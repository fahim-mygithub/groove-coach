#!/usr/bin/env bash
# Fetch the MediaPipe Pose Landmarker (full) and Hand Landmarker models bundled as app resources.
# Pinned to the versioned "/1/" objects (not "/latest/") and verified by sha256 so builds are deterministic.
# Models:
# - Pose: BlazePose GHUM 3D, Apache License 2.0 (https://ai.google.dev/edge/mediapipe/solutions/vision/pose_landmarker).
# - Hand: MediaPipe Hands, Apache License 2.0 (https://ai.google.dev/edge/mediapipe/solutions/vision/hand_landmarker).
set -euo pipefail

RESOURCES_DIR="$(cd "$(dirname "$0")" && pwd)"

POSE_MODEL_URL="https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/1/pose_landmarker_full.task"
POSE_MODEL_SHA256="5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1"
POSE_DEST="$RESOURCES_DIR/pose_landmarker_full.task"

HAND_MODEL_URL="https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task"
HAND_MODEL_SHA256="fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1"
HAND_DEST="$RESOURCES_DIR/hand_landmarker.task"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

fetch_model() {
  local name="$1"
  local url="$2"
  local expected_sha="$3"
  local dest="$4"

  if [ -f "$dest" ] && [ "$(sha256_of "$dest")" = "$expected_sha" ]; then
    echo "$name model already present: $dest"
    return 0
  fi

  echo "fetching $name model from $url..."
  curl -fsSL --retry 3 -o "$dest.tmp" "$url"
  local actual
  actual="$(sha256_of "$dest.tmp")"
  if [ "$actual" != "$expected_sha" ]; then
    rm -f "$dest.tmp"
    echo "sha256 mismatch for $name model: expected $expected_sha, got $actual" >&2
    exit 1
  fi
  mv "$dest.tmp" "$dest"
  echo "fetched $name model: $dest"
}

fetch_model "pose" "$POSE_MODEL_URL" "$POSE_MODEL_SHA256" "$POSE_DEST"
fetch_model "hand" "$HAND_MODEL_URL" "$HAND_MODEL_SHA256" "$HAND_DEST"
