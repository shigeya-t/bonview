import CFFmpeg

/// FFmpeg (Homebrew) is weak-linked; check this before creating any decoder.
public enum FFmpegAvailability {
    /// Names of the FFmpeg libraries that could not be loaded (empty when FFmpeg is usable).
    public static let missingLibraries: [String] = {
        guard let p = tv_ffmpeg_missing_libraries() else { return [] }
        return String(cString: p).components(separatedBy: ", ")
    }()

    public static var isAvailable: Bool { missingLibraries.isEmpty }
}
