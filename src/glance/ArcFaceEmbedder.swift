//
//  ArcFaceEmbedder.swift
//  glance
//
//  Requires a canonically-aligned 112x112 input (see FaceAligner) — unlike VisionFeaturePrintEmbedder, accuracy depends on alignment.
//

import CoreML
import CoreGraphics
import CoreVideo
import Accelerate

enum ArcFaceEmbedderError: LocalizedError {
    case modelNotFound
    case modelLoadFailed(String)
    case pixelBufferCreationFailed
    case unexpectedInputSize(got: (Int, Int), expected: Int)
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "ArcFace.mlpackage/mlmodelc not found in the app bundle. Run tools/convert_arcface.py, then add glance/Models/ArcFace.mlpackage to the Xcode project."
        case .modelLoadFailed(let detail):
            return "Failed to load the ArcFace Core ML model: \(detail)"
        case .pixelBufferCreationFailed:
            return "Couldn't prepare the aligned face image for Core ML."
        case .unexpectedInputSize(let got, let expected):
            return "ArcFaceEmbedder expects a \(expected)x\(expected) aligned image, got \(got.0)x\(got.1). Run the face through FaceAligner first."
        case .unexpectedOutput(let detail):
            return "ArcFace model produced an unexpected output: \(detail)"
        }
    }
}

nonisolated final class ArcFaceEmbedder: FaceEmbedder, @unchecked Sendable {
    nonisolated let name = "ArcFace (w600k_r50)"
    /// Bumped from `arcface-w600k_mbf-v1`. `SecureFaceStore` refuses to compare embeddings across
    /// identifiers, so every enrolled face is correctly invalidated by the backbone change rather
    /// than silently scored against a model that produces a different embedding space.
    nonisolated let modelIdentifier = ArcFaceEmbedder.currentModelIdentifier

    /// Single source of truth for "which embedding space is this app using", readable without
    /// constructing an embedder (and therefore without loading 87MB of weights) — `GlanceSettings`
    /// needs it at launch to decide whether a persisted threshold is still meaningful.
    nonisolated static let currentModelIdentifier = "arcface-w600k_r50-v1"

    /// Cosine-similarity operating points for this backbone.
    ///
    /// A threshold is only meaningful for the embedding space it was measured in: swapping the
    /// backbone moves the whole genuine/impostor distribution, so a number carried over from the
    /// previous model is not conservative or liberal, it is simply unrelated. `GlanceSettings`
    /// re-seeds from these whenever `currentModelIdentifier` changes.
    ///
    /// Measured for w600k_r50 through this app's own detect/align path, on 283 LFW faces
    /// (85 identities, 365 genuine and 39,538 impostor pairs):
    ///
    ///   impostor pairs    max 0.288, p99 0.149
    ///   genuine, cross-session (different photo, different day)   min 0.331, median 0.672
    ///   genuine, same-session (consecutive frames of one scan)    min 0.952, median 0.983
    ///
    /// Every value below clears the observed impostor maximum, so none of them accepted a single
    /// impostor pair out of 39,538. The spread between them is therefore not a security/convenience
    /// trade in the usual sense — it is how much appearance drift away from the enrolled samples
    /// the user is willing to tolerate before being asked for a password instead.
    nonisolated static let lessStrictThreshold: Float = 0.38
    nonisolated static let defaultThreshold: Float = 0.45
    nonisolated static let moreStrictThreshold: Float = 0.55
    nonisolated let embeddingDimension = 512
    nonisolated let requiresAlignment = true
    // `embedding(for:)` returns `FaceEmbedding.l2Normalized(...)`, and stored templates are averages
    // of those, which `FaceEmbedding.average` renormalizes.
    nonisolated let producesUnitEmbeddings = true

    private static let inputSize = FaceAligner.outputSize
    private static let inputName = "input_image"
    private static let outputName = "embedding"

    // Loaded once and reused — model load dominates a single inference.
    private let model: MLModel
    private let pixelBufferPool: CVPixelBufferPool
    /// Reused across every render; `CGColorSpaceCreateDeviceRGB()` per call is needless churn.
    private static let renderColorSpace = CGColorSpaceCreateDeviceRGB()

    /// Throws immediately if the model isn't bundled, so callers can fall back to `VisionFeaturePrintEmbedder`.
    init() throws {
        guard let modelURL = Self.locateModel() else {
            throw ArcFaceEmbedderError.modelNotFound
        }

        let configuration = MLModelConfiguration()
        // `.all` lets Core ML pick, which on a cold start can mean a GPU-backed plan with far worse
        // latency and power than the ANE for a model shaped like this one. Restricting the choice keeps
        // the compute path predictable; Core ML still falls back to CPU for any unsupported op.
        configuration.computeUnits = .cpuAndNeuralEngine

        do {
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            throw ArcFaceEmbedderError.modelLoadFailed(error.localizedDescription)
        }

        guard let pool = Self.makePixelBufferPool(size: Self.inputSize) else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        pixelBufferPool = pool

        warmUp()
    }

    /// First prediction pays for ANE program compilation and weight staging — a few hundred ms. Spending it
    /// at init, while the app is idle, keeps it off the first frame of an unlock scan.
    private func warmUp() {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &buffer) == kCVReturnSuccess,
              let buffer,
              let input = try? MLDictionaryFeatureProvider(
                  dictionary: [Self.inputName: MLFeatureValue(pixelBuffer: buffer)]
              )
        else { return }
        _ = try? model.prediction(from: input)
    }

    /// Both names are checked in case the file was added under a different name.
    private static func locateModel() -> URL? {
        for name in ["ArcFace", "w600k_r50", "w600k_mbf"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
                return url
            }
        }
        return nil
    }

    private static func makePixelBufferPool(size: Int) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    /// `MLModel.prediction(from:)` is synchronous/blocking — callers run embedders off the main actor.
    nonisolated func embedding(for face: CGImage) throws -> [Float] {
        guard face.width == Self.inputSize, face.height == Self.inputSize else {
            throw ArcFaceEmbedderError.unexpectedInputSize(got: (face.width, face.height), expected: Self.inputSize)
        }

        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBufferOut)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        try Self.render(face, into: pixelBuffer)

        let input = try MLDictionaryFeatureProvider(dictionary: [Self.inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
        let output = try model.prediction(from: input)

        guard let multiArray = output.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw ArcFaceEmbedderError.unexpectedOutput("no '\(Self.outputName)' output found")
        }
        guard multiArray.count == embeddingDimension else {
            throw ArcFaceEmbedderError.unexpectedOutput("expected \(embeddingDimension) floats, got \(multiArray.count)")
        }

        let raw = try Self.floatVector(from: multiArray)
        return FaceEmbedding.l2Normalized(raw)
    }

    private static func render(_ image: CGImage, into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: renderColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// Reads the output buffer directly instead of going through `MLMultiArray`'s `NSNumber` subscript,
    /// which boxes and unboxes once per element — 512 heap allocations on every single inference, on the
    /// unlock hot path. The contiguous fast path covers what Core ML actually hands back here (a dense
    /// 1x512 Float16 array); the subscript loop stays as a correctness fallback for anything else.
    private static func floatVector(from array: MLMultiArray) throws -> [Float] {
        let count = array.count
        let isContiguous = array.strides.last?.intValue == 1

        if isContiguous {
            switch array.dataType {
            case .float16:
                var result = [Float](repeating: 0, count: count)
                try array.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else {
                        throw ArcFaceEmbedderError.unexpectedOutput("output buffer had no base address")
                    }
                    var source = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: base),
                        height: 1, width: vImagePixelCount(count), rowBytes: count * 2
                    )
                    result.withUnsafeMutableBufferPointer { out in
                        var destination = vImage_Buffer(
                            data: out.baseAddress, height: 1,
                            width: vImagePixelCount(count), rowBytes: count * 4
                        )
                        _ = vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)
                    }
                }
                return result

            case .float32:
                var result = [Float](repeating: 0, count: count)
                try array.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else {
                        throw ArcFaceEmbedderError.unexpectedOutput("output buffer had no base address")
                    }
                    let source = base.assumingMemoryBound(to: Float.self)
                    result.withUnsafeMutableBufferPointer { out in
                        guard let destination = out.baseAddress else { return }
                        destination.update(from: source, count: count)
                    }
                }
                return result

            default:
                break
            }
        }

        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            result[i] = array[i].floatValue
        }
        return result
    }
}
