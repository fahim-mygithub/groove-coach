import Foundation

/// Every threshold `CalibrationGate` uses, in one live-swappable value (app-only; no Python parity).
///
/// Defaults are the numbers of `docs/research/2026-11-18-calibration-research.md` ("Recommended calibration
/// sequence") and `docs/specs/2026-11-26-calibration-v2-plan.md` (§7.2). Values marked (inference) there are
/// starting points to tune from device logs: the app polls the debug-link server's `tuning.json` and assigns
/// `CalibrationGate.tuning` without a rebuild.
///
/// JSON keys are the Swift property names. Decoding is partial: a missing (or `null`) key keeps its default, so a
/// `tuning.json` that sets one key works. Unknown keys and keys starting with `_` (e.g. `_comment`) are ignored.
/// A key with the wrong type (e.g. a string) is an error rather than being silently dropped.
///
/// Coordinates are MediaPipe normalised image coordinates of the un-mirrored portrait buffer, `y` down.
public struct CalibrationTuning: Codable, Equatable, Sendable {

    // MARK: Step 0 - resume

    /// Gravity may move less than this (g, Euclidean) from the stored profile to skip steps 1 and 4. (inference)
    public var resumeGravityDeltaG: Double

    // MARK: Step 1 - place & level the phone

    /// `|rollDeg|` at or below this starts counting as level (Poser shows level at < 3 deg).
    public var rollEnterDeg: Double
    /// Once level, `|rollDeg|` may grow to this before level is lost (hysteresis). (inference)
    public var rollExitDeg: Double
    /// Signed `tiltBackDeg = atan2(-g.z, -g.y)` window; negative leans forward. (inference)
    public var tiltBackMinDeg: Double
    public var tiltBackMaxDeg: Double
    /// `|userAcceleration|` (g) must stay below this for the phone to count as still. (inference)
    public var stillAccelMaxG: Double
    /// `|rotationRate|` (rad/s) must stay below this for the phone to count as still. (inference)
    public var stillRotationMaxRadS: Double
    /// Seconds level, upright and still before step 1 passes. (inference)
    public var phoneStillHoldS: Double
    /// After step 1, gravity moving more than this (g) from the locked gravity means the phone was bumped: back to
    /// step 1 (report "Open risks" 1). (inference)
    public var bumpGravityDeltaG: Double

    // MARK: Step 2 - full-body framing

    /// Both shoulders at or above this visibility means a person is present ("Step in front of the camera").
    public var presenceMinVisibility: Double
    /// Visibility floor for nose, shoulders, hips, knees and ankles.
    public var coreMinVisibility: Double
    /// Visibility floor for heels and foot-index points.
    public var footMinVisibility: Double
    /// Every core and foot point must have `x` in `[safeBoxMinX, safeBoxMaxX]`. (inference)
    public var safeBoxMinX: Double
    public var safeBoxMaxX: Double
    /// The lowest foot point (`max y` of heels and foot index) must be at or above this. (inference)
    public var maxFootY: Double
    /// `nose.y` must be at least this (headroom for raised wrists). (inference)
    public var minNoseY: Double
    /// Legacy v1 body size `span = maxFootY - nose.y` floor (`0.45`); superseded in v2 by `spanMinFloor` (§7.2).
    public var spanMin: Double
    public var spanMax: Double
    /// Hip midpoint `x` window (Ashrium, runform).
    public var hipCenterMinX: Double
    public var hipCenterMaxX: Double
    /// Seconds every framing check must pass before step 4.
    public var framingHoldS: Double
    /// Hysteresis: once framing passes, the visibility floors drop by this and the span window widens by
    /// `framingStaySpanDelta` (Ashrium enter/hold pattern). (inference)
    public var framingStayVisibilityDelta: Double
    public var framingStaySpanDelta: Double
    /// Seconds in step 2 after which the relaxed limits apply (Ashrium `RELAX_AFTER_MS = 15_000`).
    public var relaxAfterS: Double
    /// Relaxed mode: visibility floors drop by this, the span window widens by `relaxSpanDelta` each side.
    public var relaxVisibilityDelta: Double
    public var relaxSpanDelta: Double

    // MARK: Step 3 - lighting advice (never blocks)

    /// Mean luma (0...1) below this is dim (runform-coach-ai 0.22).
    public var dimLumaMax: Double
    /// Exposure duration (s) at or above this is dim (ai-smart-framing 0.033 s).
    public var dimExposureMinS: Double
    /// ISO at or above this is dim (ai-smart-framing front camera 450).
    public var dimISOMin: Double
    /// `iso / maxISO` at or above this is dim; device-independent. (inference)
    public var dimISORatioMin: Double
    /// Backlit when `borderLuma - torsoLuma` exceeds this ... (inference)
    public var backlightDeltaMin: Double
    /// ... and `torsoLuma` is below this. (inference)
    public var backlightTorsoLumaMax: Double
    /// Mean luma below this with no person present is "very dark" (OpenJustDance < 25/255).
    public var veryDarkLumaMax: Double

    // MARK: Step 4 - calibration T-pose

    /// `t_pose_score` floor (OpenJustDance `TPOSE_MIN_SCORE`).
    public var tPoseMinScore: Double
    /// Sub-score gates of OpenJustDance's `ok` flag: `s_y > 0.3`, `s_ang > 0.3`, `min(ext) > -0.15`.
    public var tPoseMinSY: Double
    public var tPoseMinSAng: Double
    public var tPoseMinExtension: Double
    /// Arm points below this visibility count as hidden in the score (more than 2 hidden scores 0).
    public var tPoseArmMinVisibility: Double
    /// Body motion per sample (shoulder+hip midpoint displacement / body span) to start the hold (Ashrium 0.012).
    public var motionEnterMax: Double
    /// ... and to stay in it (Ashrium 0.02).
    public var motionStayMax: Double
    /// Seconds the T-pose must be held. (inference)
    public var poseHoldS: Double
    /// Failing samples within this many seconds of the last good one keep the hold (OpenJustDance 0.35 s).
    public var dropoutToleranceS: Double
    /// Good samples needed before locking, so the bone medians are stable. (inference)
    public var minCapturedFrames: Int

    // MARK: Calibration v2 - studio distance, coupled span, LiDAR, AE lock & 9-pose holds (§7.2)

    /// Hard minimum 2D `maxFootY - nose.y` floor across 2–4 m before FoV/LiDAR coupling (§3.5, §7.2). (inference)
    public var spanMinFloor: Double
    /// Ratio `(h_nose - h_heel) / H_dancer` (`baby.py` 1.15 crown rule) used in pinhole `span_expected` (§3.2, §3.5).
    public var noseToFootHeightRatio: Double
    /// Relative `±` window around `span_expected` when coupling 2D `span` to LiDAR/FoV (§3.5). (inference)
    public var spanDepthToleranceRatio: Double
    /// Baseline minimum LiDAR torso distance (m) before FoV floor `d_geom_min` (§3.2).
    public var lidarMinDistanceM: Double
    /// Maximum LiDAR torso distance (m; §3.5).
    public var lidarMaxDistanceM: Double
    /// Hysteresis widening (m) on LiDAR distance once passing (§3.5). (inference)
    public var lidarDistanceStayDeltaM: Double
    /// Relaxed-mode (`15 s`) widening (m) on LiDAR distance bounds, clamped to `>= 2.0 m` (§3.5). (inference)
    public var lidarDistanceRelaxDeltaM: Double
    /// Lateral margin (m) added to `wingspanM` in portrait horizontal FoV floor `d_horiz_min` (§3.2). (inference)
    public var lateralStepMarginM: Double
    /// Tighter Pose 1 (`.rest`) min `hipCenterX` in Tier-2 full calibration (§2.2, §7.2). (inference)
    public var restHipCenterMinX: Double
    /// Tighter Pose 1 (`.rest`) max `hipCenterX` in Tier-2 full calibration (§2.2, §7.2). (inference)
    public var restHipCenterMaxX: Double
    /// Max LiDAR camera-height change (m) allowed for Tier-0 resume (§6.2). (inference)
    public var resumeFloorHeightDeltaM: Double
    /// Max LiDAR floor-normal change (deg) allowed for Tier-0 resume (§6.2). (inference)
    public var resumeFloorAngleDeg: Double
    /// Max LiDAR dancer-height delta (m) to reuse `body` in Tier-1 (§6.2). (inference)
    public var sameDancerHeightDeltaM: Double
    /// Low-camera non-blocking advisory threshold (m; Dina `50–70 cm`, §3.4).
    public var cameraHeightMinM: Double
    /// High-camera non-blocking advisory threshold (m; §3.4). (inference)
    public var cameraHeightMaxM: Double
    /// Max locked shutter duration (s) before custom ISO boost (`1/60 s`, §3.3). (inference)
    public var exposureMaxShutterS: Double
    /// Between-take luma drift triggering AE/AWB re-meter (§3.3). (inference)
    public var remeterLumaDelta: Double
    /// Hold duration (s) for Pose 1 (`.rest`, §2.2). (inference)
    public var restHoldS: Double
    /// Hold duration (s) for Pose 3 (`.overhead`, §2.2). (inference)
    public var overheadHoldS: Double
    /// Min `(nose.y - wrist.y) / span` for Pose 3 (`.overhead`, §2.2).
    public var overheadMinWristAboveNose: Double
    /// Top-edge clipping guard (`y >= overheadMinTopMarginY`) for raised wrists in `.overhead` (§2.2). (inference)
    public var overheadMinTopMarginY: Double
    /// Min interior elbow extension angle (deg) in Pose 3 (`.overhead`, §2.2). (inference)
    public var overheadMinElbowDeg: Double
    /// Hold duration (s) for Pose 4 (`.asymLR`, §2.2). (inference)
    public var asymHoldS: Double
    /// Min horizontal right-wrist reach in shoulder widths in Pose 4 (`.asymLR`, §2.2). (inference)
    public var asymMinSideReachShoulders: Double
    /// Hold duration (s) for Pose 5 (`.armsForward`, §2.2). (inference)
    public var forwardHoldS: Double
    /// Min canonical & LiDAR shoulder-to-wrist forward Z delta (m) in Pose 5 (`.armsForward`, §2.2). (inference)
    public var forwardMinDeltaZM: Double
    /// Hold duration (s) for Pose 6 (`.plie`, §2.2). (inference)
    public var plieHoldS: Double
    /// Min exterior `mean_knee_flex` (deg) in Pose 6 (`.plie`, §2.2). (inference)
    public var plieMinKneeFlexDeg: Double
    /// Min `hip_height_norm` drop below `.rest` in Pose 6 (`.plie`, §2.2). (inference)
    public var plieMinHipDropNorm: Double
    /// Hold duration (s) for Pose 7 (`.turned45`, §2.2). (inference)
    public var turnedHoldS: Double
    /// Min 3D shoulder XZ yaw angle (deg) in Pose 7 (`.turned45`, §2.2). (inference)
    public var turnedMinYawDeg: Double
    /// Max 3D shoulder XZ yaw angle (deg) before profile occlusion in Pose 7 (`.turned45`, §2.2). (inference)
    public var turnedMaxYawDeg: Double
    /// Edge-on 2D shoulder-collapse floor `|ls.x - rs.x|` (`checkup.ts:151`, §2.2).
    public var turnedMinShoulderWidth2D: Double
    /// Hold duration (s) per lateral step side (`.stepLeft`, `.stepRight`, §2.2). (inference)
    public var stepHoldS: Double
    /// Min normalized horizontal hip shift from `.rest` center in Pose 8 (`stepLR`, §2.2). (inference)
    public var stepMinHipShiftX: Double
    /// Dropout tolerance (s) during lateral step weight transfer in Pose 8 (`stepLR`, §2.2). (inference)
    public var stepDropoutS: Double
    /// Hold duration (s) for Pose 9 (`.kneeLift`, §2.2). (inference)
    public var kneeLiftHoldS: Double
    /// Min lifted-leg exterior `knee_flex` (deg) in Pose 9 (`.kneeLift`, §2.2). (inference)
    public var kneeLiftMinFlexDeg: Double
    /// Min `|la3D.y - ra3D.y| / legScale` in Pose 9 (`.kneeLift`, §2.2). (inference)
    public var kneeLiftMinAnkleClearance: Double
    /// Relaxed stillness stay limit for single-leg balance in Pose 9 (`.kneeLift`, §2.2). (inference)
    public var kneeLiftMotionStayMax: Double
    /// Dropout tolerance (s) for Pose 9 (`.kneeLift`, §2.2). (inference)
    public var kneeLiftDropoutS: Double

    /// The report's and v2 plan's numbers.
    public static let defaults = CalibrationTuning(
        resumeGravityDeltaG: 0.05,
        rollEnterDeg: 3.0,
        rollExitDeg: 5.0,
        tiltBackMinDeg: -5.0,
        tiltBackMaxDeg: 20.0,
        stillAccelMaxG: 0.03,
        stillRotationMaxRadS: 0.08,
        phoneStillHoldS: 0.5,
        bumpGravityDeltaG: 0.05,
        presenceMinVisibility: 0.5,
        coreMinVisibility: 0.6,
        footMinVisibility: 0.5,
        safeBoxMinX: 0.05,
        safeBoxMaxX: 0.95,
        maxFootY: 0.95,
        minNoseY: 0.20,
        spanMin: 0.45,
        spanMax: 0.75,
        hipCenterMinX: 0.30,
        hipCenterMaxX: 0.70,
        framingHoldS: 0.4,
        framingStayVisibilityDelta: 0.1,
        framingStaySpanDelta: 0.05,
        relaxAfterS: 15.0,
        relaxVisibilityDelta: 0.1,
        relaxSpanDelta: 0.05,
        dimLumaMax: 0.22,
        dimExposureMinS: 0.033,
        dimISOMin: 450,
        dimISORatioMin: 0.8,
        backlightDeltaMin: 0.35,
        backlightTorsoLumaMax: 0.25,
        veryDarkLumaMax: 0.10,
        tPoseMinScore: 0.55,
        tPoseMinSY: 0.3,
        tPoseMinSAng: 0.3,
        tPoseMinExtension: -0.15,
        tPoseArmMinVisibility: 0.3,
        motionEnterMax: 0.012,
        motionStayMax: 0.02,
        poseHoldS: 1.0,
        dropoutToleranceS: 0.35,
        minCapturedFrames: 15,
        spanMinFloor: 0.22,
        noseToFootHeightRatio: 0.855,
        spanDepthToleranceRatio: 0.22,
        lidarMinDistanceM: 2.0,
        lidarMaxDistanceM: 4.0,
        lidarDistanceStayDeltaM: 0.25,
        lidarDistanceRelaxDeltaM: 0.30,
        lateralStepMarginM: 0.55,
        restHipCenterMinX: 0.40,
        restHipCenterMaxX: 0.60,
        resumeFloorHeightDeltaM: 0.03,
        resumeFloorAngleDeg: 3.0,
        sameDancerHeightDeltaM: 0.06,
        cameraHeightMinM: 0.50,
        cameraHeightMaxM: 1.50,
        exposureMaxShutterS: 0.0167,
        remeterLumaDelta: 0.20,
        restHoldS: 0.6,
        overheadHoldS: 0.7,
        overheadMinWristAboveNose: 0.05,
        overheadMinTopMarginY: 0.02,
        overheadMinElbowDeg: 135.0,
        asymHoldS: 0.7,
        asymMinSideReachShoulders: 0.80,
        forwardHoldS: 0.7,
        forwardMinDeltaZM: 0.25,
        plieHoldS: 0.8,
        plieMinKneeFlexDeg: 22.0,
        plieMinHipDropNorm: 0.04,
        turnedHoldS: 0.7,
        turnedMinYawDeg: 25.0,
        turnedMaxYawDeg: 65.0,
        turnedMinShoulderWidth2D: 0.045,
        stepHoldS: 0.5,
        stepMinHipShiftX: 0.12,
        stepDropoutS: 0.40,
        kneeLiftHoldS: 0.5,
        kneeLiftMinFlexDeg: 55.0,
        kneeLiftMinAnkleClearance: 0.18,
        kneeLiftMotionStayMax: 0.035,
        kneeLiftDropoutS: 0.45
    )

    public init(
        resumeGravityDeltaG: Double,
        rollEnterDeg: Double,
        rollExitDeg: Double,
        tiltBackMinDeg: Double,
        tiltBackMaxDeg: Double,
        stillAccelMaxG: Double,
        stillRotationMaxRadS: Double,
        phoneStillHoldS: Double,
        bumpGravityDeltaG: Double,
        presenceMinVisibility: Double,
        coreMinVisibility: Double,
        footMinVisibility: Double,
        safeBoxMinX: Double,
        safeBoxMaxX: Double,
        maxFootY: Double,
        minNoseY: Double,
        spanMin: Double,
        spanMax: Double,
        hipCenterMinX: Double,
        hipCenterMaxX: Double,
        framingHoldS: Double,
        framingStayVisibilityDelta: Double,
        framingStaySpanDelta: Double,
        relaxAfterS: Double,
        relaxVisibilityDelta: Double,
        relaxSpanDelta: Double,
        dimLumaMax: Double,
        dimExposureMinS: Double,
        dimISOMin: Double,
        dimISORatioMin: Double,
        backlightDeltaMin: Double,
        backlightTorsoLumaMax: Double,
        veryDarkLumaMax: Double,
        tPoseMinScore: Double,
        tPoseMinSY: Double,
        tPoseMinSAng: Double,
        tPoseMinExtension: Double,
        tPoseArmMinVisibility: Double,
        motionEnterMax: Double,
        motionStayMax: Double,
        poseHoldS: Double,
        dropoutToleranceS: Double,
        minCapturedFrames: Int,
        spanMinFloor: Double = 0.22,
        noseToFootHeightRatio: Double = 0.855,
        spanDepthToleranceRatio: Double = 0.22,
        lidarMinDistanceM: Double = 2.0,
        lidarMaxDistanceM: Double = 4.0,
        lidarDistanceStayDeltaM: Double = 0.25,
        lidarDistanceRelaxDeltaM: Double = 0.30,
        lateralStepMarginM: Double = 0.55,
        restHipCenterMinX: Double = 0.40,
        restHipCenterMaxX: Double = 0.60,
        resumeFloorHeightDeltaM: Double = 0.03,
        resumeFloorAngleDeg: Double = 3.0,
        sameDancerHeightDeltaM: Double = 0.06,
        cameraHeightMinM: Double = 0.50,
        cameraHeightMaxM: Double = 1.50,
        exposureMaxShutterS: Double = 0.0167,
        remeterLumaDelta: Double = 0.20,
        restHoldS: Double = 0.6,
        overheadHoldS: Double = 0.7,
        overheadMinWristAboveNose: Double = 0.05,
        overheadMinTopMarginY: Double = 0.02,
        overheadMinElbowDeg: Double = 135.0,
        asymHoldS: Double = 0.7,
        asymMinSideReachShoulders: Double = 0.80,
        forwardHoldS: Double = 0.7,
        forwardMinDeltaZM: Double = 0.25,
        plieHoldS: Double = 0.8,
        plieMinKneeFlexDeg: Double = 22.0,
        plieMinHipDropNorm: Double = 0.04,
        turnedHoldS: Double = 0.7,
        turnedMinYawDeg: Double = 25.0,
        turnedMaxYawDeg: Double = 65.0,
        turnedMinShoulderWidth2D: Double = 0.045,
        stepHoldS: Double = 0.5,
        stepMinHipShiftX: Double = 0.12,
        stepDropoutS: Double = 0.40,
        kneeLiftHoldS: Double = 0.5,
        kneeLiftMinFlexDeg: Double = 55.0,
        kneeLiftMinAnkleClearance: Double = 0.18,
        kneeLiftMotionStayMax: Double = 0.035,
        kneeLiftDropoutS: Double = 0.45
    ) {
        self.resumeGravityDeltaG = resumeGravityDeltaG
        self.rollEnterDeg = rollEnterDeg
        self.rollExitDeg = rollExitDeg
        self.tiltBackMinDeg = tiltBackMinDeg
        self.tiltBackMaxDeg = tiltBackMaxDeg
        self.stillAccelMaxG = stillAccelMaxG
        self.stillRotationMaxRadS = stillRotationMaxRadS
        self.phoneStillHoldS = phoneStillHoldS
        self.bumpGravityDeltaG = bumpGravityDeltaG
        self.presenceMinVisibility = presenceMinVisibility
        self.coreMinVisibility = coreMinVisibility
        self.footMinVisibility = footMinVisibility
        self.safeBoxMinX = safeBoxMinX
        self.safeBoxMaxX = safeBoxMaxX
        self.maxFootY = maxFootY
        self.minNoseY = minNoseY
        self.spanMin = spanMin
        self.spanMax = spanMax
        self.hipCenterMinX = hipCenterMinX
        self.hipCenterMaxX = hipCenterMaxX
        self.framingHoldS = framingHoldS
        self.framingStayVisibilityDelta = framingStayVisibilityDelta
        self.framingStaySpanDelta = framingStaySpanDelta
        self.relaxAfterS = relaxAfterS
        self.relaxVisibilityDelta = relaxVisibilityDelta
        self.relaxSpanDelta = relaxSpanDelta
        self.dimLumaMax = dimLumaMax
        self.dimExposureMinS = dimExposureMinS
        self.dimISOMin = dimISOMin
        self.dimISORatioMin = dimISORatioMin
        self.backlightDeltaMin = backlightDeltaMin
        self.backlightTorsoLumaMax = backlightTorsoLumaMax
        self.veryDarkLumaMax = veryDarkLumaMax
        self.tPoseMinScore = tPoseMinScore
        self.tPoseMinSY = tPoseMinSY
        self.tPoseMinSAng = tPoseMinSAng
        self.tPoseMinExtension = tPoseMinExtension
        self.tPoseArmMinVisibility = tPoseArmMinVisibility
        self.motionEnterMax = motionEnterMax
        self.motionStayMax = motionStayMax
        self.poseHoldS = poseHoldS
        self.dropoutToleranceS = dropoutToleranceS
        self.minCapturedFrames = minCapturedFrames
        self.spanMinFloor = spanMinFloor
        self.noseToFootHeightRatio = noseToFootHeightRatio
        self.spanDepthToleranceRatio = spanDepthToleranceRatio
        self.lidarMinDistanceM = lidarMinDistanceM
        self.lidarMaxDistanceM = lidarMaxDistanceM
        self.lidarDistanceStayDeltaM = lidarDistanceStayDeltaM
        self.lidarDistanceRelaxDeltaM = lidarDistanceRelaxDeltaM
        self.lateralStepMarginM = lateralStepMarginM
        self.restHipCenterMinX = restHipCenterMinX
        self.restHipCenterMaxX = restHipCenterMaxX
        self.resumeFloorHeightDeltaM = resumeFloorHeightDeltaM
        self.resumeFloorAngleDeg = resumeFloorAngleDeg
        self.sameDancerHeightDeltaM = sameDancerHeightDeltaM
        self.cameraHeightMinM = cameraHeightMinM
        self.cameraHeightMaxM = cameraHeightMaxM
        self.exposureMaxShutterS = exposureMaxShutterS
        self.remeterLumaDelta = remeterLumaDelta
        self.restHoldS = restHoldS
        self.overheadHoldS = overheadHoldS
        self.overheadMinWristAboveNose = overheadMinWristAboveNose
        self.overheadMinTopMarginY = overheadMinTopMarginY
        self.overheadMinElbowDeg = overheadMinElbowDeg
        self.asymHoldS = asymHoldS
        self.asymMinSideReachShoulders = asymMinSideReachShoulders
        self.forwardHoldS = forwardHoldS
        self.forwardMinDeltaZM = forwardMinDeltaZM
        self.plieHoldS = plieHoldS
        self.plieMinKneeFlexDeg = plieMinKneeFlexDeg
        self.plieMinHipDropNorm = plieMinHipDropNorm
        self.turnedHoldS = turnedHoldS
        self.turnedMinYawDeg = turnedMinYawDeg
        self.turnedMaxYawDeg = turnedMaxYawDeg
        self.turnedMinShoulderWidth2D = turnedMinShoulderWidth2D
        self.stepHoldS = stepHoldS
        self.stepMinHipShiftX = stepMinHipShiftX
        self.stepDropoutS = stepDropoutS
        self.kneeLiftHoldS = kneeLiftHoldS
        self.kneeLiftMinFlexDeg = kneeLiftMinFlexDeg
        self.kneeLiftMinAnkleClearance = kneeLiftMinAnkleClearance
        self.kneeLiftMotionStayMax = kneeLiftMotionStayMax
        self.kneeLiftDropoutS = kneeLiftDropoutS
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case resumeGravityDeltaG
        case rollEnterDeg, rollExitDeg, tiltBackMinDeg, tiltBackMaxDeg
        case stillAccelMaxG, stillRotationMaxRadS, phoneStillHoldS, bumpGravityDeltaG
        case presenceMinVisibility, coreMinVisibility, footMinVisibility
        case safeBoxMinX, safeBoxMaxX, maxFootY, minNoseY, spanMin, spanMax, hipCenterMinX, hipCenterMaxX
        case framingHoldS, framingStayVisibilityDelta, framingStaySpanDelta
        case relaxAfterS, relaxVisibilityDelta, relaxSpanDelta
        case dimLumaMax, dimExposureMinS, dimISOMin, dimISORatioMin
        case backlightDeltaMin, backlightTorsoLumaMax, veryDarkLumaMax
        case tPoseMinScore, tPoseMinSY, tPoseMinSAng, tPoseMinExtension, tPoseArmMinVisibility
        case motionEnterMax, motionStayMax, poseHoldS, dropoutToleranceS, minCapturedFrames
        case spanMinFloor, noseToFootHeightRatio, spanDepthToleranceRatio
        case lidarMinDistanceM, lidarMaxDistanceM, lidarDistanceStayDeltaM, lidarDistanceRelaxDeltaM
        case lateralStepMarginM, restHipCenterMinX, restHipCenterMaxX
        case resumeFloorHeightDeltaM, resumeFloorAngleDeg, sameDancerHeightDeltaM
        case cameraHeightMinM, cameraHeightMaxM, exposureMaxShutterS, remeterLumaDelta
        case restHoldS
        case overheadHoldS, overheadMinWristAboveNose, overheadMinTopMarginY, overheadMinElbowDeg
        case asymHoldS, asymMinSideReachShoulders
        case forwardHoldS, forwardMinDeltaZM
        case plieHoldS, plieMinKneeFlexDeg, plieMinHipDropNorm
        case turnedHoldS, turnedMinYawDeg, turnedMaxYawDeg, turnedMinShoulderWidth2D
        case stepHoldS, stepMinHipShiftX, stepDropoutS
        case kneeLiftHoldS, kneeLiftMinFlexDeg, kneeLiftMinAnkleClearance, kneeLiftMotionStayMax, kneeLiftDropoutS
    }

    /// `JSONDecoder.userInfo` key holding the `CalibrationTuning` that missing keys fall back to (default:
    /// `.defaults`). `merged(withJSON:)` sets it.
    public static let baseUserInfoKey = CodingUserInfoKey(rawValue: "groove.calibrationTuning.base")!

    public init(from decoder: Decoder) throws {
        let base = (decoder.userInfo[Self.baseUserInfoKey] as? CalibrationTuning) ?? .defaults
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            try c.decodeIfPresent(Double.self, forKey: key) ?? fallback
        }
        resumeGravityDeltaG = try d(.resumeGravityDeltaG, base.resumeGravityDeltaG)
        rollEnterDeg = try d(.rollEnterDeg, base.rollEnterDeg)
        rollExitDeg = try d(.rollExitDeg, base.rollExitDeg)
        tiltBackMinDeg = try d(.tiltBackMinDeg, base.tiltBackMinDeg)
        tiltBackMaxDeg = try d(.tiltBackMaxDeg, base.tiltBackMaxDeg)
        stillAccelMaxG = try d(.stillAccelMaxG, base.stillAccelMaxG)
        stillRotationMaxRadS = try d(.stillRotationMaxRadS, base.stillRotationMaxRadS)
        phoneStillHoldS = try d(.phoneStillHoldS, base.phoneStillHoldS)
        bumpGravityDeltaG = try d(.bumpGravityDeltaG, base.bumpGravityDeltaG)
        presenceMinVisibility = try d(.presenceMinVisibility, base.presenceMinVisibility)
        coreMinVisibility = try d(.coreMinVisibility, base.coreMinVisibility)
        footMinVisibility = try d(.footMinVisibility, base.footMinVisibility)
        safeBoxMinX = try d(.safeBoxMinX, base.safeBoxMinX)
        safeBoxMaxX = try d(.safeBoxMaxX, base.safeBoxMaxX)
        maxFootY = try d(.maxFootY, base.maxFootY)
        minNoseY = try d(.minNoseY, base.minNoseY)
        spanMin = try d(.spanMin, base.spanMin)
        spanMax = try d(.spanMax, base.spanMax)
        hipCenterMinX = try d(.hipCenterMinX, base.hipCenterMinX)
        hipCenterMaxX = try d(.hipCenterMaxX, base.hipCenterMaxX)
        framingHoldS = try d(.framingHoldS, base.framingHoldS)
        framingStayVisibilityDelta = try d(.framingStayVisibilityDelta, base.framingStayVisibilityDelta)
        framingStaySpanDelta = try d(.framingStaySpanDelta, base.framingStaySpanDelta)
        relaxAfterS = try d(.relaxAfterS, base.relaxAfterS)
        relaxVisibilityDelta = try d(.relaxVisibilityDelta, base.relaxVisibilityDelta)
        relaxSpanDelta = try d(.relaxSpanDelta, base.relaxSpanDelta)
        dimLumaMax = try d(.dimLumaMax, base.dimLumaMax)
        dimExposureMinS = try d(.dimExposureMinS, base.dimExposureMinS)
        dimISOMin = try d(.dimISOMin, base.dimISOMin)
        dimISORatioMin = try d(.dimISORatioMin, base.dimISORatioMin)
        backlightDeltaMin = try d(.backlightDeltaMin, base.backlightDeltaMin)
        backlightTorsoLumaMax = try d(.backlightTorsoLumaMax, base.backlightTorsoLumaMax)
        veryDarkLumaMax = try d(.veryDarkLumaMax, base.veryDarkLumaMax)
        tPoseMinScore = try d(.tPoseMinScore, base.tPoseMinScore)
        tPoseMinSY = try d(.tPoseMinSY, base.tPoseMinSY)
        tPoseMinSAng = try d(.tPoseMinSAng, base.tPoseMinSAng)
        tPoseMinExtension = try d(.tPoseMinExtension, base.tPoseMinExtension)
        tPoseArmMinVisibility = try d(.tPoseArmMinVisibility, base.tPoseArmMinVisibility)
        motionEnterMax = try d(.motionEnterMax, base.motionEnterMax)
        motionStayMax = try d(.motionStayMax, base.motionStayMax)
        poseHoldS = try d(.poseHoldS, base.poseHoldS)
        dropoutToleranceS = try d(.dropoutToleranceS, base.dropoutToleranceS)
        // Accept 15 or 15.0 from hand-edited JSON.
        if let n = try? c.decodeIfPresent(Int.self, forKey: .minCapturedFrames) {
            minCapturedFrames = n
        } else if let v = try c.decodeIfPresent(Double.self, forKey: .minCapturedFrames) {
            guard v.isFinite, v >= 0, v == v.rounded() else {
                throw DecodingError.dataCorruptedError(forKey: .minCapturedFrames, in: c,
                                                       debugDescription: "minCapturedFrames must be a whole number")
            }
            minCapturedFrames = Int(v)
        } else {
            minCapturedFrames = base.minCapturedFrames
        }
        spanMinFloor = try d(.spanMinFloor, base.spanMinFloor)
        noseToFootHeightRatio = try d(.noseToFootHeightRatio, base.noseToFootHeightRatio)
        spanDepthToleranceRatio = try d(.spanDepthToleranceRatio, base.spanDepthToleranceRatio)
        lidarMinDistanceM = try d(.lidarMinDistanceM, base.lidarMinDistanceM)
        lidarMaxDistanceM = try d(.lidarMaxDistanceM, base.lidarMaxDistanceM)
        lidarDistanceStayDeltaM = try d(.lidarDistanceStayDeltaM, base.lidarDistanceStayDeltaM)
        lidarDistanceRelaxDeltaM = try d(.lidarDistanceRelaxDeltaM, base.lidarDistanceRelaxDeltaM)
        lateralStepMarginM = try d(.lateralStepMarginM, base.lateralStepMarginM)
        restHipCenterMinX = try d(.restHipCenterMinX, base.restHipCenterMinX)
        restHipCenterMaxX = try d(.restHipCenterMaxX, base.restHipCenterMaxX)
        resumeFloorHeightDeltaM = try d(.resumeFloorHeightDeltaM, base.resumeFloorHeightDeltaM)
        resumeFloorAngleDeg = try d(.resumeFloorAngleDeg, base.resumeFloorAngleDeg)
        sameDancerHeightDeltaM = try d(.sameDancerHeightDeltaM, base.sameDancerHeightDeltaM)
        cameraHeightMinM = try d(.cameraHeightMinM, base.cameraHeightMinM)
        cameraHeightMaxM = try d(.cameraHeightMaxM, base.cameraHeightMaxM)
        exposureMaxShutterS = try d(.exposureMaxShutterS, base.exposureMaxShutterS)
        remeterLumaDelta = try d(.remeterLumaDelta, base.remeterLumaDelta)
        restHoldS = try d(.restHoldS, base.restHoldS)
        overheadHoldS = try d(.overheadHoldS, base.overheadHoldS)
        overheadMinWristAboveNose = try d(.overheadMinWristAboveNose, base.overheadMinWristAboveNose)
        overheadMinTopMarginY = try d(.overheadMinTopMarginY, base.overheadMinTopMarginY)
        overheadMinElbowDeg = try d(.overheadMinElbowDeg, base.overheadMinElbowDeg)
        asymHoldS = try d(.asymHoldS, base.asymHoldS)
        asymMinSideReachShoulders = try d(.asymMinSideReachShoulders, base.asymMinSideReachShoulders)
        forwardHoldS = try d(.forwardHoldS, base.forwardHoldS)
        forwardMinDeltaZM = try d(.forwardMinDeltaZM, base.forwardMinDeltaZM)
        plieHoldS = try d(.plieHoldS, base.plieHoldS)
        plieMinKneeFlexDeg = try d(.plieMinKneeFlexDeg, base.plieMinKneeFlexDeg)
        plieMinHipDropNorm = try d(.plieMinHipDropNorm, base.plieMinHipDropNorm)
        turnedHoldS = try d(.turnedHoldS, base.turnedHoldS)
        turnedMinYawDeg = try d(.turnedMinYawDeg, base.turnedMinYawDeg)
        turnedMaxYawDeg = try d(.turnedMaxYawDeg, base.turnedMaxYawDeg)
        turnedMinShoulderWidth2D = try d(.turnedMinShoulderWidth2D, base.turnedMinShoulderWidth2D)
        stepHoldS = try d(.stepHoldS, base.stepHoldS)
        stepMinHipShiftX = try d(.stepMinHipShiftX, base.stepMinHipShiftX)
        stepDropoutS = try d(.stepDropoutS, base.stepDropoutS)
        kneeLiftHoldS = try d(.kneeLiftHoldS, base.kneeLiftHoldS)
        kneeLiftMinFlexDeg = try d(.kneeLiftMinFlexDeg, base.kneeLiftMinFlexDeg)
        kneeLiftMinAnkleClearance = try d(.kneeLiftMinAnkleClearance, base.kneeLiftMinAnkleClearance)
        kneeLiftMotionStayMax = try d(.kneeLiftMotionStayMax, base.kneeLiftMotionStayMax)
        kneeLiftDropoutS = try d(.kneeLiftDropoutS, base.kneeLiftDropoutS)
    }

    /// `self` with every key present in `json` (a JSON object) overriding its value; missing keys keep `self`'s.
    public func merged(withJSON json: Data) throws -> CalibrationTuning {
        let decoder = JSONDecoder()
        decoder.userInfo[Self.baseUserInfoKey] = self
        return try decoder.decode(CalibrationTuning.self, from: json)
    }
}
