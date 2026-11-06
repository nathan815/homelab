"""mitmproxy script that wraps the unmodified egress-proxy addon.
1. Imports /addon/addon.py (the original) and re-exports its addon list.
2. Patches addon.guard so the (private-IP) mock hosts on the egress net pass the SSRF guard. Spike-only.
3. Adds Swap: AFTER the approval addon allowed the request, for SWAP_HOST replace the placeholder bearer
   token with the real secret, which is read from a file mounted only into the proxy container.
"""
import os, sys
sys.path.insert(0, "/addon")
import addon as orig
from mitmproxy import ctx

MOCK_HOSTS = set(os.environ.get("MOCK_HOSTS", "").split(","))
SWAP_HOST = os.environ.get("SWAP_HOST", "")
PLACEHOLDER = os.environ.get("SWAP_PLACEHOLDER", "PLACEHOLDER_KEY")
SECRET = open(os.environ.get("SWAP_SECRET_FILE", "/run/secrets/real_key")).read().strip()

_orig_guard = orig.guard
async def guard(host):
    if host.lower() in MOCK_HOSTS:
        return None
    return await _orig_guard(host)
orig.guard = guard

class Swap:
    def request(self, flow):
        if flow.response or flow.request.host != SWAP_HOST:
            return
        a = flow.request.headers.get("Authorization", "")
        if PLACEHOLDER in a:
            flow.request.headers["Authorization"] = "Bearer " + SECRET
            ctx.log.info(f"SWAP applied for {flow.request.host}{flow.request.path}")

addons = orig.addons + [Swap()]
