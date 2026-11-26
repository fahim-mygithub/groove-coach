import AVFoundation
import CoreGraphics
import CoreMedia
import CoreMotion
import CoreVideo
import Foundation
import GrooveCore
import ImageIO
import simd

/// Sensor inputs and metric LiDAR / camera calibration helpers for `CalibrationGate`
/// (spec: `docs/specs/2026-11-26-calibration-v2-plan.md` §§1.2, 3.1–3.5, 10 #6):
/// - `CMDeviceMotion` at 30 Hz (`gravity`, `userAcceleration`, `rotationRate`), delivered on the main queue,
///   plus camera-mode-aware conversion of device gravity into `CanonicalSkeleton` camera axes;
/// - `AVDepthData` + `AVCameraCalibrationData` extraction, radial lens-distortion undistortion,
///   canonical right-handed 3D back-projection, and 40-iteration gravity-guided floor RANSAC;
/// - `CMSampleBuffer` per-frame video intrinsics (`kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`)
///   and portrait vertical/horizontal FoV helpers;
/// - 2 Hz 32BGRA luma sampling plus AE/AWB lock (`1/60 s` motion-blur shutter cap + custom ISO boost),
///   unlock, and `1.0 s` between-take luma-drift re-meter guard.
final class CalibrationSensors: @unchecked Sendable {
    static let motionHz = 30.0
    static let defaultVerticalFoVDeg = 60.0
    static let remeterSettleDurationS = 1.0

    // Floor plane RANSAC constants (spec §3.4)
    static let floorRansacIterations = 40
    static let floorRansacInlierThresholdM = 0.02
    static let floorRansacMaxTiltDeltaDeg = 15.0
    static let floorRansacMinInliers = 80
    static let floorDepthMinM = 1.0
    static let floorDepthMaxM = 4.8
    static let floorLowerFrameMinY = 0.65

    /// Snapshot of AE/AWB lock and between-take re-meter state (spec §3.3).
    struct ExposureLockState: Equatable, Sendable {
        var exposureLocked: Bool
        var isRemetering: Bool
        var lockedMeanLuma: Double?
        var lockedISO: Double?
        var lockedExposureDurationS: Double?
        var wasAdjustingExposureAtLock: Bool
        var wasAdjustingWhiteBalanceAtLock: Bool

        init(
            exposureLocked: Bool = false,
            isRemetering: Bool = false,
            lockedMeanLuma: Double? = nil,
            lockedISO: Double? = nil,
            lockedExposureDurationS: Double? = nil,
            wasAdjustingExposureAtLock: Bool = false,
            wasAdjustingWhiteBalanceAtLock: Bool = false
        ) {
            self.exposureLocked = exposureLocked
            self.isRemetering = isRemetering
            self.lockedMeanLuma = lockedMeanLuma
            self.lockedISO = lockedISO
            self.lockedExposureDurationS = lockedExposureDurationS
            self.wasAdjustingExposureAtLock = wasAdjustingExposureAtLock
            self.wasAdjustingWhiteBalanceAtLock = wasAdjustingWhiteBalanceAtLock
        }
    }

    private let motion = CMMotionManager()
    private let lock = NSLock()
    private var _exposureState = ExposureLockState()
    private var remeterStartTime: Double?

    /// Called on the main queue for every device-motion update while running.
    var onMotion: ((CalibrationMotionSample) -> Void)?

    var isRunning: Bool { motion.isDeviceMotionActive }

    // MARK: - Motion & Camera-Frame Gravity (§1.2, §3.4)

    func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / Self.motionHz
        motion.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
            guard let self, let dm else { return }
            self.onMotion?(Self.sample(dm))
        }
    }

    func stopMotion() {
        motion.stopDeviceMotionUpdates()
    }

    /// Latest gravity (g, CoreMotion device frame), or upright portrait when motion is unavailable.
    func currentGravity() -> [Double] {
        guard let g = motion.deviceMotion?.gravity else { return [0.0, -1.0, 0.0] }
        return [g.x, g.y, g.z]
    }

    /// Latest gravity converted into `CanonicalSkeleton` camera axes for `PoseClip.gravity_vector` (§1.2):
    /// `[+gx, +gy, +gz]` on `.rearLiDAR` / `.rearWide`, `[-gx, +gy, -gz]` on `.frontSelfView`.
    func currentCameraGravity(for cameraMode: CameraMode) -> [Double] {
        Self.cameraFrameGravity(fromDeviceGravity: currentGravity(), cameraMode: cameraMode)
    }

    /// Converts CoreMotion device-frame gravity `[gx, gy, gz]` into `CanonicalSkeleton` camera axes
    /// (`+x` un-mirrored image-right, `+y` image-up, `+z` dancer-toward-lens; spec §1.2).
    static func cameraFrameGravity(fromDeviceGravity gravity: [Double], cameraMode: CameraMode) -> [Double] {
        cameraMode.cameraFrameGravity(fromDeviceGravity: gravity)
    }

    /// Converts a CoreMotion device-frame gravity `CalibrationVector3` into `CanonicalSkeleton` camera axes (§1.2).
    static func cameraFrameGravity(
        fromDeviceGravity gravity: CalibrationVector3,
        cameraMode: CameraMode
    ) -> CalibrationVector3 {
        CalibrationVector3(cameraMode.cameraFrameGravity(fromDeviceGravity: gravity.array))
    }

    /// Expected upward unit floor normal `n_g = -normalize(g_cam)` in `CanonicalSkeleton` camera space (§3.4).
    static func upwardFloorNormal(
        fromDeviceGravity gravity: CalibrationVector3,
        cameraMode: CameraMode
    ) -> CalibrationVector3? {
        let gCam = cameraFrameGravity(fromDeviceGravity: gravity, cameraMode: cameraMode)
        let norm = gCam.norm
        guard norm > 1e-6 else { return nil }
        return CalibrationVector3(x: -gCam.x / norm, y: -gCam.y / norm, z: -gCam.z / norm)
    }

    static func sample(_ dm: CMDeviceMotion) -> CalibrationMotionSample {
        CalibrationMotionSample(
            timestamp: dm.timestamp,
            gravity: CalibrationVector3(x: dm.gravity.x, y: dm.gravity.y, z: dm.gravity.z),
            userAcceleration: CalibrationVector3(
                x: dm.userAcceleration.x,
                y: dm.userAcceleration.y,
                z: dm.userAcceleration.z
            ),
            rotationRate: CalibrationVector3(
                x: dm.rotationRate.x,
                y: dm.rotationRate.y,
                z: dm.rotationRate.z
            )
        )
    }

    // MARK: - AE/AWB Lock, Unlock & Re-Meter Guard (§3.3, §11.1 item 5)

    var exposureState: ExposureLockState {
        lock.lock()
        defer { lock.unlock() }
        return _exposureState
    }

    /// True while AE/AWB has been locked by this sensor controller (false while unlocked or during a 1 s re-meter).
    var isExposureLocked: Bool {
        exposureState.exposureLocked
    }

    var lockedMeanLuma: Double? {
        exposureState.lockedMeanLuma
    }

    var lockedISO: Double? {
        exposureState.lockedISO
    }

    var lockedExposureDurationS: Double? {
        exposureState.lockedExposureDurationS
    }

    /// True when `device` currently reports `.locked` or `.custom` exposure mode.
    static func isExposureLocked(_ device: AVCaptureDevice?) -> Bool {
        guard let device else { return false }
        return device.exposureMode == .locked || device.exposureMode == .custom
    }

    /// Locks exposure and white balance immediately after Pose 1 (`.rest`) completes (§3.3):
    /// - Caps shutter duration at `tuning.exposureMaxShutterS` (`1/60 s` default) via `.custom` mode with proportional
    ///   ISO boost capped at `0.75 * activeFormat.maxISO` when supported, else falls back to `exposureMode = .locked`.
    /// - Locks white balance via `whiteBalanceMode = .locked` when supported.
    /// - Records `lockedMeanLuma`, `lockedISO`, `lockedExposureDurationS`, and `isAdjusting*` slew diagnostics.
    @discardableResult
    func lockExposureAndWhiteBalance(
        on device: AVCaptureDevice?,
        meanLuma: Double? = nil,
        tuning: CalibrationTuning = .defaults
    ) -> ExposureLockState {
        guard let device else {
            lock.lock()
            _exposureState = ExposureLockState()
            remeterStartTime = nil
            let snapshot = _exposureState
            lock.unlock()
            return snapshot
        }

        let wasAdjustingAE = device.isAdjustingExposure
        let wasAdjustingAWB = device.isAdjustingWhiteBalance

        var committedISO: Double?
        var committedDurationS: Double?
        var didLockExposure = false

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let rawSeconds = device.exposureDuration.seconds
            let currentSeconds = (rawSeconds.isFinite && rawSeconds > 0) ? rawSeconds : 0.0
            let currentISO = Double(device.iso)
            let maxShutterS = max(0.001, tuning.exposureMaxShutterS)

            if currentSeconds > maxShutterS, device.isExposureModeSupported(.custom) {
                // Default 0.0167 corresponds to 1/60 s (0.0166667 s); honor live tuning overrides when changed.
                let desiredSeconds = abs(maxShutterS - 0.0167) < 0.0005 ? (1.0 / 60.0) : maxShutterS
                let desiredTime = CMTimeMakeWithSeconds(desiredSeconds, preferredTimescale: 1_000_000)
                let minDur = device.activeFormat.minExposureDuration
                let maxDur = device.activeFormat.maxExposureDuration
                let clampedTime = CMTimeMaximum(minDur, CMTimeMinimum(maxDur, desiredTime))
                let appliedSeconds = max(1e-6, clampedTime.seconds)

                let scaledISO = currentISO * (currentSeconds / appliedSeconds)
                let softMaxISO = Double(device.activeFormat.maxISO) * 0.75
                let targetISO = min(softMaxISO, scaledISO)
                let clampedISO = min(
                    device.activeFormat.maxISO,
                    max(device.activeFormat.minISO, Float(targetISO))
                )

                device.setExposureModeCustom(duration: clampedTime, iso: clampedISO, completionHandler: nil)
                committedISO = Double(clampedISO)
                committedDurationS = appliedSeconds
                didLockExposure = true
            } else if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
                committedISO = currentISO
                committedDurationS = currentSeconds
                didLockExposure = true
            } else {
                didLockExposure = Self.isExposureLocked(device)
                committedISO = currentISO
                committedDurationS = currentSeconds
            }

            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
        } catch {
            DebugLog.warn("ae_awb_lock failed: \(error.localizedDescription)")
        }

        let sanitizedLuma: Double?
        if let meanLuma, meanLuma.isFinite {
            sanitizedLuma = meanLuma
        } else {
            sanitizedLuma = nil
        }

        let state = ExposureLockState(
            exposureLocked: didLockExposure,
            isRemetering: false,
            lockedMeanLuma: sanitizedLuma,
            lockedISO: committedISO,
            lockedExposureDurationS: committedDurationS,
            wasAdjustingExposureAtLock: wasAdjustingAE,
            wasAdjustingWhiteBalanceAtLock: wasAdjustingAWB
        )

        lock.lock()
        _exposureState = state
        remeterStartTime = nil
        lock.unlock()

        DebugLog.info(
            "ae_awb_lock locked=\(didLockExposure) iso=\(String(format: "%.1f", committedISO ?? 0)) "
            + "shutterS=\(String(format: "%.5f", committedDurationS ?? 0)) "
            + "luma=\(sanitizedLuma.map { String(format: "%.3f", $0) } ?? "nil") "
            + "slewAE=\(wasAdjustingAE) slewAWB=\(wasAdjustingAWB)"
        )
        return state
    }

    /// Restores continuous auto-exposure and auto-white-balance on `device` and clears stored lock baselines (§3.3).
    func unlockExposureAndWhiteBalance(on device: AVCaptureDevice?) {
        Self.unlockDeviceExposureAndWhiteBalance(device)
        lock.lock()
        let wasLocked = _exposureState.exposureLocked || _exposureState.isRemetering
        _exposureState = ExposureLockState()
        remeterStartTime = nil
        lock.unlock()
        if wasLocked {
            DebugLog.info("ae_awb_unlock restored continuous AE/AWB")
        }
    }

    /// Stateless helper restoring `.continuousAutoExposure` and `.continuousAutoWhiteBalance` on `device`
    /// (used on `PracticeCamera.stop()`, camera-mode switches, bump resets, and `calibration.cancel()`).
    static func unlockDeviceExposureAndWhiteBalance(_ device: AVCaptureDevice?) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        } catch {
            DebugLog.warn("ae_awb_unlock failed: \(error.localizedDescription)")
        }
    }

    /// Between-take 2 Hz luma drift guard (§3.3):
    /// When `allowRemeter` is true (e.g. `.idle` / `.results`) and `|meanLuma - lockedMeanLuma| > tuning.remeterLumaDelta`,
    /// reverts to continuous AE/AWB for `1.0 s` and then re-locks at the new scene brightness.
    @discardableResult
    func evaluateRemeterIfNeeded(
        meanLuma: Double,
        at time: Double,
        device: AVCaptureDevice?,
        allowRemeter: Bool = true,
        tuning: CalibrationTuning = .defaults
    ) -> ExposureLockState {
        lock.lock()
        let currentState = _exposureState
        let activeRemeterStart = remeterStartTime
        lock.unlock()

        if currentState.isRemetering {
            let startedAt = activeRemeterStart ?? time
            if !allowRemeter || (time - startedAt >= Self.remeterSettleDurationS) {
                return lockExposureAndWhiteBalance(on: device, meanLuma: meanLuma, tuning: tuning)
            }
            return currentState
        }

        guard currentState.exposureLocked,
              allowRemeter,
              meanLuma.isFinite,
              let baselineLuma = currentState.lockedMeanLuma,
              abs(meanLuma - baselineLuma) > tuning.remeterLumaDelta else {
            return currentState
        }

        Self.unlockDeviceExposureAndWhiteBalance(device)
        let remeteringState = ExposureLockState(
            exposureLocked: false,
            isRemetering: true,
            lockedMeanLuma: baselineLuma,
            lockedISO: nil,
            lockedExposureDurationS: nil,
            wasAdjustingExposureAtLock: false,
            wasAdjustingWhiteBalanceAtLock: false
        )
        lock.lock()
        _exposureState = remeteringState
        remeterStartTime = time
        lock.unlock()

        DebugLog.info(
            "ae_awb_remeter triggered meanLuma=\(String(format: "%.3f", meanLuma)) "
            + "baseline=\(String(format: "%.3f", baselineLuma)) delta=\(String(format: "%.3f", abs(meanLuma - baselineLuma)))"
        )
        return remeteringState
    }

    // MARK: - Light (call on the camera analysis queue)

    /// Torso box (normalised raw image coordinates) spanning both shoulders and hips, or nil without a person.
    static func torsoRect(_ landmarks: [CalibrationLandmark], minVisibility: Double = 0.5) -> CGRect? {
        let idx = ["leftShoulder", "rightShoulder", "leftHip", "rightHip"].compactMap {
            CanonicalSkeleton.mediapipeIndex[$0]
        }
        guard landmarks.count == CanonicalSkeleton.poseLandmarkCount else { return nil }
        let pts = idx.map { landmarks[$0] }
        guard pts.allSatisfy({ $0.visibility >= minVisibility }) else { return nil }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(),
              x1 - x0 > 0.01, y1 - y0 > 0.01 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// One light sample from a 32BGRA buffer: a 10x10 grid mean, five border points, five torso points, and the
    /// device's exposure readings.
    static func lightSample(_ pb: CVPixelBuffer, device: AVCaptureDevice?, torso: CGRect?) -> CalibrationLightSample? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let raw = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        guard w > 0, h > 0 else { return nil }
        let base = raw.assumingMemoryBound(to: UInt8.self)

        func luma(_ nx: Double, _ ny: Double) -> Double {
            let px = min(w - 1, max(0, Int(nx * Double(w))))
            let py = min(h - 1, max(0, Int(ny * Double(h))))
            let o = py * bpr + px * 4
            // BGRA, Rec. 709 weights.
            return (0.0722 * Double(base[o]) + 0.7152 * Double(base[o + 1]) + 0.2126 * Double(base[o + 2])) / 255.0
        }

        var sum = 0.0
        for i in 0..<10 {
            for j in 0..<10 {
                sum += luma((Double(i) + 0.5) / 10.0, (Double(j) + 0.5) / 10.0)
            }
        }
        let borderPoints: [(Double, Double)] = [(0.05, 0.1), (0.95, 0.1), (0.05, 0.5), (0.95, 0.5), (0.5, 0.03)]
        var borderSum = 0.0
        for (bx, by) in borderPoints { borderSum += luma(bx, by) }

        var torsoLuma: Double?
        if let r = torso {
            let x0 = Double(r.minX), y0 = Double(r.minY), rw = Double(r.width), rh = Double(r.height)
            let torsoPoints: [(Double, Double)] = [(0.3, 0.3), (0.7, 0.3), (0.5, 0.5), (0.3, 0.7), (0.7, 0.7)]
            var torsoSum = 0.0
            for (fx, fy) in torsoPoints {
                let nx: Double = x0 + fx * rw
                let ny: Double = y0 + fy * rh
                torsoSum += luma(nx, ny)
            }
            torsoLuma = torsoSum / Double(torsoPoints.count)
        }

        var iso = 0.0, maxISO = 0.0, exposure = 0.0
        if let device {
            iso = Double(device.iso)
            maxISO = Double(device.activeFormat.maxISO)
            let s = device.exposureDuration.seconds
            exposure = s.isFinite ? s : 0
        }
        return CalibrationLightSample(
            meanLuma: sum / 100.0,
            torsoLuma: torsoLuma,
            borderLuma: borderSum / Double(borderPoints.count),
            iso: iso,
            maxISO: maxISO,
            exposureSeconds: exposure
        )
    }

    /// Pairs `lightSample(_:device:torso:)` with the active `exposureLocked` boolean for v2 telemetry (§3.3, §7.1).
    static func lightSampleWithExposureLock(
        _ pb: CVPixelBuffer,
        device: AVCaptureDevice?,
        torso: CGRect?,
        sensors: CalibrationSensors? = nil
    ) -> (sample: CalibrationLightSample, exposureLocked: Bool)? {
        guard let sample = lightSample(pb, device: device, torso: torso) else { return nil }
        let locked = sensors?.isExposureLocked ?? isExposureLocked(device)
        return (sample: sample, exposureLocked: locked)
    }

    // MARK: - FoV, Intrinsics & Canonical 3D Back-Projection (§3.1, §3.2)

    /// Portrait vertical FoV (degrees) from `AVCaptureDevice.Format.videoFieldOfView` (sensor long-side FoV),
    /// falling back to `60.0°` when `0` / unknown (§3.2).
    static func resolvedVerticalFoVDeg(
        for device: AVCaptureDevice?,
        fallback: Double = defaultVerticalFoVDeg
    ) -> Double {
        let raw = Double(device?.activeFormat.videoFieldOfView ?? 0)
        if raw.isFinite && raw > 0.0 && raw < 179.0 {
            return raw
        }
        return fallback
    }

    /// Portrait horizontal (narrow-axis) FoV in degrees from portrait `verticalFoVDeg` (`9:16` default; §3.2).
    static func portraitHorizontalFoVDeg(
        fromVerticalFoVDeg verticalFoVDeg: Double,
        aspectRatio: Double = 9.0 / 16.0
    ) -> Double {
        CalibrationIntrinsics.portraitHorizontalFoVDeg(
            fromVerticalFoVDeg: verticalFoVDeg,
            aspectRatio: aspectRatio
        )
    }

    /// Extracts per-frame `CalibrationIntrinsics` from a portrait video `CMSampleBuffer`'s
    /// `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` attachment (§3.1 item 2, §11.1 item 4).
    static func videoIntrinsics(
        from sampleBuffer: CMSampleBuffer,
        fallbackVerticalFoVDeg: Double = defaultVerticalFoVDeg
    ) -> CalibrationIntrinsics? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        guard let rawAttachment = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil
        ),
              let data = rawAttachment as? Data,
              data.count >= MemoryLayout<matrix_float3x3>.size else {
            return nil
        }

        var matrix = matrix_float3x3()
        _ = withUnsafeMutableBytes(of: &matrix) { dst in
            data.copyBytes(to: dst)
        }

        let rawFx = Double(matrix.columns.0.x)
        let rawFy = Double(matrix.columns.1.y)
        let rawCx = Double(matrix.columns.2.x)
        let rawCy = Double(matrix.columns.2.y)
        guard rawFx.isFinite, rawFy.isFinite, rawFx > 0, rawFy > 0,
              rawCx.isFinite, rawCy.isFinite else {
            return nil
        }

        // Detect whether the attachment's principal point is still in landscape sensor axes (1280x720)
        // when `videoRotationAngle = 90` has already rotated the pixel buffer to portrait (720x1280).
        let fx: Double
        let fy: Double
        let cx: Double
        let cy: Double
        if width < height,
           rawCx > rawCy,
           abs(rawCx - Double(height) * 0.5) < abs(rawCx - Double(width) * 0.5) {
            fx = rawFy
            fy = rawFx
            cx = Double(width) - rawCy
            cy = rawCx
        } else {
            fx = rawFx
            fy = rawFy
            cx = rawCx
            cy = rawCy
        }

        var intrinsics = CalibrationIntrinsics.fromPinhole(
            fx: fx,
            fy: fy,
            cx: cx,
            cy: cy,
            width: width,
            height: height
        )
        if !(intrinsics.verticalFoVDeg > 0 && intrinsics.verticalFoVDeg < 179.0) {
            let vFoV = (fallbackVerticalFoVDeg > 0 && fallbackVerticalFoVDeg < 179.0)
                ? fallbackVerticalFoVDeg
                : defaultVerticalFoVDeg
            intrinsics.verticalFoVDeg = vFoV
            intrinsics.horizontalFoVDeg = portraitHorizontalFoVDeg(
                fromVerticalFoVDeg: vFoV,
                aspectRatio: Double(width) / Double(height)
            )
        }
        return intrinsics
    }

    /// Back-projects 2D pixel `(u, v)` (`u` right, `v` down) at optical depth `depthM > 0` directly into
    /// `CanonicalSkeleton` right-handed camera coordinates (`+X` right, `+Y` up, `+Z` toward lens; §3.1).
    static func backProjectToCanonical(
        u: Double,
        v: Double,
        depthM: Double,
        intrinsics: CalibrationIntrinsics
    ) -> CalibrationVector3 {
        intrinsics.backProjectToCanonical(u: u, v: v, depthM: depthM)
    }

    /// Applies radial undistortion from `AVCameraCalibrationData.lensDistortionLookupTable` around
    /// `lensDistortionCenter` (evaluated in `referenceDimensions` coordinates and mapped back to `(width, height)`).
    static func undistortPixel(
        u: Double,
        v: Double,
        width: Int,
        height: Int,
        distortionCenter: CGPoint,
        referenceDimensions: CGSize,
        lookupTable: [Float]
    ) -> (u: Double, v: Double) {
        guard !lookupTable.isEmpty,
              width > 0,
              height > 0,
              referenceDimensions.width > 0,
              referenceDimensions.height > 0 else {
            return (u, v)
        }
        let refW = Double(referenceDimensions.width)
        let refH = Double(referenceDimensions.height)
        let sx = refW / Double(width)
        let sy = refH / Double(height)
        let xRef = u * sx
        let yRef = v * sy
        let dcx = Double(distortionCenter.x)
        let dcy = Double(distortionCenter.y)
        let dx = xRef - dcx
        let dy = yRef - dcy
        let r = (dx * dx + dy * dy).squareRoot()

        let r00 = (dcx * dcx + dcy * dcy).squareRoot()
        let r10 = ((refW - dcx) * (refW - dcx) + dcy * dcy).squareRoot()
        let r01 = (dcx * dcx + (refH - dcy) * (refH - dcy)).squareRoot()
        let r11 = ((refW - dcx) * (refW - dcx) + (refH - dcy) * (refH - dcy)).squareRoot()
        let rMax = max(max(r00, r10), max(r01, r11))
        guard rMax > 1e-6 else { return (u, v) }

        let mag: Double
        if lookupTable.count == 1 {
            mag = Double(lookupTable[0])
        } else if r >= rMax {
            mag = Double(lookupTable[lookupTable.count - 1])
        } else {
            let pos = (r / rMax) * Double(lookupTable.count - 1)
            let idx = min(lookupTable.count - 2, max(0, Int(pos)))
            let frac = pos - Double(idx)
            let a = Double(lookupTable[idx])
            let b = Double(lookupTable[idx + 1])
            mag = a + (b - a) * frac
        }
        guard mag.isFinite, abs(mag) < 0.5 else { return (u, v) }
        let xUndist = dcx + (1.0 + mag) * dx
        let yUndist = dcy + (1.0 + mag) * dy
        return (xUndist / sx, yUndist / sy)
    }

    // MARK: - Gravity-Guided Floor Plane RANSAC (§3.4)

    /// Fits floor plane `n_floor · P + h_cam = 0` (`n_floor · n_g > 0`, `h_cam > 0`) in `CanonicalSkeleton`
    /// camera coordinates via 40-iteration 3-point RANSAC (`inlierThreshold = 0.02 m`, normal within `15°` of `n_g`,
    /// `>= 80` inliers; spec §3.4).
    static func fitFloorPlane(
        points: [CalibrationVector3],
        expectedUpwardNormal: CalibrationVector3,
        iterations: Int = floorRansacIterations,
        inlierThresholdM: Double = floorRansacInlierThresholdM,
        maxAngleDeg: Double = floorRansacMaxTiltDeltaDeg,
        minInliers: Int = floorRansacMinInliers
    ) -> CalibrationProfileV2.FloorPlane? {
        guard points.count >= max(3, minInliers) else { return nil }
        let nGNorm = expectedUpwardNormal.norm
        guard nGNorm > 1e-6 else { return nil }
        let nG = CalibrationVector3(
            x: expectedUpwardNormal.x / nGNorm,
            y: expectedUpwardNormal.y / nGNorm,
            z: expectedUpwardNormal.z / nGNorm
        )
        let minCosAngle = cos(maxAngleDeg * .pi / 180.0)

        var rng = SplitMix64(seed: UInt64(points.count) &* 0x9E37_79B9_7F4A_7C15 &+ 0xD1B5_4A32_D192_ED03)
        let count = points.count
        var bestNormal: CalibrationVector3?
        var bestHeightM: Double = 0.0
        var bestInliers = 0
        var bestMeanResidual = Double.infinity

        var validHypotheses = 0
        var draws = 0
        let maxDraws = max(iterations, iterations * 3)

        while validHypotheses < iterations && draws < maxDraws {
            draws += 1
            let i0 = Int(rng.next() % UInt64(count))
            var i1 = Int(rng.next() % UInt64(count - 1))
            if i1 >= i0 { i1 += 1 }
            var i2 = Int(rng.next() % UInt64(count - 2))
            let low = min(i0, i1)
            let high = max(i0, i1)
            if i2 >= low { i2 += 1 }
            if i2 >= high { i2 += 1 }

            let p0 = points[i0]
            let p1 = points[i1]
            let p2 = points[i2]
            let v1 = vecSub(p1, p0)
            let v2 = vecSub(p2, p0)
            let cross = vecCross(v1, v2)
            let crossLen = cross.norm
            guard crossLen > 1e-6 else { continue }
            validHypotheses += 1

            var candidateN = CalibrationVector3(
                x: cross.x / crossLen,
                y: cross.y / crossLen,
                z: cross.z / crossLen
            )
            if vecDot(candidateN, nG) < 0 {
                candidateN = CalibrationVector3(x: -candidateN.x, y: -candidateN.y, z: -candidateN.z)
            }
            guard vecDot(candidateN, nG) >= minCosAngle else { continue }

            let candidateHCam = -vecDot(candidateN, p0)
            guard candidateHCam.isFinite, candidateHCam > 0.05 else { continue }

            var inliers = 0
            var residualSum = 0.0
            for p in points {
                let res = abs(vecDot(candidateN, p) + candidateHCam)
                if res <= inlierThresholdM {
                    inliers += 1
                    residualSum += res
                }
            }
            guard inliers >= minInliers else { continue }
            let meanRes = residualSum / Double(inliers)
            if inliers > bestInliers || (inliers == bestInliers && meanRes < bestMeanResidual) {
                bestInliers = inliers
                bestMeanResidual = meanRes
                bestNormal = candidateN
                bestHeightM = candidateHCam
            }
        }

        guard let chosenNormal = bestNormal, bestInliers >= minInliers else {
            return nil
        }

        // Refine perpendicular offset `h_cam = -mean(n_floor · P_inlier)` over the winning inlier set.
        var projectionSum = 0.0
        var refinedCount = 0
        for p in points {
            let dotNP = vecDot(chosenNormal, p)
            if abs(dotNP + bestHeightM) <= inlierThresholdM {
                projectionSum += dotNP
                refinedCount += 1
            }
        }
        let refinedHeightM = refinedCount >= minInliers ? (-projectionSum / Double(refinedCount)) : bestHeightM
        guard refinedHeightM.isFinite, refinedHeightM > 0.05 else { return nil }

        let disagreementDeg = CalibrationProfileV2.angleBetweenDeg(chosenNormal, nG)
        return CalibrationProfileV2.FloorPlane(
            normal: chosenNormal.array,
            cameraHeightM: refinedHeightM,
            lidarGravityDisagreementDeg: disagreementDeg
        )
    }

    // MARK: - LiDAR `AVDepthData` Extraction (§1.2, §2.2 Pose 5, §3.1, §3.4, §3.5)

    /// Converts one rear-LiDAR `AVDepthData` frame (plus concurrent MediaPipe 2D landmarks and CoreMotion gravity)
    /// into a pure `CalibrationDepthSample` for `CalibrationGate.update(depth:)` (off-main safe).
    static func depthSample(
        from rawDepthData: AVDepthData,
        timestamp: Double,
        landmarks: [CalibrationLandmark],
        deviceGravity: [Double],
        cameraMode: CameraMode = .rearLiDAR,
        verticalFoVDeg: Double? = nil,
        targetVideoWidth: Int = 720,
        targetVideoHeight: Int = 1280
    ) -> CalibrationDepthSample? {
        var depthData = rawDepthData
        if depthData.depthDataType != kCVPixelFormatType_DepthFloat32 {
            depthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        }
        let initialMap = depthData.depthDataMap
        if CVPixelBufferGetWidth(initialMap) > CVPixelBufferGetHeight(initialMap) {
            // Rotate landscape sensor depth + calibration data 90 deg CW into upright portrait.
            depthData = depthData.applyingExifOrientation(.right)
        }

        let depthMap = depthData.depthDataMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            return nil
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let rawBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let mapW = CVPixelBufferGetWidth(depthMap)
        let mapH = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard mapW > 0,
              mapH > 0,
              bytesPerRow >= mapW * MemoryLayout<Float32>.size,
              bytesPerRow % MemoryLayout<Float32>.size == 0 else {
            return nil
        }

        let resolvedCal = extractDepthCalibration(
            from: depthData.cameraCalibrationData,
            mapWidth: mapW,
            mapHeight: mapH,
            targetVideoWidth: targetVideoWidth,
            targetVideoHeight: targetVideoHeight,
            fallbackVerticalFoVDeg: verticalFoVDeg ?? defaultVerticalFoVDeg
        )
        let depthIntrinsics = resolvedCal.depthIntrinsics
        let videoIntrinsics = resolvedCal.videoIntrinsics
        let effectiveVFoV = resolvedCal.verticalFoVDeg

        func depthAtPixel(_ px: Int, _ py: Int) -> Double? {
            guard px >= 0, px < mapW, py >= 0, py < mapH else { return nil }
            let row = rawBase.advanced(by: py * bytesPerRow).assumingMemoryBound(to: Float32.self)
            let z = Double(row[px])
            guard z.isFinite, z > 0.05, z <= 5.2 else { return nil }
            return z
        }

        func backProjectMapPixel(_ u: Double, _ v: Double, depthM: Double) -> CalibrationVector3 {
            let undist = undistortPixel(
                u: u,
                v: v,
                width: mapW,
                height: mapH,
                distortionCenter: resolvedCal.distortionCenter,
                referenceDimensions: resolvedCal.referenceDimensions,
                lookupTable: resolvedCal.lookupTable
            )
            return depthIntrinsics.backProjectToCanonical(u: undist.u, v: undist.v, depthM: depthM)
        }

        func patchDepths(
            nx: Double,
            ny: Double,
            halfWindow: Int,
            minDepthM: Double = 0.4,
            maxDepthM: Double = 5.0
        ) -> [Double] {
            guard nx.isFinite, ny.isFinite, nx >= 0.0, nx <= 1.0, ny >= 0.0, ny <= 1.0 else { return [] }
            let cx = min(mapW - 1, max(0, Int((nx * Double(mapW)).rounded())))
            let cy = min(mapH - 1, max(0, Int((ny * Double(mapH)).rounded())))
            var values: [Double] = []
            values.reserveCapacity((2 * halfWindow + 1) * (2 * halfWindow + 1))
            let y0 = max(0, cy - halfWindow)
            let y1 = min(mapH - 1, cy + halfWindow)
            let x0 = max(0, cx - halfWindow)
            let x1 = min(mapW - 1, cx + halfWindow)
            for py in y0...y1 {
                for px in x0...x1 {
                    if let z = depthAtPixel(px, py), z >= minDepthM, z <= maxDepthM {
                        values.append(z)
                    }
                }
            }
            return values
        }

        func landmark(_ name: String, minVis: Double) -> CalibrationLandmark? {
            guard landmarks.count == CanonicalSkeleton.poseLandmarkCount,
                  let idx = CanonicalSkeleton.mediapipeIndex[name],
                  idx < landmarks.count else {
                return nil
            }
            let lm = landmarks[idx]
            guard lm.visibility >= minVis,
                  lm.x.isFinite, lm.y.isFinite,
                  lm.x >= 0.0, lm.x <= 1.0, lm.y >= 0.0, lm.y <= 1.0 else {
                return nil
            }
            return lm
        }

        // 1. Gravity-guided floor plane RANSAC (§3.4): lower third `v / H >= 0.65`, excluding dancer bbox.
        let personBox = dancerExclusionRect(landmarks)
        let startY = max(0, Int((Self.floorLowerFrameMinY * Double(mapH)).rounded()))
        let endY = mapH - 1
        let stepX = max(1, mapW / 48)
        let stepY = max(1, max(1, endY - startY + 1) / 24)

        var floorPoints: [CalibrationVector3] = []
        if startY <= endY {
            floorPoints.reserveCapacity(1200)
            var py = startY
            while py <= endY {
                let ny = (Double(py) + 0.5) / Double(mapH)
                var px = stepX / 2
                while px < mapW {
                    let nx = (Double(px) + 0.5) / Double(mapW)
                    let insidePerson = personBox.map { $0.contains(CGPoint(x: nx, y: ny)) } ?? false
                    if !insidePerson,
                       let z = depthAtPixel(px, py),
                       z >= Self.floorDepthMinM,
                       z <= Self.floorDepthMaxM {
                        floorPoints.append(backProjectMapPixel(Double(px) + 0.5, Double(py) + 0.5, depthM: z))
                    }
                    px += stepX
                }
                py += stepY
            }
        }

        var fittedFloor: CalibrationProfileV2.FloorPlane?
        if let nG = upwardFloorNormal(fromDeviceGravity: CalibrationVector3(deviceGravity), cameraMode: cameraMode) {
            fittedFloor = fitFloorPlane(points: floorPoints, expectedUpwardNormal: nG)
        }

        // 2. Dancer torso distance (§3.5 item 1): median across 5x5 patches on mid-shoulder and mid-hip.
        var torsoDepthSamples: [Double] = []
        if let ls = landmark("leftShoulder", minVis: 0.4),
           let rs = landmark("rightShoulder", minVis: 0.4) {
            torsoDepthSamples.append(
                contentsOf: patchDepths(
                    nx: 0.5 * (ls.x + rs.x),
                    ny: 0.5 * (ls.y + rs.y),
                    halfWindow: 2,
                    minDepthM: 0.5,
                    maxDepthM: 5.0
                )
            )
        }
        if let lh = landmark("leftHip", minVis: 0.4),
           let rh = landmark("rightHip", minVis: 0.4) {
            torsoDepthSamples.append(
                contentsOf: patchDepths(
                    nx: 0.5 * (lh.x + rh.x),
                    ny: 0.5 * (lh.y + rh.y),
                    halfWindow: 2,
                    minDepthM: 0.5,
                    maxDepthM: 5.0
                )
            )
        }
        let dancerDistanceM = medianValue(torsoDepthSamples)

        // 3. Metric dancer height (§3.5 item 2): nose + lowest heel back-projected at Z_torso above floor + 0.15 crown.
        var measuredHeightM: Double?
        if let floor = fittedFloor,
           let zTorso = dancerDistanceM,
           let nose = landmark("nose", minVis: 0.5) {
            let heels = [
                landmark("leftHeel", minVis: 0.4),
                landmark("rightHeel", minVis: 0.4)
            ].compactMap { $0 }
            if let lowestHeel = heels.max(by: { $0.y < $1.y }) {
                let nFloor = floor.normalVector
                let pNose = backProjectMapPixel(nose.x * Double(mapW), nose.y * Double(mapH), depthM: zTorso)
                let pHeel = backProjectMapPixel(
                    lowestHeel.x * Double(mapW),
                    lowestHeel.y * Double(mapH),
                    depthM: zTorso
                )
                let hNose = vecDot(nFloor, pNose) + floor.cameraHeightM
                let hHeel = vecDot(nFloor, pHeel) + floor.cameraHeightM
                if hNose > hHeel, abs(hHeel) <= 0.25 {
                    let hDancer = hNose + 0.15 * (hNose - hHeel)
                    if hDancer >= 1.10 && hDancer <= 2.20 {
                        measuredHeightM = hDancer
                    }
                }
            }
        }

        // 4. Metric 3D joint back-projection -> `lidarBoneLengthsM` (§1.2 item 3) & `shoulderToWristDeltaZM` (§2.2 Pose 5).
        let minForegroundZ = dancerDistanceM.map { max(0.4, $0 - 0.95) } ?? 0.4
        let maxForegroundZ = dancerDistanceM.map { min(5.0, $0 + 0.65) } ?? 5.0

        func jointDepthM(_ lm: CalibrationLandmark, halfWindow: Int) -> Double? {
            let fg = patchDepths(
                nx: lm.x,
                ny: lm.y,
                halfWindow: halfWindow,
                minDepthM: minForegroundZ,
                maxDepthM: maxForegroundZ
            )
            if let med = medianValue(fg) { return med }
            return medianValue(patchDepths(nx: lm.x, ny: lm.y, halfWindow: halfWindow, minDepthM: 0.4, maxDepthM: 5.0))
        }

        var joints3D: [String: CalibrationVector3] = [:]
        var jointDepths: [String: Double] = [:]
        let torsoJointNames: Set<String> = ["leftShoulder", "rightShoulder", "leftHip", "rightHip"]

        for name in CanonicalSkeleton.mediapipeIndex.keys {
            guard let lm = landmark(name, minVis: 0.45) else { continue }
            let halfWin = torsoJointNames.contains(name) ? 2 : 1
            guard let z = jointDepthM(lm, halfWindow: halfWin) else { continue }
            jointDepths[name] = z
            joints3D[name] = backProjectMapPixel(lm.x * Double(mapW), lm.y * Double(mapH), depthM: z)
        }

        if let lh = joints3D["leftHip"], let rh = joints3D["rightHip"] {
            joints3D["root"] = vecMid(lh, rh)
        }
        if let ls = joints3D["leftShoulder"], let rs = joints3D["rightShoulder"] {
            joints3D["centerShoulder"] = vecMid(ls, rs)
        }
        if let root = joints3D["root"], let cs = joints3D["centerShoulder"] {
            joints3D["spine"] = vecMid(root, cs)
        }

        var lidarBoneLengthsM: [String: Double] = [:]
        for bone in CanonicalSkeleton.canonicalBones {
            guard let c = joints3D[bone.child], let p = joints3D[bone.parent] else { continue }
            let len = c.distance(to: p)
            if len.isFinite && len > 0.02 && len < 1.0 {
                lidarBoneLengthsM[bone.child] = len
            }
        }

        var forwardDeltas: [Double] = []
        if let zLS = jointDepths["leftShoulder"], let zLW = jointDepths["leftWrist"] {
            forwardDeltas.append(zLS - zLW)
        }
        if let zRS = jointDepths["rightShoulder"], let zRW = jointDepths["rightWrist"] {
            forwardDeltas.append(zRS - zRW)
        }
        let shoulderToWristDeltaZM = forwardDeltas.min()

        return CalibrationDepthSample(
            timestamp: timestamp,
            dancerDistanceM: dancerDistanceM,
            measuredHeightM: measuredHeightM,
            cameraHeightM: fittedFloor?.cameraHeightM,
            floorNormal: fittedFloor?.normalVector,
            lidarBoneLengthsM: lidarBoneLengthsM,
            shoulderToWristDeltaZM: shoulderToWristDeltaZM,
            verticalFoVDeg: effectiveVFoV,
            intrinsics: videoIntrinsics
        )
    }

    // MARK: - Private Geometry & Calibration Helpers

    private struct ResolvedDepthCalibration {
        var depthIntrinsics: CalibrationIntrinsics
        var videoIntrinsics: CalibrationIntrinsics
        var verticalFoVDeg: Double
        var distortionCenter: CGPoint
        var referenceDimensions: CGSize
        var lookupTable: [Float]
    }

    private static func extractDepthCalibration(
        from calData: AVCameraCalibrationData?,
        mapWidth: Int,
        mapHeight: Int,
        targetVideoWidth: Int,
        targetVideoHeight: Int,
        fallbackVerticalFoVDeg: Double
    ) -> ResolvedDepthCalibration {
        let safeFallbackVFoV = (fallbackVerticalFoVDeg.isFinite && fallbackVerticalFoVDeg > 0 && fallbackVerticalFoVDeg < 179.0)
            ? fallbackVerticalFoVDeg
            : defaultVerticalFoVDeg

        if let calData {
            let m = calData.intrinsicMatrix
            let rawFx = Double(m.columns.0.x)
            let rawFy = Double(m.columns.1.y)
            let rawCx = Double(m.columns.2.x)
            let rawCy = Double(m.columns.2.y)
            let rawRef = calData.intrinsicMatrixReferenceDimensions

            if rawFx.isFinite, rawFy.isFinite, rawFx > 0, rawFy > 0,
               rawCx.isFinite, rawCy.isFinite,
               rawRef.width > 0, rawRef.height > 0 {
                let fx: Double
                let fy: Double
                let cx: Double
                let cy: Double
                let refW: Int
                let refH: Int
                let distCenter: CGPoint

                // If `depthDataMap` was rotated into portrait (`mapWidth < mapHeight`) by `AVCaptureConnection`
                // while `intrinsicMatrixReferenceDimensions` remained landscape (`width > height`), rotate 90 deg CW.
                if mapWidth < mapHeight && rawRef.width > rawRef.height {
                    fx = rawFy
                    fy = rawFx
                    cx = Double(rawRef.height) - rawCy
                    cy = rawCx
                    refW = max(1, Int(rawRef.height.rounded()))
                    refH = max(1, Int(rawRef.width.rounded()))
                    distCenter = CGPoint(
                        x: rawRef.height - calData.lensDistortionCenter.y,
                        y: calData.lensDistortionCenter.x
                    )
                } else {
                    fx = rawFx
                    fy = rawFy
                    cx = rawCx
                    cy = rawCy
                    refW = max(1, Int(rawRef.width.rounded()))
                    refH = max(1, Int(rawRef.height.rounded()))
                    distCenter = calData.lensDistortionCenter
                }

                var refIntrinsics = CalibrationIntrinsics.fromPinhole(
                    fx: fx,
                    fy: fy,
                    cx: cx,
                    cy: cy,
                    width: refW,
                    height: refH
                )
                if !(refIntrinsics.verticalFoVDeg > 0 && refIntrinsics.verticalFoVDeg < 179.0) {
                    refIntrinsics.verticalFoVDeg = safeFallbackVFoV
                    refIntrinsics.horizontalFoVDeg = portraitHorizontalFoVDeg(fromVerticalFoVDeg: safeFallbackVFoV)
                }

                let depthScaled = refIntrinsics.scaled(toWidth: mapWidth, height: mapHeight)
                let videoScaled = refIntrinsics.scaled(toWidth: targetVideoWidth, height: targetVideoHeight)
                let table = decodeFloatLookupTable(calData.lensDistortionLookupTable)

                return ResolvedDepthCalibration(
                    depthIntrinsics: depthScaled,
                    videoIntrinsics: videoScaled,
                    verticalFoVDeg: refIntrinsics.verticalFoVDeg,
                    distortionCenter: distCenter,
                    referenceDimensions: CGSize(width: refW, height: refH),
                    lookupTable: table
                )
            }
        }

        // Pinhole fallback from `videoFieldOfView` when `cameraCalibrationData` is unavailable.
        let halfVRad = (safeFallbackVFoV * .pi / 180.0) * 0.5
        let fyVideo = (Double(targetVideoHeight) * 0.5) / max(1e-6, tan(halfVRad))
        let fxVideo = fyVideo
        let hFoV = portraitHorizontalFoVDeg(
            fromVerticalFoVDeg: safeFallbackVFoV,
            aspectRatio: Double(targetVideoWidth) / Double(max(1, targetVideoHeight))
        )
        let videoFallback = CalibrationIntrinsics(
            fx: fxVideo,
            fy: fyVideo,
            cx: Double(targetVideoWidth) * 0.5,
            cy: Double(targetVideoHeight) * 0.5,
            width: targetVideoWidth,
            height: targetVideoHeight,
            horizontalFoVDeg: hFoV,
            verticalFoVDeg: safeFallbackVFoV
        )
        let depthFallback = videoFallback.scaled(toWidth: mapWidth, height: mapHeight)
        return ResolvedDepthCalibration(
            depthIntrinsics: depthFallback,
            videoIntrinsics: videoFallback,
            verticalFoVDeg: safeFallbackVFoV,
            distortionCenter: CGPoint(x: Double(mapWidth) * 0.5, y: Double(mapHeight) * 0.5),
            referenceDimensions: CGSize(width: mapWidth, height: mapHeight),
            lookupTable: []
        )
    }

    private static func decodeFloatLookupTable(_ data: Data?) -> [Float] {
        guard let data, data.count >= MemoryLayout<Float>.size else { return [] }
        let count = data.count / MemoryLayout<Float>.size
        var values = [Float](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst)
        }
        return values
    }

    private static func dancerExclusionRect(_ landmarks: [CalibrationLandmark]) -> CGRect? {
        guard landmarks.count == CanonicalSkeleton.poseLandmarkCount else { return nil }
        let visible = landmarks.filter {
            $0.visibility >= 0.3 && $0.x.isFinite && $0.y.isFinite && $0.x >= 0.0 && $0.x <= 1.0 && $0.y >= 0.0 && $0.y <= 1.0
        }
        guard visible.count >= 4 else { return nil }
        let xs = visible.map(\.x)
        let ys = visible.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
            return nil
        }
        let x0 = max(0.0, minX - 0.04)
        let x1 = min(1.0, maxX + 0.04)
        let y0 = max(0.0, minY - 0.04)
        let y1 = min(1.0, maxY + 0.02)
        guard x1 > x0, y1 > y0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private static func medianValue(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return 0.5 * (sorted[mid - 1] + sorted[mid])
    }

    private static func vecSub(_ a: CalibrationVector3, _ b: CalibrationVector3) -> CalibrationVector3 {
        CalibrationVector3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }

    private static func vecMid(_ a: CalibrationVector3, _ b: CalibrationVector3) -> CalibrationVector3 {
        CalibrationVector3(x: 0.5 * (a.x + b.x), y: 0.5 * (a.y + b.y), z: 0.5 * (a.z + b.z))
    }

    private static func vecDot(_ a: CalibrationVector3, _ b: CalibrationVector3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func vecCross(_ a: CalibrationVector3, _ b: CalibrationVector3) -> CalibrationVector3 {
        CalibrationVector3(
            x: a.y * b.z - a.z * b.y,
            y: a.z * b.x - a.x * b.z,
            z: a.x * b.y - a.y * b.x
        )
    }

    private struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
