//
//  FaceAligner.swift
//  glance
//
//  ArcFace requires faces warped into a canonical pose (eyes level, fixed positions) — a loose crop tanks its accuracy.
//  Solves the 2D similarity transform mapping 5 detected landmarks onto the standard ArcFace template, then warps.
//
//  The warp runs against a small pre-rendered face crop rather than the whole camera frame. Drawing a
//  1280x720 frame through a transform into a 112x112 context makes Core Graphics resample the entire
//  source at high quality to fill 12,544 pixels; warping a ~448px crop does the same job on ~2% of the
//  data, and that crop is already being rendered for the liveness glare cue.
//

import Vision
import CoreGraphics

struct AlignedFace {
    let image: CGImage   // 112x112, canonically aligned
    let tier: AlignmentTier
}

enum AlignmentTier: String {
    case fivePoint = "5-point"
    case twoPoint = "2-point (eyes only)"
    case paddedCrop = "padded crop (no alignment)"
}

/// A native-resolution crop around a detected face, plus what it takes to map full-frame
/// coordinates into it. Produced once per processed frame and shared by alignment and liveness.
nonisolated struct FaceCrop {
    let image: CGImage
    /// The region of the full frame this crop covers, in top-left-origin pixel space.
    let sourceRect: CGRect
    /// `image` pixels per source pixel — below 1 when the crop was downsampled to the render cap.
    let scale: CGFloat
    /// The part of this crop backed by real camera pixels, in crop space. Anything outside it is
    /// edge-replicated: good enough for the warp to read, but not evidence of anything.
    let realRectInCrop: CGRect
    /// The detected face box expressed in this crop's own pixel space. Liveness measures relative to
    /// this rather than to a fixed fraction of the crop, because the crop is sized by what the
    /// alignment needs and so varies with how close the person is — a tuned gloss threshold must not
    /// move just because someone leaned in.
    let faceRectInCrop: CGRect

    /// Maps a point in full-frame pixel space into this crop's own pixel space.
    func convert(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - sourceRect.minX) * scale, y: (point.y - sourceRect.minY) * scale)
    }
}

nonisolated enum FaceAligner {
    static let outputSize = 112

    /// Standard ArcFace 112x112 template: left eye, right eye, nose, left mouth, right mouth. "Left"/"right" are
    /// on-screen, not anatomical — see the ordering fix in `fivePoints(from:imageSize:)`.
    private static let referencePoints: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]
    private static let eyeReferencePoints = Array(referencePoints[0...1])

    /// Reused across every alignment — creating a device RGB color space per frame is pure overhead.
    private static let workingColorSpace = CGColorSpaceCreateDeviceRGB()

    // MARK: - What the template needs

    /// The region of the frame the canonical warp will sample, in top-left pixel space.
    ///
    /// The crop has to be built around *this*, not around a guessed multiple of the face box. The
    /// template reaches well past Vision's rectangle — further above it the closer the face is — so
    /// a fixed padding that is generous at arm's length runs off the top of the frame at laptop
    /// distance, and the warp then has nothing to read. Returns nil when there are no usable
    /// landmarks, in which case the caller falls back to padding the box.
    static func requiredSourceRect(for face: DetectedFace) -> CGRect? {
        guard let landmarks = face.landmarks,
              let points = fivePoints(from: landmarks, imageSize: face.imageSize),
              let transform = LandmarkGeometry.solveSimilarityTransform(
                  from: points, to: referencePoints
              )
        else { return nil }

        let determinant = transform.a * transform.d - transform.b * transform.c
        guard abs(determinant) > 1e-9 else { return nil }
        let inverse = transform.inverted()

        let output = CGFloat(outputSize)
        let corners = [
            CGPoint(x: 0, y: 0), CGPoint(x: output, y: 0),
            CGPoint(x: 0, y: output), CGPoint(x: output, y: output),
        ].map { $0.applying(inverse) }

        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Crop-based alignment (the hot path)

    /// Best-effort: 5-point landmarks, falling back to 2-point (eyes only), falling back to a padded crop.
    /// Landmark points are resolved in full-frame space and then mapped into `crop`, so landmark precision
    /// is unaffected by the crop's render scale.
    static func align(_ face: DetectedFace, in crop: FaceCrop) -> AlignedFace? {
        let imageSize = face.imageSize

        if let landmarks = face.landmarks,
           let points = fivePoints(from: landmarks, imageSize: imageSize),
           let warped = warp(crop.image, sourcePoints: points.map(crop.convert),
                             destinationPoints: referencePoints, realBounds: crop.realRectInCrop) {
            return AlignedFace(image: warped, tier: .fivePoint)
        }

        if let landmarks = face.landmarks,
           let eyes = twoPoints(from: landmarks, imageSize: imageSize),
           let warped = warp(crop.image, sourcePoints: eyes.map(crop.convert),
                             destinationPoints: eyeReferencePoints, realBounds: crop.realRectInCrop) {
            return AlignedFace(image: warped, tier: .twoPoint)
        }

        // Deliberately no padded-crop fallback on this path. It exists for the Vision feature-print
        // embedder, which tolerates a loose crop; ArcFace does not, and handing it one produces a
        // confident embedding that is uncorrelated with the same person's aligned embedding. Failing
        // here makes the scan skip the frame and keep looking, which is the honest outcome.
        return nil
    }

    // MARK: - Whole-frame alignment (enrollment, Face Lab, offline tools)

    static func align(_ face: DetectedFace, from image: CGImage) -> AlignedFace? {
        let imageSize = CGSize(width: image.width, height: image.height)
        // Same three-tier fallback as the crop path; the padded-crop tier crops to the face rather
        // than squashing the whole frame into 112x112.
        if let landmarks = face.landmarks,
           let points = fivePoints(from: landmarks, imageSize: imageSize),
           let warped = warp(image, sourcePoints: points, destinationPoints: referencePoints) {
            return AlignedFace(image: warped, tier: .fivePoint)
        }
        if let landmarks = face.landmarks,
           let eyes = twoPoints(from: landmarks, imageSize: imageSize),
           let warped = warp(image, sourcePoints: eyes, destinationPoints: eyeReferencePoints) {
            return AlignedFace(image: warped, tier: .twoPoint)
        }
        guard let cropped = FaceDetector.crop(face, from: image),
              let resized = resize(cropped, to: outputSize) else { return nil }
        return AlignedFace(image: resized, tier: .paddedCrop)
    }

    // MARK: - Landmark extraction
    //
    // Point/centroid/eye-center/transform math lives in `LandmarkGeometry`, shared with the liveness analyzer.

    private static func fivePoints(from landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> [CGPoint]? {
        guard let eyeA = LandmarkGeometry.eyeCenter(pupil: landmarks.leftPupil, eye: landmarks.leftEye, imageSize: imageSize),
              let eyeB = LandmarkGeometry.eyeCenter(pupil: landmarks.rightPupil, eye: landmarks.rightEye, imageSize: imageSize),
              let nose = landmarks.nose, let noseCenter = LandmarkGeometry.centroid(of: nose, imageSize: imageSize),
              let outerLips = landmarks.outerLips else { return nil }

        // Vision's leftEye/rightEye are anatomical, not on-screen — sort by x instead of trusting either label.
        let imageLeftEye = eyeA.x <= eyeB.x ? eyeA : eyeB
        let imageRightEye = eyeA.x <= eyeB.x ? eyeB : eyeA

        let lipPoints = LandmarkGeometry.imagePoints(of: outerLips, imageSize: imageSize)
        guard let imageLeftMouth = lipPoints.min(by: { $0.x < $1.x }),
              let imageRightMouth = lipPoints.max(by: { $0.x < $1.x }) else { return nil }

        return [imageLeftEye, imageRightEye, noseCenter, imageLeftMouth, imageRightMouth]
    }

    private static func twoPoints(from landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> [CGPoint]? {
        guard let eyeA = LandmarkGeometry.eyeCenter(pupil: landmarks.leftPupil, eye: landmarks.leftEye, imageSize: imageSize),
              let eyeB = LandmarkGeometry.eyeCenter(pupil: landmarks.rightPupil, eye: landmarks.rightEye, imageSize: imageSize) else { return nil }
        return eyeA.x <= eyeB.x ? [eyeA, eyeB] : [eyeB, eyeA]
    }

    // MARK: - Warp

    /// Points are given in top-left/y-down space but flipped before solving since CGContext is bottom-left/y-up;
    /// the image itself needs no flip since `CGContext.draw(_:in:)` already handles a CGImage's row order.
    private static func warp(
        _ image: CGImage,
        sourcePoints: [CGPoint],
        destinationPoints: [CGPoint],
        realBounds: CGRect? = nil
    ) -> CGImage? {
        let imageHeight = CGFloat(image.height)
        let sourceFlipped = sourcePoints.map { CGPoint(x: $0.x, y: imageHeight - $0.y) }
        let destinationFlipped = destinationPoints.map { CGPoint(x: $0.x, y: CGFloat(outputSize) - $0.y) }

        guard let transform = LandmarkGeometry.solveSimilarityTransform(from: sourceFlipped, to: destinationFlipped) else { return nil }
        // Refuse a warp that would have to invent pixels. This is the failure mode that produced
        // black corners in the aligned face: the template reaches outside the image, Core Graphics
        // fills the gap with nothing, and the embedder returns a confident embedding computed partly
        // from a black wedge. Nothing downstream can tell that apart from a real face, so it has to
        // be caught here — `align` falls through to a lower tier, which enrollment then rejects.
        guard coverage(of: transform, within: realBounds) >= minimumCoverage else { return nil }

        guard let context = CGContext(
            data: nil,
            width: outputSize, height: outputSize,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: workingColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        return context.makeImage()
    }

    /// How much of the 112x112 output must come from real camera pixels rather than replicated edge.
    ///
    /// Sitting close to a laptop puts the top of ArcFace's template above the top of the frame —
    /// pixels that do not exist. `FrameCropper` replicates the edge there so the warp still has
    /// something to read, which keeps the alignment canonical where it matters (the landmarks are
    /// all real) and costs only a smeared margin. That is far better than the alternative: refusing
    /// to align drops the face to an unaligned padded crop, and an ArcFace embedding of an unaligned
    /// crop is not a weak match, it is noise — measured at cosine -0.09 against the same person's
    /// aligned embedding. This threshold only has to catch the case where most of the face is
    /// invented.
    private static let minimumCoverage: CGFloat = 0.6

    /// Fraction of the output grid that reads from real camera pixels.
    ///
    /// `transform` maps source to destination, so inverting it answers "which source pixel does this
    /// output pixel read from" — the question that matters. Sampled on a coarse grid rather than
    /// solved analytically because the mapped region is a rotated quadrilateral and 49 point
    /// transforms are far cheaper than clipping one polygon against another.
    ///
    /// `bounds` is the region backed by real pixels, in the same space as the transform's source.
    /// Passing nil means every pixel is real (the whole-frame path, which never replicates).
    private static func coverage(of transform: CGAffineTransform, within bounds: CGRect?) -> CGFloat {
        guard let bounds else { return 1 }
        // `inverted()` returns the transform unchanged rather than failing when it is singular,
        // so check the determinant first instead of trusting the result.
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard abs(determinant) > 1e-9 else { return 0 }
        let inverse = transform.inverted()
        let steps = 6
        var inside = 0
        var total = 0
        for i in 0...steps {
            for j in 0...steps {
                let point = CGPoint(
                    x: CGFloat(i) / CGFloat(steps) * CGFloat(outputSize),
                    y: CGFloat(j) / CGFloat(steps) * CGFloat(outputSize)
                )
                total += 1
                if bounds.contains(point.applying(inverse)) { inside += 1 }
            }
        }
        return CGFloat(inside) / CGFloat(total)
    }

    private static func resize(_ image: CGImage, to size: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: workingColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }
}
