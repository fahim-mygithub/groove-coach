import AVFoundation
import GrooveCore
import SwiftUI
import UIKit

// MARK: - Dedicated TV Camera Preview (§1.2, §4.1, §10 #10)

/// Dedicated 16:9 TV-stage `AVCaptureVideoPreviewLayer` host with zero dependency on `PracticeView.swift`.
/// Forces upright portrait framing (`videoRotationAngle = 90`) and explicit horizontal preview mirroring
/// (`automaticallyAdjustsVideoMirroring = false`, `isVideoMirrored = true`) on `.back` so a dancer watching
/// the TV moves screen-left when stepping to their own left—matching `PracticeCamera.mirrorForDisplay = true`
/// and `ScreenStreamer.collectPreviews` (`ScreenStreamer.swift:196-205`).
struct TVCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool = true

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        var desiredMirrored: Bool = true

        override func layoutSubviews() {
            super.layoutSubviews()
            applyConnectionSettings()
        }

        func applyConnectionSettings() {
            guard let connection = previewLayer.connection else { return }
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                // `automaticallyAdjustsVideoMirroring` MUST be disabled before setting `isVideoMirrored`.
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = desiredMirrored
            }
        }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.desiredMirrored = mirrored
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.applyConnectionSettings()
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.desiredMirrored = mirrored
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.previewLayer.videoGravity = .resizeAspect
        uiView.applyConnectionSettings()
    }
}

// MARK: - Observable TV Stage State Container (for Order #12 CoachingStageCoordinator)

/// Shared observable state model driving `TVCoachingStageView` inside `ExternalDisplayManager.shared.stageBuilder`
/// so beat updates, count-in ticks, live limb matching, scorecards, and gesture toasts re-render smoothly on the
/// external `UIWindowScene` without rebuilding the root `UIWindow`.
@MainActor
final class TVCoachingStageModel: ObservableObject {
    @Published var host: CoachingHost
    @Published var phase: CoachingPhase
    @Published var title: String
    @Published var subtitle: String
    @Published var playbackRate: Double
    @Published var isTeacherMirrored: Bool
    @Published var player: AVPlayer?
    @Published var hasTeacherVideo: Bool
    @Published var countInBeatsLeft: Int
    @Published var currentBeatCount: Int
    @Published var currentPhrase: Int
    @Published var liveState: LiveMatcher.LiveState?
    @Published var scoreResult: GrooveScoringEngine.AttemptScoreResult?
    @Published var resultPose: [String: CGPoint]
    @Published var gradingRefusalReason: String?
    @Published var referencePose: [String: CGPoint]
    @Published var nextUnlocked: Bool
    @Published var toastText: String?
    @Published var statusMessage: String?

    init(
        host: CoachingHost = .lesson,
        phase: CoachingPhase = .idle,
        title: String = "Groove Coach",
        subtitle: String = "",
        playbackRate: Double = 1.0,
        isTeacherMirrored: Bool = true,
        player: AVPlayer? = nil,
        hasTeacherVideo: Bool = false,
        countInBeatsLeft: Int = 0,
        currentBeatCount: Int = 1,
        currentPhrase: Int = 1,
        liveState: LiveMatcher.LiveState? = nil,
        scoreResult: GrooveScoringEngine.AttemptScoreResult? = nil,
        resultPose: [String: CGPoint] = [:],
        gradingRefusalReason: String? = nil,
        referencePose: [String: CGPoint] = [:],
        nextUnlocked: Bool = false,
        toastText: String? = nil,
        statusMessage: String? = nil
    ) {
        self.host = host
        self.phase = phase
        self.title = title
        self.subtitle = subtitle
        self.playbackRate = playbackRate
        self.isTeacherMirrored = isTeacherMirrored
        self.player = player
        self.hasTeacherVideo = hasTeacherVideo
        self.countInBeatsLeft = countInBeatsLeft
        self.currentBeatCount = currentBeatCount
        self.currentPhrase = currentPhrase
        self.liveState = liveState
        self.scoreResult = scoreResult
        self.resultPose = resultPose
        self.gradingRefusalReason = gradingRefusalReason
        self.referencePose = referencePose
        self.nextUnlocked = nextUnlocked
        self.toastText = toastText
        self.statusMessage = statusMessage
    }
}

// MARK: - Production 16:9 Landscape TV Coaching Stage (§4.1 items 1–3, §5.4, §10 #10)

/// Full-bleed 16:9 landscape 10-foot UI hosted on the external AirPlay / wired TV `UIWindowScene`:
/// 1. **Calibration Stage (40/60 split):** High-contrast target pose mannequin (`Pose 1 of 9`), step title,
///    `42 pt` bold spoken cue banner, and 9-dot progress bar on the left 40%; mirrored `TVCameraPreview`,
///    green/red safe-box, live skeleton, LiDAR distance pill, and `160 pt` radial hold ring on the right 60%.
/// 2. **Lesson / Practice Stage (50/50 split):** `PlayerLayerView` (flipped when `isTeacherMirrored == true`)
///    on the left 50%; mirrored `TVCameraPreview` + `TVLiveOverlay` (`LiveMatcher` ok/warn/off limb colours and
///    clean-beat streak badge) on the right 50%; center-spanning `96 pt` `4-3-2-1` count-in, `1..8` beat bar,
///    and pre-trigger `GestureHoldRingView` / `40 pt` `GestureToast`.
/// 3. **Results Stage (10-foot scorecard):** `PASS / KEEP DRILLING` banner, `Shape / Groove / Hits / Hands` chips,
///    top joint hint, worst beat offset, coloured stick figure, and bottom gesture legend
///    (*"Swipe Left: Try Again · Swipe Right: Next · Clap: Continue"*).
@MainActor
struct TVCoachingStageView: View {
    @ObservedObject var model: TVCoachingStageModel
    @ObservedObject var camera: PracticeCamera
    @ObservedObject var calibration: CalibrationController

    init(
        model: TVCoachingStageModel,
        camera: PracticeCamera,
        calibration: CalibrationController
    ) {
        self.model = model
        self.camera = camera
        self.calibration = calibration
    }

    /// Convenience value-based initialiser for standalone previews or direct stage builders.
    init(
        camera: PracticeCamera,
        calibration: CalibrationController,
        host: CoachingHost = .lesson,
        phase: CoachingPhase = .idle,
        title: String = "Groove Coach",
        subtitle: String = "",
        playbackRate: Double = 1.0,
        isTeacherMirrored: Bool = true,
        player: AVPlayer? = nil,
        hasTeacherVideo: Bool = false,
        countInBeatsLeft: Int = 0,
        currentBeatCount: Int = 1,
        currentPhrase: Int = 1,
        liveState: LiveMatcher.LiveState? = nil,
        scoreResult: GrooveScoringEngine.AttemptScoreResult? = nil,
        resultPose: [String: CGPoint] = [:],
        gradingRefusalReason: String? = nil,
        referencePose: [String: CGPoint] = [:],
        nextUnlocked: Bool = false,
        toastText: String? = nil,
        statusMessage: String? = nil
    ) {
        self.model = TVCoachingStageModel(
            host: host,
            phase: phase,
            title: title,
            subtitle: subtitle,
            playbackRate: playbackRate,
            isTeacherMirrored: isTeacherMirrored,
            player: player,
            hasTeacherVideo: hasTeacherVideo,
            countInBeatsLeft: countInBeatsLeft,
            currentBeatCount: currentBeatCount,
            currentPhrase: currentPhrase,
            liveState: liveState,
            scoreResult: scoreResult,
            resultPose: resultPose,
            gradingRefusalReason: gradingRefusalReason,
            referencePose: referencePose,
            nextUnlocked: nextUnlocked,
            toastText: toastText,
            statusMessage: statusMessage
        )
        self.camera = camera
        self.calibration = calibration
    }

    private var effectivePhase: CoachingPhase {
        if model.phase == .calibrating || calibration.status != nil {
            return .calibrating
        }
        return model.phase
    }

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.04, blue: 0.07)
                .ignoresSafeArea()

            switch effectivePhase {
            case .calibrating:
                calibrationStage
            case .results:
                resultsStage
            case .idle, .clapSync, .countIn, .recording, .analyzing, .paused:
                practiceOrLessonStage
            }

            // Center-spanning gesture feedback HUD (pre-trigger hold ring >= 0.15 + 40 pt toast banner, §5.4)
            gestureFeedbackHUD
        }
        .animation(.easeInOut(duration: 0.2), value: effectivePhase)
        .animation(.easeInOut(duration: 0.2), value: model.toastText)
    }

    // MARK: - Top-Center Gesture Feedback HUD (§5.4)

    private var gestureFeedbackHUD: some View {
        VStack(spacing: 14) {
            if let toast = model.toastText, !toast.isEmpty {
                GestureToast(text: toast, tvScale: true)
            }
            if effectivePhase != .calibrating {
                GestureHoldRingView(
                    progress: camera.gestureHoldProgress,
                    phase: effectivePhase,
                    tvScale: true
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    // MARK: - 1. Calibration Stage (40% Mannequin + Cue / 60% Mirrored Preview + 160 pt Hold Ring)

    private var calibrationStage: some View {
        let st = calibration.status ?? CalibrationStatus(
            step: .level,
            cue: .placePhone,
            progress: 0,
            lightAdvice: .ok,
            relaxed: false,
            skipped: false
        )

        return GeometryReader { geo in
            let horizontalPad: CGFloat = 32
            let spacing: CGFloat = 26
            let innerWidth = max(0, geo.size.width - horizontalPad * 2 - spacing)
            let leftWidth = innerWidth * 0.40
            let rightWidth = innerWidth * 0.60

            HStack(spacing: spacing) {
                calibrationLeftPanel(status: st)
                    .frame(width: leftWidth, height: max(0, geo.size.height - 56))

                calibrationRightPreviewPanel(status: st)
                    .frame(width: rightWidth, height: max(0, geo.size.height - 56))
            }
            .padding(.horizontal, horizontalPad)
            .padding(.vertical, 28)
        }
    }

    private func calibrationLeftPanel(status st: CalibrationStatus) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // Step header (`Pose 1 of 9 · Resting Stance`)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: camera.cameraMode.usesLiDAR ? "sensor.tag.radiowaves.forward.fill" : "camera.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.cyan)
                    Text(cameraModeBadgeLabel(camera.cameraMode))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(.cyan)
                }

                Text(CalibrationOverlayView.stepLabel(st.step, tier: calibration.calibrationTier))
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.yellow)
                    .lineLimit(2)
            }

            // Spoken cue banner (`42 pt` bold per §4.1 item 1)
            HStack(alignment: .top, spacing: 14) {
                if let arrow = CalibrationOverlayView.arrow(for: st.cue) {
                    Image(systemName: arrow)
                        .font(.system(size: 38, weight: .heavy))
                        .foregroundStyle(.yellow)
                        .padding(.top, 4)
                }
                Text(calibrationInstruction(st))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.68)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))

            // High-contrast target pose mannequin (or TV bubble-level gauge during `.level`)
            ZStack {
                if st.step == .level {
                    TVLevelGaugeView(
                        rollDeg: calibration.rollDeg,
                        tiltBackDeg: calibration.tiltBackDeg,
                        tuning: calibration.tuning
                    )
                } else {
                    ZStack {
                        CalibrationPoseSilhouetteView(
                            step: st.step,
                            isHolding: st.progress > 0,
                            lrSwappedWarning: st.cue == .swapArmsLR
                        )
                        if st.step == .asymLR {
                            HStack {
                                Text("L · UP")
                                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.yellow, in: Capsule())
                                Spacer()
                                Text("R · OUT")
                                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.yellow, in: Capsule())
                            }
                            .padding(18)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 9-dot progress bar + hands-free calibration gesture legend
            VStack(alignment: .leading, spacing: 12) {
                TVCalibrationProgressBar(
                    currentStep: st.step,
                    completedSteps: calibration.completedSteps
                )

                Text("Clap: Repeat Cue  ·  Double-Clap: Skip Calibration")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.68))
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 26)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 26)
                        .stroke(Color.white.opacity(0.14), lineWidth: 2)
                )
        )
    }

    private func calibrationRightPreviewPanel(status st: CalibrationStatus) -> some View {
        GeometryReader { geo in
            let rect = CalibrationOverlayView.fittedRect(
                in: geo.size,
                imageAspect: camera.skeleton.imageAspect
            )

            ZStack {
                RoundedRectangle(cornerRadius: 26)
                    .fill(Color.black)

                TVCameraPreview(session: camera.session, mirrored: true)
                    .clipShape(RoundedRectangle(cornerRadius: 26))

                SkeletonOverlay(
                    joints: camera.skeleton.joints,
                    severities: [:],
                    imageAspect: camera.skeleton.imageAspect,
                    tvScale: true
                )

                if st.step.poseKind != nil || st.isLocked {
                    tvFramingSafeBox(in: rect, status: st)
                }

                // Top-left & top-right telemetry pills (LiDAR distance + non-blocking light/height advice)
                VStack {
                    HStack(alignment: .top, spacing: 12) {
                        if let dist = st.dancerDistanceM, dist.isFinite, dist > 0 {
                            tvDistancePill(distanceM: dist, status: st)
                        }
                        Spacer(minLength: 0)
                        tvCalibrationAdvisoryPill(status: st)
                    }
                    Spacer(minLength: 0)
                }
                .padding(22)

                // `160 pt` radial hold ring (§4.1 item 1 & §10 #10)
                VStack {
                    Spacer(minLength: 0)
                    HStack {
                        Spacer(minLength: 0)
                        TVCalibrationHoldRing(
                            progress: st.progress,
                            locked: st.isLocked,
                            icon: CalibrationOverlayView.icon(for: st.step)
                        )
                        .frame(width: 160, height: 160)
                    }
                }
                .padding(26)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 26)
                    .stroke(
                        CalibrationOverlayView.isFramingSatisfied(status: st)
                            ? Color.green.opacity(0.75)
                            : Color.white.opacity(0.22),
                        lineWidth: 3
                    )
            )
        }
    }

    private func tvFramingSafeBox(in rect: CGRect, status st: CalibrationStatus) -> some View {
        let u = calibration.tuning
        let isLateralStep = (st.step == .stepLeft || st.step == .stepRight)
        let rawMinX = isLateralStep ? min(0.04, u.safeBoxMinX) : u.safeBoxMinX
        let rawMaxX = isLateralStep ? max(0.96, u.safeBoxMaxX) : u.safeBoxMaxX
        let minX = 1.0 - rawMaxX
        let maxX = 1.0 - rawMinX
        let box = CGRect(
            x: rect.minX + minX * rect.width,
            y: rect.minY + u.minNoseY * rect.height,
            width: (maxX - minX) * rect.width,
            height: (u.maxFootY - u.minNoseY) * rect.height
        )
        let ok = CalibrationOverlayView.isFramingSatisfied(status: st)
        return RoundedRectangle(cornerRadius: 22)
            .stroke(
                ok ? Color.green : Color.red,
                style: StrokeStyle(lineWidth: 5, dash: ok ? [] : [14, 8])
            )
            .frame(width: max(0, box.width), height: max(0, box.height))
            .position(x: box.midX, y: box.midY)
            .allowsHitTesting(false)
    }

    private func tvDistancePill(distanceM: Double, status st: CalibrationStatus) -> some View {
        let u = calibration.tuning
        let minBase = st.effectiveMinDistanceM ?? u.lidarMinDistanceM
        let maxBase = u.lidarMaxDistanceM
        let delta = (st.progress > 0 ? u.lidarDistanceStayDeltaM : 0.0)
            + (st.relaxed ? u.lidarDistanceRelaxDeltaM : 0.0)
        let minUsed = max(u.lidarMinDistanceM, minBase - delta)
        let maxUsed = maxBase + delta
        let inBand = st.cue != .stepBackDistance && st.cue != .stepCloserDistance
            && distanceM >= minUsed && distanceM <= maxUsed
        let targetMin = CalibrationPoseScorers.spokenTargetMinDistanceM(for: minBase)
        let text = inBand
            ? String(format: "%.1f m", distanceM)
            : String(format: "%.1f m (target %.1f–%.0f m)", distanceM, targetMin, maxBase)
        let accent: Color = inBand ? .green : .orange

        return HStack(spacing: 10) {
            Image(systemName: "sensor.tag.radiowaves.forward.fill")
                .font(.system(size: 24, weight: .bold))
            Text(text)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.78), in: Capsule())
        .overlay(
            Capsule()
                .stroke(accent.opacity(0.75), lineWidth: 2)
        )
    }

    @ViewBuilder
    private func tvCalibrationAdvisoryPill(status st: CalibrationStatus) -> some View {
        if st.lightAdvice != .ok {
            tvAdvisoryBadge(
                text: st.lightCue.spokenText,
                icon: st.lightCue == .backlit ? "sun.max.trianglebadge.exclamationmark" : "lightbulb.fill"
            )
        } else if st.cameraHeightCue != .none {
            tvAdvisoryBadge(
                text: st.cameraHeightCue.spokenText,
                icon: "arrow.up.and.down.circle.fill"
            )
        }
    }

    private func tvAdvisoryBadge(text: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .bold))
            Text(text)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(2)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.95), in: Capsule())
    }

    private func calibrationInstruction(_ st: CalibrationStatus) -> String {
        if st.isLocked {
            if st.skipped { return "Calibration skipped." }
            return calibration.calibrationTier == .tier2FullCalibration
                ? CalibrationVoice.studioCalibratedLockedText
                : CalibrationCue.locked.spokenText
        }
        if st.step == .resume {
            return "Checking your studio setup…"
        }
        if st.step == .plie && st.cue == .bendKneesDeeper && !calibration.hasEnteredPlieHold {
            return CalibrationVoice.plieEntryText
        }
        if st.cue != .none {
            return st.cue.spokenText(
                dancerDistanceM: st.dancerDistanceM,
                effectiveMinDistanceM: st.effectiveMinDistanceM
            )
        }
        return CalibrationOverlayView.holdingPrompt(for: st.step)
    }

    private func cameraModeBadgeLabel(_ mode: CameraMode) -> String {
        switch mode {
        case .rearLiDAR:
            return "STUDIO · REAR CAMERA + LiDAR"
        case .rearWide:
            return "STUDIO · REAR CAMERA"
        case .frontSelfView:
            return "FRONT CAMERA"
        }
    }

    // MARK: - 2. Lesson / Practice 50/50 Split Stage (§4.1 item 2, §10 #10)

    private var practiceOrLessonStage: some View {
        ZStack {
            GeometryReader { geo in
                let pad: CGFloat = 28
                let gap: CGFloat = 22
                let halfWidth = max(0, (geo.size.width - pad * 2 - gap) * 0.50)
                let stageHeight = max(0, geo.size.height - pad * 2)

                HStack(spacing: gap) {
                    teacherHalfStage
                        .frame(width: halfWidth, height: stageHeight)

                    learnerHalfStage
                        .frame(width: halfWidth, height: stageHeight)
                }
                .padding(pad)
            }

            // Center-spanning Count-In (`96 pt`), Analyzing / Paused notice, and `1..8` Beat Bar
            VStack {
                stageTopHeaderPill
                    .padding(.top, 20)

                Spacer(minLength: 0)

                centerPhaseBanner

                Spacer(minLength: 0)

                bottomStageHUD
                    .padding(.bottom, 22)
            }
            .padding(.horizontal, 36)
            .allowsHitTesting(false)
        }
    }

    private var teacherHalfStage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.black)

            if let player = model.player, model.hasTeacherVideo {
                PlayerLayerView(player: player, isMirrored: model.isTeacherMirrored)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
            } else if !model.referencePose.isEmpty {
                SkeletonOverlay(
                    joints: model.referencePose,
                    severities: [:],
                    imageAspect: 9.0 / 16.0,
                    tvScale: true
                )
                .padding(24)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "figure.dance")
                        .font(.system(size: 68, weight: .bold))
                        .foregroundStyle(.cyan.opacity(0.85))
                    Text(model.title)
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if !model.subtitle.isEmpty {
                        Text(model.subtitle)
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
                .padding(32)
            }

            // Top-left Teacher label + Mirroring & Tempo pills
            VStack {
                HStack(spacing: 10) {
                    stageCornerBadge(
                        text: model.isTeacherMirrored ? "TEACHER · MIRRORED" : "TEACHER · AS FILMED",
                        icon: "person.crop.rectangle.fill",
                        tint: .indigo
                    )
                    stageCornerBadge(
                        text: String(format: "%.2fx", model.playbackRate),
                        icon: "speedometer",
                        tint: .green
                    )
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.18), lineWidth: 2.5)
        )
    }

    private var learnerHalfStage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.black)

            TVCameraPreview(session: camera.session, mirrored: true)
                .clipShape(RoundedRectangle(cornerRadius: 24))

            TVLiveOverlay(
                camera: camera,
                liveState: model.liveState,
                severities: JointSeverityMap.from(model.scoreResult?.joint_feedback),
                mirroredLimbs: model.isTeacherMirrored,
                showStreakBadge: effectivePhase == .recording || model.liveState != nil
            )

            // Top-right Learner status + REC badge
            VStack {
                HStack(spacing: 10) {
                    if effectivePhase == .recording || effectivePhase == .countIn {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 14, height: 14)
                            Text(effectivePhase == .recording ? "REC" : "READY")
                                .font(.system(size: 22, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.78), in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.red.opacity(0.8), lineWidth: 2)
                        )
                    }

                    Spacer(minLength: 0)

                    stageCornerBadge(
                        text: "YOU · MIRRORED",
                        icon: "camera.viewfinder",
                        tint: .cyan
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(
                    effectivePhase == .recording ? Color.yellow.opacity(0.7) : Color.cyan.opacity(0.35),
                    lineWidth: 2.5
                )
        )
    }

    @ViewBuilder
    private var stageTopHeaderPill: some View {
        if camera.gestureHoldProgress < GestureHoldRingView.defaultVisibilityThreshold && model.toastText == nil {
            HStack(spacing: 12) {
                Text(model.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !model.subtitle.isEmpty {
                    Text("·")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(model.subtitle)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.74), in: Capsule())
        }
    }

    @ViewBuilder
    private var centerPhaseBanner: some View {
        if effectivePhase == .countIn && model.countInBeatsLeft > 0 {
            VStack(spacing: 8) {
                Text("COUNT-IN")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.yellow)
                Text("\(model.countInBeatsLeft)")
                    .font(.system(size: 96, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .yellow.opacity(0.65), radius: 20)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 26)
            .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 32))
            .overlay(
                RoundedRectangle(cornerRadius: 32)
                    .stroke(Color.yellow.opacity(0.8), lineWidth: 3)
            )
            .transition(.scale.combined(with: .opacity))
        } else if effectivePhase == .analyzing {
            HStack(spacing: 18) {
                ProgressView()
                    .tint(.cyan)
                    .scaleEffect(1.6)
                Text("Scoring your take…")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .background(Color.black.opacity(0.85), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.cyan.opacity(0.75), lineWidth: 2.5)
            )
        } else if effectivePhase == .paused {
            VStack(spacing: 12) {
                Label("TAKE PAUSED", systemImage: "pause.circle.fill")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(.orange)
                Text(model.statusMessage ?? "Clap or Hold Both Hands Up to Resume  ·  Swipe Left: Review")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 26)
            .background(Color.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 28))
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Color.orange.opacity(0.8), lineWidth: 2.5)
            )
        } else if effectivePhase == .clapSync {
            VStack(spacing: 10) {
                Label("TV AUDIO CLAP SYNC", systemImage: "hands.clap.fill")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(.green)
                Text(model.statusMessage ?? "Listen for 1, 2, 3 — CLAP on beat 4!")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 24)
            .background(Color.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 28))
        }
    }

    @ViewBuilder
    private var bottomStageHUD: some View {
        if effectivePhase == .recording || effectivePhase == .countIn {
            TVBeatBarView(
                currentPhrase: model.currentPhrase,
                currentBeatCount: effectivePhase == .recording ? model.currentBeatCount : 0
            )
        } else if effectivePhase == .idle {
            HStack(spacing: 18) {
                TVBeatBarView(
                    currentPhrase: model.currentPhrase,
                    currentBeatCount: model.currentBeatCount
                )

                Text(
                    model.host == .lesson
                        ? "Hands Up: Start Take  ·  Clap: Play/Pause  ·  Swipe ←: Restart  ·  Swipe →: Next"
                        : "Hands Up or Clap: Start Take  ·  Swipe →: Next Move"
                )
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(Color.black.opacity(0.78), in: Capsule())
            }
        }
    }

    private func stageCornerBadge(text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.74), in: Capsule())
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.6), lineWidth: 1.5)
        )
    }

    // MARK: - 3. Results 10-Foot Scorecard Stage (§4.1 item 3, §10 #10)

    private var resultsStage: some View {
        VStack(spacing: 22) {
            if let refusal = model.gradingRefusalReason {
                gradingRefusedCard(reason: refusal)
            } else if let result = model.scoreResult {
                scorecardHeader(result: result)
                scorecardBody(result: result)
            } else {
                Spacer(minLength: 0)
                Text("Take complete")
                    .font(.system(size: 48, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }

            resultsGestureLegend
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 30)
    }

    private func gradingRefusedCard(reason: String) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.orange)
            Text("Keep Full Body in View")
                .font(.system(size: 48, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text(reason)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 26)
                .fill(Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 26)
                        .stroke(Color.orange.opacity(0.65), lineWidth: 2.5)
                )
        )
    }

    private func scorecardHeader(result: GrooveScoringEngine.AttemptScoreResult) -> some View {
        let accent: Color = result.passed ? .green : .orange
        return HStack(alignment: .center, spacing: 20) {
            HStack(spacing: 16) {
                Image(systemName: result.passed ? "checkmark.seal.fill" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 52, weight: .black))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.passed ? "PASS" : "KEEP DRILLING")
                        .font(.system(size: 52, weight: .black, design: .rounded))
                        .foregroundStyle(accent)
                    Text(model.title)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 6) {
                Text(
                    String(
                        format: "%+.0f ms  ·  %.0f%% ON BEAT",
                        result.mean_offset_ms,
                        result.good_or_better_ratio * 100
                    )
                )
                .font(.system(size: 32, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)

                Text(
                    String(
                        format: "Tempo %.2fx%@",
                        model.playbackRate,
                        model.nextUnlocked ? "  ·  Next Unlocked" : ""
                    )
                )
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(model.nextUnlocked ? .green : .white.opacity(0.65))
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(accent.opacity(0.65), lineWidth: 2.5)
                )
        )
    }

    private func scorecardBody(result: GrooveScoringEngine.AttemptScoreResult) -> some View {
        let severities = JointSeverityMap.from(result.joint_feedback)
        let flagged = (result.joint_feedback.verdicts + result.joint_feedback.angle_verdicts)
            .filter { $0.severity != "ok" }
            .sorted { JointSeverityMap.rank($0.severity) > JointSeverityMap.rank($1.severity) }
            .prefix(3)
            .map { $0 }

        return HStack(spacing: 28) {
            // Left: Coloured stick figure at first beat
            VStack(spacing: 10) {
                SkeletonOverlay(
                    joints: model.resultPose,
                    severities: severities,
                    imageAspect: 0.62,
                    tvScale: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text("JOINT VERDICTS")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(20)
            .frame(width: 300)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.black.opacity(0.88))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.white.opacity(0.18), lineWidth: 2)
                    )
            )

            // Right: Shape/Groove/Hits/Hands chips, top joint hint, worst beat offset, & flagged joints
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    tvScoreChip(title: "SHAPE", value: result.shape_score)
                    tvScoreChip(title: "GROOVE", value: result.groove_score)
                    if let hit = result.hit_timing.hit_score {
                        tvScoreChip(title: "HITS", value: hit)
                    }
                    if let hand = result.hand_styling.hand_score {
                        tvScoreChip(title: "HANDS", value: hand)
                    }
                }

                // Top Joint Hint (`36 pt` bold)
                VStack(alignment: .leading, spacing: 8) {
                    if let hint = result.joint_feedback.top_hint, !hint.isEmpty {
                        Label(
                            hint.prefix(1).uppercased() + hint.dropFirst(),
                            systemImage: "figure.dance"
                        )
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.yellow)
                        .lineLimit(2)
                    } else if result.joint_feedback.status == "available" {
                        Label("All joints within tolerance", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                    }

                    Text(result.top_issue)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))

                // Worst Beat Offset + Hit / Hand Details
                HStack(spacing: 18) {
                    worstBeatPill(result.worst_beat)
                    if let hitDetail = tvHitSummary(result.hit_timing) {
                        detailPill(icon: "metronome.fill", text: hitDetail, tint: .cyan)
                    }
                }

                if !flagged.isEmpty {
                    HStack(spacing: 14) {
                        ForEach(Array(flagged.enumerated()), id: \.offset) { _, verdict in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(JointSeverityMap.color(verdict.severity))
                                    .frame(width: 14, height: 14)
                                Text(verdict.hint ?? verdict.joint)
                                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.08), in: Capsule())
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func tvScoreChip(title: String, value: Double) -> some View {
        let tint: Color = value >= 80 ? .green : (value >= 65 ? .yellow : .orange)
        return VStack(spacing: 6) {
            Text(String(format: "%.0f", value))
                .font(.system(size: 46, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(tint.opacity(0.5), lineWidth: 2)
                )
        )
    }

    private func worstBeatPill(_ worst: GrooveScoringEngine.BeatJudgment) -> some View {
        let direction = worst.offset_ms >= 0 ? "late" : "early"
        let text = String(
            format: "Worst Beat #%d: %.0f ms %@ (%@)",
            worst.count_number,
            abs(worst.offset_ms),
            direction,
            worst.judgment.uppercased()
        )
        let isClean = worst.judgment == "perfect" || worst.judgment == "good"
        return detailPill(
            icon: "waveform.path.ecg",
            text: text,
            tint: isClean ? .green : .orange
        )
    }

    private func detailPill(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 23, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.07), in: Capsule())
    }

    private func tvHitSummary(_ hits: GrooveScoringEngine.HitTimingResult) -> String? {
        guard hits.status == "available" else { return nil }
        guard let mean = hits.mean_offset_ms else {
            return "Hits 0/\(hits.per_hit.count) landed"
        }
        let dir = mean >= 0 ? "late" : "early"
        return "Hits \(hits.matched_count)/\(hits.per_hit.count) (\(Int(abs(mean).rounded())) ms \(dir))"
    }

    /// Bottom gesture legend required by spec §4.1 item 3:
    /// *"Swipe Left: Try Again · Swipe Right: Next · Clap: Continue"*.
    private var resultsGestureLegend: some View {
        HStack(spacing: 24) {
            legendItem(icon: "arrow.left.circle.fill", text: "Swipe Left: Try Again", tint: .yellow)
            Text("·")
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(.white.opacity(0.4))
            legendItem(
                icon: "arrow.right.circle.fill",
                text: (model.host == .practice || model.nextUnlocked) ? "Swipe Right: Next" : "Swipe Right: Review",
                tint: (model.host == .practice || model.nextUnlocked) ? .green : .cyan
            )
            Text("·")
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(.white.opacity(0.4))
            legendItem(icon: "hands.clap.fill", text: "Clap: Continue", tint: .cyan)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1.5)
                )
        )
    }

    private func legendItem(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Dedicated TV Subviews (No PracticeView Dependency)

/// Dedicated TV live learner overlay (`LiveMatcher` ok/warn/off limb colours, clean-beat streak badge,
/// hand-shape badge, and camera error banner; §4.1 item 2 & §10 #10).
struct TVLiveOverlay: View {
    @ObservedObject var camera: PracticeCamera
    var liveState: LiveMatcher.LiveState?
    var severities: [String: String]
    var mirroredLimbs: Bool = true
    var showStreakBadge: Bool = false

    var body: some View {
        ZStack {
            SkeletonOverlay(
                joints: camera.skeleton.joints,
                severities: severities,
                imageAspect: camera.skeleton.imageAspect,
                limbStates: liveState?.limbs,
                mirroredLimbs: mirroredLimbs,
                tvScale: true
            )

            VStack {
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 14) {
                    if showStreakBadge {
                        CleanBeatStreakBadge(
                            streak: liveState?.streak ?? 0,
                            tvScale: true
                        )
                    }

                    if !camera.handShapes.isEmpty {
                        Text(handLabel)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Color.black.opacity(0.75), in: Capsule())
                    }

                    Spacer(minLength: 0)

                    if let error = camera.cameraError {
                        Text(error)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Color.black.opacity(0.82), in: Capsule())
                    }
                }
            }
            .padding(20)
        }
        .allowsHitTesting(false)
    }

    private var handLabel: String {
        ["left", "right"].compactMap { side in
            camera.handShapes[side].map { "\(side == "left" ? "L" : "R"): \($0)" }
        }.joined(separator: "  ·  ")
    }
}

/// 10-foot `1..8` beat indicator track rendered along the bottom-center of `TVCoachingStageView` (§4.1 item 2).
struct TVBeatBarView: View {
    let currentPhrase: Int
    let currentBeatCount: Int

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PHRASE \(currentPhrase)")
                    .font(.system(size: 16, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                Text(currentBeatCount > 0 ? "COUNT \(currentBeatCount)" : "READY")
                    .font(.system(size: 26, weight: .black, design: .monospaced))
                    .foregroundStyle(.yellow)
            }
            .padding(.trailing, 6)

            HStack(spacing: 10) {
                ForEach(1...8, id: \.self) { count in
                    let active = currentBeatCount == count
                    ZStack {
                        Circle()
                            .fill(active ? Color.yellow : Color.white.opacity(0.18))
                            .frame(width: 48, height: 48)
                        Text("\(count)")
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .foregroundStyle(active ? Color.black : Color.white)
                    }
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.82), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.22), lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }
}

/// 10-foot `160 pt` radial hold ring for the Calibration TV stage (§4.1 item 1, §10 #10).
struct TVCalibrationHoldRing: View {
    let progress: Double
    let locked: Bool
    let icon: String

    var body: some View {
        let clamped = min(1.0, max(0.0, progress))
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.74))
            Circle()
                .stroke(Color.white.opacity(0.24), lineWidth: 14)
                .padding(8)
            Circle()
                .trim(from: 0, to: CGFloat(locked ? 1.0 : clamped))
                .stroke(
                    Color.green,
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(8)

            VStack(spacing: 6) {
                Image(systemName: locked ? "checkmark" : icon)
                    .font(.system(size: 46, weight: .heavy))
                    .foregroundStyle(locked ? .green : .white)
                if !locked && clamped > 0 {
                    Text(String(format: "%.0f%%", clamped * 100))
                        .font(.system(size: 24, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.green)
                }
            }
        }
        .shadow(color: .black.opacity(0.55), radius: 14, y: 4)
        .allowsHitTesting(false)
    }
}

/// 10-foot 9-dot progress bar for Poses 1–9 on the Calibration TV stage (§4.1 item 1).
struct TVCalibrationProgressBar: View {
    let currentStep: CalibrationStep
    var completedSteps: Set<CalibrationStep> = []

    private func isDone(_ poseIndex: Int) -> Bool {
        if currentStep == .locked { return true }
        if let active = CalibrationPoseProgressDots.poseNumber(for: currentStep), poseIndex < active {
            return true
        }
        switch poseIndex {
        case 1: return completedSteps.contains(.rest)
        case 2: return completedSteps.contains(.tpose)
        case 3: return completedSteps.contains(.overhead)
        case 4: return completedSteps.contains(.asymLR)
        case 5: return completedSteps.contains(.armsForward)
        case 6: return completedSteps.contains(.plie)
        case 7: return completedSteps.contains(.turned45)
        case 8: return completedSteps.contains(.stepLeft) && completedSteps.contains(.stepRight)
        case 9: return completedSteps.contains(.kneeLift)
        default: return false
        }
    }

    var body: some View {
        let activePose = CalibrationPoseProgressDots.poseNumber(for: currentStep)
        HStack(spacing: 12) {
            ForEach(1...9, id: \.self) { index in
                let done = isDone(index)
                let isCurrent = (activePose == index)
                if isCurrent {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.yellow.opacity(index == 8 && currentStep == .stepLeft ? 0.35 : 1.0))
                            .frame(width: 40, height: 16)
                        if index == 8 && currentStep == .stepLeft {
                            Capsule()
                                .fill(Color.yellow)
                                .frame(width: 22, height: 16)
                        }
                    }
                } else {
                    Circle()
                        .fill(done ? Color.green : Color.white.opacity(0.26))
                        .frame(width: 16, height: 16)
                }
            }
        }
    }
}

/// 10-foot phone roll & tilt gauge shown on the left 40% of `TVCoachingStageView` during `.level` (`stepIndex = 1`).
/// Reads `rollEnterDeg`, `tiltBackMinDeg`, and `tiltBackMaxDeg` directly from `CalibrationTuning` so live Debug Link
/// `tuning.json` overrides update the TV gauge automatically.
struct TVLevelGaugeView: View {
    let rollDeg: Double?
    let tiltBackDeg: Double?
    let tuning: CalibrationTuning

    private static let arcMin = -30.0
    private static let arcMax = 45.0

    var body: some View {
        let roll = rollDeg ?? 0.0
        let rollOK = abs(roll) <= tuning.rollEnterDeg
        let tilt = tiltBackDeg ?? 0.0
        let tiltOK = tilt >= tuning.tiltBackMinDeg && tilt <= tuning.tiltBackMaxDeg

        VStack(spacing: 18) {
            VStack(spacing: 10) {
                ZStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.28))
                        .frame(height: 3)
                    Capsule()
                        .fill(rollOK ? Color.green : Color.red)
                        .frame(width: 220, height: 10)
                        .rotationEffect(.degrees(-roll))
                }
                .frame(height: 54)

                Text(rollDeg.map { String(format: "Roll %+.1f°", $0) } ?? "Roll –")
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundStyle(rollOK ? .green : .white)
            }

            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height - 12)
                let radius = max(20, min(size.width / 2, size.height) - 16)
                func screenAngle(_ deg: Double) -> Angle {
                    let f = (deg - Self.arcMin) / (Self.arcMax - Self.arcMin)
                    return .degrees(-165 + 150 * min(1, max(0, f)))
                }

                var fullArc = Path()
                fullArc.addArc(
                    center: center,
                    radius: radius,
                    startAngle: screenAngle(Self.arcMin),
                    endAngle: screenAngle(Self.arcMax),
                    clockwise: false
                )
                ctx.stroke(fullArc, with: .color(.white.opacity(0.28)), lineWidth: 12)

                var targetWindow = Path()
                targetWindow.addArc(
                    center: center,
                    radius: radius,
                    startAngle: screenAngle(tuning.tiltBackMinDeg),
                    endAngle: screenAngle(tuning.tiltBackMaxDeg),
                    clockwise: false
                )
                ctx.stroke(targetWindow, with: .color(.green.opacity(0.85)), lineWidth: 12)

                if tiltBackDeg != nil {
                    let angleRad = screenAngle(tilt).radians
                    var needle = Path()
                    needle.move(to: center)
                    needle.addLine(
                        to: CGPoint(
                            x: center.x + cos(angleRad) * (radius + 8),
                            y: center.y + sin(angleRad) * (radius + 8)
                        )
                    )
                    ctx.stroke(
                        needle,
                        with: .color(tiltOK ? .green : .red),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                }
            }
            .frame(maxHeight: 160)

            Text(tiltBackDeg.map { String(format: "Tilt %+.1f°", $0) } ?? "Tilt –")
                .font(.system(size: 26, weight: .bold, design: .monospaced))
                .foregroundStyle(tiltOK ? .green : .white)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.black.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke((rollOK && tiltOK) ? Color.green.opacity(0.7) : Color.white.opacity(0.2), lineWidth: 2)
                )
        )
    }
}
