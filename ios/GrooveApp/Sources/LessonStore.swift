import CryptoKit
import Foundation
import GrooveCore

public typealias LessonManifest = LessonPackage.Manifest

extension LessonPackage.Segment: Identifiable {}

/// Manages lesson packages stored on device:
/// - downloads packages to a staging directory,
/// - verifies SHA-256 integrity against `manifest.files`,
/// - moves verified packages atomically to `Application Support/Lessons/{lesson_id}/v{n}/` (excluded from backup),
/// - retains older versions until the new one successfully verifies,
/// - caches catalog metadata locally for offline access,
/// - persists per-segment take history and evaluates adaptive speed progression,
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
    public func loadManifest(lessonId: String, version: Int) -> LessonPackage.Manifest? {
        let dir = lessonVersionDirectory(lessonId: lessonId, version: version)
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(LessonPackage.Manifest.self, from: data)
    }

    /// Resolves the local URL of the video file for a downloaded lesson.
    public func localVideoURL(for manifest: LessonPackage.Manifest) -> URL? {
        let dir = lessonVersionDirectory(lessonId: manifest.lessonID, version: manifest.packageVersion)
        let videoURL = dir.appendingPathComponent(manifest.video.file)
        return FileManager.default.fileExists(atPath: videoURL.path) ? videoURL : nil
    }

    /// Resolves the local URL of the reference pose JSON file for a downloaded lesson.
    public func localReferenceURL(for manifest: LessonPackage.Manifest) -> URL? {
        let dir = lessonVersionDirectory(lessonId: manifest.lessonID, version: manifest.packageVersion)
        let refURL = dir.appendingPathComponent(manifest.reference.file)
        return FileManager.default.fileExists(atPath: refURL.path) ? refURL : nil
    }

    /// Loads the reference pose clip from disk.
    public func loadReferenceClip(for manifest: LessonPackage.Manifest) -> GrooveScoringEngine.PoseClip? {
        guard let url = localReferenceURL(for: manifest),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GrooveScoringEngine.PoseClip.self, from: data)
    }

    // MARK: - Per-Segment Take History & Adaptive Progression

    public struct PersistedTakeRecord: Codable, Sendable {
        public let passed: Bool
        public let rate: Double?
        public let timestamp: Date

        public init(passed: Bool, rate: Double?, timestamp: Date = Date()) {
            self.passed = passed
            self.rate = rate
            self.timestamp = timestamp
        }
    }

    public func takeHistoryKey(lessonID: String, version: Int, segmentID: String) -> String {
        "groove_takes_\(lessonID)_v\(version)_\(segmentID)"
    }

    public func loadTakes(lessonID: String, version: Int, segmentID: String) -> [LessonPackage.Take] {
        let key = takeHistoryKey(lessonID: lessonID, version: version, segmentID: segmentID)
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([PersistedTakeRecord].self, from: data) else {
            return []
        }
        return records.map { LessonPackage.Take(passed: $0.passed, rate: $0.rate) }
    }

    public func saveTake(lessonID: String, version: Int, segmentID: String, passed: Bool, rate: Double?) {
        let key = takeHistoryKey(lessonID: lessonID, version: version, segmentID: segmentID)
        var records: [PersistedTakeRecord] = []
        if let data = UserDefaults.standard.data(forKey: key),
           let existing = try? JSONDecoder().decode([PersistedTakeRecord].self, from: data) {
            records = existing
        }
        records.append(PersistedTakeRecord(passed: passed, rate: rate))
        if let encoded = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    public func clearTakes(lessonID: String, version: Int, segmentID: String) {
        let key = takeHistoryKey(lessonID: lessonID, version: version, segmentID: segmentID)
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Check if a segment is unlocked according to the teaching sequence and previous segment performance (spec §8 Q6).
    public func isSegmentUnlocked(manifest: LessonPackage.Manifest, segmentID: String) -> Bool {
        guard let seg = manifest.segments.first(where: { $0.id == segmentID }) else { return false }
        if seg.teachOrder <= 1 { return true }
        let sorted = manifest.segments.sorted(by: { $0.teachOrder < $1.teachOrder })
        guard let idx = sorted.firstIndex(where: { $0.id == segmentID }), idx > 0 else { return true }
        let prevSeg = sorted[idx - 1]
        let prevTakes = loadTakes(lessonID: manifest.lessonID, version: manifest.packageVersion, segmentID: prevSeg.id)
        let prevPolicy = prevSeg.adaptiveSpeed ?? manifest.practice.adaptiveSpeed
        let (_, unlocked) = (try? LessonPackage.nextRate(policy: prevPolicy, history: prevTakes)) ?? (prevPolicy.startRate, false)
        return unlocked
    }

    /// Returns the current playback rate offered by the adaptive speed policy for a segment.
    public func currentRate(manifest: LessonPackage.Manifest, segmentID: String) -> Double {
        guard let seg = manifest.segments.first(where: { $0.id == segmentID }) else {
            return manifest.practice.adaptiveSpeed.startRate
        }
        let policy = seg.adaptiveSpeed ?? manifest.practice.adaptiveSpeed
        let takes = loadTakes(lessonID: manifest.lessonID, version: manifest.packageVersion, segmentID: segmentID)
        let (rate, _) = (try? LessonPackage.nextRate(policy: policy, history: takes)) ?? (policy.startRate, false)
        return rate
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
    public func downloadLesson(item: CatalogItem) async throws -> LessonPackage.Manifest {
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

        let manifest = try JSONDecoder().decode(LessonPackage.Manifest.self, from: manifestData)
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
        let targetVersionDir = lessonVersionDirectory(lessonId: manifest.lessonID, version: manifest.packageVersion)
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
    @discardableResult
    public func importPackageFromFolder(folderURL: URL) throws -> LessonPackage.Manifest {
        let isSecurityScoped = folderURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped { folderURL.stopAccessingSecurityScopedResource() }
        }

        let manifestURL = folderURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw LessonStoreError.manifestNotFound
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(LessonPackage.Manifest.self, from: manifestData)

        let targetDir = lessonVersionDirectory(lessonId: manifest.lessonID, version: manifest.packageVersion)
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
            course_id: "dev-course-\(manifest.courseSlug)",
            course_slug: manifest.courseSlug,
            course_title: manifest.courseSlug.replacingOccurrences(of: "-", with: " ").capitalized,
            lesson_id: manifest.lessonID,
            lesson_slug: manifest.lessonSlug,
            lesson_title: manifest.title,
            position: 1,
            package_version: manifest.packageVersion,
            storage_prefix: "dev/\(manifest.courseSlug)/\(manifest.lessonSlug)/v\(manifest.packageVersion)",
            manifest: manifest,
            pose_model_sha256: manifest.extractor.poseModelSha256,
            published_at: ISO8601DateFormatter().string(from: Date())
        )

        catalog.removeAll { $0.lesson_id == manifest.lessonID && $0.package_version == manifest.packageVersion }
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
        let sampleManifest = Self.makeSampleFilmiManifest()
        let seedItem = CatalogItem(
            course_id: "course-bollywood-basics",
            course_slug: "bollywood-basics",
            course_title: "Bollywood Basics",
            lesson_id: sampleManifest.lessonID,
            lesson_slug: sampleManifest.lessonSlug,
            lesson_title: sampleManifest.title,
            position: 1,
            package_version: 1,
            storage_prefix: "lesson-packages/bollywood-basics/img4941-routine/v1",
            manifest: sampleManifest,
            pose_model_sha256: sampleManifest.extractor.poseModelSha256,
            published_at: "2026-10-31T00:00:00Z"
        )
        self.catalog = [seedItem]
    }

    public static func makeSampleFilmiManifest() -> LessonPackage.Manifest {
        let json = sampleManifestJSON
        return try! JSONDecoder().decode(LessonPackage.Manifest.self, from: json.data(using: .utf8)!)
    }

    public static let sampleManifestJSON = """
    {
      "schema": "groove.lesson/1",
      "lesson_id": "b6f14c2e-7d0a-4b8e-9c31-5a2f0e8d4b17",
      "course_slug": "bollywood-basics",
      "lesson_slug": "img4941-routine",
      "package_version": 1,
      "title": "Filmi Routine 1",
      "requires": {
        "engine_major": 2,
        "skeleton": "groove.canonical/1"
      },
      "extractor": {
        "pose_model": "pose_landmarker_full",
        "pose_model_sha256": "5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1",
        "mediapipe_python": "1.2.0",
        "running_mode": "VIDEO",
        "num_poses": 1
      },
      "video": {
        "file": "video.mp4",
        "duration_s": 16.33,
        "fps": 30,
        "width": 720,
        "height": 1280,
        "mirrored": false,
        "default_display_flip": true
      },
      "poster": "poster.jpg",
      "reference": {
        "file": "reference_pose.json",
        "frame_count": 490
      },
      "beat_grid": {
        "bpm": 112.5,
        "anchor_s": 0.53,
        "source": "author_confirmed",
        "detector": "beat_this_small_cpu",
        "beats": [
          { "t": 0.53, "phrase": 1, "count": 1 },
          { "t": 1.063, "phrase": 1, "count": 2 },
          { "t": 1.597, "phrase": 1, "count": 3 },
          { "t": 2.13, "phrase": 1, "count": 4 },
          { "t": 2.663, "phrase": 1, "count": 5 },
          { "t": 3.197, "phrase": 1, "count": 6 },
          { "t": 3.73, "phrase": 1, "count": 7 },
          { "t": 4.263, "phrase": 1, "count": 8 },
          { "t": 4.797, "phrase": 2, "count": 1 },
          { "t": 5.33, "phrase": 2, "count": 2 },
          { "t": 5.863, "phrase": 2, "count": 3 },
          { "t": 6.397, "phrase": 2, "count": 4 },
          { "t": 6.93, "phrase": 2, "count": 5 },
          { "t": 7.463, "phrase": 2, "count": 6 },
          { "t": 7.997, "phrase": 2, "count": 7 },
          { "t": 8.53, "phrase": 2, "count": 8 },
          { "t": 9.063, "phrase": 3, "count": 1 },
          { "t": 9.597, "phrase": 3, "count": 2 },
          { "t": 10.13, "phrase": 3, "count": 3 },
          { "t": 10.663, "phrase": 3, "count": 4 },
          { "t": 11.197, "phrase": 3, "count": 5 },
          { "t": 11.73, "phrase": 3, "count": 6 },
          { "t": 12.263, "phrase": 3, "count": 7 },
          { "t": 12.797, "phrase": 3, "count": 8 },
          { "t": 13.33, "phrase": 4, "count": 1 },
          { "t": 13.863, "phrase": 4, "count": 2 },
          { "t": 14.397, "phrase": 4, "count": 3 },
          { "t": 14.93, "phrase": 4, "count": 4 },
          { "t": 15.463, "phrase": 4, "count": 5 },
          { "t": 15.997, "phrase": 4, "count": 6 }
        ]
      },
      "segments": [
        {
          "id": "A",
          "title": "The Attitude Intro",
          "start_s": 0.53,
          "end_s": 4.8,
          "teach_order": 1,
          "difficulty": 2,
          "focus": ["arms", "hands", "hips", "feet"],
          "cues": [
            "Right hand flicks by the right ear on 1-2-3-4",
            "Left hip and knee pop out with each flick",
            "Switch hands on 5-6, gather to the chest on 7-8"
          ]
        },
        {
          "id": "B",
          "title": "Peek-a-Boo to Lateral Sweep",
          "start_s": 4.8,
          "end_s": 6.4,
          "teach_order": 2,
          "difficulty": 2,
          "focus": ["arms", "hands"],
          "cues": [
            "Palms together over the nose on 1",
            "Forearms fold and sweep across the chest to your left on 3"
          ]
        },
        {
          "id": "C",
          "title": "The Hook Groove",
          "start_s": 6.4,
          "end_s": 9.07,
          "teach_order": 3,
          "difficulty": 4,
          "focus": ["arms", "hips", "feet"],
          "cues": [
            "Heel-hip bounce on 5-6-7-8",
            "Wrists roll by the left shoulder"
          ],
          "config_overrides": {
            "scoring_thresholds": {
              "gate": {
                "timing_source": "hits"
              }
            }
          }
        },
        {
          "id": "D",
          "title": "Shimmy, Crown Lotus and Finale",
          "start_s": 9.07,
          "end_s": 14.93,
          "teach_order": 4,
          "difficulty": 2,
          "focus": ["arms", "hands", "torso"],
          "cues": [
            "Shoulder shimmy at the collarbone",
            "Hands trace the face and meet overhead on 8",
            "Open palms forward, then drop to rest"
          ]
        },
        {
          "id": "full",
          "kind": "full_run",
          "title": "Full Routine",
          "start_s": 0.53,
          "end_s": 14.93,
          "teach_order": 5,
          "difficulty": 3,
          "focus": ["arms", "hands", "hips", "feet"],
          "cues": ["A, B, C, D without stopping"]
        }
      ],
      "windows": [
        {
          "kind": "clasp",
          "start_s": 4.8,
          "end_s": 5.87,
          "mask": ["hand_shape"],
          "tolerance_scale": {
            "leftWrist": 2.0,
            "rightWrist": 2.0
          }
        },
        {
          "kind": "clasp",
          "start_s": 12.75,
          "end_s": 13.65,
          "mask": ["hand_shape"],
          "tolerance_scale": {
            "leftWrist": 2.0,
            "rightWrist": 2.0
          }
        }
      ],
      "config_overrides": {
        "scoring_thresholds": {
          "shape": { "arm_weight": 0.35 },
          "groove": { "pass_min_score": 0 }
        }
      },
      "practice": {
        "count_in_beats": 4,
        "adaptive_speed": {
          "min_rate": 0.6,
          "start_rate": 0.7,
          "max_rate": 1.0,
          "step_up": 0.1,
          "step_down": 0.05,
          "promote_after": 2,
          "demote_after": 2,
          "unlock_next_at_rate": 0.8
        }
      },
      "files": {
        "video.mp4": "0000000000000000000000000000000000000000000000000000000000000000",
        "reference_pose.json": "0000000000000000000000000000000000000000000000000000000000000000",
        "poster.jpg": "0000000000000000000000000000000000000000000000000000000000000000"
      }
    }
    """
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
    public let manifest: LessonPackage.Manifest?
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
        manifest: LessonPackage.Manifest? = nil,
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
