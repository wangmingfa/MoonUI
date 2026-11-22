///|
/// `UiCheckbox` / `UiToggle`——自绘勾选框与开关（`T350`）。
///
/// 原生勾选框的方框、勾、开关的圆钮都由系统画（Win32 是 `BS_AUTOCHECKBOX` 与
/// 自画的 owner-draw 开关，macOS 是 `NSButton` 的 bezel），皮肤通道改不了它的
/// 造型、也不给悬停态——这正是"控件看着不像一套"最刺眼的两处。自绘之后，方框
/// 圆角、勾的粗细、开关的轨道与钮都归这套令牌。
///
/// 两只共用同一条交互链：整行可点（不只方框那一小块）、空格/回车各算一次、
/// 悬停/按下/焦点各换一档色。区别只在"选中态长什么样"：勾选框画勾、开关画
/// 一颗钮滑过去。

///|
/// 勾选框的可变账。
struct CheckState {
  theme : UiTheme
  metrics : UiMetrics
  mut label : String
  mut checked : Bool
  it : UiInteract
  mut handler : ((Bool) -> Unit raise @moonui.UiError)?
}

///|
/// 自绘勾选框：左侧方框 + 右侧文案，整行是点击区。
pub struct UiCheckbox[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : CheckState
}

///|
/// 方框边长：跟字号走（md 18、sm 17、lg 20）。比字号大 5，是"字高之外再留
/// 一圈呼吸"，与主流设计系统的 16~20 那档一致。
fn ui_check_box(metrics : UiMetrics) -> Double {
  metrics.font + 5.0
}

///|
/// 勾选框的固有尺寸：方框 + 间距 + 文案宽，高取控件档高（点击区够大）。
fn[B : @moonui.Backend] ui_check_size(
  backend : B,
  label : String,
  metrics : UiMetrics,
) -> @moonui.LogicalSize {
  let box = ui_check_box(metrics)
  let (tw, _) = ui_measure(backend, label, metrics.font, false)
  @moonui.LogicalSize(box + metrics.gap + tw, metrics.height)
}

///|
/// 画一颗勾选框。
fn ui_paint_checkbox(
  st : CheckState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let t = st.theme
  let s = ui_check_box(st.metrics)
  let by = (h - s) / 2.0
  let r = s * 0.28
  let it = st.it
  let enabled = it.enabled
  let checked = st.checked
  // 底：选中是主色（悬停/按下各深一档），未选是面色（悬停浮一格）
  let fill = if checked {
    if !enabled {
      ui_mix(t.accent, t.surface, 0.72)
    } else if it.pressed {
      t.accent_active
    } else if it.hovered {
      t.accent_hover
    } else {
      t.accent
    }
  } else if !enabled {
    t.surface
  } else if it.hovered {
    t.surface_hover
  } else {
    t.surface
  }
  ui_paint_fill(dl, 0.0, by, s, s, r, fill)
  if !checked {
    // 未选才有边：选中的方框整块是主色，再描一圈同色边只是把角磨钝
    let edge = if !enabled {
      t.border
    } else if it.hovered {
      t.border_strong
    } else {
      t.border
    }
    ui_paint_stroke(dl, 0.0, by, s, s, r, 0.5, 1.0, edge)
  }
  if checked {
    // 勾：两段折线。线宽 s×0.13（18px 的框 → 2.3px），落点刻意偏下——按几何
    // 中心画出来的勾视觉重心会往下掉，抬高一格才看着正。
    let ink = if enabled { t.on_accent } else { t.text_disabled }
    let lw = s * 0.13
    dl.line(s * 0.26, by + s * 0.52, s * 0.43, by + s * 0.69, width=lw, rgb=ink)
    dl.line(s * 0.43, by + s * 0.69, s * 0.75, by + s * 0.32, width=lw, rgb=ink)
  }
  if it.focused && enabled {
    // 焦点环套在方框外 2px：贴着方框描会和边框糊成一条，离远了又不像它的焦点
    ui_paint_focus_ring(
      dl,
      -2.0,
      by - 2.0,
      s + 4.0,
      s + 4.0,
      r + 2.0,
      t.focus_ring,
    )
  }
  draw_fitted_text(
    dl,
    env,
    st.label,
    s + st.metrics.gap,
    w - s - st.metrics.gap,
    0.0,
    h,
    st.metrics.font,
    false,
    if enabled {
      t.text
    } else {
      t.text_disabled
    },
    false,
  )
}

///|
/// 造一颗勾选框。
pub fn[B : @moonui.Backend] UiCheckbox::UiCheckbox(
  backend : B,
  label : String,
  checked~ : Bool = false,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
  enabled~ : Bool = true,
) -> UiCheckbox[B] raise @moonui.UiError {
  let metrics = theme.metrics(size)
  let state = CheckState::{
    theme,
    metrics,
    label,
    checked,
    it: UiInteract::new(enabled~),
    handler: None,
  }
  let widget = @moonui.Widget::custom(
    backend,
    ui_check_size(backend, label, metrics),
    fn(dl, env) { ui_paint_checkbox(state, dl, env) },
    focusable=true,
  )
  ui_watch_state(widget, state.it)
  let _ = widget.on_click(fn() raise @moonui.UiError {
    ui_check_toggle(widget, state)
  })
  let _ = widget.on(
    fn(e) {
      match e {
        @moonui.KeyDown(_, _) => true
        _ => false
      }
    },
    fn(e) raise @moonui.UiError {
      match e {
        @moonui.KeyDown(_, k) =>
          if k.key == " " || k.key == "Enter" {
            ui_check_toggle(widget, state)
          }
        _ => ()
      }
    },
  )
  { backend, widget, state, }
}

///|
/// 翻一次的唯出口：用户点/按空格都走这里（程序设值走 `set_checked`，不回声）。
fn[B : @moonui.Backend] ui_check_toggle(
  w : @moonui.Widget[B],
  st : CheckState,
) -> Unit raise @moonui.UiError {
  if !st.it.enabled {
    return
  }
  let next = !st.checked
  st.checked = next
  // 先改状态再重画：绘制回调读的是这份状态，反过来画出来的还是旧的
  w.repaint()
  match st.handler {
    Some(f) => f(next)
    None => ()
  }
}

///|
pub fn[B] UiCheckbox::widget(self : UiCheckbox[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
pub fn[B] UiCheckbox::checked(self : UiCheckbox[B]) -> Bool {
  self.state.checked
}

///|
pub fn[B] UiCheckbox::label(self : UiCheckbox[B]) -> String {
  self.state.label
}

///|
/// 勾选变化的回调，携带变化后的值。
pub fn[B] UiCheckbox::on_change(
  self : UiCheckbox[B],
  f : (Bool) -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
/// 程序设值：改画面与状态，**不**触发 `on_change`（与 `set_checked` 同一条
/// 规矩：setter 不回声）。
pub fn[B : @moonui.Backend] UiCheckbox::set_checked(
  self : UiCheckbox[B],
  checked : Bool,
) -> Unit raise @moonui.UiError {
  if self.state.checked == checked {
    return
  }
  self.state.checked = checked
  self.widget.repaint()
}

///|
/// 换文案并重算宽度。
pub fn[B : @moonui.Backend] UiCheckbox::set_label(
  self : UiCheckbox[B],
  label : String,
) -> Unit raise @moonui.UiError {
  if self.state.label == label {
    return
  }
  self.state.label = label
  self.widget.set_custom_size(
    ui_check_size(self.backend, label, self.state.metrics),
  )
  self.widget.repaint()
}

///|
/// 使能开关。
pub fn[B : @moonui.Backend] UiCheckbox::set_enabled(
  self : UiCheckbox[B],
  enabled : Bool,
) -> Unit raise @moonui.UiError {
  if self.state.it.enabled == enabled {
    return
  }
  self.state.it.enabled = enabled
  self.widget.repaint()
}

///|
/// 开关的可变账。
struct ToggleState {
  theme : UiTheme
  metrics : UiMetrics
  label : String
  mut checked : Bool
  it : UiInteract
  mut handler : ((Bool) -> Unit raise @moonui.UiError)?
}

///|
/// 自绘开关（iOS 那种滑钮）。
pub struct UiToggle[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : ToggleState
}

///|
/// 轨道尺寸：高 = 档高 − 10（md 22），宽 = 高的 1.75 倍（≈38）。这个比例是
/// 开关"一眼看出能滑"的常用值，窄了像勾选框、宽了像进度条。
fn ui_toggle_track(metrics : UiMetrics) -> (Double, Double) {
  let h = metrics.height - 10.0
  let hh = if h < 18.0 { 18.0 } else { h }
  (hh * 1.75, hh)
}

///|
fn[B : @moonui.Backend] ui_toggle_size(
  backend : B,
  label : String,
  metrics : UiMetrics,
) -> @moonui.LogicalSize {
  let (tw, th) = ui_toggle_track(metrics)
  let (lw, _) = ui_measure(backend, label, metrics.font, false)
  let extra = if label == "" { 0.0 } else { metrics.gap + lw }
  @moonui.LogicalSize(
    tw + extra,
    if th > metrics.height {
      th
    } else {
      metrics.height
    },
  )
}

///|
/// 画一只开关。
fn ui_paint_toggle(
  st : ToggleState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let t = st.theme
  let (tw, th) = ui_toggle_track(st.metrics)
  let ty = (h - th) / 2.0
  let it = st.it
  let enabled = it.enabled
  // 轨道：开是主色（悬停/按下各深一档），关是灰槽
  let fill = if st.checked {
    if !enabled {
      ui_mix(t.accent, t.surface, 0.72)
    } else if it.pressed {
      t.accent_active
    } else if it.hovered {
      t.accent_hover
    } else {
      t.accent
    }
  } else if !enabled {
    ui_mix(t.track, t.surface, 0.5)
  } else if it.hovered {
    ui_mix(t.track, t.text, 0.10)
  } else {
    t.track
  }
  ui_paint_fill(dl, 0.0, ty, tw, th, th / 2.0, fill)
  // 钮：轨道内缩 2px 的圆，开启时贴右端
  let knob_r = th / 2.0 - 2.0
  let knob_x = if st.checked { tw - knob_r - 2.0 } else { knob_r + 2.0 }
  let knob = if !enabled { ui_mix(t.surface, t.bg, 0.35) } else { t.surface }
  // 钮的投影靠"先铺一圈半透明的深色底"模拟——`DrawCmd::Shadow` 要跟着一次
  // 填充走，在钮上用它会把轨道也带上；一圈稍大的深点圆更省也更准。
  ui_paint_dot(
    dl,
    knob_x,
    ty + th / 2.0 + 0.75,
    knob_r + 0.75,
    ui_mix(fill, 0x000000, 0.18),
  )
  ui_paint_dot(dl, knob_x, ty + th / 2.0, knob_r, knob)
  if it.focused && enabled {
    ui_paint_focus_ring(
      dl,
      -2.0,
      ty - 2.0,
      tw + 4.0,
      th + 4.0,
      (th + 4.0) / 2.0,
      t.focus_ring,
    )
  }
  if st.label != "" {
    draw_fitted_text(
      dl,
      env,
      st.label,
      tw + st.metrics.gap,
      w - tw - st.metrics.gap,
      0.0,
      h,
      st.metrics.font,
      false,
      if enabled {
        t.text
      } else {
        t.text_disabled
      },
      false,
    )
  }
}

///|
/// 造一只开关。
pub fn[B : @moonui.Backend] UiToggle::UiToggle(
  backend : B,
  label : String,
  checked~ : Bool = false,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
  enabled~ : Bool = true,
) -> UiToggle[B] raise @moonui.UiError {
  let metrics = theme.metrics(size)
  let state = ToggleState::{
    theme,
    metrics,
    label,
    checked,
    it: UiInteract::new(enabled~),
    handler: None,
  }
  let widget = @moonui.Widget::custom(
    backend,
    ui_toggle_size(backend, label, metrics),
    fn(dl, env) { ui_paint_toggle(state, dl, env) },
    focusable=true,
  )
  ui_watch_state(widget, state.it)
  let _ = widget.on_click(fn() raise @moonui.UiError {
    ui_toggle_fire(widget, state)
  })
  let _ = widget.on(
    fn(e) {
      match e {
        @moonui.KeyDown(_, _) => true
        _ => false
      }
    },
    fn(e) raise @moonui.UiError {
      match e {
        @moonui.KeyDown(_, k) =>
          if k.key == " " || k.key == "Enter" {
            ui_toggle_fire(widget, state)
          }
        _ => ()
      }
    },
  )
  { backend, widget, state, }
}

///|
fn[B : @moonui.Backend] ui_toggle_fire(
  w : @moonui.Widget[B],
  st : ToggleState,
) -> Unit raise @moonui.UiError {
  if !st.it.enabled {
    return
  }
  let next = !st.checked
  st.checked = next
  w.repaint()
  match st.handler {
    Some(f) => f(next)
    None => ()
  }
}

///|
pub fn[B] UiToggle::widget(self : UiToggle[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
pub fn[B] UiToggle::checked(self : UiToggle[B]) -> Bool {
  self.state.checked
}

///|
pub fn[B] UiToggle::on_change(
  self : UiToggle[B],
  f : (Bool) -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
pub fn[B : @moonui.Backend] UiToggle::set_checked(
  self : UiToggle[B],
  checked : Bool,
) -> Unit raise @moonui.UiError {
  if self.state.checked == checked {
    return
  }
  self.state.checked = checked
  self.widget.repaint()
}

///|
pub fn[B : @moonui.Backend] UiToggle::set_enabled(
  self : UiToggle[B],
  enabled : Bool,
) -> Unit raise @moonui.UiError {
  if self.state.it.enabled == enabled {
    return
  }
  self.state.it.enabled = enabled
  self.widget.repaint()
}
