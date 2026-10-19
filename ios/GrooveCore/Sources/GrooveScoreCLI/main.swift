import Foundation
import GrooveCore

struct GoldenDataset: Codable {
    let references: [String: GrooveScoringEngine.PoseClip]
    let golden_clips: [GrooveScoringEngine.PoseClip]
}

let args = CommandLine.arguments
let configPath = args.count > 1 ? args[1] : "../../config/groove_config.json"
let datasetPath = args.count > 2 ? args[2] : "../../fixtures/golden_clips.json"

let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
let datasetData = try Data(contentsOf: URL(fileURLWithPath: datasetPath))

let decoder = JSONDecoder()
let config = try decoder.decode(GrooveScoringEngine.GrooveConfig.self, from: configData)
let dataset = try decoder.decode(GoldenDataset.self, from: datasetData)

var results: [GrooveScoringEngine.AttemptScoreResult] = []
for clip in dataset.golden_clips {
    guard let ref = dataset.references[clip.move_tag] else {
        fatalError("Missing reference for move_tag \(clip.move_tag)")
    }
    let res = GrooveScoringEngine.scoreAttempt(attempt: clip, reference: ref, config: config)
    results.append(res)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let outData = try encoder.encode(results)
if let jsonString = String(data: outData, encoding: .utf8) {
    print(jsonString)
}
