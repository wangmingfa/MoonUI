///|
/// 声明式修饰符链（`T83`，2026-10-15；`T84` 加 `.animation` 一条）：盖在
/// Core 上的糖层，Core 一字不动。
///
/// 形状公约是"**身份字段走构造参数、外观/行为字段走返回 self 的链**"。这条公约
/// 的前半句由旧命令式构造兑现——`Widget::menu_row(b, "原生控件", false)` 的
/// 文案与选中态本来就是构造参数，`Widget::column(b, 8.0, [...])` 的间距与
/// 子项也是；后半句由本文件的链兑现。旧构造照旧 pub（mock 测试全走它们），
/// 文档里推荐的推荐脸是新的。
///
/// 与 TODO 示例形状的三处偏差，全是工具链逼出来的（探测例在 /tmp/mbprobe，
/// 结论记在 T83 完成注）：
/// - **别名限定构造族（`Text::new` / `Column::new` / `MenuRow::new`）落不了地。**
///   泛型别名（`pub type Text[B] = Widget[B]`）是透明的：方法的登记键是
///   (所有者, 名) 二元组，别名在登记前先被归一化到 `Widget`，第二个定义必撞
///   4056（签名不同也拦不住——登记不看签名）；而调用侧的限定符同样被擦除，
///   `Button::new` 会静默命中 `Text::new` 的定义体。4056 是错误级诊断，
///   不在任何警告名单里，无编译参数可抑。所以身份构造留在旧名上，本文件
///   只添链。
/// - **`.children([...])` / `.insets(...)` / `.on_click(...)` 这三个字面链名
///   落不了地**：它们已被旧 pub 脸占用（`children`/`insets` 是读回 getter、
///   `on_click` 是返 Int32 的订阅），同名单上再登记就是 4056，而旧脸 471 条
///   声明一条不许缩。这批走 `with_` 前缀。
/// - **SwiftUI 式包裹修饰符（`.padding()` 包出新根）结构性落不了地**：链返回
///   self，包裹会换掉树的身份，"self 还是同一个控件"是这条链的存在前提。
///   结构（谁包含谁）走构造——`Widget::padding(b, insets, child)` 照旧；链只
///   管"这个控件自己身上有什么"。
///
/// 种类守卫沿 Core 的既有哲学（widget.mbt 头注）：编译期不管，运行期由被包裹
/// 的 setter 用 `Unsupported` 拦——`.with_spacing(8.0)` 链在 Label 上与
/// `label.set_spacing(8.0)` 是同一个错误、同一句话。控件不吞异常（§33），
/// 所以每条链都 `raise UiError`——糖层不改变错误的传播形状。

///|
/// 外观链的公共底座：把一张稀疏覆盖叠进**局部样式**（§15）。
///
/// 只叠 `over` 里显式设置的字段，局部样式里已有的其它覆盖原样保留——链
/// `.font_size(18.0).font_weight(Bold)` 是两次独立的"只改这一格"，不是
/// "第二次把第一次抹掉"。生效值沿 Theme -> 祖先 -> 自身由 `resolved_style`
/// 算出，重排时 `apply_styles` 下发后端；本函数不碰后端（局部样式不参与
/// 事件与布局值的直接推送，量它的度量在重排那一刻才读）。
fn[B] Widget::layer_local(self : Widget[B], over : Style) -> Unit raise UiError {
  let own = match self.style {
    Some(s) => s
    None => Style::empty()
  }
  self.set_style(Some(own.layer(over)))
}

///|
/// 稀疏覆盖的空底：11 个外观字段全是 `None`，只有更新语法点名的字段有值。
fn sparse_style() -> Style {
  Style::empty()
}

///|
/// 字号（§15）。Mock 的固有尺寸随它缩放（`mock_font_scale`，相对 12.0 基准），
/// 真后端上由原生字体接管（§32 豁免：样式照存照传，原生度量不理它）。
pub fn[B] Widget::font_size(
  self : Widget[B],
  v : Double,
) -> Widget[B] raise UiError {
  self.layer_local(Style::{ ..sparse_style(), font_size: Some(v), })
  self
}

///|
/// 字重。Mock 里 Bold 让文字宽度乘 1.25（`mock_intrinsic`），语义与字号同账。
pub fn[B] Widget::font_weight(
  self : Widget[B],
  w : FontWeight,
) -> Widget[B] raise UiError {
  self.layer_local(Style::{ ..sparse_style(), font_weight: Some(w), })
  self
}

///|
/// 前景色（文字/图标的期望色）。
pub fn[B] Widget::foreground(
  self : Widget[B],
  c : Color,
) -> Widget[B] raise UiError {
  self.layer_local(Style::{ ..sparse_style(), foreground: Some(c), })
  self
}

///|
/// 背景色。
pub fn[B] Widget::background(
  self : Widget[B],
  c : Color,
) -> Widget[B] raise UiError {
  self.layer_local(Style::{ ..sparse_style(), background: Some(c), })
  self
}

///|
/// 不透明度（1.0 全显，0.0 全隐）。只进样式，不替代 `set_visible`——
/// 可见性是状态事实（后端现读），透明度是外观期望。
pub fn[B] Widget::opacity(
  self : Widget[B],
  v : Double,
) -> Widget[B] raise UiError {
  self.layer_local(Style::{ ..sparse_style(), opacity: Some(v), })
  self
}

///|
/// 圆角半径。
pub fn[B] Widget::radius(
  self : Widget[B],
  v : Double,
) -> Widget[B] raise UiError {
  self.layer_local(Style::{ ..sparse_style(), radius: Some(v), })
  self
}

///|
/// 定宽覆盖：进局部样式的 `width`，测量账沿 §15 的样式消费走。
pub fn[B] Widget::width(
  self : Widget[B],
  v : Double,
) -> Widget[B] raise UiError {
  self.layer_local(Style::{ ..sparse_style(), width: Some(v), })
  self
}

///|
/// 定高覆盖。
pub fn[B] Widget::height(
  self : Widget[B],
  v : Double,
) -> Widget[B] raise UiError {
  self.layer_local(Style::{ ..sparse_style(), height: Some(v), })
  self
}

///|
/// 最小宽度约束。
pub fn[B] Widget::min_width(
  self : Widget[B],
  v : Double,
) -> Widget[B] raise UiError {
  self.layer_local(Style::{ ..sparse_style(), min_width: Some(v), })
  self
}

///|
/// 最大宽度约束。
pub fn[B] Widget::max_width(
  self : Widget[B],
  v : Double,
) -> Widget[B] raise UiError {
  self.layer_local(Style::{ ..sparse_style(), max_width: Some(v), })
  self
}

///|
/// 外边距。样式字段（§15），与容器内缩（Padding 的 insets）是两种语义：
/// margin 是"这一层和周围拉开多少"，insets 是"容器把子项往里压多少"。
pub fn[B] Widget::margin(
  self : Widget[B],
  e : EdgeInsets,
) -> Widget[B] raise UiError {
  self.layer_local(Style::{ ..sparse_style(), margin: Some(e), })
  self
}

///|
/// 隐式动画修饰符（`T84`，2026-10-15，SwiftUI 形）：给这个控件记一份动画
/// 曲线——布局值（position/size）、opacity 变了自动过渡，简单程序简单，
/// 一修饰符完事。
///
/// 它与外观链那 11 条**不同源**：不在 Style 上存值（样式层叠一个字不动），
/// 在控件上记动画配置——曲线 + 参与的属性由 Core 动画模块定（第一版：
/// bounds 走 `set_widget_bounds`、opacity 走 `set_widget_opacity` 那条破 §32
/// 豁免的通道）。时长固定 300ms（`animation.mbt`），显式控制器（Flutter 形）
/// 不做——隐式那半的底层就是它。
///
/// 时刻由 pump 注入：没接帧钟的 App 上本修饰符退化为"变更点当圈直接落"，
/// 与无动画树逐位同值（动画是糖，落点即真相）；既有 setter 与布局/可见性
/// 的语义一字不动——动画是加法。
pub fn[B] Widget::animation(
  self : Widget[B],
  curve : AnimationCurve,
) -> Widget[B] raise UiError {
  self.check_open()
  self.animation_curve = Some(curve)
  self
}

///|
/// 行为/状态链的公约：每条 `with_*` 包一个已存在的 setter（`set_*`），把
/// 它的语义原样继承（种类守卫、标脏、后端推送、错误传播），只是返回 self
/// 让链继续。签名随被包裹的 setter 带同样的 `[B : Backend]` 界（需要碰
/// 后端的 setter 才带界，纯 Core 存值的照旧不带）。

///|
/// 文本（包 `set_text`）。文本一变固有尺寸就变的账（b6537ce）照走。
pub fn[B : Backend] Widget::with_text(
  self : Widget[B],
  t : String,
) -> Widget[B] raise UiError {
  self.set_text(t)
  self
}

///|
/// 勾选态（包 `set_checked`，种类守卫：只有复选框和菜单行）。
pub fn[B : Backend] Widget::with_checked(
  self : Widget[B],
  v : Bool,
) -> Widget[B] raise UiError {
  self.set_checked(v)
  self
}

///|
/// 选中下标（包 `set_selected`，种类守卫：ComboBox / RadioButtons）。
pub fn[B : Backend] Widget::with_selected(
  self : Widget[B],
  index : Int32,
) -> Widget[B] raise UiError {
  self.set_selected(index)
  self
}

///|
/// 整数值（包 `set_value`，种类守卫：Slider / Spinbox / Progress）。
pub fn[B : Backend] Widget::with_value(
  self : Widget[B],
  v : Int32,
) -> Widget[B] raise UiError {
  self.set_value(v)
  self
}

///|
/// 可见性（包 `set_visible`）：对容器生效意味着整棵子树一起藏。
pub fn[B : Backend] Widget::with_visible(
  self : Widget[B],
  v : Bool,
) -> Widget[B] raise UiError {
  self.set_visible(v)
  self
}

///|
/// 可用性（包 `set_enabled`）。
pub fn[B : Backend] Widget::with_enabled(
  self : Widget[B],
  v : Bool,
) -> Widget[B] raise UiError {
  self.set_enabled(v)
  self
}

///|
/// 弹性分配（包 `set_expand`，`expand=true` 的叶子与 Spacer 同账）。
pub fn[B] Widget::with_expand(
  self : Widget[B],
  v : Bool,
) -> Widget[B] raise UiError {
  self.set_expand(v)
  self
}

///|
/// 间距（包 `set_spacing`，种类守卫：Row / Column / Grid，负值夹 0 的
/// 夹紧规则在同一处）。
pub fn[B] Widget::with_spacing(
  self : Widget[B],
  v : Double,
) -> Widget[B] raise UiError {
  self.set_spacing(v)
  self
}

///|
/// 内边距（包 `set_insets`，种类守卫：Padding / MenuRow）。两种语义的账
/// 都在被包裹的 setter 里：Padding 是布局内缩，MenuRow 是 CSS 账（固有
/// = 内容 + insets，绘制语义推后端）。
pub fn[B : Backend] Widget::with_insets(
  self : Widget[B],
  v : EdgeInsets,
) -> Widget[B] raise UiError {
  self.set_insets(v)
  self
}

///|
/// 整张局部样式覆盖（包 `set_style`）。逐字段的外观链
/// （`.font_size(...)` 一族）是"只改这一格"，这条是"整张换"。
pub fn[B] Widget::with_style(
  self : Widget[B],
  s : Style?,
) -> Widget[B] raise UiError {
  self.set_style(s)
  self
}

///|
/// 挂一个子项（包 `add_child`）。已被持有的控件不能二次归属（§8）。
pub fn[B] Widget::with_child(
  self : Widget[B],
  child : Widget[B],
) -> Widget[B] raise UiError {
  self.add_child(child)
  self
}

///|
/// 依次挂一排子项（包 `add_child` 的循环）：语义是**追加**，不是替换——
/// 结构身份不换（self 还是同一个容器），和构造参数里交子项字面量同账。
pub fn[B] Widget::with_children(
  self : Widget[B],
  arr : Array[Widget[B]],
) -> Widget[B] raise UiError {
  for c in arr {
    self.add_child(c)
  }
  self
}

///|
/// 无障碍语义覆盖（§32 / `T41`）：三条 `with_access_*` 包对应的
/// `set_access_*`。覆盖值存 Core，生效视图由 `accessibility()` 现算。
pub fn[B] Widget::with_access_role(
  self : Widget[B],
  r : AccessRole?,
) -> Widget[B] raise UiError {
  self.set_access_role(r)
  self
}

///|
/// 无障碍朗读名称（包 `set_access_label`）。
pub fn[B] Widget::with_access_label(
  self : Widget[B],
  s : String?,
) -> Widget[B] raise UiError {
  self.set_access_label(s)
  self
}

///|
/// 无障碍朗读描述（包 `set_access_description`）。
pub fn[B] Widget::with_access_description(
  self : Widget[B],
  s : String?,
) -> Widget[B] raise UiError {
  self.set_access_description(s)
  self
}

///|
/// 事件链的公约：包 `on_*` 订阅族，闭包在构造点捕获（TODO 形状里
/// "event 闭包在构造点捕获"的落地）。旧订阅返回的 handler id 在链上被
/// 丢——id 的用途是按 id 摘单个订阅，而 Core 还没有"从父级摘下单个
/// 控件"（§8），订阅随控件整个回收（`close_tree`），链不需要 id。

///|
/// 点击（包 `on_click`）。种类不匹配不报错——事件可能来自任何地方，
/// 过滤器只在真的收到时放行（§10 的既有语义）。
pub fn[B] Widget::with_on_click(
  self : Widget[B],
  f : () -> Unit raise UiError,
) -> Widget[B] raise UiError {
  let _ = self.on_click(f)
  self
}

///|
/// 双击（包 `on_double_click`）。
pub fn[B] Widget::with_on_double_click(
  self : Widget[B],
  f : () -> Unit raise UiError,
) -> Widget[B] raise UiError {
  let _ = self.on_double_click(f)
  self
}

///|
/// 值变化（包 `on_change`）。
pub fn[B] Widget::with_on_change(
  self : Widget[B],
  f : () -> Unit raise UiError,
) -> Widget[B] raise UiError {
  let _ = self.on_change(f)
  self
}

///|
/// 文本变化，携带变化后的全文（包 `on_input`，§10 的 `Input`）。
pub fn[B] Widget::with_on_input(
  self : Widget[B],
  f : (String) -> Unit raise UiError,
) -> Widget[B] raise UiError {
  let _ = self.on_input(f)
  self
}

///|
/// 获得焦点（包 `on_focus`）。
pub fn[B] Widget::with_on_focus(
  self : Widget[B],
  f : () -> Unit raise UiError,
) -> Widget[B] raise UiError {
  let _ = self.on_focus(f)
  self
}

///|
/// 失去焦点（包 `on_blur`）。
pub fn[B] Widget::with_on_blur(
  self : Widget[B],
  f : () -> Unit raise UiError,
) -> Widget[B] raise UiError {
  let _ = self.on_blur(f)
  self
}

///|
/// 全放行订阅（包 `on_any`），集成测试与全局观察用。
pub fn[B] Widget::with_on_any(
  self : Widget[B],
  handler : (Event) -> Unit raise UiError,
) -> Widget[B] raise UiError {
  let _ = self.on_any(handler)
  self
}
