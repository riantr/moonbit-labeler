# Mutation testing analysis for riantr/moonbit_labeler

MoonBit 0.1.x does not ship a mutation testing framework (e.g.
`mutmut`, `cargo-mutants`, `Stryker`), and hand-applying mutations to
`*.mbt` source files would cost more in review than it returns for a
library this size. Instead this document lists the highest-value
mutations we *would* apply, and grades each on whether the current test
suite (labeler 29 + gherkin 10 = 39 tests) actually catches it.

## Mutation catalogue

Each entry has:
- **Operator**: the syntax change we would apply
- **Expected effect**: which test(s) should catch it (kill the mutant)
- **Survives?**: yes if no test would fail; the higher the impact the
  larger the gap

---

### M1 — BMP `BGR → RGB` channel swap

```moonbit
// extensions/image/bmp.mbt  BmpDecoder::decode_24bit
// before:
_buf[dst] = self.data[src + 2] // R
// after:
_buf[dst] = self.data[src]     // B (was R)
```

- **Impact**: every 24-bit BMP would render in swapped colours (R↔B).
- **Expected kill**: `lib_test.mbt` `BMP round-trip preserves pixel data`
  (asserts first/last pixel RGB matches the fixture's red bytes).
- **Survives?** no — this test would flip red → blue and fail.

### M2 — BMP top-down height sign flip

```moonbit
// extensions/image/bmp.mbt  BmpDecoder::new
// before:
let top_down = height_raw < 0
// after:
let top_down = height_raw > 0
```

- **Impact**: top-down BMP images would render upside-down.
- **Expected kill**: any image_dimensions / decode test against a
  top-down BMP fixture. The current suite has **no top-down BMP
  fixture** — every `bmp_1x1_*` fixture is bottom-up (height > 0).
- **Survives?** **yes** ⚠️ — this is a real gap. Adding a top-down BMP
  fixture would close it.

### M3 — JPEG YCbCr→RGB coefficient rounding

```moonbit
// extensions/image/jpeg.mbt  ycbcr_to_rgb
// before:
let r = y + ((5743 * cr_off + 2048) >> 12)
// after:
let r = y + (5743 * cr_off >> 12)
```

- **Impact**: red channel loses 1 unit of precision (the rounding
  bias `+ 2048` is gone). For most pixels the result is identical
  (off-by-one in 0..1 step). For ~0.5% of pixels the rounded value
  changes by 1.
- **Expected kill**: a JPEG colour-sensitive test. We have `decode_jpeg`
  exercised via the round-trip smoke test but it only checks width /
  height, not pixel values.
- **Survives?** **yes** ⚠️ — would need a JPEG round-trip with strict
  per-pixel equality.

### M4 — PNG IDCT `+ 2048` rounding bias removed

Same shape as M3 but for IDCT precision. Currently no IDCT-sensitive
white-box test exercises the high-frequency coefficients.
- **Survives?** yes ⚠️

### M5 — `detect_format` misses BMP

```moonbit
// extensions/image/lib.mbt  detect_format
// before:
if data.length() >= 2 && data[0] == b'B' && data[1] == b'M' {
// after:
if data.length() >= 2 && data[0] == b'B' && data[1] == b'X' {
```

- **Impact**: every BMP image would now report `None` and the public
  `decode()` would raise `UnsupportedFormat`.
- **Expected kill**: `gherkin_blackbox_test.mbt` `BMP signature is
  detected` and `lib_test.mbt` `image_dimensions reads BMP header` and
  every BMP round-trip test.
- **Survives?** no — multiple tests would catch it.

### M6 — `encode_bmp` drops the 14-byte file header

```moonbit
// extensions/image/bmp_writer.mbt  encode_bmp
// before: write_bmp_file_header then row data
// after: write row data directly
```

- **Impact**: the encoded buffer would be 14 bytes shorter and start
  with `0x28 0x00` (DIB header) instead of `B M ...`. `decode_bmp`
  would then fail with `Failure: BMP: invalid signature`.
- **Expected kill**: `lib_test.mbt` `BMP round-trip preserves pixel
  data` and `gherkin_blackbox_test.mbt` `BMP round-trip preserves
  dimensions`.
- **Survives?** no.

---

## Summary

| Mutation | Catches? | Severity |
|----------|----------|----------|
| M1 BMP channel swap | yes | medium |
| **M2 top-down BMP height flip** | **NO** ⚠️ | **medium** |
| **M3 JPEG YCbCr rounding** | **NO** ⚠️ | **low** |
| **M4 PNG IDCT rounding** | **NO** ⚠️ | **low** |
| M5 detect_format BMP miss | yes | high |
| M6 encode_bmp header drop | yes | high |

## Action items (next session)

1. Add a top-down BMP fixture (`bmp_topdown_8x8.bmp` with negative
   height in the DIB header) and an assertion that decode() preserves
   row order. Closes M2.
2. Add a JPEG round-trip with per-pixel equality (lossless JFIF mode
   so the output is bit-exact). Closes M3.
3. Add a synthetic 8x8 PNG that exercises non-trivial IDCT
   coefficients (e.g. alternating checkerboard) and assert pixel
   values match the source. Closes M4.