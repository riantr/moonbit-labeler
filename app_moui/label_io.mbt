// app_moui/label_io.mbt — JSON label parser for MoUI app.
//
// Phase 5.14.B — wire the 5.14.A class_id field end-to-end:
// the JSON label file's `type` field (which is the class *name*)
// maps to Annotation.class_id via reverse lookup in
// model.classes. Until the full IPC bridge is in place
// (op_set_annotations is wired to app_moui's Msg dispatch),
// this module provides the in-process parser so the dataflow
// is verifiable end-to-end.
//
// Input format (matches the normalized schema emitted by
// extensions/labeler/labeler.mbt::normalize_label_json):
//
//   {
//     "img_name": "<string>",
//     "infos": [
//       {
//         "id": "<string>",
//         "shape": "rect" | "polygon" | "keypoint",
//         "type": "<class name>",
//         "points": [[<x>, <y>], ...]
//       },
//       ...
//     ],
//     "bindings": [
//       {
//         "id": "<string>",
//         "from": "<info-id>",
//         "to": "<info-id>",
//         "type": "<binding-type>"
//       },
//       ...
//     ]
//   }
//
// Output: (Array[Annotation], Array[Binding]) ready to feed
// directly into SetAnnotations. Each Annotation's class_id is
// the resolved ClassEntry.id for the info's `type` (or "" when
// the class doesn't exist in model.classes).

// ─────────────────────────────────────────────────────────────────
// Reverse class lookup (class name → class_id)
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.14.B — look up the class_id for a given class name in
/// the supplied classes array. Returns `Some(id)` on the first
/// match (first-wins — class names are assumed unique within
/// `classes`; duplicates are allowed but the first wins, same as
/// the existing `class_lookup_name` lookup direction).
///
/// Returns `None` when no matching class exists. The caller
/// decides what to do with the miss — `parse_label_text` below
/// translates it into an empty class_id (which triggers
/// `class_lookup_name`'s fallback to `ann.id` at render time).
pub fn class_id_for_name(name : String, classes : Array[ClassEntry]) -> String? {
  for c in classes {
    if c.name == name {
      return Some(c.id)
    }
  }
  None
}

///|
/// Phase 5.16 — inverse of `class_id_for_name`: look up the
/// class_name for a given class_id. Returns the name on the
/// first match (first-wins). Returns "" when no matching
/// class exists — `serialize_label_text` translates this into
/// the JSON `type` field as "" (the normalised schema's
/// "unassigned" sentinel).
///
/// Used by `serialize_label_text` to write the JSON's `type`
/// field from the model's `class_id`. Without the inverse
/// helper, the serialiser would have to carry its own
/// reverse-lookup loop, and we already have two other
/// class_id ↔ name helpers (`class_id_for_name`,
/// `class_lookup_name`) — symmetry feels right.
pub fn class_name_for_id(id : String, classes : Array[ClassEntry]) -> String {
  for c in classes {
    if c.id == id {
      return c.name
    }
  }
  ""
}

///|
/// Phase 5.16 — extract the filename portion of a file path.
/// Used by `serialize_label_text` to populate the JSON's
/// `img_name` field from `model.imageSource` (which stores the
/// full file path). Handles both forward and backward slashes
/// (Windows path support).
pub fn path_basename(path : String) -> String {
  // Find the last occurrence of either '/' or '\\' and return
  // everything after it. Falls through to the full path when
  // no separator is found (the input is already a basename).
  let chars : Array[Char] = path.to_array()
  let mut last_sep : Int = -1
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i] == '/' || chars[i] == '\\' {
      last_sep = i
    }
  }
  if last_sep < 0 {
    return path
  }
  let out : Array[Char] = []
  for i = last_sep + 1; i < chars.length(); i = i + 1 {
    out.push(chars[i])
  }
  String::from_array(out)
}

// ─────────────────────────────────────────────────────────────────
// Shape / point helpers (private)
// ─────────────────────────────────────────────────────────────────

///|
/// Parse the JSON shape string into the Shape enum. Returns
/// `None` for any unrecognised shape — the caller skips the
/// annotation (matches the silent-skip policy elsewhere).
fn parse_shape(s : String) -> Shape? {
  match s {
    "rect" => Some(Rect)
    "polygon" => Some(Polygon)
    "keypoint" => Some(Keypoint)
    _ => None
  }
}

///|
/// Extract a `[[x, y], ...]` array of points from a Json value.
/// Returns an empty array for malformed input (lets the caller
/// skip the annotation silently — the normalised JSON always
/// has well-formed arrays for entries that survived the first
/// pass).
fn parse_points_array(json : Json) -> Array[Point] {
  let arr : Array[Json] = match json {
    Array(a) => a
    _ => []
  }
  let out : Array[Point] = []
  for entry in arr {
    match entry {
      Array(coords) =>
        if coords.length() >= 2 {
          let x : Double = match coords[0] {
            Number(n, ..) => n
            _ => 0.0
          }
          let y : Double = match coords[1] {
            Number(n, ..) => n
            _ => 0.0
          }
          out.push({ x, y, })
        }
      _ => ()
    }
  }
  out
}

// ─────────────────────────────────────────────────────────────────
// Top-level parser
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.14.B — parse a normalized JSON label text into
/// (annotations, bindings) ready for SetAnnotations. Returns
/// the parsed pair; empty arrays when the JSON is malformed
/// or the top-level structure is wrong (no raise — the caller
/// treats an empty result as "load failed, show toast").
///
/// `classes` is the model.classes table; used to translate
/// each annotation's `type` (class name) into class_id. When
/// the class name doesn't resolve, the annotation's class_id
/// stays empty and the canvas falls back to ann.id for the
/// label text (5.14.A's `class_lookup_name` fallback path).
pub fn parse_label_text(
  text : String,
  classes : Array[ClassEntry],
) -> (Array[Annotation], Array[Binding]) {
  let raw : Json = @json.parse(text) catch { _ => return ([], []) }
  let members : Map[String, Json] = match raw {
    Object(m) => m
    _ => return ([], [])
  }
  // 1. Parse infos → annotations.
  let raw_infos : Array[Json] = match members.get("infos") {
    Some(Array(a)) => a
    _ => []
  }
  let annotations : Array[Annotation] = []
  for entry in raw_infos {
    let obj : Map[String, Json] = match entry {
      Object(m) => m
      _ => continue
    }
    let id : String = match obj.get("id") {
      Some(String(s)) => s
      _ => continue
    }
    let shape_str : String = match obj.get("shape") {
      Some(String(s)) => s
      _ => continue
    }
    let shape : Shape = match parse_shape(shape_str) {
      Some(s) => s
      None => continue
    }
    let points : Array[Point] = match obj.get("points") {
      Some(j) => parse_points_array(j)
      None => []
    }
    // Annotations with zero points are silently dropped — they
    // would render as nothing on the canvas and confuse the
    // handle hit-test (5.3 hit_test.mbt asserts N >= 1).
    if points.length() == 0 {
      continue
    }
    // Resolve `type` (class name) to class_id via the class
    // table. Empty class_id is the "unassigned" sentinel;
    // render time falls back to ann.id.
    let class_id : String = match obj.get("type") {
      Some(String(name)) =>
        match class_id_for_name(name, classes) {
          Some(id) => id
          None => ""
        }
      _ => ""
    }
    annotations.push({ id, shape, points, class_id, })
  }
  // 2. Parse bindings (no class lookup needed; bindings carry
  // from/to ids only).
  let raw_bindings : Array[Json] = match members.get("bindings") {
    Some(Array(a)) => a
    _ => []
  }
  let bindings : Array[Binding] = []
  for entry in raw_bindings {
    let obj : Map[String, Json] = match entry {
      Object(m) => m
      _ => continue
    }
    let id : String = match obj.get("id") {
      Some(String(s)) => s
      _ => continue
    }
    let from : String = match obj.get("from") {
      Some(String(s)) => s
      _ => continue
    }
    let to : String = match obj.get("to") {
      Some(String(s)) => s
      _ => continue
    }
    // Skip self-bindings (from == to) — invalid by construction.
    if from == to {
      continue
    }
    bindings.push({ id, from, to, })
  }
  (annotations, bindings)
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.16 — serialize_label_text (mirror of parse_label_text)
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.16 — convert a Shape enum to its JSON string form.
/// Matches the strings `parse_label_text` accepts (so a
/// serialize → parse round-trip is identity-preserving).
fn shape_to_string(shape : Shape) -> String {
  match shape {
    Rect => "rect"
    Polygon => "polygon"
    Keypoint => "keypoint"
  }
}

///|
/// Phase 5.16 — convert a Point to its JSON array form.
fn point_to_json(p : Point) -> Json {
  Json::array([Json::number(p.x), Json::number(p.y)])
}

///|
/// Phase 5.16 — serialize the model's annotations + bindings
/// back into the normalized label JSON text. Round-trips
/// against `parse_label_text`: serialize → parse returns the
/// same annotations + bindings + class_ids (modulo class-name
/// resolution: serialize writes the class *name* in the JSON
/// `type` field, parse resolves it back to class_id via the
/// same `model.classes` table).
///
/// `img_name` is derived from `model.imageSource` via
/// `path_basename`. When `imageSource` is "" (placeholder
/// mode), `img_name` is also "".
pub fn serialize_label_text(model : Model) -> String {
  let classes : Array[ClassEntry] = model.classes
  let img_name : String = path_basename(model.imageSource)
  let infos_json : Array[Json] = []
  for ann in model.annotations {
    // Each info: { id, shape, type (class name from class_id),
    // points (array of [x, y] pairs) }
    let type_name : String = class_name_for_id(ann.class_id, classes)
    let points_json : Array[Json] = []
    for p in ann.points {
      points_json.push(point_to_json(p))
    }
    let info_members : Map[String, Json] = Map::from_array([
      ("id", Json::string(ann.id)),
      ("shape", Json::string(shape_to_string(ann.shape))),
      ("type", Json::string(type_name)),
      ("points", Json::array(points_json)),
    ])
    infos_json.push(Json::object(info_members))
  }
  let bindings_json : Array[Json] = []
  for b in model.bindings {
    let binding_members : Map[String, Json] = Map::from_array([
      ("id", Json::string(b.id)),
      ("from", Json::string(b.from)),
      ("to", Json::string(b.to)),
      ("type", Json::string("same_group")),
    ])
    bindings_json.push(Json::object(binding_members))
  }
  let members : Map[String, Json] = Map::from_array([
    ("img_name", Json::string(img_name)),
    ("infos", Json::array(infos_json)),
    ("bindings", Json::array(bindings_json)),
  ])
  Json::object(members).stringify()
}
