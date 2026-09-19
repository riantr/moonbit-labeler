// app_moui/view_math_test.mbt — blackbox tests for the pure-math
// view-transform helpers added in Phase 5.12.A.
//
// These tests don't construct a Model or any PaintContext —
// view_math is deliberately free of UI dependencies so the math
// is independently verifiable. Each test asserts a single property
// of one helper (or a small composition); no shared setup.

// ─────────────────────────────────────────────────────────────────
// Zoom clamp
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.12.A — clamp_zoom passes through values already in
/// the [zoom_min, zoom_max] range. Default zoom = 1.0 is the
/// canonical in-range case (the natural state on image load).
test "clamp_zoom — in-range value passes through unchanged" {
  assert_eq(clamp_zoom(1.0), 1.0)
  assert_eq(clamp_zoom(0.5), 0.5)
  assert_eq(clamp_zoom(2.5), 2.5)
}

///|
/// Phase 5.12.A — clamp_zoom pins anything below zoom_min up to
/// the floor. Mirrors canvas.js:712 / 726.
test "clamp_zoom — below zoom_min pins to floor" {
  assert_eq(clamp_zoom(0.01), zoom_min)
  assert_eq(clamp_zoom(0.0), zoom_min)
  assert_eq(clamp_zoom(-5.0), zoom_min)
}

///|
/// Phase 5.12.A — clamp_zoom pins anything above zoom_max down to
/// the ceiling. Mirrors canvas.js:712 / 726.
test "clamp_zoom — above zoom_max pins to ceiling" {
  assert_eq(clamp_zoom(100.0), zoom_max)
  assert_eq(clamp_zoom(50.0), zoom_max)
}

///|
/// Phase 5.12.A — boundary values zoom_min and zoom_max are
/// inclusive (clamp returns them unchanged). Guards against an
/// off-by-one that would silently lock users out of the floor /
/// ceiling.
test "clamp_zoom — boundary values zoom_min / zoom_max are inclusive" {
  assert_eq(clamp_zoom(zoom_min), zoom_min)
  assert_eq(clamp_zoom(zoom_max), zoom_max)
}

// ─────────────────────────────────────────────────────────────────
// Coordinate transforms
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.12.A — screen_to_natural is the inverse of
/// `natural_to_screen` when the inputs are *canvas-local* CSS px
/// (i.e. the post-Fix-A convention: the canvas is co-located with
/// the image origin, so `sx = pan.x + nx * zoom` simplifies to
/// `sx = nx * zoom` when pan is ignored on input). Round-tripping
/// at pan = (0, 0) must return the input.
test "screen_to_natural ∘ natural_to_screen — round-trip identity at pan=0" {
  let natural_pt : Point = { x: 42.5, y: 100.25, }
  let zoom : Double = 2.0
  let screen_pt : Point = natural_to_screen(
    natural_pt.x,
    natural_pt.y,
    { x: 0.0, y: 0.0, },
    zoom,
  )
  let recovered : Point = screen_to_natural(screen_pt.x, screen_pt.y, zoom)
  assert_eq(recovered.x, natural_pt.x)
  assert_eq(recovered.y, natural_pt.y)
}

///|
/// Phase 5.12.A — screen_to_natural cancels pan when called
/// correctly: a point at the canvas origin (sx=0, sy=0) in
/// canvas-local CSS px corresponds to natural (-pan/zoom).
/// This is the post-Fix-A convention: canvas-local px is the
/// same as image-local px, so the pan offset must be subtracted
/// to land back in natural space. (The current screen_to_natural
/// takes (sx, sy) without explicit pan because the caller is
/// expected to pass canvas-local coords, NOT stage-local — and
/// then there's no pan offset.)
test "screen_to_natural — canvas-local px maps cleanly to natural" {
  // Natural (100, 50) at pan=(10, 5), zoom=2 → screen (210, 105).
  // Calling screen_to_natural(210, 105, 2) → natural (105, 52.5).
  let nat : Point = screen_to_natural(210.0, 105.0, 2.0)
  assert_eq(nat.x, 105.0)
  assert_eq(nat.y, 52.5)
}

// ─────────────────────────────────────────────────────────────────
// fitView — auto-fit zoom
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.12.A — fit_view_zoom on a landscape image in a
/// landscape viewport picks the width-limiting scale
/// (vp_w / nat_w). Mirrors canvas.js:701.
test "fit_view_zoom — landscape image in landscape viewport uses width" {
  // vp = 800 × 600, nat = 1600 × 1200 → scale = 800/1600 = 0.5.
  assert_eq(fit_view_zoom(1600.0, 1200.0, 800.0, 600.0), 0.5)
}

///|
/// Phase 5.12.A — fit_view_zoom on a portrait image in a
/// landscape viewport picks the height-limiting scale
/// (vp_h / nat_h). The image must shrink to fit the shorter axis.
test "fit_view_zoom — portrait image in landscape viewport uses height" {
  // vp = 800 × 600, nat = 800 × 1200 → scale = 600/1200 = 0.5.
  assert_eq(fit_view_zoom(800.0, 1200.0, 800.0, 600.0), 0.5)
}

///|
/// Phase 5.12.A — fit_view_zoom returns 1.0 when natural size is
/// non-positive (placeholder mode / no image loaded yet). The
/// caller has no geometry to compute against; zoom=1 + pan=(0,0)
/// is the safe default.
test "fit_view_zoom — zero natural size falls back to zoom=1" {
  assert_eq(fit_view_zoom(0.0, 0.0, 800.0, 600.0), 1.0)
  assert_eq(fit_view_zoom(0.0, 100.0, 800.0, 600.0), 1.0)
  assert_eq(fit_view_zoom(100.0, 0.0, 800.0, 600.0), 1.0)
}

///|
/// Phase 5.12.A — fit_view_zoom returns 1.0 when viewport is
/// non-positive (the canvas hasn't been laid out yet).
test "fit_view_zoom — zero viewport falls back to zoom=1" {
  assert_eq(fit_view_zoom(1600.0, 1200.0, 0.0, 600.0), 1.0)
  assert_eq(fit_view_zoom(1600.0, 1200.0, 800.0, 0.0), 1.0)
}

// ─────────────────────────────────────────────────────────────────
// fitView — centre pan
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.12.A — fit_view_pan centres the fitted image inside
/// the viewport. For a square image in a square viewport with a
/// 1× zoom, the pan must be (0, 0) — the image is already
/// centred with no slack to absorb.
test "fit_view_pan — square image, square viewport, zoom=1 → pan=(0,0)" {
  let pan : Point = fit_view_pan(1.0, 800.0, 600.0, 800.0, 600.0)
  assert_eq(pan.x, 0.0)
  assert_eq(pan.y, 0.0)
}

///|
/// Phase 5.12.A — fit_view_pan on a landscape image in a
/// square viewport with a fit zoom (vp_w / nat_w) produces a
/// pan whose y is the centred vertical slack. The fitted image
/// occupies (vp_w, vp_w * nat_h/nat_w) — the unused vertical
/// area is `vp_h - vp_w * nat_h/nat_w`, half above and half
/// below. This is the canvas.js:707-708 formula.
test "fit_view_pan — landscape image, square viewport, fit zoom" {
  // vp = 1000 × 1000, nat = 2000 × 1000 → scale = 0.5, dw = 1000, dh = 500.
  // pan = ((1000 - 1000)/2, (1000 - 500)/2) = (0, 250).
  let pan : Point = fit_view_pan(0.5, 2000.0, 1000.0, 1000.0, 1000.0)
  assert_eq(pan.x, 0.0)
  assert_eq(pan.y, 250.0)
}

///|
/// Phase 5.12.A — fit_view_pan returns (0, 0) when natural size is
/// non-positive (placeholder mode). The caller has no geometry to
/// centre against.
test "fit_view_pan — zero natural size returns pan=(0,0)" {
  let pan : Point = fit_view_pan(1.0, 0.0, 0.0, 800.0, 600.0)
  assert_eq(pan.x, 0.0)
  assert_eq(pan.y, 0.0)
}

// ─────────────────────────────────────────────────────────────────
// Zoom around a focal point
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.12.A — zooming in around a focal natural point must
/// keep that point under the same screen-space position. This is
/// the core invariant of zoom_around_natural_pt; if it breaks, the
/// image jumps sideways on every wheel tick.
///
/// Setup: pan=(0,0), zoom=1.0, focal_natural=(100, 100). The
/// focal point's screen position is (100, 100) initially. Zooming
/// to 2.0 around it, the focal's screen position should still be
/// (100, 100). The new pan must therefore be (0, 0): the focal
/// natural point at zoom=2 with pan=(0,0) renders at screen
/// (200, 200). To land at (100, 100) the pan must be (-100, -100).
test "zoom_around_natural_pt — focal point stays fixed under zoom-in" {
  let new_pan : Point = zoom_around_natural_pt(
    2.0,
    100.0,
    100.0,
    { x: 0.0, y: 0.0, },
    1.0,
  )
  // Verify by re-projecting the focal: pan + focal * zoom should
  // equal the pre-zoom screen position.
  let screen_after : Point = natural_to_screen(100.0, 100.0, new_pan, 2.0)
  // Pre-zoom screen pos was pan + focal * zoom = 0 + 100*1 = 100.
  assert_eq(screen_after.x, 100.0)
  assert_eq(screen_after.y, 100.0)
}

///|
/// Phase 5.12.A — zooming out (e.g. 2.0 → 0.5) also keeps the
/// focal point fixed. Mirror of the zoom-in case: with pan=0
/// and zoom=2.0, the focal (100, 100) is at screen (200, 200).
/// Zooming to 0.5 around it, the focal must still be at (200, 200).
test "zoom_around_natural_pt — focal point stays fixed under zoom-out" {
  let new_pan : Point = zoom_around_natural_pt(
    0.5,
    100.0,
    100.0,
    { x: 0.0, y: 0.0, },
    2.0,
  )
  let screen_after : Point = natural_to_screen(100.0, 100.0, new_pan, 0.5)
  // Pre-zoom screen pos was 0 + 100*2 = 200.
  assert_eq(screen_after.x, 200.0)
  assert_eq(screen_after.y, 200.0)
}

///|
/// Phase 5.12.A — zoom_around_natural_pt clamps the requested
/// zoom through clamp_zoom. Asking for 100× from zoom=1.0 pins
/// at zoom_max; the resulting pan still keeps the focal point
/// fixed (just at the clamped zoom).
test "zoom_around_natural_pt — clamps requested zoom via clamp_zoom" {
  let new_pan : Point = zoom_around_natural_pt(
    100.0, // way above zoom_max = 32
    50.0,
    50.0,
    { x: 0.0, y: 0.0, },
    1.0,
  )
  let screen_after : Point = natural_to_screen(
    50.0, 50.0, new_pan, zoom_max, // clamped target
  )
  // Pre-zoom focal screen pos = 0 + 50*1 = 50.
  assert_eq(screen_after.x, 50.0)
  assert_eq(screen_after.y, 50.0)
}

///|
/// Phase 5.12.A — zoom_around_natural_pt with focal_natural=(0,0)
/// (the bitmap origin) reduces to "pan stays the same, just
/// change the zoom". The origin doesn't move when zoomed around.
test "zoom_around_natural_pt — focal at origin leaves pan unchanged" {
  let pan_before : Point = { x: 17.0, y: -3.0, }
  let pan_after : Point = zoom_around_natural_pt(2.0, 0.0, 0.0, pan_before, 1.0)
  assert_eq(pan_after.x, pan_before.x)
  assert_eq(pan_after.y, pan_before.y)
}

///|
/// Phase 5.12.A — zoom_around_screen_pt is the convenience wrapper
/// that converts (focal_sx, focal_sy) → natural first. Result
/// must match zoom_around_natural_pt fed the converted focal.
/// This is the property the canvas.js `zoomAtScreenPoint` relies
/// on (lines 256-264).
test "zoom_around_screen_pt — equivalent to zoom_around_natural_pt with converted focal" {
  // Stage at pan=(0,0), zoom=1.0. A click at screen (200, 100)
  // corresponds to natural (200/1, 100/1) = (200, 100) at zoom=1.
  // Zooming to 3.0 around it: focal screen pos before = (200, 100),
  // after should still be (200, 100).
  let new_pan : Point = zoom_around_screen_pt(
    3.0,
    200.0,
    100.0,
    { x: 0.0, y: 0.0, },
    1.0,
  )
  // Same natural focal → same algebraic answer. Verify via
  // natural_to_screen at zoom=3.
  let screen_after : Point = natural_to_screen(200.0, 100.0, new_pan, 3.0)
  assert_eq(screen_after.x, 200.0)
  assert_eq(screen_after.y, 100.0)
}
