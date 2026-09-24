# MoonBit Labeler

An image and video annotation desktop app for security X-ray scans,
ported from a C# reference tool (`MOlabeler_V2.6`) to a MoonBit + Proton
native stack. Supports 4 annotation primitives (rectangle, polygon,
keypoint, binding) with custom JSON labels that round-trip both modern
and CARS-dataset legacy schemas.

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
# One-time CEF runtime download (~150 MB) into .proton/runtimes/
proton_cli cef setup

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
```

## Features

- **Image annotation** — 4 primitives (rectangle, polygon, keypoint,
  binding), 1-9 hotkeys for class switching, undo/redo, autosave,
  prefix/suffix batch ops.
- **Video annotation** — frames are flat annotations with a `frames: []`
  field that lists which frames the annotation applies to. Frame timeline
  + copy-to-next + coverage badge. See [docs/VIDEO_LABELING.md](docs/VIDEO_LABELING.md).
- **Two render modes** — native browser `<img>` (default) and backend
  decode + BMP (`image/bmp` data URL), selectable at runtime via the
  Settings menu.
- **Export** — Pascal VOC XML and YOLO TXT format with classes.txt,
  per-image batch export to a chosen folder.
- **Custom class lists** — TXT (`id|name|#RRGGBB`) or JSON format,
  editable via the menubar, persisted next to the image folder as
  `classes.json`. Colors travel with each class.

## Stack

| Layer | Choice | Why |
|---|---|---|
| Backend | MoonBit 0.1.20260920 + async runtime | Native AOT compile, no GC pauses in the hot path |
| UI shell | Proton 0.3.3 + CEF 150.0.19 | Self-contained portable exe, no Electron |
| Image codec | shared [`riantr/moonbit_image@0.3.5`](https://mooncakes.io/riantr/moonbit_image) (MIT / Apache-2.0) | Faster than `mizchi/image` for our workload; includes JPEG IDCT fix |
| Frontend | Vanilla JS + Vite | No framework lock-in, fast cold reload |
| IPC | MoonBit `@proton_contract.Command` + `@proton_extension.typed` | Type-safe Request/Reply structs, bound via `CommandRegistrar` |

### Runtime versions

The Stack table is the target configuration. To install the matching runtime locally, run
`proton_cli cef setup` and verify against `.proton/runtime.json` (`proton_version` /
`cef_version`). Older local installs (e.g. Proton 0.1.12) keep the project working but
don't match the documented target.

## Project layout

```
.
├── app/
│   └── main.mbt                       # 0.2.5 entry: @proton.file(...).identifier(...).capability(@proton_extension.capability(ext)).run_or_abort()
├── extensions/
│   ├── labeler/                       # 21 IPC ops + the image/label/VOC/YOLO pipeline
│   │   ├── labeler.mbt                # ~3,400 lines (Request/Reply structs + op_* handlers)
│   │   ├── extension.mbt               # 0.2.5 extension registration (CommandRegistrar::bind for all 21 ops)
│   │   ├── dispatch.mbt                # pure-MoonBit dispatch_op(op, payload) -> Json raise entry point (used by the stdio bridge)
│   │   └── moon.pkg
│   # Image codec lives in the shared riantr/moonbit_image@0.3.4 mooncake
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
│       └── style.css                  # all CSS in one place
├── data/                              # local sample dataset (Image@CARS.Part.01)
├── docs/VIDEO_LABELING.md
├── proton.project.json                # 0.2.5 canonical app config (identifier, backend, frontend, package)
├── moon.mod                           # deps: moonbit-community/proton@0.2.5 + proton_contract@0.2.5
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

## Build & run

This is a MoonBit Proton native desktop app. See [AGENTS.md](AGENTS.md)
for the project command list.

```sh
moon fmt
moon check --target native --diagnostic-limit 80
proton_cli package            # full build -> target/proton-dist/moonbit-labeler/moonbit-labeler.exe
proton_cli dev                # hot-reload dev mode (reads proton.project.json)
```

The first build downloads ~150 MB of CEF binaries; subsequent builds are
incremental. If the Proton runtime is missing, run `proton_cli cef setup`.

The packaged binary is at
`target/proton-dist/moonbit-labeler/moonbit-labeler.exe`. (The `zip` format
in `proton.project.json` produces a sibling `moonbit-labeler-0.2.5.zip` —
self-contained, drop on any Windows machine, unzip, double-click the exe.)

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
| `decode_image` / `resize_image` | frontend → backend | Backend-side image decode / resize (shared `riantr/moonbit_image@0.3.4`) |
| `read_text` / `write_text` | frontend → backend | Read / write a UTF-8 text file |
| `read_label` / `write_label` | frontend → backend | Read / write the on-disk label JSON for a given image path |
| `scan_classes` / `save_classes` / `load_classes` / `load_classes_from_file` | frontend → backend | Manage the curated class list (TXT or JSON, by file path or by Image/Label dir scan) |
| `parse_label` / `serialize_label` | frontend → backend | Round-trip a label JSON through the shared normalizer (handles legacy + modern schema) |
| `list_videos` / `read_video_info` / `read_video_frame` | frontend → backend | Video enumeration + per-frame decode (via `ffprobe / ffmpeg`) |
| `export_voc_folder` / `export_yolo_folder` | frontend → backend | Batch export the current Image/Label folder to Pascal VOC XML or YOLO TXT |

## Vendored dependencies

- **`riantr/moonbit_image@0.3.4`** — shared mooncake, MIT / Apache-2.0,
  original copyright 2025 lws. Pulled in via `moon.mod` (see the
  `import` block). Used for the backend decode + resize + BMP encode
  paths. A prior vendored copy under `extensions/image/` was removed
  in commit `20fbdf2`; see the commit message for the deletion
  rationale (the vendored buildliming fork was missing the JPEG
  IDCT fix that the upstream 0.3.4 release ships).
- **CEF / Proton runtime** — assembled into `target/proton-dist/...` at
  build time by `proton_cli package`. The runtime itself is downloaded
  by `proton_cli cef setup` and cached under `.proton/runtimes/`.

## License

Apache License 2.0 — see [LICENSE](LICENSE).