// app_moui/canvas_view_test.mbt — blackbox tests for canvas_view helpers.
//
// Phase 5.2: cover the fit-contain math (aspect-preserving centre) and
// the cursor-crosshair inverse mapping (image-natural from screen). The
// rest of canvas_view (DrawImage / DrawCommand assembly) is a pure
// declaration — verified end-to-end by moon build, no renderer needed
// until Phase 10 wires the windows_skia entrypoint.

///|
test "fit_contain_rect — landscape image in landscape frame preserves aspect" {
  let frame : @core.Rect = @core.Rect::new(x=0.0, y=0.0, width=800.0, height=600.0)
  let dst : @core.Rect = fit_contain_rect(frame, 1600.0, 1200.0)
  // 1600×1200 in 800×600 — scale = 800/1600 = 0.5, dst = 800×600
  assert_eq(dst.size.width, 800.0)
  assert_eq(dst.size.height, 600.0)
  assert_eq(dst.origin.x, 0.0)
  assert_eq(dst.origin.y, 0.0)
}

///|
test "fit_contain_rect — portrait image in landscape frame fits to height" {
  let frame : @core.Rect = @core.Rect::new(x=0.0, y=0.0, width=800.0, height=600.0)
  let dst : @core.Rect = fit_contain_rect(frame, 600.0, 1200.0)
  // 600×1200 in 800×600 — scale = min(800/600, 600/1200) = 0.5.
  // dst = 300×600, centred horizontally → x offset = 250.
  assert_eq(dst.size.width, 300.0)
  assert_eq(dst.size.height, 600.0)
  assert_eq(dst.origin.x, 250.0)
  assert_eq(dst.origin.y, 0.0)
}

///|
test "fit_contain_rect — zero natural size falls back to fill" {
  let frame : @core.Rect = @core.Rect::new(x=10.0, y=20.0, width=400.0, height=300.0)
  let dst : @core.Rect = fit_contain_rect(frame, 0.0, 0.0)
  assert_eq(dst.size.width, 400.0)
  assert_eq(dst.size.height, 300.0)
  assert_eq(dst.origin.x, 10.0)
  assert_eq(dst.origin.y, 20.0)
}

///|
test "fit_contain_rect — square image in square frame, no padding" {
  let frame : @core.Rect = @core.Rect::new(x=5.0, y=5.0, width=500.0, height=500.0)
  let dst : @core.Rect = fit_contain_rect(frame, 1000.0, 1000.0)
  assert_eq(dst.size.width, 500.0)
  assert_eq(dst.size.height, 500.0)
  assert_eq(dst.origin.x, 5.0)
  assert_eq(dst.origin.y, 5.0)
}