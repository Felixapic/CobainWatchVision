// DebugOverlayView.swift
// MovementPrompt PoC
//
// SwiftUI Canvas overlay drawn on top of the camera preview.
//
// ── Coordinate transform ─────────────────────────────────────────────────────
// Vision normalised space: origin bottom-left, y increases UP.
// Screen space:            origin top-left,    y increases DOWN.
// The camera preview layer is mirrored (standard front-camera behaviour).
//
// To match the mirrored preview:
//   screenX = (1 − visionX) × viewWidth    ← flip x
//   screenY = (1 − visionY) × viewHeight   ← flip y

import SwiftUI
import Vision

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Skeleton connection map
// ─────────────────────────────────────────────────────────────────────────────

private let skeletonConnections: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
    // Head / neck
    (.neck, .nose),
    // Upper body
    (.neck,          .leftShoulder),  (.neck,          .rightShoulder),
    (.leftShoulder,  .leftElbow),     (.rightShoulder, .rightElbow),
    (.leftElbow,     .leftWrist),     (.rightElbow,    .rightWrist),
    // Torso
    (.leftShoulder,  .leftHip),       (.rightShoulder, .rightHip),
    (.leftHip,       .rightHip),
    // Lower body
    (.leftHip,  .leftKnee),           (.rightHip,  .rightKnee),
    (.leftKnee, .leftAnkle),          (.rightKnee, .rightAnkle),
]

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DebugOverlayView
// ─────────────────────────────────────────────────────────────────────────────

struct DebugOverlayView: View {

    let currentFrame: PoseFrame?
    let gesturePhases: [GestureType: GesturePhase]
    let framingIssues: [VNHumanBodyPoseObservation.JointName]
    let lowConfidencePercent: [VNHumanBodyPoseObservation.JointName: Double]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // ── Skeleton canvas ──────────────────────────────────────
                if let frame = currentFrame {
                    Canvas { ctx, size in
                        drawSkeleton(ctx: ctx, size: size, frame: frame)
                        drawJoints(ctx: ctx, size: size, frame: frame)
                    }
                }

                // ── Text HUD ─────────────────────────────────────────────
                HUDView(
                    frame: currentFrame,
                    gesturePhases: gesturePhases,
                    framingIssues: framingIssues,
                    lowConfidencePercent: lowConfidencePercent
                )
                .padding(10)
            }
        }
        .allowsHitTesting(false)    // overlay is display-only; touches pass through
    }

    // ── Drawing helpers ──────────────────────────────────────────────────────

    private func drawSkeleton(ctx: GraphicsContext, size: CGSize, frame: PoseFrame) {
        for (nameA, nameB) in skeletonConnections {
            guard
                let a = frame.joint(nameA), a.confidence > 0,
                let b = frame.joint(nameB), b.confidence > 0
            else { continue }

            let minConf = min(a.confidence, b.confidence)
            var path = Path()
            path.move(to: visionToScreen(a.location, size: size))
            path.addLine(to: visionToScreen(b.location, size: size))
            ctx.stroke(
                path,
                with: .color(confidenceColor(minConf).opacity(0.75)),
                lineWidth: 2
            )
        }
    }

    private func drawJoints(ctx: GraphicsContext, size: CGSize, frame: PoseFrame) {
        for (_, joint) in frame.joints {
            guard joint.confidence > 0 else { continue }
            let pos = visionToScreen(joint.location, size: size)
            let radius: CGFloat = joint.confidence >= AppConfig.minJointConfidence ? 5 : 3
            let rect = CGRect(
                x: pos.x - radius, y: pos.y - radius,
                width: radius * 2, height: radius * 2
            )
            ctx.fill(
                Path(ellipseIn: rect),
                with: .color(confidenceColor(joint.confidence))
            )
        }
    }

    // ── Coordinate transform ──────────────────────────────────────────────────

    private func visionToScreen(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: (1.0 - Double(point.x)) * size.width,
            y: (1.0 - Double(point.y)) * size.height
        )
    }

    // ── Colour helpers ────────────────────────────────────────────────────────

    private func confidenceColor(_ confidence: Float) -> Color {
        switch confidence {
        case 0.7...:  return .green
        case 0.4...:  return Color(hue: 0.15, saturation: 1, brightness: 1)  // amber
        default:      return .red
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - HUDView
// ─────────────────────────────────────────────────────────────────────────────

private struct HUDView: View {

    let frame: PoseFrame?
    let gesturePhases: [GestureType: GesturePhase]
    let framingIssues: [VNHumanBodyPoseObservation.JointName]
    let lowConfidencePercent: [VNHumanBodyPoseObservation.JointName: Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {

            // FPS + torso length
            if let f = frame {
                Label(
                    String(format: "FPS: %.1f   torso: %@",
                           f.fps,
                           f.torsoLength.map { String(format: "%.3f", $0) } ?? "—"),
                    systemImage: "camera.fill"
                )
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.green)
            }

            Divider().overlay(.white.opacity(0.3))

            // Gesture states
            ForEach(GestureType.allCases, id: \.self) { type in
                GestureRow(type: type, phase: gesturePhases[type] ?? .idle)
            }

            // Framing warning
            if !framingIssues.isEmpty {
                Divider().overlay(.white.opacity(0.3))
                Label(
                    "Low conf: \(framingIssues.map(\.shortJointName).joined(separator: " "))",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.orange)
            }

            // Low-confidence % for monitored lower-body joints
            let lowerBody: [(VNHumanBodyPoseObservation.JointName, Double)] = [
                (.leftKnee,   lowConfidencePercent[.leftKnee]   ?? 0),
                (.rightKnee,  lowConfidencePercent[.rightKnee]  ?? 0),
                (.leftAnkle,  lowConfidencePercent[.leftAnkle]  ?? 0),
                (.rightAnkle, lowConfidencePercent[.rightAnkle] ?? 0),
            ]
            let significant = lowerBody.filter { $0.1 > 5 }
            if !significant.isEmpty {
                Text("Low-conf%: " + significant.map {
                    "\($0.0.shortJointName):\(String(format:"%.0f", $0.1))%"
                }.joined(separator: " "))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color(hue: 0.08, saturation: 1, brightness: 1))
            }
        }
        .padding(8)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GestureRow
// ─────────────────────────────────────────────────────────────────────────────

private struct GestureRow: View {
    let type: GestureType
    let phase: GesturePhase

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(bgColor)
                    .frame(width: 10, height: 10)
                if case .entering(let p) = phase {
                    Circle()
                        .trim(from: 0, to: CGFloat(p))
                        .stroke(.yellow, lineWidth: 2)
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(-90))
                }
            }
            Text(type.displayName)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
        }
    }

    private var bgColor: Color {
        switch phase {
        case .idle:     return .gray.opacity(0.5)
        case .entering: return .yellow.opacity(0.4)
        case .active:   return .green
        case .exiting:  return .orange.opacity(0.7)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - JointName extension
// ─────────────────────────────────────────────────────────────────────────────

private extension VNHumanBodyPoseObservation.JointName {
    /// Short display name for a Vision joint.
    var shortJointName: String {
        self.rawValue.rawValue
            .replacingOccurrences(of: "left",  with: "L")
            .replacingOccurrences(of: "right", with: "R")
            .replacingOccurrences(of: "VNJointName", with: "")
    }
}
