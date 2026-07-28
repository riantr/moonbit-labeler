///| ---------------------------------------------------------------
/// MoonBit Labeler — backend extension
///
/// Exposes filesystem operations the frontend needs to:
///   - list image files in a folder
///   - read image bytes (as base64) for display
///   - read / write JSON annotation files (Step 6)
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

///| Request to read a text file (JSON label files in Step 6).
pub struct ReadTextRequest {
  path : String
} derive(FromJson, ToJson, Eq, Debug)

pub struct ReadTextReply {
  path : String
  content : String
  found : Bool
} derive(ToJson, Eq, Debug)

///| Request to write a text file (JSON label files in Step 6).
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
  @fs.write_file(req.path, req.content) catch {
    err => fail("write_text failed: " + err.to_string())
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
      let rest = leaf[6:].to_string()
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
/// Mirrors the frontend's `detectLabelFolder` heuristic.
fn image_path_to_label_path(image_path : String) -> String {
  let (dir, basename) = split_dir_name(image_path)
  let (stem, _ext) = split_stem_ext(basename)

  // Strip an "_<n>" suffix used in CARS dataset (`1800003_0` -> `1800003`).
  let underscore = last_index_of(stem, '_')
  let stem_no_idx = if underscore > 0 {
    stem[:underscore].to_owned()
  } else {
    stem
  }

  let (dir_parent, dir_leaf) = split_dir_name(dir)
  let sep = if dir.contains("\\") { "\\" } else { "/" }
  let new_leaf = if dir_leaf.has_prefix("Image@") {
    "Label@" + dir_leaf[6:].to_owned()
  } else {
    ""
  }
  let label_basename = stem_no_idx + ".json"
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

async fn op_read_label(req : ReadLabelRequest) -> ReadLabelReply {
  let label_path = image_path_to_label_path(req.image_path)
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
  let label_path = image_path_to_label_path(req.image_path)
  let (label_dir, _) = split_dir_name(label_path)
  if label_dir != "" && !@fs.exists(label_dir) {
    @fs.mkdir(label_dir, recursive=true) catch {
      _ => ()
    }
  }
  @fs.write_file(label_path, req.content) catch {
    err => fail("write_label failed: " + err.to_string())
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
  let counts : Map[String, Int] = Map::new()
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
      text[1:].to_string()
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
  log("distinct classes found: " + counts.size().to_string())
  let entries : Array[ClassInfo] = []
  for k, v in counts {
    entries.push({ name: k, count: v })
  }
  entries.sort_by(fn(a, b) { b.count - a.count })
  // Append any fallback classes that weren't seen, so the UI always has
  // the seed list available (with count 0).
  for fallback in fallback_classes {
    if not(counts.contains(fallback)) {
      entries.push({ name: fallback, count: 0 })
    }
  }
  log("returning " + entries.length().to_string() + " entries")
  { label_dir, classes: entries }
}

///| Returns a count map of class-name -> frequency inside the given
/// (already BOM-stripped) label JSON text.
fn collect_classes_from_text(text : String) -> Map[String, Int] {
  let counts : Map[String, Int] = Map::new()
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
          let name = text[start:j].to_string()
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
  Ok(())
}
