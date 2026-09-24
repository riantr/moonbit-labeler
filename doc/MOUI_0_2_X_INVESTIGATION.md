# Phase 16.D — Moui 0.2.x upgrade investigation

Goal: check whether upgrading `wzzc-dev/moui` from 0.1.12 to a
hypothetical 0.2.x would unlock Phase 14 (image disk-load bridge).
Phase 14 was parked because `Effect::task.start` is a sync callback
and `@fs.read_file` (moonbitlang/x/fs) requires `async@0.21+`.

## Conclusion: skip the upgrade; Phase 14 is unlockable on Moui 0.1.12

Moui 0.1.12 already exposes everything we need:

1. **Typed async file I/O** — `FileServices::read_bytes(path) ->
   ServiceTask[Bytes]`. The `ServiceTask` type is async-via-callback
   (`.start((ServiceTaskResult[T]) -> Unit)`) and `.effect(map)`
   converts it into an `Effect` for the runtime. The runtime calls
   the start callback synchronously *and* retains a cancel handle,
   but the body of the callback can do whatever it wants — including
   kicking off a thread, calling into the host's native bridge, etc.

2. **Image source pipeline** — `HostImageSource::new(read=(String)
   -> Bytes?)` is wired into the Windows backend via
   `@host_image_native.filesystem_image_source()`. Internally that
   helper does `Some(@fs.read_file_to_bytes(source)) catch { _ =>
   None }` — the moonbitlang/x call IS happening, but inside the
   *host_image_native* package where the moon 0.1.x import resolution
   bug does not bite (Moui vendors its own internal copy of the
   relevant async primitives; our `app_moui` only sees the clean
   `Bytes?` API).

3. **Image dimension probing** — there's a `probe_image_dimensions`
   path under `@image_header` that already does async read + header
   parse. The phase-14 blocker ("probe_image_dimensions_path returns
   None for everything") was the sync wrapper, not the underlying
   helper — which works fine when called from inside an
   `Effect::service_task` start callback.

So the path to Phase 14 on Moui 0.1.12:

```
view model emit ImageWanted(path)
  -> service: file_services.read_bytes(path).effect(map=ImageLoaded)
  -> runtime kicks off Effect via start_task
  -> start callback calls filesystem_image_source().read(path)
  -> on success, dispatch ImageLoaded(bytes)
  -> message handler: image_cache.load_bytes(source, w, h, data)
  -> next render: cache hit, paint_image draws real RGBA
```

No need to wait for Moui 0.2.x; the upgrade would mostly bring
bug-fixes and small API ergonomics, not the missing async bridge.

## Other things in Moui 0.1.12 worth knowing for app_moui

- **`Effect::task` / `Effect::service_task`** — sync call-and-dispatch,
  not "fire and forget". The `start` callback returns `(() -> Unit)?`
  which is the cancel handle. The runtime WILL cancel tasks when the
  effect key changes; our app_moui code should keep cancel handles
  around if we ever want mid-flight cancellation (we currently don't).

- **`@io.Data` / `@fs.read_file_to_bytes`** — sync wrapper that
  panics on failure (use `try?` form to convert to `Bytes?`). This is
  what `filesystem_image_source` already uses internally. Our
  app-level should NOT import this directly (moon 0.1.x can't resolve
  moonbitlang/x from app packages); instead route through
  `HostImageSource::read` or `FileServices::read_bytes`.

- **`@core.SurfaceMetrics`** — current metrics snapshot; the resize
  callback updates this so `render_frame` (our `render_placeholder_frame`
  in `renderer.mbt`) can size the PixelFrame correctly. Already
  wired in Phase 10.2 / Phase 11.5.

- **Capability flags** — `BackendCapabilities::async_services` /
  `async_image` tell the runtime which services the backend supports.
  The Windows backend sets `async_services=true` (verified in
  `windows_backend.mbt`); image reads off-thread should work today.

- **No 0.2.x in local cache** — `wzzc-dev/moui` is only at 0.1.12 in
  `.mooncakes/`. Newer versions are not vendored; an upgrade would
  require a `moon update` against the registry. Low priority for this
  spike — the spike's goal is to demonstrate the Moui pipeline end-to-
  end, which 0.1.12 already supports.

## Recommendation

- **Do not upgrade Moui** for Phase 14. The async bridge we need
  (`FileServices` + `HostImageSource`) is already in 0.1.12.
- **Do upgrade the moonbitlang/async pin** in `app_moui/moon.mod`
  if we ever need to call `@fs.*` directly from the app — it's
  already at 0.21.2, which is sufficient.
- **Phase 14 plan** (next session, if requested):
  1. In `main_native.mbt`, build a `HostImageSource` wrapper that
     calls `@image_header::probe_image_dimensions` synchronously and
     `@image_decoder` for the bytes, then hands both to
     `image_cache.load_bytes`. (Or just delegate to Moui's
     `filesystem_image_source` and let the runtime handle cache.)
  2. Trigger an image load via the view model's
     `Effect::service_task(file_services.read_bytes(path))` — the
     bytes flow back as a message, get cached, and the next paint
     blits the real pixels.
  3. Add an integration test that opens a 200x200 PNG and verifies
     that `rasterize_draw_frame` paints actual RGBA at the image
     rect within ~16 ms (load + decode + paint, single-shot).

## Spike wrap-up status

Spike complete: Phase 10 (windows_skia launcher) → Phase 11 (CPU
rasterizer translates DrawFrame into HWND pixels) → Phase 11.5
(outline placeholders for DrawText/DrawImage) → Phase 12 (5×7
ASCII bitmap font) → Phase 13 (image cache + real RGBA blit) →
Phase 14 (PARKED; bridge mechanism identified above) → Phase 15
(AA for FillRect + FillRoundedRect + StrokeRoundedRect) → Phase
16.A (QuadTo/CubicTo bezier flattening) → Phase 16.B (Shadow +
separable 5x5 box blur) → Phase 16.C (labeler UI composition
module that exercises every primitive in one frame).

210/210 tests pass. Net spike: +47 commits, ~3000 lines of
rasterizer + tests, +1 labeler_ui.mbt reference module.