// Copyright (c) 2025 lws
// Image transformation utilities — flip, rotate, crop, resize
//
// All functions operate on raw bytes for performance and work with
// every PixelFormat (Gray8, GrayA8, RGB8, RGBA8).

//-----------------------------------------------------------------------------
// Helpers
//-----------------------------------------------------------------------------

///|
/// Copy a block of bpp bytes from src to dst
fn copy_pixel(
  src : Bytes,
  src_off : Int,
  dst : Array[Byte],
  dst_off : Int,
  bpp : Int,
) -> Unit {
  for i = 0; i < bpp; i = i + 1 {
    dst[dst_off + i] = src[src_off + i]
  }
}

//-----------------------------------------------------------------------------
// Flip
//-----------------------------------------------------------------------------

///|
/// Flip the image horizontally (mirror left-to-right).
/// Each row is reversed in-place into a new buffer.
pub fn Image::flip_horizontal(self : Image) -> Image {
  let bpp = self.bytes_per_pixel()
  let stride = self.stride()
  let pixel_count = self.width * self.height
  let out_size = pixel_count * bpp
  let buf = Array::make(out_size, b'\x00')

  for y = 0; y < self.height; y = y + 1 {
    let row_off = y * stride
    for x = 0; x < self.width; x = x + 1 {
      let src_off = row_off + x * bpp
      let dst_x = self.width - 1 - x
      let dst_off = row_off + dst_x * bpp
      copy_pixel(self.data, src_off, buf, dst_off, bpp)
    }
  }

  Image::new(self.width, self.height, self.format, Bytes::from_array(buf))
}

///|
/// Flip the image vertically (mirror top-to-bottom).
/// Rows are copied in reverse order to a new buffer.
pub fn Image::flip_vertical(self : Image) -> Image {
  let bpp = self.bytes_per_pixel()
  let stride = self.stride()
  let pixel_count = self.width * self.height
  let out_size = pixel_count * bpp
  let buf = Array::make(out_size, b'\x00')

  for y = 0; y < self.height; y = y + 1 {
    let src_row_off = y * stride
    let dst_y = self.height - 1 - y
    let dst_row_off = dst_y * stride
    for i = 0; i < stride; i = i + 1 {
      buf[dst_row_off + i] = self.data[src_row_off + i]
    }
  }

  Image::new(self.width, self.height, self.format, Bytes::from_array(buf))
}

//-----------------------------------------------------------------------------
// Rotate
//-----------------------------------------------------------------------------

///|
/// Rotate the image 90 degrees clockwise.
/// New width = old height, new height = old width.
pub fn Image::rotate_90(self : Image) -> Image {
  let bpp = self.bytes_per_pixel()
  let old_stride = self.stride()
  let new_w = self.height
  let new_h = self.width
  let new_stride = new_w * bpp
  let out_size = new_w * new_h * bpp
  let buf = Array::make(out_size, b'\x00')

  for dst_y = 0; dst_y < new_h; dst_y = dst_y + 1 {
    for dst_x = 0; dst_x < new_w; dst_x = dst_x + 1 {
      // Clockwise 90: output[x][y] = input[y][old_h - 1 - x]
      let src_x = dst_y
      let src_y = self.height - 1 - dst_x
      let src_off = src_y * old_stride + src_x * bpp
      let dst_off = dst_y * new_stride + dst_x * bpp
      copy_pixel(self.data, src_off, buf, dst_off, bpp)
    }
  }

  Image::new(new_w, new_h, self.format, Bytes::from_array(buf))
}

///|
/// Rotate the image 180 degrees.
/// Implemented as flip horizontal then flip vertical.
pub fn Image::rotate_180(self : Image) -> Image {
  self.flip_horizontal().flip_vertical()
}

///|
/// Rotate the image 270 degrees clockwise (equivalent to 90 degrees counter-clockwise).
/// New width = old height, new height = old width.
pub fn Image::rotate_270(self : Image) -> Image {
  let bpp = self.bytes_per_pixel()
  let old_stride = self.stride()
  let new_w = self.height
  let new_h = self.width
  let new_stride = new_w * bpp
  let out_size = new_w * new_h * bpp
  let buf = Array::make(out_size, b'\x00')

  for dst_y = 0; dst_y < new_h; dst_y = dst_y + 1 {
    for dst_x = 0; dst_x < new_w; dst_x = dst_x + 1 {
      // 270 clockwise (= 90 counter-clockwise): output[x][y] = input[old_w - 1 - y][x]
      let src_x = self.width - 1 - dst_y
      let src_y = dst_x
      let src_off = src_y * old_stride + src_x * bpp
      let dst_off = dst_y * new_stride + dst_x * bpp
      copy_pixel(self.data, src_off, buf, dst_off, bpp)
    }
  }

  Image::new(new_w, new_h, self.format, Bytes::from_array(buf))
}

//-----------------------------------------------------------------------------
// Crop
//-----------------------------------------------------------------------------

///|
/// Extract a sub-rectangle from the image.
///
/// # Errors
///
/// Raises `Failure` if the crop region is out of bounds or has non-positive
/// dimensions.
pub fn Image::crop(
  self : Image,
  x : Int,
  y : Int,
  w : Int,
  h : Int,
) -> Image raise Failure {
  // Bounds checking
  if x < 0 || y < 0 || w <= 0 || h <= 0 {
    raise Failure::Failure(
      "crop: invalid region (x=\{x}, y=\{y}, w=\{w}, h=\{h})",
    )
  }
  if x + w > self.width {
    raise Failure::Failure(
      "crop: x + w (\{x + w}) exceeds image width (\{self.width})",
    )
  }
  if y + h > self.height {
    raise Failure::Failure(
      "crop: y + h (\{y + h}) exceeds image height (\{self.height})",
    )
  }

  let bpp = self.bytes_per_pixel()
  let src_stride = self.stride()
  let dst_stride = w * bpp
  let out_size = w * h * bpp
  let buf = Array::make(out_size, b'\x00')

  for row = 0; row < h; row = row + 1 {
    let src_row_off = (y + row) * src_stride + x * bpp
    let dst_row_off = row * dst_stride
    for i = 0; i < dst_stride; i = i + 1 {
      buf[dst_row_off + i] = self.data[src_row_off + i]
    }
  }

  Image::new(w, h, self.format, Bytes::from_array(buf))
}

//-----------------------------------------------------------------------------
// Resize — Nearest Neighbor
//-----------------------------------------------------------------------------

///|
/// Resize the image using nearest-neighbor sampling.
/// Uses integer arithmetic: src_x = dst_x * old_w / new_w.
pub fn Image::resize_nearest(self : Image, new_w : Int, new_h : Int) -> Image {
  if new_w <= 0 || new_h <= 0 {
    return Image::new(
      0,
      0,
      self.format,
      Bytes::from_array(Array::make(0, b'\x00')),
    )
  }
  if self.width == 0 || self.height == 0 {
    return Image::new(
      new_w,
      new_h,
      self.format,
      Bytes::from_array(
        Array::make(new_w * new_h * self.bytes_per_pixel(), b'\x00'),
      ),
    )
  }

  let bpp = self.bytes_per_pixel()
  let old_stride = self.stride()
  let new_stride = new_w * bpp
  let out_size = new_w * new_h * bpp
  let buf = Array::make(out_size, b'\x00')

  for dst_y = 0; dst_y < new_h; dst_y = dst_y + 1 {
    let src_y = dst_y * self.height / new_h
    // Clamp to valid range (handles edge case when new_h == 1)
    let src_y_clamped = if src_y >= self.height {
      self.height - 1
    } else {
      src_y
    }
    let dst_row_off = dst_y * new_stride
    let src_row_off = src_y_clamped * old_stride

    for dst_x = 0; dst_x < new_w; dst_x = dst_x + 1 {
      let src_x = dst_x * self.width / new_w
      let src_x_clamped = if src_x >= self.width {
        self.width - 1
      } else {
        src_x
      }
      let dst_off = dst_row_off + dst_x * bpp
      let src_off = src_row_off + src_x_clamped * bpp
      copy_pixel(self.data, src_off, buf, dst_off, bpp)
    }
  }

  Image::new(new_w, new_h, self.format, Bytes::from_array(buf))
}

//-----------------------------------------------------------------------------
// Resize — Bilinear Interpolation
//-----------------------------------------------------------------------------

///|
/// Resize the image using bilinear interpolation.
/// Each output pixel is a weighted blend of its 4 nearest source neighbors.
/// Interpolation is performed independently on each byte channel.
pub fn Image::resize_bilinear(self : Image, new_w : Int, new_h : Int) -> Image {
  if new_w <= 0 || new_h <= 0 {
    return Image::new(
      0,
      0,
      self.format,
      Bytes::from_array(Array::make(0, b'\x00')),
    )
  }
  if self.width == 0 || self.height == 0 {
    return Image::new(
      new_w,
      new_h,
      self.format,
      Bytes::from_array(
        Array::make(new_w * new_h * self.bytes_per_pixel(), b'\x00'),
      ),
    )
  }

  let bpp = self.bytes_per_pixel()
  let old_w = self.width
  let old_h = self.height
  let old_stride = self.stride()
  let new_stride = new_w * bpp
  let out_size = new_w * new_h * bpp
  let buf = Array::make(out_size, b'\x00')

  for dst_y = 0; dst_y < new_h; dst_y = dst_y + 1 {
    // Compute source y position with fractional part (8-bit fixed point)
    let (src_y0, frac_y) = if old_h == 1 || new_h == 1 {
      (0, 0)
    } else {
      let num = dst_y * (old_h - 1)
      let y0 = num / (new_h - 1)
      let rem = num - y0 * (new_h - 1)
      let fy = rem * 256 / (new_h - 1)
      (y0, fy)
    }
    let src_y1 = if src_y0 + 1 >= old_h { src_y0 } else { src_y0 + 1 }

    let dst_row_off = dst_y * new_stride

    for dst_x = 0; dst_x < new_w; dst_x = dst_x + 1 {
      // Compute source x position with fractional part (8-bit fixed point)
      let (src_x0, frac_x) = if old_w == 1 || new_w == 1 {
        (0, 0)
      } else {
        let num = dst_x * (old_w - 1)
        let x0 = num / (new_w - 1)
        let rem = num - x0 * (new_w - 1)
        let fx = rem * 256 / (new_w - 1)
        (x0, fx)
      }
      let src_x1 = if src_x0 + 1 >= old_w { src_x0 } else { src_x0 + 1 }

      let inv_fx = 256 - frac_x
      let inv_fy = 256 - frac_y

      // Compute offsets for the 4 source pixels
      let off00 = src_y0 * old_stride + src_x0 * bpp
      let off10 = src_y0 * old_stride + src_x1 * bpp
      let off01 = src_y1 * old_stride + src_x0 * bpp
      let off11 = src_y1 * old_stride + src_x1 * bpp

      let dst_off = dst_row_off + dst_x * bpp

      // Interpolate each byte channel independently
      for c = 0; c < bpp; c = c + 1 {
        let v00 = self.data[off00 + c].to_int()
        let v10 = self.data[off10 + c].to_int()
        let v01 = self.data[off01 + c].to_int()
        let v11 = self.data[off11 + c].to_int()

        // Two-pass bilinear: horizontal then vertical
        let top = (v00 * inv_fx + v10 * frac_x) / 256
        let bottom = (v01 * inv_fx + v11 * frac_x) / 256
        let val = (top * inv_fy + bottom * frac_y) / 256

        buf[dst_off + c] = val.to_byte()
      }
    }
  }

  Image::new(new_w, new_h, self.format, Bytes::from_array(buf))
}
