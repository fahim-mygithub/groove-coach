import GrooveCore
import SwiftUI

/// Joint name -> worst severity ("ok" / "warn" / "off") across position and angle verdicts,
/// plus `LiveMatcher` limb-state colour mapping for 10-foot TV and phone overlays.
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

    static func limbColor(_ state: LiveMatcher.LimbState?) -> Color {
        switch state {
        case .ok: return .green
        case .warn: return .yellow
        case .off: return .red
        case nil: return .white.opacity(0.75)
        }
    }
}

/// Stick figure with joints coloured ok (green) / warn (yellow) / off (red), and optional live
/// `LiveMatcher` limb-segment colouring (`limbStates`) for real-time coaching feedback.
/// `joints` are normalised 0...1 points with y down inside `imageAspect`-shaped content (width / height).
struct SkeletonOverlay: View {
    let joints: [String: CGPoint]
    let severities: [String: String]
    var imageAspect: Double = 9.0 / 16.0
    var limbStates: [LiveMatcher.Limb: LiveMatcher.LimbState]? = nil
    /// Set `true` when `LiveMatcher` was initialised with `mirrored: true` (`swapMirrored` maps the learner's
    /// anatomical left limbs onto `.right*` in reference space so screen-left matches the flipped teacher).
    var mirroredLimbs: Bool = false
    /// Scales stroke widths and joint radii up for 10-foot TV legibility (2–4 m viewing distance).
    var tvScale: Bool = false

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

    static func limb(from a: String, to b: String, mirrored: Bool = false) -> LiveMatcher.Limb? {
        let base: LiveMatcher.Limb?
        switch (a, b) {
        case ("leftShoulder", "leftElbow"), ("leftElbow", "leftShoulder"):
            base = .leftUpperArm
        case ("leftElbow", "leftWrist"), ("leftWrist", "leftElbow"):
            base = .leftForearm
        case ("rightShoulder", "rightElbow"), ("rightElbow", "rightShoulder"):
            base = .rightUpperArm
        case ("rightElbow", "rightWrist"), ("rightWrist", "rightElbow"):
            base = .rightForearm
        case ("leftHip", "leftKnee"), ("leftKnee", "leftHip"):
            base = .leftThigh
        case ("leftKnee", "leftAnkle"), ("leftAnkle", "leftKnee"):
            base = .leftShin
        case ("rightHip", "rightKnee"), ("rightKnee", "rightHip"):
            base = .rightThigh
        case ("rightKnee", "rightAnkle"), ("rightAnkle", "rightKnee"):
            base = .rightShin
        default:
            base = nil
        }
        guard let limb = base else { return nil }
        guard mirrored else { return limb }
        switch limb {
        case .leftUpperArm: return .rightUpperArm
        case .leftForearm: return .rightForearm
        case .rightUpperArm: return .leftUpperArm
        case .rightForearm: return .leftForearm
        case .leftThigh: return .rightThigh
        case .leftShin: return .rightShin
        case .rightThigh: return .leftThigh
        case .rightShin: return .leftShin
        }
    }

    var body: some View {
        GeometryReader { geo in
            let rect = fittedRect(in: geo.size)
            let baseLineWidth: CGFloat = tvScale ? 5.5 : 3.0
            let emphasizedLineWidth: CGFloat = tvScale ? 7.5 : 4.5
            let defaultDotRadius: CGFloat = tvScale ? 6.0 : 4.0
            let flaggedDotRadius: CGFloat = tvScale ? 10.0 : 7.0

            Canvas { context, _ in
                func place(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
                }
                for (a, b) in Self.bones {
                    guard let pa = joints[a], let pb = joints[b] else { continue }
                    var path = Path()
                    path.move(to: place(pa))
                    path.addLine(to: place(pb))
                    let matchedState: LiveMatcher.LimbState?
                    if let limbStates, let mappedLimb = Self.limb(from: a, to: b, mirrored: mirroredLimbs) {
                        matchedState = limbStates[mappedLimb]
                    } else {
                        matchedState = nil
                    }
                    let strokeColor: Color = limbStates != nil
                        ? JointSeverityMap.limbColor(matchedState)
                        : .white.opacity(0.7)
                    let width: CGFloat = (matchedState == .off || matchedState == .warn)
                        ? emphasizedLineWidth
                        : baseLineWidth
                    context.stroke(
                        path,
                        with: .color(strokeColor),
                        style: StrokeStyle(lineWidth: width, lineCap: .round)
                    )
                }
                for (name, p) in joints {
                    let c = place(p)
                    let r: CGFloat = severities[name] == nil ? defaultDotRadius : flaggedDotRadius
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

/// Transient capsule banner shown when a hands-free gesture fires (§5.4).
/// Defaults to phone sizing (`tvScale = false`); set `tvScale = true` for the `40 pt` bold 10-foot TV banner.
struct GestureToast: View {
    let text: String
    var tvScale: Bool = false
    var icon: String? = nil

    var body: some View {
        if tvScale {
            HStack(spacing: 14) {
                Image(systemName: icon ?? "hand.wave.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.cyan)
                Text(text)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(Color.black.opacity(0.84), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.cyan.opacity(0.8), lineWidth: 2.5)
            )
            .shadow(color: .black.opacity(0.55), radius: 14, y: 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.subheadline.bold())
                }
                Text(text)
                    .font(.subheadline.bold())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Pre-trigger overhead hands-up hold progress ring (`0...1`, visible when `progress >= visibilityThreshold`, §5.4).
struct GestureHoldRingView: View {
    /// Default pre-trigger visibility threshold (`holdProgress >= 0.15`, spec §5.4).
    static let defaultVisibilityThreshold: Double = 0.15

    let progress: Double
    var phase: CoachingPhase = .idle
    var labelOverride: String? = nil
    var tvScale: Bool = true
    var visibilityThreshold: Double = Self.defaultVisibilityThreshold

    static func defaultPrompt(for phase: CoachingPhase) -> String {
        switch phase {
        case .idle:
            return "Hold hands up to Start…"
        case .countIn:
            return "Hold hands up to Cancel…"
        case .recording:
            return "Hold still to Pause…"
        case .results:
            return "Hold hands up to Repeat…"
        case .paused:
            return "Hold hands up to Restart…"
        case .calibrating, .analyzing, .clapSync:
            return "Hold hands up…"
        }
    }

    var body: some View {
        let clamped = min(1.0, max(0.0, progress))
        if clamped >= visibilityThreshold {
            let ringSize: CGFloat = tvScale ? 68 : 36
            let strokeW: CGFloat = tvScale ? 7.5 : 4.0
            let isPauseOrCancel = (phase == .countIn || phase == .recording)
            let accent: Color = isPauseOrCancel ? .orange : .cyan

            HStack(spacing: tvScale ? 18 : 10) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.24), lineWidth: strokeW)
                    Circle()
                        .trim(from: 0, to: CGFloat(clamped))
                        .stroke(accent, style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "hands.sparkles.fill")
                        .font(.system(size: tvScale ? 26 : 14, weight: .bold))
                        .foregroundStyle(accent)
                }
                .frame(width: ringSize, height: ringSize)

                VStack(alignment: .leading, spacing: tvScale ? 4 : 2) {
                    Text(labelOverride ?? Self.defaultPrompt(for: phase))
                        .font(
                            tvScale
                                ? .system(size: 30, weight: .bold, design: .rounded)
                                : .subheadline.bold()
                        )
                        .foregroundStyle(.white)
                    Text(String(format: "%.0f%%", clamped * 100))
                        .font(
                            tvScale
                                ? .system(size: 20, weight: .bold, design: .monospaced)
                                : .caption2.monospacedDigit().bold()
                        )
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, tvScale ? 24 : 12)
            .padding(.vertical, tvScale ? 14 : 8)
            .background(Color.black.opacity(0.78), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(accent.opacity(0.75), lineWidth: tvScale ? 2.0 : 1.0)
            )
            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
            .allowsHitTesting(false)
        }
    }
}

/// Clean-beat streak pill rendered alongside live limb feedback (`LiveMatcher.LiveState.streak`, §4.1 item 2).
struct CleanBeatStreakBadge: View {
    let streak: Int
    var tvScale: Bool = true

    var body: some View {
        let hot = streak >= 4
        let active = streak >= 1
        let accent: Color = hot ? .yellow : (active ? .green : .white.opacity(0.65))

        HStack(spacing: tvScale ? 10 : 5) {
            Image(systemName: hot ? "flame.fill" : "checkmark.circle.fill")
                .font(.system(size: tvScale ? 24 : 12, weight: .bold))
                .foregroundStyle(accent)
            Text(streak == 1 ? "1 CLEAN BEAT" : "\(streak) CLEAN BEATS")
                .font(
                    tvScale
                        ? .system(size: 22, weight: .heavy, design: .rounded)
                        : .caption.bold()
                )
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, tvScale ? 16 : 9)
        .padding(.vertical, tvScale ? 9 : 5)
        .background(Color.black.opacity(0.74), in: Capsule())
        .overlay(
            Capsule()
                .stroke(accent.opacity(0.7), lineWidth: tvScale ? 2.0 : 1.0)
        )
        .allowsHitTesting(false)
    }
}
