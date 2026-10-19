"""Universal clip-audio beat extraction & pose-JSON beat attachment for Groove Coach (M1).

Why clip-audio alignment is the primary M1 method:
- An in-app recorder only knows the beat clock for takes recorded inside the app.
- Imported reference videos, iPhone Camera-app clips, and the 20 real calibration clips all have music
  audible in their recorded audio track.
- Extracting the clip's audio on Linux CPU and running `Beat This!` (CPJKU, ISMIR 2024) produces
  `bpm` and `beat_times` in the clip's exact media timeline, guaranteeing one unified beat-alignment
  method across all video sources.
"""

from __future__ import annotations

import argparse
import json
import math
import shutil
import struct
import subprocess
import tempfile
import wave
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


def extract_wav_from_media(media_path: Path, target_wav: Path, sample_rate: int = 22050) -> Path:
    """Extract mono 16-bit PCM WAV from a video/audio file using ffmpeg if needed."""
    if media_path.suffix.lower() == ".wav":
        return media_path

    ffmpeg_bin = shutil.which("ffmpeg")
    if not ffmpeg_bin:
        raise RuntimeError(
            f"Cannot extract audio from {media_path}: 'ffmpeg' not found on PATH. "
            "Install ffmpeg (`sudo apt install ffmpeg`) or pass a .wav file."
        )

    subprocess.run(
        [
            ffmpeg_bin,
            "-y",
            "-i",
            str(media_path),
            "-vn",
            "-ac",
            "1",
            "-ar",
            str(sample_rate),
            "-f",
            "wav",
            str(target_wav),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    return target_wav


def _read_wav_mono_float(wav_path: Path) -> Tuple[List[float], int]:
    """Read a 16-bit PCM WAV file into normalized [-1.0, 1.0] mono floats using Python stdlib."""
    with wave.open(str(wav_path), "rb") as wf:
        n_channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        framerate = wf.getframerate()
        n_frames = wf.getnframes()
        raw = wf.readframes(n_frames)

    if sampwidth != 2:
        raise ValueError(f"Expected 16-bit PCM WAV (sampwidth=2), got sampwidth={sampwidth}")

    total_samples = n_frames * n_channels
    ints = struct.unpack(f"<{total_samples}h", raw)
    if n_channels == 1:
        samples = [x / 32768.0 for x in ints]
    else:
        samples = [
            sum(ints[i : i + n_channels]) / (n_channels * 32768.0)
            for i in range(0, total_samples, n_channels)
        ]
    return samples, framerate


def _extract_beats_beat_this_cpu(audio_path: Path) -> Optional[Tuple[float, List[float]]]:
    """Run CPJKU `Beat This!` on CPU if installed (`pip install beat_this`)."""
    try:
        from beat_this.inference import File2Beats  # type: ignore[import-not-found]
    except ImportError:
        return None

    tracker = File2Beats(checkpoint_path="final0", device="cpu", dbn=False)
    beats, _downbeats = tracker(str(audio_path))
    beat_list = [round(float(b), 4) for b in beats]
    if len(beat_list) >= 2:
        intervals = [beat_list[i + 1] - beat_list[i] for i in range(len(beat_list) - 1)]
        median_ioi = sorted(intervals)[len(intervals) // 2]
        bpm = round(60.0 / max(1e-6, median_ioi), 2)
    else:
        bpm = 120.0
    return bpm, beat_list


def _extract_beats_stdlib_onset(wav_path: Path, min_bpm: float = 95.0, max_bpm: float = 140.0) -> Tuple[float, List[float]]:
    """Deterministic stdlib onset-envelope beat tracker for CPU environments without PyTorch."""
    samples, sr = _read_wav_mono_float(wav_path)
    hop = max(1, int(sr * 0.010))  # 10 ms hop
    win = max(hop, int(sr * 0.020))  # 20 ms window

    energies: List[float] = []
    for start in range(0, max(1, len(samples) - win), hop):
        chunk = samples[start : start + win]
        energies.append(math.sqrt(sum(c * c for c in chunk) / len(chunk)))

    # First-order positive onset flux
    onset_env = [0.0] + [max(0.0, energies[i] - energies[i - 1]) for i in range(1, len(energies))]
    env_dt = hop / float(sr)

    # Autocorrelation over house-music BPM range [min_bpm, max_bpm]
    min_lag = max(1, int(round((60.0 / max_bpm) / env_dt)))
    max_lag = max(min_lag + 1, int(round((60.0 / min_bpm) / env_dt)))

    best_lag = min_lag
    best_score = -1.0
    for lag in range(min_lag, min(max_lag + 1, len(onset_env) // 2)):
        score = sum(onset_env[i] * onset_env[i + lag] for i in range(len(onset_env) - lag))
        if score > best_score:
            best_score = score
            best_lag = lag

    beat_period_s = best_lag * env_dt
    bpm = round(60.0 / max(1e-6, beat_period_s), 2)

    # Find best phase alignment for the beat grid
    num_phase_steps = best_lag
    best_phase_idx = 0
    best_phase_energy = -1.0
    for p in range(num_phase_steps):
        e = 0.0
        idx = p
        while idx < len(onset_env):
            w_lo = max(0, idx - 2)
            w_hi = min(len(onset_env), idx + 3)
            e += max(onset_env[w_lo:w_hi])
            idx += best_lag
        if e > best_phase_energy:
            best_phase_energy = e
            best_phase_idx = p

    # Snap each grid beat to local onset peak within +/- 30ms
    duration_s = len(samples) / float(sr)
    beat_times: List[float] = []
    k = 0
    while True:
        nominal_idx = best_phase_idx + k * best_lag
        nominal_t = nominal_idx * env_dt
        if nominal_t > duration_s - 0.05:
            break
        lo = max(0, nominal_idx - 3)
        hi = min(len(onset_env), nominal_idx + 4)
        peak_idx = max(range(lo, hi), key=lambda idx: onset_env[idx])
        beat_times.append(round(peak_idx * env_dt, 4))
        k += 1

    return bpm, beat_times


def extract_beats_from_audio(media_path: Path) -> Dict[str, Any]:
    """Extract BPM and beat timestamps from a video or audio clip on Linux CPU."""
    media_path = Path(media_path)
    res_bt = _extract_beats_beat_this_cpu(media_path)
    if res_bt is not None:
        bpm, beat_times = res_bt
        return {
            "backend": "beat_this_cpu",
            "bpm": bpm,
            "beat_times": beat_times,
        }

    with tempfile.TemporaryDirectory() as tmpdir:
        wav_path = extract_wav_from_media(media_path, Path(tmpdir) / "extracted.wav")
        bpm, beat_times = _extract_beats_stdlib_onset(wav_path)
        return {
            "backend": "stdlib_onset_cpu",
            "bpm": bpm,
            "beat_times": beat_times,
        }


def attach_beats_to_pose_json(
    media_path: Path,
    pose_json_path: Path,
    output_json_path: Optional[Path] = None,
) -> Dict[str, Any]:
    """Extract beat grid from clip audio and attach `bpm` and `beat_times` to a pose JSON file."""
    beat_info = extract_beats_from_audio(media_path)
    with open(pose_json_path, "r", encoding="utf-8") as f:
        pose_clip = json.load(f)

    pose_clip["bpm"] = beat_info["bpm"]
    pose_clip["beat_times"] = beat_info["beat_times"]
    pose_clip["beat_alignment_source"] = beat_info["backend"]

    out_path = output_json_path or pose_json_path
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(pose_clip, f, indent=2)

    return pose_clip


def detect_audio_clap_onset(wav_path: Path) -> float:
    """Detect the sharpest impulsive clap onset timestamp (seconds) in a WAV recording."""
    samples, sr = _read_wav_mono_float(wav_path)
    hop = max(1, int(sr * 0.002))  # 2 ms resolution for clap test
    win = max(hop, int(sr * 0.005))

    best_idx = 0
    best_flux = -1.0
    prev_rms = 0.0
    for idx, start in enumerate(range(0, max(1, len(samples) - win), hop)):
        chunk = samples[start : start + win]
        rms = math.sqrt(sum(c * c for c in chunk) / len(chunk))
        flux = rms - prev_rms
        if flux > best_flux:
            best_flux = flux
            best_idx = idx
        prev_rms = rms

    return round((best_idx * hop) / float(sr), 5)


def write_synthetic_click_track_wav(
    wav_path: Path,
    bpm: float = 120.0,
    num_beats: int = 8,
    phase_offset_s: float = 0.50,
    sample_rate: int = 22050,
) -> List[float]:
    """Generate a synthetic house kick/click WAV file with known ground-truth beat timestamps for testing."""
    beat_period_s = 60.0 / bpm
    duration_s = phase_offset_s + num_beats * beat_period_s + 0.5
    total_samples = int(duration_s * sample_rate)
    samples = [0.0] * total_samples
    true_beats: List[float] = []

    for b in range(num_beats):
        t_beat = round(phase_offset_s + b * beat_period_s, 4)
        true_beats.append(t_beat)
        start_idx = int(t_beat * sample_rate)
        pulse_len = int(0.035 * sample_rate)
        for i in range(pulse_len):
            idx = start_idx + i
            if 0 <= idx < total_samples:
                env = math.exp(-i / (0.008 * sample_rate))
                samples[idx] += 0.9 * env * math.sin(2.0 * math.pi * 110.0 * (i / sample_rate))

    pcm = struct.pack(
        f"<{total_samples}h",
        *[max(-32767, min(32767, int(s * 32767.0))) for s in samples],
    )
    with wave.open(str(wav_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm)

    return true_beats


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extract beats from clip audio and attach to Vision 3D pose JSON."
    )
    parser.add_argument("media_path", type=Path, help="Path to .mov, .mp4, or .wav clip")
    parser.add_argument("pose_json", type=Path, help="Path to exported pose JSON clip")
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Optional output path (defaults to updating pose_json in place)",
    )
    args = parser.parse_args()

    updated = attach_beats_to_pose_json(args.media_path, args.pose_json, args.output)
    print(
        f"Attached {len(updated['beat_times'])} beats at {updated['bpm']} BPM "
        f"(backend={updated['beat_alignment_source']}) -> {args.output or args.pose_json}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
