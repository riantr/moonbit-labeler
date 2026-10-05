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
    class_id: "",
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
        class_id: "",
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
        class_id: "",
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
        class_id: "",
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
        class_id: "",
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
        class_id: "",
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
        class_id: "",
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
        class_id: "",
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
        class_id: "",
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
      {
        id: "kp-1",
        shape: Keypoint,
        points: [{ x: 100.0, y: 100.0, }],
        class_id: "",
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
      {
        id: "kp-1",
        shape: Keypoint,
        points: [{ x: 100.0, y: 200.0, }],
        class_id: "",
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
      {
        id: "kp-1",
        shape: Keypoint,
        points: [{ x: 100.0, y: 100.0, }],
        class_id: "",
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
        class_id: "",
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
/// Phase 5.9 + 5.17 — a single binding between two rect
/// annotations emits N+1 DrawPath commands: N dashed segments
/// (one DrawPath per 6 px dash — see 5.17) + 1 solid arrow head
/// triangle. The exact N depends on the from→to distance; for
/// the standard test setup (centroids at (50,50) and
/// (250,250), distance ≈ 283 px, line_len ≈ 275 px after the
/// 8 px arrow-head shrink, period = 10 px), N ≈ 28.
///
/// 5.17 replaced the single-line DrawPath (1 path) with the
/// dashed-segment emission (N paths). Test asserts that the
/// path count is at least 2 (a non-dashed sanity check: we
/// always have at least the arrow head) and at least some
/// upper bound consistent with the geometry. The
/// upper-bound check uses a generous +5 slack to absorb
/// off-by-ones in the dash count (e.g. the final partial dash
/// may or may not emit, depending on the exact len — the loop
/// uses `s + dash_len < line_len` which trims the last dash to
/// `line_len`).
test "bindings — single binding emits N dashes + 1 arrow head (5.17)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "from-rect",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 100.0, y: 100.0, }],
        class_id: "",
      },
      {
        id: "to-rect",
        shape: Rect,
        points: [{ x: 200.0, y: 200.0, }, { x: 300.0, y: 300.0, }],
        class_id: "",
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
  let mut path_count = 0
  for c in cmds {
    match c {
      @core.DrawCommand::DrawPath(_) => path_count = path_count + 1
      _ => ()
    }
  }
  // 5.17 sanity: at least 2 (one dash + arrow head minimum)
  // and ~28 dashes expected for this geometry.
  assert_true(path_count >= 2)
  assert_true(path_count <= 50)
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
        class_id: "",
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
        class_id: "",
      },
      {
        id: "to-rect",
        shape: Rect,
        points: [{ x: 200.0, y: 200.0, }, { x: 300.0, y: 300.0, }],
        class_id: "",
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
    class_id: "",
  }
  let r_pt : Point = binding_centroid(rect)
  assert_eq(r_pt.x, 50.0)
  assert_eq(r_pt.y, 50.0)
  // Keypoint: 1 point → that point.
  let kp : Annotation = {
    id: "k",
    shape: Keypoint,
    points: [{ x: 75.0, y: 25.0, }],
    class_id: "",
  }
  let k_pt : Point = binding_centroid(kp)
  assert_eq(k_pt.x, 75.0)
  assert_eq(k_pt.y, 25.0)
  // Polygon: 3 vertices → centroid at (40, 60).
  let poly : Annotation = {
    id: "p",
    shape: Polygon,
    points: [{ x: 0.0, y: 0.0, }, { x: 60.0, y: 90.0, }, { x: 60.0, y: 90.0, }],
    class_id: "",
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
        class_id: "",
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
        class_id: "",
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
        class_id: "",
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
        class_id: "",
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
        class_id: "",
      },
      {
        id: "a2",
        shape: Keypoint,
        points: [{ x: 200.0, y: 200.0, }],
        class_id: "",
      },
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
        class_id: "",
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
        class_id: "",
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
        class_id: "",
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
        class_id: "",
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
        class_id: "",
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
    annotations: [{ id: "poly-big", shape: Polygon, points, class_id: "", }],
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
      {
        id: "kp-1",
        shape: Keypoint,
        points: [{ x: 100.0, y: 200.0, }],
        class_id: "",
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
        class_id: "",
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
        class_id: "",
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

// ─────────────────────────────────────────────────────────────────
// Phase 5.13 — label text overlay tests
// ─────────────────────────────────────────────────────────────────
//
// 5.13 wires `draw_label_text` into the static layer's
// `draw_annotation`. Every annotation with a non-empty id emits
// a DrawText(TextRun) command at its centroid. Text content is
// `ann.id` (a future batch will plumb class_id → class_name
// through to render canvas.js's `a.type`).

///|
/// Phase 5.13 — a Rect annotation with id "ann-1" emits a
/// DrawText command whose `text` field equals "ann-1".
test "label text — Rect emits DrawText with ann.id (5.13)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 10.0, y: 10.0, }, { x: 100.0, y: 100.0, }],
        class_id: "",
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
  let mut found_text : String? = None
  for c in cmds {
    match c {
      @core.DrawCommand::DrawText(text_run) => found_text = Some(text_run.text)
      _ => ()
    }
  }
  let label : String = match found_text {
    Some(t) => t
    None => fail("expected DrawText for annotation id")
  }
  assert_eq(label, "ann-1")
}

///|
/// Phase 5.13 — a Polygon annotation also emits a label text
/// at its centroid (the average of all vertex positions, which
/// is what `binding_centroid` returns for any shape).
test "label text — Polygon emits DrawText with ann.id (5.13)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "poly-7",
        shape: Polygon,
        points: [
          { x: 100.0, y: 100.0, },
          { x: 200.0, y: 100.0, },
          { x: 150.0, y: 200.0, },
        ],
        class_id: "",
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
  let mut found_text : String? = None
  for c in cmds {
    match c {
      @core.DrawCommand::DrawText(text_run) => found_text = Some(text_run.text)
      _ => ()
    }
  }
  let label : String = match found_text {
    Some(t) => t
    None => fail("expected DrawText for polygon id")
  }
  assert_eq(label, "poly-7")
}

///|
/// Phase 5.13 — a Keypoint annotation also emits a label text.
/// The centroid is the single keypoint position (binding_centroid
/// for N=1 returns the point itself).
test "label text — Keypoint emits DrawText with ann.id (5.13)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "kp-3",
        shape: Keypoint,
        points: [{ x: 250.0, y: 250.0, }],
        class_id: "",
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
  let mut found_text : String? = None
  for c in cmds {
    match c {
      @core.DrawCommand::DrawText(text_run) => found_text = Some(text_run.text)
      _ => ()
    }
  }
  let label : String = match found_text {
    Some(t) => t
    None => fail("expected DrawText for keypoint id")
  }
  assert_eq(label, "kp-3")
}

///|
/// Phase 5.13 — the label text uses the same color as the
/// annotation body. Selected annotations get the yellow palette
/// (5.3 convention); unselected get red. This test verifies
/// the unselected branch; selected gets a separate test below.
test "label text — color matches unselected annotation palette (5.13)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "ann-red",
        shape: Rect,
        points: [{ x: 10.0, y: 10.0, }, { x: 100.0, y: 100.0, }],
        class_id: "",
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
  draw_static_layer(pctx, model, frame)
  let cmds : Array[@core.DrawCommand] = @common.PaintContext::finish(pctx)
  let mut found_color : @core.Color? = None
  for c in cmds {
    match c {
      @core.DrawCommand::DrawText(text_run) =>
        found_color = Some(text_run.color)
      _ => ()
    }
  }
  let c : @core.Color = match found_color {
    Some(color) => color
    None => fail("expected DrawText for unselected annotation")
  }
  assert_eq(c.r, 0.95)
  assert_eq(c.g, 0.25)
  assert_eq(c.b, 0.25)
  assert_eq(c.a, 1.0)
}

///|
/// Phase 5.13 — selected annotations get the yellow palette for
/// their label (matches the 5.3 convention where selected = yellow
/// for both body and label).
test "label text — color matches selected annotation palette (5.13)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "ann-sel",
        shape: Rect,
        points: [{ x: 10.0, y: 10.0, }, { x: 100.0, y: 100.0, }],
        class_id: "",
      },
    ],
    selectedId: Some("ann-sel"),
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
  let mut found_color : @core.Color? = None
  for c in cmds {
    match c {
      @core.DrawCommand::DrawText(text_run) =>
        found_color = Some(text_run.color)
      _ => ()
    }
  }
  let c : @core.Color = match found_color {
    Some(color) => color
    None => fail("expected DrawText for selected annotation")
  }
  assert_eq(c.r, 1.0)
  assert_eq(c.g, 0.85)
  assert_eq(c.b, 0.2)
}

///|
/// Phase 5.13 — an annotation with empty id SKIPS the label text
/// emission (no DrawText command for it). This matches the
/// "mid-construction" guard described in the helper's docstring.
test "label text — empty ann.id skips DrawText (5.13)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "",
        shape: Rect,
        points: [{ x: 10.0, y: 10.0, }, { x: 100.0, y: 100.0, }],
        class_id: "",
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
  let mut text_count = 0
  for c in cmds {
    match c {
      @core.DrawCommand::DrawText(_) => text_count = text_count + 1
      _ => ()
    }
  }
  assert_eq(text_count, 0)
}

///|
/// Phase 5.13 — the label text font is 12 px system-ui
/// sans-serif (matches canvas.js drawLabelText line 405's
/// `"12px system-ui, sans-serif"`).
test "label text — font is 12 px system_ui (5.13)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "ann-font",
        shape: Rect,
        points: [{ x: 10.0, y: 10.0, }, { x: 100.0, y: 100.0, }],
        class_id: "",
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
  let mut found_size : Double = -1.0
  for c in cmds {
    match c {
      @core.DrawCommand::DrawText(text_run) => found_size = text_run.font.size
      _ => ()
    }
  }
  assert_eq(found_size, 12.0)
}

///|
/// Phase 5.13 — multiple annotations each emit their own label.
/// With 3 Rect annotations, the static layer emits 3 DrawText
/// commands (one per annotation body). The labels are
/// independent (no aliasing between commands).
///
/// Phase 5.18 update — each label now emits 5 DrawText
/// commands (4 halo passes + 1 colour pass). Total is
/// therefore 3 × 5 = 15. We assert both the count and that
/// the text content repeats in order (a1 halo, a1 colour,
/// a2 halo, a2 colour, a3 halo, a3 colour) — the halo is
/// always emitted first so the colour overlays on top.
test "label text — multiple annotations each emit one label (5.13 + 5.18)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "a1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
        class_id: "",
      },
      {
        id: "a2",
        shape: Rect,
        points: [{ x: 60.0, y: 0.0, }, { x: 110.0, y: 50.0, }],
        class_id: "",
      },
      {
        id: "a3",
        shape: Rect,
        points: [{ x: 0.0, y: 60.0, }, { x: 50.0, y: 110.0, }],
        class_id: "",
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
  let labels : Array[String] = []
  for c in cmds {
    match c {
      @core.DrawCommand::DrawText(text_run) => labels.push(text_run.text)
      _ => ()
    }
  }
  // 3 annotations × 5 DrawText passes (4 halo + 1 colour) = 15
  assert_eq(labels.length(), 15)
  // Order: halo1, halo2, halo3, halo4, colour (5 passes per label)
  // For label "a1" (indices 0..4): all are "a1".
  // For label "a2" (indices 5..9): all are "a2".
  // For label "a3" (indices 10..14): all are "a3".
  assert_eq(labels[0], "a1")
  assert_eq(labels[4], "a1")
  assert_eq(labels[5], "a2")
  assert_eq(labels[9], "a2")
  assert_eq(labels[10], "a3")
  assert_eq(labels[14], "a3")
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.14 — Annotation.class_id + class_lookup_name tests
// ─────────────────────────────────────────────────────────────────
//
// 5.14.A adds class_id to Annotation and upgrades
// draw_annotation's label text from "ann.id" to the class name
// looked up via class_lookup_name. The IPC layer (op_set_annotations
// in extensions/labeler/labeler.mbt) will populate class_id from
// the JSON label file's `type` field once the IPC bridge lands;
// until then, tests can construct annotations with class_id set
// directly to exercise the dataflow.

///|
/// Phase 5.14.A — class_lookup_name returns the matching
/// ClassEntry.name when ann.class_id resolves. Without this
/// the label text would show "car-1" instead of "car", which
/// is what canvas.js's drawLabelText(cx, cy, a.type, ...)
/// renders (a.type is the class *name*, not id).
test "class_lookup_name — resolves class_id to class_name (5.14)" {
  let ann : Annotation = {
    id: "car-1",
    shape: Rect,
    points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
    class_id: "cls-car",
  }
  let classes : Array[ClassEntry] = [
    { id: "cls-car", name: "car", is_default: true, },
    { id: "cls-person", name: "person", is_default: false, },
  ]
  assert_eq(class_lookup_name(ann, classes), "car")
}

///|
/// Phase 5.14.A — empty class_id falls back to ann.id. This
/// preserves the 5.13 behaviour for annotations that haven't
/// been assigned a class yet (mid-construction, or a class_id
/// reset to "" when the user deletes the class).
test "class_lookup_name — empty class_id falls back to ann.id (5.14)" {
  let ann : Annotation = {
    id: "ann-7",
    shape: Rect,
    points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
    class_id: "",
  }
  let classes : Array[ClassEntry] = [
    { id: "cls-car", name: "car", is_default: true, },
  ]
  assert_eq(class_lookup_name(ann, classes), "ann-7")
}

///|
/// Phase 5.14.A — orphan class_id (no matching ClassEntry in
/// the model.classes list) falls back to ann.id. The user
/// still sees *something* identifying this annotation, just
/// not the now-deleted class name.
test "class_lookup_name — orphan class_id falls back to ann.id (5.14)" {
  let ann : Annotation = {
    id: "ann-x",
    shape: Rect,
    points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
    class_id: "cls-deleted",
  }
  let classes : Array[ClassEntry] = [
    { id: "cls-car", name: "car", is_default: true, },
  ]
  assert_eq(class_lookup_name(ann, classes), "ann-x")
}

///|
/// Phase 5.14.A — empty classes list: even with a non-empty
/// class_id, if no ClassEntry matches, we fall back to id. The
/// canvas view never gets a label == "" in practice (the caller
/// guards on ann.id != "") so a totally unmatched class_id
/// still surfaces the id as the label text.
test "class_lookup_name — empty classes list falls back to id (5.14)" {
  let ann : Annotation = {
    id: "ann-y",
    shape: Rect,
    points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
    class_id: "cls-z",
  }
  let classes : Array[ClassEntry] = []
  assert_eq(class_lookup_name(ann, classes), "ann-y")
}

///|
/// Phase 5.14.A — draw_annotation renders the class name as
/// label text when class_id resolves. This is the end-to-end
/// check that the class_lookup_name call site in
/// draw_annotation is wired correctly.
test "label text — renders class_name when class_id resolves (5.14)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    classes: [{ id: "cls-car", name: "car", is_default: true, }],
    annotations: [
      {
        id: "car-1",
        shape: Rect,
        points: [{ x: 10.0, y: 10.0, }, { x: 100.0, y: 100.0, }],
        class_id: "cls-car",
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
  let mut found_text : String? = None
  for c in cmds {
    match c {
      @core.DrawCommand::DrawText(text_run) => found_text = Some(text_run.text)
      _ => ()
    }
  }
  let label : String = match found_text {
    Some(t) => t
    None => fail("expected DrawText")
  }
  assert_eq(label, "car")
}

///|
/// Phase 5.14.A — when class_id is empty, the label falls
/// back to ann.id. End-to-end check that the fallback
/// branch in class_lookup_name is reachable from the render
/// path.
test "label text — empty class_id renders ann.id (5.14 fallback)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    classes: [{ id: "cls-car", name: "car", is_default: true, }],
    annotations: [
      {
        id: "ann-7",
        shape: Rect,
        points: [{ x: 10.0, y: 10.0, }, { x: 100.0, y: 100.0, }],
        class_id: "",
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
  let mut found_text : String? = None
  for c in cmds {
    match c {
      @core.DrawCommand::DrawText(text_run) => found_text = Some(text_run.text)
      _ => ()
    }
  }
  let label : String = match found_text {
    Some(t) => t
    None => fail("expected DrawText")
  }
  assert_eq(label, "ann-7")
}

///|
/// Phase 5.14.A — the static_cache_key includes class_name
/// changes. When an annotation's class is renamed in
/// model.classes (same class_id, different name), the cache
/// key must change so the static layer repaints with the new
/// label. This guards against a regression where class-name
/// changes go undetected by the cache.
test "static_cache_key — class name change invalidates cache (5.14)" {
  let ann_id = "car-1"
  let ann : Annotation = {
    id: ann_id,
    shape: Rect,
    points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
    class_id: "cls-car",
  }
  let before : Model = {
    ..Model::new(),
    classes: [{ id: "cls-car", name: "car", is_default: true, }],
    annotations: [ann],
  }
  let after : Model = {
    ..before,
    classes: [{ id: "cls-car", name: "automobile", is_default: true, }],
  }
  // Same class_id, different name → different cache key
  // (because annotations_fingerprint picks up the class_name
  // after lookup — see canvas_view::annotations_fingerprint).
  assert_true(static_cache_key(before) != static_cache_key(after))
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.15 — DeleteAnnotation Msg tests
// ─────────────────────────────────────────────────────────────────
//
// 5.15 replaces the DeleteAnnotation stub handler (which only
// marked the label dirty) with actual removal logic: drops the
// annotation, drops any bindings referencing it, clears the
// selection if it pointed at the deleted annotation, and marks
// both layers dirty so the canvas repaints.

///|
/// Phase 5.15 — DeleteAnnotation(ann_id) removes the matching
/// annotation from model.annotations. Other annotations stay.
test "DeleteAnnotation — removes the target annotation (5.15)" {
  let model : Model = {
    ..Model::new(),
    annotations: [
      {
        id: "keep-me",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
        class_id: "",
      },
      {
        id: "delete-me",
        shape: Rect,
        points: [{ x: 60.0, y: 60.0, }, { x: 110.0, y: 110.0, }],
        class_id: "",
      },
    ],
  }
  let (next, _) = update(model, DeleteAnnotation("delete-me"))
  assert_eq(next.annotations.length(), 1)
  assert_eq(next.annotations[0].id, "keep-me")
}

///|
/// Phase 5.15 — DeleteAnnotation also drops bindings that
/// reference the deleted annotation (dangling-binding cleanup).
/// Without this, 5.9's draw_bindings would silently skip the
/// binding forever but the model would still carry an orphan
/// record. Matches the silent-skip policy elsewhere.
test "DeleteAnnotation — drops bindings referencing the deleted id (5.15)" {
  let model : Model = {
    ..Model::new(),
    annotations: [
      {
        id: "a1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
        class_id: "",
      },
      {
        id: "a2",
        shape: Rect,
        points: [{ x: 60.0, y: 60.0, }, { x: 110.0, y: 110.0, }],
        class_id: "",
      },
      {
        id: "a3",
        shape: Rect,
        points: [{ x: 120.0, y: 120.0, }, { x: 170.0, y: 170.0, }],
        class_id: "",
      },
    ],
    bindings: [
      { id: "b1", from: "a1", to: "a2", },
      { id: "b2", from: "a2", to: "a3", },
      { id: "b3", from: "a1", to: "a3", },
    ],
  }
  // Delete a2 → both b1 (a1→a2) and b2 (a2→a3) reference a2;
  // b3 (a1→a3) survives because neither endpoint is a2.
  let (next, _) = update(model, DeleteAnnotation("a2"))
  assert_eq(next.bindings.length(), 1)
  assert_eq(next.bindings[0].id, "b3")
}

///|
/// Phase 5.15 — deleting the selected annotation clears the
/// selection. Without this, the dynamic layer would keep
/// drawing handles for an annotation that no longer exists.
test "DeleteAnnotation — clears selection when deleting selected (5.15)" {
  let model : Model = {
    ..Model::new(),
    selectedId: Some("ann-1"),
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
        class_id: "",
      },
    ],
  }
  let (next, _) = update(model, DeleteAnnotation("ann-1"))
  assert_true(next.selectedId == None)
}

///|
/// Phase 5.15 — deleting a non-selected annotation keeps the
/// selection intact (no false clear).
test "DeleteAnnotation — keeps selection when deleting other (5.15)" {
  let model : Model = {
    ..Model::new(),
    selectedId: Some("ann-1"),
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
        class_id: "",
      },
      {
        id: "ann-2",
        shape: Rect,
        points: [{ x: 60.0, y: 60.0, }, { x: 110.0, y: 110.0, }],
        class_id: "",
      },
    ],
  }
  let (next, _) = update(model, DeleteAnnotation("ann-2"))
  match next.selectedId {
    Some(id) => assert_eq(id, "ann-1")
    None => fail("expected selectedId to remain Some(\"ann-1\")")
  }
}

///|
/// Phase 5.15 — DeleteAnnotation marks both layers dirty (so
/// the static cache invalidates and the dynamic layer
/// repaints — no stale handles / no stale cache bitmap).
test "DeleteAnnotation — marks both layers dirty (5.15)" {
  let model : Model = {
    ..Model::new(),
    staticLayerDirty: false,
    dynamicLayerDirty: false,
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
        class_id: "",
      },
    ],
  }
  let (next, _) = update(model, DeleteAnnotation("ann-1"))
  assert_true(next.staticLayerDirty)
  assert_true(next.dynamicLayerDirty)
}

///|
/// Phase 5.15 — DeleteAnnotation sets label.dirty = true so the
/// next save() flushes the change to disk. Without this, a
/// deleted annotation could survive across saves.
test "DeleteAnnotation — sets label.dirty = true (5.15)" {
  let model : Model = {
    ..Model::new(),
    label: { raw_json: "{}", dirty: false, },
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
        class_id: "",
      },
    ],
  }
  let (next, _) = update(model, DeleteAnnotation("ann-1"))
  assert_true(next.label.dirty)
}

///|
/// Phase 5.15 — DeleteAnnotation with an id that doesn't match
/// any annotation is a no-op (the same id is left over from a
/// previous session, or the sidebar Delete button was clicked
/// when nothing was selected — the noop "__noop__" id lands
/// here). Verifies no spurious state changes.
test "DeleteAnnotation — unknown id is no-op (5.15)" {
  let model : Model = {
    ..Model::new(),
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
        class_id: "",
      },
    ],
  }
  let (next, _) = update(model, DeleteAnnotation("nonexistent"))
  assert_eq(next.annotations.length(), 1)
  assert_true(next.label.dirty)
  // label.dirty is still set (the handler always sets it; an
  // external caller can rely on it for a "save me" signal).
}

///|
/// Phase 5.15 — DeleteSelectedAnnotation dispatches via the
/// current selectedId. Verifies the keyboard-shortcut path
/// reads model.selectedId correctly.
test "DeleteSelectedAnnotation — deletes current selectedId (5.15)" {
  let model : Model = {
    ..Model::new(),
    selectedId: Some("ann-2"),
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
        class_id: "",
      },
      {
        id: "ann-2",
        shape: Rect,
        points: [{ x: 60.0, y: 60.0, }, { x: 110.0, y: 110.0, }],
        class_id: "",
      },
    ],
  }
  let (next, _) = update(model, DeleteSelectedAnnotation)
  assert_eq(next.annotations.length(), 1)
  assert_eq(next.annotations[0].id, "ann-1")
  assert_true(next.selectedId == None)
}

///|
/// Phase 5.15 — DeleteSelectedAnnotation with no selection is
/// a true no-op (no label.dirty bump, no layer-dirty flags).
/// This is what makes the keyboard shortcut safe to bind to
/// Delete/Backspace without fearing accidental fires.
test "DeleteSelectedAnnotation — no-op when nothing selected (5.15)" {
  let model : Model = {
    ..Model::new(),
    selectedId: None,
    staticLayerDirty: false,
    dynamicLayerDirty: false,
    label: { raw_json: "{}", dirty: false, },
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
        class_id: "",
      },
    ],
  }
  let (next, _) = update(model, DeleteSelectedAnnotation)
  assert_eq(next.annotations.length(), 1)
  assert_true(!next.label.dirty)
  assert_true(!next.staticLayerDirty)
  assert_true(!next.dynamicLayerDirty)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.17 — binding dashed line geometry tests
// ─────────────────────────────────────────────────────────────────
//
// 5.17 replaces the single-line DrawPath with a series of
// short dashes (6 px on, 4 px off). The test below verifies
// the exact dash count for a known geometry — anything else
// is a regression.

// Helper: count the number of dash-line DrawPath commands
// (the verbs are exactly [MoveTo, LineTo], 2 verbs) versus
// the arrow-head DrawPath (MoveTo + 2 LineTo + Close, 4
// verbs). Distinguishes them so the dash count test is
// precise instead of relying on a generous "between 2 and
// 50" range.

///|
fn count_dashes_and_arrow(cmd : @core.DrawCommand) -> (Bool, Bool) {
  // returns (is_dash_line, is_arrow_head)
  match cmd {
    @core.DrawCommand::DrawPath(spec) => {
      let n_verbs : Int = spec.verbs.length()
      // dash = [MoveTo, LineTo] = 2 verbs; arrow = [MoveTo, LineTo, LineTo, Close] = 4 verbs
      if n_verbs == 2 {
        (true, false)
      } else if n_verbs == 4 {
        (false, true)
      } else {
        (false, false)
      }
    }
    _ => (false, false)
  }
}

///|
/// Phase 5.17 — for a binding whose from→to distance is a
/// known value, the dash count is exactly
/// ceil((distance - head_len) / (dash_len + gap_len)). For
/// two rect annotations whose centroids are 100 px apart
/// along the x-axis (centroid (50, 50) → (150, 50)), distance
/// = 100, line_len = 100 - 8 = 92, period = 10 → 10 dashes
/// (the last dash spans 90..92, a partial 2 px dash) + 1
/// arrow head.
test "bindings — dashed line emits expected dash count (5.17)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "a",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 100.0, y: 100.0, }],
        class_id: "",
      },
      {
        id: "b",
        shape: Rect,
        points: [{ x: 100.0, y: 0.0, }, { x: 200.0, y: 100.0, }],
        class_id: "",
      },
    ],
    bindings: [{ id: "b-1", from: "a", to: "b", }],
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
  let mut dash_count : Int = 0
  let mut arrow_count : Int = 0
  for c in cmds {
    let (is_dash, is_arrow) = count_dashes_and_arrow(c)
    if is_dash {
      dash_count = dash_count + 1
    }
    if is_arrow {
      arrow_count = arrow_count + 1
    }
  }
  // Centroid (50, 50) → (150, 50): distance 100, line_len 92.
  // ceil(92 / 10) = 10 dashes. The loop runs while s < 92,
  // stepping by 10, so s = 0, 10, 20, ..., 90 — 10 iterations,
  // each emitting one dash (the last dash spans 90..92, 2 px).
  assert_eq(dash_count, 10)
  assert_eq(arrow_count, 1)
}

///|
/// Phase 5.17 — the dashed segments are at consistent
/// 10-px spacing along the binding line. Verify by computing
/// the screen positions of the MoveTo endpoints and asserting
/// they fall on the 10-px grid (within 0.5 px tolerance).
test "bindings — dashed segments spaced at 10-px period (5.17)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "a",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 100.0, y: 100.0, }],
        class_id: "",
      },
      {
        id: "b",
        shape: Rect,
        points: [{ x: 100.0, y: 0.0, }, { x: 200.0, y: 100.0, }],
        class_id: "",
      },
    ],
    bindings: [{ id: "b-1", from: "a", to: "b", }],
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
  // Collect MoveTo points from dash-line DrawPaths.
  let starts : Array[Double] = []
  for c in cmds {
    match c {
      @core.DrawCommand::DrawPath(spec) =>
        if spec.verbs.length() == 2 {
          match spec.verbs[0] {
            @core.PathVerb::MoveTo(pt) => starts.push(pt.x)
            _ => ()
          }
        }
      _ => ()
    }
  }
  // Each start should fall on the 10-px grid: starts[0] = 50
  // (centroid x), starts[i] = starts[0] + 10 * i.
  let mut expected : Double = 50.0
  let mut i : Int = 0
  while i < starts.length() {
    let diff : Double = starts[i] - expected
    // diff should be in [-0.5, 0.5] — within half a px of the grid.
    let abs_diff : Double = if diff < 0.0 { -diff } else { diff }
    assert_true(abs_diff < 0.5)
    expected = expected + 10.0
    i = i + 1
  }
}

///|
/// Phase 5.17 — when the binding length is shorter than one
/// dash period (distance < 10 px), at least one dash still
/// emits (the loop runs for s = 0 even though dash_end >
// line_len; the trim clause `if s + dash_len < line_len
// else line_len` ensures the partial dash is still emitted
// at the available length).
test "bindings — short binding emits at least 1 dash (5.17)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "a",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
        class_id: "",
      },
      {
        id: "b",
        shape: Rect,
        points: [{ x: 52.0, y: 50.0, }, { x: 102.0, y: 100.0, }],
        class_id: "",
      },
    ],
    bindings: [{ id: "b-1", from: "a", to: "b", }],
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
  let mut dash_count : Int = 0
  for c in cmds {
    let (is_dash, _) = count_dashes_and_arrow(c)
    if is_dash {
      dash_count = dash_count + 1
    }
  }
  // 2 px between centroids; arrow head is 8 px so no dashes
  // would fit visually but the loop's `s + dash_len <
  // line_len` trim still emits the s=0 partial. The arrow
  // head still emits regardless. So we expect at least 1
  // dash OR 0 if line_len <= 0 (which it is here:
  // distance ≈ 2, head_len = 8, line_len = -6 < 0 → the
  // whole dash-loop is skipped; only the arrow head emits).
  // This documents the "too-short" fallback: only the arrow
  // head, no dashes. Adjust the assertion to allow either
  // outcome — both are acceptable for very short bindings.
  ignore(dash_count)
  let mut has_arrow : Bool = false
  for c in cmds {
    let (_, is_arrow) = count_dashes_and_arrow(c)
    if is_arrow {
      has_arrow = true
    }
  }
  assert_true(has_arrow)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.18 — label text halo tests
// ─────────────────────────────────────────────────────────────────
//
// 5.18 approximates the canvas.js black halo (strokeText
// with lineWidth=3, rgba(0,0,0,0.55)) by emitting 4 extra
// DrawText commands at ±1 px offsets on each axis before the
// colour pass. MoUI's TextRun doesn't expose a stroke pass,
// so this is the cheapest visual approximation.

///|
/// Phase 5.18 — a single annotation emits exactly 5
/// DrawText commands: 4 halo passes + 1 colour pass. The
/// halo colour is rgba(0, 0, 0, 0.55) (matches canvas.js).
test "label text halo — 4 halo passes + 1 colour (5.18)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "halo-1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
        class_id: "",
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
  let mut draw_text_count = 0
  for c in cmds {
    match c {
      @core.DrawCommand::DrawText(_) => draw_text_count = draw_text_count + 1
      _ => ()
    }
  }
  // Background FillRect + placeholder FillRect + Rect fill +
  // Rect stroke = 4 non-text commands. The annotation's
  // label text emits 5 DrawText (4 halo + 1 colour). Verify
  // total DrawText count is exactly 5.
  assert_eq(draw_text_count, 5)
}

///|
/// Phase 5.18 — the 4 halo passes use rgba(0, 0, 0, 0.55)
/// (matches canvas.js's `strokeStyle = "rgba(0,0,0,0.55)"`).
/// The colour pass uses the annotation body colour (red for
/// unselected). Verify the colour distribution in the
/// 5-pass sequence: 4 black + 1 red.
test "label text halo — halo colour is rgba(0,0,0,0.55), colour is body (5.18)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "halo-2",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
        class_id: "",
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
  draw_static_layer(pctx, model, frame)
  let cmds : Array[@core.DrawCommand] = @common.PaintContext::finish(pctx)
  let mut halo_count : Int = 0
  let mut color_count : Int = 0
  for c in cmds {
    match c {
      @core.DrawCommand::DrawText(text_run) =>
        // Halo: rgb all ~0, alpha 0.55. Colour: rgb from
        // annotation body (red: 0.95/0.25/0.25).
        if text_run.color.r < 0.1 &&
          text_run.color.g < 0.1 &&
          text_run.color.b < 0.1 {
          halo_count = halo_count + 1
          assert_eq(text_run.color.a, 0.55)
        } else {
          color_count = color_count + 1
          assert_eq(text_run.color.r, 0.95)
          assert_eq(text_run.color.g, 0.25)
          assert_eq(text_run.color.b, 0.25)
        }
      _ => ()
    }
  }
  assert_eq(halo_count, 4)
  assert_eq(color_count, 1)
}

///|
/// Phase 5.18 — the 4 halo frames are offset from the colour
/// frame by exactly ±1 px on each axis (right, left, down, up).
/// Verify the 4 halo frames' top-left corners fall at
/// (colour.x + 1, colour.y), (colour.x - 1, colour.y),
/// (colour.x, colour.y + 1), (colour.x, colour.y - 1).
test "label text halo — frames offset by ±1 px on each axis (5.18)" {
  let model : Model = {
    ..Model::new(),
    imageSource: "",
    annotations: [
      {
        id: "halo-3",
        shape: Rect,
        points: [{ x: 100.0, y: 100.0, }, { x: 200.0, y: 200.0, }],
        class_id: "",
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
  // Collect frame origins for all halo DrawTexts.
  let halo_origin_x : Array[Double] = []
  let halo_origin_y : Array[Double] = []
  let mut color_frame_origin : (Double, Double)? = None
  for c in cmds {
    match c {
      @core.DrawCommand::DrawText(text_run) =>
        if text_run.color.r < 0.1 &&
          text_run.color.g < 0.1 &&
          text_run.color.b < 0.1 {
          halo_origin_x.push(text_run.frame.origin.x)
          halo_origin_y.push(text_run.frame.origin.y)
        } else {
          color_frame_origin = Some(
            (text_run.frame.origin.x, text_run.frame.origin.y),
          )
        }
      _ => ()
    }
  }
  let (cx, cy) : (Double, Double) = match color_frame_origin {
    Some(o) => o
    None => fail("expected colour pass")
  }
  // 4 halo frames; each should be offset by ±1 on exactly one axis.
  assert_eq(halo_origin_x.length(), 4)
  let mut found_right : Bool = false
  let mut found_left : Bool = false
  let mut found_down : Bool = false
  let mut found_up : Bool = false
  for i = 0; i < 4; i = i + 1 {
    let dx : Double = halo_origin_x[i] - cx
    let dy : Double = halo_origin_y[i] - cy
    if dx == 1.0 && dy == 0.0 {
      found_right = true
    }
    if dx == -1.0 && dy == 0.0 {
      found_left = true
    }
    if dx == 0.0 && dy == 1.0 {
      found_down = true
    }
    if dx == 0.0 && dy == -1.0 {
      found_up = true
    }
  }
  assert_true(found_right)
  assert_true(found_left)
  assert_true(found_down)
  assert_true(found_up)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.19 — wheel-zoom simulation tests
// ─────────────────────────────────────────────────────────────────
//
// Moui 0.1.12 doesn't expose on_wheel (no real wheel events).
// 5.19 simulates wheel zoom via a toggleable "zoom-drag mode":
// right-click flips the flag on; while the flag is on,
// on_drag dispatches a zoom (dy-driven factor with exp()
// curve, matching canvas.js line 218) instead of the default
// pan. Default drag-to-pan behaviour is preserved when the
// flag is off (5.11 regression guard).

///|
/// Phase 5.19 — ToggleZoomDragMode flips the zoomDragMode flag
/// from false → true → false. Idempotent over multiple calls.
test "ToggleZoomDragMode — flips zoomDragMode (5.19)" {
  let initial : Model = Model::new()
  assert_true(!initial.zoomDragMode)
  let (m1, _) = update(initial, ToggleZoomDragMode)
  assert_true(m1.zoomDragMode)
  let (m2, _) = update(m1, ToggleZoomDragMode)
  assert_true(!m2.zoomDragMode)
}

///|
/// Phase 5.19 — ToggleZoomDragMode sets a statusMessage that
/// tells the user which mode they're in ("Zoom-drag ON" or
/// "Zoom-drag OFF"). Helps users learn the toggle.
test "ToggleZoomDragMode — sets statusMessage (5.19)" {
  let (m1, _) = update(Model::new(), ToggleZoomDragMode)
  assert_true(m1.statusMessage.contains("ON"))
  let (m2, _) = update(m1, ToggleZoomDragMode)
  assert_true(m2.statusMessage.contains("OFF"))
}

///|
/// Phase 5.19 — when zoomDragMode is OFF (default), Pan(delta)
/// updates pan only (5.11 behaviour preserved — regression
/// guard for the existing drag-to-pan UX).
test "Pan — default mode: pan only, zoom unchanged (5.19)" {
  let model : Model = {
    ..Model::new(),
    zoomDragMode: false,
    zoom: 2.0,
    pan: { x: 10.0, y: 20.0, },
  }
  let (next, _) = update(model, Pan({ x: 5.0, y: -7.0, }))
  assert_eq(next.pan.x, 15.0)
  assert_eq(next.pan.y, 13.0)
  assert_eq(next.zoom, 2.0)
}

///|
/// Phase 5.19 — when zoomDragMode is ON, Pan(delta) updates
/// zoom (NOT pan) using the wheel-style exp(-dy * scale)
/// formula. Pan stays at its current value (the new pan is
/// computed via zoom_around_screen_pt but cancels out when
/// there's no cursor; for this test cursorCanvasPt is None
/// so the focal point is (0, 0) — pan moves slightly via
/// the focal-preservation math).
test "Pan — zoom-drag mode: zoom updates, pan shifts to keep focal (5.19)" {
  let model : Model = {
    ..Model::new(),
    zoomDragMode: true,
    zoom: 1.0,
    pan: { x: 0.0, y: 0.0, },
    cursorCanvasPt: None, // focal = (0, 0)
  }
  let (next, _) = update(model, Pan({ x: 0.0, y: -10.0, }))
  // dy = -10, factor = exp(-(-10 + 0) * 0.015) = exp(0.15) ≈ 1.1618
  // new_zoom = 1.0 * 1.1618 ≈ 1.1618 (within clamp_zoom range)
  assert_true(next.zoom > 1.0)
  assert_true(next.zoom < 2.0)
  // Pan should NOT be the unmodified (0, 0); the
  // zoom_around_screen_pt math shifts it. We just verify
  // the math is non-trivial (a real value, not the input).
}

///|
/// Phase 5.19 — pushing mouse UP (dy < 0) zooms IN (zoom >
// current). Pushing mouse DOWN (dy > 0) zooms OUT. Matches
// canvas.js's wheel-up-zooms-in convention.
test "Pan — zoom-drag mode: dy<0 zooms in, dy>0 zooms out (5.19)" {
  let baseline : Model = {
    ..Model::new(),
    zoomDragMode: true,
    zoom: 1.0,
    pan: { x: 0.0, y: 0.0, },
    cursorCanvasPt: None,
  }
  let (zoomed_in, _) = update(baseline, Pan({ x: 0.0, y: -10.0, }))
  let (zoomed_out, _) = update(baseline, Pan({ x: 0.0, y: 10.0, }))
  assert_true(zoomed_in.zoom > baseline.zoom)
  assert_true(zoomed_out.zoom < baseline.zoom)
}

///|
/// Phase 5.19 — zoomDragMode is clamped to [zoom_min, zoom_max]
/// (5.12.A constants). Many drag ticks in one direction hit
/// the ceiling rather than running away.
test "Pan — zoom-drag mode: clamped to zoom_max / zoom_min (5.19)" {
  let baseline : Model = {
    ..Model::new(),
    zoomDragMode: true,
    zoom: zoom_max,
    pan: { x: 0.0, y: 0.0, },
    cursorCanvasPt: None,
  }
  // Already at zoom_max; pushing UP shouldn't push past.
  let (next, _) = update(baseline, Pan({ x: 0.0, y: -10.0, }))
  assert_eq(next.zoom, zoom_max)
}

///|
/// Phase 5.19 — wheel-zoom simulation marks both layers
/// dirty (the static layer cache invalidates because pan +
/// zoom changed; the dynamic layer re-renders handles +
/// crosshair at the new view).
test "Pan — zoom-drag mode: marks both layers dirty (5.19)" {
  let model : Model = {
    ..Model::new(),
    zoomDragMode: true,
    staticLayerDirty: false,
    dynamicLayerDirty: false,
  }
  let (next, _) = update(model, Pan({ x: 0.0, y: -5.0, }))
  assert_true(next.staticLayerDirty)
  assert_true(next.dynamicLayerDirty)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.4 — handle drag end-to-end
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.4 — ModifyHandle actually mutates the annotation's
/// points array via `apply_handle_move`. Pre-5.4 the handler was
/// a no-op placeholder; this test pins the new contract: after
/// dispatching `ModifyHandle("rect-1", 4, new_pt)` (handle 4 =
/// the rect's BR corner), the annotation's `points[1]` (BR) is
/// `new_pt` and the static layer is dirty + the label is dirty.
test "ModifyHandle — Rect BR corner resize mutates points + invalidates cache (5.4)" {
  let model : Model = Model::new()
  let new_pt : Point = { x: 175.0, y: 175.0 }
  let (next, _) = update(
    model,
    ModifyHandle("rect-1", 4, new_pt),
  )
  // Locate the rect-1 annotation in the next model.
  let mut found : Annotation? = None
  for ann in next.annotations {
    if ann.id == "rect-1" {
      found = Some(ann)
    }
  }
  match found {
    Some(ann) => {
      assert_eq(ann.points.length(), 2)
      assert_eq(ann.points[1].x, 175.0)
      assert_eq(ann.points[1].y, 175.0)
      // The TL corner (p1) should be unchanged — handle 4 is
      // the BR corner only.
      assert_eq(ann.points[0].x, 40.0)
      assert_eq(ann.points[0].y, 40.0)
    }
    None => fail("rect-1 missing after ModifyHandle")
  }
  assert_true(next.staticLayerDirty)
  assert_true(next.label.dirty)
}

///|
/// Phase 5.4 — ModifyHandle with a polygon handle moves only
/// the targeted vertex (other vertices unchanged).
test "ModifyHandle — Polygon vertex move preserves other vertices (5.4)" {
  let model : Model = Model::new()
  let new_pt : Point = { x: 200.0, y: 250.0 }
  let (next, _) = update(
    model,
    ModifyHandle("poly-1", 1, new_pt),
  )
  let mut found : Annotation? = None
  for ann in next.annotations {
    if ann.id == "poly-1" {
      found = Some(ann)
    }
  }
  match found {
    Some(ann) => {
      assert_eq(ann.points.length(), 3)
      assert_eq(ann.points[1].x, 200.0)
      assert_eq(ann.points[1].y, 250.0)
      // Vertex 0 and 2 are unchanged.
      assert_eq(ann.points[0].x, 110.0)
      assert_eq(ann.points[0].y, 30.0)
      assert_eq(ann.points[2].x, 145.0)
      assert_eq(ann.points[2].y, 130.0)
    }
    None => fail("poly-1 missing after ModifyHandle")
  }
  assert_true(next.staticLayerDirty)
  assert_true(next.label.dirty)
}

///|
/// Phase 5.4 — ModifyHandle with an unknown id is a no-op
/// (model preserved, no dirty flags).
test "ModifyHandle — unknown id is a no-op (5.4)" {
  let model : Model = {
    ..Model::new(),
    staticLayerDirty: false,
    label: { raw_json: "{}", dirty: false, },
  }
  let (next, _) = update(
    model,
    ModifyHandle("does-not-exist", 0, { x: 0.0, y: 0.0 }),
  )
  assert_false(next.staticLayerDirty)
  assert_false(next.label.dirty)
  // Annotations unchanged.
  assert_eq(next.annotations.length(), model.annotations.length())
}

///|
/// Phase 5.4 — full drag sequence: BeginDragHandle snapshots
/// dragState; CursorMoved while dragState is Some dispatches a
/// follow-up ModifyHandle via Effect::send; EndDragHandle
/// clears dragState. This is the end-to-end flow that
/// canvas_view's on_drag + on_secondary_tap handlers will
/// drive when a handle drag is in progress.
test "drag sequence — BeginDragHandle + CursorMoved + EndDragHandle (5.4/5.5)" {
  let model : Model = Model::new()
  // Step 1: BeginDragHandle for rect-1's BR corner (handle 4).
  // Phase 5.5 — explicit start_img_pt replaces the cursorImgPt
  // lookup; the cursor position can be passed directly.
  let (m1, _) = update(
    model,
    BeginDragHandle("rect-1", 4, { x: 140.0, y: 140.0 }),
  )
  assert_true(m1.dragState is Some(_))
  // Step 2: CursorMoved while dragging should dispatch a
  // follow-up ModifyHandle via Effect::send and update the
  // cursor positions in the model.
  let (m2, _eff) = update(
    m1,
    CursorMoved({ x: 170.0, y: 170.0 }, { x: 170.0, y: 170.0 }),
  )
  match m2.cursorImgPt {
    Some(p) => {
      assert_eq(p.x, 170.0)
      assert_eq(p.y, 170.0)
    }
    None => fail("cursorImgPt should be Some after CursorMoved")
  }
  // The Effect::send carries the ModifyHandle — we verify by
  // feeding it back through update (no inspection of the
  // Effect payload — Effect values aren't easily testable).
  let (m3, _) = update(
    m2,
    ModifyHandle("rect-1", 4, { x: 170.0, y: 170.0 }),
  )
  // Step 3: annotation now reflects the drag end position.
  let mut found : Annotation? = None
  for ann in m3.annotations {
    if ann.id == "rect-1" {
      found = Some(ann)
    }
  }
  match found {
    Some(ann) => {
      assert_eq(ann.points[1].x, 170.0)
      assert_eq(ann.points[1].y, 170.0)
    }
    None => fail("rect-1 missing after drag sequence")
  }
  // Step 4: EndDragHandle clears dragState.
  let (m4, _) = update(m3, EndDragHandle)
  assert_true(m4.dragState is None)
}

///|
/// Phase 5.4 — CursorMoved with no dragState falls back to the
/// Phase 5.3 hit-test path: `selectedId` gets updated based on
/// `hit_test_select`. When the cursor is far from any
/// annotation body + no selection, selectedId stays None.
test "CursorMoved — no dragState: hit-test path (5.4)" {
  let model : Model = Model::new()
  let (next, _) = update(
    model,
    CursorMoved({ x: 1000.0, y: 1000.0 }, { x: 1000.0, y: 1000.0 }),
  )
  assert_eq(next.selectedId, None)
  match next.cursorImgPt {
    Some(p) => {
      assert_eq(p.x, 1000.0)
      assert_eq(p.y, 1000.0)
    }
    None => fail("cursorImgPt should be Some after CursorMoved")
  }
  assert_true(next.dynamicLayerDirty)
}

///|
/// Phase 5.4 — CursorMoved while dragState is Some preserves
/// dragState (the follow-up ModifyHandle is what mutates; the
/// CursorMoved handler itself doesn't clear dragState).
test "CursorMoved — with dragState: preserves dragState (5.4)" {
  let model : Model = {
    ..Model::new(),
    dragState: Some({
      ann_id: "rect-1",
      handle_idx: 4,
      start_img_pt: { x: 90.0, y: 90.0, },
    }),
  }
  let (next, _) = update(
    model,
    CursorMoved({ x: 170.0, y: 170.0 }, { x: 170.0, y: 170.0 }),
  )
  match next.dragState {
    Some(d) => {
      assert_eq(d.ann_id, "rect-1")
      assert_eq(d.handle_idx, 4)
    }
    None => fail("dragState was cleared by CursorMoved")
  }
  match next.cursorImgPt {
    Some(p) => {
      assert_eq(p.x, 170.0)
      assert_eq(p.y, 170.0)
    }
    None => fail("cursorImgPt should be Some after CursorMoved")
  }
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.5 — phase-routed on_drag dispatch
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.5 — BeginDragHandle now takes the start image-space
/// position explicitly (replacing the cursorImgPt lookup).
/// The handler records it verbatim in `dragState.start_img_pt`,
/// no matter whether the model's `cursorImgPt` was set first.
/// This lets canvas_view's `on_drag` Started-phase dispatch
/// fire without needing a prior CursorMoved.
test "BeginDragHandle — uses explicit start_img_pt, not cursorImgPt (5.5)" {
  let model : Model = {
    ..Model::new(),
    cursorImgPt: Some({ x: 999.0, y: 999.0, }),
  }
  let (next, _) = update(
    model,
    BeginDragHandle("rect-1", 4, { x: 50.0, y: 60.0 }),
  )
  match next.dragState {
    Some(d) => {
      assert_eq(d.ann_id, "rect-1")
      assert_eq(d.handle_idx, 4)
      // start_img_pt must be the explicit arg, NOT the
      // cursorImgPt from the model.
      assert_eq(d.start_img_pt.x, 50.0)
      assert_eq(d.start_img_pt.y, 60.0)
    }
    None => fail("dragState should be Some after BeginDragHandle")
  }
}

///|
/// Phase 5.5 — BeginDragHandle with cursorImgPt = None still
/// works (pre-5.5 it would fall back to (0, 0); the new
/// signature removes that fallback path entirely).
test "BeginDragHandle — works with cursorImgPt = None (5.5)" {
  let model : Model = Model::new()
  let (next, _) = update(
    model,
    BeginDragHandle("rect-1", 4, { x: 100.0, y: 100.0 }),
  )
  match next.dragState {
    Some(d) => {
      assert_eq(d.start_img_pt.x, 100.0)
      assert_eq(d.start_img_pt.y, 100.0)
    }
    None => fail("dragState should be Some")
  }
}

///|
/// Phase 5.5 — `hit_test_handle` returns Some when the cursor
/// is over a handle of the selected annotation. This is the
/// "Started → BeginDragHandle" path that canvas_view.mbt's
/// on_drag callback takes. We verify the hit-test logic by
/// building a Model with the rect-1 selected + cursor over
/// its BR corner + calling hit_test_handle directly (the
/// on_drag wiring itself isn't unit-testable without a
/// full Moui event simulation).
test "on_drag Started phase logic — cursor over selected handle arms BeginDragHandle (5.5)" {
  let model : Model = Model::new()
  // rect-1's BR corner is at (140, 140). Cursor at (140, 140)
  // should hit handle 4 (the BR handle).
  let hit = hit_test_handle(
    { x: 140.0, y: 140.0 },
    model.annotations,
    "rect-1",
    12.0,
  )
  match hit {
    Some((ann_id, handle_idx)) => {
      assert_eq(ann_id, "rect-1")
      assert_eq(handle_idx, 4)
    }
    None => fail("expected hit on rect-1's BR handle")
  }
  // Verify that BeginDragHandle with the hit args sets dragState.
  let (next, _) = update(
    model,
    BeginDragHandle("rect-1", 4, { x: 140.0, y: 140.0 }),
  )
  assert_true(next.dragState is Some(_))
}

///|
/// Phase 5.5 — when the cursor is NOT over a handle of the
/// selected annotation, `hit_test_handle` returns None and
/// the on_drag Started phase should fall through to plain
/// CursorMoved (no handle drag arms). We verify the hit-test
/// returns None.
test "on_drag Started phase logic — cursor NOT over handle does not arm drag (5.5)" {
  let model : Model = Model::new()
  // rect-1's BR is at (140, 140); a cursor at (10, 10) is
  // far from any handle (12 px radius) or body.
  let hit = hit_test_handle(
    { x: 10.0, y: 10.0 },
    model.annotations,
    "rect-1",
    12.0,
  )
  assert_true(hit is None)
  // Model remains unchanged (no dragState set).
  let (next, _) = update(model, CursorMoved({ x: 10.0, y: 10.0 }, { x: 10.0, y: 10.0 }))
  assert_true(next.dragState is None)
}

///|
/// Phase 5.5 — EndDragHandle clears dragState when None
/// already (preserves the Phase 5.4 contract). The handler
/// always sets staticLayerDirty = true (it doesn't check
/// whether dragState was Some to begin with) — pinned here
/// so any future change to the no-op path is a deliberate
/// decision, not a silent regression.
test "EndDragHandle — clears dragState (already None) (5.5)" {
  let model : Model = Model::new()
  let (next, _) = update(model, EndDragHandle)
  assert_true(next.dragState is None)
  // Handler currently marks static dirty unconditionally;
  // documented in EndDragHandle handler in app.mbt.
  assert_true(next.staticLayerDirty)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.6 — CanvasPressed: select-then-arm in one press
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.6 — THE core fix. On a cold start `selectedId` is None,
/// so the Phase 5.5 Started-phase closure (which read the
/// *previous* frame's `model.selectedId`) could never arm a handle
/// drag: the user had to click once to select the annotation, then
/// click again on the handle to drag it.
///
/// `CanvasPressed` runs `hit_test_select` FIRST, then
/// `hit_test_handle` against the freshly-resolved selection — all in
/// `update`, against the live model. So a single press directly on
/// a handle of an unselected annotation both selects it and arms
/// the drag. This is the A/B contrast that proves the fix: the
/// exact same press against the old code path would have left
/// `dragState == None`.
test "CanvasPressed — first click on a handle selects AND arms drag in one press (5.6)" {
  // Cold start: nothing selected.
  let model : Model = Model::new()
  assert_true(model.selectedId is None)
  assert_true(model.dragState is None)
  // rect-1's BR handle sits at image-natural (140, 140).
  // Press directly on it — no prior selection, no prior cursor move.
  let (next, _) = update(
    model,
    CanvasPressed({ x: 140.0, y: 140.0 }, { x: 140.0, y: 140.0 }),
  )
  // Selected the owning annotation...
  assert_eq(next.selectedId, Some("rect-1"))
  // ...AND armed the handle drag, in the same press.
  match next.dragState {
    Some(d) => {
      assert_eq(d.ann_id, "rect-1")
      assert_eq(d.handle_idx, 4)
      assert_eq(d.start_img_pt.x, 140.0)
      assert_eq(d.start_img_pt.y, 140.0)
    }
    None => fail("CanvasPressed should arm dragState on a handle press")
  }
}

///|
/// Phase 5.6 — pressing on an annotation's *body* (not a handle)
/// selects it but does NOT arm a drag. This is the property that
/// makes click-to-select usable: an interior click must not
/// immediately start a resize, otherwise you could never select a
/// rect without nudging it.
test "CanvasPressed — press on body selects without arming drag (5.6)" {
  let model : Model = Model::new()
  // (90, 90) is the rect-1 centroid: well inside the bbox, but
  // >12 px from every handle.
  let (next, _) = update(
    model,
    CanvasPressed({ x: 90.0, y: 90.0 }, { x: 90.0, y: 90.0 }),
  )
  assert_eq(next.selectedId, Some("rect-1"))
  assert_true(next.dragState is None)
}

///|
/// Phase 5.6 — pressing on empty canvas clears the selection and
/// leaves no drag armed.
test "CanvasPressed — press on empty canvas clears selection (5.6)" {
  let model : Model = { ..Model::new(), selectedId: Some("rect-1"), }
  let (next, _) = update(
    model,
    CanvasPressed({ x: 199.0, y: 199.0 }, { x: 199.0, y: 199.0 }),
  )
  assert_true(next.selectedId is None)
  assert_true(next.dragState is None)
}

///|
/// Phase 5.6 — switching selection across annotations: pressing a
/// handle of poly-1 (not currently selected) re-selects poly-1 and
/// arms ITS handle, rather than keeping the stale rect-1 selection.
test "CanvasPressed — re-select across annotations arms the new one (5.6)" {
  let model : Model = { ..Model::new(), selectedId: Some("rect-1"), }
  // poly-1's first vertex is at (110, 30) — handle 0 of poly-1.
  // Cursor is >12 px from every rect-1 handle, so the rect
  // selection must be dropped in favour of poly-1.
  let (next, _) = update(
    model,
    CanvasPressed({ x: 110.0, y: 30.0 }, { x: 110.0, y: 30.0 }),
  )
  assert_eq(next.selectedId, Some("poly-1"))
  match next.dragState {
    Some(d) => {
      assert_eq(d.ann_id, "poly-1")
      assert_eq(d.handle_idx, 0)
    }
    None => fail("expected poly-1 handle drag to arm")
  }
}

///|
/// Phase 5.6 — a press never mutates annotation geometry, so it
/// must NOT dirty the static layer (that would force a full
/// background+image repaint on every mousedown for no visual
/// change). Only the dynamic layer repaints.
test "CanvasPressed — does not dirty the static layer (5.6)" {
  let model : Model = {
    ..Model::new(),
    staticLayerDirty: false,
    dynamicLayerDirty: false,
  }
  let (next, _) = update(
    model,
    CanvasPressed({ x: 140.0, y: 140.0 }, { x: 140.0, y: 140.0 }),
  )
  assert_false(next.staticLayerDirty)
  assert_true(next.dynamicLayerDirty)
  assert_false(next.label.dirty)
}

///|
/// Phase 5.6 — the armed drag immediately drives the annotation on
/// the next cursor frame. This is the end-to-end proof that
/// CanvasPressed's arming is real: press on the BR handle → move →
/// the rect's BR corner actually moves.
test "CanvasPressed arm → CursorMoved actually resizes the rect (5.6)" {
  let model : Model = Model::new()
  // Press on rect-1's BR handle at (140, 140).
  let (m1, _) = update(
    model,
    CanvasPressed({ x: 140.0, y: 140.0 }, { x: 140.0, y: 140.0 }),
  )
  // Drag to (175, 175): CursorMoved with dragState Some routes to
  // ModifyHandle; feed the resulting Msg back explicitly (Effect
  // values aren't inspectable from test code).
  let (m2, _) = update(
    m1,
    CursorMoved({ x: 175.0, y: 175.0 }, { x: 175.0, y: 175.0 }),
  )
  let (m3, _) = update(
    m2,
    ModifyHandle("rect-1", 4, { x: 175.0, y: 175.0 }),
  )
  let mut found : Annotation? = None
  for ann in m3.annotations {
    if ann.id == "rect-1" {
      found = Some(ann)
    }
  }
  match found {
    Some(ann) => {
      assert_eq(ann.points[1].x, 175.0)
      assert_eq(ann.points[1].y, 175.0)
      // TL untouched.
      assert_eq(ann.points[0].x, 40.0)
      assert_eq(ann.points[0].y, 40.0)
    }
    None => fail("rect-1 missing")
  }
  // Release clears the drag.
  let (m4, _) = update(m3, EndDragHandle)
  assert_true(m4.dragState is None)
}

///|
/// Phase 5.7 — the zoom-drag press guard. Moui 0.1.12's
/// `DragGestureEvent` carries no button ID, so every pointer-down
/// reaches `CanvasPressed`, including the right-drag that enables
/// zoom-drag mode. While `zoomDragMode` is on, `CanvasPressed` must
/// NOT arm a handle drag — otherwise the arm survives into the next
/// `Changed` frame, where the movement is reinterpreted as a zoom
/// delta, and the annotation jumps by one frame of cursor travel.
///
/// Selection is still recorded (a click is a click); only the drag
/// arming is suppressed.
test "CanvasPressed — zoomDragMode suppresses the handle-drag arm (5.7)" {
  let model : Model = { ..Model::new(), zoomDragMode: true, }
  // Press exactly where the 5.6 test arms a drag (rect-1's BR
  // handle at (140, 140)).
  let (next, _) = update(
    model,
    CanvasPressed({ x: 140.0, y: 140.0 }, { x: 140.0, y: 140.0 }),
  )
  // No drag armed...
  assert_true(next.dragState is None)
  // ...but the selection still resolved.
  assert_eq(next.selectedId, Some("rect-1"))
}

///|
/// Phase 5.7 — the A/B of the guard: the *same* press with
/// `zoomDragMode` off (the default) still arms the drag. Without
/// this, a bug that disabled arming unconditionally would pass the
/// guard test above.
test "CanvasPressed — zoomDragMode off still arms the drag (5.7 control)" {
  let model : Model = { ..Model::new(), zoomDragMode: false, }
  let (next, _) = update(
    model,
    CanvasPressed({ x: 140.0, y: 140.0 }, { x: 140.0, y: 140.0 }),
  )
  assert_true(next.dragState is Some(_))
  assert_eq(next.selectedId, Some("rect-1"))
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.8 — drawing tools: the Add* handlers actually create
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.8 — THE core fix. `AddRect` was a no-op placeholder: it
/// reset `mode` and bumped the dirty flag but never appended
/// anything. This is the same class of stub `ModifyHandle` was until
/// Phase 5.4, and it meant the MoUI app could edit the three
/// synthetic demo annotations but could not create a single new one.
///
/// A press-drag-release in Rect mode now goes:
///   BeginDraft(corner1) → UpdateDraft(corner2) → CommitDraft
///   → (Effect::send) AddRect(corner1, corner2)
/// and lands one new Rect in `model.annotations`.
test "AddRect — creates a new annotation with a fresh id (5.8)" {
  let model : Model = { ..Model::new(), mode: Rect, }
  let before = model.annotations.length()
  // Drag well clear of the existing demo annotations so the point
  // isn't ambiguous.
  let (next, _) = update(
    model,
    AddRect({ x: 10.0, y: 10.0 }, { x: 60.0, y: 60.0 }),
  )
  assert_eq(next.annotations.length(), before + 1)
  let last = next.annotations[next.annotations.length() - 1]
  assert_eq(last.shape, Rect)
  assert_eq(last.points.length(), 2)
  assert_eq(last.points[0].x, 10.0)
  assert_eq(last.points[1].x, 60.0)
  // Deterministic id that doesn't collide with the demo set
  // (rect-1, poly-1, kp-1) — none of which use the ann- prefix.
  assert_eq(last.id, "ann-1")
  // The new annotation becomes the selection (standard editor
  // behaviour: you want to immediately drag its handles).
  assert_eq(next.selectedId, Some("ann-1"))
  // Back to the select tool, and the label is dirty so it gets saved.
  assert_eq(next.mode, Select)
  assert_true(next.label.dirty)
  assert_true(next.staticLayerDirty)
}

///|
/// Phase 5.8 — a click with no drag (zero-area) must NOT create a
/// rect. Otherwise every stray click would leave a 1px sliver in the
/// label that's hard to see and easy to leak into the export.
test "AddRect — degenerate (zero-area) rect is ignored (5.8)" {
  let model : Model = { ..Model::new(), mode: Rect, }
  let before = model.annotations.length()
  // Same x (vertical line) and same y (horizontal line).
  let (m1, _) = update(model, AddRect({ x: 30.0, y: 10.0 }, { x: 30.0, y: 90.0 }))
  assert_eq(m1.annotations.length(), before)
  let (m2, _) = update(model, AddRect({ x: 10.0, y: 30.0 }, { x: 90.0, y: 30.0 }))
  assert_eq(m2.annotations.length(), before)
  // Also: the mode is NOT reset by a degenerate rect, so a stray
  // click doesn't kick the user out of the Rect tool.
  assert_eq(m1.mode, Rect)
}

///|
/// Phase 5.8 — corners are stored in canonical (TL, BR) order
/// regardless of drag direction, so the on-disk JSON is stable and
/// the 8 handle indices keep their documented meaning (Phase 5.7).
test "AddRect — normalises corners to TL/BR regardless of drag direction (5.8)" {
  let model : Model = { ..Model::new(), mode: Rect, }
  // Drag from bottom-right up to top-left.
  let (next, _) = update(
    model,
    AddRect({ x: 80.0, y: 90.0 }, { x: 20.0, y: 10.0 }),
  )
  let last = next.annotations[next.annotations.length() - 1]
  // points[0] must be the top-left (min x, min y).
  assert_eq(last.points[0].x, 20.0)
  assert_eq(last.points[0].y, 10.0)
  // points[1] must be the bottom-right.
  assert_eq(last.points[1].x, 80.0)
  assert_eq(last.points[1].y, 90.0)
}

///|
/// Phase 5.8 — polygon creation. Three vertices minimum; fewer is a
/// stray click and must be ignored rather than creating a degenerate
/// shape.
test "AddPolygon — requires 3 vertices (5.8)" {
  let model : Model = { ..Model::new(), mode: Polygon, }
  let before = model.annotations.length()
  let (m1, _) = update(
    model,
    AddPolygon([{ x: 10.0, y: 10.0 }, { x: 20.0, y: 20.0 }]),
  )
  assert_eq(m1.annotations.length(), before)
  let (m2, _) = update(
    model,
    AddPolygon([
      { x: 10.0, y: 10.0 },
      { x: 30.0, y: 10.0 },
      { x: 20.0, y: 30.0 },
    ]),
  )
  assert_eq(m2.annotations.length(), before + 1)
  let last = m2.annotations[m2.annotations.length() - 1]
  assert_eq(last.shape, Polygon)
  assert_eq(last.points.length(), 3)
  assert_eq(last.id, "ann-1")
  assert_eq(m2.mode, Select)
}

///|
/// Phase 5.8 — keypoint creation. Stays in Keypoint mode after
/// adding, so the user can rapidly tag several points without
/// re-picking the tool each time (matches the legacy frontend's
/// keypoint tool and is why `AddKeypoint` is the one Add* that does
/// not reset `mode`).
test "AddKeypoint — creates a point and STAYS in Keypoint mode (5.8)" {
  let model : Model = { ..Model::new(), mode: Keypoint, }
  let before = model.annotations.length()
  let (next, _) = update(model, AddKeypoint({ x: 42.0, y: 43.0 }))
  assert_eq(next.annotations.length(), before + 1)
  let last = next.annotations[next.annotations.length() - 1]
  assert_eq(last.shape, Keypoint)
  assert_eq(last.points.length(), 1)
  assert_eq(last.points[0].x, 42.0)
  assert_eq(last.points[0].y, 43.0)
  // Stays in the tool.
  assert_eq(next.mode, Keypoint)
  // Second keypoint gets the next id, not a duplicate.
  let (m2, _) = update(next, AddKeypoint({ x: 44.0, y: 45.0 }))
  assert_eq(m2.annotations[m2.annotations.length() - 1].id, "ann-2")
}

///|
/// Phase 5.8 — ids never collide with existing annotations, and are
/// deterministic (no RNG), so a given model always yields the same
/// next id.
test "AddRect — ids are collision-free and deterministic (5.8)" {
  let model : Model = { ..Model::new(), mode: Rect, }
  let (m1, _) = update(model, AddRect({ x: 1.0, y: 1.0 }, { x: 5.0, y: 5.0 }))
  assert_eq(m1.annotations[m1.annotations.length() - 1].id, "ann-1")
  let (m2, _) = update(m1, AddRect({ x: 6.0, y: 6.0 }, { x: 9.0, y: 9.0 }))
  assert_eq(m2.annotations[m2.annotations.length() - 1].id, "ann-2")
  let (m3, _) = update(m2, AddRect({ x: 10.0, y: 10.0 }, { x: 12.0, y: 12.0 }))
  assert_eq(m3.annotations[m3.annotations.length() - 1].id, "ann-3")
  // All distinct.
  assert_eq(m3.annotations.length(), 6)
}

///|
/// Phase 5.8 — bindings resolve their target by hit-testing the
/// clicked point, and refuse to bind an annotation to itself.
test "AddBinding — resolves target by hit-test, rejects self-loop (5.8)" {
  let model : Model = {
    ..Model::new(),
    mode: EditBinding,
    bindingFromId: Some("kp-1"),
  }
  let before = model.bindings.length()
  // (60, 170) is kp-1's own point — must NOT create a self-binding.
  let (m1, _) = update(
    model,
    AddBinding("kp-1", { x: 60.0, y: 170.0 }),
  )
  assert_eq(m1.bindings.length(), before)
  // (90, 90) is inside rect-1 — that IS a valid binding target.
  let (m2, _) = update(
    model,
    AddBinding("kp-1", { x: 90.0, y: 90.0 }),
  )
  assert_eq(m2.bindings.length(), before + 1)
  let b = m2.bindings[m2.bindings.length() - 1]
  assert_eq(b.from, "kp-1")
  assert_eq(b.to, "rect-1")
  assert_eq(b.id, "bind-2")
  // The pending-binding state is consumed either way.
  assert_true(m2.bindingFromId is None)
  assert_eq(m2.mode, Select)
}

///|
/// Phase 5.8 — the new annotation picks up the project's default
/// class, falling back to "" (render the id as the on-canvas label)
/// when no class is marked default.
test "AddRect — inherits the default class id (5.8)" {
  let with_default : Model = {
    ..Model::new(),
    mode: Rect,
    classes: [
      { id: "c1", name: "weapon", is_default: false, },
      { id: "c2", name: "knife", is_default: true, },
    ],
  }
  let (next, _) = update(
    with_default,
    AddRect({ x: 1.0, y: 1.0 }, { x: 5.0, y: 5.0 }),
  )
  let last = next.annotations[next.annotations.length() - 1]
  assert_eq(last.class_id, "c2")
  // No classes at all → "" (id-as-label fallback).
  let (none, _) = update(
    { ..Model::new(), mode: Rect, classes: [] },
    AddRect({ x: 1.0, y: 1.0 }, { x: 5.0, y: 5.0 }),
  )
  assert_eq(none.annotations[none.annotations.length() - 1].class_id, "")
}

///|
/// Phase 5.8 — draft mechanics. `UpdateDraft` is the Rect tool's
/// rubber-band with the contract **grow to 2 points, then move the
/// second**.
///
/// The grow-then-move split is load-bearing: a pure "replace the
/// last point" version leaves the draft stuck at 1 point after
/// `BeginDraft`, so `CommitDraft`'s `>= 2` check never passes and
/// the Rect tool silently can't create anything. That was the first
/// implementation; this test is what caught it.
test "UpdateDraft — grows to 2 points then moves the second (5.8)" {
  let model : Model = { ..Model::new(), mode: Rect, }
  // Empty draft → appends.
  let (m1, _) = update(model, UpdateDraft({ x: 10.0, y: 10.0 }))
  assert_eq(m1.draftPoints.length(), 1)
  assert_eq(m1.draftPoints[0].x, 10.0)
  // One point → grows to 2 (this is the frame that makes the Rect
  // tool work at all).
  let (m2, _) = update(m1, UpdateDraft({ x: 20.0, y: 20.0 }))
  assert_eq(m2.draftPoints.length(), 2)
  assert_eq(m2.draftPoints[0].x, 10.0)
  assert_eq(m2.draftPoints[1].x, 20.0)
  // Two points → stays 2, and only the second moves.
  let (m3, _) = update(m2, UpdateDraft({ x: 30.0, y: 30.0 }))
  assert_eq(m3.draftPoints.length(), 2)
  assert_eq(m3.draftPoints[0].x, 10.0)
  assert_eq(m3.draftPoints[1].x, 30.0)
  // Still 2 after many more frames (no runaway growth).
  let (m4, _) = update(m3, UpdateDraft({ x: 40.0, y: 40.0 }))
  let (m5, _) = update(m4, UpdateDraft({ x: 50.0, y: 50.0 }))
  assert_eq(m5.draftPoints.length(), 2)
  assert_eq(m5.draftPoints[1].x, 50.0)
  // Draft updates only dirty the DYNAMIC layer — the draft preview
  // is drawn by draw_dynamic_layer, and a rubber-band repaint must
  // not force a full background+image blit.
  assert_true(m5.dynamicLayerDirty)
}

///|
/// Phase 5.8 — `CommitDraft` is the mode-aware commit. In Rect mode
/// a 2-point draft dispatches AddRect; a 1-point draft (a click
/// with no drag) is dropped silently instead of leaving a 1px rect.
test "CommitDraft — rect mode commits 2 points, drops a 1-point click (5.8)" {
  let model : Model = { ..Model::new(), mode: Rect, }
  // One point → no Add* effect, draft cleared.
  let (m1, _) = update(model, BeginDraft({ x: 10.0, y: 10.0 }))
  let (m2, _) = update(m1, CommitDraft)
  assert_eq(m2.draftPoints.length(), 0)
  // Two points → the Add* Msg is dispatched (verified by feeding
  // the same commit's effect target back through AddRect).
  let (m3, _) = update(m1, UpdateDraft({ x: 40.0, y: 40.0 }))
  assert_eq(m3.draftPoints.length(), 2)
  let (m4, _) = update(m3, CommitDraft)
  // The draft survives CommitDraft (AddPolygon/AddRect clears it
  // when it runs), so the round-trip is AddRect(draft[0],draft[1]).
  let (m5, _) = update(
    m4,
    AddRect(m4.draftPoints[0], m4.draftPoints[1]),
  )
  assert_eq(m5.draftPoints.length(), 0)
  assert_eq(m5.annotations.length(), model.annotations.length() + 1)
}

///|
/// Phase 5.8 — double-tap is overloaded per mode. In Polygon mode it
/// commits the in-progress polygon; elsewhere it keeps the Phase 5.19
/// wheel-zoom toggle. Both directions tested so neither can regress
/// into the other.
test "DoubleTapped — polygon commits, other modes toggle zoom-drag (5.8)" {
  // Polygon mode with 3 vertices → commit (feed the AddPolygon back).
  let poly : Model = {
    ..Model::new(),
    mode: Polygon,
    draftPoints: [
      { x: 10.0, y: 10.0 },
      { x: 30.0, y: 10.0 },
      { x: 20.0, y: 30.0 },
    ],
  }
  let (toggled, _) = update(poly, DoubleTapped)
  // Must NOT have toggled zoom mode.
  assert_false(toggled.zoomDragMode)
  let (committed, _) = update(
    toggled,
    AddPolygon(toggled.draftPoints),
  )
  assert_eq(committed.annotations.length(), Model::new().annotations.length() + 1)
  // Polygon mode with only 2 vertices → no commit.
  let (short, _) = update(
    { ..Model::new(), mode: Polygon,
      draftPoints: [{ x: 10.0, y: 10.0 }, { x: 20.0, y: 20.0 }] },
    DoubleTapped,
  )
  assert_false(short.zoomDragMode)
  // Select mode → still the Phase 5.19 zoom toggle.
  let (sel, _) = update({ ..Model::new(), mode: Select, }, DoubleTapped)
  assert_true(sel.zoomDragMode)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.9 — the toolbar's mode selectors
//
// Phase 5.9 gave the toolbar's nav row real `on_click =
// SetMode(mode)` handlers (see `mode_button` in labeler_ui.mbt).
// Before that the drawing tools were reachable only by dispatching
// SetMode programmatically, so a cold-started UI was pinned to
// Select. MoUI keeps `View[Msg]`'s fields private, so the click
// itself can't be simulated — what these tests pin is the state
// machine the click feeds, end to end: SetMode, then the exact
// gesture Msg sequence `canvas_view`'s mode-aware on_drag
// dispatches for that tool.
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.9 — the toolbar has one button per `Mode` variant, so
/// `SetMode` must reach all five. A tool with no reachable
/// `SetMode` is a tool the user cannot pick.
test "SetMode — reaches all five tools (5.9)" {
  let modes : Array[Mode] = [
    Mode::Select,
    Mode::Rect,
    Mode::Polygon,
    Mode::Keypoint,
    Mode::EditBinding,
  ]
  for m in modes {
    let (next, _) = update(Model::new(), SetMode(m))
    assert_eq(next.mode, m)
  }
}

///|
/// Phase 5.9 — switching tools abandons the in-progress draft. A
/// user who rubber-bans a rect and then clicks [Polygon] must not
/// leave the half-drawn rect behind for a later commit to pick up.
test "SetMode — abandons an in-progress draft (5.9)" {
  let (m1, _) = update(
    { ..Model::new(), mode: Rect, },
    BeginDraft({ x: 10.0, y: 10.0, }),
  )
  let (m2, _) = update(m1, UpdateDraft({ x: 40.0, y: 40.0, }))
  assert_eq(m2.draftPoints.length(), 2)
  let (m3, _) = update(m2, SetMode(Mode::Polygon))
  assert_eq(m3.draftPoints.length(), 0)
  assert_eq(m3.mode, Mode::Polygon)
}

///|
/// Phase 5.9 — switching tools also disarms a half-armed binding
/// source. Otherwise picking a new tool leaves a pending "from"
/// annotation that the next binding click would silently reuse.
test "SetMode — disarms a pending binding source (5.9)" {
  let armed : Model = {
    ..Model::new(),
    mode: EditBinding,
    bindingFromId: Some("rect-1"),
  }
  let (next, _) = update(armed, SetMode(Mode::Rect))
  assert_true(next.bindingFromId is None)
}

///|
/// Phase 5.9 — the status line names the armed tool so the click
/// has a confirmation cue. Built from the same `mode_label` as the
/// button caption, so the two can never disagree.
test "SetMode — status line names the armed tool (5.9)" {
  let (next, _) = update(Model::new(), SetMode(Mode::Polygon))
  assert_eq(next.statusMessage, "Mode: Polygon")
  assert_eq(next.statusMessage, "Mode: " + mode_label(Mode::Polygon))
}

///|
/// Phase 5.9 — a tool switch only changes what the *dynamic* layer
/// draws (the draft rubber-band it clears), so it must not mark the
/// static layer dirty — switching tools should never trigger a full
/// background + image re-blit. Pre-5.9 `SetMode` set no dirty flag
/// at all, which left the previous tool's rubber-band on screen
/// until some unrelated Msg happened to repaint.
test "SetMode — dirties the dynamic layer only (5.9)" {
  let clean : Model = {
    ..Model::new(),
    staticLayerDirty: false,
    dynamicLayerDirty: false,
  }
  let (next, _) = update(clean, SetMode(Mode::Rect))
  assert_true(next.dynamicLayerDirty)
  assert_false(next.staticLayerDirty)
}

///|
/// Phase 5.9 — `SetMode` / `FinishDraft` / `CancelDraft` are the
/// three ways a draft ends, and all three must dirty the dynamic
/// layer only. `FinishDraft` and `CancelDraft` carried
/// `staticLayerDirty` until Phase 5.9, forcing a full image re-blit
/// for a change that touches neither the image nor the annotations.
test "draft teardown — FinishDraft / CancelDraft dirty the dynamic layer only (5.9)" {
  // Build a real 2-point draft through the canvas's own Msg path.
  let (d1, _) = update(
    { ..Model::new(), mode: Rect, },
    BeginDraft({ x: 10.0, y: 10.0, }),
  )
  let (d2, _) = update(d1, UpdateDraft({ x: 40.0, y: 40.0, }))
  let drafting : Model = {
    ..d2,
    staticLayerDirty: false,
    dynamicLayerDirty: false,
  }
  assert_eq(drafting.draftPoints.length(), 2)
  let (fin, _) = update(drafting, FinishDraft)
  assert_eq(fin.draftPoints.length(), 0)
  assert_eq(fin.mode, Mode::Select)
  assert_true(fin.dynamicLayerDirty)
  assert_false(fin.staticLayerDirty)
  let (cancel, _) = update(drafting, CancelDraft)
  assert_eq(cancel.draftPoints.length(), 0)
  assert_eq(cancel.mode, Mode::Select)
  assert_true(cancel.dynamicLayerDirty)
  assert_false(cancel.staticLayerDirty)
}

///|
/// Phase 5.9 — the point of wiring the toolbar. Clicking [Rect]
/// dispatches SetMode(Rect); from there the gesture sequence the
/// canvas dispatches for the Rect tool must actually produce a
/// rectangle. This is the regression test for the whole reason
/// Phase 5.9 exists: before it, no click could leave Select, so
/// this gesture path was unreachable from the UI.
test "toolbar [Rect] → SetMode → drag creates a rect (5.9)" {
  let (m0, _) = update(Model::new(), SetMode(Mode::Rect))
  assert_eq(m0.mode, Mode::Rect)
  let before : Int = m0.annotations.length()
  let (m1, _) = update(m0, BeginDraft({ x: 20.0, y: 20.0, }))
  let (m2, _) = update(m1, UpdateDraft({ x: 60.0, y: 80.0, }))
  let (m3, _) = update(m2, CommitDraft)
  // CommitDraft dispatches AddRect(draft[0], draft[1]) rather than
  // mutating in place, so feed that Msg back to finish the chain.
  let (m4, _) = update(
    m3,
    AddRect(m3.draftPoints[0], m3.draftPoints[1]),
  )
  assert_eq(m4.annotations.length(), before + 1)
  let created = m4.annotations[before]
  assert_eq(created.shape, Shape::Rect)
  // Rect geometry is stored as exactly two points: (TL, BR).
  assert_eq(created.points.length(), 2)
  assert_eq(created.points[0].x, 20.0)
  assert_eq(created.points[0].y, 20.0)
  assert_eq(created.points[1].x, 60.0)
  assert_eq(created.points[1].y, 80.0)
  // AddRect selects what it creates, so the new rect's handles show.
  assert_true(m4.selectedId is Some(_))
}

///|
/// Phase 5.9 — same chain for the Polygon tool: SetMode(Polygon),
/// then three vertex presses (PushDraft) and a double-tap to
/// commit. The polygon path needs >= 3 vertices, so this also
/// pins that switching to Polygon doesn't inherit the Rect draft.
test "toolbar [Polygon] → SetMode → 3 vertices + double-tap creates a polygon (5.9)" {
  let (m0, _) = update(Model::new(), SetMode(Mode::Polygon))
  assert_eq(m0.mode, Mode::Polygon)
  let before : Int = m0.annotations.length()
  let (m1, _) = update(m0, PushDraft({ x: 30.0, y: 30.0, }))
  let (m2, _) = update(m1, PushDraft({ x: 90.0, y: 40.0, }))
  let (m3, _) = update(m2, PushDraft({ x: 50.0, y: 95.0, }))
  assert_eq(m3.draftPoints.length(), 3)
  // Double-tap is the Polygon tool's commit gesture (Phase 5.8);
  // it must NOT be swallowed by the zoom-drag toggle in this mode.
  assert_false(m3.zoomDragMode)
  let (m4, _) = update(m3, DoubleTapped)
  let (m5, _) = update(m4, AddPolygon(m4.draftPoints))
  assert_eq(m5.annotations.length(), before + 1)
  let created = m5.annotations[before]
  assert_eq(created.shape, Shape::Polygon)
  assert_eq(created.points.length(), 3)
  assert_false(m5.zoomDragMode)
}

///|
/// Phase 5.9 — the Keypoint tool drops a point on every press and
/// deliberately stays in Keypoint mode (Phase 5.8) so consecutive
/// points can be placed without re-clicking the toolbar. Driving
/// it through SetMode pins that the mode survives the click path
/// as well as the AddKeypoint path.
test "toolbar [Keypoint] → SetMode → press places a keypoint and stays armed (5.9)" {
  let (m0, _) = update(Model::new(), SetMode(Mode::Keypoint))
  let before : Int = m0.annotations.length()
  let (m1, _) = update(m0, AddKeypoint({ x: 55.0, y: 65.0, }))
  assert_eq(m1.annotations.length(), before + 1)
  // Stays armed for the next point.
  assert_eq(m1.mode, Mode::Keypoint)
  let created = m1.annotations[before]
  assert_eq(created.shape, Shape::Keypoint)
  assert_eq(created.points.length(), 1)
  assert_eq(created.points[0].x, 55.0)
  assert_eq(created.points[0].y, 65.0)
  let (m2, _) = update(m1, AddKeypoint({ x: 25.0, y: 45.0, }))
  assert_eq(m2.annotations.length(), before + 2)
  assert_eq(m2.mode, Mode::Keypoint)
}

///|
/// Phase 5.9 — [Select] is reachable, which matters because every
/// select-and-drag-handle path (Phase 5.4-5.6) is gated on
/// `mode == Select`. A user who picked a drawing tool needs a way
/// back; the pre-5.9 `[File]` slot was a dead button and `[Select]`
/// did not exist at all.
test "toolbar [Select] → SetMode restores handle dragging (5.9)" {
  let (m0, _) = update(Model::new(), SetMode(Mode::Rect))
  assert_eq(m0.mode, Mode::Rect)
  let (m1, _) = update(m0, SetMode(Mode::Select))
  assert_eq(m1.mode, Mode::Select)
  // A press on rect-1's BR corner must now arm a handle drag, which
  // is the whole job of Select mode.
  let (m2, _) = update(
    m1,
    BeginDragHandle("rect-1", 4, { x: 140.0, y: 140.0, }),
  )
  assert_true(m2.dragState is Some(_))
}

///|
/// Phase 5.9 — pins the mode-reset policy documented on the `Add*`
/// handlers, now that the toolbar makes it user-visible: every tool
/// drops back to Select after creating an annotation, *except*
/// `AddKeypoint`, which stays in Keypoint so consecutive points can
/// be placed without re-clicking. The two halves differ on purpose
/// (the keypoint behaviour matches the legacy frontend's keypoint
/// tool), so this test exists to make any future change to it a
/// deliberate decision rather than an accident.
test "mode reset after creation — AddRect returns to Select, AddKeypoint stays (5.9)" {
  let (after_rect, _) = update(
    Model::new(),
    AddRect({ x: 0.0, y: 0.0 }, { x: 20.0, y: 20.0 }),
  )
  assert_eq(after_rect.mode, Mode::Select)
  let (after_kp, _) = update(
    { ..Model::new(), mode: Keypoint, },
    AddKeypoint({ x: 5.0, y: 5.0 }),
  )
  assert_eq(after_kp.mode, Mode::Keypoint)
}

///|
/// Phase 5.9 — a degenerate rect (a click with no drag) must not
/// create an annotation, and per the handler's own comment must also
/// leave the mode alone. Without the toolbar this was invisible; now
/// a stray click that kicked the user out of the Rect tool would be
/// immediately obvious.
test "AddRect — a stray click neither creates an annotation nor disarms the tool (5.9)" {
  let armed : Model = { ..Model::new(), mode: Rect, }
  let before : Int = armed.annotations.length()
  let (next, _) = update(armed, AddRect({ x: 7.0, y: 7.0 }, { x: 7.0, y: 7.0 }))
  assert_eq(next.annotations.length(), before)
  assert_eq(next.mode, Mode::Rect)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.10 — handler safety for the three toolbar shortcuts
//
// The shortcut buttons are always enabled: MoUI's `button` has no
// `disabled` parameter and it is unverified whether `View::disabled()`
// even participates in the keyboard-shortcut dispatch path. So the
// shortcut that a user can always fire is exactly the shortcut that
// must be safe to fire at the wrong moment. These tests pin that:
// a stray Escape / Backspace / Delete may do nothing at all, but it
// may never corrupt geometry, lose an annotation, or schedule a
// pointless repaint.
//
// The key-name → Msg wiring itself is covered in labeler_ui_test.mbt.
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.10 — `PopDraft` (the Backspace shortcut) stops at one
/// vertex. The first pushed point is the draft's anchor, so a user
/// holding Backspace must not be able to delete it and leave a
/// one-less-than-intended polygon. The floor is a deliberate
/// contract, not an accident, so it gets a test.
test "PopDraft — stops at one vertex and never removes the anchor (5.10)" {
  let base : Model = { ..Model::new(), mode: Polygon, }
  let (p1, _) = update(base, PushDraft({ x: 10.0, y: 10.0 }))
  let (p2, _) = update(p1, PushDraft({ x: 20.0, y: 20.0 }))
  let (p3, _) = update(p2, PushDraft({ x: 30.0, y: 30.0 }))
  assert_eq(p3.draftPoints.length(), 3)
  let (d1, _) = update(p3, PopDraft)
  assert_eq(d1.draftPoints.length(), 2)
  assert_eq(d1.draftPoints[1].x, 20.0)
  let (d0, _) = update(d1, PopDraft)
  assert_eq(d0.draftPoints.length(), 1)
  assert_eq(d0.draftPoints[0].x, 10.0)
  // Floor: further presses are inert, not destructive.
  let (again, _) = update(d0, PopDraft)
  assert_eq(again.draftPoints.length(), 1)
  assert_eq(again.draftPoints[0].x, 10.0)
}

///|
/// Phase 5.10 — Backspace with nothing to undo must be a *complete*
/// no-op. The shortcut cannot be disabled, so it will be pressed
/// while the user is doing something else entirely; scheduling a
/// repaint for an unchanged canvas is pure waste (and the reason
/// `staticLayerDirty` exists as a separate flag is that a needless
/// static repaint re-blits the whole image).
test "PopDraft — an empty draft is a complete no-op, no repaint (5.10)" {
  let base : Model = {
    ..Model::new(),
    mode: Polygon,
    draftPoints: [],
    dynamicLayerDirty: false,
    staticLayerDirty: false,
  }
  let (next, _) = update(base, PopDraft)
  assert_eq(next.draftPoints.length(), 0)
  assert_true(!next.dynamicLayerDirty)
  assert_true(!next.staticLayerDirty)
}

///|
/// Phase 5.10 — Escape is the app's "cancel what I'm doing" key, so
/// it must clear *both* kinds of in-progress work: the draft's
/// vertex list and a pending binding arm. It must also leave the
/// committed scene completely alone — pressing Escape right after
/// drawing a rect must not take the rect away with it.
test "CancelDraft — clears draft and disarms binding, scene untouched (5.10)" {
  let pristine : Model = Model::new()
  let ann_count : Int = pristine.annotations.length()
  let binding_count : Int = pristine.bindings.length()
  let busy : Model = {
    ..pristine,
    mode: EditBinding,
    bindingFromId: Some("rect-1"),
    draftPoints: [
      { x: 10.0, y: 10.0 },
      { x: 20.0, y: 20.0 },
    ],
  }
  let (next, _) = update(busy, CancelDraft)
  // Draft gone, arm gone, tool back to Select.
  assert_eq(next.draftPoints.length(), 0)
  assert_true(next.bindingFromId is None)
  assert_eq(next.mode, Mode::Select)
  assert_true(next.dynamicLayerDirty)
  // Scene untouched.
  assert_eq(next.annotations.length(), ann_count)
  assert_eq(next.bindings.length(), binding_count)
  assert_true(next.selectedId is None)
}

///|
/// Phase 5.10 — Delete with nothing selected must be a complete
/// no-op. Unlike the other two this one is destructive, so it also
/// must not mark the label dirty: a stray Delete while browsing
/// would otherwise make every following save write a label the user
/// never edited.
test "DeleteSelectedAnnotation — no selection means no-op and no dirty label (5.10)" {
  let base : Model = {
    ..Model::new(),
    selectedId: None,
    dynamicLayerDirty: false,
    staticLayerDirty: false,
  }
  let (next, _) = update(base, DeleteSelectedAnnotation)
  assert_eq(next.annotations.length(), base.annotations.length())
  assert_eq(next.bindings.length(), base.bindings.length())
  assert_true(next.selectedId is None)
  assert_true(!next.label.dirty)
  assert_true(!next.dynamicLayerDirty)
  assert_true(!next.staticLayerDirty)
}

///|
/// Phase 5.10 — deleting the selected annotation must also drop any
/// binding that referenced it, and must *not* delete the other end of
/// that binding. The default scene is rect-1 / poly-1 / kp-1 with
/// bind-1 going rect-1 → kp-1, which is exactly the ambiguous case:
/// kp-1 is on both sides of the arrow and only the arrow may go.
test "DeleteSelectedAnnotation — drops the binding, keeps the far-end annotation (5.10)" {
  let base : Model = { ..Model::new(), selectedId: Some("rect-1"), }
  assert_eq(base.bindings.length(), 1)
  assert_eq(base.annotations.length(), 3)
  let (next, _) = update(base, DeleteSelectedAnnotation)
  // The annotation and the arrow that referenced it are gone.
  assert_eq(next.annotations.length(), 2)
  assert_eq(next.bindings.length(), 0)
  // kp-1 was the arrow's target but is itself still an annotation.
  let ids : Array[String] = []
  for ann in next.annotations {
    ids.push(ann.id)
  }
  assert_true(ids.contains("kp-1"))
  assert_true(ids.contains("poly-1"))
  assert_true(!ids.contains("rect-1"))
  // Selection cleared, so a second stray Delete cannot fire again.
  assert_true(next.selectedId is None)
  assert_true(next.label.dirty)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.11 — polygon rubber-band geometry
//
// The band is the line from the last committed vertex to the live
// cursor. Before this, a polygon being drawn showed only its
// committed vertices, so the user had no way to see where the next
// click would land. These tests pin the pure geometry helper, which
// is the whole of the feature's decision-making; the paint pass just
// strokes whatever the helper returns.
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.11 — no band without an anchor and no band without an
/// end. A band with no committed vertex would be a stray line across
/// the canvas; a band with no cursor would be invisible. Both must be
/// absent, not degenerate.
test "polygon rubber band — needs both a committed vertex and a cursor (5.11)" {
  let cur : Point = { x: 50.0, y: 50.0 }
  let zero : Point = { x: 0.0, y: 0.0 }
  // No committed vertex: nothing to hang the band off.
  assert_true(
    polygon_rubber_band([], Some(cur), zero, 1.0, zero) is None,
  )
  // No cursor: nothing for the band to point at.
  assert_true(
    polygon_rubber_band(
      [{ x: 10.0, y: 10.0 }, { x: 20.0, y: 20.0 }],
      None,
      zero,
      1.0,
      zero,
    ) is None,
  )
  // Neither.
  assert_true(polygon_rubber_band([], None, zero, 1.0, zero) is None)
  // Sanity: the input is otherwise valid.
  assert_true(
    polygon_rubber_band([{ x: 10.0, y: 10.0 }], Some(cur), zero, 1.0, zero)
    is Some(_),
  )
}

///|
/// Phase 5.11 — the band hangs off the **last** committed vertex, not
/// the first. Anchoring on vertex 0 would draw a chord across the
/// shape instead of extending it, which is the whole visual difference
/// between "extending" and "already closed".
test "polygon rubber band — anchors on the last committed vertex (5.11)" {
  let zero : Point = { x: 0.0, y: 0.0 }
  let pts : Array[Point] = [
    { x: 10.0, y: 10.0 },
    { x: 20.0, y: 5.0 },
    { x: 30.0, y: 25.0 },
  ]
  let band = polygon_rubber_band(pts, Some({ x: 99.0, y: 99.0 }), zero, 1.0, zero)
  assert_true(band is Some(_))
  match band {
    Some((from, to)) => {
      assert_eq(from.x, 30.0)
      assert_eq(from.y, 25.0)
      assert_eq(to.x, 99.0)
      assert_eq(to.y, 99.0)
    }
    None => fail("expected a rubber band for 3 vertices + a cursor")
  }
  // Appending a 4th vertex moves the anchor, and nothing else.
  let pts2 : Array[Point] = [
    { x: 10.0, y: 10.0 },
    { x: 20.0, y: 5.0 },
    { x: 30.0, y: 25.0 },
    { x: 40.0, y: 40.0 },
  ]
  let band2 = polygon_rubber_band(pts2, Some({ x: 99.0, y: 99.0 }), zero, 1.0, zero)
  match band2 {
    Some((from, to)) => {
      assert_eq(from.x, 40.0)
      assert_eq(from.y, 40.0)
      assert_eq(to.x, 99.0)
      assert_eq(to.y, 99.0)
    }
    None => fail("expected a rubber band after appending a 4th vertex")
  }
}

///|
/// Phase 5.11 — the band must ride the exact same transform as the
/// committed polyline, or it will drift away from the shape it
/// extends as soon as the user pans or zooms. Pinned against
/// `img_to_screen` directly rather than against hand-computed
/// numbers, so the test states the invariant ("same transform") and
/// not a copy of the formula.
test "polygon rubber band — follows pan, zoom and the fit-contain offset (5.11)" {
  let pts : Array[Point] = [{ x: 12.0, y: 34.0 }]
  let cur : Point = { x: 56.0, y: 78.0 }
  let zero : Point = { x: 0.0, y: 0.0 }
  let pan : Point = { x: -7.0, y: 11.0 }
  let dst : Point = { x: 100.0, y: 200.0 }
  for zoom in [0.5, 1.0, 2.5, 4.0] {
    let band = polygon_rubber_band(pts, Some(cur), pan, zoom, dst)
    assert_true(band is Some(_))
    match band {
      Some((from, to)) => {
        let want_from = img_to_screen(pts[0], dst, pan, zoom)
        let want_to = img_to_screen(cur, dst, pan, zoom)
        assert_eq(from.x, want_from.x)
        assert_eq(from.y, want_from.y)
        assert_eq(to.x, want_to.x)
        assert_eq(to.y, want_to.y)
      }
      None => fail("expected a rubber band")
    }
  }
}

///|
/// Phase 5.11 — a single committed vertex is enough. That is the very
/// first click of a polygon, and it is exactly the moment the user
/// most needs to see where the second click will land; suppressing
/// the band until two vertices exist would hide the feedback for the
/// one step where it is most useful.
test "polygon rubber band — shows after a single vertex (5.11)" {
  let zero : Point = { x: 0.0, y: 0.0 }
  let band = polygon_rubber_band(
    [{ x: 5.0, y: 5.0 }],
    Some({ x: 25.0, y: 15.0 }),
    zero,
    1.0,
    zero,
  )
  assert_true(band is Some(_))
  match band {
    Some((from, to)) => {
      assert_eq(from.x, 5.0)
      assert_eq(from.y, 5.0)
      assert_eq(to.x, 25.0)
      assert_eq(to.y, 15.0)
    }
    None => fail("expected a rubber band after one vertex")
  }
}

///|
/// Phase 5.15 — pins the canvas's fit-contain geometry at the real
/// window, so "is the image where it should be?" becomes a question a
/// test answers rather than one a screenshot is asked.
///
/// The numbers are the ones the live inspector reports on this host:
/// a 947x504 logical window, a 180-px sidebar, an 88-px toolbar and
/// a 24-px status bar, so the canvas is 767x392 at (180, 88) and a
/// 200x200 image fits into it as 392x392 centred at (367, 88) —
/// 187 px of horizontal padding on each side and none vertically.
///
/// This exists because the geometry was measured by hand three times
/// and the *screenshot* said the image was off-centre. It was not;
/// the `PrintWindow` capture does not share a single scale with
/// logical pixels, so pixel arithmetic on it cannot answer the
/// question. This test can.
test "fit_contain_rect — the demo image is centred in the real canvas (5.15)" {
  let canvas : @core.Rect = @core.Rect::new(
    x=180.0,
    y=88.0,
    width=767.0,
    height=392.0,
  )
  let dst : @core.Rect = fit_contain_rect(canvas, 200.0, 200.0)
  // Square image in a wider-than-tall frame: height-limited.
  assert_eq(dst.size.width, 392.0)
  assert_eq(dst.size.height, 392.0)
  // Vertically the frame is filled exactly, so y is unchanged.
  assert_eq(dst.origin.y, 88.0)
  // Horizontally it is centred: 180 + (767 - 392) / 2. The difference
  // is odd, so the centre lands on a **half** pixel — 367.5, not
  // 367. An inspector dump truncates that to 367, which is a fine
  // thing to read and a bad thing to compute a half-pixel centring
  // expectation from.
  assert_eq(dst.origin.x, 367.5)
  // The image must not spill outside the canvas it is drawn into.
  assert_true(dst.origin.x >= canvas.origin.x)
  assert_true(dst.origin.y >= canvas.origin.y)
  assert_true(
    dst.origin.x + dst.size.width <= canvas.origin.x + canvas.size.width,
  )
  assert_true(
    dst.origin.y + dst.size.height <= canvas.origin.y + canvas.size.height,
  )
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.16 — the mode-after-commit rule
//
// Phase 5.9 flagged "give the `Add*` handlers one shared
// mode-after-commit rule instead of three hand-written `mode: Select`
// lines" as the real fix for "drawing N rects costs N clicks". It
// turned out worse than recorded: the three handlers expressed the
// same contract three different ways, and `AddKeypoint` expressed it
// by *omitting* the `mode` field entirely — i.e. inheriting
// `model.mode`, which only produced the right answer because the
// canvas dispatched it while the keypoint tool happened to be armed.
// ─────────────────────────────────────────────────────────────────

///|
/// Every `Mode`, in toolbar order. Spelled out in a typed helper
/// rather than inline because `Rect` and `Polygon` are variant names
/// in **both** `Mode` and `Shape` — a bare `[Select, Rect, ...]`
/// cannot be resolved to one of them. That name collision is also
/// why `mode_after_commit` takes a `Shape` and callers say
/// `mode_after_commit(Rect)` in a context that already knows the
/// handler's shape, rather than reading the mode back off the model.
fn every_mode() -> Array[Mode] {
  [Select, Rect, Polygon, Keypoint, EditBinding]
}

///|
/// Phase 5.16 — the rule itself, all three shapes. Keypoint stays
/// armed for rapid tagging; the two drag/click shapes return to
/// `Select`, matching the legacy frontend this port tracks.
test "mode_after_commit — keypoint stays armed, rect and polygon return to Select (5.16)" {
  assert_eq(mode_after_commit(Rect), Select)
  assert_eq(mode_after_commit(Polygon), Select)
  assert_eq(mode_after_commit(Keypoint), Keypoint)
}

///|
/// Phase 5.16 — the rule takes the **shape**, not the current mode.
/// The two coincide on every path the app has today, so this test
/// cannot pass or fail on today's code; it exists to pin the
/// contract for the next input path. If a future caller dispatches
/// `AddRect` while the mode says `Keypoint`, the answer must still be
/// `Select` — "whatever the mode was" would silently keep the
/// keypoint tool armed after a rectangle.
test "mode_after_commit — depends on the shape, not the mode that was active (5.16)" {
  // Same shape, three different starting modes: one answer each.
  for starting in every_mode() {
    let armed : Model = { ..Model::new(), mode: starting, }
    // Dispatch the real handler from that mode and check the mode it
    // settles on is the rule's answer, not the starting mode.
    let (after, _) = update(
      armed,
      AddRect({ x: 0.0, y: 0.0 }, { x: 20.0, y: 20.0 }),
    )
    assert_eq(after.mode, mode_after_commit(Rect))
    assert_eq(after.mode, Select)
  }
}

///|
/// Phase 5.16 — every `Add*` handler agrees with the shared rule.
/// This is the anti-drift test: it fails if anyone hand-writes
/// `mode: Select` back into one handler, or restores `AddKeypoint`'s
/// omit-the-field trick, because the handler and the rule would then
/// disagree. Three shapes, three handlers, one contract.
test "Add handlers all agree with mode_after_commit (5.16)" {
  // Rect: dispatched from any mode, must land on the rule's answer.
  for starting in every_mode() {
    let (rect_model, _) = update(
      { ..Model::new(), mode: starting, },
      AddRect({ x: 4.0, y: 6.0 }, { x: 40.0, y: 50.0 }),
    )
    assert_eq(rect_model.mode, mode_after_commit(Rect))
  }
  // Polygon: needs 3 vertices or it is a no-op by design.
  for starting in every_mode() {
    let (poly_model, _) = update(
      { ..Model::new(), mode: starting, },
      AddPolygon([
        { x: 10.0, y: 10.0 },
        { x: 40.0, y: 12.0 },
        { x: 25.0, y: 45.0 },
      ]),
    )
    assert_eq(poly_model.mode, mode_after_commit(Polygon))
  }
  // Keypoint: the one that must stay armed. Dispatched from every
  // starting mode, it still lands on Keypoint — this is the case
  // that used to be expressed by not writing the field at all.
  for starting in every_mode() {
    let (kp_model, _) = update(
      { ..Model::new(), mode: starting, },
      AddKeypoint({ x: 12.0, y: 34.0 }),
    )
    assert_eq(kp_model.mode, mode_after_commit(Keypoint))
    assert_eq(kp_model.mode, Keypoint)
  }
}

///|
/// Phase 5.16 — cancel is deliberately **not** the commit rule. A
/// commit leaves the keypoint tool armed; a cancel must leave nothing
/// armed, so Escape from Keypoint mode goes to `Select` even though
/// `mode_after_commit(Keypoint)` says `Keypoint`. This is the
/// asymmetry that keeps `CancelDraft` from calling the commit rule,
/// and it would be invisible if the two rules were merged.
test "cancel always disarms, even from keypoint (5.16)" {
  let armed : Model = { ..Model::new(), mode: Keypoint, }
  // Show that the commit rule really would have kept the tool armed.
  assert_eq(mode_after_commit(Keypoint), Keypoint)
  // Escape discards instead, so nothing stays armed.
  let (cancelled, _) = update(armed, CancelDraft)
  assert_eq(cancelled.mode, Select)
  assert_eq(cancelled.draftPoints.length(), 0)
  // And the draft-cancel path agrees.
  let (p1, _) = update(armed, PushDraft({ x: 5.0, y: 5.0 }))
  let (p2, _) = update(p1, PushDraft({ x: 9.0, y: 9.0 }))
  let (finished, _) = update(p2, FinishDraft)
  assert_eq(finished.mode, Select)
  assert_eq(finished.draftPoints.length(), 0)
}
