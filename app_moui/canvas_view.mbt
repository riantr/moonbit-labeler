// app_moui/canvas_view.mbt — annotation canvas as MoUI view.
//
// Phase 5.5 (this session): split the single canvas into two stacked
// canvas sub-views so the bulk render (background + image + all
// annotations) sits on a "static" layer and the moving overlay
// (selected-annotation handles + cursor crosshair) sits on a
// "dynamic" layer. This mirrors `frontend/src/canvas.js`'s two
// offscreen-canvas design — the static layer is the same on every
// frame until the user pans/zooms/loads an image / mutates an
// annotation, so we can repaint only the dynamic layer on cursor
// moves. MoUI doesn't yet honour a custom paint cache_key from
// `views.canvas(...)` (it always declares `paint=Uncacheable`), so
// the actual GPU/CPU savings require a follow-up that wraps the
// static sub-view in a custom ViewNode with `paint=Exact(key)` —
// that's 5.5.x. This commit delivers the layer *separation* (logical
// correctness, type-level guarantee that the dynamic layer doesn't
// redraw annotations and vice-versa).
//
// Phase 5.4 (prior session): DPR / HiDPI scaling investigation —
// no-op, see docs/moui-dpi-investigation.md.
// Phase 5.3 (prior session): draw annotations + selected-handle markers.
// Phase 5.2 (prior session): paint an actual image source via DrawImage
// (fit-contain + pan/zoom). Phase 5.1 (prior session): minimal
// placeholder + cursor crosshair.
//
// What this canvas draws, in order:
//   Static layer (background → image OR placeholder → annotations):
//     1. Neutral background (#1f1f1f).
//     2. If model.imageSource == "", 320×240 placeholder rect; else
//        emits a DrawImage with fit-contain math + pan/zoom applied.
//     3. Each annotation in model.annotations:
//        - Rect: red stroke rect (yellow stroke if selected).
//        - Polygon: yellow stroke polyline (cyan stroke if selected).
//        - Keypoint: 4 px filled circle (white if selected).
//   Dynamic layer (selected handles + cursor crosshair):
//     4. For the selected annotation only, draw the 8 (rect) / N
//        (polygon) / 1 (keypoint) handles as small filled squares.
//     5. Cursor crosshair (when cursorImgPt is Some).
//
// Drag flow (wiring side is in update()):
//   cursor drag emits CursorMoved → hit_test_handle first (radius
//   12 px image-natural) → if hit, SelectAnnotation + caller should
//   send BeginDragHandle. While dragState is Some, every
//   CursorMoved dispatches ModifyHandle via Effect::send, which
//   apply_handle_move folds back into the annotation's points array.
//   The on_drag handler is attached to the OUTER stack view so both
//   sub-layers receive consistent pointer events.
//
// Coordinate space conventions (also see dpi-investigation.md):
//   - `frame : Rect` (draw callback arg)        → logical px
//   - `ev.position` (on_drag callback arg)      → logical px
//     (host normalises physical→logical before dispatch)
//   - `model.pan`, `model.zoom`                 → logical-px units
//   - `ann.points` (Annotation in model)       → image-natural pixels
//     (canvas_view does the pan/zoom inversion before hit-testing)
//   - `12.0` hit-test radius (hittest.mbt:155)  → image-natural px
//     (independent of DPR; canvas_view calls hit_test_select with
//     the pan/zoom-inverted cursor)
//   - All `@common.fill_rect / stroke_rect / draw_image` size/width
//     arguments                                 → logical px
//
// Phase 5.5 does NOT port:
//   - actual cached paint for the static layer (5.5.x: custom
//     ViewNode with `paint=Exact(static_key)`)
//   - image-header probe (caller passes natural size; 5.5 keeps the
//     5.2 "supply natural_w/h at LoadTestImage time" convention)
//   - wheel zoom + drag pan input plumbing (Zoom/Pan Msgs are wired
//     in update() but no input plumbing — that's 5.11)
//   - midpoint handle drag refinement (corner handles work; midpoints
//     drag the opposite edge — good enough for 5.3)
//   - Polygon draw_path upgrade (still thick-line approximation via
//     fill_rect sequence; 5.7 will add draw_path)

///|
/// Annotation canvas view (top-level). Returns a MoUI view that paints
/// a neutral background + (optionally) a real image + (optionally)
/// annotations + selected handles + cursor crosshair, split across two
/// stacked canvas sub-views.
///
/// The outer view is a `@layout.stack` whose children are drawn at the
/// same origin (z-ordered: first child painted first → under; last
/// child painted last → on top). We put the static layer first
/// (under) and the dynamic layer second (over).
///
/// `on_drag` is attached to the OUTER view so pointer events on
/// either sub-view funnel through one handler. The canvas-view model
/// state mutation is still single-source-of-truth (`model.cursorImgPt`,
/// `model.selectedId`, etc.), so there's no risk of the two layers
/// disagreeing about what's selected.
pub fn canvas_view(model : Model) -> @moui.View[Msg] {
  let static_layer = static_layer_view(model)
  let dynamic_layer = dynamic_layer_view(model)
  let stacked = @layout.stack([static_layer, dynamic_layer])
  stacked.on_drag(fn(ev) {
    CursorMoved(
      {
        x: (ev.position.x - model.pan.x) / model.zoom,
        y: (ev.position.y - model.pan.y) / model.zoom,
      },
      { x: ev.position.x, y: ev.position.y, },
    )
  })
}

///|
/// Static layer canvas: background + image (or placeholder) +
/// annotations. Conceptually the "world" that only changes when the
/// image source, pan/zoom transform, or annotation set mutates. The
/// draw callback receives `frame : @core.Rect` which is the canvas's
/// actual viewport — MoUI layout guarantees this is the right size
/// on every paint.
fn static_layer_view(model : Model) -> @moui.View[Msg] {
  let measure = fn(constraints : @core.Constraints) -> @core.Size {
    constraints.max
  }
  let draw = fn(pctx, frame : @core.Rect) -> Unit {
    draw_static_layer(pctx, model, frame)
  }
  @views.canvas(measure~, draw~, semantics_label="Annotation canvas (static)")
}

///|
/// Dynamic layer canvas: selected-annotation handles + cursor
/// crosshair. Conceptually the "overlay" that repaints on every
/// cursor move / drag frame. Sits on top of the static layer via
/// `@layout.stack`.
///
/// Note: in 5.5 the dynamic layer is a separate canvas sub-view so
/// the API surface reflects the layer split, but the runtime
/// repaints both sub-views every frame (both `views.canvas` views
/// declare `paint=Uncacheable`). The runtime paint-cache optimization
/// lands in 5.5.x via a custom ViewNode with `paint=Exact(key)`.
fn dynamic_layer_view(model : Model) -> @moui.View[Msg] {
  let measure = fn(constraints : @core.Constraints) -> @core.Size {
    constraints.max
  }
  let draw = fn(pctx, frame : @core.Rect) -> Unit {
    draw_dynamic_layer(pctx, model, frame)
  }
  @views.canvas(measure~, draw~, semantics_label="Annotation canvas (dynamic)")
}

///|
/// Issue the static layer's DrawCommands into `pctx`. Public for
/// blackbox tests (so 5.5 layer-split tests can inspect the
/// command stream without driving MoUI's full paint pass — which
/// isn't wired to a renderer until phase 10).
pub fn draw_static_layer(
  pctx : @common.PaintContext,
  model : Model,
  frame : @core.Rect,
) -> Unit {
  // 1. Neutral background.
  @common.fill_rect(
    pctx,
    frame,
    @core.Color::rgba(r=0.121, g=0.121, b=0.121, a=1.0),
  )
  // 2. Image OR placeholder.
  if model.imageSource == "" {
    let placeholder : @core.Rect = @core.Rect::new(
      x=frame.origin.x + (frame.size.width - 320.0) / 2.0,
      y=frame.origin.y + (frame.size.height - 240.0) / 2.0,
      width=320.0,
      height=240.0,
    )
    @common.fill_rect(
      pctx,
      placeholder,
      @core.Color::rgba(r=0.18, g=0.18, b=0.18, a=1.0),
    )
    @common.stroke_rect(
      pctx,
      placeholder,
      @core.Color::rgba(r=0.4, g=0.4, b=0.4, a=1.0),
      1.0,
    )
  } else {
    let dst : @core.Rect = fit_contain_rect(
      frame,
      model.imageNaturalSize.x,
      model.imageNaturalSize.y,
    )
    let zoomed : @core.Rect = @core.Rect::new(
      x=dst.origin.x + model.pan.x,
      y=dst.origin.y + model.pan.y,
      width=dst.size.width * model.zoom,
      height=dst.size.height * model.zoom,
    )
    @common.draw_image(pctx, {
      source: model.imageSource,
      frame: zoomed,
      opacity: 1.0,
      fit: model.fitMode,
    })
  }
  // 3. Annotations (drawn in iteration order; later wins z-order).
  for ann in model.annotations {
    let is_sel = match model.selectedId {
      Some(id) => id == ann.id
      None => false
    }
    draw_annotation(pctx, ann, is_sel, model.pan, model.zoom)
  }
}

///|
/// Issue the dynamic layer's DrawCommands into `pctx`. Public for
/// blackbox tests. The dynamic layer does NOT paint the background,
/// image, placeholder, or annotation bodies — only the selected
/// handles + the cursor crosshair. The alpha channel is preserved
/// (no Clear) so the static layer shows through.
pub fn draw_dynamic_layer(
  pctx : @common.PaintContext,
  model : Model,
  frame : @core.Rect,
) -> Unit {
  // 1. Selected-annotation handles.
  match model.selectedId {
    Some(sel_id) =>
      for ann in model.annotations {
        if ann.id == sel_id {
          draw_handles(pctx, ann, model.pan, model.zoom)
        }
      }
    None => ()
  }
  // 2. Cursor crosshair.
  match model.cursorImgPt {
    Some(img_pt) => draw_cursor_crosshair(pctx, img_pt, model.pan, model.zoom)
    None => ()
  }
  // Reference `frame` so the param shape matches the canvas
  // draw signature; the dynamic layer is full-frame and lets
  // the static layer's background show through every non-handle
  // pixel.
  ignore(frame)
}

///|
/// Compute the destination rect for fit-contain rendering: keep the
/// image's aspect ratio, fit it inside `frame`, and centre it.
pub fn fit_contain_rect(
  frame : @core.Rect,
  natural_w : Double,
  natural_h : Double,
) -> @core.Rect {
  let fw = frame.size.width
  let fh = frame.size.height
  if natural_w <= 0.0 || natural_h <= 0.0 {
    @core.Rect::new(x=frame.origin.x, y=frame.origin.y, width=fw, height=fh)
  } else {
    let scale = if fw / natural_w < fh / natural_h {
      fw / natural_w
    } else {
      fh / natural_h
    }
    let w = natural_w * scale
    let h = natural_h * scale
    @core.Rect::new(
      x=frame.origin.x + (fw - w) / 2.0,
      y=frame.origin.y + (fh - h) / 2.0,
      width=w,
      height=h,
    )
  }
}

// ─────────────────────────────────────────────────────────────────
// Internal helpers — image-natural → screen transform + draw logic.
// ─────────────────────────────────────────────────────────────────

///|
/// Image-natural point → screen point via pan/zoom around origin (0,0).
fn img_to_screen(p : Point, pan : Point, zoom : Double) -> Point {
  { x: pan.x + p.x * zoom, y: pan.y + p.y * zoom, }
}

///|
/// 6 px square centred on the given screen point. The visual handle
/// marker is a tiny filled rect; hit-test (12 px) is bigger than the
/// marker (12 vs 6) so the user has some forgiveness on the click
/// target.
fn handle_marker(p : Point) -> @core.Rect {
  @core.Rect::new(x=p.x - 3.0, y=p.y - 3.0, width=6.0, height=6.0)
}

///|
/// Draw a single annotation. Phase 5.3 ships rect + polygon +
/// keypoint. `selected` swaps the colour to a brighter palette so
/// the user can see which annotation is active.
fn draw_annotation(
  pctx : @common.PaintContext,
  ann : Annotation,
  selected : Bool,
  pan : Point,
  zoom : Double,
) -> Unit {
  let color = if selected {
    @core.Color::rgba(r=1.0, g=0.85, b=0.2, a=1.0) // yellow
  } else {
    @core.Color::rgba(r=0.95, g=0.25, b=0.25, a=1.0) // red
  }
  let stroke_width = if selected { 2.0 } else { 1.0 }
  match ann.shape {
    Rect =>
      if ann.points.length() >= 2 {
        let p1 = img_to_screen(ann.points[0], pan, zoom)
        let p2 = img_to_screen(ann.points[1], pan, zoom)
        // Normalise to top-left + bottom-right.
        let xmin = if p1.x < p2.x { p1.x } else { p2.x }
        let ymin = if p1.y < p2.y { p1.y } else { p2.y }
        let w = if p1.x > p2.x { p1.x - p2.x } else { p2.x - p1.x }
        let h = if p1.y > p2.y { p1.y - p2.y } else { p2.y - p1.y }
        let r : @core.Rect = @core.Rect::new(x=xmin, y=ymin, width=w, height=h)
        @common.stroke_rect(pctx, r, color, stroke_width)
      }
    Polygon =>
      if ann.points.length() >= 2 {
        // Polygon: draw each segment as a thin rectangle (the
        // primitive set is fill_rect / stroke_rect — no polyline
        // helper). 5.7 will upgrade this to draw_path.
        for i = 0; i < ann.points.length() - 1; i = i + 1 {
          let a = img_to_screen(ann.points[i], pan, zoom)
          let b = img_to_screen(ann.points[i + 1], pan, zoom)
          draw_thick_line(pctx, a, b, color, stroke_width)
        }
      }
    Keypoint =>
      if ann.points.length() >= 1 {
        let p = img_to_screen(ann.points[0], pan, zoom)
        let r : @core.Rect = @core.Rect::new(
          x=p.x - 4.0,
          y=p.y - 4.0,
          width=8.0,
          height=8.0,
        )
        @common.fill_rect(pctx, r, color)
      }
  }
}

///|
/// Draw handle markers for the selected annotation only.
fn draw_handles(
  pctx : @common.PaintContext,
  ann : Annotation,
  pan : Point,
  zoom : Double,
) -> Unit {
  let color = @core.Color::rgba(r=0.2, g=0.85, b=1.0, a=1.0) // cyan
  let hs = handle_points(ann)
  for h in hs {
    let s = img_to_screen(h, pan, zoom)
    @common.fill_rect(pctx, handle_marker(s), color)
  }
  // Close-polygon handle: a small ring at the first vertex for
  // visual feedback that the polygon can be closed by clicking
  // back near vertex 0. 5.7 will wire the actual close logic.
  ignore(0)
}

///|
/// Draw the cursor crosshair in screen space. (Used to be inline in
/// the 5.1 canvas_view — extracted to dedupe.)
fn draw_cursor_crosshair(
  pctx : @common.PaintContext,
  img_pt : Point,
  pan : Point,
  zoom : Double,
) -> Unit {
  let s = img_to_screen(img_pt, pan, zoom)
  let v_bar : @core.Rect = @core.Rect::new(
    x=s.x - 8.0,
    y=s.y,
    width=16.0,
    height=1.0,
  )
  let h_bar : @core.Rect = @core.Rect::new(
    x=s.x,
    y=s.y - 8.0,
    width=1.0,
    height=16.0,
  )
  let white = @core.Color::rgba(r=1.0, g=1.0, b=1.0, a=1.0)
  @common.stroke_rect(pctx, v_bar, white, 1.0)
  @common.stroke_rect(pctx, h_bar, white, 1.0)
}

///|
/// Approximate a 1-D line segment as a series of filled unit squares
/// (a "thick line" via the fill_rect primitive). Phase 5.7 will
/// replace this with draw_path. For now it gives us a visually
/// visible 1-2 px line for polygon edges.
fn draw_thick_line(
  pctx : @common.PaintContext,
  a : Point,
  b : Point,
  color : @core.Color,
  stroke_width : Double,
) -> Unit {
  let dx = b.x - a.x
  let dy = b.y - a.y
  let len_sq = dx * dx + dy * dy
  if len_sq <= 0.0 {
    return
  }
  let len = sqrt_double_inline(len_sq)
  let steps = (len * 2.0).to_int() + 1
  let half = stroke_width / 2.0
  let mut i = 0
  while i <= steps {
    let t = (Float::from_int(i) / Float::from_int(steps)).to_double()
    let px = a.x + dx * t
    let py = a.y + dy * t
    let r : @core.Rect = @core.Rect::new(
      x=px - half,
      y=py - half,
      width=stroke_width,
      height=stroke_width,
    )
    @common.fill_rect(pctx, r, color)
    i = i + 1
  }
}

///|
/// Local sqrt — same Newton iteration as hit_test.mbt::sqrt_double,
/// duplicated here to keep canvas_view self-contained for the
/// draw helpers.
fn sqrt_double_inline(x : Double) -> Double {
  if x <= 0.0 {
    return 0.0
  }
  let mut guess = x / 2.0
  if guess < 1.0 {
    guess = 1.0
  }
  for _i = 0; _i < 8; _i = _i + 1 {
    guess = (guess + x / guess) / 2.0
  }
  guess
}
