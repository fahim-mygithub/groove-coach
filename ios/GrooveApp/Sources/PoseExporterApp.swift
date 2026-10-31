import AVFoundation
import CoreMotion
import GrooveCore
import PhotosUI
import SwiftUI
import UIKit
import Vision

@main
struct GrooveCoachApp: App {
    @StateObject private var library = GrooveLibrary()
    @StateObject private var lessonStore = LessonStore.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                CourseListView()
                    .tabItem { Label("Courses", systemImage: "play.rectangle.on.rectangle") }
                PracticeView()
                    .tabItem { Label("Practice", systemImage: "figure.dance") }
                CalibrationOnboardingView()
                    .tabItem { Label("Calibrate", systemImage: "slider.horizontal.3") }
            }
            .environmentObject(library)
            .environmentObject(lessonStore)
        }
    }
}

/// Complete Calibration Bundle exported by the app and compatible with `groove_eval` / `check_parity.py`.
struct CalibrationBundle: Codable {
    let references: [String: GrooveScoringEngine.PoseClip]
    let golden_clips: [GrooveScoringEngine.PoseClip]
    let calibration_report: GrooveScoringEngine.CalibrationReport
}

enum CalibrationClipRole: String, CaseIterable, Identifiable {
    case reference = "Reference Clip"
    case cleanPass = "Clean / Good (Expect PASS)"
    case lateFail = "Deliberately Late (Expect FAIL)"
    case earlyFail = "Deliberately Early (Expect FAIL)"
    case stiffFail = "Stiff / Locked Knees (Expect FAIL)"
    case wrongMoveFail = "Wrong Move (Expect FAIL)"

    var id: String { rawValue }

    var expectedLabel: GrooveScoringEngine.ExpectedLabel {
        switch self {
        case .reference, .cleanPass:
            return .init(passed: true, reason: "none")
        case .lateFail:
            return .init(passed: false, reason: "timing_late")
        case .earlyFail:
            return .init(passed: false, reason: "timing_early")
        case .stiffFail:
            return .init(passed: false, reason: "stiff_groove")
        case .wrongMoveFail:
            return .init(passed: false, reason: "wrong_move")
        }
    }
}

/// In-App Personal Calibration & 20-Clip Pose Ingest Screen (M1a + M0b).
/// Ingests ~20 short 20-second clips directly on the iPhone, runs unified Vision 3D + Core ML foot
/// pose extraction, calibrates the user's personal baseline (`LearnerBaseline`), verifies 100%
/// pass/fail separation, and saves/exports the calibration bundle.
struct CalibrationOnboardingView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var clipId: String = "clip_01_bounce_clean"
    @State private var moveTag: String = "down_bounce"
    @State private var clipRole: CalibrationClipRole = .cleanPass
    @State private var bpm: Double = 110.0

    @EnvironmentObject private var library: GrooveLibrary
    private var references: [String: GrooveScoringEngine.PoseClip] { library.references }
    private var calibrationClips: [GrooveScoringEngine.PoseClip] { library.calibrationClips }
    @State private var calibrationReport: GrooveScoringEngine.CalibrationReport?
    @State private var exportedBundleURL: URL?

    @State private var statusText: String = "Step 1: Import reference clips (`down_bounce`, `house_jack`), then ingest your ~20 calibration clips."
    private let footTrackingAvailable = FootKeypointProviderFactory.isAvailable
    @State private var measuredFps: Double = 0.0

    private let motionManager = CMMotionManager()

    var body: some View {
        NavigationStack {
            Form {
                Section("1. Next 20-Second Clip to Ingest") {
                    TextField("Clip ID", text: $clipId)
                        .textInputAutocapitalization(.never)
                    Picker("Move Tag", selection: $moveTag) {
                        Text("down_bounce").tag("down_bounce")
                        Text("house_jack").tag("house_jack")
                        Text("step_touch").tag("step_touch")
                        Text("heel_toe").tag("heel_toe")
                    }
                    Picker("Clip Role / Label", selection: $clipRole) {
                        ForEach(CalibrationClipRole.allCases) { role in
                            Text(role.rawValue).tag(role)
                        }
                    }
                    HStack {
                        Text("BPM")
                        Spacer()
                        TextField("BPM", value: $bpm, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        Label("Pick 20s Video & Ingest Pose", systemImage: "video.badge.plus")
                    }
                    .onChange(of: selectedItem) { _, newItem in
                        guard let newItem else { return }
                        Task { await ingestPickedVideo(newItem) }
                    }
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label(
                        footTrackingAvailable ? "Foot tracking: MediaPipe Pose Landmarker" : "Foot tracking: unavailable in this build",
                        systemImage: footTrackingAvailable ? "shoeprints.fill" : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(footTrackingAvailable ? .green : .orange)
                    if measuredFps > 0 {
                        Text(String(format: "Last Vision 3D + Foot Speed: %.1f fps", measuredFps))
                            .font(.caption.monospacedDigit().bold())
                    }
                }

                Section("2. Ingested Calibration Dataset (\(calibrationClips.count)/20 clips, \(references.count) refs)") {
                    HStack {
                        Text("Loaded References:")
                        Spacer()
                        Text(references.keys.sorted().joined(separator: ", ").isEmpty ? "None" : references.keys.sorted().joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                    Button("Compute Personal Baseline & Verify Separation") {
                        runOnDeviceCalibration()
                    }
                    .disabled(references.isEmpty || calibrationClips.isEmpty)
                }

                if let report = calibrationReport {
                    Section("3. Personal Calibration Result") {
                        HStack {
                            Text("Separation Gate")
                            Spacer()
                            Text("\(report.matched_clips)/\(report.total_clips) (\(Int(report.separation_accuracy * 100))%)")
                                .bold()
                                .foregroundStyle(report.calibration_valid ? .green : .orange)
                        }
                        HStack {
                            Text("Calibrated Leg Scale")
                            Spacer()
                            Text(String(format: "%.3f m", report.learner_baseline.personal_leg_scale_m))
                                .monospacedDigit()
                        }
                        HStack {
                            Text("Timing Bias Offset")
                            Spacer()
                            Text(String(format: "%+.1f ms", report.learner_baseline.baseline_timing_bias_ms))
                                .monospacedDigit()
                        }
                        HStack {
                            Text("Baseline Knee Flex Ratio")
                            Spacer()
                            Text(String(format: "%.0f%%", report.learner_baseline.baseline_knee_flex_ratio * 100))
                                .monospacedDigit()
                        }
                        HStack {
                            Text("Natural Spine Lag")
                            Spacer()
                            Text(String(format: "%.0f ms", report.learner_baseline.baseline_spine_lag_ms))
                                .monospacedDigit()
                        }
                        HStack {
                            Text("Recommended Groove Gate")
                            Spacer()
                            Text(String(format: "%.1f", report.learner_baseline.recommended_groove_gate))
                                .monospacedDigit()
                        }

                        if let url = exportedBundleURL {
                            ShareLink(item: url) {
                                Label("Export Calibration Bundle JSON", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Groove Calibration")
            .onAppear {
                if motionManager.isDeviceMotionAvailable {
                    motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
                    motionManager.startDeviceMotionUpdates()
                }
            }
        }
    }

    private func currentGravityVector() -> [Double] {
        guard let g = motionManager.deviceMotion?.gravity else {
            return [0.0, -1.0, 0.0]
        }
        return [g.x, g.y, g.z]
    }

    @MainActor
    private func ingestPickedVideo(_ item: PhotosPickerItem) async {
        statusText = "Loading 20s video clip..."
        do {
            guard let movieData = try await item.loadTransferable(type: Data.self) else {
                statusText = "Failed to load video data."
                return
            }
            let tempVideoURL = FileManager.default.temporaryDirectory.appendingPathComponent("ingest_clip.mov")
            try movieData.write(to: tempVideoURL, options: .atomic)

            statusText = "Extracting Vision 3D + MediaPipe foot + hand poses..."
            let startWall = CFAbsoluteTimeGetCurrent()
            let frames = try await VideoPoseExtractor.extractFrames(from: tempVideoURL)
            let elapsed = max(0.001, CFAbsoluteTimeGetCurrent() - startWall)
            measuredFps = Double(frames.count) / elapsed

            let beatPeriod = 60.0 / bpm
            let duration = frames.last?.t ?? 4.5
            let numBeats = max(8, Int((duration - 0.5) / beatPeriod))
            let beatTimes = (0..<numBeats).map { 0.5 + Double($0) * beatPeriod }

            let clip = GrooveScoringEngine.PoseClip(
                clip_id: clipId,
                move_tag: moveTag,
                bpm: bpm,
                beat_times: beatTimes,
                gravity_vector: currentGravityVector(),
                mirrored: false,
                audio_latency_ms: 0.0,
                speed_pct: 100,
                expected: clipRole.expectedLabel,
                frames: frames
            )

            if clipRole == .reference {
                library.references[moveTag] = clip
                statusText = "Saved reference clip for `\(moveTag)` (\(frames.count) frames @ \(String(format: "%.1f", measuredFps)) fps)."
            } else {
                library.calibrationClips.append(clip)
                statusText = "Ingested `\(clipId)` (\(calibrationClips.count)/20 calibration clips)."
                clipId = String(format: "clip_%02d_%@", calibrationClips.count + 1, moveTag)
            }
        } catch {
            statusText = "Ingest error: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func runOnDeviceCalibration() {
        let cfg = library.config
        let report = GrooveScoringEngine.calibrateUserBaseline(
            clips: calibrationClips,
            references: references,
            config: cfg
        )
        calibrationReport = report

        let bundle = CalibrationBundle(
            references: references,
            golden_clips: calibrationClips,
            calibration_report: report
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(bundle) {
            let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("calibration_bundle.json")
            try? data.write(to: outURL, options: .atomic)
            exportedBundleURL = outURL
        }
        if let baselineData = try? encoder.encode(report.learner_baseline) {
            UserDefaults.standard.set(baselineData, forKey: "GrooveCoach.CalibratedLearnerBaseline")
        }
        statusText = report.calibration_valid
            ? "Calibration passed (\(report.matched_clips)/\(report.total_clips))! Baseline saved to LearnerProfile."
            : "Calibration separated \(report.matched_clips)/\(report.total_clips) clips. Check mismatched takes."
    }
}

enum VideoPoseExtractor {
    static let visionJointMap: [(String, VNHumanBodyPose3DObservation.JointName)] = [
        ("leftElbow", .leftElbow),
        ("leftWrist", .leftWrist),
        ("rightElbow", .rightElbow),
        ("rightWrist", .rightWrist),
        ("root", .root),
        ("spine", .spine),
        ("centerShoulder", .centerShoulder),
        ("leftHip", .leftHip),
        ("leftKnee", .leftKnee),
        ("leftAnkle", .leftAnkle),
        ("rightHip", .rightHip),
        ("rightKnee", .rightKnee),
        ("rightAnkle", .rightAnkle),
        ("leftShoulder", .leftShoulder),
        ("rightShoulder", .rightShoulder)
    ]

    /// Display orientation of a video track (portrait iPhone recordings are stored landscape plus a 90 deg transform).
    static func orientation(for transform: CGAffineTransform) -> (vision: CGImagePropertyOrientation, ui: UIImage.Orientation) {
        let degrees = Int((atan2(transform.b, transform.a) * 180.0 / .pi).rounded())
        switch degrees {
        case 90: return (.right, .right)
        case -90: return (.left, .left)
        case 180, -180: return (.down, .down)
        default: return (.up, .up)
        }
    }

    /// Unified Vision 3D body + MediaPipe feet + Vision hand landmarks per frame.
    /// With `rebaseToFirstSample`, `t` is measured from the first decoded frame (used to re-time practice takes).
    static func extractFrames(from videoURL: URL, rebaseToFirstSample: Bool = false) async throws -> [GrooveScoringEngine.RawPoseFrame] {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return []
        }
        let transform = try await track.load(.preferredTransform)
        let (visionOrientation, imageOrientation) = orientation(for: transform)
        let rotated = visionOrientation == .left || visionOrientation == .right

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(trackOutput)
        reader.startReading()

        let footProvider = FootKeypointProviderFactory.makeVideoProvider()
        var extracted: [GrooveScoringEngine.RawPoseFrame] = []
        var firstSampleTime: Double?
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let rawTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if firstSampleTime == nil { firstSampleTime = rawTimestamp }
            let timestamp = rebaseToFirstSample ? rawTimestamp - (firstSampleTime ?? rawTimestamp) : rawTimestamp
            let request3D = VNDetectHumanBodyPose3DRequest()
            let handRequest = HandPoseExtractor.makeRequest()
            let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: visionOrientation)
            try handler.perform([request3D, handRequest])

            guard let obs3D = request3D.results?.first else { continue }
            var jointsDict: [String: [Double]] = [:]
            var confDict: [String: Double] = [:]

            for (name, jointKey) in visionJointMap {
                if let point = try? obs3D.recognizedPoint(jointKey) {
                    // `position` is root-relative model space (meters); `localPosition` is parent-joint-relative.
                    let pos = point.position.columns.3
                    jointsDict[name] = [Double(pos.x), Double(pos.y), Double(pos.z)]
                    confDict[name] = 0.95
                }
            }

            // Foot keypoints: NEVER fake heel/toe positions from ankle offsets.
            // Only populate if a real FootKeypointProvider (MediaPipeTasksVision PoseLandmarker) returns them;
            // otherwise leave foot joints absent from `jointsDict` with explicit 0.0 confidence so scoring reports "unavailable".
            let visionAnkles = jointsDict.filter { $0.key == "leftAnkle" || $0.key == "rightAnkle" }
            if let realFeet = footProvider?.footKeypoints(
                from: sampleBuffer,
                orientation: imageOrientation,
                timestampSeconds: rawTimestamp,
                visionAnkles: visionAnkles
            ) {
                for (footName, coords) in realFeet.joints {
                    jointsDict[footName] = coords
                }
                for (footName, conf) in realFeet.confidences {
                    confDict[footName] = conf
                }
            } else {
                confDict["leftHeel"] = 0.0
                confDict["leftFootIndex"] = 0.0
                confDict["rightHeel"] = 0.0
                confDict["rightFootIndex"] = 0.0
            }

            // Hands in the 21-point MediaPipe order; nil when not seen, so hand styling is skipped (never zeroed).
            var imageAspect = 9.0 / 16.0
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let w = Double(CVPixelBufferGetWidth(pixelBuffer))
                let h = Double(CVPixelBufferGetHeight(pixelBuffer))
                imageAspect = rotated ? h / max(1.0, w) : w / max(1.0, h)
            }
            let hands = HandPoseExtractor.handsPayload(HandPoseExtractor.hands(from: handRequest, imageAspect: imageAspect))

            extracted.append(
                GrooveScoringEngine.RawPoseFrame(
                    t: timestamp,
                    joints: jointsDict,
                    confidences: confDict,
                    hands: hands
                )
            )
        }
        return extracted
    }
}

/// Monotonic host-time converter aligning `AVCaptureSession` camera `CMSampleBuffer` timestamps
/// and `AVAudioEngine` `AVAudioTime` timestamps onto the exact same `CMClockGetHostTimeClock()` timeline.
public enum HostTimeClock {
    /// Convert a camera `CMSampleBuffer` presentation timestamp into monotonic host-clock seconds.
    public static func cameraFrameHostTimeSeconds(_ sampleBuffer: CMSampleBuffer) -> Double {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostClock = CMClockGetHostTimeClock()
        let hostTime = CMSyncConvertTime(pts, from: hostClock, to: hostClock)
        return CMTimeGetSeconds(hostTime)
    }

    /// Convert an `AVAudioTime` render timestamp into monotonic host-clock seconds.
    public static func audioRenderHostTimeSeconds(_ audioTime: AVAudioTime) -> Double? {
        guard audioTime.isHostTimeValid else { return nil }
        return AVAudioTime.seconds(forHostTime: audioTime.hostTime)
    }
}

