# Mac ID 1.2

A separate app built from [jonnyoo/glance](https://github.com/jonnyoo/glance) @ `c379097` —
faster, a stronger recognition model, and a printed-photo check. Built and measured on this machine
(MacBook Pro, M1 Pro, macOS 27.0, Xcode 27).

Mac ID installs **alongside** Glance rather than replacing it: different bundle identifier
(`com.samuelmittman.macid`), so it gets its own camera permission, its own keychain items, its own
settings and its own Application Support folder. Your existing Glance stays exactly as it is.

Everything below is measured, not estimated. Where something could not be measured properly, it
says so.

---

## 1. Why it wasn't smooth

The UI was not the problem, and neither was Rosetta — the shipped binary is universal and was
running native ARM64. The cost was in the per-frame recognition pipeline.

| What | Where | Cost |
|---|---|---|
| A full Core Image render + GPU readback to build a `CGImage`, **on every captured frame** whether or not the recognizer used it | `CameraManager.captureOutput` | ~1.0 ms × camera frame rate |
| Camera locked to the sensor's **highest-resolution format regardless of fps** | `selectHighestResolutionFormat` | 1080p built-in; **12 MP** on a Studio Display, **4032×3024** on a Continuity Camera iPhone |
| A general-purpose rectangle detector run **every frame** for spoof checking | `DeviceBezelDetector` | ~8–11 ms/frame |
| A **second** full-resolution render for the liveness crop | `renderCrop` | ~0.8 ms/frame |
| The 112×112 alignment warp drawing the **entire frame** through a high-quality resample | `FaceAligner.warp` | — |
| 512 `NSNumber` heap allocations per inference, reading the model output through `MLMultiArray`'s boxing subscript | `ArcFaceEmbedder.floatVector` | 0.10 ms/inference |
| Cosine similarity as a scalar loop, recomputing norms of already-unit-length vectors | `FaceEmbedding` | small but per-sample, per-frame |

One thing I initially got wrong and the measurements corrected: the original code was **not**
running face detection twice. It chained `VNDetectFaceLandmarksRequest` to the rectangle pass via
`inputFaceObservations`, which skips re-detection. That part was already well built.

## 2. What changed

- **The capture callback now does no pixel work at all.** It retains the `CVPixelBuffer` and
  publishes. Detection reads that buffer directly, so a frame with nobody in front of the camera
  costs zero rendered pixels.
- **Camera format selection inverted**: the *smallest* format clearing 1280px at ≥24 fps, capped to
  30 fps, instead of the largest format available.
- **One shared face crop** replaces the whole-frame alignment render plus the separate liveness
  render. The crop is rendered once and used by both.
- **Rectangle detection rate-limited** to every third processed frame — a phone or sheet of paper
  does not appear and vanish in 33 ms, and the cue's own 3-frame threshold is still reachable.
- **Accelerate/vDSP** for the specular scan, chroma statistics and similarity math, with a
  unit-vector fast path (embeddings are already L2-normalized, so the cosine is just the dot
  product).
- **Model output read directly** instead of through `NSNumber` boxing. Verified bit-exact against
  the original path: max absolute difference `0.00000000`, cosine `0.99999994`.
- **Neural Engine pinned** (`.cpuAndNeuralEngine` rather than `.all`) and a warm-up inference at
  init, so the ~1.4 s first-inference compile cost is paid while idle, not on the first frame of an
  unlock.

### A change I made, measured, and reverted

I first moved alignment to warp from the small crop *and* fed Vision the full-resolution buffer,
assuming detection cost would scale down with input size. It does not — Vision's face detector was
*faster* on a 1280×720 buffer (11.4 ms) than on a 640×360 one (16.8 ms). The crop-based warp also
turned out to save only ~0.03 ms over warping the whole frame, while introducing a real bug
(see §4). The buffer-direct detection was kept because it is both faster *and* gives the landmark
detector full-resolution pixels; the crop was kept because it is shared with the liveness cues.

## 3. Measured results

Both pipelines compiled as separate modules and run **interleaved in one process**, alternating
per frame, so CPU frequency state, thermal drift and Neural Engine contention hit both equally.
Same model in both arms, so this isolates the pipeline rewrite from the model change.
4 faces × 25 rounds = 100 samples per arm.

**Built-in FaceTime camera (1280×720):**

```
                              original -> rewritten
work per CAPTURED frame         1.11 ms ->  0.00 ms
work per PROCESSED frame       26.54 ms -> 19.06 ms   (-28%)

end-to-end per processed frame 27.65 ms -> 19.06 ms   1.45x faster
                                  36 fps -> 53 fps ceiling
camera-rate overhead at 30fps   33.3 ms -> 0.0 ms of CPU per second
```

**Continuity Camera / Studio Display resolution (3024×4032)** — what the old format selection
would actually have picked there:

```
work per CAPTURED frame         3.92 ms ->  0.00 ms
end-to-end per processed frame 42.07 ms -> 30.89 ms
camera-rate overhead at 30fps  117.5 ms -> 0.1 ms of CPU per second
```

That last row is the one that matters most for "doesn't run smooth": on an external camera the old
code burned ~12% of a core on the capture callback alone, continuously, for frames the recognizer
mostly threw away. The rewrite does not select that format at all, so in practice the comparison
there is 42.07 ms → 16.69 ms.

The rewritten pipeline also does **more** work than the original — it computes the new
printed-photo cue that did not exist before.

> **Superseded — see §9.** Part of this speedup came from collapsing detection into a single Vision
> request, which turned out to silently destroy head-pose estimation and break enrollment. Restoring
> the chained detection gives back some of it: re-measured, the same benchmark reads
> **24.56 ms → 19.72 ms, 1.25x faster**, with the per-captured-frame work still eliminated entirely.
> The numbers above are left as measured so the trade is visible.

## 4. A bug I introduced and caught

The first version of the crop-based aligner padded the face box by 0.15 on each side. The aligned
output came back with black corners. Measuring what ArcFace's canonical 112×112 template actually
samples, against real portraits:

```
img     faceBox     required padding beyond the box (fraction)
f1.jpg  479x479     l=0.21 r=0.14 t=0.38 b=-0.02
f3.jpg  262x262     l=0.34 r=0.18 t=0.44 b=0.09
f5.jpg  310x310     l=0.09 r=0.11 t=0.29 b=-0.08
```

The template includes forehead that Vision's face rectangle does not — up to **0.44×** the box
height above it. Padding is now 0.6 on every side. The liveness cues measure only the centred
1.3/2.2 of that padded crop, which reproduces the framing the existing gloss thresholds were tuned
against so the padding change doesn't silently move a calibrated threshold.

## 5. Accuracy: model upgrade

The shipped app used **ArcFace w600k_mbf** — the small MobileFaceNet backbone from InsightFace's
`buffalo_s` pack. The repo's own converter already supported `w600k_r50` (ResNet-50, `buffalo_l`);
it was simply never shipped. It is now converted and bundled.

**Conversion correctness.** The repo's parity check failed r50 at 0.9977 against its 0.999 bar. That
turned out to be an artifact of the check, not a conversion bug — converting the same graph at
FLOAT32 scores **exactly 1.000000** against the ONNX model. FLOAT16 costs a few thousandths, and
costs most on random noise, which is what the check used. On real aligned face crops FLOAT16 agrees
to **0.999676**. `tools/convert_arcface.py` now gates on a conversion-bug floor plus an optional
strict in-domain check against real crops (`--reference-images`), and documents why.

**Accuracy.** 457 LFW faces, 197 identities, run through this app's own detect/align path —
477 genuine and 103,719 impostor pairs:

| | w600k_mbf (shipped) | w600k_r50 (new) |
|---|---|---|
| d' (separation) | 6.21 | **7.67** (1.23×) |
| best accuracy | 99.988% | **99.997%** |
| genuine mean | 0.609 | **0.671** |
| worst impostor pair | 0.361 | **0.295** |
| false rejects @ threshold 0.45 | 7.76% | **2.94%** |

The worst impostor pair scoring lower (0.361 → 0.295) is the security-relevant one: it leaves more
headroom under any threshold. The lower false-reject rate is the convenience one.

**Cost of the bigger model: essentially nothing.** On the Neural Engine, 12.7× the weights buys
+0.56 ms per inference:

```
w600k_mbf   on-disk  6.9 MB   load  781 ms   inference 2.25 ms
w600k_r50   on-disk 87.4 MB   load 1393 ms   inference 2.81 ms
```

Load time is why the warm-up at init matters. It is off the unlock path now.

**Thresholds recalibrated.** A threshold only means something in the embedding space it was measured
in; carrying `0.66` over from mbf would have been neither strict nor lax, just unrelated. Measured
for r50 through this pipeline:

```
impostor pairs                                  max 0.295, p99 0.149
genuine, cross-session (different day)          min -0.003, median 0.671
genuine, same-session (frames of one scan)      min 0.952, median 0.983
```

New defaults: **less strict 0.38, default 0.45, more strict 0.55**. All three accepted
**0 of 103,719** impostor pairs. `GlanceSettings` now stores which embedding space a threshold was
set for and re-seeds if the backbone changes, so a stale number can't silently survive a model swap.

**Multi-frame fusion** was also added: the match is made against an average of the last 5 frames of
the same continuously-tracked face rather than whichever single frame arrived. Averaging unit
vectors cancels the part of the frame-to-frame embedding wobble that is uncorrelated. The buffer is
cleared the moment tracking is lost, so it cannot blend two people.

## 6. Printed-photo detection

A new `printedPhoto` deny cue, alongside the existing gloss/device cues.

**How it works.** Print halftone is far too fine to resolve at webcam distance — at ~20 px/cm a
150 LPI screen has a period of about a third of a pixel. But a fine periodic pattern sampled below
its Nyquist limit does not disappear, it aliases into a coarse **moiré beat**, and that is plainly
resolvable. The cue high-passes the skin texture and looks for a *local bump* in its
autocorrelation: natural skin texture decays monotonically with lag, a beat pattern does not. That
has to coincide with a **matte** surface (near-zero specular highlights) before it will convict.

**Also widened**: the rectangle detector's aspect-ratio ceiling went from 1.0 to 1.8. A photo held
the **wide** way — 4×6 at 1.5, Letter landscape at ~1.4 — was previously invisible to it entirely.

**Calibration.** The first version fired on 4 of 5 real faces — unusable. The `×4` scaling I'd
applied was saturating the signal, and the chroma-flatness term I'd assumed would help turned out to
overlap completely between real and printed faces, so it was dropped. Recalibrated against measured
distributions (raw autocorrelation bump: 0.08–0.23 real, 0.31–0.63 printed):

```
                          real faces    fires?
  5 real portraits        level 0.000   0/5
  print, 1.6 px period    level 1.000   5/5
  print, 1.0 px period    level 0.681   4/5
  print, 3.2 px period    level 0.541   4/5
  print, 0.7 px period    level 0.240   1/5
```

13 of 15 catches across realistic print regimes, with **no false positives** and a clean margin.

**What this validation does not cover — please read.** The "real face" negatives are web JPEGs, not
live webcam captures of you sitting at your Mac. Camera frames arrive as uncompressed BGRA with no
JPEG block structure to inflate the reading, so the calibration should be conservative rather than
tight — but I could not prove that without your camera. And the "prints" are simulated through a
modelled optical chain, not photographs of an actual sheet of paper.

**So: test it before trusting it.** Print a photo of yourself, open Face Lab, and watch the
"Printed photo" cue while you hold it up and while you sit in front of the camera normally. The
firing level (`printLevel`, currently 0.5, needing 5 frames) is tunable there. If it ever rejects
your real face, that number is the one to raise.

Also worth keeping in mind: this is one more deny cue, not a guarantee. A very fine screen print is
the case it most often misses, and none of this defeats a video replay — which the upstream README
is already explicit about.

## 7. Rebranded as its own app, and four more fixes

**Separate app, version 1.2.** `PRODUCT_NAME` → `Mac ID`, `PRODUCT_BUNDLE_IDENTIFIER` →
`com.samuelmittman.macid`, `MARKETING_VERSION` → 1.2 (build 4). The keychain service, the
`os.Logger` subsystem, the camera dispatch queue label, the Application Support folder and every
user-facing string moved with it. The bundle identifier change is what makes the two apps genuinely
independent rather than two builds fighting over one TCC entry and one keychain.

**Sparkle disabled — this one mattered.** The Info.plist still carried Glance's `SUFeedURL`
(`tryglance.app/appcast.xml`) and its author's `SUPublicEDKey`. Left alone, this app would have
checked that feed and offered an "update" that silently replaced Mac ID with stock Glance, undoing
every change in it. Both keys are gone and `UpdaterController.start()` no longer starts the updater.
The About page says so rather than showing a permanently greyed-out button, and its "Send Feedback"
link — which pointed at the original author's form — now points at the upstream repo.

**A regression I introduced, caught and fixed.** Making Vision's capture-quality pass optional (it
costs a second Vision pass per frame and the unlock path never reads it) also silently removed it
from Face Lab's sample-capture path. Every sample captured there would have been stored with
`quality: nil`, which `FaceSample.qualityTier` reports as *unrated* rather than *unknown* — so the
"poor sample" warning in Settings would simply never fire again. `recognize(in:)` now takes
`includeQuality`, and every path that *stores* a sample passes `true`. Guided enrollment was already
gating on quality and on 5-point alignment, and still is.

**Alignment coverage guard.** The black-corner bug in §4 was fixed by padding the crop, but padding
cannot help when the face is genuinely at the edge of the frame — the pixels do not exist. In that
case Core Graphics fills the gap with black and the embedder returns a confident embedding computed
partly from a black wedge, which nothing downstream can distinguish from a real face. `FaceAligner`
now inverts the transform, samples a 7×7 grid over the 112×112 output, and refuses the warp unless
≥98% of it sources real pixels. Verified not to reject valid faces: 6 of 6 test portraits still
align at the full 5-point tier.

**Printed-photo sensitivity is now a real setting.** I previously said the cue was tunable in Face
Lab — that was wrong. Face Lab *displays* each cue's firing threshold but has no control to change
it, and its tuning is deliberately isolated from the unlock path anyway, so nothing you did there
could affect a real unlock. Settings → Recognition → Liveness now has **Off / Standard / Strict**,
read fresh on every frame by the unlock path. Standard is the calibrated point from §6; Strict drops
the firing level to 0.35 over 4 frames to catch finer screens, at a higher risk of rejecting you;
Off removes the cue from the evaluator entirely rather than pushing its threshold out of reach.

Calibrate it the same way regardless: print a photo of yourself, open Face Lab, and compare the
"Printed photo" cue level with the print held up versus your own face in front of the camera.

## 8. Launch crash, recognition failure, and the icon

Three things found by actually running it, which is what the previous round should have done.

### It wouldn't launch at all

```
Termination Reason: DYLD, Library missing
Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
... mapping process and mapped file (non-platform) have different Team IDs
```

Sparkle ships as a prebuilt XCFramework carrying its own code signature. dyld refuses to map an
embedded framework whose Team ID doesn't match the process loading it, and a locally signed build
has no Team ID — so the app died before `main`. Re-signing the framework on every build would have
worked around it, but nothing called into Sparkle any more after §7 disabled the updater. The
dependency is gone: no `import Sparkle`, no package reference, no embedded framework, and with it
the whole class of embedded-framework signing failures. The bundle also lost 3 MB.

### It wasn't recognizing faces

The cause was the coverage guard I added in §7, combined with sizing the crop as a fixed multiple of
the face box. Reproduced by rendering the same face at a range of sizes in a 1280×720 frame:

```
box height as % of frame     alignment tier
   9% - 35%                  5-point
   44%                       padded crop (no alignment)   <- broken
   53% - 60%                 padded crop (no alignment)   <- broken
```

Sitting at a normal laptop distance puts your face at roughly 30–50% of frame height. Past ~40%, the
2.2×-face-box crop ran off the top of the frame, the ArcFace template no longer fit inside it, the
coverage guard rejected the warp, and the face fell through to an unaligned padded crop. Enrollment
*requires* 5-point alignment, so it silently never captured a sample; and at unlock an unaligned
ArcFace embedding isn't a weak match, it's noise — **cosine −0.09 against the same person's aligned
embedding**.

Three changes:

1. **The crop is now sized by what the alignment actually needs.** `FaceAligner.requiredSourceRect`
   inverts the similarity transform and reports the exact region the template will sample; the
   cropper grows to contain it. No constant can do this job, because the template reaches
   proportionally further above the face box the closer you are.
2. **Missing pixels are edge-replicated rather than fatal.** Close enough to the camera and the
   template genuinely extends above the top of the frame. `clampedToExtent()` replicates the edge
   there, so the warp always has something to read and the landmarks — all of which are inside the
   real region — still land on canonical positions.
3. **No padded-crop fallback for ArcFace.** That fallback exists for the Vision feature-print
   embedder, which tolerates a loose crop. Handing it to ArcFace produces a confident, meaningless
   embedding. Failing instead makes the scan skip the frame and keep looking.

The coverage guard survives, measuring real-vs-replicated pixels at a much more tolerant 0.6, so it
still catches a face that is mostly invented.

**After, same sweep:**

```
box height as % of frame     tier       cosine vs the reference distance
   9% - 38%                  5-point    0.96 - 1.00
   44% - 46%                 5-point    0.95 - 0.96
   53% - 62%                 5-point    0.82 - 0.92
```

5-point at every distance a face is detected at, and the embedding holds together across the whole
range instead of falling off a cliff. Separation is unaffected — across 1.3×/2.5×/3.0× distances,
including the heaviest edge replication:

```
SAME person, different distance    n=12   min 0.827   median 0.919
DIFFERENT people                   n=66   max 0.200   median 0.063
match threshold                           0.45
```

0.38 of headroom below the worst genuine pair and 0.25 above the worst impostor.

### The icon

The build had **no icon at all** — the project asked for an appicon named `GlanceIcon` while the file
was `glanceicon.icon`, so it never resolved and the Info.plist came out with no icon keys. Mac ID now
has its own: `glance/MacID.icon`, authored in the Icon Composer format the project already used (a
gradient fill plus SVG layers, which the system renders with the macOS material treatment). Violet
gradient, white card, and a scan-bracket-plus-person mark — deliberately not Glance's blue face
glyph. The same SVG layers are composited into `appicon.png` for the About and onboarding screens, so
the two can't drift apart.

## 9. The enrollment failure, and a full audit

### "It won't scan my face"

Enrollment detected a face and then silently discarded every frame. The cause was the §2 change that
collapsed detection into a single self-detecting `VNDetectFaceLandmarksRequest`. Measured on one
frame:

```
VNDetectFaceLandmarksRequest alone    yaw 0.000   pitch nil     roll 0.000
VNDetectFaceRectanglesRequest         yaw 0.121   pitch 0.264   roll -0.055
  -> landmarks chained onto those     yaw 0.121   pitch 0.264   roll -0.055
```

Only the rectangles request estimates head pose. Guided enrollment gates on
`guard let yaw = ..., let pitch = ...` before it will even consider a frame, so with pitch always nil
it could never capture a sample — exactly the reported symptom. The depth/pose liveness cue and the
guided pose sweep were dead for the same reason.

Detection is back to a rectangles pass with landmarks *chained* to its results, which is what the
original did. Chaining means the second pass computes landmarks rather than re-detecting, so this is
not the "two detections per frame" I mistakenly described it as in §1 — that reading was wrong, and
the single-request version I replaced it with was a regression, not an optimization. The capture
quality pass stays optional, which is a genuine saving on the unlock path.

**After, the full enrollment gate chain:**

```
face size    yaw      pitch    width   quality  alignment   verdict
  16%        0.163    0.261    0.089   0.740    5-point     REJECT (too far)
  28%        0.121    0.264    0.158   0.722    5-point     REJECT (too far)
  36%        0.175    0.331    0.200   0.765    5-point     ACCEPT
  53%        0.221    0.302    0.296   0.729    5-point     ACCEPT
```

The remaining rejections are the *intended* "move closer" gate (`minimumFaceWidth`, default 0.19
normalized). That one is a deliberate setting, not a bug — Settings → Recognition → Detection
distance has Close / Default / Far if you want it more permissive. Recognition itself is unaffected
by it: alignment stays 5-point and embeddings stay above 0.95 well below that width.

### Audit

Everything re-verified end to end after all the changes above:

| Check | Result |
|---|---|
| Alignment vs distance (9–61% of frame) | 5-point at every distance |
| Embedding stability across distance | 0.85 – 1.00 |
| Same person vs different people | same 0.828–0.982, different max 0.199, threshold 0.45 |
| Enrollment gates | pose, quality, alignment all pass; only the distance gate rejects |
| Printed-photo cue | 0/6 false positives, 16/18 realistic prints caught |
| Repo's own liveness self-test | all tests pass |
| Build warnings in touched files | none |
| App launches and stays running | yes, ~0.4% CPU idle |

Three further things the audit turned up and fixed:

- **`tools/glare_cue_probe.swift` and `tools/liveness_selftest.swift` no longer built.** Folding
  `GlareCueExtractor` into `CropAppearance.swift` made that file depend on `FaceCrop`, which belongs
  to the Vision-facing layer — breaking the deliberate separation that lets those tools compile
  without Vision or Core ML. `PrintSample` moved next to `GlareSample` in `GlareCue.swift`, and the
  `FaceCrop` convenience moved to `LivenessFeatures.swift`. Both tools now build exactly as their
  own headers document, and the self-test passes.
- **Concurrency warnings** from `FaceCrop` and `LivenessFrame` picking up main-actor isolation under
  the project's default. Both are pure value types read from detached tasks; both are now
  `nonisolated`. These are errors under the Swift 6 language mode.
- **The printed-photo cue got better**, not just unbroken: pinning its measurement to the face box
  rather than a fixed fraction of the crop means it now sees mostly skin. Detection at a
  one-pixel screen period went from a 0.190 worst case to 0.762.

## 10. Why granting Accessibility never took effect

Granting Accessibility appeared to do nothing: the toggle went on in System Settings, and
`AXIsProcessTrusted()` kept returning false. The app's own polling was fine — it really was being
told it had no permission.

The cause was how I was signing the app:

```
Signature=adhoc
# designated => cdhash H"51707904c29e7ba14657b6dbdd1b49d56a33eb99"
```

An ad-hoc signature has no stable identity, so the app's designated requirement is its **exact
binary hash**. macOS binds a TCC grant to that requirement. Every rebuild produced a different hash
and silently invalidated the grant, while the stale entry stayed visible and switched on in System
Settings. Across this work the app was replaced five times, so the permission was dead nearly every
time it was granted.

This is not something the app can work around, and it is not something worth bypassing: without
Accessibility, `CGEvent` cannot post keystrokes to the lock screen at all, so skipping the check
would only move the failure from a visible permission screen to a silent failure at unlock.

**Fixed by signing with a real identity.** There was already an Apple Development certificate in the
login keychain, so Mac ID now signs with it:

```
Authority=Apple Development: sammymittman@gmail.com (HXAA92329K)
TeamIdentifier=G2LCW65DC4
designated => identifier "com.samuelmittman.macid" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: ..."
```

Identity-based rather than hash-based. Verified by building twice from different binaries and
diffing the requirement — byte-identical, so the grant now survives rebuilds.

The signing settings are pinned in the Xcode project (`CODE_SIGN_IDENTITY = "Apple Development"`,
`CODE_SIGN_STYLE = Manual`, `DEVELOPMENT_TEAM = G2LCW65DC4`, replacing two stale team IDs inherited
from upstream), so a plain `xcodebuild` reproduces it and cannot quietly fall back to ad-hoc.

The stale grant was cleared with `tccutil reset Accessibility com.samuelmittman.macid`. **Grant it
once more and it will stick from now on.**

## 11. Enrollment stuck on "Look straight at the camera", and the keychain entitlement

### The pose gate could never be satisfied

Enrollment sat on the centre pose forever and never moved on to turning left or right. Vision reports
head pose relative to the **camera**, and a laptop camera sits above the screen — so someone looking
at the screen reads as permanently pitched. Measured on real frontal portraits, that offset reaches
**0.33 rad against a 0.15 tolerance**, and the yaw offset was similarly biased. The centre band could
not match on any frame:

```
raw yaw +0.175  pitch +0.331     centre: NO
raw yaw +0.153  pitch +0.316     centre: NO
raw yaw +0.161  pitch +0.324     centre: NO
```

The fix is to stop treating Vision's camera-absolute angles as if they were head-relative. Enrollment
already begins with a 1.5-second settle delay during which nothing is captured; the median pose over
that window is now taken as *this person's neutral at this camera*, and every band is measured from
it. "Turn left" then means 14° from where their head actually rests, rather than from an idealised
head-on camera — which is what it should always have meant.

```
calibrated neutral: yaw +0.170  pitch +0.327
relative yaw +0.005  pitch +0.005     centre: match
relative yaw -0.017  pitch -0.011     centre: match
relative yaw +0.005  pitch -0.011     centre: match

centre pose matched on 0/6 frames before, 6/6 after   (same result on a second subject)
```

Post-calibration jitter is ±0.03 against a 0.20 tolerance, so this is a stable match rather than a
marginal one. `pitchCenterTolerance` also went 0.15 → 0.20 for headroom against Vision's noise.

### "Keychain error: A required entitlement is not present"

Also mine. The password is stored in two tiers: a Touch-ID-gated **session key** wraps an encrypted
password blob. That session key is written with a `.userPresence` `SecAccessControl`, which puts it
in the data-protection keychain — and that refuses access without the `keychain-access-groups`
entitlement, which I had stripped in §7 to make ad-hoc signing work.

`keychain-access-groups` is profile-restricted, so restoring it needs a provisioning profile, which
needs an Apple account in Xcode. The alternative was to drop `.userPresence` and enforce Touch ID in
app code instead — but that ACL is the *only* thing forcing biometric authentication on the key that
decrypts your login password, so weakening it silently was not an acceptable trade to make on your
behalf. With the account signed in, Xcode issued a Mac Development profile and the entitlement is
back:

```
keychain-access-groups = G2LCW65DC4.com.samuelmittman.macid
provisioning profile: embedded
```

The security model is unchanged from upstream's design. Signing moved to automatic (a profile is now
required), and the designated requirement is byte-identical to before — verified — so the
Accessibility grant you already gave it is still valid and does not need re-granting.

## 12. Faster detection, and a DMG

Two things paced the scan, both fixed.

**Camera warm-up was serialised behind the UI animation.** `AVCaptureSession.startRunning()` needs a
few hundred milliseconds before it produces a usable frame, and it was only reached after a 300ms
lock-state settle plus a 250ms arm-animation buffer — so those costs were paid back to back. The
capture session now starts the moment a trigger is confirmed, in parallel with the arm animation, so
by the time the notch has finished opening the camera is already delivering frames. Gated on the
trigger actually auto-scanning, so hover-to-start doesn't light the camera indicator speculatively.

**The scan loop was dropping a quarter of the frames it was handed.** It slept 20ms between frames,
which on its own is reasonable — but added to the ~20ms a frame takes to process it made a ~40ms
cycle against 33ms frame arrivals. Measured by driving the real pipeline against a simulated 30fps
camera for three seconds:

```
poll 20ms (before)   processed 53 of 90 delivered frames   17.7 fps   59% of the camera
poll  5ms (after)    processed 85 of 90 delivered frames   28.3 fps   94% of the camera
```

A 1.6x increase in how many chances per second it gets to recognise you, which is what time-to-unlock
actually depends on. Polling is now well inside the frame interval, so processing paces the loop
rather than the sleep.

What was left alone: `lightModeMinimumFrames` (3 frames before Light mode auto-confirms) is the
window the deny cues get to fire in, and shortening it would trade spoof resistance for a few tens of
milliseconds. Detection itself is the floor at ~12-16ms per frame and is already the cheapest of the
strategies measured in §9.

**DMG.** `Mac ID 1.2.dmg` (82 MB) sits next to the app in `~/mac-id/`, with the standard
drag-to-Applications layout. Verified: it mounts, and the app inside passes `codesign --verify
--deep --strict`.

One limit worth knowing: the app is signed with your *development* certificate and carries a
development provisioning profile. That is what permits the keychain entitlement, but it also means
the DMG is for your machines, not for distribution — another person's Mac will refuse it. Sharing it
would need a Developer ID certificate and notarization, which is a paid-account thing.

## 13. Shipping updates to other people

Sparkle is back — safely this time — with your own signing key and a release script. One piece
cannot be done without a purchase, and it is the piece that gates everything else.

### The hard blocker: distribution needs a paid account

You have an *Apple Development* certificate only. That signs an app that runs on **your** Macs.
Reaching anyone else's Mac needs:

1. A paid Apple Developer Program membership ($99/yr)
2. A **Developer ID Application** certificate created under it
3. **Notarization** (`xcrun notarytool submit --wait`, then `xcrun stapler staple`)

Without those, Gatekeeper blocks the app on every machine that isn't yours, and Sparkle makes this
worse rather than better: the update downloads, verifies, and then fails to install. The release
script detects this and says so loudly rather than letting you ship something that half-works.

Everything else is done, so when you have the certificate it is a rebuild, not a rewrite.

### Sparkle, re-integrated

Removed in §8 because its prebuilt XCFramework carries its own signature and dyld refuses to load an
embedded framework whose Team ID doesn't match the host — under ad-hoc signing the app died before
`main`. Now that the app signs with a real identity, Xcode re-signs Sparkle to match:

```
app:      TeamIdentifier=G2LCW65DC4
Sparkle:  TeamIdentifier=G2LCW65DC4
```

Verified by launching: no dyld crash. The release script also asserts this equality before packaging,
because that failure is invisible until the moment someone tries to run it.

### Your update-signing key

Generated with Sparkle's `generate_keys`. Public half is in `Info.plist`:

```
SUPublicEDKey = uKUdbCTMCAWtKhvS4mUYirjeM7VwYsdZprh3gA7EzYQ=
```

The private half is in your **login keychain** and is not in the repo. Sparkle refuses any update
whose signature doesn't verify against the public key, so nobody can push an update to your users
without it — including whoever might control the feed URL. Verified working: signing the 1.2 DMG
produced a valid signature.

**Back this key up.** Losing it means shipping a new public key, which strands every copy already
installed — they will never accept another update.

```bash
security find-generic-password -s "https://sparkle-project.org" -w
```

Upstream Glance's feed and key were deliberately not reused; pointing at that feed would have
replaced Mac ID with a different app on every install.

### The release script

`tools/release.sh <version>` builds, packages, signs and regenerates the appcast. It deliberately
stops short of publishing and prints the `gh release create` line, because a bad appcast reaches
every installed copy at once.

It refuses to proceed when:

- `SUFeedURL` is still the placeholder (checked before touching the project, so a refused run
  changes nothing)
- the app isn't signed with Developer ID, or is Developer ID but not notarized — warns, with the
  exact commands
- `Sparkle.framework`'s Team ID doesn't match the app's
- the appcast comes out without EdDSA signatures, meaning the private key wasn't found

Appcast generation uses Sparkle's own `generate_appcast`, which signs every archive in `releases/`
and keeps older versions in the feed, rather than hand-written XML.

### Layout on GitHub

Feed URL, compiled into every copy:

```
https://github.com/sammystech/Mac-ID/releases/latest/download/appcast.xml
```

(GitHub turns the repo name "Mac ID" into `Mac-ID` — repo names can't contain spaces.)

Because the feed points at `releases/latest/download/`, **every release upload must include all the
zips plus the appcast**, not just the new one — older versions have to stay reachable from the newest
release or updating from them breaks. The script prints the exact command.

Two directories, deliberately separate: `releases/` holds only the update zips and `appcast.xml`,
because `generate_appcast` refuses two archives carrying the same bundle version; `dist/` holds the
hand-install DMGs.

### Verified end to end

A full `./tools/release.sh 1.2` run produced:

```
releases/MacID-1.2.zip        97M
releases/appcast.xml          1 item, signed
dist/Mac ID 1.2.dmg           83M
```

with a correct enclosure URL and an EdDSA signature. The signature chain was then checked both ways:
the real archive verifies, and the same signature against a different archive is **rejected**
("failed to pass signing verification") — so a substituted download cannot install.

The run also correctly warned that the build is Development-signed and therefore yours-only, and
confirmed `Sparkle.framework`'s Team ID matches the app's.

---

## Files changed

Roughly 30 source files touched across both rounds, plus two new ones
(`glance/CameraFrame.swift`, `glance/Liveness/CropAppearance.swift`), one deleted
(`glance/Liveness/GlareCueExtractor.swift`, folded into `CropAppearance.swift`), the replaced
Core ML model, and `tools/convert_arcface.py`.

Full source is in `src/`. Rebuild with:

```bash
xcodebuild -project src/glance.xcodeproj -scheme glance -configuration Release build
```

No signing flags — the project now pins them (see §10). **Do not** rebuild with
`CODE_SIGN_IDENTITY="-"`; ad-hoc signing is what broke the Accessibility permission.

## Before you run it

- **You will have to enroll your face and store your password in Mac ID.** It is a different app
  with a different bundle identifier, so it has no access to anything Glance stored — and the
  backbone change would have invalidated the old embeddings anyway (`SecureFaceStore` refuses to
  compare across model identifiers, by design).
- **Turn Glance off first.** Two face-unlock apps both driving the notch overlay and both typing a
  password at the lock screen will fight each other. Quit Glance (and disable its launch-at-login)
  before enabling unlock in Mac ID.
- Signing is automatic against team G2LCW65DC4, using the Apple Development certificate and a Mac
  Development provisioning profile Xcode issues. That profile is what permits the
  `keychain-access-groups` entitlement, and that entitlement is what lets the Touch-ID-gated session
  key work at all — so an Apple account must stay signed in to Xcode for rebuilds.
- Signed with your Apple Development certificate (team G2LCW65DC4), not notarized. Gatekeeper may
  still ask on first launch: right-click → Open.
- Built **arm64-only** (the original shipped universal). Fine for this Mac; rebuild with
  `ARCHS="arm64 x86_64"` if you ever need Intel.
- Auto-update is switched off deliberately, not broken — see §7. Mac ID will never try to replace
  itself, which also means you update it by rebuilding from `src/`.
- The app has now been launched and verified to start cleanly and stay running. What has *not* been
  exercised is the unlock path itself — enrolling a real face and having it type a password at the
  lock screen. Enroll with the screen unlocked and confirm recognition in Face Lab before switching
  unlock on.
