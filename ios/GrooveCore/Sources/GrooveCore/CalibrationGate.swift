import Foundation

// Pre-dance calibration (app-only; no Python parity). Foundation only, so `swift test` runs it on Linux.
// Spec: docs/research/2026-11-18-calibration-research.md, "Recommended calibration sequence".
//
// Steps: resume (0) -> level the phone (1) -> full-body framing (2) -> T-pose hold (4) -> locked (5).
// Lighting (3) is advice computed alongside steps 1-4; it never blocks.
//
// Landmarks are MediaPipe normalised image coordinates of the UN-mirrored portrait buffer (x right, y down).
// MediaPipe's left/right are the person's own sides. A person standing at raw x < 0.5 is off to their own right
// and shows on the right of the mirrored selfie preview, so the cue is "Move to your left" (which is also
// screen-left in the mirrored preview).
//
// Clocks: each input stream drives its own holds. Motion timestamps time the phone hold (step 1); pose timestamps
// time the framing hold, the relax clock and the T-pose hold. The two clocks are never subtracted from each other.

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
    /// `CMDeviceMotion.gravity` (g). Upright portrait is about (0, -1, 0); +z points out of the screen.
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

    public init(meanLuma: Double, torsoLuma: Double? = nil, borderLuma: Double? = nil,
                iso: Double = 0, maxISO: Double = 0, exposureSeconds: Double = 0) {
        self.meanLuma = meanLuma
        self.torsoLuma = torsoLuma
        self.borderLuma = borderLuma
        self.iso = iso
        self.maxISO = maxISO
        self.exposureSeconds = exposureSeconds
    }
}

// MARK: - Outputs

public enum CalibrationStep: Int, Codable, Sendable, CaseIterable {
    case resume = 0
    case level = 1
    case frame = 2
    // 3 is lighting: advice alongside steps 1-4, never a blocking step.
    case tpose = 4
    case locked = 5

    public var name: String {
        switch self {
        case .resume: return "resume"
        case .level: return "level"
        case .frame: return "frame"
        case .tpose: return "tpose"
        case .locked: return "locked"
        }
    }
}

/// One spoken / visual instruction (report table). Left and right are the dancer's own sides, which match the
/// mirrored selfie preview.
public enum CalibrationCue: String, Codable, Sendable, CaseIterable {
    case none
    // Step 1
    case placePhone
    case levelPhone
    case tiltLessBack
    case tiltLessForward
    case setPhoneDown
    // Step 2
    case stepIn
    case stepBackShowFeet
    case showHead
    case stepBack
    case stepCloser
    case moveLeft
    case moveRight
    // Step 3 (advice; reported as `lightCue`, never as the blocking `cue`)
    case dimLight
    case backlit
    case veryDark
    /// Static scene advice for the overlay; the gate never emits it.
    case sceneTips
    // Step 4
    case armsOutT
    case holdStill
    // Step 5
    case locked

    public var spokenText: String {
        switch self {
        case .none: return ""
        case .placePhone: return "Stand your phone up about waist high, facing you."
        case .levelPhone: return "Level the phone."
        case .tiltLessBack: return "Tilt it back a little less."
        case .tiltLessForward: return "Tilt the top of the phone back a little."
        case .setPhoneDown: return "Set it down so it's still."
        case .stepIn: return "Step in front of the camera."
        case .stepBackShowFeet: return "Step back so your feet are in view."
        case .showHead: return "Step back so your head is in view."
        case .stepBack: return "Step back."
        case .stepCloser: return "Step a little closer."
        case .moveLeft: return "Move to your left."
        case .moveRight: return "Move to your right."
        case .dimLight: return "Dim light. Turn on a light in front of you for sharper feet and hands."
        case .backlit: return "Bright light behind you. Face the light."
        case .veryDark: return "Camera is very dark. Check the lens or turn on a light."
        case .sceneTips: return "Avoid mirrors and colour-changing lights, and wear clothes that stand out from the wall."
        case .armsOutT: return "Arms straight out to the sides, like a T. Hold still."
        case .holdStill: return "Hold still."
        case .locked: return "Locked in!"
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
    /// The blocking step's instruction (`.none` while a hold is filling).
    public var cue: CalibrationCue
    /// Hold progress of the current step, 0...1.
    public var progress: Double
    public var lightAdvice: CalibrationLightAdvice
    public var relaxed: Bool
    public var skipped: Bool

    public var lightCue: CalibrationCue { lightAdvice.cue }
    public var isLocked: Bool { step == .locked }
}

/// What a finished calibration yields; also the input of the resume path.
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
/// A nil field has not been measured yet.
public struct CalibrationTelemetry: Codable, Equatable, Sendable {
    // State
    public var step: String = CalibrationStep.level.name
    public var stepIndex: Int = CalibrationStep.level.rawValue
    public var cue: String = CalibrationCue.none.rawValue
    public var lightAdvice: String = CalibrationLightAdvice.ok.rawValue
    public var lightCue: String = CalibrationCue.none.rawValue
    public var progress: Double = 0
    public var relaxed: Bool = false
    public var skipped: Bool = false
    public var resumed: Bool = false
    public var capturedFrameCount: Int = 0
    public var holdSampleCount: Int = 0
    public var lastMotionTimestamp: Double?
    public var lastPoseTimestamp: Double?

    // Step 0 / 1 - phone
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

    // Step 2 - framing
    public var shoulderVisibility: Double?
    public var minCoreVisibility: Double?
    public var minFootVisibility: Double?
    public var noseVisibility: Double?
    public var minX: Double?
    public var maxX: Double?
    public var maxFootY: Double?
    public var noseY: Double?
    public var span: Double?
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

    // Step 3 - light
    public var meanLuma: Double?
    public var torsoLuma: Double?
    public var borderLuma: Double?
    public var backlightDelta: Double?
    public var iso: Double?
    public var maxISO: Double?
    public var isoRatio: Double?
    public var exposureSeconds: Double?
    public var lumaOK: Bool?
    public var exposureOK: Bool?
    public var isoOK: Bool?
    public var backlightOK: Bool?
    public var lightOK: Bool?

    // Step 4 - T-pose
    public var tPoseScore: Double?
    public var tPoseSY: Double?
    public var tPoseSExt: Double?
    public var tPoseSSpan: Double?
    public var tPoseSAng: Double?
    public var tPoseExtension: Double?
    public var tPoseHiddenArmPoints: Int?
    public var bodyMotion: Double?
    public var motionLimitUsed: Double?
    public var tPoseOK: Bool?
    public var bodyStillOK: Bool?
    public var poseHoldS: Double?

    public init() {}
}

// MARK: - Gate

/// Pure calibration state machine. Feed it samples from the three streams; read `status`, `telemetry()` and, once
/// locked, `lockedProfile`. `tuning` may be replaced at any time (live tuning); holds keep their progress because
/// they are stored as start timestamps, and the new thresholds apply from the next sample.
public struct CalibrationGate: Sendable {

    public var tuning: CalibrationTuning

    public private(set) var step: CalibrationStep
    public private(set) var cue: CalibrationCue
    public private(set) var progress: Double = 0
    public private(set) var lightAdvice: CalibrationLightAdvice = .ok
    /// True once 15 s (`relaxAfterS`) were spent in step 2: looser visibility and span limits from then on.
    public private(set) var relaxed = false
    public private(set) var skipped = false
    /// True when the lock came from the resume path (previous profile's frames reused).
    public private(set) var resumed = false
    /// Frames captured during the current T-pose hold (all of them once locked).
    public private(set) var capturedFrames: [GrooveScoringEngine.RawPoseFrame] = []
    /// Gravity locked at the end of step 1 (or taken from the resume profile), replaced by the latest reading on
    /// lock. nil before step 1 passes, unless skipped with a motion reading available.
    public private(set) var lockedGravity: [Double]?
    /// Set on lock (nil when skipped).
    public private(set) var lockedProfile: CalibrationProfile?

    public var status: CalibrationStatus {
        CalibrationStatus(step: step, cue: cue, progress: progress, lightAdvice: lightAdvice,
                          relaxed: relaxed, skipped: skipped)
    }

    /// `calibration_frames` for the take: the locked frames, nil when skipped or not locked.
    public var calibrationFrames: [GrooveScoringEngine.RawPoseFrame]? { lockedProfile?.frames }

    private var resumeProfile: CalibrationProfile?
    private var latestMotion: CalibrationMotionSample?
    private var readings = CalibrationTelemetry()

    // Step 1
    private var levelLatched = false
    private var phoneOkSince: Double?
    // Step 2
    private var relaxClockStart: Double?
    private var framingOkSince: Double?
    private var personPresent = false
    // Step 4
    private var frameFailSince: Double?
    private var poseStart: Double?
    private var poseLastGood: Double?
    private var poseLatched = false
    private var holdSamples = 0
    private var lastBody: (sx: Double, sy: Double, hx: Double, hy: Double)?

    /// - Parameter resume: a profile from an earlier calibration. If the phone has not moved (gravity within
    ///   `resumeGravityDeltaG`), only the framing check runs and the lock reuses its frames.
    public init(tuning: CalibrationTuning = .defaults, resume: CalibrationProfile? = nil) {
        self.tuning = tuning
        if let r = resume, !r.frames.isEmpty, r.gravity.count >= 3 {
            resumeProfile = r
            step = .resume
            cue = .none
        } else {
            step = .level
            cue = .placePhone
        }
    }

    /// Starts over from step 1 with the current tuning (no resume).
    public mutating func reset() {
        self = CalibrationGate(tuning: tuning)
    }

    /// The Skip button: lock now with no calibration frames (`calibration_frames = nil`, bone lengths come from
    /// the take, as today). `lockedGravity` is the latest gravity reading, if any.
    public mutating func skip() {
        guard step != .locked else { return }
        skipped = true
        step = .locked
        cue = .none
        progress = 1
        capturedFrames = []
        lockedProfile = nil
        if let m = latestMotion { lockedGravity = m.gravity.array }
    }

    // MARK: Angles

    /// Signed angles in degrees: `rollDeg = atan2(g.x, -g.y)`, `tiltBackDeg = atan2(-g.z, -g.y)`.
    /// With +z out of the screen, leaning the phone back gives `tiltBackDeg > 0` (verify the sign on a device).
    public static func angles(gravity g: CalibrationVector3) -> (rollDeg: Double, tiltBackDeg: Double) {
        (atan2(g.x, -g.y) * 180 / .pi, atan2(-g.z, -g.y) * 180 / .pi)
    }

    // MARK: Motion stream

    @discardableResult
    public mutating func update(motion m: CalibrationMotionSample) -> CalibrationStatus {
        latestMotion = m
        let (roll, tilt) = Self.angles(gravity: m.gravity)
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

        let reference = lockedGravity ?? resumeProfile?.gravity
        let delta = reference.map { m.gravity.distance(to: CalibrationVector3($0)) }
        readings.gravityDeltaG = delta

        switch step {
        case .resume:
            if let delta, let profile = resumeProfile, delta < tuning.resumeGravityDeltaG {
                readings.resumeOK = true
                lockedGravity = profile.gravity
                enterFrame()
            } else {
                readings.resumeOK = false
                resumeProfile = nil
                enterLevel()
                processLevel(m, rollOK: rollOK, tiltOK: tiltOK, stillOK: stillOK, tilt: tilt)
            }
        case .level:
            processLevel(m, rollOK: rollOK, tiltOK: tiltOK, stillOK: stillOK, tilt: tilt)
        case .frame, .tpose:
            if let delta, delta > tuning.bumpGravityDeltaG {
                // Phone bumped or moved after it was placed: back to step 1, full flow.
                resumeProfile = nil
                enterLevel()
                processLevel(m, rollOK: rollOK, tiltOK: tiltOK, stillOK: stillOK, tilt: tilt)
            }
        case .locked:
            break
        }
        return status
    }

    private mutating func enterLevel() {
        step = .level
        cue = .placePhone
        progress = 0
        phoneOkSince = nil
        lockedGravity = nil
        framingOkSince = nil
        frameFailSince = nil
        resetPose()
    }

    private mutating func processLevel(_ m: CalibrationMotionSample, rollOK: Bool, tiltOK: Bool, stillOK: Bool,
                                       tilt: Double) {
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
            enterFrame()
        }
    }

    private mutating func enterFrame() {
        step = .frame
        cue = .none
        progress = 0
        framingOkSince = nil
        frameFailSince = nil
        resetPose()
    }

    // MARK: Pose stream

    @discardableResult
    public mutating func update(pose p: CalibrationPoseSample) -> CalibrationStatus {
        let t = p.timestamp
        readings.lastPoseTimestamp = t
        let lm = Landmarks(p.landmarks)

        if step == .frame {
            let start = relaxClockStart ?? t
            relaxClockStart = start
            if t - start >= tuning.relaxAfterS { relaxed = true }
        }
        let passing = step == .tpose || (step == .frame && framingOkSince != nil)
        let framing = evaluateFraming(lm, passing: passing)
        personPresent = framing.presence

        let score = Self.tPoseScore(lm, tuning: tuning)
        recordTPose(score)
        let motion = bodyMotion(lm)
        readings.bodyMotion = motion

        switch step {
        case .resume, .level, .locked:
            break
        case .frame:
            processFrame(t, framing: framing)
        case .tpose:
            processTPose(t, framing: framing, score: score, motion: motion, frame: p.frame)
        }
        return status
    }

    private mutating func processFrame(_ t: Double, framing: Framing) {
        guard framing.cue == .none else {
            framingOkSince = nil
            progress = 0
            cue = framing.cue
            return
        }
        let since = framingOkSince ?? t
        framingOkSince = since
        let held = t - since
        cue = .none
        progress = Self.fraction(held, of: tuning.framingHoldS)
        guard held >= tuning.framingHoldS else { return }
        if let profile = resumeProfile {
            // Resume: the phone has not moved and the dancer is framed; reuse the stored stance.
            resumed = true
            lock(frames: profile.frames)
        } else {
            step = .tpose
            cue = .armsOutT
            progress = 0
            frameFailSince = nil
            resetPose()
        }
    }

    private mutating func processTPose(_ t: Double, framing: Framing, score: TPoseScore, motion: Double?,
                                       frame: GrooveScoringEngine.RawPoseFrame?) {
        // Framing keeps being checked (with the hold limits); a failure that outlasts the dropout tolerance sends
        // the dancer back to step 2.
        if framing.cue != .none {
            let since = frameFailSince ?? t
            frameFailSince = since
            if t - since > tuning.dropoutToleranceS {
                step = .frame
                cue = framing.cue
                progress = 0
                framingOkSince = nil
                frameFailSince = nil
                resetPose()
                return
            }
        } else {
            frameFailSince = nil
        }

        let motionLimit = poseLatched ? tuning.motionStayMax : tuning.motionEnterMax
        let still = motion.map { $0 <= motionLimit } ?? false
        readings.motionLimitUsed = motionLimit
        readings.bodyStillOK = still
        let good = framing.cue == .none && score.passes && still

        if good {
            if let last = poseLastGood, t - last > tuning.dropoutToleranceS { resetPose() }
            if poseStart == nil {
                poseStart = t
                capturedFrames = []
                holdSamples = 0
            }
            poseLatched = true
            poseLastGood = t
            holdSamples += 1
            if let frame { capturedFrames.append(frame) }
        } else if let last = poseLastGood, t - last <= tuning.dropoutToleranceS {
            // Tolerated dropout: keep the progress, capture nothing.
        } else {
            resetPose()
            progress = 0
            cue = score.passes ? .holdStill : .armsOutT
            return
        }

        let elapsed = t - (poseStart ?? t)
        readings.poseHoldS = elapsed
        cue = .holdStill
        if elapsed >= tuning.poseHoldS && holdSamples >= max(1, tuning.minCapturedFrames) {
            lock(frames: capturedFrames)
        } else {
            progress = min(0.99, Self.fraction(elapsed, of: tuning.poseHoldS))
        }
    }

    private mutating func resetPose() {
        poseStart = nil
        poseLastGood = nil
        poseLatched = false
        holdSamples = 0
        capturedFrames = []
        readings.poseHoldS = nil
    }

    private mutating func lock(frames: [GrooveScoringEngine.RawPoseFrame]) {
        let gravity = latestMotion?.gravity.array ?? lockedGravity ?? [0, -1, 0]
        lockedGravity = gravity
        capturedFrames = frames
        lockedProfile = CalibrationProfile(frames: frames, gravity: gravity)
        step = .locked
        cue = .locked
        progress = 1
    }

    // MARK: Light stream (advice only; never changes the step)

    @discardableResult
    public mutating func update(light l: CalibrationLightSample) -> CalibrationStatus {
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
        r.capturedFrameCount = capturedFrames.count
        r.holdSampleCount = holdSamples
        return r
    }

    // MARK: Framing

    struct Landmarks {
        let points: [CalibrationLandmark]
        init(_ points: [CalibrationLandmark]) { self.points = points }

        subscript(_ name: String) -> CalibrationLandmark? {
            guard let i = CanonicalSkeleton.mediapipeIndex[name], i < points.count else { return nil }
            return points[i]
        }

        func visibility(_ name: String) -> Double { self[name]?.visibility ?? 0 }
    }

    static let coreJoints = ["nose", "leftShoulder", "rightShoulder", "leftHip", "rightHip",
                             "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"]
    static let footJoints = ["leftHeel", "rightHeel", "leftFootIndex", "rightFootIndex"]
    static let legJoints = ["leftKnee", "rightKnee", "leftAnkle", "rightAnkle"]

    struct Framing {
        var cue: CalibrationCue
        var presence: Bool
    }

    /// Runs the step-2 checks on one sample, records every measured value and check, and returns the first
    /// failing check's cue (`.none` when all pass). `passing` selects the looser hold limits (hysteresis).
    mutating func evaluateFraming(_ lm: Landmarks, passing: Bool) -> Framing {
        let u = tuning
        var visDelta = 0.0
        var spanDelta = 0.0
        if relaxed {
            visDelta = max(visDelta, u.relaxVisibilityDelta)
            spanDelta = max(spanDelta, u.relaxSpanDelta)
        }
        if passing {
            visDelta = max(visDelta, u.framingStayVisibilityDelta)
            spanDelta = max(spanDelta, u.framingStaySpanDelta)
        }
        let coreFloor = u.coreMinVisibility - visDelta
        let footFloor = u.footMinVisibility - visDelta
        let spanMin = u.spanMin - spanDelta
        let spanMax = u.spanMax + spanDelta

        let shoulderVis = min(lm.visibility("leftShoulder"), lm.visibility("rightShoulder"))
        let coreVis = Self.coreJoints.map { lm.visibility($0) }.min() ?? 0
        let footVis = Self.footJoints.map { lm.visibility($0) }.min() ?? 0
        let legVis = Self.legJoints.map { lm.visibility($0) }.min() ?? 0
        let noseVis = lm.visibility("nose")
        let pts = (Self.coreJoints + Self.footJoints).compactMap { lm[$0] }
        let minX = pts.map(\.x).min()
        let maxX = pts.map(\.x).max()
        let maxFootY = Self.footJoints.compactMap { lm[$0]?.y }.max()
        let noseY = lm["nose"]?.y
        let span: Double? = {
            guard let f = maxFootY, let n = noseY else { return nil }
            return f - n
        }()
        let hipX: Double? = {
            guard let l = lm["leftHip"], let r = lm["rightHip"] else { return nil }
            return 0.5 * (l.x + r.x)
        }()

        let presence = shoulderVis >= u.presenceMinVisibility
        let coreOK = coreVis >= coreFloor
        let feetOK = footVis >= footFloor
        let headOK = noseVis >= coreFloor
        let leftOut = (minX ?? 0) < u.safeBoxMinX
        let rightOut = (maxX ?? 1) > u.safeBoxMaxX
        let safeOK = !leftOut && !rightOut
        let feetInFrame = (maxFootY ?? 1) <= u.maxFootY
        let headroom = (noseY ?? 0) >= u.minNoseY
        let spanOK = span.map { $0 >= spanMin && $0 <= spanMax } ?? false
        let centred = hipX.map { $0 >= u.hipCenterMinX && $0 <= u.hipCenterMaxX } ?? false

        let cue: CalibrationCue
        if !presence {
            cue = .stepIn
        } else if !feetOK || legVis < coreFloor {
            cue = .stepBackShowFeet
        } else if !headOK {
            cue = .showHead
        } else if !coreOK {
            cue = .stepBack
        } else if !feetInFrame {
            cue = .stepBackShowFeet
        } else if !headroom {
            cue = .stepBack
        } else if let s = span, s > spanMax {
            cue = .stepBack
        } else if !spanOK {
            cue = .stepCloser
        } else if leftOut && rightOut {
            cue = .stepBack
        } else if leftOut {
            cue = .moveLeft     // raw left edge = the dancer's own right side is out
        } else if rightOut {
            cue = .moveRight
        } else if let h = hipX, h < u.hipCenterMinX {
            cue = .moveLeft     // raw x < 0.5 shows on the right of the mirrored preview
        } else if !centred {
            cue = .moveRight
        } else {
            cue = .none
        }

        readings.shoulderVisibility = shoulderVis
        readings.minCoreVisibility = coreVis
        readings.minFootVisibility = footVis
        readings.noseVisibility = noseVis
        readings.minX = minX
        readings.maxX = maxX
        readings.maxFootY = maxFootY
        readings.noseY = noseY
        readings.span = span
        readings.hipCenterX = hipX
        readings.coreFloorUsed = coreFloor
        readings.footFloorUsed = footFloor
        readings.spanMinUsed = spanMin
        readings.spanMaxUsed = spanMax
        readings.presenceOK = presence
        readings.coreVisibleOK = coreOK
        readings.feetVisibleOK = feetOK
        readings.headVisibleOK = headOK
        readings.safeBoxOK = safeOK
        readings.feetInFrameOK = feetInFrame
        readings.headroomOK = headroom
        readings.spanOK = spanOK
        readings.centredOK = centred
        readings.framingOK = cue == .none
        readings.framingCue = cue.rawValue
        return Framing(cue: cue, presence: presence)
    }

    /// Mean shoulder- and hip-midpoint displacement since the previous pose sample, divided by the nose-to-foot
    /// span (Ashrium-style). nil on the first sample or without shoulders, hips and nose.
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

    private mutating func recordTPose(_ s: TPoseScore) {
        readings.tPoseScore = s.score
        readings.tPoseSY = s.sY
        readings.tPoseSExt = s.sExt
        readings.tPoseSSpan = s.sSpan
        readings.tPoseSAng = s.sAng
        readings.tPoseExtension = s.ext
        readings.tPoseHiddenArmPoints = s.hiddenArmPoints
        readings.tPoseOK = s.passes
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
