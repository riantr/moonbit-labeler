// Labeler extension tests are hosted under fuzz/ and qa/ instead of
// here, because MoonBit 0.1.20260803 forbids the white-box test file
// from constructing the priv enum and string helpers this extension
// uses internally. The public surface (`extension()`) is exercised
// end-to-end by the Electron + black-box harness in qa/.
//
// Black-box coverage (folder-pick path mapping, label JSON
// roundtrip, VOC/YOLO export) lives in:
//   - qa/labeler_blackbox_test.mjs
//   - qa/labeler_e2e_test.mjs
//
// White-box coverage of the public decode/encode API lives in
// extensions/image/lib_test.mbt.
