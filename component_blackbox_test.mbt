// Component tests — exercise the interaction between two production
// modules: `extensions/image` (codec) and `extensions/labeler` (label
// schema normalizer). Each scenario validates that calling the public
// APIs across the package boundary yields the contract documented in
// `extensions/image/lib.mbt` and `extensions/labeler/labeler.mbt`.
//
// These tests run as a blackbox suite (`*_blackbox_test.mbt`) at the
// project root, so they see only the public surfaces: @moonbit_image.* and
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
  let original = @moonbit_image.decode(src) catch {
    _ => fail("decode fixture failed")
  }
  let brightened = original.brighten(128)
  let bytes = @moonbit_image.encode_bmp(brightened)
  let roundtrip = @moonbit_image.decode(bytes) catch {
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
  let original = @moonbit_image.decode(src) catch {
    _ => fail("decode fixture failed")
  }
  let gray = original.to_grayscale()
  let bytes = @moonbit_image.encode_bmp(gray)
  let (w, h, fmt) = @moonbit_image.image_dimensions(bytes) catch {
    _ => fail("image_dimensions on encoded bytes failed")
  }
  assert_eq(w, 1)
  assert_eq(h, 1)
  assert_eq(@moonbit_image.image_format_name(fmt), "BMP")
}

// ---------------------------------------------------------------------------
// Component: image statistics on a known image
// ---------------------------------------------------------------------------

///|
test "component: histogram on a 1x1 red image sums to 1 pixel" {
  let src = comp_qoi_1x1_red_rgba()
  let img = @moonbit_image.decode(src) catch { _ => fail("decode failed") }
  let hist = img.histogram()
  let total = hist.fold(init=0, fn(acc, b) { acc + b })
  assert_eq(total, 1)
  // The image has exactly one non-zero bucket (the luminance bin).
  let non_zero = hist.fold(init=0, fn(acc, b) {
    acc + (if b > 0 { 1 } else { 0 })
  })
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
  let img = @moonbit_image.decode(src) catch { _ => fail("decode failed") }
  let encoded = @moonbit_image.encode_bmp(img)
  let (w, h, fmt) = @moonbit_image.image_dimensions(encoded) catch {
    _ => fail("image_dimensions raised on encoded bytes")
  }
  assert_eq(w, 1)
  assert_eq(h, 1)
  assert_eq(@moonbit_image.image_format_name(fmt), "BMP")
}

// ---------------------------------------------------------------------------
// Component: label-path derivation
//
// `image_path_to_label_path` honors the `Image@<name>/Label@<name>` sibling
// convention when the parent folder matches, and falls back to in-folder
// `<basename>.json` otherwise. The in-folder case is the "user's folder is
// just a pile of photos" path — easy to lose if someone tidies the empty
// branch, so we lock both shapes here.
// ---------------------------------------------------------------------------

///|
test "component: image_path_to_label_path maps Image@X/<file>.jpg to Label@X/<file>.json" {
  let got = @labeler.image_path_to_label_path("D:/datasets/Image@CARS.Part.01/1800003_0.jpg")
  assert_eq(got, "D:/datasets/Label@CARS.Part.01/1800003_0.json")
}

///|
test "component: image_path_to_label_path maps Image@X/<file>.png to Label@X/<file>.json" {
  let got = @labeler.image_path_to_label_path("/home/user/Image@skin/abc.png")
  assert_eq(got, "/home/user/Label@skin/abc.json")
}

///|
test "component: image_path_to_label_path uses the parent dir when Image@ leaf is at root" {
  // When the Image@ folder is at the filesystem root, dir_parent is "",
  // so the result must not have a leading separator.
  let got = @labeler.image_path_to_label_path("Image@CARS/1800003_0.jpg")
  assert_eq(got, "Label@CARS/1800003_0.json")
}

///|
test "component: image_path_to_label_path keeps _0 suffix in the basename (CARS-style)" {
  // The `_0` is part of the original CARS filename, not a separate
  // index — the label name must mirror the basename verbatim.
  let got = @labeler.image_path_to_label_path("D:/x/Image@CARS/1800003_0.jpg")
  assert_eq(got, "D:/x/Label@CARS/1800003_0.json")
}

///|
test "component: image_path_to_label_path falls back to in-folder .json when dir leaf is not Image@<rest>" {
  // The user dropped a pile of photos in `data/photos/` without the
  // Image@/Label@ sibling convention. The label file must land
  // alongside the image so the user can save and load labels without
  // restructuring their directory tree.
  let got = @labeler.image_path_to_label_path("D:/data/photos/a.jpg")
  assert_eq(got, "D:/data/photos/a.json")
}

///|
test "component: image_path_to_label_path falls back to in-folder .json for bare folder names" {
  // A flat folder of photos (no Image@ prefix anywhere) should still
  // produce a usable label path. This is the "user just dropped a
  // bunch of JPGs in a folder" path.
  let got = @labeler.image_path_to_label_path("/home/user/pics/2024-01-15/IMG_0001.bmp")
  assert_eq(got, "/home/user/pics/2024-01-15/IMG_0001.json")
}

///|
test "component: image_path_to_label_path accepts Windows backslash paths" {
  // Native Windows builds hit `dir.contains("\\")` and use the
  // backslash as the separator. The result must round-trip cleanly.
  let got = @labeler.image_path_to_label_path("D:\\datasets\\Image@CARS\\a.jpg")
  assert_eq(got, "D:\\datasets\\Label@CARS\\a.json")
}

///|
test "component: image_path_to_label_path uses backslash for backslash input on Windows-style paths" {
  // Same as above but verifying the in-folder fallback picks up
  // the backslash separator when the input uses backslashes.
  let got = @labeler.image_path_to_label_path("D:\\photos\\a.jpg")
  assert_eq(got, "D:\\photos\\a.json")
}

///|
test "component: video_path_to_label_path mirrors the image rule for Video@X/<file>.mp4" {
  let got = @labeler.video_path_to_label_path("D:/datasets/Video@clip/run_001.mp4")
  assert_eq(got, "D:/datasets/Label@clip/run_001.json")
}

///|
test "component: video_path_to_label_path falls back to in-folder .json for non-Video@ dirs" {
  // Same in-folder fallback as the image path: a video dropped in
  // `data/raw/` gets its label next to it as `data/raw/foo.json`.
  let got = @labeler.video_path_to_label_path("D:/data/raw/clip_001.mkv")
  assert_eq(got, "D:/data/raw/clip_001.json")
}

// ---------------------------------------------------------------------------
// Component: parse_label / serialize_label IPC ops
//
// These two ops used to be missing from the bridge's op surface — the
// frontend `label.js` calls them on every save/load, and the bridge
// returned "bridge op is not registered", which the autosave catch
// block surfaced as the persistent "保存失败" badge. The pure helpers
// (`parse_label_text` / `serialize_label_text`) already existed, so
// the fix is to register thin IPC wrappers. This test exercises them
// through `dispatch_op` (the stdio JSON-RPC entry point) to lock the
// end-to-end wiring — `dispatch_op` is the same dispatcher the CEF
// bridge calls, so a green test here means the CEF op is wired.
// ---------------------------------------------------------------------------

///|
async test "component: dispatch_op parse_label normalizes legacy points string" {
  let req : Json = {
    "text": "{\"img_name\":\"a.png\",\"infos\":[{\"label\":\"cat\",\"points\":\"0,0;10,10;20,20\"}]}",
    "fallback_img_name": "fallback.png",
  }
  let reply = @labeler.dispatch_op("parse_label", req) catch {
    _ => fail("dispatch_op parse_label raised")
  }
  // Reply should be { label_text: "<normalized JSON>" } per the Reply
  // struct. Pull the label_text back out and verify the modern schema.
  let label_text = match reply {
    { "label_text": String(s), .. } => s
    _ => fail("parse_label reply missing label_text: " + reply.stringify())
  }
  assert_true(label_text.contains("\"infos\""))
  assert_true(label_text.contains("\"img_name\""))
  // The legacy `points: "x,y;x,y;..."` shape must be normalized to
  // nested arrays. If this regresses, the editor can't tell
  // keypoints from polygons downstream.
  assert_true(label_text.contains("[["))
}

///|
async test "component: dispatch_op serialize_label round-trips a modern label" {
  // The frontend hands in a label object JSON-stringified; the
  // normalizer must round-trip it back with the modern schema.
  let req : Json = {
    "label_text": "{\"img_name\":\"a.png\",\"infos\":[{\"id\":\"x\",\"shape\":\"rect\",\"type\":\"t\",\"points\":[[1.4,2.6],[3.5,4.7]]}]}",
  }
  let reply = @labeler.dispatch_op("serialize_label", req) catch {
    _ => fail("dispatch_op serialize_label raised")
  }
  let text = match reply {
    { "text": String(s), .. } => s
    _ => fail("serialize_label reply missing text: " + reply.stringify())
  }
  // Pixel coordinates must be rounded to integers on the way back out
  // (the on-disk schema is integer px, not float). 1.4 -> 1, 2.6 -> 3.
  assert_true(text.contains("[1,3]"))
  assert_true(text.contains("[4,5]"))
  // id and shape must be preserved
  assert_true(text.contains("\"id\":\"x\""))
  assert_true(text.contains("\"shape\":\"rect\""))
}
