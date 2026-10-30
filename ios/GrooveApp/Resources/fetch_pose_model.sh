#!/usr/bin/env bash
# Fetch the MediaPipe Pose Landmarker (full) model bundled as an app resource.
# Pinned to the versioned "/1/" object (not "/latest/") and verified by sha256 so builds are deterministic.
# Model: BlazePose GHUM 3D, Apache License 2.0 (https://ai.google.dev/edge/mediapipe/solutions/vision/pose_landmarker).
set -euo pipefail

MODEL_URL="https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/1/pose_landmarker_full.task"
MODEL_SHA256="5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1"
DEST="$(cd "$(dirname "$0")" && pwd)/pose_landmarker_full.task"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

if [ -f "$DEST" ] && [ "$(sha256_of "$DEST")" = "$MODEL_SHA256" ]; then
  echo "pose model already present: $DEST"
  exit 0
fi

curl -fsSL --retry 3 -o "$DEST.tmp" "$MODEL_URL"
ACTUAL="$(sha256_of "$DEST.tmp")"
if [ "$ACTUAL" != "$MODEL_SHA256" ]; then
  rm -f "$DEST.tmp"
  echo "sha256 mismatch for pose model: expected $MODEL_SHA256, got $ACTUAL" >&2
  exit 1
fi
mv "$DEST.tmp" "$DEST"
echo "fetched pose model: $DEST"
