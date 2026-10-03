// app_moui/phase5_7_blit_test.mbt — Phase 5.7 regression tests
// for the deferred image-blit questions.
//
// Phase 5.2 shipped a solid-magenta 200x200 synthetic demo fixture
// and left a known bug on the record:
//
//   "The 4-stripe (red/green/blue/yellow per y or x range) variants
//   tested during development only rendered 2 of the 4 stripes (top
//   half red, bottom half green; or left half red, right half green)
//   regardless of which MoonBit syntax was used. The branching case
//   appears to clamp src_h to ~100 instead of 200 in `paint_image`'s
//   loop."
//
// That claim was never verified, and it is wrong: `paint_image`
// computes `src_y = dy * src_h / dst_h`, which is a correct
// nearest-neighbour mapping with no clamp, and `ImageCache::load_bytes`
// rejects any buffer whose length is not exactly `w * h * 4`.
//
// The gap in coverage is that the pre-existing blit test
// (phase14_image_test.mbt) uses a 4x4 image at 1:1 scale, which
// cannot distinguish a correct nearest-neighbour mapping from a
// clamped one — every source pixel is visited exactly once. The
// reported failure needs a *banded* image at an *upscale*, which is
// exactly what the real canvas does (200x200 source, several-hundred-px
// destination). These tests close that gap.

///|
/// Phase 5.7 — read one destination pixel out of a PixelBuffer as an
/// (r, g, b) triple. The buffer stores BGRA (see phase14 test's
/// `pixels[off + 2]` == R), so the channel indices are reversed
/// relative to the RGBA source data. Centralised here so every
/// assertion in this file agrees on the channel order.
fn pixel_rgb(buf : PixelBuffer, x : Int, y : Int) -> (Int, Int, Int) {
  let off : Int = y * buf.width * 4 + x * 4
  (buf.pixels[off + 2].to_int(), buf.pixels[off + 1].to_int(),
   buf.pixels[off].to_int())
}

///|
/// Phase 5.7 — expected colour for a destination row, derived from
/// the *shipped* fixture's band schedule (`banded_rgba8_fixture` +
/// `band_colour` in image_cache.mbt) rather than a local copy. The
/// tests below therefore pin the fixture the app actually ships, not
/// a lookalike that could drift from it.
fn expected_band_rgb(src_y : Int, src_h : Int) -> (Int, Int, Int) {
  let band_h : Int = src_h / 4
  let band : Int = if band_h <= 0 {
    0
  } else if src_y < band_h {
    0
  } else if src_y < band_h * 2 {
    1
  } else if src_y < band_h * 3 {
    2
  } else {
    3
  }
  band_colour(band)
}

///|
/// Phase 5.7 — THE decisive regression test for the Phase 5.2
/// "4-stripe" known bug. The shipped 200x200 fixture (4 bands of 50
/// rows) drawn into a 400x400 destination — 2x upscale, the same
/// regime as the real canvas where the 200x200 synthetic image is
/// fit-contain'd into a several-hundred-px viewport.
///
/// Under a correct nearest-neighbour mapping, destination row `dy`
/// samples source row `dy * 200 / 400 = dy / 2`, so all four bands
/// must be present and in the right places. Under the hypothesised
/// "src_h clamped to ~100" bug, the destination's lower half would
/// keep re-sampling the top half of the source and bands 2/3 would
/// never appear.
test "paint_image — shipped 200x200 4-band fixture at 2x upscale renders all 4 bands (5.7)" {
  let cache : ImageCache = ImageCache::new()
  let _ = cache.load_bytes("banded.png", 200, 200, banded_rgba8_fixture(200, 200))
  let buf : PixelBuffer = PixelBuffer::new(
    400,
    400,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let run : @core.ImageRun = {
    source: "banded.png",
    frame: @core.Rect::new(x=0.0, y=0.0, width=400.0, height=400.0),
    opacity: 1.0,
    fit: @core.ImageFit::Stretch,
  }
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawImage(run)],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, cache)
  // Walk one column (x = 200) down the full destination height,
  // sampling every band. Sample the *middle* of each band's
  // destination range so an off-by-one at a boundary can't decide
  // the result.
  //
  // Destination row -> source row is dy / 2, so band boundaries in
  // destination space are at dy = 100, 200, 300.
  for dy in [10, 60, 120, 180, 260, 320, 380] {
    let (r, g, b) = pixel_rgb(buf, 200, dy)
    let src_y : Int = dy * 200 / 400
    let (er, eg, eb) = expected_band_rgb(src_y, 200)
    assert_eq((r, g, b), (er, eg, eb))
  }
}

///|
/// Phase 5.7 — downscale direction. The same shipped fixture drawn
/// into a 100x100 destination (0.5x) must show all four bands too,
/// just thinner. Under a broken mapping that overshot (e.g. clamped
/// to a smaller range) bands 2/3 would be dropped entirely.
test "paint_image — shipped 4-band fixture at 0.5x downscale renders all 4 bands (5.7)" {
  let cache : ImageCache = ImageCache::new()
  let _ = cache.load_bytes("banded.png", 200, 200, banded_rgba8_fixture(200, 200))
  let buf : PixelBuffer = PixelBuffer::new(
    100,
    100,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let run : @core.ImageRun = {
    source: "banded.png",
    frame: @core.Rect::new(x=0.0, y=0.0, width=100.0, height=100.0),
    opacity: 1.0,
    fit: @core.ImageFit::Stretch,
  }
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawImage(run)],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, cache)
  // Destination row dy -> source row dy * 200 / 100 = dy * 2, so
  // band boundaries land at dy = 25, 50, 75.
  for dy in [5, 15, 30, 40, 55, 65, 80, 95] {
    let (r, g, b) = pixel_rgb(buf, 50, dy)
    let src_y : Int = dy * 200 / 100
    let (er, eg, eb) = expected_band_rgb(src_y, 200)
    assert_eq((r, g, b), (er, eg, eb))
  }
}

///|
/// Phase 5.7 — the fixture's own byte layout. `load_bytes` rejects
/// any buffer whose length isn't exactly `w * h * 4`, so a fixture
/// that pushed a different number of bytes per pixel would be
/// silently refused (producing a cache-miss placeholder on screen
/// rather than a banded image). Pin the length so a refactor of the
/// push loop can't quietly break the demo.
test "banded_rgba8_fixture — byte length is exactly w*h*4 (5.7)" {
  assert_eq(banded_rgba8_fixture(200, 200).length(), 200 * 200 * 4)
  assert_eq(banded_rgba8_fixture(4, 4).length(), 4 * 4 * 4)
}

///|
/// Phase 5.7 — vertical banding (the per-x variant the Phase 5.2
/// note also reported failing: "left half red, right half green").
/// Guards the `src_x = dx * src_w / dst_w` axis, which the
/// row-banded tests above never touch, and covers the
/// vertical-stripe fixture shape that was also reported broken.
test "paint_image — vertical bands render across the full width (5.7)" {
  let rgba : Array[Byte] = []
  let mut y : Int = 0
  while y < 8 {
    let mut x : Int = 0
    while x < 8 {
      // Left half red, right half green, mirrored top/bottom so a
      // row-axis bug can't masquerade as an x-axis success.
      let (r, g, b) = if x < 4 { (255, 0, 0) } else { (0, 255, 0) }
      rgba.push(r.to_byte())
      rgba.push(g.to_byte())
      rgba.push(b.to_byte())
      rgba.push((255).to_byte())
      x = x + 1
    }
    y = y + 1
  }
  let cache : ImageCache = ImageCache::new()
  let _ = cache.load_bytes("vstripes.png", 8, 8, Bytes::from_array(rgba))
  let buf : PixelBuffer = PixelBuffer::new(
    32,
    32,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let run : @core.ImageRun = {
    source: "vstripes.png",
    frame: @core.Rect::new(x=0.0, y=0.0, width=32.0, height=32.0),
    opacity: 1.0,
    fit: @core.ImageFit::Stretch,
  }
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawImage(run)],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, cache)
  // Sample the full width at mid-height.
  for dx in [1, 6, 12, 20, 26, 30] {
    let (r, g, b) = pixel_rgb(buf, dx, 16)
    let (er, eg, eb) = if dx * 8 / 32 < 4 {
      (255, 0, 0)
    } else {
      (0, 255, 0)
    }
    assert_eq((r, g, b), (er, eg, eb))
  }
}
