// GestureDefinitions.swift
// MovementPrompt PoC
//
// Every gesture is defined here as a GestureDefinition value: the joints it
// uses, its rule function, hysteresis counts, and known failure modes.
//
// ── Front-camera mirror mapping (read before editing any rule) ─────────────
//
//   VisionPoseProvider delivers an UNMIRRORED portrait pixel buffer
//   (videoRotationAngle = 90 applied; front camera buffer is never mirrored
//   by AVCaptureVideoDataOutput).
//
//   Therefore in the Vision coordinate space:
//     Vision .leftXxx   = LEFT of portrait image  = person's RIGHT side
//     Vision .rightXxx  = RIGHT of portrait image  = person's LEFT side
//
//   Every rule below uses Vision joint names internally.
//   GestureType names use person-perspective (rightArmRaise = person's right).
//
// ── Vision coordinate system ───────────────────────────────────────────────
//   Origin (0,0) = bottom-left.  y increases UPWARD.
//   All thresholds are normalised by torso length (shoulder-to-hip distance).

import Vision

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GestureDefinition
// ─────────────────────────────────────────────────────────────────────────────

struct GestureDefinition {
    let type: GestureType
    /// Vision joints that must be reliable for the rule to be evaluated.
    /// If any required joint has confidence < minJointConfidence the rule
    /// is automatically treated as FALSE for that frame.
    let requiredJoints: [VNHumanBodyPoseObservation.JointName]
    /// Consecutive frames above threshold → fire .detected.
    let enterFrames: Int
    /// Consecutive frames below threshold → fire .ended.
    let exitFrames: Int
    /// The core boolean predicate. Called only when all required joints are
    /// reliable and torsoLength is non-nil.
    let rule: (PoseFrame, Double) -> Bool
    /// Human-readable failure risk summary (logged + surfaced in PROJECT_CONTEXT).
    let knownFailures: String
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GestureDefinitions
// ─────────────────────────────────────────────────────────────────────────────

enum GestureDefinitions {

    static let all: [GestureDefinition] = [
        rightArmRaise,
        leftArmRaise,
        bothArmLateral,
        rightHighKnee,
        leftHighKnee,
        squat,
    ]

    // ─── Right arm raise (person's right arm) ─────────────────────────────

    /// Person raises their RIGHT arm above their shoulder.
    ///
    /// Joints:  Vision rightShoulder, rightElbow, rightWrist
    static let rightArmRaise = GestureDefinition(
        type: .rightArmRaise,
        requiredJoints: [.rightShoulder, .rightElbow, .rightWrist],
        enterFrames: AppConfig.hysteresisEnterFrames,
        exitFrames:  AppConfig.hysteresisExitFrames,
        rule: { frame, torso in
            guard
                let shoulder = frame.reliableJoint(.rightShoulder),
                let elbow    = frame.reliableJoint(.rightElbow),
                let wrist    = frame.reliableJoint(.rightWrist)
            else { return false }

            let wristRatio  = (Double(wrist.location.y)  - Double(shoulder.location.y)) / torso
            let elbowRatio  = (Double(elbow.location.y)  - Double(shoulder.location.y)) / torso
            return wristRatio > AppConfig.armRaiseWristAboveShoulderRatio
                && elbowRatio > AppConfig.armRaiseElbowAboveShoulderRatio
        },
        knownFailures: "Arm behind head drops elbow; arm crossing body occludes wrist."
    )

    // ─── Left arm raise (person's left arm) ──────────────────────────────

    /// Person raises their LEFT arm above their shoulder.
    ///
    /// Joints:  Vision leftShoulder, leftElbow, leftWrist
    static let leftArmRaise = GestureDefinition(
        type: .leftArmRaise,
        requiredJoints: [.leftShoulder, .leftElbow, .leftWrist],
        enterFrames: AppConfig.hysteresisEnterFrames,
        exitFrames:  AppConfig.hysteresisExitFrames,
        rule: { frame, torso in
            guard
                let shoulder = frame.reliableJoint(.leftShoulder),
                let elbow    = frame.reliableJoint(.leftElbow),
                let wrist    = frame.reliableJoint(.leftWrist)
            else { return false }

            let wristRatio = (Double(wrist.location.y)  - Double(shoulder.location.y)) / torso
            let elbowRatio = (Double(elbow.location.y)  - Double(shoulder.location.y)) / torso
            return wristRatio > AppConfig.armRaiseWristAboveShoulderRatio
                && elbowRatio > AppConfig.armRaiseElbowAboveShoulderRatio
        },
        knownFailures: "Same as rightArmRaise, mirrored."
    )

    // ─── Both-arm lateral raise ────────────────────────────────────────────

    /// Person raises BOTH arms above their shoulders simultaneously.
    static let bothArmLateral = GestureDefinition(
        type: .bothArmLateral,
        requiredJoints: [
            .leftShoulder, .leftElbow, .leftWrist,
            .rightShoulder, .rightElbow, .rightWrist,
        ],
        enterFrames: AppConfig.hysteresisEnterFrames,
        exitFrames:  AppConfig.hysteresisExitFrames,
        rule: { frame, torso in
            guard
                let lShoulder = frame.reliableJoint(.leftShoulder),
                let lElbow    = frame.reliableJoint(.leftElbow),
                let lWrist    = frame.reliableJoint(.leftWrist),
                let rShoulder = frame.reliableJoint(.rightShoulder),
                let rElbow    = frame.reliableJoint(.rightElbow),
                let rWrist    = frame.reliableJoint(.rightWrist)
            else { return false }

            let lWristR  = (Double(lWrist.location.y)  - Double(lShoulder.location.y)) / torso
            let lElbowR  = (Double(lElbow.location.y)  - Double(lShoulder.location.y)) / torso
            let rWristR  = (Double(rWrist.location.y)  - Double(rShoulder.location.y)) / torso
            let rElbowR  = (Double(rElbow.location.y)  - Double(rShoulder.location.y)) / torso

            let leftArm  = lWristR > AppConfig.armRaiseWristAboveShoulderRatio
                        && lElbowR > AppConfig.armRaiseElbowAboveShoulderRatio
            let rightArm = rWristR > AppConfig.armRaiseWristAboveShoulderRatio
                        && rElbowR > AppConfig.armRaiseElbowAboveShoulderRatio
            return leftArm && rightArm
        },
        knownFailures: "One arm out of frame → always false. Body lean shifts torso estimate."
    )

    // ─── Right high knee (person's right knee) ────────────────────────────

    /// Person lifts their RIGHT knee above the hip.
    ///
    /// Joints:  Vision rightHip, rightKnee
    static let rightHighKnee = GestureDefinition(
        type: .rightHighKnee,
        requiredJoints: [.rightHip, .rightKnee],
        enterFrames: AppConfig.hysteresisEnterFrames,
        exitFrames:  AppConfig.hysteresisExitFrames,
        rule: { frame, torso in
            guard
                let hip  = frame.reliableJoint(.rightHip),
                let knee = frame.reliableJoint(.rightKnee)
            else { return false }

            let kneeRatio = (Double(knee.location.y) - Double(hip.location.y)) / torso
            return kneeRatio > AppConfig.highKneeKneeAboveHipRatio
        },
        knownFailures: """
            Knee confidence often low for front camera at chest height. \
            Far distance → knee/ankle both below minJointConfidence. \
            Baggy clothing reduces visibility. Log low-confidence % for Q2.
            """
    )

    // ─── Left high knee (person's left knee) ──────────────────────────────

    /// Person lifts their LEFT knee above the hip.
    ///
    /// Joints:  Vision leftHip, leftKnee
    static let leftHighKnee = GestureDefinition(
        type: .leftHighKnee,
        requiredJoints: [.leftHip, .leftKnee],
        enterFrames: AppConfig.hysteresisEnterFrames,
        exitFrames:  AppConfig.hysteresisExitFrames,
        rule: { frame, torso in
            guard
                let hip  = frame.reliableJoint(.leftHip),
                let knee = frame.reliableJoint(.leftKnee)
            else { return false }

            let kneeRatio = (Double(knee.location.y) - Double(hip.location.y)) / torso
            return kneeRatio > AppConfig.highKneeKneeAboveHipRatio
        },
        knownFailures: "Identical to rightHighKnee, mirrored."
    )

    // ─── Squat ────────────────────────────────────────────────────────────

    /// Person performs a squat (hips descend toward ankle level).
    ///
    /// Joints:  leftHip, rightHip, leftAnkle, rightAnkle, leftKnee, rightKnee
    ///
    /// Rule:
    ///   let hipMidY    = (leftHip.y + rightHip.y) / 2
    ///   let ankleMidY  = (leftAnkle.y + rightAnkle.y) / 2
    ///   (hipMidY − ankleMidY) / torso < squatHipAnkleRatio
    ///
    ///   Standing baseline: hip-to-ankle ratio ≈ 2.5–3.5 (torso-normalised).
    ///   Deep squat: ratio drops significantly. M1 threshold: 1.6 (tune after runs).
    ///
    /// Known failures  (MOST FRAGILE gesture per brief):
    ///   - Requires ALL lower-body joints visible → phone must be far enough back.
    ///   - Ankles are frequently confidence-0 at typical selfie distances.
    ///   - Knee confidence degrades as knees exit the frame bottom edge.
    ///   - No standing calibration in M1 → absolute threshold may mis-fire
    ///     for tall/short people or unusual camera heights.
    ///   - User leaning forward partially occludes hips in 2D projection.
    ///   - Log % low-confidence frames for knee and ankle (Q2 metric).
    static let squat = GestureDefinition(
        type: .squat,
        requiredJoints: [.leftHip, .rightHip, .leftAnkle, .rightAnkle],
        enterFrames: AppConfig.hysteresisEnterFrames,
        exitFrames:  AppConfig.hysteresisExitFrames,
        rule: { frame, torso in
            guard
                let lHip    = frame.reliableJoint(.leftHip),
                let rHip    = frame.reliableJoint(.rightHip),
                let lAnkle  = frame.reliableJoint(.leftAnkle),
                let rAnkle  = frame.reliableJoint(.rightAnkle)
            else { return false }

            let hipMidY   = Double(lHip.location.y   + rHip.location.y)   / 2.0
            let ankleMidY = Double(lAnkle.location.y + rAnkle.location.y) / 2.0

            // hipMidY > ankleMidY when standing (hips are higher than ankles).
            // The ratio shrinks during a squat as hips descend.
            let ratio = (hipMidY - ankleMidY) / torso
            return ratio < AppConfig.squatHipAnkleRatio
        },
        knownFailures: """
            Most fragile gesture: all lower-body joints must be visible. \
            Ankle confidence near-zero at typical selfie distances. \
            No calibration in M1; threshold 1.6 is a starting point only. \
            Log low-confidence % for knee+ankle per-frame for Q2 analysis.
            """
    )
}
