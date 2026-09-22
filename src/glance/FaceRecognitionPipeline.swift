//
//  FaceRecognitionPipeline.swift
//  glance
//
//  Only place that should construct a FaceEmbedder — keeps all consumers in sync.
//

import Foundation
import CoreGraphics
import Observation

nonisolated struct FaceRecognitionResult {
    let embedding: [Float]
    /// What was actually fed to the embedder, for debug UIs to inspect.
    let alignedImage: CGImage
    let alignmentTier: AlignmentTier
    let quality: Float?
    let face: DetectedFace
}

nonisolated enum FaceRecognitionPipelineError: LocalizedError {
    case noFaceDetected
    case alignmentFailed

    var errorDescription: String? {
        switch self {
        case .noFaceDetected: return "No face detected in frame."
        case .alignmentFailed: return "Could not align the detected face."
        }
    }
}

/// `@Observable` so the debug UI can surface which embedder is active.
@Observable
@MainActor
final class FaceRecognitionPipeline {
    nonisolated let embedder: FaceEmbedder

    /// Set when ArcFace failed to load (see tools/convert_arcface.py) and the weaker Vision feature-print embedder is in use instead.
    private(set) var usingFallbackEmbedder: Bool
    private(set) var fallbackReason: String?

    init() {
        do {
            embedder = try ArcFaceEmbedder()
            usingFallbackEmbedder = false
            fallbackReason = nil
        } catch {
            embedder = VisionFeaturePrintEmbedder()
            usingFallbackEmbedder = true
            fallbackReason = error.localizedDescription
        }
    }

    /// `nonisolated` so callers can run detect/align/embed from a background task instead of blocking the main actor.
    /// - Parameter previousBoundingBox: previous frame's selected box, if any — lets a continuous scanner keep selection "stuck" to the same person instead of re-picking every frame.
    nonisolated func recognize(in frame: CGImage, preferNear previousBoundingBox: CGRect? = nil) throws -> FaceRecognitionResult {
        let faces = try FaceDetector.detectFaces(in: frame)
        guard let face = Self.selectDominantFace(in: faces, preferNear: previousBoundingBox) else {
            throw FaceRecognitionPipelineError.noFaceDetected
        }
        return try recognize(face, in: frame)
    }

    /// Capture-path entry point: detects against the frame's pixel buffer and, only if a face is
    /// actually there, renders the one small crop that alignment and the liveness cues share.
    ///
    /// A frame with nobody in it therefore costs a single Vision pass and zero rendered pixels — the
    /// previous whole-frame-CGImage path paid a full Core Image render on every frame either way.
    /// The returned `FaceCrop` is handed back so the caller can feed liveness without re-rendering it.
    /// - Parameter includeQuality: runs Vision's capture-quality pass as well. The unlock loop leaves
    ///   this off — it costs a second Vision pass per frame for a number nothing on that path reads.
    ///   Anything that *stores* a sample must turn it on, because `FaceSample.qualityTier` is what
    ///   flags a bad enrollment later, and a `nil` quality is silently treated as "unrated" rather
    ///   than as "unknown, go and measure it".
    nonisolated func recognize(
        in frame: CameraFrame,
        preferNear previousBoundingBox: CGRect? = nil,
        includeQuality: Bool = false
    ) throws -> (result: FaceRecognitionResult, crop: FaceCrop) {
        let faces = try FaceDetector.detectFaces(in: frame.pixelBuffer, includeQuality: includeQuality)
        guard let face = Self.selectDominantFace(in: faces, preferNear: previousBoundingBox) else {
            throw FaceRecognitionPipelineError.noFaceDetected
        }
        guard let crop = FrameCropper.renderCrop(
            from: frame,
            imageRect: face.boundingBox,
            covering: FaceAligner.requiredSourceRect(for: face)
        ) else {
            throw FaceRecognitionPipelineError.alignmentFailed
        }

        let inputImage: CGImage
        let tier: AlignmentTier
        if embedder.requiresAlignment {
            guard let aligned = FaceAligner.align(face, in: crop) else {
                throw FaceRecognitionPipelineError.alignmentFailed
            }
            inputImage = aligned.image
            tier = aligned.tier
        } else {
            inputImage = crop.image
            tier = .paddedCrop
        }

        let embedding = try embedder.embedding(for: inputImage)
        let result = FaceRecognitionResult(
            embedding: embedding, alignedImage: inputImage,
            alignmentTier: tier, quality: face.quality, face: face
        )
        return (result, crop)
    }

    /// Aligns and embeds an already-chosen face; enrollment uses this to bypass the prominence filter so a too-small face reads as "move closer" rather than "nobody there".
    nonisolated func recognize(_ face: DetectedFace, in frame: CGImage) throws -> FaceRecognitionResult {
        let inputImage: CGImage
        let tier: AlignmentTier
        if embedder.requiresAlignment {
            guard let aligned = FaceAligner.align(face, from: frame) else {
                throw FaceRecognitionPipelineError.alignmentFailed
            }
            inputImage = aligned.image
            tier = aligned.tier
        } else {
            guard let cropped = FaceDetector.crop(face, from: frame) else {
                throw FaceRecognitionPipelineError.alignmentFailed
            }
            inputImage = cropped
            tier = .paddedCrop
        }

        let embedding = try embedder.embedding(for: inputImage)
        return FaceRecognitionResult(embedding: embedding, alignedImage: inputImage, alignmentTier: tier, quality: face.quality, face: face)
    }

    /// Same as `recognize(_:in:)` but sourced from a capture frame, so enrollment aligns a face exactly
    /// the way the unlock path will later: from a native-resolution crop, not from a downscaled working
    /// image. Enrolling through a different alignment than you match through leaves a systematic offset
    /// between the stored template and every live embedding compared against it.
    nonisolated func recognize(_ face: DetectedFace, in frame: CameraFrame) throws -> FaceRecognitionResult {
        guard let crop = FrameCropper.renderCrop(
            from: frame,
            imageRect: face.boundingBox,
            covering: FaceAligner.requiredSourceRect(for: face)
        ) else {
            throw FaceRecognitionPipelineError.alignmentFailed
        }

        let inputImage: CGImage
        let tier: AlignmentTier
        if embedder.requiresAlignment {
            guard let aligned = FaceAligner.align(face, in: crop) else {
                throw FaceRecognitionPipelineError.alignmentFailed
            }
            inputImage = aligned.image
            tier = aligned.tier
        } else {
            inputImage = crop.image
            tier = .paddedCrop
        }

        let embedding = try embedder.embedding(for: inputImage)
        return FaceRecognitionResult(
            embedding: embedding, alignedImage: inputImage,
            alignmentTier: tier, quality: face.quality, face: face
        )
    }

    // Flip test-time augmentation was tried here and removed. On the previous w600k_r50 backbone it
    // was worth +1.3 points on occluded faces; on glintr100 it moves the worst-case occluded score
    // from 0.429 to 0.430 — nothing — while doubling embedding cost from 9.6ms to 19.3ms per frame,
    // which the scan loop cannot afford. The stronger backbone already captures what the mirror pass
    // was recovering.

    /// Largest face by area with no prominence cutoff — unlike `selectDominantFace`, so enrollment can tell "too far" apart from "no face".
    nonisolated static func largestFace(in faces: [DetectedFace]) -> DetectedFace? {
        faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }

    /// Below this fraction of frame width, a face is treated as a bystander, not a candidate — shared with onboarding's "move closer" prompt. `nonisolated(unsafe)` because it's read from a background-task static func that can't touch AppSettings' MainActor-isolated storage.
    nonisolated(unsafe) static var minimumProminentFaceWidth: Float = 0.18

    /// Max normalized-coordinate drift between frames still counted as "the same person".
    nonisolated private static let continuityDistanceTolerance: CGFloat = 0.3

    /// Picks the person actually at the camera, not a bystander: filters out faces below `minimumProminentFaceWidth`, then prefers continuity with `previousBoundingBox` over raw largest-by-area so two similarly-sized faces can't flip-flop the selection frame to frame and starve the liveness/wrong-face streaks of agreement.
    nonisolated static func selectDominantFace(in faces: [DetectedFace], preferNear previousBoundingBox: CGRect? = nil) -> DetectedFace? {
        let candidates = faces.filter { $0.normalizedBoundingBox.width >= CGFloat(minimumProminentFaceWidth) }
        guard !candidates.isEmpty else { return nil }

        if let previous = previousBoundingBox {
            let previousCenter = CGPoint(x: previous.midX, y: previous.midY)
            if let nearest = candidates.min(by: { distance(from: $0, to: previousCenter) < distance(from: $1, to: previousCenter) }),
               distance(from: nearest, to: previousCenter) < continuityDistanceTolerance {
                return nearest
            }
        }

        return candidates.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }

    nonisolated private static func distance(from face: DetectedFace, to point: CGPoint) -> CGFloat {
        let center = CGPoint(x: face.normalizedBoundingBox.midX, y: face.normalizedBoundingBox.midY)
        return hypot(center.x - point.x, center.y - point.y)
    }
}

nonisolated struct ScoredIdentity {
    let identity: FaceIdentity
    /// Similarity against the identity's averaged template.
    let centroidSimilarity: Float
    /// Similarity against the single closest individual sample — catches
    /// cases where averaging blurred together poses that shouldn't be
    /// blended.
    let maxSampleSimilarity: Float
}

extension FaceRecognitionPipeline {
    /// Sorted by centroid similarity descending; includes stale identities (different embedder) since `bestMatch` is what excludes them from actually matching.
    nonisolated func score(_ embedding: [Float], against identities: [FaceIdentity]) -> [ScoredIdentity] {
        // ArcFace embeddings and the templates averaged from them are already unit length, so the
        // cosine is just the dot product. Re-deriving both norms for every enrolled sample, on every
        // frame of a scan, is work with a known answer.
        let areUnit = embedder.producesUnitEmbeddings
        let similarity: ([Float], [Float]) -> Float = { a, b in
            areUnit
                ? FaceEmbedding.cosineSimilarityOfUnitVectors(a, b)
                : FaceEmbedding.cosineSimilarity(a, b)
        }

        return identities.compactMap { identity in
            guard let template = identity.template, !identity.samples.isEmpty else { return nil }
            let centroidSim = similarity(embedding, template)
            let maxSim = identity.samples
                .map { similarity(embedding, $0.embedding) }
                .max() ?? centroidSim
            return ScoredIdentity(identity: identity, centroidSimilarity: centroidSim, maxSampleSimilarity: maxSim)
        }.sorted { max($0.centroidSimilarity, $0.maxSampleSimilarity) > max($1.centroidSimilarity, $1.maxSampleSimilarity) }
    }

    /// Shared by Face Lab and FaceUnlockCoordinator so tuning stays consistent. No runner-up margin check: the same person can be enrolled multiple times under different appearances, so two of their own profiles legitimately score close together — a margin check can't tell that apart from two different people colliding.
    nonisolated func bestMatch(in scored: [ScoredIdentity], threshold: Float) -> ScoredIdentity? {
        guard let first = scored.first, !first.identity.isStale(comparedTo: embedder) else { return nil }
        // Either route is enough. Requiring *both* — which this used to do — is the strictest of the
        // four possible rules and it was costing real recognitions: with a quarter of the face
        // covered it accepted 82.2% of genuine attempts where this rule accepts 91.6%, measured on
        // LFW through this pipeline. The two routes answer different questions and a face that
        // clearly satisfies one should not be refused for failing the other.
        //
        // The centroid averages every enrolled pose, so it is the steadier signal for a face close
        // to how you enrolled; the closest single sample is what catches a live frame that happens
        // to resemble one particular enrolled pose and not the average of all nine. Neither is
        // weaker than the other against an impostor: at the shipped threshold this rule accepted
        // 0 of ~55,000 impostor comparisons.
        guard max(first.centroidSimilarity, first.maxSampleSimilarity) >= threshold else { return nil }
        return first
    }
}
