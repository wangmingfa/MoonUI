/// T103 的 mac 测试脚手架（真窗测试的投递与探针）：extern 直指
/// adapter_native.m 尾段的四条入口，C 侧契约在 adapter.h 脚手架段——
/// send_key 造真 NSEvent 走 sendEvent:（键监听、菜单认领、T96②③ 的
/// 吞键状态机全被真跑）、click 造一对真按下/抬起、type_text 走
/// makeFirstResponder + 共享 field editor、focus 回读判据。坐标口径
/// 全部收 MoonUI 的（客户区左上原点、物理像素），换算在 C 里做。
///
/// 只在本包的 native 测试二进制里用（moon.pkg 的 targets 把本文件钉在
/// native；wasm 路径上没有 Cocoa）。名字与 adapter.h 脚手架段逐字一致（那
/// 是两平台的共同契约，Windows 半的同名四条住在 adapter_native.c）；返回码
/// 也照那一套：-3 只给"真命不中"（点在窗口外），窗口里的空白处归 -4。

///|
#borrow(title, key)
extern "c" fn c_send_key_in_window(
  title : Bytes,
  title_len : Int32,
  key : Bytes,
  key_len : Int32,
  mods : Int32,
  down : Int32,
) -> Int32 = "moonui_native_send_key_in_window"

///|
#borrow(title)
extern "c" fn c_click_button_in_window(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int32 = "moonui_native_click_button_in_window"

///|
#borrow(title, text)
extern "c" fn c_type_text_in_window(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
  text : Bytes,
  text_len : Int32,
) -> Int32 = "moonui_native_type_text_in_window"

///|
#borrow(title)
extern "c" fn c_focus_widget_in_window(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int32 = "moonui_native_focus_widget_in_window"

///|
/// 等价于"用户在标题匹配的窗口里按下/抬起了这颗键"（同步派发，返回即
/// 真跑完）。mods 是 adapter.h 的四位打包（bit0 ctrl / 1 alt / 2 shift /
/// 3 meta）；返回码：0 = 已派发，-1 编码失败，-2 找不到窗口，-3 焦点不在
/// 我们的控件上（先 focus_widget_in_window），-4 键不在词表里。
pub fn send_key_in_window(
  title : String,
  key : String,
  mods : Int32,
  down : Bool,
) -> Int32 {
  let t = @utf8.encode(title)
  let k = @utf8.encode(key)
  c_send_key_in_window(
    t,
    t.length(),
    k,
    k.length(),
    mods,
    if down {
      1
    } else {
      0
    },
  )
}

///|
/// 等价于"用户在 (x, y) 按了一下鼠标"（MoonUI 坐标口径，见文件头）。
/// 返回码：0 = 已派发，-2 找不到窗口，-3 点在窗口外，-4 命中的不是按钮
/// （窗口空白处与 label/输入框都归这一档）。mac 侧走 `performClick:`——
/// 合成的 mouseDown 会让按钮进 tracking 嵌套循环等一颗不在队列里的抬起，
/// 当场挂死（真跑咬出）；`performClick:` 是 `BM_CLICK` 的 mac 对应物，
/// target/action 的真路由照走。
pub fn click_button_in_window(title : String, x : Int32, y : Int32) -> Int32 {
  let t = @utf8.encode(title)
  c_click_button_in_window(t, t.length(), x, y)
}

///|
/// 等价于"用户在 (x, y) 那个输入框里打出 text"（单行 kind 2 / 密码 kind 4）。
/// 返回码：0 = 已插入，-1 编码失败，-2 找不到窗口，-3 点在窗口外，
/// -4 命中的不是输入框（含窗口空白处），-5 拿不到可编辑的文本栈。
pub fn type_text_in_window(
  title : String,
  x : Int32,
  y : Int32,
  text : String,
) -> Int32 {
  let t = @utf8.encode(title)
  let s = @utf8.encode(text)
  c_type_text_in_window(t, t.length(), x, y, s, s.length())
}

///|
/// 等价于"用户把焦点挪到 (x, y) 那个控件上"，判据是回读。返回码：
/// 0 = 焦点已落到我们的控件，-2 找不到窗口，-3 点在窗口外，
/// -4 命中的不是我们的控件（含窗口空白处）或者原生答应了却没给。
pub fn focus_widget_in_window(title : String, x : Int32, y : Int32) -> Int32 {
  let t = @utf8.encode(title)
  c_focus_widget_in_window(t, t.length(), x, y)
}
