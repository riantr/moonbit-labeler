name = "riantr/moonbit_labeler"

version = "0.2.10"

import {
  "moonbitlang/async@0.22.1",
  "moonbit-community/proton@0.3.3",
  "moonbit-community/proton_contract@0.3.3",
  "riantr/moonbit_image@0.3.5",
  "wzzc-dev/moui@0.1.12",
}

readme = "README.mbt.md"

repository = "https://github.com/riantr/moonbit-labeler"

license = "Apache-2.0"

keywords = [
  "labeling",
  "image-annotation",
  "voc",
  "yolo",
  "moonbit",
  "ipc",
  "json-rpc",
]

description = "Image / video labeling backend for the MoonbitLabeler app: 21 async ops over @fs/@json for folder browsing, image IO, label IO, schema normalization (parse/serialize round-trip), class management, and VOC/YOLO export. The op_handlers are pure async MoonBit functions and can be wired into any IPC layer (Proton/CEF, stdio JSON-RPC, HTTP, WASM, custom bridge). Includes a `dispatch_op(op, payload) -> Json raise` entry point in 0.2.0+ for embedding outside the CEF runtime."

options(
  warn_list: "",
  preferred_target: "native",
  supported_targets: "+native",
)
