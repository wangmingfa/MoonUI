///|
/// `UiPagination`——自绘分页器（`T360` 第三档）。
///
/// 原生控件没有分页器；社区做法是一排按钮，但"哪些页码该显示、什么时候用省略
/// 号、到端要不要禁用"这套算术每处重写一遍。自绘之后它是一只控件：总页数与
/// 当前页进来，槽位表自己算，宽度跟着槽数变（`set_custom_size`），点哪格回调
/// 哪个页码。
///
/// 槽位表规则（与主流设计系统同一条）：
/// - 总页数 ≤ 7：全列；
/// - 否则：首页 + （当前离首页远才有的）省略号 + 当前 ±1 + （离末页远才有的）
///   省略号 + 末页。
///
/// 省略号那一格不可点（`0` 在槽位表里就是它）。
///
/// 键盘：左右键翻一页，与分段控件同一条口径；第一页/最后一页时对应方向键无效。

///|
/// 分页器的账：总数、当前页、槽位表。
struct PageState {
  mut theme : UiTheme
  size : UiSize
  mut metrics : UiMetrics
  mut total : Int32
  /// 当前页（1 起）
  mut current : Int32
  /// 显示的槽位：页码（≥1），`0` 表示省略号
  mut slots : Array[Int32]
  /// 悬停的槽位下标（-1 = 没在任一格上）
  mut hover : Int32
  /// 按下时记的槽位下标（-1 = 没按下）
  mut press : Int32
  mut handler : ((Int32) -> Unit raise @moonui.UiError)?
}

///|
/// 自绘分页器。
pub struct UiPagination[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : PageState
}

///|
/// 页码格之间的间距。
const UI_PAGE_GAP : Double = 4.0

///|
/// 算槽位表：见文件头那条规则。`total` 小于 1 时给空表。
fn ui_page_slots(total : Int32, current : Int32) -> Array[Int32] {
  let out : Array[Int32] = []
  if total <= 0 {
    return out
  }
  if total <= 7 {
    let mut i = 1
    while i <= total {
      out.push(i)
      i = i + 1
    }
    return out
  }
  out.push(1)
  let mut from = current - 1
  if from < 2 {
    from = 2
  }
  let mut to = current + 1
  if to > total - 1 {
    to = total - 1
  }
  if from > 2 {
    out.push(0)
  }
  let mut p = from
  while p <= to {
    out.push(p)
    p = p + 1
  }
  if to < total - 1 {
    out.push(0)
  }
  out.push(total)
  out
}

///|
/// 一格边长（方形格）。
fn ui_page_cell(st : PageState) -> Double {
  st.metrics.height
}

///|
/// 格子总数：上一页 + 槽位 + 下一页。
fn ui_page_cell_count(st : PageState) -> Int32 {
  st.slots.length() + 2
}

///|
/// 固有宽。
fn ui_page_width(st : PageState) -> Double {
  let n = ui_page_cell_count(st)
  if n <= 0 {
    return 0.0
  }
  let c = ui_page_cell(st)
  n.to_double() * c + (n - 1).to_double() * UI_PAGE_GAP
}

///|
/// 第 i 格的 x（0 = 上一页，1..n-2 = 槽位，n-1 = 下一页）。
fn ui_page_cell_x(st : PageState, i : Int32) -> Double {
  i.to_double() * (ui_page_cell(st) + UI_PAGE_GAP)
}

///|
/// 画一格：底（当前页填主色、悬停填悬停面）+ 字。
fn ui_paint_page_cell(
  st : PageState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  i : Int32,
  label : String,
  active : Bool,
  enabled : Bool,
  selected : Bool,
) -> Unit {
  let t = st.theme
  let c = ui_page_cell(st)
  let x = ui_page_cell_x(st, i)
  let r = if st.metrics.radius - 2.0 > 0.0 {
    st.metrics.radius - 2.0
  } else {
    0.0
  }
  if selected {
    ui_paint_fill(dl, x, 0.0, c, c, r, t.accent)
  } else if active && enabled {
    ui_paint_fill(dl, x, 0.0, c, c, r, t.surface_hover)
  }
  let fg = if !enabled {
    t.text_disabled
  } else if selected {
    t.on_accent
  } else if label == "…" {
    t.text_muted
  } else {
    t.text
  }
  ui_paint_center_text(
    dl,
    env,
    label,
    x,
    0.0,
    c,
    c,
    st.metrics.font,
    selected,
    fg,
  )
}

///|
/// 画一整条分页器。
fn ui_paint_pagination(
  st : PageState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 || st.total <= 0 {
    return
  }
  let n = ui_page_cell_count(st)
  ui_paint_page_cell(
    st,
    dl,
    env,
    0,
    "‹",
    st.hover == 0,
    st.current > 1,
    false,
  )
  let mut i = 0
  while i < st.slots.length() {
    let p = st.slots[i]
    let ci = i + 1
    let selected = p != 0 && p == st.current
    ui_paint_page_cell(
      st,
      dl,
      env,
      ci,
      if p == 0 {
        "…"
      } else {
        p.to_string()
      },
      st.hover == ci,
      p != 0,
      selected,
    )
    i = i + 1
  }
  ui_paint_page_cell(
    st,
    dl,
    env,
    n - 1,
    "›",
    st.hover == n - 1,
    st.current < st.total,
    false,
  )
}

///|
/// 指针 → 槽位下标（-1 = 不在格上）。
fn[B] ui_page_hit(
  w : @moonui.Widget[B],
  st : PageState,
  p : @moonui.LogicalPoint,
) -> Int32 {
  let c = ui_page_cell(st)
  let step = c + UI_PAGE_GAP
  if step <= 0.0 {
    return -1
  }
  let x = p.x - w.frame().origin.x
  let y = p.y - w.frame().origin.y
  if y < 0.0 || y > c {
    return -1
  }
  let idx = (x / step).to_int()
  // 落在两格之间的缝里：只有缝不到半格宽时才算前一格，避免"点缝全落空"
  if idx < 0 || idx >= ui_page_cell_count(st) {
    return -1
  }
  idx
}

///|
/// 槽位下标 → 目标页（0 = 无动作：省略号、到端的箭头）。
fn ui_page_target(st : PageState, idx : Int32) -> Int32 {
  let n = ui_page_cell_count(st)
  if idx <= 0 {
    if st.current > 1 {
      st.current - 1
    } else {
      0
    }
  } else if idx >= n - 1 {
    if st.current < st.total {
      st.current + 1
    } else {
      0
    }
  } else {
    st.slots[idx - 1]
  }
}

///|
/// 提交一页：夹在 1..total，变了才回调、每次都重画。
fn[B : @moonui.Backend] ui_page_commit(
  w : @moonui.Widget[B],
  st : PageState,
  raw : Int32,
) -> Unit raise @moonui.UiError {
  if raw <= 0 || st.total <= 0 {
    return
  }
  let v = if raw > st.total { st.total } else { raw }
  let changed = v != st.current
  st.current = v
  st.slots = ui_page_slots(st.total, v)
  w.repaint()
  if changed {
    match st.handler {
      Some(f) => f(v)
      None => ()
    }
  }
}

///|
/// 造一只分页器。`total` 至少 1；`current` 夹在 1..total。
pub fn[B : @moonui.Backend] UiPagination::UiPagination(
  backend : B,
  total~ : Int32 = 1,
  current~ : Int32 = 1,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
) -> UiPagination[B] raise @moonui.UiError {
  let metrics = theme.metrics(size)
  let t = if total < 1 { 1 } else { total }
  let c = if current < 1 { 1 } else if current > t { t } else { current }
  let state = PageState::{
    theme,
    size,
    metrics,
    total: t,
    current: c,
    slots: ui_page_slots(t, c),
    hover: -1,
    press: -1,
    handler: None,
  }
  let widget = @moonui.Widget::custom(
    backend,
    @moonui.LogicalSize(ui_page_width(state), metrics.height),
    fn(dl, env) { ui_paint_pagination(state, dl, env) },
    focusable=true,
  )
  let _ = widget.on(
    fn(e) {
      match e {
        @moonui.MouseDown(_, @moonui.Left, _, _) => true
        @moonui.MouseUp(_, @moonui.Left, _, _) => true
        @moonui.MouseMove(_, _) => true
        @moonui.MouseLeave(_) => true
        @moonui.KeyDown(_, kp) => kp.key == "Left" || kp.key == "Right"
        _ => false
      }
    },
    fn(e) raise @moonui.UiError {
      match e {
        @moonui.MouseDown(_, _, p, _) =>
          state.press = ui_page_hit(widget, state, p)
        @moonui.MouseMove(_, p) => {
          let h = ui_page_hit(widget, state, p)
          if h != state.hover {
            state.hover = h
            widget.repaint()
          }
        }
        @moonui.MouseLeave(_) =>
          if state.hover != -1 {
            state.hover = -1
            widget.repaint()
          }
        @moonui.MouseUp(_, _, p, _) => {
          let idx = ui_page_hit(widget, state, p)
          let fire = state.press >= 0 && idx == state.press
          state.press = -1
          if fire {
            ui_page_commit(widget, state, ui_page_target(state, idx))
          }
        }
        @moonui.KeyDown(_, kp) =>
          if kp.key == "Left" {
            ui_page_commit(widget, state, state.current - 1)
          } else if kp.key == "Right" {
            ui_page_commit(widget, state, state.current + 1)
          }
        _ => ()
      }
    },
  )
  { backend, widget, state, }
}

///|
pub fn[B] UiPagination::widget(self : UiPagination[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
pub fn[B] UiPagination::current(self : UiPagination[B]) -> Int32 {
  self.state.current
}

///|
pub fn[B] UiPagination::total(self : UiPagination[B]) -> Int32 {
  self.state.total
}

///|
/// 当下槽位表（判据读它看省略号规则，不用去数绘制命令）。
pub fn[B] UiPagination::slots(self : UiPagination[B]) -> Array[Int32] {
  self.state.slots
}

///|
/// 换当前页（夹住，变了才回调）。
pub fn[B : @moonui.Backend] UiPagination::set_current(
  self : UiPagination[B],
  page : Int32,
) -> Unit raise @moonui.UiError {
  ui_page_commit(self.widget, self.state, page)
}

///|
/// 换总页数：当前页跟着夹一下，槽位表重算，宽度可能变（页数跨过 7 那一档）。
pub fn[B : @moonui.Backend] UiPagination::set_total(
  self : UiPagination[B],
  total : Int32,
) -> Unit raise @moonui.UiError {
  let t = if total < 1 { 1 } else { total }
  self.state.total = t
  if self.state.current > t {
    self.state.current = t
  }
  self.state.slots = ui_page_slots(t, self.state.current)
  self.widget.set_custom_size(
    @moonui.LogicalSize(ui_page_width(self.state), self.state.metrics.height),
  )
  self.widget.repaint()
}

///|
/// 换页回调。
pub fn[B] UiPagination::on_change(
  self : UiPagination[B],
  f : (Int32) -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
/// 换令牌：格子边长跟着尺寸档走，宽度要重算。
pub fn[B : @moonui.Backend] UiPagination::set_theme(
  self : UiPagination[B],
  theme : UiTheme,
) -> Unit raise @moonui.UiError {
  self.state.theme = theme
  self.state.metrics = theme.metrics(self.state.size)
  self.widget.set_custom_size(
    @moonui.LogicalSize(ui_page_width(self.state), self.state.metrics.height),
  )
  self.widget.repaint()
}
