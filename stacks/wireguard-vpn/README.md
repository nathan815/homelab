# Wireguard VPN

VPN for accessing my home LAN from anywhere.

## Environmental Variables

* `WG_EXTERNAL_HOST` - External hostname which clients connect to
* `WG_PASSWORD_HASH` - Password hash
    * Generate with: ` docker run --rm -it ghcr.io/wg-easy/wg-easy wgpw 'PASSWORD_HERE'`
* `WG_LAN_NETWORK` - Network address block for local network
