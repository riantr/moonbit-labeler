// Copyright (c) 2025 lws
// GIF (Graphics Interchange Format) decoder
//
// Supports GIF87a and GIF89a formats with:
//   - LZW decompression with variable-length codes (up to 12 bits)
//   - Global and local color tables
//   - 4-pass interlacing
//   - Transparency via Graphic Control Extension
//   - Single-frame decoding (returns first image)
//
// Performance optimizations:
//   - LZW state inlined into mutable locals (no per-code struct allocation)
//   - Color tables pre-computed as RGBA byte quads (no per-pixel .to_byte())
//   - Non-interlaced fast path (no row_map indirection)
//   - Stack array allocated once and reused
//   - Bulk byte reading when bit-aligned

//-----------------------------------------------------------------------------
// LZW Decompressor for GIF (inlined, zero struct allocation)
//-----------------------------------------------------------------------------

///|
/// Decode LZW stream into raw pixel indices
/// Uses mutable locals for LZW state to eliminate struct allocation overhead.
/// For a 256x256 image, this avoids ~65,000 struct allocations.
fn lzw_decompress(
  data : Bytes,
  min_code_size : Int,
  pixel_count : Int,
) -> Array[Byte] raise Failure {
  // LZW constants
  let max_table = 4096
  let clear_code = 1 << min_code_size
  let eoi_code = clear_code + 1

  // String table (mutated in place)
  let table_prefix = Array::make(max_table, 0)
  let table_suffix = Array::make(max_table, 0)

  // Decode stack reused across all calls (sized to max possible depth)
  let stack = Array::make(max_table, b'\x00')

  // Mutable LZW state (was LzwDecoder struct)
  let mut pos : Int = 0
  let mut bit_pos : Int = 0
  let mut code_size : Int = min_code_size + 1
  let mut next_code : Int = eoi_code + 1
  let mut max_code : Int = (1 << code_size) - 1

  let pixels = Array::make(pixel_count, b'\x00')
  let mut pi = 0

  // --- read first code ---
  let (p1, bp1, code1) = lzw_read_code(data, pos, bit_pos, code_size)
  pos = p1
  bit_pos = bp1

  if code1 == eoi_code {
    return pixels
  }

  if code1 == clear_code {
    // Reset and read next as root
    next_code = eoi_code + 1
    code_size = min_code_size + 1
    max_code = (1 << code_size) - 1
    let (p2, bp2, code2) = lzw_read_code(data, pos, bit_pos, code_size)
    pos = p2
    bit_pos = bp2
    if code2 == eoi_code {
      return pixels
    }
    if pi < pixel_count {
      pixels[pi] = code2.to_byte()
      pi = pi + 1
    }
    let mut prev : Int = code2

    while pi < pixel_count {
      let (p3, bp3, code3) = lzw_read_code(data, pos, bit_pos, code_size)
      pos = p3
      bit_pos = bp3

      if code3 == eoi_code {
        break
      }

      if code3 == clear_code {
        // Reset table
        next_code = eoi_code + 1
        code_size = min_code_size + 1
        max_code = (1 << code_size) - 1
        let (p4, bp4, code4) = lzw_read_code(data, pos, bit_pos, code_size)
        pos = p4
        bit_pos = bp4
        if code4 == eoi_code {
          break
        }
        if pi < pixel_count {
          pixels[pi] = code4.to_byte()
          pi = pi + 1
        }
        prev = code4
        continue
      }

      // decode_and_add inlined
      let (cs5, nc5, mc5, out_len) = lzw_decode_string(
        table_prefix, table_suffix, stack, code3, prev, eoi_code, code_size, next_code,
        max_code,
      )
      code_size = cs5
      next_code = nc5
      max_code = mc5

      // Copy from stack (which now contains output in reverse) to pixels
      for i = 0; i < out_len && pi < pixel_count; i = i + 1 {
        pixels[pi] = stack[out_len - 1 - i]
        pi = pi + 1
      }

      prev = code3
    }
    return pixels
  }

  // Normal path: first code is a root code
  if pi < pixel_count {
    pixels[pi] = code1.to_byte()
    pi = pi + 1
  }
  let mut prev : Int = code1

  // --- main decode loop ---
  while pi < pixel_count {
    let (p2, bp2, code2) = lzw_read_code(data, pos, bit_pos, code_size)
    pos = p2
    bit_pos = bp2

    if code2 == eoi_code {
      break
    }

    if code2 == clear_code {
      // Reset table
      next_code = eoi_code + 1
      code_size = min_code_size + 1
      max_code = (1 << code_size) - 1
      let (p3, bp3, code3) = lzw_read_code(data, pos, bit_pos, code_size)
      pos = p3
      bit_pos = bp3
      if code3 == eoi_code {
        break
      }
      if pi < pixel_count {
        pixels[pi] = code3.to_byte()
        pi = pi + 1
      }
      prev = code3
      continue
    }

    // decode_and_add inlined
    let (cs3, nc3, mc3, out_len) = lzw_decode_string(
      table_prefix, table_suffix, stack, code2, prev, eoi_code, code_size, next_code,
      max_code,
    )
    code_size = cs3
    next_code = nc3
    max_code = mc3

    // Copy from stack (output in reverse order) to pixels
    for i = 0; i < out_len && pi < pixel_count; i = i + 1 {
      pixels[pi] = stack[out_len - 1 - i]
      pi = pi + 1
    }

    prev = code2
  }

  pixels
}

///|
/// Read the next variable-length code from the LZW bitstream (LSB-first).
/// Returns (new_pos, new_bit_pos, code).
/// Uses bulk byte reading when byte-aligned for codes >= 8 bits.
fn lzw_read_code(
  data : Bytes,
  pos : Int,
  bit_pos : Int,
  code_size : Int,
) -> (Int, Int, Int) raise Failure {
  let mut byte_pos = pos
  let mut bp = bit_pos
  let mut result = 0
  let mut bit_count = 0

  // Fast path: byte-aligned and reading 8+ bits -> read two bytes at once
  if bp == 0 && code_size >= 8 && byte_pos + 1 < data.length() {
    let lo = data[byte_pos].to_int()
    let hi = data[byte_pos + 1].to_int()
    let word = lo | (hi << 8)
    result = word & ((1 << code_size) - 1)
    let bits_read = if code_size <= 16 { code_size } else { 16 }
    byte_pos = byte_pos + bits_read / 8
    bp = bits_read % 8
    return (byte_pos, bp, result)
  }

  // General path: bit-by-bit
  while bit_count < code_size {
    if byte_pos >= data.length() {
      raise Failure::Failure("GIF: unexpected end of LZW data")
    }
    let byte = data[byte_pos].to_int()
    let bits_left = 8 - bp
    let needed = code_size - bit_count
    let take = if needed < bits_left { needed } else { bits_left }
    let val = (byte >> bp) & ((1 << take) - 1)
    result = result | (val << bit_count)
    bit_count = bit_count + take
    if take == bits_left {
      byte_pos = byte_pos + 1
      bp = 0
    } else {
      bp = bp + take
    }
  }

  (byte_pos, bp, result)
}

///|
/// Decode a single LZW code's output string, building it on the stack.
/// Returns (new_code_size, new_next_code, new_max_code, output_length).
/// The output is placed on `stack` in reverse order (pop from end to get forward order).
/// This function handles both the normal case and the KwKwK edge case correctly:
/// when `code == next_code`, output = string(prev_code) + first_char(string(prev_code)).
fn lzw_decode_string(
  table_prefix : Array[Int],
  table_suffix : Array[Int],
  stack : Array[Byte],
  code : Int,
  prev_code : Int,
  eoi_code : Int,
  code_size : Int,
  next_code : Int,
  max_code : Int,
) -> (Int, Int, Int, Int) raise Failure {
  let max_table = table_prefix.length()
  let mut c = code
  let mut sp = 0

  // KwKwK case: code not yet in table.
  // Output = string(prev_code) + first_char(string(prev_code)).
  // We must trace prev_code to find its first character, then push it.
  if c == next_code {
    // Find first character of prev_code's string by tracing to root
    let mut t = prev_code
    while t > eoi_code {
      if t >= max_table {
        raise Failure::Failure("GIF: invalid LZW prefix chain")
      }
      t = table_prefix[t]
    }
    stack[sp] = t.to_byte()
    sp = sp + 1
    c = prev_code
  }

  // Walk prefix chain: push suffix bytes onto stack
  while c > eoi_code {
    if c >= next_code || c >= max_table {
      raise Failure::Failure("GIF: invalid LZW code \{c}")
    }
    stack[sp] = table_suffix[c].to_byte()
    sp = sp + 1
    c = table_prefix[c]
  }
  // Root code (c <= eoi_code, the root value is the actual pixel index)
  stack[sp] = c.to_byte()
  sp = sp + 1

  // First byte of output (bottom of stack = first character of decoded string)
  let first = stack[sp - 1].to_int()

  // Add new entry: prev_code + first_byte
  let mut new_next = next_code
  let mut new_cs = code_size
  let mut new_max = max_code

  if next_code < max_table {
    table_prefix[next_code] = prev_code
    table_suffix[next_code] = first
    new_next = next_code + 1
    // Grow code size if needed
    if new_next > max_code && code_size < 12 {
      new_cs = code_size + 1
      new_max = (1 << new_cs) - 1
    }
  }

  (new_cs, new_next, new_max, sp)
}

//-----------------------------------------------------------------------------
// GIF Decoder
//-----------------------------------------------------------------------------

///|
/// Decode a GIF image from raw bytes (returns the first frame)
pub fn decode_gif(data : Bytes) -> Image raise Failure {
  let decoder = GifDecoder::new(data)
  decoder.decode()
}

///|
/// GIF decoder state
priv struct GifDecoder {
  data : Bytes
  pos : Int
  width : Int
  height : Int
  global_ct : Array[(Int, Int, Int)] // (R, G, B) tuples
  bg_color : Int
}

///|
fn GifDecoder::new(data : Bytes) -> GifDecoder raise Failure {
  // Check signature
  if data.length() < 13 {
    raise Failure::Failure("GIF: file too small")
  }

  // "GIF" signature
  if data[0] != b'G' || data[1] != b'I' || data[2] != b'F' {
    raise Failure::Failure("GIF: invalid signature")
  }

  // Version: "87a" or "89a"
  if data[3] != b'8' || (data[4] != b'7' && data[4] != b'9') || data[5] != b'a' {
    raise Failure::Failure("GIF: unsupported version")
  }

  // Logical Screen Descriptor
  let w = read_u16_le(data, 6)
  let h = read_u16_le(data, 8)
  let packed = data[10].to_int()
  let bg = data[11].to_int()
  let _aspect = data[12].to_int()

  if w <= 0 || h <= 0 {
    raise Failure::Failure("GIF: invalid dimensions")
  }

  let has_gct = packed >> 7 != 0
  let gct_size = 1 << ((packed & 7) + 1)

  // Read Global Color Table if present
  let mut gct = Array::make(0, (0, 0, 0))
  let mut pos = 13
  if has_gct {
    gct = Array::make(gct_size, (0, 0, 0))
    for i = 0; i < gct_size; i = i + 1 {
      let r = data[pos].to_int()
      let g = data[pos + 1].to_int()
      let b = data[pos + 2].to_int()
      gct[i] = (r, g, b)
      pos = pos + 3
    }
  }

  { data, pos, width: w, height: h, global_ct: gct, bg_color: bg }
}

///|
/// Read a sub-block chain (GIF data sub-blocks)
/// Each sub-block: 1-byte count (0-255) followed by count bytes of data
/// Terminated by a 0-byte count
fn read_sub_blocks(data : Bytes, start_pos : Int) -> (Bytes, Int) raise Failure {
  let buf = Buffer()
  let mut pos = start_pos
  while pos < data.length() {
    let count = data[pos].to_int()
    pos = pos + 1
    if count == 0 {
      break
    }
    if pos + count > data.length() {
      raise Failure::Failure("GIF: truncated sub-block")
    }
    buf.write_bytes(data[pos:pos + count].to_owned())
    pos = pos + count
  }
  (buf.to_bytes(), pos)
}

///|
/// Build interlace row mapping for 4-pass interlacing
/// Returns an array mapping source row index to destination row
fn build_interlace_map(img_h : Int) -> Array[Int] {
  let row_map = Array::make(img_h, 0)
  let mut ri = 0
  // Pass 1: every 8th row starting at 0
  let mut r = 0
  while r < img_h {
    row_map[ri] = r
    ri = ri + 1
    r = r + 8
  }
  // Pass 2: every 8th row starting at 4
  r = 4
  while r < img_h {
    row_map[ri] = r
    ri = ri + 1
    r = r + 8
  }
  // Pass 3: every 4th row starting at 2
  r = 2
  while r < img_h {
    row_map[ri] = r
    ri = ri + 1
    r = r + 4
  }
  // Pass 4: every 2nd row starting at 1
  r = 1
  while r < img_h {
    row_map[ri] = r
    ri = ri + 1
    r = r + 2
  }
  row_map
}

///|
/// Pre-compute color table as RGBA byte quads for fast pixel writes.
/// Converts (Int,Int,Int) tuples to [r_byte, g_byte, b_byte, a_byte] arrays,
/// eliminating per-pixel .to_byte() calls and tuple destructuring.
fn ct_to_rgba(ct : Array[(Int, Int, Int)]) -> Array[Array[Byte]] {
  let n = ct.length()
  let result = Array::make(n, [b'\x00', b'\x00', b'\x00', b'\xFF'])
  for i = 0; i < n; i = i + 1 {
    let (r, g, b) = ct[i]
    result[i] = [r.to_byte(), g.to_byte(), b.to_byte(), b'\xFF']
  }
  result
}

///|
/// Decode a single GIF frame (returns first frame found)
fn GifDecoder::decode(self : GifDecoder) -> Image raise Failure {
  let mut pos = self.pos

  // GCE state tracked as mutable locals
  let mut has_transparency = false
  let mut transparent_idx = -1
  let mut _delay = 0

  while pos < self.data.length() {
    let block_type = self.data[pos].to_int()
    pos = pos + 1

    // Extension block
    if block_type == 0x21 {
      if pos >= self.data.length() {
        raise Failure::Failure("GIF: truncated extension")
      }
      let ext_type = self.data[pos].to_int()
      pos = pos + 1

      if ext_type == 0xF9 {
        // Graphic Control Extension
        if pos + 5 > self.data.length() {
          raise Failure::Failure("GIF: truncated GCE")
        }
        let _block_size = self.data[pos].to_int() // should be 4
        pos = pos + 1
        let gce_packed = self.data[pos].to_int()
        pos = pos + 1
        _delay = read_u16_le(self.data, pos)
        pos = pos + 2
        let trans_idx = self.data[pos].to_int()
        pos = pos + 1
        let _term = self.data[pos].to_int() // block terminator 0x00
        pos = pos + 1

        has_transparency = (gce_packed & 1) != 0
        transparent_idx = if has_transparency { trans_idx } else { -1 }
      } else {
        // Skip other extensions (comment, plain text, application)
        let (_bs, np) = read_sub_blocks(self.data, pos)
        pos = np
      }
      continue
    }

    // Image Descriptor
    if block_type == 0x2C {
      // Parse image descriptor
      if pos + 9 > self.data.length() {
        raise Failure::Failure("GIF: truncated image descriptor")
      }
      let _img_left = read_u16_le(self.data, pos)
      let _img_top = read_u16_le(self.data, pos + 2)
      let img_w = read_u16_le(self.data, pos + 4)
      let img_h = read_u16_le(self.data, pos + 6)
      let img_packed = self.data[pos + 8].to_int()
      pos = pos + 9

      let has_lct = img_packed >> 7 != 0
      let is_interlaced = ((img_packed >> 6) & 1) != 0
      let lct_size = 1 << ((img_packed & 7) + 1)

      // Read Local Color Table if present
      let mut active_ct = self.global_ct
      if has_lct {
        active_ct = Array::make(lct_size, (0, 0, 0))
        for i = 0; i < lct_size; i = i + 1 {
          let r = self.data[pos].to_int()
          let g = self.data[pos + 1].to_int()
          let b = self.data[pos + 2].to_int()
          active_ct[i] = (r, g, b)
          pos = pos + 3
        }
      }

      // Pre-compute RGBA byte palette (eliminates per-pixel .to_byte() calls)
      let palette_rgba = ct_to_rgba(active_ct)
      let pal_len = palette_rgba.length()

      // Read LZW minimum code size
      if pos >= self.data.length() {
        raise Failure::Failure("GIF: no LZW code size")
      }
      let min_code_size = self.data[pos].to_int()
      if min_code_size < 2 {
        raise Failure::Failure("GIF: invalid LZW code size")
      }
      pos = pos + 1

      // Read sub-blocks containing LZW data
      let (lzw_data, np) = read_sub_blocks(self.data, pos)
      pos = np

      // Decompress LZW data
      let pixel_count = img_w * img_h
      let indices = lzw_decompress(lzw_data, min_code_size, pixel_count)

      // Build output image
      let out_w = self.width
      let out_h = self.height
      let out_size = out_w * out_h * 4
      let out = Array::make(out_size, b'\x00')

      if is_interlaced {
        // Interlaced path: build row_map and use indirect addressing
        let row_map = build_interlace_map(img_h)
        for src_row = 0; src_row < img_h; src_row = src_row + 1 {
          let dst_row = row_map[src_row]
          let src_base = src_row * img_w
          let dst_base = dst_row * out_w * 4
          for x = 0; x < img_w; x = x + 1 {
            let idx = indices[src_base + x].to_int()
            let di = dst_base + x * 4
            if has_transparency && idx == transparent_idx {
              // Transparent: alpha=0 (bytes already zero from init)
              continue
            }
            if idx < pal_len {
              let c = palette_rgba[idx]
              out[di] = c[0]
              out[di + 1] = c[1]
              out[di + 2] = c[2]
              out[di + 3] = c[3]
            } else {
              out[di + 3] = b'\xFF' // Opaque black for out-of-bounds
            }
          }
        }
      } else {
        // Non-interlaced fast path: no row_map indirection
        for y = 0; y < img_h; y = y + 1 {
          let src_base = y * img_w
          let dst_base = y * out_w * 4
          for x = 0; x < img_w; x = x + 1 {
            let idx = indices[src_base + x].to_int()
            let di = dst_base + x * 4
            if has_transparency && idx == transparent_idx {
              // Transparent: alpha=0 (bytes already zero from init)
              continue
            }
            if idx < pal_len {
              let c = palette_rgba[idx]
              out[di] = c[0]
              out[di + 1] = c[1]
              out[di + 2] = c[2]
              out[di + 3] = c[3]
            } else {
              out[di + 3] = b'\xFF' // Opaque black for out-of-bounds
            }
          }
        }
      }

      return Image::new(
        out_w,
        out_h,
        PixelFormat::RGBA8,
        Bytes::from_array(out),
      )
    }

    // Trailer: end of file
    if block_type == 0x3B {
      raise Failure::Failure("GIF: no image found")
    }

    raise Failure::Failure("GIF: unknown block type 0x\{block_type.to_byte()}")
  }

  raise Failure::Failure("GIF: no image found")
}

///|
/// Decode all frames from an animated GIF, returning an AnimatedImage.
/// Parses Graphic Control Extensions for frame delays and transparency,
/// and the Netscape Application Extension for loop count.
/// Frames are composited onto the full canvas respecting disposal methods.
pub fn decode_gif_all(data : Bytes) -> AnimatedImage raise Failure {
  let decoder = GifDecoder::new(data)
  decoder.decode_all()
}

///|
fn GifDecoder::decode_all(self : GifDecoder) -> AnimatedImage raise Failure {
  let mut pos = self.pos
  let mut loop_count = 0 // 0 = infinite loop (default for GIF)

  // Collect frames
  let frames_buf = Buffer()
  let delays_buf = Buffer()

  // GCE state for the next frame
  let mut has_transparency = false
  let mut transparent_idx = -1
  let mut delay = 0
  let mut disposal = 0 // 0=unspecified, 1=leave, 2=background, 3=restore

  // Canvas state
  let canvas_w = self.width
  let canvas_h = self.height
  let canvas_size = canvas_w * canvas_h * 4
  let canvas = Array::make(canvas_size, b'\x00')

  // Pre-compute background color from global color table if available
  let bg_rgba = if self.bg_color >= 0 && self.bg_color < self.global_ct.length() {
    let (br, bg, bb) = self.global_ct[self.bg_color]
    [br.to_byte(), bg.to_byte(), bb.to_byte(), b'\xFF']
  } else {
    [b'\x00', b'\x00', b'\x00', b'\x00']
  }

  while pos < self.data.length() {
    let block_type = self.data[pos].to_int()
    pos = pos + 1

    // Extension block
    if block_type == 0x21 {
      if pos >= self.data.length() {
        raise Failure::Failure("GIF: truncated extension")
      }
      let ext_type = self.data[pos].to_int()
      pos = pos + 1

      if ext_type == 0xF9 {
        // Graphic Control Extension
        if pos + 5 > self.data.length() {
          raise Failure::Failure("GIF: truncated GCE")
        }
        let _block_size = self.data[pos].to_int()
        pos = pos + 1
        let gce_packed = self.data[pos].to_int()
        pos = pos + 1
        delay = read_u16_le(self.data, pos)
        pos = pos + 2
        let trans_idx = self.data[pos].to_int()
        pos = pos + 1
        let _term = self.data[pos].to_int()
        pos = pos + 1

        has_transparency = (gce_packed & 1) != 0
        transparent_idx = if has_transparency { trans_idx } else { -1 }
        disposal = (gce_packed >> 2) & 7
      } else if ext_type == 0xFF {
        // Application Extension
        let (app_data, np) = read_sub_blocks(self.data, pos)
        pos = np
        // Check for Netscape Application Extension (loop count)
        if app_data.length() >= 15 &&
          app_data[0] == b'N' &&
          app_data[1] == b'E' &&
          app_data[2] == b'T' &&
          app_data[3] == b'S' &&
          app_data[4] == b'C' &&
          app_data[5] == b'A' &&
          app_data[6] == b'P' &&
          app_data[7] == b'E' &&
          app_data[8] == b'2' &&
          app_data[9] == b'.' &&
          app_data[10] == b'0' {
          // Sub-block data: 3 bytes (1 byte sub-block ID, 2 bytes loop count LE)
          if app_data.length() >= 14 {
            loop_count = app_data[12].to_int() | (app_data[13].to_int() << 8)
          }
        }
      } else {
        // Skip other extensions
        let (_bs, np) = read_sub_blocks(self.data, pos)
        pos = np
      }
      continue
    }

    // Image Descriptor
    if block_type == 0x2C {
      if pos + 9 > self.data.length() {
        raise Failure::Failure("GIF: truncated image descriptor")
      }
      let img_left = read_u16_le(self.data, pos)
      let img_top = read_u16_le(self.data, pos + 2)
      let img_w = read_u16_le(self.data, pos + 4)
      let img_h = read_u16_le(self.data, pos + 6)
      let img_packed = self.data[pos + 8].to_int()
      pos = pos + 9

      let has_lct = img_packed >> 7 != 0
      let is_interlaced = ((img_packed >> 6) & 1) != 0
      let lct_size = 1 << ((img_packed & 7) + 1)

      // Read Local Color Table if present
      let mut active_ct = self.global_ct
      if has_lct {
        active_ct = Array::make(lct_size, (0, 0, 0))
        for i = 0; i < lct_size; i = i + 1 {
          let r = self.data[pos].to_int()
          let g = self.data[pos + 1].to_int()
          let b = self.data[pos + 2].to_int()
          active_ct[i] = (r, g, b)
          pos = pos + 3
        }
      }

      let palette_rgba = ct_to_rgba(active_ct)
      let pal_len = palette_rgba.length()

      // Read LZW minimum code size
      if pos >= self.data.length() {
        raise Failure::Failure("GIF: no LZW code size")
      }
      let min_code_size = self.data[pos].to_int()
      if min_code_size < 2 {
        raise Failure::Failure("GIF: invalid LZW code size")
      }
      pos = pos + 1

      // Read sub-blocks containing LZW data
      let (lzw_data, np) = read_sub_blocks(self.data, pos)
      pos = np

      // Decompress LZW data
      let pixel_count = img_w * img_h
      let indices = lzw_decompress(lzw_data, min_code_size, pixel_count)

      // Decode frame into RGBA buffer
      let frame_buf = Array::make(canvas_w * canvas_h * 4, b'\x00')

      // Handle disposal method 2: restore to background before drawing
      if disposal == 2 {
        for i = 0; i < canvas_size; i = i + 1 {
          canvas[i] = bg_rgba[i % 4]
        }
      }

      if is_interlaced {
        let row_map = build_interlace_map(img_h)
        for src_row = 0; src_row < img_h; src_row = src_row + 1 {
          let dst_row = row_map[src_row]
          let src_base = src_row * img_w
          for x = 0; x < img_w; x = x + 1 {
            let idx = indices[src_base + x].to_int()
            let ox = img_left + x
            let oy = img_top + dst_row
            if ox >= 0 && ox < canvas_w && oy >= 0 && oy < canvas_h {
              let di = (oy * canvas_w + ox) * 4
              if has_transparency && idx == transparent_idx {
                // Transparent: leave existing canvas pixel
                continue
              }
              if idx < pal_len {
                let c = palette_rgba[idx]
                frame_buf[di] = c[0]
                frame_buf[di + 1] = c[1]
                frame_buf[di + 2] = c[2]
                frame_buf[di + 3] = c[3]
              } else {
                frame_buf[di + 3] = b'\xFF'
              }
            }
          }
        }
      } else {
        for y = 0; y < img_h; y = y + 1 {
          let src_base = y * img_w
          for x = 0; x < img_w; x = x + 1 {
            let idx = indices[src_base + x].to_int()
            let ox = img_left + x
            let oy = img_top + y
            if ox >= 0 && ox < canvas_w && oy >= 0 && oy < canvas_h {
              let di = (oy * canvas_w + ox) * 4
              if has_transparency && idx == transparent_idx {
                continue
              }
              if idx < pal_len {
                let c = palette_rgba[idx]
                frame_buf[di] = c[0]
                frame_buf[di + 1] = c[1]
                frame_buf[di + 2] = c[2]
                frame_buf[di + 3] = c[3]
              } else {
                frame_buf[di + 3] = b'\xFF'
              }
            }
          }
        }
      }

      // Composite frame onto canvas so transparent pixels show the background
      // (whether it's the original canvas, cleared to bg, or previous content)
      for i = 0; i < canvas_size; i = i + 4 {
        if frame_buf[i + 3] != b'\x00' {
          canvas[i] = frame_buf[i]
          canvas[i + 1] = frame_buf[i + 1]
          canvas[i + 2] = frame_buf[i + 2]
          canvas[i + 3] = b'\xFF'
        }
      }
      // Save the composited canvas as the frame
      let frame_bytes = Bytes::from_array(
        {
          let copy = Array::make(canvas_size, b'\x00')
          for i = 0; i < canvas_size; i = i + 1 {
            copy[i] = canvas[i]
          }
          copy
        },
      )
      frames_buf.write_bytes(frame_bytes)
      delays_buf.write_bytes(
        Bytes::from_array([delay.to_byte(), (delay >> 8).to_byte()]),
      )
      continue
    }

    // Trailer: end of file
    if block_type == 0x3B {
      break
    }

    raise Failure::Failure("GIF: unknown block type 0x\{block_type.to_byte()}")
  }

  // Build result
  let frame_data = frames_buf.to_bytes()
  let delay_data = delays_buf.to_bytes()
  let num_frames = delay_data.length() / 2

  if num_frames == 0 {
    raise Failure::Failure("GIF: no frames found")
  }

  let empty_bytes = Bytes::from_array(Array::make(4, b'\x00'))
  let dummy_img = Image::new(1, 1, PixelFormat::RGBA8, empty_bytes)
  let frames = Array::make(num_frames, dummy_img)
  let delays = Array::make(num_frames, 0)
  for i = 0; i < num_frames; i = i + 1 {
    let fstart = i * canvas_size
    let arr = Array::make(canvas_size, b'\x00')
    for j = 0; j < canvas_size; j = j + 1 {
      arr[j] = frame_data[fstart + j]
    }
    frames[i] = Image::new(
      canvas_w,
      canvas_h,
      PixelFormat::RGBA8,
      Bytes::from_array(arr),
    )
    delays[i] = delay_data[i * 2].to_int() |
      (delay_data[i * 2 + 1].to_int() << 8)
  }

  AnimatedImage::new(frames, delays, canvas_w, canvas_h, loop_count)
}
