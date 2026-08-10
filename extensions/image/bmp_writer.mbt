// Copyright (c) 2025 lws
// BMP (Bitmap) image encoder
//
// Encodes images as uncompressed BMP files:
//   - 24-bit BGR when all pixels are fully opaque
//   - 32-bit BGRA when any pixel has transparency
//
// Output uses a negative height in the DIB header to signal top-down
// row order, which is simpler and avoids manual row reversal.

//-----------------------------------------------------------------------------
// Little-endian write helpers
//-----------------------------------------------------------------------------

///|
/// Write a 16-bit unsigned integer in little-endian byte order
fn write_u16_le(buf : Array[Byte], pos : Int, val : Int) -> Unit {
  buf[pos] = (val & 0xFF).to_byte()
  buf[pos + 1] = ((val >> 8) & 0xFF).to_byte()
}

///|
/// Write a 32-bit unsigned integer in little-endian byte order
fn write_u32_le(buf : Array[Byte], pos : Int, val : Int) -> Unit {
  buf[pos] = (val & 0xFF).to_byte()
  buf[pos + 1] = ((val >> 8) & 0xFF).to_byte()
  buf[pos + 2] = ((val >> 16) & 0xFF).to_byte()
  buf[pos + 3] = ((val >> 24) & 0xFF).to_byte()
}

//-----------------------------------------------------------------------------
// Alpha detection
//-----------------------------------------------------------------------------

///|
/// Check whether any pixel in an RGBA8 image has a non-opaque alpha value
fn has_alpha(rgba : Image) -> Bool {
  let data = rgba.data
  let pixel_count = rgba.width * rgba.height
  for i = 0; i < pixel_count; i = i + 1 {
    let a = data[i * 4 + 3].to_int()
    if a != 255 {
      return true
    }
  }
  false
}

//-----------------------------------------------------------------------------
// Row stride with 4-byte alignment
//-----------------------------------------------------------------------------

///|
/// Compute the BMP row stride in bytes, padded to a 4-byte boundary
fn bmp_encode_stride(width : Int, bpp : Int) -> Int {
  let row_bytes = width * bpp / 8
  (row_bytes + 3) / 4 * 4
}

//-----------------------------------------------------------------------------
// BMP Encoder
//-----------------------------------------------------------------------------

///|
/// Encode an Image as an uncompressed BMP file.
///
/// The image is converted to RGBA8 internally. If all pixels are fully opaque
/// (alpha = 255 everywhere), the output is 24-bit BGR. Otherwise it is 32-bit
/// BGRA to preserve transparency.
///
/// Pixel data is written top-down with a negative height in the DIB header,
/// so most BMP readers display the image correctly without additional flipping.
///
/// # Errors
///
/// Raises `Failure` if the image has zero width or height.
pub fn encode_bmp(image : Image) -> Bytes raise Failure {
  // Convert to RGBA8 for uniform pixel access
  let rgba = image.to_rgba8()

  // Reject empty images
  if rgba.width <= 0 || rgba.height <= 0 {
    raise Failure::Failure("BMP encode: image dimensions must be positive")
  }

  // Determine bit depth: 32-bit if any pixel has transparency, else 24-bit
  let use_alpha = has_alpha(rgba)
  let bpp = if use_alpha { 32 } else { 24 }
  let bytes_per_pixel = bpp / 8

  // Calculate sizes
  let header_size = 14 + 40
  let row_stride = bmp_encode_stride(rgba.width, bpp)
  let pixel_data_size = row_stride * rgba.height
  let file_size = header_size + pixel_data_size

  // Allocate output buffer
  let buf = Array::make(file_size, b'\x00')

  // === BMP File Header (14 bytes) ===

  // bytes 0-1: "BM" signature
  buf[0] = b'B'
  buf[1] = b'M'

  // bytes 2-5: total file size (little-endian)
  write_u32_le(buf, 2, file_size)

  // bytes 6-9: reserved (already zero-initialized)

  // bytes 10-13: offset from start of file to pixel data (54 = 14 + 40)
  write_u32_le(buf, 10, header_size)

  // === BITMAPINFOHEADER (40 bytes, starting at file offset 14) ===

  // bytes 0-3 (file 14-17): DIB header size (40)
  write_u32_le(buf, 14, 40)

  // bytes 4-7 (file 18-21): image width
  write_u32_le(buf, 18, rgba.width)

  // bytes 8-11 (file 22-25): image height
  // Negative value signals top-down row order, avoiding the need to flip rows
  write_u32_le(buf, 22, -rgba.height)

  // bytes 12-13 (file 26-27): color planes (must be 1)
  write_u16_le(buf, 26, 1)

  // bytes 14-15 (file 28-29): bits per pixel (24 or 32)
  write_u16_le(buf, 28, bpp)

  // bytes 16-19 (file 30-33): compression method (0 = BI_RGB, no compression)
  // already zero-initialized

  // bytes 20-23 (file 34-37): image size (may be 0 for BI_RGB)
  // already zero-initialized

  // bytes 24-27 (file 38-41): horizontal resolution in pixels per meter
  // 2835 ppm ≈ 72 DPI
  write_u32_le(buf, 38, 2835)

  // bytes 28-31 (file 42-45): vertical resolution in pixels per meter
  write_u32_le(buf, 42, 2835)

  // bytes 32-35 (file 46-49): number of colors in palette (0 = full palette)
  // already zero-initialized

  // bytes 36-39 (file 50-53): number of important colors (0 = all important)
  // already zero-initialized

  // === Pixel Data ===
  //
  // Written top-down (row 0 = top of image). The negative height in the DIB
  // header tells BMP readers not to flip the rows.
  //
  // BMP stores pixels in BGR / BGRA byte order (blue first, red third).
  // Each row is padded to a multiple of 4 bytes with zeros.

  let src_data = rgba.data
  let src_stride = rgba.stride()

  for row = 0; row < rgba.height; row = row + 1 {
    let dst_row_offset = header_size + row * row_stride

    for col = 0; col < rgba.width; col = col + 1 {
      let src = row * src_stride + col * 4
      let dst = dst_row_offset + col * bytes_per_pixel

      // BGR / BGRA byte order (reversed from the source RGBA order)
      buf[dst] = src_data[src + 2] // B
      buf[dst + 1] = src_data[src + 1] // G
      buf[dst + 2] = src_data[src] // R
      if use_alpha {
        buf[dst + 3] = src_data[src + 3] // A
      }
    }
  }

  Bytes::from_array(buf)
}
