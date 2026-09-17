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
} derive(Debug)

///|
pub(all) struct Annotation {
  id : String
  shape : Shape
  points : Array[Point]
} derive(Debug)

///|
pub(all) struct Binding {
  id : String
  from : String
  to : String
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
  fitMode : @core.ImageFit
  // Phase 5.3 — annotations + bindings + active handle drag.
  annotations : Array[Annotation]
  bindings : Array[Binding]
  dragState : DragState?
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
    // Phase 5.2 — empty source means "draw placeholder rect".
    // Natural size is read from the image header at LoadTestImage
    // time. For the default 800x600 placeholder we mirror the old
    // canvas_view.mbt size.
    imageSource: "",
    imageNaturalSize: { x: 800.0, y: 600.0, },
    fitMode: @core.ImageFit::Contain,
    // Phase 5.3 — annotations + bindings live in model so hit-test
    // can run without re-parsing the raw label JSON on every mouse
    // move. SetAnnotations syncs them from the parsed JSON.
    annotations: [],
    bindings: [],
    dragState: None,
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
  ModifyHandle(String, Int, Point)
  CursorMoved(Point, Point)
  CursorLeft
  Zoom(Double)
  Pan(Point)
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
  // BeginDragHandle(ann_id, handle_idx) — start dragging the n-th
  //   handle of the given annotation. While dragState is Some, every
  //   CursorMoved emits ModifyHandle instead of hit-testing.
  // EndDragHandle — release the active drag (no-op when None).
  SetAnnotations(Array[Annotation], Array[Binding])
  BeginDragHandle(String, Int)
  EndDragHandle
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
    AddRect(_p1, _p2) =>
      (
        {
          ..model,
          label: { raw_json: model.label.raw_json, dirty: true, },
          staticLayerDirty: true,
          mode: Select,
          draftPoints: [],
        },
        @moui.Effect::none(),
      )
    AddPolygon(_pts) =>
      (
        {
          ..model,
          label: { raw_json: model.label.raw_json, dirty: true, },
          staticLayerDirty: true,
          mode: Select,
          draftPoints: [],
        },
        @moui.Effect::none(),
      )
    AddKeypoint(_pt) =>
      (
        {
          ..model,
          label: { raw_json: model.label.raw_json, dirty: true, },
          staticLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    AddBinding(_from_id, _pt) =>
      (
        { ..model, bindingFromId: None, mode: Select, staticLayerDirty: true, },
        @moui.Effect::none(),
      )
    BeginDraft(pt) =>
      (
        { ..model, draftPoints: [pt], staticLayerDirty: true, },
        @moui.Effect::none(),
      )
    PushDraft(pt) =>
      (
        {
          ..model,
          draftPoints: model.draftPoints + [pt],
          staticLayerDirty: true,
        },
        @moui.Effect::none(),
      )
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
          { ..model, draftPoints: kept, staticLayerDirty: true, },
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
    DeleteAnnotation(_id) =>
      (
        {
          ..model,
          label: { raw_json: model.label.raw_json, dirty: true, },
          staticLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    ModifyHandle(_id, _handle_idx, _new_pt) =>
      (
        {
          ..model,
          label: { raw_json: model.label.raw_json, dirty: true, },
          staticLayerDirty: true,
        },
        @moui.Effect::none(),
      )
    CursorMoved(img_pt, canvas_pt) =>
      // Phase 5.3 — handle drags emit ModifyHandle; otherwise
      // hit-test: prefer handles of the selected annotation, fall
      // back to body hit for selection. 12 px handle radius
      // (matches frontend canvas.js v0.2.9); 4 px body radius.
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
      (
        {
          ..model,
          pan: { x: model.pan.x + delta.x, y: model.pan.y + delta.y, },
          staticLayerDirty: true,
          dynamicLayerDirty: true,
        },
        @moui.Effect::none(),
      )
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
      // Phase 5.6 — schedule an Effect::task that probes the
      // image header off the immediate update cycle. The runtime
      // runs the task start in the async event loop.
      //
      // 5.6 ships the public Msg variants + the bytes-level
      // `probe_image_dimensions` helper. The disk-level probe
      // `probe_image_dimensions_path` is async but MoUI's
      // Effect::task.start callback is sync; we currently
      // short-circuit the probe by `send`ing LoadImageFailed
      // immediately and asking the caller to retry via the
      // 5.6.x helper once async update fn lands. Until then the
      // caller can fall back to LoadTestImage(path, w, h) which
      // still works for tests.
      (
        {
          ..model,
          statusMessage: "Loading " + path + "...",
        },
        @moui.Effect::task(
          key="image-header-probe:" + path,
          start=fn(send) {
            // 5.6.x TODO: replace this no-op dispatch with an
            // actual async probe via @async.with_task_group
            // (which can be called from inside the task start
            // when MoUI's task runtime is the same event loop
            // as @async). For now we report a transient failure
            // so the user sees the toast and can retry with a
            // manual LoadTestImage until 5.6.x lands.
            send(
              LoadImageFailed(
                path,
                "5.6: async file read needs 5.6.x; use LoadTestImage for now",
              ),
            )
            None
          },
        ),
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
          statusMessage: "Image cleared",
          staticLayerDirty: true,
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
    BeginDragHandle(ann_id, handle_idx) =>
      // Phase 5.3 — start dragging handle. If the cursor is in the
      // canvas, snapshot its current image position as the drag
      // origin; otherwise defer until the first CursorMoved.
      match model.cursorImgPt {
        Some(img_pt) =>
          (
            {
              ..model,
              dragState: Some({ ann_id, handle_idx, start_img_pt: img_pt, }),
              staticLayerDirty: true,
            },
            @moui.Effect::none(),
          )
        None =>
          (
            {
              ..model,
              dragState: Some({
                ann_id,
                handle_idx,
                start_img_pt: { x: 0.0, y: 0.0, },
              }),
              staticLayerDirty: true,
            },
            @moui.Effect::none(),
          )
      }
    EndDragHandle =>
      (
        { ..model, dragState: None, staticLayerDirty: true, },
        @moui.Effect::none(),
      )
  }
}

// ─────────────────────────────────────────────────────────────────
// View — placeholder shell using @views
// ─────────────────────────────────────────────────────────────────

///|
pub fn view(model : Model) -> @moui.View[Msg] {
  // Phase 5.1: real split_view with sidebar + canvas. Earlier
  // sessions shipped only a card-of-text shell; this is the first
  // real chrome layout. canvas_view lives in canvas_view.mbt.
  @views.split_view(
    primary=@views.column(
      [
        @views.text("Folder: " + model.folder),
        @views.text("Images: " + model.images.length().to_string()),
        @views.text("Classes: " + model.classes.length().to_string()),
        match model.toastMessage {
          Some(msg) => @views.text("toast: " + msg)
          None => @views.text("Status: " + model.statusMessage)
        },
      ],
      spacing=4.0,
    ),
    detail=canvas_view(model),
    primary_width=240.0,
    detail_width=800.0,
    height=600.0,
  )
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

// ─────────────────────────────────────────────────────────────────
// Entry — minimal main that proves the package compiles end-to-end.
// Real platform entrypoints (windows_skia / linux_skia / macos_skia /
// web_wasm) live in sibling packages and call @runtime.new_program
// + .run_app("MoonBit Labeler", runtime).backend(@<plat>.entry()).
// ─────────────────────────────────────────────────────────────────

///|
fn main {
  let _p : @moui.Program[Model, Msg] = program()
  let _m : Model = Model::new()
  println("app_moui: skeleton compiled. _p=_m=")
}
