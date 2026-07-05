# Troubleshooting & Common Issues

## Backup Strategy

### Current State
⚠️ **Not formalized yet**. Data lives on docker.lan VM at `/mnt/media`.

### Recommended Approach
- [ ] Document what needs backing up (Home Assistant config, AdGuardHome filters, Grafana dashboards, Plex/Sonarr/Radarr DBs)
- [ ] Implement daily snapshots (Proxmox native snaps or external)
- [ ] Test restore procedures regularly
- [ ] Off-site backup for critical configs (git-crypt + cloud storage)

---

## Service Health Checks

### lanindex shows a service as down, but it's actually up
1. Check the service's actual health endpoint:
   - Navigate to `http://service.$domain` in browser
   - Check if it returns a valid response

2. If the service is up, update `lanindex/config.json`:
   - Look for `"check_url"` — it may be hitting the wrong endpoint
   - Example: Plex uses `/identity` not root `/`

3. If `check_url` is wrong, update it:
   ```json
   {
     "name": "Plex",
     "url": "http://plex.$domain",
     "check_url": "http://plex.$domain/identity"
   }
   ```

### Service is completely down, how to debug?

#### Step 1: Check if container is running
```bash
ssh docker.lan
docker ps | grep SERVICE_NAME
docker logs SERVICE_NAME
```

#### Step 2: Check NGINX reverse proxy
```bash
ssh docker.lan
cd stacks/nginx-proxy
docker logs nginx
```
Look for proxy errors or DNS resolution failures.

#### Step 3: Check DNS
```bash
ssh docker.lan
nslookup service.$domain localhost  # Should resolve to docker.lan IP
```
If DNS is broken, check AdGuardHome on docker.lan:8089

#### Step 4: Check service logs
```bash
ssh docker.lan
cd stacks/SERVICE_NAME
docker-compose logs
```

### Service flaps (up and down intermittently)
- Often indicates: Memory pressure, disk full, or resource exhaustion
- Check: `ssh docker.lan && docker stats`
- Check disk: `df -h` on docker.lan
- Check memory: `free -h` on docker.lan

---

## Deployment Failures

### Ansible playbook fails with "unreachable" error
1. **SSH connection issue**
   - Verify host is in inventory: `ansible all -i ansible/inventory.yml --list-hosts`
   - Test SSH: `ssh -i ~/.ssh/id_rsa USERNAME@HOST.lan`
   - Check `ansible.cfg` for SSH key path

2. **Wrong user or permissions**
   - Check `inventory.yml` for correct `ansible_ssh_user`
   - Verify SSH key auth works without password
   - If you need sudo, ensure `ansible_become_password` is in `secrets.yml`

### docker-compose up fails with "network not found"
1. Ensure you're in the correct stack directory
2. Check if docker service is running: `sudo systemctl status docker`
3. Pull latest images: `docker-compose pull && docker-compose up -d`

### Port conflicts (e.g., "Bind for 0.0.0.0:80 failed")
1. Check what's using the port: `sudo lsof -i :PORT`
2. Either kill the conflicting process or change the port in `docker-compose.yml`

---

## Smart Home / MQTT Issues

### Zigbee2MQTT can't communicate with Home Assistant
1. Verify MQTT broker (Mosquitto) is running in Home Assistant
2. Check Zigbee2MQTT is subscribed to the right topic:
   ```bash
   ssh octoprint.lan
   docker logs zigbee2mqtt | grep "Zigbee home automation started"
   ```

3. Publish a test message:
   ```bash
   mosquitto_pub -h docker.lan -t "test" -m "hello"
   ```
   (From any host on the network; replace docker.lan with the MQTT broker IP if different)

### Home Assistant won't connect to Zigbee2MQTT
1. Verify MQTT host URL in Home Assistant (Settings > Devices & Services > MQTT)
   - Should be: `mqtt://HOME_ASSISTANT_IP` (internal only)
2. Check firewall rules if Home Assistant is in a different VLAN
3. Check Home Assistant logs: **Settings > System > Logs**

---

## Network / Connectivity

### Can't reach a service from outside the LAN (WireGuard connected)
1. Check if the service is exposed via NGINX or is it internal-only?
   - Internal-only: Not accessible via WireGuard (by design)
   - Via NGINX: Should be accessible as `https://service.$domain`

2. Test from WireGuard client:
   ```bash
   ping 10.x.x.x  # VPN IP of docker.lan
   curl https://service.$domain  # Should reach NGINX
   ```

3. If HTTPS cert fails, check:
   - Self-signed? Browser/client must trust it
   - Let's Encrypt? Check NGINX cert renewal (manual for internal services)

### DNS not resolving *.lan locally
1. Check AdGuardHome is running: `docker ps | grep adguardhome`
2. Set your machine to use AdGuardHome as DNS: `10.x.x.x:53`
3. Verify CNAME records in AdGuardHome UI (http://adguard.$domain:8089)

---

## Performance / Resource Issues

### docker.lan VM is slow
1. Check available memory: `free -h` → Need at least 20-30% free
2. Check disk space: `df -h` → Warn at 80%, critical at 90%
3. Check running containers: `docker ps -q | wc -l` → Too many?
4. Check CPU: `top -b -n1 | head -20`

**Quick fix**: Restart heavy containers (Plex, Prometheus)
```bash
docker restart plex prometheus
```

### Proxmox node running low on resources
1. SSH to proxmox.lan and open Proxmox UI
2. Check VM memory allocation: **Proxmox > VM > Hardware**
3. Check storage: **Proxmox > Storage**
4. If docker.lan VM is consuming memory, increase allocation or trim services

---

## Monitoring & Alerts

### Grafana dashboards show no data
1. Verify Prometheus is scraping targets: http://prometheus.$domain/targets
2. Check if Node Exporter is running on the target host: `docker ps | grep node-exporter`
3. Verify networking: Can Prometheus reach the exporter port?

### Prometheus targets are DOWN
1. Check the exporter is running: `docker ps | grep EXPORTER_NAME`
2. Check DNS resolution (if using hostname): `nslookup TARGET.lan`
3. Check firewall: Can docker.lan reach target port?

---

## Ansible Best Practices

### Before running a playbook
- Backup current state if it's a destructive operation
- Test on one host first: `--limit HOSTNAME`
- Dry-run to see what changes: `-C` or `--check`

### After running a playbook
- Verify changes: `ansible all -i inventory.yml -m setup | grep RELEVANT_FACT`
- Check logs: `ansible_playbook.sh base.yml -vv` for verbose output

---

## Getting Help

1. **Check git log** for recent changes that might have broken things
2. **Check service logs** first: `docker logs SERVICE_NAME`
3. **Post on Trello card** with details (error message, steps to reproduce)
4. **Check Home Assistant docs** for smart home issues
5. **Check service README** in the respective stack directory

---

## Quick Diagnostic Checklist

When a service is broken:
- [ ] Is the container running? `docker ps | grep SERVICE`
- [ ] Are logs helpful? `docker logs -f SERVICE`
- [ ] Is DNS working? `nslookup service.$domain`
- [ ] Is NGINX proxying correctly? Check `/stacks/nginx-proxy/conf.d/`
- [ ] Is the service's health check passing? Check lanindex
- [ ] Are there permission issues? `docker exec SERVICE ls -la /path`
- [ ] Is there a network connectivity issue? `docker exec SERVICE ping 8.8.8.8`
