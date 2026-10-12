import Foundation

/// A cross-process lock compatible with npm `proper-lockfile`, which Claude Code uses to
/// serialise OAuth refreshes between its own processes.
///
/// The protocol: the lock is a *directory*; `mkdir` succeeding means you own it. The owner
/// touches its mtime every few seconds; a lock whose mtime is older than `stale` is
/// considered abandoned and may be removed. By speaking the same protocol, this app behaves
/// like just another Claude Code process and never refreshes concurrently with one.
final class DirectoryLock: @unchecked Sendable {
    let path: String
    private let heartbeat: DispatchSourceTimer

    private init(path: String, updateInterval: TimeInterval) {
        self.path = path
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + updateInterval, repeating: updateInterval)
        timer.setEventHandler { utimes(path, nil) }
        timer.resume()
        self.heartbeat = timer
    }

    deinit { heartbeat.cancel() }

    /// Tries once to take the lock. Returns `nil` if someone else holds a fresh lock.
    static func tryAcquire(_ path: String,
                           stale: TimeInterval,
                           updateInterval: TimeInterval = 5) -> DirectoryLock? {
        for _ in 0..<2 {
            if mkdir(path, 0o777) == 0 {
                return DirectoryLock(path: path, updateInterval: updateInterval)
            }
            guard errno == EEXIST else { return nil }

            var info = stat()
            if stat(path, &info) != 0 {
                if errno == ENOENT { continue } // released in between — try again
                return nil
            }
            let mtime = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                             + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
            guard Date().timeIntervalSince(mtime) > stale else { return nil }
            // Abandoned by a crashed holder: remove it and retry.
            rmdir(path)
        }
        return nil
    }

    func release() {
        heartbeat.cancel()
        rmdir(path)
    }
}
