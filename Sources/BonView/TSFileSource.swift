import Foundation
import MediaCore
import TSCore

/// Plays a recorded .ts/.m2ts file through the same pipeline at real-time pace (by PCR; by the
/// presenter's buffer for streams without PCR).
final class TSFileSource: @unchecked Sendable {
    private let url: URL
    private let player: TSPlayer
    private var thread: Thread?
    private let lock = NSLock()
    private var running = false
    var onFinished: (() -> Void)?

    init(url: URL, player: TSPlayer) {
        self.url = url
        self.player = player
    }

    func start() throws {
        let handle = try FileHandle(forReadingFrom: url)
        lock.lock(); running = true; lock.unlock()
        let t = Thread { [weak self] in
            defer { try? handle.close() }
            let chunk = 188 * 256
            var pacer = PCRPacer()
            while let self, self.isRunning {
                guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else { break }
                // Note: `player.feed` is asynchronous and `bufferedSeconds` only counts decoded
                // audio, so the buffer alone can't pace the reader; the PCR can.
                var wait = pacer.delay(for: data, now: ProcessInfo.processInfo.systemUptime)
                while self.isRunning && wait > 0 {
                    let step = min(wait, 0.05)
                    usleep(UInt32(step * 1_000_000))
                    wait -= step
                }
                guard self.isRunning else { break }
                self.player.feed(data)
                if !pacer.hasPCR {
                    // No PCR (yet): keep ~1 s queued; before the audio clock starts, cap the rate.
                    var waited = 0
                    while self.isRunning && self.player.presenter.bufferedSeconds > 1.0 && waited < 400 {
                        usleep(10_000)
                        waited += 1
                    }
                    if self.player.presenter.bufferedSeconds == 0 { usleep(8_000) }
                }
            }
            DispatchQueue.main.async { self?.onFinished?() }
        }
        t.name = "TS file reader"
        thread = t
        t.start()
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
    }
}
