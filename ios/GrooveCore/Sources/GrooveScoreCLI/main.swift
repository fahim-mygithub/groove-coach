import Foundation
import GrooveCore

struct GoldenDataset: Codable {
    let references: [String: GrooveScoringEngine.PoseClip]
    let golden_clips: [GrooveScoringEngine.PoseClip]
}

/// Each clip's optional `config_overrides` (fixtures/lesson_clips.json), read alongside the PoseClip decode.
struct ClipOverrides: Decodable {
    let config_overrides: GrooveScoringEngine.JSONValue?
}

struct OverridesDataset: Decodable {
    let golden_clips: [ClipOverrides]
}

let args = CommandLine.arguments
let configPath = args.count > 1 ? args[1] : "../../config/groove_config.json"
let datasetPath = args.count > 2 ? args[2] : "../../fixtures/golden_clips.json"

let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
let datasetData = try Data(contentsOf: URL(fileURLWithPath: datasetPath))

let decoder = JSONDecoder()
let config = try GrooveScoringEngine.decodeConfig(configData)
let dataset = try decoder.decode(GoldenDataset.self, from: datasetData)
let overrides = try decoder.decode(OverridesDataset.self, from: datasetData)

var results: [GrooveScoringEngine.AttemptScoreResult] = []
for (idx, clip) in dataset.golden_clips.enumerated() {
    guard let ref = dataset.references[clip.move_tag] else {
        fatalError("Missing reference for move_tag \(clip.move_tag)")
    }
    // Same rule as scripts/check_parity.py: the clip's overrides are deep-merged over the config JSON, then decoded.
    let clipConfig = try overrides.golden_clips[idx].config_overrides.map {
        try GrooveScoringEngine.decodeConfig(configData, overrides: [$0])
    } ?? config
    let res = GrooveScoringEngine.scoreAttempt(attempt: clip, reference: ref, config: clipConfig)
    results.append(res)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let outData = try encoder.encode(results)
if let jsonString = String(data: outData, encoding: .utf8) {
    print(jsonString)
}
