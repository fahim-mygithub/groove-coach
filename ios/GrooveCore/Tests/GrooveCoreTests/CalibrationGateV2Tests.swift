import Foundation
import XCTest
@testable import GrooveCore

final class CalibrationGateV2Tests: XCTestCase {

    // MARK: - Studio Geometry & Synthetic 9-Pose Fixtures (§6.1)

    private static let studioIntrinsics = CalibrationIntrinsics.fromPinhole(
        fx: 959.6,
        fy: 959.6,
        cx: 360.0,
        cy: 640.0,
        width: 720,
        height: 1280
    )

    /// Rear camera aimed upward by ~+9.9° (`g.z > 0`), slight 0.7° roll (§6.1).
    private static let rearStudioGravity = CalibrationVector3(x: 0.012, y: -0.985, z: 0.172)
    /// Canonical upward floor normal agreeing with `-normalize(rearStudioGravity)` to ~0.4° (§6.1).
    private static let studioFloorNormal = CalibrationVector3(x: -0.010, y: 0.986, z: -0.166)

    /// Un-mirrored 2D standing landmarks scaled around hip center so standing `span ≈ 0.404` at `2.85 m` (§6.1).
    private static let standing2DAt2p85m: [String: (x: Double, y: Double)] = [
        "nose": (0.50, 0.430),
        "leftShoulder": (0.545, 0.485), "rightShoulder": (0.455, 0.485),
        "leftElbow": (0.560, 0.560), "rightElbow": (0.440, 0.560),
        "leftWrist": (0.568, 0.630), "rightWrist": (0.432, 0.630),
        "leftHip": (0.530, 0.630), "rightHip": (0.470, 0.630),
        "leftKnee": (0.530, 0.730), "rightKnee": (0.470, 0.730),
        "leftAnkle": (0.530, 0.815), "rightAnkle": (0.470, 0.815),
        "leftHeel": (0.530, 0.826), "rightHeel": (0.470, 0.826),
        "leftFootIndex": (0.536, 0.834), "rightFootIndex": (0.464, 0.834)
    ]

    /// Upright root-centered 3D canonical skeleton in MediaPipe metres (`L_lidar = 1.064 * L_mp` yields §6.1 `boneLengthsM`).
    private static let uprightWorld3D: [String: [Double]] = {
        let invScale = 1.0 / 1.064
        let metricJoints: [String: [Double]] = [
            "root": [0.0, 0.0, 0.0],
            "spine": [0.0, 0.24, 0.0],
            "centerShoulder": [0.0, 0.48, 0.0],
            "nose": [0.0, 0.69, 0.0],
            "leftHip": [0.11, 0.0, 0.0],
            "leftKnee": [0.11, -0.43, 0.0],
            "leftAnkle": [0.11, -0.84, 0.0],
            "leftHeel": [0.11, -0.87, -0.0743],
            "leftFootIndex": [0.11, -0.87, 0.1572],
            "rightHip": [-0.11, 0.0, 0.0],
            "rightKnee": [-0.11, -0.43, 0.0],
            "rightAnkle": [-0.11, -0.84, 0.0],
            "rightHeel": [-0.11, -0.87, -0.0743],
            "rightFootIndex": [-0.11, -0.87, 0.1572],
            "leftShoulder": [0.19, 0.48, 0.0],
            "leftElbow": [0.22, 0.20, 0.0],
            "leftWrist": [0.24, -0.06, 0.0],
            "rightShoulder": [-0.19, 0.48, 0.0],
            "rightElbow": [-0.22, 0.20, 0.0],
            "rightWrist": [-0.24, -0.06, 0.0]
        ]
        return metricJoints.mapValues { coords in coords.map { $0 * invScale } }
    }()

    /// Metric LiDAR bone lengths matching §6.1 (`1.064 * L_mp`, wrist-to-wrist `wingspanM = 1.46 m`).
    private static let studioLidarBoneLengthsM: [String: Double] = [
        "leftShoulder": 0.19, "rightShoulder": 0.19,
        "leftElbow": 0.28, "rightElbow": 0.28,
        "leftWrist": 0.26, "rightWrist": 0.26,
        "leftKnee": 0.43, "rightKnee": 0.43,
        "leftAnkle": 0.41, "rightAnkle": 0.41
    ]

    /// Rotates world-upright `(0, -1, 0)` gravity-aligned 3D coordinates into camera space whose gravity is `camGravity`
    /// (inverse of `applyGravityCorrection`) so `CalibrationPoseScorers` recovers exact world posture under tilted cameras.
    private func rotateWorldToCamera(
        _ worldJoints: [String: [Double]],
        cameraGravity: CalibrationVector3
    ) -> [String: [Double]] {
        let n = cameraGravity.norm
        guard n > 1e-6 else { return worldJoints }
        let gx = cameraGravity.x / n
        let gy = cameraGravity.y / n
        let gz = cameraGravity.z / n
        // Rotate (0, -1, 0) -> (gx, gy, gz): axis = (0, -1, 0) x g = (-gz, 0, gx), cosTheta = -gy.
        let cosTheta = max(-1.0, min(1.0, -gy))
        if abs(1.0 - cosTheta) < 1e-9 { return worldJoints }
        let axisNorm = hypot(gz, gx)
        guard axisNorm > 1e-9 else { return worldJoints }
        let kx = -gz / axisNorm
        let kz = gx / axisNorm
        let sinTheta = (max(0.0, 1.0 - cosTheta * cosTheta)).squareRoot()

        return worldJoints.mapValues { p in
            let x = p[0], y = p[1], z = p[2]
            // k = (kx, 0, kz)
            let kCrossX = -kz * y
            let kCrossY = kz * x - kx * z
            let kCrossZ = kx * y
            let kDotV = kx * x + kz * z
            let rx = x * cosTheta + kCrossX * sinTheta + kx * kDotV * (1.0 - cosTheta)
            let ry = y * cosTheta + kCrossY * sinTheta
            let rz = z * cosTheta + kCrossZ * sinTheta + kz * kDotV * (1.0 - cosTheta)
            return [rx, ry, rz]
        }
    }

    private func makeStudioPoseSample(
        t: Double,
        for step: CalibrationStep,
        cameraGravity: CalibrationVector3 = CalibrationGateV2Tests.rearStudioGravity,
        reversedAsym: Bool = false,
        visibilityOverrides: [String: Double] = [:]
    ) -> CalibrationPoseSample {
        var pts2D = Self.standing2DAt2p85m
        var world3D = Self.uprightWorld3D
        let invScale = 1.0 / 1.064

        switch step {
        case .resume, .level, .rest, .locked:
            break

        case .tpose:
            pts2D["leftElbow"] = (0.635, 0.485)
            pts2D["rightElbow"] = (0.365, 0.485)
            pts2D["leftWrist"] = (0.720, 0.485)
            pts2D["rightWrist"] = (0.280, 0.485)
            world3D["leftShoulder"] = [0.19 * invScale, 0.48 * invScale, 0.0]
            world3D["leftElbow"] = [0.47 * invScale, 0.48 * invScale, 0.0]
            world3D["leftWrist"] = [0.73 * invScale, 0.48 * invScale, 0.0]
            world3D["rightShoulder"] = [-0.19 * invScale, 0.48 * invScale, 0.0]
            world3D["rightElbow"] = [-0.47 * invScale, 0.48 * invScale, 0.0]
            world3D["rightWrist"] = [-0.73 * invScale, 0.48 * invScale, 0.0]

        case .overhead:
            pts2D["leftElbow"] = (0.555, 0.380)
            pts2D["rightElbow"] = (0.445, 0.380)
            pts2D["leftWrist"] = (0.555, 0.310)
            pts2D["rightWrist"] = (0.445, 0.310)
            world3D["leftElbow"] = [0.20 * invScale, 0.76 * invScale, 0.0]
            world3D["leftWrist"] = [0.21 * invScale, 1.02 * invScale, 0.0]
            world3D["rightElbow"] = [-0.20 * invScale, 0.76 * invScale, 0.0]
            world3D["rightWrist"] = [-0.21 * invScale, 1.02 * invScale, 0.0]

        case .asymLR:
            if reversedAsym {
                // Reversed: anatomical right wrist overhead, left wrist horizontal.
                pts2D["rightElbow"] = (0.445, 0.380)
                pts2D["rightWrist"] = (0.445, 0.310)
                pts2D["leftElbow"] = (0.635, 0.485)
                pts2D["leftWrist"] = (0.720, 0.485)
                world3D["rightElbow"] = [-0.20 * invScale, 0.76 * invScale, 0.0]
                world3D["rightWrist"] = [-0.21 * invScale, 1.02 * invScale, 0.0]
                world3D["leftElbow"] = [0.47 * invScale, 0.48 * invScale, 0.0]
                world3D["leftWrist"] = [0.73 * invScale, 0.48 * invScale, 0.0]
            } else {
                // Correct: anatomical left wrist overhead, right wrist horizontal.
                pts2D["leftElbow"] = (0.555, 0.380)
                pts2D["leftWrist"] = (0.555, 0.310)
                pts2D["rightElbow"] = (0.365, 0.485)
                pts2D["rightWrist"] = (0.280, 0.485)
                world3D["leftElbow"] = [0.20 * invScale, 0.76 * invScale, 0.0]
                world3D["leftWrist"] = [0.21 * invScale, 1.02 * invScale, 0.0]
                world3D["rightElbow"] = [-0.47 * invScale, 0.48 * invScale, 0.0]
                world3D["rightWrist"] = [-0.73 * invScale, 0.48 * invScale, 0.0]
            }

        case .armsForward:
            pts2D["leftElbow"] = (0.545, 0.500)
            pts2D["rightElbow"] = (0.455, 0.500)
            pts2D["leftWrist"] = (0.545, 0.495)
            pts2D["rightWrist"] = (0.455, 0.495)
            world3D["leftElbow"] = [0.19 * invScale, 0.46 * invScale, 0.26]
            world3D["leftWrist"] = [0.19 * invScale, 0.46 * invScale, 0.50]
            world3D["rightElbow"] = [-0.19 * invScale, 0.46 * invScale, 0.26]
            world3D["rightWrist"] = [-0.19 * invScale, 0.46 * invScale, 0.50]

        case .plie:
            pts2D["leftElbow"] = (0.635, 0.510)
            pts2D["rightElbow"] = (0.365, 0.510)
            pts2D["leftWrist"] = (0.720, 0.510)
            pts2D["rightWrist"] = (0.280, 0.510)
            pts2D["nose"] = (0.50, 0.465)
            pts2D["leftShoulder"] = (0.545, 0.515)
            pts2D["rightShoulder"] = (0.455, 0.515)
            pts2D["leftHip"] = (0.530, 0.660)
            pts2D["rightHip"] = (0.470, 0.660)
            pts2D["leftKnee"] = (0.548, 0.745)
            pts2D["rightKnee"] = (0.452, 0.745)
            world3D["leftElbow"] = [0.47 * invScale, 0.48 * invScale, 0.0]
            world3D["leftWrist"] = [0.73 * invScale, 0.48 * invScale, 0.0]
            world3D["rightElbow"] = [-0.47 * invScale, 0.48 * invScale, 0.0]
            world3D["rightWrist"] = [-0.73 * invScale, 0.48 * invScale, 0.0]
            world3D["leftKnee"] = [0.16 * invScale, -0.36 * invScale, 0.16 * invScale]
            world3D["leftAnkle"] = [0.11 * invScale, -0.74 * invScale, 0.0]
            world3D["leftHeel"] = [0.11 * invScale, -0.77 * invScale, -0.0743 * invScale]
            world3D["leftFootIndex"] = [0.11 * invScale, -0.77 * invScale, 0.1572 * invScale]
            world3D["rightKnee"] = [-0.16 * invScale, -0.36 * invScale, 0.16 * invScale]
            world3D["rightAnkle"] = [-0.11 * invScale, -0.74 * invScale, 0.0]
            world3D["rightHeel"] = [-0.11 * invScale, -0.77 * invScale, -0.0743 * invScale]
            world3D["rightFootIndex"] = [-0.11 * invScale, -0.77 * invScale, 0.1572 * invScale]

        case .turned45:
            pts2D["leftShoulder"] = (0.532, 0.485)
            pts2D["rightShoulder"] = (0.468, 0.485)
            pts2D["leftElbow"] = (0.605, 0.485)
            pts2D["rightElbow"] = (0.395, 0.485)
            pts2D["leftWrist"] = (0.680, 0.485)
            pts2D["rightWrist"] = (0.320, 0.485)
            world3D["leftShoulder"] = [0.134 * invScale, 0.48 * invScale, -0.134 * invScale]
            world3D["rightShoulder"] = [-0.134 * invScale, 0.48 * invScale, 0.134 * invScale]
            world3D["leftElbow"] = [0.33 * invScale, 0.48 * invScale, -0.33 * invScale]
            world3D["leftWrist"] = [0.51 * invScale, 0.48 * invScale, -0.51 * invScale]
            world3D["rightElbow"] = [-0.33 * invScale, 0.48 * invScale, 0.33 * invScale]
            world3D["rightWrist"] = [-0.51 * invScale, 0.48 * invScale, 0.51 * invScale]

        case .stepLeft:
            for (k, v) in pts2D { pts2D[k] = (v.x + 0.15, v.y) }

        case .stepRight:
            for (k, v) in pts2D { pts2D[k] = (v.x - 0.15, v.y) }

        case .kneeLift:
            pts2D["leftKnee"] = (0.535, 0.635)
            pts2D["leftAnkle"] = (0.530, 0.720)
            pts2D["leftHeel"] = (0.530, 0.732)
            pts2D["leftFootIndex"] = (0.536, 0.740)
            world3D["leftKnee"] = [0.11 * invScale, -0.02 * invScale, 0.43 * invScale]
            world3D["leftAnkle"] = [0.11 * invScale, -0.42 * invScale, 0.41 * invScale]
            world3D["leftHeel"] = [0.11 * invScale, -0.45 * invScale, 0.35 * invScale]
            world3D["leftFootIndex"] = [0.11 * invScale, -0.45 * invScale, 0.55 * invScale]
        }

        let camera3D = rotateWorldToCamera(world3D, cameraGravity: cameraGravity)
        var confs: [String: Double] = [:]
        for joint in CanonicalSkeleton.canonicalJoints {
            confs[joint] = visibilityOverrides[joint] ?? 0.95
        }
        let lm = pts2D.mapValues { pt in
            CalibrationLandmark(x: pt.x, y: pt.y, visibility: 0.95)
        }
        var landmarkDict = lm
        for (joint, vis) in visibilityOverrides {
            if let existing = landmarkDict[joint] {
                landmarkDict[joint] = CalibrationLandmark(x: existing.x, y: existing.y, visibility: vis)
            }
        }
        let frame = GrooveScoringEngine.RawPoseFrame(t: t, joints: camera3D, confidences: confs)
        return CalibrationPoseSample(timestamp: t, named: landmarkDict, frame: frame)
    }

    /// Projects a standing dancer of height `dancerHeightM` at `distanceM` under `studioIntrinsics` (`theta_V ≈ 67.38°`).
    private func makeStandingSampleAtDistance(
        t: Double,
        distanceM: Double,
        dancerHeightM: Double = 1.73,
        dx: Double = 0.0
    ) -> CalibrationPoseSample {
        let tanHalfV = Double(Self.studioIntrinsics.height) / (2.0 * Self.studioIntrinsics.fy)
        let expectedSpan = (0.855 * dancerHeightM) / (2.0 * distanceM * tanHalfV)
        // Base `standing2DAt2p85m` has span = 0.834 - 0.430 = 0.404; scale vertically around y = 0.63.
        let scale = expectedSpan / 0.404
        var named: [String: CalibrationLandmark] = [:]
        for (joint, base) in Self.standing2DAt2p85m {
            let x = 0.50 + (base.x - 0.50) * scale + dx
            let y = 0.63 + (base.y - 0.63) * scale
            named[joint] = CalibrationLandmark(x: x, y: y, visibility: 0.95)
        }
        let camera3D = rotateWorldToCamera(Self.uprightWorld3D, cameraGravity: Self.rearStudioGravity)
        let frame = GrooveScoringEngine.RawPoseFrame(t: t, joints: camera3D)
        return CalibrationPoseSample(timestamp: t, named: named, frame: frame)
    }

    // MARK: - 1. Full 9-Pose Sequence (`testFullNinePoseSequenceLocksProfileV2`)

    func testFullNinePoseSequenceLocksProfileV2() throws {
        let fixedNow = try XCTUnwrap(CalibrationProfileV2.parseTimestamp("2026-11-26T02:15:00Z"))
        var gate = CalibrationGate(
            cameraMode: .rearLiDAR,
            storedProfile: nil,
            isSameSession: false,
            deviceModel: "iPhone18,2",
            now: fixedNow
        )
        XCTAssertEqual(gate.step, .level)
        XCTAssertEqual(gate.calibrationTier, .tier2FullCalibration)
        XCTAssertFalse(gate.status.needsExposureLock)

        // Feed initial pre-lock light sample (`exposureLocked == false`).
        gate.update(light: CalibrationLightSample(
            meanLuma: 0.44,
            torsoLuma: 0.42,
            borderLuma: 0.46,
            iso: 160,
            maxISO: 2000,
            exposureSeconds: 0.01667,
            exposureLocked: false
        ))
        XCTAssertEqual(gate.telemetry().exposureLocked, false)

        // Feed LiDAR floor plane + initial studio distance during `.level`.
        gate.update(depth: CalibrationDepthSample(
            timestamp: 0.0,
            dancerDistanceM: 2.85,
            measuredHeightM: 1.73,
            cameraHeightM: 0.74,
            floorNormal: Self.studioFloorNormal,
            verticalFoVDeg: Self.studioIntrinsics.verticalFoVDeg,
            intrinsics: Self.studioIntrinsics
        ))

        // Hold phone still for `phoneStillHoldS = 0.5 s` with +9.9° rear upward tilt.
        for i in 0...18 {
            gate.update(motion: CalibrationMotionSample(
                timestamp: Double(i) / 30.0,
                gravity: Self.rearStudioGravity
            ))
        }
        XCTAssertEqual(gate.step, .rest)
        XCTAssertEqual(gate.step.rawValue, 2)
        XCTAssertEqual(CalibrationStep.frame, .rest)
        XCTAssertFalse(gate.status.needsExposureLock)

        var t = 10.0
        let dt = 1.0 / 30.0

        // Pose 1: `.rest` (0.6 s hold) -> triggers `needsExposureLock == true` and advances to `.tpose` (4).
        while gate.step == .rest && t < 12.0 {
            gate.update(pose: makeStudioPoseSample(t: t, for: .rest))
            t += dt
        }
        XCTAssertEqual(gate.step, .tpose)
        XCTAssertEqual(gate.step.rawValue, 4)
        XCTAssertTrue(gate.status.needsExposureLock, "AE/AWB lock must trigger immediately as Pose 1 (.rest) completes")
        XCTAssertEqual(gate.telemetry().restOK, true)

        // Controller locks AE/AWB and reports `exposureLocked: true` on subsequent light samples.
        gate.update(light: CalibrationLightSample(
            meanLuma: 0.44,
            torsoLuma: 0.42,
            borderLuma: 0.46,
            iso: 160,
            maxISO: 2000,
            exposureSeconds: 0.01667,
            exposureLocked: true
        ))
        XCTAssertEqual(gate.telemetry().exposureLocked, true)

        // Pose 2: `.tpose` (1.0 s hold, >= 15 frames) + LiDAR bone lengths -> `.overhead` (5).
        gate.update(depth: CalibrationDepthSample(
            timestamp: t,
            dancerDistanceM: 2.85,
            measuredHeightM: 1.73,
            cameraHeightM: 0.74,
            floorNormal: Self.studioFloorNormal,
            lidarBoneLengthsM: Self.studioLidarBoneLengthsM,
            verticalFoVDeg: Self.studioIntrinsics.verticalFoVDeg,
            intrinsics: Self.studioIntrinsics
        ))
        while gate.step == .tpose && t < 15.0 {
            gate.update(pose: makeStudioPoseSample(t: t, for: .tpose))
            t += dt
        }
        XCTAssertEqual(gate.step, .overhead)
        XCTAssertEqual(gate.step.rawValue, 5)
        XCTAssertGreaterThanOrEqual(gate.capturedFrames.count, 15)
        XCTAssertEqual(try XCTUnwrap(gate.telemetry().metricScaleFactor), 1.064, accuracy: 0.01)

        // Pose 3: `.overhead` (0.7 s hold) -> `.asymLR` (6).
        while gate.step == .overhead && t < 17.0 {
            gate.update(pose: makeStudioPoseSample(t: t, for: .overhead))
            t += dt
        }
        XCTAssertEqual(gate.step, .asymLR)
        XCTAssertEqual(gate.step.rawValue, 6)
        XCTAssertEqual(gate.telemetry().overheadOK, true)

        // Pose 4: `.asymLR` — first hold reversed arms for 0.45 s (>= 0.35 s) to verify `lrSwapped` + `.swapArmsLR`,
        // then hold correct left-up/right-out to clear `lrSwapped` and advance to `.armsForward` (7).
        for _ in 0..<15 {
            gate.update(pose: makeStudioPoseSample(t: t, for: .asymLR, reversedAsym: true))
            t += dt
        }
        XCTAssertEqual(gate.step, .asymLR)
        XCTAssertEqual(gate.cue, .swapArmsLR)
        XCTAssertEqual(gate.telemetry().lrSwapped, true)

        while gate.step == .asymLR && t < 20.0 {
            gate.update(pose: makeStudioPoseSample(t: t, for: .asymLR, reversedAsym: false))
            t += dt
        }
        XCTAssertEqual(gate.step, .armsForward)
        XCTAssertEqual(gate.step.rawValue, 7)
        XCTAssertEqual(gate.telemetry().asymLROK, true)
        XCTAssertEqual(gate.telemetry().lrSwapped, false)

        // Pose 5: `.armsForward` (0.7 s hold) with LiDAR `shoulderToWristDeltaZM = 0.515 m` -> `.plie` (8).
        gate.update(depth: CalibrationDepthSample(
            timestamp: t,
            dancerDistanceM: 2.85,
            cameraHeightM: 0.74,
            floorNormal: Self.studioFloorNormal,
            shoulderToWristDeltaZM: 0.515,
            verticalFoVDeg: Self.studioIntrinsics.verticalFoVDeg,
            intrinsics: Self.studioIntrinsics
        ))
        while gate.step == .armsForward && t < 22.0 {
            gate.update(pose: makeStudioPoseSample(t: t, for: .armsForward))
            t += dt
        }
        XCTAssertEqual(gate.step, .plie)
        XCTAssertEqual(gate.step.rawValue, 8)
        XCTAssertEqual(gate.telemetry().armsForwardOK, true)

        // Pose 6: `.plie` (0.8 s hold) -> `.turned45` (9).
        while gate.step == .plie && t < 24.0 {
            gate.update(pose: makeStudioPoseSample(t: t, for: .plie))
            t += dt
        }
        XCTAssertEqual(gate.step, .turned45)
        XCTAssertEqual(gate.step.rawValue, 9)
        XCTAssertEqual(gate.telemetry().plieOK, true)

        // Pose 7: `.turned45` (0.7 s hold) -> `.stepLeft` (10).
        while gate.step == .turned45 && t < 26.0 {
            gate.update(pose: makeStudioPoseSample(t: t, for: .turned45))
            t += dt
        }
        XCTAssertEqual(gate.step, .stepLeft)
        XCTAssertEqual(gate.step.rawValue, 10)
        XCTAssertEqual(gate.telemetry().turned45OK, true)

        // Pose 8a: `.stepLeft` (0.5 s hold) -> `.stepRight` (11).
        while gate.step == .stepLeft && t < 28.0 {
            gate.update(pose: makeStudioPoseSample(t: t, for: .stepLeft))
            t += dt
        }
        XCTAssertEqual(gate.step, .stepRight)
        XCTAssertEqual(gate.step.rawValue, 11)
        XCTAssertEqual(gate.telemetry().stepLeftOK, true)

        // Pose 8b: `.stepRight` (0.5 s hold) -> `.kneeLift` (12).
        while gate.step == .stepRight && t < 30.0 {
            gate.update(pose: makeStudioPoseSample(t: t, for: .stepRight))
            t += dt
        }
        XCTAssertEqual(gate.step, .kneeLift)
        XCTAssertEqual(gate.step.rawValue, 12)
        XCTAssertEqual(gate.telemetry().stepRightOK, true)

        // Pose 9: `.kneeLift` (0.5 s hold) -> `.locked` (13).
        while gate.step == .kneeLift && t < 32.0 {
            gate.update(pose: makeStudioPoseSample(
                t: t,
                for: .kneeLift,
                visibilityOverrides: ["leftHeel": 0.46, "leftFootIndex": 0.46]
            ))
            t += dt
        }
        XCTAssertEqual(gate.step, .locked)
        XCTAssertEqual(gate.step.rawValue, 13)
        XCTAssertEqual(gate.cue, .locked)
        XCTAssertEqual(gate.progress, 1.0)
        XCTAssertFalse(gate.resumed)
        XCTAssertFalse(gate.resumedBody)

        // Verify `lockedProfileV2` (§6.1) and `lockedProfile` bridge.
        let v2 = try XCTUnwrap(gate.lockedProfileV2)
        XCTAssertEqual(v2.schema, "groove.calibration/2")
        XCTAssertEqual(v2.schemaVersion, 2)
        XCTAssertEqual(v2.deviceModel, "iPhone18,2")
        XCTAssertEqual(v2.cameraMode, .rearLiDAR)
        XCTAssertEqual(v2.environment.tiltBackDeg, 9.9, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(v2.environment.floorPlane?.cameraHeightM), 0.74, accuracy: 1e-6)
        XCTAssertLessThan(try XCTUnwrap(v2.environment.floorPlane?.lidarGravityDisagreementDeg), 1.0)
        XCTAssertEqual(try XCTUnwrap(v2.environment.dancerDistanceM), 2.85, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(v2.environment.effectiveMinDistanceM), 2.68, accuracy: 0.03)
        XCTAssertEqual(try XCTUnwrap(v2.environment.usableLateralSpanM), 1.97, accuracy: 0.03)
        XCTAssertEqual(try XCTUnwrap(v2.environment.overheadHeadroomMinY), 0.31, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(v2.environment.lockedMeanLuma), 0.44, accuracy: 1e-6)

        XCTAssertEqual(try XCTUnwrap(v2.body.dancerHeightM), 1.73, accuracy: 1e-6)
        XCTAssertEqual(v2.body.metricScaleFactor, 1.064, accuracy: 0.01)
        XCTAssertEqual(v2.body.wingspanM, 1.46, accuracy: 0.01)
        XCTAssertEqual(v2.body.boneLengthsM.count, 19)
        XCTAssertTrue(v2.body.lrVerified)
        XCTAssertEqual(try XCTUnwrap(v2.body.armSymmetryRatio), 1.0, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(v2.body.zDepthScaleRatio), 1.03, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(v2.body.rom.plieKneeFlexDeg, 22.0)
        XCTAssertGreaterThanOrEqual(v2.body.rom.plieHipDropNorm, 0.04)
        XCTAssertGreaterThan(v2.body.rom.maxShoulderElevationDeg, 165.0)
        XCTAssertGreaterThanOrEqual(v2.body.rom.maxKneeLiftFlexDeg, 55.0)
        XCTAssertEqual(v2.body.jointConfidenceWeights.count, 17)
        XCTAssertGreaterThanOrEqual(v2.body.calibrationFrames.count, 15)
        XCTAssertEqual(gate.lockedProfile?.frames.count, v2.body.calibrationFrames.count)

        // Verify `calibration_end` telemetry pass criteria (§9.3).
        let tel = gate.telemetry()
        XCTAssertEqual(tel.step, "locked")
        XCTAssertEqual(tel.stepIndex, 13)
        XCTAssertFalse(tel.skipped)
        XCTAssertEqual(tel.calibrationTier, 2)
        XCTAssertFalse(tel.resumedBody)
        XCTAssertEqual(tel.cameraMode, "rearLiDAR")
        XCTAssertEqual(tel.lrSwapped, false)
        XCTAssertEqual(tel.exposureLocked, true)
        XCTAssertEqual(tel.restOK, true)
        XCTAssertEqual(tel.tPoseOK, true)
        XCTAssertEqual(tel.overheadOK, true)
        XCTAssertEqual(tel.asymLROK, true)
        XCTAssertEqual(tel.armsForwardOK, true)
        XCTAssertEqual(tel.plieOK, true)
        XCTAssertEqual(tel.turned45OK, true)
        XCTAssertEqual(tel.stepLeftOK, true)
        XCTAssertEqual(tel.stepRightOK, true)
        XCTAssertEqual(tel.kneeLiftOK, true)
    }

    // MARK: - 2. Distance & Coupled Span Reconciliation (`testRestPassesAcross2p68To4mWithoutStepCloserConflict`)

    func testRestPassesAcross2p68To4mWithoutStepCloserConflict() throws {
        // Stored profile with calibrated `wingspanM = 1.46 m`, `dancerHeightM = 1.73 m` so `d_effective_min ≈ 2.68 m`.
        let seedBody = CalibrationProfileV2.Body(
            dancerHeightM: 1.73,
            metricScaleFactor: 1.064,
            wingspanM: 1.46,
            boneLengthsM: Self.studioLidarBoneLengthsM
        )
        let seedProfile = CalibrationProfileV2(
            calibratedAt: "2026-10-01T00:00:00Z", // >30 days old -> forces Tier 2 while supplying stored wingspan/height
            deviceModel: "iPhone18,2",
            cameraMode: .rearLiDAR,
            environment: CalibrationProfileV2.Environment(gravity: Self.rearStudioGravity.array, rollDeg: 0.7, tiltBackDeg: 9.9),
            body: seedBody
        )
        let now = try XCTUnwrap(CalibrationProfileV2.parseTimestamp("2026-11-26T02:15:00Z"))

        func leveledRearLiDARGate() -> CalibrationGate {
            var g = CalibrationGate(cameraMode: .rearLiDAR, storedProfile: seedProfile, isSameSession: false, now: now)
            for i in 0...18 {
                g.update(motion: CalibrationMotionSample(
                    timestamp: Double(i) / 30.0,
                    gravity: Self.rearStudioGravity
                ))
            }
            XCTAssertEqual(g.step, .rest)
            return g
        }

        // (a) Initial < 0.25 s warm-up before first LiDAR depth sample arrives: `distanceOK == false`, `cue == .none`
        // (never speaks a spurious `.stepCloser` on a 3.9 m standing dancer with `span ≈ 0.285`).
        var warmupGate = leveledRearLiDARGate()
        let farSample = makeStandingSampleAtDistance(t: 5.0, distanceM: 3.90, dancerHeightM: 1.73)
        let warmupStatus = warmupGate.update(pose: farSample)
        XCTAssertEqual(warmupStatus.cue, .none)
        XCTAssertNotEqual(warmupStatus.cue, .stepCloser)
        XCTAssertEqual(warmupGate.telemetry().distanceOK, false)

        // (b) At `2.0 m` (inside `d_effective_min ≈ 2.68 m`): fires `.stepBackDistance`, NEVER `.stepCloser`.
        var nearGate = leveledRearLiDARGate()
        nearGate.update(depth: CalibrationDepthSample(
            timestamp: 5.0,
            dancerDistanceM: 2.0,
            measuredHeightM: 1.73,
            cameraHeightM: 0.74,
            floorNormal: Self.studioFloorNormal,
            verticalFoVDeg: Self.studioIntrinsics.verticalFoVDeg,
            intrinsics: Self.studioIntrinsics
        ))
        let nearStatus = nearGate.update(pose: makeStandingSampleAtDistance(t: 5.0, distanceM: 2.0, dancerHeightM: 1.73))
        XCTAssertEqual(nearStatus.cue, .stepBackDistance)
        XCTAssertNotEqual(nearStatus.cue, .stepCloser)
        let nearTel = nearGate.telemetry()
        XCTAssertEqual(nearTel.distanceOK, false)
        XCTAssertEqual(try XCTUnwrap(nearTel.effectiveMinDistanceM), 2.68, accuracy: 0.02)
        let spokenNear = nearStatus.cue.spokenText(
            dancerDistanceM: nearStatus.dancerDistanceM,
            effectiveMinDistanceM: nearStatus.effectiveMinDistanceM
        )
        XCTAssertTrue(spokenNear.contains("2.0 meters"), spokenNear)
        XCTAssertTrue(spokenNear.contains("3.0 meters"), spokenNear)

        // (c) Above `4.0 m` (`4.35 m`): fires `.stepCloserDistance`.
        var tooFarGate = leveledRearLiDARGate()
        tooFarGate.update(depth: CalibrationDepthSample(
            timestamp: 5.0,
            dancerDistanceM: 4.35,
            measuredHeightM: 1.73,
            cameraHeightM: 0.74,
            floorNormal: Self.studioFloorNormal,
            verticalFoVDeg: Self.studioIntrinsics.verticalFoVDeg,
            intrinsics: Self.studioIntrinsics
        ))
        let tooFarStatus = tooFarGate.update(pose: makeStandingSampleAtDistance(t: 5.0, distanceM: 4.35, dancerHeightM: 1.73))
        XCTAssertEqual(tooFarStatus.cue, .stepCloserDistance)
        XCTAssertEqual(tooFarGate.telemetry().distanceOK, false)

        // (d) Across `[2.68 m, 4.00 m]` (`span ≈ 0.414 -> 0.277`, plus `1.50 m` dancer at `4.00 m` with `span ≈ 0.240`):
        // every distance passes `distanceOK`, `spanOK`, and `framingOK` with zero `.stepCloser` conflict, and completes `.rest`.
        let studioCases: [(distanceM: Double, heightM: Double)] = [
            (2.68, 1.73),
            (2.85, 1.73),
            (3.30, 1.73),
            (4.00, 1.73),
            (4.00, 1.50)
        ]

        for testCase in studioCases {
            var g = leveledRearLiDARGate()
            g.update(depth: CalibrationDepthSample(
                timestamp: 10.0,
                dancerDistanceM: testCase.distanceM,
                measuredHeightM: testCase.heightM,
                cameraHeightM: 0.74,
                floorNormal: Self.studioFloorNormal,
                verticalFoVDeg: Self.studioIntrinsics.verticalFoVDeg,
                intrinsics: Self.studioIntrinsics
            ))
            for i in 0...20 {
                let t = 10.0 + Double(i) / 30.0
                let st = g.update(pose: makeStandingSampleAtDistance(
                    t: t,
                    distanceM: testCase.distanceM,
                    dancerHeightM: testCase.heightM
                ))
                XCTAssertNotEqual(st.cue, .stepCloser, "Conflicting .stepCloser at d=\(testCase.distanceM)m, H=\(testCase.heightM)m")
                if g.step == .tpose { break }
                let tel = g.telemetry()
                XCTAssertEqual(tel.distanceOK, true, "distanceOK failed at d=\(testCase.distanceM)m")
                XCTAssertEqual(tel.spanOK, true, "spanOK failed at d=\(testCase.distanceM)m, H=\(testCase.heightM)m")
                XCTAssertEqual(tel.framingOK, true, "framingOK failed at d=\(testCase.distanceM)m, H=\(testCase.heightM)m")
                XCTAssertNotNil(tel.spanExpected)
            }
            XCTAssertEqual(g.step, .tpose, "Pose 1 (.rest) must complete at d=\(testCase.distanceM)m, H=\(testCase.heightM)m")
            XCTAssertTrue(g.status.needsExposureLock)
        }
    }

    // MARK: - 3. Rear vs Front Camera CoreMotion Gravity Z-Sign Flip (`testRearCameraTiltSignFlip`)

    func testRearCameraTiltSignFlip() {
        // Rear camera aimed upward by +9.9° tilts front screen slightly face-down (`g.z = +0.172 > 0`).
        let rearAngles = CalibrationGate.angles(gravity: Self.rearStudioGravity, cameraMode: .rearLiDAR)
        let rearWideAngles = CalibrationGate.angles(gravity: Self.rearStudioGravity, cameraMode: .rearWide)
        let frontAngles = CalibrationGate.angles(gravity: Self.rearStudioGravity, cameraMode: .frontSelfView)

        XCTAssertEqual(rearAngles.rollDeg, 0.7, accuracy: 0.05)
        XCTAssertEqual(rearAngles.tiltBackDeg, 9.9, accuracy: 0.05)
        XCTAssertEqual(rearWideAngles.tiltBackDeg, rearAngles.tiltBackDeg, accuracy: 1e-9)
        XCTAssertEqual(frontAngles.tiltBackDeg, -rearAngles.tiltBackDeg, accuracy: 1e-9)

        // Rear gate accepts +9.9° (`[-5°, +20°]`) and agrees with LiDAR floor normal (`lidarFloorTiltDeg < 1°`).
        var rearGate = CalibrationGate(cameraMode: .rearLiDAR)
        rearGate.update(depth: CalibrationDepthSample(
            timestamp: 0.0,
            cameraHeightM: 0.74,
            floorNormal: Self.studioFloorNormal
        ))
        let rearStatus = rearGate.update(motion: CalibrationMotionSample(
            timestamp: 0.0,
            gravity: Self.rearStudioGravity
        ))
        XCTAssertEqual(rearStatus.cue, .none)
        XCTAssertEqual(rearGate.telemetry().tiltOK, true)
        XCTAssertEqual(try XCTUnwrap(rearGate.telemetry().tiltBackDeg), 9.9, accuracy: 0.05)
        XCTAssertLessThan(try XCTUnwrap(rearGate.telemetry().lidarFloorTiltDeg), 1.0)

        // Front gate sees the exact same device gravity as -9.9° forward lean (`< -5°`), prompting `.tiltLessForward`.
        var frontGate = CalibrationGate(cameraMode: .frontSelfView)
        let frontStatus = frontGate.update(motion: CalibrationMotionSample(
            timestamp: 0.0,
            gravity: Self.rearStudioGravity
        ))
        XCTAssertEqual(frontStatus.cue, .tiltLessForward)
        XCTAssertEqual(frontGate.telemetry().tiltOK, false)
        XCTAssertEqual(try XCTUnwrap(frontGate.telemetry().tiltBackDeg), -9.9, accuracy: 0.05)
    }

    // MARK: - 4. Three-Tier Re-Calibration & Bump Reset (`testTier0AndTier1ResumeRules`)

    func testTier0AndTier1ResumeRules() throws {
        let baseDate = try XCTUnwrap(CalibrationProfileV2.parseTimestamp("2026-11-26T02:15:00Z"))
        let storedFrames = (0..<15).map { idx in
            GrooveScoringEngine.RawPoseFrame(
                t: Double(idx) / 30.0,
                joints: rotateWorldToCamera(Self.uprightWorld3D, cameraGravity: Self.rearStudioGravity)
            )
        }
        let storedProfile = CalibrationProfileV2(
            calibratedAt: "2026-11-26T02:15:00Z",
            deviceModel: "iPhone18,2",
            cameraMode: .rearLiDAR,
            environment: CalibrationProfileV2.Environment(
                gravity: Self.rearStudioGravity.array,
                rollDeg: 0.7,
                tiltBackDeg: 9.9,
                intrinsics: Self.studioIntrinsics,
                floorPlane: CalibrationProfileV2.FloorPlane(
                    normal: Self.studioFloorNormal.array,
                    cameraHeightM: 0.74,
                    lidarGravityDisagreementDeg: 0.4
                ),
                effectiveMinDistanceM: 2.68,
                dancerDistanceM: 2.85,
                usableLateralSpanM: 1.97,
                overheadHeadroomMinY: 0.31,
                lockedMeanLuma: 0.44,
                airplayRouteOffsetsMs: ["LivingRoomTV": 18.0],
                tvVideoLeadOffsetMs: 12.0
            ),
            body: CalibrationProfileV2.Body(
                dancerHeightM: 1.73,
                metricScaleFactor: 1.064,
                wingspanM: 1.46,
                lrVerified: true,
                armSymmetryRatio: 0.99,
                zDepthScaleRatio: 1.03,
                boneLengthsM: Self.studioLidarBoneLengthsM,
                rom: CalibrationROM(standingKneeFlexDeg: 5.0, plieKneeFlexDeg: 34.0, plieHipDropNorm: 0.09),
                jointConfidenceWeights: ["nose": 0.98, "leftAnkle": 0.90],
                calibrationFrames: storedFrames
            )
        )

        // --- (A) Tier 0: same session, same cameraMode, stable gravity & LiDAR floor -> `.resume -> .rest (0.4 s) -> .locked` ---
        var tier0 = CalibrationGate(
            cameraMode: .rearLiDAR,
            storedProfile: storedProfile,
            isSameSession: true,
            deviceModel: "iPhone18,2",
            now: baseDate.addingTimeInterval(120)
        )
        XCTAssertEqual(tier0.step, .resume)
        XCTAssertEqual(tier0.calibrationTier, .tier0InstantResume)

        tier0.update(motion: CalibrationMotionSample(timestamp: 0.0, gravity: Self.rearStudioGravity))
        XCTAssertEqual(tier0.step, .resume, "rearLiDAR Tier 0 waits for LiDAR floor confirmation too")

        tier0.update(depth: CalibrationDepthSample(
            timestamp: 0.05,
            dancerDistanceM: 2.85,
            measuredHeightM: 1.73,
            cameraHeightM: 0.75, // |0.75 - 0.74| = 0.01 < 0.03 m
            floorNormal: Self.studioFloorNormal,
            verticalFoVDeg: Self.studioIntrinsics.verticalFoVDeg,
            intrinsics: Self.studioIntrinsics
        ))
        XCTAssertEqual(tier0.step, .rest)
        XCTAssertEqual(tier0.telemetry().resumeOK, true)

        // 0.4 s hold (15 samples at 30 Hz = 0.467 s) locks immediately without Poses 2–9.
        for i in 0..<15 {
            tier0.update(pose: makeStudioPoseSample(t: 1.0 + Double(i) / 30.0, for: .rest))
        }
        XCTAssertEqual(tier0.step, .locked)
        XCTAssertTrue(tier0.resumed)
        XCTAssertTrue(tier0.resumedBody)
        XCTAssertTrue(tier0.status.needsExposureLock)
        XCTAssertEqual(tier0.telemetry().calibrationTier, 0)
        XCTAssertEqual(tier0.telemetry().resumedBody, true)
        XCTAssertEqual(tier0.lockedProfileV2?.body, storedProfile.body)
        XCTAssertEqual(tier0.lockedProfileV2?.environment.airplayRouteOffsetsMs["LivingRoomTV"], 18.0)

        // --- (B) Tier 0 -> Tier 1 downgrade when camera height moved >= 0.03 m; same dancer reuses `body` after `.rest` ---
        var movedHeight = CalibrationGate(
            cameraMode: .rearLiDAR,
            storedProfile: storedProfile,
            isSameSession: true,
            now: baseDate.addingTimeInterval(300)
        )
        movedHeight.update(motion: CalibrationMotionSample(timestamp: 0.0, gravity: Self.rearStudioGravity))
        movedHeight.update(depth: CalibrationDepthSample(
            timestamp: 0.05,
            dancerDistanceM: 2.95,
            measuredHeightM: 1.75, // |1.75 - 1.73| = 0.02 <= 0.06 m (same dancer!)
            cameraHeightM: 0.80,   // |0.80 - 0.74| = 0.06 >= 0.03 m -> Tier 1!
            floorNormal: Self.studioFloorNormal,
            verticalFoVDeg: Self.studioIntrinsics.verticalFoVDeg,
            intrinsics: Self.studioIntrinsics
        ))
        XCTAssertEqual(movedHeight.step, .level)
        XCTAssertEqual(movedHeight.calibrationTier, .tier1EnvironmentOnly)
        XCTAssertEqual(movedHeight.telemetry().resumeOK, false)

        for i in 1...18 {
            movedHeight.update(motion: CalibrationMotionSample(timestamp: Double(i) / 30.0, gravity: Self.rearStudioGravity))
        }
        XCTAssertEqual(movedHeight.step, .rest)

        for i in 0...20 {
            movedHeight.update(pose: makeStandingSampleAtDistance(
                t: 2.0 + Double(i) / 30.0,
                distanceM: 2.95,
                dancerHeightM: 1.75
            ))
        }
        XCTAssertEqual(movedHeight.step, .locked, "Tier 1 same-dancer check jumps straight from .rest to .locked")
        XCTAssertFalse(movedHeight.resumed)
        XCTAssertTrue(movedHeight.resumedBody)
        XCTAssertTrue(movedHeight.status.needsExposureLock)
        XCTAssertEqual(movedHeight.telemetry().calibrationTier, 1)
        XCTAssertEqual(movedHeight.telemetry().resumedBody, true)
        XCTAssertEqual(movedHeight.lockedProfileV2?.body, storedProfile.body)
        XCTAssertEqual(try XCTUnwrap(movedHeight.lockedProfileV2?.environment.floorPlane?.cameraHeightM), 0.80, accuracy: 1e-6)

        // --- (C) Tier 1 -> Tier 2 escalation when LiDAR detects a different dancer (`|1.84 - 1.73| = 0.11 > 0.06 m`) ---
        var differentDancer = CalibrationGate(
            cameraMode: .rearLiDAR,
            storedProfile: storedProfile,
            isSameSession: false, // new session -> starts in Tier 1
            now: baseDate.addingTimeInterval(3600)
        )
        XCTAssertEqual(differentDancer.step, .level)
        XCTAssertEqual(differentDancer.calibrationTier, .tier1EnvironmentOnly)

        differentDancer.update(depth: CalibrationDepthSample(
            timestamp: 0.0,
            dancerDistanceM: 3.10,
            measuredHeightM: 1.84,
            cameraHeightM: 0.74,
            floorNormal: Self.studioFloorNormal,
            verticalFoVDeg: Self.studioIntrinsics.verticalFoVDeg,
            intrinsics: Self.studioIntrinsics
        ))
        for i in 0...18 {
            differentDancer.update(motion: CalibrationMotionSample(timestamp: Double(i) / 30.0, gravity: Self.rearStudioGravity))
        }
        XCTAssertEqual(differentDancer.step, .rest)

        for i in 0...20 {
            differentDancer.update(pose: makeStandingSampleAtDistance(
                t: 5.0 + Double(i) / 30.0,
                distanceM: 3.10,
                dancerHeightM: 1.84
            ))
        }
        XCTAssertEqual(differentDancer.step, .tpose, "Different dancer height must escalate Tier 1 -> Tier 2 (.tpose)")
        XCTAssertEqual(differentDancer.calibrationTier, .tier2FullCalibration)
        XCTAssertEqual(differentDancer.telemetry().calibrationTier, 2)
        XCTAssertFalse(differentDancer.resumedBody)
        XCTAssertTrue(differentDancer.status.needsExposureLock)

        // --- (D) Mid-calibration LiDAR bump (> 0.04 m cameraHeightM change) resets to `.level` and clears `needsExposureLock` ---
        let bumpedStatus = differentDancer.update(depth: CalibrationDepthSample(
            timestamp: 6.0,
            cameraHeightM: 0.81 // |0.81 - 0.74| = 0.07 > 0.04 m
        ))
        XCTAssertEqual(bumpedStatus.step, .level)
        XCTAssertFalse(bumpedStatus.needsExposureLock, "Bump reset must clear needsExposureLock so AE/AWB unlocks")
    }

    // MARK: - 5. Flat JSON Telemetry Verification (`testTelemetryIsFlatJSON`)

    func testTelemetryIsFlatJSON() throws {
        var gate = CalibrationGate(cameraMode: .rearLiDAR, deviceModel: "iPhone18,2")
        gate.update(depth: CalibrationDepthSample(
            timestamp: 0.0,
            dancerDistanceM: 2.85,
            measuredHeightM: 1.73,
            cameraHeightM: 0.74,
            floorNormal: Self.studioFloorNormal,
            lidarBoneLengthsM: Self.studioLidarBoneLengthsM,
            shoulderToWristDeltaZM: 0.515,
            verticalFoVDeg: Self.studioIntrinsics.verticalFoVDeg,
            intrinsics: Self.studioIntrinsics
        ))
        gate.update(light: CalibrationLightSample(
            meanLuma: 0.44,
            torsoLuma: 0.42,
            borderLuma: 0.46,
            iso: 160,
            maxISO: 2000,
            exposureSeconds: 0.01667,
            exposureLocked: true
        ))
        for i in 0...18 {
            gate.update(motion: CalibrationMotionSample(timestamp: Double(i) / 30.0, gravity: Self.rearStudioGravity))
        }

        var t = 10.0
        while gate.step != .locked && t < 35.0 {
            gate.update(pose: makeStudioPoseSample(t: t, for: gate.step))
            t += 1.0 / 30.0
        }
        XCTAssertEqual(gate.step, .locked)

        let tel = gate.telemetry()
        let data = try JSONEncoder().encode(tel)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // 1. Strictly flat JSON: zero nested dictionaries or arrays anywhere.
        for (key, value) in object {
            XCTAssertFalse(value is [String: Any] || value is [Any], "\(key) must be a flat scalar, got \(type(of: value))")
        }

        // 2. Every required §7.1 v2 telemetry field is present and non-nil.
        let requiredV2Keys = [
            "cameraMode",
            "dancerDistanceM",
            "effectiveMinDistanceM",
            "distanceMinUsed",
            "distanceMaxUsed",
            "distanceOK",
            "spanExpected",
            "cameraHeightM",
            "measuredHeightM",
            "lidarFloorTiltDeg",
            "metricScaleFactor",
            "exposureLocked",
            "calibrationTier",
            "resumedBody",
            "lrSwapped",
            "restOK",
            "tPoseOK",
            "overheadOK",
            "asymLROK",
            "armsForwardOK",
            "plieOK",
            "turned45OK",
            "stepLeftOK",
            "stepRightOK",
            "kneeLiftOK"
        ]
        for key in requiredV2Keys {
            XCTAssertNotNil(object[key], "Missing flat v2 telemetry key: \(key)")
        }

        // 3. Exact Codable round-trip.
        let decoded = try JSONDecoder().decode(CalibrationTelemetry.self, from: data)
        XCTAssertEqual(decoded, tel)
    }
}
