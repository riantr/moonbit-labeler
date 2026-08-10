// Copyright (c) 2025 lws
// JPEG baseline decoder — grayscale + YCbCr color
//
// Supports JFIF baseline JPEG (SOF0) with:
//   - Huffman-coded DC and AC coefficients (O(1) prefix table lookup)
//   - Zigzag deordering → dequantization → IDCT
//   - Grayscale (1-component) and YCbCr color (3-component, 4:4:4/4:2:2/4:2:0)
//   - Restart marker (RST) support
//
// Performance optimizations:
//   - IDCT coefficients and zigzag table as module-level constants
//   - O(1) Huffman decoding via prefix lookup table
//   - Bulk bit reading (reads bytes directly when 8+ bits needed)
//   - JBR uses byte_pos + bit_pos representation

//-----------------------------------------------------------------------------
// Module-level constants (pre-computed once, not per-call)
//-----------------------------------------------------------------------------

///|
/// Zigzag scan order (JPEG spec Figure K.2)
let zigzag : Array[Int] = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48,
  41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15,
  23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62,
  63,
]

///|
/// IDCT basis coefficients (scaled by 2^12 = 4096)
/// cos((2x+1)*u*pi/16) * 4096 for each (u, x)
let dct_t : Array[Array[Int]] = [
  [1448, 1448, 1448, 1448, 1448, 1448, 1448, 1448],
  [2009, 1703, 1138, 400, -400, -1138, -1703, -2009],
  [1892, 784, -784, -1892, -1892, -784, 784, 1892],
  [1703, -400, -2009, -1138, 1138, 2009, 400, -1703],
  [1448, -1448, -1448, 1448, 1448, -1448, -1448, 1448],
  [1138, -2009, 400, 1703, -1703, -400, 2009, -1138],
  [784, -1892, 1892, -784, -784, 1892, -1892, 784],
  [400, -1138, 1703, -2009, 2009, -1703, 1138, -400],
]

//-----------------------------------------------------------------------------
// Bit reader (MSB-first, used for JPEG Huffman-coded data)
//-----------------------------------------------------------------------------

///|
/// JPEG bit reader. Uses byte_pos + bit_pos representation for efficient
/// bulk reading.
/// Fields are named differently from BitReader to avoid type ambiguity.
priv struct JBR {
  buf : Bytes // entropy-coded data (with 0xFF00 stuffing already stripped)
  bp : Int // current byte position
  bitp : Int // next bit to read within byte (0=MSB, 7=LSB)
}

///|
fn JBR::new(data : Bytes) -> JBR {
  { buf: data, bp: 0, bitp: 0 }
}

///|
/// Read n bits MSB-first. Returns (new_reader, value).
/// Uses bulk byte reading when byte-aligned for efficiency.
fn JBR::read_bits(self : JBR, n : Int) -> (JBR, Int) raise Failure {
  if n == 0 {
    return (self, 0)
  }

  let mut bp_idx = self.bp
  let mut bit_pos = self.bitp
  let mut result = 0
  let mut needed = n

  // Fast path: byte-aligned, reading 8+ bits → read whole bytes
  while needed >= 8 && bit_pos == 0 {
    if bp_idx >= self.buf.length() {
      raise Failure::Failure("JPEG: unexpected end of entropy data")
    }
    result = (result << 8) | self.buf[bp_idx].to_int()
    bp_idx = bp_idx + 1
    needed = needed - 8
  }

  // Remaining bits (either not byte-aligned, or < 8 bits left)
  while needed > 0 {
    if bp_idx >= self.buf.length() {
      raise Failure::Failure("JPEG: unexpected end of entropy data")
    }
    let byte = self.buf[bp_idx].to_int()
    let bits_left = 8 - bit_pos
    let take = if needed < bits_left { needed } else { bits_left }
    // Extract bits from the current position within the byte (MSB-first)
    let val = (byte >> (bits_left - take)) & ((1 << take) - 1)
    result = (result << take) | val
    needed = needed - take
    if take == bits_left {
      bp_idx = bp_idx + 1
      bit_pos = 0
    } else {
      bit_pos = bit_pos + take
    }
  }

  ({ buf: self.buf, bp: bp_idx, bitp: bit_pos }, result)
}

//-----------------------------------------------------------------------------
// JPEG Huffman table with O(1) prefix lookup
//-----------------------------------------------------------------------------

///|
/// JPEG Huffman table entry.
/// Fields are named sym/len to avoid conflict with PNG's HEntry (symbol/length).
priv struct JHTEntry {
  sym : Int
  len : Int
}

///|
/// JPEG Huffman table with prefix lookup for O(1) decoding.
/// Uses the same approach as PNG's huff_decode (png.mbt:65-69).
priv struct JHT {
  table : Array[JHTEntry]
  tbl_bits : Int
}

///|
/// Build a fast prefix-lookup Huffman table from BITS and HUFFVAL arrays.
/// This eliminates the O(n) bit-at-a-time scan with an O(1) table lookup.
fn build_jht(bits : Array[Int], hv_in : Array[Int]) -> JHT {
  // Find the maximum code length
  let mut max_len = 0
  for l = 1; l <= 16; l = l + 1 {
    if bits[l - 1] > 0 {
      max_len = l
    }
  }
  if max_len == 0 {
    // Return empty table with sentinel
    let tbl = Array::make(1, { sym: -1, len: 0 })
    return { table: tbl, tbl_bits: 0 }
  }

  // Compute canonical Huffman codes for each length (MSB-first like JPEG)
  let huffcode = Array::make(17, Array::make(0, 0))
  let mut code = 0
  for l = 1; l <= 16; l = l + 1 {
    let count = bits[l - 1]
    if count > 0 {
      let codes = Array::make(count, 0)
      for i = 0; i < count; i = i + 1 {
        codes[i] = code
        code = code + 1
      }
      huffcode[l] = codes
    }
    code = code << 1
  }

  // Build prefix table of size 2^tbl_bits
  let tbl_bits = max_len
  let ts = 1 << tbl_bits
  let sentinel = { sym: -1, len: 0 }
  let tbl = Array::make(ts, sentinel)

  let mut si = 0
  for l = 1; l <= max_len; l = l + 1 {
    let count = bits[l - 1]
    if count > 0 {
      let codes = huffcode[l]
      for i = 0; i < count; i = i + 1 {
        let c = codes[i]
        let sym_val = hv_in[si]
        si = si + 1
        // Fill all table entries starting with this prefix
        let entry = { sym: sym_val, len: l }
        let base = c << (tbl_bits - l)
        let step = 1 << (tbl_bits - l)
        for j = 0; j < step && base + j < ts; j = j + 1 {
          tbl[base + j] = entry
        }
      }
    }
  }

  { table: tbl, tbl_bits }
}

///|
/// Decode a symbol using the prefix lookup table.
/// Reads one bit at a time (avoiding push-back complexity), but uses the
/// prefix table for O(1) validation at each bit length.
fn jht_decode(ht : JHT, r : JBR) -> (JBR, Int) raise Failure {
  let mut reader = r
  let mut code = 0
  for l = 1; l <= 16; l = l + 1 {
    let (nr, bit) = reader.read_bits(1)
    reader = nr
    code = (code << 1) | bit
    // Check if this prefix matches a code of length l in the table
    if l <= ht.tbl_bits {
      let idx = code << (ht.tbl_bits - l)
      let e = ht.table[idx]
      if e.len == l {
        return (reader, e.sym)
      }
    }
  }
  raise Failure::Failure("JPEG: bad Huffman code")
}

//-----------------------------------------------------------------------------
// IDCT (Inverse Discrete Cosine Transform)
//-----------------------------------------------------------------------------

///|
/// 1-D IDCT on 8-element array v, writing result to out[os..os+7].
/// Uses pre-computed module-level dct_t coefficient matrix.
fn idct_1d(v : Array[Int], out : Array[Int], os : Int) -> Unit {
  for x = 0; x < 8; x = x + 1 {
    let mut sum = 0
    for u = 0; u < 8; u = u + 1 {
      sum = sum + v[u] * dct_t[u][x]
    }
    let pixel = ((sum + 2048) >> 12) + 128
    if pixel < 0 {
      out[os + x] = 0
    } else if pixel > 255 {
      out[os + x] = 255
    } else {
      out[os + x] = pixel
    }
  }
}

///|
/// 2-D IDCT on an 8x8 block, returns 64-element pixel array.
/// Optimized: reuses 3 pre-allocated 8-element buffers instead of
/// allocating 8 row + 8 tmp + 8 col = 24 temporary arrays per block.
fn idct_2d(block : Array[Int]) -> Array[Int] {
  // First pass: IDCT on rows, store in transposed layout
  let t = Array::make(64, 0)
  // Reusable 8-element buffers (allocated once per block)
  let row_buf = Array::make(8, 0)
  let tmp_buf = Array::make(8, 0)
  let col_buf = Array::make(8, 0)
  for y = 0; y < 8; y = y + 1 {
    for x = 0; x < 8; x = x + 1 {
      row_buf[x] = block[y * 8 + x]
    }
    idct_1d(row_buf, tmp_buf, 0)
    for x = 0; x < 8; x = x + 1 {
      t[x * 8 + y] = tmp_buf[x]
    }
  }
  // Second pass: IDCT on columns (rows of transposed matrix)
  let res = Array::make(64, 0)
  for x = 0; x < 8; x = x + 1 {
    for y = 0; y < 8; y = y + 1 {
      col_buf[y] = t[x * 8 + y]
    }
    idct_1d(col_buf, res, x * 8)
  }
  res
}

//-----------------------------------------------------------------------------
// JPEG Decoder Helper Functions
//-----------------------------------------------------------------------------

///|
/// Decode DC coefficient. Returns (reader, new_value, new_pred).
fn jpg_dc(r : JBR, ht : JHT, pred : Int) -> (JBR, Int, Int) raise Failure {
  let (r2, cat) = jht_decode(ht, r)
  if cat == 0 {
    return (r2, pred, pred)
  }
  let (r3, bits) = r2.read_bits(cat)
  let half = 1 << (cat - 1)
  let diff = if bits < half { bits - ((1 << cat) - 1) } else { bits }
  let new_val = pred + diff
  (r3, new_val, new_val)
}

///|
/// Decode AC coefficients for one 8x8 block.
/// Writes decoded values to block[] at zigzag positions.
/// Returns the updated reader.
fn jpg_ac(r : JBR, ht : JHT, block : Array[Int]) -> JBR raise Failure {
  let mut reader = r
  let mut k = 1
  while k < 64 {
    let (r2, sym) = jht_decode(ht, reader)
    reader = r2
    if sym == 0 {
      return reader
    } // EOB
    let rs = sym >> 4
    let sz = sym & 0xF
    if sz == 0 && rs == 15 {
      // ZRL: 16 zeros
      k = k + 16
      continue
    }
    k = k + rs
    if k >= 64 {
      break
    }
    if sz > 0 {
      let (r3, bits) = reader.read_bits(sz)
      reader = r3
      let half = 1 << (sz - 1)
      let val = if bits < half { bits - ((1 << sz) - 1) } else { bits }
      let zi = zigzag[k]
      if zi < 64 {
        block[zi] = val
      }
    }
    k = k + 1
  }
  reader
}

///|
/// Decode one 8x8 block. Returns (reader, new_dc_pred, pixel_array[64]).
fn jpg_block(
  r : JBR,
  dc_ht : JHT,
  ac_ht : JHT,
  qt : Array[Int],
  dc_pred : Int,
) -> (JBR, Int, Array[Int]) raise Failure {
  let block = Array::make(64, 0)
  let (r2, _dc_val, ndc) = jpg_dc(r, dc_ht, dc_pred)
  let r3 = jpg_ac(r2, ac_ht, block)
  block[0] = ndc
  // Dequantize
  for i = 0; i < 64; i = i + 1 {
    block[i] = block[i] * qt[i]
  }
  (r3, ndc, idct_2d(block))
}

//-----------------------------------------------------------------------------
// YCbCr → RGB conversion (ITU-R BT.601, 12-bit fixed point)
//-----------------------------------------------------------------------------

///|
/// Convert YCbCr to RGB using ITU-R BT.601 coefficients with 12 fractional bits.
/// All values are clamped to [0, 255].
fn ycbcr_to_rgb(y : Int, cb : Int, cr : Int) -> (Int, Int, Int) {
  let cb_off = cb - 128
  let cr_off = cr - 128

  // R = Y + 1.40200 * (Cr-128)  →  R = Y + 5743 * Cr_off / 4096
  let r = y + ((5743 * cr_off + 2048) >> 12)
  // G = Y - 0.34414 * (Cb-128) - 0.71414 * (Cr-128)
  let g = y - ((1410 * cb_off + 2925 * cr_off + 2048) >> 12)
  // B = Y + 1.77200 * (Cb-128)  →  B = Y + 7258 * Cb_off / 4096
  let b = y + ((7258 * cb_off + 2048) >> 12)

  let r_clamp = if r < 0 { 0 } else if r > 255 { 255 } else { r }
  let g_clamp = if g < 0 { 0 } else if g > 255 { 255 } else { g }
  let b_clamp = if b < 0 { 0 } else if b > 255 { 255 } else { b }

  (r_clamp, g_clamp, b_clamp)
}

//-----------------------------------------------------------------------------
// Main JPEG decoder
//-----------------------------------------------------------------------------

///|
/// Decode a JPEG image from raw bytes.
/// Supports grayscale (1-component) and YCbCr color (3-component) baseline JPEG.
pub fn decode_jpeg(data : Bytes) -> Image raise Failure {
  if data.length() < 2 || data[0].to_int() != 0xFF || data[1].to_int() != 0xD8 {
    raise Failure::Failure("JPEG: missing SOI marker")
  }

  let mut pos = 2
  let mut w = 0
  let mut h = 0
  let mut nc = 1 // number of components

  // Component info from SOF0
  let mut comp_id = Array::make(0, 0) // component ID (for scan selector matching)
  let mut comp_h = Array::make(0, 0) // horizontal sampling factor
  let mut comp_v = Array::make(0, 0) // vertical sampling factor
  let mut comp_qt = Array::make(0, 0) // quantization table selector

  // Quantization tables (up to 4)
  let qt = Array::make(4, Array::make(64, 1))

  // Huffman tables: [TC][TH] where TC=0:DC, TC=1:AC
  let ht_sentinel = JHT::{
    table: Array::make(1, { sym: -1, len: 0 }),
    tbl_bits: 0,
  }
  let dc_ht = Array::make(4, ht_sentinel)
  let ac_ht = Array::make(4, ht_sentinel)

  // Restart interval (0 = no restart markers)
  let mut restart_interval = 0

  // Parse markers
  while pos < data.length() {
    if data[pos].to_int() != 0xFF {
      raise Failure::Failure("JPEG: expected marker at \{pos}")
    }
    pos = pos + 1
    let mb = data[pos].to_int()
    pos = pos + 1

    // Skip padding bytes and RST markers in header
    if mb == 0x00 {
      continue
    }
    if mb == 0xD8 {
      continue
    } // SOI
    if mb >= 0xD0 && mb <= 0xD7 {
      continue
    } // RST markers (shouldn't appear outside SOS)
    if mb == 0xD9 {
      break
    } // EOI

    let len = (data[pos].to_int() << 8) | data[pos + 1].to_int()
    pos = pos + 2
    let end = pos + len - 2

    if mb == 0xDB { // DQT - Define Quantization Table
      while pos < end {
        let info = data[pos].to_int()
        pos = pos + 1
        let tid = info & 0x0F
        let prec = (info >> 4) & 0x0F
        let tbl = Array::make(64, 0)
        for i = 0; i < 64; i = i + 1 {
          if prec == 0 {
            tbl[zigzag[i]] = data[pos].to_int()
            pos = pos + 1
          } else {
            tbl[zigzag[i]] = (data[pos].to_int() << 8) | data[pos + 1].to_int()
            pos = pos + 2
          }
        }
        if tid < 4 {
          qt[tid] = tbl
        }
      }
    } else if mb == 0xC0 { // SOF0 - Start of Frame (baseline)
      let _precision = data[pos].to_int()
      pos = pos + 1
      let hi_h = data[pos].to_int()
      let lo_h = data[pos + 1].to_int()
      let hi_w = data[pos + 2].to_int()
      let lo_w = data[pos + 3].to_int()
      h = hi_h * 256 + lo_h
      w = hi_w * 256 + lo_w
      pos = pos + 4
      nc = data[pos].to_int()
      pos = pos + 1

      comp_h = Array::make(nc, 0)
      comp_v = Array::make(nc, 0)
      comp_qt = Array::make(nc, 0)
      comp_id = Array::make(nc, 0)
      for i = 0; i < nc; i = i + 1 {
        let cid = data[pos].to_int() // component ID
        pos = pos + 1
        let samp = data[pos].to_int()
        pos = pos + 1
        comp_id[i] = cid
        comp_h[i] = (samp >> 4) & 0xF
        comp_v[i] = samp & 0xF
        comp_qt[i] = data[pos].to_int()
        pos = pos + 1
      }
    } else if mb == 0xC4 { // DHT - Define Huffman Table
      while pos < end {
        let info = data[pos].to_int()
        pos = pos + 1
        let tc = (info >> 4) & 1 // 0=DC, 1=AC
        let th = info & 0xF
        let bits = Array::make(16, 0)
        let mut total = 0
        for i = 0; i < 16; i = i + 1 {
          bits[i] = data[pos].to_int()
          pos = pos + 1
          total = total + bits[i]
        }
        let hv = Array::make(total, 0)
        for i = 0; i < total; i = i + 1 {
          hv[i] = data[pos].to_int()
          pos = pos + 1
        }
        let ht = build_jht(bits, hv)
        if tc == 0 {
          if th < 4 {
            dc_ht[th] = ht
          }
        } else if th < 4 {
          ac_ht[th] = ht
        }
      }
    } else if mb == 0xDD { // DRI - Define Restart Interval
      restart_interval = (data[pos].to_int() << 8) | data[pos + 1].to_int()
      pos = end
    } else if mb == 0xDA { // SOS - Start of Scan
      let ns = data[pos].to_int() // number of scan components
      pos = pos + 1

      // Read scan component selectors: (component_id, dc_table, ac_table)
      let scan_comp_idx = Array::make(ns, 0) // maps scan component → SOF component index
      let scan_dc_ht = Array::make(ns, 0)
      let scan_ac_ht = Array::make(ns, 0)
      for i = 0; i < ns; i = i + 1 {
        let cs = data[pos].to_int() // component selector (component ID)
        pos = pos + 1
        let tdta = data[pos].to_int()
        pos = pos + 1
        let td = (tdta >> 4) & 0xF
        let ta = tdta & 0xF
        scan_dc_ht[i] = td
        scan_ac_ht[i] = ta
        // Find the SOF component index that matches this component ID
        let mut found = false
        for j = 0; j < nc; j = j + 1 {
          if comp_id[j] == cs {
            scan_comp_idx[i] = j
            found = true
            break
          }
        }
        if !found {
          scan_comp_idx[i] = i
        }
      }

      pos = pos + 3 // skip Ss, Se, Ah/Al

      // Collect entropy-coded data (until next marker, stripping 0xFF00 byte stuffing)
      let ec_buf = Buffer()
      while pos < data.length() - 1 {
        let b0 = data[pos].to_int()
        if b0 == 0xFF {
          let b1 = data[pos + 1].to_int()
          // Check for end-of-scan markers (anything other than 0x00 and RST0-7)
          if b1 != 0x00 && (b1 < 0xD0 || b1 > 0xD7) {
            break
          }
          if b1 == 0x00 {
            ec_buf.write_byte(b'\xFF')
            pos = pos + 2
            continue
          }
          // RST marker: skip (they serve as resynchronization points)
          pos = pos + 2
          continue
        }
        ec_buf.write_byte(data[pos])
        pos = pos + 1
      }

      let ec = ec_buf.to_bytes()

      // Determine MCU dimensions
      let mut max_h = 1
      let mut max_v = 1
      for i = 0; i < nc; i = i + 1 {
        if comp_h[i] > max_h {
          max_h = comp_h[i]
        }
        if comp_v[i] > max_v {
          max_v = comp_v[i]
        }
      }
      let mcu_w = max_h * 8
      let mcu_h = max_v * 8

      // Allocate component planes as Array[Byte] (mutable, unlike Bytes)
      let comp_w = Array::make(nc, 0)
      let comp_h_plane = Array::make(nc, 0)
      for i = 0; i < nc; i = i + 1 {
        comp_w[i] = ((w * comp_h[i] + max_h - 1) / max_h + 7) / 8 * 8
        comp_h_plane[i] = ((h * comp_v[i] + max_v - 1) / max_v + 7) / 8 * 8
      }

      let planes = Array::make(nc, Array::make(0, b'\x00'))
      for i = 0; i < nc; i = i + 1 {
        planes[i] = Array::make(comp_w[i] * comp_h_plane[i], b'\x00')
      }

      // Per-component DC predictors
      let dc_pred = Array::make(nc, 0)

      let mut reader = JBR::new(ec)
      let mcus_x = (w + mcu_w - 1) / mcu_w
      let mcus_y = (h + mcu_h - 1) / mcu_h
      let mut block_counter = 0

      for my = 0; my < mcus_y; my = my + 1 {
        for mx = 0; mx < mcus_x; mx = mx + 1 {
          // For each component in scan order
          for sc = 0; sc < ns; sc = sc + 1 {
            let ci = scan_comp_idx[sc]
            let sf_h = comp_h[ci]
            let sf_v = comp_v[ci]
            let dht_dc = scan_dc_ht[sc]
            let dht_ac = scan_ac_ht[sc]
            let qti = comp_qt[ci]

            // Decode sf_h * sf_v data units for this component in this MCU
            for vy = 0; vy < sf_v; vy = vy + 1 {
              for vx = 0; vx < sf_h; vx = vx + 1 {
                let (r2, ndc, pixels) = jpg_block(
                  reader,
                  dc_ht[dht_dc],
                  ac_ht[dht_ac],
                  qt[qti],
                  dc_pred[ci],
                )
                reader = r2
                dc_pred[ci] = ndc

                // Place decoded block into the component plane
                let block_x = mx * sf_h * 8 + vx * 8
                let block_y = my * sf_v * 8 + vy * 8
                let plane = planes[ci]
                let plane_w = comp_w[ci]
                let plane_h = comp_h_plane[ci]
                for py = 0; py < 8; py = py + 1 {
                  let oy = block_y + py
                  if oy >= plane_h {
                    continue
                  }
                  for px = 0; px < 8; px = px + 1 {
                    let ox = block_x + px
                    if ox >= plane_w {
                      continue
                    }
                    plane[oy * plane_w + ox] = pixels[py * 8 + px].to_byte()
                  }
                }

                block_counter = block_counter + 1

                // Handle restart marker
                if restart_interval > 0 && block_counter % restart_interval == 0 {
                  for i = 0; i < nc; i = i + 1 {
                    dc_pred[i] = 0
                  }
                  reader = { buf: reader.buf, bp: reader.bp, bitp: 0 }
                }
              }
            }
          }
        }
      }

      // Assemble output image from component planes
      if nc == 1 {
        // Grayscale: direct copy (clipping to image dimensions)
        let out = Array::make(w * h, b'\x00')
        let plane = planes[0]
        let pw = comp_w[0]
        for y = 0; y < h; y = y + 1 {
          for x = 0; x < w; x = x + 1 {
            out[y * w + x] = plane[y * pw + x]
          }
        }
        return Image::new(w, h, PixelFormat::Gray8, Bytes::from_array(out))
      } else if nc == 3 {
        // YCbCr → RGB conversion
        let out = Array::make(w * h * 3, b'\x00')
        let y_plane = planes[0]
        let cb_plane = planes[1]
        let cr_plane = planes[2]
        let y_w = comp_w[0]
        let cb_w = comp_w[1]
        let cr_w = comp_w[2]

        for y = 0; y < h; y = y + 1 {
          for x = 0; x < w; x = x + 1 {
            // Compute sub-sampled chroma coordinates (nearest-neighbor upsampling)
            let cb_x = x * comp_h[1] / max_h
            let cb_y = y * comp_v[1] / max_v
            let cr_x = x * comp_h[2] / max_h
            let cr_y = y * comp_v[2] / max_v

            let y_val = y_plane[y * y_w + x].to_int()
            let cb_val = cb_plane[cb_y * cb_w + cb_x].to_int()
            let cr_val = cr_plane[cr_y * cr_w + cr_x].to_int()

            let (r, g, b) = ycbcr_to_rgb(y_val, cb_val, cr_val)
            let di = (y * w + x) * 3
            out[di] = r.to_byte()
            out[di + 1] = g.to_byte()
            out[di + 2] = b.to_byte()
          }
        }
        return Image::new(w, h, PixelFormat::RGB8, Bytes::from_array(out))
      } else {
        raise Failure::Failure("JPEG: unsupported component count: \{nc}")
      }
    } else {
      // Skip unknown segment
      pos = end
    }
  }

  raise Failure::Failure("JPEG: no SOS marker found")
}

///|
/// Read JPEG dimensions from header without decoding pixels.
/// Fast path: scans for SOF0 marker and extracts width/height.
pub fn jpeg_dimensions(data : Bytes) -> (Int, Int) raise Failure {
  if data.length() < 2 || data[0].to_int() != 0xFF || data[1].to_int() != 0xD8 {
    raise Failure::Failure("JPEG: missing SOI marker")
  }

  let mut pos = 2
  while pos < data.length() - 1 {
    if data[pos].to_int() != 0xFF {
      raise Failure::Failure("JPEG: expected marker")
    }
    pos = pos + 1
    let mb = data[pos].to_int()
    pos = pos + 1

    if mb == 0x00 {
      continue
    }
    if mb == 0xD8 {
      continue
    }
    if mb >= 0xD0 && mb <= 0xD7 {
      continue
    }
    if mb == 0xD9 {
      break
    }

    let len = (data[pos].to_int() << 8) | data[pos + 1].to_int()
    pos = pos + 2
    let end = pos + len - 2

    if mb == 0xC0 { // SOF0
      let _precision = data[pos].to_int()
      pos = pos + 1
      let hi_h = data[pos].to_int()
      let lo_h = data[pos + 1].to_int()
      let hi_w = data[pos + 2].to_int()
      let lo_w = data[pos + 3].to_int()
      let h = hi_h * 256 + lo_h
      let w = hi_w * 256 + lo_w
      return (w, h)
    }

    pos = end
  }

  raise Failure::Failure("JPEG: no SOF0 marker found")
}
