# Pre-Dance Calibration Sequence for Groove Coach — Verified Research

**Date:** 2026-11-18
**Orders:** `calib-research-c` (initial research, agy) → `calib-verify-c` (verification and final edit, Opus)
**App code read for the mapping (branch `nirvana-integrate/youtube`):** `ios/GrooveApp/Sources/PracticeCamera.swift`, `PracticeView.swift`, `LessonPlayerView.swift`, `MediaPipePoseProvider.swift`; `ios/GrooveCore/Sources/GrooveCore/Retarget.swift`, `ScoringEngine.swift`, `CanonicalSkeleton.swift`, `GestureRecognizer.swift`.

Throughout, **(inference)** marks a number or step that no opened source states, followed by the reasoning behind it. Everything else cites a page that was opened during the verification session.

---

## Summary

We recommend a short calibration that the dancer can complete without touching the phone. It runs before the count-in and has **five steps**:

1. **Place and level the phone.** Use CoreMotion `gravity` to check the phone is upright, level, and still. Spoken cue: "prop it about waist high".
2. **Step back until the whole body is in frame.** Use the 33 live MediaPipe landmarks. Check each landmark's visibility *and its position in the image*, then check body size and centring. Use hysteresis and a "relax after 15 s" fallback.
3. **Lighting advice.** Runs alongside step 2 and **never blocks**. Uses `AVCaptureDevice` ISO and shutter time plus sampled luma.
4. **Hold a calibration T-pose for about 1 s** with a 0.35 s dropout tolerance. Capture those live canonical frames into `PoseClip.calibration_frames`. That field already exists, `Retarget.learnerBoneLengths` already prefers it, and no code fills it today.
5. **Lock and count in.** Audio chime plus spoken "Locked in". Lock the gravity vector for the take.

What verification changed in agy's draft (the verdict table below has every claim):

- **Wrong tilt maths.** The draft's elevation formula `atan2(-g.y, hypot(g.x, g.z))` is symmetric in `g.z`. It never exceeds 90°, so it cannot tell a phone leaning back from one leaning forward, and its "95° = 5° forward lean" bound can never be reached. We replaced it with the signed `atan2(-g.z, -g.y)` (sign convention: inference, verify on device). The roll formula `atan2(g.x, -g.y)` is confirmed: three iOS repos use exactly that expression.
- **The `4:3` format claim is wrong.** Apple defines `videoFieldOfView` as the format's *horizontal* field of view. A 16:9 format is a centre crop of the 4:3 sensor along the *short* side. In portrait the short side runs left-right, so 4:3 gives more **side-to-side** room, not head-to-toe room. The draft's "stand 0.4–0.5 m closer" does not follow. QuickPose's selection also requires a short side of at least 1080, not 720.
- **Lighting numbers were invented.** The draft's `1/45 s` shutter, `ISO 800` and `−1 EV = exposure ceiling` appear in no source. They are replaced by numbers two iOS repos actually ship:
  - mean Y-plane luma `< 0.22` → "Low lighting" (`runform-coach-ai`);
  - front camera `ISO ≥ 450` or `exposureDuration ≥ 0.033 s` or average luminance `< 0.28` → low light (`ai-smart-framing-camera`).
- **Visibility alone is not enough.** One shipped capture gate states that "the pose model also places face points off-frame with high confidence, so position counts" (`Ashrium pose-gates.ts`). BlazePose's paper also assumes the head is always visible, because its detector is a face detector. The framing gate must therefore check landmark *coordinates* as well as visibility.
- **The safe-box inset values were not QuickPose's.** QuickPose's interface exposes the `RelativeCameraEdgeInsets` type but no default values. The insets are now labelled inference.
- **A haptic is useless here.** The draft fired a success haptic on lock, but the phone is on a stand 2 m away. Use an audio chime and speech instead (inference).
- **Two app gaps the draft missed:**
  - `LessonPlayerView` hard-codes the take's `gravity_vector: [0.0, -1.0, 0.0]`.
  - `LessonPlayerView` only calls `camera.start()` inside `startTake()`. A calibration step needs the camera running before the take.

Source count: **55 draft URLs re-opened**, all HTTP 200. **9 further GitHub repos** found by GitHub code search and read. **8 more Apple pages** (Apple docs plus one WWDC session). **2 more arXiv papers** and **MediaPipe's `landmark.proto`**. GitHub repos read in total: **27** (code in 26, a README in 1).

---

## Verdict table: agy's draft claims

Key: ✅ confirmed (the source says it) · ⚠️ partly / needs a qualifier · ❌ wrong · ❓ unsupported (no opened source says it; dropped, or kept as labelled inference).

| # | Draft claim | Source checked | Verdict | Fix applied |
|---|---|---|---|---|
| 1 | Just Dance Camera Controller: phone 1.5–2 m away, 50–70 cm high, selfie camera toward player | Dina YouTube transcript | ✅ | Kept. Added: the video says to place the phone **horizontally** (landscape), so the distance does not carry over directly to Groove Coach's portrait framing |
| 2 | "up to ~2.5 m" | Dina transcript | ❓ | Dropped |
| 3 | Penrose: waist-high, align with silhouette, step back/forward and recalibrate | Penrose transcript | ⚠️ | The words are there, but the same video says "keep the phone steady in your hand". It mixes camera mode with handheld mode. Downgraded to weak evidence |
| 4 | Ubisoft: smartphone camera, deep-learning 3D skeleton | Ubisoft news page | ✅ | Kept. "Hands-free solo" is not on that page; the one-player limit comes from the Dina video |
| 5 | HomeCourt: tripod at least 3–5 ft | HomeCourt FAQ | ✅ | Kept, flagged as a basketball sideline set-up (weak analogy) |
| 6 | `baby.py`: "Stand 2-3 meters…", 150 px at 2 m, clamp 1–5 m, 1280×720, crown = 0.15 × nose-to-heel | `baby.py` | ✅ | Kept |
| 7 | `CMDeviceMotion` separates gravity and user acceleration; attitude in radians, −π…π | Apple CMDeviceMotion; *Getting processed device-motion data* | ✅ | Kept |
| 8 | Groove Coach runs `CMMotionManager` at 30 Hz and writes `gravity` into `PoseClip.gravity_vector` | `PracticeView.swift` | ✅ for `PracticeView` | Added: `LessonPlayerView` hard-codes `[0,-1,0]` |
| 9 | Upright portrait: `gravity ≈ (0,-1,0)`; +Z out of the screen | Apple CMMotionManager (axes shown only in a figure); Poser, aicam and ai-smart-framing all use `atan2(g.x, -g.y)` for roll | ⚠️ | The Y part is supported by three codebases. The Z sign is inference: log it on a device |
| 10 | `elevDeg = atan2(-g.y, hypot(g.x,g.z))`, pass window 65°–95° | Maths | ❌ | Symmetric in `g.z` and capped at 90°. Replaced by signed `tiltBackDeg = atan2(-g.z, -g.y)` |
| 11 | Roll within ±5° | — | ❓ | Sources: Poser shows "level" at `< 3°`; ai-smart-framing uses 0.8°/1.3° hysteresis for photos. Adopted 3° to enter and 5° to exit (inference) |
| 12 | Phone still: `‖userAcceleration‖ < 0.03 g`, `‖rotationRate‖ < 0.08 rad/s` for 0.5 s | — | ❓ | Kept, labelled inference |
| 13 | QuickPose `selectFormat`: "widest field of view… short side of at least 1080… 16:9 video formats are a centre crop… typically selects a sensor-native 4:3 format" | `QuickPoseCamera.swift` | ✅ | Quote kept. The draft's sketch used `>= 720`, which is not QuickPose's rule |
| 14 | 4:3 lets dancers frame head-to-feet 0.4–0.5 m closer | Apple `videoFieldOfView` ("horizontal field of view") | ❌ | In portrait 4:3 adds lateral room only (see Q1). Moved to "optional, later" |
| 15 | BlazePose detector regresses hip midpoint, circumscribing-circle radius and incline (the "Vitruvian man") | arXiv 2006.10204v1 HTML | ✅ | Kept. Attributing this to 2206.11678 is ❓: its abstract does not say it |
| 16 | BlazePose trains with occlusion rectangles and has a per-point visibility classifier | 2006.10204v1 | ✅ | Kept |
| 17 | BlazePose "always hallucinates all 33 points even when the lower body is out of frame" | 2006.10204v1; `landmark.proto` | ⚠️ | The paper says tracking continues "for cases of significant occlusions, like upper body-only". The proto says visibility counts out-of-scene as invisible, and presence is "located within scene bounds". Reworded |
| 18 | Gu et al.: keypoint confidences are miscalibrated as instance scale shrinks | arXiv 2311.17105 abstract | ⚠️ | The abstract says confidence is poorly calibrated and that "predicting the instance size and adjusting the confidence" helps. It studies 2D heatmap estimators, not BlazePose. Reworded |
| 19 | OpenJustDance `CalibrationView._check`: 8 joints at `visible(n, 0.5)` | `views.py` | ✅ | Kept. Added: live play runs **YOLO11n-pose** (`threads.py`, `README.md`), so that "visibility" is a YOLO keypoint confidence, not a MediaPipe value |
| 20 | OpenJustDance detector rejects area ratio `< 0.015` (`0.008` sensitive) and boxes `< 40×80` | `detector.py` | ✅ | Kept. It is the HOG person detector |
| 21 | office-posture-monitor: `pose_landmarker_full.task`, `min_visibility 0.55`, calibration rejected below it, 45/20-frame hysteresis | `config.py`, `calibration.py`, `posture_analyzer.py` | ✅ | The 45/20 frames are posture-warning hysteresis, not calibration |
| 22 | AI-Personal-Trainer: `VISIBILITY_THRESHOLD 0.65`, shoulder width 0.10–0.80, "Step Back (Show Hips)" / "Too Far!" / "Too Close!" | `main.py` | ✅ | Kept |
| 23 | 0.5 visibility in Smart-fitness-PT, ai-gym-coach (`visMin`), DanceFever; Praxis 0.6 | `pose_detector.py`, `Landmarks.swift`, `config.js`, `pose.py` | ✅ | `visMin` lives in `Landmarks.swift`. `CameraService.swift` uses `VNDetectHumanBodyPoseRequest` |
| 24 | QuickPose `.inside(RelativeCameraEdgeInsets, limb: .wholeBodyAndHead)`, red → green border, `DirectionChange` cases | QuickPoseCore `.swiftinterface` | ✅ | Kept |
| 25 | Safe box `RelativeCameraEdgeInsets(top: 0.05, left: 0.06, bottom: 0.06, right: 0.06)` attributed to QuickPoseCore | `.swiftinterface` | ❓ | The interface has the type and `init(top:left:bottom:right:)` but no values. Insets relabelled inference |
| 26 | OpenJustDance brightness: `np.mean(frame)`; `< 25` dark warning; `>= 40` "Good lighting"; `light_blocking = False` | `threads.py`, `views.py`, `i18n.py` | ✅ | Kept |
| 27 | `DARK_BRIGHTNESS = 20.0` shows the dark warning | `threads.py` | ❌ | At 20 the camera thread **switches on an auto-exposure boost**. The warning is the separate `< 25` check in `views.py` |
| 28 | Gray-frame check `std < 8 and 115 < mean < 140` | `threads.py` | ✅ | Kept |
| 29 | Dina: "The light should be coming from where the phone is, and not from behind you"; avoid reflective surfaces and colour-changing RGB lights; contrasting clothes; face visible | Dina transcript | ✅ | Kept, plus "the algorithm needs to see the nose and the eyes… anchor point" |
| 30 | Apple `exposureTargetOffset` (EV), `iso` (between minISO and maxISO), `exposureDuration` (CMTime), all key-value observable | Apple docs ×3 | ✅ | Kept. The ISO page also says "Higher values result in noisier images" |
| 31 | `exposureTargetOffset <= -1 EV` means the exposure ceiling was hit | Apple doc | ❓ | The doc only defines the offset. Labelled inference |
| 32 | Shutter `> 1/45 s` causes blur; ISO ≥ 800 means heavy noise | — | ❓ | Replaced by sourced 0.033 s / ISO 450 / luma 0.28 (ai-smart-framing) and luma 0.22 (runform) |
| 33 | `TPOSE_HOLD_TIME 0.6`, `TPOSE_DROPOUT_TOL 0.35`, `TPOSE_MIN_SCORE 0.55` | `join_view.py` | ✅ | Kept |
| 34 | `t_pose_score` = `0.50·s_y + 0.20·s_ext + 0.10·s_span + 0.20·s_ang` and its sub-metrics | `detector.py` | ✅ | Kept |
| 35 | `s_sh` "requires shoulder ≥ 0.05" | `detector.py` | ⚠️ | It is a multiplier (`shoulder/0.05` when smaller), not a hard gate. The `ok` flag also needs `s_y > 0.3`, `s_ang > 0.3`, `min(ext) > -0.15` |
| 36 | OpenJustDance stability: last 20 head samples, at least 10, variance `< 0.002`, held 2.5 s, then 3-2-1 at 1000 ms | `views.py`, `normalizer.py` | ✅ | The head is from the normalised pose (hip-centred, shoulder-width scaled) |
| 37 | Smart-fitness-PT: `CALIBRATING` over a 30-frame moving average, done at ≥ 28 frames | `rep_counter.py`, `main.py` | ✅ | Note: it averages but **does not test stillness** |
| 38 | movecalibrate: 15-frame `StabilityTracker`, CoM RMS / 0.03, velocity variance / 0.005, base of support from 4 foot points | `biomechanics.ts` | ✅ | Its `calibrationEngine.ts` "calibration" is confidence-vs-quality scoring, not camera set-up |
| 39 | ParshvCrafts `CALIBRATION_DURATION = 7`; Praxis 3 reps with 5th/95th percentiles | `config.py`, `app.py` | ✅ | Kept as a contrast |
| 40 | MediaPipe left/right are the person's own sides | FitVision `pose_utils.py`; DanceFever `poses.js` | ✅ | Kept |
| 41 | `PracticeCamera` buffers are un-mirrored; `displayX` mirrors for the UI | `PracticeCamera.swift` | ✅ | Added: the `GestureRecognizer` is also fed mirrored x |
| 42 | `MediaPipePoseProvider` "drops visibility" on normalised landmarks | `MediaPipePoseProvider.swift`, `CanonicalSkeleton.swift` | ⚠️ | Visibility survives as `RawPoseFrame.confidences` (minimum over source landmarks). **Presence** is dropped, and eye landmarks are not exposed |
| 43 | SpeechCoach: `rate 0.52`, `.playback` with `[.mixWithOthers, .duckOthers]`, backlog cap `< 2`; Smart-fitness `VOICE_COOLDOWN_SEC 4.0` | `SpeechCoach.swift`, `config.py` | ✅ | Kept |
| 44 | `.success` haptic on lock | `UINotificationFeedbackGenerator` doc | ⚠️ | The API exists, but the user is about 2 m from the phone. Replaced with an audio chime (inference) |
| 45 | `Retarget.learnerBoneLengths` prefers `calibration_frames`; per-bone median; mirrored takes swap sides | `Retarget.swift` | ✅ | Kept |
| 46 | `GestureConfig.raisedMargin = 0.05`, restart held 1.0 s | `GestureRecognizer.swift` | ✅ | Kept |
| 47 | Skip steps 1–4 entirely when gravity changed by `< 0.05 g` | — | ❓ | Revised (inference): the dancer may stand somewhere else, so always re-run the cheap framing check |
| 48 | "Every source below was directly fetched" | Re-fetch on 2026-11-18 | ✅ | All 55 returned HTTP 200 |

---

## Findings by research question

The original brief file (`calib-research-c.md`) is not in this worktree. Q1–Q4 follow the draft's headings. Q5 covers how the guidance reaches the dancer and maps onto the app, which the brief's "report shape" asked for.

### Q1. Camera placement and tilt

**What shipped products tell users**
- Just Dance Camera Controller (Dina tutorial):
  - "place your phone horizontally in front of your TV with the selfie camera facing towards you. Step back and stand in the designated box… a green bar progressing as the system is detecting your body";
  - "around 1.5 to 2 m in front of your phone… the middle of your body or around 50 to 70 cm off the ground".
- runform-coach-ai shows "Camera too low. Raise to around hip height." when mid-shoulder `y > 0.86` (Vision coordinates), or when shoulder and hip are less than 0.10 apart vertically.
- HomeCourt asks for a tripod "at least 3-5 feet in height". That is for a basketball sideline, so it is weak evidence for dance.

**Measuring tilt with CoreMotion.** `CMDeviceMotion.gravity` is "the gravity acceleration vector expressed in the device's reference frame". Three iOS repos compute roll as `atan2(g.x, -g.y)`:
- Poser `Camera.swift` shows "Tilt N° to level" unless `|roll| < 3°`;
- aicam `FrameAnalyzer.swift`;
- ai-smart-framing-camera `CameraViewModel.swift`, with 0.8° to enter level and 1.3° to stay level.

For front/back lean:
- Poser uses `pitch = atan2(g.z, -g.y)`;
- aicam uses `atan2(g.z, hypot(g.x, g.y))` and negates it for the front camera.

**Recommended measures** (inference from those formulas):
- `rollDeg = atan2(g.x, -g.y)·180/π`
- `tiltBackDeg = atan2(-g.z, -g.y)·180/π`

With +Z out of the screen, a phone lying face-up has `g ≈ (0, 0, -1)`, so leaning back gives `tiltBackDeg > 0`. Apple shows the axes only in a figure, so **log this sign on a device before shipping**.

**Thresholds** (inference):

| Check | Pass | Why |
|---|---|---|
| Roll | `≤ 3°` to pass, `≤ 5°` to keep passing | A propped phone needs less precision than a photo, so the photo app's 0.8° is too strict |
| Tilt | `−5° ≤ tiltBack ≤ 20°` | `GrooveScoringEngine.applyGravityCorrection` already rotates world landmarks to true vertical using the stored gravity. Tilt therefore matters mainly for perspective foreshortening of shins and feet, and for losing the head or feet out of frame. Beyond about 20° of lean-back from a low phone, the feet are close to the lens while the head is far |
| Stillness | `‖userAcceleration‖ < 0.03 g` and `‖rotationRate‖ < 0.08 rad/s` for 0.5 s | Confirms the phone has been set down. Tune from device logs |

**Distance depends on the field of view, so compute it at runtime instead of hard-coding it.** In portrait, the vertical axis of the picture is the sensor's long side. Apple's `AVCaptureDevice.Format.videoFieldOfView` is "the format's horizontal field of view in degrees" in sensor orientation, which is that long side. The minimum distance is

`d ≥ max(h_cam, H_top − h_cam) / tan(FoV/2)` (inference: pinhole geometry)

where:
- `h_cam` is the phone height;
- `H_top` is the highest point that must stay in frame (about 1.25 × body height with arms up, for the restart gesture).

Example with an **assumed** 60° FoV (the same default the Tai-Chi repo uses), `h_cam` = 0.6 m and `H_top` = 2.2 m: `d ≥ 1.6 / tan 30° ≈ 2.8 m`. Speak the number based on the device's real FoV, then let the framing gate decide.

**4:3 versus 16:9.** QuickPose picks "the widest field of view the lens offers… 16:9 video formats are a centre crop of the sensor, so this typically selects a sensor-native 4:3 format", requiring a short side of at least 1080. Because the crop removes the *short* side, in portrait 4:3 adds **lateral** room (arms, side steps). It adds no head-to-toe room (inference from Apple's definition).

Switching formats is optional and should come later, because:
- `MediaPipePoseProvider` passes `imageAspect: 9.0 / 16.0` to `CanonicalSkeleton.toCanonical`;
- `LiveSkeleton` starts with `9.0 / 16.0`;
- the recorded takes and offline extraction would all change aspect at once.

### Q2. Full-body framing check

**What the model guarantees, and what it doesn't**
- BlazePose's detector is a face detector. It assumes "the head of the person should always be visible", and predicts "the middle point between the person's hips, the size of the circle circumscribing the whole person, and incline" (arXiv 2006.10204).
- It is trained with simulated occlusions and has "a per-point visibility classifier", so it keeps tracking "even for cases of significant occlusions, like upper body-only".
- MediaPipe's `landmark.proto` defines:
  - `visibility`: "visible or occluded… Landmark considered as invisible also if it is not present on the screen (out of scene bounds)";
  - `presence`: "located within scene bounds".
- In practice, though, Ashrium's capture gate says "the pose model also places face points off-frame with high confidence, so position counts". It requires face points within `[0.01, 0.99]` and an estimated crown above `0.005`.
- **Rule: gate on visibility *and* on coordinates.**

**Thresholds shipped in open source** (normalised image coordinates, `y` pointing down):

| Repo | Visibility | Size / distance | Centring / edges | Hold |
|---|---|---|---|---|
| OpenJustDance `views.py` | 8 joints ≥ 0.5 (YOLO conf) | — | — | head variance < 0.002 for 2.5 s |
| AI-Personal-Trainer `main.py` | hips > 0.65 | shoulder width 0.10–0.80 | — | — |
| office-posture-monitor | 7 joints ≥ 0.55 | — | — | — |
| vibecheque `CalibrationGate.tsx` | shoulders > 0.55, hips and wrists > 0.45 | torso height 0.14–0.55 | `|midX − 0.5| ≤ 0.22` | 25 frames |
| runform-coach-ai | Vision conf > 0.25 | nose…ankle span 0.42–0.82 | hip midX 0.35–0.65 | — |
| Ashrium `pose-gates.ts` | 0.45 (ankles/feet 0.3, face 0.5) | crown→sole 0.55–0.98 without an outline; `|scale−1| ≤ 0.12` (enter) / 0.16 (hold) with one | torso centre 0.3–0.7; edge 0.10/0.14 | motion ≤ 0.012 / 0.02 body-heights |
| PhysiqueProgress (Vision) | 9 joints ≥ 0.3 | — | — | — |

**Recommended Groove Coach gate.** It runs on raw (un-mirrored) normalised landmarks, after the phone check passes.

1. **Person present.** Both shoulders have confidence ≥ 0.5. Otherwise say "Step in front of the camera".
2. **Visibility.**
   - Core joints (`nose`, shoulders, hips, knees, ankles): confidence ≥ 0.6.
   - Feet (`leftHeel`, `rightHeel`, `leftFootIndex`, `rightFootIndex`): ≥ 0.5.
   - (Inference.) Sources span 0.45–0.65. Feet run lower; Ashrium uses 0.3. Groove Coach *scores* feet (`requiredFootJoints`), so we sit at the strict end and loosen in relaxed mode.
   - Failure says "Step back so your feet are in view".
3. **Position.**
   - Every core and foot point within `x ∈ [0.05, 0.95]`.
   - `maxFootY ≤ 0.95`.
   - `nose.y ≥ 0.20`.
   - (Inference.) The 0.20 headroom keeps raised wrists in frame: wrists are about 0.27 × height above the nose, about 0.29 of the nose-to-heel span, and the restart gesture needs them above the nose.
4. **Size.** `span = maxFootY − nose.y` in `[0.45, 0.75]`.
   - (Inference.) The lower bound is close to runform's 0.42.
   - The upper bound follows from the headroom and floor margins above (`0.95 − 0.20`).
   - Too big → "Step back". Too small → "Step a little closer".
5. **Centre.** Hip midpoint `x ∈ [0.30, 0.70]` (Ashrium, runform). The cue must be mirrored: raw `x < 0.3` appears on the *right* of the selfie preview.
6. **Hysteresis and fallback.** Use looser limits once a check has passed (Ashrium's enter/hold pattern). After 15 s stuck on red, start at the loose limits (Ashrium `RELAX_AFTER_MS = 15_000`). Always show a **Skip** button.
7. **Stable for 0.4 s** before moving on (inference: about 10 live frames). Use time, not frame counts. `PracticeCamera` drops frames while `analysisBusy`, and the live call waits up to 35 ms, so the live rate varies.

### Q3. Lighting and image quality

- **Never block on light when the pose tracks.** OpenJustDance: "Pose-only: in calibration lighting does not block when a body is detected. The indicator stays but never gates the countdown" (`light_blocking = False`). It shows "Very dark camera: check the lens or turn on a light." below a mean of 25/255. Its "Good lighting" tick is green at ≥ 40/255. That is a BGR mean on a laptop webcam.
- **Sourced iOS low-light triggers:**
  - runform-coach-ai: mean of the 420f Y plane, sampled every 8 px, `< 0.22` → "Low lighting. Move to brighter light.";
  - ai-smart-framing-camera `isLowLightCondition`: average luminance `< 0.28`, or front camera `ISO ≥ 450`, or `exposureDuration ≥ 0.033 s`.
- **Apple APIs.** `iso` lies between the active format's `minISO` and `maxISO`, and "Higher values result in noisier images". `exposureDuration` lies between the format's min and max exposure durations. `exposureTargetOffset` is "the metered exposure level's offset from the target exposure value, in EV units". All three are key-value observable.
- **Backlighting and scene advice** (Dina): "The light should be coming from where the phone is, and not from behind you". Avoid reflective objects and colour-cycling RGB lights. Wear clothes that contrast with the wall. Keep the face clear, because "the algorithm needs to see the nose and the eyes".
- **Why lighting matters to the model:** MET-POSE (arXiv 2502.09460) tests MediaPipe Holistic under brightness, gamma, resolution and similar transformations. It finds many outputs that change under them. This is qualitative support only; the paper gives no threshold.

**Recommended (non-blocking) light advice:**
- **Dim:** mean luma < 0.22 (runform), or `exposureDuration ≥ 0.033 s`, or `iso ≥ 450` (ai-smart-framing). ISO scales differ between devices, so also accept `iso / activeFormat.maxISO ≥ 0.8` (inference). Say "Dim light — turn on a light in front of you for sharper feet and hands."
- **Backlit:** border luma − torso luma > 0.35 with torso luma < 0.25 (inference: a silhouette has a dark torso against a bright background; the numbers are a starting point to tune from logs). Say "Bright light behind you — face the light."
- **Dark with no person:** mean luma < 0.10 (about 25/255, OpenJustDance). Say "Camera is very dark — check the lens or turn on a light."
- Sample at 2 Hz on `analysisQueue`. The cost is negligible (inference: a sparse grid of about 100 samples).

### Q4. Pose capture and user calibration

**Calibration poses in shipped code**

| Repo | Pose | Hold | What it captures |
|---|---|---|---|
| OpenJustDance `join_view.py` / `detector.py` | T-pose, `t_pose_score ≥ 0.55` | 0.6 s, dropout 0.35 s | Claims a player track |
| vibecheque `CalibrationGate.tsx` | T-pose: wrists > 0.16 out from shoulders, within ±0.08 of shoulder y | 25 frames | Starts the game |
| Tai-Chi-Repo `calibration.ts` | T-pose from **world** landmarks: each arm segment within 15° of horizontal | 3 s by default | `computeProportions` takes limb lengths in metres from world landmarks — the same idea as `Retarget.medianBoneLengths` |
| Ashrium `pose-gates.ts` | A-pose: upright, knees ≥ 145°, wrists at least hip-width + 0.1·torso apart, not above shoulder − 0.25·torso | still ≤ 0.012 body-heights | Avatar body scan |
| JamesHardey `BodyPositionChecker.swift` | Arms by the sides, feet shoulder-width | — | "Perfect! Hold still..." |
| OpenJustDance `views.py` | Any stance, stable head | 2.5 s + 3-2-1 | Starts the song |

**Recommendation: a T-pose, held 1.0 s with a 0.35 s dropout tolerance.**
- Score it with OpenJustDance's `t_pose_score ≥ 0.55`, including its `s_y > 0.3`, `s_ang > 0.3` and extension gates.
- Require stillness ≤ 0.012 body-heights per sample to enter, ≤ 0.02 to stay (Ashrium).
- Keep at least 15 captured frames (inference: enough for a stable per-bone median at varying live frame rates).

Why a T-pose suits Groove Coach (inference):
- `Retarget.medianBoneLengths` takes the median of each canonical bone over the frames. Arms held out in the image plane show the upper-arm and forearm unoccluded and without depth foreshortening; arms by the sides overlap the hips.
- The pose doubles as a deliberate "ready" signal.
- It proves there is room to the sides.

The 1.0 s hold sits between OpenJustDance's 0.6 s and vibecheque's 25 frames on one side and Tai-Chi's 3 s on the other. It lengthens the 0.6 s join hold because these frames also feed bone lengths.

**Store raw, un-mirrored canonical frames.** Capture the live `RawPoseFrame` returned by `provider.live(...)`. It is canonical world joints plus `confidences`, the same type `extract(videoURL:)` produces. `PoseClip.mirrored` and `learnerBoneLengths` already swap sides for mirrored takes (`Retarget.swift`).

**Mirroring.** MediaPipe labels left and right from the person's own perspective (FitVision: "MediaPipe landmarks are from the person's perspective, not camera view"; DanceFever: "MediaPipe's 'left' is the person's own left, which appears on the SCREEN-left of a mirrored camera picture").

**Gesture collision.** Raising the arms into a T is a fast horizontal wrist sweep. With `swipeMinDistance 0.35` in 0.5 s, it could fire `swipeLeft`/`swipeRight`. **Suppress `GestureRecognizer` while calibrating.** `restartDrill` (both wrists above `headY + 0.05` for 1.0 s) is not triggered by a T-pose.

### Q5. Delivering guidance hands-free, and mapping onto the app

**Voice.** Use `AVSpeechSynthesizer` the way `ai-gym-coach` `SpeechCoach.swift` does: `rate = 0.52`, `.playback` with `[.mixWithOthers, .duckOthers]`, drop cues when two are pending. Don't repeat a cue within 4 s (Smart-fitness-PT `VOICE_COOLDOWN_SEC = 4.0`). Speak only when the cue *changes*.

**Visuals.** Show a large mirrored skeleton and a rounded frame that turns red → green. QuickPose's `.inside(...)` default style is red with a green conditional colour; Dina describes a box with a green progress bar. Add a hold progress ring.

**Haptics.** Don't use them during calibration (inference: the phone is on a stand about 2 m away). Use a short chime at lock.

**Vision 3D cross-check (optional).**
- `VNHumanBodyPose3DObservation.cameraOriginMatrix` is "a transform from the skeleton hip to the camera". WWDC23 says this "is useful to get an understanding of where the camera was relative to the person". It could estimate camera height and pitch offline from the scored take.
- `bodyHeight` is only accurate when `heightEstimation` is `.measured`. Without depth it is "a reference height of 1.8 meters" (WWDC23). So absolute scale from Vision 3D without depth is a fixed assumption, and MediaPipe world landmarks from the calibration hold are the better per-user proportion source (inference).

**App facts that shape the plan** (read from `nirvana-integrate/youtube`):
- `PracticeCamera.configureSession` uses `.hd1280x720` on the `.front` `builtInWideAngleCamera`, 32BGRA, `videoRotationAngle = 90`, and drops late frames.
- Live landmarks reach the app as `MediaPipePoseProvider.latestNormalizedLandmarks: [String: CGPoint]`, covering the 17 joints in `CanonicalSkeleton.mediapipeIndex` (no eyes). Per-joint visibility arrives as `RawPoseFrame.confidences`.
- `PracticeViewModel` runs `CMMotionManager` at 30 Hz from `onAppear`, and `currentGravity()` feeds `buildTake`.
- **`LessonPlayerViewModel`:**
  - starts the camera only in `startTake()` (`camera.start(); camera.startRecording(to:)`);
  - writes `gravity_vector: [0.0, -1.0, 0.0]` on its take `PoseClip`;
  - has no `CMMotionManager`.
- `PoseClip.calibration_frames` exists and defaults to `nil`. No caller sets it.

---

## Recommended calibration sequence

All coordinates are MediaPipe normalised image coordinates of the un-mirrored portrait buffer, with `y` pointing down. Times are wall-clock, because the live frame rate varies.

| Step | What the user sees / hears | Measurement | Pass threshold | Source |
|---|---|---|---|---|
| **0. Resume** | Nothing if the previous profile still fits. Otherwise the flow starts at step 1 | `CMDeviceMotion.gravity` versus the locked gravity; quick framing check | Phone moved `< 0.05 g` → run step 2 only (0.5 s), then step 5 | (inference) Framing is cheap and the dancer may have moved |
| **1. Place & level the phone** | Bubble-level line plus tilt arc. Voice: "Stand your phone up about waist high, facing you." Then "Level the phone" / "Tilt it back a little less" / "Set it down so it's still" | `rollDeg = atan2(g.x,−g.y)`; `tiltBackDeg = atan2(−g.z,−g.y)`; `‖userAcceleration‖`; `‖rotationRate‖` | `|roll| ≤ 3°` (stay ≤ 5°); `−5° ≤ tiltBack ≤ 20°`; still (`< 0.03 g`, `< 0.08 rad/s`) for 0.5 s | Height: Dina 50–70 cm, runform "around hip height". Roll formula: Poser, aicam, ai-smart-framing. Poser shows level at `< 3°`. Limits: (inference) |
| **2. Step back into frame** | Mirrored skeleton plus a rounded frame, red → green. Voice: "Step back so your feet are in view" / "Step a little closer" / "Move to your left/right" (mirrored) / "Step in front of the camera" | Live landmarks + `confidences`: core and foot visibility; all points within `x ∈ [0.05,0.95]`, `maxFootY ≤ 0.95`, `nose.y ≥ 0.20`; `span = maxFootY − nose.y`; hip midX | Core ≥ 0.6, feet ≥ 0.5; positions inside the box; `0.45 ≤ span ≤ 0.75`; hip midX in `[0.30,0.70]`; all true for 0.4 s. After 15 s red: visibility −0.1 and span `[0.40, 0.80]` | Visibility range: OpenJustDance, office-posture, AI-Personal-Trainer, vibecheque. Position-over-confidence: Ashrium. Span: runform 0.42–0.82. Centre: Ashrium, runform. Relax at 15 s: Ashrium. Exact numbers: (inference) |
| **3. Lighting advice** *(runs alongside 2; never blocks)* | Amber pill plus one spoken tip: "Dim light — turn on a light in front of you" / "Bright light behind you — face the light". Advice: no mirrors or RGB lights; clothes that contrast with the wall | 2 Hz: mean luma, torso-vs-border luma; `device.iso`, `iso/activeFormat.maxISO`, `exposureDuration.seconds` | Dim if luma `< 0.22` or `exposureDuration ≥ 0.033 s` or `iso ≥ 450` (or `≥ 0.8·maxISO`). Backlit if border − torso `> 0.35` and torso `< 0.25`. Very dark if luma `< 0.10` with no person | Non-blocking: OpenJustDance. 0.22: runform. 0.033 s / ISO 450 / 0.28: ai-smart-framing. < 25/255: OpenJustDance. Advice: Dina. Backlight numbers and maxISO ratio: (inference) |
| **4. Calibration T-pose** | Ring fills 0 → 100 %. Voice: "Arms straight out to the sides, like a T. Hold still." | `t_pose_score` (OpenJustDance port); motion = mean shoulder and hip displacement per sample ÷ body span; collect live `RawPoseFrame`s | Score ≥ 0.55 with `s_y > 0.3`, `s_ang > 0.3`, `min(ext) > −0.15`; motion ≤ 0.012 to enter, ≤ 0.02 to stay; held **1.0 s**; gaps ≤ 0.35 s tolerated; ≥ 15 frames captured | Score and dropout: OpenJustDance. T-pose hold: vibecheque (25 frames), Tai-Chi (3 s, world-landmark limb lengths). Stillness: Ashrium. 1.0 s and 15 frames: (inference) |
| **5. Lock & count in** | Chime plus "Locked in!", then the existing 4-beat count-in | Freeze `calibrationFrames`, `lockedGravity`, timestamp; re-enable gestures | — | Existing count-in (`PracticeViewModel.countInBeats = 4`, `manifest.practice.countInBeats`). Chime instead of haptic: (inference) |

There is always a **Skip** button. Skipping leaves `calibration_frames = nil`, which falls back to bone lengths from the take, as today.

---

## Swift implementation sketch

This is a sketch, not compiled: no local Swift toolchain; verify through the linux-ci / IPA workflows. No app code was changed by this order.

### Files

| File | Status | Responsibility |
|---|---|---|
| `ios/GrooveCore/Sources/GrooveCore/CalibrationGate.swift` | **new** (Foundation only, so `swift test` runs it on Linux like `GestureRecognizer.swift`) | Pure state machine: tilt, framing, T-pose and stillness checks; light advice; captured frames |
| `ios/GrooveCore/Tests/GrooveCoreTests/CalibrationGateTests.swift` | **new** | Synthetic landmark/gravity fixtures for every cue and hold, dropout and relax path |
| `ios/GrooveApp/Sources/CalibrationSensors.swift` | **new** | Own `CMMotionManager` (or share PracticeView's); read `AVCaptureDevice` exposure; sample luma from the BGRA buffer at 2 Hz |
| `ios/GrooveApp/Sources/CalibrationOverlayView.swift` | **new** | Level arc, red/green frame, light pill, hold ring, Skip; `CalibrationVoice` (SpeechCoach-style, 4 s cooldown, speaks only on cue change, chime on lock) |
| `ios/GrooveApp/Sources/PracticeCamera.swift` | edit | Add `var calibrationActive` (on `analysisQueue`). When set, skip `recognizer.process` and send `(time, normLandmarks, frame)` plus the pixel buffer to an `onCalibrationSample` callback. Expose `captureDevice` for the exposure reads |
| `ios/GrooveApp/Sources/MediaPipePoseProvider.swift` | optional edit | Also publish `presence` and eye landmarks (2, 5) for a crown estimate like Ashrium's `CROWN_ABOVE_EYES = 0.65` |
| `ios/GrooveApp/Sources/PracticeView.swift` | edit | Add `Phase.calibrating` before `.countIn`. `start()` enters it unless a cached profile passes step 0. `buildTake` passes `calibration_frames: profile?.frames` and uses `profile?.gravity ?? currentGravity()` |
| `ios/GrooveApp/Sources/LessonPlayerView.swift` | edit | Start `camera` and a `CMMotionManager` in `onAppear` rather than in `startTake()`. Add a `.calibrating` phase. Replace the hard-coded `gravity_vector: [0.0, -1.0, 0.0]` with the locked gravity. Pass `calibration_frames` |

### `CalibrationGate.swift` (GrooveCore)

```swift
import Foundation

/// Pre-dance calibration: phone placement → full-body framing → T-pose hold → locked.
/// Landmarks are MediaPipe normalised image coords of the UN-mirrored portrait buffer (y down).
public struct CalibrationGate: Sendable {

    public enum Step: String, Sendable { case placePhone, frameBody, holdPose, locked }

    public enum Cue: String, Sendable {
        case none
        case levelPhone, tiltLessBack, tiltLessForward, setPhoneDown
        case stepIn, stepBackShowFeet, stepBack, stepCloser, moveScreenLeft, moveScreenRight, showHead
        case armsOutT, holdStill
        case locked
    }

    public enum LightAdvice: String, Sendable { case ok, dim, backlit, veryDark }

    public struct Motion: Sendable {
        public var gx, gy, gz: Double            // CMDeviceMotion.gravity (g)
        public var userAccelNorm: Double         // ‖userAcceleration‖ (g)
        public var rotationRateNorm: Double      // ‖rotationRate‖ (rad/s)
        public init(gx: Double, gy: Double, gz: Double, userAccelNorm: Double, rotationRateNorm: Double) {
            self.gx = gx; self.gy = gy; self.gz = gz
            self.userAccelNorm = userAccelNorm; self.rotationRateNorm = rotationRateNorm
        }
    }

    public struct Light: Sendable {
        public var meanLuma: Double              // 0…1
        public var torsoLuma: Double?            // 0…1, nil without a torso
        public var borderLuma: Double            // 0…1
        public var iso: Double
        public var maxISO: Double
        public var exposureDurationS: Double
        public init(meanLuma: Double, torsoLuma: Double?, borderLuma: Double,
                    iso: Double, maxISO: Double, exposureDurationS: Double) {
            self.meanLuma = meanLuma; self.torsoLuma = torsoLuma; self.borderLuma = borderLuma
            self.iso = iso; self.maxISO = maxISO; self.exposureDurationS = exposureDurationS
        }
    }

    public struct Point: Sendable {
        public var x, y, confidence: Double
        public init(x: Double, y: Double, confidence: Double) { self.x = x; self.y = y; self.confidence = confidence }
    }

    public struct Thresholds: Sendable {
        // Step 1 — (inference) except the roll formula/3° level (Poser).
        public var rollEnterDeg = 3.0, rollStayDeg = 5.0
        public var minTiltBackDeg = -5.0, maxTiltBackDeg = 20.0
        public var maxUserAccelG = 0.03, maxRotationRadS = 0.08, phoneStillS = 0.5
        // Step 2 — ranges from OpenJustDance / office-posture / vibecheque / runform / Ashrium; exact values (inference).
        public var coreMinConf = 0.6, footMinConf = 0.5
        public var sideMargin = 0.05, maxFootY = 0.95, minNoseY = 0.20
        public var minSpan = 0.45, maxSpan = 0.75
        public var minHipX = 0.30, maxHipX = 0.70
        public var framingHoldS = 0.4
        public var relaxAfterS = 15.0            // Ashrium RELAX_AFTER_MS
        // Step 4 — OpenJustDance score/dropout, Ashrium stillness; 1.0 s & 15 frames (inference).
        public var tPoseMinScore = 0.55, poseHoldS = 1.0, dropoutS = 0.35
        public var motionEnter = 0.012, motionStay = 0.02
        public var minCapturedFrames = 15
        public init() {}
    }

    public struct Status: Sendable {
        public var step: Step
        public var cue: Cue
        public var light: LightAdvice
        public var rollDeg: Double
        public var tiltBackDeg: Double
        public var progress: Double              // 0…1 for the current hold
    }

    public var t = Thresholds()
    public private(set) var capturedFrames: [GrooveScoringEngine.RawPoseFrame] = []
    public private(set) var lockedGravity: [Double] = [0, -1, 0]

    private var levelLatched = false
    private var phoneOkSince: Double?
    private var framingOkSince: Double?
    private var framingLatched = false
    private var redSince: Double?
    private var poseStart: Double?
    private var poseLastOk: Double?
    private var poseLatched = false
    private var lastBody: (sx: Double, sy: Double, hx: Double, hy: Double)?
    private var phoneSettled = false

    public init() {}

    public mutating func reset() { self = CalibrationGate(t: t) }
    private init(t: Thresholds) { self.t = t }

    /// Signed angles (inference: verify the z sign on a device by logging a phone leaning back).
    public static func tilt(gx: Double, gy: Double, gz: Double) -> (roll: Double, tiltBack: Double) {
        let roll = atan2(gx, -gy) * 180 / .pi
        let tiltBack = atan2(-gz, -gy) * 180 / .pi
        return (roll, tiltBack)
    }

    public mutating func update(time: Double, motion: Motion?, light: Light?,
                                landmarks lm: [String: Point],
                                frame: GrooveScoringEngine.RawPoseFrame?) -> Status {
        let advice = Self.lightAdvice(light, personPresent: lm["leftShoulder"] != nil)
        var roll = 0.0, tiltBack = 0.0

        // Step 1: phone placement.
        if let m = motion, !phoneSettled {
            (roll, tiltBack) = Self.tilt(gx: m.gx, gy: m.gy, gz: m.gz)
            let rollLimit = levelLatched ? t.rollStayDeg : t.rollEnterDeg
            let level = abs(roll) <= rollLimit
            let upright = tiltBack >= t.minTiltBackDeg && tiltBack <= t.maxTiltBackDeg
            let still = m.userAccelNorm < t.maxUserAccelG && m.rotationRateNorm < t.maxRotationRadS
            levelLatched = level
            guard level, upright, still else {
                phoneOkSince = nil
                let cue: Cue = !level ? .levelPhone
                    : tiltBack > t.maxTiltBackDeg ? .tiltLessBack
                    : tiltBack < t.minTiltBackDeg ? .tiltLessForward : .setPhoneDown
                return Status(step: .placePhone, cue: cue, light: advice, rollDeg: roll, tiltBackDeg: tiltBack, progress: 0)
            }
            if phoneOkSince == nil { phoneOkSince = time }
            let held = time - phoneOkSince!
            guard held >= t.phoneStillS else {
                return Status(step: .placePhone, cue: .none, light: advice, rollDeg: roll, tiltBackDeg: tiltBack,
                              progress: held / t.phoneStillS)
            }
            phoneSettled = true
            lockedGravity = [m.gx, m.gy, m.gz]
        }

        // Step 2: framing (re-checked during the pose hold; a failure drops back here).
        if redSince == nil { redSince = time }
        let relaxed = time - redSince! >= t.relaxAfterS
        let framing = framingCue(lm, relaxed: relaxed || framingLatched)
        guard framing == .none else {
            framingOkSince = nil; framingLatched = false
            resetPose()
            return Status(step: .frameBody, cue: framing, light: advice, rollDeg: roll, tiltBackDeg: tiltBack, progress: 0)
        }
        if framingOkSince == nil { framingOkSince = time }
        if !framingLatched {
            let held = time - framingOkSince!
            guard held >= t.framingHoldS else {
                return Status(step: .frameBody, cue: .none, light: advice, rollDeg: roll, tiltBackDeg: tiltBack,
                              progress: held / t.framingHoldS)
            }
            framingLatched = true
        }

        // Step 4: T-pose + stillness hold.
        let score = Self.tPoseScore(lm)
        let motionLimit = poseLatched ? t.motionStay : t.motionEnter
        let still = bodyMotion(lm).map { $0 <= motionLimit } ?? false
        if score >= t.tPoseMinScore && still {
            if poseStart == nil { poseStart = time; capturedFrames.removeAll() }
            poseLatched = true
            poseLastOk = time
            if let frame { capturedFrames.append(frame) }
        } else if let last = poseLastOk, time - last <= t.dropoutS {
            // Tolerated dropout: keep the progress, don't capture this frame.
        } else {
            resetPose()
            return Status(step: .holdPose, cue: score >= t.tPoseMinScore ? .holdStill : .armsOutT,
                          light: advice, rollDeg: roll, tiltBackDeg: tiltBack, progress: 0)
        }
        let elapsed = time - (poseStart ?? time)
        if elapsed >= t.poseHoldS && capturedFrames.count >= t.minCapturedFrames {
            return Status(step: .locked, cue: .locked, light: advice, rollDeg: roll, tiltBackDeg: tiltBack, progress: 1)
        }
        return Status(step: .holdPose, cue: .holdStill, light: advice, rollDeg: roll, tiltBackDeg: tiltBack,
                      progress: min(0.99, elapsed / t.poseHoldS))
    }

    private mutating func resetPose() {
        poseStart = nil; poseLastOk = nil; poseLatched = false; capturedFrames.removeAll()
    }

    // MARK: Framing

    static let core = ["nose", "leftShoulder", "rightShoulder", "leftHip", "rightHip",
                       "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"]
    static let feet = ["leftHeel", "rightHeel", "leftFootIndex", "rightFootIndex"]

    func framingCue(_ lm: [String: Point], relaxed: Bool) -> Cue {
        let slack = relaxed ? 0.1 : 0.0
        let spanSlack = relaxed ? 0.05 : 0.0
        guard let ls = lm["leftShoulder"], let rs = lm["rightShoulder"],
              min(ls.confidence, rs.confidence) >= 0.5 else { return .stepIn }
        for name in Self.feet + ["leftAnkle", "rightAnkle", "leftKnee", "rightKnee"] {
            let floor = Self.feet.contains(name) ? t.footMinConf : t.coreMinConf
            if (lm[name]?.confidence ?? 0) < floor - slack { return .stepBackShowFeet }
        }
        guard let nose = lm["nose"], nose.confidence >= t.coreMinConf - slack else { return .showHead }
        for name in Self.core where (lm[name]?.confidence ?? 0) < t.coreMinConf - slack { return .stepBack }

        // Position counts, not just confidence (Ashrium: off-frame points can score high).
        let pts = (Self.core + Self.feet).compactMap { lm[$0] }
        let maxFootY = Self.feet.compactMap { lm[$0]?.y }.max() ?? 1
        if maxFootY > t.maxFootY { return .stepBackShowFeet }
        if nose.y < t.minNoseY { return .stepBack }
        let span = maxFootY - nose.y
        if span > t.maxSpan + spanSlack { return .stepBack }
        if span < t.minSpan - spanSlack { return .stepCloser }
        guard let lh = lm["leftHip"], let rh = lm["rightHip"] else { return .stepIn }
        let hipX = 0.5 * (lh.x + rh.x)
        // Raw x < 0.5 shows on the RIGHT of the mirrored selfie preview.
        if hipX < t.minHipX || (pts.map(\.x).min() ?? 0) < t.sideMargin { return .moveScreenLeft }
        if hipX > t.maxHipX || (pts.map(\.x).max() ?? 1) > 1 - t.sideMargin { return .moveScreenRight }
        return .none
    }

    /// Mean shoulder+hip midpoint displacement since the last sample, as a fraction of nose→foot span (Ashrium-style).
    private mutating func bodyMotion(_ lm: [String: Point]) -> Double? {
        guard let ls = lm["leftShoulder"], let rs = lm["rightShoulder"],
              let lh = lm["leftHip"], let rh = lm["rightHip"], let nose = lm["nose"] else { lastBody = nil; return nil }
        let cur = (sx: 0.5 * (ls.x + rs.x), sy: 0.5 * (ls.y + rs.y), hx: 0.5 * (lh.x + rh.x), hy: 0.5 * (lh.y + rh.y))
        defer { lastBody = cur }
        guard let prev = lastBody else { return nil }
        let footY = Self.feet.compactMap { lm[$0]?.y }.max() ?? 1
        let span = max(0.05, footY - nose.y)
        let d = 0.5 * (hypot(cur.sx - prev.sx, cur.sy - prev.sy) + hypot(cur.hx - prev.hx, cur.hy - prev.hy))
        return d / span
    }

    // MARK: T-pose (port of OpenJustDance engine/pose_engine/detector.py `t_pose_score`)

    public static func tPoseScore(_ lm: [String: Point], visMin: Double = 0.3) -> Double {
        guard let ls = lm["leftShoulder"], let rs = lm["rightShoulder"], let le = lm["leftElbow"],
              let re = lm["rightElbow"], let lw = lm["leftWrist"], let rw = lm["rightWrist"] else { return 0 }
        let hidden = [ls, rs, le, re, lw, rw].filter { $0.confidence < visMin }.count
        if hidden > 2 { return 0 }
        let shoulder = hypot(rs.x - ls.x, rs.y - ls.y)
        guard shoulder > 1e-6 else { return 0 }
        var torso = shoulder * 1.2
        if let lh = lm["leftHip"], let rh = lm["rightHip"] { torso = abs(0.5 * (ls.y + rs.y) - 0.5 * (lh.y + rh.y)) }
        let yScale = max(torso, shoulder * 0.6, 1e-6)
        let yWorst = [lw.y - ls.y, rw.y - rs.y, le.y - ls.y, re.y - rs.y].map { abs($0) / yScale }.max()!
        let sY = clamp01(1 - (yWorst - 0.25) / 0.35)
        let leftIsLeft = ls.x <= rs.x
        let (oL, oR) = leftIsLeft ? (ls, rs) : (rs, ls)
        let (wL, wR) = leftIsLeft ? (lw, rw) : (rw, lw)
        let ext = min((oL.x - wL.x) / shoulder, (wR.x - oR.x) / shoulder)
        let sExt = clamp01((ext + 0.1) / 0.5)
        let sSpan = clamp01((abs(rw.x - lw.x) / shoulder - 1.1) / 0.7)
        let sAng = clamp01((min(angle(ls, le, lw), angle(rs, re, rw)) - 120) / 30)
        let sSh = shoulder >= 0.05 ? 1.0 : shoulder / 0.05
        var score = (0.50 * sY + 0.20 * sExt + 0.10 * sSpan + 0.20 * sAng) * sSh
        if hidden > 0 { score *= 0.7 }
        // detector.py `ok` gates
        guard sY > 0.3, sAng > 0.3, ext > -0.15 else { return min(score, 0.54) }
        return clamp01(score)
    }

    static func angle(_ a: Point, _ b: Point, _ c: Point) -> Double {
        let v1 = (a.x - b.x, a.y - b.y), v2 = (c.x - b.x, c.y - b.y)
        let n = hypot(v1.0, v1.1) * hypot(v2.0, v2.1)
        guard n > 1e-9 else { return 0 }
        return acos(max(-1, min(1, (v1.0 * v2.0 + v1.1 * v2.1) / n))) * 180 / .pi
    }

    static func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }

    // MARK: Light (advice only — never gates; OpenJustDance light_blocking = False)

    public static func lightAdvice(_ l: Light?, personPresent: Bool) -> LightAdvice {
        guard let l else { return .ok }
        if !personPresent && l.meanLuma < 0.10 { return .veryDark }                       // ≈ OpenJustDance < 25/255
        if let torso = l.torsoLuma, l.borderLuma - torso > 0.35, torso < 0.25 { return .backlit } // (inference)
        let isoHigh = l.iso >= 450 || (l.maxISO > 0 && l.iso / l.maxISO >= 0.8)            // ai-smart-framing; ratio (inference)
        if l.meanLuma < 0.22 || l.exposureDurationS >= 0.033 || isoHigh { return .dim }    // runform; ai-smart-framing
        return .ok
    }
}
```

### Hooks in the app (sketch)

```swift
// PracticeCamera.swift — analysis path (analysisQueue). New state:
var calibrationActive = false                       // set via analysisQueue.async
var onCalibrationSample: ((Double, [String: CalibrationGate.Point], RawPoseFrame, CVPixelBuffer) -> Void)?
private(set) var captureDevice: AVCaptureDevice?    // stored in configureSession()

// in analyze(_:time:), after `guard let frame = provider.live(...)`:
if calibrationActive {
    var pts: [String: CalibrationGate.Point] = [:]
    for (name, p) in normLandmarks {                // RAW (un-mirrored) coords — not displayX
        pts[name] = .init(x: Double(p.x), y: Double(p.y), confidence: frame.confidences?[name] ?? 0)
    }
    onCalibrationSample?(time, pts, frame, pixelBuffer)
    // skip recognizer.process(sample): a T-pose raise looks like a swipe
} else if let command = recognizer.process(sample) { ... }
```

```swift
// CalibrationSensors.swift — 2 Hz light sample on analysisQueue (32BGRA buffer, sparse grid).
func lightSample(_ pb: CVPixelBuffer, device: AVCaptureDevice,
                 torso: CGRect?) -> CalibrationGate.Light {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    func luma(_ nx: Double, _ ny: Double) -> Double {
        let o = min(h - 1, Int(ny * Double(h))) * bpr + min(w - 1, Int(nx * Double(w))) * 4
        return (0.0722 * Double(base[o]) + 0.7152 * Double(base[o + 1]) + 0.2126 * Double(base[o + 2])) / 255
    }
    let grid = (0..<10).flatMap { i in (0..<10).map { j in luma((Double(i) + 0.5) / 10, (Double(j) + 0.5) / 10) } }
    let border = [(0.05, 0.1), (0.95, 0.1), (0.05, 0.5), (0.95, 0.5), (0.5, 0.03)].map { luma($0.0, $0.1) }
    let torsoLuma = torso.map { r in
        [(0.3, 0.3), (0.7, 0.3), (0.5, 0.5), (0.3, 0.7), (0.7, 0.7)]
            .map { luma(r.minX + $0.0 * r.width, r.minY + $0.1 * r.height) }.reduce(0, +) / 5
    }
    return .init(meanLuma: grid.reduce(0, +) / Double(grid.count), torsoLuma: torsoLuma,
                 borderLuma: border.reduce(0, +) / Double(border.count),
                 iso: Double(device.iso), maxISO: Double(device.activeFormat.maxISO),
                 exposureDurationS: device.exposureDuration.seconds)
}
```

```swift
// PracticeView.swift — PracticeViewModel
enum Phase: Equatable { case idle, calibrating, countIn, recording, analyzing, results, paused }
struct CalibrationProfile { let frames: [GrooveScoringEngine.RawPoseFrame]; let gravity: [Double]; let at: Date }
private var profile: CalibrationProfile?

// buildTake(...):
GrooveScoringEngine.PoseClip(/* existing args */,
    gravity_vector: profile?.gravity ?? gravity,
    calibration_frames: profile?.frames)          // feeds Retarget.learnerBoneLengths(attempt:)

// LessonPlayerView.swift — LessonPlayerViewModel
// • onAppear: camera.start() + motion.startDeviceMotionUpdates() (today camera starts in startTake()).
// • takePoseClip: gravity_vector: profile?.gravity ?? currentGravity()   (today: [0.0, -1.0, 0.0])
//                 calibration_frames: profile?.frames
```

---

## Open risks

1. **Tilt sign and thresholds have not been tried on a device.** The `tiltBackDeg` sign assumes +Z points out of the screen; Apple shows the axes only in a figure. The ±limits are inference. Ship with logging (`roll`, `tiltBack`, pass/fail) and tune. The sketch checks the phone only until it settles. If the phone gets bumped during framing, nothing catches it. A production gate should keep watching `‖userAcceleration‖` and drop back to step 1.
2. **Live and offline frame sources differ.** `calibration_frames` would come from the LIVE_STREAM landmarker. Take frames come from `extract(videoURL:)` in VIDEO mode. Both run `pose_landmarker_full` and `CanonicalSkeleton.toCanonical`, but the live path waits up to 35 ms and may skip frames. Bone medians should still agree; add a test comparing live and offline medians on the same recording. An alternative is to record the calibration hold into the `.mov` and extract it offline.
3. **The visibility floors may be too strict for feet** in dim rooms. Ashrium uses 0.3 for ankles and feet. The relaxed mode (−0.1 after 15 s) and Skip prevent a deadlock, but measure the pass rate.
4. **Body-span bounds assume a typical adult and arms-up headroom.** Very tall dancers in small rooms may never fit 0.75 at a reachable distance. Relaxed mode widens the band to 0.80; beyond that, Skip.
5. **ISO and luma scales vary by device.** ISO 450 comes from one repo's front-camera heuristic. Prefer the `iso / maxISO` ratio and log real values.
6. **4:3 format (optional).** It helps lateral room in portrait only. It changes `imageAspect` (hard-coded `9.0 / 16.0` in `MediaPipePoseProvider` and in `LiveSkeleton`'s initial value), the preview crop, and the recorded take format. Treat it as a separate change with its own tests.
7. **Vision 3D scale.** Without depth, `bodyHeight` is a 1.8 m reference (WWDC23). Don't use Vision 3D for per-user proportions; use the MediaPipe calibration frames.
8. **Mirrored cues.** "Move left/right" must be phrased for the mirrored preview. Raw `x` and screen `x` are opposite.
9. **Gesture suppression.** If `calibrationActive` is left set after Skip or cancel, swipes and claps stop working. Clear it on every exit path.
10. **Source quality.** Several of the GitHub repos are small hobby or hackathon projects. Their thresholds show the range people ship, not validated optima. No opened paper gives validated framing or lighting thresholds for MediaPipe.

---

## Sources

"Read" means the page was fetched in this session and the cited lines or sections were read. All URLs were re-checked at the end; see the status listing in the commit's work report.

### GitHub: code read

| URL | What was read | Type |
|---|---|---|
| https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/README.md | Game flow (Join T-pose → Calibration → Game); live backend `yolo11n-pose`; "Light level is informational only" | github |
| https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/ui/join_view.py | `TPOSE_HOLD_TIME 0.6`, `TPOSE_DROPOUT_TOL 0.35`, `TPOSE_MIN_SCORE 0.55`; hold/dropout loop | github |
| https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/engine/pose_engine/detector.py | HOG person filter (40×80, area 0.015/0.008); full `t_pose_score` | github |
| https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/ui/views.py | `CalibrationView._check`: 8 joints ≥ 0.5, dark < 25, light ≥ 40, `light_blocking = False`, head variance < 0.002, 2.5 s, countdown | github |
| https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/threads.py | `DARK_BRIGHTNESS 20` auto-exposure boost; `np.mean(frame)`; gray-frame check; YOLO live backend | github |
| https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/apps/desktop/i18n.py | "Very dark camera: check the lens or turn on a light."; calibration step labels | github |
| https://raw.githubusercontent.com/diegoperea20/OpenJustDance/main/engine/normalize_engine/normalizer.py | Hip-centred, shoulder-width-scaled normalisation (visibility 0.4) | github |
| https://raw.githubusercontent.com/quickpose/quickpose-ios-sdk/main/Sources/QuickPoseCamera/QuickPoseCamera.swift | `selectFormat`: widest FoV, short side ≥ 1080, 16:9 is a centre crop | github |
| https://raw.githubusercontent.com/quickpose/quickpose-ios-sdk/main/QuickPoseCore.xcframework/ios-arm64/QuickPoseCore.framework/Modules/QuickPoseCore.swiftmodule/arm64-apple-ios.swiftinterface | `RelativeCameraEdgeInsets` (no defaults), `.inside(...)` red/green style, `DirectionChange`, `BodyFeedback.standFacing`, `noPersonFound` | github |
| https://raw.githubusercontent.com/Feki-Tech/ai-gym-coach/main/ios/GymCoach/Sources/SpeechCoach.swift | `AVSpeechSynthesizer` rate 0.52, `.playback` mix/duck, backlog < 2 | github |
| https://raw.githubusercontent.com/Feki-Tech/ai-gym-coach/main/ios/CoachCore/Sources/CoachCore/Landmarks.swift | `visMin = 0.5`, OneEuro hold-last-good | github |
| https://raw.githubusercontent.com/Feki-Tech/ai-gym-coach/main/ios/GymCoach/Sources/CameraService.swift | `VNDetectHumanBodyPoseRequest`, `videoRotationAngle = 90`, y flip | github |
| https://raw.githubusercontent.com/Feki-Tech/ai-gym-coach/main/ios/GymCoach/Sources/WorkoutView.swift | Skeleton overlay, idle-timer handling | github |
| https://raw.githubusercontent.com/Feki-Tech/ai-gym-coach/main/android/app/src/main/java/com/fekitech/gymcoach/PoseAnalyzer.kt | MediaPipe LIVE_STREAM; `1.0 - x` mirroring | github |
| https://raw.githubusercontent.com/siddhanttiwari19/Smart-fitness-PT/main/rep_counter.py | `CALIBRATING`, 30-frame window, ≥ 28 frames | github |
| https://raw.githubusercontent.com/siddhanttiwari19/Smart-fitness-PT/main/pose_detector.py | `MIN_VISIBILITY = 0.5`, critical joints | github |
| https://raw.githubusercontent.com/siddhanttiwari19/Smart-fitness-PT/main/config.py | `VOICE_COOLDOWN_SEC 4.0`, `CONSECUTIVE_FRAMES 6` | github |
| https://raw.githubusercontent.com/siddhanttiwari19/Smart-fitness-PT/main/main.py | "Calibrating — stand still", "Step into frame" | github |
| https://raw.githubusercontent.com/rakshanda-ai/office-posture-monitor/main/config.py | `pose_landmarker_full.task`, `min_visibility 0.55`, 45/20 frames | github |
| https://raw.githubusercontent.com/rakshanda-ai/office-posture-monitor/main/calibration.py | `PostureCalibrator.calibrate` returns False if features are missing | github |
| https://raw.githubusercontent.com/rakshanda-ai/office-posture-monitor/main/posture_analyzer.py | `extract_features` needs 7 joints ≥ min visibility | github |
| https://raw.githubusercontent.com/RamjeU/AI-Personal-Trainer/main/main.py | SETUP→WORKOUT gate, 0.65, shoulder width 0.1–0.8, prompts | github |
| https://raw.githubusercontent.com/aperry938/movecalibrate/main/src/core/biomechanics.ts | `StabilityTracker(15)`, /0.03, /0.005, base of support from 4 foot points | github |
| https://raw.githubusercontent.com/aperry938/movecalibrate/main/src/core/calibrationEngine.ts | `QUALITY_THRESHOLD 70` confidence-vs-quality calibration | github |
| https://raw.githubusercontent.com/aperry938/movecalibrate/main/src/hooks/usePoseEstimation.ts | PoseLandmarker GPU→CPU fallback | github |
| https://raw.githubusercontent.com/fbianco/DanceFever/main/src/config.js | `minVisibility 0.5`, `bothHandsHold 1.0`, `autoContinue 4` | github |
| https://raw.githubusercontent.com/fbianco/DanceFever/main/src/dance/poses.js | "MediaPipe's 'left' is the person's own left…"; raw un-mirrored → mirrored dirs | github |
| https://raw.githubusercontent.com/fbianco/DanceFever/main/src/input/BodyReader.js | EMA smoothing, shoulder visibility gate | github |
| https://raw.githubusercontent.com/ParshvCrafts/AI-Fitness-Trainer/main/config.py | `CALIBRATION_DURATION 7`, `DETECTION_CONFIDENCE 0.5` | github |
| https://raw.githubusercontent.com/DarshitaBhagat/Praxis/main/app.py | `TARGET_CALIB_REPS 3`, 5th/95th percentiles | github |
| https://raw.githubusercontent.com/DarshitaBhagat/Praxis/main/core/pose.py | detection/tracking confidence 0.6 | github |
| https://raw.githubusercontent.com/akvaithiyanathan/-human-height-detection-using-python-in-vs-code-/main/baby.py | "Stand 2-3 meters…", 150 px at 2 m, clamp 1–5 m, crown 0.15, 1280×720 | github |
| https://raw.githubusercontent.com/sumit1kr/FitVision-AI/main/pose_utils.py | "MediaPipe landmarks are from the person's perspective, not camera view" | github |
| https://raw.githubusercontent.com/cnc0090306/DanceTrace/main/backend/main.py | `KEY_LANDMARKS`, hip→nose height scaling, torso-axis rotation | github |
| https://raw.githubusercontent.com/MindDock/motion-tracker/main/demos/dance_coach_demo.py | DTW dance-sequence matcher | github |
| https://raw.githubusercontent.com/PrashantSaikia/Body-Movement-Comparison-with-Mediapipe/main/move_comparison.py | `fastdtw(..., dist=cosine)` | github |
| https://raw.githubusercontent.com/jay2323-tech/ai-fitness-trainer/main/exercise_logic.py | Per-user min/max angle, `body_inclination_angle` | github |
| https://raw.githubusercontent.com/jackye426/vision-model/main/README.md | Per-person upright baseline from calibration photos | github |
| https://raw.githubusercontent.com/samiullahlashari911-lang/Ashrium/master/lib/widget/pose-gates.ts | Full capture gate: enter/hold thresholds, `RELAX_AFTER_MS 15000`, crown/sole estimates, loose band 0.55–0.98, "position counts", A-pose arm checks, motion 0.012/0.02 | github |
| https://raw.githubusercontent.com/aaronTibbetts/Tai-Chi-Repo/main/src/lib/calibration.ts | World-landmark T-pose (15°), `durationSec` 3, `computeProportions` limb lengths, assumed 60° HFOV intrinsics | github |
| https://raw.githubusercontent.com/forever8896/vibecheque/main/app/components/CalibrationGate.tsx | Torso 0.14–0.55, centre ±0.22, T-pose arm limits, `HOLD_FRAMES 25`, visibility 0.55/0.45 | github |
| https://raw.githubusercontent.com/JamesHardey/PoseDetection/main/ios/PoseDetection/BodyPositionChecker.swift | Vision full-body/posture/centre/feet prompts, "Perfect! Hold still..." | github |
| https://raw.githubusercontent.com/manavkapur/PhysiqueProgress/main/PhysiqueProgress/Core/Validation/FullBodyValidator.swift | 9 required Vision joints ≥ 0.3, "Step back and include feet." | github |
| https://raw.githubusercontent.com/hgao168/runform-coach-ai/master/ios/RunFormCoachAI/LiveGuidanceRecorderView.swift | Body span 0.42–0.82, hip centre 0.35–0.65, "Camera too low… hip height", Y-plane luma < 0.22 low light | github |
| https://raw.githubusercontent.com/AriesHongHuanWu/aicam/main/App/Sources/Coach/FrameAnalyzer.swift | `motionAngles`: roll `atan2(g.x,-g.y)`, pitch `atan2(g.z, hypot(g.x,g.y))`, front-camera sign flip | github |
| https://raw.githubusercontent.com/Neal-Kotval/Poser/main/Poser/Camera.swift | Gravity pitch/roll, "Tilt N° to level" unless `|roll| < 3` | github |
| https://raw.githubusercontent.com/emlavankhoahienma-hue/ai-smart-framing-camera/main/AISmartFramingCamera/ViewModels/CameraViewModel.swift | `isLowLightCondition` (luma < 0.28, ISO ≥ 450, exposure ≥ 0.033 s); level hysteresis 0.8°/1.3° | github |
| https://raw.githubusercontent.com/google-ai-edge/mediapipe/master/mediapipe/framework/formats/landmark.proto | Definitions of `visibility` (out of scene counts as invisible) and `presence` (within scene bounds) | github |

### Documentation and talks

| URL | What was read | Type |
|---|---|---|
| https://ai.google.dev/edge/mediapipe/solutions/vision/pose_landmarker | 33 landmarks, normalised + world (m, hip origin), visibility/presence, confidence options default 0.5, LIVE_STREAM drops frames | doc |
| https://developer.apple.com/documentation/coremotion/cmdevicemotion.md | gravity vs userAcceleration separation; attitude, rotationRate | doc |
| https://developer.apple.com/documentation/coremotion/cmdevicemotion/gravity.md | "gravity acceleration vector expressed in the device's reference frame" | doc |
| https://developer.apple.com/documentation/coremotion/cmattitude.md | roll/pitch/yaw in radians, rotation matrix, quaternion | doc |
| https://developer.apple.com/documentation/coremotion/getting-processed-device-motion-data.md | Reference frames, −π…π range, update intervals | doc |
| https://developer.apple.com/documentation/coremotion/cmmotionmanager.md | Device coordinate axes (figure) | doc |
| https://developer.apple.com/documentation/coremotion/cmacceleration.md | Units in g | doc |
| https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposuretargetoffset.md | EV offset definition, KVO | doc |
| https://developer.apple.com/documentation/avfoundation/avcapturedevice/iso.md | minISO…maxISO, "Higher values result in noisier images" | doc |
| https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposureduration.md | min…max exposure duration, KVO | doc |
| https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/videofieldofview.md | "the format's horizontal field of view in degrees" | doc |
| https://developer.apple.com/documentation/vision/vndetecthumanbodypose3drequest.md | 3D body points relative to the camera; uses depth if available | doc |
| https://developer.apple.com/documentation/vision/vnhumanbodypose3dobservation.md | Observation API overview | doc |
| https://developer.apple.com/documentation/vision/vnhumanbodypose3dobservation/bodyheight.md | Accurate only when `.measured`, else reference | doc |
| https://developer.apple.com/documentation/vision/vnhumanbodypose3dobservation/cameraoriginmatrix.md | "A transform from the skeleton hip to the camera" | doc |
| https://developer.apple.com/videos/play/wwdc2023/111241/ | WWDC23 *Explore 3D body pose and person segmentation in Vision* transcript: reference height 1.8 m, cameraOriginMatrix use | doc |
| https://developer.apple.com/documentation/uikit/uinotificationfeedbackgenerator.md | Notification haptics API | doc |
| https://www.ubisoft.com/en-us/game/just-dance/news-updates/2UBGhF4xWMLAVVFMmTCWwn/revolutionising-motion-gaming-the-camera-controller-feature | Camera Controller: smartphone camera, deep-learning 3D skeleton, ML scoring | doc |
| https://www.homecourt.ai/faq/setup | Tripod "at least 3-5 feet", well-lit, sideline placement | doc |

### Papers

| URL | What was read | Type |
|---|---|---|
| https://arxiv.org/abs/2006.10204 | BlazePose abstract (33 keypoints, > 30 FPS Pixel 2) | paper |
| https://arxiv.org/html/2006.10204v1 | Head-always-visible assumption, alignment parameters, occlusion augmentation, visibility classifier | paper |
| https://arxiv.org/abs/2206.11678 | BlazePose GHUM Holistic abstract (3D landmarks, monocular) | paper |
| https://arxiv.org/abs/2311.17105 | Gu et al., pose-confidence miscalibration; instance-size adjustment | paper |
| https://arxiv.org/abs/2502.09460 | MET-POSE abstract: metamorphic testing of MediaPipe Holistic | paper |
| https://arxiv.org/html/2502.09460 | Brightness/gamma/resolution/mirror rules and violation results | paper |
| https://arxiv.org/abs/2503.19917 | Dance sync analysis with 2D/3D pose: ankle and head heights during jumps drive the sync rate (so head and feet must stay in frame through jumps) | paper |

### YouTube

| URL | What was read | Type |
|---|---|---|
| https://www.youtube.com/watch?v=0QWBZChzuSI | *How to play JUST DANCE with a CAMERA* (Dina Just Dance), English transcript: horizontal phone, box + green bar, 1.5–2 m, 50–70 cm, lighting/clothes/face tips, one player | youtube |
| https://www.youtube.com/watch?v=QbBG9XJwKLI | *How to Use Just Dance Controller App (easy Method)* (Penrose Learning), transcript: waist-high, silhouette, step back/forward; contradictory "phone… in your hand" (weak source) | youtube |
