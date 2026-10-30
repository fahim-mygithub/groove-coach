import CoreMedia
import Foundation
import UIKit
#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision
#endif

/// Real foot keypoints for one frame (`leftHeel`, `leftFootIndex`, `rightHeel`, `rightFootIndex`).
struct FootKeypointResult {
    let joints: [String: [Double]]
    let confidences: [String: Double]
}

/// Source of real heel / toe keypoints. Implementations must NEVER synthesize feet from ankle offsets:
/// return `nil` when no person or no model is available so scoring reports feet as "unavailable".
protocol FootKeypointProvider: AnyObject {
    /// `visionAnkles` holds the Vision 3D `leftAnkle` / `rightAnkle` positions of the same frame (if detected),
    /// used to anchor the foot vectors into the Vision 3D body space consumed by `GrooveScoringEngine`.
    func footKeypoints(
        from sampleBuffer: CMSampleBuffer,
        timestampSeconds: Double,
        visionAnkles: [String: [Double]]
    ) -> FootKeypointResult?
}

enum FootKeypointProviderFactory {
    /// Bundled MediaPipe Pose Landmarker model (fetched by CI, pinned by sha256; see `Resources/fetch_pose_model.sh`).
    static let modelResourceName = "pose_landmarker_full"
    static let modelResourceExtension = "task"

    /// One provider per video: MediaPipe `.video` running mode requires monotonically increasing timestamps.
    static func makeVideoProvider() -> FootKeypointProvider? {
        #if canImport(MediaPipeTasksVision)
        guard let modelPath = Bundle.main.path(forResource: modelResourceName, ofType: modelResourceExtension) else {
            return nil
        }
        return try? MediaPipeFootKeypointProvider(modelPath: modelPath)
        #else
        return nil
        #endif
    }

    /// Whether this build can produce real foot keypoints (framework linked + model bundled).
    static var isAvailable: Bool {
        #if canImport(MediaPipeTasksVision)
        return Bundle.main.path(forResource: modelResourceName, ofType: modelResourceExtension) != nil
        #else
        return false
        #endif
    }
}

#if canImport(MediaPipeTasksVision)
/// `FootKeypointProvider` backed by MediaPipe `PoseLandmarker` (config `models.foot_keypoints_coreml` =
/// `MediaPipePoseLandmarker_FootKeypoints`). Landmark indices: 27 = left_ankle, 28 = right_ankle,
/// 29 = left_heel, 30 = right_heel, 31 = left_foot_index, 32 = right_foot_index.
final class MediaPipeFootKeypointProvider: FootKeypointProvider {
    private static let footLandmarks: [(name: String, index: Int, ankleName: String, ankleIndex: Int)] = [
        ("leftHeel", 29, "leftAnkle", 27),
        ("rightHeel", 30, "rightAnkle", 28),
        ("leftFootIndex", 31, "leftAnkle", 27),
        ("rightFootIndex", 32, "rightAnkle", 28)
    ]

    private let landmarker: PoseLandmarker
    private var lastTimestampMs: Int = -1

    init(modelPath: String) throws {
        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .video
        options.numPoses = 1
        options.minPoseDetectionConfidence = 0.5
        options.minPosePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        landmarker = try PoseLandmarker(options: options)
    }

    func footKeypoints(
        from sampleBuffer: CMSampleBuffer,
        timestampSeconds: Double,
        visionAnkles: [String: [Double]]
    ) -> FootKeypointResult? {
        let timestampMs = Int((timestampSeconds * 1000.0).rounded())
        guard timestampMs > lastTimestampMs else { return nil }
        lastTimestampMs = timestampMs

        guard let image = try? MPImage(sampleBuffer: sampleBuffer, orientation: .up),
              let result = try? landmarker.detect(videoFrame: image, timestampInMilliseconds: timestampMs),
              let world = result.worldLandmarks.first, world.count > 32,
              let normalized = result.landmarks.first, normalized.count > 32 else {
            return nil
        }

        var joints: [String: [Double]] = [:]
        var confidences: [String: Double] = [:]
        for foot in Self.footLandmarks {
            let footPoint = Self.visionAxes(world[foot.index])
            let mpAnkle = Self.visionAxes(world[foot.ankleIndex])
            if let anchor = visionAnkles[foot.ankleName], anchor.count >= 3 {
                // Anchor MediaPipe's ankle->foot vector on the Vision 3D ankle so heel height and foot pitch
                // live in the same hip-centered, y-up metric space as the Vision body joints.
                joints[foot.name] = [
                    anchor[0] + (footPoint[0] - mpAnkle[0]),
                    anchor[1] + (footPoint[1] - mpAnkle[1]),
                    anchor[2] + (footPoint[2] - mpAnkle[2])
                ]
            } else {
                joints[foot.name] = footPoint
            }
            confidences[foot.name] = Self.confidence(normalized[foot.index])
        }
        return FootKeypointResult(joints: joints, confidences: confidences)
    }

    /// MediaPipe world landmarks are hip-centered meters with y pointing down; Vision 3D joints are
    /// hip-centered meters with y pointing up. Foot pitch only depends on the vertical axis, so any residual
    /// rotation about y between the two spaces does not change the scored pitch or heel height.
    private static func visionAxes(_ landmark: Landmark) -> [Double] {
        [Double(landmark.x), -Double(landmark.y), -Double(landmark.z)]
    }

    private static func confidence(_ landmark: NormalizedLandmark) -> Double {
        let visibility = landmark.visibility?.doubleValue ?? 0.0
        let presence = landmark.presence?.doubleValue ?? visibility
        return max(0.0, min(1.0, min(visibility, presence)))
    }
}
#endif
