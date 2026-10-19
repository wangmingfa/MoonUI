///|
/// Window（设计文档 §12）。
///
/// `Window[B]` 只是原生窗口的句柄包装：尺寸、位置、可见性一律通过 `Backend`
/// 读写，Core 不缓存窗口状态——缓存会和原生层的真实值分叉，而 HiDPI 缩放、
/// 用户拖拽产生的 Resize 都只有原生层知道。留在 Core 的只有两样，都不是原生状态：
/// min/max 约束（Core 侧的夹紧语义；min 还会推给原生层落成系统级钳位——用户
/// 拖窗格不经过 Core，只有原生层的钳位挡得住），
/// 以及 `style_base`（§15/§16 的主题底样式，由 `App` 算好交下来，原生层根本不知道
/// 主题这回事）。
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
  /// 拖拽改尺寸的实时重排开关（live redraw）的**显式覆盖**：`None` = 继承
  /// App 的默认（`live_default`）。两层是两种真实需求——应用整体想开/关
  /// （`App::set_live_redraw`）与"这只窗特别重、单独关"（`set_live_redraw`）。
  mut live_redraw : Bool?
  /// App 下发的全局默认（`App::create_window` 填入、`App::set_live_redraw`
  /// 刷新），沿 `style_base` 的下发先例。直接 `Window::new` 出来的窗口是
  /// `true`——与后端的默认同值（没登记过的窗口按开处理）。
  mut live_default : Bool
  /// 窗口位移的激活期插值账（`set_position_animated` 记，`App::pump_animations` 推）。
  mut move_anim : MoveSpan?
  /// 主题底样式（§15/§16 层叠最外层），由 `App::create_window` 填入、
  /// `App::set_theme` 刷新。直接 `Window::new` 出来的窗口是 `Style::empty()`。
  mut style_base : Style
  mut content : Widget[B]?
  /// Core 侧记的**上一次已知原点**（`T89` 吸附）。为什么要缓存这一份，破了
  /// "Core 不缓存窗口状态"的规矩：原生报上来的 Moved 只有**新**原点，而
  /// "把邻居带走多少"要的是**位移**——没有"上一次在哪"就算不出 delta。
  /// 它只由 Core 写（`set_position`、位移动画泵、Moved 回写），用户拖窗不经过
  /// Core 时也一定先有一条 Moved 把新原点带回来，所以不会和原生分叉。
  mut last_origin : LogicalPoint
  /// 显隐镜像（`T89`）：吸附只带走**此刻真在屏幕上**的窗——收起的均衡器/迷你条
  /// 不该被别的窗拖着在看不见的地方乱跑。显隐只有 Core 会改（`show` / `hide`；
  /// 用户点关闭走 Close → `release`），所以这份镜像不会漂。
  mut visible : Bool
}

///|
/// 标题栏样式（§12）。`Standard` 是后端建窗的默认（mac 的标准标题栏、Windows 的
/// 标准标题栏）；`Immersive` 是"沉浸式"——标题栏透明、内容铺满整个窗口、红绿灯
/// 浮在内容上（mac 的 `fullSizeContentView` + `titlebarAppearsTransparent` +
/// `titleVisibility = .hidden`）。Windows 没有红绿灯，`Immersive` 在那侧是空操作，
/// 留这条是为了跨平台 API 一致（调用方不用按平台分叉）。
///
/// `pub(all)`：包外要能构造这两个值（`pub enum` 对包外只读，`AlertType` 同一条规则）。
pub(all) enum TitlebarStyle {
  Standard
  Immersive
} derive(Debug, Eq)

///|
/// 文档 §12 的 `Window::new(title, width, height)`。尺寸是逻辑像素（§30）。
///
/// 建好就**默认居中**到窗口所在那块屏的可用区（§12，复用 `center`）：不显式
/// `set_position` 的窗口落在屏幕中央，而不是后端建窗的默认点——libui-ng 的
/// darwin 后端把内容区写死在 `(0,0)`（Cocoa 的左下角），windows 后端用
/// `CW_USEDEFAULT` 让系统级联（史注：`T82` 删 libui 前量的账），两个平台各落各的、
/// 都不居中。Core 在这里统一掉，
/// 后端那半的默认点从此不再决定窗口开在哪。之后调 `set_position` 仍然赢：
/// 默认居中只在"没设位置"时生效。
pub fn[B : Backend] Window::new(
  backend : B,
  title : String,
  size : LogicalSize,
) -> Window[B] raise UiError {
  let handle = Backend::create_window(backend, title, size)
  let win = Window::{
    backend,
    handle,
    closed: false,
    min_size: None,
    max_size: None,
    live_redraw: None,
    live_default: true,
    move_anim: None,
    style_base: Style::empty(),
    content: None,
    last_origin: LogicalPoint(0.0, 0.0),
    visible: false,
  }
  win.center()
  win
}

///|
pub fn[B] Window::handle(self : Window[B]) -> NativeHandle {
  self.handle
}

///|
/// 事件订阅用的目标。id 与句柄一致，`App::on_event(win.target(), ...)` 就能收到
/// 这个窗口的 Close/Resize（§10）。
pub fn[B] Window::target(self : Window[B]) -> EventTarget {
  EventTarget::of(self.handle)
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
  self.visible = true
}

///|
pub fn[B : Backend] Window::hide(self : Window[B]) -> Unit raise UiError {
  let h = self.check_open()
  Backend::hide_window(self.backend, h)
  self.visible = false
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
/// 设置尺寸：先按 Core 的 min/max 夹紧，再交给后端，**设完立刻重排一次**。
///
/// 为什么要在这里补重排：原生后端把「程序化改尺寸」的回声挡掉了
/// （`suppress_resize`，见 adapter.h 的 on_resized 契约——建窗时 Core 会纠正一次
/// 尺寸，那次不该变成 Resize 事件）。于是用户拖窗格有 Resize 事件、内容跟着
/// 重排，而程序化 `set_size` 只改外框、内容还按旧尺寸画：最典型的就是「复位
/// 窗口」——外框缩回默认宽度，里面仍是拖拽后的宽度，右侧露出一条空带，原生
/// 输入框还飘在空带里。夹紧后的实际尺寸由后端说了算，`relayout` 读的就是它。
pub fn[B : Backend] Window::set_size(
  self : Window[B],
  size : LogicalSize,
) -> Unit raise UiError {
  let h = self.check_open()
  Backend::set_window_size(self.backend, h, self.clamped(size))
  self.relayout()
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
  let _ = self.check_open()
  self.push_position(origin)
}

///|
/// 位置落地并记下"上一次已知原点"（`T89` 吸附算位移用）。所有改位置的路径
/// 都走这条：`set_position` 与位移动画泵。原生层把程序化移动的回声抑制掉了
/// （与 `suppress_resize` 同一条约定），所以这里不会回成一条 Moved。
fn[B : Backend] Window::push_position(
  self : Window[B],
  origin : LogicalPoint,
) -> Unit raise UiError {
  Backend::set_window_position(self.backend, self.handle, origin)
  self.last_origin = origin
}

///|
pub fn[B : Backend] Window::position(
  self : Window[B],
) -> LogicalPoint raise UiError {
  let h = self.check_open()
  Backend::window_position(self.backend, h)
}

///|
/// 窗口**位移动画**：从当下位置平滑滑到 `p`（复位窗口这类"把窗送到位"的场景，
/// 瞬移看着像闪了一下）。尺寸不在这条账里——要连尺寸一起换就先 `set_size`
/// （当场落，内容跟着重排）再来滑位置。
///
/// 时长与曲线沿隐式动画的默认档（300ms、EaseInOut）。**落点由动画泵兑现**
/// （`App::step` 收尾那一圈，`T84` 的泵）：没接帧钟时那一圈直接落到 `p`，
/// 等于瞬移（与无动画逐位同值）；系统"减少动态效果"开着同样直接落。
/// 动画期间 `position()` 读到的是中途值，落点后才是 `p`。要瞬移用
/// `set_position`。中途再调一次从**当下**位置续跑（被中断不跳变）。
pub fn[B : Backend] Window::set_position_animated(
  self : Window[B],
  p : LogicalPoint,
) -> Unit raise UiError {
  let h = self.check_open()
  let from = Backend::window_position(self.backend, h)
  if from == p {
    return
  }
  self.move_anim = Some(MoveSpan::{
    curve: EaseInOut,
    start_ms: -1,
    from,
    to: p,
  })
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
/// 设置客户区最小尺寸（`None` 清掉限制）。
///
/// 三件事，顺序不能换：
/// 1. 先按"min 不得大于 max"校验（矛盾配置当场报，§33）；
/// 2. 记进 Core 并**推给原生层**——用户拖窗格不经过 Core，只有原生的钳位
///    （mac `contentMinSize` / Win32 `WM_GETMINMAXINFO`）挡得住窗口被拖成一条缝；
/// 3. 窗口当下比下限还小就当场抬上去：系统不会因为设了下限就自动长大，而一个
///    "下限 500、实际 300"的窗口下一次被拖到 400 时仍会被当成合规，看着像下限
///    没生效。
///
/// 夹紧用的是 `clamped`，所以 `size` 读到的、推给后端的都是同一条账。
pub fn[B : Backend] Window::set_min_size(
  self : Window[B],
  size : LogicalSize?,
) -> Unit raise UiError {
  let h = self.check_open()
  match (size, self.max_size) {
    (Some(lo), Some(hi)) => check_size_pair(lo, hi)
    _ => ()
  }
  self.min_size = size
  Backend::set_window_min_size(self.backend, h, size)
  match size {
    Some(lo) => {
      let now = Backend::window_size(self.backend, h)
      if now.width < lo.width || now.height < lo.height {
        self.set_size(lo)
      }
    }
    None => ()
  }
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
/// 拖拽改尺寸时是否**实时重排**（live redraw）的显式覆盖。
///
/// `None` = 继承 App 的默认（`App::live_redraw`，默认开），`Some(v)` = 这只窗
/// 定死。为什么要有覆盖层："应用整体想关"与"这只窗特别重、单独关"是两种
/// 真实需求，App 改默认时只刷没覆盖的窗——覆盖过的不许被冲掉。
///
/// 开 = 拖拽过程中内容跟着窗走（体验好）；关 = 拖拽期间不动、松手后补一次
/// 重排（复杂应用拖起来卡时关它）。落地细节见 `Backend::set_window_live_redraw`。
pub fn[B : Backend] Window::set_live_redraw(
  self : Window[B],
  on : Bool?,
) -> Unit raise UiError {
  let h = self.check_open()
  self.live_redraw = on
  Backend::set_window_live_redraw(
    self.backend,
    h,
    on.unwrap_or(self.live_default),
  )
}

///|
/// 显式覆盖值（`None` = 在继承 App 的默认）。生效值就是后端那份——
/// 测试走 `MockBackend::window_live_redraw` 对表。
pub fn[B] Window::live_redraw(self : Window[B]) -> Bool? {
  self.live_redraw
}

///|
/// App 专用（沿 `refresh_style_base` 的先例，放出去只会多一条"设了默认但没人
/// 推给后端"的路径）：下发全局默认。**有显式覆盖的窗不动**——覆盖优先于默认。
fn[B : Backend] Window::refresh_live_default(
  self : Window[B],
  v : Bool,
) -> Unit raise UiError {
  self.live_default = v
  if self.live_redraw is None {
    Backend::set_window_live_redraw(self.backend, self.handle, v)
  }
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
/// 窗口态快照（`T86②`）：最小化与最大化两个位。读回口径是"读当下态"而非
/// 推送式——批三的窗口持久化（`T86⑦`）要的是"存档时刻窗口是什么态"，问一次
/// 拿一份快照正合适；原生层是唯一事实来源，Core 不缓存。
pub(all) struct WindowState {
  minimized : Bool
  maximized : Bool
} derive(Debug, Eq)

///|
/// 最小化到任务栏/Dock。最小化窗口的管理是窗口系统的事，调用方只在事件循环
/// 里发这条意图；`false` 恢复（mac 的 deminiaturize、Win32 的 SW_RESTORE）。
pub fn[B : Backend] Window::set_minimized(
  self : Window[B],
  v : Bool,
) -> Unit raise UiError {
  let h = self.check_open()
  Backend::set_window_minimized(self.backend, h, v)
}

///|
/// 最大化铺满工作区。`false` 恢复原尺寸（mac 的 zoom 位、Win32 的
/// SW_RESTORE——两侧都由原生层记"进最大化之前是什么样"）。
pub fn[B : Backend] Window::set_maximized(
  self : Window[B],
  v : Bool,
) -> Unit raise UiError {
  let h = self.check_open()
  Backend::set_window_maximized(self.backend, h, v)
}

///|
/// 读回当下的窗口态（`T86②`）：原生层是唯一事实来源，这份快照就是读数本身。
pub fn[B : Backend] Window::window_state(
  self : Window[B],
) -> WindowState raise UiError {
  let h = self.check_open()
  Backend::window_state(self.backend, h)
}

///|
/// 标题栏样式（§12）。`Immersive` 让内容铺满整个窗口、红绿灯浮在内容上（mac）；
/// Windows 没有红绿灯，这条在那侧是空操作。之后调 `set_titlebar_style(Standard)`
/// 可以切回标准标题栏。
pub fn[B : Backend] Window::set_titlebar_style(
  self : Window[B],
  style : TitlebarStyle,
) -> Unit raise UiError {
  let h = self.check_open()
  Backend::set_window_titlebar_style(self.backend, h, style)
}

///|
/// 红绿灯位置（§12）。`p` 是**关闭按钮左上角**相对**窗口左上角**的逻辑像素坐标，
/// mac 把三个红绿灯整簇挪过去（resize 时重新断言，AppKit 会在 resize 时把它们摆回
/// 默认位）；Windows 没有红绿灯，这条在那侧是空操作。
pub fn[B : Backend] Window::set_traffic_light_position(
  self : Window[B],
  p : LogicalPoint,
) -> Unit raise UiError {
  let h = self.check_open()
  Backend::set_window_traffic_light_position(self.backend, h, p)
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
/// 居中到**这只窗口当下所在那块屏**的可用区域。窗口大于那块屏时偏移夹为零，不产生
/// 负坐标（§12）。
///
/// 这里原先用的是 `Backend::screen_size`，那条按定义只有主屏（mac 的 `mainScreen`、
/// Win32 的 `SPI_GETWORKAREA`），于是一只在副屏上的窗口会被摆回主屏中央——`T42`。
/// `window_work_area` 的坐标空间就是同一个后端摆位那套（trait 上那条注释与 `adapter.h`
/// 写明了两平台这个空间本身不同），所以算出来的点交给 `set_position` 才落得回这块屏。
pub fn[B : Backend] Window::center(self : Window[B]) -> Unit raise UiError {
  let area = Backend::window_work_area(self.backend, self.handle)
  let size = self.size()
  let spot = area.center(size)
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
    None => LogicalSize(Infinity, Infinity)
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
  let win = Window::new(b, "MoonUI", LogicalSize(800.0, 600.0))
  (b, win)
}

///|
test "窗口属性读写都走 Backend，Core 不缓存" {
  let (b, win) = mock_window()
  assert_eq(win.size(), LogicalSize(800.0, 600.0))
  assert_false(b.window(win.handle()).visible)
  win.show()
  assert_true(b.window(win.handle()).visible)
  win.hide()
  assert_false(b.window(win.handle()).visible)
  win.set_title("MoonUI — Counter")
  assert_eq(b.window(win.handle()).title, "MoonUI — Counter")
  win.set_position(LogicalPoint(30.0, 40.0))
  assert_eq(win.position(), LogicalPoint(30.0, 40.0))
  win.set_resizable(false)
  assert_false(b.window(win.handle()).resizable)
  win.set_fullscreen(true)
  assert_true(b.window(win.handle()).fullscreen)
  assert_false(win.is_closed())
}

///|
test "min/max 在 Core 侧夹紧后再交给后端" {
  let (_b, win) = mock_window()
  win.set_min_size(Some(LogicalSize(200.0, 100.0)))
  win.set_max_size(Some(LogicalSize(600.0, 400.0)))
  win.set_size(LogicalSize(50.0, 5000.0))
  assert_eq(win.size(), LogicalSize(200.0, 400.0))
  win.set_size(LogicalSize(-10.0, 250.0))
  // 负值先归零，再被最小尺寸抬起来
  assert_eq(win.size(), LogicalSize(200.0, 250.0))
  assert_eq(win.min_size(), Some(LogicalSize(200.0, 100.0)))
  assert_eq(win.sync_size(LogicalSize(9999.0, 10.0)), LogicalSize(600.0, 100.0))
  // sync_size 不回写后端，Resize 事件的原生值才是事实
  assert_eq(win.size().height, 250.0)
}

///|
test "最小尺寸大于最大尺寸时报错并保持原约束" {
  let (_b, win) = mock_window()
  win.set_max_size(Some(LogicalSize(300.0, 300.0)))
  let msg = try {
    win.set_min_size(Some(LogicalSize(400.0, 100.0)))
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("操作失败：窗口的最小尺寸大于最大尺寸"))
  assert_eq(win.min_size(), None)
  // 反过来设置同样被拦下
  win.set_min_size(Some(LogicalSize(100.0, 100.0)))
  let msg2 = try {
    win.set_max_size(Some(LogicalSize(50.0, 500.0)))
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
  assert_eq(win.position(), LogicalPoint(560.0, 240.0))
  MockBackend::set_screen_size(b, LogicalSize(400.0, 300.0))
  win.center()
  assert_eq(win.position(), LogicalPoint(0.0, 0.0))
}

///|
/// `T42`：居中问的是**这只窗口那块屏**的可用区，不是主屏。三发按顺序钉三件事——
/// 没注入时退回整块虚拟屏（单屏机器的形状，所以上面那条旧断言的数一个都不许变）、
/// 注入一块副屏后中心落在那块屏内、以及副屏的 origin 为负时同样落得回去
/// （Win32 上副屏在主屏左边或上边，`GetMonitorInfo` 报的就是负数）。
test "center 用窗口自己那块屏的工作区，主屏那条只当默认" {
  let (b, win) = mock_window()
  win.center()
  assert_eq(win.position(), LogicalPoint(560.0, 240.0))
  MockBackend::set_window_work_area(
    b,
    win.handle(),
    LogicalRect(LogicalPoint(1920.0, 0.0), LogicalSize(1280.0, 960.0)),
  )
  win.center()
  assert_eq(win.position(), LogicalPoint(2160.0, 180.0))
  MockBackend::set_window_work_area(
    b,
    win.handle(),
    LogicalRect(LogicalPoint(-1280.0, -200.0), LogicalSize(1280.0, 1000.0)),
  )
  win.center()
  assert_eq(win.position(), LogicalPoint(-1040.0, 0.0))
  // 另一只窗口没注入过，仍在虚拟屏中央：work_area 是按窗口的，不是进程全局的
  let other = b.create_window("另一只", LogicalSize(800.0, 600.0))
  assert_eq(
    b.window_work_area(other),
    LogicalRect(LogicalPoint(0.0, 0.0), LogicalSize(1920.0, 1080.0)),
  )
}

///|
/// 默认居中（§12）：`Window::new` 建好就落在窗口所在那块屏的可用区中央，
/// 不再由后端建窗的默认点决定（沿 libui 时代的账：darwin 写死 `(0,0)` = Cocoa 左下角、
/// windows 用 `CW_USEDEFAULT` 级联，两个平台各落各的）。mock 的虚拟屏是
/// 1920x1080，800x600 的窗口居中后原点是 (560, 240)——和上面 `center` 那条
/// 的数同一条公式。之后 `set_position` 仍然赢：默认居中只在"没设位置"时生效。
test "Window::new 默认居中，set_position 之后仍由调用方说了算" {
  let (_, win) = mock_window()
  // 建好即居中，不调 center() 也不调 set_position()
  assert_eq(win.position(), LogicalPoint(560.0, 240.0))
  // 显式设位置覆盖默认
  win.set_position(LogicalPoint(30.0, 40.0))
  assert_eq(win.position(), LogicalPoint(30.0, 40.0))
  // 再 center() 一次回到中央（幂等，和上面 center 那条同一条公式）
  win.center()
  assert_eq(win.position(), LogicalPoint(560.0, 240.0))
}

///|
test "physical_size 按窗口缩放因子换算（§30）" {
  let (b, win) = mock_window()
  assert_eq(win.physical_size(), PhysicalSize(800, 600))
  MockBackend::set_window_scale(b, win.handle(), Scale::{ x: 2.0, y: 2.0, })
  assert_eq(win.scale(), Scale::{ x: 2.0, y: 2.0, })
  assert_eq(win.physical_size(), PhysicalSize(1600, 1200))
}

///|
test "Window::target 与句柄同 id，供 App 按窗口订阅" {
  let (_b, win) = mock_window()
  assert_eq(win.target(), EventTarget::of(win.handle()))
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
  // T74：叶子不再一律挂窗口——Scroll 认领自己的子树（挂进文档区），
  // 其余仍然挂窗口。先序收集，挂接顺序仍是声明顺序（Tab 序，§14）。
  let pairs : Array[(NativeHandle?, NativeHandle)] = []
  root.collect_attach(None, pairs)
  for pair in pairs {
    match pair.0 {
      None => Backend::attach_widget(self.backend, h, pair.1)
      Some(container) =>
        Backend::attach_widget_to(self.backend, container, pair.1)
    }
  }
  // 层叠由 Core 算整份推下去（`T29`）：先序、Stack 子树倒序，规则在 `paint_order`。
  let order : Array[NativeHandle] = []
  root.paint_order(order)
  Backend::set_paint_order(self.backend, h, order)
  // 焦点链也交给 Core 算（`T29`）：就是声明顺序（先序），`collect_native` 收出来的
  // 就是它。不含 Stack 的树它和 `order` 同值；Stack 里两者分道——
  // 层叠倒序、焦点声明序，Tab 不再跟着层叠翻。
  let leaves : Array[NativeHandle] = []
  root.collect_native(leaves)
  Backend::set_focus_chain(self.backend, h, leaves)
  self.relayout()
}

///|
pub fn[B] Window::content(self : Window[B]) -> Widget[B]? {
  self.content
}

///|
/// 按坐标命中控件（§10 的鼠标路由，`T39` 的鼠标那一半）：穿一遍内容树，返回绘制顺序里
/// 最后一个 `frame()` 含住这个点的叶子；命不中就返回 `None`。
///
/// - 那个点是**以窗口内容区左上角为原点**的逻辑像素，和 `Widget::frame()` 同一个空间，
///   也就是 `set_bounds` 推给后端的那份矩形（§14）。原生层报上来的鼠标坐标是物理的，
///   换成这里的数是调用方的活（`T39` 的鼠标那半在后端里除以该窗口的 Scale，§30）。
/// - 判据只有叶子那一份：Core 里纯布局节点没有矩形（`do_layout` 写回的是带 id 的 `Placed`
///   项，而布局节点没有句柄也没有 id），所以 `Scroll` 的视口不在这里裁——超出视口的内容
///   仍然算命中。滚动偏移本来就属于后端、Core 不存（§14），这条是那份边界在这里的直接
///   后果，不是这里新加的洞。
/// - 纯布局节点（Row / Column / Stack / …）穿过但不返回，它们没有句柄、收不到原生事件（§14）。
pub fn[B] Window::widget_at(self : Window[B], p : LogicalPoint) -> Widget[B]? {
  match self.content {
    Some(root) => root.hit_test(p)
    None => None
  }
}

///|
/// 用窗口当前尺寸重算整棵内容树的绝对边界。Resize 事件走这里（§12/§14）。
///
/// 顺序是"先推样式、再布局"（§15/§16）：`do_layout` 要问后端每个叶子的固有尺寸，
/// 而那份尺寸是后端在当下这份样式下量出来的，样式晚推一步就会拿到旧字号的度量。
pub fn[B : Backend] Window::relayout(self : Window[B]) -> Unit raise UiError {
  match self.content {
    Some(root) => {
      // 底样式先于逐控件样式推（皮肤账）：原生后端拿它做"继承 vs 显式"
      // 的分野——Button 这类保原生外观的 kind 只消费与底不同的字段。
      Backend::set_theme_base(self.backend, self.style_base)
      root.apply_styles(self.style_base)
      let _ = root.do_layout(LogicalRect(LogicalPoint(0.0, 0.0), self.size()))
      root.needs_layout = false
    }
    None => ()
  }
}

///|
/// 换主题底样式并立刻重排（§16）。`App` 专用：窗口自己不知道主题，层叠的起点在
/// `App::style_base`，所以这里不公开——放出去只会多一条"设了样式但没人刷新内容"的路径。
fn[B : Backend] Window::refresh_style_base(
  self : Window[B],
  base : Style,
) -> Unit raise UiError {
  self.style_base = base
  self.relayout()
}

///|
/// 动画泵的位移推进（`T84` 的窗口半条）：与 `Widget::pump_anim_tree` 同一套
/// 规则——`start_ms < 0` 是起跑圈（补记时刻、零推送，后端此刻正停在 from），
/// 中间帧线性混合，退场推**精确的 to** 不做插值（浮点上 `lerp(a,b,1)` 未必
/// 逐位等 b，判据靠这条绕行）。返回 (本圈是否真的挪过、还剩几条账)。
fn[B : Backend] Window::pump_move_anim(
  self : Window[B],
  now : Int32,
) -> (Bool, Int32) raise UiError {
  if self.closed {
    self.move_anim = None
    return (false, 0)
  }
  match self.move_anim {
    Some(s) => {
      let elapsed = if s.start_ms < 0 {
        s.start_ms = now
        0
      } else {
        now - s.start_ms
      }
      if elapsed >= ANIMATION_DURATION_MS {
        self.push_position(s.to)
        self.move_anim = None
        (true, 0)
      } else if elapsed > 0 {
        let k = s.curve.progress(
          elapsed.to_double() / ANIMATION_DURATION_MS.to_double(),
        )
        self.push_position(anim_lerp_point(s.from, s.to, k))
        (true, 1)
      } else {
        (false, 1)
      }
    }
    None => (false, 0)
  }
}

///|
/// 没接帧钟 / 系统"减少动态效果"开着时的退化路径：当圈直接落到**精确落点**、
/// 账清零——变更点即落点，与无动画窗口逐位同值（`T84` 判据④的同一条绕行）。
fn[B : Backend] Window::retire_move_anim(
  self : Window[B],
) -> (Bool, Int32) raise UiError {
  match self.move_anim {
    Some(s) => {
      self.move_anim = None
      if self.closed {
        (false, 0)
      } else {
        self.push_position(s.to)
        (true, 0)
      }
    }
    None => (false, 0)
  }
}

///|
/// 按事件目标在内容树里找控件；`App::dispatch` 用它把事件路由到控件 handler。
/// 比的是整个 `EventTarget`（id + generation，`T49`）：id 复用之后，拿着旧代
/// target 的事件不许再路由到同一 id 的新控件上。只有 Core 内部需要，不放进
/// 公共 API。
fn[B] Window::find_widget(self : Window[B], t : EventTarget) -> Widget[B]? {
  match self.content {
    Some(root) => root.find_by_target(t)
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
  win.set_size(LogicalSize(200.0, 100.0))
  (b, win)
}

///|
/// 测试用：窗口的层叠顺序，按句柄 id 从顶层到底层列出。
fn z_ids(
  b : MockBackend,
  win : Window[MockBackend],
) -> Array[Int32] raise UiError {
  let out : Array[Int32] = []
  for h in b.child_z_order(win.handle()) {
    out.push(h.id)
  }
  out
}

///|
/// 测试用：控件的句柄 id。布局节点没有句柄，拿不到就是测试自己写错了树。
fn handle_id(w : Widget[MockBackend]) -> Int32 raise UiError {
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
  assert_eq(
    label.bounds(),
    LogicalRect(LogicalPoint(0.0, 0.0), LogicalSize(24.0, 20.0)),
  )
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
  let other = Window::new(b, "Other", LogicalSize(100.0, 100.0))
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
  Backend::set_window_size(b, win.handle(), LogicalSize(100.0, 100.0))
  win.handle_event(Event::Resize(win.target(), LogicalSize(100.0, 100.0)))
  assert_eq(win.size(), LogicalSize(100.0, 100.0))
  assert_eq(label.bounds().origin.x, 76.0)
  assert_eq(label.bounds().origin.y, 0.0)
}

///|
/// 程序化 `set_size` 要当场重排：原生层把这次改尺寸的回声挡掉了
/// （`suppress_resize`），不补重排的话外框变了、内容还按旧尺寸画。「复位窗口」
/// 之后右侧露出一条空带就是这么来的——播放列表被拖窄过，复位只改了外框。
test "set_size 当场重排内容（不依赖 Resize 回声）" {
  let (b, win) = content_window()
  let sp = Widget::spacer(b)
  let label = Widget::label(b, "Ab")
  win.set_content(Widget::row(b, 0.0, [sp, label]))
  assert_eq(label.bounds().origin.x, 176.0)
  win.set_size(LogicalSize(100.0, 100.0))
  assert_eq(win.size(), LogicalSize(100.0, 100.0))
  assert_eq(label.bounds().origin.x, 76.0)
}

///|
/// 最小尺寸有两条路要走：一条进 Core（`clamped` 挡程序化改尺寸），另一条
/// **必须推到原生层**——用户拖窗格不经过 Core（Resize 是"已经拖完了"的回报），
/// 只记在 Core 里的话窗口照样能被拖成一条缝，内容挤成一团。
/// 另外"当下比下限还小"要当场抬上来：系统不会因为设了下限就自己长大。
test "set_min_size：推到后端，并把比下限还小的窗口抬上来" {
  let (b, win) = content_window()
  // 200×100 的窗先设 400×250 的下限 → 当场长大
  win.set_min_size(Some(LogicalSize(400.0, 250.0)))
  assert_eq(win.min_size(), Some(LogicalSize(400.0, 250.0)))
  assert_eq(b.window_min_size(win.handle()), Some(LogicalSize(400.0, 250.0)))
  assert_eq(win.size(), LogicalSize(400.0, 250.0))
  // 程序化改尺寸被夹在下限上（Core 那半）
  win.set_size(LogicalSize(120.0, 80.0))
  assert_eq(win.size(), LogicalSize(400.0, 250.0))
  // 清掉限制是 None，原生层收到 None（真后端把它落成 (0, 0)）
  win.set_min_size(None)
  assert_eq(win.min_size(), None)
  assert_eq(b.window_min_size(win.handle()), None)
  win.set_size(LogicalSize(120.0, 80.0))
  assert_eq(win.size(), LogicalSize(120.0, 80.0))
}

///|
/// live redraw 的两层配置：App 是全局默认（默认开），Window 的 `Some` 是显式
/// 覆盖、`None` 回到继承。覆盖优先——App 改默认不许冲掉窗口定死的值。
test "live_redraw：App 默认开、Window 覆盖优先、清掉回继承" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  assert_true(app.live_redraw())
  let w1 = app.create_window("a", LogicalSize(200.0, 100.0))
  let w2 = app.create_window("b", LogicalSize(200.0, 100.0))
  // 建窗就带上下发的默认（开）；覆盖位是 None = 在继承
  assert_eq(w1.live_redraw(), None)
  assert_true(b.window_live_redraw(w1.handle()))
  assert_true(b.window_live_redraw(w2.handle()))
  // w1 显式定死开；全局改关——覆盖的不动，没覆盖的跟
  w1.set_live_redraw(Some(true))
  app.set_live_redraw(false)
  assert_false(app.live_redraw())
  assert_true(b.window_live_redraw(w1.handle()))
  assert_false(b.window_live_redraw(w2.handle()))
  // 清掉覆盖 → 回到继承（此刻全局是关）
  w1.set_live_redraw(None)
  assert_eq(w1.live_redraw(), None)
  assert_false(b.window_live_redraw(w1.handle()))
  // 全局改回开 → 没覆盖的都跟
  app.set_live_redraw(true)
  assert_true(b.window_live_redraw(w1.handle()))
  assert_true(b.window_live_redraw(w2.handle()))
}

///|
/// live redraw 的兑现点在**拖拽的同步栈**上（`push_live_resize` 模拟拖拽）：
/// 开着 = 一拖当场重排（内容跟手）；关着 = 拖拽期间内容不动，松手后（`step`）
/// 补一次，且 N 记拖拽只补**一次**——攒下的旧 Resize 合并成最新一份（关掉实时
/// 的复杂应用要的是"松手后重排一次"，不是"松手后重排 N 次"）。
test "live_redraw：开着当场重排，关了等事件循环且旧报告合并" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let win = app.create_window("t", LogicalSize(200.0, 100.0))
  let sp = Widget::spacer(b)
  let label = Widget::label(b, "Ab")
  win.set_content(Widget::row(b, 0.0, [sp, label]))
  // 200 宽里 Spacer 吃掉 176，标签贴在右端
  assert_eq(label.bounds().origin.x, 176.0)
  // 开着（默认）：一拖当场重排，不等事件循环
  b.push_live_resize(win.handle(), LogicalSize(100.0, 100.0))
  assert_eq(label.bounds().origin.x, 76.0)
  // 关掉：连拖三次都只改外框，内容不动
  win.set_live_redraw(Some(false))
  b.push_live_resize(win.handle(), LogicalSize(300.0, 100.0))
  b.push_live_resize(win.handle(), LogicalSize(260.0, 100.0))
  b.push_live_resize(win.handle(), LogicalSize(240.0, 100.0))
  assert_eq(label.bounds().origin.x, 76.0)
  // 用户订阅也只收到一条（合并后的最新那份 240）
  let hits : Array[Double] = []
  let _ = app.on_event(win.target(), fn(ev) {
    match ev {
      Resize(_, s) => hits.push(s.width)
      _ => ()
    }
  })
  let mut steps = 0
  while app.step() && steps < 10 {
    steps = steps + 1
  }
  assert_eq(hits, [240.0])
  assert_eq(label.bounds().origin.x, 216.0)
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
  assert_eq(win.physical_size(), PhysicalSize(200, 100))
  MockBackend::set_window_scale(b, win.handle(), Scale::{ x: 2.0, y: 2.0, })
  Backend::set_window_size(b, win.handle(), LogicalSize(100.0, 50.0))
  win.handle_event(ScaleChanged(win.target(), Scale::{ x: 2.0, y: 2.0, }))
  assert_eq(label.bounds().origin.x, 76.0)
  // 物理尺寸跨 DPI 变化保持不变，这正是 HiDPI 的全部意义
  assert_eq(win.physical_size(), PhysicalSize(200, 100))
}

///|
/// 后端 DPI 字段没初始化就返回 0.0：窗口层夹紧到 1.0，
/// 不能让除零把布局变成 Infinity（§47 第 5 条）。
test "非法的后端缩放因子在窗口层被夹紧" {
  let (b, win) = mock_window()
  MockBackend::set_window_scale(b, win.handle(), Scale::{ x: 0.0, y: -2.0, })
  assert_eq(win.scale(), Scale::one())
  assert_eq(win.physical_size(), PhysicalSize(800, 600))
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
  assert_eq(lb, PhysicalRect(PhysicalPoint(0, 0), PhysicalSize(48, 40)))
  // 文案 20 逻辑高 + 6 逻辑间距 = 26 逻辑 -> 52 物理：间距也按同一因子放大，
  // 所以 2x 屏上留白是 12 物理像素，不会退化成 1x 屏上的 6
  assert_eq(bb.origin.y, 52)
  assert_eq(bb.origin.y - (lb.origin.y + lb.size.height), 12)
  assert_eq(bb.size, PhysicalSize(80, 56))
}
