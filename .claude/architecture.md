# Homelab Architecture

## Hardware Tier

### Primary Hypervisor
- **Proxmox Host** (proxmox.lan): Dell Optiplex 7050 Micro
  - Runs VMs: Home Assistant, docker.lan (Plex + services), Ubuntu Desktop
  - Monitoring: Cockpit, NodeExporter, cAdvisor
  - Plan: Cluster more Optiplexes together

### Container Hosts
- **docker.lan**: Proxmox VM
  - Primary service host (migrated from Pi4)
  - Services: Plex, AdGuardHome, WireGuard, Docker Registry, Komodo, Uptime Kuma, status page, media stack
  - Monitoring: Dockge, Cockpit, cAdvisor, NodeExporter

- **pi01**: Raspberry Pi 4
  - Legacy host (mostly replaced by docker.lan VM)
  - May still run some services; being phased out

- **octoprint.lan**: Raspberry Pi 3B+
  - Role: 3D printer control (OctoPrint)
  - Zigbee2MQTT (strategically located for signal strength)
  - Monitoring: Cockpit, cAdvisor, NodeExporter

- **pi02.lan** (legacy): Raspberry Pi 3B+
  - Currently unused (held as backup for AdGuardHome replication)

### Network
- **Router**: Mikrotik RB3011 (RouterOS) - manages VLANs, WireGuard
- **Access Point**: Netgear WAX615 (PoE-powered)
- **Switch**: 16-port PoE switch
- **DNS**: AdGuardHome on docker.lan (resolves *.lan and *.nathancj.com internally)

## Software Architecture

### Reverse Proxy
- **NGINX** (stacks/nginx-proxy/) - single entry point for all services
- Enforces HTTPS where supported
- Maps subdomains (service.$domain) to internal services
- Special IPs bypassed (e.g., Zigbee2MQTT at 192.168.0.29:8888)

### Smart Home Core
- **Home Assistant**: VirtualMachine on Proxmox
  - MQTT broker (Mosquitto)
  - Zigbee (via Zigbee2MQTT on octoprint.lan)
  - Matter, Bluetooth integration
  - Automations, dashboards

- **Zigbee2MQTT**: Docker on octoprint.lan
  - Connects Zigbee coordinator to MQTT bridge
  - Isolated on octoprint for RF signal strength

### Media Ecosystem
- **Plex Media Server**: Soon-to-be Proxmox VM
- **Monitoring/Stats**: Tautulli on docker.lan
- **Content Requests**: Overseerr, Radarr, Sonarr, Bazarr, Prowlarr, QBT on docker.lan
- **Viewing**: Plex FileBrowser, Wizarr on docker.lan
- **Alternative**: ViewTube (privacy-friendly video streaming)

### Observability
- **Prometheus**: Collects metrics from Node Exporter, cAdvisor, Speedtest Exporter
- **Grafana**: Visualizes Prometheus data
- **Uptime Kuma**: Synthetic monitoring/alerting (redundant to lanindex health checks)
- **Status Page**: Public status display
- **Speedtest Exporter**: Continuous internet speed monitoring

### Utilities
- **AdGuardHome**: DNS + ad-blocking + local CNAME records
- **WireGuard VPN**: Remote access (wg-easy UI)
- **Docker Registry + Registry UI**: Private image repository
- **UpSnap**: WakeOnLan control for machines
- **Container Management (Dockge)**: Docker management web UI
- **Cockpit**: Linux system management (on each host)
- **PrivateBin**: Encrypted pastebin
- **AirConnect**: AirPlay bridge for audio devices

### Landing Page
- **lanindex** (Flask app on docker.lan): home.lan
  - Links to all services
  - Real-time health status via `/status/<name>` endpoints
  - Service-level check_url configuration for accuracy

## Data Flow

```
Internet
  ↓
Mikrotik Router (WireGuard VPN endpoint)
  ↓
PoE Switch / WiFi
  ↓
  ├─ Proxmox (Home Assistant VM)
  │   ├─ MQTT (Mosquitto)
  │   └─ Zigbee2MQTT link
  │
  ├─ docker.lan (Pi 4)
  │   ├─ NGINX proxy (ingress)
  │   ├─ Plex media
  │   ├─ AdGuardHome (DNS)
  │   └─ Monitoring stack
  │
  └─ octoprint.lan (Pi 3)
      ├─ OctoPrint
      └─ Zigbee2MQTT (RF coordinator)

Local DNS (AdGuardHome) resolves *.lan and *.nathancj.com → internal IPs
```

## Deployment Model

- **No manual steps**: Everything via Ansible
- **Stack layout**: One `docker-compose.yml` per service in `stacks/`
- **Configuration**: ENV files (partially managed via `init_env.sh`), git-tracked YAML
- **Secrets**: `ansible/secrets.yml` (git-ignored, distributed manually)
- **Scaling**: Services can move between hosts by adjusting Ansible inventory

## Known Limitations / Planned Changes

1. Backup strategy not yet documented (see troubleshooting)
2. No persistent volume management (data on docker.lan `/mnt`)
3. WireGuard only entry point for remote access (no Tailscale, Cloudflare Tunnel yet)
4. pi01 (Pi4) being phased out in favor of Proxmox VM consolidation
