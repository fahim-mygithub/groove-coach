# Groove Coach Calibration v2, Rear-Camera + LiDAR, AirPlay TV Stage & Gesture UI Plan

**Date:** 2026-11-26
**Order:** `calib2-plan-v4` (`Run: calib2`)
**Base commit:** `aa5953e`
**Target hardware:** `iPhone18,2` (iPhone 17 Pro Max), iOS 26.6.1, rear LiDAR scanner, live LAN Debug Link (`%LOCALAPPDATA%\groove-coach\debuglink\`)

Throughout this specification:
- Every factual claim cites an opened source from `docs/research/2026-11-26-owner-s-words-update-the-calibration/report.md`, `docs/research/2026-11-18-calibration-research.md`, `Chuyuyan/dance-trainer` (`src/pose/checkup.ts`), or an exact `file:line` in this repository.
- **(inference)** marks design thresholds, formulas, or dance-specific pose steps derived from first principles and existing repo constraints rather than copied verbatim from an external source.
- Any Apple SDK symbol or property whose documentation page was not opened in the two research reports is explicitly flagged and listed in **§11.1 (SDK facts to verify against Xcode headers)** rather than guessed.

---

## Executive Summary

Groove Coach shifts its primary studio setup from a phone-screen self-view to a **hands-free TV coaching stage**:
1. **Phone placement:** The iPhone sits in front of the TV (waist/table height, ~0.5–1.0 m high) with its **rear wide camera + LiDAR scanner** facing the dancer at **2.0–4.0 m**. Because the glowing TV is behind the phone, it naturally illuminates the dancer from the front (`2026-11-18-calibration-research.md:73,200`).
2. **Display split:** The dancer watches a dedicated **16:9 landscape External-Display `UIWindowScene`** over AirPlay (or USB-C → HDMI) while the phone shows a dark OLED minimal status/emergency-touch screen.
3. **Pose + LiDAR hybrid:** **MediaPipe `pose_landmarker_full` + `hand_landmarker`** remains the sole pose extractor for both live feedback (`LIVE_STREAM`) and authoritative post-take grading (`VIDEO`), preserving 100% model parity with authored lessons (`AttemptExport.swift:16-24`, `docs/specs/2026-10-31-course-platform-design.md:19-20,124`) and keeping CI's ban on Vision pose symbols intact (`.github/workflows/ios-sideload-ipa.yml:95-97`). **Rear LiDAR (`AVDepthData` + `AVCameraCalibrationData`)** runs at low rate (5–10 Hz) during calibration and idle checks—never during take recording—to calibrate camera height, floor plane, 2.0–4.0 m distance, metric dancer height, and a per-user `metricScaleFactor` mapping MediaPipe world bones to true physical metres.
4. **9-pose easiest-first dance calibration:** Modeled on `Chuyuyan/dance-trainer` (`src/pose/checkup.ts:6-11,66-121`) plus two dance additions (`stepLR`, `kneeLift`), persisted in a versioned `CalibrationProfile` v2 so full body/ROM calibration (~28 s) runs once per dancer, environment re-placement (~4 s) runs only when gravity or LiDAR floor height changes, and unmoved sessions resume in <1 s.
5. **Front-camera fallback:** Preserved as an automatic fallback (`CameraMode.frontSelfView`) whenever no external display is connected or when toggled manually.

---

## 1. Pose Pipeline on the Rear Camera (with Front-Camera Fallback)

### 1.1 Re-Weighing the Scholar Decision Matrix Without the Phone Self-View Constraint

In `docs/research/2026-11-26-owner-s-words-update-the-calibration/report.md:18-32`, Option (f) (*front wide camera, MediaPipe + Vision 3D, no depth*, **4.08 / 5.0**) beat Option (e) (*depth only for metric scale & floor plane*, **4.00**) and Option (b) (*rear LiDAR + `ARBodyTrackingConfiguration`*, **3.33**) solely because **Camera-Switching Cost / UX (25% weight)** scored rear-camera options `1.0 / 5.0` under the assumption that the dancer must see the phone screen (`report.md:19`).

With the TV displaying the coaching UI via AirPlay, the rear camera faces the dancer continuously across calibration *and* takes (zero camera-flip friction; UX = `5.0`). However, re-evaluating the three rear-camera candidates against Groove Coach's actual codebase and CI invariants reveals why **extractor parity** and **thermal budget** decide the winner:

| Pipeline Candidate | Scoring Extractor Parity | Mapping to 33-Landmark `CanonicalSkeleton` | Live FPS & Thermal Cost on `iPhone18,2` | Verdict |
|---|---|---|---|---|
| **A. ARKit `ARBodyTrackingConfiguration` + `ARFrame.sceneDepth`** (rear only, `report.md:39-45`) | **Breaks parity.** Outputs Apple's 3D body rig rather than MediaPipe's sha256-pinned `pose_landmarker_full`. `AttemptExport.canGrade` (`AttemptExport.swift:16-24`) and spec §2.2 (`2026-10-31-course-platform-design.md:124`) forbid grading cross-model poses. Lacks MediaPipe's 4 foot landmarks (`29..32`) required by `requiredFootJoints` (`ScoringEngine.swift:68-70,540-558`) and 21-point hands. | Requires a lossy cross-rig joint adapter; systematic joint-center offsets corrupt `spine_jack_angle`, `foot_pitch_deg`, and `Retarget.canonicalBones`. Also `ARSession` monopolizes the rear camera, conflicting with `PracticeCamera` + `TakeRecorder` (`PracticeCamera.swift:30,253`). | **High thermal cost.** Runs 60 Hz SLAM + neural 3D body + LiDAR `sceneDepth` simultaneously with AirPlay encoding and `AVPlayer` decode; if MediaPipe also runs for parity, ANE/GPU load doubles. | **Reject** |
| **B. AVFoundation Rear + MediaPipe + Vision 3D (`VNDetectHumanBodyPose3DRequest` with `AVDepthData`)** (`report.md:35-38`) | **Blocked by CI & redundant.** Both `.github/workflows/ios-sideload-ipa.yml:95-97` and `ios-testflight.yml:104-106` fail the build if `VNDetectHuman(Body|Hand)Pose` appears in `nm -u`. Vision 3D also lacks heel/toe landmarks (`2026-10-31-course-platform-design.md:173-194`). | Would require fusing Vision 3D's 17 body joints with MediaPipe's feet and hands—the exact dual-model architecture removed in the course-platform migration (`2026-10-31-course-platform-design.md:193`). | **Medium-High.** Runs two full 3D pose neural networks per frame (`MediaPipe` + `VNDetectHumanBodyPose3DRequest`) plus AirPlay video encode. | **Reject** |
| **C. Hybrid: AVFoundation Rear Camera + MediaPipe (`LIVE_STREAM` / `VIDEO`) + Low-Rate LiDAR `AVDepthData` Calibration** *(Recommended)* | **100% parity preserved.** `TakeRecorder` records 720×1280 H.264 `.mov` (`PracticeCamera.swift:278-281`); post-take scoring runs `MediaPipePoseProvider.extract(videoURL:)` (`MediaPipePoseProvider.swift:132-213`) + `HandPoseExtractor`, identical to lesson authoring. | **Direct, lossless.** Uses `CanonicalSkeleton.toCanonical` (`CanonicalSkeleton.swift:120-171`) on all 33 MediaPipe pose landmarks + 21 hand landmarks. LiDAR supplies a scalar `metricScaleFactor`, `floorPlane`, and `dancerDistanceM` without altering joint topology. | **Low thermal cost.** Capture locked to 30 fps (`1280×720`); `MediaPipePoseProvider.live` runs at 15–30 fps (`PracticeCamera.swift:190-205`); LiDAR depth runs **only** at 5–10 Hz during calibration and 1 Hz idle checks, **0 Hz during `.recording`**. | **Adopt** |

### 1.2 How Pipeline C Feeds Scoring, Live UI, and `CanonicalSkeleton`

1. **Capture Modes (`CameraMode`):**
   - `rearLiDAR` *(default when an external AirPlay/HDMI display is connected, or when manually selected on a LiDAR device)*: Configures `AVCaptureSession` on the rear LiDAR-capable wide camera (`position: .back`, `report.md:29`), delivering upright 720×1280 `32BGRA` video frames (`videoRotationAngle = 90`, un-mirrored buffer, `PracticeCamera.swift:156-169`) plus throttled `AVDepthData` + `AVCameraCalibrationData` (`report.md:11,93-95`). If a device lacks rear LiDAR, degrades gracefully to `rearWide` (rear wide camera without depth).
   - `frontSelfView` *(automatic fallback when no external display is connected, or via user toggle)*: Existing `.builtInWideAngleCamera` at `position: .front` (`PracticeCamera.swift:146`), phone-screen HUD (`CalibrationOverlayView.swift:204`), `metricScaleFactor = 1.0`, no LiDAR checks.
2. **Coordinate & Mirroring Invariance Across Rear and Front Cameras:**
   - A camera lens placed in front of the dancer facing their chest sees the dancer's **own right side** on the **left** side of the raw un-mirrored portrait image (`raw x < 0.5`) regardless of whether the hardware sensor is `.front` or `.back` (verified in `CalibrationGate.swift:9-12` and `CalibrationGateTests.swift:35`: `"leftShoulder": (0.56, 0.33), "rightShoulder": (0.44, 0.33)` — subject to Device Measurement Gate 1 confirming portrait `videoRotationAngle` on `.back` on `iPhone18,2`).
   - However, `AVCaptureVideoPreviewLayer` automatically mirrors `.front` previews (`isVideoMirrored = true`) and leaves `.back` previews **un-mirrored** by default (`ScreenStreamer.swift:128`). On the TV Coaching Stage, the dancer faces the TV like a studio mirror: moving toward their own left must move their image toward TV-left.
   - **Rule:** Keep `AVCaptureVideoDataOutput` un-mirrored (`isVideoMirrored = false`) in both modes so `MediaPipePoseProvider`, `TakeRecorder`, and `CalibrationGate` receive identical raw coordinates; explicitly mirror the preview layer on the TV (`automaticallyAdjustsVideoMirroring = false; isVideoMirrored = true`) and keep `PracticeCamera.mirrorForDisplay = true` (`PracticeCamera.swift:66,247-249`).
   - **Rear-vs-Front CoreMotion Gravity Z-Sign Flip (Critical Hardware Geometry):** In `CMDeviceMotion.gravity` (`CalibrationGate.swift:47,427-431`), `+Z` points out of the **front** screen while `-Z` points out of the **rear** lens. Aiming the **rear** camera slightly upward (`+10°` optical elevation from a `0.6 m` stand) tilts the front screen slightly *face-down* (`g.z > 0`), whereas aiming the **front** camera upward tilts the front screen *face-up* (`g.z < 0`). Consistent with `aicam` `FrameAnalyzer.swift` (`2026-11-18-calibration-research.md:115,708`), camera optical upward pitch is `atan2(+g.z, -g.y)` in `rearLiDAR`/`rearWide` mode vs `atan2(-g.z, -g.y)` in `frontSelfView` mode! Likewise, in `CanonicalSkeleton` (`+x` image-right, `+y` image-up, `+z` from dancer toward lens, `CanonicalSkeleton.swift:6-11`), device `gravity = (gx, gy, gz)` aligns directly with canonical camera axes on the **rear** camera (`+X` = optical right, `+Z` = toward lens), whereas on the **front** camera optical right is `-X` and toward-lens is `-Z` (`cameraGravity = [-gx, gy, -gz]`). Passing camera-frame gravity into `PoseClip.gravity_vector` ensures `applyGravityCorrection` (`ScoringEngine.swift:479-492`) un-tilts `trunk_lean_deg` in the right direction on both cameras.
3. **Mapping to `CanonicalSkeleton` (`groove.canonical/1`):**
   - `CanonicalSkeleton.toCanonical` (`CanonicalSkeleton.swift:120-171`) maps the 33 MediaPipe landmarks (`0` nose, `11..16` shoulders/elbows/wrists, `23..28` hips/knees/ankles, `29..32` heels/toes) plus synthesized `root`, `spine`, `centerShoulder` into root-relative canonical coordinates (`+x` image-right, `+y` up, `+z` toward camera, `CanonicalSkeleton.swift:6-11,76-79`).
   - LiDAR depth back-projects visible 2D joints `(u, v)` into metric camera-space 3D via `AVCameraCalibrationData.intrinsicMatrix` (`report.md:11,93-95`) during calibration holds. The median ratio of LiDAR 3D segment lengths (shoulders, thighs, shins, upper arms) to `CanonicalSkeleton.boneLengths(frame)` (`CanonicalSkeleton.swift:174-182`) yields `metricScaleFactor`, correcting MediaPipe's monocular GHUM scale drift (`report.md:120`) without changing a single joint index.
4. **Frame Rate & Thermal Budget (inference, verified in Device Gate 1):**
   - Cap `AVCaptureDevice` frame rate at **30 fps** (`1280×720`) during calibration and takes (`config/groove_config.json:17` lists 60 fps legacy target, whereas `PracticeCamera.swift:145` uses `.hd1280x720` default 30 fps and authoring references are 30 fps, `2026-10-31-course-platform-design.md:85`).
   - `MediaPipePoseProvider.live` runs asynchronously behind `analysisBusy` (`PracticeCamera.swift:190-195`) at **20–30 fps**; UI skeleton publishing stays throttled to **~15 Hz** (`0.066 s`, `PracticeCamera.swift:231`).
   - LiDAR `AVDepthDataOutput` runs at **5–10 Hz** during `.calibrating`, **1 Hz** in `.idle` (bump/floor watch), and is **disabled (`0 Hz`) during `.countIn`, `.recording`, and `.analyzing`**.
   - Phone screen dims/renders a static dark status card while the TV scene is active, eliminating dual-preview GPU compositing.

---

## 2. Dance Calibration Sequence (9 Poses, Easiest-First)

### 2.1 Coordinate Conventions & Design Rationale

Following `Chuyuyan/dance-trainer` (`src/pose/checkup.ts:9-10`, cited in `report.md:57-70`), steps run **easiest-first** so any failure immediately localizes whether the issue is framing, scale, vertical headroom, L/R mirroring, Z-depth, lower-body flexion, oblique angle, lateral studio width, or single-leg foot tracking.

Two coordinate conventions coexist in `GrooveCore` and must never be conflated:
- **Normalized 2D (`CalibrationLandmark`, `CalibrationGate.swift:65-75`):** Un-mirrored portrait buffer, `x ∈ [0, 1]` right, **`y ∈ [0, 1]` down**. Dancer's anatomical left is at `x > 0.5` (`CalibrationGateTests.swift:23,35`).
- **Canonical 3D (`RawPoseFrame.joints`, `CanonicalSkeleton.swift:6-11,76-79`):** Gravity-corrected via `GrooveScoringEngine.applyGravityCorrection` (`ScoringEngine.swift:479-492`), root-centered metres, **`+y` up**, **`+z` toward the camera**. Note that `FrameFeatures` knee flexion (`ScoringEngine.swift:524-530`) measures the **exterior** bend angle between `(knee - hip)` and `(ankle - knee)` (`0°` = straight leg, `25°–55°` = demi-plié), whereas `JointTolerance.defaultAngleTriples` (`JointTolerance.swift:54-58,187-196`) measures the **interior** joint angle (`180°` = straight). All knee criteria below use `FrameFeatures`'s exterior `knee_flex` convention (`0°` straight) for direct compatibility with `ScoringEngine`.

(`checkup.ts:97-104` also includes a `head` turn check; it is intentionally omitted because `CanonicalSkeleton.mediapipeIndex` (`CanonicalSkeleton.swift:19-29`) exposes only `nose`—no ears or eyes—and head yaw is ungraded in `ScoringEngine`.)

### 2.2 Step-by-Step Dance Calibration Specification

All hold times use **monotonic pose-stream wall-clock seconds** (`2026-11-18-calibration-research.md:191`), never frame counts. Because the dancer is watching the TV from 2–4 m, every step speaks a concise instruction via `CalibrationVoice` (`CalibrationVoice.swift:8,99`, rate `0.52`) on entry and plays a short rising two-tone confirmation chime (`CalibrationVoice.swift:131-148`) the instant each hold completes.

| # | Step ID | Source | Purpose | Pass Criterion | Hold / Dropout | Spoken Cue (Entry & Diagnostic) | Writes to `CalibrationProfile` v2 |
|---|---|---|---|---|---|---|---|
| **1** | `rest` | `checkup.ts:67-72` + `CalibrationGate.swift:777` | Full-body framing, leg/foot visibility, LiDAR 2–4 m distance, metric dancer height, resting posture baseline, & AE/AWB lock trigger. | Existing `evaluateFraming` passes (`coreVis >= 0.6`, `footVis >= 0.5`, `x ∈ [0.05, 0.95]`, `nose.y >= 0.20`, `maxFootY <= 0.95`, `span ∈ [0.45, 0.75]`, `hipCenterX ∈ [0.30, 0.70]`) **AND** arms relaxed (`lw.y, rw.y > hipY - 0.05·span`, `|wrist.x - hip.x| < 0.22`) **AND** (when rear LiDAR active) `dancerDistanceM ∈ [2.0, 4.0]` **AND** `bodyMotion <= 0.012` (enter) / `0.020` (stay). *(inference)* | **0.6 s** hold / **0.35 s** dropout *(inference)* | Entry: *"Stand in the box, feet visible, arms relaxed by your sides."* Diagnostics: existing `.stepBackShowFeet`, `.stepCloser`, `.stepBack`, `.moveLeft`, `.moveRight`, plus distance-specific cues (§3.5). | `dancerDistanceM`, `dancerHeightM`, `rom.standingKneeFlexDeg`, `rom.trunkLeanBaselineDeg`, initial torso/leg `jointConfidenceWeights`; triggers **AE/AWB lock** (§3.3). |
| **2** | `tpose` | `checkup.ts:73-78` + `OpenJustDance` (`CalibrationGate.swift:931`) | Unoccluded zero-foreshortening capture of all 19 canonical bone lengths (`Retarget.canonicalBones`), lateral wingspan room, & LiDAR-to-MediaPipe `metricScaleFactor`. | `tPoseScore >= 0.55` with sub-gates `sY > 0.30`, `sAng > 0.30`, `ext > -0.15` (`CalibrationGate.swift:957-958`), wrists inside `x ∈ [0.03, 0.97]`, `bodyMotion <= 0.012` / `0.020`, and `>= 15` frames captured (`report.md:59`, `CalibrationTuning.swift:146-155`). | **1.0 s** hold / **0.35 s** dropout | Entry: *"Arms straight out to the sides, like a T. Hold still."* Diagnostic if wrists clip X edges: *"Step back slightly so both hands stay in view."* | `calibrationFrames` (`>= 15` `RawPoseFrame`s), `metricScaleFactor` (`median(L_lidar / L_mp)`), `boneLengthsM` (19 bones in true m), `wingspanM`, arm `jointConfidenceWeights`. |
| **3** | `overhead` | `checkup.ts:79-84` | Verifies top-of-frame optical headroom for overhead choreography (`Crown Lotus`, `2026-10-31-course-platform-design.md:98`) and the `restartDrill` gesture (`GestureRecognizer.swift:147`), up/down axis polarity, & max shoulder elevation ROM. | Both wrists above nose in 2D (`lw.y < nose.y - 0.05·span`, `rw.y < nose.y - 0.05·span`), unclipped at top edge (`min(lw.y, rw.y) >= 0.02`, wrist visibility `>= 0.45`), 2D/3D interior elbow angle `>= 135°`, `bodyMotion <= 0.015` / `0.025`. *(inference)* | **0.7 s** hold / **0.35 s** dropout *(inference)* | Entry: *"Reach both arms straight up overhead."* Diagnostic if `min(lw.y, rw.y) < 0.02` or wrist lost: *"Step back a little so your raised hands stay in frame."* (`.stepBackHeadroom`) | `overheadHeadroomMinY`, `rom.maxShoulderElevationDeg` (torso-frame angle), overhead wrist/elbow confidence. |
| **4** | `asymLR` | `checkup.ts:85-90` | Explicit anatomical Left vs Right verification across camera sensor, TV mirror transform, and MediaPipe side labels (`checkup.ts:88`: *"left and right not being swapped"*). | Anatomical `leftWrist` overhead (`lw.y < nose.y - 0.03·span`, left elbow `>= 130°`) **AND** anatomical `rightWrist` horizontal (`|rw.y - rs.y| / torso <= 0.35`, `|rw.x - rs.x| / shoulder >= 0.80`, right elbow `>= 130°`), `bodyMotion <= 0.015` / `0.025`. If **reversed** (`rightWrist` up, `leftWrist` out for `>= 0.35 s`), emit `.swapArmsLR`. *(inference)* | **0.7 s** hold / **0.35 s** dropout *(inference)* | Entry: *"Raise your left arm straight up, and stretch your right arm out to the side."* Diagnostic on swap: *"Other side—raise your left arm up, right arm out."* | `lrVerified = true`, `armSymmetryRatio` (`leftArmM / rightArmM`), `lrSwapCount` in telemetry. |
| **5** | `armsForward` | `checkup.ts:91-96` | Tests monocular Z-depth under severe 2D foreshortening (`checkup.ts:94`) and cross-checks canonical `+z` against rear LiDAR `ΔZ`. | Canonical 3D wrists forward of shoulders (`lw3D.z - ls3D.z >= 0.25 m` and `rw3D.z - rs3D.z >= 0.25 m`), 2D wrists near shoulder height (`|w.y - s.y| / torso <= 0.40`), and when rear LiDAR active, `depthM(shoulder) - depthM(wrist) >= 0.25 m`, `bodyMotion <= 0.015` / `0.025`. *(inference)* | **0.7 s** hold / **0.35 s** dropout *(inference)* | Entry: *"Point both arms straight forward toward the camera."* Diagnostic: *"Bring both hands up to shoulder height, pointing at the lens."* | `zDepthScaleRatio` (`ΔZ_lidar / Δz_canonical`), foreshortened elbow/wrist `jointConfidenceWeights`. |
| **6** | `plie` | `checkup.ts:105-114` (`squat`) | Calibrates lower-body groove ROM (`mean_knee_flex` & `hip_height_norm`, `ScoringEngine.swift:529-531,561,613,910-917`) and verifies knee/ankle tracking under flexion. | Exterior `mean_knee_flex >= 22.0°` (and `>= standingKneeFlexDeg + 15.0°`), `hip_height_norm` drop `>= 0.04` below `rest`, arms out (`sY > 0.25`), ankles/feet visible (`>= footFloorUsed`), `bodyMotion <= 0.018` / `0.028`. *(inference)* | **0.8 s** hold / **0.35 s** dropout *(inference)* | Entry: *"Arms out, bend your knees into a gentle squat and hold."* Diagnostic: *"Bend your knees a little deeper, heels in view."* | `rom.plieKneeFlexDeg`, `rom.plieHipDropNorm`, flexed knee/ankle `jointConfidenceWeights`. |
| **7** | `turned45` | `checkup.ts:115-120,149` (`turned`) | Verifies torso-frame scoring (`ScoringFeatures.swift:429-445`) at ~45° oblique yaw without edge-on shoulder collapse (`checkup.ts:149`: `|ls.x - rs.x| < 0.045`). | Canonical 3D shoulder XZ yaw `atan2(|rs3D.z - ls3D.z|, |rs3D.x - ls3D.x|) ∈ [25°, 65°]`, 2D shoulder width `|ls.x - rs.x| >= 0.045` (`checkup.ts:149`), arms extended (`sAng > 0.25`), `bodyMotion <= 0.015` / `0.025`. *(inference)* | **0.7 s** hold / **0.35 s** dropout *(inference)* | Entry: *"Keep arms out and turn your whole body halfway to one side."* Diagnostic if `|ls.x - rs.x| < 0.045`: *"Turn a little less sideways so both shoulders are visible."* | `obliqueTrackingConfidence` (far-side wrist/elbow/hip/knee weights for occlusion scaling). |
| **8** | `stepLR` (`stepLeft` → `stepRight`) | Dance addition *(inference; `report.md:10,127` notes no OSS benchmark)* | Verifies physical lateral floor clearance (sofas/walls) and horizontal FoV margin for side-travel moves (`step_touch`, `IMG_4941` Segment B sweep, `hip_x_norm` in `ScoringEngine.swift:563,857-859`). | Two sub-holds: **8a (`stepLeft`):** `hipCenterX - restHipCenterX >= 0.12` (dancer moved left, raw `x` increased) with all core+foot `x <= 0.96`; **8b (`stepRight`):** `restHipCenterX - hipCenterX >= 0.12` with all core+foot `x >= 0.04`, `bodyMotion <= 0.020` / `0.030`. *(inference)* | **0.5 s** left + **0.5 s** right / **0.40 s** dropout *(inference)* | 8a: *"Take a wide dance step to your left and pause."* → chime → 8b: *"Now take a wide step to your right and pause."* Diagnostic if edge clipped: *"Step back slightly for more side-to-side room."* | `usableLateralSpanM`, `maxSafeHipXNorm`, lateral-edge foot confidence. |
| **9** | `kneeLift` | Dance addition *(inference; `report.md:10,127` notes no OSS benchmark)* | Tests single-leg balance, kick/bounce hip flexion, MediaPipe L/R ankle non-swapping when feet separate vertically, & lifted foot keypoint (`Heel`, `FootIndex`) confidence out of floor shadow (`ScoringEngine.swift:68-70,540-558`). | `max(leftKneeFlex, rightKneeFlex) >= 55.0°` exterior flexion **AND** gravity-aligned ankle height delta `|la3D.y - ra3D.y| >= 0.18 · legScale`, standing ankle + both knees `>= coreFloorUsed`, lifted heel/toe `>= footFloorUsed - 0.05`, relaxed single-leg sway `bodyMotion <= 0.025` / `0.035`. *(inference)* | **0.5 s** hold / **0.45 s** dropout *(inference)* | Entry: *"Lift one knee up toward hip height for a moment."* → final lock chime + *"Locked in! Studio calibrated."* | `rom.maxKneeLiftFlexDeg`, lifted-foot confidence, finalized per-joint `jointConfidenceWeights`. |

---

## 3. Camera + LiDAR Calibration

### 3.1 Camera Intrinsics & Lens Distortion

Per `report.md:11,93-100`:
1. **LiDAR Depth Alignment (`AVCameraCalibrationData`):** Read `depthData.cameraCalibrationData` on `AVDepthData` frames (`report.md:93-95`: `AVCameraCalibrationData` is delivered on `AVDepthData` or `AVCapturePhoto`, *not* on video `CMSampleBuffer`s). Extract `intrinsicMatrix` ($3\times 3$ pinhole matrix with focal lengths $f_x, f_y$ and principal point $c_x, c_y$), `intrinsicMatrixReferenceDimensions`, `lensDistortionLookupTable`, and `lensDistortionCenter`. Scale $(f_x, f_y, c_x, c_y)$ linearly from `intrinsicMatrixReferenceDimensions` to the `AVDepthData` map dimensions (typically `320×240` or `256×192` float32 metres) before back-projecting 2D pixels $(u, v)$ to metric 3D camera coordinates:
   $$X = \frac{(u - c_x) Z}{f_x}, \quad Y = \frac{(v - c_y) Z}{f_y}, \quad Z = \text{depth}(u, v)$$
2. **Per-Frame Video Intrinsics (`frontSelfView` & `rearWide` fallback):** On the `AVCaptureVideoDataOutput` connection (`PracticeCamera.swift:166`), guard `connection.isCameraIntrinsicMatrixDeliverySupported` and set `connection.isCameraIntrinsicMatrixDeliveryEnabled = true` (`report.md:98-100`). Read `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` from video `CMSampleBuffer`s. *(Note: verify portrait 90° rotation axis order on `iPhone18,2` in Device Gate 1; see §11.1.)*

### 3.2 Field of View (FoV) & Runtime Minimum Distance

Per `report.md:101-104` and `2026-11-18-calibration-research.md:132-140`:
- Read `captureDevice.activeFormat.videoFieldOfView` (degrees; returns `0` if unknown, `report.md:103`; fall back to `60.0°` when `0`, `2026-11-18-calibration-research.md:140`).
- Because `videoFieldOfView` is the sensor's horizontal (long-side) FoV, in portrait orientation (`720×1280`, aspect $9:16$) it represents the **vertical** FoV $\theta_V$, while horizontal portrait FoV is $\theta_H = 2 \arctan\left(\frac{9}{16} \tan(\theta_V / 2)\right)$ (`2026-11-18-calibration-research.md:24,132`).
- Compute the geometric minimum stand-back distance (`2026-11-18-calibration-research.md:134`):
  $$d_{\min} = \frac{\max(h_{\text{cam}},\, 1.25 \cdot H_{\text{dancer}} - h_{\text{cam}})}{\tan(\theta_V / 2)}$$
  where $1.25 \cdot H_{\text{dancer}}$ reserves headroom for `overhead` choreography and `restartDrill`. Retain `16:9` (`1280×720`) capture in v2 rather than switching to `4:3`, because `MediaPipePoseProvider.swift:185,295` and `PracticeCamera.swift:33` assume `9.0 / 16.0` (`2026-11-18-calibration-research.md:144-148`).

### 3.3 Exposure & White-Balance Lock After Lighting / Rest Step

Per `report.md:105-115` and `2026-11-18-calibration-research.md:195-207`:
1. **Lighting Advice Remains Non-Blocking:** `CalibrationSensors.lightSample` (`CalibrationSensors.swift:69-124`) continues running at 2 Hz alongside Steps 1–2 (`meanLuma < 0.22`, `exposureSeconds >= 0.033`, `iso >= 450` or `iso/maxISO >= 0.80`, backlight `borderLuma - torsoLuma > 0.35` with `torsoLuma < 0.25`, `CalibrationTuning.swift:139-145`). It emits spoken/visual advice without blocking (`CalibrationGate.swift:671-691`).
2. **When to Lock AE/AWB:** Lock **immediately when Step 2 (`rest`) finishes**—never during Step 1 (`level`), when hands or walls dominate the meter, and before Step 3 (`tpose`), so auto-exposure and auto-white-balance do not pump as the dancer sweeps arms or steps across background windows during Steps 3–9 and subsequent takes (`MET-POSE`, `2026-11-18-calibration-research.md:201`).
3. **How to Lock (`report.md:105-115`):** Inside `device.lockForConfiguration()` / `device.unlockForConfiguration()`:
   - **Motion-Blur Shutter Cap *(inference)*:** Fast dance wrist/foot hits blur above `1/60 s` (`0.0167 s`). If `device.exposureDuration.seconds > 0.0167` and `device.isExposureModeSupported(.custom)`, compute `lockedDuration = 1/60 s` and scale `lockedISO = min(activeFormat.maxISO * 0.75, device.iso * (currentDuration / 0.0167))` to preserve scene EV, then call `setExposureModeCustom(duration:iso:completionHandler:)` (`report.md:108-109`). Otherwise, if `device.exposureDuration.seconds <= 0.0167` and `device.isExposureModeSupported(.locked)`, set `device.exposureMode = .locked` (`report.md:106-107`).
   - **White Balance Lock:** If `device.isWhiteBalanceModeSupported(.locked)`, set `device.whiteBalanceMode = .locked` (`report.md:111-112`, or `setWhiteBalanceModeLocked(with:completionHandler:)` with current `deviceWhiteBalanceGains` clamped to `[1.0, maxWhiteBalanceGain]`, `report.md:113-114`).
   - **Re-Meter Guard *(inference)*:** Record `lockedMeanLuma` at lock time. Between takes (in `.idle` / `.results`), if 2 Hz `meanLuma` drifts by `|meanLuma - lockedMeanLuma| > 0.20` (e.g., room lights toggled or daylight shifted), revert to `.continuousAutoExposure` / `.continuousAutoWhiteBalance` for 1.0 s and re-lock. Always unlock on `camera.stop()` or `calibration.cancel()`.

### 3.4 Floor Plane & Camera Height / Tilt from LiDAR

Per `report.md:42-50`, rear iPhone LiDAR measures static planes to `~1 mm` precision and rooms to a few centimetres out to `5.0 m` (`Scannr`, `report.md:46-50`).
1. **Gravity-Guided Floor RANSAC *(inference)*:**
   - Convert `CMDeviceMotion.gravity` (`CalibrationSensors.swift:38-40`) into the expected floor normal $\hat{n}_g = -\text{normalize}(\mathbf{g})$ in camera space.
   - Sample a sparse grid of valid LiDAR depth pixels $(u, v, Z)$ with $Z \in [1.0, 4.8]\text{ m}$ in the lower third of the portrait frame (`v / H >= 0.65`, excluding pixels inside the dancer's bounding box once present) and back-project to 3D points $\mathbf{P}_i$.
   - Fit plane $\hat{n}_{\text{floor}} \cdot \mathbf{P} + d_{\text{floor}} = 0$ via 40-iteration 3-point RANSAC (`inlierThreshold = 0.02 m`), accepting only candidate normals within `15°` of $\hat{n}_g$ so walls, couches, and coffee tables cannot win. Require `>= 80` inlier points.
2. **Derived Calibration Values:**
   - **Camera Height (`cameraHeightM`):** $h_{\text{cam}} = d_{\text{floor}}$ (perpendicular distance from lens to floor, metres). Advisory voice cue if `< 0.35 m` (*"Raise the phone off the floor to waist or table height if you can"*) or `> 1.50 m` (`2026-11-18-calibration-research.md:105-106`).
   - **LiDAR-vs-Gravity Tilt Cross-Check (`lidarFloorTiltDeg`):** $\arccos(\text{clamp}(\hat{n}_{\text{floor}} \cdot \hat{n}_g, -1, 1)) \cdot \frac{180}{\pi}$. On a level floor this verifies CoreMotion `tiltBackDeg = atan2(-g.z, -g.y)` (`CalibrationGate.swift:429-431`) to `< 3.0°`, resolving Risk 1 of `2026-11-18-calibration-research.md:643`.

### 3.5 Metric Dancer Height & 2–4 m Distance Check

1. **Distance Check (`2.0 m <= dancerDistanceM <= 4.0 m`):**
   - Sample median LiDAR depth $Z$ across $5\times 5$ depth patches centered on the 2D mid-hip and mid-shoulder landmarks (`dancerDistanceM`).
   - Why `2.0–4.0 m`: Below `2.0 m`, raised arms and side steps clip the portrait FoV (`2026-11-18-calibration-research.md:140`); above `4.0 m`, LiDAR approaches its `5.0 m` hardware cutoff (`report.md:48`) and pixel density on hands/feet degrades (`checkup.ts:145`). Hysteresis widens hold bounds by `±0.25 m` (`[1.75, 4.25] m`); relaxed mode after 15 s widens to `[1.70, 4.30] m`.
   - Spoken cues include the live metric reading rounded to `0.5 m` when out of range *(inference)*: *"You're at 1.5 meters—step back past 2 meters"* or *"You're over 4 meters away—step a little closer."*
2. **Metric Dancer Height (`dancerHeightM`):**
   - Back-project 2D `nose` at `Z_torso` to 3D $\mathbf{P}_{\text{nose}}$; compute height of nose above the LiDAR floor plane $h_{\text{nose}} = \hat{n}_{\text{floor}} \cdot \mathbf{P}_{\text{nose}} + d_{\text{floor}}$.
   - Add crown offset using `baby.py`'s verified `0.15 × (h_nose - h_heel)` rule (`2026-11-18-calibration-research.md:50`): $H_{\text{dancer}} = h_{\text{nose}} + 0.15 \cdot (h_{\text{nose}} - h_{\text{heel}})$, validated within `[1.10, 2.20] m`.

---

## 4. AirPlay to TV Architecture & Audio/Video/Scoring Sync

### 4.1 Screen Mirroring vs Dedicated External-Display `UIWindowScene`

| Option | TV Screen Utilization | Teacher + Learner Layout | `AVPlayer` Conflict Risk | Phone Thermal / Power Cost | Verdict |
|---|---|---|---|---|---|
| **Plain iOS Screen Mirroring only** | **~31.6% of TV area.** Portrait `9:16` phone UI (`project.yml:51-52`) pillarboxes into the center third of a `16:9` TV; `120×190 pt` teacher PiP (`LessonPlayerView.swift:126`) is unreadable from 3 m. | Cramped portrait stack; touch buttons clutter the TV. | High unless `allowsExternalPlayback = false` is set explicitly. | High: renders full 120 Hz camera + video UI on the unseen phone screen. | **Fallback only** |
| **Dedicated External-Display `UIWindowScene` ("TV Coaching Stage") + Minimal Phone Controller** *(Recommended)* | **100% of 16:9 1080p/4K TV.** Full landscape 10-foot UI with ≥28–96 pt typography readable at 4 m. | Side-by-side 50/50 split stage (Teacher left, Mirrored Learner + Skeleton right) during takes; giant pose mannequin + hold ring during calibration. | Controlled: `player.allowsExternalPlayback = false` keeps `AVPlayer` inside our composite TV scene rather than AirPlay Video hijacking the whole TV. | Low: phone shows a static dark `#000000` status card with 0 preview layers. | **Adopt** |

*(Note: When the user enables AirPlay Screen Mirroring from iOS Control Center—or plugs in a USB-C → HDMI adapter—iOS attaches an external screen and creates a `UIWindowScene` for the external display role; exact `Info.plist` scene manifest keys to verify in Xcode headers are listed in §11.1.)*

**TV Coaching Stage Layouts (`TVCoachingStageView`):**
1. **Calibration Stage:** Left 40% shows a large high-contrast target pose mannequin/diagram for the current step (`1 of 9`), step title, spoken cue banner (`42 pt` bold), and 9-dot step progress bar; Right 60% shows the mirrored rear-camera feed, green/red safe-box, live skeleton, LiDAR distance pill (`"2.8 m · Floor Locked"`), and a `160 pt` radial hold ring.
2. **Lesson / Practice Stage:** Left 50% renders `PlayerLayerView` (`LessonPlayerView.swift:1131`, flipped when `isMirrored == true`); Right 50% renders mirrored `CameraPreview` + `LiveOverlay` (`LiveMatcher` ok/warn/off limb colors and clean-beat streak badge, `LiveMatcher.swift:36-39`). Center-spanning HUD renders the giant `4-3-2-1` count-in (`96 pt`), `1..8` beat bar (`LessonPlayerView.swift:237-267`), and gesture progress/toast banner.
3. **Results Stage:** Landscape 10-foot scorecard (`Pass / Keep Drilling`, Shape/Groove/Hits/Hands chips, top joint hint, worst beat offset, coloured stick figure) with large gesture action icons along the bottom (*"Swipe Left: Try Again · Swipe Right: Next · Clap: Continue"*).
4. **Phone Screen (`PhoneControllerStatusView` while TV Connected):** Pure black OLED canvas, dim status header (*"TV Stage Active · Rear Camera + LiDAR · 2.8 m"*), AirPlay audio route badge, and three oversized emergency touch buttons: **Pause / Resume**, **Skip Calibration**, and **Use Phone Screen (Front Camera)**.

### 4.2 AirPlay Latency vs Audio, Video, and Scoring Synchronization

Wireless AirPlay introduces two distinct latencies that must be kept aligned with `CMClockGetHostTimeClock()` (`PracticeCamera.swift:180`, `PoseExporterApp.swift:314`):
- **AirPlay Audio Latency ($\Delta_{\text{audio}}$):** Typically `150–250 ms`. Reported by `AVAudioSession.sharedInstance().outputLatency * 1000.0` (`Metronome.swift:19-21`) and already subtracted from learner turnaround/hit timestamps in `GrooveScoringEngine.scoreAttempt` (`ScoringEngine.swift:805`, `ScoringFeatures.swift:583-586`)!
- **AirPlay Screen/Scene Video Latency ($\Delta_{\text{tv\_video}}$):** Wireless H.264/HEVC display mirroring adds `~60–250 ms` of visual delay on the TV, while iPhone rear-camera `CMSampleBuffer` capture has `< 5 ms` local host-clock latency (`PracticeCamera.swift:186`).

**Three-Part Synchronization Design:**
1. **Shared Host-Clock Start for Audio + Teacher Video (`LessonPlayerView.swift:769-777`):**
   - Keep `Metronome.startScheduled` (`Metronome.swift:31-65`) and `player.setRate(Float(playbackRate), time: segment.startS, atHostTime: hostClockTime)` anchored to the exact same `mach_absolute_time()` start. Set `player.allowsExternalPlayback = false` so both `AVPlayer` audio and `Metronome` clicks mix through the same iOS system audio pipeline to AirPlay, while iOS AirPlay Mirroring paces the external `UIWindowScene` frames against that same AirPlay audio stream.
2. **Live Feedback Immunity (`LiveMatcher.swift:41`):**
   - `LiveMatcher` searches `lagRangeMs = 0...400 ms` (`LiveMatcher.swift:41`) when coloring live limbs green/amber/red. Up to `400 ms` of combined AirPlay visual + human reaction lag is absorbed automatically without penalizing live streak feedback.
3. **1-Clap End-to-End AirPlay Sync Calibration (`verifyClapSync`, `ScoringEngine.swift:693-724`):**
   - Smart TVs often add `20–100 ms` of internal HDMI/soundbar DSP delay not reflected in `AVAudioSession.outputLatency`.
   - When an external AirPlay display or Bluetooth/AirPlay audio route (`outputLatencyMs > 60 ms`) is active and uncalibrated for the current `AVAudioSessionPortDescription.uid`, run a **4-beat rhythm clap check** (*"Clap on four: 1, 2, 3, CLAP!"*) at the end of calibration. Feed the camera wrist distances and `frameHostTimes` into the already-built `GrooveScoringEngine.verifyClapSync` (`ScoringEngine.swift:693-724`) against beat 4's scheduled `hostSeconds + outputLatencyS`. Store the residual `airplayAudioOffsetMs = clamp(offset_ms, -150, +250)` keyed by `audioRoutePortUID` in `CalibrationProfile` v2, and pass `effectiveAudioLatencyMs = metronome.outputLatencyMs + airplayAudioOffsetMs` into `PoseClip.audio_latency_ms` (`PracticeView.swift:186`, `LessonPlayerView.swift:913`).

### 4.3 What Happens When AirPlay Drops

Observe `UIScene.didDisconnectNotification` and `AVAudioSession.routeChangeNotification` (`.oldDeviceUnavailable`):
1. **Mid-Take (`.countIn` or `.recording`):** Immediately abort and transition to `.paused` (`abortTake`, `PracticeView.swift:244`, `LessonPlayerView.swift:826`). **Never** call `recordTake(passed: false, ...)` (`LessonPlayerView.swift:985`), so an AirPlay drop never demotes the learner on the adaptive speed ladder. Re-activate `CalibrationVoice` on the iPhone's built-in speaker and speak: *"TV disconnected. Take paused. Reconnect AirPlay, or tap Use Front Camera on your phone."*
2. **Mid-Calibration (`.calibrating`):** Cancel active hold (`calibration.cancel()`), preserve any already-persisted `CalibrationProfile` v2 on disk, speak *"TV disconnected. Calibration paused."*, and present reconnect vs `Switch to Front Camera` options on the phone screen.
3. **Reconnect (`UIScene.willConnectNotification`):** Re-mount `TVCoachingStageView` onto the external `UIWindowScene`, restore `PhoneControllerStatusView` on the phone, run a 0.4 s Tier-0 framing check (`CalibrationGate` resume), and speak *"TV reconnected. Raise both hands or clap to resume."*

---

## 5. Hands-Free Gesture UI

### 5.1 Two Existing Codebase Bugs Fixed by This Plan

1. **Inverted Y-Axis in `PracticeCamera.swift:223-226`:** `GestureRecognizer` (`GestureRecognizer.swift:7-8,147-148`) expects Vision-style **`y`-up** coordinates (`l.y > head + config.raisedMargin` for wrists above head), whereas `MediaPipePoseProvider.latestNormalizedLandmarks` (`MediaPipePoseProvider.swift:299`) outputs MediaPipe **`y`-down** coordinates (`0` = top, `1` = bottom). Today, `PracticeCamera.swift:223,225` passes `y: Double(p.y)` and `headY: Double($0.y)` unflipped, causing normal standing with arms hanging down (`wrist.y ≈ 0.55 > nose.y ≈ 0.25 + 0.05`) to fire `.restartDrill`, while actually raising hands overhead (`wrist.y ≈ 0.10 < 0.25`) never fires! **Fix:** Add `GestureSample.fromMediaPipeNormalized(...)` in `GrooveCore` that flips `y = 1.0 - mpY` once, tested in `GestureRecognizerTests`.
2. **Missing Gesture Wiring in `LessonPlayerView.swift`:** `PracticeView.swift:40-42` wires `camera.onGesture`, whereas `LessonPlayerView.swift` never assigns `camera.onGesture`. **Fix:** Introduce a pure `GestureRouter` in `GrooveCore` shared by both `PracticeViewModel` and `LessonPlayerViewModel`.

### 5.2 Gesture Command Mapping Across Coaching States

To enable hands-free **Skip Calibration** without colliding with any of the 9 calibration poses (`tpose` sweeps horizontally like `swipe`; `overhead` holds hands above head like `restartDrill`), note that **none of the 9 calibration poses bring the two hands together**. Extending `GestureRecognizer` with a **`GestureMode`** enum adds:
- In `.calibrating` mode: **Single Clap** repeats the current spoken instruction; **Double Clap** (two claps within `1.8 s`, bypassing the `1.0 s` post-clap cooldown for the second clap) triggers **Skip Calibration** (`CalibrationController.skip()`). Swipes and raised-hands holds are ignored during `.calibrating`.
- In `.recording` mode: Swipes and claps are **disabled**; only a **`2.0 s` Stationary Hands-Raised Hold** (`raisedHold = 2.0 s` while `bodyMotion <= 0.020`) triggers **Pause / Abort Take**.

| App Phase | `togglePause` (Single Clap) | `doubleClap` (2 Claps ≤ 1.8 s) | `restartDrill` (Both Hands Up Hold) | `swipeLeft` (Arm Sweep Left) | `swipeRight` (Arm Sweep Right) |
|---|---|---|---|---|---|
| **Idle / Lesson Review** | Play / Pause teacher video (`LessonPlayer`) or Start Take (`Practice`) | — | **Start Take / Confirm Ready** (`1.0 s` hold) | Restart segment preview from `startS` | Next segment (if unlocked) / Next move |
| **Calibrating** | **Repeat Spoken Cue** (`CalibrationVoice`) | **Skip Calibration** | *Disabled* (collides with `overhead`) | *Disabled* (collides with `tpose`) | *Disabled* (collides with `tpose`) |
| **Count-In** | *Disabled* (dancers clap on beat) | **Cancel / Pause Take** | **Cancel / Pause Take** (`1.2 s` hold) | *Disabled* | *Disabled* |
| **Recording (Dancing)** | *Disabled* (collides with Namaste / claps) | *Disabled* | **Emergency Pause Take** (`2.0 s` **stationary** hold only) | *Disabled* (collides with lateral sweeps) | *Disabled* (collides with lateral sweeps) |
| **Analyzing** | *Disabled* | *Disabled* | *Disabled* | *Disabled* | *Disabled* |
| **Results** *(after `1.0 s` post-take grace cooldown)* | **Confirm / Continue** (if `passed` & unlocked → Next; else → Try Again) | — | **Repeat Take** (`1.0 s` hold) | **Repeat Take** (same rate) | **Next Segment / Move** (if unlocked; else close results to review) |
| **Paused** | **Resume / Start Take** | — | **Restart Take** (`1.0 s` hold) | Exit to Lesson Review | Next Segment / Move |

### 5.3 False-Trigger Guards During Choreography

Evidence from `IMG_4941` (`2026-10-31-course-platform-design.md:92-104`) proves why naive gesture recognition fails mid-dance:
- **Segment B (`4.80–6.40 s`):** "Peek-a-Boo to Lateral Sweep" sweeps wrists across >35% of image width → would false-trigger `swipeLeft`/`swipeRight`.
- **Clasp Windows (`4.80–5.87 s`, `12.75–13.65 s`):** Namaste and wrist clasps bring `wristDistance < 0.06` → would false-trigger `clap`.
- **Segment D (`12.75–13.65 s`):** "Crown Lotus" holds both wrists above the head for `0.90 s` → nearly hits `1.0 s` `raisedHold`.

**Four Layered Guards:**
1. **Between-Takes Gate:** Swipes and claps execute **only** in `.idle`, `.results`, and `.paused`.
2. **Stationary 2.0 s Hold Guard in `.recording`:** Mid-take abort requires `2.0 s` continuous overhead hold (`> 2×` Crown Lotus's `0.90 s`) *simultaneously* with `bodyMotion <= 0.020` (dancer has stopped dancing and stood still). Because segments are short (`1.6–14.4 s`, `2026-10-31-course-platform-design.md:92-100`), accidental triggers drop to zero.
3. **Post-Take Grace Cooldown (`1.0 s`):** Entering `.results` calls `recognizer.reset()` and ignores commands for `1.0 s` so a final pose flourish never immediately dismisses the scorecard.
4. **Quiet Wind-Up Preserved (`GestureRecognizer.swift:69-72,225-234`):** Between takes, swipes keep the existing `0.3 s` quiet wind-up (`swipeQuietExtent = 0.08`), preventing casual walking from firing commands.

### 5.4 On-TV Visual & Audio Feedback for Gestures

- **Pre-Trigger Hold Ring:** Expose `holdProgress: Double` (`0...1`) from `GestureRecognizer` at 15 Hz. Whenever `holdProgress >= 0.15`, display a large translucent top-center HUD ring on `TVCoachingStageView` (*"Hold hands up to Start…"* / *"Hold still to Pause…"*).
- **Recognized Command Banner + Earcon:** On fire, display a high-contrast `40 pt` bold capsule banner (`GestureToast` scaled for TV) with SF Symbol icon for `1.5 s` **and** play a distinct 200 ms `AVAudioEngine` earcon (rising fifth for Start/Confirm, crisp double-tick for Next/Repeat, descending fourth for Pause/Skip) so confirmation is audible over AirPlay without looking at a corner badge.

---

## 6. `CalibrationProfile` v2 Data Model, Persistence & Re-Calibration Rules

### 6.1 Versioned Schema (`CalibrationProfileV2`, `groove.calibration/2`)

Today `CalibrationProfile` (`CalibrationGate.swift:234-244`) holds only `frames` and `gravity` in a static in-memory property (`CalibrationController.lastProfile`, `CalibrationOverlayView.swift:30`), losing calibration on every app relaunch.

`CalibrationProfileV2` (`Codable, Equatable, Sendable` in `GrooveCore`) is persisted atomically as JSON to `Application Support/Calibration/calibration_profile_v2.json` (excluded from iCloud backup, matching `LessonStore` in `2026-10-31-course-platform-design.md:156`), separating **session environment fields** (invalidated when the phone moves) from **dancer anatomical fields** (reusable across sessions):

```json
{
  "schema": "groove.calibration/2",
  "schemaVersion": 2,
  "calibratedAt": "2026-11-26T02:15:00Z",
  "deviceModel": "iPhone18,2",
  "cameraMode": "rearLiDAR",
  "environment": {
    "gravity": [0.012, -0.985, -0.172],
    "rollDeg": 0.7,
    "tiltBackDeg": 9.9,
    "intrinsics": {
      "fx": 925.4, "fy": 925.4, "cx": 360.0, "cy": 640.0,
      "width": 720, "height": 1280,
      "horizontalFoVDeg": 41.2, "verticalFoVDeg": 67.4
    },
    "floorPlane": {
      "normal": [-0.010, 0.986, 0.166],
      "cameraHeightM": 0.74,
      "lidarGravityDisagreementDeg": 0.4
    },
    "dancerDistanceM": 2.85,
    "usableLateralSpanM": 1.65,
    "overheadHeadroomMinY": 0.06,
    "lockedMeanLuma": 0.44,
    "exposureLockedISO": 160.0,
    "exposureLockedDurationS": 0.01667,
    "airplayAudioOffsetMs": 42.0,
    "audioRoutePortUID": "AirPlay-LivingRoomTV"
  },
  "body": {
    "dancerHeightM": 1.73,
    "metricScaleFactor": 1.064,
    "wingspanM": 1.71,
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
```

### 6.2 Three-Tier Re-Calibration Policy *(inference)*

| Tier | Trigger Condition | What Runs | Wall-Clock Time |
|---|---|---|---|
| **Tier 0: Instant In-Session Resume** | Same app session, same `cameraMode`, CoreMotion `gravityDeltaG < 0.05 g` (`resumeGravityDeltaG`), **AND** (if `rearLiDAR`) live LiDAR `|cameraHeightM - stored.cameraHeightM| < 0.03 m` and `floorNormalAngleDeltaDeg < 3.0°`. | Step 2 (`rest` framing + 2–4 m distance check, `0.4 s` hold) → lock AE/AWB → `.locked`. Reuses full `environment` + `body`. | **~0.5–1.0 s** |
| **Tier 1: Environment Re-Calibration (Phone Moved / New Session)** | Valid `CalibrationProfileV2` on disk (`age <= 30 days`), **AND** (`gravityDeltaG >= 0.05 g`, OR LiDAR `|cameraHeightM - stored| >= 0.03 m`, OR new app launch). | Step 1 (`level` + LiDAR floor plane) → Step 2 (`rest` framing + 2–4 m distance + AE/AWB lock + LiDAR `measuredHeightM`). **Same-dancer check:** if `|measuredHeightM - body.dancerHeightM| <= 0.06 m` (or in `frontSelfView` fallback), update `environment` and reuse `body` (`boneLengthsM`, `rom`, `jointConfidenceWeights`)! (+1-clap sync check only if `audioRoutePortUID` changed.) | **~4–6 s** |
| **Tier 2: Full 9-Pose Body + Studio Calibration** | (a) No `CalibrationProfileV2` (`schemaVersion == 2`) on disk; (b) `age > 30 days`; (c) `rearLiDAR` active now while stored profile was `frontSelfView` (`body.dancerHeightM == nil`); (d) LiDAR detects a different dancer (`|measuredHeightM - body.dancerHeightM| > 0.06 m`); or (e) user triggers **Recalibrate** in Calibrate tab / settings. | Full Step 1 (`level`) + Steps 2–10 (`rest` → `tpose` → `overhead` → `asymLR` → `armsForward` → `plie` → `turned45` → `stepLR` → `kneeLift`) + AirPlay 1-clap check if external audio route is uncalibrated. | **~25–32 s** |

**Mid-Calibration / Mid-Session Bump Watch:** As in `CalibrationGate.swift:477-483`, if `gravityDeltaG > bumpGravityDeltaG` (`0.05 g`) or `|cameraHeightM - lockedCameraHeightM| > 0.04 m` occurs during Steps 2–10 (someone kicked the tripod), `CalibrationGate` resets immediately to Step 1 (`level`) and unlocks AE/AWB so exposure re-meters after re-placement.

---

## 7. Mapping Onto `CalibrationGate` Steps and `CalibrationTuning` Keys

### 7.1 Pure State Machine Architecture (`Foundation`-Only)

`CalibrationGate` (`ios/GrooveCore/Sources/GrooveCore/CalibrationGate.swift`) remains a pure `Foundation`-only `Sendable` struct with zero Apple framework dependencies so every state transition, pose scorer, LiDAR check, and resume rule runs in `< 0.1 s` under `swift test --package-path ios/GrooveCore` on Linux CI (`.github/workflows/linux-ci.yml:31-33`).

1. **Fourth Pure Input Stream (`CalibrationDepthSample`):**
   Alongside `update(motion:)`, `update(pose:)`, and `update(light:)`, add `@discardableResult public mutating func update(depth: CalibrationDepthSample) -> CalibrationStatus`. `CalibrationSensors` (in `GrooveApp`) performs `AVDepthData` pixel reads and RANSAC plane fitting off-main, passing `CalibrationGate` pure scalars: `timestamp`, `dancerDistanceM`, `measuredHeightM`, `cameraHeightM`, `floorNormal` (`CalibrationVector3`), `lidarBoneLengthsM` (`[String: Double]`), `shoulderToWristDeltaZM`, and `intrinsics`.
2. **Expanded `CalibrationStep` Sequence & Shared `PoseHoldTracker`:**
   - Steps: `resume (0)` → `level (1)` → `rest (2)` → *(if Tier 0/1 resume & height matches: `locked (99)`; else Tier 2 full flow:)* `tpose (4)` → `overhead (5)` → `asymLR (6)` → `armsForward (7)` → `plie (8)` → `turned45 (9)` → `stepLeft (10)` → `stepRight (11)` → `kneeLift (12)` → `locked (99)`. (Index `3` remains reserved conceptually for parallel non-blocking lighting advice.)
   - Extract a single internal `PoseHoldTracker` value struct inside `CalibrationGate` managing `(poseStart, poseLastGood, poseLatched, holdSamples, dropoutToleranceS)` so Steps `4...12` share one tested hold/dropout/framing-loss loop instead of duplicating `processTPose` (`CalibrationGate.swift:596-650`) nine times.
   - Add `gate.needsExposureLock: Bool` flag on `CalibrationStatus` that flips `true` as `rest` completes, signaling `CalibrationController` to lock `AVCaptureDevice` exposure and white balance.
3. **Flat `CalibrationTelemetry` Invariant Preserved (`CalibrationGateTests.swift:568-570`):**
   Every added field on `CalibrationTelemetry` is a flat optional scalar (`String`, `Int`, `Double?`, `Bool?`)—no nested arrays or dictionaries—so Debug Link JSONL logging (`tools/debuglink/server.py:163-175`) and `testTelemetryIsFlatJSON` remain 100% compatible.

### 7.2 New `CalibrationTuning` Keys & Defaults

All new keys in `CalibrationTuning.swift` decode via `c.decodeIfPresent(...) ?? fallback` (`CalibrationTuning.swift:269-271`) so partial `tools/debuglink/tuning.json` overrides work live at 2 s polling intervals without rebuilding:

| Key | Type | Default | Provenance | Purpose |
|---|---|---|---|---|
| `lidarMinDistanceM` | `Double` | `2.0` | Owner spec (`2–4 m`) | Minimum LiDAR torso distance (`rest` & framing). |
| `lidarMaxDistanceM` | `Double` | `4.0` | Owner spec + `report.md:48` | Maximum LiDAR torso distance (inside 5 m LiDAR range). |
| `lidarDistanceStayDeltaM` | `Double` | `0.25` | *(inference)* | Hysteresis widening on distance once passing. |
| `resumeFloorHeightDeltaM` | `Double` | `0.03` | *(inference)* + `report.md:47` | Max LiDAR camera-height change (m) allowed for Tier-0 resume. |
| `resumeFloorAngleDeg` | `Double` | `3.0` | *(inference)* | Max LiDAR floor-normal change (deg) allowed for Tier-0 resume. |
| `sameDancerHeightDeltaM` | `Double` | `0.06` | *(inference)* | Max LiDAR dancer-height delta (m) to reuse `body` in Tier-1. |
| `cameraHeightMinM` | `Double` | `0.35` | Dina 0.5–0.7 m (`11-18:105`) | Low-camera advisory threshold (m). |
| `cameraHeightMaxM` | `Double` | `1.50` | *(inference)* | High-camera advisory threshold (m). |
| `exposureMaxShutterS` | `Double` | `0.0167` | *(inference: 1/60 s)* | Max locked shutter duration before custom ISO boost. |
| `remeterLumaDelta` | `Double` | `0.20` | *(inference)* | Between-take luma drift triggering AE/AWB re-meter. |
| `restHoldS` | `Double` | `0.6` | *(inference)* | Hold duration for Step 2 (`rest`). |
| `overheadHoldS` | `Double` | `0.7` | *(inference)* | Hold duration for `overhead`. |
| `overheadMinWristAboveNose` | `Double` | `0.05` | `GestureConfig.raisedMargin` | Min `(nose.y - wrist.y) / span` for `overhead`. |
| `overheadMinTopMarginY` | `Double` | `0.02` | Ashrium `0.01` (`11-18:157`) | Top-edge clipping guard for raised wrists (`y >= 0.02`). |
| `overheadMinElbowDeg` | `Double` | `135.0` | *(inference)* | Min interior elbow extension angle in `overhead`. |
| `asymHoldS` | `Double` | `0.7` | *(inference)* | Hold duration for `asymLR`. |
| `asymMinSideReachShoulders` | `Double` | `0.80` | `checkup.ts:85-90` *(inference)* | Min horizontal right-wrist reach in shoulder widths. |
| `forwardHoldS` | `Double` | `0.7` | *(inference)* | Hold duration for `armsForward`. |
| `forwardMinDeltaZM` | `Double` | `0.25` | `checkup.ts:39,92` (`0.52 m` arm) | Min canonical & LiDAR shoulder-to-wrist forward Z delta (m). |
| `plieHoldS` | `Double` | `0.8` | *(inference)* | Hold duration for `plie`. |
| `plieMinKneeFlexDeg` | `Double` | `22.0` | `checkup.ts:109-111` *(inference)* | Min exterior `mean_knee_flex` (deg) in `plie`. |
| `plieMinHipDropNorm` | `Double` | `0.04` | *(inference)* | Min `hip_height_norm` drop from `rest` in `plie`. |
| `turnedHoldS` | `Double` | `0.7` | *(inference)* | Hold duration for `turned45`. |
| `turnedMinYawDeg` | `Double` | `25.0` | `checkup.ts:118` (`45°` ± `20°`) | Min 3D shoulder XZ yaw angle (deg). |
| `turnedMaxYawDeg` | `Double` | `65.0` | `checkup.ts:118` (`45°` ± `20°`) | Max 3D shoulder XZ yaw angle (deg). |
| `turnedMinShoulderWidth2D` | `Double` | `0.045` | `checkup.ts:149` (exact) | Edge-on collapse floor `|ls.x - rs.x|`. |
| `stepHoldS` | `Double` | `0.5` | *(inference)* | Hold duration per side (`stepLeft`, `stepRight`). |
| `stepMinHipShiftX` | `Double` | `0.12` | *(inference)* | Min normalized horizontal hip shift from `rest` center. |
| `stepDropoutS` | `Double` | `0.40` | *(inference)* | Dropout tolerance during lateral step weight transfer. |
| `kneeLiftHoldS` | `Double` | `0.5` | *(inference)* | Hold duration for `kneeLift`. |
| `kneeLiftMinFlexDeg` | `Double` | `55.0` | *(inference)* | Min lifted-leg exterior `knee_flex` (deg). |
| `kneeLiftMinAnkleClearance` | `Double` | `0.18` | *(inference)* | Min `|la3D.y - ra3D.y| / legScale` in `kneeLift`. |
| `kneeLiftMotionStayMax` | `Double` | `0.035` | *(inference)* | Relaxed stillness stay limit for single-leg balance. |
| `kneeLiftDropoutS` | `Double` | `0.45` | *(inference)* | Dropout tolerance for `kneeLift`. |

---

## 8. How Scoring and Retargeting Consume `CalibrationProfileV2`

**Strict Swift ↔ Python Parity Rule:** `scripts/check_parity.py` (`scripts/check_parity.py:1-11,195-238`) enforces 1:1 numeric parity (`±0.02`) between `ios/GrooveCore` and `groove_eval/` across `golden_clips.json`, `feature_clips.json`, and `lesson_clips.json`. Therefore:
1. Add an optional `calibration_v2: LearnerCalibrationV2? = nil` field on `GrooveScoringEngine.PoseClip` (`ScoringEngine.swift:239-282`) and `"calibration_v2"` dictionary key in `groove_eval/scoring.py` & `groove_eval/retarget.py`.
2. When `calibration_v2` is `nil` (all existing golden/feature/lesson clips and skipped calibrations), scoring and retargeting execute **100% identically** to `aa5953e` so `fixtures/expected_scores_snapshot.json` has zero drift on existing clips.
3. When `calibration_v2` is present on a take, both `GrooveCore` and `groove_eval` apply four deterministic adjustments:

### 8.1 Metric Scale & Calibrated Bone Lengths → `Retarget` & `MoveSegmenter`
- **Bone-Length Priority (`Retarget.swift:83-92`, `groove_eval/retarget.py:72-82`):** `Retarget.learnerBoneLengths(attempt:)` reads `attempt.calibration_v2.boneLengthsM` first (which already incorporates `metricScaleFactor` from LiDAR over the `>= 15` T-pose frames, swapped via `mirrorName` when `attempt.mirrored == true`), falling back to `calibration_frames` and then `attempt.frames`.
- **Automatic Retargeting Activation:** Today `config/groove_config.json:84` defaults `retarget.enabled` to `false`. When `attempt.calibration_v2 != nil` (and the lesson/segment does not explicitly set `retarget.enabled = false`), `scoreAttempt` enables `Retarget.retargetClip` so the teacher reference is re-walked onto the learner's LiDAR-metric proportions (`Retarget.swift:95-159`).
- **Metric Frame Scaling for Hit Velocities (`MoveSegmenter`):** Multiply learner canonical 3D joint positions `(x, y, z)` by `calibration_v2.metricScaleFactor` before `MoveSegmenter.detectHits` (`ScoringFeatures.swift:580-582`) and `measureClipLegScale` (`ScoringEngine.swift:1032`), putting 3D joint speeds (`m/s` vs `moving_threshold = 1.0`, `settle_threshold = 0.4`) in true physical metres per second. (Ratio features like `hip_height_norm`, `ScoringEngine.swift:560-563`, cancel scale in numerator and denominator and remain invariant.)

### 8.2 Range-of-Motion (ROM) Limits → Groove & Posture Fairness
- **Plié Knee-Bounce Ceiling (`ScoringEngine.swift:910-917`):** Today `kneeFlexRatio = userKneeRange / refKneeRange`. A learner whose comfortable calibrated plié excursion `availableKneeFlexDeg = max(15.0, rom.plieKneeFlexDeg - rom.standingKneeFlexDeg)` is smaller than a hyper-mobile instructor's `refKneeRange` is unfairly penalized even when dancing full-out. Replace the denominator with `effectiveRefKneeRange = min(refKneeRange, availableKneeFlexDeg)`. Crucially, a stiff-kneed take (`userKneeRange ≈ 4°` against `availableKneeFlexDeg = 28°` → `ratio = 0.14 < 0.65`) still fails the stiffness gate (`stiff_groove`), preserving negative rejection!
- **Resting Trunk Lean Baseline (`ScoringEngine.swift:536-537,836`):** Subtract `clamp(rom.trunkLeanBaselineDeg - refRestTrunkLeanDeg, -5.0, 5.0)` when computing `hips` (`trunk_lean_deg`) shape error so natural standing posture or slight camera-floor slope discrepancy does not add a constant degree bias on every beat.
- **Overhead Tolerance Floor:** On beats where the reference's torso-frame upper-arm elevation exceeds `rom.maxShoulderElevationDeg`, widen `leftElbow`/`rightElbow`/`leftWrist`/`rightWrist` position and angle tolerances in `scoreJointFeedback` by `1.25×`.

### 8.3 Per-Joint Confidence Weights → Noise-Aware Tolerances & Shape Weights
Each canonical joint $j$ gets a calibrated reliability weight $w_j \in [0.50, 1.00]$ equal to `clamp(p25Visibility(j), 0.50, 1.00)` aggregated over the calibration poses in which joint $j$ is unoccluded.
1. **Joint Verdict Tolerance Widening (`ScoringFeatures.swift:716-724`):** Multiply beat tolerance `scale(name, velPos)` in `scoreJointFeedback` by `1.0 / w_j` (up to `2.0×` when $w_j = 0.50$). Chronically low-SNR joints in a dim corner or dark carpet (e.g. `leftHeel` at $w = 0.60$) stop dominating `top_hint` with noisy `"off"` verdicts, while clean joints ($w \ge 0.90$) retain full strictness.
2. **Shape Sub-Weight Re-Normalization (`ScoringEngine.swift:833-895`):** Multiply each `jointKeys` weight (`knees`, `spine`, `hips`, `left_foot`, `right_foot`, plus `armWeight` when `armsOn`) by the mean $w_j$ of its constituent joints and divide by the sum of active weights so total shape weight stays `1.0`.

### 8.4 AirPlay Audio/Video Route Offset → Timing Alignment
`PracticeViewModel` (`PracticeView.swift:186`) and `LessonPlayerViewModel` (`LessonPlayerView.swift:913`) pass `audio_latency_ms = metronome.outputLatencyMs + (matchingRouteOffsetMs ?? 0.0)` when `profile.environment.audioRoutePortUID == currentAudioPortUID`.

---

## 9. Verification Plan

### 9.1 Automated Unit & Parity Tests (`linux-ci`)

1. **`GrooveCore` Swift Tests (`swift test --package-path ios/GrooveCore`):**
   - `CalibrationProfileV2Tests.swift`: JSON round-trip of `CalibrationProfileV2`, Tier-0 / Tier-1 / Tier-2 classification across synthetic `gravityDeltaG`, `cameraHeightM` delta, `dancerHeightM` mismatch (`> 0.06 m`), camera mode upgrades (`frontSelfView` → `rearLiDAR`), and 30-day expiry.
   - `CalibrationGateV2Tests.swift`: Synthetic 30 Hz + 10 Hz trajectories through all 9 poses; negative & diagnostic cue tests for each pose (`overhead` top clipping → `.stepBackHeadroom`, `asymLR` mirrored arms → `.swapArmsLR`, `armsForward` flat 2D without Z → fail, `plie` shallow knee bend → fail, `turned45` edge-on `< 0.045` → `.turnLessSideways`, `stepLeft`/`stepRight` two-stage latching, `kneeLift` relaxed sway `0.030` passing); `CalibrationDepthSample` `2.0–4.0 m` gates and `metricScaleFactor` median calculation; partial `CalibrationTuning` JSON merge; flat JSON check on `CalibrationTelemetry` (no nested objects/arrays).
   - `GestureRecognizerTests.swift`: `GestureSample.fromMediaPipeNormalized` `y`-flip test (arms down at `mpY = 0.55` never triggers `restartDrill`; hands overhead at `mpY = 0.10` triggers `restartDrill` after `1.0 s`); `.calibrating` mode `doubleClap` skip + zero false triggers across full 9-pose synthetic calibration trajectory; `.recording` mode `2.0 s` stationary hold vs `IMG_4941` lateral sweep, Namaste clasp, and `0.90 s` Crown Lotus negative tests; `GestureRouter` phase-to-action matrix tests.
   - `ScoringCalibrationV2Tests.swift`: `metricScaleFactor`, `rom` plié cap (verifying limited-ROM clean take passes while stiff-knee take still fails), and `jointConfidenceWeights` tolerance scaling.
2. **Python ↔ Swift Exact Parity (`python3 -m unittest discover -s tests -v && python3 scripts/check_parity.py`):**
   - Add `tests/test_calibration_v2_parity.py` and two `calibration_v2`-annotated clips in `fixtures/lesson_clips.json` (+ `fixtures/expected_scores_snapshot.json`), verifying `0` drift on all existing clips and `< 0.02` diff between Python and `groove-score-cli` on the new v2 clips.

### 9.2 Debug Link External-Display Capture (`ScreenStreamer.swift` + `server.py`)

Today `ScreenStreamer.tick()` (`ScreenStreamer.swift:51-53`) selects only `.first(where: { $0.activationState == .foregroundActive })`, missing any connected external AirPlay/TV `UIWindowScene`, and `tools/debuglink/server.py:245` writes only a single `screen/latest.jpg`.

**Required Upgrades:**
1. **`ScreenStreamer.swift`:** Iterate over all connected `UIWindowScene`s with `.activationState == .foregroundActive` (plus external display scenes where `scene.screen != UIScreen.main`, which may report `.foregroundInactive` when non-interactive). Within a single `inFlight`-guarded detached `Task` (so the phone upload never starves the external upload), encode and `POST /screen` first for the phone scene (`X-Screen-Role: phone` at native scale) and then, when present, for the external TV `UIWindowScene` (`X-Screen-Role: external`, downscaled by `0.5×` e.g. `960×540` JPEG `q = 0.65` so LAN upload stays `< 90 KB/s` and never contends with AirPlay Wi-Fi bandwidth). Run `collectPreviews` (`ScreenStreamer.swift:120-135`) on the external window's layer tree so `CameraFrameStore` composites the live rear camera image into the TV's `AVCaptureVideoPreviewLayer` rect!
2. **`tools/debuglink/server.py`:** Read `X-Screen-Role` (`"phone"` default vs `"external"`). Store external frames at `screen/latest-external.jpg` and `screen/external-YYYYMMDD-*.jpg` (capped at `KEEP_SCREENS`), add `latest_external_screen` + `external_fps` to `/status.json`, serve `GET /screen/latest-external.jpg`, and render `#scr-tv` alongside `#scr` in `LIVE_PAGE` (`http://localhost:8765/`).

### 9.3 On-Device Verification via Debug Link (`%LOCALAPPDATA%\groove-coach\debuglink\`)

| Check | Debug Link Artifact / Stream | Quantitative Pass Criterion |
|---|---|---|
| **Rear camera & gravity signs** | `frames/latest.jpg`, `telemetry-YYYYMMDD.jsonl` | Portrait upright dancer; dancer's raised left hand appears at raw `x > 0.5`; leaning phone top away from dancer gives `tiltBackDeg > 0` and `lidarFloorTiltDeg < 3.0°`. |
| **LiDAR metric calibration** | `telemetry-YYYYMMDD.jsonl` (`dancerDistanceM`, `cameraHeightM`, `measuredHeightM`, `metricScaleFactor`) | At 2.5 m & 3.5 m tape-measured marks: `|dancerDistanceM - tape| <= 0.05 m`, `|measuredHeightM - realHeight| <= 0.04 m`, `metricScaleFactor ∈ [0.85, 1.20]` with `< 0.03` spread across 3 runs. |
| **AE/AWB lock** | `telemetry-YYYYMMDD.jsonl` (`exposureLocked`, `exposureSeconds`, `iso`) | `exposureLocked == true` from Step 3 (`tpose`) onward; `exposureSeconds <= 0.017` in normal indoor lighting; zero exposure pumping across Steps 3–9. |
| **9-pose sequence & profile save** | `events-YYYYMMDD.jsonl` (`kind == "calibration_end"`) | `step == "locked"`, `skipped == false`, `capturedFrameCount >= 15`, `lrSwapped == false`, all 9 pose flags `true`; killing & relaunching app triggers Tier-1 (`resumedBody == true`) in `< 6 s`. |
| **Dual-screen AirPlay UI** | `screen/latest.jpg` + `screen/latest-external.jpg` | `latest-external.jpg` shows 16:9 `TVCoachingStageView` with composited live camera + skeleton; `latest.jpg` shows dark `PhoneControllerStatusView`; `AVPlayer` renders inside left half of TV stage. |
| **Gesture routing & false-trigger immunity** | `events-YYYYMMDD.jsonl` (`kind == "gesture_fired"`, `kind == "take_end"`) | Hands-up starts take, double-clap skips calibration, swipes navigate results; full `IMG_4941` take fires `0` gestures during `phase == "recording"`; on-beat take achieves `|meanOffsetMs| <= 35 ms`. |
| **Thermal & FPS stability** | `logs-YYYYMMDD.jsonl` (`liveFps`, `thermalState`) | Live MediaPipe `>= 20 fps` during 5 consecutive takes with AirPlay active; `thermalState` stays `.nominal` or `.fair` (never `.serious` / `.critical`). |

---

## 10. Phased Build Orders (< 1 Hour Each, Globally Non-Overlapping `owns:`)

Note that `ios/GrooveApp/project.yml:13-14` uses directory discovery (`sources: - Sources`) and `ios/GrooveCore/Package.swift` auto-discovers target sources, so orders creating new `.swift` files do **not** contend on `project.yml` or `Package.swift`. Every single file across all 10 orders below has **globally disjoint ownership** (`0` overlapping paths anywhere in the plan).

```
PHASE 1 (Core, Rear Camera + LiDAR Plumbing, Dual-Screen Debug Link)
  Wave 1A (parallel):  [1. calib2-core-profile-tuning]   [2. calib2-gestures-core]   [3. calib2-debuglink-extscreen]
                                      │                              │
  Wave 1B (parallel):  [4. calib2-gate-9pose]            [5. calib2-rear-camera-lidar]
                                      └──────────────┬───────────────┘
                                                     ▼
                              🛑 DEVICE MEASUREMENT GATE 1 (on iPhone18,2)
                                                     │
PHASE 2 (Scoring Parity, Persistent Controller/Voice, AirPlay TV Scene, App Wiring)
  Wave 2A (parallel):  [6. calib2-scoring-retarget]  [7. calib2-controller-voice-overlay]  [8. calib2-external-display-scene]
                                                     │
  Wave 2B (parallel):               [9. calib2-wire-practice]        [10. calib2-wire-lesson-player]
                                                     └──────────────┬───────────────┘
                                                                    ▼
                              🛑 DEVICE MEASUREMENT GATE 2 (End-to-End AirPlay TV + Dance Run)
```

### Phase 1 Orders

1. **`calib2-core-profile-tuning`** *(Wave 1A · ~45 min · GrooveCore)*
   - **Work:** Define `CalibrationProfileV2` (`CameraMode`, `environment`, `body`, `rom`, `jointConfidenceWeights`, Tier-0/1/2 classifier, and `.legacyProfile` bridge so existing `CalibrationGate` callers compile unchanged during Wave 1A), `CalibrationDepthSample`, `CalibrationIntrinsics`, and add all §7.2 keys/defaults + partial JSON decoding to `CalibrationTuning`.
   - **`owns:`** `ios/GrooveCore/Sources/GrooveCore/CalibrationProfileV2.swift` *(new)*, `ios/GrooveCore/Sources/GrooveCore/CalibrationTuning.swift`, `ios/GrooveCore/Tests/GrooveCoreTests/CalibrationProfileV2Tests.swift` *(new)*
   - **`test:`** `swift test --package-path ios/GrooveCore --filter CalibrationProfileV2Tests`
   - **`check:`** `testProfileV2RoundTrip` `testThreeTierResumeClassifier` `testNewTuningKeysPartialDecode`

2. **`calib2-gestures-core`** *(Wave 1A · ~40 min · GrooveCore)*
   - **Work:** Add `GestureSample.fromMediaPipeNormalized` (`1.0 - y` fix), `holdProgress` (`0...1`), `GestureMode` (`.betweenTakes`, `.calibrating` with single-clap repeat + `doubleClap` skip, `.recording` with `2.0 s` stationary hold), and pure `GestureRouter` (`(ScreenPhase, GestureCommand) -> CoachingAction`) with full unit tests.
   - **`owns:`** `ios/GrooveCore/Sources/GrooveCore/GestureRecognizer.swift`, `ios/GrooveCore/Sources/GrooveCore/GestureRouter.swift` *(new)*, `ios/GrooveCore/Tests/GrooveCoreTests/GestureRecognizerTests.swift`
   - **`test:`** `swift test --package-path ios/GrooveCore --filter GestureRecognizerTests`
   - **`check:`** `testMediaPipeYFlipFixesRaisedHands` `testCalibrationDoubleClapSkipsAndPosesNeverTrigger` `testRecordingStationaryHoldIgnoresChoreography`

3. **`calib2-debuglink-extscreen`** *(Wave 1A · ~45 min · GrooveApp + Python Debug Link)*
   - **Work:** Extend `ScreenStreamer` to capture connected external `UIWindowScene` windows sequentially under one `inFlight` cycle (`0.5×` scale, compositing `CameraFrameStore` into external `AVCaptureVideoPreviewLayer`s, `X-Screen-Role: external`) and update `tools/debuglink/server.py` + `README.md` to store `screen/latest-external.jpg`, update `/status.json` & `LIVE_PAGE`, and add Python server unit tests.
   - **`owns:`** `ios/GrooveApp/Sources/ScreenStreamer.swift`, `tools/debuglink/server.py`, `tools/debuglink/README.md`, `tests/test_debuglink_server.py`
   - **`test:`** `python -m unittest tests.test_debuglink_server -v`
   - **`check:`** `test_external_screen_role_stored_separately` `test_phone_screen_default_role_preserved`

4. **`calib2-gate-9pose`** *(Wave 1B · depends on #1 · ~55 min · GrooveCore)*
   - **Work:** Implement the 9-pose state machine (`rest`, `tpose`, `overhead`, `asymLR`, `armsForward`, `plie`, `turned45`, `stepLeft`, `stepRight`, `kneeLift`), rear-vs-front `CameraMode` optical pitch sign (`atan2(isRear ? +g.z : -g.z, -g.y)`), `PoseHoldTracker`, `CalibrationDepthSample` integration (`2–4 m` distance, floor-height resume, `metricScaleFactor`), Tier-0/1/2 transitions producing `lockedProfileV2`, `needsExposureLock`, and flat `CalibrationTelemetry` fields.
   - **`owns:`** `ios/GrooveCore/Sources/GrooveCore/CalibrationGate.swift`, `ios/GrooveCore/Tests/GrooveCoreTests/CalibrationGateTests.swift`, `ios/GrooveCore/Tests/GrooveCoreTests/CalibrationGateV2Tests.swift` *(new)*
   - **`test:`** `swift test --package-path ios/GrooveCore --filter CalibrationGate`
   - **`check:`** `testFullNinePoseSequenceLocksProfileV2` `testAsymLRDetectsSwappedSides` `testRearCameraTiltSignFlip` `testTelemetryIsFlatJSON`

5. **`calib2-rear-camera-lidar`** *(Wave 1B · depends on #1, #2 · ~55 min · GrooveApp)*
   - **Work:** Add `CameraMode` (`.rearLiDAR`, `.rearWide`, `.frontSelfView`) to `PracticeCamera` (30 fps cap, depth output active only during calibration / 1 Hz idle, `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`, `videoFieldOfView`), wire `GestureSample.fromMediaPipeNormalized` + `GestureMode`, and add camera-frame gravity conversion (`rear` vs `front`), RANSAC LiDAR floor plane, metric torso/height/bone back-projection, and AE/AWB lock/unlock + re-meter helpers to `CalibrationSensors`.
   - **`owns:`** `ios/GrooveApp/Sources/PracticeCamera.swift`, `ios/GrooveApp/Sources/CalibrationSensors.swift`
   - **Gate:** macOS IPA build (`ios-sideload-ipa.yml` / `xcodebuild`, verifying `VNDetectHuman(Body|Hand)Pose` remains absent!)

### 🛑 Mandatory Device Measurement Gate 1 (Before Phase 2)
Deploy Phase 1 build to `iPhone18,2` (iOS 26.6.1) with Debug Link running and measure:
1. Rear-camera portrait buffer orientation & `leftShoulder.x > 0.5` parity in `frames/latest.jpg`, plus `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` axis order under `videoRotationAngle = 90`.
2. CoreMotion rear-camera optical pitch (`atan2(+g.z, -g.y) > 0` when rear lens tilts up) vs LiDAR floor plane (`lidarFloorTiltDeg < 3.0°`).
3. LiDAR `dancerDistanceM`, `cameraHeightM`, `measuredHeightM`, and `metricScaleFactor` accuracy at 2.0 m, 3.0 m, and 4.0 m, plus live MediaPipe FPS & thermal state over 3 minutes.
4. Any threshold adjustments written into `tools/debuglink/tuning.json` and folded into `CalibrationTuning.defaults` if needed.

### Phase 2 Orders

6. **`calib2-scoring-retarget`** *(Wave 2A · depends on #1 · ~55 min · GrooveCore + Python `groove_eval`)*
   - **Work:** Add optional `calibration_v2: LearnerCalibrationV2?` to `PoseClip` in Swift and Python; wire `boneLengthsM` priority + automatic retargeting, `metricScaleFactor` velocity scaling, `rom` plié cap + posture baseline, and `jointConfidenceWeights` tolerance/shape scaling with 1:1 parity tests and updated snapshot for new lesson clips.
   - **`owns:`** `ios/GrooveCore/Sources/GrooveCore/ScoringEngine.swift`, `ios/GrooveCore/Sources/GrooveCore/ScoringFeatures.swift`, `ios/GrooveCore/Sources/GrooveCore/Retarget.swift`, `ios/GrooveCore/Tests/GrooveCoreTests/ScoringCalibrationV2Tests.swift` *(new)*, `groove_eval/scoring.py`, `groove_eval/retarget.py`, `fixtures/lesson_clips.json`, `fixtures/expected_scores_snapshot.json`, `tests/test_calibration_v2_parity.py` *(new)*
   - **`test:`** `python scripts/check_parity.py`
   - **`check:`** `Python vs. canonical snapshot parity` `lesson_clips.json`

7. **`calib2-controller-voice-overlay`** *(Wave 2A · depends on #4, #5 · ~50 min · GrooveApp)*
   - **Work:** Build `CalibrationProfileStore` (`Application Support/Calibration/calibration_profile_v2.json`), update `CalibrationController` to drive Tier-0/1/2 flows, feed `CalibrationDepthSample`, lock/unlock AE/AWB on `needsExposureLock`, add 9-pose target silhouettes & progress dots to `CalibrationOverlayView`, and add all new spoken cues + per-step completion chimes + gesture earcons to `CalibrationVoice`.
   - **`owns:`** `ios/GrooveApp/Sources/CalibrationOverlayView.swift`, `ios/GrooveApp/Sources/CalibrationVoice.swift`, `ios/GrooveApp/Sources/CalibrationProfileStore.swift` *(new)*
   - **Gate:** macOS `xcodebuild` compile check

8. **`calib2-external-display-scene`** *(Wave 2A · depends on #3, #7 · ~55 min · GrooveApp)*
   - **Work:** Add `ExternalDisplayManager` (scene connect/disconnect, AirPlay route UID tracking, disconnect voice alert), register external display scene support in `project.yml` + `PoseExporterApp.swift`, and build 16:9 `TVCoachingStageView` + minimal dark OLED `PhoneControllerStatusView` + Calibrate-tab "Recalibrate Studio (v2)" trigger.
   - **`owns:`** `ios/GrooveApp/project.yml`, `ios/GrooveApp/Sources/PoseExporterApp.swift`, `ios/GrooveApp/Sources/ExternalDisplayManager.swift` *(new)*, `ios/GrooveApp/Sources/TVCoachingStageView.swift` *(new)*
   - **Gate:** macOS `xcodegen generate && xcodebuild`

9. **`calib2-wire-practice`** *(Wave 2B · depends on #6, #7, #8 · ~45 min · GrooveApp)*
   - **Work:** Wire `PracticeViewModel` & `PracticeView` to `ExternalDisplayManager`, automatic `CameraMode` switching (`rearLiDAR` with TV, `frontSelfView` fallback without TV + manual toggle), `GestureRouter` + `1.0 s` post-take cooldown, AirPlay drop auto-pause, TV-scaled `GestureToast` / hold ring in `FeedbackViews.swift`, and `CalibrationProfileV2` → `PoseClip.calibration_v2`.
   - **`owns:`** `ios/GrooveApp/Sources/PracticeView.swift`, `ios/GrooveApp/Sources/FeedbackViews.swift`
   - **Gate:** macOS `xcodebuild`

10. **`calib2-wire-lesson-player`** *(Wave 2B · depends on #6, #7, #8 · ~50 min · GrooveApp)*
    - **Work:** Wire `LessonPlayerViewModel` & `LessonPlayerView` to `ExternalDisplayManager`, set `player.allowsExternalPlayback = false` when TV stage is active, wire `camera.onGesture` via `GestureRouter` (fixing missing gesture support in lessons), abort to pause without recording a failed take on AirPlay drop, add optional 1-clap AirPlay latency check (`verifyClapSync` + `Metronome`), and pass `CalibrationProfileV2` + `effectiveAudioLatencyMs` into `takePoseClip`.
    - **`owns:`** `ios/GrooveApp/Sources/LessonPlayerView.swift`, `ios/GrooveApp/Sources/Metronome.swift`
    - **Gate:** macOS `ios-sideload-ipa.yml` full IPA verification

### 🛑 Mandatory Device Measurement Gate 2 (Final Sign-Off)
Run end-to-end on `iPhone18,2` AirPlaying to the owner's TV with Debug Link active: verify `screen/latest-external.jpg`, complete the full 9-pose hands-free calibration from 3 m, run the 1-clap AirPlay sync check, dance a full `IMG_4941` segment + `full_run` verifying `0` false gesture triggers and `|meanOffsetMs| <= 35 ms`, and pull AirPlay mid-take to verify graceful pause without ladder demotion.

---

## 11. Risks and Open Questions

### 11.1 Unopened Apple SDK Details (Verify Against Local Xcode 16+ / iOS 26 SDK Headers, Do Not Guess)

Because web browsing was restricted to the existing research reports plus `Chuyuyan/dance-trainer`, the implementing workers in Orders #5 and #8 must verify these exact SDK signatures against Xcode's local Swift interfaces before compiling:
1. **`AVCaptureDepthDataOutput` & LiDAR Device Selection (Order #5):** `report.md` opened `AVCameraCalibrationData`, `ARFrame.sceneDepth`, and `VNDetectHumanBodyPose3DRequest`, not the `AVCaptureDepthDataOutput` / `AVCaptureDevice.DeviceType.builtInLiDARDepthCamera` reference pages. Verify: (a) exact `AVCaptureDevice.DeviceType` priority list (`.builtInLiDARDepthCamera` → `.builtInDualWideCamera` / `.builtInWideAngleCamera` fallback), (b) `AVDepthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)` signature, and (c) supported `activeDepthDataFormat` paired with `1280×720` @ 30 fps on `iPhone18,2`.
2. **External Display `UIWindowScene` Configuration in SwiftUI `App` (Order #8):** Neither research report opened Apple's external display `UIWindowScene` / `Info.plist` `UIApplicationSceneManifest` documentation. Verify: (a) exact `UISceneConfiguration` role name (`UIWindowSceneSessionRoleExternalDisplayNonInteractive` vs `UIWindowSceneSessionRoleExternalDisplay`) in `project.yml` `Info.plist` properties, (b) attaching a `UIHostingController(rootView: TVCoachingStageView())` in a `UISceneDelegate` vs SwiftUI scene API, and (c) confirming `player.allowsExternalPlayback = false` prevents `AVPlayer` from overriding the external `UIWindowScene`.
3. **Exposure Readiness Properties Before Locking (Order #5):** `report.md:105-115` verified `ExposureMode.locked`, `setExposureModeCustom`, `WhiteBalanceMode.locked`, and `setWhiteBalanceModeLocked`, not `isAdjustingExposure` / `isAdjustingWhiteBalance`. Check those properties in `AVFoundation` headers so AE/AWB is not locked mid-slew.
4. **Intrinsics Rotation Under `videoRotationAngle = 90` (Order #5 + Device Gate 1):** Verify on `iPhone18,2` whether `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` and `AVDepthData.cameraCalibrationData.intrinsicMatrix` are delivered in landscape sensor coordinates (`1280×720`, requiring $(f_x, c_x) \leftrightarrow (f_y, c_y)$ swap for portrait buffers) or already rotated to `720×1280`.

### 11.2 Product Decisions for the Owner

1. **Re-calibration cadence (§6.2):** Does the 3-tier cadence (**~28 s** Full 9-Pose once per dancer / 30 days, **~4 s** Level + LiDAR Distance/Height check when the phone is moved, **<1 s** framing check between takes) match your vision, or do you want an option in Practice/Lesson UI to force the full 9-pose warm-up before every session?
2. **1-Clap AirPlay Sync Check (§4.2):** Should the 4-beat `"1, 2, 3, CLAP"` TV latency check run automatically once whenever a new AirPlay TV is connected, or remain an optional button / gesture in TV settings unless timing offsets look biased?
3. **Mid-Take Escape Hatch (§5.2):** Segments are short (`1.6–14.4 s`). Do you prefer the **`2.0 s` stationary hands-up hold** to pause mid-take, or **zero gestures active during `.recording`** (waiting up to ~14 s for the take to finish naturally) for absolute zero false-positive risk?
4. **USB-C → HDMI Cable Option:** `iPhone18,2` supports DisplayPort over USB-C (`< 20 ms` latency vs `60–250 ms` wireless AirPlay) using the exact same external `UIWindowScene` code. Will you test primarily over wireless AirPlay 2 (smart TV vs Apple TV 4K) or also with a USB-C → HDMI adapter?

### 11.3 Technical Risks & Mitigations

- **AirPlay + Debug Link Wi-Fi Contention:** Wireless AirPlay streams 1080p video from the iPhone while `ScreenStreamer` uploads JPEGs over the same Wi-Fi radio. *Mitigation:* Cap external-display Debug Link uploads at `0.5×` resolution (`960×540`, JPEG `q = 0.65`, `~70 KB/s` at 1 fps) and keep `inFlight` frame-dropping (`ScreenStreamer.swift:49`).
- **`AVPlayerLayer` Black Box in Debug Link Screen Captures:** As documented in `ScreenStreamer.swift:17`, `UIWindow.drawHierarchy` renders `AVPlayerLayer` black. On `screen/latest-external.jpg`, the right 50% (composited rear camera + skeleton) and all SwiftUI HUDs/rings/scorecards will appear in full color while the left 50% teacher video box appears black unless an optional 1 Hz `AVPlayerItemVideoOutput` compositor is added later.
- **TV Reflection in Background Mirrors:** Placing the phone in front of the TV facing the dancer keeps the TV behind the camera, which is ideal; however, if the dancer has a wall mirror *behind* them, the rear camera will see the TV reflected in the mirror (`num_poses = 1`, `2026-10-31-course-platform-design.md:49`, could lock onto the teacher video playing on the TV reflection!). *Mitigation:* Warn in `sceneTips` (*"Avoid standing with a mirror directly behind you facing the TV"*), and during `rest`/`tpose` check that the tracked person's LiDAR depth `dancerDistanceM` is physical (`2.0–4.0 m`) rather than a mirror plane reflection (`> 5 m`, which LiDAR returns as invalid/NaN!).
