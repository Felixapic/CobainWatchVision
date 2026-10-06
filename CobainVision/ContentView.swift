// ContentView.swift
// MovementPrompt PoC — Milestone W-LITE Stage 1
//
// Root view: camera preview (mirrored) + debug overlay + gesture HUD + Stage 1 Watch Debug Panel.

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
    @StateObject private var watchTransport = WCSessionTransport()

    // ── Local state ───────────────────────────────────────────────────────────
    @State private var currentFrame: PoseFrame?
    @State private var isRunning = false
    @State private var showOverlay = AppConfig.debugOverlayEnabledByDefault
    @State private var showWatchDebug = true
    @State private var errorMessage: String?
    @State private var exportMessage: String?
    @State private var frameTask: Task<Void, Never>?

    // Stage 1 Watch Live Debug States
    @State private var latestWatchSample: WatchFeatureSample?
    @State private var watchArmRaised: Bool = false
    @State private var watchWristShaking: Bool = false
    @State private var watchHR: Double?
    @State private var watchCalibrationText: String = "Uncalibrated"

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

            // ── Stage 1 Watch Debug Panel (Top-Right) ─────────────────────
            if showWatchDebug {
                VStack(alignment: .trailing, spacing: 4) {
                    WatchLiveDebugPanel(
                        transport: watchTransport,
                        sample: latestWatchSample,
                        armRaised: watchArmRaised,
                        wristShaking: watchWristShaking,
                        heartRate: watchHR,
                        calibrationText: watchCalibrationText,
                        onPing: { watchTransport.sendPing() }
                    )
                }
                .padding(.top, 40)
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            // ── Controls & HUD ────────────────────────────────────────────
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

                    // Watch Debug Panel toggle
                    Button {
                        showWatchDebug.toggle()
                    } label: {
                        Image(systemName: showWatchDebug ? "applewatch" : "applewatch.slash")
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
        .task {
            try? await watchTransport.activate()
            startSession()
            listenToWatchEvents()
        }
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

    private func listenToWatchEvents() {
        Task {
            for await event in watchTransport.events {
                await MainActor.run {
                    switch event {
                    case .sample(let sample):
                        self.latestWatchSample = sample
                        if let hr = sample.heartRate { self.watchHR = hr }

                    case .armRaiseDetected(_, _):
                        self.watchArmRaised = true

                    case .armRaiseEnded(_, _):
                        self.watchArmRaised = false

                    case .wristShakeDiagnostic(_, _):
                        self.watchWristShaking = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.watchWristShaking = false
                        }

                    case .heartRateUpdated(let bpm):
                        self.watchHR = bpm

                    case .calibrationUpdated(let side, let down, let up):
                        self.watchCalibrationText = "\(side.rawValue.capitalized) (Down: \(String(format:"%.1f", down)) rad, Up: \(String(format:"%.1f", up)) rad)"

                    default:
                        break
                    }
                }
            }
        }
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
// MARK: - WatchLiveDebugPanel
// ─────────────────────────────────────────────────────────────────────────────

private struct WatchLiveDebugPanel: View {
    @ObservedObject var transport: WCSessionTransport
    let sample: WatchFeatureSample?
    let armRaised: Bool
    let wristShaking: Bool
    let heartRate: Double?
    let calibrationText: String
    let onPing: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "applewatch")
                Text("Watch Live Debug")
                    .bold()
                Spacer()
                Circle()
                    .fill(transport.isReachable ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(transport.isReachable ? "Reachable" : "Unreachable")
                    .font(.caption2)
            }
            Divider().background(.white.opacity(0.3))

            // Motion & Features
            if let s = sample {
                Text(String(format: "Pitch: %.1f° | Mag: %.2f g", s.forearmPitch * 180.0 / .pi, s.motionMagnitude))
                Text("Seq: \(s.sequenceNumber) | Wrist: \(s.wristSide.rawValue.capitalized)")
            } else {
                Text("Waiting for Watch 15 Hz stream...")
                    .foregroundStyle(.gray)
            }

            // State & HR
            HStack {
                Text("Arm: \(armRaised ? "RAISED" : "IDLE")")
                    .foregroundStyle(armRaised ? Color.green : Color.gray)
                    .bold()
                if let hr = heartRate {
                    Text("• HR: \(Int(hr)) BPM")
                        .foregroundStyle(.red)
                }
            }

            if wristShaking {
                Text("⚠️ Wrist Shake (Diagnostic)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.yellow)
            }

            Text("Cal: \(calibrationText)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider().background(.white.opacity(0.3))

            // Transport Reliability Stats
            Text(String(format: "Latency: Med %.0f ms | P95 %.0f ms", transport.medianLatencyMs, transport.p95LatencyMs))
            Text(String(format: "Clock Offset: %+.2f s", transport.clockOffsetSeconds))
            Text("Dropped Msgs: \(transport.droppedMessageCount) | Disconnects: \(transport.disconnectCount)")

            HStack {
                Button(action: onPing) {
                    Text("Ping Watch")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue)
                        .clipShape(Capsule())
                }
            }
            .padding(.top, 2)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(width: 220)
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
