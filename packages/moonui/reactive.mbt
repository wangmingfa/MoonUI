///|
/// 响应式（MVVM）数据驱动 —— Layer 1 引擎（`T284`，DESIGN §53.3）。
///
/// 放 Core 而不是独立包的原因（2026-11-15 落地偏差，记 DESIGN §53.10）：
/// MoonBit 错误类型是**名义**的——独立包必须自带错误类型，而绑定层（同在
/// Core，`raise UiError`）调用 `Signal::get`/`set` 就无法直接组合，每个绑定都要
/// 翻译一次。引擎放 Core 直接用 `UiError`，绑定层零翻译。引擎本身仍是
/// 后端无关的（不碰 Backend、不碰 Widget），Core 的 wasm 门禁照常成立。
///
/// 四条工具链硬约束（§53.1，2026-11-15 在 `/tmp/mbprobe-reactive` 实测）：
/// - 无 `dyn` / trait 对象 → 不用统一基类，泛型 `Signal[T]` + 闭包订阅。
/// - 无顶层 `let mut` → 全局追踪上下文用"顶层不可变绑定 + 堆内 mut 结构体"
///   （`TrackCtx` / `GenRef`）。
/// - 有堆内可变全局（实测断言通过）→ 依赖追踪可行。
/// - 闭包可自引用存储 → 订阅机制可行。
///
/// 错误传播沿 §33：`get`/`set`/`computed`/`effect` 都能 `raise UiError`，不吞。

///|
/// 活计数器：不可变绑定 + 堆内 `mut`，跨闭包共享（§53.6 实测）。
pub(all) struct GenRef {
  mut value : Int32
}

///|
fn GenRef::GenRef() -> GenRef {
  { value: 0, }
}

///|
/// 递增并返回新值。effect/computed 每次求值 bump 一次，旧订阅立刻失效。
fn GenRef::bump(self : GenRef) -> Int32 {
  self.value = self.value + 1
  self.value
}

///|
/// 一个追踪帧：一次 effect/computed 求值期间的依赖收集上下文。
///
/// `gen_ref` 是活计数器，`gen` 是本帧创建时的快照。`Signal::get` 在追踪中把
/// `(gen_ref, gen)` 存进被读 Signal 的订阅表，触发时比对——不等即旧帧残留
/// （代际失效，R2）。`notify` 是"依赖变了要做什么"：effect 帧是排程重跑，
/// computed 帧是标脏 + 通知下游。
priv struct Frame {
  gen_ref : GenRef
  gen : Int32
  mut dep_count : Int32
  notify : () -> Unit raise UiError
}

///|
fn Frame::Frame(
  gen_ref : GenRef,
  gen : Int32,
  notify : () -> Unit raise UiError,
) -> Frame {
  { gen_ref, gen, dep_count: 0, notify, }
}

///|
priv struct TrackCtx {
  stack : Array[Frame]
}

///|
let track_ctx : TrackCtx = TrackCtx::{ stack: [], }

///|
/// 当前追踪帧（栈顶），不在追踪中返回 `None`。
fn track_current() -> Frame? {
  let n = track_ctx.stack.length()
  if n > 0 {
    Some(track_ctx.stack[n - 1])
  } else {
    None
  }
}

///|
/// 压入一帧。调用方负责在求值结束后 `track_pop`。
fn track_push(frame : Frame) -> Unit {
  track_ctx.stack.push(frame)
}

///|
/// 弹出栈顶帧。
fn track_pop() -> Unit {
  let _ = track_ctx.stack.pop()
}

///|
/// 一条订阅（`Sub`）：`gen_ref = None` 是永久订阅（`subscribe`，绑定层用），
/// `Some` 是帧追踪订阅（effect/computed 依赖，代际失效）。
pub(all) struct Sub {
  gen_ref : GenRef?
  gen : Int32
  /// 永久订阅的 id（`subscribe` 返回的那只，从 1 起）；帧追踪订阅无 id（`-1`）。
  id : Int32
  call : () -> Unit raise UiError
}

///|
/// 一条永久订阅（绑定层）：`gen_ref = None`，永不失效。
fn Sub::permanent(id : Int32, call : () -> Unit raise UiError) -> Sub {
  { gen_ref: None, gen: 0, id, call, }
}

///|
/// 一条帧追踪订阅：`gen_ref = Some`，触发时比对活值，失效即跳过。
fn Sub::tracked(
  gen_ref : GenRef,
  gen : Int32,
  call : () -> Unit raise UiError,
) -> Sub {
  { gen_ref: Some(gen_ref), gen, id: -1, call, }
}

///|
/// 响应式单元：读 `get` 在追踪中注册依赖，写 `set` 通知订阅者。
///
/// `compute` 为 `Some` 时是**惰性 computed**（§53.3）：`dirty` 置位后，下一次
/// `get` 才重跑 `compute` 求值。`set` 对 computed 抛 `Unsupported`（只读，R5）。
/// `compute_gen` 是 computed 的代际计数器（`compute = None` 时无意义）。
pub struct Signal[T] {
  mut value : T
  subs : Array[Sub]
  id : Int32
  mut next_sub_id : Int32
  compute : (() -> T raise UiError)?
  mut dirty : Bool
  compute_gen : GenRef?
  mut notifying : Bool
  /// R4（§53.7）：computed 求值中标记。`recompute` 进入时看到已置位即循环依赖
  /// （computed A 读 B、B 读 A），`raise Unsupported`。
  mut running : Bool
  /// Eq 短路（2026-11-15，记 §53.10-⑧）：`Some` 时 `recompute` 用它比较新旧值，
  /// 相等即"值没变"，不通知下游（rabbita 的 "equal results stop propagating"）。
  /// 普通信号填 `None`（总是通知）；`computed`（`T : Eq`）填 `Some(==)`。
  eq : ((T, T) -> Bool)?
}

///|
/// 新建一个普通（可变）响应式单元。
pub fn[T] Signal::Signal(initial : T) -> Signal[T] {
  {
    value: initial,
    subs: [],
    id: 0,
    next_sub_id: 1,
    compute: None,
    dirty: false,
    compute_gen: None,
    notifying: false,
    running: false,
    eq: None,
  }
}

///|
/// 读值。在追踪上下文（effect/computed 求值中）里读，会把自己注册成依赖。
///
/// computed 且 `dirty` 时先重跑求值（惰性，R5 的只读由 `set` 拦）。
/// 求值函数允许失败，失败从本方法传出（§33 不吞异常）。
pub fn[T] Signal::get(self : Signal[T]) -> T raise UiError {
  if self.compute is Some(_) && self.dirty {
    let _ = self.recompute()
  }
  match track_current() {
    Some(frame) => {
      let gen = frame.gen
      self.subs.push(
        Sub::tracked(frame.gen_ref, gen, fn() raise UiError { (frame.notify)() }),
      )
      frame.dep_count = frame.dep_count + 1
    }
    None => ()
  }
  self.value
}

///|
/// 读值但不注册依赖、也不触发惰性重算。对 computed 返回**可能过期的**当前值；
/// 需要新鲜值且能承受依赖追踪时用 `get`。
pub fn[T] Signal::peek(self : Signal[T]) -> T {
  self.value
}

///|
/// 写值并通知订阅者。对 computed 抛 `Unsupported`（只读，R5）。
///
/// 通知只**排程**依赖的 effect（`mark_dirty` → 入队），最外层 set 收尾时
/// `flush` 一次（批处理，R3）；绑定层的直接订阅在 `notify_subs` 内同步执行。
pub fn[T] Signal::set(self : Signal[T], v : T) -> Unit raise UiError {
  if self.compute is Some(_) {
    raise Unsupported("computed 是只读的，不能 set")
  }
  self.value = v
  react_state.depth = react_state.depth + 1
  self.notify_subs()
  react_state.depth = react_state.depth - 1
  if react_state.depth == 0 {
    flush()
  }
}

///|
/// 用函数更新当前值并通知。等价于 `set(f(get()))`，但读当前值不走依赖追踪。
pub fn[T] Signal::update(self : Signal[T], f : (T) -> T) -> Unit raise UiError {
  self.set(f(self.value))
}

///|
/// 写值并通知订阅者，但**新值等于旧值时不通知**（Eq 短路，§53.10-⑧）。
///
/// 解决"值没变却重渲"——滑块拖过同值、`bind_text_fmt` 四舍五入到同一文案这类
/// 场景，`set` 会通知订阅者（effect 重跑、绑定回写）而 `set_if_changed` 不会。
/// `T : Eq` 是比较前提。对 computed 抛 `Unsupported`（只读，R5）。
pub fn[T : Eq] Signal::set_if_changed(
  self : Signal[T],
  v : T,
) -> Unit raise UiError {
  if v != self.value {
    self.set(v)
  }
}

///|
/// 永久订阅（绑定层与高级用）：`set` 后回调被调用。不做代际失效——
/// 订阅者随控件 `close_tree` 时手动 `unsubscribe`（R1，见绑定层）。
/// 返回订阅 id（从 1 起，0 是"从未分配"哨兵），`unsubscribe` 按 id 摘。
pub fn[T] Signal::subscribe(
  self : Signal[T],
  f : () -> Unit raise UiError,
) -> Int32 {
  let id = self.next_sub_id
  self.next_sub_id = self.next_sub_id + 1
  self.subs.push(Sub::permanent(id, f))
  id
}

///|
/// 永久订阅的取消（R1）：按 `subscribe` 返回的 id 把这条订阅从表里摘掉。
/// 未知 id 幂等（表里没有就是没有）。
pub fn[T] Signal::unsubscribe(self : Signal[T], id : Int32) -> Unit {
  let mut i = 0
  while i < self.subs.length() {
    let s = self.subs[i]
    if s.gen_ref is None && s.id == id {
      let _ = self.subs.remove(i)
    } else {
      i = i + 1
    }
  }
}

///|
/// 通知全部活订阅；结束后清扫失效订阅（代际失效，R2）。
///
/// `notifying` 防重入：订阅回调里再 `set` 同一只 Signal（罕见但可能），不递归
/// 通知，只把值改掉——下一轮谁读谁见新值。
fn[T] Signal::notify_subs(self : Signal[T]) -> Unit raise UiError {
  if self.notifying {
    return
  }
  self.notifying = true
  // 快照：订阅回调可能 push/remove，不能在原数组上边遍历边改
  let snapshot = self.subs.copy()
  for sub in snapshot {
    if sub_is_live(sub) {
      (sub.call)()
    }
  }
  // 清扫失效（代际不符）
  let mut i = 0
  while i < self.subs.length() {
    if !sub_is_live(self.subs[i]) {
      let _ = self.subs.remove(i)
    } else {
      i = i + 1
    }
  }
  self.notifying = false
}

///|
fn sub_is_live(sub : Sub) -> Bool {
  match sub.gen_ref {
    None => true
    Some(g) => g.value == sub.gen
  }
}

///|
/// 惰性 computed 的重算：bump 代际、压追踪帧、跑求值、写回值并清脏位。
///
/// 只在 `dirty` 时被 `get` 调用。求值失败会 `raise`（§33），调用方（`get`）
/// 传出；脏位此时不置回（下次 `get` 再试）。
fn[T] Signal::recompute(self : Signal[T]) -> Bool raise UiError {
  match self.compute {
    Some(f) => {
      if self.running {
        // R4（§53.7）：computed A 读 B、B 读 A——重入求值即循环依赖。
        raise Unsupported("循环依赖：computed 相互读取")
      }
      self.running = true
      let old = self.value
      let gen = match self.compute_gen {
        Some(g) => g
        None => GenRef()
      }
      let g = gen.bump()
      track_push(Frame(gen, g, fn() raise UiError { self.mark_dirty() }))
      let err = try {
        let v = f()
        self.value = v
        self.dirty = false
        None
      } catch {
        e => Some(e)
      }
      track_pop()
      self.running = false
      match err {
        Some(e) => raise e
        None => ()
      }
      // Eq 短路（§53.10-⑧）：值没变返回 false，调用方（mark_dirty）据此
      // 不通知下游（"equal results stop propagating"）。
      match self.eq {
        Some(eq) => !eq(old, self.value)
        None => true
      }
    }
    None => true
  }
}

///|
/// computed 的"依赖变了"回调：标脏 + 通知下游（读这个 computed 的帧）。
/// 下游帧收到通知后重跑，重跑时读 `get` 会触发 `recompute`。
fn[T] Signal::mark_dirty(self : Signal[T]) -> Unit raise UiError {
  if self.compute is Some(_) {
    self.dirty = true
    // Eq 短路（§53.10-⑧）：有下游订阅时及时重算，值没变就不通知下游。
    // 无下游订阅时保持惰性（下次 `get` 才重算）——没人读，重算是白做。
    if self.subs.length() > 0 {
      let err = try {
        let changed = self.recompute()
        if !changed {
          // 值没变：不通知下游（"equal results stop propagating"）。
          return
        }
        None
      } catch {
        e => Some(e)
      }
      match err {
        // 重算失败：保持 dirty（下次 get 再试并抛出），仍通知下游——
        // 错误沿传播路径交给读它的帧，不吞（§33）。
        Some(_) => ()
        None => ()
      }
    }
  }
  self.notify_subs()
}

///|
/// 派生响应式单元：`f` 首次求值得初值，任一依赖变化 → 标脏 → 下游帧被通知；
/// 下一次 `get` 才重跑 `f`（惰性）。返回的 Signal 是**只读**的（`set` 抛
/// `Unsupported`，R5）。
///
/// 鸡生蛋：`f` 求值期间需要"依赖变了"的回调，而回调要引用返回的 Signal。用
/// `self_ref` 槽——`f` 求值期间没有任何依赖会变化（构造阶段），槽在构造
/// 完成后才填，之后依赖变化走 `Signal::mark_dirty`。
pub fn[T : Eq] computed(f : () -> T raise UiError) -> Signal[T] raise UiError {
  let gen = GenRef()
  let mut self_ref : Signal[T]? = None
  track_push(
    Frame(gen, 0, fn() raise UiError {
      match self_ref {
        Some(r) => r.mark_dirty()
        None => ()
      }
    }),
  )
  let err = try {
    let v = f()
    let r = Signal::{
      value: v,
      subs: [],
      id: 0,
      next_sub_id: 1,
      compute: Some(f),
      dirty: false,
      compute_gen: Some(gen),
      notifying: false,
      running: false,
      eq: Some(fn(a, b) { a == b }),
    }
    self_ref = Some(r)
    None
  } catch {
    e => Some(e)
  }
  track_pop()
  match err {
    Some(e) => raise e
    None => ()
  }
  match self_ref {
    Some(r) => r
    None => raise OperationFailed("computed 求值未产生值")
  }
}

///|
/// 全局调度账：排程中的 effect（去重靠 `Effect::pending`）+ 嵌套深度。
///
/// `depth > 0` = 正在一次 `set` 的通知或一次 `flush` 里；嵌套排程只入队，
/// 最外层收尾才跑。UI 单线程，无锁。
priv struct ReactState {
  mut depth : Int32
  pending : Array[Effect]
}

///|
let react_state : ReactState = ReactState::{ depth: 0, pending: [], }

///|
/// 一只 effect 的句柄。`stop` 停链；句柄本身不持有 UI 对象（R1 不适用——
/// effect 的闭包由调用方持有，停链只是翻一位）。
pub struct Effect {
  gen_box : GenRef
  mut running : Bool
  mut dirty : Bool
  mut stopped : Bool
  mut pending : Bool
  run : () -> Unit raise UiError
}

///|
/// 副作用 effect：立即跑 `f` 收集依赖；依赖变化 → 排程重跑（`flush` 时）。
/// 返回句柄，`stop` 停链。
pub fn effect(f : () -> Unit raise UiError) -> Effect raise UiError {
  let eff = Effect::{
    gen_box: GenRef(),
    running: false,
    dirty: false,
    stopped: false,
    pending: false,
    run: f,
  }
  eff.run_once()
  if react_state.depth == 0 {
    flush()
  }
  eff
}

///|
/// 停链：之后依赖变化不再触发重跑，已排程的也不跑。幂等。
pub fn Effect::stop(self : Effect) -> Unit {
  self.stopped = true
  self.pending = false
}

///|
/// 依赖变了：标脏 + 排程。`stop` 之后是空操作。
fn Effect::mark_dirty(self : Effect) -> Unit {
  if self.stopped {
    return
  }
  self.dirty = true
  self.schedule()
}

///|
/// 入排程队列（去重）。
fn Effect::schedule(self : Effect) -> Unit {
  if self.pending {
    return
  }
  self.pending = true
  react_state.pending.push(self)
}

///|
/// 立即跑一轮 `f`：bump 代际、压追踪帧、跑、弹帧。
fn Effect::run_once(self : Effect) -> Unit raise UiError {
  if self.stopped {
    return
  }
  self.running = true
  self.dirty = false
  self.pending = false
  let g = self.gen_box.bump()
  track_push(Frame(self.gen_box, g, fn() { self.mark_dirty() }))
  let err = try {
    (self.run)()
    None
  } catch {
    e => Some(e)
  }
  track_pop()
  self.running = false
  match err {
    Some(e) => raise e
    None => ()
  }
}

///|
/// 排空排程队列：最外层调用才真正跑；嵌套调用（`flush` 里再 `set`）只入队，
/// 由外层循环拾起。`depth` 防重入。
pub fn flush() -> Unit raise UiError {
  if react_state.depth > 0 {
    return
  }
  react_state.depth = react_state.depth + 1
  while react_state.pending.length() > 0 {
    let jobs = react_state.pending.copy()
    react_state.pending.clear()
    for eff in jobs {
      eff.pending = false
      if !eff.stopped && eff.dirty {
        eff.run_once()
      }
    }
  }
  react_state.depth = react_state.depth - 1
}

///|
/// 显式批处理（R3）：`f` 里的多次 `set` 只触发一次 flush，依赖的 effect 每轮
/// 只跑一次。`batch(fn() { a.set(1); b.set(2); c.set(3) })` 的 effect 跑一次，
/// 不带 `batch` 的三个顺序 `set` 各跑一次。这是 R3 的显式收口——引擎不知道
/// 事件处理的边界在哪，批处理的边界由调用方给。
pub fn batch(f : () -> Unit raise UiError) -> Unit raise UiError {
  react_state.depth = react_state.depth + 1
  let err = try {
    f()
    None
  } catch {
    e => Some(e)
  }
  react_state.depth = react_state.depth - 1
  if react_state.depth == 0 {
    flush()
  }
  match err {
    Some(e) => raise e
    None => ()
  }
}

///|
/// 观察一个响应式单元：`source` 变化时回调 `(旧值, 新值)`。用 effect 实现——
/// 每次重跑读 `get`（注册依赖），与缓存旧值比对，不同才回调。`T : Eq` 是
/// 比对的前提。
pub fn[T : Eq] watch(
  source : Signal[T],
  cb : (T, T) -> Unit raise UiError,
) -> Effect raise UiError {
  let mut old = source.peek()
  effect(fn() raise UiError {
    let new = source.get()
    if new != old {
      let prev = old
      old = new
      cb(prev, new)
    }
  })
}

///|
/// 派生糖（2026-11-16，`T292`）：`self.map(f)` 等价于
/// `computed(fn() { f(self.get()) })`——单信号派生的书写简化。
/// `U : Eq` 沿 `computed` 的短路前提；`f` 允许失败（§33）。
pub fn[T, U : Eq] Signal::map(
  self : Signal[T],
  f : (T) -> U raise UiError,
) -> Signal[U] raise UiError {
  computed(fn() raise UiError { f(self.get()) })
}
