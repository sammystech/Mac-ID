//
//  CropAppearance.swift
//  glance
//
//  One rasterization of the native-resolution face crop, two spoof signals out of it:
//  the existing specular/gloss measurements (`GlareSample`) and the printed-photo
//  measurements (`PrintSample`). Both used to mean their own `CGContext.draw` plus their
//  own full scan of the pixels; they need exactly the same bytes, so they share a pass.
//

import CoreGraphics
import Accelerate

nonisolated enum CropAppearanceAnalyzer {
    /// Near-white, near-gray pixel — signature of a direct specular highlight vs. a bright colored surface.
    private static let specularLumaFloor: Float = 235
    private static let specularChromaTolerance: Float = 10

    /// Coarse on purpose — just distinguishes "one blob" from "many scattered points".
    private static let clusterGridSize = 8

    /// Lags, in pixels, searched for a periodic bump in the high-pass residual. The lower bound
    /// skips lag 1, which is dominated by sensor noise and demosaic correlation rather than scene
    /// content; the upper bound is past any beat coarse enough to still be called texture.
    private static let minPeriodLag = 2
    private static let maxPeriodLag = 16

    /// Returns `nil` only if the crop couldn't be rasterized.
    /// `measuring` is in `faceCrop`'s pixel space; nil measures the whole image.
    static func analyze(faceCrop: CGImage, measuring region: CGRect? = nil) -> (glare: GlareSample, print: PrintSample)? {
        var faceCrop = faceCrop
        if let region {
            let bounds = CGRect(x: 0, y: 0, width: faceCrop.width, height: faceCrop.height)
            let clipped = region.integral.intersection(bounds)
            if clipped.width >= 32, clipped.height >= 32, let sub = faceCrop.cropping(to: clipped) {
                faceCrop = sub
            }
        }

        let width = faceCrop.width
        let height = faceCrop.height
        guard width > 0, height > 0 else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = rgba.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(
                data: buffer.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return nil }
        context.draw(faceCrop, in: CGRect(x: 0, y: 0, width: width, height: height))

        let pixelCount = width * height

        // Deinterleave once into float planes; every measurement below is then a vectorized
        // pass rather than a per-pixel Swift loop with bounds checks.
        var red = [Float](repeating: 0, count: pixelCount)
        var green = [Float](repeating: 0, count: pixelCount)
        var blue = [Float](repeating: 0, count: pixelCount)
        rgba.withUnsafeBufferPointer { bytes in
            guard let base = bytes.baseAddress else { return }
            base.withMemoryRebound(to: UInt8.self, capacity: pixelCount * 4) { raw in
                vDSP_vfltu8(raw, 4, &red, 1, vDSP_Length(pixelCount))
                vDSP_vfltu8(raw.advanced(by: 1), 4, &green, 1, vDSP_Length(pixelCount))
                vDSP_vfltu8(raw.advanced(by: 2), 4, &blue, 1, vDSP_Length(pixelCount))
            }
        }

        let n = vDSP_Length(pixelCount)

        // BT.601 luma and chroma, matching the original scalar formulation exactly.
        var luma = [Float](repeating: 0, count: pixelCount)
        var cb = [Float](repeating: 0, count: pixelCount)
        var cr = [Float](repeating: 0, count: pixelCount)
        weightedSum(red, green, blue, 0.299, 0.587, 0.114, into: &luma, count: n)
        weightedSum(red, green, blue, -0.168736, -0.331264, 0.5, into: &cb, count: n)
        weightedSum(red, green, blue, 0.5, -0.418688, -0.081312, into: &cr, count: n)
        var chromaOffset: Float = 128
        vDSP_vsadd(cb, 1, &chromaOffset, &cb, 1, n)
        vDSP_vsadd(cr, 1, &chromaOffset, &cr, 1, n)

        let glare = measureSpecular(
            luma: luma, cb: cb, cr: cr, width: width, height: height
        )

        let printSample = PrintSample(
            cropPixelWidth: CGFloat(width),
            texturePeriodicity: measurePeriodicity(luma: luma, width: width, height: height),
            chromaSpread: measureChromaSpread(cb: cb, cr: cr, count: pixelCount),
            specularFraction: glare.specularFraction
        )

        return (glare, printSample)
    }

    /// `out = wR*R + wG*G + wB*B`, done as three fused passes.
    private static func weightedSum(
        _ r: [Float], _ g: [Float], _ b: [Float],
        _ wr: Float, _ wg: Float, _ wb: Float,
        into out: inout [Float], count: vDSP_Length
    ) {
        var wr = wr, wg = wg, wb = wb
        vDSP_vsmul(r, 1, &wr, &out, 1, count)
        vDSP_vsma(g, 1, &wg, out, 1, &out, 1, count)
        vDSP_vsma(b, 1, &wb, out, 1, &out, 1, count)
    }

    // MARK: - Specular (gloss cue)

    private static func measureSpecular(
        luma: [Float], cb: [Float], cr: [Float], width: Int, height: Int
    ) -> GlareSample {
        var gridCounts = [Int](repeating: 0, count: clusterGridSize * clusterGridSize)
        var specularTotal = 0

        luma.withUnsafeBufferPointer { l in
            cb.withUnsafeBufferPointer { b in
                cr.withUnsafeBufferPointer { r in
                    for y in 0..<height {
                        let rowBase = y * width
                        let gy = min(clusterGridSize - 1, y * clusterGridSize / height)
                        for x in 0..<width {
                            let i = rowBase + x
                            guard l[i] >= specularLumaFloor,
                                  abs(b[i] - 128) <= specularChromaTolerance,
                                  abs(r[i] - 128) <= specularChromaTolerance
                            else { continue }
                            specularTotal += 1
                            let gx = min(clusterGridSize - 1, x * clusterGridSize / width)
                            gridCounts[gy * clusterGridSize + gx] += 1
                        }
                    }
                }
            }
        }

        let pixelCount = width * height
        let specularFraction = Float(specularTotal) / Float(pixelCount)
        let largestCluster = gridCounts.max() ?? 0
        let clusterRatio = specularTotal > 0 ? Float(largestCluster) / Float(specularTotal) : 0

        return GlareSample(
            cropPixelWidth: CGFloat(width),
            specularFraction: specularFraction,
            specularClusterRatio: clusterRatio
        )
    }

    // MARK: - Chroma spread (print cue)

    private static func measureChromaSpread(cb: [Float], cr: [Float], count: Int) -> Float {
        var meanCb: Float = 0, sdCb: Float = 0
        var meanCr: Float = 0, sdCr: Float = 0
        vDSP_normalize(cb, 1, nil, 1, &meanCb, &sdCb, vDSP_Length(count))
        vDSP_normalize(cr, 1, nil, 1, &meanCr, &sdCr, vDSP_Length(count))
        // Typical live-skin crops land around 4-10 here; ink-on-paper compresses toward 1-3.
        return sqrt(sdCb * sdCb + sdCr * sdCr)
    }

    // MARK: - Periodicity (print cue)

    /// Looks for a *local bump* in the autocorrelation of the high-pass residual.
    ///
    /// Natural texture — skin pores, stubble, sensor noise — has an autocorrelation that falls off
    /// monotonically with lag. A repeating pattern does not: it puts a local maximum at its period.
    /// Scoring the bump relative to its own neighbours (rather than the absolute correlation) is what
    /// keeps a smooth, heavily-blurred face from scoring the same as a patterned one.
    private static func measurePeriodicity(luma: [Float], width: Int, height: Int) -> Float {
        // Analyze a centered square patch: the middle of the face box is mostly skin, and keeping
        // the eyes/mouth/hair edges out avoids scoring real structure as if it were a pattern.
        let side = min(width, height) / 2
        guard side >= 64 else { return 0 }
        let originX = (width - side) / 2
        let originY = (height - side) / 2

        var patch = [Float](repeating: 0, count: side * side)
        luma.withUnsafeBufferPointer { l in
            for row in 0..<side {
                let source = (originY + row) * width + originX
                let destination = row * side
                patch.withUnsafeMutableBufferPointer { p in
                    guard let dst = p.baseAddress, let src = l.baseAddress else { return }
                    dst.advanced(by: destination).update(from: src.advanced(by: source), count: side)
                }
            }
        }

        // High-pass: subtract a 3-tap-separable box blur. Removes illumination and skin tone,
        // leaving texture and any pattern beat.
        let residual = highPassResidual(patch, side: side)

        let horizontal = autocorrelationPeak(residual, side: side, rowStride: side, step: 1)
        let vertical = autocorrelationPeak(residual, side: side, rowStride: side, step: side)
        return max(max(horizontal, vertical), 0)
    }

    private static func highPassResidual(_ patch: [Float], side: Int) -> [Float] {
        var blurred = [Float](repeating: 0, count: side * side)
        // Horizontal 3-tap mean, then vertical — separable, so 6 adds per pixel instead of 9.
        patch.withUnsafeBufferPointer { src in
            guard let s = src.baseAddress else { return }
            blurred.withUnsafeMutableBufferPointer { dst in
                guard let d = dst.baseAddress else { return }
                for y in 0..<side {
                    let row = y * side
                    for x in 0..<side {
                        let left = s[row + max(x - 1, 0)]
                        let mid = s[row + x]
                        let right = s[row + min(x + 1, side - 1)]
                        d[row + x] = (left + mid + right) / 3
                    }
                }
            }
        }
        var vertical = [Float](repeating: 0, count: side * side)
        blurred.withUnsafeBufferPointer { src in
            guard let s = src.baseAddress else { return }
            vertical.withUnsafeMutableBufferPointer { dst in
                guard let d = dst.baseAddress else { return }
                for y in 0..<side {
                    let up = max(y - 1, 0) * side
                    let mid = y * side
                    let down = min(y + 1, side - 1) * side
                    for x in 0..<side {
                        d[mid + x] = (s[up + x] + s[mid + x] + s[down + x]) / 3
                    }
                }
            }
        }

        var residual = [Float](repeating: 0, count: side * side)
        vDSP_vsub(vertical, 1, patch, 1, &residual, 1, vDSP_Length(side * side))
        return residual
    }

    /// Autocorrelation across `step`-spaced lags, scored for peakiness rather than magnitude.
    private static func autocorrelationPeak(_ residual: [Float], side: Int, rowStride: Int, step: Int) -> Float {
        let count = residual.count
        var energy: Float = 0
        vDSP_svesq(residual, 1, &energy, vDSP_Length(count))
        guard energy > 1e-6 else { return 0 }

        var correlations = [Float](repeating: 0, count: maxPeriodLag + 2)
        for lag in 1...(maxPeriodLag + 1) {
            let offset = lag * step
            guard offset < count else { break }
            let overlap = count - offset
            var dot: Float = 0
            residual.withUnsafeBufferPointer { r in
                guard let base = r.baseAddress else { return }
                vDSP_dotpr(base, 1, base.advanced(by: offset), 1, &dot, vDSP_Length(overlap))
            }
            correlations[lag] = dot / energy
        }

        // A bump means this lag correlates better than both of its neighbours — the shape a
        // repeating pattern makes, and the shape monotonic texture falloff never makes.
        var best: Float = 0
        for lag in minPeriodLag...maxPeriodLag where lag + 1 < correlations.count {
            let bump = correlations[lag] - (correlations[lag - 1] + correlations[lag + 1]) / 2
            best = max(best, bump)
        }
        return best
    }
}

/// Retained as a thin wrapper so `tools/glare_cue_probe.swift` keeps working unchanged.
nonisolated enum GlareCueExtractor {
    static func extract(faceCrop: CGImage) -> GlareSample? {
        CropAppearanceAnalyzer.analyze(faceCrop: faceCrop)?.glare
    }
}
