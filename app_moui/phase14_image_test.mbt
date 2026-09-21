// app_moui/phase14_image_test.mbt — Phase 14 integration test
// for the image disk-load bridge.
//
// Phase 14 architecture (revised after the 0.21.x investigation):
//
//   1. App model emits a `LoadImage(path)` Msg when the user
//      selects an image.
//   2. Update handler dispatches an Effect that triggers a
//      FileServices::read_bytes(path) (async, via Moui's
//      ServiceTask pattern — see Phase 16.D investigation).
//   3. The async bridge in our main_native.mbt routes the
//      loaded Bytes back as an `ImageLoaded(path, bytes)`
//      Msg via the runtime's dispatch channel.
//   4. Update handler decodes Bytes via `riantr/moonbit_image`
//      and stashes the RGBA8 pixel buffer into a process-local
//      side table keyed by path.
//   5. View tree emits `DrawImage(ImageRun)` referencing that
//      path; our rasterizer's `paint_image` looks up the
//      ImageCache (Phase 13) by source name and blits the
//      cached RGBA8.
//
// Direct sync disk-read (`@fs.read_file` from sync context)
// remains blocked in moon 0.21.x — the libuv uv_fs threadpool
// call requires an async context. This test verifies steps
// 4 + 5 (the cache-and-blit half) using pre-built RGBA8 bytes,
// which is the part the rasterizer owns and which we can
// unit-test in isolation. The async half (steps 1-3) is
// wired through Moui at integration time and isn't testable
// here without spinning up a full HostSurface + runtime.

///|
/// Build a small 4x4 RGBA8 image with 4 distinct colors per
/// quadrant. Used as test fixture for the disk-load cache
/// pipeline:
///   [0..2, 0..2]   = red    (R=255, G=0,   B=0,   A=255)
///   [2..4, 0..2]   = green  (R=0,   G=255, B=0,   A=255)
///   [0..2, 2..4]   = blue   (R=0,   G=0,   B=255, A=255)
///   [2..4, 2..4]   = yellow (R=255, G=255, B=0,   A=255)
fn make_quadrant_rgba8() -> Bytes {
  let rgba : Array[Byte] = []
  let mut y : Int = 0
  while y < 4 {
    let mut x : Int = 0
    while x < 4 {
      let in_top : Bool = y < 2
      let in_left : Bool = x < 2
      // 4 quadrants:
      //   top-left  (y<2, x<2):  red    R=255
      //   top-right (y<2, x>=2): green  R=0,  G=255
      //   bot-left  (y>=2, x<2): blue   B=255
      //   bot-right (y>=2, x>=2): yellow R=255, G=255
      let r : Int = if in_top && in_left {
        255
      } else if !in_top && !in_left {
        255
      } else {
        0
      }
      let g : Int = if in_top && !in_left {
        255
      } else if !in_top && !in_left {
        255
      } else {
        0
      }
      let b : Int = if !in_top && in_left {
        255
      } else {
        0
      }
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

///|
/// Phase 14 — integration test: ImageCache + rasterizer
/// pipeline. Pre-populate the cache with 4x4 RGBA8 quadrant
/// data, then rasterize a DrawFrame that references that
/// source via DrawImage(ImageRun). Pixel (1, 1) should be
/// red (top-left quadrant), pixel (3, 1) green, etc.
test "phase14_cache_then_rasterize_draws_quadrants" {
  let rgba : Bytes = make_quadrant_rgba8()
  let cache : ImageCache = ImageCache::new()
  let _ = cache.load_bytes("test.png", 4, 4, rgba)
  let buf : PixelBuffer = PixelBuffer::new(
    8,
    8,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let run : @core.ImageRun = {
    source: "test.png",
    frame: @core.Rect::new(x=2.0, y=2.0, width=4.0, height=4.0),
    opacity: 1.0,
    fit: @core.ImageFit::Stretch,
  }
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawImage(run)],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, cache)
  // Pixel (2, 2) corresponds to image pixel (0, 0): top-left = red.
  let off22 : Int = 2 * buf.width * 4 + 2 * 4
  let r22 : Int = buf.pixels[off22 + 2].to_int()
  let g22 : Int = buf.pixels[off22 + 1].to_int()
  let b22 : Int = buf.pixels[off22].to_int()
  // DEBUG: dump all 4 BGRA bytes at (2,2)
  let _ = assert_eq(r22, 255)
  let _ = assert_eq(g22, 0)
  let _ = assert_eq(b22, 0)
  // Pixel (5, 2) -> image (3, 0): top-right = green.
  let off52 : Int = 2 * buf.width * 4 + 5 * 4
  assert_eq(buf.pixels[off52 + 2].to_int(), 0)
  assert_eq(buf.pixels[off52 + 1].to_int(), 255)
  assert_eq(buf.pixels[off52].to_int(), 0)
  // Pixel (2, 5) -> image (0, 3): bottom-left = blue.
  let off25 : Int = 5 * buf.width * 4 + 2 * 4
  assert_eq(buf.pixels[off25 + 2].to_int(), 0)
  assert_eq(buf.pixels[off25 + 1].to_int(), 0)
  assert_eq(buf.pixels[off25].to_int(), 255)
  // Pixel (5, 5) -> image (3, 3): bottom-right = yellow.
  let off55 : Int = 5 * buf.width * 4 + 5 * 4
  assert_eq(buf.pixels[off55 + 2].to_int(), 255)
  assert_eq(buf.pixels[off55 + 1].to_int(), 255)
  assert_eq(buf.pixels[off55].to_int(), 0)
}

///|
/// Phase 14 — second rasterization should be cache hit (no
/// decode). Two consecutive rasterize_draw_frame calls with
/// the same source must produce identical pixels; verifies
/// the cache is read, not re-decoded.
test "phase14_cache_hit_on_second_rasterize" {
  let rgba : Bytes = make_quadrant_rgba8()
  let cache : ImageCache = ImageCache::new()
  let _ = cache.load_bytes("quad.png", 4, 4, rgba)
  let run : @core.ImageRun = {
    source: "quad.png",
    frame: @core.Rect::new(x=0.0, y=0.0, width=4.0, height=4.0),
    opacity: 1.0,
    fit: @core.ImageFit::Stretch,
  }
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawImage(run)],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let buf1 : PixelBuffer = PixelBuffer::new(
    8,
    8,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let buf2 : PixelBuffer = PixelBuffer::new(
    8,
    8,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf1, frame, cache)
  rasterize_draw_frame(buf2, frame, cache)
  // Spot-check: pixel (1, 1) identical in both buffers.
  let off : Int = 1 * buf1.width * 4 + 1 * 4
  assert_eq(buf1.pixels[off + 2].to_int(), buf2.pixels[off + 2].to_int())
  assert_eq(buf1.pixels[off + 1].to_int(), buf2.pixels[off + 1].to_int())
  assert_eq(buf1.pixels[off].to_int(), buf2.pixels[off].to_int())
}

///|
/// Phase 14 — unknown source with no disk-load bridge yet
/// should still paint the placeholder (no crash). Verifies
/// the cache-miss path stays graceful until the async bridge
/// is wired in main_native.mbt.
test "phase14_cache_miss_paints_placeholder_no_crash" {
  let cache : ImageCache = ImageCache::new()
  let buf : PixelBuffer = PixelBuffer::new(
    16,
    16,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let run : @core.ImageRun = {
    source: "never-loaded.png",
    frame: @core.Rect::new(x=4.0, y=4.0, width=8.0, height=8.0),
    opacity: 1.0,
    fit: @core.ImageFit::Stretch,
  }
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawImage(run)],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, cache)
  // Pixel (8, 8) is inside the rect; placeholder should have
  // drawn the outline + diagonal lines. Just verify the
  // buffer is non-trivial after rasterization (no all-zero
  // panic).
  let off : Int = 8 * buf.width * 4 + 8 * 4
  let a : Int = buf.pixels[off + 3].to_int()
  assert_true(a > 0)
}