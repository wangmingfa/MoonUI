///|
/// `UiProgress`——自绘线性进度条（`T351`）。
///
/// 原生进度条（`Widget::progress`）在 Win32 上是系统画的一段绿色方块、在 mac
/// 上是 `NSProgressIndicator` 的细蓝条，两边连高度都不由调用方定；配色、圆角、
/// 轨道更是改不了。自绘之后它只是两块圆角矩形——轨道一条、进度一条，宽随值变。
///
/// 不定进度（`T357`）：`Core` 的 `App::post_animation` 就是"控件自己申请每帧
/// 回调"的口子，所以这里能自己推相位——构造时把 `app` 交进来，跑马灯那一档
/// 每 16ms 挪一步，关掉时下一拍自动收链，不留一条空转的定时器。
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
  mut indeterminate : Bool
  mut elapsed : Int32
  mut phase : Double
  ticker : @moonui.Ticker
}

///|
/// 自绘进度条。
pub struct UiProgress[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : ProgressState
  /// 起跑马灯链用的 App：构造时记下，切换档位不用调用方再交一次
  app : @moonui.App[B]?
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
/// 一轮跑马灯的来回周期（毫秒）。半程 900ms：短到能看出在动，长到不晃眼。
const UI_PROGRESS_PERIOD_MS : Int32 = 900

///|
/// 跑马灯的相位（0..1，来回）：`anim_phase` 的 PingPong 那一档，纯函数——
/// 真机推进只负责喂 elapsed，画在哪儿由这里算，判据因此能逐拍写死。
pub fn ui_progress_phase(elapsed : Int32) -> Double {
  @moonui.anim_phase(
    @moonui.RepeatMode::PingPong,
    elapsed,
    UI_PROGRESS_PERIOD_MS,
  ).0
}

///|
/// 一拍：推相位 + 叫醒这块面。返回 `false` 收链——关掉不定档之后最多多跑
/// 16ms 就停，不会留一条空转的定时器在后台每帧叫 repaint。
fn[B : @moonui.Backend] ui_progress_drive(
  st : ProgressState,
  w : @moonui.Widget[B],
) -> (Bool) -> Bool raise @moonui.UiError {
  fn(first : Bool) -> Bool raise @moonui.UiError {
    if !st.indeterminate {
      return false
    }
    if first {
      st.elapsed = 0
    }
    st.elapsed = st.elapsed + 16
    // 相对累计从 0 起步，跑一天多才会碰到 Int32 上界；提前折回整周期，
    // 免得真到回绕那刻 PingPong 的取模翻脸。
    if st.elapsed > 100000 {
      st.elapsed = st.elapsed % UI_PROGRESS_PERIOD_MS
    }
    st.phase = ui_progress_phase(st.elapsed)
    w.repaint()
    true
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
  if st.indeterminate {
    // 不定档：一段短亮条在槽里来回走。宽度取槽的 28%（下限 8px，短条在长槽
    // 里会像噪声），位置由 PingPong 相位给出——两端各停一瞬才折返，比单向
    // 循环更像"还在干活但说不出还要多久"。
    let span = if w * 0.28 < 8.0 { 8.0 } else { w * 0.28 }
    let x = (w - span) * st.phase
    ui_paint_fill(dl, x, 0.0, span, h, r, t.tone(st.tone))
    return
  }
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
  indeterminate~ : Bool = false,
  app~ : @moonui.App[B]? = None,
) -> UiProgress[B] raise @moonui.UiError {
  let h = if thickness > 0.0 { thickness } else { 8.0 }
  let w = if width > 0.0 { width } else { 180.0 }
  let state = ProgressState::{
    theme,
    value: ui_progress_clamp(value),
    tone,
    indeterminate,
    elapsed: 0,
    phase: 0.0,
    ticker: @moonui.Ticker(),
  }
  let widget = @moonui.Widget::custom(backend, @moonui.LogicalSize(w, h), fn(
    dl,
    env,
  ) {
    ui_paint_progress(state, dl, env)
  })
  match app {
    Some(a) =>
      if indeterminate {
        let _ = a.post_animation(
          state.ticker,
          16,
          ui_progress_drive(state, widget),
        )
      }
    None => ()
  }
  { backend, widget, state, app, }
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

///|
/// 切到/切出不定档。切到时开一条帧链（幂等，已有链不动）；切出时把相位归零，
/// 链在下一拍自己收。不定档下 `set_value` 照旧记账，切回来时直接接着用。
pub fn[B : @moonui.Backend] UiProgress::set_indeterminate(
  self : UiProgress[B],
  value : Bool,
) -> Unit raise @moonui.UiError {
  if self.state.indeterminate == value {
    return
  }
  self.state.indeterminate = value
  self.state.elapsed = 0
  self.state.phase = 0.0
  match self.app {
    Some(a) =>
      if value {
        let _ = a.post_animation(
          self.state.ticker,
          16,
          ui_progress_drive(self.state, self.widget),
        )
      }
    None => ()
  }
  self.widget.repaint()
}

///|
/// 当前是不是不定档（画册/判据读回用）。
pub fn[B] UiProgress::indeterminate(self : UiProgress[B]) -> Bool {
  self.state.indeterminate
}

///|
/// 当前跑马灯相位（0..1）：真窗读数与判据都从这里取，不摸内部状态。
pub fn[B] UiProgress::phase(self : UiProgress[B]) -> Double {
  self.state.phase
}

///|
/// 帧链还在不在：关档后下一拍应自动收链，这条读数让判据能直接看见"没空转"。
pub fn[B] UiProgress::ticking(self : UiProgress[B]) -> Bool {
  self.state.ticker.running()
}
