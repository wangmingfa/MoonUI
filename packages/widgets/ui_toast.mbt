///|
/// `UiToast`——自绘轻提示条（`T360` 第三档）。
///
/// 这里的 Toast 是**内联**的（页面流里的一条），不是浮层：浮层要 Core 的 popup
/// 能力，那是 `T359` 里评估为架构性大坑的那一笔（与 `T343`/HUD 同族），不做。
/// 内联版解掉的是最常见的用法——"刚保存成功""网络断了"这种几秒后自己消失的
/// 一行字，铺在表单上方或页面底部，不需要脱离父窗。
///
/// 自动消失靠 `App::post_animation` 推倒计时（与不定进度、骨架屏同一条帧口子）：
/// 到点调一次 `on_dismiss` 并收链。控件**不会**自己摘掉——从布局里移除是调用方
/// 的事（框架替它改父容器的孩子表，语义上比"通知你该收了"更越界）。
///
/// 不交 `app` 或 `duration_ms <= 0` 就是常驻条，不启动帧链。

///|
/// 轻提示的账：文案、语义、倒计时。
struct ToastState {
  mut theme : UiTheme
  size : UiSize
  mut metrics : UiMetrics
  mut text : String
  mut tone : UiTone
  /// 总时长（毫秒）；`<= 0` 表示常驻
  duration : Int32
  mut elapsed : Int32
  /// 已经到点过（回调只响一次）
  mut done : Bool
  /// 固有宽（重算高要用它，不读 frame）
  width : Double
  ticker : @moonui.Ticker
  mut handler : (() -> Unit raise @moonui.UiError)?
}

///|
/// 自绘轻提示。
pub struct UiToast[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : ToastState
}

///|
/// 一拍的步长（毫秒）：与 `post_animation` 的间隔一致。
const UI_TOAST_TICK_MS : Int32 = 16

///|
/// 条目高：一行字 + 上下各 8。
fn ui_toast_height(st : ToastState) -> Double {
  st.metrics.font * 1.45 + 16.0
}

///|
/// 一拍：累加已过时长，到点回调一次并收链（`false`）。回调里可能把控件摘掉，
/// 所以先置 `done` 再调——重入进来不会响第二次。
fn[B : @moonui.Backend] ui_toast_drive(
  st : ToastState,
  w : @moonui.Widget[B],
) -> (Bool) -> Bool raise @moonui.UiError {
  fn(first : Bool) -> Bool raise @moonui.UiError {
    if st.done || st.duration <= 0 {
      return false
    }
    if first {
      st.elapsed = 0
    }
    st.elapsed = st.elapsed + UI_TOAST_TICK_MS
    if st.elapsed >= st.duration {
      st.done = true
      match st.handler {
        Some(f) => f()
        None => ()
      }
      return false
    }
    w.repaint()
    true
  }
}

///|
/// 画一条轻提示：淡语义底 + 左侧语义圆点 + 一行字。
fn ui_paint_toast(
  st : ToastState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let t = st.theme
  ui_paint_fill(dl, 0.0, 0.0, w, h, st.metrics.radius, t.tone_surface(st.tone))
  ui_paint_dot(dl, 14.0, h / 2.0, 3.5, t.tone(st.tone))
  ui_paint_line_text(
    dl,
    env,
    st.text,
    26.0,
    0.0,
    w - 38.0,
    h,
    st.metrics.font,
    false,
    t.text,
  )
}

///|
/// 造一条轻提示。`duration_ms <= 0` 为常驻；到点触发 `on_dismiss`。
pub fn[B : @moonui.Backend] UiToast::UiToast(
  backend : B,
  text : String,
  tone~ : UiTone = UiTone::UiSuccess,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
  width~ : Double = 320.0,
  duration_ms~ : Int32 = 3000,
  app~ : @moonui.App[B]? = None,
) -> UiToast[B] raise @moonui.UiError {
  let metrics = theme.metrics(size)
  let w = if width > 0.0 { width } else { 320.0 }
  let state = ToastState::{
    theme,
    size,
    metrics,
    text,
    tone,
    duration: duration_ms,
    elapsed: 0,
    done: false,
    width: w,
    ticker: @moonui.Ticker(),
    handler: None,
  }
  let widget = @moonui.Widget::custom(
    backend,
    @moonui.LogicalSize(w, ui_toast_height(state)),
    fn(dl, env) { ui_paint_toast(state, dl, env) },
  )
  match (app, duration_ms > 0) {
    (Some(a), true) => {
      let _ = a.post_animation(
        state.ticker,
        UI_TOAST_TICK_MS,
        ui_toast_drive(state, widget),
      )
    }
    _ => ()
  }
  { backend, widget, state, }
}

///|
pub fn[B] UiToast::widget(self : UiToast[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
pub fn[B] UiToast::text(self : UiToast[B]) -> String {
  self.state.text
}

///|
/// 剩余毫秒（常驻条给 `duration`）。判据用它看倒计时真的在走。
pub fn[B] UiToast::remaining_ms(self : UiToast[B]) -> Int32 {
  if self.state.duration <= 0 {
    return self.state.duration
  }
  let left = self.state.duration - self.state.elapsed
  if left < 0 {
    0
  } else {
    left
  }
}

///|
/// 到点了没有（回调已响过）。
pub fn[B] UiToast::done(self : UiToast[B]) -> Bool {
  self.state.done
}

///|
/// 帧链还在不在：常驻条与到点之后都应为 false（没有空转的定时器）。
pub fn[B] UiToast::ticking(self : UiToast[B]) -> Bool {
  self.state.ticker.running()
}

///|
/// 到点回调。后挂的覆盖先挂的；只响一次。
pub fn[B] UiToast::on_dismiss(
  self : UiToast[B],
  f : () -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
/// 换文案并重画（单行条宽度不变）。
pub fn[B : @moonui.Backend] UiToast::set_text(
  self : UiToast[B],
  text : String,
) -> Unit raise @moonui.UiError {
  if self.state.text == text {
    return
  }
  self.state.text = text
  self.widget.repaint()
}

///|
/// 换语义色。
pub fn[B : @moonui.Backend] UiToast::set_tone(
  self : UiToast[B],
  tone : UiTone,
) -> Unit raise @moonui.UiError {
  if self.state.tone == tone {
    return
  }
  self.state.tone = tone
  self.widget.repaint()
}

///|
/// 换令牌：字号变了条目高也要重算。
pub fn[B : @moonui.Backend] UiToast::set_theme(
  self : UiToast[B],
  theme : UiTheme,
) -> Unit raise @moonui.UiError {
  self.state.theme = theme
  self.state.metrics = theme.metrics(self.state.size)
  self.widget.set_custom_size(
    @moonui.LogicalSize(self.state.width, ui_toast_height(self.state)),
  )
  self.widget.repaint()
}
