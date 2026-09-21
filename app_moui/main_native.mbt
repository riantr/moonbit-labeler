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
  // Initial window framebuffer size. 1280×800 leaves room
  // for the 240 px sidebar + an 800 px canvas viewport (5.12.D
  // hardcodes 800×600 for FitView; 800 is the minimum that
  // matters, but 800 is the canvas width not the window width,
  // so the window itself can be wider for the sidebar +
  // chrome).
  let size : @core.Size = @core.Size::new(width=1280.0, height=800.0)
  let program : @moui.Program[Model, Msg] = program()
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