// Copyright (c) 2025 lws
// Image decoding library for MoonBit - Core types

//-----------------------------------------------------------------------------
// PixelFormat - Supported pixel layouts
//-----------------------------------------------------------------------------

///|
/// All pixel formats supported by this library
pub enum PixelFormat {
  /// 8-bit grayscale (1 byte per pixel)
  Gray8
  /// 16-bit grayscale with alpha (2 bytes per pixel)
  GrayA8
  /// 24-bit RGB (3 bytes per pixel, R, G, B)
  RGB8
  /// 32-bit RGBA (4 bytes per pixel, R, G, B, A)
  RGBA8
}

//-----------------------------------------------------------------------------
// ImageFormat - Supported file formats
//-----------------------------------------------------------------------------

///|
/// Image file formats that can be detected and decoded
pub enum ImageFormat {
  BMP
  QOI
  TGA
  PNG
  GIF
  JPEG
}

//-----------------------------------------------------------------------------
// Color - A single pixel color value
//-----------------------------------------------------------------------------

///|
/// A color represented as 8-bit RGBA components
pub struct Color {
  r : Int
  g : Int
  b : Int
  a : Int
}

///|
/// Constructors and utilities for Color
pub fn Color::default() -> Color {
  { r: 0, g: 0, b: 0, a: 255 }
}

///|
pub fn Color::new(r : Int, g : Int, b : Int, a : Int) -> Color {
  { r, g, b, a }
}

///|
pub fn Color::from_rgb(r : Int, g : Int, b : Int) -> Color {
  { r, g, b, a: 255 }
}

///|
pub fn Color::from_gray(v : Int) -> Color {
  { r: v, g: v, b: v, a: 255 }
}

///|
pub fn Color::with_alpha(self : Color, a : Int) -> Color {
  { r: self.r, g: self.g, b: self.b, a }
}

///|
pub fn Color::to_gray(self : Color) -> Int {
  // ITU-R BT.601 luma
  (self.r * 299 + self.g * 587 + self.b * 114) / 1000
}

//-----------------------------------------------------------------------------
// Image - The main image data structure
//-----------------------------------------------------------------------------

///|
/// A decoded image with pixel data
pub struct Image {
  /// Image width in pixels
  width : Int
  /// Image height in pixels
  height : Int
  /// Pixel format describing the data layout
  format : PixelFormat
  /// Raw pixel data, row-major order (top to bottom)
  data : Bytes
}

///|
pub fn Image::new(
  width : Int,
  height : Int,
  format : PixelFormat,
  data : Bytes,
) -> Image {
  { width, height, format, data }
}

///|
/// Number of bytes per pixel for this format
pub fn Image::bytes_per_pixel(self : Image) -> Int {
  match self.format {
    PixelFormat::Gray8 => 1
    PixelFormat::GrayA8 => 2
    PixelFormat::RGB8 => 3
    PixelFormat::RGBA8 => 4
  }
}

///|
/// Number of bytes per row (stride) for this image
pub fn Image::stride(self : Image) -> Int {
  self.width * self.bytes_per_pixel()
}

///|
/// Total size of pixel data in bytes
pub fn Image::data_size(self : Image) -> Int {
  self.stride() * self.height
}

///|
/// Get the color at a specific pixel coordinate
pub fn Image::get_pixel(self : Image, x : Int, y : Int) -> Color {
  let offset = y * self.stride() + x * self.bytes_per_pixel()
  match self.format {
    PixelFormat::Gray8 => {
      let v = self.data[offset].to_int()
      Color::from_gray(v)
    }
    PixelFormat::GrayA8 => {
      let v = self.data[offset].to_int()
      let a = self.data[offset + 1].to_int()
      Color::from_gray(v).with_alpha(a)
    }
    PixelFormat::RGB8 => {
      let r = self.data[offset].to_int()
      let g = self.data[offset + 1].to_int()
      let b = self.data[offset + 2].to_int()
      Color::new(r, g, b, 255)
    }
    PixelFormat::RGBA8 => {
      let r = self.data[offset].to_int()
      let g = self.data[offset + 1].to_int()
      let b = self.data[offset + 2].to_int()
      let a = self.data[offset + 3].to_int()
      Color::new(r, g, b, a)
    }
  }
}

///|
/// Convert this image to RGBA8 format (always 4 bytes per pixel)
/// Uses per-format bulk loops for performance (avoids per-pixel match dispatch)
pub fn Image::to_rgba8(self : Image) -> Image {
  match self.format {
    PixelFormat::RGBA8 => return self
    _ => ()
  }
  let pixel_count = self.width * self.height
  let out_size = pixel_count * 4
  let _buf = Array::make(out_size, b'\x00')

  match self.format {
    PixelFormat::Gray8 =>
      for i = 0; i < pixel_count; i = i + 1 {
        let v = self.data[i].to_int()
        let dst = i * 4
        _buf[dst] = v.to_byte()
        _buf[dst + 1] = v.to_byte()
        _buf[dst + 2] = v.to_byte()
        _buf[dst + 3] = b'\xFF'
      }
    PixelFormat::GrayA8 =>
      for i = 0; i < pixel_count; i = i + 1 {
        let src = i * 2
        let v = self.data[src].to_int()
        let a = self.data[src + 1]
        let dst = i * 4
        _buf[dst] = v.to_byte()
        _buf[dst + 1] = v.to_byte()
        _buf[dst + 2] = v.to_byte()
        _buf[dst + 3] = a
      }
    PixelFormat::RGB8 =>
      for i = 0; i < pixel_count; i = i + 1 {
        let src = i * 3
        let dst = i * 4
        _buf[dst] = self.data[src]
        _buf[dst + 1] = self.data[src + 1]
        _buf[dst + 2] = self.data[src + 2]
        _buf[dst + 3] = b'\xFF'
      }
    _ =>
      // Fallback: per-pixel conversion (should not reach here since RGBA8 is early-returned)
      for y = 0; y < self.height; y = y + 1 {
        for x = 0; x < self.width; x = x + 1 {
          let c = self.get_pixel(x, y)
          let offset = (y * self.width + x) * 4
          _buf[offset] = c.r.to_byte()
          _buf[offset + 1] = c.g.to_byte()
          _buf[offset + 2] = c.b.to_byte()
          _buf[offset + 3] = c.a.to_byte()
        }
      }
  }
  Image::new(
    self.width,
    self.height,
    PixelFormat::RGBA8,
    Bytes::from_array(_buf),
  )
}

//-----------------------------------------------------------------------------
// AnimatedImage - Multi-frame image (e.g., animated GIF)
//-----------------------------------------------------------------------------

///|
/// A multi-frame animated image with per-frame delay timing
pub struct AnimatedImage {
  /// Array of decoded frames
  frames : Array[Image]
  /// Delay for each frame in centiseconds (1/100 second)
  delays : Array[Int]
  /// Canvas width in pixels
  width : Int
  /// Canvas height in pixels
  height : Int
  /// Number of times to loop (0 = infinite)
  loop_count : Int
}

///|
pub fn AnimatedImage::new(
  frames : Array[Image],
  delays : Array[Int],
  width : Int,
  height : Int,
  loop_count : Int,
) -> AnimatedImage {
  { frames, delays, width, height, loop_count }
}

///|
pub fn AnimatedImage::frame_count(self : AnimatedImage) -> Int {
  self.frames.length()
}

//-----------------------------------------------------------------------------
// BitReader - Bit-level reading from Bytes
//-----------------------------------------------------------------------------

///|
/// Bit reader for DEFLATE (RFC 1951) bit-stream format
/// Reads bits LSB-first (least significant bit first) as required by DEFLATE
priv struct BitReader {
  data : Bytes
  byte_pos : Int
  bit_pos : Int // 0 = LSB, 7 = MSB (next bit to read)
}

///|
fn BitReader::new(data : Bytes) -> BitReader {
  { data, byte_pos: 0, bit_pos: 0 }
}

///|
/// Read n bits as an integer, up to 16 bits, in LSB-first order
/// First bit read becomes the least significant bit of the result
fn BitReader::read_bits(
  self : BitReader,
  n : Int,
) -> (BitReader, Int) raise Failure {
  if n == 0 {
    return (self, 0)
  }
  if n > 16 {
    raise Failure::Failure("BitReader: cannot read more than 16 bits at once")
  }

  let mut reader = self
  let mut result = 0
  let mut needed = n
  let mut result_pos = 0 // position where next bits go in result

  // Read remaining bits from current partial byte first (LSBs of result)
  if reader.bit_pos != 0 {
    let bits_left = 8 - reader.bit_pos
    let take = if needed < bits_left { needed } else { bits_left }
    if reader.byte_pos >= reader.data.length() {
      raise Failure::Failure(
        "BitReader: unexpected end of data while reading bits",
      )
    }
    let byte = reader.data[reader.byte_pos].to_int()
    // Read bits [bit_pos .. bit_pos+take-1] from the byte (LSB-first)
    let val = (byte >> reader.bit_pos) & ((1 << take) - 1)
    result = result | (val << result_pos)
    result_pos = result_pos + take
    needed = needed - take
    if take == bits_left {
      reader = { data: reader.data, byte_pos: reader.byte_pos + 1, bit_pos: 0 }
    } else {
      reader = {
        data: reader.data,
        byte_pos: reader.byte_pos,
        bit_pos: reader.bit_pos + take,
      }
    }
    if needed == 0 {
      return (reader, result)
    }
  }

  // Read full bytes (8 bits each, LSB-first)
  while needed >= 8 {
    if reader.byte_pos >= reader.data.length() {
      raise Failure::Failure(
        "BitReader: unexpected end of data while reading bits",
      )
    }
    let byte_val = reader.data[reader.byte_pos].to_int()
    result = result | (byte_val << result_pos)
    result_pos = result_pos + 8
    needed = needed - 8
    reader = { data: reader.data, byte_pos: reader.byte_pos + 1, bit_pos: 0 }
  }

  // Read remaining bits from next byte (LSBs of that byte)
  if needed > 0 {
    if reader.byte_pos >= reader.data.length() {
      raise Failure::Failure(
        "BitReader: unexpected end of data while reading bits",
      )
    }
    let byte = reader.data[reader.byte_pos].to_int()
    let val = byte & ((1 << needed) - 1)
    result = result | (val << result_pos)
    reader = { data: reader.data, byte_pos: reader.byte_pos, bit_pos: needed }
  }

  (reader, result)
}

///|
/// Align to the next byte boundary
fn BitReader::align_to_byte(self : BitReader) -> BitReader {
  if self.bit_pos == 0 {
    self
  } else {
    { data: self.data, byte_pos: self.byte_pos + 1, bit_pos: 0 }
  }
}

///|
/// Read raw bytes from current byte position (must be byte-aligned)
fn BitReader::read_bytes(
  self : BitReader,
  n : Int,
) -> (BitReader, Bytes) raise Failure {
  if self.bit_pos != 0 {
    raise Failure::Failure("BitReader: cannot read bytes when not byte-aligned")
  }
  if self.byte_pos + n > self.data.length() {
    raise Failure::Failure("BitReader: unexpected end of data")
  }
  let slice = self.data[self.byte_pos:self.byte_pos + n].to_owned()
  let new_reader = { data: self.data, byte_pos: self.byte_pos + n, bit_pos: 0 }
  (new_reader, slice)
}
