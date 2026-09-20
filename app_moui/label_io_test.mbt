// app_moui/label_io_test.mbt — blackbox tests for the JSON
// label parser added in Phase 5.14.B.
//
// The parser converts a normalized label JSON text into
// (annotations, bindings) ready for SetAnnotations. The tests
// exercise the round-trip: build a JSON string → parse → verify
// the resulting Annotation / Binding structures are correct.
//
// Round-trip via the JSON-RPC bridge (extensions/labeler) is
// NOT exercised here — that lives in extensions/labeler/ tests.
// These tests cover the in-process MoUI-side dataflow only.

// ─────────────────────────────────────────────────────────────────
// class_id_for_name
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.14.B — class_id_for_name returns Some(id) on the
/// first matching class name (first-wins).
test "class_id_for_name — resolves name to id (5.14.B)" {
  let classes : Array[ClassEntry] = [
    { id: "cls-car", name: "car", is_default: true, },
    { id: "cls-person", name: "person", is_default: false, },
  ]
  assert_eq(class_id_for_name("car", classes), Some("cls-car"))
  assert_eq(class_id_for_name("person", classes), Some("cls-person"))
}

///|
/// Phase 5.14.B — class_id_for_name returns None when the name
/// doesn't resolve. The parser treats this as "unassigned"
/// (empty class_id) and the canvas falls back to ann.id for
/// the label text.
test "class_id_for_name — unknown name returns None (5.14.B)" {
  let classes : Array[ClassEntry] = [
    { id: "cls-car", name: "car", is_default: true, },
  ]
  assert_eq(class_id_for_name("truck", classes), None)
}

// ─────────────────────────────────────────────────────────────────
// parse_label_text
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.14.B — parse a minimal label JSON (one rect
/// annotation, no bindings) into a single Annotation with
/// class_id resolved via model.classes.
test "parse_label_text — single rect with class lookup (5.14.B)" {
  let classes : Array[ClassEntry] = [
    { id: "cls-car", name: "car", is_default: true, },
  ]
  let text : String =
    #|{
    #|  "img_name": "test.jpg",
    #|  "infos": [
    #|    {
    #|      "id": "ann-1",
    #|      "shape": "rect",
    #|      "type": "car",
    #|      "points": [[10, 20], [110, 220]]
    #|    }
    #|  ],
    #|  "bindings": []
    #|}
  let (anns, binds) = parse_label_text(text, classes)
  assert_eq(anns.length(), 1)
  assert_eq(binds.length(), 0)
  let a : Annotation = anns[0]
  assert_eq(a.id, "ann-1")
  match a.shape {
    Rect => ()
    _ => fail("expected Rect")
  }
  assert_eq(a.class_id, "cls-car")
  assert_eq(a.points.length(), 2)
  assert_eq(a.points[0].x, 10.0)
  assert_eq(a.points[0].y, 20.0)
  assert_eq(a.points[1].x, 110.0)
  assert_eq(a.points[1].y, 220.0)
}

///|
/// Phase 5.14.B — class_id is empty when the class name
/// doesn't resolve. The canvas will fall back to ann.id for
/// the label text via class_lookup_name's fallback path.
test "parse_label_text — orphan class_name → empty class_id (5.14.B)" {
  let classes : Array[ClassEntry] = [
    { id: "cls-car", name: "car", is_default: true, },
  ]
  let text : String =
    #|{
    #|  "img_name": "x.jpg",
    #|  "infos": [
    #|    {
    #|      "id": "ann-1",
    #|      "shape": "keypoint",
    #|      "type": "deleted-class",
    #|      "points": [[50, 50]]
    #|    }
    #|  ],
    #|  "bindings": []
    #|}
  let (anns, _) = parse_label_text(text, classes)
  assert_eq(anns.length(), 1)
  assert_eq(anns[0].class_id, "")
}

///|
/// Phase 5.14.B — parse a label JSON with one binding
/// referencing two annotation ids. Verify the binding's
/// from/to fields are populated correctly.
test "parse_label_text — binding references two infos (5.14.B)" {
  let classes : Array[ClassEntry] = []
  let text : String =
    #|{
    #|  "img_name": "x.jpg",
    #|  "infos": [
    #|    {"id": "a1", "shape": "rect", "type": "x", "points": [[0,0],[10,10]]},
    #|    {"id": "a2", "shape": "rect", "type": "x", "points": [[20,20],[30,30]]}
    #|  ],
    #|  "bindings": [
    #|    {"id": "b1", "from": "a1", "to": "a2", "type": "same_group"}
    #|  ]
    #|}
  let (anns, binds) = parse_label_text(text, classes)
  assert_eq(anns.length(), 2)
  assert_eq(binds.length(), 1)
  assert_eq(binds[0].id, "b1")
  assert_eq(binds[0].from, "a1")
  assert_eq(binds[0].to, "a2")
}

///|
/// Phase 5.14.B — malformed JSON returns empty arrays
/// (silent fail — the caller surfaces a toast). Verifies the
/// parser doesn't `raise` on garbage input.
test "parse_label_text — malformed JSON returns empty (5.14.B)" {
  let (anns, binds) = parse_label_text("not valid json", [])
  assert_eq(anns.length(), 0)
  assert_eq(binds.length(), 0)
}

///|
/// Phase 5.14.B — empty infos + empty bindings parses
/// successfully to empty arrays. Verifies the happy path
/// for an annotation-free label file.
test "parse_label_text — empty infos and bindings (5.14.B)" {
  let text : String =
    #|{
    #|  "img_name": "blank.jpg",
    #|  "infos": [],
    #|  "bindings": []
    #|}
  let (anns, binds) = parse_label_text(text, [])
  assert_eq(anns.length(), 0)
  assert_eq(binds.length(), 0)
}

///|
/// Phase 5.14.B — annotations with zero points are silently
/// dropped (they would render as nothing on the canvas).
test "parse_label_text — annotations with 0 points are dropped (5.14.B)" {
  let text : String =
    #|{
    #|  "img_name": "x.jpg",
    #|  "infos": [
    #|    {"id": "a1", "shape": "rect", "type": "x", "points": []},
    #|    {"id": "a2", "shape": "rect", "type": "x", "points": [[1,1],[2,2]]}
    #|  ],
    #|  "bindings": []
    #|}
  let (anns, _) = parse_label_text(text, [])
  assert_eq(anns.length(), 1)
  assert_eq(anns[0].id, "a2")
}

///|
/// Phase 5.14.B — unrecognised shape strings are silently
/// skipped. Defends against future schema additions that the
/// older parser doesn't know about.
test "parse_label_text — unknown shape is skipped (5.14.B)" {
  let text : String =
    #|{
    #|  "img_name": "x.jpg",
    #|  "infos": [
    #|    {"id": "a1", "shape": "unknown_future_shape", "type": "x", "points": [[1,1]]},
    #|    {"id": "a2", "shape": "keypoint", "type": "x", "points": [[2,2]]}
    #|  ],
    #|  "bindings": []
    #|}
  let (anns, _) = parse_label_text(text, [])
  assert_eq(anns.length(), 1)
  assert_eq(anns[0].id, "a2")
}

///|
/// Phase 5.14.B — bindings with from == to are skipped
/// (invalid by construction). Same silent-skip policy as 5.9.
test "parse_label_text — self-binding (from==to) is skipped (5.14.B)" {
  let text : String =
    #|{
    #|  "img_name": "x.jpg",
    #|  "infos": [
    #|    {"id": "a1", "shape": "rect", "type": "x", "points": [[1,1],[2,2]]}
    #|  ],
    #|  "bindings": [
    #|    {"id": "b1", "from": "a1", "to": "a1", "type": "same_group"}
    #|  ]
    #|}
  let (_, binds) = parse_label_text(text, [])
  assert_eq(binds.length(), 0)
}

// ─────────────────────────────────────────────────────────────────
// LoadLabelJson Msg dispatch
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.14.B — LoadLabelJson dispatches into the model via
/// the parser. After dispatch, model.annotations + model.bindings
/// are populated with the parsed data and class_ids are resolved.
test "LoadLabelJson — populates annotations + class_ids (5.14.B)" {
  let classes : Array[ClassEntry] = [
    { id: "cls-car", name: "car", is_default: true, },
  ]
  let initial : Model = { ..Model::new(), classes, }
  let text : String =
    #|{
    #|  "img_name": "x.jpg",
    #|  "infos": [
    #|    {"id": "ann-1", "shape": "rect", "type": "car", "points": [[10,20],[110,220]]}
    #|  ],
    #|  "bindings": []
    #|}
  let (next, _) = update(initial, LoadLabelJson(text))
  assert_eq(next.annotations.length(), 1)
  assert_eq(next.bindings.length(), 0)
  assert_eq(next.annotations[0].id, "ann-1")
  assert_eq(next.annotations[0].class_id, "cls-car")
  assert_true(next.staticLayerDirty)
}

///|
/// Phase 5.14.B — LoadLabelJson with an unknown class name
/// leaves class_id empty (the canvas fallback path renders
/// ann.id for the label text).
test "LoadLabelJson — orphan class_name leaves class_id empty (5.14.B)" {
  let initial : Model = Model::new()
  let text : String =
    #|{
    #|  "img_name": "x.jpg",
    #|  "infos": [
    #|    {"id": "ann-1", "shape": "rect", "type": "deleted", "points": [[10,20],[110,220]]}
    #|  ],
    #|  "bindings": []
    #|}
  let (next, _) = update(initial, LoadLabelJson(text))
  assert_eq(next.annotations[0].class_id, "")
}

// ─────────────────────────────────────────────────────────────────
// Phase 5.16 — serialize_label_text + inverse helpers + Msg tests
// ──────────────────────────────────────────────���──────────────────
//
// 5.16 mirrors 5.14.B's parse_label_text with the reverse
// operation: convert model.annotations + model.bindings back into
// the normalized label JSON. The serialize → parse round-trip
// must preserve every annotation + binding + class_id
// (modulo class-name resolution, which uses the same
// model.classes table on both sides).

///|
/// Phase 5.16 — class_name_for_id returns the class name on
/// first match (first-wins). Inverse of class_id_for_name.
test "class_name_for_id — resolves id to name (5.16)" {
  let classes : Array[ClassEntry] = [
    { id: "cls-car", name: "car", is_default: true, },
    { id: "cls-person", name: "person", is_default: false, },
  ]
  assert_eq(class_name_for_id("cls-car", classes), "car")
  assert_eq(class_name_for_id("cls-person", classes), "person")
}

///|
/// Phase 5.16 — class_name_for_id returns "" for unknown ids
/// (the serialised sentinel that downstream consumers can use to
/// flag unassigned entries).
test "class_name_for_id — unknown id returns empty string (5.16)" {
  let classes : Array[ClassEntry] = [
    { id: "cls-car", name: "car", is_default: true, },
  ]
  assert_eq(class_name_for_id("cls-unknown", classes), "")
}

///|
/// Phase 5.16 — class_id_for_name ∘ class_name_for_id round-trip
/// on the same classes table returns the input id. Sanity check
/// for the inverse helpers.
test "class_name_for_id ∘ class_id_for_name — round-trip (5.16)" {
  let classes : Array[ClassEntry] = [
    { id: "cls-car", name: "car", is_default: true, },
  ]
  let id_back : String? = class_id_for_name(
    class_name_for_id("cls-car", classes),
    classes,
  )
  assert_eq(id_back, Some("cls-car"))
}

///|
/// Phase 5.16 — path_basename extracts the filename from a
/// full Windows-style path. The model stores imageSource as
/// the full path; the serialised JSON's `img_name` field
/// wants just the basename.
test "path_basename — extracts filename from Windows path (5.16)" {
  assert_eq(path_basename("C:\\Users\\foo\\bar.jpg"), "bar.jpg")
  assert_eq(path_basename("D:/datasets/test.png"), "test.png")
}

///|
/// Phase 5.16 — path_basename returns the input unchanged
/// when no separator is present (input is already a
/// basename).
test "path_basename — no separator returns input (5.16)" {
  assert_eq(path_basename("test.jpg"), "test.jpg")
  assert_eq(path_basename(""), "")
}

///|
/// Phase 5.16 — path_basename handles the last separator
/// (basename is everything after the last '/', not the
/// first). Common case: a path with both forward and
/// backward slashes (Windows UNC paths, mixed-style
/// config files).
test "path_basename — last separator wins (5.16)" {
  assert_eq(path_basename("/var/data/sub/test.jpg"), "test.jpg")
  assert_eq(path_basename("C:\\Users\\foo\\Pictures\\sub\\a.png"), "a.png")
}

///|
/// Phase 5.16 — serialize_label_text produces a JSON string
/// that round-trips through parse_label_text with the same
/// annotations + bindings + class_ids. Verifies the
/// serialize → parse identity for the no-class case.
test "serialize_label_text — round-trips via parse_label_text (5.16)" {
  let initial : Model = {
    ..Model::new(),
    imageSource: "/data/test.jpg",
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 10.0, y: 20.0, }, { x: 110.0, y: 220.0, }],
        class_id: "",
      },
      {
        id: "ann-2",
        shape: Keypoint,
        points: [{ x: 50.0, y: 50.0, }],
        class_id: "",
      },
    ],
    bindings: [{ id: "b-1", from: "ann-1", to: "ann-2", }],
  }
  let text : String = serialize_label_text(initial)
  let (anns, binds) = parse_label_text(text, [])
  assert_eq(anns.length(), 2)
  assert_eq(binds.length(), 1)
  assert_eq(anns[0].id, "ann-1")
  match anns[0].shape {
    Rect => ()
    _ => fail("expected Rect")
  }
  assert_eq(anns[1].id, "ann-2")
  match anns[1].shape {
    Keypoint => ()
    _ => fail("expected Keypoint")
  }
  assert_eq(binds[0].id, "b-1")
  assert_eq(binds[0].from, "ann-1")
  assert_eq(binds[0].to, "ann-2")
}

///|
/// Phase 5.16 — serialize_label_text translates class_id back
/// to the class *name* in the JSON `type` field. The
/// round-trip then parses the name → class_id via the same
/// classes table.
test "serialize_label_text — round-trips class_id via class name (5.16)" {
  let classes : Array[ClassEntry] = [
    { id: "cls-car", name: "car", is_default: true, },
    { id: "cls-person", name: "person", is_default: false, },
  ]
  let initial : Model = {
    ..Model::new(),
    imageSource: "test.jpg",
    classes,
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
        class_id: "cls-car",
      },
    ],
  }
  let text : String = serialize_label_text(initial)
  // Re-parse using the same classes table — class_id should
  // round-trip through the name field.
  let (anns, _) = parse_label_text(text, classes)
  assert_eq(anns.length(), 1)
  assert_eq(anns[0].class_id, "cls-car")
}

///|
/// Phase 5.16 — serialize_label_text emits img_name as the
/// basename of imageSource (the JSON field is a filename, not
/// a full path).
test "serialize_label_text — img_name is basename of imageSource (5.16)" {
  let initial : Model = {
    ..Model::new(),
    imageSource: "D:\\datasets\\test\\image1.jpg",
    annotations: [],
  }
  let text : String = serialize_label_text(initial)
  // The img_name field is in the JSON; parse it back to
  // verify it equals the basename.
  let raw : Json = @json.parse(text)
  let img_name : String = match raw {
    Object(m) =>
      match m.get("img_name") {
        Some(String(s)) => s
        _ => fail("expected img_name")
      }
    _ => fail("expected object")
  }
  assert_eq(img_name, "image1.jpg")
}

///|
/// Phase 5.16 — SaveLabelText(text) stores the text in
/// model.label.raw_json and clears model.label.dirty. The
/// caller produces the text via serialize_label_text (or
/// equivalent) — this Msg only handles the storage side.
test "SaveLabelText — stores raw_json + clears dirty (5.16)" {
  let initial : Model = {
    ..Model::new(),
    label: { raw_json: "old", dirty: true, },
  }
  let (next, _) = update(initial, SaveLabelText("new serialised text"))
  assert_eq(next.label.raw_json, "new serialised text")
  assert_true(!next.label.dirty)
}

///|
/// Phase 5.16 — SaveCurrentLabel is the convenience wrapper:
/// serialize the current model state and store it in
/// model.label.raw_json. Verifies the round-trip dataflow
/// end-to-end (model → JSON → model via re-parse).
test "SaveCurrentLabel — serialises model into model.label (5.16)" {
  let initial : Model = {
    ..Model::new(),
    imageSource: "x.jpg",
    classes: [{ id: "cls-car", name: "car", is_default: true, }],
    annotations: [
      {
        id: "ann-1",
        shape: Rect,
        points: [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 50.0, }],
        class_id: "cls-car",
      },
    ],
    label: { raw_json: "", dirty: true, },
  }
  let (next, _) = update(initial, SaveCurrentLabel)
  assert_true(!next.label.dirty)
  // The stored JSON must round-trip back through parse_label_text
  // to the same annotations + class_id (the canonical
  // identity check).
  let (anns, _) = parse_label_text(next.label.raw_json, next.classes)
  assert_eq(anns.length(), 1)
  assert_eq(anns[0].id, "ann-1")
  assert_eq(anns[0].class_id, "cls-car")
}
