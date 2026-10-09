///|
/// libui-ng 后端的 FFI 层（设计文档 §20；开发顺序 §48 第 03/04/06 步）。
///
/// 这一层不是公共 API，服务对象是同包内的 `Backend` 实现。它负责三件事：
/// 把 `moonui_*` 的形状映射成 MoonBit 的、把 C 的失败形态换成 `UiError`（§33）、
/// 以及把裸指针收进 Core 的 `HandleTable`——MoonBit 侧从头到尾拿不到指针（§6/§7）。
///
/// 这里只讲物理像素和裸整数：逻辑像素的换算属于 `Backend` 那一层（§30 要求
/// 全框架只有 `Scale` 一处换算），`LibuiBackend` 因此是唯一做除法的地方。
///
/// 只在 native 目标下编译（见 moon.pkg 的 targets 门控）：§47 要求 Core 不
/// 依赖任何 GUI 库，反过来说 GUI 库也不能出现在 wasm 路径上。

///|
/// libui 的原生状态是进程全局的：一次 init、一个事件循环、一套控件类注册。
/// 句柄表因此也放在包级，而不是每个 backend 实例一份。
let handles : @moonui.HandleTable = @moonui.HandleTable::new()

///|
/// C 侧一次回两个整数（尺寸、位置）时打包进一个 Int64：高 32 位前一个、低 32
/// 位后一个。用算术移位拆，负数（窗口坐标可以为负）能正确还原。
fn unpack2(v : Int64) -> (Int, Int) {
  ((v >> 32).to_int(), (v << 32 >> 32).to_int())
}

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
extern "c" fn c_window_destroy(w : Int64) -> Unit = "moonui_window_destroy"

///|
#borrow(title)
extern "c" fn c_window_set_title(
  w : Int64,
  title : Bytes,
  title_len : Int,
) -> Unit = "moonui_window_set_title"

///|
extern "c" fn c_window_set_content_size(
  w : Int64,
  width : Int,
  height : Int,
) -> Unit = "moonui_window_set_content_size"

///|
extern "c" fn c_window_content_size(w : Int64) -> Int64 = "moonui_window_content_size"

///|
extern "c" fn c_window_set_position(w : Int64, x : Int, y : Int) -> Unit = "moonui_window_set_position"

///|
extern "c" fn c_window_position(w : Int64) -> Int64 = "moonui_window_position"

///|
extern "c" fn c_window_set_resizable(w : Int64, v : Int) -> Unit = "moonui_window_set_resizable"

///|
extern "c" fn c_window_set_fullscreen(w : Int64, v : Int) -> Unit = "moonui_window_set_fullscreen"

///|
extern "c" fn c_window_dpi(w : Int64) -> Int = "moonui_window_dpi"

///|
extern "c" fn c_system_dpi() -> Int = "moonui_system_dpi"

///|
extern "c" fn c_screen_work_area() -> Int64 = "moonui_screen_work_area"

///|
extern "c" fn c_window_on_closing(
  w : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int = "moonui_window_on_closing"

///|
extern "c" fn c_window_on_resized(
  w : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int = "moonui_window_on_resized"

///|
#borrow(text)
extern "c" fn c_widget_new(kind : Int, text : Bytes, text_len : Int) -> Int64 = "moonui_widget_new"

///|
extern "c" fn c_widget_destroy(c : Int64) -> Unit = "moonui_widget_destroy"

///|
#borrow(text)
extern "c" fn c_widget_set_text(
  c : Int64,
  text : Bytes,
  text_len : Int,
) -> Unit = "moonui_widget_set_text"

///|
extern "c" fn c_widget_text(c : Int64) -> Bytes = "moonui_widget_text"

///|
extern "c" fn c_widget_set_checked(c : Int64, v : Int) -> Unit = "moonui_widget_set_checked"

///|
extern "c" fn c_widget_checked(c : Int64) -> Int = "moonui_widget_checked"

///|
extern "c" fn c_widget_set_visible(c : Int64, v : Int) -> Unit = "moonui_widget_set_visible"

///|
extern "c" fn c_widget_visible(c : Int64) -> Int = "moonui_widget_visible"

///|
extern "c" fn c_widget_set_enabled(c : Int64, v : Int) -> Unit = "moonui_widget_set_enabled"

///|
extern "c" fn c_widget_enabled(c : Int64) -> Int = "moonui_widget_enabled"

///|
extern "c" fn c_widget_minimum_size(c : Int64) -> Int64 = "moonui_widget_minimum_size"

///|
extern "c" fn c_widget_dpi(c : Int64) -> Int = "moonui_widget_dpi"

///|
extern "c" fn c_widget_origin(c : Int64) -> Int64 = "moonui_widget_origin"

///|
extern "c" fn c_widget_size(c : Int64) -> Int64 = "moonui_widget_size"

///|
extern "c" fn c_widget_on_clicked(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int = "moonui_widget_on_clicked"

///|
extern "c" fn c_control_attach(w : Int64, child : Int64) -> Unit = "moonui_control_attach"

///|
extern "c" fn c_control_set_bounds(
  child : Int64,
  x : Int,
  y : Int,
  width : Int,
  height : Int,
) -> Unit = "moonui_control_set_bounds"

///|
extern "c" fn c_control_detach(child : Int64) -> Unit = "moonui_control_detach"

///|
extern "c" fn c_control_raise(child : Int64) -> Unit = "moonui_control_raise"

///|
extern "c" fn c_control_z_index(child : Int64) -> Int = "moonui_control_z_index"

///|
extern "c" fn c_main_steps() -> Unit = "moonui_main_steps"

///|
extern "c" fn c_main_step(wait : Int) -> Int = "moonui_main_step"

///|
extern "c" fn c_messages_pending() -> Int = "moonui_messages_pending"

///|
extern "c" fn c_wait_messages(ms : Int) -> Int = "moonui_wait_messages"

///|
extern "c" fn c_time_ms() -> Int64 = "moonui_time_ms"

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
#borrow(title)
extern "c" fn c_request_window_close(title : Bytes, title_len : Int) -> Int = "moonui_request_window_close"

///|
/// C 侧所有字符串都是 (UTF-8 字节, 长度) 一对：MoonBit 的 `String` 内部是
/// UTF-16，`Bytes` 又不保证 NUL 结尾，把长度显式传下去是唯一不需要祈祷的形式（§29）。
fn utf8(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
/// 裸指针进句柄表；0（分配失败或不支持的 kind）在这里就转成错误，Core 拿不到空指针。
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
fn bool_to_c(v : Bool) -> Int {
  if v {
    1
  } else {
    0
  }
}

///|
/// 初始化 libui。失败时把 libui 的错误串放进 `InitializationFailed`（§33）。
pub fn native_init() -> Unit raise @moonui.UiError {
  if c_init() != 0 {
    raise @moonui.InitializationFailed(@utf8.decode_lossy(c_last_error()))
  }
}

///|
/// 收尾。C 侧会注销它持有的闭包，窗口和控件应当已经在这之前销毁。
pub fn native_terminate() -> Unit {
  c_terminate()
}

///|
/// 当前存活的原生对象数。泄漏检查用（§48 的里程碑要求关闭后归零）。
pub fn native_live_handles() -> Int {
  handles.live()
}

///|
/// 建窗口。宽高这里用的是物理像素整数——逻辑到物理的换算发生在 `Backend`
/// 那一层（§30），adapter 只按平台习惯收整数。
pub fn native_window_new(
  title : String,
  width : Int,
  height : Int,
) -> @moonui.NativeHandle raise @moonui.UiError {
  let t = utf8(title)
  register(c_window_new(t, t.length(), width, height), "moonui_window_new")
}

///|
pub fn native_window_show(
  h : @moonui.NativeHandle,
) -> Unit raise @moonui.UiError {
  c_window_show(handles.resolve(h).0)
}

///|
pub fn native_window_hide(
  h : @moonui.NativeHandle,
) -> Unit raise @moonui.UiError {
  c_window_hide(handles.resolve(h).0)
}

///|
/// 注销窗口句柄并销毁它。窗口不替控件收尾（§14 把布局拿回来自家做，
/// 所有权的交接也就不能指望 libui 的容器），所以所有控件必须在之前
/// 走 `native_widget_destroy`：控件的 HWND 会跟着 DestroyWindow 一起没，但 libui
/// 那份控件对象不会，退出时的分配审计会把这件事变成 DebugBreak。
pub fn native_window_destroy(
  h : @moonui.NativeHandle,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  handles.unregister(h)
  c_window_destroy(ptr.0)
}

///|
pub fn native_window_set_title(
  h : @moonui.NativeHandle,
  title : String,
) -> Unit raise @moonui.UiError {
  let t = utf8(title)
  c_window_set_title(handles.resolve(h).0, t, t.length())
}

///|
/// 客户区尺寸，物理像素。
pub fn native_window_set_content_size(
  h : @moonui.NativeHandle,
  width : Int,
  height : Int,
) -> Unit raise @moonui.UiError {
  c_window_set_content_size(handles.resolve(h).0, width, height)
}

///|
pub fn native_window_content_size(
  h : @moonui.NativeHandle,
) -> (Int, Int) raise @moonui.UiError {
  unpack2(c_window_content_size(handles.resolve(h).0))
}

///|
/// 窗口外层左上角，屏幕物理像素坐标。
pub fn native_window_set_position(
  h : @moonui.NativeHandle,
  x : Int,
  y : Int,
) -> Unit raise @moonui.UiError {
  c_window_set_position(handles.resolve(h).0, x, y)
}

///|
pub fn native_window_position(
  h : @moonui.NativeHandle,
) -> (Int, Int) raise @moonui.UiError {
  unpack2(c_window_position(handles.resolve(h).0))
}

///|
pub fn native_window_set_resizable(
  h : @moonui.NativeHandle,
  v : Bool,
) -> Unit raise @moonui.UiError {
  c_window_set_resizable(handles.resolve(h).0, bool_to_c(v))
}

///|
pub fn native_window_set_fullscreen(
  h : @moonui.NativeHandle,
  v : Bool,
) -> Unit raise @moonui.UiError {
  c_window_set_fullscreen(handles.resolve(h).0, bool_to_c(v))
}

///|
/// 窗口当下的 DPI，96 = 100%。C 侧保证不返回 0。
pub fn native_window_dpi(h : @moonui.NativeHandle) -> Int raise @moonui.UiError {
  c_window_dpi(handles.resolve(h).0)
}

///|
/// 进程 DPI，只给"还没有窗口"时的换算当基准（`screen_size`）。
pub fn native_system_dpi() -> Int {
  c_system_dpi()
}

///|
/// 主屏工作区（不含任务栏），物理像素。
pub fn native_screen_work_area() -> (Int, Int) {
  unpack2(c_screen_work_area())
}

///|
/// 注册"用户点了关闭按钮"。C 侧的回调一律否决 libui 自己的销毁动作，
/// 销毁顺序留给 Core（先内容树后窗口）。
pub fn native_window_on_close(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_window_on_closing(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("libui 回调槽位已用满")
  }
}

///|
pub fn native_window_on_resized(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_window_on_resized(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("libui 回调槽位已用满")
  }
}

///|
/// adapter 的 kind 编码：0=Label 1=Button 2=TextInput 3=Checkbox。
/// 纯布局节点在 §14 里不占原生对象，走到这里就是调用方的错，所以显式报错。
fn kind_code(kind : @moonui.WidgetKind) -> Int raise @moonui.UiError {
  match kind {
    @moonui.Label => 0
    @moonui.Button => 1
    @moonui.TextInput => 2
    @moonui.Checkbox => 3
    _ =>
      raise @moonui.Unsupported(
        "纯布局节点（Row/Column/…）不占原生对象",
      )
  }
}

///|
pub fn native_widget_new(
  kind : @moonui.WidgetKind,
  text : String,
) -> @moonui.NativeHandle raise @moonui.UiError {
  let code = kind_code(kind)
  let t = utf8(text)
  register(c_widget_new(code, t, t.length()), "moonui_widget_new")
}

///|
/// 显式销毁控件并松开 C 侧替它看守的闭包。必须在所属窗口销毁之前调用。
pub fn native_widget_destroy(
  h : @moonui.NativeHandle,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  handles.unregister(h)
  c_widget_destroy(ptr.0)
}

///|
pub fn native_widget_set_text(
  h : @moonui.NativeHandle,
  text : String,
) -> Unit raise @moonui.UiError {
  let t = utf8(text)
  c_widget_set_text(handles.resolve(h).0, t, t.length())
}

///|
pub fn native_widget_text(
  h : @moonui.NativeHandle,
) -> String raise @moonui.UiError {
  @utf8.decode_lossy(c_widget_text(handles.resolve(h).0))
}

///|
pub fn native_widget_set_checked(
  h : @moonui.NativeHandle,
  v : Bool,
) -> Unit raise @moonui.UiError {
  c_widget_set_checked(handles.resolve(h).0, bool_to_c(v))
}

///|
pub fn native_widget_checked(
  h : @moonui.NativeHandle,
) -> Bool raise @moonui.UiError {
  c_widget_checked(handles.resolve(h).0) != 0
}

///|
pub fn native_widget_set_visible(
  h : @moonui.NativeHandle,
  v : Bool,
) -> Unit raise @moonui.UiError {
  c_widget_set_visible(handles.resolve(h).0, bool_to_c(v))
}

///|
/// 控件是否真的在屏幕上显示。父窗口还没 show 时这里是 `false`——
/// `IsWindowVisible` 查的正是这条祖先链，和用户的观感一致。
pub fn native_widget_visible(
  h : @moonui.NativeHandle,
) -> Bool raise @moonui.UiError {
  c_widget_visible(handles.resolve(h).0) != 0
}

///|
pub fn native_widget_set_enabled(
  h : @moonui.NativeHandle,
  v : Bool,
) -> Unit raise @moonui.UiError {
  c_widget_set_enabled(handles.resolve(h).0, bool_to_c(v))
}

///|
pub fn native_widget_enabled(
  h : @moonui.NativeHandle,
) -> Bool raise @moonui.UiError {
  c_widget_enabled(handles.resolve(h).0) != 0
}

///|
/// libui 自己量出来的固有尺寸，物理像素。
pub fn native_widget_minimum_size(
  h : @moonui.NativeHandle,
) -> (Int, Int) raise @moonui.UiError {
  unpack2(c_widget_minimum_size(handles.resolve(h).0))
}

///|
pub fn native_widget_dpi(h : @moonui.NativeHandle) -> Int raise @moonui.UiError {
  c_widget_dpi(handles.resolve(h).0)
}

///|
/// 相对父窗口客户区的左上角，物理像素。
pub fn native_widget_origin(
  h : @moonui.NativeHandle,
) -> (Int, Int) raise @moonui.UiError {
  unpack2(c_widget_origin(handles.resolve(h).0))
}

///|
pub fn native_widget_size(
  h : @moonui.NativeHandle,
) -> (Int, Int) raise @moonui.UiError {
  unpack2(c_widget_size(handles.resolve(h).0))
}

///|
pub fn native_widget_on_click(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_widget_on_clicked(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("libui 点击回调槽位已用满")
  }
}

///|
/// 把控件的 HWND 挂进窗口，插到 z-order 末尾（= Tab 顺序）。矩形另走
/// `native_control_set_bounds`：Core 的调用顺序就是先 attach 再布局（§14）。
pub fn native_control_attach(
  window : @moonui.NativeHandle,
  child : @moonui.NativeHandle,
) -> Unit raise @moonui.UiError {
  c_control_attach(handles.resolve(window).0, handles.resolve(child).0)
}

///|
/// 按 MoonUI 算好的矩形摆放，窗口客户区物理像素坐标。
pub fn native_control_set_bounds(
  child : @moonui.NativeHandle,
  x : Int,
  y : Int,
  width : Int,
  height : Int,
) -> Unit raise @moonui.UiError {
  c_control_set_bounds(handles.resolve(child).0, x, y, width, height)
}

///|
pub fn native_control_detach(
  child : @moonui.NativeHandle,
) -> Unit raise @moonui.UiError {
  c_control_detach(handles.resolve(child).0)
}

///|
/// 把控件提到父窗口的最上层（§14 的 Stack）。
pub fn native_control_raise(
  child : @moonui.NativeHandle,
) -> Unit raise @moonui.UiError {
  c_control_raise(handles.resolve(child).0)
}

///|
/// 控件在父窗口子窗口列表里的位置，0 = 最上层；没有父窗口时 -1。
/// 测试断言层叠顺序用（产品路径不读它）。
pub fn native_control_z_index(
  child : @moonui.NativeHandle,
) -> Int raise @moonui.UiError {
  c_control_z_index(handles.resolve(child).0)
}

///|
/// 事件循环：`native_main_steps` 做一次初始化，之后每一步自己控制是否等待（§10）。
pub fn native_main_steps() -> Unit {
  c_main_steps()
}

///|
/// 走一步消息循环。返回 `false` 只可能是收到了 WM_QUIT。
pub fn native_main_step(wait : Bool) -> Bool {
  c_main_step(if wait { 1 } else { 0 }) != 0
}

///|
/// 原生队列里还有消息可取吗。`native_main_step` 的返回值分不清"处理了一条"
/// 和"队列本来就空"，`native_wait_messages` 又只报告"自上次唤醒以来有无新消息"，
/// 所以推进循环之前要用这一问把积压的消息走完（backend.mbt 的 `pump`）。
pub fn native_messages_pending() -> Bool {
  c_messages_pending() != 0
}

///|
/// 最多等 `ms` 毫秒，看原生队列里有没有**新**消息来。`false` = 这段时间里没有。
/// 队列里有积压时这里照样可能报 `false`，所以它只能当唤醒用。
pub fn native_wait_messages(ms : Int) -> Bool {
  c_wait_messages(ms) != 0
}

///|
/// 单调时钟，毫秒。给 `poll_event` 的等待预算当墙钟截止点。
pub fn native_time_ms() -> Int {
  c_time_ms().to_int()
}

///|
pub fn native_quit() -> Unit {
  c_quit()
}

///|
/// 在指定标题窗口的客户区坐标 (x, y) 处命中控件并点击它，等价于用户按了一下鼠标。
/// 只给测试用：真实点击由 libui 的 WM_COMMAND 路由送进来，不需要这里掺和。
/// 返回 0 表示消息已发出，负值表示没命中按钮（编码失败 / 找不到窗口 /
/// 命中的不是按钮）。
pub fn native_click_button_in_window(title : String, x : Int, y : Int) -> Int {
  let t = utf8(title)
  c_click_in_window(t, t.length(), x, y)
}

///|
/// 等价于"用户点了这个窗口的关闭按钮"：投递一条 WM_CLOSE，回调要在之后的
/// 事件循环里才会跑到。只给测试用。0 = 已投递，负值 = 编码失败 / 找不到窗口。
pub fn native_request_window_close(title : String) -> Int {
  let t = utf8(title)
  c_request_window_close(t, t.length())
}
