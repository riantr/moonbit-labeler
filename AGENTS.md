# AGENTS.md

Image & video annotation desktop app for security X-ray scans — MoonBit + Proton native stack
(ported from the C# `MOlabeler_V2.6` reference). One JSON file per image/video, 4 annotation
primitives (rect / polygon / keypoint / binding), Pascal VOC + YOLO export, CEF shell via
Proton 0.2.5, plus an optional headless `--stdio` JSON-RPC bridge for non-CEF GUIs.

Full project description, IPC surface, and data layout: see [README.md](README.md).
Video-mode details: see [docs/VIDEO_LABELING.md](docs/VIDEO_LABELING.md).

## Setup

- One-time CEF download (~150 MB) into `.proton/runtimes/`: `proton_cli cef setup`
- Update MoonBit deps: `moon update`
- Frontend deps: `cd frontend && npm install`

## Commands

Run all from the project root (`D:\src\MiniMax\Projects\MoonBit\moonbit-labeler`).

- Format MoonBit:                `moon fmt`
- Type-check (native):           `moon check --target native --diagnostic-limit 80`
- Dev (hot reload, Vite + CEF):  `proton_cli dev`
  (reads `proton.project.json` for the frontend dev server config)
- Build release:                 `proton_cli build`
- Inspect package plan:          `proton_cli package --dry-run`
- Produce portable exe + zip:    `proton_cli package`
  → output: `target/proton-dist/moonbit-labeler/moonbit-labeler.exe` + `.zip`
  (formats + output dir come from the `package` block in `proton.project.json`)

> **Upstream bug in `proton_cli` 0.2.5 zip step (Windows).** The internal
> `create_windows_zip` in `proton_package@0.2.5/lib/windows.mbt` passes
> `destination + ".staging"` to `Compress-Archive -DestinationPath`, but
> `Compress-Archive` only accepts paths ending in `.zip` (it uses the extension
> to pick the archive format). Result: PowerShell exits 1 with a non-UTF-8
> error message; the Moon side sees the UTF-8 decode fail and prints
> `error: create Windows zip failed: exit code 1: non-UTF-8 output`. The `app/`
> directory is fully staged before the zip step, so the artifact is not lost.
> **Workaround:** pass `--format app` to skip the broken zip step, then zip
> manually with PowerShell `Compress-Archive -LiteralPath <app> -DestinationPath
> <app>.zip -Force`. The wrapper `_build/package-app.bat` (gitignored) does
> exactly this; run it instead of raw `proton_cli package` for releases.
> Track upstream fix: replace `let staging = destination + ".staging"` with
> `let staging = destination + ".staging.zip"` in `proton_package/lib/windows.mbt`.
- Frontend only:                 `cd frontend && npm run dev` / `npm run build`
- Headless JSON-RPC bridge:      `moonbit-labeler.exe --stdio` (CEF-free; same 18 ops over stdin/stdout)
  See "Stdio JSON-RPC bridge" below for the wire protocol.

## Project layout

- `app/`                   — runnable entry. `main.mbt` routes to one of two modes:
  - CEF/Proton (default): `@proton.file(...).identifier(...).capability(...).run_or_abort()` —
    the 0.2.5 `App` builder API that loads `frontend/dist/index.html` into a CEF webview.
  - `--stdio` (headless): dispatches the same 18 ops as JSON-RPC over stdin/stdout (see
    "Stdio JSON-RPC bridge" below). Selected by passing `--stdio` as the first arg.
  `stdio_main.mbt` holds the stdio loop. Both modes share the `@labeler.dispatch_op`
  entry point in `extensions/labeler/dispatch.mbt`.
- `extensions/labeler/`    — 18 IPC ops (`ext:labeler/<op>`), on-disk label format, VOC/YOLO export,
  and the pure-MoonBit `dispatch_op(op, payload) -> Json raise` entry point. In
  `extension.mbt`, each op is declared as a `@proton_contract.Command[Request, Reply]`
  and bound to the existing `op_*` handler via a `CommandRegistrar`.
- `extensions/image/`      — vendored `buildliming/moonbit_image` (MIT, 14 .mbt files). Do not
  modify unless bumping the upstream pin.
- `frontend/`              — Vite + vanilla-JS UI. `src/main.js` orchestrates IPC + canvas + state;
  `dist/` is inlined into the exe at `proton_cli package` time.
- `data/`                  — local sample dataset (`Image@CARS.Part.01`, sibling `Label@<name>`).
  `data/Image*/` and `data/Label*/` are gitignored (per-deployment user data); only `data/.gitkeep`
  is tracked.
- `docs/`                  — long-form (`VIDEO_LABELING.md`, `PROPOSAL_MoonbitLabeler.md`,
  `benchmark.md`, `mutation_analysis.md`).
- `tests/`, `qa/`          — black-box tests. `*_blackbox_test.mbt` at the repo root + Gherkin
  feature `image_codecs.feature`; frontend QA in `frontend/qa/webkit_picker_blackbox.test.mjs`.
- `target/proton-dist/`    — packaged exe + zip (gitignored).
- `proton.project.json`    — 0.2.5 canonical app config: identifier, backend package path,
  frontend dev/build commands, product name + version + output dir + formats.
  (The 0.1.12 `moon.proton` was removed in the 0.2.5 migration.)
- `moon.mod`               — `riantr/moonbit_labeler` v0.2.5, depends on `moonbit-community/proton@0.2.5`,
  `proton_contract@0.2.5`, and `moonbitlang/async@0.19.4`.

## Code style

- MoonBit source under `app/` and `extensions/labeler/`. Vendored code under `extensions/image/`
  stays untouched except when bumping the upstream pin.
- IPC ops are declared in `extensions/labeler/extension.mbt` as
  `@proton_contract.Command[Request, Reply]` values and bound to handlers inside
  `@proton_extension.typed(...)`. A new op must be added to the table in
  [README.md](README.md#ipc-surface) and exercised from `frontend/src/`.
- Frontend is vanilla-JS ES modules — no framework, no TypeScript. Match the existing
  `frontend/src/*.js` style (named exports, IIFE-free, no transpilation).
- Run `moon fmt` before committing; CI does not currently re-format.

## Testing

- MoonBit package tests: `moon test` (covers `extensions/labeler/labeler_test.mbt`).
- Repo-root black-box drivers (`component_blackbox_test.mbt`, `gherkin_blackbox_test.mbt`) and
  the Gherkin feature `image_codecs.feature` exercise the full labeler + image pipelines.
- Frontend black-box: `node frontend/qa/webkit_picker_blackbox.test.mjs`.
- Manual smoke: `proton_cli dev`, then exercise the canvas + sidebar end-to-end. Do this before
  opening a PR that touches IPC ops, canvas rendering, or the on-disk label format.
- All tests must pass before opening a PR.

## PR & commit conventions

- Branch from `main`; never push to it directly.
- Conventional commits (`feat:` / `fix:` / `refactor:` / `docs:` / `chore:`).
- Keep commits scoped to one package (`app/`, `extensions/labeler/`, `frontend/`, or the
  vendored `extensions/image/` bump) when practical.

## Operational notes

- The frontend is a Vite SPA that gets inlined into the exe at `proton_cli package` time.
  After any change under `frontend/src/`, re-run `npm run build` (or let `proton_cli dev`
  rebuild) before the change is visible in the packaged binary.
- CEF runtime, Proton native prebuilts, `target/`, and `_build/` are all gitignored. The
  documented target is **Proton 0.2.5 + CEF 150.0.19**; if `.proton/runtime.json` shows an
  older Proton version (e.g. 0.1.12 from a previous install), re-run `proton_cli cef setup`
  to pull the 0.2.5 runtime. Older local installs keep the project working but don't match
  the documented target until upgraded.
- **Do not reintroduce the old WebSocket app runtime route.** All IPC goes through
  `@proton_contract.Command` ops (`ext:labeler/<op>`, registered via
  `@proton_extension.typed(...)` in `extensions/labeler/extension.mbt`) or the headless
  `--stdio` JSON-RPC bridge in `app/stdio_main.mbt`.

## Stdio JSON-RPC bridge

The packaged exe (`target/proton-dist/moonbit-labeler/moonbit-labeler.exe`) doubles as
a CEF-free JSON-RPC server when launched with `--stdio`. Same 18 ops, same Request/Reply
structs, same JSON wire format as the CEF path — useful for embedding the labeler backend
in a Python Qt shell, scripts, or debug tooling.

```
$ echo '{"id":1,"op":"list_images","payload":{"path":"data/Image@skin","extensions":["jpg"]}}' \
    | ./moonbit-labeler.exe --stdio
{"type":"ready","ops":["list_images", ...18 ops...]}
{"id":1,"ok":true,"result":{"folder":"data/Image@skin","images":[...]}}
{"type":"bye"}
```

Wire format (one JSON object per line, newline-delimited):

- Banner on startup: `{"type":"ready","ops":[...18 op names...]}`
- Request: `{"id": <int|null>, "op": "<name>", "payload": <op-specific-json>}`
- Response: `{"id": ..., "ok": true,  "result": <json>, "error": null}`
  or:       `{"id": ..., "ok": false, "result": null, "error": "<message>"}`
- Trailer on EOF: `{"type":"bye"}`

Implementation: `app/stdio_main.mbt` (`pub async fn run_stdio()`) reads one line per
request via `@stdio.stdin.read_until("\n")` (trait method on `@io.Reader`), dispatches via
`@labeler.dispatch_op(op, payload)`, and writes one response line via
`@stdio.stdout.write(...)` (trait method on `@io.Writer`). The response is a struct
`Response` with `derive(ToJson)` — 0.2.5 made the `Object`/`Null`/`String` Json variant
constructors read-only outside `core/json`, so the public way to build a Json object is
either an object literal `{ "k": v, ... }` or a `derive(ToJson)` struct. Both keys
(`result` and `error`) are always present in the wire output, with one of them `null`.

The CLI arg detection lives in `app/main.mbt::is_stdio_mode(args)`:
`@env.args().contains("--stdio")` selects the stdio path; otherwise the CEF builder runs.

## Security

- Never commit secrets — there is no `.env`; runtime data lives under `data/`, which is
  gitignored.
- The `--stdio` bridge is a privileged local IPC surface: it accepts JSON-RPC from whoever
  owns the parent process. Only invoke it from a trusted local driver; do not expose it
  on a network socket without an explicit auth layer.
- CEF download (`proton_cli cef setup`) is a 150 MB tarball — verify the SHA256 from
  upstream if operating in a high-trust environment.
