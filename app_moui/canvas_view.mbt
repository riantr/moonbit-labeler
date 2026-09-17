// app_moui/canvas_view.mbt — annotation canvas as MoUI view.
//
// Phase 5.2 (this session): paint an actual image source instead of
// the 5.1 placeholder rect. The draw callback:
//
//   1. Clears the frame to neutral background (#1f1f1f).
//   2. If model.imageSource == "" (default), draws the 320×240
//      placeholder rect so the canvas pane still has visible
//      content before any image is loaded.
//   3. Else, emits a `DrawImage` command with the image's natural
//      size + the model.fitMode. The destination rect is computed
//      via fit-contain math (preserve aspect ratio, centred, then
//      scale by model.zoom, then offset by model.pan).
//
// Phase 5.2 does NOT port:
//   - DPR scaling (frame is in logical pixels; deferred to 5.4)
//   - image-header probe (caller passes natural size; 5.3 will
//     use riantr/moonbit_image to read the header)
//   - static + dynamic layer composition (single layer for now)
//   - pan/zoom wheel handlers (cursor drag already emits CursorMoved;
//     wheel + Zoom/Pan Msgs are wired in update() but no input plumbing
//     yet — that's 5.11)
//   - handle hit-testing + draw logic for rect/polygon/keypoint/binding
//
// Phase 5.2 explicitly uses the draw callback's `frame` parameter as
// the actual viewport size. MoUI has no `on_resize` observer; the
// layout pass always passes the correct frame to the canvas's paint
// callback, so the draw already knows its viewport.

///|
/// Annotation canvas view. Returns a MoUI view that paints a neutral
/// background + (optionally) a real image + cursor crosshair. The
/// draw callback receives `frame : @core.Rect` which is the canvas's
/// actual viewport — MoUI layout guarantees this is the right size
/// on every paint, so there's no separate ResizeObserver subscription.
pub fn canvas_view(model : Model) -> @moui.View[Msg] {
  // Measure callback: relax to the parent's frame constraint.
  // `Constraints` is a struct with `min : Size` and `max : Size`
  // fields — use the max field directly so the canvas fills its
  // parent pane (the right pane of split_view).
  let measure = fn(constraints : @core.Constraints) -> @core.Size {
    constraints.max
  }
  // Draw: background + (image OR placeholder) + cursor crosshair.
  let draw = fn(pctx, frame : @core.Rect) -> Unit {
    // 1. Neutral background.
    @common.fill_rect(
      pctx,
      frame,
      @core.Color::rgba(r=0.121, g=0.121, b=0.121, a=1.0),
    )
    // 2. Image OR placeholder.
    if model.imageSource == "" {
      // Placeholder rect (320×240 grey centred in the viewport).
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
      // Compute the fit-contain destination rect.
      let dst : @core.Rect = fit_contain_rect(
        frame,
        model.imageNaturalSize.x,
        model.imageNaturalSize.y,
      )
      // Apply pan/zoom: shift the dst rect by model.pan and scale by
      // model.zoom around the frame's top-left. (Phase 5.11 will
      // refine to keep the cursor anchor under the mouse.)
      let zoomed : @core.Rect = @core.Rect::new(
        x=dst.origin.x + model.pan.x,
        y=dst.origin.y + model.pan.y,
        width=dst.size.width * model.zoom,
        height=dst.size.height * model.zoom,
      )
      @common.draw_image(
        pctx,
        {
          source: model.imageSource,
          frame: zoomed,
          opacity: 1.0,
          fit: model.fitMode,
        },
      )
    }
    // 3. Cursor crosshair (when cursorImgPt is Some).
    match model.cursorImgPt {
      Some(img_pt) => {
        let screen_x = model.pan.x + img_pt.x * model.zoom
        let screen_y = model.pan.y + img_pt.y * model.zoom
        let v_bar : @core.Rect = @core.Rect::new(
          x=screen_x - 16.0 / 2.0,
          y=screen_y,
          width=16.0,
          height=1.0,
        )
        let h_bar : @core.Rect = @core.Rect::new(
          x=screen_x,
          y=screen_y - 16.0 / 2.0,
          width=1.0,
          height=16.0,
        )
        let white = @core.Color::rgba(r=1.0, g=1.0, b=1.0, a=1.0)
        @common.stroke_rect(pctx, v_bar, white, 1.0)
        @common.stroke_rect(pctx, h_bar, white, 1.0)
      }
      None => ()
    }
  }
  let canvas = @views.canvas(
    measure~,
    draw~,
    semantics_label="Annotation canvas",
  )
  canvas.on_drag(fn(ev) {
    CursorMoved(
      { x: (ev.position.x - model.pan.x) / model.zoom,
        y: (ev.position.y - model.pan.y) / model.zoom },
      { x: ev.position.x, y: ev.position.y },
    )
  })
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
  // Guard against zero natural size — fall back to filling the frame.
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