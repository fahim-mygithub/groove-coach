import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import GrooveCore
import UIKit

/// Live 2D joints for the camera overlay: normalised 0...1 with y down, mirrored like the preview.
struct LiveSkeleton {
    var joints: [String: CGPoint]
    /// width / height of the camera image.
    var imageAspect: Double
}

/// One live calibration sample, delivered on the camera analysis queue while calibration is active.
struct CalibrationCameraSample {
    /// Host-clock seconds of the camera frame.
    let time: Double
    /// The 33 MediaPipe points in raw (un-mirrored) normalised image coordinates; empty without a person.
    let landmarks: [CalibrationLandmark]
    /// The live canonical frame (nil without a person).
    let frame: GrooveScoringEngine.RawPoseFrame?
    /// The portrait 32BGRA camera buffer (valid for the duration of the callback; don't keep it).
    let pixelBuffer: CVPixelBuffer
    /// Active camera mode for this frame (`.rearLiDAR`, `.rearWide`, `.frontSelfView`).
    let cameraMode: CameraMode
    /// Portrait vertical FoV in degrees (`videoFieldOfView` on sensor long side, fallback `60.0°`).
    let verticalFoVDeg: Double
    /// Portrait narrow-axis horizontal FoV in degrees (`2 * atan((9/16) * tan(verticalFoVDeg / 2))`).
    let horizontalFoVDeg: Double
    /// Per-frame video intrinsics when delivered via `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`.
    let videoIntrinsics: CalibrationIntrinsics?
    /// Most recent throttled LiDAR depth reading when `cameraMode == .rearLiDAR`.
    let latestDepthSample: CalibrationDepthSample?

    init(
        time: Double,
        landmarks: [CalibrationLandmark],
        frame: GrooveScoringEngine.RawPoseFrame?,
        pixelBuffer: CVPixelBuffer,
        cameraMode: CameraMode = .frontSelfView,
        verticalFoVDeg: Double = CalibrationSensors.defaultVerticalFoVDeg,
        horizontalFoVDeg: Double = CalibrationSensors.portraitHorizontalFoVDeg(
            fromVerticalFoVDeg: CalibrationSensors.defaultVerticalFoVDeg
        ),
        videoIntrinsics: CalibrationIntrinsics? = nil,
        latestDepthSample: CalibrationDepthSample? = nil
    ) {
        self.time = time
        self.landmarks = landmarks
        self.frame = frame
        self.pixelBuffer = pixelBuffer
        self.cameraMode = cameraMode
        self.verticalFoVDeg = verticalFoVDeg
        self.horizontalFoVDeg = horizontalFoVDeg
        self.videoIntrinsics = videoIntrinsics
        self.latestDepthSample = latestDepthSample
    }
}

/// Rear-camera + LiDAR / front-camera capture for coaching and calibration
/// (spec: `docs/specs/2026-11-26-calibration-v2-plan.md` §§1.2, 3.1, 3.2, 5.1, 5.2, 5.4, 9.2, 10 #6):
/// - supports `CameraMode` (`.rearLiDAR`, `.rearWide`, `.frontSelfView`) capped at 30 fps;
/// - keeps `AVCaptureVideoDataOutput` upright (`videoRotationAngle = 90`) and explicitly un-mirrored;
/// - delivers per-frame video intrinsics (`isCameraIntrinsicMatrixDeliveryEnabled`) and FoV (`verticalFoVDeg`, `horizontalFoVDeg`);
/// - runs `AVCaptureDepthDataOutput` throttled to 8 Hz (`5–10 Hz`) in `.calibrating`, `1 Hz` in `.idle`, and
///   disabled (`0 Hz`, `connection.isEnabled = false`) during `.countIn`, `.recording`, and `.analyzing`;
/// - feeds `GestureRecognizer` via `GestureSample.fromMediaPipeNormalized` (`1.0 - y` fix) + `GestureMode`;
/// - reports rolling `liveFps` every `5.0 s` to `DebugLink.shared.recordPerfSample`.
///
/// Thread confinement: capture + recording state lives on `videoQueue`, live pose + gesture state on `analysisQueue`,
/// LiDAR depth extraction + RANSAC on `depthQueue`, and `@Published` properties are written on the main queue.
final class PracticeCamera: NSObject,
    ObservableObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureDepthDataOutputDelegate,
    @unchecked Sendable
{
    typealias Mode = CameraMode

    static let targetMaxFps: Double = 30.0
    static let calibratingDepthHz: Double = 8.0
    static let idleDepthHz: Double = 1.0
    static let disabledDepthHz: Double = 0.0
    static let perfReportIntervalS: Double = 5.0
    private static let minLiveJointConfidence: Float = 0.3

    let session = AVCaptureSession()

    @Published private(set) var skeleton = LiveSkeleton(joints: [:], imageAspect: 9.0 / 16.0)
    /// Live hand-shape label per dancer hand ("left" / "right").
    @Published private(set) var handShapes: [String: String] = [:]
    @Published private(set) var cameraError: String?
    /// Active resolved capture mode (`.rearLiDAR`, `.rearWide`, or `.frontSelfView`).
    @Published private(set) var cameraMode: CameraMode = .frontSelfView
    /// Portrait vertical FoV in degrees (`AVCaptureDevice.Format.videoFieldOfView`, fallback `60.0°`).
    @Published private(set) var verticalFoVDeg: Double = CalibrationSensors.defaultVerticalFoVDeg
    /// Portrait narrow-axis horizontal FoV in degrees (`2 * atan((9/16) * tan(verticalFoVDeg / 2))`).
    @Published private(set) var horizontalFoVDeg: Double = CalibrationSensors.portraitHorizontalFoVDeg(
        fromVerticalFoVDeg: CalibrationSensors.defaultVerticalFoVDeg
    )
    /// Rolling analyzed live pose FPS over the past 5 seconds.
    @Published private(set) var liveFps: Double = 0.0
    /// Pre-trigger overhead gesture hold progress (`0...1`), published at ~15 Hz for TV/phone HUD rings (§5.4).
    @Published private(set) var gestureHoldProgress: Double = 0.0

    /// Legacy 4-case gesture callback delivered on the main queue (`PracticeView` source-compatible).
    var onGesture: ((GestureCommand) -> Void)?
    /// Full v2 5-case gesture event callback (including `.doubleClap` during `.calibrating`), delivered on main queue.
    var onGestureEvent: ((GestureEvent) -> Void)?
    /// Full v2 gesture event + sample host-clock timestamp callback for `GestureRouter.route(_:at:)`, on main queue.
    var onGestureEventAtTime: ((GestureEvent, Double) -> Void)?
    /// Throttled LiDAR depth callback (`8 Hz` in `.calibrating`, `1 Hz` in `.idle`), delivered on main queue.
    var onDepthSample: ((CalibrationDepthSample) -> Void)?
    /// Optional provider returning the latest CoreMotion device-frame gravity `[gx, gy, gz]` for floor RANSAC.
    var deviceGravityProvider: (() -> [Double])? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _deviceGravityProvider
        }
        set {
            stateLock.lock()
            _deviceGravityProvider = newValue
            stateLock.unlock()
        }
    }

    /// Active `AVCaptureDevice` for exposure/ISO reads and AE/AWB lock (`CalibrationSensors`).
    private(set) var captureDevice: AVCaptureDevice?

    private let provider: PoseProvider
    private let output = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let videoQueue = DispatchQueue(label: "groove.practice.video")
    private let analysisQueue = DispatchQueue(label: "groove.practice.analysis")
    private let depthQueue = DispatchQueue(label: "groove.practice.depth", qos: .utility)
    private let stateLock = NSLock()

    // stateLock-protected cross-queue state
    private var preferredCameraMode: CameraMode?
    private var autoExternalDisplayConnected: Bool = false
    private var _activeCameraMode: CameraMode = .frontSelfView
    private var _portraitVideoWidth: Int = 720
    private var _portraitVideoHeight: Int = 1280
    private var _verticalFoVDeg: Double = CalibrationSensors.defaultVerticalFoVDeg
    private var _horizontalFoVDeg: Double = CalibrationSensors.portraitHorizontalFoVDeg(
        fromVerticalFoVDeg: CalibrationSensors.defaultVerticalFoVDeg
    )
    private var _latestVideoIntrinsics: CalibrationIntrinsics?
    private var _latestDepthSample: CalibrationDepthSample?
    private var _cachedDeviceGravity: [Double] = [0.0, -1.0, 0.0]
    private var _deviceGravityProvider: (() -> [Double])?
    private var explicitCoachingPhase: CoachingPhase?
    private var manualGestureMode: GestureMode?
    private var isCalibrationStreamActive: Bool = false
    private var isTakeRecordingActive: Bool = false
    private var _depthTargetHz: Double = 0.0

    // videoQueue state
    private var configured = false
    private var configuredMode: CameraMode?
    private var recorder: TakeRecorder?
    private var analysisBusy = false
    private var loggedVideoIntrinsicsOnce = false

    // analysisQueue state
    private var recognizer = GestureRecognizer()
    private var previousGestureLandmarks: [CalibrationLandmark]?
    private var lastPublish = 0.0
    private var lastPublishedHoldProgress = 0.0
    private var calibrationActive = false
    private var onCalibrationSample: ((CalibrationCameraSample) -> Void)?
    private var onCalibrationDepthSample: ((CalibrationDepthSample) -> Void)?
    private var analysisTimestamps: [Double] = []
    private var lastPerfReportTime = -Double.infinity

    // depthQueue state
    private var lastDepthSampleTime = -Double.infinity
    private var loggedDepthFormatOnce = false

    // Main-queue scene observers for automatic TV -> rearLiDAR fallback when `preferredCameraMode == nil`
    private var sceneObservers: [NSObjectProtocol] = []

    /// Preview is horizontally mirrored on both TV (`TVCameraPreview`) and phone (`CameraPreview`), so gesture
    /// horizontal travel and live skeleton `x` are mirrored (`1.0 - x`) to match what the dancer sees.
    private let mirrorForDisplay = true

    init(provider: PoseProvider = MediaPipePoseProvider.shared, initialCameraMode: CameraMode? = nil) {
        self.provider = provider
        self.preferredCameraMode = initialCameraMode
        if let initialCameraMode {
            self._activeCameraMode = initialCameraMode
            self.cameraMode = initialCameraMode
        }
        super.init()
        installExternalDisplayObservers()
    }

    deinit {
        let nc = NotificationCenter.default
        for token in sceneObservers {
            nc.removeObserver(token)
        }
    }

    // MARK: - Thread-Safe Accessors

    var activeCameraMode: CameraMode {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _activeCameraMode
    }

    var latestVideoIntrinsics: CalibrationIntrinsics? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _latestVideoIntrinsics
    }

    var latestDepthSample: CalibrationDepthSample? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _latestDepthSample
    }

    /// Updates cached CoreMotion device-frame gravity `[gx, gy, gz]` used by background LiDAR floor RANSAC.
    func updateDeviceGravity(_ gravity: [Double]) {
        guard gravity.count >= 3 else { return }
        stateLock.lock()
        _cachedDeviceGravity = [gravity[0], gravity[1], gravity[2]]
        stateLock.unlock()
    }

    // MARK: - Lifecycle & Camera Mode Selection

    func start() {
        let extConnected = Self.readExternalDisplayConnectedIfOnMain()
        stateLock.lock()
        if let extConnected {
            autoExternalDisplayConnected = extConnected
        }
        let desiredMode = resolveRequestedCameraModeLocked()
        stateLock.unlock()

        videoQueue.async { [weak self] in
            guard let self else { return }
            let resolvedHardwareMode = Self.resolveAvailableHardwareMode(for: desiredMode)
            if !self.configured || self.configuredMode != resolvedHardwareMode {
                self.configureSession(requestedMode: desiredMode)
            }
            self.applyDepthConnectionStateOnVideoQueue()
            if self.configured && !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        stopCalibration()
        stateLock.lock()
        isTakeRecordingActive = false
        explicitCoachingPhase = nil
        _depthTargetHz = Self.disabledDepthHz
        stateLock.unlock()

        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.analysisTimestamps.removeAll()
            self.lastPerfReportTime = -Double.infinity
            self.previousGestureLandmarks = nil
            self.recognizer.resetPreservingHoldLatch()
        }
        depthQueue.async { [weak self] in
            self?.lastDepthSampleTime = -Double.infinity
        }
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.recorder?.cancel()
            self.recorder = nil
            // Always unlock AE/AWB on stop (spec §3.3).
            CalibrationSensors.unlockDeviceExposureAndWhiteBalance(self.captureDevice)
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    /// Sets the preferred `CameraMode` (`nil` restores automatic external-display selection: `.rearLiDAR` when an
    /// AirPlay / external `UIWindowScene` is connected, `.frontSelfView` otherwise). Safe while running or stopped.
    func setCameraMode(_ mode: CameraMode?) {
        let extConnected = Self.readExternalDisplayConnectedIfOnMain()
        stateLock.lock()
        preferredCameraMode = mode
        if let extConnected {
            autoExternalDisplayConnected = extConnected
        }
        let desiredMode = resolveRequestedCameraModeLocked()
        stateLock.unlock()

        reconfigureForDesiredModeIfNeeded(desiredMode)
    }

    /// Convenience wrapper switching explicitly to `mode`.
    func switchCameraMode(to mode: CameraMode) {
        setCameraMode(mode)
    }

    // MARK: - Coaching Phase, Gesture Mode & Depth Throttle Synchronization

    /// Synchronizes `GestureMode` (with `resetPreservingHoldLatch()`) and LiDAR `AVCaptureDepthDataOutput` rate
    /// across coaching phases (`8 Hz` in `.calibrating`, `1 Hz` in `.idle`/`.results`/`.paused`, `0 Hz` disabled
    /// during `.countIn`/`.recording`/`.analyzing`/`.clapSync`; spec §§1.2, 5.2).
    func setCoachingPhase(_ phase: CoachingPhase) {
        stateLock.lock()
        explicitCoachingPhase = phase
        if phase != .recording {
            isTakeRecordingActive = false
        }
        recomputeRatesAndModesLocked()
        let targetGestureMode = effectiveGestureModeLocked()
        stateLock.unlock()

        syncGestureModeOnAnalysisQueue(targetGestureMode, forceResetLatch: true)
        videoQueue.async { [weak self] in
            self?.applyDepthConnectionStateOnVideoQueue()
        }
    }

    /// Directly updates `GestureRecognizer.mode` (invoking `resetPreservingHoldLatch()`) and aligns depth throttling.
    func setGestureMode(_ mode: GestureMode) {
        stateLock.lock()
        manualGestureMode = mode
        recomputeRatesAndModesLocked()
        let targetGestureMode = effectiveGestureModeLocked()
        stateLock.unlock()

        syncGestureModeOnAnalysisQueue(targetGestureMode, forceResetLatch: true)
        videoQueue.async { [weak self] in
            self?.applyDepthConnectionStateOnVideoQueue()
        }
    }

    /// Invokes `GestureRecognizer.resetPreservingHoldLatch()` on `analysisQueue` (§5.2).
    func resetGestureHoldLatch() {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.recognizer.resetPreservingHoldLatch()
            if self.lastPublishedHoldProgress != 0 {
                self.lastPublishedHoldProgress = 0
                DispatchQueue.main.async { self.gestureHoldProgress = 0 }
            }
        }
    }

    // MARK: - Calibration

    /// Routes live frames to `handler` (on `analysisQueue`), switches `GestureRecognizer` to `.calibrating`
    /// (single-clap repeat + double-clap skip; poses never trigger swipes/holds), and raises LiDAR depth to `8 Hz`.
    func startCalibration(
        _ handler: @escaping (CalibrationCameraSample) -> Void,
        onDepth: ((CalibrationDepthSample) -> Void)? = nil
    ) {
        stateLock.lock()
        isCalibrationStreamActive = true
        recomputeRatesAndModesLocked()
        let targetGestureMode = effectiveGestureModeLocked()
        stateLock.unlock()

        depthQueue.async { [weak self] in
            // Allow the first calibration depth sample immediately without waiting out a prior 1 Hz idle interval.
            self?.lastDepthSampleTime = -Double.infinity
        }
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.onCalibrationSample = handler
            self.onCalibrationDepthSample = onDepth
            self.calibrationActive = true
            if self.recognizer.mode != targetGestureMode {
                self.recognizer.mode = targetGestureMode
            } else {
                self.recognizer.resetPreservingHoldLatch()
            }
            if self.lastPublishedHoldProgress != 0 {
                self.lastPublishedHoldProgress = 0
                DispatchQueue.main.async { self.gestureHoldProgress = 0 }
            }
        }
        videoQueue.async { [weak self] in
            self?.applyDepthConnectionStateOnVideoQueue()
        }
    }

    /// Ends calibration callbacks, restores non-calibration `GestureMode` (preserving lower-hands hold latch),
    /// and drops LiDAR depth from `8 Hz` back to `1 Hz` (or `0 Hz` if entering `.countIn` / `.recording`).
    func stopCalibration() {
        stateLock.lock()
        isCalibrationStreamActive = false
        if explicitCoachingPhase == .calibrating {
            explicitCoachingPhase = nil
        }
        if manualGestureMode == .calibrating {
            manualGestureMode = nil
        }
        recomputeRatesAndModesLocked()
        let targetGestureMode = effectiveGestureModeLocked()
        stateLock.unlock()

        analysisQueue.async { [weak self] in
            guard let self else { return }
            let wasActive = self.calibrationActive
            self.calibrationActive = false
            self.onCalibrationSample = nil
            self.onCalibrationDepthSample = nil
            if wasActive {
                if self.recognizer.mode != targetGestureMode {
                    self.recognizer.mode = targetGestureMode
                } else {
                    self.recognizer.resetPreservingHoldLatch()
                }
            }
        }
        videoQueue.async { [weak self] in
            self?.applyDepthConnectionStateOnVideoQueue()
        }
    }

    // MARK: - Recording

    func startRecording(to url: URL) {
        stateLock.lock()
        isTakeRecordingActive = true
        recomputeRatesAndModesLocked()
        let targetGestureMode = effectiveGestureModeLocked()
        stateLock.unlock()

        syncGestureModeOnAnalysisQueue(targetGestureMode, forceResetLatch: false)
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.applyDepthConnectionStateOnVideoQueue()
            self.recorder?.cancel()
            self.recorder = TakeRecorder(url: url)
        }
    }

    func finishRecording() async -> TakeRecorder.Output? {
        stateLock.lock()
        isTakeRecordingActive = false
        if explicitCoachingPhase == nil || explicitCoachingPhase == .recording || explicitCoachingPhase == .countIn {
            // Keep LiDAR at 0 Hz and gestures suppressed during post-take `.analyzing` until next phase change.
            explicitCoachingPhase = .analyzing
        }
        recomputeRatesAndModesLocked()
        let targetGestureMode = effectiveGestureModeLocked()
        stateLock.unlock()

        syncGestureModeOnAnalysisQueue(targetGestureMode, forceResetLatch: true)
        return await withCheckedContinuation { continuation in
            videoQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                self.applyDepthConnectionStateOnVideoQueue()
                guard let recorder = self.recorder else {
                    continuation.resume(returning: nil)
                    return
                }
                self.recorder = nil
                recorder.finish { continuation.resume(returning: $0) }
            }
        }
    }

    func cancelRecording() {
        stateLock.lock()
        isTakeRecordingActive = false
        if explicitCoachingPhase == .recording || explicitCoachingPhase == .countIn {
            explicitCoachingPhase = .idle
        }
        recomputeRatesAndModesLocked()
        let targetGestureMode = effectiveGestureModeLocked()
        stateLock.unlock()

        syncGestureModeOnAnalysisQueue(targetGestureMode, forceResetLatch: true)
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.recorder?.cancel()
            self.recorder = nil
            self.applyDepthConnectionStateOnVideoQueue()
        }
    }

    // MARK: - Capture Session Configuration (videoQueue)

    private func configureSession(requestedMode: CameraMode) {
        // Unlock AE/AWB on any previously bound camera device before reconfiguring.
        CalibrationSensors.unlockDeviceExposureAndWhiteBalance(captureDevice)

        session.beginConfiguration()
        for existingInput in session.inputs {
            session.removeInput(existingInput)
        }
        for existingOutput in session.outputs {
            session.removeOutput(existingOutput)
        }

        session.sessionPreset = .hd1280x720

        let selection = Self.selectCaptureDevice(for: requestedMode)
        guard let device = selection.device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            configured = false
            configuredMode = nil
            let label = requestedMode.isRear ? "Rear camera unavailable." : "Front camera unavailable."
            publishError(label)
            DebugLog.error("camera input unavailable for mode=\(requestedMode.rawValue)")
            return
        }
        session.addInput(input)
        captureDevice = device

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            configured = false
            configuredMode = nil
            publishError("Camera output unavailable.")
            DebugLog.error("camera video output unavailable")
            return
        }
        session.addOutput(output)

        var resolvedMode = selection.resolvedMode
        var depthAdded = false
        if resolvedMode == .rearLiDAR {
            depthOutput.isFilteringEnabled = true
            depthOutput.alwaysDiscardsLateDepthData = true
            depthOutput.setDelegate(self, callbackQueue: depthQueue)
            if session.canAddOutput(depthOutput), Self.ensureDepthCapableFormat(on: device) {
                session.addOutput(depthOutput)
                depthAdded = true
            } else {
                // Graceful fallback to `.rearWide` if depth output or LiDAR depth format is unavailable (§1.2).
                resolvedMode = .rearWide
                DebugLog.warn("rearLiDAR depth output unavailable; degrading to rearWide")
            }
        }

        // Enforce 30 fps cap (and float32 depth format when LiDAR active) AFTER preset/format/outputs are bound.
        Self.configureFrameRateAndDepthFormat(on: device, enableDepth: depthAdded)

        if let videoConnection = output.connection(with: .video) {
            if videoConnection.isVideoRotationAngleSupported(90) {
                // Portrait, upright buffers: live MediaPipe runs with `.up` and recorded takes need no transform.
                videoConnection.videoRotationAngle = 90
            }
            if videoConnection.isVideoMirroringSupported {
                // Explicitly un-mirrored raw buffer across BOTH rear and front modes (§1.2, §11.1 item 4).
                videoConnection.automaticallyAdjustsVideoMirroring = false
                videoConnection.isVideoMirrored = false
            }
            if videoConnection.isCameraIntrinsicMatrixDeliverySupported {
                videoConnection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
        }

        if depthAdded, let depthConnection = depthOutput.connection(with: .depthData) {
            if depthConnection.isVideoRotationAngleSupported(90) {
                depthConnection.videoRotationAngle = 90
            }
            if depthConnection.isVideoMirroringSupported {
                depthConnection.automaticallyAdjustsVideoMirroring = false
                depthConnection.isVideoMirrored = false
            }
        }

        session.commitConfiguration()

        let vFoV = CalibrationSensors.resolvedVerticalFoVDeg(for: device)
        let hFoV = CalibrationSensors.portraitHorizontalFoVDeg(fromVerticalFoVDeg: vFoV)
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let portraitW = dims.width > 0 && dims.height > 0 ? Int(min(dims.width, dims.height)) : 720
        let portraitH = dims.width > 0 && dims.height > 0 ? Int(max(dims.width, dims.height)) : 1280
        let intrinsicsSupported = output.connection(with: .video)?.isCameraIntrinsicMatrixDeliveryEnabled ?? false

        stateLock.lock()
        _activeCameraMode = resolvedMode
        _portraitVideoWidth = portraitW
        _portraitVideoHeight = portraitH
        _verticalFoVDeg = vFoV
        _horizontalFoVDeg = hFoV
        _latestVideoIntrinsics = nil
        if resolvedMode != .rearLiDAR {
            _latestDepthSample = nil
        }
        recomputeRatesAndModesLocked()
        stateLock.unlock()

        configured = true
        configuredMode = resolvedMode
        loggedVideoIntrinsicsOnce = false
        applyDepthConnectionStateOnVideoQueue()

        DebugLog.info(
            "practice_camera configured mode=\(resolvedMode.rawValue) (requested=\(requestedMode.rawValue)) "
            + "device=\(device.localizedName) format=\(dims.width)x\(dims.height) "
            + "vFoV=\(String(format: "%.1f", vFoV))deg hFoV=\(String(format: "%.1f", hFoV))deg "
            + "depth=\(depthAdded) videoIntrinsics=\(intrinsicsSupported)"
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cameraError = nil
            self.cameraMode = resolvedMode
            self.verticalFoVDeg = vFoV
            self.horizontalFoVDeg = hFoV
        }
    }

    private static func selectCaptureDevice(for requestedMode: CameraMode) -> (device: AVCaptureDevice?, resolvedMode: CameraMode) {
        switch requestedMode {
        case .rearLiDAR:
            if let lidarDevice = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) {
                return (lidarDevice, .rearLiDAR)
            }
            if let wideBack = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                return (wideBack, .rearWide)
            }
            return (nil, .rearWide)

        case .rearWide:
            return (AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), .rearWide)

        case .frontSelfView:
            return (AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front), .frontSelfView)
        }
    }

    private static func resolveAvailableHardwareMode(for requestedMode: CameraMode) -> CameraMode {
        switch requestedMode {
        case .rearLiDAR:
            if AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil {
                return .rearLiDAR
            }
            return .rearWide
        case .rearWide:
            return .rearWide
        case .frontSelfView:
            return .frontSelfView
        }
    }

    /// Ensures `device.activeFormat` supports depth delivery when `.rearLiDAR` is active, preferring `1280x720`
    /// (`16:9`) first and otherwise selecting the smallest `16:9` depth-capable format supporting 30 fps.
    private static func ensureDepthCapableFormat(on device: AVCaptureDevice) -> Bool {
        if !device.activeFormat.supportedDepthDataFormats.isEmpty {
            return true
        }
        let candidates = device.formats.filter { format in
            guard !format.supportedDepthDataFormats.isEmpty else { return false }
            let supports30 = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= targetMaxFps + 0.05 && $0.maxFrameRate >= targetMaxFps - 0.05
            }
            return supports30
        }
        guard !candidates.isEmpty else { return false }

        let chosen = candidates.min { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let a16x9 = (Int(da.width) * 9 == Int(da.height) * 16)
            let b16x9 = (Int(db.width) * 9 == Int(db.height) * 16)
            if a16x9 != b16x9 { return a16x9 }
            let aExact720 = (da.width == 1280 && da.height == 720)
            let bExact720 = (db.width == 1280 && db.height == 720)
            if aExact720 != bExact720 { return aExact720 }
            return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
        }
        guard let targetFormat = chosen else { return false }

        do {
            try device.lockForConfiguration()
            device.activeFormat = targetFormat
            device.unlockForConfiguration()
            return !device.activeFormat.supportedDepthDataFormats.isEmpty
        } catch {
            DebugLog.warn("failed selecting depth-capable format: \(error.localizedDescription)")
            return false
        }
    }

    /// Caps video capture at 30 fps (`1/30 s` min frame duration) and selects `DepthFloat32` when depth is active.
    private static func configureFrameRateAndDepthFormat(on device: AVCaptureDevice, enableDepth: Bool) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if enableDepth {
                let depthFormats = device.activeFormat.supportedDepthDataFormats
                let preferredDepth = depthFormats.first {
                    CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
                } ?? depthFormats.first {
                    CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat16
                } ?? depthFormats.first
                if let preferredDepth {
                    device.activeDepthDataFormat = preferredDepth
                }
            }

            let desiredMinDuration = CMTime(value: 1, timescale: Int32(targetMaxFps))
            let ranges = device.activeFormat.videoSupportedFrameRateRanges
            if let range = ranges.first(where: {
                $0.minFrameRate <= targetMaxFps + 0.05 && $0.maxFrameRate >= targetMaxFps - 0.05
            }) ?? ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                let minDur = CMTimeMaximum(
                    range.minFrameDuration,
                    CMTimeMinimum(range.maxFrameDuration, desiredMinDuration)
                )
                device.activeVideoMinFrameDuration = minDur
                if CMTimeCompare(device.activeVideoMaxFrameDuration, minDur) < 0 {
                    device.activeVideoMaxFrameDuration = range.maxFrameDuration
                }
            }
        } catch {
            DebugLog.warn("camera 30fps/depth configuration failed: \(error.localizedDescription)")
        }
    }

    private func applyDepthConnectionStateOnVideoQueue() {
        stateLock.lock()
        let shouldEnable = (_activeCameraMode == .rearLiDAR) && (_depthTargetHz > 0.0)
        stateLock.unlock()

        if let depthConn = depthOutput.connection(with: .depthData), depthConn.isEnabled != shouldEnable {
            depthConn.isEnabled = shouldEnable
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { self.cameraError = message }
    }

    /// Camera presentation time on the host clock (the clock `Metronome` schedules clicks on).
    private func hostSeconds(_ pts: CMTime) -> Double {
        let hostClock = CMClockGetHostTimeClock()
        let captureClock = session.synchronizationClock ?? hostClock
        return CMSyncConvertTime(pts, from: captureClock, to: hostClock).seconds
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let time = hostSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        recorder?.append(sampleBuffer, hostSeconds: time)
        // Debug Link screen sharing: the latest camera frame for the preview composite (throttled inside).
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            CameraFrameStore.shared.offer(pb)
        }
        guard !analysisBusy else { return }
        analysisBusy = true
        analysisQueue.async { [weak self] in
            self?.analyze(sampleBuffer, time: time)
            self?.videoQueue.async { self?.analysisBusy = false }
        }
    }

    // MARK: - AVCaptureDepthDataOutputDelegate (depthQueue)

    func depthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        didOutput depthData: AVDepthData,
        timestamp: CMTime,
        connection: AVCaptureConnection
    ) {
        stateLock.lock()
        let mode = _activeCameraMode
        let targetHz = _depthTargetHz
        let vFoV = _verticalFoVDeg
        let portraitW = _portraitVideoWidth
        let portraitH = _portraitVideoHeight
        let gravity = _cachedDeviceGravity
        let gravityProvider = _deviceGravityProvider
        stateLock.unlock()

        guard mode == .rearLiDAR, targetHz > 0.0 else { return }

        let time = hostSeconds(timestamp)
        let minInterval = 1.0 / targetHz
        guard time - lastDepthSampleTime >= minInterval - 1e-4 else { return }
        lastDepthSampleTime = time

        if !loggedDepthFormatOnce {
            loggedDepthFormatOnce = true
            let dm = depthData.depthDataMap
            DebugLog.info(
                "lidar_depth first sample rawSize=\(CVPixelBufferGetWidth(dm))x\(CVPixelBufferGetHeight(dm)) "
                + "hasCalData=\(depthData.cameraCalibrationData != nil) targetHz=\(String(format: "%.1f", targetHz))"
            )
        }

        let liveGravity = gravityProvider?() ?? gravity
        let landmarks = (provider as? MediaPipePoseProvider)?.latestCalibrationLandmarks ?? []
        guard let sample = CalibrationSensors.depthSample(
            from: depthData,
            timestamp: time,
            landmarks: landmarks,
            deviceGravity: liveGravity,
            cameraMode: mode,
            verticalFoVDeg: vFoV,
            targetVideoWidth: portraitW,
            targetVideoHeight: portraitH
        ) else {
            return
        }

        stateLock.lock()
        _latestDepthSample = sample
        stateLock.unlock()

        analysisQueue.async { [weak self] in
            guard let self else { return }
            let calDepthHandler = self.calibrationActive ? self.onCalibrationDepthSample : nil
            DispatchQueue.main.async { [weak self] in
                calDepthHandler?(sample)
                self?.onDepthSample?(sample)
            }
        }
    }

    // MARK: - Live Pose, Intrinsics, Gestures & FPS Telemetry (analysisQueue)

    private func analyze(_ sampleBuffer: CMSampleBuffer, time: Double) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = max(1, CVPixelBufferGetHeight(pixelBuffer))
        let aspect = Double(width) / Double(height)

        stateLock.lock()
        let currentMode = _activeCameraMode
        let currentVFoV = _verticalFoVDeg
        let currentHFoV = _horizontalFoVDeg
        let currentDepth = _latestDepthSample
        stateLock.unlock()

        // Extract per-frame video intrinsics when delivered (`frontSelfView` / `rearWide` fallback + Gate 1 check).
        let frameVideoIntrinsics = CalibrationSensors.videoIntrinsics(
            from: sampleBuffer,
            fallbackVerticalFoVDeg: currentVFoV
        )
        if let frameVideoIntrinsics {
            stateLock.lock()
            _latestVideoIntrinsics = frameVideoIntrinsics
            stateLock.unlock()
            if !loggedVideoIntrinsicsOnce {
                loggedVideoIntrinsicsOnce = true
                DebugLog.info(
                    "video_intrinsics delivered mode=\(currentMode.rawValue) "
                    + "size=\(frameVideoIntrinsics.width)x\(frameVideoIntrinsics.height) "
                    + "fx=\(String(format: "%.1f", frameVideoIntrinsics.fx)) "
                    + "fy=\(String(format: "%.1f", frameVideoIntrinsics.fy)) "
                    + "cx=\(String(format: "%.1f", frameVideoIntrinsics.cx)) "
                    + "cy=\(String(format: "%.1f", frameVideoIntrinsics.cy))"
                )
            }
        }

        let liveFrame = provider.live(sampleBuffer, hostTime: time)

        // Rolling 5 s live pose FPS & Debug Link `perf_sample` reporting (§9.2).
        recordLiveFrameTimestampAndReportIfDue(at: time, cameraMode: currentMode)

        let mpProvider = provider as? MediaPipePoseProvider
        let calibrationPoints = mpProvider?.latestCalibrationLandmarks ?? []

        if calibrationActive, let handler = onCalibrationSample {
            // RAW (un-mirrored) coordinates: `CalibrationGate` phrases left/right for the mirrored preview itself.
            handler(
                CalibrationCameraSample(
                    time: time,
                    landmarks: calibrationPoints,
                    frame: calibrationPoints.isEmpty ? nil : liveFrame,
                    pixelBuffer: pixelBuffer,
                    cameraMode: currentMode,
                    verticalFoVDeg: currentVFoV,
                    horizontalFoVDeg: currentHFoV,
                    videoIntrinsics: frameVideoIntrinsics,
                    latestDepthSample: currentDepth
                )
            )
        }

        // Build `GestureSample` via `fromMediaPipeNormalized` (`1.0 - mpY` fix; §5.1) + `bodyMotion` (§5.2).
        let gestureSample = makeGestureSample(
            at: time,
            liveFrame: liveFrame,
            mpProvider: mpProvider,
            calibrationPoints: calibrationPoints
        )
        let firedEvent = recognizer.processEvent(gestureSample)
        let currentHoldProgress = recognizer.holdProgress

        if let firedEvent {
            let legacyCommand = firedEvent.legacyCommand
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onGestureEventAtTime?(firedEvent, time)
                self.onGestureEvent?(firedEvent)
                if let legacyCommand {
                    self.onGesture?(legacyCommand)
                }
            }
        }

        // Immediately clear hold ring when `holdProgress` resets to 0 after being active.
        if currentHoldProgress == 0 && lastPublishedHoldProgress != 0 {
            lastPublishedHoldProgress = 0
            DispatchQueue.main.async { [weak self] in
                self?.gestureHoldProgress = 0
            }
        }

        guard let frame = liveFrame else { return }
        let normLandmarks = mpProvider != nil
            ? (calibrationPoints.isEmpty ? [:] : (mpProvider?.latestNormalizedLandmarks ?? [:]))
            : [:]

        guard time - lastPublish >= 0.066 else { return }
        lastPublish = time
        lastPublishedHoldProgress = currentHoldProgress

        var joints: [String: CGPoint] = [:]
        for (name, p) in normLandmarks {
            if let conf = frame.confidences?[name], conf >= Double(Self.minLiveJointConfidence) {
                joints[name] = CGPoint(x: displayX(p.x), y: p.y)
            }
        }
        let skeleton = LiveSkeleton(joints: joints, imageAspect: aspect)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.skeleton = skeleton
            self.handShapes = [:]
            if self.gestureHoldProgress != currentHoldProgress {
                self.gestureHoldProgress = currentHoldProgress
            }
        }
    }

    private func makeGestureSample(
        at time: Double,
        liveFrame: GrooveScoringEngine.RawPoseFrame?,
        mpProvider: MediaPipePoseProvider?,
        calibrationPoints: [CalibrationLandmark]
    ) -> GestureSample {
        if mpProvider != nil {
            guard calibrationPoints.count == CanonicalSkeleton.poseLandmarkCount else {
                previousGestureLandmarks = nil
                return GestureSample(time: time)
            }
            let bodyMotion = GestureSample.mediaPipeBodyMotion(
                previous: previousGestureLandmarks,
                current: calibrationPoints
            )
            previousGestureLandmarks = calibrationPoints
            return GestureSample.fromMediaPipeNormalized(
                time: time,
                landmarks: calibrationPoints,
                minConfidence: Double(Self.minLiveJointConfidence),
                mirrorX: mirrorForDisplay,
                bodyMotion: bodyMotion
            )
        }

        guard let frame = liveFrame else {
            return GestureSample(time: time)
        }
        let normLandmarks = (provider as? MediaPipePoseProvider)?.latestNormalizedLandmarks ?? [:]
        func rawWrist(_ side: String) -> GesturePoint? {
            let key = side + "Wrist"
            guard let p = normLandmarks[key],
                  let conf = frame.confidences?[key],
                  conf >= Double(Self.minLiveJointConfidence) else {
                return nil
            }
            return GesturePoint(x: Double(p.x), y: Double(p.y), confidence: conf)
        }
        let headY = normLandmarks["nose"].map { Double($0.y) }
        return GestureSample.fromMediaPipeNormalized(
            time: time,
            leftWrist: rawWrist("left"),
            rightWrist: rawWrist("right"),
            headY: headY,
            mirrorX: mirrorForDisplay,
            bodyMotion: nil
        )
    }

    private func recordLiveFrameTimestampAndReportIfDue(at time: Double, cameraMode: CameraMode) {
        analysisTimestamps.append(time)
        let windowCutoff = time - Self.perfReportIntervalS
        if analysisTimestamps.count > 1 {
            analysisTimestamps.removeAll { $0 < windowCutoff }
        }
        guard analysisTimestamps.count >= 2, let oldest = analysisTimestamps.first else { return }
        let span = time - oldest
        guard span >= 0.25 else { return }

        let fps = Double(analysisTimestamps.count - 1) / span
        guard fps.isFinite else { return }

        if time - lastPerfReportTime >= Self.perfReportIntervalS {
            lastPerfReportTime = time
            let modeRaw = cameraMode.rawValue
            Task { @MainActor [weak self] in
                self?.liveFps = fps
                DebugLink.shared.recordPerfSample(liveFps: fps, extra: ["cameraMode": modeRaw])
            }
        }
    }

    private func displayX(_ x: CGFloat) -> CGFloat {
        mirrorForDisplay ? 1.0 - x : x
    }

    // MARK: - Internal State & External-Display Auto Mode Helpers

    private func resolveRequestedCameraModeLocked() -> CameraMode {
        if let preferredCameraMode {
            return preferredCameraMode
        }
        return autoExternalDisplayConnected ? .rearLiDAR : .frontSelfView
    }

    private func recomputeRatesAndModesLocked() {
        guard _activeCameraMode == .rearLiDAR else {
            _depthTargetHz = Self.disabledDepthHz
            return
        }
        if isTakeRecordingActive {
            _depthTargetHz = Self.disabledDepthHz
            return
        }
        if let phase = explicitCoachingPhase {
            switch phase {
            case .calibrating:
                _depthTargetHz = Self.calibratingDepthHz
            case .idle, .results, .paused:
                _depthTargetHz = isCalibrationStreamActive ? Self.calibratingDepthHz : Self.idleDepthHz
            case .countIn, .recording, .analyzing, .clapSync:
                _depthTargetHz = Self.disabledDepthHz
            }
            return
        }
        if let manualMode = manualGestureMode {
            switch manualMode {
            case .calibrating:
                _depthTargetHz = Self.calibratingDepthHz
            case .betweenTakes:
                _depthTargetHz = isCalibrationStreamActive ? Self.calibratingDepthHz : Self.idleDepthHz
            case .countIn, .recording, .disabled:
                _depthTargetHz = Self.disabledDepthHz
            }
            return
        }
        _depthTargetHz = isCalibrationStreamActive ? Self.calibratingDepthHz : Self.idleDepthHz
    }

    private func effectiveGestureModeLocked() -> GestureMode {
        if let phase = explicitCoachingPhase {
            if isCalibrationStreamActive && phase == .idle {
                return .calibrating
            }
            return phase.gestureMode
        }
        if isCalibrationStreamActive {
            return .calibrating
        }
        if isTakeRecordingActive {
            return .recording
        }
        return manualGestureMode ?? .betweenTakes
    }

    private func syncGestureModeOnAnalysisQueue(_ targetMode: GestureMode, forceResetLatch: Bool) {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            if self.recognizer.mode != targetMode {
                // `recognizer.mode.didSet` automatically invokes `resetPreservingHoldLatch()`.
                self.recognizer.mode = targetMode
            } else if forceResetLatch {
                self.recognizer.resetPreservingHoldLatch()
            }
            if self.recognizer.holdProgress == 0 && self.lastPublishedHoldProgress != 0 {
                self.lastPublishedHoldProgress = 0
                DispatchQueue.main.async { self.gestureHoldProgress = 0 }
            }
        }
    }

    private func reconfigureForDesiredModeIfNeeded(_ desiredMode: CameraMode) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            guard self.configured else {
                let resolved = Self.resolveAvailableHardwareMode(for: desiredMode)
                self.stateLock.lock()
                self._activeCameraMode = resolved
                self.recomputeRatesAndModesLocked()
                self.stateLock.unlock()
                DispatchQueue.main.async { [weak self] in
                    self?.cameraMode = resolved
                }
                return
            }
            let resolvedHardwareMode = Self.resolveAvailableHardwareMode(for: desiredMode)
            guard self.configuredMode != resolvedHardwareMode else {
                self.applyDepthConnectionStateOnVideoQueue()
                return
            }
            self.configureSession(requestedMode: desiredMode)
            self.analysisQueue.async { [weak self] in
                guard let self else { return }
                self.previousGestureLandmarks = nil
                self.analysisTimestamps.removeAll()
                self.lastPerfReportTime = -Double.infinity
                self.recognizer.resetPreservingHoldLatch()
            }
            self.depthQueue.async { [weak self] in
                self?.lastDepthSampleTime = -Double.infinity
            }
        }
    }

    private static func readExternalDisplayConnectedIfOnMain() -> Bool? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            ExternalDisplayManager.shared.isConnected
        }
    }

    private func installExternalDisplayObservers() {
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            UIScene.willConnectNotification,
            UIScene.didDisconnectNotification
        ]
        for name in names {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    ExternalDisplayManager.shared.reconcileConnectedScenes()
                    let extConnected = ExternalDisplayManager.shared.isConnected
                    self.handleAutoExternalDisplayChange(isConnected: extConnected)
                }
            }
            sceneObservers.append(token)
        }
    }

    private func handleAutoExternalDisplayChange(isConnected: Bool) {
        stateLock.lock()
        autoExternalDisplayConnected = isConnected
        let isAuto = (preferredCameraMode == nil)
        let desiredMode = resolveRequestedCameraModeLocked()
        stateLock.unlock()

        guard isAuto else { return }
        videoQueue.async { [weak self] in
            guard let self, self.configured, self.session.isRunning else { return }
            let resolved = Self.resolveAvailableHardwareMode(for: desiredMode)
            if self.configuredMode != resolved {
                self.configureSession(requestedMode: desiredMode)
            }
        }
    }
}

/// Writes camera sample buffers of one take to a .mov (called on the camera queue only).
final class TakeRecorder {
    struct Output {
        let url: URL
        /// Host-clock time of the first frame in the file.
        let firstFrameHostSeconds: Double
    }

    private let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstFrameHostSeconds: Double?
    private var failed = false

    init(url: URL) {
        self.url = url
        try? FileManager.default.removeItem(at: url)
    }

    func append(_ sampleBuffer: CMSampleBuffer, hostSeconds: Double) {
        guard !failed else { return }
        if writer == nil {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            do {
                let newWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
                let settings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: CVPixelBufferGetWidth(pixelBuffer),
                    AVVideoHeightKey: CVPixelBufferGetHeight(pixelBuffer)
                ]
                let newInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                newInput.expectsMediaDataInRealTime = true
                guard newWriter.canAdd(newInput) else {
                    failed = true
                    return
                }
                newWriter.add(newInput)
                guard newWriter.startWriting() else {
                    failed = true
                    return
                }
                newWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                writer = newWriter
                input = newInput
            } catch {
                failed = true
                return
            }
        }
        guard let input, input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer), firstFrameHostSeconds == nil {
            firstFrameHostSeconds = hostSeconds
        }
    }

    func finish(_ completion: @escaping (Output?) -> Void) {
        guard let writer, let input, let first = firstFrameHostSeconds, !failed else {
            cancel()
            completion(nil)
            return
        }
        let url = self.url
        input.markAsFinished()
        writer.finishWriting {
            completion(writer.status == .completed ? Output(url: url, firstFrameHostSeconds: first) : nil)
        }
    }

    func cancel() {
        if let writer, writer.status == .writing {
            writer.cancelWriting()
        }
    }
}
