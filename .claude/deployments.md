# Deploying & Managing Services

## Adding a New Service

> Komodo-managed (git-backed) stacks deploy from CI on push to main: see `komodo/README.md` ("Adding a stack"). The steps below are the older Ansible/manual path.

### 1. Create the Stack Directory
```bash
mkdir stacks/myservice
```

### 2. Create docker-compose.yml
- Store all config in the compose file or as environment variables
- Use the standard template for ENV variable substitution:
  ```yaml
  services:
    myapp:
      image: myapp:latest
      environment:
        - CONFIG_VAR=${CONFIG_VAR}
        - SECRET_VAR=${SECRET_VAR}
  ```

### 3. Environment Setup (if needed)
- If the service needs secrets or host-specific config, add them to `ansible/group_vars/all.yml` or host-specific vars
- Alternative: Create a `.env` file in the stack directory (add to `.gitignore`)

### 4. Expose via NGINX
Edit `stacks/nginx-proxy/conf.d/default.conf`:
```nginx
server {
    server_name myservice.$domain;
    location / {
        proxy_pass http://docker.lan:PORT;
    }
}
```

### 5. Register in lanindex (optional but recommended)
Edit `apps/lanindex/config.json`:
```json
{
  "name": "My Service",
  "url": "http://myservice.$domain",
  "check_url": "http://myservice.$domain/health"  // optional
}
```

### 6. Deploy via Ansible (if using Ansible)
Create `ansible/roles/myservice/tasks/main.yml` or run manually:
```bash
cd stacks/myservice
docker-compose -f docker-compose.yml up -d
```

## Standard Playbooks & When to Use Them

Run from `ansible/` directory. Assumes an Ansible docker container is built; use `ansible_playbook.sh` wrapper.

### `base.yml`
- **What**: Installs base software (Cockpit, Node Exporter, cAdvisor)
- **When**: New host added to inventory
- **Inventory**: Targets group in `inventory.yml`
```bash
./ansible_playbook.sh base.yml --limit proxmox
```

### `core-services.yml`
- **What**: NGINX proxy, monitoring stack (Prometheus, Grafana, Speedtest)
- **When**: Initializing docker.lan
- **Requirement**: Run `base.yml` first

### `media-services.yml`
- **What**: Plex, Sonarr, Radarr, Bazarr, Prowlarr, Overseerr, Tautulli, QBT
- **When**: Setting up media ecosystem
- **Warning**: Large disk space required; see media-system README

### `dns.yml`
- **What**: AdGuardHome configuration
- **When**: First deployment or config changes

### `zigbee.yml`
- **What**: Zigbee2MQTT setup
- **When**: Initial octoprint.lan setup

### `mounts.yml`
- **What**: NFS/SMB mounts for shared storage
- **When**: After core services running

## Secrets Management

### Secrets File
- Location: `ansible/secrets.yml` (git-ignored)
- Template: `ansible/sample.secrets.yml`
- Usage: Variables in secrets.yml are available to all Ansible plays

### How to Set Secrets
1. Copy `sample.secrets.yml` to `secrets.yml`
2. Fill in values (passwords, API keys, etc.)
3. Reference in playbooks/roles:
   ```yaml
   - name: Set config
     template:
       src: config.j2
       dest: /path/to/config
     vars:
       api_key: "{{ vault_api_key }}"  # from secrets.yml
   ```

### Best Practice
- Never commit actual secrets.yml
- Store it securely outside the repo (1Password, git-crypt, etc.)
- Distribute to team members via secure channel
- Rotate regularly

## Environment Variables (docker-compose stacks)

### init_env.sh
- **Purpose**: Generate `.env` files for stacks that need them
- **Usage**: `stacks/init_env.sh`
- **Creates**: `.env` in each stack directory (git-ignored)
- **Customization**: Edit the script or individual stack `.env` files before deploying

### init_data.sh
- **Purpose**: Initialize persistent data directories
- **Usage**: `stacks/init_data.sh`
- **Examples**: Create volume mounts, permission fixes

### Workflow
```bash
cd stacks/
./init_env.sh          # Generate all .env files
./init_data.sh         # Initialize data directories
docker-compose -f myservice/docker-compose.yml up -d
```

## Service-Specific Notes

### Plex (media-system)
- Runs on docker.lan Proxmox VM
- Large storage footprint: `/mnt/media`
- Tautulli monitors Plex for stats
- FileBrowser, Overseerr, Wizarr are satellite services

### Zigbee2MQTT (octoprint.lan)
- Must run on octoprint for RF coverage
- Connected to Home Assistant via MQTT
- Config in `ansible/roles/zigbee2mqtt/`

### AdGuardHome
- Handles DNS for *.lan and *.nathancj.com
- Blocks ads network-wide
- Stores filters in `/opt/adguardhome/`

### WireGuard VPN
- Router endpoint for external access
- Managed via wg-easy UI
- Clients configured in Mikrotik RouterOS

### Woodpecker CI
- Stack at `stacks/woodpecker`, runs on pi01, deployed via `deploy-stack` role (`core-services.yml`, tag `woodpecker`):
  ```bash
  cd ansible/
  ./ansible_playbook.sh core-services.yml --tags woodpecker
  ```
- Exposed at `http://woodpecker.lan.nathancj.com` (proxied to `pi01.lan:8001` — **not** 8000, since nginx-proxy's own `nginx-public` container already binds host port 8000 on pi01)
- `.env` values needed (see `.env.defaults`): `WOODPECKER_HOST`, `WOODPECKER_GITHUB_CLIENT`/`WOODPECKER_GITHUB_SECRET` (from a GitHub OAuth App, not a GitHub App — callback URL `http://woodpecker.lan.nathancj.com/authorize`; "Enable Device Flow" is not needed), `WOODPECKER_AGENT_SECRET` (`openssl rand -hex 32`)
- After deploying, authorize with GitHub in the UI, enable the `homelab-code` repo, and add `komodo_api_key` / `komodo_api_secret` repo secrets for the image pipelines (see `komodo/README.md`)

## Backup & Restore

### Current State
- **What's backed up**: Questionable; see [troubleshooting.md](./troubleshooting.md#backup-strategy)
- **Recommendation**: Document backup schedule for:
  - Home Assistant configuration
  - AdGuardHome filters
  - Grafana dashboards
  - Media library metadata (Plex/Sonarr/Radarr databases)

## Troubleshooting Deployments

See [troubleshooting.md](./troubleshooting.md)
