// riantr/moonbit_labeler/app_moui — MoUI app skeleton.
//
// Phase 2 (this session): Model + Msg + Update + view shell, modelled
// on the existing frontend state machine (frontend/src/main.js lines
// 60-100). The 21 IPC ops stay in extensions/labeler/ and get called
// as direct MoonBit async functions from update() — see
// _build/design/moui-migration-design.md §6 for the IPC removal plan.
//
// Pattern reference: wzzc-dev/MoUI/docs/app-templates.md §Counter
// (program() factory + Model::new() + Msg enum + pure update).

// ─────────────────────────────────────────────────────────────────
// State — exact mirror of frontend/src/main.js §state (lines 60-100)
// ─────────────────────────────────────────────────────────────────

///|
pub(all) enum MediaKind {
  Image
  Video
} derive(Debug, Eq)

///|
pub(all) enum Mode {
  Select
  Rect
  Polygon
  Keypoint
  EditBinding
} derive(Debug, Eq)

///|
/// Phase 5.9 — canonical display caption for each drawing tool.
/// Single source of truth shared by the toolbar button label and the
/// status-bar line emitted by `SetMode`, so the two can never drift
/// apart. `EditBinding` renders as "Binding" because that is what
/// the primitive is called everywhere else in the UI and on disk
/// (the label file's `bindings` array).
pub fn mode_label(mode : Mode) -> String {
  match mode {
    Select => "Select"
    Rect => "Rect"
    Polygon => "Polygon"
    Keypoint => "Keypoint"
    EditBinding => "Binding"
  }
}

///|
/// Phase 5.16 — the one rule for "which tool is armed after the user
/// finishes creating a shape".
///
/// It takes the **shape that was created**, not the mode the user
/// happened to be in. Those coincide today, but the shape is the
/// actual fact: if a future input path ever dispatches `AddRect`
/// while the mode says `Keypoint`, the correct answer is still
/// `Select`, not "whatever the mode was".
///
/// **The rule.** Keypoint stays armed; everything else returns to
/// `Select`.
///
/// **Why Keypoint is the exception.** It is a one-click tool, and
/// labelling a scan means dropping a point on every defect — dozens
/// of them. Requiring a toolbar click between consecutive points is
/// the difference between tagging a scan in a minute and not
/// finishing. The legacy frontend's keypoint tool behaves this way,
/// and that is the reference this port is tracking.
///
/// **Why Rect and Polygon do not stay armed** — and this is the part
/// Phase 5.9 flagged as deserving a deliberate decision. It is
/// genuinely annoying: drawing N rectangles costs N toolbar clicks,
/// because each `AddRect` returns to `Select`. The counter-argument
/// is that the same drop-out is what the legacy frontend does for
/// both tools, and this is a port of it: keeping the tool armed would
/// be a deliberate divergence from the reference, not a fix. So the
/// behaviour is **unchanged** and the point of this phase is to make
/// it single-sourced, explicit and tested rather than to change it.
/// If the decision is ever revisited, this function is the one place
/// it has to change, and `mode_after_commit` is covered by tests for
/// all three shapes.
///
/// Note the asymmetry with the *cancel* paths (`FinishDraft`,
/// `CancelDraft`, and `AddBinding`), which always go to `Select`
/// **including from Keypoint**: cancelling is "stop what you were
/// doing", not "finish what you were doing", so it must not leave a
/// tool armed. Those handlers therefore do not call this function —
/// see the comment on `CancelDraft`.
pub fn mode_after_commit(created : Shape) -> Mode {
  match created {
    Keypoint => Keypoint
    Rect => Select
    Polygon => Select
  }
}

///|
pub(all) enum ClassType {
  Object
  Tag
  Binding
} derive(Debug, Eq)

///|
pub(all) enum ToastKind {
  Info
  Warn
  Error
} derive(Debug, Eq)

///|
pub(all) enum Layer {
  Static
  Dynamic
} derive(Debug)

///|
pub(all) enum OpResult {
  Ok(String, String) // op name, result json (raw text)
  Err(String, String) // op name, error message
} derive(Debug)

///|
pub(all) struct Point {
  x : Double
  y : Double
} derive(Debug)

///|
pub(all) enum Shape {
  Rect
  Polygon
  Keypoint
} derive(Debug, Eq)

///|
pub(all) struct Annotation {
  id : String
  shape : Shape
  points : Array[Point]
  // Phase 5.14 — reference into model.classes for label-text
  // rendering. Empty string ("") means "no class assigned";
  // the canvas falls back to `id` for the label text in that
  // case. Populated by the IPC layer (op_set_annotations
  // parses `type` from the JSON label file into class_id once
  // the IPC bridge lands; until then, callers can set it
  // directly in tests). classType is intentionally NOT
  // duplicated here — we look it up from classes when needed.
  class_id : String
} derive(Debug)

///|
pub(all) struct Binding {
  id : String
  from : String
  to : String
} derive(Debug)

///|
/// Phase 5.10 — image decode metadata. We deliberately don't
/// store the raw decoded pixel buffer here — that's a multi-MB
/// allocation per loaded image, and the Model struct gets
/// diff'd + cloned on every update by the runtime. Instead
/// the metadata is exposed via this struct, and the pixel
/// bytes live in a side table (5.10.x+ work).
pub(all) struct ImageDecodedMeta {
  width : Int
  height : Int
  byte_length : Int
  pixel_format : String
} derive(Debug)

///|
/// Active drag state — when Some, the next CursorMoved should
/// move the (id, handle_idx) handle instead of selecting a new
/// annotation. Begun by BeginDragHandle, ended by EndDragHandle.
pub(all) struct DragState {
  ann_id : String
  handle_idx : Int
  start_img_pt : Point
} derive(Debug)

///|
pub(all) struct ImageEntry {
  name : String
  path : String
  size_bytes : Int
} derive(Debug)

///|
pub(all) struct VideoEntry {
  name : String
  path : String
  frame_count : Int
} derive(Debug)

///|
pub(all) struct ClassEntry {
  id : String
  name : String
  is_default : Bool
} derive(Debug)

///|
pub(all) struct Label {
  raw_json : String
  dirty : Bool
} derive(Debug)

///|
pub(all) struct Model {
  folder : String
  labelFolder : String
  images : Array[ImageEntry]
  videos : Array[VideoEntry]
  currentIndex : Int
  mediaKind : MediaKind
  label : Label
  labelPath : String
  loadedFromDisk : Bool
  mode : Mode
  classType : ClassType
  selectedId : String?
  // Phase 5.17 — which class new annotations get. `""` means "not
  // chosen", in which case `default_class_id` falls back to the first
  // class flagged `is_default`. Kept as a plain id rather than
  // reusing `ClassEntry::is_default` so the sidebar's *demo* class
  // set (plain strings, no ClassEntry behind them) can drive it too.
  activeClassId : String
  // Phase 5.21 — the rename-in-progress session. `editingClassId` is
  // the class being renamed and `renameBuffer` is the text field's
  // controlled value. `""` means "not renaming", and that mode flag is
  // what makes a rename *abandonable*: without somewhere for a
  // half-typed name to live, `CancelRename` has nothing to undo.
  editingClassId : String
  renameBuffer : String
  draftPoints : Array[Point]
  bindingFromId : String?
  classes : Array[ClassEntry]
  // Phase 5.2 — image source. imageSource = "" means no image loaded
  // (placeholder rect shown instead). When non-empty, the renderer
  // fetches/decodes the file lazily at first paint.
  imageSource : String
  imageNaturalSize : Point
  // Phase 5.10 — image decode metadata. Populated by the
  // `ImageDecoded` Msg after `LoadImage` reads + decodes the
  // file. None while no image is loaded; Some(_) once the
  // decode succeeds. Storing only the metadata fields
  // (width, height, byte length, pixel format name) avoids
  // bloating the Model struct with multi-MB raw pixel data.
  // Future 5.10.x+ work moves the decoded pixel bytes into
  // a side table keyed by imageSource so the renderer can
  // blit them in phase 10 (the MoUI DrawImage primitive
  // currently only takes a file-path source, not raw bytes).
  imageDecoded : ImageDecodedMeta?
  // Phase 5.12 — the viewport the view tree is sized against.
  // Phase 5.13 — this was previously a hardcoded `1280.0, 800.0`
  // passed straight into `build_labeler_ui_view`, which had been
  // wrong since Phase 18.B (the launcher opens 1920x1080, and after
  // the host reports its real surface the runtime re-lays-out to
  // 947x504 on this machine). It is on the Model because
  // `main_native.mbt` is the only place that knows the window size
  // it asked for, and the view has no other way to learn the real
  // one: MoUI 0.1.12 has no resize callback, and
  // `ViewNode::child_constraints` defaults to `constraints.loosen()`
  // so a pass-through layout hands its children the unbounded 1e9
  // max rather than the parent's resolved size.
  viewport : @core.Size
  fitMode : @core.ImageFit
  // Phase 5.3 — annotations + bindings + active handle drag.
  annotations : Array[Annotation]
  bindings : Array[Binding]
  dragState : DragState?
  // Phase 5.19 — when true, on_drag dispatches ZoomBy (vertical
  // drag = zoom) instead of Pan (default drag-to-pan). Toggled
  // by the on_secondary_tap modifier; the boolean is the only
  // state we carry since Moui 0.1.12 has no on_wheel modifier
  // and no separate right-button-drag modifier.
  zoomDragMode : Bool
  cursorImgPt : Point?
  cursorCanvasPt : Point?
  zoom : Double
  pan : Point
  staticLayerDirty : Bool
  dynamicLayerDirty : Bool
  toastMessage : String?
  toastKind : ToastKind
  statusMessage : String
} derive(Debug)

///|
pub fn Model::new() -> Model {
  {
    folder: "",
    labelFolder: "",
    images: [],
    videos: [],
    currentIndex: -1,
    mediaKind: Image,
    label: { raw_json: "{}", dirty: false, },
    labelPath: "",
    loadedFromDisk: false,
    mode: Select,
    classType: Object,
    selectedId: None,
    // Phase 5.17 — no class chosen yet; `default_class_id` falls back
    // to the first `is_default` class until the user picks one.
    activeClassId: "",
    editingClassId: "",
    renameBuffer: "",
    draftPoints: [],
    bindingFromId: None,
    classes: default_demo_classes(),
    // Phase 5.13 — default viewport. `main_native.mbt` overwrites
    // this on the cold-start model with the size it asks the
    // runtime for, so the view and the window cannot disagree. The
    // value here is only what a headless `Model::new()` caller
    // gets; it matches the 947x504 logical surface this host
    // actually produces (1894x1009 physical at scale_factor 2).
    viewport: @core.Size::new(width=947.0, height=504.0),
    // Phase 5.3 — default annotation set + binding. The smoke
    // screenshot demonstrates the full annotation rendering
    // pipeline (image + annotation bodies + binding arrows +
    // label text) without requiring a real .json label file
    // to be read at startup. The synthetic
    // annotations cover all 3 shapes (Rect, Polygon, Keypoint)
    // + 1 binding between the Rect and Keypoint so the binding
    // arrow + dashed-centroid-line render is exercised too.
    // Annotation IDs match the binding `from` / `to` references.
    annotations: default_demo_annotations(),
    bindings: default_demo_bindings(),
    // Phase 5.2 — default imageSource points to the
    // synthetic test image that `main_native.mbt`
    // pre-populates into the renderer's module-local
    // ImageCache via `register_test_image_in_renderer`
    // (source key `_phase5_2_synthetic`, 200×200 RGBA8 with
    // 4-quadrant pattern + 8 px border). Setting a non-empty
    // default lets the smoke screenshot demonstrate the full
    // `imageSource → DrawImage → cache hit → paint_image →
    // window presenter` pipeline on first paint, without
    // needing the image to be decoded from disk first (the
    // decode-to-cache step is still unwired — see
    // image_header.mbt).
    //
    // Set imageSource back to "" to see the Phase 5.2
    // placeholder StrokeRect instead (imageSource == "").
    imageSource: "_phase5_2_synthetic",
    imageNaturalSize: { x: 200.0, y: 200.0, },
    imageDecoded: None,
    fitMode: @core.ImageFit::Contain,
    // Phase 5.3 — annotations + bindings live in model so hit-test
    // can run without re-parsing the raw label JSON on every mouse
    // move. SetAnnotations syncs them from the parsed JSON. The
    // default values are set by the `default_demo_*` helpers above
    // (inserted after `classes: []`) so the smoke screenshot shows
    // the full annotation rendering pipeline.
    dragState: None,
    zoomDragMode: false,
    cursorImgPt: None,
    cursorCanvasPt: None,
    zoom: 1.0,
    pan: { x: 0.0, y: 0.0, },
    staticLayerDirty: true,
    dynamicLayerDirty: true,
    toastMessage: None,
    toastKind: Info,
    statusMessage: "Ready",
  }
}

///|
/// Phase 5.20 — the demo class list, as **real model state**.
///
/// Until now `model.classes` was always empty and the sidebar
/// rendered a hardcoded string list instead (knife / gun / batt / liq
/// / botl / bomb). That made the class-management handlers added in
/// 5.19 unreachable *in principle*, not just without a UI: a
/// `★` or `×` button on those rows would dispatch `SetDefaultClass`
/// or `DeleteClass` against ids that do not exist in
/// `model.classes`, and both would answer "No such class". Adding
/// the buttons would have created two more dead controls — the exact
/// failure 5.9, 5.10 and 5.17 spent this track removing. Seeding
/// real `ClassEntry` records is what makes them live.
///
/// **No class is marked `is_default`.** That is deliberate and it is
/// what keeps the smoke screenshot unchanged: `default_class_id`
/// falls through to `""`, and an annotation with an empty
/// `class_id` renders its own id as its label
/// (`class_lookup_name`'s fallback). Marking one default would give
/// every demo annotation the same "knife" label and hide the
/// per-annotation ids the smoke exists to show.
///
/// The id equals the name, which is what the demo rows already
/// assumed and what keeps the chip the user clicks identical to the
/// label that would land on the canvas. When `ScanClasses` is
/// implemented this is replaced wholesale by the project's real
/// class list; nothing else needs to change.
pub fn default_demo_classes() -> Array[ClassEntry] {
  let names = ["knife", "gun", "batt", "liq", "botl", "bomb"]
  let out : Array[ClassEntry] = []
  for n in names {
    out.push({ id: n, name: n, is_default: false, })
  }
  out
}

///|
/// Phase 5.3 — synthetic annotation set used by
/// `Model::new` to demonstrate the static-layer annotation
/// rendering pipeline (Rect fill+stroke, Polygon fill+stroke+vertex
/// dots, Keypoint fill+stroke, label text at centroid) in the
/// smoke screenshot without needing a real .json label file on
/// disk to be loaded at startup.
///
/// Coordinates are in image-natural space (the synthetic
/// 200×200 magenta test image from Phase 5.2). IDs match
/// `default_demo_bindings` so the binding arrow draws.
/// class_id is empty so the label text falls back to `id`
/// per `class_lookup_name`'s fallback path.
fn default_demo_annotations() -> Array[Annotation] {
  // Rect spanning the upper-left quadrant of the image.
  let rect : Annotation = {
    id: "rect-1",
    shape: Rect,
    points: [
      { x: 40.0, y: 40.0, },
      { x: 140.0, y: 140.0, },
    ],
    class_id: "",
  }
  // Triangle in the upper-right quadrant (3 points).
  let poly : Annotation = {
    id: "poly-1",
    shape: Polygon,
    points: [
      { x: 110.0, y: 30.0, },
      { x: 180.0, y: 70.0, },
      { x: 145.0, y: 130.0, },
    ],
    class_id: "",
  }
  // Single-point keypoint in the lower-left quadrant.
  let kp : Annotation = {
    id: "kp-1",
    shape: Keypoint,
    points: [{ x: 60.0, y: 170.0, }],
    class_id: "",
  }
  [rect, poly, kp]
}

///|
/// Phase 5.3 — synthetic binding between the demo Rect and
/// the demo Keypoint. `draw_bindings` paints a dashed line
/// from the Rect's centroid to the Keypoint's centroid +
/// a small arrow head at the `to` end, so the smoke
/// screenshot exercises the binding rendering path.
fn default_demo_bindings() -> Array[Binding] {
  [
    {
      id: "bind-1",
      from: "rect-1",
      to: "kp-1",
    },
  ]
}

// ─────────────────────────────────────────────────────────────────
// Msg — exhaustive event union
// ─────────────────────────────────────────────────────────────────

///|
pub(all) enum Msg {
  PickFolder
  PickFolderResult(String)
  LoadFolder(String)
  FolderLoaded(Array[ImageEntry], Array[VideoEntry], String, String)
  LoadFolderFailed(String, String)
  ScanClasses(String)
  ClassesLoaded(Array[ClassEntry])
  SelectIndex(Int)
  // Phase 5.17 — the sidebar's class rows were `@views.button`s with
  // no `on_click` at all: they rendered as pressable and did nothing.
  // 5.13 finally brought them on screen (they had been clipped off
  // the bottom of the window since 5.1), which turned 6 dead controls
  // into 6 visible ones. This is the message they dispatch.
  SetActiveClass(String)
  // Phase 5.21 — the rename-in-progress session. 5.19 implemented
  // `UpdateClass` and 5.20 gave the row a `*` and an `x`; rename was
  // the one left unreachable because it needs text entry. These four
  // messages are that input, modelled as a state machine so the whole
  // flow is testable without a widget.
  StartRenameClass(String)
  RenameInput(String)
  CommitRename
  CancelRename
  ReadLabelFor(String)
  LabelLoaded(Label, String, Bool)
  SaveLabel
  LabelSaved(String, Bool)
  SetMode(Mode)
  SetClassType(ClassType)
  SelectAnnotation(String?)
  AddRect(Point, Point)
  AddPolygon(Array[Point])
  AddKeypoint(Point)
  AddBinding(String, Point)
  BeginDraft(Point)
  PushDraft(Point)
  PopDraft
  FinishDraft
  CancelDraft
  DeleteAnnotation(String)
  // Phase 5.15 — convenience Msg for the Delete / Backspace
  // keyboard shortcut. Resolves the current selectedId and
  // delegates to DeleteAnnotation. No-op when nothing is
  // selected (so the shortcut doesn't delete an arbitrary
  // annotation or accidentally fire mid-typing).
  DeleteSelectedAnnotation
  ModifyHandle(String, Int, Point)
  CursorMoved(Point, Point)
  CursorLeft
  Zoom(Double)
  Pan(Point)
  // Phase 5.11 — reset pan + zoom to defaults (pan=(0,0),
  // zoom=1.0). Triggered by on_secondary_tap (right-click) and
  // on_double_tap (touch / keyboard) on the canvas view. The
  // canvas re-centres on the natural-size image.
  ResetZoomTransformView
  // Phase 5.12.D — auto-fit the natural-size image into the
  // supplied viewport. The Msg carries the viewport dimensions
  // because Moui doesn't expose a post-layout callback from
  // which the canvas view could push its current frame size
  // into Model. The sidebar Fit button dispatches this with a
  // hardcoded (800, 600) — matches the detail_width in the
  // top-level split_view. A future viewport-aware dispatcher
  // (after Moui adds a layout callback or @views.container with
  // a layout event) will supply the live frame instead.
  FitView(Double, Double)
  // Phase 5.12.D — zoom around a focal screen-space point.
  // Hooks up 5.12.A's zoom_around_screen_pt helper to the Msg
  // system. No trigger is wired yet (Moui 0.1.12 has no
  // on_wheel modifier; the wheel-zoom gesture lands in a
  // future batch once Moui exposes one). Tests verify the
  // dataflow.
  ZoomAroundScreenPoint(Double, Double, Double)
  // Phase 5.19 — toggle the zoom-drag mode flag (when on,
  // on_drag dispatches ZoomBy instead of Pan). Bound to
  // on_secondary_tap in view(). See the on_drag / on_secondary_tap
  // wiring for the dispatch chain.
  ToggleZoomDragMode
  AddClass(String)
  UpdateClass(String, String)
  DeleteClass(String)
  SetDefaultClass(String)
  SetSettingOpacity(Double)
  SetSettingPolygonClosePx(Double)
  SetSettingAutosaveMs(Int)
  SwitchMediaKind(MediaKind)
  LoadVideoFrame(Int)
  // Phase 5.2 — image source load + fit-mode toggle.
  // LoadTestImage(path, natural_w, natural_h) — caller supplies the
  //   natural pixel size (read from the JPEG/PNG header or
  //   guessed). Phase 5.3 will replace with a real image-header
  //   probe using riantr/moonbit_image.
  // SetFitMode(fit) — switch between Contain / Cover / Stretch.
  LoadTestImage(String, Double, Double)
  // Phase 5.6 — caller passes only the path; the app reads the
  // header itself via riantr/moonbit_image (see image_header.mbt)
  // and dispatches `ImageLoaded(path, w, h)` or `LoadImageFailed`
  // once it knows the natural pixel size. This removes the
  // "caller must guess the image dimensions" requirement that
  // 5.2's LoadTestImage had.
  LoadImage(String)
  ImageLoaded(String, Int, Int)
  LoadImageFailed(String, String)
  ClearImage
  SetFitMode(@core.ImageFit)
  // Phase 5.3 — annotation set / handle drag.
  // SetAnnotations(annotations, bindings) — bulk-replace the model's
  //   annotation set + binding list. Used to sync the model after
  //   parsing the label JSON (parser added in 5.x).
  // BeginDragHandle(ann_id, handle_idx, start_img_pt) — start
  //   dragging the n-th handle of the given annotation. The
  //   `start_img_pt` is the cursor position at drag start in
  //   image-natural coordinates (recorded in dragState for
  //   future delta math + audit). While dragState is Some,
  //   every CursorMoved emits ModifyHandle instead of
  //   hit-testing. Phase 5.5 added the start_img_pt parameter
  //   so the handler doesn't need to read cursorImgPt (which
  //   may not be set yet on the first drag frame).
  // EndDragHandle — release the active drag (no-op when None).
  SetAnnotations(Array[Annotation], Array[Binding])
  // Phase 5.14.B — parse a JSON label text and bulk-load the
  // result into the model. Currently only wired to a
  // test-driven dataflow; the production path will route
  // through op_set_annotations once the IPC bridge lands.
  // Returns (annotations, bindings) ready for SetAnnotations.
  // model.classes is passed at dispatch time so the parser
  // can resolve class names → class_ids.
  LoadLabelJson(String)
  // Phase 5.16 — store a freshly-serialised label JSON in
  // model.label and clear the dirty flag. The caller is
  // expected to have produced `text` via
  // label_io.serialize_label_text(model) or its equivalent.
  // Splitting "produce JSON" from "store in model" keeps the
  // dispatch handler free of side-effect-only concerns and
  // matches the existing pattern (LoadLabelJson similarly
  // takes a pre-parsed JSON string).
  SaveLabelText(String)
  // Phase 5.16 — convenience Msg: serialize the current
  // model state to JSON and store it in model.label.raw_json
  // in one step. Use this for the sidebar "Save" button;
  // the caller (write_file) decides whether to also flush to
  // disk via an Effect.
  SaveCurrentLabel
  // Phase 5.5 — added `start_img_pt` so the handler doesn't
  // need to read model.cursorImgPt (which may be None on the
  // first drag frame, before any CursorMoved has fired).
  BeginDragHandle(String, Int, Point)
  EndDragHandle
  // Phase 5.6 — pointer went down on the canvas. Carries
  // (img_pt, canvas_pt) in the same shape as CursorMoved.
  //
  // Pre-5.6 the Started-phase logic lived in canvas_view.mbt's
  // on_drag closure, which reads a *stale* `model` snapshot
  // captured when the view was built. Two consequences:
  //   1. `model.selectedId` was always one frame stale, so the
  //      very first click of a session (selectedId == None)
  //      could never arm a handle drag — the handle belongs
  //      to an annotation that hasn't been selected yet.
  //   2. The closure couldn't update the model, so any hit
  //      result had to be smuggled back through a second Msg
  //      round-trip.
  //
  // Phase 5.6 moves the whole press decision into `update`,
  // where the model is live. The handler runs
  // `hit_test_select` (select-then-drag) and then, if the newly
  // selected annotation has a handle under the cursor,
  // `hit_test_handle` to arm dragState — all in one Msg, one
  // frame, no stale reads.
  CanvasPressed(Point, Point)
  // Phase 5.8 — the drawing-tool Msgs, completing the set needed to
  // actually create annotations (the `Add*` handlers existed but
  // nothing could reach them). Together with the now-real `AddRect` /
  // `AddPolygon` / `AddKeypoint` / `AddBinding` handlers, a user can
  // finally draw, not just edit the synthetic demo annotations.
  //
  // UpdateDraft(pt) — replace the draft's *last* point (rect tool
  //   rubber-banding: press sets the first corner, every Changed
  //   frame moves the second). Appends when the draft is empty so
  //   callers can use it as "add or move" without a null check.
  // CommitDraft — inspect `model.draftPoints` + `model.mode` and
  //   dispatch the matching Add* via `Effect::send`: Rect needs 2
  //   points, Polygon needs 3, otherwise no-op. Keeping the decision
  //   here (rather than branching in the view closure) means the
  //   draft-length rules are unit-testable and can't drift between
  //   the tools.
  UpdateDraft(Point)
  CommitDraft
  // Phase 5.8 — double-tap on the canvas, overloading the Phase 5.19
  // wheel-zoom toggle. In Polygon mode it commits the in-progress
  // polygon ("click vertices, double-click to close"); in every
  // other mode it keeps toggling `zoomDragMode`. Routing it through
  // `update` (rather than branching in the view closure) is what
  // makes the per-mode rule testable.
  //
  // No position payload: Moui 0.1.12's `on_double_tap` takes a bare
  // `Msg` and carries no coordinates, and none are needed — the
  // polygon's vertices already live in `model.draftPoints`.
  DoubleTapped
  // Phase 5.10 — full image decode result. Carries the decoded
  // pixel width, height, byte length, and pixel format name
  // (Gray8 / GrayA8 / RGB8 / RGBA8) so the model can expose
  // them via a status bar / progress UI without holding the
  // raw pixel buffer in the Model struct (we'd otherwise bloat
  // every Model update with multi-MB pixel data).
  ImageDecoded(String, Int, Int, Int, String)
  OpResult(OpResult)
  ExportVoc(String)
  ExportYolo(String)
  ShowToast(String, ToastKind)
  DismissToast
  MarkDirty(Layer)
}

// ─────────────────────────────────────────────────────────────────
// Update — pure, returns new Model + Effect[Msg]
// ─────────────────────────────────────────────────────────────────

///|
pub fn update(model : Model, msg : Msg) -> (Model, @moui.Effect[Msg]) {
  match msg {
    PickFolder => (model, @moui.Effect::none())
    PickFolderResult(path) =>
      if path == "" {
        (
          { ..model, statusMessage: "Folder pick cancelled", },
          @moui.Effect::none(),
        )
      } else {
        ({ ..model, folder: path, }, @moui.Effect::none())
      }
    // Phase 5.22 — really scans the folder. Was a no-op stub on the
    // (wrong) theory that `Effect::Task` never runs; it does, and
    // `moonbitlang/x/fs` reads the directory synchronously anyway, so
    // nothing async is needed. See `disk_io.mbt` for the full
    // correction.
    LoadFolder(path) =>
      match scan_folder(path) {
        None =>
          (
            {
              ..model,
              toastMessage: Some("Folder load failed: " + path),
              toastKind: Error,
            },
            @moui.Effect::none(),
          )
        Some(scan) =>
          (
            folder_loaded(
              model,
              scan.images,
              scan.videos,
              path,
              scan.label_folder,
            ),
            @moui.Effect::none(),
          )
      }
    // Delegated so the programmatic route and the scan route cannot
    // drift: both go through `folder_loaded`.
    FolderLoaded(images, videos, folder, label_folder) =>
      (
        folder_loaded(model, images, videos, folder, label_folder),
        @moui.Effect::none(),
      )
    LoadFolderFailed(_path, err) =>
      (
        {
          ..model,
          toastMessage: Some("Folder load failed: " + err),
          toastKind: Error,
        },
        @moui.Effect::none(),
      )
    // Phase 5.22 — still a no-op, and now for an honest reason rather
    // than a false one. It used to be "I/O is impossible"; disk reads
    // work fine now. The actual blocker is that **there is no class
    // source in the dataset** — `data/Label@skin` holds one .json and
    // no classes file, so there is no on-disk convention to recover.
    // Deriving classes from the distinct `type` values across every
    // label is a reasonable design, but it is a *choice*, and shipping
    // it as though it were the recovered convention would misrepresent
    // it. Deferred deliberately.
    ScanClasses(_path) => (model, @moui.Effect::none())
    ClassesLoaded(classes) => ({ ..model, classes, }, @moui.Effect::none())
    SetMode(mode) =>
      (
        {
          ..model,
          mode,
          // Phase 5.9 — switching tools abandons any in-progress
          // draft and disarms a half-armed binding. The draft
          // rubber-band is painted by the *dynamic* layer (see
          // `draw_dynamic_layer`), so the stale preview only needs
          // that layer to repaint. The static layer is untouched
          // because the image, pan, zoom and annotation set are all
          // unchanged — pre-5.9 this handler set no dirty flag at
          // all, which left the previous tool's rubber-band on
          // screen until some unrelated Msg happened to repaint.
          draftPoints: [],
          bindingFromId: None,
          statusMessage: "Mode: " + mode_label(mode),
          dynamicLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    SetClassType(ct) => ({ ..model, classType: ct, }, @moui.Effect::none())
    // Phase 5.17 — a click on a sidebar class row. The status message
    // is not decoration: it is the only feedback a Ghost-variant
    // sidebar row gives, and the class is otherwise invisible until
    // the next annotation is drawn.
    SetActiveClass(id) =>
      (
        {
          ..model,
          activeClassId: id,
          statusMessage: "Class: " + id,
          // The sidebar chip changes, and `dynamicLayerDirty` is what
          // the canvas's dynamic layer (crosshair, handles) reacts
          // to. The sidebar is part of the static layer's subtree, so
          // it needs the static flag; both are cheap and neither
          // re-blits the image for a class change on its own — the
          // static layer is cached and its key does not include the
          // sidebar, so this only repaints the chrome.
          staticLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    SelectAnnotation(id) =>
      (
        { ..model, selectedId: id, staticLayerDirty: true, },
        @moui.Effect::none(),
      )
    // Phase 5.8 — the Add* handlers were no-op placeholders (the
    // same class of stub that `ModifyHandle` was until Phase 5.4):
    // they reset `mode` / `draftPoints` and bumped the dirty flag
    // but never appended anything, so the MoUI app could edit the
    // three synthetic demo annotations and could not create a single
    // new one. Each now actually constructs the annotation/binding.
    //
    // Shared contract: allocate a deterministic id, assign
    // `default_class_id(model)`, append, select the new entity, and
    // reset the drawing mode back to `Select` (except `AddKeypoint`,
    // which stays in Keypoint mode so the user can rapidly drop
    // several points without re-clicking the toolbar — the same
    // behaviour as the legacy frontend's keypoint tool).
    AddRect(p1, p2) => {
      // Degenerate (a click with no drag) → no annotation, and leave
      // the mode alone so the user isn't kicked out of Rect tool by
      // an accidental click.
      if rect_is_degenerate(p1, p2) {
        (model, @moui.Effect::none())
      } else {
        let (tl, br) = normalize_rect_corners(p1, p2)
        let ann : Annotation = {
          id: next_annotation_id(model),
          shape: Rect,
          points: [tl, br],
          class_id: default_class_id(model),
        }
        (
          {
            ..model,
            annotations: model.annotations + [ann],
            selectedId: Some(ann.id),
            label: { raw_json: model.label.raw_json, dirty: true, },
            // Phase 5.16 — via the shared rule rather than a
            // hand-written `mode: Select`. See `mode_after_commit`.
            mode: mode_after_commit(Rect),
            draftPoints: [],
            staticLayerDirty: true,
          },
          @moui.Effect::none(),
        )
      }
    }
    AddPolygon(pts) => {
      // A polygon needs 3 distinct-enough vertices to enclose area;
      // fewer is a stray click or an in-progress draft.
      if pts.length() < 3 {
        (model, @moui.Effect::none())
      } else {
        let ann : Annotation = {
          id: next_annotation_id(model),
          shape: Polygon,
          points: pts,
          class_id: default_class_id(model),
        }
        (
          {
            ..model,
            annotations: model.annotations + [ann],
            selectedId: Some(ann.id),
            label: { raw_json: model.label.raw_json, dirty: true, },
            // Phase 5.16 — shared rule; see `mode_after_commit`.
            mode: mode_after_commit(Polygon),
            draftPoints: [],
            staticLayerDirty: true,
          },
          @moui.Effect::none(),
        )
      }
    }
    AddKeypoint(pt) => {
      let ann : Annotation = {
        id: next_annotation_id(model),
        shape: Keypoint,
        points: [pt],
        class_id: default_class_id(model),
      }
      (
        {
          ..model,
          annotations: model.annotations + [ann],
          selectedId: Some(ann.id),
          label: { raw_json: model.label.raw_json, dirty: true, },
          // Phase 5.16 — this used to be expressed by *omitting*
          // `mode` and inheriting `model.mode`. That is the same
          // rule as the other two handlers written a third way, and
          // it only works because the canvas dispatches
          // `AddKeypoint` while the keypoint tool is armed. It is
          // now explicit, so the behaviour no longer depends on the
          // caller having set the mode first.
          mode: mode_after_commit(Keypoint),
          staticLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    }
    AddBinding(from_id, pt) => {
      // The Msg carries the *point* the user clicked, not the target
      // id — matching the frontend's two-step binding flow (click the
      // source annotation to set `bindingFromId`, then click the
      // target). Resolve the target by hit-test, ignoring the source
      // itself so a click on the source can't create a self-loop.
      let target : String? = match hit_test_body(
        pt,
        model.annotations,
        body_hit_radius,
      ) {
        Some(id) => if id == from_id { None } else { Some(id) }
        None => None
      }
      match target {
        Some(to_id) => {
          let b : Binding = {
            id: next_binding_id(model),
            from: from_id,
            to: to_id,
          }
          (
            {
              ..model,
              bindings: model.bindings + [b],
              bindingFromId: None,
              mode: Select,
              label: { raw_json: model.label.raw_json, dirty: true, },
              staticLayerDirty: true,
            },
            @moui.Effect::none(),
          )
        }
        None =>
          // No target under the cursor (or it was the source): cancel
          // the pending binding rather than leaving the app in a
          // half-armed state.
          (
            { ..model, bindingFromId: None, mode: Select, },
            @moui.Effect::none(),
          )
      }
    }
    BeginDraft(pt) =>
      (
        {
          ..model,
          draftPoints: [pt],
          // Phase 5.8 — the draft preview is drawn by the *dynamic*
          // layer (`draw_draft_rect` / `draw_draft_polygon` in
          // `draw_dynamic_layer`), so only the dynamic layer needs to
          // repaint. The pre-5.8 handlers set `staticLayerDirty`,
          // forcing a full background+image blit on every draft frame
          // for a change that touches neither.
          dynamicLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    PushDraft(pt) =>
      (
        {
          ..model,
          draftPoints: model.draftPoints + [pt],
          dynamicLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    UpdateDraft(pt) => {
      // Phase 5.8 — the Rect tool's rubber-band. Contract:
      // **grow the draft to 2 points, then move the second.**
      //
      // The grow-then-move split is load-bearing, and getting it
      // wrong silently disables the whole tool: a pure
      // "replace the last point" version leaves the draft at 1
      // point forever after `BeginDraft`, so `CommitDraft`'s
      // `>= 2` check never passes and no rect can ever be created.
      // (That was the first implementation; the test
      // "UpdateDraft — moves the last point, appends when empty"
      // caught it.)
      let n = model.draftPoints.length()
      if n < 2 {
        (
          {
            ..model,
            draftPoints: model.draftPoints + [pt],
            dynamicLayerDirty: true,
          },
          @moui.Effect::none(),
        )
      } else {
        // Keep every point except the last, then move the last.
        let pts : Array[Point] = []
        let mut i = 0
        while i < n - 1 {
          pts.push(model.draftPoints[i])
          i = i + 1
        }
        pts.push(pt)
        (
          {
            ..model,
            draftPoints: pts,
            dynamicLayerDirty: true,
          },
          @moui.Effect::none(),
        )
      }
    }
    CommitDraft =>
      // Phase 5.8 — turn the in-progress draft into a real
      // annotation by dispatching the matching `Add*`. The length
      // rules live here, not in the view closure, so they're
      // testable and consistent across tools.
      match model.mode {
        Rect => {
          if model.draftPoints.length() >= 2 {
            (
              model,
              @moui.Effect::send(
                AddRect(
                  model.draftPoints[0],
                  model.draftPoints[1],
                ),
              ),
            )
          } else {
            // A click with no drag — drop the draft silently rather
            // than leaving a 1px rect behind.
            (
              { ..model, draftPoints: [], },
              @moui.Effect::none(),
            )
          }
        }
        Polygon => {
          if model.draftPoints.length() >= 3 {
            (
              model,
              @moui.Effect::send(AddPolygon(model.draftPoints)),
            )
          } else {
            (model, @moui.Effect::none())
          }
        }
        _ => (model, @moui.Effect::none())
      }
    DoubleTapped =>
      // Phase 5.8 — overload double-tap per mode. Polygon commits
      // (the vertex-click tool needs a separate gesture to close);
      // every other mode keeps the Phase 5.19 wheel-zoom toggle.
      // Selection is deliberately NOT re-run in Polygon mode —
      // committing a polygon shouldn't also change what's selected.
      match model.mode {
        Polygon => {
          if model.draftPoints.length() >= 3 {
            (
              model,
              @moui.Effect::send(AddPolygon(model.draftPoints)),
            )
          } else {
            (model, @moui.Effect::none())
          }
        }
        _ =>
          (
            { ..model, zoomDragMode: !model.zoomDragMode, },
            @moui.Effect::none(),
          )
      }
    PopDraft => {
      let n = model.draftPoints.length()
      if n <= 1 {
        (model, @moui.Effect::none())
      } else {
        let kept : Array[Point] = []
        for i = 0; i < n - 1; i = i + 1 {
          kept.push(model.draftPoints[i])
        }
        (
          {
            ..model,
            draftPoints: kept,
            dynamicLayerDirty: true,
          },
          @moui.Effect::none(),
        )
      }
    }
    // Phase 5.9 — `FinishDraft` / `CancelDraft` only discard the
    // in-progress draft, and the draft preview is drawn by the
    // *dynamic* layer, so that is the only layer that needs to
    // repaint. Pre-5.9 these two set `staticLayerDirty`, forcing a
    // full background + image re-blit for a change that touches
    // neither. `PopDraft` above already carried the correct flag;
    // these two were missed when Phase 5.8 swept the draft handlers.
    FinishDraft =>
      (
        { ..model, draftPoints: [], mode: Select, dynamicLayerDirty: true, },
        @moui.Effect::none(),
      )
    // Phase 5.10 — Escape now dispatches this (it had been
    // unreachable since the draft landed), which makes it the app's
    // "cancel everything in progress" affordance. It must therefore
    // also disarm a *pending binding* — before this fix it reset the
    // mode but left `bindingFromId` set, so a user who armed a
    // binding, pressed Escape, then pressed `[Binding]` again hit
    // `SetMode`, which clears the arm... but only by luck of the
    // ordering. `SetMode` (line ~608) already clears both fields, so
    // this arm was reachable-but-unreachable only by accident.
    // `FinishDraft` above has the same latent shape; it is not bound
    // to any key and not dispatched from the view tree, so it is left
    // alone rather than changed untested.
    //
    // Phase 5.16 — note this uses the *cancel* rule, not
    // `mode_after_commit`. Both `FinishDraft` and `CancelDraft` go to
    // `Select` unconditionally, **including when the user was in
    // Keypoint mode**. That is deliberate and is the asymmetry
    // `mode_after_commit` documents: a commit means "I finished",
    // which leaves the keypoint tool armed for the next point, while
    // a cancel means "stop", which must leave nothing armed. The
    // distinction is the whole reason these handlers do not call the
    // commit rule.
    CancelDraft =>
      (
        {
          ..model,
          draftPoints: [],
          bindingFromId: None,
          mode: Select,
          dynamicLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    DeleteAnnotation(id) => {
      // Phase 5.15 — actually remove the annotation, plus any
      // bindings that referenced it (dangling binding cleanup
      // matches the 5.9 draw_bindings "silently skipped" policy
      // — we don't leave orphan bindings behind). If the
      // deleted annotation was selected, clear the selection
      // (otherwise the dynamic layer would keep rendering handles
      // for an annotation that no longer exists).
      let new_annotations : Array[Annotation] = []
      for ann in model.annotations {
        if ann.id != id {
          new_annotations.push(ann)
        }
      }
      let new_bindings : Array[Binding] = []
      for b in model.bindings {
        if b.from != id && b.to != id {
          new_bindings.push(b)
        }
      }
      let new_selected : String? = match model.selectedId {
        Some(sel_id) => if sel_id == id { None } else { Some(sel_id) }
        None => None
      }
      (
        {
          ..model,
          annotations: new_annotations,
          bindings: new_bindings,
          selectedId: new_selected,
          label: { raw_json: model.label.raw_json, dirty: true, },
          staticLayerDirty: true,
          dynamicLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    }
    DeleteSelectedAnnotation =>
      // Phase 5.15 — Delete / Backspace keyboard shortcut
      // handler. Reads the current selectedId and inlines the
      // DeleteAnnotation logic (no way to compose Msg arms in
      // MoonBit's match; inlining is the simplest path).
      // No-op when nothing is selected so the shortcut can't
      // fire on mid-typing keystrokes.
      match model.selectedId {
        Some(sel_id) => {
          let new_annotations : Array[Annotation] = []
          for ann in model.annotations {
            if ann.id != sel_id {
              new_annotations.push(ann)
            }
          }
          let new_bindings : Array[Binding] = []
          for b in model.bindings {
            if b.from != sel_id && b.to != sel_id {
              new_bindings.push(b)
            }
          }
          (
            {
              ..model,
              annotations: new_annotations,
              bindings: new_bindings,
              selectedId: None,
              label: { raw_json: model.label.raw_json, dirty: true, },
              staticLayerDirty: true,
              dynamicLayerDirty: true,
            },
            @moui.Effect::none(),
          )
        }
        None => (model, @moui.Effect::none())
      }
    ModifyHandle(ann_id, handle_idx, new_pt) =>
      // Phase 5.4 — actually mutate the annotation via
      // `apply_handle_move` from hittest.mbt. Pre-5.4 this was
      // a no-op placeholder that just bumped the dirty flag; the
      // points array was left unchanged so dragging a handle had
      // no visible effect. Now: iterate `model.annotations`, find
      // the matching id, call `apply_handle_move(ann, handle_idx,
      // new_pt)`, replace with the new annotation when Some, and
      // mark static + label dirty. Returns the same model when no
      // matching id is found or `apply_handle_move` rejects the
      // handle_idx (e.g. polygon with fewer vertices than the
      // requested index).
      mutate_annotation(model, ann_id, fn(ann) {
        apply_handle_move(ann, handle_idx, new_pt)
      })
    CursorMoved(img_pt, canvas_pt) =>
      // Phase 5.4 — when dragState is Some, route the cursor move
      // through to ModifyHandle(ann_id, handle_idx, img_pt) by
      // dispatching it via Effect::send, so the per-frame handler
      // chain stays single-step (CursorMoved → ModifyHandle →
      // mutate). This avoids duplicating the mutate_annotation
      // logic between the two Msg variants.
      //
      // When dragState is None, fall back to the Phase 5.3
      // hit-test path: prefer handles of the selected annotation
      // (radius 12 px), fall back to body hit (radius 4 px). Both
      // radii are in image-natural pixel space, matching the
      // frontend canvas.js v0.2.9 conventions.
      match model.dragState {
        Some(drag) =>
          (
            {
              ..model,
              cursorImgPt: Some(img_pt),
              cursorCanvasPt: Some(canvas_pt),
              dynamicLayerDirty: true,
            },
            @moui.Effect::send(
              ModifyHandle(drag.ann_id, drag.handle_idx, img_pt),
            ),
          )
        None =>
          (
            {
              ..model,
              cursorImgPt: Some(img_pt),
              cursorCanvasPt: Some(canvas_pt),
              selectedId: hit_test_select(
                img_pt,
                model.annotations,
                model.selectedId,
              ),
              staticLayerDirty: true,
              dynamicLayerDirty: true,
            },
            @moui.Effect::none(),
          )
      }
    CursorLeft =>
      (
        {
          ..model,
          cursorImgPt: None,
          cursorCanvasPt: None,
          dynamicLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    Zoom(z) =>
      (
        { ..model, zoom: z, staticLayerDirty: true, dynamicLayerDirty: true, },
        @moui.Effect::none(),
      )
    Pan(delta) =>
      // Phase 5.19 — when zoomDragMode is on, the Pan Msg
      // becomes a wheel-zoom simulation: dy drives a zoom
      // factor (exp(-dy * scale), matching canvas.js line
      // 218 `factor = Math.exp(-ev.deltaY * 0.0015)`),
      // applied around the cursor position. dx still
      // contributes to the zoom factor too (canvas.js only
      // uses deltaY; we use both axes to make horizontal
      // mouse-wheel feel intuitive if it ever lands). The
      // delta is screen-space, so the cursor screen position
      // is `cursorCanvasPt` (canvas-local, NOT pan-offset).
      if model.zoomDragMode {
        // Phase 5.19 — wheel-zoom simulation. Combine dx + dy
        // into a single zoom factor (canvas.js uses -dy only;
        // we use -dy as the dominant axis and -dx as a
        // minor tiebreaker for trackpad-style two-finger
        // gestures).
        let focal_x : Double = match model.cursorCanvasPt {
          Some(p) => p.x
          None => 0.0
        }
        let focal_y : Double = match model.cursorCanvasPt {
          Some(p) => p.y
          None => 0.0
        }
        // The -dy convention: pushing mouse UP zooms IN
        // (canvas.js's wheel-up-zooms-in matches typical
        // desktop image viewers). dy * 0.015 is the
        // sensitivity; canvas.js uses 0.0015 but dy is in
        // pixels per pixel, so 10× for our drag convention.
        let factor : Double = @math.exp(-((delta.y + delta.x * 0.3) * 0.015))
        let new_zoom : Double = factor * model.zoom
        let new_pan : Point = zoom_around_screen_pt(
          new_zoom,
          focal_x,
          focal_y,
          model.pan,
          model.zoom,
        )
        (
          {
            ..model,
            pan: new_pan,
            zoom: clamp_zoom(new_zoom),
            staticLayerDirty: true,
            dynamicLayerDirty: true,
          },
          @moui.Effect::none(),
        )
      } else {
        // Default 5.11 Pan behavior — drag-to-pan.
        (
          {
            ..model,
            pan: { x: model.pan.x + delta.x, y: model.pan.y + delta.y, },
            staticLayerDirty: true,
            dynamicLayerDirty: true,
          },
          @moui.Effect::none(),
        )
      }
    ToggleZoomDragMode =>
      // Phase 5.19 — flip the zoom-drag-mode flag. Bound
      // to on_secondary_tap in view() so a right-click
      // toggles between "drag = pan" (default) and "drag =
      // wheel-zoom" modes. Idempotent within a frame; the
      // statusMessage gives the user a visible cue about
      // which mode they're in.
      (
        {
          ..model,
          zoomDragMode: !model.zoomDragMode,
          statusMessage: if model.zoomDragMode {
            "Zoom-drag OFF"
          } else {
            "Zoom-drag ON (drag = zoom)"
          },
        },
        @moui.Effect::none(),
      )
    ResetZoomTransformView =>
      // Phase 5.11 — reset pan + zoom to defaults. Forces a
      // full static-layer repaint (the 5.5.x cache key
      // includes pan + zoom, so changing them invalidates
      // the cached static bitmap and the next paint rebuilds
      // it from scratch).
      (
        {
          ..model,
          pan: { x: 0.0, y: 0.0, },
          zoom: 1.0,
          statusMessage: "View reset",
          staticLayerDirty: true,
          dynamicLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    FitView(viewport_w, viewport_h) => {
      // Phase 5.12.D — auto-fit the natural-size image into
      // the supplied viewport. Delegates to view_math.fit_view_zoom
      // (scale to fit) and view_math.fit_view_pan (centre the
      // fitted image). Both helpers are pure functions added in
      // 5.12.A; this handler just glues them into the Msg
      // pipeline.
      //
      // The statusMessage gives the user a confirmation cue
      // (the actual visual fit happens via the standard
      // zoom/pan → cache invalidation → repaint cycle).
      let nat_w : Double = model.imageNaturalSize.x
      let nat_h : Double = model.imageNaturalSize.y
      let new_zoom : Double = fit_view_zoom(
        nat_w, nat_h, viewport_w, viewport_h,
      )
      let new_pan : Point = fit_view_pan(
        new_zoom, nat_w, nat_h, viewport_w, viewport_h,
      )
      (
        {
          ..model,
          pan: new_pan,
          zoom: new_zoom,
          statusMessage: "Fit view",
          staticLayerDirty: true,
          dynamicLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    }
    ZoomAroundScreenPoint(new_zoom, focal_sx, focal_sy) => {
      // Phase 5.12.D — zoom around a focal screen-space point.
      // Delegates to view_math.zoom_around_screen_pt which
      // (a) clamps the new zoom, (b) converts focal screen
      // coords to natural, (c) computes the new pan that
      // keeps the focal natural point under the same screen
      // position after the zoom. Mirrors canvas.js
      // zoomAtScreenPoint (lines 256-264) one-for-one.
      let new_pan : Point = zoom_around_screen_pt(
        new_zoom,
        focal_sx,
        focal_sy,
        model.pan,
        model.zoom,
      )
      (
        {
          ..model,
          pan: new_pan,
          zoom: clamp_zoom(new_zoom),
          staticLayerDirty: true,
          dynamicLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    }
    AddClass(name) =>
      (
        {
          ..model,
          classes: model.classes + [{ id: name, name, is_default: false, }],
        },
        @moui.Effect::none(),
      )
    // Phase 5.21 — the rename session. Four messages, all pure state
    // transitions, so the flow is testable without a text field ever
    // being rendered.
    //
    // Entering seeds the buffer with the class's current **name**,
    // because a rename that starts from an empty box is a "retype it",
    // not a "rename it". Committing an empty buffer cancels rather
    // than renaming to blank: an empty class name renders as a label
    // with nothing in it, and the UI has no way to say "leave it
    // alone" once the text is gone.
    StartRenameClass(id) => {
      let hit = model.classes.filter(c => c.id == id)
      if hit.length() == 0 {
        (
          { ..model, statusMessage: "No such class: " + id, },
          @moui.Effect::none(),
        )
      } else {
        (
          {
            ..model,
            editingClassId: id,
            renameBuffer: hit[0].name,
            statusMessage: "Renaming " + id,
            staticLayerDirty: true,
          },
          @moui.Effect::none(),
        )
      }
    }
    RenameInput(text) =>
      (
        {
          ..model,
          renameBuffer: text,
        },
        @moui.Effect::none(),
      )
    CommitRename => {
      let id = model.editingClassId
      if id == "" {
        // Nothing in flight. The field only renders while editing, so
        // this is unreachable from the UI; it is here so the message
        // is total rather than half-handled.
        (model, @moui.Effect::none())
      } else if model.renameBuffer == "" {
        (
          {
            ..model,
            editingClassId: "",
            renameBuffer: "",
            statusMessage: "Rename cancelled (empty name)",
            staticLayerDirty: true,
          },
          @moui.Effect::none(),
        )
      } else {
        let renamed = renamed_class(model, id, model.renameBuffer)
        (
          {
            ..renamed,
            editingClassId: "",
            renameBuffer: "",
            staticLayerDirty: true,
          },
          @moui.Effect::none(),
        )
      }
    }
    CancelRename => (
      {
        ..model,
        editingClassId: "",
        renameBuffer: "",
        statusMessage: "Rename cancelled",
        staticLayerDirty: true,
      },
      @moui.Effect::none(),
    )
    // Phase 5.19 — the class list was half-built: `AddClass` appended
    // an entry, and rename / delete / set-default were all no-op
    // stubs. None of them need I/O — they are pure model edits, so
    // there was never a reason for them to be inert.
    //
    // The comment here used to say that unlike `ReadLabelFor` /
    // `LoadFolder` / `ScanClasses` these were not "blocked: Effect::Task
    // is never executed by the runtime, so a sync update cannot read a
    // file". **That blocker was a misreading** — see `disk_io.mbt`.
    // The I/O ops are implemented as of 5.22; the class ops were
    // simply never I/O-bound, which was the real and much milder
    // reason.
    //
    // Two layers of "which class is active", deliberately distinct:
    //
    //   - `ClassEntry::is_default` — the **project** default, persisted
    //     with the classes. This handler.
    //   - `Model::activeClassId` — the **session** choice made by
    //     clicking a sidebar row (5.17). It wins, and `default_class_id`
    //     falls back here when it is empty.
    //
    // Keeping both is not redundancy: the session choice should not
    // silently rewrite the project default, and it must be
    // clearable without touching what the project says.
    SetDefaultClass(id) => {
      let known : Bool = model.classes.iter().any(c => c.id == id)
      if !known {
        // A no-op that reports itself. Flipping across the list for an
        // id that is not in it would silently *unset* the current
        // default — "set the default to a class that doesn't exist"
        // must not mean "there is no default".
        (
          {
            ..model,
            statusMessage: "No such class: " + id,
          },
          @moui.Effect::none(),
        )
      } else {
        // Exactly one class carries the flag. Flipping across the
        // whole list is what makes it a *default* rather than another
        // boolean.
        let flipped : Array[ClassEntry] = model.classes.map(c => {
          ..c,
          is_default: c.id == id,
        })
        (
          {
            ..model,
            classes: flipped,
            statusMessage: "Default class: " + id,
            staticLayerDirty: true,
          },
          @moui.Effect::none(),
        )
      }
    }
    // Rename moves only the display name — and that is the whole
    // point of the id/name split. An annotation stores the class
    // **id**, and `class_lookup_name` resolves it through
    // `model.classes` at draw time, so every on-canvas label follows
    // the rename with no annotation being touched at all. A handler
    // that also rewrote `ann.class_id` here would be a no-op
    // (`id -> id`); the first draft of this arm had exactly that, and
    // it is removed rather than kept as decoration.
    UpdateClass(id, new_name) => (renamed_class(model, id, new_name), @moui.Effect::none())
    // Delete must not leave a dangling reference. `class_lookup_name`
    // falls back to rendering the annotation's **own id** when its
    // class cannot be resolved, so a surviving `class_id` pointing at
    // a class that no longer exists shows the raw id on the canvas.
    // Clearing it keeps every annotation renderable and honest.
    DeleteClass(id) => {
      let kept : Array[ClassEntry] = model.classes.filter(c => c.id != id)
      let existed : Bool = kept.length() != model.classes.length()
      let cleared : Array[Annotation] = model.annotations.map(ann => {
        ..ann,
        class_id: if ann.class_id == id { "" } else { ann.class_id },
      })
      (
        {
          ..model,
          classes: kept,
          annotations: cleared,
          // The session choice cannot point at a class that is gone.
          activeClassId: if model.activeClassId == id {
            ""
          } else {
            model.activeClassId
          },
          statusMessage: if existed {
            "Deleted class: " + id
          } else {
            "No such class: " + id
          },
          label: {
            raw_json: model.label.raw_json,
            dirty: model.label.dirty || existed,
          },
          staticLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    }
    SetSettingOpacity(v) =>
      (
        { ..model, statusMessage: "Opacity: " + v.to_string(), },
        @moui.Effect::none(),
      )
    SetSettingPolygonClosePx(v) =>
      (
        { ..model, statusMessage: "Polygon close: " + v.to_string() + "px", },
        @moui.Effect::none(),
      )
    SetSettingAutosaveMs(v) =>
      (
        { ..model, statusMessage: "Autosave: " + v.to_string() + "ms", },
        @moui.Effect::none(),
      )
    SwitchMediaKind(kind) =>
      ({ ..model, mediaKind: kind, currentIndex: -1, }, @moui.Effect::none())
    LoadVideoFrame(_idx) => (model, @moui.Effect::none())
    OpResult(Ok(_op, _json)) => (model, @moui.Effect::none())
    OpResult(Err(_op, err)) =>
      (
        { ..model, toastMessage: Some("Op failed: " + err), toastKind: Error, },
        @moui.Effect::none(),
      )
    ExportVoc(_folder) => (model, @moui.Effect::none())
    ExportYolo(_folder) => (model, @moui.Effect::none())
    ShowToast(message, kind) =>
      (
        { ..model, toastMessage: Some(message), toastKind: kind, },
        @moui.Effect::none(),
      )
    DismissToast => ({ ..model, toastMessage: None, }, @moui.Effect::none())
    // Phase 5.22 — was `state_for_image_change(model, idx)`. Selecting an
    // image now also reads its label off disk, which is what makes the
    // disk layer reachable at all: this is the message the sidebar's
    // image rows dispatch (Phase 5.17).
    SelectIndex(idx) => (image_selected(model, idx), @moui.Effect::none())
    ReadLabelFor(path) => (read_label_into(model, path), @moui.Effect::none())
    LabelLoaded(label, path, ok) =>
      (
        {
          ..model,
          label,
          labelPath: path,
          loadedFromDisk: ok,
          staticLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    // Phase 5.22 — really writes the file. Was a no-op stub.
    SaveLabel => {
      let (path, ok) = save_label_to_disk(model)
      (
        {
          ..model,
          label: { raw_json: model.label.raw_json, dirty: false, },
          statusMessage: if ok { "Saved " + path } else { "Save failed" },
        },
        @moui.Effect::none(),
      )
    }
    LabelSaved(path, ok) =>
      (
        {
          ..model,
          label: { raw_json: model.label.raw_json, dirty: false, },
          statusMessage: if ok {
            "Saved " + path
          } else {
            "Save failed: " + path
          },
        },
        @moui.Effect::none(),
      )
    MarkDirty(layer) =>
      match layer {
        Static => ({ ..model, staticLayerDirty: true, }, @moui.Effect::none())
        Dynamic => ({ ..model, dynamicLayerDirty: true, }, @moui.Effect::none())
      }
    LoadTestImage(path, natural_w, natural_h) =>
      // Phase 5.2 / 5.6 — kept for backward compatibility (callers
      // like the existing CEF→MoUI migration tests use it). New
      // code should prefer `LoadImage(path)` which probes the
      // header itself.
      (
        {
          ..model,
          imageSource: path,
          imageNaturalSize: { x: natural_w, y: natural_h, },
          statusMessage: "Loaded test image: " + path,
          staticLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    LoadImage(path) =>
      // Phase 5.6.x — dispatch an Effect::task that probes the
      // image header. Phase 5.22: `probe_image_dimensions_path` is a
      // real synchronous implementation now (it was a stub that
      // always returned `None`), so the header probe no longer needs
      // a coroutine. What is still missing is the *next* step —
      // decoding the pixels into the `ImageCache` — so the task
      // below still reports `LoadImageFailed` rather than pretending
      // to load. See `image_header.mbt` and `disk_io.mbt`.
      (
        { ..model, statusMessage: "Loading " + path + "...", },
        @moui.Effect::task(key="image-header-probe:" + path, start=fn(send) {
          match probe_image_dimensions_path(path) {
            Some((w, h)) =>
              if w > 0 && h > 0 {
                send(ImageLoaded(path, w, h))
              } else {
                send(LoadImageFailed(path, "image has zero width or height"))
              }
            None =>
              // 5.6.x: this branch is hit when the sync wrapper
              // can't call @fs.read_file. The async helper
              // probe_image_dimensions_path_async exists for the
              // future async-update-fn path.
              send(
                LoadImageFailed(
                  path, "5.6.x: sync wrapper can't bridge to async fs; use LoadTestImage or wait for async update fn",
                ),
              )
          }
          None
        }),
      )
    ImageLoaded(path, w, h) =>
      // Phase 5.6 — async result. The probe completed and we now
      // know the natural pixel size. Drop the path into
      // imageSource, fold the dimensions into imageNaturalSize,
      // and force a static-layer repaint (the cached layer key
      // changes via imageSource / imageNaturalSize so the
      // runtime invalidates the static cache automatically).
      (
        {
          ..model,
          imageSource: path,
          imageNaturalSize: { x: w.to_double(), y: h.to_double(), },
          statusMessage: "Loaded " +
          w.to_string() +
          "x" +
          h.to_string() +
          " image: " +
          path,
          staticLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    LoadImageFailed(path, reason) =>
      // Phase 5.6 — async error. Surface the failure as a toast
      // so the user knows why the image didn't load. We don't
      // touch imageSource — the previous image (or placeholder)
      // stays on screen.
      (
        {
          ..model,
          toastMessage: Some("Image load failed: " + reason),
          toastKind: ToastKind::Error,
          statusMessage: "Failed to load " + path + ": " + reason,
        },
        @moui.Effect::none(),
      )
    ClearImage =>
      // Phase 5.6 — drop the image entirely. Used by the UI when
      // the user explicitly dismisses a loaded image (e.g. after
      // an error toast). Forces the static cache to invalidate.
      (
        {
          ..model,
          imageSource: "",
          imageNaturalSize: { x: 800.0, y: 600.0, },
          imageDecoded: None,
          statusMessage: "Image cleared",
          staticLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    ImageDecoded(path, w, h, byte_len, fmt) =>
      // Phase 5.10 — async result of the full pixel decode (not
      // just the header probe in 5.6). Carries the image
      // metadata so the model can expose them without holding
      // the multi-MB raw pixel buffer in the Model struct.
      // The full pixel data lives in a side table (5.10.x+
      // follow-up).
      (
        {
          ..model,
          imageDecoded: Some({
            width: w,
            height: h,
            byte_length: byte_len,
            pixel_format: fmt,
          }),
          statusMessage: "Decoded " +
          w.to_string() +
          "x" +
          h.to_string() +
          " (" +
          (byte_len / 1024).to_string() +
          " KB, " +
          fmt +
          "): " +
          path,
        },
        @moui.Effect::none(),
      )
    SetFitMode(fit) =>
      ({ ..model, fitMode: fit, staticLayerDirty: true, }, @moui.Effect::none())
    SetAnnotations(annotations, bindings) =>
      (
        {
          ..model,
          annotations,
          bindings,
          selectedId: None,
          dragState: None,
          staticLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    LoadLabelJson(text) => {
      // Phase 5.14.B — parse the JSON text via label_io.parse_label_text
      // and route the result through the same dataflow as
      // SetAnnotations. model.classes is forwarded so the parser can
      // resolve class names → class_ids (the 5.14.A plumbing that
      // the canvas view reads in draw_label_text).
      let (annotations, bindings) : (Array[Annotation], Array[Binding]) = parse_label_text(
        text,
        model.classes,
      )
      (
        {
          ..model,
          annotations,
          bindings,
          selectedId: None,
          dragState: None,
          staticLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    }
    SaveLabelText(text) =>
      // Phase 5.16 — store the pre-serialised JSON in
      // model.label.raw_json and clear the dirty flag. The
      // caller is responsible for producing `text` (typically
      // via label_io.serialize_label_text(model)). Splitting
      // "produce JSON" from "store in model" matches the
      // LoadLabelJson shape and keeps the handler side-
      // effect-free (no disk I/O).
      (
        {
          ..model,
          label: { raw_json: text, dirty: false, },
          statusMessage: "Saved (in memory; flush to disk via IPC)",
        },
        @moui.Effect::none(),
      )
    SaveCurrentLabel => {
      // Phase 5.16 — convenience wrapper: serialize the
      // current model state and store it in model.label. The
      // effect is `none()` because the actual disk write
      // happens via the IPC bridge (op_write_label) once
      // it's wired. Until then, "Save" only persists to
      // memory + the dirty flag is cleared (so the next
      // delete or edit re-dirties it).
      let text : String = serialize_label_text(model)
      (
        {
          ..model,
          label: { raw_json: text, dirty: false, },
          statusMessage: "Saved (in memory)",
        },
        @moui.Effect::none(),
      )
    }
    BeginDragHandle(ann_id, handle_idx, start_img_pt) =>
      // Phase 5.5 — start dragging handle. The caller passes
      // the cursor's image-natural position at drag start
      // explicitly, so we don't depend on model.cursorImgPt
      // being set (which it might not be on the very first
      // drag frame). dragState.start_img_pt is recorded for
      // future delta math + audit.
      (
        {
          ..model,
          dragState: Some({ ann_id, handle_idx, start_img_pt, }),
          staticLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    EndDragHandle =>
      (
        { ..model, dragState: None, staticLayerDirty: true, },
        @moui.Effect::none(),
      )
    // Phase 5.6 — the full press decision, run against the live
    // model (no stale view-closure snapshot):
    //
    //   1. Always record the cursor positions.
    //   2. `hit_test_select` resolves the selection: prefer
    //      handles of the current selection (so clicking a
    //      handle of an already-selected annotation keeps it
    //      selected), else fall back to a body hit on the
    //      topmost annotation (reverse z-order).
    //   3. If we landed on an annotation, check whether the
    //      cursor is within `handle_hit_radius` px of one of
    //      ITS handles. If yes, arm `dragState` in the same
    //      frame.
    //
    // Step 3 is the bug Phase 5.5 deferred: pre-5.6 the
    // Started-phase closure only tried `hit_test_handle`
    // against `model.selectedId` from the *previous* frame. On
    // a cold start (selectedId == None), or when clicking a
    // handle of a not-yet-selected annotation, no drag ever
    // armed — the user had to click once to select, then click
    // again to drag. Now both happen in one press.
    //
    // NOTE: the arm body is wrapped in `{ }` because MoonBit
    // rejects `let` bindings directly in a match arm's action
    // part (error 3002: "Using let statement in the action part
    // of a matching case directly is not allowed. Consider
    // moving the let binding into a curly braces block").
    //
    // Phase 5.7 — step 3 is skipped entirely while `zoomDragMode`
    // is on. Moui 0.1.12's `DragGestureEvent` carries no button
    // ID, so the runtime routes *every* pointer-down through this
    // handler, including the right-drag that toggled zoom-drag
    // mode. Without the guard, a right-drag starting on a handle
    // would arm a handle drag, and the arming would then survive
    // until the next `Changed` frame reinterpreted the movement
    // as a zoom delta — so the annotation jumped by one frame of
    // cursor travel. Skipping the arm removes that whole class of
    // "zoom-drag also moved my annotation" bug. Selection is
    // still recorded (a click is a click), just never a drag.
    CanvasPressed(img_pt, canvas_pt) => {
      let sel : String? = hit_test_select(
        img_pt,
        model.annotations,
        model.selectedId,
      )
      let armed : (String, Int)? = if model.zoomDragMode {
        None
      } else {
        match sel {
          Some(sel_id) => hit_test_handle(
            img_pt,
            model.annotations,
            sel_id,
            handle_hit_radius,
          )
          None => None
        }
      }
      let drag : DragState? = match armed {
        Some((ann_id, handle_idx)) => Some({
          ann_id,
          handle_idx,
          start_img_pt: img_pt,
        })
        None => None
      }
      (
        {
          ..model,
          cursorImgPt: Some(img_pt),
          cursorCanvasPt: Some(canvas_pt),
          selectedId: sel,
          dragState: drag,
          // Pressing may change selection (visible highlight)
          // and may arm a drag (visible handles), but never
          // mutates geometry — so only the dynamic layer needs
          // to repaint here. The armed drag's first
          // ModifyHandle is what marks the static layer dirty.
          dynamicLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    }
  }
}

// ─────────────────────────────────────────────────────────────────
// Helpers — annotation mutation
// ─────────────────────────────────────────────────────────────────

///|
/// Phase 5.8 — the id prefix for user-created annotations. Matches
/// the `ann-N` shape used throughout the app_moui tests and the
/// canvas label-text renderer (which notes that short ids matter:
/// "ann-1", "ann-23" etc. easily fit; long ids get clipped).
///
/// Deliberately NOT the production frontend's scheme —
/// `frontend/src/main.js:1066` uses
/// `newId(prefix) = prefix + "_" + random_base36_7`, e.g.
/// `obj_ab12cd3`. Random ids are untestable and unbounded in
/// length, which is the wrong trade for a native canvas that
/// renders the id as on-canvas label text.
pub let annotation_id_prefix : String = "ann-"

///|
/// Phase 5.8 — the id prefix for user-created bindings.
pub let binding_id_prefix : String = "bind-"

///|
/// Phase 5.8 — smallest positive integer `n >= from` such that
/// `prefix + n` is not present in `taken`. Returns `from` when
/// every candidate is already used.
///
/// Used by `next_annotation_id` / `next_binding_id` so a deleted
/// id is never handed out again to a *new* annotation while an
/// older one still exists — e.g. with annotations `ann-1`, `ann-3`
/// present, the next id is `ann-4` (not `ann-2`, which would be
/// free but would break the "ids increase monotonically within a
/// session" expectation that the label JSON round-trip relies on).
fn first_free_suffix(
  taken : Array[String],
  prefix : String,
  from : Int,
) -> Int {
  let n = taken.length()
  let mut candidate = from
  let mut searching = true
  while searching {
    let probe : String = prefix + candidate.to_string()
    let mut used = false
    let mut i = 0
    while i < n {
      if taken[i] == probe {
        used = true
      }
      i = i + 1
    }
    if used {
      candidate = candidate + 1
    } else {
      searching = false
    }
  }
  candidate
}

///|
/// Phase 5.8 — allocate an id for a new annotation. Deterministic
/// (no RNG), so a given model state always yields the same id and
/// the behaviour is unit-testable.
fn next_annotation_id(model : Model) -> String {
  let taken : Array[String] = []
  for ann in model.annotations {
    taken.push(ann.id)
  }
  annotation_id_prefix + first_free_suffix(
    taken,
    annotation_id_prefix,
    1,
  ).to_string()
}

///|
/// Phase 5.8 — allocate an id for a new binding.
fn next_binding_id(model : Model) -> String {
  let taken : Array[String] = []
  for b in model.bindings {
    taken.push(b.id)
  }
  binding_id_prefix + first_free_suffix(taken, binding_id_prefix, 1).to_string()
}

///|
/// Phase 5.8 — the `class_id` a newly created annotation gets. Since
/// 5.17 an explicit choice made in the sidebar wins: if the user has
/// clicked a class row, `model.activeClassId` is that class, and it
/// outranks the project's own `is_default` flag. Before this the
/// flag was the *only* source, which is why the sidebar's class rows
/// had nothing to dispatch — there was no state for a click to set.
fn default_class_id(model : Model) -> String {
  if model.activeClassId != "" {
    return model.activeClassId
  }
  for c in model.classes {
    if c.is_default {
      return c.id
    }
  }
  ""
}

///|
/// Phase 5.18 — what switching to a different image means.
///
/// Phase 5.17 made the sidebar's folder rows dispatch `SelectIndex`,
/// which turned a latent bug into the first thing a user does. The
/// handler only moved `currentIndex` and cleared `selectedId`, so
/// **the previous image's annotations, bindings and label stayed on
/// screen under the new image's name**. In a labelling tool that is
/// the expensive kind of wrong: those annotations would be saved
/// against the new file.
///
/// Annotations belong to an image, not to the application, so this is
/// the only correct answer. Note what is deliberately **kept**:
///
///  - `folder`, `images`, `videos`, `labelFolder` — the project's
///    file list.
///  - `classes`, `activeClassId`, `classType` — the class list is a
///    property of the project, not of an image, and 5.17 just gave
///    the user a way to pick one. Losing that on every image switch
///    would regress a feature one phase old.
///  - `imageSource` — see the honesty note below.
///
/// The in-progress drawing state (`draftPoints`, `bindingFromId`,
/// `mode`, the cursor, the viewport) is reset too: a rubber-band
/// half-drawn on the old image, or a keypoint tool still armed, means
/// nothing on the new one.
///
/// **Honesty note on `imageSource`.** The pixels are *not* reloaded
/// here. This note used to say that was impossible — "`Effect::Task` is
/// declared and counted in the effect-plan summary but never executed
/// by the runtime, so there is no async path out of a sync `update` to
/// read a file with." **That was a misreading and is now corrected**
/// (see `disk_io.mbt`): `Effect::Task` *is* executed, and `x/fs` reads
/// synchronously. The label half is therefore implemented as of 5.22 —
/// `image_selected` loads it. The *pixel* half is still not: decoding
/// an image is a second step after the read (`decode_image_bytes` plus
/// an `ImageCache::load`, neither wired to a `SelectIndex`), and until
/// that exists the previous image's pixels stay on screen.
///
/// That is still the lesser evil — stale pixels are visibly stale,
/// whereas misattributed *annotations* are silent — but it is now a
/// plain unfinished feature rather than an impossibility, and the
/// annotations are correct.
pub fn state_for_image_change(model : Model, idx : Int) -> Model {
  let name : String = if idx >= 0 && idx < model.images.length() {
    model.images[idx].name
  } else {
    ""
  }
  {
    ..model,
    currentIndex: idx,
    // Per-image data — must not follow the user to another file.
    annotations: [],
    bindings: [],
    label: { raw_json: "{}", dirty: false, },
    labelPath: "",
    loadedFromDisk: false,
    // Work in progress on the previous image.
    selectedId: None,
    mode: Select,
    draftPoints: [],
    bindingFromId: None,
    cursorImgPt: None,
    cursorCanvasPt: None,
    // Viewport is per-image: a zoom into one scan is meaningless on
    // the next, and carrying it over reads as a rendering fault.
    pan: { x: 0.0, y: 0.0, },
    zoom: 1.0,
    fitMode: @core.ImageFit::Contain,
    statusMessage: if name == "" { "No image" } else { "Image: " + name },
    staticLayerDirty: true,
    dynamicLayerDirty: true,
  }
}

///|
/// Phase 5.22 — apply a folder scan to the model. Shared by
/// `LoadFolder` (which scans) and `FolderLoaded` (which receives an
/// already-scanned result), so the two cannot disagree about what
/// "loaded" means.
///
/// `currentIndex` becomes 0 for a non-empty folder and **-1** for an
/// empty one. -1 is the sentinel `state_for_image_change` and the
/// sidebar already treat as "no image selected", so an empty folder
/// does not leave row 0 falsely highlighted.
pub fn folder_loaded(
  model : Model,
  images : Array[ImageEntry],
  videos : Array[VideoEntry],
  folder : String,
  label_folder : String,
) -> Model {
  let n : Int = images.length()
  let loaded = state_for_image_change(model, if n > 0 { 0 } else { -1 })
  {
    ..loaded,
    folder,
    labelFolder: label_folder,
    images,
    videos,
    statusMessage: "Loaded " +
    n.to_string() +
    " images, " +
    videos.length().to_string() +
    " videos",
  }
}

///|
/// Phase 5.22 — load one image's label file off disk into the model.
///
/// Pure in signature only: it reads, but it reads nothing mutable and
/// returns the whole new Model, so every branch is still assertable.
/// Both the "there is a file" and "there is no file" paths are
/// ordinary outcomes — an un-annotated image has no label file, and
/// treating that as an error would put a red toast on screen every
/// time a user clicks an unlabelled scan.
///
/// **Missing file is not the same as empty file.** No file resets the
/// canvas and says "No label"; a file that exists but fails to parse
/// arrives through `load_label`'s `Some` arm with its `raw_json`
/// intact, so the text is still there to be re-saved rather than
/// silently overwritten with an empty annotation set.
pub fn read_label_into(model : Model, image_path : String) -> Model {
  let path : String = label_path_for(image_path, model.labelFolder)
  let image_name : String = path_basename(image_path)
  match load_label(path, model.classes) {
    None =>
      {
        ..model,
        label: { raw_json: "{}", dirty: false, },
        labelPath: path,
        loadedFromDisk: false,
        annotations: [],
        bindings: [],
        selectedId: None,
        dragState: None,
        staticLayerDirty: true,
        dynamicLayerDirty: true,
        statusMessage: image_name + ": no label",
      }
    Some((label, annotations, bindings)) =>
      {
        ..model,
        label,
        labelPath: path,
        loadedFromDisk: true,
        annotations,
        bindings,
        selectedId: None,
        dragState: None,
        staticLayerDirty: true,
        dynamicLayerDirty: true,
        statusMessage: image_name +
        ": " +
        annotations.length().to_string() +
        " annotations",
      }
  }
}

///|
/// Phase 5.22 — selecting an image loads its label. This is what
/// makes the disk read **reachable**: `SelectIndex` is already wired
/// to the sidebar's image rows (Phase 5.17), so without this the read
/// code would be correct and unreachable.
///
/// 5.18 established that switching images must not carry the previous
/// image's data, so the reset runs *first* and the load overwrites
/// only what it owns. A bad index leaves the reset in place and loads
/// nothing — there is no image to read a label for.
pub fn image_selected(model : Model, idx : Int) -> Model {
  let reset : Model = state_for_image_change(model, idx)
  if idx >= 0 && idx < reset.images.length() {
    read_label_into(reset, reset.images[idx].path)
  } else {
    reset
  }
}

///|
/// Phase 5.22 — write the current label back to disk.
///
/// Returns `(path, ok)` so the caller can report precisely. Saves to
/// `model.labelPath`, the path `read_label_into` resolved — **not** to
/// a freshly derived one. That is the safety property: `labelPath` is
/// empty until an image has actually been read, so pressing Save
/// before that cannot invent a filename and drop a stray JSON into the
/// working directory.
pub fn save_label_to_disk(model : Model) -> (String, Bool) {
  if model.labelPath.length() == 0 {
    return ("", false)
  }
  let path : String = model.labelPath
  let ok : Bool = write_label_text(path, serialize_label_text(model))
  (path, ok)
}

///|
/// Phase 5.21 — rename a class: move the display name, nothing else.
///
/// Pure and total, so both entry points (`UpdateClass` and
/// `CommitRename` from the sidebar) share it and cannot drift.
///
/// Annotations store the class **id** and `class_lookup_name` resolves
/// it through `model.classes` at draw time, so every on-canvas label
/// follows the rename with **no annotation being touched**. A rename
/// is still a label edit — the on-disk name changed — so
/// `label.dirty` is set, but only when the class exists: renaming
/// something that is not there must not dirty a label, or the user
/// gets an unsaved-changes prompt for nothing.
pub fn renamed_class(model : Model, id : String, new_name : String) -> Model {
  if !model.classes.iter().any(c => c.id == id) {
    return { ..model, statusMessage: "No such class: " + id, }
  }
  let renamed : Array[ClassEntry] = model.classes.map(c => {
    ..c,
    name: if c.id == id { new_name } else { c.name },
  })
  {
    ..model,
    classes: renamed,
    statusMessage: "Renamed class: " + new_name,
    label: { raw_json: model.label.raw_json, dirty: true, },
    staticLayerDirty: true,
  }
}

///|
/// Phase 5.8 — normalise a rect's two corners to (top-left,
/// bottom-right). The stored convention is `points[0] = TL,
/// points[1] = BR`; Phase 5.7 established that the *rendering and
/// hit-test* code tolerates either order, but storing the canonical
/// order keeps the on-disk JSON stable and makes the eight handles
/// index-meaningful.
fn normalize_rect_corners(
  a : Point,
  b : Point,
) -> (Point, Point) {
  let tl : Point = { x: if a.x < b.x { a.x } else { b.x },
                     y: if a.y < b.y { a.y } else { b.y } }
  let br : Point = { x: if a.x > b.x { a.x } else { b.x },
                     y: if a.y > b.y { a.y } else { b.y } }
  (tl, br)
}

///|
/// Phase 5.8 — a rect is only worth creating if it has real area.
/// A click (press + release with no movement) yields a zero-size
/// rect, which would render as a 1px sliver and leave an
/// un-deletable speck in the label. Callers treat a degenerate rect
/// as "no annotation drawn" and leave the model untouched.
fn rect_is_degenerate(a : Point, b : Point) -> Bool {
  a.x == b.x || a.y == b.y
}

///|
/// Phase 5.4 — pure helper that runs `f` against the annotation
/// with matching `ann_id` in `model.annotations`, replacing it
/// when `f` returns `Some(new_ann)` and leaving the model
/// unchanged otherwise (no match, or `f` rejected the
/// transformation). The new model always has `staticLayerDirty =
/// true` + `label.dirty = true` so the cache invalidates and
/// the next save picks up the change. Used by `ModifyHandle`
/// (with `apply_handle_move` as `f`); future Msg handlers
/// (delete vertex, insert vertex, change shape) can reuse it.
fn mutate_annotation(
  model : Model,
  ann_id : String,
  f : (Annotation) -> Annotation?,
) -> (Model, @moui.Effect[Msg]) {
  let n = model.annotations.length()
  let mut found_idx : Int = -1
  let mut replacement : Annotation? = None
  let mut i = 0
  while i < n {
    if model.annotations[i].id == ann_id {
      found_idx = i
      replacement = f(model.annotations[i])
      break
    }
    i = i + 1
  }
  match replacement {
    Some(updated) => {
      let new_anns : Array[Annotation] = []
      let mut j = 0
      while j < n {
        if j == found_idx {
          new_anns.push(updated)
        } else {
          new_anns.push(model.annotations[j])
        }
        j = j + 1
      }
      (
        {
          ..model,
          annotations: new_anns,
          label: { raw_json: model.label.raw_json, dirty: true, },
          staticLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    }
    None => (model, @moui.Effect::none())
  }
}

// ─────────────────────────────────────────────────────────────────
// View — placeholder shell using @views
// ─────────────────────────────────────────────────────────────────

///|
pub fn view(model : Model) -> @moui.View[Msg] {
  // Phase 18.A — delegate to build_labeler_ui_view for the
  // full labeler UI (toolbar + sidebar + canvas + status bar).
  // The Phase 5.x placeholder split_view (Folder/Images/Classes
  // text + Fit/Reset/Delete buttons) is replaced; the same Msg
  // handlers (FitView, ResetZoomTransformView, LoadFolder,
  // SetMode, SetClassType, etc.) are wired into the new toolbar
  // and sidebar buttons.
  //
  // We pass `model.viewport` as the initial layout size, which
  // `main_native.mbt` sets from the same constants it hands the
  // runtime. Moui's flex layout resizes the tree on window-resize
  // events automatically, but the view still needs a real number to
  // bound the canvas with — see `Model::viewport`.
  build_labeler_ui_view(model, model.viewport.width, model.viewport.height)
}

// ─────────────────────────────────────────────────────────────────
// Program factory
// ─────────────────────────────────────────────────────────────────

///|
pub fn program() -> @moui.Program[Model, Msg] {
  @moui.Program::new(
    init=() => (Model::new(), @moui.Effect::none()),
    update~,
    view~,
  )
}

///|
/// Phase 5.4 — alternate program factory that lets the caller
/// supply a custom initial `Model`. Used by `main_native.mbt`'s
/// smoke harness to demonstrate that `ModifyHandle` actually
/// mutates the annotation set: the harness builds a Model via
/// `Model::new()`, dispatches a BeginDragHandle + CursorMoved +
/// ModifyHandle + EndDragHandle sequence, and passes the
/// post-drag model to `program_with_init` so the smoke
/// screenshot shows the rect-1 BR corner at its
/// drag-end position instead of the original `(140, 140)`.
pub fn program_with_init(
  initial : Model,
) -> @moui.Program[Model, Msg] {
  @moui.Program::new(
    init=() => (initial, @moui.Effect::none()),
    update~,
    view~,
  )
}

// ─────────────────────────────────────────────────────────────────
// Entry — minimal main that proves the package compiles end-to-end.
// Real platform entrypoints (windows_skia / linux_skia / macos_skia /
// web_wasm) live in sibling packages and call @runtime.new_program
// + .run_app("MoonBit Labeler", runtime).backend(@<plat>.entry()).
// ─────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────
// Entry — Phase 10 moved the windows_skia launcher to
// main_native.mbt (where the @runtime / @windows imports and
// the native-stub C/C++ linker directives live). The remaining
// sub-routines below (`program`, `view`) are used by both the
// test environment (where `program` is called for blackbox
// tests via `update` / `init`) and the runtime (where
// `main_native.mbt`'s `main` constructs the same Program).
// ─────────────────────────────────────────────────────────────────
