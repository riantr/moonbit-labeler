<div align="center">
  <img src="docs/logo.png" alt="MoonBit Labeler" width="260" />
</div>

# MoonBit Labeler

A desktop annotation tool for images and video frames, built natively
on MoonBit + Proton. 4 annotation primitives (rectangle, polygon,
keypoint, binding), user-defined classes with per-class colors, custom
JSON labels, and export to Pascal VOC XML, YOLO TXT, and COCO
instances JSON.

The tool is domain-independent. The primitives, the class system, and
the export formats assume nothing about the imagery being annotated.
Security X-ray inspection scanning is one application of it — and is
what the bundled `data/` sample dataset happens to contain — but
pointing the tool at another dataset means replacing the image folder
and the class list, nothing more. The CARS legacy-schema round-trip
described under [Data layout](#data-layout) is likewise one supported
schema variant rather than a domain requirement.

```
┌─ menubar (File / Annotate / View / Settings / Tools) ───────────────┐
│ ┌─ sidebar ───────────┐ ┌─ canvas stage (image or video frame) ──┐ │
│ │ 文件列表            │ │  [ toolbar with mode buttons + class  ] │ │
│ │ ▣ 1800003_0.jpg  ✓  │ │  ┌────────────────────────────────────┐ │ │
│ │ ▣ 1800007_0.jpg     │ │  │                                    │ │ │
│ │ ▣ 1800008_0.jpg     │ │  │       canvas + SVG overlay         │ │ │
│ │ ▣ 1800018_0.jpg     │ │  │                                    │ │ │
│ │ ...                 │ │  └────────────────────────────────────┘ │ │
│ │ ── 类别 ────────── │ │  [ timeline (video mode only)        ] │ │
│ │ 1 knife_blade  1332 │ └────────────────────────────────────────┘ │
│ │ 2 scissors  1117    │  ┌─ statusbar (path / index / hints) ┐   │
│ └─────────────────────┘  └─────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────┘
```

## Quick Start

```powershell
# proton_cli is a mooncakes binary package, not part of the moon installer.
# Pin it to the version in moon.mod (Proton modules are lockstep-versioned).
moon install moonbit-community/proton_cli@0.9.0

# One-time CEF runtime download (~850 MB) into ~/.proton/store/
proton_cli setup

# Sync MoonBit deps + frontend deps
moon update
cd frontend ; npm install ; cd ..

# Hot-reload dev (Vite + CEF)
proton_cli dev

# Or build + package the portable exe
moon check --target native --diagnostic-limit 40
moon test --target native
proton_cli package --format app
# Output: target\proton-dist\moonbit-labeler\moonbit-labeler.exe

# Ship it: zip the staged directory with the built-in tar
cd target\proton-dist
tar -a -cf moonbit-labeler-0.2.15.zip moonbit-labeler
```

Use `--format app` rather than the bare `proton_cli package`: the default
also runs a zip step that is upstream-broken on Windows. The staged
`app/` directory is produced either way, so zip it yourself afterwards —
the `tar` line above does it, and [Build & run](#build--run) explains why.

## Features

- **Image annotation** — 4 primitives (rectangle, polygon, keypoint,
  binding), 1-9 hotkeys for class switching, undo/redo, autosave,
  prefix/suffix batch ops.
- **Video annotation** — one JSON per video, holding one annotation set
  per frame in a `frame_labels` array (the top-level `infos` / `bindings`
  stay the "default set" so older files read unchanged). Frame timeline +
  copy-to-next + coverage badge. See [doc/VIDEO_LABELING.md](doc/VIDEO_LABELING.md).
- **Two render modes** — native browser `<img>` (default) and backend
  decode (`moonbit`, re-encoded to BMP and handed over as a data URL),
  selectable at runtime via the Settings menu.
- **Export** — Pascal VOC XML and YOLO TXT format with classes.txt,
  per-image batch export to a chosen folder.
- **Import** — bring external annotations into the on-disk JSON
  format. Three formats supported:
  - **Pascal VOC XML** — `<annotation>/<object>/<bndbox>` per file.
    `<difficult>` is preserved in the bbox coords (we don't have a
    `difficult` field, so the user can post-filter from the JSON if
    they need to).
  - **YOLO TXT** — `<stem>.txt` per image with normalized bbox,
    plus a global `classes.txt`. The image folder is required to
    denormalize the 0..1 coords into absolute pixel space.
  - **COCO instances JSON** — single `instances_*.json` file with
    `images[]`, `annotations[]`, `categories[]`. Annotations without
    a `bbox` (segmentation-only) are skipped — our schema has no
    native segmentation field. `file_name` subdirectories
    (`train2017/...`) are stripped to the basename so the resulting
    JSON keys match what `list_images` returns.
- **Custom class lists** — TXT (`id|name|#RRGGBB`) or JSON format,
  editable via the menubar, persisted next to the image folder as
  `classes.json`. Colors travel with each class.
- **Class revision** — the class list is only a projection of the
  annotation data, so a class annotated under a wrong name could not be
  corrected. 工具 → 重命名类别 rewrites the `type` field of the
  annotations that use it: either the current image's label document or
  every label document of the dataset. The rename is previewed first
  (how many annotations and files it touches) and confirmed before
  anything is written; for a video it reaches every frame's set.
- **Class context menu** — right-clicking a class in the sidebar opens a
  menu with 替换至当前目标, which re-classifies the annotation that is
  selected on the canvas to that class (the geometry is untouched). The
  item is greyed out and unselectable while no annotation is selected, so
  it never fails silently.

## Stack

| Layer | Choice | Why |
|---|---|---|
| Backend | MoonBit 0.1.20261104 + `moonbitlang/core/async` runtime | Native AOT compile, no GC pauses in the hot path |
| UI shell | Proton 0.9.0 + CEF 150.0.19 | Self-contained portable exe, no Electron |
| Image codec | shared [`riantr/moonbit_image@0.3.9`](https://mooncakes.io/riantr/moonbit_image) (MIT) | Moved out of the vendored tree into a shared mooncake; includes the JPEG IDCT fix |
| Frontend | Vanilla JS + Vite | No framework lock-in, fast cold reload |
| IPC | MoonBit `@proton_contract.Command` + `@proton_extension.typed` | Type-safe Request/Reply structs, bound via `CommandRegistrar` |

### Runtime versions

The Stack table is the target configuration. To install the matching runtime locally, run
`proton_cli setup` and verify against `.proton/runtime.json` (`proton_version` /
`cef_version`). Older local installs (e.g. Proton 0.1.12) keep the project working but
don't match the documented target.

## Project layout

```
.
├── app/
│   └── main.mbt                       # 0.9.0 entry: @proton.file(...) then app.identifier(...) / app.capability(...) / app.run_or_abort()
├── extensions/
│   ├── labeler/                       # 27 IPC ops + the image/label/VOC/YOLO/COCO pipeline
│   │   ├── labeler.mbt                # ~3,400 lines (Request/Reply structs + op_* handlers)
│   │   ├── extension.mbt               # 0.9.0 extension registration (returns @proton_contract.Extension; 27 commands registered via @proton_extension.typed)
│   │   ├── dispatch.mbt                # pure-MoonBit dispatch_op(op, payload) -> Json raise entry point (used by the stdio bridge)
│   │   └── moon.pkg
│   # Image codec lives in the shared riantr/moonbit_image@0.3.9 mooncake
│   # (see moon.mod), not in this tree. Prior `extensions/image/` vendored
│   # copy was removed in 20fbdf2.
├── frontend/
│   ├── dist/                          # Vite build output (inlined into the exe)
│   ├── index.html
│   └── src/
│       ├── main.js                    # state + IPC + UI orchestration (~1,800 lines)
│       ├── canvas.js                  # Canvas 2D rendering + hit testing
│       ├── image-loader.js            # file:// / IPC fallback / lazy thumbs
│       ├── label.js                   # shared IPC wrappers for parse/serialize
│       ├── video.js                   # video mode controller (fetches, timeline, frame save)
│       ├── webkit-pickers.js          # <input type="file"> folder/file pickers
│       ├── lazy-images.js             # IntersectionObserver sidebar thumbs
│       ├── log.js                     # per-stage timing instrumentation
│       ├── logo.png                   # app logo (small enough that the build inlines it)
│       └── style.css                  # all CSS in one place
├── data/                              # local sample dataset (Image@skin / Label@skin)
├── docs/logo.png                      # the logo, at README size
├── doc/VIDEO_LABELING.md
├── proton.project.json                # 0.9.0 canonical app config (identifier, backend, frontend, package)
├── moon.mod                           # deps: proton@0.9.0 + proton_contract@0.9.0 + moonbit_image@0.3.9 (async comes from the builtin moonbitlang/core)
└── README.mbt.md                      # generated Proton README (do not edit)
```

## Data layout

The on-disk format is one JSON file per image/video. The convention is
sibling directories named `Image@<dataset>` and `Label@<dataset>`:

```
Image@CARS.Part.01/1800007_0.jpg
Label@CARS.Part.01/1800007_0.json
```

The JSON has the shape:

```json
{
  "img_name": "1800007_0.jpg",
  "infos": [
    {
      "id": "obj_a1b2c3",
      "shape": "rect",
      "type": "knife_blade",
      "points": [[287, 111], [303, 180]]
    }
  ],
  "bindings": [
    { "id": "b_d3e4f5", "from": "obj_a1b2c3", "to": "obj_…", "type": "same_group" }
  ],
  "frames": []      // omitted when empty (image mode)
}
```

The backend normalizes both the legacy `points: "x,y;x,y;..."` shape
(CARS) and the modern `points: [[x, y], ...]` shape on read. Saves always
use the modern shape.

A **video** uses the same one-JSON-per-file convention, with the
per-frame sets in a `frame_labels` array:

```json
{
  "img_name": "clip_001.mp4",
  "infos": [],
  "bindings": [],
  "frame_labels": [
    { "frames": [12], "infos": [ /* ... */ ], "bindings": [ /* ... */ ] },
    { "frames": [24, 25], "infos": [ /* ... */ ], "bindings": [ /* ... */ ] }
  ]
}
```

The top-level `infos` / `bindings` / `frames` stay the **default set**
(empty `frames` = "applies to every frame"), so a file written by the
older flat schema reads back unchanged. The full rules are in
[doc/VIDEO_LABELING.md](doc/VIDEO_LABELING.md).

## Build & run

This is a MoonBit Proton native desktop app. See [AGENTS.md](AGENTS.md)
for the project command list.

```sh
moon fmt
moon check --target native --diagnostic-limit 80
proton_cli package            # full build -> target/proton-dist/moonbit-labeler/moonbit-labeler.exe
proton_cli dev                # hot-reload dev mode (reads proton.project.json)
```

The first build downloads ~850 MB of CEF binaries; subsequent builds are
incremental. If the Proton runtime is missing, run `proton_cli setup`.

`proton_cli` is a mooncakes binary package rather than part of the moon
installer, so install it once with `moon install
moonbit-community/proton_cli@<version>` — pinned to the version in
`moon.mod`, because all published Proton modules use one lockstep
version.

The packaged binary is at
`target/proton-dist/moonbit-labeler/moonbit-labeler.exe`. To ship it, zip
the staged directory yourself — Proton's built-in zip step is
upstream-broken on Windows (`create_windows_zip` in
`proton_package/lib/windows.mbt` hands `Compress-Archive` a `.staging`
suffix, and `Compress-Archive` only accepts `.zip`, so the step exits 1
and nothing is zipped). Use the built-in `tar`, which needs no extra
tool:

```powershell
proton_cli package --format app          # stage the app; skip the broken zip step
cd target\proton-dist
tar -a -cf moonbit-labeler-0.2.15.zip moonbit-labeler
```

The result is self-contained: drop it on any Windows 10+ machine, unzip,
and double-click `moonbit-labeler.exe`. The app finds its frontend
through the resource directory (`<exe dir>/Resources`), so it starts
from **any** working directory — no "run it from this folder" caveat.

See [AGENTS.md](AGENTS.md) for the upstream bug report and the
`package-app.bat` wrapper that automates the same two steps.

## The single-file bundle (riantr/LunaPack)

The staged application is ~419 MB, almost all of it the CEF runtime. To
offer it as one download, [riantr/LunaPack](https://github.com/riantr/LunaPack)
packs the staged directory into a self-extracting executable that embeds
itself as the launcher: the user downloads one file, runs it, and it
unpacks itself into a `.lunapack/` cache directory next to the executable
on first start.

```powershell
moon install riantr/LunaPack@0.1.20     # native build -> ~/.moon/bin/LunaPack.exe
proton_cli package --format app         # stage the app first
LunaPack bundle `
  -i target/proton-dist/moonbit-labeler/moonbit-labeler.exe `
  -o target/proton-dist/moonbit-labeler-0.2.15-bundle.exe `
  --Files target/proton-dist/moonbit-labeler `
  --compression-method lz4 `
  --name moonbit-labeler --version 0.2.15
LunaPack verify target/proton-dist/moonbit-labeler-0.2.15-bundle.exe
```

Two things matter here. The `bundle` **subcommand** is used, never the
Studio front end (`--GUI` / `--studio`): Studio opens a window, which
blocks forever on a headless CI runner, and the wasm build refuses it
outright. And the CLI must be the **native** build — the `moonx` path
runs the wasm target, which has no launcher to embed, so the "bundle" it
produces carries the payload but does not start on its own.

Any bundle can be inspected without unpacking it:

```powershell
LunaPack info target/proton-dist/moonbit-labeler-0.2.15-bundle.exe
```

### What is inside the bundle

244 entries, 438,888,654 bytes uncompressed; lz4 stores them in 257 MB.
Our own code is 0.8% of that.

**Root (19 entries, 358,960,964 B)** — the application and the CEF runtime:

| File | Size | What it is |
|---|---:|---|
| `moonbit-labeler.exe` | 3,510,272 | the application itself |
| `proton-package.json` | 564 | Proton's package manifest (the app reads its resource dir from it) |
| `proton-update-version` | 7 | Proton's update-check stamp |
| `cef_process.exe` | 637,440 | CEF's renderer subprocess |
| `libcef.dll` | 275,751,424 | the CEF/Chromium runtime — 62.8% of the whole payload |
| `chrome_elf.dll` | 2,785,280 | Chromium's own ELF shim |
| `d3dcompiler_47.dll` | 4,741,488 | DirectX shader compiler |
| `dxcompiler.dll` | 25,636,352 | DirectX shader compiler (HLSL) |
| `dxil.dll` | 1,502,784 | DXIL bytecode library |
| `libEGL.dll` | 496,640 | ANGLE EGL |
| `libGLESv2.dll` | 7,882,240 | ANGLE GLESv2 |
| `vulkan-1.dll` | 951,808 | Vulkan loader |
| `vk_swiftshader.dll` | 5,425,152 | software Vulkan rasterizer (fallback) |
| `vk_swiftshader_icd.json` | 106 | the ICD descriptor for the above |
| `icudtl.dat` | 10,876,560 | ICU character data |
| `resources.pak` | 16,130,228 | Chromium's resource bundle (UI strings) |
| `chrome_100_percent.pak` | 695,496 | Chromium resources at 100% scaling |
| `chrome_200_percent.pak` | 1,197,075 | Chromium resources at 200% scaling |
| `v8_context_snapshot.bin` | 740,048 | V8 startup snapshot |

**`Resources/` (225 files, 79,927,690 B)** — the resource directory the
app entry resolves against, plus the CEF locale packs:

| File | Size | What it is |
|---|---:|---|
| `Resources/frontend/dist/index.html` | 146,456 | the whole frontend — Vite inlines the JS and CSS into one file |
| `Resources/locales/*.pak` | 50,881,875 | 220 files: 55 locales × {plain, feminine, masculine, neuter} |
| `Resources/resources.pak` | 16,130,228 | the CEF resource bundle again |
| `Resources/icudtl.dat` | 10,876,560 | the ICU data again |
| `Resources/chrome_100_percent.pak` | 695,496 | the 100% resources again |
| `Resources/chrome_200_percent.pak` | 1,197,075 | the 200% resources again |

Two things are worth knowing about that list. The four `.pak`/`.dat`
files are staged **twice** — once at the root and once under `Resources/`
— so 27.6 MB of the payload is a duplicate copy. That duplication is
**not** removable: deleting either set from a staged tree and launching
makes the app fail to start, with a control run (both sets present)
passing in between, so Proton needs the exe directory and the resource
directory populated separately. The locale packs, on the other hand, are
trimmable: keeping only `en-US`, `zh-CN` and `zh-TW` — 12 of the 220
files — drops 46.8 MB from the payload (389,782,898 B for 36 files) and
the app still renders pixel-identically, because CEF falls back to
`en-US.pak` for any locale that is not shipped. That trim is not applied
yet; it would take the release zip from 419 MB to about 372 MB.

## Keyboard shortcuts

| Key | Action |
|---|---|
| `1` - `9` | Select class 1 - 9 (only classes with a non-empty count, see sidebar) |
| `V` | Select / move mode |
| `R` | Rectangle mode |
| `P` | Polygon mode |
| `K` | Keypoint mode |
| `B` | Binding mode |
| `Ctrl` /`Z` / `Y` | Undo / Redo |
| `Delete` | Delete selected annotation |
| `Ctrl` /`S` | Save current label |
| `Ctrl` /`+` / `Ctrl` /`-` / `Ctrl` /`0` | Zoom in / out / actual size |
| `←` / `→` / `W` / `S` | Previous / next image (or video frame in video mode) |

## IPC surface

The MoonBit side registers ops through `@proton_contract.Command` (declared
in `extensions/labeler/extension.mbt` and bound to `op_*` handlers in
`labeler.mbt` via `CommandRegistrar::bind`). Each op is invoked from JS as
`window.__MoonBit__.core.invokeOp("ext:labeler/<op>", payload)`.

| Op | Direction | Purpose |
|---|---|---|
| `list_images` | frontend → backend | List image files in a folder |
| `read_image` / `read_thumb` | frontend → backend | Read image bytes (base64), with optional resize for thumbs |
| `decode_image` / `resize_image` | frontend → backend | Backend-side image decode / resize (shared `riantr/moonbit_image@0.3.9`) |
| `read_text` / `write_text` | frontend → backend | Read / write a UTF-8 text file |
| `read_label` / `write_label` | frontend → backend | Read / write the on-disk label JSON for a given image path |
| `scan_classes` / `save_classes` / `load_classes` / `load_classes_from_file` | frontend → backend | Manage the curated class list (TXT or JSON, by file path or by Image/Label dir scan) |
| `rename_class` | frontend → backend | Rename a class across the annotations that use it — `scope` is `current` (one label document) or `folder` (every label document of the dataset), `apply: false` previews the counts |
| `parse_label` / `serialize_label` | frontend → backend | Round-trip a label JSON through the shared normalizer (handles legacy + modern schema) |
| `list_videos` / `read_video_info` / `read_video_frame` | frontend → backend | Video enumeration + per-frame decode (via `ffprobe / ffmpeg`) |
| `read_video_label` / `write_video_label` | frontend → backend | Read / write the annotation set of one video frame (one JSON per video, one set per frame — see `doc/VIDEO_LABELING.md`) |
| `export_voc_folder` / `export_yolo_folder` | frontend → backend | Batch export the current Image/Label folder to Pascal VOC XML or YOLO TXT |
| `import_voc_folder` / `import_yolo_folder` / `import_coco_file` | frontend → backend | Batch import Pascal VOC XML / YOLO TXT / COCO JSON into a destination `Label@<dataset>` folder (see Features above) |
| `pick_folder` | frontend → backend | Native folder picker; the only op that uses the request context. Spawns a PowerShell folder dialog on Windows (CEF 150's `CommandWindow.choose_directory` renders as an OpenFileDialog and returns an empty path, so it is bypassed) |

All 27 ops above correspond 1:1 to the `contract.command(...)`
declarations in `extensions/labeler/extension.mbt`.

## Use the backend as a library

The backend is published to mooncakes.io, so another MoonBit project can
depend on it without the CEF runtime and without this source tree:

```sh
moon add riantr/moonbit_labeler@0.2.15
```

which pins the dependency in `moon.mod`:

```
import {
  "riantr/moonbit_labeler@0.2.15",
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

A minimal consumer:

```mbt nocheck
// cmd/main/moon.pkg
import {
  "riantr/moonbit_labeler/extensions/labeler",
  "moonbitlang/core/async",
  "moonbitlang/core/json",
}

supported_targets = "native"

pkgtype(kind: "executable")

options(
  "allow-experimental-packages": [
    "moonbitlang/core/async",
  ],
)
```

```mbt nocheck
// cmd/main/main.mbt
async fn main raise {
  let ops = @labeler.dispatch_op_list()
  println("op count = " + ops.length().to_string())

  let reply = @labeler.dispatch_op(
    "list_images",
    @json.parse("{\"path\":\"C:/some/images\"}"),
  )
  println(reply.stringify())
}
```

The public entry points are `pub async fn dispatch_op(op : String,
payload : Json) -> Json`, `pub fn dispatch_op_list() -> Array[String]`
and `pub fn parse_label_text(text : String, fallback_img_name : String)
-> (String, String) raise`.

## Vendored dependencies

- **`riantr/moonbit_image@0.3.9`** — shared mooncake, MIT,
  original copyright 2025 lws. Pulled in via `moon.mod` (see the
  `import` block). Used for the backend decode + resize + BMP encode
  paths. A prior vendored copy under `extensions/image/` was removed
  in commit `20fbdf2`; see the commit message for the deletion
  rationale (the vendored buildliming fork was missing the JPEG
  IDCT fix that the upstream 0.3.5 release ships).
- **CEF / Proton runtime** — assembled into `target/proton-dist/...` at
  build time by `proton_cli package`. The runtime itself is downloaded
  by `proton_cli setup` into `~/.proton/store/<platform>/cef-<sha>-layout-<n>/sdk`
  (~850 MB on Windows), which is shared by every project on the machine
  and can be relocated with `PROTON_RUNTIME_STORE`. Proton 0.3.3 moved
  this out of the repo, so the older `.proton/runtimes/` path no longer
  applies.

## License

Apache License 2.0 — see [LICENSE](LICENSE).