# app_moui

Native MoUI app for riantr/moonbit_labeler (0.3.0+).

This package hosts the cross-platform native MoUI app that replaces
the current CEF + Proton + vanilla-JS frontend. The shared TEA app
(`app_moui/app/`) is platform-neutral; each platform entrypoint
(`app_moui/windows_skia/`, `linux_skia/`, `macos_skia/`, `web_wasm/`)
is a thin `main` that wires the host backend into the runtime.

## Layout

```text
app_moui/
  app/                  # shared app package — Model + Msg + Update + view
  windows_skia/         # Windows entrypoint (skia renderer)
  linux_skia/           # Linux entrypoint (skia renderer)
  macos_skia/           # macOS entrypoint (skia renderer)
  web_wasm/             # Browser entrypoint (wasm-gc + WebGPU)
```

## Status

- Phase 0 (this session): MoUI spike + dependency resolution.
- Phase 1 (this session): design doc at `_build/design/moui-migration-design.md`.
- Phase 2 (this session): shared app skeleton + Model + Msg types.
- Phase 5.1–5.4 (this + prior sessions): canvas view scaffold → image
  source + fit-contain → 8 px handle hit-test + drag → DPR scaling
  investigation (no-op; see `_build/design/dpi-investigation.md`).

Deferred to follow-up sessions:

- Phase 5.5: static + dynamic layer composition (single layer for now).
- Phase 5.6: image-header probe (caller currently passes natural size).
- Phase 5.7–5.10: rect/polygon/keypoint/binding draw upgrade (thick-line
  approximation for polygon; 8×8 fill_rect for keypoint; binding arrows
  not yet drawn).
- Phase 5.11: wheel zoom + drag pan input plumbing (Zoom/Pan Msgs wired
  in update() but no input handlers).
- Phase 5.12: canvas.js 35 KB full parity (hard bone).
- Phase 6: 21 op handler direct-call wiring (replace `dispatch_op` with
  `op_<name>(req)`).
- Phase 7: 8 frontend modules → MoUI views.
- Phase 8: cross-platform entrypoints + smoke tests
  (windows_skia / linux_skia / macos_skia / web_wasm).
- Phase 9: CEF path deprecation + 0.3.0 release.