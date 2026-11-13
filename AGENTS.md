# AGENTS.md

Guidance for AI coding agents (and humans) working on this repository.

## What this is

BonView is a native macOS viewer for Japanese digital TV (ISDB-T/S). It connects over the LAN to a
BonDriver server running on Windows/Linux — **BonDriverProxy(Ex)** (BdpPacket protocol, port 1192) or
**BonDriverTunnel** (xtne6f, port 1193) — and demuxes/decodes/presents the MPEG-2 TS locally.

Scope decisions (keep them unless the maintainer says otherwise):

- **Client only.** No BonDriver server and no local tuner drivers on macOS.
- **No descrambling (ARIB STD-B25) on the Mac.** The server does it. Only the HaijinW BonDriverProxyEx
  "please descramble" request bit is sent.
- Decoding is **FFmpeg + VideoToolbox** (Homebrew FFmpeg, dynamically linked).
- User-facing strings are **Japanese**. Code comments and identifiers are **English**.
- Don't use the name "TVTest" in the product, UI or identifiers.

## Commands

```bash
swift build                    # all targets (needs `brew install ffmpeg`; override with FFMPEG_PREFIX)
swift test                     # unit + integration tests; decode/scan tests need the ffmpeg CLI
scripts/bundle.sh              # build/BonView.app (release, ad-hoc signed)
swift scripts/make_icon.swift  # regenerate Resources/AppIcon.{icns,png}
scripts/mock_bdp_server.py --port 1192 --tunnel-port 1193 --origin PT-T a.ts b.ts   # fake server
swift run bdpcat -a 127.0.0.1 -d X --list | --scan | --space 0 --channel 0 -t 5 --info
```

The "ld: warning … built for newer macOS" linker warnings come from Homebrew's dylibs and are expected.

## Layout

| Path | Notes |
|---|---|
| `Sources/BonDriver` | `BonDriver` protocol (IBonDriver1–3 in Swift, push-style `tsHandler`). `ProxyClient` + `ProxyProtocol` (BdpPacket: 8-byte header, big-endian body length, UTF-16LE wide strings; header byte 2 bit0 = B25 request). `TunnelClient` (little-endian 16-byte commands, `Crea`/`Conn` handshake, `GTsS` polling, reconnect with same sequence number). `Socket.swift` is a small blocking BSD-socket wrapper. |
| `Sources/TSCore` | Packet splitter with resync, section assembler + CRC32, PAT/PMT/SDT/EIT p/f/TOT, PES, ARIB STD-B24 8-unit strings, `TSDemuxer`. Not thread-safe: drive from one queue. |
| `Sources/CFFmpeg` | C wrapper (`tvffmpeg.h`) so Swift never touches FFmpeg structs. Parser → decoder → (bwdif for MPEG-2) → NV12 `CVPixelBuffer`; audio → swresample float stereo. |
| `Sources/MediaCore` | `TSPlayer` (serial queue pipeline, PTS unwrapping, status), `AVPresenter` (`AVSampleBufferRenderSynchronizer`, anchors on first audio PTS − 0.4 s, re-anchors on underrun / > 2.5 s buffered). |
| `Sources/ChannelScan` | `ChannelScanner`: tunes each channel, waits for PAT + SDT names (or gives up after ~1.5 s without PAT and without signal). |
| `Sources/BonView` | SwiftUI app. `AppModel` (@Observable, main-thread state; all BonDriver calls on `driverQueue`), `ServerProfile`/`Preferences` (UserDefaults), views. |
| `Sources/bdpcat` | CLI client. |
| `Tests/*` | Swift Testing. `MockProxyServer`/`MockTunnelServer` speak the real protocols in-process; `DecodeTests`/`ChannelScanTests` generate TS with the ffmpeg CLI and skip when it is missing. |
| `scripts/` | `bundle.sh`, `make_icon.swift`, `mock_bdp_server.py`, `make_demo_ts.py` (test-pattern TS with ARIB SDT/EIT/TOT, used for README screenshots). |
| `docs/images/` | README screenshots. Only use generated demo streams — never real broadcast footage. |

## Things that have bitten us

- **Swift exclusivity:** `self.scan?.x = self.scan?.y` on an `@Observable` property aborts at runtime.
  Copy to a local, mutate, assign back.
- **`tsHandler` is read on the driver's receive thread.** Don't reassign it while streaming; `AppModel`
  routes through `TSRouter` (lock-protected) to switch between player and scanner.
- **AAC PES contain several frames; only the first gets a PTS.** `tvffmpeg.c` continues the timeline
  for frames without PTS (`nextAudioPts`). Dropping them causes choppy audio.
- **Error counters start after the first PAT** following a reset, so retune garbage isn't counted.
  The "scrambled" banner uses the selected service's PIDs over the last second only.
- **Persisted settings** use UserDefaults keys `profiles`, `currentProfile`, `lastChannel.<uuid>`,
  `lastService.<uuid>.<space>-<ch>`, `scan.<uuid>`, `channelOrder.<uuid>` / `hiddenChannels.<uuid>`
  (entry IDs `<space>-<ch>-<sid>`; ordering logic in `ChannelListOrder`). `ProxyConfig`/`ServerProfile` decode old data with
  `decodeIfPresent` defaults — keep that when adding fields.
- Wire-format details are documented at the top of `ProxyProtocol.swift` and `TunnelClient.swift`;
  update those comments together with the code.

## Conventions

- Swift 6 toolchain, `swiftLanguageModes: [.v5]`, macOS 14 deployment target.
- Prefer small, focused changes; add/adjust tests next to the code you change (protocol changes →
  mock server tests; TS/PSI → `TSCoreTests`; decode/timing → `DecodeTests`).
- Run `swift test` before handing work back; for UI changes also run `scripts/bundle.sh` and try the
  app against `mock_bdp_server.py`.

## Privacy / repository hygiene

- Never commit real server addresses, MAC addresses, `.ini`/`.conf` files, recorded `.ts` files, crash
  reports or personal paths. Use documentation addresses (`192.168.0.x`, `127.0.0.1`) and placeholders.
- `.gitignore` already excludes these; check `git status` before committing.
