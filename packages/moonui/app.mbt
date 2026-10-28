///|
/// App 与事件循环（设计文档 §11、§27，开发顺序 §48 第 07/08 步：Lifecycle + App）。
///
/// 本版本 MoonBit 的 trait 不是类型、也没有 `dyn`，所以 App 对后端做**静态分发**：
/// `App[MockBackend]` 用于无头测试，真后端是 `App[NativeBackend]`（经前台门
/// `@moonui_app.new_app()` 拿）。
/// 后端因此是编译期选定的，符合 §34/§35 "每个平台预编译对应后端" 的方向；
/// 代价是同一个 App 不能同时挂两个后端，也不能在运行期换后端。
///
/// `run()` 的退出契约（headless 与真实后端的差异必须写清楚）：
/// - 真实后端的 `poll_event` 阻塞到有事件或主循环关闭，返回 `None` 只表示"循环结束"；
/// - `MockBackend` 的队列空即返回 `None`，所以 `run()` 等于"把注入的事件排空"，
///   这让 §37 的集成测试在没有任何显示环境的 CI 上也能跑完整生命周期。
/// 两种情况下 `run()` 都不忙等：一整轮既没有任务也没有事件就退出。

///|
/// 一条事件订阅。handler 允许失败（控件操作本身就会 `raise UiError`），
/// 失败从 `dispatch` 传出并结束循环——App 不做"吞掉异常继续跑"的隐藏策略（§33）。
pub(all) struct Subscription {
  id : Int32
  target : EventTarget
  /// `T57`：种类过滤器，与控件级 `Widget::on` 的 `accept` 同形。
  /// target 只认"这只控件"，过滤器再筛"哪一种事件"——`on_event` 是恒真过滤器的糖。
  accept : (Event) -> Bool
  handler : (Event) -> Unit raise UiError
}

///|
/// 排队任务（`T85①`）的取消句柄。与订阅 id（`Subscription`）是两个独立编号空间；
/// seq 从 1 起，0 永不分配，所以"没有句柄"有明确的哨兵。
pub(all) struct TaskId {
  seq : Int32
} derive(Debug, Eq)

///|
/// `T86⑧` 长按判据的常量，默认值记案：
/// - `LONG_PRESS_DURATION_MS = 400`——按下后保持到这个毫数且未超移动阈值才补发
///   长按。取 Android `ViewConfiguration` 的 `LONG_PRESS_TIMEOUT`（400ms）同档；
///   iOS 用 500ms，两者都在"手指没有在点、也没有在拖"的人类节奏上，400 是
///   更跟手的那档，也是各平台里常见的默认。
/// - `LONG_PRESS_MOVE_THRESHOLD = 8.0`（逻辑像素）——移动超过这个距离取消识别。
///   取触摸 slop 的惯用档（Android `TouchSlop` 一档、逻辑 8pt）：低于它仍算
///   "按住没动"，高于它就是拖动手势的开始。
///
/// 两个都是框架默认值，不做配置口——判据钉的就是这对默认下的行为。
pub const LONG_PRESS_DURATION_MS : Int32 = 400

///|
/// 见上：移动阈值（逻辑像素），超出即取消（按下点的距离，不是增量）。
pub const LONG_PRESS_MOVE_THRESHOLD : Double = 8.0

///|
/// 一条还在识别中的按住（`T86⑧`）：谁收到的 `MouseDown`、按下点在哪、
/// 时刻注入（`T84` 先例）读到的是第几毫。进程级鼠标监听只保证按下/抬起
/// 到达 MoonBit，"按了多久"由 Core 在这条账上计时，零 C。
struct PressPending {
  target : EventTarget
  start : LogicalPoint
  started : Int32
}

///|
/// 任务队列里的一条：句柄 + 任务本体。队列只被 UI 线程碰——跨线程投递走平台
/// 层的投递原语（后端侧），落到这条队列时已经是 UI 线程代码了（§47 风险 3 的
/// 收口：不加锁，靠"外来投递经投递原语变成 UI 线程投递"）。
struct PostedTask {
  id : TaskId
  task : () -> Unit raise UiError
}

///|
pub struct App[B] {
  backend : B
  mut subs : Array[Subscription]
  windows : Array[Window[B]]
  mut posted : Array[PostedTask]
  mut next_sub_id : Int32
  mut running : Bool
  mut quit_requested : Bool
  mut finished : Bool
  mut theme : Theme
  // T84 帧钟（加法）：时刻注入——动画泵的"当前时刻"从这里来，Core 一行不读
  // 时钟（不可测）。None 默认 = 动画退化为"变更点当圈直接落"，与无动画树
  // 逐位同值；前台门注入平台的钟（native 是现成的 native_time_ms），Mock
  // 测试注入自控的参数。
  mut anim_clock : (() -> Int32)?
  // T84 帧钟开关：激活→退场的切换沿各发一次 wake(active)。前台门用它把
  // 原生后端的等待预算换成 8ms 档（激活期）/ -1（退场后）；Mock 测试注入
  // 记录器，判据"激活期等待预算改短"就是断言它。None = 没人要听。
  mut anim_wake : ((Bool) -> Unit)?
  // 当前激活的动画账条数（泵每圈收拾）。0 = 无激活动画，泵一圈只花一次
  // 比较——"无激活动画零开销退回现状"。
  mut anim_active : Int32
  // §25 菜单栏与 §26 快捷键。菜单项自带的组合在 set_menubar 时展开成镜像表，
  // 这样按键命中不用每次重扫整棵菜单树。
  mut menubar : MenuBar?
  mut menu_accel : Array[MenuAccel]
  mut shortcuts : Array[ShortcutBinding]
  mut next_shortcut_id : Int32
  // `T85①`：任务句柄计数器，与订阅 id 分开记账（`TaskId` 从 1 起，0 是哨兵）。
  mut next_task_seq : Int32
  // `T86⑧`：识别中的按住（一条——单指档，第二根手指的 MouseDown 不另立账）。
  // None = 没有在识别。识别只在注入了时刻（`anim_clock`，`T84` 先例）时启动：
  // 没有时钟就推不出"按了多久"，识别整体缺席——与无激活动画零开销同一条规矩。
  mut press_pending : PressPending?
  // `T88①` 事件分发跟踪的 sink：None（默认）= 没开账，派发零分配零调用；
  // Some = 每次 dispatch 收尾把整条 `DispatchTrace` 流出。快照纪律见
  // trace.mbt 段注（派发起点快照，handler 中途换不影响本回合）。
  mut event_trace : ((DispatchTrace) -> Unit)?
  /// 悬停中的控件 target（皮肤账的悬停账）：MouseMove 目标换人时翻面。
  /// None = 不在任何控件上（空白/离开窗口）。
  mut hover : EventTarget?
  /// 拖拽改尺寸的实时重排开关（live redraw）的**全局默认**（默认开）。
  /// 窗口没显式覆盖（`Window::set_live_redraw` 的 `None`）就跟着这条；
  /// 改这条只刷没覆盖的窗（覆盖优先，见 `Window::refresh_live_default`）。
  mut live_redraw : Bool
  /// 吸附联动（`T89`）：开（默认）时，用户拖一只窗会把"贴着它"的其它窗按同样
  /// 位移一起带走；关掉就各走各的。分组不存表——每次移动按当下几何现算
  /// （见 `App::follow_move`）。
  mut dock : Bool
}

///|
/// 文档 §11 的 `App::new()`。因为后端是编译期参数，这里必须把后端实例交进来；
/// 真后端就位后（`T82` 删 libui 收敛单后端），默认形态是前台门
/// `@moonui_app.new_app()` 包好的 `App[NativeBackend]`。
///
/// 构造时顺手接上**实时直达通道**（`Backend::set_live_dispatch`）：拖拽跑在
/// 系统模态循环里（mac 的窗口跟踪循环、Win32 的 sizing 循环），`step` 被泵
/// 卡住、事件队列排不动——实时重排的 Resize 与吸附联动的 Moved 都从这条同步
/// 直达 `dispatch`，用户订阅、内容重排与邻居跟随都跟拖拽同一拍。处理器的失败
/// 由后端的 `push_resize` / `push_move` 就地吞（原生回调栈上没有传出 `UiError`
/// 的路）。
pub fn[B : Backend] App::new(backend : B) -> App[B] {
  let app = App::{
    backend,
    subs: [],
    windows: [],
    posted: [],
    next_sub_id: 0,
    running: false,
    quit_requested: false,
    finished: false,
    // §16：默认跟随系统，具体外观由 Backend 报告
    theme: System,
    // T84 帧钟默认没接：动画退化为变更点当圈直接落，零开销
    anim_clock: None,
    anim_wake: None,
    anim_active: 0,
    // §25/§26：菜单栏与其快捷键镜像表都在 App 侧，后端只持有安装副本
    menubar: None,
    menu_accel: [],
    shortcuts: [],
    next_shortcut_id: 0,
    next_task_seq: 1,
    press_pending: None,
    // `T88①`：分发跟踪默认关——旧路径零开销
    event_trace: None,
    hover: None,
    // live redraw 默认开：拖拽改尺寸时内容跟着窗走（体验优先）
    live_redraw: true,
    // 吸附联动默认开：拖一只窗带走贴着它的那些（体验优先）
    dock: true,
  }
  Backend::set_live_dispatch(
    backend,
    Some(fn(ev) raise UiError { let _ = app.dispatch(ev) }),
  )
  app
}

///|
/// T84 时刻注入：动画泵的"当前时刻"从这里来。Core 的动画模块一行不读时钟
/// （不可测），时刻由 pump 从平台拿到再传进插值账；Mock 测试里时刻是测试
/// 自控的参数——判据①逐帧断言的前提。不注入时动画退化为"变更点当圈直接落"。
pub fn[B] App::set_anim_clock(self : App[B], clock : () -> Int32) -> Unit {
  self.anim_clock = Some(clock)
}

///|
/// T84 帧钟开关：动画激活期各发一次 `wake(true)`、全部退场 `wake(false)`。
/// 前台门用它把原生后端的 poll_event 等待预算换成 8ms 档，让主循环每圈醒来
/// 推进插值；Mock 测试注入记录器，"激活期等待预算改短"的判据就是断言它。
pub fn[B] App::set_anim_wake(self : App[B], wake : (Bool) -> Unit) -> Unit {
  self.anim_wake = Some(wake)
}

///|
/// T84 动画泵：推进所有激活期的插值账，返回本圈是否真的推送过帧。
///
/// 零开销闸门：只读 root 的 `needs_anim` 旗标，无动画的树一次遍历都不花。
/// 帧钟开关沿激活/退场的切换沿发（上一圈的账条数 vs 这一圈收拾完的账条数）：
/// 0→n 发 `wake(true)`（前台门把预算换成 8ms 档），n→0 发 `wake(false)`
/// （恢复 -1，空闲的 GUI 不自己退出）。没帧钟时（`anim_clock` 为 None）-span
/// 当圈直接落：推精确的 to、账清零——与无动画树逐位同值。
fn[B : Backend] App::pump_animations(self : App[B]) -> Bool raise UiError {
  let had = self.anim_active > 0
  let mut pushed = false
  let mut active = 0
  for win in self.windows {
    if !win.is_closed() {
      match win.content {
        Some(root) =>
          if root.needs_anim {
            // T87③ reduced-motion 退场闸门（读口快照，不推送）：偏好开着，
            // 中间帧整体跳过——所有激活账当圈推**精确的 to**、账清零，显示值
            // 不停在中间态，与无动画树逐位同值。读口只在既有零开销闸门
            // （needs_anim）里花：无动画的树一次偏好读数都不多花。偏好开着
            // 的树记账当圈收拾（active 恒 0），激活沿从未真正立起——帧钟
            // 一次都不响；进行中的动画在这圈退场，wake(false) 沿既有切换沿
            // 发（预算恢复零开销）。偏好关 = 快照 false = 既有两条路径原样
            // （负控制：T84 既有判据块全程担任）。失败沿 UiError 传出——
            // 读口签名沿既有读口惯例，Mock/Native 的读不到都当 false，
            // 实际到不了这里。
            let (did, remain) = if Backend::get_prefers_reduced_motion(
                self.backend,
              ) {
              root.retire_anim_tree()
            } else {
              match self.anim_clock {
                Some(clock) => root.pump_anim_tree(clock())
                None => root.retire_anim_tree()
              }
            }
            if did {
              pushed = true
            }
            active = active + remain
            root.needs_anim = remain > 0
          }
        None => ()
      }
      // 窗口位移账（`set_position_animated` 记的那条）：与树账同一台泵、同一
      // 套退化规则——偏好开着/没接帧钟都当圈退场推精确落点，只是落点在窗口
      // 位置上（`MoveSpan` 段注）。零开销闸门同款：没有账一次偏好读数都不花。
      if win.move_anim is Some(_) {
        let (did, remain) = if Backend::get_prefers_reduced_motion(self.backend) {
          win.retire_move_anim()
        } else {
          match self.anim_clock {
            Some(clock) => win.pump_move_anim(clock())
            None => win.retire_move_anim()
          }
        }
        if did {
          pushed = true
        }
        active = active + remain
      }
    }
  }
  if had && active == 0 {
    self.fire_anim_wake(false)
  } else if !had && active > 0 {
    self.fire_anim_wake(true)
  }
  self.anim_active = active
  pushed
}

///|
/// T84：帧钟开关发沿。没接线（None）就是没人要听，什么都不发生。
fn[B] App::fire_anim_wake(self : App[B], active : Bool) -> Unit {
  match self.anim_wake {
    Some(w) => w(active)
    None => ()
  }
}

///|
/// 设置全局主题（§16 的 `app.set_theme(Theme::System)`）。
///
/// 变了之后已开的窗口立刻按新底样式重排：字体度量属于后端（§18），字号一改整棵树
/// 的矩形都可能跟着变，所以这条不能只改字段就返回。已关闭的窗口跳过——句柄已经
/// 归还，重排会打到失效句柄上。
pub fn[B : Backend] App::set_theme(
  self : App[B],
  t : Theme,
) -> Unit raise UiError {
  self.theme = t
  let base = self.style_base()
  for w in self.windows {
    if !w.is_closed() {
      w.refresh_style_base(base)
    }
  }
}

///|
/// 用户请求的主题，可能仍是 `System`（尚未解析成配色）。
pub fn[B] App::theme(self : App[B]) -> Theme {
  self.theme
}

///|
/// 拖拽改尺寸的实时重排开关（live redraw）的**全局默认**（默认开）。
/// 窗口层没显式配置（`Window::set_live_redraw(None)`）就继承这条；
/// 窗口层 `Some(v)` 定死的不随它动。语义细节见 `Window::set_live_redraw`。
pub fn[B] App::live_redraw(self : App[B]) -> Bool {
  self.live_redraw
}

///|
/// 改全局默认，并刷给所有**没有显式覆盖**的存活窗（覆盖优先——用户在
/// Window 层定死的不许被这里的改动冲掉）。新开的窗由 `create_window`
/// 落地时就带上这条。
pub fn[B : Backend] App::set_live_redraw(
  self : App[B],
  on : Bool,
) -> Unit raise UiError {
  self.live_redraw = on
  for w in self.windows {
    if !w.is_closed() {
      w.refresh_live_default(on)
    }
  }
}

///|
/// 设置应用图标（§26）。`name` 是**不带扩展名的文件名**（stem）：mac 侧补
/// `.png`、Windows 侧补 `.ico`，调用方只写一份路径就能两边通用。相对进程
/// CWD 解析，建议在 `create_window` 之前调用——之后新建的窗口才会带上它。
///
/// **macOS 会按系统图标网格补留白**：满幅的 PNG（内容贴到四边）先量 alpha
/// 包围盒、再按 Apple 的 824/1024 重排到透明画布上，主体只占画布约 80.5%。
/// 这不是美化——Dock 与 Cmd-Tab 把图标当整块画布摆，四边贴满的图会明显比
/// 邻居大一圈。已经留够白的图（主体 ≤86%）原样使用，不会被反复缩小。
pub fn[B : Backend] App::set_icon(
  self : App[B],
  name : String,
) -> Unit raise UiError {
  Backend::set_app_icon(self.backend, name)
}

///|
/// 系统托盘图标（`T86⑥`）：参数沿 `set_icon` 的 stem 约定（平台各自补
/// `.png`/`.ico`）。托盘是进程级单例，一个应用一只，不占句柄表。
pub fn[B : Backend] App::set_tray_icon(
  self : App[B],
  name : String,
) -> Unit raise UiError {
  Backend::set_tray_icon(self.backend, name)
}

///|
/// 系统托盘菜单（`T86⑥`）：整份替换（与 `set_menubar` 同一条重建语义）。
/// 选中的语义同上下文菜单——同步解析，勾选态改在 Core、回调当场跑（`T86⑥`
/// 落地注记）。点击动作/气泡的第一版不做。
pub fn[B : Backend] App::set_tray_menu(
  self : App[B],
  menu : Menu,
) -> Unit raise UiError {
  Backend::set_tray_menu(self.backend, menu)
}

///|
/// 系统通知（`T86⑥`）：投出去即返回，投递本身是异步的；点击动作第一版不做。
pub fn[B : Backend] App::notify(
  self : App[B],
  title : String,
  body : String,
) -> Unit raise UiError {
  Backend::notify(self.backend, title, body)
}

///|
/// 当前实际生效的外观。`System` 向 Backend 取值，Backend 也报告 `System`
/// 时按 Light 兜底——和 `Theme::resolve` 一致，避免出现无法解析的外观。
pub fn[B : Backend] App::appearance(self : App[B]) -> Theme raise UiError {
  let system = Backend::system_theme(self.backend)
  match self.theme {
    Light => Light
    Dark => Dark
    System => if system == System { Light } else { system }
  }
}

///|
/// 生效配色（§16）。
pub fn[B : Backend] App::palette(self : App[B]) -> Palette raise UiError {
  self.theme.resolve(Backend::system_theme(self.backend))
}

///|
/// 样式层叠的最底层（§15/§16）：Theme 给出的默认样式。
/// 控件的解析走 `Widget::resolved_style`，顺序是 Theme -> 父容器 -> 自身。
/// 这份值是给窗口的：`create_window` 与 `set_theme` 把它存进每个窗口，
/// `relayout` 再沿树下发到后端，后端的测量与绘制都以它为准（§18）。
pub fn[B : Backend] App::style_base(self : App[B]) -> Style raise UiError {
  self.theme.default_style(Backend::system_theme(self.backend))
}

///|
/// 取出后端的引用，用于 Backend 侧的操作与断言。
/// MoonBit 结构体是引用语义，返回的 `B` 与 App 内部持有的是同一个对象。
pub fn[B] App::backend(self : App[B]) -> B {
  self.backend
}

///|
/// App 创建并登记窗口（§11 概念图里的 "App ├ Windows"）。
/// App 只登记不销毁：窗口由 `Window::close` 显式关闭，遗留的由 `Backend::terminate` 兜底。
pub fn[B : Backend] App::create_window(
  self : App[B],
  title : String,
  size : LogicalSize,
) -> Window[B] raise UiError {
  let win = Window::new(self.backend, title, size)
  // 新建的窗口一落地就带上当前的主题底样式（§16），否则 set_content 之后
  // 第一次 relayout 推给后端的是空样式，配色和字号都要等下一次重排才生效。
  win.refresh_style_base(self.style_base())
  // 实时重排的全局默认同一条下发纪律（live redraw）：没显式覆盖的窗跟着 App。
  win.refresh_live_default(self.live_redraw)
  self.windows.push(win)
  win
}

///|
/// 累计创建的窗口数
pub fn[B] App::window_count(self : App[B]) -> Int32 {
  self.windows.length()
}

///|
/// 仍存活的窗口数：`run()` 结束后应为 0，除非用户确实留着窗口没关。
pub fn[B] App::live_window_count(self : App[B]) -> Int32 {
  let mut n = 0
  for w in self.windows {
    if !w.is_closed() {
      n = n + 1
    }
  }
  n
}

///|
/// 通用订阅（`T57`）：target 认"这只控件"，`accept` 再筛"哪一种事件"。
/// 与控件级 `Widget::on(accept, handler)` 同一条形状——app 级此前只有按 target
/// 收的 `on_event`，窗口显示那一圈 `refresh_focus` 推的 `Focus` 会照单全收进
/// "来什么印什么"的订阅（`T49` 在 counter-native-macos 上咬到的那枚牙）。
/// 过滤器返回 false 不算命中：handler 不调用，`dispatch` 的命中数也不加。
/// 返回订阅 id 用于 `unsubscribe`；同一 target 可以有多个订阅，按订阅顺序触发。
pub fn[B] App::on(
  self : App[B],
  target : EventTarget,
  accept : (Event) -> Bool,
  handler : (Event) -> Unit raise UiError,
) -> Int32 {
  let id = self.next_sub_id
  self.next_sub_id = id + 1
  self.subs.push(Subscription::{ id, target, accept, handler, })
  id
}

///|
/// 订阅某个控件的所有事件（恒真过滤器）：要筛种类的场合请用 `App::on`。
pub fn[B] App::on_event(
  self : App[B],
  target : EventTarget,
  handler : (Event) -> Unit raise UiError,
) -> Int32 {
  self.on(target, _ => true, handler)
}

///|
/// 退订。返回是否真的删掉了一条订阅，重复退订返回 `false`。
pub fn[B] App::unsubscribe(self : App[B], id : Int32) -> Bool {
  let kept : Array[Subscription] = []
  for s in self.subs {
    if s.id != id {
      kept.push(s)
    }
  }
  let removed = kept.length() != self.subs.length()
  self.subs = kept
  removed
}

///|
/// 当前有效订阅数：控件销毁后应回到 0，用于泄漏检查。
pub fn[B] App::subscription_count(self : App[B]) -> Int32 {
  self.subs.length()
}

///|
/// 把任务投递回 UI 线程（§27）。Worker 只能 `post`，不能直接碰 Widget。
/// 任务在下一轮循环、且在原生事件之前执行；循环结束后再 `post` 不会被执行。
/// 不返回取消句柄——要撤回的任务走下面那条 `post_task`（`T85①`）。
pub fn[B] App::post(self : App[B], task : () -> Unit raise UiError) -> Unit {
  let _ = self.post_task(task)
}

///|
/// `T85①`：带取消句柄的投递。worker 把完成结果落回 UI 线程时走的就是这条
/// ——落进来的是一条普通排队任务，撤回它不再需要区分"是谁投的"。返回的
/// `TaskId` 在任务执行前一直有效；执行过的、取消过的、或循环已结束后再取消
/// 都返回 `false`（撤回一条死任务不是错误，是幂等空操作）。
pub fn[B] App::post_task(
  self : App[B],
  task : () -> Unit raise UiError,
) -> TaskId {
  let seq = self.next_task_seq
  self.next_task_seq = seq + 1
  let id = TaskId::{ seq, }
  self.posted.push(PostedTask::{ id, task, })
  id
}

///|
/// `T85①`：取消一条还在排队的任务。返回是否真的从队列里撤掉了——已经换进
/// 本圈在跑的任务撤不掉（返回 `false`），这与"撤回一条死任务"是同一个答案。
pub fn[B] App::cancel_task(self : App[B], id : TaskId) -> Bool {
  let kept : Array[PostedTask] = []
  let mut removed = false
  for t in self.posted {
    if !removed && t.id == id {
      removed = true
    } else {
      kept.push(t)
    }
  }
  if removed {
    self.posted = kept
  }
  removed
}

///|
pub fn[B] App::is_running(self : App[B]) -> Bool {
  self.running
}

///|
/// 请求退出循环。可以在 handler 或 post 的任务里调用，也可以在 `run()` 之前调用——
/// 那时循环一次都不跑，但 init/terminate 仍然发生。
pub fn[B] App::quit(self : App[B]) -> Unit {
  self.quit_requested = true
}

///|
/// 循环是否已收尾。用于断言"退出后没有遗留状态"。
pub fn[B] App::is_finished(self : App[B]) -> Bool {
  self.finished
}

///|
/// 执行本轮已投递的任务，返回执行个数。
/// 先把队列换成空数组再跑，所以任务里新 post 的留到下一轮，不会在本轮尾部失控。
fn[B] App::run_posted(self : App[B]) -> Int32 raise UiError {
  let round = self.posted
  self.posted = []
  let n = round.length()
  for i = 0; i < n; i = i + 1 {
    let t = round[i].task
    t()
  }
  n
}

///|
fn[B] App::is_subscribed(self : App[B], id : Int32) -> Bool {
  let mut found = false
  for s in self.subs {
    if s.id == id {
      found = true
    }
  }
  found
}

///|
/// `T86⑧` 按下点之间的距离（逻辑像素）。平方和开根，不做增量累计——
/// 识别问的是"离开按下点多远了"，不是"一路上走了多远"。
fn press_travel(a : LogicalPoint, b : LogicalPoint) -> Double {
  let dx = b.x - a.x
  let dy = b.y - a.y
  (dx * dx + dy * dy).sqrt()
}

///|
/// `T86⑧` 识别账的喂入：派发路过这里，按下/抬起/移动三支各改一条账。
/// 这是观察者加法——路由照旧，事件本身不改写；`MenuSelect`/`ThemeChanged`
/// 两支结构性进不了这里（它们在 dispatch 的独立臂里）。只有左键启动识别：
/// 长按是左键手势，右键有自己的账（`T86①`）。
fn[B] App::long_press_track(self : App[B], ev : Event) -> Unit {
  match ev {
    MouseDown(t, button, point) =>
      if button == Left {
        match self.anim_clock {
          Some(clock) =>
            self.press_pending = Some(PressPending::{
              target: t,
              start: point,
              started: clock(),
            })
          None => ()
        }
      }
    MouseUp(_, button, _) => if button == Left { self.press_pending = None }
    MouseMove(_, point) =>
      match self.press_pending {
        Some(p) =>
          // 移动超阈取消：抬起在阈值内是"点"，拖出去是"拖"，都不补发长按
          if press_travel(p.start, point) > LONG_PRESS_MOVE_THRESHOLD {
            self.press_pending = None
          }
        None => ()
      }
    _ => ()
  }
}

///|
/// 悬停翻面的落点（皮肤账）：指针在 target 上时，target 与**祖先链上声明了
/// `hover_style` 的控件**都算悬着（CSS `:hover` 的祖先语义）——列表行的悬停
/// 底挂在 Panel 上，命中报的却常是最里面的文字 Label，只翻 target 会让行的
/// 悬停底在指到文字时亮不起来。链上谁都没声明时翻 target 自己（按钮那类的
/// 既有语义）。声明了样式的翻面后各推一次 `apply_styles`（悬停样式沿
/// resolved_style 的祖先链漏给子孙，只推自己不漏）；没声明的翻面不改任何
/// 解析值，不推。
fn[B : Backend] hover_flip(
  w : Widget[B],
  on : Bool,
  base : Style,
) -> Unit raise UiError {
  let chain : Array[Widget[B]] = []
  let mut cur : Widget[B]? = Some(w)
  while true {
    match cur {
      Some(x) => {
        chain.push(x)
        cur = x.parent
      }
      None => break
    }
  }
  let mut styled = false
  for x in chain {
    if x.hover_style is Some(_) {
      styled = true
    }
  }
  if styled {
    for x in chain {
      if x.hover_style is Some(_) {
        x.hovered = on
        x.apply_styles(base)
      }
    }
  } else {
    w.hovered = on
    w.apply_styles(base)
  }
}

///|
/// 悬停账（皮肤账）：MouseMove 的目标换人时翻面——旧目标摘 `hovered`、新
/// 目标挂上（落点见 `hover_flip`：命中控件 + 祖先链上声明了 hover_style 的
/// 都翻），两只都把生效样式重推给后端，并补发 MouseLeave/MouseEnter（观察者
/// 照旧用 `on_event`/`on_any` 收，事件的 target 仍是命中控件自己）。目标认
/// 不出（指针不在任何控件上——空白处移动/离开窗口，后端报窗口自己）= None，
/// 与"悬着别的"也构成一次换面。整树重建后旧 target 找不到就算了——标记随
/// 旧树作废，新树按下一次移动重新认领。
fn[B : Backend] App::hover_track(
  self : App[B],
  ev : Event,
) -> Unit raise UiError {
  let t = match ev {
    MouseMove(t, _) => t
    _ => return
  }
  // 悬的是哪只控件：沿窗口找 target。窗口自己（空白）认成 None。
  let mut hovered : Widget[B]? = None
  for win in self.windows {
    if !win.is_closed() {
      match win.find_widget(t) {
        Some(w) => {
          hovered = Some(w)
          break
        }
        None => ()
      }
    }
  }
  let new_target : EventTarget? = match hovered {
    Some(_) => Some(t)
    None => None
  }
  if self.hover == new_target {
    return
  }
  let base = self.style_base()
  // 摘旧（整树已重建时 find 不到——那只控件连同标记一起作废）
  match self.hover {
    Some(wt) => {
      for win in self.windows {
        if !win.is_closed() {
          match win.find_widget(wt) {
            Some(w) => {
              hover_flip(w, false, base)
              break
            }
            None => ()
          }
        }
      }
      let _ = self.dispatch(MouseLeave(wt))
    }
    None => ()
  }
  // 挂新
  match hovered {
    Some(w) => {
      hover_flip(w, true, base)
      let _ = self.dispatch(MouseEnter(t))
    }
    None => ()
  }
  self.hover = new_target
}

///|
/// `T86⑧` 把到期的那条识别补发成长按事件。判据是"按了 >= 400ms 且没抬起、
/// 没超移动阈值"——抬起与超阈两条取消路都在 track 里当场清账，这里只补
/// 到期那条。时刻一律从注入读（`T84` 先例：Core 一行不读时钟），没注入
/// 时识别整体缺席。返回本圈是否真的补发过（`step` 拿它算"这一轮算不算
/// 有进展"，主循环不在只剩长按可发时提前退出）。
fn[B : Backend] App::poll_long_press(self : App[B]) -> Bool raise UiError {
  match self.press_pending {
    Some(p) =>
      match self.anim_clock {
        Some(clock) => {
          let now = clock()
          if now - p.started >= LONG_PRESS_DURATION_MS {
            self.press_pending = None
            let _ = self.dispatch(LongPress(p.target))
            true
          } else {
            false
          }
        }
        None => false
      }
    None => false
  }
}

///|
/// 派发一个事件，返回本次实际触发的 handler 个数（菜单项回调 + 快捷键回调 + App 订阅）。
///
/// 三段路径（§9/§10 的"Event First"）：
/// 1. `MenuSelect` 走菜单栏：菜单项 id 与句柄 id 是两个独立编号空间，因此按事件
///    变体分流，绝不进控件树，避免同一个数字命中窗口或控件；
/// 2. 其余事件路由到 Core——目标是窗口就交给 `Window::handle_event`（Resize 重排、
///    Close 释放），目标是控件就在内容树里找到它并 `fire`；`KeyDown` 额外触发命中的
///    快捷键（§26），先菜单项（`set_menubar` 自动登记的组合），后独立注册的组合；
/// 3. 最后走 `on` / `on_event` 注册的订阅，让观察者在界面状态已经更新之后收到
///    通知（`T57`：`on` 带 `target` 之外还有一层种类过滤器，没放行的不算命中）。
/// 先快照再调用：派发过程中新增的订阅本轮不触发，被退订的不再调用。
pub fn[B : Backend] App::dispatch(
  self : App[B],
  ev : Event,
) -> Int32 raise UiError {
  let target = Event::target(ev)
  // `T88①` 观察者加法：sink 在派发起点快照（handler 中途换 sink 不影响本
  // 回合）；没开账（None）零分配零调用——下面的路由照旧走，行为与旧账逐位
  // 同值。开着时逐格账经 `route_with_phases` 的记录口落进 accum，收尾整条
  // 流出；路由臂的判定与记账共享一次命中判定，顺序与旧账一字不差。
  let sink = self.event_trace
  let accum : DispatchTrace? = match sink {
    Some(_) =>
      Some(DispatchTrace::{
        event: ev,
        route: Missed,
        capture: [],
        direct: [],
        bubble: [],
        intercepted: false,
        subscribed: [],
      })
    None => None
  }
  let mut hits = 0
  match ev {
    MenuSelect(t) => {
      let found = match self.click_menu_item(t.id) {
        Some(_) => true
        None => false
      }
      if found {
        hits = hits + 1
      }
      match accum {
        Some(t) => t.route = MenuHit(found)
        None => ()
      }
    }
    /// 主题换底样式要走 `refresh_style_base`（换底 + 重排一起做），不能只重排：
    /// 样式层叠的起点存在窗口上（§16），起点不换，重排推给后端的还是旧配色。
    /// 只刷目标窗口——后端给每只存活窗口各发一条，一条只管一扇窗。
    /// App 强制了主题（Light/Dark）时 `style_base()` 算回同一个值，这里就只是
    /// 一次幂等的重排；事件照发，因为它报告的是**系统**主题变了，不是生效外观。
    ThemeChanged(t, _) => {
      let base = self.style_base()
      let mut refreshed = 0
      for win in self.windows {
        if !win.is_closed() && win.target() == t {
          win.refresh_style_base(base)
          hits = hits + 1
          refreshed = refreshed + 1
        }
      }
      match accum {
        Some(t) => t.route = ThemeRefreshed(refreshed)
        None => ()
      }
    }
    _ => {
      // `T89` 吸附：用户拖动窗口时，先把贴着它的那些窗按同样位移带走。放在
      // 路由**之前**——邻居的位移要按"这只窗已经到位"之后的几何算，否则每一
      // 步都差一拍（拖动会变成越拖越散）。路由本身不改：下面那条窗口臂照旧
      // 把事件交给被拖的这只窗自己。
      match ev {
        Moved(_, p) => {
          let _ = self.follow_move(target, p)
        }
        _ => ()
      }
      // `T86⑧`：识别账先喂（观察者加法，路由不改写）。按下记账、抬起/超阈取消，
      // 事件的直派照旧走下面的窗口臂。悬停账同一条观察者规矩（皮肤账）。
      self.long_press_track(ev)
      self.hover_track(ev)
      for win in self.windows {
        if !win.is_closed() {
          // 路由比整个 EventTarget（id + generation，`T49`）：id 被新窗口或
          // 新控件拿走之后，拿着旧代 target 的事件不许再命中它们。
          if win.target() == target {
            win.handle_event(ev)
            match accum {
              Some(t) => t.route = WindowArm
              None => ()
            }
          } else {
            match win.find_widget(target) {
              // `T86⑨`：路由换成"capture → 直派 → 冒泡"的完整路径。直派那一格
              // 仍是既有账（`fire` 一字未动）；树上一格拦截口/冒泡口都没装时，
              // 两个新阶段恒空、一次调用都不发生——行为与旧账逐位同值。
              // `T88①`：账开着时树臂记 TreeArm、三段逐格账在同一次命中判定
              // 下落进 accum（Missed 是 accum 的初值——循环走完没命中就是它）。
              Some(w) => {
                match accum {
                  Some(t) => t.route = TreeArm
                  None => ()
                }
                w.route_with_phases(ev, accum)
              }
              None => ()
            }
          }
        }
      }
      match ev {
        KeyDown(_, kp) => hits = hits + self.fire_shortcut(kp)
        _ => ()
      }
    }
  }
  let round : Array[Subscription] = []
  for s in self.subs {
    if s.target == target {
      round.push(s)
    }
  }
  for s in round {
    if self.is_subscribed(s.id) {
      // `T88①`：accept 裁决共享——账开着时挡下的格子也进账（"accept 与否"
      // 的另一半），调用与命中数跟旧账一字不差（accept 每格恰好裁决一次）。
      let accepted = (s.accept)(ev)
      match accum {
        Some(t) => t.subscribed.push(TraceStop::{ owner: s.id, accepted, })
        None => ()
      }
      if accepted {
        (s.handler)(ev)
        hits = hits + 1
      }
    }
  }
  match sink {
    Some(s) =>
      match accum {
        Some(t) => s(t)
        None => ()
      }
    None => ()
  }
  hits
}

///|
/// 推进一圈：先跑 `post` 来的任务，再取一个原生事件派发，然后把标了脏的窗口
/// 重排掉（`set_text` 只标脏——文案一变固有尺寸就变，frame 不追就截字；重排
/// 放在派发之后的同一轮，回调里改的文案下一帧就长回来，也不在原生回调栈里
/// 重入布局），最后推进动画泵（`T84`）：变更点在重排那一格记成动画起点，
/// 泵在**同一圈**起跑，之后的每一圈推一帧中间值直到落点退场。返回 `false`
/// 表示这一轮既没有任务也没有事件、没有重排、也没有帧可推。
pub fn[B : Backend] App::step(self : App[B]) -> Bool raise UiError {
  let tasks = self.run_posted()
  let result = match Backend::poll_event(self.backend) {
    Some(ev) => {
      let _ = self.dispatch(ev)
      true
    }
    None => tasks > 0
  }
  let laid = self.flush_layout()
  // `T86⑧`：按住到期的那条在这一圈补发——调度口径沿 `T84` 帧钟：主循环
  // 每圈路过一次，到期即发，不必另立定时器（零 ABI 的理由之一）。
  let pressed = self.poll_long_press()
  let animated = self.pump_animations()
  result || laid || pressed || animated
}

///|
/// 把 `set_text` 标脏的窗口重排一遍。返回这一圈有没有真的重排——`step` 拿它
/// 决定"这一轮算不算有进展"，`run` 的主循环才不会在只剩重排可做时提前退出。
fn[B : Backend] App::flush_layout(self : App[B]) -> Bool raise UiError {
  let mut did = false
  for win in self.windows {
    if !win.is_closed() {
      match win.content {
        Some(root) =>
          if root.needs_layout {
            win.relayout()
            did = true
          }
        None => ()
      }
    }
  }
  did
}

///|
/// 事件主循环。`drive` 把 handler 的失败收进返回值而不是直接抛出，
/// 这样 `run` 的收尾（terminate）在任何路径上都会执行一次且仅一次。
fn[B : Backend] App::drive(self : App[B]) -> UiError? {
  let mut err : UiError? = None
  try {
    while !self.quit_requested {
      if !self.step() {
        break
      }
    }
  } catch {
    e => err = Some(e)
  }
  err
}

///|
/// 事件主循环（§11）：init → 循环 → terminate。
/// `terminate` 回收遗留句柄，所以即使 handler 失败退出也不会留下悬垂对象（§47 风险 2）。
pub fn[B : Backend] App::run(self : App[B]) -> Unit raise UiError {
  if self.running {
    raise OperationFailed("事件循环已经在运行")
  }
  if self.finished {
    raise OperationFailed("App 已退出，不能再次 run")
  }
  Backend::init(self.backend)
  self.running = true
  let err = self.drive()
  self.running = false
  self.finished = true
  Backend::terminate(self.backend)
  match err {
    Some(e) => raise e
    None => ()
  }
}

///|
test "run 走完 init → 派发 → terminate，退出时句柄表归零" {
  let app = App::new(MockBackend::new())
  let target = EventTarget::{ id: 7, generation: 0, }
  let seen : Array[Event] = []
  let _ = app.on_event(target, fn(ev) { seen.push(ev) })
  let b = app.backend()
  Backend::init(b)
  let _ = b.create_window("MoonUI", LogicalSize(800.0, 600.0))
  assert_eq(app.subscription_count(), 1)
  assert_false(app.is_running())
  b.push_event(Click(target, Left))
  b.push_event(Close(target))
  app.run()
  assert_eq(seen, [Click(target, Left), Close(target)])
  assert_false(app.is_running())
  assert_true(app.is_finished())
  // terminate 回收了没显式销毁的窗口
  assert_eq(b.live(), 0)
}

///|
test "handler 里 quit 让循环立刻收尾，后续事件不再派发" {
  let app = App::new(MockBackend::new())
  let target = EventTarget::{ id: 1, generation: 0, }
  let b = app.backend()
  b.push_event(Click(target, Left))
  b.push_event(Change(target))
  let mut hits = 0
  let mut was_running = false
  let _ = app.on_event(target, fn(ev) {
    hits = hits + 1
    was_running = app.is_running()
    match ev {
      Click(_, _) => app.quit()
      _ => ()
    }
  })
  app.run()
  assert_eq(hits, 1)
  assert_true(was_running)
  assert_eq(b.live(), 0)
}

///|
test "run 之后不能再次 run，quit 幂等" {
  let app = App::new(MockBackend::new())
  app.quit()
  app.run()
  assert_true(app.is_finished())
  let msg = try {
    app.run()
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("操作失败：App 已退出，不能再次 run"))
}

///|
test "空队列的 run 不忙等，仍然完成生命周期" {
  let app = App::new(MockBackend::new())
  let b = app.backend()
  Backend::init(b)
  let _ = b.create_window("A", LogicalSize(10.0, 10.0))
  app.run()
  assert_true(app.is_finished())
  assert_eq(b.live(), 0)
}

///|
test "step 单轮语义：先任务后事件，都空时返回 false" {
  let app = App::new(MockBackend::new())
  let target = EventTarget::{ id: 3, generation: 0, }
  let b = app.backend()
  Backend::init(b)
  let order : Array[String] = []
  let _ = app.on_event(target, fn(_) { order.push("event") })
  app.post(fn() { order.push("task") })
  b.push_event(Change(target))
  assert_true(app.step())
  assert_eq(order, ["task", "event"])
  assert_false(app.step())
}

///|
test "post 的任务按 FIFO 执行，本轮新 post 的留到下一轮" {
  let app = App::new(MockBackend::new())
  let log : Array[Int32] = []
  app.post(fn() { log.push(1) })
  app.post(fn() {
    log.push(2)
    app.post(fn() { log.push(3) })
  })
  assert_true(app.step())
  assert_eq(log, [1, 2])
  assert_true(app.step())
  assert_eq(log, [1, 2, 3])
  assert_false(app.step())
}

///|
test "事件只派发给同一 target 的订阅" {
  let app = App::new(MockBackend::new())
  let a = EventTarget::{ id: 10, generation: 0, }
  let other = EventTarget::{ id: 11, generation: 0, }
  let mut a_hits = 0
  let mut b_hits = 0
  let _ = app.on_event(a, fn(_) { a_hits = a_hits + 1 })
  let _ = app.on_event(a, fn(_) { a_hits = a_hits + 100 })
  let _ = app.on_event(other, fn(_) { b_hits = b_hits + 1 })
  assert_eq(app.dispatch(Click(a, Left)), 2)
  assert_eq(a_hits, 101)
  assert_eq(b_hits, 0)
  assert_eq(app.dispatch(Change(other)), 1)
  assert_eq(app.dispatch(Scroll(a, LogicalPoint(0.0, 0.0))), 2)
}

///|
/// `T57`：app 级订阅按种类收口——`App::on` 的过滤器在 target 命中之后先筛种类，
/// 没放行的不调用 handler、也不算进 `dispatch` 的命中数；`on_event` 是恒真
/// 过滤器的糖，来什么收什么。`T49` 咬到的那枚牙（`refresh_focus` 在窗口显示
/// 那一圈推的 `Focus` 灌进"来什么印什么"的订阅）从此可以精确收听。
test "App::on 按种类过滤，on_event 照单全收" {
  let app = App::new(MockBackend::new())
  let t = EventTarget::{ id: 3, generation: 0, }
  let clicks : Array[Event] = []
  let all : Array[Event] = []
  let _ = app.on(t, ev => ev is Click(_, _), fn(ev) { clicks.push(ev) })
  let _ = app.on_event(t, fn(ev) { all.push(ev) })
  // 同 target 的 Focus：过滤器挡下（hits 只有 on_event 那一条），订阅数组不动
  assert_eq(app.dispatch(Focus(t)), 1)
  assert_eq(clicks, [])
  assert_eq(all, [Focus(t)])
  // Click 放行：两条订阅都命中
  assert_eq(app.dispatch(Click(t, Left)), 2)
  assert_eq(clicks, [Click(t, Left)])
  assert_eq(all.length(), 2)
  // 过滤器只筛种类不筛 target：别的 target 的事件本来就进不来（`T49` 的另一半）
  assert_eq(
    app.dispatch(Click(EventTarget::{ id: 4, generation: 0, }, Left)),
    0,
  )
  assert_eq(clicks.length(), 1)
}

///|
test "unsubscribe 生效且幂等，派发中被退订的 handler 不再调用" {
  let app = App::new(MockBackend::new())
  let t = EventTarget::{ id: 5, generation: 0, }
  let mut first = 0
  let mut second = 0
  let mut second_id = 0
  let first_id = app.on_event(t, fn(_) {
    first = first + 1
    let _ = app.unsubscribe(second_id)
  })
  second_id = app.on_event(t, fn(_) { second = second + 1 })
  assert_eq(app.subscription_count(), 2)
  assert_eq(app.dispatch(Click(t, Left)), 1)
  assert_eq(first, 1)
  assert_eq(second, 0)
  assert_true(app.unsubscribe(first_id))
  assert_eq(app.subscription_count(), 0)
  assert_false(app.unsubscribe(first_id))
  assert_false(app.unsubscribe(-99))
}

///|
test "handler 失败会结束循环，但 terminate 仍然回收句柄" {
  let app = App::new(MockBackend::new())
  let target = EventTarget::{ id: 2, generation: 0, }
  let b = app.backend()
  Backend::init(b)
  let _ = b.create_window("Boom", LogicalSize(10.0, 10.0))
  b.push_event(Click(target, Left))
  b.push_event(Change(target))
  let mut seen = 0
  let _ = app.on_event(target, fn(ev) raise UiError {
    seen = seen + 1
    match ev {
      Click(_, _) => raise OperationFailed("handler 内部失败")
      _ => ()
    }
  })
  let msg = try {
    app.run()
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("操作失败：handler 内部失败"))
  assert_eq(seen, 1)
  assert_true(app.is_finished())
  assert_eq(b.live(), 0)
}

///|
test "App 创建窗口，Close 事件驱动关闭并退出循环" {
  let app = App::new(MockBackend::new())
  let b = app.backend()
  Backend::init(b)
  let win = app.create_window("Main", LogicalSize(640.0, 480.0))
  win.show()
  assert_eq(app.window_count(), 1)
  assert_eq(app.live_window_count(), 1)
  // Close 由 Core 负责释放窗口与内容（§12），订阅者是观察者——
  // 在 handler 里再 win.close() 会得到 Destroyed。
  let _ = app.on_event(win.target(), fn(_) { app.quit() })
  b.push_event(Close(win.target()))
  b.push_event(Click(win.target(), Left))
  app.run()
  assert_true(win.is_closed())
  assert_eq(app.live_window_count(), 0)
  assert_eq(b.live(), 0)
}

///|
test "集成：Resize 驱动窗口尺寸，Close 退出循环（§37 第三层雏形）" {
  let app = App::new(MockBackend::new())
  let b = app.backend()
  Backend::init(b)
  let win = b.create_window("Counter", LogicalSize(320.0, 240.0))
  let target = EventTarget::of(win)
  let mut closed = false
  let _ = app.on_event(target, fn(ev) raise UiError {
    match ev {
      Resize(_, size) => Backend::set_window_size(b, win, size)
      Close(_) => {
        closed = true
        app.quit()
      }
      _ => ()
    }
  })
  b.push_event(Resize(target, LogicalSize(100.0, 80.0)))
  b.push_event(Click(target, Left))
  b.push_event(Close(target))
  app.run()
  assert_true(closed)
  assert_eq(app.subscription_count(), 1)
  assert_eq(b.live(), 0)
}

///|
/// §9/§10 的闭环：原生事件 -> Backend 队列 -> App 路由 -> 控件 handler，
/// 以及 Resize 触发窗口重排。用 Spacer 让布局结果随宽度变化，
/// 这样"确实重排过"是可断言的，而不是恰好相等。
test "run 把原生事件路由到控件并按 Resize 重排" {
  let app = App::new(MockBackend::new())
  let b = app.backend()
  Backend::init(b)
  let win = app.create_window("Counter", LogicalSize(200.0, 100.0))
  let label = Widget::label(b, "Ab")
  let sp = Widget::spacer(b)
  win.set_content(Widget::row(b, 0.0, [sp, label]))
  let initial_x = label.bounds().origin.x
  let log : Array[String] = []
  let _ = label.on_click(fn() { log.push("clicked") })
  let observed : Array[Int32] = []
  let _ = app.on_event(label.target(), fn(_) { observed.push(1) })
  // 界面状态必须在事件当时读：循环收尾时 terminate 会关掉后端
  let positions : Array[Double] = []
  let _ = app.on_event(win.target(), fn(_) raise UiError {
    positions.push(label.bounds().origin.x)
  })
  b.push_event(Event::Click(label.target(), MouseButton::Left))
  // 真实后端是"原生层先改尺寸、再发 Resize"
  Backend::set_window_size(b, win.handle(), LogicalSize(300.0, 100.0))
  b.push_event(Event::Resize(win.target(), LogicalSize(300.0, 100.0)))
  app.run()
  assert_eq(log, ["clicked"])
  // App 级订阅是观察者，不参与路由本身
  assert_eq(observed.length(), 1)
  // 装载时 200 宽贴在右端 176；Resize 到 300 宽后路由先重排，
  // 观察者读到的是重排后的 276
  assert_eq(initial_x, 176.0)
  assert_eq(positions, [276.0])
  assert_true(app.is_finished())
}

///|
/// Close 事件走窗口自己的释放路径：内容树整棵关闭，退出时句柄表归零（§47 风险 2）。
test "Close 事件经循环释放窗口与其内容" {
  let app = App::new(MockBackend::new())
  let b = app.backend()
  Backend::init(b)
  let win = app.create_window("Done", LogicalSize(100.0, 50.0))
  let btn = Widget::button(b, "Ok")
  win.set_content(btn)
  assert_eq(b.live(), 2)
  b.push_event(Event::Close(win.target()))
  app.run()
  assert_true(win.is_closed())
  assert_true(btn.is_closed())
  assert_eq(b.live(), 0)
}

///|
/// §30：ScaleChanged 走与 Resize 相同的路由（窗口目标 -> `Window::handle_event`），
/// 但它不带尺寸——新的逻辑尺寸必须由 Core 回后端读，这正是"Core 不缓存窗口状态"
/// 在 HiDPI 上的收益：后端改了 DPI，Core 不需要知道是怎么改的。
test "ScaleChanged 经主循环路由到窗口并重排" {
  let app = App::new(MockBackend::new())
  let b = app.backend()
  Backend::init(b)
  let win = app.create_window("HiDPI", LogicalSize(200.0, 100.0))
  let label = Widget::label(b, "Ab")
  let sp = Widget::spacer(b)
  win.set_content(Widget::row(b, 0.0, [sp, label]))
  assert_eq(label.bounds().origin.x, 176.0)
  MockBackend::set_window_scale(b, win.handle(), Scale::{ x: 2.0, y: 2.0, })
  Backend::set_window_size(b, win.handle(), LogicalSize(100.0, 50.0))
  b.push_event(ScaleChanged(win.target(), Scale::{ x: 2.0, y: 2.0, }))
  assert_true(app.step())
  assert_eq(label.bounds().origin.x, 76.0)
  assert_eq(win.scale(), Scale::{ x: 2.0, y: 2.0, })
}

///|
/// `T48`：系统主题变了，后端给每只存活窗口发一条 `ThemeChanged`，App 收到后
/// 给目标窗口重算 `style_base` 并下发。断言的是后端当下持有的那份样式——
/// 只改 Core 里的字段不推给后端，配色就不会真的变（§16 的下发那一步）。
test "ThemeChanged 给目标窗口换底样式并重推给后端" {
  let app = App::new(MockBackend::new())
  let b = app.backend()
  Backend::init(b)
  b.set_appearance(Light)
  let win = app.create_window("主题", LogicalSize(200.0, 100.0))
  let label = Widget::label(b, "Ab")
  win.set_content(Widget::column(b, 0.0, [label]))
  let h = check_nonnull(label.handle(), "叶子控件必须有原生对象")
  let light = check_nonnull(b.widget(h).style, "装载时必须已下发样式")
  // 系统切到深色：后端发现变化，给窗口发一条携带新外观的事件
  b.set_appearance(Dark)
  assert_eq(app.dispatch(ThemeChanged(win.target(), Dark)), 1)
  let dark = check_nonnull(b.widget(h).style, "换主题必须重推")
  // Label 不下发继承来的底色（`T139`，见 `Widget::apply_styles` 段注），
  // 所以这里比的是"主题算出来的那份"去掉背景之后的形状。
  assert_eq(dark, Style::{ ..app.style_base(), background: None, })
  assert_eq(dark.foreground, Some(Theme::dark_palette().text))
  assert_true(dark != light)
  // 目标不是存活窗口时不重推、也不计命中
  let stranger = EventTarget::{ id: win.target().id + 100, generation: 0, }
  assert_eq(app.dispatch(ThemeChanged(stranger, Light)), 0)
  assert_eq(check_nonnull(b.widget(h).style, ""), dark)
}

///|
/// App 强制了主题（Light/Dark）时，`ThemeChanged` 事件的底样式算回同一个值，
/// 重排是幂等的；事件照发——它报告的是**系统**主题变了，不是生效外观。
test "App 强制主题时 ThemeChanged 只做幂等重排，订阅仍收到事件" {
  let app = App::new(MockBackend::new())
  let b = app.backend()
  Backend::init(b)
  app.set_theme(Dark)
  let win = app.create_window("强制", LogicalSize(100.0, 50.0))
  let seen : Array[Event] = []
  let _ = app.on_event(win.target(), fn(ev) { seen.push(ev) })
  // 系统其实是浅色，但 App 强制了深色
  b.set_appearance(Light)
  // 命中数 = 1（窗口刷新）+ 1（同目标的 App 订阅）
  assert_eq(app.dispatch(ThemeChanged(win.target(), Light)), 2)
  assert_eq(seen, [ThemeChanged(win.target(), Light)])
  // 生效外观没变：app.theme 仍是 Dark
  assert_eq(app.appearance(), Dark)
}

///|
/// `T49`：句柄表会把销毁过的 id 发给下一只新控件（`free_ids` 的设计如此），
/// 只比 id 的订阅早晚会命中"同一个数字的新主人"。本条用挂账时的那轮探针复现：
/// 建一只按钮 → 订阅它的 target → `set_content` 换掉整棵内容树（旧按钮当场
/// `close_tree`、id 回收）→ 新按钮拿走同一个 id。断言三件事：id 真的复用了、
/// generation 真的变了（否则这条测试没有牙）、旧订阅从此一条都不响——
/// 新控件的事件路由与订阅匹配都比整个 `EventTarget`，id 相同、代不同，不命中。
test "句柄 id 复用不再冒充旧订阅（T49）" {
  let app = App::new(MockBackend::new())
  let b = app.backend()
  Backend::init(b)
  let win = app.create_window("复用", LogicalSize(200.0, 100.0))
  let first = Widget::button(b, "第一只")
  win.set_content(first)
  let stale = first.target()
  let mut stale_hits = 0
  let _ = app.on_event(stale, fn(_) { stale_hits = stale_hits + 1 })
  // 先把内容树整个换成一只纯布局节点（`set_content` 当场 `close_tree`
  // 旧按钮、id 回收），再建新按钮——顺序反了新按钮会拿到全新的 id，
  // 复用根本没发生，这条测试就成了空转
  win.set_content(Widget::column(b, 0.0, []))
  assert_true(first.is_closed())
  let second = Widget::button(b, "第二只")
  win.set_content(second)
  assert_eq(second.target().id, stale.id)
  assert_true(second.target().generation != stale.generation)
  // 新控件的 Click 只响新控件自己的订阅，旧订阅一条都不许响
  let mut fresh_hits = 0
  let _ = app.on_event(second.target(), fn(_) { fresh_hits = fresh_hits + 1 })
  assert_eq(app.dispatch(Click(second.target(), Left)), 1)
  assert_eq(fresh_hits, 1)
  assert_eq(stale_hits, 0)
  // 拿着旧代 target 派发：命不中新控件（fresh_hits 不动——路由与订阅匹配
  // 都比整个 EventTarget），旧订阅自己收得到——它订的就是这个 target，
  // 这一条是"事件确实送达了"的正控制，不是漏。
  assert_eq(app.dispatch(Click(stale, Left)), 1)
  assert_eq(fresh_hits, 1)
  assert_eq(stale_hits, 1)
  assert_eq(app.subscription_count(), 2)
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// `T85①` 判据一（Mock 模拟 worker 完成投递的落地点）：真实链路里 worker 闭包
/// 在平台线程跑完后，投递原语在主循环泵消息时把落地回调调回 UI 线程——落地
/// 动作是 `app.post(...)`，排队、下一圈执行、且排在原生事件之前（§27）。Mock
/// 是单线程的，投递的落地点就是下一次 `step` 调用：任务先跑、事件后到、FIFO
/// 保序，且 `post_task` 发出的句柄互不相同（同一批投递各有各的撤回凭据）。
test "worker 投递的任务在 UI 线程执行且排在事件前（T85①判据一）" {
  let app = App::new(MockBackend::new())
  let target = EventTarget::{ id: 21, generation: 0, }
  let b = app.backend()
  Backend::init(b)
  let order : Array[String] = []
  let _ = app.on_event(target, fn(_) { order.push("event") })
  // 模拟投递原语的落地点：worker 完成后泵消息时落地回调在 UI 线程跑，落地
  // 动作就是这三条投递（带句柄的是撤回判据要用的形状，post 是它的糖）。
  let id_a = app.post_task(fn() { order.push("task-a") })
  let id_b = app.post_task(fn() { order.push("task-b") })
  app.post(fn() { order.push("task-c") })
  assert_true(id_a != id_b)
  assert_true(id_a.seq != 0)
  b.push_event(Change(target))
  assert_true(app.step())
  assert_eq(order, ["task-a", "task-b", "task-c", "event"])
  assert_false(app.step())
}

///|
/// `T85①` 判据二负控制一（worker 投递的取消）：worker 落回来的结果是一条
/// 普通排队任务，撤回它走 `cancel_task`——执行前随时可撤、执行过的撤不掉、
/// 从未存在的句柄同样幂等。整条负控制是确定性的：没有线程时序可赌。
test "worker 投递的取消：执行前撤回，执行后撤不掉（T85①负控制）" {
  let app = App::new(MockBackend::new())
  let ran : Array[Int32] = []
  let id_first = app.post_task(fn() { ran.push(1) })
  let id_cancel = app.post_task(fn() { ran.push(2) })
  // 执行前撤回：从队列里真的撤掉，任务不跑
  assert_true(app.cancel_task(id_cancel))
  assert_true(app.step())
  assert_eq(ran, [1])
  // 已执行的与取消过的：再撤都是空操作
  assert_false(app.cancel_task(id_first))
  assert_false(app.cancel_task(id_cancel))
  // 执行前一刻撤回：撤回窗口覆盖到任务执行前一刻
  let id_late = app.post_task(fn() { ran.push(3) })
  assert_true(app.cancel_task(id_late))
  assert_false(app.step())
  // 从未分配的句柄（0 是哨兵）：撤回也是空操作
  assert_false(app.cancel_task(TaskId::{ seq: 0, }))
  assert_eq(ran, [1])
}

///|
/// `T85①` 判据二负控制二（任务里控件已销毁）：worker 落地的任务闭着一只控件的
/// 引用；控件在任务执行前销毁——`close_tree` 把后端句柄连同注销掉，任务跑的
/// 时候任何控件操作必须当场判错而不是命中尸体（句柄表 `T49`/`T57` 的 generation
/// 自动继承到任务路径）。断言：任务确实执行了、控件操作当场判错、主循环安然
/// 活下来——判错文本不钉具体措辞，钉的是"确实判错了"。
test "worker 投递的任务里控件已销毁：判错不命中尸体（T85①负控制）" {
  let app = App::new(MockBackend::new())
  let b = app.backend()
  Backend::init(b)
  let win = app.create_window("销毁", LogicalSize(200.0, 100.0))
  let btn = Widget::button(b, "Ok")
  win.set_content(btn)
  let mut ran = false
  let mut judged = "未判错"
  let _ = app.post_task(fn() {
    ran = true
    judged = try {
      let _ = btn.target()
      "未判错"
    } catch {
      e => UiError::message(e)
    }
  })
  // 执行前销毁：close_tree 走"先销毁原生对象、再清 Core 引用"的释放语义
  btn.close_tree()
  assert_true(btn.is_closed())
  let _ = app.step()
  assert_true(ran)
  assert_true(judged != "未判错")
  // 控件的句柄没有泄漏：窗口还在（live=1），按钮那份已归零
  assert_eq(b.live(), 1)
}

///|
/// `T85②` 判据一（Mock 模拟组合序列的事件到达顺序）：真实链路里后端从原生
/// 组合源（mac 的 field editor 标记串、Win32 的 `WM_IME_*` 分流）推相位通知，
/// Mock 直接注入相位事件。断言注入顺序原样到达打在组合控件上的订阅——
/// 起始不带组合串（对齐 Win32 的 `WM_IME_STARTCOMPOSITION`），中间每条携带
/// 当下的组合串，结束不带组合串（上屏全文随既有 `Input` 走，§32）。
test "Mock 模拟组合序列的事件到达顺序（T85②判据）" {
  let app = App::new(MockBackend::new())
  let b = app.backend()
  Backend::init(b)
  let win = app.create_window("组合", LogicalSize(300.0, 120.0))
  let input = Widget::text_input(b, "")
  win.set_content(Widget::column(b, 0.0, [input]))
  let seq : Array[String] = []
  let _ = input.on(
    fn(ev) { ev is ImeStart(_) || ev is ImeCompose(_, _) || ev is ImeEnd(_) },
    fn(ev) {
      match ev {
        ImeStart(_) => seq.push("start")
        ImeCompose(_, s) => seq.push("compose:" + s)
        ImeEnd(_) => seq.push("end")
        _ => ()
      }
    },
  )
  // 模拟"在组合框里打 nihao 再上屏"的相位序列。一条 step 只派发一条事件，
  // 五条序列交给 run 排空（队列空后 run 收尾）。
  b.push_event(ImeStart(input.target()))
  b.push_event(ImeCompose(input.target(), "ni"))
  b.push_event(ImeCompose(input.target(), "niha"))
  b.push_event(ImeCompose(input.target(), "nihao"))
  b.push_event(ImeEnd(input.target()))
  app.run()
  assert_eq(seq, ["start", "compose:ni", "compose:niha", "compose:nihao", "end"])
}
