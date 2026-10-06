// NormalizationTests.swift
// CobainVisionTests
//
// Unit tests for torso-length normalisation and PoseFrame helper methods.

import XCTest
import Vision
@testable import CobainVision

final class NormalizationTests: XCTestCase {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - torsoLength
    // ─────────────────────────────────────────────────────────────────────────

    func testTorsoLengthComputedCorrectly() {
        // Shoulders at y=0.8, hips at y=0.5 → expected torso = 0.3
        let frame = PoseFrame.makeTest(joints: [
            .leftShoulder:  (x: 0.4, y: 0.8, confidence: 0.9),
            .rightShoulder: (x: 0.6, y: 0.8, confidence: 0.9),
            .leftHip:       (x: 0.4, y: 0.5, confidence: 0.9),
            .rightHip:      (x: 0.6, y: 0.5, confidence: 0.9),
        ])
        XCTAssertNotNil(frame.torsoLength)
        XCTAssertEqual(frame.torsoLength!, 0.3, accuracy: 0.001)
    }

    func testTorsoLengthAveragesShoulderYAndHipY() {
        // Asymmetric shoulders: L=0.82, R=0.78 → midY=0.80. Hips: L=0.52, R=0.48 → midY=0.50
        let frame = PoseFrame.makeTest(joints: [
            .leftShoulder:  (x: 0.4, y: 0.82, confidence: 0.9),
            .rightShoulder: (x: 0.6, y: 0.78, confidence: 0.9),
            .leftHip:       (x: 0.4, y: 0.52, confidence: 0.9),
            .rightHip:      (x: 0.6, y: 0.48, confidence: 0.9),
        ])
        // |shoulderMidY - hipMidY| = |0.80 - 0.50| = 0.30
        XCTAssertEqual(frame.torsoLength!, 0.30, accuracy: 0.001)
    }

    func testTorsoLengthNilWhenShoulderLowConfidence() {
        let frame = PoseFrame.makeTest(joints: [
            .leftShoulder:  (x: 0.4, y: 0.8, confidence: 0.1),  // below threshold
            .rightShoulder: (x: 0.6, y: 0.8, confidence: 0.9),
            .leftHip:       (x: 0.4, y: 0.5, confidence: 0.9),
            .rightHip:      (x: 0.6, y: 0.5, confidence: 0.9),
        ])
        XCTAssertNil(frame.torsoLength, "Low-confidence shoulder must make torsoLength nil")
    }

    func testTorsoLengthNilWhenHipZeroConfidence() {
        let frame = PoseFrame.makeTest(joints: [
            .leftShoulder:  (x: 0.4, y: 0.8, confidence: 0.9),
            .rightShoulder: (x: 0.6, y: 0.8, confidence: 0.9),
            .leftHip:       (x: 0.4, y: 0.5, confidence: 0.0),  // Vision: not detected
            .rightHip:      (x: 0.6, y: 0.5, confidence: 0.9),
        ])
        XCTAssertNil(frame.torsoLength, "Zero-confidence hip must make torsoLength nil")
    }

    func testTorsoLengthNilWhenTooShort() {
        // Person very far away: shoulder y=0.52, hip y=0.50 → length = 0.02 < minTorsoLength
        let frame = PoseFrame.makeTest(joints: [
            .leftShoulder:  (x: 0.4, y: 0.52, confidence: 0.9),
            .rightShoulder: (x: 0.6, y: 0.52, confidence: 0.9),
            .leftHip:       (x: 0.4, y: 0.50, confidence: 0.9),
            .rightHip:      (x: 0.6, y: 0.50, confidence: 0.9),
        ])
        XCTAssertNil(frame.torsoLength, "Torso shorter than minTorsoLength must return nil")
    }

    func testTorsoLengthAtExactMinimum() {
        // Exactly at minTorsoLength (0.05) — boundary case: should be non-nil (>= check)
        let halfMin = AppConfig.minTorsoLength / 2.0
        let frame = PoseFrame.makeTest(joints: [
            .leftShoulder:  (x: 0.4, y: 0.5 + halfMin, confidence: 0.9),
            .rightShoulder: (x: 0.6, y: 0.5 + halfMin, confidence: 0.9),
            .leftHip:       (x: 0.4, y: 0.5 - halfMin, confidence: 0.9),
            .rightHip:      (x: 0.6, y: 0.5 - halfMin, confidence: 0.9),
        ])
        XCTAssertNotNil(frame.torsoLength)
        XCTAssertEqual(frame.torsoLength!, AppConfig.minTorsoLength, accuracy: 0.0001)
    }

    func testTorsoLengthBelowMinimum() {
        let belowMin = AppConfig.minTorsoLength * 0.4
        let frame = PoseFrame.makeTest(joints: [
            .leftShoulder:  (x: 0.4, y: 0.5 + belowMin / 2.0, confidence: 0.9),
            .rightShoulder: (x: 0.6, y: 0.5 + belowMin / 2.0, confidence: 0.9),
            .leftHip:       (x: 0.4, y: 0.5 - belowMin / 2.0, confidence: 0.9),
            .rightHip:      (x: 0.6, y: 0.5 - belowMin / 2.0, confidence: 0.9),
        ])
        XCTAssertNil(frame.torsoLength, "Torso below minimum must return nil")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - reliableJoint
    // ─────────────────────────────────────────────────────────────────────────

    func testReliableJointReturnsAboveThreshold() {
        let frame = PoseFrame.makeTest(joints: [
            .leftWrist: (x: 0.3, y: 0.8, confidence: AppConfig.minJointConfidence),
        ])
        XCTAssertNotNil(frame.reliableJoint(.leftWrist))
    }

    func testReliableJointReturnsNilBelowThreshold() {
        let frame = PoseFrame.makeTest(joints: [
            .leftWrist: (x: 0.3, y: 0.8, confidence: AppConfig.minJointConfidence - 0.01),
        ])
        XCTAssertNil(frame.reliableJoint(.leftWrist))
    }

    func testReliableJointReturnsNilForZeroConfidence() {
        let frame = PoseFrame.makeTest(joints: [
            .leftKnee: (x: 0.3, y: 0.3, confidence: 0.0),
        ])
        XCTAssertNil(frame.reliableJoint(.leftKnee),
                     "Vision confidence-0 joint must always be treated as absent")
    }

    func testReliableJointReturnsNilForMissingJoint() {
        let frame = PoseFrame.makeTest(joints: [:])
        XCTAssertNil(frame.reliableJoint(.leftKnee))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - missingJoints
    // ─────────────────────────────────────────────────────────────────────────

    func testMissingJointsEmpty() {
        let frame = PoseFrame.makeTest(joints: [
            .neck:          (x: 0.5, y: 0.8, confidence: 0.9),
            .leftShoulder:  (x: 0.4, y: 0.75, confidence: 0.9),
            .rightShoulder: (x: 0.6, y: 0.75, confidence: 0.9),
            .leftHip:       (x: 0.4, y: 0.50, confidence: 0.9),
            .rightHip:      (x: 0.6, y: 0.50, confidence: 0.9),
        ])
        let missing = frame.missingJoints(from: AppConfig.framingUpperBodyJoints)
        XCTAssertTrue(missing.isEmpty, "All upper-body joints present and reliable → no missing")
    }

    func testMissingJointsReturnsMissing() {
        let frame = PoseFrame.makeTest(joints: [
            .neck:          (x: 0.5, y: 0.8, confidence: 0.9),
            .leftShoulder:  (x: 0.4, y: 0.75, confidence: 0.9),
            .rightShoulder: (x: 0.6, y: 0.75, confidence: 0.9),
            // hips absent
        ])
        let missing = frame.missingJoints(from: AppConfig.framingUpperBodyJoints)
        XCTAssertTrue(missing.contains(.leftHip))
        XCTAssertTrue(missing.contains(.rightHip))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - monitoredJointConfidences
    // ─────────────────────────────────────────────────────────────────────────

    func testMonitoredJointConfidencesAllPresent() {
        let frame = PoseFrame.makeTest(joints: [
            .leftKnee:   (x: 0.4, y: 0.3, confidence: 0.8),
            .rightKnee:  (x: 0.6, y: 0.3, confidence: 0.7),
            .leftAnkle:  (x: 0.4, y: 0.1, confidence: 0.5),
            .rightAnkle: (x: 0.6, y: 0.1, confidence: 0.4),
            .leftHip:    (x: 0.4, y: 0.5, confidence: 0.9),
            .rightHip:   (x: 0.6, y: 0.5, confidence: 0.9),
        ])
        let confs = frame.monitoredJointConfidences()
        XCTAssertEqual(confs[.leftKnee]!,  0.8, accuracy: 0.001)
        XCTAssertEqual(confs[.rightKnee]!, 0.7, accuracy: 0.001)
        XCTAssertEqual(confs[.leftAnkle]!, 0.5, accuracy: 0.001)
    }

    func testMonitoredJointConfidencesZeroForAbsent() {
        let frame = PoseFrame.makeTest(joints: [:])
        let confs = frame.monitoredJointConfidences()
        for name in AppConfig.monitoredJoints {
            XCTAssertEqual(confs[name], 0.0, "Absent joint should report confidence 0")
        }
    }
}
