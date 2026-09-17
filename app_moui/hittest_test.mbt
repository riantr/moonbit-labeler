// app_moui/hittest_test.mbt — blackbox tests for the hit-test helpers.

///|
test "handle_points — rect returns 4 corners + 4 midpoints" {
  let ann : Annotation = {
    id: "r",
    shape: Rect,
    points: [{ x: 10.0, y: 20.0, }, { x: 110.0, y: 120.0, }],
  }
  let hs = handle_points(ann)
  assert_eq(hs.length(), 8)
  // TL
  assert_eq(hs[0].x, 10.0)
  assert_eq(hs[0].y, 20.0)
  // TR
  assert_eq(hs[2].x, 110.0)
  assert_eq(hs[2].y, 20.0)
  // BR
  assert_eq(hs[4].x, 110.0)
  assert_eq(hs[4].y, 120.0)
  // BL
  assert_eq(hs[6].x, 10.0)
  assert_eq(hs[6].y, 120.0)
  // T (top midpoint)
  assert_eq(hs[1].x, 60.0)
  assert_eq(hs[1].y, 20.0)
  // L (left midpoint)
  assert_eq(hs[7].x, 10.0)
  assert_eq(hs[7].y, 70.0)
}

///|
test "handle_points — keypoint returns 1 handle at the only point" {
  let ann : Annotation = {
    id: "k",
    shape: Keypoint,
    points: [{ x: 50.0, y: 60.0, }],
  }
  let hs = handle_points(ann)
  assert_eq(hs.length(), 1)
  assert_eq(hs[0].x, 50.0)
  assert_eq(hs[0].y, 60.0)
}

///|
test "hit_test_handle — finds handle at TL of selected rect" {
  let ann : Annotation = {
    id: "r",
    shape: Rect,
    points: [{ x: 10.0, y: 20.0, }, { x: 110.0, y: 120.0, }],
  }
  // Cursor on TL (within 12 px)
  let hit = hit_test_handle({ x: 11.0, y: 19.0, }, [ann], "r", 12.0)
  assert_eq(hit, Some(("r", 0)))
  // Cursor on TR
  let hit2 = hit_test_handle({ x: 109.0, y: 21.0, }, [ann], "r", 12.0)
  assert_eq(hit2, Some(("r", 2)))
  // Cursor far away — None
  let miss = hit_test_handle({ x: 500.0, y: 500.0, }, [ann], "r", 12.0)
  assert_eq(miss, None)
}

///|
test "hit_test_body — selects rect whose bbox contains the cursor" {
  let r : Annotation = {
    id: "r",
    shape: Rect,
    points: [{ x: 10.0, y: 20.0, }, { x: 110.0, y: 120.0, }],
  }
  let k : Annotation = {
    id: "k",
    shape: Keypoint,
    points: [{ x: 500.0, y: 500.0, }],
  }
  // Cursor inside rect → returns "r"
  let hit = hit_test_body({ x: 50.0, y: 50.0, }, [r, k], 4.0)
  assert_eq(hit, Some("r"))
  // Cursor on keypoint → returns "k"
  let hit2 = hit_test_body({ x: 500.0, y: 500.0, }, [r, k], 4.0)
  assert_eq(hit2, Some("k"))
  // Cursor far away → None
  let miss = hit_test_body({ x: 1000.0, y: 1000.0, }, [r, k], 4.0)
  assert_eq(miss, None)
}

///|
test "hit_test_select — prefers handle over body when selected" {
  let r : Annotation = {
    id: "r",
    shape: Rect,
    points: [{ x: 10.0, y: 20.0, }, { x: 110.0, y: 120.0, }],
  }
  // Cursor on TL handle — selection stays as "r"
  let sel = hit_test_select({ x: 11.0, y: 19.0, }, [r], Some("r"))
  assert_eq(sel, Some("r"))
  // Cursor inside the rect but not on a handle — still stays as "r"
  let sel2 = hit_test_select({ x: 50.0, y: 50.0, }, [r], Some("r"))
  assert_eq(sel2, Some("r"))
  // No selection + cursor in rect — selects "r"
  let sel3 = hit_test_select({ x: 50.0, y: 50.0, }, [r], None)
  assert_eq(sel3, Some("r"))
}

///|
test "apply_handle_move — rect TL corner drag moves p1 to new_pt" {
  let ann : Annotation = {
    id: "r",
    shape: Rect,
    points: [{ x: 10.0, y: 20.0, }, { x: 110.0, y: 120.0, }],
  }
  let moved = apply_handle_move(ann, 0, { x: 5.0, y: 15.0, })
  match moved {
    Some(new_ann) => {
      assert_eq(new_ann.points[0].x, 5.0)
      assert_eq(new_ann.points[0].y, 15.0)
      // p2 stays put
      assert_eq(new_ann.points[1].x, 110.0)
      assert_eq(new_ann.points[1].y, 120.0)
    }
    None => fail("expected Some for handle_idx=0")
  }
}

///|
test "apply_handle_move — polygon vertex drag" {
  let ann : Annotation = {
    id: "p",
    shape: Polygon,
    points: [{ x: 0.0, y: 0.0, }, { x: 10.0, y: 0.0, }, { x: 10.0, y: 10.0, }],
  }
  let moved = apply_handle_move(ann, 2, { x: 50.0, y: 50.0, })
  match moved {
    Some(new_ann) => {
      assert_eq(new_ann.points[2].x, 50.0)
      assert_eq(new_ann.points[2].y, 50.0)
      // other vertices unchanged
      assert_eq(new_ann.points[0].x, 0.0)
      assert_eq(new_ann.points[1].x, 10.0)
    }
    None => fail("expected Some for vertex handle")
  }
}
