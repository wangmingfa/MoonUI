///|
/// 原生 Cocoa 后端（设计文档 §51 的 Backend #2，macOS 半）。
///
/// 这一层把 `Backend` 契约翻译成 `native_*` 那套物理像素调用，和
/// ../libui-common/backend.mbt 同一套形状，但底下不经过 libui-ng——窗口、事件
/// 循环、回调全部直写 AppKit（见 adapter_native.m）。这是"libui-ng 只是第一个
/// Backend"（§51）的正面落地：Core 里跑 Demo 的那条泛型路径，在这里换成一个
/// 真窗口、真事件循环，一行 Core 代码都不用改。
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
/// 收尾顺序是硬要求：先控件、后窗口，最后才是 `native_terminate`。FP1 还没有
/// 控件，`live_widgets` 恒空，所以这里只剩窗口那一圈（FP2 补控件时把控件圈加回来）。
pub impl @moonui.Backend for NativeBackend with fn terminate(self) {
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
  scale_of_window(h).to_logical_size(@moonui.PhysicalSize::{ width: w, height, })
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
  @moonui.Scale::of_dpi(native_system_dpi().to_double()).to_logical_size(@moonui.PhysicalSize::{
    width: w,
    height,
  })
}

///|
/// 这只窗口当下所在那块屏的工作区（`T42`）。
pub impl @moonui.Backend for NativeBackend with fn window_work_area(self, h) -> @moonui.LogicalRect raise @moonui.UiError {
  self.check_initialized()
  let scale = scale_of_window(h)
  let (x, y) = native_window_screen_origin(h)
  let (w, height) = native_window_screen_size(h)
  @moonui.LogicalRect::{
    origin: scale.to_logical_point(@moonui.PhysicalPoint::{ x, y, }),
    size: scale.to_logical_size(@moonui.PhysicalSize::{ width: w, height, }),
  }
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
  scale_of_window(h).to_logical_point(@moonui.PhysicalPoint::{ x, y, })
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
/// FP1 还没有控件：所有控件方法暂时 raise Unsupported，FP2 补。
pub impl @moonui.Backend for NativeBackend with fn create_widget(
  self,
  _kind,
  _text,
) -> @moonui.NativeHandle raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn create_ranged_widget(
  self,
  _kind,
  _min,
  _max,
) -> @moonui.NativeHandle raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn destroy_widget(self, _h) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_text(
  self,
  _h,
  _text,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_text(self, _h) -> String raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_checked(
  self,
  _h,
  _v,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_checked(self, _h) -> Bool raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_value(
  self,
  _h,
  _v,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_value(self, _h) -> Int32 raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_range(
  self,
  _h,
  _min,
  _max,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn append_widget_option(
  self,
  _h,
  _text,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_selected(
  self,
  _h,
  _index,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_selected(self, _h) -> Int32 raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_datetime(
  self,
  _h,
  _text,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_datetime(self, _h) -> String raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_visible(
  self,
  _h,
  _v,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_visible(self, _h) -> Bool raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_enabled(
  self,
  _h,
  _v,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_enabled(self, _h) -> Bool raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_style(
  self,
  _h,
  _style,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_accessibility(
  self,
  _h,
  _a,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_widget_bounds(
  self,
  _h,
  _rect,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_bounds(self, _h) -> @moonui.LogicalRect raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn widget_intrinsic_size(
  self,
  _h,
) -> @moonui.LogicalSize raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn attach_widget(
  self,
  _window,
  _child,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn detach_widget(self, _child) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn raise_widget(self, _child) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_paint_order(
  self,
  _window,
  _order,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_focus_chain(
  self,
  _window,
  _chain,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有控件（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn clipboard_text(self) -> String? raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有剪贴板（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_clipboard_text(
  self,
  _text,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有剪贴板（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn show_message(
  self,
  _title,
  _text,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有对话框（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn confirm(self, _title, _text) -> Bool raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有对话框（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn open_file(self, _title) -> String? raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported(
    "原生后端 FP1 还没有文件面板（FP2 补）",
  )
}

///|
pub impl @moonui.Backend for NativeBackend with fn save_file(
  self,
  _title,
  _default_name,
) -> String? raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported(
    "原生后端 FP1 还没有文件面板（FP2 补）",
  )
}

///|
pub impl @moonui.Backend for NativeBackend with fn select_folder(self, _title) -> String? raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported(
    "原生后端 FP1 还没有文件面板（FP2 补）",
  )
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_menu_bar(self, _bar) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有菜单栏（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_menu_item_checked(
  self,
  _id,
  _checked,
) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported("原生后端 FP1 还没有菜单栏（FP2 补）")
}

///|
pub impl @moonui.Backend for NativeBackend with fn set_app_icon(self, _name) -> Unit raise @moonui.UiError {
  self.check_initialized()
  raise @moonui.Unsupported(
    "原生后端 FP1 还没有应用图标（FP2 补）",
  )
}

///|
/// 把 trait 方法提升成 `NativeBackend` 的普通方法（和 ../libui-common/backend.mbt
/// 末尾那条同一套形状），免得 `implicit_impl_as_method` 那条弃用警告。
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
