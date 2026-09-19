// app_moui/view_math.mbt — pure-math view-transform helpers.
//
// Phase 5.12.A — canvas.js view-math parity (the math side of the
// parity push; 5.12.B/C/D handle visual + plumbing). These are the
// pure functions that fit / zoom-around-point / zoom-clamp logic
// reduces to. They live in their own file (not canvas_view.mbt) so:
//   - the math is independently testable without instantiating a
//     Model or constructing any PaintContext;
//   - future Msg handlers (FitView, ZoomAroundPoint, …) can
//     dispatch directly through them without dragging in the
//     paint-pipeline code from canvas_view.mbt.
//
// Functions mirror the JavaScript reference in frontend/src/canvas.js:
//   clamp_zoom         → clamp box at canvas.js:76-77, line 712 / 726
//   fit_view_zoom      → fitView at canvas.js:701
//   fit_view_pan       → fitView at canvas.js:707-708
//   zoom_around_natural_pt
//                      → zoomAtScreenPoint at canvas.js:256-264
//                      (input reformulated in natural coords so the
//                      call site doesn't have to do the
//                      screen→natural round-trip itself).
//
// Conventions:
//   - pan is in stage CSS px (relative to the canvas / image origin
//     inside the stage). Same convention as canvas.js (line 73).
//   - zoom is dimensionless multiplier; 1.0 = natural size on
//     stage at display.dpr = 1. 2.0 = 2× natural.
//   - image-natural point (x, y) is in raw bitmap px, no DPR
//     adjustment. img_to_screen in canvas_view.mbt uses the same
//     convention; the two are inverses modulo pan/zoom.

// ─────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────

///|
/// Minimum allowed zoom. 5% of natural — anything smaller and
/// even a 4K image disappears into a few pixels, which is usually
/// a "lost the canvas" state the user can't recover from without
/// hitting reset. Matches canvas.js ZOOM_MIN (line 76).
pub let zoom_min : Double = 0.05

///|
/// Maximum allowed zoom. 32× natural — anything larger and Skia /
/// Cairo rasterise a single pixel into a ~1 MB bitmap on a 4K
/// source, which the user almost certainly didn't intend. Matches
/// canvas.js ZOOM_MAX (line 77).
pub let zoom_max : Double = 32.0

// ─────────────────────────────────────────────────────────────────
// Zoom clamp
// ─────────────────────────────────────────────────────────────────

///|
/// Clamp `z` to the [zoom_min, zoom_max] range. canvas.js clamps
/// at every zoomBy / setZoom call (lines 712, 726); we centralise
/// the same clamp here so any future caller (Zoom Msg, future
/// wheel-on_wheel plumbing) gets the same behaviour for free.
/// Returns the input unchanged if it's already inside the range.
pub fn clamp_zoom(z : Double) -> Double {
  if z < zoom_min {
    zoom_min
  } else if z > zoom_max {
    zoom_max
  } else {
    z
  }
}

// ─────────────────────────────────────────────────────────────────
// Coordinate transforms
// ─────────────────────────────────────────────────────────────────

///|
/// Given a *canvas-local* screen-space point `(sx, sy)` (i.e.
/// coordinates relative to the canvas / image origin, NOT the
/// stage origin — see post-Fix-A convention in canvas.js
/// comment lines 88-105) and the current `zoom`, return the
/// image-natural point underneath it. Formula:
/// `natural = canvas_local_screen / zoom`. Pan does NOT appear
/// in the formula because the input is canvas-local — if the
/// caller has stage-local CSS px, they must subtract pan first
/// (`sx_canvas_local = sx_stage - pan.x`, etc).
///
/// This is the canvas.js `toNatural` (line 106-108) one-for-one.
pub fn screen_to_natural(sx : Double, sy : Double, zoom : Double) -> Point {
  { x: sx / zoom, y: sy / zoom, }
}

///|
/// Forward transform — image-natural → screen. Mirrors
/// `canvas_view::img_to_screen` (kept private there to avoid
/// pulling PaintContext into view_math). Formula:
/// `screen = pan + natural * zoom`.
pub fn natural_to_screen(
  nx : Double,
  ny : Double,
  pan : Point,
  zoom : Double,
) -> Point {
  { x: pan.x + nx * zoom, y: pan.y + ny * zoom, }
}

// ─────────────────────────────────────────────────────────────────
// fitView — auto-fit zoom + centre-pan
// ─────────────────────────────────────────────────────────────────

///|
/// Compute the zoom factor that scales the natural-size image so
/// it fits entirely inside the viewport (stage rect). The
/// limiting dimension (width vs height) wins, so neither side of
/// the image ever clips. Matches canvas.js fitView line 701:
/// `z = min(vw / natural_w, vh / natural_h)`.
///
/// Returns 1.0 when `natural_w` or `natural_h` is non-positive —
/// the caller has no real natural size yet (placeholder mode);
/// zoom=1 + pan=(0,0) is the safe default that 5.5's static layer
/// already understands.
pub fn fit_view_zoom(
  natural_w : Double,
  natural_h : Double,
  viewport_w : Double,
  viewport_h : Double,
) -> Double {
  if natural_w <= 0.0 ||
    natural_h <= 0.0 ||
    viewport_w <= 0.0 ||
    viewport_h <= 0.0 {
    return 1.0
  }
  let z = if viewport_w / natural_w < viewport_h / natural_h {
    viewport_w / natural_w
  } else {
    viewport_h / natural_h
  }
  clamp_zoom(z)
}

///|
/// Compute the pan offset that, given a fit-view zoom, centres the
/// fitted image inside the viewport. The fitted image occupies
/// `(natural_w * zoom, natural_h * zoom)` screen px; the unused
/// area on each axis is `(viewport - fitted_size)`, and we split
/// it evenly between the two sides. Pan is the top-left corner of
/// the fitted image *relative to the canvas origin*, so the
/// returned pan is `(viewport - fitted_size) / 2`.
///
/// Matches canvas.js fitView lines 707-708:
/// `panX = (viewport.w - dw) / 2 - display.left`,
/// where `display.left = 0` in the post-Fix-A geometry (the
/// canvas is co-located with the image origin).
///
/// Returns `(0, 0)` when any input is non-positive (caller has
/// no real geometry yet).
pub fn fit_view_pan(
  zoom : Double,
  natural_w : Double,
  natural_h : Double,
  viewport_w : Double,
  viewport_h : Double,
) -> Point {
  if natural_w <= 0.0 ||
    natural_h <= 0.0 ||
    viewport_w <= 0.0 ||
    viewport_h <= 0.0 {
    return { x: 0.0, y: 0.0, }
  }
  let dw = natural_w * zoom
  let dh = natural_h * zoom
  { x: (viewport_w - dw) / 2.0, y: (viewport_h - dh) / 2.0, }
}

// ─────────────────────────────────────────────────────────────────
// Zoom around a focal point
// ─────────────────────────────────────────────────────────────────

///|
/// Compute the new pan offset that keeps a focal image-natural
/// point `(focal_nx, focal_ny)` under the same screen-space
/// position when the view zoom changes from `current_zoom` to
/// `new_zoom`. The focal screen position *before* the zoom is:
///
///   sx_before = pan.x + focal_nx * current_zoom
///
/// We want the same `sx_before` *after* the zoom too:
///
///   sx_after  = pan_new.x + focal_nx * new_zoom
///
/// Solving: `pan_new.x = pan.x + focal_nx * (current_zoom - new_zoom)`.
/// That's exactly the canvas.js formula at lines 256-264 with the
/// `(sx, sy)` round-trip expanded algebraically — see the
/// derivation in the module header.
///
/// Used by: wheel zoom (when `on_wheel` lands in a future Moui
/// version — currently 0.1.12 has no wheel modifier), zoom-in /
//  zoom-out buttons, and any "zoom around cursor" gesture.
pub fn zoom_around_natural_pt(
  new_zoom : Double,
  focal_nx : Double,
  focal_ny : Double,
  current_pan : Point,
  current_zoom : Double,
) -> Point {
  let z = clamp_zoom(new_zoom)
  {
    x: current_pan.x + focal_nx * (current_zoom - z),
    y: current_pan.y + focal_ny * (current_zoom - z),
  }
}

///|
/// Convenience wrapper: zoom around a screen-space focal point.
/// Converts `(focal_sx, focal_sy)` → natural via
/// `screen_to_natural(focal_sx, focal_sy, current_zoom)` first,
/// then dispatches to `zoom_around_natural_pt`. This matches the
/// signature of canvas.js's `zoomAtScreenPoint(z, sx, sy)`
/// (lines 256-264) one-for-one, so porting the wheel handler is a
/// straight call.
pub fn zoom_around_screen_pt(
  new_zoom : Double,
  focal_sx : Double,
  focal_sy : Double,
  current_pan : Point,
  current_zoom : Double,
) -> Point {
  let nx = focal_sx / current_zoom
  let ny = focal_sy / current_zoom
  zoom_around_natural_pt(new_zoom, nx, ny, current_pan, current_zoom)
}
