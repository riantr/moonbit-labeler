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
| Backend | MoonBit 0.4.43 + async runtime | Native AOT compile, no GC pauses in the hot path |
| UI shell | Proton 0.1.12 + CEF 147 | Self-contained portable exe, no Electron |
| Image codec | vendored [buildliming/moonbit_image](extensions/image/) (MIT) | Faster than `mizchi/image` for our workload |
| Frontend | Vanilla JS + Vite | No framework lock-in, fast cold reload |
| IPC | MoonBit `@proton_command` JSON ops | Type-safe request/response structs |

## Project layout

```
.
├── app/
│   └── main.mbt                       # @proton.config(...).extension().run_or_abort()
├── extensions/
│   ├── labeler/                       # 21 IPC ops + the image/label/VOC/YOLO pipeline
│   │   ├── labeler.mbt                # ~3,400 lines
│   │   ├── moon.pkg
│   │   └── write_probe.mbt            # (deprecated ops, kept for test)
│   └── image/                         # vendored buildliming/moonbit_image (14 .mbt files)
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
├── moon.mod                           # deps: moonbitlang/x@0.4.43
├── moon.proton                        # window 1280x800, entry=frontend/dist/index.html
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
proton_cli package app       # full build -> target/proton-dist/moonbit-labeler/
proton_cli dev               # hot-reload dev mode
```

The first build downloads ~150 MB of CEF binaries; subsequent builds are
incremental. If the Proton runtime is missing, run `proton_cli cef setup`.

The packaged binary is at
`target/proton-dist/moonbit-labeler/moonbit-labeler.exe` and the matching
ZIP is `target/proton-dist/moonbit-labeler.zip`. The ZIP is self-contained
— drop it on any Windows machine, unzip, double-click the exe, done.

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

The MoonBit side registers ops through `@proton_command`. Each op is
invoked from JS as `window.__MoonBit__.core.invokeOp("ext:labeler/<op>", payload)`.

| Op | Direction | Purpose |
|---|---|---|
| `list_images` | frontend → backend | List image files in a folder |
| `read_image` / `read_thumb` | frontend → backend | Read image bytes (base64), with optional resize for thumbs |
| `decode_image` / `resize_image` | frontend → backend | Backend-side image decode / resize (vendored buildliming/moonbit_image) |
| `read_text` / `write_text` | frontend → backend | Read / write a UTF-8 text file |
| `read_label` / `write_label` | frontend → backend | Read / write the on-disk label JSON for a given image path |
| `scan_classes` / `save_classes` / `load_classes` / `load_classes_from_file` | frontend → backend | Manage the curated class list (TXT or JSON, by file path or by Image/Label dir scan) |
| `parse_label` / `serialize_label` | frontend → backend | Round-trip a label JSON through the shared normalizer (handles legacy + modern schema) |
| `list_videos` / `read_video_info` / `read_video_frame` | frontend → backend | Video enumeration + per-frame decode (via `ffprobe / ffmpeg`) |
| `export_voc_folder` / `export_yolo_folder` | frontend → backend | Batch export the current Image/Label folder to Pascal VOC XML or YOLO TXT |

## Vendored dependencies

- **buildliming/moonbit_image** — `extensions/image/` (14 .mbt files).
  MIT license, original copyright 2025 lws, published upstream as
  `shunge/image`. Vendored because the build environment can't reach the
  moon registry. Used for the backend decode + resize + BMP encode paths.
- **CEF / Proton runtime** — assembled into `target/proton-dist/...` at
  build time by `proton_cli package`. The runtime itself is downloaded
  by `proton_cli cef setup` and cached under `.proton/runtimes/`.

## License

Apache License 2.0 — see [LICENSE](LICENSE).