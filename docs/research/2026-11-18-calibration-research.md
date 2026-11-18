# Pre-Dance Calibration Sequence Research for Groove Coach

**Date:** 2026-11-18  
**Order:** `calib-research-c`  
**Target App:** Groove Coach (`ios/GrooveApp/Sources/PracticeCamera.swift`, `MediaPipePoseProvider.swift`, `PracticeView.swift`, `LessonPlayerView.swift`; `ios/GrooveCore/Sources/GrooveCore/CanonicalSkeleton.swift`, `Retarget.swift`, `ScoringEngine.swift`, `GestureRecognizer.swift`)

---

## Executive Summary

Groove Coach currently runs a portrait, front-camera `AVCaptureSession` (`1280×720`, `videoRotationAngle = 90`) feeding a live MediaPipe `PoseLandmarker` (`LIVE_STREAM` mode, `pose_landmarker_full`, `minPoseDetectionConfidence = 0.5`, `minPosePresenceConfidence = 0.5`, `minTrackingConfidence = 0.5`) for a mirrored skeleton overlay and wrist-based `GestureRecognizer`, while recording `.mov` takes for offline scoring via MediaPipe `VIDEO` mode (`GrooveScoringEngine.scoreAttempt`). Importantly, `GrooveScoringEngine.PoseClip` already defines `calibration_frames: [RawPoseFrame]?` and `GrooveScoringEngine.Retarget.learnerBoneLengths(attempt:)` already prefers `calibration_frames` over dance frames when retargeting the teacher's skeleton onto the learner's proportions—yet no pre-dance calibration UI or capture step populates `calibration_frames` today, and foot scoring (`requiredFootJoints`: `leftHeel`, `leftFootIndex`, `rightHeel`, `rightFootIndex`) silently degrades if the dancer stands too close or tilts the phone poorly.

Across **13 open-source GitHub repositories** (dance games, AI gym/squat coaches, posture calibrators, and iOS pose SDKs), **8 official Google/Apple/commercial docs**, **3 arXiv papers**, and **2 YouTube setup guides**, shipped and open-source systems converge on a **fast (~5–8 s), hands-free, 4-stage gated pre-dance calibration sequence**:

1. **Stage 1 — Phone Placement, Stability & Tilt (`CMDeviceMotion`):** Verify the phone is stationary on a surface (`0.5–1.0 m` waist/table height or floor stand) using `userAcceleration` / `rotationRate`, horizontally level (`|roll| <= 5°`), and upright or slightly leaned back (`pitch` in `65°–95°` from horizontal, i.e., `0°–25°` lean-back from vertical) while recording the live `gravity` vector for `GrooveScoringEngine.applyGravityCorrection` (inference synthesizing Apple `CMDeviceMotion` / `CMAttitude` docs and commercial setup guides).
2. **Stage 2 — Lighting & Backlight Check (`AVCaptureDevice` + Luma):** Monitor `AVCaptureDevice.iso`, `exposureDuration`, and `exposureTargetOffset` alongside person-vs-background luma. Following `OpenJustDance` (`views.py`), treat lighting as **non-blocking (informational warning)** whenever pose landmarks track cleanly, warning only on severe darkness (`brightness < 25–40 / 255` or `exposureTargetOffset <= -1.0 EV` at high ISO) or silhouette backlighting so dim bedrooms never deadlock the user.
3. **Stage 3 — Full-Body Framing & Distance Gate (MediaPipe 33 Landmarks):** Switch the camera format from `16:9` center-crop to the sensor-native **`4:3` widest-FoV format** (`QuickPoseCamera.swift`), reducing required stand-back distance in small rooms. Gate on `visibility >= 0.55` across core + foot landmarks (`nose`, `shoulders`, `hips`, `knees`, `ankles`, `heels`, `footIndices`) inside a `RelativeCameraEdgeInsets(top: 0.05, left: 0.06, bottom: 0.06, right: 0.06)` safe box (`QuickPoseCore`, `OpenJustDance`, `office-posture-monitor`), with directional voice/HUD prompts ("Step back to show your feet", "Step closer").
4. **Stage 4 — T-Pose / Neutral Stance Hold & Bone-Length Lock (`0.6 s`–`1.0 s`):** Prompt an arms-out **T-pose** (`t_pose_score >= 0.55` held for `0.6 s` with `0.35 s` dropout tolerance, `OpenJustDance/join_view.py` & `detector.py`) combined with head/CoM stillness (`variance < 0.002`, `OpenJustDance/views.py`; ~18–30 frames, `Smart-fitness-PT/rep_counter.py`). Capture those `~20–30` `RawPoseFrame`s directly into `PoseClip.calibration_frames` so `Retarget.medianBoneLengths` locks accurate, un-foreshortened 3D limb lengths, then fire a success haptic (`UINotificationFeedbackGenerator`), speak `"Locked in! Starting in 3, 2, 1"`, and launch the beat-synced count-in.

---

## Findings by Research Question

### 1. Camera Placement & Tilt

#### How Shipped & Open-Source Apps Guide Placement
- **Height & Distance Sweet Spot:**
  - **Just Dance Camera Controller (`0QWBZChzuSI`, `QbBG9XJwKLI`, Ubisoft News):** Official Ubisoft documentation notes the Camera Controller turns a smartphone into a hands-free solo 3D full-body skeleton tracker ([Ubisoft Camera Controller](https://www.ubisoft.com/en-us/game/just-dance/news-updates/2UBGhF4xWMLAVVFMmTCWwn/revolutionising-motion-gaming-the-camera-controller-feature)). Setup tutorials specify placing the phone **1.5 m to 2.0 m** (up to ~2.5 m) in front of the dancer at **middle-of-body / waist height (`50–70 cm` off the ground)** with the selfie screen facing the player ([Dina Just Dance YouTube Tutorial](https://www.youtube.com/watch?v=0QWBZChzuSI), [Penrose Learning YouTube Guide](https://www.youtube.com/watch?v=QbBG9XJwKLI)).
  - **HomeCourt AI (`homecourt.ai`):** Recommends placing the iOS device on a stable stand or tripod **at least `3–5 feet` (`0.9–1.5 m`) high** so the entire player and court lines remain in view ([HomeCourt Setup FAQ](https://www.homecourt.ai/faq/setup)).
  - **Height Detector (`akvaithiyanathan/-human-height-detection-using-python-in-vs-code-`):** Explicitly instructs the user: *"1. Stand 2-3 meters from camera. 2. Stand upright with feet shoulder-width apart. 3. Ensure FULL BODY is visible from head to toe. 4. Face the camera directly"*, and estimates distance in meters from shoulder pixel width (`reference_width_at_2m = 150 px` at `1280×720` for an average `45 cm` biacromial shoulder width: `distance = (150 / shoulder_px) * 2.0`, clamped to `1.0–5.0 m`) ([baby.py](https://raw.githubusercontent.com/akvaithiyanathan/-human-height-detection-using-python-in-vs-code-/main/baby.py)).

#### Sensor Fusion for Tilt, Roll & Stability (`CoreMotion`)
- **`CMDeviceMotion` & `CMAttitude`:** Apple's Core Motion framework fuses accelerometer and gyroscope streams to separate `gravity` (`CMAcceleration`, unit `g` vector in device coordinates) from `userAcceleration` (`CMAcceleration` imparted by hand movement) and `attitude` (`CMAttitude`: `pitch`, `roll`, `yaw` in radians over `[-π, π]`) ([CMDeviceMotion](https://developer.apple.com/documentation/coremotion/cmdevicemotion.md), [CMAttitude](https://developer.apple.com/documentation/coremotion/cmattitude.md), [Getting processed device-motion data](https://developer.apple.com/documentation/coremotion/getting-processed-device-motion-data.md)).
- **Existing Groove Coach Gravity Usage:** Groove Coach already runs `CMMotionManager` at `30 Hz` (`deviceMotionUpdateInterval = 1.0 / 30.0`) in `PracticeViewModel`, reading `motion.deviceMotion?.gravity` into `PoseClip.gravity_vector` so `GrooveScoringEngine.applyGravityCorrection(point:gravityVector:)` rotates MediaPipe's camera-frame 3D world landmarks into true vertical `(0, -1, 0)` before computing `trunk_lean_deg` (`angleBetweenDeg(trunkVec, Vec3(0, 1, 0))`) and `foot_pitch_deg`.
- **Why Physical Tilt Still Needs a Gate (inference from Groove Coach + BlazePose geometry):** Even though `applyGravityCorrection` mathematically de-tilts 3D world coordinates, extreme camera pitch (e.g., phone flat against a baseboard tilted `> 30°` upward) causes severe perspective foreshortening of the shins/feet and pushes the head or raised hands outside the vertical FoV when jumping, while lateral roll (`|roll| > 5°`) skews horizontal framing margins and makes the preview look crooked.
- **Concrete Sensor Thresholds for Portrait Propped Phone (inference from `CMDeviceMotion` axes & placement geometry):**
  - In portrait upright orientation on iOS, device `+X` points right, `+Y` points up toward the earpiece, and `+Z` points out of the screen toward the user:
    - Perfectly vertical upright portrait: `gravity = (0, -1, 0)`, `pitch = +90°` (`π/2 rad`).
    - Propped on a low table/chair (`50–70 cm` high) or floor stand leaning slightly backward against an object to see head-to-toe at `2.0–2.5 m`: `gravity.y ≈ -0.90 to -1.00`, `gravity.z ≈ -0.42 to +0.09`, corresponding to **elevation pitch from horizontal = `65° to 95°`** (i.e. **`0°` vertical to `25°` backward lean**, or up to `5°` forward lean if placed on a high shelf).
    - **Horizontal level (roll) angle** in portrait plane: `atan2(gravity.x, -gravity.y)` within **`±5°`** (hysteresis release at `±7°`) so the horizon is level.
    - **Phone stationary gate:** `norm(userAcceleration) < 0.03 g` and `norm(rotationRate) < 0.08 rad/s` for **`0.5 s` (15 samples at 30 Hz)** confirms the user has finished propping the phone down and stepped away (inference).

#### Crucial iOS Camera Format Insight (`4:3` vs `16:9` FoV)
- **`QuickPoseCamera.swift` (`quickpose/quickpose-ios-sdk`):** `PracticeCamera.swift` currently sets `session.sessionPreset = .hd1280x720` (`16:9`). In `QuickPoseCamera.swift`, the SDK authors explicitly document and implement `AVCaptureDevice.selectFormat(frameRate:)`: *"Single format policy: the widest field of view the lens offers, at the smallest resolution with a short side of at least 1080... 16:9 video formats are a centre crop of the sensor, so this typically selects a sensor-native 4:3 format"* ([QuickPoseCamera.swift](https://raw.githubusercontent.com/quickpose/quickpose-ios-sdk/main/Sources/QuickPoseCamera/QuickPoseCamera.swift)).
- **Impact on Groove Coach (inference):** Switching `PracticeCamera` (or selecting a `4:3` format when available) avoids cropping ~25% of the sensor's horizontal/vertical peripheral field, allowing dancers in cramped apartments to capture head-to-feet ~`0.4–0.5 m` closer to the phone!

---

### 2. Full-Body Framing Check

#### How BlazePose / MediaPipe Predicts Occluded Landmarks (and Why Visibility Gating Is Mandatory)
- **BlazePose Architecture (`arXiv:2006.10204`, `arXiv:2206.11678`, Google MediaPipe Docs):**
  - BlazePose uses a fast face/person detector that regresses the **Vitruvian man alignment parameters**: the hip midpoint, the **radius of the circle circumscribing the whole person**, and the body incline angle connecting mid-shoulders and mid-hips ([arXiv:2006.10204v1](https://arxiv.org/html/2006.10204v1), [arXiv:2006.10204](https://arxiv.org/abs/2006.10204), [arXiv:2206.11678](https://arxiv.org/abs/2206.11678)).
  - Crucially, BlazePose was trained with random occlusion-simulating rectangles so it **always hallucinates all 33 `x, y, z` coordinates even when the lower body is completely outside the camera frame**, outputting per-landmark `visibility` (`[0.0, 1.0]`, probability the joint is unoccluded) and `presence` (`[0.0, 1.0]`, probability the joint is inside the image bounds) ([arXiv:2006.10204v1](https://arxiv.org/html/2006.10204v1), [MediaPipe Pose Landmarker](https://ai.google.dev/edge/mediapipe/solutions/vision/pose_landmarker)).
  - Furthermore, Gu et al. (`arXiv:2311.17105`, *On the Calibration of Human Pose Estimation*) show that raw neural pose keypoint confidences are systematically miscalibrated as instance scale shrinks (small/distant subjects), reinforcing that framing must check **both** confidence thresholds **and** bounding-box scale/margins ([arXiv:2311.17105](https://arxiv.org/abs/2311.17105)).

#### Concrete Landmark Visibility & Framing Thresholds Across GitHub Repos
1. **`OpenJustDance` (`diegoperea20/OpenJustDance`):**
   - In `CalibrationView._check` (`apps/desktop/ui/views.py`), full-body visibility requires all 8 core extremities—`left_shoulder`, `right_shoulder`, `left_hip`, `right_hip`, `left_wrist`, `right_wrist`, `left_ankle`, `right_ankle`—to satisfy **`visibility >= 0.50`** (`all(raw.visible(n, 0.5) for n in needed)`) ([views.py](https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/ui/views.py)).
   - Person detection (`engine/pose_engine/detector.py`) rejects tiny/distant detections whose bounding-box area ratio `(w * h) / (W * H) < 0.015` (`0.008` in sensitive multi-person mode) or pixel size `< 40×80` ([detector.py](https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/engine/pose_engine/detector.py)).
2. **`office-posture-monitor` (`rakshanda-ai/office-posture-monitor`):**
   - Uses `pose_landmarker_full.task` (exact same model as Groove Coach!) with **`min_visibility: float = 0.55`** (`config.py`), rejecting calibration in `PostureCalibrator.calibrate` if any required landmark falls below `0.55`, and uses frame hysteresis (`45` poor frames to warn, `20` good frames to recover) ([config.py](https://raw.githubusercontent.com/rakshanda-ai/office-posture-monitor/main/config.py), [calibration.py](https://raw.githubusercontent.com/rakshanda-ai/office-posture-monitor/main/calibration.py), [posture_analyzer.py](https://raw.githubusercontent.com/rakshanda-ai/office-posture-monitor/main/posture_analyzer.py)).
3. **`AI-Personal-Trainer` (`RamjeU/AI-Personal-Trainer`):**
   - Implements an explicit `SETUP -> WORKOUT` state machine in `main.py` using **`VISIBILITY_THRESHOLD = 0.65`**, **`SHOULDER_WIDTH_MIN = 0.10`**, and **`SHOULDER_WIDTH_MAX = 0.80`** (normalized image width `0..1`):
     - If `left_hip.visibility <= 0.65` or `right_hip.visibility <= 0.65` → `"Step Back (Show Hips)"`
     - Else if `shoulder_width < 0.10` → `"Too Far! Step Closer"`
     - Else if `shoulder_width > 0.80` → `"Too Close! Step Back"`
     - Else → `"GO! Workout Active."` ([main.py](https://raw.githubusercontent.com/RamjeU/AI-Personal-Trainer/main/main.py)).
4. **`Smart-fitness-PT` (`siddhanttiwari19/Smart-fitness-PT`) & `ai-gym-coach` (`Feki-Tech/ai-gym-coach`) & `DanceFever` (`fbianco/DanceFever`):**
   - All three standardize on **`MIN_VISIBILITY = 0.50`** (`visMin = 0.5` in `Landmarks.swift` and `VNDetectHumanBodyPoseRequest` confidence in `CameraService.swift`; `minVisibility: 0.5` in `DanceFever/src/config.js`), while `Praxis` (`DarshitaBhagat/Praxis`) uses **`0.60`** for `min_detection_confidence` and `min_tracking_confidence` ([pose_detector.py](https://raw.githubusercontent.com/siddhanttiwari19/Smart-fitness-PT/main/pose_detector.py), [Landmarks.swift](https://raw.githubusercontent.com/Feki-Tech/ai-gym-coach/main/ios/CoachCore/Sources/CoachCore/Landmarks.swift), [CameraService.swift](https://raw.githubusercontent.com/Feki-Tech/ai-gym-coach/main/ios/GymCoach/Sources/CameraService.swift), [config.js](https://raw.githubusercontent.com/fbianco/DanceFever/main/src/config.js), [pose.py](https://raw.githubusercontent.com/DarshitaBhagat/Praxis/main/core/pose.py)).
5. **`QuickPose iOS SDK` (`quickpose/quickpose-ios-sdk`):**
   - Provides a dedicated `.inside(RelativeCameraEdgeInsets, limb: .wholeBodyAndHead)` feature with `PoseFeedback.DirectionChange` cases (`.up`, `.down`, `.left`, `.right`, `.forward`, `.back`, `.intoView`, `.intoBox`, `.onFloor`) and `BodyFeedback.standFacing`, turning a rounded border rectangle from `UIColor.red` to `UIColor.green` when `wholeBodyAndHead` fits inside the inset box ([arm64-apple-ios.swiftinterface](https://raw.githubusercontent.com/quickpose/quickpose-ios-sdk/main/QuickPoseCore.xcframework/ios-arm64/QuickPoseCore.framework/Modules/QuickPoseCore.swiftmodule/arm64-apple-ios.swiftinterface)).

#### Synthesizing Groove Coach's Full-Body Framing Gate (inference)
Because Groove Coach grades **foot pitch** (`leftHeel` 29, `rightHeel` 30, `leftFootIndex` 31, `rightFootIndex` 32) and **hands-above-head restart gestures** (`GestureConfig.raisedMargin = 0.05` above `nose`), Groove Coach's framing gate must verify:
1. **Joint Visibility & Coordinates Bounds:**
   - Core joints `[0 (nose), 11, 12 (shoulders), 23, 24 (hips), 25, 26 (knees), 27, 28 (ankles)]` must have **`visibility >= 0.60`** (and `presence >= 0.60` if available).
   - Foot joints `[29, 30, 31, 32]` must have **`visibility >= 0.50`**.
2. **Normalized Frame Safe Insets (`0..1` portrait image):**
   - `nose.y >= 0.08` (leaves `8%` headroom above the nose for top-of-skull + jumping/bounce + hands-raised gesture; note `baby.py` estimates skull crown is `0.15 * (heel_y - nose.y)` above `nose.y`).
   - `max(leftHeel.y, rightHeel.y, leftFootIndex.y, rightFootIndex.y) <= 0.94` (`6%` floor margin so foot pitch isn't clipped at the bottom edge).
   - Horizontal bounds: `min(x) >= 0.06` and `max(x) <= 0.94` (and during T-pose, wrists remain inside `[0.04, 0.96]`).
3. **Body Height Fraction (Distance Gate):**
   - Let `spanY = maxFootY - noseY`. Require **`0.50 <= spanY <= 0.80`** (equivalent to full-body height occupying **~58%–92%** of portrait frame height):
     - `spanY > 0.80` or ankles/feet missing while shoulders are large → **"Too close — step back so your feet are in view"**
     - `spanY < 0.50` (user > ~3.5 m away, degrading hand landmark 21-point resolution) → **"Too far — step a little closer"**

---

### 3. Lighting & Image Quality

#### How Open-Source & Commercial Systems Handle Lighting
- **Critical UX Lesson — Do Not Hard-Block on Brightness Alone (`OpenJustDance`):**
  - `OpenJustDance` computes mean pixel intensity `brightness = float(np.mean(frame))` (`0..255`) in `CameraThread` (`threads.py`) and checks three levels in `CalibrationView._check` (`views.py`):
    1. `DARK_BRIGHTNESS = 20.0` / `brightness < 25.0`: displays `calib.dark_warning` (*"Very dark camera: check the lens or turn on a light"* — catches covered lenses or pitch-black rooms).
    2. `light_ok = brightness >= 40.0`: toggles the `"Good lighting"` checkmark pill green (`>= 40`) vs gray (`< 40`).
    3. `light_blocking = False`: explicitly comments *"Pose-only: in calibration lighting does not block when a body is detected. The indicator stays but never gates the countdown"* ([views.py](https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/ui/views.py), [threads.py](https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/threads.py), [i18n.py](https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/i18n.py)).
  - `CameraThread._is_gray_frame` also checks `std < 8.0 and 115.0 < mean < 140.0` to detect broken/stuck uniform-gray camera streams ([threads.py](https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/threads.py)).
- **Backlighting & Motion Blur Hazards (`0QWBZChzuSI`):**
  - The Just Dance Camera Controller tutorial specifically warns: *"The light should be coming from where the phone is and not from behind you"* (which silhouettes the dancer and washes out facial anchor points like nose/eyes), avoid mirrors/reflective surfaces or color-cycling RGB lights, and wear clothing that contrasts with the wall behind you ([Dina Just Dance YouTube Tutorial](https://www.youtube.com/watch?v=0QWBZChzuSI)).

#### iOS `AVFoundation` Exposure Metadata & Pixel Checks
Apple's `AVCaptureDevice` exposes three KVO-observable hardware exposure properties without needing per-pixel CPU passes ([exposureTargetOffset](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposuretargetoffset.md), [iso](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iso.md), [exposureDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposureduration.md)):
1. **`device.exposureTargetOffset` (`Float`, EV units):** Difference between metered scene brightness and target auto-exposure. When `exposureTargetOffset <= -1.0 EV`, the camera has hit its exposure ceiling and the image is still at least 1 stop underexposed.
2. **`device.iso` (`Float`, within `[activeFormat.minISO, activeFormat.maxISO]`):** Sensor gain. High ISO (`iso >= 800` or `iso / activeFormat.maxISO >= 0.65`) indicates heavy sensor amplification and landmark-jitter noise (inference).
3. **`device.exposureDuration` (`CMTime`, seconds):** Shutter integration time. For fast dance movements (`down_bounce`, `house_jack` at `110–130 BPM`), an auto-exposure shutter slower than **`1/45 s` (`> 0.022 s`, ~22 ms)** introduces severe limb/hand motion blur even if static standing brightness looks acceptable! (inference).
4. **Backlight / Silhouette Detection from `CVPixelBuffer` + Landmarks (inference):**
   - Because `PracticeCamera` already receives `32BGRA` `CVPixelBuffer` frames and normalized torso landmarks (`leftShoulder`, `rightShoulder`, `leftHip`, `rightHip`), sampling a sparse grid (e.g. `16×16` points inside the torso quad vs `32` points in the outer frame border once every `0.5 s` = negligible CPU) yields `torsoLuma` and `bgLuma` (`0..255`):
     - **Pitch-black / covered lens (hard block only if no pose):** `meanLuma < 25` (`OpenJustDance`).
     - **Low-light / motion-blur warning (non-blocking amber badge):** `exposureTargetOffset <= -1.0` OR (`iso >= 800` AND `exposureDuration.seconds > 0.022`) OR `meanLuma < 45` → *"Dim lighting — turn on a front light for sharper foot & hand scoring."*
     - **Backlight warning (non-blocking amber badge):** `bgLuma > 185` AND `torsoLuma < 65` (`bgLuma - torsoLuma > 110`) → *"Bright light behind you — face the light source so you aren't in shadow."*

---

### 4. Pose Capture & User Calibration

#### T-Pose vs. A-Pose vs. Neutral Standing Across Repos
Open-source repos use two complementary calibration patterns:
1. **T-Pose Gesture + Body Proportion Capture (`OpenJustDance`):**
   - `JoinView` (`apps/desktop/ui/join_view.py`) uses **`TPOSE_HOLD_TIME = 0.6` seconds**, **`TPOSE_DROPOUT_TOL = 0.35` seconds** (so a single dropped frame doesn't reset the progress bar!), and **`TPOSE_MIN_SCORE = 0.55`** ([join_view.py](https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/ui/join_view.py)).
   - `t_pose_score` (`engine/pose_engine/detector.py`) computes a weighted `0..1` score (`0.50 * s_y + 0.20 * s_ext + 0.10 * s_span + 0.20 * s_ang`) from 4 scale-invariant sub-metrics normalized by `shoulder = hypot(rs.x - ls.x, rs.y - ls.y)` and `torso = |mid_sh_y - mid_hip_y|`:
     - **Vertical arm alignment (`s_y`, weight `0.50`):** `max(|lw.y - ls.y|, |rw.y - rs.y|, |le.y - ls.y|, |re.y - rs.y|) / y_scale` (`<= 0.25` = `1.0`, `0.60` = `0.0`).
     - **Wrist outward extension (`s_ext`, weight `0.20`):** wrists horizontally outside shoulders (`> -0.15 * shoulder`).
     - **Arm span (`s_span`, weight `0.10`):** `|rw.x - lw.x| / shoulder` (`1.1` → `0.0`, `1.8` → `1.0`).
     - **Elbow straightness (`s_ang`, weight `0.20`):** interior angle `shoulder–elbow–wrist` (`120°` → `0.0`, `150°+` → `1.0`).
     - **Shoulder separation guard (`s_sh`):** requires `shoulder >= 0.05` of frame width ([detector.py](https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/engine/pose_engine/detector.py)).
2. **Stillness / Stability Hold & Countdown (`OpenJustDance`, `Smart-fitness-PT`, `movecalibrate`):**
   - `OpenJustDance` `CalibrationView._check` (`views.py`, `100 ms` timer) buffers the last `20` head positions; once `>= 10` samples have 2D variance `var < 0.002` (in shoulder-width normalized units) continuously for **`2.5 s`**, it starts a **`3, 2, 1` (`1000 ms` tick) countdown** ([views.py](https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/ui/views.py)).
   - `Smart-fitness-PT` (`rep_counter.py`) runs a `SquatPhase.CALIBRATING` state ("Calibrating — stand still") over a **`30-frame` moving average window** (completing at **`>= 28` frames ≈ `0.93 s` at 30 fps**) to lock standing hip baseline `_standing_hip_y` ([rep_counter.py](https://raw.githubusercontent.com/siddhanttiwari19/Smart-fitness-PT/main/rep_counter.py), [main.py](https://raw.githubusercontent.com/siddhanttiwari19/Smart-fitness-PT/main/main.py)).
   - `movecalibrate` (`biomechanics.ts` & `usePoseEstimation.ts`) tracks postural sway with a **`15-frame` `StabilityTracker` (`~0.5 s`)**, normalizing CoM RMS oscillation against `0.03` (`stability[1] = clamp(oscillation / 0.03, 0, 1)`) and joint velocity variance against `0.005`, and computes base-of-support from the 4 foot landmarks (`L_HEEL`, `R_HEEL`, `L_FOOT_INDEX`, `R_FOOT_INDEX`) ([biomechanics.ts](https://raw.githubusercontent.com/aperry938/movecalibrate/main/src/core/biomechanics.ts), [usePoseEstimation.ts](https://raw.githubusercontent.com/aperry938/movecalibrate/main/src/hooks/usePoseEstimation.ts)).
   - Contrast with exercise-ROM calibrators: `ParshvCrafts/AI-Fitness-Trainer` (`CALIBRATION_DURATION = 7 s` min/max curl angles) and `DarshitaBhagat/Praxis` (`TARGET_CALIB_REPS = 3`, 5th/95th percentile angles) calibrate single-joint ROM, whereas dance coaching compares arbitrary choreography against a **retargeted 3D skeleton** ([ParshvCrafts config.py](https://raw.githubusercontent.com/ParshvCrafts/AI-Fitness-Trainer/main/config.py), [Praxis app.py](https://raw.githubusercontent.com/DarshitaBhagat/Praxis/main/app.py), [MindDock dance_coach_demo.py](https://raw.githubusercontent.com/MindDock/motion-tracker/main/demos/dance_coach_demo.py), [DanceTrace main.py](https://raw.githubusercontent.com/cnc0090306/DanceTrace/main/backend/main.py), [Body-Movement-Comparison move_comparison.py](https://raw.githubusercontent.com/PrashantSaikia/Body-Movement-Comparison-with-Mediapipe/main/move_comparison.py), [jay2323-tech exercise_logic.py](https://raw.githubusercontent.com/jay2323-tech/ai-fitness-trainer/main/exercise_logic.py), [movecalibrate calibrationEngine.ts](https://raw.githubusercontent.com/aperry938/movecalibrate/main/src/core/calibrationEngine.ts), [jackye426/vision-model README](https://raw.githubusercontent.com/jackye426/vision-model/main/README.md)).

#### Why T-Pose (or Wide A-Pose) Is Ideal Specifically for Groove Coach (`Retarget.swift`)
In Groove Coach (`Retarget.swift` & `CanonicalSkeleton.swift`), `GrooveScoringEngine.Retarget.learnerBoneLengths(attempt:)` computes the **per-bone median 3D length** across all 19 `canonicalBones`:
- `spine`, `centerShoulder`, `nose`
- `leftHip`, `leftKnee`, `leftAnkle`, `leftHeel`, `leftFootIndex` (and `right*`)
- `leftShoulder`, `leftElbow`, `leftWrist` (and `right*`)

Why T-pose (arms horizontal, feet hip/shoulder-width apart facing camera) beats neutral arms-at-sides or active dance frames (inference from `Retarget.swift` + BlazePose):
1. **Zero depth foreshortening & zero torso self-occlusion:** Every bone (`upperArm`, `forearm`, `thigh`, `shin`, `shoulder`, `hip`) lies parallel to the camera's fronto-parallel `(X, Y)` plane, where monocular BlazePose 3D world coordinates have their highest metric accuracy and zero wrist-on-hip occlusion.
2. **Acts as a deliberate hands-free "Ready / Start" trigger:** Holding a T-pose for **`0.75 s` (~22 frames at 30 fps, with `0.25 s` dropout tolerance)** simultaneously proves the dancer has **horizontal arm clearance** on both sides (won't clip wrists or hit walls during lateral moves) and replaces tapping a tiny button 2.5 meters away! (Also avoids colliding with `GestureRecognizer.restartDrill`, which requires both wrists *above* `headY + 0.05` for `1.0 s`).

#### Mirroring Semantics Confirmation
- MediaPipe `PoseLandmarker` always labels `left*` / `right*` from the **dancer's anatomical perspective**, even on a front camera (`FitVision-AI/pose_utils.py`, `DanceFever/poses.js`, `ai-gym-coach/PoseAnalyzer.kt`) ([pose_utils.py](https://raw.githubusercontent.com/sumit1kr/FitVision-AI/main/pose_utils.py), [poses.js](https://raw.githubusercontent.com/fbianco/DanceFever/main/src/dance/poses.js), [PoseAnalyzer.kt](https://raw.githubusercontent.com/Feki-Tech/ai-gym-coach/main/android/app/src/main/java/com/fekitech/gymcoach/PoseAnalyzer.kt)).
- Groove Coach's `PracticeCamera` leaves the `AVCaptureVideoDataOutput` buffer **un-mirrored** (so `MediaPipePoseProvider` receives true anatomical left/right), mirrors `x -> 1.0 - x` only for `LiveSkeleton` UI display (`displayX`), and sets `PoseClip.mirrored = mirrorTeacher` (`PracticeView`) / `!isMirrored` (`LessonPlayerView`) when the learner mirrors a flipped teacher video (`Retarget.learnerBoneLengths` automatically swaps `left* <-> right*` when `attempt.mirrored == true`). **Calibration frames captured from `MediaPipePoseProvider` must therefore be stored un-mirrored, matching `extract(videoURL:)`!**

#### Voice & Haptic Prompts (Hands-Free UX at 2–3 m)
- At `2.0–2.5 m`, reading small footnote text on an iPhone screen is hard. Following `Feki-Tech/ai-gym-coach` (`SpeechCoach.swift`), use `AVSpeechSynthesizer` (`rate = 0.52`, `.playback` with `[.mixWithOthers, .duckOthers]`, queue depth capped at `< 2`, `4.0 s` cue cooldown per `Smart-fitness-PT/config.py`) paired with large high-contrast HUD pills and `UINotificationFeedbackGenerator().notificationOccurred(.success)` on lock ([SpeechCoach.swift](https://raw.githubusercontent.com/Feki-Tech/ai-gym-coach/main/ios/GymCoach/Sources/SpeechCoach.swift), [Smart-fitness-PT config.py](https://raw.githubusercontent.com/siddhanttiwari19/Smart-fitness-PT/main/config.py), [UINotificationFeedbackGenerator](https://developer.apple.com/documentation/uikit/uinotificationfeedbackgenerator.md)).

---

## Recommended Calibration Sequence for Groove Coach

Once calibrated in a session, **cache the `CalibrationSessionProfile` in memory** (`PracticeCamera` / `GrooveLibrary`): if the phone has not moved (`|Δgravity| < 0.05 g`) between consecutive takes or segments, **auto-skip Stages 1–4** and go straight to the beat count-in, with a `"Recalibrate"` button in the toolbar (and an always-available `"Skip"` button so advanced users are never trapped).

| Step | What the user sees / hears | Measurement | Pass threshold | Source |
| :--- | :--- | :--- | :--- | :--- |
| **1. Prop & Tilt Phone** | **HUD:** Bubble-level horizon line + phone tilt arc.<br>**Voice:** *"Prop your phone waist-high, upright and level."* (Chime + light haptic when locked). | `CMMotionManager` (`30 Hz`) `deviceMotion`:<br>• `rollDeg = atan2(g.x, -g.y) * 180/π`<br>• `elevDeg = atan2(-g.y, hypot(g.x, g.z)) * 180/π`<br>• `accel = norm(userAcceleration)`<br>• `rot = norm(rotationRate)` | • `\|rollDeg\| <= 5.0°`<br>• `elevDeg` in **`65°...95°`** (`0°–25°` lean-back from vertical)<br>• `accel < 0.03 g` & `rot < 0.08 rad/s`<br>• Held for **`0.5 s`** (`15` samples) | [CMDeviceMotion](https://developer.apple.com/documentation/coremotion/cmdevicemotion.md), [CMAttitude](https://developer.apple.com/documentation/coremotion/cmattitude.md), [Dina Just Dance YouTube](https://www.youtube.com/watch?v=0QWBZChzuSI), [HomeCourt Setup FAQ](https://www.homecourt.ai/faq/setup); angle bounds (inference) |
| **2. Lighting & Glare Check** *(Non-blocking)* | **HUD:** Non-blocking amber pill if dim (*"Low light — front lighting improves foot tracking"*) or backlit (*"Bright light behind you — face the light"*). Hard-warns only if pitch-black (`luma < 25`) with no body. | `AVCaptureDevice`: `exposureTargetOffset`, `iso`, `exposureDuration.seconds` + sparse `CVPixelBuffer` luma (`meanLuma`, `torsoLuma`, `bgLuma` on `0..255` scale, sampled at `2 Hz`). | • **Good:** `meanLuma >= 45`, `exposureTargetOffset > -1.0 EV`, `exposureDuration <= 0.022 s` (`1/45 s`), `bgLuma - torsoLuma <= 110`<br>• **Gate policy:** **Informational only** (`light_blocking = false` when pose passes Step 3) | [OpenJustDance views.py](https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/ui/views.py), [threads.py](https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/threads.py), [exposureTargetOffset](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposuretargetoffset.md), [iso](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iso.md), [exposureDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposureduration.md), [Dina Just Dance YouTube](https://www.youtube.com/watch?v=0QWBZChzuSI); shutter/backlight numbers (inference) |
| **3. Full-Body Framing & Distance** | **HUD:** Rounded safe-frame border (`red` → `green`) + live mirrored skeleton.<br>**Voice** (`4 s` cooldown): *"Step back so your feet are visible"* / *"Step closer"* / *"Move to the center"*. | Live MediaPipe `PoseLandmarker` (`33` image landmarks):<br>• `vis` of core (`0,11,12,23,24,25,26,27,28`) & feet (`29,30,31,32`)<br>• Safe box `x ∈ [0.06, 0.94]`, `nose.y >= 0.08`, `maxFootY <= 0.94`<br>• `spanY = maxFootY - noseY` | • Core `visibility >= 0.60`, Feet `visibility >= 0.50`<br>• All joints inside safe insets<br>• `spanY` in **`0.50...0.80`** (~`1.8–2.8 m` distance)<br>• Stable for **`0.4 s`** (`12` frames) | [MediaPipe Pose Landmarker](https://ai.google.dev/edge/mediapipe/solutions/vision/pose_landmarker), [BlazePose 2006.10204](https://arxiv.org/html/2006.10204v1), [QuickPoseCore swiftinterface](https://raw.githubusercontent.com/quickpose/quickpose-ios-sdk/main/QuickPoseCore.xcframework/ios-arm64/QuickPoseCore.framework/Modules/QuickPoseCore.swiftmodule/arm64-apple-ios.swiftinterface), [OpenJustDance views.py](https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/ui/views.py), [office-posture-monitor config.py](https://raw.githubusercontent.com/rakshanda-ai/office-posture-monitor/main/config.py), [AI-Personal-Trainer main.py](https://raw.githubusercontent.com/RamjeU/AI-Personal-Trainer/main/main.py); `spanY` & foot split (inference) |
| **4. T-Pose Hold & Bone Lock** | **HUD:** Circular progress ring (`0% → 100%`) + *"Stretch arms out in a T-pose to lock & start"* → *"Locked!"*<br>**Feedback:** `.success` haptic + chime + Voice *"Ready! 4, 3, 2, 1…"* into beat count-in. | • `tPoseScore` (`wrists` & `elbows` within `0.25 * torso` of `shoulder.y`, elbow angle `>= 145°`, wrist `x` inside `[0.04, 0.96]`)<br>• Nose/hip 2D RMS sway `< 0.015` (var `< 0.00025` raw image)<br>• Collect `[RawPoseFrame]` into `calibrationFrames` | • `tPoseScore >= 0.55` + stillness held for **`0.75 s`** (`~22` frames, **`0.25 s` dropout tolerance**)<br>• Compute `Retarget.medianBoneLengths(calibrationFrames)` & attach to `PoseClip.calibration_frames` | [OpenJustDance join_view.py](https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/ui/join_view.py), [detector.py](https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/engine/pose_engine/detector.py), [Smart-fitness-PT rep_counter.py](https://raw.githubusercontent.com/siddhanttiwari19/Smart-fitness-PT/main/rep_counter.py), [movecalibrate biomechanics.ts](https://raw.githubusercontent.com/aperry938/movecalibrate/main/src/core/biomechanics.ts), [SpeechCoach.swift](https://raw.githubusercontent.com/Feki-Tech/ai-gym-coach/main/ios/GymCoach/Sources/SpeechCoach.swift), [UINotificationFeedbackGenerator](https://developer.apple.com/documentation/uikit/uinotificationfeedbackgenerator.md) |

---

## Swift Implementation Sketch (Mapped onto Groove Coach)

### Architectural Mapping to Existing Files

| File | Current Responsibility (`nirvana-integrate/youtube`) | Calibration Changes Needed |
| :--- | :--- | :--- |
| `ios/GrooveCore/Sources/GrooveCore/CalibrationGate.swift` *(new pure-Swift file)* | *(None — keeps `GrooveCore` free of `UIKit`/`AVFoundation`/`CoreMotion` so Linux `swift test` runs it, matching `GestureRecognizer.swift` and `LiveMatcher.swift`)* | Pure-math `CalibrationGate` state machine: evaluates tilt/roll/motion vectors, lighting metrics, 33-landmark framing/margins, T-pose score + `0.75 s` hold with `0.25 s` dropout tolerance, and emits `calibrationFrames: [RawPoseFrame]`. |
| `ios/GrooveApp/Sources/MediaPipePoseProvider.swift` | Exposes `latestLiveFrame: RawPoseFrame?` and `latestNormalizedLandmarks: [String: CGPoint]` (drops raw per-landmark `visibility` on normalized landmarks). | Expose `latestImageLandmarks: [NormalizedLandmarkSnapshot]` (all 33 `x, y, visibility, presence` values) alongside `latestLiveFrame` inside `poseLandmarker(_:didFinishDetection:...)`. |
| `ios/GrooveApp/Sources/PracticeCamera.swift` | Configures front camera (`1280×720`), runs live MediaPipe + `GestureRecognizer`, records `.mov` via `TakeRecorder`. | 1. Prefer widest-FoV `4:3` format (`>= 720p/1080p` short side, `30 fps`) per `QuickPoseCamera.swift`.<br>2. Expose `ExposureSnapshot` (`iso`, `exposureDurationS`, `exposureTargetOffset`, sparse `meanLuma`, `torsoLuma`, `bgLuma` every `0.5 s`).<br>3. Suppress `GestureRecognizer` while calibration is active so T-pose/framing movement never triggers swipes. |
| `ios/GrooveApp/Sources/CalibrationOverlayView.swift` *(new SwiftUI + TTS/Haptics helper)* | *(None)* | Renders the 4-step HUD (horizon level, safe-frame rounded rectangle, non-blocking light badge, T-pose progress ring, `"Skip"` button) + `CalibrationVoiceCoach` (`AVSpeechSynthesizer` with `4 s` cooldown + `UINotificationFeedbackGenerator`). |
| `ios/GrooveApp/Sources/PracticeView.swift` & `LessonPlayerView.swift` | `PracticeViewModel.Phase` goes `.idle -> .countIn -> .recording`; `LessonPlayerViewModel` starts count-in directly in `startTake()`. Neither populates `PoseClip.calibration_frames`. | Insert `.calibrating` phase before `.countIn` when `cachedCalibration == nil` or gravity shifted `> 0.05 g`. Pass `cachedCalibration.frames` into `PoseClip(..., calibration_frames: cachedCalibration?.frames)` in `buildTake(...)` and `LessonPlayerViewModel` so `Retarget.learnerBoneLengths` uses the T-pose baseline! |

---

### 1. Pure-Math State Machine in `GrooveCore` (`CalibrationGate.swift`)

```swift
import Foundation

/// Pure-Swift pre-dance calibration state machine (Foundation-only; Linux `swift test` compatible).
public struct CalibrationGate: Sendable {

    public enum Step: String, Sendable, Equatable {
        case tiltPhone       // Step 1: Prop phone upright, level, and still
        case frameBody       // Step 3: Step back until head-to-feet fit inside safe box
        case holdTPose       // Step 4: Hold T-pose 0.75s to lock bone lengths
        case locked          // Ready to launch count-in
    }

    public enum LightWarning: String, Sendable, Equatable {
        case none
        case cameraCoveredOrDark // meanLuma < 25
        case dimRoomOrBlurRisk   // offset <= -1.0 EV or slow shutter > 22ms at high ISO
        case backlitSilhouette   // bgLuma - torsoLuma > 110 with dark torso
    }

    public enum FramingCue: String, Sendable, Equatable {
        case ok
        case noPerson
        case stepBackShowFeet
        case stepBackTooClose
        case stepCloser
        case moveLeft
        case moveRight
        case lowerCameraOrStepBack // nose too close to top edge
    }

    public struct MotionSample: Sendable {
        public var gravityX: Double
        public var gravityY: Double
        public var gravityZ: Double
        public var userAccelNormG: Double
        public var rotationRateNormRadS: Double
        public init(gravityX: Double, gravityY: Double, gravityZ: Double,
                    userAccelNormG: Double, rotationRateNormRadS: Double) {
            self.gravityX = gravityX
            self.gravityY = gravityY
            self.gravityZ = gravityZ
            self.userAccelNormG = userAccelNormG
            self.rotationRateNormRadS = rotationRateNormRadS
        }
    }

    public struct LightSample: Sendable {
        public var exposureTargetOffsetEV: Float
        public var iso: Float
        public var exposureDurationS: Double
        public var meanLuma: Double   // 0...255
        public var torsoLuma: Double  // 0...255
        public var bgLuma: Double     // 0...255
        public init(exposureTargetOffsetEV: Float, iso: Float, exposureDurationS: Double,
                    meanLuma: Double, torsoLuma: Double, bgLuma: Double) {
            self.exposureTargetOffsetEV = exposureTargetOffsetEV
            self.iso = iso
            self.exposureDurationS = exposureDurationS
            self.meanLuma = meanLuma
            self.torsoLuma = torsoLuma
            self.bgLuma = bgLuma
        }
    }

    public struct Landmark2D: Sendable {
        public var x: Double          // 0...1 un-mirrored camera image
        public var y: Double          // 0...1 top-down
        public var visibility: Double // 0...1
        public init(x: Double, y: Double, visibility: Double) {
            self.x = x; self.y = y; self.visibility = visibility
        }
    }

    public struct Status: Sendable, Equatable {
        public var step: Step
        public var rollDeg: Double
        public var elevationDeg: Double
        public var tiltOk: Bool
        public var lightWarning: LightWarning
        public var framingCue: FramingCue
        public var tPoseScore: Double
        public var holdProgress: Double // 0...1
        public var spokenPrompt: String?
    }

    // Thresholds grounded in OpenJustDance, office-posture-monitor, QuickPose, AI-Personal-Trainer
    public var maxRollDeg: Double = 5.0
    public var minElevationDeg: Double = 65.0   // up to 25 deg backward lean
    public var maxElevationDeg: Double = 95.0   // up to 5 deg forward lean
    public var maxUserAccelG: Double = 0.03
    public var maxRotationRadS: Double = 0.08
    public var tiltHoldS: Double = 0.50

    public var coreMinVisibility: Double = 0.60
    public var footMinVisibility: Double = 0.50
    public var insetTop: Double = 0.08
    public var insetBottom: Double = 0.06
    public var insetSide: Double = 0.06
    public var minBodySpanY: Double = 0.50
    public var maxBodySpanY: Double = 0.80
    public var framingHoldS: Double = 0.40

    public var tPoseMinScore: Double = 0.55
    public var tPoseHoldS: Double = 0.75
    public var tPoseDropoutTolS: Double = 0.25
    public var maxSwayRMS: Double = 0.015

    private var tiltGoodSince: Double?
    private var framingGoodSince: Double?
    private var tPoseStart: Double?
    private var tPoseLastGood: Double?
    private var hipHistory: [(t: Double, x: Double, y: Double)] = []
    public private(set) var capturedFrames: [GrooveScoringEngine.RawPoseFrame] = []
    public private(set) var lockedGravity: [Double] = [0.0, -1.0, 0.0]

    public init() {}

    public mutating func reset() {
        tiltGoodSince = nil
        framingGoodSince = nil
        tPoseStart = nil
        tPoseLastGood = nil
        hipHistory.removeAll()
        capturedFrames.removeAll()
    }

    public mutating func update(
        time: Double,
        motion: MotionSample?,
        light: LightSample?,
        landmarks: [String: Landmark2D],
        canonicalFrame: GrooveScoringEngine.RawPoseFrame?
    ) -> Status {
        // 1. Lighting evaluation (informational unless camera is pitch-black with no pose)
        let lightWarning = Self.evaluateLight(light)

        // 2. Tilt & stability check
        var rollDeg = 0.0
        var elevDeg = 90.0
        var tiltInstantOk = true
        if let m = motion {
            rollDeg = atan2(m.gravityX, -m.gravityY) * 180.0 / .pi
            elevDeg = atan2(-m.gravityY, hypot(m.gravityX, m.gravityZ)) * 180.0 / .pi
            let upright = elevDeg >= minElevationDeg && elevDeg <= maxElevationDeg
            let level = abs(rollDeg) <= maxRollDeg
            let still = m.userAccelNormG < maxUserAccelG && m.rotationRateNormRadS < maxRotationRadS
            tiltInstantOk = upright && level && still
            if tiltInstantOk {
                lockedGravity = [m.gravityX, m.gravityY, m.gravityZ]
            }
        }
        if tiltInstantOk {
            if tiltGoodSince == nil { tiltGoodSince = time }
        } else {
            tiltGoodSince = nil
            framingGoodSince = nil
            tPoseStart = nil
            capturedFrames.removeAll()
            let prompt = abs(rollDeg) > maxRollDeg
                ? "Level your phone horizontally."
                : (elevDeg < minElevationDeg ? "Stand your phone more upright." : "Set your phone down on a stable surface.")
            return Status(step: .tiltPhone, rollDeg: rollDeg, elevationDeg: elevDeg, tiltOk: false,
                          lightWarning: lightWarning, framingCue: .noPerson, tPoseScore: 0, holdProgress: 0,
                          spokenPrompt: prompt)
        }
        let tiltSettled = (time - (tiltGoodSince ?? time)) >= tiltHoldS
        guard tiltSettled else {
            return Status(step: .tiltPhone, rollDeg: rollDeg, elevationDeg: elevDeg, tiltOk: true,
                          lightWarning: lightWarning, framingCue: .noPerson, tPoseScore: 0, holdProgress: 0,
                          spokenPrompt: nil)
        }

        // 3. Full-body framing check
        let cue = evaluateFraming(landmarks)
        guard cue == .ok else {
            framingGoodSince = nil
            tPoseStart = nil
            capturedFrames.removeAll()
            return Status(step: .frameBody, rollDeg: rollDeg, elevationDeg: elevDeg, tiltOk: true,
                          lightWarning: lightWarning, framingCue: cue, tPoseScore: 0, holdProgress: 0,
                          spokenPrompt: Self.prompt(for: cue, light: lightWarning))
        }
        if framingGoodSince == nil { framingGoodSince = time }
        guard (time - (framingGoodSince ?? time)) >= framingHoldS else {
            return Status(step: .frameBody, rollDeg: rollDeg, elevationDeg: elevDeg, tiltOk: true,
                          lightWarning: lightWarning, framingCue: .ok, tPoseScore: 0, holdProgress: 0,
                          spokenPrompt: nil)
        }

        // 4. T-pose + stillness hold (0.75s hold with 0.25s dropout tolerance)
        let score = Self.computeTPoseScore(landmarks)
        let swayOk = updateSwayAndCheck(time: time, landmarks: landmarks)
        if score >= tPoseMinScore && swayOk {
            if tPoseStart == nil {
                tPoseStart = time
                capturedFrames.removeAll()
            }
            tPoseLastGood = time
            if let canonicalFrame {
                capturedFrames.append(canonicalFrame)
            }
            let elapsed = time - (tPoseStart ?? time)
            let progress = min(1.0, elapsed / tPoseHoldS)
            if elapsed >= tPoseHoldS && capturedFrames.count >= 10 {
                return Status(step: .locked, rollDeg: rollDeg, elevationDeg: elevDeg, tiltOk: true,
                              lightWarning: lightWarning, framingCue: .ok, tPoseScore: score, holdProgress: 1.0,
                              spokenPrompt: "Locked in! Get ready.")
            }
            return Status(step: .holdTPose, rollDeg: rollDeg, elevationDeg: elevDeg, tiltOk: true,
                          lightWarning: lightWarning, framingCue: .ok, tPoseScore: score, holdProgress: progress,
                          spokenPrompt: "Hold still…")
        } else {
            if let lastGood = tPoseLastGood, (time - lastGood) <= tPoseDropoutTolS, let start = tPoseStart {
                let progress = min(0.99, (lastGood - start) / tPoseHoldS)
                return Status(step: .holdTPose, rollDeg: rollDeg, elevationDeg: elevDeg, tiltOk: true,
                              lightWarning: lightWarning, framingCue: .ok, tPoseScore: score, holdProgress: progress,
                              spokenPrompt: nil)
            }
            tPoseStart = nil
            tPoseLastGood = nil
            capturedFrames.removeAll()
            return Status(step: .holdTPose, rollDeg: rollDeg, elevationDeg: elevDeg, tiltOk: true,
                          lightWarning: lightWarning, framingCue: .ok, tPoseScore: score, holdProgress: 0,
                          spokenPrompt: "Stretch both arms out in a T-pose to start.")
        }
    }

    private static func evaluateLight(_ l: LightSample?) -> LightWarning {
        guard let l else { return .none }
        if l.meanLuma < 25.0 { return .cameraCoveredOrDark }
        if l.bgLuma > 185.0 && l.torsoLuma < 65.0 && (l.bgLuma - l.torsoLuma) > 110.0 {
            return .backlitSilhouette
        }
        if l.exposureTargetOffsetEV <= -1.0 || (l.iso >= 800.0 && l.exposureDurationS > 0.022) || l.meanLuma < 45.0 {
            return .dimRoomOrBlurRisk
        }
        return .none
    }

    private func evaluateFraming(_ lm: [String: Landmark2D]) -> FramingCue {
        let core = ["nose", "leftShoulder", "rightShoulder", "leftHip", "rightHip",
                    "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"]
        let feet = ["leftHeel", "rightHeel", "leftFootIndex", "rightFootIndex"]
        guard let ls = lm["leftShoulder"], let rs = lm["rightShoulder"],
              max(ls.visibility, rs.visibility) >= 0.4 else {
            return .noPerson
        }
        for name in ["leftAnkle", "rightAnkle"] {
            if (lm[name]?.visibility ?? 0) < coreMinVisibility { return .stepBackShowFeet }
        }
        for name in feet {
            if (lm[name]?.visibility ?? 0) < footMinVisibility { return .stepBackShowFeet }
        }
        for name in core {
            if (lm[name]?.visibility ?? 0) < coreMinVisibility { return .stepBackShowFeet }
        }
        let allPts = (core + feet).compactMap { lm[$0] }
        let minX = allPts.map(\.x).min() ?? 0
        let maxX = allPts.map(\.x).max() ?? 1
        // Note: in mirrored selfie view, raw x < insetSide appears on the right of the screen
        if minX < insetSide { return .moveLeft }
        if maxX > (1.0 - insetSide) { return .moveRight }

        let noseY = lm["nose"]!.y
        let maxFootY = feet.compactMap { lm[$0]?.y }.max() ?? 1.0
        if noseY < insetTop { return .lowerCameraOrStepBack }
        if maxFootY > (1.0 - insetBottom) { return .stepBackShowFeet }

        let spanY = maxFootY - noseY
        if spanY > maxBodySpanY { return .stepBackTooClose }
        if spanY < minBodySpanY { return .stepCloser }
        return .ok
    }

    private mutating func updateSwayAndCheck(time: Double, landmarks: [String: Landmark2D]) -> Bool {
        guard let lh = landmarks["leftHip"], let rh = landmarks["rightHip"] else { return false }
        let cx = 0.5 * (lh.x + rh.x)
        let cy = 0.5 * (lh.y + rh.y)
        hipHistory.append((t: time, x: cx, y: cy))
        hipHistory.removeAll { time - $0.t > 0.6 }
        guard hipHistory.count >= 6 else { return true }
        let mx = hipHistory.map(\.x).reduce(0, +) / Double(hipHistory.count)
        let my = hipHistory.map(\.y).reduce(0, +) / Double(hipHistory.count)
        let rms = (hipHistory.map { ($0.x - mx) * ($0.x - mx) + ($0.y - my) * ($0.y - my) }
            .reduce(0, +) / Double(hipHistory.count)).squareRoot()
        return rms <= maxSwayRMS
    }

    /// Port of OpenJustDance `t_pose_score` adapted to Groove Coach landmark names.
    public static func computeTPoseScore(_ lm: [String: Landmark2D]) -> Double {
        guard let ls = lm["leftShoulder"], let rs = lm["rightShoulder"],
              let le = lm["leftElbow"], let re = lm["rightElbow"],
              let lw = lm["leftWrist"], let rw = lm["rightWrist"],
              min(ls.visibility, rs.visibility, le.visibility, re.visibility, lw.visibility, rw.visibility) >= 0.5
        else { return 0.0 }
        // Wrists must remain inside horizontal camera bounds
        guard lw.x >= 0.04, lw.x <= 0.96, rw.x >= 0.04, rw.x <= 0.96 else { return 0.0 }

        let shoulder = hypot(rs.x - ls.x, rs.y - ls.y)
        guard shoulder >= 0.05 else { return 0.0 }
        let torso: Double
        if let lh = lm["leftHip"], let rh = lm["rightHip"] {
            torso = abs(0.5 * (ls.y + rs.y) - 0.5 * (lh.y + rh.y))
        } else {
            torso = shoulder * 1.2
        }
        let yScale = max(torso, shoulder * 0.6, 1e-6)
        let yWorst = max(abs(lw.y - ls.y), abs(rw.y - rs.y), abs(le.y - ls.y), abs(re.y - rs.y)) / yScale
        let sY = max(0.0, min(1.0, 1.0 - (yWorst - 0.25) / 0.35))

        let leftIsLeft = ls.x <= rs.x
        let (outerL, outerR) = leftIsLeft ? (ls, rs) : (rs, ls)
        let (wristL, wristR) = leftIsLeft ? (lw, rw) : (rw, lw)
        let extL = (outerL.x - wristL.x) / shoulder
        let extR = (wristR.x - outerR.x) / shoulder
        guard min(extL, extR) > -0.15 else { return 0.0 }
        let sExt = max(0.0, min(1.0, (min(extL, extR) + 0.1) / 0.5))
        let span = abs(rw.x - lw.x) / shoulder
        let sSpan = max(0.0, min(1.0, (span - 1.1) / 0.7))

        func angle(_ a: Landmark2D, _ b: Landmark2D, _ c: Landmark2D) -> Double {
            let v1x = a.x - b.x, v1y = a.y - b.y
            let v2x = c.x - b.x, v2y = c.y - b.y
            let denom = hypot(v1x, v1y) * hypot(v2x, v2y)
            guard denom > 1e-9 else { return 0.0 }
            return acos(max(-1.0, min(1.0, (v1x * v2x + v1y * v2y) / denom))) * 180.0 / .pi
        }
        let minAng = min(angle(ls, le, lw), angle(rs, re, rw))
        let sAng = max(0.0, min(1.0, (minAng - 120.0) / 30.0))
        guard sY > 0.3, sAng > 0.3 else { return 0.0 }
        return 0.50 * sY + 0.20 * sExt + 0.10 * sSpan + 0.20 * sAng
    }

    private static func prompt(for cue: FramingCue, light: LightWarning) -> String {
        switch cue {
        case .noPerson:
            return light == .cameraCoveredOrDark
                ? "Camera is very dark. Check the lens or turn on a light."
                : "Step in front of the camera."
        case .stepBackShowFeet, .stepBackTooClose:
            return "Step back so your head and feet are in view."
        case .stepCloser:
            return "Step a little closer to the camera."
        case .moveLeft, .moveRight:
            return "Step toward the center of the frame."
        case .lowerCameraOrStepBack:
            return "Tilt the phone slightly back or step back so your head fits."
        case .ok:
            return ""
        }
    }
}
```

---

### 2. Camera Format, Exposure & Motion Wiring (`PracticeCamera.swift` & `PracticeView.swift`)

```swift
// Inside PracticeCamera.swift:
// 1. Select widest-FoV 4:3 sensor format (>= 720p short side, 30 fps) instead of cropped 16:9 .hd1280x720
private func selectWidestFoVFormat(on device: AVCaptureDevice, targetFPS: Double = 30.0) {
    var best: AVCaptureDevice.Format?
    for format in device.formats {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard dims.height >= 720, dims.width <= 1920 else { continue }
        guard format.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate
        }) else { continue }
        if let cur = best {
            let curDims = CMVideoFormatDescriptionGetDimensions(cur.formatDescription)
            if format.videoFieldOfView < cur.videoFieldOfView { continue }
            if format.videoFieldOfView == cur.videoFieldOfView &&
               (dims.width * dims.height) >= (curDims.width * curDims.height) { continue }
        }
        best = format
    }
    guard let chosen = best else { return }
    do {
        try device.lockForConfiguration()
        device.activeFormat = chosen
        let frameDur = CMTime(value: 1, timescale: Int32(targetFPS))
        device.activeVideoMinFrameDuration = frameDur
        device.activeVideoMaxFrameDuration = frameDur
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        device.unlockForConfiguration()
    } catch {}
}

// 2. Sample exposure + sparse BGRA luma every 0.5 s on analysisQueue
private func sampleLight(device: AVCaptureDevice, pixelBuffer: CVPixelBuffer,
                         landmarks: [String: CalibrationGate.Landmark2D]) -> CalibrationGate.LightSample {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let w = CVPixelBufferGetWidth(pixelBuffer)
    let h = CVPixelBufferGetHeight(pixelBuffer)
    let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
        return .init(exposureTargetOffsetEV: device.exposureTargetOffset, iso: device.iso,
                     exposureDurationS: device.exposureDuration.seconds, meanLuma: 128, torsoLuma: 128, bgLuma: 128)
    }
    func lumaAt(_ nx: Double, _ ny: Double) -> Double {
        let px = max(0, min(w - 1, Int(nx * Double(w))))
        let py = max(0, min(h - 1, Int(ny * Double(h))))
        let offset = py * bpr + px * 4 // 32BGRA
        let b = Double(base[offset]), g = Double(base[offset + 1]), r = Double(base[offset + 2])
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    // 8x8 global grid
    var sum = 0.0, count = 0.0
    for gx in 0..<8 {
        for gy in 0..<8 {
            sum += lumaAt((Double(gx) + 0.5) / 8.0, (Double(gy) + 0.5) / 8.0)
            count += 1
        }
    }
    // Torso vs border luma for backlight silhouette check
    var torso = 128.0
    if let ls = landmarks["leftShoulder"], let rs = landmarks["rightShoulder"],
       let lh = landmarks["leftHip"], let rh = landmarks["rightHip"] {
        let cx = 0.25 * (ls.x + rs.x + lh.x + rh.x)
        let cy = 0.25 * (ls.y + rs.y + lh.y + rh.y)
        torso = lumaAt(cx, cy)
    }
    let borderPts = [(0.08, 0.15), (0.92, 0.15), (0.08, 0.50), (0.92, 0.50), (0.50, 0.06)]
    let bg = borderPts.map { lumaAt($0.0, $0.1) }.reduce(0, +) / Double(borderPts.count)

    return CalibrationGate.LightSample(
        exposureTargetOffsetEV: device.exposureTargetOffset,
        iso: device.iso,
        exposureDurationS: device.exposureDuration.seconds,
        meanLuma: sum / max(1, count),
        torsoLuma: torso,
        bgLuma: bg
    )
}
```

```swift
// Inside PracticeView.swift / LessonPlayerView.swift when building a PoseClip:
// Attach `cachedCalibrationFrames` so GrooveScoringEngine.Retarget.learnerBoneLengths uses the T-pose baseline!
let clip = GrooveScoringEngine.PoseClip(
    clip_id: String(format: "practice_%03d_%@", takeNumber, reference.move_tag),
    move_tag: reference.move_tag,
    bpm: reference.bpm,
    beat_times: reference.beat_times,
    gravity_vector: gravity,
    mirrored: mirrored,
    audio_latency_ms: latencyMs,
    speed_pct: 100,
    expected: nil,
    frames: retimed,
    calibration_frames: cachedCalibrationFrames // <-- feeds Retarget.learnerBoneLengths(attempt:)
)
```

---

## Opened Sources List

Every source below was directly fetched and read in this session.

| URL | What was read | Type |
| :--- | :--- | :--- |
| https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/README.md | Full dance game flow (`Join T-pose -> Calibration -> Game`), scoring & normalization overview | github |
| https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/ui/join_view.py | `JoinView` T-pose lobby constants (`TPOSE_HOLD_TIME = 0.6`, `TPOSE_DROPOUT_TOL = 0.35`, `TPOSE_MIN_SCORE = 0.55`) | github |
| https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/engine/pose_engine/detector.py | `t_pose_score` formula, sub-weights, elbow angle (`120°–150°`), min person area (`0.015`) | github |
| https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/ui/views.py | `CalibrationView._check`: 8-joint `0.5` visibility check, non-blocking lighting (`brightness >= 40`, `< 25` dark warning), 20-sample head variance `< 0.002` for `2.5 s`, `3..1` countdown | github |
| https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/threads.py | `CameraThread`: `DARK_BRIGHTNESS = 20.0`, `_is_gray_frame` (`std < 8`), `brightness = np.mean(frame)` | github |
| https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/i18n.py | English/Spanish calibration & T-pose UX prompt strings | github |
| https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/engine/normalize_engine/normalizer.py | `BodyNormalizer`: hip-centered, shoulder-width scaled, hip-horizontal rotation normalization (`visibility_threshold = 0.4`) | github |
| https://raw.githubusercontent.com/quickpose/quickpose-ios-sdk/main/Sources/QuickPoseCamera/QuickPoseCamera.swift | `QuickPoseCamera` & `AVCaptureDevice.selectFormat`: sensor-native `4:3` widest-FoV format selection vs `16:9` crop | github |
| https://raw.githubusercontent.com/quickpose/quickpose-ios-sdk/main/QuickPoseCore.xcframework/ios-arm64/QuickPoseCore.framework/Modules/QuickPoseCore.swiftmodule/arm64-apple-ios.swiftinterface | `RelativeCameraEdgeInsets`, `.inside(..., limb: .wholeBodyAndHead)`, `PoseFeedback.DirectionChange`, `Status.noPersonFound` | github |
| https://raw.githubusercontent.com/Feki-Tech/ai-gym-coach/main/ios/GymCoach/Sources/CameraService.swift | iOS `AVCaptureSession` portrait setup (`videoRotationAngle = 90`) + `VNDetectHumanBodyPoseRequest` coordinate flip | github |
| https://raw.githubusercontent.com/Feki-Tech/ai-gym-coach/main/ios/GymCoach/Sources/WorkoutView.swift | SwiftUI live skeleton overlay, HUD pills, idle timer management | github |
| https://raw.githubusercontent.com/Feki-Tech/ai-gym-coach/main/ios/GymCoach/Sources/SpeechCoach.swift | `AVSpeechSynthesizer` hands-free voice coaching (`rate = 0.52`, `.duckOthers`, backlog cap `< 2`) | github |
| https://raw.githubusercontent.com/Feki-Tech/ai-gym-coach/main/ios/CoachCore/Sources/CoachCore/Landmarks.swift | `visMin = 0.5`, `OneEuroFilter` per-joint smoother holding last good landmark during brief drops | github |
| https://raw.githubusercontent.com/Feki-Tech/ai-gym-coach/main/android/app/src/main/java/com/fekitech/gymcoach/PoseAnalyzer.kt | MediaPipe `LIVE_STREAM` setup & front-camera `1.0 - x` mirroring | github |
| https://raw.githubusercontent.com/siddhanttiwari19/Smart-fitness-PT/main/rep_counter.py | `SquatPhase.CALIBRATING` (`30`-frame moving average, `>= 28` frames standing hip baseline lock) | github |
| https://raw.githubusercontent.com/siddhanttiwari19/Smart-fitness-PT/main/pose_detector.py | `MIN_VISIBILITY = 0.5` & critical lower-body landmark gating | github |
| https://raw.githubusercontent.com/siddhanttiwari19/Smart-fitness-PT/main/config.py | `VOICE_COOLDOWN_SEC = 4.0`, `CONSECUTIVE_FRAMES = 6` hysteresis | github |
| https://raw.githubusercontent.com/siddhanttiwari19/Smart-fitness-PT/main/main.py | `"Calibrating — stand still"` vs `"Step into frame"` banner UX | github |
| https://raw.githubusercontent.com/rakshanda-ai/office-posture-monitor/main/config.py | `pose_landmarker_full.task`, `min_visibility = 0.55`, `45`/`20` frame hysteresis | github |
| https://raw.githubusercontent.com/rakshanda-ai/office-posture-monitor/main/calibration.py | `PostureCalibrator` reference capture gated on `min_visibility` | github |
| https://raw.githubusercontent.com/rakshanda-ai/office-posture-monitor/main/posture_analyzer.py | `extract_features` shoulder-width normalization & alignment angles | github |
| https://raw.githubusercontent.com/RamjeU/AI-Personal-Trainer/main/main.py | `SETUP -> WORKOUT` framing gate: `VISIBILITY_THRESHOLD = 0.65`, `SHOULDER_WIDTH_MIN = 0.1`, `SHOULDER_WIDTH_MAX = 0.8` ("Step Back" / "Too Far") | github |
| https://raw.githubusercontent.com/aperry938/movecalibrate/main/src/core/biomechanics.ts | `StabilityTracker(15)`: CoM RMS oscillation `/ 0.03`, joint velocity variance `/ 0.005`, 4-foot-landmark Base of Support | github |
| https://raw.githubusercontent.com/aperry938/movecalibrate/main/src/hooks/usePoseEstimation.ts | MediaPipe `PoseLandmarker` initialization & GPU->CPU fallback | github |
| https://raw.githubusercontent.com/aperry938/movecalibrate/main/src/core/calibrationEngine.ts | Movement quality calibration threshold (`QUALITY_THRESHOLD = 70`) | github |
| https://raw.githubusercontent.com/fbianco/DanceFever/main/src/config.js | Browser MediaPipe dance game constants (`minVisibility: 0.5`, `bothHandsHold: 1.0 s`, `autoContinue: 4 s`) | github |
| https://raw.githubusercontent.com/fbianco/DanceFever/main/src/dance/poses.js | Canonical bone-direction representation & front-camera mirror coordinate math | github |
| https://raw.githubusercontent.com/fbianco/DanceFever/main/src/input/BodyReader.js | EMA landmark smoothing & shoulder visibility gate | github |
| https://raw.githubusercontent.com/ParshvCrafts/AI-Fitness-Trainer/main/config.py | `CALIBRATION_DURATION = 7` seconds, `DETECTION_CONFIDENCE = 0.5` | github |
| https://raw.githubusercontent.com/DarshitaBhagat/Praxis/main/app.py | `TARGET_CALIB_REPS = 3` dynamic 5th/95th percentile calibration UI | github |
| https://raw.githubusercontent.com/DarshitaBhagat/Praxis/main/core/pose.py | MediaPipe Pose `min_detection_confidence = 0.6`, `min_tracking_confidence = 0.6` | github |
| https://raw.githubusercontent.com/akvaithiyanathan/-human-height-detection-using-python-in-vs-code-/main/baby.py | `2–3 m` full-body setup instructions, crown offset (`0.15 * nose-to-heel`), shoulder-width distance estimation (`150 px @ 2 m`) | github |
| https://raw.githubusercontent.com/sumit1kr/FitVision-AI/main/pose_utils.py | Person-perspective anatomical landmark indexing & circular gauge HUD | github |
| https://raw.githubusercontent.com/cnc0090306/DanceTrace/main/backend/main.py | `KEY_LANDMARKS` (`0,11..16,23..28`) hip-centered, hip-to-nose height & torso-angle normalization | github |
| https://raw.githubusercontent.com/MindDock/motion-tracker/main/demos/dance_coach_demo.py | MediaPipe + DTW dance sequence coaching comparison | github |
| https://raw.githubusercontent.com/PrashantSaikia/Body-Movement-Comparison-with-Mediapipe/main/move_comparison.py | FastDTW cosine-distance dance step comparison | github |
| https://raw.githubusercontent.com/jay2323-tech/ai-fitness-trainer/main/exercise_logic.py | Adaptive per-user min/max angle range calibration & body inclination auto-detection | github |
| https://raw.githubusercontent.com/jackye426/vision-model/main/README.md | Per-person neutral upright baseline capture separated from test scoring | github |
| https://ai.google.dev/edge/mediapipe/solutions/vision/pose_landmarker | Official MediaPipe Pose Landmarker docs: 33 normalized + world landmarks, `visibility`, `presence`, confidence options | doc |
| https://developer.apple.com/documentation/coremotion/cmdevicemotion.md | Official Apple `CMDeviceMotion` docs: `attitude`, `gravity`, `userAcceleration`, `rotationRate` | doc |
| https://developer.apple.com/documentation/coremotion/cmattitude.md | Official Apple `CMAttitude` docs: `roll`, `pitch`, `yaw`, `rotationMatrix`, `quaternion` | doc |
| https://developer.apple.com/documentation/coremotion/getting-processed-device-motion-data.md | Official Apple Core Motion guide: reference frames (`xArbitraryZVertical`), update intervals, sensor fusion | doc |
| https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposuretargetoffset.md | Official Apple `AVCaptureDevice.exposureTargetOffset` (EV units, KVO) | doc |
| https://developer.apple.com/documentation/avfoundation/avcapturedevice/iso.md | Official Apple `AVCaptureDevice.iso` (`minISO`..`maxISO`, KVO) | doc |
| https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposureduration.md | Official Apple `AVCaptureDevice.exposureDuration` (`CMTime` shutter duration, KVO) | doc |
| https://developer.apple.com/documentation/vision/vndetecthumanbodypose3drequest.md | Official Apple `VNDetectHumanBodyPose3DRequest` camera-relative 3D body pose docs | doc |
| https://developer.apple.com/documentation/uikit/uinotificationfeedbackgenerator.md | Official Apple `UINotificationFeedbackGenerator` haptic feedback docs | doc |
| https://www.ubisoft.com/en-us/game/just-dance/news-updates/2UBGhF4xWMLAVVFMmTCWwn/revolutionising-motion-gaming-the-camera-controller-feature | Official Ubisoft Just Dance Camera Controller deep-learning full-body skeleton tracking overview | doc |
| https://www.homecourt.ai/faq/setup | Official HomeCourt AI Setup FAQ (`3–5 ft` tripod height, well-lit full-body framing) | doc |
| https://arxiv.org/abs/2006.10204 | Bazarevsky et al., *BlazePose: On-device Real-time Body Pose tracking* (abstract page) | paper |
| https://arxiv.org/html/2006.10204v1 | Bazarevsky et al., *BlazePose: On-device Real-time Body Pose tracking* (`arXiv:2006.10204` full HTML): Vitruvian circle alignment, occlusion simulation, per-point visibility classifier | paper |
| https://arxiv.org/abs/2206.11678 | Grishchenko et al., *BlazePose GHUM Holistic: Real-time 3D Human Landmarks and Pose Estimation* (`arXiv:2206.11678`) | paper |
| https://arxiv.org/abs/2311.17105 | Gu et al., *On the Calibration of Human Pose Estimation* (`arXiv:2311.17105`): keypoint confidence miscalibration vs instance scale | paper |
| https://www.youtube.com/watch?v=0QWBZChzuSI | *How to play JUST DANCE with a CAMERA* (`Dina Just Dance`): `1.5–2 m` distance, `50–70 cm` height, green progress bar in box, front lighting vs backlighting, clothing contrast, face visibility | youtube |
| https://www.youtube.com/watch?v=QbBG9XJwKLI | *How to Use Just Dance Controller App* (`Penrose Learning`): waist-high screen-facing placement, onscreen silhouette alignment, step back/forward recalibration | youtube |
