import Foundation
import XCTest
@testable import GrooveCore

final class CalibrationProfileV2Tests: XCTestCase {

    // MARK: - Fixtures

    /// Exact §6.1 illustrative `rearLiDAR` JSON payload from `docs/specs/2026-11-26-calibration-v2-plan.md`.
    private static let specSection6JSON = #"""
    {
      "schema": "groove.calibration/2",
      "schemaVersion": 2,
      "calibratedAt": "2026-11-26T02:15:00Z",
      "deviceModel": "iPhone18,2",
      "cameraMode": "rearLiDAR",
      "environment": {
        "gravity": [0.012, -0.985, 0.172],
        "rollDeg": 0.7,
        "tiltBackDeg": 9.9,
        "intrinsics": {
          "fx": 959.6, "fy": 959.6, "cx": 360.0, "cy": 640.0,
          "width": 720, "height": 1280,
          "horizontalFoVDeg": 41.1, "verticalFoVDeg": 67.4
        },
        "floorPlane": {
          "normal": [-0.010, 0.986, -0.166],
          "cameraHeightM": 0.74,
          "lidarGravityDisagreementDeg": 0.4
        },
        "effectiveMinDistanceM": 2.68,
        "dancerDistanceM": 2.85,
        "usableLateralSpanM": 1.97,
        "overheadHeadroomMinY": 0.31,
        "lockedMeanLuma": 0.44,
        "exposureLockedISO": 160.0,
        "exposureLockedDurationS": 0.01667,
        "airplayRouteOffsetsMs": {
          "AirPlay-LivingRoomTV": 0.0
        },
        "tvVideoLeadOffsetMs": 0.0
      },
      "body": {
        "dancerHeightM": 1.73,
        "metricScaleFactor": 1.064,
        "wingspanM": 1.46,
        "lrVerified": true,
        "armSymmetryRatio": 0.99,
        "zDepthScaleRatio": 1.03,
        "boneLengthsM": {
          "spine": 0.24, "centerShoulder": 0.24, "nose": 0.21,
          "leftHip": 0.11, "leftKnee": 0.43, "leftAnkle": 0.41,
          "leftHeel": 0.08, "leftFootIndex": 0.16,
          "rightHip": 0.11, "rightKnee": 0.43, "rightAnkle": 0.41,
          "rightHeel": 0.08, "rightFootIndex": 0.16,
          "leftShoulder": 0.19, "leftElbow": 0.28, "leftWrist": 0.26,
          "rightShoulder": 0.19, "rightElbow": 0.28, "rightWrist": 0.26
        },
        "rom": {
          "standingKneeFlexDeg": 6.5,
          "plieKneeFlexDeg": 34.0,
          "plieHipDropNorm": 0.09,
          "maxShoulderElevationDeg": 171.0,
          "maxKneeLiftFlexDeg": 78.0,
          "trunkLeanBaselineDeg": 2.8
        },
        "jointConfidenceWeights": {
          "nose": 0.98, "leftShoulder": 0.99, "rightShoulder": 0.99,
          "leftElbow": 0.94, "rightElbow": 0.94, "leftWrist": 0.91, "rightWrist": 0.91,
          "leftHip": 0.97, "rightHip": 0.97, "leftKnee": 0.95, "rightKnee": 0.95,
          "leftAnkle": 0.90, "rightAnkle": 0.90,
          "leftHeel": 0.78, "rightHeel": 0.78, "leftFootIndex": 0.80, "rightFootIndex": 0.80
        },
        "calibrationFrames": []
      }
    }
    """#

    private func makeSampleFrame(_ t: Double) -> GrooveScoringEngine.RawPoseFrame {
        GrooveScoringEngine.RawPoseFrame(
            t: t,
            joints: [
                "root": [0.0, 0.0, 0.0],
                "spine": [0.0, 0.24, 0.0],
                "centerShoulder": [0.0, 0.48, 0.0],
                "leftShoulder": [0.19, 0.48, 0.0],
                "rightShoulder": [-0.19, 0.48, 0.0]
            ],
            confidences: [
                "root": 0.97,
                "leftShoulder": 0.99,
                "rightShoulder": 0.99
            ]
        )
    }

    private func makeSpecProfile() throws -> CalibrationProfileV2 {
        try JSONDecoder().decode(CalibrationProfileV2.self, from: Data(Self.specSection6JSON.utf8))
    }

    // MARK: - Profile Round-Trip & Bridges

    func testProfileV2RoundTrip() throws {
        var profile = try makeSpecProfile()
        XCTAssertEqual(profile.schema, "groove.calibration/2")
        XCTAssertEqual(profile.schemaVersion, 2)
        XCTAssertTrue(profile.isValidSchema)
        XCTAssertEqual(profile.cameraMode, .rearLiDAR)
        XCTAssertTrue(profile.cameraMode.isRear)
        XCTAssertTrue(profile.cameraMode.usesLiDAR)
        XCTAssertEqual(profile.deviceModel, "iPhone18,2")
        XCTAssertEqual(profile.environment.floorPlane?.cameraHeightM, 0.74)
        XCTAssertEqual(profile.environment.dancerDistanceM, 2.85)
        XCTAssertEqual(profile.environment.effectiveMinDistanceM, 2.68)
        XCTAssertEqual(profile.environment.airplayRouteOffsetsMs["AirPlay-LivingRoomTV"], 0.0)
        XCTAssertEqual(profile.body.dancerHeightM, 1.73)
        XCTAssertEqual(profile.body.metricScaleFactor, 1.064)
        XCTAssertEqual(profile.body.wingspanM, 1.46, accuracy: 1e-9)

        // Verify wrist-to-wrist wingspanM equals sum of the 6 L/R arm segments in boneLengthsM (§6.1).
        let computedWingspan = try XCTUnwrap(
            CalibrationProfileV2.Body.wristToWristWingspanM(from: profile.body.boneLengthsM)
        )
        XCTAssertEqual(computedWingspan, 1.46, accuracy: 1e-9)

        // Attach calibrationFrames and verify full JSON round-trip equality.
        profile.body.calibrationFrames = [makeSampleFrame(0.0), makeSampleFrame(0.033)]
        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(CalibrationProfileV2.self, from: encoded)
        XCTAssertEqual(decoded, profile)

        // Verify `.legacyProfile` bridge (`PoseClip.calibration_frames` + device gravity).
        let legacy = decoded.legacyProfile
        XCTAssertEqual(legacy.gravity, [0.012, -0.985, 0.172])
        XCTAssertEqual(legacy.frames.count, 2)
        XCTAssertEqual(legacy.frames[1].t, 0.033, accuracy: 1e-9)

        // Verify camera-frame gravity flip on front vs rear (§1.2).
        XCTAssertEqual(decoded.cameraFrameGravity, [0.012, -0.985, 0.172])
        XCTAssertEqual(CameraMode.frontSelfView.cameraFrameGravity(fromDeviceGravity: [0.012, -0.985, 0.172]),
                       [-0.012, -0.985, -0.172])

        // Verify `.asScoringCalibration` (`LearnerCalibrationV2`) round-trip & partial decode.
        let scoring = decoded.asScoringCalibration
        XCTAssertEqual(scoring.schema, "groove.calibration/2")
        XCTAssertEqual(scoring.metricScaleFactor, 1.064)
        XCTAssertEqual(scoring.dancerHeightM, 1.73)
        XCTAssertEqual(scoring.wingspanM, 1.46)
        XCTAssertEqual(scoring.boneLengthsM.count, GrooveScoringEngine.Retarget.canonicalBones.count)
        XCTAssertEqual(scoring.rom, decoded.body.rom)
        XCTAssertEqual(scoring.jointConfidenceWeights["leftHeel"], 0.78)

        let scoringData = try JSONEncoder().encode(scoring)
        let decodedScoring = try JSONDecoder().decode(LearnerCalibrationV2.self, from: scoringData)
        XCTAssertEqual(decodedScoring, scoring)

        let minimalScoring = try JSONDecoder().decode(
            LearnerCalibrationV2.self,
            from: Data(#"{"metricScaleFactor": 1.05}"#.utf8)
        )
        XCTAssertEqual(minimalScoring.schema, "groove.calibration/2")
        XCTAssertEqual(minimalScoring.metricScaleFactor, 1.05)
        XCTAssertTrue(minimalScoring.boneLengthsM.isEmpty)
        XCTAssertNil(minimalScoring.rom)
    }

    // MARK: - Three-Tier Resume Classifier (§6.2)

    func testThreeTierResumeClassifier() throws {
        let rearProfile = try makeSpecProfile()
        let baseDate = try XCTUnwrap(rearProfile.calibratedAtDate)
        let sameGravity = CalibrationVector3(rearProfile.environment.gravity)
        let sameFloorNormal = try XCTUnwrap(rearProfile.environment.floorPlane?.normalVector)

        // 1. Tier 0: same session, same rearLiDAR mode, tiny gravity delta (< 0.05 g),
        //    cameraHeightM delta < 0.03 m, floor normal angle < 3.0 deg.
        XCTAssertEqual(
            rearProfile.resumeTier(
                cameraMode: .rearLiDAR,
                isSameSession: true,
                now: baseDate.addingTimeInterval(120),
                currentGravity: CalibrationVector3(x: sameGravity.x + 0.01, y: sameGravity.y, z: sameGravity.z),
                liveCameraHeightM: 0.755,
                liveFloorNormal: sameFloorNormal
            ),
            .tier0InstantResume
        )

        // 2. Tier 1: new app session (same valid profile <= 30 days).
        XCTAssertEqual(
            rearProfile.resumeTier(
                cameraMode: .rearLiDAR,
                isSameSession: false,
                now: baseDate.addingTimeInterval(3600),
                currentGravity: sameGravity,
                liveCameraHeightM: 0.74,
                liveFloorNormal: sameFloorNormal
            ),
            .tier1EnvironmentOnly
        )

        // 3. Tier 1: phone moved in-session (`gravityDeltaG >= 0.05 g`).
        XCTAssertEqual(
            rearProfile.resumeTier(
                cameraMode: .rearLiDAR,
                isSameSession: true,
                now: baseDate.addingTimeInterval(60),
                gravityDeltaG: 0.05,
                liveCameraHeightM: 0.74,
                floorNormalAngleDeltaDeg: 0.2
            ),
            .tier1EnvironmentOnly
        )

        // 4. Tier 1: LiDAR cameraHeightM shifted by >= 0.03 m (`|0.78 - 0.74| = 0.04 >= 0.03`).
        XCTAssertEqual(
            rearProfile.resumeTier(
                cameraMode: .rearLiDAR,
                isSameSession: true,
                now: baseDate.addingTimeInterval(60),
                gravityDeltaG: 0.01,
                liveCameraHeightM: 0.78,
                floorNormalAngleDeltaDeg: 0.2
            ),
            .tier1EnvironmentOnly
        )

        // 5. Tier 1: LiDAR floor normal tilted by >= 3.0 deg.
        XCTAssertEqual(
            rearProfile.resumeTier(
                cameraMode: .rearLiDAR,
                isSameSession: true,
                now: baseDate.addingTimeInterval(60),
                gravityDeltaG: 0.01,
                liveCameraHeightM: 0.74,
                floorNormalAngleDeltaDeg: 3.1
            ),
            .tier1EnvironmentOnly
        )

        // 6. Tier 1 vs Tier 2 same-dancer height check (`<= 0.06 m` reuses body; `> 0.06 m` escalates to Tier 2).
        XCTAssertTrue(rearProfile.canReuseBody(measuredDancerHeightM: 1.78, cameraMode: .rearLiDAR))
        XCTAssertFalse(rearProfile.canReuseBody(measuredDancerHeightM: 1.81, cameraMode: .rearLiDAR))
        XCTAssertEqual(
            rearProfile.resumeTier(
                cameraMode: .rearLiDAR,
                isSameSession: false,
                now: baseDate.addingTimeInterval(600),
                measuredDancerHeightM: 1.81
            ),
            .tier2FullCalibration
        )

        // 7. Tier 2 (a): no stored profile or wrong schema version.
        XCTAssertEqual(
            CalibrationProfileV2.classifyResumeTier(
                stored: nil,
                cameraMode: .rearLiDAR,
                isSameSession: false,
                now: baseDate
            ),
            .tier2FullCalibration
        )
        var wrongSchema = rearProfile
        wrongSchema.schemaVersion = 1
        XCTAssertEqual(
            wrongSchema.resumeTier(cameraMode: .rearLiDAR, isSameSession: true, now: baseDate, gravityDeltaG: 0.0),
            .tier2FullCalibration
        )

        // 8. Tier 2 (b): 30-day expiry (`age <= 30 days` stays Tier 1; `age > 30 days` requires Tier 2).
        let exact30Days = baseDate.addingTimeInterval(30.0 * 24.0 * 3600.0)
        let over30Days = baseDate.addingTimeInterval(30.0 * 24.0 * 3600.0 + 1.0)
        XCTAssertEqual(
            rearProfile.resumeTier(cameraMode: .rearLiDAR, isSameSession: false, now: exact30Days),
            .tier1EnvironmentOnly
        )
        XCTAssertEqual(
            rearProfile.resumeTier(cameraMode: .rearLiDAR, isSameSession: false, now: over30Days),
            .tier2FullCalibration
        )

        // 9. Tier 2 (c): camera mode upgrade `frontSelfView -> rearLiDAR` (`dancerHeightM == nil`),
        //    whereas `frontSelfView -> frontSelfView` unmoved uses Tier 0, and `rearLiDAR -> frontSelfView` uses Tier 1.
        var frontProfile = rearProfile
        frontProfile.cameraMode = .frontSelfView
        frontProfile.environment.floorPlane = nil
        frontProfile.body.dancerHeightM = nil
        frontProfile.body.metricScaleFactor = 1.0

        XCTAssertEqual(
            frontProfile.resumeTier(cameraMode: .rearLiDAR, isSameSession: true, now: baseDate, gravityDeltaG: 0.01),
            .tier2FullCalibration
        )
        XCTAssertEqual(
            frontProfile.resumeTier(cameraMode: .frontSelfView, isSameSession: true, now: baseDate, gravityDeltaG: 0.01),
            .tier0InstantResume
        )
        XCTAssertEqual(
            rearProfile.resumeTier(cameraMode: .frontSelfView, isSameSession: true, now: baseDate, gravityDeltaG: 0.01),
            .tier1EnvironmentOnly
        )
        XCTAssertTrue(frontProfile.canReuseBody(measuredDancerHeightM: nil, cameraMode: .frontSelfView))

        // 10. Tier 2 (e): explicit Recalibrate Studio request always forces Tier 2.
        XCTAssertEqual(
            rearProfile.resumeTier(
                cameraMode: .rearLiDAR,
                isSameSession: true,
                forceFullRecalibration: true,
                now: baseDate,
                gravityDeltaG: 0.0,
                liveCameraHeightM: 0.74,
                floorNormalAngleDeltaDeg: 0.0
            ),
            .tier2FullCalibration
        )
    }

    // MARK: - CalibrationTuning v2 Keys & Partial Decode (§7.2)

    func testNewTuningKeysPartialDecode() throws {
        let d = CalibrationTuning.defaults
        // Legacy `spanMin` stays 0.45 so existing v1 tests remain green until #7 adopts `spanMinFloor = 0.22`.
        XCTAssertEqual(d.spanMin, 0.45)
        XCTAssertEqual(d.spanMinFloor, 0.22)
        XCTAssertEqual(d.noseToFootHeightRatio, 0.855)
        XCTAssertEqual(d.spanDepthToleranceRatio, 0.22)
        XCTAssertEqual(d.lidarMinDistanceM, 2.0)
        XCTAssertEqual(d.lidarMaxDistanceM, 4.0)
        XCTAssertEqual(d.lidarDistanceStayDeltaM, 0.25)
        XCTAssertEqual(d.lidarDistanceRelaxDeltaM, 0.30)
        XCTAssertEqual(d.lateralStepMarginM, 0.55)
        XCTAssertEqual(d.restHipCenterMinX, 0.40)
        XCTAssertEqual(d.restHipCenterMaxX, 0.60)
        XCTAssertEqual(d.resumeFloorHeightDeltaM, 0.03)
        XCTAssertEqual(d.resumeFloorAngleDeg, 3.0)
        XCTAssertEqual(d.sameDancerHeightDeltaM, 0.06)
        XCTAssertEqual(d.cameraHeightMinM, 0.50)
        XCTAssertEqual(d.cameraHeightMaxM, 1.50)
        XCTAssertEqual(d.exposureMaxShutterS, 0.0167)
        XCTAssertEqual(d.remeterLumaDelta, 0.20)
        XCTAssertEqual(d.restHoldS, 0.6)
        XCTAssertEqual(d.overheadHoldS, 0.7)
        XCTAssertEqual(d.overheadMinWristAboveNose, 0.05)
        XCTAssertEqual(d.overheadMinTopMarginY, 0.02)
        XCTAssertEqual(d.overheadMinElbowDeg, 135.0)
        XCTAssertEqual(d.asymHoldS, 0.7)
        XCTAssertEqual(d.asymMinSideReachShoulders, 0.80)
        XCTAssertEqual(d.forwardHoldS, 0.7)
        XCTAssertEqual(d.forwardMinDeltaZM, 0.25)
        XCTAssertEqual(d.plieHoldS, 0.8)
        XCTAssertEqual(d.plieMinKneeFlexDeg, 22.0)
        XCTAssertEqual(d.plieMinHipDropNorm, 0.04)
        XCTAssertEqual(d.turnedHoldS, 0.7)
        XCTAssertEqual(d.turnedMinYawDeg, 25.0)
        XCTAssertEqual(d.turnedMaxYawDeg, 65.0)
        XCTAssertEqual(d.turnedMinShoulderWidth2D, 0.045)
        XCTAssertEqual(d.stepHoldS, 0.5)
        XCTAssertEqual(d.stepMinHipShiftX, 0.12)
        XCTAssertEqual(d.stepDropoutS, 0.40)
        XCTAssertEqual(d.kneeLiftHoldS, 0.5)
        XCTAssertEqual(d.kneeLiftMinFlexDeg, 55.0)
        XCTAssertEqual(d.kneeLiftMinAnkleClearance, 0.18)
        XCTAssertEqual(d.kneeLiftMotionStayMax, 0.035)
        XCTAssertEqual(d.kneeLiftDropoutS, 0.45)

        // Partial JSON override keeps non-overridden keys from receiver (`merged(withJSON:)`).
        var customBase = CalibrationTuning.defaults
        customBase.lateralStepMarginM = 0.62
        customBase.plieHoldS = 0.95

        let patch = #"""
        {
          "_comment": "live debuglink tuning override",
          "spanMinFloor": 0.24,
          "lidarDistanceRelaxDeltaM": 0.35,
          "restHipCenterMinX": 0.42,
          "restHipCenterMaxX": 0.58,
          "turnedMinShoulderWidth2D": null,
          "unknownFutureKey": 123
        }
        """#
        let merged = try customBase.merged(withJSON: Data(patch.utf8))
        XCTAssertEqual(merged.spanMinFloor, 0.24)
        XCTAssertEqual(merged.spanMin, 0.45)
        XCTAssertEqual(merged.lidarDistanceRelaxDeltaM, 0.35)
        XCTAssertEqual(merged.restHipCenterMinX, 0.42)
        XCTAssertEqual(merged.restHipCenterMaxX, 0.58)
        XCTAssertEqual(merged.lateralStepMarginM, 0.62, "missing key keeps receiver value")
        XCTAssertEqual(merged.plieHoldS, 0.95, "missing key keeps receiver value")
        XCTAssertEqual(merged.turnedMinShoulderWidth2D, 0.045, "explicit null keeps receiver value")

        // Wrong type on a new v2 key throws rather than silently dropping.
        XCTAssertThrowsError(try customBase.merged(withJSON: Data(#"{"spanMinFloor": "low"}"#.utf8)))

        // Full encode/decode round-trip covers all CodingKeys.
        let encoded = try JSONEncoder().encode(merged)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(obj.count, CalibrationTuning.CodingKeys.allCases.count)
        XCTAssertEqual(try JSONDecoder().decode(CalibrationTuning.self, from: encoded), merged)
    }

    // MARK: - Depth Sample & Intrinsics Geometry (§3.1, §3.2, §6.1)

    func testDepthSampleAndIntrinsicsGeometry() throws {
        let intr = CalibrationIntrinsics.fromPinhole(
            fx: 959.6, fy: 959.6, cx: 360.0, cy: 640.0, width: 720, height: 1280
        )
        XCTAssertEqual(intr.horizontalFoVDeg, 41.112, accuracy: 0.02)
        XCTAssertEqual(intr.verticalFoVDeg, 67.380, accuracy: 0.02)
        XCTAssertEqual(
            CalibrationIntrinsics.portraitHorizontalFoVDeg(fromVerticalFoVDeg: intr.verticalFoVDeg),
            intr.horizontalFoVDeg,
            accuracy: 1e-6
        )

        // Principal point projects along -Z; image-right (+u) -> +X_cam; image-top (v < cy) -> +Y_cam.
        let center3D = intr.backProjectToCanonical(u: 360.0, v: 640.0, depthM: 2.85)
        XCTAssertEqual(center3D.x, 0.0, accuracy: 1e-9)
        XCTAssertEqual(center3D.y, 0.0, accuracy: 1e-9)
        XCTAssertEqual(center3D.z, -2.85, accuracy: 1e-9)

        let topRight = intr.backProjectToCanonical(u: 560.0, v: 240.0, depthM: 2.85)
        XCTAssertGreaterThan(topRight.x, 0.0)
        XCTAssertGreaterThan(topRight.y, 0.0)
        XCTAssertEqual(topRight.z, -2.85, accuracy: 1e-9)

        let scaled = intr.scaled(toWidth: 180, height: 320)
        XCTAssertEqual(scaled.fx, 239.9, accuracy: 1e-9)
        XCTAssertEqual(scaled.cx, 90.0, accuracy: 1e-9)
        XCTAssertEqual(scaled.cy, 160.0, accuracy: 1e-9)

        let depth = CalibrationDepthSample(
            timestamp: 12.5,
            dancerDistanceM: 2.85,
            measuredHeightM: 1.73,
            cameraHeightM: 0.74,
            floorNormal: CalibrationVector3(x: -0.010, y: 0.986, z: -0.166),
            lidarBoneLengthsM: ["leftShoulder": 0.19, "rightShoulder": 0.19],
            shoulderToWristDeltaZM: 0.31,
            verticalFoVDeg: 67.4,
            intrinsics: intr
        )
        let data = try JSONEncoder().encode(depth)
        let decoded = try JSONDecoder().decode(CalibrationDepthSample.self, from: data)
        XCTAssertEqual(decoded, depth)

        // Verify §6.1 floor normal vs `-normalize(gravity)` disagreement (~0.4 deg).
        let negGravity = CalibrationVector3(x: -0.012, y: 0.985, z: -0.172)
        let floorNormal = CalibrationVector3(x: -0.010, y: 0.986, z: -0.166)
        XCTAssertEqual(CalibrationProfileV2.angleBetweenDeg(floorNormal, negGravity), 0.37, accuracy: 0.05)
    }
}
