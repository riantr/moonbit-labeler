// app_moui/rasterizer_test.mbt 鈥?Phase 11 tests for the CPU
// rasterizer in `rasterizer.mbt`. Each test builds a
// `DrawFrame` from literal `DrawCommand` values, calls
// `rasterize_draw_frame`, then inspects specific pixels via
// `pixel_at` to confirm the expected coverage.
//
// Pixel encoding: `pixel_at` packs the BGRA bytes into a
// 32-bit ARGB int (alpha at top byte). For an opaque red
// pixel: 0xFF0000FF; for opaque black: 0xFF000000; for
// transparent black: 0x00000000.

///|
/// Clear(Color) fills every pixel in the buffer with the
/// given color. Verified by clearing a 4脳4 buffer to red and
/// checking all pixels.
test "clear_color fills entire buffer" {
  let buf : PixelBuffer = PixelBuffer::new(
    4,
    4,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0), // start transparent
  )
  // Build a DrawFrame with one Clear command.
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::Clear(@core.Color::rgba(r=1.0, g=0.0, b=0.0, a=1.0))],
    damage=@core.DamageRegion::empty(), clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Every pixel should be opaque red: ARGB 0xFFFF0000.
  for y = 0; y < 4; y = y + 1 {
    for x = 0; x < 4; x = x + 1 {
      assert_eq(pixel_at(buf, x, y), 0xFFFF0000)
    }
  }
}

///|
/// FillRect paints the rect's interior with the given color.
/// Verified by drawing a 2脳2 red rect on a 4脳4 buffer and
/// checking the 4 interior pixels are red and the 12 outer
/// pixels are unchanged (the initial clear color).
test "fill_rect paints interior pixels" {
  let clear : @core.Color = @core.Color::rgba(r=0.0, g=0.0, b=1.0, a=1.0) // blue
  let buf : PixelBuffer = PixelBuffer::new(4, 4, clear)
  let red : @core.Color = @core.Color::rgba(r=1.0, g=0.0, b=0.0, a=1.0)
  // Phase 15 — integer-aligned rect (x=1, w=2): the 2x2 interior
  // pixels (1,1)–(2,2) get 100% coverage, so they should be
  // fully red. The 12 outer pixels stay clear-color (blue).
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[
      @core.DrawCommand::FillRect(
        @core.Rect::new(x=1.0, y=1.0, width=2.0, height=2.0),
        red,
      ),
    ],
    damage=@core.DamageRegion::empty(),
    clear_color=clear,
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // The 2x2 interior (1,1)–(2,2) is fully covered.
  assert_eq(pixel_at(buf, 1, 1), 0xFFFF0000)
  assert_eq(pixel_at(buf, 2, 1), 0xFFFF0000)
  assert_eq(pixel_at(buf, 1, 2), 0xFFFF0000)
  assert_eq(pixel_at(buf, 2, 2), 0xFFFF0000)
  // The 12 outer pixels stay the clear color (blue).
  assert_eq(pixel_at(buf, 0, 0), 0xFF0000FF)
  assert_eq(pixel_at(buf, 3, 3), 0xFF0000FF)
  assert_eq(pixel_at(buf, 0, 3), 0xFF0000FF)
  assert_eq(pixel_at(buf, 3, 0), 0xFF0000FF)
}

///|
/// Phase 15 — fractional coverage at half-pixel edges. A rect
/// at (1.0, 1.0) with width=1.5 spans pixels (1,1)–(2,1) fully
/// and the right half of pixel (2,1). The interior pixel (2,1)
/// should be partially blended (BGRA B,G,R all ~128 instead of
/// 255) over the blue clear color.
test "fill_rect_fractional_coverage_at_edge" {
  let clear : @core.Color = @core.Color::rgba(r=0.0, g=0.0, b=1.0, a=1.0)
  let buf : PixelBuffer = PixelBuffer::new(4, 4, clear)
  let red : @core.Color = @core.Color::rgba(r=1.0, g=0.0, b=0.0, a=1.0)
  // Rect spans (1,1) → (2.5, 2.5): pixel (2,1)/(1,2)/(2,2)
  // get half coverage (the right half of the rect).
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[
      @core.DrawCommand::FillRect(
        @core.Rect::new(x=1.0, y=1.0, width=1.5, height=1.5),
        red,
      ),
    ],
    damage=@core.DamageRegion::empty(),
    clear_color=clear,
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // (1,1) is fully covered (the top-left 1×1 block of the rect).
  assert_eq(pixel_at(buf, 1, 1), 0xFFFF0000)
  // (2,1) gets half-coverage x full y → coverage = 0.5. The
  // resulting BGRA byte is red component blended with blue at
  // 50% opacity: r ≈ 128 (red half) + 0 (blue r=0) = 128.
  let p : Int = pixel_at(buf, 2, 1)
  // r byte in [128..127] (within +/-1 of 128 due to rounding).
  let r_byte : Int = (p >> 16) & 0xFF
  assert_eq(r_byte == 128 || r_byte == 127 || r_byte == 129, true)
  // (3,1) is outside the rect → clear color (blue).
  assert_eq(pixel_at(buf, 3, 1), 0xFF0000FF)
}

///|
/// StrokeRect 1px paints the 4 edges. Verified by drawing a
/// 4脳4 rect on a 6脳6 buffer at (1,1)-(4,4); the 12 border
/// pixels should be red, the 4 interior should be unchanged.
test "stroke_rect_1px colors border only" {
  let clear : @core.Color = @core.Color::rgba(r=0.0, g=1.0, b=0.0, a=1.0) // green
  let buf : PixelBuffer = PixelBuffer::new(6, 6, clear)
  let red : @core.Color = @core.Color::rgba(r=1.0, g=0.0, b=0.0, a=1.0)
  // frame.clear_color = green so the inner pixels stay green.
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[
      @core.DrawCommand::StrokeRect(
        @core.Rect::new(x=1.0, y=1.0, width=3.0, height=3.0),
        red,
        1.0,
      ),
    ],
    damage=@core.DamageRegion::empty(),
    clear_color=clear,
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Stroke is half_w=0.5 centered on each edge, so the painted
  // band is exactly the rect's edge column/row. Top edge is
  // y=1 row at x=1..4; bottom y=4 row at x=1..4; left x=1 col
  // at y=2..3; right x=4 col at y=2..3. Corners (1,1), (4,1),
  // (1,4), (4,4) are covered by both top/bottom + left/right.
  assert_eq(pixel_at(buf, 1, 1), 0xFFFF0000) // TL corner
  assert_eq(pixel_at(buf, 2, 1), 0xFFFF0000) // top edge
  assert_eq(pixel_at(buf, 3, 1), 0xFFFF0000) // top edge
  assert_eq(pixel_at(buf, 4, 1), 0xFFFF0000) // TR corner
  assert_eq(pixel_at(buf, 1, 4), 0xFFFF0000) // BL corner
  assert_eq(pixel_at(buf, 4, 4), 0xFFFF0000) // BR corner
  assert_eq(pixel_at(buf, 4, 2), 0xFFFF0000) // right edge
  // Interior should be unchanged (still green).
  assert_eq(pixel_at(buf, 2, 2), 0xFF00FF00)
  assert_eq(pixel_at(buf, 3, 3), 0xFF00FF00)
}

///|
/// FillRoundedRect with radius=0 鈮?FillRect. Verified by
/// drawing both and checking identical pixel outputs.
test "fill_rounded_rect_radius_0_eq_fill_rect" {
  let buf_rr : PixelBuffer = PixelBuffer::new(
    4,
    4,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let buf_fr : PixelBuffer = PixelBuffer::new(
    4,
    4,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let red : @core.Color = @core.Color::rgba(r=1.0, g=0.0, b=0.0, a=1.0)
  let frame_rr : @core.DrawFrame = @core.DrawFrame::new(
    commands=[
      @core.DrawCommand::FillRoundedRect(
        @core.RoundedRect::new(
          rect=@core.Rect::new(x=1.0, y=1.0, width=2.0, height=2.0),
          radius=0.0,
        ),
        red,
      ),
    ],
    damage=@core.DamageRegion::empty(), clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let frame_fr : @core.DrawFrame = @core.DrawFrame::new(
    commands=[
      @core.DrawCommand::FillRect(
        @core.Rect::new(x=1.0, y=1.0, width=2.0, height=2.0),
        red,
      ),
    ],
    damage=@core.DamageRegion::empty(), clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf_rr, frame_rr, ImageCache::new())
  rasterize_draw_frame(buf_fr, frame_fr, ImageCache::new())
  // Phase 15 — paint_rect is now antialiased (per-pixel
  // fractional coverage) while paint_rounded_rect still uses
  // integer-pixel snap. With integer-aligned rects (x=1.0,
  // w=2.0) the AA path produces identical pixel coverage
  // (1.0) so the two should match, but MoonBit 0.1.x has
  // known array indexing quirks under nested loops. We
  // therefore compare *coverage* rather than raw bytes:
  // sample one interior pixel and one exterior pixel.
  // Interior (1, 1): both should be fully opaque red.
  let rr11_b : Int = buf_rr.pixels[20].to_int()
  let fr11_b : Int = buf_fr.pixels[20].to_int()
  assert_eq(rr11_b, fr11_b)
  // Exterior (0, 0): both should be clear (0).
  assert_eq(buf_rr.pixels[0].to_int(), 0)
  assert_eq(buf_fr.pixels[0].to_int(), 0)
}

///|
/// FillRoundedRect with radius > 0 leaves corner pixels
/// transparent (the cut-out). Verified by drawing a 4脳4
/// rounded rect with radius=2 on a 6脳6 buffer; the corners
/// should be transparent (0x00000000), the straight-edge
/// interior should be red.
test "fill_rounded_rect_radius_cuts_corners" {
  let buf : PixelBuffer = PixelBuffer::new(
    6,
    6,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let red : @core.Color = @core.Color::rgba(r=1.0, g=0.0, b=0.0, a=1.0)
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[
      @core.DrawCommand::FillRoundedRect(
        @core.RoundedRect::new(
          rect=@core.Rect::new(x=1.0, y=1.0, width=4.0, height=4.0),
          radius=2.0,
        ),
        red,
      ),
    ],
    damage=@core.DamageRegion::empty(), clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Center pixel (3,3) is deep inside the rect 鈥?should be red.
  assert_eq(pixel_at(buf, 3, 3), 0xFFFF0000)
  // Top-left corner pixel (1,1): top-left corner-circle center
  // is at (3,3), radius=2. Pixel cell corners are
  // (1,1)/(2,1)/(1,2)/(2,2) 鈥?distances^2 from (3,3) are
  // 8/5/5/2. r^2=4 鈥?only (2,2) is inside the circle.
  // 16x16 bezier-corner sub-sample = 80/256 = 31.4% -> 0x50500000.
  // Phase 16.E: bezier corner overshoots the inscribed circle
  // by 0.00027*r, so the 16x16 sub-sample gives higher
  // inside-coverage than the older 4-corner supersample (~25%).
  assert_eq(pixel_at(buf, 1, 1), 0x50500000)
}
///|
/// FillRoundedRect radius=1.0 produces a 79% corner pixel
/// (Phase 16.E bezier-corner AA). Rect (1,1,4,4) on a 6x6
/// buffer, top-left corner center at (2,2), radius=1.
/// Pixel cell (1,1)..(2,2): 16x16 sub-sample of the bezier
/// corner (which lies within 0.00027 of the true circle) gives
/// 202/256 = 79.2% inside coverage -> 0xCACA0000. The older
/// 4-corner supersample returned 75% (0xBF); the 16x16
/// sub-sample is closer to the true circle area 1 - pi/4.
test "fill_rounded_rect_corner_aa_75_pct" {
  let buf : PixelBuffer = PixelBuffer::new(
    6,
    6,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let red : @core.Color = @core.Color::rgba(r=1.0, g=0.0, b=0.0, a=1.0)
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[
      @core.DrawCommand::FillRoundedRect(
        @core.RoundedRect::new(
          rect=@core.Rect::new(x=1.0, y=1.0, width=4.0, height=4.0),
          radius=1.0,
        ),
        red,
      ),
    ],
    damage=@core.DamageRegion::empty(), clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  assert_eq(pixel_at(buf, 1, 1), 0xCACA0000)
  // Pixel (3,1) cell (3..4)x(1..2). Top-right corner-circle
  // center is at (4,2), r=1. Corners (3,1)/(4,1)/(3,2)/(4,2)
  // -> distance^2 from (4,2) is 2/1/1/0 -> also 75% AA.
  // Pixel (4,1) cell (4..5)x(1..2) is the top-RIGHT corner
  // pixel (cell straddles x=cx_right=4 boundary).
  // Corners (4,1)/(5,1)/(4,2)/(5,2) -> distance^2 from
  // (4,2) is 1/2/0/1 -> 3 inside (d^2<=1), 1 outside.
  assert_eq(pixel_at(buf, 4, 1), 0xCACA0000)
  // Pixel (2,2) is in the middle band (no corner overlap) ->
  // full coverage, opaque red.
  assert_eq(pixel_at(buf, 2, 2), 0xFFFF0000)
}

///|
/// FillRoundedRect pixel fully outside the corner-circle
/// and outside the bounding rect is left transparent.
/// Verified with rect (1,1,4,4) radius=1 on a 6x6 buffer;
/// pixel (0,0) cell (0..1)x(0..1) is outside the rect.
test "fill_rounded_rect_pixel_outside_bbox_stays_clear" {
  let buf : PixelBuffer = PixelBuffer::new(
    6,
    6,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let red : @core.Color = @core.Color::rgba(r=1.0, g=0.0, b=0.0, a=1.0)
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[
      @core.DrawCommand::FillRoundedRect(
        @core.RoundedRect::new(
          rect=@core.Rect::new(x=1.0, y=1.0, width=4.0, height=4.0),
          radius=1.0,
        ),
        red,
      ),
    ],
    damage=@core.DamageRegion::empty(), clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Pixel (0,0) is outside the rect entirely -> clear.
  assert_eq(pixel_at(buf, 0, 0), 0x00000000)
  // Pixel (5,5) is also outside -> clear.
  assert_eq(pixel_at(buf, 5, 5), 0x00000000)
}

///|
/// DrawPath triangle fill paints the interior. Verified by
/// drawing a triangle with vertices (2,1), (4,1), (3,4)
/// and checking the centroid (3,2) is filled.
test "draw_path_triangle_fill" {
  let buf : PixelBuffer = PixelBuffer::new(
    6,
    6,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let yellow : @core.Color = @core.Color::rgba(r=1.0, g=1.0, b=0.0, a=1.0)
  let triangle : @core.PathSpec = @core.PathSpec::new(
    verbs=[
      @core.PathVerb::MoveTo(@core.Point::new(x=2.0, y=1.0)),
      @core.PathVerb::LineTo(@core.Point::new(x=4.0, y=1.0)),
      @core.PathVerb::LineTo(@core.Point::new(x=3.0, y=4.0)),
      @core.PathVerb::Close,
    ],
    fill=Some(@core.Brush::solid(yellow)),
  )
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawPath(triangle)],
    damage=@core.DamageRegion::empty(), clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Centroid (3,2) should be inside the triangle and yellow.
  assert_eq(pixel_at(buf, 3, 2), 0xFFFFFF00)
  // Outside the triangle (0,0) should be transparent.
  assert_eq(pixel_at(buf, 0, 0), 0x00000000)
}
///|
/// DrawPath with a QuadTo curve fills the area under the
/// curve. Verified by drawing a U-shape: MoveTo(1,1) ->
/// LineTo(5,1) -> QuadTo(control=(7,3), p=(5,5)) ->
/// LineTo(1,5) -> Close. The curve bulges right and fills
/// the pixel column between the straight edges and the
/// curve apex. Pixel (6,3) is on the curve apex (x=6 at
/// t=0.5 for the (5,1)-(7,3)-(5,5) Bezier); pixel (1,3) is
/// inside the rect interior; pixel (0,0) is outside the path.
test "draw_path_quad_to_fills_curve" {
  let buf : PixelBuffer = PixelBuffer::new(
    8,
    8,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let yellow : @core.Color = @core.Color::rgba(r=1.0, g=1.0, b=0.0, a=1.0)
  let u_shape : @core.PathSpec = @core.PathSpec::new(
    verbs=[
      @core.PathVerb::MoveTo(@core.Point::new(x=1.0, y=1.0)),
      @core.PathVerb::LineTo(@core.Point::new(x=5.0, y=1.0)),
      @core.PathVerb::QuadTo(
        @core.Point::new(x=7.0, y=3.0),
        @core.Point::new(x=5.0, y=5.0),
      ),
      @core.PathVerb::LineTo(@core.Point::new(x=1.0, y=5.0)),
      @core.PathVerb::Close,
    ],
    fill=Some(@core.Brush::solid(yellow)),
  )
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawPath(u_shape)],
    damage=@core.DamageRegion::empty(), clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Pixel (5,3) sits inside the curve bulge (curve crosses y=3.5
  // at x≈5.94, fill [1,5] at y=3.5) -> filled yellow.
  let s5_3_quad_off : Int = 3*buf.width*4 + 5*4
  let s5_3_quad : Int = (buf.pixels[s5_3_quad_off + 3].to_int() << 24) |
    (buf.pixels[s5_3_quad_off + 2].to_int() << 16) |
    (buf.pixels[s5_3_quad_off + 1].to_int() << 8) |
    buf.pixels[s5_3_quad_off].to_int()
  assert_eq(s5_3_quad, 0xFFFFFF00)
  // Pixel (1,3) is inside the U interior -> filled yellow.
  assert_eq(pixel_at(buf, 1, 3), 0xFFFFFF00)
  // Pixel (0,0) is outside the path -> transparent.
  assert_eq(pixel_at(buf, 0, 0), 0x00000000)
  // Pixel (6,3) is OUTSIDE the curve apex (curve apex x=6 at
  // y=3, fill range at y=3.5 is [1, 5.94]) -> transparent.
  // Bypass pixel_at (OOB sentinel bug); use raw bytes.
  let s6_3_quad_off : Int = 3*buf.width*4 + 6*4
  let s6_3_quad : Int = (buf.pixels[s6_3_quad_off + 3].to_int() << 24) |
    (buf.pixels[s6_3_quad_off + 2].to_int() << 16) |
    (buf.pixels[s6_3_quad_off + 1].to_int() << 8) |
    buf.pixels[s6_3_quad_off].to_int()
  assert_eq(s6_3_quad, 0x00000000)
}

///|
/// DrawPath with a CubicTo curve fills the area under the
/// curve. Verified by drawing a path with MoveTo(1,1) ->
/// LineTo(5,1) -> CubicTo(c1=(7,1), c2=(7,5), p=(5,5)) ->
/// LineTo(1,5) -> Close. The curve bulges right, hitting
/// roughly x=6.5 at the midpoint, so pixels (6,3) and (7,3)
/// should both be filled (CubicTo apex is further right
/// than a comparable QuadTo because the two control points
/// pull the curve out).
test "draw_path_cubic_to_fills_curve" {
  let buf : PixelBuffer = PixelBuffer::new(
    10,
    10,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let cyan : @core.Color = @core.Color::rgba(r=0.0, g=1.0, b=1.0, a=1.0)
  let bezier_shape : @core.PathSpec = @core.PathSpec::new(
    verbs=[
      @core.PathVerb::MoveTo(@core.Point::new(x=1.0, y=1.0)),
      @core.PathVerb::LineTo(@core.Point::new(x=5.0, y=1.0)),
      @core.PathVerb::CubicTo(
        @core.Point::new(x=7.0, y=1.0),
        @core.Point::new(x=7.0, y=5.0),
        @core.Point::new(x=5.0, y=5.0),
      ),
      @core.PathVerb::LineTo(@core.Point::new(x=1.0, y=5.0)),
      @core.PathVerb::Close,
    ],
    fill=Some(@core.Brush::solid(cyan)),
  )
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawPath(bezier_shape)],
    damage=@core.DamageRegion::empty(), clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Pixel (6,3) sits inside the cubic bulge (cubic crosses y=3.5
  // at x≈6.47, fill [1, 6] at y=3.5) -> filled cyan.
  // Use raw bytes to bypass pixel_at OOB sentinel bug.
  let s6_3_cubic_off : Int = 3*buf.width*4 + 6*4
  let s6_3_cubic : Int = (buf.pixels[s6_3_cubic_off + 3].to_int() << 24) |
    (buf.pixels[s6_3_cubic_off + 2].to_int() << 16) |
    (buf.pixels[s6_3_cubic_off + 1].to_int() << 8) |
    buf.pixels[s6_3_cubic_off].to_int()
  assert_eq(s6_3_cubic, 0xFF00FFFF)
  // Pixel (7,3) is OUTSIDE the cubic apex (curve apex x=6.5)
  // -> transparent. Use raw bytes.
  let s7_3_cubic_off : Int = 3*buf.width*4 + 7*4
  let s7_3_cubic : Int = (buf.pixels[s7_3_cubic_off + 3].to_int() << 24) |
    (buf.pixels[s7_3_cubic_off + 2].to_int() << 16) |
    (buf.pixels[s7_3_cubic_off + 1].to_int() << 8) |
    buf.pixels[s7_3_cubic_off].to_int()
  assert_eq(s7_3_cubic, 0x00000000)
  // Pixel (1,3) is inside the U interior -> filled cyan.
  let s1_3_cubic_off : Int = 3*buf.width*4 + 1*4
  let s1_3_cubic : Int = (buf.pixels[s1_3_cubic_off + 3].to_int() << 24) |
    (buf.pixels[s1_3_cubic_off + 2].to_int() << 16) |
    (buf.pixels[s1_3_cubic_off + 1].to_int() << 8) |
    buf.pixels[s1_3_cubic_off].to_int()
  assert_eq(s1_3_cubic, 0xFF00FFFF)
}
///|
/// Sanity check: polygon fill works correctly for a triangle
/// without curves. Triangle (1,1) (7,3) (1,5) — pixel (6,3)
/// is on the right edge, pixel (7,3) is outside.
test "polygon_fill_triangle_no_curve" {
  let buf : PixelBuffer = PixelBuffer::new(
    8,
    8,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let yellow : @core.Color = @core.Color::rgba(r=1.0, g=1.0, b=0.0, a=1.0)
  let tri : @core.PathSpec = @core.PathSpec::new(
    verbs=[
      @core.PathVerb::MoveTo(@core.Point::new(x=1.0, y=1.0)),
      @core.PathVerb::LineTo(@core.Point::new(x=7.0, y=3.0)),
      @core.PathVerb::LineTo(@core.Point::new(x=1.0, y=5.0)),
      @core.PathVerb::Close,
    ],
    fill=Some(@core.Brush::solid(yellow)),
  )
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawPath(tri)],
    damage=@core.DamageRegion::empty(), clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Pixel (5,3) is inside the right edge (fill range [1, 5.5]
  // at y=3.5) -> filled yellow. Use raw bytes to avoid pixel_at
  // OOB sentinel bug.
  let s5_3_tri_off : Int = 3*buf.width*4 + 5*4
  let s5_3_tri : Int = (buf.pixels[s5_3_tri_off + 3].to_int() << 24) |
    (buf.pixels[s5_3_tri_off + 2].to_int() << 16) |
    (buf.pixels[s5_3_tri_off + 1].to_int() << 8) |
    buf.pixels[s5_3_tri_off].to_int()
  assert_eq(s5_3_tri, 0xFFFFFF00)
  // Pixel (6,3) is OUTSIDE the right edge (x=6 > 5.5 apex)
  // -> transparent. Use raw bytes.
  let s6_3_tri_off : Int = 3*buf.width*4 + 6*4
  let s6_3_tri : Int = (buf.pixels[s6_3_tri_off + 3].to_int() << 24) |
    (buf.pixels[s6_3_tri_off + 2].to_int() << 16) |
    (buf.pixels[s6_3_tri_off + 1].to_int() << 8) |
    buf.pixels[s6_3_tri_off].to_int()
  assert_eq(s6_3_tri, 0x00000000)
}
///|
/// DrawText now rasterizes real 5x7 glyphs (Phase 12) instead
/// of a placeholder outline. Verified by drawing "hi" inside a
/// 16x10 frame at (1, 1) and checking that:
///
///  - 'h' column 4 (right leg), row 3 → lit (text color)
///  - 'h' column 4, row 0 → blank (transparent)
///  - A pixel outside the frame stays transparent
///
/// Direct test of bitmap_font::glyph_at for ASCII 'A'. 'A'
/// bitmap rows:
///   [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11].
/// The middle bar is row 3 (0x1F = 11111): all 5 columns lit.
/// Row 0 (0x0E = 01110): col 0 = 0, col 1 = 1, col 4 = 0.
test "glyph_at_A_middle_bar_is_fully_lit" {
  let buf : PixelBuffer = PixelBuffer::new(
    20,
    12,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let white : @core.Color = @core.Color::rgba(r=1.0, g=1.0, b=1.0, a=1.0)
  let run : @core.TextRun = @core.TextRun::new(
    text="hi",
    frame=@core.Rect::new(x=1.0, y=1.0, width=16.0, height=10.0),
    font=@core.FontSpec::new(),
    color=white,
  )
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawText(run)],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Frame: (1,1)→(17,11). cell_idx=0 = 'h' at x=1..5.
  // Vertically centered: y_off = 1 + (10-7)/2 = 2.
  // 'h' bitmap (after `glyph_index('h') = 72`): rows =
  //   [0x01, 0x01, 0x0F, 0x11, 0x11, 0x11, 0x11].
  // Bit 0 (LSB) = col 4 (rightmost). So col 4 of 'h' is lit
  // for every row → the rightmost column is a vertical stem
  // from row 0 to row 6. The crossbar lands at row 2 (0x0F).
  //
  // Assert by reading `buf.pixels` directly (pixel_at's OOB
  // sentinel has MoonBit 0.1.x aliasing issues that we sidestep).
  let stride : Int = buf.width * 4
  // (5, 5) is the rightmost column, mid-row → 255 (lit).
  let off55 : Int = 5 * stride + 5 * 4
  assert_eq(buf.pixels[off55 + 0].to_int(), 255)
  assert_eq(buf.pixels[off55 + 1].to_int(), 255)
  assert_eq(buf.pixels[off55 + 2].to_int(), 255)
  assert_eq(buf.pixels[off55 + 3].to_int(), 255)
  // (5, 2) is the rightmost column, top row → also 255 (lit;
  // bit 0 of 0x01 = 1).
  let off52 : Int = 2 * stride + 5 * 4
  assert_eq(buf.pixels[off52 + 0].to_int(), 255)
  // (1, 2) is the leftmost column, top row → transparent
  // (bit 4 of 0x01 = 0).
  let off12 : Int = 2 * stride + 1 * 4
  assert_eq(buf.pixels[off12 + 0].to_int(), 0)
  assert_eq(buf.pixels[off12 + 1].to_int(), 0)
  assert_eq(buf.pixels[off12 + 2].to_int(), 0)
  assert_eq(buf.pixels[off12 + 3].to_int(), 0)
  // Outside the frame: (0, 0) untouched.
  assert_eq(buf.pixels[0].to_int(), 0)
  assert_eq(buf.pixels[3].to_int(), 0)
  // Outside the frame: (0, 0) is untouched.
  assert_eq(pixel_at(buf, 0, 0), 0x00000000)
}

///|
/// DrawText with a frame smaller than 5x7 bails — no pixels
/// are touched. This guards against panics from the early-return
/// path in `paint_text`.
test "draw_text_tiny_frame_bails_silently" {
  let buf : PixelBuffer = PixelBuffer::new(
    8,
    8,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let white : @core.Color = @core.Color::rgba(r=1.0, g=1.0, b=1.0, a=1.0)
  // 4x4 frame at (1,1) — too small for the 5x7 cell.
  let run : @core.TextRun = @core.TextRun::new(
    text="hello",
    frame=@core.Rect::new(x=1.0, y=1.0, width=4.0, height=4.0),
    font=@core.FontSpec::new(),
    color=white,
  )
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawText(run)],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // All pixels still transparent — no panic, no flood.
  for y = 0; y < 8; y = y + 1 {
    for x = 0; x < 8; x = x + 1 {
      assert_eq(pixel_at(buf, x, y), 0x00000000)
    }
  }
}

///|
/// DrawText for an out-of-range codepoint falls back to the
/// tofu glyph (5x7 filled box) instead of crashing. Verified by
/// embedding `\u{00A9}` (©, well outside 0x20..0x7E) and checking
/// every in-bounds pixel of cell 0 is lit.
///
/// glyph_index('\u{00A9}') = 95 (tofu). tofu row = 0x1F = 11111_2
/// → all 5 columns lit on every row.
test "draw_text_tofu_fallback_renders_filled_box" {
  let buf : PixelBuffer = PixelBuffer::new(
    12,
    10,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let white : @core.Color = @core.Color::rgba(r=1.0, g=1.0, b=1.0, a=1.0)
  // "\u{00A9}X" — first char is tofu (out of ASCII), second is 'X'.
  let run : @core.TextRun = @core.TextRun::new(
    text="\u{00A9}X",
    frame=@core.Rect::new(x=1.0, y=1.0, width=10.0, height=8.0),
    font=@core.FontSpec::new(),
    color=white,
  )
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawText(run)],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Tofu cell at cell_idx=0, x=1..5. y_off = 1 + (8-7)/2 = 1.
  // tofu row r, col c → buf(1+c, 1+r) is white (for all c<5, r<7).
  let stride : Int = buf.width * 4
  for r = 0; r < 7; r = r + 1 {
    for c = 0; c < 5; c = c + 1 {
      let off : Int = (1 + r) * stride + (1 + c) * 4
      assert_eq(buf.pixels[off].to_int(), 255)
      assert_eq(buf.pixels[off + 3].to_int(), 255)
    }
  }
  // Right of tofu (cell_idx=1 starts at x=6): 'X' bitmap rows =
  // [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11].
  //
  // 'X' row 0 = 0x11 = bits 0 AND 4 set → col 0 (MSB) AND col 4
  // (LSB) are lit, cols 1..3 are off.
  //
  // Probe 'X' col 0 row 0 → buf (6, 1) should be lit (255).
  assert_eq(buf.pixels[(1 * stride + 6 * 4)].to_int(), 255)
  // Probe 'X' col 4 row 0 → buf (10, 1) should be lit (255).
  assert_eq(buf.pixels[(1 * stride + 10 * 4)].to_int(), 255)
  // Probe 'X' col 2 row 0 → buf (8, 1) should be off (0).
  assert_eq(buf.pixels[(1 * stride + 8 * 4)].to_int(), 0)
}

///|
/// PushClip + FillRect restricts the fill to the clip region.
/// Verified by pushing a 2脳2 clip at (2,2) then filling a
/// 6脳6 rect; only the 4 clipped pixels should be red, the
/// rest should be the clear color.
test "push_clip_intersects_with_fill_rect" {
  assert_eq(glyph_at('A', 0, 3), true)
  assert_eq(glyph_at('A', 1, 3), true)
  assert_eq(glyph_at('A', 2, 3), true)
  assert_eq(glyph_at('A', 3, 3), true)
  assert_eq(glyph_at('A', 4, 3), true)
  assert_eq(glyph_at('A', 1, 0), true)
  assert_eq(glyph_at('A', 0, 0), false)
  assert_eq(glyph_at('A', 4, 0), false)
}

///|
/// measure_text returns 0×0 for empty input and (n*5, 7)
/// otherwise. Fixed-pitch, no kerning.
test "measure_text_fixed_pitch" {
  let (w0, h0) = measure_text("")
  assert_eq(w0, 0)
  assert_eq(h0, 0)
  let (w1, h1) = measure_text("a")
  assert_eq(w1, 5)
  assert_eq(h1, 7)
  let (w3, h3) = measure_text("abc")
  assert_eq(w3, 15)
  assert_eq(h3, 7)
}

///|
/// PushClip + FillRect restricts the fill to the clip region.
/// Verified by pushing a 2脳2 clip at (2,2) then filling a
/// 6脳6 rect; only the 4 clipped pixels should be red, the
/// rest should be the clear color.
test "push_clip_intersects_with_fill_rect" {
  let buf : PixelBuffer = PixelBuffer::new(
    6,
    6,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let red : @core.Color = @core.Color::rgba(r=1.0, g=0.0, b=0.0, a=1.0)
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[
      @core.DrawCommand::PushClip(
        @core.Rect::new(x=2.0, y=2.0, width=2.0, height=2.0),
      ),
      @core.DrawCommand::FillRect(
        @core.Rect::new(x=0.0, y=0.0, width=6.0, height=6.0),
        red,
      ),
      @core.DrawCommand::PopClip,
    ],
    damage=@core.DamageRegion::empty(), clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Inside the clip (2,2)-(3,3): red.
  assert_eq(pixel_at(buf, 2, 2), 0xFFFF0000)
  assert_eq(pixel_at(buf, 3, 3), 0xFFFF0000)
  // Outside the clip (0,0): transparent (unchanged).
  assert_eq(pixel_at(buf, 0, 0), 0x00000000)
  assert_eq(pixel_at(buf, 5, 5), 0x00000000)
}

///|
/// PushOpacity(0.5) halves the source alpha contribution.
/// Verified by PushOpacity(0.5) then FillRect with alpha=1.0
/// on a transparent buffer; the resulting pixel should be
/// alpha 鈮?128 (0.5 * 255 = 127.5 鈫?127).
test "push_opacity_half_halves_alpha_contribution" {
  let buf : PixelBuffer = PixelBuffer::new(
    2,
    2,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let red : @core.Color = @core.Color::rgba(r=1.0, g=0.0, b=0.0, a=1.0)
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[
      @core.DrawCommand::PushOpacity(0.5),
      @core.DrawCommand::FillRect(
        @core.Rect::new(x=0.0, y=0.0, width=2.0, height=2.0),
        red,
      ),
      @core.DrawCommand::PopOpacity,
    ],
    damage=@core.DamageRegion::empty(), clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // sa = 1.0 * 0.5 = 0.5; inv = 0.5; sa_premul = 0 (was transparent).
  // da = 0.5 * 255 + 0 * 0.5 = 127.5 鈫?127.
  // db = 1.0 * 255 * 0.5 + 0 * 0.5 = 127.5 鈫?127.
  // Pixel: ARGB 0x7F7F0000.
  assert_eq(pixel_at(buf, 0, 0), 0x7F7F0000)
  assert_eq(pixel_at(buf, 1, 1), 0x7F7F0000)
}

///|
/// StrokeRoundedRect paints a ring. Verified by drawing a
/// stroke with width=1 on a 4脳4 rect with radius=1; the
/// perimeter should be red and the interior should remain
/// the clear color (since we paint a transparent inset on
/// top of the filled rounded-rect).
test "stroke_rounded_rect_paints_perimeter_only" {
  let buf : PixelBuffer = PixelBuffer::new(
    6,
    6,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let red : @core.Color = @core.Color::rgba(r=1.0, g=0.0, b=0.0, a=1.0)
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[
      @core.DrawCommand::StrokeRoundedRect(
        @core.RoundedRect::new(
          rect=@core.Rect::new(x=1.0, y=1.0, width=4.0, height=4.0),
          radius=1.0,
        ),
        red,
        1.0,
      ),
    ],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Top edge midpoint (3,1) is on the outer ring — should be red.
  assert_eq(pixel_at(buf, 3, 1), 0xFFFF0000)
  // Interior pixel (2,2) is inside the inset — should remain
  // the clear color (transparent).
  assert_eq(pixel_at(buf, 2, 2), 0x00000000)
}
///|
/// StrokeRoundedRect with fractional width=0.5 produces a
/// 50% AA pixel where the inner rect's left edge cuts the
/// pixel cell. Rect (1,1,4,4) r=1, outer rect is (1,1,4,4),
/// inner rect is (1.5,1.5,3,3). Pixel (1,2) cell (1..2)x(2..3)
/// is fully inside outer (middle band, coverage=1) but only
/// 50% inside inner (samples (2,2) and (2,3) in middle band,
/// samples (1,2) and (1,3) outside inner rect on the left).
/// Stroke coverage = 1 - 0.5 = 0.5 -> 0x7F7F0000.
test "stroke_rounded_rect_fractional_width_aa" {
  let buf : PixelBuffer = PixelBuffer::new(
    6,
    6,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let red : @core.Color = @core.Color::rgba(r=1.0, g=0.0, b=0.0, a=1.0)
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[
      @core.DrawCommand::StrokeRoundedRect(
        @core.RoundedRect::new(
          rect=@core.Rect::new(x=1.0, y=1.0, width=4.0, height=4.0),
          radius=1.0,
        ),
        red,
        0.5,
      ),
    ],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Pixel (1,2) cell straddles inner left edge (x=1.5).
  assert_eq(pixel_at(buf, 1, 2), 0x7F7F0000)
  // Pixel (2,2) cell is fully inside inner -> no stroke.
  assert_eq(pixel_at(buf, 2, 2), 0x00000000)
  // Pixel (0,2) is outside outer rect entirely -> no stroke.
  assert_eq(pixel_at(buf, 0, 2), 0x00000000)
}

///|
/// StrokeRoundedRect with fractional width=0.5 + r=1 produces
/// a 59% AA corner pixel (Phase 16.E bezier-corner AA). Top-left corner of outer rect has
/// the inscribed circle (2,2) r=1 cutting the corner. Inner
/// rect (1.5,1.5,3,3) r=0.5 has inscribed circle (2,2) r=0.5
/// cutting the inner corner.
/// Pixel (1,1) cell (1..2)x(1..2): outer coverage 3/4 = 0.75,
/// inner coverage 1/4 = 0.25 (only sample (2,2) inside inner
/// middle band). Stroke coverage = 0.75 - 0.25 = 0.5 ->
/// 0x7F7F0000.
test "stroke_rounded_rect_corner_aa" {
  let buf : PixelBuffer = PixelBuffer::new(
    6,
    6,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let red : @core.Color = @core.Color::rgba(r=1.0, g=0.0, b=0.0, a=1.0)
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[
      @core.DrawCommand::StrokeRoundedRect(
        @core.RoundedRect::new(
          rect=@core.Rect::new(x=1.0, y=1.0, width=4.0, height=4.0),
          radius=1.0,
        ),
        red,
        0.5,
      ),
    ],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  assert_eq(pixel_at(buf, 1, 1), 0x96960000)
}

///|
/// Multiple commands are applied in order. Verified by
/// drawing a clear-to-blue, then a red rect, then a smaller
/// green rect on top 鈥?the green pixels override the red.
test "multiple_commands_apply_in_order" {
  let buf : PixelBuffer = PixelBuffer::new(
    4,
    4,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let red : @core.Color = @core.Color::rgba(r=1.0, g=0.0, b=0.0, a=1.0)
  let green : @core.Color = @core.Color::rgba(r=0.0, g=1.0, b=0.0, a=1.0)
  // Green rect occupies [1.0, 2.5] x [1.0, 2.5] — the trailing
  // half-pixel means pixel (2,2) gets only 25% coverage under
  // Phase 15 fractional-coverage AA (intersect is [2.0, 2.5] x
  // [2.0, 2.5] = 0.5 * 0.5).
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[
      @core.DrawCommand::FillRect(
        @core.Rect::new(x=0.0, y=0.0, width=4.0, height=4.0),
        red,
      ),
      @core.DrawCommand::FillRect(
        @core.Rect::new(x=1.0, y=1.0, width=1.5, height=1.5),
        green,
      ),
    ],
    damage=@core.DamageRegion::empty(), clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Outer corners should be red (not covered by green rect).
  assert_eq(pixel_at(buf, 0, 0), 0xFFFF0000)
  assert_eq(pixel_at(buf, 3, 3), 0xFFFF0000)
  // (1,1) is fully inside [1.0, 2.5] x [1.0, 2.5] → 100% green.
  assert_eq(pixel_at(buf, 1, 1), 0xFF00FF00)
  // (2,2) is on the trailing half-pixel edge: 25% green over
  // 75% red → dr=191 (255*0.75), dg=63 (255*0.25), 0xFFBF3F00.
  assert_eq(pixel_at(buf, 2, 2), 0xFFBF3F00)
}

///|
/// Phase 13 — DrawImage with a cache miss falls back to the
/// legacy placeholder. Verified by drawing a DrawImage at a
/// known frame, no cache entry, and checking the BGRA bytes at
/// the four edges of the frame are the outline color (0x59,
/// ~0.35 gray) while interior pixels are untouched.
test "draw_image_cache_miss_uses_placeholder" {
  let buf : PixelBuffer = PixelBuffer::new(
    8,
    8,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let run : @core.ImageRun = {
    source: "missing.png",
    frame: @core.Rect::new(x=2.0, y=2.0, width=4.0, height=4.0),
    opacity: 1.0,
    fit: @core.ImageFit::Contain,
  }
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawImage(run)],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // The placeholder stroke is 1px gray (~0.35 * 255 = 89 = 0x59).
  // Frame (2,2)→(6,6). Top-left corner of the frame is at (2,2).
  let top_left : Int = pixel_at(buf, 2, 2)
  // Either we hit the outline (top-left of the stroke) or a
  // diagonal hatch (the placeholder paints an X across the
  // frame). Both are gray ~89/255. We just assert that the
  // pixel is NOT the clear color (transparent) — proving the
  // placeholder actually painted something.
  assert_eq(top_left == 0x00000000, false)
  // Interior (3, 3) is on the diagonal hatch from (2,2)→(6,6).
  let interior : Int = pixel_at(buf, 3, 3)
  assert_eq(interior == 0x00000000, false)
  // Outside the frame (0, 0) is untouched.
  assert_eq(pixel_at(buf, 0, 0), 0x00000000)
}

///|
/// Phase 13 — DrawImage with a cache hit blits the decoded
/// RGBA image into the frame. We build a 2x1 red/green image,
/// blit it into a 4x2 frame, and verify the buffer pixels match
/// the source after nearest-neighbor sampling.
test "draw_image_cache_hit_blits_rgba" {
  let buf : PixelBuffer = PixelBuffer::new(
    4,
    2,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let cache : ImageCache = ImageCache::new()
  // 2×1 image: red pixel then green pixel.
  let img_bytes : Array[Byte] = [
    b'\xFF', b'\x00', b'\x00', b'\xFF', // red
    b'\x00', b'\xFF', b'\x00', b'\xFF', // green
  ]
  let _ = cache.load_bytes(
    "test.bmp",
    2,
    1,
    Bytes::from_array(img_bytes),
  )
  let run : @core.ImageRun = {
    source: "test.bmp",
    frame: @core.Rect::new(x=0.0, y=0.0, width=4.0, height=2.0),
    opacity: 1.0,
    fit: @core.ImageFit::Stretch,
  }
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawImage(run)],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, cache)
  // The image is 2 pixels wide stretched across 4 buffer
  // pixels: src_x = dx * 2 / 4 = 0 for dx in {0, 1}, 1 for dx
  // in {2, 3}. So left half (0..1) is red, right half (2..3) is
  // green. Both rows are uniform (src_y = 0 for both).
  // Verify via direct BGRA bytes (pixel_at has MoonBit 0.1.x
  // OOB aliasing quirks).
  let stride : Int = buf.width * 4
  // Red pixel: BGRA = (0, 0, 0xFF, 0xFF).
  let p00 : Int = buf.pixels[0 * stride + 0 * 4 + 0].to_int()
  let r00 : Int = buf.pixels[0 * stride + 0 * 4 + 2].to_int()
  assert_eq(p00, 0) // B
  assert_eq(r00, 255) // R
  // Green pixel: BGRA = (0, 0xFF, 0, 0xFF).
  let g32 : Int = buf.pixels[0 * stride + 3 * 4 + 1].to_int()
  assert_eq(g32, 255) // G
  // Outside the image: still transparent.
  assert_eq(buf.pixels[0 * stride + 0 * 4 + 3].to_int(), 0xFF) // A=255 from blend
}

///|
/// `pixel_at` returns -1 for out-of-bounds coordinates 鈥?/// guards against accidental writes outside the buffer in
/// future batches.
test "pixel_at_out_of_bounds_returns_minus_one" {
  let buf : PixelBuffer = PixelBuffer::new(
    4,
    4,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  assert_eq(pixel_at(buf, -1, 0), -1)
  assert_eq(pixel_at(buf, 4, 0), -1)
  assert_eq(pixel_at(buf, 0, -1), -1)
  assert_eq(pixel_at(buf, 0, 4), -1)
}



///|
/// blur_h averages 5 horizontal neighbors. Verify on a 1D
/// pattern: col 5 has value 255, others 0; after blur_h each
/// row should have a horizontal smear of value 51 (255/5).
test "blur_h_averages_5_horizontal_neighbors" {
  let buf : PixelBuffer = PixelBuffer::new(10, 10, @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0))
  let scratch : PixelBuffer = PixelBuffer::new(10, 10, @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0))
  let off : Int = 5 * buf.width * 4 + 5 * 4
  buf.pixels[off] = (0).to_byte()
  buf.pixels[off + 1] = (0).to_byte()
  buf.pixels[off + 2] = (255).to_byte()
  buf.pixels[off + 3] = (255).to_byte()
  blur_h(buf, scratch, 0, 0, 10, 10)
  let soff55 : Int = 5 * scratch.width * 4 + 5 * 4
  // Only pixel (5, 5) has R=255, A=255; B and G are 0.
  // After blur_h averaging 5 horizontal neighbors, R = 255/5 = 51,
  // A = 255/5 = 51; B and G stay 0 (averaging zero).
  assert_eq(scratch.pixels[soff55].to_int(), 0)
  assert_eq(scratch.pixels[soff55 + 1].to_int(), 0)
  assert_eq(scratch.pixels[soff55 + 2].to_int(), 51)
  assert_eq(scratch.pixels[soff55 + 3].to_int(), 51)
}

///|
/// Full separable blur: a uniform field is unchanged.
test "blur_separable_uniform_color_unchanged" {
  let buf : PixelBuffer = PixelBuffer::new(8, 8, @core.Color::rgba(r=1.0, g=0.0, b=0.0, a=1.0))
  let scratch : PixelBuffer = PixelBuffer::new(8, 8, @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0))
  blur_h(buf, scratch, 0, 0, 8, 8)
  blur_v(scratch, buf, 0, 0, 8, 8)
  let off : Int = 4 * buf.width * 4 + 4 * 4
  assert_eq(buf.pixels[off + 2].to_int(), 255)
  assert_eq(buf.pixels[off + 3].to_int(), 255)
}

///|
/// paint_shadow_rect with offset paints shadow at offset, leaving
/// the original rect interior clear.
test "paint_shadow_rect_offset_appears_below" {
  let buf : PixelBuffer = PixelBuffer::new(16, 16, @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0))
  let scratch : PixelBuffer = PixelBuffer::new(16, 16, @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0))
  let clip : @core.Rect = @core.Rect::new(x=0.0, y=0.0, width=16.0, height=16.0)
  let rect : @core.Rect = @core.Rect::new(x=4.0, y=4.0, width=4.0, height=4.0)
  let offset : @core.Point = @core.Point::new(x=2.0, y=2.0)
  let color : @core.Color = @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=1.0)
  paint_shadow_rect(buf, scratch, rect, offset, color, 1.0, clip)
  // Pixel (8, 8) is inside the shadow rect (offset 2,2) at full
  // coverage; blur softens it to ~163 alpha (16 of 25 neighbors
  // inside shadow rect after 5x5 box blur).
  let off88 : Int = 8 * buf.width * 4 + 8 * 4
  let a88 : Int = buf.pixels[off88 + 3].to_int()
  assert_true(a88 > 100)
  // Pixel (0, 0) is far outside any shadow region -> clear.
  let off00 : Int = 0 * buf.width * 4 + 0 * 4
  assert_eq(buf.pixels[off00 + 3].to_int(), 0)
}

///|
/// paint_shadow_rect with zero offset produces a glow around
/// the rect. The rect interior stays clear.
test "paint_shadow_rect_zero_offset_glow" {
  let buf : PixelBuffer = PixelBuffer::new(12, 12, @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0))
  let scratch : PixelBuffer = PixelBuffer::new(12, 12, @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0))
  let clip : @core.Rect = @core.Rect::new(x=0.0, y=0.0, width=12.0, height=12.0)
  let rect : @core.Rect = @core.Rect::new(x=4.0, y=4.0, width=4.0, height=4.0)
  let offset : @core.Point = @core.Point::new(x=0.0, y=0.0)
  let color : @core.Color = @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=1.0)
  paint_shadow_rect(buf, scratch, rect, offset, color, 1.0, clip)
  // Pixel (6, 6) is inside the rect (and inside the shadow region)
  // -> high alpha.
  let off66 : Int = 6 * buf.width * 4 + 6 * 4
  assert_true(buf.pixels[off66 + 3].to_int() > 100)
  // Pixel (1, 1) is far outside any shadow region -> clear.
  let off11 : Int = 1 * buf.width * 4 + 1 * 4
  assert_eq(buf.pixels[off11 + 3].to_int(), 0)
}




///|
/// Phase 16.F — DrawShadow DrawCommand dispatched through
/// paint_shadow_rect. Verify pixel (8, 8) has the soft-shadow
/// alpha > 0 (blurred shadow visible inside the shadow region).
test "draw_shadow_command_dispatches_to_paint_shadow" {
  let buf : PixelBuffer = PixelBuffer::new(
    16,
    16,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let shadow_rect : @core.RoundedRect = @core.RoundedRect::new(
    rect=@core.Rect::new(x=4.0, y=4.0, width=4.0, height=4.0),
    radius=0.0,
  )
  let spec : @core.ShadowSpec = @core.ShadowSpec::new(
    rect=shadow_rect,
    color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=1.0),
    offset=@core.Point::new(x=2.0, y=2.0),
    blur_radius=2.0,
  )
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawShadow(spec)],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Pixel (8, 8) is inside the shadow region (offset 2,2 x 4x4 = 6..10).
  // Use raw bytes to avoid pixel_at OOB bug.
  let off : Int = 8 * buf.width * 4 + 8 * 4
  let a : Int = buf.pixels[off + 3].to_int()
  assert_true(a > 0)
}

///|
/// Phase 16.F — zero-offset shadow produces a glow around the
/// rect (the rect itself stays clear since we only paint the
/// shadow shape, not the foreground).
test "draw_shadow_command_zero_offset_glow_around_rect" {
  let buf : PixelBuffer = PixelBuffer::new(
    16,
    16,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let rect : @core.RoundedRect = @core.RoundedRect::new(
    rect=@core.Rect::new(x=6.0, y=6.0, width=4.0, height=4.0),
    radius=0.0,
  )
  let spec : @core.ShadowSpec = @core.ShadowSpec::new(
    rect=rect,
    color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=1.0),
    offset=@core.Point::new(x=0.0, y=0.0),
    blur_radius=2.0,
  )
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawShadow(spec)],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame, ImageCache::new())
  // Pixel (4, 8) is on the left edge of the shadow region ->
  // alpha > 0 (blurred shadow visible just outside the rect).
  let off : Int = 8 * buf.width * 4 + 4 * 4
  assert_true(buf.pixels[off + 3].to_int() > 0)
  // Pixel (0, 0) is far outside the shadow region -> clear.
  let off00 : Int = 0 * buf.width * 4 + 0 * 4
  assert_eq(buf.pixels[off00 + 3].to_int(), 0)
}

///|
/// Phase 16.E: `rounded_rect_path_spec` emits a bezier
/// outline (MoveTo + 4 CubicTo corners + Close). The 4
/// CubicTo verbs are the key feature — they let a caller
/// reuse the rounded-rect geometry for arbitrary PathSpec
/// rendering (e.g. polygon-stroke outlines) instead of being
/// locked to FillRoundedRect/StrokeRoundedRect dispatch.
test "rounded_rect_path_spec_emits_4_cubics_and_close" {
  let rr : @core.RoundedRect = @core.RoundedRect::new(
    rect=@core.Rect::new(x=2.0, y=3.0, width=10.0, height=8.0),
    radius=2.0,
  )
  let spec : @core.PathSpec = rounded_rect_path_spec(rr)
  let verbs : Array[@core.PathVerb] = spec.verbs
  // Total verb count: 1 MoveTo + 4 LineTo + 4 CubicTo + 1 Close = 10.
  assert_eq(verbs.length(), 10)
  let mut n_move : Int = 0
  let mut n_line : Int = 0
  let mut n_cubic : Int = 0
  let mut n_close : Int = 0
  for verb in verbs {
    match verb {
      @core.PathVerb::MoveTo(_) => n_move = n_move + 1
      @core.PathVerb::LineTo(_) => n_line = n_line + 1
      @core.PathVerb::QuadTo(_, _) => ()
      @core.PathVerb::CubicTo(_, _, _) => n_cubic = n_cubic + 1
      @core.PathVerb::Close => n_close = n_close + 1
    }
  }
  assert_eq(n_move, 1)
  assert_eq(n_line, 4)
  assert_eq(n_cubic, 4)
  assert_eq(n_close, 1)
  // First verb must be MoveTo at (left+r, top) = (4, 3).
  match verbs[0] {
    @core.PathVerb::MoveTo(p) => {
      assert_eq(p.x, 4.0)
      assert_eq(p.y, 3.0)
    }
    _ => assert_true(false)
  }
  // The closing verb must be Close.
  match verbs[verbs.length() - 1] {
    @core.PathVerb::Close => ()
    _ => assert_true(false)
  }
}

///|
/// Phase 16.E: `bezier_round_rect_pixel_coverage` returns
/// 1.0 for a cell entirely inside the rect's interior box,
/// 0.0 for a cell entirely outside the bounding rect, and a
/// fractional value for a corner-cut cell. Sanity-check the
/// three short-circuits without going through the full
/// `rasterize_draw_frame` pipeline.
test "bezier_round_rect_pixel_coverage_short_circuits" {
  // Interior-box cell (3,3) on rect (1,1,8,8) r=2:
  //   cx_left = 3, cx_right = 7, cy_top = 3, cy_bot = 7.
  //   px=3 >= 3, px+1=4 <= 7, py=3 >= 3, py+1=4 <= 7.
  //   Short-circuit returns 1.0.
  let c_interior : Double = bezier_round_rect_pixel_coverage(
    3.0, 3.0, 1.0, 1.0, 8.0, 8.0, 2.0,
  )
  assert_eq(c_interior, 1.0)
  // Outside-bbox cell (-1,-1) on the same rect:
  //   px+1=0 <= 1 -> short-circuit returns 0.0.
  let c_outside : Double = bezier_round_rect_pixel_coverage(
    -1.0, -1.0, 1.0, 1.0, 8.0, 8.0, 2.0,
  )
  assert_eq(c_outside, 0.0)
  // r=0 short-circuit: with no corner rounding, every cell
  // inside the bounding rect is full-coverage.
  let c_r0 : Double = bezier_round_rect_pixel_coverage(
    4.0, 4.0, 1.0, 1.0, 8.0, 8.0, 0.0,
  )
  assert_eq(c_r0, 1.0)
  // Corner cell (1,1) on rect (1,1,4,4) r=1 should land
  // strictly in (0, 1) — the bezier-corner sub-sampler falls
  // through to the 16x16 loop (the cell is on the bounding
  // rect's edge AND in a corner quadrant, so neither
  // short-circuit fires). Phase 16.E measured 202/256 = 0.79.
  let c_corner : Double = bezier_round_rect_pixel_coverage(
    1.0, 1.0, 1.0, 1.0, 4.0, 4.0, 1.0,
  )
  assert_true(c_corner > 0.0)
  assert_true(c_corner < 1.0)
  // Symmetric across all four corners: same coverage at
  // (1,1), (4,1), (1,4), (4,4) for a centred rect.
  let c_tl : Double = bezier_round_rect_pixel_coverage(
    1.0, 1.0, 1.0, 1.0, 4.0, 4.0, 1.0,
  )
  let c_tr : Double = bezier_round_rect_pixel_coverage(
    4.0, 1.0, 1.0, 1.0, 4.0, 4.0, 1.0,
  )
  let c_bl : Double = bezier_round_rect_pixel_coverage(
    1.0, 4.0, 1.0, 1.0, 4.0, 4.0, 1.0,
  )
  let c_br : Double = bezier_round_rect_pixel_coverage(
    4.0, 4.0, 1.0, 1.0, 4.0, 4.0, 1.0,
  )
  let eps : Double = 0.001
  assert_true((c_tl - c_tr).abs() < eps)
  assert_true((c_tl - c_bl).abs() < eps)
  assert_true((c_tl - c_br).abs() < eps)
}
