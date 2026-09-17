#!/usr/bin/env python3
"""
Converts InsightFace's ArcFace recognition model (w600k_mbf, MobileFaceNet
backbone trained with ArcFace loss) into a Core ML .mlpackage that Glance's
Swift code can load directly.

Pipeline: ONNX (InsightFace's official weights) -> torch (via onnx2torch)
-> traced TorchScript -> Core ML, with preprocessing baked into the model so
Swift only ever hands over a raw RGB 112x112 image.

Usage:
    python3 -m venv .venv && source .venv/bin/activate
    pip install -r tools/requirements.txt
    python tools/convert_arcface.py --variant w600k_mbf

Output:
    glance/Models/ArcFace.mlpackage
        input:  "input_image", 112x112 RGB CVPixelBuffer/CGImage
        output: "embedding", 512 floats (NOT yet L2-normalized — Swift does that)

This script does not modify the Xcode project or any Swift source. It only
produces the model file; wiring it in is a separate, reviewable step.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "glance" / "Models" / "ArcFace.mlpackage"

VARIANT_ONNX_NAMES = {
    "w600k_mbf": "w600k_mbf.onnx",   # buffalo_s pack, ~13MB, MobileFaceNet backbone
    "w600k_r50": "w600k_r50.onnx",   # buffalo_l pack, ~166MB, ResNet50 backbone
}
VARIANT_PACK = {
    "w600k_mbf": "buffalo_s",
    "w600k_r50": "buffalo_l",
}


def fail(message: str) -> None:
    print(f"\nERROR: {message}\n", file=sys.stderr)
    sys.exit(1)


def locate_or_download_onnx(variant: str, explicit_path: str | None) -> Path:
    """Returns a local path to the recognition-model .onnx file.

    Prefers an explicit --onnx-path if given (for when auto-download fails
    or the user already has the weights). Otherwise downloads the official
    InsightFace model pack via the `insightface` package's own model zoo,
    which is the actively-maintained source for these weights — more
    resilient than us hardcoding a URL that could move.
    """
    if explicit_path:
        path = Path(explicit_path).expanduser().resolve()
        if not path.is_file():
            fail(f"--onnx-path does not exist: {path}")
        return path

    try:
        from insightface.app import FaceAnalysis
    except ImportError:
        fail(
            "The 'insightface' package is required to auto-download weights.\n"
            "Install it with: pip install insightface onnxruntime opencv-python\n"
            "Or download w600k_mbf.onnx yourself and pass --onnx-path."
        )

    pack_name = VARIANT_PACK[variant]
    print(f"Downloading InsightFace '{pack_name}' model pack (first run only)...")
    # .prepare() triggers the download+unzip into ~/.insightface/models/<pack>/
    # and validates every model in the pack loads correctly.
    app = FaceAnalysis(name=pack_name, providers=["CPUExecutionProvider"])
    app.prepare(ctx_id=-1)

    model_dir = Path.home() / ".insightface" / "models" / pack_name
    onnx_name = VARIANT_ONNX_NAMES[variant]
    matches = list(model_dir.glob(f"*{onnx_name}"))
    if not matches:
        fail(
            f"Downloaded pack '{pack_name}' but couldn't find {onnx_name} in {model_dir}. "
            f"Contents: {list(model_dir.iterdir()) if model_dir.exists() else 'directory missing'}"
        )
    return matches[0]


def convert_to_coreml(onnx_path: Path, output_path: Path, variant: str = "w600k_mbf") -> None:
    import numpy as np
    import onnx
    import coremltools as ct
    from onnx2torch import convert
    import torch

    print(f"Loading ONNX model from {onnx_path} ({onnx_path.stat().st_size / 1e6:.1f} MB)...")
    onnx_model = onnx.load(str(onnx_path))
    onnx.checker.check_model(onnx_model)

    print("Converting ONNX -> torch (via onnx2torch)...")
    torch_model = convert(onnx_model)
    torch_model.eval()

    dummy_input = torch.randn(1, 3, 112, 112)
    with torch.no_grad():
        traced = torch.jit.trace(torch_model, dummy_input)

    print("Converting torch -> Core ML (preprocessing baked in: RGB, (px-127.5)/127.5)...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="input_image",
                shape=(1, 3, 112, 112),
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )

    # Names the variant actually converted; this string is the only provenance that
    # survives into the built app, and a wrong one makes the bundled weights unidentifiable.
    mlmodel.short_description = f"ArcFace ({variant}) face embedding — 512-d, on-device"
    mlmodel.input_description["input_image"] = "112x112 RGB aligned face crop"
    mlmodel.output_description["embedding"] = "512-float embedding (not L2-normalized)"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(output_path))
    print(f"Saved {output_path}")
    return mlmodel, onnx_path


def verify_parity(mlmodel, onnx_path: Path, reference_images: list[Path] | None = None) -> None:
    """Feeds identical pixels through the original ONNX graph and the converted Core ML
    model and confirms they agree. Shape-only checks would miss a channel-order or scale
    bug — exactly the kind of mistake that silently wrecks ArcFace accuracy without ever
    throwing an error.

    What "agree" means depends on the input, and on a deep backbone the spread is large:

      * A conversion bug (wrong channel order, wrong scale/bias) drives the cosine to
        roughly zero on *any* input. That is the failure this gate has to catch, and the
        0.99 floor below catches it with enormous margin.

      * FLOAT16 quantization costs a few thousandths, and costs the most on inputs the
        model never saw in training. Measured for w600k_r50: ~0.9964 on random uint8
        noise, ~0.9976 on smooth synthetic images, and ~0.9998 on real aligned face
        crops — the only domain the app ever runs it on. Converting the same graph at
        FLOAT32 scores exactly 1.000000 against the same ONNX model, which is what
        establishes that the graph itself is correct.

      * The shallower w600k_mbf clears 0.999 even on noise, which is why the original
        form of this check used that as a blanket threshold. It does not generalize.

    Pass --reference-images with real 112x112 aligned crops for a strict in-domain check;
    without them this reports the synthetic numbers and gates only on the bug floor.
    """
    import numpy as np
    import onnxruntime as ort
    from PIL import Image

    sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    onnx_input_name = sess.get_inputs()[0].name

    def cosine_for(pixels):
        chw = pixels.astype(np.float32).transpose(2, 0, 1)[None]
        reference = sess.run(None, {onnx_input_name: (chw - 127.5) / 127.5})[0].flatten()
        converted = np.array(
            mlmodel.predict({"input_image": Image.fromarray(pixels, mode="RGB")})["embedding"]
        ).flatten()
        if reference.shape != (512,) or converted.shape != (512,):
            fail(f"Unexpected output shape: onnx={reference.shape}, coreml={converted.shape}")
        return float(
            np.dot(reference, converted)
            / (np.linalg.norm(reference) * np.linalg.norm(converted))
        )

    print("\nVerifying ONNX <-> Core ML numerical parity...")
    rng = np.random.default_rng(0)

    noise = min(
        cosine_for(rng.integers(0, 256, size=(112, 112, 3), dtype=np.uint8)) for _ in range(3)
    )
    print(f"  random noise      : {noise:.6f}")

    smooth = min(cosine_for(px) for px in _smooth_synthetic_inputs(rng))
    print(f"  smooth synthetic  : {smooth:.6f}")

    BUG_FLOOR = 0.99
    if min(noise, smooth) < BUG_FLOOR:
        fail(
            f"Parity below {BUG_FLOOR} — too far off to be quantization. Most likely cause: "
            "preprocessing mismatch (channel order RGB vs BGR, or scale/bias). "
            "Re-convert with compute_precision=FLOAT32 to confirm: a correct graph scores 1.000000."
        )

    if reference_images:
        scores = []
        for path in reference_images:
            px = np.asarray(Image.open(path).convert("RGB").resize((112, 112)), dtype=np.uint8)
            scores.append(cosine_for(px))
        worst = min(scores)
        print(f"  real aligned faces: {worst:.6f}  (n={len(scores)}, expect > 0.999)")
        if worst < 0.999:
            fail("Parity failed on real aligned faces — the domain the model is actually used in.")
        print("Parity check passed, including the strict in-domain check.")
    else:
        print(
            "Parity check passed the conversion-bug floor. For the strict in-domain check, "
            "re-run with --reference-images pointing at real 112x112 aligned crops."
        )


def _smooth_synthetic_inputs(rng):
    """Low-frequency, skin-toned images. Not faces — measured parity on these tracks noise
    more closely than it tracks real crops — but enough to exercise a second input regime
    without the converter having to bundle image assets."""
    import numpy as np
    from PIL import Image

    inputs = []
    for _ in range(3):
        coarse = np.clip(rng.normal(0.55, 0.10, size=(9, 9, 3)), 0.05, 0.95)
        smooth = np.asarray(
            Image.fromarray((coarse * 255).astype(np.uint8)).resize((112, 112), Image.BICUBIC),
            dtype=np.float32,
        ) / 255.0
        tone = np.array([1.0, 0.82, 0.72], dtype=np.float32)
        inputs.append((np.clip(smooth * tone, 0, 1) * 255).astype(np.uint8))
    return inputs


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=sorted(VARIANT_ONNX_NAMES), default="w600k_mbf")
    parser.add_argument("--onnx-path", default=None, help="Skip auto-download; use this local .onnx file instead.")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="Output .mlpackage path.")
    parser.add_argument("--skip-verify", action="store_true", help="Skip the ONNX/Core ML parity check.")
    parser.add_argument(
        "--reference-images", nargs="*", default=None,
        help="Real aligned 112x112 face crops for the strict in-domain parity check.",
    )
    args = parser.parse_args()

    onnx_path = locate_or_download_onnx(args.variant, args.onnx_path)
    mlmodel, onnx_path = convert_to_coreml(onnx_path, Path(args.output), args.variant)

    if not args.skip_verify:
        verify_parity(
            mlmodel, onnx_path,
            [Path(p) for p in args.reference_images] if args.reference_images else None,
        )

    print(f"\nDone. Model ready at: {args.output}")
    print("Next: add this file to the Xcode project (glance/Models/ArcFace.mlpackage) if not auto-picked-up,")
    print("then build — ArcFaceEmbedder.swift will load it from the app bundle at runtime.")


if __name__ == "__main__":
    main()
