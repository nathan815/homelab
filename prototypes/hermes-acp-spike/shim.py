#!/usr/bin/env python3
"""Runs INSIDE the sandbox. Connects OUT to the trusted side and bridges bytes <-> `hermes acp` stdio.
No listener is opened. usage: shim.py HOST PORT [-- cmd args...]  (default cmd: hermes acp)"""
import socket, subprocess, sys, threading
host, port = sys.argv[1], int(sys.argv[2])
cmd = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else ["hermes", "acp"]
s = socket.create_connection((host, port))
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open("/tmp/shim-child.err", "wb"))
def sock_to_child():
    try:
        while (d := s.recv(65536)): p.stdin.write(d); p.stdin.flush()
    except OSError: pass
    try: p.stdin.close()      # trusted side went away -> EOF to hermes
    except OSError: pass
def child_to_sock():
    while (d := p.stdout.read1(65536)):
        try: s.sendall(d)
        except OSError: break
    try: s.shutdown(socket.SHUT_WR)
    except OSError: pass
threading.Thread(target=sock_to_child, daemon=True).start()
t = threading.Thread(target=child_to_sock); t.start()
p.wait(); t.join(2)
