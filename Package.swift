// swift-tools-version:6.0
import PackageDescription

// FFmpeg is taken from Homebrew (`brew install ffmpeg`). Override with FFMPEG_PREFIX if needed.
let ffmpegPrefix = Context.environment["FFMPEG_PREFIX"] ?? "/opt/homebrew/opt/ffmpeg"

let package = Package(
    name: "BonView",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BonView", targets: ["BonView"]),
        .executable(name: "bdpcat", targets: ["bdpcat"]),
        .library(name: "BonDriver", targets: ["BonDriver"]),
        .library(name: "TSCore", targets: ["TSCore"]),
    ],
    targets: [
        // Thin C layer over libavcodec/libavfilter/libswresample so Swift never touches FFmpeg structs.
        // The FFmpeg dylibs are weak-linked so the app still launches without them and can tell the
        // user to install FFmpeg (`tv_ffmpeg_missing_libraries`) instead of dyld aborting.
        .target(
            name: "CFFmpeg",
            cSettings: [.unsafeFlags(["-I\(ffmpegPrefix)/include"])],
            linkerSettings: [
                .unsafeFlags(["-L\(ffmpegPrefix)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(ffmpegPrefix)/lib"]
                    + ["avcodec", "avutil", "avfilter", "swresample", "swscale"].flatMap { ["-Xlinker", "-weak-l\($0)"] }),
                .linkedFramework("CoreVideo"), .linkedFramework("CoreFoundation"),
            ]
        ),
        // IBonDriver abstraction + BonDriver_Proxy client (BonDriverProxy protocol compatible).
        .target(name: "BonDriver"),
        // MPEG-2 TS demux, PSI/SI tables and ARIB STD-B24 strings.
        .target(name: "TSCore"),
        // Decoding (FFmpeg/VideoToolbox) and A/V presentation (AVSampleBufferRenderSynchronizer).
        .target(name: "MediaCore", dependencies: ["CFFmpeg", "TSCore"]),
        // Channel scan (tune every channel, collect TSID/services from PAT/PMT/SDT).
        .target(name: "ChannelScan", dependencies: ["BonDriver", "TSCore"]),
        .executableTarget(name: "BonView", dependencies: ["BonDriver", "TSCore", "MediaCore", "ChannelScan"]),
        .executableTarget(name: "bdpcat", dependencies: ["BonDriver", "TSCore", "ChannelScan"]),
        .testTarget(name: "BonDriverTests", dependencies: ["BonDriver"]),
        .testTarget(name: "TSCoreTests", dependencies: ["TSCore"]),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore", "TSCore"]),
        .testTarget(name: "ChannelScanTests", dependencies: ["ChannelScan", "BonDriver", "TSCore"]),
    ],
    swiftLanguageModes: [.v5]
)
