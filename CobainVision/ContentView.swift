// ContentView.swift
// MovementPrompt PoC — M1
//
// Root view: camera preview (mirrored) + debug overlay + gesture HUD + controls.
// PoC disclaimer is always visible per the brief.

import SwiftUI
import AVFoundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ContentView
// ─────────────────────────────────────────────────────────────────────────────

struct ContentView: View {

    // ── View models ──────────────────────────────────────────────────────────
    @StateObject private var poseProvider = VisionPoseProvider()
    @StateObject private var gestureEngine = GestureEngine()
    @StateObject private var logger = SessionLogger()

    // ── Local state ───────────────────────────────────────────────────────────
    @State private var currentFrame: PoseFrame?
    @State private var isRunning = false
    @State private var showOverlay = AppConfig.debugOverlayEnabledByDefault
    @State private var errorMessage: String?
    @State private var exportMessage: String?
    @State private var frameTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // ── Camera preview (full-screen, mirrored) ────────────────────
            CameraPreviewView(session: poseProvider.captureSession)
                .ignoresSafeArea()

            // ── Debug overlay ─────────────────────────────────────────────
            if showOverlay {
                DebugOverlayView(
                    currentFrame: currentFrame,
                    gesturePhases: gestureEngine.gesturePhases,
                    framingIssues: gestureEngine.framingIssues,
                    lowConfidencePercent: logger.lowConfidencePercent
                )
                .ignoresSafeArea()
            }

            // ── Controls ──────────────────────────────────────────────────
            VStack {
                // PoC disclaimer — always visible
                Text("PoC – not medical advice")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.4))
                    .clipShape(Capsule())
                    .padding(.top, 8)

                Spacer()

                // Gesture event feed (last 4 events)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(gestureEngine.sessionEvents.suffix(4).reversed()) { event in
                        EventBadge(event: event)
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer().frame(height: 16)

                // Bottom controls
                HStack(spacing: 16) {
                    // Start / Stop
                    Button {
                        isRunning ? stopSession() : startSession()
                    } label: {
                        Label(
                            isRunning ? "Stop" : "Start",
                            systemImage: isRunning ? "stop.fill" : "play.fill"
                        )
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(isRunning ? Color.red : Color.green)
                        .clipShape(Capsule())
                    }

                    // Overlay toggle
                    Button {
                        showOverlay.toggle()
                    } label: {
                        Image(systemName: showOverlay ? "eye.fill" : "eye.slash")
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.white.opacity(0.2))
                            .clipShape(Circle())
                    }

                    // Export CSV
                    Button {
                        exportCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.white.opacity(0.2))
                            .clipShape(Circle())
                    }
                }
                .padding(.bottom, 32)

                // Error / export message
                if let msg = errorMessage ?? exportMessage {
                    Text(msg)
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(errorMessage != nil ? Color.red : Color.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, 8)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .background(.black)
        .task { startSession() }
        .onDisappear { stopSession() }
    }

    // ─── Session control ─────────────────────────────────────────────────────

    private func startSession() {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        exportMessage = nil
        gestureEngine.reset()
        logger.reset()

        frameTask = Task {
            do {
                try await poseProvider.start()
                for await frame in poseProvider.frames {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        currentFrame = frame
                        let events = gestureEngine.process(frame)
                        logger.log(frame: frame)
                        for event in events { logger.log(event: event) }
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isRunning = false
                }
            }
        }
    }

    private func stopSession() {
        frameTask?.cancel()
        frameTask = nil
        poseProvider.stop()
        isRunning = false
    }

    private func exportCSV() {
        do {
            let (framesURL, eventsURL) = try logger.exportCSV()
            exportMessage = "Saved:\n\(framesURL.lastPathComponent)\n\(eventsURL.lastPathComponent)"
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - EventBadge
// ─────────────────────────────────────────────────────────────────────────────

private struct EventBadge: View {
    let event: GestureEvent

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: event.kind == .detected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(event.kind == .detected ? .green : .gray)
                .font(.caption)
            Text("\(event.gestureType.displayName) \(event.kind.rawValue)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.black.opacity(0.5))
        .clipShape(Capsule())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CameraPreviewView (UIViewRepresentable)
// ─────────────────────────────────────────────────────────────────────────────

/// Wraps `AVCaptureVideoPreviewLayer` in SwiftUI.
/// The preview layer is mirrored (standard front-camera mirror behaviour).
/// The data output is NOT mirrored — see VisionPoseProvider for details.
struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.updateLayout()
    }

    // ── Inner UIView ──────────────────────────────────────────────────────────

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
        func updateLayout() {
            previewLayer.frame = bounds
            if let connection = previewLayer.connection {
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            updateLayout()
        }
    }
}

#Preview {
    ContentView()
}
