///|
/// 原生句柄与句柄表（设计文档 §6、§7、§47 风险 2）。
///
/// Core 与公共 API 只看到 `NativeHandle`（id + generation），永远看不到
/// `uiButton*` / `HWND` / `SDL_Window*`。真实指针只在 Backend 内部通过
/// `HandleTable` 换取，这样文档 §47 里的"悬垂指针 / double free"从运行期
/// 未定义行为变成框架内可判定的错误——也就能在不依赖任何真后端的情况下先用
/// 单测把生命周期语义锁住。

///|
/// 交给 Backend 保管的原生对象地址。
///
/// 必须用 `Int64` 而不是 `Int`：MoonBit 的 `Int` 是 32 位，而 native FFI 传的是
/// x64 指针（tests/ffi 在 MSVC/x64 上验证了这点），用 `Int` 会把地址截断成野指针。
/// Core 不解引用它，只做透传与相等性判断。
pub(all) struct NativePtr(Int64) derive(Debug, Eq)

///|
/// 不透明句柄。id 会复用，因此必须配合 generation，旧句柄不会命中新对象。
pub(all) struct NativeHandle {
  id : Int32
  generation : Int32
} derive(Debug, Eq)

///|
struct HandleSlot {
  generation : Int32
  ptr : NativePtr
  mut alive : Bool
}

///|
/// id -> 原生指针的登记表。所有 Backend 共用同一套生命周期语义。
pub struct HandleTable {
  slots : Array[HandleSlot]
  free_ids : Array[Int32]
  mut live_count : Int32
  /// `T88①` 读数化的另一半：存活读数的历史峰值（高水位）。register 里顺手
  /// 记账，unregister 不减——归零之后的账还在，泄漏检查断的是"峰值多少、
  /// 当下多少"，比单点归零多一个读数维度。
  mut high_water : Int32
}

///|
pub fn HandleTable::new() -> HandleTable {
  HandleTable::{ slots: [], free_ids: [], live_count: 0, high_water: 0, }
}

///|
/// 越界访问返回 `None`，而不是像 `slots[i]` 那样直接失败——句柄 id 来自
/// 用户侧，可能早已失效，必须走可恢复的错误路径。
fn slot_at(table : HandleTable, id : Int32) -> HandleSlot? {
  if id >= 0 && id < table.slots.length() {
    Some(table.slots[id])
  } else {
    None
  }
}

///|
/// 登记一个新对象，返回可用于后续调用的句柄。
pub fn HandleTable::register(
  self : HandleTable,
  ptr : NativePtr,
) -> NativeHandle {
  let id = match self.free_ids.pop() {
    Some(id) => id
    None => self.slots.length()
  }
  let generation = match slot_at(self, id) {
    Some(slot) => slot.generation + 1
    None => 0
  }
  let slot = HandleSlot::{ generation, ptr, alive: true, }
  if id < self.slots.length() {
    self.slots[id] = slot
  } else {
    self.slots.push(slot)
  }
  self.live_count += 1
  if self.live_count > self.high_water {
    self.high_water = self.live_count
  }
  NativeHandle::{ id, generation, }
}

///|
/// 换取真实指针。句柄过期或已销毁时抛 `UiError::InvalidHandle`，
/// 而不是把野指针交给 C。
pub fn HandleTable::resolve(
  self : HandleTable,
  h : NativeHandle,
) -> NativePtr raise UiError {
  let slot = match slot_at(self, h.id) {
    Some(s) => s
    None => raise InvalidHandle
  }
  if slot.generation != h.generation || !slot.alive {
    raise InvalidHandle
  }
  slot.ptr
}

///|
/// 注销对象。重复注销抛 `UiError::Destroyed`，让 double free 变成可测错误。
pub fn HandleTable::unregister(
  self : HandleTable,
  h : NativeHandle,
) -> Unit raise UiError {
  let slot = match slot_at(self, h.id) {
    Some(s) => s
    None => raise InvalidHandle
  }
  if !slot.alive {
    raise Destroyed
  }
  if slot.generation != h.generation {
    raise InvalidHandle
  }
  slot.alive = false
  self.free_ids.push(h.id)
  self.live_count -= 1
}

///|
/// 当前存活对象数，供泄漏检查（集成测试断言退出时应归零）。
pub fn HandleTable::live(self : HandleTable) -> Int32 {
  self.live_count
}

///|
/// 句柄表统计读数（`T88①`）：当下存活数 + 历史峰值。归零断言的产物变成
/// 可读数——退出时 `stats.live == 0` 与既有归零断言同义，`stats.high_water`
/// 额外回答"这一轮最多同时活过多少只"，回归载体（退场时句柄泄漏的排查）
/// 不用再靠临时打印现场重跑。两平台共用同一份（读的是同一张表，零 C）。
pub(all) struct HandleStats {
  live : Int32
  high_water : Int32
} derive(Debug, Eq)

///|
/// 逐字段统计读数（`T88①`）。与 `live()` 并存：`live` 是单点读数（既有调用
/// 一个字不动），`stats` 是成对的读数账。
pub fn HandleTable::stats(self : HandleTable) -> HandleStats {
  HandleStats::{ live: self.live_count, high_water: self.high_water, }
}

///|
/// 存活句柄清单，供 Backend 退出时统一回收未显式销毁的对象。
pub fn HandleTable::alive_handles(self : HandleTable) -> Array[NativeHandle] {
  let out : Array[NativeHandle] = []
  for i = 0; i < self.slots.length(); i = i + 1 {
    let slot = self.slots[i]
    if slot.alive {
      out.push(NativeHandle::{ id: i, generation: slot.generation, })
    }
  }
  out
}

///|
/// 句柄是否仍指向存活对象，供 UI 线程派发事件时做快速判定。
pub fn HandleTable::is_alive(self : HandleTable, h : NativeHandle) -> Bool {
  match slot_at(self, h.id) {
    Some(s) => s.alive && s.generation == h.generation
    None => false
  }
}

///|
/// 反查"这个原生对象是我们的哪个控件/窗口"，认不出来给 `None`。
///
/// 键盘和焦点的原生来源只给对象本身（`keyDown:` 的那个 view、`WM_KEYDOWN` 的那个
/// HWND、窗口的 firstResponder），句柄在 MoonBit 这一侧，所以"通知不带内容、内容回读"
/// 那条约定（§48-16）要靠这一问把地址换回句柄。认不出来是常态而不是错误：焦点在窗口
/// 自己或原生层内部的辅助对象上时，后端报的就是一个没登记过的地址。
///
/// 答案是唯一的——`register` 只会把指针写进空格子，所以同一个地址最多落在一个存活
/// 槽里（注销之后格子先标死再复用，旧句柄靠 generation 失活）。
pub fn HandleTable::find_alive(
  self : HandleTable,
  ptr : NativePtr,
) -> NativeHandle? {
  for i = 0; i < self.slots.length(); i = i + 1 {
    let slot = self.slots[i]
    if slot.alive && slot.ptr == ptr {
      return Some(NativeHandle::{ id: i, generation: slot.generation, })
    }
  }
  None
}

///|
test "句柄表登记与换取指针" {
  let table = HandleTable::new()
  let h = table.register(NativePtr(1000L))
  assert_eq(h, NativeHandle::{ id: 0, generation: 0, })
  assert_eq(table.resolve(h), NativePtr(1000L))
  assert_eq(table.live(), 1)
  let h2 = table.register(NativePtr(2000L))
  assert_eq(h2, NativeHandle::{ id: 1, generation: 0, })
  assert_eq(table.live(), 2)
  table.unregister(h)
  assert_eq(table.live(), 1)
  assert_false(table.is_alive(h))
  assert_true(table.is_alive(h2))
}

///|
test "id 复用不会让旧句柄命中新对象" {
  let table = HandleTable::new()
  let first = table.register(NativePtr(100L))
  table.unregister(first)
  // 同一个 id 被复用，但 generation 递增，旧句柄随之失效
  let second = table.register(NativePtr(200L))
  assert_eq(second.id, first.id)
  assert_true(second.generation != first.generation)

  let err = try {
    let _ = table.resolve(first)
    None
  } catch {
    e => Some(e.message())
  }
  assert_eq(err, Some("无效的原生句柄"))

  let ok = Some(table.resolve(second)) catch { _ => None }
  assert_eq(ok, Some(NativePtr(200L)))
}

///|
test "double free 表现为 Destroyed 而不是崩溃" {
  let table = HandleTable::new()
  let h = table.register(NativePtr(42L))
  table.unregister(h)
  let msg = try {
    table.unregister(h)
    None
  } catch {
    e => Some(e.message())
  }
  assert_eq(msg, Some("对象已销毁"))
  assert_eq(table.live(), 0)
}

///|
test "从未注册过的句柄返回无效句柄" {
  let table = HandleTable::new()
  let msg = try {
    let _ = table.resolve(NativeHandle::{ id: 99, generation: 0, })
    None
  } catch {
    e => Some(e.message())
  }
  assert_eq(msg, Some("无效的原生句柄"))
  assert_false(table.is_alive(NativeHandle::{ id: 99, generation: 0, }))
  // 负 id 也不能绕过检查
  assert_false(table.is_alive(NativeHandle::{ id: -1, generation: 0, }))
}

///|
test "注册与注销交替进行且计数不漂移" {
  let table = HandleTable::new()
  let handles = []
  for i = 0; i < 8; i = i + 1 {
    handles.push(table.register(NativePtr((i * 10).to_int64())))
  }
  assert_eq(table.live(), 8)
  for h in handles {
    table.unregister(h)
  }
  assert_eq(table.live(), 0)
  // 全部释放后新注册复用回收的 id，generation 继续递增
  let again = table.register(NativePtr(777L))
  assert_eq(again.id, 7)
  assert_eq(table.resolve(again), NativePtr(777L))
}

///|
test "反查地址：存活的认得出，注销的和没登记的认不出" {
  let table = HandleTable::new()
  let a = table.register(NativePtr(11L))
  let b = table.register(NativePtr(22L))
  assert_eq(table.find_alive(NativePtr(11L)), Some(a))
  assert_eq(table.find_alive(NativePtr(22L)), Some(b))
  // 后端在"焦点不落在我们控件上"时报的是一个没登记过的地址，那是常态不是错误
  assert_eq(table.find_alive(NativePtr(33L)), None)
  // 0 是"没有对象"的约定值，而它根本进不了表（ffi 的 register 当场拦下）
  assert_eq(table.find_alive(NativePtr(0L)), None)

  table.unregister(a)
  // 注销之后同一个地址必须认不出：事件要是还往这个对象上派，Core 不能拿它去查树，
  // 拿着旧句柄就更不行（find_alive 靠 alive 位而不是只比地址）
  assert_eq(table.find_alive(NativePtr(11L)), None)
  // b 不受影响
  assert_eq(table.find_alive(NativePtr(22L)), Some(b))
}

///|
test "反查在 id 复用之后给出的是新句柄" {
  let table = HandleTable::new()
  let first = table.register(NativePtr(100L))
  table.unregister(first)
  // 地址会随对象一起没，所以正常路径上不会有两个存活句柄共享地址；这里量的是
  // "格子复用之后，反查跟着给出新的那一份"
  let second = table.register(NativePtr(200L))
  assert_eq(second.id, first.id)
  assert_eq(table.find_alive(NativePtr(100L)), None)
  assert_eq(table.find_alive(NativePtr(200L)), Some(second))
  assert_eq(table.resolve(second), NativePtr(200L))
}

///|
/// `T88①` 判据·读数化：归零断言的产物变成可读数。峰值在 register 时顺手记下，
/// 注销不减——全注销后 `live == 0`（与既有归零断言同义）而 `high_water == 8`
/// 还在，回答"这一轮最多同时活过多少只"；空表峰值 0。
test "句柄表统计：live 归零后高水位还在（T88①判据）" {
  let table = HandleTable::new()
  assert_eq(table.stats(), HandleStats::{ live: 0, high_water: 0, })
  let batch : Array[NativeHandle] = []
  for i = 0; i < 8; i = i + 1 {
    batch.push(table.register(NativePtr((i * 10).to_int64())))
  }
  assert_eq(table.stats(), HandleStats::{ live: 8, high_water: 8, })
  // 中途注销一半：当下读数下降，峰值不跟——峰值的语义是"活过的最高点"
  for i = 0; i < 4; i = i + 1 {
    table.unregister(batch[i])
  }
  assert_eq(table.stats(), HandleStats::{ live: 4, high_water: 8, })
  // 再注册 4 只到峰值：读数追平，不超出（复用的 id 挂新代句柄——
  // 注销过的旧代本来已死，不进注销账）
  let again : Array[NativeHandle] = []
  for i = 0; i < 4; i = i + 1 {
    again.push(table.register(NativePtr((i * 100).to_int64())))
  }
  assert_eq(table.stats(), HandleStats::{ live: 8, high_water: 8, })
  // 幸存的一半 + 新一代：注销账交织到头，归零（既有断言的读法）而峰值原地——
  // 泄漏检查的两个读数维度都在
  for i = 4; i < 8; i = i + 1 {
    table.unregister(batch[i])
  }
  for h in again {
    table.unregister(h)
  }
  assert_eq(table.stats(), HandleStats::{ live: 0, high_water: 8, })
}

///|
/// MockBackend 消费同一张表：`T88①` 读数经后端取（Mock 的 `live()` 单点读数
/// 一个字不动，`handle_stats` 是成对读数的通道）。判据沿 App 生命周期走完整
/// 一圈——建窗（峰值涨）→ 关窗（live 回落）→ terminate 回收（归零），峰值仍在。
test "MockBackend 的句柄统计经生命周期一圈读数（T88①判据·后端半）" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  assert_eq(b.handle_stats(), HandleStats::{ live: 0, high_water: 0, })
  let win = app.create_window("MoonUI", LogicalSize(800.0, 600.0))
  win.set_content(Widget::column(b, 0.0, [Widget::label(b, "hi")]))
  // 窗口一格 + 叶子一格；Column 是纯布局节点零句柄（§14）
  assert_eq(b.handle_stats(), HandleStats::{ live: 2, high_water: 2, })
  win.close()
  assert_eq(b.handle_stats(), HandleStats::{ live: 0, high_water: 2, })
  Backend::terminate(b)
  assert_eq(b.handle_stats(), HandleStats::{ live: 0, high_water: 2, })
}
