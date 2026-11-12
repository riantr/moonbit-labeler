///|
/// Class revision — rename a class across the annotations that use it.
///
/// The sidebar's class list is only a *projection* of the annotation
/// data: `op_scan_classes` counts the `"type"` strings it finds in the
/// label files, so once a class had been annotated with a wrong name
/// there was no way to correct it. This module owns the rewrite that
/// fixes it.
///
/// The rewrite lives in the backend rather than in the frontend
/// because a folder-wide rename touches every label document on disk,
/// and the on-disk schema is the backend's business (see `labeler.mbt`).

///|
/// The outcome of rewriting one label document.
priv struct RewriteResult {
  /// How many annotations changed.
  changed : Int32
  /// The rewritten document, as JSON text.
  text : String
}

///|
/// Rewrite the `type` field of every annotation whose class is `from`,
/// so that it reads `to` instead. Returns how many annotations
/// changed.
///
/// The rewrite reaches the document's own `infos` array *and* every
/// per-frame set under `frame_labels`. A video label document keeps
/// each frame's annotations in a set of its own, so a rewrite that
/// stopped at the top level would rename the default set while every
/// frame of the video stayed on the old class name.
///
/// Binding entries are left alone: a binding's `type` says what kind
/// of relation it is (`same_group`), not which class it belongs to.
///
/// The document is edited in place — a `Json::Object` holds a mutable
/// map — so the caller can serialize the very same value afterwards.
pub fn rename_class_types(doc : Json, from : String, to : String) -> Int32 {
  if from == "" || to == "" || from == to {
    return 0
  }
  let members : Map[String, Json] = match doc {
    Object(m) => m
    _ => return 0
  }
  let top_infos : Array[Json] = match members.get("infos") {
    Some(Array(a)) => a
    _ => []
  }
  let mut changed = rename_types_in_infos(top_infos, from, to)
  let raw_sets : Array[Json] = match members.get("frame_labels") {
    Some(Array(a)) => a
    _ => []
  }
  for entry in raw_sets {
    let obj : Map[String, Json] = match entry {
      Object(o) => o
      _ => continue
    }
    let set_infos : Array[Json] = match obj.get("infos") {
      Some(Array(a)) => a
      _ => []
    }
    changed = changed + rename_types_in_infos(set_infos, from, to)
  }
  changed
}

///|
/// Rewrite the `type` of every entry in one `infos` array. Returns how
/// many entries changed.
fn rename_types_in_infos(
  infos : Array[Json],
  from : String,
  to : String,
) -> Int32 {
  let mut changed = 0
  for entry in infos {
    let obj : Map[String, Json] = match entry {
      Object(o) => o
      _ => continue
    }
    match obj.get("type") {
      Some(String(t)) =>
        if t == from {
          obj.set("type", Json::string(to))
          changed = changed + 1
        }
      _ => ()
    }
  }
  changed
}

///|
/// Request to rename a class across the annotations that use it.
#derive(FromJson, ToJson, Eq, Debug)
pub struct RenameClassRequest {
  /// Absolute path of the image or video the rename starts from.
  image_path : String
  /// The class name to replace.
  from : String
  /// The new class name.
  to : String
  /// `"current"` renames the one label document, `"folder"` renames
  /// every label document of the dataset the image belongs to.
  scope : String
  /// False previews the rename, true writes it.
  apply : Bool
}

///|
/// The result of a class rename.
#derive(ToJson, Eq, Debug)
pub struct RenameClassReply {
  image_path : String
  from : String
  to : String
  scope : String
  /// True when the rename reached the disk. A preview reports false.
  applied : Bool
  /// How many annotations now carry the new class name.
  changed_annotations : Int32
  /// How many label documents the rename touched.
  changed_files : Int32
  /// How many label documents were inspected.
  scanned_files : Int32
  /// The rewritten content of the current document. Empty when the
  /// current document was not touched. The frontend replaces its
  /// in-memory label with this, so a later autosave cannot write the
  /// old class name back over the rename.
  current_content : String
  /// Where the current document lives on disk.
  current_label_path : String
  /// True when the curated class list (`classes.json`) was renamed too.
  curated_updated : Bool
}

///|
/// Rename a class across the annotations that use it.
///
/// `scope` decides how far the rename reaches:
///
///   - `"current"` — only the label document of `image_path`.
///   - `"folder"`  — every label document of the dataset the image
///     belongs to, i.e. the sibling `Label@<name>` folder (or the
///     image folder itself for the in-folder convention).
///
/// `apply` false previews the rename: the reply carries the counts the
/// rename *would* produce and nothing is written. `apply` true writes
/// the rename.
///
/// A document the rename touches is normalized on the way out, exactly
/// like the normal save path does — a label file written by an older
/// version comes back in the modern schema. A document the rename does
/// not touch is left byte-for-byte alone.
#warnings("-unused_value")
async fn op_rename_class(req : RenameClassRequest) -> RenameClassReply {
  let from = req.from.trim().to_owned()
  let to = req.to.trim().to_owned()
  if from == "" {
    fail("rename_class: the source class name is empty")
  }
  if to == "" {
    fail("rename_class: the target class name is empty")
  }
  let scope = if req.scope == "folder" { "folder" } else { "current" }
  // The label document of the current image or video. Its folder is
  // also the folder the `folder` scope sweeps, which keeps the two
  // conventions (`Image@X` / `Label@X` and the flat in-folder one)
  // in one place.
  let current_label_path = label_path_for(req.image_path)
  let targets : Array[String] = []
  if scope == "folder" {
    let (label_dir, _) = split_dir_name(current_label_path)
    if label_dir == "" {
      fail(
        "rename_class: cannot determine the label folder for " + req.image_path,
      )
    }
    let names = @fs.readdir(label_dir, include_hidden=false, sort=false) catch {
      _ => []
    }
    for name in names {
      if !lower(name).has_suffix(".json") {
        continue
      }
      // The curated class list is not a label document — it is handled
      // separately below.
      if lower(name) == "classes.json" {
        continue
      }
      targets.push(join_path(label_dir, name))
    }
  }
  // The current document always takes part: for `scope=current` it is
  // the only one, and for `scope=folder` it may sit outside the swept
  // folder (an ad-hoc layout), where the sweep would miss it.
  if !targets.contains(current_label_path) {
    targets.push(current_label_path)
  }
  let mut scanned_files = 0
  let mut changed_files = 0
  let mut changed_annotations = 0
  let mut current_content = ""
  for path in targets {
    if !@fs.exists(path) {
      continue
    }
    let rewritten = match rewrite_label_document(path, from, to) {
      Some(r) => r
      None => continue
    }
    scanned_files = scanned_files + 1
    if rewritten.changed == 0 {
      continue
    }
    changed_annotations = changed_annotations + rewritten.changed
    changed_files = changed_files + 1
    if req.apply {
      @fs.write_text(path, rewritten.text, create_mode=@fs.CreateOrTruncate) catch {
        err =>
          fail("rename_class: write " + path + " failed: " + err.to_string())
      }
    }
    if path == current_label_path {
      current_content = rewritten.text
    }
  }
  // The curated class list is the sidebar's source of truth whenever
  // it exists, so a rename that left it alone would show the old class
  // name right after the rename.
  let curated_updated = if scope == "folder" {
    let image_dir = derive_image_dir(req.image_path)
    rename_curated_classes(image_dir, from, to, req.apply)
  } else {
    false
  }
  {
    image_path: req.image_path,
    from,
    to,
    scope,
    applied: req.apply,
    changed_annotations,
    changed_files,
    scanned_files,
    current_content,
    current_label_path,
    curated_updated,
  }
}

///|
/// Read one label document, normalize it and rename the class `from`
/// into `to`. Returns `None` when the file cannot be read or does not
/// hold a parseable label.
async fn rewrite_label_document(
  path : String,
  from : String,
  to : String,
) -> RewriteResult? {
  let text = match read_label_file_text(path) {
    Some(t) => t
    None => return None
  }
  let (_, basename) = split_dir_name(path)
  let normalized = try {
    let (n, _) = parse_label_text(text, basename)
    Some(n)
  } catch {
    _ => None
  }
  let normalized = match normalized {
    Some(n) => n
    None => return None
  }
  let doc = @json.parse(normalized)
  let changed = rename_class_types(doc, from, to)
  Some({ changed, text: doc.stringify(), })
}

///|
/// Read a file as UTF-8 text. Returns `None` when the file cannot be
/// read or does not hold valid UTF-8.
async fn read_label_file_text(path : String) -> String? {
  let data = @fs.read_binary(path) catch { _ => return None }
  let text = @utf8.decode(data) catch { _ => return None }
  Some(text)
}

///|
/// Rename the class in the curated class list (`classes.json`) that
/// sits next to the image folder. Returns true when the list carried
/// the old name.
///
/// Only the `{"classes": ["a", "b"]}` shape is rewritten — that is
/// what `op_save_classes` writes. A curated file in any other shape is
/// left alone rather than being reshaped, and a file that does not
/// exist is not an error: the curated list is optional.
async fn rename_curated_classes(
  image_dir : String,
  from : String,
  to : String,
  apply : Bool,
) -> Bool {
  if image_dir == "" {
    return false
  }
  let path = join_path(image_dir, "classes.json")
  if !@fs.exists(path) {
    return false
  }
  let text = match read_label_file_text(path) {
    Some(t) => t
    None => return false
  }
  let parsed = Some(@json.parse(text)) catch { _ => None }
  let parsed = match parsed {
    Some(p) => p
    None => return false
  }
  let members : Map[String, Json] = match parsed {
    Object(m) => m
    _ => return false
  }
  let raw : Array[Json] = match members.get("classes") {
    Some(Array(a)) => a
    _ => return false
  }
  let names : Array[String] = []
  let mut touched = false
  for entry in raw {
    match entry {
      String(name) =>
        if name == from {
          names.push(to)
          touched = true
        } else {
          names.push(name)
        }
      _ => return false
    }
  }
  if !touched {
    return false
  }
  if apply {
    @fs.write_text(
      path,
      render_curated_classes(names),
      create_mode=@fs.CreateOrTruncate,
    ) catch {
      err => fail("rename_class: write " + path + " failed: " + err.to_string())
    }
  }
  true
}
