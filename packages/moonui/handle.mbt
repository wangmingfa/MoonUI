///|
/// 原生句柄与句柄表（设计文档 §6、§7、§47 风险 2）。
///
/// Core 与公共 API 只看到 `NativeHandle`（id + generation），永远看不到
/// `uiButton*` / `HWND` / `SDL_Window*`。真实指针只在 Backend 内部通过
/// `HandleTable` 换取，这样文档 §47 里的"悬垂指针 / double free"从运行期
/// 未定义行为变成框架内可判定的错误——也就能在接上 libui-ng 之前先用
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
  id : Int
  generation : Int
} derive(Debug, Eq)

///|
struct HandleSlot {
  generation : Int
  ptr : NativePtr
  mut alive : Bool
}

///|
/// id -> 原生指针的登记表。所有 Backend 共用同一套生命周期语义。
pub struct HandleTable {
  slots : Array[HandleSlot]
  free_ids : Array[Int]
  mut live_count : Int
}

///|
pub fn HandleTable::new() -> HandleTable {
  HandleTable::{ slots: [], free_ids: [], live_count: 0, }
}

///|
/// 越界访问返回 `None`，而不是像 `slots[i]` 那样直接失败——句柄 id 来自
/// 用户侧，可能早已失效，必须走可恢复的错误路径。
fn slot_at(table : HandleTable, id : Int) -> HandleSlot? {
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
pub fn HandleTable::live(self : HandleTable) -> Int {
  self.live_count
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
