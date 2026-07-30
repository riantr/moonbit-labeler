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

///| Request to list images in a directory. Empty `extensions` = default set.
pub struct ListImagesRequest {
  path : String
  extensions : Array[String]?
} derive(FromJson, ToJson, Eq, Debug)

///| One image entry returned by `list_images`.
pub struct ImageEntry {
  name : String
  path : String
  ext : String
} derive(ToJson, Eq, Debug)

pub struct ListImagesReply {
  folder : String
  images : Array[ImageEntry]
} derive(ToJson, Eq, Debug)

///| Request to read an image as base64 (used as a `data:` URL fallback
/// when the webview cannot load `file://` URLs).
pub struct ReadImageRequest {
  path : String
} derive(FromJson, ToJson, Eq, Debug)

pub struct ReadImageReply {
  path : String
  /// base64-encoded file bytes (no `data:` prefix)
  base64 : String
  mime : String
} derive(ToJson, Eq, Debug)

///| Request to read a text file (JSON label files).
pub struct ReadTextRequest {
  path : String
} derive(FromJson, ToJson, Eq, Debug)

pub struct ReadTextReply {
  path : String
  content : String
  found : Bool
} derive(ToJson, Eq, Debug)

///| Request to write a text file (JSON label files).
pub struct WriteTextRequest {
  path : String
  content : String
} derive(FromJson, ToJson, Eq, Debug)

pub struct WriteTextReply {
  path : String
  bytes : Int
} derive(ToJson, Eq, Debug)

///| Request to read the label JSON for an image. The label path is
/// derived automatically:
///   `Image@X/<basename>.jpg` -> `Label@X/<basename>.json`
/// If the folder layout does not match the `Image@<name>` / `Label@<name>`
/// convention, the sibling-label fallback is used.
pub struct ReadLabelRequest {
  image_path : String
} derive(FromJson, ToJson, Eq, Debug)

pub struct ReadLabelReply {
  image_path : String
  label_path : String
  content : String
  found : Bool
} derive(ToJson, Eq, Debug)

///| Request to write the label JSON for an image. The label path is
/// resolved the same way as in `read_label`.
pub struct WriteLabelRequest {
  image_path : String
  content : String
} derive(FromJson, ToJson, Eq, Debug)

pub struct WriteLabelReply {
  image_path : String
  label_path : String
  bytes : Int
} derive(ToJson, Eq, Debug)

///| Default image extensions when the frontend doesn't pass a list.
let default_image_extensions : Array[String] = [
  ".jpg", ".jpeg", ".png", ".bmp", ".webp", ".gif",
]

///| Default video extensions scanned by `list_videos`.
let default_video_extensions : Array[String] = [
  ".mp4", ".mov", ".mkv", ".avi", ".webm", ".m4v",
]

///| Fallback class list used when no label files have been scanned yet.
/// Order matches the most common classes observed in the CARS dataset.
let fallback_classes : Array[String] = [
  "scissors", "knife_straight", "knife_folded", "knife_blade", "knife_other",
  "lithium_cell_charger_square", "lithium_cell_charger_cylinder",
  "liquid_bottle_plastic", "liquid_thermos_cup_metal", "lighter_plastic",
]

///| Request to enumerate all distinct class names used in the label files
/// under the sibling `Label@<name>` directory.
pub struct ScanClassesRequest {
  image_path : String?
} derive(FromJson, ToJson, Eq, Debug)

///| One class with its frequency.
pub struct ClassInfo {
  name : String
  count : Int
} derive(ToJson, Eq, Debug)

///| Reply containing the label directory that was scanned and the
/// distinct classes (sorted by count desc).
pub struct ScanClassesReply {
  label_dir : String
  classes : Array[ClassInfo]
} derive(ToJson, Eq, Debug)

///| Request to enumerate video files. `Video@<name>/*.mp4` is the
/// conventional folder layout. Sibling-folder fallback applies.
pub struct ListVideosRequest {
  path : String
  extensions : Array[String]?
} derive(FromJson, ToJson, Eq, Debug)

///| One video entry returned by `list_videos`. The frontend decides
/// when (and whether) to call `read_video_info` to populate metadata.
pub struct VideoEntry {
  name : String
  path : String
  ext : String
  size_bytes : Int
} derive(ToJson, Eq, Debug)

pub struct ListVideosReply {
  folder : String
  videos : Array[VideoEntry]
} derive(ToJson, Eq, Debug)

///| Request metadata for a single video. Implemented via `ffprobe -v error
/// -print_format json -show_streams -show_format <path>` and a small
/// string parser. The reply fields are best-effort: missing / unparseable
/// values surface as `0` / `""`.
pub struct ReadVideoInfoRequest {
  path : String
} derive(FromJson, ToJson, Eq, Debug)

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

///| Request a single frame as a base64-encoded JPEG. Internally invokes
/// `ffmpeg -ss <sec> -i <path> -frames:v 1 -q:v 3 -y <tmp>`. The reply
/// is intentionally narrow: the same shape as `read_image` so the
/// frontend can re-use the data: URL fallback path.
pub struct ReadVideoFrameRequest {
  path : String
  frame : Int
  /// Optional override JPEG quality (1-31, lower is better). Defaults to 3.
  quality : Int?
} derive(FromJson, ToJson, Eq, Debug)

pub struct ReadVideoFrameReply {
  path : String
  frame : Int
  base64 : String
  mime : String
  width : Int
  height : Int
  ok : Bool
} derive(ToJson, Eq, Debug)

///| Make sure the directory exists; falls back to PowerShell if the
/// MoonBit async fs `mkdir` doesn't materialise the path. We hit this
/// edge case on Windows when the parent path lives in a folder the
/// async backend hasn't seen before.
async fn ensure_dir(path : String) -> Unit {
  if path == "" { return }
  if @fs.exists(path) && @fs.kind(path) == @fs.Directory { return }
  // PowerShell is the most reliable on Windows for paths that contain
  // characters like `@`. `New-Item -Force` is equivalent to `mkdir -p`.
  let (code, ps_out) = @process.collect_stdout(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command",
     "New-Item -ItemType Directory -Path '" + ps_escape(path) + "' -Force | Out-Null"],
  ) catch { _ => (0, "") }
  let _ = ps_out
  let _ = code
}

///| --- string helpers ---

///| Lowercase an ASCII character. Non-ASCII chars pass through.
fn to_lower_char(c : Char) -> Char {
  let code = c.to_int()
  if code >= 65 && code <= 90 {
    Int::unsafe_to_char(code + 32)
  } else {
    c
  }
}

fn lower(s : String) -> String {
  let buf = StringBuilder::new(size_hint=s.length())
  for c in s {
    buf.write_char(to_lower_char(c))
  }
  buf.to_string()
}

fn is_image_ext(name : String, exts : Array[String]) -> Bool {
  let lname = lower(name)
  for ext in exts {
    if lname.has_suffix(ext) {
      return true
    }
  }
  false
}

fn is_video_ext(name : String, exts : Array[String]) -> Bool {
  let lname = lower(name)
  for ext in exts {
    if lname.has_suffix(ext) {
      return true
    }
  }
  false
}

///| Returns the file extension including the leading `.`, or `""`.
fn ext_of(name : String) -> String {
  let bytes = name.to_bytes()
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

fn join_path(folder : String, name : String) -> String {
  if folder.has_suffix("/") || folder.has_suffix("\\") {
    folder + name
  } else {
    folder + "\\" + name
  }
}

///| --- base64 encoding (RFC 4648, with padding) ---

fn base64_encode(data : Bytes) -> String {
  let alphabet : FixedArray[Char] = [
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H',
    'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
    'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X',
    'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f',
    'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n',
    'o', 'p', 'q', 'r', 's', 't', 'u', 'v',
    'w', 'x', 'y', 'z', '0', '1', '2', '3',
    '4', '5', '6', '7', '8', '9', '+', '/',
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

///| --- native folder picker (Windows) ---
///
/// Shows a native Windows folder selection dialog by shelling out to
/// PowerShell's `FolderBrowserDialog`. The selected path is written to a
/// temp file (UTF-8) by the script and read back here — that sidesteps
/// both PowerShell's stdout encoding (UTF-16 LE on PS 5.1) and the need
/// to base64-encode the path.

///| Request to show a native folder picker dialog.
pub struct PickFolderRequest {
  title : String
  initial : String?
} derive(FromJson, ToJson, Eq, Debug)

///| Reply with the picked folder path (empty if the user cancelled).
pub struct PickFolderReply {
  path : String
  cancelled : Bool
} derive(ToJson, Eq, Debug)

///| Escape a string for use inside a PowerShell single-quoted literal
/// (`'` becomes `''`).
fn ps_escape(s : String) -> String {
  let buf = StringBuilder::new(size_hint=s.length() + 4)
  for c in s {
    if c == '\'' {
      buf.write_string("''")
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///| Encode a string as a PowerShell single-quoted literal. Used for
/// passing UTF-8 JSON content through PowerShell to WriteAllText.
fn ps_powershell_string_literal(s : String) -> String {
  let buf = StringBuilder::new(size_hint=s.length() + 4)
  buf.write_char('\'')
  for c in s {
    if c == '\'' {
      buf.write_string("''")
    } else {
      buf.write_char(c)
    }
  }
  buf.write_char('\'')
  buf.to_string()
}

///| --- ops ---

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

async fn op_read_image(req : ReadImageRequest) -> ReadImageReply raise {
  let data = @fs.read_file(req.path) catch {
    err => fail("read_image failed: " + err.to_string())
  }
  let bytes = data.binary()
  { path: req.path, base64: base64_encode(bytes), mime: mime_for(req.path) }
}

async fn op_read_text(req : ReadTextRequest) -> ReadTextReply {
  if !@fs.exists(req.path) {
    return { path: req.path, content: "", found: false }
  }
  let data = @fs.read_file(req.path) catch {
    _ => return { path: req.path, content: "", found: false }
  }
  let text = data.text() catch {
    err => return { path: req.path, content: "decode error: " + err.to_string(), found: true }
  }
  { path: req.path, content: text, found: true }
}

async fn op_write_text(req : WriteTextRequest) -> WriteTextReply raise {
  // PowerShell-based file write. See op_write_label for the rationale.
  let (code, ps_out) = @process.collect_stdout(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command",
     "[System.IO.File]::WriteAllText('" + ps_escape(req.path) +
       "', " + ps_powershell_string_literal(req.content) + ", (New-Object System.Text.UTF8Encoding $false))"],
  ) catch {
    err => fail("write_text spawn failed: " + err.to_string())
  }
  if code != 0 {
    let ps_text = ps_out.text() catch { _ => "<decode err>" }
    fail("write_text exited with code \{code}: " + ps_text)
  }
  { path: req.path, bytes: req.content.length() }
}

///| Returns the last index of `c` in `s`, or `-1` if not found.
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

///| Splits on either `/` or `\`, returning the slice up to (exclusive)
/// of the last separator and the slice after it. The separator used is
/// the one that appears later in the string.
fn split_dir_name(path : String) -> (String, String) {
  let last_slash = last_index_of(path, '/')
  let last_back = last_index_of(path, '\\')
  let last_sep = if last_slash >= last_back { last_slash } else { last_back }
  if last_sep < 0 {
    ("", path)
  } else {
    (
      path[:last_sep].to_owned(),
      path[last_sep + 1:].to_owned(),
    )
  }
}

///| Splits the basename into (stem, ext). If no `.`, ext is "".
fn split_stem_ext(basename : String) -> (String, String) {
  let dot = last_index_of(basename, '.')
  if dot <= 0 {
    (basename, "")
  } else {
    (basename[:dot].to_owned(), basename[dot:].to_owned())
  }
}

///| Resolve the label directory for the `scan_classes` op.
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

///| Map `Image@X/<basename>.ext` -> `Label@X/<basename>.json`.
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

///| Same as `image_path_to_label_path` but for `Video@X/<basename>.ext`
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
    _ => return { image_path: req.image_path, label_path, content: "", found: false }
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

async fn op_write_label(req : WriteLabelRequest) -> WriteLabelReply raise {
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
    ensure_dir(label_dir) catch { _ => () }
  }
  // Use PowerShell to write the file directly. The MoonBit async fs
  // has trouble with paths that contain `@` (e.g. Label@<dataset>) —
  // it returns "system cannot find the path specified" even when the
  // directory clearly exists. Going through PowerShell bypasses the
  // buggy path-handling code path.
  let (code, ps_out) = @process.collect_stdout(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command",
     "[System.IO.File]::WriteAllText('" + ps_escape(label_path) +
       "', " + ps_powershell_string_literal(req.content) + ", (New-Object System.Text.UTF8Encoding $false))"],
  ) catch {
    err => fail("write_label spawn failed: " + err.to_string())
  }
  if code != 0 {
    let ps_text = ps_out.text() catch { _ => "<decode err>" }
    fail("write_label exited with code \{code}: " + ps_text)
  }
  { image_path: req.image_path, label_path, bytes: req.content.length() }
}

///| Show a native folder picker via PowerShell's `FolderBrowserDialog` and
/// return the selected absolute path. The path is written to a temp file
/// (UTF-8) by the script and read back here, which avoids both PowerShell
/// stdout encoding issues (UTF-16 LE on PS 5.1) and base64 round-tripping.
async fn op_pick_folder(req : PickFolderRequest) -> PickFolderReply raise {
  let debug_log = "C:\\Windows\\Temp\\moonbit-labeler-pick-folder.log"
  @fs.write_file(debug_log, "", create_mode=@fs.CreateOrTruncate) catch { _ => () }
  @fs.write_file(debug_log, "=== pick_folder start ===\n", append=true, create_mode=@fs.OpenOrCreate) catch {
    _ => ()
  }
  let initial_text = match req.initial {
    Some(p) => p
    None => ""
  }
  @fs.write_file(debug_log, "req.title=" + req.title + ", initial=" + initial_text + "\n", append=true, create_mode=@fs.OpenOrCreate) catch {
    _ => ()
  }
  let title = ps_escape(req.title)
  let initial_clause = match req.initial {
    Some(p) if p.length() > 0 =>
      "$f.SelectedPath = '" + ps_escape(p) + "';\n"
    _ => ""
  }
  let temp_path = "C:\\Windows\\Temp\\moonbit-labeler-pick-folder.txt"
  let script =
    "Add-Type -AssemblyName System.Windows.Forms;\n" +
    "$f = New-Object System.Windows.Forms.FolderBrowserDialog;\n" +
    "$f.Description = '" + title + "';\n" +
    "$f.ShowNewFolderButton = $true;\n" +
    initial_clause +
    "if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {\n" +
    "  [System.IO.File]::WriteAllText('" + ps_escape(temp_path) +
      "', $f.SelectedPath, [System.Text.Encoding]::UTF8)\n" +
    "}\n"
  @fs.write_file(debug_log, "script built, length=" + script.length().to_string() + "\n", append=true, create_mode=@fs.OpenOrCreate) catch {
    _ => ()
  }
  if @fs.exists(temp_path) {
    @fs.remove(temp_path) catch {
      _ => ()
    }
  }
  @fs.write_file(debug_log, "spawning powershell.exe\n", append=true, create_mode=@fs.OpenOrCreate) catch {
    _ => ()
  }
  let (exit_code, _stdout) = @process.collect_stdout(
    "powershell.exe",
    [
      "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
      "-Command", script,
    ],
  ) catch {
    err => {
      @fs.write_file(debug_log, "spawn failed: " + err.to_string() + "\n", append=true, create_mode=@fs.OpenOrCreate) catch {
        _ => ()
      }
      fail("pick_folder spawn failed: " + err.to_string())
    }
  }
  @fs.write_file(debug_log, "powershell exit_code=" + exit_code.to_string() + "\n", append=true, create_mode=@fs.OpenOrCreate) catch {
    _ => ()
  }
  if exit_code != 0 {
    fail("pick_folder exited with code \{exit_code}")
  }
  if !@fs.exists(temp_path) {
    @fs.write_file(debug_log, "no result file -> cancelled\n", append=true, create_mode=@fs.OpenOrCreate) catch {
      _ => ()
    }
    return { path: "", cancelled: true }
  }
  let data = @fs.read_file(temp_path) catch {
    err => fail("pick_folder read result failed: " + err.to_string())
  }
  let raw = data.text() catch {
    err => fail("pick_folder decode failed: " + err.to_string())
  }
  @fs.write_file(debug_log, "read result, len=" + raw.length().to_string() + "\n", append=true, create_mode=@fs.OpenOrCreate) catch {
    _ => ()
  }
  @fs.remove(temp_path) catch {
    _ => ()
  }
  let trimmed = trim_string(raw)
  @fs.write_file(debug_log, "returning path=" + trimmed + "\n", append=true, create_mode=@fs.OpenOrCreate) catch {
    _ => ()
  }
  { path: trimmed, cancelled: false }
}

///| Enumerate the distinct `type` strings across every label JSON in the
/// sibling `Label@<name>` directory. Counts are sorted descending. If the
/// label directory does not exist or is empty, returns the
/// `fallback_classes` so the UI still has something to pick from.
async fn op_scan_classes(req : ScanClassesRequest) -> ScanClassesReply raise {
  // image_path can be either a directory (e.g. `D:/x/Image@Foo`) or a file
  // (e.g. `D:/x/Image@Foo/1800003_0.jpg`). Handle both: if it's a directory
  // whose name starts with `Image@`, swap it for the sibling `Label@<rest>`.
  let label_dir = match req.image_path {
    Some(p) if p.length() > 0 =>
      derive_label_dir_for_scan(p)
    _ => ""
  }
  let dbg = "C:\\Windows\\Temp\\moonbit-labeler-scan-classes.log"
  // Initialize log file. TruncateExisting is the default but we want to make
  // sure the file exists for subsequent appends.
  @fs.write_file(dbg, "", create_mode=@fs.CreateOrTruncate) catch { _ => () }
  async fn log(s : String) {
    @fs.write_file(dbg, s + "\n", append=true, create_mode=@fs.OpenOrCreate) catch { _ => () }
  }
  log("=== scan_classes start ===")
  log("req.image_path=" + (match req.image_path { Some(p) => p; None => "<none>" }))
  log("derived label_dir='" + label_dir + "'")
  if label_dir == "" || !@fs.exists(label_dir) {
    log("label_dir empty or missing -> fallback")
    let classes : Array[ClassInfo] = []
    for c in fallback_classes {
      classes.push({ name: c, count: 0 })
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
  let counts : Map[String, Int] = Map::new(capacity=fallback_classes.length() * 2)
  let mut files_read = 0
  let mut files_decoded = 0
  let mut files_scanned = 0
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
    files_read = files_read + 1
    let text = data.text() catch {
      err => {
        log("decode failed for " + name + ": " + err.to_string())
        continue
      }
    }
    files_decoded = files_decoded + 1
    // Strip BOM if present.
    let cleaned = if text.length() > 0 && text[0] == '\u{FEFF}' {
      text[1:].to_owned()
    } else {
      text
    }
    let class_counts = collect_classes_from_text(cleaned)
    if class_counts.length() > 0 {
      files_scanned = files_scanned + 1
    }
    for k, v in class_counts {
      let prev = counts.get(k).unwrap_or(0)
      counts[k] = prev + v
    }
  }
  log("files_read=" + files_read.to_string() + " decoded=" + files_decoded.to_string() + " with_classes=" + files_scanned.to_string())
  log("distinct classes found: " + counts.length().to_string())
  let entries : Array[ClassInfo] = []
  for k, v in counts {
    entries.push({ name: k, count: v })
  }
  entries.sort_by(fn(a, b) { b.count - a.count })
  // Append any fallback classes that weren't seen, so the UI always has
  // the seed list available (with count 0).
  for fallback in fallback_classes {
    if !counts.contains(fallback) {
      entries.push({ name: fallback, count: 0 })
    }
  }
  log("returning " + entries.length().to_string() + " entries")
  { label_dir, classes: entries }
}

///| Returns a count map of class-name -> frequency inside the given
/// (already BOM-stripped) label JSON text.
fn collect_classes_from_text(text : String) -> Map[String, Int] {
  let counts : Map[String, Int] = Map::new(capacity=16)
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

///| Resolve a unique temp JPEG path under `%TEMP%/moonbit-labeler-frames/`.
async fn video_frame_tmp_path() -> String {
  let dir = "C:\\Windows\\Temp\\moonbit-labeler-frames"
  // Best-effort: create the directory if it doesn't exist. Errors are
  // ignored — `ffmpeg -y` will fail loudly if the path is unusable, and
  // we surface that in `ok: false`.
  if !(@fs.exists(dir) catch { _ => false }) {
    @fs.mkdir(dir, recursive=true) catch { _ => () }
  }
  let stamp = now_millis_unix().to_string()
  dir + "\\frame-" + stamp + ".jpg"
}

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
    videos.push({ name, path: full, ext: ext_of(name), size_bytes: bytes.length() })
  }
  { folder: req.path, videos }
}

///| Run ffprobe on a single video and parse a subset of the JSON output.
/// We only need: container duration, first video stream width/height/codec,
/// and a sensible fps. Any parsing error is reported as `ok: false` with
/// empty/zero fields, which the UI can detect and fall back to defaults.
async fn op_read_video_info(req : ReadVideoInfoRequest) -> ReadVideoInfoReply {
  let dbg = "C:\\Windows\\Temp\\moonbit-labeler-video-info.log"
  @fs.write_file(dbg, "", create_mode=@fs.CreateOrTruncate) catch { _ => () }
  async fn log(s : String) {
    @fs.write_file(dbg, s + "\n", append=true, create_mode=@fs.OpenOrCreate) catch { _ => () }
  }
  log("=== read_video_info start ===")
  log("path=" + req.path)
  let (exit_code, stdout_data) = @process.collect_stdout(
    "ffprobe.exe",
    [
      "-v", "error",
      "-print_format", "json",
      "-show_streams",
      "-show_format",
      req.path,
    ],
  ) catch {
    err => {
      log("ffprobe spawn failed: " + err.to_string())
      return { path: req.path, duration_ms: 0, fps: 0.0, frame_count: 0,
               width: 0, height: 0, codec: "", ok: false }
    }
  }
  let stdout = stdout_data.text() catch {
    err => {
      log("ffprobe stdout decode failed: " + err.to_string())
      return { path: req.path, duration_ms: 0, fps: 0.0, frame_count: 0,
               width: 0, height: 0, codec: "", ok: false }
    }
  }
  log("ffprobe exit_code=" + exit_code.to_string() + " stdout_len=" + stdout.length().to_string())
  if exit_code != 0 {
    return { path: req.path, duration_ms: 0, fps: 0.0, frame_count: 0,
             width: 0, height: 0, codec: "", ok: false }
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
    if n < 1 { 1 } else { n }
  } else {
    0
  }
  log("parsed: w=" + vw.to_string() + " h=" + vh.to_string() +
      " fps=" + vfps.to_string() + " codec=" + vcodec +
      " duration_ms=" + duration_ms.to_string() +
      " frame_count=" + frame_count.to_string())
  { path: req.path, duration_ms, fps: vfps, frame_count,
    width: vw, height: vh, codec: vcodec, ok: true }
}

///| Extract `(width, height, fps, codec)` from ffprobe JSON stdout. We do
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

///| Read a JSON string value after a key (e.g. the "video" that comes
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
  while i < n && json[i] != '"' { i = i + 1 }
  if i >= n { return (false, "") }
  i = i + 1
  // Skip whitespace and colon.
  while i < n && (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r') { i = i + 1 }
  if i >= n || json[i] != ':' { return (false, "") }
  i = i + 1
  while i < n && (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r') { i = i + 1 }
  if i >= n || json[i] != '"' { return (false, "") }
  let start = i + 1
  let mut j = start
  while j < n && json[j] != '"' { j = j + 1 }
  if j > n { return (false, "") }
  (true, json[start:j].to_owned())
}

///| Read `"duration": "<seconds>"` from the format section. Returns 0.0
/// if missing or unparseable.
fn parse_format_duration_seconds(json : String) -> Double {
  match find_quoted_string_value(json, "duration") {
    Some(s) => parse_double_text(s)
    None => 0.0
  }
}

///| Find `"needle"` (the quoted JSON key itself) starting from `from`,
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

///| After `from`, find the next JSON string literal and return
/// `(start, end)` indices excluding the surrounding quotes.
fn find_quoted_string(s : String, from : Int) -> (Int, Int)? {
  let n = s.length()
  let mut i = from
  while i < n && s[i] != '"' {
    i = i + 1
  }
  if i >= n {
    return None
  }
  let start = i + 1
  let mut j = start
  // JSON string: no escaped quotes inside for our use (codec_type, codec_name
  // are simple ASCII). ffprobe does not emit escaped quotes in these fields.
  while j < n && s[j] != '"' {
    j = j + 1
  }
  if j > n {
    None
  } else {
    Some((start, j))
  }
}

///| Find `"key": "<value>"` and return `value` (without quotes).
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
        while j < n && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') {
          j = j + 1
        }
        if j < n && s[j] == ':' {
          j = j + 1
          while j < n && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') {
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

///| Find `"key": <number>` and parse it as Int.
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
        while j < n && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') {
          j = j + 1
        }
        if j < n && s[j] == ':' {
          j = j + 1
          while j < n && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') {
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

///| Find `"key": "<num>/<den>"` and parse as double. Returns 0.0 on failure.
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

///| Parse a positive int from a UTF-8 byte view.
fn parse_int_bytes(bytes : Bytes) -> Int {
  let mut result = 0
  for i in 0..<bytes.length() {
    let c = bytes[i]
    if c < b'0' || c > b'9' {
      break
    }
    result = result * 10 + (c - b'0').to_int()
  }
  result
}

///| Parse a simple positive decimal directly from MoonBit characters.
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
      if seen { break } else { continue }
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
  if !seen { 0.0 } else { whole + frac / divisor }
}

///| Parse a positive double (integer or simple decimal) from a UTF-8
/// byte view. Sufficient for durations like "12.345" — we don't need
/// scientific notation for ffprobe output.
fn parse_double_bytes(bytes : Bytes) -> Double {
  let n = bytes.length()
  let mut int_part = 0.0
  let mut frac = 0.0
  let mut frac_div = 1.0
  let mut in_frac = false
  let mut seen_digit = false
  for i in 0..<n {
    let c = bytes[i]
    if c == b'.' {
      in_frac = true
      continue
    }
    if c < b'0' || c > b'9' {
      // Stop at the first non-digit after a number. ffprobe emits
      // "12.345000" for the duration — trailing zeros are fine.
      if seen_digit {
        break
      } else {
        continue
      }
    }
    seen_digit = true
    let d = (c - b'0').to_double()
    if in_frac {
      frac = frac * 10.0 + d
      frac_div = frac_div * 10.0
    } else {
      int_part = int_part * 10.0 + d
    }
  }
  if !seen_digit {
    return 0.0
  }
  if in_frac {
    int_part + frac / frac_div
  } else {
    int_part
  }
}

///| Cheap approximation of the current Unix time in milliseconds. We
/// don't need accuracy — the value only feeds the temp-file name.
async fn now_millis_unix() -> Int {
  let (code, out_data) = @process.collect_stdout(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command",
     "[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()"],
  ) catch {
    _ => return 0
  }
  if code != 0 {
    return 0
  }
  let out = out_data.text() catch { _ => return 0 }
  parse_int_bytes(trim_string(out).to_bytes())
}

///| Extract a single frame as a base64-encoded JPEG via ffmpeg.
async fn op_read_video_frame(req : ReadVideoFrameRequest) -> ReadVideoFrameReply raise {
  if req.frame < 0 {
    return { path: req.path, frame: req.frame, base64: "", mime: "image/jpeg",
             width: 0, height: 0, ok: false }
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
  let (code, _out) = @process.collect_stdout(
    "ffmpeg.exe",
    [
      "-loglevel", "error",
      "-ss", format_double(sec),
      "-i", req.path,
      "-frames:v", "1",
      "-q:v", q.to_string(),
      "-y", tmp,
    ],
  ) catch {
    err => fail("ffmpeg spawn failed: " + err.to_string())
  }
  if code != 0 {
    // Best-effort cleanup.
    @fs.remove(tmp) catch { _ => () }
    return { path: req.path, frame: req.frame, base64: "", mime: "image/jpeg",
             width: 0, height: 0, ok: false }
  }
  let data = @fs.read_file(tmp) catch {
    err => {
      @fs.remove(tmp) catch { _ => () }
      fail("read_video_frame read failed: " + err.to_string())
    }
  }
  let bytes = data.binary()
  let base64 = base64_encode(bytes)
  @fs.remove(tmp) catch { _ => () }
  { path: req.path, frame: req.frame, base64, mime: "image/jpeg",
    width: info.width, height: info.height, ok: true }
}

///| Format a double as a short decimal string for ffmpeg `-ss`. We only
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

///| Trim leading + trailing ASCII whitespace (incl. \r, \n, \t).
fn trim_string(s : String) -> String {
  let n = s.length()
  let mut start = 0
  while start < n {
    let c = s[start]
    if c != ' ' && c != '\t' && c != '\n' && c != '\r' {
      break
    }
    start = start + 1
  }
  let mut end = n
  while end > start {
    let c = s[end - 1]
    if c != ' ' && c != '\t' && c != '\n' && c != '\r' {
      break
    }
    end = end - 1
  }
  if start == 0 && end == n {
    s
  } else {
    String::from_array(s.to_array()[start:end])
  }
}

///| --- extension registration ---

pub fn extension() -> @proton_extension.Extension {
  @proton_extension.from_command_spec(
    @proton_command.AppCommandExtensionSpec::new(
      "moonbit_labeler/labeler",
      "labeler",
      [
        @proton_command.AppCommandApiDescriptor::new("list_images"),
        @proton_command.AppCommandApiDescriptor::new("read_image"),
        @proton_command.AppCommandApiDescriptor::new("read_text"),
        @proton_command.AppCommandApiDescriptor::new("write_text"),
        @proton_command.AppCommandApiDescriptor::new("read_label"),
        @proton_command.AppCommandApiDescriptor::new("write_label"),
        @proton_command.AppCommandApiDescriptor::new("pick_folder"),
        @proton_command.AppCommandApiDescriptor::new("scan_classes"),
        @proton_command.AppCommandApiDescriptor::new("list_videos"),
        @proton_command.AppCommandApiDescriptor::new("read_video_info"),
        @proton_command.AppCommandApiDescriptor::new("read_video_frame"),
      ],
      register_labeler_commands,
    ),
  )
}

fn register_labeler_commands(
  context : @proton_command.AppCommandExtensionContext,
) -> Result[Unit, String] {
  context.op_async("list_images", op_list_images, emits_events=false)
  context.op_async("read_image", op_read_image, emits_events=false)
  context.op_async("read_text", op_read_text, emits_events=false)
  context.op_async("write_text", op_write_text, emits_events=false)
  context.op_async("read_label", op_read_label, emits_events=false)
  context.op_async("write_label", op_write_label, emits_events=false)
  context.op_async("pick_folder", op_pick_folder, emits_events=false)
  context.op_async("scan_classes", op_scan_classes, emits_events=false)
  context.op_async("list_videos", op_list_videos, emits_events=false)
  context.op_async("read_video_info", op_read_video_info, emits_events=false)
  context.op_async("read_video_frame", op_read_video_frame, emits_events=false)
  Ok(())
}
