// Tests for the class-revision rewrite.
//
// The bug this file guards against: the sidebar's class list is only a
// projection of the annotation data, so a class that had been annotated
// with a wrong name could never be corrected — the only name-rewriting
// that existed was the tool-menu batch prefix/suffix actions, and those
// touched the current image only, in the frontend.
//
// The tests drive the public rewrite contract — `rename_class_types` —
// rather than the op, because the op is async (the async runtime cannot
// be called from a `test` block) and because the rewrite is where the
// interesting behaviour lives: it has to reach the per-frame sets of a
// video document and leave the bindings alone.

///|
/// Build a normalized annotation entry with the given id and class.
fn cr_info(id : String, class_name : String) -> Json {
  Json::object(
    Map::from_array([
      ("id", Json::string(id)),
      ("shape", Json::string("rect")),
      ("type", Json::string(class_name)),
      (
        "points",
        Json::array([
          Json::array([Json::number(1.0), Json::number(2.0)]),
          Json::array([Json::number(3.0), Json::number(4.0)]),
        ]),
      ),
    ]),
  )
}

///|
/// Build a binding entry.
fn cr_binding(id : String, from : String, to : String) -> Json {
  Json::object(
    Map::from_array([
      ("id", Json::string(id)),
      ("from", Json::string(from)),
      ("to", Json::string(to)),
      ("type", Json::string("same_group")),
    ]),
  )
}

///|
/// The class of the annotation with the given id, or "" when the
/// document has no such annotation.
fn cr_type_of(doc : Json, id : String) -> String {
  let members : Map[String, Json] = match doc {
    Object(m) => m
    _ => Map([])
  }
  let infos : Array[Json] = match members.get("infos") {
    Some(Array(a)) => a
    _ => []
  }
  for info in infos {
    let io : Map[String, Json] = match info {
      Object(o) => o
      _ => continue
    }
    let vid : String = match io.get("id") {
      Some(String(v)) => v
      _ => ""
    }
    if vid != "" && vid == id {
      let t : String = match io.get("type") {
        Some(String(s)) => s
        _ => ""
      }
      return t
    }
  }
  ""
}

///|
/// The class of the annotation with the given id inside the per-frame
/// set that covers `frame`, or "" when there is none.
fn cr_frame_type_of(doc : Json, frame : Double, id : String) -> String {
  let members : Map[String, Json] = match doc {
    Object(m) => m
    _ => Map([])
  }
  let sets : Array[Json] = match members.get("frame_labels") {
    Some(Array(a)) => a
    _ => []
  }
  for entry in sets {
    let eo : Map[String, Json] = match entry {
      Object(o) => o
      _ => continue
    }
    let frames : Array[Json] = match eo.get("frames") {
      Some(Array(a)) => a
      _ => []
    }
    let mut covers = false
    for f in frames {
      let n : Double = match f {
        Number(v, ..) => v
        _ => 0.0
      }
      if n == frame {
        covers = true
      }
    }
    if !covers {
      continue
    }
    let infos : Array[Json] = match eo.get("infos") {
      Some(Array(a)) => a
      _ => []
    }
    for info in infos {
      let io : Map[String, Json] = match info {
        Object(o) => o
        _ => continue
      }
      let vid : String = match io.get("id") {
        Some(String(v)) => v
        _ => ""
      }
      if vid != "" && vid == id {
        let t : String = match io.get("type") {
          Some(String(s)) => s
          _ => ""
        }
        return t
      }
    }
  }
  ""
}

///|
/// A flat (image-mode) document with two annotations of one class and
/// one of another, plus a binding.
fn cr_flat_doc() -> Json {
  Json::object(
    Map::from_array([
      ("img_name", Json::string("a.jpg")),
      (
        "infos",
        Json::array([
          cr_info("obj_a", "knife"),
          cr_info("obj_b", "scissors"),
          cr_info("obj_c", "knife"),
        ]),
      ),
      ("bindings", Json::array([cr_binding("b_a", "obj_a", "obj_c")])),
    ]),
  )
}

///|
/// A video document with one default set and two per-frame sets.
fn cr_video_doc() -> Json {
  Json::object(
    Map::from_array([
      ("img_name", Json::string("clip.mp4")),
      ("infos", Json::array([cr_info("obj_top", "knife")])),
      ("bindings", Json::array([])),
      (
        "frame_labels",
        Json::array([
          Json::object(
            Map::from_array([
              ("frames", Json::array([Json::number(5.0)])),
              ("infos", Json::array([cr_info("obj_f5", "knife")])),
              ("bindings", Json::array([])),
            ]),
          ),
          Json::object(
            Map::from_array([
              ("frames", Json::array([Json::number(9.0)])),
              (
                "infos",
                Json::array([
                  cr_info("obj_f9", "knife"),
                  cr_info("obj_f9b", "scissors"),
                ]),
              ),
              ("bindings", Json::array([])),
            ]),
          ),
        ]),
      ),
    ]),
  )
}

///|
test "rename_class_types rewrites the matching annotations only" {
  let doc = cr_flat_doc()
  let changed = rename_class_types(doc, "knife", "blade")
  assert_eq(changed, 2)
  assert_eq(cr_type_of(doc, "obj_a"), "blade")
  assert_eq(cr_type_of(doc, "obj_c"), "blade")
  // The annotation of another class is untouched.
  assert_eq(cr_type_of(doc, "obj_b"), "scissors")
}

///|
test "rename_class_types leaves the bindings alone" {
  let doc = cr_flat_doc()
  let _ = rename_class_types(doc, "knife", "blade")
  // A binding's `type` says what kind of relation it is, not which
  // class it belongs to — rewriting it would break the schema.
  let members : Map[String, Json] = match doc {
    Object(m) => m
    _ => Map([])
  }
  let bindings : Array[Json] = match members.get("bindings") {
    Some(Array(a)) => a
    _ => []
  }
  assert_eq(bindings.length(), 1)
  let b : Map[String, Json] = match bindings[0] {
    Object(o) => o
    _ => Map([])
  }
  let btype : String = match b.get("type") {
    Some(String(s)) => s
    _ => ""
  }
  assert_eq(btype, "same_group")
}

///|
test "rename_class_types reaches the per-frame sets of a video" {
  let doc = cr_video_doc()
  let changed = rename_class_types(doc, "knife", "blade")
  // The default set plus frame 5 plus frame 9.
  assert_eq(changed, 3)
  assert_eq(cr_type_of(doc, "obj_top"), "blade")
  assert_eq(cr_frame_type_of(doc, 5.0, "obj_f5"), "blade")
  assert_eq(cr_frame_type_of(doc, 9.0, "obj_f9"), "blade")
  // The other class inside the same frame set is untouched.
  assert_eq(cr_frame_type_of(doc, 9.0, "obj_f9b"), "scissors")
}

///|
test "rename_class_types keeps the per-frame sets in the document" {
  let doc = cr_video_doc()
  let _ = rename_class_types(doc, "knife", "blade")
  let members : Map[String, Json] = match doc {
    Object(m) => m
    _ => Map([])
  }
  let sets : Array[Json] = match members.get("frame_labels") {
    Some(Array(a)) => a
    _ => []
  }
  assert_eq(sets.length(), 2)
}

///|
test "rename_class_types reports nothing when the class is not used" {
  let doc = cr_flat_doc()
  let changed = rename_class_types(doc, "lithium_cell", "battery")
  assert_eq(changed, 0)
  assert_eq(cr_type_of(doc, "obj_a"), "knife")
}

///|
test "rename_class_types is a no-op for an empty or equal name" {
  let doc = cr_flat_doc()
  assert_eq(rename_class_types(doc, "", "blade"), 0)
  assert_eq(rename_class_types(doc, "knife", ""), 0)
  assert_eq(rename_class_types(doc, "knife", "knife"), 0)
  assert_eq(cr_type_of(doc, "obj_a"), "knife")
}

///|
test "rename_class_types handles a document without annotations" {
  let doc = Json::object(
    Map::from_array([
      ("img_name", Json::string("a.jpg")),
      ("infos", Json::array([])),
      ("bindings", Json::array([])),
    ]),
  )
  assert_eq(rename_class_types(doc, "knife", "blade"), 0)
}

///|
test "rename_class_types survives a document that is not an object" {
  assert_eq(rename_class_types(Json::null(), "knife", "blade"), 0)
  assert_eq(rename_class_types(Json::array([]), "knife", "blade"), 0)
}
