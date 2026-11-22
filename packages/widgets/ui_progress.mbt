///|
/// `UiProgress`——自绘线性进度条（`T351`）。
///
/// 原生进度条（`Widget::progress`）在 Win32 上是系统画的一段绿色方块、在 mac
/// 上是 `NSProgressIndicator` 的细蓝条，两边连高度都不由调用方定；配色、圆角、
/// 轨道更是改不了。自绘之后它只是两块圆角矩形——轨道一条、进度一条，宽随值变。
///
/// 为什么不做不定进度（跑马灯）：那需要一条时间轴（`App` 的动画泵按帧推进），
/// 而这块面现在只会被"值变了"叫醒。真要做，得先有"控件自己申请每帧回调"的
/// 口子，那是另一笔账（`T337` 的动画扩容已经在往那个方向走）。
///
/// 与 `ProgressRing`（`progress_ring.mbt`）的分工：环是"配额/占用"这种要一眼
/// 看出比例的地方，条是"任务完成到哪一步"这种要看数字的地方。两者的颜色账
/// 都从令牌取，所以放在一张卡里也不会串味。

///|
/// 进度条的账：值、语义色、粗细、宽度。
struct ProgressState {
  mut theme : UiTheme
  mut value : Double
  mut tone : UiTone
}

///|
/// 自绘进度条。
pub struct UiProgress[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : ProgressState
}

///|
/// 夹到 0..1。`NaN` 也归 0（与 `ProgressRing` 同一条口径：画一个空条比画一条
/// "满格但没完成"的假象诚实）。
fn ui_progress_clamp(v : Double) -> Double {
  if v != v {
    0.0
  } else if v < 0.0 {
    0.0
  } else if v > 1.0 {
    1.0
  } else {
    v
  }
}

///|
/// 画一条进度：轨道整条 + 进度到 `value` 那一截。
fn ui_paint_progress(
  st : ProgressState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let t = st.theme
  let r = h / 2.0
  ui_paint_fill(dl, 0.0, 0.0, w, h, r, t.track)
  if st.value <= 0.0 {
    return
  }
  // 进度那一截至少 2px 宽：0.5% 的进度条画不出来，就等于"程序没动"——2px
  // 是一个能看见"确实开始跑了"的最小读数
  let mut fw = w * st.value
  if fw < 2.0 {
    fw = 2.0
  }
  if fw > w {
    fw = w
  }
  ui_paint_fill(dl, 0.0, 0.0, fw, h, r, t.tone(st.tone))
}

///|
/// 造一条进度条。`value` 0..1（越界与 `NaN` 夹住）；`thickness` 是条的粗细，
/// 也是它的固有高。
pub fn[B : @moonui.Backend] UiProgress::UiProgress(
  backend : B,
  value~ : Double = 0.0,
  theme~ : UiTheme = UiTheme::light(),
  width~ : Double = 180.0,
  thickness~ : Double = 8.0,
  tone~ : UiTone = UiTone::UiAccent,
) -> UiProgress[B] raise @moonui.UiError {
  let h = if thickness > 0.0 { thickness } else { 8.0 }
  let w = if width > 0.0 { width } else { 180.0 }
  let state = ProgressState::{ theme, value: ui_progress_clamp(value), tone, }
  let widget = @moonui.Widget::custom(backend, @moonui.LogicalSize(w, h), fn(
    dl,
    env,
  ) {
    ui_paint_progress(state, dl, env)
  })
  { backend, widget, state, }
}

///|
pub fn[B] UiProgress::widget(self : UiProgress[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
pub fn[B] UiProgress::value(self : UiProgress[B]) -> Double {
  self.state.value
}

///|
/// 推一个新值并重画。夹在 0..1，`value()` 读到的也是夹住后的值。
pub fn[B : @moonui.Backend] UiProgress::set_value(
  self : UiProgress[B],
  value : Double,
) -> Unit raise @moonui.UiError {
  self.state.value = ui_progress_clamp(value)
  self.widget.repaint()
}

///|
/// 换语义色（成功/警告/危险）并重画。
pub fn[B : @moonui.Backend] UiProgress::set_tone(
  self : UiProgress[B],
  tone : UiTone,
) -> Unit raise @moonui.UiError {
  self.state.tone = tone
  self.widget.repaint()
}

///|
/// 换令牌并重画（精细宽高由 `.width()` / `.height()` 覆盖，不走这里）。
pub fn[B : @moonui.Backend] UiProgress::set_theme(
  self : UiProgress[B],
  theme : UiTheme,
) -> Unit raise @moonui.UiError {
  self.state.theme = theme
  self.widget.repaint()
}
