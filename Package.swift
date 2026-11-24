// swift-tools-version:6.0
import Foundation
import PackageDescription

// FFmpeg: the minimal LGPL build from `scripts/build_ffmpeg.sh` (build/ffmpeg), bundled into the
// app by bundle.sh. Override with FFMPEG_PREFIX (e.g. `$(brew --prefix ffmpeg)`) to use another build.
let ffmpegPrefix = Context.environment["FFMPEG_PREFIX"] ?? "\(Context.packageDirectory)/build/ffmpeg"

// iOS: the same FFmpeg as dynamic-framework XCFrameworks from `scripts/build_ffmpeg_ios.sh`
// (build/ffmpeg-ios). They are only declared when present, so macOS builds don't need them.
let ffmpegLibraries = ["avcodec", "avutil", "avfilter", "swresample", "swscale"]
let iosFFmpegDir = "build/ffmpeg-ios"
let iosFFmpegTargets: [Target] = ffmpegLibraries.compactMap { lib in
    let path = "\(iosFFmpegDir)/lib\(lib).xcframework"
    guard FileManager.default.fileExists(atPath: "\(Context.packageDirectory)/\(path)") else { return nil }
    return .binaryTarget(name: "lib\(lib)", path: path)
}

let package = Package(
    name: "BonView",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "BonView", targets: ["BonView"]),
        .executable(name: "bdpcat", targets: ["bdpcat"]),
        .library(name: "BonDriver", targets: ["BonDriver"]),
        .library(name: "TSCore", targets: ["TSCore"]),
        .library(name: "MediaCore", targets: ["MediaCore"]),
        .library(name: "ChannelScan", targets: ["ChannelScan"]),
        .library(name: "SettingsSync", targets: ["SettingsSync"]),
    ],
    targets: [
        // Thin C layer over libavcodec/libavfilter/libswresample so Swift never touches FFmpeg structs.
        // The FFmpeg dylibs are weak-linked so the app still launches without them and can tell the
        // user to install FFmpeg (`tv_ffmpeg_missing_libraries`) instead of dyld aborting.
        .target(
            name: "CFFmpeg",
            dependencies: iosFFmpegTargets.map { .target(name: $0.name, condition: .when(platforms: [.iOS])) },
            cSettings: [.unsafeFlags(["-I\(ffmpegPrefix)/include"], .when(platforms: [.macOS]))],
            linkerSettings: [
                // rpath: Contents/Frameworks inside BonView.app, the prefix for `swift run` / `swift test`.
                .unsafeFlags(["-L\(ffmpegPrefix)/lib",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", "\(ffmpegPrefix)/lib"]
                    + ffmpegLibraries.flatMap { ["-Xlinker", "-weak-l\($0)"] },
                    .when(platforms: [.macOS])),
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
        // Mirrors selected settings between UserDefaults and iCloud (NSUbiquitousKeyValueStore).
        .target(name: "SettingsSync"),
        // macOS app. macOS/BonView/Shared is a symlink to Shared/, the app code the iOS app
        // (iOS/project.yml) compiles too.
        .executableTarget(name: "BonView", dependencies: ["BonDriver", "TSCore", "MediaCore", "ChannelScan", "SettingsSync"],
                          path: "macOS/BonView"),
        .executableTarget(name: "bdpcat", dependencies: ["BonDriver", "TSCore", "ChannelScan"]),
        .testTarget(name: "BonDriverTests", dependencies: ["BonDriver"]),
        .testTarget(name: "TSCoreTests", dependencies: ["TSCore"]),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore", "TSCore"]),
        .testTarget(name: "ChannelScanTests", dependencies: ["ChannelScan", "BonDriver", "TSCore"]),
        .testTarget(name: "SettingsSyncTests", dependencies: ["SettingsSync"]),
    ] + iosFFmpegTargets,
    swiftLanguageModes: [.v5]
)
