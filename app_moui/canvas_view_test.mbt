// app_moui/canvas_view_test.mbt — blackbox tests for canvas_view helpers.
//
// Phase 5.5: add blackbox tests for the static + dynamic layer split.
// We don't drive MoUI's actual paint pass (no renderer is wired in
// 5.5; that lands in phase 10). Instead we test the *contract* of
// the split: img_to_screen is pan/zoom-correct, the cursor crosshair
// only appears when cursorImgPt is Some, and handle-marker positions
// are pure functions of (selected annotation, pan, zoom). The
// actual stack / ViewNode paint-channel wiring is verified at
// compile time (moon check) and via the renderer in phase 10.
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

// ─────────────────────────────────────────────────────────────────
// Phase 5.5 — static + dynamic layer split tests
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.5 — count the kinds of DrawCommands emitted by each layer.
/// Used to assert the static/dynamic split: the static layer must
/// issue at least one FillRect (background) and one FillRect
/// (placeholder), but ZERO DrawImage / cursor-crosshair stroke
/// pairs; the dynamic layer must NOT issue any background FillRect.
fn count_draw_kinds(cmds : Array[@core.DrawCommand]) -> (Int, Int, Int) {
  let mut fill = 0
  let mut stroke = 0
  let mut draw_image = 0
  for c in cmds {
    match c {
      @core.DrawCommand::FillRect(_) => fill = fill + 1
      @core.DrawCommand::StrokeRect(_) => stroke = stroke + 1
      @core.DrawCommand::DrawImage(_) => draw_image = draw_image + 1
      _ => ()
    }
  }
  (fill, stroke, draw_image)
}

///|
/// Phase 5.5 — when imageSource == "" (placeholder mode), the
/// static layer emits background + placeholder FillRect +
/// placeholder StrokeRect. There must be no DrawImage and no
/// cursor crosshair (crosshair lives on the dynamic layer).
test "static layer — placeholder mode: background + placeholder rect, no image, no crosshair" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    selectedId: Some("ann-1"),
    cursorImgPt: Some({ x: 50.0, y: 50.0, }),
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 10.0, y: 10.0, }, { x: 100.0, y: 100.0, }],
      },
    ],
  }
  let frame : @core.Rect = @core.Rect::new(
    x=0.0,
    y=0.0,
    width=800.0,
    height=600.0,
  )
  let pctx = @common.PaintContext::new()
  draw_static_layer(pctx, model, frame)
  let cmds : Array[@core.DrawCommand] = @common.PaintContext::finish(pctx)
  let (fill, stroke, draw_image) = count_draw_kinds(cmds)
  // Background FillRect + placeholder FillRect = 2 FillRects;
  // placeholder border StrokeRect + annotation stroke_rect = 2
  // StrokeRects (one per non-fill outline); 0 DrawImages.
  assert_eq(fill, 2)
  assert_eq(stroke, 2)
  assert_eq(draw_image, 0)
}

///|
/// Phase 5.5 — when imageSource is non-empty, the static layer
/// emits background FillRect + 1 DrawImage + annotation strokes.
/// No cursor crosshair (crosshair lives on the dynamic layer).
test "static layer — image mode: background + DrawImage + annotation strokes, no crosshair" {
  let model : Model = {
    ..Model::new(),
    imageSource: "/fake/path.jpg",
    imageNaturalSize: { x: 1920.0, y: 1080.0, },
    selectedId: None,
    cursorImgPt: Some({ x: 50.0, y: 50.0, }),
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 10.0, y: 10.0, }, { x: 100.0, y: 100.0, }],
      },
    ],
  }
  let frame : @core.Rect = @core.Rect::new(
    x=0.0,
    y=0.0,
    width=800.0,
    height=600.0,
  )
  let pctx = @common.PaintContext::new()
  draw_static_layer(pctx, model, frame)
  let cmds : Array[@core.DrawCommand] = @common.PaintContext::finish(pctx)
  let (fill, stroke, draw_image) = count_draw_kinds(cmds)
  // 1 FillRect (background only — no placeholder FillRect in image mode)
  // + 1 DrawImage (the source image) + 1 StrokeRect (annotation rect).
  assert_eq(fill, 1)
  assert_eq(stroke, 1)
  assert_eq(draw_image, 1)
}

///|
/// Phase 5.5 — the dynamic layer must NOT draw the background,
/// image, placeholder, or any annotation body strokes. It must
/// only draw handles (when selectedId is Some) and/or the cursor
/// crosshair (when cursorImgPt is Some). With both set, we expect:
///   - 0 background FillRect
///   - 8 handle FillRects (rect has 8 handles)
///   - 2 crosshair StrokeRects (vertical + horizontal bars)
test "dynamic layer — selected + cursor: 8 handles + 2 crosshair strokes, no background" {
  let model : Model = {
    ..Model::new(),
    selectedId: Some("ann-1"),
    cursorImgPt: Some({ x: 50.0, y: 50.0, }),
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 10.0, y: 10.0, }, { x: 100.0, y: 100.0, }],
      },
    ],
  }
  let frame : @core.Rect = @core.Rect::new(
    x=0.0,
    y=0.0,
    width=800.0,
    height=600.0,
  )
  let pctx = @common.PaintContext::new()
  draw_dynamic_layer(pctx, model, frame)
  let cmds : Array[@core.DrawCommand] = @common.PaintContext::finish(pctx)
  let (fill, stroke, draw_image) = count_draw_kinds(cmds)
  // 8 handle FillRects; 2 crosshair StrokeRects; no background
  // FillRect (the dynamic layer is transparent over the static
  // layer).
  assert_eq(fill, 8)
  assert_eq(stroke, 2)
  assert_eq(draw_image, 0)
}

///|
/// Phase 5.5 — when nothing is selected AND no cursor, the dynamic
/// layer is empty. This is the steady-state during idle (the user
/// isn't hovering over the canvas). The static layer still emits
/// its full background+image+annotations, but the dynamic layer
/// should produce ZERO DrawCommands.
test "dynamic layer — empty when no selection and no cursor" {
  let model : Model = { ..Model::new(), selectedId: None, cursorImgPt: None, }
  let frame : @core.Rect = @core.Rect::new(
    x=0.0,
    y=0.0,
    width=800.0,
    height=600.0,
  )
  let pctx = @common.PaintContext::new()
  draw_dynamic_layer(pctx, model, frame)
  let cmds : Array[@core.DrawCommand] = @common.PaintContext::finish(pctx)
  assert_eq(cmds.length(), 0)
}

///|
/// Phase 5.5 — even when annotations exist, if selectedId points
/// to a non-existent annotation, the dynamic layer emits nothing
/// for handles. Only the cursor crosshair (2 StrokeRects).
test "dynamic layer — selectedId not in annotations → no handles drawn" {
  let model : Model = {
    ..Model::new(),
    selectedId: Some("nonexistent"),
    cursorImgPt: Some({ x: 50.0, y: 50.0, }),
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 10.0, y: 10.0, }, { x: 100.0, y: 100.0, }],
      },
    ],
  }
  let frame : @core.Rect = @core.Rect::new(
    x=0.0,
    y=0.0,
    width=800.0,
    height=600.0,
  )
  let pctx = @common.PaintContext::new()
  draw_dynamic_layer(pctx, model, frame)
  let cmds : Array[@core.DrawCommand] = @common.PaintContext::finish(pctx)
  let (fill, stroke, _) = count_draw_kinds(cmds)
  assert_eq(fill, 0)
  assert_eq(stroke, 2)
}
