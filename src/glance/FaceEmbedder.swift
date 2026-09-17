//
//  FaceEmbedder.swift
//  glance
//
//  Two implementations: `VisionFeaturePrintEmbedder` (Apple's built-in, but only ~5-7% similarity gap between people —
//  too thin to gate unlock on) and `ArcFaceEmbedder` (real face-discriminative model).
//

import Vision
import CoreGraphics
import Accelerate

/// `nonisolated` so implementations can run on a background task despite the project's default main-actor isolation.
protocol FaceEmbedder: Sendable {
    /// Name shown in the debug UI so it's obvious which embedder produced a given saved sample.
    nonisolated var name: String { get }
    /// Persisted alongside every sample; `SecureFaceStore` uses it to refuse comparing across different embedders
    /// (which wouldn't error, just produce confident nonsense).
    nonisolated var modelIdentifier: String { get }
    /// Declared output length, for cross-model mismatch detection without running an embedding first.
    nonisolated var embeddingDimension: Int { get }
    /// Whether this embedder needs a canonically-aligned input (ArcFace) vs. tolerating a loose crop (Vision feature-print).
    nonisolated var requiresAlignment: Bool { get }
    /// Whether `embedding(for:)` already returns unit-length vectors, letting scoring skip recomputing norms.
    nonisolated var producesUnitEmbeddings: Bool { get }
    nonisolated func embedding(for face: CGImage) throws -> [Float]
}

enum FaceEmbedderError: LocalizedError {
    case noObservation
    case unsupportedElementType

    var errorDescription: String? {
        switch self {
        case .noObservation:
            return "Vision did not produce a feature print for this image."
        case .unsupportedElementType:
            return "Feature print used an unexpected element type."
        }
    }
}

struct VisionFeaturePrintEmbedder: FaceEmbedder {
    nonisolated let name = "Vision Feature Print"
    nonisolated let modelIdentifier = "vision-feature-print-v1"
    // Nominal hint only — `modelIdentifier` is the real discriminator `SecureFaceStore` relies on.
    nonisolated let embeddingDimension = 2048
    nonisolated let requiresAlignment = false
    // Vision hands back raw feature-print floats; nothing normalizes them before they're stored.
    nonisolated let producesUnitEmbeddings = false

    nonisolated func embedding(for face: CGImage) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: face, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw FaceEmbedderError.noObservation
        }
        return try Self.floatVector(from: observation)
    }

    /// Decodes Vision's raw bytes + element type into `[Float]` so it can persist as plain JSON and be averaged.
    nonisolated private static func floatVector(from observation: VNFeaturePrintObservation) throws -> [Float] {
        let count = observation.elementCount
        switch observation.elementType {
        case .float:
            var result = [Float](repeating: 0, count: count)
            observation.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let buffer = raw.bindMemory(to: Float.self)
                for i in 0..<count { result[i] = buffer[i] }
            }
            return result
        case .double:
            var result = [Float](repeating: 0, count: count)
            observation.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let buffer = raw.bindMemory(to: Double.self)
                for i in 0..<count { result[i] = Float(buffer[i]) }
            }
            return result
        default:
            throw FaceEmbedderError.unsupportedElementType
        }
    }
}

nonisolated enum FaceEmbedding {
    /// Scales `vector` to unit length; matters once vectors are combined (see `average` below).
    static func l2Normalized(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return vector }
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = norm.squareRoot()
        guard norm > 0 else { return vector }
        var result = [Float](repeating: 0, count: vector.count)
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }

    /// Cosine similarity, range -1...1. The raw value ArcFace thresholds are quoted in.
    ///
    /// Scored against every enrolled sample on every frame of a scan, so the scalar triple-accumulator
    /// loop this replaces was doing 512 unfused multiply-adds per comparison on the unlock hot path.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let n = vDSP_Length(a.count)
        var dot: Float = 0
        var squaredA: Float = 0
        var squaredB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, n)
        vDSP_svesq(a, 1, &squaredA, n)
        vDSP_svesq(b, 1, &squaredB, n)
        guard squaredA > 0, squaredB > 0 else { return 0 }
        return dot / (squaredA.squareRoot() * squaredB.squareRoot())
    }

    /// Fast path for vectors already known to be unit length — both stored templates and freshly
    /// produced embeddings are L2-normalized, so the norms are 1 and the dot product *is* the cosine.
    static func cosineSimilarityOfUnitVectors(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }

    /// For the legacy Vision-feature-print UI only. Don't use to tune ArcFace thresholds — use `cosineSimilarity` directly.
    static func similarityPercent(_ a: [Float], _ b: [Float]) -> Double {
        let similarity = cosineSimilarity(a, b)
        return Double((similarity + 1) / 2) * 100
    }

    /// Normalize each sample, average, then renormalize — a plain element-wise mean would let a larger-magnitude
    /// sample silently dominate.
    static func average(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        let count = first.count
        var sum = [Float](repeating: 0, count: count)
        var contributing: Float = 0
        for vector in vectors where vector.count == count {
            let normalized = l2Normalized(vector)
            vDSP_vadd(sum, 1, normalized, 1, &sum, 1, vDSP_Length(count))
            contributing += 1
        }
        guard contributing > 0 else { return nil }
        var divisor = contributing
        var mean = [Float](repeating: 0, count: count)
        vDSP_vsdiv(sum, 1, &divisor, &mean, 1, vDSP_Length(count))
        return l2Normalized(mean)
    }
}
