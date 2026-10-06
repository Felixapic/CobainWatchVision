// GestureEngineTests.swift
// CobainVisionTests
//
// Unit tests for GestureEngine using synthetic PoseFrame data.
// These tests run on the Simulator — no camera needed.
//
// Coordinate reminders:
//   Vision y increases UPWARD.
//   Vision leftXxx = person's RIGHT side (front-camera unmirrored buffer).

import XCTest
import Vision
@testable import CobainVision

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// A standard "standing" pose with reliable upper and lower body joints.
/// Torso: left/rightShoulder at y=0.75, left/rightHip at y=0.50 → torsoLength = 0.25.
/// Knee:  at y=0.28, ankle at y=0.05  (below hip — person is standing).
private let standingJoints: [VNHumanBodyPoseObservation.JointName: (x: Double, y: Double, confidence: Float)] = [
    .neck:          (x: 0.50, y: 0.80, confidence: 0.9),
    .leftShoulder:  (x: 0.40, y: 0.75, confidence: 0.9),   // Vision left = person right
    .rightShoulder: (x: 0.60, y: 0.75, confidence: 0.9),   // Vision right = person left
    .leftElbow:     (x: 0.38, y: 0.65, confidence: 0.9),
    .rightElbow:    (x: 0.62, y: 0.65, confidence: 0.9),
    .leftWrist:     (x: 0.36, y: 0.55, confidence: 0.9),   // arms at sides
    .rightWrist:    (x: 0.64, y: 0.55, confidence: 0.9),
    .leftHip:       (x: 0.43, y: 0.50, confidence: 0.9),
    .rightHip:      (x: 0.57, y: 0.50, confidence: 0.9),
    .leftKnee:      (x: 0.43, y: 0.28, confidence: 0.8),
    .rightKnee:     (x: 0.57, y: 0.28, confidence: 0.8),
    .leftAnkle:     (x: 0.43, y: 0.05, confidence: 0.7),
    .rightAnkle:    (x: 0.57, y: 0.05, confidence: 0.7),
]

// torsoLength = |shoulderMidY - hipMidY| = |0.75 - 0.50| = 0.25

private func makeEngine() -> GestureEngine {
    GestureEngine()
}

/// Feed `n` identical frames into the engine.
@discardableResult
private func feed(
    _ engine: GestureEngine,
    joints: [VNHumanBodyPoseObservation.JointName: (x: Double, y: Double, confidence: Float)],
    count: Int,
    startTimestamp: TimeInterval = 0
) -> [GestureEvent] {
    var allEvents: [GestureEvent] = []
    for i in 0..<count {
        let frame = PoseFrame.makeTest(
            joints: joints,
            timestamp: startTimestamp + Double(i) / 30.0,
            frameIndex: i
        )
        let events = engine.process(frame)
        allEvents.append(contentsOf: events)
    }
    return allEvents
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Right arm raise tests
// ─────────────────────────────────────────────────────────────────────────────

final class RightArmRaiseTests: XCTestCase {

    // Joints for right arm raise (person's right = Vision's left)
    private var raisedJoints: [VNHumanBodyPoseObservation.JointName: (x: Double, y: Double, confidence: Float)] {
        var j = standingJoints
        // Raise Vision-left wrist and elbow above Vision-left shoulder (y=0.75)
        // torsoLength = 0.25, ratio threshold = 0.10 → need > 0.75 + 0.10*0.25 = 0.775
        j[.leftWrist]  = (x: 0.35, y: 0.88, confidence: 0.9)
        j[.leftElbow]  = (x: 0.37, y: 0.80, confidence: 0.9)
        return j
    }

    func testDetectedAfterEnterFrames() async throws {
        let engine = makeEngine()
        let events = feed(engine, joints: raisedJoints, count: AppConfig.hysteresisEnterFrames)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].gestureType, .rightArmRaise)
        XCTAssertEqual(events[0].kind, .detected)
        XCTAssertEqual(events[0].source, .camera)
    }

    func testNotDetectedBeforeEnterFrames() async throws {
        let engine = makeEngine()
        // One frame fewer than required
        let events = feed(engine, joints: raisedJoints, count: AppConfig.hysteresisEnterFrames - 1)
        XCTAssertTrue(events.isEmpty, "Should not fire before enter frame count is reached")
    }

    func testEndsAfterExitFrames() async throws {
        let engine = makeEngine()
        // Trigger detection
        feed(engine, joints: raisedJoints, count: AppConfig.hysteresisEnterFrames)
        // Now feed standing frames (rule is false)
        let events = feed(engine, joints: standingJoints, count: AppConfig.hysteresisExitFrames)
        let ended = events.filter { $0.kind == .ended && $0.gestureType == .rightArmRaise }
        XCTAssertEqual(ended.count, 1)
    }

    func testRejectsLowConfidenceWrist() async throws {
        let engine = makeEngine()
        var j = raisedJoints
        j[.leftWrist] = (x: 0.35, y: 0.88, confidence: 0.1)  // below minJointConfidence
        let events = feed(engine, joints: j, count: AppConfig.hysteresisEnterFrames + 2)
        let detected = events.filter { $0.gestureType == .rightArmRaise && $0.kind == .detected }
        XCTAssertTrue(detected.isEmpty, "Low-confidence wrist should prevent detection")
    }

    func testHysteresisResetOnBreak() async throws {
        let engine = makeEngine()
        // Feed (enterFrames - 1) raised frames, then one standing frame, then (enterFrames) raised
        feed(engine, joints: raisedJoints, count: AppConfig.hysteresisEnterFrames - 1)
        feed(engine, joints: standingJoints, count: 1)
        let events = feed(engine, joints: raisedJoints, count: AppConfig.hysteresisEnterFrames)
        let detected = events.filter { $0.gestureType == .rightArmRaise && $0.kind == .detected }
        // Must require a full new set of enter frames after the break
        XCTAssertEqual(detected.count, 1)
    }

    func testTorsoLengthPresentInEvent() async throws {
        let engine = makeEngine()
        let events = feed(engine, joints: raisedJoints, count: AppConfig.hysteresisEnterFrames)
        XCTAssertNotNil(events.first?.torsoLength)
        // torsoLength for standingJoints variant should be ≈ 0.25
        if let tl = events.first?.torsoLength {
            XCTAssertEqual(tl, 0.25, accuracy: 0.01)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Left arm raise tests
// ─────────────────────────────────────────────────────────────────────────────

final class LeftArmRaiseTests: XCTestCase {

    private var raisedJoints: [VNHumanBodyPoseObservation.JointName: (x: Double, y: Double, confidence: Float)] {
        var j = standingJoints
        // Person's left = Vision's RIGHT joints
        j[.rightWrist] = (x: 0.65, y: 0.88, confidence: 0.9)
        j[.rightElbow] = (x: 0.63, y: 0.80, confidence: 0.9)
        return j
    }

    func testDetected() async throws {
        let engine = makeEngine()
        let events = feed(engine, joints: raisedJoints, count: AppConfig.hysteresisEnterFrames)
        let detected = events.filter { $0.gestureType == .leftArmRaise && $0.kind == .detected }
        XCTAssertEqual(detected.count, 1)
    }

    func testDoesNotFireRightArmRaise() async throws {
        let engine = makeEngine()
        let events = feed(engine, joints: raisedJoints, count: AppConfig.hysteresisEnterFrames)
        let wrongSide = events.filter { $0.gestureType == .rightArmRaise && $0.kind == .detected }
        XCTAssertTrue(wrongSide.isEmpty, "Left-arm raise should not trigger right-arm raise")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Both-arm lateral raise tests
// ─────────────────────────────────────────────────────────────────────────────

final class BothArmLateralTests: XCTestCase {

    private var bothRaisedJoints: [VNHumanBodyPoseObservation.JointName: (x: Double, y: Double, confidence: Float)] {
        var j = standingJoints
        j[.leftWrist]  = (x: 0.35, y: 0.88, confidence: 0.9)
        j[.leftElbow]  = (x: 0.37, y: 0.80, confidence: 0.9)
        j[.rightWrist] = (x: 0.65, y: 0.88, confidence: 0.9)
        j[.rightElbow] = (x: 0.63, y: 0.80, confidence: 0.9)
        return j
    }

    func testBothArmsDetected() async throws {
        let engine = makeEngine()
        let events = feed(engine, joints: bothRaisedJoints, count: AppConfig.hysteresisEnterFrames)
        let detected = events.filter { $0.gestureType == .bothArmLateral && $0.kind == .detected }
        XCTAssertEqual(detected.count, 1)
    }

    func testOnlyOneArmDoesNotTriggerBoth() async throws {
        let engine = makeEngine()
        var j = standingJoints
        // Only raise Vision-left (person's right)
        j[.leftWrist] = (x: 0.35, y: 0.88, confidence: 0.9)
        j[.leftElbow] = (x: 0.37, y: 0.80, confidence: 0.9)
        let events = feed(engine, joints: j, count: AppConfig.hysteresisEnterFrames + 2)
        let detected = events.filter { $0.gestureType == .bothArmLateral && $0.kind == .detected }
        XCTAssertTrue(detected.isEmpty, "One arm raised should not trigger both-arm gesture")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - High knee tests
// ─────────────────────────────────────────────────────────────────────────────

final class HighKneeTests: XCTestCase {

    /// Right high knee: person's right = Vision's LEFT knee/hip.
    private var rightKneeJoints: [VNHumanBodyPoseObservation.JointName: (x: Double, y: Double, confidence: Float)] {
        var j = standingJoints
        // leftHip y=0.50, torso=0.25, threshold=0.10 → knee must be > 0.50 + 0.10*0.25 = 0.525
        j[.leftKnee] = (x: 0.43, y: 0.60, confidence: 0.8)
        return j
    }

    private var leftKneeJoints: [VNHumanBodyPoseObservation.JointName: (x: Double, y: Double, confidence: Float)] {
        var j = standingJoints
        j[.rightKnee] = (x: 0.57, y: 0.60, confidence: 0.8)
        return j
    }

    func testRightHighKneeDetected() async throws {
        let engine = makeEngine()
        let events = feed(engine, joints: rightKneeJoints, count: AppConfig.hysteresisEnterFrames)
        let detected = events.filter { $0.gestureType == .rightHighKnee && $0.kind == .detected }
        XCTAssertEqual(detected.count, 1)
    }

    func testLeftHighKneeDetected() async throws {
        let engine = makeEngine()
        let events = feed(engine, joints: leftKneeJoints, count: AppConfig.hysteresisEnterFrames)
        let detected = events.filter { $0.gestureType == .leftHighKnee && $0.kind == .detected }
        XCTAssertEqual(detected.count, 1)
    }

    func testHighKneeBelowThresholdNotDetected() async throws {
        let engine = makeEngine()
        // Knee barely above hip but not enough (< threshold * torso)
        var j = standingJoints
        j[.leftKnee] = (x: 0.43, y: 0.51, confidence: 0.8) // barely above hip y=0.50, ratio=0.04
        let events = feed(engine, joints: j, count: AppConfig.hysteresisEnterFrames + 2)
        let detected = events.filter { $0.gestureType == .rightHighKnee && $0.kind == .detected }
        XCTAssertTrue(detected.isEmpty)
    }

    func testHighKneeRejectsZeroConfidenceKnee() async throws {
        let engine = makeEngine()
        var j = rightKneeJoints
        j[.leftKnee] = (x: 0.43, y: 0.60, confidence: 0.0) // Vision: not detected
        let events = feed(engine, joints: j, count: AppConfig.hysteresisEnterFrames + 2)
        let detected = events.filter { $0.gestureType == .rightHighKnee && $0.kind == .detected }
        XCTAssertTrue(detected.isEmpty, "Zero-confidence knee must be ignored")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Squat tests
// ─────────────────────────────────────────────────────────────────────────────

final class SquatTests: XCTestCase {

    /// Squat pose: hips move down, hip-to-ankle ratio drops below threshold.
    /// Standing ratio = (hipMidY - ankleMidY) / torso = (0.50 - 0.05) / 0.25 = 1.80
    /// Squat: we lower hips to y=0.30 → ratio = (0.30 - 0.05) / 0.25 = 1.0 < threshold(1.6) ✓
    private var squatJoints: [VNHumanBodyPoseObservation.JointName: (x: Double, y: Double, confidence: Float)] {
        var j = standingJoints
        j[.leftHip]   = (x: 0.43, y: 0.30, confidence: 0.9)
        j[.rightHip]  = (x: 0.57, y: 0.30, confidence: 0.9)
        // Keep ankles and knees in place
        return j
    }

    func testSquatDetected() async throws {
        let engine = makeEngine()
        let events = feed(engine, joints: squatJoints, count: AppConfig.hysteresisEnterFrames)
        let detected = events.filter { $0.gestureType == .squat && $0.kind == .detected }
        XCTAssertEqual(detected.count, 1)
    }

    func testStandingDoesNotTriggerSquat() async throws {
        let engine = makeEngine()
        // Standing ratio = 1.80 > threshold 1.6 → should NOT fire
        let events = feed(engine, joints: standingJoints, count: AppConfig.hysteresisEnterFrames + 5)
        let detected = events.filter { $0.gestureType == .squat && $0.kind == .detected }
        XCTAssertTrue(detected.isEmpty, "Standing pose should not trigger squat")
    }

    func testSquatRequiresReliableAnkles() async throws {
        let engine = makeEngine()
        var j = squatJoints
        // Ankles below confidence threshold — squat should not fire (required joint missing)
        j[.leftAnkle]  = (x: 0.43, y: 0.05, confidence: 0.1)
        j[.rightAnkle] = (x: 0.57, y: 0.05, confidence: 0.1)
        let events = feed(engine, joints: j, count: AppConfig.hysteresisEnterFrames + 2)
        let detected = events.filter { $0.gestureType == .squat && $0.kind == .detected }
        XCTAssertTrue(detected.isEmpty, "Low-confidence ankles must prevent squat detection")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Engine-level tests
// ─────────────────────────────────────────────────────────────────────────────

final class GestureEngineGeneralTests: XCTestCase {

    func testNoEventsForStandingPose() async throws {
        let engine = makeEngine()
        let events = feed(engine, joints: standingJoints, count: 60) // 2 sec at 30 fps
        XCTAssertTrue(events.isEmpty, "60 frames of standing should produce no gesture events")
    }

    func testResetClearsState() async throws {
        let engine = makeEngine()
        var j = standingJoints
        j[.leftWrist] = (x: 0.35, y: 0.88, confidence: 0.9)
        j[.leftElbow] = (x: 0.37, y: 0.80, confidence: 0.9)
        feed(engine, joints: j, count: AppConfig.hysteresisEnterFrames)
        engine.reset()
        XCTAssertTrue(engine.sessionEvents.isEmpty)
        XCTAssertEqual(engine.gesturePhases[.rightArmRaise], .idle)
    }

    func testMissingTorsoSkipsRule() async throws {
        let engine = makeEngine()
        // Remove hip joints so torsoLength == nil
        var j = standingJoints
        j[.leftHip]  = (x: 0.43, y: 0.50, confidence: 0.0)
        j[.rightHip] = (x: 0.57, y: 0.50, confidence: 0.0)
        // Raise arm
        j[.leftWrist] = (x: 0.35, y: 0.88, confidence: 0.9)
        j[.leftElbow] = (x: 0.37, y: 0.80, confidence: 0.9)
        let events = feed(engine, joints: j, count: AppConfig.hysteresisEnterFrames + 2)
        let detected = events.filter { $0.kind == .detected }
        XCTAssertTrue(detected.isEmpty, "No torso → no normalisation → no gesture should fire")
    }
}
