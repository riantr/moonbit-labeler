# AGENTS.md

Image & video annotation desktop app for security X-ray scans — MoonBit + Proton native stack
(ported from the C# `MOlabeler_V2.6` reference). One JSON file per image/video, 4 annotation
primitives (rect / polygon / keypoint / binding), Pascal VOC + YOLO export, CEF shell via
Proton 0.3.3, plus an optional headless `--stdio` JSON-RPC bridge for non-CEF GUIs.

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

> **Upstream bug in `proton_cli` zip step (Windows).** Reported on 0.2.5 and
> **not yet verified fixed on 0.3.3** (deferred — verifying requires running the
> full `proton_cli package` without `--format app` and observing the broken-staging
> zip, which is the workaround this paragraph exists to bypass). The internal
> `create_windows_zip` in `proton_package/lib/windows.mbt` passes
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

> **Upstream bug in `proton_app` entry path resolution (Windows).** Reported on 0.2.5
> and **confirmed still present on 0.3.3** (verified 2026-09-24 by inspecting
> `.mooncakes/moonbit-community/proton/facade_entry.mbt` after `moon update`).
> The helper `resolve_entry_path()` in `proton/facade_entry.mbt` does
> `@mbpath.Path(path).resolve()` — that's cwd-relative, not resource-relative.
> So `@proton.file("frontend/dist/index.html")` looks at
> `<launch-cwd>/frontend/dist/index.html`, NOT `<dist>/Resources/frontend/dist/index.html`
> where the package step actually staged the file. Symptoms: exe starts then
> aborts with
> `failed to read HTML entry <launch-cwd>/frontend/dist/index.html: @os_error.OSError: @fs.realpath(): ...: The system cannot find the path specified.`
> followed by a null-pointer cascade in the async runtime.
> `resolve_asset_path()` (used by `AppEntry::Asset`) does the right thing:
> it joins `runtime_resource_dir()` for relative paths. **Workaround:** the
> wrapper script mirrors `Resources/frontend/dist/` → `frontend/dist/`
> inside the staged app dir, so the cwd-relative lookup succeeds. This
> works for any launch cwd that lives under (or below) the staged app dir.
> Track upstream fix: copy the `runtime_resource_dir()` branch from
> `resolve_asset_path` into `resolve_entry_path` in
> `moonbit-community/proton/proton_app/facade_entry.mbt`.
- Frontend only:                 `cd frontend && npm run dev` / `npm run build`
- Headless JSON-RPC bridge:      `moonbit-labeler.exe --stdio` (CEF-free; same 21 ops over stdin/stdout)
  See "Stdio JSON-RPC bridge" below for the wire protocol.
- Launch packaged exe:           `_build/run.bat [--cef|--stdio]`
  (auto mode: CEF if `target/proton-dist/moonbit-labeler/libcef.dll` is present,
  otherwise attempts `--stdio`; see "Launch wrapper" below for caveats)

## Project layout

- `app/`                   — runnable entry. `main.mbt` routes to one of two modes:
  - CEF/Proton (default): `@proton.file(...).identifier(...).capability(...).run_or_abort()` —
    the 0.3.3 `App` builder API that loads `frontend/dist/index.html` into a CEF webview.
  - `--stdio` (headless): dispatches the same 21 ops as JSON-RPC over stdin/stdout (see
    "Stdio JSON-RPC bridge" below). Selected by passing `--stdio` as the first arg.
  `stdio_main.mbt` holds the stdio loop. Both modes share the `@labeler.dispatch_op`
  entry point in `extensions/labeler/dispatch.mbt`.
- `extensions/labeler/`    — 21 IPC ops (`ext:labeler/<op>`), on-disk label format, VOC/YOLO export,
  and the pure-MoonBit `dispatch_op(op, payload) -> Json raise` entry point. In
  `extension.mbt`, each op is declared as a `@proton_contract.Command[Request, Reply]`
  and bound to the existing `op_*` handler via a `CommandRegistrar`.
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
- `proton.project.json`    — 0.3.3 canonical app config: identifier, backend package path,
  frontend dev/build commands, product name + version + output dir + formats.
  (The 0.1.12 `moon.proton` was removed in the 0.2.5 migration; the 0.2.5 → 0.3.3
  migration kept the same `proton.project.json` schema.)
- `moon.mod`               — `riantr/moonbit_labeler` v0.2.10, depends on `moonbit-community/proton@0.3.3`,
  `proton_contract@0.3.3`, and `moonbitlang/async@0.19.4`. The image codec comes from the shared
  `riantr/moonbit_image@0.3.4` package (pulled in transitively). A prior vendored copy under
  `extensions/image/` was removed in commit b6dd1b1; do not reintroduce it without first
  re-reading the deletion rationale in that commit's message.

## Code style

- MoonBit source under `app/` and `extensions/labeler/`. Image decoding/encoding lives in
  the shared `riantr/moonbit_image` mooncake — never vendor image codec code locally.
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
- **CEF smoke test (post-build, pre-PR):** the CEF runtime exposes a Chromium
  DevTools Protocol endpoint. `_build/launch-detached.ps1` starts the
  packaged exe with `PROTON_REMOTE_DEBUGGING_PORT=59944`; then
  `node _build/devtools-screenshot-2.mjs 59946 _build/screenshot.png` (or
  any free port) connects over CDP, dumps `readyState` / `folderInput.value`
  / console errors / first-paint screenshot. This is the only
  end-to-end check for "the packaged exe actually starts and renders
  the frontend" — without it, the cwd-relative path bug (see
  Commands > Upstream bugs above) and the `has-image`/`fitView`
  canvas chain (see commit log) would silently regress. Use this
  before opening a PR that touches `app/main.mbt`, the
  `frontend/dist` asset pipeline, the canvas controller, or the
  `@proton.file(...)` entry.
- Manual smoke: `proton_cli dev`, then exercise the canvas + sidebar end-to-end. Do this before
  opening a PR that touches IPC ops, canvas rendering, or the on-disk label format.
- All tests must pass before opening a PR.

## PR & commit conventions

- Branch from `main`; never push to it directly.
- Conventional commits (`feat:` / `fix:` / `refactor:` / `docs:` / `chore:`).
- Keep commits scoped to one package (`app/`, `extensions/labeler/`, `frontend/`, or a
  dependency bump in `moon.mod`) when practical.

## Operational notes

- The frontend is a Vite SPA that gets inlined into the exe at `proton_cli package` time.
  After any change under `frontend/src/`, re-run `npm run build` (or let `proton_cli dev`
  rebuild) before the change is visible in the packaged binary.
- CEF runtime, Proton native prebuilts, `target/`, and `_build/` are all gitignored. The
  documented target is **Proton 0.3.3 + CEF 150.0.19**; if `.proton/runtime.json` shows an
  older Proton version (e.g. 0.1.12 or 0.2.5 from a previous install), re-run `proton_cli cef setup`
  to pull the 0.3.3 runtime. Both 0.2.5 and 0.3.3 share the same CEF 150.0.19 archive
  (per `cef_requirements.generated.mjs`), so a 0.2.5 CEF already on disk is reused as-is
  and no new CEF download is triggered. Older local installs keep the project working
  but don't match the documented target until upgraded.
- **Do not reintroduce the old WebSocket app runtime route.** All IPC goes through
  `@proton_contract.Command` ops (`ext:labeler/<op>`, registered via
  `@proton_extension.typed(...)` in `extensions/labeler/extension.mbt`) or the headless
  `--stdio` JSON-RPC bridge in `app/stdio_main.mbt`.

## MoUI `app_moui/` migration status

> **Status: SPIKE SCOPE — future cleanup candidate.** `app_moui/` is a
> parallel spike demonstrating an alternative native view tree (MoUI 0.1.12)
> that could replace the CEF/JS frontend. It is **not** on the production
> path; the production frontend is `frontend/` (Vite + vanilla JS + CEF
> 150.0.19). The 217 tests in `app_moui/` are reference + smoke tests, not
> the gating regression suite — the gating suite is
> `extensions/labeler/labeler_test.mbt` (39 tests). `app_moui/` should
> eventually either be promoted to production scope (when MoUI upstream
> fixes the `@views.button` rendering bug) or be deleted entirely.

The CEF/JS frontend is being replaced by a native Moui 0.1.12 view tree driven through
`app_moui/main_native.mbt`. Phase history:

- **Phase 17** — `_build/run_smoke.ps1` + `--smoke` flag launches the packaged exe,
  raises the Win32 HWND to foreground, and screenshots via PrintWindow (`PW_RENDERFULLCONTENT`).
  Per-window screenshots saved as `_build/phase18x_smoke._window.png` (640×400 / 960×540 / etc.
  depending on host DPI).
- **Phase 18.A** — `app_moui/app.mbt::view()` calls `build_labeler_ui_view(model, 1280, 800)`,
  which returns `@moui.View[Msg]` from `@views.column` / `@views.row` / `@views.text` /
  `@views.canvas`. The toolbar / sidebar / canvas placeholder / status bar are all visible
  on screen, but the canvas text is just a placeholder.
- **Phase 18.B** — Layout fits the smoke window. Discovered that `@views.button`'s intrinsic
  height is theme-driven (`max(min_size.height, font_size + 2×sm_padding)` = 32 px regardless
  of the `height=` we pass because the dark theme's body font is 16 px + sm spacing is 8 px).
  Worked around by using `@views.text` placeholders for the toolbar mode buttons and the
  sidebar folder / class rows. Live screenshot (`_build/phase18b_postrevert._window.png`)
  shows all regions of the UI: toolbar header, nav row, sidebar headers + 4 folder rows +
  5-6 class chips, canvas placeholder, status bar `Ready` text. All 217 tests pass.

### Phase 18.C/D — `@views.button` rendering in this version is broken (FIXED in 18.E)

**Phase 18.C/D investigation history**: every form of `@views.button` we tried
became **completely invisible** in the smoke screenshot — no text, no background, even
when the row's column reported the button's expected size. Two attempts both failed the same way:

1. **`@views.frame(@views.button(text, theme, on_click), width=W, height=H)`** — the frame
   wrapper's child walking should reach the button's paint, but the button's DrawText command
   doesn't appear in the final command list. FrameLayout has no `fn paint` override, so it
   returns `ViewPaintPlan::empty()` by default — that's correct (children paint themselves),
   but somehow the button's commands vanish. Phase 18.C experiment confirmed this by replacing
   ONE sidebar text row with a framed button — that single row's text vanished while the 3
   surrounding text rows still rendered.

2. **`@views.button(text, theme=slim_button_theme_with_sm_0, on_click, width, height)`** (no frame).
   A custom `SpacingScale` with `sm = 0.0` should reduce content_height to `max(24, 16 + 0) = 24`
   instead of `max(24, 32) = 32`. Build succeeded, 217 tests passed, but every toolbar / sidebar
   button vanished from the smoke screenshot. The plain `@views.text` widgets next to the buttons
   (zoom %, section headers) still rendered correctly.

The diagnostic was: **`FillRoundedRectBrush` and `StrokeRoundedRectBrush` were silently
no-op'd in the rasterizer** (`rasterizer.mbt:1500-1502`, the `_ => ()` catch-all under the
Phase 11 "no-op commands" comment). Moui's `@style.append_control_background`
(`.mooncakes/wzzc-dev/moui/views/style/control_primitives.mbt:31,50`) emits exactly these
brush variants for every control background, so every button background vanished. The
button's `DrawText` *was* reaching the bitmap — the issue was that the missing background
made the button visually indistinguishable from the surrounding dark canvas, and in some
contrast modes the foreground color also dropped out, so neither the background nor the
label were visible.

### Phase 18.E — wire the brush variants into the rasterizer

Path (a) from the Phase 18.C/D "needs either (a) ... or (b) ..." note landed first because
it's an actionable code-level fix that lives entirely in `app_moui/rasterizer.mbt`:

1. Added two real `match` arms in `dispatch_command`:
   - `FillRoundedRectBrush(rr, brush)` → `paint_rounded_rect(buf, rr, clip, brush.fallback_color(), opacity)`
   - `StrokeRoundedRectBrush(rr, brush, w)` → `paint_stroke_rounded_rect(buf, rr, w, clip, brush.fallback_color(), opacity)`
2. `Brush::fallback_color` (`.mooncakes/wzzc-dev/moui/core/paint.mbt:514`) handles every
   brush variant — `Solid` returns the color, `LinearGradient` / `RadialGradient` return
   `start_color` / `center_color` respectively. The gradients lose fidelity (become solid
   blocks) but at least the control fills something, which is what Phase 18.B's
   `phase18b_postrevert._window.png` already showed.
3. Updated the no-op comment block (line 1497-1502) to remove the two brush variants from
   the catch-all list.
4. Added 2 new rasterizer tests (`fill_rounded_rect_brush_solid_paints_interior` and
   `stroke_rounded_rect_brush_solid_paints_perimeter_only`) that exercise the new arms.
   Test count: 217 → 219, all pass.

**Layout wrapper pattern** (path b's idea, also kept): every button in
`build_labeler_ui_view` / `sidebar_folder_rows` / `sidebar_class_rows` / toolbar nav row
is wrapped in `@views.frame(width, height)`. The frame clamps the button's
theme-driven intrinsic height back down to the row pitch we want (16 px for sidebar rows,
24 px for toolbar nav). Without the frame the dark theme's 16-px control font + 2×8-px
padding makes each button 32 px tall, inflating the column and clipping the status bar —
the same inflation bug Phase 18.B documented.

**Variant choice**: `ButtonVariant::Ghost` for sidebar + toolbar rows. Matches Moui's
own `navigation_sidebar` (`.mooncakes/wzzc-dev/moui/views/navigation/navigation_sidebar.mbt:28`)
and reads as "selectable list item" rather than "primary CTA". Primary would be too loud
for 10 sidebar rows.

**Smoke verification**:
- `_build/phase18e_smoke._window.png` — first row only (`> CARS.Part.01`) shows white
  Ghost-button background with rounded corners + label, while the 3 surrounding text rows
  (`> CARS.Body.01`, `> BAGS.Xray.01`, `> TNT.Lab.01`) stay as plain text. This is the
  A/B contrast that proved the rasterizer change was the actual fix.
- `_build/phase18e_full_smoke._window.png` — full rollout: 5 toolbar nav Ghost buttons
  (`[File] [Rect] [Polygon] [Keypoint] [Binding]`), 4 sidebar folder Ghost buttons, 6
  sidebar class Ghost buttons, plus the zoom% readout and section headers as text. All
  11 Ghost buttons render with their rounded-rect background + label visible.

**What's still on the SPIKE list**: the toolbar header row's "MoonBit Labeler" title
and "Folder: …" path label are also still text widgets (correct, since they're not
actionable controls). The canvas decoration is the only remaining Phase 16.C legacy
artifact — Phase 19 swapped the placeholder text for a real `@views.canvas` widget.

### Phase 19 — wire `@views.canvas` + bezier swoop decoration

Phase 19 replaces the Phase 18.B `@views.text("[canvas area]", width=600, height=120)`
placeholder in `build_labeler_ui_view` with a real `@views.canvas` widget whose draw
callback is the existing `paint_canvas_decoration` function. The measure callback
returns `c.max.width × max(40, c.max.height - 100)` so the canvas fills the row's
remaining width and bounds its height to `window.height - toolbar - status - margin`.

**Decoration shape**: dark-slate fill across the full frame + white bezier swoop
anchored at `frame.origin + (80, 10)` with the same MoveTo + CubicTo + LineTo + Close
verbs as the Phase 16.C legacy `build_labeler_ui_demo_frame` path. The swoop is
80 px wide × 40 px tall, sits inside the canvas frame regardless of where the column
puts it.

**Anchor math note**: the swoop uses `frame.origin.x + offset_x` (frame-relative
positive offsets) rather than `frame.origin.x + frame.size.width - 60` (frame-edge
relative negative offsets). Verified end-to-end: with the `right - X` form, the
swoop landed at the canvas's right edge (~`x=660`) where the host framebuffer's
retained-layer system clipped it on subsequent frames — the PrintWindow capture
caught a frame where the swoop had already been cleared. The `origin + offset`
form keeps the swoop safely inside the canvas frame.

**Verification**: smoke screenshot `_build/phase19_smoke_final._window.png` shows
the canvas area with the white bezier swoop visible at the top-right of the
sidebar/canvas split. 219/219 tests pass, `moon check --target native` reports 0
errors.

**Why this took several iterations**: the first two attempts placed the swoop at
`right - 60` etc. and it didn't render visibly. A debug iteration with a magenta
20×20 marker at `frame.origin + (10, 10)` plus a green fill_rect at the same offset
showed the canvas's actual origin was around `(295, 70)` (sidebar was ~295 px wide,
not the intrinsic 180 the comment block assumed). After switching to
`origin + offset` math, the swoop renders reliably.

## Stdio JSON-RPC bridge

The packaged exe (`target/proton-dist/moonbit-labeler/moonbit-labeler.exe`) doubles as
a CEF-free JSON-RPC server when launched with `--stdio`. Same 21 ops, same Request/Reply
structs, same JSON wire format as the CEF path — useful for embedding the labeler backend
in a Python Qt shell, scripts, or debug tooling.

```
$ echo '{"id":1,"op":"list_images","payload":{"path":"data/Image@skin","extensions":["jpg"]}}' \
    | ./moonbit-labeler.exe --stdio
{"type":"ready","ops":["list_images", ...21 ops...]}
{"id":1,"ok":true,"result":{"folder":"data/Image@skin","images":[...]}}
{"type":"bye"}
```

Wire format (one JSON object per line, newline-delimited):

- Banner on startup: `{"type":"ready","ops":[...21 op names...]}`
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

## Launch wrapper

`_build/run.bat` is the front door for the packaged exe. It picks between the
CEF/Proton GUI and the headless JSON-RPC bridge depending on CLI flag and
CEF runtime presence:

```
run.bat              auto: CEF if libcef.dll is present, else --stdio
run.bat --cef        always try CEF (will fail loudly if DLLs are missing)
run.bat --stdio      always run the headless JSON-RPC bridge
```

**Why the auto fallback exists.** The Proton/ProtonCLI build is the normal
delivery path and produces a working GUI. When that pipeline is broken
(CLI segfaults, CEF download is incomplete, the user is on a headless
host, or a downstream driver just wants the JSON-RPC bridge) the launcher
picks the right mode without requiring a rebuild.

**The "partial-fallback" caveat.** `moonbit-labeler.exe` is statically
linked against `libcef.dll` (it appears in the import table regardless
of which entry branch we take — the CEF symbols are pulled in by the
`@proton.file(...)` call site in `app/main.mbt`). So when the CEF
runtime is missing, BOTH the CEF path AND the `--stdio` path fail with
`STATUS_DLL_NOT_FOUND` (exit -1073741515 / 0xC0000135). The launcher
detects this and surfaces a clear actionable error instead of letting
the raw Windows code propagate. The "fallback" is therefore best read
as "the launcher's intent is to prefer CEF when available and to give
a clean diagnostic otherwise" — not as a true CEF-free stdio.

**True CEF-free stdio** requires a separate build target that doesn't
import the Proton runtime at all (a second `app_stdio/moon.pkg` whose
entry imports only `labeler` + `async` + `core/{env,json}`). That
binary could be ~3 MB (no CEF runtime) and run on any Windows host
without setup. Tracked as a follow-up; the one-binary design is good
enough for the current single-host dev workflow.

## Security

- Never commit secrets — there is no `.env`; runtime data lives under `data/`, which is
  gitignored.
- The `--stdio` bridge is a privileged local IPC surface: it accepts JSON-RPC from whoever
  owns the parent process. Only invoke it from a trusted local driver; do not expose it
  on a network socket without an explicit auth layer.
- CEF download (`proton_cli cef setup`) is a 150 MB tarball — verify the SHA256 from
  upstream if operating in a high-trust environment.
