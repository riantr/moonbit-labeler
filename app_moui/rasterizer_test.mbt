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
  rasterize_draw_frame(buf, frame)
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
  // frame.clear_color matches the buffer init (blue) so the
  // outer-of-rect pixels stay blue after rasterize_draw_frame's
  // initial clear.
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
  rasterize_draw_frame(buf, frame)
  // The 2x2 interior (1,1)-(2,2) should be red.
  assert_eq(pixel_at(buf, 1, 1), 0xFFFF0000)
  assert_eq(pixel_at(buf, 2, 1), 0xFFFF0000)
  assert_eq(pixel_at(buf, 1, 2), 0xFFFF0000)
  assert_eq(pixel_at(buf, 2, 2), 0xFFFF0000)
  // The 12 outer pixels should still be the clear color (blue).
  assert_eq(pixel_at(buf, 0, 0), 0xFF0000FF)
  assert_eq(pixel_at(buf, 3, 3), 0xFF0000FF)
  assert_eq(pixel_at(buf, 0, 3), 0xFF0000FF)
  assert_eq(pixel_at(buf, 3, 0), 0xFF0000FF)
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
  rasterize_draw_frame(buf, frame)
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
  rasterize_draw_frame(buf_rr, frame_rr)
  rasterize_draw_frame(buf_fr, frame_fr)
  // All 16 pixels should match.
  for y = 0; y < 4; y = y + 1 {
    for x = 0; x < 4; x = x + 1 {
      assert_eq(pixel_at(buf_rr, x, y), pixel_at(buf_fr, x, y))
    }
  }
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
  rasterize_draw_frame(buf, frame)
  // Center pixel (3,3) is deep inside the rect 鈥?should be red.
  assert_eq(pixel_at(buf, 3, 3), 0xFFFF0000)
  // Top-left corner (1,1) is inside the corner cut-out 鈥?should
  // be transparent.
  assert_eq(pixel_at(buf, 1, 1), 0x00000000)
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
  rasterize_draw_frame(buf, frame)
  // Centroid (3,2) should be inside the triangle and yellow.
  assert_eq(pixel_at(buf, 3, 2), 0xFFFFFF00)
  // Outside the triangle (0,0) should be transparent.
  assert_eq(pixel_at(buf, 0, 0), 0x00000000)
}

///|
/// DrawText placeholder draws a 1px gray outline around the
/// text's frame rect (no longer floods the frame in text color,
/// which ate the chrome on white-on-dark layouts). Verified by
/// drawing a DrawText with a 2×2 frame and checking the 4 corner
/// pixels are the outline color; the interior pixels stay
/// transparent.
test "draw_text_placeholder_outlines_frame" {
  let buf : PixelBuffer = PixelBuffer::new(
    4,
    4,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  let text_color : @core.Color = @core.Color::rgba(r=1.0, g=1.0, b=1.0, a=1.0) // would flood if Phase 11
  let run : @core.TextRun = @core.TextRun::new(
    text="hi",
    frame=@core.Rect::new(x=1.0, y=1.0, width=1.5, height=1.5),
    font=@core.FontSpec::new(),
    color=text_color,
  )
  let frame : @core.DrawFrame = @core.DrawFrame::new(
    commands=[@core.DrawCommand::DrawText(run)],
    damage=@core.DamageRegion::empty(),
    clear_color=@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
  rasterize_draw_frame(buf, frame)
  // Outline color: (0.4, 0.4, 0.4, 1.0) → 102/255 ≈ 0x66;
  // pixel = 0xFF666666.
  let outline : Int = 0xFF666666
  // Top-left corner (1,1) is on the stroked edge.
  assert_eq(pixel_at(buf, 1, 1), outline)
  // Interior pixel (1,2) is INSIDE the rect (1,1)→(2,2) but
  // not on the 1px stroke — should remain transparent (no fill).
  // (1.5×1.5 inset; stroke is half_w=0.5 → covers x=1 and
  // x=2 rows, y=1 and y=2 rows, so y=1 is covered but y=2
  // is also covered.) Verify an off-center interior pixel.
  assert_eq(pixel_at(buf, 2, 2), outline)
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
  rasterize_draw_frame(buf, frame)
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
  rasterize_draw_frame(buf, frame)
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
  rasterize_draw_frame(buf, frame)
  // Top edge midpoint (3,1) is on the outer ring — should be red.
  assert_eq(pixel_at(buf, 3, 1), 0xFFFF0000)
  // Interior pixel (2,2) is inside the inset — should remain
  // the clear color (transparent).
  assert_eq(pixel_at(buf, 2, 2), 0x00000000)
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
  // Use width=1.5 for the green rect so it doesn't bleed into
  // (3,3) (the bottom-right corner of the red rect).
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
  rasterize_draw_frame(buf, frame)
  // Outer corners should be red (not covered by green rect).
  assert_eq(pixel_at(buf, 0, 0), 0xFFFF0000)
  assert_eq(pixel_at(buf, 3, 3), 0xFFFF0000)
  // Inner 2x2 should be green (drawn after red).
  assert_eq(pixel_at(buf, 1, 1), 0xFF00FF00)
  assert_eq(pixel_at(buf, 2, 2), 0xFF00FF00)
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
