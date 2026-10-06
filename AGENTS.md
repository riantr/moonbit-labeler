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
- `moon.mod`               — `riantr/moonbit_labeler` v0.2.12, depends on `moonbit-community/proton@0.3.3`,
  `proton_contract@0.3.3`, `moonbitlang/async@0.22.4`, and `wzzc-dev/moui@0.1.12`. The image codec comes from the shared
  `riantr/moonbit_image@0.3.7` package (pulled in transitively). A prior vendored copy under
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

### Phase 20 — header text height bumps + status-bar spacer

Phase 20 is a polish pass over Phase 19's `@views.canvas` view tree that
fixes two visible regressions in the title-bar / sidebar / status-bar
regions:

1. **Title-bar header text compressed.** The toolbar's top row holds
   `"MoonBit Labeler"` (`TextRole::Title`, 21 px font) and
   `"Folder: " + model.folder` (`TextRole::Body`). With `height=24` both
   glyphs had their bottom 1-2 px cut off — visibly squashed in
   `phase19_smoke_final._window.png`. Bumped both to `height=32` so the
   21 px Title font has ≥28 px box + ~10 px breathing room for ascender
   + descender. The toolbar's footer row's `zoom %` readout (Body font)
   stays at 24 px.

2. **Sidebar section headers ("Folders" / "Classes") compressed.**
   Same root cause — `TextRole::Title` at 21 px needs ≥28 px box.
   Bumped both section headers from `height=24` to `height=32`. The
   folder rows + class chips (their own `@views.button` children, all
   wrapped in `@views.frame(width=180, height=16)` from Phase 18.E) stay
   at 16 px so the row pitch is unchanged.

3. **`@views.spacer(weight=1.0)` between toolbar and main row.** The
   outer column was `[toolbar, main_row, status_bar]` with no flex
   element. When `toolbar + main_row + status_bar` summed past
   `window_h` the status bar got clipped off-screen — visible in the
   Phase 19 smoke capture (no "Ready" text at the window bottom).
   Phase 20 inserts `@views.spacer(weight=1.0)` as the second child of
   the outer column so the column's flex layout gives it all leftover
   vertical space, pushing the main row to the top and the status bar
   to the window bottom regardless of canvas intrinsic height.

**Bonus: status bar text height 16→24.** The 16 px Body font needed
≥20 px box for full glyph height; 16 px clipped descenders of "g",
"p", "y" so multi-line toasts (when `model.toastMessage` carries a
sentence) rendered flat-topped. Bumped to 24 to match the section
header height.

**Known issue (deferred):** the smoke capture at the bottom of the
window still shows no "Ready" text in the status bar — even after the
spacer is in place. Possible causes (in order of likelihood):
- DPI scale on this host is 0.5x (window logical 1920×1080, capture
  physical 960×540); 24 px logical = 12 px physical which is right at
  the bitmap-font's per-glyph minimum readable size.
- `@views.text` rendering on the status bar's last child doesn't
  reach the windows_skia rasterizer for some reason specific to the
  bottom-edge widget (the rest of the toolbar + sidebar + canvas all
  render fine).
- The `windows_skia` rasterizer in MoUI 0.1.12 has a known issue
  with text painted below a certain y-offset (Phase 19 had a similar
  bug for the bezier swoop — fixed by switching from `right - 60`
  edge-relative coordinates to `origin + offset` frame-relative
  coordinates).

Layout math is verified correct (column measures `toolbar + spacer +
main_row + status_bar = 1080` logical px in the 1080-tall window; slack
fills the spacer). Status bar visibility is a follow-up rasterizer /
DPI issue — **not blocking** for Phase 20 commit.

**Verification:** `_build/phase20_final_smoke._window.png` shows the
toolbar + sidebar + canvas layout with the Phase 18.E button styling
+ Phase 19 bezier swoop intact; 219/219 rasterizer/labeler tests pass.

### Phase 5.2 — wire canvas_view(model) into the view tree + visual smoke demo

Phase 5.2 is the MoUI port's first end-to-end verification that
`model.imageSource → DrawImage → cache hit → paint_image → buffer
blit → windows_skia presenter → pixels on screen` works as a single
pipeline. Prior phases had the infrastructure but no view-tree
connection — the canvas still showed the Phase 19 bezier swoop
decoration regardless of `model.imageSource`.

**What landed:**

1. **`labeler_ui.mbt` — replace bezier swoop with `canvas_view(model)`.**
   The Phase 19 `@views.canvas(measure, draw=paint_canvas_decoration)`
   placeholder is swapped for the model-driven `canvas_view` builder.
   `canvas_view` returns a `@layout.stack` of two layers:

   - **Static layer** (cached via `ViewPaintLayer` with `cache_key`):
     neutral background + `model.imageSource == ""` placeholder
     StrokeRect OR `DrawImage` (when imageSource != "" + cache hit),
     plus the model's annotation set drawn in iteration order. Cache
     key derives from imageSource + annotations + pan + zoom +
     naturalSize + fitMode so `LoadTestImage` / `LoadImage` invalidate
     automatically.
   - **Dynamic layer**: selected-annotation handles + cursor
     crosshair + draft polygon/rect preview (only paints when those
     states are non-empty; transparent at startup).
   - `on_drag` → `Pan` (image pan), `CursorMoved` (hit-test).
   - `on_secondary_tap` / `on_double_tap` → `ToggleZoomDragMode`.

   `cached_static_layer_view`'s layout impl returns
   `ctx.constraints.max`, so the canvas fills whatever space the
   outer row gives it. No custom measure needed.

2. **`renderer.mbt` — `register_test_image_in_renderer(source, w, h, bytes)`**.
   Public wrapper around the module-local `image_cache` so
   `main_native.mbt` (or any future startup helper) can inject
   pre-decoded RGBA8 bytes. Returns `true` on success / `false` if
   `load_bytes` rejected the bytes (mismatched length, zero
   width/height, etc.).

3. **`main_native.mbt::register_synthetic_test_image`** — builds a
   200×200 RGBA8 magenta test fixture inline and injects it under
   source key `_phase5_2_synthetic` at startup. Chosen as solid
   magenta for unambiguous visibility in the smoke screenshot
   (any deviation from pure magenta = bug somewhere in the pipeline).
   See "Known issue" below for the 4-stripe variant we tried first.

4. **`app.mbt::Model::new` — `imageSource: "_phase5_2_synthetic"`**
   by default so the cold-start smoke demonstrates the full
   pipeline without requiring a real image file on disk + a working
   sync→async file-read bridge (both still blocked — see
   `image_header.mbt` doc). Set `imageSource: ""` to revert to the
   Phase 5.2 placeholder StrokeRect.

**Why this matters:**

- Confirms the existing `phase14_image_test.mbt` cache+blit
  pipeline works through MoUI's view tree (not just in unit tests).
- `LoadImage(path)` (5.6) still can't actually load real files (no
  sync→async bridge), but the entire downstream chain — image
  cache, `paint_image`, fit-contain math, pan/zoom transform,
  windows_skia presenter — is now verified working in the smoke.
- `LoadTestImage(path, w, h)` (5.2 deprecated shim) also gets a
  smoke test for free: when the user wants to verify a specific
  image, pre-decoding the bytes + `image_cache.load_bytes` + set
  `model.imageSource` via `LoadTestImage` produces the expected
  output.

**Known issue (deferred):** The smoke screenshot shows the magenta
fixture as a solid uniform color across the entire canvas area.
The 4-stripe (red/green/blue/yellow per y or x range) variants
tested during development only rendered 2 of the 4 stripes (top
half red, bottom half green; or left half red, right half green)
regardless of which MoonBit syntax was used (`if/else if`, `match`,
direct byte pushes with or without `ignore()`, mirroring
`phase14_image_test.mbt`'s style). The same solid-magenta code
without branching produces a valid solid magenta. The branching
case appears to clamp src_h to ~100 instead of 200 in
`paint_image`'s loop. Tracked as a follow-up — Phase 5.2 doesn't
need the 4-stripe variant to ship; solid magenta proves the cache +
blit + presenter + ViewPaintLayer caching all work end-to-end.

**Verification:** `_build/phase5_2_smoke_final._window.png` shows
the toolbar + sidebar + canvas with solid magenta filling the canvas
viewport (cache hit path: image → DrawImage → nearest-neighbor
sampling → BGRA buffer → windows_skia presenter → pixels on
screen). 219/219 app_moui tests still pass; `moon check --target
native` 0 errors; smoke `run_smoke.ps1 -OutFile ... -WaitSeconds 8`
captures the screenshot in 8 s.

### Phase 5.3 — fit-contain offset for annotations + binding arrow (visual smoke demo)

Phase 5.3 wires the existing canvas_view annotation + binding pipeline
into the live UI. Phase 5.2 proved the image-cache → blit → presenter
chain works end-to-end on a magenta fixture; Phase 5.3 layers the
annotation + binding renderer on top so a single smoke screenshot
demonstrates all four Shape variants (Rect fill+stroke, Polygon
fill+stroke+vertex_dots, Keypoint circle, Binding dashed arrow +
arrowhead) without requiring a real .json label file + working
sync→async file-read bridge.

**What landed:**

1. **`app.mbt::Model::new`** — defaults `annotations:
   default_demo_annotations()` + `bindings: default_demo_bindings()`
   so cold-start state has 3 annotations + 1 binding visible without
   requiring `LoadImage` (still blocked — see `image_header.mbt` doc).

   - `default_demo_annotations()` — Rect `(40,40)→(140,140)` + 3-vertex
     Polygon triangle `(80,60)/(180,90)/(110,170)` + Keypoint `(60,170)`.
     Covers every Shape variant in `@views/canvas` with deliberately
     small coords so they fit inside the 200×200 magenta fixture even
     when the canvas viewport is wider.
   - `default_demo_bindings()` — 1 binding from `rect-1` centroid
     `(90,90)` to `kp-1` centroid `(60,170)`. Dashed yellow arrow with
     arrowhead at the kp-1 end, so the binding's fill+stroke+arrowhead
     trio is visible in one smoke.

2. **`canvas_view.mbt::img_to_screen`** — signature changed from
   `(p : Point, pan, zoom)` to `(p : Point, dst_origin : Point, pan,
   zoom)`. Pre-Phase 5.3, `img_to_screen` returned the canvas-local
   position assuming the image natural-origin == canvas (0,0), which
   is only true when the image's fit-contain destination rect
   coincides with the canvas top-left. When the canvas is wider than
   the image (the smoke case: 200 px image in a ~600 px canvas
   viewport), the fit-contain math centers the image with horizontal
   padding — so an annotation at image-natural `(40, 40)` lands at
   canvas-local `(40 + left_padding, 40 + top_padding)`, not at
   canvas-local `(40, 40)`. The `dst_origin` parameter carries that
   left/top padding into every primitive, so the annotation lines up
   with where the image actually drew.

3. **11 helper functions updated** to thread `dst_origin` through
   the call chain: `draw_annotation`, `draw_handles`, `draw_bindings`,
   `draw_binding_arrow`, `draw_cursor_crosshair`, `draw_polygon_path`,
   `draw_polygon_fill`, `draw_polygon_vertex_dots`, `draw_draft_polygon`,
   `draw_draft_rect`, `draw_binding_from_marker`. The fit-contain rect
   is precomputed once in `issue_static_commands` + `draw_dynamic_layer`
   via `fit_contain_rect(frame.size, natural_w, natural_h)` and passed
   to each helper as `dst_origin = rect.origin`.

4. **First-attempt bug discovery** (smoke
   `_build/phase5_3_smoke._window.png`): the annotation primitives
   drew at image-natural coords directly, so the rect outline landed
   at canvas-local `(40, 40)` (in the sidebar area, overlapping the
   "Folders" text). Adding `dst_origin` and threading it through
   the helpers fixed the offset — see
   `_build/phase5_3_smoke_v2._window.png` for the corrected render.

**Verification:** `_build/phase5_3_smoke_v2._window.png` shows the
toolbar + sidebar + canvas with:
- 200×200 magenta image filling the canvas viewport (Phase 5.2 chain).
- Red Rect outline `(40,40)→(140,140)` at the image-natural position
  (now correctly inside the image's fit-contain dest rect, not at the
  canvas top-left). Label "rect-1" inside the rect.
- Red 3-vertex Polygon triangle outline + fill + vertex dots + label
  "poly-1" at image-natural position.
- Red Keypoint circle with white outline + label "kp-1" at
  image-natural `(60, 170)`.
- Yellow dashed binding arrow with arrowhead from rect-1 centroid
  `(90, 90)` to kp-1 centroid `(60, 170)`.

219/219 app_moui tests pass; `moon check --target native` 0 errors.
`app_moui/_build/native/release/build/app_moui.exe` (1.2 MB) launches
under `_build/run_smoke.ps1 -OutFile _build/phase5_3_smoke_v2._window.png
-WaitSeconds 8` and renders the screenshot in 8 s.

**Known issues deferred:**
- `paint_canvas_decoration` is now unused (Phase 5.2 swap) but the
  function remains for backwards compat — produces an unused_function
  warning, non-blocking.
- 4-stripe multi-color fixture bug from Phase 5.2 is still open. Solid
  magenta remains the demo default until the `paint_image` src_h
  clamping bug is root-caused (likely an off-by-one in the loop
  bounds for branching paths, see Phase 5.2 deferred).
- Phase 5.3 still uses the synthetic fixture path — production
  `LoadImage(path)` needs the sync→async file-read bridge (blocked).

### Phase 5.4 — wire handle drag end-to-end (ModifyHandle + CursorMoved routing)

Phase 5.4 connects the existing `apply_handle_move` (hittest.mbt)
and `DragState` (app.mbt) into the actual `update` chain so
dragging a handle on the selected annotation actually mutates
the annotation's points array. Pre-5.4 the `ModifyHandle` Msg
handler was a no-op placeholder; the drag infrastructure
existed but the points array was never written.

**What landed:**

1. **`app.mbt::mutate_annotation`** — pure helper that runs a
   caller-supplied transform `f : (Annotation) -> Annotation?`
   against the annotation with matching `ann_id`, replaces it
   when `f` returns `Some(new_ann)`, and otherwise leaves the
   model unchanged (no match, or `f` rejected). The new model
   always has `staticLayerDirty = true` + `label.dirty = true`
   so the cache invalidates and the next save picks up the
   change. Reusable by future handlers (delete vertex, insert
   vertex, change shape).

2. **`app.mbt::ModifyHandle(ann_id, handle_idx, new_pt)` handler**
   — wires through `mutate_annotation` with `apply_handle_move`
   as `f`. The handler is now a one-liner that replaces the
   Phase 5.3 no-op placeholder. When the annotation's
   `handle_idx` doesn't match its shape (e.g. polygon vertex
   index out of range), `apply_handle_move` returns `None`
   and `mutate_annotation` preserves the original — no
   half-applied drags.

3. **`app.mbt::CursorMoved(img_pt, canvas_pt)` handler** —
   when `dragState` is `Some(drag)`, routes the cursor move
   through to `ModifyHandle(drag.ann_id, drag.handle_idx,
   img_pt)` via `Effect::send`, keeping the per-frame handler
   chain single-step (`CursorMoved → Effect::send(ModifyHandle)
   → mutate → redraw`). When `dragState` is `None`, falls back
   to the Phase 5.3 hit-test path (12 px handle radius for the
   selected annotation, 4 px body radius for selection).

4. **`app.mbt::program_with_init(initial : Model)`** — alternate
   program factory that lets the caller supply a custom
   initial Model. Used by the smoke harness to demonstrate
   the drag visually (see point 6).

5. **`hittest.mbt::apply_handle_move` — corrected Rect handle
   math.** Pre-5.4 the handle_idx=4/5/6/7 arms set BOTH
   `new_p1` and `new_p2` from `new_pt`, collapsing the rect to
   a single point when dragging BR/B/BL/L handles. The new
   logic restricts each handle to moving only the corners it
   geometrically affects: corner handles (0, 2, 4, 6) change
   2 coords; edge-midpoint handles (1, 3, 5, 7) change 1 coord.
   Existing tests only covered handle_idx=0 + Polygon vertex,
   which is why the bug went unnoticed until Phase 5.4 wired
   the handler end-to-end.

6. **`main_native.mbt::build_demo_drag_model`** — at startup,
   dispatches `BeginDragHandle("rect-1", 4)` → `CursorMoved` →
   `ModifyHandle` → `EndDragHandle` against `Model::new()`,
   then passes the post-drag model to `program_with_init`. The
   default Rect's BR corner starts at `(140, 140)` and the demo
   drag resizes it to `(175, 175)`. The smoke screenshot
   (`_build/phase5_4_smoke._window._window.png`) shows the
   resized rect outline + the binding arrow's origin centroid
   shifted accordingly, visually demonstrating that the cache
   invalidation + mutation pipeline works end-to-end.

7. **10 new tests** (229 total, was 219):
   - `ModifyHandle — Rect BR corner resize mutates points + invalidates cache (5.4)`
   - `ModifyHandle — Polygon vertex move preserves other vertices (5.4)`
   - `ModifyHandle — unknown id is a no-op (5.4)`
   - `drag sequence — BeginDragHandle + CursorMoved + EndDragHandle (5.4)`
   - `CursorMoved — no dragState: hit-test path (5.4)`
   - `CursorMoved — with dragState: preserves dragState (5.4)`
   - `apply_handle_move — rect BR corner drag (handle 4) keeps TL fixed`
   - `apply_handle_move — rect BL corner drag (handle 6) updates both axes`
   - `apply_handle_move — rect T edge-mid drag (handle 1) moves TL.y only`
   - `apply_handle_move — rect L edge-mid drag (handle 7) moves TL.x only`

**Verification:** `_build/phase5_4_smoke._window._window.png`
shows the post-drag state: rect-1 outline extends to ~(175, 175)
in image-natural coords (vs. the original (140, 140)), 4 corner
handles visible at the rect corners, poly-1 triangle + kp-1
keypoint at original positions, yellow dashed binding arrow now
connects the rect's new centroid (post-drag) to kp-1's centroid.
229/229 tests pass; `moon check --target native` 0 errors;
`app_moui/_build/native/release/build/app_moui.exe` (1.2 MB)
launches + renders in 8 s.

**Known issues deferred:**
- The actual mouse-drag UX (cursor over a handle → press → drag
  → release) is still wired through `BeginDragHandle` only
  via a manual Msg dispatch; the canvas_view's `on_drag` and
  `on_press` handlers don't yet emit `BeginDragHandle` based
  on hit-test state. Phase 5.5 picks that up.
- `Effect::send` from `CursorMoved` enqueues a follow-up Msg
  in the same frame; Moui 0.1.12's runtime processes the queue
  before the next paint, so the user perceives a single
  end-to-end drag. Verified by the smoke screenshot but not
  pinned by an explicit unit test (Effect values aren't
  inspectable from MoonBit test code without an in-package
  observer).
- `apply_handle_move` assumes `p1 = TL, p2 = BR` ordering.
  Rects drawn from BR→TL by the user (rare in practice — the
  default rect tool normalizes to TL→BR) would have inverted
  handle labels. Tracked as a follow-up: normalize `p1`/`p2`
  to `(min, max)` at write time.

### Phase 5.5 — wire on_drag phase routing (Started/Changed/Ended → BeginDragHandle/CursorMoved/EndDragHandle)

Phase 5.5 closes the loop on the drag UX: clicking on a handle
of the selected annotation now arms `BeginDragHandle` based on
hit-test state, and releasing the mouse clears it via
`EndDragHandle`. Pre-5.5 the `BeginDragHandle` / `EndDragHandle`
chain was wired in `update` but the canvas view only ever
dispatched `Pan(delta)` + `CursorMoved` per drag frame — there
was no path from "user clicked on a handle" to "model.dragState
is Some".

**What landed:**

1. **`Msg::BeginDragHandle(ann_id, handle_idx, start_img_pt)`**
   — added `start_img_pt : Point` to the variant so the
   handler doesn't need to read `model.cursorImgPt` (which
   may be `None` on the very first drag frame, before any
   `CursorMoved` has fired). The handler records the explicit
   `start_img_pt` verbatim in `dragState.start_img_pt`.

2. **`app.mbt::BeginDragHandle handler`** — simplified from
   the Phase 5.3 `match cursorImgPt { Some → ..., None → (0,0) }`
   fallback to a single-branch handler that uses the explicit
   parameter. Removes the silent "drag origin = (0, 0) when
   cursorImgPt is None" failure mode that pre-5.5 produced when
   `on_drag` Started fired before any `CursorMoved`.

3. **`canvas_view.mbt::canvas_view` second `on_drag` callback**
   — replaced the Phase 5.11 always-fire `CursorMoved` with a
   `match ev.phase` dispatch:
     - `Started` → `hit_test_handle(img_pt, annotations, sel_id, 12.0)`;
       if Some, dispatch `BeginDragHandle(ann_id, handle_idx, img_pt)`;
       else dispatch `CursorMoved(img_pt, canvas_pt)`.
     - `Changed` → `CursorMoved(img_pt, canvas_pt)` (the
       Phase 5.4 `dragState is Some → ModifyHandle` routing
       fires inside the `CursorMoved` handler).
     - `Ended` → `EndDragHandle` (no-op when dragState is
       already None).
     - `Idle` / `Pending` / `Cancelled` → `CursorMoved` for
       cursor tracking.

4. **`main_native.mbt::build_demo_drag_model`** — updated to
   use the new `BeginDragHandle` signature. The smoke
   screenshot proves the entire chain
   (Started → BeginDragHandle → CursorMoved → ModifyHandle →
   Ended → EndDragHandle) still produces the same resized rect
   as Phase 5.4.

5. **5 new tests** (234 total, was 229):
   - `BeginDragHandle — uses explicit start_img_pt, not cursorImgPt (5.5)`
   - `BeginDragHandle — works with cursorImgPt = None (5.5)`
   - `on_drag Started phase logic — cursor over selected handle arms BeginDragHandle (5.5)`
   - `on_drag Started phase logic — cursor NOT over handle does not arm drag (5.5)`
   - `EndDragHandle — clears dragState (already None) (5.5)`

**Verification:** `_build/phase5_5_smoke._window._window.png`
shows the same post-drag state as Phase 5.4 (rect-1 BR corner
resized from `(140, 140)` → `(175, 175)`, binding arrow's
origin centroid shifted accordingly). Visual identity is the
expected outcome — Phase 5.5 is purely an internal-routing
change, not a visual one. 234/234 tests pass; `moon check
--target native` 0 errors; `app_moui/_build/native/release/build/
app_moui.exe` (1.2 MB) launches + renders in 8 s.

**Known issues deferred:**
- The `Started → hit_test_handle` decision is made with the
  `model.selectedId` from the previous frame. If the user
  clicks on a handle BEFORE any prior `CursorMoved` has
  selected anything, `selectedId` is None and the handle drag
  doesn't arm. Tracked as a follow-up: also fire a
  `hit_test_select` on `Started` when `selectedId` is None, so
  clicking on a handle always selects the annotation AND
  begins the drag in the same frame.
- `on_drag` doesn't distinguish between left-button drag and
  middle/right-button drag. Moui 0.1.12 doesn't expose the
  button ID on `DragGestureEvent`, so right-click-drag (which
  Phase 5.19 repurposes for wheel-zoom simulation) is also
  routed through this same handler chain. Side effect: when
  `zoomDragMode` is on, the first `on_drag` callback's
  `Pan(delta)` is interpreted as a zoom delta by the
  `update` handler, but the second `on_drag` callback's
  `Started → BeginDragHandle` still tries to arm a handle
  drag. The handle drag arms then no-ops on the next
  `CursorMoved` (because the cursor's screen position has
  moved past any handle). User-visible impact: clicking on a
  handle while zoom-drag mode is on briefly flashes the
  handle hover state but doesn't actually drag it. Tracked
  as a follow-up.

### Phase 5.6 — CanvasPressed: select-then-arm in one press (fixes the Phase 5.5 deferred)

Phase 5.6 fixes the first-click bug that Phase 5.5 explicitly
deferred: "if the user clicks on a handle BEFORE any prior
`CursorMoved` has selected anything, `selectedId` is None and
the handle drag doesn't arm."

**Root cause.** The Phase 5.5 press logic lived in
`canvas_view.mbt`'s `on_drag` closure, which closes over a
**stale `model` snapshot** captured when the view tree was
built. Two consequences:

1. `model.selectedId` read in the closure was always one frame
   behind. On a cold start (`selectedId == None`) the closure
   took the `None` branch and could never arm a handle drag.
2. The closure cannot mutate the model, so any hit-test result
   had to be smuggled back through a second `Msg` round-trip.

The user-visible symptom: to drag a handle you had to **click
once to select the annotation, then click again on the handle**
— two presses for one drag.

**What landed:**

1. **`Msg::CanvasPressed(Point, Point)`** — new variant
   carrying `(img_pt, canvas_pt)`, the same shape as
   `CursorMoved`.

2. **`app.mbt::CanvasPressed` update handler** — runs the whole
   press decision against the **live** model:
   - record `cursorImgPt` / `cursorCanvasPt`;
   - `hit_test_select` resolves the selection (prefer handles
     of the current selection, else topmost body hit);
   - `hit_test_handle` against the *freshly resolved* selection
     with `handle_hit_radius`; if it hits, arm `dragState` in
     the same frame;
   - marks only `dynamicLayerDirty` (a press never mutates
     geometry, so the static layer cache doesn't need to
     invalidate — this matters because the static layer holds
     the background + image blit).

3. **`canvas_view.mbt` Started branch** — reduced from a
   9-line nested `match` to a single `CanvasPressed(img_pt,
   canvas_pt)`. All hit-test logic now lives in `update`, where
   it's both live and unit-testable.

4. **`hittest.mbt` — hoisted the hit radii to named constants**
   `pub let handle_hit_radius : Double = 12.0` and
   `pub let body_hit_radius : Double = 4.0`. These were bare
   literals at 3 call sites (`hit_test_select` ×2 plus the
   now-removed canvas_view literal), which is exactly the shape
   of a value that drifts. `hit_test_select` now uses the
   constants.

5. **`main_native.mbt::build_demo_drag_model`** — the smoke
   harness now dispatches the real `CanvasPressed` Msg from a
   genuine cold start (`selectedId == None`, `dragState ==
   None`) instead of a hand-constructed `BeginDragHandle`. So the
   smoke screenshot is now evidence for the 5.6 path specifically,
   not just for 5.4's hand-built sequence.

**Toolchain gotcha (cost ~6 iterations to find).** MoonBit
**rejects `let` bindings written directly in a match arm's action
part**:

```
Error: [3002] Using let statement in `the action part of a
matching case` directly is not allowed. Consider moving the let
binding into a curly braces block.
```

The failure mode is badly misleading: instead of a single clean
diagnostic, `moon test` emitted a cascade of **`Error: [4139]`
"this expression has type (Model, Effect[Msg]), its value cannot
be implicitly ignored"** on *every other arm of the same `match`*
(including arms ~700 lines earlier, e.g. `PickFolder`). The
parser bails and the type checker then demotes the enclosing
`match msg` to a statement position, so every non-Unit arm
becomes an "ignored value".

- **Rule:** any match arm needing intermediate bindings must be
  written `Pattern => { let x = ...; ... }` with the braces.
- **Symptom to recognise:** many `[4139]` errors clustered on
  arms you did *not* touch → look for a *single* `[3002]`
  earlier in the same file, and check whether the arm that
  actually changed has a `let` in it.
- **Also note:** `moon check` reported **0 errors** on this exact
  source while `moon test` reported the cascade. Don't trust
  `moon check` alone for match-arm syntax — always run
  `moon test`.
- A second red herring on the way: hoisting a `match` expression
  out of a record-literal field value (`dragState: match x {…}`)
  was tried as a fix and was **not** the cause — a bare `match`
  as a struct field value is fine; the `let`-in-arm rule is the
  real constraint.

**7 new tests** (241 total, was 234):
- `CanvasPressed — first click on a handle selects AND arms drag in one press (5.6)` — the A/B proof of the fix; the same press that left `dragState == None` pre-5.6 now sets both `selectedId` and `dragState`.
- `CanvasPressed — press on body selects without arming drag (5.6)` — guards the inverse property (an interior click must not nudge a rect).
- `CanvasPressed — press on empty canvas clears selection (5.6)`
- `CanvasPressed — re-select across annotations arms the new one (5.6)` — pressing poly-1's handle while rect-1 is selected must switch, not keep the stale selection.
- `CanvasPressed — does not dirty the static layer (5.6)`
- `CanvasPressed arm → CursorMoved actually resizes the rect (5.6)` — end-to-end from a cold-start press.
- `hit radii constants — 12 px handle / 4 px body (5.6)`

**Verification:** `_build/phase5_6_smoke._window._window.png` shows
the same post-drag state as 5.4/5.5 (rect-1 BR corner resized
`(140, 140)` → `(175, 175)`), but now produced from a genuine
`CanvasPressed` cold-start press. 241/241 tests pass;
`moon check --target native` 0 errors; `app_moui/_build/native/
release/build/app_moui.exe` (1.2 MB) launches + renders in 8 s.

**Known issues deferred (carried from 5.5):**
- `on_drag` still can't distinguish left/right/middle button
  because Moui 0.1.12's `DragGestureEvent` carries no button ID.
  In `zoomDragMode`, a right-drag still briefly arms a handle
  drag before no-oping. Needs either a Moui-side button field or
  a local "suppress press while zoomDragMode" guard.
- `apply_handle_move` assumes `p1 = TL, p2 = BR` ordering. A rect
  written BR→TL would have inverted handle labels. Tracked:
  normalise corners in `handle_points` + `apply_handle_move` +
  the Rect branch of `draw_annotation` together (all three read
  `points[0]` / `points[1]` directly today).
- 4-stripe multi-colour fixture bug (Phase 5.2) and
  `paint_canvas_decoration` now-unused warning both still open.

> **CORRECTION (added in Phase 5.7).** Two claims in the section
> above are wrong, and the screenshot claim is wrong outright.
>
> 1. **The Phase 5.6 smoke screenshot was stale.** It was captured
>    from a *pre-5.6* debug binary — see the Phase 5.7
>    stale-binary section below. The 5.6 screenshot showed an
>    **unselected** rect, but the 5.6 source (`CanvasPressed`
>    setting `selectedId` and never clearing it) must render a
>    **selected** rect. The selected appearance only appeared once
>    the debug exe was genuinely rebuilt in Phase 5.7. So
>    `phase5_6_smoke._window._window.png` is **not** evidence for
>    Phase 5.6. The 241/241 unit tests, including the cold-start
>    `CanvasPressed` A/B test, remain valid evidence.
> 2. **The 4-stripe fixture bug and the rect corner-order worry
>    were both unfounded**, and are closed in Phase 5.7 with
>    regression tests.

### Phase 5.7 — disprove two deferred "bugs", harden the smoke harness

Phase 5.7 spent its effort converting three deferred *unknowns* into
settled facts, because two of them turned out not to be bugs at all
and one was a harness problem that had been silently corrupting
evidence.

#### 1. The Phase 5.2 "4-stripe" bug was never a blit bug

The Phase 5.2 note recorded: the 4-band fixture "only rendered 2 of
the 4 stripes (top half red, bottom half green)", and hypothesised
that `paint_image` "appears to clamp src_h to ~100 instead of 200".

**That hypothesis is wrong.** `paint_image` computes
`src_y = dy * src_h / dst_h` — a correct nearest-neighbour mapping
with no clamp — and `ImageCache::load_bytes` rejects any buffer whose
length isn't exactly `w * h * 4`, so a malformed fixture could never
reach the blit as a half-height image.

The reason the bug was never caught is a **coverage gap**: the
pre-existing blit test (`phase14_image_test.mbt`) uses a 4x4 image at
1:1 scale, where every source pixel is visited exactly once — a
correct mapping and a broken one produce identical output. The
reported failure needs a *banded* image at a *different* scale, which
is exactly what the real canvas does (200x200 source into a
several-hundred-px fit-contain viewport).

New `app_moui/phase5_7_blit_test.mbt` closes that gap, driving the
**shipped** fixture through the real rasterizer:
- 200x200 4-band fixture → 400x400 destination (2x upscale): all 4
  bands present and correctly placed.
- Same fixture → 100x100 destination (0.5x downscale): all 4 bands
  present.
- Vertical bands across the full width: guards the `src_x` axis,
  which the row-banded cases never touch.
- `banded_rgba8_fixture(200, 200).length() == 200 * 200 * 4`: pins
  the byte count, since a bad count is silently refused by
  `load_bytes` and would show up on screen as a placeholder rather
  than an error.

All four passed on their first run, confirming the blit path was
never broken. The original failure was in throwaway fixture code that
no longer exists.

#### 2. Ship the banded fixture, because solid magenta was a degenerate check

`image_cache.mbt` gains `pub fn banded_rgba8_fixture(w, h) -> Bytes`
plus `pub fn band_colour(band)`, and
`main_native.mbt::register_synthetic_test_image` now uses it.

The reason this matters beyond aesthetics: **a uniform source cannot
distinguish a correct source-sampling mapping from a wrong one**,
because every mapping yields the same pixels. That is precisely why
Phase 5.2's magenta fixture was able to look like a passing smoke
while an adjacent mapping concern was untested. Banding makes the
fixture self-validating — a dropped, repeated, or shifted band is
visible at a glance — and the tests above pin the same builder the
app actually ships (not a copy that could drift).

Note: `_build/phase5_7_smoke._window._window.png` shows the red and
green bands, but blue and white fall **below the captured window
edge** — the 200x200 fixture is scaled taller than the 960x540
capture. So the screenshot proves the fixture is live and the bands
are in the right order and proportion, but the unit tests, not the
screenshot, are the authoritative all-4-bands evidence.

#### 3. The rect corner-order worry was unfounded

Phase 5.4-5.6 carried: "`apply_handle_move` assumes `p1 = TL,
p2 = BR`; a rect written BR→TL would have inverted handle labels."

Tested empirically, the code is **order-agnostic by construction**:
`handle_points` derives all 8 handles from whatever the two points
are, and `apply_handle_move` moves the same point the matching handle
sits on. For a BR→TL rect the *indices* rotate (index 0 lands on the
visually bottom-right) but the set of 8 handle positions is
identical, and each drag still moves the corner the user grabbed. No
handle is visually distinguishable from its neighbours, so the index
rotation is invisible. `draw_annotation` already normalised with
min/max, and `hit_test_body` did too.

Pinned by 3 tests in `hittest_test.mbt`: the flipped rect's 8 handles
are set-equal to the upright rect's; handle 0 sits on the visually
bottom-right and dragging it moves that corner; and a BR-first rect
is still body-hit-testable.

#### 4. zoom-drag press guard

Deferred from Phase 5.5: Moui 0.1.12's `DragGestureEvent` carries no
button ID, so *every* pointer-down reaches `CanvasPressed` — including
the right-drag that enables zoom-drag mode. A right-drag starting on a
handle would arm a handle drag, and that arm would survive into the
next `Changed` frame, where the movement is reinterpreted as a zoom
delta — so the annotation jumped by one frame of cursor travel.

`CanvasPressed` now skips the arming step entirely when
`model.zoomDragMode` is true. Selection is still recorded (a click is
a click); only the drag arm is suppressed. Two tests cover it, with
an explicit `zoomDragMode: false` control so a bug that disabled
arming unconditionally would fail.

#### 5. Stale-binary trap in `_build/run_smoke.ps1` (found the hard way)

`run_smoke.ps1` line 68 hardcodes the **debug** exe. The project habit
is `moon build --target native --release --strip` before a smoke —
and `--release` does **not** refresh the debug artifact. So a
`-SkipBuild` smoke run after a release build screenshots a stale
binary, and because a stale binary still renders a plausible UI, the
mistake is invisible unless you already know to look.

This actually happened: `phase5_6_smoke._window._window.png` shows
an **unselected** rect (salmon stroke, round white handles), but the
5.6 source sets `selectedId` via `CanvasPressed` and never clears it,
so it must render a **selected** rect (gold stroke, square cyan
handles). The selected appearance appeared only after rebuilding the
debug exe in Phase 5.7 — at which point it was obvious the 5.6
screenshot had been captured from pre-5.6 code.

`run_smoke.ps1` now compares the exe's mtime against the newest
`app_moui/*.mbt` and refuses to run with a clear diagnostic (exit 5)
when `-SkipBuild` was passed on a stale artifact. Verified in both
directions: fresh exe passes, deliberately-backdated exe is refused.

**Apply when:** before trusting *any* smoke screenshot in this repo.
If `-SkipBuild` was used, confirm the debug exe is newer than the
newest `.mbt`, or just drop `-SkipBuild` and let the script rebuild.
This is the same class of trap as the `moon build` exit-0 bug in
`pof_service`: a build gate that silently doesn't gate.

#### Test count

249 total (was 241): +4 in `phase5_7_blit_test.mbt`, +3 rect
corner-order + 1 radius-constant pin in `hittest_test.mbt`, +2
zoom-drag guard (one with a control) in `canvas_view_test.mbt`.

**Still open:** `paint_canvas_decoration` is unused since Phase 5.2
and produces a warning. `DragGestureEvent` still has no button ID —
Phase 5.7's guard is a local mitigation, not a real fix.

### Phase 5.8 — drawing tools: the Add* handlers finally create annotations

Phase 5.8 closes the biggest remaining functional hole: **the MoUI
app could not create a single annotation.** `AddRect` / `AddPolygon`
/ `AddKeypoint` / `AddBinding` all existed as Msg variants, but every
handler was a no-op placeholder that reset `mode` and bumped the
dirty flag without appending anything — the same class of stub that
`ModifyHandle` was until Phase 5.4. Worse, nothing dispatched them:
the canvas's `on_drag` routed every phase to the Select-tool
handlers regardless of `model.mode`. So the app could edit the three
synthetic demo annotations and nothing else.

**What landed:**

1. **Deterministic id allocation** (`app.mbt`):
   `annotation_id_prefix = "ann-"`, `binding_id_prefix = "bind-"`,
   plus `first_free_suffix`, `next_annotation_id`,
   `next_binding_id`. Deliberately **not** the production frontend's
   scheme (`frontend/src/main.js:1066` uses
   `newId(p) = p + "_" + random_base36_7`, e.g. `obj_ab12cd3`):
   random ids are untestable and unbounded in length, which is the
   wrong trade for a native canvas that renders the id as on-canvas
   label text (see the note at `canvas_view.mbt:1145` — "ann-1",
   "ann-23" easily fit; long ids get clipped).

2. **`default_class_id(model)`** — first class flagged
   `is_default`, else `""` (which makes `class_lookup_name` fall
   back to rendering the annotation's own id, the same fallback the
   synthetic Phase 5.3 demo annotations use).

3. **`normalize_rect_corners` + `rect_is_degenerate`** — corners are
   stored canonically as `(TL, BR)` regardless of drag direction, and
   a zero-area "rect" (a click with no drag) is dropped rather than
   left as an invisible 1 px sliver in the label.

4. **The four `Add*` handlers are real.** Each allocates an id,
   assigns the default class, appends, and selects the new entity.
   `AddKeypoint` is the one that does **not** reset `mode` — staying
   in Keypoint mode lets the user tag several points without
   re-picking the tool (matching the legacy frontend's keypoint
   tool). A degenerate rect leaves `mode` alone too, so a stray click
   doesn't kick the user out of the Rect tool.

5. **`AddBinding(from_id, pt)` resolves its target by hit-test**,
   matching the frontend's two-step binding flow (click source →
   click target) — the Msg carries the *point*, not the target id. It
   refuses self-loops (target == source) and cancels cleanly (rather
   than staying half-armed) when nothing is under the cursor.

6. **Two new Msgs: `UpdateDraft(Point)` and `CommitDraft`.**
   `CommitDraft` owns the per-tool minimum-vertex rules (Rect ≥ 2,
   Polygon ≥ 3) in `update` rather than in the view closure, so
   they're testable and can't drift between tools.

7. **`DoubleTapped`** — a new Msg, no position payload. Moui 0.1.12's
   `on_double_tap` takes a *bare* `Msg` (unlike `on_drag`, which gets
   a `DragGestureEvent`), so it carries no coordinates; none are
   needed because the polygon's vertices already live in
   `model.draftPoints`. Double-tap is overloaded per mode: in Polygon
   mode it commits the polygon (the standard "click vertices,
   double-click to close" interaction — release can't serve, because
   every press is already a vertex); elsewhere it keeps the Phase
   5.19 wheel-zoom toggle.

8. **Mode-aware canvas dispatch** (`canvas_view.mbt`) —
   `Started` / `Changed` / `Ended` now branch on `model.mode`:
   - `Select` / `EditBinding` → the Phase 5.6 selection + handle-drag
     path.
   - `Rect` → press `BeginDraft`, drag `UpdateDraft`, release
     `CommitDraft`.
   - `Polygon` → each press appends a vertex (first press
     `BeginDraft`, later ones `PushDraft`); double-tap commits.
   - `Keypoint` → each press drops a point immediately.
   - `EditBinding` → `AddBinding` when a source is armed, otherwise
     the press picks the source.

9. **Draft handlers now dirty the *dynamic* layer**, not the static
   one. The draft preview is drawn by `draw_dynamic_layer`
   (`draw_draft_rect` / `draw_draft_polygon`), so pre-5.8's
   `staticLayerDirty` forced a full background+image blit on every
   rubber-band frame for a change that touches neither.

10. **`Shape` now derives `Eq`** (was `Debug` only, while `Mode`
    already derived `(Debug, Eq)`) so tests can assert on shape.

**The bug the tests caught (worth keeping in mind).** The first
`UpdateDraft` implementation "replaced the draft's last point". That
silently disables the entire Rect tool: after `BeginDraft` the draft
holds 1 point, `UpdateDraft` replaces it, so it stays at 1 forever,
`CommitDraft`'s `>= 2` check never passes, and **no rect can ever be
created** — with no error anywhere. The contract is now explicitly
"grow the draft to 2 points, then move the second", and the test
`UpdateDraft — grows to 2 points then moves the second (5.8)` pins
it. A rubber-band helper whose failure mode is "the tool quietly does
nothing" needs a test that asserts the *point count*, not just the
last point's position.

**11 new tests** (260 total, was 249): `AddRect` creates / rejects
degenerate / normalises corners / ids collision-free + deterministic;
`AddPolygon` requires 3 vertices; `AddKeypoint` creates and stays in
mode and increments the id; `AddBinding` resolves target, rejects
self-loop, consumes `bindingFromId`; `AddRect` inherits the default
class (and falls back to `""`); `UpdateDraft` grow-then-move contract
(including no runaway growth over many frames); `CommitDraft` 2-point
commit vs 1-point drop; `DoubleTapped` per-mode overload in both
directions (polygon commits and does *not* toggle zoom; Select still
toggles).

**Verification:** 260/260 tests pass; `moon check --target native`
0 errors. `_build/phase5_8_smoke._window._window.png` shows the demo
model after drawing a **fourth** annotation — `ann-1` at
image-natural `(8, 96) → (46, 190)`, in the lower-left, clear of the
three synthetic demo annotations, rendered with the selected (gold)
stroke, its 8 square handles, and its `ann-1` label. The three demo
annotations are still visible in their original positions. The smoke
harness (`build_demo_drag_model`) now dispatches the real
BeginDraft → UpdateDraft → AddRect sequence, so the screenshot is
evidence for creation, not just editing.

**Known issues deferred:**
- Polygon drafting shows committed vertices only — there's no
  rubber-band segment from the last vertex to the live cursor.
  `draw_draft_polygon` would need `model.cursorImgPt` threaded in.
- `CancelDraft` / `PopDraft` (undo-vertex) have no key binding yet.

### Phase 5.9 — toolbar tool buttons dispatch `SetMode` (the UI can finally pick a tool)

Phase 5.8 made the drawing tools *work*; this makes them *reachable*.
The blocker it removes: the toolbar's nav row was five `@views.button`
widgets with **no `on_click` at all**, so `SetMode` could only be
dispatched programmatically. A cold-started UI was therefore pinned to
`Select` forever, and the whole Phase 5.4–5.8 gesture pipeline
(handle drag, draft, commit) was unreachable by a user.

**1. `mode_button` / `mode_button_variant` in `labeler_ui.mbt`.** The
nav row's five hard-coded button blocks collapse into five
`mode_button(model, mode, theme, width)` calls. The helper wires
`on_click=SetMode(mode)` and picks the variant via
`mode_button_variant(model.mode, mode)` — `ButtonVariant::Primary`
for the armed tool, `Ghost` for the other four — so exactly one
button in the row reads as active. `mode_button_variant` is a pure
`pub fn` taking two `Mode`s precisely so that "only the current mode
is highlighted" is unit-testable without a paint pass. The
`@views.frame` wrapper (Phase 18.E) is retained: the dark theme's
16-px body font + 2×8-px padding otherwise forces a 32-px intrinsic
button height and inflates the toolbar.

**2. `[File]` → `[Select]`.** The `[File]` slot was a permanently
dead button (`File` is not a `Mode` variant) and its absence hid a
real hole: `Select` is the mode every select-and-drag-handle path
(Phase 5.4–5.6) is gated on, so a user who picked a drawing tool had
no way back. The slot is reused rather than appended, so the row
keeps its original width budget (`[Select]` 72, `[Rect]` 64,
`[Polygon]` 80, `[Keypoint]` 88, `[Binding]` 80 → 484 px, inside the
528-px header row).

**3. `mode_label(mode)` in `app.mbt`.** Single source of truth for
the button caption *and* the status line, so they can't drift.
`EditBinding` renders as `"Binding"` to match the primitive's name
everywhere else. The button label is `"[" + mode_label(mode) + "]"`.

**4. `SetMode` set no dirty flag — fixed.** `SetMode` clears
`draftPoints` and disarms `bindingFromId`, but the pre-5.9 handler
set *neither* `staticLayerDirty` nor `dynamicLayerDirty`. The draft
rubber-band is painted by the **dynamic** layer (`draw_draft_rect` /
`draw_draft_polygon`), so switching tools mid-draft left the previous
tool's rubber-band on screen until some unrelated Msg happened to
repaint. It now sets `dynamicLayerDirty: true` only — the image, pan,
zoom and annotation set are all unchanged, so a tool switch must not
cost a full background+image re-blit. It also sets
`statusMessage: "Mode: " + mode_label(mode)`, matching every other
mutating handler in the file.

**5. `FinishDraft` / `CancelDraft` were missed by the Phase 5.8
sweep.** Those two still set `staticLayerDirty: true` when discarding
a draft — a change that touches neither the image nor the annotations.
`PopDraft` had already been converted; these two were overlooked. All
three draft-teardown paths (`SetMode` / `FinishDraft` / `CancelDraft`)
now dirty the dynamic layer only, and one test pins all three.

**6. Dead `paint_canvas_decoration` removed.** Superseded by Phase
5.2's `canvas_view(model)` and referenced nowhere (not even tests) —
it was the source of the `unused` warning carried since Phase 5.2.
Removed together with its 66-line doc block.

**14 new tests** (274 total, was 260). The click itself is **not**
directly testable — MoUI declares `View[Msg]` with private fields and
no accessor, so a real event simulation isn't available (the same
limitation the Phase 5.5 `on_drag` tests document). The tests
therefore pin the two pure decisions the buttons make plus the whole
state machine the click feeds:

- `labeler_ui_test.mbt` (2): `mode_button_variant` is `Primary` for
  the armed mode and `Ghost` for all others, exhaustively over all
  25 pairs; `mode_label` captions are non-empty and pairwise unique
  (two identical captions would make the tool ambiguous).
- `canvas_view_test.mbt` (12): `SetMode` reaches all five modes;
  abandons an in-progress draft; disarms a pending `bindingFromId`;
  names the armed tool in `statusMessage`; dirties the dynamic layer
  only; `FinishDraft` / `CancelDraft` also dirty dynamic-only. Then
  four end-to-end chains — `[Rect]` → drag → a rect with the right
  two corner points; `[Polygon]` → 3 vertices + double-tap → a
  3-point polygon that does *not* trip the zoom-drag toggle;
  `[Keypoint]` → press → a point, staying armed; `[Select]` → press
  on a handle → drag armed. Plus the documented mode-reset policy
  (`AddRect` returns to `Select`, `AddKeypoint` stays) and the
  degenerate-rect case leaving the tool armed.

**Verification:** 274/274 tests pass; `moon check --target native`
0 errors (185 pre-existing `derive` warnings, unchanged);
`moon fmt --check` flags none of the 6 touched files (the repo-wide
fmt drift is pre-existing in `component_blackbox_test.mbt` and
unrelated files, so `moon fmt` was deliberately *not* run — it would
rewrite those). Smoke `_build/phase5_9_smoke._window._window.png`
shows `[Select]` with a filled `Primary` background and a dark label
against the four `Ghost` buttons with light labels — the active-tool
state is visibly distinct. A fifth runtime annotation `ann-2` appears
in the canvas alongside `ann-1`, created through the real
`SetMode → BeginDraft → UpdateDraft → AddRect` path, so the demo
exercises the toolbar's own Msg.

Note the screenshot shows **[Select]** armed rather than `[Rect]`:
the final `AddRect` resets the mode, which is the honest post-draw
steady state.

**Known issues deferred:**
- **Rect costs one toolbar click per rectangle.** `AddRect` resets
  the mode to `Select` (documented on the handler, and pinned by a
  5.9 test), so drawing N rects costs N clicks where N keypoints cost
  one. That asymmetry is now user-visible. The legacy frontend drops
  out of the rect tool but keeps the user in the keypoint tool, so
  this matches production — but it deserves a deliberate decision.
- A real fix for the above would give the `Add*` handlers one shared
  mode-after-commit rule instead of three hand-written `mode: Select`
  lines; the 5.9 mode-reset test exists to make changing it deliberate.
- Polygon drafting still has no rubber-band segment.

### Phase 5.10 — keyboard shortcuts: `Escape` / `Backspace` / `Delete`

> **Numbering collision.** The MoUI track already re-used 5.2–5.9
> from the older roadmap, and 5.10 collides again: `Msg::ImageDecoded`
> carries a comment reading "Phase 5.10 — full image decode result",
> and the old roadmap also had 5.15 = Delete shortcut and 5.19 =
> zoom-drag. This section keeps the "Phase 5.10" label for
> chronological continuity with 5.9; where the two disagree, the
> per-file comments are the tie-breaker.

**What landed.** Three toolbar shortcuts, each a
`@views.shortcut_button`:

| Label | Key | Msg |
| --- | --- | --- |
| `Cancel` | `Escape` | `CancelDraft` |
| `Undo pt` | `Backspace` | `PopDraft` |
| `Delete` | `Delete` | `DeleteSelectedAnnotation` |

`CancelDraft` / `PopDraft` had working `update` arms since the draft
landed with no way to reach them. `DeleteSelectedAnnotation` was added
in an earlier phase explicitly "for the Delete / Backspace keyboard
shortcut" and had never been bound — nor tested. All three are now
bound, and all three are now tested.

`labeler_ui.mbt` gains `pub(all) struct ShortcutSpec`,
`pub fn shortcut_specs()`, and `fn shortcut_row(theme)`, hung on a
**third toolbar row** below the nav row. The specs are plain *data*
rather than view code precisely so a test can drive them.

**MoUI keyboard API — the four traps** (all verified against
`.mooncakes/wzzc-dev/moui@0.1.12` sources, all silent on failure):

1. **Key names are capitalised and the match is strict equality.**
   `KeyboardShortcut::matches` is
   `event.pressed && event.key == key && event.modifiers == mods`.
   MoUI's Windows backend (`backend/common/input/window_event_decode.mbt`,
   `named_key_name`) emits `"Escape"`, `"Backspace"`, `"Delete"`,
   `"Enter"`, `"Tab"`, `"ArrowLeft"`, … Writing `"escape"` disables
   the shortcut with **no error anywhere**. This is why the specs are
   data and why the test drives MoUI's own matcher over them — it is
   the only way to catch that class of typo without a human pressing
   keys. Character keys are worse: their host name is the literal
   character, so they are shift-sensitive and ambiguous. Hence
   `Backspace` for undo-vertex rather than `Ctrl+Z`.

2. **A bare `View::keyboard_shortcut` dispatches no `Msg`.**
   `handle_keyboard_shortcut_modifier` returns
   `{ activated: true, captured: true }` and *nothing else*. The `Msg`
   only arrives because `runtime/input_keyboard.mbt::dispatch_keyboard_shortcut`
   then calls `activate_first_child` on the matched node, and the first
   child is a real pressable button whose `on_click` fires. So the
   modifier must live on a node whose first child is a button —
   which is what `shortcut_button` (a `row[button, key-chip]`) is for.
   Attaching the modifier *to the button itself* would not work: a
   button has no children to activate.

3. **The first match wins and stops the walk.**
   `dispatch_keyboard_shortcut_to_children` iterates children in order
   and breaks at the first activated one, so two specs sharing a key
   make the second permanently unreachable. A test asserts the three
   keys are pairwise distinct.

4. **Shortcuts are global, not focus-scoped.** `dispatch_keyboard_shortcut`
   is a separate whole-tree walk; `dispatch_keyboard` is the
   focus-based one. Nothing needs to be clicked first.

Also noted: MoUI's `button` has **no `disabled` parameter**, and
whether `View::disabled()` participates in the keyboard-shortcut path
could not be verified locally. So the three buttons are always
enabled, and safety comes from the handlers instead (below).

**Handler safety — the reason the tests exist.** An always-enabled
destructive key is only safe if its handler is a no-op when there is
nothing to do. Five invariants are now pinned in
`canvas_view_test.mbt`:

- `PopDraft` stops at one vertex and never removes the draft's
  anchor point (3 → 2 → 1 → 1, holding).
- `PopDraft` on an empty draft is a *complete* no-op: not even
  `dynamicLayerDirty` is set, so a stray Backspace never schedules a
  repaint of an unchanged canvas.
- `CancelDraft` clears the draft, disarms the mode, and leaves the
  committed scene (annotations / bindings / selection) untouched.
- `DeleteSelectedAnnotation` with no selection changes nothing —
  including `label.dirty`, so a stray Delete cannot make the next
  save write a label the user never edited.
- `DeleteSelectedAnnotation` drops bindings referencing the id but
  keeps the *far-end* annotation. The default scene (rect-1 →
  kp-1) is exactly the ambiguous case: `kp-1` is on both sides of the
  arrow and only the arrow may go.

**Collateral fix — `CancelDraft` now disarms a pending binding.**
`SetMode` already cleared both `draftPoints` and `bindingFromId`, but
`CancelDraft` reset only the mode, leaving a half-armed binding.
Harmless while `CancelDraft` was unreachable; a real leak the moment
`Escape` became pressable. `FinishDraft` has the same latent shape but
is not bound to any key and is not dispatched from the view tree, so
it was left alone rather than changed untested.

**Layout: the third row costs ~56 px, and why it is a separate row.**
`shortcut_button` cannot be made narrow enough to share the nav row —
measured off the smoke capture, the label button is floored at
`max(72, width - shortcut_width - spacing)` and the key chip at
`shortcut_width`, so three of them render at a **304-px pitch (912 px
of a 960-px window)** while the nav row already spans the window.
Three therefore need a row of their own.

That row is not free. Measured with a pixel scan of
`_build/phase5_10_final._window._window.png` (canvas top edge at
x=700):

| Configuration | canvas top (px) | toolbar cost |
| --- | --- | --- |
| 5.9 baseline (no shortcut row) | 178 | — |
| `@views.frame` height=16 | 218 | +40 |
| `@views.frame` height=24 (**shipped**) | 234 | +56 |
| unclamped `shortcut_button` | 258 | +80 |

**`height=16` is a trap and must not be "optimised" into place.**
`@views.frame` clamps the child's *layout* box and does **not** clip
its *paint*, so a 16-px frame around a ~40-px-tall button lets the
button paint down into the canvas;
`_build/phase5_10_smoke_v4._window._window.png` shows all three key
chips sliced in half by the red image. Keep the frame's height equal
to the button's real painted height, or the row overlaps the canvas.

**Honest cost statement.** At the default window the sidebar's class
chips clip one row earlier than in 5.9 (`# Knife` / `# Gun` were
visible in `phase5_9_smoke._window._window.png` and are not in
`phase5_10_final...`). This is a real, if small, regression — but the
sidebar **already overflowed** before this phase: 5.9 showed only 2
of 6 class chips, and the status bar was off-screen entirely (the
Phase 20 deferred DPI/rasterizer issue). The root cause is that the
content does not fit the window, not that this feature is too big.
The status bar was tried as the home for the shortcuts and reverted:
it is layout-free (canvas top returned to exactly 178) but sits below
the fold, so the buttons would be invisible — the same failure mode as
the Phase 18.C/D invisible-button hunt. Fixing the overflow (taller
default window, or a denser sidebar) is the follow-up.

**Verification boundary — no keystrokes were synthesised.** It is not
possible to inject a key event into the window from the smoke harness,
so the physical-key → `Msg` path is **not** end-to-end verified. What
is verified: (a) every spec's key string matches a real
`KeyboardEvent` through MoUI's own matcher, and near-misses
(lower-case, key-up) do not; (b) each key's `Msg` drives the action it
advertises; (c) each handler is no-op-safe. The unverified link is
MoUI's dispatch actually routing a synthesised key to these three
buttons.

**Verification:** 283/283 tests pass (274 → 283, +9);
`moon check --target native` 0 errors (185 pre-existing warnings,
unchanged); `moon fmt --check` flags none of the 4 touched files (the
repo-wide fmt drift is pre-existing in `component_blackbox_test.mbt`
and unrelated files, so `moon fmt` was deliberately *not* run). Smoke
`_build/phase5_10_final._window._window.png` shows the third row with
`Cancel`/`Esc`, `Undo pt`/`Backspace` and `Delete`/`Delete` all fully
painted, with no overlap against the canvas.

### Phase 5.11 — polygon rubber band + two rasterizer stroke bugs

**What landed.** The polygon tool showed only its *committed* vertices,
with no indication of where the next click would land. It now draws a
rubber-band segment from the last committed vertex to the live cursor.

- `canvas_view.mbt` — new pure `pub fn polygon_rubber_band(points,
  cursor, pan, zoom, dst_origin) -> (Point, Point)?`. Returns the
  screen-space `(from, to)` of the band, or `None` when there is
  nothing to band: no committed vertex (no anchor) or no cursor (no
  end). Both cases matter — a band with no anchor is a stray line
  across the canvas, one with no end is invisible.
- `draw_draft_polygon` gains a `cursor : Point?` parameter; the call
  site passes `model.cursorImgPt`. The band is drawn *after* the
  fill and stroke passes so it never contaminates the committed
  shape's fill area or its solid outline, and it is deliberately
  weaker — same hue, alpha 0.55, 1 px vs the committed edge's
  alpha 1.0 at 2 px. A fully opaque band would read as an
  already-placed edge, which is the exact confusion it exists to
  prevent.
- The geometry is a pure function so it is unit-testable without a
  paint pass, the same factoring `mode_button_variant` (5.9) used.
  Four tests pin: both `None` cases, that the band anchors on the
  **last** vertex (vertex 0 would draw a chord across the shape
  instead of extending it), that it rides the identical
  `(pan, zoom, dst_origin)` transform as the committed polyline —
  asserted against `img_to_screen` rather than hand-computed numbers,
  so the test states the invariant and not a copy of the formula —
  and that it appears after a **single** vertex, which is the one
  step where the feedback is most needed.

**Two rasterizer bugs, found because the band is a diagonal.** A
rubber band is a 2-vertex, diagonal, 1-px stroke, and it rendered as
a solid orange quad with a black rectangle beside it. Both defects
were pre-existing and affected every diagonal stroke in the app.

1. **`paint_path` hardcoded black for 2-vertex paths.** The
   `verts.length() < 3` branch called `paint_polygon_stroke` with
   `rgba(0,0,0,1)` and ignored `spec.stroke` entirely. So a
   2-vertex path came out black regardless of the colour requested —
   which is exactly the shape of the new rubber band *and* of a
   1-edge draft polyline. Now resolves the real brush via
   `brush_color`, matching the fill pass.

2. **`paint_polygon_stroke` painted each thick edge as its
   axis-aligned bounding box.** That is exact for axis-aligned edges,
   which is most of the labeler's annotation geometry, and a filled
   box for anything diagonal: a 1-px stroke from (2,2) to (9,9)
   filled the whole 7x7 square. Replaced with a DDA walk
   (2 samples per pixel of length) stamping a `width x width` square
   per step, which is correct at every angle.

   The stamps go through `paint_rect_snap` at integer coordinates,
   not the anti-aliased `paint_rect`. A 1-px square centred on a
   fractional point is only partly covered by any one pixel, which
   the AA path correctly renders as a dimmed line — alpha 0xEA/0xFD
   instead of 0xFF. Snapping is also the convention the rest of the
   file already uses for stroke geometry (see `paint_rect_snap`'s own
   doc comment), so a hairline stays a hairline. This was found by a
   test asserting an exact alpha, not by inspection.

Two rasterizer tests pin both. The diagonal test's discriminator is
the pixel *inside the segment's bounding box but far off the
diagonal* — a bounding box paints those, a line leaves them clear.

**Side effect worth knowing about:** fixing #2 also cleaned up
geometry this phase did not touch. `poly-1`'s triangle edges and the
`rect-1 → kp-1` binding arrow now render as crisp lines; before, the
binding arrow was a black staircase of filled boxes. The
`_build/phase5_11_final._window._window.png` vs
`_build/phase5_10_final._window._window.png` comparison shows both.

**Verification:** 289/289 tests pass (287 → 289, +2; 283 → 289
including the four rubber-band geometry tests); `moon check
--target native` 0 errors (185 pre-existing warnings, unchanged);
`moon fmt --check` flags none of the 5 touched files. Smoke
`_build/phase5_11_final._window._window.png` shows the two committed
vertices as yellow dots with white rings, a solid yellow committed
edge between them, a visibly weaker yellow band running from the
second vertex to the white cursor crosshair, and `[Polygon]` drawn
with the filled `Primary` background. `_build/phase5_11_band_zoom.png`
is a 4x nearest-neighbour crop of that region, taken because the
alpha difference between the committed edge and the band is the whole
visual contract and is not legible at 1x.

`build_demo_drag_model` now ends mid-polygon (two `PushDraft` points
plus a `CursorMoved`), which is the only state in which a band
exists. Side effect: the screenshot's armed tool is now `[Polygon]`
rather than `[Select]`. That still demonstrates Phase 5.9's cue — one
filled `Primary` against four `Ghost` — and a band is only reachable
with the polygon tool active, so it is the honest state to capture.

### Open: the window overflow (diagnosed, not fixed)

The sidebar still overruns the bottom of the window and the status
bar is still never painted. Phase 5.11 investigated this and did not
fix it. The findings, so the next attempt does not repeat them:

- **The status bar mystery from Phase 20 is a layout problem, not a
  rasterizer or DPI problem.** The text was never laid out there;
  the region was consumed by content above it. The three theories in
  the Phase 20 note (DPI scale, `windows_skia` bottom-edge text, the
  retained-layer bug seen in Phase 19) can all be dropped.
- **The text measurement looks like the culprit, and the arithmetic
  supports it.** `renderer.mbt` supplies
  `@core.TextSystem::fallback()` to the renderer, whose measurement
  is `height = font.size * 1.25` (`core/text_layout.mbt:568`) — 20
  logical px for the 16-px control font. But
  `rasterizer.mbt::paint_text` never uses that number: it draws a
  fixed 5x7 glyph cell and vertically centres it in `run.frame`.
  So layout reserves 20 px for text that occupies 7, and
  `@views.button` inherits it
  (`max(min_size.height, text_height + 2 * spacing_scale.sm)`).
- **Three levers were tried and all three were inert.** Pixel-scanning
  the smoke capture, the sidebar's row positions were byte-identical
  across all of them (258 / 318 / 354 / 390 / 426 / 490):
  1. `Theme::with_spacing_scale` (sm 8→2, lg 16→6) on the dense
     chrome. Real but tiny: the row pitch moved 50→36 px while the
     text term alone predicts 36, so padding is not what sets it.
  2. `bitmap_text_system()` — a `TextSystem` measuring via the app's
     own `measure_text` (5x7 cells) — wired into the renderer's
     `text_system=`. Canvas top moved 234→252, i.e. *worse*.
  3. The same system installed on the runtime via the public
     `AppRuntime::set_text_system` (which does mark layout + paint
     dirty, and `RuntimeState::layout` re-measures). This reverted
     (2) but still left the sidebar unchanged.
  All three were reverted; the tree is at the 5.10 layout.
- **So the row height is set by something not yet identified.**
  `@views.frame(child, width=, height=)` wraps every sidebar row at
  16 px, yet the rows lay out at 36. `resolve_frame_size` clamps to
  the requested height, but the result is then passed through
  `constraints.constrain(...)`, which can expand to a `min` supplied
  by the parent. Finding what sets that `min` — most likely in
  `@layout.column`'s `child_constraints` — is the next step. Note
  that `@views.frame` clamps layout and does not clip paint (Phase
  5.10), so any fix here has to work through the layout min rather
  than through a smaller frame.
- **Measurement recipe** (reuse it): scan the per-window capture at
  x=700 for the first strongly-red pixel to get the canvas top, and
  count text-bright pixels in x∈[30,200] to get sidebar row
  positions. The window is requested at 1920x1080 but the
  `PrintWindow` capture is 960x540, so capture px are half of
  logical px.

### Phase 5.12 — chrome theme: the declared font size is layout ballast

**What landed.** `labeler_ui.mbt` gains `chrome_typography_scale()`,
`chrome_spacing_scale()` and `compact_theme(base)`, applied to the
**controls only** (nav-row buttons, sidebar folder rows, sidebar class
chips, shortcut row). Text widgets keep `dark_theme` and their
explicit heights.

**Why shrinking the declared type is free.** MoUI's `button` measures
itself as `max(min_size.height, text_height + 2 *
spacing_scale.sm)` (`views/button/button.mbt:156`), and the text
height comes from the theme's font via
`@core.TextSystem::fallback()`, which reports `font.size * 1.25`
(`core/text_layout.mbt:568`) — 20 logical px for the theme's 16-px
control font. But `rasterizer.mbt::paint_text` **ignores `font.size`
entirely**: it draws a fixed 5x7 glyph cell and vertically centres it
in `run.frame`. The declared size is therefore pure layout ballast —
a 16-px control font produced 36-px buttons (20 + 2x8) inside
`@views.frame(width=180, height=16)` rows that asked for 16, and the
frames were powerless to stop it.

`control` drops to 10 px, so the declared text height becomes 12.5 and
`sm` to 1, so the button lands on `max(16, 12.5 + 2) = 16` — the
frame's own floor. **The glyphs are redrawn byte-identically**,
because `paint_text` never looked at the size.

**Verified, not assumed.** MoUI exposes the live layout through
`AppRuntime::inspector_snapshot()` (a record that derives `Debug` and
`ToJson`). Dumped from inside `render_frame` — the only hook that
fires after the surface reports its real size — the sidebar's folder
rows go from `y = 126, 144, 162, 180` (pitch 18) where they were
pitch 36, and the class chips from pitch 36 to 17. The whole chrome
now measures 88 (toolbar) + ~253 (sidebar) + 24 (status) = ~365 of the
504 logical px available. That is the first time the layout has
provably fit the window.

**Recipe, worth keeping.** `moon run` the exe with `--smoke` and
redirect stdout; parse `layout.bounds` (per-node `element_id`, `frame`,
`constraints`) and join it against `view_tree.nodes` (`element_id` ->
`kind`). The values are MoonBit's `Json` debug form — `Object({...})`,
`Number(...)`, `String(...)` — not strict JSON, so `ConvertFrom-Json`
will not read it. Two gotchas: the layout reported in `main` is measured
against the *requested* size, not the real surface, so the dump has to
come from inside the frame loop; and this host runs at
`scale_factor = 2`, so the window is **947x504 logical**, not the
1920x1080 `main_native.mbt` asks for (the runtime re-lays-out to the
real surface). Pixel-scanning the smoke capture cannot answer any of
this — the capture's px-to-logical mapping is not 1:1 and guessing it
is what cost Phase 5.11 and most of this phase.

**Open: the status bar is parked at y = 1,000,000,088.** Still not
fixed, but now measured rather than guessed, and the cause is known:

- MoUI 0.1.12's `ViewNode::child_constraints` defaults to
  `constraints.loosen()`, and neither `@layout.stack` nor
  `@views.canvas` overrides it. The unbounded max is `1.0e9`
  (`core/geometry.mbt:86`), and `canvas_view`'s layers return
  `ctx.constraints.max`. The live snapshot records the whole chain:
  root column `947x504` (constraints min = max, correct), main row
  `947 x 1e9`, canvas `x=180, w=1e9, h=1e9`, status text
  **`y = 1000000088`**.
- So the status bar is not clipped, it is a billion pixels below the
  window. That is the real cause of every symptom chased since Phase
  18 — including **Phase 20's status-bar mystery, which was recorded
  as a DPI and `windows_skia` bottom-edge raster bug and is neither**
  — and of the sidebar's apparent overflow, which was always inside
  the window.

Two fixes were tried and **both reverted**:

- **`.expanded()` on the main row** (weighted child, so its base is 0
  and the 1e9 canvas cannot poison `child_main_total`). The column
  then resolves [88, 0, 24], hands the main row `504 - 112 = 392`,
  and puts the status bar at `y = 480 = 504 - 24` — **confirmed
  correct in the inspector**. But the canvas's own width stays 1e9, the
  fit-contain math centres the image in that frame, and the canvas
  renders blank.
- **`@views.frame(canvas, max_width=, max_height=)`** to bound that
  width. It does bound it (node 85: 1e9 -> 1100), but the canvas
  *still* renders blank — no image, no annotations, only the neutral
  background. The static layer is painting somewhere the rasterizer no
  longer samples. Not understood, so not shipped.

The open question is the second one: **why does bounding the canvas
stop the static layer from painting at all?** Start from
`CachedStaticLayerView::paint` (`canvas_view.mbt:293`) and the
`ViewPaintLayer` cache, since bounding the frame changes the layer's
cache key and the first frame after a key change is exactly when a
cache-fill pattern drops commands.

**Verification:** 291/291 tests pass (289 -> 291, +2 on the theme
scales); `moon check --target native` 0 errors (185 pre-existing
warnings, unchanged); `moon fmt --check` flags neither touched file.
Smoke `_build/phase5_12_final._window._window.png` is pixel-equivalent
to the 5.11 capture — image, annotations, rubber band, `poly-1`'s
triangle and the binding arrow all still paint — so the typography
change is layout-only, which is the claim.

### Phase 5.13 — the canvas is bounded, and the status bar is on screen

Closes the item Phase 5.12 diagnosed: the status bar was parked at
`y = 1_000_000_088`, and both attempts to fix it there had been
reverted.

**Root cause, complete.** `canvas_view` is greedy by design — its
layers return `ctx.constraints.max`. MoUI 0.1.12's
`ViewNode::child_constraints` defaults to `constraints.loosen()`, and
neither `@layout.stack` nor `@views.canvas` overrides it, so a
pass-through layout hands its children the **unbounded** max
(`Constraints::unbounded()` = 1.0e9, `core/geometry.mbt:86`). The
canvas measured 1e9 x 1e9, which poisoned the outer column and
threw the status bar a billion pixels down.

**Why it looked like it worked.** `rasterizer.mbt::paint_image` maps
the destination with `src = d * src_size / dst_size`, where `dst`
comes from `run.frame ∩ clip` — it **stretches the image to fill the
clipped region** rather than fitting it into `run.frame`. With a 1e9
frame the intersection is the whole viewport, so the image filled the
canvas: correct by accident. And because a 200x200 square image in a
1e9 square frame has the same aspect ratio, `fit_contain_rect`
returned the frame unchanged, so `dst_origin` stayed at the frame
origin and the annotations landed correctly too. One number, 1e9,
was doing two unrelated jobs.

**The fix, and the trap on the way.** Bounding the canvas with
`@views.frame(max_width=, max_height=)` removes the accident, and
then the bound has to be the real viewport. The first attempt used
`build_labeler_ui_view`'s hardcoded `1280.0, 800.0` parameters, which
had been wrong since Phase 18.B (`main_native.mbt` opened 1920x1080,
and nothing ever checked the two against each other). That produced a
1100x688 canvas whose fitted image landed at `y = 368` — almost
entirely outside the 947x504 buffer — so **the canvas rendered blank**
and looked like a cache bug. It was never a cache bug.

**`Model::viewport` is the fix.** The view has no other way to learn
the real size: MoUI 0.1.12 exposes no resize callback, and
`child_constraints` hands children 1e9 rather than the parent's
resolved size, so "how much room is there" has to be told. The
viewport is now a Model field, set by `main_native.mbt` from the same
constants the runtime is given.

**The two numbers are deliberately different, and getting that wrong
is observable.** `AppRuntime::size()` returns the request **divided by
the DPI scale factor** (2 on this host). So:

| | value | role |
| --- | --- | --- |
| request | 1920x1080 | what Win32 wants; Phase 18.B was right |
| `AppRuntime::size()` | 947x504 | the logical layout |
| `Model::viewport` | 947x504 | what the view sizes against |

Asking for 947x504 produces a **460x216** logical layout — a
half-size window. Verified: that build's live layout reported
460x216, and the fixed one reports 947x504.

**Verified layout, live, via the inspector** (was / is):

| node | was | is |
| --- | --- | --- |
| root column | 947 x 504 | 947 x 504 |
| toolbar | 88 | 88 |
| main row | 947 x 1e9 | 947 x **392** |
| canvas | x=180, 1e9 x 1e9 | x=180, **767 x 392** |
| status text | **y = 1000000088** | **y = 480** (504 - 24) |

The visible consequence is in
`_build/phase5_13_final._window.png`: the sidebar's class chips
(`# Knife`, `# Gun`, `# Pistol`, `# Rifle`, …) are now all on screen.
They were clipped in every capture from 5.1 through 5.12.

**Phase 5.15 correction — the geometry was never wrong.** This
section said the image was clipped at the window edge. It was not.
The paint-time measurement (see Phase 5.14's correction) gives
`paint.frame = 180,88 767x392` and `fit = 367,88 392x392` — centred,
inside the frame, nothing clipped. What changed the *rendered* result
was Phase 5.14's `paint_image` fix, because until then the rasterizer
ignored that frame and stretched the image to the clip. The layout
work in 5.13 was necessary (the status bar really was at y=1e9) but
it was never the cause of the apparent image problem.

**Smoke capture caveat, now settled.** The per-window
`PrintWindow` capture is **half** the requested window size, so it
shows only the top-left of a 947x504 window. Every "the status bar is
missing" reading from a per-window capture was partly this. The
full-desktop capture (`<out>.png`, no `._window` suffix) shows the
whole window and is the one to look at for layout questions.

**Verification:** 291/291 tests pass (unchanged — this phase is
layout-only and touches no `update` arm); `moon check --target native`
0 errors (185 pre-existing warnings, unchanged); `moon fmt --check`
flags none of the 3 touched files.

### Phase 5.14 — `paint_image` honours `run.frame` (correctness, not placement)

**What changed.** `rasterizer.mbt::paint_image` took its source
mapping from `run.frame ∩ clip`:

```
src = d * src_size / (run.frame ∩ clip).size
```

i.e. it **stretched the image to fill whatever the clip allowed**,
ignoring the frame the caller had asked the image to occupy. It now
maps relative to `run.frame`:

```
src = (absolute_dest - frame.origin) * src_size / frame.size
```

with the source index clamped to `[0, src_len - 1]`. The clip is
still used for two things — rejecting a fully off-screen run, and
bounding the destination loop — but it no longer decides *which* texel
a destination pixel reads.

**Why it matters beyond tidiness.** It was masking a real bug, in both
directions:

- A `DrawImage` with a small frame inside a large clip painted the
  whole clip, over its neighbours.
- With the canvas's frame deliberately oversized (Phase 5.13 was
  fixing exactly that, via a 1e9 x 1e9 canvas), the stretch
  coincidentally filled the viewport and *looked right*. That is why
  the fit-contain geometry was never load-bearing, and why the image
  placement bug went unnoticed for so long. With the frame honoured,
  `fit_contain_rect` in `canvas_view.mbt` is finally what the user
  actually sees — which also means a future layout regression can no
  longer hide behind the stretch.

**Two tests, both discriminators** (293/293, +2):

- `draw_image_paints_into_run_frame_not_the_whole_clip` — a 10x10
  frame in a 20x20 buffer. The 2x2 source (red/green/blue/white)
  fills the frame in quadrants, and the four buffer **corners stay
  clear**. Under the old stretch all four corners were painted, so
  the test fails against the old code rather than merely describing
  the new.
- `draw_image_with_frame_larger_than_clip_samples_only_the_visible_corner`
  — the opposite direction, and the one the canvas actually hit: a
  16x16 frame over an 8x8 buffer, so the buffer is the source's
  top-left corner. Every pixel is red; under the old stretch the
  bottom-right corner came out **white** (source texel 1,1).

**Correction (Phase 5.15) — the image is NOT mis-centred.** This
section originally reported the image as drawn right of centre with
the geometry implying x=367. That was **wrong**, and the mistake was
in the instrument rather than the code: a `PrintWindow` capture does
not share a single scale with logical pixels here, so pixel
arithmetic on it cannot answer a placement question at all. Measured
directly in `CachedStaticLayerView::paint` on the real window:

```
paint.frame = 180,88  767x392
fit_contain  = 367,88  392x392
```

which is exactly centred — 187 px of horizontal padding on each
side. The geometry was always right; Phase 5.14's `paint_image` fix is
what made the *rendered* output finally match it. The claim is
replaced by a test (`fit_contain_rect — the demo image is centred in
the real canvas`) so it cannot be re-derived by hand.

**Smoke capture caveat, now settled.** The full-desktop capture catches
whatever is in the foreground — during Phase 5.14's run it caught a
browser window rather than the app. The per-window capture is the
reliable one, but it is **not** a uniform scale of the window: a
960x540 capture of a 947x504 window is not 1:1, and the factor
differs between axes. So it is fine for "does the app render at all"
and useless for "where exactly is this pixel". Measure placement in
`paint` (or in the inspector snapshot), never on a capture.

**Verification:** 293/293 tests pass (+2); `moon check --target
native` 0 errors (185 pre-existing warnings, unchanged);
`moon fmt --check` flags neither touched file. Smoke
`_build/phase5_14_final._window._window.png` shows the image, the
rubber band, `rect-1` and the sidebar rows all still painting — this
phase changes *where* an image samples, not whether it paints.

### Phase 5.15 — a correction, and the test that replaces the screenshot

No behaviour change. The layout and the rasterizer are as Phase 5.14
left them; this phase removes a wrong claim and makes the right claim
checkable.

**What was wrong.** Phases 5.13 and 5.14 both recorded "the image is
drawn right of centre / clipped at the window edge" as a known issue.
It was not. Measured directly in `CachedStaticLayerView::paint` on
the real window:

```
paint.frame = 180,88  767x392
fit_contain  = 367.5,88  392x392
```

Centred, inside the frame, nothing clipped — 187.5 px of horizontal
padding on each side.

**Where the mistake came from.** I read it off a `PrintWindow`
screenshot. That capture does not share a single scale with logical
pixels on this host: a 960x540 capture of a 947x504 window is not 1:1,
and the factor differs between axes, so a red-pixel bounding box on
it cannot recover a position. Fitting both axes from that box gave
1.64 horizontally and 2.05 vertically — mutually inconsistent, which
is the tell. I should have treated "my two axes disagree" as "my
instrument is wrong" instead of "the code is wrong". Two phases
(5.12, 5.14) were spent on the same mistake before the instrument,
not the code, was questioned.

Also worth recording: the inspector dump prints integers, and
`to_int()` truncates the half-pixel centring **367.5 to 367**. Reading
a centring expectation off a dump therefore produces a test that fails
for a reason that has nothing to do with the bug.

**What replaces it.** `fit_contain_rect — the demo image is centred in
the real canvas (5.15)` pins the geometry with the real numbers —
947x504 window, 180-px sidebar, 88-px toolbar, 24-px status bar, so a
767x392 canvas at (180, 88) holding a 392x392 image at **367.5**, 88.
It also asserts the image stays inside the canvas, so a future
viewport change that broke the fit would fail here rather than being
noticed by eye. Writing it is what caught the 367-vs-367.5
discrepancy: the test's first draft asserted 367, and the real value
is 367.5, because (767 - 392) is odd.

**Rule this establishes.** A placement question is answered by
`paint`, by the inspector snapshot, or by a test — never by a
screenshot. A capture answers exactly one question: did anything
render at all.

**Verification:** 294/294 tests pass (+1); `moon check --target
native` 0 errors (185 pre-existing warnings, unchanged);
`moon fmt --check` flags neither touched file. No smoke re-run: this
phase changes no rendering path, and the geometry it pins was
measured from the live paint in this same phase.

### Phase 5.16 — one rule for "which tool is armed after a commit"

Closes the second half of the item Phase 5.9 left open ("a real fix
would give the `Add*` handlers one shared mode-after-commit rule
instead of three hand-written `mode: Select` lines").

**The rule, and where it lives.** `pub fn mode_after_commit(created :
Shape) -> Mode` in `app.mbt`, next to `mode_label` (5.9's other mode
helper). Keypoint stays armed; Rect and Polygon return to `Select`.
All three `Add*` handlers call it.

**It takes the shape, not the current mode.** The two coincide on
every path the app has today, so this is about the next input path:
if something ever dispatches `AddRect` while the mode says `Keypoint`,
the answer must still be `Select`. Reading the mode back off the
model would silently keep the keypoint tool armed after a rectangle.
It also sidesteps a real hazard in this file — **`Rect` and `Polygon`
are variant names in both `Mode` and `Shape`**, which is why a bare
`[Select, Rect, ...]` in a test cannot be resolved to either enum and
needed an explicitly typed `every_mode()` helper.

**Worse than AGENTS.md had it.** The note said "three hand-written
`mode: Select` lines". In fact there were **six** `mode: Select`
writes, and the three `Add*` handlers expressed the same contract
three different ways:

| handler | how it said "commit" |
| --- | --- |
| `AddRect` | hand-written `mode: Select` |
| `AddPolygon` | hand-written `mode: Select` |
| `AddKeypoint` | **omitted the `mode` field entirely** |

`AddKeypoint` inherited `model.mode`, so it produced the right answer
only because the canvas dispatched it while the keypoint tool
happened to be armed. That is a contract held by an accident of call
ordering rather than by code. It is now explicit.

**The behaviour is unchanged, and that is the decision.** Drawing N
rectangles still costs N toolbar clicks. The counter-argument is that
the legacy frontend this port tracks also drops out of the rect tool
after a commit, so keeping the tool armed would be a deliberate
*divergence* from the reference rather than a fix. The rule is now
single-sourced, explicit and tested, so revisiting it is a one-line
change in one function instead of three edits in three handlers.

**The asymmetry with cancel is deliberate and tested.** `FinishDraft`
and `CancelDraft` go to `Select` unconditionally, *including* from
Keypoint, and therefore do **not** call `mode_after_commit`. A commit
means "finished", which leaves the keypoint tool armed for the next
point; a cancel means "stop", which must leave nothing armed. Merging
the two rules would silently re-arm the tool on Escape, so
`cancel always disarms, even from keypoint (5.16)` asserts both
halves.

**Tests (298/298, +4).** The rule for all three shapes; the
shape-not-mode contract, dispatched from all five starting modes; the
**anti-drift** test asserting every `Add*` handler agrees with the
rule from every starting mode (it fails if anyone hand-writes
`mode: Select` back, or restores the omit-the-field trick); and the
cancel asymmetry above.

**Verification:** 298/298 tests pass (294 -> 298); `moon check
--target native` 0 errors (185 pre-existing warnings, unchanged);
`moon fmt --check` flags neither touched file. Smoke
`_build/phase5_16_final._window._window.png` is unchanged from 5.14
except for the toolbar's armed tool — correct, since this phase
refactors a rule without changing any behaviour.

### Phase 5.17 — the sidebar rows are live controls

**What was broken.** Since Phase 18.E the sidebar's 4 folder rows and
6 class chips have been `@views.button`s with **no `on_click` at
all** — rendered with a Ghost background, looking pressable, and
inert. The same dead-control failure 5.9 found on the toolbar's
`[File]`, except that here the fix only became *visible* two phases
after the diagnosis: 5.13 brought the rows into the window for the
first time (they had been clipped off the bottom since 5.1), which
turned "6 dead controls nobody could see" into "6 dead controls on
screen".

**What landed.**

- Folder rows dispatch `SelectIndex(i)` — already implemented, just
  never called.
- Class rows dispatch a new `SetActiveClass(String)`.
- `Model::activeClassId : String` is the state they set. It had to
  be new: `default_class_id` read only `ClassEntry::is_default`, so
  there was **no state for a class click to set** — which is why
  these rows could not be wired at all until now. `default_class_id`
  now prefers `activeClassId` when set, and falls back to the
  project flag as before.
- `pub fn sidebar_row_variant(is_current : Bool)` gives the active
  row a `Primary` background, same shape as 5.9's
  `mode_button_variant`. Without it the clicks would work and be
  invisible.
- `SetActiveClass` writes a status line, which for a Ghost row is
  the only feedback available.

**The row string is both the label and the class id** — not a
simplification but what the app's current state forces. `ScanClasses`
is still a no-op stub and nothing dispatches `ClassesLoaded`, so
`model.classes` is always empty and the demo fallback is the only
reachable branch; a demo class has no `ClassEntry` behind it, so its
name *is* its id, consistently end to end. When `ScanClasses` is
implemented this needs a second parallel array (a real `ClassEntry`
carries `id` and `name` separately, and the annotation wants the
**id**). A pair type was tried first and `Array[(String, String)]`
does not resolve in this package.

**Tests (302/302, +4).** The variant function; `SetActiveClass`
recording the class *and* the new annotation actually receiving it
(driven through the real handler, and checking that switching class
retargets only the next annotation); the highlight following model
state through both real handlers; and `SelectIndex` clearing
`selectedId`, which matters now that a folder click changes image —
a stale handle highlight on the previous image's annotation would be
a new bug introduced by making the row live.

**A build note worth keeping.** The first version of this change
failed `moon test` with `Package "moui" not found in the loaded
packages` pointing at an untouched line, while `moon check --target
native` passed. That message is a **cascade from a parse failure
elsewhere in the file**, not a real package-resolution problem — and
the bisect that found it (`moon check` vs `moon test`, then revert
one file) is the only reason it was identified rather than guessed
at. Two false leads came first: `Array[(String, String)]` as the
cause, and CRLF line endings (the file had genuinely drifted to CRLF
at one point, and fixing that did *not* fix the error).

**Verification:** 302/302 tests pass (298 -> 302); `moon check
--target native` 0 errors (185 pre-existing warnings, unchanged);
`moon fmt --check` flags none of the 3 touched files. Smoke
`_build/phase5_17_final._window._window.png` is unchanged from 5.16,
which is the correct result: the cold-start model has
`currentIndex == -1` and `activeClassId == ""`, so **no** row is
current and every row stays Ghost. The highlight only appears after
a click, which is a behaviour no screenshot of a cold start can
show.

### Phase 5.18 — switching images must not carry the previous image's data

**The bug 5.17 introduced.** 5.17 made the sidebar's folder rows
dispatch `SelectIndex`, which turned a latent bug into the first thing
a user does. The handler moved `currentIndex` and cleared
`selectedId` — nothing else. So **the previous image's annotations,
bindings and label stayed on screen under the new image's name**, and
in a labelling tool those annotations would be saved against the new
file. Annotations belong to an image, not to the application.

**What landed.** `pub fn state_for_image_change(model, idx) -> Model`
in `app.mbt`, which `SelectIndex` now delegates to. It resets:

- per-image **data** — `annotations`, `bindings`, `label`,
  `labelPath`, `loadedFromDisk`;
- work in progress on the old image — `draftPoints`,
  `bindingFromId`, `mode`, `selectedId`, both cursor positions;
- the **viewport** — `pan`, `zoom`, `fitMode`. A zoom into one scan is
  meaningless on the next, and carrying it over reads as a rendering
  fault.

And it deliberately **keeps** the project-level state: `folder`,
`images`, `videos`, `labelFolder`, `classes`, `activeClassId`,
`classType`. The class list is a property of the project, and 5.17
gave the user a way to pick a class one phase earlier — dropping
`activeClassId` on every image switch would regress a feature a week
old. There is a test for exactly that half, because "reset
everything" is the obvious wrong implementation.

**`imageSource` is NOT reset, and that is a stated limitation.** The
pixels are not reloaded, because nothing in MoUI 0.1.12 can:

> **CORRECTED IN PHASE 5.22 — this reasoning was wrong.** `Effect::Task`
> *is* executed: `runtime/runtime.mbt:46-49` calls `start_task(...)`,
> which reaches `runtime/program_runtime_effect_tasks.mbt:22` and
> calls `start(...)`. The three occurrences counted here are the
> *diagnostic summary pass*, not the execution path — I read a counter
> as a verdict. Separately, a sync `update` **can** read a file:
> `moonbitlang/x/fs` is a synchronous API, importable all along. Disk
> reads are implemented in 5.22.
>
> What is still true: `imageSource` is not reset, and the *pixels*
> still do not reload — but for the ordinary reason that decoding an
> image into the `ImageCache` is a second unwired step, not because I/O
> is impossible. See "Phase 5.22".

That is a sharper statement than the one in `image_header.mbt`, which
attributes the blockage to MoonBit's language (no sync→async bridge,
FFI pointer types rejected). Both are true, but the MoUI-side one is
the binding constraint and it is the one worth knowing. It also
settles the question for `ReadLabelFor`, `LoadFolder` and
`ScanClasses` — all three are no-op stubs, and all three are blocked
for the same reason, so no amount of cleverness in `update` will wire
them.

Stale pixels are the lesser evil: they are visibly the same image,
whereas misattributed *annotations* are silent.

**Tests (306/306, +4).** Per-image data cleared (the "cleared"
assertions are real — `Model::new()` already ships three demo
annotations, so this would have failed before); in-progress drawing
state and viewport reset; project-level state surviving; and an
out-of-range or `-1` index being safe and reporting `"No image"`
rather than claiming a file that is not there.

**Incidental.** `ClassType` gained `derive(Eq)`, so the survival test
can assert on it. It is a fieldless enum like `Mode` and `Shape`, both
of which already derived `Eq`; this brings it in line rather than
working around it with a `match` in the test.

**Verification:** 306/306 tests pass (302 -> 306); `moon check
--target native` 0 errors (185 pre-existing warnings, unchanged);
`moon fmt --check` flags neither touched file. Smoke
`_build/phase5_18_final._window._window.png` is unchanged from 5.17 —
correct, since the demo model never switches images.

### Phase 5.19 — the class list was half-built

> **Second numbering collision.** The older roadmap also numbered a
> phase 5.19 (zoom-drag), which shipped in 5.6/5.7. As with 5.10, the
> number here is kept for chronological continuity with 5.18 and the
> per-file comments are the tie-breaker.

**What was broken.** The class list could be **added to** but not
otherwise managed: `AddClass` appended an entry, and
`UpdateClass`, `DeleteClass` and `SetDefaultClass` were all
one-line no-op stubs. Unlike `ReadLabelFor` / `LoadFolder` /
`ScanClasses` — which 5.22 showed were **not** I/O-blocked at all (see
"Phase 5.22"; the blocker this paragraph cites was a misreading) —
these three are **pure model edits**. There was never a reason for
them to be inert.

**What landed.** All three, plus one gap they exposed.

- `SetDefaultClass` — flips `is_default` across the class list so
  exactly one class carries it. Two classes carrying the flag makes
  `default_class_id` order-dependent, which is not a default at all.
- `UpdateClass` — renames the **display name** and nothing else.
  That is deliberate and is the point of the id/name split: an
  annotation stores the class **id**, and `class_lookup_name`
  resolves it through `model.classes` at draw time, so every
  on-canvas label follows the rename with **no annotation being
  touched**. The first draft of the handler rewrote every
  `ann.class_id` as `id -> id` — a no-op dressed as work — and it
  was removed rather than kept as decoration. A test asserts the
  absence of annotation churn, because that is the only way to catch
  it next time.
- `DeleteClass` — removes the class **and clears `class_id` on every
  annotation that referenced it**, plus the session choice. A
  surviving reference would render the annotation's own raw id on
  the canvas (`class_lookup_name`'s unresolvable fallback) and
  persist that into the label JSON.

**A bug the tests caught.** `SetDefaultClass("does-not-exist")`
originally flipped the whole list, which *unset the existing
default* — so "set the default to a class that doesn't exist" meant
"there is no default". It is now a no-op that reports the unknown id,
and `SetDefaultClass` is the only one of the three that leaves
`label.dirty` alone when nothing matched.

**The two "active class" layers, now both real and distinct.**

| | scope | cleared by |
| --- | --- | --- |
| `ClassEntry::is_default` | the **project**, persisted with the classes | `SetDefaultClass` |
| `Model::activeClassId` | the **session**, set by clicking a sidebar row (5.17) | a second click on the active row |

`default_class_id` prefers the session choice and falls back to the
project default. Keeping both is not redundancy: a session choice
should not silently rewrite the project default, and it must be
clearable without touching what the project says. That
clearability was missing — `activeClassId` started empty but **no
input could return it to empty**, so the first class the user clicked
was permanent for the session. A second click on the already-active
row now dispatches `SetActiveClass("")`.

**Reachable, or not.** `SetActiveClass`'s toggle is on the sidebar and
user-reachable. The other three are **not** reachable from the UI
yet: there is no rename/delete affordance, and app_moui does not even
link the labeler backend (`app_moui/moon.pkg` imports no
`riantr/moonbit_labeler/labeler`), so the `OpResult` path that would
carry them from a real `UpdateClasses` op does not exist here. They
are model operations with no user-facing trigger — which is a
different and much less harmful state than a *stub that lies*, but
it is not "shipped", and the UI affordance is the obvious follow-up.

**Tests (311/311, +5).** The default being exclusive; the two layers
and clearing falling back to the project default rather than to
empty; a rename moving the name while annotations stay bit-identical;
a delete clearing every reference including `activeClassId`; and all
three handlers reporting an unknown id instead of faking success.

**Verification:** 311/311 tests pass (306 -> 311); `moon check
--target native` 0 errors (185 pre-existing warnings, unchanged);
`moon fmt --check` flags none of the 3 touched files. Smoke
`_build/phase5_19_final._window._window.png` is unchanged from 5.18 —
correct: the demo model has no classes loaded, so the class rows are
the fallback demo set and no row is active.

### Phase 5.20 — the demo class list becomes real state, and the buttons become live

5.19 ended by saying its rename/delete handlers had **no user-facing
trigger**. This phase makes two of the three reachable, and the
reason they were unreachable is worth recording because it was not
"the UI was never built".

**The class rows named classes that did not exist.** `model.classes`
was always empty (`ScanClasses` is a no-op stub and nothing
dispatches `ClassesLoaded`, 5.19), and the sidebar rendered a
**hardcoded string list** instead — `["knife", "gun", "batt", ...]`.
So a `*` or `x` button on those rows would have dispatched
`SetDefaultClass` / `DeleteClass` against ids absent from
`model.classes`, and both would have answered **"No such class"**.
Building the buttons first would have manufactured two more dead
controls — precisely the failure 5.9, 5.10 and 5.17 spent this
track removing. Making the rows address real state is what makes
them live.

`Model::new` now seeds `model.classes` with six `ClassEntry`
records (`default_demo_classes`, id == name) and
`sidebar_class_rows` iterates `model.classes` with the hardcoded list
gone.

**No class is marked `is_default`, and that is the load-bearing
detail.** It keeps `default_class_id` returning `""`, so a demo
annotation has an empty `class_id` and labels itself with its own id
(`class_lookup_name`'s fallback). Marking one default would give
every demo annotation the same "knife" label and hide exactly what
the smoke screenshot exists to show. The test asserts this
consequence, because "seed the classes" and "seed them without a
default" look identical until the screenshot changes.

**The row is now three controls**, not one:

| control | dispatches | meaning |
| --- | --- | --- |
| `# name` (120 px) | `SetActiveClass(id)` | this **session**'s class; a second click clears it (5.19) |
| `*` (24 px) | `SetDefaultClass(id)` | the **project** default, filled when `is_default` |
| `x` (24 px) | `DeleteClass(id)` | remove, clearing every reference (5.19) |

The star is filled from `is_default` and the name button from
`activeClassId`, so the two layers are visually distinct on the same
row rather than being two shades of the same question. A test sets
one without the other and checks the other does not follow.

**Still not reachable: rename.** `UpdateClass` is implemented and
tested but has no UI, because it needs text entry and the sidebar
has nowhere to put a field. MoUI *does* have a controlled
`@views.text_field(value, on_input~, on_submit?)`, so this is a
build-not-a-blocker, and it is the obvious next slice. It is
deliberately not started here: it needs an edit-mode flag plus a
buffer on the Model, and shipping half of a rename flow would be
worse than shipping none.

**Tests (314/314, +3).** The seeded list being real, unique and
default-free (asserted through a new annotation's `class_id`); all
three buttons reaching a handler that answers without "No such
class"; and the two "active" affordances being independent.

**Verification:** 314/314 tests pass (311 -> 314); `moon check
--target native` 0 errors (185 pre-existing warnings, unchanged);
`moon fmt --check` flags none of the 3 touched files. Smoke
`_build/phase5_20_final._window.png` shows the six rows as
`# knife  *  x` … `# botl  *  x`, and the canvas annotations still
labelled `rect-1` / `poly-1` / `kp-1` / `ann-1` / `ann-2`.

**Tooling note.** Mid-phase, a PowerShell rewrite of `app.mbt` failed
mid-script and truncated the file to 8 lines. `git checkout` restored
it from the 5.19 commit and the 5.20 work was redone. The rule for
next time: **never rewrite a source file from PowerShell**; use the
file-edit tool, and check `git diff --stat` after every edit so a
truncation is visible immediately. The file-edit tool also failed
repeatedly on one specific block in `labeler_ui.mbt` (now worked
around with smaller, uniquely-anchored edits) for reasons never
diagnosed.

### Phase 5.21 — the rename session

5.20 left `UpdateClass` implemented and tested but with no UI,
because rename needs text entry. This phase builds that input.

**Model + messages.** `editingClassId` and `renameBuffer`, plus four
messages: `StartRenameClass(String)`, `RenameInput(String)`,
`CommitRename`, `CancelRename`. The mode flag is the point: without
somewhere for a half-typed name to live, `CancelRename` has nothing
to undo, and a rename cannot be abandoned at all.

Three decisions in the transitions:

- **Entering seeds the buffer with the class's current name.** A
  rename that opens on an empty box is a "retype it", not a "rename
  it" — and the seed is what makes the field's text match the row it
  replaced.
- **Committing an empty buffer cancels.** An empty class name renders
  as a label with nothing in it, and once the text is gone the UI has
  no way to express "leave it alone".
- **The messages are total.** Commit with nothing in flight, and
  starting an edit on a class that is not there, are both no-ops that
  say so. The last case that matters: if the class is **deleted while
  its edit is open**, committing releases the mode and renames
  nothing — a dead edit session cannot survive a delete.

`UpdateClass` and `CommitRename` now both delegate to one pure
helper, `renamed_class(model, id, name)`, so the message and the
sidebar button are the same operation reached two ways.

**Sidebar.** Each class row gains a `>` trigger that starts the
session. While a row is being renamed, its name button is replaced by
a controlled `@views.text_field(value=renameBuffer,
on_input=RenameInput, on_submit=CommitRename)` and the `>` trigger is
**dropped** — its absence is what marks the row busy. The view only
forwards Msgs; every decision is in `update`, which is the rule the
whole tree follows.

Two MoonBit details worth writing down, because both are errors you
only get once:

- `on_input` is a **function**, not a Msg, so a bare constructor is
  rejected: *"Using constructors as higher order function directly is
  forbidden"*. It needs `fn(text) { RenameInput(text) }`.
- `on_submit` is `Msg?`, and a bare constructor is not a `Msg` value
  either — it needs `Some(CommitRename)`.

**What is verified, and what is not.** The state machine is fully
tested (+4). The **widget** is verified by the inspector rather than
by eye, because the per-window capture does not reach the class rows
(5.14/5.15) and the full-desktop capture came back entirely black on
both attempts this phase — a harness flake, since the same command
produced a good desktop capture in 5.20. Dumped from inside
`render_frame`, the live tree shows:

```
86  TextField   x=0     y=257.5  96x16   paint_bounds non-empty
87  ...         x=98    y=257.5  20x16   (*)
90  ...         x=120   y=257.5  20x16   (x)
```

So the field is in the tree, on the right row, at the size the view
asked for, and it **produced paint output** rather than being a
silently empty node. The row's `>` trigger is absent while editing,
exactly as intended.

**Not verified: how the field looks.** Glyphs, caret, background and
click-to-focus are untested by anything here, and this is the app's
first text-input widget — nothing else in the codebase exercises
MoUI's text editing path. That is the one thing to eyeball on the
next interactive run. Note that keyboard focus for the field is a
separate question from the three toolbar shortcuts wired in 5.10:
those are `View::keyboard_shortcut` (global, no focus needed, 5.10's
finding), whereas a text field needs real focus, and nothing in this
phase grants it.

The demo state also leaves the second class row mid-rename, for the
same reason the polygon demo stops mid-draft in 5.11: a cold start
never renders the field, so without it the new widget gets no visual
coverage at all.

**Tests (318/318, +4).** Seeding the buffer; the round trip
(type → submit → name moved, id unmoved, label dirty); cancel and
empty-commit both leaving the class untouched and the label clean;
and the total-message cases including delete-during-edit.

**Verification:** 318/318 tests pass (314 -> 318); `moon check
--target native` 0 errors (185 pre-existing warnings, unchanged);
`moon fmt --check` flags none of the 4 touched files. Smoke exits 0
and the app boots and renders; the screenshot cannot reach the
sidebar rows, so the field's appearance is the acknowledged gap
above.

### Phase 5.22 — the file-I/O blocker was a phantom

5.13 concluded that this app **cannot** read files, and every phase
since cited that as the reason `ReadLabelFor` / `LoadFolder` /
`ScanClasses` were inert stubs. Both halves of that conclusion were
wrong, both were cheap to check, and neither was checked for nine
phases. This phase removes the blocker and corrects the record.

**The two wrong claims.**

1. *"`Effect::Task` is never executed."* I had grepped MoUI for
   `Effect::Task`, found the constructor plus a counter at
   `runtime/program_plan_summary.mbt:273`, and generalised "counted
   but never run". The execution lives in a **different file**:
   `runtime/runtime.mbt:46-49` calls `start_task(...)`, which lands in
   `runtime/program_runtime_effect_tasks.mbt:22` and calls `start(...)`.
   The summary counter is a parallel diagnostic pass, not the
   execution path.
2. *"There is no sync→async bridge, so a sync `update` cannot read a
   file."* True of `moonbitlang/async` — and irrelevant, because
   `moonbitlang/x/fs` is a **synchronous** filesystem API that was
   importable the entire time. It was one `moon.mod` line away.

The shared failure is worth more than either bug: **a search that
finds one instance of something and concludes the category is absent.**
Claim 1 read a counter as a verdict; claim 2 read "the async package
can't do it" as "the toolchain can't do it" without asking whether a
synchronous package existed. Upstream already answered that question —
MoUI's own `backend/common/services/native/moon.pkg` imports
`moonbitlang/x/fs` with `supported_targets = "native"`. Sync disk I/O
on Windows is supported, not a workaround.

**Two environment traps, neither guessable.**

- `app_moui` is its **own module** (`riantr/moonbit_labeler/app_moui`,
  own `moon.mod`), not a package of the repo-root module. Adding the
  dependency to the root `moon.mod` changes nothing here; the error
  even says "its containing module is not imported by
  riantr/moonbit_labeler/app_moui".
- `moonbitlang/async/fs` and `moonbitlang/x/fs` both want the bare
  alias `fs`, and MoonBit rejects the collision outright ("Conflicting
  import alias"). It needs an explicit `"moonbitlang/x/fs" @xfs`.
- The `moonbitlang/x` version must **match MoUI's own pin** (`0.5.1`).
  Forcing a newer `0.5.5` fails in *MoUI's* code, not ours:
  `backend/common/services/native/filesystem_services.mbt:53`
  annotates `@fs.read_dir` as `Array[String]` while 0.5.5 returns
  `ArrayView[String]`. A version bump that looks like your bug and is
  not.

**What landed.** New `app_moui/disk_io.mbt`: `extension_of`,
`media_kind`, `join_path`, `strip_extension`, `label_path_for`,
`sibling_label_folder`, `name_less`, `scan_folder`, `read_label_text`,
`write_label_text`, `load_label`. Wired into `LoadFolder`,
`FolderLoaded`, `ReadLabelFor`, `SaveLabel` and — the part that makes
it *reachable* — `SelectIndex`, which the sidebar's image rows already
dispatch since 5.17. `probe_image_dimensions_path` is now a real
synchronous read too, replacing a stub that unconditionally returned
`None`.

**Decisions worth recording.**

- **The label path convention was recovered, not guessed.** The shipped
  dataset pairs `Image@skin/BIOMEDICA_P0_JCAS-4-2-g001.jpg` with
  `Label@skin/BIOMEDICA_P0_JCAS-4-2-g001.json` — extension stripped,
  *not* `.jpg.json` appended. There is a test asserting exactly these
  filenames.
- **Saving targets `model.labelPath`, not a re-derived path.**
  `labelPath` is empty until an image has actually been read, so Save
  before that cannot invent a filename and drop a stray JSON into the
  working directory. There is a test for the refusal.
- **Missing label ≠ empty label.** No file resets the canvas and says
  "no label"; a file that exists but fails to parse returns `Some`
  with its `raw_json` intact, so a re-save cannot destroy a label this
  build cannot read. An un-annotated image is a normal outcome, not a
  red toast.
- **Parent directories are not auto-created.** Writing into a
  `Label@...` folder that does not exist is a layout error worth
  surfacing.

**MoonBit's `String.<` is length-first, not lexicographic.** Measured,
not assumed: `"bb" < "ccc"` is `true`. This was found by a failing
index assertion — sorting the shipped dataset put
`BIOMEDICA_P0_JCAS-4-2-g001.jpg` (30 chars) ahead of the `2-` series
(31 chars). `name_less` is therefore an explicit lexicographic
comparator. **Neither order is universally right**: length-first is
better for numbered filenames (`img1, img2, img10`), lexicographic for
series names, and this dataset is series-named. There is a test pinning
MoonBit's behaviour so nobody re-derives it; if a future toolchain
makes `<` lexicographic that test fails loudly, which is when
`name_less` can be deleted.

**`media_kind` returns `MediaKind?`, not a third `Other` variant.**
`MediaKind` already existed in `app.mbt` and is matched exhaustively,
so widening it to carry a non-media case would force every one of those
matches to grow a dead arm. "There is no media kind" and "the kind is
`Other`" are different claims and only the first is true.

**What is still not done, honestly.**

- **Image pixels still do not load.** The *label* half works; the
  *pixel* half is a second step after the read (`decode_image_bytes`
  plus an `ImageCache::load`) and neither is wired to `SelectIndex`. So
  selecting a real image updates annotations and the status line while
  the canvas keeps showing the previous pixels.
- **`ScanClasses` is still a no-op — for a real reason now.** There is
  no class source in the shipped dataset: `data/Label@skin` holds one
  `.json` and no `classes.txt`, so there is no on-disk convention to
  recover. Deriving classes from the distinct `type` values across
  labels is a plausible design, but shipping it as though it were the
  recovered convention would misrepresent it.
- **`LoadFolder` has no UI trigger.** There is no folder picker in this
  app (the `[File]` button was removed in 5.9 as a dead control), so
  scanning is currently reachable programmatically only. `SaveLabel`
  likewise has no toolbar button yet — the handler works and is
  tested, but nothing dispatches it.
- **`ImageEntry.size_bytes` / `VideoEntry.frame_count` are always 0.**
  `x/fs` exposes no stat or size call, and inventing a number the UI
  could display would be worse than reporting none.
- **VOC/YOLO export remains unimplemented.**

**The screenshot is not the evidence here.** This phase changes the
data layer only — the view tree is untouched — so the smoke capture
cannot show it either way. Per the 5.15 rule the evidence is the test
suite, and it is unusually strong: the folder scan, the label parse
(9 annotations from the real shipped JSON), the image-header probe, and
the select→load round trip all run against `data/`. A synthetic
fixture written by the same code under test would have agreed with it
by construction, which is exactly what it would not have proved.

One test-authoring lesson from this phase, because it cost a cycle: a
guard-less `annotations[0]` **panics**, and a panic kills the whole
blackbox executable — silently discarding the results of every test
that ran before it. An earlier draft reported "1 failed" while five
tests had actually failed, because the run died before printing a
summary. Every index in the new tests is length-guarded now.

**Tests (347/347, +29).** Pure helpers (extension parsing incl.
dotfiles and double extensions, case folding, path joining, the
`Image@`/`Label@` sibling rule); disk round-trips (write→read,
unwritable target, missing file vs unreadable directory); the shipped
`data/Image@skin` scan and `data/Label@skin` JSON parse; the real-image
header probe; and the handler wiring end to end — `LoadFolder` on the
real folder, `SelectIndex` loading the real label, the no-label row
staying clean, 5.18's no-carry-over invariant surviving the load, class
id resolution both ways, `SaveLabel` writing and re-parsing, and Save
refusing without a known path.

**Verification:** 347/347 tests pass (318 → 347); `moon check
--target native` 0 errors (185 pre-existing warnings, unchanged);
`moon fmt --check` flags none of the touched files. Smoke exits 0 and
the per-window capture shows the UI unchanged (toolbar, shortcut row,
sidebar, canvas annotations all intact); the full-screen capture came
back black, which is the harness flakiness 5.21 recorded, and the
sidebar rows are still outside the per-window capture's reach.

### Phase 5.23 — the pixels, not just the labels

5.22 left the app in a state that was worse than it looked. Selecting
a real image loaded its **label** from disk, so the annotations and the
status line were right — while the canvas kept showing the *previous*
image's pixels. Correct annotations over the wrong picture is the worst
of both, and no screenshot in 5.22 would have shown it, because 5.22
never put a real image on screen.

This phase closes the loop: read → decode → widen to RGBA8 → register
in the renderer cache → repoint `imageSource` / `imageNaturalSize`.

**`riantr/moonbit_image` has no `to_rgba8`.** Its `transform` module
offers flip / rotate / crop / resize and nothing else, and
`ImageCache::load_bytes` demands exactly `width*height*4` bytes. So
`to_rgba8_bytes` in `image_header.mbt` widens all four `PixelFormat`
arms. The shipped sample decodes as **RGB8** (517×371, 575,421 =
517×371×3 bytes), but all four are implemented and tested: one folder
is not evidence about the decoders, and a grayscale X-ray is `Gray8`,
which is the *expected* case in this domain. `GrayA8` is the one arm
that **keeps** the encoder's alpha; the other two force 255 because
their formats carry none.

Two details that are load-bearing rather than cosmetic:

- **The wideners clamp, they do not trust.** Each arm iterates
  `min(width*height, data.length() / bytes_per_pixel)`, so a decoder
  that returned a short buffer produces a short result instead of an
  out-of-bounds panic, and `load_bytes`' own length check is what
  rejects it. Validation lives in one place instead of being
  re-implemented per arm.
- **Registration happens before `imageSource` moves.** The canvas
  emits a `DrawImage` for any non-empty `imageSource`, and the
  rasterizer's cache-miss fallback paints a grey X — so the other
  order flashes the placeholder for a frame. For the same reason
  `image_pixels_loaded` **leaves `imageSource` untouched** when the
  decode fails: swapping a real picture for a grey X is a worse outcome
  than the stale image the user already had, and the status line says
  `no pixels` instead.

**The cache is now bounded.** Every entry is a full RGBA8 buffer
(767,228 bytes for the shipped sample), so walking a 500-image folder
unbounded would cost ~380 MB and release none of it. `register_image_in_renderer`
clears the map at 64 entries — deliberately **not** an LRU, and
documented as such: it is the cheapest policy that makes the bound
real, and a re-registration of an already-cached source is not growth
so it does not trigger a clear. `image_in_renderer` is what makes
re-selecting the current image free; the decode (~190k pixels to widen
here) is the expensive half and is skipped on a hit.

**This blocks, and that is a real cost.** The decode and widening are
synchronous, on the thread running `update` — the UI thread. For the
shipped 517×371 sample that is single-digit milliseconds; for a 4K scan
it is ~8.3M pixels and ~33 MB of buffer, and the click will visibly
hitch. The architecture offers no alternative: MoUI's `update` is sync,
and `Effect::Task` is a *subscription* whose completion would still have
to be marshalled back onto the UI thread. So the cost is acknowledged
rather than solved, and mitigated by the cache.

**`PixelFormat` cannot be constructed from outside the package.** It is
a `pub enum`, not `pub(all)`, so its constructors are read-only and
even upstream's own tests only ever *match* on it. A synthetic `Image`
with a chosen format is therefore impossible, and the four arms are
reached through **real encoded PNGs** instead — one per colour type,
generated once and embedded as hex, with a guard test that each decodes
to the dimensions and bytes-per-pixel its type implies.

The first attempt at those fixtures was a hand-rolled builder emitting
*stored* (uncompressed) deflate blocks with a hand-written CRC-32, and
**all four arms failed to decode**. The CRC was the cause, and the
reason is worth keeping: **MoonBit's `Int` is 32-bit signed**, so
`0xFFFFFFFF` is `-1`, `0xEDB88320` is `-305424608`, and `>>` is an
*arithmetic* shift — a state of `-1` shifts to `-1` forever, and the
checksum returns a wrong negative number with no error anywhere. The
published check value `0xCBF43926` does not fit a positive `Int`
either, so the known-answer test had to assert `-873187034`. Upstream
solves the same problem with `(v >> 1) & 0x7FFFFFFF` (`lsr1` in
`moonbit_image/utils.mbt`); embedding a known-good file sidesteps the
whole class of it.

**The smoke demo now uses the real dataset.** `build_real_data_demo`
tries `data/Image@skin` then `../data/Image@skin` and selects index 4 —
the one image with a label — so the screenshot shows a real X-ray with
its nine real annotations, exercising the entire path end to end. Two
candidates rather than one because the harness sets the working
directory to the repo root while `moon run` from `app_moui` would need
the other form, and a hardcoded single path would work *by accident of
the caller's cwd*. It returns `Model?` and falls back to the synthetic
fixture when no candidate scans, so a checkout without `data/` still
produces a working screenshot.

**Not verified — and deliberately not guessed.** The smoke capture
shows a narrow striped band along the image's left edge. The source
data is *not* the cause: the shipped JPEG's first 8–9 columns are pure
white at every sampled row (0, 100, 200, 300, 370), and the top of
column 0 is a uniform ~252. So the decode is correct, and the artifact
is in how the image reaches the screen. **I did not attribute it**,
because the per-window capture is cropped and 5.15's rule is that
positions get answered by `paint`, an inspector snapshot or a test —
never by fitting numbers to pixels in a screenshot. It wants one
instrumented `run.frame` dump. It is cosmetic and it does not affect
any assertion in this phase.

**What is still not done, honestly.** `LoadFolder` and `SaveLabel` have
no UI trigger (there is no folder picker in the app); `ScanClasses`
remains a no-op for the reason 5.22 gave — no class source in the
dataset; `size_bytes` / `frame_count` are always 0 because `x/fs` has no
stat call; VOC/YOLO export is unimplemented; and near-neighbour
minification is still the sampler, so shrinking a detailed scan will
alias.

**Tests (361/361, +14).** The four widening arms against real PNGs
(including that `GrayA8`'s alpha 128 survives and `RGBA8` is the
identity rather than a rebuild); every colour type landing on exactly
`w*h*4`; the fixture guard; the real shipped JPEG decoding to 517×371
with a 767,228-byte buffer; a repeat load served from cache; a
non-image file refused at every layer; and the handler wiring —
`SelectIndex` moving `imageSource` / `imageNaturalSize`, pixels cached
before the source points at them, and an undecodable image leaving the
previous source alone.

**Verification:** 361/361 tests pass (347 → 361); `moon check
--target native` 0 errors (185 pre-existing warnings, unchanged);
`moon fmt --check` flags none of the symbols this phase added. Smoke
exits 0 and the per-window capture shows the real X-ray with the
sidebar's six real filenames and the fifth row highlighted; the
full-screen capture came back black, which is the harness flakiness
5.21 recorded.

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
