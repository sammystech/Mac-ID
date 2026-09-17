//
//  GlareCue.swift
//  glance
//
//  Pixel-domain half of the gloss/glare cue (see `LivenessCues.glossGlare`);
//  no Vision/CoreImage import, so it stays usable from `tools/liveness_selftest.swift`.
//  Populated by `GlareCueExtractor.extract(faceCrop:)`.
//

import CoreGraphics

struct GlareSample: Equatable {
    /// Native pixel width of the measured crop; `renderCrop` only ever downsamples, so this
    /// is an honest detail measure — the cue confidence-weights down as it shrinks.
    let cropPixelWidth: CGFloat

    /// Fraction of crop pixels that are near-saturated and low-chroma — direct specular reflection.
    let specularFraction: Float

    /// How concentrated the specular pixels are into one region (densest 8x8 grid cell's
    /// share) vs. scattered — distinguishes glass glare from a shiny forehead.
    let specularClusterRatio: Float
}

/// Measurements that argue a flat printed photo is being held up to the camera.
///
/// Nothing here is a proof on its own — each one has an innocent explanation (a matte
/// complexion, flat studio lighting, a low-detail crop). The `printedPhoto` cue in
/// `LivenessCues` is what combines them, and it deliberately requires the texture signal
/// *and* the matte signal together before it will convict.
struct PrintSample: Equatable {
    /// Native pixel width of the measured crop; below ~120px none of this is trustworthy.
    let cropPixelWidth: CGFloat

    /// Strength of a *periodic* component in the high-frequency residual.
    ///
    /// Raw autocorrelation bump height, not rescaled — measured values are ~0.08-0.23 for
    /// photographs of real faces and ~0.31-0.63 for the same faces re-rendered through a
    /// halftone screen at a one-camera-pixel period. Keep it raw so the ramp in
    /// `LivenessCues.printedPhoto` stays readable against those numbers.
    ///
    /// This is the moiré signal. A print's halftone or inkjet dither is far too fine to
    /// resolve directly at webcam distance — at ~20px/cm a 150 LPI screen has a period of
    /// about a third of a pixel — but a fine periodic pattern sampled below its Nyquist
    /// limit does not vanish, it aliases into a coarse low-frequency beat, and *that* is
    /// plainly resolvable. Skin texture is broadband and its autocorrelation decays
    /// monotonically; a beat pattern puts a local bump in it at the beat period.
    let texturePeriodicity: Float

    /// Spread of the chroma channels across the crop, normalized. Live skin varies —
    /// subsurface scattering and blood perfusion make cheeks, nose and forehead differ.
    /// Ink on paper compresses that gamut, so a print reads flatter.
    let chromaSpread: Float

    /// Fraction of pixels that are specular highlights (same measurement the gloss cue uses).
    /// Matte paper returns essentially none; skin almost always returns some.
    let specularFraction: Float
}
