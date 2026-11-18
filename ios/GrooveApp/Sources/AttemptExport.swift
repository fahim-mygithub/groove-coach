import Foundation
import GrooveCore
import SwiftUI
import UIKit

/// Manages attempt bundle exports and grading compatibility checks (spec §2.2, §5 V4).
public enum AttemptExport {
    /// App's supported scoring engine major version.
    public static let appEngineMajor: Int = 2

    /// Pinned SHA-256 of the bundled MediaPipe Pose Landmarker model.
    /// Pinned in `ios/GrooveApp/Resources/fetch_pose_model.sh` and `config/groove_config.json`.
    public static let appPoseModelSha256: String = "5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1"

    /// Refuse to grade (but still play) when manifest.extractor pose_model_sha256 or requires.engine_major differ (spec §2.2).
    public static func canGrade(manifest: LessonPackage.Manifest) -> (canGrade: Bool, reason: String?) {
        if manifest.requires.engineMajor != appEngineMajor {
            return (false, "Incompatible engine major: lesson requires v\(manifest.requires.engineMajor), but app runs v\(appEngineMajor). Please update the app to grade.")
        }
        if manifest.extractor.poseModelSha256.caseInsensitiveCompare(appPoseModelSha256) != .orderedSame {
            return (false, "Incompatible pose model: sha256 mismatch with bundled model. Please update the app to grade.")
        }
        return (true, nil)
    }

    /// Attempt bundle exported via share sheet for tuning sessions (spec §5 V4).
    public struct AttemptBundle: Codable, Sendable {
        public var schema: String
        public var lessonId: String
        public var segmentId: String
        public var packageVersion: Int
        public var rate: Double
        public var mirrored: Bool
        public var timestamp: String
        public var takePoses: GrooveScoringEngine.PoseClip
        public var referenceSlice: GrooveScoringEngine.PoseClip
        public var result: GrooveScoringEngine.AttemptScoreResult

        enum CodingKeys: String, CodingKey {
            case schema
            case lessonId = "lesson_id"
            case segmentId = "segment_id"
            case packageVersion = "package_version"
            case rate
            case mirrored
            case timestamp
            case takePoses = "take_poses"
            case referenceSlice = "reference_slice"
            case result
        }

        public init(
            schema: String = "groove.attempt/1",
            lessonId: String,
            segmentId: String,
            packageVersion: Int,
            rate: Double,
            mirrored: Bool,
            timestamp: String = ISO8601DateFormatter().string(from: Date()),
            takePoses: GrooveScoringEngine.PoseClip,
            referenceSlice: GrooveScoringEngine.PoseClip,
            result: GrooveScoringEngine.AttemptScoreResult
        ) {
            self.schema = schema
            self.lessonId = lessonId
            self.segmentId = segmentId
            self.packageVersion = packageVersion
            self.rate = rate
            self.mirrored = mirrored
            self.timestamp = timestamp
            self.takePoses = takePoses
            self.referenceSlice = referenceSlice
            self.result = result
        }
    }

    /// Serializes an attempt bundle to a temporary JSON file and returns its URL for UIActivityViewController.
    public static func exportBundleToFile(_ bundle: AttemptBundle) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        let safeDate = bundle.timestamp
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let filename = "attempt_\(bundle.lessonId)_\(bundle.segmentId)_\(safeDate).json"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}

/// Share sheet (UIActivityViewController) wrapper for SwiftUI.
public struct ShareSheet: UIViewControllerRepresentable {
    public let activityItems: [Any]
    public var applicationActivities: [UIActivity]? = nil

    public init(activityItems: [Any], applicationActivities: [UIActivity]? = nil) {
        self.activityItems = activityItems
        self.applicationActivities = applicationActivities
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
