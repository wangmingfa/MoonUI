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
  fn create_window(Self, title : String, size : LogicalSize) -> NativeHandle raise UiError
  fn destroy_window(Self, NativeHandle) -> Unit raise UiError
  fn set_window_title(Self, NativeHandle, String) -> Unit raise UiError
  fn set_window_size(Self, NativeHandle, LogicalSize) -> Unit raise UiError
  fn show_window(Self, NativeHandle) -> Unit raise UiError
  fn hide_window(Self, NativeHandle) -> Unit raise UiError
  /// 窗口所在屏幕的缩放因子，用于逻辑/物理像素换算（§30）。
  fn window_scale(Self, NativeHandle) -> Scale raise UiError
  /// 主屏可用区域，逻辑像素。`Window::center` 与多屏定位依赖它（§12、§30）。
  fn screen_size(Self) -> LogicalSize raise UiError
  /// 系统当前的外观（Light/Dark）。`Theme::System` 靠它落地（§16）。
  fn system_theme(Self) -> Theme raise UiError
  /// 读回窗口当前的尺寸/位置：原生层是唯一事实来源，Core 不缓存。
  fn window_size(Self, NativeHandle) -> LogicalSize raise UiError
  fn set_window_position(Self, NativeHandle, LogicalPoint) -> Unit raise UiError
  fn window_position(Self, NativeHandle) -> LogicalPoint raise UiError
  fn set_window_resizable(Self, NativeHandle, Bool) -> Unit raise UiError
  fn set_window_fullscreen(Self, NativeHandle, Bool) -> Unit raise UiError
  /// 控件创建与属性读写（§13）。窗口和控件共用同一张句柄表，所以
  /// `EventTarget.id` 全局唯一，派发时不会把窗口和控件混为一谈。
  fn create_widget(Self, kind : WidgetKind, text : String) -> NativeHandle raise UiError
  fn destroy_widget(Self, NativeHandle) -> Unit raise UiError
  fn set_widget_text(Self, NativeHandle, String) -> Unit raise UiError
  fn widget_text(Self, NativeHandle) -> String raise UiError
  fn set_widget_checked(Self, NativeHandle, Bool) -> Unit raise UiError
  fn widget_checked(Self, NativeHandle) -> Bool raise UiError
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
  /// MoonUI 自己算布局（§14），后端只接受算好的绝对边界（逻辑像素）。
  fn set_widget_bounds(Self, NativeHandle, LogicalRect) -> Unit raise UiError
  fn widget_bounds(Self, NativeHandle) -> LogicalRect raise UiError
  /// 固有尺寸由后端测量：字体度量属于原生层，Core 不猜（§18）。
  fn widget_intrinsic_size(Self, NativeHandle) -> LogicalSize raise UiError
  /// 原生父子挂接：控件必须属于窗口才会显示（§8）。
  /// Row/Column 这类容器在 Core 里算绝对边界、不占原生对象（§14），
  /// 所以后端的挂接目标只有窗口。
  fn attach_widget(Self, window : NativeHandle, child : NativeHandle) -> Unit raise UiError
  fn detach_widget(Self, child : NativeHandle) -> Unit raise UiError
  /// 层叠（§14 的 Stack）：把控件提到所在窗口子窗口列表的最上层。
  ///
  /// 为什么不并进 `attach_widget`：挂载只能给出"顺序"这一件事，而原生层的视觉层叠
  /// 与键盘 Tab 走的是同一份 z-order，两者方向相反（先挂的在 Tab 链前面，后挂的
  /// 画在上层）。Stack 的契约是"数组靠后的画在上层"，所以由 Core 在挂载之后按
  /// 数组顺序逐个 raise，把视觉顺序钉死——代价写在 window.mbt 的 `apply_layers`。
  fn raise_widget(Self, child : NativeHandle) -> Unit raise UiError
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
  /// 菜单栏（§25）。真实后端在这里把 Core 的菜单树换成 uiMenu/uiMenuItem；
  /// 用户点击通过 `Event::MenuSelect` 回流，Core 不轮询菜单状态。
  fn set_menu_bar(Self, MenuBar) -> Unit raise UiError
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
  mut scale : Scale
  /// 子控件的层叠顺序，**从顶层到底层**——和 Win32 `EnumChildWindows` 的返回顺序
  /// 同向，所以 mock 里写下的层叠断言能原样搬到真后端上（§14、§48-15）。
  mut z_order : Array[NativeHandle]
} derive(Debug, Eq)

///|
pub struct MockBackend {
  handles : HandleTable
  windows : Array[MockWindow]
  widgets : Array[MockWidget]
  queue : Array[Event]
  mut screen : LogicalSize
  mut appearance : Theme
  mut cursor : Int
  mut clipboard : String?
  // §24 的脚本化对话框：请求日志 + 两条按序消费的应答队列
  dialog_log : Array[String]
  confirm_replies : Array[Bool]
  mut confirm_cursor : Int
  path_replies : Array[String?]
  mut path_cursor : Int
  // §25 的菜单栏快照与安装次数
  mut menu_bar : MenuBar?
  mut menu_installs : Int
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
pub fn MockBackend::pending_dialog_replies(self : MockBackend) -> Int {
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
pub fn MockBackend::push_menu_select(self : MockBackend, id : Int) -> Unit {
  self.queue.push(MenuSelect(EventTarget::{ id, }))
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
pub fn MockBackend::menu_install_count(self : MockBackend) -> Int {
  self.menu_installs
}

///|
/// 存活的句柄总数（窗口 + 控件），泄漏检查用。
pub fn MockBackend::live(self : MockBackend) -> Int {
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
) -> Int raise UiError {
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
) -> Int raise UiError {
  self.slot_of(h, false)
}

///|
fn MockBackend::widget_slot(
  self : MockBackend,
  h : NativeHandle,
) -> Int raise UiError {
  self.slot_of(h, true)
}

///|
fn MockBackend::windows_at(self : MockBackend, index : Int) -> MockWindow? {
  if index >= 0 && index < self.windows.length() {
    Some(self.windows[index])
  } else {
    None
  }
}

///|
fn MockBackend::widgets_at(self : MockBackend, index : Int) -> MockWidget? {
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
    scale: Scale::one(),
    z_order: [],
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
  window_size,
  set_window_position,
  window_position,
  set_window_resizable,
  set_window_fullscreen,
  create_widget,
  destroy_widget,
  set_widget_text,
  widget_text,
  set_widget_checked,
  widget_checked,
  set_widget_visible,
  widget_visible,
  set_widget_enabled,
  widget_enabled,
  set_widget_style,
  set_widget_bounds,
  widget_bounds,
  widget_intrinsic_size,
  attach_widget,
  detach_widget,
  raise_widget,
  clipboard_text,
  set_clipboard_text,
  system_theme,
  show_message,
  confirm,
  open_file,
  save_file,
  select_folder,
  set_menu_bar,
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
  let target = EventTarget::{ id: 7, }
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
