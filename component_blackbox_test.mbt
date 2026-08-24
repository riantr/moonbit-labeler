// Component tests — exercise the interaction between two production
// modules: `extensions/image` (codec) and `extensions/labeler` (label
// schema normalizer). Each scenario validates that calling the public
// APIs across the package boundary yields the contract documented in
// `extensions/image/lib.mbt` and `extensions/labeler/labeler.mbt`.
//
// These tests run as a blackbox suite (`*_blackbox_test.mbt`) at the
// project root, so they see only the public surfaces: @image.* and
// @labeler.*. Internal helpers (normalize_label_json, decode_for, …)
// are intentionally not exercised here.
//
// Fixtures are built inline via `Bytes::from_array(...)` to keep this
// file self-contained; gherkin_blackbox_test.mbt has its own copies
// with the same shapes.

// ---------------------------------------------------------------------------
// Inline byte-construction helper
// ---------------------------------------------------------------------------

///|
fn bytes_from(values : Array[Int]) -> Bytes {
  // Each value is converted to its low 8 bits via Int::to_byte(),
  // matching the helper used in gherkin_blackbox_test.mbt.
  let buf = Array::make(values.length(), b'\x00')
  for i = 0; i < values.length(); i = i + 1 {
    buf[i] = values[i].to_byte()
  }
  Bytes::from_array(buf)
}

// ---------------------------------------------------------------------------
// Fixtures — 1x1 BMP and 1x1 QOI, hand-rolled to match what PIL would emit
// ---------------------------------------------------------------------------

///|
fn comp_bmp_1x1_black_24bpp() -> Bytes {
  // 58 bytes: 14-byte file header + 40-byte DIB header + 4-byte pixel row
  let bytes : Array[Int] = [
    // file header
    0x42, 0x4D, // "BM"
    0x3A, 0x00, 0x00, 0x00, // file size = 58
    0x00, 0x00, 0x00, 0x00, // reserved
    0x36, 0x00, 0x00, 0x00, // pixel data offset = 54
    // DIB header (BITMAPINFOHEADER)
    0x28, 0x00, 0x00, 0x00, // header size = 40
    0x01, 0x00, 0x00, 0x00, // width = 1
    0x01, 0x00, 0x00, 0x00, // height = 1
    0x01, 0x00, // planes = 1
    0x18, 0x00, // bpp = 24
    0x00, 0x00, 0x00, 0x00, // compression = 0
    0x04, 0x00, 0x00, 0x00, // image size = 4
    0x00, 0x00, 0x00, 0x00, // x pix/m
    0x00, 0x00, 0x00, 0x00, // y pix/m
    0x00, 0x00, 0x00, 0x00, // colors used
    0x00, 0x00, 0x00, 0x00, // colors important
    // pixel row: BGR=0,0,0 + 1 byte pad
    0x00, 0x00, 0x00, 0x00,
  ]
  bytes_from(bytes)
}

///|
fn comp_qoi_1x1_red_rgba() -> Bytes {
  // 24 bytes: 'qoif' magic + BE(width=1) + BE(height=1) + channels +
  // colorspace + OP_RGB(255,0,0) + 8-byte end marker.
  // Matches the layout used by gherkin_blackbox_test.mbt.
  let bytes : Array[Int] = [
    0x71, 0x6F, 0x69, 0x66, // "qoif"
    0x00, 0x00, 0x00, 0x01, // width = 1
    0x00, 0x00, 0x00, 0x01, // height = 1
    0x04, // channels = 4 (RGBA)
    0x01, // colorspace = sRGB (value 1, not 0)
    0xFE, // OP_RGB tag
    0xFF, 0x00, 0x00, // R=255, G=0, B=0
    0x00, 0x00, 0x00, 0x00, // 8-byte end marker
    0x00, 0x00, 0x00, 0x01,
  ]
  bytes_from(bytes)
}

// ---------------------------------------------------------------------------
// Component: image → transform → re-encode
// ---------------------------------------------------------------------------

///|
test "component: decode BMP, brighten, re-encode, re-decode preserves size" {
  let src = comp_bmp_1x1_black_24bpp()
  let original = @image.decode(src) catch { _ => fail("decode fixture failed") }
  let brightened = original.brighten(128)
  let bytes = @image.encode_bmp(brightened)
  let roundtrip = @image.decode(bytes) catch {
    _ => fail("decode round-trip failed")
  }
  assert_eq(roundtrip.width, original.width)
  assert_eq(roundtrip.height, original.height)
}

///|
test "component: decode QOI → grayscale → encode BMP → dimensions match" {
  // The labeler pipeline feeds images through to_grayscale() before
  // running OCR-style processing. Verify the encode side still emits
  // a valid BMP after the transform.
  let src = comp_qoi_1x1_red_rgba()
  let original = @image.decode(src) catch { _ => fail("decode fixture failed") }
  let gray = original.to_grayscale()
  let bytes = @image.encode_bmp(gray)
  let (w, h, fmt) = @image.image_dimensions(bytes) catch {
    _ => fail("image_dimensions on encoded bytes failed")
  }
  assert_eq(w, 1)
  assert_eq(h, 1)
  assert_eq(@image.image_format_name(fmt), "BMP")
}

// ---------------------------------------------------------------------------
// Component: image statistics on a known image
// ---------------------------------------------------------------------------

///|
test "component: histogram on a 1x1 red image sums to 1 pixel" {
  let src = comp_qoi_1x1_red_rgba()
  let img = @image.decode(src) catch { _ => fail("decode failed") }
  let hist = img.histogram()
  let total = hist.fold(init=0, fn(acc, b) { acc + b })
  assert_eq(total, 1)
  // The image has exactly one non-zero bucket (the luminance bin).
  let non_zero = hist.fold(init=0, fn(acc, b) { acc + (if b > 0 { 1 } else { 0 }) })
  assert_eq(non_zero, 1)
  // Sum of pixel-counts == 1 means there is exactly one populated bucket.
  let populated = hist.filter(fn(b) { b > 0 })
  assert_eq(populated.length(), 1)
}

// ---------------------------------------------------------------------------
// Component: label text round-trip through @labeler
// ---------------------------------------------------------------------------

///|
test "component: serialize_label_text then parse_label_text round-trip" {
  // Given a legacy-shape label (points as a semicolon-separated string)
  // using the canonical `img_name` field the normalizer reads.
  let legacy = "{\"img_name\":\"a.png\",\"infos\":[{\"label\":\"cat\",\"points\":\"0,0;10,10;20,20\"}]}"
  // When the frontend hands it to serialize_label_text (modern-schema upgrade)
  let (modern, err1) = @labeler.serialize_label_text(legacy) catch {
    _ => fail("serialize_label_text raised")
  }
  if err1 != "" {
    fail("serialize_label_text error: " + err1)
  }
  // And parse_label_text accepts the modernized text
  let (reparsed, err2) = @labeler.parse_label_text(modern, "a.png") catch {
    _ => fail("parse_label_text raised")
  }
  if err2 != "" {
    fail("parse_label_text error: " + err2)
  }
  // And the round-trip preserves the canonical schema markers
  assert_true(reparsed.contains("infos"))
  assert_true(reparsed.contains("img_name"))
  assert_true(reparsed.contains("[["))
}

///|
test "component: parse_label_text strips UTF-8 BOM before parsing" {
  // Given a label JSON prefixed with a UTF-8 BOM (U+FEFF)
  let bom = "\u{feff}{\"img_name\":\"a.png\",\"infos\":[]}"
  let (out, err) = @labeler.parse_label_text(bom, "a.png") catch {
    _ => fail("parse_label_text raised")
  }
  if err != "" {
    fail("parse_label_text error: " + err)
  }
  // Then the BOM is gone but the rest of the JSON survives
  assert_false(out.contains("\u{feff}"))
  assert_true(out.contains("img_name"))
}

// ---------------------------------------------------------------------------
// Component: image + labeler — the codec produces bytes the labeler can
// reason about without choking on the embedded metadata.
// ---------------------------------------------------------------------------

///|
test "component: image_dimensions on encoded BMP stays consistent" {
  // The labeler attaches annotations to images whose dimensions it
  // can read cheaply. Verify that image_dimensions on bytes coming
  // out of the codec still returns the expected BMP marker.
  let src = comp_bmp_1x1_black_24bpp()
  let img = @image.decode(src) catch { _ => fail("decode failed") }
  let encoded = @image.encode_bmp(img)
  let (w, h, fmt) = @image.image_dimensions(encoded) catch {
    _ => fail("image_dimensions raised on encoded bytes")
  }
  assert_eq(w, 1)
  assert_eq(h, 1)
  assert_eq(@image.image_format_name(fmt), "BMP")
}
