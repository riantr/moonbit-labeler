///| ---------------------------------------------------------------
/// 0.2.5 Proton extension registration for the labeler backend.
///
/// Defines the 21 IPC ops as `ext:labeler/<op>` and binds them to the
/// existing `op_*` handlers in `labeler.mbt`. The frontend invokes
/// these via `window.__MoonBit__.core.invokeOp("ext:labeler/<op>", payload)`.
///
/// ## Op surface
///
/// | op                          | request                  | reply                  |
/// |-----------------------------|--------------------------|------------------------|
/// | list_images                 | ListImagesRequest        | ListImagesReply       |
/// | read_image                  | ReadImageRequest         | ReadImageReply        |
/// | read_thumb                  | ReadThumbRequest         | ReadImageReply        |
/// | decode_image                | DecodeImageRequest       | ReadImageReply        |
/// | resize_image                | ResizeImageRequest       | ReadImageReply        |
/// | read_text                   | ReadTextRequest          | ReadTextReply         |
/// | write_text                  | WriteTextRequest         | WriteTextReply        |
/// | read_label                  | ReadLabelRequest         | ReadLabelReply        |
/// | write_label                 | WriteLabelRequest        | WriteLabelReply       |
/// | parse_label                 | ParseLabelRequest        | ParseLabelReply       |
/// | serialize_label             | SerializeLabelRequest    | SerializeLabelReply   |
/// | scan_classes                | ScanClassesRequest       | ScanClassesReply      |
/// | save_classes                | SaveClassesRequest       | SaveClassesReply      |
/// | load_classes                | LoadClassesRequest       | LoadClassesReply      |
/// | load_classes_from_file      | LoadClassesFromFileRequest| LoadClassesReply     |
/// | list_videos                 | ListVideosRequest        | ListVideosReply       |
/// | read_video_info             | ReadVideoInfoRequest     | ReadVideoInfoReply    |
/// | read_video_frame            | ReadVideoFrameRequest    | ReadVideoFrameReply   |
/// | export_voc_folder           | ExportVocRequest         | ExportReply           |
/// | export_yolo_folder          | ExportYoloRequest        | ExportReply           |
/// | pick_folder                 | PickFolderRequest        | PickFolderReply       |
///
/// The shape mirrors the 0.1.12 `@proton_command` annotation that
/// `labeler.extension()` used to expose: same op names, same Request/
/// Reply structs, same JSON wire format — so the frontend keeps working
/// unchanged.
///
/// **0.2.5 routing gotcha:** the top-level `@proton_contract.command(name, ...)`
/// produces a `Command` with `scope = Application` (route = `app:<op>`),
/// NOT `scope = Extension`. You must build each command via
/// `contract.command(name, ...)` so the route gets the
/// `Extension(id, js_namespace)` scope. The framework's
/// `ExtensionSpecError::ForeignCommandRoute` rejects Application-scoped
/// routes when the `command_routes` array is filtered by extension id
/// + namespace, which is why calling top-level `command(...)` here
/// would panic with `command route app:list_images does not belong
/// to extension moonbit-labeler`.
/// ---------------------------------------------------------------

///|
pub fn extension() -> @proton_extension.Extension {
  // Build the extension contract first. Commands created from this
  // contract carry `scope = Extension("moonbit-labeler", "labeler")`
  // which is what the framework's typed registrar filters by.
  let contract = @proton_contract.extension(
    id="moonbit-labeler",
    js_namespace="labeler",
  )
  // Each command is created via `contract.command(name, ...)` so the
  // route lives under the `ext:labeler/` namespace. Type ascription
  // drives the generic parameter resolution for the Request/Reply pair.
  let list_images : @proton_contract.Command[ListImagesRequest, ListImagesReply] = contract.command(
    "list_images",
  )
  let read_image : @proton_contract.Command[ReadImageRequest, ReadImageReply] = contract.command(
    "read_image",
  )
  let read_thumb : @proton_contract.Command[ReadThumbRequest, ReadImageReply] = contract.command(
    "read_thumb",
  )
  let decode_image : @proton_contract.Command[DecodeImageRequest, ReadImageReply] = contract.command(
    "decode_image",
  )
  let resize_image : @proton_contract.Command[ResizeImageRequest, ReadImageReply] = contract.command(
    "resize_image",
  )
  let read_text : @proton_contract.Command[ReadTextRequest, ReadTextReply] = contract.command(
    "read_text",
  )
  let write_text : @proton_contract.Command[WriteTextRequest, WriteTextReply] = contract.command(
    "write_text",
  )
  let read_label : @proton_contract.Command[ReadLabelRequest, ReadLabelReply] = contract.command(
    "read_label",
  )
  let write_label : @proton_contract.Command[WriteLabelRequest, WriteLabelReply] = contract.command(
    "write_label",
  )
  // parse_label / serialize_label round-trip the in-memory label through
  // the Moon-side schema normalizer. The frontend `label.js` calls them
  // on every save and load; without these registrations the bridge
  // returns "bridge op is not registered" and the autosave status bar
  // gets stuck on "保存失败".
  let parse_label : @proton_contract.Command[ParseLabelRequest, ParseLabelReply] = contract.command(
    "parse_label",
  )
  let serialize_label : @proton_contract.Command[SerializeLabelRequest, SerializeLabelReply] = contract.command(
    "serialize_label",
  )
  let scan_classes : @proton_contract.Command[ScanClassesRequest, ScanClassesReply] = contract.command(
    "scan_classes",
  )
  let save_classes : @proton_contract.Command[SaveClassesRequest, SaveClassesReply] = contract.command(
    "save_classes",
  )
  let load_classes : @proton_contract.Command[LoadClassesRequest, LoadClassesReply] = contract.command(
    "load_classes",
  )
  let load_classes_from_file : @proton_contract.Command[LoadClassesFromFileRequest, LoadClassesReply] = contract.command(
    "load_classes_from_file",
  )
  let list_videos : @proton_contract.Command[ListVideosRequest, ListVideosReply] = contract.command(
    "list_videos",
  )
  let read_video_info : @proton_contract.Command[ReadVideoInfoRequest, ReadVideoInfoReply] = contract.command(
    "read_video_info",
  )
  let read_video_frame : @proton_contract.Command[ReadVideoFrameRequest, ReadVideoFrameReply] = contract.command(
    "read_video_frame",
  )
  let export_voc_folder : @proton_contract.Command[ExportVocRequest, ExportReply] = contract.command(
    "export_voc_folder",
  )
  let export_yolo_folder : @proton_contract.Command[ExportYoloRequest, ExportReply] = contract.command(
    "export_yolo_folder",
  )
  let pick_folder : @proton_contract.Command[PickFolderRequest, PickFolderReply] = contract.command(
    "pick_folder",
  )
  // Routes: belt-and-suspenders sanity check. If a command is declared
  // but missing from this list, the framework panics with
  // `ForeignCommandRoute` at startup. A missing bind call (in the
  // registrar below) wouldn't trip the framework check, so we keep
  // this list ordered to match the `bind` block — that's a manual
  // visual check during code review.
  let routes = [
    list_images.contract_route(),
    read_image.contract_route(),
    read_thumb.contract_route(),
    decode_image.contract_route(),
    resize_image.contract_route(),
    read_text.contract_route(),
    write_text.contract_route(),
    read_label.contract_route(),
    write_label.contract_route(),
    parse_label.contract_route(),
    serialize_label.contract_route(),
    scan_classes.contract_route(),
    save_classes.contract_route(),
    load_classes.contract_route(),
    load_classes_from_file.contract_route(),
    list_videos.contract_route(),
    read_video_info.contract_route(),
    read_video_frame.contract_route(),
    export_voc_folder.contract_route(),
    export_yolo_folder.contract_route(),
    pick_folder.contract_route(),
  ]
  @proton_extension.typed(
    contract,
    routes,
    (registrar) => {
      // 20 of 21 handlers are stateless and just discard the
      // AppCommandRequestContext. Only `pick_folder` keeps the
      // context because it needs the CEF `CommandWindow` to drive
      // the native folder dialog. The wrap-in-closure is a
      // typed-registrar requirement (signature is
      // `async (CommandContext, Request) -> Response`).
      registrar.bind(list_images, (_ctx, req) => op_list_images(req))
      registrar.bind(read_image, (_ctx, req) => op_read_image(req))
      registrar.bind(read_thumb, (_ctx, req) => op_read_thumb(req))
      registrar.bind(decode_image, (_ctx, req) => op_decode_image(req))
      registrar.bind(resize_image, (_ctx, req) => op_resize_image(req))
      registrar.bind(read_text, (_ctx, req) => op_read_text(req))
      registrar.bind(write_text, (_ctx, req) => op_write_text(req))
      registrar.bind(read_label, (_ctx, req) => op_read_label(req))
      registrar.bind(write_label, (_ctx, req) => op_write_label(req))
      registrar.bind(parse_label, (_ctx, req) => op_parse_label(req))
      registrar.bind(serialize_label, (_ctx, req) => op_serialize_label(req))
      registrar.bind(scan_classes, (_ctx, req) => op_scan_classes(req))
      registrar.bind(save_classes, (_ctx, req) => op_save_classes(req))
      registrar.bind(load_classes, (_ctx, req) => op_load_classes(req))
      registrar.bind(load_classes_from_file, (_ctx, req) => op_load_classes_from_file(req))
      registrar.bind(list_videos, (_ctx, req) => op_list_videos(req))
      registrar.bind(read_video_info, (_ctx, req) => op_read_video_info(req))
      registrar.bind(read_video_frame, (_ctx, req) => op_read_video_frame(req))
      registrar.bind(export_voc_folder, (_ctx, req) => op_export_voc_folder(req))
      registrar.bind(export_yolo_folder, (_ctx, req) => op_export_yolo_folder(req))
      // pick_folder keeps the context (the only one of the 21 that does).
      registrar.bind(pick_folder, (ctx, req) => op_pick_folder(ctx, req))
    },
  )
}
