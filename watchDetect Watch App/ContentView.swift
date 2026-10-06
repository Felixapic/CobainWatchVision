// ContentView.swift
// watchDetect Watch App — Milestone W-LITE Stage 1
//
// Watch UI: WCSession status fields (activationState, isPaired, isWatchAppInstalled, isReachable, lastError),
// Wrist side selection, 2-step Arm Down / Arm Up calibration, Haptic toggle, live HR & Motion metrics.

import SwiftUI

struct ContentView: View {

    @StateObject private var workoutManager = WatchWorkoutManager()
    @StateObject private var motionDetector = WatchMotionDetector()
    @StateObject private var transport = WCSessionTransport()

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Connection & WCSession Status
                HStack {
                    Circle()
                        .fill(transport.isReachable ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(transport.isReachable ? "Reachable" : "Unreachable")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }

                // WCSession Status Panel (Requested fields)
                VStack(alignment: .leading, spacing: 2) {
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
                .font(.system(size: 9, design: .monospaced))
                .padding(6)
                .background(Color.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Heart Rate Readout
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    if let hr = workoutManager.heartRate {
                        Text("\(Int(hr)) BPM")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    } else {
                        Text("-- BPM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Wrist Side Selection
                Picker("Wrist", selection: $motionDetector.wristSide) {
                    Text("L Wrist").tag(WristSide.left)
                    Text("R Wrist").tag(WristSide.right)
                }
                .pickerStyle(.wheel)
                .frame(height: 45)

                // Calibration Section
                VStack(spacing: 4) {
                    Button(action: { motionDetector.calibrateArmDown() }) {
                        Label("Calibrate Down", systemImage: "arrow.down.circle")
                            .font(.caption2)
                    }
                    .tint(.blue)

                    Button(action: { motionDetector.calibrateArmUp() }) {
                        Label("Calibrate Up", systemImage: "arrow.up.circle")
                            .font(.caption2)
                    }
                    .tint(.green)

                    Text(motionDetector.calibrationState == .calibrated ? "Calibrated ✓" : "Not Calibrated")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(motionDetector.calibrationState == .calibrated ? Color.green : Color.orange)
                }

                Divider()

                // Haptics Toggle (Default OFF per Amendment 1)
                Toggle(isOn: $motionDetector.hapticsEnabled) {
                    Text("Haptics")
                        .font(.caption2)
                }

                Divider()

                // Motion & Detection Live Metrics
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "Pitch: %.1f°", motionDetector.currentPitch * 180.0 / .pi))
                    Text(String(format: "Motion: %.2f g", motionDetector.motionMagnitude))
                    HStack {
                        Text("Arm:")
                        Text(motionDetector.isArmRaised ? "RAISED" : "DOWN")
                            .bold()
                            .foregroundStyle(motionDetector.isArmRaised ? Color.green : Color.gray)
                    }
                    if motionDetector.isWristShaking {
                        Text("⚠️ Wrist Shake (Cheat)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.yellow)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(4)
        }
        .task {
            try? await transport.activate()
            motionDetector.setup(transport: transport)
            workoutManager.requestAuthorizationAndStart()
            motionDetector.start()
        }
        .onChange(of: workoutManager.heartRate) { _, newHR in
            motionDetector.updateHeartRate(newHR)
        }
    }
}

#Preview {
    ContentView()
}
