# Tailscale

Tailscale node that is both a subnet router for the home LAN and an exit node, for reaching home from anywhere.

## Environmental Variables

* `TS_HOSTNAME` - Machine name shown in the Tailscale admin console
* `TS_AUTHKEY` - Auth key from the admin console (Settings > Keys). Only used on first start; state is kept in the `tailscale_state` volume. Deployed by Komodo (see `komodo/komodo.toml`), which reads it from the secret variable `TAILSCALE_AUTHKEY` (Settings -> Variables)
* `TS_ROUTES` - LAN subnet(s) to advertise

## One-time setup

1. Create the Komodo secret variable `TAILSCALE_AUTHKEY`, run the `homelab` resource sync, then deploy the `tailscale` stack.
2. In the admin console, open the machine > Edit route settings, approve the subnet route and "Use as exit node".
3. Optional: disable key expiry for the machine.
4. If this host's LAN is also reached by other Tailscale clients on the same subnet, fine; to use the exit node run `tailscale up --exit-node=<name>` (or pick it in the app).

The host needs IP forwarding enabled (`net.ipv4.ip_forward=1`, `net.ipv6.conf.all.forwarding=1`).
