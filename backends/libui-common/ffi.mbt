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
extern "c" fn c_window_screen_origin(w : Int64) -> Int64 = "moonui_window_screen_origin"

///|
extern "c" fn c_window_screen_size(w : Int64) -> Int64 = "moonui_window_screen_size"

///|
extern "c" fn c_system_theme() -> Int = "moonui_system_theme"

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
extern "c" fn c_widget_on_text_changed(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int = "moonui_widget_on_text_changed"

///|
extern "c" fn c_widget_on_toggled(
  c : Int64,
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int = "moonui_widget_on_toggled"

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
extern "c" fn c_clipboard_text() -> Bytes = "moonui_clipboard_text"

///|
#borrow(text)
extern "c" fn c_clipboard_set_text(text : Bytes, text_len : Int) -> Int = "moonui_clipboard_set_text"

///|
#borrow(title, text)
extern "c" fn c_dialog_message(
  title : Bytes,
  title_len : Int,
  text : Bytes,
  text_len : Int,
) -> Int = "moonui_dialog_message"

///|
#borrow(title, text)
extern "c" fn c_dialog_confirm(
  title : Bytes,
  title_len : Int,
  text : Bytes,
  text_len : Int,
) -> Int = "moonui_dialog_confirm"

///|
#borrow(title)
extern "c" fn c_open_file(title : Bytes, title_len : Int) -> Int = "moonui_open_file"

///|
#borrow(title, default_name)
extern "c" fn c_save_file(
  title : Bytes,
  title_len : Int,
  default_name : Bytes,
  default_name_len : Int,
) -> Int = "moonui_save_file"

///|
#borrow(title)
extern "c" fn c_select_folder(title : Bytes, title_len : Int) -> Int = "moonui_select_folder"

///|
extern "c" fn c_file_dialog_path() -> Bytes = "moonui_file_dialog_path"

///|
/// 装整棵原生菜单。`tree` 是下面 `menu_tree` 打包出来的字节串（格式在 adapter.h），
/// 回调带一个 Core 的菜单项 id。
#borrow(tree)
extern "c" fn c_set_menu_bar(
  tree : Bytes,
  tree_len : Int,
  call_closure : FuncRef[((Int) -> Unit, Int) -> Unit],
  closure : (Int) -> Unit,
) -> Int = "moonui_set_menu_bar"

///|
extern "c" fn c_menu_item_set_checked(id : Int, checked : Int) -> Int = "moonui_menu_item_set_checked"

///|
/// 装那份进程级的键盘监听（§10/§26）。整个进程只挂一份，重复调用只换闭包。
extern "c" fn c_on_key(
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int = "moonui_on_key"

///|
/// 下面四条是刚通知过的那颗键的快照，只在回调里读才有意义（§48-16：通知不带内容）。
/// `c_key_target` 给的是原生对象的裸地址，要经 `find_alive` 才能变成句柄。
extern "c" fn c_key_target() -> Int64 = "moonui_key_target"

///|
extern "c" fn c_key_is_down() -> Int = "moonui_key_is_down"

///|
extern "c" fn c_key_modifiers() -> Int = "moonui_key_modifiers"

///|
extern "c" fn c_key_name() -> Bytes = "moonui_key_name"

///|
/// 这只窗口当下把焦点给了哪个我们的控件（§32）。0 = 没有；裸地址同样要经 `find_alive`。
extern "c" fn c_focused_control(w : Int64) -> Int64 = "moonui_focused_control"

///|
/// 装那份进程级鼠标监听（§10 的鼠标五变体，`T39` 的鼠标那半）。和 `c_on_key` 同一个
/// 形状，也因此同样只占一格槽位：命中靠坐标反查，不给每只控件挂监听。
extern "c" fn c_on_mouse(
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int = "moonui_on_mouse"

///|
/// 下面四条是刚通知过的那次鼠标动作的快照（§48-16：通知不带内容）。
/// target 是命中控件的裸地址，落在空白处或原生辅助对象上是 0，要经 `find_alive`。
extern "c" fn c_mouse_target() -> Int64 = "moonui_mouse_target"

///|
/// `kind * 8 + button`（kind 0 按下 / 1 抬起 / 2 移动或拖拽 / 3 双击 / 4 滚轮，
/// button 0..4 与 `@moonui.MouseButton` 的声明顺序同源）。拆在 `backend.mbt` 里做，
/// 和 `c_key_modifiers` 那一位同一个位置。
extern "c" fn c_mouse_kind_button() -> Int = "moonui_mouse_kind_button"

///|
/// 命中的点：客户区左上角为原点、y 向下的**物理像素**，两个 int32 打包（高 32 位 x）。
extern "c" fn c_mouse_pos() -> Int64 = "moonui_mouse_pos"

///|
/// 滚动增量。注意这一条和上面一条的口径不一样：C 侧**已经**换算成逻辑像素了
/// （用的那几个数——自然滚动旗标、每行像素数——只在各自平台存在，见 adapter.h），
/// 所以这里一次也不除 Scale。`kind` 不是 4 时是 0。
extern "c" fn c_mouse_delta() -> Int64 = "moonui_mouse_delta"

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
#borrow(title, text)
extern "c" fn c_type_text_in_window(
  title : Bytes,
  title_len : Int,
  x : Int,
  y : Int,
  text : Bytes,
  text_len : Int,
) -> Int = "moonui_type_text_in_window"

///|
extern "c" fn c_auto_dismiss_dialog(ms : Int, index : Int) -> Int = "moonui_auto_dismiss_dialog"

///|
#borrow(path)
extern "c" fn c_auto_answer_file_dialog(
  ms : Int,
  path : Bytes,
  path_len : Int,
  accept : Int,
) -> Int = "moonui_auto_answer_file_dialog"

///|
extern "c" fn c_menu_click_item(id : Int) -> Int = "moonui_menu_click_item"

///|
extern "c" fn c_menu_dump() -> Bytes = "moonui_menu_dump"

///|
/// 等价于"用户在当下有焦点的控件上按了（或抬起了）一颗键"。只给测试用。
#borrow(title, key)
extern "c" fn c_send_key_in_window(
  title : Bytes,
  title_len : Int,
  key : Bytes,
  key_len : Int,
  mods : Int,
  down : Int,
) -> Int = "moonui_send_key_in_window"

///|
/// 等价于"用户把焦点挪到客户区 (x, y) 处那个控件上"。只给测试用。
#borrow(title)
extern "c" fn c_focus_widget_in_window(
  title : Bytes,
  title_len : Int,
  x : Int,
  y : Int,
) -> Int = "moonui_focus_widget_in_window"

///|
/// 等价于"用户在客户区 (x, y) 给出一次鼠标动作"。只给测试用。
/// dx/dy 是给 Core 看的那两个逻辑像素（非滚轮时 0）——C 内部会按同一个自然滚动旗标把
/// 它们反向送成原生事件，往返自逆，钉住的是"换算只做一次"，见 adapter.h。
#borrow(title)
extern "c" fn c_send_mouse_in_window(
  title : Bytes,
  title_len : Int,
  kind_button : Int,
  x : Int,
  y : Int,
  dx : Int,
  dy : Int,
) -> Int = "moonui_send_mouse_in_window"

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
/// 菜单树打包：字符串写成"i32 字节数 + UTF-8 内容、不带 NUL"（§29 的进 C 形态）。
fn menu_put_str(buf : @buffer.Buffer, s : String) -> Unit {
  let b = utf8(s)
  buf.write_int_le(b.length())
  buf.write_bytes(b)
}

///|
fn menu_put_byte(buf : @buffer.Buffer, v : Int) -> Unit {
  buf.write_byte(v.to_byte())
}

///|
fn menu_put_bool(buf : @buffer.Buffer, v : Bool) -> Unit {
  menu_put_byte(buf, bool_to_c(v))
}

///|
fn menu_role_byte(role : @moonui.MenuRole) -> Int {
  match role {
    @moonui.Normal => 0
    @moonui.Check => 1
    @moonui.Radio => 2
  }
}

///|
/// 修饰键压成一个字节：bit0 ctrl、bit1 alt、bit2 shift、bit3 meta（adapter.h）。
fn menu_mods_byte(sc : @moonui.Shortcut) -> Int {
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
/// macos_test 与 Win32 那份测试各断言一次 dump，就是这条布局的钉子。
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
/// 这只窗口**当下所在那块屏**的工作区左上角，物理像素。坐标空间和
/// `native_window_position` / `native_window_set_position` 同一个（否则读回来的矩形
/// 摆不回去），而这个空间两个平台本身不同——理由与兜底写在 `adapter.h` 那一节（`T42`）。
pub fn native_window_screen_origin(
  h : @moonui.NativeHandle,
) -> (Int, Int) raise @moonui.UiError {
  unpack2(c_window_screen_origin(handles.resolve(h).0))
}

///|
/// 同上，工作区的宽高，物理像素。
pub fn native_window_screen_size(
  h : @moonui.NativeHandle,
) -> (Int, Int) raise @moonui.UiError {
  unpack2(c_window_screen_size(handles.resolve(h).0))
}

///|
/// 系统外观是不是深色（§16）。两侧读的是"这个进程现在按哪套画"：mac 读
/// `NSApp.effectiveAppearance`，Windows 读注册表的 `AppsUseLightTheme`。读不到就当
/// 浅色，不报错——理由写在 adapter.h 那一节：老系统上根本没有这个值，把它变成
/// raise 只会让 `App::palette` 在能跑的机器上先炸掉。
pub fn native_system_theme_is_dark() -> Bool {
  c_system_theme() != 0
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
/// 注册"输入框里的字被改了"。回调不带文字：C 侧只报"出事了"，全文由
/// `native_widget_text` 回读（`Input` 事件要携带变化后的全文，§10）。
pub fn native_widget_on_text_changed(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_widget_on_text_changed(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("libui 文本变化回调槽位已用满")
  }
}

///|
/// 注册"勾选框被点了一下"。同样不带状态，勾选态由 `native_widget_checked` 回读。
pub fn native_widget_on_toggled(
  h : @moonui.NativeHandle,
  handler : () -> Unit,
) -> Unit raise @moonui.UiError {
  let ptr = handles.resolve(h)
  if c_widget_on_toggled(ptr.0, fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("libui 勾选回调槽位已用满")
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
/// 读文本剪贴板（§23）。空 bytes = 现在读不到文本（剪贴板空着、内容是图片之类、
/// 或暂时打不开），统一成 `None`；读路径没有错误码，理由写在 adapter.h 的剪贴板段。
pub fn native_clipboard_text() -> String? {
  let b = c_clipboard_text()
  if b.length() == 0 {
    None
  } else {
    Some(@utf8.decode_lossy(b))
  }
}

///|
/// 写文本剪贴板。C 的两个失败码一个"拿不到"、一个"拿住了没写成"，都变成带原因的
/// `OperationFailed`（§33）：复制没成功却报"已复制"，是用户最难自己发现的那类错。
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
/// 弹一只只带"确定"的消息框（§24）。同步阻塞到用户把它关掉为止，所以只应在
/// 事件循环里调用。C 的两个负数码都是真失败，变成 `OperationFailed`（§33）：
/// 一句"已提示"用户看不见，只有对话框没出现才知道什么都没发生。
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
/// 弹一只"是/否"确认框，`true` = 用户选了"是"（§24）。
/// 0 是"用户没同意"（选了"否"、或者按 ESC 关掉），它和负数的"弹都没弹出来"是两条
/// 不同的路：前者是答案，后者是故障。契约在 `packages/moonui/dialog.mbt`。
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
/// 取走刚选中的路径（adapter.h 的取走语义：C 的返回码和路径分两次调用，因为 FFI
/// 单返回值；结果只在返回 1 之后存在）。空 bytes 在正常路径下取不到，真出现时当
/// `None`——和"用户取消"同形，测试会在断言上把这种坏状态红出来。
fn file_dialog_result() -> String? {
  let b = c_file_dialog_path()
  if b.length() == 0 {
    None
  } else {
    Some(@utf8.decode_lossy(b))
  }
}

///|
/// 打开文件面板（§24）。`Some(path)` = 用户选了；`None` = 用户取消；真失败 `raise`
/// （文案没能交给系统 / 面板没弹出来）——取消和失败是两条不同的路，理由同
/// `native_dialog_confirm`。同步阻塞到用户答完为止，只应在事件循环里调用。
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
/// 由 `LibuiBackend` 把它变成 `MenuSelect` 事件。
/// C 的两个负数码含义不同但都是真失败（§33）：-1 是这棵树它读不懂，也就是上面的
/// 打包和 adapter.h 的布局对不上——那属于我们自己的 bug，不许当成"没菜单"咽下去。
pub fn native_set_menu_bar(
  bar : @moonui.MenuBar,
  on_click : (Int) -> Unit,
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
/// 把 Core 改掉的勾选态推给当下那棵原生菜单（§25 / §48-20）。
/// Radio 整组一起推是 `App::click_menu_item` 的事，这里只报一项。
/// 报 -1 必须变成错误而不是静悄悄什么都不做：那正是"点了没反应"这一类最难查的形态。
/// 文案和 `MockBackend` 的同名实现一致，headless 与真窗口两侧钉的是同一句话。
pub fn native_menu_item_set_checked(
  id : Int,
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
/// 裸地址 → 句柄的反查（§48-16 在键盘和焦点上的那一步）：后端在"焦点不落在我们的控件
/// 上"时给的是一个没登记过的地址（原生层的辅助对象、或窗口自己），所以认不出是常态，
/// 返回 `None` 而不是报错。
fn find_alive(addr : Int64) -> @moonui.NativeHandle? {
  handles.find_alive(@moonui.NativePtr(addr))
}

///|
/// 装那份进程级的键盘监听（§10/§26，`T39`）。整个进程只挂一份，重复调用只换闭包，
/// 所以这里只在 `init` 里调一次。
///
/// 回调不带任何内容：它只说"有颗键出事了"，内容要用下面四条当场读回去（§48-16 那条
/// "通知不带内容"的约定，和控件的文字/勾选态同一个形状）。
pub fn native_on_key(handler : () -> Unit) -> Unit raise @moonui.UiError {
  if c_on_key(fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("libui 回调槽位已用满")
  }
}

///|
/// 刚通知过的那颗键属于谁：焦点在我们的控件上时是那个控件，否则是事件所在窗口自己。
/// `None` = 这颗键不属于本框架，调用方据此丢弃（后端不猜"那应该是主窗口吧"）。
pub fn native_key_target() -> @moonui.NativeHandle? {
  find_alive(c_key_target())
}

///|
/// 刚通知过的那颗键是按下还是抬起。
pub fn native_key_is_down() -> Bool {
  c_key_is_down() != 0
}

///|
/// 刚通知过的那颗键的修饰键位：bit0 ctrl、bit1 alt、bit2 shift、bit3 meta，和上面
/// `menu_mods_byte` 装进菜单的那一套同一个编码（§25/§26 的"显示与派发同源"）。
pub fn native_key_modifiers() -> Int {
  c_key_modifiers()
}

///|
/// 刚通知过的那颗键的键名，用 Core 那套词（event.mbt）。空串 = 这颗键不在词表里
/// （修饰键自己、输入法、媒体键），不该产事件。
pub fn native_key_name() -> String {
  @utf8.decode_lossy(c_key_name())
}

///|
/// 这只窗口当下把焦点给了哪个我们的控件（§32）。`None` = 焦点在窗口自己或在原生层的
/// 辅助对象上。没有回调：两边都没有一个既及时又不侵入的"焦点变了"来源，所以由
/// `LibuiBackend` 每圈事件循环问一次（见 backend.mbt 的 `refresh_focus`）。
pub fn native_focused_control(
  h : @moonui.NativeHandle,
) -> @moonui.NativeHandle? raise @moonui.UiError {
  find_alive(c_focused_control(handles.resolve(h).0))
}

///|
/// 装那份进程级鼠标监听（`T39` 的鼠标那半）：和键盘同一形状——整个进程一份、只在
/// `init` 里调一次、通知不带内容，四样（谁/kind+button/点/增量）用下面四条当场读回。
/// 槽位因此不随控件数增长：命中是坐标反查出来的，不给每只控件挂监听。
pub fn native_on_mouse(handler : () -> Unit) -> Unit raise @moonui.UiError {
  if c_on_mouse(fn(f) { f() }, handler) != 0 {
    raise @moonui.OperationFailed("libui 回调槽位已用满")
  }
}

///|
/// 刚通知过的那次鼠标动作命中了谁。`None` = 落在空白处、libui 的辅助 view，
/// 或者那个原生对象没登记过；调用方据此丢弃整条事件（不猜"那应该是窗口自己吧"——
/// Core 现在没有任何一处消费落在空白处的鼠标事件，§32 的 focused 由点击驱动是 `T41`）。
pub fn native_mouse_target() -> @moonui.NativeHandle? {
  find_alive(c_mouse_target())
}

///|
/// 刚通知过的那次动作的 `kind * 8 + button`，原样交给 `backend.mbt` 拆——和
/// `native_key_modifiers` 同一个位置，编码只有一份解释它的代码。
pub fn native_mouse_kind_button() -> Int {
  c_mouse_kind_button()
}

///|
/// 刚通知过的那个点，**物理像素**（客户区左上角为原点、y 向下），拆成 (x, y)。
/// 除以 Scale 是调用方的事，除的是命中那只控件的 Scale（§30 唯一的那一处换算）。
pub fn native_mouse_pos() -> (Int, Int) {
  unpack2(c_mouse_pos())
}

///|
/// 刚通知过的那次滚动的增量，**已经是逻辑像素**（C 侧换算完，理由见 adapter.h），
/// 拆成 (dx, dy)。这一条别跟着上一条再除一次 Scale。
pub fn native_mouse_delta() -> (Int, Int) {
  unpack2(c_mouse_delta())
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

///|
/// 等价于"用户在窗口客户区 (x, y) 的输入框里敲了一段字"。只给测试用。
/// 两个平台各自走的是真人那条路（Win32 逐字符 WM_CHAR，macOS 让 field editor
/// insertText:），不是直接 setStringValue:/EM_REPLACESEL——所以libui 自己
/// 那条"程序改文本要不要回声"的分歧会被量出来，而不是被绕开。
/// 返回 0 表示已送达；-1 编码失败，-2 找不到窗口，-3 命不中控件，
/// -4 命中的不是输入框，-5 命中的是只读框或拿不到 field editor。
pub fn native_type_text_in_window(
  title : String,
  x : Int,
  y : Int,
  text : String,
) -> Int {
  let t = utf8(title)
  let s = utf8(text)
  c_type_text_in_window(t, t.length(), x, y, s, s.length())
}

///|
/// 等价于"用户在 ms 毫秒之后按下下一个对话框的第 index 个按钮"（0 = 确定／是，
/// 1 = 否）。只给测试用：对话框是同步阻塞的，不在调用之前把"用户会按哪个"安排好，
/// 调用方就永远回不来。装的这发由下一个对话框认领，一次性的。
/// 返回 0 = 已装好，-1 = index 越界（这条 ABI 只有 1 只和 2 只按钮两种形态）。
pub fn native_auto_dismiss_dialog(ms : Int, index : Int) -> Int {
  c_auto_dismiss_dialog(ms, index)
}

///|
/// 等价于"用户在 ms 毫秒之后对下一个文件面板按 接受（面板已经停在 path 上）/ 取消
/// （`accept` = false，此时 path 传空串）"。只给测试用：文件面板和对话框一样同步
/// 阻塞。装的这发由下一个文件面板认领，一次性的。
/// 返回 0 = 已装好，-1 = 接受但 path 为空（这条 ABI 见 adapter.h）。
pub fn native_auto_answer_file_dialog(
  ms : Int,
  path : String,
  accept : Bool,
) -> Int {
  let p = utf8(path)
  c_auto_answer_file_dialog(ms, p, p.length(), if accept { 1 } else { 0 })
}

///|
/// 等价于"用户在原生菜单里点了 id 这一项"（mac 的 `performActionForItemAtIndex:` /
/// Windows 的 `WM_COMMAND`）。只给测试用：真实点击由原生菜单自己报回来。
/// 0 = 已派发（回调在本次调用里已经跑过），-1 = 这棵菜单里没这个 id，
/// -2 = 有这一项但它是禁用的、什么都没发生（adapter.h 把两边对齐到同一套码）。
pub fn native_menu_click_item(id : Int) -> Int {
  c_menu_click_item(id)
}

///|
/// 原生菜单当下的快照，格式在 adapter.h 的 `moonui_menu_dump` 那一段。只给测试用：
/// §25 的状态以 Core 为准，产品路径不读回。空串 = 还没装过菜单。
pub fn native_menu_dump() -> String {
  @utf8.decode_lossy(c_menu_dump())
}

///|
/// 等价于"用户在当下有焦点的那个控件上按了（或抬起了）一颗键"。只给测试用：真按键由
/// 原生键盘源自己报回来。mac 造的是一条真 NSEvent 交给 `sendEvent:`，Windows 往有焦点的
/// HWND `PostMessage` 一条 WM_KEYDOWN/WM_KEYUP，两边都不是"把回调调一遍"。
/// 0 = 已派发（回调在本次调用里已经跑过），-1 编码失败，-2 找不到窗口，
/// -3 这只窗口里没有我们的控件拿着焦点，-4 键不在词表里。
pub fn native_send_key_in_window(
  title : String,
  key : String,
  mods : Int,
  down : Bool,
) -> Int {
  let t = utf8(title)
  let k = utf8(key)
  c_send_key_in_window(t, t.length(), k, k.length(), mods, bool_to_c(down))
}

///|
/// 等价于"用户把焦点挪到客户区 (x, y) 处那个控件上"。只给测试用：按坐标命中而不是
/// "取第几只控件"，理由和 `native_click_button_in_window` 一样，布局摆错了这里就命不中。
/// 0 = 焦点已给出去，-1 编码失败，-2 找不到窗口，-3 命不中子控件，-4 命中了但焦点没落到
/// 我们的控件上（空白处，或原生不肯给：Windows 的禁用控件走这一档）。
pub fn native_focus_widget_in_window(title : String, x : Int, y : Int) -> Int {
  let t = utf8(title)
  c_focus_widget_in_window(t, t.length(), x, y)
}

///|
/// 等价于"用户在窗口客户区 (x, y) 给出一次鼠标动作"。只给测试用：按坐标命中而不是
/// "取第几只控件"，理由和 `native_click_button_in_window` 一样——布局摆错了这里就命不中。
/// `kind`/`button` 在这里打包成 ABI 的那一个数（编码见 adapter.h），`dx`/`dy` 是这条
/// 动作希望 Core 读到的逻辑像素滚动增量（不是滚轮时给 0）。
///
/// 返回 0 = 事件真被那份监听认领了；-1 = 标题编码失败、原生造不出事件、或者造出来
/// 没被认领；-2 找不到窗口，-3 命不中原生 view，-4 命中的不是我们的控件，
/// -5 编码越界。
pub fn native_send_mouse_in_window(
  title : String,
  kind : Int,
  button : Int,
  x : Int,
  y : Int,
  dx : Int,
  dy : Int,
) -> Int {
  let t = utf8(title)
  c_send_mouse_in_window(t, t.length(), kind * 8 + button, x, y, dx, dy)
}
