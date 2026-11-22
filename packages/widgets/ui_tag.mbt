///|
/// `UiTag`——自绘角标 / 药丸（`T351`）。
///
/// 原生控件里根本没有"角标"这一档：它要么是一块 Label（方底、不能去掉边距），
/// 要么是一颗按钮（有边框、点了会凹）。自绘之后它是一条圆头药丸：淡色底 + 同色
/// 字，语义由 `UiTone` 给（成功/警告/危险/中性/主色）。
///
/// 为什么不做"可关闭"：关闭要一个 `×` 命中区、要按下态、要"点 × 才算"与
/// "点药丸主体算什么"的分流，而这三件事的语义只有应用知道（点主体是筛选？
/// 是打开详情？）。等真的有调用方要，再加一个 `on_click` 更诚实。
///
/// 高度只有一档（字号 + 10）：角标是"贴在别的东西旁边的小字"，跟着控件尺寸
/// 分三档反而会在同一行里高低不齐。

///|
/// 角标的账：文案、语义色、令牌。
struct TagState {
  theme : UiTheme
  metrics : UiMetrics
  mut text : String
  mut tone : UiTone
}

///|
/// 自绘角标。
pub struct UiTag[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : TagState
}

///|
/// 角标的固有尺寸：字宽 + 两侧 8，高 = 字号 + 10（md 23 / sm 22）。
fn[B : @moonui.Backend] ui_tag_size(
  backend : B,
  text : String,
  metrics : UiMetrics,
) -> @moonui.LogicalSize {
  let (tw, _) = ui_measure(backend, text, metrics.font, false)
  let w = tw + 16.0
  let h = metrics.font + 10.0
  @moonui.LogicalSize(if w < 24.0 { 24.0 } else { w }, h)
}

///|
/// 画一条药丸：淡色底 + 同色字，圆角取半高。
fn ui_paint_tag(
  st : TagState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let t = st.theme
  ui_paint_fill(dl, 0.0, 0.0, w, h, h / 2.0, t.tone_surface(st.tone))
  ui_paint_center_text(
    dl,
    env,
    st.text,
    8.0,
    0.0,
    w - 16.0,
    h,
    st.metrics.font,
    false,
    t.tone(st.tone),
  )
}

///|
/// 造一个角标。`tone` 只管颜色，不管语义检查（"已完成"用绿、"失败"用红是
/// 调用方的事，框架不猜）。
pub fn[B : @moonui.Backend] UiTag::UiTag(
  backend : B,
  text : String,
  tone~ : UiTone = UiTone::UiAccent,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiSmall,
) -> UiTag[B] raise @moonui.UiError {
  let metrics = theme.metrics(size)
  let state = TagState::{ theme, metrics, text, tone, }
  let widget = @moonui.Widget::custom(
    backend,
    ui_tag_size(backend, text, metrics),
    fn(dl, env) { ui_paint_tag(state, dl, env) },
  )
  { backend, widget, state, }
}

///|
pub fn[B] UiTag::widget(self : UiTag[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
pub fn[B] UiTag::text(self : UiTag[B]) -> String {
  self.state.text
}

///|
pub fn[B] UiTag::tone(self : UiTag[B]) -> UiTone {
  self.state.tone
}

///|
/// 换文案并按新字宽重算尺寸。
pub fn[B : @moonui.Backend] UiTag::set_text(
  self : UiTag[B],
  text : String,
) -> Unit raise @moonui.UiError {
  if self.state.text == text {
    return
  }
  self.state.text = text
  self.widget.set_custom_size(
    ui_tag_size(self.backend, text, self.state.metrics),
  )
  self.widget.repaint()
}

///|
/// 换语义色。
pub fn[B : @moonui.Backend] UiTag::set_tone(
  self : UiTag[B],
  tone : UiTone,
) -> Unit raise @moonui.UiError {
  if self.state.tone == tone {
    return
  }
  self.state.tone = tone
  self.widget.repaint()
}
