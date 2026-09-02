///|
async fn main {
  // Proton/CEF IPC shell entry. Loads the 0.2.5 `frontend/dist/index.html`
  // and registers the 18 labeler ops as `ext:labeler/<op>` IPC commands.
  //
  // The previous dual-mode entry also routed `--stdio` to a headless
  // JSON-RPC bridge for the Python Qt shell. That bridge lived in
  // `app/stdio_main.mbt` and was wired in via `@stdio_main.run_stdio()`,
  // but the 0.2.5 `moonbitlang/async` `@stdio` / `@env.arguments()` API
  // surface moved and the old call sites no longer resolve. The bridge
  // source is preserved in `app/stdio_main.mbt.disabled`; a follow-up
  // should port it to the new async API and re-add the branch here.
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
