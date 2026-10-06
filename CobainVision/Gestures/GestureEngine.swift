// GestureEngine.swift
// MovementPrompt PoC
//
// Rule-based state machine that processes PoseFrames and emits GestureEvents.
// One GestureStateMachine instance runs per GestureType.

import Vision
import Observation
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GestureStateMachine (internal)
// ─────────────────────────────────────────────────────────────────────────────

/// Per-gesture hysteresis state machine.
/// Thread-safety: must be called from a single thread (the MainActor via GestureEngine).
final class GestureStateMachine {

    // ── Internal phase ──────────────────────────────────────────────────────

    private enum InternalPhase {
        case idle
        case entering(count: Int)   // count: frames seen so far
        case active
        case exiting(count: Int)    // count: frames below threshold so far
    }

    // ── Properties ──────────────────────────────────────────────────────────

    let definition: GestureDefinition
    private var phase: InternalPhase = .idle
    private var totalFrames: Int = 0

    // ── Public phase (for UI) ────────────────────────────────────────────────

    var gesturePhase: GesturePhase {
        switch phase {
        case .idle:                  return .idle
        case .entering(let count):   return .entering(progress: Double(count) / Double(definition.enterFrames))
        case .active:                return .active
        case .exiting:               return .exiting
        }
    }

    // ── Init ─────────────────────────────────────────────────────────────────

    init(definition: GestureDefinition) {
        self.definition = definition
    }

    // ── Core transition ──────────────────────────────────────────────────────

    /// Feed one frame through the state machine.
    /// Returns a `GestureEvent` when a .detected or .ended transition occurs;
    /// returns nil otherwise.
    func process(_ frame: PoseFrame) -> GestureEvent? {
        totalFrames += 1

        // Require torso length for normalisation.
        guard let torso = frame.torsoLength else {
            // If torso is unmeasurable, treat rule as false to avoid spurious detects.
            return handleRuleResult(false, frame: frame, torso: 0)
        }

        // Check that all required joints are reliable.
        let allReliable = definition.requiredJoints.allSatisfy { name in
            (frame.joints[name]?.confidence ?? 0) >= AppConfig.minJointConfidence
        }
        guard allReliable else {
            return handleRuleResult(false, frame: frame, torso: torso)
        }

        let ruleResult = definition.rule(frame, torso)
        return handleRuleResult(ruleResult, frame: frame, torso: torso)
    }

    // ── Private helpers ──────────────────────────────────────────────────────

    private func handleRuleResult(_ result: Bool, frame: PoseFrame, torso: Double) -> GestureEvent? {
        switch phase {
        case .idle:
            if result {
                if definition.enterFrames <= 1 {
                    phase = .active
                    return makeEvent(frame, kind: .detected, frames: 1)
                }
                phase = .entering(count: 1)
            }
            return nil

        case .entering(let count):
            if result {
                let newCount = count + 1
                if newCount >= definition.enterFrames {
                    phase = .active
                    return makeEvent(frame, kind: .detected, frames: newCount)
                }
                phase = .entering(count: newCount)
            } else {
                // Any break resets the entering count.
                phase = .idle
            }
            return nil

        case .active:
            if !result {
                if definition.exitFrames <= 1 {
                    phase = .idle
                    return makeEvent(frame, kind: .ended, frames: 0)
                }
                phase = .exiting(count: 1)
            }
            return nil

        case .exiting(let count):
            if !result {
                let newCount = count + 1
                if newCount >= definition.exitFrames {
                    phase = .idle
                    return makeEvent(frame, kind: .ended, frames: 0)
                }
                phase = .exiting(count: newCount)
            } else {
                // Rule is true again — return to active.
                phase = .active
            }
            return nil
        }
    }

    private func makeEvent(_ frame: PoseFrame, kind: GestureEvent.Kind, frames: Int) -> GestureEvent {
        GestureEvent(
            gestureType: definition.type,
            kind: kind,
            timestamp: frame.timestamp,
            source: .camera,
            torsoLength: frame.torsoLength,
            framesToDetect: frames
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GestureEngine
// ─────────────────────────────────────────────────────────────────────────────

/// Drives all gesture state machines, performs the framing check, and
/// publishes observable state for the SwiftUI layer.
///
/// Must be used on the MainActor (all @Published mutations happen here).
@MainActor
final class GestureEngine: ObservableObject {

    // ── Published state ──────────────────────────────────────────────────────

    @Published private(set) var gesturePhases: [GestureType: GesturePhase] = {
        Dictionary(uniqueKeysWithValues: GestureType.allCases.map { ($0, .idle) })
    }()

    /// Joints that are currently below the minimum confidence threshold.
    /// Updated every frame; used to drive the framing indicator.
    @Published private(set) var framingIssues: [VNHumanBodyPoseObservation.JointName] = []

    /// All events fired in the current session, in order.
    @Published private(set) var sessionEvents: [GestureEvent] = []

    // ── Private ──────────────────────────────────────────────────────────────

    private var machines: [GestureType: GestureStateMachine]

    // ── Init ─────────────────────────────────────────────────────────────────

    init() {
        machines = Dictionary(
            uniqueKeysWithValues: GestureDefinitions.all.map { def in
                (def.type, GestureStateMachine(definition: def))
            }
        )
    }

    // ── API ───────────────────────────────────────────────────────────────────

    /// Process one PoseFrame through all gesture machines.
    /// Returns any events that fired this frame.
    @discardableResult
    func process(_ frame: PoseFrame) -> [GestureEvent] {
        // Update framing check (upper body required for all gestures).
        framingIssues = frame.missingJoints(from: AppConfig.framingUpperBodyJoints)

        var events: [GestureEvent] = []

        for type in GestureType.allCases {
            guard let machine = machines[type] else { continue }
            if let event = machine.process(frame) {
                events.append(event)
                sessionEvents.append(event)
            }
            gesturePhases[type] = machine.gesturePhase
        }

        return events
    }

    /// Reset all state machines to idle (e.g. between runs).
    func reset() {
        machines = Dictionary(
            uniqueKeysWithValues: GestureDefinitions.all.map { def in
                (def.type, GestureStateMachine(definition: def))
            }
        )
        gesturePhases = Dictionary(
            uniqueKeysWithValues: GestureType.allCases.map { ($0, .idle) }
        )
        framingIssues = []
        sessionEvents = []
    }
}
