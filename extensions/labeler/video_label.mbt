///|
/// Per-frame annotation sets for video labels.
///
/// A video label document holds an ordered list of *sets*. Each set is
/// one annotation set plus the list of frames it applies to:
///
/// ```json
/// {
///   "img_name": "clip_001.mp4",
///   "infos": [], "bindings": [], "frames": [],
///   "frame_labels": [
///     { "frames": [12], "infos": [ ... ], "bindings": [ ... ] },
///     { "frames": [24, 25], "infos": [ ... ], "bindings": [ ... ] }
///   ]
/// }
/// ```
///
/// The document's top-level `infos` / `bindings` / `frames` form the
/// *default* set — the first entry of the list. A default set with an
/// empty `frames` array applies to every frame; one with a non-empty
/// `frames` array applies only to those frames. That is what keeps files
/// written by the earlier flat-schema implementation readable: their
/// single flat set becomes the default set and behaves as it did.
///
/// Everything after the default set is a per-frame set, and a frame
/// belongs to at most one per-frame set. That is the point of this
/// module: the previous implementation merged every frame's objects into
/// one flat union before writing, so a box drawn on frame 5 silently
/// reappeared on frame 9 and the two frames could never differ.

///|
/// One annotation set plus the frames it applies to.
struct FrameSet {
  frames : Array[Int32]
  infos : Array[Json]
  bindings : Array[Json]
}

///|
/// Split a normalized label document into its annotation sets. The first
/// element is always the document's default (top-level) set, so the
/// list is never empty.
fn parse_frame_sets(doc : Json) -> Array[FrameSet] {
  let members : Map[String, Json] = match doc {
    Object(m) => m
    _ => Map([])
  }
  let empty : Array[Json] = []
  let default_infos : Array[Json] = match members.get("infos") {
    Some(Array(a)) => a
    _ => empty
  }
  let default_bindings : Array[Json] = match members.get("bindings") {
    Some(Array(a)) => a
    _ => empty
  }
  let default_frames : Array[Int32] = match members.get("frames") {
    Some(Array(a)) => normalize_frame_list(a)
    _ => []
  }
  let sets : Array[FrameSet] = [
    {
      frames: default_frames,
      infos: default_infos,
      bindings: default_bindings,
    },
  ]
  let raw_sets : Array[Json] = match members.get("frame_labels") {
    Some(Array(a)) => a
    _ => empty
  }
  for entry in raw_sets {
    let obj : Map[String, Json] = match entry {
      Object(o) => o
      _ => continue
    }
    let frames : Array[Int32] = match obj.get("frames") {
      Some(Array(a)) => normalize_frame_list(a)
      _ => []
    }
    let infos : Array[Json] = match obj.get("infos") {
      Some(Array(a)) => a
      _ => empty
    }
    let bindings : Array[Json] = match obj.get("bindings") {
      Some(Array(a)) => a
      _ => empty
    }
    sets.push({ frames, infos, bindings, })
  }
  sets
}

///|
/// The annotation set that applies to `frame`, or an empty set when the
/// frame carries no annotations.
fn project_frame_set(sets : Array[FrameSet], frame : Int32) -> FrameSet {
  // A per-frame set is the most specific match, so it wins over the
  // default set.
  for i in 1..<sets.length() {
    let s = sets[i]
    if s.frames.contains(frame) {
      return s
    }
  }
  // Otherwise fall back to the default set: an empty `frames` list means
  // "applies to every frame", a non-empty one means "applies to these".
  let default = sets[0]
  if default.frames.length() == 0 || default.frames.contains(frame) {
    return default
  }
  { frames: [frame], infos: [], bindings: [], }
}

///|
/// Every frame mentioned by any set, sorted ascending and de-duplicated.
///
/// The default set may list no frames at all, which means "applies to
/// every frame" — a set of frames that cannot be enumerated. Such a
/// document therefore reports no annotated frames here, even though it
/// does carry annotations.
fn annotated_frames(sets : Array[FrameSet]) -> Array[Int32] {
  let seen : Map[String, Bool] = Map([])
  let acc : Array[Int32] = []
  for s in sets {
    for f in s.frames {
      let key = f.to_string()
      if !seen.contains(key) {
        seen.set(key, true)
        acc.push(f)
      }
    }
  }
  acc.sort()
  acc
}

///|
/// The name a label document carries.
fn doc_img_name(doc : Json) -> String {
  match doc {
    Object(m) =>
      match m.get("img_name") {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
/// Replace the `img_name` of a label document.
fn doc_with_img_name(doc : Json, img_name : String) -> Json {
  match doc {
    Object(m) => {
      m.set("img_name", Json::string(img_name))
      Json::object(m)
    }
    _ => Json::object(Map::from_array([("img_name", Json::string(img_name))]))
  }
}

///|
/// The annotation set that applies to `frame`, as a label document.
///
/// This is the read side of the video label contract: give it the
/// document on disk and a frame number, and it answers with the set of
/// annotations that frame carries. Frames with no annotations get an
/// empty set rather than an error.
pub fn video_frame_label(doc : Json, frame : Int32) -> Json {
  let sets = parse_frame_sets(doc)
  let projected = project_frame_set(sets, frame)
  frame_set_to_label_json(projected, doc_img_name(doc), frame)
}

///|
/// Merge the annotation set in `label` into `doc` for `frame`, and
/// return the new document.
///
/// This is the write side of the contract: the frame's own set is
/// replaced, every other frame's set is left exactly as it was. The
/// incoming set is normalized on the way in, so a hand-written or
/// legacy-shaped payload cannot smuggle in a malformed entry.
pub fn merge_video_frame_label(doc : Json, frame : Int32, label : Json) -> Json {
  let sets = parse_frame_sets(doc)
  let incoming_members : Map[String, Json] = match label {
    Object(m) => m
    _ => Map([])
  }
  let raw_infos : Array[Json] = match incoming_members.get("infos") {
    Some(Array(a)) => a
    _ => []
  }
  let raw_bindings : Array[Json] = match incoming_members.get("bindings") {
    Some(Array(a)) => a
    _ => []
  }
  let (infos, ids) = normalize_info_entries(raw_infos)
  let bindings = normalize_binding_entries(raw_bindings, ids)
  let merged = merge_frame_set(sets, frame, infos, bindings)
  frame_sets_to_json(merged, doc_img_name(doc))
}

///|
/// Every frame the document annotates, sorted ascending.
///
/// The timeline uses this to mark the annotated frames.
pub fn video_annotated_frames(doc : Json) -> Array[Int32] {
  annotated_frames(parse_frame_sets(doc))
}

///|
/// Merge the annotation set for `frame` into `sets` and return the new
/// list. `infos` / `bindings` replace whatever the frame carried before;
/// every other frame is left untouched.
fn merge_frame_set(
  sets : Array[FrameSet],
  frame : Int32,
  infos : Array[Json],
  bindings : Array[Json],
) -> Array[FrameSet] {
  let out : Array[FrameSet] = []
  // A per-frame set that already covers this frame is updated in place,
  // so its `frames` list — and therefore the other frames it covers —
  // survives the edit.
  for i in 1..<sets.length() {
    if sets[i].frames.contains(frame) {
      for j in 0..<sets.length() {
        if j == i {
          out.push({ frames: sets[j].frames, infos, bindings, })
        } else {
          out.push(sets[j])
        }
      }
      return out
    }
  }
  let default = sets[0]
  let default_covers_frame = default.frames.contains(frame) ||
    (
      default.frames.length() == 0 &&
      (default.infos.length() > 0 || default.bindings.length() > 0)
    )
  for j in 0..<sets.length() {
    if j == 0 {
      if default_covers_frame {
        out.push({ frames: default.frames, infos, bindings, })
      } else {
        out.push(default)
      }
    } else {
      out.push(sets[j])
    }
  }
  // The frame had no set of its own, so it gets one.
  if !default_covers_frame {
    out.push({ frames: [frame], infos, bindings, })
  }
  out
}

///|
/// Render the annotation sets back into a label document.
fn frame_sets_to_json(sets : Array[FrameSet], img_name : String) -> Json {
  let default = sets[0]
  let members : Map[String, Json] = Map::from_array([
    ("img_name", Json::string(img_name)),
    ("infos", Json::array(default.infos)),
    ("bindings", Json::array(default.bindings)),
  ])
  if default.frames.length() > 0 {
    members.set("frames", Json::array(frames_to_json(default.frames)))
  }
  let per_frame : Array[Json] = []
  for i in 1..<sets.length() {
    let s = sets[i]
    per_frame.push(
      Json::object(
        Map::from_array([
          ("frames", Json::array(frames_to_json(s.frames))),
          ("infos", Json::array(s.infos)),
          ("bindings", Json::array(s.bindings)),
        ]),
      ),
    )
  }
  if per_frame.length() > 0 {
    members.set("frame_labels", Json::array(per_frame))
  }
  Json::object(members)
}

///|
/// Render one annotation set as a standalone label document scoped to
/// `frame`. This is what the frontend receives for the frame it is
/// showing.
fn frame_set_to_label_json(
  s : FrameSet,
  img_name : String,
  frame : Int32,
) -> Json {
  Json::object(
    Map::from_array([
      ("img_name", Json::string(img_name)),
      ("infos", Json::array(s.infos)),
      ("bindings", Json::array(s.bindings)),
      ("frames", Json::array(frames_to_json([frame]))),
    ]),
  )
}

///|
/// Request the annotation set that applies to one frame of a video.
#derive(FromJson, ToJson, Eq, Debug)
pub struct ReadVideoLabelRequest {
  /// Absolute path of the video file.
  path : String
  /// The frame number to project.
  frame : Int32
}

///|
/// The annotation set that applies to one frame of a video.
#derive(FromJson, ToJson, Eq, Debug)
pub struct ReadVideoLabelReply {
  path : String
  /// Where the label document lives on disk.
  label_path : String
  /// True when a label document exists for this video. `content` is
  /// populated either way, so the caller can render an unannotated
  /// frame without a special case.
  found : Bool
  /// The annotation set for `frame`, as normalized JSON text.
  content : String
  /// Every frame the document annotates, sorted ascending. The timeline
  /// uses this to mark the annotated frames.
  annotated_frames : Array[Int32]
  /// How many annotation sets the document holds in total — the default
  /// set plus the per-frame ones. Diagnostic only.
  set_count : Int32
}

///|
/// Request to write the annotation set for one frame of a video.
#derive(FromJson, ToJson, Eq, Debug)
pub struct WriteVideoLabelRequest {
  /// Absolute path of the video file.
  path : String
  /// The frame number the annotation set belongs to.
  frame : Int32
  /// The annotation set for `frame`, as JSON text.
  content : String
}

///|
/// The result of writing one frame's annotation set.
#derive(FromJson, ToJson, Eq, Debug)
pub struct WriteVideoLabelReply {
  path : String
  label_path : String
  /// Size of the written document in bytes.
  bytes : Int32
  /// How many annotation sets the document holds after the write.
  set_count : Int32
}

///|
/// Read the annotation set that applies to `frame` of the video at
/// `req.path`.
///
/// The document is located with the usual `Video@X/<name>.mp4` ->
/// `Label@X/<name>.json` convention. When it does not exist yet the
/// reply still carries an empty annotation set, so the frontend can
/// render an unannotated frame without a special case.
async fn op_read_video_label(
  req : ReadVideoLabelRequest,
) -> ReadVideoLabelReply {
  let label_path = video_path_to_label_path(req.path)
  let (_, basename) = split_dir_name(req.path)
  if !@fs.exists(label_path) {
    let empty_doc = doc_with_img_name(
      Json::object(
        Map::from_array([
          ("infos", Json::array([])),
          ("bindings", Json::array([])),
        ]),
      ),
      basename,
    )
    return {
      path: req.path,
      label_path,
      found: false,
      content: video_frame_label(empty_doc, req.frame).stringify(),
      annotated_frames: [],
      set_count: 0,
    }
  }
  let data = @fs.read_binary(label_path) catch {
    _ =>
      return {
        path: req.path,
        label_path,
        found: false,
        content: "",
        annotated_frames: [],
        set_count: 0,
      }
  }
  let text = @utf8.decode(data) catch {
    _ =>
      return {
        path: req.path,
        label_path,
        found: false,
        content: "",
        annotated_frames: [],
        set_count: 0,
      }
  }
  let (normalized, _) = parse_label_text(text, basename)
  let doc = doc_with_img_name(@json.parse(normalized), basename)
  {
    path: req.path,
    label_path,
    found: true,
    content: video_frame_label(doc, req.frame).stringify(),
    annotated_frames: video_annotated_frames(doc),
    set_count: parse_frame_sets(doc).length(),
  }
}

///|
/// Write the annotation set for one frame of the video at `req.path`.
///
/// The set is merged into the existing document: the frame's own set is
/// replaced, every other frame's set is left exactly as it was. That is
/// what keeps two frames of the same video independent.
async fn op_write_video_label(
  req : WriteVideoLabelRequest,
) -> WriteVideoLabelReply {
  let label_path = video_path_to_label_path(req.path)
  let (_, basename) = split_dir_name(req.path)
  // Read the existing document, if any.
  let existing_doc = if @fs.exists(label_path) {
    let data = @fs.read_binary(label_path) catch { _ => b"" }
    let text = @utf8.decode(data) catch { _ => "" }
    if text == "" {
      doc_with_img_name(
        Json::object(
          Map::from_array([
            ("infos", Json::array([])),
            ("bindings", Json::array([])),
          ]),
        ),
        basename,
      )
    } else {
      let (normalized, _) = parse_label_text(text, basename)
      doc_with_img_name(@json.parse(normalized), basename)
    }
  } else {
    doc_with_img_name(
      Json::object(
        Map::from_array([
          ("infos", Json::array([])),
          ("bindings", Json::array([])),
        ]),
      ),
      basename,
    )
  }
  // The incoming set is normalized by `merge_video_frame_label`, so a
  // hand-written or legacy-shaped payload cannot smuggle in a malformed
  // entry.
  let incoming_doc = @json.parse(req.content)
  let merged = merge_video_frame_label(existing_doc, req.frame, incoming_doc)
  let out_text = merged.stringify()
  let (label_dir, _) = split_dir_name(label_path)
  if label_dir != "" {
    ensure_dir(label_dir) catch {
      e =>
        fail(
          "write_video_label: cannot create label directory '" +
          label_dir +
          "': " +
          e.to_string(),
        )
    }
  }
  @fs.write_text(label_path, out_text, create_mode=@fs.CreateOrTruncate) catch {
    err => fail("write_video_label failed: " + err.to_string())
  }
  {
    path: req.path,
    label_path,
    bytes: out_text.length(),
    set_count: parse_frame_sets(merged).length(),
  }
}
