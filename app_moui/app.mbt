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
    // Phase 5.2 — empty source means "draw placeholder rect".
    // Natural size is read from the image header at LoadTestImage
    // time. For the default 800x600 placeholder we mirror the old
    // canvas_view.mbt size.
    imageSource: "",
    imageNaturalSize: { x: 800.0, y: 600.0, },
    imageDecoded: None,
    fitMode: @core.ImageFit::Contain,
    // Phase 5.3 — annotations + bindings live in model so hit-test
    // can run without re-parsing the raw label JSON on every mouse
    // move. SetAnnotations syncs them from the parsed JSON.
    annotations: [],
    bindings: [],
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
  // BeginDragHandle(ann_id, handle_idx) — start dragging the n-th
  //   handle of the given annotation. While dragState is Some, every
  //   CursorMoved emits ModifyHandle instead of hit-testing.
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
  BeginDragHandle(String, Int)
  EndDragHandle
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
