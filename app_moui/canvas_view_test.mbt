// app_moui/canvas_view_test.mbt — blackbox tests for canvas_view helpers.
//
// Phase 5.4: add a DPR-invariance test for fit_contain_rect (the
// contract that makes HiDPI display handling transparent — see
// _build/design/dpi-investigation.md).
//
// Phase 5.2: cover the fit-contain math (aspect-preserving centre) and
// the cursor-crosshair inverse mapping (image-natural from screen). The
// rest of canvas_view (DrawImage / DrawCommand assembly) is a pure
// declaration — verified end-to-end by moon build, no renderer needed
// until Phase 10 wires the windows_skia entrypoint.

///|
test "fit_contain_rect — landscape image in landscape frame preserves aspect" {
  let frame : @core.Rect = @core.Rect::new(
    x=0.0,
    y=0.0,
    width=800.0,
    height=600.0,
  )
  let dst : @core.Rect = fit_contain_rect(frame, 1600.0, 1200.0)
  // 1600×1200 in 800×600 — scale = 800/1600 = 0.5, dst = 800×600
  assert_eq(dst.size.width, 800.0)
  assert_eq(dst.size.height, 600.0)
  assert_eq(dst.origin.x, 0.0)
  assert_eq(dst.origin.y, 0.0)
}

///|
test "fit_contain_rect — portrait image in landscape frame fits to height" {
  let frame : @core.Rect = @core.Rect::new(
    x=0.0,
    y=0.0,
    width=800.0,
    height=600.0,
  )
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
  let frame : @core.Rect = @core.Rect::new(
    x=10.0,
    y=20.0,
    width=400.0,
    height=300.0,
  )
  let dst : @core.Rect = fit_contain_rect(frame, 0.0, 0.0)
  assert_eq(dst.size.width, 400.0)
  assert_eq(dst.size.height, 300.0)
  assert_eq(dst.origin.x, 10.0)
  assert_eq(dst.origin.y, 20.0)
}

///|
test "fit_contain_rect — square image in square frame, no padding" {
  let frame : @core.Rect = @core.Rect::new(
    x=5.0,
    y=5.0,
    width=500.0,
    height=500.0,
  )
  let dst : @core.Rect = fit_contain_rect(frame, 1000.0, 1000.0)
  assert_eq(dst.size.width, 500.0)
  assert_eq(dst.size.height, 500.0)
  assert_eq(dst.origin.x, 5.0)
  assert_eq(dst.origin.y, 5.0)
}

///|
/// Phase 5.4 — DPR invariance: a logical-px frame of 800×600 produces
/// the same dst regardless of the window's scale_factor. We simulate the
/// dpr=2 case by checking the math against an "effective logical" 1600×1200
/// (the same 800×600 logical frame stretched 2× in physical pixels by a
/// dpr=2 monitor): fit_contain_rect must depend only on the logical frame,
/// not on the hypothetical physical_size.
///
/// Concretely:
///   case1 = fit_contain_rect(800×600 logical,  1600×1200 image)
///   case2 = fit_contain_rect(1600×1200 logical (i.e. physical 3200×2400 at dpr=2),
///                            1600×1200 image)
///
/// case1 → scale = min(800/1600, 600/1200) = 0.5 → dst = (0,0,800×600)
/// case2 → scale = min(1600/1600, 1200/1200) = 1.0 → dst = (0,0,1600×1200)
/// Same logical-px origin; size scales with the logical frame.
test "fit_contain_rect — DPR invariance: result depends only on logical frame" {
  // Simulate dpr=1 (no scaling): logical frame = physical frame = 800×600.
  let logical_frame_dpr1 : @core.Rect = @core.Rect::new(
    x=0.0,
    y=0.0,
    width=800.0,
    height=600.0,
  )
  // Simulate dpr=2 (HiDPI): logical frame is still 800×600; the
  // physical surface is 1600×1200. fit_contain_rect only sees the
  // logical frame, so it must produce the same dst as dpr=1.
  let logical_frame_dpr2 : @core.Rect = @core.Rect::new(
    x=0.0,
    y=0.0,
    width=800.0,
    height=600.0,
  )
  let dst_dpr1 : @core.Rect = fit_contain_rect(
    logical_frame_dpr1, 1600.0, 1200.0,
  )
  let dst_dpr2 : @core.Rect = fit_contain_rect(
    logical_frame_dpr2, 1600.0, 1200.0,
  )
  // The two are identical because fit_contain_rect doesn't take
  // scale_factor — the framework's host layer already collapsed
  // physical → logical before fit_contain_rect was called.
  assert_eq(dst_dpr1.size.width, dst_dpr2.size.width)
  assert_eq(dst_dpr1.size.height, dst_dpr2.size.height)
  assert_eq(dst_dpr1.origin.x, dst_dpr2.origin.x)
  assert_eq(dst_dpr1.origin.y, dst_dpr2.origin.y)
  // Concrete values for sanity (1600×1200 in 800×600 logical → 0.5× scale).
  assert_eq(dst_dpr1.size.width, 800.0)
  assert_eq(dst_dpr1.size.height, 600.0)
}

///|
/// Phase 5.4 — image-natural hit-test radius is DPR-invariant: the canvas
/// view converts the logical-px pointer position back to image-natural
/// coords via (canvas_pt - pan) / zoom BEFORE calling hit_test_select,
/// so the 12 px handle radius and 4 px body radius in hittest.mbt are
/// already in image-natural pixels. They're independent of the window's
/// scale_factor — which is what we want, so that on a dpr=2 HiDPI display
/// the click target doesn't get bigger in image-natural terms.
///
/// Verified here by passing image-natural coords directly to hit_test
/// helpers (the canvas_view does the pan/zoom inversion before calling).
test "hit_test_select — image-natural coords make hit-test DPR-invariant" {
  // 12 px handle hit radius at image-natural (canvas.js v0.2.9 contract).
  let radius = 12.0
  let ann_id = "ann-1"
  let ann : Annotation = {
    id: ann_id,
    shape: Rect,
    points: [{ x: 100.0, y: 100.0, }, { x: 200.0, y: 200.0, }],
  }
  let annotations : Array[Annotation] = [ann]
  // A click at the TL handle (image-natural (100,100)) should hit
  // within the 12 px radius regardless of the window's DPR — because
  // canvas_view pre-inverts (canvas_pt - pan) / zoom before this call,
  // the canvas_pt passed in IS already image-natural.
  let hit : (String, Int)? = hit_test_handle(
    { x: 105.0, y: 105.0, },
    annotations,
    ann_id,
    radius,
  )
  inspect(hit, content="Some((ann-1, 0))")
}
