// Copyright (c) 2025 lws
// QOI (Quite OK Image Format) encoder
//
// QOI is a fast, lossless image compression format.
// Specification: https://qoiformat.org/
//
// Uses QOI_OP_* constants and qoi_hash from qoi.mbt (same package).

///|
const QOI_OP_RUN : Int = 0xC0 // 11xxxxxx

///|
/// Encode an image to QOI (Quite OK Image) format.
/// Returns the encoded bytes ready to write to a file.
pub fn encode_qoi(image : Image) -> Bytes raise Failure {
  // Validate dimensions
  if image.width <= 0 || image.height <= 0 {
    raise Failure::Failure(
      "QOI: invalid image dimensions: \{image.width}x\{image.height}",
    )
  }

  // Convert to RGBA8 for uniform pixel processing
  let rgba = image.to_rgba8()
  let pixel_count = rgba.width * rgba.height

  // Determine channel count: 3 if all pixels are fully opaque, else 4
  let has_alpha = check_non_opaque_alpha(rgba)
  let channels : Int = if has_alpha { 4 } else { 3 }

  // Allocate worst-case output buffer:
  // header (14) + max per-pixel data (pixel_count * 5) + end marker (8)
  let max_size = 14 + pixel_count * 5 + 8
  let buf = Array::make(max_size, b'\x00')
  let mut pos = 0

  // ---- Header (14 bytes) ----
  // Magic bytes "qoif"
  buf[pos] = b'q'
  pos = pos + 1
  buf[pos] = b'o'
  pos = pos + 1
  buf[pos] = b'i'
  pos = pos + 1
  buf[pos] = b'f'
  pos = pos + 1

  // Width (big-endian u32)
  write_u32_be_buf(buf, pos, rgba.width)
  pos = pos + 4

  // Height (big-endian u32)
  write_u32_be_buf(buf, pos, rgba.height)
  pos = pos + 4

  // Channels (3 = RGB, 4 = RGBA)
  buf[pos] = channels.to_byte()
  pos = pos + 1

  // Colorspace (0 = sRGB with linear alpha)
  buf[pos] = b'\x00'
  pos = pos + 1

  // ---- Encode pixels ----
  // Previous pixel state (initial: r=0 g=0 b=0 a=255 per QOI spec)
  let mut prev_r = 0
  let mut prev_g = 0
  let mut prev_b = 0
  let mut prev_a = 255

  // Previously seen pixel cache (64 entries, stored as 4 separate arrays
  // to avoid per-pixel Color::new() allocation and struct field access)
  let seen_r = Array::make(64, 0)
  let seen_g = Array::make(64, 0)
  let seen_b = Array::make(64, 0)
  let seen_a = Array::make(64, 255)

  let mut run = 0
  let data = rgba.data

  for i = 0; i < pixel_count; i = i + 1 {
    let offset = i * 4
    let r = data[offset].to_int()
    let g = data[offset + 1].to_int()
    let b = data[offset + 2].to_int()
    let a = data[offset + 3].to_int()

    if r == prev_r && g == prev_g && b == prev_b && a == prev_a {
      // Same as previous pixel: accumulate run length
      run = run + 1
      if run == 62 {
        // Max run length (62) reached, emit RUN chunk and reset
        let run_byte : Int = QOI_OP_RUN | (run - 1)
        buf[pos] = run_byte.to_byte()
        pos = pos + 1
        run = 0
      }
    } else {
      // Pixel changed: flush any pending run before encoding the new pixel
      if run > 0 {
        let run_byte : Int = QOI_OP_RUN | (run - 1)
        buf[pos] = run_byte.to_byte()
        pos = pos + 1
        run = 0
      }

      // Try INDEX encoding first (look up in seen cache)
      let index = qoi_hash(r, g, b, a)
      if seen_r[index] == r &&
        seen_g[index] == g &&
        seen_b[index] == b &&
        seen_a[index] == a {
        buf[pos] = (QOI_OP_INDEX | index).to_byte()
        pos = pos + 1
      } else {
        // Update seen cache with the new pixel value
        seen_r[index] = r
        seen_g[index] = g
        seen_b[index] = b
        seen_a[index] = a

        if a == prev_a {
          // Alpha unchanged: try DIFF, then LUMA, then RGB
          let dr = r - prev_r
          let dg = g - prev_g
          let db = b - prev_b
          let dr_dg = dr - dg
          let db_dg = db - dg

          if dr >= -2 && dr <= 1 && dg >= -2 && dg <= 1 && db >= -2 && db <= 1 {
            // DIFF encoding: 1 byte
            // dr, dg, db are in [-2, 1], stored as biased values (+2)
            let byte_val : Int = QOI_OP_DIFF |
              ((dr + 2) << 4) |
              ((dg + 2) << 2) |
              (db + 2)
            buf[pos] = byte_val.to_byte()
            pos = pos + 1
          } else if dg >= -32 &&
            dg <= 31 &&
            dr_dg >= -8 &&
            dr_dg <= 7 &&
            db_dg >= -8 &&
            db_dg <= 7 {
            // LUMA encoding: 2 bytes
            // dg in [-32, 31] stored as biased (+32)
            let byte1 : Int = QOI_OP_LUMA | (dg + 32)
            buf[pos] = byte1.to_byte()
            pos = pos + 1
            // dr_dg in [-8, 7] stored as biased (+8) in upper 4 bits
            // db_dg in [-8, 7] stored as biased (+8) in lower 4 bits
            let byte2 : Int = ((dr_dg + 8) << 4) | (db_dg + 8)
            buf[pos] = byte2.to_byte()
            pos = pos + 1
          } else {
            // RGB encoding: 4 bytes (tag 0xFE + R + G + B)
            buf[pos] = b'\xFE'
            pos = pos + 1
            buf[pos] = r.to_byte()
            pos = pos + 1
            buf[pos] = g.to_byte()
            pos = pos + 1
            buf[pos] = b.to_byte()
            pos = pos + 1
          }
        } else {
          // Alpha changed: use RGBA encoding
          // 5 bytes: tag 0xFF + R + G + B + A
          buf[pos] = b'\xFF'
          pos = pos + 1
          buf[pos] = r.to_byte()
          pos = pos + 1
          buf[pos] = g.to_byte()
          pos = pos + 1
          buf[pos] = b.to_byte()
          pos = pos + 1
          buf[pos] = a.to_byte()
          pos = pos + 1
        }
      }

      // Update previous pixel state for next comparison
      prev_r = r
      prev_g = g
      prev_b = b
      prev_a = a
    }
  }

  // Flush any remaining run after the last pixel
  if run > 0 {
    let run_byte : Int = QOI_OP_RUN | (run - 1)
    buf[pos] = run_byte.to_byte()
    pos = pos + 1
  }

  // ---- End marker: 7 bytes of 0x00 followed by 1 byte of 0x01 ----
  for i = 0; i < 7; i = i + 1 {
    buf[pos] = b'\x00'
    pos = pos + 1
  }
  buf[pos] = b'\x01'
  pos = pos + 1

  // Copy to exact-size output array and convert to Bytes
  let output = Array::make(pos, b'\x00')
  for i = 0; i < pos; i = i + 1 {
    output[i] = buf[i]
  }
  Bytes::from_array(output)
}

///|
/// Check whether any pixel in a RGBA8 image has a non-255 alpha value.
/// Used to decide between channels=3 (all opaque) and channels=4 (has transparency).
fn check_non_opaque_alpha(image : Image) -> Bool {
  let pixel_count = image.width * image.height
  let mut found = false
  for i = 0; i < pixel_count; i = i + 1 {
    if image.data[i * 4 + 3] != b'\xFF' {
      found = true
      break
    }
  }
  found
}

///|
/// Write a 32-bit unsigned integer in big-endian byte order into a buffer array.
fn write_u32_be_buf(buf : Array[Byte], pos : Int, value : Int) -> Unit {
  buf[pos] = ((value >> 24) & 0xFF).to_byte()
  buf[pos + 1] = ((value >> 16) & 0xFF).to_byte()
  buf[pos + 2] = ((value >> 8) & 0xFF).to_byte()
  buf[pos + 3] = (value & 0xFF).to_byte()
}
