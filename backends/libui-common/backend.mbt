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
/// 已知边界，都写在对应方法的注释里：`App::post` 的任务要等下一条原生事件才被执行
/// ——那是 `App::step` 的既有顺序，不在这里偷偷改 Core。输入框与勾选框的变化事件、
/// 剪贴板、对话框与文件面板、菜单栏（§48 的第 13/16/18/19/20 步）、键盘与焦点
/// （`T39`）、系统外观的读数（`T40`）都已经接上，两份 C 各实现一遍。剩下的缺口是
/// 鼠标（`T39` 里没做的那半）、主题切换的**通知**（读数已接，切换怎么告诉 Core 在
/// `T48`）、缩放（`T24`）——外加按窗口取屏幕读数（`T42`）。

///|
pub struct LibuiBackend {
  mut queue : Array[@moonui.Event]
  mut live_windows : Array[@moonui.NativeHandle]
  mut live_widgets : Array[@moonui.NativeHandle]
  /// 上一圈事件循环问到的焦点：`(窗口, 这只窗口当下的焦点控件)`。
  /// 只在 `refresh_focus` 里读写，整表按 `live_windows` 重建，所以销毁的窗口
  /// 不会在这里留下一条旧焦点被当成"丢了焦点"（§32）。
  mut focus_of : Array[(@moonui.NativeHandle, @moonui.NativeHandle?)]
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
    focus_of: [],
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
/// 把"输入框里的字变了"翻译成 Input 事件。
/// 和 push_resize 同一个形状：原生通知只说"变了"，内容要回过头去问原生控件
/// （§48-16），所以这里读的是 `widget_text`，不是回调带来的任何参数——libui
/// 三个平台的回调都不带文本，差异全留在 C 里。
/// 读文本要过句柄表，可能失败——失败就丢事件，理由同 push_resize（§12）。
fn LibuiBackend::push_input(
  self : LibuiBackend,
  h : @moonui.NativeHandle,
) -> Unit {
  try {
    let text = self.widget_text(h)
    self.push(@moonui.Input(@moonui.EventTarget::{ id: h.id, }, text))
  } catch {
    _ => ()
  }
}

///|
/// 把"有颗键出事了"翻译成 KeyDown/KeyUp（§10/§26，`T39`）。
/// 和 push_input 同一个形状：通知不带内容，键名、修饰键、按下还是抬起、打在谁身上
/// 四样都要当场读回去（§48-16）。
/// 两种丢弃都是"这颗键不归本框架管"，不是错误：词表外的键（修饰键自己、输入法、
/// 媒体键）读回来是空串；目标反查不到句柄，说明焦点在原生层的辅助对象或别的进程
/// 那里——这里不猜"那应该是主窗口吧"，猜了 Core 就会收到一条假按键。
fn LibuiBackend::push_key(self : LibuiBackend) -> Unit {
  let name = native_key_name()
  match native_key_target() {
    None => ()
    Some(t) =>
      if name != "" {
        let mods = native_key_modifiers()
        let kp = @moonui.KeyPress::{
          key: name,
          ctrl: mods % 2 == 1,
          alt: mods / 2 % 2 == 1,
          shift: mods / 4 % 2 == 1,
          meta: mods / 8 % 2 == 1,
        }
        self.push(
          if native_key_is_down() {
            @moonui.KeyDown(@moonui.EventTarget::{ id: t.id, }, kp)
          } else {
            @moonui.KeyUp(@moonui.EventTarget::{ id: t.id, }, kp)
          },
        )
      }
  }
}

///|
/// 焦点轮询（§32，`T39` 方案甲的另一半）：每圈事件循环把每只存活窗口问一次
/// "你把焦点给了哪个我们的控件"，和上一圈比，变了才发事件。
///
/// 为什么没有回调：mac 的 `NSWindow.didBecomeKeyNotification` 只说窗口，控件级的是
/// `becomeFirstResponder`（要在每个控件上盖一层），Windows 只有 `WM_KILLFOCUS`/
/// `WM_SETFOCUS` 成对消息，得先有焦点才拿得到下一个——两边都做不到"既及时又不侵入"，
/// 所以按回读来做，判据形状和 `native_focused_control` 的注释一致。去重在这里：
/// 一圈问一次、只在差异上发事件，所以"程序改焦点"跑出的是恰好一条 `Focus`。
///
/// 读不到焦点就当没变（`before`）：那条失败只可能在窗口正在被拆掉时撞上失效句柄，
/// 这时发一条 `Blur` 是假事件，理由同 `push_resize`（§12）。
fn LibuiBackend::refresh_focus(self : LibuiBackend) -> Unit {
  let now : Array[(@moonui.NativeHandle, @moonui.NativeHandle?)] = []
  for w in self.live_windows {
    let mut before : @moonui.NativeHandle? = None
    for entry in self.focus_of {
      if entry.0 == w {
        before = entry.1
      }
    }
    let cur = native_focused_control(w) catch { _ => before }
    now.push((w, cur))
    if before != cur {
      match before {
        Some(c) => self.push(@moonui.Blur(@moonui.EventTarget::{ id: c.id, }))
        None => ()
      }
      match cur {
        Some(c) => self.push(@moonui.Focus(@moonui.EventTarget::{ id: c.id, }))
        None => ()
      }
    }
  }
  self.focus_of = now
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
pub impl @moonui.Backend for LibuiBackend with fn init(self) -> Unit raise @moonui.UiError {
  native_init()
  // Windows 后端这里什么都不做（libui 的 uiMainSteps 是空函数），但契约要求
  // 循环开始前调一次，别的后端（GTK）就是在这里装 g_main_context 的。
  native_main_steps()
  // 键盘是进程级的一条监听，不占窗口/控件的槽位账（`T39`：实测一份 96 的表在
  // "每窗 2 条 + 每控件 ≤1 条 + 全局 1 条"下够用，所以这里没有分池的前提）。
  // 装不上就是槽位满了，init 必须带原因失败，而不是留一条"以后按键永远不响"的绿。
  native_on_key(fn() { self.push_key() })
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
  self.focus_of = []
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
    // 每圈先问一次焦点（`T39`）：轮询出来的 Blur/Focus 进队列后先于新消息被取走，
    // 所以"程序改焦点 → 恰好一条 Focus"这条判据不依赖后面有没有别的消息。
    self.refresh_focus()
    ev = self.take()
    if ev is None {
      if native_messages_pending() {
        // 只有 WM_QUIT 会让这一步返回 false
        if !native_main_step(false) {
          self.loop_ended = true
        }
        ev = self.take()
      } else {
        let _ = native_wait_messages(wait_slice_ms)
      }
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
/// 系统外观（§16）。libui-ng 自己没有查询口，所以这一条走 adapter.h 的
/// `moonui_system_theme`：mac 读 `NSApp.effectiveAppearance`，Windows 读注册表的
/// `AppsUseLightTheme`。两边读不到都当浅色，于是 `Theme::System` 在老系统上等价于
/// Light——这是**读数的兜底**，不是"没接"：接之前这里根本不调 C，恒报 Light，
/// 深色桌面上 `App::appearance`/`palette`/`style_base` 三处一起跟着浅色那套走。
/// 切换主题什么时候生效是另一笔账（`T40`：今天只有 `poll_event` 一条通道，而
/// `Event` 里没有 `ThemeChanged`，那是公共 API 变化，形状要让 owner 定）。
pub impl @moonui.Backend for LibuiBackend with fn system_theme(self) -> @moonui.Theme raise @moonui.UiError {
  self.check_initialized()
  if native_system_theme_is_dark() {
    @moonui.Dark
  } else {
    @moonui.Light
  }
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
/// 三种会动的控件都在这里装回调：Button 的点击、输入框的文本变化、勾选框的
/// 勾选。三条都走同一套槽位机制，只是原生通知不同（WM_COMMAND/BN_CLICKED、
/// EN_CHANGE、BN_CLICKED），到 MoonBit 这一侧统统翻译成 §10 的 Event 入队，
/// Core 那边读不出差别（§48-12/13/16）。
/// 纯布局节点不占原生对象，到不了这里。
pub impl @moonui.Backend for LibuiBackend with fn create_widget(
  self,
  kind,
  text,
) -> @moonui.NativeHandle raise @moonui.UiError {
  self.check_initialized()
  let h = native_widget_new(kind, text)
  let target = @moonui.EventTarget::{ id: h.id, }
  match kind {
    @moonui.Button =>
      native_widget_on_click(h, fn() {
        self.push(@moonui.Click(target, @moonui.Left))
      })
    @moonui.TextInput =>
      native_widget_on_text_changed(h, fn() { self.push_input(h) })
    @moonui.Checkbox =>
      native_widget_on_toggled(h, fn() { self.push(@moonui.Change(target)) })
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
/// §15/§16 下发的样式在原生控件后端上**有意不生效**：§32 要保住系统原生外观，
/// 而 libui-ng 根本不给 button/label 提供 per-control 的字体或配色接口（它只有
/// `uiFontButton` 这种"弹字体对话框"的控件）。所以这里只检查初始化，其余什么都不做，
/// `widget_intrinsic_size` 继续报 libui 在系统字体下的最小尺寸。
///
/// 两个代价都写在这条豁免旁边，不当隐藏行为：
/// - 不校验句柄。真后端的句柄校验全在 C 侧，这里没有任何原生调用可以顺带做，
///   所以传错句柄不会报错。Core 只会给自己创建且尚未销毁的叶子推样式，因此无害。
/// - 同一份 `Style` 在 Mock 上会改度量、在这里不会，所以跨后端的布局数值断言
///   只能拿"不含字号"的样式来比。
pub impl @moonui.Backend for LibuiBackend with fn set_widget_style(
  self,
  _h,
  _style,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
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
/// 层叠：SetWindowPos(HWND_TOP)。为什么需要这条而不是让挂载顺序自己满足，
/// 见 `Backend::raise_widget` 的契约（§14：挂载顺序管 Tab，Stack 要的是反过来
/// 的视觉顺序，原生层只有一份 z-order，所以只能事后提）。
pub impl @moonui.Backend for LibuiBackend with fn raise_widget(self, child) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_control_raise(child)
}

///|
/// 剪贴板（§48-19）接上了：`adapter.h` 两条入口，两份 C 各实现一遍，MoonBit 侧只
/// 多两个 ffi wrapper——`Backend` 契约一个字没改，这正是 §47 要的"分叉只到 C 为止"。
///
/// 读路径没有错误码（"现在没有文本"和"暂时打不开"对调用方是同一个回答），写路径
/// 有，两个负数码在 `native_clipboard_set_text` 变成 `OperationFailed`。
pub impl @moonui.Backend for LibuiBackend with fn clipboard_text(self) -> String? raise @moonui.UiError {
  self.check_initialized()
  native_clipboard_text()
}

///|
pub impl @moonui.Backend for LibuiBackend with fn set_clipboard_text(self, text) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_clipboard_set_text(text)
}

///|
/// 对话框与文件选择（§48-18）都接上了，走的还是 `T18` 定的 (a)：分叉留在 C。
/// `adapter.h` 里每条一对入口（文件面板是三条 + 一条结果 getter），Cocoa 弹
/// `NSAlert` / `NSOpenPanel` / `NSSavePanel`，Win32 弹 `MessageBoxW` / `IFileDialog`，
/// MoonBit 侧只有几个 wrapper。这里不掺平台判断，也不解释"为什么不用 libui 的
/// `uiMsgBox` / `uiOpenFile` / `uiSaveFile`"——那答案在 ABI 头里，一句话版是前者的
/// 选择吞在返回值缺失里，后者把取消和失败并成同一个 NULL，而 §24 契约要它们分开。
///
/// 剩下 §48 的第 20 步（菜单栏）也接上了，形状一样，见下面 `set_menu_bar` 那一段。
///
/// 文案不带平台名字。这份实现同时**是** Cocoa 后端的实现（`backends/libui-macos`
/// 直接导入本包，它自己的目录里没有 backend.mbt），所以任何一句 Win32 的话都会
/// 原样抛到 mac 上。平台分叉一律留在 C 里，MoonBit 这一份两边共用（`T18` 的方案 (a)）。
pub impl @moonui.Backend for LibuiBackend with fn show_message(
  self,
  title,
  text,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_dialog_message(title, text)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn confirm(self, title, text) -> Bool raise @moonui.UiError {
  self.check_initialized()
  native_dialog_confirm(title, text)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn open_file(self, title) -> String? raise @moonui.UiError {
  self.check_initialized()
  native_open_file(title)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn save_file(
  self,
  title,
  default_name,
) -> String? raise @moonui.UiError {
  self.check_initialized()
  native_save_file(title, default_name)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn select_folder(self, title) -> String? raise @moonui.UiError {
  self.check_initialized()
  native_select_folder(title)
}

///|
/// 菜单栏（§48-20）接上了，走的还是 `T18` 定的 (a)：MoonBit 侧只把 Core 那棵树打包成
/// 一段字节（`ffi.mbt` 的 `menu_tree`，布局写在 `adapter.h`），两份 C 各自把它换成
/// 原生菜单——Cocoa 往进程主菜单追加 `NSMenu`，Win32 给每个活窗口建一份自己的 `HMENU`。
/// 为什么不用 libui 自己的菜单 API，理由全在 ABI 头里；一句话版是 mac 上建过窗口之后再
/// 装菜单会当场终止进程，Windows 上不认识的命令 id 会让 libui `DebugBreak`。
///
/// 点击通过回调回流成 `MenuSelect`，Core 不轮询菜单状态；勾选态则是反方向，由 Core 在
/// 每次点击之后推给后端（下面那条）。
pub impl @moonui.Backend for LibuiBackend with fn set_menu_bar(self, bar) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_set_menu_bar(bar, fn(id) {
    self.push(@moonui.MenuSelect(@moonui.EventTarget::{ id, }))
  })
}

///|
/// 把 Core 刚改掉的勾选态推给当下那棵原生菜单。为什么是"推"而不是后端自己回读，见
/// `Backend::set_menu_item_checked` 的契约（§25）：libui 的菜单项没有可靠的读回接口，
/// mac 那份连入参都不看，只看当前态翻一下。
///
/// Radio 会连着整组一起推过来（互斥是 Core 算的，被取消勾选的那些兄弟同样得改外观），
/// 所以这里是一项一次，不做任何分组判断。id 不在已装的树里时报 `OperationFailed`：
/// 装菜单和推状态读的是同一棵树，对上正确安装过的菜单栏就不该失败，真失败说明调用方
/// 手里的 id 过期了。
pub impl @moonui.Backend for LibuiBackend with fn set_menu_item_checked(
  self,
  id,
  checked,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_menu_item_set_checked(id, checked)
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
  set_menu_item_checked,
}
