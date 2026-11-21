import Darwin
import Foundation

/// Crash marker for the Debug Link. `install()` sets an uncaught-NSException handler and fatal-signal handlers
/// (SIGSEGV, SIGBUS, SIGILL, SIGTRAP for Swift traps, SIGABRT, SIGFPE). On a crash they write
/// `Library/Caches/debuglink-crash.txt` with the reason and the last `DebugLog.tailCount` log lines; the next launch
/// sends it as a `crash` event (`DebugLink`) and deletes it once the server has it.
///
/// The signal path only uses async-signal-safe calls (`open`/`write`/`close`) on memory set up in `install()`:
/// the log tail is mirrored into a fixed C ring buffer as lines are logged.
enum CrashMarker {
    static let slotCount = 200  // = DebugLog.tailCount; a literal so the signal handler never runs a lazy initialiser
    static let slotSize = 256

    static var markerURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent("debuglink-crash.txt")
    }

    private static let lock = NSLock()

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard crashRing == nil else { return }
        let ring = UnsafeMutablePointer<UInt8>.allocate(capacity: slotCount * slotSize)
        ring.initialize(repeating: 0, count: slotCount * slotSize)
        let lens = UnsafeMutablePointer<Int32>.allocate(capacity: slotCount)
        lens.initialize(repeating: 0, count: slotCount)
        crashLens = lens
        crashPath = strdup(markerURL.path)
        crashRing = ring

        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            CrashMarker.writeException(exception)
            previousExceptionHandler?(exception)
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(sig, crashSignalHandler)
        }
    }

    /// Mirrors one rendered log line into the ring (called by `DebugLog` for every line).
    static func record(line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let ring = crashRing, let lens = crashLens else { return }
        let slot = crashHead % slotCount
        var bytes = Array(line.utf8.prefix(slotSize - 1))
        bytes.append(0x0A)
        let dst = ring + slot * slotSize
        bytes.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!, count: src.count)
        }
        lens[slot] = Int32(bytes.count)
        crashHead += 1
    }

    // MARK: - Writing

    fileprivate static func writeException(_ exception: NSException) {
        crashExceptionWritten = 1
        var text = "GROOVE_CRASH v1\n"
        text += "reason: uncaught \(exception.name.rawValue): \(exception.reason ?? "(no reason)")\n"
        text += "stack:\n"
        for s in exception.callStackSymbols.prefix(60) { text += s + "\n" }
        text += "log:\n"
        text += tailText()
        try? text.data(using: .utf8)?.write(to: markerURL, options: .atomic)
    }

    private static func tailText() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let ring = crashRing, let lens = crashLens else { return "" }
        let count = min(crashHead, slotCount)
        var out = ""
        for i in 0..<count {
            let slot = (crashHead - count + i) % slotCount
            let len = Int(lens[slot])
            out += String(decoding: UnsafeBufferPointer(start: ring + slot * slotSize, count: len), as: UTF8.self)
        }
        return out
    }

    // MARK: - Next launch

    struct Report {
        let reason: String
        let stack: [String]
        let log: [String]
        let crashedAt: Date?
    }

    /// The marker left by the previous run, if any.
    static func pending() -> Report? {
        let url = markerURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var reason = "unknown"
        var stack: [String] = []
        var log: [String] = []
        var section = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("GROOVE_CRASH") { continue }
            if line.hasPrefix("reason: ") && section.isEmpty {
                reason = String(line.dropFirst("reason: ".count))
                continue
            }
            if line == "stack:" || line == "log:" {
                section = line
                continue
            }
            if line.isEmpty { continue }
            if section == "stack:" { stack.append(line) } else if section == "log:" { log.append(line) }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Report(reason: reason, stack: stack, log: log, crashedAt: attrs?[.modificationDate] as? Date)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}

// Signal-handler state: plain globals set once in `install()` and only read (racily, best effort) by the handler.
nonisolated(unsafe) private var crashRing: UnsafeMutablePointer<UInt8>?
nonisolated(unsafe) private var crashLens: UnsafeMutablePointer<Int32>?
nonisolated(unsafe) private var crashHead = 0
nonisolated(unsafe) private var crashPath: UnsafeMutablePointer<CChar>?
nonisolated(unsafe) private var crashExceptionWritten: Int32 = 0
nonisolated(unsafe) private var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

private func crashWrite(_ fd: Int32, _ s: StaticString) {
    _ = write(fd, s.utf8Start, s.utf8CodeUnitCount)
}

private func crashSignalHandler(_ sig: Int32) {
    defer {
        signal(sig, SIG_DFL)
        raise(sig)
    }
    // An uncaught NSException already wrote a better marker; its abort() lands here as SIGABRT.
    guard crashExceptionWritten == 0, let path = crashPath else { return }
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    crashWrite(fd, "GROOVE_CRASH v1\nreason: signal ")
    switch sig {
    case SIGSEGV: crashWrite(fd, "SIGSEGV (bad memory access)")
    case SIGBUS: crashWrite(fd, "SIGBUS (bad memory access)")
    case SIGILL: crashWrite(fd, "SIGILL (illegal instruction)")
    case SIGTRAP: crashWrite(fd, "SIGTRAP (Swift runtime trap: force unwrap, index out of range, fatalError...)")
    case SIGABRT: crashWrite(fd, "SIGABRT (abort)")
    case SIGFPE: crashWrite(fd, "SIGFPE (arithmetic)")
    default: crashWrite(fd, "other")
    }
    crashWrite(fd, "\nlog:\n")
    if let ring = crashRing, let lens = crashLens {
        let slots = CrashMarker.slotCount
        let size = CrashMarker.slotSize
        let head = crashHead
        let count = min(head, slots)
        var i = 0
        while i < count {
            let slot = (head - count + i) % slots
            let len = Int(lens[slot])
            if len > 0 && len <= size { _ = write(fd, ring + slot * size, len) }
            i += 1
        }
    }
    close(fd)
}
