# MacDuo

Turn a MacBook into an iPhone Duo: the inner-screen fold, driven by the real hinge.

English · [中文](README.zh-CN.md)

[![Stars](https://img.shields.io/github/stars/by123/MacDuo?style=flat-square&logo=github&color=555)](https://github.com/by123/MacDuo/stargazers)
[![Forks](https://img.shields.io/github/forks/by123/MacDuo?style=flat-square&logo=github&color=555)](https://github.com/by123/MacDuo/forks)
[![Issues](https://img.shields.io/github/issues/by123/MacDuo?style=flat-square&logo=github&color=555)](https://github.com/by123/MacDuo/issues)
[![Last commit](https://img.shields.io/github/last-commit/by123/MacDuo?style=flat-square&color=555)](https://github.com/by123/MacDuo/commits/main)
[![License](https://img.shields.io/github/license/by123/MacDuo?style=flat-square&color=555)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-13%2B%20·%20Apple%20Silicon-black?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-5-F05138?style=flat-square&logo=swift&logoColor=white)

## Usage stats

<!-- stats:start -->
<!-- stats:data {"clones": 0, "downloads": 0, "forks": 0, "stars": 0, "traffic_stamp": "2026-09-12 06:49", "views": 0, "visitors": 0, "watchers": 0} -->
| ⭐ Stars | Forks | Watchers | Downloads | Views (14d) | Visitors (14d) | Clones (14d) |
|---|---|---|---|---|---|---|
| 0 | 0 | 0 | 0 | 0 | 0 | 0 |

<sub>Refreshed daily by [`stats.yml`](.github/workflows/stats.yml) straight from GitHub's API — no third-party tracker. Views, visitors and clones are a rolling 14-day window, last read 2026-09-12 06:49 UTC.</sub>
<!-- stats:end -->

## The mapping

```
MacBook = one iPhone Duo
  ├─ Upper half (display) = one panel: outer shell on the back, inner screen in front (your desktop)
  ├─ Lower half (keyboard) = the other panel: a screen plus a back shell
  └─ Hinge                 = the MacBook's own hinge, between screen and keyboard
                             = the bottom edge of your display
```

The consequence that makes this cheap: **your desktop already _is_ the inner screen.**
macOS renders it, so this app is a **transparent** overlay that only adds what a fold
would put on top of the inner screen — nothing is redrawn.

The hinge is physically fixed, so there is exactly one fold direction: up from the
bottom edge of the display. There is no setting for it.

## What the effect is made of

The moment the lid starts closing, MacDuo **freezes one full-screen grab** and applies
the optics of a fold on top of it. There is **no sweep, scale, or translation** — it is
full-screen from the first frame.

| Layer | What it is |
|---|---|
| Frozen grab | One ScreenCaptureKit frame copied into a CGImage (windows, playing video and all), filling the screen |
| Blur layer | One of three (menu → **Blur Style**): **lens defocus** (default, 8 pre-rendered levels driven by a spatial gradient) / **frosted glass** (uniform blur + cool milk) / **liquid glass** (iOS 26, full-screen material + bevelled edges) |
| Crease | A light band riding the hinge edge, `transparent → white .14 → black .30 → white .16 → transparent`, brighter as the lid closes |
| Haze | Inner-screen glare, stronger as the lid closes |
| Closing dim | Only kicks in past `fold > 0.55`, capped at 0.35 |

### The three blur styles

Menu bar → **Blur Style**, stored in UserDefaults (`blurStyle`). All three share the same
frozen grab, the same 8 pre-rendered blur levels and the same layer stack — they differ
only in **which images get pasted, behind which mask, and what is stacked on top**:

| | How it reads | How it is built |
|---|---|---|
| Lens defocus (default) | Spatial gradient: sharpest at the hinge, blurrier the further away | 8 blur levels + a 4-stop gradient mask |
| Frosted glass | Uniformly blurred, with a cool milky wash | Same images, mask flat at both ends, plus one white layer |
| Liquid glass | Full-screen material, more transparent and more saturated, with visible thickness along all four edges | Saturation-boosted image set + four-edge bevel refraction |

The last two are **full-screen** materials with no displacement or sweep — the glass sits
*on* the screen as one sheet, it is not a slab pushed in from an edge. The first attempt
animated it in from one side, and it read as a translation, not as a material.

#### The material ramp: why `fold^1.35`

Frosted and liquid glass both drive blur through `pow(fold, materialRamp)` with the
exponent at **1.35 (ease-in)**.

Mapped linearly, the first dozen degrees already blur past legibility: perceived blur
**saturates** against radius, and past roughly 20px more radius is barely readable. So
only the first 15% of the travel did anything and the rest looked static — no sense of
progression at all. Eased in, the whole 99° → 30° range keeps changing: still nearly
sharp at 80°, medium at 60°, fully milky only around 40°.

#### The three styles have to be distinguishable at a glance

Not an aesthetic point. In the first version all three read as the same thing at the
angles you actually use — measured per-band sharpness differed by under 20%, because at
`fold = 0.45` even the hinge end of the defocus mode is only 7px of radius, and the whole
screen is already mush. So the other two each need a signature that defocus **cannot**
produce:

- Frosted: 26% cool milky wash. Mean luminance climbs from 97 to 129 — it reads as
  *a material laid on top*, not as *out of focus*.
- Liquid glass: a sheet with boosted saturation (1.60) and a slight lift (0.05), plus
  bevel refraction along all four edges. Defocus and frosted only ever make the image
  **flatter**; only glass makes it **more vivid**, with thickness at the edges.

### Liquid glass (iOS 26)

The sheet is the same 8 layers, only the images have been reworked into a material by
`Blur.glassSkins` — glass *pulls the background into* the material rather than laying a
translucent white over it (stacking white only ever goes grey). The real identity lives
on the **screen edges**, and it does not move:

| | What it is |
|---|---|
| Bevel refraction | A narrow band on each of the four edges (4.5% of the short side by default, ≈ 44pt); the closer to the edge, the harder the image is squeezed. That squeeze *is* the readable thickness |
| Overfill | The sheet is drawn larger than the grab (2.5% per side); the excess is clipped by the window |
| Edge highlight | A thin bright line hugging the edge, cool white (`#D8F0FF`) turning warm white (`#FFE8CD`) inward — dispersion |
| Sheet sheen | A weak diagonal light, anchored to the screen (the source does not move) |

"Liquid" is expressed as: **the faster the lid moves, the thicker the bevel (up to 1.3×)
and the brighter the highlight** — the material being stretched. Speed is `|d(fold)/dt|`
through an 80ms filter; unfiltered it jitters with the sampling.

#### The bevel samples inward, not outward

Real bevels refract what is *outside* the glass. This sheet lies on the screen and there
is nothing outside it to refract, so the sampling direction is inverted — it squeezes the
**inside** of the image toward the edge:

```
S(u) = w · u^0.45        u = depth inward from the screen edge (0…1, in units of band width w)
```

The slope of `u^0.45` diverges at `u → 0`, which is exactly the hard compression right at
the edge, relaxing to 1:1 at the inner end; it is monotonic, so the image never flips.
The curve is approximated by 4 affine segments: neighbouring segments are **continuous in
sample position** at the seam (only the derivative jumps), so the hard-edged joins are
invisible and need no cross-fade.

Uniform compression (a single affine map) was tried: it reads as **smear**, not glass —
affine compression is the same everywhere, while a bevel's displacement is inherently
non-linear.

#### The glass sheet must be bigger than the grab

The bevel pushes the image **toward the edges**, so laid out 1:1 the outermost ring gets
squeezed out and leaves a blank rim — as if the glass did not reach the screen edge.
`glassOverfill = 0.025` draws the sheet 2.5% larger per side, so the squeezed-out region
is filled by the overflow and the excess is clipped by the window. The 5% magnification
is correct on its own terms too: looking through glass with thickness does magnify a bit.

The same bug had a second half: the refraction bands used to be pasted with the **sharp**
grab, which ringed the screen with un-materialised, crisp content and made the glass look
even less full-bleed. They now use the glass images too, just a few levels **shallower**
than the sheet (`rimIdx = amount × 8 × 0.25`) — blur it all and the squeeze becomes
invisible, which defeats the refraction; equal to or blurrier than the sheet does not work
either. It has to be sharper than the sheet while still being the material.

#### Why not `contentsRect`

Fitting a source region into a destination band is intuitively a `contentsRect` change.
But its y origin is ambiguous on macOS (it follows `contentsAreFlipped()`), so tuning it
is guesswork. This computes the frame directly instead: scale and position the whole grab
so that the src region on screen lands exactly on the dst region, then clip the rest with
the parent's `masksToBounds` — pure geometry, no ambiguity, and one less mask.

### Self-shot verification

```bash
open -n --env MACDUO_SHOOT=/tmp/shots build/MacDuo.app
```

Injects a **synthetic desktop** (not the real one) into the Stage, renders several frames
per style, grabs only its own window through ScreenCaptureKit into PNGs, and exits.

The detour is necessary because every other route is closed: `CALayer.render(in:)` does
not support masks; `CARenderer` renders all zeros on this machine; `CGWindowListCreateImage`
has been pulled from the SDK. And the correctness of this effect lives **entirely in the
masks and the nested clipping** — recomposing it in CoreGraphics would only verify the
algorithm, not Core Animation's actual behaviour.
`SCContentFilter(desktopIndependentWindow:)` captures what the window server composited,
which is what your eyes see.

Grabbing its own window uses the app's own screen-recording grant, so it **must be started
through LaunchServices** (`open`); running `Contents/MacOS/MacDuo` directly gets no grant
(`preflight = false`). Also, do not just wrap it in `Task {}` — `window.setFrame` inside
`layout()` is main-thread only, while a nonisolated `async` method is scheduled onto a
background executor, so `@MainActor` has to be explicit.

What it caught: uniformly compressed refraction bands reading as smear (fixed by the
piecewise non-linear curve), the highlight being a wide white fog (tightened to a thin
line), the three styles colliding at everyday angles, and the whole material ramp being
crammed into the first dozen degrees.

The two measuring sticks that go with it live in the verification scripts under `/tmp`:
per-band sharpness and mean luminance. **Per-band sharpness is only valid comparing the
same band across images**, and large flat areas in the synthetic desktop can invert it
(a blurred image has small gradients everywhere, a sharp one is mostly 0), so in the end
you still have to look at the pictures.

### The transition range

Default: **blur begins at 99°, reaches maximum at 30°**, and stays at maximum below 30°.
Linearly mapped to `fold` 0→1. Both ends are editable from the menu — *Set Current Angle
as Start / End*, or *Reset to 99° → 30°* — and are saved to UserDefaults.

### Why not cross-fade a sharp and a blurred copy

The first version alpha-blended two images (sharp + maximum blur). Your eye then sees
**sharp edges and a blur halo at the same time**, which reads as a double exposure or a
veil, not as defocus — real defocus requires the **radius itself** to grow continuously.

Now 8 levels of linearly increasing radius are pre-rendered and stacked; neighbouring
levels differ by 1/8 of the radius, so cross-fading between them looks like the radius
changing continuously. Each layer gets a 4-stop gradient mask expressing exactly
`alpha(p) = clamp(local blur level − (i−1), 0, 1)`, where the local level grows linearly
with distance from the hinge.

### Why blur in linear light

A Gaussian in sRGB space turns white highlights into **grey blobs** (luminance collapse)
and looks muddy. Converted to linear light first, highlights stay bright and bloom outward
like real lens defocus. The before/after through
`CISRGBToneCurveToLinear` → Gaussian → `CILinearToSRGBToneCurve` is obvious side by side.

### Why generate iteratively

Gaussians compose: `r_i` comes from re-blurring `r_{i-1}` by `sqrt(r_i² − r_{i-1}²)`, so
every step is a small radius — an order of magnitude faster than doing a large-radius blur
from the original for each level. Measured over 8 levels: 237ms cold, 62–108ms warm.

### Why not `CALayer.filters`

The first version used `CALayer.filters = [CIAffineClamp, CIGaussianBlur]` and the blur
showed up in a small patch in the bottom-left corner. `CIAffineClamp` produces an
**infinitely extending** CIImage, so the compositor has no valid extent and drew the
filter result into the corner. The mask `locations` were also being handed out-of-range
values like `1.4` / `-0.4`.

It now pre-renders in CoreImage, with the output rect given explicitly by
`createCGImage(out, from: scaled.extent)` — no infinite extent. Three side benefits:

- **Verifiable offscreen.** `CALayer.filters` is composited by the window server and
  `render(in:)` cannot capture it; pre-rendering can be run over a test image and dumped
  to PNG.
- **Much cheaper.** The blur is computed once at grab time, not as a full-screen Gaussian
  every frame.
- **Blur images are quarter resolution** (3024x1964 → 756x491), scaled back up with
  linear interpolation — it is already blurred anyway. All 8 levels cost about 12MB;
  full resolution would be 190MB.

CoreImage compiles kernels on first use, about 290ms cold, so `Blur.warmUp()` runs one
throwaway pass in the background at launch. Generation runs on a `userInitiated` queue and
never blocks the main thread.

The gradient mask keeps a 15% floor at the hinge end (`hingeFloor`) so that at `fold = 1`
the whole screen is blurred, just heaviest at the far end. On hide, the grab and the 8
blur levels are detached from the layers and about 36MB goes straight back.

### Capture takes exactly one frame

`needsSnapshot` converts the first frame to a CGImage and `stop()`s the stream
immediately — the copy is mandatory because the IOSurface is recycled by the stream. So
screen recording runs for a few hundred milliseconds per close, not continuously. As soon
as the lid starts moving (angle < start angle + 15° and falling), `prime()` warms it up so
the grab is ready before it is needed.

### Blur direction

Menu → *Blurrier away from the hinge (lens defocus only; uncheck to invert)*, on by
default. The other two styles are uniform across the screen and have no direction, so the
switch does nothing for them.

### Language

The UI is **English by default**; menu → **Language** → **中文** switches it, and the
choice is saved to UserDefaults (`language`). Switching rebuilds the status-bar menu
immediately — no relaunch. Log output is always English.

## How it works

Apple Silicon MacBooks have a built-in lid angle sensor exposed as an HID device:

- UsagePage `0x20` (Sensors) / Usage `0x8A`, Feature Report ID `1`
- Bytes 2–3, little-endian = angle in degrees
- Measured 0.35ms per read, a theoretical ceiling of ~2844Hz, and **no system permission
  of any kind**

## Values ported from the apple.com/iphone-duo viewer

| Item | Value |
|---|---|
| Body gradient | `linear-gradient(160deg, #3B424E, #22272F 42%, #171B21)` |
| Haze | `linear-gradient(190deg, rgba(190,205,255,.30), rgba(255,190,140,.10) 55%, transparent)` |
| Haze strength | `opacity = .34 − .24 × openness` |
| Crease | `transparent → #fff.16 → #000.30 → #fff.14 → transparent`, `opacity = .15 + .75 × fold` |
| Crease width | `11/288` of the body size |
| Dead zone | `0.11` — the image only starts changing past this fraction, so a brush of the hand does not shake it |
| Image lag | The image follows a slower spring (implemented here as a 120ms filter) |

### Deliberately not ported

- **The spring + magnet simulator.** In the viewer it manufactures feel for a mouse drag.
  Here the input is a real hinge, the feel is already in your hand, and another spring on
  top only makes the image lag behind it. The viewer says as much itself: "the angle comes
  from a real sensor… then it must be computed." Only the 55ms critically damped filter is
  kept, to smooth the steps from the sensor's integer degrees (1° = 1% of fold progress;
  unfiltered you see it jump).
- **The three-camera blend.** The viewer needs it because you are rotating a virtual phone
  with a mouse. Here the camera is your eyes and is already physically moving; adding it
  would be a double rotation.
- **Outer screen / Dynamic Island / app grid.** That is phone UI, not your inner screen.

## Build and run

```bash
./build.sh
open build/MacDuo.app
```

Preview without actually closing the lid (a 5-second flat → closed → flat pass):
menu bar → *Play Preview Once*, or
`MACDUO_DEMO=1 ./build/MacDuo.app/Contents/MacOS/MacDuo`

Stop: menu bar → Quit, or `pkill -x MacDuo`.

## Behaviour

- **Start angle defaults to 99°**, settable to the current angle from the menu. At or
  above the start angle the overlay is fully hidden.
- **Adaptive sampling**: 15Hz at rest (0.5% CPU), 125Hz while moving (about 6% peak).
- **Built-in display only**: closing the lid with an external display attached is
  clamshell mode and is unaffected.
- Fully click-through (`ignoresMouseEvents`), never takes focus.

## Screen recording permission

Showing the real desktop requires ScreenCaptureKit, which requires MacDuo to be ticked
under System Settings → Privacy & Security → Screen Recording. macOS raises the prompt the
first time capture is triggered.

Things worth knowing:

- **Capture excludes MacDuo's own windows** (`SCContentFilter(excludingApplications:)`),
  otherwise the panel contains a panel, recursively.
- **Capture only runs while the overlay is visible**; the stream stops after the first
  frame, and the layers are released 1.5s after hiding. Nothing records around the clock.
  The pixels are used as a texture in local memory only — never written to disk, never
  uploaded.
- **Sign with a Developer ID, not ad-hoc.** This matters: a TCC grant against an ad-hoc
  signature is bound to the cdhash and dies on every rebuild, so you get the prompt over
  and over; a Developer ID is bound to the Team ID and the grant survives rebuilds.
  `build.sh` picks up the first `Developer ID Application` identity in your keychain
  automatically and only falls back to ad-hoc if there is none. Set `MACDUO_IDENTITY` to
  choose a specific one. A free Apple ID has no Developer ID — ad-hoc still works, you
  just have to re-grant screen recording after every rebuild.
- **macOS kills the app once you grant** (the "quit and reopen" behaviour). That is
  normal — the menu has *Relaunch MacDuo After Granting*.
- **No automatic retry.** Once preflight reports no permission, the launch asks once and
  never again, so you do not get a prompt on every close. To retry, use menu → *Open
  System Settings → Screen Recording*.

## Logs

`~/Library/Logs/MacDuo.log` — permission state at launch, capture start/stop, failure
reasons. (`log show --process MacDuo` reads nothing from the unified log on this machine,
hence the plain file.)

## Known limitations

1. **Does nothing on the lock screen.** Locked, macOS switches to loginwindow's separate
   secure context and user-space app windows are not composited. The window level is
   already at the user-space ceiling (`CGShieldingWindowLevel`); this is a hard system
   boundary.
2. **Below roughly 40° you cannot see it anyway** — the display has turned away from you,
   and sleep triggers at 5–10°. The genuinely visible range is about 99° → 40°.
3. **Opening lags.** On opening, the WindowServer runs its own fade-in before the app gets
   the angle event; that delay cannot be removed.

## Tuning

`MacDuo.swift`:

| Knob | Meaning | Current |
|---|---|---|
| `maxRadiusPx` | Maximum blur radius | `span × sf × 0.05` (98px measured) |
| `hingeFloor` | Blur floor at the hinge end | `0.15` |
| `Blur.levelCount` | Blur levels — more is smoother and slower | `8` |
| `downscale` | Downsampling factor for blur images | `4` |
| `startAngle` / `endAngle` | Transition range | `99°` / `30°` |
| `dim` coefficient | Cap on the closing dim | `0.35` |
| `foldDeadZone` | Fold fraction before the image starts changing | `0.11` |
| `angleTau` | Angle smoothing — larger lags further behind your hand | `0.055` |
| `foldTau` | How far the light and shadow lag the angle | `0.12` |
| `haze.opacity` coefficient | Inner-screen glare strength | `0.30` |
| `Blur.glassSkin` saturation / brightness | How material the glass sheet feels | `1.60` / `0.05` |
| `materialRamp` | Frosted/glass ramp exponent — larger eases in more | `1.35` |
| `veil` coefficient | Cap on the frosted milky wash | `0.26` |
| `bevelDepth` | Glass bevel width (fraction of the screen's short side) | `0.045` |
| `bevelSqueeze` | Bevel sampling exponent `S(u)=w·u^p` — smaller hugs the edge harder | `0.45` |
| `bevelSegments` | Affine segments approximating the bevel curve per edge | `4` |
| `glassOverfill` | How far the glass sheet overhangs the grab (per side) | `0.025` |

## License

MIT — see [LICENSE](LICENSE).
