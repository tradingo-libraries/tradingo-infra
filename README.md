# Home Lab Docker Swarm — Ansible IaC

## Architecture

```
                         Internet
                            │
                   ┌────────┴────────┐
                   │  DO Gateway     │
                   │  <public-ip>    │
                   │  wg: 10.8.0.1   │
                   └────────┬────────┘
                            │ WireGuard (10.8.0.0/24)
                 ┌──────────┼──────────┐
                 │          │          │
        ┌────────┴───┐  ┌──┴───┐   ┌──┴──────┐
        │  nuc-01    │  │ rory │   │ Future  │
        │  manager   │  │ .10  │   │ .11+    │
        │  wg: .2    │  └──────┘   └─────────┘
        │  LAN .50   │
        │     │      │
        │  ┌──┴───┐  │
        │  │nuc-02│  │    Home LAN: 192.168.1.0/24
        │  │ .51  │  │    WireGuard: 10.8.0.0/24
        │  └──────┘  │
        └────────────┘
```

nuc-01 is the only WireGuard peer — it maintains a persistent tunnel to the DO gateway and also routes LAN traffic for nuc-02 through that tunnel. After initial bootstrap, all Ansible runs target nuc-01 at its WireGuard IP (`10.8.0.2`).

---

## Digital Ocean Gateway Setup

### 1. Create the droplet

- **Image**: Ubuntu 24.04 LTS
- **Size**: Smallest available (1 vCPU / 512MB is enough for a WireGuard relay)
- **Region**: Pick closest to your home
- **SSH keys**: Add your workstation's public key to your DO account **before** creating the droplet — DO injects it into `root` automatically on creation

Once created, note the public IP and set it in `inventory/group_vars/all.yml`:
```yaml
do_public_ip: "x.x.x.x"
do_ssh_user: "rory"
```

### 2. Verify root access

```bash
ssh root@<do_public_ip> "whoami"
```

If this fails, check that your SSH key was added to the DO project before the droplet was created. You may need to rebuild the droplet with the key attached.

### 3. Run the gateway playbook (first time: as root)

On a fresh droplet the `rory`/`admin` users don't exist yet, so the first run must connect as `root`:

```bash
ansible-playbook playbooks/setup-gateway.yml -e ansible_user=root
```

This creates users, propagates your SSH key, and configures WireGuard. Subsequent runs use the default `do_ssh_user` (`rory`) and don't need `-e ansible_user=root`.

---

## Bootstrap Order (from scratch)

> **Important**: Steps 1–3 must be run while on the **home LAN** or with direct SSH access to the NUCs (192.168.1.50/51). Step 2 (setup-wireguard) has a chicken-and-egg dependency — it configures the WireGuard tunnel on nuc-01, but to run it you need to reach nuc-01 first. Once the tunnel is up, `10.8.0.2` is always reachable remotely.

```bash
# 1. Set up DO gateway (run once as root, then rory works for future runs)
ansible-playbook playbooks/setup-gateway.yml -e ansible_user=root

# 2. Bootstrap swarm nodes (OS, users, Docker, firewall) — must be on LAN
ansible-playbook playbooks/bootstrap-nodes.yml

# 3. Configure WireGuard peer on nuc-01 — must be on LAN for first run
ansible-playbook playbooks/setup-wireguard.yml \
  -e ansible_host=192.168.1.50 --limit nuc-01

# Verify tunnel is up, then all subsequent runs use WG IP from inventory:
ansible nuc-01 -m ping

# 4. Set up NFS
ansible-playbook playbooks/setup-nfs.yml

# 5. Initialise Docker Swarm
ansible-playbook playbooks/init-swarm.yml

# 6. Deploy cron jobs
ansible-playbook playbooks/deploy-crons.yml
```

### Chicken-and-egg: re-bootstrapping nuc-01

If the WireGuard tunnel on nuc-01 ever goes down and you're not on the LAN, you can't reach `10.8.0.2`. Override the host on the command line without touching the inventory:

```bash
ansible-playbook playbooks/setup-wireguard.yml \
  -e ansible_host=192.168.1.50 --limit nuc-01
```

---

## Prerequisites

On your workstation:
```bash
pip install ansible
ansible-galaxy collection install community.general ansible.posix
```

---

## Inventory

| Host    | Group    | `ansible_host` | WG IP     | LAN IP        | Purpose                        |
|---------|----------|----------------|-----------|---------------|-------------------------------|
| gateway | gateway  | DO public IP   | 10.8.0.1  | —             | WireGuard relay (not in Swarm) |
| nuc-01  | managers | 10.8.0.2       | 10.8.0.2  | 192.168.1.50  | Swarm manager, NFS server, WG peer |
| nuc-02  | workers  | 192.168.1.51   | —         | 192.168.1.51  | Swarm worker (via nuc-01 routing) |

nuc-02 is not a WireGuard peer. It is accessed from outside the LAN via routing through nuc-01's tunnel.

---

## WireGuard Clients

Clients (laptop, phone) connect to the DO gateway and get access to both the WireGuard subnet (`10.8.0.0/24`) and the home LAN (`192.168.1.0/24`).

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

## Day-to-Day Operations

```bash
# Add a new WireGuard client:
ansible-playbook playbooks/add-wg-client.yml -e wg_client_name=jane

# Add a new user to swarm nodes:
#   1. Add to users list in inventory/group_vars/all.yml
#   2. Run:
ansible-playbook playbooks/bootstrap-nodes.yml --tags users

# Add a new NUC worker:
#   1. Add to inventory/hosts.yml under workers
#   2. Run:
ansible-playbook playbooks/site.yml --limit nuc-03

# Deploy / update monitoring:
ansible-playbook playbooks/deploy-monitoring.yml

# Sync platform and deploy application stack:
ansible-playbook playbooks/sync-platform.yml -e tradingo_plat_version=v1.2.0
ansible-playbook playbooks/deploy-stack.yml -e image_tag=v1.2.0

# Check cluster health:
ansible-playbook playbooks/cluster-status.yml
```

---

## Users & Groups

| User    | UID  | Primary Group | Sudo        | Purpose                              |
|---------|------|---------------|-------------|--------------------------------------|
| admin   | 1001 | admin         | NOPASSWD    | System administration                |
| rory    | 1100 | research      | NOPASSWD    | Researcher, Jupyter, DAGs, Ansible   |
| service | 1200 | service       | —           | Airflow, monitoring (non-interactive)|

All users in the `sudo` group get passwordless sudo (required for Ansible automation).

---

## Project Structure

```
tradingo-infra/
├── ansible.cfg                 # Ansible settings (remote_user=admin, key=~/.ssh/id_ed25519)
├── inventory/
│   ├── hosts.yml               # All hosts and groups
│   ├── group_vars/
│   │   ├── all.yml             # Shared variables (secrets, users, network) — not committed
│   │   ├── all.yml.example     # Template — copy to all.yml and fill in
│   │   ├── swarm.yml           # Swarm node settings
│   │   └── gateway.yml         # DO gateway settings
│   └── host_vars/
│       ├── nuc-01.yml          # static_ip, hostname
│       └── nuc-02.yml
├── roles/
│   ├── common/                 # Hostname, netplan static IP, packages, firewall, SSH
│   ├── users/                  # Groups, users, sudo, SSH key propagation
│   ├── docker/                 # Docker CE install + daemon config
│   ├── nfs_server/             # NFS exports (manager only)
│   ├── nfs_client/             # NFS mounts (workers)
│   ├── wireguard_server/       # WG relay config (DO gateway)
│   ├── wireguard_peer/         # WG peer config (nuc-01 manager)
│   ├── swarm_manager/          # Swarm init + overlay network creation
│   ├── swarm_worker/           # Swarm join
│   ├── monitoring/             # Prometheus + Grafana stack
│   └── crontabs/               # Docker cleanup cron jobs
└── playbooks/
    ├── site.yml                # Master playbook (full provisioning)
    ├── bootstrap-nodes.yml     # OS setup, users, Docker, firewall
    ├── setup-gateway.yml       # DO WireGuard gateway + users
    ├── setup-wireguard.yml     # WireGuard peer on nuc-01
    ├── setup-nfs.yml           # NFS server + clients
    ├── init-swarm.yml          # Docker Swarm cluster init
    ├── deploy-crons.yml        # Cron job deployment
    ├── deploy-monitoring.yml   # Prometheus + Grafana stack
    ├── deploy-stack.yml        # Tradingo application stack
    ├── sync-platform.yml       # Sync tradingo-plat repo to NFS
    ├── cluster-status.yml      # Health check
    └── add-wg-client.yml       # Generate WireGuard client configs
```

---

## Monitoring Stack

Deployed via `deploy-monitoring.yml` as a Docker Swarm stack on the `monitoring` overlay network.

| Service       | Image                             | Port | Placement |
|---------------|-----------------------------------|------|-----------|
| Prometheus    | `prom/prometheus:latest`          | 9090 | manager   |
| Grafana       | `grafana/grafana:latest`          | 3000 | manager   |
| node-exporter | `prom/node-exporter:latest`       | —    | global    |
| cadvisor      | `gcr.io/cadvisor/cadvisor:latest` | —    | global    |

```bash
# Deploy / update:
ansible-playbook playbooks/deploy-monitoring.yml

# Override Grafana password:
ansible-playbook playbooks/deploy-monitoring.yml -e grafana_admin_password=MySecret

# Tear down:
ansible-playbook playbooks/deploy-monitoring.yml -e monitoring_state=absent
```

---

## Application Deployment

```bash
# 1. Sync platform code to NFS:
ansible-playbook playbooks/sync-platform.yml -e tradingo_plat_version=v1.2.0

# 2. Deploy Docker stack:
ansible-playbook playbooks/deploy-stack.yml -e image_tag=v1.2.0

# Redeploy with current images (config-only change):
ansible-playbook playbooks/deploy-stack.yml -e image_tag=latest
```

Images pulled from local registry (`localhost:5000`):
- `tradingo-plat-airflow:<tag>`
- `tradingo-plat-jupyter:<tag>`
- `tradingo-plat-monitor:<tag>`
