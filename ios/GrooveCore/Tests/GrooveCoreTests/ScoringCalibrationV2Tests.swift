import Foundation
import XCTest
@testable import GrooveCore

/// Unit tests for Calibration v2 (`LearnerCalibrationV2`) integration in `GrooveScoringEngine`, `Retarget`, and
/// `ScoringFeatures` (spec §8, §9.1, §10 order #9).
final class ScoringCalibrationV2Tests: XCTestCase {

    typealias Engine = GrooveScoringEngine
    typealias Retarget = GrooveScoringEngine.Retarget

    // MARK: - Synthetic canonical skeleton builders

    /// Builds a full canonical frame (all 15 `requiredJoints` + elbows/wrists) with controllable knee flex,
    /// sagittal trunk lean, foot pitch, upper-arm elevation (`0` down, `90` T-pose, `180` overhead), and wrist X offset.
    private func makeCanonicalFrame(
        t: Double,
        scale: Double = 1.0,
        kneeFlexDeg: Double = 8.0,
        spineJackDeg: Double = 4.0,
        trunkLeanDeg: Double = 2.0,
        leftFootPitchDeg: Double = 0.0,
        rightFootPitchDeg: Double = 0.0,
        armElevationDeg: Double = 20.0,
        elbowFlexDeg: Double = 0.0,
        wristSlideX: Double = 0.0
    ) -> Engine.RawPoseFrame {
        let lowerRad = (trunkLeanDeg - 0.5 * spineJackDeg) * .pi / 180.0
        let upperRad = (trunkLeanDeg + 0.5 * spineJackDeg) * .pi / 180.0
        let spineLen = 0.25 * scale
        let spine = [0.0, spineLen * cos(lowerRad), spineLen * sin(lowerRad)]
        let centerShoulder = [
            0.0,
            spine[1] + spineLen * cos(upperRad),
            spine[2] + spineLen * sin(upperRad)
        ]

        let halfFlexRad = (0.5 * kneeFlexDeg) * .pi / 180.0
        let thighLen = 0.42 * scale
        let shinLen = 0.40 * scale
        let hipX = 0.11 * scale
        let kneeY = -thighLen * cos(halfFlexRad)
        let kneeZ = thighLen * sin(halfFlexRad)
        let ankleY = kneeY - shinLen * cos(halfFlexRad)
        let ankleZ = kneeZ - shinLen * sin(halfFlexRad)

        let footLen = 0.16 * scale
        let lPitchRad = leftFootPitchDeg * .pi / 180.0
        let rPitchRad = rightFootPitchDeg * .pi / 180.0
        let lHeel = [-hipX, ankleY - 0.04 * scale, ankleZ - 0.04 * scale]
        let rHeel = [hipX, ankleY - 0.04 * scale, ankleZ - 0.04 * scale]
        let lFootIdx = [lHeel[0], lHeel[1] + footLen * sin(lPitchRad), lHeel[2] + footLen * cos(lPitchRad)]
        let rFootIdx = [rHeel[0], rHeel[1] + footLen * sin(rPitchRad), rHeel[2] + footLen * cos(rPitchRad)]

        let shoulderHalfW = 0.18 * scale
        let lShoulder = [-shoulderHalfW, centerShoulder[1], centerShoulder[2]]
        let rShoulder = [shoulderHalfW, centerShoulder[1], centerShoulder[2]]

        // Elevation measured from downward (0 = straight down, 90 = out to side, 180 = straight up).
        let elevRad = armElevationDeg * .pi / 180.0
        let foreRad = (armElevationDeg + elbowFlexDeg) * .pi / 180.0
        let upperArmLen = 0.28 * scale
        let forearmLen = 0.26 * scale

        let lElbow = [
            lShoulder[0] - upperArmLen * sin(elevRad),
            lShoulder[1] - upperArmLen * cos(elevRad),
            lShoulder[2]
        ]
        let rElbow = [
            rShoulder[0] + upperArmLen * sin(elevRad),
            rShoulder[1] - upperArmLen * cos(elevRad),
            rShoulder[2]
        ]
        let lWrist = [
            lElbow[0] - forearmLen * sin(foreRad) + wristSlideX,
            lElbow[1] - forearmLen * cos(foreRad),
            lElbow[2]
        ]
        let rWrist = [
            rElbow[0] + forearmLen * sin(foreRad) + wristSlideX,
            rElbow[1] - forearmLen * cos(foreRad),
            rElbow[2]
        ]

        let joints: [String: [Double]] = [
            "root": [0.0, 0.0, 0.0],
            "spine": spine,
            "centerShoulder": centerShoulder,
            "nose": [0.0, centerShoulder[1] + 0.20 * scale, centerShoulder[2] + 0.02 * scale],
            "leftHip": [-hipX, 0.0, 0.0],
            "leftKnee": [-hipX, kneeY, kneeZ],
            "leftAnkle": [-hipX, ankleY, ankleZ],
            "leftHeel": lHeel,
            "leftFootIndex": lFootIdx,
            "rightHip": [hipX, 0.0, 0.0],
            "rightKnee": [hipX, kneeY, kneeZ],
            "rightAnkle": [hipX, ankleY, ankleZ],
            "rightHeel": rHeel,
            "rightFootIndex": rFootIdx,
            "leftShoulder": lShoulder,
            "leftElbow": lElbow,
            "leftWrist": lWrist,
            "rightShoulder": rShoulder,
            "rightElbow": rElbow,
            "rightWrist": rWrist
        ]
        let confidences = joints.mapValues { _ in 0.95 }
        return Engine.RawPoseFrame(t: t, joints: joints, confidences: confidences)
    }

    private func copyClip(
        _ clip: Engine.PoseClip,
        mirrored: Bool? = nil,
        calibrationFrames: [Engine.RawPoseFrame]? = nil,
        keepExistingCalibrationFrames: Bool = true,
        calibrationV2: LearnerCalibrationV2? = nil
    ) -> Engine.PoseClip {
        Engine.PoseClip(
            clip_id: clip.clip_id,
            move_tag: clip.move_tag,
            bpm: clip.bpm,
            beat_times: clip.beat_times,
            gravity_vector: clip.gravity_vector,
            mirrored: mirrored ?? clip.mirrored,
            audio_latency_ms: clip.audio_latency_ms,
            speed_pct: clip.speed_pct,
            expected: clip.expected,
            frames: clip.frames,
            windows: clip.windows,
            calibration_frames: keepExistingCalibrationFrames ? (calibrationFrames ?? clip.calibration_frames) : calibrationFrames,
            calibration_v2: calibrationV2
        )
    }

    private func loadDefaultConfig() throws -> Engine.GrooveConfig {
        let f = try LessonFixtures.get()
        return try Engine.decodeConfig(f.configData)
    }

    // MARK: - Tests

    func testCalibrationV2NilZeroDriftAndCodableRoundTrip() throws {
        let f = try LessonFixtures.get()
        let baseClip = try XCTUnwrap(f.dataset.golden_clips.first)
        XCTAssertNil(baseClip.calibration_v2)

        let v2 = LearnerCalibrationV2(
            metricScaleFactor: 1.064,
            dancerHeightM: 1.73,
            wingspanM: 1.46,
            boneLengthsM: ["spine": 0.24, "leftWrist": 0.26, "rightWrist": 0.26],
            rom: CalibrationROM(
                standingKneeFlexDeg: 6.5,
                plieKneeFlexDeg: 34.0,
                plieHipDropNorm: 0.09,
                maxShoulderElevationDeg: 171.0,
                maxKneeLiftFlexDeg: 78.0,
                trunkLeanBaselineDeg: 2.8
            ),
            jointConfidenceWeights: ["leftWrist": 0.91, "rightWrist": 0.91]
        )
        let clipWithV2 = copyClip(baseClip, calibrationV2: v2)
        let encoded = try JSONEncoder().encode(clipWithV2)
        let decoded = try JSONDecoder().decode(Engine.PoseClip.self, from: encoded)
        XCTAssertEqual(decoded.calibration_v2, v2)

        let retargeted = Retarget.retargetClip(clipWithV2, lengths: ["spine": 0.25])
        XCTAssertEqual(retargeted.calibration_v2, v2)
    }

    func testCalibrationV2PreservesRetargetDisabledDefault() throws {
        let f = try LessonFixtures.get()
        let defaultConfig = try Engine.decodeConfig(f.configData)
        XCTAssertEqual(defaultConfig.scoring_thresholds.retarget?.enabled, false)

        // `lesson_12_retarget_off` is a long-armed learner whose wrists fail joint verdicts unless retargeted.
        let uncalibrated = f.clip("lesson_12_retarget_off")
        let ref = try XCTUnwrap(f.dataset.references[uncalibrated.move_tag])
        let learnerBones = Retarget.medianBoneLengths(uncalibrated.frames)

        let calibratedNeutral = copyClip(
            uncalibrated,
            calibrationV2: LearnerCalibrationV2(
                metricScaleFactor: 1.0,
                boneLengthsM: learnerBones
            )
        )

        let baseRes = Engine.scoreAttempt(attempt: uncalibrated, reference: ref, config: defaultConfig)
        let calRes = Engine.scoreAttempt(attempt: calibratedNeutral, reference: ref, config: defaultConfig)

        // Even with `calibration_v2.boneLengthsM` populated, `retarget.enabled` stays `false` by default (§8.1).
        XCTAssertFalse(baseRes.retargeted)
        XCTAssertFalse(calRes.retargeted)
        XCTAssertEqual(calRes.passed, baseRes.passed)
        XCTAssertEqual(calRes.shape_score, baseRes.shape_score, accuracy: 1e-12)
        XCTAssertEqual(calRes.groove_score, baseRes.groove_score, accuracy: 1e-12)
        XCTAssertEqual(calRes.joint_feedback.counts, baseRes.joint_feedback.counts)
        XCTAssertEqual(
            calRes.joint_feedback.verdicts.map { $0.error },
            baseRes.joint_feedback.verdicts.map { $0.error }
        )
        let flagged = Set(calRes.joint_feedback.verdicts.filter { $0.severity != "ok" }.map { $0.joint })
        XCTAssertTrue(flagged.isSuperset(of: ["leftWrist", "rightWrist"]))
    }

    func testCalibrationV2BoneLengthsPriorityWhenRetargetEnabled() throws {
        // 1. Direct priority check: `calibration_v2.boneLengthsM` > `calibration_frames` > `attempt.frames`.
        let takeFrame = makeCanonicalFrame(t: 0.0, scale: 1.0)
        let stanceFrame = makeCanonicalFrame(t: 0.0, scale: 1.2)
        let v2Bones: [String: Double] = [
            "spine": 0.36,
            "leftWrist": 0.33,
            "rightWrist": 0.25
        ]

        let allSourcesClip = Engine.PoseClip(
            clip_id: "priority_all",
            move_tag: "m",
            bpm: 112.5,
            beat_times: [0.5],
            mirrored: false,
            frames: [takeFrame],
            calibration_frames: [stanceFrame],
            calibration_v2: LearnerCalibrationV2(boneLengthsM: v2Bones)
        )
        let fromV2 = Retarget.learnerBoneLengths(attempt: allSourcesClip)
        XCTAssertEqual(fromV2["spine"] ?? 0.0, 0.36, accuracy: 1e-12)
        XCTAssertEqual(fromV2["leftWrist"] ?? 0.0, 0.33, accuracy: 1e-12)
        XCTAssertEqual(fromV2["rightWrist"] ?? 0.0, 0.25, accuracy: 1e-12)

        // Mirrored attempt swaps `left*` <-> `right*` on `calibration_v2.boneLengthsM`.
        let mirroredClip = copyClip(allSourcesClip, mirrored: true, calibrationV2: allSourcesClip.calibration_v2)
        let mirroredLengths = Retarget.learnerBoneLengths(attempt: mirroredClip)
        XCTAssertEqual(mirroredLengths["leftWrist"] ?? 0.0, 0.25, accuracy: 1e-12)
        XCTAssertEqual(mirroredLengths["rightWrist"] ?? 0.0, 0.33, accuracy: 1e-12)
        XCTAssertEqual(mirroredLengths["spine"] ?? 0.0, 0.36, accuracy: 1e-12)

        // Empty `boneLengthsM` falls back to `calibration_frames`, then `attempt.frames`.
        let emptyV2Clip = copyClip(allSourcesClip, calibrationV2: LearnerCalibrationV2(boneLengthsM: [:]))
        XCTAssertEqual(Retarget.learnerBoneLengths(attempt: emptyV2Clip)["spine"] ?? 0.0, 0.25 * 1.2, accuracy: 1e-12)

        let takeOnlyClip = copyClip(
            allSourcesClip,
            calibrationFrames: nil,
            keepExistingCalibrationFrames: false,
            calibrationV2: LearnerCalibrationV2(boneLengthsM: [:])
        )
        XCTAssertEqual(Retarget.learnerBoneLengths(attempt: takeOnlyClip)["spine"] ?? 0.0, 0.25, accuracy: 1e-12)

        // 2. Full `scoreAttempt` integration when `retarget.enabled == true`:
        // Give `calibration_frames` mismatched short-arm teacher proportions while `calibration_v2.boneLengthsM`
        // carries the learner's true calibrated bone lengths; `calibration_v2.boneLengthsM` must win.
        let f = try LessonFixtures.get()
        let retargetOnConfig = try Engine.decodeConfig(
            f.configData,
            overrides: [LessonFixtures.json(#"{"scoring_thresholds": {"retarget": {"enabled": true}}}"#)]
        )
        let longArmedAttempt = f.clip("lesson_12_retarget_off")
        let shortRef = try XCTUnwrap(f.dataset.references[longArmedAttempt.move_tag])
        let trueLearnerBones = Retarget.medianBoneLengths(longArmedAttempt.frames)

        let wrongStanceOnly = copyClip(
            longArmedAttempt,
            calibrationFrames: [shortRef.frames[0]],
            calibrationV2: nil
        )
        let wrongStanceRes = Engine.scoreAttempt(attempt: wrongStanceOnly, reference: shortRef, config: retargetOnConfig)
        XCTAssertTrue(wrongStanceRes.retargeted)
        XCTAssertGreaterThan(
            (wrongStanceRes.joint_feedback.counts["warn"] ?? 0) + (wrongStanceRes.joint_feedback.counts["off"] ?? 0),
            0
        )

        let v2WinsAttempt = copyClip(
            longArmedAttempt,
            calibrationFrames: [shortRef.frames[0]],
            calibrationV2: LearnerCalibrationV2(boneLengthsM: trueLearnerBones)
        )
        let v2WinsRes = Engine.scoreAttempt(attempt: v2WinsAttempt, reference: shortRef, config: retargetOnConfig)
        XCTAssertTrue(v2WinsRes.retargeted)
        XCTAssertEqual(
            (v2WinsRes.joint_feedback.counts["warn"] ?? 0) + (v2WinsRes.joint_feedback.counts["off"] ?? 0),
            0
        )
    }

    func testCalibrationV2MetricScaleFactorVelocityScaling() throws {
        // Build a 3.0 s @ 30 fps canonical clip (`torsoScale = 0.50 m`). Only `leftWrist` & `rightWrist` move among
        // the 8 `MoveSegmenter.defaultJoints`, so per-frame energy is `(2 * wristSpeed) / 8 / 0.50 = 0.5 * wristSpeed`.
        let beatTimes = [0.80, 1.80]
        func buildHitFrames(wristSpeedMps: Double) -> [Engine.RawPoseFrame] {
            var xPos = 0.0
            let dt = 1.0 / 30.0
            var out: [Engine.RawPoseFrame] = []
            for i in 0..<90 {
                let t = Double(i) * dt
                let movingBeat1 = (i > 16 && i <= 23) // settles at frame 24 (t = 0.80 s)
                let movingBeat2 = (i > 46 && i <= 53) // settles at frame 54 (t = 1.80 s)
                if movingBeat1 {
                    xPos += wristSpeedMps * dt
                } else if movingBeat2 {
                    xPos -= wristSpeedMps * dt
                }
                out.append(makeCanonicalFrame(t: t, spineJackDeg: 0.0, trunkLeanDeg: 0.0, wristSlideX: xPos))
            }
            return out
        }

        let refFrames = buildHitFrames(wristSpeedMps: 3.0)   // raw energy = 1.50 >= 1.0 -> 2 clean hits
        let userFrames = buildHitFrames(wristSpeedMps: 1.76) // raw energy = 0.88 < 1.0 -> 0 hits without metric scale

        let baseCfg = try loadDefaultConfig()
        let t = baseCfg.scoring_thresholds
        let noSmoothConfig = Engine.GrooveConfig(
            version: baseCfg.version,
            scoring_thresholds: .init(
                timing: t.timing,
                shape: t.shape,
                groove: t.groove,
                coverage: t.coverage,
                gate: t.gate,
                smoothing: Engine.SmoothingConfig(enabled: false),
                hits: t.hits,
                joint_tolerance: t.joint_tolerance,
                hands: t.hands,
                retarget: t.retarget,
                tolerance: t.tolerance
            )
        )

        let refClip = Engine.PoseClip(clip_id: "ref_hits", move_tag: "hits_m", bpm: 60.0, beat_times: beatTimes, frames: refFrames)
        let uncalAttempt = Engine.PoseClip(clip_id: "usr_uncal", move_tag: "hits_m", bpm: 60.0, beat_times: beatTimes, frames: userFrames)
        let scaledAttempt = Engine.PoseClip(
            clip_id: "usr_scaled",
            move_tag: "hits_m",
            bpm: 60.0,
            beat_times: beatTimes,
            frames: userFrames,
            calibration_v2: LearnerCalibrationV2(metricScaleFactor: 1.25)
        )

        let uncalRes = Engine.scoreAttempt(attempt: uncalAttempt, reference: refClip, config: noSmoothConfig)
        let scaledRes = Engine.scoreAttempt(attempt: scaledAttempt, reference: refClip, config: noSmoothConfig)

        XCTAssertEqual(uncalRes.hit_timing.reference_hit_count, 2)
        XCTAssertEqual(uncalRes.hit_timing.user_hit_count, 0)
        XCTAssertEqual(uncalRes.hit_timing.matched_count, 0)
        XCTAssertEqual(uncalRes.hit_timing.hit_score, 0.0)

        // With `metricScaleFactor = 1.25`, `0.88 * 1.25 = 1.10 >= 1.0`, matching both reference hits on the beat.
        XCTAssertEqual(scaledRes.hit_timing.user_hit_count, 2)
        XCTAssertEqual(scaledRes.hit_timing.matched_count, 2)
        XCTAssertEqual(scaledRes.hit_timing.hit_score ?? 0.0, 100.0, accuracy: 1e-6)

        // Verify `measureClipLegScale` also incorporates `metricScaleFactor` (§8.1).
        let uncalLeg = Engine.measureClipLegScale(clip: uncalAttempt)
        let scaledLeg = Engine.measureClipLegScale(clip: scaledAttempt)
        XCTAssertEqual(scaledLeg, (uncalLeg * 1.25 * 10000.0).rounded() / 10000.0, accuracy: 1e-4)
    }

    func testCalibrationV2RomAndConfidenceScaling() throws {
        let baseCfg = try loadDefaultConfig()
        let t = baseCfg.scoring_thresholds
        let rawCfg = Engine.GrooveConfig(
            version: baseCfg.version,
            scoring_thresholds: .init(
                timing: t.timing,
                shape: t.shape,
                groove: t.groove,
                coverage: t.coverage,
                gate: t.gate,
                smoothing: Engine.SmoothingConfig(enabled: false),
                hits: t.hits,
                joint_tolerance: t.joint_tolerance,
                hands: t.hands,
                retarget: t.retarget,
                tolerance: t.tolerance
            )
        )

        // 100 BPM => period = 0.60 s = 18 frames @ 30 fps (even frame count hits both wave = 1.0 and wave = 0.0 exactly).
        let bpm = 100.0
        let period = 60.0 / bpm
        let beats = (0..<4).map { 0.6 + Double($0) * period }

        func bounceFrames(
            kneeAmpDeg: Double,
            trunkLeanOffsetDeg: Double = 0.0,
            footPitchDeg: Double = 0.0,
            armElevationDeg: Double = 20.0
        ) -> [Engine.RawPoseFrame] {
            (0..<95).map { i in
                let time = Double(i) / 30.0
                let phase = 2.0 * .pi * ((time - beats[0]) / period)
                let spinePhase = 2.0 * .pi * ((time - 0.066 - beats[0]) / period)
                let wave = 0.5 * (1.0 + cos(phase))
                let spineWave = 0.5 * (1.0 + cos(spinePhase))
                let spineJack = 4.0 + 12.0 * spineWave
                let trunkLean = 2.0 + trunkLeanOffsetDeg
                return makeCanonicalFrame(
                    t: time,
                    kneeFlexDeg: 8.0 + kneeAmpDeg * wave,
                    spineJackDeg: spineJack,
                    trunkLeanDeg: trunkLean,
                    leftFootPitchDeg: footPitchDeg,
                    rightFootPitchDeg: footPitchDeg,
                    armElevationDeg: armElevationDeg
                )
            }
        }

        // 1. §8.2 Plié Knee-Bounce Ceiling (`effectiveRefKneeRange = min(refKneeRange, max(15.0, plie - standing))`)
        let deepBounceRef = Engine.PoseClip(
            clip_id: "ref_bounce",
            move_tag: "bounce",
            bpm: bpm,
            beat_times: beats,
            frames: bounceFrames(kneeAmpDeg: 32.0)
        )
        let limitedRomAttempt = Engine.PoseClip(
            clip_id: "usr_limited_rom",
            move_tag: "bounce",
            bpm: bpm,
            beat_times: beats,
            frames: bounceFrames(kneeAmpDeg: 14.0)
        )
        let limitedUncal = Engine.scoreAttempt(attempt: limitedRomAttempt, reference: deepBounceRef, config: rawCfg)
        XCTAssertLessThan(limitedUncal.knee_flex_ratio, 0.50)

        let limitedCal = Engine.scoreAttempt(
            attempt: copyClip(
                limitedRomAttempt,
                calibrationV2: LearnerCalibrationV2(
                    rom: CalibrationROM(standingKneeFlexDeg: 6.0, plieKneeFlexDeg: 26.0, trunkLeanBaselineDeg: 2.0)
                )
            ),
            reference: deepBounceRef,
            config: rawCfg
        )
        // `effectiveRefKneeRange` drops from ~32 deg to `26 - 6 = 20 deg`, raising `knee_flex_ratio` above 0.65.
        XCTAssertEqual(limitedCal.knee_flex_ratio, 0.70, accuracy: 0.02)
        XCTAssertGreaterThan(limitedCal.groove_score, limitedUncal.groove_score)

        // Stiff-kneed takes (`userKneeRange = 3 deg`) still fail despite small calibrated plié range (`15 deg` floor).
        let stiffAttempt = Engine.PoseClip(
            clip_id: "usr_stiff",
            move_tag: "bounce",
            bpm: bpm,
            beat_times: beats,
            frames: bounceFrames(kneeAmpDeg: 3.0),
            calibration_v2: LearnerCalibrationV2(
                rom: CalibrationROM(standingKneeFlexDeg: 6.0, plieKneeFlexDeg: 14.0, trunkLeanBaselineDeg: 2.0)
            )
        )
        let stiffRes = Engine.scoreAttempt(attempt: stiffAttempt, reference: deepBounceRef, config: rawCfg)
        XCTAssertEqual(stiffRes.knee_flex_ratio, 0.20, accuracy: 0.02)
        XCTAssertLessThan(stiffRes.knee_flex_ratio, rawCfg.scoring_thresholds.groove.min_knee_flex_ratio)

        // 2. §8.2 Resting Trunk Lean Baseline (`clamp(rom.trunkLeanBaselineDeg - refRestTrunkLeanDeg, -5, 5)`)
        let forwardPostureAttempt = Engine.PoseClip(
            clip_id: "usr_posture",
            move_tag: "bounce",
            bpm: bpm,
            beat_times: beats,
            frames: bounceFrames(kneeAmpDeg: 32.0, trunkLeanOffsetDeg: 4.0)
        )
        let postureUncal = Engine.scoreAttempt(attempt: forwardPostureAttempt, reference: deepBounceRef, config: rawCfg)
        let uncalHipsErr = postureUncal.worst_joints.first { $0.joint == "hips" }?.mean_angle_error_deg ?? 0.0
        XCTAssertEqual(uncalHipsErr, 4.0, accuracy: 0.05)

        let postureCal = Engine.scoreAttempt(
            attempt: copyClip(
                forwardPostureAttempt,
                calibrationV2: LearnerCalibrationV2(
                    rom: CalibrationROM(standingKneeFlexDeg: 8.0, plieKneeFlexDeg: 40.0, trunkLeanBaselineDeg: 6.0)
                )
            ),
            reference: deepBounceRef,
            config: rawCfg
        )
        let calHipsErr = postureCal.worst_joints.first { $0.joint == "hips" }?.mean_angle_error_deg ?? 99.0
        XCTAssertEqual(calHipsErr, 0.0, accuracy: 0.05)
        XCTAssertGreaterThan(postureCal.shape_score, postureUncal.shape_score)

        // 3. §8.2 Overhead Tolerance Floor (`1.25x` on elbows & wrists when ref upper-arm elevation > maxShoulderElevationDeg)
        let overheadRef = Engine.PoseClip(
            clip_id: "ref_overhead",
            move_tag: "overhead",
            bpm: bpm,
            beat_times: beats,
            frames: bounceFrames(kneeAmpDeg: 24.0, armElevationDeg: 170.0)
        )
        let lowerOverheadUser = Engine.PoseClip(
            clip_id: "usr_overhead",
            move_tag: "overhead",
            bpm: bpm,
            beat_times: beats,
            frames: bounceFrames(kneeAmpDeg: 24.0, armElevationDeg: 145.0)
        )
        let overheadUncal = Engine.scoreAttempt(attempt: lowerOverheadUser, reference: overheadRef, config: rawCfg)
        let overheadWidened = Engine.scoreAttempt(
            attempt: copyClip(
                lowerOverheadUser,
                calibrationV2: LearnerCalibrationV2(
                    rom: CalibrationROM(maxShoulderElevationDeg: 150.0, trunkLeanBaselineDeg: 2.0)
                )
            ),
            reference: overheadRef,
            config: rawCfg
        )
        let uncalVerdictErrs = Dictionary(uniqueKeysWithValues: overheadUncal.joint_feedback.verdicts.map { ($0.joint, $0.error) })
        let widenedVerdictErrs = Dictionary(uniqueKeysWithValues: overheadWidened.joint_feedback.verdicts.map { ($0.joint, $0.error) })
        for armJoint in ["leftElbow", "rightElbow", "leftWrist", "rightWrist"] {
            let rawErr = try XCTUnwrap(uncalVerdictErrs[armJoint])
            let widErr = try XCTUnwrap(widenedVerdictErrs[armJoint])
            XCTAssertGreaterThan(rawErr, 0.02, armJoint)
            XCTAssertEqual(widErr, rawErr / 1.25, accuracy: 0.001, armJoint)
        }

        // 4. §8.3 Joint Verdict Tolerance Widening (`1.0 / clamp(w_j, 0.5, 1.0)`, up to `2.0x`)
        let lowConfWidened = Engine.scoreAttempt(
            attempt: copyClip(
                lowerOverheadUser,
                calibrationV2: LearnerCalibrationV2(
                    jointConfidenceWeights: ["leftWrist": 0.50, "rightWrist": 0.80, "leftElbow": 0.25]
                )
            ),
            reference: overheadRef,
            config: rawCfg
        )
        let confVerdictErrs = Dictionary(uniqueKeysWithValues: lowConfWidened.joint_feedback.verdicts.map { ($0.joint, $0.error) })
        XCTAssertEqual(
            try XCTUnwrap(confVerdictErrs["leftWrist"]),
            try XCTUnwrap(uncalVerdictErrs["leftWrist"]) * 0.50,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(confVerdictErrs["rightWrist"]),
            try XCTUnwrap(uncalVerdictErrs["rightWrist"]) * 0.80,
            accuracy: 0.001
        )
        // `0.25` clamps to `0.50` -> maximum `2.0x` tolerance widening.
        XCTAssertEqual(
            try XCTUnwrap(confVerdictErrs["leftElbow"]),
            try XCTUnwrap(uncalVerdictErrs["leftElbow"]) * 0.50,
            accuracy: 0.001
        )

        // 5. §8.3 Shape Sub-Weight Re-Normalization across constituent joint confidence weights
        let noisyFeetAttempt = Engine.PoseClip(
            clip_id: "usr_noisy_feet",
            move_tag: "bounce",
            bpm: bpm,
            beat_times: beats,
            frames: bounceFrames(kneeAmpDeg: 32.0, footPitchDeg: 18.0)
        )
        let shapeUncal = Engine.scoreAttempt(attempt: noisyFeetAttempt, reference: deepBounceRef, config: rawCfg)
        // Uncalibrated: 0.70 * 100 + 0.30 * (100 * (1 - 18/45)) = 70 + 18 = 88.0.
        XCTAssertEqual(shapeUncal.shape_score, 88.0, accuracy: 0.05)

        let shapeCal = Engine.scoreAttempt(
            attempt: copyClip(
                noisyFeetAttempt,
                calibrationV2: LearnerCalibrationV2(
                    jointConfidenceWeights: [
                        "leftHeel": 0.50, "leftFootIndex": 0.50,
                        "rightHeel": 0.50, "rightFootIndex": 0.50
                    ]
                )
            ),
            reference: deepBounceRef,
            config: rawCfg
        )
        // Re-normalized: (0.70 / 0.85) * 100 + (0.15 / 0.85) * 60 = 92.94.
        XCTAssertEqual(shapeCal.shape_score, 92.94, accuracy: 0.05)
        XCTAssertGreaterThan(shapeCal.shape_score, shapeUncal.shape_score)
    }
}
