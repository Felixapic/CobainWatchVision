// GestureEvent.swift
// MovementPrompt PoC

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GestureType
// ─────────────────────────────────────────────────────────────────────────────

/// All detectable gestures.
/// Names are from the PERSON'S perspective, not the camera's.
/// See GestureDefinitions.swift for the Vision ↔ person mapping.
enum GestureType: String, CaseIterable, Codable, Hashable {
    case rightArmRaise   // person's right arm
    case leftArmRaise    // person's left arm
    case bothArmLateral  // both arms raised laterally / overhead simultaneously
    case rightHighKnee   // person's right knee raised
    case leftHighKnee    // person's left knee raised
    case squat

    var displayName: String {
        switch self {
        case .rightArmRaise:  return "R Arm Raise"
        case .leftArmRaise:   return "L Arm Raise"
        case .bothArmLateral: return "Both Arms"
        case .rightHighKnee:  return "R High Knee"
        case .leftHighKnee:   return "L High Knee"
        case .squat:          return "Squat"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GesturePhase
// ─────────────────────────────────────────────────────────────────────────────

/// Public phase exposed to the UI. Mirrors the internal state machine without
/// exposing frame counts.
enum GesturePhase: Equatable {
    case idle
    case entering(progress: Double) // 0.0 ... 1.0
    case active
    case exiting
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GestureEvent
// ─────────────────────────────────────────────────────────────────────────────

/// Emitted by GestureEngine when a gesture is detected or ends.
/// The `source` field has slots for camera, watch, and fusion from day one.
struct GestureEvent: Identifiable, Codable {

    // MARK: Nested types

    enum Kind: String, Codable {
        case detected // gesture entered the active state
        case ended    // gesture left the active state
    }

    enum Source: String, Codable {
        case camera  // M1
        case watch   // M3
        case fusion  // M3
    }

    // MARK: Properties

    let id: UUID
    let gestureType: GestureType
    let kind: Kind
    /// CACurrentMediaTime() at the moment the event fired.
    let timestamp: TimeInterval
    let source: Source
    /// Shoulder-to-hip torso length at time of event; nil if unmeasurable.
    let torsoLength: Double?
    /// How many consecutive frames it took to cross the hysteresis threshold.
    let framesToDetect: Int

    // MARK: Init

    init(
        gestureType: GestureType,
        kind: Kind,
        timestamp: TimeInterval,
        source: Source,
        torsoLength: Double?,
        framesToDetect: Int
    ) {
        self.id            = UUID()
        self.gestureType   = gestureType
        self.kind          = kind
        self.timestamp     = timestamp
        self.source        = source
        self.torsoLength   = torsoLength
        self.framesToDetect = framesToDetect
    }
}
