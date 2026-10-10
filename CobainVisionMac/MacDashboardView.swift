// MacDashboardView.swift
// MovementPrompt PoC — Milestone H-A Stage A1 macOS Research Rig
//
// Mac Live Dashboard: Network listener (Bonjour _cobainvision._tcp + port 12345),
// local IP/Port display, iPhone Thigh Hub panel, Apple Watch relay panel,
// raw ping-pong timing log (t0, t1, t2, t3), median/P95 RTT, rolling charts,
// and JSONL recording exporter.

import SwiftUI

public struct MacDashboardView: View {

    @StateObject private var networkTransport = MacNetworkTransport()

    // Live Sensor States
    @State private var latestThighSample: ThighFeatureSample?
    @State private var latestWatchSample: WatchFeatureSample?
    @State private var latestWatchHR: Double?
    @State private var hubStatusNote: String = "Waiting for iPhone Hub connection..."
    @State private var hubState: HubStatusState = .active

    // History for Rolling Charts (last 100 points)
    @State private var thighAngleHistory: [Double] = []
    @State private var watchPitchHistory: [Double] = []
    @State private var heartRateHistory: [Double] = []

    // JSONL Logger State
    @State private var isRecording: Bool = false
    @State private var recordedLineCount: Int = 0
    @State private var currentLogFileUrl: URL?
    @State private var logFileHandle: FileHandle?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MovementPrompt — Mac Research Dashboard (Stage A1)")
                        .font(.title2)
                        .bold()
                    Text("IP: \(networkTransport.localIPAddress) | Port: \(networkTransport.listeningPort) | Bonjour: _cobainvision._tcp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Connection Badge
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 10, height: 10)
                    Text(networkTransport.state.rawValue.capitalized)
                        .font(.headline)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.1))
                .clipShape(Capsule())

                // Recording Controls
                Button(action: toggleRecording) {
                    Label(
                        isRecording ? "Stop Recording (\(recordedLineCount) lines)" : "Start JSONL Recording",
                        systemImage: isRecording ? "stop.circle.fill" : "record.circle"
                    )
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(isRecording ? Color.red : Color.blue)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Main Content Grid
            ScrollView {
                VStack(spacing: 16) {
                    // Top Row: Sensor Stream Panels
                    HStack(alignment: .top, spacing: 16) {
                        // iPhone Thigh Hub Panel
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "iphone")
                                Text("iPhone Thigh Hub")
                                    .font(.headline)
                                Spacer()
                                Text(hubState.rawValue.capitalized)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(hubState == .active ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                            Divider()

                            if let s = latestThighSample {
                                Group {
                                    Text(String(format: "Thigh Angle: %.1f°", s.thighAngleDegrees))
                                        .font(.title3)
                                        .bold()
                                        .foregroundStyle(.blue)
                                    Text(String(format: "Motion Mag: %.2f g", s.motionMagnitude))
                                    Text(String(format: "Gravity: (%.2f, %.2f, %.2f)", s.gravityX, s.gravityY, s.gravityZ))
                                    Text("Seq: \(s.sequenceNumber) | Status: \(s.isCalibrated ? "Calibrated ✓" : "Uncalibrated")")
                                }
                                .font(.system(.body, design: .monospaced))
                            } else {
                                Text("Waiting for Thigh 20 Hz stream...")
                                    .foregroundStyle(.gray)
                                    .italic()
                            }

                            Text("Hub Note: \(hubStatusNote)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        // Apple Watch Relay Panel
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "applewatch")
                                Text("Apple Watch Stream")
                                    .font(.headline)
                                Spacer()
                            }
                            Divider()

                            if let ws = latestWatchSample {
                                Group {
                                    Text(String(format: "Forearm Pitch: %.1f°", ws.forearmPitch * 180.0 / .pi))
                                        .font(.title3)
                                        .bold()
                                        .foregroundStyle(.green)
                                    Text(String(format: "Motion Mag: %.2f g", ws.motionMagnitude))
                                    Text("Seq: \(ws.sequenceNumber) | Wrist: \(ws.wristSide.rawValue.capitalized)")
                                    if let hr = ws.heartRate ?? latestWatchHR {
                                        Text("Heart Rate: \(Int(hr)) BPM")
                                            .font(.body)
                                            .bold()
                                            .foregroundStyle(.red)
                                    }
                                }
                                .font(.system(.body, design: .monospaced))
                            } else {
                                Text("Waiting for Watch 15 Hz stream...")
                                    .foregroundStyle(.gray)
                                    .italic()
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // Middle Row: Rolling Mini-Charts
                    HStack(spacing: 16) {
                        ChartPanelView(title: "Thigh Angle (°)", values: thighAngleHistory, minVal: 0, maxVal: 90, color: .blue)
                        ChartPanelView(title: "Watch Pitch (°)", values: watchPitchHistory, minVal: -90, maxVal: 90, color: .green)
                        ChartPanelView(title: "Heart Rate (BPM)", values: heartRateHistory, minVal: 40, maxVal: 180, color: .red)
                    }

                    // Bottom Row: Network, Latency & Raw Ping-Pong Log Panel
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "network")
                            Text("Network Pipeline, Latency & Raw Ping-Pong (t0, t1, t2, t3)")
                                .font(.headline)
                            Spacer()
                        }
                        Divider()

                        HStack(spacing: 24) {
                            VStack(alignment: .leading) {
                                Text(String(format: "Median RTT: %.1f ms", networkTransport.medianRTTMs))
                                Text(String(format: "P95 RTT: %.1f ms", networkTransport.p95RTTMs))
                                Text(String(format: "One-Way Est (RTT/2): %.1f ms", networkTransport.medianRTTMs / 2.0))
                            }
                            VStack(alignment: .leading) {
                                Text("Dropped Messages: \(networkTransport.droppedMessageCount)")
                                Text("Network State: \(networkTransport.state.rawValue)")
                            }
                        }
                        .font(.system(.body, design: .monospaced))

                        Divider()

                        Text("Raw Ping-Pong Log Feed (Last 5 Samples):")
                            .font(.caption)
                            .bold()

                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(networkTransport.rawPingPongSamples.suffix(5).reversed()) { p in
                                Text(String(format: "[%@] RTT: %.1fms | t0=%.3f, t1=%.3f, t2=%.3f, t3=%.3f",
                                            p.link, p.rttMs, p.t0, p.t1, p.t2, p.t3))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding()
            }
        }
        .onAppear {
            try? networkTransport.startServer(port: 12345)
            listenToNetworkMessages()
        }
        .onDisappear {
            networkTransport.stop()
            stopRecording()
        }
    }

    private var connectionColor: Color {
        switch networkTransport.state {
        case .connected: return .green
        case .connecting, .searching: return .orange
        case .disconnected: return .red
        }
    }

    // ── Network Listener Hook ────────────────────────────────────────────────

    private func listenToNetworkMessages() {
        networkTransport.onMessageReceived = { msg in
            switch msg.type {
            case .thighSample:
                if let json = msg.payloadJSON,
                   let data = json.data(using: .utf8),
                   let sample = try? JSONDecoder().decode(ThighFeatureSample.self, from: data) {

                    self.latestThighSample = sample
                    self.thighAngleHistory.append(sample.thighAngleDegrees)
                    if self.thighAngleHistory.count > 100 { self.thighAngleHistory.removeFirst() }

                    if self.isRecording { self.logToFile(msg) }
                }

            case .watchSampleRelay:
                if let json = msg.payloadJSON,
                   let data = json.data(using: .utf8),
                   let wSample = try? JSONDecoder().decode(WatchFeatureSample.self, from: data) {

                    self.latestWatchSample = wSample
                    self.watchPitchHistory.append(wSample.forearmPitch * 180.0 / .pi)
                    if self.watchPitchHistory.count > 100 { self.watchPitchHistory.removeFirst() }

                    if let hr = wSample.heartRate {
                        self.latestWatchHR = hr
                        self.heartRateHistory.append(hr)
                        if self.heartRateHistory.count > 100 { self.heartRateHistory.removeFirst() }
                    }

                    if self.isRecording { self.logToFile(msg) }
                }

            case .hubStatus:
                if let json = msg.payloadJSON,
                   let data = json.data(using: .utf8),
                   let statusMsg = try? JSONDecoder().decode(HubStatusMessage.self, from: data) {

                    self.hubState = statusMsg.state
                    self.hubStatusNote = statusMsg.note ?? statusMsg.state.rawValue
                    if self.isRecording { self.logToFile(msg) }
                }

            default:
                if self.isRecording { self.logToFile(msg) }
            }
        }
    }

    // ── JSONL Recording ──────────────────────────────────────────────────────

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("CobainVision_Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateStr = formatter.string(from: Date())
        let fileUrl = dir.appendingPathComponent("session_rig_\(dateStr).jsonl")

        FileManager.default.createFile(atPath: fileUrl.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileUrl) else { return }

        self.logFileHandle = handle
        self.currentLogFileUrl = fileUrl
        self.recordedLineCount = 0
        self.isRecording = true

        // Write header metadata line
        let meta: [String: Any] = [
            "record_type": "session_metadata",
            "timestamp": Date().timeIntervalSince1970,
            "mac_os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "build_configuration": "Stage A1 Research Rig"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta) {
            handle.write(data)
            handle.write("\n".data(using: .utf8)!)
            recordedLineCount += 1
        }
    }

    private func stopRecording() {
        isRecording = false
        logFileHandle?.closeFile()
        logFileHandle = nil
    }

    private func logToFile(_ msg: HubTransportMessage) {
        guard let handle = logFileHandle,
              let data = try? JSONEncoder().encode(msg) else { return }
        handle.write(data)
        handle.write("\n".data(using: .utf8)!)
        recordedLineCount += 1
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Mini Rolling Chart Component
// ─────────────────────────────────────────────────────────────────────────────

private struct ChartPanelView: View {
    let title: String
    let values: [Double]
    let minVal: Double
    let maxVal: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .bold()
                .foregroundStyle(color)

            GeometryReader { geo in
                Path { path in
                    guard values.count > 1 else { return }
                    let step = geo.size.width / CGFloat(max(1, values.count - 1))
                    let range = max(0.001, maxVal - minVal)

                    for (idx, val) in values.enumerated() {
                        let clamped = max(minVal, min(maxVal, val))
                        let normY = 1.0 - CGFloat((clamped - minVal) / range)
                        let pt = CGPoint(x: CGFloat(idx) * step, y: normY * geo.size.height)
                        if idx == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                }
                .stroke(color, lineWidth: 2)
            }
            .frame(height: 60)
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
