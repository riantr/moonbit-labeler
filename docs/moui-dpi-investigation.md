# DPR / HiDPI scaling investigation — Phase 5.4 finding

**Date**: phase 5.4 spike (2026-09-17).
**Verdict**: **5.4 is a no-op for the application code**. MoUI's framework already
normalises physical pixels → logical pixels at the host-backend layer, and the
rest of the layout / paint / event pipeline operates in logical coordinates.

## TL;DR for the next reader

> In MoUI, **`frame : Rect` in a `canvas` view's `draw` callback is in logical
> pixels** (CSS-pixel-equivalent). All paint commands issued from `draw`
> (`@common.fill_rect`, `@common.stroke_rect`, `@common.draw_image`, …) are
> interpreted as logical pixels. The framework's render worker applies the
> window's `scale_factor` matrix when blitting to the physical surface.
>
> **Implication for our canvas**: nothing in `canvas_view.mbt` needs to change
> when the window is moved to a HiDPI display. Stroke widths, handle marker
> sizes, hit-test radii in image-natural space, etc., are already correct
> across DPRs. The legacy `frontend/src/canvas.js` (CEF path) actually has a
> small bug on HiDPI displays because it treats the canvas backing-store
> pixel count as CSS pixels; the MoUI path is one CSS pixel = one logical
> pixel = `scale_factor` physical pixels, automatically.

## Evidence chain (all line refs are to this repo's `.mooncakes/` checkout of `wzzc-dev/moui` + `wzzc-dev/window`)

### 1. Platform window reports physical size + scale factor

`.mooncakes/wzzc-dev/window/windows/native/...` and the analogous Linux / macOS
backends expose:

```text
window.surface_size()  → PhysicalSize { width : Int, height : Int }
window.scale_factor()  → Double   // 1.0 = 100% DPI; 2.0 = 200% DPI scaling
```

`PhysicalSize` lives in `.mooncakes/wzzc-dev/window/dpi/dpi.mbt` (line 47-66)
and is paired with `LogicalSize` (line 13-31). Conversion is the canonical
`PhysicalSize / scale_factor` round-trip.

### 2. Host backend converts physical → logical before dispatching

`.mooncakes/wzzc-dev/moui/backend/windows/windows_backend.mbt:493-496`:

```moonbit
let metrics = @window_input.make_surface_metrics(
  window.surface_size(),
  scale_factor=window.scale_factor(),
)
```

The Linux (`linux_app_handler.mbt:25-28`), macOS (`macos_app_handler.mbt:25-28`),
web (`web/host_runtime.mbt:212-218`), and embedded
(`common/embedded/embedded_runtime_backend.mbt:209-213`) backends do the same.

`make_surface_metrics` returns a `SurfaceMetrics{ logical_size, physical_size, scale_factor }`
where `logical_size = physical_size / scale_factor`. **This is the only point
in the pipeline where DPR matters** — every subsequent stage is logical.

### 3. Driver dispatches `Event::Resized(metrics)` with logical size

`.mooncakes/wzzc-dev/moui/backend/windows/windows_backend.mbt:521`:

```moonbit
ignore(self.driver.dispatch(@host.Event::Resized(metrics)))
```

The driver hands `metrics.logical_size` (NOT `physical_size`) to the runtime.

### 4. Runtime sets up the root layout in logical coordinates

`.mooncakes/wzzc-dev/moui/backend/common/embedded/embedded_runtime_backend.mbt:135`
and `:215` — the runtime's root layout pass receives `metrics.logical_size` and
computes `Constraints.max = logical_size`. **No DPR-aware code in app-land
ever runs from here down.**

### 5. `frame : Rect` in our `canvas_view.mbt` draw callback = logical

`.mooncakes/wzzc-dev/moui/views/canvas/canvas.mbt:40-49`:

```moonbit
impl @core.ViewNode for Canvas with fn paint(self, ctx) {
  let pctx = PaintContext::new()
  (self.draw)(pctx, ctx.frame)
  @core.ViewPaintPlan::commands(PaintContext::finish(pctx))
}
```

`ctx.frame` comes from `ViewPaintContext` (`.mooncakes/wzzc-dev/moui/core/view_protocol.mbt:49-54`),
which the runtime fills with the layout-computed logical rect. Our
`canvas_view.mbt:43-49` uses `frame.size.width / .height` directly for fit-contain
math — and this is correct across all DPRs.

### 6. Pointer events are normalised to logical before reaching views

`.mooncakes/wzzc-dev/moui/backend/windows/windows_window_event_dispatch.mbt:22-25`:

```moonbit
let scale_factor = match self.platform_slots.lookup_host(window_id) {
  Some(slot) => slot.window.scale_factor()
  None => 1.0
}
match @window_input.transform_cross_platform_event(
  event, ..., scale_factor~, ...) { ... }
```

`transform_cross_platform_event` (in `.mooncakes/wzzc-dev/window/internal/.../window_event_transformer.mbt`)
divides physical pointer coordinates by `scale_factor` before they reach our
`canvas.on_drag` callback. So `ev.position` in `canvas_view.mbt:124-130` is
**already in logical pixels**, and the `(ev.position.x - model.pan.x) /
model.zoom` formula gives the correct image-natural cursor.

### 7. Render worker carries scale_factor into the GPU/CPU blit

`.mooncakes/wzzc-dev/moui/render/common/surface_context.mbt:1-20`:

```moonbit
pub struct PixelFrame {
  width : Int
  height : Int
  row_bytes : Int
  scale_factor : Double
  pixels : Bytes
}
```

`PixelFrame.scale_factor` is propagated into the render worker
(`.mooncakes/wzzc-dev/moui/render/common/gpu_render_worker.mbt`) which applies
it as the canvas matrix when blitting the command stream to the surface.

So `@common.fill_rect(pctx, Rect{ width: 6.0 }, ...)` (logical pixels) ends up
as `6 * scale_factor` physical pixels on HiDPI displays — which is exactly
what we want for "1 logical pixel = 1 logical CSS pixel on screen regardless
of monitor DPI".

## What this means for each paint call in `canvas_view.mbt`

| Code site | Logical px today | Behaviour on HiDPI (dpr=2) | DPR-aware change needed? |
|---|---|---|---|
| `fill_rect(frame, #1f1f1f)` background | frame in logical px | Fills the entire logical viewport | **No** — `frame` is already logical |
| `fill_rect(placeholder, 320×240)` | hard-coded | 320×240 logical = 640×480 physical | **No** — this is intentional (placeholder is logical-size) |
| `stroke_rect(rect, red, 1.0)` | 1 px stroke in logical | 2 physical px on dpr=2 = crisp | **No** |
| `fill_rect(handle_marker, 6×6)` | 6 logical px | 12 physical px on dpr=2 = correct | **No** |
| `fill_rect(keypoint, 8×8)` | 8 logical px | 16 physical px on dpr=2 = correct | **No** |
| `draw_image(ImageRun{source, frame, ...})` | frame in logical px | Skia stretches the image to logical frame; scale_factor applied at blit | **No** |
| `fill_rect(crosshair 16×1)` | 16 logical px wide, 1 px tall | Same — fine on all DPRs | **No** |
| Hit-test radius `12.0` (`hittest.mbt:155`) | image-natural space | Independent of DPR (radius is in image-natural coords) | **No** |
| Pan/zoom math (`img_to_screen`, `screen_to_img`) | screen px in logical | Independent of DPR (zoom is a logical-pixel multiplier) | **No** |

**Every site is already DPR-correct by virtue of operating in logical
coordinates.**

## What 5.4 does NOT need to do

- No Model.dpr field
- No Msg::SurfaceDprChanged variant
- No application-side scale matrix
- No changes to canvas_view.mbt draw logic
- No changes to hit-test radii
- No changes to handle marker sizes
- No font-size adjustment (text rendering isn't on the canvas yet — that's a
  5.x+ sidebar/toolbar concern, but MoUI's `text_system()` already exposes
  logical-px text metrics).

## What 5.4 DOES deliver (this commit)

1. **This investigation report** (`_build/design/dpi-investigation.md`) so the
   next person who asks "do we need to handle DPR?" finds the answer in one
   place instead of re-deriving it from `.mooncakes/`.

2. **Updated header doc** in `canvas_view.mbt` calling out the logical-px
   convention explicitly, so future readers don't add ad-hoc scale_factor
   arithmetic.

3. **One new blackbox test** in `canvas_view_test.mbt`:
   `fit_contain_rect` is DPR-invariant because it only takes the logical
   `frame`. Same input `(frame, natural_w, natural_h)` ⇒ same output regardless
   of the window's `scale_factor`. This is the contract.

## When we WOULD need explicit DPR handling

Only if we started drawing **physical-pixel-perfect** elements (e.g. 1
device-pixel hairlines that are sub-logical-px, or fonts that should be
exactly 8 px regardless of monitor). Today's canvas doesn't do this — every
"px" in `canvas_view.mbt` is intended as a logical CSS pixel.

If that ever changes, the surface to extend is:

```moonbit
// In Model:
dpr : Double  // = 1.0 default, set when Resized fires

// In Msg:
SurfaceResized(Double)  // scale_factor

// In canvas_view.mbt draw callback:
let hairline = 1.0 / model.dpr  // sub-logical px
```

…but again, **we don't need this today**.

## Cross-references

- `.mooncakes/wzzc-dev/window/dpi/dpi.mbt` — LogicalSize / PhysicalSize / Position / Size enums + `validate_scale_factor` (rejects NaN/Inf/≤0).
- `.mooncakes/wzzc-dev/moui/backend/windows/windows_backend.mbt:493-521` — Windows host: physical→logical dispatch.
- `.mooncakes/wzzc-dev/moui/backend/linux/linux_app_handler.mbt:25-72` — Linux host: same pattern.
- `.mooncakes/wzzc-dev/moui/backend/macos/macos_app_handler.mbt:25-72` — macOS host: same pattern.
- `.mooncakes/wzzc-dev/moui/backend/web/host_runtime.mbt:208-220` — Web host: same pattern (browser CSS px → logical).
- `.mooncakes/wzzc-dev/moui/backend/common/embedded/embedded_runtime_backend.mbt:130-218` — embedded backend: same pattern, dispatches `Event::Resized(metrics)`.
- `.mooncakes/wzzc-dev/moui/backend/common/input/window_event_transformer.mbt` — pointer event physical→logical.
- `.mooncakes/wzzc-dev/moui/views/canvas/canvas.mbt:40-49` — Canvas view's `paint` impl, passes `ctx.frame` (logical) to user draw.
- `.mooncakes/wzzc-dev/moui/render/common/surface_context.mbt:1-20` — `PixelFrame.scale_factor` propagated into the render worker.
- `.mooncakes/wzzc-dev/moui/render/common/gpu_render_worker.mbt` — final blit; scale_factor applied as canvas matrix.