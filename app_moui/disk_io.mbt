// app_moui/disk_io.mbt — real filesystem I/O (Phase 5.22).
//
// ── Why this file exists ────────────────────────────────────────────
//
// Phase 5.13 concluded that file I/O was structurally impossible in
// this app, and every later phase cited that conclusion as the
// reason `ReadLabelFor` / `LoadFolder` / `ScanClasses` were inert.
// **That conclusion was wrong, twice over, and both halves were
// checkable long before 5.22:**
//
//   1. "`Effect::Task` is never executed." I had grepped MoUI for
//      `Effect::Task` and found the constructor plus a counter in
//      `runtime/program_plan_summary.mbt:273`, then generalised
//      "counted but never run". The execution lives in a *different*
//      file: `runtime/runtime.mbt:46-49` calls `start_task(...)`,
//      which lands in `runtime/program_runtime_effect_tasks.mbt:22`
//      and calls `start(...)`. The summary counter is a parallel
//      diagnostic pass, not the execution path. One grep hit was
//      read as a category verdict.
//
//   2. "There is no sync->async bridge, so a sync `update` cannot
//      read a file." True of `moonbitlang/async` — but irrelevant,
//      because `moonbitlang/x/fs` is a **synchronous** fs API and
//      was never importable only because I never added it. It also
//      needed an explicit `@xfs` alias: `moonbitlang/async/fs` and
//      `moonbitlang/x/fs` both want the bare name `fs`, and MoonBit
//      rejects the collision outright ("Conflicting import alias").
//
// Two further environment facts that cost real time and are worth
// writing down, because both are load-bearing and neither is
// guessable:
//
//   - `app_moui` is its **own module** (`riantr/moonbit_labeler/
//     app_moui`, own `moon.mod`), not a package of the repo root
//     module. Adding a dependency to the root `moon.mod` changes
//     nothing here; the error text even says "its containing module
//     is not imported by riantr/moonbit_labeler/app_moui".
//
//   - The `moonbitlang/x` version must match **MoUI's own pin**
//     (`0.5.1`). Forcing a newer `x@0.5.5` does not fail in our
//     code — it breaks MoUI's own
//     `backend/common/services/native/filesystem_services.mbt:53`,
//     where `@fs.read_dir` is annotated `Array[String]` but 0.5.5
//     returns `ArrayView[String]`. A version bump looks like our
//     bug and is not.
//
// Upstream already depends on this package for exactly this purpose
// on exactly this platform: MoUI's own
// `backend/common/services/native/moon.pkg` imports
// `moonbitlang/x/fs` with `supported_targets = "native"`. Sync disk
// I/O on Windows is supported upstream, not a workaround.
//
// ── What is real here vs. still stubbed ────────────────────────────
//
// Real: folder listing + media classification, label read, label
// write, and the Image@/Label@ sibling-folder convention.
// Still not implemented: image pixel decode from disk (the canvas
// still shows the synthetic fixture — see `image_header.mbt`), and
// VOC/YOLO export. `ImageEntry.size_bytes` is always 0 because
// `x/fs` exposes no stat/size call.

///|
/// Classify a filename by extension. The image set is the set
/// `riantr/moonbit_image` decodes plus the two extra formats
/// `image_header.mbt` can probe headers for; the video set is what
/// `docs/VIDEO_LABELING.md` describes.
///
/// `None` means "not media". It is deliberately **not** a third
/// `MediaKind` variant: `MediaKind` already exists in `app.mbt` and is
/// matched exhaustively elsewhere, so widening it to carry a
/// non-media case would force every one of those matches to grow a
/// dead arm. "There is no media kind" and "the kind is `Other`" are
/// different claims, and only the first one is true.
pub fn media_kind(name : String) -> MediaKind? {
  match extension_of(name) {
    "png" | "jpg" | "jpeg" | "bmp" | "gif" | "tga" | "qoi" | "webp" =>
      Some(Image)
    "mp4" | "avi" | "mov" | "mkv" => Some(Video)
    _ => None
  }
}

///|
/// ASCII-only lowercase. Deliberately hand-rolled rather than using a
/// stdlib helper: `x/fs`'s own package does not re-export one, and
/// guessing at the stdlib name is a compile error for no benefit.
/// Extensions are ASCII by definition, so ASCII is sufficient — a
/// non-ASCII byte passes through unchanged rather than being mangled.
fn to_lower_ascii(s : String) -> String {
  let chars : Array[Char] = s.to_array()
  let out : Array[Char] = []
  for ch in chars {
    if ch >= 'A' && ch <= 'Z' {
      // `Int::to_char` is total-looking but returns `Char?`; the None
      // case is unreachable for an ASCII code point, so falling back
      // to the original char keeps the mapping total either way.
      match Int::to_char(ch.to_int() + 32) {
        Some(lower) => out.push(lower)
        None => out.push(ch)
      }
    } else {
      out.push(ch)
    }
  }
  String::from_array(out)
}

///|
/// The lowercase extension of `name` **without** the leading dot.
/// Returns `""` when the name has no dot, or when the dot is the
/// first character (a dotfile like `.gitkeep` has no extension, not
/// an extension named `gitkeep`). Only the *last* dot counts, so
/// `archive.tar.gz` yields `gz`.
pub fn extension_of(name : String) -> String {
  let chars : Array[Char] = name.to_array()
  let mut last_dot : Int = -1
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i] == '.' {
      last_dot = i
    }
  }
  // No dot at all, or a leading dot only (hidden file).
  if last_dot <= 0 || last_dot == chars.length() - 1 {
    return ""
  }
  let out : Array[Char] = []
  for i = last_dot + 1; i < chars.length(); i = i + 1 {
    out.push(chars[i])
  }
  to_lower_ascii(String::from_array(out))
}

///|
/// Join a directory and a filename with exactly one separator.
/// Idempotent on a trailing separator: `join_path("a/", "b")` and
/// `join_path("a", "b")` both yield `a/b`. An empty `dir` yields
/// `name` unchanged, which is what lets the caller pass "" to mean
/// "same directory as the image".
pub fn join_path(dir : String, name : String) -> String {
  if dir.length() == 0 {
    return name
  }
  let chars : Array[Char] = dir.to_array()
  let last : Char = chars[chars.length() - 1]
  if last == '/' || last == '\\' {
    dir + name
  } else {
    dir + "/" + name
  }
}

///|
/// Strip the final extension: `a/b/c.jpg` -> `c`, `c.jpg` -> `c`.
/// A name with no extension is returned unchanged.
pub fn strip_extension(name : String) -> String {
  let chars : Array[Char] = name.to_array()
  let mut last_dot : Int = -1
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i] == '.' {
      last_dot = i
    }
  }
  // Keep a leading dot: `.gitkeep` must survive intact.
  if last_dot <= 0 {
    return name
  }
  let out : Array[Char] = []
  for i = 0; i < last_dot; i = i + 1 {
    out.push(chars[i])
  }
  String::from_array(out)
}

///|
/// Where the label JSON for `image_path` lives.
///
/// The convention is **strip the image's extension, append `.json`**,
/// taken from the real dataset rather than guessed:
/// `data/Image@skin/BIOMEDICA_P0_JCAS-4-2-g001.jpg` pairs with
/// `data/Label@skin/BIOMEDICA_P0_JCAS-4-2-g001.json`. Appending to
/// the full basename would produce `...jpg.json`, which matches
/// nothing on disk.
///
/// `label_folder` empty means "beside the image", which is what a
/// flat single-folder project looks like.
pub fn label_path_for(image_path : String, label_folder : String) -> String {
  let base : String = path_basename(image_path)
  let stem : String = strip_extension(base)
  if label_folder.length() == 0 {
    // Sibling of the image: keep the image's own directory.
    let chars : Array[Char] = image_path.to_array()
    let mut last_sep : Int = -1
    for i = 0; i < chars.length(); i = i + 1 {
      if chars[i] == '/' || chars[i] == '\\' {
        last_sep = i
      }
    }
    if last_sep < 0 {
      return stem + ".json"
    }
    let dir : Array[Char] = []
    for i = 0; i <= last_sep; i = i + 1 {
      dir.push(chars[i])
    }
    return String::from_array(dir) + stem + ".json"
  }
  join_path(label_folder, stem + ".json")
}

///|
/// Derive the label folder that sits beside `image_folder` per the
/// documented layout: `Image@<name>` -> `Label@<name>`.
///
/// Returns `""` when the folder is not named `Image@...` — the
/// caller then treats it as "labels live beside the images". We do
/// not guess a sibling name for an arbitrarily-named folder,
/// because writing annotations into an unrelated directory is worse
/// than not writing them at all.
pub fn sibling_label_folder(image_folder : String) -> String {
  let base : String = path_basename(image_folder)
  let base_chars : Array[Char] = base.to_array()
  // "Image@" is 6 chars, and a bare "Image@" has no name to carry
  // over, so `<= 6` is the reject case.
  if base_chars.length() <= 6 {
    return ""
  }
  let prefix_ok : Bool = base_chars[0] == 'I' &&
    base_chars[1] == 'm' &&
    base_chars[2] == 'a' &&
    base_chars[3] == 'g' &&
    base_chars[4] == 'e' &&
    base_chars[5] == '@'
  if !prefix_ok {
    return ""
  }
  let tail : Array[Char] = []
  for i = 6; i < base_chars.length(); i = i + 1 {
    tail.push(base_chars[i])
  }
  let rebuilt : String = String::from_array(tail)
  let chars : Array[Char] = image_folder.to_array()
  let mut last_sep : Int = -1
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i] == '/' || chars[i] == '\\' {
      last_sep = i
    }
  }
  if last_sep < 0 {
    return "Label@" + rebuilt
  }
  let dir : Array[Char] = []
  for i = 0; i <= last_sep; i = i + 1 {
    dir.push(chars[i])
  }
  String::from_array(dir) + "Label@" + rebuilt
}

///|
/// True when `a` sorts before `b` **lexicographically**.
///
/// This exists because MoonBit's `String.<` is **not** lexicographic:
/// it compares by length first and only then by content. Verified, not
/// assumed — `"bb" < "ccc"` is `true`, and sorting
/// `[img100, img10, img2, img1]` by `<` yields
/// `img1, img2, img10, img100`.
///
/// For numbered sequences that length-first order is accidentally
/// what people want (`img1, img2, ..., img10, img100`), which is
/// exactly why it is dangerous: it looks right until the names have
/// uneven lengths. In the shipped dataset it puts
/// `BIOMEDICA_P0_JCAS-4-2-g001.jpg` (30 chars) ahead of
/// `BIOMEDICA_P0_JCAS-2-72-g003.jpg` (31 chars), so a file browser
/// listing starts with a "4-" series and a user reading it thinks the
/// scan is mis-ordered.
///
/// **Neither order is universally right.** Length-first is better for
/// numbered filenames, lexicographic is better for series names, and
/// this dataset is series-named — so `scan_folder` uses this. Byte
/// order, then length. Compared through `Char::to_int` so the ordering
/// does not depend on `Char` being `Ord`.
pub fn name_less(a : String, b : String) -> Bool {
  let ac : Array[Char] = a.to_array()
  let bc : Array[Char] = b.to_array()
  let short : Int = if ac.length() < bc.length() {
    ac.length()
  } else {
    bc.length()
  }
  let mut i = 0
  while i < short {
    if ac[i].to_int() != bc[i].to_int() {
      return ac[i].to_int() < bc[i].to_int()
    }
    i = i + 1
  }
  ac.length() < bc.length()
}

///|
/// The result of listing a folder: the media split by kind, plus the
/// label folder that belongs to it. `label_folder` is `""` when there
/// is none — see `sibling_label_folder`.
pub(all) struct FolderScan {
  images : Array[ImageEntry]
  videos : Array[VideoEntry]
  label_folder : String
} derive(Debug)

///|
/// List `folder` and split its entries into images and videos.
///
/// Returns `None` when the folder cannot be read at all (missing,
/// not a directory, permission denied). A folder that *is* readable
/// but contains no media returns `Some` with two empty arrays — that
/// is a legitimate empty project, not an error, and collapsing the
/// two would make "the folder is empty" indistinguishable from "the
/// folder is broken".
///
/// **Entries are sorted by name.** `read_dir` returns whatever order
/// the filesystem hands back, which differs between NTFS and other
/// volumes and is not stable across runs. The sidebar renders this
/// list directly, so leaving it unsorted would make image 3 of a
/// project shuffle between launches.
///
/// Sorted with `name_less` (explicit lexicographic), **not** `<` —
/// see `name_less` for why MoonBit's built-in comparison cannot be
/// used for a file list.
pub fn scan_folder(folder : String) -> FolderScan? {
  let names = @xfs.read_dir(folder) catch { _ => return None }
  // Copy the ArrayView into a mutable Array. There is no `to_owned`
  // on ArrayView in x/fs@0.5.1, and we need a mutable buffer to sort.
  let sorted : Array[String] = []
  for name in names {
    sorted.push(name)
  }
  sorted.sort_by(fn(a, b) {
    if name_less(a, b) {
      -1
    } else if name_less(b, a) {
      1
    } else {
      0
    }
  })
  let images : Array[ImageEntry] = []
  let videos : Array[VideoEntry] = []
  for name in sorted {
    // `None` covers both unrelated files and subdirectories — a
    // directory entry has no extension. We do not recurse.
    match media_kind(name) {
      Some(Image) =>
        // size_bytes stays 0: x/fs exposes no stat/size call, and
        // inventing a number here would be a lie the UI could show.
        images.push({ name, path: join_path(folder, name), size_bytes: 0, })
      Some(Video) =>
        // frame_count stays 0 for the same reason — it is a decoded
        // property, not something a directory listing can know.
        videos.push({ name, path: join_path(folder, name), frame_count: 0, })
      None => ()
    }
  }
  Some({ images, videos, label_folder: sibling_label_folder(folder), })
}

///|
/// Read a label file's raw JSON text. `None` when the file is
/// missing or unreadable — which is the **normal** case for an
/// un-annotated image, not an error. The caller distinguishes
/// "no label yet" from "label present but corrupt" by re-parsing the
/// text it got back; `load_label` does both in one step.
pub fn read_label_text(path : String) -> String? {
  let text = @xfs.read_file_to_string(path) catch { _ => return None }
  Some(text)
}

///|
/// Write a label file. Returns `false` on failure instead of raising
/// so the caller can put the reason on the status bar.
///
/// The parent directory is **not** created: writing a label into a
/// `Label@...` folder that does not exist is a configuration error
/// worth surfacing, not something to paper over by silently making
/// directories.
pub fn write_label_text(path : String, text : String) -> Bool {
  @xfs.write_string_to_file(path, text) catch {
    _ => return false
  }
  true
}

///|
/// Read + parse a label file in one step.
///
/// Returns `None` when the file is absent or unreadable. A file that
/// exists but does not parse yields `Some` with **empty**
/// annotations/bindings and the raw text preserved — the caller keeps
/// the original bytes so a re-save does not silently destroy a label
/// this build cannot understand. That asymmetry is deliberate:
/// "no file" and "empty file" are both a blank canvas, but they are
/// not the same thing to the user's data.
pub fn load_label(
  path : String,
  classes : Array[ClassEntry],
) -> (Label, Array[Annotation], Array[Binding])? {
  let text = match read_label_text(path) {
    Some(t) => t
    None => return None
  }
  let (annotations, bindings) = parse_label_text(text, classes)
  Some(({ raw_json: text, dirty: false, }, annotations, bindings))
}

///|
/// Phase 5.23 — read an image off disk, decode it, and register it in
/// the renderer cache under its own path. Returns the decoded
/// dimensions, or `None` if any step failed.
///
/// **This blocks.** The decode and the RGB→RGBA widening are
/// synchronous and run on whatever thread called it — in this app, the
/// one running `update`, i.e. the UI thread. For the shipped 517×371
/// sample that is ~190k pixels, single-digit milliseconds. For a 4K
/// scan it is ~8.3M pixels and roughly 33 MB of buffer, and the UI
/// will visibly hitch on the click. The architecture offers no
/// alternative: MoUI's `update` is sync, and the only async escape
/// (`Effect::Task`) is a *subscription* whose completion would still
/// have to be marshalled back onto the UI thread. So the cost is
/// acknowledged rather than solved, and the mitigation is
/// `image_in_renderer`: a cache hit skips the whole thing, so
/// re-selecting the current image is free and paging forward through a
/// folder pays once per image.
///
/// Callers must register **before** pointing `Model::imageSource` at
/// the path. The canvas emits a `DrawImage` for any non-empty
/// `imageSource` and the rasterizer's cache-miss fallback paints a
/// grey X, so setting the source first would flash that placeholder
/// for a frame.
pub fn load_image_into_cache(path : String) -> (Int, Int)? {
  // Fast path: already decoded. Skips the file read *and* the decode.
  if image_in_renderer(path) {
    return image_size_in_renderer(path)
  }
  let bytes = @xfs.read_file_to_bytes(path) catch { _ => return None }
  // `decode_image_bytes` already collapses the codec's raise into
  // `None`, so there is nothing to catch here — just unwrap it.
  let img = match decode_image_bytes(bytes) {
    Some(i) => i
    None => return None
  }
  let rgba : Bytes = to_rgba8_bytes(img)
  let ok : Bool = register_image_in_renderer(path, img.width, img.height, rgba)
  if ok {
    Some((img.width, img.height))
  } else {
    None
  }
}
