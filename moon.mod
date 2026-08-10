name = "moonbit_labeler"

version = "0.1.0"

import {
  "moonbitlang/async@0.19.4",
  "moonbitlang/x@0.4.43",
  "justjavac/proton@0.1.12",
}

readme = "README.mbt.md"

repository = ""

license = "Apache-2.0"

keywords = [ "proton", "gui", "web", "desktop-app" ]

description = "A Proton desktop app."

options(
  warn_list: "",
  preferred_target: "native",
  supported_targets: "+native",
)
