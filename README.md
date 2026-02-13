# Home Lab Docker Swarm — Ansible IaC

## Architecture

```
                         Internet
                            │
                   ┌────────┴────────┐
                   │  DO Gateway     │
                   │  <public-ip>    │
                   │  wg: 10.99.0.1  │
                   └────────┬────────┘
                            │ WireGuard
                 ┌──────────┼──────────┐
                 │          │          │
        ┌────────┴───┐  ┌──┴───┐   ┌──┴──────┐
        │  nuc-01    │  │ Rory │   │ Future  │
        │  manager   │  │ .10  │   │ .11+    │
        │  wg: .2    │  └──────┘   └─────────┘
        │  LAN .50   │
        │     │      │
        │  ┌──┴───┐  │
        │  │nuc-02│  │    Home LAN: 192.168.1.0/24
        │  │ .51  │  │    WireGuard: 10.99.0.0/24
        │  └──────┘  │
        └────────────┘
```

## Prerequisites

On your workstation (laptop/desktop):
```bash
pip install ansible
# Or: brew install ansible / apt install ansible
```

SSH key access to all nodes:
```bash
ssh-copy-id admin@192.168.1.50
ssh-copy-id admin@192.168.1.51
ssh-copy-id admin@<do-ip>
```

## Quick Start

### 1. Configure
```bash
cp inventory/group_vars/all.yml.example inventory/group_vars/all.yml
# Edit with your actual IPs, passwords, etc.
nano inventory/group_vars/all.yml
```

### 2. Bootstrap everything
```bash
# Full cluster setup (nodes + gateway):
ansible-playbook playbooks/site.yml

# Or step by step:
ansible-playbook playbooks/bootstrap-nodes.yml    # OS, users, docker, firewall
ansible-playbook playbooks/setup-gateway.yml       # DO WireGuard relay
ansible-playbook playbooks/setup-wireguard.yml     # WG peer on manager
ansible-playbook playbooks/setup-nfs.yml           # NFS server + clients
ansible-playbook playbooks/init-swarm.yml          # Swarm manager + workers
ansible-playbook playbooks/deploy-crons.yml        # Cron jobs (docker cleanup)
```

### 3. Deploy services
```bash
# Deploy monitoring (Prometheus + Grafana):
ansible-playbook playbooks/deploy-monitoring.yml

# Sync tradingo-plat repo to NFS and deploy the application stack:
ansible-playbook playbooks/sync-platform.yml -e tradingo_plat_version=v1.2.0
ansible-playbook playbooks/deploy-stack.yml -e image_tag=v1.2.0
```

### 4. Day-to-day operations
```bash
# Add a new NUC:
#   1. Add to inventory/hosts.yml under [workers]
#   2. Run:
ansible-playbook playbooks/site.yml --limit nuc-03

# Add a new user:
#   1. Add to users list in inventory/group_vars/all.yml
#   2. Run:
ansible-playbook playbooks/bootstrap-nodes.yml --tags users

# Generate a WireGuard client config:
ansible-playbook playbooks/add-wg-client.yml -e wg_client_name=jane

# Redeploy monitoring stack:
ansible-playbook playbooks/deploy-monitoring.yml

# Update application stack (after sync):
ansible-playbook playbooks/deploy-stack.yml -e image_tag=latest

# Check cluster health:
ansible-playbook playbooks/cluster-status.yml
```

## Inventory

| Host    | Group          | IP             | WG IP       | Purpose                        |
|---------|----------------|----------------|-------------|--------------------------------|
| gateway | gateway        | DO public IP   | 10.99.0.1   | WireGuard relay (not in Swarm) |
| nuc-01  | managers       | 192.168.1.50   | 10.99.0.2   | Swarm manager, NFS server      |
| nuc-02  | workers        | 192.168.1.51   | —           | Swarm worker                   |

## Users & Groups

| User    | UID  | Primary Group | Purpose                              |
|---------|------|---------------|--------------------------------------|
| admin   | 1000 | admin         | System administration, sudo          |
| rory    | 1100 | research      | Researcher, Jupyter, DAGs            |
| service | 1200 | service       | Airflow, monitoring, non-interactive |

Adding a researcher: add to `users` in `group_vars/all.yml`, run with `--tags users`.

## Project Structure

```
tradingo-infra/
├── ansible.cfg                 # Ansible settings
├── inventory/
│   ├── hosts.yml               # All hosts and groups
│   ├── group_vars/
│   │   ├── all.yml             # Shared variables (secrets, users, network)
│   │   ├── all.yml.example     # Template for all.yml
│   │   ├── swarm.yml           # Swarm node settings
│   │   └── gateway.yml         # DO gateway settings
│   └── host_vars/
│       ├── nuc-01.yml          # Per-host overrides
│       └── nuc-02.yml
├── roles/
│   ├── common/                 # Hostname, netplan, packages, firewall, SSH
│   ├── users/                  # Groups and users (research, service, admin)
│   ├── docker/                 # Docker CE install + daemon config
│   ├── nfs_server/             # NFS exports (manager only)
│   ├── nfs_client/             # NFS mounts (workers)
│   ├── wireguard_server/       # WG relay (DO gateway)
│   ├── wireguard_peer/         # WG peer (manager)
│   ├── swarm_manager/          # Swarm init + network creation
│   ├── swarm_worker/           # Swarm join
│   ├── monitoring/             # Prometheus + Grafana stack
│   └── crontabs/               # Docker cleanup cron jobs
└── playbooks/
    ├── site.yml                # Master playbook (full provisioning)
    ├── bootstrap-nodes.yml     # OS setup, users, Docker, firewall
    ├── setup-gateway.yml       # DO WireGuard gateway
    ├── setup-wireguard.yml     # WireGuard peer on manager
    ├── setup-nfs.yml           # NFS server + clients
    ├── init-swarm.yml          # Docker Swarm cluster init
    ├── deploy-crons.yml        # Cron job deployment
    ├── deploy-monitoring.yml   # Prometheus + Grafana stack
    ├── deploy-stack.yml        # Tradingo application stack
    ├── sync-platform.yml       # Sync tradingo-plat repo to NFS
    ├── cluster-status.yml      # Health check
    └── add-wg-client.yml       # Generate WireGuard client configs
```

## Monitoring Stack

Deployed via `deploy-monitoring.yml` as a separate Docker Swarm stack on the `monitoring` overlay network.

| Service        | Image                          | Port | Deployment |
|----------------|--------------------------------|------|------------|
| Prometheus     | `prom/prometheus:latest`       | 9090 | manager    |
| Grafana        | `grafana/grafana:latest`       | 3000 | manager    |
| node-exporter  | `prom/node-exporter:latest`    | —    | global     |
| cadvisor       | `gcr.io/cadvisor/cadvisor:latest` | — | global     |

### Grafana Dashboards

Pre-provisioned dashboards (auto-loaded via Grafana provisioning API):

| Dashboard         | File                                           | Content                              |
|-------------------|------------------------------------------------|--------------------------------------|
| Node Exporter     | `roles/monitoring/files/dashboards/node-exporter.json` | CPU, memory, disk, network    |
| Docker Swarm      | `roles/monitoring/files/dashboards/docker-swarm.json`  | Container counts, service health, cAdvisor metrics |

### Configuration

- Prometheus retention: 30 days / 5 GB (configurable via `prometheus_retention`, `prometheus_retention_size`)
- Grafana admin password: set via `grafana_admin_password` in `group_vars/all.yml` (default: `admin`)
- Prometheus scrapes: node-exporter, cadvisor, docker engine metrics (port 9323)
- Config deployed to `{{ monitoring_config_dir }}` (`/opt/monitoring`) on the manager node

### Managing Monitoring

```bash
# Deploy / update:
ansible-playbook playbooks/deploy-monitoring.yml

# Override Grafana password:
ansible-playbook playbooks/deploy-monitoring.yml -e grafana_admin_password=MySecret

# Tear down:
ansible-playbook playbooks/deploy-monitoring.yml -e monitoring_state=absent
```

## Application Deployment

The tradingo stack is deployed in two steps:

### 1. Sync platform code to NFS
```bash
ansible-playbook playbooks/sync-platform.yml -e tradingo_plat_version=v1.2.0
```
Clones/updates `tradingo-plat` at the given git tag, then rsyncs DAGs, config, plugins, notebooks, and scripts to the appropriate NFS shares.

### 2. Deploy Docker stack
```bash
ansible-playbook playbooks/deploy-stack.yml -e image_tag=v1.2.0

# Separate image tags per service:
ansible-playbook playbooks/deploy-stack.yml \
  -e image_tag=v1.2.0 \
  -e jupyter_tag=v1.2.0 \
  -e monitor_tag=v1.2.0

# Redeploy with current images (e.g. config-only change):
ansible-playbook playbooks/deploy-stack.yml -e image_tag=latest
```

Images are pulled from the local registry (`localhost:5000`):
- `tradingo-plat-airflow:<tag>`
- `tradingo-plat-jupyter:<tag>`
- `tradingo-plat-monitor:<tag>`
