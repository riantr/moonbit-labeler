///|
/// Decide whether the executable was launched with `--stdio` (headless
/// JSON-RPC mode for non-CEF shells, e.g. the Python Qt front-end).
fn is_stdio_mode(args : Array[String]) -> Bool {
  for arg in args {
    if arg == "--stdio" {
      return true
    }
  }
  false
}

///|
async fn main {
  // Proton/CEF IPC shell entry. Loads the 0.2.5 `frontend/dist/index.html`
  // and registers the 18 labeler ops as `ext:labeler/<op>` IPC commands.
  //
  // When launched with `--stdio`, skip the Proton/Chromium stack and
  // run the headless JSON-RPC bridge in `stdio_main.mbt` instead. The
  // bridge talks the same 18 ops to the parent process over stdin/stdout,
  // which lets non-CEF shells (Python Qt, scripts, debug tooling) embed
  // the labeler backend without spinning up a webview.
  let args = @env.args()
  if is_stdio_mode(args) {
    run_stdio()
  } else {
    @proton.file(
      "MoonBit Labeler",
      "frontend/dist/index.html",
      width=1280,
      height=800,
      debug=true,
    )
    .identifier("com.mavis.moonbit-labeler")
    .capability(@proton_extension.capability(@labeler.extension()))
    .run_or_abort()
  }
}
