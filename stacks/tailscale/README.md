# Tailscale

Tailscale node that is both a subnet router for the home LAN and an exit node, for reaching home from anywhere.

## Environmental Variables

* `TS_HOSTNAME` - Machine name shown in the Tailscale admin console
* `TS_AUTHKEY` - Auth key from the admin console (Settings > Keys); single-use is fine. Create it with the tag `tag:homenet`. Only used on first start; state is kept in the `tailscale_state` volume. Deployed by Komodo (see `komodo/komodo.toml`), which reads it from the secret variable `TAILSCALE_AUTHKEY` (Settings -> Variables)
* `TS_ROUTES` - LAN subnet(s) to advertise

## One-time setup

1. Create the Komodo secret variable `TAILSCALE_AUTHKEY`, run the `homelab` resource sync, then deploy the `tailscale` stack.
2. In the admin console, open the machine > Edit route settings, approve the subnet route and "Use as exit node".
3. Tagged nodes don't expire. If untagged, disable key expiry for the machine instead.
4. To use the exit node from a client, run `tailscale set --exit-node=homenet` (or pick it in the app).

## ACL sketch

Define `tag:homenet` in `tagOwners` and restrict access, e.g. allow only your user to reach `tag:homenet`, `192.168.0.0/24` and `autogroup:internet`. Optionally add `autoApprovers` for the route and exit node so step 2 is automatic.

The host needs IP forwarding enabled (`net.ipv4.ip_forward=1`, `net.ipv6.conf.all.forwarding=1`).
