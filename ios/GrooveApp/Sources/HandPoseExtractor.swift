import CoreMedia
import Foundation
import GrooveCore
import UIKit
#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision
#endif

/// MediaPipe HandLandmarker wrapper for post-take hand extraction (spec §3.3).
///
/// Uses pinned `hand_landmarker.task` model (sha256 `fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1`),
/// the exact same model as authoring pipeline. In the post-take pass, hands are detected
/// per video frame and attached to the nearest pose wrist via `CanonicalSkeleton.toCanonical`.
public final class HandPoseExtractor: @unchecked Sendable {
    public static let modelResourceName = "hand_landmarker"
    public static let modelResourceExtension = "task"
    public static let modelSha256 = "fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1"

    #if canImport(MediaPipeTasksVision)
    private let landmarker: HandLandmarker?
    #endif
    private var lastTimestampMs: Int = -1

    public init(modelPath: String? = nil) {
        #if canImport(MediaPipeTasksVision)
        let resolvedPath = modelPath ?? Bundle.main.path(forResource: Self.modelResourceName, ofType: Self.modelResourceExtension)
        if let path = resolvedPath {
            let options = HandLandmarkerOptions()
            options.baseOptions.modelAssetPath = path
            options.runningMode = .video
            options.numHands = 2
            options.minHandDetectionConfidence = 0.5
            options.minHandPresenceConfidence = 0.5
            options.minTrackingConfidence = 0.5
            self.landmarker = try? HandLandmarker(options: options)
        } else {
            self.landmarker = nil
        }
        #endif
    }

    public var isAvailable: Bool {
        #if canImport(MediaPipeTasksVision)
        return landmarker != nil
        #else
        return false
        #endif
    }

    /// Detect hands in a video frame; returns hands mapped into `CanonicalSkeleton.Hand` shape.
    public func detectHands(
        from sampleBuffer: CMSampleBuffer,
        orientation: UIImage.Orientation,
        timestampMs: Int
    ) -> [CanonicalSkeleton.Hand] {
        #if canImport(MediaPipeTasksVision)
        guard let landmarker = landmarker else { return [] }
        guard timestampMs > lastTimestampMs else { return [] }
        lastTimestampMs = timestampMs

        guard let image = try? MPImage(sampleBuffer: sampleBuffer, orientation: orientation),
              let result = try? landmarker.detect(videoFrame: image, timestampInMilliseconds: timestampMs) else {
            return []
        }

        var hands: [CanonicalSkeleton.Hand] = []
        let worldHands = result.worldLandmarks
        let imageHands = result.landmarks
        let count = min(worldHands.count, imageHands.count)
        for hIdx in 0..<count {
            let wList = worldHands[hIdx]
            let iList = imageHands[hIdx]
            guard wList.count == CanonicalSkeleton.handLandmarkCount,
                  iList.count == CanonicalSkeleton.handLandmarkCount else {
                continue
            }
            let wPts = wList.map { [Double($0.x), Double($0.y), Double($0.z)] }
            let iPts = iList.map { [Double($0.x), Double($0.y), Double($0.z)] }
            hands.append(CanonicalSkeleton.Hand(worldLandmarks: wPts, imageLandmarks: iPts))
        }
        return hands
        #else
        return []
        #endif
    }

    /// Classify hand shape from 21 canonical/hand-space 3D landmarks via `HandStyling`.
    public static func shapeLabel(points: [[Double]], isLeft: Bool) -> HandStyling.Shape {
        let vecs = points.map { GrooveScoringEngine.Vec3(array: $0) }
        guard let features = HandStyling.extractFeatures(points: vecs, isLeft: isLeft) else { return .unknown }
        return HandStyling.classify(features).label
    }
}
