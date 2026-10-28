///|
/// 原生 Cocoa 后端（设计文档 §51 的 Backend #2，macOS 半）。
///
/// 这一层把 `Backend` 契约翻译成 `native_*` 那套物理像素调用，形状沿用
/// ../libui-common/backend.mbt（`T82` 删 libui）搬过来的那套，底下不经过中间
/// GUI 库——窗口、事件循环、回调全部直写 AppKit（见 adapter_native.m）。这是
/// §51 "libui-ng 只是第一个 Backend" 的正面落地：libui 那份之后，Core 里跑 Demo
/// 的那条泛型路径在这里换成一个真窗口、真事件循环，一行 Core 代码都不用改。
///
/// FP1 只把窗口 + 事件循环接通：`create_window`/`destroy_window`/`poll_event`/
/// 窗口属性那一批是真的，控件那一批（`create_widget` 起）暂时 raise
/// `Unsupported`——FP2 补控件时再换成真实现。

///|
pub struct NativeBackend {
  mut queue : Array[@moonui.Event]
  mut live_windows : Array[@moonui.NativeHandle]
  mut live_widgets : Array[@moonui.NativeHandle]
  /// `poll_event` 的等待预算，毫秒；`-1` = 一直等到有事件为止（产品语义：
  /// 一个空闲的 GUI 不该自己退出）。测试用 `for_testing` 换成有限值。
  mut wait_budget_ms : Int32
  /// 主循环已经结束（moonui_quit）。只有 `poll_event` 会置位。
  mut loop_ended : Bool
  mut initialized : Bool
  /// `T85②`：进程级组合事件源装上过没有。组合监听进程一份（adapter.h 的
  /// IME 段注），第一条文本控件创建时装上；后端收尾时 C 侧闭包随之松开，
  /// 这里同步复位，重建控件时重新装。
  mut ime_installed : Bool
  /// `T86①`：进程级鼠标监听装上过没有（右键事件源，adapter.h 的鼠标段注）。
  /// C 侧闭包随 terminate 松开，这里同步复位。
  mut mouse_installed : Bool
  /// `T86③`：进程级文件拖入监听装上过没有（第一期档案，mac 半）。装不上
  /// （Windows 半欠 IDropTarget）就静默缺席，不挡开窗。
  mut drag_installed : Bool
  /// `T100`：进程级触控板手势监听装上过没有（adapter.h 手势段）。mac 半真接，
  /// Windows 半恒 -1（欠 `WM_GESTURE` 那套子类化），装不上静默缺席。
  mut gesture_installed : Bool
  /// `T91`：进程级键盘监听装上过没有（adapter.h 键盘段注——KeyDown/KeyUp
  /// 的事件源 + Shift+Tab 回退接管）。C 侧闭包随 terminate 松开，这里同步
  /// 复位。
  mut key_installed : Bool
  /// `T91`：焦点账（§32 的"问而不报"）——每只窗口上次问到的焦点 owner
  /// 指针，0 = 焦点不在我们的控件上。每圈事件循环问一遍 `focused_control`，
  /// 变了才推 Focus/Blur，去重因此发生在这层。
  mut last_focus : Array[(Int64, Int64)]
  /// 皮肤账：最近一次 `set_theme_base` 推来的层叠起点。原生后端拿它做
  /// "继承 vs 显式"的分野——下发的样式字段与底同值视为继承（保原生外观），
  /// 不同值才是应用显式要的（破 §32 消费）。
  mut theme_base : @moonui.Style?
  /// 实时直达通道（live dispatch）：`App::new` 装 `fn(ev) { app.dispatch(ev) }`，
  /// `push_resize` / `push_move` 走实时路时同步交给它。None = 没人接，一切照旧入队。
  mut live_dispatch : ((@moonui.Event) -> Unit raise @moonui.UiError)?
  /// 拖拽改尺寸的实时重排开关（live redraw）的逐窗登记：**缺席 = 开**（默认
  /// 开，没登记过的窗口按开处理）。消费点在 `push_resize`。
  mut live_redraws : Array[(@moonui.NativeHandle, Bool)]
  /// 自定义绘制面（`T101`）的位图账：句柄 id → 那只控件专属的画布。一块面
  /// 一张画布，第一次绘制时惰性建（尺寸在那时才知道），销毁控件时跟着释放。
  /// 键用 `NativeHandle.id`（句柄表的代际号，销毁后不会与新建的撞）。
  mut custom_canvases : Array[(@moonui.NativeHandle, Canvas)]
  /// 自定义绘制面的登记（`T110`）：哪些句柄是"自绘面"。
  ///
  /// 为什么后端要自己记这一笔：左键的 `MouseDown` / `MouseUp`（带坐标）只对
  /// 自绘面翻译，原生控件那几支照旧不翻译——原生控件的左键消费者是控件回调
  /// 发的 `Click`，补上这两条会改变既有行为（长按识别账 `T86⑧` 也吃
  /// `MouseDown(Left)`，一并会动）。"是不是自绘面"这件事只有后端知道
  /// （`create_widget` 的 kind 是它自己收到的），C 侧的 kind 表在另一层，
  /// 不为这一条开口子。
  mut custom_faces : Array[@moonui.NativeHandle]
}

///|
pub fn NativeBackend::new() -> NativeBackend {
  NativeBackend::{
    queue: [],
    live_windows: [],
    live_widgets: [],
    wait_budget_ms: -1,
    loop_ended: false,
    initialized: false,
    ime_installed: false,
    mouse_installed: false,
    drag_installed: false,
    gesture_installed: false,
    key_installed: false,
    last_focus: [],
    theme_base: None,
    live_dispatch: None,
    live_redraws: [],
    custom_canvases: [],
    custom_faces: [],
  }
}

///|
/// 测试用后端：空转最多 `budget_ms` 毫秒就不再等事件。
pub fn NativeBackend::for_testing(budget_ms : Int32) -> NativeBackend {
  let b = NativeBackend::new()
  b.wait_budget_ms = budget_ms
  b
}

///|
/// 一轮 `poll_event` 里最多让原生队列空转这么久。8ms 是量出来的折中：
/// 比一帧（16ms）短，消息不会攒着；比直接忙等省，空闲时每秒只醒 125 次。
let wait_slice_ms = 8

///|
/// 帧钟（`T84`，零 C——帧钟是 MoonBit 侧 pump 的账）：动画激活期把
/// `poll_event` 的等待预算换成现成的 `wait_slice_ms` 8ms 档，让主循环每圈
/// 醒来、Core 的动画泵推进插值；退场恢复 -1（产品语义：空闲的 GUI 不自己
/// 退出）。由前台门接线（`packages/moonui-app`），沿 App 动画激活/退场的
/// 切换沿调用；无动画的产品路径一个字不碰它（`for_testing` 的测试预算也
/// 不受影响——真窗口测试里没有激活的动画）。
pub fn NativeBackend::set_frame_budget(
  self : NativeBackend,
  active : Bool,
) -> Unit {
  self.wait_budget_ms = if active { wait_slice_ms } else { -1 }
}

///|
fn NativeBackend::check_initialized(
  self : NativeBackend,
) -> Unit raise @moonui.UiError {
  if !self.initialized {
    raise @moonui.InitializationFailed("Backend 尚未初始化")
  }
}

///|
/// 窗口的裸指针（自绘后端专用，§52）：`moonui_canvas_attach_window` 要的是
/// C 侧的 NSWindow*，这条把 NativeHandle 换回去。只认窗口——控件指针对
/// 画布没有意义，混进来就该红。
pub fn NativeBackend::window_ptr(
  self : NativeBackend,
  h : @moonui.NativeHandle,
) -> Int64 raise @moonui.UiError {
  self.check_initialized()
  let is_window = self.live_windows.contains(h)
  if !is_window {
    raise @moonui.InvalidHandle
  }
  let resolved = handles.resolve(h) catch { _ => @moonui.NativePtr(0L) }
  resolved.0
}

///|
fn NativeBackend::push(self : NativeBackend, ev : @moonui.Event) -> Unit {
  self.queue.push(ev)
}

///|
fn NativeBackend::take(self : NativeBackend) -> @moonui.Event? {
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
/// `T85②`：组合 target 反查——adapter 报的是我们的控件指针，句柄表只认正向
/// （NativeHandle → 指针），进程级的组合相位一份，只能沿当下存活的控件线性
/// 扫一遍认人。键盘/鼠标监听不需要这一步（它们的回调逐控件闭包持有句柄）。
/// 指针不在表里（已销毁）返回 None，事件照 adapter.h 的契约丢弃。
fn NativeBackend::ime_target_widget(
  self : NativeBackend,
) -> @moonui.NativeHandle? {
  let ptr = native_ime_target()
  if ptr == 0L {
    return None
  }
  for w in self.live_widgets {
    let resolved = handles.resolve(w) catch { _ => @moonui.NativePtr(0L) }
    if resolved.0 == ptr {
      return Some(w)
    }
  }
  None
}

///|
/// `T86①`：指针反查——adapter 报的是我们的控件指针（mac 半 hitTest 后沿
/// owner 记号退出来的、Windows 半 ChildWindowFromPoint + 属性表退出来的），
/// 句柄表只认正向，进程级的鼠标监听一份，只能沿当下存活的控件线性扫认人。
/// 与 `ime_target_widget` 同形：指针不在表里（已销毁）返回 None，事件丢弃。
fn NativeBackend::mouse_target_widget(
  self : NativeBackend,
  ptr : Int64,
) -> @moonui.NativeHandle? {
  if ptr == 0L {
    return None
  }
  for w in self.live_widgets {
    let resolved = handles.resolve(w) catch { _ => @moonui.NativePtr(0L) }
    if resolved.0 == ptr {
      return Some(w)
    }
  }
  None
}

///|
/// `T91`：键归属的指针反查——键盘事件的归属可能是控件（焦点反查）也可能是
/// 窗口本身（焦点不在控件上时），两张表都扫：先控件后窗口。
fn NativeBackend::handle_of_ptr(
  self : NativeBackend,
  ptr : Int64,
) -> @moonui.NativeHandle? {
  if ptr == 0L {
    return None
  }
  match self.mouse_target_widget(ptr) {
    Some(h) => return Some(h)
    None => ()
  }
  for w in self.live_windows {
    let resolved = handles.resolve(w) catch { _ => @moonui.NativePtr(0L) }
    if resolved.0 == ptr {
      return Some(w)
    }
  }
  None
}

///|
/// `T91`：焦点账的问账（§32 的"问而不报"）——每圈事件循环对每只活窗口问一次
/// `focused_control`，变了才推 Focus/Blur。去重发生在这层：同一只控件连续
/// 几圈问出同一个 owner 不多推；程序自己改焦点也走同一条账。
fn NativeBackend::poll_focus(self : NativeBackend) -> Unit {
  let fresh : Array[(Int64, Int64)] = []
  for w in self.live_windows {
    let wptr = handles.resolve(w) catch { _ => @moonui.NativePtr(0L) }
    let cur = native_focused_control(w)
    let mut old = 0L
    for pair in self.last_focus {
      if pair.0 == wptr.0 {
        old = pair.1
        break
      }
    }
    if cur != old {
      // 先 Blur 后 Focus：焦点交接的顺序语义（§32）。
      if old != 0L {
        match self.handle_of_ptr(old) {
          Some(h) => self.push(@moonui.Blur(@moonui.EventTarget::of(h)))
          None => ()
        }
      }
      if cur != 0L {
        match self.handle_of_ptr(cur) {
          Some(h) => self.push(@moonui.Focus(@moonui.EventTarget::of(h)))
          None => ()
        }
      }
    }
    fresh.push((wptr.0, cur))
  }
  self.last_focus = fresh
}

///|
/// `T86③`：拖入命中的窗口指针反查——拖进的 destination 是窗口本身，扫的是
/// `live_windows`。同形于上面两条。
fn NativeBackend::drop_target_window(
  self : NativeBackend,
  ptr : Int64,
) -> @moonui.NativeHandle? {
  if ptr == 0L {
    return None
  }
  for w in self.live_windows {
    let resolved = handles.resolve(w) catch { _ => @moonui.NativePtr(0L) }
    if resolved.0 == ptr {
      return Some(w)
    }
  }
  None
}

///|
/// `T86①`/`T86⑥` 共用的选中语义（沿 `T22` 现账）：`MenuBar::click` 一条——
/// 勾选态改在 Core（Check 翻转、Radio 带组互斥），回调当场跑。这个闭包在
/// 弹窗/托盘菜单的同步嵌套循环里被 C 回调，异常跨 C 帧未定义（worker 同一条
/// 纪律），所以就地吞掉——菜单回调里的失败沿下一轮事件照常报，不在这里假装
/// 没发生过（与菜单栏的 MenuSelect 沿循环传出不同，`T86①` 落地注记）。
fn menu_click_semantics(bar : @moonui.MenuBar, id : Int32) -> Unit {
  try {
    match bar.click(id) {
      Some(_) => ()
      None => ()
    }
  } catch {
    _ => ()
  }
}

///|
/// 把"输入框里的字变了"翻译成 Input 事件。原生通知只说"变了"，内容要回过头去
/// 问原生控件（§48-16），所以这里读的是 `widget_text`。读文本要过句柄表，可能
/// 失败——失败就丢事件（§12）。
fn NativeBackend::push_input(
  self : NativeBackend,
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
/// 把"窗口客户区变了"翻译成 Resize 事件。两条路（live redraw）：
///
/// - **实时**（开关开 + 当下是用户拖拽会话 + 装了直达通道）：同步交给
///   `live_dispatch`——拖拽跑在系统模态循环里（mac 的窗口跟踪循环、Win32 的
///   sizing 循环），`App::step` 被泵卡住、队列排不动，走队列就得等松手才重排，
///   拖的过程内容不跟手。同步直达才能一拖一重排。处理器的失败就地吞掉：
///   原生回调栈上没有能把 `UiError` 传出去的路。
/// - **入队**（其余）：照旧排给 `poll_event`。拖拽期间攒下的旧报告**合并成最新
///   一份**——关掉实时的复杂应用要的是"松手后重排一次"，不是"松手后重排 N 次"。
///
/// 读尺寸要过句柄表，可能失败——失败就丢事件：这条回调只可能在窗口正在被
/// 拆掉的时候撞上失效句柄，而 Core 也不会派发给已经关掉的窗口（§12）。
fn NativeBackend::push_resize(
  self : NativeBackend,
  h : @moonui.NativeHandle,
) -> Unit {
  try {
    let size = self.window_size(h)
    let target = @moonui.EventTarget::of(h)
    let ev = @moonui.Resize(target, size)
    let mut live = false
    match self.live_dispatch {
      Some(f) =>
        if self.live_redraw_on(h) && native_window_in_live_resize(h) {
          f(ev) catch {
            _ => ()
          }
          live = true
        }
      None => ()
    }
    if !live {
      let kept : Array[@moonui.Event] = []
      for e in self.queue {
        let stale = match e {
          @moonui.Resize(t, _) => t == target
          _ => false
        }
        if !stale {
          kept.push(e)
        }
      }
      self.queue = kept
      self.push(ev)
    }
  } catch {
    _ => ()
  }
}

///|
/// 把"窗口被拖到新位置"翻译成 Moved 事件。两条路（live dispatch，与
/// `push_resize` 同款结构）：
///
/// - **实时**（装了直达通道）：同步交给 `live_dispatch`——拖拽跑在系统模态
///   循环里（mac 的窗口跟踪循环、Win32 的 sizing 循环），`App::step` 被泵卡住、
///   队列排不动，走队列就得等松手吸附联动（`App::follow_move`）才追上邻居，
///   那正是"拖的时候其它窗延迟跟"。同步直达才能一拖一跟、与被拖窗同一拍。
///   处理器的失败就地吞掉：原生回调栈上没有能把 `UiError` 传出去的路。
/// - **入队**（没装，裸后端）：照旧排给 `poll_event`，同窗旧 Moved 合并成
///   最新一份——松手后一次性追上。
///
/// 门比 `push_resize` 窄两处，都是语义使然：
///
/// - 不看 `live_redraw`：那只开关管"拖拽改尺寸时**内容**跟不跟手"（重排有
///   开销）；Moved 不重排内容，跟手的是吸附联动，联动自己有 `set_dock_enabled`。
/// - 不看 `native_window_in_live_resize`：Resize 要把"非拖拽会话的尺寸报告"
///   （程序化 set_size 之外的系统改尺寸）挡在实时路外；Moved 没有这个问题
///   ——程序化移动的回声被原生层抑制掉（`suppress_move` / `inhibit`），回调里的
///   Moved 必是用户拖动。且 mac 的 `inLiveResize` 在**拖标题**时不置位（那不是
///   resize 会话），拿它当门正好把要修的场景挡在门外。
///
/// 读位置要过句柄表，可能失败——失败就丢事件（§12，失效句柄只可能在窗口
/// 正在被拆时撞上）。
fn NativeBackend::push_move(
  self : NativeBackend,
  h : @moonui.NativeHandle,
) -> Unit {
  try {
    let point = self.window_position(h)
    let target = @moonui.EventTarget::of(h)
    let ev = @moonui.Moved(target, point)
    let mut live = false
    match self.live_dispatch {
      Some(f) => {
        f(ev) catch {
          _ => ()
        }
        live = true
      }
      None => ()
    }
    if !live {
      let kept : Array[@moonui.Event] = []
      for e in self.queue {
        let stale = match e {
          @moonui.Moved(t, _) => t == target
          _ => false
        }
        if !stale {
          kept.push(e)
        }
      }
      self.queue = kept
      self.push(ev)
    }
  } catch {
    _ => ()
  }
}

///|
/// 实时重排开关的读数（缺席 = 开，与 trait 段注的默认同一条）。
fn NativeBackend::live_redraw_on(
  self : NativeBackend,
  h : @moonui.NativeHandle,
) -> Bool {
  for e in self.live_redraws {
    if e.0 == h {
      return e.1
    }
  }
  true
}

///|
/// 读回实时重排开关（测试对账用；缺席按开报）。
pub fn NativeBackend::window_live_redraw(
  self : NativeBackend,
  h : @moonui.NativeHandle,
) -> Bool {
  self.live_redraw_on(h)
}

///|
fn NativeBackend::drop_handle(
  self : NativeBackend,
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
    // 实时重排的登记一并清（缺席 = 开，留着旧条目只是白占）
    let kept_live : Array[(@moonui.NativeHandle, Bool)] = []
    for e in self.live_redraws {
      if e.0 != h {
        kept_live.push(e)
      }
    }
    self.live_redraws = kept_live
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
/// `T110`：这只句柄是不是自定义绘制面。
///
/// 登记表在 `create_widget` 里按 kind 记（只有 `@moonui.Custom` 那一条），
/// 销毁时销掉——句柄表会复用 id，所以销账得跟销毁同步，否则一块销毁掉的面
/// 会让后来新建的控件"继承"自绘面身份，左键翻译就落到它头上。
fn NativeBackend::is_custom_face(
  self : NativeBackend,
  h : @moonui.NativeHandle,
) -> Bool {
  for w in self.custom_faces {
    if w == h {
      return true
    }
  }
  false
}

///|
/// 记一笔"这只控件是自定义绘制面"（`T110`）。只登记一次——同一只控件重复
/// 建不会（句柄表给的是新 id），但多记一笔也不致命，判定用的是"在不在表里"。
fn NativeBackend::mark_custom_face(
  self : NativeBackend,
  h : @moonui.NativeHandle,
) -> Unit {
  if !self.is_custom_face(h) {
    self.custom_faces.push(h)
  }
}

///|
/// 销掉一笔自绘面登记（`T110`）。销毁控件时同步做。
fn NativeBackend::unmark_custom_face(
  self : NativeBackend,
  h : @moonui.NativeHandle,
) -> Unit {
  let kept : Array[@moonui.NativeHandle] = []
  for w in self.custom_faces {
    if w != h {
      kept.push(w)
    }
  }
  self.custom_faces = kept
}

///|
pub impl @moonui.Backend for NativeBackend with fn init(self) -> Unit raise @moonui.UiError {
  native_init()
  // 循环开始前调一次：C 侧 finishLaunching，把 App 变成真正在跑的 App。
  native_main_steps()
  self.initialized = true
  self.loop_ended = false
}

///|
/// 收尾顺序是硬要求：先控件、后窗口，最后才是 `native_terminate`。控件的
/// NSView 挂在窗口的 contentView 上，窗口拆掉前必须先把它们摘干净（C 侧
/// `moonui_window_destroy` 的注释也这么要求）。
pub impl @moonui.Backend for NativeBackend with fn terminate(self) {
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
  // `T110`：自绘面登记随控件一起清空。
  self.custom_faces = []
  self.initialized = false
  self.loop_ended = false
  // `T85②`：C 侧的监听闭包随 terminate 松开，这里同步复位——重建控件时重新装。
  self.ime_installed = false
  // `T86①`/`T86③`：鼠标与文件拖入两份监听同一条形状（进程一份），同步复位。
  // 键盘同款（`T91`）；焦点账一并清零。
  self.mouse_installed = false
  self.drag_installed = false
  self.key_installed = false
  // `T100`：手势监听同一条形状（进程一份，C 侧闭包随 terminate 松开）。
  self.gesture_installed = false
  self.last_focus = []
  native_terminate()
}

///|
/// 契约（app.mbt 开头）：真实后端的 `poll_event` 阻塞到有事件或循环结束，
/// 返回 `None` 只表示"循环结束"。这里的"循环结束"有两种：没有存活窗口了
/// （用户把窗口都关了），或者主循环被 `native_quit` 标成跑完了。
pub impl @moonui.Backend for NativeBackend with fn poll_event(self) -> @moonui.Event? {
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
/// 意义，所以是空操作。
pub impl @moonui.Backend for NativeBackend with fn request_redraw(self, _h) -> Unit raise @moonui.UiError {
  self.check_initialized()
}

///|
/// 推进原生消息循环，直到控件回调留下一个事件、循环结束，或等待预算用完。
///
/// 顺序是"先清队列、再等新消息"：`native_messages_pending` 把队列抽干，
/// `native_wait_messages` 只当有界睡眠用。
fn NativeBackend::pump(self : NativeBackend) -> @moonui.Event? {
  // `T91`：每圈先问一遍焦点（§32 的"问而不报"）——焦点变化推成 Focus/Blur
  // 进队列，下面的 take() 当场取走。
  self.poll_focus()
  // 预算按墙钟算：无限（产品）路径不看时钟，有限（测试）路径到点就返回。
  let deadline = native_time_ms() + self.wait_budget_ms
  let mut ev : @moonui.Event? = None
  while ev is None && !self.loop_ended {
    ev = self.take()
    if ev is None {
      if native_messages_pending() {
        // 只有循环结束会让这一步返回 false
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
pub impl @moonui.Backend for NativeBackend with fn create_window(
  self,
  title,
  size,
) -> @moonui.NativeHandle raise @moonui.UiError {
  self.check_initialized()
  // 窗口落在哪块屏要等 NSWindow 建出来才知道，所以先按进程 DPI 建，再按窗口
  // 自己的 DPI 纠正一次尺寸——§30 的"按监视器缩放"就落在这两行上。
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
  native_window_on_moved(h, fn() { self.push_move(h) })
  self.live_windows.push(h)
  // `T86①`/`T86③`：鼠标与文件拖入两份监听都是"进程一份、惰性装"——有窗口
  // 才会有右键和拖进，第一条窗口创建时装上（与组合监听的同形形状）。装不上
  // 就静默缺席（Windows 半的拖入源还没接，欠 IDropTarget；不挡开窗），
  // 复位在 terminate。
  if !self.mouse_installed {
    try {
      native_on_mouse(fn() {
        // 判定表在 `@native-abi.mouse_decision`（`T143`）；这个闭包只做三件
        // 后端独有的活：指针反查（句柄表在这里）、自绘面登记表、坐标换算
        // （要按**收件对象自己**的 DPI 除回去，判定表拿不到）。
        //
        // 反查一次算齐再判，而不是每支自己反查：`T141` 那类缺口就是"某一支
        // 没写自己的反查于是整条落空"，把反查提到判定之前，漏的是分支而不是
        // 整条事件路径。
        let kb = native_mouse_kind_button()
        let ptr = native_mouse_target()
        let target = self.mouse_target_widget(ptr)
        let window = self.drop_target_window(ptr)
        // owner 只在滚轮那一路、且命中没认出控件时才有用（`T102` 第十二刀：
        // mac 半的滚轮 target 恒报窗口，真正被滚到的控件走第二本账）。别的时候
        // 不扫——它沿存活控件线性反查，而移动是最高频的事件。哪几路要它，问
        // `@native-abi`，这层不说 kind 的数字。
        let owner = if target is None && @native-abi.needs_owner(kb) {
          self.mouse_target_widget(native_mouse_owner())
        } else {
          None
        }
        let target_is_custom = match target {
          Some(h) => self.is_custom_face(h)
          None => false
        }
        let owner_is_custom = match owner {
          Some(h) => self.is_custom_face(h)
          None => false
        }
        // 这个闭包被 C 在监听回调里调进来，raise 跨 C 帧未定义（worker 同一条
        // 纪律）——读 DPI 要过句柄表可能失败，失败就丢事件（§12）。
        match
          @native-abi.mouse_decision(
            kb, target, window, owner, target_is_custom, owner_is_custom,
          ) {
          @native-abi.MouseDecision::Drop => ()
          @native-abi.MouseDecision::MoveTo(h) =>
            try {
              // 悬停在控件上按控件问 DPI，在空白处报的是窗口、按窗口问——
              // 问错对象是真窗上的 NSException（window_dpi 打在 view 上）。
              let scale = match target {
                Some(_) => scale_of_widget(h)
                None => scale_of_window(h)
              }
              let (px, py) = native_mouse_pos()
              let point = scale.to_logical_point(@moonui.PhysicalPoint(px, py))
              self.push(@moonui.MouseMove(@moonui.EventTarget::of(h), point))
            } catch {
              _ => ()
            }
          @native-abi.MouseDecision::WheelTo(h) => {
            // 增量 C 侧已换成逻辑像素（`T98①`），不再除缩放。
            let (dx, dy) = native_mouse_delta()
            self.push(
              @moonui.Scroll(
                @moonui.EventTarget::of(h),
                @moonui.LogicalPoint(dx.to_double(), dy.to_double()),
              ),
            )
          }
          @native-abi.MouseDecision::DoubleTo(h) =>
            self.push(@moonui.DoubleClick(@moonui.EventTarget::of(h)))
          @native-abi.MouseDecision::PressTo(h, button) =>
            try {
              let (px, py) = native_mouse_pos()
              let point = scale_of_widget(h).to_logical_point(
                @moonui.PhysicalPoint(px, py),
              )
              self.push(
                @moonui.MouseDown(@moonui.EventTarget::of(h), button, point),
              )
            } catch {
              _ => ()
            }
          @native-abi.MouseDecision::ReleaseTo(h, button) =>
            try {
              let (px, py) = native_mouse_pos()
              let point = scale_of_widget(h).to_logical_point(
                @moonui.PhysicalPoint(px, py),
              )
              self.push(
                @moonui.MouseUp(@moonui.EventTarget::of(h), button, point),
              )
            } catch {
              _ => ()
            }
        }
      })
      self.mouse_installed = true
    } catch {
      _ => ()
    }
  }
  // `T91`：键盘监听同一条"进程一份、惰性装"的形状——有窗口才有键归属，
  // 第一条窗口创建时装上；装不上静默缺席（不挡开窗），复位在 terminate。
  if !self.key_installed {
    try {
      native_on_key(fn() {
        // 这个闭包被 C 在监听回调里调进来，raise 跨 C 帧未定义（worker
        // 同一条纪律）——反查与读回全是不 raise 的路径，事件原样入队。
        match self.handle_of_ptr(native_key_target()) {
          Some(h) => {
            let name = native_key_name()
            // 词表外的键不产事件（adapter.h 的词表契约）。
            if name != "" {
              let m = native_key_modifiers()
              let kp = @moonui.KeyPress::{
                key: name,
                ctrl: (m & 1) != 0,
                alt: (m & 2) != 0,
                shift: (m & 4) != 0,
                meta: (m & 8) != 0,
              }
              let target = @moonui.EventTarget::of(h)
              if native_key_is_down() {
                self.push(@moonui.KeyDown(target, kp))
              } else {
                self.push(@moonui.KeyUp(target, kp))
              }
            }
          }
          None => ()
        }
      })
      self.key_installed = true
    } catch {
      _ => ()
    }
  }
  if !self.drag_installed {
    try {
      native_on_file_drop(fn() {
        match self.drop_target_window(native_file_drop_target()) {
          Some(h) =>
            self.push(
              @moonui.FileDrop(
                @moonui.EventTarget::of(h),
                native_file_drop_paths(),
              ),
            )
          None => ()
        }
      })
      self.drag_installed = true
    } catch {
      _ => ()
    }
  }
  // `T100`：触控板手势同一条"进程一份、惰性装"的形状。mac 半真接，
  // Windows 半的 `on_gesture` 恒 -1（`WM_GESTURE` 要 SetGestureConfig 加
  // 逐窗口子类化，欠在那台机器上）——装不上就静默缺席，不挡开窗。
  //
  // 手势的 target 与滚轮同一套反查：落在控件上给控件、落在空白给窗口自己
  // （自绘半按 ptr 反查窗口，报控件会让它整条丢掉）。三样读回都是小整数
  // 编码，价量那一格是定点除回来的小数。
  if !self.gesture_installed {
    try {
      native_on_gesture(fn() {
        match self.handle_of_ptr(native_gesture_target()) {
          Some(h) => {
            let target = @moonui.EventTarget::of(h)
            let value = native_gesture_value()
            let gesture = match native_gesture_kind() {
              0 =>
                @moonui.Gesture::Magnify(
                  value,
                  @native-abi.gesture_phase(native_gesture_phase()),
                )
              1 =>
                @moonui.Gesture::Rotate(
                  value,
                  @native-abi.gesture_phase(native_gesture_phase()),
                )
              _ =>
                @moonui.Gesture::Swipe(
                  @native-abi.swipe_direction(native_gesture_direction()),
                )
            }
            self.push(@moonui.Gesture(target, gesture))
          }
          None => ()
        }
      })
      self.gesture_installed = true
    } catch {
      _ => ()
    }
  }
  h
}

///|
pub impl @moonui.Backend for NativeBackend with fn destroy_window(self, h) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_destroy(h)
  self.drop_handle(true, h)
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_window_title(
  self,
  h,
  title,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_set_title(h, title)
}

///|
/// `set_window_size` 设的是客户区尺寸——Core 的布局也正是按客户区算的（§14）。
pub impl @moonui.Backend for NativeBackend with fn set_window_size(
  self,
  h,
  size,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  let phys = scale_of_window(h).to_physical_size(size)
  native_window_set_content_size(h, phys.width, phys.height)
}

///|
pub impl @moonui.Backend for NativeBackend with fn window_size(self, h) -> @moonui.LogicalSize raise @moonui.UiError {
  self.check_initialized()
  let (w, height) = native_window_content_size(h)
  scale_of_window(h).to_logical_size(@moonui.PhysicalSize(w, height))
}

///|
/// 客户区最小尺寸下发（物理像素）。`None` 清成 (0, 0)——原生层把 0 当"没有
/// 限制"，两平台同一口径（mac 的 `contentMinSize` 本来就是零尺寸起步）。
pub impl @moonui.Backend for NativeBackend with fn set_window_min_size(
  self,
  h,
  size,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  match size {
    Some(s) => {
      let phys = scale_of_window(h).to_physical_size(s)
      native_window_set_min_size(h, phys.width, phys.height)
    }
    None => native_window_set_min_size(h, 0, 0)
  }
}

///|
/// 拖拽改尺寸的实时重排开关记账（live redraw）。**缺席 = 开**，只登记与默认
/// 不同的；消费点在 `push_resize`，拖拽检测走 `native_window_in_live_resize`。
pub impl @moonui.Backend for NativeBackend with fn set_window_live_redraw(
  self,
  h,
  on,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  let kept : Array[(@moonui.NativeHandle, Bool)] = []
  for e in self.live_redraws {
    if e.0 != h {
      kept.push(e)
    }
  }
  kept.push((h, on))
  self.live_redraws = kept
}

///|
/// 实时直达通道记账（live dispatch）。`App::new` 装的就是
/// `fn(ev) { app.dispatch(ev) }`；纯记账，不碰原生层，因此不查初始化。
pub impl @moonui.Backend for NativeBackend with fn set_live_dispatch(self, f) -> Unit {
  self.live_dispatch = f
}

///|
pub impl @moonui.Backend for NativeBackend with fn show_window(self, h) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_show(h)
}

///|
pub impl @moonui.Backend for NativeBackend with fn hide_window(self, h) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_hide(h)
}

///|
pub impl @moonui.Backend for NativeBackend with fn window_scale(self, h) -> @moonui.Scale raise @moonui.UiError {
  self.check_initialized()
  scale_of_window(h)
}

///|
/// 主屏工作区（不含任务栏）：`Window::center` 靠它，用整屏会把窗口摆到
/// 任务栏底下（§12）。换算基准只能用进程 DPI——这时还没有窗口可问。
pub impl @moonui.Backend for NativeBackend with fn screen_size(self) -> @moonui.LogicalSize raise @moonui.UiError {
  self.check_initialized()
  let (w, height) = native_screen_work_area()
  @moonui.Scale::of_dpi(native_system_dpi().to_double()).to_logical_size(
    @moonui.PhysicalSize(w, height),
  )
}

///|
/// 这只窗口当下所在那块屏的工作区（`T42`）。
pub impl @moonui.Backend for NativeBackend with fn window_work_area(self, h) -> @moonui.LogicalRect raise @moonui.UiError {
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
/// 系统外观（§16）。读不到就当浅色，不报错。
pub impl @moonui.Backend for NativeBackend with fn system_theme(self) -> @moonui.Theme raise @moonui.UiError {
  self.check_initialized()
  if native_system_theme_is_dark() {
    @moonui.Dark
  } else {
    @moonui.Light
  }
}

///|
/// 宿主平台（`@moonui.HostPlatform` 的段注）。值来自 C 侧的
/// `moonui_native_host_platform`——同一份 MoonBit 共享层被两个适配器各链一次，
/// 血统在这个符号上分叉，不在这里。认不出的返回值（将来加了新宿主而共享层没
/// 跟上）一律降级成 `Unknown`，不 panic：血统读数错了顶多是窗口钮多画一排，
/// 不该让整个应用起不来。
pub impl @moonui.Backend for NativeBackend with fn host_platform(self) -> @moonui.HostPlatform {
  let _ = self
  match native_host_platform() {
    1 => @moonui.Macos
    2 => @moonui.Windows
    _ => @moonui.Unknown
  }
}

///|
/// 进程级偏好读数（`T87`③ 减少动态效果）。快照式读当下偏好，不推送、不
/// 订阅（与 `window_state` 读回同一条纪律）。读不到就当关，不报错——上面
/// `system_theme` 的"读不到就当浅色"同一条绕行。
pub impl @moonui.Backend for NativeBackend with fn get_prefers_reduced_motion(
  self,
) -> Bool raise @moonui.UiError {
  self.check_initialized()
  native_prefers_reduced_motion()
}

///|
/// 进程级偏好读数（`T87`② 增强对比度）。首版只做读口；消费点（主题读数档）
/// 第二版接。绕行理由同上。
pub impl @moonui.Backend for NativeBackend with fn get_prefers_high_contrast(
  self,
) -> Bool raise @moonui.UiError {
  self.check_initialized()
  native_prefers_high_contrast()
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_window_position(
  self,
  h,
  origin,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  let p = scale_of_window(h).to_physical_point(origin)
  native_window_set_position(h, p.x, p.y)
}

///|
pub impl @moonui.Backend for NativeBackend with fn window_position(self, h) -> @moonui.LogicalPoint raise @moonui.UiError {
  self.check_initialized()
  let (x, y) = native_window_position(h)
  scale_of_window(h).to_logical_point(@moonui.PhysicalPoint(x, y))
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_window_resizable(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_set_resizable(h, v)
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_window_fullscreen(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_set_fullscreen(h, v)
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_window_titlebar_style(
  self,
  h,
  style,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_set_titlebar_style(h, style)
}

///|
/// 拖动带（`T116`）：收的是**逻辑像素**，按这只窗的 Scale 换成物理像素再下发
/// （`WM_NCHITTEST` 拿到的全是物理坐标，两套空间不能混）。
pub impl @moonui.Backend for NativeBackend with fn set_window_drag_band(
  self,
  h,
  height,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  let phys = scale_of_window(h).to_physical_size(
    @moonui.LogicalSize(height, 0.0),
  )
  native_window_set_drag_band(h, phys.width)
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_window_traffic_light_position(
  self,
  h,
  p,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  let phys = scale_of_window(h).to_physical_point(p)
  native_window_set_traffic_light_position(h, phys.x, phys.y)
}

///|
/// `T85②`/`T90④`：进程级组合事件源，第一条文本控件创建时装上（重复装只换回调，
/// adapter.h 的 IME 段注）。通知不带内容（§48-16），相位/target/组合串由读口
/// 当场取；target 反查不进句柄表（组合对象已销毁）就丢——悬垂组合命中死控件由
/// generation 自动挡住（`T49`/`T57` 继承到组合相位路径）。
///
/// 三类文本控件共用这一个入口：单行（TextInput）、密码（PasswordInput）、多行
/// （MultilineEntry）。后者的相位 `T90④` 才接上——之前只有前两类调这段，多行
/// 组合在 Core 侧一条事件都到不了。
fn NativeBackend::install_ime(
  self : NativeBackend,
) -> Unit raise @moonui.UiError {
  if self.ime_installed {
    return
  }
  native_on_ime(fn() {
    match self.ime_target_widget() {
      Some(w) => {
        let target = @moonui.EventTarget::of(w)
        match native_ime_phase() {
          0 => self.push(@moonui.ImeStart(target))
          1 => self.push(@moonui.ImeCompose(target, native_ime_text()))
          _ => self.push(@moonui.ImeEnd(target))
        }
      }
      None => ()
    }
  })
  self.ime_installed = true
}

///|
/// 所有控件都在这里落成句柄并装好回调。构造入口按 kind 分派：Label/Button/
/// TextInput/Checkbox/PasswordInput/Separator/VSeparator/MenuRow 走
/// `native_widget_new`（构造参数只有文案），Progress/ComboBox/RadioButtons/
/// MultilineEntry/DatePicker 走各自的专属入口（C 侧要按具体 NSView 子类建），
/// Slider/Spinbox 不进这里——它们的范围是构造参数，见 `create_ranged_widget`。
///
/// 回调与 §48-16 的形状一致：通知不带内容，值/文本由 MoonBit 回读。翻译全是
/// §10 的既有事件：点击=Click、文本=Input、其余一切"状态变了"=Change。
pub impl @moonui.Backend for NativeBackend with fn create_widget(
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
    @moonui.TextInput | @moonui.PasswordInput => {
      native_widget_on_text_changed(h, fn() { self.push_input(h) })
      self.install_ime()
    }
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
    @moonui.MultilineEntry => {
      native_multiline_on_changed(h, fn() { self.push_input(h) })
      // `T90④`：多行文本域也装组合事件源——两条 C 侧的接法同形（mac 认 kind 10
      // 的 NSTextView、Windows 把 ES_MULTILINE 的 EDIT 一起换子类过程），Core 这
      // 一侧只差"别漏装"。
      self.install_ime()
    }
    @moonui.DatePicker =>
      native_datepicker_on_changed(h, fn() { self.push(@moonui.Change(target)) })
    // 自定义绘制面（`T101`）：它没有原生 action 可借，点击由 C 侧那支 NSView
    // 子类在自己的 `mouseUp:` 里派发（按下并原地抬起才算一次，与 Button 的
    // 判定同一条），这里只装槽位。
    //
    // `T110`：另外记一笔"这只控件是自绘面"——左键的 `MouseDown` / `MouseUp`
    //（带坐标）只对它翻译，自绘面才知道点在哪。
    @moonui.Custom => {
      native_custom_on_click(h, fn() {
        self.push(@moonui.Click(target, @moonui.Left))
      })
      self.mark_custom_face(h)
    }
    _ => ()
  }
  self.live_widgets.push(h)
  h
}

///|
/// Slider / Spinbox：范围进构造器（NSSlider 的 minValue/maxValue、NSStepper 的
/// 同名字段），回调同上。初始值等于最小值。
pub impl @moonui.Backend for NativeBackend with fn create_ranged_widget(
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
pub impl @moonui.Backend for NativeBackend with fn destroy_widget(self, h) -> Unit raise @moonui.UiError {
  self.check_initialized()
  // 自定义绘制面的画布跟着控件走（`T101`）：先还画布再还视图——C 侧的
  // present 只把位图挂到 layer 上（layer 自己持一份 CGImage），与画布生死无关，
  // 但反过来（先毁视图、后毁画布）会让 `canvas_present_view` 的 window 指针
  // 变成悬垂，虽然那条路径只在绘制时走，秩序还是照因果来。
  self.drop_custom_canvas(h)
  native_widget_destroy(h)
  // `T110`：自绘面登记跟着销毁走——句柄表会复用 id，销晚了会让后来的控件
  // 继承自绘面身份，左键翻译就落到它头上。
  self.unmark_custom_face(h)
  self.drop_handle(false, h)
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_text(
  self,
  h,
  text,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_set_text(h, text)
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_text(self, h) -> String raise @moonui.UiError {
  self.check_initialized()
  native_widget_text(h)
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_checked(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_set_checked(h, v)
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_checked(self, h) -> Bool raise @moonui.UiError {
  self.check_initialized()
  native_widget_checked(h)
}

///|
/// 内边距推给绘制侧：口径同 `set_widget_bounds`——Core 发逻辑值，这里换物理
/// 像素再过 FFI（同一把 `scale_of_widget`，向上取整保证内容不被裁掉）。两个
/// LogicalSize 各带两维：start/top 进文字位置，end/bottom 进文字右缘。
pub impl @moonui.Backend for NativeBackend with fn set_widget_insets(self, h, v) -> Unit raise @moonui.UiError {
  self.check_initialized()
  let s = scale_of_widget(h)
  let st = s.to_physical_size(@moonui.LogicalSize(v.start, v.top))
  let eb = s.to_physical_size(@moonui.LogicalSize(v.end, v.bottom))
  native_widget_set_insets(h, st.height, eb.width, eb.height, st.width)
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_value(self, h, v) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_set_value(h, v)
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_value(self, h) -> Int32 raise @moonui.UiError {
  self.check_initialized()
  native_widget_value(h)
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_range(
  self,
  h,
  min,
  max,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_slider_set_range(h, min, max)
}

///|
pub impl @moonui.Backend for NativeBackend with fn append_widget_option(
  self,
  h,
  text,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_append_option(h, text)
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_selected(
  self,
  h,
  index,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_set_selected(h, index)
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_selected(self, h) -> Int32 raise @moonui.UiError {
  self.check_initialized()
  native_widget_selected(h)
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_datetime(
  self,
  h,
  text,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_datepicker_set_text(h, text)
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_datetime(self, h) -> String raise @moonui.UiError {
  self.check_initialized()
  native_datepicker_text(h)
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_visible(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_set_visible(h, v)
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_visible(self, h) -> Bool raise @moonui.UiError {
  self.check_initialized()
  native_widget_visible(h)
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_enabled(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_set_enabled(h, v)
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_enabled(self, h) -> Bool raise @moonui.UiError {
  self.check_initialized()
  native_widget_enabled(h)
}

///|
/// §32 的豁免在皮肤通道（adapter.h 的 widget_set_style 注）上定点破开：
/// Panel 画 layer 底+圆角，Label 换文字色与字体，Button 在显式给过时换
/// 文字色/平面底（见下面的"继承 vs 显式"闸门）。其余 kind 的样式仍不生效
/// （保系统原生外观的原规矩）。
///
/// 闸门：`theme_base`（`set_theme_base` 随每次重排先推）与生效样式逐字段比，
/// 同值视为继承（主题给的默认），不消费；不同值才是应用（或祖先样式）显式
/// 要的，才下发。没有底（还没重排过）时没有比较尺，全字段照下发——宁可
/// 多消费一次也不静默吞掉显式样式。
pub impl @moonui.Backend for NativeBackend with fn set_widget_style(
  self,
  h,
  style,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  let base_bg = match self.theme_base {
    Some(b) => b.background
    None => None
  }
  let base_fg = match self.theme_base {
    Some(b) => b.foreground
    None => None
  }
  let weight : Int32? = match style.font_weight {
    Some(Bold) => Some(2)
    // Medium 在 ABI 里与 Regular 同档（mac 侧注：AppKit 没有直接的
    // Medium 入口，mock 的 is_bold 判据也只认 Bold）
    Some(_) => Some(0)
    None => None
  }
  // 渐变底（§15）：原生皮肤通道只吃一个颜色，退到渐变中点色近似。要真
  // 渐变条带请用 `Widget::gradient_panel`（子控件铺色，四后端一致）。
  let effective_bg : @moonui.Color? = match style.background {
    Some(c) => Some(c)
    None =>
      match style.background_gradient {
        Some(g) => Some(g.midpoint())
        None => None
      }
  }
  native_widget_set_style(
    h,
    background=explicit_field(effective_bg, base_bg),
    foreground=explicit_field(style.foreground, base_fg),
    radius=style.radius,
    font_size=style.font_size,
    weight~,
  )
}

///|
/// "继承 vs 显式"的逐字段判据：与底同值 = 继承（None = 不消费），不同值 =
/// 显式（原值下发）。皮肤通道的闸门专用。
fn[T : Eq] explicit_field(v : T?, base : T?) -> T? {
  match v {
    Some(x) => if Some(x) == base { None } else { Some(x) }
    None => None
  }
}

///|
/// 主题底样式（皮肤账）：记下来做"继承 vs 显式"的比较尺。
pub impl @moonui.Backend for NativeBackend with fn set_theme_base(
  self,
  style : @moonui.Style,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  self.theme_base = Some(style)
}

///|
/// 图标（皮肤账）：转发给平台。mac 按 SF Symbols 名查表换成图像；Windows
/// 半自 `T131` 起按名字把矢量图形画在钮心（`play.fill` / `pause.fill` /
/// `stop.fill` / `backward.fill` / `forward.fill` / `repeat` / `repeat.1` /
/// `shuffle`），名字不认得的回退文本外观——与 mac "取不到 SF Symbol 就保
/// 标题"同一条。平台自己画的，不是这里吞掉的。
pub impl @moonui.Backend for NativeBackend with fn set_widget_icon(
  self,
  h,
  name : String,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_set_icon(h, name)
}

///|
/// 不透明度（T84 动画通道）：Core 发 0..1 的 Double，换算在 ffi 那层
/// （千分比整数过 FFI）。豁免注释见上面 set_widget_style 那段的改写。
pub impl @moonui.Backend for NativeBackend with fn set_widget_opacity(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_widget_set_opacity(h, v)
}

///|
/// §32 的语义翻译（`T41`）：把 `Accessibility` 打包成 adapter.h 那条 ABI
/// （role 序号 + 两个 UTF-8 串 + state 位包）。
pub impl @moonui.Backend for NativeBackend with fn set_widget_accessibility(
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
/// `AccessRole` → ABI 序号。顺序就是 `accessibility.mbt` 里的声明顺序。
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
/// 逻辑矩形 → 客户区物理矩形，然后 setFrame（C 侧翻 y）。
pub impl @moonui.Backend for NativeBackend with fn set_widget_bounds(self, h, r) -> Unit raise @moonui.UiError {
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
pub impl @moonui.Backend for NativeBackend with fn widget_bounds(self, h) -> @moonui.LogicalRect raise @moonui.UiError {
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
/// 固有尺寸来自原生控件自己的 fittingSize（字体度量属于原生层，§18）。
pub impl @moonui.Backend for NativeBackend with fn widget_intrinsic_size(
  self,
  h,
) -> @moonui.LogicalSize raise @moonui.UiError {
  self.check_initialized()
  let (w, height) = native_widget_minimum_size(h)
  scale_of_widget(h).to_logical_size(@moonui.PhysicalSize(w, height))
}

///|
/// 自定义绘制面（`T101`）的画布：一块面一张，第一次绘制时惰性建。
///
/// 为什么按控件存而不是"共用一张大画布"：位图是 `present` 到那只控件自己的
/// layer 上的，两块面共用一个缓冲区就会互相覆盖。惰性建也有理由——尺寸要到
/// `set_widget_bounds` 之后才知道，建早了只能开一张 0×0 的空帧。
fn NativeBackend::custom_canvas(
  self : NativeBackend,
  h : @moonui.NativeHandle,
) -> Canvas raise @moonui.UiError {
  for entry in self.custom_canvases {
    let (k, c) = entry
    if k == h {
      return c
    }
  }
  let c = canvas_create()
  self.custom_canvases.push((h, c))
  c
}

///|
/// 还掉某块面的画布（控件销毁时）。没建过就什么都不做——那是常态（一块面
/// 在落到 0×0 以外的尺寸之前不会建画布）。
fn NativeBackend::drop_custom_canvas(
  self : NativeBackend,
  h : @moonui.NativeHandle,
) -> Unit {
  let kept : Array[(@moonui.NativeHandle, Canvas)] = []
  for entry in self.custom_canvases {
    let (k, c) = entry
    if k == h {
      canvas_destroy(c) catch {
        _ => ()
      }
    } else {
      kept.push(entry)
    }
  }
  self.custom_canvases = kept
}

///|
/// 重画一块自定义绘制面（`T101`）：开一张该控件尺寸的位图帧，把清单按窗口
/// Scale 画进去，再贴到这只控件自己的 view 上。
///
/// 三个口径：
/// - **物理尺寸从控件读回**（`native_widget_size` 已经是物理像素），不是从
///   Core 的清单推——清单里只有逻辑账，物理换算只做一次（在 `CanvasPainter`
///   里），这里不再乘一遍；
/// - **整帧重画**：每次 `begin_frame` 换一张新位图，上一帧不留底（自定义控件
///   的语义就是"这份清单 = 这一帧的全部"）；
/// - **零尺寸跳过**：还没摆出来（或缩成 0）时开不了帧，也不该开。
pub impl @moonui.Backend for NativeBackend with fn draw_custom(
  self,
  h,
  dl : @moonui.DrawList,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  let (w, height) = native_widget_size(h)
  if w <= 0 || height <= 0 {
    return
  }
  let canvas = self.custom_canvas(h)
  canvas_begin_frame(canvas, w, height)
  let dpi = native_widget_dpi(h).to_double()
  let scale = if dpi > 0.0 { dpi / 96.0 } else { 1.0 }
  @canvas-common.replay(CanvasPainter::new(canvas, scale), dl)
  canvas_end_frame(canvas)
  canvas_present_view(canvas, handles.resolve(h).0)
}

///|
/// 文本度量（`T101` 的绘制回调要用）：走画布 ABI 的 `moonui_canvas_measure_text`
/// ——度量与绘制共用同一份 attributes，所以"量出来的就是画出来的"。
///
/// 单位是逻辑像素：那支 C 函数量的是 `NSAttributedString.size`（点），与字号
/// 同一把尺。Windows 半的画布整段缺席，这条如实 raise（自定义控件在那边的
/// 绘制本来也不存在，见 `draw_custom` 的同侧欠账）。
pub impl @moonui.Backend for NativeBackend with fn measure_text(
  self,
  text,
  size,
  bold,
) -> (Double, Double) raise @moonui.UiError {
  self.check_initialized()
  canvas_measure_text(text, size, bold~)
}

///|
/// §14：控件的 NSView 直接挂进窗口的 contentView，原生容器布局不参与。
/// 这里只管挂接，矩形由 `set_widget_bounds` 在 Core 布局算完后单独给。
pub impl @moonui.Backend for NativeBackend with fn attach_widget(
  self,
  window,
  child,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_control_attach(window, child)
}

///|
/// T74：挂进容器控件（目前只有滚动视口的文档区）。child 的矩形在 Core 侧
/// 已经平移成文档区坐标，C 侧只做 addSubview，不再动坐标。
pub impl @moonui.Backend for NativeBackend with fn attach_widget_to(
  self,
  container,
  child,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_container_attach(container, child)
}

///|
/// T74：滚动视口的滚动行程。Core 只对 Scroll 调这里（`push_scroll_content`），
/// 逻辑尺寸按视口所在屏的缩放换成物理像素交给 adapter。
pub impl @moonui.Backend for NativeBackend with fn set_scroll_content(
  self,
  scroll,
  axis,
  size,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_scroll_set_content(scroll, axis, size)
}

///|
/// 摘下来 = 从 contentView 的 subviews 里移除（C 侧 removeFromSuperview:）。
/// 放在那里之后控件既看不见也不响应——这正是"脱离了内容树"应有的状态（§8）。
pub impl @moonui.Backend for NativeBackend with fn detach_widget(self, child) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_control_detach(child)
}

///|
/// 层叠：setFrame 之后把 view 提到 contentView 子列表最上层（C 侧
/// addSubview:positioned:NSWindowAbove）。
pub impl @moonui.Backend for NativeBackend with fn raise_widget(self, child) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_control_raise(child)
}

///|
/// 整窗绘画顺序（`T29`）：`order` 是"从顶层到底层"的列表（Core 的层叠契约）。
/// 原生控件后端把它翻译成 subviews 的顺序——`raise` 是把 view 提到最上层，所以
/// 必须**倒序**逐个 raise：先提最底层的、最后提最顶层的，最顶层那只最后被提到
/// 最上面，subviews 数组最终就是"从底到顶"，和 Core 同向（和 libui 那份（`T82` 删）同一套）。
pub impl @moonui.Backend for NativeBackend with fn set_paint_order(
  self,
  window,
  order,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  for i = order.length() - 1; i >= 0; i = i - 1 {
    native_control_raise(order[i])
  }
  let _ = window
}

///|
/// 焦点链（`T29`）：把 Core 声明的整份链推给后端。Cocoa 侧关掉
/// autorecalculatesKeyViewLoop、按声明序把 nextKeyView 接成首尾相接的环
/// （链尾回链头），Tab 遍历从此按链走、不再跟 z-order（和 libui 那份（`T82` 删）同一套
/// 语义，见 adapter.h 的 moonui_set_focus_chain 注释）。
pub impl @moonui.Backend for NativeBackend with fn set_focus_chain(
  self,
  window,
  chain,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_set_focus_chain(window, chain)
}

///|
/// 自绘面的焦点 opt-in（`T102` 第十一刀）：C 侧那支 `MoonuiCustomView` 的
/// `acceptsFirstResponder` 按这个开关回答，`mouseDown:` 在开着时顺手
/// `makeFirstResponder:` 自己。默认关（视图创建时 `focusable = NO`）。
pub impl @moonui.Backend for NativeBackend with fn set_custom_focusable(
  self,
  widget,
  on,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_custom_set_focusable(widget, on)
}

///|
/// 剪贴板（§23 / §48-19，T76）：`adapter.h` 两条入口，C 侧直写 NSPasteboard。
/// 契约和错误码的形状沿用 ../libui-common/backend.mbt（`T82` 删）那套同名方法——分叉只在 C。
pub impl @moonui.Backend for NativeBackend with fn clipboard_text(self) -> String? raise @moonui.UiError {
  self.check_initialized()
  native_clipboard_text()
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_clipboard_text(
  self,
  text,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_clipboard_set_text(text)
}

///|
/// 对话框与文件选择（§48-18，T76）：同步阻塞到用户答完为止，只应在事件循环里
/// 调用。取消和失败是两条不同的路，C 的负数码在 ffi 那层变成带原因的错误（§33）。
pub impl @moonui.Backend for NativeBackend with fn show_message(
  self,
  title,
  text,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_dialog_message(title, text)
}

///|
pub impl @moonui.Backend for NativeBackend with fn confirm(self, title, text) -> Bool raise @moonui.UiError {
  self.check_initialized()
  native_dialog_confirm(title, text)
}

///|
pub impl @moonui.Backend for NativeBackend with fn open_file(self, title) -> String? raise @moonui.UiError {
  self.check_initialized()
  native_open_file(title)
}

///|
pub impl @moonui.Backend for NativeBackend with fn save_file(
  self,
  title,
  default_name,
) -> String? raise @moonui.UiError {
  self.check_initialized()
  native_save_file(title, default_name)
}

///|
pub impl @moonui.Backend for NativeBackend with fn select_folder(self, title) -> String? raise @moonui.UiError {
  self.check_initialized()
  native_select_folder(title)
}

///|
/// 菜单栏（§48-20，T76）：MoonBit 侧只把 Core 那棵树打包成一段字节（ffi.mbt 的
/// `menu_tree`），C 把它换成 NSMenu 挂进主菜单。点击通过回调回流成 `MenuSelect`，
/// 勾选态由 Core 每次点击之后推回来（下面那条）。
pub impl @moonui.Backend for NativeBackend with fn set_menu_bar(self, bar) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_set_menu_bar(bar, fn(id) {
    self.push(@moonui.MenuSelect(@moonui.EventTarget::{ id, generation: 0, }))
  })
}

///|
/// 把 Core 刚改掉的勾选态推给当下那棵原生菜单（§25）。id 不在已装的树里时报
/// `OperationFailed`——装菜单和推状态读的是同一棵树，真失败说明调用方手里的
/// id 过期了。
pub impl @moonui.Backend for NativeBackend with fn set_menu_item_checked(
  self,
  id,
  checked,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_menu_item_set_checked(id, checked)
}

///|
/// 应用图标（§26，T76）。C 侧按平台补扩展名，这里只把 stem 递下去。
pub impl @moonui.Backend for NativeBackend with fn set_app_icon(self, name) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_set_app_icon(name)
}

///|
/// 控件级右键上下文菜单（`T86①`）：整份菜单装进一棵单顶的 `MenuBar`（编号
/// 从 0 连续），打包沿 `menu_tree` 同一套字节（与 `set_menu_bar` 共用打包/解析
/// 底座），选中的语义由 `menu_click_semantics` 在弹窗的同步嵌套循环里解析。
pub impl @moonui.Backend for NativeBackend with fn show_context_menu(self, menu) -> Unit raise @moonui.UiError {
  self.check_initialized()
  let bar = menu_wrapped_bar(menu)
  native_show_context_menu(bar, fn(id) { menu_click_semantics(bar, id) })
}

///|
/// 窗口态（`T86②`）：两条 setter 加一条读当下的快照（读回契约见 trait 注记）。
pub impl @moonui.Backend for NativeBackend with fn set_window_minimized(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_set_minimized(h, v)
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_window_maximized(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_window_set_maximized(h, v)
}

///|
pub impl @moonui.Backend for NativeBackend with fn window_state(self, h) -> @moonui.WindowState raise @moonui.UiError {
  self.check_initialized()
  native_window_state(h)
}

///|
/// 图像源（`T86⑤`）：解码与绘制归原生层，两条通道各是整源替换。
pub impl @moonui.Backend for NativeBackend with fn set_widget_image_path(
  self,
  h,
  path,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_image_set_path(h, path)
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_image_bytes(
  self,
  h,
  data,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_image_set_data(h, data)
}

///|
/// 托盘与通知（`T86⑥`）：托盘菜单沿 `T86①` 的同步解析；`notify` 投出去即返回。
pub impl @moonui.Backend for NativeBackend with fn set_tray_icon(self, name) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_tray_set_icon(name)
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_tray_menu(self, menu) -> Unit raise @moonui.UiError {
  self.check_initialized()
  let bar = menu_wrapped_bar(menu)
  native_tray_set_menu(bar, fn(id) { menu_click_semantics(bar, id) })
}

///|
pub impl @moonui.Backend for NativeBackend with fn notify(self, title, body) -> Unit raise @moonui.UiError {
  self.check_initialized()
  native_notify(title, body)
}

///|
/// 把单顶菜单包成 `MenuBar`（编号从 0 连续），托盘菜单与上下文菜单共用这半。
fn menu_wrapped_bar(menu : @moonui.Menu) -> @moonui.MenuBar {
  @moonui.MenuBar::new([menu])
}

///|
/// 把 trait 方法提升成 `NativeBackend` 的普通方法（和 ../libui-common/backend.mbt
///（`T82` 删）末尾那条同一套形状），免得 `implicit_impl_as_method` 那条弃用警告。
pub extend NativeBackend with @moonui.Backend::{
  init,
  terminate,
  poll_event,
  request_redraw,
  create_window,
  destroy_window,
  set_window_title,
  set_window_size,
  set_window_min_size,
  set_window_live_redraw,
  set_live_dispatch,
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
  set_window_drag_band,
  host_platform,
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
  set_widget_opacity,
  set_widget_style,
  set_widget_icon,
  set_theme_base,
  set_widget_accessibility,
  set_widget_bounds,
  widget_bounds,
  widget_intrinsic_size,
  draw_custom,
  measure_text,
  attach_widget,
  attach_widget_to,
  set_scroll_content,
  detach_widget,
  raise_widget,
  set_paint_order,
  set_focus_chain,
  set_custom_focusable,
  clipboard_text,
  set_clipboard_text,
  system_theme,
  get_prefers_reduced_motion,
  get_prefers_high_contrast,
  show_message,
  confirm,
  open_file,
  save_file,
  select_folder,
  set_menu_bar,
  set_menu_item_checked,
  set_app_icon,
  show_context_menu,
  set_window_minimized,
  set_window_maximized,
  window_state,
  set_widget_image_path,
  set_widget_image_bytes,
  set_tray_icon,
  set_tray_menu,
  notify,
}
