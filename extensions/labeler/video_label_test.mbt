// Tests for the per-frame annotation model.
//
// The bug this file guards against: the frontend used to merge every
// frame's objects into one flat union before writing the label file, so
// a box drawn on frame 5 reappeared on frame 9. The model keeps one
// annotation set per frame (or per group of frames), and the tests pin
// that isolation.
//
// The tests drive the public JSON-level contract — `video_frame_label`
// and `merge_video_frame_label` — rather than the internal `FrameSet`
// struct, so they exercise the same surface the IPC ops use.

///|
/// Build a normalized rect annotation entry.
fn test_info(id : String, x : Double) -> Json {
  Json::object(
    Map::from_array([
      ("id", Json::string(id)),
      ("shape", Json::string("rect")),
      ("type", Json::string("person")),
      (
        "points",
        Json::array([
          Json::array([Json::number(x), Json::number(0.0)]),
          Json::array([Json::number(x + 10.0), Json::number(10.0)]),
        ]),
      ),
    ]),
  )
}

///|
/// The ids carried by a label document's `infos`, in order.
fn doc_info_ids(doc : Json) -> Array[String] {
  let ids : Array[String] = []
  match doc {
    Object(m) =>
      match m.get("infos") {
        Some(Array(infos)) =>
          for info in infos {
            match info {
              Object(io) =>
                match io.get("id") {
                  Some(String(v)) => ids.push(v)
                  _ => ()
                }
              _ => ()
            }
          }
        _ => ()
      }
    _ => ()
  }
  ids
}

///|
/// An empty label document.
fn empty_doc() -> Json {
  Json::object(
    Map::from_array([
      ("img_name", Json::string("clip_001.mp4")),
      ("infos", Json::array([])),
      ("bindings", Json::array([])),
    ]),
  )
}

///|
/// A document holding one per-frame set for frame 5.
fn doc_with_frame_set() -> Json {
  Json::object(
    Map::from_array([
      ("img_name", Json::string("clip_001.mp4")),
      ("infos", Json::array([])),
      ("bindings", Json::array([])),
      (
        "frame_labels",
        Json::array([
          Json::object(
            Map::from_array([
              ("frames", Json::array([Json::number(5.0)])),
              ("infos", Json::array([test_info("obj_a", 1.0)])),
              ("bindings", Json::array([])),
            ]),
          ),
        ]),
      ),
    ]),
  )
}

///|
/// A label document carrying one annotation set.
fn set_doc(id : String, x : Double) -> Json {
  Json::object(
    Map::from_array([
      ("img_name", Json::string("clip_001.mp4")),
      ("infos", Json::array([test_info(id, x)])),
      ("bindings", Json::array([])),
    ]),
  )
}

///|
test "an empty document has no annotations on any frame" {
  let doc = empty_doc()
  assert_eq(doc_info_ids(video_frame_label(doc, 0)), [])
  assert_eq(doc_info_ids(video_frame_label(doc, 999)), [])
}

///|
test "a legacy flat document applies to the frames it lists" {
  let doc = Json::object(
    Map::from_array([
      ("img_name", Json::string("clip_001.mp4")),
      ("infos", Json::array([test_info("obj_a", 1.0)])),
      ("bindings", Json::array([])),
      ("frames", Json::array([Json::number(12.0), Json::number(24.0)])),
    ]),
  )
  assert_eq(doc_info_ids(video_frame_label(doc, 12)), ["obj_a"])
  assert_eq(doc_info_ids(video_frame_label(doc, 24)), ["obj_a"])
  assert_eq(doc_info_ids(video_frame_label(doc, 5)), [])
}

///|
test "a legacy flat document without frames applies to every frame" {
  let doc = Json::object(
    Map::from_array([
      ("img_name", Json::string("clip_001.mp4")),
      ("infos", Json::array([test_info("obj_a", 1.0)])),
      ("bindings", Json::array([])),
    ]),
  )
  assert_eq(doc_info_ids(video_frame_label(doc, 0)), ["obj_a"])
  assert_eq(doc_info_ids(video_frame_label(doc, 999)), ["obj_a"])
}

///|
test "a per-frame set wins over the default set" {
  let doc = doc_with_frame_set()
  assert_eq(doc_info_ids(video_frame_label(doc, 5)), ["obj_a"])
  assert_eq(doc_info_ids(video_frame_label(doc, 9)), [])
}

///|
test "merging gives an unannotated frame its own set" {
  let merged = merge_video_frame_label(
    doc_with_frame_set(),
    9,
    set_doc("obj_b", 50.0),
  )
  assert_eq(doc_info_ids(video_frame_label(merged, 5)), ["obj_a"])
  assert_eq(doc_info_ids(video_frame_label(merged, 9)), ["obj_b"])
}

///|
test "merging updates a frame's own set instead of adding one" {
  let merged = merge_video_frame_label(
    doc_with_frame_set(),
    5,
    set_doc("obj_c", 7.0),
  )
  assert_eq(doc_info_ids(video_frame_label(merged, 5)), ["obj_c"])
  assert_eq(doc_info_ids(video_frame_label(merged, 9)), [])
}

///|
test "merging keeps two frames of the same video independent" {
  // The regression guard: a box drawn on frame 5 must not show up on
  // frame 9, and the other way round.
  let after_five = merge_video_frame_label(
    doc_with_frame_set(),
    5,
    set_doc("obj_a", 1.0),
  )
  let after_nine = merge_video_frame_label(
    after_five,
    9,
    set_doc("obj_b", 50.0),
  )
  assert_eq(doc_info_ids(video_frame_label(after_nine, 5)), ["obj_a"])
  assert_eq(doc_info_ids(video_frame_label(after_nine, 9)), ["obj_b"])
}

///|
test "merging keeps the frames of a shared set" {
  let doc = Json::object(
    Map::from_array([
      ("img_name", Json::string("clip_001.mp4")),
      ("infos", Json::array([])),
      ("bindings", Json::array([])),
      (
        "frame_labels",
        Json::array([
          Json::object(
            Map::from_array([
              ("frames", Json::array([Json::number(12.0), Json::number(13.0)])),
              ("infos", Json::array([test_info("obj_a", 1.0)])),
              ("bindings", Json::array([])),
            ]),
          ),
        ]),
      ),
    ]),
  )
  let merged = merge_video_frame_label(doc, 12, set_doc("obj_z", 3.0))
  // The set still covers frame 13, and both frames show the edit — a
  // shared set is edited as a unit.
  assert_eq(doc_info_ids(video_frame_label(merged, 12)), ["obj_z"])
  assert_eq(doc_info_ids(video_frame_label(merged, 13)), ["obj_z"])
}

///|
test "merging edits a legacy default set in place" {
  let doc = Json::object(
    Map::from_array([
      ("img_name", Json::string("clip_001.mp4")),
      ("infos", Json::array([test_info("obj_a", 1.0)])),
      ("bindings", Json::array([])),
      ("frames", Json::array([Json::number(12.0), Json::number(24.0)])),
    ]),
  )
  let merged = merge_video_frame_label(doc, 12, set_doc("obj_z", 3.0))
  assert_eq(doc_info_ids(video_frame_label(merged, 12)), ["obj_z"])
  assert_eq(doc_info_ids(video_frame_label(merged, 24)), ["obj_z"])
  assert_eq(doc_info_ids(video_frame_label(merged, 30)), [])
}

///|
test "merging adds a set for a frame outside a legacy default set" {
  let doc = Json::object(
    Map::from_array([
      ("img_name", Json::string("clip_001.mp4")),
      ("infos", Json::array([test_info("obj_a", 1.0)])),
      ("bindings", Json::array([])),
      ("frames", Json::array([Json::number(12.0)])),
    ]),
  )
  let merged = merge_video_frame_label(doc, 30, set_doc("obj_b", 50.0))
  assert_eq(doc_info_ids(video_frame_label(merged, 12)), ["obj_a"])
  assert_eq(doc_info_ids(video_frame_label(merged, 30)), ["obj_b"])
}

///|
test "merging is idempotent for the same frame" {
  let once = merge_video_frame_label(empty_doc(), 7, set_doc("obj_a", 1.0))
  let twice = merge_video_frame_label(once, 7, set_doc("obj_a", 1.0))
  assert_eq(doc_info_ids(video_frame_label(twice, 7)), ["obj_a"])
  assert_eq(video_annotated_frames(twice), [7])
}

///|
test "the annotated frames are reported in order" {
  let doc = merge_video_frame_label(empty_doc(), 30, set_doc("obj_c", 3.0))
  let doc = merge_video_frame_label(doc, 5, set_doc("obj_a", 1.0))
  assert_eq(video_annotated_frames(doc), [5, 30])
}

///|
test "the default set is written at the top level" {
  let merged = merge_video_frame_label(empty_doc(), 5, set_doc("obj_a", 1.0))
  match merged {
    Object(m) => {
      assert_eq(m.get("img_name"), Some(Json::string("clip_001.mp4")))
      assert_eq(m.get("infos"), Some(Json::array([])))
      assert_true(m.contains("frame_labels"))
    }
    _ => fail("expected a JSON object")
  }
}

///|
test "parse_label_text preserves the per-frame sets" {
  // The normalizer rebuilds the document from scratch, so a field it
  // does not know about is dropped. `frame_labels` has to survive that
  // round trip or every per-frame annotation is lost on the next save.
  let input =
    #|{"img_name":"clip_001.mp4","infos":[],"bindings":[],"frame_labels":[
    #|{"frames":[5],"infos":[{"id":"obj_a","shape":"rect","type":"person",
    #|"points":[[1,2],[3,4]]}],"bindings":[]}]}
  let (out, _) = parse_label_text(input, "clip_001.mp4") catch {
    _ => ("", "parse failed")
  }
  assert_true(out.contains("frame_labels"))
  let doc = @json.parse(out)
  assert_eq(doc_info_ids(video_frame_label(doc, 5)), ["obj_a"])
  assert_eq(doc_info_ids(video_frame_label(doc, 9)), [])
}

///|
test "a binding inside a per-frame set is validated against that set" {
  // The binding names two objects, but only one of them is in the set,
  // so it is dangling and must be dropped rather than silently kept.
  let doc = Json::object(
    Map::from_array([
      ("img_name", Json::string("clip_001.mp4")),
      ("infos", Json::array([])),
      ("bindings", Json::array([])),
      (
        "frame_labels",
        Json::array([
          Json::object(
            Map::from_array([
              ("frames", Json::array([Json::number(5.0)])),
              ("infos", Json::array([test_info("obj_a", 1.0)])),
              (
                "bindings",
                Json::array([
                  Json::object(
                    Map::from_array([
                      ("id", Json::string("b_1")),
                      ("from", Json::string("obj_a")),
                      ("to", Json::string("obj_missing")),
                      ("type", Json::string("same_group")),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    ]),
  )
  let (out, _) = parse_label_text(doc.stringify(), "clip_001.mp4") catch {
    _ => ("", "parse failed")
  }
  let reparsed = @json.parse(out)
  match video_frame_label(reparsed, 5) {
    Object(m) =>
      match m.get("bindings") {
        Some(Array(b)) => assert_eq(b.length(), 0)
        _ => fail("expected a bindings array")
      }
    _ => fail("expected a JSON object")
  }
}
