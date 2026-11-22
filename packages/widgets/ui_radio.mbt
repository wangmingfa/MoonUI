///|
/// `UiRadioGroup`——自绘单选组（`T350`）。
///
/// 原生单选钮（`Widget::radio_buttons`）是一整排系统画的小圆点，造型、间距、
/// 悬停都没有话语权，而且 macOS 与 Windows 两边的圆点大小本来就不一样——同
/// 一个表单换平台就换了张脸。自绘之后圆环粗细、选中点的直径、行高都由令牌定。
///
/// 形状：一组选项 + 一个"当前选中"的下标；每一行是一块独立的 `Widget::custom`
/// （点击区 = 整行，含文案），共享同一份 `RadioState`——点哪一行都改同一格状态，
/// 再把**所有行**重画一遍（选中点要从旧行消失，不只在新行出现）。
///
/// 程序设值（`set_selected`）不触发 `on_change`，与 `Widget::set_checked` 和
/// `RadioGroup`（`components.mbt`）同一条规矩：setter 不回声。

///|
/// 单选组的共享账。行与行之间只有这一份状态，绘制回调各自捕获 `(state, 下标)`。
struct RadioState {
  mut theme : UiTheme
  mut metrics : UiMetrics
  options : Array[String]
  /// 当前选中下标；`-1` = 没选中（沿 `RadioGroup` 的哨兵）
  mut selected : Int32
  mut handler : ((Int32) -> Unit raise @moonui.UiError)?
}

///|
/// 自绘单选组。
pub struct UiRadioGroup[B] {
  backend : B
  state : RadioState
  rows : Array[@moonui.Widget[B]]
  root : @moonui.Widget[B]
}

///|
/// 圆环直径：与勾选框的方框同一档（字号 + 5），两组控件并排时大小看着齐。
fn ui_radio_dot(metrics : UiMetrics) -> Double {
  metrics.font + 5.0
}

///|
/// 一行的固有尺寸：圆 + 间距 + 文案。
fn[B : @moonui.Backend] ui_radio_size(
  backend : B,
  label : String,
  metrics : UiMetrics,
) -> @moonui.LogicalSize {
  let s = ui_radio_dot(metrics)
  let (tw, _) = ui_measure(backend, label, metrics.font, false)
  @moonui.LogicalSize(s + metrics.gap + tw, metrics.height)
}

///|
/// 画一行单选。`picked` 由共享状态下标与自己的下标比出来，绘制回调不读下标
/// 之外的任何全局——一行只知道自己选没选。
fn ui_paint_radio_row(
  st : RadioState,
  it : UiInteract,
  index : Int32,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let t = st.theme
  let s = ui_radio_dot(st.metrics)
  let cx = s / 2.0
  let cy = h / 2.0
  let picked = st.selected == index
  let enabled = it.enabled
  let ring = if !enabled {
    t.border
  } else if picked {
    t.accent
  } else if it.hovered {
    t.border_strong
  } else {
    t.border_strong
  }
  // 未选时的底：悬停浮一层浅底，让"这一行可以点"看得出来
  if !picked && enabled && it.hovered {
    ui_paint_fill(dl, 0.0, 0.0, w, h, st.metrics.radius, t.surface_hover)
  }
  // 圆环用描边弧画（半径收半个线宽）：`fill_rect` 拼出来的圆边是方的
  let lw = 1.5
  dl.stroke_arc(cx, cy, s / 2.0 - lw / 2.0, 0.0, 360.0, width=lw, rgb=ring)
  if picked {
    let r = (s / 2.0 - lw) * 0.52
    let ink = if !enabled {
      ui_mix(t.accent, t.surface, 0.6)
    } else if it.hovered {
      t.accent_hover
    } else {
      t.accent
    }
    ui_paint_dot(dl, cx, cy, r, ink)
  }
  if it.focused && enabled {
    let r = s / 2.0 + 2.0
    dl.stroke_arc(cx, cy, r, 0.0, 360.0, width=1.5, rgb=t.focus_ring)
  }
  draw_fitted_text(
    dl,
    env,
    st.options[index],
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
/// 造一组单选。`selected` 越界按"没选中"处理（与 `RadioGroup` 一致）。
///
/// `horizontal=true` 排成一行（表单里"性别/尺寸"这种短选项），默认竖排。
pub fn[B : @moonui.Backend] UiRadioGroup::UiRadioGroup(
  backend : B,
  options : Array[String],
  selected~ : Int32 = 0,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
  enabled~ : Bool = true,
  horizontal~ : Bool = false,
) -> UiRadioGroup[B] raise @moonui.UiError {
  let metrics = theme.metrics(size)
  let init = if selected >= 0 && selected < options.length() {
    selected
  } else {
    -1
  }
  let state = RadioState::{
    theme,
    metrics,
    options,
    selected: init,
    handler: None,
  }
  let rows : Array[@moonui.Widget[B]] = []
  for i, option in options {
    let it = UiInteract::new(enabled~)
    let row = @moonui.Widget::custom(
      backend,
      ui_radio_size(backend, option, metrics),
      fn(dl, env) { ui_paint_radio_row(state, it, i, dl, env) },
      focusable=true,
    )
    ui_watch_state(row, it)
    let _ = row.on_click(fn() raise @moonui.UiError {
      ui_radio_pick(rows, state, it, i)
    })
    let _ = row.on(
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
              ui_radio_pick(rows, state, it, i)
            }
          _ => ()
        }
      },
    )
    rows.push(row)
  }
  let root = if horizontal {
    @moonui.Widget::row(backend, metrics.gap + 8.0, rows)
  } else {
    @moonui.Widget::column(backend, 2.0, rows)
  }
  { backend, state, rows, root, }
}

///|
/// 用户选中某一行：改下标、重画**所有**行（旧行的点要消失）、再回调。
fn[B : @moonui.Backend] ui_radio_pick(
  rows : Array[@moonui.Widget[B]],
  st : RadioState,
  it : UiInteract,
  index : Int32,
) -> Unit raise @moonui.UiError {
  if !it.enabled {
    return
  }
  if st.selected == index {
    // 点已选中的那行：不发回调（"值没变"不该通知一次）
    return
  }
  st.selected = index
  for row in rows {
    row.repaint()
  }
  match st.handler {
    Some(f) => f(index)
    None => ()
  }
}

///|
/// 组的根（Column 或 Row）：挂进容器或 `Window::set_content` 都用它。
pub fn[B] UiRadioGroup::view(self : UiRadioGroup[B]) -> @moonui.Widget[B] {
  self.root
}

///|
pub fn[B] UiRadioGroup::selected(self : UiRadioGroup[B]) -> Int32 {
  self.state.selected
}

///|
pub fn[B] UiRadioGroup::selected_text(self : UiRadioGroup[B]) -> String {
  let i = self.state.selected
  if i >= 0 && i < self.state.options.length() {
    self.state.options[i]
  } else {
    ""
  }
}

///|
pub fn[B] UiRadioGroup::on_change(
  self : UiRadioGroup[B],
  f : (Int32) -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
/// 程序设值：夹到合法下标（越界不动），重画全部行，不触发 `on_change`。
pub fn[B : @moonui.Backend] UiRadioGroup::set_selected(
  self : UiRadioGroup[B],
  index : Int32,
) -> Unit raise @moonui.UiError {
  if index < 0 || index >= self.state.options.length() {
    return
  }
  if self.state.selected == index {
    return
  }
  self.state.selected = index
  for row in self.rows {
    row.repaint()
  }
}

///|
/// 换一套令牌：行的尺寸按新字号重算（圆与文案都跟着变）。
pub fn[B : @moonui.Backend] UiRadioGroup::set_theme(
  self : UiRadioGroup[B],
  theme : UiTheme,
  size~ : UiSize = UiMedium,
) -> Unit raise @moonui.UiError {
  self.state.theme = theme
  self.state.metrics = theme.metrics(size)
  for i, row in self.rows {
    row.set_custom_size(
      ui_radio_size(self.backend, self.state.options[i], self.state.metrics),
    )
    row.repaint()
  }
}
