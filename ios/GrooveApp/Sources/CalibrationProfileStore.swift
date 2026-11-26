import AVFoundation
import Combine
import Foundation
import GrooveCore

/// Atomic disk store and runtime session tracker for `CalibrationProfileV2` (`groove.calibration/2`, spec §6.1, §6.2, §8.4).
/// Persists to `Application Support/Calibration/calibration_profile_v2.json` excluded from iCloud backup.
@MainActor
final class CalibrationProfileStore: ObservableObject {
    static let shared = CalibrationProfileStore()

    nonisolated static let directoryName = "Calibration"
    nonisolated static let fileName = "calibration_profile_v2.json"
    nonisolated static let pendingRouteOffsetsDefaultsKey = "GrooveCoach.pendingAirPlayRouteOffsetsMs"

    let directoryURL: URL
    let fileURL: URL

    /// Currently active persisted v2 profile (nil until first calibration completes or if cleared/invalid).
    @Published private(set) var activeProfileV2: CalibrationProfileV2?

    /// True once at least one non-skipped calibration has locked during this app launch (enables Tier-0 instant resume; §6.2).
    @Published private(set) var hasCalibratedInCurrentSession: Bool = false

    /// Set true when the user taps "Recalibrate Studio" (§6.2 Tier-2 trigger e); cleared once a non-skipped calibration saves.
    @Published var forceFullRecalibrationNext: Bool = false

    private var pendingRouteOffsetsMs: [String: Double]

    var storedProfile: CalibrationProfileV2? { activeProfileV2 }
    var activeLegacyProfile: CalibrationProfile? { activeProfileV2?.legacyProfile }

    init(baseDirectoryURL: URL? = nil) {
        let rootURL: URL = baseDirectoryURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let calDir = rootURL.appendingPathComponent(Self.directoryName, isDirectory: true)
        self.directoryURL = calDir
        self.fileURL = calDir.appendingPathComponent(Self.fileName, isDirectory: false)
        self.pendingRouteOffsetsMs = Self.loadPendingRouteOffsetsFromDefaults()

        Self.ensureDirectoryExcludedFromBackup(calDir)
        self.activeProfileV2 = Self.readFromDisk(at: self.fileURL)
    }

    // MARK: - Load / Save / Clear

    /// Reloads `calibration_profile_v2.json` from disk and updates `activeProfileV2`.
    @discardableResult
    func reload() -> CalibrationProfileV2? {
        let loaded = Self.readFromDisk(at: fileURL)
        activeProfileV2 = loaded
        return loaded
    }

    /// Atomically writes `profile` to `Application Support/Calibration/calibration_profile_v2.json`
    /// (excluding directory and file from iCloud backup) and updates `activeProfileV2`.
    @discardableResult
    func save(_ profile: CalibrationProfileV2, markSessionCalibrated: Bool = true) -> Bool {
        var merged = profile
        merged.schema = CalibrationProfileV2.currentSchema
        merged.schemaVersion = CalibrationProfileV2.currentSchemaVersion

        for (routeUID, offsetMs) in pendingRouteOffsetsMs where offsetMs.isFinite {
            if merged.environment.airplayRouteOffsetsMs[routeUID] == nil {
                merged.environment.airplayRouteOffsetsMs[routeUID] = offsetMs
            }
        }
        for (routeUID, offsetMs) in merged.environment.airplayRouteOffsetsMs where offsetMs.isFinite {
            pendingRouteOffsetsMs[routeUID] = offsetMs
        }
        Self.savePendingRouteOffsetsToDefaults(pendingRouteOffsetsMs)

        if let explicitLead = UserDefaults.standard.object(
            forKey: ExternalDisplayManager.tvVideoLeadOffsetDefaultsKey
        ) as? Double, explicitLead.isFinite {
            merged.environment.tvVideoLeadOffsetMs = explicitLead
        }

        let ok = Self.writeToDisk(merged, directoryURL: directoryURL, fileURL: fileURL)
        activeProfileV2 = merged
        if markSessionCalibrated {
            hasCalibratedInCurrentSession = true
            forceFullRecalibrationNext = false
        }
        return ok
    }

    /// Queues a full 9-pose Tier-2 studio recalibration for the next `CalibrationController.begin(...)` (§6.2 trigger e).
    func requestFullRecalibration() {
        forceFullRecalibrationNext = true
        hasCalibratedInCurrentSession = false
        DebugLog.info("calibration_profile_store queued Tier-2 full studio recalibration")
    }

    /// Deletes the persisted v2 profile from disk and resets in-session resume state.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        activeProfileV2 = nil
        hasCalibratedInCurrentSession = false
    }

    // MARK: - Audio / TV Sync Helpers (§4.2, §8.4, Orders #12 & #15)

    /// Effective audio latency in milliseconds for `PoseClip.audio_latency_ms` (§8.4):
    /// `baseOutputLatencyMs + (airplayRouteOffsetsMs[routeUID] ?? 0.0)`.
    func effectiveAudioLatencyMs(baseOutputLatencyMs: Double, routeUID: String? = nil) -> Double {
        let base = baseOutputLatencyMs.isFinite ? baseOutputLatencyMs : 0.0
        let resolvedUID = routeUID ?? Self.currentAudioRouteUID()
        let routeOffset = airplayRouteOffsetMs(forRouteUID: resolvedUID)
        return base + routeOffset
    }

    /// Returns the stored downstream TV/AirPlay route offset (ms) for `routeUID` (`0.0` when unset).
    func airplayRouteOffsetMs(forRouteUID routeUID: String? = nil) -> Double {
        let resolvedUID = routeUID ?? Self.currentAudioRouteUID()
        guard !resolvedUID.isEmpty, resolvedUID != "none" else { return 0.0 }
        let value = activeProfileV2?.environment.airplayRouteOffsetsMs[resolvedUID]
            ?? pendingRouteOffsetsMs[resolvedUID]
            ?? 0.0
        return value.isFinite ? value : 0.0
    }

    /// Stores a calibrated AirPlay/TV audio route offset (`ms`) keyed by `routeUID` and persists to disk (§4.2 item 4, Order #15).
    @discardableResult
    func setAirPlayRouteOffsetMs(_ offsetMs: Double, forRouteUID routeUID: String) -> Bool {
        guard !routeUID.isEmpty, routeUID != "none", offsetMs.isFinite else { return false }
        let clamped = min(300.0, max(-150.0, offsetMs))
        pendingRouteOffsetsMs[routeUID] = clamped
        Self.savePendingRouteOffsetsToDefaults(pendingRouteOffsetsMs)

        guard var profile = activeProfileV2 else {
            return true
        }
        profile.environment.airplayRouteOffsetsMs[routeUID] = clamped
        return save(profile, markSessionCalibrated: hasCalibratedInCurrentSession)
    }

    /// Alias convenience matching `(routeUID:offsetMs:)` parameter order for Order #15 callers.
    @discardableResult
    func updateAirPlayRouteOffset(routeUID: String, offsetMs: Double) -> Bool {
        setAirPlayRouteOffsetMs(offsetMs, forRouteUID: routeUID)
    }

    /// Host-time TV video lead offset in milliseconds (`> 0` advances video relative to audio; §4.2).
    var tvVideoLeadOffsetMs: Double {
        if let explicit = UserDefaults.standard.object(
            forKey: ExternalDisplayManager.tvVideoLeadOffsetDefaultsKey
        ) as? Double, explicit.isFinite {
            return explicit
        }
        if let stored = activeProfileV2?.environment.tvVideoLeadOffsetMs, stored.isFinite {
            return stored
        }
        let live = ExternalDisplayManager.shared.tvVideoLeadOffsetMs
        return live.isFinite ? live : 0.0
    }

    /// Host-time TV video lead offset in seconds for `LessonPlayerViewModel` scheduling (`§4.2`, Order #12).
    var tvVideoLeadOffsetSeconds: Double {
        tvVideoLeadOffsetMs / 1000.0
    }

    /// Updates `tvVideoLeadOffsetMs` in both `ExternalDisplayManager` and the persisted `CalibrationProfileV2`.
    @discardableResult
    func setTVVideoLeadOffsetMs(_ offsetMs: Double) -> Bool {
        guard offsetMs.isFinite else { return false }
        ExternalDisplayManager.shared.commitTVVideoLeadOffsetMs(offsetMs)
        guard var profile = activeProfileV2 else { return true }
        profile.environment.tvVideoLeadOffsetMs = ExternalDisplayManager.shared.tvVideoLeadOffsetMs
        return save(profile, markSessionCalibrated: hasCalibratedInCurrentSession)
    }

    // MARK: - Private Disk & Audio Route Helpers

    private static func currentAudioRouteUID() -> String {
        let managerUID = ExternalDisplayManager.shared.audioRouteUID
        if !managerUID.isEmpty && managerUID != "none" {
            return managerUID
        }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let uids = outputs.map { $0.uid }.filter { !$0.isEmpty }
        return uids.isEmpty ? "none" : uids.joined(separator: ",")
    }

    private static func ensureDirectoryExcludedFromBackup(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        excludeFromBackup(url)
    }

    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private static func readFromDisk(at fileURL: URL) -> CalibrationProfileV2? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let decoded = try JSONDecoder().decode(CalibrationProfileV2.self, from: data)
            guard decoded.isValidSchema else {
                DebugLog.warn(
                    "calibration_profile_store ignored unsupported schema=\(decoded.schema) v=\(decoded.schemaVersion)"
                )
                return nil
            }
            return decoded
        } catch {
            DebugLog.warn("calibration_profile_store decode failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func writeToDisk(_ profile: CalibrationProfileV2, directoryURL: URL, fileURL: URL) -> Bool {
        ensureDirectoryExcludedFromBackup(directoryURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(profile)
            try data.write(to: fileURL, options: [.atomic])
            excludeFromBackup(fileURL)
            DebugLog.info(
                "calibration_profile_store saved mode=\(profile.cameraMode.rawValue) "
                + "heightM=\(profile.body.dancerHeightM.map { String(format: "%.2f", $0) } ?? "nil") "
                + "scale=\(String(format: "%.3f", profile.body.metricScaleFactor))"
            )
            return true
        } catch {
            DebugLog.warn("calibration_profile_store write failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func loadPendingRouteOffsetsFromDefaults() -> [String: Double] {
        guard let raw = UserDefaults.standard.dictionary(forKey: pendingRouteOffsetsDefaultsKey) else {
            return [:]
        }
        var result: [String: Double] = [:]
        for (key, value) in raw {
            if let num = value as? Double, num.isFinite {
                result[key] = num
            } else if let nsNum = value as? NSNumber {
                let d = nsNum.doubleValue
                if d.isFinite { result[key] = d }
            }
        }
        return result
    }

    private static func savePendingRouteOffsetsToDefaults(_ offsets: [String: Double]) {
        UserDefaults.standard.set(offsets, forKey: pendingRouteOffsetsDefaultsKey)
    }
}
