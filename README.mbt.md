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

This is an independent implementation, not a port. It has no inheritance,
no shared code, and no design lineage relationship to the C# tool
`MOlabeler_V2.6`; the only connection is that both solve the same general
image-annotation problem.

For the full design doc see the project repo's
[README.md](https://github.com/riantr/moonbit-labeler#readme). For
data format and project layout see that repo's README and
[docs/VIDEO_LABELING.md](https://github.com/riantr/moonbit-labeler/blob/main/docs/VIDEO_LABELING.md).

## Build from source

### Prerequisites

- **MoonBit** ≥ 0.1.20260803 (the build host has `moon 0.1.20260920`)
- **Node.js** ≥ 18 with `npm` on PATH (for the Vite frontend)
- **Proton CLI** — `proton_cli` is the wrapper that drives the native
  AOT compile, downloads the CEF runtime, and assembles the exe. It is a
  mooncakes binary package and is installed with:

  ```sh
  moon install moonbit-community/proton_cli@0.3.4
  ```

  which drops it in `~/.moon/bin`. **Pin the version to the one in
  `moon.mod`**: all published Proton modules use one lockstep version, so
  an unpinned install floats to the newest release and silently drifts
  out of lockstep. See <https://github.com/moonbit-community/proton>.
- **PowerShell 5.1** on PATH (Windows-only; the native folder picker
  spawns `powershell.exe -NoProfile -NonInteractive -EncodedCommand`)
- ~850 MB of disk for the first CEF download (`proton_cli cef setup`)

### One-time setup

```sh
# From the project root:
moon install moonbit-community/proton_cli@0.3.4  # the CLI itself
moon update                                     # sync moon.mod deps
proton_cli cef setup                            # download the CEF runtime
cd frontend && npm install && cd ..             # Vite + frontend deps
```

`cef setup` populates `~/.proton/store/<platform>/cef-<sha>-layout-<n>/sdk`,
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
yourself afterwards.

### Verify a build

```sh
moon test --target native           # 55 tests (blackbox + unit)
node frontend/qa/webkit_picker_blackbox.test.mjs   # frontend blackbox
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
├── extensions/labeler/             # 24 IPC ops + label/VOC/YOLO/COCO pipeline
├── frontend/                       # Vite + vanilla-JS UI (built into the exe at pack time)
├── moon.mod                        # deps: proton@0.3.4, proton_contract@0.3.4, moonbit_image@0.3.7, moui@0.1.12, async@0.22.4
├── proton.project.json             # identifier, frontend, package (output dir, formats, version)
└── AGENTS.md                       # setup + commands + smoke-test recipe (read first)
```

## Embedding the backend without CEF

The Moon-side handler set is pure async MoonBit and can be wired into
any IPC layer. `extensions/labeler/dispatch.mbt` exposes a single entry
point:

```mbt nocheck
pub fn dispatch_op(op : String, payload : Json) -> Json raise
```

This is what `app/stdio_main.mbt` calls, and what you can call from
your own host (Python Qt shell, Go service, embedded WASM, etc.). The
24 op names and their request/response JSON shapes are listed in
`extensions/labeler/extension.mbt` and the project README.

## License

Apache License 2.0 — see [LICENSE](https://github.com/riantr/moonbit-labeler/blob/main/LICENSE).

The image codec comes from
[`riantr/moonbit_image@0.3.7`](https://mooncakes.io/riantr/moonbit_image)
(MIT / Apache-2.0, original copyright 2025 lws).