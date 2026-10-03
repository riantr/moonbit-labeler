// app_moui/image_cache.mbt — Phase 13 in-memory image cache.
//
// Holds decoded RGBA8 images keyed by source string. The rasterizer
// asks the cache for an image by source path before each blit; the
// hot path is purely a Map lookup, no disk or codec work.
//
// Why a hand-rolled Map cache:
//
//  - Phase 11+ rasterizer runs synchronously inside the Moui render
//    callback. Re-decoding the same image every frame would 100%
//    stutter on any non-trivial canvas.
//  - Decoded `moonbit_image::Image` is reference-shared via Bytes,
//    so the cache cost is one Map entry per unique source string
//    plus the underlying pixel data.
//
// What about disk I/O?
//
//  - Disk reading is **not** done in this module. Moui 0.1.12
//    ships `moonbitlang/x/fs` as a sync read_file API, but that
//    package is not on the project's dependency surface yet
//    (Moui 0.1.12 transitively requires `moonbitlang/async@0.21.0`
//    while the labeler's root project pins `async@0.19.4`). The
//    sync read pull is queued as Phase 14.
//  - Until then, callers inject decoded bytes via `load_bytes`
//    (used by tests and by the Moui `HostImageSource` integration
//    in Phase 14). The on-disk loader will be `ImageCache::load`
//    once the async/sync boundary is sorted.

///|
/// Decoded RGBA8 image, ready for direct blit. `data` is
/// `width * height * 4` bytes in row-major (top-to-bottom)
/// order, R G B A per pixel — exactly the layout `Image::to_rgba8`
/// produces.
pub struct DecodedImage {
  width : Int
  height : Int
  data : Bytes
} derive(Eq, Debug, Show)

///|
/// Process-wide image cache keyed by source path.
pub struct ImageCache {
  entries : Map[String, DecodedImage]
}

///|
/// Build an empty cache. Cheap; no I/O happens.
pub fn ImageCache::new() -> ImageCache {
  // MoonBit 0.1.x's no-arg `Map::new()` is deprecated in favor
  // of `Map([], capacity=...)`, but the typed-array form triggers
  // an unresolved-type-variable error here (the pair array's
  // element type needs explicit typing). Until that's stable,
  // use the simple form and accept the warning — the runtime
  // behavior is identical and the warning is already silenced
  // project-wide via the root `warn_list: ""` option.
  { entries: Map::new() }
}

///|
/// Clear all cached entries. Useful for tests and for forced
/// reload (e.g. a "refresh images" UI affordance).
pub fn ImageCache::clear(self : ImageCache) -> Unit {
  self.entries.clear()
}

///|
/// Look up `source` in the cache. Returns the previously-decoded
/// RGBA8 image, or `None` if the cache has never loaded it.
pub fn ImageCache::get(self : ImageCache, source : String) -> DecodedImage? {
  self.entries.get(source)
}

///|
/// Inject an already-decoded RGBA8 image into the cache. Called
/// by tests (with hand-built RGBA bytes) and, eventually, by the
/// Moui `HostImageSource` integration (which decodes off-thread
/// and hands the result here).
///
/// Returns `None` if the input bytes are malformed (length is
/// not `width * height * 4`, or `width`/`height` are not positive).
pub fn ImageCache::load_bytes(
  self : ImageCache,
  source : String,
  width : Int,
  height : Int,
  data : Bytes,
) -> DecodedImage? {
  if width <= 0 || height <= 0 {
    return None
  }
  let expected : Int = width * height * 4
  if data.length() != expected {
    return None
  }
  let decoded : DecodedImage = { width, height, data }
  self.entries.set(source, decoded)
  Some(decoded)
}

///|
/// Convenience: return the cached entry if present, otherwise
/// attempt to inject a pre-decoded image. Disk-based loading
/// (the missing `load` method) is Phase 14.
pub fn ImageCache::get_or_inject(
  self : ImageCache,
  source : String,
  width : Int,
  height : Int,
  data : Bytes,
) -> DecodedImage? {
  match self.entries.get(source) {
    Some(d) => Some(d)
    None => self.load_bytes(source, width, height, data)
  }
}

// ─────────────────────────────────────────────────────────────────
// Synthetic fixtures
// ─────────────────────────────────────────────────────────────────

///|
/// The colour of horizontal band `band` (0-based) of the banded
/// fixture: red, green, blue, white. One definition shared by the
/// fixture builder and the Phase 5.7 regression test, so the
/// "which colour is which band" mapping can't drift between the
/// shipped fixture and the test that pins it.
pub fn band_colour(band : Int) -> (Int, Int, Int) {
  match band {
    0 => (255, 0, 0)
    1 => (0, 255, 0)
    2 => (0, 0, 255)
    _ => (255, 255, 255)
  }
}

///|
/// Phase 5.7 — build a `w` x `h` RGBA8 image split into 4 equal
/// horizontal bands, colour `i` from `band_colour(i)`. Fully opaque
/// (alpha 255) on every pixel.
///
/// This replaced the Phase 5.2 solid-magenta demo fixture. Solid
/// magenta proved the cache + blit + presenter chain worked, but it
/// was a *degenerate* check: a uniformly-coloured source cannot
/// distinguish a correct nearest-neighbour mapping from a wrong one,
/// because every mapping produces the same pixels. Banding makes the
/// fixture self-validating — if fit-contain, the pan/zoom transform,
/// or `paint_image`'s source-row mapping drops or repeats a band, it
/// is immediately visible in the smoke screenshot *and* pinned by
/// `phase5_7_blit_test.mbt`, which drives this exact builder through
/// the real rasterizer at 2x upscale, 0.5x downscale, and with
/// vertical banding.
///
/// The Phase 5.2 note claimed a 4-stripe fixture "only rendered 2 of
/// the 4 stripes" and hypothesised that `paint_image` "clamps src_h
/// to ~100". That hypothesis is disproven — see the tests in
/// `phase5_7_blit_test.mbt`; `src_y = dy * src_h / dst_h` has no
/// clamp and all four bands land correctly at every tested scale.
pub fn banded_rgba8_fixture(w : Int, h : Int) -> Bytes {
  let rgba : Array[Byte] = []
  // 4 bands, so the per-band row count is h / 4 with any remainder
  // folded into the last band. For h = 200 this is exactly 50 rows
  // each.
  let band_h : Int = h / 4
  let mut y : Int = 0
  while y < h {
    let band : Int = if band_h <= 0 {
      0
    } else if y < band_h {
      0
    } else if y < band_h * 2 {
      1
    } else if y < band_h * 3 {
      2
    } else {
      3
    }
    let (r, g, b) = band_colour(band)
    let mut x : Int = 0
    while x < w {
      rgba.push(r.to_byte())
      rgba.push(g.to_byte())
      rgba.push(b.to_byte())
      rgba.push((255).to_byte())
      x = x + 1
    }
    y = y + 1
  }
  Bytes::from_array(rgba)
}
