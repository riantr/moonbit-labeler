// Copyright (c) 2025 lws
// Color utilities — color space conversions and pixel manipulations

//-----------------------------------------------------------------------------
// Alpha blending and color operations
//-----------------------------------------------------------------------------

///|
/// Blend this color with another color using alpha compositing (over operator)
/// The result replaces the background color with this (foreground) color on top
/// `alpha` is in 0..255 range for per-pixel control
pub fn Color::blend(self : Color, other : Color) -> Color {
  let src_a = self.a
  let dst_a = 255 - src_a
  let r = (self.r * src_a + other.r * dst_a) / 255
  let g = (self.g * src_a + other.g * dst_a) / 255
  let b = (self.b * src_a + other.b * dst_a) / 255
  let a = src_a + other.a * dst_a / 255
  Color::new(r, g, b, a)
}

///|
/// Alpha blend with a specific alpha override (0..255)
pub fn Color::blend_alpha(self : Color, other : Color, alpha : Int) -> Color {
  let effective_a = self.a * alpha / 255
  let src_a = effective_a
  let dst_a = 255 - effective_a
  let r = (self.r * src_a + other.r * dst_a) / 255
  let g = (self.g * src_a + other.g * dst_a) / 255
  let b = (self.b * src_a + other.b * dst_a) / 255
  let a = effective_a + other.a * dst_a / 255
  Color::new(r, g, b, a)
}

///|
/// Invert this color (255 - each channel), preserves alpha
pub fn Color::invert(self : Color) -> Color {
  Color::new(255 - self.r, 255 - self.g, 255 - self.b, self.a)
}

///|
/// Linear interpolation between two colors (t in 0..255 fixed-point)
/// Returns an integer-blended color without floating-point
pub fn Color::lerp(self : Color, other : Color, t : Int) -> Color {
  let inv_t = 255 - t
  let r = (self.r * inv_t + other.r * t) / 255
  let g = (self.g * inv_t + other.g * t) / 255
  let b = (self.b * inv_t + other.b * t) / 255
  let a = (self.a * inv_t + other.a * t) / 255
  Color::new(r, g, b, a)
}

//-----------------------------------------------------------------------------
// HSL color space conversions
//-----------------------------------------------------------------------------

///|
/// Convert an RGB color to HSL (Hue 0..360, Saturation 0..100, Lightness 0..100)
/// Uses integer arithmetic to avoid floating-point precision issues
pub fn Color::to_hsl(self : Color) -> (Int, Int, Int) {
  let r = self.r
  let g = self.g
  let b = self.b

  // Find min and max
  let max_val = if r > g {
    if r > b {
      r
    } else {
      b
    }
  } else if g > b {
    g
  } else {
    b
  }
  let min_val = if r < g {
    if r < b {
      r
    } else {
      b
    }
  } else if g < b {
    g
  } else {
    b
  }
  let delta = max_val - min_val

  // Lightness
  let l = (max_val + min_val) * 50 / 255

  // Gray (no saturation)
  if delta == 0 {
    return (0, 0, l)
  }

  // Saturation
  let s = if l > 50 {
    delta * 255 * 100 / (510 - (max_val + min_val))
  } else {
    delta * 255 * 100 / (max_val + min_val)
  }

  // Hue
  let h = if max_val == r {
    60 * (g - b) * 100 / (delta * 255)
  } else if max_val == g {
    120 + 60 * (b - r) * 100 / (delta * 255)
  } else {
    240 + 60 * (r - g) * 100 / (delta * 255)
  }
  let hue = if h < 0 { h + 360 } else { h }
  (hue, s, l)
}

///|
/// Create a Color from HSL values (Hue 0..360, Saturation 0..100, Lightness 0..100)
pub fn Color::from_hsl(hue : Int, saturation : Int, lightness : Int) -> Color {
  let h = hue % 360
  let s = if saturation > 100 { 100 } else { saturation }
  let l = if lightness > 100 { 100 } else { lightness }

  if s == 0 {
    let v = l * 255 / 100
    return Color::from_rgb(v, v, v)
  }

  let hue_f = h
  let s_f = s
  let l_f = l

  let q = if l_f < 50 {
    l_f * (100 + s_f) / 100
  } else {
    l_f + s_f - l_f * s_f / 100
  }
  let p = 2 * l_f - q

  let r = hue_to_rgb(p, q, hue_f + 120)
  let g = hue_to_rgb(p, q, hue_f)
  let b = hue_to_rgb(p, q, hue_f - 120)

  let tr = r * 255 / 100
  let tg = g * 255 / 100
  let tb = b * 255 / 100

  Color::from_rgb(tr, tg, tb)
}

///|
/// HSL helper: convert hue position to RGB component
fn hue_to_rgb(p : Int, q : Int, t_raw : Int) -> Int {
  let mut t = t_raw
  if t < 0 {
    t = t + 360
  }
  if t >= 360 {
    t = t - 360
  }
  if t < 60 {
    return p + (q - p) * t / 60
  } else if t < 180 {
    return q
  } else if t < 240 {
    return p + (q - p) * (240 - t) / 60
  } else {
    return p
  }
}

//-----------------------------------------------------------------------------
// HSV color space conversions
//-----------------------------------------------------------------------------

///|
/// Convert RGB to HSV (Hue 0..360, Saturation 0..100, Value 0..100)
pub fn Color::to_hsv(self : Color) -> (Int, Int, Int) {
  let r = self.r
  let g = self.g
  let b = self.b

  let max_val = if r > g {
    if r > b {
      r
    } else {
      b
    }
  } else if g > b {
    g
  } else {
    b
  }
  let min_val = if r < g {
    if r < b {
      r
    } else {
      b
    }
  } else if g < b {
    g
  } else {
    b
  }
  let delta = max_val - min_val

  // Value
  let v = max_val * 100 / 255

  // Gray
  if delta == 0 {
    return (0, 0, v)
  }

  // Saturation
  let s = delta * 100 / max_val

  // Hue
  let h = if max_val == r {
    60 * (g - b) * 100 / (delta * 255)
  } else if max_val == g {
    120 + 60 * (b - r) * 100 / (delta * 255)
  } else {
    240 + 60 * (r - g) * 100 / (delta * 255)
  }
  let hue = if h < 0 { h + 360 } else { h }
  (hue, s, v)
}

///|
/// Create a Color from HSV values (Hue 0..360, Saturation 0..100, Value 0..100)
pub fn Color::from_hsv(hue : Int, saturation : Int, value : Int) -> Color {
  let h = hue % 360
  let s = if saturation > 100 { 100 } else { saturation }
  let v = if value > 100 { 100 } else { value }

  if s == 0 {
    let gv = v * 255 / 100
    return Color::from_rgb(gv, gv, gv)
  }

  let region = h / 60
  let remainder = h % 60

  let p_val = v * (100 - s) / 100
  let q_val = v * (100 - s * remainder / 60) / 100
  let t_val = v * (100 - s * (60 - remainder) / 60) / 100

  let (r_val, g_val, b_val) = match region {
    0 => (v, t_val, p_val)
    1 => (q_val, v, p_val)
    2 => (p_val, v, t_val)
    3 => (p_val, q_val, v)
    4 => (t_val, p_val, v)
    _ => (v, p_val, q_val)
  }

  let r = r_val * 255 / 100
  let g = g_val * 255 / 100
  let b = b_val * 255 / 100
  Color::from_rgb(r, g, b)
}

//-----------------------------------------------------------------------------
// Perceptual color distance
//-----------------------------------------------------------------------------

///|
/// Compute a simple perceptual color distance (weighted Euclidean)
/// Uses simplified CIE76-like formula with weighted RGB components.
/// Returns 0..441 for maximum distance (black vs white at max alpha).
pub fn Color::distance(self : Color, other : Color) -> Int {
  let dr = self.r - other.r
  let dg = self.g - other.g
  let db = self.b - other.b
  let da = self.a - other.a

  // Weighted by human perception sensitivity (green most, blue least)
  let rmean = (self.r + other.r) / 2
  let r_weight = (512 + rmean) / 256 // red gets more weight when both are red
  let g_weight = 4 // green is most visible
  let b_weight = (767 - rmean) / 256 // blue gets less weight when colors are red

  let squared = dr * dr * r_weight +
    dg * dg * g_weight +
    db * db * b_weight +
    da * da * 2
  squared / 16 // Normalized to reasonable range
}

//-----------------------------------------------------------------------------
// Image-level color utilities
//-----------------------------------------------------------------------------

///|
/// Compute the average color of the image
pub fn Image::average_color(self : Image) -> Color {
  let pixel_count = self.width * self.height
  let mut r_sum = 0
  let mut g_sum = 0
  let mut b_sum = 0
  let mut a_sum = 0

  match self.format {
    PixelFormat::Gray8 =>
      for i = 0; i < pixel_count; i = i + 1 {
        let v = self.data[i].to_int()
        r_sum = r_sum + v
        g_sum = g_sum + v
        b_sum = b_sum + v
        a_sum = a_sum + 255
      }
    PixelFormat::GrayA8 =>
      for i = 0; i < pixel_count; i = i + 1 {
        let src = i * 2
        let v = self.data[src].to_int()
        let a = self.data[src + 1].to_int()
        r_sum = r_sum + v
        g_sum = g_sum + v
        b_sum = b_sum + v
        a_sum = a_sum + a
      }
    PixelFormat::RGB8 =>
      for i = 0; i < pixel_count; i = i + 1 {
        let src = i * 3
        r_sum = r_sum + self.data[src].to_int()
        g_sum = g_sum + self.data[src + 1].to_int()
        b_sum = b_sum + self.data[src + 2].to_int()
        a_sum = a_sum + 255
      }
    PixelFormat::RGBA8 =>
      for i = 0; i < pixel_count; i = i + 1 {
        let src = i * 4
        r_sum = r_sum + self.data[src].to_int()
        g_sum = g_sum + self.data[src + 1].to_int()
        b_sum = b_sum + self.data[src + 2].to_int()
        a_sum = a_sum + self.data[src + 3].to_int()
      }
  }

  if pixel_count == 0 {
    return Color::default()
  }

  let avg_r = r_sum / pixel_count
  let avg_g = g_sum / pixel_count
  let avg_b = b_sum / pixel_count
  let avg_a = a_sum / pixel_count
  Color::new(avg_r, avg_g, avg_b, avg_a)
}

///|
/// Compute a 256-bin luminance histogram from the image
/// Returns an array[256] of pixel counts, indexed by luminance value (0-255)
pub fn Image::histogram(self : Image) -> Array[Int] {
  let bins = Array::make(256, 0)
  let pixel_count = self.width * self.height

  match self.format {
    PixelFormat::Gray8 =>
      for i = 0; i < pixel_count; i = i + 1 {
        let v = self.data[i].to_int()
        bins[v] = bins[v] + 1
      }
    PixelFormat::GrayA8 =>
      for i = 0; i < pixel_count; i = i + 1 {
        let v = self.data[i * 2].to_int()
        bins[v] = bins[v] + 1
      }
    PixelFormat::RGB8 =>
      for i = 0; i < pixel_count; i = i + 1 {
        let src = i * 3
        let r = self.data[src].to_int()
        let g = self.data[src + 1].to_int()
        let b = self.data[src + 2].to_int()
        // ITU-R BT.601 luminance
        let lum = (r * 299 + g * 587 + b * 114) / 1000
        bins[lum] = bins[lum] + 1
      }
    PixelFormat::RGBA8 =>
      for i = 0; i < pixel_count; i = i + 1 {
        let src = i * 4
        let r = self.data[src].to_int()
        let g = self.data[src + 1].to_int()
        let b = self.data[src + 2].to_int()
        let lum = (r * 299 + g * 587 + b * 114) / 1000
        bins[lum] = bins[lum] + 1
      }
  }

  bins
}

///|
/// Brighten the image by adding a delta to all channels
/// Positive delta brightens, negative darkens. Clamped to 0..255.
/// Returns a new Image (does not modify self).
pub fn Image::brighten(self : Image, delta : Int) -> Image {
  let pixel_count = self.width * self.height
  let bpp = self.bytes_per_pixel()
  let out_size = pixel_count * bpp
  let _buf = Array::make(out_size, Byte::default())

  for i = 0; i < out_size; i = i + 1 {
    // Only adjust RGB channels, skip alpha
    let is_alpha = match self.format {
      PixelFormat::GrayA8 => i % 2 == 1
      PixelFormat::RGBA8 => i % 4 == 3
      _ => false
    }
    if is_alpha {
      _buf[i] = self.data[i]
    } else {
      let v = self.data[i].to_int() + delta
      if v > 255 {
        _buf[i] = b'\xFF'
      } else if v < 0 {
        _buf[i] = b'\x00'
      } else {
        _buf[i] = v.to_byte()
      }
    }
  }

  Image::new(self.width, self.height, self.format, Bytes::from_array(_buf))
}

///|
/// Convert an image to grayscale in-place (returns Gray8 or GrayA8)
pub fn Image::to_grayscale(self : Image) -> Image {
  match self.format {
    PixelFormat::Gray8 | PixelFormat::GrayA8 => self
    _ => {
      let pixel_count = self.width * self.height
      let _buf = Array::make(pixel_count, Byte::default())
      match self.format {
        PixelFormat::RGB8 =>
          for i = 0; i < pixel_count; i = i + 1 {
            let src = i * 3
            let r = self.data[src].to_int()
            let g = self.data[src + 1].to_int()
            let b = self.data[src + 2].to_int()
            let lum = (r * 299 + g * 587 + b * 114) / 1000
            _buf[i] = lum.to_byte()
          }
        PixelFormat::RGBA8 =>
          for i = 0; i < pixel_count; i = i + 1 {
            let src = i * 4
            let r = self.data[src].to_int()
            let g = self.data[src + 1].to_int()
            let b = self.data[src + 2].to_int()
            let lum = (r * 299 + g * 587 + b * 114) / 1000
            _buf[i] = lum.to_byte()
          }
        _ =>
          // Should not reach here
          for i = 0; i < pixel_count; i = i + 1 {
            _buf[i] = b'\x00'
          }
      }
      Image::new(
        self.width,
        self.height,
        PixelFormat::Gray8,
        Bytes::from_array(_buf),
      )
    }
  }
}
