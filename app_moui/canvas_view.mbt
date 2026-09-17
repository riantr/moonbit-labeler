// app_moui/canvas_view.mbt — annotation canvas as MoUI view.
//
// Phase 5.1 (this session): minimal scaffold that proves the
// MoUI canvas pipeline works. Draws a neutral background + a
// placeholder rectangle + a cursor crosshair (when one is set in
// model.cursorImgPt). Pointer drags emit CursorMoved messages, which
// the update() function folds into model state.
//
// Phase 5.1 does NOT port:
//   - handle hit-testing (the 8 px corner/edge rects)
//   - pan/zoom interaction (placeholder values from model)
//   - DPR scaling
//   - static + dynamic layer composition (single layer)
//   - rect / polygon / keypoint / binding draw logic
//   - image source (no @core.Image decoder wired yet)
//
// Each of these arrives one piece at a time in subsequent phases.

///|
/// Annotation canvas view. Returns a MoUI View that paints a
/// neutral background + (optionally) a placeholder rectangle +
/// cursor crosshair. Pointer drags emit CursorMoved messages.
pub fn canvas_view(model : Model) -> @moui.View[Msg] {
  // Fixed canvas viewport for Phase 5.1. Phase 5.2 will replace
  // with a ResizeObserver-equivalent subscription so the canvas
  // tracks the actual pane size.
  let measure = fn(_constraints : @core.Constraints) -> @core.Size {
    @core.Size::new(width=800.0, height=600.0)
  }
  // draw: paint the empty background + the placeholder rectangle +
  // cursor crosshair. @common is the aliased import for
  // wzzc-dev/moui/views/common (which exposes fill_rect / stroke_rect
  // / draw_image / draw_text + push/pop transform primitives).
  let draw = fn(pctx, frame : @core.Rect) -> Unit {
    // Neutral background (CSS #1f1f1f equivalent: rgb(0.121, 0.121, 0.121)).
    @common.fill_rect(pctx, frame, @core.Color::rgba(r=0.121, g=0.121, b=0.121, a=1.0))
    // Placeholder rect (320×240 grey centred in the viewport).
    let placeholder : @core.Rect = @core.Rect::new(
      x=frame.origin.x + (frame.size.width - 320.0) / 2.0,
      y=frame.origin.y + (frame.size.height - 240.0) / 2.0,
      width=320.0,
      height=240.0,
    )
    @common.fill_rect(pctx, placeholder, @core.Color::rgba(r=0.18, g=0.18, b=0.18, a=1.0))
    @common.stroke_rect(pctx, placeholder, @core.Color::rgba(r=0.4, g=0.4, b=0.4, a=1.0), 1.0)
    // Cursor crosshair (when cursorImgPt is Some).
    match model.cursorImgPt {
      Some(img_pt) => {
        // Convert image-natural px → screen CSS px via pan/zoom.
        let screen_x = model.pan.x + img_pt.x * model.zoom
        let screen_y = model.pan.y + img_pt.y * model.zoom
        // Vertical bar: a thin (1 px tall, 16 px wide) rect centred on
        // (screen_x, screen_y).
        let v_bar : @core.Rect = @core.Rect::new(x=screen_x - 16.0 / 2.0, y=screen_y, width=16.0, height=1.0)
        // Horizontal bar.
        let h_bar : @core.Rect = @core.Rect::new(x=screen_x, y=screen_y - 16.0 / 2.0, width=1.0, height=16.0)
        let white = @core.Color::rgba(r=1.0, g=1.0, b=1.0, a=1.0)
        @common.stroke_rect(pctx, v_bar, white, 1.0)
        @common.stroke_rect(pctx, h_bar, white, 1.0)
      }
      None => ()
    }
  }
  // Build the canvas view, then wire pointer drag → CursorMoved.
  // Phase 5.2 branches on drag phase for BeginDraft / AddRect etc.
  let canvas = @views.canvas(measure~, draw~, semantics_label="Annotation canvas")
  canvas.on_drag(fn(ev) {
    CursorMoved(
      // Image-natural coord: invert the pan/zoom transform.
      { x: (ev.position.x - model.pan.x) / model.zoom,
        y: (ev.position.y - model.pan.y) / model.zoom },
      // Screen coord passes through.
      { x: ev.position.x, y: ev.position.y },
    )
  })
}