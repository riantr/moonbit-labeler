name = "riantr/moonbit_labeler"

version = "0.1.0"

import {
  "moonbitlang/async@0.19.4",
}

readme = "README.mbt.md"

repository = "https://github.com/riantr/moonbit-labeler"

license = "Apache-2.0"

keywords = [ "labeling", "image-annotation", "voc", "yolo", "moonbit" ]

description = "Image / video labeling backend for the MoonbitLabeler app: 21 async ops over @fs/@json for folder browsing, image IO, label IO, class management, and VOC/YOLO export. Originally driven through Proton IPC; the 21 op handlers themselves are pure async MoonBit functions and can be wired into any IPC layer (HTTP, WASM, custom bridge)."

options(
  warn_list: "",
  preferred_target: "native",
  supported_targets: "+native",
)





















