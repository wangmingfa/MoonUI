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

// ---- 控件（FP2）----
//
// 和 ../libui-common/ffi.mbt 同一套 moonui_* 名字，但底下直写 AppKit。kind 编码
// 与 adapter.h 一致：0=Label 1=Button 2=TextInput 3=Checkbox 4=PasswordInput
// 5=Separator 13=VSeparator 14=MenuRow；Slider/Spinbox/Progress/ComboBox/
// RadioButtons/MultilineEntry/DatePicker 各有专属的 moonui_*_new 入口。

///|
#borrow(text)
extern "c" fn c_widget_new(
  kind : Int32,
  text : Bytes,
  text_len : Int32,
) -> Int64 = "moonui_widget_new"

///|
extern "c" fn c_widget_destroy(c : Int64) -> Unit = "moonui_widget_destroy"

///|
#borrow(text)
extern "c" fn c_widget_set_text(
  c : Int64,
  text : Bytes,
  text_len : Int32,
) -> Unit = "moonui_widget_set_text"

///|
extern "c" fn c_widget_text(c : Int64) -> Bytes = "moonui_widget_text"

///|
extern "c" fn c_widget_set_checked(c : Int64, v : Int32) -> Unit = "moonui_widget_set_checked"

///|
extern "c" fn c_widget_checked(c : Int64) -> Int32 = "moonui_widget_checked"

///|
extern "c" fn c_widget_set_visible(c : Int64, v : Int32) -> Unit = "moonui_widget_set_visible"

///|
extern "c" fn c_widget_visible(c : Int64) -> Int32 = "moonui_widget_visible"

///|
extern "c" fn c_widget_set_enabled(c : Int64, v : Int32) -> Unit = "moonui_widget_set_enabled"

///|
extern "c" fn c_widget_enabled(c : Int64) -> Int32 = "moonui_widget_enabled"

///|
extern "c" fn c_widget_minimum_size(c : Int64) -> Int64 = "moonui_widget_minimum_size"

///|
extern "c" fn c_widget_dpi(c : Int64) -> Int32 = "moonui_widget_dpi"

///|
extern "c" fn c_widget_origin(c : Int64) -> Int64 = "moonui_widget_origin"

///|
extern "c" fn c_widget_size(c : Int64) -> Int64 = "moonui_widget_size"

///|
extern "c" fn c_widget_on_clicked(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_widget_on_clicked"

///|
extern "c" fn c_widget_on_text_changed(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_widget_on_text_changed"

///|
extern "c" fn c_widget_on_toggled(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_widget_on_toggled"

///|
extern "c" fn c_slider_new(min : Int32, max : Int32) -> Int64 = "moonui_slider_new"

///|
extern "c" fn c_slider_set_range(c : Int64, min : Int32, max : Int32) -> Unit = "moonui_slider_set_range"

///|
extern "c" fn c_slider_on_changed(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_slider_on_changed"

///|
extern "c" fn c_spinbox_new(min : Int32, max : Int32) -> Int64 = "moonui_spinbox_new"

///|
extern "c" fn c_spinbox_on_changed(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_spinbox_on_changed"

///|
extern "c" fn c_progress_new() -> Int64 = "moonui_progress_new"

///|
extern "c" fn c_combobox_new() -> Int64 = "moonui_combobox_new"

///|
extern "c" fn c_combobox_on_selected(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_combobox_on_selected"

///|
extern "c" fn c_radio_new() -> Int64 = "moonui_radio_new"

///|
extern "c" fn c_radio_on_selected(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_radio_on_selected"

///|
extern "c" fn c_multiline_new() -> Int64 = "moonui_multiline_new"

///|
extern "c" fn c_multiline_on_changed(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_multiline_on_changed"

///|
extern "c" fn c_datepicker_new() -> Int64 = "moonui_datepicker_new"

///|
#borrow(text)
extern "c" fn c_datepicker_set_text(
  c : Int64,
  text : Bytes,
  text_len : Int32,
) -> Int32 = "moonui_datepicker_set_text"

///|
extern "c" fn c_datepicker_text(c : Int64) -> Bytes = "moonui_datepicker_text"

///|
extern "c" fn c_datepicker_on_changed(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_datepicker_on_changed"

///|
extern "c" fn c_widget_set_value(c : Int64, v : Int32) -> Unit = "moonui_widget_set_value"

///|
extern "c" fn c_widget_value(c : Int64) -> Int32 = "moonui_widget_value"

///|
#borrow(text)
extern "c" fn c_widget_append_option(
  c : Int64,
  text : Bytes,
  text_len : Int32,
) -> Unit = "moonui_widget_append_option"

///|
extern "c" fn c_widget_set_selected(c : Int64, index : Int32) -> Unit = "moonui_widget_set_selected"

///|
extern "c" fn c_widget_selected(c : Int64) -> Int32 = "moonui_widget_selected"

///|
extern "c" fn c_control_attach(w : Int64, child : Int64) -> Unit = "moonui_control_attach"

///|
extern "c" fn c_control_set_bounds(
  child : Int64,
  x : Int32,
  y : Int32,
  width : Int32,
  height : Int32,
) -> Unit = "moonui_control_set_bounds"

///|
extern "c" fn c_control_detach(child : Int64) -> Unit = "moonui_control_detach"

///|
/// T74：挂进容器（滚动视口的文档区）。child 的坐标在 Core 侧已平移成
/// 文档区坐标，C 侧不再动。
extern "c" fn c_container_attach(container : Int64, child : Int64) -> Unit = "moonui_container_attach"

///|
/// T74：滚动视口的滚动行程。axis 0=Vertical 1=Horizontal（跟布局的
/// Axis 编码一致）。宽高是物理像素。
extern "c" fn c_scroll_set_content(
  scroll : Int64,
  axis : Int32,
  width : Int32,
  height : Int32,
) -> Unit = "moonui_scroll_set_content"

///|
extern "c" fn c_control_raise(child : Int64) -> Unit = "moonui_control_raise"

///|
extern "c" fn c_control_z_index(child : Int64) -> Int32 = "moonui_control_z_index"

///|
/// 焦点链（`T29`）：Core 声明的整份链推给后端。`ids` 是空格分隔的十进制 owner
/// 指针（MoonBit 过不来数组，序列化成文本，和 libui 那份同一招）。0 = 接好，
/// -1 = 窗口句柄不真，-2 = 链里有 owner 换不出 view，-3 = 文本解析失败。
#borrow(ids)
extern "c" fn c_set_focus_chain(
  window : Int64,
  ids : Bytes,
  ids_len : Int32,
) -> Int32 = "moonui_set_focus_chain"

///|
/// `T41` 无障碍语义下发。role 是 `AccessRole` 的声明序号（0..9，与
/// adapter.h 的注释同一份契约）；state 打包：bit0 = visible、bit1 = enabled、
/// bits2-3 = checked（0 = 无此态、1 = 未勾、2 = 已勾）。
#borrow(label, desc)
extern "c" fn c_set_widget_accessibility(
  c : Int64,
  role : Int32,
  label : Bytes,
  label_len : Int32,
  desc : Bytes,
  desc_len : Int32,
  state : Int32,
) -> Int32 = "moonui_set_widget_accessibility"

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

// ---- 控件的 FFI 包装（FP2）----
// 形状与 ../libui-common/ffi.mbt 的 native_* 那批一致，只是底下直写 AppKit。

///|
/// adapter 的 kind 编码：0=Label 1=Button 2=TextInput 3=Checkbox
/// 4=PasswordInput 5=Separator 13=VSeparator 14=MenuRow 15=Scroll（T74 起
/// 滚动视口占用一个原生对象）。其余叶子（Slider 等）各有专属的 moonui_*_new
/// 入口，不走 moonui_widget_new；纯布局节点在 §14 里不占原生对象，走到这里
/// 就是调用方的错，所以显式报错。
fn kind_code(kind : @moonui.WidgetKind) -> Int32 raise @moonui.UiError {
  match kind {
    @moonui.Label => 0
    @moonui.Button => 1
    @moonui.TextInput => 2
    @moonui.Checkbox => 3
    @moonui.PasswordInput => 4
    @moonui.Separator => 5
    @moonui.VSeparator => 13
    @moonui.MenuRow => 14
    @moonui.Scroll => 15
    @moonui.Row
    | @moonui.Column
    | @moonui.Padding
    | @moonui.Spacer
    | @moonui.Center
    | @moonui.Stack
    | @moonui.Grid =>
      raise @moonui.Unsupported(
        "纯布局节点（Row/Column/…）不占原生对象",
      )
    _ =>
      raise @moonui.Unsupported(
        "这个控件种类走专属的创建入口，不走 moonui_widget_new",
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
/// 原生量出来的固有尺寸，物理像素。
pub fn native_widget_minimum_size(
  h : @moonui.NativeHandle,
) -> (Int32, Int32) raise @moonui.UiError {
  unpack2(c_widget_minimum_size(handles.resolve(h).0))
}

///|
pub fn native_widget_dpi(
  h : @moonui.NativeHandle,
) -> Int32 raise @moonui.UiError {
  c_widget_dpi(handles.resolve(h).0)
}

///|
/// 相对父窗口客户区的左上角，物理像素。
pub fn native_widget_origin(
  h : @moonui.NativeHandle,
) -> (Int32, Int32) raise @moonui.UiError {
  unpack2(c_widget_origin(handles.resolve(h).0))
}

///|
pub fn native_widget_size(
  h : @moonui.NativeHandle,
) -> (Int32, Int32) raise @moonui.UiError {
  unpack2(c_widget_size(handles.resolve(h).0))
}

///|
pub fn native_widget_on_click(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_widget_on_clicked(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("原生点击回调槽位已用满")
  }
}

///|
pub fn native_widget_on_text_changed(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_widget_on_text_changed(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("原生文本变化回调槽位已用满")
  }
}

///|
pub fn native_widget_on_toggled(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_widget_on_toggled(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("原生勾选回调槽位已用满")
  }
}

///|
pub fn native_slider_new(
  min : Int32,
  max : Int32,
) -> @moonui.NativeHandle raise @moonui.UiError {
  register(c_slider_new(min, max), "moonui_slider_new")
}

///|
pub fn native_slider_set_range(
  h : @moonui.NativeHandle,
  min : Int32,
  max : Int32,
) -> Unit raise @moonui.UiError {
  c_slider_set_range(handles.resolve(h).0, min, max)
}

///|
pub fn native_slider_on_changed(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_slider_on_changed(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("原生滑块回调槽位已用满")
  }
}

///|
pub fn native_spinbox_new(
  min : Int32,
  max : Int32,
) -> @moonui.NativeHandle raise @moonui.UiError {
  register(c_spinbox_new(min, max), "moonui_spinbox_new")
}

///|
pub fn native_spinbox_on_changed(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_spinbox_on_changed(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("原生数字框回调槽位已用满")
  }
}

///|
pub fn native_progress_new() -> @moonui.NativeHandle raise @moonui.UiError {
  register(c_progress_new(), "moonui_progress_new")
}

///|
pub fn native_combobox_new() -> @moonui.NativeHandle raise @moonui.UiError {
  register(c_combobox_new(), "moonui_combobox_new")
}

///|
pub fn native_combobox_on_selected(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_combobox_on_selected(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("原生下拉框回调槽位已用满")
  }
}

///|
pub fn native_radio_new() -> @moonui.NativeHandle raise @moonui.UiError {
  register(c_radio_new(), "moonui_radio_new")
}

///|
pub fn native_radio_on_selected(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_radio_on_selected(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("原生单选组回调槽位已用满")
  }
}

///|
pub fn native_multiline_new() -> @moonui.NativeHandle raise @moonui.UiError {
  register(c_multiline_new(), "moonui_multiline_new")
}

///|
pub fn native_multiline_on_changed(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_multiline_on_changed(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("原生多行文本回调槽位已用满")
  }
}

///|
pub fn native_datepicker_new() -> @moonui.NativeHandle raise @moonui.UiError {
  register(c_datepicker_new(), "moonui_datepicker_new")
}

///|
pub fn native_datepicker_set_text(
  h : @moonui.NativeHandle,
  text : String,
) -> Unit raise @moonui.UiError {
  let t = utf8(text)
  let rc = c_datepicker_set_text(handles.resolve(h).0, t, t.length())
  if rc != 0 {
    raise @moonui.OperationFailed("日期时间文本格式不对：\{text}")
  }
}

///|
pub fn native_datepicker_text(
  h : @moonui.NativeHandle,
) -> String raise @moonui.UiError {
  @utf8.decode_lossy(c_datepicker_text(handles.resolve(h).0))
}

///|
pub fn native_datepicker_on_changed(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_datepicker_on_changed(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("原生日期控件回调槽位已用满")
  }
}

///|
pub fn native_widget_set_value(
  h : @moonui.NativeHandle,
  v : Int32,
) -> Unit raise @moonui.UiError {
  c_widget_set_value(handles.resolve(h).0, v)
}

///|
pub fn native_widget_value(
  h : @moonui.NativeHandle,
) -> Int32 raise @moonui.UiError {
  c_widget_value(handles.resolve(h).0)
}

///|
pub fn native_widget_append_option(
  h : @moonui.NativeHandle,
  text : String,
) -> Unit raise @moonui.UiError {
  let t = utf8(text)
  c_widget_append_option(handles.resolve(h).0, t, t.length())
}

///|
pub fn native_widget_set_selected(
  h : @moonui.NativeHandle,
  index : Int32,
) -> Unit raise @moonui.UiError {
  c_widget_set_selected(handles.resolve(h).0, index)
}

///|
pub fn native_widget_selected(
  h : @moonui.NativeHandle,
) -> Int32 raise @moonui.UiError {
  c_widget_selected(handles.resolve(h).0)
}

///|
pub fn native_control_attach(
  window : @moonui.NativeHandle,
  child : @moonui.NativeHandle,
) -> Unit raise @moonui.UiError {
  c_control_attach(handles.resolve(window).0, handles.resolve(child).0)
}

///|
pub fn native_control_set_bounds(
  child : @moonui.NativeHandle,
  x : Int32,
  y : Int32,
  width : Int32,
  height : Int32,
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
/// T74：把 child 挂进容器控件的文档区（C 侧 addSubview 到 documentView）。
pub fn native_container_attach(
  container : @moonui.NativeHandle,
  child : @moonui.NativeHandle,
) -> Unit raise @moonui.UiError {
  c_container_attach(handles.resolve(container).0, handles.resolve(child).0)
}

///|
/// T74：滚动视口的滚动行程（内容完整尺寸）。Core 侧传的是逻辑尺寸，
/// 这里按视口自己的缩放换成物理像素再进 C。
pub fn native_scroll_set_content(
  scroll : @moonui.NativeHandle,
  axis : @moonui.Axis,
  size : @moonui.LogicalSize,
) -> Unit raise @moonui.UiError {
  let p = scale_of_widget(scroll).to_physical_size(size)
  let code = match axis {
    @moonui.Vertical => 0
    @moonui.Horizontal => 1
  }
  c_scroll_set_content(handles.resolve(scroll).0, code, p.width, p.height)
}

///|
pub fn native_control_raise(
  child : @moonui.NativeHandle,
) -> Unit raise @moonui.UiError {
  c_control_raise(handles.resolve(child).0)
}

///|
pub fn native_control_z_index(
  child : @moonui.NativeHandle,
) -> Int32 raise @moonui.UiError {
  c_control_z_index(handles.resolve(child).0)
}

///|
/// 焦点链（`T29`）：Core 声明的整份链推给后端。`chain` 是声明顺序的 owner 指针
/// 列表，序列化成空格分隔的十进制文本过 FFI（MoonBit 过不来数组，和 libui 那份
/// 同一招）。这只窗口的 Tab 遍历从此按链走（链尾回链头），不再跟 z-order。
pub fn native_set_focus_chain(
  window : @moonui.NativeHandle,
  chain : Array[@moonui.NativeHandle],
) -> Unit raise @moonui.UiError {
  let mut parts = ""
  for i, h in chain {
    if i > 0 {
      parts = parts + " "
    }
    parts = parts + handles.resolve(h).0.to_string()
  }
  let ids = utf8(parts)
  match c_set_focus_chain(handles.resolve(window).0, ids, ids.length()) {
    0 => ()
    -1 =>
      raise @moonui.OperationFailed(
        "焦点链装不进去：窗口不在后端登记表里",
      )
    _ =>
      raise @moonui.OperationFailed(
        "焦点链装不进去：链里有 owner 换不出原生 view",
      )
  }
}

///|
/// 语义下发（`T41`）。0 = 成功，负数 = 失败（控件没有对应的原生 view 之类）。
pub fn native_set_widget_accessibility(
  h : @moonui.NativeHandle,
  role : Int32,
  label : String,
  desc : String,
  state : Int32,
) -> Unit raise @moonui.UiError {
  let l = utf8(label)
  let d = utf8(desc)
  let rc = c_set_widget_accessibility(
    handles.resolve(h).0,
    role,
    l,
    l.length(),
    d,
    d.length(),
    state,
  )
  if rc != 0 {
    raise @moonui.OperationFailed("无障碍语义下发失败")
  }
}

///|
// ---- 剪贴板 / 对话框 / 文件面板 / 菜单栏 / 应用图标（T76，§48-18/19/20、§26）----
//
// 五组入口的 ABI 契约都在 adapter.h；MoonBit 这一层和 ../libui-common/ffi.mbt
// 的同名函数逐字相同——分叉只在 C（那边是 adapter_native.m 直写 AppKit，和
// adapter_macos.m 落到同一组系统调用），§47 的"分叉只到 C 为止"在这里就是
// 两份 MoonBit 的复制体。下面的注释只写本侧特有的那几句，其余理由看 libui 那份。
extern "c" fn c_clipboard_text() -> Bytes = "moonui_clipboard_text"

///|
#borrow(text)
extern "c" fn c_clipboard_set_text(text : Bytes, text_len : Int32) -> Int32 = "moonui_clipboard_set_text"

///|
#borrow(title, text)
extern "c" fn c_dialog_message(
  title : Bytes,
  title_len : Int32,
  text : Bytes,
  text_len : Int32,
) -> Int32 = "moonui_dialog_message"

///|
#borrow(title, text)
extern "c" fn c_dialog_confirm(
  title : Bytes,
  title_len : Int32,
  text : Bytes,
  text_len : Int32,
) -> Int32 = "moonui_dialog_confirm"

///|
#borrow(title)
extern "c" fn c_open_file(title : Bytes, title_len : Int32) -> Int32 = "moonui_open_file"

///|
#borrow(title, default_name)
extern "c" fn c_save_file(
  title : Bytes,
  title_len : Int32,
  default_name : Bytes,
  default_name_len : Int32,
) -> Int32 = "moonui_save_file"

///|
#borrow(title)
extern "c" fn c_select_folder(title : Bytes, title_len : Int32) -> Int32 = "moonui_select_folder"

///|
extern "c" fn c_file_dialog_path() -> Bytes = "moonui_file_dialog_path"

///|
/// 装整棵原生菜单。`tree` 是下面 `menu_tree` 打包出来的字节串（格式在 adapter.h），
/// 回调带一个 Core 的菜单项 id。
#borrow(tree)
extern "c" fn c_set_menu_bar(
  tree : Bytes,
  tree_len : Int32,
  call_closure : FuncRef[((Int32) -> Unit, Int32) -> Unit],
  closure : (Int32) -> Unit,
) -> Int32 = "moonui_set_menu_bar"

///|
extern "c" fn c_menu_item_set_checked(id : Int32, checked : Int32) -> Int32 = "moonui_menu_item_set_checked"

///|
/// 设置应用图标（§26）。`name` 是不带扩展名的 stem，平台各自补后缀。
#borrow(name)
extern "c" fn c_set_app_icon(name : Bytes, name_len : Int32) -> Int32 = "moonui_set_app_icon"

///|
extern "c" fn c_auto_dismiss_dialog(ms : Int32, index : Int32) -> Int32 = "moonui_auto_dismiss_dialog"

///|
#borrow(path)
extern "c" fn c_auto_answer_file_dialog(
  ms : Int32,
  path : Bytes,
  path_len : Int32,
  accept : Int32,
) -> Int32 = "moonui_auto_answer_file_dialog"

///|
extern "c" fn c_menu_click_item(id : Int32) -> Int32 = "moonui_menu_click_item"

///|
extern "c" fn c_menu_dump() -> Bytes = "moonui_menu_dump"

///|
/// 菜单树打包：字符串写成"i32 字节数 + UTF-8 内容、不带 NUL"（§29 的进 C 形态）。
fn menu_put_str(buf : @buffer.Buffer, s : String) -> Unit {
  let b = utf8(s)
  buf.write_int_le(b.length())
  buf.write_bytes(b)
}

///|
fn menu_put_byte(buf : @buffer.Buffer, v : Int32) -> Unit {
  buf.write_byte(v.to_byte())
}

///|
fn menu_put_bool(buf : @buffer.Buffer, v : Bool) -> Unit {
  menu_put_byte(buf, bool_to_c(v))
}

///|
fn menu_role_byte(role : @moonui.MenuRole) -> Int32 {
  match role {
    @moonui.Normal => 0
    @moonui.Check => 1
    @moonui.Radio => 2
  }
}

///|
/// 修饰键压成一个字节：bit0 ctrl、bit1 alt、bit2 shift、bit3 meta（adapter.h）。
fn menu_mods_byte(sc : @moonui.Shortcut) -> Int32 {
  let m = bool_to_c(sc.ctrl) + bool_to_c(sc.alt) * 2
  let m2 = bool_to_c(sc.shift) * 4 + bool_to_c(sc.meta) * 8
  m + m2
}

///|
fn menu_put_nodes(
  buf : @buffer.Buffer,
  nodes : Array[@moonui.MenuNode],
) -> Unit {
  for n in nodes {
    match n {
      @moonui.Item(item) => {
        menu_put_byte(buf, 0)
        menu_put_str(buf, item.label)
        buf.write_int_le(item.id)
        menu_put_byte(buf, menu_role_byte(item.role))
        menu_put_bool(buf, item.checked)
        menu_put_bool(buf, item.enabled)
        match item.shortcut {
          None => menu_put_byte(buf, 0)
          Some(sc) => {
            menu_put_byte(buf, 1)
            menu_put_byte(buf, menu_mods_byte(sc))
            menu_put_str(buf, sc.key)
          }
        }
      }
      @moonui.Separator => menu_put_byte(buf, 1)
      @moonui.Submenu(label, children) => {
        menu_put_byte(buf, 2)
        menu_put_str(buf, label)
        buf.write_int_le(children.length())
        menu_put_nodes(buf, children)
      }
    }
  }
}

///|
/// 把 Core 那棵菜单树打包成 adapter.h「菜单栏」一段说的那段字节。
///
/// 布局和 adapter.h 的说明是同一件事的两个副本，两份 C 的解析器也都照它写：改一处就得
/// 几处一起动，否则不会崩，只会「装得上但装错了」——菜单和 Core 想的不一样，那比崩难查。
/// libui 那侧的 macos_test 与 Win32 那份测试各断言一次 dump，本侧的 native_test
/// 再钉一次，三只钉子全对同一张布局。
fn menu_tree(bar : @moonui.MenuBar) -> Bytes {
  let buf = @buffer.Buffer()
  menu_put_byte(buf, 1)
  let menus = bar.menus()
  buf.write_int_le(menus.length())
  for m in menus {
    menu_put_str(buf, m.title())
    let nodes = m.nodes()
    buf.write_int_le(nodes.length())
    menu_put_nodes(buf, nodes)
  }
  buf.to_bytes()
}

///|
/// 读文本剪贴板（§23）。空 bytes = 现在读不到文本，统一成 `None`。
pub fn native_clipboard_text() -> String? {
  let b = c_clipboard_text()
  if b.length() == 0 {
    None
  } else {
    Some(@utf8.decode_lossy(b))
  }
}

///|
/// 写文本剪贴板。两个失败码都变成带原因的 `OperationFailed`（§33）。
pub fn native_clipboard_set_text(text : String) -> Unit raise @moonui.UiError {
  let t = utf8(text)
  match c_clipboard_set_text(t, t.length()) {
    0 => ()
    -1 =>
      raise @moonui.OperationFailed(
        "剪贴板打不开，可能有别的进程正占着它",
      )
    _ => raise @moonui.OperationFailed("剪贴板拿住了但没写进去")
  }
}

///|
/// 弹一只只带"确定"的消息框（§24）。同步阻塞到用户把它关掉为止。
pub fn native_dialog_message(
  title : String,
  text : String,
) -> Unit raise @moonui.UiError {
  let t = utf8(title)
  let s = utf8(text)
  match c_dialog_message(t, t.length(), s, s.length()) {
    0 => ()
    -1 => raise @moonui.OperationFailed("消息框的文案没能交给系统")
    _ => raise @moonui.OperationFailed("消息框没弹出来")
  }
}

///|
/// 弹一只"是/否"确认框，`true` = 用户选了"是"（§24）。0 是"用户没同意"（答案），
/// 负数是"弹都没弹出来"（故障），两条路分开。
pub fn native_dialog_confirm(
  title : String,
  text : String,
) -> Bool raise @moonui.UiError {
  let t = utf8(title)
  let s = utf8(text)
  match c_dialog_confirm(t, t.length(), s, s.length()) {
    1 => true
    0 => false
    -1 => raise @moonui.OperationFailed("确认框的文案没能交给系统")
    _ => raise @moonui.OperationFailed("确认框没弹出来")
  }
}

///|
/// 取走刚选中的路径（adapter.h 的取走语义）。空 bytes 当 `None`。
fn file_dialog_result() -> String? {
  let b = c_file_dialog_path()
  if b.length() == 0 {
    None
  } else {
    Some(@utf8.decode_lossy(b))
  }
}

///|
/// 打开文件面板（§24）。`Some(path)` = 用户选了；`None` = 用户取消；真失败 `raise`。
pub fn native_open_file(title : String) -> String? raise @moonui.UiError {
  let t = utf8(title)
  match c_open_file(t, t.length()) {
    1 => file_dialog_result()
    0 => None
    -1 =>
      raise @moonui.OperationFailed("文件面板的标题没能交给系统")
    _ => raise @moonui.OperationFailed("文件面板没弹出来")
  }
}

///|
/// 保存文件面板（§24）。`default_name` 是文件名栏里预填的字；返回值同
/// `native_open_file`。
pub fn native_save_file(
  title : String,
  default_name : String,
) -> String? raise @moonui.UiError {
  let t = utf8(title)
  let d = utf8(default_name)
  match c_save_file(t, t.length(), d, d.length()) {
    1 => file_dialog_result()
    0 => None
    -1 =>
      raise @moonui.OperationFailed(
        "保存面板的标题或默认名没能交给系统",
      )
    _ => raise @moonui.OperationFailed("保存面板没弹出来")
  }
}

///|
/// 选文件夹面板（§24）。返回值同 `native_open_file`。
pub fn native_select_folder(title : String) -> String? raise @moonui.UiError {
  let t = utf8(title)
  match c_select_folder(t, t.length()) {
    1 => file_dialog_result()
    0 => None
    -1 =>
      raise @moonui.OperationFailed(
        "文件夹面板的标题没能交给系统",
      )
    _ => raise @moonui.OperationFailed("文件夹面板没弹出来")
  }
}

///|
/// 装整棵菜单栏（§25 / §48-20）。`on_click` 收到的是原生派发回来的 Core 菜单项 id，
/// 由 `NativeBackend` 把它变成 `MenuSelect` 事件。-1 是"树读不懂"（我们自己的 bug，
/// 不许咽下去），-2 是"还没初始化"。
pub fn native_set_menu_bar(
  bar : @moonui.MenuBar,
  on_click : (Int32) -> Unit,
) -> Unit raise @moonui.UiError {
  let tree = menu_tree(bar)
  match c_set_menu_bar(tree, tree.length(), fn(f, id) { f(id) }, on_click) {
    0 => ()
    -1 =>
      raise @moonui.OperationFailed(
        "菜单栏没装上：打包出来的树和 adapter.h 的布局对不上",
      )
    _ =>
      raise @moonui.OperationFailed(
        "原生主菜单还不存在（还没初始化）",
      )
  }
}

///|
/// 设置应用图标（§26）。`name` 是不带扩展名的 stem：C 侧各自补 `.png` / `.ico`。
pub fn native_set_app_icon(name : String) -> Unit raise @moonui.UiError {
  match c_set_app_icon(utf8(name), name.length()) {
    0 => ()
    -1 =>
      raise @moonui.OperationFailed(
        "图标文件读不出来（路径不对或格式不受支持）：\{name}",
      )
    _ =>
      raise @moonui.OperationFailed(
        "原生应用对象还不存在（还没初始化）",
      )
  }
}

///|
/// 把 Core 改掉的勾选态推给当下那棵原生菜单（§25）。报 -1 必须变成错误而不是
/// 静悄悄什么都不做。文案和 `MockBackend` 的同名实现一致，headless 与真窗口两侧
/// 钉的是同一句话。
pub fn native_menu_item_set_checked(
  id : Int32,
  checked : Bool,
) -> Unit raise @moonui.UiError {
  match c_menu_item_set_checked(id, bool_to_c(checked)) {
    0 => ()
    _ =>
      raise @moonui.OperationFailed(
        "菜单项 \{id} 不在已安装的菜单栏里",
      )
  }
}

///|
/// 装好"ms 毫秒之后按下下一个对话框的第 index 个按钮"（0 = 第一只、1 = 否）。
/// 只给测试用：对话框同步阻塞，不在调用之前把"用户会按哪个"安排好，调用方就
/// 永远回不来。一次性的。返回 0 = 已装好，-1 = index 越界。
pub fn native_auto_dismiss_dialog(ms : Int32, index : Int32) -> Int32 {
  c_auto_dismiss_dialog(ms, index)
}

///|
/// 等价于"用户在 ms 毫秒之后对下一个文件面板按 接受（面板已经停在 path 上）/ 取消
/// （`accept` = false，此时 path 传空串）"。只给测试用。一次性的。
/// 返回 0 = 已装好，-1 = 接受但 path 为空（这条 ABI 见 adapter.h）。
pub fn native_auto_answer_file_dialog(
  ms : Int32,
  path : String,
  accept : Bool,
) -> Int32 {
  let p = utf8(path)
  c_auto_answer_file_dialog(ms, p, p.length(), if accept { 1 } else { 0 })
}

///|
/// 等价于"用户在原生菜单里点了 id 这一项"。只给测试用：真实点击由原生菜单自己
/// 报回来。0 = 已派发，-1 = 没这个 id，-2 = 有这一项但它是禁用的。
pub fn native_menu_click_item(id : Int32) -> Int32 {
  c_menu_click_item(id)
}

///|
/// 原生菜单当下的快照，格式在 adapter.h 的 `moonui_menu_dump` 那一段。只给测试用。
/// 空串 = 还没装过菜单。
pub fn native_menu_dump() -> String {
  @utf8.decode_lossy(c_menu_dump())
}
