///| ---------------------------------------------------------------
/// MoonBit Labeler — backend extension
///
/// Exposes filesystem operations the frontend needs to:
///   - list image files in a folder
///   - read image bytes (as base64) for display
///   - read / write JSON annotation files
///   - list videos + read a single frame from a video via ffmpeg
///
/// IPC contract: each op is invoked as `ext:labeler/<op>` with a
/// JSON payload. The reply is also JSON.
/// ---------------------------------------------------------------

///| --- IPC payloads ---

///|
/// Request to list images in a directory. Empty `extensions` = default set.
pub struct ListImagesRequest {
  path : String
  extensions : Array[String]?
} derive(FromJson, ToJson, Eq, Debug)

///|
/// One image entry returned by `list_images`.
pub struct ImageEntry {
  name : String
  path : String
  ext : String
} derive(ToJson, Eq, Debug)

///|
pub struct ListImagesReply {
  folder : String
  images : Array[ImageEntry]
} derive(ToJson, Eq, Debug)

///|
/// Request to read an image as base64 (used as a `data:` URL fallback
/// when the webview cannot load `file://` URLs).
pub struct ReadImageRequest {
  path : String
} derive(FromJson, ToJson, Eq, Debug)

///|
pub struct ReadImageReply {
  path : String
  /// base64-encoded file bytes (no `data:` prefix)
  base64 : String
  mime : String
} derive(ToJson, Eq, Debug)

///|
/// Request a low-resolution thumbnail for sidebar / list previews.
/// Reuses ReadImageReply so the frontend can drop the result straight
/// into a `data:` URL. The backend resizes the source image to fit
/// within `max_edge` on its longest side, preserving aspect ratio.
/// This is the workhorse behind `image.thumb` — the small output
/// keeps the bytecode cost down (the old path shipped full-res JPGs
/// at ~250KB each, which 2580 thumbs = ~6.5MB of data to deserialize).
pub struct ReadThumbRequest {
  path : String
  /// Longest-side pixel cap. 64-256 is the sensible range. Default 128.
  max_edge : Int?
  /// JPEG quality 1-31 (lower is better). Default 5 (slightly worse
  /// than the main image path). Ignored for PNG source.
  quality : Int?
} derive(FromJson, ToJson, Eq, Debug)

///|
/// Request to read a text file (JSON label files).
pub struct ReadTextRequest {
  path : String
} derive(FromJson, ToJson, Eq, Debug)

///|
pub struct ReadTextReply {
  path : String
  content : String
  found : Bool
} derive(ToJson, Eq, Debug)

///|
/// Request to write a text file (JSON label files).
pub struct WriteTextRequest {
  path : String
  content : String
} derive(FromJson, ToJson, Eq, Debug)

///|
pub struct WriteTextReply {
  path : String
  bytes : Int
} derive(ToJson, Eq, Debug)

///|
/// Request to read the label JSON for an image. The label path is
/// derived automatically:
///   `Image@X/<basename>.jpg` -> `Label@X/<basename>.json`
/// If the folder layout does not match the `Image@<name>` / `Label@<name>`
/// convention, the sibling-label fallback is used.
pub struct ReadLabelRequest {
  image_path : String
} derive(FromJson, ToJson, Eq, Debug)

///|
pub struct ReadLabelReply {
  image_path : String
  label_path : String
  content : String
  found : Bool
} derive(ToJson, Eq, Debug)

///|
/// Request to write the label JSON for an image. The label path is
/// resolved the same way as in `read_label`.
pub struct WriteLabelRequest {
  image_path : String
  content : String
} derive(FromJson, ToJson, Eq, Debug)

///|
pub struct WriteLabelReply {
  image_path : String
  label_path : String
  bytes : Int
} derive(ToJson, Eq, Debug)

///|
/// Parse a label JSON text and return a normalized, modern-schema JSON
/// text. This is the shared entry point used by the frontend to avoid
/// keeping a parallel hand-rolled parser in JS. Accepts both legacy
/// `points: "x,y;x,y;..."` and modern `points: [[x, y], ...]` shapes,
/// infers missing `shape` from point count, mints missing `id`s, and
/// strips UTF-8 BOMs.
pub struct ParseLabelRequest {
  text : String
  /// Substituted into `img_name` when the parsed JSON has none.
  fallback_img_name : String?
} derive(FromJson, ToJson, Eq, Debug)

///|
pub struct ParseLabelReply {
  ok : Bool
  /// Normalized modern-schema JSON text. Empty when ok=false.
  label_text : String
  /// Human-readable error message. Empty when ok=true.
  error : String
} derive(ToJson, Eq, Debug)

///|
/// Re-serialize a label JSON text to the modern schema. Rounds pixel
/// coordinates to integers, drops empty `points` and dangling
/// bindings, and includes `frames` only when non-empty.
pub struct SerializeLabelRequest {
  /// Frontend-built label as JSON text.
  label_text : String
} derive(FromJson, ToJson, Eq, Debug)

///|
pub struct SerializeLabelReply {
  ok : Bool
  text : String
  error : String
} derive(ToJson, Eq, Debug)

///|
/// Default image extensions when the frontend doesn't pass a list.
let default_image_extensions : Array[String] = [
  ".jpg", ".jpeg", ".png", ".bmp", ".webp", ".gif",
]

///|
/// Default video extensions scanned by `list_videos`.
let default_video_extensions : Array[String] = [
  ".mp4", ".mov", ".mkv", ".avi", ".webm", ".m4v",
]

///|
/// Fallback class list used when no label files have been scanned yet.
/// Order matches the most common classes observed in the CARS dataset.
let fallback_classes : Array[String] = [
  "scissors", "knife_straight", "knife_folded", "knife_blade", "knife_other", "lithium_cell_charger_square",
  "lithium_cell_charger_cylinder", "liquid_bottle_plastic", "liquid_thermos_cup_metal",
  "lighter_plastic",
]

///|
/// Request to enumerate all distinct class names used in the label files
/// under the sibling `Label@<name>` directory.
pub struct ScanClassesRequest {
  image_path : String?
} derive(FromJson, ToJson, Eq, Debug)

///|
/// One class with its frequency. `color` is an optional `#RRGGBB`
/// string; empty when the source has no color (e.g. JSON files or a
/// label-folder scan that can't recover one).
pub struct ClassInfo {
  name : String
  count : Int
  color : String
} derive(ToJson, Eq, Debug)

///|
/// Reply containing the label directory that was scanned and the
/// distinct classes (sorted by count desc).
pub struct ScanClassesReply {
  label_dir : String
  classes : Array[ClassInfo]
} derive(ToJson, Eq, Debug)

///|
/// Request to write the user's curated class list to `<image_folder>/classes.json`.
pub struct SaveClassesRequest {
  image_path : String
  classes : Array[String]
} derive(FromJson, ToJson, Eq, Debug)

///|
/// Result of `save_classes`. `path` is the absolute path of the written
/// file (may be empty if the destination couldn't be determined).
pub struct SaveClassesReply {
  path : String
  written : Int
} derive(ToJson, Eq, Debug)

///|
/// Request to read the user-curated class list. If no `classes.json` is
/// present, the backend falls back to scanning the sibling `Label@<rest>`
/// folder (the same path as `scan_classes`).
pub struct LoadClassesRequest {
  image_path : String
} derive(FromJson, ToJson, Eq, Debug)

///|
/// Result of `load_classes`. `path` is the file that was read (or "" if
/// neither the curated file nor any label file was available). `classes`
/// carries the merged class list; `from_curated` is `true` when the
/// curated file was the source, `false` when the result came from a
/// label-folder scan.
pub struct LoadClassesReply {
  path : String
  classes : Array[ClassInfo]
  from_curated : Bool
} derive(ToJson, Eq, Debug)

///|
/// Request to read a class list from an arbitrary file path (typically
/// picked via the frontend's `<input type="file">` element).
pub struct LoadClassesFromFileRequest {
  path : String
} derive(FromJson, ToJson, Eq, Debug)

///|
/// Request to enumerate video files. `Video@<name>/*.mp4` is the
/// conventional folder layout. Sibling-folder fallback applies.
pub struct ListVideosRequest {
  path : String
  extensions : Array[String]?
} derive(FromJson, ToJson, Eq, Debug)

///|
/// One video entry returned by `list_videos`. The frontend decides
/// when (and whether) to call `read_video_info` to populate metadata.
pub struct VideoEntry {
  name : String
  path : String
  ext : String
  size_bytes : Int
} derive(ToJson, Eq, Debug)

///|
pub struct ListVideosReply {
  folder : String
  videos : Array[VideoEntry]
} derive(ToJson, Eq, Debug)

///|
/// Request metadata for a single video. Implemented via `ffprobe -v error
/// -print_format json -show_streams -show_format <path>` and a small
/// string parser. The reply fields are best-effort: missing / unparseable
/// values surface as `0` / `""`.
pub struct ReadVideoInfoRequest {
  path : String
} derive(FromJson, ToJson, Eq, Debug)

///|
pub struct ReadVideoInfoReply {
  path : String
  /// Duration in milliseconds.
  duration_ms : Int
  /// Effective frames per second (best of r_frame_rate / avg_frame_rate).
  fps : Double
  /// Total frame count. Computed as round(fps * duration_seconds), with
  /// a min of 1 to keep timelines usable.
  frame_count : Int
  width : Int
  height : Int
  /// Codec fourcc as a string (e.g. "h264"). Empty if unknown.
  codec : String
  /// True when ffprobe finished cleanly and a video stream was found.
  ok : Bool
} derive(ToJson, Eq, Debug)

///|
/// Request a single frame as a base64-encoded JPEG. Internally invokes
/// `ffmpeg -ss <sec> -i <path> -frames:v 1 -q:v 3 -y <tmp>`. The reply
/// is intentionally narrow: the same shape as `read_image` so the
/// frontend can re-use the data: URL fallback path.
pub struct ReadVideoFrameRequest {
  path : String
  frame : Int
  /// Optional override JPEG quality (1-31, lower is better). Defaults to 3.
  quality : Int?
} derive(FromJson, ToJson, Eq, Debug)

///|
pub struct ReadVideoFrameReply {
  path : String
  frame : Int
  base64 : String
  mime : String
  width : Int
  height : Int
  ok : Bool
} derive(ToJson, Eq, Debug)

///|
/// One annotation with a normalised `(shape, type, points)` triple.
/// Coordinates are image pixels (XY order). Used by the VOC/YOLO
/// exporters.
pub struct ExportAnn {
  shape : String
  type_ : String
  points : Array[(Double, Double)]
} derive(ToJson, Eq, Debug)

///|
/// Result of `export_voc_folder` / `export_yolo_folder`. The
/// `classes` field is the ordered list of distinct class names that
/// were written into `classes.txt` (YOLO) or into `<name>` elements
/// (VOC). The order matches `load_classes` so it stays stable across
/// export calls.
pub struct ExportReply {
  dest_folder : String
  exported_count : Int
  skipped_count : Int
  classes : Array[String]
} derive(ToJson, Eq, Debug)

///|
/// Make sure the directory exists; falls back to PowerShell if the
/// MoonBit async fs `mkdir` doesn't materialise the path. We hit this
/// edge case on Windows when the parent path lives in a folder the
/// async backend hasn't seen before.
async fn ensure_dir(path : String) -> Unit {
  if path == "" {
    return
  }
  if @fs.exists(path) && @fs.kind(path) == @fs.Directory {
    return
  }
  // `@fs.mkdir(..., recursive=true)` is the modern MoonBit path. It
  // was probed to work on `Image@CARS.Part.01`-style paths (with `@`
  // in the directory name) under moon 0.4.43, so the PowerShell
  // `New-Item -Force` round-trip is no longer needed here.
  @fs.mkdir(path, recursive=true) catch {
    _ => ()
  }
}

///| --- string helpers ---

///|
fn lower(s : String) -> String {
  let buf = StringBuilder::new(size_hint=s.length())
  for c in s {
    if c >= 'A' && c <= 'Z' {
      buf.write_char(Int::unsafe_to_char(c.to_int() + 32))
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
/// Upper-case helper for color normalization (color hex).
fn upper(s : String) -> String {
  let buf = StringBuilder::new(size_hint=s.length())
  for c in s {
    if c >= 'a' && c <= 'z' {
      buf.write_char(Int::unsafe_to_char(c.to_int() - 32))
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
fn is_image_ext(name : String, exts : Array[String]) -> Bool {
  let lname = lower(name)
  for ext in exts {
    if lname.has_suffix(ext) {
      return true
    }
  }
  false
}

///|
fn is_video_ext(name : String, exts : Array[String]) -> Bool {
  let lname = lower(name)
  for ext in exts {
    if lname.has_suffix(ext) {
      return true
    }
  }
  false
}

///|
/// Returns the file extension including the leading `.`, or `""`.
fn ext_of(name : String) -> String {
  let bytes = @encoding.encode(@encoding.UTF8, name)
  let mut dot = -1
  for i in 0..<bytes.length() {
    if bytes[i] == b'.' {
      dot = i
    }
  }
  if dot < 0 {
    ""
  } else {
    let buf = StringBuilder::new(size_hint=bytes.length() - dot)
    for i in dot..<bytes.length() {
      buf.write_char(Int::unsafe_to_char(bytes[i].to_int()))
    }
    buf.to_string()
  }
}

///|
fn join_path(folder : String, name : String) -> String {
  if folder.has_suffix("/") || folder.has_suffix("\\") {
    folder + name
  } else {
    folder + "\\" + name
  }
}

///|
/// --- base64 encoding (RFC 4648, with padding) ---
fn base64_encode(data : Bytes) -> String {
  let alphabet : FixedArray[Char] = [
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
    'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f',
    'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v',
    'w', 'x', 'y', 'z', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '+', '/',
  ]
  let buf = StringBuilder::new(size_hint=(data.length() + 2) / 3 * 4)
  let mut i = 0
  while i + 2 < data.length() {
    let b0 = data[i].to_int()
    let b1 = data[i + 1].to_int()
    let b2 = data[i + 2].to_int()
    let c0 = (b0 & 0xFC) >> 2
    let c1 = ((b0 & 0x03) << 4) | (b1 >> 4)
    let c2 = ((b1 & 0x0F) << 2) | (b2 >> 6)
    let c3 = b2 & 0x3F
    buf.write_char(alphabet[c0])
    buf.write_char(alphabet[c1])
    buf.write_char(alphabet[c2])
    buf.write_char(alphabet[c3])
    i = i + 3
  }
  let rem = data.length() - i
  if rem == 1 {
    let b0 = data[i].to_int()
    let c0 = (b0 & 0xFC) >> 2
    let c1 = (b0 & 0x03) << 4
    buf.write_char(alphabet[c0])
    buf.write_char(alphabet[c1])
    buf.write_char('=')
    buf.write_char('=')
  } else if rem == 2 {
    let b0 = data[i].to_int()
    let b1 = data[i + 1].to_int()
    let c0 = (b0 & 0xFC) >> 2
    let c1 = ((b0 & 0x03) << 4) | (b1 >> 4)
    let c2 = (b1 & 0x0F) << 2
    buf.write_char(alphabet[c0])
    buf.write_char(alphabet[c1])
    buf.write_char(alphabet[c2])
    buf.write_char('=')
  }
  buf.to_string()
}

///|
fn mime_for(name : String) -> String {
  let lower_name = lower(name)
  if lower_name.has_suffix(".jpg") || lower_name.has_suffix(".jpeg") {
    "image/jpeg"
  } else if lower_name.has_suffix(".png") {
    "image/png"
  } else if lower_name.has_suffix(".bmp") {
    "image/bmp"
  } else if lower_name.has_suffix(".webp") {
    "image/webp"
  } else if lower_name.has_suffix(".gif") {
    "image/gif"
  } else {
    "application/octet-stream"
  }
}

///|
/// --- ops ---
async fn op_list_images(req : ListImagesRequest) -> ListImagesReply {
  let exts = match req.extensions {
    Some(list) if list.length() > 0 => list
    _ => default_image_extensions
  }
  let names = @fs.readdir(req.path, include_hidden=false, sort=true)
  let images : Array[ImageEntry] = []
  for name in names {
    if !is_image_ext(name, exts) {
      continue
    }
    let full = join_path(req.path, name)
    images.push({ name, path: full, ext: ext_of(name) })
  }
  { folder: req.path, images }
}

///|
async fn op_read_image(req : ReadImageRequest) -> ReadImageReply {
  let data = @fs.read_file(req.path) catch {
    err => fail("read_image failed: " + err.to_string())
  }
  let bytes = data.binary()
  { path: req.path, base64: base64_encode(bytes), mime: mime_for(req.path) }
}

///|
/// Read a downscaled thumbnail. Pure-MoonBit pipeline: decode the
/// source (JPEG / PNG / BMP / GIF / QOI / TGA via buildliming),
/// bilinear-resize to fit inside `max_edge`, re-encode as BMP, base64
/// the result for the frontend to drop into a data: URL.
///
/// The output is BMP rather than JPEG because buildliming's encoder
/// set is BMP / QOI (no JPEG encoder). BMP is browser-native — the
/// frontend feeds it to <img>/createImageBitmap and never notices
/// the difference. At 128px the BMP payload is typically <20 KB,
/// comparable to what ffmpeg's `q:v 5` JPEG produced.
async fn op_read_thumb(req : ReadThumbRequest) -> ReadImageReply {
  let max_edge = match req.max_edge {
    Some(v) if v >= 32 && v <= 1024 => v
    _ => 128
  }
  // Read the source as bytes; let buildliming auto-detect the format.
  let data = @fs.read_file(req.path) catch {
    err => {
      // Surface as empty reply so the frontend's loadThumbFallback
      // can fall back to read_image (full-res file:// URL).
      let _ = err
      return { path: req.path, base64: "", mime: "image/bmp" }
    }
  }
  let raw = data.binary()
  let img = decode_for(req.path, raw) catch {
    _ => return { path: req.path, base64: "", mime: "image/bmp" }
  }
  let w = img.width
  let h = img.height
  if w <= 0 || h <= 0 {
    return { path: req.path, base64: "", mime: "image/bmp" }
  }
  // Compute the new size preserving aspect ratio. `max_edge` is the
  // longest-side cap; the other dimension scales proportionally.
  let nw = if w >= h {
    max_edge
  } else {
    (w.to_double() * max_edge.to_double() / h.to_double()).to_int()
  }
  let nh = if h >= w {
    max_edge
  } else {
    (h.to_double() * max_edge.to_double() / w.to_double()).to_int()
  }
  let nw_final = if nw < 1 { 1 } else { nw }
  let nh_final = if nh < 1 { 1 } else { nh }
  // Skip resize when the source is already smaller than the cap —
  // saves the bilinear pass entirely.
  let resized = if w <= max_edge && h <= max_edge {
    img
  } else {
    img.resize_bilinear(nw_final, nh_final)
  }
  let bmp = @image.encode_bmp(resized) catch {
    err => fail("read_thumb encode_bmp failed: " + err.to_string())
  }
  { path: req.path, base64: base64_encode(bmp), mime: "image/bmp" }
}

///| --- buildliming/moonbit_image integration (bypass path) ---
///
/// Two new ops that route through the vendored buildliming/moonbit_image
/// library (extensions/image/) instead of the ffmpeg/file:// path.
/// They are registered alongside the existing ops but never called from
/// the default code path — the frontend opts in via a settings flag
/// (`imageRenderMode`).
///
/// Why have them at all? The buildliming path:
///   - decodes fully to RGBA8 in pure MoonBit (no subprocess, no FFI),
///   - supports BMP / QOI / TGA / PNG / GIF / JPEG via one `decode_*` call,
///   - can resize to a target dimension with bilinear / nearest,
///   - can re-encode to BMP / QOI without leaving the language.
/// Useful for future work where we want to:
///   - skip the CEF file:// cascade and ship a single data: URL,
///   - bake a custom low-res pipeline into the export step,
///   - ship image diffs/snapshots for unit tests.
/// Trade-off: the library only writes BMP / QOI (no PNG encoder yet).
/// Browsers accept both via `<img>` / canvas / createImageBitmap, so we
/// ship BMP — uncompressed, similar size to PNG for our X-ray data
/// and supported in every CEF release we care about.

///|
/// Decode the image at full resolution into RGBA8. We piggyback on
/// `ReadImageReply` so the frontend can drop the result into a
/// `data:` URL using the same `mime` field as the existing read_image
/// reply. The returned `base64` is a BMP re-encoded from the RGBA
/// buffer (buildliming/image doesn't ship a PNG encoder, so we go
/// BMP — 24-bit when fully opaque, 32-bit otherwise).
pub struct DecodeImageRequest {
  path : String
} derive(FromJson, ToJson, Eq, Debug)

///|
async fn op_decode_image(req : DecodeImageRequest) -> ReadImageReply {
  let data = @fs.read_file(req.path) catch {
    err => fail("decode_image read failed: " + err.to_string())
  }
  let raw = data.binary()
  let img = decode_for(req.path, raw) catch {
    err => fail("decode_image decode failed: " + err.to_string())
  }
  // Re-encode to BMP so the frontend can drop the bytes into a
  // data: URL. The frontend then draws the BMP into a canvas at
  // any size it likes via object-fit: contain.
  let bmp = @image.encode_bmp(img) catch {
    err => fail("decode_image encode_bmp failed: " + err.to_string())
  }
  { path: req.path, base64: base64_encode(bmp), mime: "image/bmp" }
}

///|
/// Decode + resize + BMP encode. Longest-side cap, same convention
/// as op_read_thumb. The BMP comes back ready to drop into a
/// `data:` URL. Internally uses buildliming/image's resize with
/// bilinear interpolation by default, which is cheap (no ffmpeg
/// subprocess) and gives visually fine output at thumbnail sizes.
pub struct ResizeImageRequest {
  path : String
  max_edge : Int?
  /// "Nearest" | "Bilinear" | "Bicubic". Defaults to Bilinear.
  /// (Bicubic falls back to bilinear — buildliming has no bicubic
  /// kernel, and the visual difference is invisible at our sizes.)
  resize_method : String?
} derive(FromJson, ToJson, Eq, Debug)

///|
async fn op_resize_image(req : ResizeImageRequest) -> ReadImageReply {
  let max_edge = match req.max_edge {
    Some(v) if v >= 16 && v <= 4096 => v
    _ => 256
  }
  let raw = @fs.read_file(req.path) catch {
    err => fail("resize_image read failed: " + err.to_string())
  }
  let bytes = raw.binary()
  let img = decode_for(req.path, bytes) catch {
    err => fail("resize_image decode failed: " + err.to_string())
  }
  let w = img.width
  let h = img.height
  if w <= 0 || h <= 0 {
    return { path: req.path, base64: "", mime: "image/bmp" }
  }
  let scale = max_edge.to_double() / w.to_double()
  let nh = if scale >= 1.0 { h } else { (h.to_double() * scale).to_int() }
  let nw = if scale >= 1.0 { w } else { max_edge }
  let resized = match req.resize_method {
    Some("Nearest") => img.resize_nearest(nw, nh)
    // "Bilinear" or "Bicubic" both → bilinear. The visual delta at
    // thumbnail sizes isn't worth carrying a second kernel for.
    _ => img.resize_bilinear(nw, nh)
  }
  let bmp = @image.encode_bmp(resized) catch {
    err => fail("resize_image encode_bmp failed: " + err.to_string())
  }
  { path: req.path, base64: base64_encode(bmp), mime: "image/bmp" }
}

///|
/// Pick the right decoder by file extension. Errors are raised as
/// `Failure` (the buildliming error type); we let the caller wrap
/// them.
fn decode_for(path : String, raw : Bytes) -> @image.Image raise {
  let ext = ext_of(path).to_lower()
  match ext {
    ".png" => @image.decode_png(raw)
    ".jpg" | ".jpeg" => @image.decode_jpeg(raw)
    ".bmp" => @image.decode_bmp(raw)
    ".gif" => @image.decode_gif(raw)
    ".qoi" => @image.decode_qoi(raw)
    ".tga" => @image.decode_tga(raw)
    _ => fail("decode_image: unsupported format '" + ext + "'")
  }
}

///|
async fn op_read_text(req : ReadTextRequest) -> ReadTextReply {
  if !@fs.exists(req.path) {
    return { path: req.path, content: "", found: false }
  }
  let data = @fs.read_file(req.path) catch {
    _ => return { path: req.path, content: "", found: false }
  }
  let text = data.text() catch {
    err =>
      return {
        path: req.path,
        content: "decode error: " + err.to_string(),
        found: true,
      }
  }
  { path: req.path, content: text, found: true }
}

///|
async fn op_write_text(req : WriteTextRequest) -> WriteTextReply {
  // Direct MoonBit @fs.write_file, UTF-8 encoded. (Earlier revisions
  // routed through PowerShell + base64 to dodge a PS 5.1 quoting bug
  // and a long-since-fixed async-fs path bug; the current async fs
  // handles UTF-8 String writes correctly even for paths containing
  // `@`, so the indirection is no longer needed.)
  @fs.write_file(req.path, req.content, create_mode=@fs.CreateOrTruncate) catch {
    err => fail("write_text failed: " + err.to_string())
  }
  { path: req.path, bytes: req.content.length() }
}

///|
/// Returns the last index of `c` in `s`, or `-1` if not found.
fn last_index_of(s : String, c : Char) -> Int {
  let mut result = -1
  let mut i = 0
  for ch in s {
    if ch == c {
      result = i
    }
    i = i + 1
  }
  result
}

///|
/// Splits on either `/` or `\`, returning the slice up to (exclusive)
/// of the last separator and the slice after it. The separator used is
/// the one that appears later in the string.
fn split_dir_name(path : String) -> (String, String) {
  let last_slash = last_index_of(path, '/')
  let last_back = last_index_of(path, '\\')
  let last_sep = if last_slash >= last_back { last_slash } else { last_back }
  if last_sep < 0 {
    ("", path)
  } else {
    (path[:last_sep].to_owned(), path[last_sep + 1:].to_owned())
  }
}

///|
/// Splits the basename into (stem, ext). If no `.`, ext is "".
fn split_stem_ext(basename : String) -> (String, String) {
  let dot = last_index_of(basename, '.')
  if dot <= 0 {
    (basename, "")
  } else {
    (basename[:dot].to_owned(), basename[dot:].to_owned())
  }
}

///|
/// Resolve the label directory for the `scan_classes` op.
/// Accepts either a directory path (`D:/x/Image@Foo`) or a file path
/// (`D:/x/Image@Foo/1800003_0.jpg`). Returns the sibling `Label@Foo`
/// directory, or "" if it can't be determined.
async fn derive_label_dir_for_scan(p : String) -> String {
  // Case 1: p is an existing directory whose leaf starts with "Image@".
  if @fs.exists(p) && @fs.kind(p) == @fs.Directory {
    let (parent, leaf) = split_dir_name(p)
    if leaf.has_prefix("Image@") && leaf.length() > 6 {
      let rest = leaf[6:].to_owned()
      let sep = if p.contains("\\") { "\\" } else { "/" }
      if parent == "" {
        return "Label@" + rest
      } else {
        return parent + sep + "Label@" + rest
      }
    }
  }
  // Case 2: fall back to file-path heuristic.
  let lp = image_path_to_label_path(p)
  let (dir, _) = split_dir_name(lp)
  dir
}

///|
/// Resolve the *image* directory for a path that may be a directory
/// (`D:/x/Image@Foo`) or a file inside it (`D:/x/Image@Foo/1800003_0.jpg`).
/// Returns the directory itself, or "" if we can't tell. The result is
/// the destination folder for `classes.json`.
async fn derive_image_dir(p : String) -> String {
  if @fs.exists(p) && @fs.kind(p) == @fs.Directory {
    return p
  }
  let (dir, _) = split_dir_name(p)
  if @fs.exists(dir) && @fs.kind(dir) == @fs.Directory {
    return dir
  }
  ""
}

///|
/// Map `Image@X/<basename>.ext` -> `Label@X/<basename>.json`.
/// Mirrors the frontend's `detectLabelFolder` heuristic. The basename is
/// preserved verbatim — `1800003_0.jpg` becomes `1800003_0.json` (the `_0`
/// is part of the CARS filename, not a separate index suffix).
fn image_path_to_label_path(image_path : String) -> String {
  let (dir, basename) = split_dir_name(image_path)
  let (stem, _ext) = split_stem_ext(basename)

  let (dir_parent, dir_leaf) = split_dir_name(dir)
  let sep = if dir.contains("\\") { "\\" } else { "/" }
  let new_leaf = if dir_leaf.has_prefix("Image@") {
    "Label@" + dir_leaf[6:].to_owned()
  } else {
    ""
  }
  let label_basename = stem + ".json"
  if new_leaf == "" {
    // Fallback: keep the dir, just swap the extension.
    if dir == "" {
      label_basename
    } else {
      dir + sep + label_basename
    }
  } else if dir_parent == "" {
    new_leaf + sep + label_basename
  } else {
    dir_parent + sep + new_leaf + sep + label_basename
  }
}

///|
/// Same as `image_path_to_label_path` but for `Video@X/<basename>.ext`
/// -> `Label@X/<basename>.json`. The convention is identical to images;
/// the basename is preserved verbatim.
fn video_path_to_label_path(video_path : String) -> String {
  let (dir, basename) = split_dir_name(video_path)
  let (stem, _ext) = split_stem_ext(basename)

  let (dir_parent, dir_leaf) = split_dir_name(dir)
  let sep = if dir.contains("\\") { "\\" } else { "/" }
  let new_leaf = if dir_leaf.has_prefix("Video@") {
    "Label@" + dir_leaf[6:].to_owned()
  } else {
    ""
  }
  let label_basename = stem + ".json"
  if new_leaf == "" {
    if dir == "" {
      label_basename
    } else {
      dir + sep + label_basename
    }
  } else if dir_parent == "" {
    new_leaf + sep + label_basename
  } else {
    dir_parent + sep + new_leaf + sep + label_basename
  }
}

///|
async fn op_read_label(req : ReadLabelRequest) -> ReadLabelReply {
  // Detect whether the request refers to a video or an image. We use the
  // directory-leaf prefix as a strong signal but fall back to extension
  // sniffing so that ad-hoc paths still work.
  let (dir, basename) = split_dir_name(req.image_path)
  let (_, dir_leaf) = split_dir_name(dir)
  let is_video = dir_leaf.has_prefix("Video@") ||
    lower(basename).has_suffix(".mp4") ||
    lower(basename).has_suffix(".mov") ||
    lower(basename).has_suffix(".mkv") ||
    lower(basename).has_suffix(".avi") ||
    lower(basename).has_suffix(".webm") ||
    lower(basename).has_suffix(".m4v")
  let label_path = if is_video {
    video_path_to_label_path(req.image_path)
  } else {
    image_path_to_label_path(req.image_path)
  }
  if !@fs.exists(label_path) {
    return { image_path: req.image_path, label_path, content: "", found: false }
  }
  let data = @fs.read_file(label_path) catch {
    _ =>
      return {
        image_path: req.image_path,
        label_path,
        content: "",
        found: false,
      }
  }
  let content = data.text() catch {
    err =>
      return {
        image_path: req.image_path,
        label_path,
        content: "decode error: " + err.to_string(),
        found: true,
      }
  }
  { image_path: req.image_path, label_path, content, found: true }
}

///|
async fn op_write_label(req : WriteLabelRequest) -> WriteLabelReply {
  let (dir, basename) = split_dir_name(req.image_path)
  let (_, dir_leaf) = split_dir_name(dir)
  let is_video = dir_leaf.has_prefix("Video@") ||
    lower(basename).has_suffix(".mp4") ||
    lower(basename).has_suffix(".mov") ||
    lower(basename).has_suffix(".mkv") ||
    lower(basename).has_suffix(".avi") ||
    lower(basename).has_suffix(".webm") ||
    lower(basename).has_suffix(".m4v")
  let label_path = if is_video {
    video_path_to_label_path(req.image_path)
  } else {
    image_path_to_label_path(req.image_path)
  }
  let (label_dir, _) = split_dir_name(label_path)
  if label_dir != "" {
    ensure_dir(label_dir) catch {
      _ => ()
    }
  }
  // Direct MoonBit @fs.write_file, UTF-8 encoded. The async fs in
  // moon 0.4.43+ handles paths with `@` correctly, and the String ->
  // UTF-8 -> Bytes conversion preserves `"` and `\` without escape
  // round-trips.
  @fs.write_file(label_path, req.content, create_mode=@fs.CreateOrTruncate) catch {
    err => fail("write_label failed: " + err.to_string())
  }
  { image_path: req.image_path, label_path, bytes: req.content.length() }
}

///|
/// Enumerate the distinct `type` strings across every label JSON in the
/// sibling `Label@<name>` directory. Counts are sorted descending. If the
/// label directory does not exist or is empty, returns the
/// `fallback_classes` so the UI still has something to pick from.
async fn op_scan_classes(req : ScanClassesRequest) -> ScanClassesReply {
  // image_path can be either a directory (e.g. `D:/x/Image@Foo`) or a file
  // (e.g. `D:/x/Image@Foo/1800003_0.jpg`). Handle both: if it's a directory
  // whose name starts with `Image@`, swap it for the sibling `Label@<rest>`.
  let label_dir = match req.image_path {
    Some(p) if p.length() > 0 => derive_label_dir_for_scan(p)
    _ => ""
  }
  let dbg = "C:\\Windows\\Temp\\moonbit-labeler-scan-classes.log"
  // Initialize log file. TruncateExisting is the default but we want to make
  // sure the file exists for subsequent appends.
  @fs.write_file(dbg, "", create_mode=@fs.CreateOrTruncate) catch {
    _ => ()
  }
  async fn log(s : String) {
    @fs.write_file(dbg, s + "\n", append=true, create_mode=@fs.OpenOrCreate) catch {
      _ => ()
    }
  }
  log("=== scan_classes start ===")
  log(
    "req.image_path=" +
    (match req.image_path {
      Some(p) => p
      None => "<none>"
    }),
  )
  log("derived label_dir='" + label_dir + "'")
  if label_dir == "" || !@fs.exists(label_dir) {
    log("label_dir empty or missing -> fallback")
    let classes : Array[ClassInfo] = []
    for c in fallback_classes {
      classes.push({ name: c, count: 0, color: "" })
    }
    return { label_dir, classes }
  }
  let names = @fs.readdir(label_dir, include_hidden=false, sort=false) catch {
    err => {
      log("readdir failed: " + err.to_string())
      []
    }
  }
  log("readdir returned " + names.length().to_string() + " entries")
  let items : Array[(String, String)] = []
  for name in names {
    if !lower(name).has_suffix(".json") {
      continue
    }
    let full = join_path(label_dir, name)
    let data = @fs.read_file(full) catch {
      err => {
        log("read_file failed for " + name + ": " + err.to_string())
        continue
      }
    }
    let text = data.text() catch {
      err => {
        log("decode failed for " + name + ": " + err.to_string())
        continue
      }
    }
    items.push((full, text))
  }
  let entries = aggregate_label_entries(items)
  log("distinct classes found: " + entries.length().to_string())
  log("returning " + entries.length().to_string() + " entries")
  { label_dir, classes: entries }
}

///|
/// Build a `ClassInfo` list from a pre-read list of (path, text) pairs.
/// `op_scan_classes` and `op_load_classes` both want the same shape; we
/// share the aggregation logic here and let callers handle the async
/// filesystem read.
fn aggregate_label_entries(items : Array[(String, String)]) -> Array[ClassInfo] {
  let counts : Map[String, Int] = Map([])
  for pair in items {
    let (_, text) = pair
    let cleaned = if text.length() > 0 && text[0] == '\u{FEFF}' {
      text[1:].to_owned()
    } else {
      text
    }
    for k, v in collect_classes_from_text(cleaned) {
      let prev = counts.get(k).unwrap_or(0)
      counts[k] = prev + v
    }
  }
  let entries : Array[ClassInfo] = []
  for k, v in counts {
    entries.push({ name: k, count: v, color: "" })
  }
  entries.sort_by(fn(a, b) { b.count - a.count })
  for fallback in fallback_classes {
    if !counts.contains(fallback) {
      entries.push({ name: fallback, count: 0, color: "" })
    }
  }
  entries
}

///|
/// Persist a curated class list to `<image_folder>/classes.json` so the
/// user can reload it across sessions and share it with other folders.
async fn op_save_classes(req : SaveClassesRequest) -> SaveClassesReply {
  let image_dir = derive_image_dir(req.image_path)
  if image_dir == "" {
    fail("save_classes: cannot determine image folder for " + req.image_path)
  }
  // Build JSON. We escape a few characters minimally: class names are
  // alphanumeric + underscore, but be safe in case users type " or \.
  let buf = StringBuilder::new(size_hint=64 + req.classes.length() * 16)
  buf.write_string("{\n  \"classes\": [\n")
  let mut first = true
  for c in req.classes {
    if !first {
      buf.write_string(",\n")
    }
    first = false
    buf.write_string("    \"")
    for ch in c {
      if ch == '"' || ch == '\\' {
        buf.write_char('\\')
      }
      buf.write_char(ch)
    }
    buf.write_string("\"")
  }
  buf.write_string("\n  ]\n}\n")
  let dest = join_path(image_dir, "classes.json")
  // Direct MoonBit @fs.write_file, UTF-8 encoded. The previous
  // PowerShell + base64 path was a workaround for a long-fixed
  // async-fs path bug (paths containing `@`) and a PS 5.1 quoting
  // bug. The current async fs handles both correctly.
  @fs.write_file(dest, buf.to_string(), create_mode=@fs.CreateOrTruncate) catch {
    err => fail("save_classes write failed: " + err.to_string())
  }
  { path: dest, written: req.classes.length() }
}

///|
/// Load the user's curated class list. Order of resolution:
///   1. `<image_folder>/classes.json`  (curated, persists author intent)
///   2. sibling `Label@<name>/` directory scan  (auto-discovered)
///   3. `fallback_classes`               (seed list for an empty folder)
async fn op_load_classes(req : LoadClassesRequest) -> LoadClassesReply {
  let image_dir = derive_image_dir(req.image_path)
  if image_dir == "" {
    fail("load_classes: cannot determine image folder for " + req.image_path)
  }
  // (1) curated file
  let curated = join_path(image_dir, "classes.json")
  if @fs.exists(curated) {
    let raw = @fs.read_file(curated) catch {
      err =>
        fail("load_classes: read " + curated + " failed: " + err.to_string())
    }
    let text = raw.text() catch { _ => "" }
    let parsed = parse_curated_classes(text)
    let entries : Array[ClassInfo] = []
    for p in parsed {
      let (name, color) = p
      entries.push({ name, count: 0, color })
    }
    return { path: curated, classes: entries, from_curated: true }
  }
  // (2) label-folder scan
  let label_dir = derive_label_dir_for_scan(req.image_path)
  if label_dir != "" && @fs.exists(label_dir) {
    let names = @fs.readdir(label_dir, include_hidden=false, sort=false) catch {
      _ => []
    }
    let items : Array[(String, String)] = []
    for name in names {
      if !lower(name).has_suffix(".json") {
        continue
      }
      let full = join_path(label_dir, name)
      let data = @fs.read_file(full) catch { _ => continue }
      let text = data.text() catch { _ => continue }
      items.push((full, text))
    }
    let entries = aggregate_label_entries(items)
    if entries.length() > 0 {
      return { path: label_dir, classes: entries, from_curated: false }
    }
  }
  // (3) fallback
  let entries : Array[ClassInfo] = []
  for c in fallback_classes {
    entries.push({ name: c, count: 0, color: "" })
  }
  { path: "", classes: entries, from_curated: false }
}

///|
/// Load a class list from an arbitrary `classes.json` path picked by
/// the user (e.g. via a native file dialog). Same reply shape as
/// `op_load_classes` so the frontend can render the result uniformly.
async fn op_load_classes_from_file(
  req : LoadClassesFromFileRequest,
) -> LoadClassesReply {
  let path = req.path
  if path == "" {
    fail("load_classes_from_file: empty path")
  }
  if !@fs.exists(path) {
    fail("load_classes_from_file: file not found: " + path)
  }
  let raw = @fs.read_file(path) catch {
    err =>
      fail(
        "load_classes_from_file: read " + path + " failed: " + err.to_string(),
      )
  }
  let text = raw.text() catch { _ => "" }
  let parsed = parse_curated_classes(text)
  let entries : Array[ClassInfo] = []
  for p in parsed {
    let (name, color) = p
    entries.push({ name, count: 0, color })
  }
  { path, classes: entries, from_curated: true }
}

///|
/// Result of parsing a curated class file. `name` is the class label,
/// `color` is a `#RRGGBB` string or "" when the format doesn't carry
/// colors (the legacy `{"classes":[...]}` JSON, for example).
type CuratedClass = (String, String) // (name, color)

///|
/// UTF-8 BOM (U+FEFF) as a Char literal.
let bom_char : Char = Int::unsafe_to_char(0xFEFF)

///|
/// Extract class names from a curated file. Two formats supported:
///
///   1. JSON: `{"classes":["a","b"]}` — returns the names with empty
///      color. Hand-parsed to avoid pulling in `@json`.
///   2. TXT:  `id|name|#RRGGBB` per line (UTF-8, often with BOM).
///      `id` is ignored; we only need `name` and `#RRGGBB` color. The
///      color string is normalized to `#RRGGBB` (8-digit `#AARRGGBB`
///      input is accepted and the leading alpha pair is dropped).
///
/// Empty lines and lines starting with `#` are skipped as comments.
/// Format is auto-detected: if the first non-whitespace character is
/// `{`, treat as JSON; otherwise treat as TXT.
fn parse_curated_classes(text : String) -> Array[CuratedClass] {
  // Strip BOM if present
  let trimmed_text = if text.length() > 0 &&
    Int::unsafe_to_char(text[0].to_int()) == bom_char {
    text[1:].to_owned()
  } else {
    text
  }
  // Auto-detect format by looking at the first non-whitespace char.
  let n = trimmed_text.length()
  let mut first_char : Char = ' '
  let mut probe = 0
  while probe < n {
    let c = Int::unsafe_to_char(trimmed_text[probe].to_int())
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      probe = probe + 1
      continue
    }
    first_char = c
    break
  }
  if first_char == '{' {
    parse_curated_json(trimmed_text)
  } else {
    parse_curated_txt(trimmed_text)
  }
}

///|
/// Parse `{"classes":["a","b"]}` JSON. Returns names with empty color.
fn parse_curated_json(text : String) -> Array[CuratedClass] {
  let out : Array[CuratedClass] = []
  let needle = "\"classes\""
  let n = text.length()
  let mut start : Int = -1
  let mut i = 0
  while i + needle.length() <= n {
    if text[i:i + needle.length()] == needle {
      start = i + needle.length()
      break
    }
    i = i + 1
  }
  if start < 0 {
    return out
  }
  // Find the first '['
  let mut j = start
  while j < n && text[j] != '[' {
    j = j + 1
  }
  if j >= n {
    return out
  }
  j = j + 1
  let buf = StringBuilder::new(size_hint=8)
  let mut in_str = false
  let mut escape = false
  while j < n {
    let ch = text[j]
    if in_str {
      if escape {
        buf.write_char(Int::unsafe_to_char(ch.to_int()))
        escape = false
      } else if ch == '\\' {
        escape = true
      } else if ch == '"' {
        in_str = false
        out.push((buf.to_string(), ""))
        buf.reset()
      } else {
        buf.write_char(Int::unsafe_to_char(ch.to_int()))
      }
    } else if ch == '"' {
      in_str = true
    } else if ch == ']' {
      break
    }
    j = j + 1
  }
  out
}

///|
/// Parse `id|name|#RRGGBB` TXT (one entry per line). Skips blank lines
/// and lines starting with `#`. Tolerates missing/short color column.
fn parse_curated_txt(text : String) -> Array[CuratedClass] {
  let out : Array[CuratedClass] = []
  let n = text.length()
  let mut line_start = 0
  while line_start < n {
    // Find end of line
    let mut line_end = line_start
    while line_end < n && text[line_end] != '\n' {
      line_end = line_end + 1
    }
    // Trim trailing \r
    let mut trim_end = line_end
    if trim_end > line_start && text[trim_end - 1] == '\r' {
      trim_end = trim_end - 1
    }
    // Skip leading whitespace
    let mut s = line_start
    while s < trim_end && (text[s] == ' ' || text[s] == '\t') {
      s = s + 1
    }
    if s < trim_end && text[s] != '#' {
      // Split on '|'. Format is `id|name|#RRGGBB` so we skip the
      // first column (id) and take the second column as `name`.
      let mut p1 = s
      while p1 < trim_end && text[p1] != '|' {
        p1 = p1 + 1
      }
      let p1_end = if p1 < trim_end { p1 } else { trim_end }
      let mut p2 = if p1 < trim_end { p1 + 1 } else { p1 }
      while p2 < trim_end && text[p2] != '|' {
        p2 = p2 + 1
      }
      let p2_end = if p2 < trim_end { p2 } else { trim_end }
      let name = slice_trim(text, p1_end + 1, p2_end)
      let raw_color = if p2 < trim_end {
        slice_trim(text, p2 + 1, trim_end)
      } else {
        ""
      }
      if name.length() > 0 {
        out.push((name, normalize_color(raw_color)))
      }
    }
    if line_end >= n {
      break
    }
    line_start = line_end + 1
  }
  out
}

///|
/// Substring `text[s:e]` rendered as an owned String (no UTF-8 boundary
/// checks — caller is expected to slice on ASCII boundaries, e.g. on
/// `|` delimiters or line endings).
fn slice_trim(text : String, s : Int, e : Int) -> String {
  let mut a = s
  let mut b = e
  while a < b && (text[a] == ' ' || text[a] == '\t') {
    a = a + 1
  }
  while b > a && (text[b - 1] == ' ' || text[b - 1] == '\t') {
    b = b - 1
  }
  let buf = StringBuilder::new(size_hint=b - a)
  let mut k = a
  while k < b {
    buf.write_char(Int::unsafe_to_char(text[k].to_int()))
    k = k + 1
  }
  buf.to_string()
}

///|
/// Normalize a color string to `#RRGGBB`. Accepts:
///   - `#RRGGBB`          → unchanged
///   - `#AARRGGBB`        → drop alpha, return `#RRGGBB`
///   - `RRGGBB`           → return `#RRGGBB`
///   - anything else      → return "" (no color)
fn normalize_color(s : String) -> String {
  if s.length() == 0 {
    return ""
  }
  // Uppercase
  let upper = upper(s)
  if upper.length() == 7 && upper[0] == '#' {
    return upper
  }
  if upper.length() == 9 && upper[0] == '#' {
    // #AARRGGBB → #RRGGBB
    return "#" + upper[3:9].to_owned()
  }
  if upper.length() == 6 {
    return "#" + upper
  }
  ""
}

///|
/// Returns a count map of class-name -> frequency inside the given
/// (already BOM-stripped) label JSON text.
fn collect_classes_from_text(text : String) -> Map[String, Int] {
  let counts : Map[String, Int] = Map([])
  // Simple scan: find every `"type":"..."` occurrence. Avoids a full JSON
  // parse for speed — the on-disk schema is small.
  let needle = "\"type\""
  let mut i = 0
  let n = text.length()
  while i < n {
    if i + 6 <= n && text[i:i + 6] == needle {
      // skip past needle, whitespace, then `:`, then `"`, then capture name
      let mut j = i + 6
      while j < n && (text[j] == ' ' || text[j] == '\t') {
        j = j + 1
      }
      if j < n && text[j] == ':' {
        j = j + 1
      }
      while j < n && (text[j] == ' ' || text[j] == '\t') {
        j = j + 1
      }
      if j < n && text[j] == '"' {
        j = j + 1
        let start = j
        while j < n && text[j] != '"' {
          j = j + 1
        }
        if j < n {
          let name = text[start:j].to_owned()
          let prev = counts.get(name).unwrap_or(0)
          counts[name] = prev + 1
          i = j + 1
          continue
        }
      }
    }
    i = i + 1
  }
  counts
}

///| --- video ops (ffmpeg / ffprobe) ---

///|
/// Resolve a unique temp JPEG path under `%TEMP%/moonbit-labeler-frames/`.
async fn video_frame_tmp_path() -> String {
  let dir = "C:\\Windows\\Temp\\moonbit-labeler-frames"
  // Best-effort: create the directory if it doesn't exist. Errors are
  // ignored — `ffmpeg -y` will fail loudly if the path is unusable, and
  // we surface that in `ok: false`.
  if !(@fs.exists(dir) catch { _ => false }) {
    @fs.mkdir(dir, recursive=true) catch {
      _ => ()
    }
  }
  let stamp = next_tmp_stamp().to_string()
  dir + "\\frame-" + stamp + ".jpg"
}

///|
async fn op_list_videos(req : ListVideosRequest) -> ListVideosReply {
  let exts = match req.extensions {
    Some(list) if list.length() > 0 => list
    _ => default_video_extensions
  }
  let names = @fs.readdir(req.path, include_hidden=false, sort=true)
  let videos : Array[VideoEntry] = []
  for name in names {
    if !is_video_ext(name, exts) {
      continue
    }
    let full = join_path(req.path, name)
    // size is best-effort; missing files just report 0.
    let data = @fs.read_file(full) catch { _ => continue }
    let bytes = data.binary()
    videos.push({
      name,
      path: full,
      ext: ext_of(name),
      size_bytes: bytes.length(),
    })
  }
  { folder: req.path, videos }
}

///|
/// Run ffprobe on a single video and parse a subset of the JSON output.
/// We only need: container duration, first video stream width/height/codec,
/// and a sensible fps. Any parsing error is reported as `ok: false` with
/// empty/zero fields, which the UI can detect and fall back to defaults.
async fn op_read_video_info(req : ReadVideoInfoRequest) -> ReadVideoInfoReply {
  let dbg = "C:\\Windows\\Temp\\moonbit-labeler-video-info.log"
  @fs.write_file(dbg, "", create_mode=@fs.CreateOrTruncate) catch {
    _ => ()
  }
  async fn log(s : String) {
    @fs.write_file(dbg, s + "\n", append=true, create_mode=@fs.OpenOrCreate) catch {
      _ => ()
    }
  }
  log("=== read_video_info start ===")
  log("path=" + req.path)
  let (exit_code, stdout_data) = @process.collect_stdout("ffprobe.exe", [
    "-v",
    "error",
    "-print_format",
    "json",
    "-show_streams",
    "-show_format",
    req.path,
  ]) catch {
    err => {
      log("ffprobe spawn failed: " + err.to_string())
      return {
        path: req.path,
        duration_ms: 0,
        fps: 0.0,
        frame_count: 0,
        width: 0,
        height: 0,
        codec: "",
        ok: false,
      }
    }
  }
  let stdout = stdout_data.text() catch {
    err => {
      log("ffprobe stdout decode failed: " + err.to_string())
      return {
        path: req.path,
        duration_ms: 0,
        fps: 0.0,
        frame_count: 0,
        width: 0,
        height: 0,
        codec: "",
        ok: false,
      }
    }
  }
  log(
    "ffprobe exit_code=" +
    exit_code.to_string() +
    " stdout_len=" +
    stdout.length().to_string(),
  )
  if exit_code != 0 {
    return {
      path: req.path,
      duration_ms: 0,
      fps: 0.0,
      frame_count: 0,
      width: 0,
      height: 0,
      codec: "",
      ok: false,
    }
  }
  // Parse width / height / fps from the first video stream.
  let (vw, vh, vfps, vcodec) = parse_first_video_stream(stdout)
  // Parse container-level duration.
  let duration_s = parse_format_duration_seconds(stdout)
  let duration_ms = if duration_s > 0.0 {
    (duration_s * 1000.0).to_int()
  } else {
    0
  }
  let frame_count = if vfps > 0.0 && duration_s > 0.0 {
    let n = (vfps * duration_s).to_int()
    if n < 1 {
      1
    } else {
      n
    }
  } else {
    0
  }
  log(
    "parsed: w=" +
    vw.to_string() +
    " h=" +
    vh.to_string() +
    " fps=" +
    vfps.to_string() +
    " codec=" +
    vcodec +
    " duration_ms=" +
    duration_ms.to_string() +
    " frame_count=" +
    frame_count.to_string(),
  )
  {
    path: req.path,
    duration_ms,
    fps: vfps,
    frame_count,
    width: vw,
    height: vh,
    codec: vcodec,
    ok: true,
  }
}

///|
/// Extract `(width, height, fps, codec)` from ffprobe JSON stdout. We do
/// a lightweight scan: find the first "streams" array entry with
/// `"codec_type":"video"`, then read the four fields we need. Numbers are
/// integers except fps (rational parsed as double).
fn parse_first_video_stream(json : String) -> (Int, Int, Double, String) {
  let mut w = 0
  let mut h = 0
  let mut fps = 0.0
  let mut codec = ""
  // Locate the first occurrence of "codec_type":"video".
  let pos_opt = find_key(json, 0, "codec_type")
  match pos_opt {
    None => (0, 0, 0.0, "")
    Some(idx) => {
      let (val_ok, val) = read_string_value(json, idx)
      if !val_ok || val != "video" {
        return (0, 0, 0.0, "")
      }
      let stream_start = idx
      let stream_end = match find_key(json, idx + 12, "codec_type") {
        Some(next) => next
        None => json.length()
      }
      let stream_block = json[stream_start:stream_end].to_owned()
      match find_number_in(stream_block, "width") {
        Some(v) => w = v
        None => ()
      }
      match find_number_in(stream_block, "height") {
        Some(v) => h = v
        None => ()
      }
      match find_quoted_string_value(stream_block, "codec_name") {
        Some(s) => codec = s
        None => ()
      }
      fps = find_fps_in(stream_block, "avg_frame_rate").unwrap_or(0.0)
      if fps <= 0.0 {
        fps = find_fps_in(stream_block, "r_frame_rate").unwrap_or(0.0)
      }
      (w, h, fps, codec)
    }
  }
}

///|
/// Read a JSON string value after a key (e.g. the "video" that comes
/// after `"codec_type":`). `key_open_idx` is the position of the opening
/// quote of the key. Returns (ok, value). The implementation walks
/// past the key + closing quote + colon + whitespace, then reads the
/// next quoted string. We return the bare value (no surrounding quotes).
fn read_string_value(json : String, key_open_idx : Int) -> (Bool, String) {
  let n = json.length()
  // Skip past the key, the closing quote, optional whitespace, the
  // colon, and the optional whitespace before the value's quote.
  let mut i = key_open_idx + 1
  // Walk to the next quote (closing quote of the key).
  while i < n && json[i] != '"' {
    i = i + 1
  }
  if i >= n {
    return (false, "")
  }
  i = i + 1
  // Skip whitespace and colon.
  while i < n &&
        (
          json[i] == ' ' ||
          json[i] == '\t' ||
          json[i] == '\n' ||
          json[i] == '\r'
        ) {
    i = i + 1
  }
  if i >= n || json[i] != ':' {
    return (false, "")
  }
  i = i + 1
  while i < n &&
        (
          json[i] == ' ' ||
          json[i] == '\t' ||
          json[i] == '\n' ||
          json[i] == '\r'
        ) {
    i = i + 1
  }
  if i >= n || json[i] != '"' {
    return (false, "")
  }
  let start = i + 1
  let mut j = start
  while j < n && json[j] != '"' {
    j = j + 1
  }
  if j > n {
    return (false, "")
  }
  (true, json[start:j].to_owned())
}

///|
/// Read `"duration": "<seconds>"` from the format section. Returns 0.0
/// if missing or unparseable.
fn parse_format_duration_seconds(json : String) -> Double {
  match find_quoted_string_value(json, "duration") {
    Some(s) => parse_double_text(s)
    None => 0.0
  }
}

///|
/// Find `"needle"` (the quoted JSON key itself) starting from `from`,
/// returning the index of the opening quote. Returns None if not found.
fn find_key(s : String, from : Int, needle : String) -> Int? {
  let n = s.length()
  let needle_len = needle.length()
  let mut i = from
  while i + needle_len + 2 <= n {
    if s[i] == '"' {
      let mut ok = true
      for k in 0..<needle_len {
        if i + 1 + k >= n || s[i + 1 + k] != needle[k] {
          ok = false
          break
        }
      }
      if ok && s[i + 1 + needle_len] == '"' {
        return Some(i)
      }
    }
    i = i + 1
  }
  None
}

///|
/// Find `"key": "<value>"` and return `value` (without quotes).
fn find_quoted_string_value(s : String, key : String) -> String? {
  let n = s.length()
  let key_len = key.length()
  let mut i = 0
  while i + key_len + 4 <= n {
    if s[i] == '"' {
      let mut ok = true
      for k in 0..<key_len {
        if s[i + 1 + k] != key[k] {
          ok = false
          break
        }
      }
      if ok && s[i + 1 + key_len] == '"' {
        // Skip whitespace + colon + whitespace + opening quote.
        let mut j = i + 2 + key_len
        while j < n &&
              (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') {
          j = j + 1
        }
        if j < n && s[j] == ':' {
          j = j + 1
          while j < n &&
                (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') {
            j = j + 1
          }
          if j < n && s[j] == '"' {
            let start = j + 1
            let mut k = start
            while k < n && s[k] != '"' {
              k = k + 1
            }
            if k <= n {
              return Some(s[start:k].to_owned())
            }
          }
        }
      }
    }
    i = i + 1
  }
  None
}

///|
/// Find `"key": <number>` and parse it as Int.
fn find_number_in(s : String, key : String) -> Int? {
  let n = s.length()
  let key_len = key.length()
  let mut i = 0
  while i + key_len + 4 <= n {
    if s[i] == '"' {
      let mut ok = true
      for k in 0..<key_len {
        if s[i + 1 + k] != key[k] {
          ok = false
          break
        }
      }
      if ok && s[i + 1 + key_len] == '"' {
        let mut j = i + 2 + key_len
        while j < n &&
              (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') {
          j = j + 1
        }
        if j < n && s[j] == ':' {
          j = j + 1
          while j < n &&
                (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') {
            j = j + 1
          }
          // Parse number.
          let start = j
          if j < n && s[j] == '-' {
            j = j + 1
          }
          let mut found_digit = false
          while j < n && s[j] >= '0' && s[j] <= '9' {
            j = j + 1
            found_digit = true
          }
          if found_digit {
            return Some(parse_int_range(s, start, j))
          }
        }
      }
    }
    i = i + 1
  }
  None
}

///|
/// Find `"key": "<num>/<den>"` and parse as double. Returns 0.0 on failure.
fn find_fps_in(s : String, key : String) -> Double? {
  let raw = match find_quoted_string_value(s, key) {
    Some(v) => v
    None => return None
  }
  // Split on '/'.
  let n = raw.length()
  let mut slash = -1
  for i in 0..<n {
    if raw[i] == '/' {
      slash = i
    }
  }
  if slash < 0 {
    return Some(parse_double_text(raw))
  }
  let num = parse_double_text(raw[:slash].to_owned())
  let den = parse_double_text(raw[slash + 1:].to_owned())
  if den == 0.0 {
    None
  } else {
    Some(num / den)
  }
}

///|
fn parse_int_range(s : String, start : Int, end : Int) -> Int {
  let mut result = 0
  let mut i = start
  while i < end {
    let c = s[i]
    if c < '0' || c > '9' {
      break
    }
    result = result * 10 + (c.to_int() - '0'.to_int())
    i = i + 1
  }
  result
}

///|
/// Parse a simple positive decimal directly from MoonBit characters.
fn parse_double_text(s : String) -> Double {
  let mut whole = 0.0
  let mut frac = 0.0
  let mut divisor = 1.0
  let mut in_frac = false
  let mut seen = false
  for c in s {
    if c == '.' {
      in_frac = true
      continue
    }
    if c < '0' || c > '9' {
      if seen {
        break
      } else {
        continue
      }
    }
    seen = true
    let d = (c.to_int() - '0'.to_int()).to_double()
    if in_frac {
      frac = frac * 10.0 + d
      divisor = divisor * 10.0
    } else {
      whole = whole * 10.0 + d
    }
  }
  if !seen {
    0.0
  } else {
    whole + frac / divisor
  }
}

///|
/// Cheap monotonically-increasing counter for unique temp-file names.
/// We used to shell out to PowerShell to get the current Unix time in
/// milliseconds, but MoonBit 0.4.43 doesn't ship a time package and
/// the PowerShell call was the only remaining `DateTimeOffset` use. A
/// monotonic counter is just as unique within a session and avoids
/// the process spawn.
let tmp_stamp_counter : @ref.Ref[Int] = @ref.new(0)

///|
/// Mint a fresh temp-file stamp. Pure-MoonBit, no PowerShell.
fn next_tmp_stamp() -> Int {
  tmp_stamp_counter.val = tmp_stamp_counter.val + 1
  tmp_stamp_counter.val
}

///|
/// Extract a single frame as a base64-encoded JPEG via ffmpeg.
async fn op_read_video_frame(
  req : ReadVideoFrameRequest,
) -> ReadVideoFrameReply {
  if req.frame < 0 {
    return {
      path: req.path,
      frame: req.frame,
      base64: "",
      mime: "image/jpeg",
      width: 0,
      height: 0,
      ok: false,
    }
  }
  // Probe fps / duration so we can convert frame -> seconds without
  // assuming a constant rate. For MVP we approximate fps=25 when probe
  // fails — typical CCTV footage. The user can always pick a frame and
  // see what comes out.
  let info = op_read_video_info({ path: req.path })
  let fps = if info.fps > 0.0 { info.fps } else { 25.0 }
  let sec = req.frame.to_double() / fps
  let tmp = video_frame_tmp_path()
  let q = match req.quality {
    Some(v) if v >= 1 && v <= 31 => v
    _ => 3
  }
  let (code, _out) = @process.collect_stdout("ffmpeg.exe", [
    "-loglevel",
    "error",
    "-ss",
    format_double(sec),
    "-i",
    req.path,
    "-frames:v",
    "1",
    "-q:v",
    q.to_string(),
    "-y",
    tmp,
  ]) catch {
    err => fail("ffmpeg spawn failed: " + err.to_string())
  }
  if code != 0 {
    // Best-effort cleanup.
    @fs.remove(tmp) catch {
      _ => ()
    }
    return {
      path: req.path,
      frame: req.frame,
      base64: "",
      mime: "image/jpeg",
      width: 0,
      height: 0,
      ok: false,
    }
  }
  let data = @fs.read_file(tmp) catch {
    err => {
      @fs.remove(tmp) catch {
        _ => ()
      }
      fail("read_video_frame read failed: " + err.to_string())
    }
  }
  let bytes = data.binary()
  let base64 = base64_encode(bytes)
  @fs.remove(tmp) catch {
    _ => ()
  }
  {
    path: req.path,
    frame: req.frame,
    base64,
    mime: "image/jpeg",
    width: info.width,
    height: info.height,
    ok: true,
  }
}

///|
/// Format a double as a short decimal string for ffmpeg `-ss`. We only
/// need millisecond precision (3 dp) for video frame seeks.
fn format_double(x : Double) -> String {
  // We don't have a generic formatter; do it manually.
  if x < 0.0 {
    return "-" + format_double(-x)
  }
  let whole = x.to_int()
  let frac_d = (x - whole.to_double()) * 1000.0
  let frac_i = if frac_d < 0.0 { 0 } else { frac_d.to_int() }
  // Strip trailing zeros from the fractional part to keep -ss compact.
  if frac_i == 0 {
    whole.to_string()
  } else if frac_i % 100 == 0 {
    whole.to_string() + "." + (frac_i / 100).to_string()
  } else if frac_i % 10 == 0 {
    whole.to_string() + "." + (frac_i / 10).to_string()
  } else {
    whole.to_string() + "." + frac_i.to_string()
  }
}

///| --- export helpers (VOC Pascal / YOLO TXT) ---

///|
/// Read image dimensions from a JPEG or PNG header. Returns `(0, 0)`
/// for unsupported formats or on parse failure. Cheap: only the first
/// few KB are inspected, never the full file.
async fn read_image_dims(path : String) -> (Int, Int) {
  if path == "" {
    return (0, 0)
  }
  let data = @fs.read_file(path) catch { _ => return (0, 0) }
  let bytes = data.binary()
  if bytes.length() < 24 {
    return (0, 0)
  }
  // PNG signature: 89 50 4E 47 0D 0A 1A 0A, then IHDR chunk.
  // width: bytes[16..20], height: bytes[20..24] (big-endian).
  if bytes[0] == b'\x89' &&
    bytes[1] == b'P' &&
    bytes[2] == b'N' &&
    bytes[3] == b'G' {
    let w = (bytes[16].to_int() << 24) |
      (bytes[17].to_int() << 16) |
      (bytes[18].to_int() << 8) |
      bytes[19].to_int()
    let h = (bytes[20].to_int() << 24) |
      (bytes[21].to_int() << 16) |
      (bytes[22].to_int() << 8) |
      bytes[23].to_int()
    return (w, h)
  }
  // JPEG: scan markers until we hit an SOFn. After the marker (1 byte)
  // + segment length (2 bytes), the next byte is sample precision, then
  // height (2 bytes), then width (2 bytes).
  if bytes[0] == b'\xFF' && bytes[1] == b'\xD8' {
    let n = bytes.length()
    let mut i = 2
    while i + 9 < n {
      // Skip non-marker padding bytes until we find a 0xFF marker.
      if bytes[i] != b'\xFF' {
        i = i + 1
        continue
      }
      // Skip duplicate 0xFF padding bytes (e.g. FF FF C0 -> seg at C0).
      while i < n && bytes[i] == b'\xFF' {
        i = i + 1
      }
      if i >= n {
        break
      }
      let marker = bytes[i].to_int()
      i = i + 1
      // Markers without payload (D8..D9, D0..D7 reset, 00/01 fill).
      if marker == 0xD8 ||
        marker == 0xD9 ||
        (marker >= 0xD0 && marker <= 0xD7) ||
        marker == 0x01 ||
        marker == 0x00 {
        continue
      }
      if i + 1 >= n {
        return (0, 0)
      }
      let seg_len = (bytes[i].to_int() << 8) | bytes[i + 1].to_int()
      // SOFn family: 0xC0..0xCF minus the DAC/dht-specific reserved
      // marks. C0/C1/C2/C3 are baseline/extended/progressive/lossless
      // and that's what most files in the wild use.
      let is_sof = marker == 0xC0 ||
        marker == 0xC1 ||
        marker == 0xC2 ||
        marker == 0xC3 ||
        (marker >= 0xC5 && marker <= 0xC7) ||
        (marker >= 0xC9 && marker <= 0xCB) ||
        (marker >= 0xCD && marker <= 0xCF)
      if is_sof && i + 7 < n {
        let h = (bytes[i + 3].to_int() << 8) | bytes[i + 4].to_int()
        let w = (bytes[i + 5].to_int() << 8) | bytes[i + 6].to_int()
        return (w, h)
      }
      if seg_len < 2 {
        return (0, 0)
      }
      i = i + seg_len
    }
  }
  (0, 0)
}

///|
/// --- shared label schema (parse / serialize, BOM-tolerant) ---
///
/// Single source of truth for the on-disk label JSON shape. The
/// frontend used to keep its own hand-rolled parser/serializer in
/// `frontend/src/label.js`; both are now expressed here so that any
/// future change to the schema is implemented once. Accepts both the
/// legacy `points: "x,y;x,y;..."` shape (CARS) and the modern
/// `points: [[x, y], ...]` shape, normalizes `shape` (inferring from
/// point count when missing), synthesizes missing `id`s, drops
/// annotations with empty `points`, and removes bindings that don't
/// reference real infos. UTF-8 BOMs are stripped on read.

///|
/// Global counter used to mint short unique ids when the on-disk
/// annotation is missing one.
let label_id_counter : @ref.Ref[Int] = @ref.new(0)

///|
/// Mint a short identifier with the given prefix (`obj`, `b`, ...).
/// Not cryptographically random, but unique enough within a session.
fn gen_label_id(prefix : String) -> String {
  label_id_counter.val = label_id_counter.val + 1
  prefix + "_" + label_id_counter.val.to_string()
}

///|
/// Strip a leading UTF-8 BOM (`U+FEFF`) if present.
fn strip_bom(s : String) -> String {
  if s.length() > 0 && s[0] == '\u{feff}' {
    String::unsafe_substring(s, start=1, end=s.length())
  } else {
    s
  }
}

///|
/// Pull a `String` field out of a JSON object map. Returns `""` when
/// the key is missing or the value isn't a string. Used by the schema
/// normalizer below.
fn json_get_string(obj : Map[String, Json], key : String) -> String {
  match obj.get(key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
/// Pull an `Int` from a JSON value, accepting either a JSON number or
/// a string of digits. Returns `None` when the value can't be parsed.
fn json_get_int(j : Json) -> Int? {
  match j {
    Number(n, ..) => Some(n.to_int())
    String(s) =>
      // `@string.parse_int` raises a string-typed error on bad input.
      // Use a sentinel pattern: the actual value is then masked off in
      // the result. For label files only small non-negative integers
      // are ever expected, so the `-1` sentinel can't collide.
      if s == "" {
        None
      } else {
        let parsed = @string.parse_int(s) catch { _ => -1 }
        if parsed < 0 {
          None
        } else {
          Some(parsed)
        }
      }
    _ => None
  }
}

///|
/// Read a list of `[[x, y], ...]` points out of a JSON value. Handles
/// both the modern shape `[[x, y], ...]` and the legacy shape
/// `"x,y;x,y;..."` (a single string of pairs separated by `;`).
fn json_get_points(j : Json) -> Array[Array[Double]] {
  let out : Array[Array[Double]] = []
  match j {
    Array(_) => {
      // Re-encode the JSON array to a string and reuse the existing
      // hand-rolled scanner. The array path is only a few hundred
      // bytes per file so the round-trip cost is negligible.
      let txt = j.stringify()
      let parsed = parse_points_array(txt, 0)
      for p in parsed {
        out.push([p.0, p.1])
      }
      out
    }
    String(s) => {
      let parsed = parse_points_string(s)
      for p in parsed {
        out.push([p.0, p.1])
      }
      out
    }
    _ => out
  }
}

///|
/// Encode a list of points as the modern `[[x, y], ...]` JSON array.
fn points_to_json(pts : Array[Array[Double]]) -> Json {
  let arr : Array[Json] = []
  for p in pts {
    arr.push(Json::array([Json::number(p[0]), Json::number(p[1])]))
  }
  Json::array(arr)
}

///|
/// Infer the shape name from a point count, matching the C# reference
/// tool's behaviour: 1 point = keypoint, 2 points = rect, otherwise
/// polygon.
fn infer_shape_from_points(pts : Array[Array[Double]]) -> String {
  match pts.length() {
    0 => "polygon"
    1 => "keypoint"
    2 => "rect"
    _ => "polygon"
  }
}

///|
/// Build a normalized label JSON object from a raw parsed `Json` value.
/// `fallback_img_name` is used when the raw object has no `img_name`.
fn normalize_label_json(raw : Json, fallback_img_name : String) -> Json {
  let members : Map[String, Json] = match raw {
    Object(m) => m
    _ => Map([])
  }
  let img_name = match members.get("img_name") {
    Some(String(s)) => s
    _ => fallback_img_name
  }
  let raw_infos : Array[Json] = match members.get("infos") {
    Some(Array(a)) => a
    _ => []
  }
  let raw_bindings : Array[Json] = match members.get("bindings") {
    Some(Array(a)) => a
    _ => []
  }
  let raw_frames : Array[Json] = match members.get("frames") {
    Some(Array(a)) => a
    _ => []
  }
  // First pass: normalize infos and collect their ids for binding
  // validation in the second pass below.
  let info_ids : Map[String, Bool] = Map([])
  let infos_out : Array[Json] = []
  for entry in raw_infos {
    let obj : Map[String, Json] = match entry {
      Object(m) => m
      _ => continue
    }
    let pts = json_get_points(obj.get("points").unwrap_or(Json::null()))
    if pts.length() == 0 {
      continue
    }
    let id = json_get_string(obj, "id")
    let id = if id == "" { gen_label_id("obj") } else { id }
    let shape = json_get_string(obj, "shape")
    let shape = if shape == "" { infer_shape_from_points(pts) } else { shape }
    let ann_type = json_get_string(obj, "type")
    let ann_type = if ann_type == "" { "object" } else { ann_type }
    info_ids.set(id, true)
    infos_out.push(
      Json::object(
        Map::from_array([
          ("id", Json::string(id)),
          ("shape", Json::string(shape)),
          ("type", Json::string(ann_type)),
          ("points", points_to_json(pts)),
        ]),
      ),
    )
  }
  // Second pass: bindings must reference real infos on both sides.
  let bindings_out : Array[Json] = []
  for entry in raw_bindings {
    let obj : Map[String, Json] = match entry {
      Object(m) => m
      _ => continue
    }
    let from = json_get_string(obj, "from")
    let to = json_get_string(obj, "to")
    if from == "" || to == "" || from == to {
      continue
    }
    if !info_ids.contains(from) || !info_ids.contains(to) {
      continue
    }
    let id = json_get_string(obj, "id")
    let id = if id == "" { gen_label_id("b") } else { id }
    let btype = json_get_string(obj, "type")
    let btype = if btype == "" { "same_group" } else { btype }
    bindings_out.push(
      Json::object(
        Map::from_array([
          ("id", Json::string(id)),
          ("from", Json::string(from)),
          ("to", Json::string(to)),
          ("type", Json::string(btype)),
        ]),
      ),
    )
  }
  // Frames: accept numbers (modern) or comma-separated strings
  // (legacy "1,2,3"). De-dup and sort ascending.
  let frames_set : Map[String, Bool] = Map([])
  let frames_acc : Array[Int] = []
  for entry in raw_frames {
    match json_get_int(entry) {
      Some(n) =>
        if n >= 0 {
          let key = n.to_string()
          if !frames_set.contains(key) {
            frames_set.set(key, true)
            frames_acc.push(n)
          }
        }
      None => ()
    }
  }
  frames_acc.sort()
  let frames_out : Array[Json] = []
  for n in frames_acc {
    frames_out.push(Json::number(n.to_double()))
  }
  // Assemble the final object. `frames` is omitted entirely when empty
  // so image-mode label files stay byte-identical to pre-video saves.
  let out_members : Map[String, Json] = Map::from_array([
    ("img_name", Json::string(img_name)),
    ("infos", Json::array(infos_out)),
    ("bindings", Json::array(bindings_out)),
  ])
  if frames_out.length() > 0 {
    out_members.set("frames", Json::array(frames_out))
  }
  Json::object(out_members)
}

///|
/// Parse a label JSON text and return a normalized, modern-schema JSON
/// text. Accepts both legacy (`points: "x,y;..."`) and modern
/// (`points: [[x, y], ...]`) shapes. Returns `(label_text, "")` on
/// success and raises the underlying parser error on failure so the
/// op layer can convert it to a structured reply.
fn parse_label_text(
  text : String,
  fallback_img_name : String,
) -> (String, String) raise {
  let stripped = strip_bom(text)
  let raw = @json.parse(stripped) catch { err => raise err }
  let normalized = normalize_label_json(raw, fallback_img_name)
  (normalized.stringify(), "")
}

///|
/// Re-serialize a label JSON text to the modern schema. Frontend
/// `serializeLabel()` was the previous owner of this logic; now the
/// IPC layer round-trips through the same normalizer. Always writes
/// `id`, `shape`, and `points` as nested arrays; rounds pixel
/// coordinates to integers; `frames` is included only when non-empty.
/// Raises the underlying parser error on failure.
fn serialize_label_text(text : String) -> (String, String) raise {
  let stripped = strip_bom(text)
  let raw = @json.parse(stripped) catch { err => raise err }
  let normalized = normalize_label_json(raw, "")
  // Round all coordinates to integers to match the on-disk convention
  // and avoid the editor accumulating floating-point drift across
  // saves. We walk the `infos[*].points[*]` arrays we just built.
  let out = match normalized {
    Object(m) => {
      let infos : Array[Json] = match m.get("infos") {
        Some(Array(a)) => a
        _ => []
      }
      let new_infos : Array[Json] = []
      for entry in infos {
        let info_obj : Map[String, Json] = match entry {
          Object(o) => o
          _ => {
            new_infos.push(entry)
            continue
          }
        }
        let points : Array[Json] = match info_obj.get("points") {
          Some(Array(a)) => a
          _ => {
            new_infos.push(entry)
            continue
          }
        }
        let new_points : Array[Json] = []
        for p in points {
          match p {
            Array(coords) => {
              let rounded : Array[Json] = []
              for c in coords {
                match c {
                  Number(n, ..) => rounded.push(Json::number(n.round()))
                  _ => rounded.push(c)
                }
              }
              new_points.push(Json::array(rounded))
            }
            _ => new_points.push(p)
          }
        }
        info_obj.set("points", Json::array(new_points))
        new_infos.push(Json::object(info_obj))
      }
      m.set("infos", Json::array(new_infos))
      Json::object(m)
    }
    _ => normalized
  }
  (out.stringify(), "")
}

///|
/// Look for `"key": <value>` in a JSON text, scanning only after
/// offset `from`. Returns the index of the value's first byte (right
/// after `:` and any whitespace) or `-1` if not found. Hand-rolled to
/// stay consistent with the other light parsers in this file.
fn find_value_after_key(s : String, from : Int, key : String) -> Int {
  let n = s.length()
  let key_len = key.length()
  let mut i = from
  while i + key_len + 4 <= n {
    if s[i] == '"' {
      let mut ok = true
      let mut k = 0
      while k < key_len {
        if s[i + 1 + k] != key[k] {
          ok = false
          break
        }
        k = k + 1
      }
      if ok && s[i + 1 + key_len] == '"' {
        let mut j = i + 2 + key_len
        while j < n &&
              (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') {
          j = j + 1
        }
        if j < n && s[j] == ':' {
          j = j + 1
          while j < n &&
                (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') {
            j = j + 1
          }
          return j
        }
      }
    }
    i = i + 1
  }
  -1
}

///|
/// Read a JSON string literal starting at `s[idx]` (which must be `"`).
/// Returns the parsed string (without surrounding quotes) and advances
/// `idx` past the closing quote. Supports `\"`, `\\`, `\/`, `\n`, `\r`,
/// `\t`, `\b`, `\f`, `\uXXXX` — more than we need for label JSON but
/// cheap to include.
fn read_json_string(s : String, idx : Int) -> (String, Int)? {
  let n = s.length()
  if idx >= n || s[idx] != '"' {
    return None
  }
  let mut j = idx + 1
  let buf = StringBuilder::new(size_hint=16)
  while j < n {
    let c = s[j]
    if c == '\\' {
      if j + 1 >= n {
        return None
      }
      let e = Int::unsafe_to_char(s[j + 1].to_int())
      if e == '"' {
        buf.write_char('"')
      } else if e == '\\' {
        buf.write_char('\\')
      } else if e == '/' {
        buf.write_char('/')
      } else if e == 'n' {
        buf.write_char('\n')
      } else if e == 'r' {
        buf.write_char('\r')
      } else if e == 't' {
        buf.write_char('\t')
      } else if e == 'b' {
        buf.write_char('\b')
      } else if e == 'f' {
        buf.write_char('\u000C')
      } else if e == 'u' {
        // \uXXXX — keep the literal escape so the caller doesn't see
        // a charset-converted char. Our annotations don't use any.
        buf.write_string("\\u")
      } else {
        buf.write_char(e)
      }
      j = j + 2
      continue
    }
    if c == '"' {
      return Some((buf.to_string(), j + 1))
    }
    buf.write_char(Int::unsafe_to_char(c.to_int()))
    j = j + 1
  }
  None
}

///|
/// Parse one entry from the `infos` array starting at `s[idx]`
/// (which must be `{`). Returns the parsed annotation and the index
/// right after the closing `}`. Returns `None` if the entry is not
/// a recognizable object — caller skips it.
fn parse_one_info(s : String, idx : Int) -> (ExportAnn, Int)? {
  let n = s.length()
  if idx >= n || s[idx] != '{' {
    return None
  }
  // Find the matching '}'. Naive but cheap — labels don't have nested
  // braces inside `infos` entries except potentially in `"shape"` keys
  // which are just strings. Strings can't contain unescaped `"`, so a
  // state-aware scan is enough.
  let mut depth = 0
  let mut j = idx
  let mut in_str = false
  let mut escape = false
  while j < n {
    let c = s[j]
    if in_str {
      if escape {
        escape = false
      } else if c == '\\' {
        escape = true
      } else if c == '"' {
        in_str = false
      }
      j = j + 1
      continue
    }
    if c == '"' {
      in_str = true
      j = j + 1
      continue
    }
    if c == '{' {
      depth = depth + 1
    } else if c == '}' {
      depth = depth - 1
      if depth == 0 {
        break
      }
    }
    j = j + 1
  }
  if depth != 0 {
    return None
  }
  let entry_end = j
  let entry_text = s[idx:entry_end + 1].to_owned()
  // Extract `type`, `shape`, `points` from the entry text.
  let type_pos = find_value_after_key(entry_text, 0, "type")
  let shape_pos = find_value_after_key(entry_text, 0, "shape")
  let points_pos = find_value_after_key(entry_text, 0, "points")
  let type_str : String = match type_pos {
    -1 => ""
    p =>
      match read_json_string(entry_text, p) {
        Some((v, _)) => v
        None => ""
      }
  }
  if type_str.length() == 0 {
    return None
  }
  let shape_str : String = match shape_pos {
    -1 => ""
    p =>
      match read_json_string(entry_text, p) {
        Some((v, _)) => v
        None => ""
      }
  }
  // `points` is either a string `"x,y;x,y;..."` or an array
  // `[[x,y],[x,y],...]`. We look at the first non-whitespace byte
  // right after `:` to decide.
  let pts = match points_pos {
    -1 => []
    p => {
      let mut k = p
      while k < entry_text.length() &&
            (
              entry_text[k] == ' ' ||
              entry_text[k] == '\t' ||
              entry_text[k] == '\n' ||
              entry_text[k] == '\r'
            ) {
        k = k + 1
      }
      if k < entry_text.length() && entry_text[k] == '"' {
        // string form
        match read_json_string(entry_text, k) {
          Some((v, _)) => parse_points_string(v)
          None => []
        }
      } else if k < entry_text.length() && entry_text[k] == '[' {
        // array form — but it may be a string `[[x,y],...]` literally
        // rather than a real nested array. Re-serialise by JSON-style
        // scan: count brackets, find each [x,y] sub-array.
        parse_points_array(entry_text, k)
      } else {
        []
      }
    }
  }
  if pts.length() == 0 {
    return None
  }
  let resolved_shape = if shape_str.length() > 0 {
    shape_str
  } else if pts.length() == 1 {
    "keypoint"
  } else if pts.length() == 2 {
    "rect"
  } else {
    "polygon"
  }
  Some(({ shape: resolved_shape, type_: type_str, points: pts }, entry_end + 1))
}

///|
/// Parse `"x,y;x,y;..."` -> array of `(x, y)` doubles. Mirrors the
/// legacy wire format used by the older C# tool.
fn parse_points_string(s : String) -> Array[(Double, Double)] {
  let out : Array[(Double, Double)] = []
  let n = s.length()
  let mut i = 0
  while i < n {
    let mut j = i
    while j < n && s[j] != ';' {
      j = j + 1
    }
    let mut k = i
    while k < j && s[k] != ',' {
      k = k + 1
    }
    if k < j {
      let xs = s[i:k].to_owned()
      let ys = s[k + 1:j].to_owned()
      let x = parse_double_text(xs)
      let y = parse_double_text(ys)
      out.push((x, y))
    }
    if j >= n {
      break
    }
    i = j + 1
  }
  out
}

///|
/// Parse `[[x,y],[x,y],...]` starting at the opening `[`. We balance
/// brackets and skip string contents. Each inner `[...]` becomes one
/// `(x, y)` point.
fn parse_points_array(s : String, start : Int) -> Array[(Double, Double)] {
  let out : Array[(Double, Double)] = []
  let n = s.length()
  if start >= n || s[start] != '[' {
    return out
  }
  // Skip the outer `[`. Then we look for every inner `[` pair until
  // the matching outer `]`.
  let mut i = start + 1
  while i < n && s[i] != ']' {
    // Skip whitespace + commas between entries.
    while i < n &&
          (
            s[i] == ' ' ||
            s[i] == '\t' ||
            s[i] == '\n' ||
            s[i] == ',' ||
            s[i] == '\r'
          ) {
      i = i + 1
    }
    if i >= n || s[i] == ']' {
      break
    }
    // Expect inner `[`.
    if s[i] != '[' {
      // Unexpected token — skip to next comma or close.
      while i < n && s[i] != ',' && s[i] != ']' {
        i = i + 1
      }
      continue
    }
    // Walk to matching `]` for this inner array, skipping string contents.
    let entry_start = i + 1
    let mut j = i + 1
    let mut depth = 1
    let mut in_str = false
    let mut escape = false
    while j < n && depth > 0 {
      let cj = s[j]
      if in_str {
        if escape {
          escape = false
        } else if cj == '\\' {
          escape = true
        } else if cj == '"' {
          in_str = false
        }
        j = j + 1
        continue
      }
      if cj == '"' {
        in_str = true
        j = j + 1
        continue
      }
      if cj == '[' {
        depth = depth + 1
      } else if cj == ']' {
        depth = depth - 1
        if depth == 0 {
          break
        }
      }
      j = j + 1
    }
    if depth != 0 {
      // Unbalanced — bail out.
      return out
    }
    // Extract content between entry_start and j (exclusive).
    let inner = s[entry_start:j].to_owned()
    // Trim leading/trailing whitespace.
    let mut a = 0
    let mut b = inner.length()
    while a < b && (inner[a] == ' ' || inner[a] == '\t') {
      a = a + 1
    }
    while b > a && (inner[b - 1] == ' ' || inner[b - 1] == '\t') {
      b = b - 1
    }
    // Split at first comma.
    let mut k = a
    while k < b && inner[k] != ',' {
      k = k + 1
    }
    if k < b {
      let xs = inner[a:k].to_owned()
      let ys = inner[k + 1:b].to_owned()
      let xv = parse_double_text(xs)
      let yv = parse_double_text(ys)
      out.push((xv, yv))
    }
    i = j + 1
  }
  out
}

///|
/// Parse the `infos` array of a label JSON file. Returns normalised
/// `(shape, type, points)` triples — empty on any structural error so
/// a single bad label can't kill an export run.
fn parse_export_anns(text : String) -> Array[ExportAnn] {
  let out : Array[ExportAnn] = []
  // Strip UTF-8 BOM if present.
  let trimmed = if text.length() > 0 &&
    Int::unsafe_to_char(text[0].to_int()) == bom_char {
    text[1:].to_owned()
  } else {
    text
  }
  let infos_pos = find_value_after_key(trimmed, 0, "infos")
  if infos_pos < 0 {
    return out
  }
  // infos must be an array — find the matching '['.
  let mut j = infos_pos
  while j < trimmed.length() && trimmed[j] != '[' {
    j = j + 1
  }
  if j >= trimmed.length() {
    return out
  }
  // Walk past the '[' looking for each '{'.
  let mut i = j + 1
  let n = trimmed.length()
  while i < n {
    let c = trimmed[i]
    if c == ']' {
      break
    }
    if c == '{' {
      match parse_one_info(trimmed, i) {
        Some((ann, next_i)) => {
          out.push(ann)
          i = next_i
          continue
        }
        None => i = i + 1
      }
    } else {
      i = i + 1
    }
  }
  out
}

///|
/// Compute the axis-aligned bbox `(xmin, ymin, xmax, ymax)` of a
/// polygon's points. Coordinates are returned as `Double` so they can
/// be either rounded to int or normalized to 0..1 by the caller.
fn polygon_bbox(
  pts : Array[(Double, Double)],
) -> (Double, Double, Double, Double) {
  let mut xmin : Double = 1.0e18
  let mut ymin : Double = 1.0e18
  let mut xmax : Double = -1.0e18
  let mut ymax : Double = -1.0e18
  for p in pts {
    let (x, y) = p
    if x < xmin {
      xmin = x
    }
    if x > xmax {
      xmax = x
    }
    if y < ymin {
      ymin = y
    }
    if y > ymax {
      ymax = y
    }
  }
  (xmin, ymin, xmax, ymax)
}

///|
/// XML-escape a string so it's safe to embed inside an element body
/// or attribute value. We don't bother with `<![CDATA[…]]>` blocks —
/// the C# reference uses plain `&lt; &gt; &amp; &quot; &apos;`
/// escapes and that round-trips with every parser we care about.
fn xml_escape(s : String) -> String {
  let buf = StringBuilder::new(size_hint=s.length())
  for c in s {
    if c == '<' {
      buf.write_string("&lt;")
    } else if c == '>' {
      buf.write_string("&gt;")
    } else if c == '&' {
      buf.write_string("&amp;")
    } else if c == '"' {
      buf.write_string("&quot;")
    } else if c == '\'' {
      buf.write_string("&apos;")
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
/// Round a positive double to the nearest integer (half-up).
fn round_half_up(x : Double) -> Int {
  let whole = x.to_int()
  let frac = x - whole.to_double()
  if frac >= 0.5 {
    whole + 1
  } else {
    whole
  }
}

///|
/// Build the body of a Pascal VOC `.xml` file for one image. `width`
/// and `height` are the image dimensions in pixels; each `info` is
/// rendered as `<object><name>...</name><bndbox>...</bndbox></object>`.
/// Keypoints are skipped (their 1-point bbox would be 0×0 and confuse
/// every VOC loader).
fn voc_xml_for(
  folder : String,
  filename : String,
  width : Int,
  height : Int,
  anns : Array[ExportAnn],
) -> String {
  let buf = StringBuilder::new(size_hint=256 + anns.length() * 96)
  buf.write_string("<annotation>\n")
  buf.write_string("  <folder>")
  buf.write_string(xml_escape(folder))
  buf.write_string("</folder>\n   <filename>")
  buf.write_string(xml_escape(filename))
  buf.write_string("</filename>\n")

  buf.write_string(
    "  <source>\n    <database>MoonBitLabeler</database>\n  </source>\n",
  )
  buf.write_string("  <size>\n    <width>")
  buf.write_string(width.to_string())
  buf.write_string("</width>\n    <height>")
  buf.write_string(height.to_string())
  buf.write_string("</height>\n    <depth>3</depth>\n  </size>\n")
  buf.write_string("  <segmented>0</segmented>\n")
  for info in anns {
    if info.shape == "keypoint" {
      continue
    }
    let (xmin, ymin, xmax, ymax) = polygon_bbox(info.points)
    let xn = if xmin < 0.0 {
      0.0
    } else if xmin > 99999.0 {
      99999.0
    } else {
      xmin
    }
    let yn = if ymin < 0.0 {
      0.0
    } else if ymin > 99999.0 {
      99999.0
    } else {
      ymin
    }
    let xx = if xmax < 0.0 {
      0.0
    } else if xmax > 99999.0 {
      99999.0
    } else {
      xmax
    }
    let yx = if ymax < 0.0 {
      0.0
    } else if ymax > 99999.0 {
      99999.0
    } else {
      ymax
    }
    buf.write_string("  <object>\n    <name>")
    buf.write_string(xml_escape(info.type_))
    buf.write_string("</name>\n    <pose>Unspecified</pose>\n")
    buf.write_string("    <truncated>0</truncated>\n")
    buf.write_string("    <difficult>0</difficult>\n")
    buf.write_string("    <bndbox>\n      <xmin>")
    buf.write_string(round_half_up(xn).to_string())
    buf.write_string("</xmin>\n      <ymin>")
    buf.write_string(round_half_up(yn).to_string())
    buf.write_string("</ymin>\n      <xmax>")
    buf.write_string(round_half_up(xx).to_string())
    buf.write_string("</xmax>\n      <ymax>")
    buf.write_string(round_half_up(yx).to_string())
    buf.write_string("</ymax>\n    </bndbox>\n  </object>\n")
  }
  buf.write_string("</annotation>\n")
  buf.to_string()
}

///|
/// Build the body of one YOLO `.txt` file. Each annotation becomes a
/// single line: `<class_id> <cx> <cy> <w> <h>` with each coordinate
/// normalised to `[0, 1]` against the image dimensions. Empty output
/// when the image has no qualifying boxes (a YOLO convention).
fn yolo_txt_for(
  class_ids : Map[String, Int],
  anns : Array[ExportAnn],
  width : Int,
  height : Int,
) -> String {
  if width <= 0 || height <= 0 {
    return ""
  }
  let buf = StringBuilder::new(size_hint=anns.length() * 32)
  let w = width.to_double()
  let h = height.to_double()
  for info in anns {
    if info.shape == "keypoint" {
      continue
    }
    let cid = match class_ids.get(info.type_) {
      Some(v) => v
      None => continue
    }
    let (xmin, ymin, xmax, ymax) = polygon_bbox(info.points)
    let bw = xmax - xmin
    let bh = ymax - ymin
    if bw <= 0.0 || bh <= 0.0 {
      continue
    }
    let cx = (xmin + xmax) / 2.0 / w
    let cy = (ymin + ymax) / 2.0 / h
    let nw = bw / w
    let nh = bh / h
    buf.write_string(cid.to_string())
    buf.write_char(' ')
    buf.write_string(format_yolo_coord(cx))
    buf.write_char(' ')
    buf.write_string(format_yolo_coord(cy))
    buf.write_char(' ')
    buf.write_string(format_yolo_coord(nw))
    buf.write_char(' ')
    buf.write_string(format_yolo_coord(nh))
    buf.write_char('\n')
  }
  buf.to_string()
}

///|
/// Format a YOLO normalised coordinate with 6 fractional digits —
/// enough resolution for sub-pixel boxes without bloating the file.
fn format_yolo_coord(x : Double) -> String {
  if x < 0.0 {
    return "0.000000"
  }
  if x > 1.0 {
    return "1.000000"
  }
  let whole = x.to_int()
  let frac_d = (x - whole.to_double()) * 1_000_000.0
  let frac_i = if frac_d < 0.0 { 0 } else { frac_d.to_int() }
  pad_left_zeros(whole.to_string(), frac_i, 6)
}

///|
/// Combine an integer part and a 6-digit fractional part into a YOLO
/// coordinate. The frac must already be in `[0, 999_999]`; we left-
/// pad it to the requested width.
fn pad_left_zeros(whole : String, frac : Int, width : Int) -> String {
  let frac_str = frac.to_string()
  let n = width - frac_str.length()
  let mut padded = frac_str
  if n > 0 {
    let mut k = 0
    let buf = StringBuilder::new(size_hint=n)
    while k < n {
      buf.write_char('0')
      k = k + 1
    }
    padded = buf.to_string() + frac_str
  }
  whole + "." + padded
}

///| --- export ops ---

///|
/// Look up the matching image filename (with extension) for a stem in
/// `image_dir`. Returns "" if no candidate is found. The image may
/// have any extension recognised by `default_image_extensions`; the
/// search is case-insensitive on the extension.
async fn find_image_filename(image_dir : String, stem : String) -> String {
  let names = @fs.readdir(image_dir, include_hidden=false, sort=false) catch {
    _ => []
  }
  for n in names {
    let lname = lower(n)
    if !is_image_ext(lname, default_image_extensions) {
      continue
    }
    let (s, _) = split_stem_ext(n)
    if s == stem {
      return n
    }
  }
  ""
}

///|
/// Add `value` to `classes_ordered` if not already present (compare
/// strings; helper used by both export drivers).
fn dedup_push(classes_ordered : Array[String], value : String) -> Unit {
  let mut has = false
  for c in classes_ordered {
    if c == value {
      has = true
      break
    }
  }
  if !has {
    classes_ordered.push(value)
  }
}

///|
/// Write a string to `path` via direct MoonBit `@fs.write_file` (UTF-8
/// encoded). Returns `true` on success, `false` on any fs error.
async fn write_text_or_log(path : String, content : String) -> Bool {
  @fs.write_file(path, content, create_mode=@fs.CreateOrTruncate) catch {
    _ => return false
  }
  true
}

///|
/// Driver: walk image/label pairs and write one Pascal VOC `.xml`
/// per labelled image into `dest_folder`.
async fn export_voc_internal(
  image_dir : String,
  label_dir : String,
  dest_folder : String,
) -> ExportReply {
  ensure_dir(dest_folder)
  let names = @fs.readdir(label_dir, include_hidden=false, sort=true) catch {
    _ => []
  }
  let pairs : Array[(String, String)] = []
  for name in names {
    let lname = lower(name)
    if !lname.has_suffix(".json") {
      continue
    }
    let (stem, _) = split_stem_ext(name)
    if stem.length() == 0 {
      continue
    }
    let img = find_image_filename(image_dir, stem)
    if img == "" {
      continue
    }
    pairs.push((stem, join_path(label_dir, name)))
  }
  let mut exported = 0
  let mut skipped = 0
  let classes_ordered : Array[String] = []
  let dbg = "C:\\Users\\hp\\.minimax\\moonbit-labeler-export-voc.log"
  @fs.write_file(
    dbg,
    "=== export_voc start ===\n",
    create_mode=@fs.CreateOrTruncate,
  ) catch {
    _ => ()
  }
  async fn elog(s : String) {
    @fs.write_file(dbg, s + "\n", append=true, create_mode=@fs.OpenOrCreate) catch {
      _ => ()
    }
  }
  elog("pairs=" + pairs.length().to_string())
  for pair in pairs {
    let (stem, label_path) = pair
    let img_filename = find_image_filename(image_dir, stem)
    if img_filename == "" {
      elog("skip " + stem + " (no image)")
      skipped = skipped + 1
      continue
    }
    let data = @fs.read_file(label_path) catch {
      _ => {
        elog("skip " + stem + " (read fail)")
        skipped = skipped + 1
        continue
      }
    }
    let text = data.text() catch {
      _ => {
        elog("skip " + stem + " (text decode fail)")
        skipped = skipped + 1
        continue
      }
    }
    elog("read " + stem + " bytes=" + text.length().to_string())
    let anns = parse_export_anns(text)
    elog("parse " + stem + " -> " + anns.length().to_string() + " anns")
    if anns.length() == 0 {
      // Print first 200 chars of the label so we can see what the
      // parser swallowed.
      let preview = if text.length() < 200 {
        text
      } else {
        text[0:200].to_owned()
      }
      elog("preview: " + preview)
      skipped = skipped + 1
      continue
    }
    let (w, h) = read_image_dims(join_path(image_dir, img_filename))
    for a in anns {
      dedup_push(classes_ordered, a.type_)
    }
    let folder_leaf = last_path_component(image_dir)
    let xml = voc_xml_for(folder_leaf, img_filename, w, h, anns)
    let out_path = join_path(dest_folder, stem + ".xml")
    if write_text_or_log(out_path, xml) {
      exported = exported + 1
    } else {
      elog("skip " + stem + " (write fail)")
      skipped = skipped + 1
    }
  }
  {
    dest_folder,
    exported_count: exported,
    skipped_count: skipped,
    classes: classes_ordered,
  }
}

///|
/// Driver: walk image/label pairs and write one YOLO `.txt` per
/// labelled image plus a global `classes.txt`.
async fn export_yolo_internal(
  image_dir : String,
  label_dir : String,
  dest_folder : String,
) -> ExportReply {
  ensure_dir(dest_folder)
  let names = @fs.readdir(label_dir, include_hidden=false, sort=true) catch {
    _ => []
  }
  // Pre-walk to gather (stem -> anns) plus the ordered class list.
  let classes_ordered : Array[String] = []
  let pair_anns : Array[(String, Array[ExportAnn])] = []
  for name in names {
    let lname = lower(name)
    if !lname.has_suffix(".json") {
      continue
    }
    let (stem, _) = split_stem_ext(name)
    if stem.length() == 0 {
      continue
    }
    let img = find_image_filename(image_dir, stem)
    if img == "" {
      continue
    }
    let data = @fs.read_file(join_path(label_dir, name)) catch { _ => continue }
    let text = data.text() catch { _ => continue }
    let anns = parse_export_anns(text)
    if anns.length() == 0 {
      continue
    }
    for a in anns {
      dedup_push(classes_ordered, a.type_)
    }
    pair_anns.push((stem, anns))
  }
  // Map class name -> id.
  let class_ids : Map[String, Int] = Map([])
  let mut i = 0
  while i < classes_ordered.length() {
    class_ids[classes_ordered[i]] = i
    i = i + 1
  }
  // Build classes.txt first; if it fails we abort without orphan
  // per-image files (well, sort of — we may still have written empty
  // per-image txts from earlier ops on a re-run; the user can clear
  // dest_folder if they want a clean redo).
  let cls_buf = StringBuilder::new(size_hint=classes_ordered.length() * 16)
  let mut k = 0
  while k < classes_ordered.length() {
    cls_buf.write_string(classes_ordered[k])
    cls_buf.write_char('\n')
    k = k + 1
  }
  let classes_path = join_path(dest_folder, "classes.txt")
  if !write_text_or_log(classes_path, cls_buf.to_string()) {
    return {
      dest_folder,
      exported_count: 0,
      skipped_count: pair_anns.length(),
      classes: classes_ordered,
    }
  }
  let mut exported = 0
  let mut total_skipped = 0
  for triple in pair_anns {
    let (stem, anns) = triple
    let img_filename = find_image_filename(image_dir, stem)
    if img_filename == "" {
      total_skipped = total_skipped + 1
      continue
    }
    let image_path_real = join_path(image_dir, img_filename)
    let (w, h) = read_image_dims(image_path_real)
    if w <= 0 || h <= 0 {
      total_skipped = total_skipped + 1
      continue
    }
    let body = yolo_txt_for(class_ids, anns, w, h)
    let out_path = join_path(dest_folder, stem + ".txt")
    if write_text_or_log(out_path, body) {
      exported = exported + 1
    } else {
      total_skipped = total_skipped + 1
    }
  }
  {
    dest_folder,
    exported_count: exported,
    skipped_count: total_skipped,
    classes: classes_ordered,
  }
}

///|
/// Last segment of a path, with both `/` and `\` supported.
fn last_path_component(p : String) -> String {
  let (_dir, leaf) = split_dir_name(p)
  leaf
}

///|
/// Request to export a folder of labels as Pascal VOC `.xml` files.
/// `image_path` may be a directory or any file inside it (the file is
/// only used to resolve the image/label folder pair via the standard
/// convention). `dest_folder` is the destination directory which is
/// created if missing.
pub struct ExportVocRequest {
  image_path : String
  dest_folder : String
} derive(FromJson, ToJson, Eq, Debug)

///|
async fn op_export_voc_folder(req : ExportVocRequest) -> ExportReply {
  if req.dest_folder == "" {
    fail("export_voc_folder: dest_folder is empty")
  }
  let image_dir = derive_image_dir(req.image_path)
  if image_dir == "" {
    fail("export_voc_folder: cannot determine image dir for " + req.image_path)
  }
  let label_dir = derive_label_dir_for_scan(image_dir)
  if label_dir == "" {
    fail(
      "export_voc_folder: cannot determine label dir for " +
      image_dir +
      " (image dir must follow the Image@<name> convention)",
    )
  }
  export_voc_internal(image_dir, label_dir, req.dest_folder)
}

///|
/// Request to export a folder of labels as YOLO `.txt` files plus a
/// global `classes.txt`. Same input conventions as `export_voc_folder`.
pub struct ExportYoloRequest {
  image_path : String
  dest_folder : String
} derive(FromJson, ToJson, Eq, Debug)

///|
async fn op_export_yolo_folder(req : ExportYoloRequest) -> ExportReply {
  if req.dest_folder == "" {
    fail("export_yolo_folder: dest_folder is empty")
  }
  let image_dir = derive_image_dir(req.image_path)
  if image_dir == "" {
    fail("export_yolo_folder: cannot determine image dir for " + req.image_path)
  }
  let label_dir = derive_label_dir_for_scan(image_dir)
  if label_dir == "" {
    fail(
      "export_yolo_folder: cannot determine label dir for " +
      image_dir +
      " (image dir must follow the Image@<name> convention)",
    )
  }
  export_yolo_internal(image_dir, label_dir, req.dest_folder)
}

///|
/// Parse a label JSON text via the shared schema normalizer. See
/// `parse_label_text` for the actual logic.
#warnings("-unused_async")
async fn op_parse_label(req : ParseLabelRequest) -> ParseLabelReply {
  let fallback = match req.fallback_img_name {
    Some(s) => s
    None => ""
  }
  let (text, err) = parse_label_text(req.text, fallback) catch {
    e => ("", "parse_label failed: " + e.to_string())
  }
  if err != "" {
    { ok: false, label_text: "", error: err }
  } else {
    { ok: true, label_text: text, error: "" }
  }
}

///|
/// Re-serialize a label JSON text via the shared schema normalizer.
/// See `serialize_label_text` for the actual logic.
#warnings("-unused_async")
async fn op_serialize_label(req : SerializeLabelRequest) -> SerializeLabelReply {
  let (text, err) = serialize_label_text(req.label_text) catch {
    e => ("", "serialize_label failed: " + e.to_string())
  }
  if err != "" {
    { ok: false, text: "", error: err }
  } else {
    { ok: true, text, error: "" }
  }
}

///|
/// --- extension registration ---
pub fn extension() -> @proton_extension.Extension {
  @proton_extension.from_command_spec(
    @proton_command.AppCommandExtensionSpec::new(
      "moonbit_labeler/labeler",
      "labeler",
      [
        @proton_command.AppCommandApiDescriptor::new("list_images"),
        @proton_command.AppCommandApiDescriptor::new("read_image"),
        @proton_command.AppCommandApiDescriptor::new("read_thumb"),
        @proton_command.AppCommandApiDescriptor::new("decode_image"),
        @proton_command.AppCommandApiDescriptor::new("resize_image"),
        @proton_command.AppCommandApiDescriptor::new("read_text"),
        @proton_command.AppCommandApiDescriptor::new("write_text"),
        @proton_command.AppCommandApiDescriptor::new("read_label"),
        @proton_command.AppCommandApiDescriptor::new("write_label"),
        @proton_command.AppCommandApiDescriptor::new("scan_classes"),
        @proton_command.AppCommandApiDescriptor::new("save_classes"),
        @proton_command.AppCommandApiDescriptor::new("load_classes"),
        @proton_command.AppCommandApiDescriptor::new("load_classes_from_file"),
        @proton_command.AppCommandApiDescriptor::new("list_videos"),
        @proton_command.AppCommandApiDescriptor::new("read_video_info"),
        @proton_command.AppCommandApiDescriptor::new("read_video_frame"),
        @proton_command.AppCommandApiDescriptor::new("export_voc_folder"),
        @proton_command.AppCommandApiDescriptor::new("export_yolo_folder"),
        @proton_command.AppCommandApiDescriptor::new("parse_label"),
        @proton_command.AppCommandApiDescriptor::new("serialize_label"),
      ],
      register_labeler_commands,
    ),
  )
}

///|
fn register_labeler_commands(
  context : @proton_command.AppCommandExtensionContext,
) -> Result[Unit, String] {
  context.op_async("list_images", op_list_images, emits_events=false)
  context.op_async("read_image", op_read_image, emits_events=false)
  context.op_async("read_thumb", op_read_thumb, emits_events=false)
  context.op_async("decode_image", op_decode_image, emits_events=false)
  context.op_async("resize_image", op_resize_image, emits_events=false)
  context.op_async("read_text", op_read_text, emits_events=false)
  context.op_async("write_text", op_write_text, emits_events=false)
  context.op_async("read_label", op_read_label, emits_events=false)
  context.op_async("write_label", op_write_label, emits_events=false)
  context.op_async("scan_classes", op_scan_classes, emits_events=false)
  context.op_async("save_classes", op_save_classes, emits_events=false)
  context.op_async("load_classes", op_load_classes, emits_events=false)
  context.op_async(
    "load_classes_from_file",
    op_load_classes_from_file,
    emits_events=false,
  )
  context.op_async("list_videos", op_list_videos, emits_events=false)
  context.op_async("read_video_info", op_read_video_info, emits_events=false)
  context.op_async("read_video_frame", op_read_video_frame, emits_events=false)
  context.op_async(
    "export_voc_folder",
    op_export_voc_folder,
    emits_events=false,
  )
  context.op_async(
    "export_yolo_folder",
    op_export_yolo_folder,
    emits_events=false,
  )
  context.op_async("parse_label", op_parse_label, emits_events=false)
  context.op_async("serialize_label", op_serialize_label, emits_events=false)
  Ok(())
}
