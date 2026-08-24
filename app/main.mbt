///|
async fn main {
  // Dual-mode entry point. Defaults to the Proton/CEF IPC shell
  // (the original behavior). When invoked with `--stdio` as the
  // first argument, switches to a headless JSON-RPC bridge over
  // stdin/stdout — used by the Python Qt (or any other) GUI shell
  // that does not need a browser runtime.
  let args = @env.arguments()
  if args.length() >= 2 && args[1] == "--stdio" {
    @stdio_main.run_stdio()
  } else {
    @proton.config("moon.proton").extension(@labeler.extension()).run_or_abort()
  }
}
