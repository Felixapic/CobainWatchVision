// WatchTypes.swift
// watchDetect Watch App — Milestone W-LITE Stage 1
//
// Shared types and protocol definitions for the watchOS app target.

import Foundation
import Combine
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WristSide
// ─────────────────────────────────────────────────────────────────────────────

enum WristSide: String, Codable, CaseIterable {
    case left
    case right
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WatchFeatureSample
// ─────────────────────────────────────────────────────────────────────────────

struct WatchFeatureSample: Codable, Identifiable {
    var id: TimeInterval { watchTimestamp }
    let watchTimestamp: TimeInterval
    let sequenceNumber: Int
    let forearmPitch: Double
    let motionMagnitude: Double
    let heartRate: Double?
    let wristSide: WristSide
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WatchTransportEvent
// ─────────────────────────────────────────────────────────────────────────────

enum WatchTransportEvent {
    case sample(WatchFeatureSample)
    case armRaiseDetected(timestamp: TimeInterval, pitch: Double)
    case armRaiseEnded(timestamp: TimeInterval, pitch: Double)
    case wristShakeDiagnostic(timestamp: TimeInterval, magnitude: Double)
    case heartRateUpdated(bpm: Double)
    case calibrationUpdated(wristSide: WristSide, armDownPitch: Double, armUpPitch: Double)
    case ping(timestamp: TimeInterval)
    case pong(origTimestamp: TimeInterval, watchTimestamp: TimeInterval)
    case reachabilityChanged(Bool)
    case disconnected
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WatchTransport Protocol
// ─────────────────────────────────────────────────────────────────────────────

protocol WatchTransport: AnyObject {
    var events: AsyncStream<WatchTransportEvent> { get }
    var isReachable: Bool { get }
    var disconnectCount: Int { get }
    var droppedMessageCount: Int { get }
    var medianLatencyMs: Double { get }
    var p95LatencyMs: Double { get }
    var clockOffsetSeconds: Double { get }
    func activate() async throws
    func send(_ message: [String: Any]) async throws
    func sendPing()
}
