//
//  CameraManager.swift
//  glance
//
//  Owns the AVCaptureSession and publishes the newest camera frame. Runs entirely on-device.
//
//  The capture callback deliberately does *no* pixel work: it retains the sample buffer's
//  `CVPixelBuffer` and publishes. Everything downstream (Vision detection, alignment, liveness)
//  reads that buffer directly, so a frame nobody looks at costs nothing. Rendering a CGImage per
//  captured frame — which is what this used to do — meant a full GPU render plus readback at the
//  camera's frame rate whether or not the recognizer ever consumed the result.
//

@preconcurrency import AVFoundation
import CoreImage
import Observation

enum CameraPermission {
    case notDetermined
    case granted
    case denied
}

@Observable
@MainActor
final class CameraManager: NSObject {
    private(set) var permission: CameraPermission = .notDetermined
    private(set) var isRunning: Bool = false
    private(set) var currentFrame: CameraFrame?
    private(set) var errorMessage: String?

    /// Exposed read-only so `CameraPreviewView` can attach a preview layer to the same session.
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.samuelmittman.macid.camera.session")

    /// Handed to the delegate outside the actor; only ever touched via `Task { @MainActor ... }`.
    private let framePublisher = FramePublisher()

    override init() {
        super.init()
        framePublisher.owner = self
    }

    func start() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            permission = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permission = granted ? .granted : .denied
        default:
            permission = .denied
        }

        guard permission == .granted else {
            errorMessage = "Camera access not granted (status: \(describe(status))). " +
                (status == .restricted
                    ? "macOS reports this as *restricted* — not a simple user denial. This usually means Screen Time content restrictions or an MDM/profile policy is blocking camera access for this app; toggling it in System Settings > Privacy & Security > Camera won't help until that restriction is lifted."
                    : "Enable it in System Settings > Privacy & Security > Camera. If Mac ID isn't listed there, quit the app, run `tccutil reset Camera \(Bundle.main.bundleIdentifier ?? "com.garymittman.macid")` in Terminal, then relaunch so macOS asks again.")
            return
        }

        errorMessage = nil
        configureSessionIfNeeded()
        reconcileDeviceIfNeeded()

        sessionQueue.async { [session] in
            if !session.isRunning {
                session.startRunning()
            }
        }
        isRunning = true
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
        isRunning = false
        currentFrame = nil
    }

    private func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private var isConfigured = false
    private var currentInput: AVCaptureDeviceInput?

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        session.beginConfiguration()
        session.sessionPreset = .high

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(framePublisher, queue: sessionQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()
    }

    /// Called on every `start()` so a camera preference change in Settings takes effect without an app restart.
    private func reconcileDeviceIfNeeded() {
        guard let device = CameraDeviceCatalog.resolvedDevice() else {
            errorMessage = "No camera device found."
            return
        }
        guard device.uniqueID != currentInput?.device.uniqueID else { return }

        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
        }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            selectRecognitionFormat(for: device)
        } else {
            currentInput = nil
            errorMessage = "No camera device found."
        }
        session.commitConfiguration()
    }

    /// Detection and liveness both saturate well below the sensor's maximum, so this picks the *smallest*
    /// format that still clears `preferredWidth` at a usable frame rate rather than the largest available.
    ///
    /// Picking the maximum — which this used to do — is close to free on a 1080p built-in FaceTime camera but
    /// catastrophic on anything else: a Studio Display is 12MP and a Continuity Camera iPhone offers 4032x3024.
    /// Every megapixel there is pure cost, paid on every frame, for detail the 112x112 embedder never sees.
    private func selectRecognitionFormat(for device: AVCaptureDevice) {
        /// Comfortably above what Vision needs for landmarks, and enough native detail for the
        /// glare/moiré spoof cues, which only ever sample a <=448px crop.
        let preferredWidth: Int32 = 1280
        let minimumFrameRate: Double = 24

        func dimensions(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        }
        func supportsFrameRate(_ format: AVCaptureDevice.Format) -> Bool {
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= minimumFrameRate }
        }
        func pixels(_ format: AVCaptureDevice.Format) -> Int {
            let d = dimensions(format)
            return Int(d.width) * Int(d.height)
        }

        let usable = device.formats.filter(supportsFrameRate)
        let pool = usable.isEmpty ? device.formats : usable

        // Smallest format at or above the target width; if the camera can't reach it, the largest it has.
        let atOrAboveTarget = pool.filter { dimensions($0).width >= preferredWidth }
        let chosen = atOrAboveTarget.min { pixels($0) < pixels($1) }
            ?? pool.max { pixels($0) < pixels($1) }

        guard let chosen else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen
            // Cap the capture rate too: the recognizer consumes frames on its own cadence, and a 60fps
            // format otherwise doubles the callback traffic for frames that are immediately discarded.
            let cap = CMTime(value: 1, timescale: 30)
            if chosen.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 }) {
                device.activeVideoMinFrameDuration = cap
            }
            device.unlockForConfiguration()
        } catch {
            errorMessage = "Couldn't configure the camera format: \(error.localizedDescription)"
        }
    }

    fileprivate func publish(frame: CameraFrame) {
        currentFrame = frame
    }

    /// Sample-buffer callbacks arrive on `sessionQueue`. This does no pixel work at all — it retains the
    /// buffer and hops to the main actor to publish.
    private final class FramePublisher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        weak var owner: CameraManager?
        private var nextFrameID: UInt64 = 0

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            nextFrameID &+= 1
            let frame = CameraFrame(id: nextFrameID, pixelBuffer: pixelBuffer)

            Task { @MainActor [weak owner] in
                owner?.publish(frame: frame)
            }
        }
    }
}
