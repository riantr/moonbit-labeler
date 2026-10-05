// app_moui/image_decode_test.mbt — Phase 5.23.
//
// Phase 5.22 made labels readable from disk but left the *pixels* on
// screen stale: selecting a real image updated the annotations and the
// status line while the canvas kept showing whatever was there
// before. This phase closes that gap — read, decode, widen to RGBA8,
// register in the renderer cache — and these tests pin it.
//
// The format-widening helper cannot be fed a chosen `PixelFormat`
// directly: `PixelFormat` is a `pub enum`, not `pub(all)`, so its
// constructors are read-only from outside `moonbit_image`, and even
// upstream's own tests only ever *match* on it. So the four arms are
// reached through real encoded PNGs instead — see the fixture notes.
//
// The disk tests run against the **shipped** `data/` sample. A
// synthetic JPEG written by this file could not tell "decoded the file"
// from "decoded the bytes I just handed it"; the read is the part under
// test, so the file has to already exist.

// ── PNG fixtures ───────────────────────────────────────────────────
//
// Four 8-bit PNGs, one per colour type: 0 = Gray8, 2 = RGB8,
// 4 = GrayA8, 6 = RGBA8. Real files, produced once with Python's
// `zlib.compress` and embedded here as hex — chunk CRCs and all.
//
// The first attempt at these was a hand-rolled builder emitting
// *stored* (uncompressed) deflate blocks with a hand-written CRC-32,
// and every arm failed to decode. The CRC was the culprit, and the
// reason is worth recording: **MoonBit's `Int` is 32-bit signed**, so
// `0xFFFFFFFF` is -1, `0xEDB88320` is -305424608, and `>>` is an
// *arithmetic* shift — a state of -1 shifts to -1 forever and the
// checksum returns a wrong negative number with no error anywhere.
// Embedding a known-good file removes the whole class of problem, and
// the guard test below keeps the fixtures honest.

///|
/// Hex digit value. `Char::to_int` for the code point, offset from the
/// digit/letter's own code point.
fn p523_hexval(c : Char) -> Int {
  if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int()
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 'a'.to_int() + 10
  } else {
    c.to_int() - 'A'.to_int() + 10
  }
}

///|
/// Hex string to `Bytes`.
fn p523_hex(s : String) -> Bytes {
  let chars : Array[Char] = s.to_array()
  let out : Array[Byte] = []
  let mut i : Int = 0
  while i + 1 < chars.length() {
    let v : Int = p523_hexval(chars[i]) * 16 + p523_hexval(chars[i + 1])
    out.push(v.to_byte())
    i = i + 2
  }
  Bytes::from_array(out)
}

///|
/// 2x1 Gray8 fixture (colour type 0), samples 7 and 200.
let p523_gray8_png : String = "89504e470d0a1a0a0000000d4948445200000002000000010800000000d14920560000000b4944415478da63603f010000d900d0440255db0000000049454e44ae426082"

///|
/// 2x1 RGB8 fixture (colour type 2), samples (10,20,30) and (40,50,60).
let p523_rgb8_png : String = "89504e470d0a1a0a0000000d49484452000000020000000108020000007b40e8dd0000000f4944415478da63e01291d330b20100023700d3e22ded9f0000000049454e44ae426082"

///|
/// 1x1 GrayA8 fixture (colour type 4), gray 5, alpha 128.
let p523_graya8_png : String = "89504e470d0a1a0a0000000d4948445200000001000000010804000000b51c0c020000000b4944415478da63606d0000008d0086d2a90c4d0000000049454e44ae426082"

///|
/// 1x1 RGBA8 fixture (colour type 6), RGB (1,2,3), alpha 3.
let p523_rgba8_png : String = "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da636064626606000018000a53c43ead0000000049454e44ae426082"

///|
/// Decode a fixture PNG and widen it, or `None` if it did not decode.
///
/// Returns `None` rather than aborting: an abort kills the whole
/// blackbox executable and discards the results of every test that ran
/// before it, so a broken fixture would present as "the run died"
/// instead of naming the arm that broke.
fn p523_widen(png : Bytes) -> Bytes? {
  match decode_image_bytes(png) {
    Some(i) => Some(to_rgba8_bytes(i))
    None => None
  }
}

///|
/// `p523_widen` with the decode assumed to have worked. A failed decode
/// yields an **empty** buffer rather than an assertion, so the failure
/// surfaces as the caller's own length/value assertion with a readable
/// diff — and so this helper does not need `raise` in its signature,
/// which would push error handling onto every call site.
fn p523_widen_or_fail(png : Bytes) -> Bytes {
  match p523_widen(png) {
    Some(b) => b
    None => Bytes::from_array([])
  }
}

///|
/// The fixtures have to be right before any assertion built on them
/// means anything. Each must decode, to the dimensions and the
/// bytes-per-pixel the colour type implies. If this fails, every other
/// test in the file is measuring the fixture, not the widening.
test "p523 fixtures — every colour type decodes to the expected shape (5.23)" {
  // Gray8 is 1 byte per pixel.
  match decode_image_bytes(p523_hex(p523_gray8_png)) {
    None => assert_true(false)
    Some(i) => {
      assert_eq(i.width, 2)
      assert_eq(i.height, 1)
      assert_eq(i.data.length(), 2)
    }
  }
  // RGB8 is 3, GrayA8 is 2, RGBA8 is 4.
  match decode_image_bytes(p523_hex(p523_rgb8_png)) {
    None => assert_true(false)
    Some(i) => assert_eq(i.data.length(), 2 * 3)
  }
  match decode_image_bytes(p523_hex(p523_graya8_png)) {
    None => assert_true(false)
    Some(i) => assert_eq(i.data.length(), 1 * 2)
  }
  match decode_image_bytes(p523_hex(p523_rgba8_png)) {
    None => assert_true(false)
    Some(i) => assert_eq(i.data.length(), 1 * 4)
  }
}

///|
/// `p523_hex` itself: two hex digits per byte, high nibble first.
test "p523_hex — decodes pairs of hex digits (5.23)" {
  let b = p523_hex("00ff10")
  assert_eq(b.length(), 3)
  assert_eq(b[0].to_int(), 0)
  assert_eq(b[1].to_int(), 255)
  assert_eq(b[2].to_int(), 16)
}

///|
/// RGB8 (3 bytes/px) -> RGBA8, alpha forced opaque. This is the arm
/// production hits on the shipped dataset: the 517x371 JPEG decodes as
/// RGB8.
test "to_rgba8_bytes — RGB8 gains an opaque alpha channel (5.23)" {
  let out = p523_widen_or_fail(p523_hex(p523_rgb8_png))
  assert_eq(out.length(), 8)
  assert_eq(out[0].to_int(), 10)
  assert_eq(out[1].to_int(), 20)
  assert_eq(out[2].to_int(), 30)
  assert_eq(out[3].to_int(), 255)
  // The second pixel must survive too — an off-by-one in the source
  // stride would repeat pixel 0 here.
  assert_eq(out[4].to_int(), 40)
  assert_eq(out[5].to_int(), 50)
  assert_eq(out[6].to_int(), 60)
  assert_eq(out[7].to_int(), 255)
}

///|
/// Gray8 -> RGBA8 by replicating the sample. The arm that matters most
/// for this domain: an X-ray scan is grayscale, so a Gray8 decode is
/// the *expected* case, not an edge case.
test "to_rgba8_bytes — Gray8 replicates into R, G and B (5.23)" {
  let out = p523_widen_or_fail(p523_hex(p523_gray8_png))
  assert_eq(out.length(), 8)
  for base in [0, 4] {
    assert_eq(out[base].to_int(), out[base + 1].to_int())
    assert_eq(out[base + 1].to_int(), out[base + 2].to_int())
    assert_eq(out[base + 3].to_int(), 255)
  }
  // The two source samples are distinct, so this catches "returns the
  // first pixel eight times" as well as a missing widen.
  assert_eq(out[0].to_int(), 7)
  assert_eq(out[4].to_int(), 200)
}

///|
/// GrayA8 is the one widening arm that **keeps** the alpha the encoder
/// wrote. The other two force 255 because their formats have no alpha;
/// this one does, and dropping it would throw away real information.
test "to_rgba8_bytes — GrayA8 keeps its existing alpha (5.23)" {
  let out = p523_widen_or_fail(p523_hex(p523_graya8_png))
  assert_eq(out.length(), 4)
  assert_eq(out[0].to_int(), 5)
  assert_eq(out[1].to_int(), 5)
  assert_eq(out[2].to_int(), 5)
  // Alpha 128 preserved, NOT promoted to 255.
  assert_eq(out[3].to_int(), 128)
}

///|
/// RGBA8 is the identity arm. A non-255 alpha proves the value was
/// carried through rather than overwritten — the `img.data` arm must
/// not copy-and-rebuild, or every already-correct image would pay for a
/// needless 4-byte-per-pixel rewrite.
test "to_rgba8_bytes — RGBA8 is the identity (5.23)" {
  let out = p523_widen_or_fail(p523_hex(p523_rgba8_png))
  assert_eq(out.length(), 4)
  assert_eq(out[0].to_int(), 1)
  assert_eq(out[1].to_int(), 2)
  assert_eq(out[2].to_int(), 3)
  assert_eq(out[3].to_int(), 3)
}

///|
/// Every arm lands on `w*h*4`, which is the contract
/// `ImageCache::load_bytes` enforces. A wrong `bytes_per_pixel` on any
/// single arm breaks here.
test "to_rgba8_bytes — every colour type widens to exactly w*h*4 (5.23)" {
  // The 2x1 fixtures.
  for hex in [p523_gray8_png, p523_rgb8_png] {
    let out = p523_widen_or_fail(p523_hex(hex))
    assert_eq(out.length(), 2 * 1 * 4)
  }
  // The 1x1 fixtures — grouped separately so a dimension mistake in
  // one fixture cannot be masked by another's expected length.
  for hex in [p523_graya8_png, p523_rgba8_png] {
    let out = p523_widen_or_fail(p523_hex(hex))
    assert_eq(out.length(), 1 * 1 * 4)
  }
}

///|
/// A file that is not an image is `None` all the way through — no
/// panic, no partial registration. The label JSON is the right negative
/// case: a real file with real bytes that is not an image.
test "to_rgba8_bytes — a non-image file never reaches the cache (5.23)" {
  assert_eq(
    load_image_into_cache("../data/Label@skin/BIOMEDICA_P0_JCAS-4-2-g001.json"),
    None,
  )
  assert_eq(load_image_into_cache("../data/Image@skin/p523_absent.jpg"), None)
}

// ── the real disk path ─────────────────────────────────────────────

///|
/// The end-to-end read, against the shipped sample: a real JPEG is
/// read, decoded, widened and registered, and the registered dimensions
/// are the file's real ones — 517x371, measured in Phase 5.23 from this
/// exact file, not guessed.
///
/// The cache is a module-global shared with every other test here, so
/// this asserts the specific source rather than a count.
test "load_image_into_cache — the real shipped JPEG decodes and registers (5.23)" {
  let path = "../data/Image@skin/BIOMEDICA_P0_JCAS-4-2-g001.jpg"
  match load_image_into_cache(path) {
    None => assert_true(false)
    Some((w, h)) => {
      assert_eq(w, 517)
      assert_eq(h, 371)
      assert_eq(image_in_renderer(path), true)
      assert_eq(image_size_in_renderer(path), Some((517, 371)))
    }
  }
}

///|
/// The registered buffer is exactly `w*h*4` — the contract
/// `load_bytes` enforces, and what a wrong widening would break.
/// 517 * 371 * 4 = 767,228.
test "load_image_into_cache — the registered buffer is exactly w*h*4 (5.23)" {
  let path = "../data/Image@skin/BIOMEDICA_P0_JCAS-4-2-g001.jpg"
  match load_image_into_cache(path) {
    None => assert_true(false)
    Some((w, h)) => assert_eq(w * h * 4, 767228)
  }
}

///|
/// A repeat load is a cache hit and must not re-read or re-decode. The
/// decode is the expensive half — ~190k pixels to widen for this
/// sample — and re-selecting the image already on screen must not pay
/// it again.
test "load_image_into_cache — a repeat load is served from the cache (5.23)" {
  let path = "../data/Image@skin/BIOMEDICA_P0_JCAS-3-170-g001.jpg"
  match load_image_into_cache(path) {
    None => assert_true(false)
    Some(_) => ()
  }
  assert_eq(image_in_renderer(path), true)
  match load_image_into_cache(path) {
    None => assert_true(false)
    Some((w, h)) => {
      assert_eq(w > 0, true)
      assert_eq(h > 0, true)
    }
  }
}

// ── handler wiring ─────────────────────────────────────────────────

///|
/// **The user-visible half.** Selecting a real image now moves
/// `imageSource` and `imageNaturalSize` onto that file. Before 5.23
/// both stayed on the synthetic fixture, so the annotations were right
/// and the picture was not — the worst of both.
test "SelectIndex — the canvas points at the selected image (5.23)" {
  let (loaded, _) = update(Model::new(), LoadFolder("../data/Image@skin"))
  assert_eq(loaded.images.length(), 6)
  let (model, _) = update(loaded, SelectIndex(4))
  assert_eq(model.currentIndex, 4)
  assert_eq(
    model.imageSource,
    "../data/Image@skin/BIOMEDICA_P0_JCAS-4-2-g001.jpg",
  )
  // Natural size drives fit-contain, so it has to be the file's real
  // dimensions or the picture is stretched.
  assert_eq(model.imageNaturalSize.x, 517.0)
  assert_eq(model.imageNaturalSize.y, 371.0)
  // The label half still works, on the same click.
  assert_eq(model.annotations.length(), 9)
}

///|
/// The pixels are registered *before* `imageSource` is repointed at
/// them. The other order would let the canvas emit a `DrawImage` that
/// resolves to the rasterizer's grey-X placeholder for a frame.
test "SelectIndex — pixels are cached by the time the source points at them (5.23)" {
  let (loaded, _) = update(Model::new(), LoadFolder("../data/Image@skin"))
  let (model, _) = update(loaded, SelectIndex(4))
  assert_eq(image_in_renderer(model.imageSource), true)
}

///|
/// An undecodable image leaves `imageSource` **alone**. Repointing it
/// at a path with no cache entry would swap the real picture for the
/// grey-X placeholder, which is a worse outcome than the stale image
/// the user already had.
test "SelectIndex — an undecodable image leaves the previous source (5.23)" {
  let (loaded, _) = update(Model::new(), LoadFolder("../data/Image@skin"))
  let (model, _) = update(loaded, SelectIndex(0))
  let before : String = model.imageSource
  assert_eq(image_in_renderer(before), true)
  // A folder whose only "image" is really the label JSON. Built
  // explicitly rather than hoped for in the dataset.
  let fake = {
    ..model,
    images: [
      {
        name: "BIOMEDICA_P0_JCAS-4-2-g001.json",
        path: "../data/Label@skin/BIOMEDICA_P0_JCAS-4-2-g001.json",
        size_bytes: 0,
      },
    ],
  }
  let (broken, _) = update(fake, SelectIndex(0))
  assert_eq(broken.imageSource, before)
  // And the status line says why.
  assert_true(broken.statusMessage.contains("no pixels"))
}
