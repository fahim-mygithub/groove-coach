import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Debug Link screen sharing: what is on screen, about once a second, to `POST /screen`. Captures first the phone
/// `UIWindowScene` (`X-Screen-Role: phone`, native resolution, JPEG quality 0.7) and then any connected external
/// display `UIWindowScene` (`X-Screen-Role: external`, `0.5x` scale, JPEG quality 0.65) sequentially inside a single
/// `inFlight` task. A tick is skipped while the previous upload is still in flight, when the app is not active, and
/// while the link is off or has no server.
///
/// Camera preview: `drawHierarchy` leaves `AVCaptureVideoPreviewLayer` black, so the latest camera frame (handed
/// over by `PracticeCamera` through `CameraFrameStore`) is composited into each visible preview layer's video rect
/// across both phone and external scenes, replacing only the black pixels there, so the skeleton / calibration HUD
/// drawn on top stays on top. Chosen over ReplayKit's in-app `RPScreenRecorder.startCapture` because that asks the
/// owner "Allow screen recording?" on every app session (no zero-configuration), stops whenever the app backgrounds,
/// and runs alongside the take recorder. `AVPlayerLayer` (lesson video) is not composited and shows black.
@MainActor
final class ScreenStreamer {
    static let shared = ScreenStreamer()

    static let interval = 1.0
    static let jpegQuality: CGFloat = 0.7
    static let externalScaleFactor: CGFloat = 0.5
    static let externalJpegQuality: CGFloat = 0.65

    private struct SceneCapture: Sendable {
        let role: String
        let screenName: String
        let snapshot: CGImage
        let scale: CGFloat
        let quality: CGFloat
        let previews: [PreviewSlot]
    }

    private struct UploadResult: Sendable {
        let ok: Bool
        let failure: String?
        let bytes: Int
        let screen: String
        let role: String
    }

    private var timer: Timer?
    private var inFlight = false
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: config)
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { ScreenStreamer.shared.tick() }
        }
        t.tolerance = 0.15
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard !inFlight else { return }
        guard let base = DebugLink.shared.streamBase,
              UIApplication.shared.applicationState == .active else {
            CameraFrameStore.shared.setWanted(false)
            return
        }

        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var orderedScenes: [(scene: UIWindowScene, isExternal: Bool)] = []
        if let phoneScene = windowScenes.first(where: { !Self.isExternal($0) && $0.activationState == .foregroundActive }) {
            orderedScenes.append((phoneScene, false))
        }
        for extScene in windowScenes where Self.isExternal(extScene) {
            if extScene.activationState == .foregroundActive || extScene.activationState == .foregroundInactive {
                orderedScenes.append((extScene, true))
            }
        }
        guard !orderedScenes.isEmpty else {
            CameraFrameStore.shared.setWanted(false)
            return
        }

        let screenName = DebugLink.shared.currentScreen
        var captures: [SceneCapture] = []
        for item in orderedScenes {
            if let cap = Self.captureScene(item.scene, isExternal: item.isExternal, screenName: screenName) {
                captures.append(cap)
            }
        }

        let anyPreviews = captures.contains { !$0.previews.isEmpty }
        CameraFrameStore.shared.setWanted(anyPreviews)
        guard !captures.isEmpty else { return }

        let camera = anyPreviews ? CameraFrameStore.shared.latest(maxAge: 2) : nil
        let device = DebugLinkDevice.model
        let session = self.session
        inFlight = true
        Task.detached(priority: .utility) {
            var results: [UploadResult] = []
            for capture in captures {
                let composed = ScreenCompositor.compose(capture.snapshot, scale: capture.scale,
                                                        previews: capture.previews, camera: camera) ?? capture.snapshot
                var ok = false
                var failure: String?
                var bytes = 0
                if let jpeg = ScreenCompositor.jpeg(composed, quality: capture.quality) {
                    bytes = jpeg.count
                    let cleanScreen = String(capture.screenName.unicodeScalars
                        .filter { $0.isASCII && $0.value >= 0x20 }
                        .map(Character.init))
                    var req = URLRequest(url: base.appendingPathComponent("screen"))
                    req.httpMethod = "POST"
                    req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
                    req.setValue(cleanScreen, forHTTPHeaderField: "X-Screen-Name")
                    req.setValue(capture.role, forHTTPHeaderField: "X-Screen-Role")
                    req.setValue(device, forHTTPHeaderField: "X-Device")
                    req.setValue("\(composed.width)x\(composed.height)", forHTTPHeaderField: "X-Size")
                    req.httpBody = jpeg
                    do {
                        let (_, resp) = try await session.data(for: req)
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        ok = (200..<300).contains(code)
                        if !ok { failure = "screen(\(capture.role)): HTTP \(code)" }
                    } catch {
                        failure = error.localizedDescription
                    }
                } else {
                    failure = "screen(\(capture.role)): JPEG encode failed"
                }
                results.append(UploadResult(ok: ok, failure: failure, bytes: bytes,
                                            screen: capture.screenName, role: capture.role))
            }
            await ScreenStreamer.shared.finished(results)
        }
    }

    private func finished(_ results: [UploadResult]) {
        inFlight = false
        for r in results {
            let label = r.role == "external" ? "\(r.screen):external" : r.screen
            DebugLink.shared.screenFinished(ok: r.ok, failure: r.failure, bytes: r.bytes, screen: label)
        }
    }

    private static func isExternal(_ scene: UIWindowScene) -> Bool {
        if scene.session.role != .windowApplication { return true }
        return scene.screen != UIScreen.main
    }

    private static func captureScene(_ scene: UIWindowScene, isExternal: Bool, screenName: String) -> SceneCapture? {
        let windows = scene.windows.filter { !$0.isHidden && $0.alpha > 0 }.sorted { $0.windowLevel < $1.windowLevel }
        guard let main = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return nil }
        let bounds = main.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let nativeScale = main.screen.scale
        let scale = isExternal ? max(0.25, nativeScale * Self.externalScaleFactor) : nativeScale
        let quality = isExternal ? Self.externalJpegQuality : Self.jpegQuality

        var previews: [PreviewSlot] = []
        for w in windows { Self.collectPreviews(w.layer, window: w, into: &previews) }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(bounds)
            for w in windows {
                w.drawHierarchy(in: w.convert(w.bounds, to: main), afterScreenUpdates: false)
            }
        }
        guard let cg = image.cgImage else { return nil }
        return SceneCapture(
            role: isExternal ? "external" : "phone",
            screenName: screenName,
            snapshot: cg,
            scale: scale,
            quality: quality,
            previews: previews
        )
    }

    /// Visible `AVCaptureVideoPreviewLayer`s, in `main`-window points (all windows share the screen origin).
    private static func collectPreviews(_ layer: CALayer, window: UIWindow, into out: inout [PreviewSlot]) {
        if layer.isHidden || layer.opacity <= 0.01 { return }
        if let preview = layer as? AVCaptureVideoPreviewLayer {
            if preview.session?.isRunning == true {
                let rect = preview.convert(preview.bounds, to: window.layer)
                let onScreen = window.convert(rect, to: window.screen.coordinateSpace)
                if onScreen.width > 1, onScreen.height > 1 {
                    out.append(PreviewSlot(rect: onScreen,
                                           mirrored: preview.connection?.isVideoMirrored ?? true,
                                           fill: preview.videoGravity == .resizeAspectFill))
                }
            }
            return
        }
        for sub in layer.sublayers ?? [] { collectPreviews(sub, window: window, into: &out) }
    }
}

/// One camera preview on screen: its layer rect (points, screen space), mirroring and gravity.
struct PreviewSlot: Sendable {
    let rect: CGRect
    let mirrored: Bool
    let fill: Bool
}

/// Latest camera frame for the screen composite. `offer` is called on the camera queue for every frame and only
/// converts one (full-size CGImage, CoreImage) every `interval` while the streamer has seen a preview on screen.
final class CameraFrameStore: @unchecked Sendable {
    static let shared = CameraFrameStore()
    static let interval = 0.5

    private let lock = NSLock()
    private var wanted = false
    private var lastConvert = 0.0
    private var image: CGImage?
    private var imageTime = 0.0
    private let context = CIContext(options: [.cacheIntermediates: false])

    func setWanted(_ value: Bool) {
        lock.lock()
        wanted = value
        if !value { image = nil }
        lock.unlock()
    }

    func offer(_ pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        lock.lock()
        let due = wanted && now - lastConvert >= Self.interval
        if due { lastConvert = now }
        lock.unlock()
        guard due else { return }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return }
        lock.lock()
        image = cg
        imageTime = now
        lock.unlock()
    }

    func latest(maxAge: Double) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let image, CACurrentMediaTime() - imageTime <= maxAge else { return nil }
        return image
    }
}

/// Composite + JPEG (thread-safe, runs detached).
enum ScreenCompositor {
    /// Pixels at or below this (each of R, G, B) inside a preview's video rect count as "preview black".
    static let blackThreshold: UInt8 = 10

    static func compose(_ snapshot: CGImage, scale: CGFloat, previews: [PreviewSlot], camera: CGImage?) -> CGImage? {
        guard let camera, !previews.isEmpty else { return snapshot }
        let w = snapshot.width, h = snapshot.height
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let base = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: space, bitmapInfo: info),
              let cam = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: info) else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        base.draw(snapshot, in: full)

        let camAspect = CGFloat(camera.width) / CGFloat(max(1, camera.height))
        var keyRects: [CGRect] = []
        for slot in previews {
            // Points -> pixels, flipped to CoreGraphics' bottom-left origin.
            let layer = CGRect(x: slot.rect.minX * scale, y: CGFloat(h) - slot.rect.maxY * scale,
                               width: slot.rect.width * scale, height: slot.rect.height * scale)
            var video = layer
            let layerAspect = layer.width / max(1, layer.height)
            if (camAspect > layerAspect) != slot.fill {
                video.size.height = layer.width / camAspect
            } else {
                video.size.width = layer.height * camAspect
            }
            video.origin.x = layer.midX - video.width / 2
            video.origin.y = layer.midY - video.height / 2
            cam.saveGState()
            cam.clip(to: layer)
            if slot.mirrored {
                cam.translateBy(x: video.midX, y: 0)
                cam.scaleBy(x: -1, y: 1)
                cam.translateBy(x: -video.midX, y: 0)
            }
            cam.draw(camera, in: video)
            cam.restoreGState()
            keyRects.append(video.intersection(layer).intersection(full).integral.intersection(full))
        }

        guard let bp = base.data?.assumingMemoryBound(to: UInt8.self),
              let cp = cam.data?.assumingMemoryBound(to: UInt8.self) else { return base.makeImage() }
        let rowBytes = base.bytesPerRow
        let camRowBytes = cam.bytesPerRow
        let t = blackThreshold
        for r in keyRects where !r.isNull && r.width >= 1 && r.height >= 1 {
            // Bitmap memory rows run top-down; CG rects are bottom-up.
            let x0 = Int(r.minX), x1 = Int(r.maxX)
            let rowTop = h - Int(r.maxY), rowBottom = h - Int(r.minY)
            for row in max(0, rowTop)..<min(h, rowBottom) {
                let b = bp + row * rowBytes
                let c = cp + row * camRowBytes
                var x = max(0, x0)
                while x < min(w, x1) {
                    let i = x * 4
                    if b[i] <= t && b[i + 1] <= t && b[i + 2] <= t {
                        b[i] = c[i]
                        b[i + 1] = c[i + 1]
                        b[i + 2] = c[i + 2]
                        b[i + 3] = 255
                    }
                    x += 1
                }
            }
        }
        return base.makeImage()
    }

    static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
