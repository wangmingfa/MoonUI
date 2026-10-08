///|
/// App 与事件循环（设计文档 §11、§27，开发顺序 §48 第 07/08 步：Lifecycle + App）。
///
/// 本版本 MoonBit 的 trait 不是类型、也没有 `dyn`，所以 App 对后端做**静态分发**：
/// `App[MockBackend]` 用于无头测试，接上 libui-ng 后是 `App[LibuiBackend]`。
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
  id : Int
  target : EventTarget
  handler : (Event) -> Unit raise UiError
}

///|
pub struct App[B] {
  backend : B
  mut subs : Array[Subscription]
  windows : Array[Window[B]]
  mut posted : Array[() -> Unit raise UiError]
  mut next_sub_id : Int
  mut running : Bool
  mut quit_requested : Bool
  mut finished : Bool
  mut theme : Theme
  // §25 菜单栏与 §26 快捷键。菜单项自带的组合在 set_menubar 时展开成镜像表，
  // 这样按键命中不用每次重扫整棵菜单树。
  mut menubar : MenuBar?
  mut menu_accel : Array[MenuAccel]
  mut shortcuts : Array[ShortcutBinding]
  mut next_shortcut_id : Int
}

///|
/// 文档 §11 的 `App::new()`。因为后端是编译期参数，这里必须把后端实例交进来；
/// 等 §20 的 libui-ng 后端就位，`App::new(LibuiBackend::new())` 会收敛成默认形态。
pub fn[B] App::new(backend : B) -> App[B] {
  App::{
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
    // §25/§26：菜单栏与其快捷键镜像表都在 App 侧，后端只持有安装副本
    menubar: None,
    menu_accel: [],
    shortcuts: [],
    next_shortcut_id: 0,
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
  self.windows.push(win)
  win
}

///|
/// 累计创建的窗口数
pub fn[B] App::window_count(self : App[B]) -> Int {
  self.windows.length()
}

///|
/// 仍存活的窗口数：`run()` 结束后应为 0，除非用户确实留着窗口没关。
pub fn[B] App::live_window_count(self : App[B]) -> Int {
  let mut n = 0
  for w in self.windows {
    if !w.is_closed() {
      n = n + 1
    }
  }
  n
}

///|
/// 订阅某个控件的事件，返回订阅 id 用于 `unsubscribe`。
/// 同一 target 可以有多个订阅，按订阅顺序触发。
pub fn[B] App::on_event(
  self : App[B],
  target : EventTarget,
  handler : (Event) -> Unit raise UiError,
) -> Int {
  let id = self.next_sub_id
  self.next_sub_id = id + 1
  self.subs.push(Subscription::{ id, target, handler, })
  id
}

///|
/// 退订。返回是否真的删掉了一条订阅，重复退订返回 `false`。
pub fn[B] App::unsubscribe(self : App[B], id : Int) -> Bool {
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
pub fn[B] App::subscription_count(self : App[B]) -> Int {
  self.subs.length()
}

///|
/// 把任务投递回 UI 线程（§27）。Worker 只能 `post`，不能直接碰 Widget。
/// 任务在下一轮循环、且在原生事件之前执行；循环结束后再 `post` 不会被执行。
pub fn[B] App::post(self : App[B], task : () -> Unit raise UiError) -> Unit {
  self.posted.push(task)
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
fn[B] App::run_posted(self : App[B]) -> Int raise UiError {
  let round = self.posted
  self.posted = []
  let n = round.length()
  for i = 0; i < n; i = i + 1 {
    round[i]()
  }
  n
}

///|
fn[B] App::is_subscribed(self : App[B], id : Int) -> Bool {
  let mut found = false
  for s in self.subs {
    if s.id == id {
      found = true
    }
  }
  found
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
/// 3. 最后走 `on_event` 注册的订阅，让观察者在界面状态已经更新之后收到通知。
/// 先快照再调用：派发过程中新增的订阅本轮不触发，被退订的不再调用。
pub fn[B : Backend] App::dispatch(
  self : App[B],
  ev : Event,
) -> Int raise UiError {
  let target = Event::target(ev)
  let mut hits = 0
  match ev {
    MenuSelect(t) =>
      match self.click_menu_item(t.id) {
        Some(_) => hits = hits + 1
        None => ()
      }
    _ => {
      for win in self.windows {
        if !win.is_closed() {
          if win.target().id == target.id {
            win.handle_event(ev)
          } else {
            match win.find_widget(target.id) {
              Some(w) => {
                let _ = w.fire(ev)
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
      (s.handler)(ev)
      hits = hits + 1
    }
  }
  hits
}

///|
/// 推进一圈：先跑 `post` 来的任务，再取一个原生事件派发。
/// 返回 `false` 表示这一轮既没有任务也没有事件。
pub fn[B : Backend] App::step(self : App[B]) -> Bool raise UiError {
  let tasks = self.run_posted()
  match Backend::poll_event(self.backend) {
    Some(ev) => {
      let _ = self.dispatch(ev)
      true
    }
    None => tasks > 0
  }
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
  let target = EventTarget::{ id: 7, }
  let seen : Array[Event] = []
  let _ = app.on_event(target, fn(ev) { seen.push(ev) })
  let b = app.backend()
  Backend::init(b)
  let _ = b.create_window("MoonUI", LogicalSize::{
    width: 800.0,
    height: 600.0,
  })
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
  let target = EventTarget::{ id: 1, }
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
  let _ = b.create_window("A", LogicalSize::{ width: 10.0, height: 10.0, })
  app.run()
  assert_true(app.is_finished())
  assert_eq(b.live(), 0)
}

///|
test "step 单轮语义：先任务后事件，都空时返回 false" {
  let app = App::new(MockBackend::new())
  let target = EventTarget::{ id: 3, }
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
  let log : Array[Int] = []
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
  let a = EventTarget::{ id: 10, }
  let other = EventTarget::{ id: 11, }
  let mut a_hits = 0
  let mut b_hits = 0
  let _ = app.on_event(a, fn(_) { a_hits = a_hits + 1 })
  let _ = app.on_event(a, fn(_) { a_hits = a_hits + 100 })
  let _ = app.on_event(other, fn(_) { b_hits = b_hits + 1 })
  assert_eq(app.dispatch(Click(a, Left)), 2)
  assert_eq(a_hits, 101)
  assert_eq(b_hits, 0)
  assert_eq(app.dispatch(Change(other)), 1)
  assert_eq(app.dispatch(Scroll(a, LogicalPoint::{ x: 0.0, y: 0.0, })), 2)
}

///|
test "unsubscribe 生效且幂等，派发中被退订的 handler 不再调用" {
  let app = App::new(MockBackend::new())
  let t = EventTarget::{ id: 5, }
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
  let target = EventTarget::{ id: 2, }
  let b = app.backend()
  Backend::init(b)
  let _ = b.create_window("Boom", LogicalSize::{ width: 10.0, height: 10.0, })
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
  let win = app.create_window("Main", LogicalSize::{
    width: 640.0,
    height: 480.0,
  })
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
  let win = b.create_window("Counter", LogicalSize::{
    width: 320.0,
    height: 240.0,
  })
  let target = EventTarget::{ id: win.id, }
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
  b.push_event(Resize(target, LogicalSize::{ width: 100.0, height: 80.0, }))
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
  let win = app.create_window("Counter", LogicalSize::{
    width: 200.0,
    height: 100.0,
  })
  let label = Widget::label(b, "Ab")
  let sp = Widget::spacer(b)
  win.set_content(Widget::row(b, 0.0, [sp, label]))
  let initial_x = label.bounds().origin.x
  let log : Array[String] = []
  let _ = label.on_click(fn() { log.push("clicked") })
  let observed : Array[Int] = []
  let _ = app.on_event(label.target(), fn(_) { observed.push(1) })
  // 界面状态必须在事件当时读：循环收尾时 terminate 会关掉后端
  let positions : Array[Double] = []
  let _ = app.on_event(win.target(), fn(_) raise UiError {
    positions.push(label.bounds().origin.x)
  })
  b.push_event(Event::Click(label.target(), MouseButton::Left))
  // 真实后端是"原生层先改尺寸、再发 Resize"
  Backend::set_window_size(b, win.handle(), LogicalSize::{
    width: 300.0,
    height: 100.0,
  })
  b.push_event(
    Event::Resize(win.target(), LogicalSize::{ width: 300.0, height: 100.0, }),
  )
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
  let win = app.create_window("Done", LogicalSize::{
    width: 100.0,
    height: 50.0,
  })
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
  let win = app.create_window("HiDPI", LogicalSize::{
    width: 200.0,
    height: 100.0,
  })
  let label = Widget::label(b, "Ab")
  let sp = Widget::spacer(b)
  win.set_content(Widget::row(b, 0.0, [sp, label]))
  assert_eq(label.bounds().origin.x, 176.0)
  MockBackend::set_window_scale(b, win.handle(), Scale::{ x: 2.0, y: 2.0, })
  Backend::set_window_size(b, win.handle(), LogicalSize::{
    width: 100.0,
    height: 50.0,
  })
  b.push_event(ScaleChanged(win.target(), Scale::{ x: 2.0, y: 2.0, }))
  assert_true(app.step())
  assert_eq(label.bounds().origin.x, 76.0)
  assert_eq(win.scale(), Scale::{ x: 2.0, y: 2.0, })
}
