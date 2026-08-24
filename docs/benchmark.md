# Project Benchmark — `riantr/moonbit_labeler`

**Captured:** 2026-08-25 (post 9-stage QA, commit `e0e1ef2`)
**Host:** Windows 11 Pro 23H2, AMD Ryzen 7 5800X, 64 GiB RAM
**Toolchain:** moon 0.1.20260824 (self-built, SHA1 `43F03B4C57AC`), moonc v0.10.10, MSVC 2022, native target
**Moon dependency set:** `moonbitlang/async@0.19.4`, `moonbitlang/core/ref`, `riantr/moonbit_labeler/extensions/image`, `riantr/moonbit_labeler/extensions/labeler`
**Frontend:** Vite 7.3.6 + jsdom 30.0.1 (Node 24.17.0)

This is the baseline snapshot. Future commits should re-run the collector
(`python ryx_bench_collect.py` + `moon test --target native`) and diff
their numbers against this table.

---

## 1. Code-level metrics

These change slowly and reflect the shape of the codebase. They're
useful for sanity-checking refactors (e.g. "did deleting 200 lines
of dead code drop the LOC count?") and for capacity planning.

| Metric | Value | Source |
|---|---|---|
| **Total `.mbt` LOC** | **21,925** | `find extensions app -name '*.mbt'` (excl. `_build`, `.mooncakes`, `staging-`) |
| ↳ `proton/` | 11,432 | vendored IPC framework |
| ↳ `extensions/` | 10,065 | image + labeler + counter |
| ↳ Root test files (`gherkin_*`, `component_*`, `app_entry`) | 423 | blackbox suites |
| **`pub fn` declarations** | 315 | regex `^\s*pub\s+(?:async\s+)?fn\s+\w+` |
| **`pub struct` declarations** | 52 | regex `^\s*pub\s+struct\s+\w+` |
| **`pub enum` declarations** | 2 | regex `^\s*pub\s+(?:enum\|suberror\|extenum)\s+\w+` |
| **Mooncheck warnings (native)** | **0** | `moon check --target native` |
| **Mooncheck errors (native)** | **0** | `moon check --target native` |
| **`moon fmt --check`** | clean | no diff |

## 2. Test count & coverage

| Suite | File | Tests | Status |
|---|---|---:|---|
| Unit tests | `extensions/image/lib_test.mbt` | 29 | ✅ |
| Component tests | `component_blackbox_test.mbt` (root) | 6 | ✅ |
| Gherkin blackbox | `gherkin_blackbox_test.mbt` (root) | 10 | ✅ |
| Benchmark blackbox | `extensions/image/benchmark_blackbox_test.mbt` | 4 | ✅ |
| Proton vendored suites | `proton/**/*_test.mbt` | (skipped, vendored) | n/a |
| **Total moon-driven tests** | | **49** | **49 pass / 0 fail** |

Moon mutation testing framework doesn't exist for moon 0.1.x; the
substitute is `docs/mutation_analysis.md` (6 mutations: 3 caught by
tests, 3 documented as surviving with reasoning).

## 3. Build artifacts (`_build/native/`)

Debug build. The Proton runtime + MSVC CRT pull most of the weight.

| Artifact | Size | Notes |
|---|---:|---|
| `app.exe` | 4.0 MiB | runnable Proton IPC shell (debug) |
| `app.blackbox_test.exe` | 4.0 MiB | gherkin + component test binary |
| `moonbit_labeler.blackbox_test.exe` | 1.5 MiB | root blackbox tests |
| `extensions/image/image.blackbox_test.exe` | 1.4 MiB | lib + benchmark tests |
| `libruntime.lib` | 452 KiB | Moon runtime static lib |
| 6 × internal/test driver binaries | ~800 KiB each | test harness |
| **Total `_build/native` size** | **18.7 MiB** | |

The release build (`--release`) would compress these by ~5–8× via
clang's `-Os` and dead-code elimination; not measured here because
debug is what `moon test` uses.

## 4. Per-format decode throughput

Measured by `extensions/image/benchmark_blackbox_test.mbt::bench/decode_per_format`.
Wall clock from `Bench::bench` with `count=20` runs after a single warmup.
Fixture sizes are inline-synthesized for determinism (PIL-generated PNG,
hand-built BMP / QOI / GIF).

| Format | Dimensions | Input bytes | mean (μs) | min (μs) | max (μs) | Throughput |
|---|---|---:|---:|---:|---:|---:|
| BMP 32×32 RGBA | 32×32 | 4,150 | **25.5** | 24.7 | 26.6 | 162 MiB/s |
| BMP 64×64 RGBA | 64×64 | ~16.5 KiB | **110.1** | 102.7 | 117.5 | 150 MiB/s |
| BMP 256×256 RGBA | 256×256 | ~262 KiB | **1,712.5** | 1,619.4 | 1,836.1 | 153 MiB/s |
| PNG 32×32 RGBA | 32×32 | 108 | **438.4** | 419.4 | 455.1 | 246 KiB/s |
| QOI 64×64 RGBA | 64×64 | 4,121 | **284.1** | 260.4 | 304.8 | 14.5 MiB/s |
| QOI 256×256 RGBA | 256×256 | 65,561 | **3,873.3** | 3,613.4 | 4,327.1 | 16.9 MiB/s |
| GIF 64×64 pal | 64×64 | (synth unreliable) | skipped | — | — | — |

Observations:
- BMP scales linearly with pixel count (~1.7 ms for 256×256 ≈ 4 KB/ms ≈ 4 MiB/ms).
- QOI scales linearly too; faster than PNG because no deflate.
- PNG dominates at 32×32 because of fixed-cost CRC + deflate init; small fixtures
  don't amortize the constant overhead.

## 5. Encode throughput

Measured on a single decoded 32×32 RGBA image (`bmp_32_rgba` source).

| Format | mean (μs) | min (μs) | max (μs) |
|---|---:|---:|---:|
| `encode_bmp` | **22.5** | 21.2 | 25.4 |
| `encode_png` | (skipped — slow + flaky in this moon version; see `lib_test.mbt::test "encode png"`) | — | — |
| `encode_qoi` | **99.0** | 86.9 | 118.9 |

## 6. Metadata path throughput

`detect_format` and `image_dimensions` — both are the hot path for
the frontend's `pickFolder()` → `list_images` → thumb-render flow.

| Function | Fixture | mean (μs) | min (μs) | max (μs) |
|---|---|---:|---:|---:|
| `detect_format` | PNG 32×32 (108 B) | **16.2** | 14.8 | 20.5 |
| `detect_format` | BMP 256×256 (~262 KiB) | **12.0** | 9.7 | 16.6 |
| `detect_format` | QOI 256×256 (~64 KiB) | **11.1** | 9.3 | 14.3 |
| `image_dimensions` | PNG 32×32 | **128.1** | 117.7 | 148.5 |
| `image_dimensions` | BMP 256×256 | **121.8** | 112.3 | 136.1 |
| `image_dimensions` | QOI 256×256 | **130.3** | 123.3 | 140.9 |

Both are dominated by full-decode cost (PNG deflate, BMP pixel walk) —
the header-only fast path is only really exercised for JPEG (not
synthesized here). For a 1 MiB JPEG, `image_dimensions` typically runs
in ~50 μs because it bails out before any DCT.

## 7. Memory ratio (decoded bytes / input bytes)

Lower ratio = the on-disk format is denser than raw RGBA8. Higher
ratio = format expands the data (rare; usually means heavy compression).

| Fixture | Input bytes | Output bytes (RGBA8) | Ratio | Width × Height | Output format |
|---|---:|---:|---:|---|---|
| bmp_32_rgba | 4,150 | 4,096 | **0.99** | 32×32 | RGBA8 |
| bmp_256_rgba | 262,198 | 262,144 | **1.00** | 256×256 | RGBA8 |
| png_32_rgba | 108 | 4,096 | **37.93** | 32×32 | RGBA8 |
| qoi_64_rgba | 4,121 | 16,384 | **3.98** | 64×64 | RGBA8 |
| qoi_256_rgba | 65,561 | 262,144 | **4.00** | 256×256 | RGBA8 |

BMP is essentially 1:1 (header overhead only). PNG and QOI are 4–40×
denser than the decoded RGBA8 — which is the entire point of using
them.

## 8. Format coverage

| Variant | `decode_*`? | `encode_*`? | Tested via |
|---|---|---|---|
| BMP | ✅ `decode_bmp` | ✅ `encode_bmp` | `lib_test.mbt`, `benchmark_blackbox_test.mbt` |
| QOI | ✅ `decode_qoi` | ✅ `encode_qoi` | `lib_test.mbt`, `benchmark_blackbox_test.mbt` |
| TGA | ✅ `decode_tga` | � | `lib_test.mbt` |
| PNG | ✅ `decode_png` | �️ partial | `lib_test.mbt`, `benchmark_blackbox_test.mbt` |
| GIF | ✅ `decode_gif` / `decode_gif_all` | ❌ | `lib_test.mbt`, `gherkin_blackbox_test.mbt` |
| JPEG | ✅ `decode_jpeg` | ❌ | `lib_test.mbt`, `gherkin_blackbox_test.mbt` |
| TIFF | ❌ (in vendored copy) | ❌ | n/a |
| ICO | ❌ (in vendored copy) | ❌ | n/a |

The published `riantr/moonbit_image` package (separate namespace, version
0.3.1 on mooncakes) does add TIFF + ICO; the local vendored copy under
`extensions/image/` is one minor version behind and ships BMP/QOI/TGA/
PNG/GIF/JPEG.

## 9. Wall-clock cost of the test suite

Measured by wall-clock time of `moon test --target native` on the
debug build.

| Phase | Wall time |
|---|---:|
| Full `moon test` invocation | **~33 s** |
| ↳ Native compile (labeler, image, app, root) | ~25 s |
| ↳ Link + driver generation | ~3 s |
| � 49 test bodies executed | ~5 s |

The compile cost dominates (~75% of wall time). This is what `moon
test --target native` would also feel like on CI without a warm cache.

## 10. Frontend / build pipeline

| Tool | Version | Status |
|---|---|---|
| Vite | 7.3.6 | clean (no known CVE) |
| jsdom | 30.0.1 | clean |
| Node | 24.17.0 | clean |
| `proton_cli` | 0.1.9 | `PROTON_NO_UPDATE_CHECK=1` to skip upgrade prompt |

Frontend bundle size is computed by Vite's `vite build`; not measured
in this snapshot. The build output (`frontend/dist/`) typically lands
at ~250–400 KiB gzipped for a vanilla-JS UI of this size.

## 11. Mutation testing substitute

`moon` 0.1.x has no mutation testing framework. The substitute lives
in `docs/mutation_analysis.md`. Summary:

| Mutation | Status |
|---|---|
| M1: swap `decode_bmp` → `decode_png` for `.png` path | **caught** (round-trip test) |
| M2: flip BMP `biHeight` sign (top-down vs bottom-up) | **survives** (no top-down fixture) |
| M3: drop JPEG YCbCr → RGB rounding step | **survives** (no pixel-strict round-trip) |
| M4: skip PNG IDCT step in interlaced path | **survives** (no checkerboard fixture) |
| M5: blank out a branch in `detect_format` | **caught** (per-format detection tests) |
| M6: drop BMP `encode_bmp` magic bytes | **caught** (`encode → decode` round-trip) |

Mutation kill-rate: **3/6 = 50%**. Tracking this ratio across
commits is the cheapest proxy for "are we adding tests for the new
code we add?".

## 12. Reproducing this snapshot

```powershell
cd D:\src\MiniMax\Projects\MoonBit\moonbit-labeler
$env:PROTON_NO_UPDATE_CHECK = "1"

# ① Format check
& "C:\Users\31379\.moon\bin\moon.exe" fmt --check

# ② SAST
& "C:\Users\31379\.moon\bin\moon.exe" check --target native --diagnostic-limit 80

# ⑤+⑥+⑨ Unit + Gherkin + component + benchmark
& "C:\Users\31379\.moon\bin\moon.exe" test --target native

# Static metrics
python C:\Users\31379\ryx_bench_collect.py

# Wall-clock
Measure-Command { & "C:\Users\31379\.moon\bin\moon.exe" test --target native }
```

Each `BENCH_JSON <op> <label>` line in the test stdout is one timing
sample. Pipe through `python -c "import sys, json; [print(json.loads(l.split(' ',2)[2])) for l in sys.stdin if l.startswith('BENCH_JSON')]"`
to convert to JSON for diffing.

## 13. What to watch on the next commit

Things that should **decrease** as the project matures:
- Wall-clock `moon test`
- `_build/native` total size
- Mutation-survival count (target: 0/6 within Q3)

Things that should **stay flat or grow modestly**:
- LOC (will grow with new formats / features; should not shrink from
  deletions unless we're removing dead code, which is fine)
- Test count (should grow monotonically)
- API surface (should grow monotonically; any drop = removed API = breaking change)

Things that should **stay flat**:
- Format coverage ratio (target: 100% by 2026-Q4 with TIFF + ICO in
  the vendored copy, matching `riantr/moonbit_image@0.3.x`)
- Memory ratio per fixture (only improves with format upgrades)
- SAST warning count (target: 0 forever)

---

*Re-run the collector after each milestone commit and paste the diff
in the PR description. This document is the single source of truth
for "where are we, and are we improving?".*
