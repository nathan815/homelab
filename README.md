# Nathan's SmartHome / HomeLab

My home is becoming smarter day by day with the help of technology. I'm using this as a way to learn new things in software & hardware, and to make life easier!

https://trello.com/b/16M8tM5F/smart-home-homelab

## Services

The services I'm currently locally running include:

- Home Assistant
- Plex Media Server
- AdGuardHome - DNS server which blocks ads network wide. Similar to pihole.
- WireGuard VPN
- Monitoring - Grafana & Prometheus
- Continuous Internet Monitoring (Speedtest + Uptime) with Prometheus
- NGINX reverse proxy - enables accessing all my local services at friendly domain names on port 80/443
- UpSnap - WakeOnLan tool
- Zigbee2MQTT
- Octoprint

## Hardware


- Dell Optiplex 7050 Micro (proxmox.lan)
  - Running Proxmox Hypervisor
  - VMs:
    - Home Assistant
    - Ubuntu Desktop
    - _WIP_: VM with Plex Media Server and related media docker containers

- Raspberry Pi 4 (pi01.lan)
  - Running most of my services currently, but I'm in the process of moving many of them over to VMs on the Proxmox box.

- Raspberry Pi 3 (pi02.lan)
  - This previously hosted Home Assistant, but I've since moved it into a VM on Proxmox (has been way more stable)
  - Planning to repurpose this Pi as a backup for certain services like AdGuard Home.

- Raspberry Pi 3 (octoprint.lan)
  - Octoprint 3D printer control software
  - Also runs zigbee2mqtt container for my Zigbee network due to the location of the Pi being ideal for the Zigbee coordinator.

### Base Software
Each of these machines have some base software installed (see ansible/playbooks/base.yml).

* Cockpit (management web UI)
* Prometheus Node Exporter (system monitoring - CPU/mem/disk/network/etc.)

## Ansible

Most of the Ansible roles here deploy docker containers with docker-compose.

### Ansible Build
I run Ansible in a docker container so I don't have to deal with maintaining its dependencies on my machine.

`docker build -t ansible:latest .`
