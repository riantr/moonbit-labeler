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
