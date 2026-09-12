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
// Component: derive_label_dir_from_image_dir
//
// The export ops (op_export_voc_folder, op_export_yolo_folder) use this
// pure helper to find the label dir to scan. The old `derive_label_dir_for_scan`
// had a Case-2 fallback that re-interpreted the input dir as a file via
// `image_path_to_label_path` and returned the **parent** of the image
// dir as the label dir — so the export ops silently found no labels
// and reported `exported_count: 0` whenever the user worked in a flat
// folder without the `Image@<name>` / `Label@<name>` convention. The
// pure helper now returns the in-folder dir directly in that case.
// ---------------------------------------------------------------------------

///|
test "component: derive_label_dir_from_image_dir maps Image@X/ to Label@X/" {
  let got = @labeler.derive_label_dir_from_image_dir("D:/datasets/Image@CARS.Part.01")
  assert_eq(got, "D:/datasets/Label@CARS.Part.01")
}

///|
test "component: derive_label_dir_from_image_dir keeps in-folder as-is" {
  // The user dropped photos in a flat folder. The export must
  // scan the same folder for .json files, not its parent.
  let got = @labeler.derive_label_dir_from_image_dir("D:/data/photos")
  assert_eq(got, "D:/data/photos")
}

///|
test "component: derive_label_dir_from_image_dir handles Image@X at FS root" {
  // No leading parent — result must not have a leading separator.
  let got = @labeler.derive_label_dir_from_image_dir("Image@CARS")
  assert_eq(got, "Label@CARS")
}

///|
test "component: derive_label_dir_from_image_dir keeps single-segment in-folder as-is" {
  let got = @labeler.derive_label_dir_from_image_dir("photos")
  assert_eq(got, "photos")
}

///|
test "component: derive_label_dir_from_image_dir accepts Windows backslash separator" {
  let got = @labeler.derive_label_dir_from_image_dir("D:\\datasets\\Image@CARS")
  assert_eq(got, "D:\\datasets\\Label@CARS")
}

///|
test "component: derive_label_dir_from_image_dir preserves dot in Image@<rest> leaf" {
  // CARS-style dataset names with dots in the leaf must round-trip
  // verbatim — only the leading `Image@` is stripped, the rest
  // (including the dot) is preserved. (Note: the function is called
  // with the resolved image dir, not a file path, so the leaf is
  // the trailing segment — no extra "/2024" suffix here.)
  let got = @labeler.derive_label_dir_from_image_dir("D:/data/Image@CARS.Part.01")
  assert_eq(got, "D:/data/Label@CARS.Part.01")
}

///|
test "component: derive_label_dir_from_image_dir treats Image@-less deep tree as in-folder" {
  // A nested dir that does NOT start with `Image@` is in-folder,
  // even if the parent happens to.
  let got = @labeler.derive_label_dir_from_image_dir("D:/data/photos/day-2024-01-15")
  assert_eq(got, "D:/data/photos/day-2024-01-15")
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

// ---------------------------------------------------------------------------
// Component: write_label error propagation
//
// `op_write_label` calls `ensure_dir` to materialise `Label@<name>/` on
// the first save. Before this fix, the underlying `@fs.mkdir` failure
// was silently swallowed (`catch { _ => () }`), so a write to a
// read-only / blocked / non-existent parent surfaced as a generic
// "write_label failed: <@os_error>" coming from the subsequent
// `@fs.write_file` call. Users couldn't tell whether the label
// directory was un-creatable or the file was un-writable.
//
// These two tests lock the new contract:
//   1. The happy path — `Label@<name>/` is auto-created on first save
//      and the file round-trips through `read_label`.
//   2. The error path — when the directory cannot be created, the
//      raised message starts with
//      "write_label: cannot create label directory '<path>':" so the
//      frontend can distinguish it from a later write failure.
//
// We use `_build/labeler_write_test_*/` (gitignored) as fresh
// sandboxes per test, so the two scenarios don't interfere.
// ---------------------------------------------------------------------------

///|
/// Recursively remove `path` whether it's a file, a symlink, or a
/// directory tree. `@fs.rmdir` is non-recursive and `@fs.remove`
/// only handles files, so we walk the tree ourselves. Idempotent
/// (silently no-ops on a missing path).
///
/// We avoid `@fs.kind` because its non-`Directory` variant names
/// differ between targets and we don't need fine-grained type
/// discrimination: a path is either enumerable (directory) or it
/// isn't, and `readdir` reliably raises on the latter.
async fn rm_rf(path : String) -> Unit {
  let exists = @fs.exists(path) catch {
    _ => false
  }
  if !exists {
    return
  }
  // Probe with readdir; if it raises the path is a file (or a
  // broken symlink, etc.), which we just remove directly.
  let probe = try {
    ignore(@fs.readdir(path))
    true
  } catch {
    _ => false
  }
  if !probe {
    @fs.remove(path) catch {
      _ => ()
    }
    return
  }
  let names = @fs.readdir(path) catch {
    _ => []
  }
  for n in names {
    // Forward-slash join works on both Windows and POSIX; the
    // async fs normalises the separator internally.
    rm_rf(path + "/" + n)
  }
  @fs.rmdir(path) catch {
    _ => ()
  }
}

///|
async test "component: dispatch_op write_label auto-creates Label@X/ and round-trips through read_label" {
  // The root of the work dir for this test. Distinct from the failure
  // test's root so the two cases can run side-by-side.
  let root = "_build/labeler_write_test_ok"
  rm_rf(root)
  let image_path = root + "/Image@CARS/1800003_0.jpg"
  let content = "{\"img_name\":\"1800003_0.jpg\",\"infos\":[]}"
  let write_req : Json = { "image_path": image_path, "content": content }
  let write_reply = @labeler.dispatch_op("write_label", write_req) catch {
    e => fail("write_label raised unexpectedly: " + e.to_string())
  }
  // The reply must report the sibling Label@<name>/<file>.json path.
  let label_path = match write_reply {
    { "label_path": String(s), .. } => s
    _ =>
      fail(
        "write_label reply missing label_path: " + write_reply.stringify(),
      )
  }
  assert_eq(label_path, root + "/Label@CARS/1800003_0.json")
  // The bytes count must match the UTF-8 length of the content.
  let expected_bytes = content.length()
  let got_bytes = match write_reply {
    { "bytes": Number(n, ..), .. } => n.to_int()
    _ => fail("write_label reply missing bytes: " + write_reply.stringify())
  }
  assert_eq(got_bytes, expected_bytes)
  // And the file must actually be on disk + readable back through
  // read_label. This proves ensure_dir did its job (created the dir)
  // AND that write_file produced a valid UTF-8 file the JSON parser
  // can re-read.
  let read_req : Json = { "image_path": image_path }
  let read_reply = @labeler.dispatch_op("read_label", read_req) catch {
    e => fail("read_label raised unexpectedly: " + e.to_string())
  }
  // found must be true (we just wrote it) and content must match.
  let found = match read_reply {
    { "found": True, .. } => true
    { "found": False, .. } =>
      fail("read_label returned found=false right after write_label")
    _ => fail("read_label reply missing found: " + read_reply.stringify())
  }
  let got_content = match read_reply {
    { "content": String(s), .. } => s
    _ => fail("read_label reply missing content: " + read_reply.stringify())
  }
  assert_true(found)
  assert_eq(got_content, content)
  rm_rf(root)
}

///|
async test "component: dispatch_op write_label raises 'cannot create label directory' when a file blocks Label@X" {
  // Set up a sandbox where the Label@<name> dir *cannot* be created:
  // we pre-place a regular file at the exact path `ensure_dir` will
  // try to use as a directory. `@fs.mkdir(..., recursive=true)` fails
  // on both Windows and POSIX when one of the path components is a
  // file rather than a directory, which is exactly the "blocked"
  // scenario we want the error message to cover.
  let root = "_build/labeler_write_test_blocked"
  rm_rf(root)
  // Make the parent dir, then drop a regular file at the spot
  // `Label@<name>` would need to be a directory.
  @fs.mkdir(root, recursive=true) catch {
    e => fail("test setup: mkdir root failed: " + e.to_string())
  }
  let blocker = root + "/Label@BLOCKED"
  @fs.write_file(blocker, b"not a dir", create_mode=@fs.CreateOrTruncate) catch {
    e => fail("test setup: write_file blocker failed: " + e.to_string())
  }
  // image_path_to_label_path(".../Image@BLOCKED/...") → ".../Label@BLOCKED/..."
  // — same name as the blocker file, so the mkdir inside op_write_label
  // must fail.
  let image_path = root + "/Image@BLOCKED/1800003_0.jpg"
  let write_req : Json = {
    "image_path": image_path,
    "content": "{\"img_name\":\"x.jpg\",\"infos\":[]}",
  }
  // The contract: the raised error must start with
  // "write_label: cannot create label directory '<path>':" so the
  // frontend can distinguish it from a later write failure.
  try {
    let _ = @labeler.dispatch_op("write_label", write_req)
    fail("write_label should have raised but returned normally")
  } catch {
    e => {
      let msg = e.to_string()
      assert_true(
        msg.contains("write_label: cannot create label directory"),
      )
      // The reported label_dir must be the one we tried to create, not
      // an empty string or the parent. Comparing against the absolute
      // blocker path locks the message to the exact directory that
      // failed.
      assert_true(msg.contains(blocker))
    }
  }
  rm_rf(root)
}

// ---------------------------------------------------------------------------
// Component: end-to-end save flow with real image files on disk
//
// The two write_label tests above exercise `op_write_label` in
// isolation against synthetic JSON paths. They catch the
// "ensure_dir swallowed the mkdir error" bug and the "label_path
// wrong" bug, but they do not prove that the *full* dispatch_op
// chain works against actual image bytes: list_images must discover
// real files, read_image must hand them back, and write_label must
// land the label JSON next to them. This test drops a real BMP file
// on disk, walks list_images → read_image → write_label → read_label
// end-to-end, and verifies both the dispatch_op replies and the
// bytes on disk.
//
// The test image is hand-crafted (2×2 BGRA, all 4 pixels distinct)
// rather than generated through @moonbit_image.encode — the encoder
// is fine, but `ImageFormat::*` and `PixelFormat::*` variants are
// read-only outside the package, so a one-off test would have to
// monkey-patch the public API. A 70-byte BMP literal is more
// honest about what the test needs and is easier to audit. BMP is
// lossless so a successful read_image round-trip is conclusive.
// ---------------------------------------------------------------------------

///|
/// A 2×2 RGBA BMP. 4 distinct pixels (red / green / blue / yellow),
/// so any byte-level corruption in the round-trip will flip a
/// non-equal pair. The whole file is 70 bytes:
///
///   14-byte file header + 40-byte DIB header + 16-byte pixel data.
///
/// Pixels are stored bottom-to-top, BGRA, with no row padding needed
/// for 32-bit alignment.
fn sample_bmp_bytes() -> Bytes {
  // [file header 14][DIB header 40][pixels 16]
  let raw : Array[Int] = [
    0x42, 0x4D,                          //  0  "BM"
    0x46, 0x00, 0x00, 0x00,              //  2  file size = 70
    0x00, 0x00, 0x00, 0x00,              //  6  reserved
    0x36, 0x00, 0x00, 0x00,              // 10  pixel offset = 54
    0x28, 0x00, 0x00, 0x00,              // 14  DIB header size = 40
    0x02, 0x00, 0x00, 0x00,              // 18  width = 2
    0x02, 0x00, 0x00, 0x00,              // 22  height = 2
    0x01, 0x00,                          // 26  planes = 1
    0x20, 0x00,                          // 28  bits per pixel = 32
    0x00, 0x00, 0x00, 0x00,              // 30  compression = BI_RGB
    0x10, 0x00, 0x00, 0x00,              // 34  image size = 16
    0x00, 0x00, 0x00, 0x00,              // 38  x ppm
    0x00, 0x00, 0x00, 0x00,              // 42  y ppm
    0x00, 0x00, 0x00, 0x00,              // 46  colors used
    0x00, 0x00, 0x00, 0x00,              // 50  important colors
    // pixel data, bottom row then top row, BGRA per pixel
    0xFF, 0x00, 0x00, 0xFF,              // 54  (0,0) bottom-left  blue
    0x00, 0xFF, 0xFF, 0xFF,              // 58  (1,0) bottom-right yellow
    0x00, 0x00, 0xFF, 0xFF,              // 62  (0,1) top-left    red
    0x00, 0xFF, 0x00, 0xFF,              // 66  (1,1) top-right   green
  ]
  bytes_from(raw)
}

///|
/// Tiny base64 decoder for the BMP round-trip check. We hand-roll
/// this rather than pulling another dependency for one assertion.
/// Only handles the padded/unpadded standard alphabet our server
/// emits (the dispatch_op op_read_image response).
///
/// Output length rule (RFC 4648 §6):
///   - input length 4k           → 3k bytes
///   - input length 4k + 2       → 3k + 1 byte (1 byte of zero-pad)
///   - input length 4k + 3       → 3k + 2 bytes (1 byte of zero-pad)
///   - input length 4k + 1       → invalid (we don't expect this)
fn b64_decode(s : String) -> Bytes {
  // Map every base64 alphabet char to its 6-bit value, sentinel -1
  // for anything else (including padding).
  let idx = fn(c : Char) -> Int {
    let n = c.to_int()
    if n >= 65 && n <= 90 {
      n - 65
    } else if n >= 97 && n <= 122 {
      n - 71
    } else if n >= 48 && n <= 57 {
      n + 4
    } else if n == 43 {
      62
    } else if n == 47 {
      63
    } else {
      -1
    }
  }
  // Collect the non-padding chars; the input is well-formed base64
  // from the server so we don't need to defend against garbage.
  let chars : Array[Char] = []
  for c in s {
    if c != '=' {
      chars.push(c)
    }
  }
  let extra = chars.length() % 4
  let mut out_len = (chars.length() / 4) * 3
  if extra == 2 {
    out_len = out_len + 1
  } else if extra == 3 {
    out_len = out_len + 2
  }
  let out : Array[Int] = Array::make(out_len, 0)
  let mut bi = 0
  let mut i = 0
  while i + 4 <= chars.length() {
    let a = idx(chars[i])
    let b = idx(chars[i + 1])
    let c = idx(chars[i + 2])
    let d = idx(chars[i + 3])
    out[bi] = (a << 2) | (b >> 4)
    bi = bi + 1
    out[bi] = ((b & 0xF) << 4) | (c >> 2)
    bi = bi + 1
    out[bi] = ((c & 0x3) << 6) | d
    bi = bi + 1
    i = i + 4
  }
  // Handle the trailing 1-3 chars (post-pad). `extra` of 2 means
  // 1 byte of source data (plus 2 bits of zero-pad); 3 means 2
  // bytes (plus 1 bit of zero-pad).
  if extra == 2 {
    let a = idx(chars[i])
    let b = idx(chars[i + 1])
    out[bi] = (a << 2) | (b >> 4)
  } else if extra == 3 {
    let a = idx(chars[i])
    let b = idx(chars[i + 1])
    let c = idx(chars[i + 2])
    out[bi] = (a << 2) | (b >> 4)
    bi = bi + 1
    out[bi] = ((b & 0xF) << 4) | (c >> 2)
  }
  bytes_from(out)
}

///|
async test "component: e2e — list_images + read_image + write_label + read_label against a real BMP file" {
  // Sandbox: fresh tree under _build/ so reruns are deterministic.
  let root = "_build/labeler_e2e_test"
  rm_rf(root)
  let image_dir = root + "/Image@e2e"
  @fs.mkdir(image_dir, recursive=true) catch {
    e => fail("test setup: mkdir image_dir failed: " + e.to_string())
  }
  // Drop the real BMP on disk.
  let bmp_path = image_dir + "/sample.bmp"
  let bmp_bytes = sample_bmp_bytes()
  @fs.write_file(bmp_path, bmp_bytes, create_mode=@fs.CreateOrTruncate) catch {
    e => fail("test setup: write_file bmp failed: " + e.to_string())
  }
  // --- 1. list_images discovers the file ---
  let list_req : Json = {
    "path": image_dir,
    "extensions": ["bmp", "png", "jpg", "jpeg"],
  }
  let list_reply = @labeler.dispatch_op("list_images", list_req) catch {
    e => fail("list_images raised: " + e.to_string())
  }
  let names = match list_reply {
    { "images": Array(arr), .. } => arr
    _ => fail("list_images reply missing 'images' array: " + list_reply.stringify())
  }
  assert_eq(names.length(), 1)
  // list_images returns an array of { name, path, ext } objects, not
  // bare filename strings. Verify both fields to lock the contract.
  let entry = names[0]
  let (got_name, got_path) = match entry {
    { "name": String(n), "path": String(p), .. } => (n, p)
    _ => fail("list_images entry shape wrong: " + entry.stringify())
  }
  assert_eq(got_name, "sample.bmp")
  // The path separator is platform-specific (Windows: `\`, POSIX: `/`),
  // and the dispatch_op normalises to the native form. We just check
  // that the Image@e2e/ directory leaf and the filename appear in the
  // returned path, regardless of separator.
  assert_true(got_path.contains("Image@e2e"))
  assert_true(got_path.has_suffix("sample.bmp"))
  // --- 2. read_image returns the exact bytes ---
  let read_reply = @labeler.dispatch_op("read_image", { "path": bmp_path }) catch {
    e => fail("read_image raised: " + e.to_string())
  }
  let (b64, mime) = match read_reply {
    { "base64": String(s), "mime": String(m), "path": String(p), .. } => {
      assert_eq(p, bmp_path)
      (s, m)
    }
    _ => fail("read_image reply shape wrong: " + read_reply.stringify())
  }
  assert_eq(mime, "image/bmp")
  let bmp_back = b64_decode(b64)
  assert_eq(bmp_back.length(), bmp_bytes.length())
  // Byte-for-byte: the BMP round-trip must not corrupt a single byte.
  for i = 0; i < bmp_back.length(); i = i + 1 {
    if bmp_back[i] != bmp_bytes[i] {
      fail(
        "BMP round-trip byte mismatch at offset " +
        i.to_string() +
        ": " +
        bmp_back[i].to_string() +
        " != " +
        bmp_bytes[i].to_string(),
      )
    }
  }
  // --- 3. write_label lands the JSON in Label@e2e/sample.json ---
  let label_content =
    "{\"img_name\":\"sample.bmp\",\"width\":2,\"height\":2,\"infos\":[{\"id\":\"r1\",\"shape\":\"rect\",\"points\":[[0,0],[1,1]],\"class\":\"target\"}]}"
  let write_req : Json = {
    "image_path": bmp_path,
    "content": label_content,
  }
  let write_reply = @labeler.dispatch_op("write_label", write_req) catch {
    e => fail("write_label raised: " + e.to_string())
  }
  let label_path = match write_reply {
    { "label_path": String(s), "bytes": Number(n, ..), .. } => {
      assert_eq(n.to_int(), label_content.length())
      s
    }
    _ => fail("write_label reply shape wrong: " + write_reply.stringify())
  }
  // Convention: Image@e2e/sample.bmp → Label@e2e/sample.json. Anything
  // else is a path-derivation regression.
  assert_eq(label_path, root + "/Label@e2e/sample.json")
  // --- 4. read_label round-trips the exact content ---
  let read_label_req : Json = { "image_path": bmp_path }
  let read_label_reply = @labeler.dispatch_op("read_label", read_label_req) catch {
    e => fail("read_label raised: " + e.to_string())
  }
  let (got_content, got_label_path) = match read_label_reply {
    { "content": String(s), "found": True, "label_path": String(lp), .. } => (s, lp)
    { "found": False, .. } =>
      fail("read_label returned found=false right after write_label")
    _ =>
      fail(
        "read_label reply shape wrong: " + read_label_reply.stringify(),
      )
  }
  assert_eq(got_label_path, label_path)
  assert_eq(got_content, label_content)
  // --- 5. The label file must actually exist on disk and match. ---
  let on_disk = @fs.read_file(label_path) catch {
    e => fail("read_file label on disk failed: " + e.to_string())
  }
  assert_eq(on_disk.text(), label_content)
  // --- 6. Auto-save semantics: a second write_label with new content
  //         must overwrite the first write in place (CreateOrTruncate
  //         semantics) — no orphan files, no appended bytes. ---
  let label_v2 = "{\"img_name\":\"sample.bmp\",\"width\":2,\"height\":2,\"infos\":[]}"
  let _ = @labeler.dispatch_op("write_label", {
    "image_path": bmp_path,
    "content": label_v2,
  }) catch {
    e => fail("second write_label raised: " + e.to_string())
  }
  let on_disk_v2 = @fs.read_file(label_path) catch {
    e => fail("read_file label on disk v2 failed: " + e.to_string())
  }
  let on_disk_v2_text = on_disk_v2.text()
  assert_eq(on_disk_v2_text, label_v2)
  // File size must equal the new content's UTF-8 length, not v1's —
  // i.e., no bytes were appended or leaked.
  assert_eq(on_disk_v2_text.length(), label_v2.length())
  // And the Label@e2e/ directory must contain *only* this one file —
  // no second `sample (1).json` or similar leak.
  let dir_entries = @fs.readdir(root + "/Label@e2e") catch {
    e => fail("readdir Label@e2e failed: " + e.to_string())
  }
  assert_eq(dir_entries.length(), 1)
  assert_eq(dir_entries[0], "sample.json")
  rm_rf(root)
}
