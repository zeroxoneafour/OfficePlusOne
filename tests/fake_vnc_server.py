#!/usr/bin/env python3
"""A tiny fake VNC (RFB 3.8) server for tests/vnc_test.gd.

Serves one connection: a 64x48 desktop, left half red and right half blue,
plus a CopyRect of the red top-left corner onto the bottom-right. On the next
request it resizes the desktop to 80x60 and paints it green. It records what
the viewer sent: it fails on any mouse input (there's no mouse control), and
checks the key presses the test types ("Hi" then Return).
Usage: fake_vnc_server.py PORT [--password]"""
import socket, struct, sys

port = int(sys.argv[1])
want_password = "--password" in sys.argv


def recv_exact(c, n):
    b = b""
    while len(b) < n:
        chunk = c.recv(n - len(b))
        if not chunk:
            raise EOFError
        b += chunk
    return b


def raw_rect(x, y, w, h, rgb):
    return struct.pack(">HHHHi", x, y, w, h, 0) + bytes([rgb[0], rgb[1], rgb[2], 0]) * (w * h)


s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(1)
s.settimeout(30)
print("listening", flush=True)
c, _ = s.accept()
c.sendall(b"RFB 003.008\n")
version = recv_exact(c, 12)
c.sendall(bytes([1, 2 if want_password else 1]))
choice = recv_exact(c, 1)[0]
if choice == 2:
    c.sendall(bytes(range(16)))  # the challenge
    recv_exact(c, 16)  # (DES itself is checked against a standard test vector)
c.sendall(struct.pack(">I", 0))
recv_exact(c, 1)  # ClientInit (shared flag)
name = b"fake desktop"
c.sendall(struct.pack(">HH", 64, 48) + bytes([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 0, 8, 16, 0, 0, 0]) + struct.pack(">I", len(name)) + name)
requests = 0
keys = []
pixel_format_ok = False
encodings = []
try:
    while True:
        t = recv_exact(c, 1)[0]
        if t == 0:
            pf = recv_exact(c, 19)[3:]
            pixel_format_ok = pf[0] == 32 and pf[3] == 1 and pf[10:13] == bytes([0, 8, 16])
        elif t == 2:
            n = struct.unpack(">xH", recv_exact(c, 3))[0]
            encodings = list(struct.unpack(">%di" % n, recv_exact(c, 4 * n)))
        elif t == 3:
            recv_exact(c, 9)
            requests += 1
            if requests == 1:
                rects = [raw_rect(0, 0, 32, 48, (255, 0, 0)), raw_rect(32, 0, 32, 48, (0, 0, 255)),
                         struct.pack(">HHHHiHH", 56, 40, 8, 8, 1, 0, 0)]
                c.sendall(struct.pack(">xxH", len(rects)) + b"".join(rects))
            elif requests == 2:
                rects = [struct.pack(">HHHHi", 0, 0, 80, 60, -223), raw_rect(0, 0, 80, 60, (0, 255, 0))]
                c.sendall(struct.pack(">xxH", len(rects)) + b"".join(rects))
            else:
                c.sendall(bytes([2]))  # a bell: harmless, and keeps the viewer's parser honest
        elif t == 4:
            down, sym = struct.unpack(">BxxI", recv_exact(c, 7))
            keys.append((down, sym))
        elif t == 5:
            print("FAIL: the viewer sent mouse input", flush=True)
            sys.exit(1)
        else:
            print("FAIL: unexpected message %d" % t, flush=True)
            sys.exit(1)
except EOFError:
    pass
expected_keys = [(1, 0x48), (0, 0x48), (1, 0x69), (0, 0x69), (1, 0xff0d), (0, 0xff0d)]
ok = pixel_format_ok and 0 in encodings and 1 in encodings and -223 in encodings and requests >= 2 and keys == expected_keys
print("SERVER %s version=%r auth=%d requests=%d pixel_format_ok=%s encodings=%s keys=%s" % (
    "OK" if ok else "FAIL", version, choice, requests, pixel_format_ok, encodings, [(d, hex(k)) for d, k in keys]), flush=True)
sys.exit(0 if ok else 1)
