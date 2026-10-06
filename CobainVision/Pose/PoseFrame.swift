// PoseFrame.swift
// MovementPrompt PoC

import Vision
import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PoseFrame
// ─────────────────────────────────────────────────────────────────────────────

/// A snapshot of all detected body joints for a single video frame.
///
/// ## Coordinate system
/// All coordinates are in **Vision normalised space**:
/// - Origin (0, 0) = **bottom-left** of the image.
/// - x increases to the **right**.
/// - y increases **upward** (opposite to UIKit/SwiftUI screen coords).
///
/// ## Front-camera mirror mapping
/// `VisionPoseProvider` sets `videoRotationAngle = 90` on the
/// `AVCaptureVideoDataOutput` connection so the pixel buffer arrives in
/// portrait orientation. The buffer is **NOT** mirrored even for the front
/// camera — only the `AVCaptureVideoPreviewLayer` mirrors the preview.
///
/// Therefore:
/// ```
///   Vision .leftXxx  → LEFT side of the portrait image → person's RIGHT side
///   Vision .rightXxx → RIGHT side of the portrait image → person's LEFT side
/// ```
///
/// `GestureDefinitions.swift` accounts for this mapping in every rule.
/// The debug overlay flips x (`screenX = 1 − visionX`) to match the mirrored preview.
struct PoseFrame {

    // MARK: Types

    typealias JointName = VNHumanBodyPoseObservation.JointName

    struct JointPoint {
        /// Normalised Vision coordinate (origin bottom-left).
        let location: CGPoint
        /// Vision confidence in [0, 1].
        /// Joints with confidence == 0 were **not detected** and must be
        /// treated as absent. Do not use them in any gesture rule.
        let confidence: VNConfidence
    }

    // MARK: Properties

    /// `CACurrentMediaTime()` at the time of capture, before Vision runs.
    let timestamp: TimeInterval
    let frameIndex: Int
    let joints: [JointName: JointPoint]
    /// Rolling FPS average at the time this frame was created.
    let fps: Double

    // MARK: Convenience accessors

    func joint(_ name: JointName) -> JointPoint? {
        joints[name]
    }

    /// Returns the joint only when its confidence ≥ `AppConfig.minJointConfidence`.
    /// Confidence-0 joints (not detected by Vision) are always excluded.
    func reliableJoint(_ name: JointName) -> JointPoint? {
        guard let j = joints[name], j.confidence >= AppConfig.minJointConfidence else {
            return nil
        }
        return j
    }

    // MARK: Torso length

    /// Vertical distance between the shoulder midpoint and hip midpoint,
    /// in Vision normalised units. Used as the normalisation denominator
    /// for all gesture thresholds.
    ///
    /// Returns `nil` when any of the four anchor joints is unreliable, or when
    /// the computed length is below `AppConfig.minTorsoLength`
    /// (person too far from the camera).
    var torsoLength: Double? {
        guard
            let ls = reliableJoint(.leftShoulder),
            let rs = reliableJoint(.rightShoulder),
            let lh = reliableJoint(.leftHip),
            let rh = reliableJoint(.rightHip)
        else { return nil }

        let shoulderMidY = Double(ls.location.y + rs.location.y) / 2.0
        let hipMidY      = Double(lh.location.y + rh.location.y) / 2.0
        let length = abs(shoulderMidY - hipMidY)
        return length >= AppConfig.minTorsoLength ? length : nil
    }

    // MARK: Framing check

    /// Returns the names of required joints whose confidence is below the minimum.
    /// An empty array means all required joints are visible — framing is good.
    func missingJoints(from required: [JointName]) -> [JointName] {
        required.filter { name in
            (joints[name]?.confidence ?? 0) < AppConfig.minJointConfidence
        }
    }

    // MARK: Low-confidence statistics

    /// Returns the confidence of each monitored joint (or 0 if absent).
    /// Used by SessionLogger to track % low-confidence frames per joint.
    func monitoredJointConfidences() -> [JointName: Float] {
        Dictionary(
            uniqueKeysWithValues: AppConfig.monitoredJoints.map { name in
                (name, joints[name]?.confidence ?? 0)
            }
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Factory (used by VisionPoseProvider and tests)
// ─────────────────────────────────────────────────────────────────────────────

extension PoseFrame {
    /// Build a PoseFrame from a Vision observation.
    static func make(
        from observation: VNHumanBodyPoseObservation,
        timestamp: TimeInterval,
        frameIndex: Int,
        fps: Double
    ) -> PoseFrame {
        let knownJoints: [JointName] = [
            .nose, .neck,
            .leftShoulder, .rightShoulder,
            .leftElbow, .rightElbow,
            .leftWrist, .rightWrist,
            .leftHip, .rightHip,
            .leftKnee, .rightKnee,
            .leftAnkle, .rightAnkle,
            .root,
        ]

        var joints: [JointName: JointPoint] = [:]
        joints.reserveCapacity(knownJoints.count)

        for name in knownJoints {
            // recognizedPoint throws if the joint name is not in the model;
            // use try? so unknown joints are silently skipped.
            if let point = try? observation.recognizedPoint(name) {
                joints[name] = JointPoint(location: point.location, confidence: point.confidence)
            }
        }

        return PoseFrame(
            timestamp: timestamp,
            frameIndex: frameIndex,
            joints: joints,
            fps: fps
        )
    }

    /// Convenience factory for unit tests — pass only the joints you care about.
    static func makeTest(
        joints: [JointName: (x: Double, y: Double, confidence: Float)],
        timestamp: TimeInterval = 0,
        frameIndex: Int = 0,
        fps: Double = 30
    ) -> PoseFrame {
        let jointMap = joints.mapValues { v in
            JointPoint(location: CGPoint(x: v.x, y: v.y), confidence: v.confidence)
        }
        return PoseFrame(
            timestamp: timestamp,
            frameIndex: frameIndex,
            joints: jointMap,
            fps: fps
        )
    }
}
