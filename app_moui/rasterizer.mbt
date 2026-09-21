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
/// Internal clipped-fill rectangle (no AA, integer snap):
/// paints every pixel inside `rect` ∩ clip with `color`
/// blended at `opacity`. Each pixel is fully painted or fully
/// skipped — sub-pixel coverage is ignored. Used by
/// `paint_stroke_rect` whose outer-half pixel boundary is
/// itself an integer-aligned edge under the stroke=1.0
/// convention; switching to AA here would change the stroke's
/// outer-edge appearance from solid to partial-coverage.
fn paint_rect_snap(
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
/// Internal clipped-fill rectangle: paints every pixel inside
/// `rect` ∩ clip with `color` blended at `opacity`. The
/// per-pixel coverage is computed analytically from the
/// intersection of the destination pixel (x..x+1, y..y+1)
/// with the clipped rect, so edges that fall on a half-pixel
/// boundary get partial coverage (Phase 15 — supersampling-
/// free fractional coverage AA; no extra read or write
/// bandwidth beyond the integer-pixel algorithm).
///
/// Coverage formula:
///
///   pixel_x_lo = max(rect.x, x)
///   pixel_x_hi = min(rect.x + rect.w, x + 1)
///   x_cover = max(0.0, pixel_x_hi - pixel_x_lo)
///
/// and likewise for y. Final coverage = x_cover * y_cover. The
/// opacity passed to `blend_pixel` becomes
/// `opacity * coverage` so that a 50% covered edge pixel
/// contributes half the source color.
fn paint_rect(
  buf : PixelBuffer,
  rect : @core.Rect,
  clip : @core.Rect,
  color : @core.Color,
  opacity : Double,
) -> Unit {
  let clipped : @core.Rect? = rect.intersection(clip)
  guard clipped is Some(c) else { return }
  let x_lo : Double = c.origin.x
  let y_lo : Double = c.origin.y
  let x_hi : Double = c.origin.x + c.size.width
  let y_hi : Double = c.origin.y + c.size.height
  let x0 : Int = x_lo.floor().to_int()
  let y0 : Int = y_lo.floor().to_int()
  let x1 : Int = x_hi.floor().to_int()
  let y1 : Int = y_hi.floor().to_int()
  for y = y0; y <= y1; y = y + 1 {
    let py_lo : Double = y.to_double()
    let py_hi : Double = py_lo + 1.0
    let y_cover : Double = {
      let lo : Double = if py_lo > y_lo { py_lo } else { y_lo }
      let hi : Double = if py_hi < y_hi { py_hi } else { y_hi }
      if hi > lo { hi - lo } else { 0.0 }
    }
    if y_cover <= 0.0 {
      continue
    }
    for x = x0; x <= x1; x = x + 1 {
      let px_lo : Double = x.to_double()
      let px_hi : Double = px_lo + 1.0
      let x_cover : Double = {
        let lo : Double = if px_lo > x_lo { px_lo } else { x_lo }
        let hi : Double = if px_hi < x_hi { px_hi } else { x_hi }
        if hi > lo { hi - lo } else { 0.0 }
      }
      if x_cover <= 0.0 {
        continue
      }
      let coverage : Double = x_cover * y_cover
      let cov_clamped : Double = if coverage > 1.0 { 1.0 } else { coverage }
      let eff_opacity : Double = opacity * cov_clamped
      blend_pixel(buf, x, y, color, eff_opacity)
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
/// Phase 13 — paint a decoded RGBA image into the BGRA buffer.
///
/// Behavior:
///   - Cache hit: nearest-neighbor sample from `image.data`
///     (row-major RGBA8) into `buf` over `run.frame`, alpha-
///     blending with the destination. Out-of-frame pixels are
///     skipped.
///   - Cache miss: render the legacy gray-outline + diagonal
///     hatch placeholder so the UI still shows something for
///     every `DrawImage` slot.
///
/// Why nearest-neighbor (not bilinear) for Phase 13:
///   - Zero per-pixel arithmetic beyond the byte reads.
///   - The labeler's display images are screenshots of X-ray
///     scans at native resolution; bilinear smoothing would
///     blur security-relevant edges. Phase 14 may add an
///     opt-in `ImageFit` -> bilinear path if a use case
///     appears.
fn paint_image(
  buf : PixelBuffer,
  run : @core.ImageRun,
  clip : @core.Rect,
  opacity : Double,
  cache : ImageCache,
) -> Unit {
  let clipped : @core.Rect? = run.frame.intersection(clip)
  guard clipped is Some(c) else { return }
  let x0 : Int = c.origin.x.ceil().to_int()
  let y0 : Int = c.origin.y.ceil().to_int()
  let x1 : Int = (c.origin.x + c.size.width).floor().to_int()
  let y1 : Int = (c.origin.y + c.size.height).floor().to_int()
  let dst_w : Int = x1 - x0 + 1
  let dst_h : Int = y1 - y0 + 1
  if dst_w <= 0 || dst_h <= 0 {
    return
  }
  match cache.get(run.source) {
    Some(img) => {
      // Map each destination pixel to a source pixel via
      // nearest-neighbor. (src_x, src_y) live in image
      // coordinates; the destination covers [x0..x1] x [y0..y1]
      // which is dst_w x dst_h pixels.
      let src_w : Int = img.width
      let src_h : Int = img.height
      if src_w <= 0 || src_h <= 0 {
        // Defensive: zero-size image, render the placeholder.
        paint_image_placeholder(buf, run, clip, opacity)
        return
      }
      let src_stride : Int = src_w * 4
      for dy = 0; dy < dst_h; dy = dy + 1 {
        let dst_y : Int = y0 + dy
        // Map dst_y ∈ [y0..y0+dst_h-1] to src_y ∈ [0..src_h-1].
        let src_y : Int = dy * src_h / dst_h
        let src_row_off : Int = src_y * src_stride
        let dst_row_off : Int = dst_y * buf.width * 4
        for dx = 0; dx < dst_w; dx = dx + 1 {
          let dst_x : Int = x0 + dx
          let src_x : Int = dx * src_w / dst_w
          let s_off : Int = src_row_off + src_x * 4
          let d_off : Int = dst_row_off + dst_x * 4
          // Read source RGBA (premultiplied? no — to_rgba8 gives
          // straight alpha).
          let r : Int = img.data[s_off].to_int()
          let g : Int = img.data[s_off + 1].to_int()
          let b : Int = img.data[s_off + 2].to_int()
          let a : Int = img.data[s_off + 3].to_int()
          // Composite: out = src.rgb * src.a + dst.rgb * (1 - src.a),
          // then multiply by the run's opacity. We approximate
          // the blend in-place with `blend_pixel` for
          // consistency with the rest of the rasterizer:
          // `blend_pixel` takes a `Color` (0..1 floats), so
          // build one from the source RGBA + run opacity * a/255.
          if a > 0 {
            let sa : Double = a.to_double() / 255.0 * opacity
            let color : @core.Color = @core.Color::rgba(
              r=r.to_double() / 255.0,
              g=g.to_double() / 255.0,
              b=b.to_double() / 255.0,
              a=sa,
            )
            blend_pixel(buf, dst_x, dst_y, color, 1.0)
          }
        }
      }
    }
    None =>
      // Cache miss — render the placeholder so the UI shows
      // a visual cue for the missing image. (Phase 14 will
      // replace this with a synchronous disk load.)
      paint_image_placeholder(buf, run, clip, opacity)
  }
}

///|
/// Phase 12 — fallback placeholder for an unresolved DrawImage.
/// Gray outline + diagonal X across the image frame. Used when
/// the cache has no entry for `run.source`. Kept as a separate
/// helper so `paint_image` (Phase 13) can fall back to it on
/// cache miss.
fn paint_image_placeholder(
  buf : PixelBuffer,
  run : @core.ImageRun,
  clip : @core.Rect,
  opacity : Double,
) -> Unit {
  let outline : @core.Color = @core.Color::rgba(
    r=0.35,
    g=0.35,
    b=0.35,
    a=1.0,
  )
  paint_stroke_rect(buf, run.frame, 1.0, clip, outline, opacity)
  let rx : Double = run.frame.origin.x
  let ry : Double = run.frame.origin.y
  let rw : Double = run.frame.size.width
  let rh : Double = run.frame.size.height
  paint_line(buf, rx, ry, rx + rw, ry + rh, clip, outline, opacity)
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
  paint_rect_snap(
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
  paint_rect_snap(
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
  paint_rect_snap(
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
  paint_rect_snap(
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
/// Magic constant for the cubic-Bezier approximation of a
/// quarter circle: c = 4*(sqrt(2)-1)/3 ≈ 0.5522847498. Each
/// corner of the rounded-rect is approximated by a cubic
/// Bezier with control points at distance c*r from the arc
/// endpoints along the tangent. The cubic lies within
/// 0.00027*r of the true circle (well below 1/256 sub-pixel
/// resolution), so the AA coverage at any pixel cell is
/// accurate to within ~1 ULP at 8-bit output.
///
/// Phase 16.E replaces the Phase 15 inscribed-circle AA math
/// with this bezier-corner construction so the same rasterizer
/// path can also handle arbitrary `PathSpec` shapes — the
/// rounded-rect is just one specific PathSpec now, built from
/// MoveTo + 3 LineTo + 4 CubicTo + Close.
pub fn bezier_circle_constant() -> Double {
  0.5522847498307933
}

///|
/// Pixel-cell coverage of the inside of a rounded rect with
/// the given bounding rect + corner radius. Phase 16.E: 16x16
/// sub-sample against the **bezier-corner** shape (the cubic
/// Bezier arc that the polygon-fill pipeline will rasterize),
/// not against the inscribed-circle approximation the older
/// code used. Same short-circuits (outside-bbox → 0; full
/// interior-box → 1), so the cost budget is identical for
/// pixels in the middle band.
///
/// The sub-sampler uses **point-in-corner-circle** as a
/// stand-in for point-inside-bezier — the bezier arc is within
/// 0.00027*r of the true circle (max divergence at t=0.21 and
/// t=0.79), so the sub-sample count is accurate to within
/// 1/256 per cell. For 8-bit AA output, this is indistinguishable
/// from a true bezier implicit-form test.
pub fn bezier_round_rect_pixel_coverage(
  px : Double,
  py : Double,
  rx : Double,
  ry : Double,
  rw : Double,
  rh : Double,
  r : Double,
) -> Double {
  let rx_hi : Double = rx + rw
  let ry_hi : Double = ry + rh
  if px + 1.0 <= rx || py + 1.0 <= ry || px >= rx_hi || py >= ry_hi {
    return 0.0
  }
  if r <= 0.0 {
    return 1.0
  }
  let cx_left : Double = rx + r
  let cx_right : Double = rx_hi - r
  let cy_top : Double = ry + r
  let cy_bot : Double = ry_hi - r
  if px >= cx_left && px + 1.0 <= cx_right &&
    py >= cy_top && py + 1.0 <= cy_bot {
    return 1.0
  }
  // 16x16 sub-sample. Each sub-pixel center at
  //   (px + (i + 0.5) / 16, py + (j + 0.5) / 16)
  // counts as inside if it lies in the rounded-rect interior
  // (inside bounding box + outside corner-cut). Total / 256
  // gives the cell coverage.
  let n : Int = 16
  let mut count : Int = 0
  let mut j : Int = 0
  while j < n {
    let sy : Double = py + (j.to_double() + 0.5) / n.to_double()
    let mut i : Int = 0
    while i < n {
      let sx : Double = px + (i.to_double() + 0.5) / n.to_double()
      // Sub-sample outside the bounding rect → not inside.
      if sx < rx || sx > rx_hi || sy < ry || sy > ry_hi {
        i = i + 1
        continue
      }
      // Determine which corner-quadrant (if any) the sample
      // falls into.
      let in_tl : Bool = sx < cx_left && sy < cy_top
      let in_tr : Bool = sx >= cx_right && sy < cy_top
      let in_bl : Bool = sx < cx_left && sy >= cy_bot
      let in_br : Bool = sx >= cx_right && sy >= cy_bot
      if !(in_tl || in_tr || in_bl || in_br) {
        // Middle band — always inside.
        count = count + 1
      } else {
        // Inside a corner quadrant — check the bezier arc.
        // The bezier lies within 0.00027*r of the inscribed
        // circle, so we use the circle test (d^2 <= r^2) as
        // the implicit-form stand-in.
        let ccx : Double = if in_tl || in_bl {
          cx_left
        } else {
          cx_right
        }
        let ccy : Double = if in_tl || in_tr {
          cy_top
        } else {
          cy_bot
        }
        let dx : Double = sx - ccx
        let dy : Double = sy - ccy
        if dx * dx + dy * dy <= r * r {
          count = count + 1
        }
      }
      i = i + 1
    }
    j = j + 1
  }
  count.to_double() / (n * n).to_double()
}

///|
/// Build a PathSpec for the outline of a rounded rect. The
/// path is built so that `path_vertices` + `paint_polygon_fill`
/// rasterizes the same shape as the older inscribed-circle AA
/// would — same corner cut, same straight edges. The bezier
/// arc lies within 0.00027*r of the true circle.
///
/// The verbs emitted:
///   MoveTo(left + r, top)
///   LineTo(right - r, top)
///   CubicTo(right - r, top - c*r, right, top - c*r, right, top + r)
///   LineTo(right, bottom - r)
///   CubicTo(right, bottom - c*r, right - c*r, bottom, right - r, bottom)
///   LineTo(left + r, bottom)
///   CubicTo(left + c*r, bottom, left, bottom - c*r, left, bottom - r)
///   LineTo(left, top + r)
///   CubicTo(left, top + c*r, left + c*r, top, left + r, top)
///   Close
///
/// `inset` (Phase 16.E stroke support) shrinks the bounding
/// rect by `inset` on each side and reduces the radius by
/// `inset` (clamped to 0). Used to build the inner outline of
/// a stroke ring.
pub fn rounded_rect_path_spec(rr : @core.RoundedRect, inset~ : Double = 0.0) -> @core.PathSpec {
  let rect : @core.Rect = rr.rect
  let rx : Double = rect.origin.x + inset
  let ry : Double = rect.origin.y + inset
  let rw : Double = rect.size.width - 2.0 * inset
  let rh : Double = rect.size.height - 2.0 * inset
  let r_raw : Double = rr.radius - inset
  let r : Double = if r_raw < 0.0 { 0.0 } else { r_raw }
  // Same radius clamp as the older paint fn: don't let the
  // corner radius exceed half the smaller side.
  let max_r : Double = if rw / 2.0 < rh / 2.0 { rw / 2.0 } else { rh / 2.0 }
  let rc : Double = if r > max_r { max_r } else { r }
  let c : Double = bezier_circle_constant()
  let k : Double = rc * c
  let right : Double = rx + rw
  let bottom : Double = ry + rh
  let verbs : Array[@core.PathVerb] = [
    // Top edge: from (left+r, top) to (right-r, top).
    @core.PathVerb::MoveTo(
      @core.Point::new(x=rx + rc, y=ry),
    ),
    @core.PathVerb::LineTo(
      @core.Point::new(x=right - rc, y=ry),
    ),
    // Top-right corner: cubic from (right-r, top) to (right, top+r).
    @core.PathVerb::CubicTo(
      @core.Point::new(x=right - rc + k, y=ry),       // tangent extension
      @core.Point::new(x=right, y=ry + rc - k),       // tangent extension
      @core.Point::new(x=right, y=ry + rc),
    ),
    // Right edge: (right, top+r) to (right, bottom-r).
    @core.PathVerb::LineTo(
      @core.Point::new(x=right, y=bottom - rc),
    ),
    // Bottom-right corner: (right, bottom-r) to (right-r, bottom).
    @core.PathVerb::CubicTo(
      @core.Point::new(x=right, y=bottom - rc + k),
      @core.Point::new(x=right - rc + k, y=bottom),
      @core.Point::new(x=right - rc, y=bottom),
    ),
    // Bottom edge: (right-r, bottom) to (left+r, bottom).
    @core.PathVerb::LineTo(
      @core.Point::new(x=rx + rc, y=bottom),
    ),
    // Bottom-left corner: (left+r, bottom) to (left, bottom-r).
    @core.PathVerb::CubicTo(
      @core.Point::new(x=rx + rc - k, y=bottom),
      @core.Point::new(x=rx, y=bottom - rc + k),
      @core.Point::new(x=rx, y=bottom - rc),
    ),
    // Left edge: (left, bottom-r) to (left, top+r).
    @core.PathVerb::LineTo(
      @core.Point::new(x=rx, y=ry + rc),
    ),
    // Top-left corner: (left, top+r) to (left+r, top).
    @core.PathVerb::CubicTo(
      @core.Point::new(x=rx, y=ry + rc - k),
      @core.Point::new(x=rx + rc - k, y=ry),
      @core.Point::new(x=rx + rc, y=ry),
    ),
    @core.PathVerb::Close,
  ]
  @core.PathSpec::new(
    verbs~,
    fill=Some(@core.Brush::solid(@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0))),
    stroke=None,
    stroke_width=0.0,
  )
}

///|
/// Rounded-rect fill (Phase 16.E): cell-level AA against the
/// bezier-corner geometry. The 16x16 sub-sampler
/// (`bezier_round_rect_pixel_coverage`) integrates over the
/// pixel cell, so a corner cell like (1,1) with rect
/// (1,1,4,4) r=1 gets the correct ~78% coverage (true-circle
/// value 0.785 rounded to 8-bit), not the "75% from
/// 4-corner supersample" the older inscribed-circle AA
/// returned. The straight edges fall in the interior-box
/// short-circuit and get full coverage; pixels outside the
/// bounding rect get 0.
///
/// `paint_polygon_fill` is the wrong tool here: it's a
/// scanline-based convex-polygon fitter that fills between
/// crossing pairs, and a rounded-rect's corner scanline has
/// only ONE crossing (the bezier curve), so it gets no fill
/// at all. The cell-level approach integrates over both axes
/// and handles the concave corner geometry correctly.
///
/// The PathSpec helper `rounded_rect_path_spec` is kept for
/// future use: it builds the same bezier outline as a `PathSpec`
/// so callers that want polygon-stroke rendering (e.g., for a
/// labeler annotation outline) can reuse the geometry without
/// duplicating the magic-constant cubic math.
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
  let x0 : Int = c.origin.x.floor().to_int()
  let y0 : Int = c.origin.y.floor().to_int()
  let x1 : Int = (c.origin.x + c.size.width).ceil().to_int() - 1
  let y1 : Int = (c.origin.y + c.size.height).ceil().to_int() - 1
  for y = y0; y <= y1; y = y + 1 {
    for x = x0; x <= x1; x = x + 1 {
      let px : Double = x.to_double()
      let py : Double = y.to_double()
      let coverage : Double = bezier_round_rect_pixel_coverage(
        px, py, rx, ry, rw, rh, r,
      )
      if coverage <= 0.0 {
        continue
      }
      let eff_opacity : Double = opacity * coverage
      blend_pixel(buf, x, y, color, eff_opacity)
    }
  }
}

///|
/// Rounded-rect stroke (Phase 16.E): cell-level outer-minus-
/// inner AA. Pixels in the middle band get outer-minus-inner
/// rectangle coverage (1 - inner coverage); corner cells get
/// the bezier-corner sub-sampled coverage. Uses the same
/// `bezier_round_rect_pixel_coverage` helper as the fill
/// path's expected AA, so a fractional stroke width gets the
/// same soft edges along both the outer and inner boundary.
///
/// Outer-minus-inner is computed per cell — two polygon fills
/// (outer + inner-rect-cover) would double-rasterize the
/// middle band; the cell-level approach reuses the outer
/// coverage for the middle band and only computes inner
/// coverage where it matters (i.e., everywhere outside the
/// inner-rect's interior-box).
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
  let inner_rx : Double = rx + width
  let inner_ry : Double = ry + width
  let inner_rw : Double = rw - 2.0 * width
  let inner_rh : Double = rh - 2.0 * width
  let inner_r : Double = if r - width < 0.0 {
    0.0
  } else {
    r - width
  }
  let clipped : @core.Rect? = rect.intersection(clip)
  guard clipped is Some(c) else { return }
  let x0 : Int = c.origin.x.floor().to_int()
  let y0 : Int = c.origin.y.floor().to_int()
  let x1 : Int = (c.origin.x + c.size.width).ceil().to_int() - 1
  let y1 : Int = (c.origin.y + c.size.height).ceil().to_int() - 1
  for y = y0; y <= y1; y = y + 1 {
    for x = x0; x <= x1; x = x + 1 {
      let px : Double = x.to_double()
      let py : Double = y.to_double()
      let outer_cov : Double = bezier_round_rect_pixel_coverage(
        px, py, rx, ry, rw, rh, r,
      )
      let inner_cov : Double = bezier_round_rect_pixel_coverage(
        px, py, inner_rx, inner_ry, inner_rw, inner_rh, inner_r,
      )
      let raw : Double = outer_cov - inner_cov
      let stroke_cov : Double = if raw < 0.0 {
        0.0
      } else if raw > 1.0 {
        1.0
      } else {
        raw
      }
      if stroke_cov <= 0.0 {
        continue
      }
      let eff_opacity : Double = opacity * stroke_cov
      blend_pixel(buf, x, y, color, eff_opacity)
    }
  }
}

///|
/// De Casteljau subdivision for a quadratic Bezier
/// P(t) = (1-t)^2*P0 + 2*(1-t)*t*P1 + t^2*P2. Recursively
/// halves the curve until the perpendicular distance from the
/// control point P1 to the chord P0-P2 is below the flatness
/// tolerance (sub-pixel: 0.25 pixels), then emits P2 as a
/// polygon vertex. Depth-limited to 16 to defend against
/// pathological inputs (degenerate midpoints, NaN, etc.).
///
/// Flatness test:
///   chord = P2 - P0
///   cross = (P1 - P0) x chord   (perpendicular distance)
///   if cross^2 / |chord|^2 <= tol^2  → flat
fn flatten_quadratic(
  p0 : @core.Point,
  p1 : @core.Point,
  p2 : @core.Point,
  out : Array[@core.Point],
  tol_sq : Double,
  depth : Int,
) -> Unit {
  if depth > 16 {
    out.push(p2)
    return
  }
  let dx : Double = p2.x - p0.x
  let dy : Double = p2.y - p0.y
  let len_sq : Double = dx * dx + dy * dy
  if len_sq < 1.0e-12 {
    // p0 ≈ p2 — degenerate chord; treat as flat.
    out.push(p2)
    return
  }
  let cross : Double = (p1.x - p0.x) * dy - (p1.y - p0.y) * dx
  let dist_sq : Double = cross * cross / len_sq
  if dist_sq <= tol_sq {
    out.push(p2)
    return
  }
  // Subdivide at t=0.5: q0=P0, q1=mid(P0,P1), m=mid(P1,P2),
  // q2=mid(q1,m), q3=P2. Left half: (q0, q1, q2); right:
  // (q2, m, q3).
  let q1 : @core.Point = @core.Point::new(
    x=(p0.x + p1.x) * 0.5,
    y=(p0.y + p1.y) * 0.5,
  )
  let m : @core.Point = @core.Point::new(
    x=(p1.x + p2.x) * 0.5,
    y=(p1.y + p2.y) * 0.5,
  )
  let q2 : @core.Point = @core.Point::new(
    x=(q1.x + m.x) * 0.5,
    y=(q1.y + m.y) * 0.5,
  )
  flatten_quadratic(p0, q1, q2, out, tol_sq, depth + 1)
  flatten_quadratic(q2, m, p2, out, tol_sq, depth + 1)
}

///|
/// De Casteljau subdivision for a cubic Bezier
/// P(t) = (1-t)^3*P0 + 3*(1-t)^2*t*P1 + 3*(1-t)*t^2*P2 + t^3*P3.
/// Subdivides until the max perpendicular distance from P1, P2
/// to the chord P0-P3 is below the flatness tolerance, then
/// emits P3 as a polygon vertex. Depth-limited to 16.
fn flatten_cubic(
  p0 : @core.Point,
  p1 : @core.Point,
  p2 : @core.Point,
  p3 : @core.Point,
  out : Array[@core.Point],
  tol_sq : Double,
  depth : Int,
) -> Unit {
  if depth > 16 {
    out.push(p3)
    return
  }
  let dx : Double = p3.x - p0.x
  let dy : Double = p3.y - p0.y
  let len_sq : Double = dx * dx + dy * dy
  if len_sq < 1.0e-12 {
    out.push(p3)
    return
  }
  let cross1 : Double = (p1.x - p0.x) * dy - (p1.y - p0.y) * dx
  let cross2 : Double = (p2.x - p0.x) * dy - (p2.y - p0.y) * dx
  let d1_sq : Double = cross1 * cross1 / len_sq
  let d2_sq : Double = cross2 * cross2 / len_sq
  let max_d_sq : Double = if d1_sq > d2_sq {
    d1_sq
  } else {
    d2_sq
  }
  if max_d_sq <= tol_sq {
    out.push(p3)
    return
  }
  // Subdivide at t=0.5:
  //   q1 = mid(P0,P1), q2 = mid(P1,P2), q3 = mid(P2,P3)
  //   r0 = mid(q1,q2), r1 = mid(q2,q3), r2 = mid(r0,r1)
  // Left half: (P0, q1, r0, r2); right half: (r2, r1, q3, P3).
  let q1 : @core.Point = @core.Point::new(
    x=(p0.x + p1.x) * 0.5,
    y=(p0.y + p1.y) * 0.5,
  )
  let q2 : @core.Point = @core.Point::new(
    x=(p1.x + p2.x) * 0.5,
    y=(p1.y + p2.y) * 0.5,
  )
  let q3 : @core.Point = @core.Point::new(
    x=(p2.x + p3.x) * 0.5,
    y=(p2.y + p3.y) * 0.5,
  )
  let r0 : @core.Point = @core.Point::new(
    x=(q1.x + q2.x) * 0.5,
    y=(q1.y + q2.y) * 0.5,
  )
  let r1 : @core.Point = @core.Point::new(
    x=(q2.x + q3.x) * 0.5,
    y=(q2.y + q3.y) * 0.5,
  )
  let r2 : @core.Point = @core.Point::new(
    x=(r0.x + r1.x) * 0.5,
    y=(r0.y + r1.y) * 0.5,
  )
  flatten_cubic(p0, q1, r0, r2, out, tol_sq, depth + 1)
  flatten_cubic(r2, r1, q3, p3, out, tol_sq, depth + 1)
}

///|
/// Extract a flat list of polygon vertices from a PathSpec's
/// verbs. Phase 16.A: handles QuadTo/CubicTo by recursively
/// subdividing curves via De Casteljau until each segment is
/// flat within 0.25 sub-pixels, then appending the polyline
/// vertices. `Close` emits an implicit lineTo back to the
/// subpath's MoveTo point so the polygon is properly closed.
fn path_vertices(spec : @core.PathSpec) -> Array[@core.Point] {
  let verts : Array[@core.Point] = []
  // Flatness tolerance: 0.25 px (sub-pixel). The squared
  // tolerance is what the helpers compare against.
  let tol_sq : Double = 0.0625
  let mut current : @core.Point = @core.Point::new(x=0.0, y=0.0)
  let mut subpath_start : @core.Point = @core.Point::new(x=0.0, y=0.0)
  let mut has_current : Bool = false
  let mut has_subpath : Bool = false
  for verb in spec.verbs {
    match verb {
      @core.PathVerb::MoveTo(p) => {
        verts.push(p)
        current = p
        subpath_start = p
        has_current = true
        has_subpath = true
      }
      @core.PathVerb::LineTo(p) => {
        verts.push(p)
        current = p
        has_current = true
      }
      @core.PathVerb::QuadTo(c, p) => {
        if has_current {
          flatten_quadratic(current, c, p, verts, tol_sq, 0)
        }
        current = p
        has_current = true
      }
      @core.PathVerb::CubicTo(c1, c2, p) => {
        if has_current {
          flatten_cubic(current, c1, c2, p, verts, tol_sq, 0)
        }
        current = p
        has_current = true
      }
      @core.PathVerb::Close => {
        if has_current && has_subpath {
          verts.push(subpath_start)
          current = subpath_start
        }
      }
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

// ─────────────────────────────────────────────────────────────────
// Phase 16.F — DrawShadow DrawCommand wire-up
// ─────────────────────────────────────────────────────────────────
//
// Phase 16.B added `paint_shadow_rect` + `blur_h` + `blur_v` as
// standalone primitives. Phase 16.F wires them into the
// command dispatcher via the existing `@core.DrawCommand::
// DrawShadow(ShadowSpec)` variant (already in the Moui core
// enum). A module-local `shadow_scratch` buffer is reused
// across frames — Phase 16.B's paint_shadow_rect takes a
// scratch buffer as a separate arg so the BGRA stays in `buf`
// during the blur pass.
//
// `ShadowSpec::new` defaults `offset=(0, 2)`, `blur_radius=8.0`,
// `spread=0.0`. Our 5x5 box blur (radius=2) is fixed — for a
// blur radius > 2 we currently use radius=2 and call it close
// enough; a future batch can add a configurable kernel size.

///|
/// Module-local scratch buffer for `paint_shadow_rect`.
/// Lazily resized to match the destination buffer dimensions
/// on each shadow paint. Reused across frames to avoid the
/// allocation cost.
let shadow_scratch : Ref[PixelBuffer] = {
  val: PixelBuffer::new(1, 1, @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0)),
}

///|
/// Ensure `shadow_scratch` is at least `w` x `h`. Grows in
/// place if too small. Called at the top of every shadow
/// paint to keep the scratch reusable across frames.
fn ensure_shadow_scratch(w : Int, h : Int) -> Unit {
  if shadow_scratch.val.width >= w && shadow_scratch.val.height >= h {
    return
  }
  shadow_scratch.val = PixelBuffer::new(
    w,
    h,
    @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0),
  )
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
  cache : ImageCache,
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
    dispatch_command(buf, cmd, clip_stack, opacity_stack, cache)
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
  cache : ImageCache,
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
    @core.DrawCommand::DrawImage(run) =>
      // Phase 13 — real RGBA blit from the per-process
      // ImageCache. On cache hit we nearest-neighbor sample the
      // decoded image into `buf` (alpha-blended). On cache miss
      // we fall back to the legacy gray-outline + diagonal X
      // placeholder via `paint_image_placeholder`. The cache is
      // owned by the caller (renderer.mbt) so the rasterizer
      // itself stays stateless.
      paint_image(buf, run, clip, opacity, cache)
    @core.DrawCommand::DrawShadow(spec) => {
      // Phase 16.F — wire the existing `DrawShadow(ShadowSpec)`
      // Moui variant through the Phase 16.B `paint_shadow_rect`
      // pipeline. Grows the module-local scratch buffer to
      // match the destination. The foreground rect is painted
      // by the caller as a separate FillRoundedRect command
      // after the shadow; `paint_shadow_rect` only paints the
      // soft drop behind it.
      let rect : @core.Rect = spec.rect.rect
      let cw : Int = buf.width
      let ch : Int = buf.height
      ensure_shadow_scratch(cw, ch)
      paint_shadow_rect(
        buf,
        shadow_scratch.val,
        rect,
        spec.offset,
        spec.color,
        opacity,
        @core.Rect::new(x=0.0, y=0.0, width=cw.to_double(), height=ch.to_double()),
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


///|
/// Separable 5-tap box blur (radius 2): horizontal pass from
/// `buf` to `scratch`, then vertical pass from `scratch` back
/// to `buf`. Region is `x0..x0+w` x `y0..y0+h`. Out-of-region
/// samples (within 2 px of the edge) clamp to the buffer edge.
/// Phase 16.B: cheap Gaussian-ish blur, exact box, separable so
/// O(w*h*5) horizontal + O(w*h*5) vertical = 10 reads per pixel.
pub fn blur_h(
  buf : PixelBuffer,
  scratch : PixelBuffer,
  x0 : Int,
  y0 : Int,
  w : Int,
  h : Int,
) -> Unit {
  let b_stride : Int = buf.width * 4
  let s_stride : Int = scratch.width * 4
  let bp = buf.pixels
  let sp = scratch.pixels
  for y = y0; y < y0 + h; y = y + 1 {
    for x = x0; x < x0 + w; x = x + 1 {
      let mut sum_b : Int = 0
      let mut sum_g : Int = 0
      let mut sum_r : Int = 0
      let mut sum_a : Int = 0
      let mut k : Int = -2
      while k <= 2 {
        let mut sx : Int = x + k
        if sx < 0 { sx = 0 }
        if sx >= buf.width { sx = buf.width - 1 }
        let off : Int = y * b_stride + sx * 4
        sum_b = sum_b + bp[off].to_int()
        sum_g = sum_g + bp[off + 1].to_int()
        sum_r = sum_r + bp[off + 2].to_int()
        sum_a = sum_a + bp[off + 3].to_int()
        k = k + 1
      }
      let soff : Int = y * s_stride + x * 4
      sp[soff] = (sum_b / 5).to_byte()
      sp[soff + 1] = (sum_g / 5).to_byte()
      sp[soff + 2] = (sum_r / 5).to_byte()
      sp[soff + 3] = (sum_a / 5).to_byte()
    }
  }
}

///|
/// Vertical pass of the separable 5-tap box blur: reads from
/// `scratch`, writes to `buf`. Region is `x0..x0+w` x `y0..y0+h`.
pub fn blur_v(
  scratch : PixelBuffer,
  buf : PixelBuffer,
  x0 : Int,
  y0 : Int,
  w : Int,
  h : Int,
) -> Unit {
  let s_stride : Int = scratch.width * 4
  let b_stride : Int = buf.width * 4
  let sp = scratch.pixels
  let bp = buf.pixels
  for y = y0; y < y0 + h; y = y + 1 {
    for x = x0; x < x0 + w; x = x + 1 {
      let mut sum_b : Int = 0
      let mut sum_g : Int = 0
      let mut sum_r : Int = 0
      let mut sum_a : Int = 0
      let mut k : Int = -2
      while k <= 2 {
        let mut sy : Int = y + k
        if sy < 0 { sy = 0 }
        if sy >= scratch.height { sy = scratch.height - 1 }
        let off : Int = sy * s_stride + x * 4
        sum_b = sum_b + sp[off].to_int()
        sum_g = sum_g + sp[off + 1].to_int()
        sum_r = sum_r + sp[off + 2].to_int()
        sum_a = sum_a + sp[off + 3].to_int()
        k = k + 1
      }
      let off : Int = y * b_stride + x * 4
      bp[off] = (sum_b / 5).to_byte()
      bp[off + 1] = (sum_g / 5).to_byte()
      bp[off + 2] = (sum_r / 5).to_byte()
      bp[off + 3] = (sum_a / 5).to_byte()
    }
  }
}

///|
/// Paint a soft shadow under a rect. Pipeline:
///   1. Compute the shadow rect: same size as `rect`, offset by
///      `(offset.x, offset.y)`, then grow by 2 px on each side
///      so the blur kernel does not clip the shadow edges.
///   2. Clear the shadow region in `scratch` to transparent.
///   3. Fill the inner (un-grown) shadow rect into `scratch`
///      with `color` at full opacity.
///   4. blur_h + blur_v on the grown region.
///   5. Composite the blurred shadow onto `buf` at `opacity`
///      (blend per-pixel, using the blurred alpha as the
///      source opacity, the existing `buf` pixel as the bg).
///
/// After this returns the caller can paint the foreground rect
/// on top to cover the shadow underneath the shape.
pub fn paint_shadow_rect(
  buf : PixelBuffer,
  scratch : PixelBuffer,
  rect : @core.Rect,
  offset : @core.Point,
  color : @core.Color,
  opacity : Double,
  clip : @core.Rect,
) -> Unit {
  // Shadow rect (not yet grown).
  let sh_x : Double = rect.origin.x + offset.x
  let sh_y : Double = rect.origin.y + offset.y
  let sh_w : Double = rect.size.width
  let sh_h : Double = rect.size.height
  // Grow by 2 px (blur radius) on each side.
  let grow : Double = 2.0
  let grown : @core.Rect = @core.Rect::new(
    x=sh_x - grow,
    y=sh_y - grow,
    width=sh_w + 2.0 * grow,
    height=sh_h + 2.0 * grow,
  )
  // Clip against buffer bounds + user clip.
  let buf_bounds : @core.Rect = @core.Rect::new(
    x=0.0,
    y=0.0,
    width=buf.width.to_double(),
    height=buf.height.to_double(),
  )
  let clipped1 : @core.Rect? = grown.intersection(clip)
  guard clipped1 is Some(c1) else { return }
  let clipped : @core.Rect? = c1.intersection(buf_bounds)
  guard clipped is Some(c) else { return }
  let x_lo : Int = c.origin.x.floor().to_int()
  let y_lo : Int = c.origin.y.floor().to_int()
  let x_hi : Int = (c.origin.x + c.size.width).ceil().to_int() - 1
  let y_hi : Int = (c.origin.y + c.size.height).ceil().to_int() - 1
  if x_lo > x_hi || y_lo > y_hi { return }
  let rw : Int = x_hi - x_lo + 1
  let rh : Int = y_hi - y_lo + 1
  // 2. Clear scratch region to transparent.
  let s_stride : Int = scratch.width * 4
  let sp = scratch.pixels
  for y = y_lo; y <= y_hi; y = y + 1 {
    let off : Int = y * s_stride + x_lo * 4
    for x = 0; x < rw * 4; x = x + 1 {
      sp[off + x] = (0).to_byte()
    }
  }
  // 3. Fill the inner shadow rect into scratch with shadow color.
  let sh_rect : @core.Rect = @core.Rect::new(
    x=sh_x,
    y=sh_y,
    width=sh_w,
    height=sh_h,
  )
  let sh_clipped : @core.Rect? = sh_rect.intersection(c)
  match sh_clipped {
    Some(sc) => {
      paint_rect_into(scratch, sc, color)
    }
    None => ()
  }
  // 4. Apply separable 5x5 box blur.
  blur_h(scratch, scratch, x_lo, y_lo, rw, rh)
  blur_v(scratch, scratch, x_lo, y_lo, rw, rh)
  // 5. Composite blurred shadow onto buf at opacity. We blend
  // using the blurred alpha (per pixel) as the source alpha,
  // scaled by `opacity`. Standard premultiplied alpha over op.
  let b_stride : Int = buf.width * 4
  let bp = buf.pixels
  for y = y_lo; y <= y_hi; y = y + 1 {
    for x = x_lo; x <= x_hi; x = x + 1 {
      let soff : Int = y * s_stride + x * 4
      let sb : Int = sp[soff].to_int()
      let sg : Int = sp[soff + 1].to_int()
      let sr : Int = sp[soff + 2].to_int()
      let sa_premul : Int = sp[soff + 3].to_int()
      // Source alpha scaled by overall opacity.
      let sa : Double = sa_premul.to_double() / 255.0 * opacity
      if sa <= 0.0 { continue }
      let inv : Double = 1.0 - sa
      let boff : Int = y * b_stride + x * 4
      let bb : Int = bp[boff].to_int()
      let bg_g : Int = bp[boff + 1].to_int()
      let br : Int = bp[boff + 2].to_int()
      let ba_premul : Int = bp[boff + 3].to_int()
      // Source RGB is the shadow color premultiplied by its (already
      // blurred) alpha; we approximate by scaling color.r/g/b by sa.
      let dr : Double = color.r * 255.0 * sa + br.to_double() * inv
      let dg : Double = color.g * 255.0 * sa + bg_g.to_double() * inv
      let db : Double = color.b * 255.0 * sa + bb.to_double() * inv
      let da : Double = sa * 255.0 + ba_premul.to_double() * inv
      bp[boff] = (if db <= 0.0 { 0 } else if db >= 255.0 { 255 } else { db.to_int() }).to_byte()
      bp[boff + 1] = (if dg <= 0.0 { 0 } else if dg >= 255.0 { 255 } else { dg.to_int() }).to_byte()
      bp[boff + 2] = (if dr <= 0.0 { 0 } else if dr >= 255.0 { 255 } else { dr.to_int() }).to_byte()
      bp[boff + 3] = (if da <= 0.0 { 0 } else if da >= 255.0 { 255 } else { da.to_int() }).to_byte()
    }
  }
}

///|
/// Fill `rect` into `buf` with `color` at full opacity, ignoring
/// clip (caller is responsible for rect already being clipped).
/// Used by paint_shadow_rect to paint the un-blurred shadow shape
/// into the scratch buffer before the blur pass.
pub fn paint_rect_into(
  buf : PixelBuffer,
  rect : @core.Rect,
  color : @core.Color,
) -> Unit {
  let x_lo : Int = rect.origin.x.floor().to_int()
  let y_lo : Int = rect.origin.y.floor().to_int()
  let x_hi : Int = (rect.origin.x + rect.size.width).ceil().to_int() - 1
  let y_hi : Int = (rect.origin.y + rect.size.height).ceil().to_int() - 1
  let stride : Int = buf.width * 4
  let b : Int = (color.b * 255.0).to_int()
  let g : Int = (color.g * 255.0).to_int()
  let r : Int = (color.r * 255.0).to_int()
  let a : Int = (color.a * 255.0).to_int()
  let p = buf.pixels
  for y = y_lo; y <= y_hi; y = y + 1 {
    if y < 0 || y >= buf.height { continue }
    let off : Int = y * stride + x_lo * 4
    for x = x_lo; x <= x_hi; x = x + 1 {
      if x < 0 || x >= buf.width { continue }
      p[off + (x - x_lo) * 4] = b.to_byte()
      p[off + (x - x_lo) * 4 + 1] = g.to_byte()
      p[off + (x - x_lo) * 4 + 2] = r.to_byte()
      p[off + (x - x_lo) * 4 + 3] = a.to_byte()
    }
  }
}
