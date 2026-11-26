# Groove Coach Calibration v2, Rear-Camera + LiDAR, AirPlay TV Stage & Gesture UI Plan

**Date:** 2026-11-26
**Order:** `calib2-plan-v4` (`Run: calib2`)
**Base commit:** `aa5953e`
**Target hardware:** `iPhone18,2` (iPhone 17 Pro Max), iOS 26.6.1, rear LiDAR scanner, live LAN Debug Link (`%LOCALAPPDATA%\groove-coach\debuglink\`)

Throughout this specification:
- Every factual claim cites an opened source from `docs/research/2026-11-26-owner-s-words-update-the-calibration/report.md`, `docs/research/2026-11-18-calibration-research.md`, `Chuyuyan/dance-trainer` (`src/pose/checkup.ts`), or an exact `file:line` in this repository.
- **(inference)** marks design thresholds, formulas, or dance-specific pose steps derived from first principles and existing repo constraints rather than copied verbatim from an external source.
- Any Apple SDK symbol, runtime behavior, or hardware/AirPlay latency figure whose documentation page was not opened in the two research reports is **never guessed as fact**—it is explicitly flagged in text, measured in the Phase-1 Device Spike (**Device Gate 1**), and listed in **§11.1 / §11.2**.

---

## Executive Summary

Groove Coach shifts its primary studio setup from a phone-screen self-view to a **hands-free TV coaching stage**:
1. **Phone placement:** The iPhone sits in front of the TV (waist/table height, ~0.50–1.0 m off the floor; Dina `50–70 cm` in `2026-11-18-calibration-research.md:105`) with its **rear wide camera + LiDAR scanner** facing the dancer in the **2.0–4.0 m** studio band. Because the glowing TV sits behind the phone, it naturally illuminates the dancer from the front (`2026-11-18-calibration-research.md:73,200`).
2. **Display split:** The dancer watches a dedicated **16:9 landscape External-Display `UIWindowScene`** over AirPlay (validated early via **Order #4 `calib2-airplay-scene-spike`** in Wave 1A and measured at **Device Gate 1**) while the phone renders a dark OLED minimal status/emergency-touch screen.
3. **Pose + LiDAR hybrid:** **MediaPipe `pose_landmarker_full` + `hand_landmarker`** remains the sole pose extractor for both live feedback (`LIVE_STREAM`) and authoritative post-take grading (`VIDEO`), preserving 100% model parity with authored lessons (`AttemptExport.swift:16-24`, `docs/specs/2026-10-31-course-platform-design.md:19-20,124`) and keeping CI's ban on Vision pose symbols intact (`.github/workflows/ios-sideload-ipa.yml:95-97`). **Rear LiDAR (`AVDepthData` + `AVCameraCalibrationData`)** runs at low rate (5–10 Hz) during calibration and 1 Hz idle checks—never during take recording—to calibrate camera height, floor plane, runtime distance (`[d_effective_min, 4.0 m]`), metric dancer height, and a per-user `metricScaleFactor` mapping MediaPipe world bones to physical metres.
4. **9-pose easiest-first dance calibration:** Modeled on `Chuyuyan/dance-trainer` (`src/pose/checkup.ts:4-12,62-117`) plus two dance additions (`stepLR`, `kneeLift`), persisted in a versioned `CalibrationProfileV2` so full 9-pose calibration (~28 s) runs once per dancer, environment re-placement (~4–6 s) runs only when gravity or LiDAR floor height changes, and unmoved in-session takes resume in <1 s.
5. **Front-camera fallback:** Preserved as an automatic fallback (`CameraMode.frontSelfView`) whenever no external display is connected or when toggled manually.

---

## 1. Pose Pipeline on the Rear Camera (with Front-Camera Fallback)

### 1.1 Re-Weighing the Scholar Decision Matrix Without the Phone Self-View Constraint

In `docs/research/2026-11-26-owner-s-words-update-the-calibration/report.md:18-32`, Option (f) (*front wide camera, MediaPipe + Vision 3D, no depth*, **4.08 / 5.0**) beat Option (e) (*depth only for metric scale & floor plane*, **4.00**) and Option (b) (*rear LiDAR + `ARBodyTrackingConfiguration`*, **3.33**) solely because **Camera-Switching Cost / UX (25% weight)** scored rear-camera options `1.0 / 5.0` under the assumption that the dancer must see the phone screen (`report.md:19`).

With the TV displaying the coaching UI via AirPlay, the rear camera faces the dancer continuously across calibration *and* takes (zero camera-flip friction; UX = `5.0`). Re-evaluating the three rear-camera candidates against Groove Coach's codebase and CI invariants shows why **extractor parity** and **thermal budget** decide the winner:

| Pipeline Candidate | Scoring Extractor Parity | Mapping to 33-Landmark `CanonicalSkeleton` | Live FPS & Thermal Cost on `iPhone18,2` | Verdict |
|---|---|---|---|---|
| **A. ARKit `ARBodyTrackingConfiguration` + `ARFrame.sceneDepth`** (rear only, `report.md:39-45,83-85`) | **Breaks parity.** Outputs ARKit's 3D body rig rather than MediaPipe's sha256-pinned `pose_landmarker_full`. `AttemptExport.canGrade` (`AttemptExport.swift:16-24`) and spec §2.2 (`2026-10-31-course-platform-design.md:124`) forbid grading cross-model poses. Lacks MediaPipe's 4 foot landmarks (`29..32`) required by `requiredFootJoints` (`ScoringEngine.swift:68-70,540-558`) and 21-point hands. | Requires a lossy cross-rig joint adapter *(inference: systematic joint-center offsets corrupt `spine_jack_angle`, `foot_pitch_deg`, and `Retarget.canonicalBones`)*. Also `ARBodyTrackingConfiguration` runs on `ARSession` (`report.md:83-85`) whereas `PracticeCamera` + `TakeRecorder` run on `AVCaptureSession` (`PracticeCamera.swift:31,253`); coexistence of `ARSession` with `PracticeCamera`'s recording pipeline was not verified in `report.md` (§11.1). | **High thermal cost *(inference)*.** Running ARKit 3D body tracking + `sceneDepth` alongside AirPlay display encoding, `AVPlayer` decode, and MediaPipe (still required for parity grading) duplicates neural-engine pose work. | **Reject** |
| **B. AVFoundation Rear + MediaPipe + Vision 3D (`VNDetectHumanBodyPose3DRequest` with `AVDepthData`)** (`report.md:35-38`) | **Blocked by CI & redundant.** Both `.github/workflows/ios-sideload-ipa.yml:95-97` and `ios-testflight.yml:104-106` fail the build if `VNDetectHuman(Body|Hand)Pose` appears in `nm -u` (which matches `VNDetectHumanBodyPose3DRequest`). Vision 3D also lacks heel/toe landmarks (`2026-10-31-course-platform-design.md:173-194`). | Would require fusing Vision 3D's body joints with MediaPipe's feet and hands—the exact dual-model architecture removed in the course-platform migration (`2026-10-31-course-platform-design.md:193`). | **Medium-High *(inference)*.** Runs two 3D pose neural networks per frame (`MediaPipe` + `VNDetectHumanBodyPose3DRequest`) plus AirPlay video encode. | **Reject** |
| **C. Hybrid: AVFoundation Rear Camera + MediaPipe (`LIVE_STREAM` / `VIDEO`) + Low-Rate LiDAR `AVDepthData` Calibration** *(Recommended)* | **100% parity preserved.** `TakeRecorder` records 720×1280 H.264 `.mov` (`PracticeCamera.swift:278-281`); post-take scoring runs `MediaPipePoseProvider.extract(videoURL:)` (`MediaPipePoseProvider.swift:132-213`) + `HandPoseExtractor`, identical to lesson authoring. | **Direct, lossless.** Uses `CanonicalSkeleton.toCanonical` (`CanonicalSkeleton.swift:120-171`) on all 33 MediaPipe pose landmarks + 21 hand landmarks. LiDAR supplies `metricScaleFactor`, `floorPlane`, and `dancerDistanceM` without altering joint topology. | **Low thermal cost *(inference, verified in Device Gate 1)*.** Capture capped at 30 fps (`1280×720`); `MediaPipePoseProvider.live` runs at 20–30 fps (`PracticeCamera.swift:190-205`); LiDAR depth runs **only** at 5–10 Hz during calibration and 1 Hz idle checks, **0 Hz during `.countIn` and `.recording`**. | **Adopt** |

### 1.2 How Pipeline C Feeds Scoring, Live UI, and `CanonicalSkeleton`

1. **Capture Modes (`CameraMode`):**
   - `rearLiDAR` *(default when an external AirPlay/TV display is connected, or when manually selected on a LiDAR device)*: Configures `AVCaptureSession` on the rear LiDAR-capable wide camera (`position: .back`, `report.md:29`; exact `AVCaptureDevice.DeviceType` selection verified against Xcode headers in §11.1), delivering upright 720×1280 `32BGRA` video frames (`videoRotationAngle = 90`, un-mirrored buffer, `PracticeCamera.swift:156-169`) plus throttled `AVDepthData` + `AVCameraCalibrationData` (`report.md:11,93-95`). Degrades gracefully to `rearWide` (rear wide camera without depth) if LiDAR is unavailable.
   - `frontSelfView` *(automatic fallback when no external display is connected, or via user toggle)*: Existing `.builtInWideAngleCamera` at `position: .front` (`PracticeCamera.swift:146`), phone-screen HUD (`CalibrationOverlayView.swift:204`), `metricScaleFactor = 1.0`, no LiDAR checks.
2. **Coordinate & Mirroring Invariance Across Rear and Front Cameras:**
   - **Physical optical geometry *(inference from pinhole optics + `CalibrationGate.swift:9-12`)*:** Any lens placed in front of the dancer facing their chest views the dancer from the front—so the dancer's **own right side** projects onto the **left** side of an un-mirrored upright portrait image (`raw x < 0.5`), and their **own left side** projects onto `raw x > 0.5` (`CalibrationGateTests.swift:35`: `"leftShoulder": (0.56, 0.33), "rightShoulder": (0.44, 0.33)`), subject to **Device Gate 1** confirming that `AVCaptureVideoDataOutput`'s `connection.isVideoMirrored` defaults to `false` under `videoRotationAngle = 90` on `.back` on `iPhone18,2` (§11.1).
   - **TV & Phone Preview Mirroring (Explicit Ownership):** Today `CameraPreview` (`PracticeView.swift:487-508`, owned by Order #13) hosts `AVCaptureVideoPreviewLayer` for the front selfie camera without explicitly setting `isVideoMirrored` (relying on UIKit/AVFoundation's front-camera preview defaults), while `ScreenStreamer.collectPreviews` (`ScreenStreamer.swift:128`) reads `preview.connection?.isVideoMirrored ?? true` when compositing Debug Link screenshots. Because `AVCaptureConnection.automaticallyAdjustsVideoMirroring` and `.back` preview mirroring pages were not opened in either research report (§11.1):
     - **Order #4 (`ExternalDisplayManager.swift`)** verifies those `AVCaptureConnection` properties against local Xcode headers and validates rear-camera `AVCaptureVideoPreviewLayer` mirroring on the external `UIWindowScene` during **Device Gate 1**.
     - **Order #10 (`TVCoachingStageView.swift`)** defines its own dedicated **`TVCameraPreview`** (`UIViewRepresentable` hosting `AVCaptureVideoPreviewLayer` with `videoRotationAngle = 90`, `automaticallyAdjustsVideoMirroring = false`, and `isVideoMirrored = true`) so the 16:9 TV stage compiles in Wave 2A without touching `PracticeView.swift`, and the dancer watching the TV moves screen-left when stepping to their own left—matching `PracticeCamera.mirrorForDisplay = true` (`PracticeCamera.swift:66,247-249`) and `ScreenStreamer.collectPreviews` (`ScreenStreamer.swift:128`).
     - **Order #13 (`PracticeView.swift`)** updates phone-side `CameraPreview` (`PracticeView.swift:487-508`) with a default-true `var mirrored: Bool = true` parameter (keeping `LessonPlayerView.swift:108`'s existing `CameraPreview(session:)` call source-compatible while ensuring manual rear-camera phone preview is also horizontally mirrored).
     - Meanwhile, **Order #6 (`PracticeCamera.swift`)** keeps `AVCaptureVideoDataOutput` explicitly un-mirrored so `MediaPipePoseProvider`, `TakeRecorder`, and `CalibrationGate` receive identical raw coordinates in both modes.
   - **Rear-vs-Front CoreMotion Gravity Z-Sign Flip (Hardware Geometry):** In `CMDeviceMotion.gravity` (`2026-11-18-calibration-research.md:53,122`, `CalibrationGate.swift:47`), `+Y` points toward the top edge of the portrait phone and `+Z` points out of the **front** screen (so `-Z` points out of the **rear** lens). In `2026-11-18-calibration-research.md:114-121,708-709`:
     - `Poser` (`Camera.swift`, lines `115, 709`) computes rear-camera pitch as `atan2(g.z, -g.y)`.
     - `aicam` (`FrameAnalyzer.swift`, lines `116, 708`) computes `atan2(g.z, hypot(g.x, g.y))` and **negates the sign for the front camera**.
     - `CalibrationGate.swift:429-431` adopted the front-camera signed form `tiltBackDeg = atan2(-g.z, -g.y) * 180 / .pi` (`2026-11-18-calibration-research.md:120`).
     Combining Poser's signed `atan2(..., -g.y)` form with `aicam`'s front/rear z-sign flip **(inference, verified on `iPhone18,2` in Device Gate 1)**: aiming the **rear** camera slightly upward (`+10°` optical elevation from a `0.7 m` table) tilts the front screen slightly face-down (`g.z > 0`), so upward optical tilt is:
     $$\text{tiltBackDeg} = \begin{cases} \operatorname{atan2}(+g_z, -g_y) \cdot \frac{180}{\pi} & \text{in } \texttt{rearLiDAR} / \texttt{rearWide} \\ \operatorname{atan2}(-g_z, -g_y) \cdot \frac{180}{\pi} & \text{in } \texttt{frontSelfView} \end{cases}$$
     Likewise, in `CanonicalSkeleton` (`+x` un-mirrored image-right, `+y` image-up, `+z` from dancer toward camera lens, `CanonicalSkeleton.swift:6-11`), device `gravity = [gx, gy, gz]` aligns directly with canonical camera axes on the **rear** camera (`+X_dev` = un-mirrored scene right, `+Y_dev` = image up, `+Z_dev` = from dancer toward rear lens), whereas on the **front** camera un-mirrored scene right is `-X_dev` and dancer-toward-lens is `-Z_dev` (`cameraGravity = [-gx, gy, -gz]`). Passing camera-frame gravity into `PoseClip.gravity_vector` ensures `applyGravityCorrection` (`ScoringEngine.swift:479-492`) rotates vertical dancers to `(0, +1, 0)` on both cameras.
3. **Mapping to `CanonicalSkeleton` (`groove.canonical/1`):**
   - `CanonicalSkeleton.toCanonical` (`CanonicalSkeleton.swift:120-171`) maps the 33 MediaPipe landmarks (`0` nose, `11..16` shoulders/elbows/wrists, `23..28` hips/knees/ankles, `29..32` heels/toes) plus synthesized `root`, `spine`, `centerShoulder` into root-relative canonical coordinates.
   - During calibration holds, LiDAR depth back-projects visible 2D joints `(u, v)` into metric 3D camera coordinates via `AVCameraCalibrationData.intrinsicMatrix` (`report.md:11,93-95`). The median ratio of LiDAR 3D segment lengths (shoulders, thighs, shins, upper arms) to `CanonicalSkeleton.boneLengths(frame)` (`CanonicalSkeleton.swift:174-182`) yields `metricScaleFactor`, correcting MediaPipe's monocular GHUM scale drift (`report.md:120`) without changing a single joint index.
4. **Frame Rate & Thermal Budget *(inference, verified in Device Gate 1)*:**
   - Cap `AVCaptureDevice` frame rate at **30 fps** (`1280×720`) during calibration and takes (`PracticeCamera.swift:145` uses `.hd1280x720` and authoring references are 30 fps, `2026-10-31-course-platform-design.md:85`).
   - `MediaPipePoseProvider.live` runs asynchronously behind `analysisBusy` (`PracticeCamera.swift:190-195`) at **20–30 fps**; UI skeleton publishing stays throttled to **~15 Hz** (`0.066 s`, `PracticeCamera.swift:231`).
   - LiDAR `AVCaptureDepthDataOutput` runs at **5–10 Hz** during `.calibrating`, **1 Hz** in `.idle` (bump/floor watch), and is **disabled (`0 Hz`) during `.countIn`, `.recording`, and `.analyzing`**.
   - The phone screen renders a static `#000000` status card (`PhoneControllerStatusView`) with zero camera preview layers while the TV scene is active.

---

## 2. Dance Calibration Sequence (9 Poses, Easiest-First)

### 2.1 Coordinate Conventions, Numbering & Design Rationale

Following `Chuyuyan/dance-trainer` (`src/pose/checkup.ts:4-12`, cited in `report.md:57-70`), poses run **easiest-first** (`checkup.ts:10-11`: *"They run easiest first, so a failure part-way through localises the problem instead of just saying the thing is broken"*).

**Unified Step & Pose Numbering Convention (used consistently throughout this spec):**
- **Pre-pose setup steps:** `.resume` (`stepIndex = 0`) → `.level` (`stepIndex = 1`, phone level/tilt/stillness + LiDAR floor RANSAC; non-blocking lighting advice runs in parallel, leaving raw index `3` unused as in `CalibrationGate.swift:135`).
- **Poses 1–9 (`CalibrationStep` cases `.rest` through `.kneeLift`):**
  - **Pose 1:** `.rest` (`stepIndex = 2`, replaces v1 `.frame = 2`; **locks AE/AWB on completion**)
  - **Pose 2:** `.tpose` (`stepIndex = 4`, preserves v1 `.tpose = 4`)
  - **Pose 3:** `.overhead` (`stepIndex = 5`)
  - **Pose 4:** `.asymLR` (`stepIndex = 6`)
  - **Pose 5:** `.armsForward` (`stepIndex = 7`)
  - **Pose 6:** `.plie` (`stepIndex = 8`)
  - **Pose 7:** `.turned45` (`stepIndex = 9`)
  - **Pose 8:** `stepLR` split into sub-holds **8a** `.stepLeft` (`stepIndex = 10`) → **8b** `.stepRight` (`stepIndex = 11`)
  - **Pose 9:** `.kneeLift` (`stepIndex = 12`)
- **Terminal state:** `.locked` (`stepIndex = 13`, renumbered from `5` in v1; see §7.1 migration note).

Two coordinate conventions coexist in `GrooveCore` and must never be conflated:
- **Normalized 2D (`CalibrationLandmark`, `CalibrationGate.swift:65-75`):** Un-mirrored portrait buffer, `x ∈ [0, 1]` right, **`y ∈ [0, 1]` down**. Dancer's anatomical left is at `x > 0.5` (`CalibrationGateTests.swift:35`).
- **Canonical 3D (`RawPoseFrame.joints`, `CanonicalSkeleton.swift:6-11,76-79`):** Gravity-corrected via `GrooveScoringEngine.applyGravityCorrection` (`ScoringEngine.swift:479-492`), root-centered metres, **`+y` up**, **`+z` toward the camera**. `FrameFeatures` knee flexion (`ScoringEngine.swift:524-530`) measures the **exterior** bend angle between `(knee - hip)` and `(ankle - knee)` (`0°` = straight leg), whereas `JointTolerance.defaultAngleTriples` (`JointTolerance.swift:54-58`) measures the interior angle (`180°` = straight). All knee criteria below use `FrameFeatures`'s exterior `knee_flex` (`0°` straight).

(`checkup.ts:93-100` also includes a `head` turn check; it is intentionally omitted because `CanonicalSkeleton.mediapipeIndex` (`CanonicalSkeleton.swift:19-29`) exposes only `nose`—no ears or eyes—and head yaw is ungraded in `ScoringEngine`.)

### 2.2 Pose-by-Pose Dance Calibration Specification (Poses 1–9)

All hold times use **monotonic pose-stream seconds** (`2026-11-18-calibration-research.md:191`), never frame counts. Every pose speaks a concise entry instruction via `CalibrationVoice` (`CalibrationVoice.swift:8,99`, rate `0.52`) and plays a short rising confirmation chime (`CalibrationVoice.swift:131-148`) as each hold completes. Note that `checkup.ts` defines synthetic target landmark coordinates for scoring comparison rather than hold durations or angle thresholds; therefore, every numeric pass threshold below not taken from `CalibrationGate.swift` or `checkup.ts:151` is explicitly marked ***(inference)***.

| Pose # (`CalibrationStep`) | Source | Purpose | Pass Criterion | Hold / Dropout | Spoken Cue (Entry & Diagnostic) | Writes to `CalibrationProfileV2` |
|---|---|---|---|---|---|---|
| **Pose 1: `.rest`** (`stepIndex 2`) | `checkup.ts:63-68` + `CalibrationGate.swift:777` | Full-body framing, leg/foot visibility, LiDAR distance check (`[d_effective_min, 4.0 m]` using both vertical & horizontal FoV, §3.2), tighter studio centring for T-pose/steps, metric dancer height, resting posture baseline, & AE/AWB lock trigger. | `evaluateFraming` passes (`coreVis >= 0.6`, `footVis >= 0.5`, `x ∈ [0.05, 0.95]`, `nose.y >= 0.20`, `maxFootY <= 0.95`, `span ∈ [0.45, 0.75]`) with tighter Tier-2 studio centring **`hipCenterX ∈ [0.40, 0.60]`** (`restHipCenterMinX..MaxX` so T-pose wrists and Pose-8 `±0.12` steps cannot clip; Tier-0 quick resume keeps `[0.30, 0.70]`) **AND** arms relaxed (`lw.y, rw.y > hipY - 0.05·span`, `|wrist.x - hip.x| < 0.22`) **AND** (when rear LiDAR active) `dancerDistanceM ∈ [d_effective_min, 4.0]` **AND** `bodyMotion <= 0.012` (enter) / `0.020` (stay). *(centring/arms/distance/hold: inference)* | **0.6 s** hold / **0.35 s** dropout *(inference)* | Entry: *"Stand centered in the box, feet visible, arms relaxed by your sides."* Diagnostics: existing `.stepBackShowFeet`, `.stepCloser`, `.stepBack`, `.moveLeft`, `.moveRight`, plus dynamic FoV/LiDAR distance cue (§3.5). | `dancerDistanceM`, `effectiveMinDistanceM`, `dancerHeightM`, `rom.standingKneeFlexDeg`, `rom.trunkLeanBaselineDeg`, initial torso/leg `jointConfidenceWeights`; triggers **AE/AWB lock** (§3.3). |
| **Pose 2: `.tpose`** (`stepIndex 4`) | `checkup.ts:69-74` + `OpenJustDance` (`CalibrationGate.swift:931`) | Unoccluded zero-foreshortening capture of all 19 canonical bone lengths (`Retarget.canonicalBones`), calibrated wrist-to-wrist lateral span (`wingspanM`), & LiDAR-to-MediaPipe `metricScaleFactor`. | `tPoseScore >= 0.55` with sub-gates `sY > 0.30`, `sAng > 0.30`, `ext > -0.15` (`CalibrationGate.swift:957-958`), wrists inside `x ∈ [0.03, 0.97]`, `bodyMotion <= 0.012` / `0.020`, and `>= 15` frames captured (`report.md:59`, `CalibrationTuning.swift:146-155`). | **1.0 s** hold / **0.35 s** dropout | Entry: *"Arms straight out to the sides, like a T. Hold still."* Diagnostic if wrists clip `[0.03, 0.97]`: emit `.moveLeft` / `.moveRight` (*"Move toward the center so both hands fit in view"*) when `|hipCenterX - 0.50| > 0.08`, else `.stepBack` (*"Step back slightly so both hands stay in view"*). | `calibrationFrames` (`>= 15` `RawPoseFrame`s), `metricScaleFactor` (`median(L_lidar / L_mp)`), `boneLengthsM` (19 bones in m), `wingspanM` (wrist-to-wrist sum `L/R shoulder+elbow+wrist` from `boneLengthsM`, as live `CalibrationGate` tracks 33 body landmarks without 21-point hands, `2026-10-31-course-platform-design.md:227`), arm `jointConfidenceWeights`. |
| **Pose 3: `.overhead`** (`stepIndex 5`) | `checkup.ts:75-80` | Verifies top-of-frame optical headroom for overhead choreography (`Crown Lotus`, `2026-10-31-course-platform-design.md:98`) and the `restartDrill` gesture (`GestureRecognizer.swift:147`), up/down axis polarity (`checkup.ts:79`), & max shoulder elevation ROM. | Both wrists above nose in 2D (`lw.y < nose.y - 0.05·span`, `rw.y < nose.y - 0.05·span`), unclipped at top edge (`min(lw.y, rw.y) >= 0.02`, wrist visibility `>= 0.45`), 2D/3D interior elbow angle `>= 135°`, `bodyMotion <= 0.015` / `0.025`. *(inference)* | **0.7 s** hold / **0.35 s** dropout *(inference)* | Entry: *"Reach both arms straight up overhead."* Diagnostic if `min(lw.y, rw.y) < 0.02` or wrist lost: *"Step back a little so your raised hands stay in frame."* (`.stepBackHeadroom`) | `overheadHeadroomMinY`, `rom.maxShoulderElevationDeg` (torso-frame angle), overhead wrist/elbow confidence. |
| **Pose 4: `.asymLR`** (`stepIndex 6`) | `checkup.ts:81-86` | Explicit anatomical Left vs Right verification across camera sensor, TV mirror transform, and MediaPipe side labels (`checkup.ts:85`: *"left and right not being swapped"*). | Anatomical `leftWrist` overhead (`lw.y < nose.y - 0.03·span`, left elbow `>= 130°`) **AND** anatomical `rightWrist` horizontal (`|rw.y - rs.y| / torso <= 0.35`, `|rw.x - rs.x| / shoulder >= 0.80`, right elbow `>= 130°`), `bodyMotion <= 0.015` / `0.025`. If **reversed** (`rightWrist` up, `leftWrist` out for `>= 0.35 s`), set `lrSwapped = true` and emit `.swapArmsLR`. *(thresholds: inference)* | **0.7 s** hold / **0.35 s** dropout *(inference)* | Entry: *"Raise your left arm straight up, and stretch your right arm out to the side."* Diagnostic on swap: *"Other side—raise your left arm up, right arm out."* | `lrVerified = true`, `armSymmetryRatio` (`leftArmM / rightArmM`), `lrSwapped` flag in telemetry (`false` once passed cleanly). |
| **Pose 5: `.armsForward`** (`stepIndex 7`) | `checkup.ts:87-92` | Tests monocular Z-depth under severe 2D foreshortening (`checkup.ts:91`: *"depth — the case flat 2D could not see"*) and cross-checks canonical `+z` against rear LiDAR `ΔZ`. (`checkup.ts:43` places synthetic wrists `0.52 m` from shoulders.) | Canonical 3D wrists forward of shoulders (`lw3D.z - ls3D.z >= 0.25 m` and `rw3D.z - rs3D.z >= 0.25 m`), 2D wrists near shoulder height (`|w.y - s.y| / torso <= 0.40`), and when rear LiDAR active, `depthM(shoulder) - depthM(wrist) >= 0.25 m`, `bodyMotion <= 0.015` / `0.025`. *(0.25 m & 0.40 thresholds: inference, allowing MediaPipe foreshortened Z compression)* | **0.7 s** hold / **0.35 s** dropout *(inference)* | Entry: *"Point both arms straight forward toward the camera."* Diagnostic: *"Bring both hands up to shoulder height, pointing at the lens."* | `zDepthScaleRatio` (`ΔZ_lidar / Δz_canonical`), foreshortened elbow/wrist `jointConfidenceWeights`. |
| **Pose 6: `.plie`** (`stepIndex 8`) | `checkup.ts:101-110` (`squat`) | Calibrates lower-body groove ROM (`mean_knee_flex` & `hip_height_norm`, `ScoringEngine.swift:529-531,561,613,910-917`) and verifies knee/ankle tracking under flexion (`checkup.ts:109`). | Exterior `mean_knee_flex >= 22.0°` (and `>= standingKneeFlexDeg + 15.0°`), `hip_height_norm` drop `>= 0.04` below `.rest`, arms out (`sY > 0.25`), ankles/feet visible (`>= footFloorUsed`), `bodyMotion <= 0.018` / `0.028`. *(all numeric thresholds: inference)* | **0.8 s** hold / **0.35 s** dropout *(inference)* | Entry: *"Arms out, bend your knees into a gentle squat and hold."* Diagnostic: *"Bend your knees a little deeper, heels in view."* | `rom.plieKneeFlexDeg`, `rom.plieHipDropNorm`, flexed knee/ankle `jointConfidenceWeights`. |
| **Pose 7: `.turned45`** (`stepIndex 9`) | `checkup.ts:111-116,151` (`turned`) | Verifies torso-frame scoring (`ScoringFeatures.swift:429-445`) at ~45° oblique body turn (`checkup.ts:115` instruction) without edge-on shoulder collapse (`checkup.ts:151`: `Math.abs(xs[0] - xs[1]) < 0.045`). | 2D shoulder width `|ls.x - rs.x| >= 0.045` (`checkup.ts:151`), canonical 3D shoulder XZ yaw `atan2(|rs3D.z - ls3D.z|, |rs3D.x - ls3D.x|) ∈ [25°, 65°]` *(inference; `checkup.ts:111-116` reuses unrotated T-pose landmarks)*, arms extended (`sAng > 0.25`), `bodyMotion <= 0.015` / `0.025`. *(yaw window & stillness: inference)* | **0.7 s** hold / **0.35 s** dropout *(inference)* | Entry: *"Keep arms out and turn your whole body halfway to one side."* Diagnostic if `|ls.x - rs.x| < 0.045`: *"Turn a little less sideways so both shoulders are visible."* | `obliqueTrackingConfidence` (far-side wrist/elbow/hip/knee weights). |
| **Pose 8: `stepLR`** (`.stepLeft` `10` → `.stepRight` `11`) | Dance addition *(inference; `report.md:10,127` notes no OSS benchmark)* | Verifies physical lateral floor clearance (sofas/walls) and horizontal FoV margin for side-travel moves (`step_touch`, `IMG_4941` Segment B sweep, `hip_x_norm` in `ScoringEngine.swift:563,857-859`). | Two sub-holds: **8a (`.stepLeft`):** `hipCenterX - restHipCenterX >= 0.12` (dancer moved left, raw `x` increased) with all core+foot `x <= 0.96`; **8b (`.stepRight`):** `restHipCenterX - hipCenterX >= 0.12` with all core+foot `x >= 0.04`, `bodyMotion <= 0.020` / `0.030`. *(inference)* | **0.5 s** left + **0.5 s** right / **0.40 s** dropout *(inference)* | 8a: *"Take a wide dance step to your left and pause."* → chime → 8b: *"Now take a wide step to your right and pause."* Diagnostic if edge clipped: *"Step back slightly for more side-to-side room."* | `usableLateralSpanM`, `maxSafeHipXNorm`, lateral-edge foot confidence. |
| **Pose 9: `.kneeLift`** (`stepIndex 12`) | Dance addition *(inference; `report.md:10,127` notes no OSS benchmark)* | Tests single-leg balance, kick/bounce hip flexion, MediaPipe L/R ankle non-swapping when feet separate vertically, & lifted foot keypoint (`Heel`, `FootIndex`) confidence (`ScoringEngine.swift:68-70,540-558`). | `max(leftKneeFlex, rightKneeFlex) >= 55.0°` exterior flexion **AND** gravity-aligned ankle height delta `|la3D.y - ra3D.y| >= 0.18 · legScale`, standing ankle + both knees `>= coreFloorUsed`, lifted heel/toe `>= footFloorUsed - 0.05`, relaxed single-leg sway `bodyMotion <= 0.025` / `0.035`. *(inference)* | **0.5 s** hold / **0.45 s** dropout *(inference)* | Entry: *"Lift one knee up toward hip height for a moment."* → final lock chime + *"Locked in! Studio calibrated."* | `rom.maxKneeLiftFlexDeg`, lifted-foot confidence, finalized per-joint `jointConfidenceWeights`. |

---

## 3. Camera + LiDAR Calibration

### 3.1 Camera Intrinsics, Lens Distortion & Canonical Back-Projection

Per `report.md:11,93-100`:
1. **LiDAR Depth Alignment (`AVCameraCalibrationData`):** Read `depthData.cameraCalibrationData` on `AVDepthData` frames (`report.md:93-95`: `AVCameraCalibrationData` is delivered on `AVDepthData` or `AVCapturePhoto`, *not* on video `CMSampleBuffer`s). Extract `intrinsicMatrix` ($f_x, f_y, c_x, c_y$), `intrinsicMatrixReferenceDimensions`, `lensDistortionLookupTable`, and `lensDistortionCenter`. Scale $(f_x, f_y, c_x, c_y)$ linearly from `intrinsicMatrixReferenceDimensions` to the `AVDepthData` map dimensions before back-projecting 2D pixels $(u, v)$ (with $u$ right, $v$ down, optical depth $Z_{\text{depth}} = \text{depth}(u, v) > 0$) directly into **`CanonicalSkeleton`'s right-handed camera axes** (`+X` image-right, `+Y` image-up, `+Z` toward camera lens, `CanonicalSkeleton.swift:6-8`):
   $$X_{\text{cam}} = \frac{(u - c_x) Z_{\text{depth}}}{f_x}, \quad Y_{\text{cam}} = -\frac{(v - c_y) Z_{\text{depth}}}{f_y}, \quad Z_{\text{cam}} = -Z_{\text{depth}}$$
2. **Per-Frame Video Intrinsics (`frontSelfView` & `rearWide` fallback):** On the `AVCaptureVideoDataOutput` connection (`PracticeCamera.swift:166`), guard `connection.isCameraIntrinsicMatrixDeliverySupported` and set `connection.isCameraIntrinsicMatrixDeliveryEnabled = true` (`report.md:98-100`), reading `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` from video `CMSampleBuffer`s. *(Axis order under `videoRotationAngle = 90` is verified in Device Gate 1; see §11.1.)*

### 3.2 Vertical & Horizontal Field of View (FoV) & Reconciled Runtime Minimum Distance (`d_effective_min`)

Per `report.md:101-104` and `2026-11-18-calibration-research.md:24,132-142`:
- Read `captureDevice.activeFormat.videoFieldOfView` (degrees; returns `0` if unknown, `report.md:103`; fall back to `60.0°` when `0`, `2026-11-18-calibration-research.md:140`).
- Because `videoFieldOfView` is the sensor's horizontal (long-side) FoV, in portrait orientation (`720×1280`, aspect $9:16$) it equals the **vertical** FoV $\theta_V$, while the **narrow** portrait horizontal FoV (`2026-11-18-calibration-research.md:24,132,142`) is:
  $$\theta_H = 2 \arctan\!\left(\frac{9}{16} \tan\!\left(\frac{\theta_V}{2}\right)\right)$$
- **Vertical + Horizontal Pinhole Floor $d_{\text{geom\_min}}$ Reconciled with the `2.0–4.0 m` Studio Band *(inference)*:**
  1. **Vertical Head-to-Toe + Raised-Hands Constraint ($d_{\text{vert\_min}}$):** From `2026-11-18-calibration-research.md:134,140`, keeping raised hands ($H_{\text{top}} \approx 1.25 \cdot H_{\text{dancer}}$) and feet inside $\theta_V$ requires:
     $$d_{\text{vert\_min}} = \frac{\max(h_{\text{cam}},\, 1.25 \cdot H_{\text{dancer}} - h_{\text{cam}})}{\tan(\theta_V / 2)}$$
  2. **Horizontal T-Pose + Lateral Step Width Constraint ($d_{\text{horiz\_min}}$):** In `9:16` portrait, $\theta_H$ is much narrower than $\theta_V$ (`41.1°` vs `67.4°` in §6.1). Using $d_{\text{vert\_min}}$ alone (`2.13 m` at $\theta_V = 67.4^\circ$) yields a physical frame width $2 d \tan(\theta_H/2) = 1.60\text{ m}$—barely wider than a `1.46 m` wrist-to-wrist T-pose (`x ≈ 0.045 / 0.955` when dead-centred), clipping immediately under any `hipCenterX` drift or Pose-8's `±0.12` side steps! Therefore, enforce an explicit width constraint over $\theta_H$:
     $$d_{\text{horiz\_min}} = \frac{W_{\text{span}} + M_{\text{lateral}}}{2 \tan(\theta_H / 2)}$$
     where $W_{\text{span}}$ is the dancer's wrist-to-wrist T-pose span (`body.wingspanM`, initialized to $0.85 \cdot H_{\text{dancer}}$ before Pose 2 measures `wingspanM`) and $M_{\text{lateral}} = \texttt{lateralStepMarginM} = 0.55\text{ m}$ *(inference: reserves `~0.275 m` per side for Pose-1 centring tolerance `hipCenterX ∈ [0.40, 0.60]`, Pose-8 `±0.12` lateral travel, and Pose-2/Pose-8 `[0.03, 0.97]` / `[0.04, 0.96]` safe-edge insets)*.
  3. **Combined Floor (`d_effective_min`):** Taking $d_{\text{geom\_min}} = \max(d_{\text{vert\_min}}, d_{\text{horiz\_min}})$, define:
     $$d_{\text{effective\_min}} = \operatorname{clamp}\!\big(\max(\texttt{lidarMinDistanceM},\; d_{\text{geom\_min}}),\; 2.0,\; 3.6\big)$$
     (initializing $H_{\text{dancer}} = 1.76\text{ m}$ until LiDAR measures `dancerHeightM`). By the §6.1 studio example ($\theta_V = 67.4^\circ$, $\theta_H = 41.1^\circ$, $h_{\text{cam}} = 0.74\text{ m}$, $H_{\text{dancer}} = 1.73\text{ m}$, $W_{\text{span}} = 1.46\text{ m}$), $d_{\text{vert\_min}} = 2.13\text{ m}$ while $d_{\text{horiz\_min}} = (1.46 + 0.55) / (2 \tan 20.56^\circ) = 2.68\text{ m}$ (`W_frame = 2.01 m`, keeping T-pose wrists within `[0.037, 0.963]` across the entire `hipCenterX ∈ [0.40, 0.60]` window and leaving ample room for Pose 8's `±0.12` steps), so $d_{\text{effective\_min}} = 2.68\text{ m}$ and the dynamic spoken cue (`ceil(2.68 * 2)/2`) says *"step back to about 3.0 meters"*. Retain `16:9` (`1280×720`) capture in v2 because `MediaPipePoseProvider.swift:185,295` and `PracticeCamera.swift:33` assume `9.0 / 16.0` (`2026-11-18-calibration-research.md:144-148`).

### 3.3 Exposure & White-Balance Lock After Pose 1 (`.rest`)

Per `report.md:105-115` and `2026-11-18-calibration-research.md:195-207`:
1. **Lighting Advice Remains Non-Blocking:** `CalibrationSensors.lightSample` (`CalibrationSensors.swift:69-124`) runs at 2 Hz alongside `.level` (`stepIndex 1`) and Pose 1 (`.rest`, `stepIndex 2`), emitting non-blocking advice (`CalibrationGate.swift:671-691`, `CalibrationTuning.swift:139-145`).
2. **When to Lock AE/AWB:** Lock **immediately when Pose 1 (`.rest`, `stepIndex 2`) finishes**—never during `.level` (`stepIndex 1`) when hands or walls dominate the meter, and before Pose 2 (`.tpose`, `stepIndex 4`) begins, so auto-exposure and white balance do not pump across Poses 2–9 and subsequent takes (`MET-POSE`, `2026-11-18-calibration-research.md:201`).
3. **How to Lock (`report.md:105-115`):** Inside `device.lockForConfiguration()` / `device.unlockForConfiguration()`:
   - **Motion-Blur Shutter Cap *(inference)*:** Fast dance wrist/foot hits blur above `1/60 s` (`0.0167 s`). If `device.exposureDuration.seconds > 0.0167` and `device.isExposureModeSupported(.custom)`, compute `lockedDuration = 1/60 s` and `lockedISO = min(activeFormat.maxISO * 0.75, device.iso * (currentDuration / 0.0167))`, then call `setExposureModeCustom(duration:iso:completionHandler:)` (`report.md:108-109`). Otherwise, if `device.isExposureModeSupported(.locked)`, set `device.exposureMode = .locked` (`report.md:106-107`).
   - **White Balance Lock:** If `device.isWhiteBalanceModeSupported(.locked)`, set `device.whiteBalanceMode = .locked` (`report.md:111-112`, or `setWhiteBalanceModeLocked(with:completionHandler:)`, `report.md:113-114`).
   - **Re-Meter Guard *(inference)*:** Record `lockedMeanLuma` at lock time and report `exposureLocked: Bool` on `CalibrationLightSample`. Between takes (in `.idle` / `.results`), if 2 Hz `meanLuma` drifts by `|meanLuma - lockedMeanLuma| > 0.20`, revert to `.continuousAutoExposure` / `.continuousAutoWhiteBalance` for `1.0 s` and re-lock. Always unlock on `camera.stop()`, bump reset to `.level`, or `calibration.cancel()`.

### 3.4 Floor Plane & Camera Height / Tilt from LiDAR

Per `report.md:46-50`, rear iPhone LiDAR measures static planes to `~1 mm` precision and rooms within a few centimetres out to `5.0 m` (`Scannr`).
1. **Gravity-Guided Floor RANSAC *(inference)*:**
   - Convert `CMDeviceMotion.gravity` into canonical camera space ($\mathbf{g}_{\text{cam}} = (g_x, g_y, g_z)$ on `.back`; $(-g_x, g_y, -g_z)$ on `.front`) and compute the expected upward floor normal $\hat{n}_g = -\operatorname{normalize}(\mathbf{g}_{\text{cam}})$.
   - Sample a sparse grid of valid LiDAR depth pixels $(u, v, Z_{\text{depth}})$ with $Z_{\text{depth}} \in [1.0, 4.8]\text{ m}$ in the lower third of the portrait frame (`v / H >= 0.65`, excluding pixels inside the dancer's bounding box) and back-project to canonical 3D points $\mathbf{P}_i = (X_{\text{cam}}, Y_{\text{cam}}, Z_{\text{cam}})$ (§3.1).
   - Fit plane $\hat{n}_{\text{floor}} \cdot \mathbf{P} + h_{\text{cam}} = 0$ (with $\hat{n}_{\text{floor}} \cdot \hat{n}_g > 0$) via 40-iteration 3-point RANSAC (`inlierThreshold = 0.02 m`), accepting only candidate normals within `15°` of $\hat{n}_g$ and requiring `>= 80` inliers.
2. **Derived Calibration Values:**
   - **Camera Height (`cameraHeightM`):** $h_{\text{cam}} > 0$ (perpendicular height of lens above floor, metres). Non-blocking advisory voice cue if `cameraHeightM < 0.50 m` (matching Dina's `50–70 cm` lower bound, `2026-11-18-calibration-research.md:105`: *"Phone is low—raising it to waist or table height around 50 to 70 centimeters improves foot tracking"*) or `> 1.50 m` *(inference)*.
   - **Camera-Mode-Aware Tilt Cross-Check (`lidarFloorTiltDeg`):** Compute angular disagreement $\arccos(\operatorname{clamp}(\hat{n}_{\text{floor}} \cdot \hat{n}_g, -1, 1)) \cdot \frac{180}{\pi}$. On a level floor this cross-checks the camera-mode-aware CoreMotion pitch `tiltBackDeg = atan2(isRear ? +g.z : -g.z, -g.y)` (§1.2) to `< 3.0°` *(inference)*, resolving Risk 1 of `2026-11-18-calibration-research.md:643`.

### 3.5 Metric Dancer Height & Dynamic Distance Check (`[d_effective_min, 4.0 m]`)

1. **Distance Check (`d_effective_min <= dancerDistanceM <= 4.0 m`):**
   - Sample median LiDAR depth $Z_{\text{depth}}$ across $5\times 5$ depth patches centered on the 2D mid-hip and mid-shoulder landmarks (`dancerDistanceM`).
   - **Why `[d_effective_min, 4.0 m]`:** `2.0–4.0 m` is the owner's target studio range (`calib2-plan-v4` brief), where $d_{\text{effective\_min}} \in [2.0, 3.6]\text{ m}$ (§3.2) dynamically raises the floor when a tall dancer or narrower FoV needs extra stand-back distance (`2026-11-18-calibration-research.md:134,140`), while `4.0 m` keeps a `1.0 m` safety buffer inside LiDAR's `5.0 m` hardware cutoff (`report.md:48`) and prevents small-instance pose noise (`checkup.ts:144-147` flags normalized torso height `< 0.09` as *"far away — tracking gets noisy"`; Gu et al., `2026-11-18-calibration-research.md:62`). Hysteresis widens hold bounds by `±0.25 m` *(inference)*; relaxed mode after 15 s widens by `±0.30 m` *(inference)*.
   - **Dynamic Spoken Distance Cues (`2026-11-18-calibration-research.md:140`, *inference*):** Following `11-18:140` (*"Speak the number based on the device's real FoV, then let the framing gate decide"*), format cues using `targetMinM = ceil(d_effective_min * 2) / 2` rather than a hard-coded `"2 meters"`: e.g., *"You're at 2.0 meters—step back to about 3.0 meters so your raised hands fit in frame"* or *"You're over 4 meters away—step a little closer."*
2. **Metric Dancer Height (`dancerHeightM`):**
   - Back-project 2D `nose` and lowest `heel` at `Z_torso` into canonical 3D $\mathbf{P}_{\text{nose}}, \mathbf{P}_{\text{heel}}$; compute heights above the LiDAR floor plane $h_{\text{nose}} = \hat{n}_{\text{floor}} \cdot \mathbf{P}_{\text{nose}} + h_{\text{cam}}$ and $h_{\text{heel}} = \hat{n}_{\text{floor}} \cdot \mathbf{P}_{\text{heel}} + h_{\text{cam}}$.
   - Add crown offset using `baby.py`'s verified `0.15 × (h_nose - h_heel)` rule (`2026-11-18-calibration-research.md:50`): $H_{\text{dancer}} = h_{\text{nose}} + 0.15 \cdot (h_{\text{nose}} - h_{\text{heel}})$, accepted within `[1.10, 2.20] m` *(bounds: inference)*.

---

## 4. AirPlay to TV Architecture & Audio/Video/Scoring Sync

### 4.1 Screen Mirroring vs Dedicated External-Display `UIWindowScene`

*(SDK Verification Note: Neither research report opened Apple's external-display `UIWindowScene`, `UIScene` notifications, `AVAudioSession` AirPlay route/latency, or `AVPlayer.allowsExternalPlayback` pages. Those exact symbols and runtime behaviors are listed in **§11.1** and validated first in **Order #4 `calib2-airplay-scene-spike`** + **Device Gate 1** before Phase 2 builds the full stage views.)*

| Option | TV Screen Utilization | Teacher + Learner Layout | `AVPlayer` Conflict Risk | Phone Thermal / Power Cost | Verdict |
|---|---|---|---|---|---|
| **Plain iOS Screen Mirroring only** | **~31.6% of TV area *(inference: 9:16 inside 16:9)*.** Portrait phone UI (`project.yml:51-52`) pillarboxes into the center third of a `16:9` TV; `120×190 pt` teacher PiP (`LessonPlayerView.swift:126`) is tiny from 3 m. | Cramped portrait stack; touch controls clutter the TV. | High unless external video playback hijack is disabled (§11.1). | High: renders full camera + video UI on the unseen phone screen. | **Fallback only** |
| **Dedicated External-Display `UIWindowScene` ("TV Coaching Stage") + Minimal Phone Controller** *(Recommended)* | **100% of 16:9 TV.** Full landscape 10-foot UI with 28–96 pt typography readable from 2–4 m *(inference)*. | Side-by-side 50/50 split stage (Teacher left, Mirrored Learner + Skeleton right) during takes; large pose mannequin + hold ring during calibration. | Controlled: configure `AVPlayer` to stay inside the composite TV scene rather than switching to full-screen AirPlay Video (verified in Order #4 / §11.1). | Low *(inference)*: phone renders a static `#000000` status card with 0 preview layers. | **Adopt** |

**TV Coaching Stage Layouts (`TVCoachingStageView`, built in Order #10 after Device Gate 1):**
1. **Calibration Stage:** Left 40% shows a high-contrast target pose mannequin for the current step (`Pose 1 of 9`), step title, spoken cue banner (`42 pt` bold), and 9-dot progress bar; Right 60% shows `TVCameraPreview` (mirrored rear-camera feed defined inside `TVCoachingStageView.swift`), green/red safe-box, live skeleton, LiDAR distance pill, and a `160 pt` radial hold ring.
2. **Lesson / Practice Stage:** Left 50% renders `PlayerLayerView` (`LessonPlayerView.swift:1131`, flipped when `isMirrored == true`); Right 50% renders mirrored `TVCameraPreview` + `LiveOverlay` (`LiveMatcher` ok/warn/off limb colors and clean-beat streak badge, `LiveMatcher.swift:36-39`). Center-spanning HUD renders the `4-3-2-1` count-in (`96 pt`), `1..8` beat bar, and gesture hold ring / toast banner.
3. **Results Stage:** Landscape 10-foot scorecard (`Pass / Keep Drilling`, Shape/Groove/Hits/Hands chips, top joint hint, worst beat offset, coloured stick figure) with bottom gesture legend (*"Swipe Left: Try Again · Swipe Right: Next · Clap: Continue"*).
4. **Phone Screen (`PhoneControllerStatusView` while TV Connected):** Pure black `#000000` canvas, dim status header (*"TV Stage Active · Rear Camera + LiDAR"*), audio route badge, three oversized emergency touch buttons (**Pause / Resume**, **Skip Calibration**, and **Use Phone Screen (Front Camera)**), plus an optional **Sync TV Audio** button shown only when `ExternalDisplayManager.shared.clapSyncAction != nil` (Phase-3 Order #15).

### 4.2 AirPlay Latency vs Audio, Video, and Scoring Synchronization

Neither research report measured wireless AirPlay audio latency, AirPlay external-scene video latency, or downstream TV DSP delay, nor did either report verify whether iOS paces external `UIWindowScene` frames to match AirPlay audio (§11.1). Therefore, **this plan makes zero unverified assumptions about AirPlay milliseconds or automatic OS frame pacing**. Instead, synchronization is derived directly from the repository's existing `CMClockGetHostTimeClock()` equations (`PracticeCamera.swift:180-183`, `Metronome.swift:19-21,61-65`, `LessonPlayerView.swift:769-777`, `ScoringFeatures.swift:583-586`) with two explicit measurable offsets **(inference)**:

Let $T_0$ be the scheduled take start on `CMClockGetHostTimeClock()` (`videoStartHostSeconds = startInfo.hostSeconds + countInDuration` in `LessonPlayerView.swift:771`):
- **Audio arrival at dancer's ears:** $T_{\text{ear}} = T_0 + \Delta_{\text{audio\_os}} + \Delta_{\text{tv\_dsp}}$, where $\Delta_{\text{audio\_os}} = \texttt{AVAudioSession.sharedInstance().outputLatency}$ (`Metronome.swift:20`, comments note `~10 ms` speakers, `150+ ms` Bluetooth; AirPlay value to be measured in Device Gate 1) and $\Delta_{\text{tv\_dsp}}$ is any uncompensated TV/soundbar processing delay.
- **Teacher video arrival on TV photons:** $T_{\text{tv}} = T_0 + \Delta_{\text{tv\_video}} - \Delta_{\text{lead}}$, where $\Delta_{\text{tv\_video}}$ is the AirPlay external-scene display delay and $\Delta_{\text{lead}} = \texttt{tvVideoLeadOffsetMs} / 1000$ is a configurable `AVPlayer` host-time shift in `LessonPlayerView.swift:769-777`.
- **Rear-camera capture:** `PracticeCamera.hostSeconds` (`PracticeCamera.swift:180-183`) timestamps every `CMSampleBuffer` directly on `CMClockGetHostTimeClock()`, and `LessonPlayerView.swift:853` rebases extracted frames to $T_0$ via `shift = output.firstFrameHostSeconds - videoStartHostSeconds`.

**Four-Part Synchronization Design:**
1. **Measurable `tvVideoLeadOffsetMs` (Measured in Phase-1 AirPlay Spike, Order #4 / Device Gate 1):**
   - Order #4 (`ExternalDisplayManager.swift`) includes a host-clock **Flash + Click Sync Probe** (flashing the external `UIWindowScene` white on beat 4 while playing a `Metronome` click scheduled at the same `mach_absolute_time()`, recorded at 60/120 fps or observed with the rear camera aimed at the TV) and explicitly emits `DebugLink.shared.sendEvent(kind: "av_sync_probe", fields: ...)` (`probeIndex`, `scheduledFlashHostSeconds`, `scheduledClickHostSeconds`, `audioRouteUID`, `outputLatencyMs`, `tvVideoLeadOffsetMs`, `externalResolution`) on each probe trigger and offset commit (§9.2, §9.3). Device Gate 1 measures $\Delta_{\text{tv\_video}} - (\Delta_{\text{audio\_os}} + \Delta_{\text{tv\_dsp}})$ directly on `iPhone18,2` + the owner's TV instead of assuming AirPlay auto-paces external scenes:
     - If AirPlay already paces video to audio within `±25 ms`, `tvVideoLeadOffsetMs = 0.0`.
     - Otherwise, `LessonPlayerView.swift:769` (via `CoachingStageCoordinator`, Orders #12 & #14) shifts `videoMachTime` by `-tvVideoLeadOffsetMs` (when $\Delta_{\text{tv\_video}} > \Delta_{\text{audio}}$) or delays `Metronome` / audio start (when $\Delta_{\text{audio}} > \Delta_{\text{tv\_video}}$) so teacher movement and music land together on the TV.
2. **Scoring Beat Alignment (`effectiveAudioLatencyMs`):**
   - `GrooveScoringEngine.scoreAttempt` already shifts beat/hit timing by `PoseClip.audio_latency_ms` (`ScoringEngine.swift:805`, `ScoringFeatures.swift:583-586`). `CoachingStageCoordinator` (Order #12) computes `effectiveAudioLatencyMs = metronome.outputLatencyMs + airplayRouteOffsetMs` and Orders #13 & #14 pass it into `PracticeView.swift:186` and `LessonPlayerView.swift:913`, aligning rear-camera learner hits with $T_{\text{ear}}$.
3. **Live Limb Feedback Immunity (`LiveMatcher.swift:41-42`):**
   - `LiveMatcher` searches `lagRangeMs = 0...400 ms` (`LiveMatcher.swift:42`), absorbing up to `400 ms` of combined display/audio/reaction lag without penalizing live limb colors or streak count. (If Device Gate 1 measures total AirPlay lag `> 400 ms`, `lagRangeMs` is widened accordingly.)
4. **Standalone `ClapSyncController` with 3-Clap Median & `±35 ms` Deadband (`verifyClapSync`, `ScoringEngine.swift:693-724`) *(inference · Deferred to Conditional Phase-3 Order #15)*:**
   - **Separated from Core Lesson Wiring & Gated on Owner Decision (§11.2 Q3):** Because §11.2 Q3 leaves clap-sync UX policy to the owner (and Device Gate 1 may show `AVAudioSession.outputLatency` already accounts for AirPlay audio within `±35 ms`), clap-sync is **not** bundled into `LessonPlayerView.swift`. Instead, it lives in its own standalone **`ClapSyncController`** (`Order #15 calib2-clap-sync` in Phase 3), invoked via `ExternalDisplayManager.shared.clapSyncAction` with **`GestureMode.disabled`** (§5.2) so claps never collide with `.calibrating` repeat/skip gestures.
   - **Handling Human Clap Asynchrony & Jitter *(inference)*:** Because human rhythmic claps exhibit natural anticipation/jitter comparable to small hardware offsets (note `verifyClapSync`'s `maxToleranceMs = 30.0` at `ScoringEngine.swift:697` and `LearnerBaseline.baseline_timing_bias_ms` at `PoseExporterApp.swift:170`), a single clap would bake human anticipation into `airplayRouteOffsetMs`. Instead:
     1. Run **3 rhythm claps** (beat 4 across three 4-beat bars: *"1, 2, 3, CLAP!"* × 3).
     2. Compute the 3 `verifyClapSync` offsets relative to `beat4HostSeconds + metronome.outputLatencyMs / 1000.0`. If `max - min > 60 ms`, discard as inconsistent and keep `0.0 ms`.
     3. Take `medianOffsetMs` and apply a **`±35 ms` deadband**: if `|medianOffsetMs| <= 35 ms`, set `airplayRouteOffsetMs = 0.0` (leaving small human anticipation to `LearnerBaseline` rather than corrupting route latency); if `|medianOffsetMs| > 35 ms`, store `airplayRouteOffsetMs = clamp(medianOffsetMs, -150.0, 300.0)` keyed by audio route identifier in `CalibrationProfileV2`.

### 4.3 What Happens When AirPlay Drops

*(Exact UIKit scene disconnect/connect notifications and `AVAudioSession` route-change APIs are verified against local Xcode headers in Order #4; see §11.1.)*
1. **Mid-Take (`.countIn` or `.recording`):** `CoachingStageCoordinator` (Order #12) immediately aborts the active take and transitions the host screen to `.paused` (`PracticeView.swift:244`, `LessonPlayerView.swift:826`). **Never** call `recordTake(passed: false, ...)` (`LessonPlayerView.swift:985`), so an AirPlay drop never demotes the learner on the adaptive speed ladder. Speak via `CalibrationVoice` on the iPhone speaker: *"TV disconnected. Take paused. Reconnect AirPlay, or tap Use Front Camera on your phone."*
2. **Mid-Calibration (`.calibrating`, or `ClapSyncController` if Order #15 is active):** Cancel active hold (`calibration.cancel()`), unlock AE/AWB, preserve any already-saved `CalibrationProfileV2` on disk, speak *"TV disconnected. Calibration paused."*, and show reconnect vs `Use Front Camera` buttons on the phone.
3. **Reconnect:** Re-attach the TV stage view to the external `UIWindowScene`, restore `PhoneControllerStatusView` on the phone, run a `0.4 s` Tier-0 framing check, and speak *"TV reconnected. Raise both hands or clap to resume."*

---

## 5. Hands-Free Gesture UI

### 5.1 Two Existing Codebase Bugs Fixed by This Plan

1. **Inverted Y-Axis in `PracticeCamera.swift:223-226`:** `GestureRecognizer` (`GestureRecognizer.swift:7-8,147-148`) expects Vision-style **`y`-up** coordinates (`l.y > head + config.raisedMargin` for wrists above head), whereas `MediaPipePoseProvider.latestNormalizedLandmarks` (`MediaPipePoseProvider.swift:299`) outputs MediaPipe **`y`-down** coordinates (`0` = top, `1` = bottom). Today `PracticeCamera.swift:223,225` passes `y: Double(p.y)` and `headY: Double($0.y)` unflipped, causing normal standing with arms hanging down (`wrist.y ≈ 0.55 > nose.y ≈ 0.25 + 0.05`) to fire `.restartDrill`, while raising hands overhead (`wrist.y ≈ 0.10 < 0.25`) never fires! **Fix:** Add `GestureSample.fromMediaPipeNormalized(...)` in `GrooveCore` flipping `y = 1.0 - mpY` once, tested in `GestureRecognizerTests`.
2. **Missing Gesture Wiring in `LessonPlayerView.swift`:** `PracticeView.swift:40-42` wires `camera.onGesture`, whereas `LessonPlayerView.swift` never assigns `camera.onGesture`. **Fix:** Introduce a pure `GestureRouter` in `GrooveCore` (Order #2) bound once in `CoachingStageCoordinator` (Order #12) and shared by both `PracticeViewModel` (Order #13) and `LessonPlayerViewModel` (Order #14).

### 5.2 Gesture Modes, Re-Arm Latch & Command Mapping Across Coaching States

Three state-transition hazards must be prevented by construction in `GestureRecognizer` + `GestureRouter` **(inference)**:
1. **No Claps or Double-Claps in `.countIn`:** At 100–120 BPM (`0.50–0.60 s` per beat), dancers clapping on beat during a 4-beat count-in produce two claps `< 1.8 s` apart—which would immediately trigger `doubleClap` and cancel the take if `doubleClap` were active in `.countIn`! Therefore, **both single clap (`togglePause`) and `doubleClap` are disabled in `.countIn` and `.recording`**.
2. **Mandatory Lower-Hands Re-Arm Latch After Start (`resetPreservingHoldLatch`):** In `.idle` / `.results` / `.paused`, raising both hands for `1.0 s` fires `.restartDrill` (**Start Take**), transitioning immediately into `.calibrating` or `.countIn` while the dancer's hands are *still overhead*. If `.countIn` started a fresh `1.2 s` overhead hold timer immediately, keeping hands raised for one extra second would cancel the take it just started!
   - **Fix:** Add `mutating func resetPreservingHoldLatch()` on `GestureRecognizer`, called on every `GestureMode` / `Phase` transition. It clears swipe `tracks`, clap `distances`, and `clapMeetTime`, **and keeps `raisedConsumed = true` (`GestureRecognizer.swift:111,151`) whenever either wrist is above `headY`**, requiring **both** wrists to drop below `headY` (`l.y < head && r.y < head` in `y`-up space) continuously for **`0.25 s`** before a new overhead hold can arm in `.countIn` or `.recording`!
3. **Dedicated `GestureMode.disabled` for `.analyzing` (and Phase-3 `ClapSyncController`):** Suppresses all gesture commands during post-take video extraction and during the optional 3-clap AirPlay sync check (`verifyClapSync`, Order #15).

| App Phase (`GestureMode`) | `togglePause` (Single Clap) | `doubleClap` (2 Claps ≤ 1.8 s) | `restartDrill` (Both Hands Up Hold) | `swipeLeft` (Arm Sweep Left) | `swipeRight` (Arm Sweep Right) |
|---|---|---|---|---|---|
| **Idle / Lesson Review** (`.betweenTakes`) | Play / Pause teacher preview (`LessonPlayer`) or Start Take (`Practice`) | — | **Start Take / Confirm Ready** (`1.0 s` hold) | Restart segment preview from `startS` | Next segment (if unlocked) / Next move |
| **Calibrating (Poses 1–9)** (`.calibrating`) | **Repeat Spoken Cue** (`CalibrationVoice`) | **Skip Calibration** (`CalibrationController.skip()`) | *Disabled* (collides with Pose 3 `.overhead`) | *Disabled* (collides with Pose 2 `.tpose`) | *Disabled* (collides with Pose 2 `.tpose`) |
| **3-Clap Sync Sheet (Order #15)** (`.disabled`) | *Disabled* (raw wrist distances feed `verifyClapSync`) | *Disabled* | *Disabled* | *Disabled* | *Disabled* |
| **Count-In** (`.countIn`) | *Disabled* (dancers clap on beat) | *Disabled* (on-beat claps are `< 1.8 s` apart) | **Cancel / Pause Take** (`1.2 s` stationary hold, **only after lowering hands below `headY` for `0.25 s`**) | *Disabled* | *Disabled* |
| **Recording (Dancing)** (`.recording`) | *Disabled* (collides with Namaste / claps) | *Disabled* | **Emergency Pause Take** (`2.0 s` **stationary** hold `bodyMotion <= 0.020`, **after lower-hands re-arm**) | *Disabled* (collides with lateral sweeps) | *Disabled* (collides with lateral sweeps) |
| **Analyzing** (`.disabled`) | *Disabled* | *Disabled* | *Disabled* | *Disabled* | *Disabled* |
| **Results** (`.betweenTakes`, after `1.0 s` post-take grace cooldown) | **Confirm / Continue** (if `passed` & unlocked → Next; else → Try Again) | — | **Repeat Take** (`1.0 s` hold, after lower-hands re-arm) | **Repeat Take** (same rate) | **Next Segment / Move** (if unlocked; else close results to review) |
| **Paused** (`.betweenTakes`) | **Resume / Start Take** | — | **Restart Take** (`1.0 s` hold, after lower-hands re-arm) | Exit to Lesson Review | Next Segment / Move |

### 5.3 False-Trigger Guards During Choreography

Evidence from `IMG_4941` (`2026-10-31-course-platform-design.md:92-104`) motivates each guard:
- **Segment B (`4.80–6.40 s`):** "Peek-a-Boo to Lateral Sweep" sweeps wrists across >35% of image width → blocked because swipes are disabled outside `.betweenTakes`.
- **Clasp Windows (`4.80–5.87 s`, `12.75–13.65 s`):** Namaste and wrist clasps bring `wristDistance < 0.06` → blocked because claps and double-claps are disabled in `.countIn` and `.recording`.
- **Segment D (`12.75–13.65 s`):** "Crown Lotus" holds both wrists above the head for `0.90 s` → blocked in `.recording` because emergency pause requires `2.0 s` continuous overhead hold (`> 2×` Crown Lotus) *simultaneously* with `bodyMotion <= 0.020` (dancer stopped moving) after lowering hands.
- **Post-Take Grace Cooldown (`1.0 s`):** Entering `.results` calls `resetPreservingHoldLatch()` and ignores gestures for `1.0 s` so a final dance flourish never dismisses the scorecard. Between takes, swipes retain the `0.3 s` quiet wind-up (`swipeQuietExtent = 0.08`, `GestureRecognizer.swift:69-72,225-234`).

### 5.4 On-TV Visual & Audio Feedback for Gestures

- **Pre-Trigger Hold Ring:** Expose `holdProgress: Double` (`0...1`) from `GestureRecognizer` at 15 Hz. Whenever `holdProgress >= 0.15` (and `raisedConsumed == false`), display a translucent top-center progress ring on `TVCoachingStageView` (*"Hold hands up to Start…"* / *"Hold still to Pause…"*).
- **Recognized Command Banner + Earcon:** On fire, log `kind: "gesture_fired"` via `DebugLink`, display a `40 pt` bold capsule banner (`GestureToast` scaled for TV) for `1.5 s`, and play a 200 ms `AVAudioEngine` earcon via `CalibrationVoice` (rising fifth for Start/Confirm, double-tick for Next/Repeat, descending fourth for Pause/Skip).

---

## 6. `CalibrationProfile` v2 Data Model, Persistence & Re-Calibration Rules

### 6.1 Versioned Schema (`CalibrationProfileV2`, `groove.calibration/2`)

Today `CalibrationProfile` (`CalibrationGate.swift:234-244`) holds only `frames` and `gravity` in memory (`CalibrationController.lastProfile`, `CalibrationOverlayView.swift:30`).

`CalibrationProfileV2` (`Codable, Equatable, Sendable` in `GrooveCore`) is persisted atomically as JSON to `Application Support/Calibration/calibration_profile_v2.json` (excluded from iCloud backup, matching `LessonStore` in `2026-10-31-course-platform-design.md:156`), separating **session environment fields** (invalidated when the phone moves) from **dancer anatomical fields** (reusable across sessions).

*(Note on mathematical consistency of the illustrative `rearLiDAR` payload below: rear camera aimed upward by `+9.9°` tilts the front screen slightly face-down, giving `gravity.z = +0.172 > 0` and rear `tiltBackDeg = atan2(+0.172, 0.985) = +9.9°`; canonical upward floor normal `[-0.010, 0.986, -0.166]` agrees with `-normalize(gravity)` to `0.9°`; square-pixel portrait intrinsics `fx = fy = 959.6` on `720×1280` give exact pinhole FoVs $\theta_H = 2\arctan(360/959.6) = 41.1^\circ$ and $\theta_V = 2\arctan(640/959.6) = 67.4^\circ$; wrist-to-wrist `wingspanM` equals the exact sum of the six L/R arm segments in `boneLengthsM` ($2 \times (0.19 + 0.28 + 0.26) = 1.46\text{ m}$); $d_{\text{vert\_min}} = (1.25 \times 1.73 - 0.74)/\tan(33.7^\circ) = 2.13\text{ m}$ while $d_{\text{horiz\_min}} = (1.46 + 0.55)/(2 \times 360/959.6) = 2.68\text{ m}$, giving `effectiveMinDistanceM = 2.68 m < dancerDistanceM = 2.85 m`; and at `2.85 m` the `92%` safe frame width `x ∈ [0.04, 0.96]` is $0.92 \times 2 \times 2.85 \times (360/959.6) = 1.97\text{ m}$.)*

```json
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
      "lidarGravityDisagreementDeg": 0.9
    },
    "effectiveMinDistanceM": 2.68,
    "dancerDistanceM": 2.85,
    "usableLateralSpanM": 1.97,
    "overheadHeadroomMinY": 0.06,
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
```

### 6.2 Three-Tier Re-Calibration Policy *(inference)*

| Tier | Trigger Condition | What Runs (`CalibrationStep` sequence) | Wall-Clock Time |
|---|---|---|---|
| **Tier 0 (`calibrationTier = 0`): Instant In-Session Resume** | Same app session, same `cameraMode`, CoreMotion `gravityDeltaG < 0.05 g` (`resumeGravityDeltaG`), **AND** (if `rearLiDAR`) live LiDAR `|cameraHeightM - stored.cameraHeightM| < 0.03 m` and `floorNormalAngleDeltaDeg < 3.0°`. | `.resume (0)` → Pose 1 `.rest (2)` (`0.4 s` framing + `[d_effective_min, 4.0 m]` distance check + AE/AWB lock) → `.locked (13)`. Sets `resumed = true`, `resumedBody = true`. | **~0.5–1.0 s** |
| **Tier 1 (`calibrationTier = 1`): Environment Re-Calibration (Phone Moved / New Session)** | Valid `CalibrationProfileV2` on disk (`age <= 30 days`), **AND** (`gravityDeltaG >= 0.05 g`, OR LiDAR `|cameraHeightM - stored| >= 0.03 m`, OR new app launch). | `.level (1)` (+ LiDAR floor plane) → Pose 1 `.rest (2)` (framing + `[d_effective_min, 4.0 m]` distance + AE/AWB lock + LiDAR `measuredHeightM`). **Same-dancer check:** if `|measuredHeightM - body.dancerHeightM| <= 0.06 m` (or in `frontSelfView` fallback), update `environment`, reuse `body` (`resumedBody = true`), and jump to `.locked (13)`! | **~4–6 s** |
| **Tier 2 (`calibrationTier = 2`): Full 9-Pose Body + Studio Calibration** | (a) No `CalibrationProfileV2` (`schemaVersion == 2`) on disk; (b) `age > 30 days`; (c) `rearLiDAR` active now while stored profile was `frontSelfView` (`body.dancerHeightM == nil`); (d) LiDAR detects a different dancer (`|measuredHeightM - body.dancerHeightM| > 0.06 m`); or (e) user triggers **Recalibrate Studio** in Calibrate tab. | `.level (1)` → **Poses 1–9** (`.rest (2)` → `.tpose (4)` → `.overhead (5)` → `.asymLR (6)` → `.armsForward (7)` → `.plie (8)` → `.turned45 (9)` → `.stepLeft (10)` → `.stepRight (11)` → `.kneeLift (12)`) → `.locked (13)`. Sets `resumedBody = false`. | **~25–32 s** |

**Mid-Calibration Bump Watch:** As in `CalibrationGate.swift:477-483`, if `gravityDeltaG > bumpGravityDeltaG` (`0.05 g`) or `|cameraHeightM - lockedCameraHeightM| > 0.04 m` occurs during any of Poses 1–9 (`stepIndex 2, 4...12`), `CalibrationGate` resets immediately to `.level (1)` and sets `needsExposureLock = false` so `CalibrationController` unlocks AE/AWB for fresh re-metering.

---

## 7. Mapping Onto `CalibrationGate` Steps and `CalibrationTuning` Keys

### 7.1 Pure State Machine Architecture & Explicit `CalibrationStep` Migration

`CalibrationGate` (`ios/GrooveCore/Sources/GrooveCore/CalibrationGate.swift`) remains a pure `Foundation`-only `Sendable` struct with zero Apple framework dependencies so every transition, pose scorer, LiDAR check, and resume rule runs in `< 0.1 s` under `swift test --package-path ios/GrooveCore` on Linux CI (`.github/workflows/linux-ci.yml:31-33`).

1. **Fourth Pure Input Stream (`CalibrationDepthSample`):**
   Alongside `update(motion:)`, `update(pose:)`, and `update(light:)`, add `@discardableResult public mutating func update(depth: CalibrationDepthSample) -> CalibrationStatus`. `CalibrationSensors` (in `GrooveApp`) performs `AVDepthData` pixel reads and RANSAC plane fitting off-main, feeding `CalibrationGate` pure scalars: `timestamp`, `dancerDistanceM`, `measuredHeightM`, `cameraHeightM`, `floorNormal` (`CalibrationVector3`), `lidarBoneLengthsM` (`[String: Double]`), `shoulderToWristDeltaZM`, `verticalFoVDeg`, and `intrinsics`.
2. **`CalibrationStep` Raw-Value & `Codable` Migration (Explicit Breaking-Change Flag):**
   - Today `CalibrationStep` (`CalibrationGate.swift:131-148`) has cases `resume = 0, level = 1, frame = 2, tpose = 4, locked = 5`, asserted in `CalibrationGateTests.swift:553` (`[0, 1, 2, 4, 5]`) and switched exhaustively in `CalibrationOverlayView.swift:222,327,346,355`.
   - In v2, `CalibrationStep` becomes:
     `resume = 0`, `level = 1`, `rest = 2` *(renamed from `frame = 2`, with `public static var frame: CalibrationStep { .rest }` compatibility alias)*, *(3 unused: parallel lighting advice)*, `tpose = 4`, `overhead = 5`, `asymLR = 6`, `armsForward = 7`, `plie = 8`, `turned45 = 9`, `stepLeft = 10`, `stepRight = 11`, `kneeLift = 12`, `locked = 13`.
   - **Impact, Transient Red App Build & Coupled Merge Rule (#7 + #8):** Repo-wide `git grep CalibrationStep` confirms `CalibrationStep` is **never persisted to disk** (`CalibrationProfile` v1 stores only `frames` and `gravity` in RAM). However, its `Codable` raw `Int`, `CalibrationTelemetry.step` (`"rest"` instead of `"frame"`) and `stepIndex` (`locked` = `13` instead of `5`), `CalibrationGateTests.swift:553` (`[0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]`), and `CalibrationOverlayView.swift:346,355` (`icon(for:)` and `stepLabel(_:)`, which switch exhaustively over `CalibrationStep` without `default:`) **all change**. Because Order #7 owns `CalibrationGate.swift` (gated on Linux `swift test`) while Order #8 owns `CalibrationOverlayView.swift` (gated on macOS `xcodebuild`), **the `GrooveApp` iOS build is intentionally broken between Waves 1C (#7) and 1D (#8) until #8 updates `CalibrationOverlayView.swift`; Orders #7 and #8 are a coupled pair that must merge to `main` together after #8's `ios-sideload-ipa.yml` gate passes** (§10).
3. **Shared `PoseHoldTracker` & `needsExposureLock`:**
   - Extract `PoseHoldTracker` in `CalibrationPoseScorers.swift` (Order #5) managing `(poseStart, poseLastGood, poseLatched, holdSamples, dropoutToleranceS)` so Poses 1–9 share one tested hold/dropout/framing-loss loop.
   - Add `needsExposureLock: Bool` on `CalibrationStatus` (flips `true` as Pose 1 `.rest` completes; resets to `false` on `.level` reset).
4. **Explicit Flat `CalibrationTelemetry` Fields (`CalibrationGateTests.swift:568-570`):**
   Every added field on `CalibrationTelemetry` is a flat optional/scalar (`String`, `Int`, `Double?`, `Bool`, `Bool?`)—no nested arrays or dicts—preserving `testTelemetryIsFlatJSON`:
   - Camera / LiDAR / AE: `cameraMode: String?`, `dancerDistanceM: Double?`, `effectiveMinDistanceM: Double?`, `cameraHeightM: Double?`, `measuredHeightM: Double?`, `lidarFloorTiltDeg: Double?`, `metricScaleFactor: Double?`, `exposureLocked: Bool?` (copied from `CalibrationLightSample.exposureLocked`).
   - Tier / Resume: `calibrationTier: Int?`, `resumedBody: Bool = false`.
   - All 9 Pose Pass Flags + L/R Swap Flag: `restOK: Bool?`, `tPoseOK: Bool?` *(existing)*, `overheadOK: Bool?`, `asymLROK: Bool?`, `lrSwapped: Bool?`, `armsForwardOK: Bool?`, `plieOK: Bool?`, `turned45OK: Bool?`, `stepLeftOK: Bool?`, `stepRightOK: Bool?`, `kneeLiftOK: Bool?`.
   Because `CalibrationController.finish()` (`CalibrationOverlayView.swift:170`) posts `DebugLink.shared.sendTelemetry(gate.telemetry(), kind: "calibration_end", ...)`, all of these fields appear automatically in both 2 Hz `telemetry-YYYYMMDD.jsonl` and `events-YYYYMMDD.jsonl` (`kind == "calibration_end"`).

### 7.2 New `CalibrationTuning` Keys & Defaults

All new keys in `CalibrationTuning.swift` decode via `c.decodeIfPresent(...) ?? fallback` (`CalibrationTuning.swift:269-271`) so partial `tools/debuglink/tuning.json` overrides work live at 2 s polling intervals:

| Key | Type | Default | Provenance | Purpose |
|---|---|---|---|---|
| `lidarMinDistanceM` | `Double` | `2.0` | Owner brief (`2–4 m`) | Baseline minimum LiDAR torso distance before FoV floor `d_geom_min` (§3.2). |
| `lidarMaxDistanceM` | `Double` | `4.0` | Owner brief + `report.md:48` (`5 m` max) | Maximum LiDAR torso distance. |
| `lidarDistanceStayDeltaM` | `Double` | `0.25` | *(inference)* | Hysteresis widening on distance once passing. |
| `lateralStepMarginM` | `Double` | `0.55` | *(inference: T-pose drift + Pose-8 `±0.12` step + safe inset)* | Lateral margin (m) added to `wingspanM` in portrait horizontal FoV floor `d_horiz_min` (§3.2). |
| `restHipCenterMinX` | `Double` | `0.40` | *(inference)* | Tighter Pose 1 (`.rest`) min `hipCenterX` in Tier-2 full calibration so T-pose/steps cannot clip. |
| `restHipCenterMaxX` | `Double` | `0.60` | *(inference)* | Tighter Pose 1 (`.rest`) max `hipCenterX` in Tier-2 full calibration. |
| `resumeFloorHeightDeltaM` | `Double` | `0.03` | *(inference; LiDAR static ~1 cm `report.md:47`)* | Max LiDAR camera-height change (m) allowed for Tier-0 resume. |
| `resumeFloorAngleDeg` | `Double` | `3.0` | *(inference)* | Max LiDAR floor-normal change (deg) allowed for Tier-0 resume. |
| `sameDancerHeightDeltaM` | `Double` | `0.06` | *(inference)* | Max LiDAR dancer-height delta (m) to reuse `body` in Tier-1. |
| `cameraHeightMinM` | `Double` | `0.50` | Dina `50–70 cm` (`2026-11-18:105`) | Low-camera non-blocking advisory threshold (m). |
| `cameraHeightMaxM` | `Double` | `1.50` | *(inference)* | High-camera non-blocking advisory threshold (m). |
| `exposureMaxShutterS` | `Double` | `0.0167` | *(inference: 1/60 s)* | Max locked shutter duration before custom ISO boost. |
| `remeterLumaDelta` | `Double` | `0.20` | *(inference)* | Between-take luma drift triggering AE/AWB re-meter. |
| `restHoldS` | `Double` | `0.6` | *(inference)* | Hold duration for Pose 1 (`.rest`). |
| `overheadHoldS` | `Double` | `0.7` | *(inference)* | Hold duration for Pose 3 (`.overhead`). |
| `overheadMinWristAboveNose` | `Double` | `0.05` | `GestureConfig.raisedMargin` (`GestureRecognizer.swift:88`) | Min `(nose.y - wrist.y) / span` for `.overhead`. |
| `overheadMinTopMarginY` | `Double` | `0.02` | *(inference; cf. Ashrium `0.01` at `2026-11-18:157`)* | Top-edge clipping guard for raised wrists (`y >= 0.02`). |
| `overheadMinElbowDeg` | `Double` | `135.0` | *(inference)* | Min interior elbow extension angle in `.overhead`. |
| `asymHoldS` | `Double` | `0.7` | *(inference)* | Hold duration for Pose 4 (`.asymLR`). |
| `asymMinSideReachShoulders` | `Double` | `0.80` | *(inference)* | Min horizontal right-wrist reach in shoulder widths in `.asymLR`. |
| `forwardHoldS` | `Double` | `0.7` | *(inference)* | Hold duration for Pose 5 (`.armsForward`). |
| `forwardMinDeltaZM` | `Double` | `0.25` | *(inference)* | Min canonical & LiDAR shoulder-to-wrist forward Z delta (m). |
| `plieHoldS` | `Double` | `0.8` | *(inference)* | Hold duration for Pose 6 (`.plie`). |
| `plieMinKneeFlexDeg` | `Double` | `22.0` | *(inference)* | Min exterior `mean_knee_flex` (deg) in `.plie`. |
| `plieMinHipDropNorm` | `Double` | `0.04` | *(inference)* | Min `hip_height_norm` drop below `.rest` in `.plie`. |
| `turnedHoldS` | `Double` | `0.7` | *(inference)* | Hold duration for Pose 7 (`.turned45`). |
| `turnedMinYawDeg` | `Double` | `25.0` | *(inference)* | Min 3D shoulder XZ yaw angle (deg) around target ~45° turn. |
| `turnedMaxYawDeg` | `Double` | `65.0` | *(inference)* | Max 3D shoulder XZ yaw angle (deg) before profile occlusion. |
| `turnedMinShoulderWidth2D` | `Double` | `0.045` | `checkup.ts:151` (exact) | Edge-on shoulder-collapse floor `|ls.x - rs.x|`. |
| `stepHoldS` | `Double` | `0.5` | *(inference)* | Hold duration per side (`.stepLeft`, `.stepRight`). |
| `stepMinHipShiftX` | `Double` | `0.12` | *(inference)* | Min normalized horizontal hip shift from `.rest` center. |
| `stepDropoutS` | `Double` | `0.40` | *(inference)* | Dropout tolerance during lateral step weight transfer. |
| `kneeLiftHoldS` | `Double` | `0.5` | *(inference)* | Hold duration for Pose 9 (`.kneeLift`). |
| `kneeLiftMinFlexDeg` | `Double` | `55.0` | *(inference)* | Min lifted-leg exterior `knee_flex` (deg). |
| `kneeLiftMinAnkleClearance` | `Double` | `0.18` | *(inference)* | Min `|la3D.y - ra3D.y| / legScale` in `.kneeLift`. |
| `kneeLiftMotionStayMax` | `Double` | `0.035` | *(inference)* | Relaxed stillness stay limit for single-leg balance. |
| `kneeLiftDropoutS` | `Double` | `0.45` | *(inference)* | Dropout tolerance for `.kneeLift`. |

---

## 8. How Scoring and Retargeting Consume `CalibrationProfileV2`

**Strict Swift ↔ Python Parity Rule:** `scripts/check_parity.py` (`scripts/check_parity.py:1-11,195-238`) enforces 1:1 numeric parity (`±0.02`) between `ios/GrooveCore` and `groove_eval/` across `golden_clips.json`, `feature_clips.json`, and `lesson_clips.json`. Therefore:
1. Add an optional `calibration_v2: LearnerCalibrationV2? = nil` field (type defined in `CalibrationProfileV2.swift` in Order #1) on `GrooveScoringEngine.PoseClip` (`ScoringEngine.swift:239-282`, Order #9) and `"calibration_v2"` dictionary key in `groove_eval/scoring.py` & `groove_eval/retarget.py` (Order #11).
2. When `calibration_v2` is `nil` (all existing golden/feature/lesson clips and skipped calibrations), scoring and retargeting execute **100% identically** to `aa5953e` so `fixtures/expected_scores_snapshot.json` has zero drift on existing clips.
3. When `calibration_v2` is present on a take, both `GrooveCore` (Order #9) and `groove_eval` (Order #11) apply the following deterministic rules **(inference)**:

### 8.1 Metric Scale & Calibrated Bone Lengths → `Retarget` (Opt-In Default Preserved) & `MoveSegmenter`
- **`retarget.enabled` Default Remains `false` (No Silent Reversal):** Since commit `6fff433`, `config/groove_config.json:84`, `ScoringEngine.swift:737`, and `groove_eval/scoring.py:100` (`DEFAULT_RETARGET = {"enabled": False}`) have defaulted bone-length retargeting to **off**, and `2026-10-31-course-platform-design.md:350-353` (§8 Q3) deliberately deferred turning it on by default because re-walking reference joints alters Cartesian positions and `leg_scale`-normalized `bodyNormalizedPose` verdicts (`Retarget.swift:11-12`). **This plan preserves `retarget.enabled == false` by default even when `attempt.calibration_v2 != nil`**, listing whether and when to enable it in lesson `config_overrides` as an explicit owner question (§11.2 Q5) and scoring risk (§11.3).
- **Bone-Length Priority When `retarget.enabled == true` (`Retarget.swift:83-92`, `groove_eval/retarget.py:72-82`):** Whenever `thresholds.retarget?.enabled == true` (via `groove_config.json` or lesson/segment `config_overrides`), `Retarget.learnerBoneLengths(attempt:)` reads `attempt.calibration_v2.boneLengthsM` **first** (incorporating LiDAR `metricScaleFactor` over the `>= 15` `.tpose` frames, swapped via `mirrorName` when `attempt.mirrored == true`), falling back to `calibration_frames` and then `attempt.frames`.
- **Metric Frame Scaling for Hit Velocities (`MoveSegmenter`):** Multiply learner canonical 3D joint positions `(x, y, z)` by `calibration_v2.metricScaleFactor` before `MoveSegmenter.detectHits` (`ScoringFeatures.swift:580-582`) and `measureClipLegScale` (`ScoringEngine.swift:1032`), putting 3D joint speeds (`m/s` vs `moving_threshold = 1.0`, `settle_threshold = 0.4`) in physical metres per second. (Ratio features like `hip_height_norm`, `ScoringEngine.swift:560-563`, cancel scale in numerator and denominator.)

### 8.2 Range-of-Motion (ROM) Limits → Groove & Posture Fairness
- **Plié Knee-Bounce Ceiling (`ScoringEngine.swift:910-917`):** Replace `refKneeRange` in `kneeFlexRatio = userKneeRange / refKneeRange` with `effectiveRefKneeRange = min(refKneeRange, max(15.0, rom.plieKneeFlexDeg - rom.standingKneeFlexDeg))` so limited-ROM dancers dancing full-out are not unfairly penalized, while stiff-kneed takes (`userKneeRange ≈ 4°` vs `28°` → `ratio = 0.14 < 0.65`) still fail `stiff_groove`.
- **Resting Trunk Lean Baseline (`ScoringEngine.swift:536-537,836`):** Subtract `clamp(rom.trunkLeanBaselineDeg - refRestTrunkLeanDeg, -5.0, 5.0)` when computing `hips` (`trunk_lean_deg`) shape error.
- **Overhead Tolerance Floor:** On beats where the reference's torso-frame upper-arm elevation exceeds `rom.maxShoulderElevationDeg`, widen `leftElbow`/`rightElbow`/`leftWrist`/`rightWrist` tolerances in `scoreJointFeedback` by `1.25×`.

### 8.3 Per-Joint Confidence Weights → Noise-Aware Tolerances & Shape Weights
Each canonical joint $j$ gets reliability weight $w_j = \operatorname{clamp}(\operatorname{p25Visibility}(j), 0.50, 1.00)$ across the unoccluded calibration holds:
1. **Joint Verdict Tolerance Widening (`ScoringFeatures.swift:716-724`):** Multiply beat tolerance `scale(name, velPos)` in `scoreJointFeedback` by `1.0 / w_j` (up to `2.0×` when $w_j = 0.50$).
2. **Shape Sub-Weight Re-Normalization (`ScoringEngine.swift:833-895`):** Multiply each `jointKeys` weight (`knees`, `spine`, `hips`, `left_foot`, `right_foot`, plus `armWeight` when `armsOn`) by the mean $w_j$ of its constituent joints and re-normalize to sum to `1.0`.

### 8.4 AirPlay Audio/Video Route Offset → Timing Alignment
`CoachingStageCoordinator` (Order #12) computes `effectiveAudioLatencyMs = metronome.outputLatencyMs + (profile.environment.airplayRouteOffsetsMs[currentRouteUID] ?? 0.0)`, which `PracticeViewModel` (`PracticeView.swift:186`, Order #13) and `LessonPlayerViewModel` (`LessonPlayerView.swift:913`, Order #14) pass into `PoseClip.audio_latency_ms`.

---

## 9. Verification Plan

### 9.1 Automated Unit & Parity Tests (`linux-ci`)

1. **`GrooveCore` Swift Tests (`swift test --package-path ios/GrooveCore`):**
   - `CalibrationProfileV2Tests.swift` (Order #1): JSON round-trip of `CalibrationProfileV2` & `LearnerCalibrationV2`, Tier-0 / Tier-1 / Tier-2 classification across synthetic `gravityDeltaG`, `cameraHeightM` delta, `dancerHeightM` mismatch (`> 0.06 m`), camera mode upgrades (`frontSelfView` → `rearLiDAR`), and 30-day expiry; partial `CalibrationTuning` JSON merge.
   - `GestureRecognizerTests.swift` (Order #2): `GestureSample.fromMediaPipeNormalized` `y`-flip test; **`testStartHoldRequiresLoweringHandsBeforeCountInCancel`** (verifying hands held overhead across `.idle` → `.countIn` never cancel the take until lowered below `headY` for `0.25 s` and raised again); **`testCountInDisablesClapsAndDoubleClap`** (on-beat claps 0.5 s apart never cancel `.countIn`); `.calibrating` `doubleClap` skip + zero false triggers across all 9 poses; `.disabled` mode silence; `.recording` `2.0 s` stationary hold vs `IMG_4941` choreography negative tests; `GestureRouter` phase matrix.
   - `CalibrationPoseScorersTests.swift` (Order #5): Stateless unit tests for all 9 pose evaluators, Tier-2 `.rest` `[0.40, 0.60]` centring + `.tpose` centring-vs-step-back cue disambiguation, `asymLR` swapped-side detection (`lrSwapped == true`), **`effectiveMinDistanceM` vertical + horizontal FoV width constraint (`(wingspanM + lateralStepMarginM) / (2·tan(θH/2))`)**, LiDAR `metricScaleFactor` median, wrist-to-wrist `wingspanM`, and p25 `jointConfidenceWeights`.
   - `CalibrationGateV2Tests.swift` (Order #7): Full synthetic trajectory `.level (1)` → Poses 1–9 (`2, 4...12`) → `.locked (13)`, rear-camera `tiltBackDeg` sign flip, `needsExposureLock` transition on Pose 1 `.rest` completion, Tier-0/1/2 resume paths, and `testTelemetryIsFlatJSON` covering all new flat telemetry keys.
   - `ScoringCalibrationV2Tests.swift` (Order #9): `boneLengthsM` priority when `retarget.enabled == true`, preservation of `retarget.enabled == false` default when `calibration_v2 != nil`, `metricScaleFactor` velocity scaling, `rom` plié cap, and `jointConfidenceWeights` scaling.
2. **Python ↔ Swift Exact Parity (`python3 -m unittest discover -s tests -v && python3 scripts/check_parity.py`):**
   - Edit existing `tests/test_debuglink_server.py` (Order #3), and in Order #11 add two `calibration_v2` cases in `groove_eval/generate_lesson_clips.py` (one with default `retarget.enabled = false` exercising ROM/confidence/metric hit scaling, and one with `config_overrides: {"scoring_thresholds": {"retarget": {"enabled": true}}}` exercising `boneLengthsM`), regenerate `fixtures/lesson_clips.json`, append only the two new entries to `fixtures/expected_scores_snapshot.json`, and run `tests/test_calibration_v2_parity.py` + `scripts/check_parity.py` verifying `0` byte drift on all existing snapshot entries and `< 0.02` diff between Python and `groove-score-cli`.

### 9.2 Debug Link External-Display Capture & Runtime Telemetry (`DebugLink.swift` + `ScreenStreamer.swift` + `server.py`, Order #3; Scene/Probe Events in Order #4)

Today `ScreenStreamer.tick()` (`ScreenStreamer.swift:51-53`) selects only `.first(where: { $0.activationState == .foregroundActive })`, missing any external AirPlay/TV `UIWindowScene`, `tools/debuglink/server.py:245` writes only `screen/latest.jpg`, and `DebugLink.swift` does not emit FPS, thermal state, or gesture events.

**Required Upgrades (Owned & Built by Order #3, Emitted/Wired by Orders #4, #6, #7, #8, #12, #13, #14):**
1. **`ScreenStreamer.swift` (Order #3):** Iterate over connected `UIWindowScene`s, capturing first the phone scene (`X-Screen-Role: phone`, native scale) and then any external display `UIWindowScene` (`scene.screen != UIScreen.main`, `X-Screen-Role: external`, downscaled `0.5×` e.g. `960×540` JPEG `q = 0.65` so LAN upload stays `< 90 KB/s`) sequentially inside one `inFlight` Task. Run `collectPreviews` (`ScreenStreamer.swift:120-135`) on the external window's layer tree so `CameraFrameStore` composites the live rear camera image into the TV's `AVCaptureVideoPreviewLayer` rect.
2. **`DebugLink.swift` (Order #3) & `ExternalDisplayManager.swift` (Order #4):**
   - In `DebugLink.swift` (Order #3): add `DebugLinkDevice.thermalStateString()` (`ProcessInfo.processInfo.thermalState` → `"nominal" | "fair" | "serious" | "critical"`), `recordPerfSample(liveFps: Double)` posting `kind: "perf_sample"` (`liveFps`, `thermalState`) to `events-YYYYMMDD.jsonl` every `5.0 s` while `PracticeCamera` is running (called from `PracticeCamera.analyze` in Order #6), and `recordGestureFired(command:mode:phase:action:)` posting `kind: "gesture_fired"` to `events-YYYYMMDD.jsonl` (called from `CoachingStageCoordinator` in Order #12). Stamp `thermalState` onto `take_end` and `calibration_end` events as well.
   - In `ExternalDisplayManager.swift` (Order #4, calling existing `DebugLink.shared.sendEvent(kind:fields:)` at `DebugLink.swift:532` with zero dependency on Order #3): emit `kind: "external_scene"` (`connected: Bool`, `screenBounds: String`, `scale: Double`, `audioRouteUID: String`, `audioPortTypes: [String]`, `outputLatencyMs: Double`) on scene connect/disconnect and audio route changes, and emit **`kind: "av_sync_probe"`** (`probeIndex: Int`, `scheduledFlashHostSeconds: Double`, `scheduledClickHostSeconds: Double`, `audioRouteUID: String`, `outputLatencyMs: Double`, `tvVideoLeadOffsetMs: Double`, `externalResolution: String`) on every scheduled beat-4 Flash+Click probe beat and whenever the measured `tvVideoLeadOffsetMs` is updated in the spike UI.
3. **`tools/debuglink/server.py` (Order #3):** Read `X-Screen-Role` (`"phone"` default vs `"external"`). Store external frames at `screen/latest-external.jpg` and `screen/external-YYYYMMDD-*.jpg` (capped at `KEEP_SCREENS`), add `latest_external_screen` + `external_fps` to `/status.json`, serve `GET /screen/latest-external.jpg`, and render `#scr-tv` alongside `#scr` in `LIVE_PAGE`.

### 9.3 On-Device Verification via Debug Link (`%LOCALAPPDATA%\groove-coach\debuglink\`)

Every field named below is built in Orders #3, #4, #6, #7, #8, #12, #13, and #14 (§7.1 & §9.2). **Important Gate 1 Visibility Note:** Because `TVCoachingStageView` (the 16:9 TV calibration mannequin + hold ring) is built in Phase 2 (**Order #10**) *after* Device Gate 1 validates the AirPlay external scene, **at Device Gate 1 the dancer stands 2–4 m in front of the rear camera (phone screen facing away) and completes the 9-pose calibration using `CalibrationVoice` spoken cues and chimes alone**, while the operator monitors `CalibrationOverlayView` on `screen/latest.jpg`, raw skeleton JPEGs on `frames/latest.jpg`, and live telemetry on the PC. Full visual + voice TV calibration is then verified at **Device Gate 2**.

| Check | Debug Link Artifact / Stream | Quantitative Pass Criterion |
|---|---|---|
| **External AirPlay scene & A/V sync spike (Gate 1)** | `screen/latest-external.jpg`, `events-YYYYMMDD.jsonl` (`kind == "external_scene"`, `kind == "av_sync_probe"` emitted by `ExternalDisplayManager`, Order #4) | External `UIWindowScene` attaches over AirPlay (`connected == true`); `latest-external.jpg` renders 16:9 landscape; `av_sync_probe` logs `scheduledFlashHostSeconds`, `scheduledClickHostSeconds`, `outputLatencyMs`, and measured `tvVideoLeadOffsetMs`. |
| **Rear camera & gravity signs (Gate 1)** | `frames/latest.jpg`, `telemetry-YYYYMMDD.jsonl` (`tiltBackDeg`, `lidarFloorTiltDeg`) | Portrait upright dancer; dancer's raised left hand at raw `x > 0.5`; tilting rear lens upward gives `tiltBackDeg > 0` and `lidarFloorTiltDeg < 3.0°`. |
| **LiDAR metric & horizontal-FoV distance calibration (Gate 1)** | `telemetry-YYYYMMDD.jsonl` (`dancerDistanceM`, `effectiveMinDistanceM`, `cameraHeightM`, `measuredHeightM`, `metricScaleFactor`) | At 2.7 m & 3.5 m tape-measured marks: `effectiveMinDistanceM` reflects `max(d_vert_min, d_horiz_min)` (`~2.65–2.80 m`), `|dancerDistanceM - tape| <= 0.05 m`, `|measuredHeightM - realHeight| <= 0.04 m`, `metricScaleFactor ∈ [0.85, 1.20]` with `< 0.03` spread across 3 runs. |
| **AE/AWB lock (Gate 1)** | `telemetry-YYYYMMDD.jsonl` (`exposureLocked`, `exposureSeconds`, `iso`) | `exposureLocked == true` from Pose 2 (`.tpose`, `stepIndex 4`) onward; `exposureSeconds <= 0.017` in normal indoor light; zero exposure pumping across Poses 2–9. |
| **9-pose sequence & profile save (Gate 1 voice-only; Gate 2 TV visual + voice)** | `events-YYYYMMDD.jsonl` (`kind == "calibration_end"`) | `step == "locked"`, `stepIndex == 13`, `skipped == false`, `capturedFrameCount >= 15`, `lrSwapped == false`, and all 10 pose/sub-pose booleans (`restOK`, `tPoseOK`, `overheadOK`, `asymLROK`, `armsForwardOK`, `plieOK`, `turned45OK`, `stepLeftOK`, `stepRightOK`, `kneeLiftOK`) `== true` (completed eyes-free via `CalibrationVoice` at Gate 1, and with `TVCoachingStageView` at Gate 2); relaunching app completes Tier-1 (`calibrationTier == 1`, `resumedBody == true`) in `< 6 s`. |
| **Dual-screen AirPlay coaching UI (Gate 2)** | `screen/latest.jpg` + `screen/latest-external.jpg` | `latest-external.jpg` shows 16:9 `TVCoachingStageView` with composited mirrored `TVCameraPreview` + skeleton; `latest.jpg` shows `#000000` `PhoneControllerStatusView`; `AVPlayer` renders inside left half of TV stage. |
| **Gesture routing & false-trigger immunity (Gate 2)** | `events-YYYYMMDD.jsonl` (`kind == "gesture_fired"`, `kind == "take_end"`) | Hands-up starts take without cancelling `.countIn`, on-beat claps in `.countIn` fire `0` gestures, `doubleClap` skips calibration, swipes navigate results; full `IMG_4941` take fires `0` gestures during `recording`; on-beat take achieves `|meanOffsetMs| <= 35 ms`. |
| **Thermal & FPS stability (Gates 1 & 2)** | `events-YYYYMMDD.jsonl` (`kind == "perf_sample"`: `liveFps`, `thermalState`) | `liveFps >= 20.0` during 5 consecutive takes with AirPlay active; `thermalState` stays `"nominal"` or `"fair"` (never `"serious"` or `"critical"`). |

---

## 10. Phased Build Orders (< 1 Hour Each, Globally Non-Overlapping `owns:`)

`ios/GrooveApp/project.yml:13-14` uses directory discovery (`sources: - Sources`) and `ios/GrooveCore/Package.swift` auto-discovers target sources, so new `.swift` files never contend on `project.yml` or `Package.swift`. Every file across all **14 core orders + 1 conditional Phase-3 order (#15)** (~35–45 min each) has **globally disjoint ownership** (`0` overlapping paths anywhere in the plan), every dependency points strictly to an earlier wave, **Orders #7 and #8 are explicitly marked to merge together** (since #7's `CalibrationStep` expansion breaks `CalibrationOverlayView.swift`'s exhaustive switches until #8 lands), and the **External-Display & AirPlay Spike (`#4`) runs immediately in Wave 1A** so **Device Measurement Gate 1** validates AirPlay scene behavior, A/V latency, rear camera, and LiDAR before Phase 2 builds the full TV UI.

```
PHASE 1 (Core, 9-Pose Gate, Rear Camera + LiDAR, Dual-Screen Debug Link & Early AirPlay Scene Spike)
  Wave 1A (parallel):  [#1 core-profile-tuning]  [#2 gestures-core]  [#3 debuglink-extscreen]  [#4 airplay-scene-spike]
  Wave 1B (parallel):  [#5 pose-scorers (←#1)]   [#6 rear-camera-lidar (←#1,#2,#3)]
  Wave 1C ──┐ coupled  [#7 gate-v2 (←#1,#5) — Linux swift test green; GrooveApp red until #8]
  Wave 1D ──┘ merge:   [#8 controller-voice-overlay (←#6,#7) — restores full Xcode IPA build; merge #7+#8 together]
                                                      │
                                                      ▼
         🛑 DEVICE MEASUREMENT GATE 1 (AirPlay Scene/Latency Spike + Rear Camera/LiDAR + Voice-Only 9-Pose Check)
                                                      │
PHASE 2 (Swift/Python Scoring Parity, 16:9 TV Stage Views, Shared Coordinator & Thin Practice/Lesson Wiring)
  Wave 2A (parallel):  [#9 scoring-swift (←#1, Gate 1)]           [#10 tv-stage-views (←#2,#4,#8, Gate 1)]
  Wave 2B (parallel):  [#11 scoring-python-parity (←#9)]          [#12 stage-coordinator (←#4,#6,#8,#10)]
  Wave 2C (parallel):  [#13 wire-practice (←#9,#12)]              [#14 wire-lesson-player (←#9,#12)]
                                                      │
                                                      ▼
         🛑 DEVICE MEASUREMENT GATE 2 (End-to-End Hands-Free AirPlay TV + Dance Sign-Off)
                                                      │
PHASE 3 (Conditional on Owner Decision §11.2 Q3 & Uncompensated TV DSP Lag > 35 ms at Gate 1/2)
  Wave 3A (optional):  [#15 clap-sync (←#4,#6,#8,#10, Gate 2, §11.2 Q3)]
```

### Phase 1 Orders

1. **`calib2-core-profile-tuning`** *(Wave 1A · depends on none · ~40 min · GrooveCore)*
   - **Work:** Define `CalibrationProfileV2` (`groove.calibration/2`, `CameraMode`, `environment`, `body` with wrist-to-wrist `wingspanM`, `rom`, `jointConfidenceWeights`, `.legacyProfile` bridge, `LearnerCalibrationV2` + `.asScoringCalibration`, and Tier-0/1/2 classifier), `CalibrationDepthSample`, `CalibrationIntrinsics`, and add all §7.2 keys/defaults (`lateralStepMarginM`, `restHipCenterMinX/MaxX`, etc.) + partial JSON decoding to `CalibrationTuning`.
   - **`owns:`** `ios/GrooveCore/Sources/GrooveCore/CalibrationProfileV2.swift` *(new)*, `ios/GrooveCore/Sources/GrooveCore/CalibrationTuning.swift`, `ios/GrooveCore/Tests/GrooveCoreTests/CalibrationProfileV2Tests.swift` *(new)*
   - **`test:`** `swift test --package-path ios/GrooveCore --filter CalibrationProfileV2Tests`
   - **`check:`** `testProfileV2RoundTrip` `testThreeTierResumeClassifier` `testNewTuningKeysPartialDecode`

2. **`calib2-gestures-core`** *(Wave 1A · depends on none · ~40 min · GrooveCore)*
   - **Work:** Add `GestureSample.fromMediaPipeNormalized` (`1.0 - y` fix), `holdProgress` (`0...1`), `resetPreservingHoldLatch()` lower-hands `0.25 s` re-arm gate, `GestureMode` (`.betweenTakes`, `.calibrating` with single-clap repeat + `doubleClap` skip, `.countIn` with claps/swipes disabled and `1.2 s` stationary hold after re-arm, `.recording` with `2.0 s` stationary hold after re-arm, `.disabled`), and pure `GestureRouter`.
   - **`owns:`** `ios/GrooveCore/Sources/GrooveCore/GestureRecognizer.swift`, `ios/GrooveCore/Sources/GrooveCore/GestureRouter.swift` *(new)*, `ios/GrooveCore/Tests/GrooveCoreTests/GestureRecognizerTests.swift`
   - **`test:`** `swift test --package-path ios/GrooveCore --filter GestureRecognizerTests`
   - **`check:`** `testMediaPipeYFlipFixesRaisedHands` `testStartHoldRequiresLoweringHandsBeforeCountInCancel` `testCountInDisablesClapsAndDoubleClap` `testCalibrationDoubleClapSkipsAndPosesNeverTrigger` `testRecordingStationaryHoldIgnoresChoreography`

3. **`calib2-debuglink-extscreen`** *(Wave 1A · depends on none · ~45 min · GrooveApp + Python Debug Link)*
   - **Work:** Upgrade `ScreenStreamer` to capture both phone (`X-Screen-Role: phone`) and external `UIWindowScene`s (`X-Screen-Role: external`, `0.5×` scale, compositing `CameraFrameStore` into external `AVCaptureVideoPreviewLayer`s) sequentially under one `inFlight` Task; add `DebugLinkDevice.thermalStateString()`, `recordPerfSample(liveFps:)` (`kind: "perf_sample"`), and `recordGestureFired(...)` (`kind: "gesture_fired"`) to `DebugLink.swift`; update `tools/debuglink/server.py` + `README.md` and edit existing `tests/test_debuglink_server.py` for `screen/latest-external.jpg` and `/status.json` `external_fps`.
   - **`owns:`** `ios/GrooveApp/Sources/DebugLink.swift`, `ios/GrooveApp/Sources/ScreenStreamer.swift`, `tools/debuglink/server.py`, `tools/debuglink/README.md`, `tests/test_debuglink_server.py`
   - **`test:`** `python -m unittest tests.test_debuglink_server -v`
   - **`check:`** `test_external_screen_role_stored_separately` `test_phone_screen_default_role_preserved`

4. **`calib2-airplay-scene-spike`** *(Wave 1A · depends on none · ~45 min · GrooveApp)*
   - **Work:** Verify external `UIWindowScene` manifest/delegate APIs, `AVCaptureConnection` preview mirroring properties, and `AVAudioSession` route notifications against local Xcode headers (§11.1); configure external display scene support in `project.yml` + `PoseExporterApp.swift`; build `ExternalDisplayManager`:
     - Emits `DebugLink.shared.sendEvent(kind: "external_scene", fields: ...)` (`connected`, `screenBounds`, `scale`, `audioRouteUID`, `audioPortTypes`, `outputLatencyMs`) on scene connect/disconnect and route changes.
     - Hosts a pluggable `@Published var stageBuilder` defaulting to a 16:9 **AirPlay Spike & Host-Clock Flash+Click Sync Probe** (including a minimal inline `AVCaptureVideoPreviewLayer` rear-mirroring check for Gate 1) that emits **`DebugLink.shared.sendEvent(kind: "av_sync_probe", fields: ...)`** (`probeIndex`, `scheduledFlashHostSeconds`, `scheduledClickHostSeconds`, `audioRouteUID`, `outputLatencyMs`, `tvVideoLeadOffsetMs`, `externalResolution`) on each beat-4 flash+click probe trigger and offset commit.
     - Exposes `onRecalibrateStudioRequested` and an optional `clapSyncAction: (() -> Void)? = nil` slot (hidden in UI until Phase-3 Order #15 registers it) wired into `CalibrationOnboardingView` in `PoseExporterApp.swift`.
   - **`owns:`** `ios/GrooveApp/project.yml`, `ios/GrooveApp/Sources/PoseExporterApp.swift`, `ios/GrooveApp/Sources/ExternalDisplayManager.swift` *(new)*
   - **Gate:** macOS `xcodegen generate && xcodebuild`

5. **`calib2-pose-scorers`** *(Wave 1B · depends on #1 · ~40 min · GrooveCore)*
   - **Work:** Implement stateless evaluators in `CalibrationPoseScorers` for all 9 poses (`.rest` with Tier-2 `[restHipCenterMinX, restHipCenterMaxX] = [0.40, 0.60]` centring, `.tpose` delegation + centring-vs-step-back cue disambiguation, `.overhead`, `.asymLR` + `lrSwapped` detector, `.armsForward`, `.plie`, `.turned45`, `.stepLeft`/`.stepRight`, `.kneeLift`), `PoseHoldTracker`, **`effectiveMinDistanceM(hCam:dancerHeightM:wingspanM:verticalFoVDeg:horizontalFoVDeg:tuning:)`** enforcing **both** vertical FoV (`d_vert_min`) **and** portrait horizontal FoV width (`d_horiz_min = (wingspanM + lateralStepMarginM)/(2·tan(θH/2))`), LiDAR `metricScaleFactor` median calculator, wrist-to-wrist `wingspanM` from `boneLengthsM`, ROM summary builder, and p25 `jointConfidenceWeights` aggregator.
   - **`owns:`** `ios/GrooveCore/Sources/GrooveCore/CalibrationPoseScorers.swift` *(new)*, `ios/GrooveCore/Tests/GrooveCoreTests/CalibrationPoseScorersTests.swift` *(new)*
   - **`test:`** `swift test --package-path ios/GrooveCore --filter CalibrationPoseScorersTests`
   - **`check:`** `testAllNinePoseEvaluators` `testAsymLRDetectsSwappedSides` `testEffectiveMinDistanceEnforcesHorizontalFoVWidth` `testMetricScaleAndConfidenceWeights`

6. **`calib2-rear-camera-lidar`** *(Wave 1B · depends on #1, #2, #3 · ~45 min · GrooveApp)*
   - **Work:** Add `CameraMode` (`.rearLiDAR`, `.rearWide`, `.frontSelfView`) to `PracticeCamera` (30 fps cap, explicitly un-mirrored `AVCaptureVideoDataOutput`, `AVCaptureDepthDataOutput` throttled to 5–10 Hz in `.calibrating`, 1 Hz in `.idle`, `0 Hz` during `.countIn`/`.recording`/`.analyzing`, video intrinsics delivery, `videoFieldOfView` + portrait `horizontalFoVDeg`, rolling `liveFps` reported every 5 s to `DebugLink.shared.recordPerfSample`), wire `GestureSample.fromMediaPipeNormalized` + `GestureMode`, and add camera-frame gravity conversion, gravity-guided RANSAC floor plane, canonical 3D back-projection, and AE/AWB lock/unlock + re-meter helpers (`CalibrationLightSample.exposureLocked`) to `CalibrationSensors`.
   - **`owns:`** `ios/GrooveApp/Sources/PracticeCamera.swift`, `ios/GrooveApp/Sources/CalibrationSensors.swift`
   - **Gate:** macOS `xcodebuild` + symbol check (`nm -u` confirms `VNDetectHuman(Body|Hand)Pose` absent)

7. **`calib2-gate-v2`** *(Wave 1C · depends on #1, #5 · ~45 min · GrooveCore · **Coupled Merge with #8**)*
   - **Work:** Wire `CalibrationGate` to `CalibrationPoseScorers` + `PoseHoldTracker`, add `CameraMode`-aware `angles(gravity:cameraMode:)`, add `update(depth: CalibrationDepthSample)`, migrate `CalibrationStep` (`[0, 1, 2, 4...13]` with `.frame` alias), implement Tier-0/1/2 transitions producing `lockedProfileV2` + `needsExposureLock`, and add all §7.1 flat v2 `CalibrationTelemetry` fields (`cameraMode`, `dancerDistanceM`, `effectiveMinDistanceM`, `cameraHeightM`, `measuredHeightM`, `lidarFloorTiltDeg`, `metricScaleFactor`, `exposureLocked`, `calibrationTier`, `resumedBody`, `lrSwapped`, and all 10 pose/sub-pose `*OK` booleans).
   - **Build Note:** `GrooveCore` (`swift test`) passes green in isolation, whereas `GrooveApp` (`xcodebuild`) is intentionally red on `CalibrationOverlayView.swift:346,355`'s exhaustive `CalibrationStep` switches until Order #8 lands in Wave 1D; **merge #7 and #8 together**.
   - **`owns:`** `ios/GrooveCore/Sources/GrooveCore/CalibrationGate.swift`, `ios/GrooveCore/Tests/GrooveCoreTests/CalibrationGateTests.swift`, `ios/GrooveCore/Tests/GrooveCoreTests/CalibrationGateV2Tests.swift` *(new)*
   - **`test:`** `swift test --package-path ios/GrooveCore --filter CalibrationGate`
   - **`check:`** `testFullNinePoseSequenceLocksProfileV2` `testRearCameraTiltSignFlip` `testTier0AndTier1ResumeRules` `testTelemetryIsFlatJSON`

8. **`calib2-controller-voice-overlay`** *(Wave 1D · depends on #6, #7 · ~45 min · GrooveApp · **Coupled Merge with #7**)*
   - **Work:** Add `CalibrationProfileStore` (`Application Support/Calibration/calibration_profile_v2.json`), update `CalibrationController` to persist `CalibrationProfileV2`, feed `CalibrationDepthSample` + `exposureLocked`, lock/unlock AE/AWB on `needsExposureLock`, update `CalibrationOverlayView` exhaustive `CalibrationStep` switches (`CalibrationOverlayView.swift:346,355`) with 9-pose target silhouettes + progress dots + dynamic `effectiveMinDistanceM` cues, and add v2 spoken cues + per-step completion chimes + gesture earcons to `CalibrationVoice`.
   - **`owns:`** `ios/GrooveApp/Sources/CalibrationOverlayView.swift`, `ios/GrooveApp/Sources/CalibrationVoice.swift`, `ios/GrooveApp/Sources/CalibrationProfileStore.swift` *(new)*
   - **Gate:** Full macOS `ios-sideload-ipa.yml` build (`xcodegen generate && xcodebuild`) with #7 + #8 merged together

### 🛑 Mandatory Device Measurement Gate 1 (Before Phase 2)
Deploy the Phase-1 IPA (`#1..#8`) to `iPhone18,2` (iOS 26.6.1) AirPlaying to the owner's TV with Debug Link live and measure:
1. **External-Display & AirPlay Sync Spike:** Confirm external `UIWindowScene` renders 16:9 on the TV (`kind == "external_scene"`), `screen/latest-external.jpg` streams cleanly alongside AirPlay without Wi-Fi drops, `AVPlayer.allowsExternalPlayback = false` prevents full-screen hijack, and record `AVAudioSession.outputLatency` + Flash+Click visual-vs-audio delta (`tvVideoLeadOffsetMs`) emitted in `kind == "av_sync_probe"` events on the owner's TV.
2. **Rear Camera, Mirroring, Gravity & Intrinsics:** Confirm portrait upright rear buffers (`leftShoulder.x > 0.5` in `frames/latest.jpg`), `.back` `AVCaptureVideoPreviewLayer` mirroring on the spike external scene, `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` axis order under `videoRotationAngle = 90`, and rear `tiltBackDeg = atan2(+g.z, -g.y) > 0` agreeing with LiDAR floor normal (`lidarFloorTiltDeg < 3.0°`).
3. **LiDAR Accuracy, Voice-Only 9-Pose Thresholds & Thermal/FPS:** Verify `effectiveMinDistanceM` (`d_horiz_min` width constraint), `dancerDistanceM` (`±0.05 m`), and `measuredHeightM` (`±0.04 m`) at 2.0 m, 3.0 m, and 4.0 m marks, `liveFps >= 20` and `thermalState` in `perf_sample` events. **Note:** Because `TVCoachingStageView` is not built until Order #10 in Phase 2 and the phone screen faces away from the dancer when using the rear camera, **the dancer runs Poses 1–9 at Gate 1 using `CalibrationVoice` spoken instructions and chimes alone** (verifying eyes-free voice clarity while the operator inspects `CalibrationOverlayView` via `screen/latest.jpg`), folding any live `tuning.json` adjustments into `CalibrationTuning.defaults`.

### Phase 2 Orders

9. **`calib2-scoring-swift`** *(Wave 2A · depends on #1 and Device Gate 1 · ~35 min · GrooveCore)*
   - **Work:** Add optional `calibration_v2: LearnerCalibrationV2? = nil` to `GrooveScoringEngine.PoseClip` (`ScoringEngine.swift:239-282`); update `Retarget.learnerBoneLengths` (`Retarget.swift:83-92`) to prefer `calibration_v2.boneLengthsM` **only when `retarget.enabled == true`** (preserving `retarget.enabled == false` default per §8.1); implement `metricScaleFactor` velocity scaling in `ScoringFeatures.scoreHitTiming`, `rom` plié cap + posture baseline + overhead tolerance floor, and `jointConfidenceWeights` verdict/shape scaling in `ScoringEngine.swift` & `ScoringFeatures.swift`, covered by `ScoringCalibrationV2Tests.swift` (zero change when `calibration_v2 == nil`).
   - **`owns:`** `ios/GrooveCore/Sources/GrooveCore/Retarget.swift`, `ios/GrooveCore/Sources/GrooveCore/ScoringEngine.swift`, `ios/GrooveCore/Sources/GrooveCore/ScoringFeatures.swift`, `ios/GrooveCore/Tests/GrooveCoreTests/ScoringCalibrationV2Tests.swift` *(new)*
   - **`test:`** `swift test --package-path ios/GrooveCore --filter ScoringCalibrationV2Tests`
   - **`check:`** `testCalibrationV2BoneLengthsPriorityWhenRetargetEnabled` `testCalibrationV2PreservesRetargetDisabledDefault` `testCalibrationV2RomAndConfidenceScaling`

10. **`calib2-tv-stage-views`** *(Wave 2A · depends on #2, #4, #8 and Device Gate 1 · ~45 min · GrooveApp)*
    - **Work:** Build production 16:9 landscape `TVCoachingStageView`—including its own dedicated **`TVCameraPreview`** (`AVCaptureVideoPreviewLayer` with `videoRotationAngle = 90`, `automaticallyAdjustsVideoMirroring = false`, `isVideoMirrored = true`, avoiding any dependency on `PracticeView.swift`), Calibration 40/60 pose mannequin + mirrored preview + 160 pt hold ring, Lesson/Practice 50/50 split stage with `LiveMatcher` overlay + 96 pt count-in + beat bar + gesture hold ring, and Results 10-foot scorecard—plus minimal `#000000` `PhoneControllerStatusView` and TV-scaled `GestureToast` / hold ring in `FeedbackViews.swift`.
    - **`owns:`** `ios/GrooveApp/Sources/TVCoachingStageView.swift` *(new)*, `ios/GrooveApp/Sources/PhoneControllerStatusView.swift` *(new)*, `ios/GrooveApp/Sources/FeedbackViews.swift`
    - **Gate:** macOS `xcodebuild`

11. **`calib2-scoring-python-parity`** *(Wave 2B · depends on #9 · ~35 min · Python `groove_eval` + Fixtures)*
    - **Work:** Mirror `calibration_v2` consumption in `groove_eval/retarget.py` (`boneLengthsM` priority when `retarget.enabled` is true; `DEFAULT_RETARGET = {"enabled": False}` preserved) and `groove_eval/scoring.py` (`metricScaleFactor` hit scaling, `rom` adjustments, `jointConfidenceWeights`); add two `calibration_v2` cases to `groove_eval/generate_lesson_clips.py`, regenerate `fixtures/lesson_clips.json`, append only the two new entries to `fixtures/expected_scores_snapshot.json` (zero byte drift on all existing snapshot entries), and verify 1:1 Swift ↔ Python parity (`±0.02`) via `tests/test_calibration_v2_parity.py` and `scripts/check_parity.py`.
    - **`owns:`** `groove_eval/retarget.py`, `groove_eval/scoring.py`, `groove_eval/generate_lesson_clips.py`, `fixtures/lesson_clips.json`, `fixtures/expected_scores_snapshot.json`, `tests/test_calibration_v2_parity.py` *(new)*
    - **`test:`** `python -m unittest tests.test_calibration_v2_parity -v && python scripts/check_parity.py`
    - **`check:`** `Python vs. canonical snapshot parity` `lesson_clips.json`

12. **`calib2-stage-coordinator`** *(Wave 2B · depends on #4, #6, #8, #10 · ~35 min · GrooveApp)*
    - **Work:** Build shared `@MainActor final class CoachingStageCoordinator` encapsulating external-display observation (`ExternalDisplayManager.shared.stageBuilder` mounting `TVCoachingStageView`), AirPlay-drop detection + spoken `CalibrationVoice` disconnect notice + `onAirPlayDropped` callback, automatic `CameraMode` switching (`rearLiDAR` with TV, `frontSelfView` fallback + manual override), `GestureRouter` binding on `camera.onGesture` with `resetPreservingHoldLatch()` + `1.0 s` post-take grace cooldown + `DebugLink.shared.recordGestureFired`, and `CalibrationProfileStore` helpers (`activeProfileV2`, `effectiveAudioLatencyMs(baseOutputLatencyMs:)`, `tvVideoLeadOffsetSeconds`).
    - **`owns:`** `ios/GrooveApp/Sources/CoachingStageCoordinator.swift` *(new)*
    - **Gate:** macOS `xcodebuild`

13. **`calib2-wire-practice`** *(Wave 2C · depends on #9, #12 · ~35 min · GrooveApp)*
    - **Work:** Wire `PracticeViewModel` & `PracticeView` to `CoachingStageCoordinator` and `PhoneControllerStatusView`, map `CoachingCommand`s (`startTake`, `abortTake(to: .paused)`, `nextMove`), pass `calibration_v2` + `effectiveAudioLatencyMs` into `buildTake`, and update phone-side `CameraPreview` (`PracticeView.swift:487-508`) with `var mirrored: Bool = true` (`automaticallyAdjustsVideoMirroring = false`, `isVideoMirrored = mirrored` when supported) so manual rear-camera phone preview mirrors cleanly without changing `LessonPlayerView.swift:108`'s call site.
    - **`owns:`** `ios/GrooveApp/Sources/PracticeView.swift`
    - **Gate:** macOS `xcodebuild`

14. **`calib2-wire-lesson-player`** *(Wave 2C · depends on #9, #12 · ~40 min · GrooveApp)*
    - **Work:** Wire `LessonPlayerViewModel` & `LessonPlayerView` to `CoachingStageCoordinator` and `PhoneControllerStatusView`: set `player.allowsExternalPlayback = false` in `setupPlayer()` (`LessonPlayerView.swift:1080-1091`), apply `coordinator.tvVideoLeadOffsetSeconds` to `videoMachTime` (`LessonPlayerView.swift:769`), map `CoachingCommand`s (fixing missing lesson gestures), add `.paused` to `LessonPlayerViewModel.Phase` (`LessonPlayerView.swift:470-472`) so `coordinator.onAirPlayDropped` aborts without calling `recordTake(passed: false, ...)` (`LessonPlayerView.swift:985`), and pass `calibration_v2` + `effectiveAudioLatencyMs` into `takePoseClip` (`LessonPlayerView.swift:906-917`).
    - **`owns:`** `ios/GrooveApp/Sources/LessonPlayerView.swift`
    - **Gate:** Full macOS `ios-sideload-ipa.yml` IPA verification

### 🛑 Mandatory Device Measurement Gate 2 (Core End-to-End Sign-Off)
Run end-to-end on `iPhone18,2` AirPlaying to the owner's TV with Debug Link active: verify `screen/latest-external.jpg` (`TVCoachingStageView` + `TVCameraPreview`), complete the full 9-pose hands-free calibration from ~3 m watching the TV stage, verify hands-up Start Take does not self-cancel `.countIn` and on-beat count-in claps do not cancel `.countIn`, dance a full `IMG_4941` segment + `full_run` verifying `0` false gesture triggers in `recording` and `|meanOffsetMs| <= 35 ms`, and disconnect AirPlay mid-take to confirm pause without speed-ladder demotion.

### Phase 3 Order (Conditional on Owner Decision §11.2 Q3)

15. **`calib2-clap-sync`** *(Wave 3A · depends on #4, #6, #8, #10, Gate 2, and Owner Decision §11.2 Q3 · ~40 min · GrooveApp)*
    - **Work:** If Device Gate 1/2 measures `> 35 ms` uncompensated downstream TV/soundbar DSP delay or the owner opts into in-app clap calibration (§11.2 Q3), build standalone `ClapSyncController` + 3-clap sync sheet (`"1, 2, 3, CLAP!"` × 3 bars with `GestureMode.disabled`, `Metronome`, and `GrooveScoringEngine.verifyClapSync` median + `60 ms` spread filter + `±35 ms` deadband per §4.2 item 4, saving `airplayRouteOffsetsMs[routeUID]` via `CalibrationProfileStore` and posting `kind: "clap_sync"` via `DebugLink`) and register `ExternalDisplayManager.shared.clapSyncAction` so the `"Sync TV Audio"` action activates in `CalibrationOnboardingView` and `PhoneControllerStatusView` without editing `LessonPlayerView.swift` or `PracticeView.swift`.
    - **`owns:`** `ios/GrooveApp/Sources/ClapSyncController.swift` *(new)*, `ios/GrooveApp/Sources/Metronome.swift`
    - **Gate:** macOS `xcodebuild` + on-device 3-clap sync verification via Debug Link (`events-YYYYMMDD.jsonl` `kind == "clap_sync"`)

---

## 11. Risks and Open Questions

### 11.1 Unopened Apple SDK & Hardware Facts (Verify in Local Xcode Headers & Device Gate 1 — Do Not Guess)

Because web browsing was restricted to the two research reports plus `Chuyuyan/dance-trainer`, the following pages were **not** opened and must be verified against Xcode's local Swift interfaces and measured on `iPhone18,2` in Phase 1 (Orders #4, #6 + Device Gate 1):
1. **External-Display `UIWindowScene` & Lifecycle Notifications (Order #4):** Exact `UIApplicationSceneManifest` / `UISceneConfiguration` external display role names (`UIWindowSceneSessionRoleExternalDisplayNonInteractive` vs `UIWindowSceneSessionRoleExternalDisplay`), SwiftUI vs `UISceneDelegate` window attachment on iOS 26, and `UIScene.willConnectNotification` / `UIScene.didDisconnectNotification` behavior when AirPlay Screen Mirroring connects and disconnects.
2. **AirPlay Audio/Video Latency, Frame Pacing & `AVPlayer.allowsExternalPlayback` (Order #4 + Device Gate 1):** (a) What `AVAudioSession.sharedInstance().outputLatency` reports during AirPlay 2 mirroring to the owner's TV, (b) actual visual display lag $\Delta_{\text{tv\_video}}$ of an external `UIWindowScene` over AirPlay vs audio arrival $\Delta_{\text{audio}}$ (whether iOS paces them together or requires non-zero `tvVideoLeadOffsetMs`), (c) `AVAudioSession.routeChangeNotification` / `AVAudioSessionPortDescription.uid` behavior on AirPlay drop, and (d) confirming `player.allowsExternalPlayback = false` keeps `AVPlayer` inside the composite TV scene.
3. **`AVCaptureDepthDataOutput` & LiDAR Device Selection (Order #6):** `report.md` opened `AVCameraCalibrationData`, `ARFrame.sceneDepth`, and `VNDetectHumanBodyPose3DRequest`, not `AVCaptureDepthDataOutput` or `builtInLiDARDepthCamera`. Verify exact `AVCaptureDevice.DeviceType` query for rear LiDAR + wide video at `1280×720` @ 30 fps, `AVDepthData` float32 conversion API, and whether `ARSession` could ever share buffers with `AVCaptureSession` (not needed by Pipeline C).
4. **Rear-Camera Preview Mirroring & Intrinsics Rotation (Orders #4, #6 + Device Gate 1):** Verify `AVCaptureConnection.automaticallyAdjustsVideoMirroring` and `isVideoMirrored` on `.back` for both `AVCaptureVideoDataOutput` (must be un-mirrored in Order #6) and `AVCaptureVideoPreviewLayer` (must be mirrored in Order #4's spike, Order #10's `TVCameraPreview`, and Order #13's `CameraPreview`), plus whether `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` and `AVDepthData.cameraCalibrationData.intrinsicMatrix` require $(f_x, c_x) \leftrightarrow (f_y, c_y)$ swap under `videoRotationAngle = 90`.
5. **Exposure Slew Readiness Properties (Order #6):** `report.md:105-115` verified `ExposureMode.locked`, `setExposureModeCustom`, `WhiteBalanceMode.locked`, and `setWhiteBalanceModeLocked`, not `isAdjustingExposure` / `isAdjustingWhiteBalance`. Check `AVCaptureDevice` headers before locking AE/AWB.

### 11.2 Product & Setup Questions for the Owner

1. **TV Connection Setup (Wireless AirPlay Receiver vs Wired Cable):** What TV or receiver will you use for coaching (Apple TV 4K vs built-in Smart TV AirPlay 2), and do you also plan to use a wired USB-C → HDMI adapter (whose hardware support and latency on `iPhone18,2` were not opened in the research reports and would be measured alongside AirPlay in Device Gate 1)?
2. **Re-Calibration Cadence (§6.2):** Does the 3-tier cadence (**~28 s** Full 9-Pose once per dancer / 30 days, **~4–6 s** Level + LiDAR Distance/Height check when the phone moves, **<1 s** framing check between takes) match your preference, or should Practice/Lesson UI include a toggle to run the full 9-pose warm-up before every session?
3. **3-Clap TV Audio Sync Check (§4.2, Conditional Phase-3 Order #15):** Should we build **Order #15 (`calib2-clap-sync`)** as an **opt-in "Sync TV Audio"** utility (needed only if Device Gate 1/2 finds `AVAudioSession.outputLatency` misses downstream TV/soundbar DSP delay by `> 35 ms`), auto-run it once per new TV route, or skip Order #15 if Gate 1's Flash+Click probe shows AirPlay audio/video sync is already within `±35 ms`?
4. **Mid-Take Escape Hatch (§5.2):** Segments are short (`1.6–14.4 s`). Do you prefer the **`2.0 s` stationary hands-up hold** (after lowering hands) to pause mid-take, or **zero gestures active during `.recording`** for zero mid-dance false-trigger surface?
5. **Enabling Bone-Length Retargeting (`retarget.enabled`) on Calibrated Takes (§8.1):** `retarget.enabled` has defaulted to `false` since `6fff433` (`config/groove_config.json:84`, `ScoringEngine.swift:737`) and was deferred in `2026-10-31-course-platform-design.md:350-353` (§8 Q3). This plan preserves `retarget.enabled = false` by default and feeds LiDAR-calibrated `boneLengthsM` into `Retarget.learnerBoneLengths` only when `retarget.enabled` is opted in via `config_overrides`. Should `retarget.enabled` remain off until V4 multi-dancer `tune_report.py` validation, or be enabled via `config_overrides` in published lesson v2 once Device Gate 2 verifies `boneLengthsM`?

### 11.3 Technical Risks & Mitigations

- **Score & Joint-Verdict Shift if `retarget.enabled` Is Flipped Without Tolerance Re-Tuning:** Re-walking the teacher reference onto `calibration_v2.boneLengthsM` alters 3D joint positions and `leg_scale`-normalized `bodyNormalizedPose` coordinates (`Retarget.swift:11-12`), shifting per-joint position errors against single-take floor tolerances (`position_floor = 0.06 m`, `2026-10-31-course-platform-design.md:247`) on every calibrated take if auto-enabled globally. *Mitigation:* Keep `retarget.enabled = false` as the engine default (§8.1), validate `boneLengthsM` retargeting under explicit `config_overrides` in `lesson_clips.json` (Order #11), and gate enabling it in lessons on owner approval (§11.2 Q5) and V4 `tune_report.py` pass-rate comparison.
- **AirPlay + Debug Link Wi-Fi Contention:** Wireless AirPlay streams TV video from the iPhone while `ScreenStreamer` uploads JPEGs over the same Wi-Fi radio. *Mitigation:* Measure early in **Device Gate 1**; cap external-display Debug Link uploads at `0.5×` resolution (`960×540`, JPEG `q = 0.65`, `< 90 KB/s` at 1 fps) inside a single `inFlight` loop (`ScreenStreamer.swift:49`).
- **`AVPlayerLayer` Black Box in Debug Link Screen Captures:** As documented in `ScreenStreamer.swift:17`, `UIWindow.drawHierarchy` renders `AVPlayerLayer` black. On `screen/latest-external.jpg`, the right 50% (composited rear camera + skeleton) and all SwiftUI HUDs/rings/scorecards render in full color while the left 50% teacher video rect appears black unless an optional 1 Hz `AVPlayerItemVideoOutput` compositor is added later.
- **Background Studio Mirrors Facing the TV:** Placing the phone in front of the TV keeps the TV behind the camera, which avoids backlighting (`2026-11-18-calibration-research.md:73,200`); however, if the dancer stands in front of a wall mirror *behind* them, the rear camera can see the TV's teacher video reflected in the mirror (`num_poses = 1`, `2026-10-31-course-platform-design.md:49`)—and optical pose estimators can be confused by mirror reflections (`2026-11-18-calibration-research.md:73,200`; how iPhone LiDAR depth behaves on studio mirrors was not opened in either report and should be checked on-device if a mirror is present). *Mitigation:* Retain Dina's `sceneTips` warning (`CalibrationGate.swift:198`: *"Avoid mirrors..."*) and warn specifically against standing with a mirror directly behind the dancer facing the TV.
