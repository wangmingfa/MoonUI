///|
/// 原生 Cocoa 后端的 FFI 层（设计文档 §51 的 Backend #2，macOS 半）。
///
/// 和 ../libui-common/ffi.mbt（`T82` 删）同一套 moonui_native_* 名字，但只声明 FP1 需要的窗口 +
/// 事件循环那一半——控件（Button/Label/…）在 FP2 补，补之前 backend.mbt 里对应
/// 的方法 raise Unsupported。这一层不是公共 API，服务对象是同包内的 `Backend`
/// 实现：把 `moonui_native_*` 的形状映射成 MoonBit 的、把 C 的失败形态换成 `UiError`
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
extern "c" fn c_init() -> Int32 = "moonui_native_init"

///|
extern "c" fn c_last_error() -> Bytes = "moonui_native_last_error"

///|
extern "c" fn c_terminate() -> Unit = "moonui_native_terminate"

///|
#borrow(title)
extern "c" fn c_window_new(
  title : Bytes,
  title_len : Int32,
  width : Int32,
  height : Int32,
) -> Int64 = "moonui_native_window_new"

///|
extern "c" fn c_window_show(w : Int64) -> Unit = "moonui_native_window_show"

///|
extern "c" fn c_window_hide(w : Int64) -> Unit = "moonui_native_window_hide"

///|
extern "c" fn c_window_destroy(w : Int64) -> Unit = "moonui_native_window_destroy"

///|
#borrow(title)
extern "c" fn c_window_set_title(
  w : Int64,
  title : Bytes,
  title_len : Int32,
) -> Unit = "moonui_native_window_set_title"

///|
extern "c" fn c_window_set_content_size(
  w : Int64,
  width : Int32,
  height : Int32,
) -> Unit = "moonui_native_window_set_content_size"

///|
extern "c" fn c_window_content_size(w : Int64) -> Int64 = "moonui_native_window_content_size"

///|
extern "c" fn c_window_set_min_size(
  w : Int64,
  width : Int32,
  height : Int32,
) -> Unit = "moonui_native_window_set_min_size"

///|
extern "c" fn c_window_min_size(w : Int64) -> Int64 = "moonui_native_window_min_size"

///|
extern "c" fn c_window_in_live_resize(w : Int64) -> Int32 = "moonui_native_window_in_live_resize"

///|
extern "c" fn c_window_set_position(w : Int64, x : Int32, y : Int32) -> Unit = "moonui_native_window_set_position"

///|
extern "c" fn c_window_position(w : Int64) -> Int64 = "moonui_native_window_position"

///|
extern "c" fn c_window_move_external(w : Int64, x : Int32, y : Int32) -> Unit = "moonui_native_window_move_external"

///|
extern "c" fn c_window_drag_step(w : Int64, x : Int32, y : Int32) -> Unit = "moonui_native_window_drag_step"

///|
extern "c" fn c_window_set_resizable(w : Int64, v : Int32) -> Unit = "moonui_native_window_set_resizable"

///|
extern "c" fn c_window_set_fullscreen(w : Int64, v : Int32) -> Unit = "moonui_native_window_set_fullscreen"

///|
extern "c" fn c_window_set_titlebar_style(w : Int64, immersive : Int32) -> Unit = "moonui_native_window_set_titlebar_style"

///|
extern "c" fn c_window_titlebar_style(w : Int64) -> Int32 = "moonui_native_window_titlebar_style"

///|
extern "c" fn c_window_set_drag_band(w : Int64, height : Int32) -> Unit = "moonui_native_window_set_drag_band"

///|
extern "c" fn c_window_drag_band(w : Int64) -> Int32 = "moonui_native_window_drag_band"

///|
extern "c" fn c_window_set_traffic_light_position(
  w : Int64,
  x : Int32,
  y : Int32,
) -> Unit = "moonui_native_window_set_traffic_light_position"

///|
extern "c" fn c_window_traffic_light_position(w : Int64) -> Int64 = "moonui_native_window_traffic_light_position"

///|
#borrow(dir)
extern "c" fn c_snapshot_all(dir : Bytes, dir_len : Int32) -> Int32 = "moonui_native_snapshot_all"

///|
extern "c" fn c_window_dpi(w : Int64) -> Int32 = "moonui_native_window_dpi"

///|
extern "c" fn c_system_dpi() -> Int32 = "moonui_native_system_dpi"

///|
extern "c" fn c_screen_work_area() -> Int64 = "moonui_native_screen_work_area"

///|
extern "c" fn c_window_screen_origin(w : Int64) -> Int64 = "moonui_native_window_screen_origin"

///|
extern "c" fn c_window_screen_size(w : Int64) -> Int64 = "moonui_native_window_screen_size"

///|
extern "c" fn c_system_theme() -> Int32 = "moonui_native_system_theme"

///|
/// 宿主血统：1 = macOS，2 = Windows。由各平台那份 adapter 各给一个常量——
/// 共享层只负责翻译（`backend.mbt` 的 `host_platform`）。
extern "c" fn c_host_platform() -> Int32 = "moonui_native_host_platform"

///|
extern "c" fn c_prefers_reduced_motion() -> Int32 = "moonui_native_prefers_reduced_motion"

///|
extern "c" fn c_prefers_high_contrast() -> Int32 = "moonui_native_prefers_high_contrast"

///|
extern "c" fn c_window_on_closing(
  w : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_window_on_closing"

///|
extern "c" fn c_window_on_resized(
  w : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_window_on_resized"

///|
extern "c" fn c_window_on_moved(
  w : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_window_on_moved"

///|
extern "c" fn c_main_steps() -> Unit = "moonui_native_main_steps"

///|
extern "c" fn c_main_step(wait : Int32) -> Int32 = "moonui_native_main_step"

///|
extern "c" fn c_messages_pending() -> Int32 = "moonui_native_messages_pending"

///|
extern "c" fn c_wait_messages(ms : Int32) -> Int32 = "moonui_native_wait_messages"

///|
extern "c" fn c_time_ms() -> Int64 = "moonui_native_time_ms"

///|
extern "c" fn c_quit() -> Unit = "moonui_native_quit"

///|
extern "c" fn c_quit_requested() -> Int32 = "moonui_native_quit_requested"

// ---- 控件（FP2）----
//
// 和 ../libui-common/ffi.mbt（`T82` 删）同一套 moonui_native_* 名字，但底下直写 AppKit。kind 编码
// 与 adapter.h 一致：0=Label 1=Button 2=TextInput 3=Checkbox 4=PasswordInput
// 5=Separator 13=VSeparator 14=MenuRow；Slider/Spinbox/Progress/ComboBox/
// RadioButtons/MultilineEntry/DatePicker 各有专属的 moonui_native_*_new 入口。

///|
#borrow(text)
extern "c" fn c_widget_new(
  kind : Int32,
  text : Bytes,
  text_len : Int32,
) -> Int64 = "moonui_native_widget_new"

///|
extern "c" fn c_widget_destroy(c : Int64) -> Unit = "moonui_native_widget_destroy"

///|
#borrow(text)
extern "c" fn c_widget_set_text(
  c : Int64,
  text : Bytes,
  text_len : Int32,
) -> Unit = "moonui_native_widget_set_text"

///|
extern "c" fn c_widget_text(c : Int64) -> Bytes = "moonui_native_widget_text"

///|
extern "c" fn c_widget_set_checked(c : Int64, v : Int32) -> Unit = "moonui_native_widget_set_checked"

///|
extern "c" fn c_widget_checked(c : Int64) -> Int32 = "moonui_native_widget_checked"

///|
extern "c" fn c_widget_set_insets(
  c : Int64,
  top : Int32,
  end : Int32,
  bottom : Int32,
  start : Int32,
) -> Unit = "moonui_native_widget_set_insets"

///|
extern "c" fn c_widget_set_visible(c : Int64, v : Int32) -> Unit = "moonui_native_widget_set_visible"

///|
extern "c" fn c_widget_visible(c : Int64) -> Int32 = "moonui_native_widget_visible"

///|
extern "c" fn c_widget_set_enabled(c : Int64, v : Int32) -> Unit = "moonui_native_widget_set_enabled"

///|
extern "c" fn c_widget_set_opacity(c : Int64, v : Int32) -> Unit = "moonui_native_widget_set_opacity"

///|
extern "c" fn c_widget_set_style(
  c : Int64,
  bg_rgb : Int64,
  fg_rgb : Int64,
  radius_permille : Int32,
  font_permille : Int32,
  weight : Int32,
) -> Int32 = "moonui_native_widget_set_style"

///|
#borrow(name)
extern "c" fn c_widget_set_icon(
  c : Int64,
  name : Bytes,
  name_len : Int32,
) -> Int32 = "moonui_native_widget_set_icon"

///|
/// 图标（皮肤账）：mac = SF Symbols 名，Windows 半静默缺席。
pub fn native_widget_set_icon(
  h : @moonui.NativeHandle,
  name : String,
) -> Unit raise @moonui.UiError {
  let n = utf8(name)
  let _ = c_widget_set_icon(handles.resolve(h).0, n, n.length())
}

///|
/// 样式下发（adapter.h 皮肤通道）：各字段独立，None = -1 哨兵（"这项不动"）。
/// 颜色打包 0xRRGGBB；radius/font 换千分比过 FFI（与 opacity 同一口径）；
/// weight 0/1/2 = Regular/Medium/Bold。翻译整层在 backend 的 set_widget_style
/// ——这里只做打包与换算。
pub fn native_widget_set_style(
  h : @moonui.NativeHandle,
  background~ : @moonui.Color?,
  foreground~ : @moonui.Color?,
  radius~ : Double?,
  font_size~ : Double?,
  weight~ : Int32?,
) -> Unit raise @moonui.UiError {
  fn pack(c : @moonui.Color?) -> Int64 {
    match c {
      Some(col) =>
        (col.r.to_int64() << 16) | (col.g.to_int64() << 8) | col.b.to_int64()
      None => -1L
    }
  }
  let bg64 = pack(background)
  let fg64 = pack(foreground)
  let r = match radius {
    Some(v) => (v * 1000.0).to_int()
    None => -1
  }
  let f = match font_size {
    Some(v) => (v * 1000.0).to_int()
    None => -1
  }
  let w = match weight {
    Some(v) => v
    None => -1
  }
  let _ = c_widget_set_style(handles.resolve(h).0, bg64, fg64, r, f, w)
}

///|
extern "c" fn c_widget_enabled(c : Int64) -> Int32 = "moonui_native_widget_enabled"

///|
extern "c" fn c_widget_minimum_size(c : Int64) -> Int64 = "moonui_native_widget_minimum_size"

///|
extern "c" fn c_widget_dpi(c : Int64) -> Int32 = "moonui_native_widget_dpi"

///|
extern "c" fn c_widget_origin(c : Int64) -> Int64 = "moonui_native_widget_origin"

///|
extern "c" fn c_widget_size(c : Int64) -> Int64 = "moonui_native_widget_size"

///|
extern "c" fn c_widget_on_clicked(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_widget_on_clicked"

///|
/// 自定义绘制面的点击（`T101`）：与按钮同一条槽位/分发器机制，只是事件源在
/// C 侧那支 NSView 子类的 `mouseUp:` 里（按下并原地抬起才算一次）。
extern "c" fn c_custom_on_clicked(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_custom_on_clicked"

///|
/// 自绘面的焦点 opt-in（`T102` 第十一刀）：0 = 已设置（句柄不是自绘面时也是
/// 0，按 Core 的契约是空操作），-1 = 句柄为空，-2 = 平台如实缺席（Windows 的
/// kind 18 还没有创建分支，自绘面整个不存在）。
extern "c" fn c_custom_set_focusable(c : Int64, on : Int32) -> Int32 = "moonui_native_custom_set_focusable"

///|
extern "c" fn c_widget_on_text_changed(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_widget_on_text_changed"

///|
extern "c" fn c_widget_on_toggled(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_widget_on_toggled"

///|
extern "c" fn c_slider_new(min : Int32, max : Int32) -> Int64 = "moonui_native_slider_new"

///|
extern "c" fn c_slider_set_range(c : Int64, min : Int32, max : Int32) -> Unit = "moonui_native_slider_set_range"

///|
extern "c" fn c_slider_knob_probe(c : Int64, permille : Int32) -> Int64 = "moonui_native_slider_knob_probe"

///|
extern "c" fn c_slider_on_changed(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_slider_on_changed"

///|
extern "c" fn c_spinbox_new(min : Int32, max : Int32) -> Int64 = "moonui_native_spinbox_new"

///|
extern "c" fn c_spinbox_on_changed(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_spinbox_on_changed"

///|
extern "c" fn c_progress_new() -> Int64 = "moonui_native_progress_new"

///|
extern "c" fn c_combobox_new() -> Int64 = "moonui_native_combobox_new"

///|
extern "c" fn c_combobox_on_selected(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_combobox_on_selected"

///|
extern "c" fn c_radio_new() -> Int64 = "moonui_native_radio_new"

///|
extern "c" fn c_radio_on_selected(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_radio_on_selected"

///|
extern "c" fn c_multiline_new() -> Int64 = "moonui_native_multiline_new"

///|
extern "c" fn c_multiline_on_changed(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_multiline_on_changed"

///|
extern "c" fn c_datepicker_new() -> Int64 = "moonui_native_datepicker_new"

///|
#borrow(text)
extern "c" fn c_datepicker_set_text(
  c : Int64,
  text : Bytes,
  text_len : Int32,
) -> Int32 = "moonui_native_datepicker_set_text"

///|
extern "c" fn c_datepicker_text(c : Int64) -> Bytes = "moonui_native_datepicker_text"

///|
extern "c" fn c_datepicker_on_changed(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_datepicker_on_changed"

///|
extern "c" fn c_widget_set_value(c : Int64, v : Int32) -> Unit = "moonui_native_widget_set_value"

///|
extern "c" fn c_widget_value(c : Int64) -> Int32 = "moonui_native_widget_value"

///|
#borrow(text)
extern "c" fn c_widget_append_option(
  c : Int64,
  text : Bytes,
  text_len : Int32,
) -> Unit = "moonui_native_widget_append_option"

///|
extern "c" fn c_widget_set_selected(c : Int64, index : Int32) -> Unit = "moonui_native_widget_set_selected"

///|
extern "c" fn c_widget_selected(c : Int64) -> Int32 = "moonui_native_widget_selected"

///|
extern "c" fn c_control_attach(w : Int64, child : Int64) -> Unit = "moonui_native_control_attach"

///|
extern "c" fn c_control_set_bounds(
  child : Int64,
  x : Int32,
  y : Int32,
  width : Int32,
  height : Int32,
) -> Unit = "moonui_native_control_set_bounds"

///|
extern "c" fn c_control_detach(child : Int64) -> Unit = "moonui_native_control_detach"

///|
/// T74：挂进容器（滚动视口的文档区）。child 的坐标在 Core 侧已平移成
/// 文档区坐标，C 侧不再动。
extern "c" fn c_container_attach(container : Int64, child : Int64) -> Unit = "moonui_native_container_attach"

///|
/// T74：滚动视口的滚动行程。axis 0=Vertical 1=Horizontal（跟布局的
/// Axis 编码一致）。宽高是物理像素。
extern "c" fn c_scroll_set_content(
  scroll : Int64,
  axis : Int32,
  width : Int32,
  height : Int32,
) -> Unit = "moonui_native_scroll_set_content"

///|
extern "c" fn c_control_raise(child : Int64) -> Unit = "moonui_native_control_raise"

///|
extern "c" fn c_control_z_index(child : Int64) -> Int32 = "moonui_native_control_z_index"

///|
/// 焦点链（`T29`）：Core 声明的整份链推给后端。`ids` 是空格分隔的十进制 owner
/// 指针（MoonBit 过不来数组，序列化成文本，和 libui 那份（`T82` 删）同一招）。0 = 接好，
/// -1 = 窗口句柄不真，-2 = 链里有 owner 换不出 view，-3 = 文本解析失败。
#borrow(ids)
extern "c" fn c_set_focus_chain(
  window : Int64,
  ids : Bytes,
  ids_len : Int32,
) -> Int32 = "moonui_native_set_focus_chain"

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
) -> Int32 = "moonui_native_set_widget_accessibility"

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
  register(
    c_window_new(t, t.length(), width, height),
    "moonui_native_window_new",
  )
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
/// 客户区最小尺寸，物理像素；(0, 0) = 清掉限制。
pub fn native_window_set_min_size(
  h : @moonui.NativeHandle,
  width : Int32,
  height : Int32,
) -> Unit raise @moonui.UiError {
  c_window_set_min_size(handles.resolve(h).0, width, height)
}

///|
/// 读回最小尺寸（物理像素）。测试用。
pub fn native_window_min_size(
  h : @moonui.NativeHandle,
) -> (Int32, Int32) raise @moonui.UiError {
  unpack2(c_window_min_size(handles.resolve(h).0))
}

///|
/// 当下是不是在**用户拖拽改尺寸**的会话里（mac 的 `inLiveResize`、Win32 的
/// WM_ENTERSIZEMOVE..WM_EXITSIZEMOVE 之间）。实时重排只认拖拽——程序化改尺寸
/// 不算（Core 的 `set_size` 自己当场重排）。
pub fn native_window_in_live_resize(
  h : @moonui.NativeHandle,
) -> Bool raise @moonui.UiError {
  c_window_in_live_resize(handles.resolve(h).0) != 0
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
/// 测试缝（只给真窗口测试用）：模拟"外部移窗"——用户拖动的中途态（mac 上是
/// WindowServer 挪了窗而 AppKit 不通知的那段时间，Windows 上是照发 WM_MOVE 的
/// 一次真移）。绕过程序化搬窗的回声抑制、不登记位置：mac 半后续由拖动期轮询
/// 从 WindowServer 发现并补报 Moved，Windows 半当场回 WM_MOVE。
pub fn native_window_move_external(
  h : @moonui.NativeHandle,
  x : Int32,
  y : Int32,
) -> Unit raise @moonui.UiError {
  c_window_move_external(handles.resolve(h).0, x, y)
}

///|
/// 测试缝（只给真窗口测试用）：喂一拍"合成拖动"——模拟用户拖着标题栏走到
/// (x, y)，走**鼠标增量预测**路径（方案 B，拖动期位置 = 锚点 + 鼠标位移）。
/// mac 半把预测原点给成 (x, y)、真把窗挪过去，并**同步**走一拍拖动期轮询
/// （发现→补报→吸附联动在返回前落定，不等定时器）；不读真实鼠标、不因松手
/// 把预测关掉。Windows 半退化成一次外部移窗（那侧 WM_MOVE 同步发）。
/// 坐标契约与 `native_window_move_external` 相同：物理像素。
pub fn native_window_drag_step(
  h : @moonui.NativeHandle,
  x : Int32,
  y : Int32,
) -> Unit raise @moonui.UiError {
  c_window_drag_step(handles.resolve(h).0, x, y)
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
    Immersive => 1
    Standard => 0
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
/// 自绘顶条的拖动带（`T116`）：外框上缘往下 `height` 个**物理像素**算标题栏
/// （`WM_NCHITTEST` 回 HTCAPTION）。Core 把顶条高按该窗缩放过再送进来。
pub fn native_window_set_drag_band(
  h : @moonui.NativeHandle,
  height : Int32,
) -> Unit raise @moonui.UiError {
  c_window_set_drag_band(handles.resolve(h).0, height)
}

///|
pub fn native_window_drag_band(
  h : @moonui.NativeHandle,
) -> Int32 raise @moonui.UiError {
  c_window_drag_band(handles.resolve(h).0)
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
/// 离屏取证：让本进程把所有窗口的内容各写一张 PNG 到 `dir`，返回写成功的
/// 张数。走视图自绘通道（`cacheDisplayInRect:`），不经过屏幕采集——沙箱/
/// 无头环境里 `screencapture` 拿到的是全黑，这条拿到的是真像素。
///
/// 是开发/取证用的口子，不是产品路径：调用方要保证窗口已显示、布局已跑过
/// 一轮。返回 -3 表示本平台没有这条（Windows 半）。
pub fn native_snapshot_all(dir : String) -> Int32 {
  let d = utf8(dir)
  c_snapshot_all(d, d.length())
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
/// 宿主血统的原始读数（1 = macOS，2 = Windows，其余未知）。翻译成
/// `@moonui.HostPlatform` 的活在 `backend.mbt` 那侧，这里只给数。
pub fn native_host_platform() -> Int32 {
  c_host_platform()
}

///|
/// 进程级偏好读数（`T87`③）：系统"减少动态效果"开着没有。快照式（问一次
/// 拿一份），读不到就当关，不报错。
pub fn native_prefers_reduced_motion() -> Bool {
  c_prefers_reduced_motion() != 0
}

///|
/// 进程级偏好读数（`T87`②）：系统"增强对比度"开着没有。快照式，读不到就
/// 当关，不报错。
pub fn native_prefers_high_contrast() -> Bool {
  c_prefers_high_contrast() != 0
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
/// 注册"窗口被用户拖到新位置"。C 侧在程序化 `set_window_position` 时会把这条
/// 回声挡掉（与 `suppress_resize` 同一条约定），所以 Core 主动搬窗不会回声成
/// 一条 Moved——吸附联动（`App::follow_move`）自己搬邻居时也不会递归触发。
pub fn native_window_on_moved(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_window_on_moved(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("回调槽位已用满")
  }
}

///|
/// 循环开始前调一次：C 侧 finishLaunching，把 App 变成真正在跑的 App。
pub fn native_main_steps() -> Unit {
  c_main_steps()
}

///|
/// 泵一条原生事件。返回 false 只表示"循环已结束"（moonui_native_quit 之后）。
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
/// 单调时钟，毫秒。C 侧是 int64_t，这里按 libui 那份（`T82` 删）搬来的口径截成 Int32——
/// 事件循环的等待预算是毫秒级的 Int32，用不到 64 位。
pub fn native_time_ms() -> Int32 {
  c_time_ms().to_int()
}

///|
/// 把主循环标成"跑完了"。
pub fn native_quit() -> Unit {
  c_quit()
}

///|
/// 原生侧有没有请求结束循环（`T154`）。只读那面旗，不消费队列、不唤醒 runloop。
pub fn native_quit_requested() -> Bool {
  c_quit_requested() != 0
}

// ---- 控件的 FFI 包装（FP2）----
// 形状与 ../libui-common/ffi.mbt（`T82` 删）的 native_* 那批一致，只是底下直写 AppKit。

///|
/// adapter 的 kind 编码：0=Label 1=Button 2=TextInput 3=Checkbox
/// 4=PasswordInput 5=Separator 13=VSeparator 14=MenuRow 15=Scroll（T74 起
/// 滚动视口占用一个原生对象）16=Image（`T86⑤`，解码归平台的开工决策记在
/// TODO `T86⑤`）17=Panel（皮肤账的自绘面）。其余叶子（Slider 等）各有
/// 专属的 moonui_native_*_new 入口，不走 moonui_native_widget_new；
/// 纯布局节点在 §14 里不占原生对象，走到这里
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
    @moonui.Image => 16
    @moonui.Panel => 17
    @moonui.Custom => 18
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
        "这个控件种类走专属的创建入口，不走 moonui_native_widget_new",
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
  register(c_widget_new(code, t, t.length()), "moonui_native_widget_new")
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
/// 内边距（§51 的 MenuRow padding）：物理像素，四边各一份，口径同
/// `native_control_set_bounds`——逻辑值已在 backend.mbt 换算。
pub fn native_widget_set_insets(
  h : @moonui.NativeHandle,
  top : Int32,
  end : Int32,
  bottom : Int32,
  start : Int32,
) -> Unit raise @moonui.UiError {
  c_widget_set_insets(handles.resolve(h).0, top, end, bottom, start)
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
/// 不透明度（T84 动画通道）：Core 发 0..1 的 Double，这一层乘 1000 换成
/// 千分比整数过 FFI（FFI 只有整数，与 insets 同一条口径）。出界的值夹进
/// 0..1000，C 侧还有一道同样的夹紧（§33：可疑输入在唯一一处拦住）。
pub fn native_widget_set_opacity(
  h : @moonui.NativeHandle,
  v : Double,
) -> Unit raise @moonui.UiError {
  let m = (v * 1000.0).to_int()
  let m = if m < 0 { 0 } else if m > 1000 { 1000 } else { m }
  c_widget_set_opacity(handles.resolve(h).0, m)
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
pub fn native_custom_on_click(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_custom_on_clicked(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("原生点击回调槽位已用满")
  }
}

///|
pub fn native_custom_set_focusable(
  h : @moonui.NativeHandle,
  on : Bool,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  let rc = c_custom_set_focusable(ptr.0, if on { 1 } else { 0 })
  if rc != 0 {
    raise @moonui.OperationFailed(
      "自绘面焦点设置失败：\{rc}（-1 句柄为空，-2 平台缺席）",
    )
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
  register(c_slider_new(min, max), "moonui_native_slider_new")
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
/// 圆点跟手探针（`T150`）：把指针拖到滑块宽度的 `permille` 处，返回自绘圆点
/// 圆心与"指针能到的圆心"之差，单位百分之一点（0 = 圆点在指针底下）。
/// 契约在 adapter.h；两平台各写一份。
pub fn native_slider_knob_probe(
  h : @moonui.NativeHandle,
  permille : Int32,
) -> Int32 raise @moonui.UiError {
  c_slider_knob_probe(handles.resolve(h).0, permille).to_int()
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
  register(c_spinbox_new(min, max), "moonui_native_spinbox_new")
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
  register(c_progress_new(), "moonui_native_progress_new")
}

///|
pub fn native_combobox_new() -> @moonui.NativeHandle raise @moonui.UiError {
  register(c_combobox_new(), "moonui_native_combobox_new")
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
  register(c_radio_new(), "moonui_native_radio_new")
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
  register(c_multiline_new(), "moonui_native_multiline_new")
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
  register(c_datepicker_new(), "moonui_native_datepicker_new")
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
///（`T82` 删）同一招）。这只窗口的 Tab 遍历从此按链走（链尾回链头），不再跟 z-order。
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
//（`T82` 删）的同名函数逐字相同——分叉只在 C（这边 adapter_native.m 直写
// AppKit，libui 那侧的 adapter_macos.m 落到同一组系统调用），§47 的"分叉只到
// C 为止"在这里就是两份 MoonBit 的复制体。下面的注释只写本侧特有的那几句，
// 其余理由原在 libui 那份的注释里，随那份文件一并删了。
extern "c" fn c_clipboard_text() -> Bytes = "moonui_native_clipboard_text"

///|
#borrow(text)
extern "c" fn c_clipboard_set_text(text : Bytes, text_len : Int32) -> Int32 = "moonui_native_clipboard_set_text"

///|
#borrow(title, text)
extern "c" fn c_dialog_message(
  title : Bytes,
  title_len : Int32,
  text : Bytes,
  text_len : Int32,
) -> Int32 = "moonui_native_dialog_message"

///|
#borrow(title, text)
extern "c" fn c_dialog_confirm(
  title : Bytes,
  title_len : Int32,
  text : Bytes,
  text_len : Int32,
) -> Int32 = "moonui_native_dialog_confirm"

///|
#borrow(title)
extern "c" fn c_open_file(title : Bytes, title_len : Int32) -> Int32 = "moonui_native_open_file"

///|
#borrow(title, default_name)
extern "c" fn c_save_file(
  title : Bytes,
  title_len : Int32,
  default_name : Bytes,
  default_name_len : Int32,
) -> Int32 = "moonui_native_save_file"

///|
#borrow(title)
extern "c" fn c_select_folder(title : Bytes, title_len : Int32) -> Int32 = "moonui_native_select_folder"

///|
extern "c" fn c_file_dialog_path() -> Bytes = "moonui_native_file_dialog_path"

///|
/// 装整棵原生菜单。`tree` 是下面 `menu_tree` 打包出来的字节串（格式在 adapter.h），
/// 回调带一个 Core 的菜单项 id。
#borrow(tree)
extern "c" fn c_set_menu_bar(
  tree : Bytes,
  tree_len : Int32,
  call_closure : FuncRef[((Int32) -> Unit, Int32) -> Unit],
  closure : (Int32) -> Unit,
) -> Int32 = "moonui_native_set_menu_bar"

///|
extern "c" fn c_menu_item_set_checked(id : Int32, checked : Int32) -> Int32 = "moonui_native_menu_item_set_checked"

///|
/// 设置应用图标（§26）。`name` 是不带扩展名的 stem，平台各自补后缀。
#borrow(name)
extern "c" fn c_set_app_icon(name : Bytes, name_len : Int32) -> Int32 = "moonui_native_set_app_icon"

///|
extern "c" fn c_auto_dismiss_dialog(ms : Int32, index : Int32) -> Int32 = "moonui_native_auto_dismiss_dialog"

///|
#borrow(path)
extern "c" fn c_auto_answer_file_dialog(
  ms : Int32,
  path : Bytes,
  path_len : Int32,
  accept : Int32,
) -> Int32 = "moonui_native_auto_answer_file_dialog"

///|
extern "c" fn c_menu_click_item(id : Int32) -> Int32 = "moonui_native_menu_click_item"

///|
extern "c" fn c_menu_dump() -> Bytes = "moonui_native_menu_dump"

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
/// libui 那侧的 macos_test（`T82` 删）曾是一只钉子；现在本侧与 Windows 半的
/// native_test 各断言一次 dump，钉子全对同一张布局。
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
/// 原生菜单当下的快照，格式在 adapter.h 的 `moonui_native_menu_dump` 那一段。只给测试用。
/// 空串 = 还没装过菜单。
pub fn native_menu_dump() -> String {
  @utf8.decode_lossy(c_menu_dump())
}

// ---- worker 与跨线程投递（`T85①`）----

///|
/// worker 投递原语（`T85①`，契约见 adapter.h 的 worker 段注）：一个 extern 装两对
/// trampoline 闭包（可行性由 /tmp 探针与 tests/ffi 同形探针钉过）——work 对在
/// 平台线程执行，land 对在 UI 线程执行。返回 0 = 线程起了，-1 = 起不来。
extern "c" fn c_worker_run(
  work_call : FuncRef[(() -> Unit) -> Unit],
  work : () -> Unit,
  land_call : FuncRef[(() -> Unit) -> Unit],
  land : () -> Unit,
) -> Int32 = "moonui_native_worker_run"

///|
/// `T85①`：worker 与跨线程投递。`work` 在平台线程执行（**不许 raise**——异常跨
/// C 帧未定义，控件回调那几条同一条纪律；worker 侧失败由调用方在闭包内部兜住）；
/// `land` 在主循环泵消息时被投回 UI 线程，落地动作是 `app.post(land)`——外来
/// 投递经投递原语变成 UI 线程投递，§27 的队列依旧只被 UI 线程碰（§47 风险 3
/// 的收口），任务本体失败仍走既有语义（run_posted 的 raise 结束循环）。
pub fn[B] worker_run(
  app : @moonui.App[B],
  work : () -> Unit,
  land : () -> Unit raise @moonui.UiError,
) -> Unit raise @moonui.UiError {
  if c_worker_run(fn(f) { f() }, work, fn(f) { f() }, fn() { app.post(land) }) !=
    0 {
    raise @moonui.OperationFailed("worker 线程没能起跑")
  }
}

// ---- 输入法组合事件源（`T85②`）----

///|
/// 进程级组合监听（`T85②`，契约见 adapter.h 的 IME 段注）：通知不带内容，
/// 相位/target/组合串三样由通知后的读口当场取。
extern "c" fn c_on_ime(
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_on_ime"

///|
extern "c" fn c_ime_target() -> Int64 = "moonui_native_ime_target"

///|
extern "c" fn c_ime_phase() -> Int32 = "moonui_native_ime_phase"

///|
extern "c" fn c_ime_text() -> Bytes = "moonui_native_ime_text"

///|
/// 装进程级组合监听。0 = 装上了，-1 = 槽位用满。
pub fn native_on_ime(handler : () -> Unit) -> Unit raise @moonui.UiError {
  if c_on_ime(fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("原生组合事件源没能装上")
  }
}

///|
/// 组合当下的 target（我们的控件指针或 0）。
pub fn native_ime_target() -> Int64 {
  c_ime_target()
}

///|
/// 组合相位：0 = 开始、1 = 进行、2 = 结束（adapter.h 的编码）。
pub fn native_ime_phase() -> Int32 {
  c_ime_phase()
}

///|
/// 当下的组合串（UTF-8）。开始/结束通知是空串，进行通知是标记串。
pub fn native_ime_text() -> String {
  @utf8.decode_lossy(c_ime_text())
}

// ---- 窗口态（`T86②`）----

///|
extern "c" fn c_window_set_minimized(w : Int64, v : Int32) -> Unit = "moonui_native_window_set_minimized"

///|
extern "c" fn c_window_set_maximized(w : Int64, v : Int32) -> Unit = "moonui_native_window_set_maximized"

///|
extern "c" fn c_window_state(w : Int64) -> Int32 = "moonui_native_window_state"

///|
/// 最小化/最大化下发（`T86②`）。位运算照 §47 的那条规矩拆（MoonBit 侧
/// 用 % 与 / 不写位运算符，键盘那批立的）：bit0 = 最小化、bit1 = 最大化。
pub fn native_window_set_minimized(
  h : @moonui.NativeHandle,
  v : Bool,
) -> Unit raise @moonui.UiError {
  c_window_set_minimized(handles.resolve(h).0, bool_to_c(v))
}

///|
pub fn native_window_set_maximized(
  h : @moonui.NativeHandle,
  v : Bool,
) -> Unit raise @moonui.UiError {
  c_window_set_maximized(handles.resolve(h).0, bool_to_c(v))
}

///|
/// 读回当下的窗口态（`T86②`）："读当下态"而非推送式，持久化（`T86⑦`）问一次
/// 拿一份快照。原生层是唯一事实来源，Core 不缓存。
pub fn native_window_state(
  h : @moonui.NativeHandle,
) -> @moonui.WindowState raise @moonui.UiError {
  let bits = c_window_state(handles.resolve(h).0)
  @moonui.WindowState::{
    minimized: bits % 2 == 1,
    maximized: bits / 2 % 2 == 1,
  }
}

// ---- 控件级右键上下文菜单（`T86①`）----

///|
/// 弹上下文菜单（`T86①`）：树是 `menu_tree` 打包的同一棵（与 `set_menu_bar`
/// 共用打包/解析底座），展示在按下右键的控件上方、鼠标当下的位置；选中的
/// 解析发生在弹窗的同步嵌套循环内（落地注记见 trait 方法）。
#borrow(tree)
extern "c" fn c_show_context_menu(
  tree : Bytes,
  tree_len : Int32,
  call_closure : FuncRef[((Int32) -> Unit, Int32) -> Unit],
  closure : (Int32) -> Unit,
) -> Int32 = "moonui_native_show_context_menu"

///|
/// 弹一份上下文菜单（`T86①`）。`on_click` 在弹窗阻塞期间被选中项回调——
/// 勾选态改在 Core、回调当场跑（沿 `T22` 现账；回调里的异常由闭包内部兜住，
/// 异常跨 C 帧未定义）。返回码：0 = 弹过（用户选了或点了空白关掉）；
/// -1 = 树不合法；-2 = 没有可以弹菜单的窗口。
pub fn native_show_context_menu(
  bar : @moonui.MenuBar,
  on_click : (Int32) -> Unit,
) -> Unit raise @moonui.UiError {
  let tree = menu_tree(bar)
  match
    c_show_context_menu(tree, tree.length(), fn(f, id) { f(id) }, on_click) {
    0 => ()
    -1 =>
      raise @moonui.OperationFailed(
        "上下文菜单没弹出来：打包出来的树和 adapter.h 的布局对不上",
      )
    _ =>
      raise @moonui.OperationFailed(
        "没有可以弹出上下文菜单的窗口",
      )
  }
}

// ---- 文件拖入（`T86③` 第一期档案，mac 半）----

///|
/// 文件拖入监听（`T86③`）：进程一份，通知不带内容，target/paths 当场读回
/// （与键盘/组合监听同一条形状）。Windows 半欠 IDropTarget（欠账挂报告），
/// 那侧的实现返回 -1，装不上。
extern "c" fn c_on_file_drop(
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_on_file_drop"

///|
extern "c" fn c_file_drop_target() -> Int64 = "moonui_native_file_drop_target"

///|
extern "c" fn c_file_drop_paths() -> Bytes = "moonui_native_file_drop_paths"

///|
/// 装文件拖入监听（`T86③`）。0 = 装上了，-1 = 平台没接（Windows 半）。
pub fn native_on_file_drop(handler : () -> Unit) -> Unit raise @moonui.UiError {
  if c_on_file_drop(fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed(
      "文件拖入事件源没能装上（平台未接）",
    )
  }
}

///|
/// 从打包 bytes 里读小端 i32。长度不足按 0 处理（坏包顶多丢一条事件）。
fn packed_i32_at(b : Bytes, pos : Int32) -> Int32 {
  let mut v = 0
  for i = 0; i < 4; i = i + 1 {
    if pos + i < b.length() {
      v = v + b.at(pos + i).to_int() * (1 << (8 * i))
    }
  }
  v
}

///|
/// 接住拖入的那只窗口（我们的窗口指针或 0，MoonBit 侧据此丢弃）。
pub fn native_file_drop_target() -> Int64 {
  c_file_drop_target()
}

///|
/// 拖入的路径数组：打包布局 `i32 count, count × (i32 字节数, UTF-8 内容)`，
/// 顺序是平台层给的原样。坏包（长度对不上）就地截断——拖入一条坏事件不该
/// 挂掉循环。
pub fn native_file_drop_paths() -> Array[String] {
  let b = c_file_drop_paths()
  let out : Array[String] = []
  let len = b.length()
  let mut pos = 0
  if len >= 4 {
    let count = packed_i32_at(b, 0)
    pos = 4
    let mut i = 0
    while i < count {
      i = i + 1
      if pos + 4 > len {
        break
      }
      let n = packed_i32_at(b, pos)
      pos = pos + 4
      if n < 0 || pos + n > len {
        break
      }
      let buf = @buffer.Buffer()
      buf.write_bytes(b.clamped_view(start=pos, end=pos + n))
      out.push(@utf8.decode_lossy(buf.to_bytes()))
      pos = pos + n
    }
  }
  out
}

// ---- Image 控件与资源加载（`T86⑤`，解码归平台）----

///|
#borrow(path)
extern "c" fn c_image_set_path(
  c : Int64,
  path : Bytes,
  path_len : Int32,
) -> Int32 = "moonui_native_image_set_path"

///|
#borrow(data)
extern "c" fn c_image_set_data(
  c : Int64,
  data : Bytes,
  data_len : Int32,
) -> Int32 = "moonui_native_image_set_data"

///|
/// 按路径装图像源（`T86⑤`）。0 = 装上了；-1 = 解码失败（路径不存在或格式
/// 平台不认，§33 调用方错）；-2 = 句柄不指 Image 控件。
pub fn native_image_set_path(
  h : @moonui.NativeHandle,
  path : String,
) -> Unit raise @moonui.UiError {
  let p = utf8(path)
  match c_image_set_path(handles.resolve(h).0, p, p.length()) {
    0 => ()
    -1 =>
      raise @moonui.OperationFailed(
        "图像读不出来（路径不对或格式不受支持）：\{path}",
      )
    _ =>
      raise @moonui.OperationFailed(
        "图像源装不进去：句柄不指 Image 控件",
      )
  }
}

///|
/// 按字节装图像源（`T86⑤`）。返回码同上。
pub fn native_image_set_data(
  h : @moonui.NativeHandle,
  data : Bytes,
) -> Unit raise @moonui.UiError {
  match c_image_set_data(handles.resolve(h).0, data, data.length()) {
    0 => ()
    -1 =>
      raise @moonui.OperationFailed(
        "图像解码失败（数据不是平台认得的编码格式）",
      )
    _ =>
      raise @moonui.OperationFailed(
        "图像源装不进去：句柄不指 Image 控件",
      )
  }
}

///|
extern "c" fn c_image_probe(c : Int64) -> Int64 = "moonui_native_image_probe"

///|
/// 图像控件的探针（`T91⑤`）：`image_set_*` 的返回码只说"装上了"，这里问原生
/// 控件自己——装进去的是不是真位图、像素多大（打包见 adapter.h：低 8 位有没有
/// 图、8..23 位宽、24..39 位高）。-1 = 句柄不指 Image 控件。
pub fn native_image_probe(
  h : @moonui.NativeHandle,
) -> (Bool, Int32, Int32) raise @moonui.UiError {
  let bits = c_image_probe(handles.resolve(h).0)
  if bits < 0L {
    raise @moonui.OperationFailed("图像探针：句柄不指 Image 控件")
  }
  (
    bits % 2L == 1L,
    ((bits >> 8) % 65536L).to_int(),
    ((bits >> 32) % 65536L).to_int(),
  )
}

// ---- 系统托盘与通知（`T86⑥`）----

///|
#borrow(name)
extern "c" fn c_tray_set_icon(name : Bytes, name_len : Int32) -> Int32 = "moonui_native_tray_set_icon"

///|
/// 装托盘菜单（`T86⑥`）：树沿 `menu_tree` 同一套打包；选中的解析发生在
/// AppKit 自己的菜单追踪循环内（同 `T86①`），勾选态不回推原生（下一次装树
/// 照新快照画，落地注记）。
#borrow(tree)
extern "c" fn c_tray_set_menu(
  tree : Bytes,
  tree_len : Int32,
  call_closure : FuncRef[((Int32) -> Unit, Int32) -> Unit],
  closure : (Int32) -> Unit,
) -> Int32 = "moonui_native_tray_set_menu"

///|
#borrow(title, body)
extern "c" fn c_notify(
  title : Bytes,
  title_len : Int32,
  body : Bytes,
  body_len : Int32,
) -> Int32 = "moonui_native_notify"

///|
/// 托盘图标（`T86⑥`）。0 = 装上了；-1 = 图标文件读不出来；-2 = 还没初始化。
pub fn native_tray_set_icon(name : String) -> Unit raise @moonui.UiError {
  match c_tray_set_icon(utf8(name), name.length()) {
    0 => ()
    -1 =>
      raise @moonui.OperationFailed(
        "托盘图标文件读不出来（路径不对或格式不受支持）：\{name}",
      )
    _ =>
      raise @moonui.OperationFailed(
        "原生托盘还不存在（还没初始化）",
      )
  }
}

///|
/// 托盘菜单（`T86⑥`）。0 = 装上了；-1 = 树不合法；-2 = 还没初始化。
pub fn native_tray_set_menu(
  bar : @moonui.MenuBar,
  on_click : (Int32) -> Unit,
) -> Unit raise @moonui.UiError {
  let tree = menu_tree(bar)
  match c_tray_set_menu(tree, tree.length(), fn(f, id) { f(id) }, on_click) {
    0 => ()
    -1 =>
      raise @moonui.OperationFailed(
        "托盘菜单没装上：打包出来的树和 adapter.h 的布局对不上",
      )
    _ =>
      raise @moonui.OperationFailed(
        "原生托盘还不存在（还没初始化）",
      )
  }
}

///|
/// 系统通知（`T86⑥`）。0 = 投递请求交出去了（投递本身异步）；-1 = 文案没能
/// 交给系统；-2 = 还没初始化；-3 = 平台没接（无 bundle 的 CLI / 系统没有通知
/// 中心连接）。
pub fn native_notify(
  title : String,
  body : String,
) -> Unit raise @moonui.UiError {
  let t = utf8(title)
  let s = utf8(body)
  match c_notify(t, t.length(), s, s.length()) {
    0 => ()
    -1 => raise @moonui.OperationFailed("通知的文案没能交给系统")
    -3 =>
      raise @moonui.OperationFailed(
        "系统通知在这个进程形态下不可用（无 bundle）",
      )
    _ => raise @moonui.OperationFailed("通知中心还没初始化")
  }
}

///|
extern "c" fn c_tray_probe() -> Int64 = "moonui_native_tray_probe"

///|
/// 托盘探针（`T91⑥`）：托盘是进程级单例、不进句柄表，所以没有入参。返回
/// `(建起来了, 图标真装了, 菜单真挂了, 顶层菜单项数)`——读的都是原生对象自己
/// 的状态（打包见 adapter.h）。Windows 半的读回欠账同批（`T91⑥` 的 Win 侧）。
pub fn native_tray_probe() -> (Bool, Bool, Bool, Int32) {
  let bits = c_tray_probe()
  (
    bits % 2L == 1L,
    bits / 2L % 2L == 1L,
    bits / 4L % 2L == 1L,
    ((bits >> 8) % 65536L).to_int(),
  )
}

// ---- 进程级鼠标监听的 MoonBit 半（`T86①` 的右键事件源；ABI 在 adapter.h，
// `T39` 那批定的形状，`T82` 重链后 Windows 半的 C 一直在、mac 半本轮补右键那一支）----

///|
extern "c" fn c_on_mouse(
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_on_mouse"

///|
extern "c" fn c_mouse_target() -> Int64 = "moonui_native_mouse_target"

///|
/// 滚轮 target 改判用的第二本账（`T102` 第十二刀）：最近一次鼠标通知里
/// `hitTest` 算出的 owner 指针（0 = 空白或还没发生过事件）。与
/// `moonui_native_mouse_target` 的区别：target 恒是窗口（自绘半靠它认窗），
/// owner 才是真正被点中的控件。
extern "c" fn c_mouse_owner() -> Int64 = "moonui_native_mouse_owner"

///|
extern "c" fn c_mouse_kind_button() -> Int32 = "moonui_native_mouse_kind_button"

///|
extern "c" fn c_mouse_pos() -> Int64 = "moonui_native_mouse_pos"

///|
extern "c" fn c_mouse_delta() -> Int64 = "moonui_native_mouse_delta"

///|
/// 装进程级鼠标监听（`T39` 的契约）。0 = 装上了，-1 = 槽位用满或平台没挂上。
pub fn native_on_mouse(handler : () -> Unit) -> Unit raise @moonui.UiError {
  if c_on_mouse(fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("原生鼠标事件源没能装上")
  }
}

///|
/// 这次鼠标事件命中的那个"我们的控件"指针（adapter 反查出的 owner）或 0。
pub fn native_mouse_target() -> Int64 {
  c_mouse_target()
}

///|
/// 同一次事件的 **hitTest owner**（`T102` 第十二刀），0 = 空白或还没有事件。
/// Windows 半恒 0：那边的 target 本来就落在命中控件上，不需要第二本账。
pub fn native_mouse_owner() -> Int64 {
  c_mouse_owner()
}

///|
/// kind * 8 + button（adapter.h 的鼠标编码）。
pub fn native_mouse_kind_button() -> Int32 {
  c_mouse_kind_button()
}

///|
/// 客户区左上角为原点的物理像素，两个 int32 打包（高 32 位是 x）。
pub fn native_mouse_pos() -> (Int32, Int32) {
  unpack2(c_mouse_pos())
}

///|
/// 滚动增量，**逻辑像素**（C 已换算完，MoonBit 不许再除一次），两个 int32
/// 打包（高 32 位是 dx）。kind 不是 4 时是 (0, 0)。
pub fn native_mouse_delta() -> (Int32, Int32) {
  unpack2(c_mouse_delta())
}

// ---- 进程级触控板手势监听的 MoonBit 半（`T100`；ABI 在 adapter.h 手势段，
// 形状照鼠标段与键盘段：通知不带内容，四样当场读回——target / kind / phase /
// direction / value。手势量是小数，所以 value 那一格在 C 里定点成百万分之一，
// 这里除回来；其余三样都是小整数编码。----

///|
extern "c" fn c_on_gesture(
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_on_gesture"

///|
extern "c" fn c_gesture_target() -> Int64 = "moonui_native_gesture_target"

///|
extern "c" fn c_gesture_kind() -> Int32 = "moonui_native_gesture_kind"

///|
extern "c" fn c_gesture_phase() -> Int32 = "moonui_native_gesture_phase"

///|
extern "c" fn c_gesture_direction() -> Int32 = "moonui_native_gesture_direction"

///|
extern "c" fn c_gesture_value() -> Int64 = "moonui_native_gesture_value"

///|
/// 装进程级触控板手势监听（adapter.h 手势段注的契约）。0 = 装上了，
/// 非 0 = 平台没这套（Windows 恒 -1——`WM_GESTURE` 要 `SetGestureConfig`
/// 加逐窗口子类化，欠在那台机器上）。
pub fn native_on_gesture(handler : () -> Unit) -> Unit raise @moonui.UiError {
  if c_on_gesture(fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("原生手势事件源没能装上")
  }
}

///|
/// 这次手势命中的"我们的控件"指针（控件或窗口）或 0。
pub fn native_gesture_target() -> Int64 {
  c_gesture_target()
}

///|
/// 0 = 捏合、1 = 旋转、2 = 滑动。
pub fn native_gesture_kind() -> Int32 {
  c_gesture_kind()
}

///|
/// 0 = began、1 = changed、2 = ended、3 = cancelled。
pub fn native_gesture_phase() -> Int32 {
  c_gesture_phase()
}

///|
/// 0 = 左、1 = 右、2 = 上、3 = 下（只有滑动有意义）。
pub fn native_gesture_direction() -> Int32 {
  c_gesture_direction()
}

///|
/// 手势量：捏合是相对缩放增量、旋转是弧度。C 侧定点成百万分之一，
/// 这里除回来——除的是个整数，0.02 那一档回来仍是 0.02。
pub fn native_gesture_value() -> Double {
  c_gesture_value().to_double() / 1000000.0
}

// ---- 进程级键盘监听的 MoonBit 半（`T91` 移植；ABI 在 adapter.h 键盘段，
// `T39` 那批定的形状：通知不带内容，四样当场读回——target / is_down /
// modifiers / name。归属反查在 C 侧走焦点而不是坐标。----

///|
extern "c" fn c_on_key(
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_on_key"

///|
extern "c" fn c_key_target() -> Int64 = "moonui_native_key_target"

///|
extern "c" fn c_key_is_down() -> Int32 = "moonui_native_key_is_down"

///|
extern "c" fn c_key_modifiers() -> Int32 = "moonui_native_key_modifiers"

///|
extern "c" fn c_key_name() -> Bytes = "moonui_native_key_name"

///|
extern "c" fn c_focused_control(w : Int64) -> Int64 = "moonui_native_focused_control"

///|
/// 装进程级键盘监听（adapter.h 键盘段注的契约——mac 半在按下前先问主菜单
/// 认不认领，Shift+Tab 拦下退一步）。0 = 装上了，-1 = 槽位用满。
pub fn native_on_key(handler : () -> Unit) -> Unit raise @moonui.UiError {
  if c_on_key(fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("原生键盘事件源没能装上")
  }
}

///|
/// 这颗键归属的"我们的对象"指针（adapter 反查的 owner——焦点控件或我们的
/// 窗口）或 0。
pub fn native_key_target() -> Int64 {
  c_key_target()
}

///|
/// 1 = 按下，0 = 抬起。
pub fn native_key_is_down() -> Bool {
  c_key_is_down() != 0
}

///|
/// 修饰键位：bit0 ctrl、bit1 alt、bit2 shift、bit3 meta（adapter.h 的编码；
/// mac 的 ⌘ 是 meta、物理 Ctrl 才是 ctrl——Core 的 Shortcut 同一张表）。
pub fn native_key_modifiers() -> Int32 {
  c_key_modifiers()
}

///|
/// 键名（UTF-8，adapter.h 的词表）；空串 = 这颗键不在词表里，不该产事件。
pub fn native_key_name() -> String {
  @utf8.decode_lossy(c_key_name())
}

///|
/// 这只窗口当下把焦点给了哪个"我们的控件"（§32 的"问而不报"）；0 = 焦点
/// 不在我们的控件上（在窗口自己、或原生对象我们没记过）。句柄已失效（窗口
/// 销毁后）返回 0。
pub fn native_focused_control(w : @moonui.NativeHandle) -> Int64 {
  let ptr = handles.resolve(w) catch { _ => @moonui.NativePtr(0L) }
  c_focused_control(ptr.0)
}

///|
/// ---- 音频 ABI（lunamusic 第一期，adapter.h 音频段）----
/// 这层只把 moonui_native_audio_* 映成 MoonBit 形状：错误码由壳的适配层
/// （NativeAudioEngine）翻成 lunamusic 的 AudioError，这里不做第二套解释。

///|
#borrow(path)
extern "c" fn c_audio_load(path : Bytes, path_len : Int32) -> Int32 = "moonui_native_audio_load"

///|
extern "c" fn c_audio_play() -> Int32 = "moonui_native_audio_play"

///|
extern "c" fn c_audio_pause() -> Int32 = "moonui_native_audio_pause"

///|
extern "c" fn c_audio_stop() -> Int32 = "moonui_native_audio_stop"

///|
extern "c" fn c_audio_position_ms() -> Int64 = "moonui_native_audio_position_ms"

///|
extern "c" fn c_audio_duration_ms() -> Int64 = "moonui_native_audio_duration_ms"

///|
extern "c" fn c_audio_seek_ms(ms : Int64) -> Int32 = "moonui_native_audio_seek_ms"

///|
extern "c" fn c_audio_set_volume(permille : Int32) -> Int32 = "moonui_native_audio_set_volume"

///|
extern "c" fn c_audio_is_playing() -> Int32 = "moonui_native_audio_is_playing"

///|
extern "c" fn c_audio_on_finished(
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "moonui_native_audio_on_finished"

///|
extern "c" fn c_audio_clear_on_finished() -> Int32 = "moonui_native_audio_clear_on_finished"

///|
#borrow(path)
extern "c" fn c_audio_probe(path : Bytes, path_len : Int32) -> Bytes = "moonui_native_audio_probe"

///|
/// 装歌：0 成功；-1 参数残缺；-2 底层失败（文件打不开/解不了码）。
pub fn native_audio_load(path : String) -> Int32 {
  let bytes = @utf8.encode(path)
  c_audio_load(bytes, bytes.length())
}

///|
pub fn native_audio_play() -> Int32 {
  c_audio_play()
}

///|
pub fn native_audio_pause() -> Int32 {
  c_audio_pause()
}

///|
pub fn native_audio_stop() -> Int32 {
  c_audio_stop()
}

///|
pub fn native_audio_position_ms() -> Int64 {
  c_audio_position_ms()
}

///|
pub fn native_audio_duration_ms() -> Int64 {
  c_audio_duration_ms()
}

///|
pub fn native_audio_seek_ms(ms : Int64) -> Int32 {
  c_audio_seek_ms(ms)
}

///|
pub fn native_audio_set_volume(permille : Int32) -> Int32 {
  c_audio_set_volume(permille)
}

///|
pub fn native_audio_is_playing() -> Bool {
  c_audio_is_playing() != 0
}

///|
/// 播完回调：传 Some(cb) 装/换（旧闭包由 C 侧 decref），传 None 撤。
pub fn native_audio_on_finished(cb : (() -> Unit)?) -> Int32 {
  match cb {
    Some(f) => c_audio_on_finished(fn(g) { g() }, f)
    None => c_audio_clear_on_finished()
  }
}

///|
/// 元数据探针：读不出（C 侧 NULL）返回 None；读出返回打包字节
/// （布局见 adapter.h 音频段：title/artist/album/duration_ms/cover）。
pub fn native_audio_probe(path : String) -> Bytes? {
  let bytes = @utf8.encode(path)
  let packed = c_audio_probe(bytes, bytes.length())
  if packed.length() == 0 {
    None
  } else {
    Some(packed)
  }
}

///|
extern "c" fn c_audio_level(band : Int32) -> Int32 = "moonui_native_audio_level"

///|
extern "c" fn c_audio_eq_band_count() -> Int32 = "moonui_native_audio_eq_band_count"

///|
extern "c" fn c_audio_eq_set_band(band : Int32, gain_mdb : Int32) -> Int32 = "moonui_native_audio_eq_set_band"

///|
extern "c" fn c_audio_eq_band_gain(band : Int32) -> Int32 = "moonui_native_audio_eq_band_gain"

///|
extern "c" fn c_audio_eq_set_enabled(on : Int32) -> Int32 = "moonui_native_audio_eq_set_enabled"

///|
extern "c" fn c_audio_eq_enabled() -> Int32 = "moonui_native_audio_eq_enabled"

///|
/// 频谱第 band 段的能量（0..1000 千分位）。没在播/未实现都是 0。
pub fn native_audio_level(band : Int32) -> Int32 {
  c_audio_level(band)
}

///|
/// 均衡器段数：0 = 本平台没有 EQ（Windows 半），UI 侧据此不画假滑块。
pub fn native_audio_eq_band_count() -> Int32 {
  c_audio_eq_band_count()
}

///|
/// 设第 band 段的增益（milli-dB，±12000 = ±12dB）。
pub fn native_audio_eq_set_band(band : Int32, gain_mdb : Int32) -> Int32 {
  c_audio_eq_set_band(band, gain_mdb)
}

///|
/// 读回第 band 段的增益（milli-dB）。
pub fn native_audio_eq_band_gain(band : Int32) -> Int32 {
  c_audio_eq_band_gain(band)
}

///|
/// 均衡器旁路开关：on=true 走 EQ，false 直通。
pub fn native_audio_eq_set_enabled(on : Bool) -> Int32 {
  c_audio_eq_set_enabled(if on { 1 } else { 0 })
}

///|
/// 均衡器是否在链路上。
pub fn native_audio_eq_enabled() -> Bool {
  c_audio_eq_enabled() != 0
}

///|
#borrow(path)
extern "c" fn c_walk_dir(path : Bytes, path_len : Int32) -> Bytes = "moonui_native_walk_dir"

///|
/// 列一个目录的直接子项（绝对路径数组，含文件与子目录）；打不开/空返回
/// 空数组。打包布局见 adapter.h 走行段：[int32 count] + count 个 [int32 len][字节]。
///
/// 解码那一半在 `@native-abi.decode_walk_packet`（`T143`）：它零 C、零 FFI，
/// 于是"打包坏了怎么办"那串逐项隔离逻辑有无头判据。这里只留 C 调用。
pub fn native_walk_dir(path : String) -> Array[String] {
  let bytes = @utf8.encode(path)
  @native-abi.decode_walk_packet(c_walk_dir(bytes, bytes.length()))
}
