///|
/// Decide whether the executable was launched with `--stdio` (headless
/// JSON-RPC mode for non-CEF shells, e.g. the Python Qt front-end).
///
/// Moon's stdlib doesn't expose `Array.contains`, so a linear scan is
/// the idiomatic way. (`@env.args()` always includes `argv[0]` — the
/// program name — so we don't bother slicing it off; no one's
/// executable is named `--stdio`.)
fn is_stdio_mode(args : Array[String]) -> Bool {
  for arg in args {
    if arg == "--stdio" {
      return true
    }
  }
  false
}

///|
/// `--debug` flips CEF into debug mode (DevTools, verbose console
/// logging, frame-rate HUD). Defaults to off so release builds don't
/// ship a `right-click → Inspect Element` escape hatch or write
/// `%TEMP%/proton_logs/` on every launch.
///
/// Why a CLI flag instead of an env var: Moon 0.2.5's `env` package
/// only exposes `args()` — there is no `getenv`, and Proton's native
/// FFI doesn't bridge it. A CLI flag is observable through the same
/// `@env.args()` we already use for `--stdio` and is the format the
/// `_build/run.bat` launcher already speaks.
fn is_debug_mode(args : Array[String]) -> Bool {
  for arg in args {
    if arg == "--debug" {
      return true
    }
  }
  false
}

///|
async fn main {
  // Proton/CEF IPC shell entry. Loads the `frontend/dist/index.html`
  // and registers the 24 labeler ops as `ext:labeler/<op>` IPC commands.
  //
  // When launched with `--stdio`, skip the Proton/Chromium stack and
  // run the headless JSON-RPC bridge in `stdio_main.mbt` instead. The
  // bridge talks the same 24 ops to the parent process over stdin/stdout,
  // which lets non-CEF shells (Python Qt, scripts, debug tooling) embed
  // the labeler backend without spinning up a webview.
  let args = @env.args()
  if is_stdio_mode(args) {
    run_stdio()
  } else {
    // Proton 0.9.0 turned the `App` builder from a chainable style
    // (every setter returned `Self`) into a statement style (every
    // setter returns `Unit` and mutates the app in place). Chaining
    // `.identifier(..).capability(..)` no longer type-checks, so the
    // builder is held in a local and configured step by step.
    //
    // `asset`, not `file`: an `AppEntry::File` is resolved against the
    // *current working directory* (Proton's `resolve_entry_path` calls
    // `@mbpath.Path(path).resolve()`), so the packaged app only found its
    // entry HTML when it was started from its own directory. The zip we
    // ship did not even carry that copy, so the app came up with no
    // window at all. An `AppEntry::Asset` is resolved against the
    // resource directory instead (`<exe dir>/Resources`, derived from
    // `proton-package.json`), which is exactly where `proton_cli
    // package` stages `frontend/dist` — so the entry is found whatever
    // the working directory is, and no mirror copy is needed.
    let app = @proton.asset(
      "MoonBit Labeler",
      "frontend/dist/index.html",
      width=1280,
      height=800,
      debug=is_debug_mode(args),
    )
    app.identifier("io.mooncakes.riantr.moonbit-labeler")
    app.capability(@proton_extension.capability(@labeler.extension()))
    app.run_or_abort()
  }
}
