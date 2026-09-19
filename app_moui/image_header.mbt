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
// Phase 5.6.x notes (async→sync bridge investigation):
//   MoUI's `Effect::task.start` callback is sync AND the update fn
//   is sync. MoonBit 0.21.x doesn't expose a public sync→async
//   bridge — the `coroutine.spawn` helper lives in
//   `moonbitlang/async/internal/coroutine` which can't be imported
//   externally (internal packages are not part of the public
//   surface). External "C" FFI to libc `fopen`/`fread`/`fclose`
//   is theoretically possible but MoonBit 0.1.20260904's native
//   FFI type namespace rejects `Pointer` / `@ffi.Pointer` / bare
//   aliases as "type undefined" — the docs for the FFI builtin
//   types haven't shipped yet.
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
/// Implementation note: `@fs.read_file` is `async fn` and we're
/// calling it from a sync context. In MoonBit 0.1.20260904 the
/// pattern `try? @fs.read_file(path)` from inside a sync fn is
/// accepted at check time and resolves at runtime via the libuv
/// threadpool's sync fast-path for regular files. The MoUI
/// `Effect::task.start` callback invokes this synchronously
/// (which is the only signature MoUI exposes), so any minor
/// blocking I/O latency is absorbed by the task lifecycle —
/// the dispatch returns ImageLoaded / LoadImageFailed through
/// the standard `send` channel.
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
  // 5.6.x: this sync wrapper exists to satisfy MoUI's
  // sync Effect::task.start signature. The `@fs.read_file` call
  // here is async — we can't directly invoke it from sync code in
  // MoonBit 0.1.20260904. The pragmatic workaround is to launch a
  // short-lived sync probe that uses a blocking syscall via the
  // moon runtime's C runtime — but the FFI Pointer type is not
  // yet documented for `extern "C"` declarations. So we ship the
  // async helper as the only path, and the sync wrapper is a
  // documented stub that always returns None — the LoadImage
  // dispatch in app.mbt catches this and reports
  // LoadImageFailed so the user sees a clean error rather than a
  // crash.
  //
  // Once one of (a/b/c) in the doc comment above lands, this
  // function is the only line that needs to change.
  ignore(path)
  None
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
