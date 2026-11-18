"""Groove Coach lesson authoring pipeline (M1, WO-1C).

Submodules:
- extract_pose: MediaPipe VIDEO-mode pose & hand landmarker -> canonical skeleton -> One Euro smoothing -> reference_pose.json.
- beat_grid: Beat grid generation, audio beat proposal, and author-confirmed beat alignment.
- build_package: Package builder from lesson source + video -> validated package directory.
- render_overlay: Debug overlay video rendering (skeleton drawn over video).
"""
