///|
/// Window（设计文档 §12）。
///
/// `Window[B]` 只是原生窗口的句柄包装：尺寸、位置、可见性一律通过 `Backend`
/// 读写，Core 不缓存窗口状态——缓存会和原生层的真实值分叉，而 HiDPI 缩放、
/// 用户拖拽产生的 Resize 都只有原生层知道。唯一留在 Core 的是 min/max 约束：
/// libui-ng 没有对应的原生 API，这条夹紧策略因此是 MoonUI 自己的语义。
///
/// §8 的所有权在这里落地：窗口持有唯一的内容树，`set_content` 换树时旧树整棵关闭，
/// `close()` 与用户点关闭按钮产生的 Close 事件走同一条释放路径。因此 `on_close`
/// 的订阅者是观察者，不需要（也不能）再在里面调用 `close()`。

///|
pub struct Window[B] {
  backend : B
  handle : NativeHandle
  mut closed : Bool
  mut min_size : LogicalSize?
  mut max_size : LogicalSize?
  mut content : Widget[B]?
}

///|
/// 文档 §12 的 `Window::new(title, width, height)`。尺寸是逻辑像素（§30）。
pub fn[B : Backend] Window::new(
  backend : B,
  title : String,
  size : LogicalSize,
) -> Window[B] raise UiError {
  let handle = Backend::create_window(backend, title, size)
  Window::{
    backend,
    handle,
    closed: false,
    min_size: None,
    max_size: None,
    content: None,
  }
}

///|
pub fn[B] Window::handle(self : Window[B]) -> NativeHandle {
  self.handle
}

///|
/// 事件订阅用的目标。id 与句柄一致，`App::on_event(win.target(), ...)` 就能收到
/// 这个窗口的 Close/Resize（§10）。
pub fn[B] Window::target(self : Window[B]) -> EventTarget {
  EventTarget::{ id: self.handle.id, }
}

///|
pub fn[B] Window::is_closed(self : Window[B]) -> Bool {
  self.closed
}

///|
/// 已销毁的窗口上做任何操作都返回 `Destroyed`，不会把失效句柄递到 C 层（§47 风险 2）。
fn[B] Window::check_open(self : Window[B]) -> NativeHandle raise UiError {
  if self.closed {
    raise Destroyed
  }
  self.handle
}

///|
pub fn[B : Backend] Window::show(self : Window[B]) -> Unit raise UiError {
  let h = self.check_open()
  Backend::show_window(self.backend, h)
}

///|
pub fn[B : Backend] Window::hide(self : Window[B]) -> Unit raise UiError {
  let h = self.check_open()
  Backend::hide_window(self.backend, h)
}

///|
/// 关闭窗口并注销句柄。重复调用返回 `Destroyed`，因此双击关闭、
/// handler 里再 close 都不会造成二次销毁。
pub fn[B : Backend] Window::close(self : Window[B]) -> Unit raise UiError {
  let h = self.check_open()
  self.release(h)
}

///|
/// 释放整窗口（§8 的所有权终点）：先关内容树，再销毁原生窗口。
///
/// 顺序不能反：真实后端销毁窗口时会在析构回调里遍历子控件，
/// 若控件句柄还挂在表上，Core 这边就会读到已经释放的原生对象。
fn[B : Backend] Window::release(
  self : Window[B],
  h : NativeHandle,
) -> Unit raise UiError {
  match self.content {
    Some(root) => {
      root.close_tree()
      self.content = None
    }
    None => ()
  }
  Backend::destroy_window(self.backend, h)
  self.closed = true
}

///|
pub fn[B : Backend] Window::set_title(
  self : Window[B],
  title : String,
) -> Unit raise UiError {
  let h = self.check_open()
  Backend::set_window_title(self.backend, h, title)
}

///|
/// 设置尺寸：先按 Core 的 min/max 夹紧，再交给后端。负值按零处理。
pub fn[B : Backend] Window::set_size(
  self : Window[B],
  size : LogicalSize,
) -> Unit raise UiError {
  let h = self.check_open()
  Backend::set_window_size(self.backend, h, self.clamped(size))
}

///|
pub fn[B : Backend] Window::size(self : Window[B]) -> LogicalSize raise UiError {
  let h = self.check_open()
  Backend::window_size(self.backend, h)
}

///|
pub fn[B : Backend] Window::set_position(
  self : Window[B],
  origin : LogicalPoint,
) -> Unit raise UiError {
  let h = self.check_open()
  Backend::set_window_position(self.backend, h, origin)
}

///|
pub fn[B : Backend] Window::position(
  self : Window[B],
) -> LogicalPoint raise UiError {
  let h = self.check_open()
  Backend::window_position(self.backend, h)
}

///|
/// 由 Resize 事件回写尺寸：原生层是事实来源，Core 侧布局需要知道新尺寸时调用它。
/// 这里不回报后端，只做 min/max 校验，避免和原生层的值来回打架。
pub fn[B] Window::sync_size(
  self : Window[B],
  size : LogicalSize,
) -> LogicalSize raise UiError {
  if self.closed {
    raise Destroyed
  }
  self.clamped(size)
}

///|
/// 最小尺寸必须不大于最大尺寸，否则夹紧结果不可预期（§33 把这类矛盾变成显式错误）。
pub fn[B] Window::set_min_size(
  self : Window[B],
  size : LogicalSize?,
) -> Unit raise UiError {
  if self.closed {
    raise Destroyed
  }
  match (size, self.max_size) {
    (Some(lo), Some(hi)) => check_size_pair(lo, hi)
    _ => ()
  }
  self.min_size = size
}

///|
pub fn[B] Window::set_max_size(
  self : Window[B],
  size : LogicalSize?,
) -> Unit raise UiError {
  if self.closed {
    raise Destroyed
  }
  match (self.min_size, size) {
    (Some(lo), Some(hi)) => check_size_pair(lo, hi)
    _ => ()
  }
  self.max_size = size
}

///|
pub fn[B] Window::min_size(self : Window[B]) -> LogicalSize? {
  self.min_size
}

///|
pub fn[B] Window::max_size(self : Window[B]) -> LogicalSize? {
  self.max_size
}

///|
pub fn[B : Backend] Window::set_resizable(
  self : Window[B],
  v : Bool,
) -> Unit raise UiError {
  let h = self.check_open()
  Backend::set_window_resizable(self.backend, h, v)
}

///|
pub fn[B : Backend] Window::set_fullscreen(
  self : Window[B],
  v : Bool,
) -> Unit raise UiError {
  let h = self.check_open()
  Backend::set_window_fullscreen(self.backend, h, v)
}

///|
/// 窗口所在屏幕的缩放因子（§30）。逻辑像素只出现在 API 上，物理换算在这里做。
/// 后端给的 Scale 先过 `normalized`：DPI 字段未初始化（0.0）不能把布局变成 Infinity。
pub fn[B : Backend] Window::scale(self : Window[B]) -> Scale raise UiError {
  let h = self.check_open()
  Backend::window_scale(self.backend, h).normalized()
}

///|
pub fn[B : Backend] Window::physical_size(
  self : Window[B],
) -> PhysicalSize raise UiError {
  let s = self.size()
  self.scale().to_physical_size(s)
}

///|
/// 居中到主屏可用区域。窗口大于屏幕时偏移夹为零，不产生负坐标（§12）。
pub fn[B : Backend] Window::center(self : Window[B]) -> Unit raise UiError {
  let screen = Backend::screen_size(self.backend)
  let size = self.size()
  let spot = LogicalRect::{
    origin: LogicalPoint::{ x: 0.0, y: 0.0, },
    size: screen,
  }.center(size)
  self.set_position(spot.origin)
}

///|
fn[B] Window::clamped(self : Window[B], size : LogicalSize) -> LogicalSize {
  let lo = match self.min_size {
    Some(m) => m
    None => LogicalSize::zero()
  }
  let hi = match self.max_size {
    Some(m) => m
    None => LogicalSize::{ width: Infinity, height: Infinity, }
  }
  size.non_negative().clamp(lo, hi)
}

///|
fn check_size_pair(lo : LogicalSize, hi : LogicalSize) -> Unit raise UiError {
  if lo.width > hi.width || lo.height > hi.height {
    raise OperationFailed("窗口的最小尺寸大于最大尺寸")
  }
}

///|
fn mock_window() -> (MockBackend, Window[MockBackend]) raise UiError {
  let b = MockBackend::new()
  Backend::init(b)
  let win = Window::new(b, "MoonUI", LogicalSize::{
    width: 800.0,
    height: 600.0,
  })
  (b, win)
}

///|
test "窗口属性读写都走 Backend，Core 不缓存" {
  let (b, win) = mock_window()
  assert_eq(win.size(), LogicalSize::{ width: 800.0, height: 600.0, })
  assert_false(b.window(win.handle()).visible)
  win.show()
  assert_true(b.window(win.handle()).visible)
  win.hide()
  assert_false(b.window(win.handle()).visible)
  win.set_title("MoonUI — Counter")
  assert_eq(b.window(win.handle()).title, "MoonUI — Counter")
  win.set_position(LogicalPoint::{ x: 30.0, y: 40.0, })
  assert_eq(win.position(), LogicalPoint::{ x: 30.0, y: 40.0, })
  win.set_resizable(false)
  assert_false(b.window(win.handle()).resizable)
  win.set_fullscreen(true)
  assert_true(b.window(win.handle()).fullscreen)
  assert_false(win.is_closed())
}

///|
test "min/max 在 Core 侧夹紧后再交给后端" {
  let (_b, win) = mock_window()
  win.set_min_size(Some(LogicalSize::{ width: 200.0, height: 100.0, }))
  win.set_max_size(Some(LogicalSize::{ width: 600.0, height: 400.0, }))
  win.set_size(LogicalSize::{ width: 50.0, height: 5000.0, })
  assert_eq(win.size(), LogicalSize::{ width: 200.0, height: 400.0, })
  win.set_size(LogicalSize::{ width: -10.0, height: 250.0, })
  // 负值先归零，再被最小尺寸抬起来
  assert_eq(win.size(), LogicalSize::{ width: 200.0, height: 250.0, })
  assert_eq(win.min_size(), Some(LogicalSize::{ width: 200.0, height: 100.0, }))
  assert_eq(win.sync_size(LogicalSize::{ width: 9999.0, height: 10.0, }), LogicalSize::{
    width: 600.0,
    height: 100.0,
  })
  // sync_size 不回写后端，Resize 事件的原生值才是事实
  assert_eq(win.size().height, 250.0)
}

///|
test "最小尺寸大于最大尺寸时报错并保持原约束" {
  let (_b, win) = mock_window()
  win.set_max_size(Some(LogicalSize::{ width: 300.0, height: 300.0, }))
  let msg = try {
    win.set_min_size(Some(LogicalSize::{ width: 400.0, height: 100.0, }))
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("操作失败：窗口的最小尺寸大于最大尺寸"))
  assert_eq(win.min_size(), None)
  // 反过来设置同样被拦下
  win.set_min_size(Some(LogicalSize::{ width: 100.0, height: 100.0, }))
  let msg2 = try {
    win.set_max_size(Some(LogicalSize::{ width: 50.0, height: 500.0, }))
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(
    msg2,
    Some("操作失败：窗口的最小尺寸大于最大尺寸"),
  )
}

///|
test "close 之后一切操作都是 Destroyed，重复 close 不会二次销毁" {
  let (b, win) = mock_window()
  win.show()
  win.close()
  assert_true(win.is_closed())
  assert_eq(b.live(), 0)
  let msg = try {
    let _ = win.size()
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("对象已销毁"))
  // 重复 close 直接被 Core 拦下，句柄不会第二次传给后端
  let again = try {
    win.close()
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(again, Some("对象已销毁"))
  assert_eq(b.live(), 0)
}

///|
test "center 把窗口摆到屏幕中央，窗口大于屏幕时不产生负坐标" {
  let (b, win) = mock_window()
  win.center()
  assert_eq(win.position(), LogicalPoint::{ x: 560.0, y: 240.0, })
  MockBackend::set_screen_size(b, LogicalSize::{ width: 400.0, height: 300.0, })
  win.center()
  assert_eq(win.position(), LogicalPoint::{ x: 0.0, y: 0.0, })
}

///|
test "physical_size 按窗口缩放因子换算（§30）" {
  let (b, win) = mock_window()
  assert_eq(win.physical_size(), PhysicalSize::{ width: 800, height: 600, })
  MockBackend::set_window_scale(b, win.handle(), Scale::{ x: 2.0, y: 2.0, })
  assert_eq(win.scale(), Scale::{ x: 2.0, y: 2.0, })
  assert_eq(win.physical_size(), PhysicalSize::{ width: 1600, height: 1200, })
}

///|
test "Window::target 与句柄同 id，供 App 按窗口订阅" {
  let (_b, win) = mock_window()
  assert_eq(win.target(), EventTarget::{ id: win.handle().id, })
}

///|
/// 装入内容树（§8 的所有权落点）：窗口成为整棵树的唯一持有者。
///
/// §14 的决定在这里生效：只有叶子控件需要原生父级，Row/Padding/Center 这些
/// 纯布局节点由 Core 算绝对边界，所以挂接动作只是把叶子句柄交给窗口。
/// 换内容时旧树整棵关闭，原生对象随 `close_tree` 归还，不留悬垂句柄。
pub fn[B : Backend] Window::set_content(
  self : Window[B],
  root : Widget[B],
) -> Unit raise UiError {
  let h = self.check_open()
  if root.is_attached() {
    raise AlreadyOwned
  }
  match self.content {
    Some(old) => old.close_tree()
    None => ()
  }
  root.attached = true
  self.content = Some(root)
  let leaves : Array[NativeHandle] = []
  root.collect_native(leaves)
  for leaf in leaves {
    Backend::attach_widget(self.backend, h, leaf)
  }
  root.apply_layers(self.backend)
  self.relayout()
}

///|
pub fn[B] Window::content(self : Window[B]) -> Widget[B]? {
  self.content
}

///|
/// 用窗口当前尺寸重算整棵内容树的绝对边界。Resize 事件走这里（§12/§14）。
pub fn[B : Backend] Window::relayout(self : Window[B]) -> Unit raise UiError {
  match self.content {
    Some(root) => {
      let _ = root.do_layout(LogicalRect::{
        origin: LogicalPoint::{ x: 0.0, y: 0.0, },
        size: self.size(),
      })
    }
    None => ()
  }
}

///|
/// 按原生句柄 id 在内容树里找控件；`App::dispatch` 用它把事件路由到控件 handler。
/// 只有 Core 内部需要，不放进公共 API。
fn[B] Window::find_widget(self : Window[B], id : Int) -> Widget[B]? {
  match self.content {
    Some(root) => root.find_by_id(id)
    None => None
  }
}

///|
/// 窗口自身要处理的事件（§10）：Resize 先回写尺寸再重排，Close 走和用户关闭
/// 同一条释放路径。其余事件属于控件，这里不管。
/// 这是 `App::dispatch` 的落点，不是用户 API——用户订阅走 `App::on_event`。
fn[B : Backend] Window::handle_event(
  self : Window[B],
  ev : Event,
) -> Unit raise UiError {
  match ev {
    Resize(_, size) => {
      let _ = self.sync_size(size)
      self.relayout()
    }
    /// DPI 变化的两种后端模型都要走重排：
    /// - macOS/Windows 的 backing scale 变了、物理尺寸没变：逻辑尺寸随之变小，
    ///   布局必须以新的 `size()` 重算；
    /// - Win32 的按监视器 DPI 变化会先按建议尺寸改窗口再通知：逻辑尺寸已经变了。
    /// 两种情况 Core 都不缓存 Scale，`relayout` 读的是后端当下的真实尺寸。
    ScaleChanged(_, _) => self.relayout()
    Close(_) => {
      let h = self.check_open()
      self.release(h)
    }
    _ => ()
  }
}

///|
fn content_window() -> (MockBackend, Window[MockBackend]) raise UiError {
  let (b, win) = mock_window()
  win.set_size(LogicalSize::{ width: 200.0, height: 100.0, })
  (b, win)
}

///|
/// 测试用：窗口的层叠顺序，按句柄 id 从顶层到底层列出。
fn z_ids(
  b : MockBackend,
  win : Window[MockBackend],
) -> Array[Int] raise UiError {
  let out : Array[Int] = []
  for h in b.child_z_order(win.handle()) {
    out.push(h.id)
  }
  out
}

///|
/// 测试用：控件的句柄 id。布局节点没有句柄，拿不到就是测试自己写错了树。
fn handle_id(w : Widget[MockBackend]) -> Int raise UiError {
  match w.handle() {
    Some(h) => h.id
    None => raise InvalidHandle
  }
}

///|
test "set_content 把叶子挂到窗口并立即布局（§8/§14）" {
  let (b, win) = content_window()
  let label = Widget::label(b, "Ab")
  let btn = Widget::button(b, "Ok")
  let row = Widget::row(b, 10.0, [label, btn])
  win.set_content(row)
  assert_true(win.content() is Some(_))
  // 两个叶子都挂上了这个窗口
  let leaves : Array[NativeHandle] = []
  match win.content() {
    Some(root) => root.collect_native(leaves)
    None => ()
  }
  assert_eq(leaves.length(), 2)
  for h in leaves {
    assert_eq(b.widget(h).parent, Some(win.handle()))
  }
  // 布局已经在窗口内容区里跑过一轮
  assert_eq(label.bounds(), LogicalRect::{
    origin: LogicalPoint::{ x: 0.0, y: 0.0, },
    size: LogicalSize::{ width: 24.0, height: 20.0, },
  })
  assert_eq(btn.bounds().origin.x, 34.0)
}

///|
/// 层叠落到后端（§14、§48-15）。断言的是 z-order **从顶到底**，
/// 也就是真后端上 `EnumChildWindows` 的返回顺序。
test "Stack 的叶子按数组倒序叠放，非叠放的树保持挂载顺序" {
  let (b, win) = content_window()
  let back = Widget::label(b, "Ab")
  let badge = Widget::button(b, "Ok")
  let top = Widget::label(b, "A")
  win.set_content(Widget::stack(b, [back, badge, top]))
  // 挂载顺序给的是"先挂的在上层"，和 Stack 的契约正好反，所以 Core 事后逐个提：
  // 最后提的 top 落在最上层。
  assert_eq(z_ids(b, win), [handle_id(top), handle_id(badge), handle_id(back)])
  // 不含 Stack 的树一条都不提：挂载顺序 = Tab 顺序这条不变（§14 的既有约定）。
  let (b2, win2) = content_window()
  let label = Widget::label(b2, "Ab")
  let btn = Widget::button(b2, "Ok")
  win2.set_content(Widget::row(b2, 10.0, [label, btn]))
  assert_eq(z_ids(b2, win2), [handle_id(label), handle_id(btn)])
}

///|
/// 层叠是"每个 Stack 管自己那一层"：嵌套时外层数组靠后的整棵子树都在上面。
test "嵌套 Stack 的层叠按外层顺序，内层跟着自己的数组" {
  let (b, win) = content_window()
  let a = Widget::label(b, "A")
  let bb = Widget::label(b, "B")
  let inner = Widget::stack(b, [a, bb])
  let c = Widget::label(b, "C")
  win.set_content(Widget::stack(b, [inner, c]))
  assert_eq(z_ids(b, win), [handle_id(c), handle_id(bb), handle_id(a)])
}

///|
test "换内容时旧树整棵关闭，句柄不残留" {
  let (b, win) = content_window()
  let old_btn = Widget::button(b, "Old")
  win.set_content(Widget::column(b, 0.0, [old_btn]))
  assert_eq(b.live(), 2)
  let new_label = Widget::label(b, "New")
  win.set_content(new_label)
  // 旧按钮的原生对象已释放，只剩窗口 + 新标签
  assert_eq(b.live(), 2)
  assert_true(old_btn.is_closed())
  assert_eq(
    widget_error(fn() raise UiError { let _ = old_btn.text() }),
    Some("对象已销毁"),
  )
  // 根控件就是一个叶子标签时，它占满整个内容区
  assert_eq(new_label.bounds(), rect(0.0, 0.0, 200.0, 100.0))
}

///|
test "同一棵树不能装进两个窗口" {
  let (b, win) = content_window()
  let other = Window::new(b, "Other", LogicalSize::{
    width: 100.0,
    height: 100.0,
  })
  let shared = Widget::row(b, 0.0, [Widget::label(b, "A")])
  win.set_content(shared)
  // 别的窗口可以装自己的内容
  other.set_content(Widget::label(b, "B"))
  // 但已被持有的根控件不能再次装入——否则两个窗口都会销毁同一批叶子
  assert_eq(
    widget_error(fn() raise UiError { other.set_content(shared) }),
    Some("该控件已被其他容器持有"),
  )
}

///|
test "窗口关闭时内容树一起释放" {
  let (b, win) = content_window()
  let btn = Widget::button(b, "Ok")
  let input = Widget::text_input(b, "")
  win.set_content(Widget::row(b, 4.0, [btn, input]))
  assert_eq(b.live(), 3)
  win.close()
  assert_true(win.is_closed())
  assert_true(btn.is_closed())
  assert_eq(b.live(), 0)
  assert_true(win.content() is None)
}

///|
test "Resize 事件回写尺寸并重排内容" {
  let (b, win) = content_window()
  let sp = Widget::spacer(b)
  let label = Widget::label(b, "Ab")
  win.set_content(Widget::row(b, 0.0, [sp, label]))
  // 200 宽里 Spacer 吃掉 176，标签贴在右端
  assert_eq(label.bounds().origin.x, 176.0)
  // 真实后端是"先改尺寸、再发 Resize"，mock 要复现这个次序才有意义
  Backend::set_window_size(b, win.handle(), LogicalSize::{
    width: 100.0,
    height: 100.0,
  })
  win.handle_event(
    Event::Resize(win.target(), LogicalSize::{ width: 100.0, height: 100.0, }),
  )
  assert_eq(win.size(), LogicalSize::{ width: 100.0, height: 100.0, })
  assert_eq(label.bounds().origin.x, 76.0)
  assert_eq(label.bounds().origin.y, 0.0)
}

///|
test "Close 事件走与用户关闭相同的释放路径" {
  let (b, win) = content_window()
  win.set_content(Widget::label(b, "A"))
  win.handle_event(Event::Close(win.target()))
  assert_true(win.is_closed())
  assert_eq(b.live(), 0)
}

///|
/// §30/§48-21：DPI 变化要驱动 Core 重算，而不是等用户手动 resize。
/// 这里模拟 macOS 的 backing scale 模型：物理尺寸不变、Scale 变了，
/// 后端因此报出更小的逻辑尺寸，窗口必须按新尺寸重排。
test "ScaleChanged 让窗口按新逻辑尺寸重排" {
  let (b, win) = content_window()
  let label = Widget::label(b, "Ab")
  let sp = Widget::spacer(b)
  win.set_content(Widget::row(b, 0.0, [sp, label]))
  assert_eq(label.bounds().origin.x, 176.0)
  assert_eq(win.physical_size(), PhysicalSize::{ width: 200, height: 100, })
  MockBackend::set_window_scale(b, win.handle(), Scale::{ x: 2.0, y: 2.0, })
  Backend::set_window_size(b, win.handle(), LogicalSize::{
    width: 100.0,
    height: 50.0,
  })
  win.handle_event(ScaleChanged(win.target(), Scale::{ x: 2.0, y: 2.0, }))
  assert_eq(label.bounds().origin.x, 76.0)
  // 物理尺寸跨 DPI 变化保持不变，这正是 HiDPI 的全部意义
  assert_eq(win.physical_size(), PhysicalSize::{ width: 200, height: 100, })
}

///|
/// 后端 DPI 字段没初始化就返回 0.0：窗口层夹紧到 1.0，
/// 不能让除零把布局变成 Infinity（§47 第 5 条）。
test "非法的后端缩放因子在窗口层被夹紧" {
  let (b, win) = mock_window()
  MockBackend::set_window_scale(b, win.handle(), Scale::{ x: 0.0, y: -2.0, })
  assert_eq(win.scale(), Scale::one())
  assert_eq(win.physical_size(), PhysicalSize::{ width: 800, height: 600, })
}

///|
/// `Window::scale` 是 Core 唯一的 Scale 入口，所以换算集中在这里之后，
/// 逻辑矩形到物理矩形的取整规则由 `Scale` 保证（原点 floor、宽高 ceil）。
test "内容树的逻辑矩形可以整棵换算成物理矩形" {
  let (b, win) = content_window()
  MockBackend::set_window_scale(b, win.handle(), Scale::{ x: 2.0, y: 2.0, })
  let label = Widget::label(b, "Ab")
  let btn = Widget::button(b, "Ok")
  win.set_content(Widget::column(b, 6.0, [label, btn]))
  let s = win.scale()
  let lb = s.to_physical_rect(label.frame())
  let bb = s.to_physical_rect(btn.frame())
  assert_eq(lb, PhysicalRect::{
    origin: PhysicalPoint::{ x: 0, y: 0, },
    size: PhysicalSize::{ width: 48, height: 40, },
  })
  // 文案 20 逻辑高 + 6 逻辑间距 = 26 逻辑 -> 52 物理：间距也按同一因子放大，
  // 所以 2x 屏上留白是 12 物理像素，不会退化成 1x 屏上的 6
  assert_eq(bb.origin.y, 52)
  assert_eq(bb.origin.y - (lb.origin.y + lb.size.height), 12)
  assert_eq(bb.size, PhysicalSize::{ width: 80, height: 56, })
}
