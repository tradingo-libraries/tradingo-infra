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
ansible-playbook playbooks/deploy-stacks.yml       # All services
```

### 3. Day-to-day operations
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

# Deploy/update stacks only:
ansible-playbook playbooks/deploy-stacks.yml

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
swarm-infra/
├── ansible.cfg                 # Ansible settings
├── inventory/
│   ├── hosts.yml               # All hosts and groups
│   ├── group_vars/
│   │   ├── all.yml             # Shared variables (secrets, users, network)
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
│   └── swarm_stacks/           # Deploy compose stacks
├── playbooks/                  # Orchestration playbooks
└── stacks/                     # Docker compose files
```
