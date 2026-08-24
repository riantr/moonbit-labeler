// Stdio JSON-RPC dispatcher for the labeler extension.
//
// The original `extension()` function in this package registered 18
// op_handlers with the Proton IPC layer (`ext:labeler/<op>`). This
// file provides an alternative entry point: a single `dispatch_op`
// function that the `bin/labeler_stdio` binary can call over
// stdin/stdout JSON-RPC, without involving CEF/Chromium or Proton.
//
// Protocol (one line per request, one line per response):
//
//   req : {"id": <int>, "op": "<name>", "payload": <op-specific-json>}
//   resp: {"id": <int>, "ok": true,  "result": <op-specific-json>}
//         {"id": <int>, "ok": false, "error": "<message>"}
//
// The op names match the CEF op names with the `ext:labeler/` prefix
// stripped, so `list_images`, `read_image`, etc.

///|
/// Top-level dispatcher. Parses `payload` into the op's Request
/// struct, invokes the matching op_handler, and serializes the
/// Reply struct back to JSON. Errors raised by the handler
/// propagate to the caller.
pub async fn dispatch_op(op : String, payload : Json) -> Json raise {
  match op {
    "list_images" => {
      let req : ListImagesRequest = @json.from_json(payload)
      op_list_images(req).to_json()
    }
    "read_image" => {
      let req : ReadImageRequest = @json.from_json(payload)
      op_read_image(req).to_json()
    }
    "read_thumb" => {
      let req : ReadThumbRequest = @json.from_json(payload)
      op_read_thumb(req).to_json()
    }
    "decode_image" => {
      let req : DecodeImageRequest = @json.from_json(payload)
      op_decode_image(req).to_json()
    }
    "resize_image" => {
      let req : ResizeImageRequest = @json.from_json(payload)
      op_resize_image(req).to_json()
    }
    "read_text" => {
      let req : ReadTextRequest = @json.from_json(payload)
      op_read_text(req).to_json()
    }
    "write_text" => {
      let req : WriteTextRequest = @json.from_json(payload)
      op_write_text(req).to_json()
    }
    "read_label" => {
      let req : ReadLabelRequest = @json.from_json(payload)
      op_read_label(req).to_json()
    }
    "write_label" => {
      let req : WriteLabelRequest = @json.from_json(payload)
      op_write_label(req).to_json()
    }
    "scan_classes" => {
      let req : ScanClassesRequest = @json.from_json(payload)
      op_scan_classes(req).to_json()
    }
    "save_classes" => {
      let req : SaveClassesRequest = @json.from_json(payload)
      op_save_classes(req).to_json()
    }
    "load_classes" => {
      let req : LoadClassesRequest = @json.from_json(payload)
      op_load_classes(req).to_json()
    }
    "load_classes_from_file" => {
      let req : LoadClassesFromFileRequest = @json.from_json(payload)
      op_load_classes_from_file(req).to_json()
    }
    "list_videos" => {
      let req : ListVideosRequest = @json.from_json(payload)
      op_list_videos(req).to_json()
    }
    "read_video_info" => {
      let req : ReadVideoInfoRequest = @json.from_json(payload)
      op_read_video_info(req).to_json()
    }
    "read_video_frame" => {
      let req : ReadVideoFrameRequest = @json.from_json(payload)
      op_read_video_frame(req).to_json()
    }
    "export_voc_folder" => {
      let req : ExportVocRequest = @json.from_json(payload)
      op_export_voc_folder(req).to_json()
    }
    "export_yolo_folder" => {
      let req : ExportYoloRequest = @json.from_json(payload)
      op_export_yolo_folder(req).to_json()
    }
    _ => raise Failure::Failure("unknown op: " + op)
  }
}

///|
/// List of all supported op names. Useful for the Python side to
/// probe capability at startup.
pub fn dispatch_op_list() -> Array[String] {
  [
    "list_images", "read_image", "read_thumb", "decode_image", "resize_image",
    "read_text", "write_text", "read_label", "write_label", "scan_classes",
    "save_classes", "load_classes", "load_classes_from_file",
    "list_videos", "read_video_info", "read_video_frame",
    "export_voc_folder", "export_yolo_folder",
  ]
}
