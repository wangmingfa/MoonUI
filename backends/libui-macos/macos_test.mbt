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
/// 用过的后端，等着被清场收掉。
///
/// 句柄表是**进程全局**的：../libui-common/ffi.mbt:17 那个 `let handles` 和 `LibuiBackend` 实例
/// 无关，而 `Backend::terminate` 只收实例自己记着的 `live_widgets`/`live_windows`
/// （../libui-common/backend.mbt:158）。一条测试在断言处失败时，MoonBit 的 panic 不跑 `defer`
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
/// 后端也在这张表里，对它们是空转：两个数组在 terminate 里清空（../libui-common/backend.mbt:169），
/// libui 也已经 uninit，而 adapter 的 moonui_terminate 在没 inited 时直接返回
/// （adapter_macos.m:352）。
///
/// 为什么收的是"后端"而不是"句柄"：只有实例自己分得清哪只句柄是控件、哪只是
/// 窗口，而"先控件后窗口"是 uiUninit 分配审计的硬要求（../libui-common/backend.mbt:153-157）——
/// 在测试里按种类再数一遍，就是抄一份会腐烂的副本。
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
  // backend.mbt 的 system_theme 是共享实现，如实报告 Light（§16 的外观 API 还没接）
  assert_eq(b.system_theme(), @moonui.Light)
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
/// 层叠的数法。Windows 那份的读数是 [0,1,2] 和 [2,1,0]（backend_wbtest.mbt:246），
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
/// 跑一次预期失败的后端调用，把错误消息记进日志。和 Windows 那份
/// `capture_unsupported`（backend_wbtest.mbt:160）同形，返回值一律 `let _ =` 丢掉：
/// 这条测试关心的是"以什么形态失败"。
fn capture_unsupported(
  cases : Array[String],
  label : String,
  body : () -> Unit raise @moonui.UiError,
) -> Unit {
  let msg = try {
    body()
    "没有报错"
  } catch {
    e => @moonui.UiError::message(e)
  }
  cases.push(label + " -> " + msg)
}

///|
/// §48-18/19/20 那三步还没做，八个能力在 Cocoa 上如实报 Unsupported。
///
/// 抛出它们的代码是共享的 `backend.mbt`——本包直接导入它，自己目录里没有第二份，
/// 所以 Windows 报什么 mac 就报什么。文案因此不许带平台名字（原先那句"剪贴板要
/// Win32 OpenClipboard"会原样抛到 mac 上）。下面八条和 Windows 那份断言
/// （backend_wbtest.mbt:211）逐字相同，两份各钉一边：改文案要三处一起动
/// （raise 处 + 这两份），漏一处就红一条。
///
/// 这条同时也钉住"文案中立不等于假装成功"：`没有报错` 那一路一旦走到就红。
test "macOS 后端：剪贴板 / 对话框 / 文件选择 / 菜单如实报不支持" {
  let b = open_backend()
  b.init()
  let cases : Array[String] = []
  capture_unsupported(cases, "剪贴板读", fn() raise @moonui.UiError {
    let _ = b.clipboard_text()
  })
  capture_unsupported(cases, "剪贴板写", fn() raise @moonui.UiError {
    b.set_clipboard_text("月")
  })
  capture_unsupported(cases, "消息框", fn() raise @moonui.UiError {
    b.show_message("标题", "正文")
  })
  capture_unsupported(cases, "确认框", fn() raise @moonui.UiError {
    let _ = b.confirm("标题", "正文")
  })
  capture_unsupported(cases, "打开文件", fn() raise @moonui.UiError {
    let _ = b.open_file("标题")
  })
  capture_unsupported(cases, "保存文件", fn() raise @moonui.UiError {
    let _ = b.save_file("标题", "a.txt")
  })
  capture_unsupported(cases, "选文件夹", fn() raise @moonui.UiError {
    let _ = b.select_folder("标题")
  })
  capture_unsupported(cases, "菜单栏", fn() raise @moonui.UiError {
    b.set_menu_bar(@moonui.MenuBar::new([]))
  })
  assert_eq(cases, [
    "剪贴板读 -> 不支持的操作：剪贴板还没接（§48-18）", "剪贴板写 -> 不支持的操作：剪贴板还没接（§48-18）",
    "消息框 -> 不支持的操作：对话框还没接（§48-19）", "确认框 -> 不支持的操作：对话框还没接（§48-19）",
    "打开文件 -> 不支持的操作：文件选择还没接（§48-19）", "保存文件 -> 不支持的操作：文件选择还没接（§48-19）",
    "选文件夹 -> 不支持的操作：文件夹选择还没接（§48-19）",
    "菜单栏 -> 不支持的操作：菜单栏还没接（§48-20）",
  ])
  // 八条都没建成任何原生对象，句柄表照旧该归零
  assert_eq(@libui-common.native_live_handles(), 0)
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
  assert_true(app.step())
  assert_eq(seen, [@moonui.Input(target, "初值打字")])
  // 空转到预算用完：set_text 没有回声
  assert_false(app.step())
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
  assert_false(app.step())
  assert_true(check.checked())
  // 负控制二：Core 程序改勾选框的文案不该回声成 Change。"勾选框被程序改文案"这件事
  // 在这条之前一次都没跑过——上面那条四种属性往返只读不写勾选框的文本。mac 这边按钮
  // 与勾选框同为 NSButton，因此走 `setTitle:`（`adapter_macos.m:644~646`），不需要
  // Windows 那层 `BS_TYPEMASK` 分派；排在真人点击之前只为了和那份同序同形。
  check.set_text("同意（已阅）")
  assert_false(app.step())
  assert_eq(check.text(), "同意（已阅）")
  // 真人点它：从 true 翻回 false
  assert_eq(@libui-common.native_click_button_in_window(title, cx, cy), 0)
  assert_true(app.step())
  assert_eq(seen, [@moonui.Change(target)])
  assert_false(check.checked())
  // 负控制三：布局矩形之外没有第二个可点的控件
  assert_true(
    @libui-common.native_click_button_in_window(title, cx + 200, cy + 200) < 0,
  )
  assert_false(app.step())
  assert_eq(@libui-common.native_request_window_close(title), 0)
  assert_true(app.step())
  assert_false(app.step())
  assert_true(win.is_closed())
  assert_true(check.is_closed())
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}
