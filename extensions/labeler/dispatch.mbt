// Stdio JSON-RPC dispatcher for the labeler extension.
//
// The original `extension()` function in this package registered 21
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
pub async fn dispatch_op(op : String, payload : Json) -> Json {
  match op {
    "list_images" => {
      let req : ListImagesRequest = @json.from_json(payload)
      ToJson::to_json(op_list_images(req))
    }
    "read_image" => {
      let req : ReadImageRequest = @json.from_json(payload)
      ToJson::to_json(op_read_image(req))
    }
    "read_thumb" => {
      let req : ReadThumbRequest = @json.from_json(payload)
      ToJson::to_json(op_read_thumb(req))
    }
    "decode_image" => {
      let req : DecodeImageRequest = @json.from_json(payload)
      ToJson::to_json(op_decode_image(req))
    }
    "resize_image" => {
      let req : ResizeImageRequest = @json.from_json(payload)
      ToJson::to_json(op_resize_image(req))
    }
    "read_text" => {
      let req : ReadTextRequest = @json.from_json(payload)
      ToJson::to_json(op_read_text(req))
    }
    "write_text" => {
      let req : WriteTextRequest = @json.from_json(payload)
      ToJson::to_json(op_write_text(req))
    }
    "read_label" => {
      let req : ReadLabelRequest = @json.from_json(payload)
      ToJson::to_json(op_read_label(req))
    }
    "write_label" => {
      let req : WriteLabelRequest = @json.from_json(payload)
      ToJson::to_json(op_write_label(req))
    }
    "parse_label" => {
      let req : ParseLabelRequest = @json.from_json(payload)
      ToJson::to_json(op_parse_label(req))
    }
    "serialize_label" => {
      let req : SerializeLabelRequest = @json.from_json(payload)
      ToJson::to_json(op_serialize_label(req))
    }
    "scan_classes" => {
      let req : ScanClassesRequest = @json.from_json(payload)
      ToJson::to_json(op_scan_classes(req))
    }
    "save_classes" => {
      let req : SaveClassesRequest = @json.from_json(payload)
      ToJson::to_json(op_save_classes(req))
    }
    "load_classes" => {
      let req : LoadClassesRequest = @json.from_json(payload)
      ToJson::to_json(op_load_classes(req))
    }
    "load_classes_from_file" => {
      let req : LoadClassesFromFileRequest = @json.from_json(payload)
      ToJson::to_json(op_load_classes_from_file(req))
    }
    "list_videos" => {
      let req : ListVideosRequest = @json.from_json(payload)
      ToJson::to_json(op_list_videos(req))
    }
    "read_video_info" => {
      let req : ReadVideoInfoRequest = @json.from_json(payload)
      ToJson::to_json(op_read_video_info(req))
    }
    "read_video_frame" => {
      let req : ReadVideoFrameRequest = @json.from_json(payload)
      ToJson::to_json(op_read_video_frame(req))
    }
    "export_voc_folder" => {
      let req : ExportVocRequest = @json.from_json(payload)
      ToJson::to_json(op_export_voc_folder(req))
    }
    "export_yolo_folder" => {
      let req : ExportYoloRequest = @json.from_json(payload)
      ToJson::to_json(op_export_yolo_folder(req))
    }
    "pick_folder" =>
      // The pick_folder op requires a CEF CommandWindow (calls the
      // native folder dialog). In stdio mode we have no GUI, so
      // there's no window to drive — return a clear "not available"
      // error rather than letting it bubble as an unknown op.
      raise Failure::Failure(
        "pick_folder is not available in stdio mode (CEF only); " +
        "use the webkit-pickers.js file-picker trick or run the exe " +
        "in CEF mode for the native dialog.",
      )
    _ => raise Failure::Failure("unknown op: " + op)
  }
}

///|
/// List of all supported op names. Useful for the Python side to
/// probe capability at startup. Includes `pick_folder` even though
/// the stdio dispatch raises on it (the op is CEF-only — see the
/// match arm); clients can detect the raise and fall back to a
/// non-native picker rather than treating the missing name as
/// "unsupported".
pub fn dispatch_op_list() -> Array[String] {
  [
    "list_images", "read_image", "read_thumb", "decode_image", "resize_image", "read_text",
    "write_text", "read_label", "write_label", "parse_label", "serialize_label",
    "scan_classes", "save_classes", "load_classes", "load_classes_from_file",
    "list_videos", "read_video_info", "read_video_frame",
    "export_voc_folder", "export_yolo_folder", "pick_folder",
  ]
}
