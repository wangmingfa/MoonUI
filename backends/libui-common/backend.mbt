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
/// 剪贴板、对话框与文件面板、菜单栏（§48 的第 13/16/18/19/20 步）、键盘与焦点、鼠标
/// 与滚动（`T39`）、系统外观的读数（`T40`）、缩放的**变化**（`T24`，§48 第 21 步，
/// 接的是轮询而不是原生监听，理由写在 `refresh_scale`）、按窗口取的屏幕工作区
/// （`T42`，§12 的居中那一个消费者）、系统主题的**变化**（`T48`，和 `T24` 一样
/// 走轮询，理由写在 `refresh_theme`）都已经接上，两份 C 各实现一遍。剩下的缺口
/// 是鼠标那两档还没人认领的：落在空白处的事件（§32 的 focused 由点击驱动在
/// `T41`）和没按住键的纯光标移动（mac 要 `acceptsMouseMovedEvents`，理由写在
/// `push_mouse` 指向的那一节），hover/leave 跟着它们一起做。

///|
pub struct LibuiBackend {
  mut queue : Array[@moonui.Event]
  mut live_windows : Array[@moonui.NativeHandle]
  mut live_widgets : Array[@moonui.NativeHandle]
  /// 上一圈事件循环问到的焦点：`(窗口, 这只窗口当下的焦点控件)`。
  /// 只在 `refresh_focus` 里读写，整表按 `live_windows` 重建，所以销毁的窗口
  /// 不会在这里留下一条旧焦点被当成"丢了焦点"（§32）。
  mut focus_of : Array[(@moonui.NativeHandle, @moonui.NativeHandle?)]
  /// 上一圈事件循环问到的 DPI：`(窗口, 这只窗口当下所在屏的 DPI)`，`-1` = 这一圈
  /// 没读到（或第一次看到这只窗口）。只在 `refresh_scale` 里读写，整表按
  /// `live_windows` 重建，所以销毁的窗口不会在这里留下一条旧读数被当成"缩放变了"。
  mut dpi_of : Array[(@moonui.NativeHandle, Int32)]
  /// 上一圈问到的系统主题（`true` = 深色）。`None` = 还没读到过（第一次读到
  /// 不算变化，见 `refresh_theme`）。`init` 时清零，跨次复用同一后端实例
  /// 不会把上一轮的读数当成"这轮的主题变了"。
  mut theme_dark : Bool?
  /// `poll_event` 的等待预算，毫秒；`-1` = 一直等到有事件为止（产品语义：
  /// 一个空闲的 GUI 不该自己退出）。测试用 `for_testing` 换成有限值，
  /// 消息真丢了就是测试失败，而不是一个挂死的 CI。
  mut wait_budget_ms : Int32
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
    dpi_of: [],
    theme_dark: None,
    wait_budget_ms: -1,
    loop_ended: false,
    initialized: false,
  }
}

///|
/// 测试用后端：空转最多 `budget_ms` 毫秒就不再等事件。
/// 取 3000 是因为真窗口的消息投递在慢机器上也要不到 100ms，
/// 超了就是链路断了，应该红而不是等。
pub fn LibuiBackend::for_testing(budget_ms : Int32) -> LibuiBackend {
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
/// 而 §30 的换算只认当下这一块屏。（`refresh_scale` 那张表只用来发现变化，
/// 换算路径一次也不读它。）
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
    self.push(@moonui.Resize(@moonui.EventTarget::of(h), size))
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
    self.push(@moonui.Input(@moonui.EventTarget::of(h), text))
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
            @moonui.KeyDown(@moonui.EventTarget::of(t), kp)
          } else {
            @moonui.KeyUp(@moonui.EventTarget::of(t), kp)
          },
        )
      }
  }
}

///|
/// button 序号 → `@moonui.MouseButton`。序号就是 `MouseButton` 的声明顺序（adapter.h
/// 把这条定成了 ABI 的一部分），越界在 `push_mouse` 那一道检查里已经丢了，这里的
/// 最后一个分支只是让 match 穷尽。
fn mouse_button(n : Int32) -> @moonui.MouseButton {
  match n {
    0 => @moonui.MouseButton::Left
    1 => @moonui.MouseButton::Right
    2 => @moonui.MouseButton::Middle
    3 => @moonui.MouseButton::Extra1
    _ => @moonui.MouseButton::Extra2
  }
}

///|
/// 把"有颗鼠标出事了"翻译成 MouseDown/MouseUp/MouseMove/DoubleClick/Scroll
/// （§10 的鼠标五变体，`T39` 的鼠标那半）。
/// 和 push_key 同一个形状：通知不带内容，打在谁身上、哪一档、落在哪儿、滚多少
/// 四样都要当场读回去（§48-16）。
///
/// 两种丢弃都是"这条不归本框架管"，不是错误：编码越界（kind 或 button 出了 adapter.h
/// 那套打包）说明 C 与这里对不上，宁可不发也不猜；target 反查不到句柄说明落在空白处
/// 或原生层的辅助 view 那里——这里不猜"那应该是窗口自己吧"，猜了 Core 就会收到一条
/// 打在窗口上的假鼠标事件，而 §32 的 focused 改由点击驱动是 `T41` 那一格的事。
/// 读 Scale 失败也丢，理由同 `push_resize`（§12：只可能在窗口正在被拆掉时撞上失效句柄）。
///
/// 两个坐标口径不一样，这一格最容易写错，adapter.h 说的负控制钉的就是它：pos 是
/// **物理像素**，要在这里除以命中那只控件的 Scale（§30 全框架只允许的那一处换算，
/// 控件那一档的现读入口正是 `scale_of_widget`）；Scroll 的增量 C 侧**已经**换算完
/// （用的那几个数只在各自平台存在），这里一次也不除——再除一次就成了"同一个换算写两遍"。
///
/// `Click` 不在这里产生：它还是 libui 自己的 `uiButtonOnClicked` 发的，所以一次真双击
/// 在 Core 看到的是 MouseDown、Click、DoubleClick、Click。抬起那一颗在两侧不等价
/// （mac 的本地监听被自跑控件的 tracking loop 绕过，Windows 的钩子看不见这个差别），
/// 各自的形状由各自那条测试钉，见 adapter.h 的「鼠标与滚动」那一节。
fn LibuiBackend::push_mouse(self : LibuiBackend) -> Unit {
  let code = native_mouse_kind_button()
  let kind = code / 8
  let button = code % 8
  match native_mouse_target() {
    None => ()
    Some(t) =>
      if code >= 0 && kind <= 4 && button <= 4 {
        let target = @moonui.EventTarget::of(t)
        match kind {
          4 => {
            let (dx, dy) = native_mouse_delta()
            self.push(
              @moonui.Scroll(
                target,
                @moonui.LogicalPoint(dx.to_double(), dy.to_double()),
              ),
            )
          }
          3 => self.push(@moonui.DoubleClick(target))
          _ =>
            try {
              let (px, py) = native_mouse_pos()
              let p = scale_of_widget(t).to_logical_point(
                @moonui.PhysicalPoint(px, py),
              )
              self.push(
                match kind {
                  0 => @moonui.MouseDown(target, mouse_button(button), p)
                  1 => @moonui.MouseUp(target, mouse_button(button), p)
                  _ => @moonui.MouseMove(target, p)
                },
              )
            } catch {
              _ => ()
            }
        }
      }
  }
}

///|
/// 缩放轮询（§30、§48 第 21 步，`T24`）：每圈事件循环把每只存活窗口的 DPI 现读
/// 一次，和上一圈比，变了才发一条 `ScaleChanged`。
///
/// 为什么不装原生监听（`T24` 原来记的那条顾虑）：mac 的触发点是
/// `viewDidChangeBackingProperties`，而那只 view 是 libui 自己建的，我们没有地方
/// 插进去；Windows 的对应物是 `WM_DPICHANGED`，得子类化 libui 自己的窗口过程。
/// 两条都要动 ABI 加两份 C，而 DPI 本来就是一个现读就够的数（`scale_of_window`
/// 为了同一个理由一直现读），所以这里走 `refresh_focus` 那套已经验证过的形状：
/// 一圈问一次、去重在 MoonBit 侧、延迟上界是 `wait_slice_ms`（一帧之内）。
///
/// 两种不发事件的情况，都是"那条会是假的"：
/// - 第一次看到某只窗口（表里没有它）：`create_window` 已经按落地屏的 DPI 纠正过
///   一次尺寸，那是创建而不是变化；
/// - 这一圈或上一圈没读到（哨兵 `-1`）：读失败只可能在窗口正在被拆掉时撞上失效句柄
///   （§12，理由同 `push_resize`）。上一圈失败、这一圈成功也不补发——那只窗口要么
///   已经没了，要么句柄号被复用成了别的窗口（`T49` 记着 id 复用这件事），两种情况下
///   补的那条都不是"缩放变了"。
/// 哨兵不会和真读数撞上：两份 C 都保证 DPI > 0（mac 用 `llround(scale*96)`，
/// Windows 那侧有显式回落），所以 `-1` 只可能是"没读到"。
fn LibuiBackend::refresh_scale(self : LibuiBackend) -> Unit {
  let now : Array[(@moonui.NativeHandle, Int32)] = []
  for w in self.live_windows {
    let dpi = native_window_dpi(w) catch { _ => -1 }
    let mut before = -1
    for entry in self.dpi_of {
      if entry.0 == w {
        before = entry.1
      }
    }
    now.push((w, dpi))
    if dpi >= 0 && before >= 0 && dpi != before {
      self.push(
        @moonui.ScaleChanged(
          @moonui.EventTarget::of(w),
          @moonui.Scale::of_dpi(dpi.to_double()),
        ),
      )
    }
  }
  self.dpi_of = now
}

///|
/// 主题轮询（§16、`T48`）：每圈事件循环把系统主题现读一次，和上一圈比，
/// 变了才给每只存活窗口发一条 `ThemeChanged`（主题是进程级的，但派发路由按
/// 句柄走，一只窗口一条；App 那一侧收到后给目标窗口重算 `style_base`）。
///
/// 为什么和 `refresh_scale` 一样走轮询而不是原生监听：mac 那条
/// `AppleInterfaceThemeChangedNotification` 是 `NSDistributedNotificationCenter`
/// 的，十几行就够；Windows 的 `WM_SETTINGCHANGE` 只发给顶层窗口，得先立一只
/// 收广播的隐藏窗口（`uiInit` 之后建、`uiUninit` 之前拆）——两侧不是同一种
/// 便宜，先做贵的那半会让"Windows 未实现"占一个 ABI 码。而系统主题本来就是一个
/// 现读就够的数（`T40` 已经把 `system_theme` 接通），一圈问一次、延迟上界
/// `wait_slice_ms`（一帧之内），两侧同一份代码。
///
/// 第一次读到不算变化，和 `refresh_scale` 同一条理由：那是启动不是切换。
/// 读数没有失败态（两份 C 都保证"读不到当浅色"），所以这里没有哨兵分支。
fn LibuiBackend::refresh_theme(self : LibuiBackend) -> Unit {
  let dark = native_system_theme_is_dark()
  match self.theme_dark {
    None => self.theme_dark = Some(dark)
    Some(before) =>
      if dark != before {
        self.theme_dark = Some(dark)
        let t = if dark { @moonui.Dark } else { @moonui.Light }
        for w in self.live_windows {
          self.push(@moonui.ThemeChanged(@moonui.EventTarget::of(w), t))
        }
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
        Some(c) => self.push(@moonui.Blur(@moonui.EventTarget::of(c)))
        None => ()
      }
      match cur {
        Some(c) => self.push(@moonui.Focus(@moonui.EventTarget::of(c)))
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
  // 键盘与鼠标是进程级各一条监听，不占窗口/控件的槽位账（`T39`：实测一份 96 的表在
  // "每窗 2 条 + 每控件 ≤1 条 + 全局 2 条"下够用，所以这里没有分池的前提；鼠标这一条
  // 之所以也不用按控件数乘，是因为命中靠坐标反查而不是逐控件挂监听）。
  // 装不上就是槽位满了，init 必须带原因失败，而不是留一条"以后按键永远不响"的绿。
  native_on_key(fn() { self.push_key() })
  native_on_mouse(fn() { self.push_mouse() })
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
  self.dpi_of = []
  self.theme_dark = None
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
/// 原生控件后端的重绘是系统的事（`T31`）：窗口脏了系统自己会画，这条对它没有
/// 意义，所以是空操作。自绘后端（§51 的 Backend #2）才会真正用到它。
pub impl @moonui.Backend for LibuiBackend with fn request_redraw(self, _h) -> Unit raise @moonui.UiError {
  self.check_initialized()
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
    // 每圈先问一次焦点（`T39`）与缩放（`T24`）：轮询出来的事件进队列后先于新消息
    // 被取走，所以"程序改焦点 → 恰好一条 Focus""窗口换屏 → 恰好一条 ScaleChanged"
    // 这两条判据都不依赖后面有没有别的消息。
    self.refresh_focus()
    self.refresh_scale()
    self.refresh_theme()
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
  let target = @moonui.EventTarget::of(h)
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
  scale_of_window(h).to_logical_size(@moonui.PhysicalSize(w, height))
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
  @moonui.Scale::of_dpi(native_system_dpi().to_double()).to_logical_size(
    @moonui.PhysicalSize(w, height),
  )
}

///|
/// 这只窗口当下所在那块屏的工作区（`T42`）。上面那条只能量主屏（mac 的
/// `NSScreen.mainScreen`、Win32 的 `SPI_GETWORKAREA` 按定义都是主屏），所以副屏上的
/// 窗口用它的数会拿到别人的矩形——`Window::center` 就是这么把副屏上的窗口摆回主屏的。
///
/// 换算基准是**这只窗口自己的** Scale（`scale_of_window`），不是进程 DPI：C 侧那两条
/// 入口乘的就是同一个数（见两份 C 的 `moonui_window_screen_*`），所以逻辑值往返自逆；
/// 用进程 DPI 的话，窗口在倍数 1.0 的副屏上时会拿主屏的 2.0 去除，读回来的矩形正好差
/// 一倍——那正是 `T24` 之前 `screen_size` 在这台双屏机器上的错。
///
/// 原点不夹零、也不和上面那条比：坐标空间是本后端摆位那两条入口的空间，两个平台本身
/// 不同（mac 的 y 恒 0，Win32 是虚拟屏幕绝对坐标，可能为负）。理由写在 `adapter.h`。
pub impl @moonui.Backend for LibuiBackend with fn window_work_area(self, h) -> @moonui.LogicalRect raise @moonui.UiError {
  self.check_initialized()
  let scale = scale_of_window(h)
  let (x, y) = native_window_screen_origin(h)
  let (w, height) = native_window_screen_size(h)
  @moonui.LogicalRect(
    scale.to_logical_point(@moonui.PhysicalPoint(x, y)),
    scale.to_logical_size(@moonui.PhysicalSize(w, height)),
  )
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
  scale_of_window(h).to_logical_point(@moonui.PhysicalPoint(x, y))
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
pub impl @moonui.Backend for LibuiBackend with fn set_window_titlebar_style(
  self,
  h,
  style,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_set_titlebar_style(h, style)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn set_window_traffic_light_position(
  self,
  h,
  p,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  let phys = scale_of_window(h).to_physical_point(p)
  native_window_set_traffic_light_position(h, phys.x, phys.y)
}

///|
/// 所有控件都在这里落成句柄并装好回调。构造入口按 kind 分派：
/// Label/Button/TextInput/Checkbox/PasswordInput/Separator 走
/// `native_widget_new`（构造参数只有文案），Progress/ComboBox/RadioButtons/
/// MultilineEntry/DatePicker 走各自的专属入口（C 侧要按具体 libui 类型建），
/// Slider/Spinbox 不进这里——它们的范围是构造参数，见 `create_ranged_widget`。
///
/// 回调与 §48-16 的形状一致：通知不带内容，值/文本由 MoonBit 回读。翻译全是
/// §10 的既有事件：点击=Click、文本=Input、其余一切"状态变了"=Change，
/// 这批新控件没有引入任何新事件变体。
pub impl @moonui.Backend for LibuiBackend with fn create_widget(
  self,
  kind,
  text,
) -> @moonui.NativeHandle raise @moonui.UiError {
  self.check_initialized()
  let h = match kind {
    @moonui.Progress => native_progress_new()
    @moonui.ComboBox => native_combobox_new()
    @moonui.RadioButtons => native_radio_new()
    @moonui.MultilineEntry => {
      // 构造入口不带文案，建完按通用文本通道补填（C 侧按控件类分派）。
      let h = native_multiline_new()
      if text != "" {
        native_widget_set_text(h, text)
      }
      h
    }
    @moonui.DatePicker => native_datepicker_new()
    @moonui.Slider | @moonui.Spinbox =>
      raise @moonui.Unsupported("Slider / Spinbox 走 create_ranged_widget")
    _ => native_widget_new(kind, text)
  }
  let target = @moonui.EventTarget::of(h)
  match kind {
    @moonui.Button | @moonui.MenuRow =>
      native_widget_on_click(h, fn() {
        self.push(@moonui.Click(target, @moonui.Left))
      })
    @moonui.TextInput | @moonui.PasswordInput =>
      native_widget_on_text_changed(h, fn() { self.push_input(h) })
    @moonui.Checkbox =>
      native_widget_on_toggled(h, fn() { self.push(@moonui.Change(target)) })
    @moonui.Slider =>
      native_slider_on_changed(h, fn() { self.push(@moonui.Change(target)) })
    @moonui.Spinbox =>
      native_spinbox_on_changed(h, fn() { self.push(@moonui.Change(target)) })
    @moonui.ComboBox =>
      native_combobox_on_selected(h, fn() { self.push(@moonui.Change(target)) })
    @moonui.RadioButtons =>
      native_radio_on_selected(h, fn() { self.push(@moonui.Change(target)) })
    @moonui.MultilineEntry =>
      native_multiline_on_changed(h, fn() { self.push_input(h) })
    @moonui.DatePicker =>
      native_datepicker_on_changed(h, fn() { self.push(@moonui.Change(target)) })
    _ => ()
  }
  self.live_widgets.push(h)
  h
}

///|
/// Slider / Spinbox：范围进构造器（libui 的 uiNewSlider/uiNewSpinbox），
/// 回调同上。初始值等于最小值，这是 libui 的行为，不是这里设的。
pub impl @moonui.Backend for LibuiBackend with fn create_ranged_widget(
  self,
  kind,
  min,
  max,
) -> @moonui.NativeHandle raise @moonui.UiError {
  self.check_initialized()
  let h = match kind {
    @moonui.Slider => native_slider_new(min, max)
    @moonui.Spinbox => native_spinbox_new(min, max)
    _ =>
      raise @moonui.Unsupported(
        "只有 Slider / Spinbox 走带范围的创建通道",
      )
  }
  let target = @moonui.EventTarget::of(h)
  match kind {
    @moonui.Slider =>
      native_slider_on_changed(h, fn() { self.push(@moonui.Change(target)) })
    _ =>
      native_spinbox_on_changed(h, fn() { self.push(@moonui.Change(target)) })
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
/// 数值属性。C 侧按控件的 libui 类型分派（uiSliderSetValue /
/// uiSpinboxSetValue / uiProgressBarSetValue），值域约定在 trait 注释里。
pub impl @moonui.Backend for LibuiBackend with fn set_widget_value(self, h, v) -> Unit raise @moonui.UiError {
  self.check_initialized()
  // C 侧那条入口自己按 libui 类型分派，三类控件共用一条 ABI。
  native_widget_set_value(h, v)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn widget_value(self, h) -> Int32 raise @moonui.UiError {
  self.check_initialized()
  native_widget_value(h)
}

///|
/// 只有 Slider 会真的走这条（Core 侧已按 kind 拦住其余）。
pub impl @moonui.Backend for LibuiBackend with fn set_widget_range(
  self,
  h,
  min,
  max,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_slider_set_range(h, min, max)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn append_widget_option(
  self,
  h,
  text,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_append_option(h, text)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn set_widget_selected(
  self,
  h,
  index,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_set_selected(h, index)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn widget_selected(self, h) -> Int32 raise @moonui.UiError {
  self.check_initialized()
  native_widget_selected(h)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn set_widget_datetime(
  self,
  h,
  text,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_datepicker_set_text(h, text)
}

///|
pub impl @moonui.Backend for LibuiBackend with fn widget_datetime(self, h) -> String raise @moonui.UiError {
  self.check_initialized()
  native_datepicker_text(h)
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
/// MenuRow 内边距的豁免（同 `set_widget_style` 的豁免，写在实现里）：libui 半
/// 的 MenuRow 是最小标准按钮形状（§51），绘制不消费 padding——测量账归 Core
/// （`to_layout_spec` 统一加固有尺寸），标准按钮自然充满长出来的矩形。接受
/// 不动作，不让 Core 侧的推空掉。
pub impl @moonui.Backend for LibuiBackend with fn set_widget_insets(
  self,
  _h,
  _insets,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
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
/// §32 的语义翻译（`T41`）：把 `Accessibility` 打包成 adapter.h 那条 ABI
/// （role 序号 + 两个 UTF-8 串 + state 位包）。Action 不在里面——执行通道
/// 要接原生回调，留到 Actions 那半。失败要 raise 而不是吞：这条挂在
/// `apply_styles` 里、relayout 的正中间，静默失败会把"读屏器看不见"藏成
/// 一个看不见的症状。
pub impl @moonui.Backend for LibuiBackend with fn set_widget_accessibility(
  self,
  h,
  a,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_set_widget_accessibility(
    h,
    access_role_code(a.role),
    a.label,
    a.description,
    access_state_code(a.state),
  )
}

///|
/// `AccessRole` → ABI 序号。顺序就是 `accessibility.mbt` 里的声明顺序，
/// 两份 C 按同一个序号翻成各自平台的角色——C 侧注释是同一份契约的另一半。
fn access_role_code(r : @moonui.AccessRole) -> Int32 {
  match r {
    Text => 0
    Button => 1
    CheckBox => 2
    TextBox => 3
    Group => 4
    List => 5
    ListItem => 6
    Window => 7
    SliderRole => 8
    ProgressRole => 9
  }
}

///|
/// `AccessState` → ABI 位包：bit0 = visible、bit1 = enabled、
/// bits2-3 = checked（0 = 无此态、1 = 未勾、2 = 已勾）。
fn access_state_code(st : @moonui.AccessState) -> Int32 {
  let base = (if st.visible { 1 } else { 0 }) + (if st.enabled { 2 } else { 0 })
  match st.checked {
    None => base
    Some(false) => base + 4
    Some(true) => base + 8
  }
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
  scale_of_widget(h).to_logical_rect(
    @moonui.PhysicalRect(
      @moonui.PhysicalPoint(x, y),
      @moonui.PhysicalSize(w, height),
    ),
  )
}

///|
/// 固有尺寸来自 libui 自己的最小尺寸（button 用 BCM_GETIDEALSIZE，label 用文本
/// extent），字体度量因此是原生层的，不是 Core 猜的（§18）。
pub impl @moonui.Backend for LibuiBackend with fn widget_intrinsic_size(self, h) -> @moonui.LogicalSize raise @moonui.UiError {
  self.check_initialized()
  let (w, height) = native_widget_minimum_size(h)
  scale_of_widget(h).to_logical_size(@moonui.PhysicalSize(w, height))
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
/// T74：挂进容器控件（目前只有滚动视口的文档区）。child 的矩形在 Core 侧
/// 已经平移成文档区坐标，C 侧只管挂接，不再动坐标。
pub impl @moonui.Backend for LibuiBackend with fn attach_widget_to(
  self,
  container,
  child,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_container_attach(container, child)
}

///|
/// T74：滚动视口的滚动行程。Core 只对 Scroll 调这里（`push_scroll_content`），
/// 逻辑尺寸按视口所在屏的缩放换成物理像素交给 adapter。Windows 半暂时只建
/// 剪裁容器、不出滚动条（真 Win32 滚动在 T75），这条行程先记账不生效。
pub impl @moonui.Backend for LibuiBackend with fn set_scroll_content(
  self,
  scroll,
  axis,
  size,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_scroll_set_content(scroll, axis, size)
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
/// 整窗绘画顺序（`T29`）：Core 给的是**从顶层到底层**的完整列表，原生层只有一份
/// z-order，所以把它翻译成 z-order——按**倒序**（从底层到顶层）逐个 `raise_widget`，
/// 后提的盖住先提的，提完顶层正好是列表第一个。不新增 C 入口：`raise_widget` 已经是
/// "提到最上层"，倒序提一遍就是整份重排。
pub impl @moonui.Backend for LibuiBackend with fn set_paint_order(
  self,
  window,
  order,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  let _w = window
  for i = order.length() - 1; i >= 0; i = i - 1 {
    native_control_raise(order[i])
  }
}

///|
/// 焦点链（`T29` 声明、`T66` 两侧都接上了）：Core 给的是声明顺序（`collect_native`
/// 的先序，含 Stack 的树里和 `set_paint_order` 的层叠序分道），后端把它存下来，Tab
/// 遍历按它走——Windows 侧在键盘钩子里拦下 VK_TAB 按链 SetFocus（§48-16）；mac 侧
/// 把声明序装进每只 view 的 nextKeyView 接成环，焦点与绘画层叠因此彻底解耦。
pub impl @moonui.Backend for LibuiBackend with fn set_focus_chain(
  self,
  window,
  chain,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_set_focus_chain(window, chain)
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
    self.push(@moonui.MenuSelect(@moonui.EventTarget::{ id, generation: 0, }))
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
/// 应用图标（§26）。C 侧按平台补扩展名（mac `.png` / Windows `.ico`），所以这里
/// 只把 stem 递下去。放在 `check_initialized` 之后：没初始化就设图标属于调用顺序
/// 错误，和其它后端方法一样按 §33 报出来而不是吞掉。
pub impl @moonui.Backend for LibuiBackend with fn set_app_icon(self, name) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_set_app_icon(name)
}

///|
/// 显式把 `Backend` 的方法开放为点号方法，避免依赖已标记为过时的隐式提升
/// （和 `MockBackend` 同一套写法）。
pub extend LibuiBackend with @moonui.Backend::{
  init,
  terminate,
  poll_event,
  request_redraw,
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
  destroy_widget,
  set_widget_text,
  widget_text,
  set_widget_checked,
  set_widget_insets,
  create_ranged_widget,
  set_widget_value,
  widget_value,
  set_widget_range,
  append_widget_option,
  set_widget_selected,
  widget_selected,
  set_widget_datetime,
  widget_datetime,
  widget_checked,
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
  attach_widget_to,
  set_scroll_content,
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
  set_app_icon,
}
