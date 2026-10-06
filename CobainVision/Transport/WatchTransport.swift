// WatchTransport.swift
// MovementPrompt PoC
//
// M1: Protocol stub only. WatchConnectivity implementation is added in M3.
// All types that M3 will need are defined here so the rest of the codebase
// can reference them without touching this file again.

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WatchFeatureSample
// ─────────────────────────────────────────────────────────────────────────────

/// Lightweight feature vector sent by the watch (M3).
/// The watch computes these from raw CMMotionManager data at 50 Hz and sends
/// only features — not raw sensor readings — to reduce bandwidth.
struct WatchFeatureSample: Codable {
    /// Timestamp from the watch clock (seconds since reference date).
    /// A ping-pong clock-offset estimate is applied before fusion.
    let watchTimestamp: TimeInterval
    /// Forearm pitch relative to gravity (radians). Positive = arm raised.
    let forearmPitch: Double
    /// RMS of accelerometer vector magnitude over the last N samples.
    let motionMagnitude: Double
    /// Latest heart rate in BPM; nil if not yet available from HealthKit.
    let heartRate: Double?
    /// Wrist side worn (set during calibration).
    let wristSide: WristSide
}

/// Which wrist the watch is worn on (set in M3 calibration screen).
enum WristSide: String, Codable {
    case left
    case right
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WatchTransportEvent
// ─────────────────────────────────────────────────────────────────────────────

enum WatchTransportEvent {
    case sample(WatchFeatureSample)
    case reachabilityChanged(Bool)
    case disconnected
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WatchTransport protocol
// ─────────────────────────────────────────────────────────────────────────────

/// Abstraction over the phone↔watch communication channel.
/// M1: not instantiated. M3: WatchConnectivityTransport conforms to this.
/// Swap the implementation here; nothing else changes.
protocol WatchTransport: AnyObject {
    /// Stream of events arriving from the watch.
    var events: AsyncStream<WatchTransportEvent> { get }
    /// True when the paired watch is reachable.
    var isReachable: Bool { get }
    /// Activate the session. Call once at app start (M3).
    func activate() async throws
    /// Send a command to the watch (e.g., start/stop workout).
    func send(_ message: [String: Any]) async throws
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - NullWatchTransport (M1 placeholder)
// ─────────────────────────────────────────────────────────────────────────────

/// No-op transport used in M1. Returns an empty stream and never connects.
final class NullWatchTransport: WatchTransport {
    let events: AsyncStream<WatchTransportEvent> = AsyncStream { _ in }
    var isReachable: Bool { false }
    func activate() async throws {}
    func send(_ message: [String: Any]) async throws {}
}
