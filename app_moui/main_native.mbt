// app_moui/main_native.mbt — Windows native launcher.
//
// Phase 10 wires the MoUI app to the windows_skia backend so
// the executable actually opens a real Win32 window with
// Direct2D rendering. Before Phase 10, `fn main` in app.mbt
// was a stub that just instantiated the program and printed
// a skeleton message — nothing rendered.
//
// Launch sequence (the canonical Moui 0.1.12 path for a
// native binary — see the comment block at the top of
// app.mbt's main entry):
//
//   let runtime = @runtime.new_program(
//     program~ = program(),
//     size~    = @core.Size::new(width, height),
//   )
//   runtime
//     .run_app("MoonBit Labeler", runtime)
//     .backend(@windows.entry())
//     .run()
//
// Where:
//   - `program()` is the @moui.Program[Model, Msg] from app.mbt
//     (Model::new / update / view triple).
//   - `@core.Size` is the initial window framebuffer size in
//     logical pixels. 1280×800 matches the canvas viewport the
//     rest of the app expects (sidebar 240 + canvas 800 +
//     a little overhead).
//   - `@runtime.run_app` produces an AppBuilder; `.backend`
//     selects the host entrypoint; `.run` is the blocking
//     call that drives the event loop until the user closes
//     the window. The function never returns under normal
//     operation — control comes back only when the user
//     closes the window via the X button.
//
// The "windows" backend is selected unconditionally because
// `supported_targets = "native"` restricts the build to the
// Windows host (this is a Windows-only app for now — Linux /
// macOS launches live in sibling packages the same way).
//
// Why a separate file: keeping the launcher isolated means
// `moon test` doesn't need the native-stub C/C++ files in
// scope (the test target compiles native but doesn't link the
// GUI subsystem — it just runs the blackbox tests on the
// pure helpers).

///|
/// Phase 10 — entry point for the native (Windows) target.
/// Constructs the MoUI program, hands it to the windows
/// runtime, and runs the event loop. Blocks until the user
/// closes the window. Doesn't return under normal operation.
///
/// Set the env var `MOONBIT_LABELER_SMOKE=1` to enable the
/// `first_frame_smoke_auto_exit` flag on the Windows backend —
/// the program opens a window, renders the first frame, then
/// exits cleanly. Used by `_build/run_smoke.ps1` (or a manual
/// `MOONBIT_LABELER_SMOKE=1 .\app_moui.exe`) to verify the
/// binary boots, the windows_skia runtime spins up, and the
/// Direct2D presenter can produce at least one frame. Without
/// the smoke flag, the binary blocks indefinitely waiting for
/// the user to close the window.
fn main {
  // Phase 5.13 — the window size, and the two numbers it becomes.
  //
  // This used to be a bare 1920x1080 with the comment "leaves room
  // for the 240 px sidebar + an 800 px canvas viewport", and a
  // separate `1280x800` was hardcoded into `app.mbt::view` for the
  // view tree. Neither number was ever checked against the other.
  //
  // The physical request is what Win32 wants; the logical pair is
  // what the layout (and therefore `Model::viewport`) works in.
  // `AppRuntime::size()` returns the request divided by the DPI
  // scale factor, which is 2 on this host: 1920x1080 requested
  // gives a 947x504 logical layout. Getting this backwards is
  // observable — requesting 947x504 produced a 460x216 logical
  // layout, i.e. a half-size window. Phase 18.B's 1920x1080 was
  // right and should not have been "fixed"; the display is
  // 1894x1009 physical, so that is as large as the window can
  // usefully get. The scale factor is not knowable before the
  // surface exists, so both numbers are spelled out rather than
  // derived.
  let window_physical_width : Double = 1920.0
  let window_physical_height : Double = 1080.0
  let window_logical_width : Double = 947.0
  let window_logical_height : Double = 504.0
  let size : @core.Size = @core.Size::new(
    width=window_physical_width,
    height=window_physical_height,
  )
  // Phase 5.2 — pre-populate the renderer's module-local
  // ImageCache with a synthetic 200×200 RGBA8 test fixture so
  // the smoke screenshot can demonstrate the full image-source
  // pipeline (`model.imageSource → DrawImage → cache hit →
  // paint_image → window presenter`) without requiring a
  // real image file on disk. The async file-read bridge that
  // `LoadImage(path)` needs is blocked in moon 0.1.20260904
  // (see image_header.mbt doc); this fixture is the working
  // substitute for the smoke harness.
  //
  // The fixture is a 200×200 RGBA8 image with a 4-quadrant
  // pattern + 8 px checker border, mirroring
  // phase14_image_test.mbt::make_quadrant_rgba8 so the
  // smoke and the unit test cover the same shape.
  ignore(register_synthetic_test_image())
  // Phase 5.4 — programmatically apply one BeginDragHandle +
  // CursorMoved + ModifyHandle + EndDragHandle sequence at
  // startup so the smoke screenshot demonstrates the live
  // drag wiring (rect-1 BR corner resized from (140,140) to
  // (175,175)). The dispatched state lands in `init_model`,
  // which `program_with_init` then hands to the runtime as
  // the cold-start Model. Production callers can keep using
  // the default `program()` (Model::new with no initial
  // drag).
  let init_model : Model = {
    ..build_demo_drag_model(),
    viewport: @core.Size::new(
      width=window_logical_width,
      height=window_logical_height,
    ),
  }
  let program : @moui.Program[Model, Msg] = program_with_init(
    init_model,
  )
  let runtime : @runtime.AppRuntime = @runtime.new_program(
    program~,
    size~,
  )
  // Phase 17 — smoke auto-exit: pass `--smoke` on the
  // command line to make the windows backend exit after the
  // first frame is presented. Used by `_build/run_smoke.ps1`
  // to verify the binary boots, the windows_skia runtime
  // spins up, and the Direct2D presenter can produce at
  // least one frame without a human closing the window.
  //
  // We use `@env.args()` (same pattern as `app/main.mbt` for
  // `--stdio` / `--debug`) because Moon's stdlib in this
  // version doesn't expose `getenv`. `--smoke` is a no-op in
  // the normal interactive flow (default = false).
  let args : Array[String] = @env.args()
  let smoke : Bool = args.contains("--smoke")
  let smoke_options : @windows.WindowsHostSmokeOptions = @windows.WindowsHostSmokeOptions::new(
    first_frame_smoke_auto_exit=smoke,
  )
  // Title string + host backend. The windows backend's
  // `entry()` returns a @runtime.PlatformEntry that the
  // AppBuilder consumes via `.backend(...)`. `run_app` is a
  // free function (not a method on AppRuntime).
  //
  // Phase 10.2 — register the placeholder RendererProvider
  // BEFORE .backend(). Without this, the runtime aborts with
  // "at least one renderer provider is required" (Phase 10.1
  // bug). The placeholder paints a flat-grey frame; a real
  // Skia/Direct2D renderer lands in a follow-up batch.
  @runtime
  .run_app("MoonBit Labeler", runtime)
  .render(make_renderer_provider())
  .backend(
    @windows.entry(options=@windows.WindowsHostAppOptions::new(), smoke_options~),
  )
  .run()
}

///|
/// Phase 5.4 — simulate a single handle drag on `Model::new()`
/// before the first frame, so the smoke screenshot demonstrates
/// the drag wiring visually.
///
/// Phase 5.6 — the sequence now goes through `CanvasPressed`,
/// i.e. exactly what a real mouse press dispatches. Note the
/// cold start has `selectedId == None` and `dragState == None`,
/// so this also exercises the select-then-arm-in-one-press path
/// that was broken before 5.6 (pre-5.6 the Started-phase closure
/// read the *previous* frame's `selectedId`, so the first press of
/// a session could never arm a drag).
///
/// Dispatched sequence:
///   `CanvasPressed((140, 140))` — presses rect-1's BR handle
///   while nothing is selected; selects rect-1 AND arms handle 4
///   + `CursorMoved` to (175, 175) → routed to `ModifyHandle`
///   + `ModifyHandle` to land the drag
///   + `EndDragHandle` to release
///
/// Resulting Model has rect-1 resized from
/// `(40, 40) → (140, 140)` to `(40, 40) → (175, 175)`, proving
/// the full `update` chain (CanvasPressed → hit_test_select +
/// hit_test_handle → dragState Some → CursorMoved →
/// Effect::send ModifyHandle → mutate_annotation →
/// apply_handle_move → points[1] = new_pt) wired correctly.
/// Used only by the smoke harness; production callers can
/// keep using `program()` which starts from `Model::new()`.
fn build_demo_drag_model() -> Model {
  // Cold start — nothing selected, no drag armed. The press
  // below must do select + arm in one step.
  let base : Model = Model::new()
  let (m1, _) = update(
    base,
    CanvasPressed({ x: 140.0, y: 140.0 }, { x: 140.0, y: 140.0 }),
  )
  let (m2, _) = update(
    m1,
    CursorMoved({ x: 175.0, y: 175.0 }, { x: 175.0, y: 175.0 }),
  )
  let (m3, _) = update(
    m2,
    ModifyHandle("rect-1", 4, { x: 175.0, y: 175.0 }),
  )
  let (m4, _) = update(m3, EndDragHandle)
  // Phase 5.8 — then draw a *brand new* annotation with the Rect
  // tool, so the smoke screenshot also proves creation works (not
  // just editing of the three synthetic demo annotations). Drawn in
  // the lower-left region, clear of rect-1 / poly-1 / kp-1, so it's
  // visually unambiguous.
  //
  // Phase 5.9 — the tool is armed through `SetMode`, which is
  // exactly what clicking [Rect] in the toolbar dispatches. The
  // pre-5.9 version patched `mode` straight into the struct literal
  // (`{ ..m4, mode: Rect, }`), i.e. it reached for the programmatic
  // path Phase 5.9 exists to make unnecessary.
  let (armed, _) = update(m4, SetMode(Rect))
  //
  // The dispatched sequence is exactly what the canvas's
  // mode-aware `on_drag` sends in Rect mode: BeginDraft on press,
  // UpdateDraft per drag frame, CommitDraft on release → AddRect.
  let (d1, _) = update(armed, BeginDraft({ x: 8.0, y: 96.0 }))
  let (d2, _) = update(d1, UpdateDraft({ x: 46.0, y: 190.0 }))
  let (d3, _) = update(d2, AddRect({ x: 8.0, y: 96.0 }, { x: 46.0, y: 190.0 }))
  // `AddRect` resets the mode back to Select (a bare click must not
  // silently keep drawing), so drawing a second rect needs the tool
  // re-armed — which is precisely the loop the toolbar now closes
  // for the user. Re-arming here exercises it twice, and leaves the
  // second rect (`ann-2`) in the smoke screenshot alongside
  // `ann-1`.
  //
  // Note the screenshot therefore shows **[Select]** as the armed
  // tool, not [Rect]: the final `AddRect` reset the mode, which is
  // the honest post-draw steady state. Seeing one button filled
  // (`ButtonVariant::Primary`) against four `Ghost` is the
  // user-visible half of Phase 5.9 either way.
  let (rearmed, _) = update(d3, SetMode(Rect))
  let (e1, _) = update(rearmed, BeginDraft({ x: 118.0, y: 148.0 }))
  let (e2, _) = update(e1, UpdateDraft({ x: 192.0, y: 196.0 }))
  let (e3, _) = update(
    e2,
    AddRect({ x: 118.0, y: 148.0 }, { x: 192.0, y: 196.0 }),
  )
  // Phase 5.11 — finish in the middle of a polygon so the smoke
  // screenshot shows the new rubber-band segment: two committed
  // vertices plus a cursor position between clicks, which is the only
  // state where the band exists.
  //
  // The vertices are placed in the image's top strip, clear of
  // rect-1 (y >= 40), poly-1 (y >= 30, x >= 110), kp-1 and the two
  // runtime rects, so the band cannot be confused with existing
  // geometry. They go in through `PushDraft`, the Msg the canvas
  // sends in Polygon mode, and the tool is armed through `SetMode`
  // exactly as clicking [Polygon] would.
  //
  // The screenshot therefore shows **[Polygon]** as the armed tool
  // rather than [Select]. That still demonstrates Phase 5.9's cue —
  // one filled `Primary` against four `Ghost` — and the band is only
  // reachable with the polygon tool active, so this is the honest
  // state to capture.
  let (polygon_armed, _) = update(e3, SetMode(Polygon))
  let (poly1, _) = update(polygon_armed, PushDraft({ x: 20.0, y: 20.0 }))
  let (poly2, _) = update(poly1, PushDraft({ x: 60.0, y: 10.0 }))
  let (poly3, _) = update(
    poly2,
    CursorMoved({ x: 95.0, y: 25.0 }, { x: 95.0, y: 25.0 }),
  )
  poly3
}

///|
/// Phase 5.2 — build a 200×200 RGBA8 synthetic test image and
/// inject it into the renderer's module-local ImageCache under
/// the source name `_phase5_2_synthetic`. The 200×200 size was
/// chosen to fit comfortably inside the canvas viewport at
/// any reasonable window size (the canvas's fit-contain math
/// will scale it down if the window is smaller).
///
/// Phase 5.7 — the fixture body moved out to
/// `banded_rgba8_fixture` in image_cache.mbt and is now a 4-band
/// pattern (red / green / blue / white) instead of solid magenta.
/// Rationale: solid magenta was a *degenerate* check — a uniform
/// source produces identical pixels under any source-sampling
/// mapping, so it could not (and did not) catch the mapping bugs
/// the Phase 5.2 note suspected. Banding makes the smoke
/// screenshot self-validating: a dropped, repeated, or shifted
/// band is visible at a glance, and `phase5_7_blit_test.mbt` pins
/// the same builder through the real rasterizer.
///
/// The Phase 5.2 "4-stripe only rendered 2 of 4 stripes" known bug
/// is resolved: the blit path is correct (`src_y = dy * src_h /
/// dst_h`, no clamp), proven by the Phase 5.7 tests at 2x upscale
/// and 0.5x downscale. The failure was in throwaway fixture code
/// that no longer exists, not in `paint_image`.
///
/// Returns `true` if the cache accepted the bytes (cache hit
/// path works on the next paint), `false` otherwise.
fn register_synthetic_test_image() -> Bool {
  let w : Int = 200
  let h : Int = 200
  register_test_image_in_renderer(
    "_phase5_2_synthetic",
    w,
    h,
    banded_rgba8_fixture(w, h),
  )
}