// Copyright (c) 2025 lws
// PNG decoder - Stage 1: Huffman tree for DEFLATE

//-----------------------------------------------------------------------------
// Huffman Tree for DEFLATE (RFC 1951)
//-----------------------------------------------------------------------------

///|
/// Huffman table entry: symbol value and code length
priv struct HEntry {
  symbol : Int
  length : Int
}

///|
/// Fast lookup Huffman decoder using a prefix table
priv struct HDecoder {
  table : Array[HEntry]
  tbl_bits : Int
}

///|
/// Build a canonical Huffman tree from an array of code lengths
/// Uses a fast lookup table of size 2^tbl_bits for O(1) symbol decoding
fn build_huffman(cl : Array[Int], ns : Int) -> HDecoder {
  // Determine maximum code length
  let mut ml = 0
  for i = 0; i < ns; i = i + 1 {
    if cl[i] > ml && cl[i] <= 15 {
      ml = cl[i]
    }
  }
  if ml == 0 {
    return { table: Array::make(1, { symbol: -1, length: 0 }), tbl_bits: 0 }
  }

  // Count codes per length (RFC 1951 §3.2.2)
  let bc = Array::make(16, 0)
  let nc = Array::make(16, 0)
  for i = 0; i < ns; i = i + 1 {
    let l = cl[i]
    if l > 0 && l <= 15 {
      bc[l] = bc[l] + 1
    }
  }

  // Compute the starting code for each length
  let mut code = 0
  for b = 1; b <= 15; b = b + 1 {
    code = (code + bc[b - 1]) << 1
    nc[b] = code
  }

  // Build fast lookup table: tbl_bits = ml gives optimal size (2^ml entries)
  // Kraft inequality guarantees all 2^ml entries are filled for complete Huffman trees
  let tb = ml
  let ts = 1 << tb
  let tbl = Array::make(ts, { symbol: -1, length: 0 })

  for i = 0; i < ns; i = i + 1 {
    let l = cl[i]
    if l > 0 && l <= 15 {
      let a = nc[l]
      nc[l] = a + 1
      let base = a << (tb - l)
      let step = 1 << (tb - l)
      for j = 0; j < step && base + j < ts; j = j + 1 {
        tbl[base + j] = { symbol: i, length: l }
      }
    }
  }

  { table: tbl, tbl_bits: tb }
}

///|
/// Reverse the bottom `n` bits of `v` (bit 0 becomes bit n-1, etc.)
fn reverse_bits(v : Int, n : Int) -> Int {
  let mut result = 0
  let mut x = v
  for i = 0; i < n; i = i + 1 {
    result = (result << 1) | (x & 1)
    x = x >> 1
  }
  result
}

///|
/// Decode a single symbol using the fast lookup table
/// `bits` contains the next `tbl_bits` bits LSB-first; we reverse them because
/// Huffman codes are transmitted MSB-first but packed LSB-first in DEFLATE
fn huff_decode(d : HDecoder, bits : Int) -> (Int, Int) {
  let idx = reverse_bits(bits, d.tbl_bits)
  let e = d.table[idx]
  (e.symbol, e.length)
}

///|
/// Query the number of lookup bits for this decoder
fn huff_bits(d : HDecoder) -> Int {
  d.tbl_bits
}

//-----------------------------------------------------------------------------
// Fixed Huffman trees (RFC 1951 §3.2.6)
//-----------------------------------------------------------------------------

///|
/// Pre-built fixed literal/length Huffman tree (288 symbols)
let fxl : HDecoder = {
  let ls = Array::make(288, 0)
  for i = 0; i <= 143; i = i + 1 {
    ls[i] = 8
  }
  for i = 144; i <= 255; i = i + 1 {
    ls[i] = 9
  }
  for i = 256; i <= 279; i = i + 1 {
    ls[i] = 7
  }
  for i = 280; i <= 287; i = i + 1 {
    ls[i] = 8
  }
  build_huffman(ls, 288)
}

///|
/// Pre-built fixed distance Huffman tree (32 symbols)
let fxd : HDecoder = {
  let ls = Array::make(32, 0)
  for i = 0; i < 32; i = i + 1 {
    ls[i] = 5
  }
  build_huffman(ls, 32)
}

//-----------------------------------------------------------------------------
// Length and distance tables (RFC 1951 §3.2.5)
//-----------------------------------------------------------------------------

///|
/// Base length values for length codes 257-285
let lbase : Array[Int] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
  99, 115, 131, 163, 195, 227, 258,
]

///|
/// Extra bits for length codes 257-285
let lextra : Array[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
  5, 0,
]

///|
/// Base distance values for distance codes 0-29
let dbase : Array[Int] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
/// Extra bits for distance codes 0-29
let dextra : Array[Int] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

///|
/// Code length alphabet reorder (RFC 1951 §3.2.7)
let clord : Array[Int] = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
]

//-----------------------------------------------------------------------------
// Bit buffer helpers
//-----------------------------------------------------------------------------

///|
/// Ensure at least `need` bits are available in the buffer
/// Bits are accumulated LSB-first: first bit read is at position 0
/// When the bit stream is exhausted (e.g., end-of-block padding), returns
/// whatever bits are available instead of raising. Callers must check `cnt`
/// to verify sufficient bits were obtained.
fn ensure_bits(
  r : BitReader,
  buf : Int,
  cnt : Int,
  need : Int,
) -> (BitReader, Int, Int) {
  let mut xr = r
  let mut xb = buf
  let mut xc = cnt
  while xc < need {
    // Read up to 16 bits at once
    let to_read = if need - xc > 16 { 16 } else { need - xc }
    try {
      let (nr, val) = xr.read_bits(to_read)
      xr = nr
      xb = xb | (val << xc)
      xc = xc + to_read
    } catch {
      _ =>
        // End of bit stream (e.g., final block with padding).
        // Return whatever we have; the caller will detect insufficient bits
        // via clen > bc or similar checks.
        break
    }
  }
  (xr, xb, xc)
}

///|
/// Consume `n` bits from the LSB side of the buffer, returning the value and updated state
fn consume(b : Int, c : Int, n : Int) -> (Int, Int, Int) {
  let v = b & ((1 << n) - 1)
  let nb = b >> n
  let nc = c - n
  (nb, nc, v)
}

//-----------------------------------------------------------------------------
// DEFLATE Decompressor (RFC 1951)
//-----------------------------------------------------------------------------

///|
/// Decompress DEFLATE-formatted data (pure DEFLATE, no zlib wrapper)
fn deflate_decompress(data : Bytes) -> Bytes raise Failure {
  let mut r = BitReader::new(data)
  let out = Buffer()
  let mut fb = false

  while !fb {
    let (r_bf, bf) = r.read_bits(1)
    r = r_bf
    let (r_bt, bt) = r.read_bits(2)
    r = r_bt
    fb = bf == 1

    if bt == 0 {
      // BTYPE=0: No compression
      r = r.align_to_byte()
      let (r_lb, lb) = r.read_bytes(2)
      r = r_lb
      let (r_nb, nb) = r.read_bytes(2)
      r = r_nb
      let len = lb[0].to_int() | (lb[1].to_int() << 8)
      let nlen = nb[0].to_int() | (nb[1].to_int() << 8)
      if (len ^ nlen) != 0xFFFF {
        raise Failure::Failure("DEFLATE: bad uncomp len")
      }
      let (r_ld, ld) = r.read_bytes(len)
      r = r_ld
      out.write_bytes(ld)
    } else if bt == 1 {
      // BTYPE=1: Fixed Huffman codes
      let (r2, _, _) = decode_block(r, out, fxl, fxd, 0, 0)
      r = r2
    } else if bt == 2 {
      // BTYPE=2: Dynamic Huffman codes
      let (r_dyn, bb_dyn, bc_dyn, lt, dt) = read_dyn_header(r)
      r = r_dyn
      let (r2, _, _) = decode_block(r, out, lt, dt, bb_dyn, bc_dyn)
      r = r2
    } else {
      raise Failure::Failure("DEFLATE: bad btype")
    }
  }

  out.to_bytes()
}

///|
/// Decode a single DEFLATE block (BTYPE 1 or 2)
/// Reads literal/length and distance Huffman codes with LZ77 back-references
fn decode_block(
  r : BitReader,
  out : Buffer,
  lt : HDecoder,
  dt : HDecoder,
  bb0 : Int,
  bc0 : Int,
) -> (BitReader, Int, Int) raise Failure {
  let mut xr = r
  let mut bb = bb0
  let mut bc = bc0
  let lb = huff_bits(lt)
  let db = huff_bits(dt)
  let ml = if lb > db { lb } else { db }
  let mut done = false

  while !done {
    // Ensure enough bits for a literal/length symbol.
    // When the stream is exhausted (e.g., after the final block's padding),
    // ensure_bits returns with ec=0; treat this as normal end-of-block.
    let (nr, eb, ec) = ensure_bits(xr, bb, bc, ml)
    if ec == 0 {
      done = true
      continue
    }
    xr = nr
    bb = eb
    bc = ec

    let (sym, clen) = huff_decode(lt, bb & ((1 << lb) - 1))
    if clen == 0 || clen > bc {
      raise Failure::Failure("DEFLATE: bad lit code")
    }
    let (nb, nc, _) = consume(bb, bc, clen)
    bb = nb
    bc = nc

    if sym < 256 {
      // Literal byte
      out.write_byte(sym.to_byte())
    } else if sym == 256 {
      // End of block
      done = true
    } else {
      // Length code (257-285)
      let li = sym - 257
      if li >= 29 {
        raise Failure::Failure("DEFLATE: bad length")
      }
      let mut length = lbase[li]
      let ex = lextra[li]
      if ex > 0 {
        let (nr2, eb2, ec2) = ensure_bits(xr, bb, bc, ex)
        xr = nr2
        bb = eb2
        bc = ec2
        let (nb2, nc2, ev) = consume(bb, bc, ex)
        bb = nb2
        bc = nc2
        length = length + ev
      }

      // Distance code
      let (nr3, eb3, ec3) = ensure_bits(xr, bb, bc, db)
      xr = nr3
      bb = eb3
      bc = ec3
      let (dc, dcl) = huff_decode(dt, bb & ((1 << db) - 1))
      if dcl == 0 || dcl > bc {
        raise Failure::Failure("DEFLATE: bad dist code")
      }
      let (nb3, nc3, _) = consume(bb, bc, dcl)
      bb = nb3
      bc = nc3

      if dc >= 30 {
        raise Failure::Failure("DEFLATE: bad distance")
      }
      let mut dist = dbase[dc]
      let dex = dextra[dc]
      if dex > 0 {
        let (nr4, eb4, ec4) = ensure_bits(xr, bb, bc, dex)
        xr = nr4
        bb = eb4
        bc = ec4
        let (nb4, nc4, ev) = consume(bb, bc, dex)
        bb = nb4
        bc = nc4
        dist = dist + ev
      }

      // LZ77 back-reference copy
      let ol = out.length()
      if dist > ol {
        raise Failure::Failure("DEFLATE: dist>len")
      }
      let cs = ol - dist
      if dist >= length {
        // Non-overlapping: simple bulk copy
        for i = 0; i < length; i = i + 1 {
          out.write_byte(out.view()[cs + i])
        }
      } else {
        // Overlapping: copy in dist-sized chunks, advancing source each iteration
        // so that newly written bytes become the source for subsequent chunks
        let mut remaining = length
        let mut src_pos = cs
        while remaining > 0 {
          let chunk = if dist < remaining { dist } else { remaining }
          for i = 0; i < chunk; i = i + 1 {
            out.write_byte(out.view()[src_pos + i])
          }
          src_pos = src_pos + chunk
          remaining = remaining - chunk
        }
      }
    }
  }

  (xr, bb, bc)
}

///|
/// Read dynamic Huffman header for BTYPE=2 blocks
/// Returns the literal/length and distance Huffman decoders
fn read_dyn_header(
  r : BitReader,
) -> (BitReader, Int, Int, HDecoder, HDecoder) raise Failure {
  let mut xr = r
  let mut bb = 0
  let mut bc = 0

  // Read HLIT (5 bits), HDIST (5 bits), HCLEN (4 bits)
  let (nr, nb, nc) = ensure_bits(xr, bb, bc, 14)
  xr = nr
  bb = nb
  bc = nc
  let (b1, c1, hl) = consume(bb, bc, 5)
  let (b2, c2, hd) = consume(b1, c1, 5)
  let (b3, c3, hc) = consume(b2, c2, 4)
  bb = b3
  bc = c3

  let nl = hl + 257
  let nd = hd + 1
  let ncl = hc + 4

  if nl > 286 || nd > 30 {
    raise Failure::Failure("DEFLATE: too many codes")
  }

  // Read code length code lengths in clord order
  let cll = Array::make(19, 0)
  for i = 0; i < ncl; i = i + 1 {
    let (nr2, eb2, ec2) = ensure_bits(xr, bb, bc, 3)
    xr = nr2
    bb = eb2
    bc = ec2
    let (nb2, nc2, len) = consume(bb, bc, 3)
    bb = nb2
    bc = nc2
    cll[clord[i]] = len
  }

  // Build code length Huffman tree and decode literal/distance code lengths
  let clt = build_huffman(cll, 19)
  let cls = Array::make(nl + nd, 0)
  let mut i = 0

  while i < nl + nd {
    let (nr3, eb3, ec3) = ensure_bits(xr, bb, bc, huff_bits(clt))
    xr = nr3
    bb = eb3
    bc = ec3
    let (sym, cl) = huff_decode(clt, bb & ((1 << huff_bits(clt)) - 1))
    if cl == 0 {
      raise Failure::Failure("DEFLATE: bad cl code")
    }
    let (nb3, nc3, _) = consume(bb, bc, cl)
    bb = nb3
    bc = nc3

    if sym < 16 {
      cls[i] = sym
      i = i + 1
    } else if sym == 16 {
      // Repeat previous code length (3-6 times)
      if i == 0 {
        raise Failure::Failure("DEFLATE: rep with no prev")
      }
      let (nr4, eb4, ec4) = ensure_bits(xr, bb, bc, 2)
      xr = nr4
      bb = eb4
      bc = ec4
      let (nb4, nc4, ex) = consume(bb, bc, 2)
      bb = nb4
      bc = nc4
      let rp = ex + 3
      let pv = cls[i - 1]
      for j = 0; j < rp && i < nl + nd; j = j + 1 {
        cls[i] = pv
        i = i + 1
      }
    } else if sym == 17 {
      // Repeat zero (3-10 times)
      let (nr5, eb5, ec5) = ensure_bits(xr, bb, bc, 3)
      xr = nr5
      bb = eb5
      bc = ec5
      let (nb5, nc5, ex) = consume(bb, bc, 3)
      bb = nb5
      bc = nc5
      let rp = ex + 3
      for j = 0; j < rp && i < nl + nd; j = j + 1 {
        cls[i] = 0
        i = i + 1
      }
    } else {
      // Repeat zero (11-138 times)
      let (nr6, eb6, ec6) = ensure_bits(xr, bb, bc, 7)
      xr = nr6
      bb = eb6
      bc = ec6
      let (nb6, nc6, ex) = consume(bb, bc, 7)
      bb = nb6
      bc = nc6
      let rp = ex + 11
      for j = 0; j < rp && i < nl + nd; j = j + 1 {
        cls[i] = 0
        i = i + 1
      }
    }
  }

  // Split into literal/length and distance trees
  let lla = Array::make(nl, 0)
  for j = 0; j < nl; j = j + 1 {
    lla[j] = cls[j]
  }
  let dla = Array::make(nd, 0)
  for j = 0; j < nd; j = j + 1 {
    dla[j] = cls[nl + j]
  }

  (xr, bb, bc, build_huffman(lla, nl), build_huffman(dla, nd))
}

//-----------------------------------------------------------------------------
// zlib decompression wrapper (RFC 1950)
//-----------------------------------------------------------------------------

///|
/// Decompress zlib-wrapped DEFLATE data
/// zlib format: 2-byte header (CMF+FLG) + DEFLATE stream + 4-byte Adler32
fn zlib_decompress(data : Bytes) -> Bytes raise Failure {
  if data.length() < 6 {
    raise Failure::Failure("zlib: data too short")
  }

  // CMF (Compression Method and Flags)
  let cmf = data[0].to_int()
  let cm = cmf & 0x0F // Compression method
  let _cinfo = cmf >> 4 // Compression info (window size)

  // FLG (Flags)
  let flg = data[1].to_int()
  let fcheck = (cmf * 256 + flg) % 31

  // Verify header checksum
  if fcheck != 0 {
    raise Failure::Failure("zlib: header checksum mismatch")
  }

  // Only DEFLATE (CM=8) is supported
  if cm != 8 {
    raise Failure::Failure("zlib: unsupported compression method: \{cm}")
  }

  // Check for preset dictionary (FDICT flag)
  let fdict = (flg >> 5) & 1
  if fdict == 1 {
    raise Failure::Failure("zlib: preset dictionary not supported")
  }

  // Extract DEFLATE stream (skip 2-byte header, skip 4-byte Adler32 trailer)
  let deflate_data = data[2:data.length() - 4].to_owned()

  // Decompress
  let result = deflate_decompress(deflate_data)

  // Verify Adler32 (last 4 bytes of zlib stream, big-endian)
  let expected_adler = (data[data.length() - 4].to_int() << 24) |
    (data[data.length() - 3].to_int() << 16) |
    (data[data.length() - 2].to_int() << 8) |
    data[data.length() - 1].to_int()
  let actual_adler = adler32(result)
  if actual_adler != expected_adler {
    raise Failure::Failure("zlib: Adler32 checksum mismatch")
  }

  result
}

//-----------------------------------------------------------------------------
// PNG filter reversal
//-----------------------------------------------------------------------------

// PNG filter types

///|
const F_NONE : Int = 0

///|
const F_SUB : Int = 1

///|
const F_UP : Int = 2

///|
const F_AVG : Int = 3

///|
const F_PAETH : Int = 4

///|
/// Absolute value
fn abs_i(x : Int) -> Int {
  if x < 0 {
    -x
  } else {
    x
  }
}

///|
/// Paeth predictor: selects the neighbor (a=left, b=up, c=upper-left)
/// closest to a+b-c, used by PNG filter type 4
fn paeth(a : Int, b : Int, c : Int) -> Int {
  let p = a + b - c
  let pa = abs_i(p - a)
  let pb = abs_i(p - b)
  let pc = abs_i(p - c)
  if pa <= pb && pa <= pc {
    a
  } else if pb <= pc {
    b
  } else {
    c
  }
}

///|
/// Apply PNG filter reversal to a single row of pixel data
/// `ft` = filter type, `rd` = filtered row data, `prev` = previous unfiltered row
/// `row` = current row index, `bpp` = bytes per pixel, `arr` = output buffer
fn apply_filter(
  ft : Int,
  rd : Bytes,
  prev : Array[Byte],
  row : Int,
  bpp : Int,
  arr : Array[Byte],
  pitch : Int,
) -> Unit raise Failure {
  let ro = row * pitch
  let sl = rd.length()

  // Filter None: data is already unfiltered
  if ft == F_NONE {
    for i = 0; i < sl; i = i + 1 {
      arr[ro + i] = rd[i]
    }
    return ()
  }

  // Filter Sub: add left neighbor (already decoded in current row)
  if ft == F_SUB {
    let cf = if bpp < sl { bpp } else { sl }
    for i = 0; i < cf; i = i + 1 {
      arr[ro + i] = rd[i]
    }
    for i = bpp; i < sl; i = i + 1 {
      arr[ro + i] = ((rd[i].to_int() + arr[ro + i - bpp].to_int()) & 0xFF).to_byte()
    }
    return ()
  }

  // Filter Up: add pixel from previous row (no left neighbor needed)
  if ft == F_UP {
    for i = 0; i < sl; i = i + 1 {
      let raw = rd[i].to_int()
      let upv = if row > 0 && i < prev.length() { prev[i].to_int() } else { 0 }
      arr[ro + i] = ((raw + upv) & 0xFF).to_byte()
    }
    return ()
  }

  // Filter Average: average of left and up neighbors (no upper-left needed)
  if ft == F_AVG {
    for i = 0; i < sl; i = i + 1 {
      let raw = rd[i].to_int()
      let left = if i >= bpp { arr[ro + i - bpp].to_int() } else { 0 }
      let upv = if row > 0 && i < prev.length() { prev[i].to_int() } else { 0 }
      arr[ro + i] = ((raw + (left + upv) / 2) & 0xFF).to_byte()
    }
    return ()
  }

  // Filter Paeth: Paeth predictor (needs left, up, and upper-left)
  if ft == F_PAETH {
    for i = 0; i < sl; i = i + 1 {
      let raw = rd[i].to_int()
      let left = if i >= bpp { arr[ro + i - bpp].to_int() } else { 0 }
      let upv = if row > 0 && i < prev.length() { prev[i].to_int() } else { 0 }
      let ul = if row > 0 && i >= bpp && i < prev.length() {
        prev[i - bpp].to_int()
      } else {
        0
      }
      arr[ro + i] = ((raw + paeth(left, upv, ul)) & 0xFF).to_byte()
    }
    return ()
  }

  raise Failure::Failure("PNG: bad filter")
}

//-----------------------------------------------------------------------------
// PNG Decoder (non-interlaced, 8-bit grayscale/RGB/RGBA)
//-----------------------------------------------------------------------------

///|
/// PNG 8-byte file signature
let png_sig : Array[Byte] = [
  b'\x89', b'P', b'N', b'G', b'\r', b'\n', b'\x1A', b'\n',
]

///|
/// PNG color types
const PC_GRAY : Int = 0

///|
const PC_RGB : Int = 2

///|
const PC_IDX : Int = 3

///|
const PC_GA : Int = 4

///|
const PC_RGBA : Int = 6

///|
/// Check if a chunk type matches a 4-character code
fn chunk_is(b : Bytes, c0 : Byte, c1 : Byte, c2 : Byte, c3 : Byte) -> Bool {
  b.length() >= 4 && b[0] == c0 && b[1] == c1 && b[2] == c2 && b[3] == c3
}

///|
/// Bytes per pixel for a given color type (at 8-bit depth)
fn png_spp(ct : Int) -> Int {
  match ct {
    0 => 1
    2 => 3
    4 => 2
    6 => 4
    _ => 1
  }
}

///|
/// Output PixelFormat for a given color type
/// Indexed color outputs RGBA8 after palette expansion
fn out_fmt(ct : Int) -> PixelFormat {
  match ct {
    PC_GRAY => PixelFormat::Gray8
    PC_IDX => PixelFormat::RGBA8
    PC_GA => PixelFormat::GrayA8
    PC_RGB => PixelFormat::RGB8
    PC_RGBA => PixelFormat::RGBA8
    _ => PixelFormat::RGBA8
  }
}

///|
/// Adam7 interlacing parameters: (x_start, y_start, x_step, y_step)
let a7_params : Array[(Int, Int, Int, Int)] = [
  (0, 0, 8, 8),
  (4, 0, 8, 8),
  (0, 4, 4, 8),
  (2, 0, 4, 4),
  (0, 2, 2, 4),
  (1, 0, 2, 2),
  (0, 1, 1, 2),
]

///|
/// Compute sub-image dimensions for an Adam7 pass
fn a7dims(w : Int, h : Int, pass : Int) -> (Int, Int) {
  let (xs, ys, xst, yst) = a7_params[pass]
  (
    if w > xs {
      (w - 1 - xs) / xst + 1
    } else {
      0
    },
    if h > ys {
      (h - 1 - ys) / yst + 1
    } else {
      0
    },
  )
}

///|
/// Decode a PNG image from raw bytes
pub fn decode_png(data : Bytes) -> Image raise Failure {
  // Verify PNG signature
  if data.length() < 8 {
    raise Failure::Failure("PNG: too small")
  }
  for i = 0; i < 8; i = i + 1 {
    if data[i] != png_sig[i] {
      raise Failure::Failure("PNG: bad sig")
    }
  }

  let mut pos = 8
  let mut w = 0
  let mut h = 0
  let mut bd : Int = 0
  let mut ct : Int = 0
  let mut il : Int = 0
  let cd = Buffer()
  let mut hi = false // IHDR seen flag
  let mut pal = Array::make(0, Color::default())

  // Chunk parsing loop
  while pos < data.length() {
    if pos + 8 > data.length() {
      raise Failure::Failure("PNG: trunc chunk")
    }

    // Read chunk length (4 bytes, big-endian)
    let cl = read_u32_be(data, pos)
    pos = pos + 4

    // Read chunk type (4 bytes)
    let cbt = data[pos:pos + 4].to_owned()
    pos = pos + 4

    if pos + cl + 4 > data.length() {
      raise Failure::Failure("PNG: trunc chunk data")
    }

    // Read chunk data
    let cdat = data[pos:pos + cl].to_owned()
    pos = pos + cl

    // Read stored CRC
    let sc = read_u32_be(data, pos)
    pos = pos + 4

    // Verify CRC for critical chunks (uppercase first letter)
    let is_critical = (cbt[0].to_int() & 32) == 0
    if is_critical {
      let ccrc = crc32_chunk(cbt, cdat)
      if ccrc != sc {
        raise Failure::Failure("PNG: CRC mismatch")
      }
    }

    let ih = chunk_is(cbt, b'I', b'H', b'D', b'R')
    let id = chunk_is(cbt, b'I', b'D', b'A', b'T')
    let ie = chunk_is(cbt, b'I', b'E', b'N', b'D')
    let ip = chunk_is(cbt, b'P', b'L', b'T', b'E')

    if ih {
      // IHDR: image header
      if cl != 13 {
        raise Failure::Failure("PNG: IHDR len")
      }
      if hi {
        raise Failure::Failure("PNG: dup IHDR")
      }
      w = read_u32_be(cdat, 0)
      h = read_u32_be(cdat, 4)
      bd = cdat[8].to_int()
      ct = cdat[9].to_int()
      il = cdat[12].to_int()
      // Validate compression and filter method
      if cdat[10].to_int() != 0 {
        raise Failure::Failure("PNG: bad comp")
      }
      if cdat[11].to_int() != 0 {
        raise Failure::Failure("PNG: bad filt")
      }
      if il != 0 && il != 1 {
        raise Failure::Failure("PNG: bad interlace")
      }
      hi = true
    } else if id {
      // IDAT: image data
      if !hi {
        raise Failure::Failure("PNG: IDAT before IHDR")
      }
      cd.write_bytes(cdat)
    } else if ie {
      // IEND: image end
      break
    } else if ip {
      // PLTE: palette
      if cl % 3 != 0 {
        raise Failure::Failure("PNG: PLTE len")
      }
      let n = cl / 3
      pal = Array::make(n, Color::default())
      for i = 0; i < n; i = i + 1 {
        let o = i * 3
        pal[i] = Color::new(
          cdat[o].to_int(),
          cdat[o + 1].to_int(),
          cdat[o + 2].to_int(),
          255,
        )
      }
    }
  }

  if !hi {
    raise Failure::Failure("PNG: no IHDR")
  }
  if w <= 0 || h <= 0 {
    raise Failure::Failure("PNG: bad dims")
  }

  // Validate color type + bit depth combination
  let vok = match ct {
    PC_GRAY => bd == 1 || bd == 2 || bd == 4 || bd == 8 || bd == 16
    PC_RGB => bd == 8 || bd == 16
    PC_IDX => bd == 1 || bd == 2 || bd == 4 || bd == 8
    PC_GA => bd == 8 || bd == 16
    PC_RGBA => bd == 8 || bd == 16
    _ => false
  }
  if !vok {
    raise Failure::Failure("PNG: bad color/depth")
  }

  // zlib decompress all IDAT data
  let dec = zlib_decompress(cd.to_bytes())

  // Decode (interlaced or non-interlaced)
  if il == 1 {
    decode_a7(w, h, bd, ct, pal, dec)
  } else {
    decode_plain(w, h, bd, ct, pal, dec)
  }
}

///|
/// Decode a non-interlaced PNG image from decompressed filtered data
fn decode_plain(
  w : Int,
  h : Int,
  bd : Int,
  ct : Int,
  pal : Array[Color],
  dec : Bytes,
) -> Image raise Failure {
  let sp = png_spp(ct)
  let bpp = sp * (if bd >= 8 { bd / 8 } else { 1 })
  let pitch = if bd < 8 { (w * bd * sp + 7) / 8 } else { w * bpp }
  let ssl = if bd >= 8 { w * bpp + 1 } else { (w * bd * sp + 7) / 8 + 1 }

  let arr = Array::make(w * h * bpp, b'\x00')
  let prev = Array::make(pitch, b'\x00')

  for y = 0; y < h; y = y + 1 {
    let rs = y * ssl
    if rs + ssl > dec.length() {
      raise Failure::Failure("PNG: short row")
    }
    let ft = dec[rs].to_int()
    let rd = dec[rs + 1:rs + ssl].to_owned()

    apply_filter(ft, rd, prev, y, bpp, arr, pitch)

    // Save current row as previous for next iteration
    let ro = y * pitch
    for x = 0; x < pitch && ro + x < arr.length(); x = x + 1 {
      prev[x] = arr[ro + x]
    }
  }

  let raw = Bytes::from_array(arr)
  let fb = if ct == PC_IDX && pal.length() > 0 {
    idx2rgba(raw, w, h, bd, pal)
  } else {
    raw
  }
  Image::new(w, h, out_fmt(ct), fb)
}

///|
/// Decode an Adam7 interlaced PNG image
fn decode_a7(
  w : Int,
  h : Int,
  bd : Int,
  ct : Int,
  pal : Array[Color],
  dec : Bytes,
) -> Image raise Failure {
  let sp = png_spp(ct)
  let bpp = if bd >= 8 { sp * bd / 8 } else { 1 }
  let oarr = Array::make(w * h * bpp, b'\x00')
  let mut sp_off = 0

  for pass = 0; pass < 7; pass = pass + 1 {
    let (pw, ph) = a7dims(w, h, pass)
    if pw == 0 || ph == 0 {
      continue
    }

    let (xs, ys, xst, yst) = a7_params[pass]
    let ppitch = if bd < 8 { (pw * bd * sp + 7) / 8 } else { pw * bpp }
    let psl = if bd >= 8 { pw * bpp + 1 } else { (pw * bd * sp + 7) / 8 + 1 }

    let parr = Array::make(ph * ppitch, b'\x00')
    let prev = Array::make(ppitch, b'\x00')

    for y = 0; y < ph; y = y + 1 {
      if sp_off + psl > dec.length() {
        raise Failure::Failure("PNG: short a7")
      }
      let ft = dec[sp_off].to_int()
      let rd = dec[sp_off + 1:sp_off + psl].to_owned()
      sp_off = sp_off + psl

      apply_filter(ft, rd, prev, y, bpp, parr, ppitch)

      let ro = y * ppitch
      for x = 0; x < ppitch && ro + x < parr.length(); x = x + 1 {
        prev[x] = parr[ro + x]
      }
    }

    // Scatter pass pixels to output image
    for py = 0; py < ph; py = py + 1 {
      let oy = ys + py * yst
      for px = 0; px < pw; px = px + 1 {
        let ox = xs + px * xst
        for b = 0; b < bpp; b = b + 1 {
          let si = py * ppitch + px * bpp + b
          let di = oy * (w * bpp) + ox * bpp + b
          if si < parr.length() && di < oarr.length() {
            oarr[di] = parr[si]
          }
        }
      }
    }
  }

  let raw = Bytes::from_array(oarr)
  let fb = if ct == PC_IDX && pal.length() > 0 {
    idx2rgba(raw, w, h, bd, pal)
  } else {
    raw
  }
  Image::new(w, h, out_fmt(ct), fb)
}

///|
/// Convert indexed pixel data to RGBA using a palette
/// Pre-computes palette as RGBA byte quads to avoid per-pixel to_byte() calls
fn idx2rgba(
  data : Bytes,
  w : Int,
  h : Int,
  bd : Int,
  pal : Array[Color],
) -> Bytes raise Failure {
  let nc = pal.length()
  let n = w * h
  let arr = Array::make(n * 4, b'\x00')

  // Pre-compute palette as RGBA byte quads (eliminates per-pixel to_byte + struct field access)
  let pal_bytes = Array::make(nc, [b'\x00', b'\x00', b'\x00', b'\xFF'])
  for i = 0; i < nc; i = i + 1 {
    let c = pal[i]
    pal_bytes[i] = [c.r.to_byte(), c.g.to_byte(), c.b.to_byte(), c.a.to_byte()]
  }
  let default_bytes = [b'\x00', b'\x00', b'\x00', b'\xFF']

  if bd == 8 {
    for i = 0; i < n; i = i + 1 {
      let idx = data[i].to_int()
      let c = if idx < nc { pal_bytes[idx] } else { default_bytes }
      let d = i * 4
      arr[d] = c[0]
      arr[d + 1] = c[1]
      arr[d + 2] = c[2]
      arr[d + 3] = c[3]
    }
  } else if bd == 4 {
    for i = 0; i < n; i = i + 1 {
      let bv = data[i / 2].to_int()
      let idx = if i % 2 == 0 { (bv >> 4) & 0xF } else { bv & 0xF }
      let c = if idx < nc { pal_bytes[idx] } else { default_bytes }
      let d = i * 4
      arr[d] = c[0]
      arr[d + 1] = c[1]
      arr[d + 2] = c[2]
      arr[d + 3] = c[3]
    }
  } else if bd == 2 {
    for i = 0; i < n; i = i + 1 {
      let bv = data[i / 4].to_int()
      let idx = (bv >> (6 - i % 4 * 2)) & 0x3
      let c = if idx < nc { pal_bytes[idx] } else { default_bytes }
      let d = i * 4
      arr[d] = c[0]
      arr[d + 1] = c[1]
      arr[d + 2] = c[2]
      arr[d + 3] = c[3]
    }
  } else if bd == 1 {
    for i = 0; i < n; i = i + 1 {
      let idx = (data[i / 8].to_int() >> (7 - i % 8)) & 1
      let c = if idx < nc { pal_bytes[idx] } else { default_bytes }
      let d = i * 4
      arr[d] = c[0]
      arr[d + 1] = c[1]
      arr[d + 2] = c[2]
      arr[d + 3] = c[3]
    }
  } else {
    raise Failure::Failure("PNG: bad idx depth")
  }
  Bytes::from_array(arr)
}
