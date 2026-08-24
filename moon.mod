name = "riantr/moonbit_labeler"

version = "0.2.0"

import {
  "moonbitlang/async@0.19.4",
}

readme = "README.mbt.md"

repository = "https://github.com/riantr/moonbit-labeler"

license = "Apache-2.0"

keywords = [ "labeling", "image-annotation", "voc", "yolo", "moonbit", "ipc", "json-rpc" ]

description = "Image / video labeling backend for the MoonbitLabeler app: 18 async ops over @fs/@json for folder browsing, image IO, label IO, class management, and VOC/YOLO export. The op_handlers are pure async MoonBit functions and can be wired into any IPC layer (Proton/CEF, stdio JSON-RPC, HTTP, WASM, custom bridge). Includes a `dispatch_op(op, payload) -> Json raise` entry point in 0.2.0+ for embedding outside the CEF runtime."

options(
  warn_list: "",
  preferred_target: "native",
  supported_targets: "+native",
)
