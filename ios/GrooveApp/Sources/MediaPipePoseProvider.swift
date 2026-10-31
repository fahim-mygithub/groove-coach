import AVFoundation
import CoreMedia
import Foundation
import GrooveCore
import UIKit
#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision
#endif

public typealias RawPoseFrame = GrooveScoringEngine.RawPoseFrame

/// Extractor version constants matching spec §2.2 and authoring pipeline.
public enum MediaPipeExtractorVersions {
    public static let poseModelName = "pose_landmarker_full"
    public static let poseModelSha256 = "5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1"
    public static let handModelName = "hand_landmarker"
    public static let handModelSha256 = "fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1"
    public static let mediapipePythonVersion = "1.2.0"
    public static let runningMode = "VIDEO"
    public static let numPoses = 1
    public static let skeleton = "groove.canonical/1"

    /// Compares a manifest extractor config against the app's bundled extractor versions.
    /// Returns true if the extractor matches and grading is permitted.
    public static func matchesManifest(poseModelSha: String) -> Bool {
        poseModelSha.lowercased() == poseModelSha256.lowercased()
    }
}

/// Abstract pose provider protocol defined by spec §6 (WO-2A).
public protocol PoseProvider: AnyObject {
    /// Extracts canonical skeleton frames from a recorded video URL.
    func extract(videoURL: URL) async throws -> [RawPoseFrame]

    /// Extracts a live canonical skeleton frame from a camera frame on the host clock (>= 15 fps target).
    func live(_ sampleBuffer: CMSampleBuffer, hostTime: Double) -> RawPoseFrame?
}

public enum PoseProviderError: LocalizedError {
    case modelNotFound(String)
    case extractionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let name):
            return "MediaPipe task model not found in app bundle: \(name).task"
        case .extractionFailed(let reason):
            return "Pose extraction failed: \(reason)"
        }
    }
}

/// MediaPipe PoseLandmarker + HandLandmarker provider.
///
/// Implements `PoseProvider` using:
/// - PoseLandmarker world landmarks in `VIDEO` mode for recorded takes (post-take pass)
/// - PoseLandmarker in `LIVE_STREAM` mode for live camera feed (>= 15 fps target)
/// - MediaPipe HandLandmarker for post-take hands pass, mapped via `CanonicalSkeleton.toCanonical`
/// - num_poses = 1
public final class MediaPipePoseProvider: NSObject, PoseProvider, @unchecked Sendable {
    public static let shared = MediaPipePoseProvider()

    public static let poseModelName = MediaPipeExtractorVersions.poseModelName
    public static let poseModelSha256 = MediaPipeExtractorVersions.poseModelSha256
    public static let handModelName = MediaPipeExtractorVersions.handModelName
    public static let handModelSha256 = MediaPipeExtractorVersions.handModelSha256
    public static let runningMode = MediaPipeExtractorVersions.runningMode
    public static let numPoses = MediaPipeExtractorVersions.numPoses

    public static var isAvailable: Bool {
        #if canImport(MediaPipeTasksVision)
        return Bundle.main.path(forResource: poseModelName, ofType: "task") != nil
        #else
        return false
        #endif
    }

    #if canImport(MediaPipeTasksVision)
    private var liveLandmarker: PoseLandmarker?
    #endif

    private let liveLock = NSLock()
    private var latestLiveFrame: RawPoseFrame?
    private var _latestNormalizedLandmarks: [String: CGPoint] = [:]
    private var lastLiveTimestampMs: Int = -1
    private var livePendingSemaphore: DispatchSemaphore?

    public var latestNormalizedLandmarks: [String: CGPoint] {
        liveLock.lock()
        defer { liveLock.unlock() }
        return _latestNormalizedLandmarks
    }

    public override init() {
        super.init()
        setupLiveLandmarker()
    }

    private func setupLiveLandmarker() {
        #if canImport(MediaPipeTasksVision)
        guard let path = Bundle.main.path(forResource: Self.poseModelName, ofType: "task") else {
            return
        }
        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = path
        options.runningMode = .liveStream
        options.numPoses = 1
        options.minPoseDetectionConfidence = 0.5
        options.minPosePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        options.poseLandmarkerLiveStreamDelegate = self
        self.liveLandmarker = try? PoseLandmarker(options: options)
        #endif
    }

    // MARK: - Video Extraction (Recorded Takes)

    public func extract(videoURL: URL) async throws -> [RawPoseFrame] {
        try await extract(videoURL: videoURL, rebaseToFirstSample: false)
    }

    public func extract(videoURL: URL, rebaseToFirstSample: Bool) async throws -> [RawPoseFrame] {
        #if canImport(MediaPipeTasksVision)
        guard let posePath = Bundle.main.path(forResource: Self.poseModelName, ofType: "task") else {
            throw PoseProviderError.modelNotFound(Self.poseModelName)
        }

        let poseOptions = PoseLandmarkerOptions()
        poseOptions.baseOptions.modelAssetPath = posePath
        poseOptions.runningMode = .video
        poseOptions.numPoses = 1
        poseOptions.minPoseDetectionConfidence = 0.5
        poseOptions.minPosePresenceConfidence = 0.5
        poseOptions.minTrackingConfidence = 0.5
        let landmarker = try PoseLandmarker(options: poseOptions)

        let handExtractor = HandPoseExtractor()

        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return []
        }
        let transform = try await track.load(.preferredTransform)
        let imageOrientation = Self.orientation(for: transform)
        let rotated = imageOrientation == .left || imageOrientation == .right

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw PoseProviderError.extractionFailed("Failed to start reading video track")
        }

        var extracted: [RawPoseFrame] = []
        var firstSampleTime: Double?
        var lastTimestampMs = -1

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let rawTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if firstSampleTime == nil { firstSampleTime = rawTimestamp }
            let timestamp = rebaseToFirstSample ? rawTimestamp - (firstSampleTime ?? rawTimestamp) : rawTimestamp
            let timestampMs = max(lastTimestampMs + 1, Int((rawTimestamp * 1000.0).rounded()))
            lastTimestampMs = timestampMs

            guard let image = try? MPImage(sampleBuffer: sampleBuffer, orientation: imageOrientation),
                  let poseResult = try? landmarker.detect(videoFrame: image, timestampInMilliseconds: timestampMs),
                  let worldPose = poseResult.worldLandmarks.first, worldPose.count == CanonicalSkeleton.poseLandmarkCount,
                  let imagePose = poseResult.landmarks.first, imagePose.count == CanonicalSkeleton.poseLandmarkCount else {
                continue
            }

            var imageAspect = 9.0 / 16.0
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let w = Double(CVPixelBufferGetWidth(pixelBuffer))
                let h = Double(CVPixelBufferGetHeight(pixelBuffer))
                imageAspect = rotated ? h / max(1.0, w) : w / max(1.0, h)
            }

            let hands = handExtractor.detectHands(
                from: sampleBuffer,
                orientation: imageOrientation,
                timestampMs: timestampMs
            )

            let worldLandmarks = worldPose.map { [Double($0.x), Double($0.y), Double($0.z)] }
            let visibility = imagePose.map { Double($0.visibility?.doubleValue ?? 0.0) }
            let imageLandmarks = imagePose.map { [Double($0.x), Double($0.y), Double($0.z)] }

            let frame = try CanonicalSkeleton.toCanonical(
                worldLandmarks: worldLandmarks,
                visibility: visibility,
                hands: hands,
                t: timestamp,
                imageLandmarks: imageLandmarks,
                imageAspect: imageAspect
            )
            extracted.append(frame)
        }

        return extracted
        #else
        return []
        #endif
    }

    // MARK: - Live Extraction (Camera Feed)

    public func live(_ sampleBuffer: CMSampleBuffer, hostTime: Double) -> RawPoseFrame? {
        #if canImport(MediaPipeTasksVision)
        guard let liveLandmarker = liveLandmarker else {
            return currentLatestLiveFrame()
        }

        guard let mpImage = try? MPImage(sampleBuffer: sampleBuffer, orientation: .up) else {
            return currentLatestLiveFrame()
        }

        let sema = DispatchSemaphore(value: 0)
        liveLock.lock()
        let timestampMs = max(lastLiveTimestampMs + 1, Int((hostTime * 1000.0).rounded()))
        lastLiveTimestampMs = timestampMs
        livePendingSemaphore = sema
        liveLock.unlock()

        do {
            try liveLandmarker.detectAsync(image: mpImage, timestampInMilliseconds: timestampMs)
            _ = sema.wait(timeout: .now() + .milliseconds(35))
        } catch {
            // Non-fatal, return current latest
        }

        liveLock.lock()
        livePendingSemaphore = nil
        let frame = latestLiveFrame
        liveLock.unlock()
        return frame
        #else
        return nil
        #endif
    }

    private func currentLatestLiveFrame() -> RawPoseFrame? {
        liveLock.lock()
        defer { liveLock.unlock() }
        return latestLiveFrame
    }

    public static func orientation(for transform: CGAffineTransform) -> UIImage.Orientation {
        let degrees = Int((atan2(transform.b, transform.a) * 180.0 / .pi).rounded())
        switch degrees {
        case 90: return .right
        case -90: return .left
        case 180, -180: return .down
        default: return .up
        }
    }
}

#if canImport(MediaPipeTasksVision)
extension MediaPipePoseProvider: PoseLandmarkerLiveStreamDelegate {
    public func poseLandmarker(
        _ poseLandmarker: PoseLandmarker,
        didFinishDetection result: PoseLandmarkerResult?,
        timestampInMilliseconds: Int,
        error: (any Error)?
    ) {
        if let result = result,
           let world = result.worldLandmarks.first, world.count == CanonicalSkeleton.poseLandmarkCount,
           let normalized = result.landmarks.first, normalized.count == CanonicalSkeleton.poseLandmarkCount {

            let worldPts = world.map { [Double($0.x), Double($0.y), Double($0.z)] }
            let vis = normalized.map { Double($0.visibility?.doubleValue ?? 0.0) }
            let imgPts = normalized.map { [Double($0.x), Double($0.y), Double($0.z)] }
            let t = Double(timestampInMilliseconds) / 1000.0

            if let frame = try? CanonicalSkeleton.toCanonical(
                worldLandmarks: worldPts,
                visibility: vis,
                hands: [],
                t: t,
                imageLandmarks: imgPts,
                imageAspect: 9.0 / 16.0
            ) {
                var normDict: [String: CGPoint] = [:]
                for (name, idx) in CanonicalSkeleton.mediapipeIndex {
                    normDict[name] = CGPoint(x: Double(normalized[idx].x), y: Double(normalized[idx].y))
                }
                liveLock.lock()
                self.latestLiveFrame = frame
                self._latestNormalizedLandmarks = normDict
                let sema = self.livePendingSemaphore
                liveLock.unlock()
                sema?.signal()
                return
            }
        }

        liveLock.lock()
        let sema = self.livePendingSemaphore
        liveLock.unlock()
        sema?.signal()
    }
}
#endif

