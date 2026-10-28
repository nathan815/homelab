# Moving runtime data to /opt/appdata (#9)

Runtime data moves out of the stack folders (`/opt/stacks/<stack>/data`) into `/opt/appdata/<stack>`, which neither Ansible nor Komodo owns (folder ownership table in `komodo/README.md`). Compose files mount `${APPDATA_DIR:-/opt/appdata}/<stack>/...`. Bulk media stays on `/mnt/disk*` / `/media/plexmedia01`. Read-only config tracked in git (`dashkiosk/config.json`, `media-system/filebrowser_config.json`, `nginx-proxy/config`) stays relative.

The mapping is the same for every stack: the **contents** of `/opt/stacks/<stack>/data/` become `/opt/appdata/<stack>/`. For example, `media-system/data/plex` becomes `/opt/appdata/media-system/plex`.

## Read this first: the data move and the deploy happen together, per stack

The new compose files point at `/opt/appdata/<stack>`. Deploying one before its data is moved starts the containers on **empty** data dirs. Docker creates the missing bind sources as empty root-owned dirs: AdGuard comes up unconfigured, Plex unclaimed with no library, and the Sonarr/Radarr databases come up empty. A missing `filebrowser.db` even becomes a directory. The old data is still in `./data`, so nothing is lost, but the services are wrong until you roll back.

What protects you:
- **Merging deploys nothing.** None of these stacks are git-backed in `komodo.toml`, so `deploy.yml` skips them. Komodo's `files_on_host` stacks (`adguardhome`, `media-system`, `container-mgmt`) run whatever is in `/opt/stacks/<stack>`, and only Ansible changes that.
- **Ansible refuses to deploy an unmigrated stack.** If a stack's compose file uses `APPDATA_DIR` and `/opt/stacks/<stack>/data` still exists, `deploy-stack` fails *before* copying any files. The host keeps the old compose file and the containers keep running.
- So after merging, every Ansible run of an affected stack fails until you migrate it. Migrate one stack at a time with `--tags <stack>`. Avoid untagged runs of `base.yml` until `container-mgmt` is migrated on every docker host. Otherwise a host stops at `container-mgmt` and skips its later plays (including `komodo-periphery` from #29).

What is **not** protected: copying the new compose file by hand (e.g. `viewtube`, which isn't deployed by Ansible), or a Komodo deploy after someone hand-edits `/opt/stacks/<stack>`.

## Sizes and disk space (measured 2026-10-28, read-only)

| Host | Stack | `./data` size | Notes |
|---|---|---|---|
| pi01 | upsnap | 22M | files owned by root |
| pi01 | dashkiosk | 36K | one sqlite from 2024-05; **container not running** |
| pi01 | container-mgmt (dockge) | 108K | |
| docker.lan | container-mgmt (dockge) | 92K | |
| octoprint | container-mgmt (dockge) | not measured (no SSH key access) | probably tiny |
| none | viewtube | no `/opt/stacks/viewtube` on pi01 or docker.lan | not deployed by Ansible or Komodo |
| pi01 | adguardhome | 1.6G | nearly all `work/data` (query log / stats); `config/AdGuardHome.yaml` 8K |
| docker.lan | media-system | 4.2G | plex 3.1G, radarr 378M, tautulli 341M, sonarr 238M, prowlarr 77M, qbt 41M, bazarr 20M, wizarr 13M, overseerr 6.8M, filebrowser 44K |

`/opt/stacks` and `/opt/appdata` are on the **same filesystem** on both hosts (pi01: `/dev/mmcblk0p2`, 7.8G free; docker.lan: `/dev/sda1`, 13G free). So:
- A full `rsync` copy that keeps `./data` as a rollback copy fits everywhere: 1.6G of 7.8G on pi01, and 4.2G of 13G on docker.lan.
- If space is ever tight (e.g. Plex grew), `mv` within the same filesystem is instant and needs no extra space. In that case take the backup tarball to another disk first, because `mv` leaves no second copy.

Re-check before each stack, because these numbers drift:
```bash
S=<stack>
sudo du -sh /opt/stacks/$S/data
df -h /opt/stacks /opt/appdata 2>/dev/null || df -h /opt/stacks /opt
findmnt -T /opt/stacks -no SOURCE; findmnt -T /opt/appdata -no SOURCE 2>/dev/null || findmnt -T /opt -no SOURCE   # same device = mv possible
```

`/opt/appdata` already exists on docker.lan (owned by `nathan`, holds `qui`) but **not** on pi01. Create it once per host: `./ansible_playbook.sh playbooks/base.yml --limit <host> --tags dirs`, or `sudo install -d -o $USER -g $USER /opt/appdata` on the host.

## Generic procedure (one stack, one host)

`stacks/migrate-appdata.sh` does the host side. Run Ansible from `ansible/` in a checkout of `main` that includes this change.

```bash
# 1. Copy the script to the host and dry-run it (checks only: free space, empty target, not already migrated)
scp stacks/migrate-appdata.sh <host>:/tmp/
ssh <host> 'sudo bash /tmp/migrate-appdata.sh <stack> --dry-run'

# 2. Migrate. The script copies while the stack runs, stops it, copies the rest, verifies the
#    copy (rsync dry run + entry count), saves docker-compose.yml.pre-appdata and renames
#    ./data to ./data.pre-appdata. It leaves the stack STOPPED and prints the exact deploy
#    command and rollback. Add --checksum to verify file contents too (longer downtime).
ssh <host> 'sudo bash /tmp/migrate-appdata.sh <stack>'

# 3. Deploy the new compose file right away (from your laptop; the script prints this line)
./ansible_playbook.sh playbooks/<playbook>.yml --limit <host> --tags <tag>
```

If anything fails, the script stops before the rename, so `./data` and the old compose file are untouched. It tells you whether the stack is stopped (restart it with `docker compose up -d` in the stack folder). Empty `/opt/appdata/<stack>` before retrying; the script refuses a non-empty target.

What the script does, if you'd rather do it by hand:
```bash
S=<stack>; cd /opt/stacks/$S
sudo install -d /opt/appdata/$S
sudo rsync -aHAX --numeric-ids data/ /opt/appdata/$S/            # pre-pass, stack running
cp docker-compose.yml docker-compose.yml.pre-appdata
docker compose down
sudo rsync -aHAX --numeric-ids --delete data/ /opt/appdata/$S/   # final pass (trailing slashes matter)
sudo rsync -aHAXn --numeric-ids --delete -i data/ /opt/appdata/$S/   # must print nothing
sudo mv data data.pre-appdata
```

```bash
# 4. Verify (on the host)
docker compose ps                                   # same services up/healthy as before (the script lists what was running)
docker compose logs --tail 50
docker inspect --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' <container>   # sources under /opt/appdata/$S
# plus the stack-specific check below

# Rollback (any time before cleanup)
cd /opt/stacks/$S && docker compose down
sudo rsync -aHAX --numeric-ids --delete /opt/appdata/$S/ /opt/stacks/$S/data.pre-appdata/   # only if you want to keep data written since the move
sudo mv /opt/stacks/$S/data.pre-appdata /opt/stacks/$S/data
cp docker-compose.yml.pre-appdata docker-compose.yml
docker compose up -d
# Ansible deploys of $S now fail on the guard again (./data exists) until you retry the move.

# Cleanup, after about a week stable
sudo rm -rf /opt/stacks/$S/data.pre-appdata /opt/stacks/$S/docker-compose.yml.pre-appdata
```

## Order and per-stack notes (lowest risk first)

### 1. upsnap (pi01, 22M)
Playbook `core-services.yml --limit pi01 --tags upsnap`. Verify: `http://upsnap.lan/` lists the devices and login works. `curl -fs http://localhost:9000/api/health`.

### 2. dashkiosk (pi01, 36K)
Not currently running (no `dashkiosk` container on pi01), so the script only moves the 36K. Note that the Ansible deploy (`core-services.yml --limit pi01 --tags dashkiosk`) **starts** it. If it is meant to stay off, add `--skip-tags docker_up` to copy the files only, or decide whether to retire the stack. Verify (if started): the admin UI shows the saved displays.

### 3. container-mgmt / dockge (pi01, docker.lan, octoprint; ~100K each)
Deployed by `base.yml` to every `docker-hosts` host, so do it per host: `./ansible_playbook.sh playbooks/base.yml --limit <host> --tags dirs,container-mgmt`. Order: octoprint, docker.lan, pi01. The script's `docker compose down` also stops cAdvisor for a minute (a short metrics gap). With #29 merged, Periphery lives in its own stack and is unaffected; before #29, `down` would also stop the v1 `komodo-periphery` until the deploy brings it back. Verify: Dockge UI on port 5555 loads and logs in (its data holds the user and settings).

### 4. viewtube (no host found)
Not deployed by Ansible or Komodo, and there is no `/opt/stacks/viewtube` on pi01 or docker.lan. If it runs somewhere, run the script there (`STACKS_DIR=<parent dir>` if it isn't under `/opt/stacks`) and copy the new compose file by hand in place of the Ansible deploy. **Nothing guards this one.** Its mongo data (`data/db`) must be moved with the stack stopped. If it isn't running anywhere, there is nothing to migrate.

### 5. adguardhome (pi01, 1.6G): LAN DNS
pi01 (and the LAN) resolve through AdGuard (`/etc/resolv.conf` on pi01 is `nameserver 192.168.0.148`, AdGuard itself). While it is down, `pi01.lan` does not resolve and image pulls on pi01 fail. So:
- Use the IP for SSH and Ansible: `ssh 192.168.0.148`, and `-e ansible_ssh_host=192.168.0.148` on the playbook.
- The script's pre-pass copies the 1.6G while AdGuard still serves DNS, so the outage covers only the final delta copy and the deploy.
- Deploy without the `--pull always` up, then start locally (the image is already on the host). The script prints these two lines with the IP:
  ```bash
  ./ansible_playbook.sh playbooks/dns.yml --limit pi01 --tags adguardhome --skip-tags docker_up -e ansible_ssh_host=192.168.0.148
  ssh 192.168.0.148 'cd /opt/stacks/adguardhome && docker compose up -d'
  ```
- Back up first: `sudo tar -C /opt/stacks/adguardhome/data -czf ~/adguardhome-config-$(date +%F).tgz config` (the config is what matters; the 1.6G is logs/stats).
- Verify: `dig @192.168.0.148 example.com`, `dig @192.168.0.148 pi01.lan` (rewrites), the UI on port 4000 logs in, and filters and clients are present.
- Do this in a quiet window. Rollback is the generic one; DNS is down while you do it.

### 6. media-system (docker.lan, 4.2G), with Plex last
One compose project, so the whole stack moves at once. Within it, the risk is Plex (3.1G, hard to rebuild) > Sonarr/Radarr (databases) > the rest. "Plex last" means: do every other stack first, and migrate media-system last.
- **Backups first** (stack running). Sonarr/Radarr/Prowlarr: System -> Backup -> "Backup Now" in each UI, and download the zips. Plex: copy `data/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases/` (it also holds Plex's own scheduled DB backups) and `Preferences.xml` off the host. Optionally tar the whole of `./data` to a media disk (`/mnt/disk1` has room) if you want a copy that isn't on `/dev/sda1`.
- The script's pre-pass copies the 4.2G while the stack runs, so downtime is the delta copy plus the deploy. For media-system it also fails unless `filebrowser/filebrowser.db` arrived as a file: if it were missing, Docker would create a directory there.
- Deploy: `./ansible_playbook.sh playbooks/media-services.yml --limit docker.lan --tags media-system`. (this PR adds the `media-system` tag; without it the tag matched nothing).
- Verify in this order: qbt + gluetun up (VPN connected), Prowlarr indexers green, Sonarr/Radarr show the series/movies and their download client tests pass, Bazarr, Overseerr/Seerr requests list, Wizarr, Tautulli history, filebrowser login. **Then Plex**: the server is still claimed (not "new server" setup), libraries list with posters, a file plays, and `Preferences.xml` has the same `MachineIdentifier`.
- `qui` already uses `/opt/appdata/qui` (not `/opt/appdata/media-system/qui`). It is left as is to avoid another move.

## After all stacks
- Remove each `data.pre-appdata` once stable (generic cleanup step).
- `stacks/.gitignore` keeps ignoring `data` as a safety net.
- The stacks can now move to Komodo git mode (`komodo/README.md`, "Migrating a stack").
