# Kamal Deployment Configuration

This directory contains Kamal CI/CD configuration for deploying the homelab.

## How It Works

```
stacks/*/docker-compose.yml  (source of truth)
         ↓
config/generate-deploy.py    (auto-converter)
         ↓
config/deploy.yml            (generated, git-ignored)
         ↓
kamal deploy                 (deployment)
```

**Key insight:** Your docker-compose files are the source of truth. The Kamal config is automatically generated from them.

---

## Structure

```
config/
├── services-map.yml         ← Maps services to servers (you edit this)
├── generate-deploy.py       ← Converter script (auto-generated deploy.yml)
├── generate-deploy.sh       ← Shell wrapper
├── deploy.yml               ← Generated (git-ignored, don't edit)
└── .env                     ← Secrets (git-ignored)
```

---

## Setup

### 1. Install Kamal

```bash
# Via gem (requires Ruby 3.0+)
gem install kamal

# Or use Homebrew
brew install kamal

# Verify
kamal version
```

### 2. Configure Services

Edit `config/services-map.yml` to map your services to servers:

```yaml
servers:
  docker:
    host: docker.lan
    user: root
    services: [plex, adguard, nginx-proxy, ...]

  pi01:
    host: pi01.lan
    user: nathan
    services: [woodpecker]
```

Each service name should match a directory in `stacks/`.

### 3. Generate deploy.yml

```bash
./config/generate-deploy.sh

# Or directly:
python3 config/generate-deploy.py
```

This reads all `stacks/*/docker-compose.yml` and generates `config/deploy.yml`.

### 4. Set Up Secrets

```bash
# Create .env with secrets
cat > config/.env << EOF
PLEX_CLAIM=claim-xxxxx
ADGUARD_PASSWORD=mypassword
GITHUB_CLIENT_SECRET=github_xxxxx
WOODPECKER_AGENT_SECRET=xxxxx
EOF

chmod 600 config/.env
```

Kamal will read these and inject them into containers.

---

## Deployment

### Full Deploy

```bash
# Generate fresh deploy.yml from docker-compose files
./config/generate-deploy.sh

# Deploy to all servers
kamal deploy
```

### Deploy One Service

```bash
kamal deploy -r plex
```

### View Logs

```bash
# Tail logs from all servers
kamal logs -f

# Logs from one role
kamal logs -r plex -f
```

### Check Status

```bash
kamal status

# Shows:
# - Server health
# - Running containers
# - Memory/CPU usage
```

### Rollback

```bash
# Revert to previous version
kamal rollback
```

Kamal keeps the previous image, so rollback is instant.

---

## Workflow

### When You Change docker-compose:

```bash
# Edit stacks/plex/docker-compose.yml
# Add a new volume, environment variable, etc.

# Regenerate deploy.yml
./config/generate-deploy.sh

# Deploy
kamal deploy -r plex
```

### In Woodpecker CI/CD:

```yaml
# .woodpecker.yml
steps:
  deploy:
    image: alpine:latest
    commands:
      - apk add python3 py3-pip
      - pip3 install pyyaml
      - ./config/generate-deploy.sh
      - kamal deploy
    when:
      branch: main
      event: push
```

---

## Troubleshooting

### "Command not found: kamal"

Install Kamal:
```bash
gem install kamal
# or
brew install kamal
```

### "Can't connect to docker.lan"

SSH to the server manually to test:
```bash
ssh root@docker.lan
docker ps
```

Check `services-map.yml` for correct hostname/user.

### deploy.yml is empty

Run:
```bash
./config/generate-deploy.sh -v
```

Check that `stacks/*/docker-compose.yml` files exist and are valid YAML.

### Services don't start

Check logs:
```bash
kamal logs -r SERVICE_NAME
```

Common issues:
- Environment variables not set in `config/.env`
- Ports already in use
- Volume mount permissions
- Missing dependencies (e.g., MQTT for Zigbee2MQTT)

---

## Advanced Usage

### Zero-Downtime Deploys

Kamal handles this automatically:
1. Pulls new image
2. Starts new container (waits for healthcheck)
3. Removes old container once new is healthy
4. No downtime!

### Health Checks

Define in `stacks/SERVICE/docker-compose.yml`:

```yaml
services:
  plex:
    healthcheck:
      test: curl -f http://localhost:32400/identity || exit 1
      interval: 30s
      timeout: 10s
      retries: 3
```

Kamal will wait for this before considering deploy successful.

### Multiple Servers for One Role

```yaml
servers:
  docker1:
    host: docker1.lan
    roles: [plex]
  
  docker2:
    host: docker2.lan
    roles: [plex]

roles:
  plex:
    docker:
      image: plexinc/pms-docker:latest
      # Deployed to both servers!
```

---

## Useful Commands

```bash
# See what will be deployed (dry-run)
kamal deploy --skip-push

# Deploy with verbose output
kamal deploy -v

# Check app status
kamal status

# Run command in container
kamal exec -r plex bash

# View container details
kamal info

# Restart without redeployment
kamal restart -r plex

# Stop (keep container)
kamal stop

# Remove containers
kamal remove
```

---

## Notes

- `deploy.yml` is **generated and git-ignored**. Don't edit it directly.
- Edit `docker-compose.yml` files in `stacks/` instead.
- Run `./config/generate-deploy.sh` after changing docker-compose files.
- Secrets are in `config/.env` (git-ignored for good reason).

---

## See Also

- Kamal docs: https://kamal-deploy.org/
- Docker Compose reference: https://docs.docker.com/compose/compose-file/
- Kamal GitHub: https://github.com/basecamp/kamal
