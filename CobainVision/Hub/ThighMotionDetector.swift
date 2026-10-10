// ThighMotionDetector.swift
// MovementPrompt PoC — Milestone H-A Stage A1
//
// CoreMotion 50 Hz device motion reader for iPhone thigh hub mode.
// Computes an orientation-agnostic thigh angle derived from standing baseline gravity.
// Includes 2-step calibration ("Calibrate Standing", "Calibrate Leg Raised").

import Foundation
import Combine
#if canImport(CoreMotion)
import CoreMotion
#endif

public enum ThighCalibrationState: String {
    case uncalibrated = "Uncalibrated"
    case standingCalibrated = "Standing Calibrated"
    case fullyCalibrated = "Fully Calibrated ✓"
}

public final class ThighMotionDetector: ObservableObject {

    @Published public private(set) var currentThighAngleDegrees: Double = 0
    @Published public private(set) var currentMotionMagnitude: Double = 0
    @Published public private(set) var calibrationState: ThighCalibrationState = .uncalibrated
    @Published public private(set) var standingGravity: (x: Double, y: Double, z: Double)? = nil
    @Published public private(set) var raisedGravity: (x: Double, y: Double, z: Double)? = nil

    public var onSampleEmitted: ((ThighFeatureSample) -> Void)?

    #if canImport(CoreMotion)
    private let motionManager = CMMotionManager()
    #endif

    private var sequenceNumber: Int = 0
    private var lastEmittedTimestamp: TimeInterval = 0
    private let sampleEmitInterval: TimeInterval = 1.0 / 20.0 // 20 Hz output stream

    public init() {}

    public func start() {
        #if canImport(CoreMotion)
        guard motionManager.isDeviceMotionAvailable else {
            print("[ThighMotionDetector] CoreMotion device motion unavailable")
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0 // 50 Hz sampling
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self = self, let motion = motion else { return }
            self.processMotionData(motion)
        }
        #endif
    }

    public func stop() {
        #if canImport(CoreMotion)
        motionManager.stopDeviceMotionUpdates()
        #endif
    }

    // ── Calibration ─────────────────────────────────────────────────────────

    public func calibrateStanding() {
        #if canImport(CoreMotion)
        if let g = motionManager.deviceMotion?.gravity {
            self.standingGravity = (g.x, g.y, g.z)
            self.calibrationState = .standingCalibrated
            print("[ThighMotionDetector] Calibrated Standing: g=(\(g.x), \(g.y), \(g.z))")
        }
        #endif
    }

    public func calibrateLegRaised() {
        #if canImport(CoreMotion)
        if let g = motionManager.deviceMotion?.gravity {
            self.raisedGravity = (g.x, g.y, g.z)
            self.calibrationState = .fullyCalibrated
            print("[ThighMotionDetector] Calibrated Leg Raised: g=(\(g.x), \(g.y), \(g.z))")
        }
        #endif
    }

    // ── Motion Processing & Orientation-Agnostic Calculation ────────────────

    #if canImport(CoreMotion)
    private func processMotionData(_ motion: CMDeviceMotion) {
        let g = motion.gravity
        let u = motion.userAcceleration
        let r = motion.rotationRate

        let mag = sqrt(u.x * u.x + u.y * u.y + u.z * u.z)
        self.currentMotionMagnitude = mag

        // Orientation-agnostic thigh angle calculation
        let angle: Double
        if let baseG = standingGravity {
            angle = ThighMotionDetector.calculateAngleBetweenGravityVectors(
                g1: (g.x, g.y, g.z),
                g2: baseG
            )
        } else {
            angle = 0.0
        }
        self.currentThighAngleDegrees = angle

        // Emit sample at 20 Hz rate
        let now = Date().timeIntervalSince1970
        if now - lastEmittedTimestamp >= sampleEmitInterval {
            lastEmittedTimestamp = now
            sequenceNumber += 1

            let sample = ThighFeatureSample(
                timestamp: now,
                sequenceNumber: sequenceNumber,
                thighAngleDegrees: angle,
                motionMagnitude: mag,
                gravityX: g.x,
                gravityY: g.y,
                gravityZ: g.z,
                rotationRateX: r.x,
                rotationRateY: r.y,
                rotationRateZ: r.z,
                isCalibrated: (calibrationState == .fullyCalibrated)
            )
            onSampleEmitted?(sample)
        }
    }
    #endif

    // ── Static Orientation-Agnostic Vector Math ────────────────────────────

    /// Computes the angle in degrees between two 3D gravity vectors.
    /// Invariant to device orientation around the gravity vector!
    public static func calculateAngleBetweenGravityVectors(
        g1: (x: Double, y: Double, z: Double),
        g2: (x: Double, y: Double, z: Double)
    ) -> Double {
        let dot = g1.x * g2.x + g1.y * g2.y + g1.z * g2.z
        let mag1 = sqrt(g1.x * g1.x + g1.y * g1.y + g1.z * g1.z)
        let mag2 = sqrt(g2.x * g2.x + g2.y * g2.y + g2.z * g2.z)

        guard mag1 > 0.0001, mag2 > 0.0001 else { return 0.0 }
        let cosAngle = max(-1.0, min(1.0, dot / (mag1 * mag2)))
        return acos(cosAngle) * 180.0 / .pi
    }
}
