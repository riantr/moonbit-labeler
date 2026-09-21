// app_moui/labeler_ui_test.mbt 鈥?Phase 16.C verification tests.
//
// Builds the labeler UI demo frame at a known size, rasterizes
// it, and asserts pixel colors at key positions to verify
// the primitives compose correctly.

///|
test "labeler_ui_sidebar_background_painted" {
  let frame : @core.DrawFrame = build_labeler_ui_demo_frame(400, 300)
  let buf : PixelBuffer = PixelBuffer::new(
    400,
    300,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Pixel (50, 160) is inside the sidebar (x<200), below the
  // toolbar (y>40), and below all folder rows (which end at
  // y=154). Should be plain sidebar background.
  let off : Int = 160 * buf.width * 4 + 50 * 4
  let b : Int = buf.pixels[off].to_int()
  let g : Int = buf.pixels[off + 1].to_int()
  let r : Int = buf.pixels[off + 2].to_int()
  let a : Int = buf.pixels[off + 3].to_int()
  // Sidebar background (16, 16, 19) * 255 = (40, 40, 48).
  // Allow small AA fuzz at the edge: check r is in 38-43.
  assert_true(r >= 38 && r <= 43)
  assert_true(g >= 38 && g <= 43)
  assert_true(b >= 46 && b <= 51)
  assert_eq(a, 255)
}

///|
test "labeler_ui_toolbar_background_painted" {
  let frame : @core.DrawFrame = build_labeler_ui_demo_frame(400, 300)
  let buf : PixelBuffer = PixelBuffer::new(
    400,
    300,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Pixel (300, 20) is inside the toolbar (y<40) and in the
  // canvas area (x>200). Toolbar_bg (22, 22, 26) * 255 = (56, 56, 66).
  let off : Int = 20 * buf.width * 4 + 300 * 4
  let r : Int = buf.pixels[off + 2].to_int()
  assert_true(r >= 54 && r <= 58)
}

///|
test "labeler_ui_canvas_background_distinct_from_sidebar" {
  let frame : @core.DrawFrame = build_labeler_ui_demo_frame(400, 300)
  let buf : PixelBuffer = PixelBuffer::new(
    400,
    300,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Pixel (300, 200) is in the canvas area (right of sidebar,
  // below toolbar). Canvas_bg (10, 10, 12) * 255 = (25, 25, 30).
  let off : Int = 200 * buf.width * 4 + 300 * 4
  let r : Int = buf.pixels[off + 2].to_int()
  let g : Int = buf.pixels[off + 1].to_int()
  let b : Int = buf.pixels[off].to_int()
  // Verify it's the dark canvas color, not the sidebar's
  // lighter color.
  assert_true(r < 28)
  assert_true(g < 28)
  assert_true(b < 33)
  // And distinct from sidebar_bg (which has r ~= 40).
  assert_true(r < 35)
}

///|
test "labeler_ui_tool_button_is_rounded_rect" {
  let frame : @core.DrawFrame = build_labeler_ui_demo_frame(400, 300)
  let buf : PixelBuffer = PixelBuffer::new(
    400,
    300,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // First tool button is at (8, 4) to (40, 36) with radius 6.
  // Pixel (16, 20) is INSIDE the rounded rect (corner cut by
  // radius 6 leaves cell at (8..14) cut, but (16, 20) is well
  // inside the interior). Expected: tool_bg (30, 30, 34) * 255.
  let off : Int = 20 * buf.width * 4 + 16 * 4
  let r : Int = buf.pixels[off + 2].to_int()
  assert_true(r >= 74 && r <= 78)
}

///|
test "labeler_ui_class_chip_color_visible" {
  let frame : @core.DrawFrame = build_labeler_ui_demo_frame(400, 300)
  let buf : PixelBuffer = PixelBuffer::new(
    400,
    300,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // First class chip is at (8, 170) to (192, 188), radius 4.
  // Pixel (100, 178) is well inside the chip. Expected: chip_bg
  // (40, 40, 85) * 255 = (102, 102, 217).
  let off : Int = 178 * buf.width * 4 + 100 * 4
  let b : Int = buf.pixels[off].to_int()
  let r : Int = buf.pixels[off + 2].to_int()
  assert_true(b >= 215 && b <= 220)
  assert_true(r >= 100 && r <= 105)
}

///|
test "labeler_ui_pure_function_returns_identical_frame" {
  // The demo builder is pure 鈥?two calls with the same args
  // produce equivalent frames.
  let frame1 : @core.DrawFrame = build_labeler_ui_demo_frame(200, 200)
  let frame2 : @core.DrawFrame = build_labeler_ui_demo_frame(200, 200)
  assert_eq(frame1.commands.length(), frame2.commands.length())
  let buf1 : PixelBuffer = PixelBuffer::new(200, 200, @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0))
  let buf2 : PixelBuffer = PixelBuffer::new(200, 200, @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0))
  rasterize_draw_frame(buf1, frame1, ImageCache::new())
  rasterize_draw_frame(buf2, frame2, ImageCache::new())
  // Spot-check: pixel (100, 100) identical in both buffers.
  let off : Int = 100 * 200 * 4 + 100 * 4
  assert_eq(buf1.pixels[off + 2].to_int(), buf2.pixels[off + 2].to_int())
  assert_eq(buf1.pixels[off].to_int(), buf2.pixels[off].to_int())
}

///|
test "labeler_ui_small_buffer_handles_minimum" {
  // 100x100 buffer — sidebar (200px) covers the whole width
  // so there's no canvas region, but the toolbar/sidebar
  // layout still paints. Pick pixel (50, 42) — inside the
  // toolbar, above the decorative bezier path.
  let frame : @core.DrawFrame = build_labeler_ui_demo_frame(100, 100)
  let buf : PixelBuffer = PixelBuffer::new(
    100,
    100,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  let off : Int = 20 * 100 * 4 + 44 * 4
  let r : Int = buf.pixels[off + 2].to_int()
  // Toolbar bg (0.22, 0.22, 0.26) -> R=56. Pixel (44, 20)
  // is between tool button 1 (8-40) and 2 (48-80).
  assert_eq(r, 56)
}

///|
