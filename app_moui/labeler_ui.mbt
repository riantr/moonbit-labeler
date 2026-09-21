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
      @views.row(
        [
          @views.text(
            "MoonBit Labeler",
            theme=dark_theme,
            role=@style.TextRole::Title,
            width=200.0,
            height=24.0,
          ),
          @views.text(
            "Folder: " + model.folder,
            theme=dark_theme,
            role=@style.TextRole::Body,
            width=320.0,
            height=24.0,
          ),
        ],
        spacing=8.0,
      ),
      // Nav row: mode labels (text only, Phase 18.C → buttons).
      @views.row(
        [
          @views.text(
            "[File]", theme=dark_theme, role=@style.TextRole::Body,
            width=64.0, height=24.0,
          ),
          @views.text(
            "[Rect]", theme=dark_theme, role=@style.TextRole::Body,
            width=64.0, height=24.0,
          ),
          @views.text(
            "[Polygon]", theme=dark_theme, role=@style.TextRole::Body,
            width=80.0, height=24.0,
          ),
          @views.text(
            "[Keypoint]", theme=dark_theme, role=@style.TextRole::Body,
            width=88.0, height=24.0,
          ),
          @views.text(
            "[Binding]", theme=dark_theme, role=@style.TextRole::Body,
            width=80.0, height=24.0,
          ),
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
    ],
    spacing=4.0,
  )
  // ─── Sidebar (left column) ───
  // Phase 18.B — folder rows + class chips are `@views.text`
  // widgets, not `@views.button`, for the same reason as the
  // toolbar (button's intrinsic height overflows). Each row is
  // a `text` showing the folder/class name prefixed with `>`
  // to evoke a selectable row. Real button widgets return in
  // Phase 18.C.
  let sidebar : @moui.View[Msg] = @views.column(
    [
      @views.text(
        "Folders",
        theme=dark_theme,
        role=@style.TextRole::Title,
        width=180.0,
        height=24.0,
      ),
      @views.column(
        sidebar_folder_rows(model, dark_theme),
        spacing=2.0,
      ),
      @views.text(
        "Classes",
        theme=dark_theme,
        role=@style.TextRole::Title,
        width=180.0,
        height=24.0,
      ),
      @views.column(
        sidebar_class_rows(model, dark_theme),
        spacing=1.0,
      ),
    ],
    spacing=6.0,
  )
  // ─── Canvas (right area, custom paint) ───
  // ─── Canvas placeholder ───
  // Phase 18.B — single text widget, explicit width/height.
  // Phase 18.C will replace this with the `@views.canvas` +
  // bezier decoration. For now the text is enough to prove
  // the row's layout (sidebar | canvas) works end-to-end.
  // Height is bounded by the sidebar's intrinsic so the row
  // doesn't claim more vertical space than it needs.
  let canvas : @moui.View[Msg] = @views.text(
    "[canvas area]",
    theme=dark_theme,
    role=@style.TextRole::Body,
    width=600.0,
    height=120.0,
  )
  // ─── Bottom status bar ───
  let status_text : String = match model.toastMessage {
    Some(msg) => msg
    None => model.statusMessage
  }
  let status_bar : @moui.View[Msg] = @views.row(
    [
      @views.text(
        status_text,
        theme=dark_theme,
        role=@style.TextRole::Body,
        width=400.0,
        height=16.0,
      ),
    ],
    spacing=8.0,
  )
  // ─── Compose ───
  // Outer column:
  //   1. toolbar (fixed height ~74)
  //   2. main row: sidebar (192 wide) + canvas (fills the rest)
  //      The row's intrinsic height = max(sidebar_h, canvas_h)
  //      = sidebar_h ≈ 304 px (Phase 18.B sees ~304 px because
  //      sidebar has Folders header + 4 buttons + Classes header
  //      + 6 chip wrap rows).
  //   3. status bar (~20 tall)
  // No spacer, no flex_weight — the children stack at their
  // intrinsic sizes. If the window is taller than the sum, the
  // leftover space appears at the bottom of the column.
  @views.column(
    [
      toolbar,
      @views.row([sidebar, canvas], spacing=0.0),
      status_bar,
    ],
    spacing=0.0,
  )
}

///|
/// Build folder-row text widgets for the sidebar. Uses model.images
/// (populated by the ListImages op) when non-empty, else falls
/// back to a 4-item demo set so the cold-start screenshot has
/// content to render. Phase 18.B — switched from `@views.button`
/// to `@views.text` because the button widget's intrinsic height
/// is theme-driven (font_size + 2×sm_padding) and overflows the
/// explicit `height=` we pass. Text widgets honor the height=24
/// we pass and don't add theme padding. Each row is prefixed with
/// "> " to evoke a selectable list item. Real button widgets
/// return in Phase 18.C.
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
      @views.text(
        "> " + folder,
        theme~,
        role=@style.TextRole::Body,
        width=180.0,
        height=12.0,
      ),
    )
  }
  rows
}

///|
/// Build class-row text widgets. Uses model.classes if populated,
/// else a demo set. Phase 18.B — same text-widget rationale as
/// sidebar_folder_rows (button widget's intrinsic height is
/// theme-driven and overflows the height=24 we pass).
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
      @views.text(
        "# " + cls,
        theme~,
        role=@style.TextRole::Body,
        width=180.0,
        height=12.0,
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

///|
/// Paint the canvas-area decoration. Phase 18.B — paint the
/// allocated `frame` in a DEBUG bright color so we can see
/// exactly where the canvas ended up in the layout. Phase 18.C
/// will switch back to dark-slate + bezier swoop.
fn paint_canvas_decoration(
  pctx : @common.PaintContext,
  frame : @core.Rect,
) -> Unit {
  // Phase 18.B debug — bright cyan so the canvas's footprint
  // is unmistakable in the smoke screenshot.
  @common.fill_rect(
    pctx,
    frame,
    @core.Color::rgba(r=0.0, g=1.0, b=1.0, a=1.0),
  )
  let right : Double = frame.origin.x + frame.size.width
  let top : Double = frame.origin.y
  let path : @core.PathSpec = @core.PathSpec::new(
    verbs=[
      @core.PathVerb::MoveTo(
        @core.Point::new(x=right - 60.0, y=top + 10.0),
      ),
      @core.PathVerb::CubicTo(
        @core.Point::new(x=right - 20.0, y=top + 5.0),
        @core.Point::new(x=right - 5.0, y=top + 30.0),
        @core.Point::new(x=right - 40.0, y=top + 40.0),
      ),
      @core.PathVerb::LineTo(
        @core.Point::new(x=right - 60.0, y=top + 40.0),
      ),
      @core.PathVerb::Close,
    ],
    fill=Some(
      @core.Brush::solid(@core.Color::rgba(r=1.0, g=1.0, b=1.0, a=1.0)),
    ),
  )
  @common.draw_path(pctx, path)
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
  let sidebar_bg : @core.Color = @core.Color::rgba(r=0.16, g=0.16, b=0.19, a=1.0)
  let toolbar_bg : @core.Color = @core.Color::rgba(r=0.22, g=0.22, b=0.26, a=1.0)
  let divider : @core.Color = @core.Color::rgba(r=0.05, g=0.05, b=0.07, a=1.0)
  let folder_row : @core.Color = @core.Color::rgba(r=0.20, g=0.20, b=0.24, a=1.0)
  let chip_bg : @core.Color = @core.Color::rgba(r=0.40, g=0.40, b=0.85, a=1.0)
  let tool_bg : @core.Color = @core.Color::rgba(r=0.30, g=0.30, b=0.34, a=1.0)
  let text_fg : @core.Color = @core.Color::rgba(r=0.95, g=0.95, b=0.95, a=1.0)
  let tool_fg : @core.Color = @core.Color::rgba(r=1.0, g=1.0, b=1.0, a=1.0)
  let font_12 : @core.FontSpec = @core.FontSpec::new(size=12.0)
  let font_10 : @core.FontSpec = @core.FontSpec::new(size=10.0)
  // 1. Canvas (full buffer) dark background.
  commands.push(
    @core.DrawCommand::FillRect(
      @core.Rect::new(x=0.0, y=0.0, width=width.to_double(), height=height.to_double()),
      dark_bg,
    ),
  )
  // 2. Toolbar background.
  commands.push(
    @core.DrawCommand::FillRect(
      @core.Rect::new(x=0.0, y=0.0, width=width.to_double(), height=toolbar_h.to_double()),
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
  let folder_names : Array[String] = ["CARS.Part", "CARS.Body", "BAGS.Xray", "TNT.Lab"]
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
  let chip_names : Array[String] = ["knife", "gun", "batt", "liq", "botl", "bomb"]
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
      @core.PathVerb::MoveTo(@core.Point::new(x=canvas_right - 60.0, y=(toolbar_h + 10).to_double())),
      @core.PathVerb::CubicTo(
        @core.Point::new(x=canvas_right - 20.0, y=(toolbar_h + 5).to_double()),
        @core.Point::new(x=canvas_right - 5.0, y=(toolbar_h + 30).to_double()),
        @core.Point::new(x=canvas_right - 40.0, y=(toolbar_h + 40).to_double()),
      ),
      @core.PathVerb::LineTo(@core.Point::new(x=canvas_right - 60.0, y=(toolbar_h + 40).to_double())),
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
