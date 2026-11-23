///|
/// `UiTabs`——自绘页签条（`T351`）。
///
/// 与 `UiSegmented` 共用一套条带机制（量格子、命中、悬停、按下），只换画法：
/// 页签不铺凹槽底，而是一整条底线加选中项下面的一段主色指示条。这是"页签"
/// 与"分段选择"在视觉上的分工——前者表示"看到的是哪一页"，后者表示"选了哪个
/// 值"，同一套交互不该用同一张脸。
///
/// 只做**页签头**：内容由调用方在 `on_change` 里换（`Window::set_content` 或
/// 换一张子树），与 `Tabs` 组件（`components.mbt`）同一条分工——组件层不给
/// 页签头画蛇添足地建一棵内容树，因为内容该怎么建只有应用知道。
///
/// 左右方向键换页（`T357`）：与分段控件共用 `ui_strip_watch`，首尾环绕。

///|
/// 自绘页签条。
pub struct UiTabs[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : StripState
}

///|
/// 页签的格子内缩：14 比分段控件宽，因为页签之间没有凹槽，全靠留白分隔。
fn[B : @moonui.Backend] ui_tabs_size(
  backend : B,
  titles : Array[String],
  metrics : UiMetrics,
) -> (Array[UiStripCell], Double) {
  ui_strip_cells(backend, titles, metrics.font, 14.0, 0.0)
}

///|
/// 画页签条：一条底线 + 每个标题 + 选中项下面那条 2px 的主色。
fn ui_paint_tabs(
  st : StripState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let t = st.theme
  // 底线：整条宽度铺满，选中项的主色条压在它上面——没有这条线，页签头与
  // 内容之间就没有"分界"这件事可言
  let base_y = h - 1.0
  dl.line(0.0, base_y, w, base_y, width=1.0, rgb=t.border)
  for i, cell in st.cells {
    let x = st.outer + cell.start
    let picked = st.selected == i
    let fg = if picked {
      t.text
    } else {
      ui_mix(
        t.text_muted,
        t.text,
        if st.hover == i {
          st.it.hover_amt
        } else {
          0.0
        },
      )
    }
    // 文字在底线之上居中：高度取 h - 2（留出底线那 2px）
    ui_paint_center_text(
      dl,
      env,
      st.titles[i],
      x,
      0.0,
      cell.width,
      h - 2.0,
      st.metrics.font,
      picked,
      fg,
    )
    if picked {
      // 指示条两端各内缩 10，不长不短地"托住"标题——与标题同宽会显得像下划线
      let bar_w = cell.width - 20.0
      if bar_w > 4.0 {
        ui_paint_fill(
          dl,
          x + 10.0,
          h - 2.0,
          bar_w,
          2.0,
          1.0,
          if st.it.enabled {
            t.accent
          } else {
            t.text_disabled
          },
        )
      }
    }
  }
  if st.it.focused {
    ui_paint_focus_ring(dl, 0.0, 0.0, w, h, st.metrics.radius, t.focus_ring)
  }
}

///|
/// 造一个页签条。`selected` 越界夹到 0。
pub fn[B : @moonui.Backend] UiTabs::UiTabs(
  backend : B,
  titles : Array[String],
  selected~ : Int32 = 0,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
  app~ : @moonui.App[B]? = None,
) -> UiTabs[B] raise @moonui.UiError {
  if titles.length() == 0 {
    raise @moonui.OperationFailed("页签条的标题不能为空")
  }
  let metrics = theme.metrics(size)
  let (cells, total) = ui_tabs_size(backend, titles, metrics)
  let init = if selected < 0 {
    0
  } else if selected >= titles.length() {
    titles.length() - 1
  } else {
    selected
  }
  let state = StripState::{
    theme,
    size,
    metrics,
    titles,
    cells,
    outer: 0.0,
    selected: init,
    hover: -1,
    press: -1,
    it: UiInteract::new(),
    handler: None,
  }
  let widget = @moonui.Widget::custom(
    backend,
    @moonui.LogicalSize(total, metrics.height),
    fn(dl, env) { ui_paint_tabs(state, dl, env) },
    focusable=true,
  )
  ui_watch_state(widget, state.it, app~)
  ui_strip_watch(widget, state)
  { backend, widget, state, }
}

///|
/// 页签条本身（挂进 Column 的头部）。
pub fn[B] UiTabs::view(self : UiTabs[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
pub fn[B] UiTabs::selected(self : UiTabs[B]) -> Int32 {
  self.state.selected
}

///|
pub fn[B] UiTabs::on_change(
  self : UiTabs[B],
  f : (Int32) -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
/// 程序设值：夹到合法下标，重画，不触发 `on_change`。
pub fn[B : @moonui.Backend] UiTabs::set_selected(
  self : UiTabs[B],
  index : Int32,
) -> Unit raise @moonui.UiError {
  let n = self.state.titles.length()
  let i = if index < 0 { 0 } else if index >= n { n - 1 } else { index }
  if self.state.selected == i {
    return
  }
  self.state.selected = i
  self.widget.repaint()
}

///|
/// 换整套令牌：与分段控件共用 `StripState`，所以格子表也得跟着字号重算。
pub fn[B : @moonui.Backend] UiTabs::set_theme(
  self : UiTabs[B],
  theme : UiTheme,
) -> Unit raise @moonui.UiError {
  self.state.theme = theme
  self.state.metrics = theme.metrics(self.state.size)
  let (cells, total) = ui_tabs_size(
    self.backend,
    self.state.titles,
    self.state.metrics,
  )
  self.state.cells = cells
  self.widget.set_custom_size(
    @moonui.LogicalSize(total, self.state.metrics.height),
  )
  self.widget.repaint()
}
