// Anchors for the imports declared in the root moon.pkg. Several of
// these packages are referenced only by `*_blackbox_test.mbt` at the
// project root, but `moon check` runs in non-test mode and would flag
// the imports as unused without a production-side reference. Each
// anchor below touches the package just enough for the import to be
// considered used; the functions themselves are trivial and exist only
// to keep the link graph intact for the published artifact
// (downstream apps `import "riantr/moonbit_labeler"` and reach
// `@moonbit_image.*` / `@labeler.*` / `@fs.*` / `@ref.*` through
// these re-exports).
//
// All four anchors are intentionally cheap (no allocation, no real IO,
// no async-only constructs), and they ignore their results — the only
// goal is the side effect of referencing the package.

///|
/// Anchor for `riantr/moonbit_image`. Touches the cheapest function
/// (`detect_format` on an empty byte buffer) so the image codec
/// stays linked into the published artifact.
pub fn image_package_anchor() -> Bool {
  let _ = @moonbit_image.detect_format(b"")
  true
}

///|
/// Anchor for `moonbitlang/async`. The `async fn` keyword alone is
/// not counted as a use by the compiler (per moon 0.1.x), so we
/// construct an `Error` via `fail()` and pass it to
/// `is_cancellation_error`. The returned `Bool` is discarded; only
/// the package reference matters.
pub fn async_package_anchor() -> Bool raise {
  let e = fail("anchor")
  let _ = @async.is_cancellation_error(e)
  true
}

///|
/// Anchor for `moonbitlang/async/fs`. `kind` is an async function
/// returning `FileKind`; we probe a path that almost certainly does
/// not exist and swallow any IO error — the goal is just to touch
/// the `@fs.*` namespace.
pub async fn fs_package_anchor() -> Bool {
  let _ = @fs.kind("/__riantr_anchor_path__") catch {
    _ => @fs.Regular
  }
  true
}

///|
/// Anchor for `moonbitlang/core/ref`. `Ref::new` is a zero-cost
/// constructor; we allocate one and immediately drop it.
pub fn ref_package_anchor() -> Bool {
  let _ = @ref.new(b"")
  true
}

///|
/// Anchor for `riantr/moonbit_labeler/extensions/labeler`. The
/// `dispatch_op_list()` symbol is the cheapest entry into the labeler
/// public API — no parameters, returns an `Array[String]`. We
/// discard the array; only the package reference matters.
pub fn labeler_package_anchor() -> Bool {
  let _ = @labeler.dispatch_op_list().length()
  true
}