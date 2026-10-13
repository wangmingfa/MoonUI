///|
/// 原生 Cocoa 后端的 FFI 层（设计文档 §51 的 Backend #2，macOS 半）。
///
/// 和 ../libui-common/ffi.mbt 同一套 moonui_* 名字，但只声明 FP1 需要的窗口 +
/// 事件循环那一半——控件（Button/Label/…）在 FP2 补，补之前 backend.mbt 里对应
/// 的方法 raise Unsupported。这一层不是公共 API，服务对象是同包内的 `Backend`
/// 实现：把 `moonui_*` 的形状映射成 MoonBit 的、把 C 的失败形态换成 `UiError`
/// （§33）、把裸指针收进 Core 的 `HandleTable`（§6/§7）。
///
/// 这里只讲物理像素和裸整数：逻辑像素的换算属于 `Backend` 那一层（§30 要求
/// 全框架只有 `Scale` 一处换算）。只在 native 目标下编译（见 moon.pkg 的
/// targets 门控）。

///|
/// 原生状态是进程全局的：一次 init、一个事件循环。句柄表因此也放在包级，
/// 而不是每个 backend 实例一份。
let handles : @moonui.HandleTable = @moonui.HandleTable::new()

///|
/// C 侧一次回两个整数（尺寸、位置）时打包进一个 Int64：高 32 位前一个、低 32
/// 位后一个。用算术移位拆，负数（窗口坐标可以为负）能正确还原。
fn unpack2(v : Int64) -> (Int32, Int32) {
  ((v >> 32).to_int(), (v << 32 >> 32).to_int())
}

///|
extern "c" fn c_init() -> Int32 = "moonui_init"

///|
extern "c" fn c_last_error() -> Bytes = "moonui_last_error"

///|
extern "c" fn c_terminate() -> Unit = "moonui_terminate"

///|
#borrow(title)
extern "c" fn c_window_new(
  title : Bytes,
  title_len : Int32,
  width : Int32,
  height : Int32,
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
  title_len : Int32,
) -> Unit = "moonui_window_set_title"

///|
extern "c" fn c_window_set_content_size(
  w : Int64,
  width : Int32,
  height : Int32,
) -> Unit = "moonui_window_set_content_size"

///|
extern "c" fn c_window_content_size(w : Int64) -> Int64 = "moonui_window_content_size"

///|
extern "c" fn c_window_set_position(w : Int64, x : Int32, y : Int32) -> Unit = "moonui_window_set_position"

///|
extern "c" fn c_window_position(w : Int64) -> Int64 = "moonui_window_position"

///|
extern "c" fn c_window_set_resizable(w : Int64, v : Int32) -> Unit = "moonui_window_set_resizable"

///|
extern "c" fn c_window_set_fullscreen(w : Int64, v : Int32) -> Unit = "moonui_window_set_fullscreen"

///|
extern "c" fn c_window_set_titlebar_style(w : Int64, immersive : Int32) -> Unit = "moonui_window_set_titlebar_style"

///|
extern "c" fn c_window_titlebar_style(w : Int64) -> Int32 = "moonui_window_titlebar_style"

///|
extern "c" fn c_window_set_traffic_light_position(
  w : Int64,
  x : Int32,
  y : Int32,
) -> Unit = "moonui_window_set_traffic_light_position"

///|
extern "c" fn c_window_traffic_light_position(w : Int64) -> Int64 = "moonui_window_traffic_light_position"

///|
extern "c" fn c_window_dpi(w : Int64) -> Int32 = "moonui_window_dpi"

///|
extern "c" fn c_system_dpi() -> Int32 = "moonui_system_dpi"

///|
extern "c" fn c_screen_work_area() -> Int64 = "moonui_screen_work_area"

///|
extern "c" fn c_window_screen_origin(w : Int64) -> Int64 = "moonui_window_screen_origin"

///|
extern "c" fn c_window_screen_size(w : Int64) -> Int64 = "moonui_window_screen_size"

///|
extern "c" fn c_system_theme() -> Int32 = "moonui_system_theme"

///|
extern "c" fn c_window_on_closing(
  w : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_window_on_closing"

///|
extern "c" fn c_window_on_resized(
  w : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_window_on_resized"

///|
extern "c" fn c_main_steps() -> Unit = "moonui_main_steps"

///|
extern "c" fn c_main_step(wait : Int32) -> Int32 = "moonui_main_step"

///|
extern "c" fn c_messages_pending() -> Int32 = "moonui_messages_pending"

///|
extern "c" fn c_wait_messages(ms : Int32) -> Int32 = "moonui_wait_messages"

///|
extern "c" fn c_time_ms() -> Int64 = "moonui_time_ms"

///|
extern "c" fn c_quit() -> Unit = "moonui_quit"

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
fn bool_to_c(v : Bool) -> Int32 {
  if v {
    1
  } else {
    0
  }
}

///|
/// 初始化。失败时把 C 的错误串放进 `InitializationFailed`（§33）。
pub fn native_init() -> Unit raise @moonui.UiError {
  if c_init() != 0 {
    raise @moonui.InitializationFailed(@utf8.decode_lossy(c_last_error()))
  }
}

///|
/// 收尾。C 侧会注销它持有的闭包，窗口应当已经在这之前销毁。
pub fn native_terminate() -> Unit {
  c_terminate()
}

///|
/// 当前存活的原生对象数。泄漏检查用（§48 的里程碑要求关闭后归零）。
pub fn native_live_handles() -> Int32 {
  handles.live()
}

///|
/// 建窗口。宽高这里用的是物理像素整数——逻辑到物理的换算发生在 `Backend`
/// 那一层（§30），adapter 只按平台习惯收整数。
pub fn native_window_new(
  title : String,
  width : Int32,
  height : Int32,
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
/// 注销窗口句柄并销毁它。窗口不替控件收尾（§14 把布局拿回来自家做），所以所有
/// 控件必须在之前走 `native_widget_destroy`。
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
  width : Int32,
  height : Int32,
) -> Unit raise @moonui.UiError {
  c_window_set_content_size(handles.resolve(h).0, width, height)
}

///|
pub fn native_window_content_size(
  h : @moonui.NativeHandle,
) -> (Int32, Int32) raise @moonui.UiError {
  unpack2(c_window_content_size(handles.resolve(h).0))
}

///|
/// 窗口外层左上角，屏幕物理像素坐标。
pub fn native_window_set_position(
  h : @moonui.NativeHandle,
  x : Int32,
  y : Int32,
) -> Unit raise @moonui.UiError {
  c_window_set_position(handles.resolve(h).0, x, y)
}

///|
pub fn native_window_position(
  h : @moonui.NativeHandle,
) -> (Int32, Int32) raise @moonui.UiError {
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
/// 标题栏样式（§12）。`Immersive` 在 mac 上是 fullSizeContentView + 透明标题栏 +
/// 隐藏标题文字。
pub fn native_window_set_titlebar_style(
  h : @moonui.NativeHandle,
  style : @moonui.TitlebarStyle,
) -> Unit raise @moonui.UiError {
  let immersive = match style {
    @moonui.TitlebarStyle::Immersive => 1
    @moonui.TitlebarStyle::Standard => 0
  }
  c_window_set_titlebar_style(handles.resolve(h).0, immersive)
}

///|
/// 读回标题栏样式（打包位，见 `c_window_titlebar_style`）。
pub fn native_window_titlebar_style(
  h : @moonui.NativeHandle,
) -> Int32 raise @moonui.UiError {
  c_window_titlebar_style(handles.resolve(h).0)
}

///|
/// 红绿灯位置（§12），物理像素，口径同 `native_window_set_position`。
pub fn native_window_set_traffic_light_position(
  h : @moonui.NativeHandle,
  x : Int32,
  y : Int32,
) -> Unit raise @moonui.UiError {
  c_window_set_traffic_light_position(handles.resolve(h).0, x, y)
}

///|
/// 读回红绿灯位置，物理像素，口径同 setter。
pub fn native_window_traffic_light_position(
  h : @moonui.NativeHandle,
) -> (Int32, Int32) raise @moonui.UiError {
  unpack2(c_window_traffic_light_position(handles.resolve(h).0))
}

///|
/// 窗口当下的 DPI，96 = 100%。C 侧保证不返回 0。
pub fn native_window_dpi(
  h : @moonui.NativeHandle,
) -> Int32 raise @moonui.UiError {
  c_window_dpi(handles.resolve(h).0)
}

///|
/// 进程 DPI，只给"还没有窗口"时的换算当基准（`screen_size`）。
pub fn native_system_dpi() -> Int32 {
  c_system_dpi()
}

///|
/// 主屏工作区（不含任务栏），物理像素。
pub fn native_screen_work_area() -> (Int32, Int32) {
  unpack2(c_screen_work_area())
}

///|
/// 这只窗口**当下所在那块屏**的工作区左上角，物理像素。
pub fn native_window_screen_origin(
  h : @moonui.NativeHandle,
) -> (Int32, Int32) raise @moonui.UiError {
  unpack2(c_window_screen_origin(handles.resolve(h).0))
}

///|
/// 同上，工作区的宽高，物理像素。
pub fn native_window_screen_size(
  h : @moonui.NativeHandle,
) -> (Int32, Int32) raise @moonui.UiError {
  unpack2(c_window_screen_size(handles.resolve(h).0))
}

///|
/// 系统外观是不是深色（§16）。读不到就当浅色，不报错。
pub fn native_system_theme_is_dark() -> Bool {
  c_system_theme() != 0
}

///|
/// 注册"用户点了关闭按钮"。C 侧的回调一律否决 AppKit 自己的销毁动作，
/// 销毁顺序留给 Core（先内容树后窗口）。
pub fn native_window_on_close(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_window_on_closing(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("回调槽位已用满")
  }
}

///|
pub fn native_window_on_resized(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_window_on_resized(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("回调槽位已用满")
  }
}

///|
/// 循环开始前调一次：C 侧 finishLaunching，把 App 变成真正在跑的 App。
pub fn native_main_steps() -> Unit {
  c_main_steps()
}

///|
/// 泵一条原生事件。返回 false 只表示"循环已结束"（moonui_quit 之后）。
pub fn native_main_step(wait : Bool) -> Bool {
  c_main_step(bool_to_c(wait)) != 0
}

///|
/// 队列里有没有待处理的事件（只探测不取）。
pub fn native_messages_pending() -> Bool {
  c_messages_pending() != 0
}

///|
/// 等最多 ms 毫秒看队列里有没有事件。返回 1 = 有，0 = 超时。
pub fn native_wait_messages(ms : Int32) -> Int32 {
  c_wait_messages(ms)
}

///|
/// 单调时钟，毫秒。C 侧是 int64_t，这里按 libui 那份的口径截成 Int32——
/// 事件循环的等待预算是毫秒级的 Int32，用不到 64 位。
pub fn native_time_ms() -> Int32 {
  c_time_ms().to_int()
}

///|
/// 把主循环标成"跑完了"。
pub fn native_quit() -> Unit {
  c_quit()
}
