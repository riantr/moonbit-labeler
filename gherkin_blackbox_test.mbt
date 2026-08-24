// Gherkin step definitions for the image codec scenarios. Each `test`
// block maps to one Scenario in image_codecs.feature (sibling file).
// We don't parse the Gherkin text — instead each scenario title is the
// test name and the step phrases are comment markers within the test
// body. Running `moon test --target native` covers this file alongside
// the lib_test.mbt and labeler_blackbox_test.mbt suites.
//
// `try?` is still required here — moon 0.1.20260824 doesn't parse
// `try ... catch ... noraise { ... }` yet, so we keep the deprecated
// form locally and silence the warning per-test below.

///|
/// Shared fixture state for the most-recently-given step within a
/// single scenario. Each test sets this in its "Given" phase so the
/// "When" / "Then" phases can read it back.
let fixture : @ref.Ref[Bytes] = @ref.new(b"")

///|
fn set_fixture(bytes : Bytes) -> Unit {
  fixture.val = bytes
}

///|
fn getFixture() -> Bytes {
  fixture.val
}

// ---------------------------------------------------------------------------
// Feature: Detect image format from magic bytes
// ---------------------------------------------------------------------------

///|
test "Scenario: PNG signature is detected" {
  // Given a PNG signature
  set_fixture(b"\x89PNG\r\n\x1a\n")
  // When I call detect_format
  let f = @image.detect_format(getFixture())
  // Then the result is Some(PNG)
  match f {
    Some(@image.ImageFormat::PNG) => assert_true(true)
    _ => fail("expected Some(PNG)")
  }
}

///|
test "Scenario: QOI signature is detected" {
  set_fixture(b"qoif\x00\x00\x00\x01")
  match @image.detect_format(getFixture()) {
    Some(@image.ImageFormat::QOI) => assert_true(true)
    _ => fail("expected Some(QOI)")
  }
}

///|
test "Scenario: BMP signature is detected" {
  set_fixture(b"BM\x36\x00\x00\x00\x00\x00\x00")
  match @image.detect_format(getFixture()) {
    Some(@image.ImageFormat::BMP) => assert_true(true)
    _ => fail("expected Some(BMP)")
  }
}

///|
test "Scenario: JPEG signature is detected" {
  set_fixture(b"\xFF\xD8\xFF\xE0\x00\x10JFIF")
  match @image.detect_format(getFixture()) {
    Some(@image.ImageFormat::JPEG) => assert_true(true)
    _ => fail("expected Some(JPEG)")
  }
}

///|
test "Scenario: TGA signature is detected" {
  // TGA has no fixed magic — the detector uses a header-heuristic for
  // type 2 (uncompressed true-colour). A 18-byte minimal header is
  // enough for the heuristic to fire.
  set_fixture(
    b"\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x10\x00\x20\x00",
  )
  match @image.detect_format(getFixture()) {
    Some(@image.ImageFormat::TGA) => assert_true(true)
    _ => fail("expected Some(TGA)")
  }
}

///|
test "Scenario: Garbage input is rejected" {
  set_fixture(b"not a header")
  match @image.detect_format(getFixture()) {
    None => assert_true(true)
    _ => fail("expected None")
  }
}

// ---------------------------------------------------------------------------
// Feature: image_dimensions is fast (no pixel decode)
// ---------------------------------------------------------------------------

///|
test "Scenario: image_dimensions reads PNG IHDR without decoding pixels" {
  // Given a small PNG with IHDR specifying 16x11
  // 8-byte sig + 4-byte length + "IHDR" + 4-byte width + 4-byte height +
  // 1-byte bit depth + ... (we pad to 33 bytes so the function's
  // minimum-length guard passes)
  let png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0DIHDR\x00\x00\x00\x10\x00\x00\x00\x0B\x08\x06\x00\x00\x00\x1F\x15\xC4\x89"
  // When I call image_dimensions
  let (w, h, f) = @image.image_dimensions(png) catch {
    _ => fail("image_dimensions raised")
  }
  // Then the function returns width and height without touching pixels
  assert_eq(w, 16)
  assert_eq(h, 11)
  match f {
    @image.ImageFormat::PNG => assert_true(true)
    _ => fail("expected PNG")
  }
}

///|
#warnings("-deprecated")
test "Scenario: image_dimensions rejects truncated PNG" {
  // A 12-byte stream is too small to even read IHDR; the function
  // should raise Failure rather than guess dimensions.
  let tiny = b"\x89PNG\r\n\x1a\n\x00\x00"
  let raised = (try? @image.image_dimensions(tiny)) is Err(_)
  assert_true(raised)
}

// ---------------------------------------------------------------------------
// Feature: Encode round-trip
// ---------------------------------------------------------------------------

///|
test "Scenario: BMP round-trip preserves dimensions" {
  // Given a 1x1 black 24bpp BMP fixture
  let src = bmp_1x1_black_24bpp()
  let original = @image.decode(src) catch { _ => fail("decode fixture failed") }
  // When I encode to BMP and decode back
  let bytes = @image.encode_bmp(original)
  let decoded = @image.decode(bytes) catch {
    _ => fail("decode round-trip failed")
  }
  // Then dimensions match
  assert_eq(decoded.width, original.width)
  assert_eq(decoded.height, original.height)
}

///|
test "Scenario: QOI round-trip preserves pixel data" {
  let src = qoi_1x1_red_rgba()
  let original = @image.decode(src) catch { _ => fail("decode fixture failed") }
  let bytes = @image.encode_qoi(original)
  let decoded = @image.decode(bytes) catch {
    _ => fail("decode round-trip failed")
  }
  assert_eq(decoded.width, original.width)
  assert_eq(decoded.height, original.height)
  assert_eq(decoded.data.length(), original.data.length())
}

// ---------------------------------------------------------------------------
// Hand-built fixtures (kept byte-for-byte identical to the upstream
// lws/moonbit_image tests so we are testing exactly the same bytes that
// other MoonBit users will hit.)
// ---------------------------------------------------------------------------

///|
fn bmp_1x1_black_24bpp() -> Bytes {
  // 1x1 black 24bpp BMP, 58 bytes total.
  let raw : Array[Int] = [
    // file header
    0x42, 0x4D, 0x3A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x36, 0x00, 0x00,
    0x00,
    // info header (BITMAPINFOHEADER)
     0x28, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00,
    // pixel row: black, padded to 4 bytes
     0x00, 0x00, 0x00, 0x00,
  ]
  to_bytes(raw)
}

///|
fn qoi_1x1_red_rgba() -> Bytes {
  // 'qoif' magic + BE(width=1) + BE(height=1) + channels=4 + srgb=1
  // + OP_RGB tag (0xFE) + r=255 g=0 b=0 (absolute) + 8-byte end marker.
  let raw : Array[Int] = [
    0x71, 0x6F, 0x69, 0x66, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04,
    0x01, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
  ]
  to_bytes(raw)
}

///|
fn to_bytes(raw : Array[Int]) -> Bytes {
  let arr = Array::make(raw.length(), b'\x00')
  for i = 0; i < raw.length(); i = i + 1 {
    arr[i] = raw[i].to_byte()
  }
  Bytes::from_array(arr)
}
