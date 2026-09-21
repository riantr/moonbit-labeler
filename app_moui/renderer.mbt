// app_moui/renderer.mbt — minimal SkiaRasterNative RendererProvider
// for Phase 10.2.
//
// Goal: build a RendererProvider that's structurally correct
// enough that the windows backend accepts it (no more
// "runtime.run_app: at least one renderer provider is
// required" warning) AND the binary's render loop calls
// render_frame each tick. The frame itself is a flat dark-grey
// background — no Skia/Direct2D pipeline to translate the
// Moui render tree into pixels yet. That's a separate Phase
// 11 (or beyond) where we'd actually port the Moui render
// pipeline to Direct2D / Skia calls.
//
// Why minimal-but-correct over no-op:
//   - The windows backend's render loop is event-driven
//     (resize / paint / invalidate) and only fires paint
//     callbacks when at least one provider successfully binds.
//     Without a provider, no paint messages are produced and
//     the window stays blank.
//   - The minimal RendererSession below proves the
//     HostSurface → NativeSurface → HWND plumbing works, and
//     gives us a foundation to add Skia calls incrementally
//     without redoing the bind plumbing each batch.

///|
/// Module-local mutable counter for `present_count`. The
/// renderer session exposes `present_count()` as a thunk so
/// the runtime can poll how many frames we've actually
/// blitted. Useful for tests + smoke harnesses.
let present_count : Ref[Int] = { val: 0 }

///|
/// Module-local "current metrics" snapshot. The resize
/// callback updates this so render_frame can size the
/// PixelFrame correctly.
let current_metrics : Ref[@core.SurfaceMetrics] = {
  val: @core.SurfaceMetrics::new(
    logical_size=@core.Size::new(width=0.0, height=0.0),
    physical_size=@core.Size::new(width=0.0, height=0.0),
    scale_factor=1.0,
  ),
}

///|
/// Phase 13 — per-process image cache. The renderer session
/// owns one cache for its lifetime; `paint_image` looks up
/// `ImageRun.source` here on every `DrawImage`. The cache is
/// populated externally (Moui `HostImageSource` integration
/// is Phase 14; tests call `load_bytes` directly). Keeping
/// it module-local rather than on the RendererSession avoids
/// any churn in the Moui renderer-session shape.
let image_cache : Ref[ImageCache] = { val: ImageCache::new() }

///|
/// Phase 10.2 — build a minimal RendererProvider that the
/// windows backend can bind. Returns a `Bound(RendererSession)`
/// on a HostSurface with `native_surface()` populated, or
/// `Rejected` (with a useful reason) when the HostSurface
/// lacks a native surface (e.g. headless test runner).
pub fn make_renderer_provider() -> @render.RendererProvider {
  // Minimal RendererBackendFeatureCapability: the windows
  // backend only requires that the provider has SOME descriptor
  // (the runtime reads `descriptor.backend` to route). Empty
  // capability list is fine for the no-op renderer — we won't
  // attempt any feature until Phase 11.
  let caps_closure : () -> Array[@render.RendererBackendFeatureCapability] = fn() {
    []
  }
  let descriptor : @render.RendererDescriptor = @render.RendererDescriptor::new(
    backend=@render.RendererBackendKind::SkiaRasterNative,
    family=@render.RendererFamily::Skia,
    presentation=@render.RendererPresentationModel::CpuPixelFrame,
    supported_targets=[@render.RendererTarget::Native],
    capabilities=[],
    description="app_moui Phase 10.2 placeholder — paints a flat grey frame; no Skia calls yet",
  )
  @render.RendererProvider::new(
    id="app_moui.phase10_2",
    descriptor~,
    capabilities=caps_closure,
    bind=fn(surface) { bind_renderer(surface) },
  )
}

///|
/// Phase 10.2 — bind the renderer to a HostSurface. Returns
/// `Bound(RendererSession)` if the surface has a native
/// surface (HWND on Windows); `Rejected` otherwise. The
/// RendererSession closures (resize / render_frame / etc.)
/// are minimal no-ops that produce a flat-grey frame each
/// paint; a future Phase 11 wires Skia calls in render_frame.
fn bind_renderer(
  surface : @render.HostSurface,
) -> @render.RendererBindResult {
  // Need a native surface to blit to. On Windows the
  // backend populates this with an HWND-backed
  // NativeSurface; on other platforms (or in tests) it's
  // None — we reject those.
  let native : @render.NativeSurface? = surface.native_surface()
  match native {
    Some(_) => {
      // Capture the surface's metrics at bind time so the
      // first `render_frame` (which fires before any
      // SurfaceResized event) already has the correct
      // dimensions. Without this, current_metrics stays
      // at its 0×0 default and `render_placeholder_frame`
      // builds a 0×0 PixelFrame that the Win32 GDI blit
      // rejects (`width <= 0` early return), leaving the
      // HWND permanently blank.
      current_metrics.val = surface.metrics()
      // Build the minimal RendererSession. Each closure is
      // a closure capturing nothing — they're all no-ops or
      // trivial counters at Phase 10.2's fidelity.
      Bound(
        @render.RendererSession::new(
          resize=fn(metrics) { current_metrics.val = metrics },
          render_frame=fn(submission) {
            render_placeholder_frame(submission, surface)
          },
          text_system=fn() { @core.TextSystem::fallback() },
          present_count=fn() { present_count.val },
        ),
      )
    }
    None => Rejected("app_moui Phase 10.2 renderer needs a native surface (HWND); got None")
  }
}

///|
/// Phase 11 — produce a real frame by rasterizing the Moui
/// `DrawFrame` from the submission into a BGRA pixel buffer
/// (via `rasterizer.mbt`), then handing it to the PresentTarget.
/// Phase 10.2 painted a flat-grey placeholder; Phase 11
/// actually translates the Moui view tree (Clear / FillRect /
/// StrokeRect / FillRoundedRect / StrokeRoundedRect / DrawPath
/// polygon / DrawText placeholder / DrawImage placeholder)
/// into BGRA bytes.
fn render_placeholder_frame(
  submission : @render.RenderFrameSubmission,
  surface : @render.HostSurface,
) -> @render.RenderFrameResult {
  // We need a PresentTarget to push pixels to. The HostSurface
  // exposes `cpu_present()` only if the backend is set up
  // for CPU pixel present. On Windows with the
  // windows_present.cpp path, the surface should expose a
  // CPU present that internally calls
  // `windows_present_pixels_to_hwnd(hwnd, ...)`.
  match surface.cpu_present() {
    Some(present_target) => {
      let metrics : @core.SurfaceMetrics = current_metrics.val
      let width : Int = metrics.logical_size.width.to_int()
      let height : Int = metrics.logical_size.height.to_int()
      let row_bytes : Int = width * 4 // BGRA8888 = 4 bytes/px
      // Allocate a fresh BGRA buffer and rasterize the Moui
      // view tree into it. `PixelBuffer::new` initializes to
      // the clear color; `rasterize_draw_frame` walks the
      // command array and writes shape primitives. We hand
      // the result to the PresentTarget as immutable Bytes.
      let buf : PixelBuffer = PixelBuffer::new(
        width,
        height,
        @core.Color::rgba(r=0.1, g=0.1, b=0.12, a=1.0), // dark slate
      )
      rasterize_draw_frame(buf, submission.frame(), image_cache.val)
      let frame : @render.PixelFrame = @render.PixelFrame::new(
        width~,
        height~,
        row_bytes~,
        scale_factor=metrics.scale_factor,
        pixels=PixelBuffer::to_bytes(buf),
      )
      let presented : Bool = present_target.present(frame)
      present_count.val = present_count.val + 1
      @render.RenderFrameResult::new(presented~)
    }
    None =>
      // No CPU present → can't produce frames. Return
      // presented=false and let the runtime decide what to
      // do (typically it falls back to a different
      // provider or shows a blank window).
      @render.RenderFrameResult::new(presented=false)
  }
}

///|
/// Phase 10.2 — test helper: get the count of frames blitted
/// since the last reset. Used by the smoke harness to verify
/// at least one frame made it through the render pipeline.
pub fn test_present_count() -> Int {
  present_count.val
}

///|
/// Phase 10.2 — test helper: reset the present count. Used
/// between smoke runs so a fresh process begins at zero.
pub fn test_reset_present_count() -> Unit {
  present_count.val = 0
}