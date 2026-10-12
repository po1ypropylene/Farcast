#!/usr/bin/env python3
"""Owned loopback RFB peer. Uses only public synthetic credentials and artifacts."""
import json
import pathlib
import socket
import ssl
import struct
import sys
import threading
import zlib
from cryptography.hazmat.primitives.ciphers import Cipher, modes
from cryptography.hazmat.decrepit.ciphers.algorithms import TripleDES

root = pathlib.Path(sys.argv[1])
mode = sys.argv[2] if len(sys.argv) > 2 else "password"
version = int(sys.argv[3]) if len(sys.argv) > 3 else 8
root.mkdir(parents=True, exist_ok=True)


def exact(s, size):
    data = b""
    while len(data) < size:
        part = s.recv(size - len(data))
        if not part:
            raise EOFError()
        data += part
    return data


def rect(x, y, w, h, encoding, data=b""):
    return struct.pack(">HHHHi", x, y, w, h, encoding) + data


def update(rectangles):
    return struct.pack(">BBH", 0, 0, len(rectangles)) + b"".join(rectangles)


def handle(s, ordinal):
    events = []
    try:
        s.settimeout(45)
        s.sendall(f"RFB 003.{version:03}\n".encode())
        assert exact(s, 12) == f"RFB 003.{version:03}\n".encode()
        security = 19 if mode.startswith("tls") else 1 if mode == "none" else 30 if mode == "unsupported" else 2
        if version == 3:
            s.sendall(struct.pack(">I", security))
        else:
            s.sendall(bytes([1, security]))
            if mode == "unsupported":
                assert not s.recv(1)
                return
            assert exact(s, 1) == bytes([security])
        if security == 19:
            s.sendall(b"\x00\x02")
            assert exact(s, 2) == b"\x00\x02"
            subtype = 262 if mode == "tlsplain" else 260 if mode == "tlsnone" else 258 if mode == "tlsanonymous" else 261
            s.sendall(b"\x00\x01" + struct.pack(">I", subtype))
            if mode == "tlsanonymous":
                assert not s.recv(1)
                return
            assert struct.unpack(">I", exact(s, 4))[0] == subtype
            s.sendall(b"\x01")
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(root / "cert.pem", root / "key.pem")
            s = context.wrap_socket(s, server_side=True)
            if mode == "tlsreject":
                assert not s.recv(1)
                return
            if subtype == 262:
                user_len, password_len = struct.unpack(">II", exact(s, 8))
                assert exact(s, user_len) == b"fixture"
                assert exact(s, password_len) == b"fixture-password"
        if security == 2 or (security == 19 and mode not in ("tlsplain", "tlsnone")):
            challenge = bytes(range(16))
            s.sendall(challenge)
            key = bytes(int(f"{b:08b}"[::-1], 2) for b in b"fixture-")
            enc = Cipher(TripleDES(key), modes.ECB()).encryptor()
            expected = enc.update(challenge) + enc.finalize()
            response = exact(s, 16)
            if mode == "wrong":
                s.sendall(struct.pack(">I", 1))
                return
            assert response == expected, "VNC DES response mismatch"
        if security != 1 or version == 8:
            s.sendall(b"\0\0\0\0")
        assert exact(s, 1) == b"\x01"
        pixel_format = bytes([32, 24, 0, 1]) + struct.pack(">HHH", 255, 255, 255) + bytes([16, 8, 0, 0, 0, 0])
        s.sendall(struct.pack(">HH", 32, 24) + pixel_format + struct.pack(">I", 7) + b"fixture")
        requests = 0
        compressor = zlib.compressobj()
        while True:
            typ = exact(s, 1)[0]
            if typ == 0:
                assert exact(s, 19) == b"\0\0\0" + pixel_format
            elif typ == 2:
                header = exact(s, 3)
                count = struct.unpack(">H", header[1:])[0]
                offered = struct.unpack(">" + "i" * count, exact(s, count * 4))
                assert set(offered) == {0, 1, 5, 6, -223}
            elif typ == 3:
                request = exact(s, 9)
                requests += 1
                if requests == 1:
                    if mode == "bounds":
                        s.sendall(update([rect(31, 23, 2, 2, 0)]))
                        continue
                    if mode == "encoding":
                        s.sendall(update([rect(0, 0, 1, 1, 999)]))
                        continue
                    if mode == "oversized":
                        s.sendall(update([rect(0, 0, 16384, 16384, -223)]))
                        continue
                    colors = [bytes([i, i + 1, i + 2, 0]) for i in (70, 90)]
                    packed = [compressor.compress(c * 64) + compressor.flush(zlib.Z_SYNC_FLUSH) for c in colors]
                    tiles = bytes([2 | 8 | 16]) + bytes([40, 50, 60, 0]) + bytes([1]) + bytes([200, 150, 100, 0, 0x11, 0x11])
                    s.sendall(update([
                        rect(0, 0, 32, 24, 0, bytes([10, 20, 30, 0]) * 768),
                        rect(0, 0, 2, 2, 0, bytes([1, 2, 3, 0]) * 4),
                        rect(1, 1, 2, 2, 1, struct.pack(">HH", 0, 0)),
                        rect(16, 0, 16, 16, 5, tiles),
                        rect(0, 16, 8, 8, 6, struct.pack(">I", len(packed[0])) + packed[0]),
                        rect(8, 16, 8, 8, 6, struct.pack(">I", len(packed[1])) + packed[1]),
                    ]))
                elif requests == 2:
                    s.sendall(update([rect(0, 0, 40, 30, -223), rect(0, 0, 40, 30, 0, bytes([11, 22, 33, 0]) * 1200)]))
                else:
                    assert request[0] == 0 if requests == 3 else True
            elif typ == 4:
                packet = exact(s, 7)
                events.append(["key", packet[0], struct.unpack(">I", packet[3:])[0]])
            elif typ == 5:
                mask, x, y = struct.unpack(">BHH", exact(s, 5))
                events.append(["pointer", mask, x, y])
            else:
                raise AssertionError("Unexpected client message; clipboard sharing must stay absent")
    except (EOFError, ConnectionResetError, BrokenPipeError, ssl.SSLEOFError):
        pass
    except Exception as problem:
        (root / f"error-{ordinal}").write_text(type(problem).__name__ + ": " + str(problem))
    finally:
        s.close()
        (root / f"events-{ordinal}.json").write_text(json.dumps(events))


with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    (root / "port").write_text(str(listener.getsockname()[1]))
    ordinal = 0
    while True:
        connection, _ = listener.accept()
        ordinal += 1
        threading.Thread(target=handle, args=(connection, ordinal), daemon=True).start()
