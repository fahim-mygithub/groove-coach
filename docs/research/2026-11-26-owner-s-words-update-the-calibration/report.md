# Groove Coach Calibration Research Report

## Answer

**As of:** 2026-11-26 | **Confidence:** Medium-High

For Groove Coach (SwiftUI iOS 17+ dance-coaching app using MediaPipe 33-landmark pose + Apple Vision 3D on the front wide camera, tested on `iPhone18,2` / iOS 26 at 2–4 m dancing distance):

1. **Depth & Camera Choice (r1):** Keep the **front wide camera with no depth sensor — MediaPipe + Vision 3D (`VNDetectHumanBodyPose3DRequest`) only** (weighted score **4.08 / 5.0**). It preserves live self-view UX, avoids front TrueDepth's <1 m range limit and rear-camera switching, and leverages Vision 3D's metric 3D joint positions. Runner-up: **depth only for metric scale and floor plane** (**4.00 / 5.0**), which wins if cm-level floor-plane calibration is required and the user accepts a one-time rear-camera LiDAR scan before flipping to the front camera.
2. **Calibration Poses & Open-Source Reference (r2):** Use an **easiest-first** sequence modeled on `Chuyuyan/dance-trainer` (`src/pose/checkup.ts`): **Rest** (framing + legs in frame) → **T-Pose** (1–2 s / 30–60 frames for bone lengths + scale) → **Overhead / Arms Up** (headroom + up/down) → **Asymmetric L/R** (mirroring check) → **Arms Forward** (monocular Z-depth) → **Squat / Plié** (lower-body ROM) → **Turned 45° / Profile** (angle tolerance). Side reach, step L/R, knee lift, and arm circles lack empirical open-source benchmarks in the inspected repos.
3. **Camera Calibration APIs (r3):** Read `AVCameraCalibrationData` (`intrinsicMatrix`, `intrinsicMatrixReferenceDimensions`, `lensDistortionLookupTable`, `inverseLensDistortionLookupTable`, `lensDistortionCenter`) from `AVCapturePhoto.cameraCalibrationData` or `AVDepthData.cameraCalibrationData` (not `CMSampleBuffer`). For per-frame video intrinsics on `AVCaptureVideoDataOutput`, enable `AVCaptureConnection.isCameraIntrinsicMatrixDeliveryEnabled` (after checking `isCameraIntrinsicMatrixDeliverySupported`) and read `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`. Read horizontal FOV from `AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)?.activeFormat.videoFieldOfView`, and lock exposure/white balance via `ExposureMode.locked` / `setExposureModeCustom(duration:iso:completionHandler:)` and `WhiteBalanceMode.locked` / `setWhiteBalanceModeLocked(with:completionHandler:)` inside `lockForConfiguration()` / `unlockForConfiguration()`.

---

## 1. Depth & Camera Options at 2–4 m (r1 · decision-matrix)

### Criteria & Weights
- **Accuracy at 2–4 m (35%):** Dancing distance is 2–4 m; depth/pose must be reliable at that range.
- **Camera-switching cost / UX (25%):** Scoring runs on the FRONT wide camera so the dancer can see the screen. Switching to rear camera breaks live self-view.
- **Fusion complexity (20%):** Engineering cost to align depth maps with MediaPipe 33-landmark + Vision 3D in SwiftUI.
- **Value for metric scale & floor plane (20%):** Calibration needs metric bone lengths/scale and floor plane; Vision 3D already outputs metric 3D joints.

### Weighted Decision Matrix (Scale: 1 poor to 5 best)

| Option | Accuracy @ 2–4 m (35%) | Camera-Switching Cost / UX (25%) | Fusion Complexity (20%) | Metric Scale & Floor Plane Value (20%) | Weighted Total |
|---|---|---|---|---|---|
| **(f) No depth, MediaPipe + Vision 3D only** | 3.5 | 5.0 | 5.0 | 3.0 | **4.08** |
| **(e) Depth only for metric scale & floor plane** | 4.5 (rear LiDAR) / 1.0 (front TrueDepth) | 2.5 | 4.0 | 5.0 | **4.00** |
| **(b) Rear LiDAR (`builtInLiDARDepthCamera` / `ARBodyTrackingConfiguration` + `sceneDepth`)** | 4.5 | 1.0 | 2.5 | 5.0 | **3.33** |
| **(c) Switching to the rear camera** | 4.5 | 1.0 | 3.0 | 4.5 | **3.28** |
| **(a) Front TrueDepth depth** | 1.0 | 5.0 | 3.5 | 1.5 | **2.60** |
| **(d) Fusing depth with MediaPipe** | 3.0 | 2.0 | 1.0 | 3.5 | **2.45** |

### Claims & Evidence
- **Apple Vision 3D (`VNDetectHumanBodyPose3DRequest`, iOS 17.0+) outputs metric 3D joint positions relative to the camera and automatically uses `AVDepthData` when allowed** (r1 · decision-matrix, Tier 1, single source):
  > "A request that detects points on human bodies in 3D space, relative to the camera."
  > "This request generates a collection of VNHumanBodyPose3DObservation objects that describe the position of each body the request detects. If the system allows it, the request uses AVDepthData information to improve the accuracy."
  > — [VNDetectHumanBodyPose3DRequest](https://developer.apple.com/documentation/vision/vndetecthumanbodypose3drequest.md)
- **`ARBodyTrackingConfiguration` is rear-facing camera only** (r1 · decision-matrix, Tier 1, single source):
  > "A configuration that tracks human body poses, planar surfaces, and images using the rear-facing camera."
  > — [ARBodyTrackingConfiguration](https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration.md)
- **`ARFrame.sceneDepth` is rear-camera LiDAR only** (r1 · decision-matrix, Tier 1, single source):
  > "Data on the distance between a device’s rear camera and real-world objects in an AR experience."
  > "populate this value with ARDepthData captured by the LiDAR scanner."
  > — [ARFrame.sceneDepth](https://developer.apple.com/documentation/arkit/arframe/scenedepth.md)
- **Rear LiDAR covers 2–4 m (max range up to 5 m) with ~±1 cm small-object and a-few-cm room accuracy** (r1 · decision-matrix, Tier 2, 1 aggregated source citing 4 peer-reviewed studies):
  > "In peer-reviewed tests, iPhone LiDAR measured small objects to about ±1 cm and rooms with errors of a few centimeters."
  > "Max range up to 5 m"
  > "Static: points within 1 mm of their plane. Moving: about 1 cm on average. Best at 1 to 1.5 m from the target"
  > — [How Accurate is iPhone LiDAR? (Scannr)](https://getscannr.com/blog/how-accurate-is-iphone-lidar)

---

## 2. Dance Calibration Poses & Open-Source GitHub Survey (r2 · breadth-then-cluster)

### Recommended Calibration Pose Clusters & Order
Based on `Chuyuyan/dance-trainer` (`src/pose/checkup.ts`, Tier 1 source code, single source), poses run **easiest-first** to localize failures:
1. **Rest / Neutral Standing** (`id: 'rest'`): baseline, checks whether legs are in frame.
2. **T-Pose (Arms Horizontal)** (`id: 'tpose'`, 1–2 s / 30–60 frames): easiest possible pose; minimizes self-occlusion/foreshortening for baseline bone lengths and scale.
3. **Arms Up / Overhead** (`id: 'overhead'`): checks whether up and down are told apart and top-of-frame headroom.
4. **Asymmetric Pose** (`id: 'asym'`): one arm up, one arm out; verifies left and right are not swapped.
5. **Arms Forward** (`id: 'forward'`): pointing at camera; tests monocular Z-depth.
6. **Squat / Plié** (`id: 'squat'`): arms out, bend knees; tests legs and lower-body ROM.
7. **Head Turn** (`id: 'head'`): arms down, turn head to own left; tests head direction.
8. **Turned 45° / Profile** (`id: 'turned'`): tests whether standing at an angle still scores; `framingProblems()` flags shoulder-width collapse `Math.abs(xs[0] - xs[1]) < 0.045`.

- **Easiest-first checkup sequence rationale** (r2 · breadth-then-cluster, Tier 1, single source):
  > "They run easiest first, so a failure part-way through localises the problem instead of just saying the thing is broken."
  > — [Chuyuyan/dance-trainer (`src/pose/checkup.ts`)](https://github.com/Chuyuyan/dance-trainer)

### Open-Source GitHub Clusters
1. **Browser / Python MediaPipe Dance & Fitness Comparison (Mature / Active):**
   - [`Chuyuyan/dance-trainer`](https://github.com/Chuyuyan/dance-trainer) (12 stars, updated 2026-11-25): `src/pose/checkup.ts` 7-step checkup + `framingProblems()` (torso visibility `>= 0.5`, ankle visibility, normalized torso height `0.09`–`0.55`, shoulder-width collapse `< 0.045`).
   - [`PrashantSaikia/Body-Movement-Comparison-with-Mediapipe`](https://github.com/PrashantSaikia/Body-Movement-Comparison-with-Mediapipe): Python + MediaPipe + OpenCV (`move_comparison.py`, `pose_module.py`, `streamlit_app.py`).
   - [`zin288/DanceVision-AI-Driven-Dance-Proficiency-Assessment`](https://github.com/zin288/DanceVision-AI-Driven-Dance-Proficiency-Assessment) (30 stars, updated 2026-11-22): MediaPipe + ML dance proficiency prediction.
   - [`knosmos/rhythmvision`](https://github.com/knosmos/rhythmvision) (35 stars, updated 2026-08-19): Body-controlled rhythm game.
2. **Personal Baseline & Posture Calibration with MediaPipe (Emerging / Active):**
   - [`wtbates99/batesposture`](https://github.com/wtbates99/batesposture) (26 stars, updated 2026-11-05): `batesposture/ml/mediapipe_compat.py`, `pose_detector.py`, `batesposture/services/score_service.py`.
3. **Multi-Camera & Intrinsic/Extrinsic Calibration with MediaPipe (Research / Niche):**
   - [`NeuroLabsIITH/Set-up-calibrated-multi-cam-3D-coordinate-capture-environment`](https://github.com/NeuroLabsIITH/Set-up-calibrated-multi-cam-3D-coordinate-capture-environment) (5 stars, updated 2026-09-01).
4. **ARKit / RealityKit Native iOS Body Tracking & Metric Scale (Mature):**
   - [`Reality-Dev/BodyTracking`](https://github.com/Reality-Dev/BodyTracking) (87 stars, updated 2026-07-15): `Sources/BodyTracking/Body3D/Configuration.swift` (`runBodyTrackingConfig2D()`, `runBodyTrackingConfig3D()`).
     > "guard ARBodyTrackingConfiguration.isSupported else { ... }"
     > "let config3D = ARBodyTrackingConfiguration()"
     > — [Reality-Dev/BodyTracking (`Configuration.swift`)](https://github.com/Reality-Dev/BodyTracking)
   - [`LightBuzz/Body-Tracking-ARKit`](https://github.com/LightBuzz/Body-Tracking-ARKit) (113 stars, updated 2025-12-07): Unity ARFoundation + ARKit 3.
   - [`d1l4y/PoseKit`](https://github.com/d1l4y/PoseKit) (38 stars, updated 2026-08-23): ARKit + RealityKit JSON export.

---

## 3. Camera Calibration, FOV, Exposure & White-Balance Lock (r3 · source-of-truth)

- **`AVCameraCalibrationData` is delivered on `AVCapturePhoto` or `AVDepthData`, not `CMSampleBuffer` video frames** (r3 · source-of-truth, Tier 1, single source):
  > "Information about the camera characteristics used to capture images and depth data."
  > — [AVCameraCalibrationData](https://developer.apple.com/tutorials/data/documentation/avfoundation/avcameracalibrationdata.json)
  > "Calibration information for the camera device that captured the photo."
  > — [AVCapturePhoto.cameraCalibrationData](https://developer.apple.com/tutorials/data/documentation/avfoundation/avcapturephoto/cameracalibrationdata.json)
- **Per-frame video intrinsics use `AVCaptureConnection.isCameraIntrinsicMatrixDeliveryEnabled` + `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`** (r3 · source-of-truth, Tier 1, single source):
  > "A Boolean value that indicates whether the capture connection currently supports delivering camera intrinsics information."
  > — [AVCaptureConnection.isCameraIntrinsicMatrixDeliverySupported](https://developer.apple.com/tutorials/data/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliverysupported.json)
- **Front wide camera horizontal FOV is read from `AVCaptureDevice.Format.videoFieldOfView`** (r3 · source-of-truth, Tier 1, single source):
  > "Indicates the format’s horizontal field of view in degrees."
  > "Returns zero if the format’s field of view is unknown."
  > — [AVCaptureDevice.Format.videoFieldOfView](https://developer.apple.com/tutorials/data/documentation/avfoundation/avcapturedevice/format/videofieldofview.json)
- **Exposure lock uses `AVCaptureDevice.ExposureMode.locked` and `setExposureModeCustom(duration:iso:completionHandler:)` inside `lockForConfiguration()` / `unlockForConfiguration()`** (r3 · source-of-truth, Tier 1, single source):
  > "A mode that locks exposure for the device."
  > — [AVCaptureDevice.ExposureMode.locked](https://developer.apple.com/tutorials/data/documentation/avfoundation/avcapturedevice/exposuremode-swift.enum/locked.json)
  > "Sets the exposure mode to a custom state, and locks exposure duration and ISO at explicit values."
  > — [setExposureModeCustom(duration:iso:completionHandler:)](https://developer.apple.com/tutorials/data/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:).json)
- **White-balance lock uses `AVCaptureDevice.WhiteBalanceMode.locked` and `setWhiteBalanceModeLocked(with:completionHandler:)`** (r3 · source-of-truth, Tier 1, single source):
  > "A mode that locks the white balance state."
  > — [AVCaptureDevice.WhiteBalanceMode.locked](https://developer.apple.com/tutorials/data/documentation/avfoundation/avcapturedevice/whitebalancemode-swift.enum/locked.json)
  > "Sets the white balance to locked mode with the specified white balance gains."
  > — [setWhiteBalanceModeLocked(with:completionHandler:)](https://developer.apple.com/tutorials/data/documentation/avfoundation/avcapturedevice/setwhitebalancemodelocked(with:completionhandler:).json)

---

## 4. Where the Researchers Disagree

No direct contradictions exist between r1, r2, and r3. However, r1 notes an internal decision trade-off between **(f) No depth, MediaPipe + Vision 3D only** (4.08) and **(e) Depth only for metric scale & floor plane** (4.00): if monocular Vision 3D scale drifts significantly at 3–4 m for very tall or short dancers, or if cm-level floor-plane calibration is required, (e) with a one-time rear LiDAR scan would be more accurate. This would be settled by benchmarking Vision 3D metric scale accuracy at 2–4 m on `iPhone18,2` / iOS 26.

---

## 5. What We Could Not Find

- **r1:** Front TrueDepth exact max range on `iPhone18,2` / iOS 26 was not directly tested on device (`truedepth_opencv.html` did not contain a clean text quote for TrueDepth's 1 m cutoff). `AVCaptureMultiCamSession` (simultaneous front + rear) was not benchmarked for thermal/FPS impact alongside MediaPipe + Vision 3D on `iPhone18,2`.
- **r2:** No open-source repo inspected provided empirical hold-time or per-joint confidence benchmarks specifically for **side reach, step L/R, knee lift, or arm circles** in MediaPipe dance coaching. Multi-camera calibration (`NeuroLabsIITH`), Unity/VRChat ARKit streamers, and `batesposture` ML internals were left shallow as out of scope.
- **r3:** On-device verification on physical `iPhone18,2` (iPhone 17 Pro Max) / iOS 26 was not run (session ran on Windows without Xcode); runtime support for `isCameraIntrinsicMatrixDeliverySupported` on the specific front-camera `activeFormat` and non-zero `videoFieldOfView` must be checked on-device.
- **Did not deliver:** none.

---

## 6. Sources

| URL | Tier | Used For | Opened By |
|---|---|---|---|
| https://developer.apple.com/documentation/vision/vndetecthumanbodypose3drequest.md | Tier 1 | `VNDetectHumanBodyPose3DRequest` availability & `AVDepthData` usage | r1 |
| https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration.md | Tier 1 | Rear-facing camera constraint for `ARBodyTrackingConfiguration` | r1 |
| https://developer.apple.com/documentation/arkit/arframe/scenedepth.md | Tier 1 | Rear-camera LiDAR constraint for `ARFrame.sceneDepth` | r1 |
| https://getscannr.com/blog/how-accurate-is-iphone-lidar | Tier 2 | iPhone LiDAR peer-reviewed accuracy & 5 m max range | r1 |
| https://github.com/Chuyuyan/dance-trainer | Tier 1 | MediaPipe dance checkup sequence (`src/pose/checkup.ts`) & framing thresholds | r2 |
| https://github.com/PrashantSaikia/Body-Movement-Comparison-with-Mediapipe | Tier 1 | Python MediaPipe dance comparison reference | r2 |
| https://github.com/zin288/DanceVision-AI-Driven-Dance-Proficiency-Assessment | Tier 1 | MediaPipe dance proficiency assessment reference | r2 |
| https://github.com/knosmos/rhythmvision | Tier 1 | Body-controlled rhythm game reference | r2 |
| https://github.com/wtbates99/batesposture | Tier 1 | Personal baseline posture calibration reference | r2 |
| https://github.com/NeuroLabsIITH/Set-up-calibrated-multi-cam-3D-coordinate-capture-environment | Tier 1 | Multi-cam MediaPipe calibration reference | r2 |
| https://github.com/Reality-Dev/BodyTracking | Tier 1 | Swift ARKit/RealityKit body tracking (`Configuration.swift`) | r2 |
| https://github.com/LightBuzz/Body-Tracking-ARKit | Tier 1 | Unity ARFoundation + ARKit 3 body tracking reference | r2 |
| https://github.com/d1l4y/PoseKit | Tier 1 | ARKit + RealityKit body position JSON library | r2 |
| https://developer.apple.com/tutorials/data/documentation/avfoundation/avcameracalibrationdata.json | Tier 1 | `AVCameraCalibrationData` properties & availability | r3 |
| https://developer.apple.com/tutorials/data/documentation/avfoundation/avcapturephoto/cameracalibrationdata.json | Tier 1 | `AVCapturePhoto.cameraCalibrationData` delivery | r3 |
| https://developer.apple.com/tutorials/data/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliverysupported.json | Tier 1 | Per-frame video intrinsics on `AVCaptureConnection` | r3 |
| https://developer.apple.com/tutorials/data/documentation/avfoundation/avcapturedevice/format/videofieldofview.json | Tier 1 | Horizontal FOV in degrees via `videoFieldOfView` | r3 |
| https://developer.apple.com/tutorials/data/documentation/avfoundation/avcapturedevice/exposuremode-swift.enum/locked.json | Tier 1 | `ExposureMode.locked` behavior | r3 |
| https://developer.apple.com/tutorials/data/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:).json | Tier 1 | Custom/locked exposure API & caveats | r3 |
| https://developer.apple.com/tutorials/data/documentation/avfoundation/avcapturedevice/whitebalancemode-swift.enum/locked.json | Tier 1 | `WhiteBalanceMode.locked` behavior | r3 |
| https://developer.apple.com/tutorials/data/documentation/avfoundation/avcapturedevice/setwhitebalancemodelocked(with:completionhandler:).json | Tier 1 | Locked white balance gains API & bounds | r3 |

---

## 7. Method

- **Routing:** 3 order(s), styles `decision-matrix`, `breadth-then-cluster`, `source-of-truth`.
- **Routing note:** Run the phased `CalibrationGate` and `CalibrationTuning` plan with Debug Link test steps only after these return; it depends on the depth choice. Also, the owner cites `docs/research/2026-11-18-calibration-research.md`, but the listed reports show none, so confirm that file exists before the plan relies on it.
- **Did not deliver:** none.
