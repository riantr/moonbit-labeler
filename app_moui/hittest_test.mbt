// app_moui/hittest_test.mbt — blackbox tests for the hit-test helpers.

///|
test "handle_points — rect returns 4 corners + 4 midpoints" {
  let ann : Annotation = {
    id: "r",
    shape: Rect,
    points: [{ x: 10.0, y: 20.0, }, { x: 110.0, y: 120.0, }],
    class_id: "",
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
    class_id: "",
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
    class_id: "",
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
    class_id: "",
  }
  let k : Annotation = {
    id: "k",
    shape: Keypoint,
    points: [{ x: 500.0, y: 500.0, }],
    class_id: "",
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
    class_id: "",
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
    class_id: "",
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
    class_id: "",
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

///|
/// Phase 5.4 — pinning the corrected Rect BR corner move.
test "apply_handle_move — rect BR corner drag (handle 4) keeps TL fixed" {
  let ann : Annotation = {
    id: "r",
    shape: Rect,
    points: [{ x: 10.0, y: 20.0, }, { x: 110.0, y: 120.0, }],
    class_id: "",
  }
  let moved = apply_handle_move(ann, 4, { x: 200.0, y: 250.0 })
  match moved {
    Some(new_ann) => {
      // TL (p1) is unchanged.
      assert_eq(new_ann.points[0].x, 10.0)
      assert_eq(new_ann.points[0].y, 20.0)
      // BR (p2) becomes new_pt.
      assert_eq(new_ann.points[1].x, 200.0)
      assert_eq(new_ann.points[1].y, 250.0)
    }
    None => fail("expected Some for handle_idx=4")
  }
}

///|
/// Phase 5.4 — pinning the corrected Rect BL corner move
/// (handle 6). Pre-5.4 the BL move set both p1 and p2 from
/// new_pt (collapsed the rect). Now: TL.x = new_pt.x, BR.y =
/// new_pt.y; the other coords stay.
test "apply_handle_move — rect BL corner drag (handle 6) updates both axes" {
  let ann : Annotation = {
    id: "r",
    shape: Rect,
    points: [{ x: 10.0, y: 20.0, }, { x: 110.0, y: 120.0, }],
    class_id: "",
  }
  let moved = apply_handle_move(ann, 6, { x: 5.0, y: 130.0 })
  match moved {
    Some(new_ann) => {
      // TL (p1): x = new_pt.x, y unchanged.
      assert_eq(new_ann.points[0].x, 5.0)
      assert_eq(new_ann.points[0].y, 20.0)
      // BR (p2): x unchanged, y = new_pt.y.
      assert_eq(new_ann.points[1].x, 110.0)
      assert_eq(new_ann.points[1].y, 130.0)
    }
    None => fail("expected Some for handle_idx=6")
  }
}

///|
/// Phase 5.4 — pinning the corrected Rect T (top edge mid)
/// move (handle 1). Only TL.y moves; BR.y stays.
test "apply_handle_move — rect T edge-mid drag (handle 1) moves TL.y only" {
  let ann : Annotation = {
    id: "r",
    shape: Rect,
    points: [{ x: 10.0, y: 20.0, }, { x: 110.0, y: 120.0, }],
    class_id: "",
  }
  let moved = apply_handle_move(ann, 1, { x: 60.0, y: 5.0 })
  match moved {
    Some(new_ann) => {
      // TL.x unchanged, TL.y = new_pt.y.
      assert_eq(new_ann.points[0].x, 10.0)
      assert_eq(new_ann.points[0].y, 5.0)
      // BR unchanged.
      assert_eq(new_ann.points[1].x, 110.0)
      assert_eq(new_ann.points[1].y, 120.0)
    }
    None => fail("expected Some for handle_idx=1")
  }
}

///|
/// Phase 5.4 — pinning the corrected Rect L (left edge mid)
/// move (handle 7). Only TL.x moves; BR.x stays.
test "apply_handle_move — rect L edge-mid drag (handle 7) moves TL.x only" {
  let ann : Annotation = {
    id: "r",
    shape: Rect,
    points: [{ x: 10.0, y: 20.0, }, { x: 110.0, y: 120.0, }],
    class_id: "",
  }
  let moved = apply_handle_move(ann, 7, { x: 5.0, y: 70.0 })
  match moved {
    Some(new_ann) => {
      // TL.x = new_pt.x, TL.y unchanged.
      assert_eq(new_ann.points[0].x, 5.0)
      assert_eq(new_ann.points[0].y, 20.0)
      // BR unchanged.
      assert_eq(new_ann.points[1].x, 110.0)
      assert_eq(new_ann.points[1].y, 120.0)
    }
    None => fail("expected Some for handle_idx=7")
  }
}

///|
/// Phase 5.7 — pins the rect corner-order invariant. The Phase
/// 5.4-5.6 notes carried a worry that a rect written BR→TL would
/// have "inverted handle labels" because `handle_points`,
/// `apply_handle_move` and `draw_annotation` all read `points[0]` /
/// `points[1]` directly.
///
/// Testing it empirically shows that worry was **unfounded**, and the
/// reason is worth recording: the code is order-agnostic by
/// construction. `handle_points` derives all 8 handles from whatever
/// the two points are, and `apply_handle_move` moves the same point
/// the matching handle sits on. For a BR→TL rect the *indices*
/// rotate (index 0 lands on the visually bottom-right instead of
/// top-left), but the set of 8 handle positions is identical and each
/// drag still moves the corner the user grabbed. No handle is
/// visually distinguishable from its neighbours, so the index
/// rotation is invisible.
///
/// This test locks that in, so a future refactor that starts
/// assuming `p1 = TL` in a *new* place gets caught.
test "rect corner order — BR-first rect keeps all 8 handles and drags the grabbed corner (5.7)" {
  // BR→TL: points[0] is the bottom-right, points[1] the top-left.
  let ann : Annotation = {
    id: "flipped",
    shape: Rect,
    points: [{ x: 110.0, y: 120.0, }, { x: 10.0, y: 20.0, }],
    class_id: "",
  }
  let hs : Array[Point] = handle_points(ann)
  assert_eq(hs.length(), 8)
  // The 8 handles must be the 4 corners + 4 edge midpoints of the
  // axis-aligned box spanning (10,20)..(110,120) — identical as a
  // SET to the TL-first rect's handles, just at different indices.
  let upright : Annotation = {
    id: "flipped",
    shape: Rect,
    points: [{ x: 10.0, y: 20.0, }, { x: 110.0, y: 120.0, }],
    class_id: "",
  }
  let uh : Array[Point] = handle_points(upright)
  // Every handle position from the flipped rect must exist
  // somewhere in the upright rect's handle list.
  for h in hs {
    let mut found = false
    for u in uh {
      if u.x == h.x && u.y == h.y {
        found = true
      }
    }
    assert_true(found)
  }
  // Index 0 is the visually-bottom-right for the flipped rect. This
  // is the "inverted label" — invisible to the user, but documented
  // so nobody later 'fixes' it by reordering the handles.
  assert_eq(hs[0].x, 110.0)
  assert_eq(hs[0].y, 120.0)
  // Dragging handle 0 must move the corner it actually sits on:
  // points[0], the visually bottom-right one.
  let moved = apply_handle_move(ann, 0, { x: 150.0, y: 160.0 })
  match moved {
    Some(m) => {
      assert_eq(m.points[0].x, 150.0)
      assert_eq(m.points[0].y, 160.0)
      // The other corner is untouched.
      assert_eq(m.points[1].x, 10.0)
      assert_eq(m.points[1].y, 20.0)
    }
    None => fail("expected Some for handle_idx=0")
  }
}

///|
/// Phase 5.7 — same invariant for hit-testing: a BR→TL rect is
/// still hit-testable by its body, because `hit_test_body` already
/// normalises with min/max rather than assuming corner order.
test "rect corner order — BR-first rect is still hit-testable by body (5.7)" {
  let ann : Annotation = {
    id: "flipped",
    shape: Rect,
    points: [{ x: 110.0, y: 120.0, }, { x: 10.0, y: 20.0, }],
    class_id: "",
  }
  // Interior point.
  assert_eq(hit_test_body({ x: 60.0, y: 70.0 }, [ann], 4.0), Some("flipped"))
  // Well outside.
  assert_true(hit_test_body({ x: 200.0, y: 200.0 }, [ann], 4.0) is None)
}

///|
/// Phase 5.7 — the hoisted hit-radius constants. Pin the values so a
/// future change to either radius is a deliberate, visible edit
/// rather than a silent drift between call sites.
test "hit radii constants — 12 px handle / 4 px body (5.7)" {
  assert_eq(handle_hit_radius, 12.0)
  assert_eq(body_hit_radius, 4.0)
}
