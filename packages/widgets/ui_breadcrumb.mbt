///|
/// `UiBreadcrumb`——自绘面包屑（`T360` 第三档）。
///
/// 原生控件里没有面包屑：它是一行"路径 + 分隔符"的字，拿 Label 拼也行，但拼接
/// 的每段要各挑各的灰、分隔符要对齐、当前项要加粗——这些每处都得重来一遍。
/// 自绘之后它是一个控件：项表进来，分隔符、间距、当前项加粗、命中区全由它管。
///
/// 宽度按内容量出来（项宽 + 分隔符宽 + 两侧 6px），不是靠调用方给——面包屑
/// 的长度就是路径的长度，写死宽度只会在长路径上截字。
///
/// 最后一项是"当前页"：加粗、用正文色，其余用次级色。点任意一项回调
/// `on_select(index)`（当前项也回调——"回到当前层"通常是刷新，允许）。

///|
/// 面包屑的账：项表、每项量出来的宽、分隔符宽。
struct CrumbState {
  mut theme : UiTheme
  size : UiSize
  mut metrics : UiMetrics
  mut items : Array[String]
  /// 每项的度量宽（构造与 `set_items` 时算一次；字体不变就不会变）
  mut widths : Array[Double]
  /// 分隔符 "/" 的度量宽
  mut sep_w : Double
  /// 项与分隔符之间的空隙
  gap : Double
  mut handler : ((Int32) -> Unit raise @moonui.UiError)?
}

///|
/// 自绘面包屑。
pub struct UiBreadcrumb[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : CrumbState
}

///|
/// 项与分隔符之间的空隙。
const UI_CRUMB_GAP : Double = 6.0

///|
/// 一行的垂直留白（上下各 4）。
fn ui_crumb_height(st : CrumbState) -> Double {
  st.metrics.font * 1.45 + 8.0
}

///|
/// 量一遍所有项与分隔符。最后一项按粗体量——它就是要加粗的那一段，用常规字
/// 量出来的宽会让它在绘制时比预留位置更宽，尾部被裁掉一截。
fn[B : @moonui.Backend] ui_crumb_measure(backend : B, st : CrumbState) -> Unit {
  let n = st.items.length()
  let widths : Array[Double] = []
  let mut i = 0
  while i < n {
    let bold = i == n - 1
    let (w, _) = ui_measure(backend, st.items[i], st.metrics.font, bold)
    widths.push(w)
    i = i + 1
  }
  st.widths = widths
  let (sw, _) = ui_measure(backend, "/", st.metrics.font, false)
  st.sep_w = sw
}

///|
/// 每项的起始 x 与宽（与绘制同一套算术，命中区直接复用）。
fn ui_crumb_xs(st : CrumbState) -> Array[(Double, Double)] {
  let out : Array[(Double, Double)] = []
  let n = st.items.length()
  let mut x = 0.0
  let mut i = 0
  while i < n {
    out.push((x, st.widths[i]))
    x = x + st.widths[i]
    if i < n - 1 {
      x = x + st.gap + st.sep_w + st.gap
    }
    i = i + 1
  }
  out
}

///|
/// 固有宽：最后一项的右边界。
fn ui_crumb_width(st : CrumbState) -> Double {
  let xs = ui_crumb_xs(st)
  if xs.length() == 0 {
    return 0.0
  }
  let (x, w) = xs[xs.length() - 1]
  let total = x + w
  if total < 16.0 {
    16.0
  } else {
    total
  }
}

///|
/// 画一行路径：项 + 分隔符。底不画（露父容器），这也是面包屑该有的样子。
fn ui_paint_crumb(
  st : CrumbState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let t = st.theme
  let xs = ui_crumb_xs(st)
  let n = st.items.length()
  let line = st.metrics.font * 1.45
  let y = (h - line) / 2.0
  let mut i = 0
  while i < n {
    let (x, iw) = xs[i]
    let last = i == n - 1
    ui_paint_line_text(
      dl,
      env,
      st.items[i],
      x,
      y,
      iw + 1.0,
      line,
      st.metrics.font,
      last,
      if last {
        t.text
      } else {
        t.text_muted
      },
    )
    if !last {
      let sx = x + iw + st.gap
      ui_paint_line_text(
        dl,
        env,
        "/",
        sx,
        y,
        st.sep_w + 1.0,
        line,
        st.metrics.font,
        false,
        t.text_disabled,
      )
    }
    i = i + 1
  }
}

///|
/// 指针 → 项号（落在空隙里也给最近的那一项？不给：返回 -1，点空白不算）。
fn[B] ui_crumb_hit(
  w : @moonui.Widget[B],
  st : CrumbState,
  p : @moonui.LogicalPoint,
) -> Int32 {
  let x = p.x - w.frame().origin.x
  let xs = ui_crumb_xs(st)
  let mut i = 0
  while i < xs.length() {
    let (sx, iw) = xs[i]
    if x >= sx && x <= sx + iw {
      return i
    }
    i = i + 1
  }
  -1
}

///|
/// 造一行面包屑。`items` 至少一项；最后一项是当前页。
pub fn[B : @moonui.Backend] UiBreadcrumb::UiBreadcrumb(
  backend : B,
  items : Array[String],
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
) -> UiBreadcrumb[B] raise @moonui.UiError {
  let metrics = theme.metrics(size)
  let state = CrumbState::{
    theme,
    size,
    metrics,
    items,
    widths: [],
    sep_w: 0.0,
    gap: UI_CRUMB_GAP,
    handler: None,
  }
  ui_crumb_measure(backend, state)
  let widget = @moonui.Widget::custom(
    backend,
    @moonui.LogicalSize(ui_crumb_width(state), ui_crumb_height(state)),
    fn(dl, env) { ui_paint_crumb(state, dl, env) },
    focusable=true,
  )
  let _ = widget.on(
    fn(e) {
      match e {
        @moonui.MouseUp(_, @moonui.Left, _, _) => true
        _ => false
      }
    },
    fn(e) raise @moonui.UiError {
      match e {
        @moonui.MouseUp(_, _, p, _) => {
          let idx = ui_crumb_hit(widget, state, p)
          if idx >= 0 {
            match state.handler {
              Some(f) => f(idx)
              None => ()
            }
          }
        }
        _ => ()
      }
    },
  )
  { backend, widget, state, }
}

///|
pub fn[B] UiBreadcrumb::widget(self : UiBreadcrumb[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
/// 当下项数。
pub fn[B] UiBreadcrumb::count(self : UiBreadcrumb[B]) -> Int32 {
  self.state.items.length()
}

///|
/// 某一项的文字（越界给空串）。
pub fn[B] UiBreadcrumb::item(self : UiBreadcrumb[B], index : Int32) -> String {
  if index < 0 || index >= self.state.items.length() {
    ""
  } else {
    self.state.items[index]
  }
}

///|
/// 换整套项表：重算每项宽度与整体宽高。
pub fn[B : @moonui.Backend] UiBreadcrumb::set_items(
  self : UiBreadcrumb[B],
  items : Array[String],
) -> Unit raise @moonui.UiError {
  self.state.items = items
  ui_crumb_measure(self.backend, self.state)
  self.widget.set_custom_size(
    @moonui.LogicalSize(ui_crumb_width(self.state), ui_crumb_height(self.state)),
  )
  self.widget.repaint()
}

///|
/// 某一项被点时的回调。
pub fn[B] UiBreadcrumb::on_select(
  self : UiBreadcrumb[B],
  f : (Int32) -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
/// 换令牌：字号变了每项宽度与行高都要重量。
pub fn[B : @moonui.Backend] UiBreadcrumb::set_theme(
  self : UiBreadcrumb[B],
  theme : UiTheme,
) -> Unit raise @moonui.UiError {
  self.state.theme = theme
  self.state.metrics = theme.metrics(self.state.size)
  ui_crumb_measure(self.backend, self.state)
  self.widget.set_custom_size(
    @moonui.LogicalSize(ui_crumb_width(self.state), ui_crumb_height(self.state)),
  )
  self.widget.repaint()
}
