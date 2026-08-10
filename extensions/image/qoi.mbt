// Copyright (c) 2025 lws
// QOI (Quite OK Image Format) decoder
//
// QOI is a fast, lossless image compression format.
// Specification: https://qoiformat.org/

// QOI chunk types (identified by high bits of first byte)

///|
const QOI_OP_RGB : Int = 0xFE // 11111110

///|
const QOI_OP_RGBA : Int = 0xFF // 11111111

///|
const QOI_OP_INDEX : Int = 0x00 // 00xxxxxx

///|
const QOI_OP_DIFF : Int = 0x40 // 01xxxxxx

///|
const QOI_OP_LUMA : Int = 0x80 // 10xxxxxx

///|
/// Decode a QOI image from raw bytes
pub fn decode_qoi(data : Bytes) -> Image raise Failure {
  let decoder = QoiDecoder::new(data)
  decoder.decode()
}

///|
/// QOI decoder state
priv struct QoiDecoder {
  data : Bytes
  pos : Int
  width : Int
  height : Int
}

///|
fn QoiDecoder::new(data : Bytes) -> QoiDecoder raise Failure {
  // Check minimum size: header (14) + end marker (8)
  if data.length() < 22 {
    raise Failure::Failure("QOI: file too small")
  }
  // Verify magic bytes: "qoif"
  if data[0] != b'q' || data[1] != b'o' || data[2] != b'i' || data[3] != b'f' {
    raise Failure::Failure("QOI: invalid magic bytes, expected 'qoif'")
  }
  let width = read_u32_be(data, 4)
  let height = read_u32_be(data, 8)
  let channels = data[12].to_int()
  let colorspace = data[13].to_int()

  if width <= 0 || height <= 0 {
    raise Failure::Failure("QOI: invalid dimensions")
  }
  if channels != 3 && channels != 4 {
    raise Failure::Failure("QOI: unsupported channel count: \{channels}")
  }
  if colorspace != 0 && colorspace != 1 {
    raise Failure::Failure("QOI: invalid colorspace value")
  }

  { data, pos: 14, width, height }
}

///|
fn QoiDecoder::decode(self : QoiDecoder) -> Image raise Failure {
  let pixel_count = self.width * self.height
  let out_size = pixel_count * 4 // Always output RGBA8
  let _pixels = Array::make(out_size, Byte::default())
  let mut pixel_idx = 0

  // Color state
  let mut r = 0
  let mut g = 0
  let mut b = 0
  let mut a = 255

  // Previously seen pixel cache (64 entries, stored as 4 separate arrays
  // to avoid per-pixel Color::new() allocation and struct field access)
  let seen_r = Array::make(64, 0)
  let seen_g = Array::make(64, 0)
  let seen_b = Array::make(64, 0)
  let seen_a = Array::make(64, 255)

  let mut pos = self.pos

  while pixel_idx < pixel_count {
    if pos >= self.data.length() {
      raise Failure::Failure("QOI: unexpected end of chunk data")
    }
    let byte_val = self.data[pos].to_int()
    pos = pos + 1

    // Determine chunk type by high bits
    if byte_val == QOI_OP_RGB {
      // 8-bit RGB chunk: R, G, B follow
      if pos + 2 >= self.data.length() {
        raise Failure::Failure("QOI: truncated RGB chunk")
      }
      r = self.data[pos].to_int()
      g = self.data[pos + 1].to_int()
      b = self.data[pos + 2].to_int()
      pos = pos + 3
    } else if byte_val == QOI_OP_RGBA {
      // 8-bit RGBA chunk: R, G, B, A follow
      if pos + 3 >= self.data.length() {
        raise Failure::Failure("QOI: truncated RGBA chunk")
      }
      r = self.data[pos].to_int()
      g = self.data[pos + 1].to_int()
      b = self.data[pos + 2].to_int()
      a = self.data[pos + 3].to_int()
      pos = pos + 4
    } else if (byte_val & 0xC0) == QOI_OP_INDEX {
      // Index chunk: look up previously seen color
      let idx = byte_val & 0x3F
      r = seen_r[idx]
      g = seen_g[idx]
      b = seen_b[idx]
      a = seen_a[idx]
    } else if (byte_val & 0xC0) == QOI_OP_DIFF {
      // Difference chunk: small delta from previous pixel
      let dr = ((byte_val >> 4) & 0x03) - 2
      let dg = ((byte_val >> 2) & 0x03) - 2
      let db = (byte_val & 0x03) - 2
      r = (r + dr) & 0xFF
      g = (g + dg) & 0xFF
      b = (b + db) & 0xFF
    } else if (byte_val & 0xC0) == QOI_OP_LUMA {
      // Luma chunk: green diff + luma-adjusted red/blue diff
      if pos >= self.data.length() {
        raise Failure::Failure("QOI: truncated LUMA chunk")
      }
      let byte2 = self.data[pos].to_int()
      pos = pos + 1
      let dg = (byte_val & 0x3F) - 32
      let dr_dg = ((byte2 >> 4) & 0x0F) - 8
      let db_dg = (byte2 & 0x0F) - 8
      let dr = dr_dg + dg
      let db = db_dg + dg
      r = (r + dr) & 0xFF
      g = (g + dg) & 0xFF
      b = (b + db) & 0xFF
    } else {
      // QOI_OP_RUN chunk: repeat previous pixel
      let run = (byte_val & 0x3F) + 1
      if run < 1 || run > 62 {
        raise Failure::Failure("QOI: invalid run length: \{run}")
      }
      for _i = 0; _i < run; _i = _i + 1 {
        if pixel_idx >= pixel_count {
          break
        }
        let out_offset = pixel_idx * 4
        _pixels[out_offset] = r.to_byte()
        _pixels[out_offset + 1] = g.to_byte()
        _pixels[out_offset + 2] = b.to_byte()
        _pixels[out_offset + 3] = a.to_byte()
        pixel_idx = pixel_idx + 1
      }
      // Update seen cache and continue (already wrote pixels)
      let hash = qoi_hash(r, g, b, a)
      seen_r[hash] = r
      seen_g[hash] = g
      seen_b[hash] = b
      seen_a[hash] = a
      continue
    }

    // Write current pixel
    let out_offset = pixel_idx * 4
    _pixels[out_offset] = r.to_byte()
    _pixels[out_offset + 1] = g.to_byte()
    _pixels[out_offset + 2] = b.to_byte()
    _pixels[out_offset + 3] = a.to_byte()
    pixel_idx = pixel_idx + 1

    // Update seen cache
    let hash = qoi_hash(r, g, b, a)
    seen_r[hash] = r
    seen_g[hash] = g
    seen_b[hash] = b
    seen_a[hash] = a
  }

  Image::new(
    self.width,
    self.height,
    PixelFormat::RGBA8,
    Bytes::from_array(_pixels),
  )
}

///|
/// QOI color hash function: (r*3 + g*5 + b*7 + a*11) % 64
fn qoi_hash(r : Int, g : Int, b : Int, a : Int) -> Int {
  (r * 3 + g * 5 + b * 7 + a * 11) % 64
}
