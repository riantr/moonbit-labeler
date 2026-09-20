// app_moui/canvas_view.mbt — annotation canvas as MoUI view.
//
// Phase 5.5.x (this session): real paint caching for the static
// layer. Replace the 5.5 plain `views.canvas` static sub-view with a
// custom ViewNode (`CachedStaticLayerView`) whose `paint()` returns
// a `ViewPaintPlan` whose `commands` is empty and `child_layers`
// carries one `ViewPaintLayer` with a stable `cache_key` derived
// from `imageSource + annotations + pan + zoom`. MoUI's
// `paint_engine.mbt:62-65` walks `plan.child_layers` and emits a
// `RenderNode{is_repaint_boundary: true, layer_cache_key: Some(...)}`,
// which `render_tree.mbt:41-58` wraps in `BeginRetainedLayer` /
// `EndRetainedLayer` automatically. When only the dynamic layer
// changes (cursor move / drag) the runtime can reuse the cached
// GPU/CPU bitmap from the previous frame instead of repainting the
// entire background + image + every annotation.
//
// The dynamic layer stays as a plain `views.canvas` because its
// content (selected handles + cursor crosshair) is cheap and
// changes every cursor frame.
//
// Phase 5.5 (prior session): split the single canvas into two
// stacked canvas sub-views (static + dynamic) via `@layout.stack`.
// Layer separation at the API surface; the runtime repainted both
// every frame because both used `views.canvas` (which hardcodes
// `paint=Uncacheable`). 5.5.x replaces the static sub-view with
// a cached custom ViewNode to actually realise the perf win.
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
// Phase 5.5.x does NOT port:
//   - image-header probe (caller passes natural size; 5.5.x keeps the
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
/// The static sub-view is a `CachedStaticLayerView` custom node
/// (5.5.x) that emits its commands inside a `ViewPaintLayer` with a
/// stable `cache_key`, so MoUI's render pipeline wraps them in
/// `BeginRetainedLayer` / `EndRetainedLayer` and the GPU/CPU
/// renderer can skip repainting when only the dynamic layer
/// changed.
///
/// `on_drag` is attached to the OUTER view so pointer events on
/// either sub-view funnel through one handler. The canvas-view model
/// state mutation is still single-source-of-truth (`model.cursorImgPt`,
/// `model.selectedId`, etc.), so there's no risk of the two layers
/// disagreeing about what's selected.
pub fn canvas_view(model : Model) -> @moui.View[Msg] {
  let static_layer = cached_static_layer_view(model)
  let dynamic_layer = dynamic_layer_view(model)
  let stacked = @layout.stack([static_layer, dynamic_layer])
  // Phase 5.11 — pan via drag. DragGestureEvent.delta carries
  // the per-step screen-space movement; we accumulate it into
  // model.pan (independent of the cursor hit-test dispatch
  // below). This makes every drag also pan the image — the
  // standard canvas-view convention for desktop image
  // viewers. CursorMoved keeps being dispatched for hit-test
  // + handle-drag, with the (updated) pan/zoom applied to
  // invert the cursor position back to image-natural coords.
  //
  // We don't dispatch a separate `Pan(ev.delta)` Msg here —
  // the pan mutation is a side effect of the drag (the user
  // doesn't expect a "pan tool" mode; pan is always-on). The
  // CursorMoved handler in app.mbt reads `model.pan` and
  // recomputes `cursorImgPt` accordingly.
  let after_pan_drag : @moui.View[Msg] = stacked.on_drag(fn(ev) {
    // Marshal @core.Point → app's local Point (same fields, but
    // distinct types in MoonBit's structural type system).
    Pan({ x: ev.delta.x, y: ev.delta.y, })
  })
  let after_cursor_drag : @moui.View[Msg] = after_pan_drag.on_drag(fn(ev) {
    CursorMoved(
      {
        x: (ev.position.x - model.pan.x) / model.zoom,
        y: (ev.position.y - model.pan.y) / model.zoom,
      },
      { x: ev.position.x, y: ev.position.y, },
    )
  })
  // Phase 5.11 — secondary-tap (right-click) resets zoom +
  // pan to defaults (zoom=1.0, pan=(0,0)). The canvas viewer
  // re-centres on the natural-size image. Matches the
  // expected "right-click to reset view" desktop convention.
  // Double-tap (primary button) does the same — gives touch
  // users a way to reset without a right-click.
  let after_secondary : @moui.View[Msg] = after_cursor_drag.on_secondary_tap(
    ResetZoomTransformView,
  )
  // Phase 5.11 — bind the final view (returned by on_double_tap)
  // so it actually flows out of the function. Renaming away from
  // `_view` (which MoonBit's type checker treats as a discard
  // even with an explicit type annotation, yielding "has type
  // Unit" on the RHS) makes the result reachable.
  let final_view : @moui.View[Msg] = after_secondary.on_double_tap(
    ResetZoomTransformView,
  )
  final_view
}

///|
/// Static layer canvas: background + image (or placeholder) +
/// annotations, wrapped in a `ViewPaintLayer` with a stable
/// `cache_key` so the runtime can reuse the rendered bitmap
/// across frames when nothing in the cache key changed.
///
/// `cache_key` is derived from the model fields that affect the
/// static layer's appearance: image source path, the sorted
/// annotation set (id + shape + points + selected colour), pan
/// offset, and zoom. When any of these change, the key changes
/// and the runtime invalidates the cached layer (forcing a
/// repaint). Otherwise the cached bitmap is reused and only the
/// dynamic layer (handles + crosshair) repaints.
fn cached_static_layer_view(model : Model) -> @moui.View[Msg] {
  @core.View::from_node(CachedStaticLayerView::{ model, })
}

///|
/// The custom ViewNode for the cached static layer. Holds a
/// snapshot of the relevant model fields and the previous
/// cache_key so we can detect "cache invalidation" (key changed)
/// vs "cache hit" (key unchanged) without comparing the whole
/// model.
priv struct CachedStaticLayerView {
  model : Model
}

///|
impl @core.ViewNode for CachedStaticLayerView with fn identity(_self) {
  @core.ViewIdentity::new(kind="CachedStaticLayer")
}

///|
impl @core.ViewNode for CachedStaticLayerView with fn declaration(_self) {
  // Static layer should be cacheable when its key is stable. The
  // runtime uses `paint` channel to decide whether to reuse
  // cached paint output; declaring it Constant makes the runtime
  // consider it cacheable (the actual cache key comes from the
  // ViewPaintLayer's cache_key field, not the declaration).
  // The dynamic layer below still declares Uncacheable so cursor
  // motion forces a repaint.
  @core.ViewDeclaration::constant()
}

///|
impl @core.ViewNode for CachedStaticLayerView with fn layout(_self, ctx) {
  @core.ViewLayoutResult::new(size=ctx.constraints.max)
}

///|
impl @core.ViewNode for CachedStaticLayerView with fn paint(self, ctx) {
  let model = self.model
  let frame = ctx.frame
  // Collect the static layer's DrawCommands into a fresh
  // PaintContext. We don't actually call the public draw_static_layer
  // helper here because we want to package the commands inside a
  // ViewPaintLayer (not push them at the top of the parent
  // command stream — that would bypass the cache key).
  let pctx = @common.PaintContext::new()
  issue_static_commands(pctx, model, frame)
  let commands : Array[@core.DrawCommand] = @common.PaintContext::finish(pctx)
  // Derive a stable cache_key from model state. Any change to
  // these fields MUST change the key so the runtime invalidates
  // the cached layer and repaints.
  let key = static_cache_key(model)
  // content_revision is monotonic; we bump it whenever the key
  // changes so the runtime's cache lookup uses fresh state. We
  // derive a simple stable revision from the key hash for now —
  // proper integer revision tracking is a follow-up (the runtime
  // only checks (key, content_revision) pair equality for cache
  // hits, so two revisions of the same content are equivalent
  // here).
  let revision = static_cache_revision(model)
  {
    commands: [],
    child_layers: [
      @core.ViewPaintLayer::new(
        frame~,
        cache_key=key,
        content_revision=revision,
        commands~,
      ),
    ],
    post_commands: [],
    overlay_commands: [],
    repaint_boundary: true,
    animating: false,
  }
}

///|
impl @core.ViewNode for CachedStaticLayerView with fn semantics(_self) {
  @core.ViewSemanticsInfo::new(
    composition=@core.SemanticsComposition::Transparent,
  )
}

///|
/// Dynamic layer canvas: selected-annotation handles + cursor
/// crosshair. Conceptually the "overlay" that repaints on every
/// cursor move / drag frame. Sits on top of the static layer via
/// `@layout.stack`.
///
/// The dynamic layer stays a plain `views.canvas` because its
/// content (handles + crosshair) is cheap and changes every cursor
/// frame — caching would just add overhead without saving work.
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
/// Compute the cache key for the static layer. The key must change
/// iff any model field that affects the static layer's appearance
/// changes. Public for blackbox tests (5.5.x layer-split tests
/// verify the key changes with each input axis independently).
pub fn static_cache_key(model : Model) -> String {
  // Format: "static|<imageSource>|<annotations_fingerprint>|<pan.x>,<pan.y>|<zoom>|<natural_w>x<natural_h>|<fit>"
  let mut s = "static|"
  s = s + model.imageSource
  s = s + "|"
  s = s +
    annotations_fingerprint(model.annotations, model.classes, model.selectedId)
  s = s + "|"
  s = s + model.pan.x.to_string()
  s = s + ","
  s = s + model.pan.y.to_string()
  s = s + "|"
  s = s + model.zoom.to_string()
  s = s + "|"
  s = s + model.imageNaturalSize.x.to_string()
  s = s + "x"
  s = s + model.imageNaturalSize.y.to_string()
  s = s + "|"
  // ImageFit enum doesn't have Debug derive here; use its show
  // via Debug if available, else a sentinel string. We use the
  // tag name through Show for stability.
  s = s + fit_mode_tag(model.fitMode)
  s
}

///|
/// Compute the content revision for the static layer cache. Used
/// as the second half of the (key, revision) pair that the
/// runtime's render-tree cache lookup compares. Today this is a
/// simple per-model derived integer; follow-up could track a
/// real monotonic counter bumped by every LabelLoaded / SetMode
/// / ModifyHandle handler in update().
pub fn static_cache_revision(_model : Model) -> Int {
  // 0 is a fine sentinel — runtime treats (key, rev) pairs
  // identically when both key and rev match. Bumping this is
  // only needed if the same logical content could be re-rendered
  // with an outdated cache for some reason; right now we trust
  // the cache_key to fully describe content identity.
  0
}

///|
/// Stable per-fit-mode tag for the cache key. Mirrors MoUI's
/// `@core.ImageFit::Contain / Cover / Stretch` constructor names
/// (the enum has no Debug/Show derive available in the public
/// surface we touch).
fn fit_mode_tag(fit : @core.ImageFit) -> String {
  match fit {
    @core.ImageFit::Contain => "Contain"
    @core.ImageFit::Cover => "Cover"
    @core.ImageFit::Stretch => "Stretch"
    @core.ImageFit::ScaleDown => "ScaleDown"
    @core.ImageFit::FitWidth => "FitWidth"
    @core.ImageFit::FitHeight => "FitHeight"
  }
}

///|
/// A short stable fingerprint of the annotation set + which one
/// is selected. Used inside the static-layer cache key so that
/// editing an annotation point invalidates the cache. Format:
///   "<n>|<id1>:<shape1>:<p1.x>,<p1.y>|<p2.x>,<p2.y>|...;<sel_id?>"
///
/// The order matches the iteration order in draw_static_layer so
/// two models with identical annotations in the same order produce
/// the same fingerprint.
fn annotations_fingerprint(
  anns : Array[Annotation],
  classes : Array[ClassEntry],
  selected : String?,
) -> String {
  let mut s = anns.length().to_string()
  s = s + "|"
  for ann in anns {
    s = s + ann.id
    s = s + ":"
    s = s + shape_tag(ann.shape)
    s = s + ":"
    // Phase 5.14 — include the resolved class_name in the
    // fingerprint. This way, renaming a class in
    // model.classes (same class_id, different name) invalidates
    // the cached static bitmap and the next paint rebuilds
    // the label text. Without this, class renames would be
    // invisible until the user pans/zooms (which independently
    // invalidates the cache).
    s = s + class_lookup_name(ann, classes)
    s = s + ":"
    for p in ann.points {
      s = s + p.x.to_string()
      s = s + ","
      s = s + p.y.to_string()
      s = s + ";"
    }
    s = s + "|"
  }
  let selected_tag : String = match selected {
    Some(id) => id
    None => "_"
  }
  s = s + selected_tag
  s
}

///|
/// Stable shape tag (Rect / Polygon / Keypoint) for the
/// fingerprint.
fn shape_tag(shape : Shape) -> String {
  match shape {
    Rect => "Rect"
    Polygon => "Polygon"
    Keypoint => "Keypoint"
  }
}

///|
/// Issue the static layer's DrawCommands into `pctx`. Internal
/// helper used by `CachedStaticLayerView::paint` (so the commands
/// land inside a `ViewPaintLayer`) AND exposed publicly via
/// `draw_static_layer` for the 5.5 layer-split tests (which drive
/// the canvas view's draw callback directly to verify the
/// non-cached layer-split behaviour).
fn issue_static_commands(
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
    draw_annotation(pctx, ann, is_sel, model.pan, model.zoom, model.classes)
  }
  // 4. Bindings (from → to arrows). Phase 5.9. Drawn after the
  // annotations so the arrow heads sit on top of the connected
  // shapes; canvas.js does the same. Each binding is a
  // dashed-centroid-to-centroid line + a small filled triangle
  // arrow head pointing at the `to` annotation.
  draw_bindings(pctx, model, model.pan, model.zoom)
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
  issue_static_commands(pctx, model, frame)
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
  // 2. Phase 5.12.C — in-progress draft (polygon fill+stroke,
  // rect fill+stroke). Drawn after handles so the user's
  // in-progress shape covers the static annotation layer where
  // they overlap. Skipped if mode is Select / EditBinding /
  // Keypoint (none of those accumulate draftPoints in a way the
  // user expects a preview for — Keypoint draws one point at a
  // time and the click-to-place feedback is the cursor crosshair
  // alone).
  match model.mode {
    Polygon =>
      if model.draftPoints.length() > 0 {
        draw_draft_polygon(pctx, model.draftPoints, model.pan, model.zoom)
      }
    Rect =>
      if model.draftPoints.length() == 2 {
        draw_draft_rect(pctx, model.draftPoints, model.pan, model.zoom)
      }
    _ => ()
  }
  // 3. Phase 5.12.C — binding-from ring (10 px circle outline at
  // the source centroid while the user is in EditBinding mode
  // and has picked the source). Drawn after draft so the ring
  // overlays any draft state cleanly.
  draw_binding_from_marker(pctx, model, model.pan, model.zoom)
  // 4. Cursor crosshair.
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
/// `pub` because 5.12.A's view_math round-trip test wants to call it
/// directly from a separate test file; `fn`-level visibility doesn't
/// carry across `_test.mbt` blackbox boundaries.
pub fn img_to_screen(p : Point, pan : Point, zoom : Double) -> Point {
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
/// the user can see which annotation is active. `classes` is the
/// model.classes array; passed through to draw_label_text for
/// class-name lookup (Phase 5.14).
fn draw_annotation(
  pctx : @common.PaintContext,
  ann : Annotation,
  selected : Bool,
  pan : Point,
  zoom : Double,
  classes : Array[ClassEntry],
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
        // Phase 5.12.B: visual completeness — fill the rect
        // with a low-alpha tint of the same colour (0.12 matches
        // canvas.js drawRectShape line 330) before stroking. This
        // gives the user a sense of which area the box covers
        // without obscuring the underlying image.
        let fill_color : @core.Color = @core.Color::rgba(
          r=color.r,
          g=color.g,
          b=color.b,
          a=0.12,
        )
        @common.fill_rect(pctx, r, fill_color)
        @common.stroke_rect(pctx, r, color, stroke_width)
      }
    Polygon =>
      if ann.points.length() >= 2 {
        // Phase 5.12.B: fill the polygon with a low-alpha tint
        // of the colour (0.18 matches canvas.js drawPolygonShape
        // line 302) before the stroke pass. We re-emit the same
        // MoveTo + LineTo + Close verbs as a separate DrawPath
        // with fill=Some(...) and stroke=None — the renderer
        // composites fill under stroke so the result is identical
        // to canvas.js's `fill()` then `stroke()` sequence.
        draw_polygon_fill(pctx, ann, color, pan, zoom)
        // Phase 5.7: replace the 5.3 fill_rect-segment
        // approximation with a single `DrawPath(PathSpec)`
        // command that describes the polyline as one
        // MoveTo + N LineTo + Close sequence. The Skia
        // (or whichever backend) renderer walks the verbs
        // to draw the stroke in one pass, with proper line
        // joins and caps — which is what the user actually
        // expects visually (the 5.3 approximation rendered
        // each segment as a discrete 1-px square which
        // looked chunky at zoom > 2× and on dpr > 1).
        draw_polygon_path(pctx, ann, color, stroke_width, pan, zoom)
        // Phase 5.12.B: small white-stroked vertex dots at each
        // polygon vertex (skip for high-vertex-count polygons to
        // keep the static layer cheap — same threshold as canvas.js
        // line 309). Drawn in screen space so the dot radius
        // stays constant under pan/zoom.
        if ann.points.length() <= 30 {
          draw_polygon_vertex_dots(pctx, ann, color, pan, zoom)
        }
      }
    Keypoint =>
      if ann.points.length() >= 1 {
        // Phase 5.12.B: bump diameter from 8 px (radius=4) to 12 px
        // (radius=6) to match canvas.js's normal keypoint
        // (canvas.js:339 — `arc(x, y, isSelected ? 8 : 6, ...)`).
        // 5.8's radius=4 was already a circle (FillRoundedRect with
        // radius = half-side), so this is just a size bump plus a
        // white outline to match canvas.js's `strokeStyle="#ffffff"`.
        let p : Point = img_to_screen(ann.points[0], pan, zoom)
        let r : @core.Rect = @core.Rect::new(
          x=p.x - 6.0,
          y=p.y - 6.0,
          width=12.0,
          height=12.0,
        )
        let rr : @core.RoundedRect = @core.RoundedRect::new(rect=r, radius=6.0)
        @common.fill_rounded_rect(pctx, rr, @core.Brush::solid(color))
        // White outline via stroke_rounded_rect — same RoundedRect
        // spec, separate pass. Skia composites stroke on top of
        // the fill so the visual matches canvas.js's
        // fill-then-stroke order.
        let white : @core.Color = @core.Color::rgba(r=1.0, g=1.0, b=1.0, a=1.0)
        @common.stroke_rounded_rect(pctx, rr, @core.Brush::solid(white), 2.0)
      }
  }
  // Phase 5.13 — emit a label-text DrawCommand at the centroid
  // for every annotation (matches canvas.js drawLabelText
  // line 562 — labels live on the static layer and re-cache
  // alongside the annotation body via the 5.5.x cache key).
  // Text content is `ann.id` for now; a future 5.14+ commits
  // class-id plumbing so we can render the class name
  // (canvas.js uses `a.type` which is the class name).
  // Phase 5.13 + 5.14 — emit the label text. 5.13 used
  // `ann.id`; 5.14 upgrades to the class name looked up from
  // `classes` via `ann.class_id`. Falls back to `ann.id` when
  // the class_id is unset ("") or doesn't resolve (orphan id,
  // deleted class). Skipped entirely when `ann.id == ""`
  // (mid-construction annotations).
  if ann.id != "" {
    let label : String = class_lookup_name(ann, classes)
    let centroid_screen : Point = img_to_screen(
      binding_centroid(ann),
      pan,
      zoom,
    )
    draw_label_text(pctx, label, centroid_screen, color)
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
/// Phase 5.9 — draw all binding arrows. For each binding in
/// `model.bindings`, look up the `from` and `to` annotations by
/// id, compute their centroids in screen space, and emit a
/// `DrawPath` line from `from` → `to` plus a filled-triangle
/// arrow head at the `to` end.
///
/// Bindings whose `from` or `to` annotation is missing (e.g.
/// the user deleted an annotation but the binding still
/// references it) are silently skipped — same behaviour as
/// `frontend/src/canvas.js:548-552`.
fn draw_bindings(
  pctx : @common.PaintContext,
  model : Model,
  pan : Point,
  zoom : Double,
) -> Unit {
  // Build an id → annotation lookup once (O(N) build, then
  // O(1) per binding lookup).
  let by_id : Map[String, Annotation] = Map::new()
  for ann in model.annotations {
    by_id.set(ann.id, ann)
  }
  for b in model.bindings {
    let from_opt : Annotation? = by_id.get(b.from)
    let to_opt : Annotation? = by_id.get(b.to)
    match (from_opt, to_opt) {
      (Some(from), Some(to)) => draw_binding_arrow(pctx, from, to, pan, zoom)
      _ => ()
    }
  }
}

///|
/// Phase 5.9 + 5.17 — emit the dashed line + arrow head for a
/// single binding.
///
/// Phase 5.17 adds the dashed pattern (canvas.js line 357 uses
/// `c.setLineDash([6, 4])`). Moui 0.1.12's PathSpec doesn't
/// expose a dash spec, so we approximate via segment emission:
/// walk the from → to line in 10 px periods (6 px dash + 4 px
/// gap), emitting one MoveTo + LineTo DrawPath per dash. The
/// arrow head stays solid (canvas.js does the same).
///
/// Arrow head is 8 px long; the line is shortened by 8 px so
/// the arrow head's tip coincides with the original `to_pt`
/// rather than overlapping the line endpoint.
fn draw_binding_arrow(
  pctx : @common.PaintContext,
  from : Annotation,
  to : Annotation,
  pan : Point,
  zoom : Double,
) -> Unit {
  let from_pt : Point = img_to_screen(binding_centroid(from), pan, zoom)
  let to_pt : Point = img_to_screen(binding_centroid(to), pan, zoom)
  // Same yellow as canvas.js's "#fbbf24" (a 3-bit web color).
  let color : @core.Color = @core.Color::rgba(r=0.984, g=0.749, b=0.141, a=1.0)
  let head_len : Double = 8.0
  let dx : Double = to_pt.x - from_pt.x
  let dy : Double = to_pt.y - from_pt.y
  let len_sq : Double = dx * dx + dy * dy
  if len_sq <= 0.001 {
    return
  }
  let len : Double = sqrt_inline(len_sq)
  // 1. Dashed line from `from_pt` to `end_pt` (end_pt is the
  // arrow-head base; the line stops there so the head doesn't
  // overlap the last dash). Each period = 6 px dash + 4 px gap
  // = 10 px. We walk from from_pt forward in 10 px steps
  // until we'd exceed end_pt.
  let end_pt : Point = {
    x: to_pt.x - dx / len * head_len,
    y: to_pt.y - dy / len * head_len,
  }
  let ux : Double = dx / len
  let uy : Double = dy / len
  let dash_len : Double = 6.0
  let gap_len : Double = 4.0
  let period : Double = dash_len + gap_len
  // Effective line length (from_pt → end_pt) in screen pixels.
  let line_len : Double = len - head_len
  if line_len <= 0.0 {
    // Too short for dashes; fall through to the arrow head.
    // (No dashes drawn — visually almost identical to
    // canvas.js's behaviour when the endpoints coincide.)
  } else {
    // Compute how many full periods fit in line_len and emit
    // one MoveTo+LineTo per dash. The last dash is trimmed so
    // it doesn't extend past end_pt.
    let mut s : Double = 0.0
    while s < line_len {
      let dash_end : Double = if s + dash_len < line_len {
        s + dash_len
      } else {
        line_len
      }
      let dash_start_pt : Point = {
        x: from_pt.x + ux * s,
        y: from_pt.y + uy * s,
      }
      let dash_end_pt : Point = {
        x: from_pt.x + ux * dash_end,
        y: from_pt.y + uy * dash_end,
      }
      let verbs : Array[@core.PathVerb] = [
        @core.PathVerb::MoveTo({ x: dash_start_pt.x, y: dash_start_pt.y, }),
        @core.PathVerb::LineTo({ x: dash_end_pt.x, y: dash_end_pt.y, }),
      ]
      let path : @core.PathSpec = @core.PathSpec::new(
        verbs~,
        fill=None,
        stroke=Some(@core.Brush::solid(color)),
        stroke_width=1.5,
      )
      @common.draw_path(pctx, path)
      s = s + period
    }
  }
  ignore(from_pt)
  // 2. Arrow head: 3-vertex filled triangle pointing at `to_pt`.
  // Perpendicular unit vector for the base:
  let px : Double = -uy
  let py : Double = ux
  let base_centre : Point = {
    x: to_pt.x - ux * head_len,
    y: to_pt.y - uy * head_len,
  }
  let half_w : Double = 3.0 // half-width of the arrow head base
  let b1 : Point = {
    x: base_centre.x + px * half_w,
    y: base_centre.y + py * half_w,
  }
  let b2 : Point = {
    x: base_centre.x - px * half_w,
    y: base_centre.y - py * half_w,
  }
  let arrow_verbs : Array[@core.PathVerb] = [
    @core.PathVerb::MoveTo({ x: to_pt.x, y: to_pt.y, }),
    @core.PathVerb::LineTo({ x: b1.x, y: b1.y, }),
    @core.PathVerb::LineTo({ x: b2.x, y: b2.y, }),
    @core.PathVerb::Close,
  ]
  let arrow_path : @core.PathSpec = @core.PathSpec::new(
    verbs=arrow_verbs,
    fill=Some(@core.Brush::solid(color)),
    stroke=None,
    stroke_width=0.0,
  )
  @common.draw_path(pctx, arrow_path)
}

///|
/// Phase 5.9 — centroid of an annotation in image-natural
/// pixels. Matches `frontend/src/canvas.js:55` (centroid of
/// the points array). For Rect we average the two corner
/// points; for Polygon we average all vertices; for
/// Keypoint the single point is its own centroid.
pub fn binding_centroid(ann : Annotation) -> Point {
  let n : Int = ann.points.length()
  if n == 0 {
    return { x: 0.0, y: 0.0, }
  }
  let mut sx : Double = 0.0
  let mut sy : Double = 0.0
  for p in ann.points {
    sx = sx + p.x
    sy = sy + p.y
  }
  { x: sx / n.to_double(), y: sy / n.to_double(), }
}

///|
/// Local sqrt for vector length math. Same Newton iteration
/// pattern as the 5.3 hit_test.mbt helper, but inlined here
/// to keep canvas_view self-contained (draw_binding_arrow
/// was the last caller that needed this).
fn sqrt_inline(x : Double) -> Double {
  if x <= 0.0 {
    return 0.0
  }
  let mut guess : Double = x / 2.0
  if guess < 1.0 {
    guess = 1.0
  }
  for _i = 0; _i < 8; _i = _i + 1 {
    guess = (guess + x / guess) / 2.0
  }
  guess
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
/// Phase 5.14 — look up the class name for an annotation's
/// `class_id` field, falling back to `ann.id` when the class
/// is unset (empty string) or doesn't resolve (orphan id).
///
/// Mirrors canvas.js's implicit class-name lookup: canvas.js
/// reads `a.type` (which is the class *name*, not id) from
/// the JSON label file directly. We have an extra layer of
/// indirection (class_id → class_name via model.classes) so
/// that class renames don't have to rewrite every annotation.
///
/// Returns the class name if `ann.class_id` matches a
/// ClassEntry.id in `classes`; otherwise `ann.id`. The fallback
/// to `ann.id` (not the empty string) is important for the
/// orphan case — we still want the user to see *something*
/// identifying this annotation even if its class record is
/// gone, and the id is the most useful identifier we have.
///
/// Empty `ann.id` is handled by the caller (`draw_annotation`
/// guards on `ann.id != ""` before calling).
pub fn class_lookup_name(
  ann : Annotation,
  classes : Array[ClassEntry],
) -> String {
  if ann.class_id == "" {
    return ann.id
  }
  for c in classes {
    if c.id == ann.class_id {
      return c.name
    }
  }
  // Orphan class_id (no matching ClassEntry). Fall back to id
  // so the user sees something identifying.
  ann.id
}

///|
/// Phase 5.13 — emit a label-text DrawCommand at the given
/// screen-space centroid. Used by `draw_annotation` to overlay
/// the class name (5.14 lookup) on top of every annotation body
/// so the user can read which one is which without clicking.
///
/// Visual spec mirrors canvas.js drawLabelText (lines 404-413):
///   - font: 12 px system-ui sans-serif
///   - alignment: TextCenter (canvas.js uses ctx.textAlign =
///     "center")
///   - position: cy - 8 (text baseline sits 8 px above the
///     centroid so the label reads inside the annotation body
///     instead of overlapping the bottom edge)
///   - color: same colour as the annotation body
///
/// MoUI's TextRun doesn't expose a stroke pass, so we omit
/// the canvas.js black-halo (`strokeText`) for now. The label
/// will be slightly harder to read on dark images, but the
/// 12 px sans-serif weight keeps it legible on most natural
/// images. A halo pass can land in a later 5.x batch if the
/// readability gap matters.
///
/// `centroid_screen` is the screen-space point the label
/// centres on — typically `img_to_screen(binding_centroid(ann),
/// pan, zoom)`.
fn draw_label_text(
  pctx : @common.PaintContext,
  text : String,
  centroid_screen : Point,
  color : @core.Color,
) -> Unit {
  let font : @core.FontSpec = @core.FontSpec::new(
    families=@core.FontFamilyStack::system_ui(),
    size=12.0,
  )
  // Frame: 200 × 20 wide enough for typical annotation ids
  // ("ann-1", "ann-23" etc. easily fit; long ids get clipped
  // by the frame but that's a graceful degradation, not a
  // crash). The frame's top-left is offset so TextCenter
  // places the text at the desired baseline (centroid y - 8,
  // matching canvas.js's `cy - 8` lift).
  let frame : @core.Rect = @core.Rect::new(
    x=centroid_screen.x - 100.0,
    y=centroid_screen.y - 18.0,
    width=200.0,
    height=20.0,
  )
  let text_run : @core.TextRun = @core.TextRun::new(
    text~,
    frame~,
    font~,
    color~,
    align=@core.TextAlign::TextCenter,
  )
  @common.draw_text(pctx, text_run)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.12.C — draft rendering + binding-from marker
// ─────────────────────────────────────────────────────────────────
//
// Drawn on the dynamic layer (not cached) because the user is
// actively mutating `model.draftPoints` / `model.bindingFromId`
// on every mouse move while a shape is being drawn or a binding
// is being placed. Caching this would defeat the purpose.
//
// `color` is the draft/binding accent color (matches the legacy
// canvas.js "#fbbf24" — a 3-bit web yellow). The same colour is
// used for draft-polygon, draft-rect, and binding-from circle
// so users learn one cue for "in-progress state".

///|
/// Phase 5.12.C — draft polygon rendering. When the user is in
/// Polygon mode and has clicked N >= 3 points, this draws the
/// in-progress polygon with a translucent fill (alpha 0.15,
/// matching canvas.js drawDraftPolygon line 366) plus the
/// polyline outline + small white-stroked vertex dots.
///
/// `points` is `model.draftPoints` (image-natural coords); we
/// convert to screen once per vertex via `img_to_screen`.
fn draw_draft_polygon(
  pctx : @common.PaintContext,
  points : Array[Point],
  pan : Point,
  zoom : Double,
) -> Unit {
  if points.length() == 0 {
    return
  }
  // Same yellow as canvas.js's "#fbbf24" draft accent.
  let color : @core.Color = @core.Color::rgba(r=0.984, g=0.749, b=0.141, a=1.0)
  let white : @core.Color = @core.Color::rgba(r=1.0, g=1.0, b=1.0, a=1.0)
  // Build the verb sequence once for both fill (when N >= 3)
  // and stroke (always when N >= 2).
  let verbs : Array[@core.PathVerb] = []
  let p0 : Point = img_to_screen(points[0], pan, zoom)
  verbs.push(@core.PathVerb::MoveTo({ x: p0.x, y: p0.y, }))
  for i = 1; i < points.length(); i = i + 1 {
    let p : Point = img_to_screen(points[i], pan, zoom)
    verbs.push(@core.PathVerb::LineTo({ x: p.x, y: p.y, }))
  }
  // Close the polyline so fill() reaches back to vertex 0.
  verbs.push(@core.PathVerb::Close)
  // Fill pass — only when the polygon has at least 3 vertices
  // (a 2-vertex polygon is just a line; fill would render as a
  // degenerate triangle of zero area).
  if points.length() >= 3 {
    let fill_color : @core.Color = @core.Color::rgba(
      r=color.r,
      g=color.g,
      b=color.b,
      a=0.15,
    )
    let fill_path : @core.PathSpec = @core.PathSpec::new(
      verbs~,
      fill=Some(@core.Brush::solid(fill_color)),
      stroke=None,
      stroke_width=1.0,
    )
    @common.draw_path(pctx, fill_path)
  }
  // Stroke pass — always when N >= 2 (a 1-point "polygon" is
  // just a single vertex with no shape).
  if points.length() >= 2 {
    let stroke_path : @core.PathSpec = @core.PathSpec::new(
      verbs~,
      fill=None,
      stroke=Some(@core.Brush::solid(color)),
      stroke_width=2.0,
    )
    @common.draw_path(pctx, stroke_path)
  }
  // Vertex dots — small fill + white outline at each vertex in
  // screen space (constant 8 px diameter so they're readable at
  // any zoom). Matches canvas.js drawDraftPolygon lines
  // 379-387.
  for nat_pt in points {
    let p : Point = img_to_screen(nat_pt, pan, zoom)
    let r : @core.Rect = @core.Rect::new(
      x=p.x - 4.0,
      y=p.y - 4.0,
      width=8.0,
      height=8.0,
    )
    let rr : @core.RoundedRect = @core.RoundedRect::new(rect=r, radius=4.0)
    @common.fill_rounded_rect(pctx, rr, @core.Brush::solid(color))
    @common.stroke_rounded_rect(pctx, rr, @core.Brush::solid(white), 1.5)
  }
}

///|
/// Phase 5.12.C — draft rect rendering. The user is in Rect
/// mode and has clicked 2 points (top-left + bottom-right).
/// We fill the rect (alpha 0.15, matching canvas.js
/// drawDraftRect line 395) and stroke the outline.
///
/// `points` is `model.draftPoints` — exactly 2 entries
/// (top-left + bottom-right) when the caller dispatches. The
/// function guards against N != 2 anyway so a malformed
/// caller doesn't render garbage.
fn draw_draft_rect(
  pctx : @common.PaintContext,
  points : Array[Point],
  pan : Point,
  zoom : Double,
) -> Unit {
  if points.length() != 2 {
    return
  }
  let color : @core.Color = @core.Color::rgba(r=0.984, g=0.749, b=0.141, a=1.0)
  let p1 : Point = img_to_screen(points[0], pan, zoom)
  let p2 : Point = img_to_screen(points[1], pan, zoom)
  let xmin = if p1.x < p2.x { p1.x } else { p2.x }
  let ymin = if p1.y < p2.y { p1.y } else { p2.y }
  let w = if p1.x > p2.x { p1.x - p2.x } else { p2.x - p1.x }
  let h = if p1.y > p2.y { p1.y - p2.y } else { p2.y - p1.y }
  let r : @core.Rect = @core.Rect::new(x=xmin, y=ymin, width=w, height=h)
  let fill_color : @core.Color = @core.Color::rgba(
    r=color.r,
    g=color.g,
    b=color.b,
    a=0.15,
  )
  @common.fill_rect(pctx, r, fill_color)
  @common.stroke_rect(pctx, r, color, 2.0)
}

///|
/// Phase 5.12.C — binding-from highlight. While the user is in
/// EditBinding mode and has clicked the source annotation
/// (`model.bindingFromId == Some(ann_id)`), this draws a 10 px
/// yellow ring at the source's centroid so they have a clear
/// visual target for "click the destination next".
///
/// Matches canvas.js paintDynamic lines 574-583: a 10 px
/// radius unfilled circle (lineWidth 2, strokeStyle "#fbbf24")
/// at the source annotation's centroid.
///
/// Looks up the source annotation from `model.annotations` by
/// id; silently skips if the id no longer resolves (e.g. the
/// user deleted the source annotation mid-binding — same
/// graceful-skip policy as 5.9's draw_bindings).
fn draw_binding_from_marker(
  pctx : @common.PaintContext,
  model : Model,
  pan : Point,
  zoom : Double,
) -> Unit {
  let color : @core.Color = @core.Color::rgba(r=0.984, g=0.749, b=0.141, a=1.0)
  // Early-return pattern: assign the id with `let id = match`
  // returns, then continue. MoonBit doesn't allow `return`
  // inside a match arm that lives inside an expression position.
  let from_id : String? = model.bindingFromId
  match from_id {
    None => ()
    Some(id) =>
      for ann in model.annotations {
        if ann.id == id {
          // 20 × 20 bounding box centred on the centroid (radius
          // 10). RoundedRect with radius = half-side renders as a
          // circle via the same FillRoundedRect trick 5.8 uses
          // for keypoints.
          let c : Point = img_to_screen(binding_centroid(ann), pan, zoom)
          let r : @core.Rect = @core.Rect::new(
            x=c.x - 10.0,
            y=c.y - 10.0,
            width=20.0,
            height=20.0,
          )
          let rr : @core.RoundedRect = @core.RoundedRect::new(
            rect=r,
            radius=10.0,
          )
          // Stroke only — the ring must be transparent inside so
          // the underlying image / annotation remains visible.
          @common.stroke_rounded_rect(pctx, rr, @core.Brush::solid(color), 2.0)
        }
      }
  }
}

///|
/// Phase 5.7 — emit a single `DrawPath(PathSpec)` command for the
/// polygon. The path describes a closed polyline: MoveTo(vertex 0),
/// LineTo(vertex 1), LineTo(vertex 2), ..., Close. The renderer's
/// stroke walker handles line joins / caps properly — the legacy
/// fill_rect-segment approximation looked chunky at zoom > 2× and
/// on dpr > 1 displays.
///
/// Stroke colour is the same `selected vs unselected` palette the
/// rect/keypoint branches use; stroke_width is `1.0` (unselected)
/// or `2.0` (selected), matching the 5.3 visual hierarchy.
fn draw_polygon_path(
  pctx : @common.PaintContext,
  ann : Annotation,
  color : @core.Color,
  stroke_width : Double,
  pan : Point,
  zoom : Double,
) -> Unit {
  // Convert the app's local `Point` to the `@core.Point` that
  // PathVerb's enum variants take. Both structs have identical
  // fields (x : Double, y : Double), but MoonBit treats them as
  // distinct types, so we marshal by field here.
  let verbs : Array[@core.PathVerb] = []
  // MoveTo(vertex 0). The transform converts image-natural to
  // screen-space once, here, so the renderer doesn't need a
  // per-vertex matrix push.
  let p0 : Point = img_to_screen(ann.points[0], pan, zoom)
  verbs.push(@core.PathVerb::MoveTo({ x: p0.x, y: p0.y, }))
  // LineTo(vertex 1..N).
  for i = 1; i < ann.points.length(); i = i + 1 {
    let p : Point = img_to_screen(ann.points[i], pan, zoom)
    verbs.push(@core.PathVerb::LineTo({ x: p.x, y: p.y, }))
  }
  // Close the polygon (back to vertex 0). The Close verb is
  // semantically equivalent to a LineTo(vertex 0) followed by
  // a path-close marker that the Skia stroke walker uses to
  // emit a proper miter join at the seam.
  verbs.push(@core.PathVerb::Close)
  let path : @core.PathSpec = @core.PathSpec::new(
    verbs~,
    fill=None,
    stroke=Some(@core.Brush::solid(color)),
    stroke_width~,
  )
  @common.draw_path(pctx, path)
}

///|
/// Phase 5.12.B — polygon fill pass. Emits the same MoveTo +
/// LineTo + Close verb sequence as `draw_polygon_path`, but with
/// `fill=Some(Brush::solid(color))` and `stroke=None`. Called
/// BEFORE the stroke pass so the renderer composites the fill
/// underneath the stroke (matches canvas.js drawPolygonShape
/// lines 300-308: `fill()` then `stroke()`).
///
/// Uses the caller's `color` unchanged — the caller is expected
/// to pass an already-alpha-adjusted color (or to bake the
/// alpha in via Color::rgba with a < 1 alpha).
fn draw_polygon_fill(
  pctx : @common.PaintContext,
  ann : Annotation,
  color : @core.Color,
  pan : Point,
  zoom : Double,
) -> Unit {
  let verbs : Array[@core.PathVerb] = []
  let p0 : Point = img_to_screen(ann.points[0], pan, zoom)
  verbs.push(@core.PathVerb::MoveTo({ x: p0.x, y: p0.y, }))
  for i = 1; i < ann.points.length(); i = i + 1 {
    let p : Point = img_to_screen(ann.points[i], pan, zoom)
    verbs.push(@core.PathVerb::LineTo({ x: p.x, y: p.y, }))
  }
  verbs.push(@core.PathVerb::Close)
  let path : @core.PathSpec = @core.PathSpec::new(
    verbs~,
    fill=Some(@core.Brush::solid(color)),
    stroke=None,
    stroke_width=1.0,
  )
  @common.draw_path(pctx, path)
}

///|
/// Phase 5.12.B — vertex-dot decoration for polygons with <= 30
/// points. Mirrors canvas.js drawPolygonShape lines 309-319: a
/// small filled circle (radius=3) at each vertex with a thin
/// white outline so the dot reads against any underlying
/// background. Drawn in screen space — vertex positions are
/// image-natural → screen mapped once at the call site so the
/// dot radius stays constant under pan/zoom (independent of the
/// polygon's `selected` flag — both branches get the same dot
/// size, which matches canvas.js's `isSelected ? 4 : 3`
/// radius difference being too subtle to bother replicating).
fn draw_polygon_vertex_dots(
  pctx : @common.PaintContext,
  ann : Annotation,
  color : @core.Color,
  pan : Point,
  zoom : Double,
) -> Unit {
  let white : @core.Color = @core.Color::rgba(r=1.0, g=1.0, b=1.0, a=1.0)
  for nat_pt in ann.points {
    let p : Point = img_to_screen(nat_pt, pan, zoom)
    // 6 × 6 square (radius 3) at each vertex — Skia renders
    // FillRoundedRect with radius = half-side as a true circle.
    let r : @core.Rect = @core.Rect::new(
      x=p.x - 3.0,
      y=p.y - 3.0,
      width=6.0,
      height=6.0,
    )
    let rr : @core.RoundedRect = @core.RoundedRect::new(rect=r, radius=3.0)
    @common.fill_rounded_rect(pctx, rr, @core.Brush::solid(color))
    @common.stroke_rounded_rect(pctx, rr, @core.Brush::solid(white), 1.0)
  }
}
