///|
/// Backend 接口（设计文档 §19、§47 风险 6）。
///
/// Core 只通过 `Backend` 与具体 GUI 库对话，因此 libui-ng / SDL3 / Win32 的差异
/// 全部留在实现侧。当前 MoonBit 版本里 trait 不是类型（也没有 `dyn`），所以
/// Backend 走泛型静态分发：`App[B : Backend]`。这意味着 **后端是编译期选定**
/// 的，与 §34/§35 "每个平台预编译对应后端" 的方向一致。

///|
pub(open) trait Backend {
  /// 初始化底层工具链。失败必须带原因（§33）。
  fn init(Self) -> Unit raise UiError
  /// 释放底层资源；调用后不允许再创建对象。
  fn terminate(Self) -> Unit
  /// 非阻塞取出一个待处理事件，队列空时返回 `None`（§10、§27）。
  ///
  /// 契约：事件里所有坐标/增量都必须是**逻辑像素**。原生层给的是物理坐标
  /// （Win32 的 lParam、Cocoa 的 NSEvent.locationInWindow 换算结果、SDL3 的
  /// mouse button 都是物理的），适配器入队前要先除以该窗口的 Scale（§30）。
  /// 这条换算放在实现侧而不是 Core 侧，是因为 Core 已经在唯一一处读 Scale，
  /// 两边都换算就会出现"除以两次"的经典 HiDPI 位移 bug。
  fn poll_event(Self) -> Event?
  /// 请求给这只窗口画一帧（`T31`）。原生控件后端是空操作——重绘是系统的事，
  /// 窗口脏了系统自己会画，这条对它没有意义；自绘后端（§51 的 Backend #2）靠它
  /// 在空闲时续命：调用后下一圈 `poll_event` 要吐一条 `Frame`（target 是这只
  /// 窗口），Core 据此驱动它画一帧。契约只钉"调用后下一圈能取到一条 Frame"，
  /// 不钉"恰好一条"——后端可以合并多次请求（脏了就是脏了，画一帧就够）。
  fn request_redraw(Self, NativeHandle) -> Unit raise UiError
  fn create_window(Self, title : String, size : LogicalSize) -> NativeHandle raise UiError
  fn destroy_window(Self, NativeHandle) -> Unit raise UiError
  fn set_window_title(Self, NativeHandle, String) -> Unit raise UiError
  fn set_window_size(Self, NativeHandle, LogicalSize) -> Unit raise UiError
  fn show_window(Self, NativeHandle) -> Unit raise UiError
  fn hide_window(Self, NativeHandle) -> Unit raise UiError
  /// 窗口所在屏幕的缩放因子，用于逻辑/物理像素换算（§30）。
  fn window_scale(Self, NativeHandle) -> Scale raise UiError
  /// 主屏可用区域，逻辑像素。`Window::center` 与多屏定位依赖它（§12、§30）。
  /// 这条是**进程级**的读数：窗口还没建出来时只有它能用。窗口已经存在时用下面那条。
  fn screen_size(Self) -> LogicalSize raise UiError
  /// 这只窗口**当下所在那块屏**的工作区（去掉任务栏 / Dock），逻辑像素。
  /// `Window::center` 用它，用 `screen_size` 会把副屏上的窗口摆回主屏（§12、`T42`）。
  ///
  /// 契约：这个矩形的坐标空间和 `window_position` / `set_window_position` **同一个**，
  /// 因为读数只有用摆位那套坐标才摆得回去。两个平台那套空间本身不同（mac 的原点是
  /// "该屏可见区的左上角"，所以 origin.y 恒为 0；Win32 是虚拟屏幕绝对坐标，副屏在右
  /// 边时 origin.x 是个非零绝对值），所以 Core 拿它只做一件事——在这块屏的可用矩形里
  /// 算一个摆位点，然后交给同一个后端的 set_position。不要在两个后端之间比这个数。
  fn window_work_area(Self, NativeHandle) -> LogicalRect raise UiError
  /// 系统当前的外观（Light/Dark）。`Theme::System` 靠它落地（§16）。
  fn system_theme(Self) -> Theme raise UiError
  /// 读回窗口当前的尺寸/位置：原生层是唯一事实来源，Core 不缓存。
  fn window_size(Self, NativeHandle) -> LogicalSize raise UiError
  fn set_window_position(Self, NativeHandle, LogicalPoint) -> Unit raise UiError
  fn window_position(Self, NativeHandle) -> LogicalPoint raise UiError
  fn set_window_resizable(Self, NativeHandle, Bool) -> Unit raise UiError
  fn set_window_fullscreen(Self, NativeHandle, Bool) -> Unit raise UiError
  /// 标题栏样式（§12）。`Immersive` 在 mac 上是 `fullSizeContentView` + 透明标题栏 +
  /// 隐藏标题文字（内容铺满、红绿灯浮在内容上）；Windows 没有红绿灯，是空操作。
  fn set_window_titlebar_style(Self, NativeHandle, TitlebarStyle) -> Unit raise UiError
  /// 红绿灯位置（§12）。`p` 是**关闭按钮左上角**相对**窗口左上角**的逻辑像素坐标，
  /// mac 把三个红绿灯整簇挪过去（resize 时重新断言，AppKit 会在 resize 时把它们
  /// 摆回默认位）；Windows 没有红绿灯，是空操作。
  fn set_window_traffic_light_position(Self, NativeHandle, LogicalPoint) -> Unit raise UiError
  /// 控件创建与属性读写（§13）。窗口和控件共用同一张句柄表，所以
  /// `EventTarget.id` 全局唯一，派发时不会把窗口和控件混为一谈。
  fn create_widget(Self, kind : WidgetKind, text : String) -> NativeHandle raise UiError
  /// Slider / Spinbox 的创建通道：范围是这两个控件的构造参数（libui 的
  /// `uiNewSlider(min,max)` / `uiNewSpinbox(min,max)` 没有"先建再设"的入口，
  /// Spinbox 连事后改范围都没有），所以单独一条而不是给 `create_widget`
  /// 塞一对大多数种类用不上的参数。其余种类必须走 `create_widget`。
  fn create_ranged_widget(Self, kind : WidgetKind, min : Int32, max : Int32) -> NativeHandle raise UiError
  fn destroy_widget(Self, NativeHandle) -> Unit raise UiError
  fn set_widget_text(Self, NativeHandle, String) -> Unit raise UiError
  fn widget_text(Self, NativeHandle) -> String raise UiError
  fn set_widget_checked(Self, NativeHandle, Bool) -> Unit raise UiError
  fn widget_checked(Self, NativeHandle) -> Bool raise UiError
  /// 数值属性（§13）：Slider / Spinbox / Progress 的当前值。
  /// Progress 的约定：0–100，传 -1 表示"不定进度"（libui 的约定）。
  fn set_widget_value(Self, NativeHandle, Int32) -> Unit raise UiError
  fn widget_value(Self, NativeHandle) -> Int32 raise UiError
  /// 改范围。只有 Slider 有这条（libui 的事实，见 create_ranged_widget）。
  fn set_widget_range(Self, NativeHandle, min : Int32, max : Int32) -> Unit raise UiError
  /// 条目属性：ComboBox / RadioButtons 的选项与选中下标（§13）。
  fn append_widget_option(Self, NativeHandle, String) -> Unit raise UiError
  fn set_widget_selected(Self, NativeHandle, Int32) -> Unit raise UiError
  fn widget_selected(Self, NativeHandle) -> Int32 raise UiError
  /// 日期时间属性（DatePicker）：值以 `"YYYY-MM-DD HH:MM:SS"` 文本进出。
  /// 不并进 `set_widget_text`：原生层的值是 `struct tm`，不是窗口文本，
  /// 这两个通道在 C 侧是两套调用，MoonBit 侧分开就不会串。
  fn set_widget_datetime(Self, NativeHandle, String) -> Unit raise UiError
  fn widget_datetime(Self, NativeHandle) -> String raise UiError
  fn set_widget_visible(Self, NativeHandle, Bool) -> Unit raise UiError
  fn widget_visible(Self, NativeHandle) -> Bool raise UiError
  fn set_widget_enabled(Self, NativeHandle, Bool) -> Unit raise UiError
  fn widget_enabled(Self, NativeHandle) -> Bool raise UiError
  /// 样式下发（§15/§16）：Core 把 `Widget::resolved_style` 沿祖先链算完的生效值
  /// 交给后端。自绘后端据此绘制配色、字体、圆角与透明度。
  ///
  /// 契约：**先推样式，再测量**。`widget_intrinsic_size` 反映后端当下持有的样式，
  /// Core 不再把 `Style` 当参数传进测量——否则"控件现在长什么样"这条事实在两个
  /// 地方各说一遍，改一处漏一处。原生控件库里也是同一个顺序：Win32 的
  /// `WM_SETFONT` 先发给控件，控件自己重算尺寸，之后量到的才是新值。
  /// `Window::relayout` 走的就是这个顺序（§14）。
  ///
  /// 没有对应的 getter：层叠由 Core 计算，解析结果本来就在 Core 手里，
  /// 向后端回读只是把同一份数据搬两次。
  ///
  /// 原生控件后端有权完全不读这份样式——§32 要保住系统原生外观，libui-ng 也没有
  /// per-control 的字体接口。这条豁免写在 `backends/libui-common/backend.mbt` 的实现里，不是隐藏行为。
  fn set_widget_style(Self, NativeHandle, Style) -> Unit raise UiError
  /// 把 §32 的无障碍语义推给后端（`T41`）：Role / Label / Description / State
  /// 四样，载荷是 Core 现算的 `Accessibility`。与 `set_widget_style` 同一条
  /// 顺序契约——都在 `Widget::apply_styles` 里下发，`Window::relayout` 先样式
  /// 后语义再 `do_layout`。Actions 也在这份结构里，但它的翻译（原生层把
  /// "执行"接给读屏器）留到 Actions 那半，后端先不读它。
  ///
  /// 显式声明了角色的纯布局节点没有 `NativeHandle`，走不到这里——它们进得了
  /// `accessibility_tree`（Core 自己展开的视图），却挂不到任何原生对象上；
  /// 给它们造原生 a11y 元素是 §17 自定义控件那一格的事。
  fn set_widget_accessibility(Self, NativeHandle, Accessibility) -> Unit raise UiError
  fn set_widget_bounds(Self, NativeHandle, LogicalRect) -> Unit raise UiError
  fn widget_bounds(Self, NativeHandle) -> LogicalRect raise UiError
  /// 固有尺寸由后端测量：字体度量属于原生层，Core 不猜（§18）。
  fn widget_intrinsic_size(Self, NativeHandle) -> LogicalSize raise UiError
  /// 原生父子挂接：控件必须属于窗口才会显示（§8）。
  /// Row/Column 这类容器在 Core 里算绝对边界、不占原生对象（§14），
  /// 所以后端的挂接目标只有窗口。
  fn attach_widget(Self, window : NativeHandle, child : NativeHandle) -> Unit raise UiError
  /// 挂进**容器控件**（`T74`：Scroll 占用原生对象，子树挂进它的文档区）。
  /// `container` 是滚动视口的句柄；与 `attach_widget` 分开，因为两边的
  /// 原生语义不同（窗口 vs 容器的文档视图），后端各译各的。
  fn attach_widget_to(Self, container : NativeHandle, child : NativeHandle) -> Unit raise UiError
  /// 滚动行程（`T74`）：`size` 是内容按完整尺寸量出来的大小（可以超出视口），
  /// 后端据此给文档视图定尺寸并按主轴配滚动条；视口自己的矩形走
  /// `set_widget_bounds`，和叶子同一条通道。
  fn set_scroll_content(
    Self,
    scroll : NativeHandle,
    axis : Axis,
    size : LogicalSize,
  ) -> Unit raise UiError
  fn detach_widget(Self, child : NativeHandle) -> Unit raise UiError
  /// 层叠（§14 的 Stack）：把控件提到所在窗口子窗口列表的最上层。
  ///
  /// 为什么不并进 `attach_widget`：挂载只能给出"顺序"这一件事，而原生层的视觉层叠
  /// 与键盘 Tab 走的是同一份 z-order，两者方向相反（先挂的在 Tab 链前面，后挂的
  /// 画在上层）。Stack 的契约是"数组靠后的画在上层"，所以由 Core 在挂载之后按
  /// 数组顺序逐个 raise，把视觉顺序钉死——代价写在 window.mbt 的 `apply_layers`。
  fn raise_widget(Self, child : NativeHandle) -> Unit raise UiError
  /// 整窗的绘画顺序（`T29`）：`order` 是这只窗口所有叶子控件**从顶层到底层**的
  /// 完整列表，Core 在挂载之后算好、整份推下来。
  ///
  /// 为什么有这条而不是只靠 `raise_widget`：`raise_widget` 假定"层叠 = 原生 z-order"，
  /// 自绘后端（§51 的 Backend #2）根本没有 z-order 这回事，它要的正是这份"谁画在谁
  /// 上面"的列表。原生控件后端把它翻译成自己的 z-order（libui 那份按倒序逐个
  /// `raise_widget` 就到位），自绘后端存下来当绘制顺序用。Core 因此只说"顺序是什么"，
  /// 不说"怎么摆"——层叠从"原生层的事"变成"Core 算、后端落"。
  fn set_paint_order(Self, window : NativeHandle, order : Array[NativeHandle]) -> Unit raise UiError
  /// 整窗的焦点链（`T29`）：`chain` 是这只窗口所有叶子控件**按声明顺序**（先序）的
  /// 完整列表，Core 在挂载之后算好、整份推下来，后端把原生焦点机制（macOS 的
  /// `nextKeyView` 链）接成这条顺序，于是键盘 Tab 走的是声明顺序。
  ///
  /// 为什么和 `set_paint_order` 分开：原生层里绘画和 Tab 常常共用同一份顺序（Win32 的
  /// z-order 一份管两件事），但 Stack 的契约要的是"数组靠后的画在上层"——绘画顺序因此
  /// 是声明顺序的**倒序**，而 Tab 不该跟着倒。把两条链都交给 Core 算、后端各自落，
  /// 层叠和焦点才解耦：Stack 里 Tab 走声明顺序、绘画走倒序，两者不再互相绑架。
  /// 不含 Stack 的树两条链同值，行为与旧实现一致。
  fn set_focus_chain(Self, window : NativeHandle, chain : Array[NativeHandle]) -> Unit raise UiError
  fn clipboard_text(Self) -> String? raise UiError
  fn set_clipboard_text(Self, String) -> Unit raise UiError
  /// 对话框（§24）。同步语义：真实后端在这里阻塞自己的事件循环子轮次。
  fn show_message(Self, title : String, text : String) -> Unit raise UiError
  /// 确认框，返回用户是否选择"是"。
  fn confirm(Self, title : String, text : String) -> Bool raise UiError
  /// 文件/文件夹选择，用户取消返回 `None`。
  fn open_file(Self, title : String) -> String? raise UiError
  fn save_file(Self, title : String, default_name : String) -> String? raise UiError
  fn select_folder(Self, title : String) -> String? raise UiError
  /// 菜单栏（§25）。真实后端在这里把 Core 的菜单树换成原生菜单（Win32 的 HMENU、
  /// Cocoa 的 NSMenu）；用户点击通过 `Event::MenuSelect` 回流，Core 不轮询菜单状态。
  ///
  /// 整棵替换，没有增量修改的入口：`MenuBar` 在 Core 侧是不可变结构（改一项就得
  /// 重新装一遍），而原生层两边都只给了"重建"这条路（见 TODO 的 `T22`）。
  fn set_menu_bar(Self, MenuBar) -> Unit raise UiError
  /// 把 Core 改掉的勾选态推给刚安装的那棵原生菜单（§25 / §48-20）。
  ///
  /// 为什么是"推"而不是让后端回读：按 §25 勾选状态只存在 Core（原生菜单项没有可靠
  /// 的读回口），后端如果自己也存一份树，两份状态迟早分叉。所以 Core 在
  /// `App::click_menu_item` 里改完就当场推一次，后端只负责把那个勾画出来。
  ///
  /// `id` 是 `MenuBar::all_items()` 给的菜单项 id，和窗口/控件的句柄 id 是两个编号
  /// 空间（§25）。id 不在已安装的菜单栏里必须 `raise`：写错的菜单 id 是用户看不见、
  /// Core 也回读不出的那类错（§33），不许静默忽略。
  fn set_menu_item_checked(Self, id : Int32, checked : Bool) -> Unit raise UiError
  /// 应用图标（§26）。参数是**不带扩展名的文件名**（stem）：mac 侧补 `.png`、
  /// Windows 侧补 `.ico`，调用方只写一份路径。相对进程 CWD 解析，建议在
  /// `create_window` 之前调用——之后新建的窗口才会带着这份图标。
  fn set_app_icon(Self, name : String) -> Unit raise UiError
}

///|
/// `Backend` 的无头实现：不依赖任何 GUI 库，用于 §37 第一/第二层测试，
/// 也让 CI 在没有 libui-ng 的机器上照样能跑完整生命周期。
pub struct MockWindow {
  mut title : String
  mut size : LogicalSize
  mut origin : LogicalPoint
  mut visible : Bool
  mut resizable : Bool
  mut fullscreen : Bool
  /// 标题栏样式（§12）。mock 只记录状态，测试靠它断言"调用真的到了后端"。
  mut titlebar_style : TitlebarStyle
  /// 红绿灯位置（§12），关闭按钮左上角相对窗口左上角的逻辑像素。mock 只记录状态。
  mut traffic_light_position : LogicalPoint
  mut scale : Scale
  /// 这只窗口所在那块屏的工作区，`None` = 测试没设过，退回"整块虚拟屏就是可用区"
  /// （单屏机器的形状，所以既有断言的数不变）。驱动 `Window::center` 的多屏那一半（`T42`）。
  mut work_area : LogicalRect?
  /// 子控件的层叠顺序，**从顶层到底层**——和 Win32 `EnumChildWindows` 的返回顺序
  /// 同向，所以 mock 里写下的层叠断言能原样搬到真后端上（§14、§48-15）。
  mut z_order : Array[NativeHandle]
  /// 焦点链，**按声明顺序**（先序）——Core 算好整份推下来（`T29`）。mock 没有原生
  /// 焦点机制，这份列表就是它的全部焦点状态，测试靠 `focus_chain` 读它断言"声明顺序
  /// 真的到了后端"。和 `z_order` 分开存：Stack 里两者不同（层叠倒序、焦点声明序）。
  mut focus_chain : Array[NativeHandle]
} derive(Debug, Eq)

///|
pub struct MockBackend {
  handles : HandleTable
  windows : Array[MockWindow]
  widgets : Array[MockWidget]
  queue : Array[Event]
  mut screen : LogicalSize
  mut appearance : Theme
  mut cursor : Int32
  mut clipboard : String?
  // §24 的脚本化对话框：请求日志 + 两条按序消费的应答队列
  dialog_log : Array[String]
  confirm_replies : Array[Bool]
  mut confirm_cursor : Int32
  path_replies : Array[String?]
  mut path_cursor : Int32
  // §25 的菜单栏快照、安装次数，与 Core 推给后端的勾选态流水（§48-20）
  mut menu_bar : MenuBar?
  mut menu_installs : Int32
  menu_checks : Array[(Int32, Bool)]
  // 最后一次 set_app_icon 的 stem 快照（§26），None = 没设过图标
  mut app_icon : String?
  mut initialized : Bool
}

///|
pub fn MockBackend::new() -> MockBackend {
  MockBackend::{
    handles: HandleTable::new(),
    windows: [],
    widgets: [],
    queue: [],
    screen: LogicalSize::{ width: 1920.0, height: 1080.0, },
    // 默认固定为 Light，测试才能对配色做稳定断言（§16）
    appearance: Light,
    cursor: 0,
    clipboard: None,
    dialog_log: [],
    confirm_replies: [],
    confirm_cursor: 0,
    path_replies: [],
    path_cursor: 0,
    menu_bar: None,
    menu_installs: 0,
    menu_checks: [],
    app_icon: None,
    initialized: false,
  }
}

///|
/// 测试侧设置虚拟屏幕尺寸，驱动 `Window::center`。
pub fn MockBackend::set_screen_size(
  self : MockBackend,
  size : LogicalSize,
) -> Unit {
  self.screen = size.non_negative()
}

///|
/// 测试侧设置"这只窗口所在那块屏的工作区"，驱动多屏那半的 `Window::center`（`T42`）。
/// 真实后端没有这条：那块屏是系统的事实，mock 里它是注入的，两者都由"窗口摆位用的
/// 那套坐标"来解释。origin 不夹非负——Win32 上副屏在主屏左边或上边时绝对坐标就是负的。
pub fn MockBackend::set_window_work_area(
  self : MockBackend,
  h : NativeHandle,
  area : LogicalRect,
) -> Unit raise UiError {
  let w = self.window(h)
  w.work_area = Some(LogicalRect::{
    origin: area.origin,
    size: area.size.non_negative(),
  })
}

///|
/// 测试侧注入系统外观，驱动 `Theme::System` 的解析（§16）。
pub fn MockBackend::set_appearance(self : MockBackend, t : Theme) -> Unit {
  self.appearance = t
}

///|
/// 脚本化确认框应答（§24）：按入队顺序依次消费，队列空时答"否"。
pub fn MockBackend::push_confirm_reply(self : MockBackend, v : Bool) -> Unit {
  self.confirm_replies.push(v)
}

///|
/// 脚本化文件/文件夹选择应答；`None` 表示用户取消。
pub fn MockBackend::push_path_reply(self : MockBackend, path : String?) -> Unit {
  self.path_replies.push(path)
}

///|
/// 已经弹出的对话框请求，形如 `confirm:标题|正文`，供集成断言（§37）。
pub fn MockBackend::dialog_requests(self : MockBackend) -> Array[String] {
  self.dialog_log
}

///|
/// 未被消费的脚本应答条数；Demo 用它断言"该问的都问了、没多问"。
pub fn MockBackend::pending_dialog_replies(self : MockBackend) -> Int32 {
  self.confirm_replies.length() -
  self.confirm_cursor +
  (self.path_replies.length() - self.path_cursor)
}

///|
/// 注入一个事件，模拟原生回调（§9 的 trampoline 落点）。
pub fn MockBackend::push_event(self : MockBackend, ev : Event) -> Unit {
  self.queue.push(ev)
}

///|
/// 模拟"用户点了菜单项 N"：等价于原生层送来 MenuSelect（§25）。
pub fn MockBackend::push_menu_select(self : MockBackend, id : Int32) -> Unit {
  self.queue.push(MenuSelect(EventTarget::{ id, generation: 0, }))
}

///|
/// 当前安装在后端侧的菜单栏。未初始化时抛错，和别的读取一样。
pub fn MockBackend::installed_menu_bar(
  self : MockBackend,
) -> MenuBar? raise UiError {
  self.check_initialized()
  self.menu_bar
}

///|
/// `set_menu_bar` 被调用过几次（重复安装是允许的，真实后端会整棵重建）。
pub fn MockBackend::menu_install_count(self : MockBackend) -> Int32 {
  self.menu_installs
}

///|
/// Core 推给后端的勾选态，按推送顺序记 `(菜单项 id, 新状态)`（§48-20）。
/// 集成测试用它断言"用户点了一下，原生那边确实被告知了"，而不必依赖对象身份；
/// Radio 一次点击会来一组（同组全推，见 `App::sync_menu_checks`）。
pub fn MockBackend::menu_check_log(self : MockBackend) -> Array[(Int32, Bool)] {
  self.menu_checks
}

///|
/// 最后一次 `set_app_icon` 传入的 stem（§26），None = 没设过图标。
pub fn MockBackend::app_icon(self : MockBackend) -> String? {
  self.app_icon
}

///|
/// 存活的句柄总数（窗口 + 控件），泄漏检查用。
pub fn MockBackend::live(self : MockBackend) -> Int32 {
  self.handles.live()
}

///|
/// 读取窗口状态，句柄失效或指向控件时抛 `InvalidHandle`。
pub fn MockBackend::window(
  self : MockBackend,
  h : NativeHandle,
) -> MockWindow raise UiError {
  self.check_initialized()
  let index = self.window_slot(h)
  let w = match self.windows_at(index) {
    Some(w) => w
    None => raise InvalidHandle
  }
  w
}

///|
/// 读取控件状态，句柄失效或指向窗口时抛 `InvalidHandle`。
pub fn MockBackend::widget(
  self : MockBackend,
  h : NativeHandle,
) -> MockWidget raise UiError {
  self.check_initialized()
  let index = self.widget_slot(h)
  let w = match self.widgets_at(index) {
    Some(w) => w
    None => raise InvalidHandle
  }
  w
}

///|
/// 窗口的子控件层叠顺序，从顶层到底层（§14、§48-15）。真后端上同一个顺序由
/// `EnumChildWindows` 给出，所以两边的断言能对上。
pub fn MockBackend::child_z_order(
  self : MockBackend,
  window : NativeHandle,
) -> Array[NativeHandle] raise UiError {
  self.window(window).z_order
}

///|
/// 窗口的焦点链，按声明顺序（先序）（`T29`）。和 `child_z_order` 分开读：Stack 里
/// 层叠是倒序、焦点是声明序，两者不同。
pub fn MockBackend::focus_chain(
  self : MockBackend,
  window : NativeHandle,
) -> Array[NativeHandle] raise UiError {
  self.window(window).focus_chain
}

///|
/// 摘掉一个句柄后的 z-order；不在列表里就原样返回。
fn z_order_without(
  order : Array[NativeHandle],
  h : NativeHandle,
) -> Array[NativeHandle] {
  let rest : Array[NativeHandle] = []
  for x in order {
    if x != h {
      rest.push(x)
    }
  }
  rest
}

///|
/// `to_top` = 提到最上层，否则落到最底层，两种都先把已在列表里的摘掉。
/// 语义照抄 Win32 的 `SetWindowPos(HWND_TOP / HWND_BOTTOM)`。
fn z_order_move(
  order : Array[NativeHandle],
  h : NativeHandle,
  to_top : Bool,
) -> Array[NativeHandle] {
  let rest = z_order_without(order, h)
  let out : Array[NativeHandle] = []
  if to_top {
    out.push(h)
  }
  for x in rest {
    out.push(x)
  }
  if !to_top {
    out.push(h)
  }
  out
}

///|
/// 句柄 -> 槽位。mock 把"指针"编码成 `槽位下标 * 2 + 类型位`
/// （0 是窗口，1 是控件），于是窗口和控件能共用一张句柄表，
/// `EventTarget.id` 因此全局唯一；类型位不符就是句柄用错了对象。
fn MockBackend::slot_of(
  self : MockBackend,
  h : NativeHandle,
  want_widget : Bool,
) -> Int32 raise UiError {
  let NativePtr(ptr) = self.handles.resolve(h)
  let is_widget = ptr % 2 == 1
  if is_widget != want_widget {
    raise InvalidHandle
  }
  (ptr / 2).to_int()
}

///|
fn MockBackend::window_slot(
  self : MockBackend,
  h : NativeHandle,
) -> Int32 raise UiError {
  self.slot_of(h, false)
}

///|
fn MockBackend::widget_slot(
  self : MockBackend,
  h : NativeHandle,
) -> Int32 raise UiError {
  self.slot_of(h, true)
}

///|
fn MockBackend::windows_at(self : MockBackend, index : Int32) -> MockWindow? {
  if index >= 0 && index < self.windows.length() {
    Some(self.windows[index])
  } else {
    None
  }
}

///|
fn MockBackend::widgets_at(self : MockBackend, index : Int32) -> MockWidget? {
  if index >= 0 && index < self.widgets.length() {
    Some(self.widgets[index])
  } else {
    None
  }
}

///|
fn MockBackend::check_initialized(self : MockBackend) -> Unit raise UiError {
  if !self.initialized {
    raise InitializationFailed("Backend 尚未初始化")
  }
}

///|
pub impl Backend for MockBackend with fn init(self) {
  self.initialized = true
}

///|
pub impl Backend for MockBackend with fn terminate(self) {
  // 遗留窗口在这里统一注销，保证 §47 风险 2 的"退出时句柄表归零"可断言
  for h in self.handles.alive_handles() {
    self.handles.unregister(h) catch {
      _ => ()
    }
  }
  self.initialized = false
}

///|
pub impl Backend for MockBackend with fn poll_event(self) -> Event? {
  let ev = if self.cursor < self.queue.length() {
    Some(self.queue[self.cursor])
  } else {
    None
  }
  match ev {
    Some(_) => self.cursor = self.cursor + 1
    None => ()
  }
  ev
}

///|
/// 自绘后端的续命信号（`T31`）：请求后下一圈 `poll_event` 能取到一条 `Frame`。
/// 这里直接入队，target 用这只窗口的句柄（id + generation 一起带走，`T49`）。
pub impl Backend for MockBackend with fn request_redraw(self, h) -> Unit raise UiError {
  let _w = self.window(h)
  self.queue.push(Frame(EventTarget::of(h)))
}

///|
pub impl Backend for MockBackend with fn create_window(self, title, size) -> NativeHandle raise UiError {
  self.check_initialized()
  let index = self.windows.length()
  self.windows.push(MockWindow::{
    title,
    size: size.non_negative(),
    origin: LogicalPoint::{ x: 0.0, y: 0.0, },
    visible: false,
    resizable: true,
    fullscreen: false,
    titlebar_style: TitlebarStyle::Standard,
    traffic_light_position: LogicalPoint::{ x: 0.0, y: 0.0, },
    scale: Scale::one(),
    work_area: None,
    z_order: [],
    focus_chain: [],
  })
  let h = self.handles.register(NativePtr((index * 2).to_int64()))
  h
}

///|
pub impl Backend for MockBackend with fn destroy_window(self, h) -> Unit raise UiError {
  self.check_initialized()
  let _ = self.window_slot(h)
  self.handles.unregister(h)
}

///|
pub impl Backend for MockBackend with fn set_window_title(self, h, title) -> Unit raise UiError {
  let w = self.window(h)
  w.title = title
}

///|
pub impl Backend for MockBackend with fn set_window_size(self, h, size) -> Unit raise UiError {
  let w = self.window(h)
  w.size = size.non_negative()
}

///|
pub impl Backend for MockBackend with fn show_window(self, h) -> Unit raise UiError {
  let w = self.window(h)
  w.visible = true
}

///|
pub impl Backend for MockBackend with fn hide_window(self, h) -> Unit raise UiError {
  let w = self.window(h)
  w.visible = false
}

///|
pub impl Backend for MockBackend with fn window_scale(self, h) -> Scale raise UiError {
  let w = self.window(h)
  w.scale
}

///|
pub impl Backend for MockBackend with fn screen_size(self) -> LogicalSize raise UiError {
  self.check_initialized()
  self.screen
}

///|
/// 没设过就是"整块虚拟屏都是可用区"，也就是单屏机器的形状（`T42`）。
pub impl Backend for MockBackend with fn window_work_area(self, h) -> LogicalRect raise UiError {
  self.check_initialized()
  let w = self.window(h)
  match w.work_area {
    Some(a) => a
    None =>
      LogicalRect::{
        origin: LogicalPoint::{ x: 0.0, y: 0.0, },
        size: self.screen,
      }
  }
}

///|
pub impl Backend for MockBackend with fn system_theme(self) -> Theme raise UiError {
  self.check_initialized()
  self.appearance
}

///|
pub impl Backend for MockBackend with fn window_size(self, h) -> LogicalSize raise UiError {
  let w = self.window(h)
  w.size
}

///|
pub impl Backend for MockBackend with fn set_window_position(self, h, origin) -> Unit raise UiError {
  let w = self.window(h)
  w.origin = origin
}

///|
pub impl Backend for MockBackend with fn window_position(self, h) -> LogicalPoint raise UiError {
  let w = self.window(h)
  w.origin
}

///|
pub impl Backend for MockBackend with fn set_window_resizable(self, h, v) -> Unit raise UiError {
  let w = self.window(h)
  w.resizable = v
}

///|
pub impl Backend for MockBackend with fn set_window_fullscreen(self, h, v) -> Unit raise UiError {
  let w = self.window(h)
  // mock 只记录状态；全屏时窗口尺寸由系统接管，这里不动 size
  w.fullscreen = v
}

///|
pub impl Backend for MockBackend with fn set_window_titlebar_style(
  self,
  h,
  style,
) -> Unit raise UiError {
  let w = self.window(h)
  // mock 只记录状态；沉浸式那半（内容铺满、红绿灯浮在内容上）是原生层的事
  w.titlebar_style = style
}

///|
pub impl Backend for MockBackend with fn set_window_traffic_light_position(
  self,
  h,
  p,
) -> Unit raise UiError {
  let w = self.window(h)
  // mock 只记录状态；把红绿灯整簇挪过去（含 resize 时重新断言）是原生层的事
  w.traffic_light_position = p
}

///|
/// 测试侧设置缩放，模拟 HiDPI 屏幕。
pub fn MockBackend::set_window_scale(
  self : MockBackend,
  h : NativeHandle,
  scale : Scale,
) -> Unit raise UiError {
  let w = self.window(h)
  w.scale = scale
}

///|
pub impl Backend for MockBackend with fn clipboard_text(self) -> String? raise UiError {
  self.check_initialized()
  self.clipboard
}

///|
pub impl Backend for MockBackend with fn set_clipboard_text(self, text) -> Unit raise UiError {
  self.check_initialized()
  self.clipboard = Some(text)
}

///|
pub impl Backend for MockBackend with fn show_message(self, title, text) -> Unit raise UiError {
  self.check_initialized()
  self.dialog_log.push("message:" + title + "|" + text)
}

///|
pub impl Backend for MockBackend with fn confirm(self, title, text) -> Bool raise UiError {
  self.check_initialized()
  self.dialog_log.push("confirm:" + title + "|" + text)
  self.take_confirm()
}

///|
pub impl Backend for MockBackend with fn open_file(self, title) -> String? raise UiError {
  self.check_initialized()
  self.dialog_log.push("open:" + title)
  self.take_path()
}

///|
pub impl Backend for MockBackend with fn save_file(self, title, default_name) -> String? raise UiError {
  self.check_initialized()
  self.dialog_log.push("save:" + title + "|" + default_name)
  self.take_path()
}

///|
pub impl Backend for MockBackend with fn select_folder(self, title) -> String? raise UiError {
  self.check_initialized()
  self.dialog_log.push("folder:" + title)
  self.take_path()
}

///|
pub impl Backend for MockBackend with fn set_menu_bar(self, bar) -> Unit raise UiError {
  self.check_initialized()
  self.menu_bar = Some(bar)
  self.menu_installs = self.menu_installs + 1
}

///|
pub impl Backend for MockBackend with fn set_app_icon(self, name) -> Unit raise UiError {
  self.check_initialized()
  self.app_icon = Some(name)
}

///|
/// 只记流水，不改任何显示状态——mock 没有屏幕。它唯一尽的职责是句柄式的校验：
/// id 不在已安装的菜单栏里就报错（契约见 trait 的那段注释）。真后端把同一条校验
/// 放在原生层（找不到那个 id 就是没装上），所以两边的失败形态是一样的。
pub impl Backend for MockBackend with fn set_menu_item_checked(
  self,
  id,
  checked,
) -> Unit raise UiError {
  self.check_initialized()
  let found = match self.menu_bar {
    None => false
    Some(bar) =>
      match bar.find(id) {
        None => false
        Some(_) => true
      }
  }
  if !found {
    raise OperationFailed("菜单项 \{id} 不在已安装的菜单栏里")
  }
  self.menu_checks.push((id, checked))
}

///|
/// 按入队顺序取确认框应答；没有脚本时返回"否"——测试里的默认必须是安全的那一侧。
/// 走兜底分支时不推进游标，这样 `pending_dialog_replies` 始终等于未消费的脚本条数，
/// 不会因为多调了一次而变成负数。
fn MockBackend::take_confirm(self : MockBackend) -> Bool {
  if self.confirm_cursor < self.confirm_replies.length() {
    let v = self.confirm_replies[self.confirm_cursor]
    self.confirm_cursor = self.confirm_cursor + 1
    v
  } else {
    false
  }
}

///|
fn MockBackend::take_path(self : MockBackend) -> String? {
  if self.path_cursor < self.path_replies.length() {
    let v = self.path_replies[self.path_cursor]
    self.path_cursor = self.path_cursor + 1
    v
  } else {
    None
  }
}

///|
/// 显式把 `Backend` 的方法开放为点号方法。不写这条的话，测试里
/// `b.create_window(...)` 依赖的是已被标记为过时的隐式提升。
pub extend MockBackend with Backend::{
  init,
  terminate,
  poll_event,
  create_window,
  destroy_window,
  set_window_title,
  set_window_size,
  show_window,
  hide_window,
  window_scale,
  screen_size,
  window_work_area,
  window_size,
  set_window_position,
  window_position,
  set_window_resizable,
  set_window_fullscreen,
  set_window_titlebar_style,
  set_window_traffic_light_position,
  create_widget,
  create_ranged_widget,
  destroy_widget,
  set_widget_text,
  widget_text,
  set_widget_checked,
  widget_checked,
  set_widget_value,
  widget_value,
  set_widget_range,
  append_widget_option,
  set_widget_selected,
  widget_selected,
  set_widget_datetime,
  widget_datetime,
  set_widget_visible,
  widget_visible,
  set_widget_enabled,
  widget_enabled,
  set_widget_style,
  set_widget_accessibility,
  set_widget_bounds,
  widget_bounds,
  widget_intrinsic_size,
  attach_widget,
  detach_widget,
  raise_widget,
  set_paint_order,
  set_focus_chain,
  clipboard_text,
  set_clipboard_text,
  system_theme,
  show_message,
  confirm,
  open_file,
  save_file,
  select_folder,
  set_menu_bar,
  set_menu_item_checked,
}

///|
test "MockBackend 生命周期：未初始化就创建窗口会失败" {
  let b = MockBackend::new()
  let msg = try {
    let _ = b.create_window("x", LogicalSize::{ width: 100.0, height: 80.0, })
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("UI 初始化失败：Backend 尚未初始化"))
  Backend::init(b)
  let h = b.create_window("x", LogicalSize::{ width: 100.0, height: 80.0, })
  assert_eq(b.live(), 1)
  Backend::destroy_window(b, h)
  assert_eq(b.live(), 0)
}

///|
test "MockBackend 窗口状态读写走句柄表" {
  let b = MockBackend::new()
  Backend::init(b)
  let h = b.create_window("MoonUI", LogicalSize::{
    width: 800.0,
    height: 600.0,
  })
  assert_eq(b.window(h).title, "MoonUI")
  assert_false(b.window(h).visible)
  Backend::show_window(b, h)
  assert_true(b.window(h).visible)
  Backend::set_window_title(b, h, "MoonUI — 改名")
  assert_eq(b.window(h).title, "MoonUI — 改名")
  Backend::set_window_size(b, h, LogicalSize::{ width: 640.0, height: 480.0, })
  assert_eq(b.window(h).size.width, 640.0)
  // 负尺寸按零处理，原生层不会收到非法尺寸
  Backend::set_window_size(b, h, LogicalSize::{ width: -5.0, height: 10.0, })
  assert_eq(b.window(h).size, LogicalSize::{ width: 0.0, height: 10.0, })
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
test "已销毁窗口的句柄不会命中新窗口" {
  let b = MockBackend::new()
  Backend::init(b)
  let first = b.create_window("A", LogicalSize::{ width: 10.0, height: 10.0, })
  Backend::destroy_window(b, first)
  let second = b.create_window("B", LogicalSize::{ width: 20.0, height: 20.0, })
  assert_eq(second.id, first.id)
  let msg = try {
    let _ = b.window(first)
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("无效的原生句柄"))
  assert_eq(b.window(second).title, "B")
}

///|
test "事件队列按注入顺序取出且取空返回 None" {
  let b = MockBackend::new()
  Backend::init(b)
  let target = EventTarget::{ id: 7, generation: 0, }
  b.push_event(Click(target, Left))
  b.push_event(Close(target))
  assert_eq(Backend::poll_event(b), Some(Click(target, Left)))
  assert_eq(Backend::poll_event(b), Some(Close(target)))
  assert_eq(Backend::poll_event(b), None)
  // 队列空了之后再注入，仍可继续读取
  b.push_event(Change(target))
  assert_eq(Backend::poll_event(b), Some(Change(target)))
}

///|
test "剪贴板与 HiDPI 缩放因子" {
  let b = MockBackend::new()
  Backend::init(b)
  assert_eq(Backend::clipboard_text(b), None)
  Backend::set_clipboard_text(b, "界面")
  assert_eq(Backend::clipboard_text(b), Some("界面"))
  let h = b.create_window("x", LogicalSize::{ width: 100.0, height: 100.0, })
  assert_eq(Backend::window_scale(b, h), Scale::one())
  MockBackend::set_window_scale(b, h, Scale::{ x: 2.0, y: 2.0, })
  assert_eq(
    Backend::window_scale(b, h).to_physical_size(LogicalSize::{
      width: 100.0,
      height: 50.0,
    }),
    PhysicalSize::{ width: 200, height: 100, },
  )
}

///|
test "窗口位置、可调整与全屏状态可读写" {
  let b = MockBackend::new()
  Backend::init(b)
  let h = b.create_window("Pos", LogicalSize::{ width: 400.0, height: 300.0, })
  assert_eq(Backend::window_position(b, h), LogicalPoint::{ x: 0.0, y: 0.0, })
  Backend::set_window_position(b, h, LogicalPoint::{ x: 120.0, y: 60.0, })
  assert_eq(Backend::window_position(b, h), LogicalPoint::{ x: 120.0, y: 60.0, })
  assert_eq(Backend::window_size(b, h), LogicalSize::{
    width: 400.0,
    height: 300.0,
  })
  assert_true(b.window(h).resizable)
  Backend::set_window_resizable(b, h, false)
  assert_false(b.window(h).resizable)
  Backend::set_window_fullscreen(b, h, true)
  assert_true(b.window(h).fullscreen)
  // 标题栏样式（§12）：默认 Standard，设成 Immersive 后读回，再切回 Standard
  assert_eq(b.window(h).titlebar_style, TitlebarStyle::Standard)
  Backend::set_window_titlebar_style(b, h, TitlebarStyle::Immersive)
  assert_eq(b.window(h).titlebar_style, TitlebarStyle::Immersive)
  Backend::set_window_titlebar_style(b, h, TitlebarStyle::Standard)
  assert_eq(b.window(h).titlebar_style, TitlebarStyle::Standard)
  // 红绿灯位置（§12）：默认 (0,0)，设一个非零值后读回
  assert_eq(b.window(h).traffic_light_position, LogicalPoint::{
    x: 0.0,
    y: 0.0,
  })
  Backend::set_window_traffic_light_position(b, h, LogicalPoint::{
    x: 12.0,
    y: 8.0,
  })
  assert_eq(b.window(h).traffic_light_position, LogicalPoint::{
    x: 12.0,
    y: 8.0,
  })
  assert_eq(Backend::screen_size(b), LogicalSize::{
    width: 1920.0,
    height: 1080.0,
  })
  MockBackend::set_screen_size(b, LogicalSize::{ width: 1000.0, height: 700.0, })
  assert_eq(Backend::screen_size(b), LogicalSize::{
    width: 1000.0,
    height: 700.0,
  })
  Backend::terminate(b)
  let msg = try {
    let _ = Backend::screen_size(b)
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("UI 初始化失败：Backend 尚未初始化"))
}

///|
test "terminate 回收未显式销毁的窗口" {
  let b = MockBackend::new()
  Backend::init(b)
  let _ = b.create_window("A", LogicalSize::{ width: 10.0, height: 10.0, })
  let _ = b.create_window("B", LogicalSize::{ width: 10.0, height: 10.0, })
  assert_eq(b.live(), 2)
  Backend::terminate(b)
  assert_eq(b.live(), 0)
  Backend::init(b)
  let h = b.create_window("C", LogicalSize::{ width: 10.0, height: 10.0, })
  assert_eq(b.live(), 1)
  Backend::destroy_window(b, h)
  assert_eq(b.live(), 0)
}
