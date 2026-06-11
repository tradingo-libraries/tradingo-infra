# CLAUDE.md — tradingo-infra

Ansible IaC for a 5-node Docker Swarm home cluster. The **README.md** has full architecture diagrams, bootstrap order, WireGuard setup, and user reference — read that first. This file focuses on agent-useful context: accurate service inventory, placement mapping, and how to make common changes.

All `make` targets are in the **root `Makefile`** (`/Users/rmcstay/dev/tradsys/Makefile`). Run them from the repo root, not from this directory.

---

## Node Reference

| Host    | LAN IP        | WG IP    | Swarm role | Labels                              | Key roles                                    |
|---------|---------------|----------|------------|-------------------------------------|----------------------------------------------|
| gateway | DO public IP  | 10.8.0.1 | —          | —                                   | WireGuard relay (not in Swarm)               |
| nuc-05  | 192.168.1.54  | 10.8.0.8 | manager    | `role=manager`, `workload=platform`, `node=nuc-05` | Swarm manager, WG peer, platform services    |
| nuc-01  | 192.168.1.50  | —        | worker     | `role=worker`, `workload=compute`, `node=nuc-01`   | NFS server, Docker registry :5000, buildx    |
| nuc-02  | 192.168.1.51  | —        | worker     | `role=worker`, `workload=compute`, `node=nuc-02`   | MinIO, Grafana, Loki                         |
| nuc-03  | 192.168.1.52  | —        | worker     | `role=worker`, `workload=compute`, `node=nuc-03`   | Compute workloads                            |
| nuc-04  | 192.168.1.53  | —        | worker     | `role=worker`, `workload=compute`, `node=nuc-04`   | Compute workloads                            |

**Placement shorthand** used in stack files:
- `node.role == manager` → **nuc-05**
- `node.labels.workload == platform` → **nuc-05**
- `node.labels.workload == compute` → **nuc-01, nuc-02, nuc-03, nuc-04**
- `node.labels.node == nuc-01` → **nuc-01** (registry pinning)
- `node.labels.node == nuc-02` → **nuc-02** (MinIO, Grafana, Loki pinning)

---

## Service Inventory

Four stacks are active plus two standalone services. Replicas reflect the running state; services with 0 replicas are on-demand.

### `tradingo` stack (`tradingo-plat/docker-stack.yaml`)

| Service                 | Image                         | Placement              | Port(s)    | Notes                              |
|-------------------------|-------------------------------|------------------------|------------|------------------------------------|
| `postgres`              | `postgres:13`                 | manager (nuc-05)       | —          | Airflow + Miniflux DB              |
| `redis`                 | `redis:7.2-bookworm`          | manager (nuc-05)       | 6379 (host)| Celery broker                      |
| `airflow-init`          | airflow image                 | manager (nuc-05)       | —          | One-shot: DB migrate + admin user  |
| `airflow-db-cleanup`    | airflow image                 | manager (nuc-05)       | —          | On-demand (scale to 1 to trigger)  |
| `airflow-apiserver`     | airflow image                 | platform (nuc-05)      | 8080       | Airflow REST API + web UI          |
| `airflow-scheduler`     | airflow image                 | platform (nuc-05)      | —          |                                    |
| `airflow-dag-processor` | airflow image                 | platform (nuc-05)      | —          |                                    |
| `airflow-triggerer`     | airflow image                 | platform (nuc-05)      | —          |                                    |
| `airflow-worker`        | airflow image                 | compute (global)       | —          | Celery worker; currently replicas=0|
| `airflow-worker-claude` | airflow-claude image          | compute (nuc-01..04)   | —          | Dedicated Claude queue, 2 concurrent|
| `tradingo-worker`       | jupyter image                 | compute (global)       | —          | Tradingo Celery queue; replicas=0  |
| `flower`                | airflow image                 | any                    | 5555       | Celery monitoring UI               |
| `dask-scheduler`        | jupyter image                 | platform (nuc-05)      | 8786, 8787 | 8787 = Dask dashboard              |
| `dask-worker`           | jupyter image                 | compute (global)       | —          | Currently replicas=0               |
| `jupyter`               | jupyter image                 | compute (nuc-01..04)   | 8083       |                                    |
| `monitor`               | monitor image                 | platform (nuc-05)      | 8082       | Tradingo portfolio dashboard       |
| `tradingo-mcp`          | mcp image                     | platform (nuc-05)      | 8765       | MCP research server (streamable-HTTP)|
| `airflow-mcp`           | `ghcr.io/astral-sh/uv:*`      | platform (nuc-05)      | 8767       | Airflow REST API as MCP            |
| `miniflux`              | `miniflux/miniflux:latest`    | platform (nuc-05)      | 8084       | RSS feed aggregator                |
| `miniflux-db-init`      | `postgres:13`                 | manager (nuc-05)       | —          | One-shot: create miniflux DB       |
| `miniflux-feed-init`    | `alpine:latest`               | manager (nuc-05)       | —          | On-demand: import feeds.opml       |
| `minio`                 | `minio/minio:latest`          | nuc-02                 | 9000, 9001 | S3-compatible ArcticDB storage; 9001=console |
| `createbuckets`         | `minio/mc:latest`             | manager (nuc-05)       | —          | One-shot: create tradingo-store bucket|

**Airflow images** (`192.168.1.50:5000/tradingo-plat-airflow:<tag>`):
- `airflow` — base Airflow image
- `airflow-claude` — adds Claude CLI for agent tasks

**Other images** (all from local registry `192.168.1.50:5000`):
- `tradingo-plat-jupyter:<tag>` — Jupyter + Dask + Tradingo worker
- `tradingo-plat-monitor:<tag>` — Plotly Dash portfolio dashboard
- `tradingo-plat-mcp:<tag>` — Tradingo MCP server

---

### `monitoring` stack (`roles/monitoring/templates/monitoring-stack.yml.j2`)

| Service             | Image                                  | Placement         | Port(s) | Notes                                    |
|---------------------|----------------------------------------|-------------------|---------|------------------------------------------|
| `prometheus`        | `prom/prometheus:latest`               | platform (nuc-05) | 9090    | 90d / 60 GB retention                    |
| `grafana`           | `grafana/grafana:latest`               | **nuc-02**        | 3000    | Pinned to nuc-02, not manager            |
| `loki`              | `grafana/loki:latest`                  | **nuc-02**        | 3100    | 30d retention                            |
| `grafana-mcp`       | `grafana/mcp-grafana:latest`           | **nuc-02**        | 8766    | Grafana as MCP (streamable-HTTP)         |
| `promtail`          | `grafana/promtail:latest`              | global            | —       | Log shipping to Loki                     |
| `node-exporter`     | `prom/node-exporter:latest`            | global            | —       | Host metrics                             |
| `cadvisor`          | `gcr.io/cadvisor/cadvisor:latest`      | global            | —       | Container metrics                        |
| `postgres-exporter` | `prometheuscommunity/postgres-exporter`| manager (nuc-05)  | —       | Postgres metrics; on `tradingo-backend` network |

> **Note**: Grafana, Loki, and grafana-mcp are pinned to **nuc-02**, not the manager. The README monitoring table is incorrect on this point.

---

### `docker-mcp` stack (`roles/docker_mcp/templates/docker-mcp-stack.yml.j2`)

| Service      | Image                                        | Placement         | Port | Notes                       |
|--------------|----------------------------------------------|-------------------|------|-----------------------------|
| `docker-mcp` | `ghcr.io/khaentertainment/docker-swarm-mcp`  | manager (nuc-05)  | 8000 | Docker Swarm API as MCP; mounts docker.sock |

---

### `web-search-mcp` stack (`roles/web_search_mcp/templates/web-search-mcp-stack.yml.j2`)

| Service          | Image                                     | Placement         | Port | Notes                          |
|------------------|-------------------------------------------|-------------------|------|--------------------------------|
| `web-search-mcp` | `192.168.1.50:5000/web-search-mcp:latest` | platform (nuc-05) | 8768 | DuckDuckGo search MCP; on `tradingo-backend` network |

---

### Standalone services (not in a stack, managed by `swarm_manager` role)

| Service             | Image                                        | Placement | Port | Notes                      |
|---------------------|----------------------------------------------|-----------|------|----------------------------|
| `registry`          | `registry:2`                                 | nuc-01    | 5000 | Local Docker registry (HTTP/insecure) |
| `registry-frontend` | `konradkleine/docker-registry-frontend:v2`   | nuc-01    | 5080 | Web UI for browsing images |

---

## Port Quick-Reference

| Port | Service                    | Stack        |
|------|----------------------------|--------------|
| 3000 | Grafana                    | monitoring   |
| 3100 | Loki                       | monitoring   |
| 5000 | Docker registry            | standalone   |
| 5080 | Registry frontend          | standalone   |
| 5555 | Flower (Celery UI)         | tradingo     |
| 6379 | Redis                      | tradingo     |
| 8000 | Docker MCP                 | docker-mcp   |
| 8080 | Airflow API server         | tradingo     |
| 8082 | Monitor dashboard          | tradingo     |
| 8083 | Jupyter                    | tradingo     |
| 8084 | Miniflux RSS               | tradingo     |
| 8765 | Tradingo MCP               | tradingo     |
| 8766 | Grafana MCP                | monitoring   |
| 8767 | Airflow MCP                | tradingo     |
| 8768 | Web search MCP             | web-search-mcp|
| 8786 | Dask scheduler (internal)  | tradingo     |
| 8787 | Dask dashboard             | tradingo     |
| 9000 | MinIO S3 API               | tradingo     |
| 9001 | MinIO console              | tradingo     |
| 9090 | Prometheus                 | monitoring   |

---

## Roles → Playbooks Mapping

| Role                | Playbook(s)                              | What it manages                                         |
|---------------------|------------------------------------------|---------------------------------------------------------|
| `common`            | `bootstrap-nodes.yml`, `site.yml`        | Hostname, netplan, packages, firewall, SSH              |
| `users`             | `bootstrap-nodes.yml`, `site.yml`        | Users, groups, sudo, SSH keys                           |
| `docker`            | `bootstrap-nodes.yml`, `site.yml`        | Docker CE, daemon.json (insecure-registries, log config)|
| `nfs_server`        | `setup-nfs.yml`, `site.yml`              | NFS exports on nuc-01                                   |
| `nfs_client`        | `setup-nfs.yml`, `site.yml`              | NFS mounts on nuc-02/03/04/05                           |
| `wireguard_server`  | `setup-gateway.yml`                      | WG relay on DO gateway                                  |
| `wireguard_peer`    | `setup-wireguard.yml`                    | WG peer on nuc-05                                       |
| `swarm_manager`     | `init-swarm.yml`                         | Swarm init, overlay networks, registry, registry-frontend, buildx, node labels |
| `swarm_worker`      | `init-swarm.yml`, `site.yml`             | Swarm join, node labels, buildx builder on nuc-01       |
| `monitoring`        | `deploy-monitoring.yml`                  | Full monitoring stack (prometheus, grafana, loki, etc.) |
| `docker_mcp`        | `deploy-docker-mcp.yml`                  | Docker Swarm MCP server stack                           |
| `web_search_mcp`    | `deploy-web-search-mcp.yml`              | Web search MCP stack                                    |
| `crontabs`          | `deploy-crons.yml`                       | Per-host cron jobs (docker cleanup, airflow DB cleanup) |

---

## Common Operations

All `make` commands run from the **repo root**.

```bash
make status                        # Check cluster health
make build TAG=<version>           # Update lock, build images on nuc-01, push to registry
make deploy TAG=<version>          # Sync config to NFS + roll out images
make sync-platform                 # Config-only sync (no image rebuild)
make deploy-monitoring             # Update monitoring stack
make deploy-docker-mcp             # Update Docker MCP stack
make deploy-crons                  # Deploy cron jobs to all nodes

# Override Grafana password:
cd tradingo-infra && ansible-playbook playbooks/deploy-monitoring.yml -e grafana_admin_password=MySecret

# Inspect live services:
# ssh nuc-05 "docker service ls"

# Scale an on-demand service:
# ssh nuc-05 "docker service scale tradingo_airflow-db-cleanup=1"

# Rotate IG API key:
cd tradingo-plat && ./scripts/rotate-ig-api-key.sh
```

---

## Making Changes

### Adding/modifying a service in the tradingo stack
Edit `tradingo-plat/docker-stack.yaml`, then run `make deploy TAG=<tag>` from the repo root.

### Modifying monitoring config (Prometheus scrape targets, Loki retention, etc.)
Edit the templates/files under `roles/monitoring/`, then run `make deploy-monitoring`.

### Adding a new NUC worker
1. Add to `inventory/hosts.yml` under `workers` with appropriate `swarm_labels`.
2. Add `inventory/host_vars/nuc-XX.yml` with `static_ip` and `hostname`.
3. Run `ansible-playbook playbooks/site.yml --limit nuc-XX`.

### Adding a new NFS-shared volume

NFS shares are declared in `inventory/group_vars/all.yml` under `nfs_shares`. Adding a volume to `docker-stack.yaml` that uses `type: nfs4` requires a matching entry there **and** reprovisioning the NFS server so the directory is created and exported.

1. Add the share to `nfs_shares` in `inventory/group_vars/all.yml`:
   ```yaml
   - name: my_new_share
     owner_group: service   # or research / root as appropriate
     mode: "2775"
   ```
2. Run `make setup-nfs` from the repo root — this creates the directory on nuc-01, sets ownership/permissions, and updates `/etc/exports`.
3. Add the NFS volume definition to `tradingo-plat/docker-stack.yaml`:
   ```yaml
   my-new-volume:
     driver: local
     driver_opts:
       type: nfs4
       o: "addr=${NFS_SERVER:-nfs.local},soft,rw"
       device: ":${NFS_BASE:-/srv/nfs}/my_new_share"
   ```
4. Deploy: `make deploy TAG=<tag>`.

Skipping step 2 means the NFS path doesn't exist and Docker will fail to mount the volume on any node other than the one where the directory happens to have been created manually.

### Adding a new MCP server stack
Follow the pattern in `roles/docker_mcp/` or `roles/web_search_mcp/`:
1. Create a role with `defaults/main.yml`, `tasks/main.yml`, and a `templates/<name>-stack.yml.j2`.
2. Add a `playbooks/deploy-<name>.yml` and a `Makefile` target.
3. If the MCP needs to reach Airflow workers, attach it to `tradingo_tradingo-backend` (external network).

### Updating node labels
Labels are applied by `swarm_manager` and `swarm_worker` roles from `inventory/hosts.yml` `swarm_labels`. Re-run `init-swarm.yml` or update labels manually: `docker node update --label-add key=value <nodename>` on the manager.

---

## Key Files

| File | Purpose |
|------|---------|
| `inventory/hosts.yml` | All hosts, groups, and node labels |
| `inventory/group_vars/all.yml` | Secrets, users, network config (gitignored — see `all.yml.example`) |
| `inventory/group_vars/swarm.yml` | Swarm advertise interface |
| `inventory/host_vars/nuc-XX.yml` | Per-host static IP and hostname |
| `versions.env` | Image tag pinning (`TAG=`, `VERSION=`) for reference — not used by Ansible |
| `Makefile` | Convenience targets wrapping `ansible-playbook` |
| `tradingo-plat/docker-stack.yaml` | Full tradingo application stack definition |
| `roles/monitoring/templates/monitoring-stack.yml.j2` | Monitoring stack definition |
