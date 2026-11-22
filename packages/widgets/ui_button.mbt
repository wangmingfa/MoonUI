///|
/// `UiButton`——自绘按钮（`T350`）。
///
/// 为什么不用 `Widget::button`：原生 push button 的脸由系统主题画（Win32 是
/// comctl32 v6 的蓝色渐变、macOS 是 `NSButton` 的 bezel），§32 明确允许原生
/// 控件完全不读样式——所以"主按钮 / 次按钮 / 幽灵按钮 / 危险按钮"这四档在
/// 原生控件上**画不出来**，只能自绘。这也是这套控件存在的第一理由：不是嫌
/// 系统难看，是系统不让改。
///
/// 画法很薄：一块圆角实底 + 一行居中的字 + 可选的 1px 边 + 焦点环，四档共用
/// 同一段代码、只换三格颜色（底/字/边）。悬停与按下各换一档底色，状态来自
/// `UiInteract`（事件翻面 → 重画），不是后端替我们画的。
///
/// 键盘：`focusable` 打开（Tab 能停上来），空格与回车各算一次点击——自绘面
/// 没有系统默认按钮那套翻译，这一条得自己接，否则键盘用户点不动它。
///
/// 坐标一律控件局部逻辑像素；尺寸由文案量出来（`ui_measure`），
/// `set_text` 之后按新字宽重算——按钮不会因为改个词就截字。

///|
/// 四档按钮。语义与 Element / Ant 的同名档一致：
/// - `UiPrimary`：页面上唯一那个"该点的"（提交/保存/确定）；
/// - `UiSecondary`：与主按钮并列的次选（取消/返回）；
/// - `UiGhost`：无底无边，悬停才浮出一层（工具栏、卡片角上的"更多"）；
/// - `UiDanger`：删除/清空这类不可逆动作。
#derive(Debug, Eq)
pub(all) enum UiButtonKind {
  UiPrimary
  UiSecondary
  UiGhost
  UiDanger
}

///|
/// 按钮的可变账：画法与尺寸都要读它，`set_*` 改完重画（必要时连尺寸一起改）。
struct BtnState {
  mut theme : UiTheme
  /// 尺寸档（换主题时要按同一档重算度量，不能写死 Medium）
  size : UiSize
  mut metrics : UiMetrics
  mut label : String
  mut kind : UiButtonKind
  it : UiInteract
  mut handler : (() -> Unit raise @moonui.UiError)?
}

///|
/// 自绘按钮。`UiButton(b, "保存")` 之后用 `widget()` 拿控件进布局。
pub struct UiButton[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : BtnState
}

///|
/// 按文案算固有尺寸：字宽 + 两侧内缩，且不窄于两倍高度（"确定"两个字也撑成
/// 一颗方正的按钮，而不是一颗药丸）。
fn[B : @moonui.Backend] ui_button_size(
  backend : B,
  label : String,
  metrics : UiMetrics,
) -> @moonui.LogicalSize {
  let (tw, _) = ui_measure(backend, label, metrics.font, true)
  let want = tw + metrics.pad_x * 2.0
  let min_w = metrics.height * 2.0
  @moonui.LogicalSize(if want < min_w { min_w } else { want }, metrics.height)
}

///|
/// 四档 × 四态 → (底, 字, 边)。返回的底/边是 `Option`：幽灵按钮静息时
/// 没有底（自绘面是透明的，露出来的是父容器的底色），边只有次级按钮有。
fn ui_button_colors(st : BtnState) -> (Int32?, Int32, Int32?) {
  let t = st.theme
  let it = st.it
  // 禁用先判：禁用态的悬停/按下都不该改颜色（指针在它上面滑动不是"可用"）
  if !it.enabled {
    let fill = match st.kind {
      UiPrimary => Some(ui_mix(t.accent, t.surface, 0.72))
      UiDanger => Some(ui_mix(t.danger, t.surface, 0.72))
      UiSecondary => Some(t.surface)
      UiGhost => None
    }
    let border = match st.kind {
      UiSecondary => Some(t.border)
      _ => None
    }
    return (fill, t.text_disabled, border)
  }
  match st.kind {
    UiPrimary => {
      let base = if it.pressed {
        t.accent_active
      } else if it.hovered {
        t.accent_hover
      } else {
        t.accent
      }
      (Some(base), t.on_accent, None)
    }
    UiDanger => {
      let base = if it.pressed {
        ui_darken(t.danger, 0.16)
      } else if it.hovered {
        ui_darken(t.danger, 0.08)
      } else {
        t.danger
      }
      (Some(base), t.on_accent, None)
    }
    UiSecondary => {
      let base = if it.pressed {
        t.surface_active
      } else if it.hovered {
        t.surface_hover
      } else {
        t.surface
      }
      let border = if it.hovered || it.pressed {
        t.border_strong
      } else {
        t.border
      }
      (Some(base), t.text, Some(border))
    }
    UiGhost => {
      let base = if it.pressed {
        Some(t.surface_active)
      } else if it.hovered {
        Some(t.surface_hover)
      } else {
        None
      }
      (base, t.text, None)
    }
  }
}

///|
/// 画一颗按钮。纯函数：只读状态、只往清单里写命令。
fn ui_paint_button(
  st : BtnState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let r = ui_clamp_radius(st.metrics.radius, w, h)
  let (fill, fg, border) = ui_button_colors(st)
  match (fill, border) {
    // 有边的档走**两层填充**：整块先涂边色，再内缩 1px 涂底色。
    //
    // 为什么不用 `stroke_rect`（`T353`）：描边是"路径 + 画笔"，画笔以路径为
    // 中心线向两侧各摊半个笔宽，而描边路径本身又被内缩了 0.5、半径减了 0.5
    // ——三次取整（逻辑→物理 int、千分比）之后，四角的可见弧比同样半径的实心
    // 块长出约 2px。截图上一排按钮里"取消"的角明显比"保存/删除"更圆，就是这
    // 笔账。两层填充两者共用同一套圆角算术，同心是几何上的必然。
    (Some(c), Some(bc)) => {
      ui_paint_fill(dl, 0.0, 0.0, w, h, r, bc)
      let ri = r - 1.0
      ui_paint_fill(
        dl,
        1.0,
        1.0,
        w - 2.0,
        h - 2.0,
        if ri > 0.0 {
          ri
        } else {
          0.0
        },
        c,
      )
    }
    (Some(c), None) => ui_paint_fill(dl, 0.0, 0.0, w, h, r, c)
    // 幽灵档静息时没有底，只可能没有边（四档里唯一的组合），什么都不画
    (None, Some(bc)) => ui_paint_stroke(dl, 0.0, 0.0, w, h, r, 0.5, 1.0, bc)
    (None, None) => ()
  }
  if st.it.focused && st.it.enabled {
    ui_paint_focus_ring(dl, 0.0, 0.0, w, h, r, st.theme.focus_ring)
  }
  ui_paint_center_text(
    dl,
    env,
    st.label,
    st.metrics.pad_x,
    0.0,
    w - st.metrics.pad_x * 2.0,
    h,
    st.metrics.font,
    true,
    fg,
  )
}

///|
/// 造一颗按钮。
///
/// 参数口径：`theme` 来自 `app.palette()`（`UiTheme::from_palette`）或直接用
/// `UiTheme::light()` / `dark()`；`size` 只影响高度、内缩与字号三档；`enabled`
/// 是初值，之后用 `set_enabled` 改。
pub fn[B : @moonui.Backend] UiButton::UiButton(
  backend : B,
  label : String,
  theme~ : UiTheme = UiTheme::light(),
  kind~ : UiButtonKind = UiPrimary,
  size~ : UiSize = UiMedium,
  enabled~ : Bool = true,
) -> UiButton[B] raise @moonui.UiError {
  let metrics = theme.metrics(size)
  let state = BtnState::{
    theme,
    size,
    metrics,
    label,
    kind,
    it: UiInteract::new(enabled~),
    handler: None,
  }
  let widget = @moonui.Widget::custom(
    backend,
    ui_button_size(backend, label, metrics),
    fn(dl, env) { ui_paint_button(state, dl, env) },
    focusable=true,
  )
  ui_watch_state(widget, state.it)
  let _ = widget.on_click(fn() raise @moonui.UiError { ui_button_fire(state) })
  // 键盘：自绘面没有原生按钮那套"空格/回车 → 点击"的翻译，自己接一条。
  // 只认按下（`KeyDown`）不认抬起，与原生按钮一致——按住不放不会连发。
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
            ui_button_fire(state)
          }
        _ => ()
      }
    },
  )
  { backend, widget, state, }
}

///|
/// 点击体的唯一出口：禁用时静默（不回调也不报错），使能时调一次处理器。
fn ui_button_fire(st : BtnState) -> Unit raise @moonui.UiError {
  if !st.it.enabled {
    return
  }
  match st.handler {
    Some(f) => f()
    None => ()
  }
}

///|
/// 拿控件进布局。
pub fn[B] UiButton::widget(self : UiButton[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
/// 当下文案。
pub fn[B] UiButton::label(self : UiButton[B]) -> String {
  self.state.label
}

///|
/// 当下是否使能。
pub fn[B] UiButton::enabled(self : UiButton[B]) -> Bool {
  self.state.it.enabled
}

///|
/// 点击回调。同一颗按钮上后挂的覆盖先挂的（与 `RadioGroup::on_change` 同一条
/// 规矩：一个动作只有一个处理器）。
pub fn[B] UiButton::on_click(
  self : UiButton[B],
  f : () -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
/// 换文案并重算尺寸。宽度跟着字走；`Sized`/`.width()` 这类外部约束照旧赢。
pub fn[B : @moonui.Backend] UiButton::set_label(
  self : UiButton[B],
  label : String,
) -> Unit raise @moonui.UiError {
  if self.state.label == label {
    return
  }
  self.state.label = label
  self.widget.set_custom_size(
    ui_button_size(self.backend, label, self.state.metrics),
  )
  self.widget.repaint()
}

///|
/// 换档（主/次/幽灵/危险）：只换配色，尺寸不变。
pub fn[B : @moonui.Backend] UiButton::set_kind(
  self : UiButton[B],
  kind : UiButtonKind,
) -> Unit raise @moonui.UiError {
  if self.state.kind == kind {
    return
  }
  self.state.kind = kind
  self.widget.repaint()
}

///|
/// 使能开关。禁用后点击与键盘都不再触发回调，颜色退到禁用档。
pub fn[B : @moonui.Backend] UiButton::set_enabled(
  self : UiButton[B],
  enabled : Bool,
) -> Unit raise @moonui.UiError {
  if self.state.it.enabled == enabled {
    return
  }
  self.state.it.enabled = enabled
  self.widget.repaint()
}

///|
/// 换整套令牌（应用切深浅色时一次推下来）：尺寸按新字号重算。
pub fn[B : @moonui.Backend] UiButton::set_theme(
  self : UiButton[B],
  theme : UiTheme,
) -> Unit raise @moonui.UiError {
  self.state.theme = theme
  self.state.metrics = theme.metrics(self.state.size)
  self.widget.set_custom_size(
    ui_button_size(self.backend, self.state.label, self.state.metrics),
  )
  self.widget.repaint()
}
