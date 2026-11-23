///|
/// `UiSteps`——自绘步骤条（`T360` 第三档）。
///
/// 原生控件里没有"步骤条"：它要么是几个 Label 并排（连线得自己铺），要么是一
/// 张自绘图片。自绘之后整条是"圆点 + 连线 + 标签"三笔：完成的画勾、当前的填
/// 主色、未到的留灰圈，连线按"是否已走过"分色。
///
/// 节点数是构造时给的（`labels`），之后只改 `current`——步骤条的语义就是
/// "走到第几步"，节点表在生命周期里变来变去反而说明用错了控件。
///
/// 点击任一节点会回调 `on_change(index)`（调用方决定是否允许回跳）；左右键
/// 在节点间移动，与分段控件同一条键盘口径。

///|
/// 步骤条的账：节点表、当前步、按下点。
struct StepsState {
  mut theme : UiTheme
  size : UiSize
  mut metrics : UiMetrics
  labels : Array[String]
  /// 固有宽（节点等分与重算都读它，不读 frame）
  width : Double
  mut current : Int32
  /// 按下时记的节点号（-1 = 没落在节点上）：抬起仍在同一节点才提交
  mut press_index : Int32
  mut handler : ((Int32) -> Unit raise @moonui.UiError)?
}

///|
/// 自绘步骤条。
pub struct UiSteps[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : StepsState
}

///|
/// 圆点直径。20 是"能装下一个两位数序号、又不把标签挤下去"的折中。
const UI_STEPS_DOT : Double = 20.0

///|
/// 圆点与标签之间的空隙。
const UI_STEPS_GAP : Double = 6.0

///|
/// 固有高：圆点 + 空隙 + 一行标签。
fn ui_steps_height(st : StepsState) -> Double {
  UI_STEPS_DOT + UI_STEPS_GAP + st.metrics.font * 1.45
}

///|
/// 每个节点占的横向宽度（等分）。
fn ui_steps_cell_w(st : StepsState) -> Double {
  let n = st.labels.length()
  if n <= 0 {
    return 0.0
  }
  let w = st.width
  w / n.to_double()
}

///|
/// 节点 i 的圆心 x。
fn ui_steps_center_x(st : StepsState, i : Int32) -> Double {
  ui_steps_cell_w(st) * (i.to_double() + 0.5)
}

///|
/// 画一条步骤：先连线（在圆点底下），再圆点，最后标签。
fn ui_paint_steps(
  st : StepsState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let t = st.theme
  let n = st.labels.length()
  if n <= 0 {
    return
  }
  let r = UI_STEPS_DOT / 2.0
  let cy = r
  // 连线：段 i 连接节点 i 与 i+1，颜色看"这一步走过了没有"
  let mut i = 0
  while i < n - 1 {
    let x0 = ui_steps_center_x(st, i) + r + 3.0
    let x1 = ui_steps_center_x(st, i + 1) - r - 3.0
    if x1 > x0 {
      let rgb = if i < st.current { t.accent } else { t.border }
      ui_paint_fill(dl, x0, cy - 1.0, x1 - x0, 2.0, 1.0, rgb)
    }
    i = i + 1
  }
  // 圆点 + 标签
  i = 0
  while i < n {
    let cx = ui_steps_center_x(st, i)
    let done = i < st.current
    let active = i == st.current
    if done || active {
      ui_paint_dot(dl, cx, cy, r, t.accent)
    } else {
      ui_paint_fill(
        dl,
        cx - r,
        cy - r,
        UI_STEPS_DOT,
        UI_STEPS_DOT,
        r,
        t.surface_sunken,
      )
      ui_paint_stroke(
        dl,
        cx - r,
        cy - r,
        UI_STEPS_DOT,
        UI_STEPS_DOT,
        r,
        0.5,
        1.0,
        t.border_strong,
      )
    }
    let (mark, mark_rgb) = if done {
      ("✓", t.on_accent)
    } else if active {
      ((i + 1).to_string(), t.on_accent)
    } else {
      ((i + 1).to_string(), t.text_muted)
    }
    ui_paint_center_text(
      dl,
      env,
      mark,
      cx - r,
      cy - r,
      UI_STEPS_DOT,
      UI_STEPS_DOT,
      if done {
        r * 1.1
      } else {
        st.metrics.font
      },
      true,
      mark_rgb,
    )
    let label_w = ui_steps_cell_w(st) - 8.0
    ui_paint_center_text(
      dl,
      env,
      st.labels[i],
      cx - label_w / 2.0,
      UI_STEPS_DOT + UI_STEPS_GAP,
      label_w,
      st.metrics.font * 1.45,
      st.metrics.font,
      active,
      if active || done {
        t.text
      } else {
        t.text_muted
      },
    )
    i = i + 1
  }
}

///|
/// 指针落点 → 节点号（不在任何节点上给 -1）。
fn[B] ui_steps_hit(
  w : @moonui.Widget[B],
  st : StepsState,
  p : @moonui.LogicalPoint,
) -> Int32 {
  let fw = w.frame().size.width
  let cell = if st.labels.length() > 0 {
    fw / st.labels.length().to_double()
  } else {
    0.0
  }
  if cell <= 0.0 {
    return -1
  }
  let x = p.x - w.frame().origin.x
  let idx = (x / cell).to_int()
  if idx < 0 || idx >= st.labels.length() {
    -1
  } else {
    idx
  }
}

///|
/// 提交一个节点号：夹住、变了才回调、每次都重画。
fn[B : @moonui.Backend] ui_steps_commit(
  w : @moonui.Widget[B],
  st : StepsState,
  raw : Int32,
) -> Unit raise @moonui.UiError {
  let n = st.labels.length()
  if n <= 0 {
    return
  }
  let v = if raw < 0 { 0 } else if raw >= n { n - 1 } else { raw }
  let changed = v != st.current
  st.current = v
  w.repaint()
  if changed {
    match st.handler {
      Some(f) => f(v)
      None => ()
    }
  }
}

///|
/// 造一条步骤条。`labels` 为空时什么都不画（不报错：数据还没到）。
pub fn[B : @moonui.Backend] UiSteps::UiSteps(
  backend : B,
  labels : Array[String],
  current~ : Int32 = 0,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
  width~ : Double = 400.0,
) -> UiSteps[B] raise @moonui.UiError {
  let metrics = theme.metrics(size)
  let w = if width > 0.0 { width } else { 400.0 }
  let n = labels.length()
  let cur = if n <= 0 {
    0
  } else if current < 0 {
    0
  } else if current >= n {
    n - 1
  } else {
    current
  }
  let state = StepsState::{
    theme,
    size,
    metrics,
    labels,
    width: w,
    current: cur,
    press_index: -1,
    handler: None,
  }
  let widget = @moonui.Widget::custom(
    backend,
    @moonui.LogicalSize(w, ui_steps_height(state)),
    fn(dl, env) { ui_paint_steps(state, dl, env) },
    focusable=true,
  )
  let _ = widget.on(
    fn(e) {
      match e {
        @moonui.MouseDown(_, @moonui.Left, _, _) => true
        @moonui.MouseUp(_, @moonui.Left, _, _) => true
        @moonui.KeyDown(_, kp) => kp.key == "Left" || kp.key == "Right"
        _ => false
      }
    },
    fn(e) raise @moonui.UiError {
      match e {
        @moonui.MouseDown(_, _, p, _) =>
          state.press_index = ui_steps_hit(widget, state, p)
        @moonui.MouseUp(_, _, p, _) => {
          let idx = ui_steps_hit(widget, state, p)
          let fire = state.press_index >= 0 && idx == state.press_index
          state.press_index = -1
          if fire {
            ui_steps_commit(widget, state, idx)
          }
        }
        @moonui.KeyDown(_, kp) =>
          if kp.key == "Left" {
            ui_steps_commit(widget, state, state.current - 1)
          } else if kp.key == "Right" {
            ui_steps_commit(widget, state, state.current + 1)
          }
        _ => ()
      }
    },
  )
  { backend, widget, state, }
}

///|
pub fn[B] UiSteps::widget(self : UiSteps[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
pub fn[B] UiSteps::current(self : UiSteps[B]) -> Int32 {
  self.state.current
}

///|
/// 节点数。
pub fn[B] UiSteps::count(self : UiSteps[B]) -> Int32 {
  self.state.labels.length()
}

///|
/// 换当前步（越界夹住，变了才回调）。
pub fn[B : @moonui.Backend] UiSteps::set_current(
  self : UiSteps[B],
  index : Int32,
) -> Unit raise @moonui.UiError {
  ui_steps_commit(self.widget, self.state, index)
}

///|
/// 走到下一步 / 上一步（到端不动）。
pub fn[B : @moonui.Backend] UiSteps::next(
  self : UiSteps[B],
) -> Unit raise @moonui.UiError {
  ui_steps_commit(self.widget, self.state, self.state.current + 1)
}

///|
pub fn[B : @moonui.Backend] UiSteps::prev(
  self : UiSteps[B],
) -> Unit raise @moonui.UiError {
  ui_steps_commit(self.widget, self.state, self.state.current - 1)
}

///|
/// 节点被点（或键盘换步）时的回调。
pub fn[B] UiSteps::on_change(
  self : UiSteps[B],
  f : (Int32) -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
/// 换令牌：字号变了标签行高与固有高都要重算。
pub fn[B : @moonui.Backend] UiSteps::set_theme(
  self : UiSteps[B],
  theme : UiTheme,
) -> Unit raise @moonui.UiError {
  self.state.theme = theme
  self.state.metrics = theme.metrics(self.state.size)
  self.widget.set_custom_size(
    @moonui.LogicalSize(self.state.width, ui_steps_height(self.state)),
  )
  self.widget.repaint()
}
