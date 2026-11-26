import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import GrooveCore
import Network
import SwiftUI
import UIKit

/// Live debug link to the PC server in `tools/debuglink/server.py` (LAN only, plain http, no auth).
/// On by default (off switch in Courses > gear, `DebugLinkSettingsView`), app-wide, zero configuration:
/// - finds the PC itself (`DebugDiscovery`: remembered host, Bonjour `_groovedebug._tcp`, then a /24 `/health`
///   probe); a host typed in the settings overrides; re-discovers after Wi-Fi changes or repeated failures;
/// - uploads every `DebugLog` line (plus captured stdout/stderr) to `POST /log` in batches, buffering while offline;
/// - posts events (screen appear/disappear, foreground/background, memory warnings, take_end, calibration, crash
///   markers from the previous run) to `POST /event`;
/// - streams the screen at native resolution, ~1 frame/s, to `POST /screen` (`ScreenStreamer`);
/// - during a calibration, as before: `CalibrationGate.telemetry()` to `POST /telemetry` at ~2 Hz, an annotated
///   camera JPEG to `POST /frame` every 3 s, and a `GET /tuning.json` poll every 2 s publishing `CalibrationTuning`.
/// Everything is fire-and-forget: requests time out fast and nothing waits on the camera or main thread
/// (URLSession async calls suspend; image work runs detached).
@MainActor
final class DebugLink: ObservableObject {
    static let shared = DebugLink()

    static let telemetryInterval = 0.5
    static let perfSampleInterval = 5.0
    static let tuningPollInterval = 2.0
    static let flushInterval = 1.0
    static let logBatch = 500
    static let maxPendingEvents = 1000

    /// Tuning from the server's `tuning.json` merged over `CalibrationTuning.defaults`; nil until one arrives or
    /// while the link is off (the gate then uses the defaults).
    @Published private(set) var tuning: CalibrationTuning?
    /// First 6 hex chars of the served tuning's ETag (sha256).
    @Published private(set) var tuningHash: String?
    /// True while the last request to the server succeeded within the last few seconds.
    @Published private(set) var connected = false
    @Published private(set) var lastSent: String = "Nothing sent yet."
    @Published private(set) var lastError: String?
    /// The server in use and how it was found ("192.168.4.47:8765 (bonjour)"), or the search state.
    @Published private(set) var serverDescription: String = "Not searching."
    /// Name of the screen on top (the last `.debugScreen` that appeared and is still visible).
    @Published private(set) var currentScreen: String = "launch"

    var isEnabled: Bool { DebugLinkSettings.isEnabled }

    /// The server currently in use (typed host, or the discovered one).
    private(set) var activeBase: URL?

    private let session: URLSession
    private var started = false
    private var sessions = 0
    private var pollTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var loopWake: CheckedContinuation<Void, Never>?
    private var etag: String?
    private var lastSuccess: Date?
    private var consecutiveFailures = 0
    private var rediscover = true
    private var pendingTelemetry: [[String: Any]] = []
    private var pendingEvents: [[String: Any]] = []
    private var lastTelemetryOffer = 0.0
    private var lastPerfSample = -Double.infinity
    private var telemetryInFlight = false
    private var eventsInFlight = false
    private var logsInFlight = false
    private var frameInFlight = false
    private var screenStack: [String] = []
    private var crashToClear = false
    private var observers: [NSObjectProtocol] = []
    private let pathMonitor = NWPathMonitor()

    private static let maxPending = 40

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: config)
    }

    // MARK: - App lifecycle

    /// Call once at launch (`GrooveCoachApp.init`). Log capture and crash handlers are installed even when the link
    /// is off (cheap; a crash marker then waits until the link is on again).
    func start() {
        guard !started else { return }
        started = true
        DebugLog.shared.captureStandardStreams()
        CrashMarker.install()
        DebugLog.info("launch \(DebugLinkDevice.appBuild) on \(DebugLinkDevice.model), iOS \(UIDevice.current.systemVersion)")
        sendEvent(kind: "app_launch", fields: ["systemVersion": UIDevice.current.systemVersion])
        if let crash = CrashMarker.pending() {
            DebugLog.warn("previous run crashed: \(crash.reason)")
            var fields: [String: Any] = ["reason": crash.reason, "log": crash.log, "stack": crash.stack]
            if let at = crash.crashedAt { fields["crashedAt"] = at.timeIntervalSince1970 }
            crashToClear = true
            sendEvent(kind: "crash", fields: fields)
        }
        observeApp()
        pathMonitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in DebugLink.shared.networkChanged(satisfied: satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "groove.debuglink.path"))
        startLoop()
        ScreenStreamer.shared.start()
    }

    private func observeApp() {
        let nc = NotificationCenter.default
        let events: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "app_active"),
            (UIApplication.willResignActiveNotification, "app_inactive"),
            (UIApplication.didEnterBackgroundNotification, "app_background"),
            (UIApplication.willEnterForegroundNotification, "app_foreground"),
            (UIApplication.didReceiveMemoryWarningNotification, "memory_warning")
        ]
        for (name, kind) in events {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DebugLink.shared.appEvent(kind) }
            })
        }
    }

    private func appEvent(_ kind: String) {
        if kind == "memory_warning" {
            DebugLog.warn("memory warning")
            sendEvent(kind: kind, fields: ["residentMB": DebugLinkDevice.residentMB()])
        } else {
            DebugLog.info(kind)
            sendEvent(kind: kind, fields: [:])
        }
        if kind == "app_foreground" || kind == "app_active" {
            if consecutiveFailures > 0 { rediscover = true }
            kickLoop()
        }
        if kind == "app_background" { flushAll() }
    }

    private func networkChanged(satisfied: Bool) {
        DebugLog.info("network path \(satisfied ? "up" : "down")")
        connected = false
        rediscover = true
        if satisfied { kickLoop() }
    }

    // MARK: - Connection loop

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in
            var backoff = 3.0
            while !Task.isCancelled {
                guard let self else { return }
                guard self.isEnabled else {
                    self.activeBase = nil
                    self.connected = false
                    self.serverDescription = "Off."
                    await self.sleep(2)
                    continue
                }
                if self.activeBase == nil || self.rediscover {
                    if await self.resolveServer() {
                        backoff = 3
                    } else {
                        await self.sleep(backoff)
                        backoff = min(backoff * 1.6, 20)
                        continue
                    }
                }
                self.flushAll()
                await self.heartbeatIfIdle()
                await self.sleep(Self.flushInterval)
            }
        }
    }

    /// Sleeps up to `seconds`, waking early on `kickLoop()`.
    private func sleep(_ seconds: Double) async {
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.kickLoop() }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if let old = loopWake { old.resume() }
            loopWake = c
        }
        timer.cancel()
    }

    private func kickLoop() {
        let c = loopWake
        loopWake = nil
        c?.resume()
    }

    /// Typed host if set, otherwise `DebugDiscovery.find()`. True when there is a server to talk to.
    private func resolveServer() async -> Bool {
        rediscover = false
        let typed = DebugLinkSettings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, let base = DebugLinkSettings.baseURL(from: typed) {
            setServer(base, source: .manual)
            return true
        }
        serverDescription = activeBase == nil ? "Searching (Bonjour, then this Wi-Fi's /24)..." : serverDescription
        let began = Date()
        guard let found = await DebugDiscovery.find() else {
            if activeBase == nil {
                serverDescription = "No server found; retrying. Is tools/debuglink/start.ps1 running on the PC?"
            }
            markFailure("no debuglink server found")
            return activeBase != nil
        }
        // The settings may have changed while searching.
        guard isEnabled, DebugLinkSettings.host.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        setServer(found.base, source: found.source)
        markSuccess()
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        DebugLog.info("debuglink server \(found.base.absoluteString) via \(found.source.rawValue) in \(ms) ms")
        return true
    }

    private func setServer(_ base: URL, source: DebugDiscovery.Source) {
        if activeBase != base {
            etag = nil
            tuningHash = nil
        }
        activeBase = base
        consecutiveFailures = 0
        serverDescription = "\(base.host ?? "?"):\(base.port ?? DebugLinkSettings.defaultPort) (\(source.rawValue))"
    }

    private func heartbeatIfIdle() async {
        guard let base = activeBase else { return }
        if let t = lastSuccess, Date().timeIntervalSince(t) < 4 { return }
        if await DebugDiscovery.isServer(base, timeout: 2) {
            markSuccess()
        } else {
            markFailure("server not answering at \(base.host ?? "?")")
        }
    }

    // MARK: - Base URL

    private var baseURL: URL? {
        guard isEnabled else { return nil }
        return activeBase
    }

    /// For `ScreenStreamer`: the server to send to, or nil when off / not found yet.
    var streamBase: URL? { baseURL }

    // MARK: - Session lifecycle (calibration running)

    /// Called when a calibration starts; starts the tuning poll if the link is on.
    func beginSession() {
        sessions += 1
        guard isEnabled else {
            tuning = nil
            return
        }
        startPolling()
    }

    func endSession() {
        sessions = max(0, sessions - 1)
        if sessions == 0 {
            pollTask?.cancel()
            pollTask = nil
            flushTelemetry()
        }
    }

    /// Settings changed (toggle or host): forget the old server's state and search again.
    func settingsChanged() {
        etag = nil
        tuningHash = nil
        connected = false
        lastSuccess = nil
        activeBase = nil
        rediscover = true
        pendingTelemetry.removeAll()
        if !isEnabled {
            tuning = nil
            pollTask?.cancel()
            pollTask = nil
        } else if sessions > 0 {
            startPolling()
        }
        kickLoop()
    }

    /// "Find again" in the settings: forget the remembered host and search now.
    func findAgain() {
        DebugDiscovery.rememberedHost = nil
        settingsChanged()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pollTuning()
                try? await Task.sleep(nanoseconds: UInt64(Self.tuningPollInterval * 1_000_000_000))
            }
        }
    }

    private func markSuccess() {
        lastSuccess = Date()
        consecutiveFailures = 0
        connected = true
        lastError = nil
    }

    private func markFailure(_ message: String) {
        lastError = message
        consecutiveFailures += 1
        // A discovered server that stopped answering: search again (a typed host is just retried).
        if consecutiveFailures >= 3, DebugLinkSettings.host.trimmingCharacters(in: .whitespaces).isEmpty {
            rediscover = true
        }
        if let t = lastSuccess, Date().timeIntervalSince(t) < 6 { return }
        connected = false
    }

    // MARK: - Screens

    /// A `.debugScreen(name)` view appeared.
    func screenAppeared(_ name: String) {
        screenStack.removeAll { $0 == name }
        screenStack.append(name)
        currentScreen = name
        DebugLog.info("screen \(name) appeared")
        sendEvent(kind: "screen_appear", fields: ["name": name])
    }

    func screenDisappeared(_ name: String) {
        screenStack.removeAll { $0 == name }
        currentScreen = screenStack.last ?? "none"
        sendEvent(kind: "screen_disappear", fields: ["name": name])
    }

    // MARK: - Tuning

    private func pollTuning() async {
        guard let base = baseURL else { return }
        var req = URLRequest(url: base.appendingPathComponent("tuning.json"))
        req.httpMethod = "GET"
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 304:
                markSuccess()
            case 200:
                markSuccess()
                do {
                    let merged = try CalibrationTuning.defaults.merged(withJSON: data)
                    let tag = http.value(forHTTPHeaderField: "ETag")
                    etag = tag
                    tuningHash = tag.map { t in String(t.filter { c in c.isHexDigit }.prefix(6)) }
                    if merged != tuning { tuning = merged }
                } catch {
                    // Keep the last good tuning; the server keeps serving the same bad file, so remember its tag.
                    etag = http.value(forHTTPHeaderField: "ETag")
                    lastError = "tuning.json rejected: \(error.localizedDescription)"
                    DebugLog.warn("tuning.json rejected: \(error.localizedDescription)")
                }
            default:
                markFailure("tuning.json: HTTP \(http.statusCode)")
            }
        } catch {
            markFailure(error.localizedDescription)
        }
    }

    // MARK: - Health check

    /// `GET /health` on a typed host, or on the current server when `host` is empty; returns a readable result.
    func testConnection(host: String) async -> String {
        let typed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = typed.isEmpty ? activeBase : DebugLinkSettings.baseURL(from: typed) else {
            return "No server found yet. Run tools/debuglink/start.ps1 on the PC (same Wi-Fi), or type its address."
        }
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 3
        let began = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            guard let http = resp as? HTTPURLResponse else { return "No HTTP response." }
            if http.statusCode == 200 {
                if isEnabled && base == activeBase { markSuccess() }
                let body = String(data: data, encoding: .utf8) ?? ""
                return "Connected to \(base.host ?? "") (\(body.trimmingCharacters(in: .whitespacesAndNewlines)), \(ms) ms)."
            }
            return "Server answered HTTP \(http.statusCode)."
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Logs and events

    func flushAll() {
        flushLogs()
        flushEvents()
        flushTelemetry()
    }

    private func flushLogs() {
        guard !logsInFlight, let base = baseURL else { return }
        let (lines, dropped) = DebugLog.shared.drain(max: Self.logBatch)
        guard !lines.isEmpty || dropped > 0 else { return }
        var payload: [String: Any] = ["device": DebugLinkDevice.model, "appBuild": DebugLinkDevice.appBuild,
                                      "lines": lines]
        if dropped > 0 { payload["dropped"] = dropped }
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        logsInFlight = true
        let request = Self.post(base, "log", body)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await self.send(request, what: "log")
            self.logsInFlight = false
            if ok {
                self.lastSent = "Log x\(lines.count) at \(DebugLinkDevice.clock())"
                // A backlog after a reconnect: keep draining.
                if DebugLog.shared.pendingCount >= Self.logBatch { self.flushLogs() }
            } else {
                DebugLog.shared.requeue(lines, dropped: dropped)
            }
        }
    }

    private func flushEvents() {
        guard !eventsInFlight, !pendingEvents.isEmpty, let base = baseURL else { return }
        let batch = pendingEvents
        pendingEvents.removeAll()
        guard JSONSerialization.isValidJSONObject(batch),
              let body = try? JSONSerialization.data(withJSONObject: batch) else { return }
        eventsInFlight = true
        let request = Self.post(base, "event", body)
        let hadCrash = crashToClear && batch.contains { ($0["kind"] as? String) == "crash" }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await self.send(request, what: "event")
            self.eventsInFlight = false
            if ok {
                if hadCrash {
                    CrashMarker.clear()
                    self.crashToClear = false
                }
                if !self.pendingEvents.isEmpty { self.flushEvents() }
            } else {
                self.pendingEvents.insert(contentsOf: batch, at: 0)
                self.trimEvents()
            }
        }
    }

    private func trimEvents() {
        if pendingEvents.count > Self.maxPendingEvents {
            pendingEvents.removeFirst(pendingEvents.count - Self.maxPendingEvents)
        }
    }

    private static func post(_ base: URL, _ path: String, _ body: Data) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    /// True when the batch is done with (2xx, or a 4xx the server will never accept).
    private func send(_ request: URLRequest, what: String) async -> Bool {
        do {
            let (_, resp) = try await session.data(for: request)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                markSuccess()
                return true
            }
            markFailure("\(what): HTTP \(code)")
            return (400..<500).contains(code)
        } catch {
            markFailure(error.localizedDescription)
            return false
        }
    }

    /// Called by `ScreenStreamer` after each upload.
    func screenFinished(ok: Bool, failure: String?, bytes: Int, screen: String) {
        if ok {
            markSuccess()
            lastSent = "Screen \(bytes / 1024) KB [\(screen)] at \(DebugLinkDevice.clock())"
        } else if let failure {
            markFailure(failure)
        }
    }

    // MARK: - Telemetry

    /// Offer the latest gate telemetry; kept at most every 0.5 s and posted in small batches. Cheap when off.
    func offerTelemetry(_ makeTelemetry: () -> CalibrationTelemetry, extra: [String: Any] = [:]) {
        guard isEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastTelemetryOffer >= Self.telemetryInterval else { return }
        lastTelemetryOffer = now
        guard var obj = Self.jsonObject(makeTelemetry()) else { return }
        obj["kind"] = "calibration"
        for (k, v) in extra { obj[k] = v }
        enqueue(obj)
        if pendingTelemetry.count >= 2 { flushTelemetry() }
    }

    /// One full telemetry line now (e.g. at lock or Skip), bypassing the 2 Hz throttle.
    func sendTelemetry(_ telemetry: CalibrationTelemetry, kind: String, extra: [String: Any] = [:]) {
        guard isEnabled, var obj = Self.jsonObject(telemetry) else { return }
        for (k, v) in extra { obj[k] = v }
        sendEvent(kind: kind, fields: obj)
    }

    /// One line per take end (result summary), or any other event; posted with the next batch.
    func sendEvent(kind: String, fields: [String: Any]) {
        guard isEnabled else { return }
        var obj = stamped(fields)
        obj["kind"] = kind
        if obj["screen"] == nil { obj["screen"] = currentScreen }
        if (kind == "take_end" || kind == "calibration_end"), obj["thermalState"] == nil {
            obj["thermalState"] = DebugLinkDevice.thermalStateString()
        }
        pendingEvents.append(obj)
        trimEvents()
        flushEvents()
    }

    /// Periodic live pose FPS + thermal state sample while `PracticeCamera` is running (at most every ~5 s).
    func recordPerfSample(liveFps: Double, extra: [String: Any] = [:]) {
        guard isEnabled, liveFps.isFinite else { return }
        let now = CACurrentMediaTime()
        guard now - lastPerfSample >= Self.perfSampleInterval - 0.1 else { return }
        lastPerfSample = now
        let roundedFps = (liveFps * 10).rounded() / 10
        var fields: [String: Any] = [
            "liveFps": roundedFps,
            "thermalState": DebugLinkDevice.thermalStateString()
        ]
        for (k, v) in extra { fields[k] = v }
        sendEvent(kind: "perf_sample", fields: fields)
    }

    /// Hands-free gesture command fired by `GestureRouter` / `CoachingStageCoordinator`.
    func recordGestureFired(command: String, mode: String? = nil, phase: String? = nil, action: String? = nil,
                            extra: [String: Any] = [:]) {
        guard isEnabled else { return }
        var fields: [String: Any] = ["command": command]
        if let mode, !mode.isEmpty { fields["mode"] = mode }
        if let phase, !phase.isEmpty { fields["phase"] = phase }
        if let action, !action.isEmpty { fields["action"] = action }
        for (k, v) in extra { fields[k] = v }
        sendEvent(kind: "gesture_fired", fields: fields)
    }

    /// Convenience overload accepting `GestureCommand` directly.
    func recordGestureFired(command: GestureCommand, mode: String? = nil, phase: String? = nil, action: String? = nil,
                            extra: [String: Any] = [:]) {
        recordGestureFired(command: command.rawValue, mode: mode, phase: phase, action: action, extra: extra)
    }

    private func enqueue(_ item: [String: Any]) {
        pendingTelemetry.append(stamped(item))
        if pendingTelemetry.count > Self.maxPending {
            pendingTelemetry.removeFirst(pendingTelemetry.count - Self.maxPending)
        }
    }

    private func stamped(_ item: [String: Any]) -> [String: Any] {
        // NaN / infinity would make the whole batch invalid JSON.
        var obj = item.mapValues { v -> Any in
            if let d = v as? Double, !d.isFinite { return String(d) }
            if let a = v as? [Double] { return a.map { $0.isFinite ? $0 as Any : String($0) as Any } }
            return v
        }
        obj["ts"] = Date().timeIntervalSince1970
        obj["hostTime"] = CACurrentMediaTime()
        obj["deviceModel"] = DebugLinkDevice.model
        obj["appBuild"] = DebugLinkDevice.appBuild
        if let tuningHash { obj["tuningHash"] = tuningHash }
        return obj
    }

    func flushTelemetry() {
        guard !telemetryInFlight, !pendingTelemetry.isEmpty, let base = baseURL else { return }
        let batch = pendingTelemetry
        pendingTelemetry.removeAll()
        guard JSONSerialization.isValidJSONObject(batch),
              let body = try? JSONSerialization.data(withJSONObject: batch) else { return }
        var req = URLRequest(url: base.appendingPathComponent("telemetry"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let request = req
        let count = batch.count
        telemetryInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.telemetryInFlight = false }
            do {
                let (_, resp) = try await self.session.data(for: request)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) {
                    self.markSuccess()
                    self.lastSent = "Telemetry x\(count) at \(DebugLinkDevice.clock())"
                } else {
                    self.markFailure("telemetry: HTTP \(code)")
                }
            } catch {
                // Dropped on failure (no retry queue: the next readings supersede these).
                self.markFailure(error.localizedDescription)
            }
        }
    }

    private static func jsonObject<T: Encodable>(_ value: T) -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = try? encoder.encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    // MARK: - Frames

    /// Sends one annotated JPEG. `image` is the (already downscaled) raw, un-mirrored camera frame; landmarks are
    /// the 33 raw normalised points. Drawing and encoding run off the main thread.
    func sendFrame(image: CGImage, landmarks: [CalibrationLandmark], tuning: CalibrationTuning,
                   framingOK: Bool, label: String) {
        guard !frameInFlight, let base = baseURL else { return }
        frameInFlight = true
        let session = self.session
        let header = String(label.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 }.map(Character.init))
        Task.detached(priority: .utility) { [weak self] in
            let jpeg = DebugLinkImaging.annotatedJPEG(image: image, landmarks: landmarks, tuning: tuning,
                                                      framingOK: framingOK, label: header)
            var ok = false
            var failure: String?
            if let jpeg {
                var req = URLRequest(url: base.appendingPathComponent("frame"))
                req.httpMethod = "POST"
                req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
                req.setValue(header, forHTTPHeaderField: "X-Frame-Label")
                req.httpBody = jpeg
                do {
                    let (_, resp) = try await session.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    ok = (200..<300).contains(code)
                    if !ok { failure = "frame: HTTP \(code)" }
                } catch {
                    failure = error.localizedDescription
                }
            }
            await self?.frameFinished(ok: ok, failure: failure, bytes: jpeg?.count ?? 0, label: header)
        }
    }

    private func frameFinished(ok: Bool, failure: String?, bytes: Int, label: String) {
        frameInFlight = false
        if ok {
            markSuccess()
            lastSent = "Frame \(bytes / 1024) KB [\(label)] at \(DebugLinkDevice.clock())"
        } else if let failure {
            markFailure(failure)
        }
    }
}

/// Debug Link settings (UserDefaults; readable from any thread).
enum DebugLinkSettings {
    static let enabledKey = "debugLink.enabled"
    static let hostKey = "debugLink.host"
    static let defaultPort = 8765
    /// Seconds between debug frames.
    static let frameInterval = 3.0

    /// On unless switched off in the settings (this build ships with the link on).
    static let enabledByDefault = true

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? enabledByDefault }
    static var host: String { UserDefaults.standard.string(forKey: hostKey) ?? "" }

    /// `http://host:port` from a field like `192.168.4.47:8765` (scheme and port optional).
    static func baseURL(from host: String) -> URL? {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        if !h.contains("://") { h = "http://" + h }
        while h.hasSuffix("/") { h.removeLast() }
        guard var comps = URLComponents(string: h), comps.host?.isEmpty == false else { return nil }
        if comps.port == nil { comps.port = defaultPort }
        comps.path = ""
        return comps.url
    }
}

/// Debug frame imaging (thread-safe; the snapshot runs on the camera queue, the annotation off the main thread).
enum DebugLinkImaging {
    static let bones: [(String, String)] = [
        ("leftShoulder", "rightShoulder"), ("leftHip", "rightHip"),
        ("leftShoulder", "leftHip"), ("rightShoulder", "rightHip"),
        ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"),
        ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
        ("leftHip", "leftKnee"), ("leftKnee", "leftAnkle"),
        ("rightHip", "rightKnee"), ("rightKnee", "rightAnkle"),
        ("leftAnkle", "leftHeel"), ("leftHeel", "leftFootIndex"),
        ("rightAnkle", "rightHeel"), ("rightHeel", "rightFootIndex")
    ]

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Downscales a camera buffer to about `width` px wide (call on the camera queue, only when a frame is due).
    static func snapshot(_ pb: CVPixelBuffer, width: CGFloat = 360) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pb)
        let extent = image.extent
        guard extent.width > 0 else { return nil }
        let s = width / extent.width
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        return ciContext.createCGImage(scaled, from: scaled.extent)
    }

    static func annotatedJPEG(image: CGImage, landmarks: [CalibrationLandmark],
                              tuning: CalibrationTuning, framingOK: Bool, label: String) -> Data? {
        let size = CGSize(width: image.width, height: image.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { ctx in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext

            // Framing box (safe x range, headroom and foot line) in raw image coordinates.
            let box = CGRect(x: tuning.safeBoxMinX * size.width,
                             y: tuning.minNoseY * size.height,
                             width: (tuning.safeBoxMaxX - tuning.safeBoxMinX) * size.width,
                             height: (tuning.maxFootY - tuning.minNoseY) * size.height)
            cg.setStrokeColor((framingOK ? UIColor.systemGreen : UIColor.systemRed).cgColor)
            cg.setLineWidth(2)
            cg.stroke(box)

            // Skeleton.
            func point(_ name: String) -> CGPoint? {
                guard let i = CanonicalSkeleton.mediapipeIndex[name], i < landmarks.count,
                      landmarks[i].visibility >= 0.3 else { return nil }
                return CGPoint(x: landmarks[i].x * size.width, y: landmarks[i].y * size.height)
            }
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.85).cgColor)
            cg.setLineWidth(2)
            for (a, b) in bones {
                guard let pa = point(a), let pb = point(b) else { continue }
                cg.move(to: pa)
                cg.addLine(to: pb)
            }
            cg.strokePath()
            for name in CanonicalSkeleton.mediapipeIndex.keys {
                guard let p = point(name), let i = CanonicalSkeleton.mediapipeIndex[name] else { continue }
                let v = landmarks[i].visibility
                cg.setFillColor((v >= 0.6 ? UIColor.systemGreen : (v >= 0.5 ? UIColor.systemYellow : UIColor.systemOrange)).cgColor)
                cg.fillEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            }

            // Label strip.
            let text = "\(label)  (raw, un-mirrored)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            cg.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: 18))
            text.draw(at: CGPoint(x: 4, y: 2), withAttributes: attrs)
        }
        return rendered.jpegData(compressionQuality: 0.5)
    }
}

enum DebugLinkDevice {
    static let model: String = {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let id = mirror.children.reduce(into: "") { acc, el in
            if let v = el.value as? Int8, v != 0 { acc.append(Character(UnicodeScalar(UInt8(bitPattern: v)))) }
        }
        return id.isEmpty ? "unknown" : id
    }()

    static let appBuild: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()

    /// Resident memory in MB (for memory-warning events); -1 if unavailable.
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return (Double(info.resident_size) / 1_048_576 * 10).rounded() / 10
    }

    static func thermalStateString(_ state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func clock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

/// Screen-name events for the Debug Link: `.debugScreen("Practice")` posts `screen_appear` / `screen_disappear`
/// and names the screen frames.
struct DebugScreenModifier: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        content
            .onAppear { DebugLink.shared.screenAppeared(name) }
            .onDisappear { DebugLink.shared.screenDisappeared(name) }
    }
}

extension View {
    func debugScreen(_ name: String) -> some View {
        modifier(DebugScreenModifier(name: name))
    }
}
