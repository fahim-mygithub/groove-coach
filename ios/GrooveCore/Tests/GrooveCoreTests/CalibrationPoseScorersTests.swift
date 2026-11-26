import Foundation
import XCTest
@testable import GrooveCore

final class CalibrationPoseScorersTests: XCTestCase {

    // MARK: - Synthetic Pose & 3D Skeleton Fixtures

    /// Un-mirrored normalized 2D standing landmarks (`x` right, `y` down; dancer's own left is at `x > 0.5`).
    private static let baseStanding2D: [String: (x: Double, y: Double)] = [
        "nose": (0.50, 0.25),
        "leftShoulder": (0.56, 0.33), "rightShoulder": (0.44, 0.33),
        "leftElbow": (0.58, 0.45), "rightElbow": (0.42, 0.45),
        "leftWrist": (0.59, 0.55), "rightWrist": (0.41, 0.55),
        "leftHip": (0.54, 0.55), "rightHip": (0.46, 0.55),
        "leftKnee": (0.54, 0.70), "rightKnee": (0.46, 0.70),
        "leftAnkle": (0.54, 0.84), "rightAnkle": (0.46, 0.84),
        "leftHeel": (0.54, 0.86), "rightHeel": (0.46, 0.86),
        "leftFootIndex": (0.55, 0.88), "rightFootIndex": (0.45, 0.88)
    ]

    /// Root-centered canonical 3D standing skeleton in MediaPipe metres (scaled so `1.064 * L_mp` matches §6.1 `boneLengthsM`).
    /// `+x` image-right (dancer's left), `+y` up, `+z` toward camera lens.
    private static let baseStanding3D: [String: [Double]] = [
        "root": [0.0, 0.0, 0.0],
        "spine": [0.0, 0.24, 0.0],
        "centerShoulder": [0.0, 0.48, 0.0],
        "nose": [0.0, 0.69, 0.0],
        "leftHip": [0.11, 0.0, 0.0],
        "leftKnee": [0.11, -0.43, 0.0],
        "leftAnkle": [0.11, -0.84, 0.0],
        "leftHeel": [0.11, -0.87, -0.074],
        "leftFootIndex": [0.11, -0.87, 0.157],
        "rightHip": [-0.11, 0.0, 0.0],
        "rightKnee": [-0.11, -0.43, 0.0],
        "rightAnkle": [-0.11, -0.84, 0.0],
        "rightHeel": [-0.11, -0.87, -0.074],
        "rightFootIndex": [-0.11, -0.87, 0.157],
        "leftShoulder": [0.19, 0.48, 0.0],
        "leftElbow": [0.22, 0.20, 0.0],
        "leftWrist": [0.24, -0.06, 0.0],
        "rightShoulder": [-0.19, 0.48, 0.0],
        "rightElbow": [-0.22, 0.20, 0.0],
        "rightWrist": [-0.24, -0.06, 0.0]
    ]

    private func makeSample(
        t: Double = 1.0,
        dx2D: Double = 0.0,
        dy2D: Double = 0.0,
        scale2D: Double = 1.0,
        overrides2D: [String: (x: Double, y: Double)] = [:],
        overrides3D: [String: [Double]] = [:],
        visibility: [String: Double] = [:],
        defaultVisibility: Double = 0.95
    ) -> CalibrationPoseSample {
        var named: [String: CalibrationLandmark] = [:]
        for (joint, base) in Self.baseStanding2D {
            let p = overrides2D[joint] ?? (
                x: 0.50 + (base.x - 0.50) * scale2D + dx2D,
                y: 0.55 + (base.y - 0.55) * scale2D + dy2D
            )
            named[joint] = CalibrationLandmark(
                x: p.x,
                y: p.y,
                visibility: visibility[joint] ?? defaultVisibility
            )
        }

        var joints3D = Self.baseStanding3D
        for (joint, coords) in overrides3D {
            joints3D[joint] = coords
        }
        var confs: [String: Double] = [:]
        for joint in CanonicalSkeleton.canonicalJoints {
            confs[joint] = visibility[joint] ?? defaultVisibility
        }
        let frame = GrooveScoringEngine.RawPoseFrame(
            t: t,
            joints: joints3D,
            confidences: confs
        )
        return CalibrationPoseSample(timestamp: t, named: named, frame: frame)
    }

    private func makeTPoseSample(
        t: Double = 1.0,
        dx2D: Double = 0.0,
        armHalfSpan2D: Double = 0.26,
        mpScale: Double = 1.0
    ) -> CalibrationPoseSample {
        let lsX = 0.56 + dx2D
        let rsX = 0.44 + dx2D
        let leX = lsX + 0.5 * armHalfSpan2D
        let reX = rsX - 0.5 * armHalfSpan2D
        let lwX = lsX + armHalfSpan2D
        let rwX = rsX - armHalfSpan2D

        var joints3D: [String: [Double]] = [:]
        for (name, arr) in Self.baseStanding3D {
            joints3D[name] = arr.map { $0 * mpScale }
        }
        joints3D["leftShoulder"] = [0.19 * mpScale, 0.48 * mpScale, 0.0]
        joints3D["leftElbow"] = [0.47 * mpScale, 0.48 * mpScale, 0.0]
        joints3D["leftWrist"] = [0.73 * mpScale, 0.48 * mpScale, 0.0]
        joints3D["rightShoulder"] = [-0.19 * mpScale, 0.48 * mpScale, 0.0]
        joints3D["rightElbow"] = [-0.47 * mpScale, 0.48 * mpScale, 0.0]
        joints3D["rightWrist"] = [-0.73 * mpScale, 0.48 * mpScale, 0.0]

        var overrides2D: [String: (x: Double, y: Double)] = [:]
        for (joint, p) in Self.baseStanding2D {
            overrides2D[joint] = (x: p.x + dx2D, y: p.y)
        }
        overrides2D["leftElbow"] = (leX, 0.33)
        overrides2D["rightElbow"] = (reX, 0.33)
        overrides2D["leftWrist"] = (lwX, 0.33)
        overrides2D["rightWrist"] = (rwX, 0.33)

        var confs: [String: Double] = [:]
        for joint in CanonicalSkeleton.canonicalJoints { confs[joint] = 0.95 }
        return CalibrationPoseSample(
            timestamp: t,
            named: overrides2D.mapValues { CalibrationLandmark(x: $0.x, y: $0.y, visibility: 0.95) },
            frame: GrooveScoringEngine.RawPoseFrame(t: t, joints: joints3D, confidences: confs)
        )
    }

    // MARK: - 1. All Nine Pose Evaluators (`testAllNinePoseEvaluators`)

    func testAllNinePoseEvaluators() throws {
        // --- Pose 1: .rest ---
        let restSample = makeSample()
        let restPass = CalibrationPoseScorers.evaluateRest(restSample, calibrationTier: .tier2FullCalibration)
        XCTAssertTrue(restPass.passes)
        XCTAssertEqual(restPass.cue, .none)
        XCTAssertEqual(try XCTUnwrap(restPass.standingKneeFlexDeg), 0.0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(restPass.trunkLeanBaselineDeg), 0.0, accuracy: 1e-6)
        let restHipHeightNorm = try XCTUnwrap(restPass.restHipHeightNorm)
        XCTAssertGreaterThan(restHipHeightNorm, 1.0)

        // Tier-2 enforces tighter [0.40, 0.60] centring while Tier-0/1 allows [0.30, 0.70].
        let offCenterRest = makeSample(dx2D: -0.14) // hipCenterX = 0.36
        let tier2OffCenter = CalibrationPoseScorers.evaluateRest(offCenterRest, calibrationTier: .tier2FullCalibration)
        XCTAssertFalse(tier2OffCenter.passes)
        XCTAssertEqual(tier2OffCenter.cue, .moveLeft)
        let tier0SameSample = CalibrationPoseScorers.evaluateRest(offCenterRest, calibrationTier: .tier0InstantResume)
        XCTAssertTrue(tier0SameSample.passes)
        XCTAssertEqual(tier0SameSample.cue, .none)

        // Arms raised during .rest prompts .relaxArms.
        let tPoseDuringRest = makeTPoseSample()
        let restArmsFail = CalibrationPoseScorers.evaluateRest(tPoseDuringRest)
        XCTAssertFalse(restArmsFail.passes)
        XCTAssertFalse(restArmsFail.armsRelaxedOK)
        XCTAssertEqual(restArmsFail.cue, .relaxArms)

        // --- Pose 2: .tpose + centring-vs-step-back cue disambiguation ---
        let tPosePass = CalibrationPoseScorers.evaluateTPose(makeTPoseSample())
        XCTAssertTrue(tPosePass.passes)
        XCTAssertEqual(tPosePass.cue, .none)
        XCTAssertGreaterThanOrEqual(tPosePass.tPoseScore.score, 0.55)

        // Centered dancer (|hipCenterX - 0.50| <= 0.08) whose wide wrists clip [0.03, 0.97] -> .stepBack.
        let clippedCenteredTPose = makeTPoseSample(dx2D: 0.0, armHalfSpan2D: 0.43) // lw.x = 0.99 > 0.97, rw.x = 0.01 < 0.03
        let tPoseStepBack = CalibrationPoseScorers.evaluateTPose(clippedCenteredTPose)
        XCTAssertFalse(tPoseStepBack.passes)
        XCTAssertEqual(tPoseStepBack.cue, .stepBack)

        // Off-center dancer (hipCenterX = 0.62 > 0.58) clipping left wrist (x > 0.97) -> .moveRight.
        let clippedLeftTPose = makeTPoseSample(dx2D: 0.12, armHalfSpan2D: 0.31) // hipX = 0.62, lw.x = 0.99 > 0.97
        let tPoseMoveRight = CalibrationPoseScorers.evaluateTPose(clippedLeftTPose)
        XCTAssertFalse(tPoseMoveRight.passes)
        XCTAssertEqual(tPoseMoveRight.cue, .moveRight)

        // Off-center dancer (hipCenterX = 0.38 < 0.42) clipping right wrist (x < 0.03) -> .moveLeft.
        let clippedRightTPose = makeTPoseSample(dx2D: -0.12, armHalfSpan2D: 0.31) // hipX = 0.38, rw.x = 0.01 < 0.03
        let tPoseMoveLeft = CalibrationPoseScorers.evaluateTPose(clippedRightTPose)
        XCTAssertFalse(tPoseMoveLeft.passes)
        XCTAssertEqual(tPoseMoveLeft.cue, .moveLeft)

        // --- Pose 3: .overhead ---
        let overheadSample = makeSample(
            overrides2D: [
                "leftElbow": (0.57, 0.19), "rightElbow": (0.43, 0.19),
                "leftWrist": (0.57, 0.08), "rightWrist": (0.43, 0.08)
            ],
            overrides3D: [
                "leftElbow": [0.21, 0.75, 0.0], "leftWrist": [0.22, 1.00, 0.0],
                "rightElbow": [-0.21, 0.75, 0.0], "rightWrist": [-0.22, 1.00, 0.0]
            ]
        )
        let overheadPass = CalibrationPoseScorers.evaluateOverhead(overheadSample)
        XCTAssertTrue(overheadPass.passes)
        XCTAssertEqual(overheadPass.cue, .none)
        XCTAssertEqual(try XCTUnwrap(overheadPass.overheadHeadroomMinY), 0.08, accuracy: 1e-6)
        XCTAssertGreaterThan(try XCTUnwrap(overheadPass.maxShoulderElevationDeg), 165.0)

        // Top-edge clipped overhead wrists (< 0.02) -> .stepBackHeadroom.
        let clippedOverhead = makeSample(
            overrides2D: [
                "leftElbow": (0.57, 0.14), "rightElbow": (0.43, 0.14),
                "leftWrist": (0.57, 0.01), "rightWrist": (0.43, 0.01)
            ],
            overrides3D: [
                "leftElbow": [0.21, 0.75, 0.0], "leftWrist": [0.22, 1.00, 0.0],
                "rightElbow": [-0.21, 0.75, 0.0], "rightWrist": [-0.22, 1.00, 0.0]
            ]
        )
        let overheadClippedEval = CalibrationPoseScorers.evaluateOverhead(clippedOverhead)
        XCTAssertFalse(overheadClippedEval.passes)
        XCTAssertEqual(overheadClippedEval.cue, .stepBackHeadroom)

        // --- Pose 4: .asymLR (left overhead, right horizontal) ---
        let asymSample = makeSample(
            overrides2D: [
                "leftElbow": (0.57, 0.20), "leftWrist": (0.57, 0.09),
                "rightElbow": (0.34, 0.33), "rightWrist": (0.24, 0.33)
            ],
            overrides3D: [
                "leftElbow": [0.20, 0.75, 0.0], "leftWrist": [0.21, 1.00, 0.0],
                "rightElbow": [-0.47, 0.48, 0.0], "rightWrist": [-0.73, 0.48, 0.0]
            ]
        )
        let asymPass = CalibrationPoseScorers.evaluateAsymLR(asymSample)
        XCTAssertTrue(asymPass.passes)
        XCTAssertFalse(asymPass.lrSwapped)
        XCTAssertEqual(asymPass.cue, .none)
        XCTAssertEqual(try XCTUnwrap(asymPass.armSymmetryRatio), 1.0, accuracy: 0.05)

        // --- Pose 5: .armsForward ---
        let forwardSample = makeSample(
            overrides2D: [
                "leftElbow": (0.56, 0.35), "rightElbow": (0.44, 0.35),
                "leftWrist": (0.56, 0.34), "rightWrist": (0.44, 0.34)
            ],
            overrides3D: [
                "leftElbow": [0.19, 0.46, 0.26], "leftWrist": [0.19, 0.46, 0.50],
                "rightElbow": [-0.19, 0.46, 0.26], "rightWrist": [-0.19, 0.46, 0.50]
            ]
        )
        let forwardMonocularPass = CalibrationPoseScorers.evaluateArmsForward(forwardSample, cameraMode: .frontSelfView)
        XCTAssertTrue(forwardMonocularPass.passes)
        XCTAssertEqual(forwardMonocularPass.cue, .none)

        let forwardLiDARPass = CalibrationPoseScorers.evaluateArmsForward(
            forwardSample,
            cameraMode: .rearLiDAR,
            shoulderToWristDeltaZM: 0.515
        )
        XCTAssertTrue(forwardLiDARPass.passes)
        XCTAssertEqual(try XCTUnwrap(forwardLiDARPass.zDepthScaleRatio), 1.03, accuracy: 0.01)

        let forwardLiDARFail = CalibrationPoseScorers.evaluateArmsForward(
            forwardSample,
            cameraMode: .rearLiDAR,
            shoulderToWristDeltaZM: 0.10
        )
        XCTAssertFalse(forwardLiDARFail.passes)
        XCTAssertEqual(forwardLiDARFail.cue, .armsForward)

        // --- Pose 6: .plie ---
        let plieSample = makeSample(
            overrides2D: [
                "leftElbow": (0.66, 0.36), "rightElbow": (0.34, 0.36),
                "leftWrist": (0.76, 0.36), "rightWrist": (0.24, 0.36),
                "leftHip": (0.54, 0.59), "rightHip": (0.46, 0.59),
                "leftKnee": (0.56, 0.72), "rightKnee": (0.44, 0.72)
            ],
            overrides3D: [
                "leftElbow": [0.47, 0.48, 0.0], "leftWrist": [0.73, 0.48, 0.0],
                "rightElbow": [-0.47, 0.48, 0.0], "rightWrist": [-0.73, 0.48, 0.0],
                "leftKnee": [0.16, -0.38, 0.14], "leftAnkle": [0.11, -0.76, 0.0],
                "leftHeel": [0.11, -0.79, -0.07], "leftFootIndex": [0.11, -0.79, 0.16],
                "rightKnee": [-0.16, -0.38, 0.14], "rightAnkle": [-0.11, -0.76, 0.0],
                "rightHeel": [-0.11, -0.79, -0.07], "rightFootIndex": [-0.11, -0.79, 0.16]
            ]
        )
        let pliePass = CalibrationPoseScorers.evaluatePlie(
            plieSample,
            standingKneeFlexDeg: 6.5,
            restHipHeightNorm: restHipHeightNorm
        )
        XCTAssertTrue(pliePass.passes)
        XCTAssertEqual(pliePass.cue, .none)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(pliePass.meanKneeFlexDeg), 22.0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(pliePass.plieHipDropNorm), 0.04)

        let shallowPlie = CalibrationPoseScorers.evaluatePlie(
            makeTPoseSample(),
            standingKneeFlexDeg: 6.5,
            restHipHeightNorm: restHipHeightNorm
        )
        XCTAssertFalse(shallowPlie.passes)
        XCTAssertEqual(shallowPlie.cue, .bendKneesDeeper)

        // --- Pose 7: .turned45 ---
        // 45° yaw in XZ: dx = 2 * 0.134 = 0.268, dz = 2 * 0.134 = 0.268 -> atan2(dz, dx) = 45°.
        let turned45Sample = makeSample(
            overrides2D: [
                "leftShoulder": (0.542, 0.33), "rightShoulder": (0.458, 0.33), // width = 0.084 >= 0.045
                "leftElbow": (0.63, 0.33), "rightElbow": (0.37, 0.33),
                "leftWrist": (0.72, 0.33), "rightWrist": (0.28, 0.33)
            ],
            overrides3D: [
                "leftShoulder": [0.134, 0.48, -0.134],
                "rightShoulder": [-0.134, 0.48, 0.134],
                "leftElbow": [0.33, 0.48, -0.33], "leftWrist": [0.51, 0.48, -0.51],
                "rightElbow": [-0.33, 0.48, 0.33], "rightWrist": [-0.51, 0.48, 0.51]
            ]
        )
        let turnedPass = CalibrationPoseScorers.evaluateTurned45(turned45Sample)
        XCTAssertTrue(turnedPass.passes)
        XCTAssertEqual(turnedPass.cue, .none)
        XCTAssertEqual(try XCTUnwrap(turnedPass.shoulderYawDeg), 45.0, accuracy: 0.5)

        // Edge-on collapse (|ls.x - rs.x| < 0.045) -> .turnLessSideways.
        let edgeOnTurn = makeSample(
            overrides2D: [
                "leftShoulder": (0.515, 0.33), "rightShoulder": (0.485, 0.33), // width = 0.030 < 0.045
                "leftElbow": (0.60, 0.33), "rightElbow": (0.40, 0.33),
                "leftWrist": (0.68, 0.33), "rightWrist": (0.32, 0.33)
            ],
            overrides3D: [
                "leftShoulder": [0.03, 0.48, -0.18],
                "rightShoulder": [-0.03, 0.48, 0.18]
            ]
        )
        let edgeOnEval = CalibrationPoseScorers.evaluateTurned45(edgeOnTurn)
        XCTAssertFalse(edgeOnEval.passes)
        XCTAssertEqual(edgeOnEval.cue, .turnLessSideways)

        // --- Pose 8a & 8b: .stepLeft & .stepRight ---
        let stepLeftSample = makeSample(dx2D: 0.15) // hipCenterX = 0.65, shift = +0.15 >= 0.12
        let stepLeftPass = CalibrationPoseScorers.evaluateStepLeft(stepLeftSample, restHipCenterX: 0.50)
        XCTAssertTrue(stepLeftPass.passes)
        XCTAssertEqual(stepLeftPass.cue, .none)

        let stepRightSample = makeSample(dx2D: -0.15) // hipCenterX = 0.35, shift = +0.15 >= 0.12
        let stepRightPass = CalibrationPoseScorers.evaluateStepRight(stepRightSample, restHipCenterX: 0.50)
        XCTAssertTrue(stepRightPass.passes)
        XCTAssertEqual(stepRightPass.cue, .none)

        // Stepping past safe edge (maxX > 0.96) -> .stepBackLateralRoom.
        let stepClipped = makeSample(dx2D: 0.42) // leftShoulder.x = 0.98 > 0.96
        let stepClippedEval = CalibrationPoseScorers.evaluateStepLeft(stepClipped, restHipCenterX: 0.50)
        XCTAssertFalse(stepClippedEval.passes)
        XCTAssertEqual(stepClippedEval.cue, .stepBackLateralRoom)

        // --- Pose 9: .kneeLift ---
        let kneeLiftSample = makeSample(
            overrides2D: [
                "leftKnee": (0.55, 0.56),
                "leftAnkle": (0.54, 0.68),
                "leftHeel": (0.54, 0.70),
                "leftFootIndex": (0.55, 0.71)
            ],
            overrides3D: [
                // Left thigh raised forward/up, shin hanging down -> exterior knee flex ~88° >= 55°, ankle delta ~0.42 m.
                "leftKnee": [0.11, -0.02, 0.43],
                "leftAnkle": [0.11, -0.42, 0.41],
                "leftHeel": [0.11, -0.45, 0.35],
                "leftFootIndex": [0.11, -0.45, 0.55]
            ],
            visibility: [
                "leftHeel": 0.46,      // >= footFloorUsed (0.50) - 0.05 = 0.45
                "leftFootIndex": 0.46
            ]
        )
        let kneeLiftPass = CalibrationPoseScorers.evaluateKneeLift(kneeLiftSample)
        XCTAssertTrue(kneeLiftPass.passes)
        XCTAssertEqual(kneeLiftPass.cue, .none)
        XCTAssertEqual(kneeLiftPass.liftedSide, "left")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(kneeLiftPass.maxKneeFlexDeg), 55.0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(kneeLiftPass.ankleClearanceRatio), 0.18)
    }

    // MARK: - 2. Pose 4 Swapped L/R Detection (`testAsymLRDetectsSwappedSides`)

    func testAsymLRDetectsSwappedSides() {
        // Reversed pose: dancer raises anatomical RIGHT wrist overhead and stretches LEFT wrist out horizontally.
        let reversedSample = makeSample(
            overrides2D: [
                "rightElbow": (0.43, 0.20), "rightWrist": (0.43, 0.09),
                "leftElbow": (0.66, 0.33), "leftWrist": (0.76, 0.33)
            ],
            overrides3D: [
                "rightElbow": [-0.20, 0.75, 0.0], "rightWrist": [-0.21, 1.00, 0.0],
                "leftElbow": [0.47, 0.48, 0.0], "leftWrist": [0.73, 0.48, 0.0]
            ]
        )

        // Stateless single-sample evaluation immediately flags reversed sides.
        let singleEval = CalibrationPoseScorers.evaluateAsymLR(reversedSample)
        XCTAssertFalse(singleEval.passes)
        XCTAssertTrue(singleEval.isReversedPose)
        XCTAssertTrue(singleEval.lrSwapped)
        XCTAssertEqual(singleEval.cue, .swapArmsLR)

        // Stateful tracker debounces swap detection for >= 0.35 s, then clears lrSwapped once corrected.
        var tracker = CalibrationPoseScorers.AsymLRSwapTracker()
        let early = tracker.evaluate(timestamp: 10.0, sample: reversedSample)
        XCTAssertFalse(early.passes)
        XCTAssertTrue(early.isReversedPose)
        XCTAssertFalse(early.lrSwapped)
        XCTAssertEqual(early.cue, .asymPose)

        let mid = tracker.evaluate(timestamp: 10.20, sample: reversedSample)
        XCTAssertFalse(mid.lrSwapped)

        let latchedSwap = tracker.evaluate(timestamp: 10.36, sample: reversedSample)
        XCTAssertFalse(latchedSwap.passes)
        XCTAssertTrue(latchedSwap.lrSwapped)
        XCTAssertEqual(latchedSwap.cue, .swapArmsLR)

        // Dancer fixes sides (left overhead, right horizontal) -> passes and clears lrSwapped.
        let correctSample = makeSample(
            t: 10.60,
            overrides2D: [
                "leftElbow": (0.57, 0.20), "leftWrist": (0.57, 0.09),
                "rightElbow": (0.34, 0.33), "rightWrist": (0.24, 0.33)
            ],
            overrides3D: [
                "leftElbow": [0.20, 0.75, 0.0], "leftWrist": [0.21, 1.00, 0.0],
                "rightElbow": [-0.47, 0.48, 0.0], "rightWrist": [-0.73, 0.48, 0.0]
            ]
        )
        let corrected = tracker.evaluate(timestamp: 10.60, sample: correctSample)
        XCTAssertTrue(corrected.passes)
        XCTAssertFalse(corrected.lrSwapped)
        XCTAssertEqual(corrected.cue, .none)
        XCTAssertFalse(tracker.lrSwapped)
    }

    // MARK: - 3. Horizontal + Vertical FoV Minimum Distance (`testEffectiveMinDistanceEnforcesHorizontalFoVWidth`)

    func testEffectiveMinDistanceEnforcesHorizontalFoVWidth() throws {
        // Exact §3.2 / §6.1 studio geometry: 720x1280 portrait pinhole fx = fy = 959.6 -> thetaH ≈ 41.1°, thetaV ≈ 67.4°.
        let intrinsics = CalibrationIntrinsics.fromPinhole(
            fx: 959.6, fy: 959.6, cx: 360.0, cy: 640.0, width: 720, height: 1280
        )
        let dEff = CalibrationPoseScorers.effectiveMinDistanceM(
            hCam: 0.74,
            dancerHeightM: 1.73,
            wingspanM: 1.46,
            verticalFoVDeg: intrinsics.verticalFoVDeg,
            horizontalFoVDeg: intrinsics.horizontalFoVDeg
        )
        // d_vert_min = 2.13 m whereas portrait horizontal width constraint d_horiz_min = (1.46 + 0.55) / (2*360/959.6) = 2.68 m!
        XCTAssertEqual(dEff, 2.68, accuracy: 0.01)
        XCTAssertGreaterThan(dEff, 2.50, "Portrait horizontal FoV width must dominate over vertical-only 2.13 m")
        XCTAssertEqual(CalibrationPoseScorers.spokenTargetMinDistanceM(for: dEff), 3.0, accuracy: 1e-9)

        // Deriving portrait horizontal FoV implicitly from verticalFoVDeg matches explicit pinhole horizontalFoVDeg.
        let dEffImplicitHFoV = CalibrationPoseScorers.effectiveMinDistanceM(
            hCam: 0.74,
            dancerHeightM: 1.73,
            wingspanM: 1.46,
            verticalFoVDeg: intrinsics.verticalFoVDeg,
            horizontalFoVDeg: nil
        )
        XCTAssertEqual(dEffImplicitHFoV, dEff, accuracy: 1e-6)

        // Usable lateral span across [0.04, 0.96] at 2.85 m matches §6.1 `1.97 m`.
        let usableSpan = try XCTUnwrap(
            CalibrationPoseScorers.usableLateralSpanM(
                dancerDistanceM: 2.85,
                horizontalFoVDeg: intrinsics.horizontalFoVDeg
            )
        )
        XCTAssertEqual(usableSpan, 1.97, accuracy: 0.01)

        // Unknown FoV (0°) falls back to 60.0° vertical FoV rather than dividing by zero.
        let dFallback = CalibrationPoseScorers.effectiveMinDistanceM(
            hCam: 0.70,
            dancerHeightM: 1.73,
            wingspanM: 1.46,
            verticalFoVDeg: 0.0
        )
        XCTAssertGreaterThan(dFallback, 3.0)
        XCTAssertLessThanOrEqual(dFallback, 3.6)

        // Clamped into [2.0, 3.6] m at extreme ends.
        let dFloor = CalibrationPoseScorers.effectiveMinDistanceM(
            hCam: 0.70,
            dancerHeightM: 1.20,
            wingspanM: 0.95,
            verticalFoVDeg: 95.0
        )
        XCTAssertEqual(dFloor, 2.0, accuracy: 1e-9)

        let dCeil = CalibrationPoseScorers.effectiveMinDistanceM(
            hCam: 0.70,
            dancerHeightM: 2.05,
            wingspanM: 1.90,
            verticalFoVDeg: 45.0
        )
        XCTAssertEqual(dCeil, 3.6, accuracy: 1e-9)
    }

    // MARK: - 4. Coupled Span Bounds Across 2–4 m & Camera Modes (`testEffectiveSpanBoundsAcross2To4mAndModes`)

    func testEffectiveSpanBoundsAcross2To4mAndModes() throws {
        let intrinsics = CalibrationIntrinsics.fromPinhole(
            fx: 959.6, fy: 959.6, cx: 360.0, cy: 640.0, width: 720, height: 1280
        )
        let vFoV = intrinsics.verticalFoVDeg
        let hFoV = intrinsics.horizontalFoVDeg

        // Mode A (§3.5, §6.1): rearLiDAR at 2.85 m for 1.73 m dancer -> spanExpected ≈ 0.389, [0.303, 0.475].
        let bounds285 = CalibrationPoseScorers.effectiveSpanBounds(
            cameraMode: .rearLiDAR,
            calibrationTier: .tier2FullCalibration,
            dancerDistanceM: 2.85,
            measuredHeightM: 1.73,
            cameraHeightM: 0.74,
            wingspanM: 1.46,
            verticalFoVDeg: vFoV,
            horizontalFoVDeg: hFoV
        )
        XCTAssertEqual(try XCTUnwrap(bounds285.spanExpected), 0.389, accuracy: 0.002)
        XCTAssertEqual(bounds285.spanMinUsed, 0.303, accuracy: 0.002)
        XCTAssertEqual(bounds285.spanMaxUsed, 0.475, accuracy: 0.002)

        // Verify standing dancers across [2.68 m, 4.0 m] (where 2D span = 0.41 -> 0.28, and 0.24 for 1.50 m at 4.0 m)
        // pass .rest cleanly in rearLiDAR with zero conflicting .stepCloser cues!
        let testCases: [(distM: Double, heightM: Double, span2D: Double)] = [
            (2.68, 1.73, 0.420),
            (2.85, 1.73, 0.404),
            (3.30, 1.73, 0.340),
            (3.90, 1.73, 0.285),
            (4.00, 1.50, 0.240)
        ]
        for tc in testCases {
            let scale = tc.span2D / 0.63 // baseStanding2D span is 0.88 - 0.25 = 0.63
            let sample = makeSample(scale2D: scale)
            let eval = CalibrationPoseScorers.evaluateRest(
                sample,
                cameraMode: .rearLiDAR,
                calibrationTier: .tier2FullCalibration,
                dancerDistanceM: tc.distM,
                measuredHeightM: tc.heightM,
                cameraHeightM: 0.74,
                wingspanM: 0.85 * tc.heightM,
                verticalFoVDeg: vFoV,
                horizontalFoVDeg: hFoV
            )
            XCTAssertTrue(eval.passes, "Expected pass at \(tc.distM) m (height \(tc.heightM) m, span \(tc.span2D)), got cue \(eval.cue)")
            XCTAssertEqual(eval.cue, .none)
        }

        // Standing too close at 2.0 m (< d_effective_min = 2.68 m) in rearLiDAR emits .stepBackDistance (never .stepCloser).
        let nearSample = makeSample(scale2D: 0.55 / 0.63)
        let nearEval = CalibrationPoseScorers.evaluateRest(
            nearSample,
            cameraMode: .rearLiDAR,
            calibrationTier: .tier2FullCalibration,
            dancerDistanceM: 2.0,
            measuredHeightM: 1.73,
            cameraHeightM: 0.74,
            wingspanM: 1.46,
            verticalFoVDeg: vFoV,
            horizontalFoVDeg: hFoV
        )
        XCTAssertFalse(nearEval.passes)
        XCTAssertFalse(nearEval.framing.distanceEvaluation.distanceOK)
        XCTAssertEqual(nearEval.cue, .stepBackDistance)
        XCTAssertTrue(
            nearEval.cue.spokenText(dancerDistanceM: 2.0, effectiveMinDistanceM: 2.68)
                .contains("3.0 meters")
        )

        // Initial < 0.25 s rearLiDAR warm-up before first depth frame holds distanceOK = false with cue = .none.
        let warmupEval = CalibrationPoseScorers.evaluateRest(
            makeSample(scale2D: 0.40 / 0.63),
            cameraMode: .rearLiDAR,
            calibrationTier: .tier2FullCalibration,
            dancerDistanceM: nil,
            verticalFoVDeg: vFoV,
            horizontalFoVDeg: hFoV,
            warmupElapsedS: 0.10
        )
        XCTAssertFalse(warmupEval.passes)
        XCTAssertFalse(warmupEval.framing.distanceEvaluation.distanceOK)
        XCTAssertEqual(warmupEval.cue, .none)

        // Mode B (monocular Tier-2 with FoV, no depth): spanMinBase ≈ 0.240, spanMaxBase ≈ 0.506 (< 0.75).
        let monoTier2Bounds = CalibrationPoseScorers.effectiveSpanBounds(
            cameraMode: .rearWide,
            calibrationTier: .tier2FullCalibration,
            dancerDistanceM: nil,
            storedHeightM: 1.73,
            cameraHeightM: 0.74,
            wingspanM: 1.46,
            verticalFoVDeg: vFoV,
            horizontalFoVDeg: hFoV
        )
        XCTAssertNil(monoTier2Bounds.spanExpected)
        XCTAssertEqual(monoTier2Bounds.spanMinBase, 0.236, accuracy: 0.01)
        XCTAssertEqual(monoTier2Bounds.spanMaxBase, 0.506, accuracy: 0.02)

        // Mode B Tier-0 frontSelfView quick resume preserves spanMaxBase = 0.75.
        let frontTier0Bounds = CalibrationPoseScorers.effectiveSpanBounds(
            cameraMode: .frontSelfView,
            calibrationTier: .tier0InstantResume,
            dancerDistanceM: nil,
            verticalFoVDeg: vFoV
        )
        XCTAssertEqual(frontTier0Bounds.spanMaxBase, 0.75, accuracy: 1e-9)

        // Mode C (synthetic test with no FoV and no depth): uses [0.22, 0.75].
        let syntheticBounds = CalibrationPoseScorers.effectiveSpanBounds(
            cameraMode: .frontSelfView,
            calibrationTier: .tier2FullCalibration,
            dancerDistanceM: nil,
            verticalFoVDeg: nil
        )
        XCTAssertEqual(syntheticBounds.spanMinBase, 0.22, accuracy: 1e-9)
        XCTAssertEqual(syntheticBounds.spanMaxBase, 0.75, accuracy: 1e-9)
    }

    // MARK: - 5. Metric Scale, Wingspan, ROM & Confidence Weights (`testMetricScaleAndConfidenceWeights`)

    func testMetricScaleAndConfidenceWeights() throws {
        // Generate 15 T-pose frames whose MediaPipe world bones are shrunk by 1 / 1.064 relative to physical metres.
        let targetScale = 1.064
        let mpShrink = 1.0 / targetScale
        var tPoseFrames: [GrooveScoringEngine.RawPoseFrame] = []
        for i in 0..<15 {
            if let f = makeTPoseSample(t: Double(i) / 30.0, mpScale: mpShrink).frame {
                tPoseFrames.append(f)
            }
        }

        // LiDAR depth samples report true physical metres (with one noisy outlier bone to verify median robustness).
        let depth1 = CalibrationDepthSample(
            timestamp: 0.1,
            lidarBoneLengthsM: [
                "leftShoulder": 0.19, "rightShoulder": 0.19,
                "leftElbow": 0.28, "rightElbow": 0.28,
                "leftWrist": 0.26, "rightWrist": 0.26,
                "leftKnee": 0.43, "rightKnee": 0.43,
                "leftAnkle": 0.41, "rightAnkle": 0.65 // single noisy shin reading
            ]
        )
        let depth2 = CalibrationDepthSample(
            timestamp: 0.3,
            lidarBoneLengthsM: [
                "leftShoulder": 0.19, "rightShoulder": 0.19,
                "leftElbow": 0.28, "rightElbow": 0.28,
                "leftWrist": 0.26, "rightWrist": 0.26,
                "leftKnee": 0.43, "rightKnee": 0.43,
                "leftAnkle": 0.41, "rightAnkle": 0.41
            ]
        )

        let scale = CalibrationPoseScorers.metricScaleFactor(
            tPoseFrames: tPoseFrames,
            depthSamples: [depth1, depth2]
        )
        XCTAssertEqual(scale, targetScale, accuracy: 1e-4)

        // Without LiDAR samples, metricScaleFactor defaults to 1.0.
        XCTAssertEqual(
            CalibrationPoseScorers.metricScaleFactor(tPoseFrames: tPoseFrames, depthSamples: []),
            1.0,
            accuracy: 1e-9
        )

        // Calibrated bone lengths (19 canonical bones in metres) & wrist-to-wrist wingspanM (1.46 m).
        let bonesM = CalibrationPoseScorers.calibratedBoneLengthsM(
            tPoseFrames: tPoseFrames,
            metricScaleFactor: scale
        )
        XCTAssertEqual(bonesM.count, CanonicalSkeleton.canonicalBones.count)
        let wingspan = try XCTUnwrap(CalibrationPoseScorers.wristToWristWingspanM(from: bonesM))
        XCTAssertEqual(wingspan, 1.46, accuracy: 1e-4)

        // ROM summary builder.
        let rom = CalibrationPoseScorers.buildROM(
            standingKneeFlexValues: [6.0, 6.5, 7.0],
            trunkLeanValues: [2.5, 2.8, 3.1],
            shoulderElevationValues: [168.0, 171.0, 169.5],
            plieKneeFlexValues: [32.0, 34.0, 35.0],
            plieHipDropValues: [0.08, 0.09, 0.10],
            kneeLiftFlexValues: [74.0, 78.0, 76.0]
        )
        XCTAssertEqual(rom.standingKneeFlexDeg, 6.5, accuracy: 1e-6)
        XCTAssertEqual(rom.trunkLeanBaselineDeg, 2.8, accuracy: 1e-6)
        XCTAssertEqual(rom.maxShoulderElevationDeg, 171.0, accuracy: 1e-6)
        XCTAssertEqual(rom.plieKneeFlexDeg, 34.0, accuracy: 1e-6)
        XCTAssertEqual(rom.plieHipDropNorm, 0.09, accuracy: 1e-6)
        XCTAssertEqual(rom.maxKneeLiftFlexDeg, 78.0, accuracy: 1e-6)

        // p25 jointConfidenceWeights clamped to [0.50, 1.00] (§8.3).
        let visValues: [Double] = [0.60, 0.78, 0.85, 0.92, 0.96] // sorted index at p25 (0.25 * 4 = 1) -> 0.78
        let lowVisValues: [Double] = [0.20, 0.32, 0.40, 0.80, 0.90] // p25 = 0.32 -> clamped to 0.50
        var samples: [CalibrationPoseSample] = []
        for i in 0..<5 {
            samples.append(
                makeSample(
                    t: Double(i) * 0.1,
                    visibility: [
                        "leftHeel": visValues[i],
                        "rightHeel": lowVisValues[i],
                        "leftShoulder": 0.99
                    ]
                )
            )
        }
        let weights = CalibrationPoseScorers.aggregateJointConfidenceWeights(samples: samples)
        XCTAssertEqual(weights["leftHeel"] ?? 0.0, 0.78, accuracy: 1e-6)
        XCTAssertEqual(weights["rightHeel"] ?? 0.0, 0.50, accuracy: 1e-6)
        XCTAssertEqual(weights["leftShoulder"] ?? 0.0, 0.99, accuracy: 1e-6)
        XCTAssertEqual(weights.count, CanonicalSkeleton.mediapipeIndex.count)
    }

    // MARK: - 6. Shared PoseHoldTracker Hold, Dropout & Framing-Loss Semantics

    func testPoseHoldTrackerHoldDropoutAndFramingLoss() {
        var tracker = CalibrationPoseScorers.PoseHoldTracker()
        let sampleFrame = makeTPoseSample().frame

        // Hold Pose 2 (.tpose) for 1.0 s at 30 Hz (>= 15 samples) with a brief 0.10 s dropout inside 0.35 s tolerance.
        var completedAt: Double?
        for i in 0...36 {
            let t = Double(i) / 30.0
            let isDropout = (i == 12 || i == 13) // ~0.067 s < 0.35 s dropoutToleranceS
            let outcome = tracker.update(
                pose: .tpose,
                timestamp: t,
                posePasses: !isDropout,
                poseFailureCue: .armsOutT,
                framingCue: .none,
                bodyMotion: i == 0 ? nil : 0.005,
                frame: sampleFrame
            )
            if outcome.completed {
                completedAt = t
                break
            }
        }
        XCTAssertNotNil(completedAt)
        XCTAssertGreaterThanOrEqual(tracker.capturedFrames.count, 15)

        // Framing failure exceeding stepDropoutS (0.40 s) during .stepLeft flags framingLost = true and resets.
        tracker.reset()
        _ = tracker.update(
            pose: .stepLeft,
            timestamp: 0.0,
            posePasses: true,
            poseFailureCue: .stepLeft,
            framingCue: .none,
            bodyMotion: 0.005
        )
        let briefFramingGlitch = tracker.update(
            pose: .stepLeft,
            timestamp: 0.20,
            posePasses: false,
            poseFailureCue: .stepLeft,
            framingCue: .stepBackShowFeet,
            bodyMotion: 0.005
        )
        XCTAssertFalse(briefFramingGlitch.framingLost)

        let sustainedFramingLoss = tracker.update(
            pose: .stepLeft,
            timestamp: 0.65,
            posePasses: false,
            poseFailureCue: .stepLeft,
            framingCue: .stepBackShowFeet,
            bodyMotion: 0.005
        )
        XCTAssertTrue(sustainedFramingLoss.framingLost)
        XCTAssertEqual(sustainedFramingLoss.cue, .stepBackShowFeet)

        // Verify evaluateFraming bypasses centredOK and widens safeBox to [0.04, 0.96] during .stepLeft,
        // and allows partial lifted-foot visibility during .kneeLift when standing foot is visible.
        let wideLeftSample = makeSample(dx2D: 0.30) // hipCenterX = 0.80, leftWrist/Shoulder <= 0.89 <= 0.96
        let stepFraming = CalibrationPoseScorers.evaluateFraming(wideLeftSample, forPose: .stepLeft, passing: true)
        XCTAssertTrue(stepFraming.passes)
        XCTAssertEqual(stepFraming.cue, .none)

        let kneeLiftPartialFoot = makeSample(visibility: ["leftHeel": 0.30, "leftFootIndex": 0.30])
        let kneeLiftFraming = CalibrationPoseScorers.evaluateFraming(kneeLiftPartialFoot, forPose: .kneeLift, passing: true)
        XCTAssertTrue(kneeLiftFraming.passes)
        XCTAssertEqual(kneeLiftFraming.cue, .none)
    }
}
