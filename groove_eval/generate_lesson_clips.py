"""Generate synthetic lesson clips for the spec §3.2 engine additions and the body-extrapolation keys.

`fixtures/lesson_clips.json` has the `golden_clips.json` shape ({references, golden_clips}). A clip may carry
`config_overrides`, deep-merged over config/groove_config.json before scoring by `scripts/check_parity.py` and
groove-score-cli alike, so each case runs with the keys it exercises and the bundled config keeps every default.

Cases (112.5 BPM, the IMG_4941 tempo; 8 beats; 30 fps):
- arm direction: a 90-degree elbow by the ear vs the same 90 degrees in front of the chest. Passes with
  `shape.arm_weight` 0, fails shape with 0.35; the right direction passes with 0.35.
- arm-only hits: legs still, arms hit on the beat. The bounce gate fails (no turnarounds); `gate.timing_source: hits`
  passes on time and fails 140 ms late.
- clasp masks: the hands are held in a clasp; on counts 3-6 the learner's clasp sits lower and its hand landmarks
  read as fists. The reference windows come from a lesson manifest through `lesson_package.slice_reference`
  (`mask: [hand_shape]`, wrist and elbow `tolerance_scale`), or the occlusion wrist-distance rule finds the clasp.
- rate 0.7: the reference sliced and stretched by `lesson_package.stretch`, the learner dancing at 0.7x.
- retarget: a short teacher and a tall learner with longer arms, same bone directions. Joint verdicts flag the wrists
  without `retarget.enabled` and are clean with it (from the take's median or a calibration stance).
- velocity: continuous arm swings, learner arms 70 ms behind; `tolerance.velocity_scale` widens the fast beats.
- occlusion: learner wrist tracking drops (confidence 0.2, wrists off) on four counts; `tolerance.occlusion`
  widens or masks them.

Body: the down-bounce (or still) skeleton of `generate_golden_clips._synthesize_skeleton_frame`. Arms: upper arm and
forearm directions in the body frame (out, up, forward), blended between poses with a smoothstep over 0.18 s that
arrives on the beat, like `generate_feature_clips`.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

from groove_eval import lesson_package
from groove_eval.generate_feature_clips import _hand_points
from groove_eval.generate_golden_clips import _synthesize_skeleton_frame

Vec3 = Tuple[float, float, float]
ArmPose = Tuple[Vec3, Vec3]  # (upper-arm direction, forearm direction) as (out, up, forward)

BPM = 112.5
PERIOD = 60.0 / BPM
FPS = 30
N_BEATS = 8
MOVE_S = 0.18
UPPER_ARM_M = 0.28
FOREARM_M = 0.26

DOWN: ArmPose = ((0.15, -1.0, 0.0), (0.1, -1.0, 0.1))
OUT: ArmPose = ((1.0, 0.15, 0.0), (1.0, 0.25, 0.0))
EAR: ArmPose = ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0))  # elbow 90 deg, forearm up by the head
GATHER: ArmPose = ((0.0, 0.0, 1.0), (-1.0, 0.0, 0.0))  # elbow 90 deg, forearm across the chest
CLASP: ArmPose = ((0.25, -0.75, 0.6), (-1.0, 0.15, 0.3))  # wrists meet in front of the chest
CLASP_LOW: ArmPose = ((0.2, -0.95, 0.3), (-1.0, -0.35, 0.3))  # the learner's lower clasp

Keyframes = List[Tuple[float, ArmPose]]


def _unit(v: Sequence[float]) -> Vec3:
    n = math.sqrt(sum(c * c for c in v))
    return (v[0] / n, v[1] / n, v[2] / n)


def _smoothstep(x: float) -> float:
    x = max(0.0, min(1.0, x))
    return x * x * (3.0 - 2.0 * x)


def _blend(a: ArmPose, b: ArmPose, w: float) -> ArmPose:
    def mix(u: Vec3, v: Vec3) -> Vec3:
        uu, vv = _unit(u), _unit(v)
        return _unit(tuple((1.0 - w) * uu[k] + w * vv[k] for k in range(3)))  # type: ignore[arg-type]

    return mix(a[0], b[0]), mix(a[1], b[1])


def _pose_at(t: float, keys: Keyframes, initial: ArmPose = DOWN) -> ArmPose:
    """Hold the last pose reached; move to the next over MOVE_S so it arrives exactly at its keyframe time."""
    pose = initial
    for arrive, target in keys:
        if t >= arrive:
            pose = target
            continue
        if t > arrive - MOVE_S:
            return _blend(pose, target, _smoothstep((t - (arrive - MOVE_S)) / MOVE_S))
        return pose
    return pose


def _hit_keys(beats: Sequence[float], target: ArmPose, offset_s: float = 0.0) -> Keyframes:
    """Arms hit `target` on every count (+ offset), hold it 0.15 s, drop DOWN and come back for the next count.

    The pose on each beat is the same, so the reference's per-joint spread is zero and the tolerances sit on their
    floors (alternating poses would push the wrists to the tolerance ceiling and hide every flag)."""
    keys: Keyframes = []
    for b in beats:
        keys.append((b + offset_s, target))
        keys.append((b + offset_s + 0.15 + MOVE_S, DOWN))
    return keys


def _alt_keys(beats: Sequence[float], target: ArmPose, offset_s: float = 0.0) -> Keyframes:
    """Arms hit `target` on odd counts and drop back DOWN on even counts, holding a whole beat: clear settle-after-move
    hits for the hit-timing cases (the tolerances then come from two poses, so they are wide)."""
    return [(b + offset_s, target if k % 2 == 0 else DOWN) for k, b in enumerate(beats)]


def _body_frame(t_media: float, beats: Sequence[float], still: bool, body_scale: float) -> Dict[str, Any]:
    """The golden down-bounce on `beats` (bottom of the dip on each beat), or a still stance."""
    if still:
        return _synthesize_skeleton_frame(t_media, 6.0, 2.0, 3.0, 0.0, 0.0, body_scale=body_scale)
    phase = 2.0 * math.pi * ((t_media - beats[0]) / PERIOD)
    spine_phase = 2.0 * math.pi * ((t_media - 0.066 - beats[0]) / PERIOD)
    wave = 0.5 * (1.0 + math.cos(phase))
    spine_jack = 4.0 + 14.0 * 0.5 * (1.0 + math.cos(spine_phase))
    return _synthesize_skeleton_frame(
        t_media,
        8.0 + 34.0 * wave,
        spine_jack,
        6.0 + 0.35 * spine_jack,
        4.0 * math.cos(phase),
        -4.0 * math.cos(phase),
        body_scale=body_scale,
    )


def _attach_arms(
    frame: Dict[str, Any],
    pose: ArmPose,
    arm_scale: float,
    hand_shape: Optional[str],
    confidence: float = 0.98,
    wrist_shift: Vec3 = (0.0, 0.0, 0.0),
) -> None:
    """Elbows / wrists from a pose. The golden skeleton faces -z with leftHip at -x: out = -x on the left."""
    joints = frame["joints"]
    hands: Dict[str, List[List[float]]] = {}
    for side, out in (("left", -1.0), ("right", 1.0)):
        s = joints[side + "Shoulder"]
        u, f = pose
        ud = _unit((out * u[0], u[1], -u[2]))
        fd = _unit((out * f[0], f[1], -f[2]))
        elbow = tuple(s[k] + UPPER_ARM_M * arm_scale * ud[k] for k in range(3))
        wrist = tuple(elbow[k] + FOREARM_M * arm_scale * fd[k] + wrist_shift[k] for k in range(3))
        joints[side + "Elbow"] = [round(c, 6) for c in elbow]
        joints[side + "Wrist"] = [round(c, 6) for c in wrist]
        frame["confidences"][side + "Elbow"] = 0.98
        frame["confidences"][side + "Wrist"] = confidence
        if hand_shape is not None:
            hands[side] = _hand_points(wrist, hand_shape, is_left=(side == "left"), mirror=False)
    if hand_shape is not None:
        frame["hands"] = hands


def _clip(
    clip_id: str,
    move_tag: str,
    description: str,
    expected_pass: bool,
    beats: Sequence[float],
    arms: Callable[[float], ArmPose],
    *,
    still: bool = False,
    body_scale: float = 1.0,
    arm_scale: float = 1.0,
    rate: float = 1.0,
    body_offset_s: float = 0.0,
    arm_offset_s: float = 0.0,
    t_start: float = 0.0,
    t_end: Optional[float] = None,
    media_origin: float = 0.0,
    hands: Optional[Callable[[float], Optional[str]]] = None,
    wrist_dropout: Optional[Callable[[float], bool]] = None,
    config_overrides: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Frames at 30 fps over clip time [t_start, t_end]. Clip time c shows the body at media time
    media_origin + rate * (c - body_offset_s) and the arms at media_origin + rate * (c - arm_offset_s); `beats` are
    media times, and the clip's own beat_times are (b - media_origin) / rate."""
    end = t_end if t_end is not None else (beats[-1] - media_origin) / rate + PERIOD / rate
    frames = []
    for i in range(int(round((end - t_start) * FPS)) + 1):
        c = t_start + i / FPS
        body_t = media_origin + rate * (c - body_offset_s)
        arm_t = media_origin + rate * (c - arm_offset_s)
        frame = _body_frame(body_t, beats, still, body_scale)
        frame["t"] = round(c, 5)
        dropped = wrist_dropout is not None and wrist_dropout(arm_t)
        _attach_arms(
            frame,
            arms(arm_t),
            body_scale * arm_scale,
            hands(arm_t) if hands is not None else None,
            confidence=0.2 if dropped else 0.98,
            wrist_shift=(0.12, 0.0, 0.0) if dropped else (0.0, 0.0, 0.0),
        )
        frames.append(frame)
    clip: Dict[str, Any] = {
        "clip_id": clip_id,
        "move_tag": move_tag,
        "description": description,
        "bpm": BPM * rate,
        "beat_times": [round((b - media_origin) / rate, 5) for b in beats],
        "gravity_vector": [0.0, -1.0, 0.0],
        "mirrored": False,
        "audio_latency_ms": 0.0,
        "speed_pct": int(math.floor(rate * 100.0 + 0.5)),
        "expected": {"passed": expected_pass, "reason": description},
        "frames": frames,
    }
    if config_overrides:
        clip["config_overrides"] = config_overrides
    return clip


def _beats(first: float) -> List[float]:
    return [round(first + k * PERIOD, 5) for k in range(N_BEATS)]


def _overrides(**sections: Dict[str, Any]) -> Dict[str, Any]:
    return {"scoring_thresholds": sections}


def _manifest_stub(segment_id: str, beats: Sequence[float], windows: List[Dict[str, Any]]) -> Dict[str, Any]:
    """The manifest fields `lesson_package.slice_reference` reads (a full manifest also needs video, files, ...)."""
    return {
        "lesson_slug": "synthetic-lesson",
        "beat_grid": {"bpm": BPM, "beats": [{"t": b} for b in beats]},
        "segments": [{"id": segment_id, "start_s": beats[0], "end_s": round(beats[-1] + PERIOD, 5)}],
        "windows": windows,
    }


def _sliced(reference: Dict[str, Any], segment_id: str, beats: Sequence[float], windows: List[Dict[str, Any]]) -> Dict[str, Any]:
    clip = lesson_package.slice_reference(reference, _manifest_stub(segment_id, beats, windows), segment_id)
    clip["description"] = reference["description"]
    return clip


def generate_lesson_dataset() -> Dict[str, Any]:
    beats = _beats(0.5)
    refs: Dict[str, Dict[str, Any]] = {}
    clips: List[Dict[str, Any]] = []
    arm_on = _overrides(shape={"arm_weight": 0.35})

    # 1. Arm direction: same elbow angle, different bone directions.
    refs["arm_ear_flick"] = _clip(
        "ref_arm_ear_flick", "arm_ear_flick", "Reference: bounce, arms hit a 90-degree ear flick on every count",
        True, beats, lambda t: _pose_at(t, _hit_keys(beats, EAR)),
    )
    gather = dict(arms=lambda t: _pose_at(t, _hit_keys(beats, GATHER)), body_offset_s=0.006, arm_offset_s=0.006)
    clips.append(_clip("lesson_01_arm_gather_unweighted", "arm_ear_flick",
                       "Gather (90 deg in front of the chest) for an ear flick, arm_weight 0: angles agree, passes",
                       True, beats, **gather))
    clips.append(_clip("lesson_02_arm_gather_weighted", "arm_ear_flick",
                       "Same gather with arm_weight 0.35: torso-frame bone directions disagree, fails shape",
                       False, beats, config_overrides=arm_on, **gather))
    clips.append(_clip("lesson_03_arm_ear_flick_weighted", "arm_ear_flick",
                       "The right ear flick with arm_weight 0.35 passes", True, beats,
                       lambda t: _pose_at(t, _hit_keys(beats, EAR)), body_offset_s=0.006, arm_offset_s=0.012,
                       config_overrides=arm_on))

    # 2. Arm-only hits: no knee bounce, so the bounce gate has no turnarounds.
    refs["arm_only_hits"] = _clip(
        "ref_arm_only_hits", "arm_only_hits", "Reference: legs still, arms hit OUT on 1, 3, 5, 7", True, beats,
        lambda t: _pose_at(t, _alt_keys(beats, OUT)), still=True,
    )
    no_groove = {"pass_min_score": 0.0}
    clips.append(_clip("lesson_04_arm_only_bounce_gate", "arm_only_hits",
                       "Hits on the beat, bounce timing gate: every beat is a Miss, fails timing", False, beats,
                       lambda t: _pose_at(t, _alt_keys(beats, OUT, 0.01)), still=True,
                       config_overrides=_overrides(groove=no_groove)))
    clips.append(_clip("lesson_05_arm_only_hits_gate", "arm_only_hits",
                       "Hits on the beat, timing_source hits: passes", True, beats,
                       lambda t: _pose_at(t, _alt_keys(beats, OUT, 0.01)), still=True,
                       config_overrides=_overrides(groove=no_groove, gate={"timing_source": "hits"})))
    clips.append(_clip("lesson_06_arm_only_hits_late", "arm_only_hits",
                       "Hits 140 ms late, timing_source hits: fails timing", False, beats,
                       lambda t: _pose_at(t, _alt_keys(beats, OUT, 0.14)), still=True,
                       config_overrides=_overrides(groove=no_groove, gate={"timing_source": "hits"})))

    # 3. Clasp: the reference on a media timeline (first beat at 2.0 s), sliced through a lesson manifest.
    media = _beats(2.0)
    seg_beats = [round(b - media[0], 5) for b in media]
    w_start, w_end = round(media[2] - 0.2, 5), round(media[5] + 0.25, 5)
    in_clasp = lambda t: w_start <= t < w_end  # noqa: E731
    clasp_windows = [{
        "kind": "clasp", "start_s": w_start, "end_s": w_end,
        "mask": ["hand_shape"], "tolerance_scale": {"leftWrist": 3.0, "rightWrist": 3.0, "leftElbow": 2.0, "rightElbow": 2.0},
    }]
    clasp_full = _clip(
        "ref_clasp_media", "clasp", "Reference: bounce with the hands held in a clasp, open hands", True, media,
        lambda t: CLASP, hands=lambda t: "open", t_start=0.0,
    )
    refs["clasp"] = _sliced(clasp_full, "clasp", media, [])
    refs["clasp_windowed"] = _sliced(clasp_full, "clasp_windowed", media, clasp_windows)
    pad = 0.5 * PERIOD
    learner_clasp = dict(
        arms=lambda t: _pose_at(t, [(w_start + 0.1, CLASP_LOW), (w_end - 0.05, CLASP)], initial=CLASP),
        hands=lambda t: "fist" if in_clasp(t) else "open",
        media_origin=media[0], t_start=-pad, t_end=seg_beats[-1] + PERIOD + pad,
        body_offset_s=0.006, arm_offset_s=0.006,
    )
    clips.append(_clip("lesson_07_clasp_no_window", "clasp",
                       "Lower clasp with fist-like hand landmarks, no window: wrists flagged, hand score drops",
                       True, media, **learner_clasp))
    clips.append(_clip("lesson_08_clasp_window_mask", "clasp_windowed",
                       "Same take vs the windowed slice: hand_shape masked, wrist x3 / elbow x2 tolerances, clean verdicts",
                       True, media, **learner_clasp))
    clips.append(_clip("lesson_09_clasp_wrist_proximity", "clasp",
                       "Same take, no window, occlusion wrist_distance 0.1 x3: the clasp widens the wrists",
                       True, media,
                       config_overrides=_overrides(tolerance={"occlusion": {"wrist_distance": 0.1, "factor": 3.0}}),
                       **learner_clasp))

    # 4. Rate 0.7: slice + stretch the reference, the learner dances at 0.7x in wall-clock time.
    rate = 0.7
    hits_full = _clip(
        "ref_hits_media", "hits_rate", "Reference: bounce, arms hit OUT on 1, 3, 5, 7", True, media,
        lambda t: _pose_at(t, _alt_keys(media, OUT)), t_start=0.0,
    )
    refs["hits_rate_70"] = lesson_package.stretch(_sliced(hits_full, "hits_rate_70", media, []), rate)
    slow = dict(media_origin=media[0], rate=rate, t_start=-pad / rate, t_end=(seg_beats[-1] + PERIOD + pad) / rate)
    clips.append(_clip("lesson_10_rate70_clean", "hits_rate_70", "0.7x take on the slowed beat: passes", True, media,
                       lambda t: _pose_at(t, _alt_keys(media, OUT)), body_offset_s=0.008, arm_offset_s=0.01, **slow))
    clips.append(_clip("lesson_11_rate70_late", "hits_rate_70", "0.7x take 150 ms late: fails timing", False, media,
                       lambda t: _pose_at(t, _alt_keys(media, OUT)), body_offset_s=0.15, arm_offset_s=0.15, **slow))

    # 5. Retarget: short teacher, tall learner with relatively longer arms; same bone directions.
    refs["retarget_short"] = _clip(
        "ref_retarget_short", "retarget_short", "Reference: short dancer, bounce, arms hit OUT", True, beats,
        lambda t: _pose_at(t, _hit_keys(beats, OUT)), body_scale=0.9,
    )
    tall = dict(arms=lambda t: _pose_at(t, _hit_keys(beats, OUT)), body_scale=1.1, arm_scale=1.3,
                body_offset_s=0.006, arm_offset_s=0.006)
    retarget_on = _overrides(retarget={"enabled": True})
    clips.append(_clip("lesson_12_retarget_off", "retarget_short",
                       "Tall long-armed learner, same motion, no retarget: wrists flagged far out", True, beats, **tall))
    clips.append(_clip("lesson_13_retarget_on", "retarget_short",
                       "Same take with retarget (take median lengths): clean joint verdicts", True, beats,
                       config_overrides=retarget_on, **tall))
    calibrated = _clip("lesson_14_retarget_calibration", "retarget_short",
                       "Same take with retarget from a calibration stance: clean joint verdicts", True, beats,
                       config_overrides=retarget_on, **tall)
    stance = _clip("stance", "retarget_short", "calibration stance", True, beats, lambda t: DOWN, still=True,
                   body_scale=1.1, arm_scale=1.3, t_start=0.0, t_end=0.3)
    calibrated["calibration_frames"] = stance["frames"]
    clips.append(calibrated)

    # 6. Velocity: continuous arm swings, fastest on the beats; the learner's arms trail by 70 ms.
    def swing(t: float) -> ArmPose:
        theta = math.radians(60.0) * math.sin(math.pi * (t - beats[0]) / PERIOD)
        d = (0.2, -math.cos(theta), math.sin(theta))
        return d, d

    refs["arm_swing"] = _clip("ref_arm_swing", "arm_swing", "Reference: bounce with arms swinging through each beat",
                              True, beats, swing)
    trail = dict(arms=swing, body_offset_s=0.006, arm_offset_s=0.07)
    clips.append(_clip("lesson_15_velocity_off", "arm_swing",
                       "Arms 70 ms behind on fast swings, base tolerance: wrists flagged", True, beats, **trail))
    clips.append(_clip("lesson_16_velocity_scaled", "arm_swing",
                       "Same take, velocity_scale 0.5: fast beats get wider tolerances, clean verdicts", True, beats,
                       config_overrides=_overrides(tolerance={"velocity_scale": 0.5}), **trail))

    # 7. Occlusion: the learner's wrist tracking drops on counts 2, 4, 6, 8 (confidence 0.2, wrists 12 cm off).
    dropout = lambda t: any(abs(t - b) <= 0.2 for b in beats[1::2])  # noqa: E731
    refs["occlusion_hits"] = _clip("ref_occlusion_hits", "occlusion_hits", "Reference: bounce, arms hit OUT", True,
                                   beats, lambda t: _pose_at(t, _hit_keys(beats, OUT)))
    occ = dict(arms=lambda t: _pose_at(t, _hit_keys(beats, OUT)), wrist_dropout=dropout,
               body_offset_s=0.006, arm_offset_s=0.006)
    clips.append(_clip("lesson_17_occlusion_off", "occlusion_hits",
                       "Wrist dropouts on four counts, occlusion off: wrists flagged", True, beats, **occ))
    clips.append(_clip("lesson_18_occlusion_widened", "occlusion_hits",
                       "Same take, occlusion factor 3: low-confidence wrists widened, clean verdicts", True, beats,
                       config_overrides=_overrides(tolerance={"occlusion": {"factor": 3.0}}), **occ))
    clips.append(_clip("lesson_19_occlusion_masked", "occlusion_hits",
                       "Same take, occlusion mask: low-confidence wrist beats left out, clean verdicts", True, beats,
                       config_overrides=_overrides(tolerance={"occlusion": {"mask": True}}), **occ))

    return {"references": refs, "golden_clips": clips}


def main() -> None:
    out_file = Path(__file__).resolve().parent.parent / "fixtures" / "lesson_clips.json"
    dataset = generate_lesson_dataset()
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(dataset, f, separators=(",", ":"))
        f.write("\n")
    print(f"Generated {len(dataset['golden_clips'])} lesson clips in {out_file}")


if __name__ == "__main__":
    main()
