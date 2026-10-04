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
} derive(Debug)

///|
pub(all) enum Mode {
  Select
  Rect
  Polygon
  Keypoint
  EditBinding
} derive(Debug, Eq)

///|
pub(all) enum ClassType {
  Object
  Tag
  Binding
} derive(Debug)

///|
pub(all) enum ToastKind {
  Info
  Warn
  Error
} derive(Debug)

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
    draftPoints: [],
    bindingFromId: None,
    classes: [],
    // Phase 5.3 — default annotation set + binding. The smoke
    // screenshot demonstrates the full annotation rendering
    // pipeline (image + annotation bodies + binding arrows +
    // label text) without requiring a real .json label file
    // + a working sync→async file-read bridge. The synthetic
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
    // needing a real image file on disk + a working
    // sync→async file-read bridge (both still blocked —
    // see image_header.mbt doc).
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
/// Phase 5.3 — synthetic annotation set used by
/// `Model::new` to demonstrate the static-layer annotation
/// rendering pipeline (Rect fill+stroke, Polygon fill+stroke+vertex
/// dots, Keypoint fill+stroke, label text at centroid) in the
/// smoke screenshot without needing a real .json label file on
/// disk + a working sync→async file-read bridge (both still
/// blocked in moon 0.1.20260904 — see image_header.mbt doc).
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
    LoadFolder(_path) => (model, @moui.Effect::none())
    FolderLoaded(images, videos, folder, label_folder) =>
      (
        {
          ..model,
          folder,
          labelFolder: label_folder,
          images,
          videos,
          currentIndex: if images.length() > 0 {
            0
          } else {
            -1
          },
          statusMessage: "Loaded",
        },
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
    ScanClasses(_path) => (model, @moui.Effect::none())
    ClassesLoaded(classes) => ({ ..model, classes, }, @moui.Effect::none())
    SetMode(mode) =>
      (
        { ..model, mode, draftPoints: [], bindingFromId: None, },
        @moui.Effect::none(),
      )
    SetClassType(ct) => ({ ..model, classType: ct, }, @moui.Effect::none())
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
            mode: Select,
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
            mode: Select,
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
          // Stay in Keypoint mode for rapid tagging.
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
    FinishDraft =>
      (
        { ..model, draftPoints: [], mode: Select, staticLayerDirty: true, },
        @moui.Effect::none(),
      )
    CancelDraft =>
      (
        { ..model, draftPoints: [], mode: Select, staticLayerDirty: true, },
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
    UpdateClass(_id, _new_name) => (model, @moui.Effect::none())
    DeleteClass(_id) => (model, @moui.Effect::none())
    SetDefaultClass(_id) => (model, @moui.Effect::none())
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
    SelectIndex(idx) =>
      (
        {
          ..model,
          currentIndex: idx,
          selectedId: None,
          staticLayerDirty: true,
          dynamicLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    ReadLabelFor(_path) => (model, @moui.Effect::none())
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
    SaveLabel => (model, @moui.Effect::none())
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
      // image header. Currently the sync wrapper
      // probe_image_dimensions_path returns None because MoonBit
      // 0.1.20260904 + MoUI 0.1.12 don't expose a public
      // sync→async bridge (see image_header.mbt doc for the
      // three paths forward: async update fn, public
      // coroutine.spawn, or documented Pointer FFI). Until one
      // of those lands, LoadImage dispatches a transient
      // LoadImageFailed so the user sees a clean error rather
      // than a crash, and the loadable image path goes through
      // LoadTestImage (still supported as a deprecated shim).
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
/// Phase 5.8 — the `class_id` a newly created annotation gets: the
/// first class flagged `is_default` in `model.classes`, or `""` when
/// the project has no classes (or none marked default). `""` makes
/// `class_lookup_name` fall back to rendering the annotation's own
/// id as the on-canvas label, which is the same fallback the
/// synthetic Phase 5.3 demo annotations rely on.
fn default_class_id(model : Model) -> String {
  for c in model.classes {
    if c.is_default {
      return c.id
    }
  }
  ""
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
  // We pass `1280.0, 800.0` as the initial layout size to match
  // the @core.Size::new(width=1280, height=800) the windows
  // backend launches with (main_native.mbt). Moui's flex layout
  // resizes the tree on window-resize events automatically.
  build_labeler_ui_view(model, 1280.0, 800.0)
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
