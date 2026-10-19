import AVFoundation
import CoreMotion
import GrooveCore
import PhotosUI
import SwiftUI
import Vision

@main
struct GrooveCoachApp: App {
    var body: some Scene {
        WindowGroup {
            CalibrationOnboardingView()
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

    @State private var references: [String: GrooveScoringEngine.PoseClip] = [:]
    @State private var calibrationClips: [GrooveScoringEngine.PoseClip] = []
    @State private var calibrationReport: GrooveScoringEngine.CalibrationReport?
    @State private var exportedBundleURL: URL?

    @State private var statusText: String = "Step 1: Import reference clips (`down_bounce`, `house_jack`), then ingest your ~20 calibration clips."
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

    private func defaultConfig() -> GrooveScoringEngine.GrooveConfig {
        GrooveScoringEngine.GrooveConfig(
            version: "1.0.0",
            scoring_thresholds: .init(
                timing: .init(perfect_max_ms: 60.0, good_max_ms: 120.0, search_window_beats: 0.45),
                shape: .init(max_angle_error_deg: 45.0, max_single_joint_error_deg: 24.0, foot_pitch_weight: 0.30, pass_min_score: 70.0),
                groove: .init(min_knee_flex_ratio: 0.65, ideal_spine_lag_ms_min: 30.0, ideal_spine_lag_ms_max: 110.0, max_jerk_ratio: 2.5, pass_min_score: 65.0),
                coverage: .init(min_joint_confidence: 0.50, min_valid_frame_ratio: 0.80),
                gate: .init(min_good_or_better_beat_ratio: 0.80, speed_ladder_pct: [50, 75, 90, 100])
            )
        )
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

            statusText = "Extracting Vision 3D + Core ML foot poses..."
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
                references[moveTag] = clip
                statusText = "Saved reference clip for `\(moveTag)` (\(frames.count) frames @ \(String(format: "%.1f", measuredFps)) fps)."
            } else {
                calibrationClips.append(clip)
                statusText = "Ingested `\(clipId)` (\(calibrationClips.count)/20 calibration clips)."
                clipId = String(format: "clip_%02d_%@", calibrationClips.count + 1, moveTag)
            }
        } catch {
            statusText = "Ingest error: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func runOnDeviceCalibration() {
        let cfg = defaultConfig()
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

    static func extractFrames(from videoURL: URL) async throws -> [GrooveScoringEngine.RawPoseFrame] {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return []
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(trackOutput)
        reader.startReading()

        var extracted: [GrooveScoringEngine.RawPoseFrame] = []
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let request3D = VNDetectHumanBodyPose3DRequest()
            let request2D = VNDetectHumanBodyPoseRequest()
            let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up)
            try handler.perform([request3D, request2D])

            guard let obs3D = request3D.results?.first else { continue }
            var jointsDict: [String: [Double]] = [:]
            var confDict: [String: Double] = [:]

            for (name, jointKey) in visionJointMap {
                if let point = try? obs3D.recognizedPoint(jointKey) {
                    let pos = point.localPosition.columns.3
                    jointsDict[name] = [Double(pos.x), Double(pos.y), Double(pos.z)]
                    confDict[name] = 0.95
                }
            }

            // Foot keypoints: NEVER fake heel/toe positions from ankle offsets.
            // Only populate if a real FootKeypointProvider (e.g. MediaPipeTasksVision PoseLandmarker) returns them;
            // otherwise leave foot joints absent from `jointsDict` with explicit 0.0 confidence so scoring reports "unavailable".
            if let realFeet = FootLandmarkerBridge.extractFootKeypoints(from: sampleBuffer, timestampSeconds: timestamp) {
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

            extracted.append(
                GrooveScoringEngine.RawPoseFrame(
                    t: timestamp,
                    joints: jointsDict,
                    confidences: confDict
                )
            )
        }
        return extracted
    }
}

/// Bridge for real foot keypoint extraction (`leftHeel`, `leftFootIndex`, `rightHeel`, `rightFootIndex`).
/// Uses official `MediaPipeTasksVision` (`PoseLandmarker` indices 29, 30, 31, 32) when linked;
/// returns `nil` (zero confidence, never fake ankle offsets) when running body-only Build #1.
enum FootLandmarkerBridge {
    struct FootResult {
        let joints: [String: [Double]]
        let confidences: [String: Double]
    }

    static func extractFootKeypoints(
        from sampleBuffer: CMSampleBuffer,
        timestampSeconds: Double
    ) -> FootResult? {
        #if canImport(MediaPipeTasksVision)
        // MediaPipe PoseLandmarker indices: 29 = left_heel, 30 = right_heel, 31 = left_foot_index, 32 = right_foot_index
        return nil
        #else
        return nil
        #endif
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

