# Claude Code Project Documentation

This directory contains project context and guides for collaborating on the homelab repository.

## Quick Navigation

### Getting Started
- **[project.md](./project.md)** — What is this? Trello board integration, current status
- **[architecture.md](./architecture.md)** — Hardware, software, and data flow overview

### How-To Guides
- **[deployments.md](./deployments.md)** — Adding services, running playbooks, managing secrets
- **[environment-variables.md](./environment-variables.md)** — How to handle `.env` files and secrets

### Troubleshooting
- **[troubleshooting.md](./troubleshooting.md)** — Common issues and debugging steps

## Trello Workflow

Tasks live on the [Trello board](https://trello.com/b/16M8tM5F/smart-home-homelab).

**How to work with it:**
1. Pick a card from the Trello board
2. Create a PR that links to the card
3. When merged, move the card to "Done"

## First-Time Setup

If you're deploying this homelab for the first time:

1. Read **[architecture.md](./architecture.md)** to understand the hardware layout
2. Follow **[deployments.md](./deployments.md)** for step-by-step instructions
3. Reference **[environment-variables.md](./environment-variables.md)** for secrets management

## Key Commands

```bash
# Run Ansible playbook
cd ansible/
./ansible_playbook.sh base.yml --limit docker.lan

# Deploy a service stack
cd stacks/SERVICE_NAME
docker-compose up -d

# Check service health via lanindex
# Visit http://home.lan (or http://home.nathancj.com from WireGuard)
```

## Most Important Practices

1. **Never commit secrets** — Use `.gitignore` at repo root
2. **Everything via Ansible** — No manual installation when possible
3. **One stack per service** — Easier to manage and move between hosts
4. **Document as you go** — Update these docs when adding services or discovering gotchas

## Questions?

- Check **[troubleshooting.md](./troubleshooting.md)** first
- Search **git log** for similar changes
- Post on the relevant Trello card for discussion
