#!/usr/bin/env python3
"""Reconnect test: process A creates a session + one turn and exits; process B (fresh `hermes acp`) resumes/loads it."""
import json, shlex, sys, time
from client import AcpClient
CMD = shlex.split(sys.argv[1] if len(sys.argv) > 1 else "docker exec -i -u hermes acpspike-hermes hermes acp")
INIT = {"protocolVersion": 1, "clientCapabilities": {}}
a = AcpClient(CMD); a.request("initialize", INIT)
sid = a.request("session/new", {"cwd": "/tmp", "mcpServers": []})["sessionId"]
a.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "remember me"}]})
a.close(); print("== process A closed; session", sid)

b = AcpClient(CMD, raw=True); b.request("initialize", INIT)
print("== session/list (new process)"); print(json.dumps(b.request("session/list", {"cwd": "/tmp"}))[:400])
print("== session/resume"); r = b.request("session/resume", {"sessionId": sid, "cwd": "/tmp", "mcpServers": []}); print(json.dumps(r)[:300])
n = len(b.notifs); print("replay notifications received before resume response:", n)
print("== follow-up prompt on resumed session")
print(b.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "hello again"}]})["stopReason"])
b.close()
c = AcpClient(CMD); c.request("initialize", INIT)
print("== session/load (third process)"); print(json.dumps(c.request("session/load", {"sessionId": sid, "cwd": "/tmp", "mcpServers": []}))[:200])
print("replay notifications:", len(c.notifs), [n["params"]["update"]["sessionUpdate"] for n in c.notifs][:12])
c.close()
