#!/usr/bin/env python3
"""Minimal BonDriverProxy / BonDriverTunnel compatible server for development.

Serves TS files as channels so BonView/bdpcat can be tested without a tuner:

    scripts/mock_bdp_server.py --port 1192 --tunnel-port 1193 ch1.ts ch2.ts

BonDriverProxy accepts any BonDriver name; BonDriverTunnel accepts origin --origin (default "Mock").

Each file becomes a channel in tuning space 0 ("Mock"). Files are streamed at roughly
real-time pace (PCR-based, --rate Mbps as fallback) and looped.
Protocols: see Sources/BonDriver/ProxyProtocol.swift and TunnelClient.swift.
"""
import argparse
import os
import socket
import struct
import threading
import time

(SELECT_BONDRIVER, CREATE_BONDRIVER, OPEN_TUNER, CLOSE_TUNER, SET_CHANNEL1, GET_SIGNAL_LEVEL,
 WAIT_TS_STREAM, GET_READY_COUNT, GET_TS_STREAM, PURGE_TS_STREAM, RELEASE, GET_TUNER_NAME,
 IS_TUNER_OPENING, ENUM_TUNING_SPACE, ENUM_CHANNEL_NAME, SET_CHANNEL2, GET_CUR_SPACE,
 GET_CUR_CHANNEL, GET_TOTAL_DEVICE_NUM, GET_ACTIVE_DEVICE_NUM, SET_LNB_POWER) = range(21)


def packet(cmd, body=b""):
    return struct.pack(">BBBBI", 0xFF, cmd, 0, 0, len(body)) + body


def wstr(s):
    return (s.encode("utf-16-le") if s is not None else b"") + b"\0\0"


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError
        buf += chunk
    return buf


def last_pcr(data):
    """Last PCR (seconds) found in a chunk of aligned TS packets."""
    pcr = None
    for i in range(0, len(data) - 187, 188):
        if data[i] != 0x47 or not (data[i + 3] & 0x20) or data[i + 4] < 7 or not (data[i + 5] & 0x10):
            continue
        b = data[i + 6:i + 12]
        base = (b[0] << 25) | (b[1] << 17) | (b[2] << 9) | (b[3] << 1) | (b[4] >> 7)
        ext = ((b[4] & 1) << 8) | b[5]
        pcr = (base * 300 + ext) / 27e6
    return pcr


def pace_file(path, alive, sink, rate):
    """Feed `path` to `sink` in chunks at real-time pace (PCR-based, `rate` bytes/s fallback), looping."""
    chunk = 188 * 256
    with open(path, "rb") as f:
        start, sent, pcr0 = time.monotonic(), 0, None
        while alive():
            data = f.read(chunk)
            if not data:
                f.seek(0)
                start, sent, pcr0 = time.monotonic(), 0, None
                continue
            try:
                sink(data)
            except OSError:
                return
            sent += len(data)
            pcr = last_pcr(data)
            if pcr is not None and pcr0 is None:
                pcr0, start = pcr, time.monotonic()
            target = pcr - pcr0 if pcr is not None else sent / rate
            ahead = target - (time.monotonic() - start)
            if ahead > 0:
                time.sleep(min(ahead, 1.0))


class Session:
    def __init__(self, sock, files, rate_mbps):
        self.sock = sock
        self.files = files
        self.rate = rate_mbps * 1e6 / 8
        self.lock = threading.Lock()
        self.channel = None
        self.gen = 0

    def send(self, data):
        with self.lock:
            self.sock.sendall(data)

    def stream(self, path, gen):
        sent = [0]

        def sink(data):
            body = struct.pack(">If", len(data), 25.0 + (sent[0] % 7) / 10) + data
            sent[0] += len(data)
            self.send(packet(GET_TS_STREAM, body))

        pace_file(path, lambda: gen == self.gen, sink, self.rate)

    def run(self):
        try:
            while True:
                sync, cmd, _, _, length = struct.unpack(">BBBBI", recv_exact(self.sock, 8))
                body = recv_exact(self.sock, length) if length else b""
                if cmd == SELECT_BONDRIVER:
                    print("SelectBonDriver", body.rstrip(b"\0").decode(errors="replace"))
                    self.send(packet(cmd, b"\x01"))
                elif cmd in (CREATE_BONDRIVER, OPEN_TUNER, PURGE_TS_STREAM, SET_LNB_POWER):
                    self.send(packet(cmd, b"\x01"))
                elif cmd == ENUM_TUNING_SPACE:
                    (i,) = struct.unpack(">I", body)
                    self.send(packet(cmd, wstr(SPACE_NAME if i == 0 else None)))
                elif cmd == ENUM_CHANNEL_NAME:
                    sp, ch = struct.unpack(">II", body[:8])
                    name = channel_name(self.files[ch]) if sp == 0 and ch < len(self.files) else None
                    self.send(packet(cmd, wstr(name)))
                elif cmd == SET_CHANNEL2:
                    sp, ch, lock = struct.unpack(">IIB", body)
                    print(f"SetChannel2 space={sp} ch={ch} lock={lock}")
                    if sp != 0 or ch >= len(self.files):
                        self.send(packet(cmd, struct.pack(">I", 0xFF)))
                        continue
                    self.gen += 1
                    self.send(packet(cmd, struct.pack(">I", 0)))
                    threading.Thread(target=self.stream, args=(self.files[ch], self.gen), daemon=True).start()
                elif cmd in (GET_TOTAL_DEVICE_NUM, GET_ACTIVE_DEVICE_NUM):
                    self.send(packet(cmd, struct.pack(">I", 1)))
                elif cmd == CLOSE_TUNER:
                    self.gen += 1
                elif cmd == RELEASE:
                    break
        except (ConnectionError, OSError):
            pass
        finally:
            self.gen += 1
            self.sock.close()
            print("client disconnected")


class TunnelSession:
    """BonDriverTunnel protocol (little-endian, 16-byte commands, polled GTsS)."""
    SESSION_ID = 0x5A5A5A50
    MAX_TS = 481280

    def __init__(self, sock, files, rate_mbps, origin):
        self.sock, self.files, self.rate, self.origin = sock, files, rate_mbps * 1e6 / 8, origin
        self.buf = bytearray()
        self.lock = threading.Lock()
        self.gen = 0
        self.last_cmd = None
        self.last_reply = b""

    def sink(self, data):
        with self.lock:
            if len(self.buf) < 32 << 20:
                self.buf += data

    def run(self):
        dw = lambda v: struct.pack("<I", v & 0xFFFFFFFF)

        def ws(text):
            if text is None:
                return dw(0)
            enc = text.encode("utf-16-le") + b"\0\0"
            return dw(len(enc) // 2) + enc

        try:
            hello = recv_exact(self.sock, 524)
            origin = hello[12:].decode("utf-16-le").split("\0")[0]
            print("Tunnel", hello[4:8].decode(), origin)
            if origin.lower() != self.origin.lower():
                return
            self.sock.sendall(dw(self.SESSION_ID | 3 if hello[4:8] == b"Crea" else 0))
            while True:
                cmd = recv_exact(self.sock, 16)
                if cmd == self.last_cmd:
                    self.sock.sendall(self.last_reply)
                    continue
                name = cmd[:4].decode(errors="replace")
                p1, p2 = struct.unpack("<II", cmd[8:16])
                if name in ("Open", "Clos", "Purg"):
                    if name != "Open":
                        self.gen += 1 if name == "Clos" else 0
                        with self.lock:
                            self.buf.clear()
                    reply = dw(1 if name == "Open" else 0)
                elif name == "GTun":
                    reply = ws("Mock Tunnel")
                elif name == "ETun":
                    reply = ws(SPACE_NAME if p1 == 0 else None)
                elif name == "ECha":
                    reply = ws(channel_name(self.files[p2]) if p1 == 0 and p2 < len(self.files) else None)
                elif name == "SCh2":
                    ok = p1 == 0 and p2 < len(self.files)
                    print(f"SCh2 space={p1} ch={p2}")
                    if ok:
                        self.gen += 1
                        gen = self.gen
                        with self.lock:
                            self.buf.clear()
                        threading.Thread(target=pace_file, args=(self.files[p2], lambda: gen == self.gen, self.sink, self.rate),
                                         daemon=True).start()
                    reply = dw(1 if ok else 0)
                elif name == "GSig":
                    reply = struct.pack("<f", 27.5)
                elif name in ("GTot", "GAct"):
                    reply = dw(1)
                elif name == "GTsS":
                    with self.lock:
                        data = bytes(self.buf[:self.MAX_TS])
                        del self.buf[:len(data)]
                        remain = len(self.buf) // 48128
                    reply = dw(4 + len(data)) + dw(remain) + data
                else:  # Rele / unknown
                    self.sock.sendall(dw(0))
                    break
                self.last_cmd, self.last_reply = cmd, reply
                self.sock.sendall(reply)
        except (ConnectionError, OSError):
            pass
        finally:
            self.gen += 1
            self.sock.close()
            print("tunnel client disconnected")


def listen(port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen()
    return srv


SPACE_NAME = "Mock"


def channel_name(path):
    """Channel name shown to clients: the file name without extension (e.g. 13Ch.ts → 13Ch)."""
    return os.path.splitext(os.path.basename(path))[0]


def main():
    global SPACE_NAME
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=1192)
    ap.add_argument("--rate", type=float, default=16.0, help="stream rate in Mbps")
    ap.add_argument("--tunnel-port", type=int, default=1193, help="BonDriverTunnel port (0 to disable)")
    ap.add_argument("--origin", default="Mock", help="BonDriverTunnel origin name (BonDriver_<origin>.dll)")
    ap.add_argument("--space-name", default="Mock", help="tuning space name reported to clients")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    SPACE_NAME = a.space_name
    if a.tunnel_port:
        tsrv = listen(a.tunnel_port)
        print(f"BonDriverTunnel on 127.0.0.1:{a.tunnel_port} (origin {a.origin})")

        def tunnel_loop():
            while True:
                s, _ = tsrv.accept()
                threading.Thread(target=TunnelSession(s, a.files, a.rate, a.origin).run, daemon=True).start()

        threading.Thread(target=tunnel_loop, daemon=True).start()
    srv = listen(a.port)
    print(f"BonDriverProxy on 127.0.0.1:{a.port}")
    while True:
        s, addr = srv.accept()
        print("client", addr)
        threading.Thread(target=Session(s, a.files, a.rate).run, daemon=True).start()


if __name__ == "__main__":
    main()
