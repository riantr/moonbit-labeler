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

## Download

The desktop app is published as a GitHub release, not as part of this
MoonBit package: mooncakes.io serves the **backend source**, and the
runnable binaries are attached to the release.

| Asset | Size | What it is |
|---|---:|---|
| [`moonbit-labeler-0.2.18-bundle.exe`](https://github.com/riantr/moonbit-labeler/releases/download/v0.2.18/moonbit-labeler-0.2.18-bundle.exe) | 247 MiB | One file — a self-extracting [LunaPack](https://github.com/riantr/LunaPack) bundle. Run it and it unpacks itself into a `.lunapack/` cache directory next to the executable. |
| [`moonbit-labeler-0.2.18.zip`](https://github.com/riantr/moonbit-labeler/releases/download/v0.2.18/moonbit-labeler-0.2.18.zip) | 187 MiB | The staged application directory: `moonbit-labeler.exe` plus the CEF runtime beside it. |

Release page: <https://github.com/riantr/moonbit-labeler/releases/tag/v0.2.18>

Both are **Windows x86-64** and self-contained: unzip (or just run the
bundle) on any Windows 10+ machine and double-click `moonbit-labeler.exe`.

For the backend only, skip the 187 MiB download and depend on the
published module instead — see [Use the backend as a library](#use-the-backend-as-a-library).

## Quick Start

```powershell
# proton_cli is a mooncakes binary package, not part of the moon installer.
# Pin it to the version in moon.mod (Proton modules are lockstep-versioned).
moon install moonbit-community/proton_cli@0.9.0

# One-time CEF runtime download (~850 MB) into ~/.proton/store/
proton_cli setup

# Refresh the registry index + install the frontend deps
moon update
cd frontend ; npm install ; cd ..

# Hot-reload dev (Vite + CEF)
proton_cli dev

# Or build + package the portable exe
moon check --target native --diagnostic-limit 40
moon test --target native
proton_cli package --format app
# Output: target\proton-dist\moonbit-labeler\moonbit-labeler.exe

# Ship it: zip the staged directory (see "Build & run" for why not `tar -a`)
python scripts\make_zip.py target\proton-dist\moonbit-labeler target\proton-dist\moonbit-labeler-0.2.18.zip
```

`moon update` refreshes the local registry index. It does **not** change the
versions pinned in `moon.mod` — to move a dependency, use
`moon add --upgrade <pkg>@<version>` and check `git diff -- moon.mod`.

`proton_cli package` uses the `formats` list in `proton.project.json`
(`app` + `zip`), so by default it stages the application **and** writes a
zip of it. `--format app` skips the zip step; the `tar` line above
then does it by hand.

Both zip routes have their own trap, so the release pipeline uses the
bundled script instead — see [Build & run](#build--run).

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

### Platforms and versions

| Target | Support | Notes |
|---|---|---|
| Desktop app (Proton + CEF) | **Windows x86-64** | The exe, the zip and the LunaPack bundle are built and smoke-tested on `windows-latest`. The native folder picker shells out to PowerShell, and Proton's packaging step is only exercised on Windows. |
| `--stdio` JSON-RPC bridge | Windows x86-64 | The same executable with no CEF window — see [Headless stdio bridge](#headless-stdio-bridge). |
| Backend library (`extensions/labeler`) | **Native, any OS** | The published module declares `supported_targets = "+native"`, so it is not published for the `wasm` target at all. CI proves the Linux native case by resolving the package from mooncakes.io and building a consumer against it; macOS is not exercised in CI. |

The minimum toolchain is **MoonBit `moon 0.1.20261104`**, and that floor is
forced by the dependencies rather than chosen: `try?` was removed from the
language in that release, so the pinned `riantr/moonbit_image@0.3.9` (the
release that replaced `try?` with an explicit `match`) does not compile on
anything older. Newer toolchains are expected to work but are not what CI
runs.

The Stack table is the target configuration. To install the matching runtime locally, run
`proton_cli setup` and verify the result with `proton_cli doctor --verbose`, which prints
the CEF archive it resolved (e.g. `cef_binary_150.0.19+gcf60f42+...`) together with the
store path it came from. Older local installs (e.g. Proton 0.1.12) keep the project working
but don't match the documented target.

## Project layout

```
.
├── app/
│   ├── main.mbt                       # 0.9.0 entry: @proton.asset(...) then app.identifier(...) / app.capability(...) / app.run_or_abort()
│   └── stdio_main.mbt                 # the headless --stdio JSON-RPC bridge (same 27 ops, no CEF)
├── extensions/
│   ├── labeler/                       # 27 IPC ops + the image/label/VOC/YOLO/COCO pipeline
│   │   ├── labeler.mbt                # ~4,700 lines (Request/Reply structs + op_* handlers)
│   │   ├── extension.mbt               # 0.9.0 extension registration (returns @proton_contract.Extension; 27 commands registered via @proton_extension.typed)
│   │   ├── dispatch.mbt                # pure-MoonBit entry point: pub async fn dispatch_op(op : String, payload : Json) -> Json (used by the stdio bridge)
│   │   ├── video_label.mbt             # the per-frame annotation model (frame_labels)
│   │   ├── media_tool.mbt              # ffmpeg / ffprobe discovery for the video ops
│   │   ├── class_revision.mbt          # the class rename (rewrite of the type field across label files)
│   │   └── moon.pkg
│   # Image codec lives in the shared riantr/moonbit_image@0.3.9 mooncake
│   # (see moon.mod), not in this tree. Prior `extensions/image/` vendored
│   # copy was removed in 20fbdf2.
├── examples/
│   ├── README.md                      # what each example does
│   ├── consumer/                      # a consumer of the PUBLIC API only; the CI job copies
│   │   ├── moon.pkg                   # these two files into a scratch module and resolves
│   │   ├── main.mbt                   # the package from mooncakes.io (see run.sh)
│   │   └── run.sh
│   └── read_label/                    # reads one image's label through the read_label op
│       ├── moon.pkg
│       └── main.mbt
├── frontend/
│   ├── dist/                          # Vite build output (inlined into the exe)
│   ├── index.html
│   └── src/
│       ├── main.js                    # state + IPC + UI orchestration (~2,600 lines)
│       ├── canvas.js                  # Canvas 2D rendering + hit testing
│       ├── image-loader.js            # file:// / IPC fallback / lazy thumbs
│       ├── label.js                   # shared IPC wrappers for parse/serialize
│       ├── video.js                   # video mode controller (fetches, timeline, frame save)
│       ├── webkit-pickers.js          # <input type="file"> folder/file pickers
│       ├── lazy-images.js             # IntersectionObserver sidebar thumbs
│       ├── log.js                     # per-stage timing instrumentation
│       ├── logo.png                   # app logo (small enough that the build inlines it)
│       └── style.css                  # all CSS in one place
├── scripts/
│   └── make_zip.py                    # builds the portable zip (a real, deflated ZIP)
├── data/                              # local sample dataset (Image@skin / Label@skin)
├── docs/logo.png                      # the logo, at README size
├── doc/VIDEO_LABELING.md
├── proton.project.json                # 0.9.0 canonical app config (identifier, backend, frontend, package)
├── moon.mod                           # deps: proton@0.9.0 + proton_contract@0.9.0 + moonbit_image@0.3.9 (async comes from the builtin moonbitlang/core)
└── README.mbt.md                      # the README published on the mooncakes.io docs page (hand-maintained)
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
`target/proton-dist/moonbit-labeler/moonbit-labeler.exe`. The staged
directory is self-contained — the CEF runtime sits beside the exe, and
the app finds its frontend through the resource directory
(`<exe dir>/Resources`) — so it starts from **any** working directory,
with no "run it from this folder" caveat.

To ship it as one archive, zip the staged directory with the bundled
script:

```powershell
proton_cli package --format app          # stage the app only
python scripts\make_zip.py target\proton-dist\moonbit-labeler target\proton-dist\moonbit-labeler-0.2.18.zip
```

`scripts/make_zip.py` is used rather than the obvious one-liners,
because both of those produce a broken archive:

- **`tar -a -cf out.zip dir` does not write a zip.** Windows' bsdtar
  ignores the extension hint and writes a *tar*, so the file starts
  with a tar header instead of the `PK` signature and no unzip tool
  can open it. That is what the 0.2.17 release shipped.
- **Proton's own zip step compresses but writes backslash entry names**
  (`moonbit-labeler\app.exe`), which breaks every extractor that is
  not Windows Explorer.

The script writes a spec-compliant archive instead — forward-slash entry
names, the `PK` signature, deflated — which is **187 MiB** for the same
419 MiB tree, where the archive `tar -a` produced was 419 MiB.

Drop the staged directory on any Windows 10+ machine, unzip, and
double-click `moonbit-labeler.exe`.

See [AGENTS.md](AGENTS.md) for the `package-app.bat` wrapper that
automates the same steps.

## The single-file bundle (riantr/LunaPack)

The staged application is ~419 MiB, almost all of it the CEF runtime. To
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
  -o target/proton-dist/moonbit-labeler-0.2.18-bundle.exe `
  --Files target/proton-dist/moonbit-labeler `
  --compression-method lz4 `
  --name moonbit-labeler --version 0.2.18
LunaPack verify target/proton-dist/moonbit-labeler-0.2.18-bundle.exe
```

Two things matter here. The `bundle` **subcommand** is used, never the
Studio front end (`--GUI` / `--studio`): Studio opens a window, which
blocks forever on a headless CI runner, and the wasm build refuses it
outright. And the CLI must be the **native** build — the `moonx` path
runs the wasm target, which has no launcher to embed, so the "bundle" it
produces carries the payload but does not start on its own.

Any bundle can be inspected without unpacking it:

```powershell
LunaPack info target/proton-dist/moonbit-labeler-0.2.18-bundle.exe
```

### What is inside the bundle

244 entries, 438,884,020 bytes uncompressed; lz4 stores them in 247 MiB.
Our own code is 0.8% of that.

The sizes below are measured from the published 0.2.18 asset. Its three
Windows binaries (`moonbit-labeler.exe`, `cef_process.exe` and
`proton-package.json`) are rebuilt on the release runner, so they differ
from a local build by a few kilobytes; every other file is byte-identical
across machines.

**Root (19 entries, 358,956,343 B)** — the application and the CEF runtime:

| File | Size | What it is |
|---|---:|---|
| `moonbit-labeler.exe` | 3,508,224 | the application itself |
| `proton-package.json` | 551 | Proton's package manifest (the app reads its resource dir from it) |
| `proton-update-version` | 7 | Proton's update-check stamp |
| `cef_process.exe` | 634,880 | CEF's renderer subprocess |
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

**`Resources/` (225 files, 79,927,677 B)** — the resource directory the
app entry resolves against, plus the CEF locale packs:

| File | Size | What it is |
|---|---:|---|
| `Resources/frontend/dist/index.html` | 146,443 | the whole frontend — Vite inlines the JS and CSS into one file |
| `Resources/locales/*.pak` | 50,881,875 | 220 files: 55 locales × {plain, feminine, masculine, neuter} |
| `Resources/resources.pak` | 16,130,228 | the CEF resource bundle again |
| `Resources/icudtl.dat` | 10,876,560 | the ICU data again |
| `Resources/chrome_100_percent.pak` | 695,496 | the 100% resources again |
| `Resources/chrome_200_percent.pak` | 1,197,075 | the 200% resources again |

Two things are worth knowing about that list. The four `.pak`/`.dat`
files are staged **twice** — once at the root and once under `Resources/`
— so 27.6 MiB of the payload is a duplicate copy. That duplication is
**not** removable: deleting either set from a staged tree and launching
makes the app fail to start, with a control run (both sets present)
passing in between, so Proton needs the exe directory and the resource
directory populated separately. The locale packs, on the other hand, are
trimmable: keeping only `en-US`, `zh-CN` and `zh-TW` — 12 of the 220
files — drops 46.8 MiB from the payload (389,778,264 B for 36 files) and
the app still renders pixel-identically, because CEF falls back to
`en-US.pak` for any locale that is not shipped. That trim is not applied
yet; it would take the release zip from 187 MiB to about 176 MiB, since
the `.pak` files are already compressed and deflating them saves only
11.5 MiB of the 46.8 MiB.

## Keyboard shortcuts

| Key | Action |
|---|---|
| `1` - `9` | Select class 1 - 9 (only classes with a non-empty count, see sidebar) |
| `V` | Select / move mode |
| `R` | Rectangle mode |
| `P` | Polygon mode |
| `K` | Keypoint mode |
| `B` | Binding mode |
| `Ctrl` /`Z` | Undo |
| `Ctrl` /`Y` or `Ctrl` /`Shift`/`Z` | Redo |
| `Delete` or `Backspace` | Delete selected annotation |
| `Esc` | Cancel the polygon draft or the binding in progress |
| `Ctrl` /`S` | Save current label |
| `Ctrl` /`+` / `Ctrl` /`-` / `Ctrl` /`0` | Zoom in / out / actual size |
| `↑` | Previous image — in video mode, previous frame |
| `↓` (or `j`) | Next image — in video mode, next frame |
| `←` / `→` | Previous / next video frame (video mode only) |

The mode keys are case-insensitive, and the shortcuts are ignored while a
text field has the focus.

`Esc` only cancels: it drops a polygon that is still being drawn or a
binding that is waiting for its target. It is not an undo.

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

## Headless stdio bridge

The same 27 ops are reachable without the CEF window. Pass `--stdio` as
the first argument and the executable turns into a line-oriented JSON-RPC
bridge over stdin/stdout:

```sh
target/proton-dist/moonbit-labeler/moonbit-labeler.exe --stdio
```

One JSON object per line in, one per line out:

```
req  = {"id": <int|null>, "op": "<name>", "payload": <op-specific-json>}
resp = {"id": <int|null>, "ok": true,  "result": <op-specific-json>}
     | {"id": <int|null>, "ok": false, "error": "<message>"}
```

The op names are the ones in the table above with `ext:labeler/` stripped.
A startup banner listing them comes first, and a `{"type":"bye"}` marker
comes last:

```console
$ printf '%s\n' '{"id":1,"op":"parse_label","payload":{"text":"{\"img_name\":\"probe.png\"}","fallback_img_name":"probe.png"}}' \
    | moonbit-labeler.exe --stdio
{"type":"ready","ops":["list_images","read_image", ... ]}
{"id":1,"ok":true,"result":{"label_text":"{\"img_name\":\"probe.png\",\"infos\":[],\"bindings\":[]}","err":""}}
{"type":"bye"}
```

Two details worth knowing if you script against it:

- **A UTF-8 BOM is tolerated**, including a stack of two. Windows
  PowerShell 5.1 hands a native executable a string that already starts
  with U+FEFF and then prepends the `EF BB BF` preamble of
  `$OutputEncoding` on top of it, so the first request line arrives with
  two BOMs in front. Without the tolerance the *first* request is
  silently dropped while every later one succeeds, which reads like a
  bug in the caller.
- **Errors are answers, not crashes.** A malformed payload comes back as
  `ok: true` with an `err` field (that is the op's own contract), while
  an unknown op or an internal failure comes back as `ok: false` with an
  `error` string. The process exits 0 on EOF.

The bridge is what the black-box tests under `tests/stdio/` drive, and
`app/stdio_main.mbt` is where the protocol is implemented.

## Use the backend as a library

The backend is published to mooncakes.io, so another MoonBit project can
depend on it without the CEF runtime and without this source tree:

```sh
moon add riantr/moonbit_labeler@0.2.18
```

which pins the dependency in `moon.mod`:

```
import {
  "riantr/moonbit_labeler@0.2.18",
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

The two files are checked in under
[`examples/consumer/`](examples/consumer/), so this snippet and the CI job
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

### Checking the published package

`examples/consumer/run.sh` does the whole round trip: it scaffolds a
throwaway module, resolves `riantr/moonbit_labeler` **from mooncakes.io**
(not from this source tree), copies the two files above in, and then
checks, builds and runs them:

```sh
examples/consumer/run.sh          # the version in moon.mod, or the latest published one
examples/consumer/run.sh 0.2.18   # a specific version
```

The `consumer (published package, ubuntu, native)` CI job runs exactly
that script on every push, so a change that breaks the *published*
package — the package path, the `supported_targets` constraint, the
dependency pins, the public signatures — turns the build red even though
every in-tree test still passes.

The `catch` suffix — rather than `try expr catch { ... }` — is the
canonical form: `moon fmt` drops a redundant `try` keyword. It also drops
the `raise` qualifier from `async fn main raise { ... }`, so a `main` that
raises is silently rewritten into code that no longer compiles. Handling
the error inside `main` avoids that.

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
  IDCT fix, which upstream first shipped in 0.3.4).
- **CEF / Proton runtime** — assembled into `target/proton-dist/...` at
  build time by `proton_cli package`. The runtime itself is downloaded
  by `proton_cli setup` into `~/.proton/store/<platform>/cef-<sha>-layout-<n>/sdk`
  (~850 MB on Windows), which is shared by every project on the machine
  and can be relocated with `PROTON_RUNTIME_STORE`. Proton 0.3.3 moved
  this out of the repo, so the older `.proton/runtimes/` path no longer
  applies.

## License

MIT — see [LICENSE](LICENSE).