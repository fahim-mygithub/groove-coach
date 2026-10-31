import Foundation

extension GrooveScoringEngine {

    /// Bone-length retargeting of a reference onto the learner's proportions (owner decision Q3, spec §8; v1 path B
    /// of the body-extrapolation report: MediaPipe skeleton only, no mesh model). Mirror of `groove_eval/retarget.py`
    /// (same bone table, same operation order).
    ///
    /// The teacher's motion is kept as unit bone directions and re-walked from `root` along `canonicalBones` with the
    /// learner's bone lengths: `x_child = x_parent + L_learner(child) * unit(teacher_child - teacher_parent)`. `root`
    /// keeps the teacher's position, so the result is a canonical frame of the same shape. Joint angles are invariant
    /// to this step; joint positions (and anything normalised by leg length) are not.
    ///
    /// Learner lengths are the per-bone median over a calibration stance when the take carries one
    /// (`PoseClip.calibration_frames`), else over the take. Bones the learner frames never show keep the teacher's
    /// length. Hand landmarks move with their wrist.
    public enum Retarget {

        /// (child, parent) bones of the canonical tree rooted at `root`; `CANONICAL_BONES` in
        /// `groove_eval/canonical_skeleton.py`, in the same order (parents before children).
        public static let canonicalBones: [(child: String, parent: String)] = [
            ("spine", "root"),
            ("centerShoulder", "spine"),
            ("nose", "centerShoulder"),
            ("leftHip", "root"),
            ("leftKnee", "leftHip"),
            ("leftAnkle", "leftKnee"),
            ("leftHeel", "leftAnkle"),
            ("leftFootIndex", "leftAnkle"),
            ("rightHip", "root"),
            ("rightKnee", "rightHip"),
            ("rightAnkle", "rightKnee"),
            ("rightHeel", "rightAnkle"),
            ("rightFootIndex", "rightAnkle"),
            ("leftShoulder", "centerShoulder"),
            ("leftElbow", "leftShoulder"),
            ("leftWrist", "leftElbow"),
            ("rightShoulder", "centerShoulder"),
            ("rightElbow", "rightShoulder"),
            ("rightWrist", "rightElbow")
        ]

        /// leftX <-> rightX (the `mirrorSwapPairs` rule); other joint names are unchanged.
        public static func mirrorName(_ name: String) -> String {
            if name.hasPrefix("left") { return "right" + String(name.dropFirst(4)) }
            if name.hasPrefix("right") { return "left" + String(name.dropFirst(5)) }
            return name
        }

        static func point(_ joints: [String: [Double]], _ name: String) -> Vec3? {
            guard let p = joints[name], p.count >= 3 else { return nil }
            return Vec3(p[0], p[1], p[2])
        }

        static func length(_ a: Vec3, _ b: Vec3) -> Double {
            let dx = a.x - b.x
            let dy = a.y - b.y
            let dz = a.z - b.z
            return (dx * dx + dy * dy + dz * dz).squareRoot()
        }

        static func median(_ values: [Double]) -> Double {
            let s = values.sorted()
            let n = s.count
            if n % 2 == 1 { return s[n / 2] }
            return (s[n / 2 - 1] + s[n / 2]) * 0.5
        }

        /// Per-bone median length (m) over `frames`, keyed by the bone's child joint.
        public static func medianBoneLengths(_ frames: [RawPoseFrame]) -> [String: Double] {
            var samples: [String: [Double]] = [:]
            for frame in frames {
                for bone in canonicalBones {
                    guard let c = point(frame.joints, bone.child), let p = point(frame.joints, bone.parent) else { continue }
                    samples[bone.child, default: []].append(length(c, p))
                }
            }
            return samples.mapValues { median($0) }
        }

        /// The learner's bone lengths in the reference's side labels: from `calibration_frames` when present and
        /// non-empty, else from the take. A mirrored take's left/right labels are swapped, like `swapMirrored`.
        public static func learnerBoneLengths(attempt: PoseClip) -> [String: Double] {
            let calibration = attempt.calibration_frames ?? []
            let lengths = medianBoneLengths(calibration.isEmpty ? attempt.frames : calibration)
            guard attempt.mirrored ?? false else { return lengths }
            var swapped: [String: Double] = [:]
            for (name, value) in lengths {
                swapped[mirrorName(name)] = value
            }
            return swapped
        }

        /// One canonical frame re-walked with `lengths`; joints the walk cannot reach (missing parent) are kept.
        public static func retargetFrame(_ frame: RawPoseFrame, lengths: [String: Double]) -> RawPoseFrame {
            guard let root = point(frame.joints, "root") else { return frame }
            var walked: [String: Vec3] = ["root": root]
            for bone in canonicalBones {
                guard let c = point(frame.joints, bone.child),
                      let p = point(frame.joints, bone.parent),
                      let base = walked[bone.parent] else { continue }
                guard let len = lengths[bone.child] else {
                    walked[bone.child] = Vec3(base.x + (c.x - p.x), base.y + (c.y - p.y), base.z + (c.z - p.z))
                    continue
                }
                let n = length(c, p)
                if n < 1e-9 {
                    walked[bone.child] = base
                    continue
                }
                let d = Vec3((c.x - p.x) / n, (c.y - p.y) / n, (c.z - p.z) / n)
                walked[bone.child] = Vec3(base.x + d.x * len, base.y + d.y * len, base.z + d.z * len)
            }

            var joints = frame.joints
            for (name, p) in walked {
                joints[name] = [p.x, p.y, p.z]
            }
            var hands = frame.hands
            if let frameHands = frame.hands, !frameHands.isEmpty {
                var moved: [String: [[Double]]] = [:]
                for (side, pts) in frameHands {
                    guard let old = point(frame.joints, side + "Wrist"), let new = walked[side + "Wrist"] else {
                        moved[side] = pts
                        continue
                    }
                    let sx = new.x - old.x
                    let sy = new.y - old.y
                    let sz = new.z - old.z
                    moved[side] = pts.map { q in
                        [(q.count > 0 ? q[0] : 0.0) + sx, (q.count > 1 ? q[1] : 0.0) + sy, (q.count > 2 ? q[2] : 0.0) + sz]
                    }
                }
                hands = moved
            }
            return RawPoseFrame(t: frame.t, joints: joints, confidences: frame.confidences, hands: hands)
        }

        public static func retargetFrames(_ frames: [RawPoseFrame], lengths: [String: Double]) -> [RawPoseFrame] {
            frames.map { retargetFrame($0, lengths: lengths) }
        }

        /// A copy of a clip whose frames are retargeted onto `lengths` (all other fields kept).
        public static func retargetClip(_ clip: PoseClip, lengths: [String: Double]) -> PoseClip {
            PoseClip(
                clip_id: clip.clip_id,
                move_tag: clip.move_tag,
                bpm: clip.bpm,
                beat_times: clip.beat_times,
                gravity_vector: clip.gravity_vector,
                mirrored: clip.mirrored,
                audio_latency_ms: clip.audio_latency_ms,
                speed_pct: clip.speed_pct,
                expected: clip.expected,
                frames: retargetFrames(clip.frames, lengths: lengths),
                windows: clip.windows,
                calibration_frames: clip.calibration_frames
            )
        }
    }
}
