// app_moui/labeler_ui.mbt — Phase 18.A labeler UI.
//
// Two parallel APIs:
//   1. build_labeler_ui_view(model, width, height) -> @moui.View[Msg]
//      — the live view tree the program() picks up. Wired into
//      view() in app.mbt. Uses Moui layout primitives (@views.column,
//      @views.row, @views.text, @views.button, @views.canvas) so the
//      UI scales to any window size.
//   2. build_labeler_ui_demo_frame(width, height) -> @core.DrawFrame
//      — Phase 16.C legacy API, kept verbatim for the existing
//      labeler_ui_test.mbt pixel assertions. Rasterizer-only path,
//      doesn't go through the view tree.
//
// Both render the same visual layout: toolbar (top) + sidebar
// (left, 200 px) with folder list + class chips + canvas (right)
// with a decorative bezier in the top-right corner. Phase 16.C's
// decoration is preserved as the canvas-area PaintContext closure
// in build_labeler_ui_view.

///|
/// Phase 18.B — build the labeler UI as a Moui view tree.
///
/// The runtime gives the root view the actual framebuffer size
/// as `Constraints.max`; this builder ignores any caller-supplied
/// width / height (kept in the signature for backwards compatibility
/// with the Phase 18.A call site in app.mbt — the args are unused).
///
/// Layout strategy:
///   - Outer column splits the window vertically: toolbar | main row
///     | status bar, with a `spacer(weight=1)` between the toolbar and
///     the main row that absorbs leftover vertical slack so the main
///     row always sits below the toolbar without pushing the status
///     bar off-screen.
///   - Main row = sidebar (intrinsic width 180, intrinsic height =
///     sum of folder buttons + class chips + section headers + gap)
///     next to a canvas that fills the rest horizontally. The canvas
///     measure returns `c.max` for width but a *bounded* height
///     (c.max.height - toolbar - status) so the row's intrinsic height
///     does not blow past the window — earlier the canvas's
///     `c.max` measure was returning the *full* parent column
///     constraint, which made the row want 800 logical pixels of
///     height even on a 400-px-tall window, clipping everything past
///     the first toolbar row.
///   - Sidebar uses `wrap` for class chips so six chips don't pile up
///     into a 144-px column — `wrap` flows them onto multiple lines
///     when the sidebar width is constrained.
///   - Buttons and text are 20 px tall (was 24 px in Phase 18.A) to
///     pack the sidebar tighter; the toolbar header row uses 28 px
///     so "MoonBit Labeler" stays readable.
pub fn build_labeler_ui_view(
  model : Model,
  width : Double,
  height : Double,
) -> @moui.View[Msg] {
  // Phase 5.12 — `width` / `height` are no longer discarded (they
  // were `let _ : Double = width` through Phase 5.11). They bound the
  // canvas frame below; see the sizing note there.
  // Phase 18.A — dark theme. The runtime's default `Environment`
  // carries a light ColorScheme, which makes `@views.text` and
  // `@views.button` paint dark foreground on the dark slate
  // background we use — illegible. We pass a custom Theme to
  // every text/button so the foreground is near-white. Theme
  // is module-local: cheap to construct, no mutation needed.
  let dark_theme : @core.Theme = @core.Theme::neutral().with_palette(
    @core.ColorPalette::dark(),
  )
  // Phase 5.12 — the chrome (nav row, sidebar rows, shortcut row)
  // gets a theme whose declared type sizes match the 5x7 bitmap font
  // we actually rasterize, so controls land on the heights their
  // `@views.frame` wrappers request instead of 2.25x that. Text
  // widgets keep `dark_theme`: their explicit heights already
  // exceeded the declared text height, so they were never inflated.
  // See `chrome_typography_scale` for the measurement behind this.
  let compact : @core.Theme = compact_theme(dark_theme)
  // Background colors for the three regions. Match the Phase 16.C
  // legacy DrawFrame palette so the view-tree path produces the
  // same visual fingerprint as the rasterizer-only test. These
  // are kept as documentation of the intended color palette;
  // Phase 18.B lays out the regions without their final
  // backgrounds — those re-attach in Phase 18.C alongside the
  // sidebar/canvas dividers.
  let _toolbar_bg : @core.Color = @core.Color::rgba(
    r=0.22,
    g=0.22,
    b=0.26,
    a=1.0,
  )
  let _sidebar_bg : @core.Color = @core.Color::rgba(
    r=0.16,
    g=0.16,
    b=0.19,
    a=1.0,
  )
  let _status_bg : @core.Color = @core.Color::rgba(
    r=0.20,
    g=0.20,
    b=0.24,
    a=1.0,
  )
  // ─── Toolbar (top column: header row + nav row) ───
  // Phase 18.B — drop all `@views.button` widgets in favor of
  // plain `@views.text` placeholders. The button widget's
  // intrinsic height is `max(min_size.height, text_size +
  // 2×sm_padding)` = `max(24, 16 + 16) = 32 px` regardless of
  // the height=24 min_size we pass, because the theme's body
  // font is 16 px and sm-padding is 8 px. That 32-px button
  // inflates each toolbar row from 24 px to 32 px (and the
  // canvas's `c.max` measure adds another 400 px on top), so
  // the outer column's intrinsic height blows past the window
  // and clips the status bar. Phase 18.C will switch back to
  // `@views.button` once we either (a) implement
  // `FillRoundedRectBrush` in the rasterizer so button
  // backgrounds render, or (b) wrap each button in a
  // `@views.frame(width=, height=)` that constrains the
  // intrinsic height back down to the min_size.
  let toolbar : @moui.View[Msg] = @views.column(
    [
      // Header row: title + folder label.
      // Phase 20 — header text heights bumped from 24 to 32 to
      // give the `Title`-role font (21 px) enough vertical room
      // for ascender + descender without clipping. Without the
      // bump the title rendered with the bottom 1-2 px of the
      // glyphs cut off (visible as a slightly-squashed "MoonBit
      // Labeler" in Phase 19's `phase19_smoke_final._window.png`).
      @views.row(
        [
          @views.text(
            "MoonBit Labeler",
            theme=dark_theme,
            role=@style.TextRole::Title,
            width=200.0,
            height=32.0,
          ),
          @views.text(
            "Folder: " + model.folder,
            theme=dark_theme,
            role=@style.TextRole::Body,
            width=320.0,
            height=32.0,
          ),
        ],
        spacing=8.0,
      ),
      // Nav row: the tool picker. Phase 5.9 — the five controls are
      // now real mode selectors (`on_click = SetMode(mode)`) built
      // by `mode_button`; the armed tool is drawn with
      // `ButtonVariant::Primary` and the rest stay `Ghost`, so
      // exactly one button in the row reads as active.
      //
      // Phase 5.9 also replaced the old `[File]` slot with
      // `[Select]`. `[File]` was a permanently dead button (no
      // on_click, and `File` is not a `Mode` variant), and its
      // absence left a real hole: `Select` is the mode every
      // select-and-drag-handle path (Phase 5.4-5.6) depends on,
      // so a user who picked a drawing tool had no way back except
      // the programmatic `SetMode` path.
      @views.row(
        [
          mode_button(model, Mode::Select, compact, 72.0),
          mode_button(model, Mode::Rect, compact, 64.0),
          mode_button(model, Mode::Polygon, compact, 80.0),
          mode_button(model, Mode::Keypoint, compact, 88.0),
          mode_button(model, Mode::EditBinding, compact, 80.0),
          // Zoom % — kept as plain text. It's a read-out, not
          // an actionable control. Phase 18.E leaves it as-is.
          @views.text(
            (model.zoom * 100.0).to_string() + "%",
            theme=dark_theme,
            role=@style.TextRole::Body,
            width=80.0,
            height=24.0,
          ),
        ],
        spacing=4.0,
      ),
      // Phase 5.10 — keyboard shortcuts, on their own toolbar row.
      //
      // They cannot share the nav row: measured off
      // `phase5_10_smoke._window._window.png`, three
      // `shortcut_button`s render at a 304-px pitch (912 px of the
      // 960-px window) because `shortcut_button` floors the label
      // button at `max(72, width - shortcut_width - spacing)` and
      // the key chip at `shortcut_width`. The nav row already
      // spans the window, so a third row is the only placement
      // that fits.
      //
      // Cost, measured: this row adds ~56 px to the toolbar, which
      // clips the sidebar's class chips one row earlier. The sidebar
      // already overflowed before this phase — `phase5_9` showed 2
      // of 6 class chips and the status bar was off-screen entirely
      // (Phase 20's deferred DPI/rasterizer issue) — so the real fix
      // is a taller window, tracked in AGENTS.md, not a smaller
      // feature set.
      shortcut_row(compact),
    ],
    spacing=4.0,
  )
  // ─── Sidebar (left column) ───
  // Phase 18.E — folder rows + class chips are real
  // `@views.button` widgets (`ButtonVariant::Ghost`) inside
  // `@views.frame` clamps so the row pitch stays at 16 px.
  // Phase 18.B had these as plain text because the button
  // widget's `FillRoundedRectBrush` was a no-op (Phase 11
  // left it in the catch-all bucket). Phase 18.E wires the
  // brush cases into `paint_rounded_rect` so the button
  // background reaches the bitmap.
  let sidebar : @moui.View[Msg] = @views.column(
    [
      // Phase 20 — section header heights bumped from 24 to 32
      // for the same `Title`-font reason as the toolbar header
      // (21 px font needs ≥28 px box; 32 px gives ~10 px breathing
      // room for ascender + descender). Visible Phase 19 fix in
      // `phase19_smoke_final._window.png` had "Folders" / "Classes"
      // headers with the bottom of the glyphs clipped.
      @views.text(
        "Folders",
        theme=dark_theme,
        role=@style.TextRole::Title,
        width=180.0,
        height=32.0,
      ),
      @views.column(sidebar_folder_rows(model, compact), spacing=2.0),
      @views.text(
        "Classes",
        theme=dark_theme,
        role=@style.TextRole::Title,
        width=180.0,
        height=32.0,
      ),
      @views.column(sidebar_class_rows(model, compact), spacing=1.0),
    ],
    spacing=6.0,
  )
  // ─── Canvas (right area, custom paint) ───
  // Phase 5.2 — swap the bezier-swoop placeholder (Phase 19)
  // for the model-aware `canvas_view(model)`. The new canvas
  // renders:
  //   - Static layer (cached via ViewPaintLayer cache_key):
  //     neutral background + placeholder StrokeRect (when
  //     model.imageSource == "") OR a real DrawImage (when
  //     imageSource != "" + image_cache hit), plus the model's
  //     annotation set drawn in iteration order.
  //   - Dynamic layer: selected annotation handles + cursor
  //     crosshair + draft polygon/rect preview.
  //   - on_drag → Pan (image pan), CursorMoved (hit-test).
  //   - on_secondary_tap / on_double_tap → ToggleZoomDragMode.
  //
  // The static layer's `ViewPaintLayer::cache_key` is derived
  // from imageSource + annotations + pan + zoom + naturalSize +
  // fitMode (see `canvas_view::static_cache_key`), so when
  // LoadTestImage / LoadImage succeeds the cached bitmap
  // invalidates automatically and the new image paints on the
  // next frame.
  //
  // Sizing: `canvas_view` returns a `@layout.stack` of two
  // canvas layers whose `layout` impls both return
  // `ctx.constraints.max`, so the canvas fills whatever space
  // the outer row gives it. No custom measure needed.
  //
  // Phase 5.12 — tried and reverted: wrapping this in
  // `@views.frame(max_width=, max_height=)` to bound the 1e9 leak
  // described in the compose block below. It does bound the frame
  // (verified in the inspector: node 85 goes from 1e9 to 1100), but
  // the canvas then renders **blank** — neither the image nor a
  // single annotation reaches the buffer. The static layer is
  // presumably painting into a region the rasterizer no longer
  // samples. Not understood, so not shipped; the 1e9 leak is
  // recorded as an open item instead.
  // Phase 5.13 — the frame, and why it exists.
  //
  // `canvas_view` is meant to be greedy, but "greedy" means whatever
  // `ctx.constraints.max` happens to be, and MoUI 0.1.12's
  // `ViewNode::child_constraints` defaults to `constraints.loosen()`
  // — so a pass-through layout hands its children the *unbounded*
  // max (`Constraints::unbounded()` = 1.0e9, `core/geometry.mbt:86`).
  // Neither `@layout.stack` nor `@views.canvas` overrides it. The
  // canvas therefore measured **1e9 x 1e9**, which:
  //
  //  - poisoned the outer column, so the status bar was placed at
  //    `y = 1_000_000_088` and never painted;
  //  - *appeared* to work, because `rasterizer.mbt::paint_image`
  //    maps the destination using `run.frame ∩ clip`, i.e. it
  //    **stretches the image to fill the clipped region** rather
  //    than fitting it into `run.frame`. With a 1e9 frame the
  //    intersection is the whole viewport, so the image filled the
  //    canvas — correct by accident. And because a 200x200 square
  //    image in a 1e9 square frame has the same aspect ratio,
  //    `fit_contain_rect` returned the frame unchanged, so
  //    `dst_origin` stayed at the frame origin and the annotations
  //    landed correctly too.
  //
  // Bounding the frame removes the accident, and then the bound has
  // to be the *real* viewport: an earlier attempt used
  // `build_labeler_ui_view`'s hardcoded `1280.0, 800.0` parameters
  // and produced a 1100x688 canvas, whose fitted image landed at
  // `y = 368` — almost entirely outside the 947x504 buffer, so the
  // canvas rendered blank. `width` / `height` are now
  // `Model::viewport`, which `main_native.mbt` sets from the same
  // constants it hands the runtime.
  //
  // With a correct bound the main row's height becomes 392 rather
  // than 1e9, the column resolves [88, 392, 24] inside 504, and the
  // status bar lands flush at `y = 480`.
  let canvas_frame_w : Double = if width > 180.0 { width - 180.0 } else { 1.0 }
  let canvas_frame_h : Double = if height > 112.0 { height - 112.0 } else { 1.0 }
  let canvas : @moui.View[Msg] = @views.frame(
    canvas_view(model),
    max_width=canvas_frame_w,
    max_height=canvas_frame_h,
  )
  // ─── Bottom status bar ───
  let status_text : String = match model.toastMessage {
    Some(msg) => msg
    None => model.statusMessage
  }
  // Phase 20 — bump status bar text height from 16 to 24 so the
  // glyphs have breathing room (16 px Body font + descender ≈
  // 19 px line-height needs ≥20 px box; 24 px gives ~5 px
  // breathing room). 16 px clips the descenders of "g", "p",
  // "y" which were visible in the Phase 19 smoke as flat-topped
  // letters. The width is a declared floor, not a request: with
  // the chrome theme's 10-px body font the row still measures 24.
  //
  // Phase 5.12 — this bar was never actually on screen before; see
  // the compose block below. The height reasoning above stands, it
  // just never got the chance to show.
  let status_bar : @moui.View[Msg] = @views.row(
    [
      @views.text(
        status_text,
        theme=dark_theme,
        role=@style.TextRole::Body,
        width=400.0,
        height=24.0,
      ),
    ],
    spacing=8.0,
  )
  // ─── Compose ───
  // Outer column: [toolbar, spacer, main row, status bar].
  //
  // Phase 5.12 — **the spacer is the bug, and replacing it does not
  // work either.** Both halves of that are now measured rather than
  // guessed, so the next attempt does not repeat them.
  //
  // The measurement. MoUI 0.1.12's `ViewNode::child_constraints`
  // defaults to `constraints.loosen()`, and neither `@layout.stack`
  // nor `@views.canvas` overrides it. `canvas_view`'s layers return
  // `ctx.constraints.max`, and the unbounded max is 1.0e9
  // (`core/geometry.mbt:86`). The inspector's live snapshot of the
  // real layout (947x504 on this host) records it directly:
  //
  //   node  1 root column   947 x 504      constraints min = max = 947x504
  //   node 59 main row      947 x 1000000088
  //   node 91 canvas         x 180, w = 1000000000, h = 1000000000
  //   node 93 status text    y = 1000000088
  //
  // So the status bar is not "clipped" — it is parked a billion
  // pixels below the window. That is the true cause of every symptom
  // chased since Phase 18, including Phase 20's status-bar mystery
  // (blamed on DPI and on `windows_skia` bottom-edge text; the text
  // simply was never on screen) and the sidebar's apparent overflow
  // (it was always inside the window).
  //
  // Attempt A, reverted: mark the main row `.expanded()` so it
  // becomes a weighted child. Weighted children claim no main-axis
  // base, so the 1e9 canvas cannot poison `child_main_total`; the
  // column then resolves [88, 0, 24] and hands the main row
  // 504 - 112 = 392, putting the status bar at y = 480 = 504 - 24 —
  // **verified correct in the inspector**. But the canvas's own
  // width stays 1e9, the fit-contain math centres the image in that
  // frame, and the canvas renders blank. Fixing that needs the
  // canvas bounded, which leads to:
  //
  // Attempt B, reverted: `@views.frame(canvas, max_width=,
  // max_height=)`. This does bound it (node 85: 1e9 -> 1100), but
  // the canvas *still* renders blank — no image, no annotations, only
  // the neutral background. The static layer is painting somewhere
  // the rasterizer no longer samples. Not understood, so not
  // shipped.
  //
  // Phase 5.12 therefore ships only the chrome theme above, which is
  // independently verified. The spacer stays; the status bar stays
  // off-screen; the open question is why bounding the canvas stops
  // the static layer from painting.
  @views.column(
    [
      toolbar,
      @views.spacer(weight=1.0),
      @views.row([sidebar, canvas], spacing=0.0),
      status_bar,
    ],
    spacing=0.0,
  )
}

///|
/// Phase 5.9 — pick the style that shows which tool is armed.
/// `Primary` is the loud filled variant; every other mode stays
/// `Ghost` so exactly one control in the nav row reads as active.
/// Split out as a pure function (rather than inlined in the view
/// builder) so the "only the current mode is highlighted" invariant
/// is unit-testable without running a paint pass.
pub fn mode_button_variant(
  current : Mode,
  candidate : Mode,
) -> @style.ButtonVariant {
  if current == candidate {
    @style.ButtonVariant::Primary
  } else {
    @style.ButtonVariant::Ghost
  }
}

///|
/// Phase 5.12 — a typography scale sized to the font we actually
/// rasterize.
///
/// **Why the declared size is pure ballast.** MoUI's `button` measures
/// itself as `max(min_size.height, text_height + 2 *
/// spacing_scale.sm)` (`views/button/button.mbt:156`), and the text
/// height comes from the theme's font via
/// `@core.TextSystem::fallback()`, which reports
/// `font.size * 1.25` (`core/text_layout.mbt:568`). But
/// `rasterizer.mbt::paint_text` **ignores `font.size` entirely**: it
/// draws a fixed 5x7 glyph cell and vertically centres it in
/// `run.frame`. The declared size therefore inflates every text
/// bearing widget by 2.25x while changing nothing on screen — a
/// 16-px control font produced 36-px buttons (20 + 2x8) in
/// `@views.frame(width=180, height=16)` rows that asked for 16.
///
/// **Why that overflowed the window.** Measured on this host, the
/// window is 947x504 logical px at `scale_factor = 2` (a 1894x1009
/// physical display), so the 1920x1080 the launcher requests is not
/// obtainable — the runtime re-lays-out to the real surface size.
/// The chrome wanted ~658 logical px: a 234-px toolbar (three rows at
/// ~78 each) plus a ~424-px sidebar (10 rows at 36 plus two 32-px
/// headers). That is 30% more than the 504 available, which is why
/// the status bar never appeared and the lower class chips were cut
/// off. Both had been mis-diagnosed: the status bar was recorded in
/// Phase 20 as a DPI/rasterizer bug in bottom-edge text, and it is
/// neither — the text was never laid out there.
///
/// **Why shrinking the type is free.** Because `paint_text` ignores
/// the size, a smaller declared size collapses the boxes to their
/// requested heights and the glyphs are redrawn identically. The
/// buttons land on the 16 px the frames already asked for, the
/// sidebar pitch becomes 18, and the whole chrome fits in
/// 88 + 244 + 24 = 356 of the 504 available.
///
/// 10 px is not arbitrary: the glyph cell is 7 logical px tall, so
/// 10 px declares (10 x 1.25 = 12.5) slightly more room than the
/// glyphs actually need, which keeps `sm = 1` inside the 16-px floor
/// instead of collapsing the text onto its own descenders.
pub fn chrome_typography_scale() -> @core.TypographyScale {
  let small : @core.FontSpec = @core.FontSpec::new(size=10.0, weight=600)
  {
    display: @core.FontSpec::new(size=16.0, weight=600),
    headline: @core.FontSpec::new(size=14.0, weight=600),
    title: @core.FontSpec::new(size=12.0, weight=600),
    subtitle: @core.FontSpec::new(size=11.0, weight=600),
    body: @core.FontSpec::new(size=10.0, weight=400),
    label: small,
    caption: @core.FontSpec::new(size=9.0, weight=400),
    overline: @core.FontSpec::new(size=9.0, weight=600),
    // `control` is MoUI's historical alias for `label`; the button
    // widget reads this one, so it must shrink too.
    control: small,
  }
}

///|
/// Phase 5.12 — a compact spacing scale to go with
/// `chrome_typography_scale`. With a 10-px control font the button
/// is `max(16, 12.5 + 2 * sm)`, so any `sm` up to 1.75 lands on the
/// 16-px floor the frames request. `sm = 1` keeps a visible pad.
/// `lg` also drops so the horizontal padding stops inflating button
/// widths — it is what made the Phase 5.10 shortcut row render at a
/// 304-px pitch.
pub fn chrome_spacing_scale() -> @core.SpacingScale {
  { xs: 2.0, sm: 1.0, md: 3.0, lg: 4.0, xl: 6.0 }
}

///|
/// Phase 5.12 — derive the chrome theme. Only the typography and
/// spacing change; palette, radii and shadows are inherited, so
/// colours and the canvas are untouched. Applied to the *controls*
/// only (nav-row buttons, sidebar rows, shortcut row); the text
/// widgets keep `dark_theme` and their explicit heights, which were
/// never inflated because their requested height already exceeded the
/// declared text height.
pub fn compact_theme(base : @core.Theme) -> @core.Theme {
  {
    ..base,
    typography: chrome_typography_scale(),
    spacing_scale: chrome_spacing_scale(),
  }
}

///|
/// Phase 5.9 — one tool button in the toolbar's nav row.
///
/// Pre-5.9 the nav row's buttons had no `on_click` at all, so the
/// drawing tools were reachable *only* by dispatching `SetMode`
/// programmatically: a cold-started UI was pinned to `Select` and
/// the user had no way to pick Rect / Polygon / Keypoint / Binding.
/// This wires `on_click=SetMode(mode)` and highlights the armed
/// tool via `mode_button_variant`.
///
/// The `@views.frame` wrapper is the Phase 18.E workaround for the
/// dark theme's 16-px body font + 2x8-px padding, which forces a
/// 32-px intrinsic button height regardless of the `height` we
/// pass. The frame clamps it back to the 24-px nav-row pitch so
/// the toolbar doesn't inflate and push the status bar off-screen.
fn mode_button(
  model : Model,
  mode : Mode,
  theme : @core.Theme,
  width : Double,
) -> @moui.View[Msg] {
  @views.frame(
    @views.button(
      "[" + mode_label(mode) + "]",
      on_click=SetMode(mode),
      theme~,
      variant=mode_button_variant(model.mode, mode),
      width~,
      height=24.0,
    ),
    width~,
    height=24.0,
  )
}

///|
/// Phase 5.10 — one keyboard shortcut: the label shown on the
/// button, the host key name, its modifier mask, the Msg the press
/// dispatches, and the button width.
///
/// This is deliberately *data*, not view code, because
/// `KeyboardShortcut::matches` is a strict
/// `event.pressed && event.key == key && event.modifiers == mods`
/// comparison against the host's own key name. MoUI's Windows
/// backend (`backend/common/input/window_event_decode.mbt ::
/// named_key_name`) emits capitalised names — "Escape",
/// "Backspace", "Delete" — so writing "escape" would silently
/// disable the shortcut with no error anywhere. Keeping the specs
/// as a plain list lets a test drive MoUI's *real* matcher over
/// them, which is the only way to catch that class of typo without
/// a human pressing keys.
pub(all) struct ShortcutSpec {
  label : String
  key : String
  modifiers : @core.KeyModifiers
  msg : Msg
  width : Double
}

///|
/// Phase 5.10 — the app's keyboard shortcuts.
///
/// `CancelDraft` / `PopDraft` had working `update` arms since the
/// draft landed but no way to reach them; `DeleteSelectedAnnotation`
/// was added in an earlier phase explicitly "for the Delete /
/// Backspace keyboard shortcut" and likewise never bound. All three
/// now have one.
///
/// The keys are deliberately distinct, because MoUI's
/// `dispatch_keyboard_shortcut_to_children` walks the children in
/// order and **stops at the first match** — two specs sharing a key
/// would make the second unreachable. Backspace (not Ctrl+Z) is the
/// undo-vertex key because a character key's host name is the
/// literal character, so it is shift-sensitive and ambiguous, while
/// the named keys are exact.
pub fn shortcut_specs() -> Array[ShortcutSpec] {
  [
    {
      label: "Cancel",
      key: "Escape",
      modifiers: @core.KeyModifiers::none(),
      msg: CancelDraft,
      width: 132.0,
    },
    {
      label: "Undo pt",
      key: "Backspace",
      modifiers: @core.KeyModifiers::none(),
      msg: PopDraft,
      width: 148.0,
    },
    {
      label: "Delete",
      key: "Delete",
      modifiers: @core.KeyModifiers::none(),
      msg: DeleteSelectedAnnotation,
      width: 148.0,
    },
  ]
}

///|
/// Phase 5.10 — build the shortcut buttons. Each spec becomes a
/// `@views.shortcut_button`, which renders the label plus the
/// shortcut's `display_label()` (so "Escape" reads as "Esc") and
/// attaches the shortcut via `View::keyboard_shortcut`.
///
/// A `shortcut_button` (rather than a bare `View::keyboard_shortcut`
/// on some invisible node) is required by the runtime: on a key
/// match, `dispatch_keyboard_shortcut` calls
/// `activate_first_child`, and the modifier itself returns
/// `activated: true` with **no Msg**. The Msg only arrives because
/// the first child is a real pressable button whose `on_click` fires.
/// A zero-size shortcut host — or a modifier attached directly to
/// the button itself, which has no children — would therefore never
/// dispatch anything.
///
/// These are always enabled, never conditionally greyed out: their
/// handlers are already no-op-safe (`PopDraft` refuses to drop below
/// one vertex, `CancelDraft` on an empty draft is a harmless reset,
/// `DeleteSelectedAnnotation` with no selection does nothing), and
/// that safety is pinned by tests in canvas_view_test.mbt rather than
/// by hiding the control. MoUI's `button` has no `disabled`
/// parameter, and whether `View::disabled()` participates in the
/// keyboard-shortcut dispatch path was not verifiable locally.
///
/// The `@views.frame` wrapper is the Phase 18.E clamp `mode_button`
/// uses: the dark theme's control metrics force an intrinsic button
/// height regardless of the `height` we pass. Measured on the smoke
/// capture, an unclamped row cost ~80 px of toolbar height and a
/// `height=24` clamp ~56.
///
/// `height=16` (the sidebar's row pitch) would cost only ~40 px, and
/// was tried — but it is a trap. `@views.frame` clamps the child's
/// *layout* box and does **not** clip its *paint*, so a 16-px frame
/// around a ~40-px-tall button lets the button paint straight down
/// into the canvas; `phase5_10_smoke_v4._window._window.png` shows
/// the three key chips sliced in half by the red image. Keep the
/// frame's height equal to the button's real painted height, or the
/// row overlaps the canvas below it.
fn shortcut_row(theme : @core.Theme) -> @moui.View[Msg] {
  let buttons : Array[@moui.View[Msg]] = []
  for spec in shortcut_specs() {
    buttons.push(
      @views.frame(
        @views.shortcut_button(
          spec.label,
          on_click=spec.msg,
          shortcut=@core.KeyboardShortcut::new(
            key=spec.key,
            modifiers=spec.modifiers,
          ),
          variant=@style.ButtonVariant::Ghost,
          theme~,
          width=spec.width,
          height=24.0,
          shortcut_width=48.0,
        ),
        width=spec.width,
        height=24.0,
      ),
    )
  }
  @views.row(buttons, spacing=4.0)
}

///|
/// Build folder-row widgets for the sidebar. Uses model.images
/// (populated by the ListImages op) when non-empty, else falls
/// back to a 4-item demo set so the cold-start screenshot has
/// content to render.
///
/// Phase 18.E — all four rows are real `@views.button` widgets
/// with `ButtonVariant::Ghost` (matches Moui's
/// `navigation_sidebar` pattern), each wrapped in a fixed
/// `@views.frame(width=180, height=16)` that clamps the
/// button's theme-driven intrinsic height back down to 16 px
/// so the sidebar's row pitch stays at 16 px. Phase 18.E wired
/// `FillRoundedRectBrush` + `StrokeRoundedRectBrush` into the
/// rasterizer (they were no-ops in Phase 11 / 18.B), so the
/// Ghost-variant background paints with the resolved brush
/// color and the label text reads against it.
///
/// Phase 5.17 — these rows now dispatch `SelectIndex(i)`. They were
/// `@views.button`s with **no `on_click` at all** from Phase 18.E
/// until now — rendered as pressable, doing nothing. 5.13 brought
/// them on screen for the first time (they had been clipped off the
/// bottom of the window since 5.1), so this is the same dead-control
/// problem 5.9 fixed for `[File]`, except that here the fix only
/// became visible two phases after the diagnosis.
fn sidebar_folder_rows(
  model : Model,
  theme : @core.Theme,
) -> Array[@moui.View[Msg]] {
  let folders : Array[String] = if model.images.length() > 0 {
    let names : Array[String] = []
    for img in model.images {
      names.push(img.name)
    }
    names
  } else {
    ["CARS.Part.01", "CARS.Body.01", "BAGS.Xray.01", "TNT.Lab.01"]
  }
  let rows : Array[@moui.View[Msg]] = []
  for i = 0; i < folders.length(); i = i + 1 {
    let index = i
    let folder = folders[i]
    rows.push(
      @views.frame(
        @views.button(
          "> " + folder,
          on_click=SelectIndex(index),
          theme~,
          variant=sidebar_row_variant(index == model.currentIndex),
          width=180.0,
          height=16.0,
        ),
        width=180.0,
        height=16.0,
      ),
    )
  }
  rows
}

/// Phase 5.17 — the highlight for a sidebar row.
///
/// Same shape as `mode_button_variant` (5.9), for the same reason: a
/// row that dispatches something must also *show* that it is the
/// current one, or the click has no visible result. `Primary` for the
/// current row, `Ghost` for the rest.
///
/// Split out as a pure function for the same reason too — a
/// Ghost-vs-Primary choice is not something a unit test can see until
/// it is a one-line boolean.
pub fn sidebar_row_variant(is_current : Bool) -> @style.ButtonVariant {
  if is_current {
    @style.ButtonVariant::Primary
  } else {
    @style.ButtonVariant::Ghost
  }
}

///|
/// Build class-row widgets. Uses model.classes if populated,
/// else a demo set. Phase 18.E — same Ghost-button pattern as
/// `sidebar_folder_rows` (real `@views.button` widgets inside
/// `@views.frame` to clamp the intrinsic height back to 16 px).
/// Phase 18.B had these as plain text because the button widget
/// was invisible (its `FillRoundedRectBrush` was a no-op).
///
/// Phase 5.17 — these rows now dispatch `SetActiveClass`, and the
/// active one is highlighted, or the click would have no visible
/// result.
///
/// **The row string is used as both the label and the class id**, and
/// that is not a simplification I chose for convenience — it is
/// forced by the current state of the app. `ScanClasses` is still a
/// no-op stub and nothing dispatches `ClassesLoaded`, so
/// `model.classes` is always empty at runtime and the demo fallback
/// below is the only reachable branch. A demo class has no
/// `ClassEntry` behind it, so its name *is* its id, and that stays
/// consistent end to end: `default_class_id` returns it, the
/// annotation records it, and `class_lookup_name` renders an
/// unresolvable `class_id` verbatim.
///
/// When `ScanClasses` is implemented, this needs one change: a real
/// `ClassEntry` carries `id` and `name` as separate fields, and the
/// annotation wants the **id**. Carrying both through would need a
/// second parallel array (or a record); a pair type was tried and
/// `Array[(String, String)]` does not resolve in this package.
fn sidebar_class_rows(
  model : Model,
  theme : @core.Theme,
) -> Array[@moui.View[Msg]] {
  let classes : Array[String] = if model.classes.length() > 0 {
    let names : Array[String] = []
    for cls in model.classes {
      names.push(cls.name)
    }
    names
  } else {
    ["knife", "gun", "batt", "liq", "botl", "bomb"]
  }
  let rows : Array[@moui.View[Msg]] = []
  for cls in classes {
    rows.push(
      @views.frame(
        @views.button(
          "# " + cls,
          on_click=SetActiveClass(cls),
          theme~,
          variant=sidebar_row_variant(cls == model.activeClassId),
          width=180.0,
          height=16.0,
        ),
        width=180.0,
        height=16.0,
      ),
    )
  }
  rows
}

///|
/// Map a class name to a ClassType enum. Phase 18.A's Model
/// exposes ClassType::{Object, Tag, Binding} (the three real
/// annotation kinds). The demo class names in the sidebar
/// (knife / gun / etc.) all map to Object for now — Phase 19
/// will extend ClassType with the per-class enum once the
/// labeler gains domain-specific class metadata.
fn parse_class_type(_name : String) -> ClassType {
  ClassType::Object
}

// ─────────────────────────────────────────────────────────────────
// Phase 16.C legacy API — kept verbatim for labeler_ui_test.mbt.
// Pixel assertions below depend on this exact command sequence;
// do not change the constants (sidebar_bg = (16,16,19), etc.)
// without also updating the tests.
// ─────────────────────────────────────────────────────────────────

///|
/// Build a labeler-style UI frame at the given pixel dimensions.
/// Returns a `DrawFrame` whose commands, when rasterized, draw:
///   +--------------------------------------+
///   |          Toolbar                      |  <- top, 40 px
///   +----------+-----------------------------+
///   |          |                             |
///   | Sidebar  |   Canvas area                |
///   | (200 px) |   (right of sidebar)         |
///   |          |                             |
///   +----------+-----------------------------+
pub fn build_labeler_ui_demo_frame(
  width : Int,
  height : Int,
) -> @core.DrawFrame {
  let commands : Array[@core.DrawCommand] = []
  let sidebar_w : Int = 200
  let toolbar_h : Int = 40
  let dark_bg : @core.Color = @core.Color::rgba(r=0.10, g=0.10, b=0.12, a=1.0)
  let sidebar_bg : @core.Color = @core.Color::rgba(
    r=0.16,
    g=0.16,
    b=0.19,
    a=1.0,
  )
  let toolbar_bg : @core.Color = @core.Color::rgba(
    r=0.22,
    g=0.22,
    b=0.26,
    a=1.0,
  )
  let divider : @core.Color = @core.Color::rgba(r=0.05, g=0.05, b=0.07, a=1.0)
  let folder_row : @core.Color = @core.Color::rgba(
    r=0.20,
    g=0.20,
    b=0.24,
    a=1.0,
  )
  let chip_bg : @core.Color = @core.Color::rgba(r=0.40, g=0.40, b=0.85, a=1.0)
  let tool_bg : @core.Color = @core.Color::rgba(r=0.30, g=0.30, b=0.34, a=1.0)
  let text_fg : @core.Color = @core.Color::rgba(r=0.95, g=0.95, b=0.95, a=1.0)
  let tool_fg : @core.Color = @core.Color::rgba(r=1.0, g=1.0, b=1.0, a=1.0)
  let font_12 : @core.FontSpec = @core.FontSpec::new(size=12.0)
  let font_10 : @core.FontSpec = @core.FontSpec::new(size=10.0)
  // 1. Canvas (full buffer) dark background.
  commands.push(
    @core.DrawCommand::FillRect(
      @core.Rect::new(
        x=0.0,
        y=0.0,
        width=width.to_double(),
        height=height.to_double(),
      ),
      dark_bg,
    ),
  )
  // 2. Toolbar background.
  commands.push(
    @core.DrawCommand::FillRect(
      @core.Rect::new(
        x=0.0,
        y=0.0,
        width=width.to_double(),
        height=toolbar_h.to_double(),
      ),
      toolbar_bg,
    ),
  )
  // 3. Sidebar background.
  commands.push(
    @core.DrawCommand::FillRect(
      @core.Rect::new(
        x=0.0,
        y=toolbar_h.to_double(),
        width=sidebar_w.to_double(),
        height=(height - toolbar_h).to_double(),
      ),
      sidebar_bg,
    ),
  )
  // 4. Toolbar/sidebar divider.
  commands.push(
    @core.DrawCommand::FillRect(
      @core.Rect::new(
        x=sidebar_w.to_double() - 1.0,
        y=toolbar_h.to_double(),
        width=1.0,
        height=(height - toolbar_h).to_double(),
      ),
      divider,
    ),
  )
  // 5. Toolbar/canvas divider.
  commands.push(
    @core.DrawCommand::FillRect(
      @core.Rect::new(
        x=0.0,
        y=toolbar_h.to_double() - 1.0,
        width=width.to_double(),
        height=1.0,
      ),
      divider,
    ),
  )
  // 6. Four tool buttons.
  let tool_labels : Array[String] = ["R", "S", "P", "D"]
  let mut i : Int = 0
  while i < tool_labels.length() {
    let x : Int = 8 + i * 40
    commands.push(
      @core.DrawCommand::FillRoundedRect(
        @core.RoundedRect::new(
          rect=@core.Rect::new(x=x.to_double(), y=4.0, width=32.0, height=32.0),
          radius=6.0,
        ),
        tool_bg,
      ),
    )
    commands.push(
      @core.DrawCommand::DrawText(
        @core.TextRun::new(
          text=tool_labels[i],
          frame=@core.Rect::new(
            x=(x + 13).to_double(),
            y=14.0,
            width=8.0,
            height=12.0,
          ),
          font=font_12,
          color=tool_fg,
        ),
      ),
    )
    i = i + 1
  }
  // 7. Folder rows.
  let folder_names : Array[String] = [
    "CARS.Part", "CARS.Body", "BAGS.Xray", "TNT.Lab",
  ]
  let mut fi : Int = 0
  while fi < folder_names.length() {
    let fy : Int = toolbar_h + 30 + fi * 22
    commands.push(
      @core.DrawCommand::FillRect(
        @core.Rect::new(
          x=8.0,
          y=fy.to_double(),
          width=(sidebar_w - 16).to_double(),
          height=18.0,
        ),
        folder_row,
      ),
    )
    commands.push(
      @core.DrawCommand::DrawText(
        @core.TextRun::new(
          text=folder_names[fi],
          frame=@core.Rect::new(
            x=12.0,
            y=(fy + 5).to_double(),
            width=(sidebar_w - 24).to_double(),
            height=10.0,
          ),
          font=font_10,
          color=text_fg,
        ),
      ),
    )
    fi = fi + 1
  }
  // 8. Class chips.
  let chip_y_start : Int = toolbar_h + 130
  commands.push(
    @core.DrawCommand::DrawText(
      @core.TextRun::new(
        text="Classes",
        frame=@core.Rect::new(
          x=12.0,
          y=(chip_y_start - 16).to_double(),
          width=80.0,
          height=10.0,
        ),
        font=font_10,
        color=text_fg,
      ),
    ),
  )
  let chip_names : Array[String] = [
    "knife", "gun", "batt", "liq", "botl", "bomb",
  ]
  let mut ci : Int = 0
  while ci < chip_names.length() {
    let cy : Int = chip_y_start + ci * 20
    commands.push(
      @core.DrawCommand::FillRoundedRect(
        @core.RoundedRect::new(
          rect=@core.Rect::new(
            x=8.0,
            y=cy.to_double(),
            width=(sidebar_w - 16).to_double(),
            height=18.0,
          ),
          radius=4.0,
        ),
        chip_bg,
      ),
    )
    commands.push(
      @core.DrawCommand::DrawText(
        @core.TextRun::new(
          text=chip_names[ci],
          frame=@core.Rect::new(
            x=14.0,
            y=(cy + 5).to_double(),
            width=(sidebar_w - 24).to_double(),
            height=10.0,
          ),
          font=font_10,
          color=tool_fg,
        ),
      ),
    )
    ci = ci + 1
  }
  // 9. Decorative bezier in the canvas area.
  let canvas_right : Double = width.to_double()
  let path : @core.PathSpec = @core.PathSpec::new(
    verbs=[
      @core.PathVerb::MoveTo(
        @core.Point::new(x=canvas_right - 60.0, y=(toolbar_h + 10).to_double()),
      ),
      @core.PathVerb::CubicTo(
        @core.Point::new(x=canvas_right - 20.0, y=(toolbar_h + 5).to_double()),
        @core.Point::new(x=canvas_right - 5.0, y=(toolbar_h + 30).to_double()),
        @core.Point::new(x=canvas_right - 40.0, y=(toolbar_h + 40).to_double()),
      ),
      @core.PathVerb::LineTo(
        @core.Point::new(x=canvas_right - 60.0, y=(toolbar_h + 40).to_double()),
      ),
      @core.PathVerb::Close,
    ],
    fill=Some(@core.Brush::solid(tool_fg)),
  )
  commands.push(@core.DrawCommand::DrawPath(path))
  @core.DrawFrame::new(
    commands~,
    damage=@core.DamageRegion::empty(),
    clear_color=dark_bg,
  )
}
