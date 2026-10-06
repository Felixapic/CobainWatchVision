// WatchMotionDetector.swift
// watchDetect Watch App — Milestone W-LITE Stage 1
//
// Device motion processing at 50 Hz using CMMotionManager.
// Features:
// • Forearm pitch relative to gravity vector.
// • Motion magnitude (user acceleration RMS).
// • 15 Hz feature streaming to iPhone over WatchConnectivity.
// • Arm raise detector (pitch threshold relative to calibration).
// • Wrist shake detector (DIAGNOSTIC ONLY — logged & displayed, does NOT veto arm raise).
// • 2-step calibration: Arm-Down baseline & Arm-Up target.
// • Haptic feedback toggle (default OFF per Amendment 1).

import Foundation
import CoreMotion
import Combine
#if canImport(WatchKit)
import WatchKit
#endif

enum CalibrationState: String, Codable {
    case uncalibrated
    case calibratingArmDown
    case calibratingArmUp
    case calibrated
}

final class WatchMotionDetector: ObservableObject {

    // ── Public State ─────────────────────────────────────────────────────────

    @Published var wristSide: WristSide = .right
    @Published private(set) var calibrationState: CalibrationState = .uncalibrated
    @Published private(set) var currentPitch: Double = 0.0
    @Published private(set) var motionMagnitude: Double = 0.0
    @Published private(set) var isArmRaised: Bool = false
    @Published private(set) var isWristShaking: Bool = false
    @Published var hapticsEnabled: Bool = false

    @Published private(set) var armDownPitch: Double = -1.2  // default baseline (rad)
    @Published private(set) var armUpPitch: Double = 1.2     // default target (rad)

    // ── Private ──────────────────────────────────────────────────────────────

    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private var transport: WatchTransport?
    private var cancellables = Set<AnyCancellable>()

    private var sequenceNumber: Int = 0
    private var sampleCounter: Int = 0
    private var heartRate: Double?

    init() {
        motionQueue.name = "com.poc.watchdetect.motion"
        motionQueue.qualityOfService = .userInteractive
    }

    func setup(transport: WatchTransport) {
        self.transport = transport
        subscribeToTransportEvents()
    }

    func updateHeartRate(_ hr: Double?) {
        self.heartRate = hr
    }

    // ── Motion Updates (50 Hz) ────────────────────────────────────────────────

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0

        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion else { return }
            self.processMotionFrame(motion)
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }

    private func processMotionFrame(_ motion: CMDeviceMotion) {
        let gravity = motion.gravity
        let accel = motion.userAcceleration

        // Forearm pitch relative to gravity (rad)
        let pitch = atan2(-gravity.z, sqrt(gravity.x * gravity.x + gravity.y * gravity.y))
        // User acceleration magnitude (g)
        let magnitude = sqrt(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z)

        DispatchQueue.main.async {
            self.currentPitch = pitch
            self.motionMagnitude = magnitude
        }

        // Arm raise threshold: midpoint between calibrated arm-down and arm-up
        let threshold = (armDownPitch + armUpPitch) / 2.0
        let newArmRaised = pitch > threshold

        if newArmRaised != isArmRaised {
            DispatchQueue.main.async { self.isArmRaised = newArmRaised }
            let now = Date().timeIntervalSince1970
            let payload: [String: Any] = [
                "type": newArmRaised ? "armRaiseDetected" : "armRaiseEnded",
                "ts": now,
                "pitch": pitch
            ]
            Task { try? await transport?.send(payload) }

            if newArmRaised && hapticsEnabled {
                triggerHapticCue()
            }
        }

        // Wrist Shake (DIAGNOSTIC ONLY per Amendment 3): high motion magnitude while arm is down
        let newWristShaking = magnitude > 0.8 && pitch < threshold
        if newWristShaking != isWristShaking {
            DispatchQueue.main.async { self.isWristShaking = newWristShaking }
            if newWristShaking {
                let now = Date().timeIntervalSince1970
                let payload: [String: Any] = [
                    "type": "wristShake",
                    "ts": now,
                    "mag": magnitude
                ]
                Task { try? await transport?.send(payload) }
            }
        }

        // 15 Hz Feature Streaming (decimate 50 Hz by factor of ~3)
        sampleCounter += 1
        if sampleCounter % 3 == 0 {
            sequenceNumber += 1
            let now = Date().timeIntervalSince1970
            let featurePayload: [String: Any] = [
                "type": "feature",
                "ts": now,
                "seq": sequenceNumber,
                "pitch": pitch,
                "mag": magnitude,
                "side": wristSide.rawValue,
                "hr": heartRate as Any
            ]
            Task { try? await transport?.send(featurePayload) }
        }
    }

    // ── Calibration Flow ──────────────────────────────────────────────────────

    func calibrateArmDown() {
        armDownPitch = currentPitch
        if armUpPitch <= armDownPitch {
            armUpPitch = armDownPitch + 1.5
        }
        calibrationState = .calibrated
        sendCalibrationUpdate()
    }

    func calibrateArmUp() {
        armUpPitch = currentPitch
        calibrationState = .calibrated
        sendCalibrationUpdate()
    }

    private func sendCalibrationUpdate() {
        let payload: [String: Any] = [
            "type": "calibration",
            "side": wristSide.rawValue,
            "down": armDownPitch,
            "up": armUpPitch
        ]
        Task { try? await transport?.send(payload) }
    }

    // ── Haptic Cue ────────────────────────────────────────────────────────────

    func triggerHapticCue() {
        guard hapticsEnabled else { return }
        #if canImport(WatchKit)
        WKInterfaceDevice.current().play(.notification)
        #endif
    }

    // ── Transport Subscriptions ───────────────────────────────────────────────

    private func subscribeToTransportEvents() {
        guard let transport = transport else { return }
        Task {
            for await event in transport.events {
                switch event {
                case .ping(let ts):
                    let pongPayload: [String: Any] = [
                        "type": "pong",
                        "origTs": ts,
                        "watchTs": Date().timeIntervalSince1970
                    ]
                    try? await transport.send(pongPayload)

                case .reachabilityChanged(let reachable):
                    if reachable {
                        sendCalibrationUpdate()
                    }

                default:
                    break
                }
            }
        }
    }
}
