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
/// Phase 18.A — build the labeler UI as a Moui view tree.
///
/// `width` / `height` are the initial layout constraints for the
/// whole tree. Moui's flex layout distributes the size among the
/// children according to the column / row splits below. Pixel
/// offsets come from the layout system, not from absolute math,
/// so the UI rescales to whatever window size the runtime gives
/// us.
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
  // ─── Toolbar (top column: header row + nav row) ───
  let toolbar : @moui.View[Msg] = @views.column(
    [
      // Top header: title + folder picker hint + Load button.
      @views.row(
        [
          @views.text("MoonBit Labeler", theme=dark_theme, width=200.0, height=32.0),
          @views.text(
            "Folder: " + model.folder,
            theme=dark_theme,
            role=@style.TextRole::Body,
            width=240.0,
            height=32.0,
          ),
          @views.button("Load", theme=dark_theme, on_click=LoadFolder(model.folder)),
        ],
        spacing=8.0,
      ),
      // Nav row: five items + zoom display. Mode has the
      // variants {Select, Rect, Polygon, Keypoint, EditBinding};
      // map each toolbar button to the closest meaningful Mode.
      @views.row(
        [
          @views.button("File", theme=dark_theme, on_click=SetMode(Mode::Select)),
          @views.button("Rect", theme=dark_theme, on_click=SetMode(Mode::Rect)),
          @views.button("Polygon", theme=dark_theme, on_click=SetMode(Mode::Polygon)),
          @views.button("Keypoint", theme=dark_theme, on_click=SetMode(Mode::Keypoint)),
          @views.button("Binding", theme=dark_theme, on_click=SetMode(Mode::EditBinding)),
          @views.text(
            (model.zoom * 100.0).to_string() + "%",
            theme=dark_theme,
            width=80.0,
            height=24.0,
          ),
        ],
        spacing=4.0,
      ),
    ],
    spacing=2.0,
  )
  // ─── Sidebar (left column) ───
  let sidebar : @moui.View[Msg] = @views.column(
    [
      @views.text("Folders", theme=dark_theme, width=180.0, height=24.0),
      @views.column(sidebar_folder_buttons(model, dark_theme), spacing=4.0),
      @views.text("Classes", theme=dark_theme, width=180.0, height=24.0),
      @views.column(sidebar_class_buttons(model, dark_theme), spacing=4.0),
    ],
    spacing=8.0,
  )
  // ─── Canvas (right area, custom paint) ───
  let canvas : @moui.View[Msg] = @views.canvas(
    measure=fn(constraints) { constraints.max },
    draw=fn(pctx, frame) { paint_canvas_decoration(pctx, frame) },
  )
  // ─── Bottom status bar ───
  let status_text : String = match model.toastMessage {
    Some(msg) => msg
    None => model.statusMessage
  }
  let status_bar : @moui.View[Msg] = @views.row(
    [
      @views.text(status_text, theme=dark_theme, width=600.0, height=24.0),
    ],
    spacing=8.0,
  )
  // ─── Compose ───
  @views.column(
    [
      toolbar,
      @views.row([sidebar, canvas], spacing=0.0),
      status_bar,
    ],
    spacing=4.0,
  )
}

///|
/// Build folder-row buttons for the sidebar. Uses model.images
/// (populated by the ListImages op) when non-empty, else falls
/// back to a 4-item demo set so the cold-start screenshot has
/// content to render.
fn sidebar_folder_buttons(
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
  let buttons : Array[@moui.View[Msg]] = []
  for folder in folders {
    buttons.push(
      @views.button(
        folder,
        theme~,
        on_click=LoadFolder(folder),
        width=180.0,
        height=24.0,
      ),
    )
  }
  buttons
}

///|
/// Build class-chip buttons. Uses model.classes if populated, else
/// a demo set.
fn sidebar_class_buttons(
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
  let buttons : Array[@moui.View[Msg]] = []
  for cls in classes {
    buttons.push(
      @views.button(
        cls,
        theme~,
        on_click=SetClassType(parse_class_type(cls)),
        width=180.0,
        height=24.0,
      ),
    )
  }
  buttons
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
/// Paint the canvas-area decoration: dark background fill plus a
/// decorative bezier swoop in the top-right corner. Phase 16.A's
/// De Casteljau (via DrawPath which rasterize_draw_frame flattens)
/// produces the bezier; Phase 16.C's curve geometry is preserved.
fn paint_canvas_decoration(
  pctx : @common.PaintContext,
  frame : @core.Rect,
) -> Unit {
  @common.fill_rect(
    pctx,
    frame,
    @core.Color::rgba(r=0.10, g=0.10, b=0.12, a=1.0),
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
