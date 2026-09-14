# MoonBit Labeler

A native desktop image and video annotation tool for security X-ray
scans, ported from a C# reference (`MOlabeler_V2.6`) to a MoonBit +
Proton native stack (no Electron). Supports 4 annotation primitives
(rectangle, polygon, keypoint, binding), custom JSON labels that
round-trip both modern and legacy (CARS-dataset) schemas, and a
21-op IPC over `ext:labeler/<op>` that any host can drive.

For the full design doc see the project repo's
[README.md](https://github.com/riantr/moonbit-labeler#readme). For
data format and project layout see that repo's README and
[docs/VIDEO_LABELING.md](https://github.com/riantr/moonbit-labeler/blob/main/docs/VIDEO_LABELING.md).

## Build from source

### Prerequisites

- **MoonBit** ≥ 0.1.20260803 (the build host has `moon 0.1.20260904`)
- **Node.js** ≥ 18 with `npm` on PATH (for the Vite frontend)
- **Proton CLI** — `proton_cli` is the wrapper that drives the native
  AOT compile, downloads the CEF runtime, and assembles the exe.
  Install per <https://github.com/moonbit-community/proton>.
- **PowerShell 5.1** on PATH (Windows-only; the native folder picker
  spawns `powershell.exe -NoProfile -NonInteractive -EncodedCommand`)
- ~150 MB of disk for the first CEF download (`proton_cli cef setup`)

### One-time setup

```sh
# From the project root:
moon update                                          # sync moon.mod deps
proton_cli cef setup                                 # download CEF runtime into .proton/runtimes/
cd frontend && npm install && cd ..                 # install Vite + frontend deps (one-time per clone)
```

If `frontend/node_modules/.bin/vite.cmd` is missing, every subsequent
`proton_cli build` step will fail with ` 'vite' is not recognized`.
Run the `npm install` line above to recover.

### Build the native executable

```sh
proton_cli build -- --release
# output: target/proton-dist/moonbit-labeler/moonbit-labeler.exe
```

`--release` is forwarded to the underlying `moon build app` invocation
and turns on MoonBit's release-mode optimisations. Without it you get a
debug build (~10× slower).

For a single-shot zip artifact too:

```sh
proton_cli package
# output: target/proton-dist/moonbit-labeler/moonbit-labeler.exe
#         target/proton-dist/moonbit-labeler/moonbit-labeler.zip (or use the wrapper _build/package-app.bat — see AGENTS.md)
```

`_build/package-app.bat` is a project-local wrapper that works around
the upstream `proton_cli@0.2.5` zip step bug (the staging directory is
fully produced; only the auto-zip fails). It's gitignored (project-local
tool) — recreate it from the snippet in `AGENTS.md` if missing.

### Verify a build

```sh
moon test --target native           # 38+1+1 = 40 unit + blackbox tests
node frontend/qa/webkit_picker_blackbox.test.mjs   # 6 frontend blackbox tests
```

### Run

```sh
# launch the packaged exe (it picks CEF mode if libcef.dll is present,
# --stdio mode if not — see _build/run.bat for the full wrapper):
_build/run.bat

# OR drive the labeler backend over JSON-RPC without launching CEF:
target/proton-dist/moonbit-labeler/moonbit-labeler.exe --stdio
# ...then send one JSON object per line on stdin, read responses on stdout.
# Wire format documented at the top of app/stdio_main.mbt and in the
# project README's "Stdio JSON-RPC bridge" section.
```

The exe is fully self-contained: drop `target/proton-dist/moonbit-labeler/`
on any Windows 10+ machine, double-click the exe. No installation
required.

### Project layout (high-level)

```
.
├── app/                            # runnable entry (CEF + stdio)
├── extensions/labeler/             # 21 IPC ops + label/VOC/YOLO pipeline
├── frontend/                       # Vite + vanilla-JS UI (built into the exe at pack time)
├── moon.mod                        # declares deps: proton@0.2.5, proton_contract@0.2.5, moonbit_image@0.3.4
├── proton.project.json             # identifier, frontend, package (output dir, formats, version)
└── AGENTS.md                       # one-time setup + commands + smoke-test recipe (read first)
```

## Embedding the backend without CEF

The Moon-side handler set is pure async MoonBit and can be wired into
any IPC layer. `extensions/labeler/dispatch.mbt` exposes a single entry
point:

```mbt
pub fn dispatch_op(op : String, payload : Json) -> Json raise
```

This is what `app/stdio_main.mbt` calls, and what you can call from
your own host (Python Qt shell, Go service, embedded WASM, etc.). The
21 op names and their request/response JSON shapes are listed in
`extensions/labeler/extension.mbt` and the project README.

## License

Apache License 2.0. Image codec comes from
[`riantr/moonbit_image@0.3.4`](https://mooncakes.io/riantr/moonbit_image)
(MIT / Apache-2.0, original copyright 2025 lws).