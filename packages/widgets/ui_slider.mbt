///|
/// `UiSlider`——自绘滑块（`T358` 第二档 B）。
///
/// 为什么不包原生 trackbar：Win32 的 `mscts_trackbar32` / mac 的 `NSSlider` /
/// GTK 的 `GtkScale` 各画各的脸，轨道粗细、钮的圆角、悬停反馈都不归这套令牌。
/// 自绘之后，轨道、已填那一截、钮与焦点环全走 `DrawList`，三端一份画法。
///
/// 为什么**不需要** Core 的指针捕获口：`T351` 记过"缺鼠标捕获会话"，`begin_drag`
/// 的语义是"源控件不再收移动"（拖放），帮不了跟手拖动。但 Windows 的自绘面在
/// `WM_LBUTTONDOWN` 就 `SetCapture`（T111），mac 那半把 `LeftMouseDragged` /
/// `LeftMouseUp` 的 owner 强制回按下的那块面（`T313` 同族），Core 又按事件自带的
/// target 路由——于是"按下后坐标一律派给起点控件直到抬起"在两只真后端上**已经
/// 成立**。这里只需在控件内记按下点与起点值，拖动中按位移重算值（不是逐帧累加，
/// 免得把帧率算进结果）。Linux 那半的自绘面目前不产 `MouseMove`（kind 2），拖动
/// 只能点、跟不了手，归 `T355` 的跨端验收。
struct SliderState {
  mut theme : UiTheme
  /// 当前值（在 min..max 内）
  mut value : Double
  min : Double
  max : Double
  /// 按下那刻的局部 x 与当时的值——拖动期间按"起点 + 位移"算，不逐帧累加
  mut dragging : Bool
  mut press_x : Double
  mut press_value : Double
  it : UiInteract
  mut enabled : Bool
  mut handler : ((Double) -> Unit raise @moonui.UiError)?
}

///|
const UI_SLIDER_TRACK_H : Double = 6.0

///|
/// 钮的半径：按控件高取 0.28，再夹在 6..14。高 32 的档约 9px， proportion 合适。
fn ui_slider_thumb_r(h : Double) -> Double {
  let r = h * 0.28
  if r < 6.0 {
    6.0
  } else if r > 14.0 {
    14.0
  } else {
    r
  }
}

///|
/// 值 → 0..1 比例（`min == max` 时整条轨道算 0，不再除零）。
pub fn ui_slider_fraction(value : Double, min : Double, max : Double) -> Double {
  let span = max - min
  if span <= 0.0 {
    return 0.0
  }
  let f = (value - min) / span
  if f < 0.0 {
    0.0
  } else if f > 1.0 {
    1.0
  } else {
    f
  }
}

///|
fn ui_slider_clamp(st : SliderState, v : Double) -> Double {
  if v < st.min {
    st.min
  } else if v > st.max {
    st.max
  } else {
    v
  }
}

///|
/// 画一条滑块：凹槽 + 已填那一截 + 圆钮，悬停/按下按比例混色。
fn ui_paint_slider(
  st : SliderState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let t = st.theme
  let cy = h / 2.0
  let tr = UI_SLIDER_TRACK_H
  let ty = cy - tr / 2.0
  // 凹槽
  ui_paint_fill(dl, 0.0, ty, w, tr, tr / 2.0, t.track)
  let frac = ui_slider_fraction(st.value, st.min, st.max)
  let r = ui_slider_thumb_r(h)
  let inset = r
  let span = w - 2.0 * inset
  let cx = if span > 0.0 { inset + frac * span } else { w / 2.0 }
  // 已填那一截（宽度到钮心，下限 0）
  if cx > 0.0 {
    ui_paint_fill(dl, 0.0, ty, cx, tr, tr / 2.0, t.accent)
  }
  // 钮：accent → hover → active 按两档强度混。禁用态用灰字色。
  let mut thumb = ui_mix(t.accent, t.accent_hover, st.it.hover_amt)
  thumb = ui_mix(thumb, t.accent_active, st.it.press_amt)
  if !st.enabled {
    thumb = t.text_disabled
  }
  ui_paint_dot(dl, cx, cy, r, thumb)
  if st.it.focused && st.enabled {
    let fr = r + 2.0
    ui_paint_focus_ring(
      dl,
      cx - fr,
      cy - fr,
      fr * 2.0,
      fr * 2.0,
      fr,
      t.focus_ring,
    )
  }
}

///|
/// 鼠标事件的点（父局部）→ 控件局部 x（与 ui_strip_local_x 同一口径）。
fn[B] ui_slider_local_x(
  w : @moonui.Widget[B],
  p : @moonui.LogicalPoint,
) -> Double {
  p.x - w.frame().origin.x
}

///|
/// 提交一个新值：夹在 min..max，值变了才回调，但每次都重画（按下那次的视觉
/// 要收回去，即便值没变）。
fn[B : @moonui.Backend] ui_slider_commit(
  w : @moonui.Widget[B],
  st : SliderState,
  raw : Double,
) -> Unit raise @moonui.UiError {
  let v = ui_slider_clamp(st, raw)
  let changed = v != st.value
  st.value = v
  w.repaint()
  if changed {
    match st.handler {
      Some(f) => f(v)
      None => ()
    }
  }
}

///|
/// 指针与键盘账：
///  - 左键按下记锚点（不立刻跳值——原生滑块按住钮不该让钮瞬移到指针下）；
///  - 拖动中按"起点值 + 位移/轨道长 × 值域"重算，与帧率无关；
///  - 左右键步进 1/20 值域，Home/End 到两端（与分段控件不同，滑块到端不环绕）。
fn[B : @moonui.Backend] ui_slider_watch(
  w : @moonui.Widget[B],
  st : SliderState,
) -> Unit raise @moonui.UiError {
  let _ = w.on(
    fn(e) {
      match e {
        @moonui.MouseDown(_, @moonui.Left, _, _) => true
        @moonui.MouseMove(_, _) => true
        @moonui.MouseUp(_, @moonui.Left, _, _) => true
        @moonui.KeyDown(_, kp) =>
          kp.key == "Left" ||
          kp.key == "Right" ||
          kp.key == "Home" ||
          kp.key == "End"
        _ => false
      }
    },
    fn(e) raise @moonui.UiError {
      match e {
        @moonui.MouseDown(_, _, p, _) =>
          if st.enabled && !st.dragging {
            st.dragging = true
            st.press_x = ui_slider_local_x(w, p)
            st.press_value = st.value
          }
        @moonui.MouseMove(_, p) =>
          if st.dragging {
            let fw = w.frame().size.width
            let span = fw - 2.0 * ui_slider_thumb_r(w.frame().size.height)
            if span > 0.0 {
              let dx = ui_slider_local_x(w, p) - st.press_x
              let delta = dx / span * (st.max - st.min)
              ui_slider_commit(w, st, st.press_value + delta)
            }
          }
        @moonui.MouseUp(_, _, _, _) =>
          if st.dragging {
            st.dragging = false
            w.repaint()
          }
        @moonui.KeyDown(_, kp) =>
          if st.enabled {
            let step = (st.max - st.min) / 20.0
            if kp.key == "Left" {
              ui_slider_commit(w, st, st.value - step)
            } else if kp.key == "Right" {
              ui_slider_commit(w, st, st.value + step)
            } else if kp.key == "Home" {
              ui_slider_commit(w, st, st.min)
            } else if kp.key == "End" {
              ui_slider_commit(w, st, st.max)
            }
          }
        _ => ()
      }
    },
  )
}

///|
/// 自绘滑块。值域 `min..max`（`min >= max` 时按整条轨道一个值处理），`value`
/// 会被夹进值域；`width` 是轨道长宽，`size` 决定高度与圆角那档。
pub struct UiSlider[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : SliderState
}

///|
pub fn[B : @moonui.Backend] UiSlider::UiSlider(
  backend : B,
  value~ : Double = 0.0,
  min~ : Double = 0.0,
  max~ : Double = 100.0,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
  width~ : Double = 200.0,
  enabled~ : Bool = true,
  app~ : @moonui.App[B]? = None,
) -> UiSlider[B] raise @moonui.UiError {
  let metrics = theme.metrics(size)
  let state = SliderState::{
    theme,
    value: 0.0,
    min,
    max,
    dragging: false,
    press_x: 0.0,
    press_value: 0.0,
    it: UiInteract::new(enabled~),
    enabled,
    handler: None,
  }
  state.value = ui_slider_clamp(state, value)
  let widget = @moonui.Widget::custom(
    backend,
    @moonui.LogicalSize(if width > 0.0 { width } else { 200.0 }, metrics.height),
    fn(dl, env) { ui_paint_slider(state, dl, env) },
    focusable=true,
  )
  ui_watch_state(widget, state.it, app~)
  ui_slider_watch(widget, state)
  { backend, widget, state, }
}

///|
pub fn[B] UiSlider::widget(self : UiSlider[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
pub fn[B] UiSlider::value(self : UiSlider[B]) -> Double {
  self.state.value
}

///|
/// 当前是否在跟手拖动中（判据与画册读回用）。
pub fn[B] UiSlider::dragging(self : UiSlider[B]) -> Bool {
  self.state.dragging
}

///|
/// 程序设值：夹在值域内并重画，与拖动共用提交账（值变了才回调）。
pub fn[B : @moonui.Backend] UiSlider::set_value(
  self : UiSlider[B],
  value : Double,
) -> Unit raise @moonui.UiError {
  ui_slider_commit(self.widget, self.state, value)
}

///|
pub fn[B] UiSlider::on_change(
  self : UiSlider[B],
  f : (Double) -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
/// 开关使能：禁用后不接指针/键盘，钮画成灰的那档。
pub fn[B : @moonui.Backend] UiSlider::set_enabled(
  self : UiSlider[B],
  value : Bool,
) -> Unit raise @moonui.UiError {
  self.state.enabled = value
  self.state.it.enabled = value
  self.widget.repaint()
}

///|
/// 换令牌并重画（滑块没有按文案量的固有尺寸，字号变了不影响这块几何）。
pub fn[B : @moonui.Backend] UiSlider::set_theme(
  self : UiSlider[B],
  theme : UiTheme,
) -> Unit raise @moonui.UiError {
  self.state.theme = theme
  self.widget.repaint()
}
