#!/usr/bin/env python3
"""Generate a broadcast-like demo TS (test pattern + tone) with ARIB SI tables.

ffmpeg makes the A/V (MPEG-2 1440x1080i + AAC); this script then replaces ffmpeg's SDT and
adds EIT present/following and TOT, with names encoded as ARIB STD-B24 8-unit strings, so the
demo shows a station name, programme titles and a broadcast clock. Used for screenshots and for
trying BonView with scripts/mock_bdp_server.py without a tuner. With --captions it also adds an
ARIB caption stream (component_tag 0x30) with a numbered line every two seconds.

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


def nit(tsid: int, onid: int, sid: int, key: int, ts_name: str) -> bytes:
    """NIT (actual) with a TS information descriptor carrying the remote-control key."""
    name = arib(ts_name)
    tsinfo = bytes([key, (len(name) << 2) | 1]) + name + bytes([0x0F, 1]) + sid.to_bytes(2, "big")
    descs = bytes([0xCD, len(tsinfo)]) + tsinfo + bytes([0x41, 3]) + sid.to_bytes(2, "big") + b"\x01"
    loop = tsid.to_bytes(2, "big") + onid.to_bytes(2, "big") + bytes([0xF0 | (len(descs) >> 8), len(descs) & 0xFF]) + descs
    body = b"\xF0\x00" + bytes([0xF0 | (len(loop) >> 8), len(loop) & 0xFF]) + loop
    return section(0x40, onid, body)


def tot(now: dt.datetime) -> bytes:
    return section(0x73, 0, mjd_bcd(now) + b"\xF0\x00", syntax=False)


def crc16_ccitt(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def caption_pes(group_id: int, data: bytes, pts: int) -> bytes:
    """Synchronized caption PES (stream_id 0xBD) with one data group."""
    group = bytes([group_id << 2, 0, 0, len(data) >> 8, len(data) & 0xFF]) + data
    group += crc16_ccitt(group).to_bytes(2, "big")
    payload = b"\x80\xFF\xF0" + group
    p = bytes([0x21 | ((pts >> 29) & 0x0E), (pts >> 22) & 0xFF, ((pts >> 14) & 0xFE) | 1,
               (pts >> 7) & 0xFF, ((pts << 1) & 0xFE) | 1])
    body = bytes([0x80, 0x80, len(p)]) + p + payload
    return b"\x00\x00\x01\xBD" + len(body).to_bytes(2, "big") + body


def caption_units(body: bytes) -> bytes:
    unit = b"\x1F\x20" + len(body).to_bytes(3, "big") + body
    return len(unit).to_bytes(3, "big") + unit


def caption_management() -> bytes:
    # TMD free, one language: tag 0, DMF 0b1010, "jpn", format/TCS/rollup 0; no data units.
    return bytes([0x3F, 1, 0x1A]) + b"jpn" + b"\x00" + b"\x00\x00\x00"


def caption_statement(lines: list) -> bytes:
    """CS, then each line at APS(row, 6) from row 13 upwards (bottom aligned)."""
    body = bytearray(b"\x0C")
    for n, line in enumerate(lines):
        body += bytes([0x1C, 0x40 + 14 - len(lines) + n, 0x40 + 6, 0x0F]) + arib(line)  # LS0: arib() starts in G0
    return b"\x3F" + caption_units(bytes(body))


def first_pts(src: bytes, pid: int) -> int:
    for i in range(len(src) // TS):
        p = src[i * TS:(i + 1) * TS]
        if (((p[1] & 0x1F) << 8) | p[2]) != pid or not p[1] & 0x40:
            continue
        o = 4 + (1 + p[4] if p[3] & 0x20 else 0)
        h = p[o:o + 14]
        if h[:3] == b"\x00\x00\x01" and h[7] & 0x80:
            return ((h[9] >> 1) & 7) << 30 | h[10] << 22 | (h[11] >> 1) << 15 | h[12] << 7 | h[13] >> 1
    raise ValueError(f"no PTS on PID {pid:#x}")


def pmt_with_caption(sec: bytes, caption_pid: int) -> bytes:
    """Re-encode ffmpeg's PMT with an extra caption ES (stream_type 0x06, component_tag 0x30)."""
    length = ((sec[1] & 0x0F) << 8) | sec[2]
    body = sec[8:3 + length - 4]  # PCR PID … ES loop
    es = bytes([0x06, 0xE0 | (caption_pid >> 8), caption_pid & 0xFF, 0xF0, 0x03, 0x52, 0x01, 0x30])
    return section(0x02, (sec[3] << 8) | sec[4], body + es)


class Packetizer:
    def __init__(self):
        self.cc = {}

    def packets(self, pid: int, sec: bytes) -> list:
        return self._split(pid, b"\x00" + sec)  # pointer_field

    def pes(self, pid: int, pes: bytes) -> list:
        return self._split(pid, pes, stuff_af=True)

    def _split(self, pid: int, data: bytes, stuff_af: bool = False) -> list:
        out, first = [], True
        while data:
            chunk, data = data[:184], data[184:]
            cc = self.cc.get(pid, 0)
            self.cc[pid] = (cc + 1) & 0x0F
            if len(chunk) < 184 and stuff_af:
                # PES must be padded with an adaptation field, not trailing bytes.
                af = 183 - len(chunk)
                head = bytes([0x47, (0x40 if first else 0) | (pid >> 8), pid & 0xFF, 0x30 | cc, af])
                out.append(head + (b"\x00" + b"\xFF" * (af - 1) if af else b"") + chunk)
            else:
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
    ap.add_argument("--key", type=int, default=0, help="remote-control key (1–12) sent in the NIT; 0 = no NIT")
    ap.add_argument("--title", default="デモ番組")
    ap.add_argument("--text", default="BonView の動作確認用に生成したテスト映像です。")
    ap.add_argument("--next", default="次の番組")
    ap.add_argument("--start", default="2026-11-13T19:00")
    ap.add_argument("--minutes", type=int, default=60)
    ap.add_argument("--seconds", type=int, default=20, help="length of the generated stream")
    ap.add_argument("--pattern", default="testsrc2", help="ffmpeg lavfi video source (testsrc2, smptehdbars, mandelbrot…)")
    ap.add_argument("--tone", type=int, default=440)
    ap.add_argument("--captions", action="store_true", help="add an ARIB caption stream (PID 0x130)")
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
    caption_pid = 0x130
    captions = {}  # packet index → caption PES packets, muxed ~1 s ahead of their PTS
    if a.captions:
        base = first_pts(src, 0x100)
        for k in range(1, a.seconds // 2):
            lines = [f"字幕のテスト {k}"] + (["二行目も表示されます"] if k % 2 else [])
            pes = caption_pes(1, caption_statement(lines), (base + k * 2 * 90000) & ((1 << 33) - 1))
            at = max(0, int(n * (k * 2 - 1) / a.seconds))
            captions.setdefault(at, []).append(pes)
    out = bytearray()
    every = max(1, n // (a.seconds * 4))  # SI about 4×/s
    end = start + dt.timedelta(minutes=a.minutes)
    for i in range(n):
        p = src[i * TS:(i + 1) * TS]
        pid = ((p[1] & 0x1F) << 8) | p[2]
        if pid == 0x11:
            continue  # replaced by our SDT
        if a.captions and pid == 0x1000 and p[1] & 0x40:
            for q in pk.packets(0x1000, pmt_with_caption(p[5:], caption_pid)):
                out += q
            continue
        if i % every == 0:
            now = start + dt.timedelta(minutes=a.minutes // 3, seconds=a.seconds * i / n)
            tables = [
                (0x11, sdt(tsid, a.onid, a.sid, a.name)),
                (0x12, eit(tsid, a.onid, a.sid, 0, 1, start, a.minutes, a.title, a.text)),
                (0x12, eit(tsid, a.onid, a.sid, 1, 2, end, 30, a.next, "")),
                (0x14, tot(now)),
            ]
            if a.key:
                tables.append((0x10, nit(tsid, a.onid, a.sid, a.key, a.name)))
            if a.captions:
                tables.append((caption_pid, None))
            for pid2, sec in tables:
                if sec is None:  # caption management data, PTS-less is fine (TMD free)
                    for q in pk.pes(caption_pid, caption_pes(0, caption_management(), 0)):
                        out += q
                    continue
                for q in pk.packets(pid2, sec):
                    out += q
        for pes in captions.pop(i, []):
            for q in pk.pes(caption_pid, pes):
                out += q
        out += p
    open(a.out, "wb").write(out)
    print(f"{a.out}: {len(out) // TS} packets")


if __name__ == "__main__":
    main()
