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
/// 把"窗口客户区变了"翻译成 Resize 事件。
/// 读尺寸要过句柄表，可能失败——失败就丢事件：这条回调只可能在窗口正在被
/// 拆掉的时候撞上失效句柄，而 Core 也不会派发给已经关掉的窗口（§12）。
fn NativeBackend::push_resize(
  self : NativeBackend,
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
  self.initialized = false
  self.loop_ended = false
  // `T85②`：C 侧的监听闭包随 terminate 松开，这里同步复位——重建控件时重新装。
  self.ime_installed = false
  // `T86①`/`T86③`：鼠标与文件拖入两份监听同一条形状（进程一份），同步复位。
  self.mouse_installed = false
  self.drag_installed = false
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
  self.live_windows.push(h)
  // `T86①`/`T86③`：鼠标与文件拖入两份监听都是"进程一份、惰性装"——有窗口
  // 才会有右键和拖进，第一条窗口创建时装上（与组合监听的同形形状）。装不上
  // 就静默缺席（Windows 半的拖入源还没接，欠 IDropTarget；不挡开窗），
  // 复位在 terminate。
  if !self.mouse_installed {
    try {
      native_on_mouse(fn() {
        match self.mouse_target_widget(native_mouse_target()) {
          Some(h) => {
            let kb = native_mouse_kind_button()
            // 只接"按下"那一支里的右键（kind 0、button 1，adapter.h 的鼠标
            // 编码）：本轮判据只有右键路由——左键按下的既有消费者是控件回调
            // 发的 Click，不重复建一条；其余 kind 的翻译欠账挂报告。
            if kb / 8 == 0 && kb % 8 == 1 {
              // 这个闭包被 C 在监听回调里调进来，raise 跨 C 帧未定义（worker
              // 同一条纪律）——读 DPI 要过句柄表可能失败，失败就丢事件（§12）。
              try {
                let (px, py) = native_mouse_pos()
                let point = scale_of_widget(h).to_logical_point(
                  @moonui.PhysicalPoint(px, py),
                )
                self.push(
                  @moonui.MouseDown(
                    @moonui.EventTarget::of(h),
                    @moonui.Right,
                    point,
                  ),
                )
              } catch {
                _ => ()
              }
            }
          }
          None => ()
        }
      })
      self.mouse_installed = true
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
      // `T85②`：进程级组合事件源，第一条文本控件创建时装上（重复装只换回调，
      // adapter.h 的 IME 段注）。通知不带内容（§48-16），相位/target/组合串由
      // 读口当场取；target 反查不进句柄表（组合对象已销毁）就丢——悬垂组合
      // 命中死控件由 generation 自动挡住（`T49`/`T57` 继承到组合相位路径）。
      if !self.ime_installed {
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
  native_widget_destroy(h)
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
/// §32 豁免在 `T84` 破的正是 opacity 这条：透明度是动画逐帧推进的值，
/// 单独通道真实现（mac 半 NSView alphaValue、Windows 半子窗口分层透明）。
/// 除 opacity 这条动画通道外，§15/§16 下发的样式在原生控件后端上**仍有意
/// 不生效**：§32 要保住系统原生外观，而 AppKit 不给 button/label 提供
/// per-control 的字体或配色接口（MenuRow 的选中高亮是它自己的事，走 checked
/// 通道，不靠 Style）。所以这里只检查初始化，其余什么都不做，
/// `widget_intrinsic_size` 继续报原生控件在系统字体下的尺寸。
pub impl @moonui.Backend for NativeBackend with fn set_widget_style(
  self,
  _h,
  _style,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
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
  set_widget_opacity,
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
