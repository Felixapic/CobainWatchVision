// VisionPoseProvider.swift
// MovementPrompt PoC
//
// AVFoundation + Vision implementation of PoseProvider.
//
// ── Camera setup ───────────────────────────────────────────────────────────
// • Uses the front-facing wide-angle camera.
// • Sets videoRotationAngle = 90 on the AVCaptureVideoDataOutput connection
//   so the pixel buffer arrives in portrait orientation (height > width).
// • The pixel buffer is NOT mirrored (AVCaptureVideoDataOutput never mirrors;
//   only the preview layer does).
//
// ── Vision orientation ──────────────────────────────────────────────────────
// • Passes CGImagePropertyOrientation.up to VNImageRequestHandler because the
//   buffer has already been rotated to portrait by the connection setting.
// • Result: Vision joint coordinates are in portrait space, origin bottom-left,
//   y increases up. Vision leftXxx = LEFT of portrait = person's RIGHT side.
//   See PoseFrame.swift and GestureDefinitions.swift for the full mapping.
//
// ── Privacy ─────────────────────────────────────────────────────────────────
// • Camera frames are NEVER saved. Only joint coordinates and confidences
//   (already normalised 0…1 values) leave this class.

import AVFoundation
import Vision
import CoreImage
import QuartzCore
import Combine

final class VisionPoseProvider: NSObject, PoseProvider, ObservableObject {

    // ── Public ───────────────────────────────────────────────────────────────

    /// The capture session — exposed so the UI can attach a preview layer.
    let captureSession = AVCaptureSession()

    let frames: AsyncStream<PoseFrame>

    // ── Private ───────────────────────────────────────────────────────────────

    private var continuation: AsyncStream<PoseFrame>.Continuation?

    /// Serial queue for camera callbacks and Vision requests.
    private let videoQueue = DispatchQueue(
        label: "com.poc.movementprompt.video",
        qos: .userInteractive
    )

    /// VNDetectHumanBodyPoseRequest is reused across frames for efficiency.
    private lazy var bodyPoseRequest: VNDetectHumanBodyPoseRequest = {
        let req = VNDetectHumanBodyPoseRequest()
        // Revision 1 is available iOS 14+; use the latest available.
        // No explicit revision set → Vision picks the best available model.
        return req
    }()

    private var frameIndex: Int = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var rollingFPS: Double = 0

    // ── Init ─────────────────────────────────────────────────────────────────

    override init() {
        var cont: AsyncStream<PoseFrame>.Continuation?
        // Buffer only the newest frame; drop stale frames when the consumer is slow.
        self.frames = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            cont = continuation
        }
        super.init()
        self.continuation = cont
    }

    // ── PoseProvider ─────────────────────────────────────────────────────────

    func start() async throws {
        try await checkPermission()
        try await setupCaptureSessionAsync()
        await startSession()
    }

    private func setupCaptureSessionAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            videoQueue.async { [weak self] in
                guard let self = self else { return }
                do {
                    try self.setupCaptureSession()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        videoQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
        continuation?.finish()
    }

    // ── Permission ───────────────────────────────────────────────────────────

    private func checkPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { throw PoseProviderError.permissionDenied }
        default:
            throw PoseProviderError.permissionDenied
        }
    }

    // ── Session setup ─────────────────────────────────────────────────────────

    private func setupCaptureSession() throws {
        guard captureSession.inputs.isEmpty else { return }
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .high

        // Front camera
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .front
        ) else {
            throw PoseProviderError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw PoseProviderError.cannotAddInput
        }
        captureSession.addInput(input)

        // Video data output
        let output = AVCaptureVideoDataOutput()
        // YpCbCr 4:2:0 — compatible with VNImageRequestHandler
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)

        guard captureSession.canAddOutput(output) else {
            throw PoseProviderError.cannotAddOutput
        }
        captureSession.addOutput(output)

        // Rotate the pixel buffer to portrait so Vision receives an upright image.
        // This means we pass .up to VNImageRequestHandler (no further rotation needed).
        // videoRotationAngle is an iOS 17+ API; our deployment target is iOS 17+.
        if let connection = output.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }

        // Set the target FPS via the active format's frame rate range.
        // A mismatch is not fatal — Vision will run at whatever rate the hardware delivers.
        if let range = device.activeFormat.videoSupportedFrameRateRanges.first {
            let fps = Double(AppConfig.targetFPS)
            if range.minFrameRate <= fps && fps <= range.maxFrameRate {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.unlockForConfiguration()
            }
        }
    }

    // ── Start / stop ─────────────────────────────────────────────────────────

    private func startSession() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            videoQueue.async { [weak self] in
                self?.captureSession.startRunning()
                continuation.resume()
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
// ─────────────────────────────────────────────────────────────────────────────

extension VisionPoseProvider: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // ── FPS tracking ──────────────────────────────────────────────────
        let captureTime = CACurrentMediaTime()
        let elapsed = captureTime - lastFrameTime
        if lastFrameTime > 0, elapsed > 0 {
            let instant = 1.0 / elapsed
            rollingFPS = rollingFPS == 0
                ? instant
                : rollingFPS * (1.0 - AppConfig.fpsEMAWeight) + instant * AppConfig.fpsEMAWeight
        }
        lastFrameTime = captureTime
        frameIndex += 1

        // ── Vision request ────────────────────────────────────────────────
        // .up because videoOrientation = .portrait aligns with portrait orientation.
        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            orientation: .up,
            options: [:]
        )

        do {
            try handler.perform([bodyPoseRequest])
        } catch {
            // Vision errors (e.g. invalid buffer) are non-fatal; skip this frame.
            return
        }

        guard let observation = bodyPoseRequest.results?.first else {
            // No person detected in this frame — do not yield a frame.
            // This allows the downstream consumer to distinguish "no person"
            // from "person detected with low-confidence joints".
            return
        }

        // ── Build PoseFrame ───────────────────────────────────────────────
        let frame = PoseFrame.make(
            from: observation,
            timestamp: captureTime,
            frameIndex: frameIndex,
            fps: rollingFPS
        )

        // Yield into the AsyncStream (thread-safe).
        continuation?.yield(frame)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Dropped frames are expected when Vision is slower than the camera.
        // The bufferingNewest(1) policy on the stream handles this gracefully.
    }
}
