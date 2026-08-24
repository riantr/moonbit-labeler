// Benchmark suite — runs as part of `moon test`. Each test prints
// timing metrics to stdout in `BENCH <label> <metric>=<value>` lines
// so the docs/benchmark.md collection script can scrape them.
//
// We intentionally keep this as a `_blackbox_test.mbt` so it sees the
// public @image.* API only (same as production code paths).
//
// Fixtures are synthesized inline so we don't need to touch the
// async-only `@fs.read_file` API. Real-file benchmarks can be layered
// on top later via a Python driver script.
//
// Timing: we wrap `Bench` and call `Bench::bench(...)` repeatedly,
// then `Bench::dump_summaries()` produces a JSON blob. We parse out
// the mean/min/max fields and emit them as `BENCH ...` lines.

// ---------------------------------------------------------------------------
// Inline byte helpers
// ---------------------------------------------------------------------------

///|
fn bmk_to_bytes(raw : Array[Int]) -> Bytes {
  let arr = Array::make(raw.length(), b'\x00')
  for i = 0; i < raw.length(); i = i + 1 {
    arr[i] = raw[i].to_byte()
  }
  Bytes::from_array(arr)
}

///|
fn bmk_append(arr : Array[Int], v : Int) -> Unit {
  arr.push(v)
}

// ---------------------------------------------------------------------------
// Fixture builders
// ---------------------------------------------------------------------------

///|
fn bmk_bmp(width : Int, height : Int, seed : Int) -> Bytes {
  let row_bytes = (width * 4 + 3) / 4 * 4
  let pix_bytes = row_bytes * height
  let file_size = 14 + 40 + pix_bytes
  let out : Array[Int] = []
  bmk_append(out, 0x42)
  bmk_append(out, 0x4D)
  let mut s = file_size
  bmk_append(out, s & 0xFF)
  s = s >> 8
  bmk_append(out, s & 0xFF)
  s = s >> 8
  bmk_append(out, s & 0xFF)
  s = s >> 8
  bmk_append(out, s & 0xFF)
  for _ in 0..<4 {
    bmk_append(out, 0)
  }
  bmk_append(out, 54)
  bmk_append(out, 0)
  bmk_append(out, 0)
  bmk_append(out, 0)
  bmk_append(out, 40)
  for _ in 0..<3 {
    bmk_append(out, 0)
  }
  let w1 = width & 0xFF
  let w2 = (width >> 8) & 0xFF
  let w3 = (width >> 16) & 0xFF
  let w4 = (width >> 24) & 0xFF
  bmk_append(out, w1)
  bmk_append(out, w2)
  bmk_append(out, w3)
  bmk_append(out, w4)
  let h1 = height & 0xFF
  let h2 = (height >> 8) & 0xFF
  let h3 = (height >> 16) & 0xFF
  let h4 = (height >> 24) & 0xFF
  bmk_append(out, h1)
  bmk_append(out, h2)
  bmk_append(out, h3)
  bmk_append(out, h4)
  bmk_append(out, 1)
  bmk_append(out, 0)
  bmk_append(out, 32)
  bmk_append(out, 0)
  for _ in 0..<24 {
    bmk_append(out, 0)
  }
  for y in 0..<height {
    for x in 0..<width {
      let r = ((x + seed) * 7 + y * 13) & 0xFF
      let g = ((x + seed) * 11 + y * 17) & 0xFF
      let b = ((x + seed) * 19 + y * 23) & 0xFF
      bmk_append(out, b)
      bmk_append(out, g)
      bmk_append(out, r)
      bmk_append(out, 0xFF)
    }
    let pad = row_bytes - width * 4
    for _ in 0..<pad {
      bmk_append(out, 0)
    }
  }
  bmk_to_bytes(out)
}

///|
fn bmk_qoi(width : Int, height : Int, seed : Int) -> Bytes {
  let out : Array[Int] = []
  for c in "qoif" {
    bmk_append(out, c.to_int())
  }
  let w1 = (width >> 24) & 0xFF
  let w2 = (width >> 16) & 0xFF
  let w3 = (width >> 8) & 0xFF
  let w4 = width & 0xFF
  bmk_append(out, w1)
  bmk_append(out, w2)
  bmk_append(out, w3)
  bmk_append(out, w4)
  let h1 = (height >> 24) & 0xFF
  let h2 = (height >> 16) & 0xFF
  let h3 = (height >> 8) & 0xFF
  let h4 = height & 0xFF
  bmk_append(out, h1)
  bmk_append(out, h2)
  bmk_append(out, h3)
  bmk_append(out, h4)
  bmk_append(out, 4)
  bmk_append(out, 1)
  bmk_append(out, 0xFE)
  let r0 = (seed * 7) & 0xFF
  let g0 = (seed * 11) & 0xFF
  let b0 = (seed * 19) & 0xFF
  bmk_append(out, r0)
  bmk_append(out, g0)
  bmk_append(out, b0)
  for _ in 1..<(width * height) {
    bmk_append(out, 0x00)
  }
  for _ in 0..<7 {
    bmk_append(out, 0)
  }
  bmk_append(out, 1)
  bmk_to_bytes(out)
}

///|
fn bmk_gif(width : Int, height : Int, seed : Int) -> Bytes {
  let out : Array[Int] = []
  for c in "GIF89a" {
    bmk_append(out, c.to_int())
  }
  bmk_append(out, width & 0xFF)
  bmk_append(out, (width >> 8) & 0xFF)
  bmk_append(out, height & 0xFF)
  bmk_append(out, (height >> 8) & 0xFF)
  bmk_append(out, 0b10000000)
  bmk_append(out, 0)
  bmk_append(out, 0)
  let r0 = (seed * 7) & 0xFF
  let g0 = (seed * 11) & 0xFF
  let b0 = (seed * 19) & 0xFF
  bmk_append(out, r0)
  bmk_append(out, g0)
  bmk_append(out, b0)
  bmk_append(out, 0xFF - r0)
  bmk_append(out, 0xFF - g0)
  bmk_append(out, 0xFF - b0)
  bmk_append(out, 0x2C)
  for _ in 0..<4 {
    bmk_append(out, 0)
  }
  bmk_append(out, width & 0xFF)
  bmk_append(out, (width >> 8) & 0xFF)
  bmk_append(out, height & 0xFF)
  bmk_append(out, (height >> 8) & 0xFF)
  bmk_append(out, 0)
  bmk_append(out, 2)
  bmk_append(out, 2)
  bmk_append(out, 0b10000000)
  bmk_append(out, 0b00000000)
  bmk_append(out, 0)
  bmk_append(out, 0x3B)
  bmk_to_bytes(out)
}

///|
fn bmk_hex_digit(c : Int) -> Int {
  if c >= 0x30 && c <= 0x39 {
    c - 0x30
  } else if c >= 0x41 && c <= 0x46 {
    c - 0x41 + 10
  } else if c >= 0x61 && c <= 0x66 {
    c - 0x61 + 10
  } else {
    0
  }
}

///|
fn bmk_png_32_rgba() -> Bytes {
  // 108-byte 32x32 RGBA PNG generated by PIL with deterministic
  // content (solid red). Hex blob captured from
  // `python -c "from PIL import Image; Image.new('RGBA', (32,32),
  // (255,0,0,255)).save(...)"`.
  let hex =
    "89504E470D0A1A0A0000000D4948445200000020000000200806000000737A7AF40000003349444154789CEDD0410D00000803B1817FCF1054F0E90CDCD29A64F2B8FE8C3B408000010204081020408000010204089CC00230E3023EF1BDF9C20000000049454E44AE426082"
  let bytes : Array[Int] = []
  let mut i = 0
  while i < hex.length() {
    let hi = bmk_hex_digit(hex[i:i + 2][0].to_int())
    let lo = bmk_hex_digit(hex[i:i + 2][1].to_int())
    bytes.push((hi * 16 + lo) & 0xFF)
    i = i + 2
  }
  bmk_to_bytes(bytes)
}

// ---------------------------------------------------------------------------
// Timing helpers — emit `BENCH <label> <metric>=<value>` lines via
// `Bench::dump_summaries`, which produces a JSON array of summaries.
// ---------------------------------------------------------------------------

///|
fn run_decode_bench(label : String, bytes : Bytes) -> Unit {
  let bench = @bench.Bench::Bench()
  bench.bench(
    name=label,
    fn() {
      let _ = try? @image.decode(bytes)
    },
    count=20,
  )
  let json = bench.dump_summaries()
  println("BENCH_JSON decode " + label + " " + json)
}

///|
fn run_encode_bench(label : String, img : @image.Image) -> Unit {
  let bench = @bench.Bench::Bench()
  bench.bench(
    name=label,
    fn() {
      let _ = try? @image.encode_bmp(img)
    },
    count=20,
  )
  let json = bench.dump_summaries()
  println("BENCH_JSON encode_bmp " + label + " " + json)
  let bench2 = @bench.Bench::Bench()
  bench2.bench(
    name=label + "_qoi",
    fn() {
      let _ = try? @image.encode_qoi(img)
    },
    count=50,
  )
  let json2 = bench2.dump_summaries()
  println("BENCH_JSON encode_qoi " + label + " " + json2)
}

///|
fn run_metadata_bench(label : String, bytes : Bytes) -> Unit {
  let bench = @bench.Bench::Bench()
  bench.bench(
    name=label,
    fn() {
      let _ = @image.detect_format(bytes)
    },
    count=200,
  )
  let json = bench.dump_summaries()
  println("BENCH_JSON detect " + label + " " + json)
  let bench2 = @bench.Bench::Bench()
  bench2.bench(
    name=label + "_dims",
    fn() {
      let _ = try? @image.image_dimensions(bytes)
    },
    count=200,
  )
  let json2 = bench2.dump_summaries()
  println("BENCH_JSON dims " + label + " " + json2)
}

///|
fn run_ratio_bench(label : String, bytes : Bytes) -> Unit raise {
  let img = @image.decode(bytes) catch { _ => fail("decode failed for ratio") }
  let in_b = bytes.length()
  let out_b = img.data.length()
  let ratio = bmk_format_f64(out_b.to_double() / in_b.to_double(), 3)
  println(
    "RATIO " +
    label +
    " in_bytes=" +
    in_b.to_string() +
    " out_bytes=" +
    out_b.to_string() +
    " ratio=" +
    ratio +
    " width=" +
    img.width.to_string() +
    " height=" +
    img.height.to_string() +
    " format=" +
    @image.pixel_format_name(img.format),
  )
}

///|
fn bmk_format_f64(v : Double, places : Int) -> String {
  let mut mul = 1
  for i = 0; i < places; i = i + 1 {
    mul = mul * 10
  }
  let scaled = (v * mul.to_double()).to_int64()
  let whole = scaled / mul.to_int64()
  let frac_raw = scaled % mul.to_int64()
  // Pad frac to `places` digits
  let mut frac_str = frac_raw.to_string()
  while frac_str.length() < places {
    frac_str = "0" + frac_str
  }
  whole.to_string() + "." + frac_str
}

// ---------------------------------------------------------------------------
// Top-level benchmark tests
// ---------------------------------------------------------------------------

///|
test "bench/decode_per_format" {
  run_decode_bench("bmp_32_rgba", bmk_bmp(32, 32, 7))
  run_decode_bench("bmp_64_rgba", bmk_bmp(64, 64, 11))
  run_decode_bench("bmp_256_rgba", bmk_bmp(256, 256, 13))
  run_decode_bench("png_32_rgba", bmk_png_32_rgba())
  run_decode_bench("qoi_64_rgba", bmk_qoi(64, 64, 17))
  run_decode_bench("qoi_256_rgba", bmk_qoi(256, 256, 19))
  // GIF synthesis is fragile (LZW minimum code size + bit packing);
  // skip in synthetic mode and rely on the gherkin_blackbox_test.mbt
  // suite for GIF coverage.
}

///|
test "bench/encode_per_format" {
  let src = bmk_bmp(32, 32, 7)
  let img = @image.decode(src) catch { _ => fail("decode failed") }
  let px = img.width * img.height
  run_encode_bench("img_" + px.to_string() + "px", img)
}

///|
test "bench/metadata_throughput" {
  run_metadata_bench("png_32_rgba", bmk_png_32_rgba())
  run_metadata_bench("bmp_256_rgba", bmk_bmp(256, 256, 13))
  run_metadata_bench("qoi_256_rgba", bmk_qoi(256, 256, 19))
}

///|
test "bench/memory_ratio" {
  run_ratio_bench("bmp_32_rgba", bmk_bmp(32, 32, 7))
  run_ratio_bench("bmp_256_rgba", bmk_bmp(256, 256, 13))
  run_ratio_bench("png_32_rgba", bmk_png_32_rgba())
  run_ratio_bench("qoi_64_rgba", bmk_qoi(64, 64, 17))
  run_ratio_bench("qoi_256_rgba", bmk_qoi(256, 256, 19))
  // GIF synthesis is unreliable; the gherkin suite covers GIF ratios.
}
