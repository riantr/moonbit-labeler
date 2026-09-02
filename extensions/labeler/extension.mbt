///| ---------------------------------------------------------------
/// 0.2.5 Proton extension registration for the labeler backend.
///
/// Defines all 18 IPC ops as `ext:labeler/<op>` and binds them to the
/// existing `op_*` handlers in `labeler.mbt`. The frontend invokes
/// these via `window.__MoonBit__.core.invokeOp("ext:labeler/<op>", payload)`.
///
/// The shape mirrors the 0.1.12 `@proton_command` annotation that
/// `labeler.extension()` used to expose: same op names, same Request/
/// Reply structs, same JSON wire format — so the frontend keeps working
/// unchanged.
/// ---------------------------------------------------------------

///|
pub fn extension() -> @proton_extension.Extension {
  // Command values, one per op. Type ascription drives the generic
  // parameter resolution for @proton_contract.command.
  let cmd_list_images : @proton_contract.Command[ListImagesRequest, ListImagesReply] = @proton_contract.command(
    "list_images",
  )
  let cmd_read_image : @proton_contract.Command[ReadImageRequest, ReadImageReply] = @proton_contract.command(
    "read_image",
  )
  let cmd_read_thumb : @proton_contract.Command[ReadThumbRequest, ReadImageReply] = @proton_contract.command(
    "read_thumb",
  )
  let cmd_decode_image : @proton_contract.Command[DecodeImageRequest, ReadImageReply] = @proton_contract.command(
    "decode_image",
  )
  let cmd_resize_image : @proton_contract.Command[ResizeImageRequest, ReadImageReply] = @proton_contract.command(
    "resize_image",
  )
  let cmd_read_text : @proton_contract.Command[ReadTextRequest, ReadTextReply] = @proton_contract.command(
    "read_text",
  )
  let cmd_write_text : @proton_contract.Command[WriteTextRequest, WriteTextReply] = @proton_contract.command(
    "write_text",
  )
  let cmd_read_label : @proton_contract.Command[ReadLabelRequest, ReadLabelReply] = @proton_contract.command(
    "read_label",
  )
  let cmd_write_label : @proton_contract.Command[WriteLabelRequest, WriteLabelReply] = @proton_contract.command(
    "write_label",
  )
  let cmd_scan_classes : @proton_contract.Command[ScanClassesRequest, ScanClassesReply] = @proton_contract.command(
    "scan_classes",
  )
  let cmd_save_classes : @proton_contract.Command[SaveClassesRequest, SaveClassesReply] = @proton_contract.command(
    "save_classes",
  )
  let cmd_load_classes : @proton_contract.Command[LoadClassesRequest, LoadClassesReply] = @proton_contract.command(
    "load_classes",
  )
  let cmd_load_classes_from_file : @proton_contract.Command[LoadClassesFromFileRequest, LoadClassesReply] = @proton_contract.command(
    "load_classes_from_file",
  )
  let cmd_list_videos : @proton_contract.Command[ListVideosRequest, ListVideosReply] = @proton_contract.command(
    "list_videos",
  )
  let cmd_read_video_info : @proton_contract.Command[ReadVideoInfoRequest, ReadVideoInfoReply] = @proton_contract.command(
    "read_video_info",
  )
  let cmd_read_video_frame : @proton_contract.Command[ReadVideoFrameRequest, ReadVideoFrameReply] = @proton_contract.command(
    "read_video_frame",
  )
  let cmd_export_voc_folder : @proton_contract.Command[ExportVocRequest, ExportReply] = @proton_contract.command(
    "export_voc_folder",
  )
  let cmd_export_yolo_folder : @proton_contract.Command[ExportYoloRequest, ExportReply] = @proton_contract.command(
    "export_yolo_folder",
  )
  let contract = @proton_contract.extension(
    id="moonbit-labeler",
    js_namespace="labeler",
  )
  let routes = [
    cmd_list_images.contract_route(),
    cmd_read_image.contract_route(),
    cmd_read_thumb.contract_route(),
    cmd_decode_image.contract_route(),
    cmd_resize_image.contract_route(),
    cmd_read_text.contract_route(),
    cmd_write_text.contract_route(),
    cmd_read_label.contract_route(),
    cmd_write_label.contract_route(),
    cmd_scan_classes.contract_route(),
    cmd_save_classes.contract_route(),
    cmd_load_classes.contract_route(),
    cmd_load_classes_from_file.contract_route(),
    cmd_list_videos.contract_route(),
    cmd_read_video_info.contract_route(),
    cmd_read_video_frame.contract_route(),
    cmd_export_voc_folder.contract_route(),
    cmd_export_yolo_folder.contract_route(),
  ]
  @proton_extension.typed(
    contract,
    routes,
    fn(registrar) {
      // Each handler is wrapped to discard the AppCommandRequestContext
      // and forward only the request payload to the existing op_* function.
      registrar.bind(cmd_list_images, fn(_ctx, req) { op_list_images(req) })
      registrar.bind(cmd_read_image, fn(_ctx, req) { op_read_image(req) })
      registrar.bind(cmd_read_thumb, fn(_ctx, req) { op_read_thumb(req) })
      registrar.bind(cmd_decode_image, fn(_ctx, req) { op_decode_image(req) })
      registrar.bind(cmd_resize_image, fn(_ctx, req) { op_resize_image(req) })
      registrar.bind(cmd_read_text, fn(_ctx, req) { op_read_text(req) })
      registrar.bind(cmd_write_text, fn(_ctx, req) { op_write_text(req) })
      registrar.bind(cmd_read_label, fn(_ctx, req) { op_read_label(req) })
      registrar.bind(cmd_write_label, fn(_ctx, req) { op_write_label(req) })
      registrar.bind(cmd_scan_classes, fn(_ctx, req) { op_scan_classes(req) })
      registrar.bind(cmd_save_classes, fn(_ctx, req) { op_save_classes(req) })
      registrar.bind(cmd_load_classes, fn(_ctx, req) { op_load_classes(req) })
      registrar.bind(
        cmd_load_classes_from_file,
        fn(_ctx, req) { op_load_classes_from_file(req) },
      )
      registrar.bind(cmd_list_videos, fn(_ctx, req) { op_list_videos(req) })
      registrar.bind(
        cmd_read_video_info,
        fn(_ctx, req) { op_read_video_info(req) },
      )
      registrar.bind(
        cmd_read_video_frame,
        fn(_ctx, req) { op_read_video_frame(req) },
      )
      registrar.bind(
        cmd_export_voc_folder,
        fn(_ctx, req) { op_export_voc_folder(req) },
      )
      registrar.bind(
        cmd_export_yolo_folder,
        fn(_ctx, req) { op_export_yolo_folder(req) },
      )
    },
  )
}
