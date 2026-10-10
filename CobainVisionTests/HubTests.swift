// HubTests.swift
// MovementPrompt PoC — Milestone H-A Stage A1 Unit Tests
//
// Tests for:
// 1. Payload encode/decode round-trip (JSON Codable)
// 2. Sequence gap counting logic
// 3. Synthetic gravity vector thigh angle calculations (baseline, raised leg, rotation invariance)

import XCTest

final class HubTests: XCTestCase {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - 1. Payload Encode / Decode Round Trip
    // ─────────────────────────────────────────────────────────────────────────

    func testPayloadEncodeDecodeRoundTrip() throws {
        let thighSample = ThighFeatureSample(
            timestamp: 1700000000.0,
            sequenceNumber: 42,
            thighAngleDegrees: 45.5,
            motionMagnitude: 0.12,
            gravityX: 0.0,
            gravityY: -0.707,
            gravityZ: -0.707,
            rotationRateX: 0.01,
            rotationRateY: 0.02,
            rotationRateZ: 0.03,
            isCalibrated: true
        )

        let sampleData = try JSONEncoder().encode(thighSample)
        let sampleJSONStr = String(data: sampleData, encoding: .utf8)!

        let transportMsg = HubTransportMessage(
            type: .thighSample,
            sourceId: "iphone_hub",
            sequenceNumber: 101,
            timestamp: 1700000000.0,
            payloadJSON: sampleJSONStr
        )

        let msgData = try JSONEncoder().encode(transportMsg)
        let decodedMsg = try JSONDecoder().decode(HubTransportMessage.self, from: msgData)

        XCTAssertEqual(decodedMsg.type, .thighSample)
        XCTAssertEqual(decodedMsg.sourceId, "iphone_hub")
        XCTAssertEqual(decodedMsg.sequenceNumber, 101)

        guard let payloadStr = decodedMsg.payloadJSON,
              let payloadData = payloadStr.data(using: .utf8) else {
            XCTFail("Missing payloadJSON")
            return
        }

        let decodedThighSample = try JSONDecoder().decode(ThighFeatureSample.self, from: payloadData)
        XCTAssertEqual(decodedThighSample.sequenceNumber, 42)
        XCTAssertEqual(decodedThighSample.thighAngleDegrees, 45.5, accuracy: 0.001)
        XCTAssertTrue(decodedThighSample.isCalibrated)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - 2. Sequence Gap Counting
    // ─────────────────────────────────────────────────────────────────────────

    func testSequenceGapCounting() {
        var lastSequenceNumber = -1
        var droppedCount = 0

        let incomingSequences = [1, 2, 3, 6, 7, 10] // Missing: 4, 5 (2 msgs) and 8, 9 (2 msgs) -> total 4 dropped

        for seq in incomingSequences {
            if lastSequenceNumber >= 0 && seq > lastSequenceNumber + 1 {
                let missing = seq - (lastSequenceNumber + 1)
                droppedCount += missing
            }
            lastSequenceNumber = seq
        }

        XCTAssertEqual(droppedCount, 4)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - 3. Synthetic Gravity Vector Thigh Angle Math
    // ─────────────────────────────────────────────────────────────────────────

    func testThighAngleBaselineStanding() {
        // Phone vertical in pocket: gravity along -Y (0, -1, 0)
        let standingG = (x: 0.0, y: -1.0, z: 0.0)
        let currentG  = (x: 0.0, y: -1.0, z: 0.0)

        let angle = ThighMotionDetector.calculateAngleBetweenGravityVectors(g1: currentG, g2: standingG)
        XCTAssertEqual(angle, 0.0, accuracy: 0.1)
    }

    func testThighAngleRaisedLeg90Degrees() {
        // Standing: gravity along -Y (0, -1, 0)
        // 90 deg leg raise forward: gravity moves to -Z (0, 0, -1)
        let standingG = (x: 0.0, y: -1.0, z: 0.0)
        let raisedG   = (x: 0.0, y: 0.0, z: -1.0)

        let angle = ThighMotionDetector.calculateAngleBetweenGravityVectors(g1: raisedG, g2: standingG)
        XCTAssertEqual(angle, 90.0, accuracy: 0.1)
    }

    func testThighAngleRotationInvariance() {
        // Test mounting phone in two completely different physical orientations:
        // Orientation A: Phone upright in pocket
        let standingA = (x: 0.0, y: -1.0, z: 0.0)
        let raisedA   = (x: 0.0, y: -0.707, z: -0.707) // 45 degree leg raise

        // Orientation B: Phone mounted sideways (rotated 90 deg around Z)
        let standingB = (x: 1.0, y: 0.0, z: 0.0)
        let raisedB   = (x: 0.707, y: 0.0, z: -0.707)  // Same 45 degree leg raise physically

        let angleA = ThighMotionDetector.calculateAngleBetweenGravityVectors(g1: raisedA, g2: standingA)
        let angleB = ThighMotionDetector.calculateAngleBetweenGravityVectors(g1: raisedB, g2: standingB)

        XCTAssertEqual(angleA, 45.0, accuracy: 0.5)
        XCTAssertEqual(angleB, 45.0, accuracy: 0.5)
        XCTAssertEqual(angleA, angleB, accuracy: 0.001, "Thigh angle calculation must be rotationally invariant!")
    }
}
