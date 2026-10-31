# Groove Coach course platform: design spec

Date: 2026-10-31. Status: approved. The owner's answers to §7 are in §8 (2026-10-31), and §8 wins wherever older text disagrees.
Code baseline: branch `nirvana-integrate/asl-features`. Every repo path below exists on that branch unless marked **(new)**.
Inputs: the four order reports (repo breakdown, learner-side references, authoring references, IMG_4941 breakdown). These are orchestration files, not repo files.

## 1. Goals and non-goals

Owner requirements, in the owner's words:

- "What if we dont use the app to create the corigraphy system but simply host the dance and the coriiphay and wew pose match with the camera of the learner"
- "I would like to start compositing videos that can eventually be built into a full course."
- "Before we continue with this build do a validation run … Once design spec is ironed out begin building."

**v1 goal.** One course, built from `IMG_4941.mov`, playable end to end on the owner's iPhone. The app downloads the lesson, plays the teacher video in teaching order (Segment A, B, C, D, then a full run), and pose-matches the learner's front camera. Playback starts slowed down and speeds up to 1.0x as the learner's takes improve (adaptive rate, §8 Q6). It scores every take and shows what to fix.

**Goals**
1. Authoring happens off the phone. A Python pipeline turns a video into a versioned **lesson package**: video, reference pose track, beat grid, 8-count segment cuts, tolerances, and occlusion and mirroring metadata.
2. The same extractor runs on both sides. MediaPipe PoseLandmarker (`pose_landmarker_full`, sha256-pinned in `ios/GrooveApp/Resources/fetch_pose_model.sh`) produces the reference on the server and the learner pose on the phone. Hands use MediaPipe HandLandmarker on both sides (§3.3).
3. The parity-tested scoring engine (`groove_eval/scoring.py` ↔ `ios/GrooveCore/Sources/GrooveCore/ScoringEngine.swift`) stays the grader.
4. Everything is validated on a real device with a real dancer before any further features are built.

**Non-goals for v1:** an in-app choreography editor; user-generated lessons; payments; Android; HLS/adaptive streaming; multi-person tracking; LLM coaching; leaderboards. The Calibrate tab (`ios/GrooveApp/Sources/PoseExporterApp.swift`) stays as a developer tool only.

## 2. Architecture

```
AUTHORING (owner's machine / Linux CI, Python)
 IMG_4941.mov ─► extract_pose (MediaPipe VIDEO mode, num_poses=1) ─► canonical skeleton ─► One Euro
             ├─► beat grid (Beat This! proposal → author-confirmed constant grid)
             ├─► lesson source file (segments, windows, names; hand-written)  ─► build_package ─► validate
             └─► debug overlay render (skeleton over video, owner eyeballs)
                                         │ publish_lesson.py (service key)
BACKEND (Supabase)                       ▼
 Postgres: courses, lessons, lesson_versions, attempts, profiles  |  Storage: lesson-packages (private)
                                         │ email-OTP JWT, REST + Storage GET
APP (iPhone)                             ▼
 LessonStore (download, sha256 verify, cache) ─► LessonPlayer (AVPlayer, beat grid, adaptive rate, mirror)
   └─► take: front camera ─► MediaPipe LIVE_STREAM (live limb colours + streak, not graded)
                          └─► recorded take ─► MediaPipe VIDEO mode ─► scoreAttempt vs sliced reference ─► results
```

### 2.1 Authoring pipeline

All new Python lives in `authoring/` **(new)**. It reuses `groove_eval` as a library and does not fork it.

| Step | Choice (license) | Alternative (license) | Notes |
|---|---|---|---|
| Pose | MediaPipe PoseLandmarker, Python, `VIDEO` mode, `num_poses=1` (Apache-2.0) | fairmotion, kinematics only (BSD-3) | `num_poses=1` drops the partial wall-mirror reflection. World landmarks make the 2–5 px handheld drift irrelevant. |
| Hands | MediaPipe HandLandmarker (Apache-2.0) | Apple Vision hands (Apple SDK, no Linux) | §3.3 |
| Beats | `groove_eval/audio_beats.py` (Beat This!) proposes; author confirms BPM + anchor | librosa `beat_track` (ISC) | The gym audio misleads the detectors (~106 BPM low-band, 112–120 onsets). The dancer is on **112.5 BPM, anchor 0.53 s**, so v1 stores a constant grid, `source: "author_confirmed"`. Beat This! license is not in the reports: verify it. Avoid madmom models (CC BY-NC-SA) and Essentia (AGPL-3.0). |
| Segments | Hand-authored 8-count cuts from the video breakdown, checked against `groove_eval/segmentation.py` hits | dance-bits-api (MIT, experimental) | One lesson does not justify an ML segmenter. |
| Tolerances | `computeJointTolerances` at score time (reference + golden takes) plus per-window scales | DTW radius clustering | One take means floor tolerances (R3). |
| Names / notes | Hand-written, seeded from the video breakdown | Gemini via `schemas/gemini_schemas.json` | **Drop Gemini for v1.** Its `move_tag` enum is house vocabulary (`down_bounce`, `house_jack`, `skate` …) with no namaste, thumka or shimmy. The model IDs in `config/groove_config.json` are unverified. This lesson's notes already exist and were reviewed by a human. Revisit around lesson 5 with a free-text schema. |

AIST++ is for internal eval only (research-only terms) and never ships in courses. The pipeline also renders `debug_overlay.mp4` **(new, build output, not in repo)**: skeleton over video, not published, for the owner to check before publishing.

### 2.2 Lesson package

**Storage layout** (Supabase Storage, not repo paths; immutable once published, and a new version means a new prefix):

```
lesson-packages/{course_slug}/{lesson_slug}/v{package_version}/
  manifest.json          # below
  video.mp4              # H.264/AAC, faststart, original timeline (not trimmed)
  reference_pose.json    # a GrooveScoringEngine.PoseClip, canonical skeleton, t = media seconds
  poster.jpg
```

`reference_pose.json` is deliberately the existing `PoseClip` Codable shape (`ScoringEngine.swift`, `scoring.py` loaders), so both engines read it unchanged. Coordinates are rounded to 4 decimals, which is about 1.1 MB for 490 frames. A packed Float32 track (from Chuyuyan/dance-trainer) is deferred until lessons run past ~60 s.

**manifest.json** (example for IMG_4941, abridged):

```json
{
  "schema": "groove.lesson/1",
  "lesson_id": "b6f1…", "course_slug": "bollywood-basics", "lesson_slug": "img4941-routine",
  "package_version": 1, "title": "Filmi Routine 1",
  "requires": { "engine_major": 2, "skeleton": "groove.canonical/1" },
  "extractor": {
    "pose_model": "pose_landmarker_full", "pose_model_sha256": "5134a3aa…11b1",
    "hand_model": "hand_landmarker", "hand_model_sha256": "<pinned in M2>",
    "mediapipe_python": "1.2.0", "running_mode": "VIDEO", "num_poses": 1
  },
  "video": { "file": "video.mp4", "duration_s": 16.33, "fps": 30, "width": 720, "height": 1280,
             "mirrored": false, "default_display_flip": true },
  "poster": "poster.jpg",
  "reference": { "file": "reference_pose.json", "frame_count": 490 },
  "beat_grid": { "bpm": 112.5, "anchor_s": 0.53, "source": "author_confirmed", "detector": "beat_this_small_cpu",
                 "beats": [ { "t": 0.53, "phrase": 1, "count": 1 }, { "t": 1.063, "phrase": 1, "count": 2 } ] },
  "segments": [
    { "id": "A", "title": "The Attitude Intro", "start_s": 0.53, "end_s": 4.80, "teach_order": 1, "difficulty": 2 },
    { "id": "B", "title": "Peek-a-Boo to Lateral Sweep", "start_s": 4.80, "end_s": 6.40, "teach_order": 2, "difficulty": 2 },
    { "id": "C", "title": "The Hook Groove", "start_s": 6.40, "end_s": 9.07, "teach_order": 3,
      "difficulty": 4, "focus": ["arms", "hips", "feet"],
      "cues": ["Heel-hip bounce on 5-6-7-8", "Wrists roll by the left shoulder"],
      "config_overrides": { "scoring_thresholds": { "gate": { "timing_source": "hits" } } } },
    { "id": "D", "title": "Shimmy, Crown Lotus and Finale", "start_s": 9.07, "end_s": 14.93, "teach_order": 4, "difficulty": 2 },
    { "id": "full", "kind": "full_run", "title": "Full Routine", "start_s": 0.53, "end_s": 14.93, "teach_order": 5 }
  ],
  "windows": [
    { "kind": "clasp", "start_s": 4.80, "end_s": 5.87, "mask": ["hand_shape"], "tolerance_scale": { "leftWrist": 2.0, "rightWrist": 2.0 } },
    { "kind": "clasp", "start_s": 12.75, "end_s": 13.65, "mask": ["hand_shape"], "tolerance_scale": { "leftWrist": 2.0, "rightWrist": 2.0 } }
  ],
  "config_overrides": { "scoring_thresholds": { "shape": { "arm_weight": 0.35 }, "groove": { "pass_min_score": 0 } } },
  "practice": { "count_in_beats": 4,
                "adaptive_speed": { "min_rate": 0.6, "start_rate": 0.7, "max_rate": 1.0, "step_up": 0.1, "step_down": 0.05,
                                    "promote_after": 2, "demote_after": 2, "unlock_next_at_rate": 0.8 } },
  "files": { "video.mp4": "<sha256>", "reference_pose.json": "<sha256>", "poster.jpg": "<sha256>" }
}
```

The full example is `fixtures/lessons/example_manifest.json`. A segment may carry its own `adaptive_speed`, which replaces `practice.adaptive_speed` for that segment. Segment D ends on beat 27 (14.93 s), not at 14.80 s where the dancing ends, because 14.80 s is 130 ms off the beat grid.

JSON Schema `schemas/lesson_package.schema.json` **(new)** describes the structure. `groove_eval/lesson_package.validate_manifest` checks that schema with a stdlib validator, because linux-ci has no `jsonschema`. It then checks these rules:
- `schema` is const `groove.lesson/1`; `package_version` is an integer ≥1.
- Every window lies inside `[0, duration_s]`, and segment boundaries sit within ±40 ms of a beat.
- `beats[].t` is strictly increasing; `pose_model_sha256` matches `^[0-9a-f]{64}$`.
- `files` covers the whole prefix.
- `config_overrides` keys exist in `config/groove_config.json` with the same JSON type, or are one of the two new config keys in §3.2: `shape.arm_weight` and `gate.timing_source`. (`windows`, the third §3.2 addition, is a manifest field.)
- Segment ids are unique, and `teach_order` runs 1..N: A, B, C, D, full.
- In every `adaptive_speed`: `0.5 ≤ min_rate ≤ start_rate ≤ max_rate ≤ 1.0`, and `min_rate ≤ unlock_next_at_rate ≤ max_rate`.

**Versioning.** `schema` changes only on a breaking format change. `package_version` increments on every republish, including tuning-only ones. Published prefixes are never overwritten. If `requires.engine_major` or `pose_model_sha256` differs from what the app bundles, the app plays the lesson but refuses to grade it ("update the app"): poses from different models are never compared.

**Mirroring.** The video is non-mirrored, so the dancer's right is on screen-left. By default the app flips the video. A learner copying it like a mirror then uses the *same anatomical side* as the teacher, and scoring runs with `mirrored=false`. With the "as filmed" toggle the learner uses the opposite side, so scoring runs with `mirrored=true` (existing `MIRROR_SWAP_PAIRS` / `swapMirrored`). The selfie preview is mirrored for display only. MediaPipe always sees the unflipped buffer.

### 2.3 Backend (Supabase)

Choice: Supabase, Postgres + Auth + Storage (Apache-2.0). Alternative: plain S3 + a static manifest. The package is self-contained files, so moving hosts later means changing one URL. Supabase is chosen for auth and progress, not for the packages themselves.

Tables (`supabase/migrations/0001_init.sql` **(new)**):

| Table | Key columns |
|---|---|
| `profiles` | `id uuid pk → auth.users`, `role text check (role in ('learner','author'))` |
| `courses` | `id`, `slug unique`, `title`, `status ('draft','published')`, `created_by` |
| `lessons` | `id`, `course_id fk`, `slug`, `title`, `position int`, `status` |
| `lesson_versions` | `id`, `lesson_id fk`, `package_version int`, `storage_prefix text`, `manifest jsonb`, `pose_model_sha256 text`, `published_at`; `unique(lesson_id, package_version)` |
| `attempts` | `id`, `user_id`, `lesson_version_id`, `segment_id`, `speed numeric`, `mirrored bool`, `passed bool`, `scores jsonb`, `created_at` (summaries only, never video) |

View `catalog`: published courses → lessons → latest published `lesson_versions` row.

**RLS sketch**
- `is_author()` is a `security definer` check on `profiles.role` for `auth.uid()`.
- `courses`, `lessons`, `lesson_versions`: `authenticated` may select where `status='published' or is_author()`; writes require `is_author()`.
- `attempts`: select/insert `using (user_id = auth.uid())`; no update or delete.
- Bucket `lesson-packages` is private. `authenticated` may select an object when a published `storage_prefix` prefixes its `name`. Clients never write; `scripts/publish_lesson.py` **(new)** uses the service key.
- `anon` gets nothing.

**Auth:** email OTP (6-digit code), so no deep links and no Sign in with Apple capability. Plain `URLSession` covers five endpoints (OTP send, OTP verify, token refresh, `catalog` select, storage GET), which keeps an SDK out of the CocoaPods build.

### 2.4 App

- **Cache.** `LessonStore` **(new)** replaces the reference half of `ios/GrooveApp/Sources/GrooveLibrary.swift`.
  - On-device location (device path, not repo): `Application Support/Lessons/{lesson_id}/v{n}/`, excluded from backup.
  - Files download to a temp directory, are sha256-verified against `manifest.files`, then renamed into place atomically. The previous version stays until the new one verifies.
  - The catalog is cached for offline launch. `GrooveLibrary` keeps calibration clips and the bundled config.
- **Player.** `AVPlayer` with `automaticallyWaitsToMinimizeStalling = false`.
  - 4 count-in clicks (existing `Metronome.swift`) play over the paused frame.
  - Then `setRate(rate, time: segment.start_s, atHostTime:)` starts the video on the host clock. That gives the take an exact host-time → media-time map, replacing the metronome-only timeline in `PracticeView.swift`.
  - Boundary time observers on `beat_grid` drive a "1 … 8" counter. Segment loops seek back to the start.
- **Adaptive rate (§8 Q6).** Each take plays at the rate that `next_rate(policy, history)` returns for its segment.
  - A segment starts at `start_rate` (0.7x). After a run of passing or failing takes, the rate moves up or down one step, within `[min_rate, 1.0]`.
  - Playback uses a pitch-preserving `audioTimePitchAlgorithm`.
  - Grading stays in wall-clock time. The reference slice is rebased to the segment start and then stretched (`t/rate`, `bpm·rate`, `speed_pct = round(100·rate)`). So `scoreAttempt` and its ms thresholds are unchanged at any rate.
  - The learner can override the offered rate. A take at another rate moves the ladder to that rate.
- **Live vs post-take.** The **post-take score is authoritative.** The recorded take is re-extracted in MediaPipe `VIDEO` mode and scored with `scoreAttempt`. That is today's "Analyzing take…" flow and stays on the parity-tested path; segments are 1.6–5.7 s, so it is quick. **Live** runs MediaPipe `LIVE_STREAM` at ≥15 fps only for limb colours and a streak meter, and is never graded.
- **Latency.** `audio_latency_ms` comes from `Metronome.outputLatencyMs`. A one-time clap check uses the existing `verifyClapSync`. Bluetooth routes get a warning.

## 3. Scoring migration

### 3.1 Vision 3D → canonical skeleton `groove.canonical/1`

The canonical skeleton **keeps today's joint names and frame convention**: metres, root-relative, +x right, +y up, +z toward the viewer (the convention stated in `groove_eval/joint_tolerance.py`). Because of that, scoring code, fixtures and correction hints do not change.

The mapper (`groove_eval/canonical_skeleton.py` **(new)**, `ios/GrooveCore/Sources/GrooveCore/CanonicalSkeleton.swift` **(new)**) converts MediaPipe world landmarks (hip-centred metres):

| Canonical | MediaPipe |
|---|---|
| `leftShoulder/rightShoulder`, `leftElbow/rightElbow`, `leftWrist/rightWrist` | 11/12, 13/14, 15/16 |
| `leftHip/rightHip`, `leftKnee/rightKnee`, `leftAnkle/rightAnkle` | 23/24, 25/26, 27/28 |
| `leftHeel/rightHeel`, `leftFootIndex/rightFootIndex` | 29/30, 31/32 (indices already used in `FootKeypointProvider.swift`) |
| `root` | midpoint 23–24 (synthesized) |
| `centerShoulder` | midpoint 11–12 (synthesized) |
| `spine` | midpoint of root and centerShoulder (synthesized) |
| `nose` (new, display only) | 0 |

- Axis signs: the mapper flips MediaPipe's image-aligned y (down) and depth sign into the repo convention. A fixture test pins this: a raised wrist has y above its shoulder.
- `confidences` = landmark visibility.
- Hands attach to the **nearest pose wrist**, not by the handedness label. That avoids left/right swaps in the 6.40–8.90 s churn.

Vision is then removed: the 3D request from `PoseExporterApp.swift` (`VideoPoseExtractor`), the 2D and hand requests from `PracticeCamera.swift` and `HandPoseExtractor.swift`, and the ankle anchoring in `FootKeypointProvider.swift`. The `models` block of `config/groove_config.json` is renamed to the MediaPipe models.

**Kept as-is:** `OneEuroFilter.swift`/`one_euro.py`, `MoveSegmenter.swift`/`segmentation.py`, `JointTolerance.swift`/`joint_tolerance.py`, `HandStyling.swift`/`hand_styling.py` (already the 21-point MediaPipe order), `GestureRecognizer.swift`, the gravity correction, and the parity gate `scripts/check_parity.py` with `.github/workflows/linux-ci.yml`.

### 3.2 Engine changes this lesson needs

The engine is tuned for house bounces, and this routine is arm-led. Evidence from the code:
- `detectTurnaroundTimes` finds each beat from `mean_knee_flex − 40·hip_height_norm`. When the signal range is under 3, it returns a Miss. The namaste, sweep and crown-clasp counts have no knee bounce, so they would score as Misses and fail the 0.80 timing gate.
- The shape score's `jointKeys` are knees, spine, hips and feet only. Arms appear only in joint verdicts and hints.

Three additions are needed, each defaulting to today's behaviour:

1. **`shape.arm_weight` (default 0).** A shape term built from **torso-frame unit bone vectors** (Chuyuyan/dance-trainer, Mimeflow).
   - It covers four bones: upper arm and forearm on each side.
   - The torso frame is Gram-Schmidt on hip left→right and root→centerShoulder.
   - Error is the angle between learner and reference bone directions at the existing −0.12/0/+0.12 s samples per beat.
   - Weights renormalize when `arm_weight > 0`.
   - Why vectors and not more joint angles: an elbow at 90° by the ear (ear flick) and at 90° in front of the chest (gather) have the same angle but different directions. The torso frame also cancels the dancer's torso yaw in the churn.
2. **`gate.timing_source` ∈ {`bounce`, `hits`} (default `bounce`).** With `hits`, the timing gate uses the existing settle-after-move `hit_timing` (wrists and feet), and bounce timing becomes informational.
3. **`windows`.** Per-window masks (`hand_shape`) and per-joint tolerance scales for the two clasp windows where the hands merge.

Lesson and segment `config_overrides` are deep-merged over the bundled config **before decoding**, by matching code in `scoring.py`, `ScoringEngine.swift` and `ios/GrooveCore/Sources/GrooveScoreCLI/main.swift`. This lesson relaxes the knee-flex groove gate by override (`groove.pass_min_score: 0`), not by a code change.

**Adopted from the gap table:**
- Torso-frame bone vectors (above).
- Eased lag window (lag += (best − lag)·0.08, 0–400 ms), **live only**, in `LiveMatcher.swift` **(new)**. It is Swift-only because it is never graded.
- 8-count phrase cuts.
- 0.5x slow-mo replay of the weakest beat range, teacher and take side by side (funfun-run).
- Live streak meter (Mimeflow).

**Rejected:** DTW for grading, because it would absorb the very timing error being graded, and per-beat alignment already exists. Extremity weighting waits for tuning data.

### 3.3 Hands: MediaPipe on both sides

The reference is extracted on Linux, which has no Vision. Matching hand shapes with the same extractor therefore means MediaPipe HandLandmarker on both sides, pinned by sha256 next to the pose model. On the phone, hands run only in the post-take pass.

### 3.4 Parity gate and fixtures re-baseline

- `fixtures/golden_clips.json` and `fixtures/feature_clips.json` are synthetic and already use canonical names and convention. With the new keys defaulting to no-ops, **every existing entry in `fixtures/expected_scores_snapshot.json` must stay byte-identical**. That is the migration's main acceptance check.
- New cases live in `fixtures/lesson_clips.json` **(new)**, generated by `groove_eval/generate_lesson_clips.py` **(new)** and added to `DATASETS` in `scripts/check_parity.py`:
  - wrong arm direction with the same elbow angle
  - arm-only hits timing
  - clasp masks
  - 0.75x stretch
- Mapper parity: both sides map `fixtures/mediapipe_sample_frames.json` **(new, real MediaPipe output for IMG_4941 frames)** to identical frames.
- Any change to an existing snapshot entry is its own `rebaseline:` commit, with the per-key diff in the message.
- Real-data fixtures (`fixtures/img4941_reference.json` **(new)**, session takes) land only after Q1, and stay outside exact parity until thresholds settle.

## 4. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | iOS and Python MediaPipe outputs differ (versions, GPU vs CPU delegate) | Pin sha256s, record versions, run V2, fall back to the CPU delegate. |
| R2 | Engine still bounce-biased for arm moves | §3.2 keys; V4 sets weights per segment. |
| R3 | One reference take means floor tolerances (`position_floor` 0.06 m, `angle_floor_deg` 8), which are too strict | Lesson tolerance scale; 2–3 golden takes (Q3). |
| R4 | Hands fail in the clasps or swap in the churn | Window masks; nearest-wrist hand assignment. |
| R5 | Live MediaPipe + playback + recording runs hot or drops frames | Live at 15 fps, off the graded path, can be switched off. |
| R6 | Audio/video latency, Bluetooth especially | `setRate(atHostTime:)`, output latency, clap check, route warning. |
| R7 | At 0.75x, hit energy falls below `moving_threshold` | Tune; per-speed override. |
| R8 | CocoaPods sunset; a silent MediaPipe link failure compiles `canImport` code out | CI checks symbols with nm (MediaPipe present, Vision 3D absent) and both models bundled. |
| R9 | Rights to host IMG_4941 | Private, owner-only until Q1; video never in git. |
| R10 | 7-day free-profile expiry; Python/Swift duplication | Q5. Authoring stays Python-only and LiveMatcher Swift-only. |

## 5. Validation plan

- **V1, authoring (CI plus receipt):**
  - Body coverage ≥0.95 and feet ≥0.90 in 0.53–14.80 s.
  - Reference vs itself passes every segment with shape ≥95.
  - Shifting by +150 ms fails timing.
  - A left/right-swapped copy fails shape on Segment A (the asymmetric ear flick).
  - Owner approves the overlay.
- **V2, cross-extractor (device):** device `VIDEO`-mode frames of IMG_4941 vs the server track. Pass: mean per-joint distance ≤2 cm (proposed bar) and shape ≥95.
- **V3, sync (device):** clap-on-beat |offset| ≤40 ms on the speaker at 1.0x, at `start_rate` (0.7x) and at `min_rate` (0.6x).
- **V4, first on-device tuning session** (owner and dancer, ~90 min):
  - Setup: portrait at waist height, 2.5–3 m away, full body in frame, even light.
  - Run V2 and V3 first.
  - Per segment in teaching order (A, B, C, D), record 3 good-faith takes at each of two pinned rates, 0.7x (`start_rate`) and 1.0x. Also record deliberate errors: half a beat late, wrong arm side, half-amplitude arms, standing still, partly out of frame. Rates stay pinned so pass rates compare.
  - Then run one segment with the adaptive policy on, and log every offered rate.
  - Export the attempt bundles via the share sheet. `groove_eval/tune_report.py` **(new)** prints pass rates and suggested threshold moves.
  - **Exit:** ≥2 of 3 good-faith takes pass per segment and rate. Every deliberate error fails with the right `top_issue`. Live and graded agree on the worst limb in ≥4 of 5 takes. The adaptive run reaches `unlock_next_at_rate` within 6 good-faith takes.
  - Tuned values ship as `config_overrides` in package v2, so the global config and parity snapshot stay put. Policy changes, such as a different `start_rate`, ship in v2 as per-segment `adaptive_speed`. A receipt records the session.

## 6. Build plan

Fixed interfaces, so parallel orders can code against them:
- the manifest (§2.2)
- `to_canonical(world_landmarks[33], visibility[33], hands?) -> RawPoseFrame`
- `PoseProvider { extract(videoURL:) async throws -> [RawPoseFrame]; live(_:hostTime:) -> RawPoseFrame? }`
- `LiveMatcher.update(frame:mediaTime:) -> LiveState{limbs, streak}`

Notes on the tables:
- Bare `.swift` names sit in `ios/GrooveApp/Sources/` (app) or `ios/GrooveCore/Sources/GrooveCore/` and `ios/GrooveCore/Tests/GrooveCoreTests/` (core), as cited above.
- `owns:` sets are disjoint within a milestone; later milestones may re-own files.
- Size: S ≤1 day, M 1–3 days, L 3–5 days of agent work.

**M0: Contracts (1 order)**

| Order | owns | Accept | Size |
|---|---|---|---|
| WO-0 contracts | `schemas/lesson_package.schema.json`, `groove_eval/canonical_skeleton.py`, `groove_eval/lesson_package.py` (load, validate, slice, stretch), `tests/test_canonical_skeleton.py`, `tests/test_lesson_package.py`, `fixtures/lessons/example_manifest.json`, `fixtures/mediapipe_sample_frames.json` (all new) | Example validates. Axis-sign, synthesized-joint, nearest-wrist and slice/stretch tests pass. linux-ci green. | M |

**M1: Foundations (5 parallel orders)**

| Order | owns | Accept | Size |
|---|---|---|---|
| WO-1A swift-contracts | `CanonicalSkeleton.swift`, `LessonPackage.swift`, `CanonicalSkeletonTests.swift`, `LessonPackageTests.swift` (core, all new) | Canonical frames match Python on the sample fixture. Example manifest decodes. Slice boundaries match Python. | M |
| WO-1B scoring-ext | `groove_eval/scoring.py`, `ScoringEngine.swift`, `ScoringFeatures.swift`, `ios/GrooveCore/Sources/GrooveScoreCLI/main.swift`, `scripts/check_parity.py`, `config/groove_config.json`, `fixtures/expected_scores_snapshot.json`, `fixtures/lesson_clips.json` (new), `groove_eval/generate_lesson_clips.py` (new), `tests/test_scoring.py`, `tests/test_scoring_features.py`, `ScoringEngineTests.swift`, `ScoringFeaturesTests.swift` | Existing snapshot entries byte-identical. The 4 new cases behave as in §3.4. Same deep-merge in all three consumers. Exact parity in linux-ci. | L |
| WO-1C authoring | `authoring/` (new: `extract_pose.py`, `beat_grid.py`, `build_package.py`, `render_overlay.py`, `requirements.txt`, `lessons/img4941.lesson.json`), `tests/test_authoring.py` (new) | CI tests on synthetic frames. Manual receipt on IMG_4941: the package validates and V1 passes. | L |
| WO-1D backend | `supabase/` (new: `migrations/0001_init.sql`, `config.toml`, `tests/rls.sql`), `scripts/publish_lesson.py` (new), `tests/test_publish_lesson.py` (new) | Migration applies locally. RLS: anon reads nothing; learners read published only, cannot write lessons, and see only their own attempts. Publish checks sha256 and refuses an existing version. | M |
| WO-1E app-lessons | `LessonStore.swift`, `SupabaseClient.swift`, `LessonPlayerView.swift`, `CourseListView.swift` (app, all new), `PoseExporterApp.swift` (tab wiring only) | IPA builds. On device: OTP login, download, segment loop at 1.0x/0.75x with pitch kept, flip toggle, counter on the beat, offline replay from cache, a corrupt file is re-fetched. Uses a stub manifest URL until 1D lands. | L |

**M2: Learner capture and grading (4 parallel orders)**

| Order | owns | Accept | Size |
|---|---|---|---|
| WO-2A mediapipe-extractor | `MediaPipePoseProvider.swift` (new), `FootKeypointProvider.swift` (delete), `HandPoseExtractor.swift`, `PoseExporterApp.swift`, `PracticeCamera.swift`, `ios/GrooveApp/Resources/fetch_pose_model.sh`, `ios/GrooveApp/project.yml`, `ios/GrooveApp/Podfile`, `ios/GrooveApp/Podfile.lock` | No Vision body/hand requests remain. Hand model pinned. V2 passes. Live ≥15 fps for 60 s. | L |
| WO-2B practice-flow | `PracticeView.swift`, `Metronome.swift`, `GrooveLibrary.swift`, `FeedbackViews.swift`, `AttemptExport.swift` (new) | `setRate(atHostTime:)` take. Correct slice and stretch at 0.75x. Mirror semantics as §2.2. Attempt bundle export. V3 passes. | L |
| WO-2C live-matcher | `LiveMatcher.swift`, `LiveMatcherTests.swift` (core, new) | A constant 200 ms lag converges within 2 s, a wrong arm turns red, the streak resets on a miss. Runs in linux-ci. | S |
| WO-2D ci-link-proof | `.github/workflows/ios-sideload-ipa.yml`, `.github/workflows/ios-testflight.yml` | Build fails if MediaPipe symbols are missing, Vision 3D symbols are present, or a `.task` model is not bundled. | S |

**M3: First lesson and tuning (2 parallel orders, then the session)**

| Order | owns | Accept | Size |
|---|---|---|---|
| WO-3A publish-img4941 | `authoring/lessons/img4941.lesson.json` (from 1C), `fixtures/img4941_reference.json` (new, only if Q1 allows) | v1 published; all 4 segments plus the full run play on the phone. | S |
| WO-3B tune-report | `groove_eval/tune_report.py`, `tests/test_tune_report.py` (new) | Synthetic bundles produce correct pass rates and suggestions. | M |
| Session V4 | owner + orchestrator | §5 exit met; package v2 published; receipt. | — |

**M4: Feedback and course flow (3 parallel orders)**

| Order | owns | Accept | Size |
|---|---|---|---|
| WO-4A replay-streak | `FeedbackViews.swift`, `ReplayView.swift` (new) | 0.5x side-by-side replay of the weakest beats; live streak meter. | M |
| WO-4B progress-sync | `ProgressSync.swift` (new), `supabase/migrations/0002_progress.sql` (new) | Attempts upload online and queue offline; RLS holds. | S |
| WO-4C course-flow | `CourseListView.swift`, `LessonPlayerView.swift` (from 1E), `AdaptiveSpeed.swift`, `AdaptiveSpeedTests.swift` (core, new: Swift port of `next_rate`) | Order A→B→C→D→full, read from `teach_order`. Each segment starts at its policy's `start_rate` and follows `next_rate`; the Swift port matches the vectors in `tests/test_lesson_package.py`. The next segment unlocks after one pass at or above `unlock_next_at_rate`; 1.0x is never required to unlock. Take history is kept per lesson version and segment. | M |

## 7. Open questions for the owner

1. **Rights:** has the dancer agreed to IMG_4941 being hosted, and will the course ever be public? *Recommend:* private and owner-only in v1, with no IMG_4941 pose data in git until you confirm.
2. **Default view:** flipped (mirror) teacher video, or as filmed? *Recommend:* flipped, with an "as filmed" toggle.
3. **Extra takes:** can the dancer record 2–3 more clean takes from the same spot, with the phone on a stand? *Recommend:* yes. It is the cheapest fix for over-strict tolerances (R3) and removes the handheld drift.
4. **Teaching order:** C (the hook) first, then A, B, D, full? *Recommend:* yes, and let V4 data reorder it.
5. **Distribution:** paid Apple Developer account (TestFlight), or Sideloadly re-signed every 7 days? *Recommend:* pay before V4 if more than one phone is involved; otherwise Sideloadly.
6. **Pass bar:** should segments gate progress? *Recommend:* unlock the next segment after one 0.75x pass, and never gate the 1.0x run.

## 8. Owner decisions (2026-10-31)

The owner answered §7 on 2026-10-31. Quoted as given:

> "This is internal tested and yes, 2 proabbly flipped the phone will be facing you. 3. no and the point is to extrapolate the body. I saw some hugging face models be able to extrapolate as well so maybe runa research run with agy to validate. 4. no go in order. 5 dieloadly for now. for the gating progress be intelegent maybe a slowewd down version as the app access your improvements it goes faster."

These decisions override older text in §1–§6. Where a line still mentions 0.75x, a C-first order or extra takes (for example §3.4 "0.75x stretch", R3, R7, WO-1E, WO-2B), read it as: a stretch at any policy rate, the A→D order, and a single take.

**Q1, rights.** IMG_4941 is internal test footage, and the dancer has agreed. The `lesson-packages` bucket stays private. Pose data derived from IMG_4941 **may** go in git. The first such file is `fixtures/mediapipe_sample_frames.json`, and `fixtures/img4941_reference.json` (WO-3A) is allowed. The video itself stays out of git.

**Q2, default view.** As recommended in §2.2: the teacher video is flipped (mirror) by default, the phone faces the learner, and an "as filmed" toggle is available.

**Q3, extra takes.** No more takes. The goal is to *extrapolate the body* from the single take. A separate research order (body-extrapolation) will study 3D body recovery and retargeting. It covers single-take tolerances (R3) and differences between the dancer's and the learner's proportions. It is not designed here. The contract stays open for it:
- Canonical frames (§3.1) are plain root-relative Cartesian joint positions in metres. They come with a fixed bone tree, `CANONICAL_BONES` in `groove_eval/canonical_skeleton.py`.
- A later retarget step of the shape `canonical frame → canonical frame` (for example, bone-length normalization to the learner's `bone_lengths`) can run between the reference and the learner. It needs no change to the mapper, the manifest or the scoring engine.
- The mapper does no per-person scaling, and `requires.skeleton` stays `groove.canonical/1`. If the research order adds a retargeted reference later, it will need an optional new manifest field.

**Q4, teaching order.** Go in order: A → B → C → D → full. In the manifest that is `teach_order` 1–5, with the full run as a segment of `"kind": "full_run"`.

**Q5, distribution.** Sideloadly for now (`.github/workflows/ios-sideload-ipa.yml`), re-signed every 7 days. TestFlight waits until more than one phone is involved.

**Q6, gating: adaptive speed.** Fixed 0.75x and 1.0x gates are replaced by a playback-rate policy, `practice.adaptive_speed`, which a segment can override with its own `adaptive_speed`. The app starts each segment slowed down and speeds it up as the learner's takes improve.
- The policy is a pure function, `next_rate(policy, history) -> (rate, unlocked)` in `groove_eval/lesson_package.py`. It replays the segment's takes from `start_rate`:
  - `promote_after` consecutive passes step the rate up by `step_up`;
  - `demote_after` consecutive fails step it down by `step_down`;
  - rates are clamped to `[min_rate, max_rate]` and rounded to 0.01;
  - a take at a rate the learner chose moves the ladder to that rate and restarts both streaks.
- The next segment unlocks after one passing take at a rate of at least `unlock_next_at_rate`, and stays unlocked. 1.0x is never required to unlock.
- `slice_reference` and `stretch` accept any rate in `[min_rate, max_rate]`, or `[0.5, 1.0]` without a policy. Scoring at rate r uses `t/r` and `bpm·r` (§2.4).
- The Swift port of `next_rate` comes in M1 (WO-1A, `LessonPackage.swift`) and is used by WO-4C.

| Key | Default | Why |
|---|---|---|
| `min_rate` | 0.6 | The floor. At 0.6x, 112.5 BPM becomes 67.5 BPM, which still feels like a pulse. Below 0.6, pitch-preserved audio smears, and hit energy drops further under `moving_threshold` (R7: velocity scales with rate). The schema's hard floor is 0.5, the lowest AVPlayer rate we would ship. |
| `start_rate` | 0.7 | Slow enough for arm-led vocabulary that is new to the learner. It sits one `step_down` above the floor, so a struggling learner still has a slower rung. |
| `max_rate` | 1.0 | The dancer's tempo. Faster than 1.0 is not a learning aid. |
| `step_up` | 0.1 | Three promotions take the learner from 0.7 to 1.0. That is at least 6 passing takes, which is 1–4 minutes for 1.6–5.9 s segments. |
| `step_down` | 0.05 | Half of `step_up`, so a bad pair of takes costs less progress than a good pair earns. This avoids bouncing between rungs. |
| `promote_after` | 2 | Two passes in a row show consistency, not luck. This matches the V4 bar of ≥2 of 3 good-faith takes. |
| `demote_after` | 2 | One failed take is normal noise, so it does not slow the learner down. |
| `unlock_next_at_rate` | 0.8 | Replaces §7's "one 0.75x pass". The learner must have been promoted once (two passes at 0.7) and then pass at 0.8. Learners keep moving through the course while 1.0x stays a goal. |

**Contract notes from WO-0 (2026-10-31).**
- **Axes.** The mapper keeps MediaPipe's x and flips y and z: `(x, y, z) → (x, −y, −z)`, the same flip as `visionAxes` in `FootKeypointProvider.swift`. On a camera-facing dancer, +x is image right, which is the dancer's left. +z points toward the camera. This is a proper rotation, so `HandStyling` palm normals keep their meaning. The synthetic golden and feature fixtures place `leftHip` at −x, as if the dancer were seen from behind. That is harmless because both sides of a comparison go through the same mapper. It does mean the left/right words in `joint_tolerance` hints are camera-relative for real data. WO-1B or WO-2B should phrase those hints for the learner's view.
- **Confidences** are the visibility values, clamped to [0, 1]. A synthesized joint takes the minimum visibility of its sources.
- **Hands.** HandLandmarker results are assigned to the nearest pose wrist in pixel space (normalized x scaled by width/height), never by the handedness label. With two or more hands, the pairing with the smallest total distance wins. Each hand is placed so that landmark 0 sits on its pose wrist.
- **Slicing.** A slice keeps frames within ±½ beat of the segment, rebased so t = 0 at `start_s`. It grades the beats in `[start_s − 40 ms, end_s − 40 ms)`, so a boundary beat is graded only once. With these rules A, B, C, D and full have 8, 3, 5, 11 and 27 graded beats.
- **Fixture.** `fixtures/mediapipe_sample_frames.json` holds real MediaPipe output, not a synthetic sample. It was produced with mediapipe 1.2.0 (Python, CPU delegate, `VIDEO` mode, `num_poses=1`) and `pose_landmarker_full`, sha256 `5134a3aa…11b1`. It covers 10 frames of IMG_4941 (video sha256 `0f8083f9…124e`), and `expected_canonical` is the parity target for the Swift mapper.
