///|
/// `UiSegmented`——分段控件（`T351`），以及它与 `UiTabs` 共用的"横向条带"机制。
///
/// 为什么这两只要共用一套底：分段控件与页签在交互上是同一件事——一排可点的
/// 格子、有一个选中、按下去松手在同一个格子里才算数。差别只在"选中长什么样"：
/// 分段把选中的格子抬成一块白底（iOS 的分段控件），页签在选中项下面画一条
/// 主色指示条。把"量格子 / 命中哪一格 / 悬停在哪一格 / 按下在哪一格"收在一处，
/// 两边的画法各写十来行就够了；分开写就要把同一套坐标算术抄两遍，改一处漏
/// 一处（`text_fit.mbt` 段注里那条教训）。
///
/// 坐标：`MouseDown`/`MouseMove` 的点是**父局部**的（Core 的鼠标事件一律如此），
/// 命中前要减掉控件自己的 `frame().origin`——与 `DataGrid` 同一条换算。

///|
/// 条带里的一格：起点（控件局部 x）与宽。宽在建树时按文案量好，之后不动
/// （标题是结构的一部分，与 `Tabs` 组件"换页重建整棵树"同一条口径）。
priv struct UiStripCell {
  start : Double
  width : Double
}

///|
/// 条带的共享账：格子表 + 选中下标 + 悬停/按下格 + 事件处理器。
///
/// `hover`/`press` 用 `-1` 表示"不在任何格子上"（指针在条带的留白里或已经
/// 离开），不用 `Option`：`-1` 与合法下标同一类型，判起来少一层嵌套。
struct StripState {
  theme : UiTheme
  metrics : UiMetrics
  titles : Array[String]
  cells : Array[UiStripCell]
  /// 条带两侧的留白（分段控件是 3，页签是 0）
  outer : Double
  mut selected : Int32
  mut hover : Int32
  mut press : Int32
  it : UiInteract
  mut handler : ((Int32) -> Unit raise @moonui.UiError)?
}

///|
/// 按文案量一排格子：每格宽 = 字宽 + 两侧内缩，且不小于 `min_cell`。
/// 返回格子表与总宽（不含两侧留白）。
fn[B : @moonui.Backend] ui_strip_cells(
  backend : B,
  titles : Array[String],
  font : Double,
  cell_pad : Double,
  min_cell : Double,
) -> (Array[UiStripCell], Double) {
  let cells : Array[UiStripCell] = []
  let mut x = 0.0
  for t in titles {
    let (tw, _) = ui_measure(backend, t, font, false)
    let mut cw = tw + cell_pad * 2.0
    if cw < min_cell {
      cw = min_cell
    }
    cells.push(UiStripCell::{ start: x, width: cw, })
    x = x + cw
  }
  (cells, x)
}

///|
/// 控件局部 x → 格子下标；落在留白里是 `-1`。
fn ui_strip_hit(
  cells : Array[UiStripCell],
  x : Double,
  outer : Double,
) -> Int32 {
  let at = x - outer
  for i, c in cells {
    if at >= c.start && at < c.start + c.width {
      return i
    }
  }
  -1
}

///|
/// 鼠标事件的点（父局部）→ 控件局部 x。
fn[B] ui_strip_local_x(
  w : @moonui.Widget[B],
  p : @moonui.LogicalPoint,
) -> Double {
  p.x - w.frame().origin.x
}

///|
/// 换选中：同一个格子再点一次不回调（值没变），但仍然重画——松开手指那次
/// "按下"的视觉要收回去。
fn[B : @moonui.Backend] ui_strip_commit(
  w : @moonui.Widget[B],
  st : StripState,
  index : Int32,
) -> Unit raise @moonui.UiError {
  if index < 0 || index >= st.cells.length() {
    return
  }
  if st.selected == index {
    w.repaint()
    return
  }
  st.selected = index
  w.repaint()
  match st.handler {
    Some(f) => f(index)
    None => ()
  }
}

///|
/// 条带上的指针账：悬停到哪一格、按在哪一格、松手算不算一次换选。
///
/// `MouseDown` 只认左键（右键留给上下文菜单）；`MouseLeave` 清悬停——指针
/// 走出条带后那一格不该还亮着。按下之后指针滑到别的格再松手**不算**换选
/// （`press` 与松手时的格子必须同一格），这是原生分段控件与页签的行为，
/// 也是"按下就生效"会误触的原因。
fn[B : @moonui.Backend] ui_strip_watch(
  w : @moonui.Widget[B],
  st : StripState,
) -> Unit raise @moonui.UiError {
  let _ = w.on(
    fn(e) {
      match e {
        @moonui.MouseMove(_, _) => true
        @moonui.MouseDown(_, @moonui.Left, _, _) => true
        @moonui.MouseUp(_, @moonui.Left, _, _) => true
        @moonui.MouseLeave(_) => true
        _ => false
      }
    },
    fn(e) raise @moonui.UiError {
      match e {
        @moonui.MouseMove(_, p) => {
          let i = ui_strip_hit(st.cells, ui_strip_local_x(w, p), st.outer)
          if i != st.hover {
            st.hover = i
            w.repaint()
          }
        }
        @moonui.MouseDown(_, _, p, _) => {
          st.press = ui_strip_hit(st.cells, ui_strip_local_x(w, p), st.outer)
          w.repaint()
        }
        @moonui.MouseUp(_, _, p, _) => {
          let i = ui_strip_hit(st.cells, ui_strip_local_x(w, p), st.outer)
          let was = st.press
          st.press = -1
          if i >= 0 && i == was {
            ui_strip_commit(w, st, i)
          } else {
            w.repaint()
          }
        }
        @moonui.MouseLeave(_) =>
          if st.hover != -1 {
            st.hover = -1
            w.repaint()
          }
        _ => ()
      }
    },
  )
}

///|
/// 分段控件。一排格子共享一块凹槽底，选中的那格抬成一块凸起的面。
pub struct UiSegmented[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : StripState
}

///|
/// 分段控件的格子内缩与最小宽：内缩 12 比按钮的 14 小一点（格子连着排，
/// 太宽会显得松），最小宽 56 让"日/周/月"这种单字标签也有一块能点的面积。
fn ui_segment_metrics(metrics : UiMetrics) -> (Double, Double) {
  (metrics.font + 0.5, 56.0)
}

///|
fn[B : @moonui.Backend] ui_segment_size(
  backend : B,
  titles : Array[String],
  metrics : UiMetrics,
) -> (Array[UiStripCell], Double) {
  let (pad, min_cell) = ui_segment_metrics(metrics)
  let (cells, total) = ui_strip_cells(
    backend,
    titles,
    metrics.font,
    pad,
    min_cell,
  )
  // 两侧各留 3：凹槽底比选中块大一圈，才看得出"块"落在"槽"里
  (cells, total + 6.0)
}

///|
/// 画分段控件：槽 + 选中块 + 每格文案。
fn ui_paint_segment(
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
  let r = ui_clamp_radius(st.metrics.radius, w, h)
  let inner = 3.0
  ui_paint_fill(dl, 0.0, 0.0, w, h, r, t.surface_sunken)
  for i, cell in st.cells {
    let x = st.outer + cell.start
    let picked = st.selected == i
    if picked {
      // 选中块：上下各内缩 3、左右与格子同宽，圆角比槽小 3——三处一起缩，
      // 块的边与槽的边才平行（只缩上下会让块的角切进槽的圆角里）
      let face = if !st.it.enabled {
        ui_mix(t.surface, t.bg, 0.4)
      } else if st.press == i {
        t.surface_active
      } else {
        t.surface
      }
      ui_paint_fill(dl, x, inner, cell.width, h - inner * 2.0, r - inner, face)
    } else if st.hover == i && st.it.enabled {
      // 未选但悬停：铺一层极淡的底。不铺的话"指针在这格上"只剩字色变化，
      // 一排灰字里看不出来
      ui_paint_fill(
        dl,
        x,
        inner,
        cell.width,
        h - inner * 2.0,
        r - inner,
        ui_mix(t.surface_sunken, t.surface, 0.5),
      )
    }
    let fg = if !st.it.enabled {
      t.text_disabled
    } else if picked {
      t.text
    } else if st.hover == i {
      t.text
    } else {
      t.text_muted
    }
    ui_paint_center_text(
      dl,
      env,
      st.titles[i],
      x,
      0.0,
      cell.width,
      h,
      st.metrics.font,
      picked,
      fg,
    )
  }
  if st.it.focused && st.it.enabled {
    ui_paint_focus_ring(dl, 0.0, 0.0, w, h, r, t.focus_ring)
  }
}

///|
/// 造一个分段控件。`selected` 越界夹到 0。
pub fn[B : @moonui.Backend] UiSegmented::UiSegmented(
  backend : B,
  titles : Array[String],
  selected~ : Int32 = 0,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
  enabled~ : Bool = true,
) -> UiSegmented[B] raise @moonui.UiError {
  if titles.length() == 0 {
    raise @moonui.OperationFailed("分段控件的选项不能为空")
  }
  let metrics = theme.metrics(size)
  let (cells, total) = ui_segment_size(backend, titles, metrics)
  let init = if selected < 0 {
    0
  } else if selected >= titles.length() {
    titles.length() - 1
  } else {
    selected
  }
  let state = StripState::{
    theme,
    metrics,
    titles,
    cells,
    outer: 3.0,
    selected: init,
    hover: -1,
    press: -1,
    it: UiInteract::new(enabled~),
    handler: None,
  }
  let widget = @moonui.Widget::custom(
    backend,
    @moonui.LogicalSize(total, metrics.height),
    fn(dl, env) { ui_paint_segment(state, dl, env) },
    focusable=true,
  )
  ui_watch_state(widget, state.it)
  ui_strip_watch(widget, state)
  { backend, widget, state, }
}

///|
pub fn[B] UiSegmented::widget(self : UiSegmented[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
pub fn[B] UiSegmented::selected(self : UiSegmented[B]) -> Int32 {
  self.state.selected
}

///|
pub fn[B] UiSegmented::on_change(
  self : UiSegmented[B],
  f : (Int32) -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
/// 程序设值：夹到合法下标，重画，不触发 `on_change`。
pub fn[B : @moonui.Backend] UiSegmented::set_selected(
  self : UiSegmented[B],
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
/// 使能开关。禁用后指针账照走（悬停仍会记账），只是不换选、颜色退到禁用档。
pub fn[B : @moonui.Backend] UiSegmented::set_enabled(
  self : UiSegmented[B],
  enabled : Bool,
) -> Unit raise @moonui.UiError {
  if self.state.it.enabled == enabled {
    return
  }
  self.state.it.enabled = enabled
  self.widget.repaint()
}

///|
/// 造一个分段控件并直接给回调（表单里最常见的写法：造完就要接上）。
pub fn[B : @moonui.Backend] UiSegmented::with_handler(
  backend : B,
  titles : Array[String],
  f : (Int32) -> Unit raise @moonui.UiError,
  selected~ : Int32 = 0,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
) -> UiSegmented[B] raise @moonui.UiError {
  let seg = UiSegmented::UiSegmented(backend, titles, selected~, theme~, size~)
  seg.on_change(f)
  seg
}
