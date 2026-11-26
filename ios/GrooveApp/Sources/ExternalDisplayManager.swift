import AVFoundation
import CoreMedia
import QuartzCore
import SwiftUI
import UIKit

// MARK: - UIApplicationDelegate & UIWindowSceneDelegate Bridge

/// Routes non-interactive external display `UISceneSession`s (AirPlay / wired TV) to `ExternalDisplaySceneDelegate`
/// while leaving `.windowApplication` scenes to SwiftUI's `WindowGroup` lifecycle.
final class ExternalDisplayAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if ExternalDisplayManager.isExternalSessionRole(connectingSceneSession.role) {
            let config = UISceneConfiguration(
                name: ExternalDisplayManager.sceneConfigurationName,
                sessionRole: connectingSceneSession.role
            )
            config.delegateClass = ExternalDisplaySceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}

/// UIKit scene delegate referenced by `Info.plist` (`UIWindowSceneSessionRoleExternalDisplayNonInteractive`)
/// and `ExternalDisplayAppDelegate`. Attaches a full-screen `UIWindow` hosting `ExternalDisplayManager.shared.stageBuilder`.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene,
              ExternalDisplayManager.isExternalSessionRole(session.role) else {
            return
        }
        window = ExternalDisplayManager.shared.attachExternalScene(windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if let windowScene = scene as? UIWindowScene {
            ExternalDisplayManager.shared.detachExternalScene(windowScene)
        }
        window = nil
    }
}

// MARK: - ExternalDisplayManager

/// Manages the dedicated 16:9 external AirPlay/TV `UIWindowScene`, `AVAudioSession` route/latency observation,
/// pluggable TV stage builder, and the Phase-1 Host-Clock Flash+Click Sync Probe + Rear-Camera Mirroring Spike.
@MainActor
final class ExternalDisplayManager: ObservableObject {
    static let shared = ExternalDisplayManager()

    nonisolated static let sceneConfigurationName = "External Display"
    nonisolated static let tvVideoLeadOffsetDefaultsKey = "GrooveCoach.tvVideoLeadOffsetMs"

    /// Default 16:9 stage view mounted before `CoachingStageCoordinator` (Order #12) installs `TVCoachingStageView`.
    static let defaultStageBuilder: @MainActor () -> AnyView = {
        AnyView(AirPlaySyncSpikeStageView())
    }

    // MARK: Published External Scene & Audio Route State

    @Published private(set) var isConnected: Bool = false
    var isExternalDisplayConnected: Bool { isConnected }

    @Published private(set) var screenBounds: CGRect = .zero
    @Published private(set) var screenScale: Double = 1.0
    @Published private(set) var audioRouteUID: String = "none"
    @Published private(set) var audioPortTypes: [String] = []
    @Published private(set) var audioPortNames: [String] = []
    @Published private(set) var outputLatencyMs: Double = 0.0

    /// Host-time lead offset (ms) applied to TV video / flash scheduling (`> 0` advances video relative to audio).
    @Published var tvVideoLeadOffsetMs: Double

    /// Pluggable 16:9 external stage builder; defaults to the Gate 1 AirPlay Spike & Host-Clock Flash+Click Sync Probe.
    @Published var stageBuilder: @MainActor () -> AnyView

    /// Callback invoked when the user taps "Recalibrate Studio" in the Calibrate tab (§6.2 Tier-2 trigger e).
    var onRecalibrateStudioRequested: (() -> Void)?

    /// Optional 3-clap TV audio sync entrypoint; `nil` (hidden in UI) until Phase-3 Order #15 registers `ClapSyncController`.
    @Published var clapSyncAction: (() -> Void)? = nil

    /// Optional observer callback invoked whenever external display connection state changes.
    var onConnectionChanged: ((Bool) -> Void)?

    // MARK: Published Gate 1 Sync Probe & Rear-Mirroring Spike State

    @Published private(set) var isSyncProbeRunning: Bool = false
    @Published private(set) var isProbeFlashingWhite: Bool = false
    @Published private(set) var probeIndex: Int = 0
    @Published private(set) var probeBeatInBar: Int = 0
    @Published private(set) var lastScheduledFlashHostSeconds: Double = 0.0
    @Published private(set) var lastScheduledClickHostSeconds: Double = 0.0

    @Published private(set) var isSpikeRearPreviewRunning: Bool = false
    @Published var spikeRearPreviewMirrored: Bool = true
    @Published private(set) var spikeConnectionDiagnostics: String = "Rear preview idle"
    @Published fileprivate(set) var spikeCameraRevision: Int = 0

    // MARK: Private State

    private var started = false
    private weak var externalWindowScene: UIWindowScene?
    private var externalWindow: UIWindow?
    private var observers: [NSObjectProtocol] = []

    // Sync probe scheduling (16 bars of 4/4 at 120 BPM per cycle; beat 4 flashes white + plays accented click)
    private let probeMetronome = Metronome()
    private var probeDisplayLink: CADisplayLink?
    private var probeDisplayTarget: ProbeDisplayLinkTarget?
    private var probeCycleStartHostSeconds: Double = 0.0
    private var probeCycleDurationSeconds: Double = 0.0
    private var probeLastEmittedBar: Int = -1
    private static let probeBpm: Double = 120.0
    private static let probeBeatPeriod: Double = 60.0 / probeBpm
    private static let probeBarsPerCycle: Int = 16
    private static let probeFlashDurationSeconds: Double = 0.085

    // Minimal inline rear-camera session for Gate 1 preview mirroring verification
    let spikeCameraController = SpikeRearCameraController()

    private init() {
        let savedLead = UserDefaults.standard.object(forKey: Self.tvVideoLeadOffsetDefaultsKey) as? Double ?? 0.0
        self.tvVideoLeadOffsetMs = savedLead.isFinite ? savedLead : 0.0
        self.stageBuilder = Self.defaultStageBuilder

        spikeCameraController.onStateChanged = { [weak self] running, diagnostics in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSpikeRearPreviewRunning = running
                self.spikeConnectionDiagnostics = diagnostics
                self.spikeCameraRevision &+= 1
            }
        }
    }

    // MARK: - Lifecycle & Scene Attachment

    nonisolated static func isExternalSessionRole(_ role: UISceneSession.Role) -> Bool {
        role == .windowExternalDisplayNonInteractive
            || role.rawValue == "UIWindowSceneSessionRoleExternalDisplay"
    }

    func start() {
        guard !started else { return }
        started = true
        refreshAudioRouteMetrics()
        installObservers()
        reconcileConnectedScenes()
    }

    private func installObservers() {
        let nc = NotificationCenter.default

        observers.append(
            nc.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    ExternalDisplayManager.shared.reconcileConnectedScenes()
                }
            }
        )

        observers.append(
            nc.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    ExternalDisplayManager.shared.reconcileConnectedScenes()
                }
            }
        )

        observers.append(
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
                let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                MainActor.assumeIsolated {
                    ExternalDisplayManager.shared.handleAudioRouteChange(reasonRawValue: reasonRaw)
                }
            }
        )
    }

    func reconcileConnectedScenes() {
        let externalScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { Self.isExternalSessionRole($0.session.role) && $0.activationState != .unattached }

        if let activeExternal = externalScenes.first {
            _ = attachExternalScene(activeExternal)
        } else if let current = externalWindowScene {
            detachExternalScene(current)
        }
    }

    @discardableResult
    func attachExternalScene(_ windowScene: UIWindowScene) -> UIWindow? {
        guard Self.isExternalSessionRole(windowScene.session.role) else { return nil }
        if externalWindowScene === windowScene, let existing = externalWindow {
            return existing
        }

        let rootView = ExternalDisplayRootHostView(manager: self)
        let hostController = UIHostingController(rootView: rootView)
        hostController.view.backgroundColor = .black

        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        window.rootViewController = hostController
        // Keep `isHidden = false` rather than `makeKeyAndVisible()` so non-interactive external displays
        // never steal keyboard / first-responder focus from phone text fields.
        window.isHidden = false

        externalWindowScene = windowScene
        externalWindow = window
        isConnected = true
        screenBounds = windowScene.screen.bounds
        screenScale = Double(windowScene.screen.scale)
        refreshAudioRouteMetrics()

        DebugLog.info(
            "external_scene connected bounds=\(screenBoundsString) scale=\(screenScale) "
            + "res=\(externalResolution) route=\(audioRouteUID) latencyMs=\(String(format: "%.1f", outputLatencyMs))"
        )
        emitExternalSceneEvent()
        onConnectionChanged?(true)
        return window
    }

    func detachExternalScene(_ windowScene: UIWindowScene) {
        guard externalWindowScene === windowScene else { return }

        stopSyncProbe()
        externalWindow?.isHidden = true
        externalWindow?.rootViewController = nil
        externalWindow = nil
        externalWindowScene = nil

        isConnected = false
        screenBounds = .zero
        screenScale = 1.0
        refreshAudioRouteMetrics()

        DebugLog.info(
            "external_scene disconnected route=\(audioRouteUID) latencyMs=\(String(format: "%.1f", outputLatencyMs))"
        )
        emitExternalSceneEvent()
        onConnectionChanged?(false)
    }

    // MARK: - Pluggable Stage Builder Helpers

    func setStage<Content: View>(@ViewBuilder _ builder: @escaping @MainActor () -> Content) {
        stageBuilder = { AnyView(builder()) }
    }

    func resetStageBuilder() {
        stageBuilder = Self.defaultStageBuilder
    }

    /// Prevents `AVPlayer` from hijacking the external `UIWindowScene` with full-screen AirPlay Video (§4.1, §11.1).
    static func configurePlayerForCompositeStage(_ player: AVPlayer) {
        player.allowsExternalPlayback = false
    }

    // MARK: - Studio Recalibration Trigger

    @discardableResult
    func requestRecalibrateStudio() -> Bool {
        DebugLog.info("recalibrate_studio_requested hasHandler=\(onRecalibrateStudioRequested != nil)")
        guard let handler = onRecalibrateStudioRequested else {
            return false
        }
        handler()
        return true
    }

    // MARK: - Audio Route & Telemetry Formatting

    var screenBoundsString: String {
        guard isConnected, screenBounds.width > 0, screenBounds.height > 0 else {
            return "0x0"
        }
        return "\(Int(screenBounds.width.rounded()))x\(Int(screenBounds.height.rounded()))"
    }

    var externalResolution: String {
        guard isConnected, screenBounds.width > 0, screenBounds.height > 0 else {
            return "0x0"
        }
        let pxW = Int((Double(screenBounds.width) * screenScale).rounded())
        let pxH = Int((Double(screenBounds.height) * screenScale).rounded())
        return "\(pxW)x\(pxH)"
    }

    var audioRouteSummary: String {
        if audioPortNames.isEmpty {
            return audioRouteUID
        }
        return "\(audioPortNames.joined(separator: ", ")) (\(audioPortTypes.joined(separator: ",")))"
    }

    func refreshAudioRouteMetrics() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let uids = outputs.map { $0.uid }.filter { !$0.isEmpty }
        audioRouteUID = uids.isEmpty ? "none" : uids.joined(separator: ",")
        audioPortTypes = outputs.map { $0.portType.rawValue }
        audioPortNames = outputs.map { $0.portName }
        outputLatencyMs = session.outputLatency * 1000.0
    }

    private func handleAudioRouteChange(reasonRawValue: UInt?) {
        // Refresh external screen metrics too if still attached.
        if let ws = externalWindowScene {
            screenBounds = ws.screen.bounds
            screenScale = Double(ws.screen.scale)
        }
        refreshAudioRouteMetrics()
        let reasonDesc: String
        if let raw = reasonRawValue, let reason = AVAudioSession.RouteChangeReason(rawValue: raw) {
            reasonDesc = String(describing: reason.rawValue)
        } else {
            reasonDesc = "unknown"
        }
        DebugLog.info(
            "audio_route_change reason=\(reasonDesc) connected=\(isConnected) "
            + "route=\(audioRouteUID) ports=\(audioPortTypes.joined(separator: ",")) "
            + "latencyMs=\(String(format: "%.1f", outputLatencyMs))"
        )
        emitExternalSceneEvent()
    }

    func emitExternalSceneEvent() {
        DebugLink.shared.sendEvent(
            kind: "external_scene",
            fields: [
                "connected": isConnected,
                "screenBounds": screenBoundsString,
                "scale": screenScale,
                "audioRouteUID": audioRouteUID,
                "audioPortTypes": audioPortTypes,
                "outputLatencyMs": outputLatencyMs
            ]
        )
    }

    // MARK: - Host-Clock Beat-4 Flash + Click Sync Probe

    func toggleSyncProbe() {
        if isSyncProbeRunning {
            stopSyncProbe()
        } else {
            startSyncProbe()
        }
    }

    func startSyncProbe() {
        stopSyncProbe()
        refreshAudioRouteMetrics()
        guard scheduleNextProbeCycle() else { return }

        isSyncProbeRunning = true
        let target = ProbeDisplayLinkTarget { [weak self] timestamp, targetTimestamp in
            MainActor.assumeIsolated {
                self?.tickSyncProbe(timestamp: timestamp, targetTimestamp: targetTimestamp)
            }
        }
        let link = CADisplayLink(target: target, selector: #selector(ProbeDisplayLinkTarget.step(_:)))
        link.add(to: .main, forMode: .common)
        probeDisplayTarget = target
        probeDisplayLink = link
    }

    func stopSyncProbe() {
        probeDisplayLink?.invalidate()
        probeDisplayLink = nil
        probeDisplayTarget = nil
        probeMetronome.stop()
        if isSyncProbeRunning {
            isSyncProbeRunning = false
        }
        if isProbeFlashingWhite {
            isProbeFlashingWhite = false
        }
        if probeBeatInBar != 0 {
            probeBeatInBar = 0
        }
    }

    /// Commits a measured `tvVideoLeadOffsetMs` value, persists it to `UserDefaults`, and emits `av_sync_probe`.
    func commitTVVideoLeadOffsetMs(_ newOffsetMs: Double) {
        let clamped = min(500.0, max(-250.0, newOffsetMs.isFinite ? newOffsetMs : 0.0))
        tvVideoLeadOffsetMs = clamped
        UserDefaults.standard.set(clamped, forKey: Self.tvVideoLeadOffsetDefaultsKey)
        refreshAudioRouteMetrics()

        let clickHost = lastScheduledClickHostSeconds > 0
            ? lastScheduledClickHostSeconds
            : AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let flashHost = clickHost - (clamped / 1000.0)
        lastScheduledFlashHostSeconds = flashHost
        lastScheduledClickHostSeconds = clickHost

        emitAVSyncProbeEvent(
            index: probeIndex,
            scheduledFlashHostSeconds: flashHost,
            scheduledClickHostSeconds: clickHost
        )
    }

    private func scheduleNextProbeCycle() -> Bool {
        let totalBeats = Self.probeBarsPerCycle * 4
        let clickTimes = (0..<totalBeats).map { Double($0) * Self.probeBeatPeriod }
        let accented = Set((0..<totalBeats).filter { $0 % 4 == 3 })
        let duration = Double(totalBeats) * Self.probeBeatPeriod
        do {
            let scheduled = try probeMetronome.startScheduled(
                clickTimes: clickTimes,
                accented: accented,
                duration: duration + 0.1
            )
            refreshAudioRouteMetrics()
            probeCycleStartHostSeconds = scheduled.hostSeconds
            probeCycleDurationSeconds = duration
            probeLastEmittedBar = -1
            return true
        } catch {
            DebugLog.error("av_sync_probe audio start failed: \(error.localizedDescription)")
            return false
        }
    }

    private func tickSyncProbe(timestamp: Double, targetTimestamp: Double) {
        guard isSyncProbeRunning else { return }

        // Compute target presentation time on the exact same `AVAudioTime` host-clock timeline as `Metronome`.
        let nowHost = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let vsyncLead = max(0.0, targetTimestamp - timestamp)
        let targetHost = nowHost + vsyncLead

        let elapsed = targetHost - probeCycleStartHostSeconds
        if elapsed >= probeCycleDurationSeconds {
            if !scheduleNextProbeCycle() {
                stopSyncProbe()
            }
            return
        }
        guard elapsed >= 0.0 else {
            if isProbeFlashingWhite { isProbeFlashingWhite = false }
            if probeBeatInBar != 0 { probeBeatInBar = 0 }
            return
        }

        let beatFloat = elapsed / Self.probeBeatPeriod
        let globalBeat = Int(beatFloat)
        let barIndex = globalBeat / 4
        let beatNumber = (globalBeat % 4) + 1
        if probeBeatInBar != beatNumber {
            probeBeatInBar = beatNumber
        }

        // Check active flash window across surrounding bars so positive or negative `tvVideoLeadOffsetMs` works cleanly.
        let leadSeconds = tvVideoLeadOffsetMs / 1000.0
        var flashingNow = false
        let minBar = max(0, barIndex - 1)
        let maxBar = min(Self.probeBarsPerCycle - 1, barIndex + 1)
        for candidateBar in minBar...maxBar {
            let clickHost = probeCycleStartHostSeconds + Double(candidateBar * 4 + 3) * Self.probeBeatPeriod
            let flashHost = clickHost - leadSeconds
            if targetHost >= flashHost && targetHost <= flashHost + Self.probeFlashDurationSeconds {
                flashingNow = true
            }
            if candidateBar > probeLastEmittedBar && targetHost >= flashHost {
                probeLastEmittedBar = candidateBar
                probeIndex += 1
                lastScheduledFlashHostSeconds = flashHost
                lastScheduledClickHostSeconds = clickHost
                refreshAudioRouteMetrics()
                emitAVSyncProbeEvent(
                    index: probeIndex,
                    scheduledFlashHostSeconds: flashHost,
                    scheduledClickHostSeconds: clickHost
                )
            }
        }

        if isProbeFlashingWhite != flashingNow {
            isProbeFlashingWhite = flashingNow
        }
    }

    private func emitAVSyncProbeEvent(
        index: Int,
        scheduledFlashHostSeconds: Double,
        scheduledClickHostSeconds: Double
    ) {
        DebugLink.shared.sendEvent(
            kind: "av_sync_probe",
            fields: [
                "probeIndex": index,
                "scheduledFlashHostSeconds": scheduledFlashHostSeconds,
                "scheduledClickHostSeconds": scheduledClickHostSeconds,
                "audioRouteUID": audioRouteUID,
                "outputLatencyMs": outputLatencyMs,
                "tvVideoLeadOffsetMs": tvVideoLeadOffsetMs,
                "externalResolution": externalResolution
            ]
        )
    }

    // MARK: - Gate 1 Rear-Camera Preview Mirroring Spike

    func setSpikeRearPreviewEnabled(_ enabled: Bool) {
        if enabled {
            startSpikeRearPreview()
        } else {
            stopSpikeRearPreview()
        }
    }

    func startSpikeRearPreview() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                self.spikeConnectionDiagnostics = "Camera permission denied"
                return
            }
            self.spikeCameraController.start()
        }
    }

    func stopSpikeRearPreview() {
        spikeCameraController.stop()
    }

    fileprivate func updatePreviewLayerConnectionReport(_ report: String) {
        if spikeConnectionDiagnostics != report {
            spikeConnectionDiagnostics = report
            DebugLog.info("spike_rear_preview \(report)")
        }
    }
}

// MARK: - CADisplayLink Target Helper

private final class ProbeDisplayLinkTarget: NSObject {
    private let handler: (Double, Double) -> Void

    init(handler: @escaping (Double, Double) -> Void) {
        self.handler = handler
    }

    @objc func step(_ link: CADisplayLink) {
        handler(link.timestamp, link.targetTimestamp)
    }
}

// MARK: - Gate 1 Minimal Rear-Camera Capture Controller & Preview

/// Minimal opt-in rear-camera `AVCaptureSession` used only during the Gate 1 AirPlay spike to verify
/// `AVCaptureConnection` mirroring properties on `.back` for both `AVCaptureVideoDataOutput` and
/// `AVCaptureVideoPreviewLayer`, while feeding `CameraFrameStore` for Debug Link external-screen compositing.
final class SpikeRearCameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onStateChanged: ((Bool, String) -> Void)?

    private let queue = DispatchQueue(label: "groove.external.spikeCamera")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var configured = false
    private(set) var outputConnectionSummary: String = "output=unconfigured"

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.configureSession()
            }
            guard self.configured else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.onStateChanged?(self.session.isRunning, self.outputConnectionSummary)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.onStateChanged?(false, "Rear preview stopped")
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            onStateChanged?(false, "Rear wide camera unavailable")
            return
        }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            onStateChanged?(false, "Rear video output unavailable")
            return
        }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            let defaultAuto = connection.automaticallyAdjustsVideoMirroring
            let defaultMirrored = connection.isVideoMirrored
            let supported = connection.isVideoMirroringSupported
            if supported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            outputConnectionSummary =
                "backOutput(supported=\(supported), defaultAuto=\(defaultAuto), "
                + "defaultMirrored=\(defaultMirrored), lockedMirrored=\(connection.isVideoMirrored))"
        }

        session.commitConfiguration()
        configured = true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            CameraFrameStore.shared.offer(pixelBuffer)
        }
    }
}

/// Minimal inline `AVCaptureVideoPreviewLayer` host for the Gate 1 external-display rear-mirroring check.
struct SpikeRearCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool
    let revision: Int
    var onConnectionConfigured: (@MainActor (String) -> Void)?

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        var desiredMirrored: Bool = true
        var onReport: (@MainActor (String) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            applyConnectionConfiguration()
        }

        func applyConnectionConfiguration() {
            guard let connection = previewLayer.connection else { return }
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            let supported = connection.isVideoMirroringSupported
            if supported {
                // Must disable `automaticallyAdjustsVideoMirroring` before mutating `isVideoMirrored`.
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = desiredMirrored
            }
            let report =
                "preview(supported=\(supported), auto=\(connection.automaticallyAdjustsVideoMirroring), "
                + "mirrored=\(connection.isVideoMirrored))"
            onReport?(report)
        }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.desiredMirrored = mirrored
        view.onReport = onConnectionConfigured
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.applyConnectionConfiguration()
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        _ = revision
        uiView.desiredMirrored = mirrored
        uiView.onReport = onConnectionConfigured
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.applyConnectionConfiguration()
    }
}

// MARK: - External Display Root & Default 16:9 Spike Stage View

/// Root wrapper hosted inside the external `UIWindowScene` so swaps of `ExternalDisplayManager.stageBuilder`
/// immediately update the TV canvas without recreating the `UIWindow`.
struct ExternalDisplayRootHostView: View {
    @ObservedObject var manager: ExternalDisplayManager

    var body: some View {
        manager.stageBuilder()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }
}

/// Default 16:9 landscape stage rendered on the external AirPlay/TV `UIWindowScene` during Phase 1 / Device Gate 1:
/// - Full-screen `#FFFFFF` white flash synchronized to Beat-4 `Metronome` clicks on `CMClockGetHostTimeClock()`
/// - 10-foot readout of external resolution, scale, audio route UID/ports, `outputLatencyMs`, and `tvVideoLeadOffsetMs`
/// - Inline `SpikeRearCameraPreview` verifying `.back` `AVCaptureVideoPreviewLayer` mirroring from 2–4 m.
struct AirPlaySyncSpikeStageView: View {
    @ObservedObject private var manager = ExternalDisplayManager.shared

    var body: some View {
        ZStack {
            if manager.isProbeFlashingWhite {
                Color.white.ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("BEAT 4 · FLASH + CLICK")
                        .font(.system(size: 72, weight: .black, design: .rounded))
                        .foregroundStyle(.black)
                    Text("PROBE #\(manager.probeIndex) · LEAD \(String(format: "%+.0f ms", manager.tvVideoLeadOffsetMs))")
                        .font(.system(size: 38, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                }
            } else {
                Color(red: 0.03, green: 0.04, blue: 0.07).ignoresSafeArea()
                stageContent
            }
        }
    }

    private var stageContent: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "tv.badge.wifi")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.cyan)
                    Text("GROOVE COACH · TV STAGE SPIKE")
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 10) {
                    metricRow(label: "TV SCENE", value: "\(manager.externalResolution) px (\(manager.screenBoundsString) pt @ \(String(format: "%.1fx", manager.screenScale)))")
                    metricRow(label: "AUDIO ROUTE", value: manager.audioRouteSummary)
                    metricRow(label: "OS AUDIO LATENCY", value: String(format: "%.1f ms", manager.outputLatencyMs))
                    metricRow(label: "TV VIDEO LEAD", value: String(format: "%+.1f ms", manager.tvVideoLeadOffsetMs))
                    metricRow(label: "REAR MIRROR CHECK", value: manager.spikeConnectionDiagnostics)
                }
                .padding(20)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))

                Spacer(minLength: 0)

                beatBar
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(Color.cyan.opacity(0.6), lineWidth: 3)
                    )

                if manager.isSpikeRearPreviewRunning {
                    let outputSummary = manager.spikeCameraController.outputConnectionSummary
                    SpikeRearCameraPreview(
                        session: manager.spikeCameraController.session,
                        mirrored: manager.spikeRearPreviewMirrored,
                        revision: manager.spikeCameraRevision,
                        onConnectionConfigured: { previewReport in
                            manager.updatePreviewLayerConnectionReport("\(previewReport) · \(outputSummary)")
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(alignment: .topLeading) {
                        Text(manager.spikeRearPreviewMirrored ? "REAR CAMERA · MIRRORED (STEP LEFT → SCREEN LEFT)" : "REAR CAMERA · UNMIRRORED")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.cyan, in: Capsule())
                            .padding(16)
                    }
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                        Text("Rear-Camera Mirror Check Idle")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Enable 'Spike Rear-Camera Preview' in the Calibrate tab on iPhone\nto verify 9:16 rear mirroring on this 16:9 TV stage.")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(36)
    }

    private var beatBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                manager.isSyncProbeRunning
                    ? "HOST-CLOCK SYNC PROBE ACTIVE · PROBE #\(manager.probeIndex) (120 BPM · FLASH ON BEAT 4)"
                    : "HOST-CLOCK FLASH+CLICK SYNC PROBE IDLE (START ON IPHONE CALIBRATE TAB)"
            )
            .font(.system(size: 22, weight: .bold, design: .monospaced))
            .foregroundStyle(manager.isSyncProbeRunning ? .yellow : .secondary)

            HStack(spacing: 16) {
                ForEach(1...4, id: \.self) { beat in
                    let active = manager.probeBeatInBar == beat
                    let isFlashBeat = beat == 4
                    Text(isFlashBeat ? "4 · FLASH" : "\(beat)")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            active
                                ? (isFlashBeat ? Color.yellow : Color.cyan)
                                : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                        .foregroundStyle(active ? Color.black : Color.white.opacity(0.75))
                }
            }
        }
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
                .frame(width: 220, alignment: .leading)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
    }
}
