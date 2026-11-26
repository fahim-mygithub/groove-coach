import GrooveCore
import SwiftUI

/// Minimal pure-black (`#000000`) OLED phone status & emergency-touch screen displayed on the iPhone
/// while the 16:9 external AirPlay/TV `UIWindowScene` (`TVCoachingStageView`) is active (spec §1.2, §4.1 item 4, §4.3).
///
/// Renders zero `AVCaptureVideoPreviewLayer`s to conserve thermal/GPU budget while providing:
/// - Dim status header (*"TV Stage Active · Rear Camera + LiDAR"*, or disconnect banner if AirPlay drops)
/// - Audio route & OS output latency badge
/// - Three oversized emergency touch buttons (**Pause / Resume**, **Skip Calibration**, **Use Phone Screen (Front Camera)**)
/// - Conditional **Sync TV Audio** button shown only when `ExternalDisplayManager.shared.clapSyncAction != nil` (Order #15).
@MainActor
struct PhoneControllerStatusView: View {
    @ObservedObject private var externalDisplay = ExternalDisplayManager.shared

    var phase: CoachingPhase
    var cameraMode: CameraMode = .rearLiDAR
    var title: String? = nil
    var statusText: String? = nil
    var onPauseResume: () -> Void
    var onSkipCalibration: (() -> Void)? = nil
    var onUsePhoneScreen: () -> Void
    var onReconnectAirPlay: (() -> Void)? = nil

    private var headerTitle: String {
        guard externalDisplay.isConnected else {
            return "TV Disconnected · Coaching Paused"
        }
        switch cameraMode {
        case .rearLiDAR:
            return "TV Stage Active · Rear Camera + LiDAR"
        case .rearWide:
            return "TV Stage Active · Rear Camera"
        case .frontSelfView:
            return "TV Stage Active · Front Camera"
        }
    }

    private var phaseBadgeText: String {
        switch phase {
        case .idle:
            return "READY"
        case .calibrating:
            return "CALIBRATING"
        case .clapSync:
            return "AUDIO SYNC"
        case .countIn:
            return "COUNT-IN"
        case .recording:
            return "RECORDING TAKE"
        case .analyzing:
            return "SCORING"
        case .results:
            return "RESULTS ON TV"
        case .paused:
            return "PAUSED"
        }
    }

    private var isActiveTakeRunning: Bool {
        phase == .countIn || phase == .recording
    }

    private var pauseResumeTitle: String {
        if isActiveTakeRunning {
            return "Pause Take"
        }
        switch phase {
        case .paused:
            return "Resume Take"
        case .calibrating:
            return "Pause Calibration"
        case .results:
            return "Repeat Take"
        case .idle, .analyzing, .clapSync:
            return "Start / Resume"
        case .countIn, .recording:
            return "Pause Take"
        }
    }

    private var pauseResumeIcon: String {
        isActiveTakeRunning || phase == .calibrating ? "pause.fill" : "play.fill"
    }

    private var canSkipCalibration: Bool {
        phase == .calibrating && onSkipCalibration != nil
    }

    var body: some View {
        ZStack {
            // Pure `#000000` OLED canvas with zero camera preview layers (§1.2, §4.1 item 4).
            Color(red: 0, green: 0, blue: 0)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                statusHeaderCard

                audioRouteBadge

                if let title, !title.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.68))
                            .lineLimit(1)
                        if let statusText, !statusText.isEmpty {
                            Text(statusText)
                                .font(.footnote)
                                .foregroundStyle(Color.white.opacity(0.45))
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 4)
                } else if let statusText, !statusText.isEmpty {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.48))
                        .lineLimit(2)
                        .padding(.horizontal, 4)
                }

                Spacer(minLength: 8)

                emergencyButtonsStack
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    private var statusHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(externalDisplay.isConnected ? Color.green.opacity(0.75) : Color.orange.opacity(0.85))
                    .frame(width: 9, height: 9)
                Text(headerTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.65))
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text(phaseBadgeText)
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08), in: Capsule())

                if externalDisplay.isConnected {
                    Text(externalDisplay.externalResolution)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.42))
                } else {
                    Text("Reconnect AirPlay or switch to Front Camera")
                        .font(.caption2)
                        .foregroundStyle(Color.orange.opacity(0.82))
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.11), lineWidth: 1)
                )
        )
    }

    private var audioRouteBadge: some View {
        HStack(spacing: 10) {
            Image(systemName: externalDisplay.isConnected ? "airplayaudio" : "speaker.wave.2.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.52))

            VStack(alignment: .leading, spacing: 2) {
                Text("AUDIO ROUTE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.38))
                Text("\(externalDisplay.audioRouteSummary) · \(String(format: "%.0f ms", externalDisplay.outputLatencyMs))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.64))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                )
        )
    }

    private var emergencyButtonsStack: some View {
        VStack(spacing: 14) {
            if !externalDisplay.isConnected, let onReconnectAirPlay {
                oversizedTouchButton(
                    title: "Reconnect AirPlay TV",
                    subtitle: "Open route picker or resume TV display",
                    icon: "tv.badge.wifi",
                    tint: Color.cyan.opacity(0.85),
                    enabled: true,
                    action: onReconnectAirPlay
                )
            }

            // 1. Pause / Resume
            oversizedTouchButton(
                title: pauseResumeTitle,
                subtitle: isActiveTakeRunning ? "Immediately pause active take" : "Hands-free controls remain active on TV",
                icon: pauseResumeIcon,
                tint: isActiveTakeRunning ? Color.orange.opacity(0.85) : Color.white.opacity(0.78),
                enabled: phase != .analyzing,
                action: onPauseResume
            )

            // 2. Skip Calibration
            oversizedTouchButton(
                title: "Skip Calibration",
                subtitle: phase == .calibrating
                    ? "Jump straight into count-in without pose holds"
                    : "Available while studio calibration is running",
                icon: "forward.end.fill",
                tint: Color.yellow.opacity(0.82),
                enabled: canSkipCalibration,
                action: { onSkipCalibration?() }
            )

            // 3. Use Phone Screen (Front Camera)
            oversizedTouchButton(
                title: "Use Phone Screen (Front Camera)",
                subtitle: "Exit TV stage and switch to front self-view",
                icon: "iphone.gen3",
                tint: Color.cyan.opacity(0.80),
                enabled: true,
                action: onUsePhoneScreen
            )

            // Conditional Phase-3 Order #15 entrypoint: shown only when `clapSyncAction != nil`.
            if let clapSyncAction = externalDisplay.clapSyncAction {
                oversizedTouchButton(
                    title: "Sync TV Audio",
                    subtitle: "Run 3-clap TV / soundbar latency check",
                    icon: "hands.clap.fill",
                    tint: Color.green.opacity(0.80),
                    enabled: phase != .recording && phase != .countIn && phase != .analyzing,
                    action: clapSyncAction
                )
            }
        }
    }

    private func oversizedTouchButton(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(enabled ? tint : Color.white.opacity(0.22))
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(enabled ? Color.white.opacity(0.86) : Color.white.opacity(0.28))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(enabled ? Color.white.opacity(0.46) : Color.white.opacity(0.20))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(enabled ? 0.045 : 0.015))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                enabled ? tint.opacity(0.32) : Color.white.opacity(0.06),
                                lineWidth: 1.2
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
