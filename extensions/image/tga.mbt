// Copyright (c) 2025 lws
// TGA (Truevision Targa) image decoder
//
// TGA is a simple raster graphics file format widely used in games and VFX.
// Supported formats:
//   - Type 2: Uncompressed true-color (RGB/RGBA, 24/32-bit)
//   - Type 3: Uncompressed grayscale (8-bit)
//   - Type 10: RLE compressed true-color (24/32-bit)
//   - Type 11: RLE compressed grayscale (8-bit)
//   - 16-bit A1R5G5B5 format
//   - Top-left and bottom-left image origin

///|
/// Decode a TGA image from raw bytes
pub fn decode_tga(data : Bytes) -> Image raise Failure {
  let decoder = TgaDecoder::new(data)
  decoder.decode()
}

///|
/// TGA decoder state
priv struct TgaDecoder {
  data : Bytes
  width : Int
  height : Int
  pixel_depth : Int
  image_descriptor : Int
  data_offset : Int
  rle : Bool
}

///|
fn TgaDecoder::new(data : Bytes) -> TgaDecoder raise Failure {
  if data.length() < 18 {
    raise Failure::Failure("TGA: file too small for header")
  }
  let id_length = data[0].to_int()
  let color_map_type = data[1].to_int()
  let image_type = data[2].to_int()

  // Read image specification
  let width = read_u16_le(data, 12)
  let height = read_u16_le(data, 14)
  let pixel_depth = data[16].to_int()
  let image_descriptor = data[17].to_int()

  if width <= 0 || height <= 0 {
    raise Failure::Failure("TGA: invalid dimensions")
  }

  // Supported image types
  let rle = match image_type {
    2 => false // Uncompressed true-color
    3 => false // Uncompressed grayscale
    10 => true // RLE true-color
    11 => true // RLE grayscale
    _ => raise Failure::Failure("TGA: unsupported image type: \{image_type}")
  }

  // Supported pixel depths
  if pixel_depth != 8 &&
    pixel_depth != 16 &&
    pixel_depth != 24 &&
    pixel_depth != 32 {
    raise Failure::Failure("TGA: unsupported pixel depth: \{pixel_depth}")
  }

  // Calculate data offset: header (18) + ID field + color map
  let id_offset = 18 + id_length
  let mut _color_map_size = 0
  if color_map_type == 1 {
    let _cm_first = read_u16_le(data, 3)
    let cm_length = read_u16_le(data, 5)
    let cm_entry_size = data[7].to_int()
    _color_map_size = cm_length * ((cm_entry_size + 7) / 8)
  }
  let data_offset = id_offset + _color_map_size

  { data, width, height, pixel_depth, image_descriptor, data_offset, rle }
}

///|
fn TgaDecoder::decode(self : TgaDecoder) -> Image raise Failure {
  if self.rle {
    self.decode_rle()
  } else {
    self.decode_uncompressed()
  }
}

///|
/// Bytes per pixel for the source TGA data
fn TgaDecoder::src_bpp(self : TgaDecoder) -> Int {
  self.pixel_depth / 8
}

///|
/// Image origin: true = top-left, false = bottom-left
fn TgaDecoder::top_origin(self : TgaDecoder) -> Bool {
  let origin_bits = (self.image_descriptor >> 4) & 0x3
  origin_bits == 2 || origin_bits == 3
}

///|
/// Map destination row to source row in file
/// Output is always top-to-bottom. TGA can store top-to-bottom or bottom-to-top.
/// - If file is top-to-bottom (top_origin): src_row = dst_row (no flip needed)
/// - If file is bottom-to-top: src_row = height - 1 - dst_row (flip)
fn TgaDecoder::src_row(self : TgaDecoder, dst_row : Int) -> Int {
  if self.top_origin() {
    dst_row // File is already top-to-bottom, matches output order
  } else {
    self.height - 1 - dst_row // File is bottom-to-top, flip to match output
  }
}

///|
/// Decode uncompressed TGA data
fn TgaDecoder::decode_uncompressed(self : TgaDecoder) -> Image raise Failure {
  let src_bpp = self.src_bpp()
  let out_bpp = if self.pixel_depth <= 8 { 1 } else { 4 }
  let out_size = self.width * self.height * out_bpp
  let _buf = Array::make(out_size, Byte::default())

  // Row stride (TGA rows are tightly packed, no padding)
  let src_stride = self.width * src_bpp
  // Upfront bounds validation: total pixel data region must fit
  if self.data.length() < self.data_offset + self.height * src_stride {
    raise Failure::Failure("TGA: unexpected end of pixel data")
  }

  for dst_y = 0; dst_y < self.height; dst_y = dst_y + 1 {
    let src_y = self.src_row(dst_y)
    let src_row_offset = self.data_offset + src_y * src_stride

    for x = 0; x < self.width; x = x + 1 {
      let src_pixel_offset = src_row_offset + x * src_bpp

      let dst_pixel_offset = (dst_y * self.width + x) * out_bpp

      if self.pixel_depth == 8 {
        // Grayscale
        _buf[dst_pixel_offset] = self.data[src_pixel_offset]
      } else if self.pixel_depth == 16 {
        // 16-bit: A1R5G5B5 or grayscale+alpha
        let lo = self.data[src_pixel_offset].to_int()
        let hi = self.data[src_pixel_offset + 1].to_int()
        let val = lo | (hi << 8)
        let r = ((val >> 10) & 0x1F) * 255 / 31
        let g = ((val >> 5) & 0x1F) * 255 / 31
        let b = (val & 0x1F) * 255 / 31
        let a = if val >> 15 != 0 { 255 } else { 0 }
        _buf[dst_pixel_offset] = r.to_byte()
        _buf[dst_pixel_offset + 1] = g.to_byte()
        _buf[dst_pixel_offset + 2] = b.to_byte()
        _buf[dst_pixel_offset + 3] = a.to_byte()
      } else if self.pixel_depth == 24 {
        // BGR → RGB
        _buf[dst_pixel_offset] = self.data[src_pixel_offset + 2] // R
        _buf[dst_pixel_offset + 1] = self.data[src_pixel_offset + 1] // G
        _buf[dst_pixel_offset + 2] = self.data[src_pixel_offset] // B
        _buf[dst_pixel_offset + 3] = b'\xFF' // A
      } else {
        // 32-bit BGRA → RGBA
        _buf[dst_pixel_offset] = self.data[src_pixel_offset + 2] // R
        _buf[dst_pixel_offset + 1] = self.data[src_pixel_offset + 1] // G
        _buf[dst_pixel_offset + 2] = self.data[src_pixel_offset] // B
        _buf[dst_pixel_offset + 3] = self.data[src_pixel_offset + 3] // A
      }
    }
  }

  let format = if out_bpp == 1 {
    PixelFormat::Gray8
  } else {
    PixelFormat::RGBA8
  }
  Image::new(self.width, self.height, format, Bytes::from_array(_buf))
}

///|
/// Decode RLE-compressed TGA data
/// RLE packets are read sequentially (not row-by-row), then scattered by row flipping
/// Uses incremental (x,y) tracking instead of per-pixel division/modulo
fn TgaDecoder::decode_rle(self : TgaDecoder) -> Image raise Failure {
  let src_bpp = self.src_bpp()
  let out_bpp = if self.pixel_depth <= 8 { 1 } else { 4 }
  let out_size = self.width * self.height * out_bpp
  let _buf = Array::make(out_size, Byte::default())

  let total_pixels = self.width * self.height
  let mut pixels_done = 0
  let mut pos = self.data_offset
  let mut cur_x = 0 // file-order column (0..width-1)
  let mut cur_y = 0 // file-order row (0..height-1)

  while pixels_done < total_pixels {
    if pos >= self.data.length() {
      raise Failure::Failure("TGA: unexpected end of RLE data")
    }
    let packet_header = self.data[pos].to_int()
    pos = pos + 1
    let packet_type = (packet_header >> 7) & 1 // 1 = RLE, 0 = raw
    let count = (packet_header & 0x7F) + 1 // 1..128 pixels

    if count > total_pixels - pixels_done {
      raise Failure::Failure("TGA: RLE packet exceeds image pixel count")
    }

    if packet_type == 1 {
      // RLE packet: repeat the next pixel `count` times
      if pos + src_bpp > self.data.length() {
        raise Failure::Failure("TGA: truncated RLE pixel data")
      }
      let pixel_data = self.data[pos:pos + src_bpp].to_owned()
      for _i = 0; _i < count; _i = _i + 1 {
        // Map file row to output row (file may be bottom-to-top)
        let dst_y = self.src_row(cur_y)
        let dst_pixel_offset = (dst_y * self.width + cur_x) * out_bpp
        write_tga_pixel(_buf, dst_pixel_offset, pixel_data, 0, self.pixel_depth)
        // Advance file-order position: increment x, wrap to next row
        cur_x = cur_x + 1
        if cur_x >= self.width {
          cur_x = 0
          cur_y = cur_y + 1
        }
      }
      pos = pos + src_bpp
    } else {
      // Raw packet: read `count` pixels literally
      for _i = 0; _i < count; _i = _i + 1 {
        if pos + src_bpp > self.data.length() {
          raise Failure::Failure("TGA: truncated raw pixel data")
        }
        // Map file row to output row
        let dst_y = self.src_row(cur_y)
        let dst_pixel_offset = (dst_y * self.width + cur_x) * out_bpp
        write_tga_pixel(
          _buf,
          dst_pixel_offset,
          self.data,
          pos,
          self.pixel_depth,
        )
        pos = pos + src_bpp
        // Advance file-order position: increment x, wrap to next row
        cur_x = cur_x + 1
        if cur_x >= self.width {
          cur_x = 0
          cur_y = cur_y + 1
        }
      }
    }
    pixels_done = pixels_done + count
  }

  let format = if out_bpp == 1 {
    PixelFormat::Gray8
  } else {
    PixelFormat::RGBA8
  }
  Image::new(self.width, self.height, format, Bytes::from_array(_buf))
}

///|
/// Write a single pixel from TGA source data to output buffer
/// Callers (decode_rle / decode_uncompressed) validate bounds at packet/row level,
/// so per-pixel bounds check is redundant and omitted here
fn write_tga_pixel(
  _buf : Array[Byte],
  dst_offset : Int,
  src : Bytes,
  src_offset : Int,
  pixel_depth : Int,
) -> Unit {
  if pixel_depth == 8 {
    _buf[dst_offset] = src[src_offset]
  } else if pixel_depth == 16 {
    let lo = src[src_offset].to_int()
    let hi = src[src_offset + 1].to_int()
    let val = lo | (hi << 8)
    let r = ((val >> 10) & 0x1F) * 255 / 31
    let g = ((val >> 5) & 0x1F) * 255 / 31
    let b = (val & 0x1F) * 255 / 31
    let a = if val >> 15 != 0 { 255 } else { 0 }
    _buf[dst_offset] = r.to_byte()
    _buf[dst_offset + 1] = g.to_byte()
    _buf[dst_offset + 2] = b.to_byte()
    _buf[dst_offset + 3] = a.to_byte()
  } else if pixel_depth == 24 {
    _buf[dst_offset] = src[src_offset + 2] // R
    _buf[dst_offset + 1] = src[src_offset + 1] // G
    _buf[dst_offset + 2] = src[src_offset] // B
    _buf[dst_offset + 3] = b'\xFF' // A
  } else {
    // 32-bit BGRA → RGBA
    _buf[dst_offset] = src[src_offset + 2] // R
    _buf[dst_offset + 1] = src[src_offset + 1] // G
    _buf[dst_offset + 2] = src[src_offset] // B
    _buf[dst_offset + 3] = src[src_offset + 3] // A
  }
  ()
}
