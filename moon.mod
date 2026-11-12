name = "riantr/moonbit_labeler"

version = "0.2.16"

import {
  "moonbit-community/proton@0.9.0",
  "moonbit-community/proton_contract@0.9.0",
  "riantr/moonbit_image@0.3.9",
}

readme = "README.mbt.md"

repository = "https://github.com/riantr/moonbit-labeler"

license = "MIT"

keywords = [
  "labeling",
  "image-annotation",
  "voc",
  "yolo",
  "moonbit",
  "ipc",
  "json-rpc",
]

description = "Image / video labeling backend for the MoonBit Labeler app: 27 async ops over @fs/@json for folder browsing, image IO, label IO, schema normalization (parse/serialize round-trip), class management (including the class rename), per-frame video labels, and VOC/YOLO/COCO export. The op_handlers are pure async MoonBit functions and can be wired into any IPC layer (Proton/CEF, stdio JSON-RPC, HTTP, WASM, custom bridge). Includes a `pub async fn dispatch_op(op : String, payload : Json) -> Json` entry point (in `extensions/labeler`) for embedding outside the CEF runtime; the package is native-only, so a consuming package must declare `supported_targets = \"native\"`."

options(
  warn_list: "",
  preferred_target: "native",
  supported_targets: "+native",
)
