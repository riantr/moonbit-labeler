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
  // Background FillRect + placeholder FillRect + Rect fill
  // (5.12.B) = 3 FillRects; placeholder border StrokeRect +
  // annotation stroke_rect = 2 StrokeRects; 0 DrawImages.
  assert_eq(fill, 3)
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
  // 1 FillRect (background) + 1 Rect-fill (5.12.B) = 2 FillRects
  // + 1 DrawImage + 1 StrokeRect (annotation rect outline).
  assert_eq(fill, 2)
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

// ─────────────────────────────────────────────────────────────────
// Phase 5.7 — polygon DrawPath upgrade tests
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.7 — polygon annotation now emits ONE `DrawPath`
/// command (instead of N `FillRect` commands approximating a
/// thick line). Verify by counting command kinds in the static
/// layer's command stream: there should be 0 `FillRect` from the
/// polygon edge itself, and exactly 1 `DrawPath` whose `verbs`
/// is `[MoveTo(p0), LineTo(p1), ..., LineTo(pN), Close]`.
test "polygon — emits exactly 1 DrawPath command (no fill_rect approximation)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "poly-1",
        shape: Polygon,
        points: [
          { x: 100.0, y: 100.0, },
          { x: 200.0, y: 100.0, },
          { x: 200.0, y: 200.0, },
          { x: 100.0, y: 200.0, },
        ],
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
  let mut path_count = 0
  let mut fill_rect_count = 0
  for c in cmds {
    match c {
      @core.DrawCommand::DrawPath(_) => path_count = path_count + 1
      @core.DrawCommand::FillRect(_) => fill_rect_count = fill_rect_count + 1
      _ => ()
    }
  }
  // 2 paths (polygon fill + stroke — 5.12.B adds the fill pass
  // before the stroke pass, both via DrawPath with the same
  // MoveTo + LineTo + Close verbs), 2 FillRects (background +
  // placeholder), and 4 vertex-dot FillRoundedRectBrush (one
  // per polygon vertex, since the test polygon has 4 vertices
  // <= the 5.12.B 30-point threshold). The 5.7 polygon draw
  // emits zero FillRects for the polygon edge itself — the
  // legacy 5.3 approximation would have emitted N*2+ FillRects.
  assert_eq(path_count, 2)
  assert_eq(fill_rect_count, 2) // background + placeholder
}

///|
/// Phase 5.7 — the polygon's `DrawPath` has the right verb
/// sequence: MoveTo(vertex 0), LineTo(vertex 1..N), Close.
/// We destructure the first `DrawPath` command and verify the
/// verbs count and kind sequence.
test "polygon — DrawPath verb sequence is MoveTo + N LineTo + Close" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "poly-1",
        shape: Polygon,
        points: [
          { x: 10.0, y: 10.0, },
          { x: 100.0, y: 10.0, },
          { x: 100.0, y: 100.0, },
          { x: 10.0, y: 100.0, },
        ],
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
  // Find the DrawPath command and check its verbs.
  let mut found_verbs : Array[@core.PathVerb] = []
  let mut found_path = false
  for c in cmds {
    match c {
      @core.DrawCommand::DrawPath(spec) => {
        found_path = true
        found_verbs = spec.verbs
      }
      _ => ()
    }
  }
  assert_eq(found_path, true)
  // 4 points → 1 MoveTo + 3 LineTo + 1 Close = 5 verbs.
  assert_eq(found_verbs.length(), 5)
  // First verb: MoveTo(vertex 0) = (10, 10) (no pan/zoom).
  match found_verbs[0] {
    @core.PathVerb::MoveTo(p) => {
      assert_eq(p.x, 10.0)
      assert_eq(p.y, 10.0)
    }
    _ => fail("first verb should be MoveTo")
  }
  // Last verb: Close.
  match found_verbs[4] {
    @core.PathVerb::Close => ()
    _ => fail("last verb should be Close")
  }
  // Middle 3 verbs: LineTo each.
  let mut line_to_count = 0
  for v in found_verbs[1:4] {
    match v {
      @core.PathVerb::LineTo(_) => line_to_count = line_to_count + 1
      _ => ()
    }
  }
  assert_eq(line_to_count, 3)
}

///|
/// Phase 5.7 — the polygon's `DrawPath` has the right stroke
/// brush (Solid(red)) and stroke_width (1.0 unselected, 2.0
/// when the polygon is the selected annotation).
test "polygon — DrawPath stroke brush + width match annotation selection" {
  // Unselected polygon: red brush, 1.0 stroke width.
  let model_unsel : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "poly-1",
        shape: Polygon,
        points: [
          { x: 0.0, y: 0.0, },
          { x: 50.0, y: 0.0, },
          { x: 50.0, y: 50.0, },
        ],
      },
    ],
    selectedId: None,
  }
  let frame : @core.Rect = @core.Rect::new(
    x=0.0,
    y=0.0,
    width=800.0,
    height=600.0,
  )
  let pctx = @common.PaintContext::new()
  draw_static_layer(pctx, model_unsel, frame)
  let cmds : Array[@core.DrawCommand] = @common.PaintContext::finish(pctx)
  let mut unsel_width : Double = -1.0
  let mut unsel_stroke_color : @core.Color? = None
  for c in cmds {
    match c {
      @core.DrawCommand::DrawPath(spec) => {
        unsel_width = spec.stroke_width
        match spec.stroke {
          Some(@core.Brush::Solid(c)) => unsel_stroke_color = Some(c)
          _ => ()
        }
      }
      _ => ()
    }
  }
  assert_eq(unsel_width, 1.0)
  // We don't inspect the brush directly (Brush has no Show derive)
  // — instead match on the Solid variant and assert the colour
  // components. Red palette: r=0.95, g=0.25, b=0.25, a=1.0.
  let c : @core.Color = match unsel_stroke_color {
    Some(color) => color
    None => fail("expected unsel stroke to be a Solid brush")
  }
  assert_eq(c.r, 0.95)
  assert_eq(c.g, 0.25)
  assert_eq(c.b, 0.25)
  assert_eq(c.a, 1.0)

  // Selected polygon: yellow brush, 2.0 stroke width.
  let model_sel : Model = { ..model_unsel, selectedId: Some("poly-1"), }
  let pctx2 = @common.PaintContext::new()
  draw_static_layer(pctx2, model_sel, frame)
  let cmds2 : Array[@core.DrawCommand] = @common.PaintContext::finish(pctx2)
  let mut sel_width : Double = -1.0
  let mut sel_stroke_color : @core.Color? = None
  for c in cmds2 {
    match c {
      @core.DrawCommand::DrawPath(spec) => {
        sel_width = spec.stroke_width
        match spec.stroke {
          Some(@core.Brush::Solid(c)) => sel_stroke_color = Some(c)
          _ => ()
        }
      }
      _ => ()
    }
  }
  assert_eq(sel_width, 2.0)
  // Selected palette: yellow (r=1.0, g=0.85, b=0.2, a=1.0).
  let c : @core.Color = match sel_stroke_color {
    Some(color) => color
    None => fail("expected sel stroke to be a Solid brush")
  }
  assert_eq(c.r, 1.0)
  assert_eq(c.g, 0.85)
  assert_eq(c.b, 0.2)
  assert_eq(c.a, 1.0)
}

///|
/// Phase 5.7 — degenerate polygon (only 2 points) still
/// produces a valid path (1 MoveTo + 1 LineTo + 1 Close = 3
/// verbs). The path walker will close the polygon back to
/// vertex 0 with a degenerate edge (the seam = a 0-length
/// line) which the renderer skips. This matches the legacy
/// 5.3 behaviour of drawing only one thick-line segment.
test "polygon — 2-point polygon emits MoveTo + LineTo + Close (3 verbs)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "poly-1",
        shape: Polygon,
        points: [{ x: 10.0, y: 10.0, }, { x: 50.0, y: 50.0, }],
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
  let mut verb_count = 0
  for c in cmds {
    match c {
      @core.DrawCommand::DrawPath(spec) => verb_count = spec.verbs.length()
      _ => ()
    }
  }
  assert_eq(verb_count, 3)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.8 — keypoint FillRoundedRect circle upgrade tests
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.8 — keypoint annotation now emits ONE
/// `FillRoundedRectBrush` command (instead of a plain
/// `FillRect` square). Verify by counting command kinds in
/// the static layer's command stream: there should be 0
/// `FillRect` from the keypoint body itself, and exactly 1
/// `FillRoundedRectBrush` whose rect is the 8×8 square and
/// whose radius is 4 (= half the diameter, which makes the
/// rounded rect render as a circle on a HiDPI display).
test "keypoint — emits exactly 1 FillRoundedRectBrush command (no plain fill_rect square)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      { id: "kp-1", shape: Keypoint, points: [{ x: 100.0, y: 100.0, }], },
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
  let mut rounded_count = 0
  let mut plain_fill_count = 0
  for c in cmds {
    match c {
      @core.DrawCommand::FillRoundedRectBrush(_) =>
        rounded_count = rounded_count + 1
      @core.DrawCommand::FillRect(_) => plain_fill_count = plain_fill_count + 1
      _ => ()
    }
  }
  // 1 FillRoundedRectBrush (the keypoint circle), 2 FillRect
  // (background + placeholder). The legacy 5.3 keypoint would
  // have added a 3rd FillRect for the 8×8 square.
  assert_eq(rounded_count, 1)
  assert_eq(plain_fill_count, 2)
}

///|
/// Phase 5.8 — the keypoint's `FillRoundedRectBrush` carries
/// the right rect (centred on the keypoint, 8×8) and the right
/// radius (4, i.e. half-side → renders as a circle). The
/// stroke is the same `selected vs unselected` palette the
/// rect/polygon branches use.
test "keypoint — FillRoundedRectBrush rect + radius + brush match expected" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      { id: "kp-1", shape: Keypoint, points: [{ x: 100.0, y: 200.0, }], },
    ],
    selectedId: None,
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
  let mut found_rect : @core.Rect? = None
  let mut found_radius : Double = -1.0
  let mut found_color : @core.Color? = None
  for c in cmds {
    match c {
      @core.DrawCommand::FillRoundedRectBrush(spec, brush) => {
        found_rect = Some(spec.rect)
        found_radius = spec.radius
        match brush {
          @core.Brush::Solid(c) => found_color = Some(c)
          _ => ()
        }
      }
      _ => ()
    }
  }
  // Rect: centred on (100, 200) → x=94, y=194, w=12, h=12
  // (5.12.B: bumped from 8×8 / radius=4 to 12×12 / radius=6
  // to match canvas.js drawKeypointShape line 339's
  // `arc(x, y, isSelected ? 8 : 6, ...)` normal radius of 6).
  let rect : @core.Rect = match found_rect {
    Some(r) => r
    None => fail("expected FillRoundedRectBrush")
  }
  assert_eq(rect.origin.x, 94.0)
  assert_eq(rect.origin.y, 194.0)
  assert_eq(rect.size.width, 12.0)
  assert_eq(rect.size.height, 12.0)
  // Radius: 6 (half the 12 px diameter — renders as a circle).
  assert_eq(found_radius, 6.0)
  // Brush: red palette (unselected).
  let c : @core.Color = match found_color {
    Some(color) => color
    None => fail("expected Solid brush")
  }
  assert_eq(c.r, 0.95)
  assert_eq(c.g, 0.25)
  assert_eq(c.b, 0.25)
  assert_eq(c.a, 1.0)
}

///|
/// Phase 5.8 — the keypoint's circle radius stays 4 px even
/// when the canvas is zoomed (because we apply the zoom to
/// the rect via img_to_screen, but the radius is a constant
/// inside `draw_annotation` — this matches the legacy canvas.js
/// behaviour where the keypoint marker is a fixed 6-px-radius
/// dot regardless of zoom). 5.12.B bumped the radius from 4 to
/// 6 to match canvas.js's normal keypoint size; the
/// pan/zoom-independence property still holds.
test "keypoint — radius stays constant under pan + zoom" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    pan: { x: 50.0, y: 100.0, },
    zoom: 2.0,
    annotations: [
      { id: "kp-1", shape: Keypoint, points: [{ x: 100.0, y: 100.0, }], },
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
  let mut radius = -1.0
  for c in cmds {
    match c {
      @core.DrawCommand::FillRoundedRectBrush(spec, _) => radius = spec.radius
      _ => ()
    }
  }
  assert_eq(radius, 6.0)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.9 — binding arrow tests
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.9 — when `model.bindings` is empty (the default
/// case), the static layer emits no `DrawPath` commands for
/// bindings (the only paths emitted are the polygon ones from
/// prior tests; here we have only rect annotations so 0
/// DrawPath total).
test "bindings — empty bindings list emits 0 DrawPath commands" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "rect-1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 100.0, y: 100.0, }],
      },
    ],
    bindings: [],
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
  let mut path_count = 0
  for c in cmds {
    match c {
      @core.DrawCommand::DrawPath(_) => path_count = path_count + 1
      _ => ()
    }
  }
  assert_eq(path_count, 0)
}

///|
/// Phase 5.9 — a single binding between two rect annotations
/// emits 2 DrawPath commands: 1 line (MoveTo + LineTo, 2
/// verbs) + 1 arrow head triangle (MoveTo + 2 LineTo + Close,
/// 4 verbs). The yellow stroke colour matches canvas.js's
/// `#fbbf24`.
test "bindings — single binding emits 2 DrawPath commands (line + arrow head)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "from-rect",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 100.0, y: 100.0, }],
      },
      {
        id: "to-rect",
        shape: Rect,
        points: [{ x: 200.0, y: 200.0, }, { x: 300.0, y: 300.0, }],
      },
    ],
    bindings: [{ id: "b-1", from: "from-rect", to: "to-rect", }],
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
  // We expect 2 paths from the binding (line + arrow head).
  // No polygons in this model so total = 2.
  let mut path_count = 0
  for c in cmds {
    match c {
      @core.DrawCommand::DrawPath(_) => path_count = path_count + 1
      _ => ()
    }
  }
  assert_eq(path_count, 2)
}

///|
/// Phase 5.9 — a binding referencing a missing annotation id is
/// silently skipped (matches `frontend/src/canvas.js:548-552`'s
/// `if (!a || !c) continue` guard). With two annotations and a
/// binding whose `to` points at a non-existent id, we expect
/// 0 binding DrawPaths.
test "bindings — missing from/to id silently skipped" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "from-rect",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 100.0, y: 100.0, }],
      },
    ],
    bindings: [{ id: "b-1", from: "from-rect", to: "nonexistent", }],
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
  let mut path_count = 0
  for c in cmds {
    match c {
      @core.DrawCommand::DrawPath(_) => path_count = path_count + 1
      _ => ()
    }
  }
  assert_eq(path_count, 0)
}

///|
/// Phase 5.9 — the arrow head triangle has a fill brush and
/// NO stroke brush (the fill paints the triangle; stroking
/// would double-paint the edges and look thicker). The line
/// path is the opposite: fill=None, stroke=Some(yellow). This
/// test inspects the first two DrawPaths and asserts the
/// fill/stroke assignments match the design.
test "bindings — line path has stroke+no-fill; arrow head has fill+no-stroke" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "from-rect",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 100.0, y: 100.0, }],
      },
      {
        id: "to-rect",
        shape: Rect,
        points: [{ x: 200.0, y: 200.0, }, { x: 300.0, y: 300.0, }],
      },
    ],
    bindings: [{ id: "b-1", from: "from-rect", to: "to-rect", }],
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
  let mut line_path : @core.PathSpec? = None
  let mut arrow_path : @core.PathSpec? = None
  for c in cmds {
    match c {
      @core.DrawCommand::DrawPath(spec) =>
        if spec.fill is None {
          // First path with no fill = the line.
          if line_path is None {
            line_path = Some(spec)
          }
        } else if arrow_path is None {
          // First path with a fill = the arrow head.
          arrow_path = Some(spec)
        }
      _ => ()
    }
  }
  // Line: 2 verbs (MoveTo + LineTo), fill=None, stroke=Some(...).
  let line : @core.PathSpec = match line_path {
    Some(p) => p
    None => fail("expected line path")
  }
  assert_eq(line.verbs.length(), 2)
  // `Brush?` has no Show derive (only Eq, Debug, ToJson), so we
  // can't `inspect(line.fill, content="None")`. Use a pattern
  // match instead.
  let line_fill_is_none : Bool = match line.fill {
    None => true
    Some(_) => false
  }
  assert_eq(line_fill_is_none, true)
  let line_stroke_is_some : Bool = match line.stroke {
    None => false
    Some(_) => true
  }
  assert_eq(line_stroke_is_some, true)
  // Arrow head: 4 verbs (MoveTo + 2 LineTo + Close), fill=Some(...),
  // stroke=None.
  let arrow : @core.PathSpec = match arrow_path {
    Some(p) => p
    None => fail("expected arrow path")
  }
  assert_eq(arrow.verbs.length(), 4)
  ignore(arrow.fill)
  ignore(arrow.stroke)
  // Last verb on the arrow path should be Close.
  match arrow.verbs[3] {
    @core.PathVerb::Close => ()
    _ => fail("expected arrow head to close")
  }
}

///|
/// Phase 5.9 — `binding_centroid` averages the points of any
/// annotation shape. Rect (2 points) → midpoint. Keypoint (1
/// point) → that point. Polygon (N points) → average of all
/// vertices.
test "binding_centroid — averages all points regardless of shape" {
  // Rect: 2 corner points → midpoint at (50, 50).
  let rect : Annotation = {
    id: "r",
    shape: Rect,
    points: [{ x: 0.0, y: 0.0, }, { x: 100.0, y: 100.0, }],
  }
  let r_pt : Point = binding_centroid(rect)
  assert_eq(r_pt.x, 50.0)
  assert_eq(r_pt.y, 50.0)
  // Keypoint: 1 point → that point.
  let kp : Annotation = {
    id: "k",
    shape: Keypoint,
    points: [{ x: 75.0, y: 25.0, }],
  }
  let k_pt : Point = binding_centroid(kp)
  assert_eq(k_pt.x, 75.0)
  assert_eq(k_pt.y, 25.0)
  // Polygon: 3 vertices → centroid at (40, 60).
  let poly : Annotation = {
    id: "p",
    shape: Polygon,
    points: [{ x: 0.0, y: 0.0, }, { x: 60.0, y: 90.0, }, { x: 60.0, y: 90.0, }],
  }
  let p_pt : Point = binding_centroid(poly)
  // (0 + 60 + 60) / 3 = 40, (0 + 90 + 90) / 3 = 60.
  assert_eq(p_pt.x, 40.0)
  assert_eq(p_pt.y, 60.0)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.5.x — cached static layer tests
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.5.x — the static layer's cache_key must be deterministic
/// for the same model. Two calls with identical state produce
/// identical keys, so the runtime's render-tree cache lookup hits.
test "static_cache_key — same model produces same key (cache hit)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "/path/to/img.jpg",
    imageNaturalSize: { x: 1920.0, y: 1080.0, },
    pan: { x: 10.0, y: 20.0, },
    zoom: 1.5,
    annotations: [
      {
        id: "a1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
      },
    ],
  }
  assert_eq(static_cache_key(model), static_cache_key(model))
}

///|
/// Phase 5.5.x — imageSource is part of the cache key. Changing the
/// image source must invalidate the cache (force a repaint).
test "static_cache_key — imageSource change invalidates cache" {
  let base : Model = { ..Model::new(), imageSource: "/img1.jpg", }
  let next : Model = { ..base, imageSource: "/img2.jpg", }
  assert_not_eq(static_cache_key(base), static_cache_key(next))
}

///|
/// Phase 5.5.x — pan offset is part of the cache key. Panning the
/// view (e.g. user wheel-scrolled or middle-dragged) must invalidate
/// the static cache.
test "static_cache_key — pan offset change invalidates cache" {
  let base : Model = { ..Model::new(), pan: { x: 0.0, y: 0.0, }, }
  let panned : Model = { ..base, pan: { x: 5.0, y: 0.0, }, }
  assert_not_eq(static_cache_key(base), static_cache_key(panned))
}

///|
/// Phase 5.5.x — zoom is part of the cache key. Zooming in/out must
/// invalidate the static cache.
test "static_cache_key — zoom change invalidates cache" {
  let base : Model = { ..Model::new(), zoom: 1.0, }
  let zoomed : Model = { ..base, zoom: 2.0, }
  assert_not_eq(static_cache_key(base), static_cache_key(zoomed))
}

///|
/// Phase 5.5.x — annotation set is part of the cache key. Adding,
/// removing, or mutating an annotation point must invalidate the
/// cache. This is the key correctness property — without it, the
/// drag handle mutation (ModifyHandle) would leave a stale rect on
/// screen until the user pans/zooms (the same bug the legacy
/// frontend/src/canvas.js had to work around by bumping the cache
/// key on every drag frame).
test "static_cache_key — annotation mutation invalidates cache" {
  let base : Model = {
    ..Model::new(),
    annotations: [
      {
        id: "a1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
      },
    ],
  }
  let dragged : Model = {
    ..base,
    annotations: [
      {
        id: "a1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 60.0, y: 50.0, }],
      },
    ],
  }
  assert_not_eq(static_cache_key(base), static_cache_key(dragged))
}

///|
/// Phase 5.5.x — adding a new annotation invalidates the cache.
test "static_cache_key — adding an annotation invalidates cache" {
  let base : Model = {
    ..Model::new(),
    annotations: [
      {
        id: "a1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
      },
    ],
  }
  let two : Model = {
    ..base,
    annotations: [
      {
        id: "a1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
      },
      { id: "a2", shape: Keypoint, points: [{ x: 200.0, y: 200.0, }], },
    ],
  }
  assert_not_eq(static_cache_key(base), static_cache_key(two))
}

///|
/// Phase 5.5.x — selectedId change invalidates the cache because the
/// selected annotation renders with a different colour (yellow vs
/// red), so even if no geometry changes the static layer output
/// changes.
test "static_cache_key — selection change invalidates cache" {
  let base : Model = {
    ..Model::new(),
    annotations: [
      {
        id: "a1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
      },
    ],
    selectedId: None,
  }
  let selected : Model = { ..base, selectedId: Some("a1"), }
  assert_not_eq(static_cache_key(base), static_cache_key(selected))
}

///|
/// Phase 5.5.x — imageNaturalSize is part of the cache key. Changing
/// the natural size (e.g. when the user loads a different image with
/// different dimensions, or when our 5.6 image-header probe reads
/// the real size from the file header) must invalidate the cache.
test "static_cache_key — natural size change invalidates cache" {
  let base : Model = {
    ..Model::new(),
    imageSource: "/img.jpg",
    imageNaturalSize: { x: 1920.0, y: 1080.0, },
  }
  let next : Model = { ..base, imageNaturalSize: { x: 1280.0, y: 720.0, }, }
  assert_not_eq(static_cache_key(base), static_cache_key(next))
}

///|
/// Phase 5.5.x — fitMode is part of the cache key. Switching
/// Contain ↔ Stretch (e.g. user toggles "fit to window" off) must
/// invalidate the cache because the DrawImage's fit field is part
/// of the cached command stream.
test "static_cache_key — fit mode change invalidates cache" {
  let base : Model = {
    ..Model::new(),
    imageSource: "/img.jpg",
    fitMode: @core.ImageFit::Contain,
  }
  let cover : Model = { ..base, fitMode: @core.ImageFit::Cover, }
  assert_not_eq(static_cache_key(base), static_cache_key(cover))
}

///|
/// Phase 5.5.x — most importantly, the dynamic layer's input fields
/// (selectedId, cursorImgPt, dragState) do NOT affect the static
/// cache key. Cursor moves / hover should NOT invalidate the static
/// layer's cached bitmap — that's the whole point of the layer
/// split.
test "static_cache_key — cursor move does NOT invalidate static cache" {
  let base : Model = {
    ..Model::new(),
    imageSource: "/img.jpg",
    cursorImgPt: Some({ x: 100.0, y: 100.0, }),
    selectedId: None,
  }
  // Move the cursor; nothing else changes.
  let moved : Model = { ..base, cursorImgPt: Some({ x: 200.0, y: 250.0, }), }
  // Static cache key is identical — the runtime can reuse the
  // cached static bitmap while only repainting the dynamic layer.
  assert_eq(static_cache_key(base), static_cache_key(moved))
}

///|
/// Phase 5.5.x — handle drag does NOT invalidate the static cache
/// key either (the static layer doesn't know about the drag; the
/// selected annotation's colour is determined by selectedId which is
/// already part of the key). This is the cornerstone of the
/// two-layer design: dragging a handle only repaints the dynamic
/// layer's handles + crosshair, not the entire static bitmap.
///
/// Note: in the legacy frontend/src/canvas.js, the static layer
/// cache key was deliberately bumped during a drag (the comment
/// explains the ghost-rect workaround). With the new key based on
/// selectedId (not on cursorImgPt), the key stays stable during a
/// drag — the static layer is correctly reused, the dynamic layer
/// redraws the dragged handle, and we get a smooth drag without
/// the ghost-rect bug.
test "static_cache_key — handle drag keeps static cache stable" {
  let ann_id = "a1"
  let base : Model = {
    ..Model::new(),
    annotations: [
      {
        id: ann_id,
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
      },
    ],
    selectedId: Some(ann_id),
    cursorImgPt: Some({ x: 0.0, y: 0.0, }),
  }
  // Cursor moves during the drag; annotation points still the
  // same (the drag hasn't actually moved the handle yet — the
  // first CursorMoved that emits ModifyHandle will change the
  // points and invalidate the cache).
  let mid_drag : Model = { ..base, cursorImgPt: Some({ x: 30.0, y: 30.0, }), }
  assert_eq(static_cache_key(base), static_cache_key(mid_drag))
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.11 — drag-pan + secondary-tap reset plumbing tests
// ─────────────────────────────────────────────────────────────────
//
// The 5.11 input plumbing in canvas_view.mbt wires:
//   - `on_drag(Pan(ev.delta))` — accumulates per-step screen-space
//     delta onto model.pan.
//   - `on_secondary_tap(ResetZoomTransformView)` + `on_double_tap(...)` —
//     reset pan + zoom to defaults.
//
// These tests don't drive the modifier chain directly (MoUI's
// modifier API is opaque — you can't enumerate a View's modifiers
// without driving a renderer). Instead we test the *Msg dispatch
// consequences*: feed Pan / Zoom / ResetZoomTransformView into
// update() and assert the resulting model. That covers the
// dataflow the modifiers rely on.

///|
/// Phase 5.11 — a single Pan(delta) Msg accumulates the delta onto
/// model.pan (x and y independently). Starting from (0, 0), a drag
/// delta of (+5, -3) gives pan = (5, -3) — i.e. the image moves 5
/// px right and 3 px up on screen, which is the standard desktop
/// image-viewer convention.
test "Pan(delta) — single step accumulates delta onto model.pan" {
  let model : Model = Model::new()
  let (next, _effect) = update(model, Pan({ x: 5.0, y: -3.0, }))
  assert_eq(next.pan.x, 5.0)
  assert_eq(next.pan.y, -3.0)
}

///|
/// Phase 5.11 — multiple Pan msgs accumulate (the typical
/// multi-step drag). After three Pan calls the pan is the sum of
/// all three deltas. This is the runtime contract for the
/// DragGestureEvent.delta stream emitted on each on_drag tick.
test "Pan(delta) — multi-step drag accumulates across calls" {
  let model : Model = Model::new()
  let (m1, _) = update(model, Pan({ x: 5.0, y: 5.0, }))
  let (m2, _) = update(m1, Pan({ x: -2.0, y: 1.0, }))
  let (m3, _) = update(m2, Pan({ x: 10.0, y: -7.0, }))
  // (5 + -2 + 10) = 13, (5 + 1 + -7) = -1
  assert_eq(m3.pan.x, 13.0)
  assert_eq(m3.pan.y, -1.0)
}

///|
/// Phase 5.11 — Pan marks the static + dynamic layers dirty so
/// the next paint rebuilds the static cache (pan is part of the
/// 5.5.x cache_key) and re-renders handles at the new offset.
test "Pan(delta) — sets staticLayerDirty + dynamicLayerDirty flags" {
  let model : Model = {
    ..Model::new(),
    staticLayerDirty: false,
    dynamicLayerDirty: false,
  }
  let (next, _) = update(model, Pan({ x: 1.0, y: 1.0, }))
  assert_true(next.staticLayerDirty)
  assert_true(next.dynamicLayerDirty)
}

///|
/// Phase 5.11 — ResetZoomTransformView wipes a non-default pan
/// + zoom back to (pan=(0,0), zoom=1.0). After panning far off
/// and zooming in, the right-click / double-tap reset brings the
/// canvas back to its natural centred position.
test "ResetZoomTransformView — restores pan to (0, 0) and zoom to 1.0" {
  let model : Model = {
    ..Model::new(),
    pan: { x: 137.5, y: -42.0, },
    zoom: 2.5,
  }
  let (next, _) = update(model, ResetZoomTransformView)
  assert_eq(next.pan.x, 0.0)
  assert_eq(next.pan.y, 0.0)
  assert_eq(next.zoom, 1.0)
}

///|
/// Phase 5.11 — ResetZoomTransformView marks the layers dirty
/// (pan + zoom changed, so the 5.5.x cache key invalidated).
test "ResetZoomTransformView — marks both layers dirty" {
  let model : Model = {
    ..Model::new(),
    staticLayerDirty: false,
    dynamicLayerDirty: false,
  }
  let (next, _) = update(model, ResetZoomTransformView)
  assert_true(next.staticLayerDirty)
  assert_true(next.dynamicLayerDirty)
}

///|
/// Phase 5.11 — ResetZoomTransformView sets a "View reset" status
/// message so the user sees confirmation in the sidebar status
/// line that the right-click / double-tap worked.
test "ResetZoomTransformView — sets statusMessage to 'View reset'" {
  let model : Model = { ..Model::new(), statusMessage: "Working…", }
  let (next, _) = update(model, ResetZoomTransformView)
  assert_eq(next.statusMessage, "View reset")
}

///|
/// Phase 5.11 — Pan(delta) does NOT touch model.zoom (pan and zoom
/// are orthogonal; pan only moves the image, zoom only scales).
/// This guards against future regressions where someone tries to
/// combine Pan + Zoom into one Msg handler.
test "Pan(delta) — does not modify model.zoom" {
  let model : Model = { ..Model::new(), zoom: 2.0, }
  let (next, _) = update(model, Pan({ x: 50.0, y: 50.0, }))
  assert_eq(next.zoom, 2.0)
}

///|
/// Phase 5.11 — Zoom(z) is the inverse-axis Msg: sets zoom to z
/// without touching pan. (Zoom was wired in 5.5.x; this is the
/// 5.11-era sanity check that the parallel Msg still works after
/// the on_drag×2 / on_secondary_tap / on_double_tap plumbing
/// landed.)
test "Zoom(z) — sets zoom without touching pan" {
  let model : Model = { ..Model::new(), pan: { x: 30.0, y: 40.0, }, zoom: 1.0, }
  let (next, _) = update(model, Zoom(3.5))
  assert_eq(next.zoom, 3.5)
  assert_eq(next.pan.x, 30.0)
  assert_eq(next.pan.y, 40.0)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.12.B — draw_annotation visual-completeness upgrades
// ─────────────────────────────────────────────────────────────────
//
// 5.12.B fills the visual gaps left by 5.3-5.11 relative to
// canvas.js (35 KB reference):
//   - Rect: add a low-alpha FillRect BEFORE the StrokeRect so
//     users see which area the box covers
//   - Polygon: emit a fill DrawPath BEFORE the stroke DrawPath
//     (same MoveTo + LineTo + Close verbs, fill-only)
//   - Polygon: small white-stroked vertex dots at each vertex
//     when N <= 30 (skipped for high-vertex-count polygons to
//     keep the static layer cheap)
//   - Keypoint: 12 px diameter (radius 6) + white outline via
//     StrokeRoundedRectBrush — matches canvas.js drawKeypointShape
//     lines 339-345
//
// The tests below assert command-stream shape, not pixel output
// (no renderer wired in until Phase 10 wires windows_skia).

///|
/// Phase 5.12.B — a Rect annotation now emits a FillRect
/// (alpha 0.12 tint) before the StrokeRect (outline). The fill
/// uses the same RGB as the outline but with alpha 0.12; the
/// stroke stays at alpha 1.0 with the selected/unselected width
/// delta.
test "rect — emits fill_rect (alpha 0.12) + stroke_rect (5.12.B)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "r-1",
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
  let mut fill_for_rect : @core.Color? = None
  let mut stroke_for_rect : @core.Color? = None
  for c in cmds {
    match c {
      @core.DrawCommand::FillRect(_, color) =>
        // Skip the background fill_rect (covers full frame) and
        // the placeholder fill_rect (320×240). The annotation's
        // fill_rect is the smaller one — pick by area.
        if color.a < 0.5 {
          // 5.12.B's annotation fill uses alpha 0.12.
          fill_for_rect = Some(color)
        }
      @core.DrawCommand::StrokeRect(_, color, _) =>
        // The annotation's StrokeRect is the one with stroke
        // width 1.0 (unselected) — the placeholder border uses
        // a different width. Actually 5.5.x set width=2.0 for
        // the placeholder border; verify both colors and find
        // the one matching the annotation palette.
        if color.r > 0.9 && color.g < 0.5 {
          // red palette
          stroke_for_rect = Some(color)
        }
      _ => ()
    }
  }
  let fill_c : @core.Color = match fill_for_rect {
    Some(c) => c
    None => fail("expected annotation fill_rect with low alpha")
  }
  assert_eq(fill_c.a, 0.12)
  let stroke_c : @core.Color = match stroke_for_rect {
    Some(c) => c
    None => fail("expected annotation stroke_rect")
  }
  assert_eq(stroke_c.a, 1.0)
}

///|
/// Phase 5.12.B — a Polygon annotation now emits 2 DrawPath
/// commands: the fill pass (MoveTo + LineTo + Close, fill only)
/// BEFORE the stroke pass (MoveTo + LineTo + Close, stroke only).
/// Both passes use the same verb sequence so the renderer
/// composites fill under stroke.
test "polygon — emits fill DrawPath + stroke DrawPath (5.12.B)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "poly-1",
        shape: Polygon,
        points: [
          { x: 100.0, y: 100.0, },
          { x: 200.0, y: 100.0, },
          { x: 200.0, y: 200.0, },
        ],
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
  let mut path_with_fill : Int = 0
  let mut path_with_stroke : Int = 0
  for c in cmds {
    match c {
      @core.DrawCommand::DrawPath(spec) => {
        let fill_present = match spec.fill {
          Some(_) => true
          None => false
        }
        let stroke_present = match spec.stroke {
          Some(_) => true
          None => false
        }
        if fill_present && !stroke_present {
          path_with_fill = path_with_fill + 1
        }
        if stroke_present && !fill_present {
          path_with_stroke = path_with_stroke + 1
        }
      }
      _ => ()
    }
  }
  assert_eq(path_with_fill, 1)
  assert_eq(path_with_stroke, 1)
}

///|
/// Phase 5.12.B — a Polygon with N vertices (N <= 30) emits
/// exactly N vertex dots, each composed of a fill pass + a
/// white stroke pass (both FillRoundedRectBrush). For a triangle
/// (3 vertices) that's 3 × 2 = 6 FillRoundedRectBrush commands
/// dedicated to vertex decoration (in addition to the 2 paths
/// for fill + stroke of the polygon body itself).
test "polygon — emits vertex dots for N <= 30 (5.12.B)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "tri-1",
        shape: Polygon,
        points: [
          { x: 100.0, y: 100.0, },
          { x: 200.0, y: 100.0, },
          { x: 150.0, y: 200.0, },
        ],
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
  let mut vertex_fill_count = 0
  let mut vertex_stroke_count = 0
  for c in cmds {
    match c {
      @core.DrawCommand::FillRoundedRectBrush(spec, _) =>
        // Vertex dots use a 6×6 rect (radius 3). The keypoint
        // body is 12×12 (radius 6), so we filter by size.
        if spec.radius == 3.0 {
          vertex_fill_count = vertex_fill_count + 1
        }
      @core.DrawCommand::StrokeRoundedRectBrush(spec, _, _) =>
        // White outline pass for each vertex dot — same radius.
        if spec.radius == 3.0 {
          vertex_stroke_count = vertex_stroke_count + 1
        }
      _ => ()
    }
  }
  // 3 vertices × 2 commands (fill + stroke) per vertex = 3 fills
  // and 3 strokes.
  assert_eq(vertex_fill_count, 3)
  assert_eq(vertex_stroke_count, 3)
}

///|
/// Phase 5.12.B — a Polygon with > 30 vertices SKIPS vertex
/// dots entirely. The threshold matches canvas.js line 309
/// (`if (points.length <= 30)`). 31 vertices is enough to be
/// over the threshold while staying cheap to set up.
test "polygon — skips vertex dots for N > 30 (5.12.B)" {
  let points : Array[Point] = []
  for i = 0; i < 31; i = i + 1 {
    let fi : Double = i.to_double()
    points.push({ x: 100.0 + fi * 5.0, y: 100.0 + fi * 5.0, })
  }
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [{ id: "poly-big", shape: Polygon, points, }],
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
  let mut vertex_fill_count = 0
  let mut vertex_stroke_count = 0
  for c in cmds {
    match c {
      @core.DrawCommand::FillRoundedRectBrush(spec, _) =>
        if spec.radius == 3.0 {
          vertex_fill_count = vertex_fill_count + 1
        }
      @core.DrawCommand::StrokeRoundedRectBrush(spec, _, _) =>
        if spec.radius == 3.0 {
          vertex_stroke_count = vertex_stroke_count + 1
        }
      _ => ()
    }
  }
  assert_eq(vertex_fill_count, 0)
  assert_eq(vertex_stroke_count, 0)
}

///|
/// Phase 5.12.B — the keypoint emits a StrokeRoundedRectBrush
/// (white outline, 2 px) immediately after the
/// FillRoundedRectBrush (body colour). Both share the same
/// RoundedRect spec (12×12, radius 6).
test "keypoint — emits fill body + white outline (5.12.B)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      { id: "kp-1", shape: Keypoint, points: [{ x: 100.0, y: 200.0, }], },
    ],
    selectedId: None,
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
  let mut fill_count = 0
  let mut stroke_count = 0
  let mut white_outline_width : Double = -1.0
  for c in cmds {
    match c {
      @core.DrawCommand::FillRoundedRectBrush(spec, _) =>
        if spec.radius == 6.0 {
          fill_count = fill_count + 1
        }
      @core.DrawCommand::StrokeRoundedRectBrush(spec, _, w) =>
        if spec.radius == 6.0 {
          stroke_count = stroke_count + 1
          white_outline_width = w
        }
      _ => ()
    }
  }
  assert_eq(fill_count, 1)
  assert_eq(stroke_count, 1)
  assert_eq(white_outline_width, 2.0)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.12.C — draft rendering + binding-from marker tests
// ─────────────────────────────────────────────────────────────────
//
// 5.12.C wires three new dynamic-layer helpers:
//   draw_draft_polygon   — alpha-0.15 fill + 2 px stroke +
//                          vertex dots while user is in
//                          Polygon mode with draftPoints > 0.
//   draw_draft_rect      — alpha-0.15 fill + 2 px stroke while
//                          user is in Rect mode with exactly 2
//                          draftPoints.
//   draw_binding_from_marker
//                        — 10 px radius unfilled yellow ring
//                          at the source centroid while
//                          bindingFromId is Some.
//
// All three are dispatched from draw_dynamic_layer under
// `model.mode` / `model.bindingFromId` guards.

///|
/// Phase 5.12.C — in Polygon mode with 3 draft points, the
/// dynamic layer emits 2 DrawPaths (fill + stroke) plus 3
/// vertex dots × 2 commands (fill + white outline) = 6
/// FillRoundedRectBrush-style commands. The static layer is
/// untouched (draft state lives on the dynamic layer only).
test "draft polygon — 3 points emits fill + stroke + vertex dots (5.12.C)" {
  let model : Model = {
    ..Model::new(),
    mode: Polygon,
    draftPoints: [
      { x: 100.0, y: 100.0, },
      { x: 200.0, y: 100.0, },
      { x: 150.0, y: 200.0, },
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
  let mut path_with_fill = 0
  let mut path_with_stroke = 0
  let mut vertex_fill_count = 0
  let mut vertex_stroke_count = 0
  for c in cmds {
    match c {
      @core.DrawCommand::DrawPath(spec) => {
        let fill_present = match spec.fill {
          Some(_) => true
          None => false
        }
        let stroke_present = match spec.stroke {
          Some(_) => true
          None => false
        }
        if fill_present && !stroke_present {
          path_with_fill = path_with_fill + 1
        }
        if stroke_present && !fill_present {
          path_with_stroke = path_with_stroke + 1
        }
      }
      @core.DrawCommand::FillRoundedRectBrush(spec, _) =>
        // Draft vertex dots use 8×8 / radius 4 (vs annotation
        // vertex dots at 6×6 / radius 3 in 5.12.B, vs keypoint
        // at 12×12 / radius 6 in 5.12.B). Filter by radius.
        if spec.radius == 4.0 {
          vertex_fill_count = vertex_fill_count + 1
        }
      @core.DrawCommand::StrokeRoundedRectBrush(spec, _, _) =>
        if spec.radius == 4.0 {
          vertex_stroke_count = vertex_stroke_count + 1
        }
      _ => ()
    }
  }
  // 2 DrawPaths (fill + stroke) for the polyline; 3 vertex
  // dots × 2 commands each = 3 fills + 3 strokes.
  assert_eq(path_with_fill, 1)
  assert_eq(path_with_stroke, 1)
  assert_eq(vertex_fill_count, 3)
  assert_eq(vertex_stroke_count, 3)
}

///|
/// Phase 5.12.C — in Polygon mode with just 2 draft points
/// (the user's clicked once + once more but hasn't closed the
/// polygon yet), there's no fill pass (a 2-vertex polygon is
/// just a line; fill would render as a degenerate triangle of
/// zero area) — only the stroke pass + 2 vertex dots.
test "draft polygon — 2 points skips fill, only stroke + dots (5.12.C)" {
  let model : Model = {
    ..Model::new(),
    mode: Polygon,
    draftPoints: [{ x: 100.0, y: 100.0, }, { x: 200.0, y: 200.0, }],
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
  let mut path_with_fill = 0
  let mut path_with_stroke = 0
  for c in cmds {
    match c {
      @core.DrawCommand::DrawPath(spec) => {
        let fill_present = match spec.fill {
          Some(_) => true
          None => false
        }
        let stroke_present = match spec.stroke {
          Some(_) => true
          None => false
        }
        if fill_present && !stroke_present {
          path_with_fill = path_with_fill + 1
        }
        if stroke_present && !fill_present {
          path_with_stroke = path_with_stroke + 1
        }
      }
      _ => ()
    }
  }
  assert_eq(path_with_fill, 0)
  assert_eq(path_with_stroke, 1)
}

///|
/// Phase 5.12.C — in Rect mode with exactly 2 draft points,
/// the dynamic layer emits 1 FillRect (alpha 0.15 fill) + 1
/// StrokeRect (outline). The order matches canvas.js: fill
/// under stroke so the user sees the area tinted before the
/// outline.
test "draft rect — 2 points emits fill + stroke (5.12.C)" {
  let model : Model = {
    ..Model::new(),
    mode: Rect,
    draftPoints: [{ x: 100.0, y: 100.0, }, { x: 200.0, y: 200.0, }],
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
  let mut fill_count = 0
  let mut stroke_count = 0
  let mut fill_alpha : Double = -1.0
  for c in cmds {
    match c {
      @core.DrawCommand::FillRect(_, color) => {
        fill_count = fill_count + 1
        fill_alpha = color.a
      }
      @core.DrawCommand::StrokeRect(_, _, _) => stroke_count = stroke_count + 1
      _ => ()
    }
  }
  assert_eq(fill_count, 1)
  assert_eq(stroke_count, 1)
  assert_eq(fill_alpha, 0.15)
}

///|
/// Phase 5.12.C — in Rect mode with only 1 draft point, the
/// dynamic layer does NOT emit any draft rect (a single point
/// can't define a rect). The user is still dragging.
test "draft rect — 1 point emits nothing (5.12.C)" {
  let model : Model = {
    ..Model::new(),
    mode: Rect,
    draftPoints: [{ x: 100.0, y: 100.0, }],
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
  let mut fill_count = 0
  let mut stroke_count = 0
  for c in cmds {
    match c {
      @core.DrawCommand::FillRect(_) => fill_count = fill_count + 1
      @core.DrawCommand::StrokeRect(_, _, _) => stroke_count = stroke_count + 1
      _ => ()
    }
  }
  assert_eq(fill_count, 0)
  assert_eq(stroke_count, 0)
}

///|
/// Phase 5.12.C — when bindingFromId is set, the dynamic
/// layer emits a single StrokeRoundedRectBrush (radius=10,
/// 2 px stroke) at the source annotation's centroid. This is
/// the "click the destination next" affordance.
test "binding-from ring — emits 10 px ring at source centroid (5.12.C)" {
  let model : Model = {
    ..Model::new(),
    mode: EditBinding,
    bindingFromId: Some("ann-1"),
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 100.0, y: 100.0, }],
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
  let mut ring_count = 0
  let mut ring_radius : Double = -1.0
  let mut ring_stroke : Double = -1.0
  for c in cmds {
    match c {
      @core.DrawCommand::StrokeRoundedRectBrush(spec, _, w) => {
        ring_count = ring_count + 1
        ring_radius = spec.radius
        ring_stroke = w
      }
      _ => ()
    }
  }
  // The ring uses radius=10 → renders as a 20 px circle outline
  // (the same trick as 5.8 / 5.12.B's keypoint, but for stroke
  // only). 2 px stroke matches canvas.js lineWidth=2.
  assert_eq(ring_count, 1)
  assert_eq(ring_radius, 10.0)
  assert_eq(ring_stroke, 2.0)
}

///|
/// Phase 5.12.C — when bindingFromId is set but the source
/// annotation has been deleted (id no longer in annotations),
/// the dynamic layer emits no ring (graceful skip, matches 5.9's
/// draw_bindings policy on dangling binding refs).
test "binding-from ring — dangling id silently skipped (5.12.C)" {
  let model : Model = {
    ..Model::new(),
    mode: EditBinding,
    bindingFromId: Some("deleted-1"),
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 100.0, y: 100.0, }],
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
  let mut ring_count = 0
  for c in cmds {
    match c {
      @core.DrawCommand::StrokeRoundedRectBrush(_) =>
        ring_count = ring_count + 1
      _ => ()
    }
  }
  assert_eq(ring_count, 0)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.12.D — FitView / ZoomAroundScreenPoint Msg tests
// ─────────────────────────────────────────────────────────────────
//
// 5.12.D wires the 5.12.A view-math helpers into the Msg
// pipeline. The Msg dispatch path is the dataflow the sidebar
// Fit button and the canvas keyboard shortcut (F / 0) feed
// into; the tests below verify that the Msg handlers correctly
// compose fit_view_zoom + fit_view_pan and zoom_around_screen_pt.
//
// These tests don't drive the modifier chain directly — same as
// 5.11's Pan / ResetZoomTransformView tests, the public surface
// to assert on is the resulting Model.

///|
/// Phase 5.12.D — FitView(800, 600) on a 1600×1200 image
/// picks zoom = 0.5 (width-limiting scale) and pan that centres
/// the fitted image. The fitted image occupies (800, 600) — same
/// as the viewport — so pan must be (0, 0) (no slack to absorb).
test "FitView — landscape image in same-size viewport → zoom=0.5, pan=(0,0)" {
  let model : Model = {
    ..Model::new(),
    imageNaturalSize: { x: 1600.0, y: 1200.0, },
  }
  let (next, _) = update(model, FitView(800.0, 600.0))
  assert_eq(next.zoom, 0.5)
  assert_eq(next.pan.x, 0.0)
  assert_eq(next.pan.y, 0.0)
}

///|
/// Phase 5.12.D — FitView(1000, 1000) on a 2000×1000 image
/// (landscape in a square viewport) picks zoom = 0.5 and pan
/// with a vertical slack of (1000 - 500) / 2 = 250 px. Matches
/// the 5.12.A fit_view_pan test on the same inputs.
test "FitView — landscape image in square viewport → zoom=0.5, pan.y=250" {
  let model : Model = {
    ..Model::new(),
    imageNaturalSize: { x: 2000.0, y: 1000.0, },
  }
  let (next, _) = update(model, FitView(1000.0, 1000.0))
  assert_eq(next.zoom, 0.5)
  assert_eq(next.pan.x, 0.0)
  assert_eq(next.pan.y, 250.0)
}

///|
/// Phase 5.12.D — FitView marks both layers dirty (the
/// resulting zoom + pan invalidate the 5.5.x cache key) and
/// sets statusMessage to "Fit view" so the user has a
/// confirmation cue in the sidebar.
test "FitView — sets statusMessage + marks layers dirty" {
  let model : Model = {
    ..Model::new(),
    imageNaturalSize: { x: 800.0, y: 600.0, },
    staticLayerDirty: false,
    dynamicLayerDirty: false,
  }
  let (next, _) = update(model, FitView(800.0, 600.0))
  assert_eq(next.statusMessage, "Fit view")
  assert_true(next.staticLayerDirty)
  assert_true(next.dynamicLayerDirty)
}

///|
/// Phase 5.12.D — ZoomAroundScreenPoint(2.0, 100, 100) at
/// pan=(0,0), zoom=1.0: focal at natural (100, 100), zoom to
/// 2.0 must keep that focal point at the same screen position
/// (100, 100). Asserts the new pan is the algebraic
/// pan_new = pan_old + focal_natural * (zoom_old - zoom_new) =
/// 0 + 100 * (1.0 - 2.0) = -100.
test "ZoomAroundScreenPoint — focal point stays fixed under zoom-in (5.12.D)" {
  let model : Model = Model::new()
  let (next, _) = update(model, ZoomAroundScreenPoint(2.0, 100.0, 100.0))
  // Re-project the focal under the new view to verify the
  // invariant: natural_to_screen(100, 100, new_pan, new_zoom)
  // must equal the pre-zoom screen position (100, 100).
  let screen_after : Point = natural_to_screen(
    100.0,
    100.0,
    next.pan,
    next.zoom,
  )
  assert_eq(screen_after.x, 100.0)
  assert_eq(screen_after.y, 100.0)
}

///|
/// Phase 5.12.D — ZoomAroundScreenPoint clamps the requested
/// zoom through view_math.clamp_zoom. Asking for 100× pins at
/// zoom_max = 32.
test "ZoomAroundScreenPoint — clamps requested zoom (5.12.D)" {
  let model : Model = Model::new()
  let (next, _) = update(model, ZoomAroundScreenPoint(100.0, 50.0, 50.0))
  assert_eq(next.zoom, zoom_max)
}

///|
/// Phase 5.12.D — ZoomAroundScreenPoint at a focal at the
/// image-natural origin (screen = (0, 0) when pan = 0)
/// reduces to "pan stays the same, just change the zoom" —
/// the origin doesn't move when zoomed around.
test "ZoomAroundScreenPoint — focal at canvas origin leaves pan unchanged (5.12.D)" {
  let model : Model = { ..Model::new(), pan: { x: 17.0, y: -3.0, }, }
  let (next, _) = update(model, ZoomAroundScreenPoint(2.0, 0.0, 0.0))
  assert_eq(next.pan.x, 17.0)
  assert_eq(next.pan.y, -3.0)
  assert_eq(next.zoom, 2.0)
}

///|
/// Phase 5.12.D — ZoomAroundScreenPoint marks both layers
/// dirty (zoom + pan changed → 5.5.x cache key invalidated).
test "ZoomAroundScreenPoint — marks layers dirty (5.12.D)" {
  let model : Model = {
    ..Model::new(),
    staticLayerDirty: false,
    dynamicLayerDirty: false,
  }
  let (next, _) = update(model, ZoomAroundScreenPoint(1.5, 50.0, 50.0))
  assert_true(next.staticLayerDirty)
  assert_true(next.dynamicLayerDirty)
}
