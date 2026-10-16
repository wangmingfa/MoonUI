///|
/// 事件分发跟踪（设计文档 §9/§10 的派发三段路，`T88①`）：开关式的流水账——
/// 开着时每个事件的一次派发全程记成一条 `DispatchTrace`，经调用方注入的
/// sink 流出；关着（默认）零分配零调用，与旧账逐位同值（观察者加法的零开销
/// 闸门，沿 `T84` 帧钟与 `T86⑧` 识别缺席的同一条规矩）。
///
/// 记的是**派发**，不是事件本身：`Event` 一个变体不加（trace 是记录不是新
/// 事件），路由三段的顺序与语义一字不动——capture/直派/冒泡的逐格账在格子
/// 层面记录（每条传播订阅、每条直派订阅、每条 App 订阅记一格：accept 放行
/// 与否都记——"accept 与否"正是这条账的判据），窗口臂/菜单臂/主题臂只记
/// 路由结果（它们的格子不在树里，语义见 `App::dispatch` 段注）。
///
/// 记录口的快照纪律沿 `dispatch`：sink 在派发起点快照一次，handler 中途换
/// sink 不影响本回合；本回合的账在派发收尾整条流出（handler 失败沿 `dispatch`
/// 抛出、账不流出——失败路径上账本来就不完整）。
///
/// 两名字空间（记案）：`TraceStop.owner` 在 capture/direct/bubble 三段里是
/// **控件句柄 id**（布局节点没有句柄，哨兵 -1——`hit_test` 同一句缺席语义），
/// 在 subscribed 段里是 **App 订阅 id**（`App::on` 返回的那只）。两空间不同段
/// 不混用，判据按段断言。

///|
/// 流水里的一格：一条订阅/口的 accept 裁决。`owner` 见段注的名字空间注；
/// `accepted` = 过滤器放行（放行即 handler 真的跑了；挡下的格子只进账）。
pub(all) struct TraceStop {
  owner : Int32
  accepted : Bool
} derive(Debug, Eq)

///|
/// 路由结果（`T88①`）：这个事件在派发三段路里走进了哪条臂——
/// - `MenuHit(found)`：菜单栏臂，菜单项回调命中与否；
/// - `ThemeRefreshed(n)`：主题臂，refresh_style_base 落上的窗口数（后端给每只
///   存活窗口各发一条，一条只管一扇窗）；
/// - `WindowArm`：窗口臂，target 是窗口本身（Resize/Close 的特殊处理）；
/// - `TreeArm`：树臂，target 在内容树里找到（capture/直派/冒泡三段账有效）；
/// - `Missed`：树臂没找到、也不在窗口 target 上——事件谁也没接到（订阅臂
///   照跑，观察者仍然收到）。
pub(all) enum TraceRoute {
  MenuHit(Bool)
  ThemeRefreshed(Int32)
  WindowArm
  TreeArm
  Missed
} derive(Debug, Eq)

///|
/// 一次派发的全程账（`T88①`）。四段格子的顺序 = 执行顺序：capture 自根向叶、
/// direct 只认 target 的直派表、bubble 自叶向根、subscribed 是 target 命中的
/// App 订阅快照。`intercepted` = capture 阶段有人喊停——直派与冒泡账恒空
/// 的原因（`on_capture` 的语义，`T86⑨`）。
pub(all) struct DispatchTrace {
  event : Event
  /// 路由结果：派发途中由命中的那条臂覆写（accum 初值是 Missed——循环走完
  /// 没命中就是它）；菜单臂/主题臂在同一次命中判定下覆写（`app.mbt`）
  mut route : TraceRoute
  capture : Array[TraceStop]
  direct : Array[TraceStop]
  bubble : Array[TraceStop]
  /// capture 喊停位：由拦截发生的那一格在 `run_capture_phase` 原位立起
  mut intercepted : Bool
  subscribed : Array[TraceStop]
} derive(Debug, Eq)

///|
/// 开事件分发跟踪（`T88①`）：此后每次 `dispatch` 收尾把整条账交给 sink。
/// sink 不允许失败（记录是观察者不是参与者）；要失败请把失败收进你自己
/// 的账里。重复调用整只替换（沿 sink 的快照纪律）。
pub fn[B] App::set_event_trace(
  self : App[B],
  sink : (DispatchTrace) -> Unit,
) -> Unit {
  self.event_trace = Some(sink)
}

///|
/// 关事件分发跟踪（`T88①`）：此后派发零分配零调用，回到不开账的旧路径。
pub fn[B] App::clear_event_trace(self : App[B]) -> Unit {
  self.event_trace = None
}

///|
/// 流水格子的 owner 读口（`T88①`）：带句柄的记句柄 id，纯布局节点哨兵 -1
/// ——它进不了命中（§14），也进不了带 owner 的格子之外的任何账。
fn[B] Widget::trace_owner(self : Widget[B]) -> Int32 {
  match self.handle {
    Some(h) => h.id
    None => -1
  }
}

///|
/// 一段格子的记录口构造（`T88①`）：accept 裁决 → 钉好 owner 与段落的格子，
/// 推进对应臂的账。调用点在 accum 展开处（None 分支根本不构造，零分配）。
/// 段落芯（快照/逐格 accept/拦截的执行语义）住在 widget.mbt 原位——芯的
/// 执行账与记录账分开，记录口 None 时逐位走旧账。
fn trace_record(
  arm : (DispatchTrace, TraceStop) -> Unit,
  t : DispatchTrace,
  owner : Int32,
) -> (Bool) -> Unit {
  fn(accepted) { arm(t, TraceStop::{ owner, accepted, }) }
}

///|
/// 三层树判据的公共底座（沿 `T86⑨` 判据的树形状）：叶 → 中 → 根依次创建
/// （叶是 Button 持句柄 id 0；中/根是 Row/Column 纯布局节点，无句柄——
/// 判据里它们的格子 owner 哨兵 -1），窗口一只后建。
fn trace_tree() -> (
  MockBackend,
  App[MockBackend],
  Window[MockBackend],
  Widget[MockBackend],
  Widget[MockBackend],
  Widget[MockBackend],
) raise UiError {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let leaf = Widget::button(b, "叶")
  let mid = Widget::row(b, 0.0, [leaf])
  let root = Widget::column(b, 0.0, [mid])
  let win = app.create_window("MoonUI", LogicalSize(400.0, 300.0))
  win.set_content(root)
  (b, app, win, leaf, mid, root)
}

///|
/// `T88①` 判据·三层树形状复用：开账后一次派发的四段格子按执行顺序逐格
/// 入账——capture 自根向叶、直派缺席（没装直派订阅）、冒泡自叶向根、订阅
/// 快照照跑。命中数与不开账的旧账一字不差（直派命中不进 dispatch 返回值，
/// `T86⑨` 同一条读法）。
test "分发跟踪逐格入账：三层树 capture → 直派（缺席）→ 冒泡（T88①判据）" {
  let (b, app, _win, leaf, mid, root) = trace_tree()
  let _ = root.on_capture(fn(_) { true }, fn(_) { true })
  let _ = mid.on_capture(fn(_) { true }, fn(_) { true })
  let _ = leaf.on_capture(fn(_) { true }, fn(_) { true })
  let _ = leaf.on_bubble(fn(_) { true }, fn(_) { () })
  let _ = mid.on_bubble(fn(_) { true }, fn(_) { () })
  let _ = root.on_bubble(fn(_) { true }, fn(_) { () })
  let traces : Array[DispatchTrace] = []
  app.set_event_trace(fn(t) { traces.push(t) })
  let ev = Click(leaf.target(), MouseButton::Left)
  let hits = app.dispatch(ev)
  assert_eq(traces.length(), 1)
  let t = traces[0]
  assert_eq(t.event, ev)
  assert_eq(t.route, TreeArm)
  // 格子 owner：带句柄的记句柄 id，纯布局节点哨兵 -1（名字空间注）。顺序即
  // 路过顺序：capture 根(-1)→中(-1)→叶(0)，冒泡叶(0)→中(-1)→根(-1)；
  // 放行的格子 accepted = true
  assert_eq(t.capture, [
    TraceStop::{ owner: -1, accepted: true, },
    TraceStop::{ owner: -1, accepted: true, },
    TraceStop::{ owner: 0, accepted: true, },
  ])
  assert_eq(t.direct, [])
  assert_eq(t.bubble, [
    TraceStop::{ owner: 0, accepted: true, },
    TraceStop::{ owner: -1, accepted: true, },
    TraceStop::{ owner: -1, accepted: true, },
  ])
  assert_false(t.intercepted)
  assert_eq(t.subscribed, [])
  assert_eq(hits, 0)
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// `T88①` 判据·拦截入账：中层喊停——capture 账停在中层（accepted = true：
/// 跑了才拦得住），直派与冒泡账恒空、`intercepted` 位立起。拦截后派发的
/// 命中数照旧是 0（`T86⑨` 同账）。
test "分发跟踪拦截入账：capture 喊停，直派与冒泡账恒空（T88①判据）" {
  let (b, app, _win, leaf, mid, root) = trace_tree()
  let _ = root.on_capture(fn(_) { true }, fn(_) { true })
  // 中层拦截：返回 false 停止后续阶段（`on_capture` 的语义）
  let _ = mid.on_capture(fn(_) { true }, fn(_) { false })
  let _ = leaf.on_capture(fn(_) { true }, fn(_) { true })
  let _ = leaf.on_click(fn() { () })
  let traces : Array[DispatchTrace] = []
  app.set_event_trace(fn(t) { traces.push(t) })
  let hits = app.dispatch(Click(leaf.target(), MouseButton::Left))
  assert_eq(traces.length(), 1)
  let t = traces[0]
  assert_eq(t.capture, [
    TraceStop::{ owner: -1, accepted: true, },
    TraceStop::{ owner: -1, accepted: true, },
  ])
  assert_true(t.intercepted)
  assert_eq(t.direct, [])
  assert_eq(t.bubble, [])
  assert_eq(hits, 0)
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// `T88①` 判据·accept 与否：恒假过滤器的格子入账为 accepted = false——
/// 格子路过了、裁决了、没放行（handler 没跑）。挡下不是拦截：阶段照走，
/// 后续格子照记（与上一条拦截账互证）。
test "分发跟踪 accept 与否：挡下的格子入账 accepted = false（T88①判据）" {
  let (b, app, _win, leaf, mid, root) = trace_tree()
  let _ = root.on_capture(fn(_) { true }, fn(_) { true })
  // 中层恒假过滤器：格子进账（accepted = false）但阶段照走
  let _ = mid.on_capture(fn(_) { false }, fn(_) { true })
  let _ = leaf.on_capture(fn(_) { true }, fn(_) { true })
  let traces : Array[DispatchTrace] = []
  app.set_event_trace(fn(t) { traces.push(t) })
  let hits = app.dispatch(Click(leaf.target(), MouseButton::Left))
  let t = traces[0]
  assert_eq(t.capture, [
    TraceStop::{ owner: -1, accepted: true, },
    TraceStop::{ owner: -1, accepted: false, },
    TraceStop::{ owner: 0, accepted: true, },
  ])
  assert_false(t.intercepted)
  // 直派与冒泡照跑（挡下不改路径）；派发命中数与旧账同值
  assert_eq(hits, 0)
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// `T88①` 判据·直派与订阅账：直派订阅的格子进 direct（owner = target 自己），
/// App 订阅按 target 命中的快照逐格进 subscribed——订阅 id 是另一名字空间
/// （`App::on` 返回的编号），放行与否逐格可辨；命中数只计订阅段（既有读法）。
test "分发跟踪直派与订阅账：accepted 逐格入账，命中数只计订阅段（T88①判据）" {
  let (b, app, _win, leaf, _mid, _root) = trace_tree()
  let _ = leaf.on_click(fn() { () })
  let traces : Array[DispatchTrace] = []
  app.set_event_trace(fn(t) { traces.push(t) })
  // 两只订阅同一 target：恒真放行（订阅 id 0）、恒假挡下（订阅 id 1）
  let _ = app.on(leaf.target(), fn(_) { true }, fn(_) { () })
  let _ = app.on(leaf.target(), fn(_) { false }, fn(_) { () })
  let hits = app.dispatch(Click(leaf.target(), MouseButton::Left))
  let t = traces[0]
  assert_eq(t.route, TreeArm)
  assert_eq(t.direct, [TraceStop::{ owner: 0, accepted: true, }])
  assert_eq(t.subscribed, [
    TraceStop::{ owner: 0, accepted: true, },
    TraceStop::{ owner: 1, accepted: false, },
  ])
  assert_false(t.intercepted)
  assert_eq(hits, 1)
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// `T88①` 判据·臂身份：窗口臂（target 是窗口本身）、菜单臂（菜单项命中与否）、
/// 主题臂（refresh 落上的窗口数）、Missed（谁也没接到——订阅臂照跑）。
test "分发跟踪臂身份：窗口/菜单/主题/Missed 逐臂入账（T88①判据）" {
  let (b, app, win, _leaf, _mid, _root) = trace_tree()
  let traces : Array[DispatchTrace] = []
  app.set_event_trace(fn(t) { traces.push(t) })
  // 窗口臂：target 是窗口本身（树里的 leaf 收不到）
  let _ = app.dispatch(Resize(win.target(), LogicalSize(300.0, 200.0)))
  assert_true(traces[traces.length() - 1].route is WindowArm)
  assert_eq(traces[traces.length() - 1].capture, [])
  // 菜单臂：没登记过的菜单项 id，命中与否记 found = false
  let _ = app.dispatch(MenuSelect(EventTarget::{ id: 999, generation: 0, }))
  assert_eq(traces[traces.length() - 1].route, MenuHit(false))
  // 主题臂：refresh 落上的窗口数（一条事件只管一扇窗）
  let hits = app.dispatch(ThemeChanged(win.target(), Light))
  assert_eq(traces[traces.length() - 1].route, ThemeRefreshed(1))
  assert_eq(hits, 1)
  // Missed：target 既不在树里也不在窗口上——四段账恒空，缺席本身就是账
  let _ = app.dispatch(Click(EventTarget::{ id: 98, generation: 0, }, Left))
  let t = traces[traces.length() - 1]
  assert_eq(t.route, Missed)
  assert_eq(t.capture, [])
  assert_eq(t.direct, [])
  assert_eq(t.bubble, [])
  assert_eq(t.subscribed, [])
  assert_false(t.intercepted)
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// `T88①` 判据·零开销闸门（负控制）：关账（默认与 `clear_event_trace` 之后）
/// 不立账不流出——旧路径零分配零调用，行为与旧账逐位同值。
test "分发跟踪关账：不流出不立账，行为与旧账同值（T88①判据·负控制）" {
  let (b, app, _win, leaf, _mid, _root) = trace_tree()
  let traces : Array[DispatchTrace] = []
  app.set_event_trace(fn(t) { traces.push(t) })
  app.clear_event_trace()
  // 关账后派发：没有账流出，命中数与开账同一读法
  let hits = app.dispatch(Click(leaf.target(), MouseButton::Left))
  assert_eq(traces, [])
  assert_eq(hits, 0)
  // 默认就没开账：同一只 App 换只新的也不立账
  let fresh : Array[DispatchTrace] = []
  app.set_event_trace(fn(t) { fresh.push(t) })
  let _ = app.dispatch(Change(leaf.target()))
  app.clear_event_trace()
  let _ = app.dispatch(Change(leaf.target()))
  assert_eq(fresh.length(), 1)
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}
