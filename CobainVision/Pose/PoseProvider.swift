// PoseProvider.swift
// MovementPrompt PoC
//
// Protocol that any pose source must implement.
// VisionPoseProvider is the M1 implementation.
// Future implementations (ARKit body tracking, synthetic mock) can conform
// to this protocol without touching any other code.

import Foundation

/// A source of body-pose frames.
/// Implementations deliver frames via an AsyncStream; the caller iterates
/// with `for await frame in provider.frames { … }`.
protocol PoseProvider: AnyObject {
    /// Continuous stream of detected pose frames.
    /// The stream ends when `stop()` is called.
    var frames: AsyncStream<PoseFrame> { get }

    /// Activate the underlying hardware / session.
    /// - Throws: `PoseProviderError` if the source cannot be started.
    func start() async throws

    /// Deactivate the source and finish the stream.
    func stop()
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Errors
// ─────────────────────────────────────────────────────────────────────────────

enum PoseProviderError: LocalizedError {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
    case permissionDenied
    case sessionInterrupted(reason: String)

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:        return "Front camera not available on this device."
        case .cannotAddInput:           return "Cannot add camera input to capture session."
        case .cannotAddOutput:          return "Cannot add video output to capture session."
        case .permissionDenied:         return "Camera permission denied. Enable it in Settings."
        case .sessionInterrupted(let r): return "Capture session interrupted: \(r)"
        }
    }
}
