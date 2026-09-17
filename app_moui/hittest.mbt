// app_moui/hittest.mbt — pure hit-testing helpers for the annotation
// canvas.
//
// File is named `hittest.mbt` (no underscore between hit and test)
// because MoonBit treats files matching the `*_test.mbt` pattern as
// blackbox-only tests; their public symbols are not exported to the
// rest of the package. The original `hit_test.mbt` name silently
// tripped this filter, leaving handle_points / hit_test_select
// unbound when called from canvas_view.mbt and app.mbt. Renamed
// to hittest.mbt in phase 5.3 to fix.
//
// Phase 5.3: 8 px (12 px enlarged, per frontend canvas.js v0.2.9)
// handle hit-testing for rect / polygon / keypoint annotations, plus
// 4 px body hit-testing for selection.
//
// All distances are in image-natural pixel space (not screen px). The
// canvas View does the pan/zoom inversion before calling these
// helpers, so callers pass the image-natural cursor position directly.

///|
/// Compute the world-space handle positions for a single annotation.
/// Rect → 4 corners + 4 edge-midpoints (8 handles). Polygon → N
/// vertex handles (one per point). Keypoint → 1 handle at the
/// single point. Returns an empty array if the annotation has too
/// few points.
pub fn handle_points(ann : Annotation) -> Array[Point] {
  match ann.shape {
    Rect =>
      // Need exactly 2 points: top-left and bottom-right of the bbox.
      if ann.points.length() < 2 {
        []
      } else {
        let p1 = ann.points[0]
        let p2 = ann.points[1]
        // Half-extents for the edge midpoints.
        let mx = (p1.x + p2.x) / 2.0
        let my = (p1.y + p2.y) / 2.0
        [
          { x: p1.x, y: p1.y, }, // 0 TL
          { x: mx, y: p1.y, }, // 1 T
          { x: p2.x, y: p1.y, }, // 2 TR
          { x: p2.x, y: my, }, // 3 R
          { x: p2.x, y: p2.y, }, // 4 BR
          { x: mx, y: p2.y, }, // 5 B
          { x: p1.x, y: p2.y, }, // 6 BL
          { x: p1.x, y: my, }, // 7 L
        ]
      }
    // One handle per vertex — copy the points array.
    Polygon => {
      let acc : Array[Point] = []
      for p in ann.points {
        acc.push({ x: p.x, y: p.y, })
      }
      acc
    }
    Keypoint =>
      // Single handle at the only point.
      if ann.points.length() < 1 {
        []
      } else {
        [{ x: ann.points[0].x, y: ann.points[0].y, }]
      }
  }
}

///|
/// Hit-test all handles of the selected annotation. Returns
/// (ann_id, handle_idx) for the first handle within `radius` px of
/// `img_pt`. Returns None when no handle is within range.
pub fn hit_test_handle(
  img_pt : Point,
  annotations : Array[Annotation],
  selected_id : String,
  radius : Double,
) -> (String, Int)? {
  for ann in annotations {
    if ann.id == selected_id {
      let hs = handle_points(ann)
      for i = 0; i < hs.length(); i = i + 1 {
        if distance(img_pt, hs[i]) <= radius {
          return Some((ann.id, i))
        }
      }
      return None
    }
  }
  None
}

///|
/// Hit-test annotation bodies (not handles). Returns the id of the
/// topmost annotation that contains `img_pt` within `radius` px of
/// any of its points (polygons are checked vertex-by-vertex; rects
/// also include the interior). Iterates in reverse order so the
/// last-drawn annotation wins (matches HTML canvas z-order).
pub fn hit_test_body(
  img_pt : Point,
  annotations : Array[Annotation],
  radius : Double,
) -> String? {
  let n = annotations.length()
  let mut i = n - 1
  while i >= 0 {
    let ann = annotations[i]
    let mut hit = false
    match ann.shape {
      Rect =>
        if ann.points.length() >= 2 {
          let p1 = ann.points[0]
          let p2 = ann.points[1]
          // Interior hit: img_pt inside the bbox + 0.5 px margin.
          let xmin = if p1.x < p2.x { p1.x } else { p2.x }
          let xmax = if p1.x > p2.x { p1.x } else { p2.x }
          let ymin = if p1.y < p2.y { p1.y } else { p2.y }
          let ymax = if p1.y > p2.y { p1.y } else { p2.y }
          if img_pt.x >= xmin &&
            img_pt.x <= xmax &&
            img_pt.y >= ymin &&
            img_pt.y <= ymax {
            hit = true
          }
        }
      _ =>
        // Polygon / keypoint: any point within radius.
        for p in ann.points {
          if distance(img_pt, p) <= radius {
            hit = true
          }
        }
    }
    if hit {
      return Some(ann.id)
    }
    if i == 0 {
      break
    }
    i = i - 1
  }
  None
}

///|
/// Combined hit-test for CursorMoved: prefer handles of the selected
/// annotation (keep selection), fall back to body hit for selection.
/// Returns the new selectedId (Some unchanged or new, None cleared).
pub fn hit_test_select(
  img_pt : Point,
  annotations : Array[Annotation],
  current_sel : String?,
) -> String? {
  match current_sel {
    Some(sel_id) =>
      match hit_test_handle(img_pt, annotations, sel_id, 12.0) {
        Some(_) => Some(sel_id)
        None => hit_test_body(img_pt, annotations, 4.0)
      }
    None => hit_test_body(img_pt, annotations, 4.0)
  }
}

///|
/// Euclidean distance between two points.
fn distance(a : Point, b : Point) -> Double {
  let dx = a.x - b.x
  let dy = a.y - b.y
  sqrt_double(dx * dx + dy * dy)
}

///|
/// Square root via Newton's method. Enough precision for hit-test
/// (we only compare with `radius` which is 4–12 px; <1e-3 is fine).
fn sqrt_double(x : Double) -> Double {
  if x <= 0.0 {
    return 0.0
  }
  let mut guess = x / 2.0
  if guess < 1.0 {
    guess = 1.0
  }
  // 8 iterations → convergence to <1e-6 for any reasonable double.
  for _i = 0; _i < 8; _i = _i + 1 {
    guess = (guess + x / guess) / 2.0
  }
  guess
}

///|
/// Apply a handle move to an annotation. Returns the new annotation
/// when the handle matches the shape's handle layout, None otherwise
/// (caller preserves the original). Rect: 8 handles (4 corners +
/// 4 midpoints). Polygon: per-vertex. Keypoint: single handle.
pub fn apply_handle_move(
  ann : Annotation,
  handle_idx : Int,
  new_pt : Point,
) -> Annotation? {
  match ann.shape {
    Rect =>
      if ann.points.length() < 2 {
        None
      } else {
        let p1 = ann.points[0]
        let p2 = ann.points[1]
        // Mirror of handle_points order: 0 TL, 1 T, 2 TR, 3 R, 4 BR,
        // 5 B, 6 BL, 7 L.
        let new_p1 = match handle_idx {
          0 => new_pt
          1 => { x: new_pt.x, y: p1.y, }
          2 => { x: new_pt.x, y: p1.y, }
          3 => { x: p2.x, y: new_pt.y, }
          4 => new_pt
          5 => { x: new_pt.x, y: p2.y, }
          6 => { x: new_pt.x, y: p2.y, }
          7 => { x: p1.x, y: new_pt.y, }
          _ => { x: p1.x, y: p1.y, }
        }
        let new_p2 = match handle_idx {
          0 => { x: p2.x, y: p2.y, }
          1 => { x: p2.x, y: new_pt.y, }
          2 => new_pt
          3 => new_pt
          4 => new_pt
          5 => { x: p2.x, y: new_pt.y, }
          6 => { x: p1.x, y: p2.y, }
          7 => { x: p1.x, y: new_pt.y, }
          _ => { x: p2.x, y: p2.y, }
        }
        let new_points : Array[Point] = [new_p1, new_p2]
        Some({ ..ann, points: new_points, })
      }
    Polygon =>
      if handle_idx < 0 || handle_idx >= ann.points.length() {
        None
      } else {
        let new_points : Array[Point] = []
        for i = 0; i < ann.points.length(); i = i + 1 {
          if i == handle_idx {
            new_points.push({ x: new_pt.x, y: new_pt.y, })
          } else {
            new_points.push({ x: ann.points[i].x, y: ann.points[i].y, })
          }
        }
        Some({ ..ann, points: new_points, })
      }
    Keypoint =>
      if handle_idx == 0 && ann.points.length() >= 1 {
        Some({ ..ann, points: [{ x: new_pt.x, y: new_pt.y, }], })
      } else {
        None
      }
  }
}
