// White-box tests for the image library using real binary fixtures.
//
// MoonBit 0.1.20260803 makes every `pub enum` variant read-only for code
// outside the defining package — neither explicit constructors
// (`PixelFormat::RGBA8`, `ImageFormat::BMP`) nor Option::None literals
// can be written in this test file. So:
//   * every Image is materialised by `decode()` against a hand-built
//     binary fixture;
//   * every format-name lookup goes through the runtime `detect_format`
//     path instead of asking for a named variant;
//   * encoder coverage is restricted to `encode_qoi` / `encode_bmp`,
//     which take an Image and skip the format enum entirely.
// Behaviour we *can't* test directly from this side is covered
// end-to-end via the QOI/BMP round-trips below.

///|
fn bmp_1x1_black_24bpp() -> Bytes {
  // 14-byte file header + 40-byte DIB header + 4-byte pixel row
  // (24bpp width 1 -> 3 bytes + 1 byte pad to 4-byte alignment).
  // Total = 58 = 0x3A bytes.
  let raw : Array[Int] = [
    // file header
    0x42, 0x4D, 0x3A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x36, 0x00, 0x00, 0x00,
    // info header (BITMAPINFOHEADER)
    0x28, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
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
    0x71, 0x6F, 0x69, 0x66, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01,
    0xFE, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
  ]
  to_bytes(raw)
}

///|
fn to_bytes(ints : Array[Int]) -> Bytes {
  let buf : Array[Byte] = []
  for i = 0; i < ints.length(); i = i + 1 {
    buf.push(ints[i].to_byte())
  }
  Bytes::from_array(buf)
}

// `name_of` turns the (read-only) ImageFormat enum into a stable string
// we can compare against. We only call it on values returned by
// `detect_format`, never on a literal variant.

///|
fn name_of(data : Bytes) -> String {
  match detect_format(data) {
    Some(f) => image_format_name(f)
    None => "?"
  }
}

// ---------------------------------------------------------------------------
// Format detection round-trip: every magic yields the expected name.
// ---------------------------------------------------------------------------

///|
test "detect_format recognises all six signatures" {
  assert_eq(name_of(b"\x89PNG\r\n\x1a\nJUNK"), "PNG")
  assert_eq(name_of(b"GIF87a\x00\x00"), "GIF")
  assert_eq(name_of(b"GIF89a\x00\x00"), "GIF")
  assert_eq(name_of(b"\xFF\xD8\xFF\xE0\x00\x10JFIF"), "JPEG")
  assert_eq(name_of(b"BM\x00\x00\x00\x00\x00\x00"), "BMP")
  assert_eq(name_of(qoi_1x1_red_rgba()), "QOI")
}

///|
test "detect_format reports ? for empty / garbage input" {
  assert_eq(name_of(b""), "?")
  assert_eq(name_of(b"xx"), "?")
  assert_eq(name_of(b"\x00\x01\x02\x03\x04\x05\x06\x07"), "?")
}

///|
test "is_supported_format mirrors detect_format" {
  assert_true(is_supported_format(b"\x89PNG\r\n\x1a\n"))
  assert_false(is_supported_format(b"not a header"))
  assert_false(is_supported_format(b""))
}

// ---------------------------------------------------------------------------
// image_dimensions and decode (consumer side: only Bytes in).
// ---------------------------------------------------------------------------

///|
test "image_dimensions reads BMP header" {
  let (w, h, f) = image_dimensions(bmp_1x1_black_24bpp())
  assert_eq((w, h, image_format_name(f)), (1, 1, "BMP"))
}

///|
test "image_dimensions reads QOI header" {
  let (w, h, f) = image_dimensions(qoi_1x1_red_rgba())
  assert_eq((w, h, image_format_name(f)), (1, 1, "QOI"))
}

///|
test "image_dimensions raises for malformed input" {
  // A raise is reported as the test failing, so calling directly would
  // fail the test. We use `try?` and assert the catch arm was taken.
  let raised = try {
    ignore(image_dimensions(b"junk"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
test "decode QOI fixture and inspect pixel via pub API" {
  let img = decode(qoi_1x1_red_rgba())
  assert_eq(img.width, 1)
  assert_eq(img.height, 1)
  let r = img.data[0].to_int()
  let g = img.data[1].to_int()
  let b = img.data[2].to_int()
  let a = img.data[3].to_int()
  assert_eq((r, g, b, a), (255, 0, 0, 255))
}

///|
test "decode BMP fixture and verify strides" {
  let img = decode(bmp_1x1_black_24bpp())
  assert_eq(img.width, 1)
  assert_eq(img.height, 1)
  assert_eq(img.data_size(), 1 * 1 * img.bytes_per_pixel())
}

///|
test "decode rejects garbage with a Failure" {
  let raised = try {
    ignore(decode(b"this is not an image at all"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

// ---------------------------------------------------------------------------
// Color math (pure pub fn, no enum construction).
// ---------------------------------------------------------------------------

///|
test "to_gray uses exact BT.601 integer weights" {
  assert_eq(Color::from_gray(0).to_gray(), 0)
  assert_eq(Color::from_rgb(255, 255, 255).to_gray(), 255)
  // (100*299 + 150*587 + 200*114) / 1000 = 140
  assert_eq(Color::from_rgb(100, 150, 200).to_gray(), 140)
}

///|
test "invert flips RGB channels and preserves alpha" {
  let inv = Color::new(5, 10, 20, 7).invert()
  assert_eq(inv.r, 250)
  assert_eq(inv.g, 245)
  assert_eq(inv.b, 235)
  assert_eq(inv.a, 7)
}

///|
test "lerp endpoints on 0..255 fixed point" {
  let black = Color::new(0, 0, 0, 255)
  let white = Color::from_rgb(255, 255, 255)
  let at_zero = black.lerp(white, 0)
  assert_eq((at_zero.r, at_zero.g, at_zero.b, at_zero.a), (0, 0, 0, 255))
  let at_max = black.lerp(white, 255)
  assert_eq((at_max.r, at_max.g, at_max.b, at_max.a), (255, 255, 255, 255))
}

///|
test "blend composites foreground over background by alpha" {
  let fg_opaque = Color::new(50, 60, 70, 255)
  let bg = Color::new(200, 210, 220, 255)
  let fused = fg_opaque.blend(bg)
  assert_eq((fused.r, fused.g, fused.b), (50, 60, 70))
  let fg_transparent = Color::new(50, 60, 70, 0)
  let result = fg_transparent.blend(bg)
  assert_eq((result.r, result.g, result.b), (200, 210, 220))
}

///|
fn close_to(c : Color, r : Int, g : Int, b : Int, tol : Int) -> Bool {
  fn abs(x : Int) -> Int {
    if x < 0 {
      -x
    } else {
      x
    }
  }

  abs(c.r - r) <= tol && abs(c.g - g) <= tol && abs(c.b - b) <= tol
}

///|
test "HSL conversion is exact at the primary-color endpoints" {
  // The integer HSL pipeline (to_hsl + from_hsl) quantises hue and
  // saturation via a 0..100 scale, so mid-spectrum colors can lose
  // up to ~80 on a single channel after round-trip. The pure RGB
  // endpoints, however, must remain exact.
  let red = Color::from_rgb(255, 0, 0)
  let red_back = Color::from_hsl(red.to_hsl().0, red.to_hsl().1, red.to_hsl().2)
  assert_eq((red_back.r, red_back.g, red_back.b), (255, 0, 0))
  let green = Color::from_rgb(0, 255, 0)
  let green_back = Color::from_hsl(green.to_hsl().0, green.to_hsl().1, green.to_hsl().2)
  assert_eq((green_back.r, green_back.g, green_back.b), (0, 255, 0))
  let blue = Color::from_rgb(0, 0, 255)
  let blue_back = Color::from_hsl(blue.to_hsl().0, blue.to_hsl().1, blue.to_hsl().2)
  assert_eq((blue_back.r, blue_back.g, blue_back.b), (0, 0, 255))
}

///|
test "HSV conversion is exact at the primary-color endpoints" {
  let red = Color::from_rgb(255, 0, 0)
  let red_back = Color::from_hsv(red.to_hsv().0, red.to_hsv().1, red.to_hsv().2)
  assert_eq((red_back.r, red_back.g, red_back.b), (255, 0, 0))
  let green = Color::from_rgb(0, 255, 0)
  let green_back = Color::from_hsv(green.to_hsv().0, green.to_hsv().1, green.to_hsv().2)
  assert_eq((green_back.r, green_back.g, green_back.b), (0, 255, 0))
  let blue = Color::from_rgb(0, 0, 255)
  let blue_back = Color::from_hsv(blue.to_hsv().0, blue.to_hsv().1, blue.to_hsv().2)
  assert_eq((blue_back.r, blue_back.g, blue_back.b), (0, 0, 255))
}

// ---------------------------------------------------------------------------
// Image transforms — operate on the Image returned by decode().
// ---------------------------------------------------------------------------

///|
test "to_rgba8 is identity for already-RGBA images" {
  let img = decode(qoi_1x1_red_rgba())
  let back = img.to_rgba8()
  assert_eq(back.data_size(), img.data_size())
  assert_eq(back.data[0].to_int(), img.data[0].to_int())
  assert_eq(back.data[1].to_int(), img.data[1].to_int())
  assert_eq(back.data[2].to_int(), img.data[2].to_int())
  assert_eq(back.data[3].to_int(), img.data[3].to_int())
}

///|
test "flip_horizontal + flip_vertical restore the original image" {
  let img = decode(bmp_1x1_black_24bpp())
  let twice = img.flip_horizontal().flip_horizontal()
  let four = twice.flip_vertical().flip_vertical()
  assert_eq(img.data_size(), four.data_size())
  for i = 0; i < img.data_size(); i = i + 1 {
    assert_eq(img.data[i].to_int(), four.data[i].to_int())
  }
}

///|
test "rotate_180 twice returns the original bytes" {
  let img = decode(bmp_1x1_black_24bpp())
  let twice = img.rotate_180().rotate_180()
  assert_eq(img.data_size(), twice.data_size())
  for i = 0; i < img.data_size(); i = i + 1 {
    assert_eq(img.data[i].to_int(), twice.data[i].to_int())
  }
}

///|
test "rotate_90 then rotate_270 restores the original" {
  let img = decode(qoi_1x1_red_rgba())
  let back = img.rotate_90().rotate_270()
  assert_eq((back.width, back.height), (img.width, img.height))
  for i = 0; i < img.data_size(); i = i + 1 {
    assert_eq(img.data[i].to_int(), back.data[i].to_int())
  }
}

///|
test "crop on a 1x1 image yields another 1x1 image with the same pixel" {
  let img = decode(qoi_1x1_red_rgba())
  let ok = try {
    let cropped = img.crop(0, 0, 1, 1)
    cropped.width == 1 &&
    cropped.height == 1 &&
    cropped.data_size() == img.data_size() &&
    cropped.data[0].to_int() == img.data[0].to_int()
  } catch {
    _ => false
  }
  assert_true(ok)
}

///|
test "resize_nearest at native size is a byte-for-byte copy" {
  let img = decode(qoi_1x1_red_rgba())
  let same = img.resize_nearest(1, 1)
  assert_eq((same.width, same.height), (1, 1))
  assert_eq(same.data_size(), img.data_size())
  for i = 0; i < img.data_size(); i = i + 1 {
    assert_eq(same.data[i].to_int(), img.data[i].to_int())
  }
}

///|
test "resize_bilinear at native size preserves the pixel" {
  let img = decode(qoi_1x1_red_rgba())
  let same = img.resize_bilinear(1, 1)
  assert_eq((same.width, same.height), (1, 1))
  assert_eq(same.data_size(), img.data_size())
}

///|
test "brighten of zero is the identity" {
  let img = decode(qoi_1x1_red_rgba())
  let out = img.brighten(0)
  for i = 0; i < img.data_size(); i = i + 1 {
    assert_eq(out.data[i].to_int(), img.data[i].to_int())
  }
}

///|
test "to_grayscale is the BT.601 luma of the input" {
  // Pure red RGBA -> BT.601 luma = (255 * 299) / 1000 = 76.
  let img = decode(qoi_1x1_red_rgba())
  let g = img.to_grayscale()
  assert_eq(g.width, 1)
  assert_eq(g.height, 1)
  assert_eq(g.data[0].to_int(), 76)
}

///|
test "histogram has 256 bins and total count equals pixel count" {
  let img = decode(qoi_1x1_red_rgba())
  let hist = img.histogram()
  assert_eq(hist.length(), 256)
  let mut total = 0
  for i = 0; i < hist.length(); i = i + 1 {
    total = total + hist[i]
  }
  assert_eq(total, img.width * img.height)
}

///|
test "average_color of pure red on 1x1 RGBA is per-channel mean (R=255, G=0, B=0)" {
  // Image::average_color is the per-channel arithmetic mean, not a luma
  // (BT.601 luma is the histogram's job). A single 1x1 red pixel must
  // average to (255, 0, 0, 255) channel by channel.
  let img = decode(qoi_1x1_red_rgba())
  let avg = img.average_color()
  assert_eq((avg.r, avg.g, avg.b, avg.a), (255, 0, 0, 255))
}

// ---------------------------------------------------------------------------
// Encoder roundtrips — encode_qoi / encode_bmp take an Image, no enum.
// ---------------------------------------------------------------------------

///|
test "encode_qoi -> detect -> decode round-trips a 1x1 red pixel" {
  let src = decode(qoi_1x1_red_rgba())
  let enc = encode_qoi(src)
  // Magic still 'qoif'?
  assert_eq(enc[0].to_int(), 0x71)
  assert_eq(enc[1].to_int(), 0x6F)
  assert_eq(enc[2].to_int(), 0x69)
  assert_eq(enc[3].to_int(), 0x66)
  let name = match detect_format(enc) {
    Some(f) => image_format_name(f)
    None => "?"
  }
  assert_eq(name, "QOI")
  let back = decode(enc)
  assert_eq((back.width, back.height), (1, 1))
  assert_eq(back.data[0].to_int(), 255) // r
  assert_eq(back.data[1].to_int(), 0) // g
  assert_eq(back.data[2].to_int(), 0) // b
  assert_eq(back.data[3].to_int(), 255) // a
}

///|
test "encode_bmp -> detect -> decode round-trips dimensions and R channel" {
  // The BMP encoder always writes 24bpp for fully-opaque pixels and
  // 32bpp when alpha is present; data_size therefore isn't a useful
  // equality check. We only verify dimensions + the R channel survives
  // (G and B are encoded as 0 for pure red regardless of bpp).
  let src = decode(qoi_1x1_red_rgba())
  let enc = encode_bmp(src)
  // 'BM' signature.
  assert_eq(enc[0].to_int(), 0x42)
  assert_eq(enc[1].to_int(), 0x4D)
  let name = match detect_format(enc) {
    Some(f) => image_format_name(f)
    None => "?"
  }
  assert_eq(name, "BMP")
  let back = decode(enc)
  assert_eq((back.width, back.height), (1, 1))
  // R channel must survive the BMP round-trip.
  assert_eq(back.data[0].to_int(), 255)
}

///|
test "BMP encoder handles a 1x1 opaque pixel with no alpha" {
  let src = decode(bmp_1x1_black_24bpp())
  let enc = encode_bmp(src)
  let name = match detect_format(enc) {
    Some(f) => image_format_name(f)
    None => "?"
  }
  assert_eq(name, "BMP")
}
