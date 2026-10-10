// HubPayloads.swift
// MovementPrompt PoC — Milestone H-A Stage A1
//
// Shared payload data structures between iPhone (Hub) and Mac (Dashboard).
// Includes payload types, thigh motion sample, watch feature relay, raw ping-pong timing (t0, t1, t2, t3),
// and hub status events.

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - MessageType
// ─────────────────────────────────────────────────────────────────────────────

public enum HubMessageType: String, Codable {
    case handshake
    case thighSample
    case watchSampleRelay
    case watchEventRelay
    case hubStatus
    case ping
    case pong
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Raw Ping-Pong Sample (t0, t1, t2, t3)
// ─────────────────────────────────────────────────────────────────────────────

/// Logged raw ping-pong timing sample.
/// - t0: Sender timestamp when ping was sent from Mac
/// - t1: Receiver timestamp when ping was received on iPhone
/// - t2: Sender timestamp when pong was sent from iPhone
/// - t3: Receiver timestamp when pong was received on Mac
public struct PingPongSample: Codable, Identifiable {
    public var id: TimeInterval { t0 }
    public let link: String           // e.g. "Mac<->iPhone" or "iPhone<->Watch"
    public let t0: TimeInterval
    public let t1: TimeInterval
    public let t2: TimeInterval
    public let t3: TimeInterval

    /// Round-trip time in milliseconds: (t3 - t0) - (t2 - t1)
    public var rttMs: Double {
        let total = (t3 - t0)
        let processing = (t2 - t1)
        return max(0.0, (total - processing) * 1000.0)
    }

    /// One-way latency estimate (RTT / 2) under symmetric path assumption
    public var oneWayEstimateMs: Double {
        return rttMs / 2.0
    }

    /// Clock offset estimate: ((t1 - t0) + (t2 - t3)) / 2
    public var clockOffsetSeconds: Double {
        return ((t1 - t0) + (t2 - t3)) / 2.0
    }

    public init(link: String, t0: TimeInterval, t1: TimeInterval, t2: TimeInterval, t3: TimeInterval) {
        self.link = link
        self.t0 = t0
        self.t1 = t1
        self.t2 = t2
        self.t3 = t3
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ThighFeatureSample
// ─────────────────────────────────────────────────────────────────────────────

/// Thigh motion sample (20 Hz) from iPhone CoreMotion.
public struct ThighFeatureSample: Codable, Identifiable {
    public var id: TimeInterval { timestamp }
    public let timestamp: TimeInterval
    public let sequenceNumber: Int
    public let thighAngleDegrees: Double     // Angle between current gravity and standing baseline (deg)
    public let motionMagnitude: Double       // User acceleration magnitude (g)
    public let gravityX: Double
    public let gravityY: Double
    public let gravityZ: Double
    public let rotationRateX: Double
    public let rotationRateY: Double
    public let rotationRateZ: Double
    public let isCalibrated: Bool

    public init(
        timestamp: TimeInterval,
        sequenceNumber: Int,
        thighAngleDegrees: Double,
        motionMagnitude: Double,
        gravityX: Double,
        gravityY: Double,
        gravityZ: Double,
        rotationRateX: Double,
        rotationRateY: Double,
        rotationRateZ: Double,
        isCalibrated: Bool
    ) {
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.thighAngleDegrees = thighAngleDegrees
        self.motionMagnitude = motionMagnitude
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.gravityZ = gravityZ
        self.rotationRateX = rotationRateX
        self.rotationRateY = rotationRateY
        self.rotationRateZ = rotationRateZ
        self.isCalibrated = isCalibrated
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - HubStatusMessage
// ─────────────────────────────────────────────────────────────────────────────

public enum HubStatusState: String, Codable {
    case active
    case paused        // Sent when iPhone enters background / becomes inactive
    case locked        // Touch lock enabled
    case unlocked
    case watchConnected
    case watchDisconnected
}

public struct HubStatusMessage: Codable {
    public let timestamp: TimeInterval
    public let state: HubStatusState
    public let note: String?

    public init(timestamp: TimeInterval, state: HubStatusState, note: String? = nil) {
        self.timestamp = timestamp
        self.state = state
        self.note = note
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Main Transport Container Envelope
// ─────────────────────────────────────────────────────────────────────────────

public struct HubTransportMessage: Codable {
    public let type: HubMessageType
    public let sourceId: String           // e.g. "iphone_hub", "mac_dashboard", "watch"
    public let sequenceNumber: Int
    public let timestamp: TimeInterval
    public let payloadJSON: String?       // Sub-payload encoded as JSON string or dict

    public init(type: HubMessageType, sourceId: String, sequenceNumber: Int, timestamp: TimeInterval, payloadJSON: String? = nil) {
        self.type = type
        self.sourceId = sourceId
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.payloadJSON = payloadJSON
    }
}
