import Darwin
import Foundation

/// App-wide log for the Debug Link. Use in place of `print`:
///
///     DebugLog.info("catalog loaded: \(n) courses")
///     DebugLog.error("save failed: \(error)")
///
/// Every line is kept in memory (up to `maxPending`, oldest dropped) until `DebugLink` uploads it to `POST /log`,
/// and mirrored to the original stderr so the Xcode console still shows it. `captureStandardStreams()` also routes
/// stdout/stderr (stray `print`, third-party libraries, MediaPipe) through a pipe into the same buffer.
/// Thread-safe; cheap enough to call from the camera queues.
enum DebugLogLevel: String {
    case debug, info, warn, error, stdout, stderr
}

final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()

    static let maxPending = 4000
    static let tailCount = 200

    private let lock = NSLock()
    private var pending: [[String: Any]] = []
    private var dropped = 0
    private var seq = 0
    /// Original stderr (before the pipe), so mirrored lines don't loop back into the capture.
    private var consoleFD: Int32 = STDERR_FILENO
    private var captured = false

    // MARK: - API

    static func debug(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        shared.append(.debug, message(), file: file, line: line)
    }

    static func info(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        shared.append(.info, message(), file: file, line: line)
    }

    static func warn(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        shared.append(.warn, message(), file: file, line: line)
    }

    static func error(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        shared.append(.error, message(), file: file, line: line)
    }

    func append(_ level: DebugLogLevel, _ message: String, file: String? = nil, line: Int? = nil, mirror: Bool = true) {
        let ts = Date().timeIntervalSince1970
        var item: [String: Any] = ["ts": ts, "level": level.rawValue, "msg": message]
        if let file { item["file"] = file }
        if let line { item["line"] = line }
        let where_ = file.map { " \($0):\(line ?? 0)" } ?? ""
        let rendered = "\(DebugLog.clock(ts)) \(level.rawValue)\(where_) \(message)"
        lock.lock()
        seq += 1
        item["seq"] = seq
        pending.append(item)
        if pending.count > Self.maxPending {
            let extra = pending.count - Self.maxPending
            pending.removeFirst(extra)
            dropped += extra
        }
        let fd = consoleFD
        let mirrorNow = mirror && captured
        lock.unlock()
        CrashMarker.record(line: rendered)
        if mirrorNow {
            // Echo to the real console (the captured stdout/stderr already reach it via the pipe reader).
            let bytes = Array((rendered + "\n").utf8)
            bytes.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
        }
    }

    /// Up to `max` oldest pending lines (removed from the buffer). Put them back with `requeue` if the upload fails.
    func drain(max: Int) -> (lines: [[String: Any]], dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        let n = min(max, pending.count)
        let out = Array(pending.prefix(n))
        pending.removeFirst(n)
        let d = dropped
        dropped = 0
        return (out, d)
    }

    func requeue(_ lines: [[String: Any]], dropped d: Int) {
        lock.lock()
        defer { lock.unlock() }
        pending.insert(contentsOf: lines, at: 0)
        dropped += d
        if pending.count > Self.maxPending {
            let extra = pending.count - Self.maxPending
            pending.removeFirst(extra)
            dropped += extra
        }
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    // MARK: - stdout / stderr capture

    /// Redirects fd 1 and 2 into pipes read on background threads; each line is logged as `stdout` / `stderr`
    /// and written through to the original stderr. Call once, early.
    func captureStandardStreams() {
        lock.lock()
        if captured {
            lock.unlock()
            return
        }
        captured = true
        let original = dup(STDERR_FILENO)
        consoleFD = original >= 0 ? original : STDERR_FILENO
        lock.unlock()
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        redirect(STDOUT_FILENO, level: .stdout)
        redirect(STDERR_FILENO, level: .stderr)
    }

    private func redirect(_ target: Int32, level: DebugLogLevel) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        let readFD = fds[0], writeFD = fds[1]
        guard dup2(writeFD, target) >= 0 else {
            close(readFD)
            close(writeFD)
            return
        }
        close(writeFD)
        let console = consoleFD
        let thread = Thread { [weak self] in
            var carry = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    break
                }
                // Pass the raw bytes through to the real console first.
                buf.withUnsafeBytes { _ = Darwin.write(console, $0.baseAddress, n) }
                carry.append(contentsOf: buf[0..<n])
                while let nl = carry.firstIndex(of: 0x0A) {
                    let lineData = carry[carry.startIndex..<nl]
                    carry.removeSubrange(carry.startIndex...nl)
                    let text = String(decoding: lineData, as: UTF8.self)
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        self?.append(level, text, mirror: false)
                    }
                }
                if carry.count > 16_384 {
                    self?.append(level, String(decoding: carry, as: UTF8.self), mirror: false)
                    carry.removeAll()
                }
            }
        }
        thread.name = "groove.debuglog.\(level.rawValue)"
        thread.qualityOfService = .utility
        thread.start()
    }

    // MARK: - Helpers

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static let clockLock = NSLock()

    static func clock(_ ts: TimeInterval) -> String {
        clockLock.lock()
        defer { clockLock.unlock() }
        return clockFormatter.string(from: Date(timeIntervalSince1970: ts))
    }
}
