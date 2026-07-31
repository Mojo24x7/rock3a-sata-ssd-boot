#!/usr/bin/env python3
"""diag_listener.py - receive initramfs boot diagnostics over raw TCP.

Run this on any machine on the same LAN as the board you are debugging, then set
DIAG_HOST to this machine's IP in /etc/default/pcie-sbr-boot on the board.

    python3 diag_listener.py [--port 9999] [--dir /tmp]

Each connection is written to a timestamped file. Raw TCP on purpose: the sending
end is `busybox nc`, whose HTTP/wget options vary between builds, and you do not
want your only diagnostic channel to depend on that.

Test the channel before you rely on it, from the board while it still boots:
    printf 'test\\n' | busybox nc <this-host> 9999
"""
import argparse
import os
import socket
import time

p = argparse.ArgumentParser()
p.add_argument("--port", type=int, default=9999)
p.add_argument("--dir", default="/tmp")
p.add_argument("--bind", default="0.0.0.0")
a = p.parse_args()

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((a.bind, a.port))
srv.listen(5)
print("listening on %s:%d  ->  %s/boot-diag-*.txt" % (a.bind, a.port, a.dir), flush=True)
print("Ctrl-C to stop", flush=True)

n = 0
while True:
    try:
        conn, addr = srv.accept()
    except KeyboardInterrupt:
        print("\nstopped", flush=True)
        break
    n += 1
    conn.settimeout(30)
    buf = b""
    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
    except Exception as e:
        buf += ("\n[listener: %s]\n" % e).encode()
    conn.close()
    path = os.path.join(a.dir, "boot-diag-%s-%d.txt" % (time.strftime("%Y%m%d-%H%M%S"), n))
    with open(path, "wb") as f:
        f.write(buf)
    print("=== %s : %d bytes -> %s" % (addr[0], len(buf), path), flush=True)

    # print the lines that usually contain the answer
    try:
        text = buf.decode("utf-8", "replace")
        for marker in ("--- PCI devices", "--- /sys/block", "--- recovery hook log"):
            i = text.find(marker)
            if i >= 0:
                print(text[i:i + 500].rstrip(), flush=True)
                print("   ...", flush=True)
    except Exception:
        pass
