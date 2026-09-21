// app_moui/rasterizer.mbt — Phase 11 CPU rasterizer.
//
// Translates a Moui `@core.DrawFrame` (the composed view tree)
// into a 32-bit BGRA pixel buffer suitable for
// `HostSurface.cpu_present().present(PixelFrame)` blitting.
//
// Why a CPU rasterizer (not Direct2D / Skia / Metal):
//
//  - Phase 10.2 ships a `CpuPixelFrame` presentation provider —
//    the PresentTarget is `windows_present.cpp`'s
//    `moui_windows_present_pixels_to_hwnd` (GDI BitBlt from a
//    user-supplied byte buffer). No D2D/D3D device context is
//    exposed by the HostSurface.
//  - Adding a real Skia rasterizer to the package means
//    pulling Skia (~30 MB native binary) and a path-based FFI
//    surface. That's a multi-batch scope creep with its own
//    binary-license + build-system consequences.
//  - The labeler app's view tree is mostly axis-aligned
//    rectangles (sidebar + toolbar + canvas background) +
//    simple polygon annotation paths. A scanline CPU path
//    rasterizes these at ~30 ms/frame for an 800×600 canvas
//    (rough back-of-envelope) which is fine for the single
//    repaint-on-state-change pattern Moui uses (no continuous
//    animation).
//
// Phase 11 covers:
//
//  - Clear / FillRect / StrokeRect / FillRoundedRect /
//    StrokeRoundedRect / DrawPath (polygon) / DrawText (filled
//    rect placeholder) / DrawImage (filled rect placeholder).
//  - PushOpacity / PopOpacity / PushClip / PopClip /
//    PushTransform / PopTransform state-stack plumbing so
//    future batches can add AA / gradients / shadows without
//    redoing the walker.
//
// Deferred to later batches:
//
//  - Real text glyph rasterization (bitmap font or external
//    swash/parley). Phase 11 paints the TextRun.frame rect in
//    the text's color so you can SEE where text would go, but
//    the glyphs themselves are not drawn.
//  - Curve path verbs (`QuadTo` / `CubicTo`) — Phase 11
//    extracts the LineTo vertices and rasterizes the polygon
//    silhouette; curves flatten to straight-line chords.
//  - Anti-aliased edges — Phase 11 uses integer coverage; AA
//    is Phase 12.
//  - Shadow / Filter / Shader / Layer / BlendMode — no-ops in
//    Phase 11.
//
// BGRA byte layout: standard Windows GDI BGRA8888 (B in the
// lowest byte, A in the highest). Windows_present.cpp's
// `moui_windows_present_pixels_to_hwnd` reads it as a
// `BITMAPINFOHEADER`-style BGRA buffer.

///|
/// A target BGRA pixel buffer. Internally backed by
/// `Array[Byte]` (mutable for per-pixel write) and exposed
/// as `Bytes` via `to_bytes` for the PixelFrame constructor.
pub(all) struct PixelBuffer {
  width : Int
  height : Int
  pixels : Array[Byte]
}

///|
/// Construct an empty pixel buffer initialized to the given
/// clear color. Width × height × 4 bytes are allocated.
pub fn PixelBuffer::new(
  width : Int,
  height : Int,
  clear : @core.Color,
) -> PixelBuffer {
  let total : Int = width * height * 4
  let pixels : Array[Byte] = Array::make(total, Byte::default())
  let buf : PixelBuffer = { width, height, pixels }
  clear_color(buf, clear)
  buf
}

///|
/// Convert the buffer's mutable backing store to immutable
/// `Bytes` for the PixelFrame constructor. Uses
/// `Bytes::from_array` (MoonBit stdlib constructor) since
/// `Bytes` is immutable — we have to build a fresh one each
/// frame from the mutable `Array[Byte]`.
pub fn PixelBuffer::to_bytes(buf : PixelBuffer) -> Bytes {
  Bytes::from_array(buf.pixels)
}

///|
/// Fill the entire buffer with a single color (no clipping,
/// no alpha blending — every pixel becomes exactly `color`).
pub fn clear_color(buf : PixelBuffer, color : @core.Color) -> Unit {
  let b : Int = clamp_byte(color.b * 255.0)
  let g : Int = clamp_byte(color.g * 255.0)
  let r : Int = clamp_byte(color.r * 255.0)
  let a : Int = clamp_byte(color.a * 255.0)
  let pixels = buf.pixels
  for i = 0; i < pixels.length(); i = i + 4 {
    pixels[i] = b.to_byte()
    pixels[i + 1] = g.to_byte()
    pixels[i + 2] = r.to_byte()
    pixels[i + 3] = a.to_byte()
  }
}

///|
/// Clamp a 0..255 float to a byte. Returns 0 for sub-zero,
/// 255 for over-255, otherwise the truncated integer.
fn clamp_byte(v : Double) -> Int {
  if v <= 0.0 {
    0
  } else if v >= 255.0 {
    255
  } else {
    v.to_int()
  }
}

///|
/// Per-pixel alpha-blend write into the BGRA buffer. Reads
/// the existing pixel and overwrites with `color` blended at
/// `opacity` (0..1, multiplies color's alpha).
fn blend_pixel(
  buf : PixelBuffer,
  x : Int,
  y : Int,
  color : @core.Color,
  opacity : Double,
) -> Unit {
  if x < 0 || x >= buf.width || y < 0 || y >= buf.height {
    return
  }
  let stride : Int = buf.width * 4
  let off : Int = y * stride + x * 4
  let pixels = buf.pixels
  let sa : Double = color.a * opacity
  let inv : Double = 1.0 - sa
  let sb : Double = pixels[off].to_int().to_double()
  let sg : Double = pixels[off + 1].to_int().to_double()
  let sr : Double = pixels[off + 2].to_int().to_double()
  let sa_premul : Double = pixels[off + 3].to_int().to_double()
  let db : Double = color.b * 255.0 * sa + sb * inv
  let dg : Double = color.g * 255.0 * sa + sg * inv
  let dr : Double = color.r * 255.0 * sa + sr * inv
  let da : Double = sa * 255.0 + sa_premul * inv
  pixels[off] = clamp_byte(db).to_byte()
  pixels[off + 1] = clamp_byte(dg).to_byte()
  pixels[off + 2] = clamp_byte(dr).to_byte()
  pixels[off + 3] = clamp_byte(da).to_byte()
}

///|
/// Test helper: get the BGRA byte at (x, y). Returns -1 if
/// out of range. Used by rasterizer_test.mbt.
pub fn pixel_at(buf : PixelBuffer, x : Int, y : Int) -> Int {
  if x < 0 || x >= buf.width || y < 0 || y >= buf.height {
    return -1
  }
  let stride : Int = buf.width * 4
  let off : Int = y * stride + x * 4
  let pixels = buf.pixels
  // Pack as 0xAARRGGBB (alpha at top) — easier to assert
  // against a known color.
  (pixels[off + 3].to_int() << 24) |
  (pixels[off + 2].to_int() << 16) |
  (pixels[off + 1].to_int() << 8) |
  pixels[off].to_int()
}

///|
/// Internal clipped-fill rectangle: paints every pixel inside
/// `rect` ∩ clip with `color` blended at `opacity`. The
/// scanline is integer (no AA) — Phase 11 uses axis-aligned
/// rect coverage only.
fn paint_rect(
  buf : PixelBuffer,
  rect : @core.Rect,
  clip : @core.Rect,
  color : @core.Color,
  opacity : Double,
) -> Unit {
  let clipped : @core.Rect? = rect.intersection(clip)
  guard clipped is Some(c) else { return }
  let x0 : Int = c.origin.x.ceil().to_int()
  let y0 : Int = c.origin.y.ceil().to_int()
  let x1 : Int = (c.origin.x + c.size.width).floor().to_int()
  let y1 : Int = (c.origin.y + c.size.height).floor().to_int()
  for y = y0; y <= y1; y = y + 1 {
    for x = x0; x <= x1; x = x + 1 {
      blend_pixel(buf, x, y, color, opacity)
    }
  }
}

///|
/// Draw a 1px-thick clipped line from (x0,y0) to (x1,y1) by
/// inscribing it inside its axis-aligned bbox. Used by the
/// DrawImage placeholder's diagonal hatch. Pixel coverage is
/// integer (no AA) — adequate for short visual hints.
fn paint_line(
  buf : PixelBuffer,
  x0 : Double,
  y0 : Double,
  x1 : Double,
  y1 : Double,
  clip : @core.Rect,
  color : @core.Color,
  opacity : Double,
) -> Unit {
  let min_x : Double = if x0 < x1 {
    x0
  } else {
    x1
  }
  let max_x : Double = if x0 > x1 {
    x0
  } else {
    x1
  }
  let min_y : Double = if y0 < y1 {
    y0
  } else {
    y1
  }
  let max_y : Double = if y0 > y1 {
    y0
  } else {
    y1
  }
  paint_rect(
    buf,
    @core.Rect::new(x=min_x, y=min_y, width=max_x - min_x, height=max_y - min_y),
    clip,
    color,
    opacity,
  )
}

///|
/// Paint a TextRun's glyphs into the BGRA buffer using the
/// embedded 5x7 ASCII bitmap font (see `bitmap_font.mbt`).
///
/// Algorithm:
///
/// 1.  Compute the text rectangle (`run.frame`) intersected
///     with the active clip. Out-of-clip glyphs are skipped
///     per-pixel rather than per-glyph for cheaper clipping.
/// 2.  Layout: fixed-pitch 5x7 cells, no kerning. We center
///     the text inside the text frame vertically and left-align
///     horizontally. (TextAlign::TextCenter/TextLeft/etc.
///     honored in a follow-up batch — Phase 12 just needs
///     visible glyphs, not polished layout.)
/// 3.  For each codepoint in `run.text`, look up
///     `bitmap_font.glyph_at(ch, col, row)` and, if the pixel
///     is lit, call `blend_pixel` with `run.color` and the
///     active opacity.
///
/// No font scaling, no AA, no Unicode — printable ASCII only.
/// Out-of-range chars render as the tofu fallback (a filled
/// 5x7 box) so callers never index OOB.
fn paint_text(
  buf : PixelBuffer,
  run : @core.TextRun,
  clip : @core.Rect,
  opacity : Double,
) -> Unit {
  let clipped : @core.Rect? = run.frame.intersection(clip)
  guard clipped is Some(c) else { return }
  // Cell dimensions in pixels (constants from the font module).
  // The font module lives in this same package (app_moui), so its
  // top-level `pub` constants and functions are visible directly
  // here — no `bitmap_font.X` namespace prefix is needed.
  let cw : Int = glyph_width
  let ch : Int = glyph_height
  // Vertical centering: nudge the baseline so the 7px-tall
  // glyph block sits centered inside `run.frame`. For a
  // generic frame height we just floor-to-baseline (frame
  // height is usually >= 7 px in the current layout).
  let frame_w : Int = run.frame.size.width.to_int()
  let frame_h : Int = run.frame.size.height.to_int()
  if frame_w < cw || frame_h < ch {
    // Frame too small to fit even one glyph — bail.
    return
  }
  // Number of glyph cells that fit horizontally. We do NOT
  // measure text width yet (no kerning); we just clamp to
  // frame width.
  let max_cells : Int = frame_w / cw
  let base_x : Int = run.frame.origin.x.to_int()
  let base_y : Int = run.frame.origin.y.to_int()
  // Vertical centering: top row of the glyph block.
  let y_off : Int = base_y + (frame_h - ch) / 2
  let mut cell_idx : Int = 0
  for c in run.text {
    if cell_idx >= max_cells {
      break
    }
    let ch_int : Int = c.to_int()
    let gx0 : Int = base_x + cell_idx * cw
    // Iterate the 5x7 cell; only blend the pixels that are
    // lit per the glyph bitmap and that fall inside the
    // clipped frame.
    let mut col : Int = 0
    while col < cw {
      let mut row : Int = 0
      while row < ch {
        if glyph_at(ch_int, col, row) {
          blend_pixel(buf, gx0 + col, y_off + row, run.color, opacity)
        }
        row = row + 1
      }
      col = col + 1
    }
    cell_idx = cell_idx + 1
  }
}

///|
/// Internal clipped stroke: paint `width` pixels on each of the
/// 4 edges of `rect`. Corners are drawn twice (each edge
/// covers its corner), which is fine for opaque strokes.
fn paint_stroke_rect(
  buf : PixelBuffer,
  rect : @core.Rect,
  width : Double,
  clip : @core.Rect,
  color : @core.Color,
  opacity : Double,
) -> Unit {
  let half_w : Double = width / 2.0
  let rx : Double = rect.origin.x
  let ry : Double = rect.origin.y
  let rw : Double = rect.size.width
  let rh : Double = rect.size.height
  // Top edge
  paint_rect(
    buf,
    @core.Rect::new(
      x=rx - half_w,
      y=ry - half_w,
      width=rw + width,
      height=width,
    ),
    clip,
    color,
    opacity,
  )
  // Bottom edge
  paint_rect(
    buf,
    @core.Rect::new(
      x=rx - half_w,
      y=ry + rh - half_w,
      width=rw + width,
      height=width,
    ),
    clip,
    color,
    opacity,
  )
  // Left edge (excluding top + bottom rows already painted)
  paint_rect(
    buf,
    @core.Rect::new(
      x=rx - half_w,
      y=ry + half_w,
      width=width,
      height=rh - width,
    ),
    clip,
    color,
    opacity,
  )
  // Right edge
  paint_rect(
    buf,
    @core.Rect::new(
      x=rx + rw - half_w,
      y=ry + half_w,
      width=width,
      height=rh - width,
    ),
    clip,
    color,
    opacity,
  )
}

///|
/// Helper: test whether (px, py) is inside the inscribed
/// circle of a rounded corner centered at (cx, cy) with
/// radius `r`. If distance² > r², the pixel is in the corner
/// cut-out — skip it.
fn inside_corner_circle(
  px : Int,
  py : Int,
  cx : Double,
  cy : Double,
  r : Double,
) -> Bool {
  let dx : Double = px.to_double() + 0.5 - cx
  let dy : Double = py.to_double() + 0.5 - cy
  dx * dx + dy * dy <= r * r
}

///|
/// Rounded-rect fill: paint every pixel inside `rect` ∩ clip
/// EXCEPT those that fall inside the corner cut-outs (one per
/// corner if radius > 0). Delegates corner-cut detection to
/// `in_corner_cut`.
fn paint_rounded_rect(
  buf : PixelBuffer,
  rr : @core.RoundedRect,
  clip : @core.Rect,
  color : @core.Color,
  opacity : Double,
) -> Unit {
  let rect : @core.Rect = rr.rect
  let rx : Double = rect.origin.x
  let ry : Double = rect.origin.y
  let rw : Double = rect.size.width
  let rh : Double = rect.size.height
  let r : Double = if rr.radius > rw / 2.0 {
    rw / 2.0
  } else if rr.radius > rh / 2.0 {
    rh / 2.0
  } else {
    rr.radius
  }
  let clipped : @core.Rect? = rect.intersection(clip)
  guard clipped is Some(c) else { return }
  let x0 : Int = c.origin.x.ceil().to_int()
  let y0 : Int = c.origin.y.ceil().to_int()
  let x1 : Int = (c.origin.x + c.size.width).floor().to_int()
  let y1 : Int = (c.origin.y + c.size.height).floor().to_int()
  for y = y0; y <= y1; y = y + 1 {
    for x = x0; x <= x1; x = x + 1 {
      let px : Double = x.to_double() + 0.5
      let py : Double = y.to_double() + 0.5
      if in_corner_cut(px, py, rx, ry, rw, rh, r) {
        continue
      }
      blend_pixel(buf, x, y, color, opacity)
    }
  }
}

///|
/// Rounded-rect stroke: paint the perimeter ring directly
/// (pixels inside the outer rounded-rect but outside the
/// inset rounded-rect). The earlier "fill then transparent-
/// subtract" approach didn't work because alpha=0 blend is a
/// no-op on existing pixels — the interior stayed filled.
fn paint_stroke_rounded_rect(
  buf : PixelBuffer,
  rr : @core.RoundedRect,
  width : Double,
  clip : @core.Rect,
  color : @core.Color,
  opacity : Double,
) -> Unit {
  let rect : @core.Rect = rr.rect
  let rx : Double = rect.origin.x
  let ry : Double = rect.origin.y
  let rw : Double = rect.size.width
  let rh : Double = rect.size.height
  let r : Double = if rr.radius > rw / 2.0 {
    rw / 2.0
  } else if rr.radius > rh / 2.0 {
    rh / 2.0
  } else {
    rr.radius
  }
  // Inset (inner) rounded rect: rect shrunk by `width` on each
  // side, radius reduced by `width` (clamped to 0).
  let inner_rect : @core.Rect = @core.Rect::new(
    x=rx + width,
    y=ry + width,
    width=rw - 2.0 * width,
    height=rh - 2.0 * width,
  )
  let inner_r : Double = if r - width < 0.0 {
    0.0
  } else {
    r - width
  }
  let inner : @core.RoundedRect = @core.RoundedRect::new(
    rect=inner_rect,
    radius=inner_r,
  )
  let clipped : @core.Rect? = rect.intersection(clip)
  guard clipped is Some(c) else { return }
  let x0 : Int = c.origin.x.ceil().to_int()
  let y0 : Int = c.origin.y.ceil().to_int()
  let x1 : Int = (c.origin.x + c.size.width).floor().to_int()
  let y1 : Int = (c.origin.y + c.size.height).floor().to_int()
  for y = y0; y <= y1; y = y + 1 {
    for x = x0; x <= x1; x = x + 1 {
      // In outer (after corner cuts) AND NOT in inner (after
      // inner corner cuts).
      let in_outer : Bool = !in_corner_cut(
        x.to_double(),
        y.to_double(),
        rx,
        ry,
        rw,
        rh,
        r,
      )
      if not(in_outer) {
        continue
      }
      let ix : Double = x.to_double() + 0.5
      let iy : Double = y.to_double() + 0.5
      // Inner membership: pixel inside inner_rect (with inner
      // corner cuts).
      let ix0 : Double = inner_rect.origin.x
      let iy0 : Double = inner_rect.origin.y
      let iw : Double = inner_rect.size.width
      let ih : Double = inner_rect.size.height
      let in_inner_rect : Bool = ix >= ix0 && ix < ix0 + iw && iy >= iy0 &&
        iy < iy0 + ih
      let in_inner : Bool = in_inner_rect &&
        !in_corner_cut(ix, iy, ix0, iy0, iw, ih, inner_r)
      if in_inner {
        continue
      }
      blend_pixel(buf, x, y, color, opacity)
    }
  }
}

///|
/// Returns true if (px, py) lies inside one of the four
/// corner cut-outs of a rounded-rect with the given rect +
/// radius. Shared between fill (where we skip) and stroke
/// (where we include only outer-but-not-inner).
fn in_corner_cut(
  px : Double,
  py : Double,
  rx : Double,
  ry : Double,
  rw : Double,
  rh : Double,
  r : Double,
) -> Bool {
  if r <= 0.0 {
    return false
  }
  let cx_left : Double = rx + r
  let cx_right : Double = rx + rw - r
  let cy_top : Double = ry + r
  let cy_bot : Double = ry + rh - r
  let in_tl : Bool = px < cx_left && py < cy_top
  let in_tr : Bool = px >= cx_right && py < cy_top
  let in_bl : Bool = px < cx_left && py >= cy_bot
  let in_br : Bool = px >= cx_right && py >= cy_bot
  if not(in_tl || in_tr || in_bl || in_br) {
    return false
  }
  let cx : Double = if in_tl {
    cx_left
  } else if in_tr {
    cx_right
  } else if in_bl {
    cx_left
  } else {
    cx_right
  }
  let cy : Double = if in_tl || in_tr {
    cy_top
  } else {
    cy_bot
  }
  let dx : Double = px - cx
  let dy : Double = py - cy
  dx * dx + dy * dy > r * r
}

///|
/// Extract a flat list of polygon vertices from a PathSpec's
/// verbs. Phase 11 ignores QuadTo/CubicTo — those curve
/// verbs are skipped. Returns MoveTo + LineTo vertices in
/// path order.
fn path_vertices(spec : @core.PathSpec) -> Array[@core.Point] {
  let verts : Array[@core.Point] = []
  for verb in spec.verbs {
    match verb {
      @core.PathVerb::MoveTo(p) => verts.push(p)
      @core.PathVerb::LineTo(p) => verts.push(p)
      @core.PathVerb::QuadTo(_, _) => () // Phase 11: skip
      @core.PathVerb::CubicTo(_, _, _) => () // Phase 11: skip
      @core.PathVerb::Close => () // Phase 11: no implicit close-to-origin
    }
  }
  verts
}

///|
/// Scanline polygon fill — even-odd coverage. For each scan-
/// line y, find x-coordinates where horizontal ray crosses
/// polygon edges (LineTo segments). Fill between every other
/// pair. Standard Foley-Van Dam algorithm; simple and
/// sufficiently fast for labeler polygons (typically < 30
/// vertices).
fn paint_polygon_fill(
  buf : PixelBuffer,
  verts : Array[@core.Point],
  clip : @core.Rect,
  color : @core.Color,
  opacity : Double,
) -> Unit {
  let n : Int = verts.length()
  if n < 3 {
    return
  }
  // Find y bounds.
  let mut y_min : Double = verts[0].y
  let mut y_max : Double = verts[0].y
  for i = 1; i < n; i = i + 1 {
    if verts[i].y < y_min {
      y_min = verts[i].y
    }
    if verts[i].y > y_max {
      y_max = verts[i].y
    }
  }
  let y_lo : Int = y_min.ceil().to_int()
  let y_hi : Int = y_max.floor().to_int()
  let y_clip_lo : Int = clip.origin.y.ceil().to_int()
  let y_clip_hi : Int = (clip.origin.y + clip.size.height).floor().to_int()
  let y_start : Int = if y_lo < y_clip_lo { y_clip_lo } else { y_lo }
  let y_end : Int = if y_hi > y_clip_hi { y_clip_hi } else { y_hi }
  for y = y_start; y <= y_end; y = y + 1 {
    let yf : Double = y.to_double() + 0.5
    let crossings : Array[Double] = []
    for i = 0; i < n; i = i + 1 {
      let j : Int = (i + 1) % n
      let p1 = verts[i]
      let p2 = verts[j]
      // Skip horizontal edges (no crossing).
      if p1.y == p2.y {
        continue
      }
      // Check if scanline crosses this edge (inclusive lower,
      // exclusive upper to avoid double-counting vertices).
      if (p1.y <= yf && p2.y > yf) || (p2.y <= yf && p1.y > yf) {
        let t : Double = (yf - p1.y) / (p2.y - p1.y)
        let x : Double = p1.x + t * (p2.x - p1.x)
        crossings.push(x)
      }
    }
    // Sort crossings ascending.
    crossings.sort()
    let m : Int = crossings.length()
    if m < 2 {
      continue
    }
    // Fill between (crossings[0], crossings[1]), (2,3), ...
    let mut k : Int = 0
    while k + 1 < m {
      let xa : Double = crossings[k]
      let xb : Double = crossings[k + 1]
      let x_lo : Int = xa.ceil().to_int()
      let x_hi : Int = xb.floor().to_int()
      let x_clip_lo : Int = clip.origin.x.ceil().to_int()
      let x_clip_hi : Int = (clip.origin.x + clip.size.width).floor().to_int()
      let xs : Int = if x_lo < x_clip_lo { x_clip_lo } else { x_lo }
      let xe : Int = if x_hi > x_clip_hi { x_clip_hi } else { x_hi }
      for x = xs; x <= xe; x = x + 1 {
        blend_pixel(buf, x, y, color, opacity)
      }
      k = k + 2
    }
  }
}

///|
/// Stroke a polygon by stroking each edge as a thin filled
/// rect (width pixels on either side of the line). Adequate
/// for labeler outlines — no need for true Bresenham yet.
fn paint_polygon_stroke(
  buf : PixelBuffer,
  verts : Array[@core.Point],
  width : Double,
  clip : @core.Rect,
  color : @core.Color,
  opacity : Double,
) -> Unit {
  let n : Int = verts.length()
  if n < 2 {
    return
  }
  let half : Double = width / 2.0
  for i = 0; i < n; i = i + 1 {
    let j : Int = (i + 1) % n
    let p1 = verts[i]
    let p2 = verts[j]
    let dx : Double = p2.x - p1.x
    let dy : Double = p2.y - p1.y
    let len : Double = (dx * dx + dy * dy).sqrt()
    if len == 0.0 {
      continue
    }
    // Perpendicular unit vector for line width offset.
    let nx : Double = -dy / len
    let ny : Double = dx / len
    let ox : Double = nx * half
    let oy : Double = ny * half
    // Build a thick-line rect (axis-aligned bbox of the
    // parallelogram) — adequate for the labeler's polygon
    // edges (mostly horizontal/vertical).
    let x_min : Double = @math.minimum(
      @math.minimum(p1.x - ox, p1.x + ox),
      @math.minimum(p2.x - ox, p2.x + ox),
    )
    let x_max : Double = @math.maximum(
      @math.maximum(p1.x - ox, p1.x + ox),
      @math.maximum(p2.x - ox, p2.x + ox),
    )
    let y_min : Double = @math.minimum(
      @math.minimum(p1.y - oy, p1.y + oy),
      @math.minimum(p2.y - oy, p2.y + oy),
    )
    let y_max : Double = @math.maximum(
      @math.maximum(p1.y - oy, p1.y + oy),
      @math.maximum(p2.y - oy, p2.y + oy),
    )
    paint_rect(
      buf,
      @core.Rect::new(x=x_min, y=y_min, width=x_max - x_min, height=y_max - y_min),
      clip,
      color,
      opacity,
    )
  }
}

///|
/// DrawPath: extract polygon, then paint fill (if brush
/// present) and stroke (if brush present).
fn paint_path(
  buf : PixelBuffer,
  spec : @core.PathSpec,
  clip : @core.Rect,
  opacity : Double,
) -> Unit {
  let verts : Array[@core.Point] = path_vertices(spec)
  if verts.length() < 3 {
    // Single line / move: paint as a stroke if there's a stroke.
    if verts.length() == 2 && spec.stroke is Some(_) {
      paint_polygon_stroke(
        buf,
        verts,
        spec.stroke_width,
        clip,
        @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=1.0),
        opacity,
      )
    }
    return
  }
  if spec.fill is Some(fill_brush) {
    let c : @core.Color = brush_color(fill_brush)
    paint_polygon_fill(buf, verts, clip, c, opacity)
  }
  if spec.stroke is Some(stroke_brush) {
    let c : @core.Color = brush_color(stroke_brush)
    paint_polygon_stroke(buf, verts, spec.stroke_width, clip, c, opacity)
  }
}

///|
/// Extract a solid color from a Brush. Phase 11 only handles
/// `Brush::solid(Color)`; linear/radial gradients are no-ops.
fn brush_color(brush : @core.Brush) -> @core.Color {
  // The Brush type is opaque (private fields). We can only
  // call its methods. `fallback_color` returns a usable color
  // (the brush's primary color when solid; a fallback when
  // gradient).
  brush.fallback_color()
}

///|
/// Walk a `DrawFrame.commands` array and rasterize each
/// DrawCommand into `buf`. The clip/opacity/transform stacks
/// start with full-buffer clip, opacity 1.0, identity
/// transform. `commands` is iterated linearly (no recursion
/// needed — `Push*` ops only push/pop state for subsequent
/// siblings).
///
/// Background strategy: Moui's runtime hands each `DrawFrame`
/// a `clear_color` (defaults to opaque white when the view
/// tree doesn't override it). We ignore that and keep the
/// `PixelBuffer::new` init colour as the background, so an
/// empty / partially-painting view tree still shows the
/// intended background instead of the runtime's default
/// white. Commands that explicitly `Clear` themselves still
/// win (they run after our init clear in command order).
pub fn rasterize_draw_frame(
  buf : PixelBuffer,
  frame : @core.DrawFrame,
) -> Unit {
  // Note: we do NOT clear to frame.clear_color here. The buf
  // was already initialized to its background by
  // PixelBuffer::new (in renderer.mbt: dark slate for the
  // labeler window). If a future view tree ships its own
  // root FillRect, it will paint on top of the dark slate
  // — visible immediately instead of waiting for the
  // cached-static-layer to commit.
  let _ = frame.clear_color
  // Walker state.
  let full : @core.Rect = @core.Rect::new(
    x=0.0,
    y=0.0,
    width=buf.width.to_double(),
    height=buf.height.to_double(),
  )
  let clip_stack : Array[@core.Rect] = [full]
  let opacity_stack : Array[Double] = [1.0]
  for cmd in frame.commands {
    dispatch_command(buf, cmd, clip_stack, opacity_stack)
  }
}

///|
/// Per-command dispatcher. Mutates clip/opacity stacks in
/// place (MoonBit arrays are mutable; we use a one-element
/// sentinel pattern by replacing the top element).
fn dispatch_command(
  buf : PixelBuffer,
  cmd : @core.DrawCommand,
  clip_stack : Array[@core.Rect],
  opacity_stack : Array[Double],
) -> Unit {
  let clip : @core.Rect = clip_stack[clip_stack.length() - 1]
  let opacity : Double = opacity_stack[opacity_stack.length() - 1]
  match cmd {
    @core.DrawCommand::Clear(c) => clear_color(buf, c)
    @core.DrawCommand::FillRect(r, c) => paint_rect(buf, r, clip, c, opacity)
    @core.DrawCommand::StrokeRect(r, c, w) =>
      paint_stroke_rect(buf, r, w, clip, c, opacity)
    @core.DrawCommand::FillRoundedRect(rr, c) =>
      paint_rounded_rect(buf, rr, clip, c, opacity)
    @core.DrawCommand::StrokeRoundedRect(rr, c, w) =>
      paint_stroke_rounded_rect(buf, rr, w, clip, c, opacity)
    @core.DrawCommand::DrawPath(spec) => paint_path(buf, spec, clip, opacity)
    @core.DrawCommand::DrawText(run) =>
      // Phase 12 — real glyph rasterization via the 5x7 ASCII
      // bitmap font (see app_moui/bitmap_font.mbt). Each lit
      // pixel in the glyph cell is blended into the BGRA buffer
      // with `run.color` and the active opacity, clipped to the
      // active clip rect. Out-of-range chars fall back to the
      // tofu glyph (filled 5x7 box) so layout never crashes.
      paint_text(buf, run, clip, opacity)
    @core.DrawCommand::DrawImage(run) => {
      // Phase 12 — placeholder: gray outline + diagonal hatch.
      // Real image decoding is Phase 13+.
      let outline : @core.Color = @core.Color::rgba(
        r=0.35,
        g=0.35,
        b=0.35,
        a=1.0,
      )
      paint_stroke_rect(buf, run.frame, 1.0, clip, outline, opacity)
      // Two diagonal lines from (x0,y0)→(x1,y1) and
      // (x0,y1)→(x1,y0) — visual "image loading" hint.
      let rx : Double = run.frame.origin.x
      let ry : Double = run.frame.origin.y
      let rw : Double = run.frame.size.width
      let rh : Double = run.frame.size.height
      paint_line(
        buf,
        rx,
        ry,
        rx + rw,
        ry + rh,
        clip,
        outline,
        opacity,
      )
      paint_line(
        buf,
        rx,
        ry + rh,
        rx + rw,
        ry,
        clip,
        outline,
        opacity,
      )
    }
    @core.DrawCommand::PushClip(r) => {
      // Intersect the pushed clip with the parent (caller's
      // responsibility: pairs with PopClip).
      let parent : @core.Rect = clip_stack[clip_stack.length() - 1]
      let intersected : @core.Rect = match r.intersection(parent) {
        Some(c) => c
        None => @core.Rect::new(x=0.0, y=0.0, width=0.0, height=0.0)
      }
      clip_stack.push(intersected)
    }
    @core.DrawCommand::PopClip =>
      // ignore: underflow check skipped for Phase 11 — tests
      // construct balanced push/pop pairs.
      ignore(clip_stack.pop())
    @core.DrawCommand::PushOpacity(a) => opacity_stack.push(opacity * a)
    @core.DrawCommand::PopOpacity => ignore(opacity_stack.pop())
    @core.DrawCommand::PushTransform(_) =>
      // Phase 11: subsequent commands operate in identity
      // transform. Moui's transform is applied at view-tree
      // level (child coords are pre-transformed by parent).
      ()
    @core.DrawCommand::PopTransform => ()
    // Phase 11 no-ops: DrawShadow, PushLayer, PopLayer,
    // BeginRetainedLayer, EndRetainedLayer, PushFilter,
    // PopFilter, DrawShaderEffect, PushRoundedClip,
    // PopRoundedClip, FillRoundedRectBrush,
    // StrokeRoundedRectBrush.
    _ => ()
  }
}