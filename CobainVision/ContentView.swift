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

    // Stage A1 Research Rig Hub State
    @StateObject private var macTransport = MacNetworkTransport()
    @StateObject private var thighDetector = ThighMotionDetector()
    @State private var isHubModeActive = false
    @State private var isTouchLocked = false
    @State private var manualMacIP = ""
    @State private var manualMacPort = "12345"

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

            // ── Stage A1 iPhone Thigh Hub Overlay ─────────────────────────
            if isHubModeActive {
                VStack(spacing: 12) {
                    Text("⚠️ MUST REMAIN IN FOREGROUND")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.yellow)
                        .clipShape(Capsule())

                    Text("iPhone Thigh Hub Mode")
                        .font(.headline)
                        .bold()
                        .foregroundStyle(.white)

                    Text("Angle: \(String(format: "%.1f°", thighDetector.currentThighAngleDegrees)) | Motion: \(String(format: "%.2f g", thighDetector.currentMotionMagnitude))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.green)

                    Text("Mac Link: \(macTransport.state.rawValue.capitalized) | RTT: \(String(format: "%.1f ms", macTransport.medianRTTMs))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))

                    // Thigh Calibration Buttons
                    HStack(spacing: 10) {
                        Button("Calibrate Standing") {
                            thighDetector.calibrateStanding()
                        }
                        .font(.caption2)
                        .padding(6)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        Button("Calibrate Leg Raised") {
                            thighDetector.calibrateLegRaised()
                        }
                        .font(.caption2)
                        .padding(6)
                        .background(Color.green)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    // Manual Connection Fallback Input
                    HStack(spacing: 6) {
                        TextField("Mac IP (e.g. 192.168.1.50)", text: $manualMacIP)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .frame(width: 170)
                        TextField("Port", text: $manualMacPort)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .frame(width: 50)
                        Button("Connect") {
                            let port = UInt16(manualMacPort) ?? 12345
                            macTransport.startClient(manualHost: manualMacIP, manualPort: port)
                        }
                        .font(.caption2)
                        .padding(6)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    // Touch Lock Button
                    Button(action: { isTouchLocked = true }) {
                        Label("Lock Screen for Thigh Strap", systemImage: "lock.fill")
                            .font(.system(.caption, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.purple)
                            .clipShape(Capsule())
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.top, 90)
                .frame(maxWidth: 320)
            }

            // ── Full-Screen Touch Lock Overlay ─────────────────────────────
            if isTouchLocked {
                ZStack {
                    Color.black.opacity(0.92)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        Image(systemName: "lock.shield.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.yellow)

                        Text("TOUCH LOCK ACTIVE")
                            .font(.title2)
                            .bold()
                            .foregroundStyle(.white)

                        Text("Phone is locked for thigh strapping.\nPRESS & HOLD FOR 2 SECONDS TO UNLOCK.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.gray)

                        Text("Hub State: Streaming to Mac Dashboard...")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                .onLongPressGesture(minimumDuration: 2.0) {
                    isTouchLocked = false
                }
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

                // Bottom controls
                HStack(spacing: 12) {
                    // Hub Mode Toggle
                    Button {
                        isHubModeActive.toggle()
                        UIApplication.shared.isIdleTimerDisabled = isHubModeActive
                        if isHubModeActive {
                            thighDetector.start()
                            macTransport.startClient()
                        } else {
                            thighDetector.stop()
                            macTransport.stop()
                        }
                    } label: {
                        Image(systemName: isHubModeActive ? "antenna.radiowaves.left.and.right.circle.fill" : "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(isHubModeActive ? Color.purple : Color.white.opacity(0.2))
                            .clipShape(Circle())
                    }

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
                        .padding(.horizontal, 16)
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
        .task {
            try? await watchTransport.activate()
            startSession()
            listenToWatchEvents()
            setupHubRelays()
            setupBackgroundNotificationObservers()
        }
        .onDisappear {
            stopSession()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func setupHubRelays() {
        // Thigh motion sample -> Mac Transport
        thighDetector.onSampleEmitted = { sample in
            guard isHubModeActive, let sampleData = try? JSONEncoder().encode(sample),
                  let sampleStr = String(data: sampleData, encoding: .utf8) else { return }

            let msg = HubTransportMessage(
                type: .thighSample,
                sourceId: "iphone_hub",
                sequenceNumber: sample.sequenceNumber,
                timestamp: sample.timestamp,
                payloadJSON: sampleStr
            )
            macTransport.send(msg)
        }

        // Watch raw message -> Mac Transport Relay
        watchTransport.onRawMessageReceived = { rawDict in
            guard isHubModeActive, let jsonData = try? JSONSerialization.data(withJSONObject: rawDict),
                  let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

            let msg = HubTransportMessage(
                type: .watchSampleRelay,
                sourceId: "watch_relay",
                sequenceNumber: (rawDict["seq"] as? Int) ?? 0,
                timestamp: Date().timeIntervalSince1970,
                payloadJSON: jsonStr
            )
            macTransport.send(msg)
        }
    }

    private func setupBackgroundNotificationObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            guard self.isHubModeActive else { return }
            let status = HubStatusMessage(
                timestamp: Date().timeIntervalSince1970,
                state: .paused,
                note: "iPhone app moved to background / inactive"
            )
            if let data = try? JSONEncoder().encode(status),
               let str = String(data: data, encoding: .utf8) {

                let msg = HubTransportMessage(
                    type: .hubStatus,
                    sourceId: "iphone_hub",
                    sequenceNumber: 0,
                    timestamp: Date().timeIntervalSince1970,
                    payloadJSON: str
                )
                self.macTransport.send(msg)
            }
        }
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

            // WCSession Status Fields
            VStack(alignment: .leading, spacing: 1) {
                Text("WCSession Status:")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.yellow)
                Text("• State: \(transport.activationState)")
                Text("• Paired: \(transport.isPaired ? "Yes" : "No")")
                Text("• AppInstalled: \(transport.isWatchAppInstalled ? "Yes" : "No")")
                Text("• Reachable: \(transport.isReachable ? "Yes" : "No")")
                if let err = transport.lastError {
                    Text("• Error: \(err)")
                        .foregroundStyle(.red)
                } else {
                    Text("• Error: none")
                        .foregroundStyle(.secondary)
                }
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
