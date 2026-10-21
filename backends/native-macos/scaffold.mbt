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
#borrow(title)
extern "c" fn c_click_custom_in_window(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int32 = "moonui_native_click_custom_in_window"

///|
/// 等价于"用户在自定义绘制面（`T101`）的 (x, y) 处点了一下"：命中判 kind 18
/// 之后造一对真 NSEvent，依次交给那只 view 自己的 mouseDown:/mouseUp:，于是
/// "按下并原地抬起才算一次 Click"那条判据真跑一遍。
///
/// 为什么不复用 `click_button_in_window`：那条要求 NSButton 并用
/// `performClick:` 触发，自定义面是裸 NSView、没有 target/action。
/// 返回码：0 = 已派发，-1 造事件失败，-2 找不到窗口，-3 点在客户区外，
/// -4 命中处不是自定义绘制面（空白与别的控件都归这一档）。
pub fn click_custom_in_window(title : String, x : Int32, y : Int32) -> Int32 {
  let t = @utf8.encode(title)
  c_click_custom_in_window(t, t.length(), x, y)
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

///|
#borrow(title)
extern "c" fn c_right_click_in_window(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int32 = "moonui_native_right_click_in_window"

///|
/// 等价于"用户在 (x, y) 处按了一下右键（按下+抬起一对）"（`T91①` 用）。
/// 一对真 NSEvent 经 `sendEvent:` 派发：进程级鼠标监听在这次调用里同步跑完，
/// target/位置/kind 全是原生给的。返回码：0 = 已派发，-1 造不出事件，
/// -2 找不到窗口，-3 点在客户区外。
///
/// 只在非文本控件上方用：编辑中的 NSTextView（field editor）默认
/// `rightMouseDown:` 会弹它自己的系统菜单（一层同步追踪循环），那条路会挂住
/// 测试（adapter.h 这条的注记）。
pub fn right_click_in_window(title : String, x : Int32, y : Int32) -> Int32 {
  let t = @utf8.encode(title)
  c_right_click_in_window(t, t.length(), x, y)
}

///|
extern "c" fn c_auto_pick_context_menu(ms : Int32, index : Int32) -> Int32 = "moonui_native_auto_pick_context_menu"

///|
/// 安排"ms 毫秒之后点了上下文菜单的第 index 项"（0 起算；-1 = 点空白关掉）。
/// 上下文菜单是同步阻塞的，不先安排这一下调用方永远回不来（契约在 adapter.h
/// 脚手架段）。返回 0 = 已装好，-1 = index 小于 -1。
pub fn auto_pick_context_menu(ms : Int32, index : Int32) -> Int32 {
  c_auto_pick_context_menu(ms, index)
}

///|
#borrow(title, paths)
extern "c" fn c_simulate_file_drop(
  title : Bytes,
  title_len : Int32,
  paths : Bytes,
  paths_len : Int32,
) -> Int32 = "moonui_native_simulate_file_drop"

///|
/// 等价于"用户把文件拖进窗口客户区然后松手"（`T91③`）。真拖要人按住鼠标从
/// Finder 拖进来；这条替投"松手那一刻"——真 NSPasteboard 里写 file URL，再走
/// destination 自己那条打包/通知路。返回码：0 = 已投递，-1 没有路径，
/// -2 找不到窗口。
pub fn simulate_file_drop(title : String, paths : Array[String]) -> Int32 {
  let t = @utf8.encode(title)
  let mut joined = ""
  let mut i = 0
  while i < paths.length() {
    if i > 0 {
      joined = joined + "\n"
    }
    joined = joined + paths[i]
    i = i + 1
  }
  let p = @utf8.encode(joined)
  c_simulate_file_drop(t, t.length(), p, p.length())
}

///|
#borrow(title)
extern "c" fn c_file_drop_probe(title : Bytes, title_len : Int32) -> Int64 = "moonui_native_file_drop_probe"

///|
/// 拖入链的三个事实（`T91③`）：`(监听装着, 登记了 file URL 这一档, 上一次替投被接住)`。
/// 找不到窗口时三格全 false（探针的 -2 那一档，调用方另有句柄可判）。
pub fn file_drop_probe(title : String) -> (Bool, Bool, Bool) {
  let t = @utf8.encode(title)
  let bits = c_file_drop_probe(t, t.length())
  (bits % 2L == 1L, bits / 2L % 2L == 1L, bits / 4L % 2L == 1L)
}

///|
#borrow(title)
extern "c" fn c_drag_hit_probe(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int32 = "moonui_native_drag_hit_probe"

///|
/// "拖到这个点上，这次拖拽由谁接？"（`T91③` 的 field editor 边界）：
/// 1 = 编辑中的 field editor 自己接（NSTextView 就是 destination），0 = 递退到
/// 窗口那一层，-2 找不到窗口，-3 点在客户区外。
pub fn drag_hit_probe(title : String, x : Int32, y : Int32) -> Int32 {
  let t = @utf8.encode(title)
  c_drag_hit_probe(t, t.length(), x, y)
}

///|
#borrow(title, text)
extern "c" fn c_ime_compose_in_window(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
  text : Bytes,
  text_len : Int32,
) -> Int32 = "moonui_native_ime_compose_in_window"

///|
#borrow(title, text)
extern "c" fn c_ime_commit_in_window(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
  text : Bytes,
  text_len : Int32,
) -> Int32 = "moonui_native_ime_commit_in_window"

///|
/// 等价于"输入法正在组合，标记串是 text"（`T90④`）：调
/// `setMarkedText:selectedRange:replacementRange:`——输入法自己走的那条。它只改
/// 文本存储、不发 `controlTextDidChange:`，相位靠选择区通知推（adapter.h 这条的
/// 注记）。单行（kind 2/4）与多行（kind 10）都认。返回码：0 = 已投递，
/// -1 编码失败，-2 找不到窗口，-3 点在窗口外，-4 命中的不是文本控件，
/// -5 焦点没落上或拿不到编辑视图。
pub fn ime_compose_in_window(
  title : String,
  x : Int32,
  y : Int32,
  text : String,
) -> Int32 {
  let t = @utf8.encode(title)
  let s = @utf8.encode(text)
  c_ime_compose_in_window(t, t.length(), x, y, s, s.length())
}

///|
/// 等价于"输入法上屏"（`T90④`）：`insertText:` 把标记串换成 text 并清掉标记
/// 区间，相位收"结束"，全文随既有文本变化通道回 Core。text 传空串 = 取消这次
/// 组合。返回码同上。
pub fn ime_commit_in_window(
  title : String,
  x : Int32,
  y : Int32,
  text : String,
) -> Int32 {
  let t = @utf8.encode(title)
  let s = @utf8.encode(text)
  c_ime_commit_in_window(t, t.length(), x, y, s, s.length())
}

///|
extern "c" fn c_click_tray_item(index : Int32) -> Int32 = "moonui_native_click_tray_item"

///|
/// 派发托盘菜单第 `index` 项的选中（`T91⑥` 的"点一下"那半）：走
/// `performActionForItemAtIndex:` → item 自己的 target/action → Core 的
/// `bar.click` 语义。真弹窗（`performClick:` + 追踪循环）在并行测试里会挂死，
/// 那半退回人手一次（adapter.h 段注记了原因）。返回码：0 = 派发过，
/// -1 = 没有状态项或没挂菜单，-2 = index 越界，-3 = 还没初始化。
pub fn click_tray_item(index : Int32) -> Int32 {
  c_click_tray_item(index)
}

///|
#borrow(title)
extern "c" fn c_magnify_in_window(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
  value_micro : Int64,
  phase : Int32,
) -> Int32 = "moonui_native_magnify_in_window"

///|
#borrow(title)
extern "c" fn c_rotate_in_window(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
  value_micro : Int64,
  phase : Int32,
) -> Int32 = "moonui_native_rotate_in_window"

///|
#borrow(title)
extern "c" fn c_swipe_in_window(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
  direction : Int32,
) -> Int32 = "moonui_native_swipe_in_window"

///|
/// 等价于"用户在 (x, y) 处捏了一下"（`T100`；MoonUI 坐标口径，见文件头）。
/// `value` 是相对缩放增量（与 `NSEvent.magnification` 同义：加在当前缩放上
/// 取新值），`phase` 是 adapter.h 的四档（0 began / 1 changed / 2 ended /
/// 3 cancelled）。投的是**派发之后**那一步——AppKit 没有公开入口造 gesture
/// NSEvent，真捏一下那格退回人手（adapter.h 手势段记了口径）。
/// 返回码：0 = 已派发，-2 找不到窗口，-3 点在客户区外。
pub fn magnify_in_window(
  title : String,
  x : Int32,
  y : Int32,
  value : Double,
  phase : Int32,
) -> Int32 {
  let t = @utf8.encode(title)
  c_magnify_in_window(t, t.length(), x, y, micro_of(value), phase)
}

///|
/// 等价于"用户在 (x, y) 处双指转了一下"（`T100`）：`value` 是**角度**、与
/// `NSEvent.rotation` 同一个单位（换算成弧度由 C 里那个与产品路径共用的函数
/// 做，所以这条断言盯得住"只换一次、方向对"）。返回码同
/// `magnify_in_window`。
pub fn rotate_in_window(
  title : String,
  x : Int32,
  y : Int32,
  value : Double,
  phase : Int32,
) -> Int32 {
  let t = @utf8.encode(title)
  c_rotate_in_window(t, t.length(), x, y, micro_of(value), phase)
}

///|
/// 等价于"用户在 (x, y) 处双指划了一下"（`T100`）：`direction` 按 adapter.h
/// 的编码（0 左 / 1 右 / 2 上 / 3 下），说的是**手指往哪儿划**。返回码同
/// `magnify_in_window`。
pub fn swipe_in_window(
  title : String,
  x : Int32,
  y : Int32,
  direction : Int32,
) -> Int32 {
  let t = @utf8.encode(title)
  c_swipe_in_window(t, t.length(), x, y, direction)
}

///|
/// 小数 → 定点百万分之一（adapter.h 手势段的 value 口径）。四舍五入到
/// 最近的百万分之一：0.02 那一档来回都是 0.02，负数（旋转逆时针为负）也
/// 不丢符号。
fn micro_of(v : Double) -> Int64 {
  (v * 1000000.0).round().to_int64()
}

///|
#borrow(title)
extern "c" fn c_custom_probe(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int64 = "moonui_native_custom_probe"

///|
/// 读自定义绘制面（`T101`）在 (x, y) 处**真画出来的**像素：窗口标题命中那只
/// Custom 视图，再读它 layer 上那张位图（present 贴上去的就是 `begin_frame`
/// 开出来的缓冲区本身）。
///
/// 为什么值得单开一支探针：清单重放对不对可以用录制式断言（`RecordCanvas`
/// 那一档），但那证明不了"位图真的贴到了这只 view 上、且坐标没有翻错"。
/// 这条读的是图层里的成品——预乘后的 0xRRGGBBAA，不透明色就是原色。
///
/// 返回码：-1 找不到窗口，-2 这一处不是自定义绘制面（含空白与别的控件），
/// -3 面在但还没 present 过。坐标口径同 `click_button_in_window`（客户区
/// 左上原点、物理像素）。
pub fn custom_probe(title : String, x : Int32, y : Int32) -> Int64 {
  let t = @utf8.encode(title)
  c_custom_probe(t, t.length(), x, y)
}

///|
#borrow(title)
extern "c" fn c_send_mouse_in_window(
  title : Bytes,
  title_len : Int32,
  kind_button : Int32,
  x : Int32,
  y : Int32,
  dx : Int32,
  dy : Int32,
) -> Int32 = "moonui_native_send_mouse_in_window"

///|
/// `kind * 8 + button` 的打包（adapter.h 鼠标段的编码，两平台同一套）：
/// kind 0 按下 / 1 抬起 / 2 移动或拖拽 / 3 双击 / 4 滚轮；
/// button 0 左 / 1 右 / 2 中 / 3 Extra1 / 4 Extra2——与 `MouseButton` 的
/// 声明顺序一字不差。kind 2 的 button 是"按住哪颗在拖"，kind 4 的 button
/// 位无意义恒 0（`Event::Scroll` 没有键这一栏）。
pub fn mouse_kind_button(kind : Int32, button : Int32) -> Int32 {
  kind * 8 + button
}

///|
/// 等价于"用户在 (x, y) 处给出一次鼠标动作"——滚轮/拖动/双击/中键这四类在
/// mac 侧此前**一个自动化入口都没有**（`T108`：这条 ABI 全仓只有 Windows 一份
/// 定义，mac 半一直欠着）。派发走真 `NSEvent` 过 `[NSApp sendEvent:]`，于是
/// 进程级鼠标监听（`on_mouse`）真看见它：坐标命中、kind/button 编码、滚轮的
/// 增量换算全由原生给，不是把回调调一遍。
///
/// 两处与别的口子不同，都是 AppKit 的事实而不是选择：①按下那一支连带一颗
/// 抬起，抬起**先排进队列**（控件自己的 tracking 循环从队列取，取不到就挂
/// 死），于是"抬起有没有被 Core 看见"跟着控件自跑与否走，测试断言前要先
/// `scaffold_drain`；②投之前窗口会被变成 key——非前台应用的左键首击会被
/// AppKit 当激活点击消费掉（`T101` 实测）。
///
/// dx/dy 只在 kind 4 有意义，且是**逻辑像素**（正 = 往下读 / 往右读）：C 按
/// 自然滚动旗标把它翻成原生那一份，监听读回时再翻一次，往返自逆——所以这里
/// 给"Core 该看到的数"，不是原生那一格。两轴同时非零是 -5（mac 的 CGEvent
/// 带得动两轴，但那条 ABI 两边共用，一侧投一条另一侧投两条，测试就要去猜顺序）。
/// kind 5（离开窗口）不在这套编码里（Windows 同期报 -5），离开的自动化另算。
///
/// 返回码：0 = 已投递，-1 = 编码失败或原生造不出事件（含 button 3/4——AppKit
/// 没有对应事件类型），-2 找不到窗口，-3 点在客户区外，-4 命中的不是我们的
/// 控件（含窗口空白处——投送侧比监听侧严一格），-5 kind/button 越界或滚轮两轴
/// 同时非零。
pub fn send_mouse_in_window(
  title : String,
  kind_button : Int32,
  x : Int32,
  y : Int32,
  dx : Int32,
  dy : Int32,
) -> Int32 {
  let t = @utf8.encode(title)
  c_send_mouse_in_window(t, t.length(), kind_button, x, y, dx, dy)
}
