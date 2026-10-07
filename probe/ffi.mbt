///|
/// native FFI 最小闭环验证（设计文档 §48 第 02/03 步）。
///
/// 这一层不是公共 API。它的唯一职责是在接 libui-ng 之前，把 §47 的三条 FFI
/// 风险在真实工具链（MSVC x64）上跑成可断言的事实：
/// 1. 指针必须用 `Int64` 承载——MoonBit 的 `Int` 是 32 位，装不下 x64 地址；
/// 2. C 管理生命的对象，double free 由 Core 的 `HandleTable` 挡住，而不是靠 C；
/// 3. C 长期持有 MoonBit 闭包时必须 incref，否则回调回来的是尸体。

///|
/// GC 管理的外部对象：容器由 MoonBit 释放，C 的 finalizer 只清 payload。
pub type ProbeObj

///|
extern "c" fn obj_new(value : Int) -> ProbeObj = "moonbit_probe_obj_new"

///|
#borrow(o)
extern "c" fn obj_value(o : ProbeObj) -> Int = "moonbit_probe_obj_value"

///|
#borrow(o)
extern "c" fn obj_release(o : ProbeObj) -> Unit = "moonbit_probe_obj_release"

///|
extern "c" fn obj_live() -> Int = "moonbit_probe_obj_live"

///|
pub fn new_object(value : Int) -> ProbeObj {
  obj_new(value)
}

///|
pub fn ProbeObj::value(self : ProbeObj) -> Int {
  obj_value(self)
}

///|
/// 显式释放。与 finalizer 二者都幂等，计数不会漂移。
pub fn ProbeObj::release(self : ProbeObj) -> Unit {
  obj_release(self)
}

///|
/// C 侧存活对象数，泄漏检查用。
pub fn live_objects() -> Int {
  obj_live()
}

///|
extern "c" fn raw_new(value : Int) -> Int64 = "moonbit_probe_raw_new"

///|
extern "c" fn raw_get(addr : Int64) -> Int = "moonbit_probe_raw_get"

///|
extern "c" fn raw_free(addr : Int64) -> Unit = "moonbit_probe_raw_free"

///|
extern "c" fn raw_live() -> Int = "moonbit_probe_raw_live"

///|
/// 分配失败（空地址）在这里就转成 `UiError`（§33），Core 拿不到 0。
pub fn alloc_raw(value : Int) -> Int64 raise @moonui.UiError {
  let addr = raw_new(value)
  if addr == 0L {
    raise @moonui.OperationFailed("moonbit_probe_raw_new 分配失败")
  }
  addr
}

///|
pub fn read_raw(addr : Int64) -> Int raise @moonui.UiError {
  let v = raw_get(addr)
  if v < 0 {
    raise @moonui.InvalidHandle
  }
  v
}

///|
/// 只应由 `HandleTable::unregister` 成功后调用一次。
pub fn free_raw(addr : Int64) -> Unit {
  raw_free(addr)
}

///|
pub fn raw_live_count() -> Int {
  raw_live()
}

///|
#borrow(s)
extern "c" fn utf8_len(s : Bytes) -> Int = "moonbit_probe_utf8_len"

///|
#borrow(s)
extern "c" fn append_bang(s : Bytes) -> Bytes = "moonbit_probe_append_bang"

///|
/// MoonBit String 内部是 UTF-16，跨 FFI 一律走 UTF-8（§29）。
pub fn utf8_byte_length(s : String) -> Int {
  utf8_len(@utf8.encode(s))
}

///|
pub fn shout(s : String) -> String {
  @utf8.decode_lossy(append_bang(@utf8.encode(s)))
}

///|
/// 立即回调：C 在循环里反复调用 MoonBit 闭包。
/// `FuncRef + closure` 是 MoonBit 侧的 trampoline，闭包生命周期不用自己管。
extern "c" fn each_ffi(
  n : Int,
  call_closure : FuncRef[((Int) -> Unit, Int) -> Unit],
  closure : (Int) -> Unit,
) = "moonbit_probe_each"

///|
pub fn each(n : Int, callback : (Int) -> Unit) -> Unit {
  each_ffi(n, fn(f, x) { f(x) }, callback)
}

///|
/// 延迟回调：C 把闭包存进全局，稍后再触发——等价于真实控件的事件注册。
extern "c" fn store_ffi(
  call_closure : FuncRef[((Int) -> Unit, Int) -> Unit],
  closure : (Int) -> Unit,
) = "moonbit_probe_store_callback"

///|
extern "c" fn fire_ffi(value : Int) -> Int = "moonbit_probe_fire_callback"

///|
extern "c" fn clear_ffi() -> Unit = "moonbit_probe_clear_callback"

///|
pub fn store_callback(callback : (Int) -> Unit) -> Unit {
  store_ffi(fn(f, x) { f(x) }, callback)
}

///|
pub fn fire_callback(value : Int) -> Int {
  fire_ffi(value)
}

///|
pub fn clear_callback() -> Unit {
  clear_ffi()
}
