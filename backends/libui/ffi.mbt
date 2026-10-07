///|
/// libui-ng 后端的 FFI 层（设计文档 §20；开发顺序 §48 第 03/04/06 步）。
///
/// 这一层不是公共 API，服务对象是同包内的 `Backend` 实现。它负责三件事：
/// 把 `moonui_*` 的形状映射成 MoonBit 的、把 C 的失败形态换成 `UiError`（§33）、
/// 以及把裸指针收进 Core 的 `HandleTable`——MoonBit 侧从头到尾拿不到指针（§6/§7）。
///
/// 只在 native 目标下编译（见 moon.pkg 的 targets 门控）：§47 要求 Core 不
/// 依赖任何 GUI 库，反过来说 GUI 库也不能出现在 wasm 路径上。

///|
/// libui 的原生状态是进程全局的：一次 init、一个事件循环、一套控件类注册。
/// 句柄表因此也放在包级，而不是每个 backend 实例一份。
let handles : @moonui.HandleTable = @moonui.HandleTable::new()

///|
extern "c" fn c_init() -> Int = "moonui_init"

///|
extern "c" fn c_last_error() -> Bytes = "moonui_last_error"

///|
extern "c" fn c_terminate() -> Unit = "moonui_terminate"

///|
#borrow(title)
extern "c" fn c_window_new(
  title : Bytes,
  title_len : Int,
  width : Int,
  height : Int,
) -> Int64 = "moonui_window_new"

///|
extern "c" fn c_window_show(w : Int64) -> Unit = "moonui_window_show"

///|
extern "c" fn c_window_hide(w : Int64) -> Unit = "moonui_window_hide"

///|
extern "c" fn c_control_attach(
  w : Int64,
  child : Int64,
  x : Int,
  y : Int,
  width : Int,
  height : Int,
) -> Unit = "moonui_control_attach"

///|
extern "c" fn c_window_destroy(w : Int64) -> Unit = "moonui_window_destroy"

///|
#borrow(text)
extern "c" fn c_button_new(text : Bytes, text_len : Int) -> Int64 = "moonui_button_new"

///|
#borrow(text)
extern "c" fn c_button_set_text(
  b : Int64,
  text : Bytes,
  text_len : Int,
) -> Unit = "moonui_button_set_text"

///|
extern "c" fn c_button_text(b : Int64) -> Bytes = "moonui_button_text"

///|
extern "c" fn c_button_on_clicked(
  b : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int = "moonui_button_on_clicked"

///|
extern "c" fn c_button_destroy(b : Int64) -> Unit = "moonui_button_destroy"

///|
extern "c" fn c_main_steps() -> Unit = "moonui_main_steps"

///|
extern "c" fn c_main_step(wait : Int) -> Int = "moonui_main_step"

///|
extern "c" fn c_quit() -> Unit = "moonui_quit"

///|
#borrow(title)
extern "c" fn c_click_in_window(
  title : Bytes,
  title_len : Int,
  x : Int,
  y : Int,
) -> Int = "moonui_click_button_in_window"

///|
/// C 侧所有字符串都是 (UTF-8 字节, 长度) 一对：MoonBit 的 `String` 内部是
/// UTF-16，`Bytes` 又不保证 NUL 结尾，把长度显式传下去是唯一不需要祈祷的形式（§29）。
fn utf8(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
/// 裸指针进句柄表；0（分配失败）在这里就转成错误，Core 拿不到空指针。
fn register(
  addr : Int64,
  context : String,
) -> @moonui.NativeHandle raise @moonui.UiError {
  if addr == 0L {
    raise @moonui.OperationFailed("\{context} 返回空指针")
  }
  handles.register(@moonui.NativePtr(addr))
}

///|
/// 初始化 libui。失败时把 libui 的错误串放进 `InitializationFailed`（§33）。
pub fn initialize() -> Unit raise @moonui.UiError {
  if c_init() != 0 {
    raise @moonui.InitializationFailed(@utf8.decode_lossy(c_last_error()))
  }
}

///|
/// 收尾。C 侧会注销它持有的闭包，窗口应当已经在这之前销毁。
pub fn terminate() -> Unit {
  c_terminate()
}

///|
/// 当前存活的原生对象数。泄漏检查用（§48 的里程碑要求关闭后归零）。
pub fn live_handles() -> Int {
  handles.live()
}

///|
/// 建窗口。尺寸这里用的是物理像素整数——逻辑像素到物理的换算发生在 `Backend`
/// 那一层（§30），adapter 只按平台习惯收整数。
pub fn create_window(
  title : String,
  width : Int,
  height : Int,
) -> @moonui.NativeHandle raise @moonui.UiError {
  let t = utf8(title)
  register(c_window_new(t, t.length(), width, height), "moonui_window_new")
}

///|
pub fn show_window(h : @moonui.NativeHandle) -> Unit raise @moonui.UiError {
  c_window_show(handles.resolve(h).0)
}

///|
pub fn hide_window(h : @moonui.NativeHandle) -> Unit raise @moonui.UiError {
  c_window_hide(handles.resolve(h).0)
}

///|
/// 把控件摆进窗口的客户区，矩形由 MoonUI 的布局引擎算好（§14）。
/// 这里用的是物理像素整数，逻辑到物理的换算在 `Backend` 那一层（§30）。
pub fn attach_control(
  window : @moonui.NativeHandle,
  child : @moonui.NativeHandle,
  x : Int,
  y : Int,
  width : Int,
  height : Int,
) -> Unit raise @moonui.UiError {
  c_control_attach(
    handles.resolve(window).0,
    handles.resolve(child).0,
    x,
    y,
    width,
    height,
  )
}

///|
/// 注销窗口句柄并销毁它。窗口不替控件收尾（§14 把布局拿回来自家做，
/// 所有权的交接也就不能指望 libui 的容器），所以所有控件必须在之前
/// 走 `destroy_button`：控件的 HWND 会跟着 DestroyWindow 一起没，但 libui
/// 那份控件对象不会，退出时的分配审计会把这件事变成 DebugBreak。
pub fn destroy_window(
  window : @moonui.NativeHandle,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(window)
  handles.unregister(window)
  c_window_destroy(ptr.0)
}

///|
pub fn create_button(
  text : String,
) -> @moonui.NativeHandle raise @moonui.UiError {
  let t = utf8(text)
  register(c_button_new(t, t.length()), "moonui_button_new")
}

///|
pub fn set_button_text(
  h : @moonui.NativeHandle,
  text : String,
) -> Unit raise @moonui.UiError {
  let t = utf8(text)
  c_button_set_text(handles.resolve(h).0, t, t.length())
}

///|
pub fn button_text(h : @moonui.NativeHandle) -> String raise @moonui.UiError {
  @utf8.decode_lossy(c_button_text(handles.resolve(h).0))
}

///|
/// 注册点击回调。`FuncRef + 闭包` 是 MoonBit 侧的 trampoline，闭包由 C 侧
/// incref 看守（§47 风险 1：C 长期持有的闭包不 incref 就是悬垂）。
pub fn button_on_click(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_button_on_clicked(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("libui 点击回调槽位已用满")
  }
}

///|
/// 显式销毁控件并松开 C 侧替它看守的闭包。必须在所属窗口销毁之前调用。
pub fn destroy_button(h : @moonui.NativeHandle) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  handles.unregister(h)
  c_button_destroy(ptr.0)
}

///|
/// 事件循环：`main_steps` 做一次初始化，之后每一步自己控制是否等待（§10）。
pub fn main_steps() -> Unit {
  c_main_steps()
}

///|
/// 走一步消息循环。返回 `false` 表示没有窗口可继续循环了。
pub fn main_step(wait : Bool) -> Bool {
  c_main_step(if wait { 1 } else { 0 }) != 0
}

///|
pub fn quit() -> Unit {
  c_quit()
}

///|
/// 在指定标题窗口的客户区坐标 (x, y) 处命中控件并点击它，等价于用户按了一下鼠标。
/// 只给测试用：真实点击由 libui 的 WM_COMMAND 路由送进来，不需要这里掺和。
/// 返回 0 表示消息已发出，负值表示没命中按钮（编码失败 / 找不到窗口 /
/// 命中的不是按钮）。
pub fn click_button_in_window(title : String, x : Int, y : Int) -> Int {
  let t = utf8(title)
  c_click_in_window(t, t.length(), x, y)
}
