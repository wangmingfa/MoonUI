///|
/// macOS 后端的真窗口验证（§48 第 03/09/10 步的 macOS 半）。
///
/// 被测的是"共享的 MoonBit 实现 + Cocoa 的 C Adapter"这一对：
/// `@libui-common.LibuiBackend` 在 Windows 和 macOS 上是同一份代码，底下换的是
/// `adapter_macos.m`。所以这里的每条断言都在问"Cocoa 有没有把 adapter.h 的契约
/// 兑现"，而不是重复 Windows 那套已经跑过的属性读写。
///
/// 只有 Cocoa 特有的四件事单独钉：
///   - 物理像素↔点的换算（Windows 没有这一段，因为 DPI 感知的 Win32 直接收像素）；
///   - y 轴方向（Cocoa 客户区默认从左下往上量，MoonUI 的矩形从左上往下量）；
///   - 文案分居 `stringValue`/`title` 两个属性（Win32 全是窗口文本）；
///   - 层叠的数法（Cocoa 的 subviews 数组末尾是上层，Win32 的子窗口列表开头是上层）。
///
/// 这些测试会真的开窗口。带 App 的那条用 `for_testing` 的有限等待预算，
/// 链路断了就是测试失败，不会挂住 CI。
///
/// 这一边的测试按行号引用别处（`:352` 那种写法）已经停用了：往被引用的文件里插一行
/// 就把后面的引用全部挪走，而挪走的引用不会自己报错。要指位置就按符号名、测试名或
/// TODO 的永久号。

///|
/// 逻辑尺寸往返的容差：物理取整（宽高原方向向上、原点向下）最多让一个方向差 1 像素；
/// macOS 还要多一道"点"的取整，所以窗口级的量允许差到 1 逻辑像素。
fn close_to(a : Double, b : Double) -> Bool {
  let d = a - b
  d < 1.0 && d > -1.0
}

///|
/// 控件在 Cocoa 里的**原始** frame 原点 y（左下原点、从父视图底边往上量）和父视图
/// 高，物理像素。adapter 那边每个对外读数都过了一遍翻折，只有这条没有——翻转方向
/// 就是靠它对表的（见"原点是左上角"那条测试的注释）。找不到给负数。
#borrow(title, text)
extern "c" fn c_cocoa_origin_of_widget(
  title : Bytes,
  title_len : Int,
  text : Bytes,
  text_len : Int,
) -> Int64 = "moonui_cocoa_origin_of_widget"

///|
/// 那只控件**自己要求**的尺寸（`[cell cellSize]`，物理像素），也就是 AppKit 的
/// `sizeToFit` 会摆出来的那一摆。下面那条"固有尺寸画得下文案"的测试用它当对照组。
#borrow(title, text)
extern "c" fn c_cocoa_cell_size_of_widget(
  title : Bytes,
  title_len : Int,
  text : Bytes,
  text_len : Int,
) -> Int64 = "moonui_cocoa_cell_size_of_widget"

///|
/// 给本进程设一次外观覆盖：0 = 取消（回到跟随系统），1 = 强制深色，2 = 强制浅色。
/// 它是"系统外观那条读数有没有牙"的唯一微分，两个方向各钉一句，理由写在
/// adapter_macos.m 那条定义上。只动 NSApp.appearance，不碰系统设置、不落盘。
extern "c" fn c_cocoa_set_appearance_override(mode : Int) -> Unit = "moonui_cocoa_set_appearance_override"

///|
/// C 侧一次回两个整数：高 32 位前一个、低 32 位后一个。和 ffi.mbt 里那份同形，
/// 只是那条是私有的，而这条读数只该活在这份测试里。
fn unpack2(v : Int64) -> (Int, Int) {
  ((v >> 32).to_int(), (v << 32 >> 32).to_int())
}

///|
fn cocoa_origin(title : String, text : String) -> (Int, Int) {
  let t = @utf8.encode(title)
  let w = @utf8.encode(text)
  unpack2(c_cocoa_origin_of_widget(t, t.length(), w, w.length()))
}

///|
fn cocoa_cell_size(title : String, text : String) -> (Int, Int) {
  let t = @utf8.encode(title)
  let w = @utf8.encode(text)
  unpack2(c_cocoa_cell_size_of_widget(t, t.length(), w, w.length()))
}

///|
/// §32 的焦点事件现在每圈事件循环都可能冒出来：两边都没有"既及时又不侵入"的焦点
/// 回调，后端只能每圈问一次、变了才发（`T39`，`backend.mbt` 的 `refresh_focus`）。
/// 下面那两条"程序改了不该冒回声"的负控制测的是**同一种事件**的回声，所以断言按
/// 事件种类过滤来读：把 Focus/Blur 混进"总条数"里，红线就会跟着 firstResponder 的
/// 安装时序漂（编辑框的 field editor 是到消息循环里才装上的）。焦点自己由后面
/// 那三条专门钉。过滤不是放水：订阅本就只挂在那一只控件的 target 上，
/// 所以留在数组里的每一条都已经是它的 target。
fn input_texts(evs : Array[@moonui.Event]) -> Array[String] {
  let out : Array[String] = []
  for ev in evs {
    match ev {
      @moonui.Input(_, text) => out.push(text)
      _ => ()
    }
  }
  out
}

///|
/// 同上，勾选那一侧的对照组：只有 `Change` 进得来。
fn changes(evs : Array[@moonui.Event]) -> Array[@moonui.EventTarget] {
  let out : Array[@moonui.EventTarget] = []
  for ev in evs {
    match ev {
      @moonui.Change(t) => out.push(t)
      _ => ()
    }
  }
  out
}

///|
/// 键盘事件的顺序表：`(打在谁身上, 键, 按下还是抬起)`。`T39` 那三条按这个读——一条
/// 键事件带着 target 和 KeyPress 两样内容，整串 `seen` 比对会把同一圈里冒出来的
/// 焦点、Input 也算进来，那些不是这条要钉的。
fn key_events(
  evs : Array[@moonui.Event],
) -> Array[(@moonui.EventTarget, @moonui.KeyPress, Bool)] {
  let out : Array[(@moonui.EventTarget, @moonui.KeyPress, Bool)] = []
  for ev in evs {
    match ev {
      @moonui.KeyDown(t, kp) => out.push((t, kp, true))
      @moonui.KeyUp(t, kp) => out.push((t, kp, false))
      _ => ()
    }
  }
  out
}

///|
/// 焦点事件折成 `("+"/"-", target)` 的顺序表，顺序就是发事件的顺序。
fn focus_events(
  evs : Array[@moonui.Event],
) -> Array[(String, @moonui.EventTarget)] {
  let out : Array[(String, @moonui.EventTarget)] = []
  for ev in evs {
    match ev {
      @moonui.Focus(t) => out.push(("+", t))
      @moonui.Blur(t) => out.push(("-", t))
      _ => ()
    }
  }
  out
}

///|
/// 顺序表里从第 `from` 条往后的部分，配 `let mut from = focus_events(seen).length()`
/// 用：动作之间比的是"这一步新冒出来什么"。
/// 为什么不整串比对：`win.show()` 之后 AppKit 自己会把 initialFirstResponder 定成
/// 第一个可聚焦的视图，那一条问到谁、在哪一圈问到，是窗口初始焦点的事，不是"我改
/// 焦点的那一步"的事。把它算进来，断言就跟着窗口的初始焦点漂了。
fn focus_new(
  evs : Array[@moonui.Event],
  from : Int,
) -> Array[(String, @moonui.EventTarget)] {
  let all = focus_events(evs)
  let out : Array[(String, @moonui.EventTarget)] = []
  let mut i = from
  while i < all.length() {
    out.push(all[i])
    i = i + 1
  }
  out
}

///|
/// 菜单项被点回来的顺序表（§25）。`T39` 那条"菜单认领的组合不双响"要把它和键事件
/// 分开数：两个都订阅在同一个 `seen` 上，整串比对会把焦点也算进来。
fn menu_selects(evs : Array[@moonui.Event]) -> Array[@moonui.EventTarget] {
  let out : Array[@moonui.EventTarget] = []
  for ev in evs {
    match ev {
      @moonui.MenuSelect(t) => out.push(t)
      _ => ()
    }
  }
  out
}

///|
/// 用过的后端，等着被清场收掉。
///
/// 句柄表是**进程全局**的：`../libui-common/ffi.mbt` 包级那个 `let handles` 和
/// `LibuiBackend` 实例无关，而 `Backend::terminate` 只收实例自己记着的
/// `live_widgets`/`live_windows`（../libui-common/backend.mbt 里那个 impl）。一条测试在断言处失败时，MoonBit 的 panic 不跑 `defer`
/// （本机实测：defer 里的 println 在正常返回那一路打得出来，panic 那一路打不出来），
/// 于是它建的窗口和控件连着那个实例一起留在表上，后面每一条的
/// `assert_eq(@libui-common.native_live_handles(), 0)` 都跟着红。本机实测过这个数字：
/// 临时注入一条故意在断言处失败的测试之后，9 条红 8 条，红字全是 `1 != 0`
/// （以及那两条中途数句柄的 `3 != 2`、`6 != 3`）——说的都不是这一条自己漏的，
/// 是上一条漏的一只窗口。把清场改成空转再跑，红数回到 8，隔离确实是清场给的。
/// 所以每条测试开头替上一条把 terminate() 补跑一遍（见 open_backend）。
/// 这张表是本文件的私有物，隔离的范围就是这一个文件：将来这个包加第二份真窗口
/// 测试文件时，得先把它也接到这套脚手架上，否则那一头的泄漏照样穿过文件边界。
let backends_in_play : Array[@libui-common.LibuiBackend] = []

///|
/// 清掉上一条失败时漏下的原生对象，让这一条从空的句柄表开始。已经自己收过尾的
/// 后端也在这张表里，对它们是空转：两个数组在 `Backend::terminate` 末尾清空，
/// libui 也已经 uninit，而 adapter 的 `moonui_terminate` 在没 inited 时直接返回
/// （adapter_macos.m 里那一句 `if (!moonui_inited)`）。
///
/// 为什么收的是"后端"而不是"句柄"：只有实例自己分得清哪只句柄是控件、哪只是
/// 窗口，而"先控件后窗口"是 uiUninit 分配审计的硬要求（`Backend::terminate`
/// 上面那段注释）——在测试里按种类再数一遍，就是抄一份会腐烂的副本。
///
/// 按登记顺序（最早的先收）遍历。因为每条测试开头都收一遍，任一时刻表里最多只有
/// 上一条没收尾，这个顺序只是保证真漏了两条时也不会提前 uiUninit。
fn sweep_leaked_handles() -> Unit {
  for b in backends_in_play {
    b.terminate()
  }
  backends_in_play.clear()
}

///|
/// 每条测试的开头：先清场，再建一个登记在册的后端。
fn open_backend() -> @libui-common.LibuiBackend {
  sweep_leaked_handles()
  let b = @libui-common.LibuiBackend::new()
  backends_in_play.push(b)
  b
}

///|
/// open_backend 的有限等待预算版（对应 @libui-common.LibuiBackend::for_testing）。
fn open_backend_for_testing(wait_budget_ms : Int) -> @libui-common.LibuiBackend {
  sweep_leaked_handles()
  let b = @libui-common.LibuiBackend::for_testing(wait_budget_ms)
  backends_in_play.push(b)
  b
}

///|
/// 窗口几何、缩放、屏幕信息。这条顺带钉住"macOS 的 dpi 就是倍数乘 96"：
/// adapter.h 说 C 侧只报 DPI 不做换算，而 Cocoa 只有倍数，所以 192 这种读数
/// 是本文件那次乘法的直接结果，Scale 拿到的还是同一个数。
test "macOS 后端：窗口尺寸、位置、缩放按物理像素往返" {
  let b = open_backend()
  b.init()
  let win = b.create_window("MoonUI macOS 窗口几何", @moonui.LogicalSize::{
    width: 300.0,
    height: 200.0,
  })
  let scale = b.window_scale(win)
  assert_true(scale.x >= 1.0 && scale.y >= 1.0)
  let size = b.window_size(win)
  assert_true(close_to(size.width, 300.0))
  assert_true(close_to(size.height, 200.0))
  b.set_window_size(win, @moonui.LogicalSize::{ width: 420.0, height: 260.0, })
  let grown = b.window_size(win)
  assert_true(close_to(grown.width, 420.0))
  assert_true(close_to(grown.height, 260.0))
  b.set_window_position(win, @moonui.LogicalPoint::{ x: 40.0, y: 60.0, })
  let origin = b.window_position(win)
  assert_true(close_to(origin.x, 40.0))
  assert_true(close_to(origin.y, 60.0))
  b.set_window_title(win, "MoonUI macOS 窗口几何 — 改名")
  b.set_window_resizable(win, false)
  b.hide_window(win)
  b.show_window(win)
  let screen = b.screen_size()
  assert_true(screen.width > 100.0 && screen.height > 100.0)
  // 外观（§16）。读数现在跟着进程的实际外观走，所以两个方向各钉一句：强制深色必须
  // 读到深色、强制浅色必须读到浅色。两句和桌面的设置无关——恒报 Light 红在第一句，
  // 恒报 Dark 红在第二句，换一台深色桌面的机器上跑也不会变成自证。
  // 最后清掉覆盖，读数要回到进入这条测试时那一份（这台机器当下是浅色，独立的尺子是
  // `defaults read -g AppleInterfaceStyle`，它报"键不存在"，不经我们的代码）。
  let theme_before = b.system_theme()
  c_cocoa_set_appearance_override(1)
  assert_eq(b.system_theme(), @moonui.Dark)
  c_cocoa_set_appearance_override(2)
  assert_eq(b.system_theme(), @moonui.Light)
  c_cocoa_set_appearance_override(0)
  assert_eq(b.system_theme(), theme_before)
  b.destroy_window(win)
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// y 轴方向单独钉一条：把控件分别摆在客户区的顶边和底边，先读 MoonUI 语义下的
/// 原点，再拿 Cocoa 的**原始** frame 对表。
///
/// 为什么要第二种读数：翻折写在 adapter 里，摆位和取数走的是同一个函数，方向写反
/// 的话两次翻折在数学上仍然自逆——下面那几条按翻折回来的值算的断言会全部照样绿。
/// 负控制实测过：把 `moonui_flip_y` 改成恒等，这套测试一条都没红。原始的 Cocoa
/// 原点不经过那条路径，才是能分辨方向的对照。
test "macOS 后端：原点是左上角，不是左下角" {
  let b = open_backend()
  b.init()
  let title = "MoonUI macOS 翻转方向"
  let win = b.create_window(title, @moonui.LogicalSize::{
    width: 200.0,
    height: 200.0,
  })
  let top = b.create_widget(@moonui.Label, "上")
  let bottom = b.create_widget(@moonui.Label, "下")
  b.attach_widget(win, top)
  b.attach_widget(win, bottom)
  b.set_widget_bounds(top, @moonui.LogicalRect::{
    origin: @moonui.LogicalPoint::{ x: 0.0, y: 0.0, },
    size: @moonui.LogicalSize::{ width: 80.0, height: 20.0, },
  })
  // 底边：摆在"客户区逻辑高度减去控件高度"处，下沿就贴住客户区下沿
  let logical = b.window_size(win)
  b.set_widget_bounds(bottom, @moonui.LogicalRect::{
    origin: @moonui.LogicalPoint::{ x: 0.0, y: logical.height - 20.0, },
    size: @moonui.LogicalSize::{ width: 80.0, height: 20.0, },
  })
  b.show_window(win)
  let (cw, ch) = @libui-common.native_window_content_size(win)
  let (top_x, top_y) = @libui-common.native_widget_origin(top)
  let (bottom_x, bottom_y) = @libui-common.native_widget_origin(bottom)
  let (_, top_h) = @libui-common.native_widget_size(top)
  let (_, bottom_h) = @libui-common.native_widget_size(bottom)
  assert_true(cw > 0 && ch > 0)
  assert_true(top_x >= 0 && top_y >= 0 && top_y <= 2)
  assert_true(bottom_x >= 0)
  assert_true(bottom_y > top_y)
  // 贴底的那只：原点到客户区顶边的距离 = 客户区高 - 控件高（都是物理像素），
  // 允许 2 像素的取整余量
  assert_true(bottom_y >= ch - bottom_h - 2 && bottom_y <= ch - bottom_h + 2)
  // 对表：Cocoa 的原点在**下**边，所以"客户区顶边"在那一侧读数是大的，
  // "客户区底边"读数是 0。翻折一去掉，这两条正好互换，测试就红了。
  let (raw_top_y, sup_h) = cocoa_origin(title, "上")
  let (raw_bottom_y, raw_sup_h) = cocoa_origin(title, "下")
  assert_true(raw_top_y > 0 && raw_bottom_y >= 0)
  // 父视图就是客户区：contentView 的高度和 libui 报的客户区尺寸是同一个量
  assert_true(sup_h == raw_sup_h && sup_h >= ch - 2 && sup_h <= ch + 2)
  assert_true(raw_top_y >= sup_h - top_h - 2 && raw_top_y <= sup_h - top_h + 2)
  assert_true(raw_bottom_y <= 2)
  b.destroy_widget(bottom)
  b.destroy_widget(top)
  b.destroy_window(win)
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 控件矩形与四种属性的往返，覆盖 Cocoa 的分叉点：
/// 四种控件的文案分居 `stringValue`（label、entry）和 `title`（button、checkbox），
/// 而 Win32 那份一格窗口文本全包了。
test "macOS 后端：控件矩形与四种属性往返" {
  let b = open_backend()
  b.init()
  let win = b.create_window("MoonUI macOS 控件往返", @moonui.LogicalSize::{
    width: 320.0,
    height: 240.0,
  })
  let btn = b.create_widget(@moonui.Button, "确定")
  let label = b.create_widget(@moonui.Label, "说明")
  let entry = b.create_widget(@moonui.TextInput, "初值")
  let check = b.create_widget(@moonui.Checkbox, "同意")
  b.attach_widget(win, btn)
  b.attach_widget(win, label)
  b.attach_widget(win, entry)
  b.attach_widget(win, check)
  b.show_window(win)
  // 故意用奇数的逻辑尺寸：px→点→px 的往返必须自逆，不然差 1 像素会在这里现形
  b.set_widget_bounds(btn, @moonui.LogicalRect::{
    origin: @moonui.LogicalPoint::{ x: 7.0, y: 9.0, },
    size: @moonui.LogicalSize::{ width: 141.0, height: 33.0, },
  })
  let rect = b.widget_bounds(btn)
  assert_true(close_to(rect.origin.x, 7.0))
  assert_true(close_to(rect.origin.y, 9.0))
  assert_true(close_to(rect.size.width, 141.0))
  assert_true(close_to(rect.size.height, 33.0))
  assert_eq(b.widget_text(btn), "确定")
  assert_eq(b.widget_text(label), "说明")
  assert_eq(b.widget_text(entry), "初值")
  assert_eq(b.widget_text(check), "同意")
  b.set_widget_text(btn, "已确认")
  b.set_widget_text(entry, "改过的值")
  assert_eq(b.widget_text(btn), "已确认")
  assert_eq(b.widget_text(entry), "改过的值")
  assert_false(b.widget_checked(check))
  b.set_widget_checked(check, true)
  assert_true(b.widget_checked(check))
  assert_true(b.widget_visible(entry))
  b.set_widget_visible(entry, false)
  assert_false(b.widget_visible(entry))
  assert_true(b.widget_enabled(entry))
  b.set_widget_enabled(entry, false)
  assert_false(b.widget_enabled(entry))
  // 固有尺寸来自 AppKit 的测量：宽度随文案变，且不为零（§18 不让 Core 猜字体）
  let short = b.widget_intrinsic_size(label)
  b.set_widget_text(label, "说明说明说明说明")
  let long = b.widget_intrinsic_size(label)
  assert_true(short.width > 0.0 && short.height > 0.0)
  assert_true(long.width > short.width)
  // §15/§16 的样式下发在真后端上是**有意不生效**的（豁免写在 backend.mbt）：
  // 可调用、不报错，而且推个大字号之后原生报的度量一个像素都不变。
  b.set_widget_style(label, @moonui.style(font_size=Some(32.0)))
  let styled = b.widget_intrinsic_size(label)
  assert_true(close_to(styled.width, long.width))
  assert_true(close_to(styled.height, long.height))
  // detach 之后再 attach 回去，控件还在同一张句柄表里
  b.detach_widget(label)
  b.attach_widget(win, label)
  b.destroy_widget(check)
  b.destroy_widget(entry)
  b.destroy_widget(label)
  b.destroy_widget(btn)
  b.destroy_window(win)
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// §18 的度量在 macOS 上必须"画得下文案"：报给 Core 的固有尺寸不许比控件自己要求的窄。
/// 这条钉的是一个真实发生过的 bug——`moonui_widget_minimum_size` 原先优先取
/// `intrinsicContentSize`，而它对 label / button / checkbox 都比 `[cell cellSize]` 小
/// （本机实测，点）：81.5 对 85.3、72x20 对 86x32、63x16 对 65x18。Core 按小的那个摆，
/// AppKit 画的时候就挤掉最后一个字：真窗口里 "Hello MoonUI" 成了 "Hello MoonU"、
/// "Click Me" 成了 "Click M"。
///
/// 对照组是 C 侧现读的 `cellSize`（AppKit 的 `sizeToFit` 用的就是它），所以这条不是
/// 自证的：把那一处改回只取 `intrinsicContentSize`，label / button / checkbox 三条立刻
/// 红（负控制实测）。entry 是反过来的那头——intrinsic(96) > cellSize(66)，那 96 是
/// AppKit 给可编辑框设的宽度下限，取大者正好留住，所以对 entry 这条只是"不小于"。
test "macOS 后端：报出去的固有尺寸画得下文案" {
  let b = open_backend()
  b.init()
  let title = "MoonUI macOS 度量下限"
  let win = b.create_window(title, @moonui.LogicalSize::{
    width: 320.0,
    height: 240.0,
  })
  let scale = b.window_scale(win).x
  let made : Array[@moonui.NativeHandle] = []
  for
    (kind, text) in [
      (@moonui.Label, "文案文案"),
      (@moonui.Button, "Click Me"),
      (@moonui.TextInput, "输入输入"),
      (@moonui.Checkbox, "勾选勾选"),
    ] {
    let h = b.create_widget(kind, text)
    b.attach_widget(win, h)
    let got = b.widget_intrinsic_size(h)
    let (want_w, want_h) = cocoa_cell_size(title, text)
    // Core 那侧是逻辑像素，对照组是物理像素，乘回倍数再比。1 像素的余量是
    // pt→px 那一步取整，不是把容差放松。
    assert_true(
      got.width * scale >= (want_w - 1).to_double(),
      msg="「\{text}」宽度不够：报出 \{got.width * scale} 物理像素，控件要求 \{want_w}",
    )
    assert_true(
      got.height * scale >= (want_h - 1).to_double(),
      msg="「\{text}」高度不够：报出 \{got.height * scale} 物理像素，控件要求 \{want_h}",
    )
    made.push(h)
  }
  for h in made {
    b.destroy_widget(h)
  }
  b.destroy_window(win)
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 层叠的数法。Windows 那份的读数是 [0,1,2] 和 [2,1,0]（Windows 的
/// 「层叠的两个方向在真窗口上：挂载压底、raise 提顶」那条），
/// macOS 这边必须一模一样：挂载压到层叠底部、raise 提到顶部，两边用同一种话写。
/// 数字对不上就说明 Core 的 `apply_layers` 在某个后端上是反的。
test "macOS 后端：层叠的两个方向和 Windows 同向" {
  let b = open_backend()
  b.init()
  let row_win = @moonui.Window::new(b, "MoonUI macOS 层叠-挂载", @moonui.LogicalSize::{
    width: 240.0,
    height: 180.0,
  })
  let first = @moonui.Widget::label(b, "Ab")
  let second = @moonui.Widget::label(b, "Abcd")
  let third = @moonui.Widget::label(b, "A")
  row_win.set_content(@moonui.Widget::row(b, 6.0, [first, second, third]))
  assert_eq(z_indices([first, second, third]), [0, 1, 2])
  row_win.close()

  let stack_win = @moonui.Window::new(b, "MoonUI macOS 层叠-叠放", @moonui.LogicalSize::{
    width: 240.0,
    height: 180.0,
  })
  let back = @moonui.Widget::label(b, "Ab")
  let badge = @moonui.Widget::button(b, "Ok")
  let top = @moonui.Widget::label(b, "A")
  stack_win.set_content(@moonui.Widget::stack(b, [back, badge, top]))
  assert_eq(z_indices([back, badge, top]), [2, 1, 0])
  stack_win.close()
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 控件在父视图 subviews 数组里的位置，0 = 最上层。
fn z_indices(
  widgets : Array[@moonui.Widget[@libui-common.LibuiBackend]],
) -> Array[Int] raise @moonui.UiError {
  let out : Array[Int] = []
  for w in widgets {
    out.push(@libui-common.native_control_z_index(w.handle().unwrap()))
  }
  out
}

///|
/// 事件循环的两个终止条件：没有存活窗口，和主循环结束（这里是 uiQuit，对应
/// Win32 的 WM_QUIT）。libui 的 darwin 版在 uiQuit 里调 [NSApp terminate:]，
/// 实测它只把循环标成跑完（main_step 从这里开始返回 0），进程照常在，
/// 这条断言钉的就是"敢在测试进程里调它"。
test "macOS 后端：poll_event 的两个终止条件" {
  let b = open_backend()
  b.init()
  assert_eq(b.poll_event(), None)
  let win = b.create_window("MoonUI macOS 循环终止", @moonui.LogicalSize::{
    width: 100.0,
    height: 80.0,
  })
  @libui-common.native_quit()
  assert_eq(b.poll_event(), None)
  assert_eq(b.poll_event(), None)
  b.destroy_window(win)
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// terminate 自己扫遗留对象：§48 要求"关闭后句柄表归零"，而 libui 的 darwin 版
/// 在 uiUninit 里跑分配审计，漏一块就当 bug。控件必须先于窗口销毁这条由
/// backend.mbt 的收尾循环兜住，这里验的是它真的兜住了。
test "macOS 后端：terminate 扫掉遗留对象" {
  let b = open_backend()
  b.init()
  let _ = b.create_window("MoonUI macOS 遗留清理", @moonui.LogicalSize::{
    width: 120.0,
    height: 90.0,
  })
  let _ = b.create_widget(@moonui.Button, "没人销毁我")
  assert_eq(@libui-common.native_live_handles(), 2)
  b.terminate()
  assert_eq(@libui-common.native_live_handles(), 0)
}

///|
/// §25 那棵菜单在真窗口测试里的夹具。注释里的数字是 `MenuBar::new` 按整棵树深度优先
/// 重排出来的 id，也就是原生侧看到的那个数（mac 的 `NSMenuItem.tag`）：
///   File：Quit(0, Meta+q)、Sidebar(1, 勾选框)、分隔线、Zoom{ Small(2, radio), Large(3, radio) }
///   Edit：Copy(4, Ctrl+c)、Sync(5, 勾选框且禁用)
/// 5 号故意做成"禁用 + 可勾选"：`moonui_menu_click_item` 的 -2 那一支要它，而
/// adapter.h 的"禁用项也允许推勾选态"（置灰的菜单项照样要显示着勾）只在 Check/Radio
/// 上量得到——Normal 项在快照里恒为 `.`。
///
/// 文案一律避开 `;` `{` `}` `,` `:` 和以 `-` 开头：快照用这几个字符分段，结构字符混进
/// 文案里就分不清是分隔线还是文案了（adapter.h 的格式那一节）。
fn menu_fixture() -> @moonui.MenuBar {
  let quit = @moonui.MenuItem::new("Quit")
  quit.set_shortcut(@moonui.Shortcut::meta("q"))
  let sidebar = @moonui.MenuItem::checkbox("Sidebar")
  let small = @moonui.MenuItem::radio("Small")
  let large = @moonui.MenuItem::radio("Large")
  let copy = @moonui.MenuItem::new("Copy")
  copy.set_shortcut(@moonui.Shortcut::ctrl("c"))
  let sync = @moonui.MenuItem::checkbox("Sync")
  sync.set_enabled(false)
  @moonui.MenuBar::new([
    @moonui.Menu::new("File", [
      @moonui.MenuNode::Item(quit),
      @moonui.MenuNode::Item(sidebar),
      @moonui.MenuNode::Separator,
      @moonui.MenuNode::Submenu("Zoom", [
        @moonui.MenuNode::Item(small),
        @moonui.MenuNode::Item(large),
      ]),
    ]),
    @moonui.Menu::new("Edit", [
      @moonui.MenuNode::Item(copy),
      @moonui.MenuNode::Item(sync),
    ]),
  ])
}

///|
/// 夹具那棵菜单装好之后，原生侧应该长成的样子（格式在 adapter.h）。整根文本逐字符写全，
/// 因为这根文本两边一模一样是这次设计的一部分：Windows 那份测试断言的是同一串，
/// 于是"树解析对了没有"在两个平台上被同一个字符串钉住（那一边挂在 `T45` 真跑）。
let menu_dump_full : String = "File{#0:n.e:Quit:Mq,#1:c-e:Sidebar:.,-,+Zoom{#2:r-e:Small:.,#3:r-e:Large:.}};Edit{#4:n.e:Copy:Cc,#5:c-d:Sync:.}"

///|
/// 快照里有没有某一项的完整记录。用在勾选态随点击变化的那几条：整串比对已经在
/// `menu_dump_full` 上做过一次了，这里要逐项盯，但仍然写全 `#<id>:<role><check><enabled>:
/// <label>:<sc>` 一整节，不是只查一个 `+`——只查 `+` 的话格式挪位也照样绿。
fn menu_dump_has(entry : String) -> Bool {
  @libui-common.native_menu_dump().contains(entry)
}

///|
/// §48-20 的"装上去"这一半：Core 那棵树整棵打包给 C，C 建出真的 NSMenu 挂进
/// `[NSApp mainMenu]`，快照读回来的是**主菜单里的那几顶**，不是 adapter 自己记的名单。
/// 这一步不能省：名单是我们抄的，只抄名单的话把 `addItem:` 整段删掉也照样绿（负控制实测
/// 过两种：删掉 `addItem:` 而名单照抄，三条菜单测试全红在第一处读回快照的断言上，而
/// `[NSApp mainMenu]` 那边 `removeItem:` 因为"这一项本来不在菜单里"直接抛
/// NSInternalInconsistencyException——两份账对不上时的现场就是这么响）。
/// 于是这一条同时钉三件事：
/// - 布局：MoonBit 的序列化器和两份 C 的解析器对的是同一份 adapter.h 布局，一个字段
///   错位就整串对不上；`Submenu` 的递归、分隔线不占 id、禁用项的 `d` 都在这里。
/// - 组合落到了项上：`<sc>` 那一栏读的是 NSMenuItem 自己的 keyEquivalent 和
///   keyEquivalentModifierMask，所以它证明的是"Core 给的 ⌘q / ⌃c 真的写进了原生项"。
///   mac 不认功能键（adapter.h 那条分叉）在这栏看得见，因此夹具只用两边都认的组合。
/// - 拆干净：换一棵是整棵替换（快照只剩 Edit 那一项，旧树里的 id 在原生侧报 -1），
///   空的一棵就是拆掉，`terminate` 之后再读还是空——菜单是进程全局的、不归句柄表管，
///   漏拆的话它不会让句柄数变红，只会串到下一跑的快照里。
///
/// 句柄表归零：菜单栏上没有一个 MoonUI 句柄（`set_menu_bar` 不建窗口也不建控件）。
test "macOS 后端：菜单栏整棵装进原生主菜单，快照逐字符对得上" {
  let b = open_backend()
  b.init()
  b.set_menu_bar(menu_fixture())
  assert_eq(@libui-common.native_menu_dump(), menu_dump_full)
  assert_eq(@libui-common.native_live_handles(), 0)
  // 换一棵：旧的整棵摘掉，所以旧树里的 id 在原生侧不再有对应项
  b.set_menu_bar(
    @moonui.MenuBar::new([
      @moonui.Menu::new("Edit", [
        @moonui.MenuNode::Item(@moonui.MenuItem::new("Copy")),
      ]),
    ]),
  )
  assert_eq(@libui-common.native_menu_dump(), "Edit{#0:n.e:Copy:.}")
  assert_eq(@libui-common.native_menu_click_item(1), -1)
  // 空的一棵 = 拆掉
  b.set_menu_bar(@moonui.MenuBar::new([]))
  assert_eq(@libui-common.native_menu_dump(), "")
  // 再装一次再收尾：`terminate` 里那次拆干净只有在这里才量得到——上面那条"空的一棵"
  // 已经先拆过一遍了。菜单是进程全局的、不归句柄表管，漏拆不会让句柄数变红，
  // 只会把这一棵串进下一跑的快照里（负控制实测：删掉 terminate 里的 `moonui_menu_clear()`，
  // 16 条里只有这一条红，红在收尾之后那一句，读回来的是整根 `menu_dump_full`）。
  b.set_menu_bar(menu_fixture())
  assert_eq(@libui-common.native_menu_dump(), menu_dump_full)
  b.terminate()
  assert_eq(@libui-common.native_menu_dump(), "")
}

///|
/// §48-20 的"点下去"这一半，macOS 版：脚手架对真 NSMenuItem 走
/// `performActionForItemAtIndex:`（不是把 MoonBit 的回调直接调一遍）→ AppKit 把 item
/// 自己送给 target → 回调读的是 `item.tag`，也就是 Core 当年装进去的那个 id →
/// 后端入队 `MenuSelect` → App 派发给订阅者。整条链上没有一个事件是测试自己造的，
/// 所以那句 `assert_eq(seen, [MenuSelect(...)])` 钉的是"id 从原生对象上带回来了"。
///
/// 后半截是反方向：§25 的勾选态只存在 Core，原生菜单项只有写入口，所以每次点击之后
/// 由 `App::click_menu_item` 推给后端。快照里 `c-` 变 `c+` 看得见这次推送，再点一次
/// 变回 `c-`（写死成 `true` 的实现在第二发上就红）；Radio 那一对比的是"同组一起推"：
/// 互斥是 Core 算的，原生层不会自己取消兄弟项，漏推一个就留下两个选中点。
///
/// 禁用那一项（5 号）报 -2 且队列里什么都不冒：`performActionForItemAtIndex:` 自己
/// 尊重 isEnabled，那就成了"什么也没发生但报成功"，所以脚手架在派发之前先查、查到禁用
/// 就原样退回（adapter.h 要求两边报同一套码）。
///
/// 两处负控制各钉住这条链的一半，都是本机实测：
/// - 把 `moonuiMenuItemClicked:` 里交给 MoonBit 的那一次调用去掉：16 条只红这一条，
///   红在第一个 `app.step()` 上——`native_menu_click_item` 照旧报 0，也就是原生确实派发
///   了，断的是"派发到 MoonBit"这一环，不是测试自己没等到。
/// - 把 `moonui_menu_item_set_checked` 里的 `setState:` 去掉：这一条和下面那条"失败形态"
///   一起红，各自红在第一个 `menu_dump_has` 上（`#1:c+e` / `#5:c+d` 读不回来），
///   而点击那半（`MenuSelect` 那条）照旧绿——推的方向和点的方向是分得开的两条路。
test "macOS 后端：真点击菜单项回流成 MenuSelect，勾选态推回原生菜单" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  app.set_menubar(menu_fixture())
  assert_eq(@libui-common.native_menu_dump(), menu_dump_full)
  let seen : Array[@moonui.Event] = []
  let sidebar = @moonui.EventTarget::{ id: 1, }
  let _ = app.on_event(sidebar, fn(ev) { seen.push(ev) })
  assert_eq(@libui-common.native_menu_click_item(1), 0)
  assert_true(app.step())
  assert_eq(seen, [@moonui.MenuSelect(sidebar)])
  assert_true(menu_dump_has("#1:c+e:Sidebar:."))
  // 再点一次：推的是改完之后的状态，不是"点一下就勾上"
  assert_eq(@libui-common.native_menu_click_item(1), 0)
  assert_true(app.step())
  assert_true(menu_dump_has("#1:c-e:Sidebar:."))
  // Radio：点 Large，同组的 Small 一起被推（Core 算的互斥要看得见）
  assert_eq(@libui-common.native_menu_click_item(3), 0)
  assert_true(app.step())
  assert_true(menu_dump_has("#3:r+e:Large:."))
  assert_true(menu_dump_has("#2:r-e:Small:."))
  assert_eq(@libui-common.native_menu_click_item(2), 0)
  assert_true(app.step())
  assert_true(menu_dump_has("#2:r+e:Small:."))
  assert_true(menu_dump_has("#3:r-e:Large:."))
  // 禁用项：-2，且没有事件冒出来（预算之内空转，红在 `app.step()` 上就是多冒了一条）
  assert_eq(@libui-common.native_menu_click_item(5), -2)
  assert_false(app.step())
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 菜单失败的那几条形态。分两处钉：
/// - 脚手架（`moonui_menu_click_item`）的返回码：0 / -1 / -2 是 adapter.h 给两边的同一
///   套码，6 号"上一个 id 都不存在"和 99 号"从没出现过"必须同为 -1——测试里 `MenuBar`
///   的编号到 5 为止，写成别的数字就是抄了一份实现。
/// - 后端方法（`set_menu_item_checked`）的报错文案：和 `MockBackend` 那份断言逐字相同
///   （§33 的"同一个失败在所有后端上长成同一个样子"）。文案里不许带平台名字，因为抛出
///   它的是共享的 `backend.mbt`，Windows 报什么 mac 就报什么。
///
/// 最后一条是"能改"而不是"改得对"：禁用项允许推勾选态，快照里 `#5:c-d` 变 `c+d`——
/// 置灰的菜单项下次启用时勾还看得见。这一支只在 Check/Radio 上量得到（Normal 项的
/// check 位恒为 `.`），夹具的 5 号因此做成"禁用 + 勾选框"。
test "macOS 后端：菜单的失败形态和 MockBackend 逐字相同" {
  let b = open_backend()
  b.init()
  b.set_menu_bar(menu_fixture())
  assert_eq(@libui-common.native_menu_click_item(6), -1)
  assert_eq(@libui-common.native_menu_click_item(99), -1)
  let msg = try {
    b.set_menu_item_checked(999, true)
    "没有报错"
  } catch {
    e => @moonui.UiError::message(e)
  }
  assert_eq(msg, "操作失败：菜单项 999 不在已安装的菜单栏里")
  b.set_menu_item_checked(5, true)
  assert_true(menu_dump_has("#5:c+d:Sync:."))
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 真剪贴板往返（§23 / §48-19）：写进去的字要能从系统里读回来，读的是 NSPasteboard，
/// 不是 adapter 自己存的一份影子。
///
/// **这条测试动的是用户机器上的真剪贴板。** 复原只覆盖文本形态：剪贴板里若是图片或
/// 文件，`clearContents` 会把它清掉且放不回去——这是真后端剪贴板测试的固有代价，
/// 换 mock 就什么都测不到。
///
/// 结尾那句复原在测试失败时跑不到：MoonBit 的 panic 不执行后面的语句，和上面
/// `backends_in_play` 记的是同一条事实。于是一次失败会把测试文案留在用户的剪贴板里，
/// 下一跑还会把它当成用户原本的内容读出来再存回去——一次失败就永久改变后面的每一跑。
/// 包级便条救不了这个：测试每跑一次都是一个新进程，进程里的状态带不到下一跑。
/// 挡得住的是**别把自家的测试文案当成用户的内容存回去**：开头读回来的内容只要正是
/// 本条测试自己写过的那两句，就当它是空的，结尾那发复原会把剪贴板清干净。代价是那一跑
/// 用户原本的内容已经找不回来了，能做的只有止损，不是复原。
///
/// 三个断言各钉一件事：
/// - 写空串再读 → `None`：§23 的"内容为空返回 None"在真后端上的形状是 None，不是
///   `Some("")`（mac 这边 `stringForType:` 给 @"" ，C 转成空 bytes，ffi 那边变 None）。
/// - 非空往返 → `Some(原文)`：文案带中文，UTF-8 → NSString 这一转在这条路上过一次。
/// - 覆盖一次 → 只剩最后一份：剪贴板是整体替换，不是追加。
///
/// 句柄表照旧归零：剪贴板是进程级的，两条入口都不带句柄、一个原生对象都不建。
test "真后端读写系统剪贴板，测完把原内容放回去" {
  let b = open_backend()
  b.init()
  let read = b.clipboard_text()
  // 上条失败留下的自家文案不算"用户的内容"，见上面
  let saved = match read {
    Some(t) if t == "月 UI 的一段文案" || t == "覆盖一次" => None
    s => s
  }
  b.set_clipboard_text("")
  assert_eq(b.clipboard_text(), None)
  b.set_clipboard_text("月 UI 的一段文案")
  assert_eq(b.clipboard_text(), Some("月 UI 的一段文案"))
  b.set_clipboard_text("覆盖一次")
  assert_eq(b.clipboard_text(), Some("覆盖一次"))
  assert_eq(@libui-common.native_live_handles(), 0)
  // 复原用户原来的复制内容（只有文本形态放得回去，见上面的说明）
  match saved {
    None => b.set_clipboard_text("")
    Some(s) => b.set_clipboard_text(s)
  }
  b.terminate()
}

///|
/// §48 的完整链路，macOS 版：真窗口显示 → 按 Core 算出的矩形命中真按钮 →
/// NSButton 的 action 进队列 → App 派发给 Demo 的 handler → 文案改变 →
/// performClose: 走 windowShouldClose:（回调否决，销毁留给 Core）→ 句柄表归零。
///
/// 点击是同步的（performClick: 直接把回调跑完，事件留在队列里），关闭也是同步的，
/// `run()` 要做的只是把这两条取出来派发——这正是 §10 的 Event First。
test "macOS 后端跑完整事件循环：真点击改文案，真关闭收尾" {
  let b = open_backend_for_testing(4000)
  let app = @moonui.App::new(b)
  b.init()
  let demo = @moonui.Demo::hello(app)
  let title = "MoonUI"
  assert_eq(demo.status().text(), "Hello MoonUI")
  assert_eq(@libui-common.native_live_handles(), 3)
  let spot = @moonui.Scale::to_physical_rect(
    demo.window().scale(),
    demo.action().frame(),
  )
  let cx = spot.origin.x + spot.size.width / 2
  let cy = spot.origin.y + spot.size.height / 2
  let mut hits = 0
  let _ = app.on_event(demo.action_target(), fn(_ev) { hits = hits + 1 })
  // 真人点击的位置：命中的矩形就是 Core 刚摆过去的那个（0 = 点到了按钮）
  assert_eq(@libui-common.native_click_button_in_window(title, cx, cy), 0)
  // 空白处：布局矩形之外，不该有第二个可点的按钮
  assert_true(
    @libui-common.native_click_button_in_window(title, cx + 200, cy + 200) < 0,
  )
  assert_eq(@libui-common.native_request_window_close(title), 0)
  app.run()
  assert_true(demo.window().is_closed())
  assert_true(demo.status().is_closed())
  assert_eq(hits, 1)
  assert_eq(@libui-common.native_live_handles(), 0)
  assert_true(app.is_finished())
}

///|
/// §48 第 16 步的输入框链路，macOS 版：Core 把真输入框摆到它以为的矩形 → 脚手架按
/// **物理像素**中心命中它 → 焦点交给控件、让 field editor 自己 insertText:（AppKit
/// 处理键盘的那条路）→ libui 的 onChanged: → adapter 的槽位 → 后端读回**全文**入队
/// → App 派发成 `Input(target, 全文)`。
///
/// 这条测试真正的重点是后半截：Core 自己 `set_text` 之后不能再冒一条 Input。分得开
/// 靠的是 AppKit 那两个不同的入口——field editor 打字发 NSTextDidChangeNotification，
/// `setStringValue:` 不发（差异写在 adapter_macos.m 的 moonui_type_text_in_window 上）。
/// 把那一处换成 setStringValue: 的负控制实测过：脚手架照旧返回 0，但下一步
/// `app.step()` 拿到的是 `false`——链路真的断在"原生没报"这一环，不是后端自己造事件。
/// 事件里带的还是"打字那一刻"的全文，不是 Core 后来写进去的那条，这一条同时钉住
/// §48-16 的"通知只说变了、内容要回头问原生对象"是在入队时读的。
///
/// 和 Windows 那半**事件条数不一样是有意的**：这里整串一次 insertText:（相当于输入法
/// 成串上屏）只来一条，那边逐字符发 WM_CHAR、打 N 个码元来 N 条。分叉留在 C 和两边的
/// 测试里，MoonBit 侧读不出差别——那正是 T18 定下的形状。
///
/// 等待预算给 200ms 而不是长链路那条的 4000：原生通知在这台机器上是**同步**落进
/// MoonBit 队列的（insertText: 当场把回调跑完），要不要等只发生在"证明没有第二条"
/// 那一步，所以小预算是给那一步封顶，不是链路的一部分。
test "macOS 后端：真打字进 Input，程序改文案不回声" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  let title = "MoonUI macOS 输入框"
  let entry = @moonui.Widget::text_input(b, "初值")
  let content = @moonui.Widget::column(b, 16.0, [entry])
  let win = app.create_window(title, @moonui.LogicalSize::{
    width: 320.0,
    height: 240.0,
  })
  win.set_content(content)
  win.show()
  let spot = @moonui.Scale::to_physical_rect(win.scale(), entry.frame())
  let cx = spot.origin.x + spot.size.width / 2
  let cy = spot.origin.y + spot.size.height / 2
  let seen : Array[@moonui.Event] = []
  let target = entry.target()
  let _ = app.on_event(target, fn(ev) { seen.push(ev) })
  // 打在 Core 刚摆过去的那个矩形上：0 说明命中的确实是那只可编辑输入框
  assert_eq(
    @libui-common.native_type_text_in_window(title, cx, cy, "打字"),
    0,
  )
  // 同一段文字改由 Core 下发——这是"程序赋值"，不算用户打字
  entry.set_text("程序写入")
  // 空转到预算用完：用户打的那一段进来一次且仅一次，set_text 没有回声。
  // 不写成"step 一次然后队列空"，是因为焦点事件现在也可能在这一圈里冒出来
  // （见上面 input_texts），谁先回来不是这条测试要钉的事。
  while app.step() {

  }
  assert_eq(input_texts(seen), ["初值打字"])
  assert_eq(entry.text(), "程序写入")
  assert_eq(@libui-common.native_request_window_close(title), 0)
  assert_true(app.step())
  assert_false(app.step())
  assert_true(win.is_closed())
  assert_true(entry.is_closed())
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// §48 第 13 步的勾选链路，macOS 版：真勾选框 → 脚手架按 Core 算出的矩形命中它
/// （checkbox 在 AppKit 里也是 NSButton，所以点按钮那条脚手架原样能用）→
/// `performClick:` 翻勾选态并发 action → libui 的 onToggled → 槽位 → 后端入队
/// `Change(target)` → App 派发。
///
/// 勾选态本身不进事件（`Change` 只带 target），所以这条同时钉住"Core 事后读回来的
/// 是真值"——点完 `checked()` 必须翻。两次负控制：Core 程序改勾选不冒事件；
/// 矩形之外命不中第二个控件。
test "macOS 后端：真勾选进 Change，程序改勾选不回声" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  let title = "MoonUI macOS 勾选框"
  let check = @moonui.Widget::checkbox(b, "同意", false)
  let content = @moonui.Widget::column(b, 16.0, [check])
  let win = app.create_window(title, @moonui.LogicalSize::{
    width: 320.0,
    height: 240.0,
  })
  win.set_content(content)
  win.show()
  let spot = @moonui.Scale::to_physical_rect(win.scale(), check.frame())
  let cx = spot.origin.x + spot.size.width / 2
  let cy = spot.origin.y + spot.size.height / 2
  let seen : Array[@moonui.Event] = []
  let target = check.target()
  let _ = app.on_event(target, fn(ev) { seen.push(ev) })
  // 负控制一：Core 程序改勾选，不该冒 Change
  check.set_checked(true)
  while app.step() {

  }
  assert_eq(changes(seen), [])
  assert_true(check.checked())
  // 负控制二：Core 程序改勾选框的文案不该回声成 Change。"勾选框被程序改文案"这件事
  // 在这条之前一次都没跑过——上面那条四种属性往返只读不写勾选框的文本。mac 这边按钮
  // 与勾选框同为 NSButton，因此走 `setTitle:`（adapter_macos.m 的 `moonui_widget_set_text`
  // 那处分派），不需要
  // Windows 那层 `BS_TYPEMASK` 分派；排在真人点击之前只为了和那份同序同形。
  check.set_text("同意（已阅）")
  while app.step() {

  }
  assert_eq(changes(seen), [])
  assert_eq(check.text(), "同意（已阅）")
  // 真人点它：从 true 翻回 false
  assert_eq(@libui-common.native_click_button_in_window(title, cx, cy), 0)
  while app.step() {

  }
  assert_eq(changes(seen), [target])
  assert_false(check.checked())
  // 负控制三：布局矩形之外没有第二个可点的控件
  assert_true(
    @libui-common.native_click_button_in_window(title, cx + 200, cy + 200) < 0,
  )
  while app.step() {

  }
  assert_eq(changes(seen), [target])
  assert_eq(@libui-common.native_request_window_close(title), 0)
  assert_true(app.step())
  assert_false(app.step())
  assert_true(win.is_closed())
  assert_true(check.is_closed())
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 消息框与确认框（§24 / §48-18）的 macOS 版：`Backend` 的这两条从"如实报
/// Unsupported"换成真弹 AppKit 的 `NSAlert`（`T20` 那一轮）。
///
/// 对话框是同步阻塞的（`Backend::confirm` 要当场给答案），所以测试必须**先**把
/// "用户会按哪只按钮"安排好，否则这条测试就是永远回不来的：脚手架那发
/// `native_auto_dismiss_dialog` 在 NSAlert 的模态循环里挂一只定时器，到点按真按钮的
/// `performClick:`，于是 `runModal` 的返回值是原生对话框给的答案，不是脚手架编的。
///
/// 三个断言各钉一件事：
/// - 消息框：那段阻塞**真发生过**。空转的实现立刻返回，量不到那 300 毫秒的等待；
///   这是这条链上唯一能从外面看到的"面板确实弹了"的证据——`message` 返回 Unit，
///   用户的选择没有出口，所以用量钟，而不是回头读一遍 C 自己的状态。
/// - 确认框按第 0 只按钮 → `true`、按第 1 只 → `false`：Bool 跟着"用户按了哪只"
///   走，也就是跟着 NSAlert 的 modal 结果走。写死成任何一个值都会红。
/// - 句柄表归零：对话框不属于任何窗口，两条入口一个 MoonUI 句柄都不建。
test "macOS 后端：消息框与确认框真弹原生面板，答案是按钮给的" {
  let b = open_backend()
  b.init()
  // 消息框：300 毫秒之后替用户按下那唯一一只"确定"
  let t0 = @libui-common.native_time_ms()
  assert_eq(@libui-common.native_auto_dismiss_dialog(300, 0), 0)
  b.show_message("月 UI 的消息框", "正文")
  let blocked = @libui-common.native_time_ms() - t0
  assert_true(blocked >= 250)
  // 确认框：先按"是"（第 0 只），再按"否"（第 1 只）
  assert_eq(@libui-common.native_auto_dismiss_dialog(300, 0), 0)
  assert_true(b.confirm("月 UI 的确认框", "要继续吗？"))
  assert_eq(@libui-common.native_auto_dismiss_dialog(300, 1), 0)
  assert_false(b.confirm("月 UI 的确认框", "要继续吗？"))
  // 越界的 index 在"装"的那一步就报回来，不许留到运行时什么也按不下
  assert_eq(@libui-common.native_auto_dismiss_dialog(10, 2), -1)
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 文件面板（§24 / §48-18）的 macOS 版：`Backend` 的三条从"如实报 Unsupported"
/// 换成真弹 `NSOpenPanel` / `NSSavePanel`（`T21` 那一轮）。
///
/// 和上面消息框那条同一个前提：面板同步阻塞（`open_file` 要当场给路径），测试必须
/// **先**把"用户怎么答"安排好。macOS 15.6 上只安排得了"取消"这一种答案——面板跑在
/// 系统 XPC 服务里，客户端没有任何入口能替用户按 OK（证据链在 adapter.h 的
/// `moonui_auto_answer_file_dialog` 那段），所以这条测试钉的是：
///
/// - 三只面板都真弹了、真阻塞：每只之前先装"300 毫秒后取消"；并且那段阻塞**真发生
///   过**——空转的实现立刻返回，量不到这 300 毫秒。这是"面板确实弹了"在外面唯一量得
///   到的证据，和上面消息框那条同一个量法。
/// - 取消是面板自己的答案：C 把 `runModal` 给的 `NSModalResponseCancel` 映射成 0，
///   MoonBit 拿 `None`；这段映射之后是 `T44`（Windows 真跑）里"选了 → `Some(path)`"
///   的同一条路——那条在 mac 上无法自动化（ok: 是桩），断言不写在这里。
/// - 装"接受"在 mac 上当场报 -2；装"接受"却不给 path 报 -1（校验排在 -2 前面，和
///   Windows 同一条负控制）。两条都不弹面板，写错的脚手架红在断言上，不许挂住整轮。
///
/// 句柄表归零：面板不属于任何窗口，三条入口一个 MoonUI 句柄都不建。
test "macOS 后端：文件 / 保存 / 文件夹面板真弹出来，答案是取消" {
  let b = open_backend()
  b.init()
  // 打开文件
  let t0 = @libui-common.native_time_ms()
  assert_eq(@libui-common.native_auto_answer_file_dialog(300, "", false), 0)
  assert_eq(b.open_file("月 UI 的打开"), None)
  assert_true(@libui-common.native_time_ms() - t0 >= 250)
  // 保存文件
  let t1 = @libui-common.native_time_ms()
  assert_eq(@libui-common.native_auto_answer_file_dialog(300, "", false), 0)
  assert_eq(b.save_file("月 UI 的保存", "moonui-t21-save-probe.txt"), None)
  assert_true(@libui-common.native_time_ms() - t1 >= 250)
  // 选文件夹
  let t2 = @libui-common.native_time_ms()
  assert_eq(@libui-common.native_auto_answer_file_dialog(300, "", false), 0)
  assert_eq(b.select_folder("月 UI 的文件夹"), None)
  assert_true(@libui-common.native_time_ms() - t2 >= 250)
  // 替按接受在 mac 上做不到：非空 path 报 -2；空 path 的 -1 校验排在它前面
  assert_eq(
    @libui-common.native_auto_answer_file_dialog(300, "/bin/ls", true),
    -2,
  )
  assert_eq(@libui-common.native_auto_answer_file_dialog(300, "", true), -1)
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// Core 摆出去的那只矩形，中心点的物理像素坐标。点击、打字、挪焦点三条脚手架都按
/// 坐标命中，而不是"取第几只控件"——布局摆错了它们就命不中（理由见 adapter.h）。
fn phys_center(
  scale : @moonui.Scale,
  frame : @moonui.LogicalRect,
) -> (Int, Int) {
  let spot = @moonui.Scale::to_physical_rect(scale, frame)
  (spot.origin.x + spot.size.width / 2, spot.origin.y + spot.size.height / 2)
}

///|
/// §10/§26 的键盘这一半（`T39` 方案甲）：mac 侧造的是一条真 NSEvent 交给
/// `[NSApp sendEvent:]`（`adapter_macos.m` 的 moonui_send_key_in_window），于是进程内
/// 的 local monitor、"菜单收不收这一组"的判断、firstResponder 的后续处理全被真跑
/// 一遍——不是"把回调调一遍"。后端只收到"有颗键出事了"那一句，键名、修饰键、按下
/// 还是抬起、打在谁身上四样都当场读回去（§48-16 那一套）。
///
/// 四件事各钉一处：
/// - 一条按键 = 一条事件，一次且仅一次。这里连着发四组，抽干队列后就是四组，
///   不多一条：mac 的双响来源是"监听报一条、firstResponder 又报一条"，数条数就是
///   它的判据。下面那条 ⌘Q 钉的是被菜单收走的那一档，两条一起把"哪些组合算收走"
///   量出来（本机拿真 `[NSApp sendEvent:]` 测过：⌘Q 认领后视图的 `-keyDown:` 不再
///   运行，没带 Command 的 ⌃S 照旧落到视图上）。
/// - 归属：焦点在输入框上时 target 是那只输入框，不是窗口。中间还隔着一层共享的
///   field editor，所以这一条同时钉住"从 delegate 拿到被编辑的控件"那一档。
/// - 键名归一化在 C：脚手架收的是 Core 那套词（`"a"` / `"Enter"`），读回来也是那套
///   词。Enter 在 mac 是 0x24、在 Windows 是 VK_RETURN，物理键码一个都不许漏到
///   MoonBit 这边——`T39` 前面那条"mac 不认功能键"的分叉因此不进这条测试的夹具，
///   这里只用两边都认的键。
/// - 修饰键是一个字节（bit0 ctrl、bit1 alt、bit2 shift、bit3 meta），和 §25 装进
///   菜单的那一套同一个编码。这里给 ⌃⇧ = 5，写死成 1 或 4 都会在下一句红。
///
/// 词表外的键在派发之前就退回 -4、一条事件都不产：这一句同时钉 adapter.h 那六个
/// 返回码里"键不在词表里"的那一个。
///
/// 等待预算 200ms 和输入框那条同一个理由：通知在这台机器上是同步落进队列的，
/// 预算是给"证明没有多余那条"封顶，不是链路的一部分。
test "macOS 后端：真按键成 KeyDown/KeyUp，打在谁身上跟着焦点走" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  let title = "MoonUI macOS 键盘"
  let entry = @moonui.Widget::text_input(b, "")
  let content = @moonui.Widget::column(b, 16.0, [entry])
  let win = app.create_window(title, @moonui.LogicalSize::{
    width: 320.0,
    height: 240.0,
  })
  win.set_content(content)
  win.show()
  let (cx, cy) = phys_center(win.scale(), entry.frame())
  // 0 = 命中的是我们的控件，焦点已经交给它了。没有这一句，下面所有断言都可能红在
  // "事件没归属所以整条丢掉"上，而不是红在想钉的那一环。
  assert_eq(@libui-common.native_focus_widget_in_window(title, cx, cy), 0)
  let seen : Array[@moonui.Event] = []
  let target = entry.target()
  let _ = app.on_event(target, fn(ev) { seen.push(ev) })
  while app.step() {

  }
  let a = @moonui.KeyPress::{
    key: "a",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  assert_eq(@libui-common.native_send_key_in_window(title, "a", 0, true), 0)
  assert_eq(@libui-common.native_send_key_in_window(title, "a", 0, false), 0)
  while app.step() {

  }
  assert_eq(key_events(seen), [(target, a, true), (target, a, false)])
  // 特殊键走同一套词
  assert_eq(@libui-common.native_send_key_in_window(title, "Enter", 0, true), 0)
  while app.step() {

  }
  assert_eq(
    key_events(seen)[2],
    (
      target,
      @moonui.KeyPress::{
        key: "Enter",
        ctrl: false,
        alt: false,
        shift: false,
        meta: false,
      },
      true,
    ),
  )
  // ⌃⇧s：bit0 + bit2
  assert_eq(@libui-common.native_send_key_in_window(title, "s", 5, true), 0)
  while app.step() {

  }
  assert_eq(
    key_events(seen)[3],
    (
      target,
      @moonui.KeyPress::{
        key: "s",
        ctrl: true,
        alt: false,
        shift: true,
        meta: false,
      },
      true,
    ),
  )
  assert_eq(key_events(seen).length(), 4)
  // 词表外的键：-4，而且队列里一条都不许多
  assert_eq(@libui-common.native_send_key_in_window(title, "§", 0, true), -4)
  while app.step() {

  }
  assert_eq(key_events(seen).length(), 4)
  assert_eq(@libui-common.native_request_window_close(title), 0)
  while app.step() {

  }
  assert_true(win.is_closed())
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 菜单认领的组合不双响（`T39` 的 mac 特有那一半）：装了 keyEquivalent 的项 AppKit
/// 自己在 `sendEvent:` 里派发掉，监听要是照样报一颗 KeyDown，同一个 ⌘Q 的处理函数就
/// 跑两遍。压掉的是按下和抬起两条——只压一条的话 Core 收到一条没有配对的 KeyUp。
///
/// 这条的判据是"只有一条 MenuSelect，一条键事件都没有"，而末尾那一句"紧接着的普通
/// 键照旧成一条 KeyDown"是这条测试自己的负控制：如果 ⌘Q 那一步把整条监听弄哑了（或者
/// 这个窗口的键根本没有归属，`moonui_on_key` 在 `target == 0` 处就 return 了），
/// 上面两句都会"因为什么都没收到"而绿，而末尾那句立刻红。
///
/// 菜单项的 target 是 `EventTarget::{ id: 0 }`：§25 的编号空间和窗口/控件句柄是两个
/// 独立空间，靠变体本身区分（event.mbt）。夹具就是菜单栏那条测试用的那一棵，⌘Q 挂在
/// 0 号 Quit 上——libui 自己那棵默认应用菜单的 Quit 没有 keyEquivalent（实测过），
/// 所以这里按下的 ⌘Q 不会被工具链拿去退出进程。
test "macOS 后端：菜单认领的 ⌘Q 只回一条 MenuSelect，不双响成 KeyDown" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  app.set_menubar(menu_fixture())
  let title = "MoonUI macOS 菜单收键"
  let entry = @moonui.Widget::text_input(b, "")
  let content = @moonui.Widget::column(b, 16.0, [entry])
  let win = app.create_window(title, @moonui.LogicalSize::{
    width: 320.0,
    height: 240.0,
  })
  win.set_content(content)
  win.show()
  let (cx, cy) = phys_center(win.scale(), entry.frame())
  assert_eq(@libui-common.native_focus_widget_in_window(title, cx, cy), 0)
  let seen : Array[@moonui.Event] = []
  let quit = @moonui.EventTarget::{ id: 0, }
  let _ = app.on_event(quit, fn(ev) { seen.push(ev) })
  let _ = app.on_event(entry.target(), fn(ev) { seen.push(ev) })
  while app.step() {

  }
  assert_eq(@libui-common.native_send_key_in_window(title, "q", 8, true), 0)
  assert_eq(@libui-common.native_send_key_in_window(title, "q", 8, false), 0)
  while app.step() {

  }
  assert_eq(menu_selects(seen), [quit])
  assert_eq(key_events(seen), [])
  // 监听还活着：没被认领的 ⌃s 照旧成一条 KeyDown（写成 ⌘s 就又撞上认领那一档，
  // 那句话就不是这一句了）
  assert_eq(@libui-common.native_send_key_in_window(title, "s", 1, true), 0)
  while app.step() {

  }
  assert_eq(key_events(seen), [
    (
      entry.target(),
      @moonui.KeyPress::{
        key: "s",
        ctrl: true,
        alt: false,
        shift: false,
        meta: false,
      },
      true,
    ),
  ])
  assert_eq(menu_selects(seen).length(), 1)
  assert_eq(@libui-common.native_request_window_close(title), 0)
  while app.step() {

  }
  assert_true(win.is_closed())
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// §32 的焦点这一半（`T39` 方案甲的另一半）：焦点没有回调，后端每圈事件循环问一次
/// `native_focused_control`，只在和上一圈不一样时发事件。"连着抽三圈什么新事件都不冒"
/// 是这套轮询唯一的形状，也是它和"每次 poll 都抄一遍原生焦点"的差别——后者会把
/// `Focus` 刷成一条不停的消息。
///
/// 为什么用两只输入框：输入框中间隔着一层共享的 field editor，`moonui_focused_control`
/// 要能从 firstResponder 退到"被编辑的那只控件"，焦点这一半和按键那一半靠的是同一档
/// 判断（`adapter_macos.m` 的 moonui_responder_owner），所以这里顺手把它钉住。
///
/// 五步各钉一件事：
/// - 第一步（焦点给第二只输入框）只钉"最后停在谁身上"：`win.show()` 之后 AppKit 自己
///   会定一只 initialFirstResponder，可能就是这两只里的一只，那一条不属于这一步的账
///   （见 `focus_new` 的注释）。
/// - 第二步起表已经落定了，所以是精确的差异比对：`Blur(旧的)` 在 `Focus(新的)` 之前，
///   两条都在，顺序不能反（§32 的"先告别再欢迎"）。
/// - 第三步把焦点给回已经拿着它的那只：一条都不许多。写错成"每次问都发"在这里红。
/// - 第四步焦点给 label：一条 Blur、**零条** Focus，脚手架报 -4。这一条钉的是本机实测的
///   一件事——`makeFirstResponder:` 对 label 返回 YES，可 firstResponder 顺着 responder
///   chain 落回窗口自己，"原生答应了"不等于"焦点到了我们控件上"。所以脚手架的判据是
///   回读（和 `native_focused_control` 同一个），adapter.h 里 mac 独有的 -5 因此删掉：
///   "是我们的控件但拿不了焦点"和"命中的不是我们的控件"在回读下分不出来，也就和
///   Windows 的禁用控件共用 -4。§32 的 `focused` 读的因此是原生真相。
/// - 第五步关掉窗口：不留一条尾巴上的 `Blur`。焦点表按 `live_windows` 重建，销毁的
///   窗口整个从表里掉出去（Core 本来也不给关掉的窗口派发，§12）。
///
/// 中间那三条失败形态各钉一个返回码（-3 命不中子控件、-4 命中的不是我们的控件、
/// -2 没有这只窗口），而且抽干之后焦点表一条都不许多：失败的那几次焦点根本没动。
test "macOS 后端：改焦点出恰好一条 Focus，挪走补一条 Blur，不再改就不多冒" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  let title = "MoonUI macOS 焦点"
  let first = @moonui.Widget::text_input(b, "第一只")
  let second = @moonui.Widget::text_input(b, "第二只")
  let note = @moonui.Widget::label(b, "这只也拿得到")
  let content = @moonui.Widget::column(b, 16.0, [first, second, note])
  let win = app.create_window(title, @moonui.LogicalSize::{
    width: 320.0,
    height: 240.0,
  })
  win.set_content(content)
  win.show()
  let (fx, fy) = phys_center(win.scale(), first.frame())
  let (sx, sy) = phys_center(win.scale(), second.frame())
  let (nx, ny) = phys_center(win.scale(), note.frame())
  let seen : Array[@moonui.Event] = []
  let _ = app.on_event(first.target(), fn(ev) { seen.push(ev) })
  let _ = app.on_event(second.target(), fn(ev) { seen.push(ev) })
  let _ = app.on_event(note.target(), fn(ev) { seen.push(ev) })
  while app.step() {

  }
  let mut from = focus_events(seen).length()
  // 一、焦点给第二只输入框
  assert_eq(@libui-common.native_focus_widget_in_window(title, sx, sy), 0)
  while app.step() {

  }
  let now = focus_events(seen)
  assert_eq(now[now.length() - 1], ("+", second.target()))
  from = now.length()
  // 二、挪回第一只：先 Blur 再 Focus，两条都在且顺序不反
  assert_eq(@libui-common.native_focus_widget_in_window(title, fx, fy), 0)
  while app.step() {

  }
  assert_eq(focus_new(seen, from), [
    ("-", second.target()),
    ("+", first.target()),
  ])
  from = focus_events(seen).length()
  // 三、再"给"一次已经拿着它的那只：什么都不许冒
  assert_eq(@libui-common.native_focus_widget_in_window(title, fx, fy), 0)
  while app.step() {

  }
  while app.step() {

  }
  assert_eq(focus_new(seen, from), [])
  // 四、焦点给 label：脚手架报 -4，表里只冒一条 Blur。本机实测的是"原生答应了"和
  // "焦点真到了我们控件上"是两件事——`makeFirstResponder:` 对 label 返回 YES，可
  // firstResponder 顺着 responder chain 落回窗口自己，所以判据换成回读之后这里红过。
  assert_eq(@libui-common.native_focus_widget_in_window(title, nx, ny), -4)
  while app.step() {

  }
  assert_eq(focus_new(seen, from), [("-", first.target())])
  from = focus_events(seen).length()
  // 三条失败形态各钉一个返回码，都是"焦点没动"：命不中子控件（客户区之外）、
  // 命中的不是我们的控件（窗口里的空白处）、根本没有这只窗口。
  // 空白处那一点取客户区左下角往上 4 像素：列只占上面那一截，这里没有控件。
  let phys = win.scale().to_physical_size(win.size())
  assert_eq(
    [
      @libui-common.native_focus_widget_in_window(title, fx + 4000, fy),
      @libui-common.native_focus_widget_in_window(title, 4, phys.height - 4),
      @libui-common.native_focus_widget_in_window("没有这只窗口", 5, 5),
    ],
    [-3, -4, -2],
  )
  while app.step() {

  }
  assert_eq(focus_new(seen, from), [])
  // 五、关窗口：尾巴上不留 Blur
  assert_eq(@libui-common.native_request_window_close(title), 0)
  while app.step() {

  }
  assert_true(win.is_closed())
  assert_eq(focus_new(seen, from), [])
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}
