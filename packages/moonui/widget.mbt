///|
/// Widget（设计文档 §13、§8、§9，开发顺序 §48 第 10~15 步）。
///
/// 本版本 MoonBit 没有 `dyn`，`children` 装不下异构的 trait 对象，所以 Widget 用
/// **单结构体 + 种类标签**：所有 §13 列出的基础能力（visible / enabled / width /
/// height / position / style / parent / children / event handlers）都是这张表上的
/// 字段和方法。代价是种类错误（比如给 Label 设勾选状态）只能在运行期靠
/// `Unsupported` 拦住，编译期不管——这是当前工具链下换整棵异构树的唯一可行形态。
///
/// §14 的另一条决定在这里落地：Row/Column/Padding/Center/Spacer 是 **纯布局节点**，
/// 不占原生对象。布局由 MoonUI 自己算绝对边界，所有叶子控件的原生父级都是窗口。
/// libui-ng 的 uiBox 是堆叠式容器（该库已随 `T82` 删去，这条判据是当时接库时量的），
/// 塞不进这套绝对定位模型，所以后端只需要
/// `attach_widget(window, child)` 一个挂接动作（§20 接上时可以直接验证这一点）。
///
/// §32 的无障碍语义也挂在这张表上：三个可覆盖字段（role / label / description）
/// 加上从事件订阅推导出的 Actions，构成 `accessibility.mbt` 里那份与平台无关的
/// 视图。之所以只存"覆盖值"而不是整份 Accessibility，是因为 State 的事实来源在
/// 后端（visible / enabled / checked），Core 缓存一份就会和原生层分叉。

///|
pub(all) enum WidgetKind {
  Label
  Button
  TextInput
  Checkbox
  PasswordInput
  Separator
  Slider
  Spinbox
  Progress
  ComboBox
  MultilineEntry
  RadioButtons
  DatePicker
  /// 扁平可点文本行（macOS 设置那种"一行一项"的侧栏菜单项，§51 的 Backend #2
  /// 画册左栏要的形状）。叶子控件：有原生对象、可点（`on_click`）、有文本
  /// （`text`/`set_text`），选中态复用 `checked` 通道（`set_checked`/`checked`）
  /// ——菜单项的"选中"就是一个布尔，和复选框的勾选同一条语义，不另开属性。
  MenuRow
  VSeparator
  Row
  Column
  Padding
  Spacer
  Center
  Stack
  /// 自绘面板（皮肤账的载体）：占一个原生对象的容器，背景/圆角吃自己的
  /// Style（§32 的豁免对它**不适用**——它存在的意义就是画样式）。子树挂进
  /// 它自己（与 Scroll 同一条认领规则），padding 也写在样式里。
  Panel
  Grid
  Scroll
  Sized
  /// 图像（`T86⑤`，§31 的最小落地形状——开工决策记在 TODO `T86⑤`）：有原生
  /// 对象、无文案无交互，图像源按路径/按字节两条通道装（`set_image_path` /
  /// `set_image_bytes`），解码与绘制都归原生层（mac 半 NSImage + NSImageView），
  /// MoonBit 侧零解码。
  Image
  /// 自定义绘制面（`T101`，§17 的 CustomWidget）：占一个原生对象、尺寸由应用
  /// 声明（`Widget::custom` 的 `size`），内容是绘制回调写进 `DrawList` 的
  /// 一串命令。它不是容器——子树挂不进来（要组合请用 Row/Column/Padding 把
  /// 它与别的控件摆在一起）；也不是文本/数值控件，`set_text` 这类属性对它报
  /// `Unsupported`。
  Custom
} derive(Debug, Eq)

///|
/// 纯布局节点没有原生对象，其余种类都必须向后端要一个句柄。
///
/// `Scroll` 例外：它**占用一个原生对象**（`T74`）——滚动视口本身是后端的原生
/// 容器（原生后端 mac 半的 NSScrollView / Windows 半
/// 的裁剪 HWND），子树挂进它的文档区、按"文档坐标"摆放（原点 = 视口左上角），
/// 裁剪与滚动条都归它。Core 侧仍然只算绝对矩形，推给后端那一刻才平移成文档
/// 坐标（见 `Widget::set_bounds` 的翻译与 `do_layout` 的滚动行程推送）。
pub fn WidgetKind::is_layout_only(self : WidgetKind) -> Bool {
  match self {
    WidgetKind::Row
    | WidgetKind::Column
    | WidgetKind::Padding
    | WidgetKind::Spacer
    | WidgetKind::Center
    | WidgetKind::Stack
    | WidgetKind::Grid
    | WidgetKind::Sized => true
    _ => false
  }
}

///|
/// 一条控件侧的事件订阅（§9 的 Widget └ EventHandlers）。
/// `accept` 是事件过滤器：`on_click` 只放行 `Click`，`on_any_event` 全放行。
pub(all) struct HandlerEntry {
  id : Int32
  accept : (Event) -> Bool
  call : (Event) -> Unit raise UiError
}

///|
/// 一条传播阶段的订阅（§9/§10，`T86⑨`）。与 `HandlerEntry` 分开两张表：
/// 直派的那张是既有账（语义一字不动），capture/bubble 各一张新表——
/// 没装这两张口的控件，两张表恒空，传播阶段路过时一次调用都不发生。
///
/// `call` 返回 Bool 只有 capture 用得上：false = 拦截，停止后续阶段
/// （target 直派与冒泡都不跑）。bubble 的订阅包一层恒真，签名两臂共用。
pub(all) struct PhaseEntry {
  id : Int32
  accept : (Event) -> Bool
  call : (Event) -> Bool raise UiError
}

///|
pub struct Widget[B] {
  backend : B
  mut handle : NativeHandle?
  kind : WidgetKind
  mut frame : LogicalRect
  mut expand : Bool
  mut spacing : Double
  /// 内边距，两种语义共用一个账：Padding 容器是布局内缩（容器 = 子项 + insets），
  /// MenuRow 是 CSS padding（背景画满整块、文字缩进，固有尺寸 = 内容 + insets）。
  /// 测量账都在 Core——容器的在 layout.mbt，MenuRow 的在 `to_layout_spec`。
  mut insets : EdgeInsets
  mut columns : Int32
  mut axis : Axis
  /// Sized 容器（§14）的定尺寸：Some 的那维在测量时盖掉子项固有值，
  /// None 的那维透传。只有 `WidgetKind::Sized` 会读它。
  mut fixed_w : Double?
  mut fixed_h : Double?
  mut style : Style?
  /// 悬停样式（皮肤账）：hovered 时叠在 resolved_style 最上层。独立于
  /// `style` 存——它是"这一层悬停时要覆盖什么"，与普通局部样式分账。
  mut hover_style : Style?
  /// 悬停中标记（App::hover_track 维护，只在那处翻）
  mut hovered : Bool
  mut access_role : AccessRole?
  mut access_label : String?
  mut access_description : String?
  /// T84 动画记录（加法）：`.animation(curve~)` 存的曲线（None = 没配动画），
  /// 与两条激活期的插值账（bounds / opacity）。曲线不在 Style 上存值——样式
  /// 层叠一个字不动，动画配置是控件自己的属性。
  mut animation_curve : AnimationCurve?
  mut bounds_anim : BoundsSpan?
  mut opacity_anim : OpacitySpan?
  /// 后端**当下显示的值**（最近一次真推下去的 bounds / opacity），动画变更
  /// 检测的对照值：被中断的动画从显示值续跑才不会跳。None = 还没推过
  /// （首推建立初始态，不做动画——与 SwiftUI 同一条规则：初次出现不过渡）。
  /// bounds 存的是推下去那份（Scroll 文档区坐标），frame 存的仍是绝对真相。
  mut shown_bounds : LogicalRect?
  mut shown_opacity : Double?
  /// 动画泵的树级旗标（只有 root 那份被 App 读）：树上有激活期插值账才置位，
  /// App 的 pump 靠它零开销跳过无动画的树——"无激活动画零开销退回现状"。
  mut needs_anim : Bool
  mut children : Array[Widget[B]]
  mut parent : Widget[B]?
  mut attached : Bool
  mut closed : Bool
  mut needs_layout : Bool
  /// 控件级右键上下文菜单（`T86①`）：Some = 右键按到这只控件时按这份菜单弹出。
  /// 配置存在 Core（菜单条目与回调都在 Core），弹出经 `Backend::show_context_menu`。
  mut context_menu : Menu?
  mut context_menu_installed : Bool
  mut handlers : Array[HandlerEntry]
  mut next_handler_id : Int32
  /// 传播阶段订阅（`T86⑨`，加法）：capture 自根向 target、bubble 自 target
  /// 向根。恒空 = 这只控件没参与传播，阶段路过零开销、零语义变化。
  mut capture_handlers : Array[PhaseEntry]
  mut bubble_handlers : Array[PhaseEntry]
  /// 自定义绘制面（`T101`）的声明尺寸：`WidgetKind::Custom` 的固有尺寸就取它
  /// （后端不知道这块面"想多大"——那是应用的事，与原生控件的 fittingSize
  /// 正相反）。其余 kind 恒为零，不读。
  mut custom_size : LogicalSize
  /// 自定义绘制面的绘制回调（`T101`）：参数是清单与环境，写入即"这一帧画这些"。
  /// 只有 `WidgetKind::Custom` 会读它；回调不存在时这块面是空的（合法状态——
  /// 先把面摆出来、后接上画法，与给图片控件后补图像源同一条路）。
  mut custom_paint : ((DrawList, PaintEnv) -> Unit)?
}

///|
/// 只攒结构、不建原生对象：`make` 与 `make_ranged` 的公共底座。
fn[B] Widget::from_parts(
  backend : B,
  kind : WidgetKind,
  handle : NativeHandle?,
) -> Widget[B] {
  Widget::{
    backend,
    handle,
    kind,
    frame: LogicalRect(LogicalPoint(0.0, 0.0), LogicalSize::zero()),
    expand: false,
    spacing: 0.0,
    insets: EdgeInsets::zero(),
    columns: 1,
    axis: Vertical,
    fixed_w: None,
    fixed_h: None,
    style: None,
    hover_style: None,
    hovered: false,
    access_role: None,
    access_label: None,
    access_description: None,
    animation_curve: None,
    bounds_anim: None,
    opacity_anim: None,
    shown_bounds: None,
    shown_opacity: None,
    needs_anim: false,
    children: [],
    parent: None,
    attached: false,
    closed: false,
    needs_layout: false,
    context_menu: None,
    context_menu_installed: false,
    handlers: [],
    next_handler_id: 0,
    capture_handlers: [],
    bubble_handlers: [],
    custom_size: LogicalSize::zero(),
    custom_paint: None,
  }
}

///|
fn[B : Backend] Widget::make(
  backend : B,
  kind : WidgetKind,
  text : String,
) -> Widget[B] raise UiError {
  let handle = if kind.is_layout_only() {
    None
  } else {
    Some(Backend::create_widget(backend, kind, text))
  }
  Widget::from_parts(backend, kind, handle)
}

///|
/// Slider / Spinbox 的创建通道：范围当构造参数是 libui 定下的口径
/// （`uiNewSlider(min, max)`），没有"先建再设范围"的入口，所以 trait 单独
/// 开了 `create_ranged_widget`，其余种类仍走 `create_widget`。
fn[B : Backend] Widget::make_ranged(
  backend : B,
  kind : WidgetKind,
  min : Int32,
  max : Int32,
) -> Widget[B] raise UiError {
  Widget::from_parts(
    backend,
    kind,
    Some(Backend::create_ranged_widget(backend, kind, min, max)),
  )
}

///|
pub fn[B : Backend] Widget::label(
  backend : B,
  text : String,
) -> Widget[B] raise UiError {
  Widget::make(backend, WidgetKind::Label, text)
}

///|
pub fn[B : Backend] Widget::button(
  backend : B,
  text : String,
) -> Widget[B] raise UiError {
  Widget::make(backend, WidgetKind::Button, text)
}

///|
pub fn[B : Backend] Widget::text_input(
  backend : B,
  text : String,
) -> Widget[B] raise UiError {
  Widget::make(backend, WidgetKind::TextInput, text)
}

///|
pub fn[B : Backend] Widget::checkbox(
  backend : B,
  text : String,
  checked : Bool,
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Checkbox, text)
  w.set_checked(checked)
  w
}

///|
/// 密码输入框：和 TextInput 同一条文本通道，但内容以圆点遮盖显示
/// （沿 libui `uiNewPasswordEntry` 的口径，两边平台都由系统画遮盖）。
pub fn[B : Backend] Widget::password_input(
  backend : B,
  text : String,
) -> Widget[B] raise UiError {
  Widget::make(backend, WidgetKind::PasswordInput, text)
}

///|
/// 分隔线（Element UI 的 Divider）：一条细线，没有文案与交互。
pub fn[B : Backend] Widget::separator(backend : B) -> Widget[B] raise UiError {
  Widget::make(backend, WidgetKind::Separator, "")
}

///|
/// 竖分隔线：和 `Widget::separator` 同一条原生实现，方向竖转。画册的
/// "左栏 | 右栏"分界靠它——横线（`Widget::separator`）在 mac 上是
/// `uiNewHorizontalSeparator`，把窗口竖切成两半需要的是竖的那条。
pub fn[B : Backend] Widget::vseparator(backend : B) -> Widget[B] raise UiError {
  Widget::make(backend, WidgetKind::VSeparator, "")
}

///|
/// 滑块（Element UI 的 Slider）：范围在创建时定死——沿 libui 的
/// 口径（`uiNewSlider(min, max)` 是唯一带范围入口，事后只有 `uiSliderSetRange`
/// 一条改口），所以构造参数就是范围。拖动产生 `Change`，值由 `value()` 回读。
pub fn[B : Backend] Widget::slider(
  backend : B,
  min : Int32,
  max : Int32,
) -> Widget[B] raise UiError {
  Widget::make_ranged(backend, WidgetKind::Slider, min, max)
}

///|
/// 数字输入框（Element UI 的 InputNumber）：带上下箭头的整数输入，
/// 范围在创建时定死（沿 libui 的口径——没有 uiSpinboxSetRange），行为同 Slider。
pub fn[B : Backend] Widget::spinbox(
  backend : B,
  min : Int32,
  max : Int32,
) -> Widget[B] raise UiError {
  Widget::make_ranged(backend, WidgetKind::Spinbox, min, max)
}

///|
/// 进度条（Element UI 的 Progress）。`value` 0–100；传 -1 进"不定进度"
/// （两端原生层都把 -1 当动画滚动条，沿 libui 的约定）。
pub fn[B : Backend] Widget::progress(backend : B) -> Widget[B] raise UiError {
  Widget::make(backend, WidgetKind::Progress, "")
}

///|
/// 下拉选择（Element UI 的 Select）。选项在创建时按序填入，选中项的
/// **下标**可读写；换选产生 `Change`，下标由 `selected()` 回读。
pub fn[B : Backend] Widget::combobox(
  backend : B,
  options : Array[String],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::ComboBox, "")
  for o in options {
    w.append_option(o)
  }
  w
}

///|
/// 多行文本域（Element UI 的 Textarea）。文本走 `text` / `set_text`
/// 同一条通道，编辑产生 `Input`（带全文，§10）。
pub fn[B : Backend] Widget::multiline(
  backend : B,
  text : String,
) -> Widget[B] raise UiError {
  Widget::make(backend, WidgetKind::MultilineEntry, text)
}

///|
/// 单选组（Element UI 的 Radio）：一组互斥的选项，一个原生控件。
/// 选项在创建时按序填入，选中下标可读写；换选产生 `Change`。
pub fn[B : Backend] Widget::radio_buttons(
  backend : B,
  options : Array[String],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::RadioButtons, "")
  for o in options {
    w.append_option(o)
  }
  w
}

///|
/// 日期时间选择（Element UI 的 DateTimePicker）。0.1 的值口径是
/// `"YYYY-MM-DD HH:MM:SS"` 文本，由后端格式化/解析（两端原生层的字段集
/// 都来自 `struct tm`，打包成 int64 过不了 native FFI 的单返回值）。
/// 改值产生 `Change`。
pub fn[B : Backend] Widget::date_picker(backend : B) -> Widget[B] raise UiError {
  Widget::make(backend, WidgetKind::DatePicker, "")
}

///|
/// 扁平可点文本行（§51 的 Backend #2 画册左栏）。`selected` 是选中态：
/// 走 `checked` 通道（`set_checked`/`checked`），建完即按它置位——和
/// `Widget::checkbox` 的 `checked` 参数同一条规矩。点击产生 `Click`，
/// 由 `on_click` 订阅；选中高亮由后端按 `checked` 画（原生层的事，§32）。
pub fn[B : Backend] Widget::menu_row(
  backend : B,
  text : String,
  selected : Bool,
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::MenuRow, text)
  w.set_checked(selected)
  w
}

///|
/// 图像（`T86⑤`）：创建时无源，装源走 `set_image_path` / `set_image_bytes`
/// （解码归平台——开工决策记在 TODO `T86⑤`，MoonBit 侧零解码）。
pub fn[B : Backend] Widget::image(backend : B) -> Widget[B] raise UiError {
  Widget::make(backend, WidgetKind::Image, "")
}

///|
/// 自定义绘制面（`T101`，§17）：一块由应用自己画的控件。
///
/// `size` 是**声明尺寸**，也就是它在布局里的固有尺寸——与原生控件的
/// "问系统要 fittingSize"正相反：这块面没有系统外观，多大是应用的账。
/// 想让它跟着容器缩放，照常 `.expand(true)` 或外层套 `Widget::sized`。
///
/// `paint` 在每一次"这块面脏了"的时候被调用（首次摆出来、改了尺寸、或应用
/// 显式 `repaint`），参数是这份帧的 `DrawList` 与 `PaintEnv`。回调里画什么、
/// 按不按 `env.size` 自适应，都是应用的事；框架只保证：
/// - 坐标是**控件局部**的逻辑像素，原点在左上角、y 向下；
/// - 回调返回后这份清单会被立刻交给后端，所以清单不是"攒起来的"；
/// - 回调不 raise（画清单不会失败），失败只可能发生在后端重放时。
///
/// 事件：这块面是一个真的原生对象，点击/悬停照常按 `EventTarget` 派发——
/// `on_click`、`on_hover` 这些都用得上。首版只到"按下并原地抬起 = 一次
/// `Click`"（与 Button 的判定同一条），拖动与滚轮留给后面按需要接。
///
/// `focusable=true` 是**键盘焦点的 opt-in**（`T102` 第十一刀）：这块面点一下
/// 就能成为 first responder、Tab 也会停在它上面，于是订阅到的 `KeyDown` 派给
/// 的是它而不是窗口。默认关——自绘面是裸 `NSView`，恒开会把每个"只画点东西"
/// 的面塞进 Tab 链、还会从文本框手里抢走焦点（`Backend::set_custom_focusable`
/// 段注）。要键盘语义的面（如 `DataGrid`）自己声明。
pub fn[B : Backend] Widget::custom(
  backend : B,
  size : LogicalSize,
  paint : (DrawList, PaintEnv) -> Unit,
  focusable~ : Bool = false,
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Custom, "")
  w.custom_size = LogicalSize(
    if size.width > 0.0 {
      size.width
    } else {
      0.0
    },
    if size.height > 0.0 {
      size.height
    } else {
      0.0
    },
  )
  w.custom_paint = Some(paint)
  match w.handle() {
    Some(h) => Backend::set_custom_focusable(backend, h, focusable)
    None => ()
  }
  w
}

///|
/// 图像源检查（`T86⑤`）：与 value/checked/datetime 同一条 kind 规矩——
/// 哪种控件有哪种属性由 Core 按 kind 拦在前头。
fn[B] Widget::check_image_kind(self : Widget[B]) -> Unit raise UiError {
  if self.kind != WidgetKind::Image {
    raise Unsupported("只有 Image 控件有图像源")
  }
}

///|
/// 按路径装图像源（`T86⑤`）。整源替换：后一次调用覆盖前一次。解码失败由
/// 后端报 `OperationFailed`（路径不存在 / 格式不支持）。
pub fn[B : Backend] Widget::set_image_path(
  self : Widget[B],
  path : String,
) -> Unit raise UiError {
  self.check_image_kind()
  match self.handle {
    Some(h) => Backend::set_widget_image_path(self.backend, h, path)
    None => raise Destroyed
  }
}

///|
/// 按字节装图像源（`T86⑤`）：字节数据（PNG/JPEG 等平台认得的编码格式）由
/// 调用方拿到（读文件、网络），解码归平台。
pub fn[B : Backend] Widget::set_image_bytes(
  self : Widget[B],
  data : Bytes,
) -> Unit raise UiError {
  self.check_image_kind()
  match self.handle {
    Some(h) => Backend::set_widget_image_bytes(self.backend, h, data)
    None => raise Destroyed
  }
}

///|
/// 配置控件级右键上下文菜单（`T86①`）。菜单本体（条目、勾选态、回调）存在
/// Core：右键按到这只控件时，框架沿 `Backend::show_context_menu` 把这份菜单
/// 弹出来，选中的语义沿 `T22` 现账（勾选态改在 Core、回调当场跑）。重复配置
/// 整体替换，装过的框架订阅只留一份（替换配置不再叠订阅）。
pub fn[B : Backend] Widget::set_context_menu(
  self : Widget[B],
  menu : Menu,
) -> Unit raise UiError {
  if !self.context_menu_installed {
    self.context_menu_installed = true
    // 框架订阅用控件既有的 handler 机制（`Widget::on`）：右键按下的事件到达
    // 这只控件时才请求弹出——事件先到 MoonBit（`T86①` 的开工决策），命中反查
    // 后才回调平台。
    let _ = self.on(
      ev => {
        match ev {
          MouseDown(_, MouseButton::Right, _) => true
          _ => false
        }
      },
      fn(_) raise UiError {
        match self.context_menu {
          Some(m) => Backend::show_context_menu(self.backend, m)
          None => ()
        }
      },
    )
  }
  self.context_menu = Some(menu)
}

///|
/// 横向容器（§14）。`spacing` 只加在相邻子项之间。
pub fn[B : Backend] Widget::row(
  backend : B,
  spacing : Double,
  children : Array[Widget[B]],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Row, "")
  w.spacing = spacing
  for c in children {
    w.add_child(c)
  }
  w
}

///|
/// 纵向容器（§14）。
pub fn[B : Backend] Widget::column(
  backend : B,
  spacing : Double,
  children : Array[Widget[B]],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Column, "")
  w.spacing = spacing
  for c in children {
    w.add_child(c)
  }
  w
}

///|
pub fn[B : Backend] Widget::padding(
  backend : B,
  insets : EdgeInsets,
  child : Widget[B],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Padding, "")
  w.insets = insets
  w.add_child(child)
  w
}

///|
/// 定尺寸容器（§14）：`Some` 的那一维在测量时盖掉子项固有值（布局时子项
/// 铺满这一维），`None` 的那一维透传子项。给"侧栏一列等宽按钮"这类
/// "宽度由设计定、不由内容定"的构图用——Row/Column 只按固有尺寸摆固定项，
/// 没有 Sized 就只能让每个按钮各宽各的。
pub fn[B : Backend] Widget::sized(
  backend : B,
  width : Double?,
  height : Double?,
  child : Widget[B],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Sized, "")
  w.fixed_w = width
  w.fixed_h = height
  w.add_child(child)
  w
}

///|
pub fn[B : Backend] Widget::center(
  backend : B,
  child : Widget[B],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Center, "")
  w.add_child(child)
  w
}

///|
/// 弹性占位：把主轴剩余空间均分给各个 Spacer（§14）。
pub fn[B : Backend] Widget::spacer(backend : B) -> Widget[B] raise UiError {
  Widget::make(backend, WidgetKind::Spacer, "")
}

///|
/// 叠放容器（§14）：子项共用同一个原点，数组靠后的画在上层。
pub fn[B : Backend] Widget::stack(
  backend : B,
  children : Array[Widget[B]],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Stack, "")
  for c in children {
    w.add_child(c)
  }
  w
}

///|
/// 均匀网格（§14）。`columns` 小于 1 按 1 处理、负间距按 0 处理，
/// 夹紧规则和布局引擎共用同一套语义，避免两处各说各话。
pub fn[B : Backend] Widget::grid(
  backend : B,
  columns : Int32,
  spacing : Double,
  children : Array[Widget[B]],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Grid, "")
  w.columns = if columns < 1 { 1 } else { columns }
  w.spacing = if spacing < 0.0 { 0.0 } else { spacing }
  for c in children {
    w.add_child(c)
  }
  w
}

///|
/// 滚动视口（§14，`T74`）。视口本身占用一个原生对象，子树挂进它的文档区、
/// 按完整尺寸摆放（可以超出视口——这就是滚动行程）；裁剪与滚动条由后端的原生
/// 容器负责。Core 不存滚动偏移——那是后端的事实，Core 存了也不会生效，反而骗人。
pub fn[B : Backend] Widget::scroll(
  backend : B,
  axis : Axis,
  child : Widget[B],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Scroll, "")
  w.axis = axis
  w.add_child(child)
  w
}

///|
/// 自绘面板：单子容器，背景/圆角/内边距全来自它自己的 Style（§32 的豁免
/// 不适用——这是皮肤账的载体，样式就是它的本职）。子树在 mac 上挂进它
/// 的原生 view，背景由原生侧按 set_widget_style 下发的值画。
pub fn[B : Backend] Widget::panel(
  backend : B,
  child : Widget[B],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Panel, "")
  w.add_child(child)
  w
}

///|
/// 渐变面板（§15 渐变的跨后端落地）：把线性渐变分解成 N 条等高/等宽的实色
/// 条带，每带一只 Panel。原生皮肤通道只吃单色、拿不到"渐变笔"，所以真渐变
/// 靠子控件铺出来——这条在 mac/win/canvas/mock 四后端行为一致，无需平台代码。
///
/// 条带用 `expand` 均分主轴剩余空间，因此它自身要有确定的主轴尺寸（放进定高
/// 容器、或用 `sized`/`with_expand(true)` 约束）。返回 Column（垂直）或 Row
/// （水平）；要与内容叠放，套一层 `Widget::stack` 把内容放数组后面。
pub fn[B : Backend] Widget::gradient_panel(
  backend : B,
  g : Gradient,
  total~ : Double,
  width~ : Double? = None,
  bands~ : Int32 = 24,
) -> Widget[B] raise UiError {
  // 定长条带（关键）：每条带的高度（或宽度）在**建树时**就写死成 total/n，
  // 不靠 expand 撑满。expand 的语义是"吃父容器主轴剩余空间"——放进 Stack
  // 这类用无界上限测量的容器里，主轴剩余就是 Infinity，条带会被量成 1e18
  // （或反过来塌成 0）。定长后它与测量上下文无关：Stack / Column / 窗口根
  // 里行为一致，四后端也一样。
  let n : Int32 = if bands < 2 { 2 } else { bands }
  let total : Double = if total <= 0.0 { 1.0 } else { total }
  let seg : Double = total / n.to_double()
  let kids : Array[Widget[B]] = []
  for i = 0; i < n; i = i + 1 {
    let t : Double = i.to_double() / (n - 1).to_double()
    // 最后一条吃掉取整余量，保证 N 条加起来正好等于 total（不留 1px 缝）。
    let len : Double = if i == n - 1 {
      total - seg * (n - 1).to_double()
    } else {
      seg
    }
    // 交叉轴：条带自己是 Panel，固有尺寸为 0——用一条「撑满交叉轴」的 filler
    // 让它长成整行宽（垂直渐变）/ 整列高（水平渐变）。
    let filler = match g.dir {
      Vertical =>
        Widget::row(backend, 0.0, [Widget::spacer(backend).with_expand(true)])
      Horizontal =>
        Widget::column(backend, 0.0, [Widget::spacer(backend).with_expand(true)])
    }
    let band = Widget::panel(backend, filler)
    let _ = band.set_style(Some(style(background=Some(g.at(t)))))
    let fixed = match g.dir {
      Vertical => Widget::sized(backend, width, Some(len), band)
      Horizontal => Widget::sized(backend, Some(len), None, band)
    }
    kids.push(fixed)
  }
  match g.dir {
    Vertical => Widget::column(backend, 0.0, kids)
    Horizontal => Widget::row(backend, 0.0, kids)
  }
}

///|
pub fn[B] Widget::kind(self : Widget[B]) -> WidgetKind {
  self.kind
}

///|
pub fn[B] Widget::handle(self : Widget[B]) -> NativeHandle? {
  self.handle
}

///|
/// 事件订阅用的目标 id。纯布局节点收不到原生事件，因此没有 target。
pub fn[B] Widget::target(self : Widget[B]) -> EventTarget raise UiError {
  match self.handle {
    Some(h) => EventTarget::of(h)
    None =>
      raise Unsupported("布局节点没有原生对象，不能订阅事件")
  }
}

///|
pub fn[B] Widget::is_closed(self : Widget[B]) -> Bool {
  self.closed
}

///|
pub fn[B] Widget::is_attached(self : Widget[B]) -> Bool {
  self.attached
}

///|
pub fn[B] Widget::children(self : Widget[B]) -> Array[Widget[B]] {
  self.children
}

///|
pub fn[B] Widget::parent(self : Widget[B]) -> Widget[B]? {
  self.parent
}

///|
pub fn[B] Widget::check_open(self : Widget[B]) -> Unit raise UiError {
  if self.closed {
    raise Destroyed
  }
}

///|
/// 取原生句柄。布局节点在这里报 `Unsupported`，绝不把空句柄递到后端。
fn[B] Widget::need_handle(self : Widget[B]) -> NativeHandle raise UiError {
  self.check_open()
  match self.handle {
    Some(h) => h
    None => raise Unsupported("布局节点没有原生对象")
  }
}

///|
/// 文本类控件才有文本（§13）。种类不符时是明确错误，不是静默无效。
fn[B] Widget::check_text_kind(self : Widget[B]) -> Unit raise UiError {
  match self.kind {
    WidgetKind::Label
    | WidgetKind::Button
    | WidgetKind::TextInput
    | WidgetKind::Checkbox
    | WidgetKind::PasswordInput
    | WidgetKind::MultilineEntry
    | WidgetKind::MenuRow => ()
    _ => raise Unsupported("该控件没有文本属性")
  }
}

///|
/// 数值属性（Slider / Spinbox / Progress 的 value）只对这三种有意义。
fn[B] Widget::check_value_kind(self : Widget[B]) -> Unit raise UiError {
  match self.kind {
    WidgetKind::Slider | WidgetKind::Spinbox | WidgetKind::Progress => ()
    _ => raise Unsupported("该控件没有数值属性")
  }
}

///|
/// 条目属性（ComboBox / RadioButtons 的选中下标与选项列表）。
fn[B] Widget::check_selected_kind(self : Widget[B]) -> Unit raise UiError {
  match self.kind {
    WidgetKind::ComboBox | WidgetKind::RadioButtons => ()
    _ => raise Unsupported("该控件没有选项属性")
  }
}

///|
pub fn[B : Backend] Widget::text(self : Widget[B]) -> String raise UiError {
  self.check_text_kind()
  Backend::widget_text(self.backend, self.need_handle())
}

///|
pub fn[B : Backend] Widget::set_text(
  self : Widget[B],
  text : String,
) -> Unit raise UiError {
  self.check_text_kind()
  Backend::set_widget_text(self.backend, self.need_handle(), text)
  self.mark_needs_layout()
}

///|
/// 文案变了、固有尺寸就可能变了，而 Core 的 frame 只在布局时才写回原生层——
/// 不喊一声重排，标签就顶着旧 frame 裁新文案（Counter 的 "Count: 15" 截字）。
/// 只挂到根上：`App::step` 每轮只看各窗口根的这一位，谁来 relayout 谁清。
fn[B] Widget::mark_needs_layout(self : Widget[B]) -> Unit {
  let mut cur : Widget[B]? = Some(self)
  while cur is Some(w) {
    w.needs_layout = true
    cur = w.parent
  }
}

///|
pub fn[B : Backend] Widget::checked(self : Widget[B]) -> Bool raise UiError {
  Backend::widget_checked(self.backend, self.need_handle())
}

///|
pub fn[B : Backend] Widget::set_checked(
  self : Widget[B],
  v : Bool,
) -> Unit raise UiError {
  Backend::set_widget_checked(self.backend, self.need_handle(), v)
  // 勾选态进无障碍语义（`T41`），改了就标脏让下一轮 step 把 State 补推给后端。
  self.mark_needs_layout()
}

///|
/// 数值读写（Slider / Spinbox / Progress）。Progress 传 -1 = 不定进度。
pub fn[B : Backend] Widget::set_value(
  self : Widget[B],
  v : Int32,
) -> Unit raise UiError {
  self.check_value_kind()
  Backend::set_widget_value(self.backend, self.need_handle(), v)
  self.mark_needs_layout()
}

///|
pub fn[B : Backend] Widget::value(self : Widget[B]) -> Int32 raise UiError {
  self.check_value_kind()
  Backend::widget_value(self.backend, self.need_handle())
}

///|
/// 改范围（只有 Slider：这条限制沿 libui 的事实——它的 Spinbox 没有事后
/// 改范围的原生入口、范围只能构造时给；`T82` 删 libui，限制保留）。
pub fn[B : Backend] Widget::set_range(
  self : Widget[B],
  min : Int32,
  max : Int32,
) -> Unit raise UiError {
  match self.kind {
    WidgetKind::Slider => {
      Backend::set_widget_range(self.backend, self.need_handle(), min, max)
      self.mark_needs_layout()
    }
    _ => raise Unsupported("只有 Slider 能改范围")
  }
}

///|
/// 追加一个选项（ComboBox / RadioButtons）。
pub fn[B : Backend] Widget::append_option(
  self : Widget[B],
  text : String,
) -> Unit raise UiError {
  self.check_selected_kind()
  Backend::append_widget_option(self.backend, self.need_handle(), text)
  self.mark_needs_layout()
}

///|
/// 选中下标读写（ComboBox / RadioButtons）。越界行为由后端定义：
/// 沿 libui 的口径：`uiComboboxSetSelected` 不做范围检查，传出去前由调用方自律。
pub fn[B : Backend] Widget::set_selected(
  self : Widget[B],
  index : Int32,
) -> Unit raise UiError {
  self.check_selected_kind()
  Backend::set_widget_selected(self.backend, self.need_handle(), index)
  self.mark_needs_layout()
}

///|
pub fn[B : Backend] Widget::selected(self : Widget[B]) -> Int32 raise UiError {
  self.check_selected_kind()
  Backend::widget_selected(self.backend, self.need_handle())
}

///|
/// 日期时间读回，格式 `"YYYY-MM-DD HH:MM:SS"`（DatePicker）。
pub fn[B : Backend] Widget::datetime_text(
  self : Widget[B],
) -> String raise UiError {
  match self.kind {
    WidgetKind::DatePicker => ()
    _ => raise Unsupported("只有 DatePicker 有日期时间属性")
  }
  Backend::widget_datetime(self.backend, self.need_handle())
}

///|
/// 设置日期时间（DatePicker），格式同上；解析不了由后端报 `OperationFailed`。
pub fn[B : Backend] Widget::set_datetime_text(
  self : Widget[B],
  text : String,
) -> Unit raise UiError {
  match self.kind {
    WidgetKind::DatePicker => ()
    _ => raise Unsupported("只有 DatePicker 有日期时间属性")
  }
  Backend::set_widget_datetime(self.backend, self.need_handle(), text)
  self.mark_needs_layout()
}

///|
/// 可见性对容器生效意味着整棵子树一起隐藏——叶子控件的原生父级是窗口，
/// 容器本身没有原生对象可以藏，所以必须自己递归。
pub fn[B : Backend] Widget::set_visible(
  self : Widget[B],
  v : Bool,
) -> Unit raise UiError {
  self.check_open()
  match self.handle {
    Some(h) => Backend::set_widget_visible(self.backend, h, v)
    None => ()
  }
  for c in self.children {
    c.set_visible(v)
  }
  // 可见性同样进无障碍语义（`T41`），标脏理由与 set_checked 相同。
  self.mark_needs_layout()
}

///|
/// 读取可见性：容器返回"子树是否全部可见"，叶子读原生状态。
pub fn[B : Backend] Widget::visible(self : Widget[B]) -> Bool raise UiError {
  self.check_open()
  let own = match self.handle {
    Some(h) => Backend::widget_visible(self.backend, h)
    None => true
  }
  let mut all = own
  for c in self.children {
    if !c.visible() {
      all = false
    }
  }
  all
}

///|
pub fn[B : Backend] Widget::set_enabled(
  self : Widget[B],
  v : Bool,
) -> Unit raise UiError {
  self.check_open()
  match self.handle {
    Some(h) => Backend::set_widget_enabled(self.backend, h, v)
    None => ()
  }
  // 可用性同样进无障碍语义（`T41`），标脏理由与 set_checked 相同。
  self.mark_needs_layout()
}

///|
pub fn[B : Backend] Widget::enabled(self : Widget[B]) -> Bool raise UiError {
  self.check_open()
  match self.handle {
    Some(h) => Backend::widget_enabled(self.backend, h)
    None => true
  }
}

///|
pub fn[B] Widget::expand(self : Widget[B]) -> Bool {
  self.expand
}

///|
/// `expand=true` 的叶子与 `Spacer` 一起参与弹性分配（§14）。
pub fn[B] Widget::set_expand(self : Widget[B], v : Bool) -> Unit raise UiError {
  self.check_open()
  if self.kind == WidgetKind::Spacer && !v {
    raise Unsupported("Spacer 本身就是弹性项")
  }
  self.expand = v
  // 弹性分配变了布局分配就变——存值必标脏（T55 那笔账的同形缺口：
  // 当时点了 set_text/set_style/set_insets，expand 漏了；真窗批 T89②
  // 的 expand 收缩触发在案钉住这条）。
  self.mark_needs_layout()
}

///|
pub fn[B] Widget::spacing(self : Widget[B]) -> Double raise UiError {
  self.check_open()
  match self.kind {
    WidgetKind::Row | WidgetKind::Column | WidgetKind::Grid => self.spacing
    _ => raise Unsupported("只有 Row/Column/Grid 有间距")
  }
}

///|
pub fn[B] Widget::set_spacing(
  self : Widget[B],
  v : Double,
) -> Unit raise UiError {
  self.check_open()
  match self.kind {
    WidgetKind::Row | WidgetKind::Column | WidgetKind::Grid =>
      self.spacing = if v < 0.0 { 0.0 } else { v }
    _ => raise Unsupported("只有 Row/Column/Grid 有间距")
  }
}

///|
/// Grid 的列数（其余种类没有这个属性）。
pub fn[B] Widget::columns(self : Widget[B]) -> Int32 raise UiError {
  self.check_open()
  match self.kind {
    WidgetKind::Grid => self.columns
    _ => raise Unsupported("只有 Grid 有列数")
  }
}

///|
/// Scroll 的滚动方向（其余种类没有轴向）。
pub fn[B] Widget::axis(self : Widget[B]) -> Axis raise UiError {
  self.check_open()
  match self.kind {
    WidgetKind::Scroll => self.axis
    _ => raise Unsupported("只有 Scroll 有滚动方向")
  }
}

///|
pub fn[B] Widget::insets(self : Widget[B]) -> EdgeInsets raise UiError {
  self.check_open()
  match self.kind {
    WidgetKind::Padding | WidgetKind::MenuRow => self.insets
    _ => raise Unsupported("只有 Padding 与 MenuRow 有内边距")
  }
}

///|
pub fn[B : Backend] Widget::set_insets(
  self : Widget[B],
  v : EdgeInsets,
) -> Unit raise UiError {
  self.check_open()
  match self.kind {
    // 内边距一变固有尺寸就变（`T55`）：不标脏的话，没有别的事顺手触发重排，
    // 控件就顶着旧矩形——同 set_text 那笔账（b6537ce）同一个理由。
    WidgetKind::Padding => {
      self.insets = v
      self.mark_needs_layout()
    }
    // MenuRow 的 CSS padding：测量账（固有 = 内容 + insets）在 Core 的
    // `to_layout_spec` 一处记；绘制语义（文字缩进）推给后端——背景画在按钮
    // 自己的 bounds 里，bounds 长大背景自动长大，绘制侧只欠"文字往哪缩"。
    WidgetKind::MenuRow => {
      self.insets = v
      Backend::set_widget_insets(self.backend, self.need_handle(), v)
      self.mark_needs_layout()
    }
    _ => raise Unsupported("只有 Padding 与 MenuRow 有内边距")
  }
}

///|
pub fn[B] Widget::style(self : Widget[B]) -> Style? {
  self.style
}

///|
/// 局部样式覆盖（§15）。这里只存"这一层要覆盖什么"，
/// 真正的生效值由 `resolved_style` 沿祖先链算出来。
/// 字号一变固有尺寸就变，所以存值之后标脏、由下一轮 `App::step` 补排
/// （`T55`，形状同 set_text 那笔 b6537ce 的账）。真后端上这一条**有意不生效**
/// （§32 保原生外观，`T30` 的豁免）——标脏照挂，只是后端那个度量不理它。
pub fn[B] Widget::set_style(self : Widget[B], s : Style?) -> Unit raise UiError {
  self.check_open()
  self.style = s
  self.mark_needs_layout()
}

///|
/// 图标（皮肤账）：给按钮类控件换图形图标。名字走平台的系统图标集
/// （mac = SF Symbols 名，Windows 半缺席）——名字与图形的对应归平台，
/// Core 只转发。装饰性：后端给不出图标就保持文本外观，不报错。
pub fn[B : Backend] Widget::set_icon(
  self : Widget[B],
  name : String,
) -> Unit raise UiError {
  self.check_open()
  let h = self.need_handle()
  match self.kind {
    WidgetKind::Button | WidgetKind::MenuRow | WidgetKind::Label =>
      Backend::set_widget_icon(self.backend, h, name)
    _ => raise Unsupported("只有 Button/MenuRow/Label 有图标通道")
  }
}

///|
/// 悬停样式（皮肤账）：hovered 时由 `resolved_style` 叠在最上层。存"悬停
/// 这一层要覆盖什么"，生效时机归 App 的悬停账（`hover_track`）——普通调用
/// 方只需要把样式交进来，翻面/重推都不到这。
pub fn[B] Widget::set_hover_style(
  self : Widget[B],
  s : Style?,
) -> Unit raise UiError {
  self.check_open()
  self.hover_style = s
  // 悬停中的时候立即换脸（下一轮 step 补推）；不在悬停中就只记账。
  if self.hovered {
    self.mark_needs_layout()
  }
}

///|
/// 样式层叠解析（§15/§16）：Theme 默认样式 -> 祖先链（由外向内）-> 自身。
/// `base` 来自 `App::style_base`；每层只覆盖显式设置的字段。
///
/// 祖先链不会成环：进入树里的控件都被标了 `attached`，而 `add_child` 与
/// `Window::set_content` 都拒绝已归属的控件，所以这里不需要访问标记。
pub fn[B] Widget::resolved_style(self : Widget[B], base : Style) -> Style {
  let inherited = match self.parent {
    Some(p) => p.resolved_style(base)
    None => base
  }
  let own = match self.style {
    Some(s) => s
    None => Style::empty()
  }
  let merged = inherited.layer(own)
  // 悬停样式叠最上层（皮肤账）：只在这只控件 hovered 时参与层叠。
  match self.hover_style {
    Some(h) => if self.hovered { merged.layer(h) } else { merged }
    None => merged
  }
}

///|
/// 把解析好的生效样式下发到后端的每个叶子（§15/§16）。`base` 来自
/// `App::style_base`，由 `Window::relayout` 在布局**之前**调用——后端测量的正是
/// 这份样式下的文字，顺序反了就会拿到上一个字号的度量去排这一版的矩形。
///
/// 每个节点各算一次 `resolved_style(base)`：它自己沿 parent 链把祖先的覆盖叠进来，
/// 所以往下传的一直是同一个 `base`，不做逐层累加，否则祖先的覆盖会被叠两遍。
/// 纯布局节点（§14）没有原生对象、不下发，但它的覆盖照样进子树的解析结果。
fn[B : Backend] Widget::apply_styles(
  self : Widget[B],
  base : Style,
) -> Unit raise UiError {
  self.check_open()
  let resolved = self.resolved_style(base)
  // Label 只画字：继承来的 `background` 是"这块字站在什么底上"的描述，铺那块底
  // 的人（Panel / 渐变带 / 兄弟窗口）才是该画它的人。直接下发会被后端当成
  // "把整块矩形填成这个色"——Windows 半就是 `OPAQUE` + 实色刷填满客户区，
  // 在纯色底上看不出，一旦底下是渐变或叠层，每只 Label 就露出一块突兀的方块
  // （`T139`：脸面上 `00:00` / `立体声` / `状态:` 五处）。mac 半本来就不给
  // NSTextField 画底，两侧因此还不一致；抹成 None 这一句把两头对齐。
  // **自己显式设过底色**的 Label 照旧画（`self.style` 是局部那一层，不是解析
  // 结果）——那是"这块字要一块底色"，与继承不是一回事。
  let pushed = match self.kind {
    WidgetKind::Label =>
      match self.style {
        Some(s) =>
          match s.background {
            Some(_) => resolved
            None => Style::{ ..resolved, background: None, }
          }
        None => Style::{ ..resolved, background: None, }
      }
    _ => resolved
  }
  match self.handle {
    Some(h) => {
      Backend::set_widget_style(self.backend, h, pushed)
      // §32 的语义跟着样式一起下发（`T41`）：State 是现读的（visible/enabled/
      // checked 都问后端），所以每次重排都推一遍而不是只在建控件时推一次——
      // 改了勾选、禁用之后，下一次重排把语义追上。没有角色的控件没有语义，
      // 一次 FFI 都不多花。
      match self.accessibility() {
        Some(a) => Backend::set_widget_accessibility(self.backend, h, a)
        None => ()
      }
      // T84 opacity 通道（§32 豁免破的那一条）：透明度是动画逐帧推进的值，
      // 单独走 `set_widget_opacity`，变更检测与 bounds 同账（真相 = 激活期
      // span 的 to）。解析值就用上面刚算完的 resolved（Theme -> 祖先 -> 自身
      // 同一条层叠账，不另立第二把尺）。样式那份照走豁免——颜色/圆角第一版不动。
      self.apply_opacity(resolved.opacity)
    }
    None => ()
  }
  for c in self.children {
    c.apply_styles(base)
  }
}

///|
/// T84 opacity 通道的变更检测与下发。`resolved` 是刚沿层叠账算完的生效值
/// （None = 整条链都没写）。零开销闸门：链上没写 opacity、控件也没配动画时，
/// 这条通道一个 FFI 都不花（"无激活动画零开销退回现状"）。首推建立初始态
/// 不过渡（shown 为 None 时直接落）；激活期真相未动就不动显示（泵拥有它）；
/// 变更点配了曲线就记 span、没配就直接落。
fn[B : Backend] Widget::apply_opacity(
  self : Widget[B],
  resolved : Double?,
) -> Unit raise UiError {
  match self.handle {
    Some(h) => {
      let v = anim_clamp01(
        match resolved {
          Some(o) => o
          None => 1.0
        },
      )
      match self.shown_opacity {
        None =>
          if resolved is Some(_) || self.animation_curve is Some(_) {
            self.shown_opacity = Some(v)
            Backend::set_widget_opacity(self.backend, h, v)
          }
        Some(shown) => {
          let target = match self.opacity_anim {
            Some(s) => s.to
            None => shown
          }
          if v == target {
            return
          }
          match self.animation_curve {
            Some(curve) => {
              self.opacity_anim = Some(OpacitySpan::{
                curve,
                start_ms: -1,
                from: shown,
                to: v,
              })
              self.mark_anim()
            }
            None => {
              self.shown_opacity = Some(v)
              Backend::set_widget_opacity(self.backend, h, v)
            }
          }
        }
      }
    }
    None => ()
  }
}

///|
pub fn[B] Widget::frame(self : Widget[B]) -> LogicalRect {
  self.frame
}

///|
/// 绝对边界（逻辑像素）：Core 记下它，叶子同时推给后端。
///
/// `T74` 之后的翻译规则：控件的 Core 侧 `frame` 永远是**窗口内容区的绝对坐标**
/// （`hit_test` / 回读都按它对表），但挂在 Scroll 文档区里的子树，推给后端的
/// 必须是**文档坐标**——原点 = 视口左上角。所以这里沿祖先链找最近的 Scroll，
/// 把它的视口原点平移掉再推。嵌套 Scroll 自动正确：叶子只减最近一层视口的
/// 原点，得到的就是那层文档的坐标；外层的翻译在滚动容器自己被推 bounds 时
/// （它是外层文档的成员）已经完成。
pub fn[B : Backend] Widget::set_bounds(
  self : Widget[B],
  rect : LogicalRect,
) -> Unit raise UiError {
  self.check_open()
  let r = rect.normalized()
  // T84 变更检测对照的是"当下真相"：激活期的真相是 span 的 to（后端显示由
  // 动画泵逐帧追），没在激活期就是上一份 frame。真相没动就不记动画——激活期
  // 的每一次无关重排都不该打扰进行中的插值（显示仍由泵拥有）。
  let target = match self.bounds_anim {
    Some(s) => s.to
    None => self.frame
  }
  if r == target {
    self.frame = r
    // 真相未动：既有语义原样——每次重排都推 bounds，零动画的树一个字不变。
    self.push_bounds_displayed(r)
    return
  }
  self.frame = r
  match self.animation_curve {
    // 变更点记成动画起点（from/to/curve）：from 是后端**当下显示的值**（shown，
    // 被中断的动画从显示值续跑才不会跳），to 是新真相。变更点本身零推送——
    // 显示由泵逐帧追、落点由退场那一帧推（首推建立初始态的那次不过渡）。
    Some(curve) if self.shown_bounds is Some(_) => {
      let from = match self.shown_bounds {
        Some(b) => b
        None => r
      }
      self.bounds_anim = Some(BoundsSpan::{ curve, start_ms: -1, from, to: r, })
      self.mark_anim()
    }
    // 没配动画（或还没建立显示初值）：变更点即落点，照旧直接落。
    _ => self.push_bounds_displayed(r)
  }
}

///|
/// T84 动画泵的 bounds 落点：把一份**绝对坐标**矩形按 `set_bounds` 的同一条
/// 翻译规则（Scroll 文档区平移）推给后端，并记入 shown。激活期的每一帧与
/// 退场帧都走 `set_widget_bounds` 现有 ABI——动画不走第二条几何通道。
fn[B : Backend] Widget::push_bounds_displayed(
  self : Widget[B],
  absolute : LogicalRect,
) -> Unit raise UiError {
  match self.handle {
    Some(h) => {
      let push = match self.enclosing_scroll_origin() {
        Some(o) =>
          LogicalRect(
            LogicalPoint(absolute.origin.x - o.x, absolute.origin.y - o.y),
            absolute.size,
          )
        None => absolute
      }
      self.shown_bounds = Some(push)
      Backend::set_widget_bounds(self.backend, h, push)
      // 自定义绘制面（`T101`）：几何变了就得重画——尺寸变了而清单不重算，
      // 画面会停在上一帧的大小上。放在 bounds 之后（后端此时才知道这块面
      // 多大，物理像素由它自己按 Scale 换）。零尺寸的帧直接跳过：窗口还没
      // 摆出来时每只控件都是 0×0，那种帧没有任何东西可画。
      if self.kind == WidgetKind::Custom {
        self.paint_custom(push.size)
      }
    }
    None => ()
  }
}

///|
/// 自定义绘制面的绘制一趟（`T101`）：调一次回调、把清单交给后端。
///
/// 为什么清单**不**在 Core 里缓存：这份清单的唯一消费者是后端，Core 留着它
/// 只会多出一份可能过期的真话；应用要重画就显式 `repaint`，比"猜缓存何时
/// 失效"可靠。
fn[B : Backend] Widget::paint_custom(
  self : Widget[B],
  size : LogicalSize,
) -> Unit raise UiError {
  match (self.custom_paint, self.handle) {
    (Some(paint), Some(h)) => {
      if size.width <= 0.0 || size.height <= 0.0 {
        return
      }
      let dl = DrawList::new()
      // 度量委托给后端（字体度量属于原生层，§18）。失败给 (0,0)：绘制回调
      // 不许 raise，而"量不到"在正常路径上只可能是空串。
      let backend = self.backend
      let env = PaintEnv::{
        size,
        measure: fn(text, font, bold) {
          Backend::measure_text(backend, text, font, bold) catch {
            _ => (0.0, 0.0)
          }
        },
      }
      paint(dl, env)
      Backend::draw_custom(self.backend, h, dl)
    }
    _ => ()
  }
}

///|
/// 让这块自定义绘制面重画一次（`T101`）。用当前显示尺寸调一遍绘制回调，再
/// 把新清单交给后端——应用的数据变了（播放进度、频谱、表格内容）就调它。
///
/// 尺寸取"后端当下显示的那份"（`shown_bounds`，动画期也准），没推过就从
/// 布局的绝对矩形兜底；两者都没有（还没摆出来）就什么都不做——摆出来那次
/// 会自动画第一帧。
///
/// 非 Custom 控件调用它是空操作，不报错也不 raise：与 `set_text` 那类"有
/// 没有这个属性"的检查不是一回事——重画请求对任何控件都无意义，多调一次
/// 不该是个错误。
pub fn[B : Backend] Widget::repaint(self : Widget[B]) -> Unit raise UiError {
  self.check_open()
  if self.kind != WidgetKind::Custom {
    return
  }
  let size = match self.shown_bounds {
    Some(r) => r.size
    None => self.frame.size
  }
  self.paint_custom(size)
}

///|
/// 把"树上有动画账"的旗标立到 root 上（span 创建时调用）。只有 root 那份
/// 被 App 的泵读，泵靠它零开销跳过无动画的树。
fn[B] Widget::mark_anim(self : Widget[B]) -> Unit {
  let mut top = self
  while top.parent is Some(p) {
    top = p
  }
  top.needs_anim = true
}

///|
/// T84 动画泵的树级推进：本节点两条 span 各推进一帧，再递归子树。返回
/// (本圈是否真的推送过帧、树里还剩几条激活账)——run 的主循环拿第一项判断
/// "这圈有没有进展"，App 拿第二项收拾 root 的旗标与帧钟开关。
///
/// 推进规则（bounds 与 opacity 同一套）：`start_ms < 0` 是起跑圈——补记时刻、
/// 零推送（后端此刻显示的正是 from）；`0 < elapsed < 时长` 推中间帧（曲线进度
/// 的线性混合，走 `set_widget_bounds` / `set_widget_opacity` 现有 ABI）；
/// `elapsed >= 时长` 是退场——推**精确的 to** 不做插值（浮点上 lerp(a,b,1)
/// 未必逐位等 b，判据④靠这条绕行），账清零。时刻 `now` 由 pump 的调用方
/// 注入，动画模块一行不读时钟。
fn[B : Backend] Widget::pump_anim_tree(
  self : Widget[B],
  now : Int32,
) -> (Bool, Int32) raise UiError {
  if self.closed {
    return (false, 0)
  }
  let mut did = false
  let mut remain = 0
  match self.bounds_anim {
    Some(s) => {
      let elapsed = if s.start_ms < 0 {
        s.start_ms = now
        0
      } else {
        now - s.start_ms
      }
      if elapsed >= ANIMATION_DURATION_MS {
        self.push_bounds_displayed(s.to)
        self.bounds_anim = None
        did = true
      } else if elapsed > 0 {
        let k = s.curve.progress(
          elapsed.to_double() / ANIMATION_DURATION_MS.to_double(),
        )
        self.push_bounds_displayed(anim_lerp_rect(s.from, s.to, k))
        did = true
        remain = remain + 1
      } else {
        remain = remain + 1
      }
    }
    None => ()
  }
  match self.opacity_anim {
    Some(s) => {
      let elapsed = if s.start_ms < 0 {
        s.start_ms = now
        0
      } else {
        now - s.start_ms
      }
      if elapsed >= ANIMATION_DURATION_MS {
        self.push_opacity_displayed(s.to)
        self.opacity_anim = None
        did = true
      } else if elapsed > 0 {
        let k = s.curve.progress(
          elapsed.to_double() / ANIMATION_DURATION_MS.to_double(),
        )
        self.push_opacity_displayed(anim_lerp_scalar(s.from, s.to, k))
        did = true
        remain = remain + 1
      } else {
        remain = remain + 1
      }
    }
    None => ()
  }
  for c in self.children {
    let (cd, cr) = c.pump_anim_tree(now)
    if cd {
      did = true
    }
    remain = remain + cr
  }
  (did, remain)
}

///|
/// T84 动画泵的 opacity 落点：把一份 0..1 的透明度真推给后端并记入 shown。
/// 激活期的每一帧与退场帧都走 `set_widget_opacity` 现有 ABI（`T84` 破 §32
/// 豁免的那条通道）。
fn[B : Backend] Widget::push_opacity_displayed(
  self : Widget[B],
  v : Double,
) -> Unit raise UiError {
  match self.handle {
    Some(h) => {
      self.shown_opacity = Some(v)
      Backend::set_widget_opacity(self.backend, h, v)
    }
    None => ()
  }
}

///|
/// T84 没接帧钟时的退化路径：所有激活账当圈直接落**精确的 to**、账清零——
/// 变更点即落点，与无动画树逐位同值（判据④的无动画基线就是这么保持的）。
/// 返回 (是否推送过、剩余账数恒为 0)。
fn[B : Backend] Widget::retire_anim_tree(
  self : Widget[B],
) -> (Bool, Int32) raise UiError {
  if self.closed {
    return (false, 0)
  }
  let mut did = false
  match self.bounds_anim {
    Some(s) => {
      self.push_bounds_displayed(s.to)
      self.bounds_anim = None
      did = true
    }
    None => ()
  }
  match self.opacity_anim {
    Some(s) => {
      self.push_opacity_displayed(s.to)
      self.opacity_anim = None
      did = true
    }
    None => ()
  }
  let mut remain = 0
  for c in self.children {
    let (cd, cr) = c.retire_anim_tree()
    if cd {
      did = true
    }
    remain = remain + cr
  }
  (did, remain)
}

///|
/// 最近一层滚动容器的视口原点（绝对坐标），没有则 `None`。
/// `set_bounds` 用它把绝对矩形平移成文档坐标；scroll 自己的 `frame`
/// 由 `do_layout` 先序写回（Scroll 的 Placed 排在其子树之前），所以
/// 走到这里时祖先的视口原点总是已知的。
fn[B] Widget::enclosing_scroll_origin(self : Widget[B]) -> LogicalPoint? {
  let mut p = self.parent
  let mut found : LogicalPoint? = None
  while p is Some(w) {
    if w.kind == WidgetKind::Scroll {
      found = Some(w.frame.origin)
      break
    }
    p = w.parent
  }
  found
}

///|
/// 把滚动内容区的尺寸（滚动行程）推给后端：后端据此给文档视图定尺寸
/// （NSScrollView 的 documentView）、并按主轴配滚动条。约束与 `layout_scroll`
/// 里那一次测量**同一份**（松约束 + 主轴放开），所以推下去的数就是布局
/// 刚刚算出的内容尺寸，两个地方不会各说各话。
fn[B : Backend] Widget::push_scroll_content(
  self : Widget[B],
) -> Unit raise UiError {
  match self.handle {
    Some(h) => {
      let child = self.only_child("Scroll")
      let c = BoxConstraints::loose(
        self.frame.size.width,
        self.frame.size.height,
      )
      let content = measure(
        child.to_layout_spec(),
        unbounded_main(self.axis, c),
      )
      Backend::set_scroll_content(self.backend, h, self.axis, content)
    }
    None => ()
  }
}

///|
pub fn[B : Backend] Widget::bounds(
  self : Widget[B],
) -> LogicalRect raise UiError {
  self.check_open()
  match self.handle {
    Some(h) => Backend::widget_bounds(self.backend, h)
    None => self.frame
  }
}

///|
/// 原生固有尺寸：叶子问后端（字体度量属于原生层，§18），布局节点为零。
pub fn[B : Backend] Widget::intrinsic_size(
  self : Widget[B],
) -> LogicalSize raise UiError {
  match self.handle {
    Some(h) => self.leaf_intrinsic(h)
    None => LogicalSize::zero()
  }
}

///|
/// MenuRow 的 CSS padding 账：内容尺寸由后端报（字体度量属于原生层，§18），
/// padding 由 Core 在这一处加（宽 +左右、高 +上下）——零 insets 是 no-op，
/// 其余叶子不设 insets。`intrinsic_size` 读回与 `to_layout_spec` 的固有值
/// 共用这个账，不出现"读回一个样、摆出来另一个样"。背景画在按钮自己的
/// bounds 里，加 padding 即背景长大。
///
/// 定宽/定高覆盖（`T94`）也在这一处消费：外观链 `.width()`/`.height()` 存进
/// 自层样式（同 `own_margin` 的口径——非继承，不经祖先链层叠），Some 的那维
/// 盖掉的就是**最终那一维**——MenuRow 的 insets 只在未覆盖时才加进去，覆盖
/// 生效时 100.0 就是 100.0，不再叠 insets。普通叶子与 MenuRow 因此同一语义。
///
/// 只服务叶子（带句柄的控件）；Row/Column/Scroll 等纯布局节点走各自的 spec
/// 分支，`.width()` 打在上面会被存下但无人消费——容器定宽请用
/// `Widget::sized`（评审中项记案）。
fn[B : Backend] Widget::leaf_intrinsic(
  self : Widget[B],
  h : NativeHandle,
) -> LogicalSize raise UiError {
  let base = Backend::widget_intrinsic_size(self.backend, h)
  // 自层样式的两维覆盖直读（不构造空样式——无样式叶子每次测量零开销）。
  let own_w = match self.style {
    Some(s) => s.width
    None => None
  }
  let own_h = match self.style {
    Some(s) => s.height
    None => None
  }
  match self.kind {
    WidgetKind::MenuRow =>
      LogicalSize(
        match own_w {
          Some(fixed) => fixed
          None => base.width + self.insets.horizontal()
        },
        match own_h {
          Some(fixed) => fixed
          None => base.height + self.insets.vertical()
        },
      )
    // 自定义绘制面（`T101`）：固有尺寸取声明值，不问后端——那块面没有系统
    // 外观，多大是应用的账（后端那边量出来只会是 0）。`.width()`/`.height()`
    // 的覆盖在这里同样生效，与普通叶子一条规矩。
    WidgetKind::Custom =>
      LogicalSize(
        match own_w {
          Some(fixed) => fixed
          None => self.custom_size.width
        },
        match own_h {
          Some(fixed) => fixed
          None => self.custom_size.height
        },
      )
    _ =>
      LogicalSize(
        match own_w {
          Some(fixed) => fixed
          None => base.width
        },
        match own_h {
          Some(fixed) => fixed
          None => base.height
        },
      )
  }
}

///|
/// 挂接子控件（§8）。已被持有的控件不能二次归属，否则窗口销毁时会出现
/// 两个父级各自销毁同一个原生对象——文档 §47 风险 2 的另一种形态。
pub fn[B] Widget::add_child(
  self : Widget[B],
  child : Widget[B],
) -> Unit raise UiError {
  self.check_open()
  if self.kind == WidgetKind::Spacer {
    raise Unsupported("Spacer 不能有子控件")
  }
  if child.closed {
    raise Destroyed
  }
  if child.attached {
    raise AlreadyOwned
  }
  child.attached = true
  child.parent = Some(self)
  self.children.push(child)
}

///|
/// 销毁控件：先销毁叶子（原生对象在这里消失），再清 Core 引用。
/// 子树整棵一起关闭，因为 §8 的所有权是"容器持有子项"。
/// 0.1 不提供"从父级摘下单个控件"——那需要控件的引用身份比较，等 §40 的
/// 动态列表真要用时再设计，避免现在塞进一个语义含糊的 API。
pub fn[B : Backend] Widget::close_tree(self : Widget[B]) -> Unit raise UiError {
  if self.closed {
    raise Destroyed
  }
  for c in self.children {
    c.close_tree()
  }
  self.children = []
  match self.handle {
    Some(h) => {
      Backend::destroy_widget(self.backend, h)
      self.handle = None
    }
    None => ()
  }
  self.handlers = []
  // 传播阶段的两张表跟直派那张一起清（§47 风险 1 的闭包泄漏检查同账）
  self.capture_handlers = []
  self.bubble_handlers = []
  self.parent = None
  self.attached = false
  self.closed = true
}

///|
/// 树中叶子控件数（含自身），用来断言"销毁后后端句柄归零"。
pub fn[B] Widget::leaf_count(self : Widget[B]) -> Int32 {
  let mut n = match self.handle {
    Some(_) => 1
    None => 0
  }
  for c in self.children {
    n = n + c.leaf_count()
  }
  n
}

///|
/// 收集子树里所有叶子的原生句柄，供 `Window::set_content` 挂接到窗口（§8）。
/// 布局节点没有句柄，因此不出现在结果里——这正是 §14 那条决定的直接体现。
fn[B] Widget::collect_native(
  self : Widget[B],
  out : Array[NativeHandle],
) -> Unit {
  match self.handle {
    Some(h) => out.push(h)
    None => ()
  }
  for c in self.children {
    c.collect_native(out)
  }
}

///|
/// 按挂接目标收集 (容器, 叶子) 对（`T74`）：`None` = 挂进窗口。Scroll 有原生
/// 对象，它的子树挂进**它**而不是窗口；嵌套 Scroll 时每层子树认自己那层。
/// 先序遍历，与 `collect_native` 同序——挂接顺序就是 Tab 顺序（§14）。
fn[B] Widget::collect_attach(
  self : Widget[B],
  container : NativeHandle?,
  out : Array[(NativeHandle?, NativeHandle)],
) -> Unit {
  match self.handle {
    Some(h) => {
      out.push((container, h))
      // Scroll / Panel 认领自己的子树；其余带句柄的都是叶子（§14），没有子树
      // 可言。Panel 与 Scroll 同形：它的原生 view 是子树的挂接容器。
      let claims = self.kind == WidgetKind::Scroll ||
        self.kind == WidgetKind::Panel
      let inner = if claims { Some(h) } else { container }
      for c in self.children {
        c.collect_attach(inner, out)
      }
    }
    None =>
      for c in self.children {
        c.collect_attach(container, out)
      }
  }
}

///|
/// 按坐标命中子树里的叶子（`Window::widget_at` 的实现）。
///
/// 只有**叶子**在 Core 里有矩形：`do_layout` 写回的是 `Placed` 那批带 id 的项，而纯布局
/// 节点没有句柄、也就没有 id，进不了那批项（上面 `do_layout` 里 `find_by_id` 那一步）。
/// 所以这里不是在矩形之间做层叠挑选，而是按绘制顺序走一遍树、留**最后一个**含住这个点的
/// 叶子：`Stack` 的数组靠后画在上层（§14、`apply_layers` 那段），其余容器互不重叠，
/// 于是"后遍历到的赢"这一条对所有容器都恰好正确。
fn[B] Widget::hit_test(self : Widget[B], p : LogicalPoint) -> Widget[B]? {
  let here : Widget[B]? = match self.handle {
    Some(_) => if self.frame.contains(p) { Some(self) } else { None }
    None => None
  }
  let mut found = here
  for c in self.children {
    // 后画的盖住先画的（§14：Stack 数组靠后的在上层，其余容器互不重叠），
    // 同一个点被两层都含住时取后面那一次。
    found = match c.hit_test(p) {
      None => found
      deeper => deeper
    }
  }
  found
}

///|
/// 算出整棵子树的**绘画顺序**（从顶层到底层），`Window::set_content` 在挂载之后
/// 调，把结果整份推给后端（`Backend::set_paint_order`，`T29`）。
///
/// 规则就是 §14 的层叠契约本身，不再借原生 z-order 的增量去凑：
/// - 普通容器（Row / Column / …）：先序、数组顺序——先声明的画在上层。
/// - `Stack`：把整棵子树的叶子按先序收齐后**倒过来**——数组靠后的画在上层。
///   Stack 因此"认领"它下面所有叶子（含嵌套容器里的），和旧实现里 `raise_leaves`
///   递归整棵子树是同一件事，只是这里一次算清、不再逐个 raise。
///
/// 为什么能整份推而不是逐个 raise：`raise_widget` 假定"层叠 = 原生 z-order"，自绘
/// 后端（§51 的 Backend #2）没有 z-order，它要的正是这份列表。Core 只说"顺序是什么"，
/// 后端自己决定怎么落（原生控件后端翻译成 z-order，自绘后端存下来当绘制顺序）。
fn[B] Widget::paint_order(self : Widget[B], out : Array[NativeHandle]) -> Unit {
  if self.kind == WidgetKind::Stack {
    let leaves : Array[NativeHandle] = []
    self.collect_native(leaves)
    for i = leaves.length() - 1; i >= 0; i = i - 1 {
      out.push(leaves[i])
    }
  } else if self.kind == WidgetKind::Panel {
    // 面板是**背景**：它必须垫在子控件下面，不能盖住自己的内容。先序会把它
    // 推在子控件之前（= 更靠顶层，见 §14 的层叠契约），那样面板的不透明底色
    // 会把整段文字/按钮抹掉——真窗上的现象就是"只有一条条纯色带，字和控件
    // 全不见"。所以面板这一格反过来：先收子树，最后推自己。
    for c in self.children {
      c.paint_order(out)
    }
    match self.handle {
      Some(h) => out.push(h)
      None => ()
    }
  } else {
    match self.handle {
      Some(h) => out.push(h)
      None => ()
    }
    for c in self.children {
      c.paint_order(out)
    }
  }
}

///|
/// 沿 Core 树找叶子控件；`do_layout` 用它把算好的矩形写回控件。
/// id 来自全局句柄表，所以窗口与控件不会互相冒充（§6）。
pub fn[B] Widget::find_by_id(self : Widget[B], id : Int32) -> Widget[B]? {
  match self.handle {
    Some(mine) =>
      if mine.id == id {
        Some(self)
      } else {
        lookup_children(self.children, id)
      }
    None => lookup_children(self.children, id)
  }
}

///|
/// 按整个 `EventTarget`（id + generation，`T49`）在树里找控件。和 `find_by_id`
/// 同一条遍历，命中条件多了 generation——`do_layout` 那个调用点按 `Placed.id`
/// 找控件，没有 generation 可比，仍走 `find_by_id`。
pub fn[B] Widget::find_by_target(
  self : Widget[B],
  t : EventTarget,
) -> Widget[B]? {
  match self.handle {
    Some(mine) =>
      if EventTarget::of(mine) == t {
        Some(self)
      } else {
        lookup_children_target(self.children, t)
      }
    None => lookup_children_target(self.children, t)
  }
}

///|
fn[B] lookup_children_target(
  children : Array[Widget[B]],
  t : EventTarget,
) -> Widget[B]? {
  let mut found : Widget[B]? = None
  for c in children {
    match c.find_by_target(t) {
      Some(w) => found = Some(w)
      None => ()
    }
  }
  found
}

///|
fn[B] lookup_children(children : Array[Widget[B]], id : Int32) -> Widget[B]? {
  let mut found : Widget[B]? = None
  for c in children {
    match c.find_by_id(id) {
      Some(w) => found = Some(w)
      None => ()
    }
  }
  found
}

///|
/// 接入 §14 的布局引擎：控件树 -> LayoutSpec。
/// 叶子的固有尺寸来自后端测量，容器用 Core 侧的 spacing/insets。
pub fn[B : Backend] Widget::to_layout_spec(
  self : Widget[B],
) -> LayoutSpec raise UiError {
  match self.kind {
    WidgetKind::Spacer => LayoutSpec::Spacer
    WidgetKind::Row =>
      LayoutSpec::Row(LineSpec::{
        axis: Horizontal,
        spacing: self.spacing,
        children: self.child_specs(),
      })
    WidgetKind::Column =>
      LayoutSpec::Column(LineSpec::{
        axis: Vertical,
        spacing: self.spacing,
        children: self.child_specs(),
      })
    WidgetKind::Padding => {
      let child = self.only_child("Padding")
      LayoutSpec::Padding(PaddingSpec::{
        insets: self.insets,
        child: child.to_layout_spec(),
      })
    }
    WidgetKind::Center => {
      let child = self.only_child("Center")
      LayoutSpec::Center(CenterSpec::{ child: child.to_layout_spec(), })
    }
    WidgetKind::Stack =>
      LayoutSpec::Stack(StackSpec::{ children: self.child_specs(), })
    WidgetKind::Grid =>
      LayoutSpec::Grid(GridSpec::{
        columns: self.columns,
        spacing: self.spacing,
        children: self.child_specs(),
      })
    WidgetKind::Scroll => {
      let child = self.only_child("Scroll")
      LayoutSpec::Scroll(ScrollSpec::{
        id: self.need_handle().id,
        axis: self.axis,
        child: child.to_layout_spec(),
      })
    }
    WidgetKind::Panel => {
      let child = self.only_child("Panel")
      let insets = match self.style {
        Some(s) =>
          match s.padding {
            Some(e) => e
            None => EdgeInsets::zero()
          }
        None => EdgeInsets::zero()
      }
      LayoutSpec::Panel(PanelSpec::{
        id: self.need_handle().id,
        insets,
        child: child.to_layout_spec(),
      })
    }
    WidgetKind::Sized => {
      let child = self.only_child("Sized")
      LayoutSpec::Sized(SizedSpec::{
        width: self.fixed_w,
        height: self.fixed_h,
        child: child.to_layout_spec(),
      })
    }
    _ => {
      let h = self.need_handle()
      LayoutSpec::Leaf(LeafSpec::{
        id: h.id,
        intrinsic: self.leaf_intrinsic(h),
        expand: self.expand,
        // MenuRow 要铺满交叉轴（画册左栏一行一项，选中高亮铺满整行宽度），主轴保持
        // 固有——见 LeafSpec.fill_cross 的说明。其余叶子保持固有尺寸。
        fill_cross: self.kind == WidgetKind::MenuRow,
      })
    }
  }
}

///|
/// `T87①` 的 margin 读取口：只读这一层自己的 Style（§15 的局部覆盖）。
/// margin 非继承（CSS 的 margin 同一条规矩）——容器设的 margin 是"容器这层
/// 与周围拉开多少"，不该漏给子项；Theme 第一版也不给 margin（主题只给配色/
/// 字号，§16 的默认样式表里没有它），所以自层直读就是全部语义，不经
/// `resolved_style` 的祖先链去层叠。
fn[B] Widget::own_margin(self : Widget[B]) -> EdgeInsets? {
  match self.style {
    Some(s) => s.margin
    None => None
  }
}

///|
fn[B : Backend] Widget::child_specs(
  self : Widget[B],
) -> Array[LayoutSpec] raise UiError {
  let out : Array[LayoutSpec] = []
  for c in self.children {
    let mut s = c.to_layout_spec()
    // `T87①` 外边距进布局：容器摆子项 = 子项 + margin（"这一层和周围拉开
    // 多少"，与 insets 的"容器把子项往里压多少"各归各——条目原句）。载体是
    // 既有 `Padding` 节点：外扩（占用长大）与内缩（frame 缩进）的几何账都在
    // layout.mbt 的 measure/layout 同一处算（§14 的归属不动，`T55` 标脏语义
    // 同族——margin 变了 `set_style` 已经标脏，下一轮 step 重排就追上），这里
    // 不立第二把尺。包层顺序在 Expand **里面**：弹性项的 margin 先吃掉自己
    // 这一圈、再谈吃剩余空间——`count_expand` 认的还是最外层 Expand。
    // 未设置或全零不包节点：spec 逐位不变，无 margin 的树布局账逐位照旧。
    let mut wrapped = false
    match c.own_margin() {
      Some(e) =>
        if e.horizontal() > 0.0 || e.vertical() > 0.0 {
          s = LayoutSpec::Padding(PaddingSpec::{ insets: e, child: s, })
          wrapped = true
        }
      None => ()
    }
    // 叶子的弹性记在 LeafSpec.expand 上；容器要参与剩余空间分配，只能在它
    // 外面包一层 Expand——否则它后面兄弟项会被推进无限区。Scroll 虽然占用
    // 原生对象（T74），但在行里同样靠 Expand 吃剩余主轴（右栏滚动的宽度、
    // 列表滚动的剩余高度都从这来），所以它也走这一包。配了 margin 的弹性
    // 子项（叶子也含）同账：margin 包层在外面再包 Expand，弹性才认得。
    out.push(
      if c.expand &&
        (c.kind.is_layout_only() || c.kind == WidgetKind::Scroll || wrapped) {
        LayoutSpec::Expand(s)
      } else {
        s
      },
    )
  }
  out
}

///|
fn[B] Widget::only_child(
  self : Widget[B],
  what : String,
) -> Widget[B] raise UiError {
  if self.children.length() != 1 {
    raise OperationFailed("\{what} 必须恰好有一个子控件")
  }
  self.children[0]
}

///|
/// 测量整棵子树的固有尺寸（§14）。
pub fn[B : Backend] Widget::measure(
  self : Widget[B],
  c : BoxConstraints,
) -> LogicalSize raise UiError {
  measure(self.to_layout_spec(), c)
}

///|
/// 在给定框架内布局，把每个叶子的绝对边界写回后端（§14、§18 的公共入口）。
/// 返回值与 `layout` 的一致，方便断言。
pub fn[B : Backend] Widget::do_layout(
  self : Widget[B],
  frame : LogicalRect,
) -> Array[Placed] raise UiError {
  self.check_open()
  let placed : Array[Placed] = []
  layout(self.to_layout_spec(), frame, placed)
  for p in placed {
    match self.find_by_id(p.id) {
      Some(w) => {
        // `T74`：滚动容器的视口先就位，内容尺寸（滚动行程）紧跟着推——
        // 后端要先有视口与文档尺寸，子树的文档坐标才有处可落。
        w.set_bounds(p.frame)
        if w.kind == WidgetKind::Scroll {
          w.push_scroll_content()
        }
      }
      None => raise InvalidHandle
    }
  }
  placed
}

///|
/// 通用订阅：`accept` 决定放行哪些事件，返回 handler id。
/// handler 失败会沿 `dispatch` 传出，控件不吞异常（§33）。
pub fn[B] Widget::on(
  self : Widget[B],
  accept : (Event) -> Bool,
  handler : (Event) -> Unit raise UiError,
) -> Int32 raise UiError {
  self.check_open()
  let id = self.next_handler_id
  self.next_handler_id = id + 1
  self.handlers.push(HandlerEntry::{ id, accept, call: handler, })
  id
}

///|
/// 当前 handler 数：`close_tree` 之后应为 0（§47 风险 1 的闭包泄漏检查）。
pub fn[B] Widget::handler_count(self : Widget[B]) -> Int32 {
  self.handlers.length()
}

///|
/// 派发一个事件到本控件的 handler，返回调用次数。
///
/// 先把本轮开始的 handler 快照出来再遍历：只快照长度的写法会在
/// "handler 把自家控件关掉"（换整棵内容树，例如列表删除一行）之后按下标读到
/// 已经被 `close_tree` 清空的数组，越界崩溃。快照之后还多一道闸门——控件一旦
/// 被销毁，本轮剩余 handler 不再调用，它们绑定的原生对象已经不在了。
pub fn[B] Widget::fire(self : Widget[B], ev : Event) -> Int32 raise UiError {
  self.fire_round(ev, self.handlers, None)
}

///|
/// 直派回合的公共芯（`T88①` 抽出，`fire` 与直派账共用一份回合账）：快照 →
/// 逐格 accept → 放行调用。`record` 只在开账时非 None；挡下的格子也记
/// （"accept 与否"的另一半）。语义与旧 fire 逐位同值——accept 每格恰好
/// 裁决一次、快照后中途关账的剩余格子既不调用也不记。
fn[B] Widget::fire_round(
  self : Widget[B],
  ev : Event,
  entries : Array[HandlerEntry],
  record : ((Bool) -> Unit)?,
) -> Int32 raise UiError {
  if self.closed {
    raise Destroyed
  }
  let round : Array[HandlerEntry] = []
  let n = entries.length()
  for i = 0; i < n; i = i + 1 {
    round.push(entries[i])
  }
  let mut hits = 0
  for e in round {
    if self.closed {
      ()
    } else {
      let accepted = (e.accept)(ev)
      match record {
        Some(rec) => rec(accepted)
        None => ()
      }
      if accepted {
        (e.call)(ev)
        hits = hits + 1
      }
    }
  }
  hits
}

///|
/// 传播阶段的拦截口（§9/§10 的 capture 语义，`T86⑨`）：capture 自根向 target
/// 走，中途某只控件的拦截口返回 false 即停止后续阶段——target 直派（既有账）
/// 与冒泡都不跑。装了拦截口而不返回 false，对事件路径零影响。
///
/// handler 的失败沿 `dispatch` 传出（§33，与直派同账）；handler id 与 `on`
/// 的直派订阅同一个编号空间（`close_tree` 一起清零）。
pub fn[B] Widget::on_capture(
  self : Widget[B],
  accept : (Event) -> Bool,
  handler : (Event) -> Bool raise UiError,
) -> Int32 raise UiError {
  self.check_open()
  let id = self.next_handler_id
  self.next_handler_id = id + 1
  self.capture_handlers.push(PhaseEntry::{ id, accept, call: handler, })
  id
}

///|
/// 传播阶段的冒泡口（`T86⑨`）：target 直派既有账跑完之后，自 target 向根路过
/// 装了冒泡口的控件。冒泡口是观察者——不能拦截（"停止后续阶段"只有 capture
/// 有，`on_capture` 的段注），返回值被包装层恒真吃掉。
pub fn[B] Widget::on_bubble(
  self : Widget[B],
  accept : (Event) -> Bool,
  handler : (Event) -> Unit raise UiError,
) -> Int32 raise UiError {
  self.check_open()
  let id = self.next_handler_id
  self.next_handler_id = id + 1
  self.bubble_handlers.push(PhaseEntry::{
    id,
    accept,
    call: fn(ev) raise UiError {
      handler(ev)
      true
    },
  })
  id
}

///|
/// 自 target 向根收出一条控件链（`T86⑨` 的两阶段共用）：链上含 target 自己。
/// 祖先链不成环的证明与 `resolved_style` 同一句——进树的控件都标了 `attached`，
/// `add_child` / `set_content` 拒绝二次归属（§8）。
fn[B] Widget::phase_chain(self : Widget[B], out : Array[Widget[B]]) -> Unit {
  let mut cur : Widget[B]? = Some(self)
  while cur is Some(w) {
    out.push(w)
    cur = w.parent
  }
}

///|
/// 跑一遍一张阶段表的快照（`T86⑨`；`T88①` 加记录口）。纪律沿 `fire`：先快照
/// 再遍历，handler 把自家控件关掉之后本轮剩余条目不再调用（控件没了，绑定的
/// 原生对象也不在了）。`stop_on_false` 只有 capture 用：返回 false 即向调用方
/// 喊停——拦截的那格已记账（accepted = true：跑了才拦得住），本格之后的剩余
/// 条目既不调用也不记（它们没跑，账上是缺席不是挡下）。`record` 只在开账时
/// 非 None（`T88①`）——挡下的格子同样记账（"accept 与否"的另一半），语义与
/// 旧账逐位同值：accept 每格恰好裁决一次。
fn[B] Widget::run_phase_entries(
  self : Widget[B],
  entries : Array[PhaseEntry],
  ev : Event,
  stop_on_false : Bool,
  record : ((Bool) -> Unit)?,
) -> Bool raise UiError {
  if self.closed {
    return true
  }
  let round : Array[PhaseEntry] = []
  let n = entries.length()
  for i = 0; i < n; i = i + 1 {
    round.push(entries[i])
  }
  for e in round {
    if self.closed {
      ()
    } else {
      let accepted = (e.accept)(ev)
      match record {
        Some(rec) => rec(accepted)
        None => ()
      }
      if accepted {
        let again = (e.call)(ev)
        if stop_on_false && !again {
          return false
        }
      }
    }
  }
  true
}

///|
/// capture 阶段（`T86⑨`；`T88①` 加逐格记账）：自根向 target（含 target 自己）
/// 路过装了拦截口的控件，逐格记账；返回 false = 有人拦截，调用方在账上立
/// `intercepted` 位、停止后续阶段（target 直派与冒泡全部停止）。
fn[B] Widget::run_capture_phase(
  self : Widget[B],
  ev : Event,
  accum : DispatchTrace?,
) -> Bool raise UiError {
  let chain : Array[Widget[B]] = []
  self.phase_chain(chain)
  for i = chain.length() - 1; i >= 0; i = i - 1 {
    let w = chain[i]
    let record = match accum {
      Some(t) =>
        Some(
          trace_record(fn(t, stop) { t.capture.push(stop) }, t, w.trace_owner()),
        )
      None => None
    }
    if !w.run_phase_entries(w.capture_handlers, ev, true, record) {
      match accum {
        Some(t) => t.intercepted = true
        None => ()
      }
      return false
    }
  }
  true
}

///|
/// 冒泡阶段（`T86⑨`；`T88①` 加逐格记账）：自 target 向根（含 target 自己）
/// 路过装了冒泡口的控件。观察者阶段——没人能在这里喊停（拦截是 capture 的
/// 特权，`on_capture` 段注），账上 accepted = true 的格子才是跑了的格子。
fn[B] Widget::run_bubble_phase(
  self : Widget[B],
  ev : Event,
  accum : DispatchTrace?,
) -> Unit raise UiError {
  let chain : Array[Widget[B]] = []
  self.phase_chain(chain)
  for i = 0; i < chain.length(); i = i + 1 {
    let w = chain[i]
    let record = match accum {
      Some(t) =>
        Some(
          trace_record(fn(t, stop) { t.bubble.push(stop) }, t, w.trace_owner()),
        )
      None => None
    }
    let _ = w.run_phase_entries(w.bubble_handlers, ev, false, record)
  }
}

///|
/// 路由到 target 时的事件路径（§9/§10，`T86⑨`；`T88①` 加记录口）：
/// capture（根→target，可拦截）→ target 直派（既有账，`fire` 的芯原位共用）
/// → 冒泡（target→根，观察者）。没装拦截口/冒泡口的树两阶段恒空、一次调用
/// 都不发生——账上也恒空，缺席与缺席互证；关账（accum = None）逐位走旧账。
fn[B] Widget::route_with_phases(
  self : Widget[B],
  ev : Event,
  accum : DispatchTrace?,
) -> Unit raise UiError {
  if !self.run_capture_phase(ev, accum) {
    return
  }
  let record = match accum {
    Some(t) =>
      Some(
        trace_record(fn(t, stop) { t.direct.push(stop) }, t, self.trace_owner()),
      )
    None => None
  }
  let _ = self.fire_round(ev, self.handlers, record)
  self.run_bubble_phase(ev, accum)
}

///|
/// §10 的高级 API：`button.on_click(...)`。种类不匹配不会报错——
/// 事件本来就可能来自任何地方，过滤器只在真的收到时放行。
pub fn[B] Widget::on_click(
  self : Widget[B],
  f : () -> Unit raise UiError,
) -> Int32 raise UiError {
  self.on(
    ev => {
      match ev {
        Click(_, _) => true
        _ => false
      }
    },
    fn(_) raise UiError { f() },
  )
}

///|
pub fn[B] Widget::on_double_click(
  self : Widget[B],
  f : () -> Unit raise UiError,
) -> Int32 raise UiError {
  self.on(
    ev => {
      match ev {
        DoubleClick(_) => true
        _ => false
      }
    },
    fn(_) raise UiError { f() },
  )
}

///|
pub fn[B] Widget::on_change(
  self : Widget[B],
  f : () -> Unit raise UiError,
) -> Int32 raise UiError {
  self.on(
    ev => {
      match ev {
        Change(_) => true
        _ => false
      }
    },
    fn(_) raise UiError { f() },
  )
}

///|
/// 文本变化，携带变化后的全文（§10 的 `Input`）。
pub fn[B] Widget::on_input(
  self : Widget[B],
  f : (String) -> Unit raise UiError,
) -> Int32 raise UiError {
  self.on(
    ev => {
      match ev {
        Input(_, _) => true
        _ => false
      }
    },
    fn(ev) raise UiError {
      match ev {
        Input(_, text) => f(text)
        _ => ()
      }
    },
  )
}

///|
pub fn[B] Widget::on_focus(
  self : Widget[B],
  f : () -> Unit raise UiError,
) -> Int32 raise UiError {
  self.on(
    ev => {
      match ev {
        Focus(_) => true
        _ => false
      }
    },
    fn(_) raise UiError { f() },
  )
}

///|
pub fn[B] Widget::on_blur(
  self : Widget[B],
  f : () -> Unit raise UiError,
) -> Int32 raise UiError {
  self.on(
    ev => {
      match ev {
        Blur(_) => true
        _ => false
      }
    },
    fn(_) raise UiError { f() },
  )
}

///|
/// 不过滤任何事件，用于集成测试与全局观察。
pub fn[B] Widget::on_any(
  self : Widget[B],
  handler : (Event) -> Unit raise UiError,
) -> Int32 raise UiError {
  self.on(_ => true, handler)
}

///|
fn mock_widgets() -> MockBackend raise UiError {
  let b = MockBackend::new()
  Backend::init(b)
  b
}

///|
/// §33：控件不吞 handler 的异常，测试里统一用它把错误收成语明。
fn widget_error(body : () -> Unit raise UiError) -> String? {
  let out : String? = try {
    body()
    None
  } catch {
    e => Some(UiError::message(e))
  }
  out
}

///|
fn rect(x : Double, y : Double, w : Double, h : Double) -> LogicalRect {
  LogicalRect(LogicalPoint(x, y), LogicalSize(w, h))
}

///|
test "叶子控件的属性读写都走 Backend，种类守卫拦住误用" {
  let b = mock_widgets()
  let label = Widget::label(b, "Title")
  assert_eq(label.kind(), WidgetKind::Label)
  assert_true(label.handle() is Some(_))
  assert_eq(label.text(), "Title")
  assert_eq(label.intrinsic_size(), LogicalSize(48.0, 20.0))
  label.set_text("Longer title")
  assert_eq(label.text(), "Longer title")
  // 文本变长，固有尺寸跟着变——真实后端就是重新测量
  assert_eq(label.intrinsic_size().width, 104.0)
  label.set_visible(false)
  assert_false(label.visible())
  label.set_enabled(false)
  assert_false(label.enabled())
  label.set_style(Some(Style::empty()))
  assert_eq(label.style(), Some(Style::empty()))

  let btn = Widget::button(b, "Ok")
  assert_eq(btn.intrinsic_size(), LogicalSize(40.0, 28.0))
  let input = Widget::text_input(b, "")
  assert_eq(input.intrinsic_size(), LogicalSize(160.0, 24.0))
  let cb = Widget::checkbox(b, "On", true)
  assert_true(cb.checked())
  cb.set_checked(false)
  assert_false(cb.checked())

  // 属性种类守卫：每个误用都是明确错误，不是静默无效
  assert_eq(
    widget_error(fn() raise UiError { label.set_checked(true) }),
    Some("不支持的操作：只有复选框和菜单行有勾选状态"),
  )
  assert_eq(
    widget_error(fn() raise UiError { label.set_spacing(4.0) }),
    Some("不支持的操作：只有 Row/Column/Grid 有间距"),
  )
  assert_eq(
    widget_error(fn() raise UiError { label.set_insets(EdgeInsets::zero()) }),
    Some("不支持的操作：只有 Padding 与 MenuRow 有内边距"),
  )
  assert_eq(widget_error(fn() raise UiError { btn.set_text("x") }), None)
  let row0 = Widget::row(b, 0.0, [])
  assert_eq(
    widget_error(fn() raise UiError { row0.set_text("x") }),
    Some("不支持的操作：该控件没有文本属性"),
  )
}

///|
/// MenuRow 的内边距走 CSS 账（§51）：加 padding 即背景长大——固有 = 内容 +
/// insets，读回（intrinsic_size）与摆出来（to_layout_spec）共用 leaf_intrinsic
/// 一个账，不出现"读回一个样、摆出来另一个样"；绘制语义（文字缩进）推给后端，
/// mock 记下最近一次推的值，测试断言"语义真的到了后端"，而不是 Core 里算得
/// 对就算完（同 accessibility / scroll_content 先例）。
test "MenuRow 内边距：固有尺寸长大，绘制语义推到后端" {
  let b = mock_widgets()
  let row = Widget::menu_row(b, "Label 文本", false)
  let base = row.intrinsic_size()
  row.set_insets(EdgeInsets::all(8.0))
  // 读回长大：宽 +左右（16）、高 +上下（16）
  assert_eq(
    row.intrinsic_size(),
    LogicalSize(base.width + 16.0, base.height + 16.0),
  )
  assert_eq(row.insets(), EdgeInsets::all(8.0))
  // 标脏（T55）：内边距一变固有尺寸就变，没有别的事顺手触发重排，
  // 控件就顶着旧矩形——构造时 set_checked 已把整条脏链点亮过，这里再点亮一次
  assert_true(row.needs_layout)
  // 摆出来同一个账：to_layout_spec 的固有值等于读回值
  assert_eq(
    row.to_layout_spec(),
    LayoutSpec::Leaf(LeafSpec::{
      id: row.need_handle().id,
      intrinsic: LogicalSize(base.width + 16.0, base.height + 16.0),
      expand: false,
      fill_cross: true,
    }),
  )
  // 绘制语义真的到了后端：mock 把最近一次推下来的 insets 记在控件上
  assert_eq(b.widget(row.need_handle()).insets, EdgeInsets::all(8.0))
}

///|
/// §8：容器持有子项。已被持有的控件不能二次归属，否则销毁时会有两个父级
/// 各自销毁同一个原生对象。
test "容器持有子项，二次归属与已销毁子项都被拒绝" {
  let b = mock_widgets()
  let btn = Widget::button(b, "Ok")
  let row1 = Widget::row(b, 0.0, [btn])
  let row2 = Widget::column(b, 0.0, [])
  assert_true(btn.is_attached())
  assert_eq(
    widget_error(fn() raise UiError { row2.add_child(btn) }),
    Some("该控件已被其他容器持有"),
  )
  assert_eq(row1.children().length(), 1)
  assert_eq(row2.children().length(), 0)

  let orphan = Widget::label(b, "Gone")
  orphan.close_tree()
  assert_eq(
    widget_error(fn() raise UiError { row2.add_child(orphan) }),
    Some("对象已销毁"),
  )
  // 关闭后的控件任何操作都是 Destroyed
  assert_eq(
    widget_error(fn() raise UiError { let _ = orphan.text() }),
    Some("对象已销毁"),
  )
  // Spacer 是终端节点
  let sp = Widget::spacer(b)
  assert_eq(
    widget_error(fn() raise UiError { sp.add_child(btn) }),
    Some("不支持的操作：Spacer 不能有子控件"),
  )
  assert_eq(
    widget_error(fn() raise UiError { sp.set_expand(false) }),
    Some("不支持的操作：Spacer 本身就是弹性项"),
  )
}

///|
/// Row 的绝对边界：主轴按固有尺寸累加、间距只加在相邻项之间，
/// 交叉轴保持固有尺寸，算完写回后端（§14）。
test "Row 布局把绝对边界写回每个叶子控件" {
  let b = mock_widgets()
  let label = Widget::label(b, "Ab")
  let btn = Widget::button(b, "Ok")
  let row = Widget::row(b, 10.0, [label, btn])
  let placed = row.do_layout(rect(20.0, 30.0, 400.0, 200.0))
  assert_eq(placed.length(), 2)
  // "Ab" -> 2*8+8 = 24 x 20；"Ok" -> 2*8+24 = 40 x 28
  assert_eq(label.bounds(), rect(20.0, 30.0, 24.0, 20.0))
  assert_eq(btn.bounds(), rect(54.0, 30.0, 40.0, 28.0))
  assert_eq(label.frame(), rect(20.0, 30.0, 24.0, 20.0))
}

///|
/// Column + Padding + Center 组合：内缩先减边距，居中用余量的一半。
test "Column 套 Padding 再 Center，边界逐级传递" {
  let b = mock_widgets()
  let a = Widget::label(b, "A")
  let c = Widget::label(b, "B")
  let col = Widget::column(b, 6.0, [a, c])
  let pad = Widget::padding(b, EdgeInsets::all(10.0), col)
  let center = Widget::center(b, pad)
  // 两个 16x20 的标签 + 6 间距 -> 16x46；内边距 10 -> 36x66
  assert_eq(
    pad.measure(BoxConstraints::loose(200.0, 100.0)),
    LogicalSize(36.0, 66.0),
  )
  let placed = center.do_layout(rect(0.0, 0.0, 200.0, 100.0))
  assert_eq(placed.length(), 2)
  // 居中后的 Padding 外框 (82,17)，内缩 10 -> 内容起点 (92,27)
  assert_eq(a.bounds(), rect(92.0, 27.0, 16.0, 20.0))
  assert_eq(c.bounds(), rect(92.0, 53.0, 16.0, 20.0))
}

///|
/// 弹性分配：Spacer 与 expand 叶子均分剩余主轴空间（§14）。
test "Spacer 吃掉 Row 的剩余空间" {
  let b = mock_widgets()
  let btn = Widget::button(b, "Ok")
  let sp = Widget::spacer(b)
  let label = Widget::label(b, "Ab")
  let row = Widget::row(b, 0.0, [btn, sp, label])
  let placed = row.do_layout(rect(0.0, 0.0, 200.0, 100.0))
  // 固定项 40 + 24 = 64，剩余 136 归 Spacer，标签被推到 176
  assert_eq(placed.length(), 2)
  assert_eq(btn.bounds(), rect(0.0, 0.0, 40.0, 28.0))
  assert_eq(label.bounds(), rect(176.0, 0.0, 24.0, 20.0))
  // expand 的叶子参与同一轮分配
  let label2 = Widget::label(b, "Ab")
  let input = Widget::text_input(b, "")
  let grow = Widget::row(b, 0.0, [label2, input])
  input.set_expand(true)
  assert_true(input.expand())
  let _ = grow.do_layout(rect(0.0, 0.0, 200.0, 40.0))
  assert_eq(input.bounds(), rect(24.0, 0.0, 176.0, 40.0))
}

///|
/// 可见性对容器递归：叶子的原生父级是窗口，容器自己没有原生对象可藏。
test "容器可见性递归到整棵子树" {
  let b = mock_widgets()
  let label = Widget::label(b, "A")
  let btn = Widget::button(b, "Ok")
  let row = Widget::row(b, 0.0, [label, btn])
  assert_true(row.visible())
  row.set_visible(false)
  assert_false(label.visible())
  assert_false(btn.visible())
  assert_false(row.visible())
  label.set_visible(true)
  // 子树里还有一个隐藏的叶子，容器就不算可见
  assert_false(row.visible())
  assert_true(label.visible())
  btn.set_visible(true)
  assert_true(row.visible())
}

///|
test "布局节点不占原生对象，也没有事件目标" {
  let b = mock_widgets()
  let label = Widget::label(b, "A")
  let btn = Widget::button(b, "Ok")
  let row = Widget::row(b, 4.0, [label, btn])
  assert_true(row.handle() is None)
  assert_eq(row.leaf_count(), 2)
  // 只有两个叶子向后端要过对象
  assert_eq(b.live(), 2)
  assert_eq(
    widget_error(fn() raise UiError { let _ = row.target() }),
    Some(
      "不支持的操作：布局节点没有原生对象，不能订阅事件",
    ),
  )
  assert_eq(
    widget_error(fn() raise UiError { row.set_bounds(rect(0.0, 0.0, 1.0, 1.0)) }),
    None,
  )
  assert_eq(row.spacing(), 4.0)
}

///|
/// §47 风险 1：关闭子树后原生句柄必须全部归还，handler 引用链同时清空。
test "close_tree 释放整棵子树的原生句柄与闭包" {
  let b = mock_widgets()
  let label = Widget::label(b, "A")
  let btn = Widget::button(b, "Ok")
  let row = Widget::row(b, 0.0, [label, btn])
  let _ = btn.on_click(fn() { () })
  assert_eq(b.live(), 2)
  assert_eq(btn.handler_count(), 1)
  row.close_tree()
  assert_eq(b.live(), 0)
  assert_eq(btn.handler_count(), 0)
  assert_eq(row.children().length(), 0)
  assert_true(row.is_closed())
  assert_true(btn.handle() is None)
  assert_eq(
    widget_error(fn() raise UiError { row.close_tree() }),
    Some("对象已销毁"),
  )
  Backend::terminate(b)
}

///|
/// §9/§10：`on_click` 之类是 `Event` 的过滤器糖，命中才调用。
test "on_click 只放行 Click，handler 的异常沿 fire 传出" {
  let b = mock_widgets()
  let btn = Widget::button(b, "Ok")
  let log : Array[String] = []
  let _ = btn.on_click(fn() { log.push("click") })
  let _ = btn.on_input(fn(s) { log.push("input:\{s}") })
  let _ = btn.on_change(fn() { log.push("change") })
  let t = btn.target()
  assert_eq(btn.fire(Event::Click(t, MouseButton::Left)), 1)
  assert_eq(btn.fire(Event::Change(t)), 1)
  assert_eq(btn.fire(Event::Input(t, "abc")), 1)
  assert_eq(btn.fire(Event::Focus(t)), 0)
  assert_eq(log, ["click", "change", "input:abc"])

  // handler 失败不被控件吞掉（§33）
  let boom = Widget::button(b, "Boom")
  let _ = boom.on_any(fn(_) raise UiError {
    raise OperationFailed("handler 内部失败")
  })
  assert_eq(
    widget_error(fn() raise UiError {
      let _ = boom.fire(Event::Click(boom.target(), MouseButton::Left))
    }),
    Some("操作失败：handler 内部失败"),
  )
  // 关闭后的控件不能再派发
  boom.close_tree()
  assert_eq(
    widget_error(fn() raise UiError {
      let _ = boom.fire(
        Event::Click(
          EventTarget::{ id: 999, generation: 0, },
          MouseButton::Left,
        ),
      )
    }),
    Some("对象已销毁"),
  )
}

///|
/// §49 Todo Demo 逼出来的一条：删除按钮的 handler 会关掉按钮自己所在的树。
/// `fire` 先快照本轮 handler，再在每次调用前复查 `closed`——只快照长度、
/// 仍按下标读活数组的写法，在 `close_tree` 清空数组后越界。
test "handler 销毁自家控件后，本轮剩余 handler 不再被调用" {
  let b = mock_widgets()
  let btn = Widget::button(b, "x")
  let row = Widget::row(b, 0.0, [btn])
  let log : Array[String] = []
  let _ = btn.on_click(fn() { log.push("first") })
  let _ = btn.on_click(fn() raise UiError {
    row.close_tree()
    log.push("destroy")
  })
  let _ = btn.on_click(fn() { log.push("never") })
  assert_eq(btn.fire(Event::Click(btn.target(), MouseButton::Left)), 2)
  assert_eq(log, ["first", "destroy"])
  assert_true(btn.is_closed())
  assert_eq(b.live(), 0)
  Backend::terminate(b)
}

///|
test "find_by_id 沿 Core 树找回叶子控件" {
  let b = mock_widgets()
  let label = Widget::label(b, "Aim")
  let btn = Widget::button(b, "Ok")
  let row = Widget::row(b, 0.0, [label, btn])
  let t = label.target()
  let found = row.find_by_id(t.id)
  assert_true(found is Some(_))
  match found {
    Some(w) => assert_eq(w.text(), "Aim")
    None => ()
  }
  assert_true(row.find_by_id(-7) is None)
}

///|
/// §15/§16 的层叠语义：稀疏覆盖表逐层合并，自身最优先，没写的字段才往下继承。
/// 配色不缓存，`set_theme` 之后下一次解析就生效。
test "样式按 Theme -> 父容器 -> 自身 层叠" {
  let b = mock_widgets()
  let app = App::new(b)
  app.set_theme(Dark)
  assert_eq(app.theme(), Dark)
  assert_eq(app.appearance(), Dark)
  let dark = Theme::dark_palette()
  let base = app.style_base()
  assert_eq(base.background, Some(dark.surface))
  assert_eq(base.foreground, Some(dark.text))

  let row = Widget::row(b, 0.0, [])
  let label = Widget::label(b, "A")
  row.add_child(label)
  row.set_style(Some(style(font_size=Some(18.0))))
  label.set_style(Some(style(foreground=Some(Color::rgb(200, 30, 30)))))
  let s = label.resolved_style(base)
  // 字号来自父容器，前景色来自自身，底色仍来自 Theme
  assert_eq(s.font_size, Some(18.0))
  assert_eq(s.foreground, Some(Color::rgb(200, 30, 30)))
  assert_eq(s.background, Some(dark.surface))
  assert_eq(s.radius, None)
  // 父容器不吃子控件的覆盖
  assert_eq(row.resolved_style(base).foreground, Some(dark.text))

  // System 落到 Backend 报告的外观上
  app.set_theme(System)
  b.set_appearance(Light)
  assert_eq(app.appearance(), Light)
  let light = Theme::light_palette()
  assert_eq(
    label.resolved_style(app.style_base()).background,
    Some(light.surface),
  )
  b.set_appearance(Dark)
  assert_eq(app.appearance(), Dark)
  assert_eq(
    label.resolved_style(app.style_base()).background,
    Some(dark.surface),
  )
  // 自身覆盖始终压过主题与父级
  assert_eq(
    label.resolved_style(app.style_base()).foreground,
    Some(Color::rgb(200, 30, 30)),
  )
}

///|
/// 层叠的结果必须真的走到后端（§15/§16 的下发那一步），否则上一条测试证明的
/// 只是"Core 里算得对"。这里断言的是后端当下持有的那份样式。
test "解析好的样式下发到叶子，换主题会重推" {
  let b = mock_widgets()
  let app = App::new(b)
  let win = app.create_window("样式", LogicalSize(400.0, 300.0))
  let label = Widget::label(b, "Ab")
  win.set_content(Widget::column(b, 0.0, [label]))
  let h = check_nonnull(label.handle(), "叶子控件必须有原生对象")
  // 控件自己没设过样式，下发的是 Theme 解析出来的那份——但 **底色不发**：
  // Label 只画字，继承来的底由铺底的人画（`T139`，见 `apply_styles` 段注），
  // 下发它会让 Windows 半把客户区整块填成主题面色。
  assert_true(label.style() is None)
  let light = Theme::light_palette()
  let pushed = check_nonnull(
    b.widget(h).style,
    "叶子必须收到下发的样式",
  )
  assert_eq(pushed.foreground, Some(light.text))
  assert_eq(pushed.background, None)
  assert_eq(pushed.font_size, app.style_base().font_size)
  app.set_theme(Dark)
  let dark = Theme::dark_palette()
  let repushed = check_nonnull(b.widget(h).style, "换主题必须重推")
  assert_eq(repushed.foreground, Some(dark.text))
  assert_true(repushed != pushed)
  // 主题里没有字号，所以换主题不改度量：这条尺寸断言和没接样式时同值
  assert_eq(b.widget(h).intrinsic, LogicalSize(24.0, 20.0))
}

///|
test "Stack 的叶子叠在同一原点，容器本身不占原生对象" {
  let b = mock_widgets()
  let back = Widget::label(b, "Ab")
  let badge = Widget::button(b, "Ok")
  assert_true(WidgetKind::Stack.is_layout_only())
  let stack = Widget::stack(b, [back, badge])
  assert_eq(stack.kind(), WidgetKind::Stack)
  assert_true(stack.handle() is None)
  assert_eq(stack.leaf_count(), 2)
  // 只有两个叶子向后端要过对象
  assert_eq(b.live(), 2)
  let placed = stack.do_layout(rect(5.0, 7.0, 200.0, 200.0))
  assert_eq(placed.length(), 2)
  assert_eq(back.bounds(), rect(5.0, 7.0, 24.0, 20.0))
  assert_eq(badge.bounds(), rect(5.0, 7.0, 40.0, 28.0))
}

///|
test "Grid 均匀单元格，非法列数与负间距在构造时夹紧" {
  let b = mock_widgets()
  let a = Widget::label(b, "Ab")
  let c = Widget::label(b, "Abcd")
  let d = Widget::label(b, "A")
  let grid = Widget::grid(b, 2, 4.0, [a, c, d])
  assert_true(WidgetKind::Grid.is_layout_only())
  assert_eq(grid.columns(), 2)
  assert_eq(grid.spacing(), 4.0)
  // 单元格取最大固有尺寸 40x20；2 列 2 行 => 40*2+4=84，20*2+4=44
  assert_eq(
    grid.measure(BoxConstraints::loose(300.0, 300.0)),
    LogicalSize(84.0, 44.0),
  )
  let placed = grid.do_layout(rect(0.0, 0.0, 300.0, 300.0))
  assert_eq(placed.length(), 3)
  assert_eq(a.bounds(), rect(0.0, 0.0, 24.0, 20.0))
  assert_eq(c.bounds(), rect(44.0, 0.0, 40.0, 20.0))
  assert_eq(d.bounds(), rect(0.0, 24.0, 16.0, 20.0))

  let e = Widget::label(b, "Ab")
  let f = Widget::label(b, "Ab")
  let one_col = Widget::grid(b, 0, -4.0, [e, f])
  assert_eq(one_col.columns(), 1)
  assert_eq(one_col.spacing(), 0.0)
  let _ = one_col.do_layout(rect(0.0, 0.0, 100.0, 100.0))
  assert_eq(f.bounds(), rect(0.0, 20.0, 24.0, 20.0))
}

///|
test "Scroll 把内容按完整高度排布，超出视口的部分即滚动行程" {
  let b = mock_widgets()
  let x = Widget::button(b, "A")
  let y = Widget::button(b, "A")
  let z = Widget::button(b, "A")
  let col = Widget::column(b, 0.0, [x, y, z])
  let sc = Widget::scroll(b, Axis::Vertical, col)
  assert_false(WidgetKind::Scroll.is_layout_only())
  assert_eq(sc.axis(), Axis::Vertical)
  // T74：视口占用一个原生对象
  assert_true(sc.handle() is Some(_))
  // 视口主轴铺满给到的 30，交叉轴随内容收缩到 32
  assert_eq(
    sc.measure(BoxConstraints::loose(200.0, 30.0)),
    LogicalSize(32.0, 30.0),
  )
  let placed = sc.do_layout(rect(0.0, 0.0, 200.0, 30.0))
  // 视口先入表，三个按钮跟在后面
  assert_eq(placed.length(), 4)
  assert_eq(sc.bounds(), rect(0.0, 0.0, 200.0, 30.0))
  assert_eq(y.bounds(), rect(0.0, 28.0, 32.0, 28.0))
  // 第三个按钮整体落在视口之外，后端沿 y 平移内容就能滚到它
  assert_eq(z.bounds(), rect(0.0, 56.0, 32.0, 28.0))
  // 滚动行程（内容完整高度 84）推给了后端，方向跟 axis
  let h = match sc.handle() {
    Some(h) => h
    None => abort("unreachable")
  }
  assert_eq(
    b.scroll_content_of(h),
    Some((Axis::Vertical, LogicalSize(32.0, 84.0))),
  )
}

///|
/// 行容器里的 Scroll：交叉轴铺满行的可用尺寸，而不是被无界约束量成"无限"
/// （真机上后端会收到 INT_MAX 大的视口矩形，永远装得下、永远不出滚动条）。
/// 主轴真无界的退路是内容全长；expand 的 Scroll 另外吃剩余主轴——T74 起
/// Scroll 不是 layout-only，得靠 child_specs 的 Expand 包装才能参与弹性。
test "行容器里的 Scroll：交叉轴铺满、无界主轴退内容、expand 吃剩余" {
  let b = mock_widgets()
  // 两个按钮各 32x28，一列 56 高——三个场景共用的内容形状。
  fn two_buttons() -> Widget[MockBackend] raise UiError {
    Widget::column(b, 0.0, [Widget::button(b, "a"), Widget::button(b, "b")])
  }
  // 横向 Row 里的 Scroll：交叉轴（高度）铺满行高 100，而不是被量成"无限"。
  let sc1 = Widget::scroll(b, Axis::Vertical, two_buttons())
  let row = Widget::row(b, 0.0, [sc1])
  let _ = row.do_layout(rect(0.0, 0.0, 60.0, 100.0))
  assert_eq(sc1.bounds(), rect(0.0, 0.0, 32.0, 100.0))
  let h1 = match sc1.handle() {
    Some(h) => h
    None => abort("unreachable")
  }
  assert_eq(
    b.scroll_content_of(h1),
    Some((Axis::Vertical, LogicalSize(32.0, 56.0))),
  )
  // 竖向 Column 里的非 expand Scroll：主轴（高度）无界，视口退内容全长 56，
  // 不再是垃圾的无限矩形。
  let sc2 = Widget::scroll(b, Axis::Vertical, two_buttons())
  let col = Widget::column(b, 0.0, [sc2])
  let _ = col.do_layout(rect(0.0, 0.0, 60.0, 100.0))
  assert_eq(sc2.bounds(), rect(0.0, 0.0, 32.0, 56.0))
  // expand 的 Scroll 吃剩余主轴：Column 里再垫一个 20 高的标题，剩 80 归它；
  // 弹性项的交叉轴（宽度）按规则铺满 60。
  let sc3 = Widget::scroll(b, Axis::Vertical, two_buttons())
  sc3.set_expand(true)
  let title = Widget::label(b, "标题")
  let col2 = Widget::column(b, 0.0, [title, sc3])
  let _ = col2.do_layout(rect(0.0, 0.0, 60.0, 100.0))
  assert_eq(sc3.bounds(), rect(0.0, 20.0, 60.0, 80.0))
}

///|
test "Scroll 必须恰好一个子控件，Grid/Scroll 属性有种类守卫" {
  let b = mock_widgets()
  let one = Widget::label(b, "Ab")
  let two = Widget::label(b, "Cd")
  let sc = Widget::scroll(b, Axis::Vertical, one)
  sc.add_child(two)
  assert_eq(
    widget_error(fn() raise UiError {
      let _ = sc.measure(BoxConstraints::loose(100.0, 100.0))
    }),
    Some("操作失败：Scroll 必须恰好有一个子控件"),
  )
  let plain = Widget::label(b, "Ab")
  assert_eq(
    widget_error(fn() raise UiError { let _ = plain.columns() }),
    Some("不支持的操作：只有 Grid 有列数"),
  )
  assert_eq(
    widget_error(fn() raise UiError { let _ = plain.axis() }),
    Some("不支持的操作：只有 Scroll 有滚动方向"),
  )
  let grid = Widget::grid(b, 3, 0.0, [])
  assert_eq(
    widget_error(fn() raise UiError { let _ = grid.axis() }),
    Some("不支持的操作：只有 Scroll 有滚动方向"),
  )
  assert_eq(
    widget_error(fn() raise UiError { let _ = grid.target() }),
    Some(
      "不支持的操作：布局节点没有原生对象，不能订阅事件",
    ),
  )
}

///|
/// 容器上声明 `set_expand(true)` 会包成 `LayoutSpec::Expand` 参与弹性分配：
/// 面板吃掉 Column 的剩余高度，它后面的兄弟项留在可视区内。
test "容器上的 set_expand 参与剩余空间分配（§14）" {
  let b = mock_widgets()
  let top = Widget::label(b, "T")
  let inner = Widget::button(b, "I")
  let panel = Widget::row(b, 0.0, [inner])
  panel.set_expand(true)
  let bottom = Widget::label(b, "B")
  let col = Widget::column(b, 4.0, [top, panel, bottom])
  assert_eq(panel.expand(), true)
  let placed = col.do_layout(rect(0.0, 0.0, 200.0, 100.0))
  assert_eq(placed.length(), 3)
  // 两个标签各 20 高，间距 2*4 -> 弹性面板得 52，底部标签贴到 80
  assert_eq(top.frame(), rect(0.0, 0.0, 16.0, 20.0))
  assert_eq(inner.frame(), rect(0.0, 24.0, 32.0, 28.0))
  assert_eq(bottom.frame(), rect(0.0, 80.0, 16.0, 20.0))
  Backend::terminate(b)
}
