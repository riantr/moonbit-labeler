# Architecture

A guided tour of the project's runtime topology, IPC contract, and data
flow. Cross-reference: see [README.md](../README.md) for the user-facing
feature overview and `doc/VIDEO_LABELING.md` for video-mode details.

## Process topology

```
┌─────────────────────────────────────────────────────────────────────┐
│                        moonbit-labeler.exe                          │
│                                                                     │
│  ┌────────────────────────┐    ┌────────────────────────────────┐   │
│  │   CEF/Proton 0.3.3     │    │   MoonBit 0.1.20260920        │   │
│  │   frontend/ (Vite SPA) │◄──►│   extensions/labeler/         │   │
│  │   Chromium 150 embedded│ IPC│   21 async ops over @fs/@json│   │
│  │   via libcef.dll       │    │   IPC bridge: dispatch_op()   │   │
│  └────────────────────────┘    └────────────────────────────────┘   │
│                                                                     │
│  Optional headless `--stdio` JSON-RPC bridge on stdin/stdout,    │
│  same 21 ops over the same Request/Reply structs.                 │
└─────────────────────────────────────────────────────────────────────┘
```

The CEF webview and the MoonBit backend live in the same native process.
The IPC bridge is bidirectional JSON-RPC over the V8↔C FFI.

## Module dependency tree

```
moon.mod  (riantr/moonbit_labeler@0.2.10)
  ├── moonbitlang/async@0.19.4
  ├── moonbit-community/proton@0.3.3          (CEF runtime)
  ├── moonbit-community/proton_contract@0.3.3 (typed IPC contract)
  ├── riantr/moonbit_image@0.3.5              (BMP/QOI/TGA/PNG/GIF/JPEG)
  └── wzzc-dev/moui@0.1.12                    (MoUI spike; see Phase 18)

app/                       ─ entry point
  ├── main.mbt              ─ CEF/Proton + stdio dispatch
  ├── stdio_main.mbt        ─ headless JSON-RPC bridge
  └── ipc_handler.mbt       ─ cross-cutting request shaping

extensions/labeler/        ─ public API (21 ops)
  ├── extension.mbt         ─ @proton_contract.Command[Request, Reply]
  ├── labeler.mbt           ─ Request/Reply structs + helpers
  ├── dispatch.mbt          ─ @labeler.dispatch_op(op, payload) -> Json raise
  └── labeler_test.mbt      ─ 39 unit tests

frontend/                  ─ Vite SPA
  ├── src/main.js           ─ IPC orchestrator
  ├── src/canvas.js         ─ canvas + annotation overlay
  ├── src/label.js          ─ label read/write
  └── src/video.js          ─ video frame extraction
```

## IPC surface

21 ops registered as `@proton_contract.Command[Request, Reply]` and bound
to handlers via `@proton_extension.typed(...)`. Wire format: JSON
payloads in/out. Full list in [README.md](README.md#ipc-surface).

| Op | Request → Reply | Use |
|---|---|---|
| `list_images` | `ListImagesRequest → ListImagesReply` | Browse an image folder |
| `read_image` | `ReadImageRequest → ReadImageReply` | Read a single image as base64 |
| `read_thumb` | `ReadThumbRequest → ReadThumbReply` | Generate a thumbnail |
| `read_text` | `ReadTextRequest → ReadTextReply` | Read arbitrary text file (label source) |
| `write_text` | `WriteTextRequest → WriteTextReply` | Write arbitrary text file |
| `read_label` | `ReadLabelRequest → ReadLabelReply` | Read a JSON label |
| `write_label` | `WriteLabelRequest → WriteLabelReply` | Write a JSON label |
| `parse_label` | `ParseLabelRequest → ParseLabelReply` | Normalize a legacy CARS schema to modern |
| `serialize_label` | `SerializeLabelRequest → SerializeLabelReply` | Serialize to JSON text |
| `scan_classes` | `ScanClassesRequest → ScanClassesReply` | Dedup class names across labels |
| `save_classes` | `SaveClassesRequest → SaveClassesReply` | Persist classes.json |
| `load_classes` | `LoadClassesRequest → LoadClassesReply` | Read classes.json from a folder |
| `load_classes_from_file` | `LoadClassesFromFileRequest → LoadClassesReply` | Read classes.json by absolute path |
| `list_videos` | `ListVideosRequest → ListVideosReply` | Browse a video folder |
| `read_video_info` | `ReadVideoInfoRequest → ReadVideoInfoReply` | Probe via ffprobe |
| `read_video_frame` | `ReadVideoFrameRequest → ReadVideoFrameReply` | ffmpeg frame grab |
| `export_voc` | `ExportVocRequest → ExportReply` | Pascal VOC XML export |
| `export_yolo` | `ExportYoloRequest → ExportReply` | YOLO TXT export |
| `decode_image` | `DecodeImageRequest → ExportReply` | riantr/moonbit_image codec round-trip |
| `resize_image` | `ResizeImageRequest → ExportReply` | Nearest-neighbor resize |
| `pick_folder` | `PickFolderRequest → PickFolderReply` | Native folder picker dialog |

## Data flow — read a label

```
┌────────────────┐  ext:labeler/read_label   ┌─────────────────┐
│ frontend/      │ ─────────────────────────►│ dispatch_op()   │
│ label.js       │                            │  op_read_label  │
│ JSON.parse     │ ◄─────────────────────────│ ensure_dir + @fs│
│ display label  │     ReadLabelReply        │ return json     │
└────────────────┘                            └─────────────────┘
```

The frontend never touches the filesystem directly. Every read/write
funnels through one of the 21 IPC ops, which centralises `ensure_dir`,
path resolution (`image_path_to_label_path`), and schema normalisation.

## Layering rules

- `frontend/` depends on the 21-op IPC surface (no other backend symbols).
- `app/` is the entry point — no domain logic.
- `extensions/labeler/` is the **only** sub-package with public IPC.
  Everything inside (`labeler.mbt`, `dispatch.mbt`) can be re-exported
  but no other package is allowed to take IPC dependencies.
- `extensions/image/` was a vendored copy of `riantr/moonbit_image`
  used during the 0.1.x era. It was removed in commit `b6dd1b1` —
  the package now depends on the upstream `riantr/moonbit_image@0.3.5`
  via mooncakes.

## Build artefacts

- `_build/`: moon's native target dir (`_build/native/debug/build/app/app.exe`).
- `target/proton-dist/moonbit-labeler/`: packaged portable exe + CEF
  runtime files (after `proton_cli package`).
- `target/`: gitignored; `proton-dist/` contents are reproducible from
  source + `proton.project.json`.

## Spike scopes (intentional)

The repo carries two spike scopes that are **not** on the production path
but kept as reference. Both are documented in `AGENTS.md` under
"Migration status":

- `app_moui/` — MoUI 0.1.12 native view tree + custom rasterizer.
  Phase 18 spike (text-widget placeholder design; `@views.button` rendering
  bug is documented but unfixed). Future cleanup candidate.
- `frontend/qa/` — webkit-picker black-box test fixtures.

See `doc/benchmark.md`, `doc/mutation_analysis.md`, and the two `doc/reviews/`
files for performance / mutation-test data on this repo.