import CryptoKit
import Foundation

/// Manages lesson packages stored on device:
/// - downloads packages to a staging directory,
/// - verifies SHA-256 integrity against `manifest.files`,
/// - moves verified packages atomically to `Application Support/Lessons/{lesson_id}/v{n}/` (excluded from backup),
/// - retains older versions until the new one successfully verifies,
/// - caches catalog metadata locally for offline access,
/// - supports Dev Mode loading directly from a folder in the Files app.
@MainActor
public final class LessonStore: ObservableObject {
    public static let shared = LessonStore()

    @Published public private(set) var catalog: [CatalogItem] = []
    @Published public private(set) var downloadingLessonId: String?
    @Published public private(set) var downloadProgress: Double = 0.0
    @Published public private(set) var lastError: String?

    public let lessonsBaseURL: URL
    private let catalogCacheURL: URL
    private let supabaseClient: SupabaseClient

    public init(supabaseClient: SupabaseClient? = nil) {
        self.supabaseClient = supabaseClient ?? SupabaseClient.shared

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = appSupport.appendingPathComponent("Lessons", isDirectory: true)
        self.lessonsBaseURL = base
        self.catalogCacheURL = base.appendingPathComponent("catalog_cache.json")

        ensureDirectoryExcludedFromBackup(base)
        loadCachedCatalog()
        if catalog.isEmpty {
            seedDefaultCatalog()
        }
    }

    // MARK: - Directory Resolution

    /// Directory for a specific lesson version: `Application Support/Lessons/{lesson_id}/v{version}/`.
    public func lessonVersionDirectory(lessonId: String, version: Int) -> URL {
        lessonsBaseURL
            .appendingPathComponent(lessonId, isDirectory: true)
            .appendingPathComponent("v\(version)", isDirectory: true)
    }

    /// Check if a specific lesson version is downloaded and has its manifest.
    public func isLessonDownloaded(lessonId: String, version: Int) -> Bool {
        let dir = lessonVersionDirectory(lessonId: lessonId, version: version)
        let manifestURL = dir.appendingPathComponent("manifest.json")
        return FileManager.default.fileExists(atPath: manifestURL.path)
    }

    /// Load the manifest for a downloaded lesson version.
    public func loadManifest(lessonId: String, version: Int) -> LessonManifest? {
        let dir = lessonVersionDirectory(lessonId: lessonId, version: version)
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(LessonManifest.self, from: data)
    }

    /// Resolves the local URL of the video file for a downloaded lesson.
    public func localVideoURL(for manifest: LessonManifest) -> URL? {
        let dir = lessonVersionDirectory(lessonId: manifest.lesson_id, version: manifest.package_version)
        let videoURL = dir.appendingPathComponent(manifest.video.file)
        return FileManager.default.fileExists(atPath: videoURL.path) ? videoURL : nil
    }

    // MARK: - Catalog & Offline Cache

    /// Refresh catalog from Supabase REST and update offline cache.
    public func refreshCatalog() async throws {
        do {
            let remoteCatalog = try await supabaseClient.selectCatalog()
            if !remoteCatalog.isEmpty {
                self.catalog = remoteCatalog
                saveCatalogCache()
            }
        } catch {
            lastError = "Failed to refresh catalog: \(error.localizedDescription)"
            throw error
        }
    }

    private func saveCatalogCache() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(catalog)
            try data.write(to: catalogCacheURL, options: .atomic)
        } catch {
            print("[LessonStore] Failed to save catalog cache: \(error)")
        }
    }

    private func loadCachedCatalog() {
        guard FileManager.default.fileExists(atPath: catalogCacheURL.path),
              let data = try? Data(contentsOf: catalogCacheURL),
              let cached = try? JSONDecoder().decode([CatalogItem].self, from: data) else {
            return
        }
        self.catalog = cached
    }

    // MARK: - Download & Atomic Verification

    /// Download and atomically verify a lesson package from Supabase Storage.
    ///
    /// Keeps existing versions untouched if download or SHA-256 verification fails.
    public func downloadLesson(item: CatalogItem) async throws -> LessonManifest {
        downloadingLessonId = item.lesson_id
        downloadProgress = 0.0
        defer {
            downloadingLessonId = nil
            downloadProgress = 0.0
        }

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lesson_staging_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: stagingDir)
        }

        // 1. Fetch manifest.json
        let manifestData: Data
        if let embedded = item.manifest, let encoded = try? JSONEncoder().encode(embedded) {
            manifestData = encoded
        } else {
            let manifestPath = "\(item.storage_prefix)/manifest.json"
            manifestData = try await supabaseClient.fetchStorageData(bucket: "lesson-packages", path: manifestPath)
        }

        let manifest = try JSONDecoder().decode(LessonManifest.self, from: manifestData)
        let manifestDestURL = stagingDir.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestDestURL, options: .atomic)

        // 2. Download all files specified in manifest.files into staging
        let totalFiles = Double(max(1, manifest.files.count))
        var fileIndex = 0.0

        for (fileName, expectedSha256) in manifest.files {
            let fileDestURL = stagingDir.appendingPathComponent(fileName)
            let storagePath = "\(item.storage_prefix)/\(fileName)"

            try await supabaseClient.downloadStorageObject(
                bucket: "lesson-packages",
                path: storagePath,
                destinationURL: fileDestURL
            )

            // 3. Verify SHA-256
            let computedHash = try computeSHA256(for: fileDestURL)
            guard computedHash.caseInsensitiveCompare(expectedSha256) == .orderedSame else {
                throw LessonStoreError.sha256Mismatch(file: fileName, expected: expectedSha256, actual: computedHash)
            }

            fileIndex += 1.0
            downloadProgress = fileIndex / totalFiles
        }

        // 4. All files verified successfully: move atomically to Application Support/Lessons/{lesson_id}/v{n}/
        let targetVersionDir = lessonVersionDirectory(lessonId: manifest.lesson_id, version: manifest.package_version)
        let lessonParentDir = targetVersionDir.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: lessonParentDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: targetVersionDir.path) {
            _ = try FileManager.default.replaceItemAt(targetVersionDir, withItemAt: stagingDir)
        } else {
            try FileManager.default.moveItem(at: stagingDir, to: targetVersionDir)
        }

        ensureDirectoryExcludedFromBackup(targetVersionDir)
        saveCatalogCache()
        return manifest
    }

    // MARK: - DEV MODE: Load from Files App Folder

    /// DEV MODE: Ingests a complete lesson package folder directly from the Files app.
    ///
    /// Reads `manifest.json`, validates its files, and installs the package locally
    /// into `Application Support/Lessons/{lesson_id}/v{package_version}/`.
    @discardableResult
    public func importPackageFromFolder(folderURL: URL) throws -> LessonManifest {
        let isSecurityScoped = folderURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped { folderURL.stopAccessingSecurityScopedResource() }
        }

        let manifestURL = folderURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw LessonStoreError.manifestNotFound
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(LessonManifest.self, from: manifestData)

        let targetDir = lessonVersionDirectory(lessonId: manifest.lesson_id, version: manifest.package_version)
        let lessonParentDir = targetDir.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: lessonParentDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: targetDir.path) {
            try FileManager.default.removeItem(at: targetDir)
        }
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // Copy manifest.json
        try manifestData.write(to: targetDir.appendingPathComponent("manifest.json"), options: .atomic)

        // Copy package files (video, reference pose, poster, etc.)
        for fileName in manifest.files.keys {
            let sourceFileURL = folderURL.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: sourceFileURL.path) {
                let targetFileURL = targetDir.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: targetFileURL.path) {
                    try FileManager.default.removeItem(at: targetFileURL)
                }
                try FileManager.default.copyItem(at: sourceFileURL, to: targetFileURL)
            }
        }

        ensureDirectoryExcludedFromBackup(targetDir)

        // Add or replace entry in catalog
        let newItem = CatalogItem(
            course_id: "dev-course-\(manifest.course_slug)",
            course_slug: manifest.course_slug,
            course_title: manifest.course_slug.replacingOccurrences(of: "-", with: " ").capitalized,
            lesson_id: manifest.lesson_id,
            lesson_slug: manifest.lesson_slug,
            lesson_title: manifest.title,
            position: 1,
            package_version: manifest.package_version,
            storage_prefix: "dev/\(manifest.course_slug)/\(manifest.lesson_slug)/v\(manifest.package_version)",
            manifest: manifest,
            pose_model_sha256: manifest.extractor?.pose_model_sha256,
            published_at: ISO8601DateFormatter().string(from: Date())
        )

        catalog.removeAll { $0.lesson_id == manifest.lesson_id && $0.package_version == manifest.package_version }
        catalog.insert(newItem, at: 0)
        saveCatalogCache()

        return manifest
    }

    // MARK: - Helpers

    private func ensureDirectoryExcludedFromBackup(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }

    private func computeSHA256(for fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func seedDefaultCatalog() {
        // Built-in seed representing Bollywood Basics / Filmi Routine 1
        let sampleManifest = LessonManifest.makeSampleFilmiManifest()
        let seedItem = CatalogItem(
            course_id: "course-bollywood-basics",
            course_slug: "bollywood-basics",
            course_title: "Bollywood Basics",
            lesson_id: sampleManifest.lesson_id,
            lesson_slug: sampleManifest.lesson_slug,
            lesson_title: sampleManifest.title,
            position: 1,
            package_version: 1,
            storage_prefix: "lesson-packages/bollywood-basics/img4941-routine/v1",
            manifest: sampleManifest,
            pose_model_sha256: sampleManifest.extractor?.pose_model_sha256,
            published_at: "2026-10-31T00:00:00Z"
        )
        self.catalog = [seedItem]
    }
}

// MARK: - Catalog Item Model

public struct CatalogItem: Codable, Identifiable, Equatable {
    public var id: String { lesson_id }
    public let course_id: String?
    public let course_slug: String
    public let course_title: String
    public let lesson_id: String
    public let lesson_slug: String
    public let lesson_title: String
    public let position: Int?
    public let package_version: Int
    public let storage_prefix: String
    public let manifest: LessonManifest?
    public let pose_model_sha256: String?
    public let published_at: String?

    public init(
        course_id: String? = nil,
        course_slug: String,
        course_title: String,
        lesson_id: String,
        lesson_slug: String,
        lesson_title: String,
        position: Int? = 1,
        package_version: Int = 1,
        storage_prefix: String,
        manifest: LessonManifest? = nil,
        pose_model_sha256: String? = nil,
        published_at: String? = nil
    ) {
        self.course_id = course_id
        self.course_slug = course_slug
        self.course_title = course_title
        self.lesson_id = lesson_id
        self.lesson_slug = lesson_slug
        self.lesson_title = lesson_title
        self.position = position
        self.package_version = package_version
        self.storage_prefix = storage_prefix
        self.manifest = manifest
        self.pose_model_sha256 = pose_model_sha256
        self.published_at = published_at
    }
}

// MARK: - Manifest Codable Mirror

/// Minimal local Codable mirror of `schemas/lesson_package.schema.json`
/// used by `LessonStore` and `LessonPlayerView` until M1A `GrooveCore.LessonPackage` integrates.
public struct LessonManifest: Codable, Equatable {
    public let schema: String
    public let lesson_id: String
    public let course_slug: String
    public let lesson_slug: String
    public let package_version: Int
    public let title: String
    public let requires: RequiresInfo?
    public let extractor: ExtractorInfo?
    public let video: VideoInfo
    public let poster: String?
    public let reference: ReferenceInfo?
    public let beat_grid: BeatGridInfo
    public let segments: [SegmentInfo]
    public let windows: [WindowInfo]?
    public let practice: PracticeInfo
    public let files: [String: String]

    public struct RequiresInfo: Codable, Equatable {
        public let engine_major: Int
        public let skeleton: String

        public init(engine_major: Int, skeleton: String) {
            self.engine_major = engine_major
            self.skeleton = skeleton
        }
    }

    public struct ExtractorInfo: Codable, Equatable {
        public let pose_model: String
        public let pose_model_sha256: String
        public let hand_model: String?
        public let hand_model_sha256: String?
        public let mediapipe_python: String
        public let running_mode: String
        public let num_poses: Int

        public init(
            pose_model: String,
            pose_model_sha256: String,
            hand_model: String? = nil,
            hand_model_sha256: String? = nil,
            mediapipe_python: String,
            running_mode: String = "VIDEO",
            num_poses: Int = 1
        ) {
            self.pose_model = pose_model
            self.pose_model_sha256 = pose_model_sha256
            self.hand_model = hand_model
            self.hand_model_sha256 = hand_model_sha256
            self.mediapipe_python = mediapipe_python
            self.running_mode = running_mode
            self.num_poses = num_poses
        }
    }

    public struct VideoInfo: Codable, Equatable {
        public let file: String
        public let duration_s: Double
        public let fps: Double
        public let width: Int
        public let height: Int
        public let mirrored: Bool
        public let default_display_flip: Bool

        public init(
            file: String,
            duration_s: Double,
            fps: Double,
            width: Int,
            height: Int,
            mirrored: Bool,
            default_display_flip: Bool
        ) {
            self.file = file
            self.duration_s = duration_s
            self.fps = fps
            self.width = width
            self.height = height
            self.mirrored = mirrored
            self.default_display_flip = default_display_flip
        }
    }

    public struct ReferenceInfo: Codable, Equatable {
        public let file: String
        public let frame_count: Int

        public init(file: String, frame_count: Int) {
            self.file = file
            self.frame_count = frame_count
        }
    }

    public struct BeatGridInfo: Codable, Equatable {
        public let bpm: Double
        public let anchor_s: Double
        public let source: String
        public let detector: String?
        public let beats: [Beat]

        public init(bpm: Double, anchor_s: Double, source: String, detector: String? = nil, beats: [Beat]) {
            self.bpm = bpm
            self.anchor_s = anchor_s
            self.source = source
            self.detector = detector
            self.beats = beats
        }

        public struct Beat: Codable, Equatable, Identifiable {
            public var id: Double { t }
            public let t: Double
            public let phrase: Int
            public let count: Int

            public init(t: Double, phrase: Int, count: Int) {
                self.t = t
                self.phrase = phrase
                self.count = count
            }
        }
    }

    public struct SegmentInfo: Codable, Equatable, Identifiable {
        public let id: String
        public let kind: String?
        public let title: String
        public let start_s: Double
        public let end_s: Double
        public let teach_order: Int
        public let difficulty: Int?
        public let focus: [String]?
        public let cues: [String]?
        public let adaptive_speed: AdaptiveSpeedPolicy?

        public init(
            id: String,
            kind: String? = nil,
            title: String,
            start_s: Double,
            end_s: Double,
            teach_order: Int,
            difficulty: Int? = nil,
            focus: [String]? = nil,
            cues: [String]? = nil,
            adaptive_speed: AdaptiveSpeedPolicy? = nil
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.start_s = start_s
            self.end_s = end_s
            self.teach_order = teach_order
            self.difficulty = difficulty
            self.focus = focus
            self.cues = cues
            self.adaptive_speed = adaptive_speed
        }
    }

    public struct WindowInfo: Codable, Equatable {
        public let kind: String
        public let start_s: Double
        public let end_s: Double
        public let mask: [String]?
        public let tolerance_scale: [String: Double]?

        public init(
            kind: String,
            start_s: Double,
            end_s: Double,
            mask: [String]? = nil,
            tolerance_scale: [String: Double]? = nil
        ) {
            self.kind = kind
            self.start_s = start_s
            self.end_s = end_s
            self.mask = mask
            self.tolerance_scale = tolerance_scale
        }
    }

    public struct PracticeInfo: Codable, Equatable {
        public let count_in_beats: Int
        public let adaptive_speed: AdaptiveSpeedPolicy

        public init(count_in_beats: Int, adaptive_speed: AdaptiveSpeedPolicy) {
            self.count_in_beats = count_in_beats
            self.adaptive_speed = adaptive_speed
        }
    }
}

// MARK: - Adaptive Speed Policy Model

public struct AdaptiveSpeedPolicy: Codable, Equatable {
    public var min_rate: Double
    public var start_rate: Double
    public var max_rate: Double
    public var step_up: Double
    public var step_down: Double
    public var promote_after: Int
    public var demote_after: Int
    public var unlock_next_at_rate: Double

    public init(
        min_rate: Double = 0.6,
        start_rate: Double = 0.7,
        max_rate: Double = 1.0,
        step_up: Double = 0.1,
        step_down: Double = 0.05,
        promote_after: Int = 2,
        demote_after: Int = 2,
        unlock_next_at_rate: Double = 0.8
    ) {
        self.min_rate = min_rate
        self.start_rate = start_rate
        self.max_rate = max_rate
        self.step_up = step_up
        self.step_down = step_down
        self.promote_after = promote_after
        self.demote_after = demote_after
        self.unlock_next_at_rate = unlock_next_at_rate
    }
}

// MARK: - Errors

public enum LessonStoreError: LocalizedError {
    case manifestNotFound
    case sha256Mismatch(file: String, expected: String, actual: String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .manifestNotFound:
            return "manifest.json was not found in the selected folder."
        case .sha256Mismatch(let file, let expected, let actual):
            return "SHA-256 verification failed for '\(file)'. Expected \(expected.prefix(8))..., got \(actual.prefix(8))..."
        case .downloadFailed(let reason):
            return "Failed to download lesson: \(reason)"
        }
    }
}

// MARK: - Sample Generator for Dev / Offline Mode

extension LessonManifest {
    public static func makeSampleFilmiManifest() -> LessonManifest {
        let bpm = 112.5
        let anchor = 0.53
        let beatPeriod = 60.0 / bpm
        var beats: [BeatGridInfo.Beat] = []
        for i in 0..<30 {
            let t = anchor + Double(i) * beatPeriod
            let phrase = (i / 8) + 1
            let count = (i % 8) + 1
            beats.append(BeatGridInfo.Beat(t: (t * 1000).rounded() / 1000, phrase: phrase, count: count))
        }

        let segments: [SegmentInfo] = [
            SegmentInfo(
                id: "A",
                title: "The Attitude Intro",
                start_s: 0.53,
                end_s: 4.80,
                teach_order: 1,
                difficulty: 2,
                focus: ["arms", "hands", "hips", "feet"],
                cues: [
                    "Right hand flicks by the right ear on 1-2-3-4",
                    "Left hip and knee pop out with each flick",
                    "Switch hands on 5-6, gather to the chest on 7-8"
                ]
            ),
            SegmentInfo(
                id: "B",
                title: "Peek-a-Boo to Lateral Sweep",
                start_s: 4.80,
                end_s: 6.40,
                teach_order: 2,
                difficulty: 2,
                focus: ["arms", "hands"],
                cues: [
                    "Palms together over the nose on 1",
                    "Forearms fold and sweep across the chest to your left on 3"
                ]
            ),
            SegmentInfo(
                id: "C",
                title: "The Hook Groove",
                start_s: 6.40,
                end_s: 9.07,
                teach_order: 3,
                difficulty: 4,
                focus: ["arms", "hips", "feet"],
                cues: [
                    "Heel-hip bounce on 5-6-7-8",
                    "Wrists roll by the left shoulder"
                ]
            ),
            SegmentInfo(
                id: "D",
                title: "Shimmy, Crown Lotus and Finale",
                start_s: 9.07,
                end_s: 14.93,
                teach_order: 4,
                difficulty: 2,
                focus: ["arms", "hands", "torso"],
                cues: [
                    "Shoulder shimmy at the collarbone",
                    "Hands trace the face and meet overhead on 8",
                    "Open palms forward, then drop to rest"
                ]
            ),
            SegmentInfo(
                id: "full",
                kind: "full_run",
                title: "Full Routine",
                start_s: 0.53,
                end_s: 14.93,
                teach_order: 5,
                difficulty: 3,
                focus: ["arms", "hands", "hips", "feet"],
                cues: [
                    "A, B, C, D without stopping"
                ]
            )
        ]

        return LessonManifest(
            schema: "groove.lesson/1",
            lesson_id: "b6f14c2e-7d0a-4b8e-9c31-5a2f0e8d4b17",
            course_slug: "bollywood-basics",
            lesson_slug: "img4941-routine",
            package_version: 1,
            title: "Filmi Routine 1",
            requires: RequiresInfo(engine_major: 2, skeleton: "groove.canonical/1"),
            extractor: ExtractorInfo(
                pose_model: "pose_landmarker_full",
                pose_model_sha256: "5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1",
                mediapipe_python: "1.2.0"
            ),
            video: VideoInfo(
                file: "video.mp4",
                duration_s: 16.33,
                fps: 30.0,
                width: 720,
                height: 1280,
                mirrored: false,
                default_display_flip: true
            ),
            poster: "poster.jpg",
            reference: ReferenceInfo(file: "reference_pose.json", frame_count: 490),
            beat_grid: BeatGridInfo(bpm: bpm, anchor_s: anchor, source: "author_confirmed", beats: beats),
            segments: segments,
            windows: [
                WindowInfo(kind: "clasp", start_s: 4.80, end_s: 5.87, mask: ["hand_shape"], tolerance_scale: ["leftWrist": 2.0, "rightWrist": 2.0]),
                WindowInfo(kind: "clasp", start_s: 12.75, end_s: 13.65, mask: ["hand_shape"], tolerance_scale: ["leftWrist": 2.0, "rightWrist": 2.0])
            ],
            practice: PracticeInfo(count_in_beats: 4, adaptive_speed: AdaptiveSpeedPolicy()),
            files: [
                "video.mp4": "0000000000000000000000000000000000000000000000000000000000000000",
                "reference_pose.json": "0000000000000000000000000000000000000000000000000000000000000000",
                "poster.jpg": "0000000000000000000000000000000000000000000000000000000000000000"
            ]
        )
    }
}
