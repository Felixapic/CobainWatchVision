// AppConfig.swift
// MovementPrompt PoC
//
// SINGLE SOURCE OF TRUTH for all tuneable values.
// Edit only this file to adjust thresholds; never put magic numbers in logic code.

import Vision

/// All configurable parameters for the Movement Prompt PoC.
///
/// Gesture thresholds are expressed as a ratio of the torso length
/// (shoulder-midpoint to hip-midpoint distance in Vision normalised space)
/// unless stated otherwise.
enum AppConfig {

    // ─── Vision ───────────────────────────────────────────────────────────────

    /// Target frames per second for AVCaptureSession.
    /// Actual FPS may be lower on older devices, especially with .accurate model.
    static let targetFPS: Int = 30

    /// Minimum per-joint confidence to use a joint in any rule.
    /// Vision docs: confidence == 0 means the joint was not detected at all.
    /// This floor additionally rejects low-but-non-zero noisy readings.
    static let minJointConfidence: Float = 0.3

    // ─── Hysteresis ───────────────────────────────────────────────────────────

    /// Consecutive frames the rule must be TRUE before firing .detected.
    /// 5 frames @ 30 fps ≈ 167 ms. Increase to reduce false positives.
    static let hysteresisEnterFrames: Int = 5

    /// Consecutive frames the rule must be FALSE before firing .ended.
    /// 3 frames @ 30 fps ≈ 100 ms. Increase for more stable hold detection.
    static let hysteresisExitFrames: Int = 3

    // ─── Normalisation ────────────────────────────────────────────────────────

    /// Minimum shoulder-to-hip torso length in Vision normalised units (0…1).
    /// Below this, the person is too far away; torsoLength returns nil.
    static let minTorsoLength: Double = 0.05

    // ─── Arm raise thresholds ─────────────────────────────────────────────────

    /// Wrist must be this many torso-lengths ABOVE the shoulder.
    /// Vision y increases upward, so (wrist.y - shoulder.y) > 0 means wrist is higher.
    static let armRaiseWristAboveShoulderRatio: Double = 0.10

    /// Elbow must be at least this many torso-lengths above the shoulder.
    /// Negative tolerance allows a slightly bent-down elbow to still pass.
    static let armRaiseElbowAboveShoulderRatio: Double = -0.05

    // ─── High-knee thresholds ─────────────────────────────────────────────────

    /// Knee must be this many torso-lengths ABOVE the hip.
    static let highKneeKneeAboveHipRatio: Double = 0.10

    // ─── Squat threshold ──────────────────────────────────────────────────────

    /// (hipMid.y − ankleMid.y) / torsoLength must be BELOW this value.
    /// Standing baseline is typically 2.5–3.5; a deep squat reduces this.
    /// M1: absolute threshold, no standing calibration. Tune after first runs.
    static let squatHipAnkleRatio: Double = 1.6

    // ─── Low-confidence joint monitoring ──────────────────────────────────────

    /// Joints whose low-confidence frame percentage is tracked and logged.
    /// Lower-body joints are listed first — they are the primary Q2 concern.
    static let monitoredJoints: [VNHumanBodyPoseObservation.JointName] = [
        .leftKnee, .rightKnee,
        .leftAnkle, .rightAnkle,
        .leftHip, .rightHip,
    ]

    // ─── Framing check ────────────────────────────────────────────────────────

    /// Upper-body joints that must be visible (≥ minJointConfidence) for the
    /// pre-run framing check to pass.
    static let framingUpperBodyJoints: [VNHumanBodyPoseObservation.JointName] = [
        .neck, .leftShoulder, .rightShoulder, .leftHip, .rightHip,
    ]

    /// Lower-body joints added to the framing requirement when testing
    /// knee or squat gestures.
    static let framingLowerBodyJoints: [VNHumanBodyPoseObservation.JointName] = [
        .leftKnee, .rightKnee,
    ]

    // ─── Logging ──────────────────────────────────────────────────────────────

    /// Increment when the log schema changes to avoid parsing mismatches.
    static let logSchemaVersion = "1.0"

    // ─── Detection mode ───────────────────────────────────────────────────────

    static let defaultDetectionMode: DetectionMode = .cameraOnly

    // ─── Debug overlay ────────────────────────────────────────────────────────

    /// Show the skeleton overlay on launch.
    static let debugOverlayEnabledByDefault: Bool = true

    // ─── FPS rolling average ──────────────────────────────────────────────────

    /// Exponential moving average weight for FPS display (0…1).
    /// Higher = more responsive; lower = smoother.
    static let fpsEMAWeight: Double = 0.1
}
