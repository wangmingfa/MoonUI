///|
/// `UiCard`——自绘卡片容器（`T360` 第三档）。
///
/// 为什么不用 `Widget::custom`：卡片要**装内容**，而自绘面是叶子（`DrawList`
/// 只能画自己那块矩形，装不了子树）。所以壳走样式通道：外层一只 Panel 铺边色
/// 并内缩 1px，内层一只 Panel 铺面色与内边距——两层同心圆角，与按钮"两层填充"
/// 是同一条几何算术（`T353`），只是把 `DrawCmd` 换成了 Panel 的 `Style`。
///
/// 这样也保住了四端一致：样式下发本来就是 Core 的账，原生后端会把它落到窗口
/// 背景上，不需要任何平台分支——这是"自绘控件套件"里唯一一只靠样式通道而不是
/// `DrawList` 的，因为它的本职是容器。
///
/// 尺寸由内容与内边距决定（Panel 走布局），调用方不必给宽高；要固定宽就用
/// `.width()` 那类外部约束，与其它控件同一条口径。

///|
/// 卡片的账：令牌、内边距档、是否带内边距。
struct CardState {
  mut theme : UiTheme
  size : UiSize
  mut metrics : UiMetrics
  /// 关掉内边距的卡片用来贴边放图/表格（内容自己管内缩）
  padded : Bool
}

///|
/// 自绘卡片。`UiCard(b, content)` 之后用 `widget()` 拿外层壳进布局。
pub struct UiCard[B] {
  backend : B
  /// 外层：铺边色的那一层（1px）
  widget : @moonui.Widget[B]
  /// 内层：铺面色 + 内边距，内容挂在它下面
  inner : @moonui.Widget[B]
  state : CardState
}

///|
/// 外层样式：边色整块 + 1px 内缩。圆角取令牌那一档，内层再减 1，两层同心。
fn ui_card_outer_style(st : CardState) -> @moonui.Style {
  @moonui.style(
    background=Some(ui_color(st.theme.border)),
    radius=Some(st.metrics.radius),
    padding=Some(@moonui.EdgeInsets::all(1.0)),
  )
}

///|
/// 内层样式：面色 + 内边距。圆角比外层少 1（不小于 0），保证同心。
fn ui_card_inner_style(st : CardState) -> @moonui.Style {
  let r = st.metrics.radius - 1.0
  @moonui.style(
    background=Some(ui_color(st.theme.surface)),
    radius=Some(if r > 0.0 { r } else { 0.0 }),
    padding=Some(
      if st.padded {
        @moonui.EdgeInsets::all(st.metrics.pad_x)
      } else {
        @moonui.EdgeInsets::zero()
      },
    ),
  )
}

///|
/// 造一只卡片。`content` 是内容子树；`padded=false` 时不加内边距（贴边放图/
/// 表格那种），此时内容自己负责内缩。
pub fn[B : @moonui.Backend] UiCard::UiCard(
  backend : B,
  content : @moonui.Widget[B],
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
  padded~ : Bool = true,
) -> UiCard[B] raise @moonui.UiError {
  let metrics = theme.metrics(size)
  let state = CardState::{ theme, size, metrics, padded, }
  let inner = @moonui.Widget::panel(backend, content)
  inner.set_style(Some(ui_card_inner_style(state)))
  let outer = @moonui.Widget::panel(backend, inner)
  outer.set_style(Some(ui_card_outer_style(state)))
  { backend, widget: outer, inner, state, }
}

///|
/// 拿外壳进布局。
pub fn[B] UiCard::widget(self : UiCard[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
/// 拿内层（要往里再挂孩子时用：内层就是装内容的那只 Panel）。
pub fn[B] UiCard::content(self : UiCard[B]) -> @moonui.Widget[B] {
  self.inner
}

///|
/// 换整套令牌：两层样式一起重刷（只刷一层会留下"边是新色、面是旧色"的半截）。
pub fn[B : @moonui.Backend] UiCard::set_theme(
  self : UiCard[B],
  theme : UiTheme,
) -> Unit raise @moonui.UiError {
  self.state.theme = theme
  self.state.metrics = theme.metrics(self.state.size)
  self.widget.set_style(Some(ui_card_outer_style(self.state)))
  self.inner.set_style(Some(ui_card_inner_style(self.state)))
  self.widget.repaint()
}
