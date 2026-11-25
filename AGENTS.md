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
- Decoding is **FFmpeg + VideoToolbox**: a minimal LGPL FFmpeg built by `scripts/build_ffmpeg.sh` and
  bundled as dylibs in `BonView.app/Contents/Frameworks`. Don't enable GPL/nonfree parts.
- User-facing strings are **Japanese**. Code comments and identifiers are **English**.
- Don't use the name "TVTest" in the product, UI or identifiers.

## Commands

```bash
scripts/build_ffmpeg.sh        # bundled LGPL FFmpeg → build/ffmpeg (once; bundle.sh runs it too)
swift build                    # all targets (FFmpeg from build/ffmpeg; override with FFMPEG_PREFIX)
swift test                     # unit + integration tests; decode/scan tests need the ffmpeg CLI (FFMPEG_CLI=…)
scripts/bundle.sh              # build/BonView.app (release, ad-hoc signed, FFmpeg in Contents/Frameworks)
scripts/package_release.sh     # build/release/: app zip + FFmpeg source tarball + notes (attach all to the release)
                               # Developer ID: keychain cert, or DEVELOPMENT_TEAM=… (Xcode cloud signing via a
                               # synthesized .xcarchive + -exportArchive); notarizes with NOTARY_PROFILE=…; else ad-hoc
scripts/build_ios.sh           # iOS app: FFmpeg XCFrameworks (build_ffmpeg_ios.sh) → XcodeGen → Simulator build
                               # GENERATE_ONLY=1 stops after iOS/BonView-iOS.xcodeproj; DESTINATION=device for iphoneos
swift scripts/make_icon.swift  # regenerate macOS/Resources/AppIcon.icns, Resources/AppIcon.png and the iOS app icon
scripts/mock_bdp_server.py --port 1192 --tunnel-port 1193 --origin PT-T a.ts b.ts   # fake server
swift run bdpcat -a 127.0.0.1 -d X --list | --scan | --space 0 --channel 0 -t 5 --info
```

With `FFMPEG_PREFIX` pointing at Homebrew, "ld: warning … built for newer macOS" linker warnings are expected.
When bumping FFmpeg, update `FFMPEG_VERSION`/`FFMPEG_SHA256` in `build_ffmpeg.sh` and the README
(`build_ffmpeg_ios.sh` reads them from there).

## Layout

| Path | Notes |
|---|---|
| `Sources/BonDriver` | `BonDriver` protocol (IBonDriver1–3 in Swift, push-style `tsHandler`). `ProxyClient` + `ProxyProtocol` (BdpPacket: 8-byte header, big-endian body length, UTF-16LE wide strings; header byte 2 bit0 = B25 request). `TunnelClient` (little-endian 16-byte commands, `Crea`/`Conn` handshake, `GTsS` polling, reconnect with same sequence number). `Socket.swift` is a small blocking BSD-socket wrapper. |
| `Sources/TSCore` | Packet splitter with resync, section assembler + CRC32, PAT/PMT/SDT/EIT p/f/TOT, PES, ARIB STD-B24 8-unit strings, `EPG.swift` (`EPGStore`: events per service, overlapping events replaced, extended items merged; `EITScheduleProgress`; thread-safe `EPGCollector` that skips sections already seen with the same CRC), captions (`Caption.swift`: data group/unit parsing, `CaptionScreen` layout engine → `CaptionFrame` glyphs in plane dots, CLUT, DRCS; vertical writing / flashing / TIME not modelled), `TSDemuxer`. Not thread-safe: drive from one queue. |
| `Sources/CFFmpeg` | C wrapper (`tvffmpeg.h`) so Swift never touches FFmpeg structs. On iOS it links the `build/ffmpeg-ios/lib*.xcframework` binary targets, which `Package.swift` declares only when they exist. Parser → decoder → (bwdif for MPEG-2) → NV12 `CVPixelBuffer`; audio → swresample float stereo. The FFmpeg dylibs are **weak-linked** (`-weak-l…` in `Package.swift`); `tv_ffmpeg_missing_libraries()` / `FFmpegAvailability` report missing ones and `macOS/BonView/FFmpegMissingAlert` shows install steps and quits at launch. Never call into `tvffmpeg.h` before that check. |
| `Sources/MediaCore` | `TSPlayer` (serial queue pipeline, PTS unwrapping, status), `AVPresenter` (`AVSampleBufferRenderSynchronizer`, anchors on first audio PTS − 0.4 s, re-anchors on underrun / > 2.5 s buffered; `currentFrame()` via `FrameHistory` for screenshots), `FrameSnapshot` (pixel buffer → display-size `CGImage`, PNG/JPEG). The app composites captions with `ImageRenderer` in `macOS/BonView/Screenshot.swift`. |
| `Sources/ChannelScan` | `EPGGrabber`: walks scanned channels on its own `BonDriver`, feeding an `EPGCollector`, moving on when every visible service's basic schedule is complete (`EITScheduleProgress`: all segments of tables 0x50–0x57 / 0x60–0x67 up to last_table_id), on stall (20 s without a new section) or after 180 s; channels whose services are already complete are skipped (BS/CS carry the network's schedule on every TS). `ChannelScanner`: tunes each channel, waits for PAT + SDT names + NIT (or gives up after ~1.5 s without PAT and without signal). `ScannedChannel.threeDigitNumber` (remote key × 10 + (SID & 7) + 1; BS/CS: SID) and `duplicateNameServiceIDs` (sub-channels auto-hidden on first scan). |
| `macOS/BonView` | macOS SwiftUI app (SwiftPM target `BonView`; `macOS/Resources` holds its `Info.plist` — version and build number —, `AppIcon.icns` and `Credits.html`). `Shared` inside it is a symlink to `/Shared`. Shared code: `ProgramGuide.swift` (background EPG grab on a second connection with `channelLock = 0`, passive `EPGCollector` on the viewing stream, tuner-sharing guard, JSON persistence) and `ProgramGuideView` (番組表 window, broadcast day 04:00–28:00 JST). `AppModel` (@Observable, main-thread state; all BonDriver calls on `driverQueue`), `ServerProfile`/`Preferences` (UserDefaults), views. |
| `Shared/` | App code shared by the macOS and iOS apps: `AppModel` (window sizing / full screen / screenshot folder are `#if os(macOS)`), `ServerProfile`/`Preferences`, `ProgramGuide(View)`, `CaptionPlaneView`, `CaptionOverlay`, `EventFormat`, `InfoPanel`, `ProfileEditor`, `TSFileSource`. Keep AppKit out of these files (or behind `#if os(macOS)`). |
| `iOS/` | iOS / iPadOS app. `project.yml` (XcodeGen; target `BonViewiOS`, product BonView, iOS 17, arm64 only) compiles `iOS/BonView/*` + `Shared/` against the package products. `PlayerScreen` (portrait: picture + `ControlBar` + `PanelView`; iPhone landscape: full screen with auto-hiding controls; iPad landscape: side panel), `SettingsScreen`, `ChannelScanScreen`. Keeps playing audio in the background (`UIBackgroundModes` audio, video decoding paused via `TSPlayer.setVideoEnabled`; `NowPlaying` handles the audio session, Control Center info and remote commands — pause disconnects, next/previous track change channel); with that setting off it disconnects and reconnects on return. `PictureInPicture` puts the display layer in a PiP window (live UI, starts automatically on leaving the app while playing; captions are SwiftUI overlays and are not shown there; the iPhone Simulator reports PiP unsupported, use the iPad one). The generated `.xcodeproj` is not checked in. |
| `Sources/SettingsSync` | `SettingsSync`: mirrors selected keys between UserDefaults and `NSUbiquitousKeyValueStore` (first-run / account-change merge where iCloud wins except keys with a merge function; local writes mirrored only when different; remote changes and removals applied). Store-agnostic (`KeyValueStore`), tested with in-memory stores. The app side is `Shared/CloudSettings.swift` (which keys, server-list union, notification handling) and `AppModel.applyCloudChanges`. |
| `Sources/bdpcat` | CLI client. |
| `Tests/*` | Swift Testing. `MockProxyServer`/`MockTunnelServer` speak the real protocols in-process; `DecodeTests`/`ChannelScanTests` generate TS with the ffmpeg CLI and skip when it is missing. |
| `scripts/` | `bundle.sh` (ad-hoc signs unless `SIGN_IDENTITY` is set, then hardened runtime + timestamp, no entitlements; copies the `@rpath` FFmpeg dylibs into Contents/Frameworks, drops the build-tree rpath, writes `Contents/Resources/Credits.html` (About panel) from `macOS/Resources/Credits.html` and copies `LICENSE` + `Resources/Licenses/` into `Contents/Resources/Licenses`), `build_ffmpeg.sh`, `package_release.sh` (LGPL: the FFmpeg source ships with every binary release), `make_icon.swift`, `mock_bdp_server.py`, `make_demo_ts.py` (test-pattern TS with ARIB SDT/EIT/TOT, used for README screenshots). |
| `docs/images/` | README screenshots. Only use generated demo streams — never real broadcast footage. |

## Things that have bitten us

- **Swift exclusivity:** `self.scan?.x = self.scan?.y` on an `@Observable` property aborts at runtime.
  Copy to a local, mutate, assign back.
- **The EPG grab uses a second server connection.** With one tuner (or equal channel-lock priorities)
  BonDriverProxyEx may move the viewer's tuner; `checkTunerSharing` cancels the grab and retunes when the
  viewing stream's EIT p/f TSID turns into the channel being grabbed.
- **Copy-on-write in assembler dictionaries:** `var asm = dict[pid]; asm.push(…); dict[pid] = asm` keeps two
  references to the buffer, so every append copies the whole PES/section. Use `dict.removeValue(forKey:)`, mutate,
  and put it back (`TSDemuxer`, `EPGCollector`).
- **Captions and TS are untrusted input.** Caption CSI parameters are clamped to the plane, cells are at least
  one dot and RPC 0 is bounded by the line width; `PESAssembler` drops PES over `maxSize`.
- **`tsHandler` is read on the driver's receive thread.** Don't reassign it while streaming; `AppModel`
  routes through `TSRouter` (lock-protected) to switch between player and scanner.
- **AAC PES contain several frames; only the first gets a PTS.** `tvffmpeg.c` continues the timeline
  for frames without PTS (`nextAudioPts`). Dropping them causes choppy audio.
- **Error counters start after the first PAT** following a reset, so retune garbage isn't counted.
  The "scrambled" banner uses the selected service's PIDs over the last second only.
- **Captions are timed against `AVPresenter.clockSeconds`**, checked after every input chunk in `TSPlayer`;
  nothing is shown while the presenter is not anchored. Caption statements start with the caption G-set
  defaults (G3 = macro), not the SI defaults, and re-initialise the writing format (SWF from the
  management data) while keeping glyphs until CS. Colours resolve against the palette at designation time.
  Superimpose (component_tag 0x38–0x3F) uses a second `CaptionDecoder` and is drawn regardless of the caption toggle.
  `Shared/CaptionPlaneView` renders frames (Canvas); `scripts/make_demo_ts.py --captions` exercises it.
- **Persisted settings** use UserDefaults keys `profiles`, `currentProfile`, `lastChannel.<uuid>`,
  `lastServices.<uuid>` (dictionary "<space>-<ch>" → SID; older `lastService.<uuid>.<space>-<ch>` keys are still read), `scan.<uuid>`, `showCaptions`, `captionStyle`, `screenshotFolder` / `screenshotFormat` / `screenshotIncludesCaptions`, `channelOrder.<uuid>` / `hiddenChannels.<uuid>` / `knownChannels.<uuid>`
  (entry IDs `<space>-<ch>-<sid>`; ordering logic in `ChannelListOrder`), `epgAutoGrab`, `backgroundPlayback` (iOS), `iCloudSync` / `iCloudSyncInitialized` (local only), `epgLastGrab.<uuid>`, `deinterlaceMode` (`DeinterlaceMode` raw value; falls back to the older `deinterlace` bool).
  Programme guide data is not in UserDefaults: `~/Library/Application Support/BonView/EPG/<uuid>.json` (`EPGStore` Codable, tagged with `ARIBString.decoderRevision`; bump it when decoded text changes so stale files are dropped and re-grabbed). `ProxyConfig`/`ServerProfile` decode old data with
  `decodeIfPresent` defaults — keep that when adding fields.
- **iCloud settings sync:** write synced settings with `Preferences.set` (never `UserDefaults.standard.set`
  directly) so they reach iCloud; the synced key list is `CloudSettings.isSynced`. Keep values small (KVS:
  1 MB total, 1024 keys) — guide data never goes there. The entitlement is only added when a team is known
  (`ICLOUD_TEAM` in bundle.sh, the iOS `.entitlements`): an ad-hoc Mac build with it would not launch.
- **Anything that changes `AppModel.epg` or `broadcastTime` re-renders the whole 番組表 grid and channel list**
  (Japanese line breaking is expensive). Guide data goes through `queueEPG` / `publishEPG` (merged at most every
  10 s); views that only need the minute use `programClock`, not `broadcastTime`.
- Wire-format details are documented at the top of `ProxyProtocol.swift` and `TunnelClient.swift`;
  update those comments together with the code.

## Conventions

- Version bumps: `CFBundleShortVersionString` / `CFBundleVersion` in `macOS/Resources/Info.plist` and
  `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `iOS/project.yml` (keep them equal).

- Swift 6 toolchain, `swiftLanguageModes: [.v5]`, macOS 14 deployment target.
- Prefer small, focused changes; add/adjust tests next to the code you change (protocol changes →
  mock server tests; TS/PSI → `TSCoreTests`; decode/timing → `DecodeTests`).
- Run `swift test` before handing work back; for UI changes also run `scripts/bundle.sh` and try the
  app against `mock_bdp_server.py`. Changes under `Shared/` must also build for iOS
  (`scripts/build_ios.sh`); the iOS Simulator reaches the mock server at 127.0.0.1.

## Privacy / repository hygiene

- Never commit real server addresses, MAC addresses, `.ini`/`.conf` files, recorded `.ts` files, crash
  reports or personal paths. Use documentation addresses (`192.168.0.x`, `127.0.0.1`) and placeholders.
- `.gitignore` already excludes these; check `git status` before committing.
- New third-party code or data in the binary → add its notice to `Resources/Licenses/` and `macOS/Resources/Credits.html` (the iOS licence screen is `iOS/BonView/SettingsScreen.swift`).
