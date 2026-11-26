import Foundation

// Calibration v2 data model, LiDAR depth/intrinsics inputs, scoring payload, and 3-tier resume classifier.
// Pure Foundation so `swift test --package-path ios/GrooveCore` runs on Linux CI.
// Spec: docs/specs/2026-11-26-calibration-v2-plan.md (§1.2, §3.1, §3.2, §6, §7.1, §8).

// MARK: - Camera Mode & Resume Tier

/// Capture mode across rear TV coaching and front-screen fallback (§1.2).
public enum CameraMode: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case rearLiDAR
    case rearWide
    case frontSelfView

    /// True when capture uses a rear-facing lens (`.rearLiDAR` or `.rearWide`).
    public var isRear: Bool {
        switch self {
        case .rearLiDAR, .rearWide:
            return true
        case .frontSelfView:
            return false
        }
    }

    /// True when LiDAR depth samples are expected (`.rearLiDAR`).
    public var usesLiDAR: Bool {
        self == .rearLiDAR
    }

    /// Converts CoreMotion device-frame gravity `[gx, gy, gz]` into `CanonicalSkeleton` camera axes
    /// (`+x` un-mirrored image-right, `+y` image-up, `+z` dancer-toward-lens; §1.2).
    public func cameraFrameGravity(fromDeviceGravity g: [Double]) -> [Double] {
        let gx = g.count > 0 ? g[0] : 0.0
        let gy = g.count > 1 ? g[1] : -1.0
        let gz = g.count > 2 ? g[2] : 0.0
        switch self {
        case .rearLiDAR, .rearWide:
            return [gx, gy, gz]
        case .frontSelfView:
            return [-gx, gy, -gz]
        }
    }
}

/// Three-tier re-calibration policy (§6.2). Raw value matches `CalibrationTelemetry.calibrationTier`.
public enum CalibrationResumeTier: Int, Codable, Equatable, Hashable, Sendable, CaseIterable {
    /// Instant in-session resume (~0.5–1.0 s): `.resume (0) -> .rest (2) -> .locked (13)`.
    case tier0InstantResume = 0
    /// Environment re-calibration (~4–6 s): `.level (1) -> .rest (2) -> .locked (13)`, reusing `body`.
    case tier1EnvironmentOnly = 1
    /// Full 9-pose body + studio calibration (~25–32 s): `.level (1) -> Poses 1–9 -> .locked (13)`.
    case tier2FullCalibration = 2
}

// MARK: - Camera Intrinsics & Pure Depth Stream Input

/// Pinhole camera intrinsics and field-of-view angles in degrees (§3.1, §3.2, §6.1).
public struct CalibrationIntrinsics: Codable, Equatable, Sendable {
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    public var width: Int
    public var height: Int
    public var horizontalFoVDeg: Double
    public var verticalFoVDeg: Double

    public init(
        fx: Double,
        fy: Double,
        cx: Double,
        cy: Double,
        width: Int,
        height: Int,
        horizontalFoVDeg: Double,
        verticalFoVDeg: Double
    ) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
        self.horizontalFoVDeg = horizontalFoVDeg
        self.verticalFoVDeg = verticalFoVDeg
    }

    /// Portrait narrow-axis FoV from the sensor long-side (portrait vertical) FoV (§3.2):
    /// `thetaH = 2 * atan((9/16) * tan(thetaV / 2))`.
    public static func portraitHorizontalFoVDeg(
        fromVerticalFoVDeg verticalFoVDeg: Double,
        aspectRatio: Double = 9.0 / 16.0
    ) -> Double {
        guard verticalFoVDeg > 0, verticalFoVDeg < 180.0, aspectRatio > 0 else { return 0.0 }
        let halfRad = (verticalFoVDeg * .pi / 180.0) * 0.5
        return 2.0 * atan(aspectRatio * tan(halfRad)) * 180.0 / .pi
    }

    /// Constructs intrinsics and derives pinhole `horizontalFoVDeg` and `verticalFoVDeg` from `(width, height, fx, fy)`.
    public static func fromPinhole(
        fx: Double,
        fy: Double,
        cx: Double,
        cy: Double,
        width: Int,
        height: Int
    ) -> CalibrationIntrinsics {
        let hFoV = (fx > 0 && width > 0) ? (2.0 * atan(Double(width) / (2.0 * fx)) * 180.0 / .pi) : 0.0
        let vFoV = (fy > 0 && height > 0) ? (2.0 * atan(Double(height) / (2.0 * fy)) * 180.0 / .pi) : 0.0
        return CalibrationIntrinsics(
            fx: fx,
            fy: fy,
            cx: cx,
            cy: cy,
            width: width,
            height: height,
            horizontalFoVDeg: hFoV,
            verticalFoVDeg: vFoV
        )
    }

    /// Linearly scales `(fx, fy, cx, cy)` from `(width, height)` to target map dimensions (§3.1).
    public func scaled(toWidth targetWidth: Int, height targetHeight: Int) -> CalibrationIntrinsics {
        guard width > 0, height > 0, targetWidth > 0, targetHeight > 0 else { return self }
        let sx = Double(targetWidth) / Double(width)
        let sy = Double(targetHeight) / Double(height)
        return CalibrationIntrinsics(
            fx: fx * sx,
            fy: fy * sy,
            cx: cx * sx,
            cy: cy * sy,
            width: targetWidth,
            height: targetHeight,
            horizontalFoVDeg: horizontalFoVDeg,
            verticalFoVDeg: verticalFoVDeg
        )
    }

    /// Back-projects pixel `(u, v)` (`u` right, `v` down) at optical depth `depthM > 0` into `CanonicalSkeleton`
    /// right-handed camera coordinates (`+X` right, `+Y` up, `+Z` toward lens; §3.1).
    public func backProjectToCanonical(u: Double, v: Double, depthM: Double) -> CalibrationVector3 {
        guard fx > 0, fy > 0 else { return CalibrationVector3(x: 0, y: 0, z: -depthM) }
        let xCam = (u - cx) * depthM / fx
        let yCam = -(v - cy) * depthM / fy
        let zCam = -depthM
        return CalibrationVector3(x: xCam, y: yCam, z: zCam)
    }
}

/// Pure scalar/vector depth reading fed to `CalibrationGate.update(depth:)` (§7.1).
public struct CalibrationDepthSample: Codable, Equatable, Sendable {
    /// Seconds on the depth/pose monotonic clock.
    public var timestamp: Double
    /// Median LiDAR torso distance (m); nil when no person patch is valid.
    public var dancerDistanceM: Double?
    /// Metric crown-to-floor dancer height (m) via LiDAR floor plane + `baby.py` 1.15 rule (§3.5).
    public var measuredHeightM: Double?
    /// Perpendicular height of the camera lens above the RANSAC floor plane (m; §3.4).
    public var cameraHeightM: Double?
    /// Upward unit floor normal in `CanonicalSkeleton` camera space (§3.4).
    public var floorNormal: CalibrationVector3?
    /// Metric 3D bone segment lengths (m) keyed by canonical child joint name (§1.2).
    public var lidarBoneLengthsM: [String: Double]
    /// `depthM(shoulder) - depthM(wrist)` (m) for Pose 5 `.armsForward` (§2.2).
    public var shoulderToWristDeltaZM: Double?
    /// Portrait vertical FoV in degrees (`AVCaptureDevice.Format.videoFieldOfView`; §3.2).
    public var verticalFoVDeg: Double?
    /// Optional camera intrinsics associated with this sample (§3.1).
    public var intrinsics: CalibrationIntrinsics?

    public init(
        timestamp: Double,
        dancerDistanceM: Double? = nil,
        measuredHeightM: Double? = nil,
        cameraHeightM: Double? = nil,
        floorNormal: CalibrationVector3? = nil,
        lidarBoneLengthsM: [String: Double] = [:],
        shoulderToWristDeltaZM: Double? = nil,
        verticalFoVDeg: Double? = nil,
        intrinsics: CalibrationIntrinsics? = nil
    ) {
        self.timestamp = timestamp
        self.dancerDistanceM = dancerDistanceM
        self.measuredHeightM = measuredHeightM
        self.cameraHeightM = cameraHeightM
        self.floorNormal = floorNormal
        self.lidarBoneLengthsM = lidarBoneLengthsM
        self.shoulderToWristDeltaZM = shoulderToWristDeltaZM
        self.verticalFoVDeg = verticalFoVDeg
        self.intrinsics = intrinsics
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case dancerDistanceM
        case measuredHeightM
        case cameraHeightM
        case floorNormal
        case lidarBoneLengthsM
        case shoulderToWristDeltaZM
        case verticalFoVDeg
        case intrinsics
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Double.self, forKey: .timestamp)
        dancerDistanceM = try c.decodeIfPresent(Double.self, forKey: .dancerDistanceM)
        measuredHeightM = try c.decodeIfPresent(Double.self, forKey: .measuredHeightM)
        cameraHeightM = try c.decodeIfPresent(Double.self, forKey: .cameraHeightM)
        floorNormal = try c.decodeIfPresent(CalibrationVector3.self, forKey: .floorNormal)
        lidarBoneLengthsM = try c.decodeIfPresent([String: Double].self, forKey: .lidarBoneLengthsM) ?? [:]
        shoulderToWristDeltaZM = try c.decodeIfPresent(Double.self, forKey: .shoulderToWristDeltaZM)
        verticalFoVDeg = try c.decodeIfPresent(Double.self, forKey: .verticalFoVDeg)
        intrinsics = try c.decodeIfPresent(CalibrationIntrinsics.self, forKey: .intrinsics)
    }
}

// MARK: - Range of Motion & Scoring Calibration Payload

/// Calibrated dancer range-of-motion summary across Poses 1, 3, 6, and 9 (§6.1, §8.2).
public struct CalibrationROM: Codable, Equatable, Sendable {
    public var standingKneeFlexDeg: Double
    public var plieKneeFlexDeg: Double
    public var plieHipDropNorm: Double
    public var maxShoulderElevationDeg: Double
    public var maxKneeLiftFlexDeg: Double
    public var trunkLeanBaselineDeg: Double

    public init(
        standingKneeFlexDeg: Double = 0.0,
        plieKneeFlexDeg: Double = 35.0,
        plieHipDropNorm: Double = 0.08,
        maxShoulderElevationDeg: Double = 180.0,
        maxKneeLiftFlexDeg: Double = 75.0,
        trunkLeanBaselineDeg: Double = 0.0
    ) {
        self.standingKneeFlexDeg = standingKneeFlexDeg
        self.plieKneeFlexDeg = plieKneeFlexDeg
        self.plieHipDropNorm = plieHipDropNorm
        self.maxShoulderElevationDeg = maxShoulderElevationDeg
        self.maxKneeLiftFlexDeg = maxKneeLiftFlexDeg
        self.trunkLeanBaselineDeg = trunkLeanBaselineDeg
    }
}

/// Deterministic scoring/retargeting calibration payload attached to `PoseClip.calibration_v2` (§8).
/// Mirrors the `"calibration_v2"` dictionary consumed by `groove_eval/scoring.py` and `groove_eval/retarget.py`.
public struct LearnerCalibrationV2: Codable, Equatable, Sendable {
    public typealias ROM = CalibrationROM

    public var schema: String
    public var metricScaleFactor: Double
    public var dancerHeightM: Double?
    public var wingspanM: Double?
    public var boneLengthsM: [String: Double]
    public var rom: CalibrationROM?
    public var jointConfidenceWeights: [String: Double]

    public init(
        schema: String = CalibrationProfileV2.currentSchema,
        metricScaleFactor: Double = 1.0,
        dancerHeightM: Double? = nil,
        wingspanM: Double? = nil,
        boneLengthsM: [String: Double] = [:],
        rom: CalibrationROM? = nil,
        jointConfidenceWeights: [String: Double] = [:]
    ) {
        self.schema = schema
        self.metricScaleFactor = metricScaleFactor
        self.dancerHeightM = dancerHeightM
        self.wingspanM = wingspanM
        self.boneLengthsM = boneLengthsM
        self.rom = rom
        self.jointConfidenceWeights = jointConfidenceWeights
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case metricScaleFactor
        case dancerHeightM
        case wingspanM
        case boneLengthsM
        case rom
        case jointConfidenceWeights
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? CalibrationProfileV2.currentSchema
        metricScaleFactor = try c.decodeIfPresent(Double.self, forKey: .metricScaleFactor) ?? 1.0
        dancerHeightM = try c.decodeIfPresent(Double.self, forKey: .dancerHeightM)
        wingspanM = try c.decodeIfPresent(Double.self, forKey: .wingspanM)
        boneLengthsM = try c.decodeIfPresent([String: Double].self, forKey: .boneLengthsM) ?? [:]
        rom = try c.decodeIfPresent(CalibrationROM.self, forKey: .rom)
        jointConfidenceWeights = try c.decodeIfPresent([String: Double].self, forKey: .jointConfidenceWeights) ?? [:]
    }
}

// MARK: - CalibrationProfileV2 (`groove.calibration/2`)

/// Persisted studio + dancer calibration profile (`groove.calibration/2`, §6.1).
public struct CalibrationProfileV2: Codable, Equatable, Sendable {
    public static let currentSchema = "groove.calibration/2"
    public static let currentSchemaVersion = 2
    /// Default 30-day profile validity window for Tier-1 reuse before requiring a full 9-pose Tier-2 run (§6.2).
    public static let maxProfileAgeSeconds: Double = 30.0 * 24.0 * 3600.0
    /// Fallback standing adult height (m) before LiDAR measures `dancerHeightM` (§3.2, §3.5).
    public static let defaultDancerHeightM: Double = 1.76
    /// Default wrist-to-wrist wingspan-to-height ratio before Pose 2 measures `wingspanM` (§3.2).
    public static let defaultWingspanToHeightRatio: Double = 0.85

    public typealias ROM = CalibrationROM

    /// Fitted LiDAR floor plane in `CanonicalSkeleton` camera space (§3.4, §6.1).
    public struct FloorPlane: Codable, Equatable, Sendable {
        /// Upward unit floor normal `[nx, ny, nz]` in canonical camera space.
        public var normal: [Double]
        /// Perpendicular height of lens above floor (m).
        public var cameraHeightM: Double
        /// Angular disagreement (deg) between `normal` and `-normalize(cameraGravity)` (§3.4).
        public var lidarGravityDisagreementDeg: Double

        public init(
            normal: [Double],
            cameraHeightM: Double,
            lidarGravityDisagreementDeg: Double
        ) {
            self.normal = normal
            self.cameraHeightM = cameraHeightM
            self.lidarGravityDisagreementDeg = lidarGravityDisagreementDeg
        }

        public var normalVector: CalibrationVector3 {
            CalibrationVector3(normal)
        }
    }

    /// Session/placement environment fields invalidated when the phone moves (§6.1).
    public struct Environment: Codable, Equatable, Sendable {
        /// CoreMotion device-frame gravity `[gx, gy, gz]` (g).
        public var gravity: [Double]
        public var rollDeg: Double
        public var tiltBackDeg: Double
        public var intrinsics: CalibrationIntrinsics?
        public var floorPlane: FloorPlane?
        public var effectiveMinDistanceM: Double?
        public var dancerDistanceM: Double?
        public var usableLateralSpanM: Double?
        public var overheadHeadroomMinY: Double?
        public var lockedMeanLuma: Double?
        public var exposureLockedISO: Double?
        public var exposureLockedDurationS: Double?
        public var airplayRouteOffsetsMs: [String: Double]
        public var tvVideoLeadOffsetMs: Double

        public init(
            gravity: [Double],
            rollDeg: Double,
            tiltBackDeg: Double,
            intrinsics: CalibrationIntrinsics? = nil,
            floorPlane: FloorPlane? = nil,
            effectiveMinDistanceM: Double? = nil,
            dancerDistanceM: Double? = nil,
            usableLateralSpanM: Double? = nil,
            overheadHeadroomMinY: Double? = nil,
            lockedMeanLuma: Double? = nil,
            exposureLockedISO: Double? = nil,
            exposureLockedDurationS: Double? = nil,
            airplayRouteOffsetsMs: [String: Double] = [:],
            tvVideoLeadOffsetMs: Double = 0.0
        ) {
            self.gravity = gravity
            self.rollDeg = rollDeg
            self.tiltBackDeg = tiltBackDeg
            self.intrinsics = intrinsics
            self.floorPlane = floorPlane
            self.effectiveMinDistanceM = effectiveMinDistanceM
            self.dancerDistanceM = dancerDistanceM
            self.usableLateralSpanM = usableLateralSpanM
            self.overheadHeadroomMinY = overheadHeadroomMinY
            self.lockedMeanLuma = lockedMeanLuma
            self.exposureLockedISO = exposureLockedISO
            self.exposureLockedDurationS = exposureLockedDurationS
            self.airplayRouteOffsetsMs = airplayRouteOffsetsMs
            self.tvVideoLeadOffsetMs = tvVideoLeadOffsetMs
        }

        private enum CodingKeys: String, CodingKey {
            case gravity
            case rollDeg
            case tiltBackDeg
            case intrinsics
            case floorPlane
            case effectiveMinDistanceM
            case dancerDistanceM
            case usableLateralSpanM
            case overheadHeadroomMinY
            case lockedMeanLuma
            case exposureLockedISO
            case exposureLockedDurationS
            case airplayRouteOffsetsMs
            case tvVideoLeadOffsetMs
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            gravity = try c.decode([Double].self, forKey: .gravity)
            rollDeg = try c.decode(Double.self, forKey: .rollDeg)
            tiltBackDeg = try c.decode(Double.self, forKey: .tiltBackDeg)
            intrinsics = try c.decodeIfPresent(CalibrationIntrinsics.self, forKey: .intrinsics)
            floorPlane = try c.decodeIfPresent(FloorPlane.self, forKey: .floorPlane)
            effectiveMinDistanceM = try c.decodeIfPresent(Double.self, forKey: .effectiveMinDistanceM)
            dancerDistanceM = try c.decodeIfPresent(Double.self, forKey: .dancerDistanceM)
            usableLateralSpanM = try c.decodeIfPresent(Double.self, forKey: .usableLateralSpanM)
            overheadHeadroomMinY = try c.decodeIfPresent(Double.self, forKey: .overheadHeadroomMinY)
            lockedMeanLuma = try c.decodeIfPresent(Double.self, forKey: .lockedMeanLuma)
            exposureLockedISO = try c.decodeIfPresent(Double.self, forKey: .exposureLockedISO)
            exposureLockedDurationS = try c.decodeIfPresent(Double.self, forKey: .exposureLockedDurationS)
            airplayRouteOffsetsMs = try c.decodeIfPresent([String: Double].self, forKey: .airplayRouteOffsetsMs) ?? [:]
            tvVideoLeadOffsetMs = try c.decodeIfPresent(Double.self, forKey: .tvVideoLeadOffsetMs) ?? 0.0
        }
    }

    /// Dancer anatomical, ROM, and joint reliability fields reusable across sessions (§6.1).
    public struct Body: Codable, Equatable, Sendable {
        /// Canonical child-joint keys whose lengths sum to wrist-to-wrist `wingspanM` (§2.2 Pose 2, §6.1).
        public static let wingspanBoneKeys: [String] = [
            "leftShoulder", "leftElbow", "leftWrist",
            "rightShoulder", "rightElbow", "rightWrist"
        ]

        /// Metric dancer height (m) when calibrated with LiDAR; `nil` in `frontSelfView` / monocular fallback (§6.2).
        public var dancerHeightM: Double?
        /// Ratio `median(L_lidar / L_mp)` mapping MediaPipe world bones to physical metres (`1.0` without LiDAR).
        public var metricScaleFactor: Double
        /// Calibrated wrist-to-wrist lateral T-pose span (m): sum of L/R `shoulder + elbow + wrist` segments (§2.2, §6.1).
        public var wingspanM: Double
        /// True once Pose 4 (`.asymLR`) verified left/right non-swapping (§2.2).
        public var lrVerified: Bool
        /// Ratio `leftArmM / rightArmM` from Pose 4 (`.asymLR`).
        public var armSymmetryRatio: Double?
        /// Ratio `deltaZ_lidar / deltaZ_canonical` from Pose 5 (`.armsForward`).
        public var zDepthScaleRatio: Double?
        /// Per-bone metric lengths (m) keyed by canonical child joint name (`Retarget.canonicalBones`).
        public var boneLengthsM: [String: Double]
        /// Range-of-motion summary across Poses 1, 3, 6, and 9.
        public var rom: CalibrationROM
        /// Per-joint reliability weights clamped to `[0.50, 1.00]` (§8.3).
        public var jointConfidenceWeights: [String: Double]
        /// Un-mirrored canonical frames captured during Pose 2 (`.tpose`) for legacy `PoseClip.calibration_frames`.
        public var calibrationFrames: [GrooveScoringEngine.RawPoseFrame]

        public init(
            dancerHeightM: Double? = nil,
            metricScaleFactor: Double = 1.0,
            wingspanM: Double? = nil,
            lrVerified: Bool = true,
            armSymmetryRatio: Double? = nil,
            zDepthScaleRatio: Double? = nil,
            boneLengthsM: [String: Double] = [:],
            rom: CalibrationROM = CalibrationROM(),
            jointConfidenceWeights: [String: Double] = [:],
            calibrationFrames: [GrooveScoringEngine.RawPoseFrame] = []
        ) {
            self.dancerHeightM = dancerHeightM
            self.metricScaleFactor = metricScaleFactor
            self.wingspanM = wingspanM
                ?? Self.wristToWristWingspanM(from: boneLengthsM)
                ?? (CalibrationProfileV2.defaultWingspanToHeightRatio * (dancerHeightM ?? CalibrationProfileV2.defaultDancerHeightM))
            self.lrVerified = lrVerified
            self.armSymmetryRatio = armSymmetryRatio
            self.zDepthScaleRatio = zDepthScaleRatio
            self.boneLengthsM = boneLengthsM
            self.rom = rom
            self.jointConfidenceWeights = jointConfidenceWeights
            self.calibrationFrames = calibrationFrames
        }

        /// Sums the 6 canonical L/R arm segment lengths (`shoulder + elbow + wrist` per side) in `boneLengthsM`,
        /// returning `nil` unless all 6 segments are present and positive.
        public static func wristToWristWingspanM(from boneLengthsM: [String: Double]) -> Double? {
            var sum = 0.0
            for key in wingspanBoneKeys {
                guard let len = boneLengthsM[key], len.isFinite, len > 0 else { return nil }
                sum += len
            }
            return sum
        }

        private enum CodingKeys: String, CodingKey {
            case dancerHeightM
            case metricScaleFactor
            case wingspanM
            case lrVerified
            case armSymmetryRatio
            case zDepthScaleRatio
            case boneLengthsM
            case rom
            case jointConfidenceWeights
            case calibrationFrames
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let decodedHeight = try c.decodeIfPresent(Double.self, forKey: .dancerHeightM)
            let decodedBones = try c.decodeIfPresent([String: Double].self, forKey: .boneLengthsM) ?? [:]
            dancerHeightM = decodedHeight
            metricScaleFactor = try c.decodeIfPresent(Double.self, forKey: .metricScaleFactor) ?? 1.0
            if let explicitWingspan = try c.decodeIfPresent(Double.self, forKey: .wingspanM) {
                wingspanM = explicitWingspan
            } else {
                wingspanM = Self.wristToWristWingspanM(from: decodedBones)
                    ?? (CalibrationProfileV2.defaultWingspanToHeightRatio * (decodedHeight ?? CalibrationProfileV2.defaultDancerHeightM))
            }
            lrVerified = try c.decodeIfPresent(Bool.self, forKey: .lrVerified) ?? false
            armSymmetryRatio = try c.decodeIfPresent(Double.self, forKey: .armSymmetryRatio)
            zDepthScaleRatio = try c.decodeIfPresent(Double.self, forKey: .zDepthScaleRatio)
            boneLengthsM = decodedBones
            rom = try c.decodeIfPresent(CalibrationROM.self, forKey: .rom) ?? CalibrationROM()
            jointConfidenceWeights = try c.decodeIfPresent([String: Double].self, forKey: .jointConfidenceWeights) ?? [:]
            calibrationFrames = try c.decodeIfPresent([GrooveScoringEngine.RawPoseFrame].self, forKey: .calibrationFrames) ?? []
        }

        public static func == (lhs: Body, rhs: Body) -> Bool {
            lhs.dancerHeightM == rhs.dancerHeightM
                && lhs.metricScaleFactor == rhs.metricScaleFactor
                && lhs.wingspanM == rhs.wingspanM
                && lhs.lrVerified == rhs.lrVerified
                && lhs.armSymmetryRatio == rhs.armSymmetryRatio
                && lhs.zDepthScaleRatio == rhs.zDepthScaleRatio
                && lhs.boneLengthsM == rhs.boneLengthsM
                && lhs.rom == rhs.rom
                && lhs.jointConfidenceWeights == rhs.jointConfidenceWeights
                && Self.framesEqual(lhs.calibrationFrames, rhs.calibrationFrames)
        }

        private static func framesEqual(
            _ a: [GrooveScoringEngine.RawPoseFrame],
            _ b: [GrooveScoringEngine.RawPoseFrame]
        ) -> Bool {
            guard a.count == b.count else { return false }
            for (fa, fb) in zip(a, b) {
                if fa.t != fb.t
                    || fa.joints != fb.joints
                    || fa.confidences != fb.confidences
                    || fa.hands != fb.hands {
                    return false
                }
            }
            return true
        }
    }

    public var schema: String
    public var schemaVersion: Int
    /// ISO-8601 UTC timestamp (e.g. `"2026-11-26T02:15:00Z"`).
    public var calibratedAt: String
    public var deviceModel: String
    public var cameraMode: CameraMode
    public var environment: Environment
    public var body: Body

    public init(
        schema: String = CalibrationProfileV2.currentSchema,
        schemaVersion: Int = CalibrationProfileV2.currentSchemaVersion,
        calibratedAt: String? = nil,
        deviceModel: String = "unknown",
        cameraMode: CameraMode,
        environment: Environment,
        body: Body
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.calibratedAt = calibratedAt ?? Self.formatTimestamp(Date())
        self.deviceModel = deviceModel
        self.cameraMode = cameraMode
        self.environment = environment
        self.body = body
    }

    // MARK: - Timestamp Helpers

    /// Formats a `Date` as an ISO-8601 UTC timestamp (`"yyyy-MM-dd'T'HH:mm:ssZ"`).
    public static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Parses an ISO-8601 timestamp string (with or without fractional seconds).
    public static func parseTimestamp(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: text) { return d }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// Parsed `Date` of `calibratedAt`, or `nil` if malformed.
    public var calibratedAtDate: Date? {
        Self.parseTimestamp(calibratedAt)
    }

    /// True when `schema == "groove.calibration/2"` and `schemaVersion == 2`.
    public var isValidSchema: Bool {
        schema == Self.currentSchema && schemaVersion == Self.currentSchemaVersion
    }

    // MARK: - Bridges

    /// Bridges this v2 profile to v1 `CalibrationProfile` (`calibrationFrames` + device `gravity`).
    public var legacyProfile: CalibrationProfile {
        CalibrationProfile(frames: body.calibrationFrames, gravity: environment.gravity)
    }

    /// Camera-frame gravity vector for `PoseClip.gravity_vector` (§1.2).
    public var cameraFrameGravity: [Double] {
        cameraMode.cameraFrameGravity(fromDeviceGravity: environment.gravity)
    }

    /// Extracts the deterministic scoring/retargeting payload (`PoseClip.calibration_v2`, §8).
    public var asScoringCalibration: LearnerCalibrationV2 {
        LearnerCalibrationV2(
            schema: schema,
            metricScaleFactor: body.metricScaleFactor,
            dancerHeightM: body.dancerHeightM,
            wingspanM: body.wingspanM,
            boneLengthsM: body.boneLengthsM,
            rom: body.rom,
            jointConfidenceWeights: body.jointConfidenceWeights
        )
    }

    // MARK: - Three-Tier Re-Calibration Classifier (§6.2)

    /// Unsigned angle in degrees `[0, 180]` between two 3D vectors (`180` if either vector is near-zero).
    public static func angleBetweenDeg(_ a: CalibrationVector3, _ b: CalibrationVector3) -> Double {
        let na = a.norm
        let nb = b.norm
        guard na > 1e-9, nb > 1e-9 else { return 180.0 }
        let cosTheta = max(-1.0, min(1.0, (a.x * b.x + a.y * b.y + a.z * b.z) / (na * nb)))
        return acos(cosTheta) * 180.0 / .pi
    }

    /// Classifies whether calibration should run Tier 0 (instant in-session resume), Tier 1 (environment-only
    /// re-calibration reusing `body`), or Tier 2 (full 9-pose body + studio calibration) per §6.2.
    public static func classifyResumeTier(
        stored: CalibrationProfileV2?,
        cameraMode: CameraMode,
        isSameSession: Bool,
        forceFullRecalibration: Bool = false,
        now: Date = Date(),
        maxAgeSeconds: Double = maxProfileAgeSeconds,
        currentGravity: CalibrationVector3? = nil,
        gravityDeltaG: Double? = nil,
        liveCameraHeightM: Double? = nil,
        liveFloorNormal: CalibrationVector3? = nil,
        floorNormalAngleDeltaDeg: Double? = nil,
        measuredDancerHeightM: Double? = nil,
        tuning: CalibrationTuning = .defaults
    ) -> CalibrationResumeTier {
        // Tier 2 (e): explicit user recalibration request.
        if forceFullRecalibration {
            return .tier2FullCalibration
        }

        // Tier 2 (a): missing or wrong schema version.
        guard let stored, stored.isValidSchema else {
            return .tier2FullCalibration
        }

        // Tier 2 (b): profile older than 30 days (or unparseable timestamp).
        guard let calibratedDate = stored.calibratedAtDate else {
            return .tier2FullCalibration
        }
        if now.timeIntervalSince(calibratedDate) > maxAgeSeconds {
            return .tier2FullCalibration
        }

        // Tier 2 (c): rearLiDAR active now while stored profile lacked LiDAR body calibration (e.g. frontSelfView).
        if cameraMode == .rearLiDAR && (stored.cameraMode != .rearLiDAR || stored.body.dancerHeightM == nil) {
            return .tier2FullCalibration
        }

        // Tier 2 (d): LiDAR detects a different dancer (`|measuredHeightM - body.dancerHeightM| > 0.06 m`).
        if let measuredH = measuredDancerHeightM, let storedH = stored.body.dancerHeightM {
            if abs(measuredH - storedH) > tuning.sameDancerHeightDeltaM {
                return .tier2FullCalibration
            }
        }

        // Tier 0 requires same app session and same cameraMode; otherwise Tier 1 re-measures environment.
        guard isSameSession, cameraMode == stored.cameraMode else {
            return .tier1EnvironmentOnly
        }

        // Tier 0 requires CoreMotion `gravityDeltaG < resumeGravityDeltaG` (0.05 g).
        let resolvedGravityDeltaG: Double? = gravityDeltaG ?? {
            guard let g = currentGravity, stored.environment.gravity.count >= 3 else { return nil }
            return g.distance(to: CalibrationVector3(stored.environment.gravity))
        }()
        guard let gDelta = resolvedGravityDeltaG, gDelta < tuning.resumeGravityDeltaG else {
            return .tier1EnvironmentOnly
        }

        // When rearLiDAR is active, Tier 0 also requires LiDAR camera-height & floor-normal stability.
        if cameraMode == .rearLiDAR {
            guard let storedFloor = stored.environment.floorPlane,
                  let liveH = liveCameraHeightM,
                  abs(liveH - storedFloor.cameraHeightM) < tuning.resumeFloorHeightDeltaM else {
                return .tier1EnvironmentOnly
            }
            let resolvedFloorAngleDeg: Double? = floorNormalAngleDeltaDeg ?? {
                guard let liveN = liveFloorNormal, storedFloor.normal.count >= 3 else { return nil }
                return angleBetweenDeg(liveN, CalibrationVector3(storedFloor.normal))
            }()
            guard let floorAngle = resolvedFloorAngleDeg, floorAngle < tuning.resumeFloorAngleDeg else {
                return .tier1EnvironmentOnly
            }
        }

        return .tier0InstantResume
    }

    /// Instance convenience wrapper for `Self.classifyResumeTier(stored: self, ...)`.
    public func resumeTier(
        cameraMode: CameraMode,
        isSameSession: Bool,
        forceFullRecalibration: Bool = false,
        now: Date = Date(),
        maxAgeSeconds: Double = maxProfileAgeSeconds,
        currentGravity: CalibrationVector3? = nil,
        gravityDeltaG: Double? = nil,
        liveCameraHeightM: Double? = nil,
        liveFloorNormal: CalibrationVector3? = nil,
        floorNormalAngleDeltaDeg: Double? = nil,
        measuredDancerHeightM: Double? = nil,
        tuning: CalibrationTuning = .defaults
    ) -> CalibrationResumeTier {
        Self.classifyResumeTier(
            stored: self,
            cameraMode: cameraMode,
            isSameSession: isSameSession,
            forceFullRecalibration: forceFullRecalibration,
            now: now,
            maxAgeSeconds: maxAgeSeconds,
            currentGravity: currentGravity,
            gravityDeltaG: gravityDeltaG,
            liveCameraHeightM: liveCameraHeightM,
            liveFloorNormal: liveFloorNormal,
            floorNormalAngleDeltaDeg: floorNormalAngleDeltaDeg,
            measuredDancerHeightM: measuredDancerHeightM,
            tuning: tuning
        )
    }

    /// Same-dancer check at the end of Tier-1 Pose 1 (`.rest`, §6.2):
    /// returns `true` when `body` can be reused to jump directly to `.locked (13)`, or `false` when
    /// calibration must escalate to Tier 2 (Poses 2–9).
    public func canReuseBody(
        measuredDancerHeightM: Double?,
        cameraMode: CameraMode,
        tuning: CalibrationTuning = .defaults
    ) -> Bool {
        guard isValidSchema else { return false }
        if cameraMode == .rearLiDAR {
            guard let storedH = body.dancerHeightM, let measuredH = measuredDancerHeightM else {
                return false
            }
            return abs(measuredH - storedH) <= tuning.sameDancerHeightDeltaM
        }
        if let storedH = body.dancerHeightM, let measuredH = measuredDancerHeightM {
            return abs(measuredH - storedH) <= tuning.sameDancerHeightDeltaM
        }
        return true
    }
}
