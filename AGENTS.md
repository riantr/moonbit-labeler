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
