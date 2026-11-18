import AVFoundation
import CoreGraphics
import CoreMotion
import CoreVideo
import GrooveCore

/// Sensor inputs of the calibration gate (spec: docs/research/2026-11-18-calibration-research.md, steps 1 and 3):
/// - `CMDeviceMotion` at 30 Hz (gravity, userAcceleration, rotationRate), delivered on the main queue;
/// - the front camera's `iso`, `activeFormat.maxISO` and `exposureDuration`;
/// - mean, torso and border luma read from the 32BGRA camera buffer (sampled at 2 Hz by the caller).
///
/// One instance per screen; it also answers `currentGravity()` for the take (it replaces the screen's own
/// `CMMotionManager`, so the app keeps a single motion stream per screen).
final class CalibrationSensors {
    static let motionHz = 30.0

    private let motion = CMMotionManager()

    /// Called on the main queue for every device-motion update while running.
    var onMotion: ((CalibrationMotionSample) -> Void)?

    var isRunning: Bool { motion.isDeviceMotionActive }

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

    /// Latest gravity (g, device frame), or upright portrait when motion is unavailable (the app's old default).
    func currentGravity() -> [Double] {
        guard let g = motion.deviceMotion?.gravity else { return [0.0, -1.0, 0.0] }
        return [g.x, g.y, g.z]
    }

    static func sample(_ dm: CMDeviceMotion) -> CalibrationMotionSample {
        CalibrationMotionSample(
            timestamp: dm.timestamp,
            gravity: CalibrationVector3(x: dm.gravity.x, y: dm.gravity.y, z: dm.gravity.z),
            userAcceleration: CalibrationVector3(x: dm.userAcceleration.x, y: dm.userAcceleration.y,
                                                 z: dm.userAcceleration.z),
            rotationRate: CalibrationVector3(x: dm.rotationRate.x, y: dm.rotationRate.y, z: dm.rotationRate.z)
        )
    }

    // MARK: - Light (call on the camera analysis queue)

    /// Torso box (normalised raw image coordinates) spanning both shoulders and hips, or nil without a person.
    static func torsoRect(_ landmarks: [CalibrationLandmark], minVisibility: Double = 0.5) -> CGRect? {
        let idx = ["leftShoulder", "rightShoulder", "leftHip", "rightHip"].compactMap { CanonicalSkeleton.mediapipeIndex[$0] }
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
}
