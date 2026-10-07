///|
/// libui-ng 真后端（设计文档 §20；开发顺序 §48 第 09~11 步）。
///
/// 这一层把 `Backend` 契约翻译成 `native_*` 那套物理像素调用，是 §47 风险 6
/// （"抽象没被真实后端验证过"）的正面回答：Core 里跑 Demo 的那条泛型路径，
/// 在这里换成一个真窗口、真控件、真消息队列，一行 Core 代码都不用改。
///
/// 三条和 mock 后端不同的地方，都是原生层的事实而不是这里的偏好：
/// - 句柄账本在 `ffi.mbt` 的包级 `handles` 里（libui 的状态是进程全局的），
///   不在 backend 实例里；
/// - `poll_event` 会推进原生消息循环，事件由控件回调放进队列（§10 的
///   trampoline 落点），而不是测试注入；
/// - 尺寸/位置一律先过 `Scale` 换算（§30 只允许这一处换算），C 侧只报 DPI 值。
///
/// 已知边界，都写在对应方法的注释里：输入框与勾选框的**变化事件**、剪贴板、
/// 对话框、菜单栏（§48 的第 12~20 步）在这个版本还没接，`App::post` 的任务要
/// 等下一条原生事件才被执行——那是 `App::step` 的既有顺序，不在这里偷偷改 Core。

///|
pub struct LibuiBackend {
  mut queue : Array[@moonui.Event]
  mut live_windows : Array[@moonui.NativeHandle]
  mut live_widgets : Array[@moonui.NativeHandle]
  /// `poll_event` 的等待预算，毫秒；`-1` = 一直等到有事件为止（产品语义：
  /// 一个空闲的 GUI 不该自己退出）。测试用 `for_testing` 换成有限值，
  /// 消息真丢了就是测试失败，而不是一个挂死的 CI。
  mut wait_budget_ms : Int
  /// libui 的主循环已经结束（收到 WM_QUIT）。只有 `poll_event` 会置位。
  mut loop_ended : Bool
  mut initialized : Bool
}

///|
pub fn LibuiBackend::new() -> LibuiBackend {
  LibuiBackend::{
    queue: [],
    live_windows: [],
    live_widgets: [],
    wait_budget_ms: -1,
    loop_ended: false,
    initialized: false,
  }
}

///|
/// 测试用后端：空转最多 `budget_ms` 毫秒就不再等事件。
/// 取 3000 是因为真窗口的消息投递在慢机器上也要不到 100ms，
/// 超了就是链路断了，应该红而不是等。
pub fn LibuiBackend::for_testing(budget_ms : Int) -> LibuiBackend {
  let b = LibuiBackend::new()
  b.wait_budget_ms = budget_ms
  b
}

///|
/// 一轮 `poll_event` 里最多让原生队列空转这么久。8ms 是量出来的折中：
/// 比一帧（16ms）短，消息不会攒着；比直接 PeekMessage 忙等省，空闲时
/// 每秒只醒 125 次。
let wait_slice_ms = 8

///|
fn LibuiBackend::check_initialized(
  self : LibuiBackend,
) -> Unit raise @moonui.UiError {
  if !self.initialized {
    raise @moonui.InitializationFailed("Backend 尚未初始化")
  }
}

///|
fn LibuiBackend::push(self : LibuiBackend, ev : @moonui.Event) -> Unit {
  self.queue.push(ev)
}

///|
fn LibuiBackend::take(self : LibuiBackend) -> @moonui.Event? {
  if self.queue.length() == 0 {
    None
  } else {
    Some(self.queue.remove(0))
  }
}

///|
/// 窗口所在屏的缩放因子。DPI 每次现读，不缓存——按监视器缩放会变，
/// 而 §30 的换算只认当下这一块屏。
fn scale_of_window(
  h : @moonui.NativeHandle,
) -> @moonui.Scale raise @moonui.UiError {
  @moonui.Scale::of_dpi(native_window_dpi(h).to_double())
}

///|
/// 控件所在屏：控件自己问不到 DPI，按父窗口算（还没挂进窗口时退回进程 DPI，
/// 见 `native_widget_dpi`）。
fn scale_of_widget(
  h : @moonui.NativeHandle,
) -> @moonui.Scale raise @moonui.UiError {
  @moonui.Scale::of_dpi(native_widget_dpi(h).to_double())
}

///|
/// 把"窗口客户区变了"翻译成 Resize 事件。
/// 读尺寸要过句柄表，可能失败——失败就丢事件：这条回调只可能在窗口正在被
/// 拆掉的时候撞上失效句柄，而 Core 也不会派发给已经关掉的窗口（§12）。
fn LibuiBackend::push_resize(
  self : LibuiBackend,
  h : @moonui.NativeHandle,
) -> Unit {
  try {
    let size = self.window_size(h)
    self.push(@moonui.Resize(@moonui.EventTarget::{ id: h.id, }, size))
  } catch {
    _ => ()
  }
}

///|
fn LibuiBackend::drop_handle(
  self : LibuiBackend,
  is_window : Bool,
  h : @moonui.NativeHandle,
) -> Unit {
  let kept : Array[@moonui.NativeHandle] = []
  if is_window {
    for w in self.live_windows {
      if w != h {
        kept.push(w)
      }
    }
    self.live_windows = kept
  } else {
    for w in self.live_widgets {
      if w != h {
        kept.push(w)
      }
    }
    self.live_widgets = kept
  }
}

///|
pub impl @moonui.Backend for LibuiBackend with fn init(self) {
  native_init()
  // Windows 后端这里什么都不做（libui 的 uiMainSteps 是空函数），但契约要求
  // 循环开始前调一次，别的后端（GTK）就是在这里装 g_main_context 的。
  native_main_steps()
  self.initialized = true
  self.loop_ended = false
}

///|
/// 收尾顺序是硬要求：先控件、后窗口，最后才是 `native_terminate`。
/// DestroyWindow 会连带销毁还挂着的子 HWND，但 libui 的控件对象不会跟着没，
/// 于是 uiUninit 的分配审计会把这一次泄漏当成 bug 并 DebugBreak。
/// Core 的正常路径（Close 事件 / Window::close）本来就按这个顺序走，
/// 这里的循环只兜"handler 失败或用户没关窗口就退出"的尾部（§47 风险 2）。
pub impl @moonui.Backend for LibuiBackend with fn terminate(self) {
  for h in self.live_widgets {
    native_widget_destroy(h) catch {
      _ => ()
    }
  }
  for h in self.live_windows {
    native_window_destroy(h) catch {
      _ => ()
    }
  }
  self.live_widgets = []
  self.live_windows = []
  self.queue = []
  self.initialized = false
  self.loop_ended = false
  native_terminate()
}

///|
/// 契约（app.mbt 开头）：真实后端的 `poll_event` 阻塞到有事件或循环结束，
/// 返回 `None` 只表示"循环结束"。这里的"循环结束"有两种：没有存活窗口了
/// （用户把窗口都关了），或者 libui 收到了 WM_QUIT。
///
/// 事件是控件回调放进 `self.queue` 的，所以推进原生循环和取事件是同一件事：
/// 把队列里已有的消息走完，空了才等新消息（见 `pump`）。
pub impl @moonui.Backend for LibuiBackend with fn poll_event(self) -> @moonui.Event? {
  match self.take() {
    Some(ev) => Some(ev)
    None =>
      if self.live_windows.length() == 0 || self.loop_ended {
        None
      } else {
        self.pump()
      }
  }
}

///|
/// 推进原生消息循环，直到控件回调留下一个事件、循环结束，或等待预算用完。
///
/// 顺序是"先清队列、再等新消息"，不是"等新消息、走一步"：
/// `MsgWaitForMultipleObjects` 报告的是**自上次唤醒以来**有没有新消息，队列里
/// 有积压时它照样报超时；而 `uiMainStep(0)` 的返回值分不清"处理了一条"和
/// "队列本来空着"（两者都是 1，只有 WM_QUIT 才是 0）。一次唤醒只走一步的话，
/// 积压会把 WM_QUIT 一直挡在后面，等待预算为无限的产品路径就再也回不来
/// （真窗口的 poll_event 测试里复现过）。所以用 `native_messages_pending`
/// 把队列抽干，`native_wait_messages` 只当有界睡眠用。
fn LibuiBackend::pump(self : LibuiBackend) -> @moonui.Event? {
  // 预算按墙钟算：无限（产品）路径不看时钟，有限（测试）路径到点就返回。
  // 消息真丢了就是测试失败，而不是一个挂死的 CI。
  let deadline = native_time_ms() + self.wait_budget_ms
  let mut ev : @moonui.Event? = None
  while ev is None && !self.loop_ended {
    if native_messages_pending() {
      // 只有 WM_QUIT 会让这一步返回 false
      if !native_main_step(false) {
        self.loop_ended = true
      }
      ev = self.take()
    } else {
      let _ = native_wait_messages(wait_slice_ms)
    }
    if self.wait_budget_ms >= 0 && native_time_ms() >= deadline {
      break
    }
  }
  ev
}

///|
pub impl @moonui.Backend for LibuiBackend with fn create_window(
  self,
  title,
  size,
) -> @moonui.NativeHandle raise @moonui.UiError {
  self.check_initialized()
  // 窗口落在哪块屏要等 HWND 建出来才知道，所以先按进程 DPI 建，再按窗口自己
  // 的 DPI 纠正一次尺寸——§30 的"按监视器缩放"就落在这两行上。
  let system = @moonui.Scale::of_dpi(native_system_dpi().to_double())
  let init_size = system.to_physical_size(size)
  let h = native_window_new(title, init_size.width, init_size.height)
  let actual = scale_of_window(h)
  if actual != system {
    let fixed = actual.to_physical_size(size)
    native_window_set_content_size(h, fixed.width, fixed.height)
  }
  // 关闭和改尺寸都只往队列里放事件，销毁动作留给 Core（§12：Close 走
  // Window::release，先内容树后窗口）。
  let target = @moonui.EventTarget::{ id: h.id, }
  native_window_on_close(h, fn() { self.push(@moonui.Close(target)) })
  native_window_on_resized(h, fn() { self.push_resize(h) })
  self.live_windows.push(h)
  h
}

///|
pub impl @moonui.Backend for LibuiBackend with fn destroy_window(self, h) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_destroy(h)
  self.drop_handle(true, h)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn set_window_title(
  self,
  h,
  title,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_set_title(h, title)
}

///|
/// `set_window_size` 设的是客户区尺寸——libui 的 uiWindowSetContentSize 就是这个
/// 语义，而 Core 的布局也正是按客户区算的（§14）。
pub impl @moonui.Backend for LibuiBackend with fn set_window_size(self, h, size) -> Unit raise @moonui.UiError {
  self.check_initialized()
  let phys = scale_of_window(h).to_physical_size(size)
  native_window_set_content_size(h, phys.width, phys.height)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn window_size(self, h) -> @moonui.LogicalSize raise @moonui.UiError {
  self.check_initialized()
  let (w, height) = native_window_content_size(h)
  scale_of_window(h).to_logical_size(@moonui.PhysicalSize::{ width: w, height, })
}

///|
pub impl @moonui.Backend for LibuiBackend with fn show_window(self, h) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_show(h)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn hide_window(self, h) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_hide(h)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn window_scale(self, h) -> @moonui.Scale raise @moonui.UiError {
  self.check_initialized()
  scale_of_window(h)
}

///|
/// 主屏工作区（不含任务栏）：`Window::center` 靠它，用整屏会把窗口摆到
/// 任务栏底下（§12）。换算基准只能用进程 DPI——这时还没有窗口可问。
pub impl @moonui.Backend for LibuiBackend with fn screen_size(self) -> @moonui.LogicalSize raise @moonui.UiError {
  self.check_initialized()
  let (w, height) = native_screen_work_area()
  @moonui.Scale::of_dpi(native_system_dpi().to_double()).to_logical_size(@moonui.PhysicalSize::{
    width: w,
    height,
  })
}

///|
/// libui-ng 的 Windows 后端没有查询系统外观的 API（既没读
/// AppsUseLightTheme 也没订阅 WM_SETTINGCHANGE），所以这里如实报告 Light：
/// `Theme::System` 在 Windows 上等价于 Light，而不是"猜一个 Dark"或返回
/// `System` 让 Core 再兜一次。真正的深色模式要等 §21 的自绘后端或上游补 API。
pub impl @moonui.Backend for LibuiBackend with fn system_theme(self) -> @moonui.Theme raise @moonui.UiError {
  self.check_initialized()
  @moonui.Light
}

///|
pub impl @moonui.Backend for LibuiBackend with fn set_window_position(
  self,
  h,
  origin,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  let p = scale_of_window(h).to_physical_point(origin)
  native_window_set_position(h, p.x, p.y)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn window_position(self, h) -> @moonui.LogicalPoint raise @moonui.UiError {
  self.check_initialized()
  let (x, y) = native_window_position(h)
  scale_of_window(h).to_logical_point(@moonui.PhysicalPoint::{ x, y, })
}

///|
pub impl @moonui.Backend for LibuiBackend with fn set_window_resizable(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_set_resizable(h, v)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn set_window_fullscreen(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_set_fullscreen(h, v)
}

///|
/// 四种控件都由 libui 建，`native_widget_new` 里做 kind 映射。
///
/// 只有 Button 会在这里装点击回调：BN_CLICKED 是四种控件里唯一"按下就派发"的
/// 原生通知。输入框的 EN_CHANGE 与勾选框的 BN_CLICKED 也要走同一条槽位机制，
/// 但那两条要在接上之后有测试才算数（§47），所以这一版不写没验证过的 plumbing。
pub impl @moonui.Backend for LibuiBackend with fn create_widget(
  self,
  kind,
  text,
) -> @moonui.NativeHandle raise @moonui.UiError {
  self.check_initialized()
  let h = native_widget_new(kind, text)
  match kind {
    @moonui.Button => {
      let target = @moonui.EventTarget::{ id: h.id, }
      native_widget_on_click(h, fn() {
        self.push(@moonui.Click(target, @moonui.Left))
      })
    }
    _ => ()
  }
  self.live_widgets.push(h)
  h
}

///|
pub impl @moonui.Backend for LibuiBackend with fn destroy_widget(self, h) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_destroy(h)
  self.drop_handle(false, h)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn set_widget_text(self, h, text) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_set_text(h, text)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn widget_text(self, h) -> String raise @moonui.UiError {
  self.check_initialized()
  native_widget_text(h)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn set_widget_checked(self, h, v) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_set_checked(h, v)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn widget_checked(self, h) -> Bool raise @moonui.UiError {
  self.check_initialized()
  native_widget_checked(h)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn set_widget_visible(self, h, v) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_set_visible(h, v)
}

///|
/// 读的是 `IsWindowVisible`，也就是"屏幕上现在看得见吗"：父窗口还没 show
/// 时这里是 false。Core 不用它做布局，只用于断言与无障碍视图。
pub impl @moonui.Backend for LibuiBackend with fn widget_visible(self, h) -> Bool raise @moonui.UiError {
  self.check_initialized()
  native_widget_visible(h)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn set_widget_enabled(self, h, v) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_set_enabled(h, v)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn widget_enabled(self, h) -> Bool raise @moonui.UiError {
  self.check_initialized()
  native_widget_enabled(h)
}

///|
/// 逻辑矩形 → 客户区物理矩形，然后 SetWindowPos（z-order 不动，见 adapter.c）。
/// 控件问的是父窗口的 DPI，和窗口自己的换算同一块屏。
pub impl @moonui.Backend for LibuiBackend with fn set_widget_bounds(self, h, r) -> Unit raise @moonui.UiError {
  self.check_initialized()
  let p = scale_of_widget(h).to_physical_rect(r)
  native_control_set_bounds(
    h,
    p.origin.x,
    p.origin.y,
    p.size.width,
    p.size.height,
  )
}

///|
pub impl @moonui.Backend for LibuiBackend with fn widget_bounds(self, h) -> @moonui.LogicalRect raise @moonui.UiError {
  self.check_initialized()
  let (x, y) = native_widget_origin(h)
  let (w, height) = native_widget_size(h)
  scale_of_widget(h).to_logical_rect(@moonui.PhysicalRect::{
    origin: @moonui.PhysicalPoint::{ x, y, },
    size: @moonui.PhysicalSize::{ width: w, height, },
  })
}

///|
/// 固有尺寸来自 libui 自己的最小尺寸（button 用 BCM_GETIDEALSIZE，label 用文本
/// extent），字体度量因此是原生层的，不是 Core 猜的（§18）。
pub impl @moonui.Backend for LibuiBackend with fn widget_intrinsic_size(self, h) -> @moonui.LogicalSize raise @moonui.UiError {
  self.check_initialized()
  let (w, height) = native_widget_minimum_size(h)
  scale_of_widget(h).to_logical_size(@moonui.PhysicalSize::{ width: w, height, })
}

///|
/// §14：控件的 HWND 直接挂进窗口的 HWND，libui 的容器布局不参与。
/// 这里只管挂接，矩形由 `set_widget_bounds` 在 Core 布局算完后单独给。
pub impl @moonui.Backend for LibuiBackend with fn attach_widget(
  self,
  window,
  child,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_control_attach(window, child)
}

///|
/// 摘下来 = 挂到 adapter 自建的隐藏窗口。放在那里之后父窗口不是任何 libui
/// 窗口，WM_COMMAND 进不了回调路由，控件于是既看不见也不响应——
/// 这正是"脱离了内容树"应有的状态（§8）。
pub impl @moonui.Backend for LibuiBackend with fn detach_widget(self, child) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_control_detach(child)
}

///|
/// 下面六个方法是 §48 的第 18~20 步（剪贴板、对话框、菜单栏），还没接。
/// 如实报 `Unsupported` 而不是空实现：空实现会让 Demo 在真后端上"看起来成功"，
/// 而 §33 要求 C 层的失败形态必须变成可读的错误。
pub impl @moonui.Backend for LibuiBackend with fn clipboard_text(self) -> String? raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported(
    "剪贴板要 Win32 OpenClipboard，属 §48-18，还没接",
  )
}

///|
pub impl @moonui.Backend for LibuiBackend with fn set_clipboard_text(
  self,
  _text,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported(
    "剪贴板要 Win32 OpenClipboard，属 §48-18，还没接",
  )
}

///|
pub impl @moonui.Backend for LibuiBackend with fn show_message(
  self,
  _title,
  _text,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("对话框要 uiMsgBox，属 §48-19，还没接")
}

///|
pub impl @moonui.Backend for LibuiBackend with fn confirm(self, _title, _text) -> Bool raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("对话框要 uiMsgBox，属 §48-19，还没接")
}

///|
pub impl @moonui.Backend for LibuiBackend with fn open_file(self, _title) -> String? raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported(
    "文件选择要 IFileDialog，属 §48-19，还没接",
  )
}

///|
pub impl @moonui.Backend for LibuiBackend with fn save_file(
  self,
  _title,
  _default_name,
) -> String? raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported(
    "文件选择要 IFileDialog，属 §48-19，还没接",
  )
}

///|
pub impl @moonui.Backend for LibuiBackend with fn select_folder(self, _title) -> String? raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported(
    "文件夹选择要 IFileDialog，属 §48-19，还没接",
  )
}

///|
pub impl @moonui.Backend for LibuiBackend with fn set_menu_bar(self, _bar) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("菜单栏要 uiNewMenu，属 §48-20，还没接")
}

///|
/// 显式把 `Backend` 的方法开放为点号方法，避免依赖已标记为过时的隐式提升
/// （和 `MockBackend` 同一套写法）。
pub extend LibuiBackend with @moonui.Backend::{
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
  set_widget_bounds,
  widget_bounds,
  widget_intrinsic_size,
  attach_widget,
  detach_widget,
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
