import AVFoundation
import CoreGraphics
import GrooveCore

/// Live 2D joints for the camera overlay: normalised 0...1 with y down, mirrored like the selfie preview.
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
}

/// Front-camera capture for practice takes:
/// - records takes to a movie file (scored afterwards with MediaPipe VIDEO mode via PoseProvider);
/// - runs lightweight live MediaPipe PoseLandmarker (LIVE_STREAM mode) to drive the skeleton overlay
///   and hands-free `GestureRecognizer`.
/// Thread confinement: capture + recording state lives on `videoQueue`, gesture state on `analysisQueue`, published
/// properties are only written on the main queue.
final class PracticeCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()

    @Published private(set) var skeleton = LiveSkeleton(joints: [:], imageAspect: 9.0 / 16.0)
    /// Live hand-shape label per dancer hand ("left" / "right").
    @Published private(set) var handShapes: [String: String] = [:]
    @Published private(set) var cameraError: String?

    /// Delivered on the main queue when a gesture completes.
    var onGesture: ((GestureCommand) -> Void)?

    /// The front camera, for exposure reads (`iso`, `activeFormat.maxISO`, `exposureDuration`). Set once when the
    /// session is configured, before any frame is analysed.
    private(set) var captureDevice: AVCaptureDevice?

    private static let minLiveJointConfidence: Float = 0.3

    private let provider: PoseProvider
    private let output = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "groove.practice.video")
    private let analysisQueue = DispatchQueue(label: "groove.practice.analysis")

    // videoQueue state
    private var configured = false
    private var recorder: TakeRecorder?
    private var analysisBusy = false

    // analysisQueue state
    private var recognizer = GestureRecognizer()
    private var lastPublish = 0.0
    /// While set, gesture recognition is skipped (a T-pose raise looks like a swipe) and every analysed frame goes to
    /// `onCalibrationSample`. Both are only touched on `analysisQueue`: use `startCalibration` / `stopCalibration`.
    private var calibrationActive = false
    private var onCalibrationSample: ((CalibrationCameraSample) -> Void)?

    /// Selfie preview is mirrored, so gesture directions and the overlay are mirrored to match what the dancer sees.
    private let mirrorForDisplay = true

    init(provider: PoseProvider = MediaPipePoseProvider.shared) {
        self.provider = provider
        super.init()
    }

    func start() {
        videoQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configureSession() }
            if self.configured && !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        stopCalibration()
        videoQueue.async { [weak self] in
            self?.recorder?.cancel()
            self?.recorder = nil
            self?.session.stopRunning()
        }
    }

    // MARK: - Calibration

    /// Routes live frames to `handler` (called on the analysis queue) and pauses gesture recognition.
    func startCalibration(_ handler: @escaping (CalibrationCameraSample) -> Void) {
        analysisQueue.async { [weak self] in
            self?.onCalibrationSample = handler
            self?.calibrationActive = true
        }
    }

    /// Back to normal: gestures on, no calibration callback. Safe to call on every exit path, any number of times.
    func stopCalibration() {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            let wasActive = self.calibrationActive
            self.calibrationActive = false
            self.onCalibrationSample = nil
            // Drop any half-finished gesture seen before calibration started.
            if wasActive { self.recognizer = GestureRecognizer() }
        }
    }

    // MARK: - Recording

    func startRecording(to url: URL) {
        videoQueue.async { [weak self] in
            self?.recorder?.cancel()
            self?.recorder = TakeRecorder(url: url)
        }
    }

    func finishRecording() async -> TakeRecorder.Output? {
        await withCheckedContinuation { continuation in
            videoQueue.async { [weak self] in
                guard let self, let recorder = self.recorder else {
                    continuation.resume(returning: nil)
                    return
                }
                self.recorder = nil
                recorder.finish { continuation.resume(returning: $0) }
            }
        }
    }

    func cancelRecording() {
        videoQueue.async { [weak self] in
            self?.recorder?.cancel()
            self?.recorder = nil
        }
    }

    // MARK: - Capture

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            publishError("Front camera unavailable.")
            DebugLog.error("front camera unavailable")
            return
        }
        session.addInput(input)
        captureDevice = device
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            publishError("Camera output unavailable.")
            DebugLog.error("camera output unavailable")
            return
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            // Portrait, upright buffers: live MediaPipe runs with `.up` and recorded takes need no transform.
            connection.videoRotationAngle = 90
        }
        session.commitConfiguration()
        configured = true
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

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = hostSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        recorder?.append(sampleBuffer, hostSeconds: time)
        // Debug Link screen sharing: the latest camera frame for the preview composite (throttled inside).
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) { CameraFrameStore.shared.offer(pb) }
        guard !analysisBusy else { return }
        analysisBusy = true
        analysisQueue.async { [weak self] in
            self?.analyze(sampleBuffer, time: time)
            self?.videoQueue.async { self?.analysisBusy = false }
        }
    }

    // MARK: - Live analysis

    private func analyze(_ sampleBuffer: CMSampleBuffer, time: Double) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let aspect = Double(CVPixelBufferGetWidth(pixelBuffer)) / Double(max(1, CVPixelBufferGetHeight(pixelBuffer)))

        let liveFrame = provider.live(sampleBuffer, hostTime: time)

        if calibrationActive, let handler = onCalibrationSample {
            // RAW (un-mirrored) coordinates: the gate phrases left/right for the mirrored preview itself.
            let points = (provider as? MediaPipePoseProvider)?.latestCalibrationLandmarks ?? []
            handler(CalibrationCameraSample(time: time, landmarks: points,
                                            frame: points.isEmpty ? nil : liveFrame, pixelBuffer: pixelBuffer))
        }

        guard let frame = liveFrame else { return }
        let normLandmarks = (provider as? MediaPipePoseProvider)?.latestNormalizedLandmarks ?? [:]

        // Gestures: body-pose wrists (stable at dance distance) from MediaPipe landmarks
        func wrist(_ side: String) -> GesturePoint? {
            guard let p = normLandmarks[side + "Wrist"],
                  let conf = frame.confidences?[side + "Wrist"],
                  conf >= Double(Self.minLiveJointConfidence) else {
                return nil
            }
            return GesturePoint(x: Double(displayX(p.x)), y: Double(p.y), confidence: conf)
        }
        let headY = normLandmarks["nose"].map { Double($0.y) }
        let sample = GestureSample(time: time, leftWrist: wrist("left"), rightWrist: wrist("right"), headY: headY)
        if !calibrationActive, let command = recognizer.process(sample) {
            DispatchQueue.main.async { self.onGesture?(command) }
        }

        guard time - lastPublish >= 0.066 else { return }
        lastPublish = time

        var joints: [String: CGPoint] = [:]
        for (name, p) in normLandmarks {
            if let conf = frame.confidences?[name], conf >= Double(Self.minLiveJointConfidence) {
                joints[name] = CGPoint(x: displayX(p.x), y: p.y)
            }
        }
        let skeleton = LiveSkeleton(joints: joints, imageAspect: aspect)
        DispatchQueue.main.async {
            self.skeleton = skeleton
            self.handShapes = [:]
        }
    }

    private func displayX(_ x: CGFloat) -> CGFloat {
        mirrorForDisplay ? 1.0 - x : x
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
