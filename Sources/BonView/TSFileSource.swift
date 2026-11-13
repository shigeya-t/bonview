import Foundation
import MediaCore

/// Plays a recorded .ts/.m2ts file through the same pipeline, paced by the presenter's buffer.
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
            let chunk = 188 * 512
            while let self, self.isRunning {
                guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else { break }
                self.player.feed(data)
                // Keep ~1 s queued; when no audio clock exists yet, cap the rate instead.
                var waited = 0
                while self.isRunning && self.player.presenter.bufferedSeconds > 1.0 && waited < 400 {
                    usleep(10_000)
                    waited += 1
                }
                if self.player.presenter.bufferedSeconds == 0 { usleep(8_000) }
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
