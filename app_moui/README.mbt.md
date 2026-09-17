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

Deferred to follow-up sessions:

- Phase 3: 21 op handler direct-call wiring (replace
  `dispatch_op` with `op_<name>(req)`).
- Phase 4: 8 frontend modules → MoUI views.
- Phase 5: Canvas 2D → `custom_children_layout` + `DrawCommand`.
- Phase 6: cross-platform entrypoints + smoke tests.
- Phase 7: CEF path deprecation + 0.3.0 release.