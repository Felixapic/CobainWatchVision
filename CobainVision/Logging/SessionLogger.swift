// SessionLogger.swift
// MovementPrompt PoC
//
// Logs joint data, gesture events, and session metadata to an in-memory store,
// then writes a CSV file to the app's Documents directory on demand.
//
// Log schema version: 1.0 (AppConfig.logSchemaVersion)
// Watch sample slots are present from day one and populated with nil in M1.
// Increment AppConfig.logSchemaVersion if the schema changes.

import Foundation
import Combine
import Vision

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Log entry types
// ─────────────────────────────────────────────────────────────────────────────

/// One row in the frame log CSV.
struct FrameLogEntry: Codable {
    let schemaVersion: String       // AppConfig.logSchemaVersion
    let sessionID: String
    let timestamp: TimeInterval     // CACurrentMediaTime
    let frameIndex: Int
    let fps: Double
    let torsoLength: Double?
    let detectionMode: String       // DetectionMode.rawValue

    // Per-joint confidence (only monitored joints)
    let leftKneeConf: Float
    let rightKneeConf: Float
    let leftAnkleConf: Float
    let rightAnkleConf: Float
    let leftHipConf: Float
    let rightHipConf: Float

    // Watch sample slots — nil in M1, populated in M3
    let watchTimestamp: TimeInterval?
    let watchForearmPitch: Double?
    let watchMotionMagnitude: Double?
    let watchHeartRate: Double?

    static func csvHeader() -> String {
        [
            "schemaVersion", "sessionID", "timestamp", "frameIndex", "fps",
            "torsoLength", "detectionMode",
            "leftKneeConf", "rightKneeConf", "leftAnkleConf", "rightAnkleConf",
            "leftHipConf", "rightHipConf",
            "watchTimestamp", "watchForearmPitch", "watchMotionMagnitude", "watchHeartRate",
        ].joined(separator: ",")
    }

    func csvRow() -> String {
        [
            schemaVersion, sessionID,
            String(timestamp), String(frameIndex), String(format: "%.2f", fps),
            torsoLength.map { String(format: "%.4f", $0) } ?? "",
            detectionMode,
            String(format: "%.3f", leftKneeConf),
            String(format: "%.3f", rightKneeConf),
            String(format: "%.3f", leftAnkleConf),
            String(format: "%.3f", rightAnkleConf),
            String(format: "%.3f", leftHipConf),
            String(format: "%.3f", rightHipConf),
            watchTimestamp.map { String($0) } ?? "",
            watchForearmPitch.map { String(format: "%.4f", $0) } ?? "",
            watchMotionMagnitude.map { String(format: "%.4f", $0) } ?? "",
            watchHeartRate.map { String(format: "%.1f", $0) } ?? "",
        ].joined(separator: ",")
    }
}

/// One row in the event log CSV.
struct EventLogEntry: Codable {
    let schemaVersion: String
    let sessionID: String
    let timestamp: TimeInterval
    let gestureType: String         // GestureType.rawValue
    let eventKind: String           // GestureEvent.Kind.rawValue
    let source: String              // GestureEvent.Source.rawValue
    let torsoLength: Double?
    let framesToDetect: Int
    let detectionMode: String

    static func csvHeader() -> String {
        [
            "schemaVersion", "sessionID", "timestamp",
            "gestureType", "eventKind", "source",
            "torsoLength", "framesToDetect", "detectionMode",
        ].joined(separator: ",")
    }

    func csvRow() -> String {
        [
            schemaVersion, sessionID, String(timestamp),
            gestureType, eventKind, source,
            torsoLength.map { String(format: "%.4f", $0) } ?? "",
            String(framesToDetect),
            detectionMode,
        ].joined(separator: ",")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SessionLogger
// ─────────────────────────────────────────────────────────────────────────────

/// Accumulates frame and event log entries during a session and writes CSV
/// files to the app's Documents directory when `exportCSV()` is called.
@MainActor
final class SessionLogger: ObservableObject {

    // ── Session state ────────────────────────────────────────────────────────

    let sessionID: String
    private(set) var mode: DetectionMode
    private var frameEntries: [FrameLogEntry] = []
    private var eventEntries: [EventLogEntry] = []

    // ── Published summaries ───────────────────────────────────────────────────

    @Published private(set) var totalFrames: Int = 0
    @Published private(set) var lowConfidencePercent: [VNHumanBodyPoseObservation.JointName: Double] = [:]

    // ── Init ─────────────────────────────────────────────────────────────────

    init(mode: DetectionMode? = nil) {
        self.sessionID = UUID().uuidString
        self.mode = mode ?? AppConfig.defaultDetectionMode
    }

    // ── Logging API ───────────────────────────────────────────────────────────

    /// Log one pose frame. Call on every PoseFrame received from the provider.
    func log(frame: PoseFrame, watchSample: WatchFeatureSample? = nil) {
        let confs = frame.monitoredJointConfidences()
        let entry = FrameLogEntry(
            schemaVersion: AppConfig.logSchemaVersion,
            sessionID: sessionID,
            timestamp: frame.timestamp,
            frameIndex: frame.frameIndex,
            fps: frame.fps,
            torsoLength: frame.torsoLength,
            detectionMode: mode.rawValue,
            leftKneeConf: confs[.leftKnee] ?? 0,
            rightKneeConf: confs[.rightKnee] ?? 0,
            leftAnkleConf: confs[.leftAnkle] ?? 0,
            rightAnkleConf: confs[.rightAnkle] ?? 0,
            leftHipConf: confs[.leftHip] ?? 0,
            rightHipConf: confs[.rightHip] ?? 0,
            watchTimestamp: watchSample?.watchTimestamp,
            watchForearmPitch: watchSample?.forearmPitch,
            watchMotionMagnitude: watchSample?.motionMagnitude,
            watchHeartRate: watchSample?.heartRate
        )
        frameEntries.append(entry)
        totalFrames += 1
        updateLowConfidenceStats()
    }

    /// Log a gesture event emitted by the GestureEngine.
    func log(event: GestureEvent) {
        let entry = EventLogEntry(
            schemaVersion: AppConfig.logSchemaVersion,
            sessionID: sessionID,
            timestamp: event.timestamp,
            gestureType: event.gestureType.rawValue,
            eventKind: event.kind.rawValue,
            source: event.source.rawValue,
            torsoLength: event.torsoLength,
            framesToDetect: event.framesToDetect,
            detectionMode: mode.rawValue
        )
        eventEntries.append(entry)
    }

    // ── Low-confidence statistics ─────────────────────────────────────────────

    private func updateLowConfidenceStats() {
        guard totalFrames > 0 else { return }
        var counts: [VNHumanBodyPoseObservation.JointName: Int] = [:]
        for entry in frameEntries {
            func check(_ conf: Float, _ name: VNHumanBodyPoseObservation.JointName) {
                if conf < AppConfig.minJointConfidence { counts[name, default: 0] += 1 }
            }
            check(entry.leftKneeConf, .leftKnee)
            check(entry.rightKneeConf, .rightKnee)
            check(entry.leftAnkleConf, .leftAnkle)
            check(entry.rightAnkleConf, .rightAnkle)
            check(entry.leftHipConf, .leftHip)
            check(entry.rightHipConf, .rightHip)
        }
        lowConfidencePercent = counts.mapValues { Double($0) / Double(totalFrames) * 100.0 }
    }

    // ── CSV export ────────────────────────────────────────────────────────────

    /// Write frame and event CSVs to the app's Documents directory.
    /// Returns the file URLs for display / sharing.
    @discardableResult
    func exportCSV() throws -> (framesURL: URL, eventsURL: URL) {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        let framesURL = docs.appendingPathComponent("frames_\(stamp)_\(sessionID.prefix(8)).csv")
        let eventsURL = docs.appendingPathComponent("events_\(stamp)_\(sessionID.prefix(8)).csv")

        // Frames CSV
        var framesCSV = FrameLogEntry.csvHeader() + "\n"
        framesCSV += frameEntries.map { $0.csvRow() }.joined(separator: "\n")
        try framesCSV.write(to: framesURL, atomically: true, encoding: .utf8)

        // Events CSV
        var eventsCSV = EventLogEntry.csvHeader() + "\n"
        eventsCSV += eventEntries.map { $0.csvRow() }.joined(separator: "\n")
        try eventsCSV.write(to: eventsURL, atomically: true, encoding: .utf8)

        return (framesURL, eventsURL)
    }

    /// Clear all logged data (e.g. before a new run).
    func reset() {
        frameEntries.removeAll()
        eventEntries.removeAll()
        totalFrames = 0
        lowConfidencePercent = [:]
    }
}
