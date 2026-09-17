//
//  DeviceBezelDetector.swift
//  glance
//
//  Looks for a held rectangle around the face — a phone or tablet bezel, or the edge of a
//  sheet of paper — via VNDetectRectanglesRequest; only ever produces positive evidence of
//  spoofing, never positive evidence of liveness.
//

import Vision
import CoreGraphics
import CoreVideo

struct DeviceBezelObservation {
    /// Largest device-plausible rectangle found this frame, same pixel space as `DetectedFace.boundingBox`.
    let rectangle: CGRect?
    /// Fraction of the face's bounding box area that falls inside `rectangle`.
    let faceOverlapFraction: CGFloat?

    nonisolated static let none = DeviceBezelObservation(rectangle: nil, faceOverlapFraction: nil)
}

nonisolated enum DeviceBezelDetector {
    /// First-pass estimates, not validated against real footage — tune here if false positives/negatives show up.
    private static func makeRequest() -> VNDetectRectanglesRequest {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.6
        // Fraction of image area, not width/height.
        request.minimumSize = 0.15
        request.maximumObservations = 3
        // Covers phone-in-portrait (0.35) through landscape paper. The old 1.0 ceiling meant a
        // printed photo held the wide way — 4x6 at 1.5, A4/Letter landscape at ~1.4 — was simply
        // invisible to this cue. Widening it costs nothing in false positives because the overlap
        // test below still requires the rectangle to sit on top of the face.
        request.minimumAspectRatio = 0.35
        request.maximumAspectRatio = 1.8
        // Generous so a phone held at a slight angle still registers.
        request.quadratureTolerance = 30

        return request
    }

    /// Zero-copy variant: a general rectangle detector is one of the more expensive things on the
    /// liveness path, and reading the capture buffer directly at least spares it a rendered frame.
    /// Callers should also rate-limit it — a phone held up to the camera does not appear and vanish
    /// between consecutive frames.
    static func detect(in pixelBuffer: CVPixelBuffer, faceBoundingBox: CGRect) -> DeviceBezelObservation {
        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        return detect(
            handler: VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]),
            imageSize: imageSize,
            faceBoundingBox: faceBoundingBox
        )
    }

    /// Synchronous and CPU-bound — call from a background task, same as `FaceDetector.detectFaces`.
    static func detect(in image: CGImage, faceBoundingBox: CGRect) -> DeviceBezelObservation {
        detect(
            handler: VNImageRequestHandler(cgImage: image, options: [:]),
            imageSize: CGSize(width: image.width, height: image.height),
            faceBoundingBox: faceBoundingBox
        )
    }

    private static func detect(
        handler: VNImageRequestHandler,
        imageSize: CGSize,
        faceBoundingBox: CGRect
    ) -> DeviceBezelObservation {
        let request = makeRequest()
        guard (try? handler.perform([request])) != nil,
              let results = request.results, !results.isEmpty
        else { return .none }

        let candidates = results.map { FaceDetector.convertToImageSpace($0.boundingBox, imageSize: imageSize) }
        // Largest candidate is assumed to be the device itself, not a smaller qualifying detail.
        guard let largest = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return .none
        }

        let faceArea = faceBoundingBox.width * faceBoundingBox.height
        guard faceArea > 0 else { return DeviceBezelObservation(rectangle: largest, faceOverlapFraction: nil) }
        let intersection = largest.intersection(faceBoundingBox)
        let overlap = (intersection.width * intersection.height) / faceArea
        return DeviceBezelObservation(rectangle: largest, faceOverlapFraction: overlap)
    }
}
