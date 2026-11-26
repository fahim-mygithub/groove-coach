import Foundation

// Pre-dance & studio calibration v2 (app-only; Foundation-only so `swift test` runs on Linux CI).
// Specs:
// - docs/research/2026-11-18-calibration-research.md
// - docs/specs/2026-11-26-calibration-v2-plan.md (§1.2, §2, §3, §6, §7, §9)
//
// Steps:
//   resume (0) -> level (1) -> rest (2) -> [lighting advice is 3, never blocking] ->
//   tpose (4) -> overhead (5) -> asymLR (6) -> armsForward (7) -> plie (8) ->
//   turned45 (9) -> stepLeft (10) -> stepRight (11) -> kneeLift (12) -> locked (13).
//
// Three-tier re-calibration policy (§6.2):
// - Tier 0: instant in-session resume (`resume (0) -> rest (2) [0.4 s] -> locked (13)`).
// - Tier 1: environment re-calibration (`level (1) -> rest (2) [0.6 s] -> same-dancer check -> locked (13)`).
// - Tier 2: full 9-pose body + studio calibration (`level (1) -> Poses 1–9 -> locked (13)`).
//
// Landmarks are MediaPipe normalised image coordinates of the UN-mirrored portrait buffer (x right, y down).
// MediaPipe's left/right are the dancer's own anatomical sides (dancer's left is at raw x > 0.5).

// MARK: - Inputs

public struct CalibrationVector3: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public var norm: Double { (x * x + y * y + z * z).squareRoot() }
    public var array: [Double] { [x, y, z] }

    public func distance(to o: CalibrationVector3) -> Double {
        CalibrationVector3(x: x - o.x, y: y - o.y, z: z - o.z).norm
    }

    /// `[x, y, z]`; missing components are 0.
    public init(_ a: [Double]) {
        self.init(x: a.count > 0 ? a[0] : 0, y: a.count > 1 ? a[1] : 0, z: a.count > 2 ? a[2] : 0)
    }
}

/// One `CMDeviceMotion` reading, in the device frame.
public struct CalibrationMotionSample: Codable, Equatable, Sendable {
    /// Seconds (any monotonic clock, e.g. `CMDeviceMotion.timestamp`).
    public var timestamp: Double
    /// `CMDeviceMotion.gravity` (g). Upright portrait is about (0, -1, 0); +z points out of the front screen.
    public var gravity: CalibrationVector3
    /// `CMDeviceMotion.userAcceleration` (g).
    public var userAcceleration: CalibrationVector3
    /// `CMDeviceMotion.rotationRate` (rad/s).
    public var rotationRate: CalibrationVector3

    public init(timestamp: Double, gravity: CalibrationVector3,
                userAcceleration: CalibrationVector3 = CalibrationVector3(x: 0, y: 0, z: 0),
                rotationRate: CalibrationVector3 = CalibrationVector3(x: 0, y: 0, z: 0)) {
        self.timestamp = timestamp
        self.gravity = gravity
        self.userAcceleration = userAcceleration
        self.rotationRate = rotationRate
    }
}

/// One normalised MediaPipe pose landmark.
public struct CalibrationLandmark: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var visibility: Double

    public init(x: Double, y: Double, visibility: Double) {
        self.x = x
        self.y = y
        self.visibility = visibility
    }
}

/// One live pose result.
public struct CalibrationPoseSample: Sendable {
    /// Seconds (the live analysis clock).
    public var timestamp: Double
    /// The 33 MediaPipe PoseLandmarker points in index order. Missing indices count as not visible.
    public var landmarks: [CalibrationLandmark]
    /// The canonical frame for this sample (the live `RawPoseFrame`); captured into `calibration_frames`.
    public var frame: GrooveScoringEngine.RawPoseFrame?

    public init(timestamp: Double, landmarks: [CalibrationLandmark], frame: GrooveScoringEngine.RawPoseFrame? = nil) {
        self.timestamp = timestamp
        self.landmarks = landmarks
        self.frame = frame
    }

    /// Builds the 33-point array from named points (`CanonicalSkeleton.mediapipeIndex` names, e.g. the app's
    /// `latestNormalizedLandmarks` plus `RawPoseFrame.confidences`). Unnamed indices get visibility 0.
    public init(timestamp: Double, named: [String: CalibrationLandmark],
                frame: GrooveScoringEngine.RawPoseFrame? = nil) {
        var pts = Array(repeating: CalibrationLandmark(x: 0, y: 0, visibility: 0),
                        count: CanonicalSkeleton.poseLandmarkCount)
        for (name, p) in named {
            if let i = CanonicalSkeleton.mediapipeIndex[name] { pts[i] = p }
        }
        self.init(timestamp: timestamp, landmarks: pts, frame: frame)
    }
}

/// One light reading (sampled at about 2 Hz). Luma values are 0...1.
public struct CalibrationLightSample: Codable, Equatable, Sendable {
    public var meanLuma: Double
    /// Mean luma inside the torso box; nil without a person.
    public var torsoLuma: Double?
    /// Mean luma along the image border; nil if not sampled.
    public var borderLuma: Double?
    /// `AVCaptureDevice.iso` and `activeFormat.maxISO` (0 if unknown).
    public var iso: Double
    public var maxISO: Double
    /// `AVCaptureDevice.exposureDuration` in seconds.
    public var exposureSeconds: Double
    /// Whether AE/AWB is currently locked on the capture device (§3.3, §7.1); nil if unknown.
    public var exposureLocked: Bool?

    public init(meanLuma: Double, torsoLuma: Double? = nil, borderLuma: Double? = nil,
                iso: Double = 0, maxISO: Double = 0, exposureSeconds: Double = 0,
                exposureLocked: Bool? = nil) {
        self.meanLuma = meanLuma
        self.torsoLuma = torsoLuma
        self.borderLuma = borderLuma
        self.iso = iso
        self.maxISO = maxISO
        self.exposureSeconds = exposureSeconds
        self.exposureLocked = exposureLocked
    }
}

// MARK: - Outputs

public enum CalibrationStep: Int, Codable, Sendable, CaseIterable {
    case resume = 0
    case level = 1
    case rest = 2
    // 3 is lighting: advice alongside steps 1+, never a blocking step.
    case tpose = 4
    case overhead = 5
    case asymLR = 6
    case armsForward = 7
    case plie = 8
    case turned45 = 9
    case stepLeft = 10
    case stepRight = 11
    case kneeLift = 12
    case locked = 13

    /// Source-compatibility alias for v1 callers/tests (`frame = 2` renamed to `rest = 2`, §7.1).
    public static var frame: CalibrationStep { .rest }

    public var name: String {
        switch self {
        case .resume: return "resume"
        case .level: return "level"
        case .rest: return "rest"
        case .tpose: return "tpose"
        case .overhead: return "overhead"
        case .asymLR: return "asymLR"
        case .armsForward: return "armsForward"
        case .plie: return "plie"
        case .turned45: return "turned45"
        case .stepLeft: return "stepLeft"
        case .stepRight: return "stepRight"
        case .kneeLift: return "kneeLift"
        case .locked: return "locked"
        }
    }

    public var poseKind: CalibrationPoseScorers.PoseKind? {
        switch self {
        case .rest: return .rest
        case .tpose: return .tpose
        case .overhead: return .overhead
        case .asymLR: return .asymLR
        case .armsForward: return .armsForward
        case .plie: return .plie
        case .turned45: return .turned45
        case .stepLeft: return .stepLeft
        case .stepRight: return .stepRight
        case .kneeLift: return .kneeLift
        case .resume, .level, .locked: return nil
        }
    }

    public init(poseKind: CalibrationPoseScorers.PoseKind) {
        switch poseKind {
        case .rest: self = .rest
        case .tpose: self = .tpose
        case .overhead: self = .overhead
        case .asymLR: self = .asymLR
        case .armsForward: self = .armsForward
        case .plie: self = .plie
        case .turned45: self = .turned45
        case .stepLeft: self = .stepLeft
        case .stepRight: self = .stepRight
        case .kneeLift: self = .kneeLift
        }
    }
}

/// Spoken / visual instructions across placement, framing, LiDAR distance, lighting advice, and Poses 1–9 (§2.2, §3.5).
/// Left and right are the dancer's own anatomical sides (matching the mirrored preview).
public enum CalibrationCue: String, Codable, Sendable, CaseIterable {
    case none
    // Step 1 - phone placement & level
    case placePhone
    case levelPhone
    case tiltLessBack
    case tiltLessForward
    case setPhoneDown
    // Step 2 - framing & LiDAR distance
    case stepIn
    case stepBackDistance
    case stepCloserDistance
    case stepBackShowFeet
    case showHead
    case stepBack
    case stepCloser
    case moveLeft
    case moveRight
    // Step 3 - non-blocking lighting & camera-height advice
    case dimLight
    case backlit
    case veryDark
    /// Static scene advice for the overlay; the gate never emits it as blocking `cue`.
    case sceneTips
    case cameraTooLow
    case cameraTooHigh
    // Poses 1–9 entry & diagnostic cues
    case relaxArms
    case armsOutT
    case reachOverhead
    case stepBackHeadroom
    case asymPose
    case swapArmsLR
    case armsForward
    case bendKneesDeeper
    case turnBody45
    case turnLessSideways
    case stepLeft
    case stepRight
    case stepBackLateralRoom
    case liftKnee
    case holdStill
    // Step 13 - terminal lock
    case locked

    public var spokenText: String {
        spokenText(dancerDistanceM: nil, effectiveMinDistanceM: nil)
    }

    /// Formats spoken instruction, substituting dynamic `dancerDistanceM` and `effectiveMinDistanceM` (`ceil(d*2)/2`)
    /// when `.stepBackDistance` is active (§3.2, §3.5).
    public func spokenText(dancerDistanceM: Double?, effectiveMinDistanceM: Double?) -> String {
        switch self {
        case .none:
            return ""
        case .placePhone:
            return "Stand your phone up about waist high, facing you."
        case .levelPhone:
            return "Level the phone."
        case .tiltLessBack:
            return "Tilt it back a little less."
        case .tiltLessForward:
            return "Tilt the top of the phone back a little."
        case .setPhoneDown:
            return "Set it down so it's still."
        case .stepIn:
            return "Step in front of the camera."
        case .stepBackDistance:
            let targetM = CalibrationPoseScorers.spokenTargetMinDistanceM(
                for: effectiveMinDistanceM ?? 3.0
            )
            let targetStr = String(format: "%.1f", targetM)
            if let current = dancerDistanceM, current.isFinite, current > 0 {
                let curStr = String(format: "%.1f", current)
                return "You're at \(curStr) meters—step back to about \(targetStr) meters so your arms and steps fit in frame."
            }
            return "Step back to about \(targetStr) meters so your arms and steps fit in frame."
        case .stepCloserDistance:
            return "You're over 4 meters away—step a little closer."
        case .stepBackShowFeet:
            return "Step back so your feet are in view."
        case .showHead:
            return "Step back so your head is in view."
        case .stepBack:
            return "Step back."
        case .stepCloser:
            return "Step a little closer."
        case .moveLeft:
            return "Move to your left."
        case .moveRight:
            return "Move to your right."
        case .dimLight:
            return "Dim light. Turn on a light in front of you for sharper feet and hands."
        case .backlit:
            return "Bright light behind you. Face the light."
        case .veryDark:
            return "Camera is very dark. Check the lens or turn on a light."
        case .sceneTips:
            return "Avoid mirrors and colour-changing lights, and wear clothes that stand out from the wall."
        case .cameraTooLow:
            return "Phone is low—raising it to waist or table height around 50 to 70 centimeters improves foot tracking."
        case .cameraTooHigh:
            return "Phone is high—lowering it closer to waist or chest height improves foot tracking."
        case .relaxArms:
            return "Stand centered in the box, feet visible, arms relaxed by your sides."
        case .armsOutT:
            return "Arms straight out to the sides, like a T. Hold still."
        case .reachOverhead:
            return "Reach both arms straight up overhead."
        case .stepBackHeadroom:
            return "Step back a little so your raised hands stay in frame."
        case .asymPose:
            return "Raise your left arm straight up, and stretch your right arm out to the side."
        case .swapArmsLR:
            return "Other side—raise your left arm up, right arm out."
        case .armsForward:
            return "Point both arms straight forward toward the camera."
        case .bendKneesDeeper:
            return "Bend your knees a little deeper, heels in view."
        case .turnBody45:
            return "Keep arms out and turn your whole body halfway to one side."
        case .turnLessSideways:
            return "Turn a little less sideways so both shoulders are visible."
        case .stepLeft:
            return "Take a wide dance step to your left and pause."
        case .stepRight:
            return "Now take a wide step to your right and pause."
        case .stepBackLateralRoom:
            return "Step back slightly for more side-to-side room."
        case .liftKnee:
            return "Lift one knee up toward hip height for a moment."
        case .holdStill:
            return "Hold still."
        case .locked:
            return "Locked in!"
        }
    }

    public init(poseCue: CalibrationPoseScorers.PoseCue) {
        switch poseCue {
        case .none: self = .none
        case .stepIn: self = .stepIn
        case .stepBackDistance: self = .stepBackDistance
        case .stepCloserDistance: self = .stepCloserDistance
        case .stepBackShowFeet: self = .stepBackShowFeet
        case .showHead: self = .showHead
        case .stepBack: self = .stepBack
        case .stepCloser: self = .stepCloser
        case .moveLeft: self = .moveLeft
        case .moveRight: self = .moveRight
        case .relaxArms: self = .relaxArms
        case .armsOutT: self = .armsOutT
        case .reachOverhead: self = .reachOverhead
        case .stepBackHeadroom: self = .stepBackHeadroom
        case .asymPose: self = .asymPose
        case .swapArmsLR: self = .swapArmsLR
        case .armsForward: self = .armsForward
        case .bendKneesDeeper: self = .bendKneesDeeper
        case .turnBody45: self = .turnBody45
        case .turnLessSideways: self = .turnLessSideways
        case .stepLeft: self = .stepLeft
        case .stepRight: self = .stepRight
        case .stepBackLateralRoom: self = .stepBackLateralRoom
        case .liftKnee: self = .liftKnee
        case .holdStill: self = .holdStill
        }
    }
}

public enum CalibrationLightAdvice: String, Codable, Sendable, CaseIterable {
    case ok, dim, backlit, veryDark

    public var cue: CalibrationCue {
        switch self {
        case .ok: return .none
        case .dim: return .dimLight
        case .backlit: return .backlit
        case .veryDark: return .veryDark
        }
    }
}

public struct CalibrationStatus: Equatable, Sendable {
    public var step: CalibrationStep
    /// The blocking step's instruction (`.none` while `.level` or `.rest` hold is filling).
    public var cue: CalibrationCue
    /// Hold progress of the current step, 0...1.
    public var progress: Double
    public var lightAdvice: CalibrationLightAdvice
    public var relaxed: Bool
    public var skipped: Bool
    /// Flips `true` when Pose 1 (`.rest`) completes so the camera controller locks AE/AWB (§3.3, §7.1);
    /// resets to `false` on `.level` reset.
    public var needsExposureLock: Bool
    /// Latest measured LiDAR torso distance (m) for dynamic spoken cue formatting.
    public var dancerDistanceM: Double?
    /// Active reconciled minimum distance `d_effective_min` (m) for dynamic spoken cue formatting.
    public var effectiveMinDistanceM: Double?
    /// Non-blocking LiDAR camera-height advisory cue (`.cameraTooLow` / `.cameraTooHigh` / `.none`, §3.4).
    public var cameraHeightCue: CalibrationCue

    public init(
        step: CalibrationStep,
        cue: CalibrationCue,
        progress: Double,
        lightAdvice: CalibrationLightAdvice,
        relaxed: Bool,
        skipped: Bool,
        needsExposureLock: Bool = false,
        dancerDistanceM: Double? = nil,
        effectiveMinDistanceM: Double? = nil,
        cameraHeightCue: CalibrationCue = .none
    ) {
        self.step = step
        self.cue = cue
        self.progress = progress
        self.lightAdvice = lightAdvice
        self.relaxed = relaxed
        self.skipped = skipped
        self.needsExposureLock = needsExposureLock
        self.dancerDistanceM = dancerDistanceM
        self.effectiveMinDistanceM = effectiveMinDistanceM
        self.cameraHeightCue = cameraHeightCue
    }

    public var lightCue: CalibrationCue { lightAdvice.cue }
    public var isLocked: Bool { step == .locked }
}

/// Legacy v1 calibration profile (`frames` + `gravity`); bridged from `CalibrationProfileV2.legacyProfile`.
public struct CalibrationProfile: Codable, Sendable {
    /// Raw, un-mirrored canonical frames for `PoseClip.calibration_frames`.
    public var frames: [GrooveScoringEngine.RawPoseFrame]
    /// Gravity (g, device frame) for `PoseClip.gravity_vector`.
    public var gravity: [Double]

    public init(frames: [GrooveScoringEngine.RawPoseFrame], gravity: [Double]) {
        self.frames = frames
        self.gravity = gravity
    }
}

/// Flat telemetry record for the app's debug link: step, cue, flags, every measured value and every check result.
/// Every field is a scalar (`String`, `Int`, `Double`, `Bool`, or optional scalar) so JSON stays strictly flat (§7.1).
/// A nil field has not been measured yet.
public struct CalibrationTelemetry: Codable, Equatable, Sendable {
    // State & Tier / Resume
    public var step: String = CalibrationStep.level.name
    public var stepIndex: Int = CalibrationStep.level.rawValue
    public var cue: String = CalibrationCue.none.rawValue
    public var lightAdvice: String = CalibrationLightAdvice.ok.rawValue
    public var lightCue: String = CalibrationCue.none.rawValue
    public var progress: Double = 0
    public var relaxed: Bool = false
    public var skipped: Bool = false
    public var resumed: Bool = false
    public var resumedBody: Bool = false
    public var calibrationTier: Int?
    public var cameraMode: String?
    public var capturedFrameCount: Int = 0
    public var holdSampleCount: Int = 0
    public var lastMotionTimestamp: Double?
    public var lastPoseTimestamp: Double?

    // Step 0 / 1 - phone & LiDAR floor plane
    public var rollDeg: Double?
    public var tiltBackDeg: Double?
    public var gravityX: Double?
    public var gravityY: Double?
    public var gravityZ: Double?
    public var userAccelG: Double?
    public var rotationRateRadS: Double?
    /// Distance of gravity from the locked (or resume-profile) gravity, g.
    public var gravityDeltaG: Double?
    public var rollOK: Bool?
    public var tiltOK: Bool?
    public var phoneStillOK: Bool?
    public var phoneOK: Bool?
    public var resumeOK: Bool?
    public var cameraHeightM: Double?
    public var measuredHeightM: Double?
    public var lidarFloorTiltDeg: Double?
    public var metricScaleFactor: Double?

    // Step 2 - framing, FoV/LiDAR distance & coupled span
    public var dancerDistanceM: Double?
    public var effectiveMinDistanceM: Double?
    public var distanceMinUsed: Double?
    public var distanceMaxUsed: Double?
    public var distanceOK: Bool?
    public var shoulderVisibility: Double?
    public var minCoreVisibility: Double?
    public var minFootVisibility: Double?
    public var noseVisibility: Double?
    public var minX: Double?
    public var maxX: Double?
    public var maxFootY: Double?
    public var noseY: Double?
    public var span: Double?
    public var spanExpected: Double?
    public var hipCenterX: Double?
    /// Floors and span window in force for the last pose sample (after relax / hysteresis).
    public var coreFloorUsed: Double?
    public var footFloorUsed: Double?
    public var spanMinUsed: Double?
    public var spanMaxUsed: Double?
    public var presenceOK: Bool?
    public var coreVisibleOK: Bool?
    public var feetVisibleOK: Bool?
    public var headVisibleOK: Bool?
    public var safeBoxOK: Bool?
    public var feetInFrameOK: Bool?
    public var headroomOK: Bool?
    public var spanOK: Bool?
    public var centredOK: Bool?
    public var framingOK: Bool?
    public var framingCue: String?

    // Step 3 - light & AE/AWB lock
    public var meanLuma: Double?
    public var torsoLuma: Double?
    public var borderLuma: Double?
    public var backlightDelta: Double?
    public var iso: Double?
    public var maxISO: Double?
    public var isoRatio: Double?
    public var exposureSeconds: Double?
    public var exposureLocked: Bool?
    public var lumaOK: Bool?
    public var exposureOK: Bool?
    public var isoOK: Bool?
    public var backlightOK: Bool?
    public var lightOK: Bool?

    // Poses 1–9 pass flags, T-pose metrics, L/R swap & hold tracking
    public var restOK: Bool?
    public var tPoseScore: Double?
    public var tPoseSY: Double?
    public var tPoseSExt: Double?
    public var tPoseSSpan: Double?
    public var tPoseSAng: Double?
    public var tPoseExtension: Double?
    public var tPoseHiddenArmPoints: Int?
    public var tPoseOK: Bool?
    public var overheadOK: Bool?
    public var asymLROK: Bool?
    public var lrSwapped: Bool?
    public var armsForwardOK: Bool?
    public var plieOK: Bool?
    public var turned45OK: Bool?
    public var stepLeftOK: Bool?
    public var stepRightOK: Bool?
    public var kneeLiftOK: Bool?
    public var bodyMotion: Double?
    public var motionLimitUsed: Double?
    public var bodyStillOK: Bool?
    public var poseHoldS: Double?

    public init() {}
}

// MARK: - Gate

/// Pure calibration v2 state machine. Feed it samples from the motion, pose, light, and LiDAR depth streams;
/// read `status`, `telemetry()` and, once locked, `lockedProfileV2` (plus legacy `lockedProfile`).
/// `tuning` may be replaced at any time (live tuning); holds keep their progress because they are stored as
/// start timestamps in `PoseHoldTracker`, and the new thresholds apply from the next sample.
public struct CalibrationGate: Sendable {

    /// Maximum mid-calibration LiDAR camera-height shift (m) before resetting to `.level` (§6.2).
    public static let bumpCameraHeightDeltaM: Double = 0.04

    public var tuning: CalibrationTuning

    public private(set) var cameraMode: CameraMode
    public private(set) var calibrationTier: CalibrationResumeTier
    public private(set) var step: CalibrationStep
    public private(set) var cue: CalibrationCue
    public private(set) var progress: Double = 0
    public private(set) var lightAdvice: CalibrationLightAdvice = .ok
    public private(set) var cameraHeightCue: CalibrationCue = .none
    /// True once 15 s (`relaxAfterS`) were spent in Pose 1 (`.rest`): looser visibility, span, and distance limits.
    public private(set) var relaxed = false
    public private(set) var skipped = false
    /// True when the lock came from the Tier-0 instant resume path (`.resume -> .rest -> .locked`).
    public private(set) var resumed = false
    /// True when dancer anatomical `body` fields were reused from a stored profile (Tier 0 or Tier 1; §6.2).
    public private(set) var resumedBody = false
    /// Flips `true` when Pose 1 (`.rest`) completes so the camera controller locks AE/AWB (§3.3, §7.1);
    /// resets to `false` on `.level` reset or `skip()`.
    public private(set) var needsExposureLock = false
    /// Canonical frames captured during Pose 2 (`.tpose`), or reused from a resumed profile once locked.
    public private(set) var capturedFrames: [GrooveScoringEngine.RawPoseFrame] = []
    /// Device-frame gravity locked at the end of `.level` (or taken from the resume profile), updated to latest on lock.
    public private(set) var lockedGravity: [Double]?
    /// Legacy v1 profile set on lock (`nil` when skipped).
    public private(set) var lockedProfile: CalibrationProfile?
    /// Full v2 profile (`groove.calibration/2`) set on lock (`nil` when skipped).
    public private(set) var lockedProfileV2: CalibrationProfileV2?

    public var status: CalibrationStatus {
        CalibrationStatus(
            step: step,
            cue: cue,
            progress: progress,
            lightAdvice: lightAdvice,
            relaxed: relaxed,
            skipped: skipped,
            needsExposureLock: needsExposureLock,
            dancerDistanceM: latestDancerDistanceM,
            effectiveMinDistanceM: readings.effectiveMinDistanceM,
            cameraHeightCue: cameraHeightCue
        )
    }

    /// `calibration_frames` for the take: the locked frames, `nil` when skipped or not locked.
    public var calibrationFrames: [GrooveScoringEngine.RawPoseFrame]? { lockedProfile?.frames }

    private var resumeProfile: CalibrationProfile?
    private var storedProfileV2: CalibrationProfileV2?
    private var deviceModel: String
    private var initNow: Date

    private var latestMotion: CalibrationMotionSample?
    private var latestLight: CalibrationLightSample?
    private var lockedLightSample: CalibrationLightSample?
    private var readings = CalibrationTelemetry()

    // Depth & FoV state
    private var latestDancerDistanceM: Double?
    private var latestMeasuredHeightM: Double?
    private var measuredHeightSamples: [Double] = []
    private var latestCameraHeightM: Double?
    private var lockedCameraHeightM: Double?
    private var latestFloorNormal: CalibrationVector3?
    private var latestVerticalFoVDeg: Double?
    private var latestHorizontalFoVDeg: Double?
    private var latestIntrinsics: CalibrationIntrinsics?
    private var latestShoulderToWristDeltaZM: Double?
    private var allDepthSamplesWithBones: [CalibrationDepthSample] = []
    private var tPoseDepthSamples: [CalibrationDepthSample] = []

    // Step 1 (.level)
    private var levelLatched = false
    private var phoneOkSince: Double?

    // Poses 1–9 (.rest .. .kneeLift)
    private var relaxClockStart: Double?
    private var restEnteredPoseTime: Double?
    private var personPresent = false
    private var poseTracker = CalibrationPoseScorers.PoseHoldTracker()
    private var asymSwapTracker = CalibrationPoseScorers.AsymLRSwapTracker()
    private var lastBody: (sx: Double, sy: Double, hx: Double, hy: Double)?
    private var lastHoldSampleCount: Int = 0

    // Per-pose accumulators for `CalibrationProfileV2`
    private var restSamples: [CalibrationPoseSample] = []
    private var restHipCentersX: [Double] = []
    private var restStandingKnees: [Double] = []
    private var restHipHeights: [Double] = []
    private var tPoseSamples: [CalibrationPoseSample] = []
    private var tPoseCapturedFrames: [GrooveScoringEngine.RawPoseFrame] = []
    private var tPoseCompleted = false
    private var calibratedWingspanM: Double?
    private var calibratedMetricScale: Double?
    private var overheadSamples: [CalibrationPoseSample] = []
    private var overheadHeadroomValues: [Double] = []
    private var asymLRSamples: [CalibrationPoseSample] = []
    private var armSymmetryRatios: [Double] = []
    private var armsForwardSamples: [CalibrationPoseSample] = []
    private var zDepthScaleRatios: [Double] = []
    private var plieSamples: [CalibrationPoseSample] = []
    private var turned45Samples: [CalibrationPoseSample] = []
    private var stepSamples: [CalibrationPoseSample] = []
    private var kneeLiftSamples: [CalibrationPoseSample] = []

    /// Legacy v1-compatible initializer (`cameraMode = .frontSelfView`).
    /// - Parameter resume: a v1 profile from an earlier in-session calibration. If the phone has not moved
    ///   (`gravityDeltaG < resumeGravityDeltaG`), Tier-0 framing runs (`0.4 s`) and reuses its frames.
    public init(tuning: CalibrationTuning = .defaults, resume: CalibrationProfile? = nil) {
        self.tuning = tuning
        self.cameraMode = .frontSelfView
        self.deviceModel = "unknown"
        self.initNow = Date()
        if let r = resume, !r.frames.isEmpty, r.gravity.count >= 3 {
            self.resumeProfile = r
            self.calibrationTier = .tier0InstantResume
            self.step = .resume
            self.cue = .none
        } else {
            self.calibrationTier = .tier2FullCalibration
            self.step = .level
            self.cue = .placePhone
        }
        self.readings.cameraMode = self.cameraMode.rawValue
        self.readings.calibrationTier = self.calibrationTier.rawValue
    }

    /// Full Calibration v2 initializer with `CameraMode` and 3-tier resume classification (§6.2).
    public init(
        tuning: CalibrationTuning = .defaults,
        cameraMode: CameraMode,
        storedProfile: CalibrationProfileV2? = nil,
        isSameSession: Bool = false,
        forceFullRecalibration: Bool = false,
        deviceModel: String = "unknown",
        now: Date = Date()
    ) {
        self.tuning = tuning
        self.cameraMode = cameraMode
        self.deviceModel = deviceModel
        self.initNow = now
        self.storedProfileV2 = storedProfile

        let baseTier = CalibrationProfileV2.classifyResumeTier(
            stored: storedProfile,
            cameraMode: cameraMode,
            isSameSession: false,
            forceFullRecalibration: forceFullRecalibration,
            now: now,
            tuning: tuning
        )

        if baseTier == .tier2FullCalibration {
            self.calibrationTier = .tier2FullCalibration
            self.step = .level
            self.cue = .placePhone
        } else if isSameSession, let stored = storedProfile, stored.cameraMode == cameraMode {
            // Tier-0 candidate: verify gravity (and LiDAR floor stability when rearLiDAR) in `.resume`.
            self.calibrationTier = .tier0InstantResume
            self.step = .resume
            self.cue = .none
        } else {
            // Tier 1: re-measure phone level + environment, then reuse `body` if same dancer (§6.2).
            self.calibrationTier = .tier1EnvironmentOnly
            self.step = .level
            self.cue = .placePhone
        }

        self.readings.cameraMode = cameraMode.rawValue
        self.readings.calibrationTier = self.calibrationTier.rawValue
    }

    /// Starts over from `.level` in full Tier-2 mode with the current tuning and `cameraMode` (no resume).
    public mutating func reset() {
        self = CalibrationGate(
            tuning: tuning,
            cameraMode: cameraMode,
            storedProfile: nil,
            isSameSession: false,
            forceFullRecalibration: true,
            deviceModel: deviceModel,
            now: initNow
        )
    }

    /// The Skip button: lock immediately with no calibration frames (`calibration_frames = nil`, `lockedProfileV2 = nil`).
    /// `lockedGravity` is the latest gravity reading, if any.
    public mutating func skip() {
        guard step != .locked else { return }
        skipped = true
        step = .locked
        cue = .none
        progress = 1
        needsExposureLock = false
        capturedFrames = []
        tPoseCapturedFrames = []
        lockedProfile = nil
        lockedProfileV2 = nil
        if let m = latestMotion { lockedGravity = m.gravity.array }
    }

    // MARK: Angles & Floor Tilt Cross-Check (§1.2, §3.4)

    /// Signed phone angles in degrees (§1.2):
    /// - `rollDeg = atan2(g.x, -g.y) * 180 / .pi`
    /// - `tiltBackDeg`:
    ///   - `.frontSelfView`: `atan2(-g.z, -g.y) * 180 / .pi`
    ///   - `.rearLiDAR` / `.rearWide`: `atan2(+g.z, -g.y) * 180 / .pi` (aiming rear lens slightly upward tilts front
    ///     screen slightly face-down, giving `g.z > 0` and `tiltBackDeg > 0`).
    public static func angles(
        gravity g: CalibrationVector3,
        cameraMode: CameraMode = .frontSelfView
    ) -> (rollDeg: Double, tiltBackDeg: Double) {
        let roll = atan2(g.x, -g.y) * 180.0 / .pi
        let signedZ = cameraMode.isRear ? g.z : -g.z
        let tilt = atan2(signedZ, -g.y) * 180.0 / .pi
        return (roll, tilt)
    }

    /// Angular disagreement in degrees between the fitted canonical LiDAR floor normal and expected upward gravity
    /// normal `-normalize(cameraGravity)` (§3.4).
    public static func lidarGravityDisagreementDeg(
        floorNormal: CalibrationVector3,
        deviceGravity: [Double],
        cameraMode: CameraMode
    ) -> Double {
        let gCam = cameraMode.cameraFrameGravity(fromDeviceGravity: deviceGravity)
        let expectedUp = CalibrationVector3(x: -gCam[0], y: -gCam[1], z: -gCam[2])
        return CalibrationProfileV2.angleBetweenDeg(floorNormal, expectedUp)
    }

    private var activeDeviceGravity: [Double] {
        latestMotion?.gravity.array
            ?? lockedGravity
            ?? storedProfileV2?.environment.gravity
            ?? resumeProfile?.gravity
            ?? [0.0, -1.0, 0.0]
    }

    private var activeCameraGravity: CalibrationVector3 {
        CalibrationVector3(cameraMode.cameraFrameGravity(fromDeviceGravity: activeDeviceGravity))
    }

    private mutating func refreshLidarFloorTilt() {
        guard let fn = latestFloorNormal else { return }
        guard latestMotion != nil || lockedGravity != nil else { return }
        readings.lidarFloorTiltDeg = Self.lidarGravityDisagreementDeg(
            floorNormal: fn,
            deviceGravity: activeDeviceGravity,
            cameraMode: cameraMode
        )
    }

    // MARK: Motion stream

    @discardableResult
    public mutating func update(motion m: CalibrationMotionSample) -> CalibrationStatus {
        latestMotion = m
        let (roll, tilt) = Self.angles(gravity: m.gravity, cameraMode: cameraMode)
        let accel = m.userAcceleration.norm
        let rot = m.rotationRate.norm
        let rollOK = abs(roll) <= (levelLatched ? tuning.rollExitDeg : tuning.rollEnterDeg)
        levelLatched = rollOK
        let tiltOK = tilt >= tuning.tiltBackMinDeg && tilt <= tuning.tiltBackMaxDeg
        let stillOK = accel < tuning.stillAccelMaxG && rot < tuning.stillRotationMaxRadS

        readings.lastMotionTimestamp = m.timestamp
        readings.rollDeg = roll
        readings.tiltBackDeg = tilt
        readings.gravityX = m.gravity.x
        readings.gravityY = m.gravity.y
        readings.gravityZ = m.gravity.z
        readings.userAccelG = accel
        readings.rotationRateRadS = rot
        readings.rollOK = rollOK
        readings.tiltOK = tiltOK
        readings.phoneStillOK = stillOK
        readings.phoneOK = rollOK && tiltOK && stillOK

        let reference = lockedGravity ?? resumeProfile?.gravity ?? storedProfileV2?.environment.gravity
        let delta = reference.map { m.gravity.distance(to: CalibrationVector3($0)) }
        readings.gravityDeltaG = delta
        refreshLidarFloorTilt()

        switch step {
        case .resume:
            evaluateResumeStep(fromMotion: m, rollOK: rollOK, tiltOK: tiltOK, stillOK: stillOK, tilt: tilt)
        case .level:
            processLevel(m, rollOK: rollOK, tiltOK: tiltOK, stillOK: stillOK, tilt: tilt)
        case .rest, .tpose, .overhead, .asymLR, .armsForward, .plie, .turned45, .stepLeft, .stepRight, .kneeLift:
            if let delta, delta > tuning.bumpGravityDeltaG {
                // Phone bumped or moved mid-calibration: downgrade Tier 0 and reset to `.level`, unlocking AE/AWB (§6.2).
                downgradeTierAfterBump()
                enterLevel()
                processLevel(m, rollOK: rollOK, tiltOK: tiltOK, stillOK: stillOK, tilt: tilt)
            }
        case .locked:
            break
        }
        return status
    }

    // MARK: Depth stream (§3.4, §3.5, §7.1)

    @discardableResult
    public mutating func update(depth d: CalibrationDepthSample) -> CalibrationStatus {
        if let intr = d.intrinsics {
            latestIntrinsics = intr
            if intr.verticalFoVDeg.isFinite && intr.verticalFoVDeg > 0 {
                latestVerticalFoVDeg = intr.verticalFoVDeg
            }
            if intr.horizontalFoVDeg.isFinite && intr.horizontalFoVDeg > 0 {
                latestHorizontalFoVDeg = intr.horizontalFoVDeg
            }
        }
        if let vFoV = d.verticalFoVDeg, vFoV.isFinite, vFoV > 0 {
            latestVerticalFoVDeg = vFoV
        }
        if let dist = d.dancerDistanceM, dist.isFinite, dist > 0 {
            latestDancerDistanceM = dist
            readings.dancerDistanceM = dist
        }
        if let h = d.measuredHeightM, h.isFinite, h >= 1.10, h <= 2.20 {
            latestMeasuredHeightM = h
            readings.measuredHeightM = h
            measuredHeightSamples.append(h)
        }
        if let fn = d.floorNormal, fn.norm > 1e-6 {
            latestFloorNormal = fn
            refreshLidarFloorTilt()
        }
        if let dz = d.shoulderToWristDeltaZM, dz.isFinite {
            latestShoulderToWristDeltaZM = dz
        }
        if !d.lidarBoneLengthsM.isEmpty {
            allDepthSamplesWithBones.append(d)
            if step == .tpose {
                tPoseDepthSamples.append(d)
            }
            if !tPoseCapturedFrames.isEmpty && cameraMode == .rearLiDAR {
                let scale = CalibrationPoseScorers.metricScaleFactor(
                    tPoseFrames: tPoseCapturedFrames,
                    depthSamples: tPoseDepthSamples.isEmpty ? allDepthSamplesWithBones : tPoseDepthSamples
                )
                calibratedMetricScale = scale
                readings.metricScaleFactor = scale
            }
        }

        if let hc = d.cameraHeightM, hc.isFinite, hc > 0 {
            latestCameraHeightM = hc
            readings.cameraHeightM = hc
            if hc < tuning.cameraHeightMinM {
                cameraHeightCue = .cameraTooLow
            } else if hc > tuning.cameraHeightMaxM {
                cameraHeightCue = .cameraTooHigh
            } else {
                cameraHeightCue = .none
            }
        }

        switch step {
        case .resume:
            evaluateResumeStep(fromMotion: nil, rollOK: false, tiltOK: false, stillOK: false, tilt: 0)
        case .level:
            break
        case .rest, .tpose, .overhead, .asymLR, .armsForward, .plie, .turned45, .stepLeft, .stepRight, .kneeLift:
            if let hc = d.cameraHeightM, hc.isFinite, hc > 0 {
                if let lockedHC = lockedCameraHeightM {
                    if abs(hc - lockedHC) > Self.bumpCameraHeightDeltaM {
                        downgradeTierAfterBump()
                        enterLevel()
                        if let m = latestMotion {
                            let (roll, tilt) = Self.angles(gravity: m.gravity, cameraMode: cameraMode)
                            let rollOK = abs(roll) <= (levelLatched ? tuning.rollExitDeg : tuning.rollEnterDeg)
                            let tiltOK = tilt >= tuning.tiltBackMinDeg && tilt <= tuning.tiltBackMaxDeg
                            let stillOK = m.userAcceleration.norm < tuning.stillAccelMaxG
                                && m.rotationRate.norm < tuning.stillRotationMaxRadS
                            processLevel(m, rollOK: rollOK, tiltOK: tiltOK, stillOK: stillOK, tilt: tilt)
                        }
                        return status
                    }
                } else {
                    lockedCameraHeightM = hc
                }
            }
        case .locked:
            return status
        }

        // Refresh distance telemetry immediately when depth updates.
        let passing = (step != .rest && step.poseKind != nil) || (step == .rest && poseTracker.poseLatched)
        let warmupElapsed: Double = {
            guard let start = restEnteredPoseTime, let lastPose = readings.lastPoseTimestamp else { return 0.0 }
            return max(0.0, max(lastPose, d.timestamp) - start)
        }()
        let distEval = CalibrationPoseScorers.evaluateDistance(
            cameraMode: cameraMode,
            dancerDistanceM: latestDancerDistanceM,
            measuredHeightM: latestMeasuredHeightM,
            storedHeightM: storedProfileV2?.body.dancerHeightM,
            cameraHeightM: latestCameraHeightM,
            wingspanM: calibratedWingspanM ?? storedProfileV2?.body.wingspanM,
            verticalFoVDeg: latestVerticalFoVDeg,
            horizontalFoVDeg: latestHorizontalFoVDeg,
            passing: passing,
            relaxed: relaxed,
            warmupElapsedS: warmupElapsed,
            tuning: tuning
        )
        readings.effectiveMinDistanceM = distEval.effectiveMinDistanceM
        readings.distanceMinUsed = distEval.distanceMinUsed
        readings.distanceMaxUsed = distEval.distanceMaxUsed
        if distEval.isActive {
            readings.distanceOK = distEval.distanceOK
            if step == .rest && personPresent && !distEval.distanceOK && distEval.cue != .none {
                let mapped = CalibrationCue(poseCue: distEval.cue)
                cue = mapped
                readings.framingOK = false
                readings.framingCue = mapped.rawValue
            }
        }

        return status
    }

    private mutating func downgradeTierAfterBump() {
        if resumeProfile != nil {
            resumeProfile = nil
            calibrationTier = .tier2FullCalibration
        } else if calibrationTier == .tier0InstantResume {
            calibrationTier = (storedProfileV2 != nil) ? .tier1EnvironmentOnly : .tier2FullCalibration
        }
        readings.calibrationTier = calibrationTier.rawValue
    }

    private mutating func evaluateResumeStep(
        fromMotion motionSample: CalibrationMotionSample?,
        rollOK: Bool,
        tiltOK: Bool,
        stillOK: Bool,
        tilt: Double
    ) {
        // Legacy v1 resume profile (`CalibrationProfile`).
        if let v1Profile = resumeProfile {
            guard let m = motionSample ?? latestMotion else { return }
            let delta = m.gravity.distance(to: CalibrationVector3(v1Profile.gravity))
            readings.gravityDeltaG = delta
            if delta < tuning.resumeGravityDeltaG {
                readings.resumeOK = true
                lockedGravity = v1Profile.gravity
                enterRest()
            } else {
                readings.resumeOK = false
                resumeProfile = nil
                calibrationTier = .tier2FullCalibration
                readings.calibrationTier = calibrationTier.rawValue
                enterLevel()
                if let mSample = motionSample {
                    processLevel(mSample, rollOK: rollOK, tiltOK: tiltOK, stillOK: stillOK, tilt: tilt)
                }
            }
            return
        }

        // V2 Tier-0 resume check (`CalibrationProfileV2`, §6.2).
        guard let stored = storedProfileV2 else {
            readings.resumeOK = false
            calibrationTier = .tier2FullCalibration
            readings.calibrationTier = calibrationTier.rawValue
            enterLevel()
            if let mSample = motionSample {
                processLevel(mSample, rollOK: rollOK, tiltOK: tiltOK, stillOK: stillOK, tilt: tilt)
            }
            return
        }

        if let m = motionSample ?? latestMotion, stored.environment.gravity.count >= 3 {
            let gDelta = m.gravity.distance(to: CalibrationVector3(stored.environment.gravity))
            readings.gravityDeltaG = gDelta
            if gDelta >= tuning.resumeGravityDeltaG {
                failTier0ToTier1(motionSample: motionSample, rollOK: rollOK, tiltOK: tiltOK, stillOK: stillOK, tilt: tilt)
                return
            }
        }

        if cameraMode == .rearLiDAR {
            guard let storedFloor = stored.environment.floorPlane, storedFloor.normal.count >= 3 else {
                failTier0ToTier1(motionSample: motionSample, rollOK: rollOK, tiltOK: tiltOK, stillOK: stillOK, tilt: tilt)
                return
            }
            if let liveHC = latestCameraHeightM,
               abs(liveHC - storedFloor.cameraHeightM) >= tuning.resumeFloorHeightDeltaM {
                failTier0ToTier1(motionSample: motionSample, rollOK: rollOK, tiltOK: tiltOK, stillOK: stillOK, tilt: tilt)
                return
            }
            if let liveFN = latestFloorNormal {
                let floorAngle = CalibrationProfileV2.angleBetweenDeg(liveFN, CalibrationVector3(storedFloor.normal))
                if floorAngle >= tuning.resumeFloorAngleDeg {
                    failTier0ToTier1(motionSample: motionSample, rollOK: rollOK, tiltOK: tiltOK, stillOK: stillOK, tilt: tilt)
                    return
                }
            }
            // Wait until both motion and LiDAR floor readings confirm stability.
            guard latestMotion != nil, latestCameraHeightM != nil, latestFloorNormal != nil else {
                return
            }
            readings.resumeOK = true
            lockedGravity = stored.environment.gravity
            lockedCameraHeightM = latestCameraHeightM
            enterRest()
        } else {
            guard latestMotion != nil else { return }
            readings.resumeOK = true
            lockedGravity = stored.environment.gravity
            enterRest()
        }
    }

    private mutating func failTier0ToTier1(
        motionSample: CalibrationMotionSample?,
        rollOK: Bool,
        tiltOK: Bool,
        stillOK: Bool,
        tilt: Double
    ) {
        readings.resumeOK = false
        calibrationTier = .tier1EnvironmentOnly
        readings.calibrationTier = calibrationTier.rawValue
        enterLevel()
        if let m = motionSample ?? latestMotion {
            let (r, t) = Self.angles(gravity: m.gravity, cameraMode: cameraMode)
            let rOK = motionSample != nil ? rollOK : (abs(r) <= tuning.rollEnterDeg)
            let tOK = motionSample != nil ? tiltOK : (t >= tuning.tiltBackMinDeg && t <= tuning.tiltBackMaxDeg)
            let sOK = motionSample != nil ? stillOK : (
                m.userAcceleration.norm < tuning.stillAccelMaxG
                    && m.rotationRate.norm < tuning.stillRotationMaxRadS
            )
            processLevel(m, rollOK: rOK, tiltOK: tOK, stillOK: sOK, tilt: motionSample != nil ? tilt : t)
        }
    }

    private mutating func enterLevel() {
        step = .level
        cue = .placePhone
        progress = 0
        needsExposureLock = false
        phoneOkSince = nil
        lockedGravity = nil
        lockedCameraHeightM = nil
        lockedLightSample = nil
        clearPoseSequenceState()
    }

    private mutating func processLevel(
        _ m: CalibrationMotionSample,
        rollOK: Bool,
        tiltOK: Bool,
        stillOK: Bool,
        tilt: Double
    ) {
        guard rollOK && tiltOK && stillOK else {
            phoneOkSince = nil
            progress = 0
            if !rollOK {
                cue = .levelPhone
            } else if tilt > tuning.tiltBackMaxDeg {
                cue = .tiltLessBack
            } else if tilt < tuning.tiltBackMinDeg {
                cue = .tiltLessForward
            } else {
                cue = .setPhoneDown
            }
            return
        }
        let since = phoneOkSince ?? m.timestamp
        phoneOkSince = since
        let held = m.timestamp - since
        cue = .none
        progress = Self.fraction(held, of: tuning.phoneStillHoldS)
        if held >= tuning.phoneStillHoldS {
            lockedGravity = m.gravity.array
            lockedCameraHeightM = latestCameraHeightM
            enterRest()
        }
    }

    private mutating func enterRest(withCue initialCue: CalibrationCue = .none) {
        step = .rest
        cue = initialCue
        progress = 0
        clearPoseSequenceState()
    }

    private mutating func enterPoseStep(_ nextStep: CalibrationStep) {
        step = nextStep
        progress = 0
        poseTracker.reset(clearFramingFailure: true)
        lastHoldSampleCount = 0
        readings.poseHoldS = nil
        if nextStep == .asymLR {
            asymSwapTracker.reset()
        }
        if let kind = nextStep.poseKind {
            cue = CalibrationCue(poseCue: kind.entryCue)
        } else {
            cue = .none
        }
    }

    private mutating func clearPoseSequenceState() {
        poseTracker.reset(clearFramingFailure: true)
        asymSwapTracker.reset()
        restEnteredPoseTime = nil
        lastHoldSampleCount = 0
        capturedFrames = []
        tPoseCapturedFrames = []
        tPoseCompleted = false
        calibratedWingspanM = nil
        calibratedMetricScale = nil
        restSamples = []
        restHipCentersX = []
        restStandingKnees = []
        restHipHeights = []
        tPoseSamples = []
        tPoseDepthSamples = []
        overheadSamples = []
        overheadHeadroomValues = []
        asymLRSamples = []
        armSymmetryRatios = []
        armsForwardSamples = []
        zDepthScaleRatios = []
        plieSamples = []
        turned45Samples = []
        stepSamples = []
        kneeLiftSamples = []
        readings.poseHoldS = nil
        readings.restOK = nil
        readings.overheadOK = nil
        readings.asymLROK = nil
        readings.lrSwapped = nil
        readings.armsForwardOK = nil
        readings.plieOK = nil
        readings.turned45OK = nil
        readings.stepLeftOK = nil
        readings.stepRightOK = nil
        readings.kneeLiftOK = nil
    }

    // MARK: Pose stream

    @discardableResult
    public mutating func update(pose p: CalibrationPoseSample) -> CalibrationStatus {
        let t = p.timestamp
        readings.lastPoseTimestamp = t
        let lm = Landmarks(p.landmarks)
        let motion = bodyMotion(lm)
        readings.bodyMotion = motion

        switch step {
        case .resume, .level, .locked:
            return status
        case .rest:
            processRest(p, landmarks: lm, motion: motion)
        case .tpose, .overhead, .asymLR, .armsForward, .plie, .turned45, .stepLeft, .stepRight, .kneeLift:
            processPose(p, landmarks: lm, motion: motion)
        }
        return status
    }

    private mutating func processRest(
        _ p: CalibrationPoseSample,
        landmarks lm: Landmarks,
        motion: Double?
    ) {
        let t = p.timestamp
        let rStart = relaxClockStart ?? t
        relaxClockStart = rStart
        if t - rStart >= tuning.relaxAfterS { relaxed = true }

        let wStart = restEnteredPoseTime ?? t
        restEnteredPoseTime = wStart
        let warmupElapsedS = max(0.0, t - wStart)

        let passing = poseTracker.poseLatched
        let restEval = CalibrationPoseScorers.evaluateRest(
            p,
            cameraMode: cameraMode,
            calibrationTier: calibrationTier,
            dancerDistanceM: latestDancerDistanceM,
            measuredHeightM: latestMeasuredHeightM,
            storedHeightM: storedProfileV2?.body.dancerHeightM,
            cameraHeightM: latestCameraHeightM,
            wingspanM: calibratedWingspanM ?? storedProfileV2?.body.wingspanM,
            verticalFoVDeg: latestVerticalFoVDeg,
            horizontalFoVDeg: latestHorizontalFoVDeg,
            cameraGravity: activeCameraGravity,
            passing: passing,
            relaxed: relaxed,
            warmupElapsedS: warmupElapsedS,
            bodyMotion: motion,
            isLatched: poseTracker.poseLatched,
            tuning: tuning
        )
        personPresent = restEval.framing.presence
        recordFraming(lm, framing: restEval.framing)

        let tScore = Self.tPoseScore(lm, tuning: tuning)
        recordTPose(tScore, updatePassFlag: !tPoseCompleted)
        readings.restOK = restEval.passes

        let holdS = (calibrationTier == .tier0InstantResume) ? tuning.framingHoldS : tuning.restHoldS
        let prevSamples = poseTracker.holdSamples
        let outcome = poseTracker.update(
            pose: .rest,
            timestamp: t,
            posePasses: restEval.armsRelaxedOK,
            poseFailureCue: restEval.cue,
            framingCue: restEval.framing.cue,
            bodyMotion: motion ?? 0.0,
            holdDurationOverrideS: holdS,
            tuning: tuning
        )

        readings.motionLimitUsed = outcome.motionLimitUsed
        readings.bodyStillOK = outcome.bodyStillOK
        readings.poseHoldS = outcome.elapsedS > 0 ? outcome.elapsedS : nil
        lastHoldSampleCount = outcome.holdSamples

        if outcome.holdSamples == 0 && prevSamples > 0 {
            restSamples = []
            restHipCentersX = []
            restStandingKnees = []
            restHipHeights = []
        } else if outcome.holdSamples > prevSamples {
            restSamples.append(p)
            if let hx = restEval.framing.hipCenterX { restHipCentersX.append(hx) }
            if let kf = restEval.standingKneeFlexDeg { restStandingKnees.append(kf) }
            if let hh = restEval.restHipHeightNorm { restHipHeights.append(hh) }
        }

        if outcome.completed {
            readings.restOK = true
            needsExposureLock = true
            lockedLightSample = latestLight
            completeRestTransition()
        } else {
            progress = outcome.progress
            if outcome.cue == .holdStill && outcome.bodyStillOK {
                cue = .none
            } else {
                cue = CalibrationCue(poseCue: outcome.cue)
            }
        }
    }

    private mutating func completeRestTransition() {
        switch calibrationTier {
        case .tier0InstantResume:
            if let v1Profile = resumeProfile {
                resumed = true
                resumedBody = true
                lockWithReusedBody(frames: v1Profile.frames, reusedBody: nil)
                return
            }
            if let stored = storedProfileV2,
               stored.canReuseBody(
                   measuredDancerHeightM: latestMeasuredHeightM,
                   cameraMode: cameraMode,
                   tuning: tuning
               ) {
                resumed = true
                resumedBody = true
                lockWithReusedBody(frames: stored.body.calibrationFrames, reusedBody: stored.body)
                return
            }
            // Different dancer detected by LiDAR during Tier 0 -> escalate to Tier 2 full 9-pose calibration (§6.2).
            calibrationTier = .tier2FullCalibration
            readings.calibrationTier = calibrationTier.rawValue
            resumed = false
            resumedBody = false
            enterPoseStep(.tpose)

        case .tier1EnvironmentOnly:
            if let stored = storedProfileV2,
               stored.canReuseBody(
                   measuredDancerHeightM: latestMeasuredHeightM,
                   cameraMode: cameraMode,
                   tuning: tuning
               ) {
                resumed = false
                resumedBody = true
                lockWithReusedBody(frames: stored.body.calibrationFrames, reusedBody: stored.body)
                return
            }
            // Same-dancer check failed -> escalate to Tier 2 full 9-pose calibration (§6.2).
            calibrationTier = .tier2FullCalibration
            readings.calibrationTier = calibrationTier.rawValue
            resumed = false
            resumedBody = false
            enterPoseStep(.tpose)

        case .tier2FullCalibration:
            enterPoseStep(.tpose)
        }
    }

    private mutating func processPose(
        _ p: CalibrationPoseSample,
        landmarks lm: Landmarks,
        motion: Double?
    ) {
        guard let poseKind = step.poseKind else { return }
        let t = p.timestamp
        let wStart = restEnteredPoseTime ?? t
        restEnteredPoseTime = wStart
        let warmupElapsedS = max(0.0, t - wStart)

        let framing = CalibrationPoseScorers.evaluateFraming(
            p,
            forPose: poseKind,
            cameraMode: cameraMode,
            calibrationTier: calibrationTier,
            dancerDistanceM: latestDancerDistanceM,
            measuredHeightM: latestMeasuredHeightM,
            storedHeightM: storedProfileV2?.body.dancerHeightM,
            cameraHeightM: latestCameraHeightM,
            wingspanM: calibratedWingspanM ?? storedProfileV2?.body.wingspanM,
            verticalFoVDeg: latestVerticalFoVDeg,
            horizontalFoVDeg: latestHorizontalFoVDeg,
            passing: true,
            relaxed: relaxed,
            warmupElapsedS: warmupElapsedS,
            tuning: tuning
        )
        personPresent = framing.presence
        recordFraming(lm, framing: framing)

        let camGrav = activeCameraGravity
        let isLatched = poseTracker.poseLatched
        var posePasses = false
        var poseFailureCue: CalibrationPoseScorers.PoseCue = poseKind.entryCue
        var overheadHeadroomSample: Double?
        var armSymmetrySample: Double?
        var zDepthRatioSample: Double?

        switch poseKind {
        case .rest:
            return

        case .tpose:
            let eval = CalibrationPoseScorers.evaluateTPose(
                p,
                bodyMotion: motion,
                isLatched: isLatched,
                tuning: tuning
            )
            recordTPose(eval.tPoseScore, updatePassFlag: true)
            readings.tPoseOK = eval.passes
            posePasses = eval.tPoseScore.passes && eval.wristsInBoundsOK
            poseFailureCue = eval.cue

        case .overhead:
            let eval = CalibrationPoseScorers.evaluateOverhead(
                p,
                cameraGravity: camGrav,
                bodyMotion: motion,
                isLatched: isLatched,
                tuning: tuning
            )
            readings.overheadOK = eval.passes
            posePasses = eval.wristsAboveNoseOK && eval.topMarginOK && eval.wristsVisibleOK && eval.elbowsExtendedOK
            poseFailureCue = eval.cue
            overheadHeadroomSample = eval.overheadHeadroomMinY

        case .asymLR:
            let eval = asymSwapTracker.evaluate(
                timestamp: t,
                sample: p,
                cameraGravity: camGrav,
                bodyMotion: motion,
                isLatched: isLatched,
                tuning: tuning
            )
            readings.lrSwapped = eval.lrSwapped
            readings.asymLROK = eval.passes
            posePasses = eval.leftOverheadOK && eval.rightHorizontalOK
            poseFailureCue = eval.cue
            armSymmetrySample = eval.armSymmetryRatio

        case .armsForward:
            let eval = CalibrationPoseScorers.evaluateArmsForward(
                p,
                cameraMode: cameraMode,
                shoulderToWristDeltaZM: latestShoulderToWristDeltaZM,
                cameraGravity: camGrav,
                bodyMotion: motion,
                isLatched: isLatched,
                tuning: tuning
            )
            readings.armsForwardOK = eval.passes
            posePasses = eval.canonicalForwardOK && eval.wristsAtShoulderHeightOK && eval.lidarDeltaZOK
            poseFailureCue = eval.cue
            zDepthRatioSample = eval.zDepthScaleRatio

        case .plie:
            let standingKnee = CalibrationPoseScorers.median(restStandingKnees) ?? 0.0
            let restHipNorm = CalibrationPoseScorers.median(restHipHeights)
            let eval = CalibrationPoseScorers.evaluatePlie(
                p,
                standingKneeFlexDeg: standingKnee,
                restHipHeightNorm: restHipNorm,
                cameraGravity: camGrav,
                passing: true,
                relaxed: relaxed,
                bodyMotion: motion,
                isLatched: isLatched,
                tuning: tuning
            )
            readings.plieOK = eval.passes
            posePasses = eval.kneeFlexOK && eval.hipDropOK && eval.armsOutOK && eval.feetVisibleOK
            poseFailureCue = eval.cue

        case .turned45:
            let eval = CalibrationPoseScorers.evaluateTurned45(
                p,
                cameraGravity: camGrav,
                bodyMotion: motion,
                isLatched: isLatched,
                tuning: tuning
            )
            readings.turned45OK = eval.passes
            posePasses = eval.shoulderWidthOK && eval.yawInWindowOK && eval.armsExtendedOK
            poseFailureCue = eval.cue

        case .stepLeft:
            let restHX = CalibrationPoseScorers.median(restHipCentersX) ?? 0.50
            let eval = CalibrationPoseScorers.evaluateStepLeft(
                p,
                restHipCenterX: restHX,
                cameraGravity: camGrav,
                passing: true,
                relaxed: relaxed,
                bodyMotion: motion,
                isLatched: isLatched,
                tuning: tuning
            )
            readings.stepLeftOK = eval.passes
            posePasses = eval.shiftOK && eval.safeBoxOK && eval.coreVisibleOK && eval.feetVisibleOK
            poseFailureCue = eval.cue

        case .stepRight:
            let restHX = CalibrationPoseScorers.median(restHipCentersX) ?? 0.50
            let eval = CalibrationPoseScorers.evaluateStepRight(
                p,
                restHipCenterX: restHX,
                cameraGravity: camGrav,
                passing: true,
                relaxed: relaxed,
                bodyMotion: motion,
                isLatched: isLatched,
                tuning: tuning
            )
            readings.stepRightOK = eval.passes
            posePasses = eval.shiftOK && eval.safeBoxOK && eval.coreVisibleOK && eval.feetVisibleOK
            poseFailureCue = eval.cue

        case .kneeLift:
            let eval = CalibrationPoseScorers.evaluateKneeLift(
                p,
                cameraGravity: camGrav,
                passing: true,
                relaxed: relaxed,
                bodyMotion: motion,
                isLatched: isLatched,
                tuning: tuning
            )
            readings.kneeLiftOK = eval.passes
            posePasses = eval.kneeFlexOK
                && eval.ankleClearanceOK
                && eval.standingSupportVisibleOK
                && eval.liftedFootVisibleOK
            poseFailureCue = eval.cue
        }

        let prevSamples = poseTracker.holdSamples
        let outcome = poseTracker.update(
            pose: poseKind,
            timestamp: t,
            posePasses: posePasses,
            poseFailureCue: poseFailureCue,
            framingCue: framing.cue,
            bodyMotion: motion,
            frame: (poseKind == .tpose) ? p.frame : nil,
            tuning: tuning
        )

        readings.motionLimitUsed = outcome.motionLimitUsed
        readings.bodyStillOK = outcome.bodyStillOK
        readings.poseHoldS = outcome.elapsedS > 0 ? outcome.elapsedS : nil
        lastHoldSampleCount = outcome.holdSamples

        if poseKind == .tpose {
            capturedFrames = poseTracker.capturedFrames
        }

        if outcome.framingLost {
            enterRest(withCue: CalibrationCue(poseCue: outcome.cue))
            return
        }

        if outcome.holdSamples == 0 && prevSamples > 0 {
            clearCurrentPoseBuffer(for: poseKind)
        } else if outcome.holdSamples > prevSamples {
            appendGoodPoseSample(
                p,
                for: poseKind,
                overheadHeadroomMinY: overheadHeadroomSample,
                armSymmetryRatio: armSymmetrySample,
                zDepthScaleRatio: zDepthRatioSample
            )
        }

        if outcome.completed {
            advanceAfterCompletedPose(poseKind)
        } else {
            progress = outcome.progress
            cue = CalibrationCue(poseCue: outcome.cue)
        }
    }

    private mutating func clearCurrentPoseBuffer(for poseKind: CalibrationPoseScorers.PoseKind) {
        switch poseKind {
        case .rest:
            restSamples = []
            restHipCentersX = []
            restStandingKnees = []
            restHipHeights = []
        case .tpose:
            tPoseSamples = []
        case .overhead:
            overheadSamples = []
            overheadHeadroomValues = []
        case .asymLR:
            asymLRSamples = []
            armSymmetryRatios = []
        case .armsForward:
            armsForwardSamples = []
            zDepthScaleRatios = []
        case .plie:
            plieSamples = []
        case .turned45:
            turned45Samples = []
        case .stepLeft, .stepRight:
            break
        case .kneeLift:
            kneeLiftSamples = []
        }
    }

    private mutating func appendGoodPoseSample(
        _ sample: CalibrationPoseSample,
        for poseKind: CalibrationPoseScorers.PoseKind,
        overheadHeadroomMinY: Double?,
        armSymmetryRatio: Double?,
        zDepthScaleRatio: Double?
    ) {
        switch poseKind {
        case .rest:
            restSamples.append(sample)
        case .tpose:
            tPoseSamples.append(sample)
        case .overhead:
            overheadSamples.append(sample)
            if let y = overheadHeadroomMinY { overheadHeadroomValues.append(y) }
        case .asymLR:
            asymLRSamples.append(sample)
            if let r = armSymmetryRatio { armSymmetryRatios.append(r) }
        case .armsForward:
            armsForwardSamples.append(sample)
            if let r = zDepthScaleRatio { zDepthScaleRatios.append(r) }
        case .plie:
            plieSamples.append(sample)
        case .turned45:
            turned45Samples.append(sample)
        case .stepLeft, .stepRight:
            stepSamples.append(sample)
        case .kneeLift:
            kneeLiftSamples.append(sample)
        }
    }

    private mutating func advanceAfterCompletedPose(_ poseKind: CalibrationPoseScorers.PoseKind) {
        switch poseKind {
        case .rest:
            completeRestTransition()

        case .tpose:
            tPoseCompleted = true
            readings.tPoseOK = true
            tPoseCapturedFrames = poseTracker.capturedFrames
            capturedFrames = tPoseCapturedFrames
            let scale: Double = cameraMode == .rearLiDAR
                ? CalibrationPoseScorers.metricScaleFactor(
                    tPoseFrames: tPoseCapturedFrames,
                    depthSamples: tPoseDepthSamples.isEmpty ? allDepthSamplesWithBones : tPoseDepthSamples
                )
                : 1.0
            calibratedMetricScale = scale
            readings.metricScaleFactor = scale
            let bonesM = CalibrationPoseScorers.calibratedBoneLengthsM(
                tPoseFrames: tPoseCapturedFrames,
                metricScaleFactor: scale
            )
            calibratedWingspanM = CalibrationPoseScorers.wristToWristWingspanM(from: bonesM)
            enterPoseStep(.overhead)

        case .overhead:
            readings.overheadOK = true
            enterPoseStep(.asymLR)

        case .asymLR:
            readings.asymLROK = true
            readings.lrSwapped = false
            enterPoseStep(.armsForward)

        case .armsForward:
            readings.armsForwardOK = true
            enterPoseStep(.plie)

        case .plie:
            readings.plieOK = true
            enterPoseStep(.turned45)

        case .turned45:
            readings.turned45OK = true
            enterPoseStep(.stepLeft)

        case .stepLeft:
            readings.stepLeftOK = true
            enterPoseStep(.stepRight)

        case .stepRight:
            readings.stepRightOK = true
            enterPoseStep(.kneeLift)

        case .kneeLift:
            readings.kneeLiftOK = true
            lockFullTier2()
        }
    }

    // MARK: Lock & Profile Assembly (§6.1, §6.2)

    private mutating func buildEnvironment(gravity: [Double], wingspanM: Double?) -> CalibrationProfileV2.Environment {
        let (roll, tilt) = Self.angles(gravity: CalibrationVector3(gravity), cameraMode: cameraMode)
        let isTier0 = (calibrationTier == .tier0InstantResume)

        let floorPlane: CalibrationProfileV2.FloorPlane? = {
            if let hc = latestCameraHeightM, let fn = latestFloorNormal {
                let dis = Self.lidarGravityDisagreementDeg(
                    floorNormal: fn,
                    deviceGravity: gravity,
                    cameraMode: cameraMode
                )
                return CalibrationProfileV2.FloorPlane(
                    normal: fn.array,
                    cameraHeightM: hc,
                    lidarGravityDisagreementDeg: dis
                )
            }
            return isTier0 ? storedProfileV2?.environment.floorPlane : nil
        }()

        let resolvedDist = latestDancerDistanceM ?? (isTier0 ? storedProfileV2?.environment.dancerDistanceM : nil)
        let resolvedIntrinsics = latestIntrinsics ?? (isTier0 ? storedProfileV2?.environment.intrinsics : nil)
        let resolvedEffMin: Double? = {
            if let eff = readings.effectiveMinDistanceM { return eff }
            if isTier0 { return storedProfileV2?.environment.effectiveMinDistanceM }
            return nil
        }()
        let resolvedLateralSpan: Double? = {
            if let d = resolvedDist {
                return CalibrationPoseScorers.usableLateralSpanM(
                    dancerDistanceM: d,
                    horizontalFoVDeg: latestHorizontalFoVDeg ?? resolvedIntrinsics?.horizontalFoVDeg,
                    verticalFoVDeg: latestVerticalFoVDeg ?? resolvedIntrinsics?.verticalFoVDeg
                )
            }
            return storedProfileV2?.environment.usableLateralSpanM
        }()
        let resolvedOverheadMinY = CalibrationPoseScorers.median(overheadHeadroomValues)
            ?? storedProfileV2?.environment.overheadHeadroomMinY

        let luma = lockedLightSample?.meanLuma ?? readings.meanLuma ?? storedProfileV2?.environment.lockedMeanLuma
        let iso = lockedLightSample.flatMap { $0.iso > 0 ? $0.iso : nil }
            ?? readings.iso.flatMap { $0 > 0 ? $0 : nil }
            ?? storedProfileV2?.environment.exposureLockedISO
        let expDur = lockedLightSample.flatMap { $0.exposureSeconds > 0 ? $0.exposureSeconds : nil }
            ?? readings.exposureSeconds.flatMap { $0 > 0 ? $0 : nil }
            ?? storedProfileV2?.environment.exposureLockedDurationS

        return CalibrationProfileV2.Environment(
            gravity: gravity,
            rollDeg: roll,
            tiltBackDeg: tilt,
            intrinsics: resolvedIntrinsics,
            floorPlane: floorPlane,
            effectiveMinDistanceM: resolvedEffMin,
            dancerDistanceM: resolvedDist,
            usableLateralSpanM: resolvedLateralSpan,
            overheadHeadroomMinY: resolvedOverheadMinY,
            lockedMeanLuma: luma,
            exposureLockedISO: iso,
            exposureLockedDurationS: expDur,
            airplayRouteOffsetsMs: storedProfileV2?.environment.airplayRouteOffsetsMs ?? [:],
            tvVideoLeadOffsetMs: storedProfileV2?.environment.tvVideoLeadOffsetMs ?? 0.0
        )
    }

    private mutating func lockWithReusedBody(
        frames: [GrooveScoringEngine.RawPoseFrame],
        reusedBody: CalibrationProfileV2.Body?
    ) {
        let gravity = latestMotion?.gravity.array
            ?? lockedGravity
            ?? storedProfileV2?.environment.gravity
            ?? resumeProfile?.gravity
            ?? [0.0, -1.0, 0.0]
        lockedGravity = gravity
        capturedFrames = frames

        let body: CalibrationProfileV2.Body
        if let reusedBody {
            body = reusedBody
        } else {
            let bonesM = CalibrationPoseScorers.calibratedBoneLengthsM(tPoseFrames: frames, metricScaleFactor: 1.0)
            body = CalibrationProfileV2.Body(
                dancerHeightM: nil,
                metricScaleFactor: 1.0,
                wingspanM: CalibrationPoseScorers.wingspanM(from: bonesM, dancerHeightM: nil),
                lrVerified: false,
                boneLengthsM: bonesM,
                calibrationFrames: frames
            )
        }

        readings.metricScaleFactor = body.metricScaleFactor
        let env = buildEnvironment(gravity: gravity, wingspanM: body.wingspanM)
        let profileTimestamp = storedProfileV2?.calibratedAt ?? CalibrationProfileV2.formatTimestamp(initNow)
        let resolvedModel = (deviceModel == "unknown" ? storedProfileV2?.deviceModel : nil) ?? deviceModel

        let v2 = CalibrationProfileV2(
            calibratedAt: profileTimestamp,
            deviceModel: resolvedModel,
            cameraMode: cameraMode,
            environment: env,
            body: body
        )
        lockedProfileV2 = v2
        lockedProfile = CalibrationProfile(frames: frames, gravity: gravity)
        step = .locked
        cue = .locked
        progress = 1
    }

    private mutating func lockFullTier2() {
        let gravity = latestMotion?.gravity.array ?? lockedGravity ?? [0.0, -1.0, 0.0]
        lockedGravity = gravity
        let frames = tPoseCapturedFrames
        capturedFrames = frames

        let dancerHeightM: Double? = cameraMode == .rearLiDAR
            ? CalibrationPoseScorers.median(measuredHeightSamples)
            : nil
        let scale: Double = calibratedMetricScale ?? (
            cameraMode == .rearLiDAR
                ? CalibrationPoseScorers.metricScaleFactor(
                    tPoseFrames: frames,
                    depthSamples: tPoseDepthSamples.isEmpty ? allDepthSamplesWithBones : tPoseDepthSamples
                )
                : 1.0
        )
        readings.metricScaleFactor = scale

        let bonesM = CalibrationPoseScorers.calibratedBoneLengthsM(
            tPoseFrames: frames,
            metricScaleFactor: scale
        )
        let wingspan = CalibrationPoseScorers.wingspanM(from: bonesM, dancerHeightM: dancerHeightM)
        let camGrav = CalibrationVector3(cameraMode.cameraFrameGravity(fromDeviceGravity: gravity))
        let rom = CalibrationPoseScorers.buildROM(
            restSamples: restSamples,
            overheadSamples: overheadSamples,
            plieSamples: plieSamples,
            kneeLiftSamples: kneeLiftSamples,
            cameraGravity: camGrav
        )
        let allHeldSamples = restSamples
            + tPoseSamples
            + overheadSamples
            + asymLRSamples
            + armsForwardSamples
            + plieSamples
            + turned45Samples
            + stepSamples
            + kneeLiftSamples
        let weights = CalibrationPoseScorers.aggregateJointConfidenceWeights(samples: allHeldSamples)

        let body = CalibrationProfileV2.Body(
            dancerHeightM: dancerHeightM,
            metricScaleFactor: scale,
            wingspanM: wingspan,
            lrVerified: true,
            armSymmetryRatio: CalibrationPoseScorers.median(armSymmetryRatios),
            zDepthScaleRatio: CalibrationPoseScorers.median(zDepthScaleRatios),
            boneLengthsM: bonesM,
            rom: rom,
            jointConfidenceWeights: weights,
            calibrationFrames: frames
        )
        let env = buildEnvironment(gravity: gravity, wingspanM: wingspan)
        let v2 = CalibrationProfileV2(
            calibratedAt: CalibrationProfileV2.formatTimestamp(initNow),
            deviceModel: deviceModel,
            cameraMode: cameraMode,
            environment: env,
            body: body
        )
        resumed = false
        resumedBody = false
        lockedProfileV2 = v2
        lockedProfile = v2.legacyProfile
        step = .locked
        cue = .locked
        progress = 1
    }

    // MARK: Light stream (advice only; never changes the step)

    @discardableResult
    public mutating func update(light l: CalibrationLightSample) -> CalibrationStatus {
        latestLight = l
        let a = Self.lightChecks(l, personPresent: personPresent, tuning: tuning)
        lightAdvice = a.advice
        readings.meanLuma = l.meanLuma
        readings.torsoLuma = l.torsoLuma
        readings.borderLuma = l.borderLuma
        readings.backlightDelta = a.backlightDelta
        readings.iso = l.iso
        readings.maxISO = l.maxISO
        readings.isoRatio = a.isoRatio
        readings.exposureSeconds = l.exposureSeconds
        readings.exposureLocked = l.exposureLocked
        readings.lumaOK = a.lumaOK
        readings.exposureOK = a.exposureOK
        readings.isoOK = a.isoOK
        readings.backlightOK = a.backlightOK
        readings.lightOK = a.advice == .ok
        return status
    }

    struct LightChecks {
        var advice: CalibrationLightAdvice
        var lumaOK: Bool
        var exposureOK: Bool
        var isoOK: Bool
        var backlightOK: Bool
        var isoRatio: Double?
        var backlightDelta: Double?
    }

    static func lightChecks(_ l: CalibrationLightSample, personPresent: Bool,
                            tuning u: CalibrationTuning) -> LightChecks {
        let isoRatio: Double? = l.maxISO > 0 ? l.iso / l.maxISO : nil
        var backlightDelta: Double?
        if let torso = l.torsoLuma, let border = l.borderLuma { backlightDelta = border - torso }
        let backlit = backlightDelta.map { $0 > u.backlightDeltaMin } == true
            && (l.torsoLuma ?? 1) < u.backlightTorsoLumaMax
        let lumaOK = l.meanLuma >= u.dimLumaMax
        let exposureOK = l.exposureSeconds < u.dimExposureMinS
        let isoOK = l.iso < u.dimISOMin && (isoRatio.map { $0 < u.dimISORatioMin } ?? true)
        let advice: CalibrationLightAdvice
        if !personPresent && l.meanLuma < u.veryDarkLumaMax {
            advice = .veryDark
        } else if backlit {
            advice = .backlit
        } else if !lumaOK || !exposureOK || !isoOK {
            advice = .dim
        } else {
            advice = .ok
        }
        return LightChecks(advice: advice, lumaOK: lumaOK, exposureOK: exposureOK, isoOK: isoOK,
                           backlightOK: !backlit, isoRatio: isoRatio, backlightDelta: backlightDelta)
    }

    /// The advice for one light sample.
    public static func lightAdvice(_ l: CalibrationLightSample, personPresent: Bool,
                                   tuning: CalibrationTuning = .defaults) -> CalibrationLightAdvice {
        lightChecks(l, personPresent: personPresent, tuning: tuning).advice
    }

    // MARK: Telemetry

    public func telemetry() -> CalibrationTelemetry {
        var r = readings
        r.step = step.name
        r.stepIndex = step.rawValue
        r.cue = cue.rawValue
        r.lightAdvice = lightAdvice.rawValue
        r.lightCue = lightAdvice.cue.rawValue
        r.progress = progress
        r.relaxed = relaxed
        r.skipped = skipped
        r.resumed = resumed
        r.resumedBody = resumedBody
        r.calibrationTier = calibrationTier.rawValue
        r.cameraMode = cameraMode.rawValue
        r.capturedFrameCount = capturedFrames.count
        r.holdSampleCount = lastHoldSampleCount
        return r
    }

    // MARK: Framing Telemetry Recording & Helpers

    struct Landmarks {
        let points: [CalibrationLandmark]
        init(_ points: [CalibrationLandmark]) { self.points = points }

        subscript(_ name: String) -> CalibrationLandmark? {
            guard let i = CanonicalSkeleton.mediapipeIndex[name], i < points.count else { return nil }
            return points[i]
        }

        func visibility(_ name: String) -> Double { self[name]?.visibility ?? 0 }
    }

    static let coreJoints = CalibrationPoseScorers.coreJoints
    static let footJoints = CalibrationPoseScorers.footJoints
    static let legJoints = CalibrationPoseScorers.legJoints

    private mutating func recordFraming(
        _ lm: Landmarks,
        framing: CalibrationPoseScorers.FramingEvaluation
    ) {
        let shoulderVis = min(lm.visibility("leftShoulder"), lm.visibility("rightShoulder"))
        let coreVis = Self.coreJoints.map { lm.visibility($0) }.min() ?? 0
        let footVis = Self.footJoints.map { lm.visibility($0) }.min() ?? 0
        let noseVis = lm.visibility("nose")
        let mappedCue = CalibrationCue(poseCue: framing.cue)

        readings.shoulderVisibility = shoulderVis
        readings.minCoreVisibility = coreVis
        readings.minFootVisibility = footVis
        readings.noseVisibility = noseVis
        readings.minX = framing.minX
        readings.maxX = framing.maxX
        readings.maxFootY = framing.maxFootY
        readings.noseY = framing.noseY
        readings.span = framing.span
        readings.spanExpected = framing.spanBounds.spanExpected
        readings.hipCenterX = framing.hipCenterX
        readings.coreFloorUsed = framing.coreFloorUsed
        readings.footFloorUsed = framing.footFloorUsed
        readings.spanMinUsed = framing.spanBounds.spanMinUsed
        readings.spanMaxUsed = framing.spanBounds.spanMaxUsed
        readings.effectiveMinDistanceM = framing.distanceEvaluation.effectiveMinDistanceM
        readings.distanceMinUsed = framing.distanceEvaluation.distanceMinUsed
        readings.distanceMaxUsed = framing.distanceEvaluation.distanceMaxUsed
        if framing.distanceEvaluation.isActive {
            readings.distanceOK = framing.distanceEvaluation.distanceOK
        } else if latestDancerDistanceM != nil {
            readings.distanceOK = framing.distanceEvaluation.distanceOK
        }
        readings.presenceOK = framing.presence
        readings.coreVisibleOK = framing.coreVisibleOK
        readings.feetVisibleOK = framing.feetVisibleOK
        readings.headVisibleOK = framing.headVisibleOK
        readings.safeBoxOK = framing.safeBoxOK
        readings.feetInFrameOK = framing.feetInFrameOK
        readings.headroomOK = framing.headroomOK
        readings.spanOK = framing.spanOK
        readings.centredOK = framing.centredOK
        readings.framingOK = framing.passes
        readings.framingCue = mappedCue.rawValue
    }

    /// Mean shoulder- and hip-midpoint displacement since the previous pose sample, divided by the nose-to-foot
    /// span (Ashrium-style). `nil` on the first sample or without shoulders, hips and nose.
    private mutating func bodyMotion(_ lm: Landmarks) -> Double? {
        guard let ls = lm["leftShoulder"], let rs = lm["rightShoulder"],
              let lh = lm["leftHip"], let rh = lm["rightHip"], let nose = lm["nose"],
              min(ls.visibility, rs.visibility, lh.visibility, rh.visibility) > 0 else {
            lastBody = nil
            return nil
        }
        let cur = (sx: 0.5 * (ls.x + rs.x), sy: 0.5 * (ls.y + rs.y), hx: 0.5 * (lh.x + rh.x), hy: 0.5 * (lh.y + rh.y))
        defer { lastBody = cur }
        guard let prev = lastBody else { return nil }
        let footY = Self.footJoints.compactMap { lm[$0]?.y }.max() ?? 1
        let span = max(0.05, footY - nose.y)
        let d = 0.5 * (hypot(cur.sx - prev.sx, cur.sy - prev.sy) + hypot(cur.hx - prev.hx, cur.hy - prev.hy))
        return d / span
    }

    // MARK: T-pose (port of OpenJustDance engine/pose_engine/detector.py `t_pose_score`)

    public struct TPoseScore: Equatable, Sendable {
        public var score: Double
        public var sY: Double
        public var sExt: Double
        public var sSpan: Double
        public var sAng: Double
        /// `min` over both arms of the wrist's outward reach past its shoulder, in shoulder widths.
        public var ext: Double
        public var hiddenArmPoints: Int
        /// Score and the `ok` sub-gates all pass.
        public var passes: Bool

        static let zero = TPoseScore(score: 0, sY: 0, sExt: 0, sSpan: 0, sAng: 0, ext: -1, hiddenArmPoints: 6,
                                     passes: false)
    }

    private mutating func recordTPose(_ s: TPoseScore, updatePassFlag: Bool) {
        readings.tPoseScore = s.score
        readings.tPoseSY = s.sY
        readings.tPoseSExt = s.sExt
        readings.tPoseSSpan = s.sSpan
        readings.tPoseSAng = s.sAng
        readings.tPoseExtension = s.ext
        readings.tPoseHiddenArmPoints = s.hiddenArmPoints
        if updatePassFlag {
            readings.tPoseOK = s.passes
        }
    }

    static func tPoseScore(_ lm: Landmarks, tuning u: CalibrationTuning) -> TPoseScore {
        guard let ls = lm["leftShoulder"], let rs = lm["rightShoulder"], let le = lm["leftElbow"],
              let re = lm["rightElbow"], let lw = lm["leftWrist"], let rw = lm["rightWrist"] else { return .zero }
        let hidden = [ls, rs, le, re, lw, rw].filter { $0.visibility < u.tPoseArmMinVisibility }.count
        guard hidden <= 2 else { return .zero }
        let shoulder = hypot(rs.x - ls.x, rs.y - ls.y)
        guard shoulder > 1e-6 else { return .zero }
        var torso = shoulder * 1.2
        if let lh = lm["leftHip"], let rh = lm["rightHip"], min(lh.visibility, rh.visibility) > 0 {
            torso = abs(0.5 * (ls.y + rs.y) - 0.5 * (lh.y + rh.y))
        }
        let yScale = max(torso, shoulder * 0.6, 1e-6)
        let yWorst = [lw.y - ls.y, rw.y - rs.y, le.y - ls.y, re.y - rs.y].map { abs($0) / yScale }.max() ?? 0
        let sY = clamp01(1 - (yWorst - 0.25) / 0.35)
        // Outer (image-left) and inner sides, whichever way the labels fall in the image.
        let leftIsImageLeft = ls.x <= rs.x
        let (oL, oR) = leftIsImageLeft ? (ls, rs) : (rs, ls)
        let (wL, wR) = leftIsImageLeft ? (lw, rw) : (rw, lw)
        let ext = min((oL.x - wL.x) / shoulder, (wR.x - oR.x) / shoulder)
        let sExt = clamp01((ext + 0.1) / 0.5)
        let sSpan = clamp01((abs(rw.x - lw.x) / shoulder - 1.1) / 0.7)
        let sAng = clamp01((min(angle(ls, le, lw), angle(rs, re, rw)) - 120) / 30)
        let sSh = shoulder >= 0.05 ? 1.0 : shoulder / 0.05
        var score = (0.50 * sY + 0.20 * sExt + 0.10 * sSpan + 0.20 * sAng) * sSh
        if hidden > 0 { score *= 0.7 }
        score = clamp01(score)
        let passes = score >= u.tPoseMinScore && sY > u.tPoseMinSY && sAng > u.tPoseMinSAng
            && ext > u.tPoseMinExtension
        return TPoseScore(score: score, sY: sY, sExt: sExt, sSpan: sSpan, sAng: sAng, ext: ext,
                          hiddenArmPoints: hidden, passes: passes)
    }

    /// The T-pose score of one pose sample.
    public static func tPoseScore(_ sample: CalibrationPoseSample,
                                  tuning: CalibrationTuning = .defaults) -> TPoseScore {
        tPoseScore(Landmarks(sample.landmarks), tuning: tuning)
    }

    /// Interior angle at `b` (degrees).
    static func angle(_ a: CalibrationLandmark, _ b: CalibrationLandmark, _ c: CalibrationLandmark) -> Double {
        let v1 = (a.x - b.x, a.y - b.y)
        let v2 = (c.x - b.x, c.y - b.y)
        let n = hypot(v1.0, v1.1) * hypot(v2.0, v2.1)
        guard n > 1e-9 else { return 0 }
        return acos(max(-1, min(1, (v1.0 * v2.0 + v1.1 * v2.1) / n))) * 180 / .pi
    }

    static func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }

    static func fraction(_ held: Double, of hold: Double) -> Double {
        hold > 0 ? clamp01(held / hold) : 1
    }
}
