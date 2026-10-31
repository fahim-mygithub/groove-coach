import GrooveCore
import SwiftUI

/// Joint name -> worst severity ("ok" / "warn" / "off") across position and angle verdicts.
enum JointSeverityMap {
    static func from(_ feedback: GrooveScoringEngine.JointFeedbackResult?) -> [String: String] {
        guard let feedback else { return [:] }
        var out: [String: String] = [:]
        for verdict in feedback.verdicts + feedback.angle_verdicts {
            if rank(verdict.severity) >= rank(out[verdict.joint] ?? "ok") {
                out[verdict.joint] = verdict.severity
            }
        }
        return out
    }

    static func rank(_ severity: String) -> Int {
        switch severity {
        case "off": return 2
        case "warn": return 1
        default: return 0
        }
    }

    static func color(_ severity: String?) -> Color {
        switch severity {
        case "off": return .red
        case "warn": return .yellow
        case "ok": return .green
        default: return .white.opacity(0.8)
        }
    }
}

/// Stick figure with joints coloured ok (green) / warn (yellow) / off (red).
/// `joints` are normalised 0...1 points with y down inside `imageAspect`-shaped content (width / height).
struct SkeletonOverlay: View {
    let joints: [String: CGPoint]
    let severities: [String: String]
    var imageAspect: Double = 9.0 / 16.0

    static let bones: [(String, String)] = [
        ("leftShoulder", "rightShoulder"), ("leftHip", "rightHip"),
        ("leftShoulder", "leftHip"), ("rightShoulder", "rightHip"),
        ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"),
        ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
        ("leftHip", "leftKnee"), ("leftKnee", "leftAnkle"),
        ("rightHip", "rightKnee"), ("rightKnee", "rightAnkle"),
        ("leftAnkle", "leftHeel"), ("leftHeel", "leftFootIndex"),
        ("rightAnkle", "rightHeel"), ("rightHeel", "rightFootIndex"),
        ("neck", "nose"), ("root", "spine"), ("spine", "centerShoulder")
    ]

    var body: some View {
        GeometryReader { geo in
            let rect = fittedRect(in: geo.size)
            Canvas { context, _ in
                func place(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
                }
                for (a, b) in Self.bones {
                    guard let pa = joints[a], let pb = joints[b] else { continue }
                    var path = Path()
                    path.move(to: place(pa))
                    path.addLine(to: place(pb))
                    context.stroke(path, with: .color(.white.opacity(0.7)), lineWidth: 3)
                }
                for (name, p) in joints {
                    let c = place(p)
                    let r: CGFloat = severities[name] == nil ? 4 : 7
                    let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    context.fill(dot, with: .color(JointSeverityMap.color(severities[name])))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Aspect-fit rect of the camera image inside the view (matches `.resizeAspect` on the preview layer).
    private func fittedRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, imageAspect > 0 else { return .zero }
        let viewAspect = Double(size.width / size.height)
        if viewAspect > imageAspect {
            let w = size.height * CGFloat(imageAspect)
            return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
        }
        let h = size.width / CGFloat(imageAspect)
        return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
    }
}

/// Results of one take: pass/fail, core scores, top correction hint, hit timing, hand shape and joint verdicts.
struct TakeResultView: View {
    let result: GrooveScoringEngine.AttemptScoreResult
    /// Learner pose (normalised, y down) at the first beat, for the coloured stick figure.
    let pose: [String: CGPoint]
    var onExport: (() -> Void)? = nil

    private var severities: [String: String] { JointSeverityMap.from(result.joint_feedback) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(result.passed ? "PASS" : "Keep drilling", systemImage: result.passed ? "checkmark.seal.fill" : "arrow.triangle.2.circlepath")
                    .font(.headline)
                    .foregroundStyle(result.passed ? .green : .orange)
                Spacer()
                Text(String(format: "%+.0f ms · %.0f%% on beat", result.mean_offset_ms, result.good_or_better_ratio * 100))
                    .font(.caption.monospacedDigit())
            }
            HStack(spacing: 12) {
                scoreChip("Shape", result.shape_score)
                scoreChip("Groove", result.groove_score)
                if let hit = result.hit_timing.hit_score { scoreChip("Hits", hit) }
                if let hand = result.hand_styling.hand_score { scoreChip("Hands", hand) }
            }

            if let hint = result.joint_feedback.top_hint {
                Label(hint.prefix(1).uppercased() + hint.dropFirst(), systemImage: "figure.dance")
                    .font(.title3.bold())
            } else if result.joint_feedback.status == "available" {
                Label("All joints within tolerance", systemImage: "figure.dance")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
            Text(result.top_issue)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                SkeletonOverlay(joints: pose, severities: severities, imageAspect: 0.6)
                    .frame(width: 110, height: 180)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    hitTimingText
                    handText
                    ForEach(Array(flagged.enumerated()), id: \.offset) { _, verdict in
                        HStack(spacing: 6) {
                            Circle().fill(JointSeverityMap.color(verdict.severity)).frame(width: 8, height: 8)
                            Text(verdict.hint ?? verdict.joint).font(.caption)
                        }
                    }
                }
            }

            if let onExport {
                Button {
                    onExport()
                } label: {
                    Label("Export Attempt Bundle", systemImage: "square.and.arrow.up")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 4)
            }
        }
    }

    private var flagged: [GrooveScoringEngine.JointVerdictSummary] {
        (result.joint_feedback.verdicts + result.joint_feedback.angle_verdicts)
            .filter { $0.severity != "ok" }
            .sorted { JointSeverityMap.rank($0.severity) > JointSeverityMap.rank($1.severity) }
            .prefix(4)
            .map { $0 }
    }

    @ViewBuilder private var hitTimingText: some View {
        if result.hit_timing.status == "available" {
            Label(hitSummary(result.hit_timing), systemImage: "metronome")
                .font(.caption)
        } else if result.hit_timing.status == "not_applicable" {
            Label("No hits in this move (continuous groove)", systemImage: "metronome")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func hitSummary(_ hits: GrooveScoringEngine.HitTimingResult) -> String {
        guard let mean = hits.mean_offset_ms else {
            return "Hits: none of \(hits.per_hit.count) accents landed"
        }
        let direction = mean >= 0 ? "late" : "early"
        return "Hits: \(hits.matched_count)/\(hits.per_hit.count) landed, \(Int(abs(mean).rounded())) ms \(direction)"
    }

    @ViewBuilder private var handText: some View {
        let hands = result.hand_styling
        if hands.status == "available" {
            Label("Hands: \(hands.user_shape ?? "?") (ref \(hands.reference_shape ?? "?"))", systemImage: "hand.raised")
                .font(.caption)
        } else if hands.status == "skipped" {
            Label("Hands not visible: styling skipped", systemImage: "hand.raised.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func scoreChip(_ title: String, _ value: Double) -> some View {
        VStack(spacing: 2) {
            Text(String(format: "%.0f", value)).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Small transient banner shown when a hands-free gesture fires.
struct GestureToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.bold())
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
