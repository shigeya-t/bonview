#!/usr/bin/env python3
"""Generate a broadcast-like demo TS (test pattern + tone) with ARIB SI tables.

ffmpeg makes the A/V (MPEG-2 1440x1080i + AAC); this script then replaces ffmpeg's SDT and
adds EIT present/following and TOT, with names encoded as ARIB STD-B24 8-unit strings, so the
demo shows a station name, programme titles and a broadcast clock. Used for screenshots and for
trying BonView with scripts/mock_bdp_server.py without a tuner. --schedule-days adds an EIT
schedule (programme guide) with sample programmes. With --captions it also adds an
ARIB caption stream (component_tag 0x30) with a numbered line every two seconds — positioned like
a broadcast (960×540 plane), with colour, ruby and a DRCS glyph — plus a superimpose (0x38).

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


SCHEDULE_TITLES = [
    ("朝のニュース", 0x0), ("情報ワイド", 0x2), ("連続ドラマ", 0x3), ("音楽の時間", 0x4), ("バラエティ特番", 0x5),
    ("映画劇場", 0x6), ("アニメ", 0x7), ("ドキュメンタリー", 0x8), ("スポーツ中継", 0x1), ("天気予報", 0x0),
]


def schedule_event(event_id: int, start: dt.datetime, minutes: int, title: str, genre: int, text: str) -> bytes:
    t, x = arib(title), arib(text)
    sed = b"jpn" + bytes([len(t)]) + t + bytes([len(x)]) + x
    head, body = arib("出演者"), arib("デモ　太郎、サンプル　花子")
    items = bytes([len(head)]) + head + bytes([len(body)]) + body
    eed = bytes([0x00]) + b"jpn" + bytes([len(items)]) + items + b"\x00"
    desc = bytes([0x4D, len(sed)]) + sed + bytes([0x54, 2, genre << 4, 0xFF]) + bytes([0x4E, len(eed)]) + eed
    return event_id.to_bytes(2, "big") + mjd_bcd(start) + dur_bcd(minutes) + bytes([0x80 | (len(desc) >> 8), len(desc) & 0xFF]) + desc


def eit_schedule(tsid: int, onid: int, sid: int, day0: dt.datetime, days: int, seed: int) -> list:
    """EIT schedule actual (table 0x50, days 0–3): one section per 3-hour segment, programmes of
    30–120 minutes back to back from day0 00:00. Returns the sections."""
    lengths = [30, 60, 60, 90, 120, 30, 60]
    events, t, n = [], day0, 0
    while t < day0 + dt.timedelta(days=days):
        title, genre = SCHEDULE_TITLES[(n + seed) % len(SCHEDULE_TITLES)]
        minutes = lengths[(n * 3 + seed) % len(lengths)]
        events.append((0x1000 + n, t, minutes, title, genre))
        t += dt.timedelta(minutes=minutes)
        n += 1
    segments = days * 8
    out = []
    for seg in range(segments):
        lo = day0 + dt.timedelta(hours=3 * seg)
        hi = lo + dt.timedelta(hours=3)
        evs = b"".join(schedule_event(eid, st, m, f"{ti}", g, f"{st:%H:%M} からの{ti}です。")
                       for eid, st, m, ti, g in events if lo <= st < hi)
        body = tsid.to_bytes(2, "big") + onid.to_bytes(2, "big") + bytes([seg * 8, 0x50]) + evs
        out.append(section(0x50, sid, body, number=seg * 8, last=(segments - 1) * 8))
    return out


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
    """Synchronized caption PES (stream_id 0xBD) with one data group; pts None → asynchronous PES (0xBF)."""
    group = bytes([group_id << 2, 0, 0, len(data) >> 8, len(data) & 0xFF]) + data
    group += crc16_ccitt(group).to_bytes(2, "big")
    if pts is None:
        payload = b"\x81\xFF\xF0" + group
        return b"\x00\x00\x01\xBF" + len(payload).to_bytes(2, "big") + payload
    payload = b"\x80\xFF\xF0" + group
    p = bytes([0x21 | ((pts >> 29) & 0x0E), (pts >> 22) & 0xFF, ((pts >> 14) & 0xFE) | 1,
               (pts >> 7) & 0xFF, ((pts << 1) & 0xFE) | 1])
    body = bytes([0x80, 0x80, len(p)]) + p + payload
    return b"\x00\x00\x01\xBD" + len(body).to_bytes(2, "big") + body


def caption_units(body: bytes, drcs: bytes = b"") -> bytes:
    units = b""
    if drcs:
        units += b"\x1F\x30" + len(drcs).to_bytes(3, "big") + drcs
    units += b"\x1F\x20" + len(body).to_bytes(3, "big") + body
    return len(units).to_bytes(3, "big") + units


def caption_management() -> bytes:
    # TMD free, one language: tag 0, DMF 0b1010, "jpn", format 7 (960×540 horizontal); no data units.
    return bytes([0x3F, 1, 0x1A]) + b"jpn" + b"\x70" + b"\x00\x00\x00"


def csi(params: str, final: int) -> bytes:
    return b"\x9B" + params.encode() + bytes([0x20, final])


# Display area like HD broadcasts: 620×480 at (170, 30), 36×36 characters, cells 40×60.
CAPTION_HEADER = (csi("7", 0x53) + csi("620;480", 0x56) + csi("170;30", 0x5F)
                  + csi("36;36", 0x57) + csi("4", 0x58) + csi("24", 0x59))

# DRCS-1 0x21: a 16×16 two-level musical note, sent with every statement that uses it.
NOTE = [
    "0000000111111100", "0000000111111111", "0000000110000011", "0000000110000011",
    "0000000110000011", "0000000110000011", "0000000110000011", "0000000110000011",
    "0000000110000011", "0000000110000011", "0011111110001111", "0111111110011111",
    "0111111110011111", "0011111100001110", "0000000000000000", "0000000000000000",
]


def drcs_note() -> bytes:
    bits = "".join(NOTE)
    pattern = bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))
    return bytes([1, 0x41, 0x21, 1, 0x00, 0, 16, 16]) + pattern


def acps(x: int, y: int) -> bytes:
    return csi(f"{x};{y}", 0x61)


def caption_statement(k: int) -> bytes:
    """Bottom two rows of the area, centred. Odd k: ruby over 字幕 and a yellow second line;
    even k: a DRCS note after the text."""
    body = bytearray(b"\x0C" + CAPTION_HEADER)
    line1 = f"字幕のテスト {k}"
    w = 40 * len(line1) + (40 if k % 2 == 0 else 0)
    x = 170 + (620 - w) // 2
    if k % 2:
        line2 = "二行目は黄色で表示します"
        x2 = 170 + (620 - 40 * len(line2)) // 2
        # Ruby (SSZ, 20×30 cells) above 字幕, then the two lines (lower-left reference points).
        body += acps(x + 10, 407) + b"\x88\x0F" + arib("じまく") + b"\x8A"
        body += acps(x, 449) + b"\x0F" + arib(line1)
        body += acps(x2, 509) + b"\x83\x0F" + arib(line2) + b"\x87"
    else:
        body += acps(x, 509) + b"\x0F" + arib(line1)
        body += b"\x1B\x28\x20\x41\x0F\x21"  # G0 = DRCS-1, LS0, note
    return b"\x3F" + caption_units(bytes(body), drcs_note() if k % 2 == 0 else b"")


def superimpose_statement(text: str) -> bytes:
    """Top-left banner: half-opacity black background (palette 4), white text."""
    body = (b"\x0C" + CAPTION_HEADER + csi("960;540", 0x56) + csi("0;0", 0x5F) + acps(40, 80)
            + b"\x90\x20\x44\x90\x50\x90\x20\x40\x87\x0F" + arib(text))
    return b"\x3F" + caption_units(body)


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


def pmt_with_caption(sec: bytes, caption_pid: int, superimpose_pid: int) -> bytes:
    """Re-encode ffmpeg's PMT with caption (component_tag 0x30) and superimpose (0x38) ES."""
    length = ((sec[1] & 0x0F) << 8) | sec[2]
    body = sec[8:3 + length - 4]  # PCR PID … ES loop
    es = bytes([0x06, 0xE0 | (caption_pid >> 8), caption_pid & 0xFF, 0xF0, 0x03, 0x52, 0x01, 0x30])
    es += bytes([0x06, 0xE0 | (superimpose_pid >> 8), superimpose_pid & 0xFF, 0xF0, 0x03, 0x52, 0x01, 0x38])
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
    ap.add_argument("--schedule-days", type=int, default=0, help="add EIT schedule (table 0x50) for this many days (≤ 4)")
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
    caption_pid, superimpose_pid = 0x130, 0x138
    captions = {}  # packet index → caption PES packets, muxed ~1 s ahead of their PTS
    if a.captions:
        base = first_pts(src, 0x100)
        for k in range(1, a.seconds // 2):
            pes = caption_pes(1, caption_statement(k), (base + k * 2 * 90000) & ((1 << 33) - 1))
            at = max(0, int(n * (k * 2 - 1) / a.seconds))
            captions.setdefault(at, []).append((caption_pid, pes))
        # Superimpose: shown at once (asynchronous PES), cleared a few seconds later.
        for t, text in ((4, "ニュース速報　これは文字スーパーのテストです"), (min(9, a.seconds - 1), None)):
            data = superimpose_statement(text) if text else b"\x3F" + caption_units(b"\x0C")
            captions.setdefault(int(n * t / a.seconds), []).append((superimpose_pid, caption_pes(1, data, None)))
    out = bytearray()
    every = max(1, n // (a.seconds * 4))  # SI about 4×/s
    day0 = start.replace(hour=0, minute=0, second=0, microsecond=0)
    schedule = eit_schedule(tsid, a.onid, a.sid, day0, min(a.schedule_days, 4), a.sid) if a.schedule_days else []
    tick = 0
    end = start + dt.timedelta(minutes=a.minutes)
    for i in range(n):
        p = src[i * TS:(i + 1) * TS]
        pid = ((p[1] & 0x1F) << 8) | p[2]
        if pid == 0x11:
            continue  # replaced by our SDT
        if a.captions and pid == 0x1000 and p[1] & 0x40:
            for q in pk.packets(0x1000, pmt_with_caption(p[5:], caption_pid, superimpose_pid)):
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
            if schedule:  # a few schedule sections per tick, round robin
                for k in range(4):
                    tables.append((0x12, schedule[(tick * 4 + k) % len(schedule)]))
            tick += 1
            if a.captions:
                tables.append((caption_pid, None))
            for pid2, sec in tables:
                if sec is None:  # caption management data, PTS-less is fine (TMD free)
                    for q in pk.pes(caption_pid, caption_pes(0, caption_management(), 0)):
                        out += q
                    continue
                for q in pk.packets(pid2, sec):
                    out += q
        for pid2, pes in captions.pop(i, []):
            for q in pk.pes(pid2, pes):
                out += q
        out += p
    open(a.out, "wb").write(out)
    print(f"{a.out}: {len(out) // TS} packets")


if __name__ == "__main__":
    main()
