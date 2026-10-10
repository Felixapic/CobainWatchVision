// MacNetworkTransport.swift
// MovementPrompt PoC — Milestone H-A Stage A1
//
// Network.framework local network transport using Bonjour discovery (_cobainvision._tcp)
// plus manual IP/Port direct connection fallback.
// Handles Mac (Listener/Server) & iPhone (Browser/Client) transport, auto-reconnect,
// raw ping-pong timing (t0, t1, t2, t3), and sequence gap tracking.

import Foundation
import Combine
import Network

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Network Connection State
// ─────────────────────────────────────────────────────────────────────────────

public enum HubNetworkState: String {
    case disconnected
    case searching
    case connecting
    case connected
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - MacNetworkTransport Protocol
// ─────────────────────────────────────────────────────────────────────────────

public protocol MacNetworkTransportProtocol: AnyObject {
    var state: HubNetworkState { get }
    var localIPAddress: String { get }
    var listeningPort: UInt16 { get }
    var medianRTTMs: Double { get }
    var p95RTTMs: Double { get }
    var droppedMessageCount: Int { get }
    var rawPingPongSamples: [PingPongSample] { get }
    
    func startServer(port: UInt16) throws
    func startClient(manualHost: String?, manualPort: UInt16?)
    func send(_ message: HubTransportMessage)
    func sendPing()
    func stop()
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - MacNetworkTransport Implementation
// ─────────────────────────────────────────────────────────────────────────────

public final class MacNetworkTransport: NSObject, MacNetworkTransportProtocol, ObservableObject {

    @Published public private(set) var state: HubNetworkState = .disconnected
    @Published public private(set) var localIPAddress: String = "127.0.0.1"
    @Published public private(set) var listeningPort: UInt16 = 12345
    @Published public private(set) var medianRTTMs: Double = 0
    @Published public private(set) var p95RTTMs: Double = 0
    @Published public private(set) var droppedMessageCount: Int = 0
    @Published public private(set) var rawPingPongSamples: [PingPongSample] = []

    public var onMessageReceived: ((HubTransportMessage) -> Void)?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?

    private var rttHistory: [Double] = []
    private var lastSequenceNumber: Int = -1
    private var sequenceNumberCounter: Int = 0
    private var pingTimer: Timer?

    private let bonjourServiceType = "_cobainvision._tcp"

    public override init() {
        super.init()
        self.localIPAddress = MacNetworkTransport.fetchLocalIPAddress()
    }

    // ── Server Mode (Mac Dashboard) ─────────────────────────────────────────

    public func startServer(port: UInt16 = 12345) throws {
        stop()
        self.listeningPort = port
        self.localIPAddress = MacNetworkTransport.fetchLocalIPAddress()

        let params = NWParameters.tcp
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: params, on: nwPort)

        listener.service = NWListener.Service(type: bonjourServiceType)

        listener.stateUpdateHandler = { [weak self] newState in
            DispatchQueue.main.async {
                switch newState {
                case .ready:
                    self?.state = .searching
                case .failed(let err):
                    print("[MacNetworkTransport] Server failed: \(err)")
                    self?.state = .disconnected
                case .cancelled:
                    self?.state = .disconnected
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] newConn in
            self?.handleIncomingConnection(newConn)
        }

        listener.start(queue: .main)
        self.listener = listener
        startPingTimer()
    }

    private func handleIncomingConnection(_ conn: NWConnection) {
        self.connection?.cancel()
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] connState in
            DispatchQueue.main.async {
                switch connState {
                case .ready:
                    self?.state = .connected
                    self?.receiveNextPacket(on: conn)
                case .failed, .cancelled:
                    if self?.connection === conn {
                        self?.state = .disconnected
                    }
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)
    }

    // ── Client Mode (iPhone Hub) ─────────────────────────────────────────────

    public func startClient(manualHost: String? = nil, manualPort: UInt16? = nil) {
        stop()

        if let host = manualHost, !host.isEmpty, let portVal = manualPort, portVal > 0 {
            // Direct IP/Port connection
            print("[MacNetworkTransport] Connecting directly to \(host):\(portVal)")
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: portVal)!)
            connectToEndpoint(endpoint)
        } else {
            // Bonjour auto-discovery
            print("[MacNetworkTransport] Browsing Bonjour service: \(bonjourServiceType)")
            let parameters = NWParameters.tcp
            let browser = NWBrowser(for: .bonjour(type: bonjourServiceType, domain: nil), using: parameters)

            browser.stateUpdateHandler = { [weak self] newState in
                DispatchQueue.main.async {
                    switch newState {
                    case .ready:
                        self?.state = .searching
                    case .failed(let err):
                        print("[MacNetworkTransport] Browser failed: \(err)")
                        self?.state = .disconnected
                    default:
                        break
                    }
                }
            }

            browser.browseResultsChangedHandler = { [weak self] results, _ in
                if let first = results.first {
                    print("[MacNetworkTransport] Discovered endpoint: \(first.endpoint)")
                    self?.browser?.cancel()
                    self?.connectToEndpoint(first.endpoint)
                }
            }

            browser.start(queue: .main)
            self.browser = browser
            self.state = .searching
        }
    }

    private func connectToEndpoint(_ endpoint: NWEndpoint) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] connState in
            DispatchQueue.main.async {
                switch connState {
                case .ready:
                    self?.state = .connected
                    self?.receiveNextPacket(on: conn)
                case .failed(let err):
                    print("[MacNetworkTransport] Client connection failed: \(err)")
                    self?.state = .disconnected
                    // Retry client connection after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        if self?.state == .disconnected {
                            self?.startClient()
                        }
                    }
                case .cancelled:
                    self?.state = .disconnected
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)
        startPingTimer()
    }

    // ── Data Transfer & Framing ──────────────────────────────────────────────

    public func send(_ message: HubTransportMessage) {
        guard let conn = connection, state == .connected else { return }
        do {
            let data = try JSONEncoder().encode(message)
            // Delimited with newline
            var frame = data
            frame.append(0x0A) // '\n'
            conn.send(content: frame, completion: .contentProcessed({ error in
                if let err = error {
                    print("[MacNetworkTransport] Send error: \(err)")
                }
            }))
        } catch {
            print("[MacNetworkTransport] Encode error: \(error)")
        }
    }

    private func receiveNextPacket(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                self.processRawData(data)
            }

            if isComplete || error != nil {
                DispatchQueue.main.async { self.state = .disconnected }
            } else {
                self.receiveNextPacket(on: conn)
            }
        }
    }

    private func processRawData(_ data: Data) {
        // Split by newline character (0x0A)
        let lines = data.split(separator: 0x0A)
        let now = Date().timeIntervalSince1970

        for lineData in lines {
            guard !lineData.isEmpty else { continue }
            do {
                let msg = try JSONDecoder().decode(HubTransportMessage.self, from: Data(lineData))
                DispatchQueue.main.async {
                    self.handleIncomingMessage(msg, arrivalTimestamp: now)
                }
            } catch {
                print("[MacNetworkTransport] Decode error: \(error)")
            }
        }
    }

    private func handleIncomingMessage(_ msg: HubTransportMessage, arrivalTimestamp: TimeInterval) {
        // Sequence gap tracking
        if lastSequenceNumber >= 0 && msg.sequenceNumber > lastSequenceNumber + 1 {
            let missing = msg.sequenceNumber - (lastSequenceNumber + 1)
            droppedMessageCount += missing
        }
        lastSequenceNumber = msg.sequenceNumber

        // Ping-Pong handling
        switch msg.type {
        case .ping:
            if let payloadStr = msg.payloadJSON,
               let payloadData = payloadStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
               let t0 = dict["t0"] as? Double {

                let t1 = arrivalTimestamp
                let t2 = Date().timeIntervalSince1970
                let pongDict: [String: Any] = ["t0": t0, "t1": t1, "t2": t2]
                if let pongJSON = try? JSONSerialization.data(withJSONObject: pongDict),
                   let pongStr = String(data: pongJSON, encoding: .utf8) {

                    sequenceNumberCounter += 1
                    let pongMsg = HubTransportMessage(
                        type: .pong,
                        sourceId: "network_node",
                        sequenceNumber: sequenceNumberCounter,
                        timestamp: t2,
                        payloadJSON: pongStr
                    )
                    send(pongMsg)
                }
            }

        case .pong:
            if let payloadStr = msg.payloadJSON,
               let payloadData = payloadStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
               let t0 = dict["t0"] as? Double,
               let t1 = dict["t1"] as? Double,
               let t2 = dict["t2"] as? Double {

                let t3 = arrivalTimestamp
                let sample = PingPongSample(link: "Mac<->iPhone", t0: t0, t1: t1, t2: t2, t3: t3)

                rawPingPongSamples.append(sample)
                if rawPingPongSamples.count > 100 { rawPingPongSamples.removeFirst() }

                rttHistory.append(sample.rttMs)
                if rttHistory.count > 100 { rttHistory.removeFirst() }

                let sorted = rttHistory.sorted()
                medianRTTMs = sorted[sorted.count / 2]
                let p95Idx = Int(Double(sorted.count) * 0.95)
                p95RTTMs = sorted[min(p95Idx, sorted.count - 1)]
            }

        default:
            break
        }

        onMessageReceived?(msg)
    }

    // ── Ping-Pong Timing ─────────────────────────────────────────────────────

    public func sendPing() {
        guard state == .connected else { return }
        let t0 = Date().timeIntervalSince1970
        let dict: [String: Any] = ["t0": t0]
        if let json = try? JSONSerialization.data(withJSONObject: dict),
           let str = String(data: json, encoding: .utf8) {

            sequenceNumberCounter += 1
            let msg = HubTransportMessage(
                type: .ping,
                sourceId: "network_node",
                sequenceNumber: sequenceNumberCounter,
                timestamp: t0,
                payloadJSON: str
            )
            send(msg)
        }
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    public func stop() {
        pingTimer?.invalidate()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        state = .disconnected
    }

    // ── Helper: Local IP Address Finder ─────────────────────────────────────

    public static func fetchLocalIPAddress() -> String {
        var address: String = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee

            if (flags & (IFF_UP | IFF_RUNNING)) != 0 && (flags & IFF_LOOPBACK) == 0 {
                if addr.sa_family == UInt8(AF_INET) { // IPv4
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        if !ip.isEmpty && ip != "127.0.0.1" {
                            address = ip
                            break
                        }
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
}
