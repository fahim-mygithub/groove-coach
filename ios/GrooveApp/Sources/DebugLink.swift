import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import GrooveCore
import UIKit

/// Live debug link to the PC server in `tools/debuglink/server.py` (LAN only, plain http, no auth).
/// Off by default; turned on in Courses > gear (`DebugLinkSettingsView`). While on and a calibration is running:
/// - batches `CalibrationGate.telemetry()` (plus device model, app build and timestamps) to `POST /telemetry` at ~2 Hz;
/// - sends a ~360 px JPEG of the camera frame with the skeleton and the framing box drawn on it to `POST /frame`
///   every 3 s (`X-Frame-Label` = step + cue);
/// - polls `GET /tuning.json` every 2 s with `If-None-Match` and publishes the merged `CalibrationTuning`.
/// Everything is fire-and-forget: requests time out fast, failures are dropped, nothing waits on the camera or main
/// thread (URLSession async calls suspend; image encoding runs detached).
@MainActor
final class DebugLink: ObservableObject {
    static let shared = DebugLink()

    static let telemetryInterval = 0.5
    static let tuningPollInterval = 2.0

    /// Tuning from the server's `tuning.json` merged over `CalibrationTuning.defaults`; nil until one arrives or
    /// while the link is off (the gate then uses the defaults).
    @Published private(set) var tuning: CalibrationTuning?
    /// First 6 hex chars of the served tuning's ETag (sha256).
    @Published private(set) var tuningHash: String?
    /// True while the last request to the server succeeded within the last few seconds.
    @Published private(set) var connected = false
    @Published private(set) var lastSent: String = "Nothing sent yet."
    @Published private(set) var lastError: String?

    var isEnabled: Bool { DebugLinkSettings.isEnabled }

    private let session: URLSession
    private var sessions = 0
    private var pollTask: Task<Void, Never>?
    private var etag: String?
    private var lastSuccess: Date?
    private var pendingTelemetry: [[String: Any]] = []
    private var lastTelemetryOffer = 0.0
    private var telemetryInFlight = false
    private var frameInFlight = false

    private static let maxPending = 40

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config)
    }

    // MARK: - Base URL

    private var baseURL: URL? {
        guard isEnabled else { return nil }
        return DebugLinkSettings.baseURL(from: DebugLinkSettings.host)
    }

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

    /// Settings changed (toggle or host): forget the old server's state.
    func settingsChanged() {
        etag = nil
        tuningHash = nil
        connected = false
        lastSuccess = nil
        pendingTelemetry.removeAll()
        if !isEnabled {
            tuning = nil
            pollTask?.cancel()
            pollTask = nil
        } else if sessions > 0 {
            startPolling()
        }
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
        connected = true
        lastError = nil
    }

    private func markFailure(_ message: String) {
        lastError = message
        if let t = lastSuccess, Date().timeIntervalSince(t) < 6 { return }
        connected = false
    }

    // MARK: - Tuning

    private func pollTuning() async {
        guard let base = baseURL else {
            connected = false
            return
        }
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
                }
            default:
                markFailure("tuning.json: HTTP \(http.statusCode)")
            }
        } catch {
            markFailure(error.localizedDescription)
        }
    }

    // MARK: - Health check

    /// `GET /health`; returns a human-readable result.
    func testConnection(host: String) async -> String {
        guard let base = DebugLinkSettings.baseURL(from: host) else { return "Enter the PC address, e.g. 192.168.4.47:8765." }
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 3
        let started = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = resp as? HTTPURLResponse else { return "No HTTP response." }
            if http.statusCode == 200 {
                if isEnabled && DebugLinkSettings.baseURL(from: DebugLinkSettings.host) == base { markSuccess() }
                let body = String(data: data, encoding: .utf8) ?? ""
                return "Connected to \(base.host ?? "") (\(body.trimmingCharacters(in: .whitespacesAndNewlines)), \(ms) ms)."
            }
            return "Server answered HTTP \(http.statusCode)."
        } catch {
            return "Failed: \(error.localizedDescription)"
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
        var obj = fields
        obj["kind"] = kind
        enqueue(obj)
        flushTelemetry()
    }

    private func enqueue(_ item: [String: Any]) {
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
        pendingTelemetry.append(obj)
        if pendingTelemetry.count > Self.maxPending {
            pendingTelemetry.removeFirst(pendingTelemetry.count - Self.maxPending)
        }
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

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
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

    static func clock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
