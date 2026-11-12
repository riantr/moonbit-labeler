![MoonBit Labeler](https://raw.githubusercontent.com/riantr/moonbit-labeler/main/docs/logo.png)

# MoonBit Labeler

A native desktop annotation tool for images and video frames, built on
a MoonBit + Proton native stack (no Electron). Supports 4 annotation
primitives (rectangle, polygon, keypoint, binding), user-defined classes
with per-class colors, custom JSON labels that round-trip both modern and
legacy (CARS-dataset) schemas, and a typed IPC over `ext:labeler/<op>`
that any host can drive.

The tool is domain-independent: the primitives, the class system, and
the on-disk format assume nothing about the imagery. Security X-ray
inspection scanning is one application — it is what the bundled sample
dataset contains — but another dataset only requires a different image
folder and class list. Likewise the CARS legacy schema is one supported
schema variant, not a domain requirement.

## Download the desktop app

**This module is the backend, not the application.** What mooncakes.io
serves here is the MoonBit *source* package: the "Download zip" link in
the sidebar is that source, and `moon add riantr/moonbit_labeler@0.2.17`
compiles it into your own project. The runnable desktop app is a separate
download, produced by the release CI job and attached to the GitHub
release:

| Asset | Size | What it is |
|---|---:|---|
| [`moonbit-labeler-0.2.17-bundle.exe`](https://github.com/riantr/moonbit-labeler/releases/download/v0.2.17/moonbit-labeler-0.2.17-bundle.exe) | 247 MiB | One file. A self-extracting [LunaPack](https://github.com/riantr/LunaPack) bundle: run it and it unpacks itself into a `.lunapack/` cache directory next to the executable. |
| [`moonbit-labeler-0.2.17.zip`](https://github.com/riantr/moonbit-labeler/releases/download/v0.2.17/moonbit-labeler-0.2.17.zip) | 419 MiB | The staged application directory: `moonbit-labeler.exe` plus the CEF runtime beside it. |

Release page: <https://github.com/riantr/moonbit-labeler/releases/tag/v0.2.17>

Both are **Windows x86-64** and need nothing installed: unzip (or just run
the bundle) on any Windows 10+ machine and double-click
`moonbit-labeler.exe`. The app finds its frontend through the resource
directory (`<exe dir>/Resources`), so it starts from any working
directory.

If you only want the backend, take the module from this page instead — no
CEF runtime, no 400 MB download:

```sh
moon add riantr/moonbit_labeler@0.2.17
```

## Build from source

### Prerequisites

- **MoonBit** — `moon 0.1.20261104` is the toolchain this release is built
  and tested with, and it is the minimum. `try?` was removed in that
  toolchain, so the pinned `riantr/moonbit_image@0.3.9` (the release that
  replaced `try?` with an explicit `match`) does not compile on anything
  older. Newer toolchains are expected to work but are not what CI runs.
- **Node.js** ≥ 18 with `npm` on PATH (for the Vite frontend)
- **Proton CLI** — `proton_cli` is the wrapper that drives the native
  AOT compile, downloads the CEF runtime, and assembles the exe. It is a
  mooncakes binary package and is installed with:

  ```sh
  moon install moonbit-community/proton_cli@0.9.0
  ```

  which drops it in `~/.moon/bin`. **Pin the version to the one in
  `moon.mod`**: all published Proton modules use one lockstep version, so
  an unpinned install floats to the newest release and silently drifts
  out of lockstep. See <https://github.com/moonbit-community/proton>.
- **PowerShell 5.1** on PATH (Windows-only; the native folder picker
  spawns `powershell.exe -NoProfile -NonInteractive -EncodedCommand`)
- ~850 MB of disk for the first CEF download (`proton_cli setup`)

### Platforms

| Target | Support |
|---|---|
| Desktop app (Proton + CEF) | **Windows x86-64** — the exe, the zip and the LunaPack bundle are built and smoke-tested on `windows-latest` |
| `--stdio` JSON-RPC bridge | Windows x86-64 — the same executable with no CEF window |
| Backend library (`extensions/labeler`) | **Native, any OS** — the published module declares `supported_targets = "+native"`, so it is not published for the `wasm` target at all. CI proves the Linux native case by resolving the package from mooncakes.io and building a consumer against it; macOS is not exercised in CI |

The backend library is the part that is platform-independent: everything
above the `dispatch_op` entry point — the 27 ops, the label schema, the
VOC/YOLO/COCO exporters — is plain MoonBit over `@fs` and `@json`.

### One-time setup

```sh
# From the project root:
moon install moonbit-community/proton_cli@0.9.0  # the CLI itself
moon update                                     # sync moon.mod deps
proton_cli setup                                 # download the CEF runtime
cd frontend && npm install && cd ..             # Vite + frontend deps
```

`setup` populates `~/.proton/store/<platform>/cef-<sha>-layout-<n>/sdk`,
which is shared by every project on the machine. Set `PROTON_RUNTIME_STORE`
to an absolute path to relocate it. (Proton 0.3.3 moved this out of the
repo — the older `.proton/runtimes/` layout no longer applies.)

If `frontend/node_modules/.bin/vite.cmd` is missing, every subsequent
`proton_cli build` step will fail with `'vite' is not recognized`.
Run the `npm install` line above to recover.

### Build the native executable

```sh
proton_cli build -- --release
# output: target/proton-dist/moonbit-labeler/moonbit-labeler.exe
```

`--release` is forwarded to the underlying `moon build app` invocation
and turns on MoonBit's release-mode optimisations. Without it you get a
debug build (roughly an order of magnitude slower).

For a single-shot artifact too:

```sh
proton_cli package --format app
# output: target/proton-dist/moonbit-labeler/moonbit-labeler.exe
#         plus the CEF runtime beside it (libcef.dll, *.pak, ...)
```

Pass `--format app` rather than the default. The default also runs the
zip step, which is upstream-broken on Windows: `create_windows_zip` in
`proton_package/lib/windows.mbt` passes a `.staging` suffix to
`Compress-Archive -DestinationPath`, and `Compress-Archive` only accepts
`.zip`. The staged `app/` directory is produced either way, so zip it
yourself with the built-in `tar`:

```sh
cd target/proton-dist
tar -a -cf moonbit-labeler-0.2.17.zip moonbit-labeler
```

The app finds its frontend through the resource directory
(`<exe dir>/Resources`), so it starts from any working directory.

### Verify a build

```sh
moon test --target native           # 85 tests (blackbox + unit)
node frontend/qa/webkit_picker_blackbox.test.mjs   # frontend blackbox

# The async half of the IPC (the class rename and the video path) is
# covered by Node scripts that drive the real --stdio bridge. They need an
# executable with the CEF runtime beside it, i.e. the packaged app:
node tests/stdio/class_revision_stdio_blackbox.test.mjs \
     target/proton-dist/moonbit-labeler/moonbit-labeler.exe
node tests/stdio/video_stdio_blackbox.test.mjs \
     target/proton-dist/moonbit-labeler/moonbit-labeler.exe --expect-ffmpeg
```

### Run

```sh
# launch the packaged exe (it picks CEF mode if libcef.dll is present,
# --stdio mode if not — see _build/run.bat for the full wrapper):
_build/run.bat

# OR drive the labeler backend over JSON-RPC without launching CEF:
target/proton-dist/moonbit-labeler/moonbit-labeler.exe --stdio
# ...then send one JSON object per line on stdin, read responses on stdout.
```

The exe is fully self-contained: drop the whole
`target/proton-dist/moonbit-labeler/` directory on any Windows 10+
machine and double-click the exe. No installation required — the CEF
runtime (`libcef.dll` and friends) sits beside it in that directory, not
in the system directory.

### Project layout (high-level)

```
.
├── app/                            # runnable entry (CEF + stdio)
├── extensions/labeler/             # 27 IPC ops + label/VOC/YOLO/COCO pipeline
├── frontend/                       # Vite + vanilla-JS UI (built into the exe at pack time)
├── moon.mod                        # deps: proton@0.9.0, proton_contract@0.9.0, moonbit_image@0.3.9 (async comes from the builtin moonbitlang/core)
├── proton.project.json             # identifier, frontend, package (output dir, formats, version)
└── AGENTS.md                       # setup + commands + smoke-test recipe (read first)
```

## Embedding the backend without CEF

The Moon-side handler set is pure async MoonBit and can be wired into
any IPC layer. `extensions/labeler/dispatch.mbt` exposes a single entry
point:

```mbt nocheck
pub async fn dispatch_op(op : String, payload : Json) -> Json
```

This is what `app/stdio_main.mbt` calls, and what you can call from
your own host (Python Qt shell, Go service, embedded WASM, etc.). The
27 op names and their request/response JSON shapes are listed in
`extensions/labeler/extension.mbt` and the project README.

### Consuming it from another MoonBit project

The backend is published to mooncakes.io, so another MoonBit project can
depend on it without the CEF runtime and without the source tree:

```sh
moon add riantr/moonbit_labeler@0.2.17
```

which pins the dependency in `moon.mod`:

```
import {
  "riantr/moonbit_labeler@0.2.17",
}
```

Three details decide whether that actually builds, and all three follow
from how the package is built rather than from any rule of their own:

- **The published module is native-only.** It declares
  `supported_targets = "+native"`, so the consuming package has to
  declare `supported_targets = "native"` as well.
- **The async runtime must be declared.** `dispatch_op` is an async
  function, so an `async fn main` needs `moonbitlang/core/async` in the
  package's `moon.pkg`, together with
  `options("allow-experimental-packages": ["moonbitlang/core/async"])` —
  that package is still flagged experimental upstream.
- **The package goes in `moon.pkg`, and nowhere else.** The `moon.pkg`
  import block is what makes `@labeler` resolvable. There is no file-level
  `import` line, and adding one is a parse error in this toolchain
  (`import <bare path>` is not valid syntax — the path form belongs in
  `moon.pkg`, and the file refers to the package as `@labeler`).

A minimal consumer — the two files are checked in under
`examples/consumer/` in the repository, so this snippet and the CI job
cannot drift apart:

```
# examples/consumer/moon.pkg
import {
  "riantr/moonbit_labeler/extensions/labeler",
  "moonbitlang/core/async",
}

supported_targets = "native"

pkgtype(kind: "executable")

options(
  "allow-experimental-packages": [ "moonbitlang/core/async" ],
)
```

```mbt nocheck
// examples/consumer/main.mbt

///|
async fn main {
  let ops = @labeler.dispatch_op_list()
  println("op count = " + ops.length().to_string())

  // Round-trip a label through the shared normalizer. `parse_label`
  // touches no filesystem, so the result is deterministic.
  //
  // `dispatch_op` is async and raises, so `main` is async and the error
  // is handled at the call site rather than by letting `main` raise.
  let payload = ToJson::to_json(ParsePayload::{
    text: ToJson::to_json(ProbeLabel::{ img_name: "probe.png", }).stringify(),
    fallback_img_name: "probe.png",
  })
  let text = @labeler.dispatch_op("parse_label", payload).stringify() catch {
    _ => "dispatch failed"
  }
  println(text)
}

///|
/// The label the probe round-trips.
#derive(ToJson)
struct ProbeLabel {
  img_name : String
}

///|
/// The `parse_label` request payload.
#derive(ToJson)
struct ParsePayload {
  text : String
  fallback_img_name : String
}
```

Running it prints:

```console
op count = 27
{"label_text":"{\"img_name\":\"probe.png\",\"infos\":[],\"bindings\":[]}","err":""}
```

`moonbitlang/core/json` is only needed if you build payloads out of raw
JSON yourself; the example derives its request structs with
`#derive(ToJson)` instead, which keeps the sample free of nested-JSON
string escaping.

The `catch` suffix — rather than `try expr catch { ... }` — is the
canonical form: `moon fmt` drops a redundant `try` keyword. It also drops
the `raise` qualifier from `async fn main raise { ... }`, so a `main` that
raises is silently rewritten into code that no longer compiles. Handling
the error inside `main` avoids that.

`dispatch_op_list()` returns the 27 op names, and
`parse_label_text(text, fallback_img_name) -> (String, String) raise`
round-trips one label document through the shared normalizer without
touching the filesystem.

## License

MIT — see [LICENSE](https://github.com/riantr/moonbit-labeler/blob/main/LICENSE).

The image codec comes from
[`riantr/moonbit_image@0.3.9`](https://mooncakes.io/riantr/moonbit_image)
(MIT / Apache-2.0, original copyright 2025 lws).