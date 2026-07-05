# Homelab Project Overview

## What is this?
A comprehensive self-hosted infrastructure setup using Ansible and Docker, managing ~30 containerized services across multiple machines running smart home, media, monitoring, and utility applications.

## Trello Board
https://trello.com/b/16M8tM5F/smart-home-homelab

**How we work with it:**
- Tasks/features are tracked on the Trello board
- Open a PR linked to the relevant Trello card
- Update the card status when PRs are merged to main
- Priority levels: cards at top of list are highest priority

## Quick Facts
- **Deployment method**: Ansible playbooks (no manual installations)
- **Container orchestration**: docker-compose (not Kubernetes)
- **Main services**: Home Assistant, Plex, Grafana/Prometheus, AdGuardHome, Zigbee2MQTT, WireGuard VPN
- **Current constraints**: Moving from Raspberry Pis to Proxmox VMs for stability; storage/backup strategy still in progress

## Key Directories
- `ansible/` - Playbooks and roles for all provisioning
- `stacks/` - docker-compose stacks (one per service)
- `lanindex/` - Custom Flask app for LAN home page + service health checks
- `ansible/group_vars/` - Host configuration (inventory variables)
- `routeros/` - RouterOS configuration for Mikrotik router

## Current Status
See recent commits in git log. Last major additions: ViewTube, PrivateBin stacks (Feb 2025). Currently stable with ongoing migration of services to Proxmox VMs.
