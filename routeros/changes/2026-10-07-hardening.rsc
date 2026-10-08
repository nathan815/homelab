# 2026-10-07 router hardening (change record)
#
# Context: RB3011UiAS (upgraded to RouterOS 7.24.5 the same day; was 7.14.3); audit found
#   - WAN port 80 forward reachable by anyone, not just Cloudflare
#   - telnet/ftp/plain-http/API/Winbox/SSH reachable from all of the LAN
#   - bandwidth-test server and neighbor discovery enabled on every interface
#   - port-80 forward logging every connection, flushing the log buffer in ~5 hours
#
# Run order (do the upgrade by hand first - it reboots the router):
#   1. ./update.sh  (done 2026-10-07: 7.14.3 -> 7.24.5, firmware 7.24.5)
#   2. upload cloudflare-address-list.rsc and this file via scp, then on the router:
#        /import cloudflare-address-list.rsc
#        /import 2026-10-07-hardening.rsc
#   3. verify: site loads through Cloudflare, Plex remote works, WireGuard connects,
#      then `/ip service print` and a fresh ssh login from the Mac.
#
# Before running, confirm the LAN really is 192.168.0.0/24 with `/ip address print`.
# Not in this file on purpose: creating a named admin user / ssh key and disabling
# `admin`, because that needs a password. Do it by hand afterwards.

# Refuse to run if the Cloudflare list is missing - the NAT change below would
# otherwise match nothing and take the site offline.
:if ([:len [/ip firewall address-list find where list=cloudflare]] = 0) do={ :error "import cloudflare-address-list.rsc first" }

# Backup + readable export first (v7 export hides sensitive values by default).
/system backup save name=pre-hardening-2026-10-07
/export file=pre-hardening-2026-10-07

# WAN port 80 -> nginx-public: Cloudflare only, and stop logging every connection.
/ip firewall nat set [find comment="Web: WAN IN Port 80"] src-address-list=cloudflare log=no

# Management services: drop the cleartext ones, limit the rest to the LAN.
# (api stays on, LAN-only, because routeros_web uses it. www stays for WebFig; disable it
#  once www-ssl has a certificate.)
/ip service disable telnet,ftp,reverse-proxy
/ip service set ssh available-from=192.168.0.0/24
/ip service set winbox available-from=192.168.0.0/24
/ip service set api available-from=192.168.0.0/24
/ip service set www available-from=192.168.0.0/24

# Stop advertising/serving management features on the WAN side.
/tool bandwidth-server set enabled=no
/ip neighbor discovery-settings set discover-interface-list=LAN
/tool mac-server set allowed-interface-list=LAN
/tool mac-server mac-winbox set allowed-interface-list=LAN

# SSH
/ip ssh set strong-crypto=yes

# ---- ROLLBACK (paste manually if something breaks) ----
# /ip firewall nat set [find comment="Web: WAN IN Port 80"] !src-address-list log=yes
# /ip service enable telnet,ftp,reverse-proxy
# /ip service set ssh,winbox,api,www available-from=""
# /tool bandwidth-server set enabled=yes
# /ip neighbor discovery-settings set discover-interface-list=all
# /tool mac-server set allowed-interface-list=all
# /tool mac-server mac-winbox set allowed-interface-list=all
# /ip ssh set strong-crypto=no
# Full restore: /system backup load name=pre-hardening-2026-10-07
