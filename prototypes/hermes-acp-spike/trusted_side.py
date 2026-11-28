#!/usr/bin/env python3
"""Trusted side (outside the sandbox). Listens for the shim's OUTBOUND connection, then bridges its own
stdin/stdout (= the ACP client's pipe) to that socket. A real product would replace stdin/stdout with the app backend."""
import socket, sys, threading, os
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", int(sys.argv[1]) if len(sys.argv) > 1 else 9000)); srv.listen(1)
print("trusted: waiting for shim", file=sys.stderr, flush=True)
c, addr = srv.accept(); print("trusted: shim connected from %s" % (addr,), file=sys.stderr, flush=True)
def up():
    while (d := os.read(0, 65536)):
        c.sendall(d)
    c.shutdown(socket.SHUT_WR)
threading.Thread(target=up, daemon=True).start()
while (d := c.recv(65536)):
    os.write(1, d)
