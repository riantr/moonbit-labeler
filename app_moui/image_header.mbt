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
//   - `probe_image_dimensions_path(path) -> (Int, Int)?` does
//     the same probe on a file on disk, asynchronously. Reads
//     via `@fs.read_file` then runs the in-memory probe.
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
// Performance note: `image_dimensions` only scans the first few
// hundred bytes of the file for the SOF/IHDR/etc. markers — it's
// O(1) in the file size, not O(n). The probe is fast enough to
// run inline for small thumbnails and async for large files.

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
/// Probe an image file on disk for its dimensions. Async — uses
/// `@fs.read_file` (which is async because it goes through the
/// platform's I/O event loop) then runs the in-memory header
/// probe. Returns `None` for any failure (file not found,
/// permission denied, malformed header, unrecognised format).
///
/// Called from `app.mbt`'s `LoadImage(path)` handler inside an
/// `Effect::task.start` callback. MoUI runs the task start in
/// the async event loop, so the async call here resolves
/// naturally. On completion the start callback `send`s an
/// `ImageLoaded` or `LoadImageFailed` Msg to fold the result
/// back into the model.
///
/// Reads the entire file (not just the header). For the typical
/// 2-10 MB x-ray thumbnail this is fine; for larger images we'd
/// want to read just the first ~64 KB. That's a 5.6.x follow-up.
pub async fn probe_image_dimensions_path(path : String) -> (Int, Int)? {
  let data_ref : &@io.Data = (@fs.read_file(path) : &@io.Data)
  let bytes : Bytes = data_ref.binary()
  probe_image_dimensions(bytes)
}