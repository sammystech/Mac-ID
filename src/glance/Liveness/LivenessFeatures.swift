//
//  LivenessFeatures.swift
//  glance
//
//  Vision-facing half of liveness: turns a `FaceRecognitionResult` into a plain,
//  Vision-free `LivenessFrame` — keeps the decision logic compilable standalone.
//

import Vision
import CoreGraphics

nonisolated enum LivenessFeatureExtractor {
    /// Never fails — a face with no landmarks still yields a frame; cues that need landmarks abstain.
    ///
    /// - Parameter frame: the full camera frame, not `result.alignedImage` (a tightly-cropped
    ///   112x112 warp with no room around the face for `DeviceBezelDetector` to see a device edge).
    static func extract(
        from result: FaceRecognitionResult, frame: CGImage, faceCrop: CGImage? = nil, timestamp: Date = Date()
    ) -> LivenessFrame {
        extract(
            from: result,
            deviceOverlapFraction: DeviceBezelDetector.detect(
                in: frame, faceBoundingBox: result.face.boundingBox
            ).faceOverlapFraction,
            appearance: faceCrop.flatMap { CropAppearanceAnalyzer.analyze(faceCrop: $0) },
            timestamp: timestamp
        )
    }

    /// Capture-path entry point. Measures the appearance cues against the face box inside `faceCrop`.
    static func extract(
        from result: FaceRecognitionResult,
        deviceOverlapFraction deviceOverlap: CGFloat?,
        faceCrop: FaceCrop?,
        timestamp: Date = Date()
    ) -> LivenessFrame {
        extract(
            from: result,
            deviceOverlapFraction: deviceOverlap,
            appearance: faceCrop.flatMap { CropAppearanceAnalyzer.analyze(crop: $0) },
            timestamp: timestamp
        )
    }

    /// Variant that takes an already-computed bezel overlap instead of running the rectangle detector
    /// itself, so a caller can rate-limit that detector independently of the per-frame landmark cues.
    /// Passing `nil` means "no bezel evidence this frame", which is exactly how the cue already treats
    /// a frame where no device-shaped rectangle was found.
    static func extract(
        from result: FaceRecognitionResult,
        deviceOverlapFraction deviceOverlap: CGFloat?,
        appearance: (glare: GlareSample, print: PrintSample)?,
        timestamp: Date = Date()
    ) -> LivenessFrame {
        let face = result.face
        let glare = appearance?.glare
        let printSample = appearance?.print

        guard let landmarks = face.landmarks else {
            return LivenessFrame(
                timestamp: timestamp, landmarks: [], interocularDistance: nil,
                yaw: face.yaw,
                leftEyeAspectRatio: nil, rightEyeAspectRatio: nil,
                noseOffsetRatio: nil,
                hasReliableLandmarks: false,
                deviceOverlapFraction: deviceOverlap,
                glare: glare,
                print: printSample
            )
        }

        let imageSize = face.imageSize
        let points = LandmarkGeometry.allPoints(from: landmarks, imageSize: imageSize)
        let interocular = LandmarkGeometry.interocularDistance(from: landmarks, imageSize: imageSize)
        let leftEAR = landmarks.leftEye.flatMap { LandmarkGeometry.eyeAspectRatio(of: $0, imageSize: imageSize) }
        let rightEAR = landmarks.rightEye.flatMap { LandmarkGeometry.eyeAspectRatio(of: $0, imageSize: imageSize) }

        let eyeLeft = LandmarkGeometry.eyeCenter(pupil: landmarks.leftPupil, eye: landmarks.leftEye, imageSize: imageSize)
        let eyeRight = LandmarkGeometry.eyeCenter(pupil: landmarks.rightPupil, eye: landmarks.rightEye, imageSize: imageSize)

        var noseOffsetRatio: CGFloat?
        if let interocular, interocular > 0, let eyeLeft, let eyeRight,
           let nose = landmarks.nose, let noseCenter = LandmarkGeometry.centroid(of: nose, imageSize: imageSize) {
            let eyeMidX = (eyeLeft.x + eyeRight.x) / 2
            noseOffsetRatio = (noseCenter.x - eyeMidX) / interocular
        }

        return LivenessFrame(
            timestamp: timestamp,
            landmarks: points,
            interocularDistance: interocular,
            yaw: face.yaw,
            leftEyeAspectRatio: leftEAR, rightEyeAspectRatio: rightEAR,
            noseOffsetRatio: noseOffsetRatio,
            hasReliableLandmarks: result.alignmentTier == .fivePoint,
            deviceOverlapFraction: deviceOverlap,
            glare: glare,
            print: printSample
        )
    }
}

extension CropAppearanceAnalyzer {
    /// How far past the face box the measured region extends, per side.
    ///
    /// The gloss thresholds in `LivenessTuning` were calibrated against a crop ~1.3x the face box.
    /// The crop itself is sized by what the alignment warp needs, which varies with distance, so the
    /// measurement is pinned to the face box instead — otherwise leaning closer would quietly move a
    /// tuned threshold by changing how much background is averaged in.
    static let measuredPadding: CGFloat = 0.15

    /// Measures the region around the face box within `crop`.
    ///
    /// Lives here rather than in `CropAppearance.swift` so that file keeps needing nothing but
    /// CoreGraphics and Accelerate — `FaceCrop` belongs to the Vision-facing layer, and
    /// `tools/glare_cue_probe.swift` builds the analyzer without it.
    static func analyze(crop: FaceCrop) -> (glare: GlareSample, print: PrintSample)? {
        let box = crop.faceRectInCrop
        let region = box.insetBy(dx: -box.width * measuredPadding, dy: -box.height * measuredPadding)
        return analyze(faceCrop: crop.image, measuring: region)
    }
}
