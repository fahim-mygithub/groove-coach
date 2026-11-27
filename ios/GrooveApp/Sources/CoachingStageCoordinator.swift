import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import GrooveCore
import SwiftUI
import UIKit

// MARK: - App-Launch Hook on ExternalDisplayAppDelegate

extension ExternalDisplayAppDelegate {
    /// Automatically invoked by UIKit at launch via `@UIApplicationDelegateAdaptor(ExternalDisplayAppDelegate.self)`
    /// in `GrooveCoachApp` (`PoseExporterApp.swift:10`). Registers `CoachingStageCoordinator.shared` immediately so
    /// tapping "Recalibrate Studio" in the Calibrate tab before Practice or Lesson opens queues a Tier-2 recalibration
    /// instead of dropping the request (closing Order #8 review gap without modifying `PoseExporterApp.swift` or
    /// `ExternalDisplayManager.swift`).
    @objc func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        _ = CoachingStageCoordinator.start()
        return true
    }
}

// MARK: - CoachingStageCoordinator

/// Shared `@MainActor` stage, camera-mode, AirPlay lifecycle, gesture-routing, and `CalibrationProfileStore`
/// coordinator for `PracticeView` (Order #13) and `LessonPlayerView` (Order #14)
/// (spec: `docs/specs/2026-11-26-calibration-v2-plan.md` §§1.2, 4.1–4.3, 5.1–5.4, 6.2, 8.4, 9.2, 10 #12):
/// - Registers `ExternalDisplayManager.shared.onRecalibrateStudioRequested` at app launch via `CoachingStageCoordinator.shared`
///   and queues Recalibrate Studio requests until a `CalibrationController` attaches.
/// - Mounts `TVCoachingStageView` onto `ExternalDisplayManager.shared.stageBuilder` while attached and tracks which
///   coordinator owns the TV canvas so overlapping SwiftUI `onAppear` / `onDisappear` transitions never clobber the active stage.
/// - Detects AirPlay / external-display drops, cancels active calibration (unlocking AE/AWB) or pauses active takes,
///   speaks the §4.3 `CalibrationVoice` disconnect / reconnect announcements, and invokes `onAirPlayDropped`.
/// - Manages automatic `CameraMode` selection (`.rearLiDAR` with TV, `.frontSelfView` fallback) plus manual override
///   and phone emergency fallback (`usePhoneScreenFrontCamera()`).
/// - Binds `GestureRouter` onto `PracticeCamera` (`onGestureEventAtTime` + `onGesture`), enforcing
///   `resetPreservingHoldLatch()` on phase transitions, the `1.0 s` post-take `.results` grace cooldown,
///   200 ms `CalibrationVoice` earcons, `1.5 s` TV/phone `GestureToast` banners, and `DebugLink.shared.recordGestureFired`.
/// - Exposes `CalibrationProfileStore` helpers (`activeProfileV2`, `effectiveAudioLatencyMs(baseOutputLatencyMs:)`,
///   `tvVideoLeadOffsetSeconds`, and host-time video lead scheduling).
@MainActor
final class CoachingStageCoordinator: ObservableObject {
    /// App-lifetime singleton started at launch (`ExternalDisplayAppDelegate` / `CoachingStageCoordinator.start()`).
    static let shared = CoachingStageCoordinator(host: .lesson, isAppSingleton: true)

    nonisolated static let defaultPostTakeGraceDuration: Double = 1.0
    nonisolated static let defaultToastDuration: Double = 1.5

    private static var hasRegisteredAppLaunchHook = false
    private static weak var activeStageOwner: CoachingStageCoordinator?

    // MARK: Dependencies & Sub-Models

    let externalDisplay: ExternalDisplayManager
    let profileStore: CalibrationProfileStore
    let stageModel: TVCoachingStageModel
    private let fallbackVoice = CalibrationVoice()

    // MARK: Published State

    @Published var host: CoachingHost {
        didSet {
            if router.host != host {
                router.host = host
            }
            if stageModel.host != host {
                stageModel.host = host
            }
        }
    }

    @Published private(set) var phase: CoachingPhase = .idle
    @Published private(set) var isExternalDisplayConnected: Bool
    /// True after the user taps "Use Phone Screen (Front Camera)" on `PhoneControllerStatusView` to exit the TV stage.
    @Published private(set) var isPhoneScreenForced: Bool = false
    /// True after AirPlay drops mid-session while the phone displays reconnect vs "Use Front Camera" actions (§4.3).
    @Published private(set) var isAwaitingAirPlayReconnect: Bool = false
    /// Explicit user camera override (`nil` = automatic `.rearLiDAR` when TV connected, `.frontSelfView` otherwise).
    @Published private(set) var manualCameraModeOverride: CameraMode? = nil
    /// Resolved active capture mode reported by `PracticeCamera` (or the desired mode prior to session attach).
    @Published private(set) var cameraMode: CameraMode
    /// Latest persisted `CalibrationProfileV2` mirrored from `CalibrationProfileStore`.
    @Published private(set) var activeProfileV2: CalibrationProfileV2?
    /// Transient `1.5 s` gesture banner text mirrored into `stageModel.toastText` (§5.4).
    @Published private(set) var toastText: String? = nil
    /// True while a "Recalibrate Studio" tap is queued awaiting a `CalibrationController` attachment.
    @Published private(set) var pendingRecalibrateStudioRequest: Bool = false
    /// Coaching phase that was active when the most recent AirPlay disconnect occurred.
    @Published private(set) var lastAirPlayDropPhase: CoachingPhase? = nil

    // MARK: Callbacks

    /// Primary gesture command handler invoked on the main actor after `GestureRouter` + grace-window filtering.
    var onCommand: ((CoachingCommand) -> Void)?
    /// Optional detailed gesture callback carrying event, mode, phase, and routed command.
    var onRoutedGesture: ((RoutedGesture) -> Void)?
    /// Invoked when AirPlay / external display drops during an active TV coaching session (§4.3).
    /// Host ViewModels must transition to `.paused` without calling `recordTake(passed: false, ...)`.
    var onAirPlayDropped: (() -> Void)?
    /// Optional phase-aware AirPlay-drop callback invoked alongside `onAirPlayDropped`.
    var onAirPlayDroppedInPhase: ((CoachingPhase) -> Void)?
    /// Invoked when AirPlay reconnects after dropping during an active session (§4.3 item 3).
    var onAirPlayReconnected: (() -> Void)?
    /// Invoked when the user requests "Recalibrate Studio" while this coordinator is attached.
    var onRecalibrateStudioRequested: (() -> Void)?

    // MARK: Internal State

    private(set) var router: GestureRouter
    private(set) var isAttached: Bool = false
    /// Latest take pass verdict used by `GestureRouter` in `.results` (single clap -> Next when passed & unlocked).
    var latestTakePassed: Bool = false

    private weak var camera: PracticeCamera?
    private weak var calibration: CalibrationController?
    private var cancellables: Set<AnyCancellable> = []
    private var cameraModeCancellable: AnyCancellable?
    private var toastTask: Task<Void, Never>?
    private var suppressNextLegacyGestureCallback = false
    private var wasDroppedFromActiveTVSession = false
    private let isAppSingleton: Bool

    // MARK: - Initialization & App-Start Registration

    convenience init(
        host: CoachingHost = .lesson,
        postTakeGraceDuration: Double = CoachingStageCoordinator.defaultPostTakeGraceDuration,
        externalDisplay: ExternalDisplayManager? = nil,
        profileStore: CalibrationProfileStore? = nil
    ) {
        self.init(
            host: host,
            postTakeGraceDuration: postTakeGraceDuration,
            externalDisplay: externalDisplay,
            profileStore: profileStore,
            isAppSingleton: false
        )
    }

    private init(
        host: CoachingHost,
        postTakeGraceDuration: Double = CoachingStageCoordinator.defaultPostTakeGraceDuration,
        externalDisplay: ExternalDisplayManager? = nil,
        profileStore: CalibrationProfileStore? = nil,
        isAppSingleton: Bool
    ) {
        let resolvedDisplay = externalDisplay ?? .shared
        let resolvedStore = profileStore ?? .shared
        self.host = host
        self.externalDisplay = resolvedDisplay
        self.profileStore = resolvedStore
        self.isAppSingleton = isAppSingleton
        self.router = GestureRouter(
            host: host,
            phase: .idle,
            postTakeGraceDuration: postTakeGraceDuration
        )
        let connected = resolvedDisplay.isConnected
        self.isExternalDisplayConnected = connected
        self.cameraMode = connected ? .rearLiDAR : .frontSelfView
        self.activeProfileV2 = resolvedStore.activeProfileV2
        self.stageModel = TVCoachingStageModel(host: host, phase: .idle)

        if !isAppSingleton {
            _ = Self.start()
        }
        installSubscriptions()
    }

    /// Idempotent app-start hook: creates `CoachingStageCoordinator.shared` and registers
    /// `ExternalDisplayManager.shared.onRecalibrateStudioRequested` so "Recalibrate Studio" taps in the Calibrate tab
    /// before Practice or Lesson opens are queued rather than lost.
    /// Called automatically by `ExternalDisplayAppDelegate.application(_:didFinishLaunchingWithOptions:)`, and safe
    /// for Orders #13 / #14 to call as well.
    @discardableResult
    static func start() -> CoachingStageCoordinator {
        let instance = shared
        if !hasRegisteredAppLaunchHook {
            hasRegisteredAppLaunchHook = true
            instance.installAppRecalibrateStudioHandler()
            DebugLog.info("coaching_stage_coordinator app-launch hook registered")
        } else if instance.externalDisplay.onRecalibrateStudioRequested == nil {
            instance.installAppRecalibrateStudioHandler()
        }
        return instance
    }

    nonisolated private static func runOnMainActor(_ block: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                block()
            }
        } else {
            Task { @MainActor in
                block()
            }
        }
    }

    private func installAppRecalibrateStudioHandler() {
        externalDisplay.onRecalibrateStudioRequested = { [weak self] in
            Self.runOnMainActor { [weak self] in
                self?.enqueueOrDispatchRecalibrateStudioRequest()
            }
        }
    }

    private func enqueueOrDispatchRecalibrateStudioRequest() {
        profileStore.requestFullRecalibration()

        if let activeOwner = Self.activeStageOwner, let controller = activeOwner.calibration {
            controller.profileStore.requestFullRecalibration()
            pendingRecalibrateStudioRequest = false
            activeOwner.pendingRecalibrateStudioRequest = false
            if controller.isRunning {
                // Cancel any partial Tier-0/Tier-1 run so the next `begin` runs full 9-pose Tier-2 calibration.
                controller.cancel()
            }
            activeOwner.onRecalibrateStudioRequested?()
            DebugLog.info("coaching_stage_coordinator dispatched Recalibrate Studio to active controller")
        } else {
            pendingRecalibrateStudioRequest = true
            DebugLog.info("coaching_stage_coordinator queued Recalibrate Studio until CalibrationController attaches")
        }
    }

    /// Drains any queued "Recalibrate Studio" request onto `controller` when Practice or Lesson attaches.
    @discardableResult
    func consumePendingRecalibrateStudioRequest(applyingTo controller: CalibrationController? = nil) -> Bool {
        let targetController = controller ?? calibration
        let wasQueuedOnSingleton = Self.shared.pendingRecalibrateStudioRequest
        let wasQueuedLocally = pendingRecalibrateStudioRequest
        guard wasQueuedOnSingleton || wasQueuedLocally || profileStore.forceFullRecalibrationNext else {
            return false
        }
        if let targetController {
            targetController.profileStore.requestFullRecalibration()
            Self.shared.pendingRecalibrateStudioRequest = false
            pendingRecalibrateStudioRequest = false
            DebugLog.info("coaching_stage_coordinator applied queued Recalibrate Studio request to controller")
            return true
        }
        return false
    }

    // MARK: - Subscriptions & External Display Observation

    private func installSubscriptions() {
        externalDisplay.$isConnected
            .removeDuplicates()
            .sink { [weak self] connected in
                Self.runOnMainActor { [weak self] in
                    self?.handleExternalDisplayConnectionChanged(isConnected: connected)
                }
            }
            .store(in: &cancellables)

        profileStore.$activeProfileV2
            .sink { [weak self] updatedProfile in
                Self.runOnMainActor { [weak self] in
                    self?.activeProfileV2 = updatedProfile
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Stage Attachment & Lifecycle

    /// Attaches a host screen's `PracticeCamera`, `CalibrationController`, and optional `AVPlayer` to this coordinator,
    /// mounting `TVCoachingStageView` onto `ExternalDisplayManager.shared.stageBuilder`, applying any queued
    /// Recalibrate Studio request, configuring composite `AVPlayer` playback, and binding `GestureRouter` + `CameraMode`.
    func attach(
        camera: PracticeCamera,
        calibration: CalibrationController,
        player: AVPlayer? = nil,
        host: CoachingHost? = nil
    ) {
        _ = Self.start()

        if let host {
            self.host = host
        }

        self.camera = camera
        self.calibration = calibration
        self.isAttached = true
        self.isExternalDisplayConnected = externalDisplay.isConnected

        if let player {
            setPlayer(player)
        }

        _ = consumePendingRecalibrateStudioRequest(applyingTo: calibration)

        bindCameraCallbacks(camera)
        camera.setCoachingPhase(phase)
        applyCameraModePolicy()

        Self.activeStageOwner = self
        if !isPhoneScreenForced {
            mountTVStage(camera: camera, calibration: calibration)
        }
    }

    /// Detaches the host screen on `onDisappear`, unbinding camera gesture callbacks and restoring the default stage
    /// builder only if no newer coaching screen has already taken ownership of `ExternalDisplayManager.shared`.
    func detach() {
        toastTask?.cancel()
        toastTask = nil
        toastText = nil
        stageModel.toastText = nil

        if let cam = camera {
            cam.onGestureEventAtTime = nil
            cam.onGestureEvent = nil
            cam.onGesture = nil
        }
        cameraModeCancellable?.cancel()
        cameraModeCancellable = nil

        camera = nil
        calibration = nil
        isAttached = false
        isAwaitingAirPlayReconnect = false
        wasDroppedFromActiveTVSession = false
        suppressNextLegacyGestureCallback = false

        if Self.activeStageOwner === self {
            Self.activeStageOwner = nil
            externalDisplay.resetStageBuilder()
        }
    }

    private func mountTVStage(camera: PracticeCamera, calibration: CalibrationController) {
        let model = stageModel
        externalDisplay.setStage { [weak camera, weak calibration] in
            if let camera, let calibration {
                TVCoachingStageView(
                    model: model,
                    camera: camera,
                    calibration: calibration
                )
            } else {
                AirPlaySyncSpikeStageView()
            }
        }
    }

    // MARK: - TV Stage & Phone Controller Mode Computed Properties

    /// True when an external AirPlay / wired TV display is connected and the user has not forced phone self-view.
    var isTVStageActive: Bool {
        isExternalDisplayConnected && !isPhoneScreenForced
    }

    /// True when the iPhone should display pure-black `PhoneControllerStatusView` instead of its camera UI
    /// (either while TV stage is active, or while paused awaiting AirPlay reconnect vs Front Camera selection; §4.1, §4.3).
    var shouldShowPhoneControllerStatus: Bool {
        (isExternalDisplayConnected || isAwaitingAirPlayReconnect) && !isPhoneScreenForced
    }

    /// Desired `CameraMode` under current TV connection and user override state.
    var desiredCameraMode: CameraMode {
        if isPhoneScreenForced {
            return .frontSelfView
        }
        if let manualCameraModeOverride {
            return manualCameraModeOverride
        }
        return isExternalDisplayConnected ? .rearLiDAR : .frontSelfView
    }

    private var activeVoice: CalibrationVoice {
        calibration?.voice ?? fallbackVoice
    }

    private var screenLabel: String {
        switch host {
        case .practice:
            return "practice"
        case .lesson:
            return "lesson"
        }
    }

    // MARK: - AirPlay Drop & Reconnect Handling (§4.3)

    private func handleExternalDisplayConnectionChanged(isConnected nowConnected: Bool) {
        let wasConnected = isExternalDisplayConnected
        guard nowConnected != wasConnected else { return }
        isExternalDisplayConnected = nowConnected

        // Do not emit coaching announcements on the dormant app-launch singleton when no coaching screen is open.
        guard isAttached else {
            if !isPhoneScreenForced, manualCameraModeOverride == nil {
                cameraMode = nowConnected ? .rearLiDAR : .frontSelfView
            }
            return
        }

        if !nowConnected {
            handleAirPlayDisconnected()
        } else {
            handleAirPlayReconnected()
        }
    }

    private func handleAirPlayDisconnected() {
        guard !isPhoneScreenForced else { return }

        let droppedPhase = phase
        lastAirPlayDropPhase = droppedPhase
        wasDroppedFromActiveTVSession = true
        isAwaitingAirPlayReconnect = true

        switch droppedPhase {
        case .countIn, .recording:
            // §4.3 item 1: immediately abort active take into `.paused` without demoting adaptive speed ladder.
            setPhase(.paused)
            stageModel.statusMessage = CalibrationVoice.airPlayDisconnectedMidTakeText
            activeVoice.speakAirPlayDisconnectedMidTake()

        case .calibrating, .clapSync:
            // §4.3 item 2: cancel active hold, unlock AE/AWB, preserve persisted `CalibrationProfileV2`, speak pause notice.
            calibration?.cancel()
            calibration?.unlockExposure()
            setPhase(.paused)
            stageModel.statusMessage = CalibrationVoice.airPlayDisconnectedMidCalibrationText
            activeVoice.speakAirPlayDisconnectedMidCalibration()

        case .idle, .results, .paused, .analyzing:
            stageModel.statusMessage = CalibrationVoice.airPlayDisconnectedMidTakeText
            activeVoice.speakAirPlayDisconnectedMidTake()
        }

        DebugLog.info("coaching_stage_coordinator airplay_dropped phase=\(droppedPhase.rawValue) host=\(host.rawValue)")
        onAirPlayDroppedInPhase?(droppedPhase)
        onAirPlayDropped?()
    }

    private func handleAirPlayReconnected() {
        let returningFromDrop = wasDroppedFromActiveTVSession || isPhoneScreenForced
        isPhoneScreenForced = false
        isAwaitingAirPlayReconnect = false
        wasDroppedFromActiveTVSession = false

        if manualCameraModeOverride == .frontSelfView && returningFromDrop {
            manualCameraModeOverride = nil
        }

        if let camera, let calibration {
            Self.activeStageOwner = self
            mountTVStage(camera: camera, calibration: calibration)
        }
        applyCameraModePolicy()

        if returningFromDrop {
            stageModel.statusMessage = CalibrationVoice.airPlayReconnectedText
            activeVoice.speakAirPlayReconnected()
            DebugLog.info("coaching_stage_coordinator airplay_reconnected host=\(host.rawValue)")
            onAirPlayReconnected?()
        }
    }

    // MARK: - Automatic & Manual CameraMode Switching (§1.2, §4.1, §4.3)

    /// Sets an explicit manual `CameraMode` override, or passes `nil` to restore automatic TV/phone selection
    /// (`.rearLiDAR` when an external display is connected, `.frontSelfView` otherwise).
    func setManualCameraMode(_ mode: CameraMode?) {
        manualCameraModeOverride = mode
        if mode != nil {
            isPhoneScreenForced = false
            if mode == .frontSelfView && !isExternalDisplayConnected {
                isAwaitingAirPlayReconnect = false
            }
        }
        applyCameraModePolicy()
    }

    /// Toggles manually between front self-view and rear LiDAR studio camera.
    func toggleCameraMode() {
        let current = camera?.activeCameraMode ?? cameraMode
        let nextMode: CameraMode = current.isRear ? .frontSelfView : .rearLiDAR
        setManualCameraMode(nextMode)
    }

    /// Action for `PhoneControllerStatusView`'s "Use Phone Screen (Front Camera)" button (§4.1 item 4, §4.3):
    /// exits the TV controller screen on the phone, cancels/pauses any active calibration or take safely,
    /// and switches `PracticeCamera` to `.frontSelfView`.
    func usePhoneScreenFrontCamera() {
        if phase == .calibrating || phase == .clapSync {
            calibration?.cancel()
            calibration?.unlockExposure()
            setPhase(.paused)
        } else if phase == .countIn || phase == .recording {
            setPhase(.paused)
            onCommand?(.pauseTake)
        }

        isPhoneScreenForced = true
        isAwaitingAirPlayReconnect = false
        wasDroppedFromActiveTVSession = false
        manualCameraModeOverride = .frontSelfView

        if Self.activeStageOwner === self {
            externalDisplay.resetStageBuilder()
        }
        applyCameraModePolicy()
        DebugLog.info("coaching_stage_coordinator switched to phone frontSelfView fallback")
    }

    /// Re-enters the TV coaching stage after `usePhoneScreenFrontCamera()` when an external display is connected.
    func resumeTVStage() {
        isPhoneScreenForced = false
        isAwaitingAirPlayReconnect = false
        if manualCameraModeOverride == .frontSelfView {
            manualCameraModeOverride = nil
        }
        if let camera, let calibration {
            Self.activeStageOwner = self
            mountTVStage(camera: camera, calibration: calibration)
        }
        applyCameraModePolicy()
    }

    private func applyCameraModePolicy() {
        let preferredForCamera: CameraMode?
        if isPhoneScreenForced {
            preferredForCamera = .frontSelfView
        } else {
            preferredForCamera = manualCameraModeOverride
        }

        guard let camera else {
            cameraMode = desiredCameraMode
            return
        }

        // Avoid tearing down `AVCaptureSession` mid-take unless the user explicitly forced a mode switch.
        let isMidTake = (phase == .countIn || phase == .recording || phase == .analyzing)
        if isMidTake && preferredForCamera == nil {
            return
        }

        camera.setCameraMode(preferredForCamera)
        cameraMode = camera.activeCameraMode
    }

    // MARK: - Phase Synchronization & GestureRouter Binding (§5.1–5.4, §9.2)

    /// Transitions the coordinator, `GestureRouter`, `TVCoachingStageModel`, and `PracticeCamera` (`GestureMode` +
    /// `resetPreservingHoldLatch()` + LiDAR depth rate) to `newPhase`, arming the `1.0 s` post-take grace window
    /// when entering `.results`.
    func setPhase(
        _ newPhase: CoachingPhase,
        at hostTime: Double? = nil,
        passed: Bool? = nil,
        nextUnlocked: Bool? = nil
    ) {
        if let passed {
            latestTakePassed = passed
        }
        if let nextUnlocked, stageModel.nextUnlocked != nextUnlocked {
            stageModel.nextUnlocked = nextUnlocked
        }

        let resolvedTime = hostTime ?? Self.currentHostTimeSeconds()
        let changed = (newPhase != phase)
        router.transition(to: newPhase, at: resolvedTime)

        if phase != newPhase {
            phase = newPhase
        }
        if stageModel.phase != newPhase {
            stageModel.phase = newPhase
        }

        if let camera {
            camera.setCoachingPhase(newPhase)
            if !changed {
                camera.resetGestureHoldLatch()
            }
        }
    }

    /// Explicitly resets transient swipe/clap tracks while preserving the lower-hands `0.25 s` hold latch (§5.2).
    func resetGestureHoldLatch() {
        camera?.resetGestureHoldLatch()
    }

    private func bindCameraCallbacks(_ camera: PracticeCamera) {
        cameraModeCancellable?.cancel()
        cameraModeCancellable = camera.$cameraMode
            .sink { [weak self] updatedMode in
                Self.runOnMainActor { [weak self] in
                    self?.cameraMode = updatedMode
                }
            }

        suppressNextLegacyGestureCallback = false

        // Primary v2 callback: receives all 5 `GestureEvent` cases (including `.doubleClap` in `.calibrating`)
        // together with the exact host-clock frame timestamp for the `1.0 s` `.results` grace window.
        camera.onGestureEvent = nil
        camera.onGestureEventAtTime = { [weak self] event, sampleHostTime in
            Self.runOnMainActor { [weak self] in
                guard let self else { return }
                self.suppressNextLegacyGestureCallback = (event.legacyCommand != nil)
                self.handleRecognizedGestureEvent(event, at: sampleHostTime)
            }
        }

        // Also bind `camera.onGesture` so any direct/legacy caller invoking `camera.onGesture?(command)` routes
        // through the exact same `GestureRouter`, grace window, earcon, and `DebugLink` pipeline without double-firing
        // after `onGestureEventAtTime` on live camera frames (`PracticeCamera.swift:950-957`).
        camera.onGesture = { [weak self] legacyCommand in
            Self.runOnMainActor { [weak self] in
                guard let self else { return }
                if self.suppressNextLegacyGestureCallback {
                    self.suppressNextLegacyGestureCallback = false
                    return
                }
                self.handleRecognizedGestureEvent(
                    GestureEvent(legacyCommand),
                    at: Self.currentHostTimeSeconds()
                )
            }
        }
    }

    private func handleRecognizedGestureEvent(_ event: GestureEvent, at hostTime: Double?) {
        let resolvedTime = hostTime ?? Self.currentHostTimeSeconds()
        let effectivePhase: CoachingPhase = (calibration?.isRunning == true) ? .calibrating : phase
        if router.phase != effectivePhase {
            router.transition(to: effectivePhase, at: resolvedTime)
        }

        let passed = latestTakePassed || (stageModel.scoreResult?.passed ?? false)
        let nextUnlocked = stageModel.nextUnlocked

        guard let command = router.route(
            event,
            at: resolvedTime,
            passed: passed,
            nextUnlocked: nextUnlocked
        ) else {
            return
        }

        let routed = RoutedGesture(
            event: event,
            mode: router.gestureMode,
            phase: effectivePhase,
            command: command
        )

        activeVoice.playEarcon(for: command)
        showToast(Self.defaultToastTitle(for: command))

        DebugLink.shared.recordGestureFired(
            command: event.rawValue,
            mode: routed.mode.rawValue,
            phase: routed.phase.rawValue,
            action: command.rawValue,
            extra: [
                "host": host.rawValue,
                "screen": screenLabel
            ]
        )

        // Built-in calibration command execution (safe & idempotent even if `onCommand` also handles them,
        // because `CalibrationController` defers `.calibrating` gestures when `onGestureEventAtTime != nil`).
        switch command {
        case .repeatCalibrationCue:
            calibration?.repeatCurrentCue()
        case .skipCalibration:
            calibration?.skip()
        case .startTake, .pauseTake, .togglePreviewPlayPause, .restartPreview, .nextItem, .returnToReview:
            break
        }

        onRoutedGesture?(routed)
        onCommand?(command)
    }

    static func defaultToastTitle(for command: CoachingCommand) -> String {
        switch command {
        case .startTake:
            return "Start Take"
        case .pauseTake:
            return "Take Paused"
        case .togglePreviewPlayPause:
            return "Play / Pause"
        case .restartPreview:
            return "Restart Preview"
        case .nextItem:
            return "Next"
        case .returnToReview:
            return "Back to Review"
        case .repeatCalibrationCue:
            return "Repeat Cue"
        case .skipCalibration:
            return "Skip Calibration"
        }
    }

    // MARK: - TV Stage Model & Toast Updates

    /// Configures `AVPlayer` to stay inside the composite 16:9 TV stage (`allowsExternalPlayback = false`; §4.1, §11.1)
    /// and binds it to `stageModel`.
    func setPlayer(_ player: AVPlayer?, hasTeacherVideo: Bool? = nil) {
        if let player {
            ExternalDisplayManager.configurePlayerForCompositeStage(player)
        }
        if stageModel.player !== player {
            stageModel.player = player
        }
        if let hasTeacherVideo, stageModel.hasTeacherVideo != hasTeacherVideo {
            stageModel.hasTeacherVideo = hasTeacherVideo
        }
    }

    /// Batch-updates non-nil `TVCoachingStageModel` fields only when changed, avoiding redundant 15–60 Hz SwiftUI invalidations.
    /// Use `setLiveState(_:)`, `setScoreResult(_:resultPose:gradingRefusalReason:)`, `setStatusMessage(_:)`, or
    /// `clearTakeResults()` when explicitly clearing optional stage state to `nil`.
    func updateStage(
        title: String? = nil,
        subtitle: String? = nil,
        playbackRate: Double? = nil,
        isTeacherMirrored: Bool? = nil,
        hasTeacherVideo: Bool? = nil,
        countInBeatsLeft: Int? = nil,
        currentBeatCount: Int? = nil,
        currentPhrase: Int? = nil,
        liveState: LiveMatcher.LiveState? = nil,
        scoreResult: GrooveScoringEngine.AttemptScoreResult? = nil,
        resultPose: [String: CGPoint]? = nil,
        gradingRefusalReason: String? = nil,
        referencePose: [String: CGPoint]? = nil,
        nextUnlocked: Bool? = nil,
        statusMessage: String? = nil
    ) {
        if let title, stageModel.title != title { stageModel.title = title }
        if let subtitle, stageModel.subtitle != subtitle { stageModel.subtitle = subtitle }
        if let playbackRate, stageModel.playbackRate != playbackRate { stageModel.playbackRate = playbackRate }
        if let isTeacherMirrored, stageModel.isTeacherMirrored != isTeacherMirrored {
            stageModel.isTeacherMirrored = isTeacherMirrored
        }
        if let hasTeacherVideo, stageModel.hasTeacherVideo != hasTeacherVideo {
            stageModel.hasTeacherVideo = hasTeacherVideo
        }
        if let countInBeatsLeft, stageModel.countInBeatsLeft != countInBeatsLeft {
            stageModel.countInBeatsLeft = countInBeatsLeft
        }
        if let currentBeatCount, stageModel.currentBeatCount != currentBeatCount {
            stageModel.currentBeatCount = currentBeatCount
        }
        if let currentPhrase, stageModel.currentPhrase != currentPhrase {
            stageModel.currentPhrase = currentPhrase
        }
        if let liveState, stageModel.liveState != liveState {
            stageModel.liveState = liveState
        }
        if let scoreResult {
            stageModel.scoreResult = scoreResult
            latestTakePassed = scoreResult.passed
        }
        if let resultPose, stageModel.resultPose != resultPose {
            stageModel.resultPose = resultPose
        }
        if let gradingRefusalReason, stageModel.gradingRefusalReason != gradingRefusalReason {
            stageModel.gradingRefusalReason = gradingRefusalReason
        }
        if let referencePose, stageModel.referencePose != referencePose {
            stageModel.referencePose = referencePose
        }
        if let nextUnlocked, stageModel.nextUnlocked != nextUnlocked {
            stageModel.nextUnlocked = nextUnlocked
        }
        if let statusMessage, stageModel.statusMessage != statusMessage {
            stageModel.statusMessage = statusMessage
        }
    }

    /// Updates or clears live limb matching state on the TV stage.
    func setLiveState(_ state: LiveMatcher.LiveState?) {
        if stageModel.liveState != state {
            stageModel.liveState = state
        }
    }

    /// Updates or clears the take scorecard, learner stick-figure pose, and optional grading refusal reason on the TV stage.
    func setScoreResult(
        _ result: GrooveScoringEngine.AttemptScoreResult?,
        resultPose: [String: CGPoint] = [:],
        gradingRefusalReason: String? = nil
    ) {
        stageModel.scoreResult = result
        latestTakePassed = result?.passed ?? false
        if stageModel.resultPose != resultPose {
            stageModel.resultPose = resultPose
        }
        if stageModel.gradingRefusalReason != gradingRefusalReason {
            stageModel.gradingRefusalReason = gradingRefusalReason
        }
    }

    /// Updates or clears the status message shown on the TV stage and `PhoneControllerStatusView`.
    func setStatusMessage(_ message: String?) {
        if stageModel.statusMessage != message {
            stageModel.statusMessage = message
        }
    }

    /// Clears per-take live matching and scorecard fields when starting a new take.
    func clearTakeResults() {
        if stageModel.liveState != nil { stageModel.liveState = nil }
        if stageModel.scoreResult != nil { stageModel.scoreResult = nil }
        if !stageModel.resultPose.isEmpty { stageModel.resultPose = [:] }
        if stageModel.gradingRefusalReason != nil { stageModel.gradingRefusalReason = nil }
        latestTakePassed = false
    }

    /// Displays a transient capsule toast on both `toastText` and the 16:9 `TVCoachingStageView` for `duration` seconds (§5.4).
    func showToast(_ text: String, duration: Double = CoachingStageCoordinator.defaultToastDuration) {
        toastTask?.cancel()
        toastText = text
        stageModel.toastText = text
        let nanos = UInt64(max(0.1, duration) * 1_000_000_000)
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard let self, !Task.isCancelled else { return }
            self.toastText = nil
            self.stageModel.toastText = nil
        }
    }

    func clearToast() {
        toastTask?.cancel()
        toastTask = nil
        toastText = nil
        stageModel.toastText = nil
    }

    /// Convenience factory wiring `PhoneControllerStatusView` to this coordinator's phase, camera mode, and fallback actions.
    func makePhoneControllerStatusView(
        title: String? = nil,
        statusText: String? = nil,
        onPauseResume: @escaping () -> Void,
        onSkipCalibration: (() -> Void)? = nil
    ) -> PhoneControllerStatusView {
        PhoneControllerStatusView(
            phase: phase,
            cameraMode: cameraMode,
            title: title ?? stageModel.title,
            statusText: statusText ?? stageModel.statusMessage,
            onPauseResume: onPauseResume,
            onSkipCalibration: onSkipCalibration ?? { [weak self] in
                self?.calibration?.skip()
            },
            onUsePhoneScreen: { [weak self] in
                self?.usePhoneScreenFrontCamera()
            },
            onReconnectAirPlay: { [weak self] in
                guard let self else { return }
                self.externalDisplay.reconcileConnectedScenes()
                self.externalDisplay.refreshAudioRouteMetrics()
                if self.externalDisplay.isConnected {
                    self.resumeTVStage()
                }
            }
        )
    }

    // MARK: - CalibrationProfileStore & Host-Clock Sync Helpers (§4.2, §8, §8.4)

    /// Deterministic `LearnerCalibrationV2` scoring payload (`nil` when `skipped == true` or uncalibrated; §8).
    func scoringCalibration(
        skipped: Bool = false,
        outcomeProfileV2: CalibrationProfileV2? = nil
    ) -> LearnerCalibrationV2? {
        guard !skipped else { return nil }
        return (outcomeProfileV2 ?? profileStore.activeProfileV2)?.asScoringCalibration
    }

    /// Effective audio output latency (`ms`) for `PoseClip.audio_latency_ms` (§8.4):
    /// `baseOutputLatencyMs + (airplayRouteOffsetsMs[routeUID] ?? 0.0)`.
    func effectiveAudioLatencyMs(baseOutputLatencyMs: Double, routeUID: String? = nil) -> Double {
        profileStore.effectiveAudioLatencyMs(baseOutputLatencyMs: baseOutputLatencyMs, routeUID: routeUID)
    }

    /// Stored TV video lead offset in milliseconds on `CalibrationProfileStore` (regardless of current connection state).
    var storedTVVideoLeadOffsetMs: Double {
        profileStore.tvVideoLeadOffsetMs
    }

    /// Stored TV video lead offset in seconds on `CalibrationProfileStore` (regardless of current connection state).
    var storedTVVideoLeadOffsetSeconds: Double {
        profileStore.tvVideoLeadOffsetSeconds
    }

    /// Active host-time TV video lead offset in milliseconds (`0.0` when rendering on the phone screen rather than TV).
    var tvVideoLeadOffsetMs: Double {
        isTVStageActive ? profileStore.tvVideoLeadOffsetMs : 0.0
    }

    /// Active host-time TV video lead offset in seconds (`> 0` advances `AVPlayer` start relative to audio; §4.2, Order #14).
    /// Returns `0.0` when no external TV stage is active so local phone playback is never shifted by a TV offset.
    var tvVideoLeadOffsetSeconds: Double {
        isTVStageActive ? profileStore.tvVideoLeadOffsetSeconds : 0.0
    }

    /// Computes overflow/underflow-safe `mach_absolute_time` ticks for `AVPlayer.setRate(_:time:atHostTime:)` (§4.2):
    /// shifts `audioStartMachTime + countInDuration` by `-tvVideoLeadOffsetSeconds` when TV stage is active.
    func scheduledVideoMachTime(audioStartMachTime: UInt64, countInDuration: Double) -> UInt64 {
        let netDelaySeconds = countInDuration - tvVideoLeadOffsetSeconds
        if netDelaySeconds >= 0 {
            return audioStartMachTime &+ AVAudioTime.hostTime(forSeconds: netDelaySeconds)
        } else {
            let advanceTicks = AVAudioTime.hostTime(forSeconds: -netDelaySeconds)
            return audioStartMachTime > advanceTicks ? (audioStartMachTime - advanceTicks) : 0
        }
    }

    /// Monotonic host-clock seconds (`CMClockGetHostTimeClock()`), matching `PracticeCamera` and `Metronome`.
    nonisolated static func currentHostTimeSeconds() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }
}
