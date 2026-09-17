//
//  FaceDetector.swift
//  glance
//
//  Converts Vision's normalized (0...1), bottom-left-origin face boxes into pixel-space, top-left-origin `CGRect`s.
//

import Vision
import CoreGraphics
import CoreVideo

struct DetectedFace {
    /// Pixel-space bounding box, top-left origin — ready to crop with.
    let boundingBox: CGRect
    /// Vision's original normalized box — kept as-is since it's the exact format `layerRectConverted(fromMetadataOutputRect:)` expects.
    let normalizedBoundingBox: CGRect
    /// 0...1 confidence from Vision that this is a face, roughly indicating
    /// image quality/pose suitability for recognition. `nil` if the quality
    /// request didn't produce a result for this face — which is the normal case
    /// on the unlock path, where the quality pass is skipped (see `detectFaces`).
    let quality: Float?
    /// Head rotation in radians, when Vision could estimate it. Yaw drives the guided-pose onboarding capture;
    /// roll and pitch are exposed but unused today.
    let yaw: Float?
    let roll: Float?
    let pitch: Float?
    /// Facial landmarks (eyes, nose, mouth, etc.), when available. Feeds
    /// `FaceAligner` for canonical 112x112 alignment ahead of ArcFace.
    nonisolated let landmarks: VNFaceLandmarks2D?
    /// Needed by `landmarks.pointsInImage(_:)` to convert normalized landmark points into `boundingBox`'s pixel space.
    let imageSize: CGSize
}

/// Pure, synchronous, CPU-bound work — `nonisolated` so it can run on a
/// background task despite the project's default main-actor isolation.
nonisolated enum FaceDetector {
    /// Detection runs as a rectangles pass followed by a landmarks pass *chained* to its results via
    /// `inputFaceObservations`, so the second pass only computes landmarks rather than re-detecting.
    ///
    /// It is tempting to collapse this into one self-detecting `VNDetectFaceLandmarksRequest`, and
    /// doing so is marginally faster — but it silently loses head pose. Measured on the same frame:
    ///
    ///     VNDetectFaceLandmarksRequest alone   yaw 0.000  pitch nil    roll 0.000
    ///     VNDetectFaceRectanglesRequest        yaw 0.121  pitch 0.264  roll -0.055
    ///
    /// Only the rectangles request estimates pose. Without it, guided enrollment — which requires a
    /// non-nil yaw *and* pitch before it will accept a frame — detects a face and then discards
    /// every single one of them, and the depth/pose liveness cue never fires either.
    ///
    /// - Parameter includeQuality: also runs `VNDetectFaceCaptureQualityRequest`. Anything that
    ///   stores a sample wants it; the unlock loop doesn't, and it costs a third Vision pass.
    static func detectFaces(in image: CGImage, includeQuality: Bool = false) throws -> [DetectedFace] {
        let imageSize = CGSize(width: image.width, height: image.height)
        return try detect(
            handler: { VNImageRequestHandler(cgImage: image, options: [:]) },
            imageSize: imageSize,
            includeQuality: includeQuality
        )
    }

    /// Zero-copy entry point: Vision reads the capture buffer directly, so a frame with no face in it
    /// never costs a single rendered pixel. Boxes come back in the buffer's own native pixel space.
    static func detectFaces(in pixelBuffer: CVPixelBuffer, includeQuality: Bool = false) throws -> [DetectedFace] {
        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        return try detect(
            handler: { VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]) },
            imageSize: imageSize,
            includeQuality: includeQuality
        )
    }

    private static func detect(
        handler makeHandler: () -> VNImageRequestHandler,
        imageSize: CGSize,
        includeQuality: Bool
    ) throws -> [DetectedFace] {
        let rectangles = VNDetectFaceRectanglesRequest()
        try makeHandler().perform([rectangles])
        let detected = rectangles.results ?? []
        guard !detected.isEmpty else { return [] }

        // Chained, so neither of these re-runs detection; both report against `detected`, in order.
        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.inputFaceObservations = detected
        var requests: [VNRequest] = [landmarks]

        let quality = VNDetectFaceCaptureQualityRequest()
        if includeQuality {
            quality.inputFaceObservations = detected
            requests.append(quality)
        }
        try makeHandler().perform(requests)

        // The landmarks results carry the pose through from the rectangles pass; fall back to the
        // rectangles observations if that pass produced nothing.
        let withLandmarks = landmarks.results ?? []
        let qualityResults = includeQuality ? (quality.results ?? []) : []

        return detected.indices.map { index in
            let observation = withLandmarks.indices.contains(index) ? withLandmarks[index] : detected[index]
            return make(
                observation,
                quality: qualityResults.indices.contains(index) ? qualityResults[index].faceCaptureQuality : nil,
                imageSize: imageSize
            )
        }
    }

    private static func make(_ observation: VNFaceObservation, quality: Float?, imageSize: CGSize) -> DetectedFace {
        DetectedFace(
            boundingBox: convertToImageSpace(observation.boundingBox, imageSize: imageSize),
            normalizedBoundingBox: observation.boundingBox,
            quality: quality,
            yaw: observation.yaw?.floatValue,
            roll: observation.roll?.floatValue,
            pitch: observation.pitch?.floatValue,
            landmarks: observation.landmarks,
            imageSize: imageSize
        )
    }

    /// Vision's normalized rect has origin at bottom-left; `CGImage.cropping`
    /// expects pixel coordinates with origin at top-left. This flips the Y axis.
    static func convertToImageSpace(_ normalizedRect: CGRect, imageSize: CGSize) -> CGRect {
        let x = normalizedRect.origin.x * imageSize.width
        let width = normalizedRect.width * imageSize.width
        let height = normalizedRect.height * imageSize.height
        let y = (1 - normalizedRect.origin.y) * imageSize.height - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Crops `face` out of `image`, padding slightly around the detected box
    /// so the embedder sees a bit of context beyond just eyes/nose/mouth.
    static func crop(_ face: DetectedFace, from image: CGImage, paddingFraction: CGFloat = 0.2) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let padX = face.boundingBox.width * paddingFraction
        let padY = face.boundingBox.height * paddingFraction
        let padded = face.boundingBox.insetBy(dx: -padX, dy: -padY).intersection(imageBounds)
        guard !padded.isEmpty else { return nil }
        return image.cropping(to: padded)
    }
}
