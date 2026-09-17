//
//  CameraFrame.swift
//  glance
//
//  The capture frame itself and the one crop operation everything downstream shares.
//  Deliberately free of AVFoundation: nothing here needs a capture device, which keeps
//  the recognition path compilable — and benchmarkable — without a camera session.
//

import CoreImage
import CoreVideo
import CoreGraphics

/// A single captured frame. Reference type with lock-guarded lazy caches: the same frame is read
/// from the main actor (preview/debug UI) and from a detached recognition task, and the derived
/// CGImage must only ever be built once.
///
/// `pixelBuffer` is the capture buffer itself — the zero-copy path Vision and vImage consume.
/// `image` is a bounded-size CGImage built on first use, for UI and for code that still wants
/// CoreGraphics. Nothing on the unlock hot path touches `image`.
nonisolated final class CameraFrame: @unchecked Sendable {
    let id: UInt64
    let pixelBuffer: CVPixelBuffer
    /// Native sensor-frame dimensions, i.e. `pixelBuffer`'s own size.
    let sourceSize: CGSize

    private let lock = NSLock()
    private var cachedImage: CGImage?
    private var cachedImageResolved = false
    private var cachedSource: CIImage?

    /// Long-edge cap for the derived `image`. Only affects the debug/preview path.
    private static let maxWorkingEdge: CGFloat = 640

    init(id: UInt64, pixelBuffer: CVPixelBuffer) {
        self.id = id
        self.pixelBuffer = pixelBuffer
        self.sourceSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
    }

    /// Full-resolution lazy CIImage over the capture buffer. Free to ask for; costs nothing until rendered.
    var source: CIImage {
        lock.lock()
        defer { lock.unlock() }
        if let cachedSource { return cachedSource }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        cachedSource = image
        return image
    }

    /// Downscaled CGImage of the whole frame, rendered at most once per frame and only if asked for.
    /// `nil` only if Core Image failed to render, which callers treat as "skip this frame".
    var image: CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if cachedImageResolved { return cachedImage }
        cachedImageResolved = true

        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let longEdge = max(ciImage.extent.width, ciImage.extent.height)
        if longEdge > Self.maxWorkingEdge {
            let scale = Self.maxWorkingEdge / longEdge
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        cachedImage = FrameCropper.sharedRenderContext.createCGImage(ciImage, from: ciImage.extent)
        return cachedImage
    }
}

/// Crop rendering, kept alongside the frame it reads from.
nonisolated enum FrameCropper {
    /// Renders a native-resolution crop around `imageRect` from the frame's capture buffer.
    ///
    /// This single crop serves both jobs that need real pixels: `FaceAligner` warps it into the
    /// canonical 112x112 the embedder expects, and the liveness glare cue scans it for the screen
    /// texture, moiré and gloss a downscaled frame throws away. Rendering it once — instead of a
    /// whole-frame image for alignment plus a separate crop for liveness — is the difference
    /// between two full-frame Core Image renders per frame and one small one.
    ///
    /// `imageRect` is in `frame.sourceSize` pixel space, the space `FaceDetector` reports boxes in
    /// when detection runs against the capture buffer.
    /// Context kept around the face for the liveness cues, as a fraction of the face box. The
    /// alignment's own requirement is handled separately and unioned in — see `covering`.
    private static let livenessContext: CGFloat = 0.35

    /// Renders one native-resolution crop that serves both jobs needing real pixels: the canonical
    /// warp `FaceAligner` performs, and the texture/gloss scan the liveness cues perform.
    ///
    /// - Parameter covering: the region the alignment warp will sample, from
    ///   `FaceAligner.requiredSourceRect`. The crop is grown to contain it. Sizing the crop by a
    ///   fixed multiple of the face box instead — which is what this did — works at arm's length and
    ///   fails at laptop distance, where the template reaches proportionally further above the box
    ///   than any single constant can cover.
    static func renderCrop(
        from frame: CameraFrame,
        imageRect: CGRect,
        covering required: CGRect? = nil,
        maxEdge: CGFloat = 640
    ) -> FaceCrop? {
        var wanted = imageRect.insetBy(
            dx: -imageRect.width * livenessContext,
            dy: -imageRect.height * livenessContext
        )
        if let required {
            // A little past what the warp strictly needs, so interpolation at the very edge of the
            // template still has a neighbouring pixel to read.
            wanted = wanted.union(required.insetBy(dx: -required.width * 0.04, dy: -required.height * 0.04))
        }

        let sourceExtent = CGRect(origin: .zero, size: frame.sourceSize)
        let real = wanted.intersection(sourceExtent)
        guard !real.isEmpty else { return nil }
        // Keep the full requested rect even where it runs off the sensor. Sitting close to a laptop
        // puts the top of the alignment template above the top of the frame; clamping there would
        // hand the warp a crop it cannot align from. `clampedToExtent` replicates the edge pixels
        // instead, so the warp always has something to read and the landmarks — which are all inside
        // the real region — still land on the canonical template positions.
        let rect = wanted

        // Core Image is bottom-left/y-up; `rect` is top-left/y-down.
        let ciRect = CGRect(
            x: rect.minX,
            y: frame.sourceSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )

        var cropped = frame.source.clampedToExtent().cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))

        var scale: CGFloat = 1
        let longEdge = max(rect.width, rect.height)
        if longEdge > maxEdge {
            scale = maxEdge / longEdge
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        guard let image = sharedRenderContext.createCGImage(cropped, from: cropped.extent) else { return nil }

        func intoCrop(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - rect.minX) * scale, y: (r.minY - rect.minY) * scale,
                   width: r.width * scale, height: r.height * scale)
        }
        return FaceCrop(
            image: image,
            sourceRect: rect,
            scale: scale,
            realRectInCrop: intoCrop(real),
            faceRectInCrop: intoCrop(imageRect)
        )
    }

    /// `CIContext` is expensive to create and safe to reuse concurrently.
    static let sharedRenderContext = CIContext(options: [.cacheIntermediates: false])


}
