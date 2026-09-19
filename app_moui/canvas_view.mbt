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
  s = s + annotations_fingerprint(model.annotations, model.selectedId)
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
  selected : String?,
) -> String {
  let mut s = anns.length().to_string()
  s = s + "|"
  for ann in anns {
    s = s + ann.id
    s = s + ":"
    s = s + shape_tag(ann.shape)
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
    draw_annotation(pctx, ann, is_sel, model.pan, model.zoom)
  }
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
