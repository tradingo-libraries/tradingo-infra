# Home Lab Docker Swarm — Ansible IaC

## Architecture

```
                         Internet
                            │
                   ┌────────┴────────┐
                   │  DO Gateway     │
                   │  wg: 10.8.0.1   │
                   └────────┬────────┘
                            │ WireGuard (10.8.0.0/24)
                            │
                   ┌────────┴────────┐
                   │    nuc-05       │  ← Swarm manager
                   │  LAN .54        │     Docker registry :5000
                   │  WG: 10.8.0.8   │     WireGuard peer (jump host)
                   └────────┬────────┘
                            │ ProxyJump (SSH)
           ┌────────┬───────┴────────┬────────┐
           │        │                │        │
      ┌────┴───┐ ┌──┴────┐      ┌───┴───┐ ┌──┴────┐
      │ nuc-01 │ │ nuc-02│      │ nuc-03│ │ nuc-04│
      │  .50   │ │  .51  │      │  .52  │ │  .53  │
      │ worker │ │worker │      │worker │ │worker │
      │  NFS ✓ │ └───────┘      └───────┘ └───────┘
      └────────┘

Home LAN: 192.168.1.0/24    WireGuard: 10.8.0.0/24
```

All Ansible runs reach LAN nodes via `ProxyJump` through nuc-05's WireGuard IP (`10.8.0.8`). After first bootstrap, the cluster is fully reachable from anywhere on the WireGuard network.

---

## Inventory

| Host    | Group    | `ansible_host` | WG IP    | LAN IP        | Roles                                        |
|---------|----------|----------------|----------|---------------|----------------------------------------------|
| gateway | gateway  | DO public IP   | 10.8.0.1 | —             | WireGuard relay (not in Swarm)               |
| nuc-05  | managers | 192.168.1.54   | 10.8.0.8 | 192.168.1.54  | Swarm manager, WG peer                                  |
| nuc-01  | workers  | 192.168.1.50   | —        | 192.168.1.50  | Swarm worker, NFS server, Docker registry, buildx builder |
| nuc-02  | workers  | 192.168.1.51   | —        | 192.168.1.51  | Swarm worker, NFS client, MinIO              |
| nuc-03  | workers  | 192.168.1.52   | —        | 192.168.1.52  | Swarm worker, NFS client                     |
| nuc-04  | workers  | 192.168.1.53   | —        | 192.168.1.53  | Swarm worker, NFS client                     |

Workers are not WireGuard peers — they are reached from outside the LAN via the ProxyJump through nuc-05.

---

## Digital Ocean Gateway Setup

### 1. Create the droplet

- **Image**: Ubuntu 24.04 LTS
- **Size**: Smallest available (1 vCPU / 512 MB is enough for a WireGuard relay)
- **Region**: Pick closest to home
- **SSH keys**: Add your workstation's public key to your DO account before creating — DO injects it into `root` automatically on creation

Once created, set the public IP in `inventory/group_vars/all.yml`:
```yaml
do_public_ip: "x.x.x.x"
do_ssh_user: "rory"
```

### 2. Run the gateway playbook (first time: as root)

On a fresh droplet the `rory`/`admin` users don't exist yet, so the first run connects as `root`:

```bash
ansible-playbook playbooks/setup-gateway.yml -e ansible_user=root
```

This creates users, propagates your SSH key, and configures WireGuard. Subsequent runs use `do_ssh_user` and don't need `-e ansible_user=root`.

---

## Bootstrap Order (from scratch)

> **Important**: Steps 1–3 must be run while on the **home LAN** or with direct SSH access to the NUCs. Step 3 (setup-wireguard) configures the WireGuard peer on nuc-05, but to run it you need to reach nuc-05 first. Once the tunnel is up, `10.8.0.8` is always reachable remotely.

```bash
# 1. Set up DO gateway
ansible-playbook playbooks/setup-gateway.yml -e ansible_user=root

# 2. Bootstrap swarm nodes (OS, users, Docker, firewall) — must be on LAN
make bootstrap
# or: ansible-playbook playbooks/bootstrap-nodes.yml

# 3. Configure WireGuard peer on nuc-05 — must be on LAN for first run
ansible-playbook playbooks/setup-wireguard.yml -e ansible_host=192.168.1.54 --limit nuc-05

# Verify tunnel is up — all subsequent runs use WG ProxyJump automatically:
ansible swarm -m ping

# 4. Set up NFS (server on nuc-01, clients on nuc-02/03/04/05)
ansible-playbook playbooks/setup-nfs.yml

# 5. Initialise Docker Swarm, create registry + buildx builder
ansible-playbook playbooks/init-swarm.yml

# 6. Deploy cron jobs
make deploy-crons
```

### Chicken-and-egg: re-bootstrapping nuc-05

If the WireGuard tunnel on nuc-05 ever goes down and you're not on the LAN, you can't reach `10.8.0.8`. Override the host without touching inventory:

```bash
ansible-playbook playbooks/setup-wireguard.yml \
  -e ansible_host=192.168.1.54 --limit nuc-05
```

---

## Prerequisites

On your workstation:
```bash
pip install ansible
ansible-galaxy collection install community.general ansible.posix
```

Copy and fill in secrets:
```bash
cp inventory/group_vars/all.yml.example inventory/group_vars/all.yml
# Edit all.yml — this file is gitignored
```

---

## Day-to-Day Operations

All `make` commands run from the **repo root** (the root `Makefile` wraps all Ansible playbooks).

```bash
# Check cluster health:
make status

# Build images + update lock + push to registry:
make build TAG=<version>

# Sync platform config to NFS + deploy:
make deploy TAG=<version>

# Deploy / update monitoring stack:
make deploy-monitoring

# Deploy / update Docker MCP stack:
make deploy-docker-mcp

# Add a new WireGuard client:
cd tradingo-infra && ansible-playbook playbooks/add-wg-client.yml -e wg_client_name=laptop

# Add a new user to all swarm nodes:
#   1. Add entry to users list in inventory/group_vars/all.yml
#   2. Run:
cd tradingo-infra && ansible-playbook playbooks/bootstrap-nodes.yml --tags users

# Add a new NUC worker:
#   1. Add to inventory/hosts.yml under workers
#   2. Run:
cd tradingo-infra && ansible-playbook playbooks/site.yml --limit nuc-XX

# Rotate the IG API key across Swarm services:
cd tradingo-plat && ./scripts/rotate-ig-api-key.sh
```

---

## Docker Registry

The local registry runs as a Swarm service pinned to **nuc-01** (`192.168.1.50:5000`), managed by the `swarm_manager` role (service constraint `node.hostname == nuc-01`).

| Service            | Port | Notes                                   |
|--------------------|------|-----------------------------------------|
| Registry           | 5000 | HTTP (insecure), pinned to nuc-01       |
| Registry frontend  | 5080 | Web UI for browsing images (nuc-01)     |

All swarm nodes have `192.168.1.50:5000` in their `insecure-registries` daemon config so plain HTTP pushes/pulls work cluster-wide.

A **buildx builder** (`tradingo-builder`) is provisioned on nuc-01 via the `swarm_worker` role. It uses a `buildkitd.toml` at `/etc/buildkit/buildkitd.toml` that marks the registry as insecure. Use it for cross-platform or multi-stage builds:

```bash
docker buildx build --builder tradingo-builder \
  --push -t 192.168.1.50:5000/my-image:latest .
```

---

## WireGuard Clients

Clients connect to the DO gateway and get access to both the WireGuard subnet (`10.8.0.0/24`) and the home LAN (`192.168.1.0/24`).

To add a new client:
1. Add an entry to `wg_clients` in `inventory/group_vars/all.yml`:
   ```yaml
   wg_clients:
     rory:
       ip: "10.8.0.10"
     phone:
       ip: "10.8.0.11"
   ```
2. Run:
   ```bash
   ansible-playbook playbooks/add-wg-client.yml -e wg_client_name=phone
   ```
3. Fetch the config or scan the QR from the gateway:
   ```bash
   # QR code for phone:
   ssh rory@<do_public_ip> "sudo qrencode -t ansiutf8 < /etc/wireguard/client-phone.conf"

   # Config file for laptop:
   scp rory@<do_public_ip>:/etc/wireguard/client-rory.conf ~/
   ```

---

## Users & Groups

| User    | UID  | Primary Group | Sudo     | Purpose                               |
|---------|------|---------------|----------|---------------------------------------|
| admin   | 1001 | admin         | NOPASSWD | System administration, Ansible        |
| rory    | 1100 | research      | NOPASSWD | Researcher, Jupyter, DAGs             |
| service | 1200 | service       | —        | Airflow, monitoring (non-interactive) |

---

## Monitoring Stack

Deployed via `make deploy-monitoring` as a Swarm stack on the `monitoring` overlay network.

| Service       | Image                             | Port | Placement |
|---------------|-----------------------------------|------|-----------|
| Prometheus    | `prom/prometheus`                 | 9090 | manager   |
| Grafana       | `grafana/grafana`                 | 3000 | manager   |
| Loki          | `grafana/loki`                    | 3100 | manager   |
| Promtail      | `grafana/promtail`                | —    | global    |
| node-exporter | `prom/node-exporter`              | —    | global    |
| cadvisor      | `gcr.io/cadvisor/cadvisor`        | —    | global    |

Prometheus retains 90 days / 60 GB. Loki retains 30 days.

```bash
# Deploy / update:
make deploy-monitoring

# Override Grafana password:
ansible-playbook playbooks/deploy-monitoring.yml -e grafana_admin_password=MySecret

# Tear down:
ansible-playbook playbooks/deploy-monitoring.yml -e monitoring_state=absent
```

---

## Project Structure

```
tradingo-infra/
├── ansible.cfg                 # remote_user=admin, inventory path
├── Makefile                    # Convenience targets
├── versions.env                # Image tag pinning (not in Ansible)
├── inventory/
│   ├── hosts.yml               # All hosts and groups
│   ├── group_vars/
│   │   ├── all.yml             # Secrets, users, network config — gitignored
│   │   ├── all.yml.example     # Template — copy to all.yml and fill in
│   │   ├── swarm.yml           # Swarm advertise interface
│   │   └── gateway.yml         # DO gateway settings
│   └── host_vars/
│       ├── nuc-01.yml          # static_ip, hostname
│       ├── nuc-02.yml
│       ├── nuc-03.yml
│       ├── nuc-04.yml
│       └── nuc-05.yml
├── roles/
│   ├── common/                 # Hostname, netplan, packages, firewall, SSH
│   ├── users/                  # Groups, users, sudo, SSH key propagation
│   ├── docker/                 # Docker CE + daemon.json (insecure-registries, log config)
│   ├── nfs_server/             # NFS exports (nuc-01)
│   ├── nfs_client/             # NFS mounts (nuc-02/03/04/05)
│   ├── wireguard_server/       # WG relay config (DO gateway)
│   ├── wireguard_peer/         # WG peer config (nuc-05)
│   ├── swarm_manager/          # Swarm init, overlay networks, Docker registry,
│   │                           #   buildx builder, regctl, node labels
│   ├── swarm_worker/           # Swarm join
│   ├── monitoring/             # Prometheus + Grafana + Loki stack
│   ├── docker_mcp/             # Docker Swarm MCP server stack
│   └── crontabs/               # Per-host cron jobs (docker cleanup, db cleanup)
└── playbooks/
    ├── site.yml                # Full cluster provisioning (imports all below)
    ├── bootstrap-nodes.yml     # OS setup, users, Docker, firewall
    ├── setup-gateway.yml       # DO WireGuard gateway + users
    ├── setup-wireguard.yml     # WireGuard peer on nuc-05
    ├── setup-nfs.yml           # NFS server + clients
    ├── init-swarm.yml          # Swarm init, registry, buildx builder
    ├── promote-manager.yml     # Promote a worker to manager
    ├── deploy-crons.yml        # Cron job deployment
    ├── deploy-monitoring.yml   # Prometheus + Grafana + Loki stack
    ├── deploy-stack.yml        # Tradingo application stack
    ├── sync-platform.yml       # Sync tradingo-plat repo to NFS
    ├── setup-docker-mcp.yml    # One-time Docker MCP setup (secrets etc.)
    ├── deploy-docker-mcp.yml   # Deploy / update Docker MCP stack
    ├── cluster-status.yml      # Health check
    └── add-wg-client.yml       # Generate WireGuard client configs
```