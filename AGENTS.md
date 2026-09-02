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
- Build release:                 `proton_cli build`
- Inspect package plan:          `proton_cli package app --dry-run`
- Produce portable exe + zip:    `proton_cli package app`
  → output: `target/proton-dist/moonbit-labeler/moonbit-labeler.exe` + `.zip`
- Frontend only:                 `cd frontend && npm run dev` / `npm run build`
- Headless JSON-RPC bridge:      run the entry with `--stdio` as the first arg
  (see `app/main.mbt`)

## Project layout

- `app/`                   — runnable entry. `main.mbt` picks Proton/CEF vs `--stdio` JSON-RPC.
- `extensions/labeler/`    — 21 IPC ops (`ext:labeler/<op>`), on-disk label format, VOC/YOLO export,
  and the pure-MoonBit `dispatch_op(op, payload) -> Json raise` entry point.
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
- `moon.proton`            — window 1280x800, entry=`frontend/dist/index.html`, Vite dev_url.
- `moon.mod`               — `riantr/moonbit_labeler` v0.2.0, depends on `moonbitlang/async@0.19.4`.

## Code style

- MoonBit source under `app/` and `extensions/labeler/`. Vendored code under `extensions/image/`
  stays untouched except when bumping the upstream pin.
- IPC ops are registered via `@proton_command` in `extensions/labeler/labeler.mbt`. A new op must
  be added to the table in [README.md](README.md#ipc-surface) and exercised from `frontend/src/`.
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
  `@proton_command` ops (`ext:labeler/<op>`) or the headless `--stdio` JSON-RPC bridge
  defined in `app/stdio_main.mbt` + `app/main.mbt`.

## Security

- Never commit secrets — there is no `.env`; runtime data lives under `data/`, which is
  gitignored.
- The `--stdio` bridge is a privileged local IPC surface: it accepts JSON-RPC from whoever
  owns the parent process. Only invoke it from a trusted local driver; do not expose it
  on a network socket without an explicit auth layer.
- CEF download (`proton_cli cef setup`) is a 150 MB tarball — verify the SHA256 from
  upstream if operating in a high-trust environment.
