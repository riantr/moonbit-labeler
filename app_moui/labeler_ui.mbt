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
  let _ : Double = width
  let _ : Double = height
  // Phase 18.A — dark theme. The runtime's default `Environment`
  // carries a light ColorScheme, which makes `@views.text` and
  // `@views.button` paint dark foreground on the dark slate
  // background we use — illegible. We pass a custom Theme to
  // every text/button so the foreground is near-white. Theme
  // is module-local: cheap to construct, no mutation needed.
  let dark_theme : @core.Theme = @core.Theme::neutral().with_palette(
    @core.ColorPalette::dark(),
  )
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
          mode_button(model, Mode::Select, dark_theme, 72.0),
          mode_button(model, Mode::Rect, dark_theme, 64.0),
          mode_button(model, Mode::Polygon, dark_theme, 80.0),
          mode_button(model, Mode::Keypoint, dark_theme, 88.0),
          mode_button(model, Mode::EditBinding, dark_theme, 80.0),
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
      shortcut_row(dark_theme),
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
      @views.column(sidebar_folder_rows(model, dark_theme), spacing=2.0),
      @views.text(
        "Classes",
        theme=dark_theme,
        role=@style.TextRole::Title,
        width=180.0,
        height=32.0,
      ),
      @views.column(sidebar_class_rows(model, dark_theme), spacing=1.0),
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
  let canvas : @moui.View[Msg] = canvas_view(model)
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
  // letters. Status bar row's intrinsic height = max of children
  // = 24 px (was 16). This eats 8 more px from the outer
  // column, leaving less for the spacer to absorb.
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
  // Outer column:
  //   1. toolbar (fixed height ~72 — header 32 + nav 24 + spacing)
  //   2. SPACER with flex_weight=1 (Phase 20) — claims all leftover
  //      vertical space so the status bar always sits flush at the
  //      window bottom regardless of sidebar/canvas intrinsic sizes.
  //      Phase 18.B had no spacer; when toolbar + main_row + status_bar
  //      summed past window_h the status bar got clipped off-screen.
  //   3. main row: sidebar (192 wide) + canvas (fills the rest)
  //      The row's intrinsic height = max(sidebar_h, canvas_h).
  //      Sidebar drives it (~248 px: header 32 + 4×16 + spacing +
  //      header 32 + 6×16 + spacing).
  //   4. status bar (~16 tall)
  // The spacer pushes the row to the top and the status bar to the
  // bottom — a classic 3-region fixed-bottom layout.
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
  for folder in folders {
    rows.push(
      @views.frame(
        @views.button(
          "> " + folder,
          theme~,
          variant=@style.ButtonVariant::Ghost,
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
/// Build class-row widgets. Uses model.classes if populated,
/// else a demo set. Phase 18.E — same Ghost-button pattern as
/// `sidebar_folder_rows` (real `@views.button` widgets inside
/// `@views.frame` to clamp the intrinsic height back to 16 px).
/// Phase 18.B had these as plain text because the button widget
/// was invisible (its `FillRoundedRectBrush` was a no-op).
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
          theme~,
          variant=@style.ButtonVariant::Ghost,
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
