// Anchor for the `riantr/moonbit_labeler/extensions/image` import declared
// in the root moon.pkg. The gherkin_blackbox_test.mbt suite uses
// @image.detect_format / @image.ImageFormat::* / @image.decode / etc.
// directly, but `moon check` runs in non-test mode and reports the
// import as unused without an explicit production-side reference.
//
// Keeping this anchor means the image codec stays linked into the
// published artifact (it surfaces as part of the @moonbit_labeler root
// namespace so downstream apps can `import "riantr/moonbit_labeler"`
// and reach `@image.*`).
//
// The function itself is intentionally trivial — its only job is to
// give the compiler a concrete symbol that uses the package.

///|
pub fn image_package_anchor() -> Bool {
  // Touch the @image API surface just enough that the import is
  // considered used. detect_format is the cheapest function (no
  // allocation, no decoding). We discard the result — the only goal
  // is the side effect of referencing the package.
  let _ = @image.detect_format(b"")
  true
}
