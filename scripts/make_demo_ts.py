#!/usr/bin/env python3
"""Generate a broadcast-like demo TS (test pattern + tone) with ARIB SI tables.

ffmpeg makes the A/V (MPEG-2 1440x1080i + AAC); this script then replaces ffmpeg's SDT and
adds EIT present/following and TOT, with names encoded as ARIB STD-B24 8-unit strings, so the
demo shows a station name, programme titles and a broadcast clock. Used for screenshots and for
trying BonView with scripts/mock_bdp_server.py without a tuner.

    scripts/make_demo_ts.py out.ts --sid 1024 --name "デモテレビ" \\
        --title "ニュース" --text "番組の説明" --next "天気予報" --start 2026-11-13T19:00 --minutes 60
"""
import argparse
import datetime as dt
import subprocess
import tempfile
import unicodedata

TS = 188


def crc32_mpeg2(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc


def arib(text: str) -> bytes:
    """ARIB 8-unit string: ASCII via the alphanumeric set (LS1), everything else via the default
    G0 Kanji set (JIS X 0208, taken from EUC-JP) after LS0."""
    out = bytearray()
    gl = 0  # 0 = Kanji (G0), 1 = alphanumeric (G1)
    for ch in text:
        if ch == " ":
            out.append(0x20)
        elif "!" <= ch <= "~":
            if gl != 1:
                out.append(0x0E)  # LS1
                gl = 1
            out.append(ord(ch))
        else:
            e = ch.encode("euc_jp")
            if len(e) != 2:
                raise ValueError(f"cannot encode {ch!r}")
            if gl != 0:
                out.append(0x0F)  # LS0
                gl = 0
            out += bytes([e[0] & 0x7F, e[1] & 0x7F])
    return bytes(out)


def section(table_id: int, ext: int, body: bytes, syntax: bool = True, number: int = 0, last: int = 0) -> bytes:
    if syntax:
        head = bytes([ext >> 8, ext & 0xFF, 0xC1, number, last])
        payload = head + body
        length = len(payload) + 4
        s = bytes([table_id, 0xB0 | (length >> 8), length & 0xFF]) + payload
    else:
        length = len(body) + 4
        s = bytes([table_id, 0x30 | (length >> 8), length & 0xFF]) + body
    return s + crc32_mpeg2(s).to_bytes(4, "big")


def mjd_bcd(t: dt.datetime) -> bytes:
    mjd = (t.date() - dt.date(1858, 11, 17)).days
    bcd = lambda v: ((v // 10) << 4) | (v % 10)
    return bytes([mjd >> 8, mjd & 0xFF, bcd(t.hour), bcd(t.minute), bcd(t.second)])


def dur_bcd(minutes: int) -> bytes:
    bcd = lambda v: ((v // 10) << 4) | (v % 10)
    return bytes([bcd(minutes // 60), bcd(minutes % 60), 0])


def sdt(tsid: int, onid: int, sid: int, name: str) -> bytes:
    prov = arib("BonView")
    nm = arib(name)
    desc = bytes([0x48, 3 + len(prov) + len(nm), 0x01, len(prov)]) + prov + bytes([len(nm)]) + nm
    svc = sid.to_bytes(2, "big") + bytes([0xFD, 0x80 | (len(desc) >> 8), len(desc) & 0xFF]) + desc
    body = onid.to_bytes(2, "big") + b"\xFF" + svc
    return section(0x42, tsid, body)


def eit(tsid: int, onid: int, sid: int, number: int, event_id: int, start: dt.datetime, minutes: int, title: str, text: str) -> bytes:
    t, x = arib(title), arib(text)
    sed = b"jpn" + bytes([len(t)]) + t + bytes([len(x)]) + x
    desc = bytes([0x4D, len(sed)]) + sed
    ev = event_id.to_bytes(2, "big") + mjd_bcd(start) + dur_bcd(minutes) + bytes([0x80 | (len(desc) >> 8), len(desc) & 0xFF]) + desc
    body = tsid.to_bytes(2, "big") + onid.to_bytes(2, "big") + bytes([0x01, 0x4E]) + ev
    return section(0x4E, sid, body, number=number, last=1)


def tot(now: dt.datetime) -> bytes:
    return section(0x73, 0, mjd_bcd(now) + b"\xF0\x00", syntax=False)


class Packetizer:
    def __init__(self):
        self.cc = {}

    def packets(self, pid: int, sec: bytes) -> list:
        data = b"\x00" + sec  # pointer_field
        out, first = [], True
        while data:
            chunk, data = data[:184], data[184:]
            cc = self.cc.get(pid, 0)
            self.cc[pid] = (cc + 1) & 0x0F
            head = bytes([0x47, (0x40 if first else 0) | (pid >> 8), pid & 0xFF, 0x10 | cc])
            out.append(head + chunk + b"\xFF" * (184 - len(chunk)))
            first = False
        return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out")
    ap.add_argument("--sid", type=int, default=1024)
    ap.add_argument("--tsid", type=int, default=None, help="default: sid")
    ap.add_argument("--onid", type=int, default=0x7FE0)
    ap.add_argument("--name", default="デモテレビ")
    ap.add_argument("--title", default="デモ番組")
    ap.add_argument("--text", default="BonView の動作確認用に生成したテスト映像です。")
    ap.add_argument("--next", default="次の番組")
    ap.add_argument("--start", default="2026-11-13T19:00")
    ap.add_argument("--minutes", type=int, default=60)
    ap.add_argument("--seconds", type=int, default=20, help="length of the generated stream")
    ap.add_argument("--pattern", default="testsrc2", help="ffmpeg lavfi video source (testsrc2, smptehdbars, mandelbrot…)")
    ap.add_argument("--tone", type=int, default=440)
    a = ap.parse_args()
    tsid = a.tsid if a.tsid is not None else a.sid
    start = dt.datetime.fromisoformat(a.start)

    with tempfile.NamedTemporaryFile(suffix=".ts") as tmp:
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", f"{a.pattern}=size=1440x1080:rate=30000/1001",
            "-f", "lavfi", "-i", f"sine=frequency={a.tone}:sample_rate=48000",
            "-t", str(a.seconds), "-vf", "setsar=4/3,setfield=tff",
            "-c:v", "mpeg2video", "-b:v", "12M", "-flags", "+ilme+ildct",
            "-c:a", "aac", "-ac", "2", "-b:a", "192k",
            "-mpegts_service_id", str(a.sid), "-mpegts_transport_stream_id", str(tsid),
            "-mpegts_original_network_id", str(a.onid), "-muxrate", "17M",
            "-f", "mpegts", tmp.name], check=True)
        src = open(tmp.name, "rb").read()

    pk = Packetizer()
    n = len(src) // TS
    out = bytearray()
    every = max(1, n // (a.seconds * 4))  # SI about 4×/s
    end = start + dt.timedelta(minutes=a.minutes)
    for i in range(n):
        p = src[i * TS:(i + 1) * TS]
        pid = ((p[1] & 0x1F) << 8) | p[2]
        if pid == 0x11:
            continue  # replaced by our SDT
        if i % every == 0:
            now = start + dt.timedelta(minutes=a.minutes // 3, seconds=a.seconds * i / n)
            for pid2, sec in (
                (0x11, sdt(tsid, a.onid, a.sid, a.name)),
                (0x12, eit(tsid, a.onid, a.sid, 0, 1, start, a.minutes, a.title, a.text)),
                (0x12, eit(tsid, a.onid, a.sid, 1, 2, end, 30, a.next, "")),
                (0x14, tot(now)),
            ):
                for q in pk.packets(pid2, sec):
                    out += q
        out += p
    open(a.out, "wb").write(out)
    print(f"{a.out}: {len(out) // TS} packets")


if __name__ == "__main__":
    main()
