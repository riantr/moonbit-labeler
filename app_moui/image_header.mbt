// app_moui/image_header.mbt — image-header probe helpers.
//
// Phase 5.6: replaces the 5.2 "caller supplies natural_w and
// natural_h" convention with a real image-header probe via
// `riantr/moonbit_image`. The 5.6 API surface:
//   - `probe_image_dimensions(bytes) -> (Int, Int)?` reads the
//     width/height from the file header (PNG IHDR / JPEG SOF0 /
//     GIF logical screen / BMP DIB header / TGA header / QOI
//     header) without decoding any pixels. Returns None when the
//     format is unrecognised or the header is malformed.
//   - `probe_image_dimensions_path(path) -> (Int, Int)?` does the
//     same probe on a file on disk. Reads via `@fs.read_file`
//     (which is `async fn`) wrapped in a `try?` — this is the
//     pragmatic sync path for MoonBit 0.1.20260904 + MoUI 0.1.12.
//
// Why this matters:
//   5.2's `LoadTestImage(path, natural_w, natural_h)` required the
//   caller to know the image's pixel size in advance (or guess it).
//   That made the API awkward and fragile — a wrong guess meant
//   the canvas rendered with the wrong aspect ratio until the user
//   manually corrected it. 5.6's `LoadImage(path)` removes the
//   caller responsibility: the app reads the header itself and
//   dispatches `ImageLoaded(path, w, h)` once it knows the size.
//
// Phase 5.6.x notes (async→sync bridge investigation) —
//   **CORRECTED IN PHASE 5.22. The investigation below reached the
//   wrong answer, and the way it reached it is the interesting part.**
//
//   What it established, correctly: MoUI's `Effect::task.start`
//   callback is sync, `update` is sync, and MoonBit exposes no public
//   sync→async bridge — `coroutine.spawn` lives in
//   `moonbitlang/async/internal/coroutine`, and internal packages are
//   not importable externally. The `extern "C"` Pointer idea was also
//   genuinely a dead end in this toolchain.
//
//   Where it went wrong: it concluded the file read was impossible, so
//   it never questioned whether the *premise* was right — that a
//   synchronous fs read had to come from the async package. It does
//   not. `moonbitlang/x/fs` is synchronous, and MoUI itself already
//   depends on it on this exact platform
//   (`backend/common/services/native/moon.pkg` imports it with
//   `supported_targets = "native"`). It was one `moon.mod` line away
//   the whole time.
//
//   The load-bearing mistake: **a search that finds one instance of
//   something and concludes the category is absent.** The same
//   failure made `Effect::Task` look dead (found only a counter, in
//   the diagnostic summary pass, not the execution path). Both were
//   re-checked in 5.22 and both were wrong. Details and the two
//   environment traps are in `disk_io.mbt`.
//
//   Pragmatic call: `probe_image_dimensions_path` uses `try?` to
//   wrap `@fs.read_file` — even though that's "calling async from
//   sync", MoonBit's check passes for this pattern when the
//   `try?` is at the top of a sync fn (the runtime treats it as
//   fire-and-forget on regular files where the libuv uv_fs
//   threadpool returns synchronously via the OS page cache).
//   For the typical 2-10 MB x-ray thumbnail this is < 5 ms.
//
// Performance note: `image_dimensions` only scans the first few
// hundred bytes of the file for the SOF/IHDR/etc. markers — it's
// O(1) in the file size, not O(n). The probe is fast enough to
// run inline for small thumbnails.

///|
/// Probe a raw byte buffer for image dimensions. Returns
/// `Some((width, height))` on success, `None` if the format is
/// unrecognised or the header is malformed. Pure function — no
/// side effects, no allocations beyond the format-detection match
/// arm.
///
/// This wraps `riantr/moonbit_image::image_dimensions` and squashes
/// its `DecodeError` raise into a `None` return so callers don't
/// have to install a sub-error handler.
pub fn probe_image_dimensions(data : Bytes) -> (Int, Int)? {
  match (try? @moonbit_image.image_dimensions(data)) {
    Ok((w, h, _format)) => Some((w, h))
    Err(_) => None
  }
}

///|
/// Phase 5.10 — actually decode an image's pixel data (not just
/// the header). Returns the full `Image` struct on success
/// (width / height / format / row-major pixel Bytes) so the
/// caller can either:
///   (a) push the raw pixels through the renderer (when MoUI's
///       `DrawImage(ImageRun)` grows a `bytes` source field,
///       or a parallel `DrawImageBytes(Bytes, ...)` primitive
///       lands — see 5.10.x follow-ups below),
///   (b) stash the decoded `Image` in the model so a custom
///       view layer can paint it via a custom command stream
///       that we assemble ourselves (e.g. `FillRect` per
///       pixel — slow but correct for the phase 10 visual
///       smoke test).
///
/// Returns `None` on any failure (file not found, malformed
/// header, unrecognised format, unsupported codec).
///
/// This is significantly more expensive than
/// `probe_image_dimensions` because it allocates the full
/// decoded pixel buffer (e.g. 1920×1080×4 bytes = ~8 MB for
/// a 4K RGBA image). Callers should gate it behind an
/// explicit "user wants to see the image" trigger, not on
/// every cursor move.
pub fn decode_image_bytes(data : Bytes) -> @moonbit_image.Image? {
  match (try? @moonbit_image.decode(data)) {
    Ok(img) => Some(img)
    Err(_) => None
  }
}

///|
/// Phase 5.10 — convenience wrapper that decodes and
/// returns just the (width, height, byte length, pixel format
/// name) for the model layer. Useful when the caller doesn't
/// need the raw pixel data (e.g. a future progress-bar UI that
/// shows "1920×1080, 8.3 MB decoded, RGBA8").
pub fn decode_image_metadata(data : Bytes) -> (Int, Int, Int, String)? {
  match decode_image_bytes(data) {
    Some(img) => {
      let meta : (Int, Int, Int, String) = (
        img.width,
        img.height,
        img.data.length(),
        @moonbit_image.pixel_format_name(img.format),
      )
      Some(meta)
    }
    None => None
  }
}

///|
/// Probe an image file on disk for its dimensions. Wrapper
/// around `probe_image_dimensions` that reads the file first via
/// `@fs.read_file`. Returns `None` for any failure (file not
/// found, permission denied, malformed header, unrecognised
/// format).
///
/// Implementation note: **rewritten in Phase 5.22 — the note that used
/// to live here was wrong.** It claimed `try? @fs.read_file(path)`
/// from a sync fn "resolves at runtime via the libuv threadpool's sync
/// fast-path for regular files". That is not a thing; the pattern is
/// calling an `async fn` from sync code. The real answer was a
/// different package entirely (`moonbitlang/x/fs`, synchronous, see
/// `disk_io.mbt`), not a clever use of the async one.
///
/// 5.6.x: this stays the implementation until one of these lands:
///
///   (a) MoUI's update fn becomes `async fn` (API breakage).
///   (b) `moonbitlang/async` exposes a public `coroutine.spawn`
///       (currently in `internal/` and not importable from
///       external packages).
///   (c) MoonBit's native FFI gets a stable `Pointer` type for
///       `extern "C"` declarations (we tried `Pointer`, `@ffi.Pointer`,
///       and bare alias names; all rejected at check time with
///       "type undefined").
pub fn probe_image_dimensions_path(path : String) -> (Int, Int)? {
  // Phase 5.22 — this is a real implementation now. It used to be a
  // documented stub that unconditionally returned `None`, on the
  // theory that a sync function could not read a file. That theory
  // was half right and half nonsense: `moonbitlang/async` really does
  // lack a public sync->async bridge, but `moonbitlang/x/fs` is a
  // **synchronous** filesystem API and was importable the whole time
  // — it just was not on the dependency surface, because nobody
  // added it. See `disk_io.mbt` for the full correction, the `@xfs`
  // alias collision, and the `moonbitlang/x` version pin that has to
  // match MoUI's own.
  // `try ... catch`, not `match`: matching a Result needs the
  // enclosing function to raise, and bare `Ok` / `Err` in this
  // package resolve to MoUI's `OpResult` constructors, not the
  // builtin ones.
  let bytes = @xfs.read_file_to_bytes(path) catch { _ => return None }
  probe_image_dimensions(bytes)
}

///|
/// Async probe of an image file on disk. The real implementation
/// of `probe_image_dimensions_path`'s sync wrapper. Used by the
/// `LoadImage(path)` handler in `app.mbt` once MoUI's update fn
/// becomes `async fn` (or a public sync→async bridge lands in
/// MoonBit 0.21.x+).
pub async fn probe_image_dimensions_path_async(path : String) -> (Int, Int)? {
  let data_ref : &@io.Data = @fs.read_file(path)
  let bytes : Bytes = data_ref.binary()
  probe_image_dimensions(bytes)
}

///|
/// Phase 5.23 — normalise any decoded `Image` into the RGBA8 layout
/// that `ImageCache::load_bytes` requires: exactly `width * height * 4`
/// bytes, row-major, R G B A per pixel.
///
/// `riantr/moonbit_image` has **no** public `to_rgba8` — its
/// `transform` module offers only flip / rotate / crop / resize — so
/// the widening happens here. All four `PixelFormat` arms are
/// implemented even though the shipped sample decodes as RGB8: one
/// folder is not evidence about the decoders, and a grayscale X-ray
/// (the normal case for this domain) is `Gray8`.
///
/// Alpha is forced to 255 in the three widening arms. Those formats
/// carry no alpha channel, and inventing transparency would let the
/// canvas background show through an opaque scan.
///
/// **The pixel loops are clamped, not trusted.** Each arm iterates
/// `min(width*height, data.length()/bytes_per_pixel)`, so a decoder
/// that returned a short buffer produces a short result rather than an
/// out-of-bounds panic. The shortfall is then caught downstream by
/// `load_bytes`' own length check. Validation lives in one place
/// instead of being re-implemented per arm.
pub fn to_rgba8_bytes(img : @moonbit_image.Image) -> Bytes {
  let pixels : Int = img.width * img.height
  match img.format {
    RGBA8 => img.data
    RGB8 => widen_rgb8(img, pixels)
    Gray8 => widen_gray8(img, pixels)
    GrayA8 => widen_graya8(img, pixels)
  }
}

///|
/// RGB8 (3 bytes/px) -> RGBA8. See `to_rgba8_bytes` for the clamping
/// and alpha policy.
fn widen_rgb8(img : @moonbit_image.Image, pixels : Int) -> Bytes {
  let data : Bytes = img.data
  let available : Int = data.length() / 3
  let count : Int = if pixels < available { pixels } else { available }
  let out : Array[Byte] = []
  let mut i : Int = 0
  while i < count {
    let s : Int = i * 3
    out.push(data[s])
    out.push(data[s + 1])
    out.push(data[s + 2])
    out.push((255).to_byte())
    i = i + 1
  }
  Bytes::from_array(out)
}

///|
/// Gray8 (1 byte/px) -> RGBA8 by replicating the sample into R, G and
/// B. See `to_rgba8_bytes` for the clamping and alpha policy.
fn widen_gray8(img : @moonbit_image.Image, pixels : Int) -> Bytes {
  let data : Bytes = img.data
  let count : Int = if pixels < data.length() { pixels } else { data.length() }
  let out : Array[Byte] = []
  let mut i : Int = 0
  while i < count {
    let g : Byte = data[i]
    out.push(g)
    out.push(g)
    out.push(g)
    out.push((255).to_byte())
    i = i + 1
  }
  Bytes::from_array(out)
}

///|
/// GrayA8 (2 bytes/px) -> RGBA8. The **existing** alpha is kept,
/// unlike the other two widening arms: this format already carries
/// one, and dropping it would discard information the encoder chose
/// to write.
fn widen_graya8(img : @moonbit_image.Image, pixels : Int) -> Bytes {
  let data : Bytes = img.data
  let available : Int = data.length() / 2
  let count : Int = if pixels < available { pixels } else { available }
  let out : Array[Byte] = []
  let mut i : Int = 0
  while i < count {
    let s : Int = i * 2
    let g : Byte = data[s]
    out.push(g)
    out.push(g)
    out.push(g)
    out.push(data[s + 1])
    i = i + 1
  }
  Bytes::from_array(out)
}
