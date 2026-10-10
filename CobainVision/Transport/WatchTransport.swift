// WatchTransport.swift
// MovementPrompt PoC — Milestone W-LITE
//
// WatchConnectivity implementation for real-time Phone<->Watch communication.
// Handles feature streaming (15 Hz), discrete events, ping-pong latency testing,
// sequence tracking, and disconnect logging.

import Foundation
import Combine
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WristSide
// ─────────────────────────────────────────────────────────────────────────────

enum WristSide: String, Codable, CaseIterable {
    case left
    case right
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WatchFeatureSample
// ─────────────────────────────────────────────────────────────────────────────

/// Lightweight 15 Hz feature sample sent by watchOS.
struct WatchFeatureSample: Codable, Identifiable {
    var id: TimeInterval { watchTimestamp }
    let watchTimestamp: TimeInterval
    let sequenceNumber: Int
    let forearmPitch: Double
    let motionMagnitude: Double
    let heartRate: Double?
    let wristSide: WristSide
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WatchTransportEvent
// ─────────────────────────────────────────────────────────────────────────────

enum WatchTransportEvent {
    case sample(WatchFeatureSample)
    case armRaiseDetected(timestamp: TimeInterval, pitch: Double)
    case armRaiseEnded(timestamp: TimeInterval, pitch: Double)
    case wristShakeDiagnostic(timestamp: TimeInterval, magnitude: Double)
    case heartRateUpdated(bpm: Double)
    case calibrationUpdated(wristSide: WristSide, armDownPitch: Double, armUpPitch: Double)
    case ping(timestamp: TimeInterval)
    case pong(origTimestamp: TimeInterval, watchTimestamp: TimeInterval)
    case reachabilityChanged(Bool)
    case disconnected
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WatchTransport Protocol
// ─────────────────────────────────────────────────────────────────────────────

protocol WatchTransport: AnyObject {
    var events: AsyncStream<WatchTransportEvent> { get }
    var isReachable: Bool { get }
    var activationState: String { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var lastError: String? { get }
    var disconnectCount: Int { get }
    var droppedMessageCount: Int { get }
    var medianLatencyMs: Double { get }
    var p95LatencyMs: Double { get }
    var clockOffsetSeconds: Double { get }
    func activate() async throws
    func send(_ message: [String: Any]) async throws
    func sendPing()
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WCSessionTransport (iOS + watchOS)
// ─────────────────────────────────────────────────────────────────────────────

final class WCSessionTransport: NSObject, WatchTransport, ObservableObject {

    @Published private(set) var isReachable: Bool = false
    @Published private(set) var activationState: String = "notActivated"
    @Published private(set) var isPaired: Bool = false
    @Published private(set) var isWatchAppInstalled: Bool = false
    @Published private(set) var lastError: String? = nil

    @Published private(set) var disconnectCount: Int = 0
    @Published private(set) var droppedMessageCount: Int = 0
    @Published private(set) var medianLatencyMs: Double = 0
    @Published private(set) var p95LatencyMs: Double = 0
    @Published private(set) var clockOffsetSeconds: Double = 0

    let events: AsyncStream<WatchTransportEvent>
    private var continuation: AsyncStream<WatchTransportEvent>.Continuation?

    public var onRawMessageReceived: (([String: Any]) -> Void)?

    private var latencyHistory: [Double] = []
    private var lastSequenceNumber: Int = -1
    private var pingTimer: Timer?

    override init() {
        var cont: AsyncStream<WatchTransportEvent>.Continuation?
        self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation in
            cont = continuation
        }
        super.init()
        self.continuation = cont
    }

    func activate() async throws {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        await MainActor.run {
            self.isReachable = session.isReachable
        }
        startPingTimer()
        #endif
    }

    func send(_ message: [String: Any]) async throws {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { [weak self] error in
                self?.handleTransportError(error)
            }
        } else {
            session.transferUserInfo(message)
        }
        #endif
    }

    func sendPing() {
        let now = Date().timeIntervalSince1970
        let payload: [String: Any] = ["type": "ping", "ts": now]
        Task {
            try? await send(payload)
        }
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        let interval = AppConfig.pingPongIntervalSeconds
        pingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    private func handleTransportError(_ error: Error) {
        Task { @MainActor in
            self.disconnectCount += 1
            self.continuation?.yield(.disconnected)
        }
    }

    private func processIncomingPayload(_ dict: [String: Any]) {
        guard let type = dict["type"] as? String else { return }
        onRawMessageReceived?(dict)

        switch type {
        case "feature":
            if let ts = dict["ts"] as? Double,
               let seq = dict["seq"] as? Int,
               let pitch = dict["pitch"] as? Double,
               let mag = dict["mag"] as? Double,
               let sideStr = dict["side"] as? String,
               let side = WristSide(rawValue: sideStr) {

                let hr = dict["hr"] as? Double
                let sample = WatchFeatureSample(
                    watchTimestamp: ts,
                    sequenceNumber: seq,
                    forearmPitch: pitch,
                    motionMagnitude: mag,
                    heartRate: hr,
                    wristSide: side
                )

                Task { @MainActor in
                    if self.lastSequenceNumber >= 0 && seq > self.lastSequenceNumber + 1 {
                        let missing = seq - (self.lastSequenceNumber + 1)
                        self.droppedMessageCount += missing
                    }
                    self.lastSequenceNumber = seq
                }

                continuation?.yield(.sample(sample))
            }

        case "armRaiseDetected":
            if let ts = dict["ts"] as? Double, let pitch = dict["pitch"] as? Double {
                continuation?.yield(.armRaiseDetected(timestamp: ts, pitch: pitch))
            }

        case "armRaiseEnded":
            if let ts = dict["ts"] as? Double, let pitch = dict["pitch"] as? Double {
                continuation?.yield(.armRaiseEnded(timestamp: ts, pitch: pitch))
            }

        case "wristShake":
            if let ts = dict["ts"] as? Double, let mag = dict["mag"] as? Double {
                continuation?.yield(.wristShakeDiagnostic(timestamp: ts, magnitude: mag))
            }

        case "hr":
            if let bpm = dict["bpm"] as? Double {
                continuation?.yield(.heartRateUpdated(bpm: bpm))
            }

        case "calibration":
            if let sideStr = dict["side"] as? String,
               let side = WristSide(rawValue: sideStr),
               let down = dict["down"] as? Double,
               let up = dict["up"] as? Double {
                continuation?.yield(.calibrationUpdated(wristSide: side, armDownPitch: down, armUpPitch: up))
            }

        case "ping":
            if let ts = dict["ts"] as? Double {
                let pongPayload: [String: Any] = [
                    "type": "pong",
                    "origTs": ts,
                    "watchTs": Date().timeIntervalSince1970
                ]
                Task { try? await send(pongPayload) }
                continuation?.yield(.ping(timestamp: ts))
            }

        case "pong":
            if let origTs = dict["origTs"] as? Double,
               let watchTs = dict["watchTs"] as? Double {
                let now = Date().timeIntervalSince1970
                let rtt = (now - origTs) * 1000.0  // ms
                let latency = max(0.0, rtt / 2.0)
                let offset = watchTs - (origTs + (rtt / 2000.0))

                Task { @MainActor in
                    self.latencyHistory.append(latency)
                    if self.latencyHistory.count > 100 { self.latencyHistory.removeFirst() }

                    let sorted = self.latencyHistory.sorted()
                    self.medianLatencyMs = sorted[sorted.count / 2]
                    let p95Idx = Int(Double(sorted.count) * 0.95)
                    self.p95LatencyMs = sorted[min(p95Idx, sorted.count - 1)]
                    self.clockOffsetSeconds = offset
                }

                continuation?.yield(.pong(origTimestamp: origTs, watchTimestamp: watchTs))
            }

        default:
            break
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WCSessionDelegate
// ─────────────────────────────────────────────────────────────────────────────

#if canImport(WatchConnectivity)
extension WCSessionTransport: WCSessionDelegate {

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            let stateStr: String
            switch activationState {
            case .activated: stateStr = "activated"
            case .inactive: stateStr = "inactive"
            case .notActivated: stateStr = "notActivated"
            @unknown default: stateStr = "unknown"
            }

            self.activationState = stateStr
            self.isReachable = session.isReachable
            self.lastError = error?.localizedDescription

            #if os(iOS)
            self.isPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            #else
            self.isPaired = true
            self.isWatchAppInstalled = true
            #endif

            print("[WCSessionStatus] activationState=\(stateStr), isReachable=\(session.isReachable), isPaired=\(self.isPaired), isWatchAppInstalled=\(self.isWatchAppInstalled), error=\(self.lastError ?? "nil")")

            self.continuation?.yield(.reachabilityChanged(session.isReachable))
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            let reachable = session.isReachable
            if !reachable && self.isReachable {
                self.disconnectCount += 1
                self.continuation?.yield(.disconnected)
            }
            self.isReachable = reachable
            print("[WCSessionStatus] reachabilityDidChange isReachable=\(reachable)")
            self.continuation?.yield(.reachabilityChanged(reachable))
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        processIncomingPayload(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        processIncomingPayload(message)
        replyHandler(["status": "ok"])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        processIncomingPayload(userInfo)
    }

    #if os(iOS)
    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            print("[WCSessionStatus] watchStateDidChange isPaired=\(session.isPaired), isWatchAppInstalled=\(session.isWatchAppInstalled)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in
            self.activationState = "inactive"
            print("[WCSessionStatus] sessionDidBecomeInactive")
        }
    }

    func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            self.activationState = "notActivated"
            print("[WCSessionStatus] sessionDidDeactivate")
        }
        WCSession.default.activate()
    }
    #endif
}
#endif

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - NullWatchTransport (Fallback placeholder)
// ─────────────────────────────────────────────────────────────────────────────

final class NullWatchTransport: WatchTransport {
    let events: AsyncStream<WatchTransportEvent> = AsyncStream { _ in }
    var isReachable: Bool { false }
    var activationState: String { "notActivated" }
    var isPaired: Bool { false }
    var isWatchAppInstalled: Bool { false }
    var lastError: String? { nil }
    var disconnectCount: Int { 0 }
    var droppedMessageCount: Int { 0 }
    var medianLatencyMs: Double { 0 }
    var p95LatencyMs: Double { 0 }
    var clockOffsetSeconds: Double { 0 }
    func activate() async throws {}
    func send(_ message: [String: Any]) async throws {}
    func sendPing() {}
}
