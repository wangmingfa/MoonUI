///|
/// `Backend` 契约在 libui-ng 真后端上的验证（§48 第 09~11 步，§37 第三层的真实版）。
///
/// 这些测试会真的开窗口：契约里"读回来的是原生层的真实值"这一条，只有真窗口
/// 能证明——mock 后端永远会把刚写进去的数原样吐回来，量不出换算有没有错。
///
/// 只有最后一条会推进消息循环（其余都是属性读写，不阻塞）。带 App 的那条
/// 用 `for_testing` 的有限等待预算，链路断了就测试失败，不会挂住 CI。

///|
/// 逻辑尺寸往返的容差：物理取整（宽高原方向向上、原点向下）最多让一个方向差 1 像素。
fn close_to(a : Double, b : Double) -> Bool {
  let d = a - b
  d < 1.0 && d > -1.0
}

///|
/// 用过的后端，等着被清场收掉。形状抄 `backends/libui-macos/macos_test.mbt` 的
/// `backends_in_play` + `sweep_leaked_handles` + `open_backend`（同一套解法，两边各一份）。
///
/// 句柄表是**进程全局**的：`../libui-common/ffi.mbt:17` 那个 `let handles` 和
/// `LibuiBackend` 实例无关，而 `Backend::terminate` 只收实例自己记着的
/// `live_widgets`/`live_windows`（`../libui-common/backend.mbt:158`）。MoonBit native
/// 的 panic 不执行 `defer`，所以一条测试在断言
/// 处失败时，它建的窗口和控件连着那个实例一起留在表上。
///
/// Windows 上这一漏的后果比 mac 上记的更硬：不是"后面每条跟着红"，而是下一条走到
/// `terminate()` 的测试直接死在 `uiUninit` 的分配审计上（`adapter.c:338-341` 的
/// DebugBreak），整个测试进程以 `0x80000003` 退出，而 native 的 println 是全缓冲的，
/// 于是一条测试输出都留不下来。本机实测（注入一条断言失败且漏一只窗口的测试）：
/// `moon test backends/libui-windows` → `exited with exit code: 0x80000003`，
/// `-i 0-2`（注入的那条 + 紧挨着的下一条）同样 abort，
/// 而 `-i 1-2`（只跑下一条）是 `Total tests: 1, passed: 1, failed: 0.`。
/// 所以每条测试开头替上一条把收尾补跑一遍（见 `open_backend` / `begin_native_session`）。
///
/// 这三张表是本包测试的私有物。两个 wbtest 文件在同一个命名空间里（`ffi_wbtest.mbt`
/// 直接调用这里的 `sweep_leaked_handles`），但**每个 wbtest 文件各产一份测试二进制**：
/// 包级 `let` 在两份二进制里各有一个副本，跨文件共享的是名字不是状态（本机
/// 0.1.20260920 实测：一个文件往包级 Array 里 push，另一个文件的测试读到的仍是空）。
/// 所以 Windows 这半是两份测试二进制各自清场、互不相干，不存在"backend 那半的表替
/// ffi 那半收尾巴"这回事——原先这里写的正是那句错话，目录改名时顺手量出来的。将来再
/// 加第三份真窗口测试文件时，它的 prologue 也得接上同一套清场，否则那一头的泄漏照样
/// 穿过文件边界。
let backends_in_play : Array[@libui-common.LibuiBackend] = []

///|
/// `ffi_wbtest.mbt` 那 6 条不建后端实例，直接调 `native_*`，所以"按实例收"那一半
/// 搬不过去：这里按种类记两张表。分种类不是洁癖——`adapter.c` 的 `moonui_release_slot`
/// 循环不分种类，而 `uiUninit` 的分配审计要求**控件先于窗口**（`../libui-common/backend.mbt:153-157`），
/// 所以清场不能只靠"把表倒出来挨个销毁"。
let native_widgets_in_play : Array[@moonui.NativeHandle] = []

///|
/// 见 `native_widgets_in_play`。
let native_windows_in_play : Array[@moonui.NativeHandle] = []

///|
/// 清掉上一条失败时漏下的原生对象，让这一条从空的句柄表开始。已经自己收过尾的后端
/// 和句柄也在这几张表里，对它们是空转：`terminate` 末尾会清空自己的两个数组
/// （`../libui-common/backend.mbt:169`），`native_*_destroy` 撞上过期句柄就报错并被丢掉
/// （`handle.mbt:83-95`：id 会复用，但 generation 递增，旧句柄不会命中新对象），
/// 而 `moonui_terminate` 在没 inited 时直接返回（`adapter.c:334`）。
///
/// 顺序是**先裸句柄、后后端**：每个后端实例的 `terminate` 末尾都有一次
/// `native_terminate` → `uiUninit`，那一步要求所有控件和窗口此刻已经销毁，
/// 所以别处漏下的裸句柄必须先收掉，否则清场自己就会踩上同一个 DebugBreak。
fn sweep_leaked_handles() -> Unit {
  let leaked_native = native_widgets_in_play.length() > 0 ||
    native_windows_in_play.length() > 0
  let leaked_backends = backends_in_play.length()
  for h in native_widgets_in_play {
    @libui-common.native_widget_destroy(h) catch {
      _ => ()
    }
  }
  for h in native_windows_in_play {
    @libui-common.native_window_destroy(h) catch {
      _ => ()
    }
  }
  native_widgets_in_play.clear()
  native_windows_in_play.clear()
  for b in backends_in_play {
    b.terminate()
  }
  backends_in_play.clear()
  // 只漏了裸句柄时（没有后端实例替我们走 uninit），补一次 terminate：
  // C 侧的回调槽位是有限的（`ffi.mbt` 的"回调槽位已用满"），只有 terminate 会松开它们。
  if leaked_native && leaked_backends == 0 {
    @libui-common.native_terminate()
  }
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
/// `open_backend` 的有限等待预算版（对应 `LibuiBackend::for_testing`）。
fn open_backend_for_testing(wait_budget_ms : Int) -> @libui-common.LibuiBackend {
  sweep_leaked_handles()
  let b = @libui-common.LibuiBackend::for_testing(wait_budget_ms)
  backends_in_play.push(b)
  b
}

///|
test "未初始化的真后端拒绝创建对象" {
  let b = open_backend()
  let msg = try {
    let _ = b.create_window("MoonUI 未初始化", @moonui.LogicalSize::{
      width: 100.0,
      height: 80.0,
    })
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(msg, Some("UI 初始化失败：Backend 尚未初始化"))
  // 初始化成功一次再收尾，确认这一对是幂等的（libui 的 init 是进程级单例）
  b.init()
  b.terminate()
  b.terminate()
}

///|
/// 窗口属性往返：写进去的是逻辑像素，读回来也必须是逻辑像素，
/// 中间那一层物理像素只有 adapter 看得见（§30）。
test "窗口几何、缩放与屏幕信息在真后端上往返" {
  let b = open_backend()
  b.init()
  let win = b.create_window("MoonUI 窗口几何", @moonui.LogicalSize::{
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
  b.set_window_title(win, "MoonUI 窗口几何 — 改名")
  b.set_window_resizable(win, false)
  b.hide_window(win)
  b.show_window(win)
  // 屏幕信息给 Window::center 用：非零、且缩放因子已经除掉
  let screen = b.screen_size()
  assert_true(screen.width > 100.0 && screen.height > 100.0)
  // libui-ng 的 Windows 后端没有系统外观 API，这里如实报告 Light（§16）
  assert_eq(b.system_theme(), @moonui.Light)
  b.destroy_window(win)
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 控件属性与矩形往返。`create_widget` 建的对象一出生挂在 libui 的隐藏工具窗口
/// 下，所以可见性要等 attach + 窗口 show 之后才是 true。
test "控件属性、矩形与固有尺寸在真后端上往返" {
  let b = open_backend()
  b.init()
  let win = b.create_window("MoonUI 控件往返", @moonui.LogicalSize::{
    width: 320.0,
    height: 240.0,
  })
  let btn = b.create_widget(@moonui.Button, "确定")
  let label = b.create_widget(@moonui.Label, "说明")
  let entry = b.create_widget(@moonui.TextInput, "初值")
  let check = b.create_widget(@moonui.Checkbox, "同意")
  b.attach_widget(win, btn)
  b.set_widget_bounds(btn, @moonui.LogicalRect::{
    origin: @moonui.LogicalPoint::{ x: 6.0, y: 8.0, },
    size: @moonui.LogicalSize::{ width: 140.0, height: 34.0, },
  })
  b.attach_widget(win, label)
  b.attach_widget(win, entry)
  b.attach_widget(win, check)
  b.show_window(win)
  let rect = b.widget_bounds(btn)
  assert_true(close_to(rect.origin.x, 6.0))
  assert_true(close_to(rect.origin.y, 8.0))
  assert_true(close_to(rect.size.width, 140.0))
  assert_true(close_to(rect.size.height, 34.0))
  assert_eq(b.widget_text(btn), "确定")
  b.set_widget_text(btn, "已确认")
  assert_eq(b.widget_text(btn), "已确认")
  assert_eq(b.widget_text(entry), "初值")
  assert_eq(b.widget_text(label), "说明")
  assert_false(b.widget_checked(check))
  b.set_widget_checked(check, true)
  assert_true(b.widget_checked(check))
  assert_true(b.widget_visible(entry))
  b.set_widget_visible(entry, false)
  assert_false(b.widget_visible(entry))
  assert_true(b.widget_enabled(entry))
  b.set_widget_enabled(entry, false)
  assert_false(b.widget_enabled(entry))
  // 固有尺寸来自 libui 的测量：宽度随文案变，且不为零（§18 不让 Core 猜字体）
  let short = b.widget_intrinsic_size(label)
  b.set_widget_text(label, "说明说明说明说明")
  let long = b.widget_intrinsic_size(label)
  assert_true(short.width > 0.0 && short.height > 0.0)
  assert_true(long.width > short.width)
  // §15/§16 的样式下发在真后端上是**有意不生效**的（豁免写在 backend.mbt）：
  // 可调用、不报错，而且推个大字号之后 libui 报的度量一个像素都不变。
  // 这条断言钉的就是"不生效"这一半——只测不抛等于什么都没测。
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
/// §48 的里程碑要求"关闭后句柄表归零"，这里连 handler 失败的路径一起验：
/// terminate 必须自己把没销毁的控件和窗口扫干净，否则 uiUninit 的分配审计
/// 会把测试进程挂死在 DebugBreak 上。
test "terminate 扫掉遗留对象，退出后句柄表归零" {
  let b = open_backend()
  b.init()
  let _ = b.create_window("MoonUI 遗留清理", @moonui.LogicalSize::{
    width: 120.0,
    height: 90.0,
  })
  let _ = b.create_widget(@moonui.Button, "没人销毁我")
  assert_eq(@libui-common.native_live_handles(), 2)
  b.terminate()
  assert_eq(@libui-common.native_live_handles(), 0)
}

///|
/// 跑一次预期失败的后端调用，把错误消息记进日志。
/// 返回值一律 `let _ =` 丢掉：这条测试关心的是"以什么形态失败"，不是成功时给什么。
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
/// §48-18/19/20 那三步还没做，八个能力如实报 Unsupported。
/// 这条测试钉住的是"不许用空实现假装成功"——真跑 Demo 时报错比静默无事好。
///
/// 下面八条字符串和 macOS 那份 `macos_test.mbt` 里
/// `test "macOS 后端：剪贴板 / 对话框 / 文件选择 / 菜单如实报不支持"` 逐字相同。
/// 抛出它们的实现是共享的 `backend.mbt`（macOS 后端包直接导入它，自己目录里没有
/// 第二份），所以两个后端各钉一遍：改文案要三处一起动（raise 处 + 这两份断言），
/// 漏一处就红一条。
test "剪贴板 / 对话框 / 菜单在真后端上明确报不支持" {
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
  b.terminate()
}

///|
/// 没有存活窗口时 poll_event 立刻收尾（真实 GUI 的"用户把所有窗口都关了"），
/// 以及 libui 主循环结束时（WM_QUIT）也收尾。两条都不靠等待预算兜底。
test "poll_event 的两个终止条件：没有窗口、主循环结束" {
  let b = open_backend()
  b.init()
  assert_eq(b.poll_event(), None)
  let win = b.create_window("MoonUI 循环终止", @moonui.LogicalSize::{
    width: 100.0,
    height: 80.0,
  })
  // 无限预算 + 有存活窗口，只有 WM_QUIT 能让它回来
  @libui-common.native_quit()
  assert_eq(b.poll_event(), None)
  // 已经知道循环结束了，再来一次也不等
  assert_eq(b.poll_event(), None)
  b.destroy_window(win)
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// §48-15：层叠的两个方向，断言的是**具体数字**。
///
/// mock 的顺序是 MoonUI 自己实现的，真后端的顺序是 Win32 给的；只有把后者钉死，
/// Core 那条 `apply_layers` 才算真落过地。两条一起测才看得出方向错：
/// 挂载是 `SetWindowPos(HWND_BOTTOM)`，所以先挂的在上层、数组顺序即 z-order 从顶到底；
/// raise 是 `HWND_TOP`，所以 Stack 按数组顺序提完之后正好倒过来。
test "层叠的两个方向在真窗口上：挂载压底、raise 提顶" {
  let b = open_backend()
  b.init()
  let row_win = @moonui.Window::new(b, "MoonUI 层叠-挂载", @moonui.LogicalSize::{
    width: 240.0,
    height: 180.0,
  })
  let first = @moonui.Widget::label(b, "Ab")
  let second = @moonui.Widget::label(b, "Abcd")
  let third = @moonui.Widget::label(b, "A")
  row_win.set_content(@moonui.Widget::row(b, 6.0, [first, second, third]))
  assert_eq(z_indices([first, second, third]), [0, 1, 2])
  row_win.close()

  let stack_win = @moonui.Window::new(b, "MoonUI 层叠-叠放", @moonui.LogicalSize::{
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
/// 控件在真窗口子窗口列表里的位置，0 = 最上层。
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
/// §48 的完整链路，真后端版：真窗口显示 → 按 Core 算出的矩形命中真按钮 →
/// 原生回调进队列 → App 派发给 Demo 的 handler → 文案改变 → 真关闭 →
/// 窗口和内容一起回收 → 句柄表归零。
///
/// 点击和关闭都发生在 `run()` 之前：点击是同步的（BM_CLICK 直接把回调跑完，
/// 事件留在队列里），关闭是 PostMessage 一条 WM_CLOSE。`run()` 要做的只是
/// 把这两条取出来派发——这正是 §10 的 Event First。
test "真后端跑完整事件循环：真点击改文案，真关闭收尾" {
  let b = open_backend_for_testing(4000)
  let app = @moonui.App::new(b)
  b.init()
  let demo = @moonui.Demo::hello(app)
  let title = "MoonUI"
  assert_eq(demo.status().text(), "Hello MoonUI")
  assert_eq(@libui-common.native_live_handles(), 3)
  // 窗口标题唯一性由上一个 assert 之外保证：Demo 用固定标题 "MoonUI"
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
/// §48 第 16 步的输入框链路，Windows 版：Core 把真输入框摆到它以为的矩形 → 脚手架按
/// **物理像素**中心命中类名是 "Edit" 的那只子窗口 → 先把插入点放到文末、再逐字符
/// SendMessage(WM_CHAR) → EDIT 自己改内容并向父窗口发 WM_COMMAND/EN_CHANGE →
/// libui 的 onWM_COMMAND（windows/entry.cpp:12）报给我们 → 后端读回全文入队 →
/// App 派发成 `Input(target, 全文)`。
///
/// 和 macOS 那半**事件条数不一样是有意的**：这边一个字符一条 EN_CHANGE（打 N 个码元
/// 来 N 条，真键盘就这样），macOS 那份把整串一次 insertText:（相当于输入法成串上屏）
/// 只来一条。分叉留在 C 和两边的测试里，MoonBit 侧读不出差别——那正是 T18 定下的形状。
///
/// 后半截是这条测试的重点：Core 自己 `set_text` 之后不能再冒 Input。Windows 上这一条
/// 是 libui 替我们做到的——`uiEntrySetText` 先立 `inhibitChanged` 再 SetWindowText
/// （windows/entry.cpp:68-75），所以 EN_CHANGE 被吞掉，回调根本不会响。事件里带的还是
/// "打字那一刻"的全文，同时钉住 §48-16 的"通知只说变了、内容要回头问原生对象"。
test "真后端：真打字逐条进 Input，程序改文案不回声" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  let title = "MoonUI 输入框事件"
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
  // 打在 Core 刚摆过去的那个矩形上：0 说明命中的确实是那只编辑框
  assert_eq(
    @libui-common.native_type_text_in_window(title, cx, cy, "打字"),
    0,
  )
  // 同一段文字改由 Core 下发——uiEntrySetText 自己把 EN_CHANGE 抑制了
  entry.set_text("程序写入")
  // 两个字符两条通知，每条带的是当时读回的全文
  assert_true(app.step())
  assert_true(app.step())
  assert_eq(seen, [
    @moonui.Input(target, "初值打"),
    @moonui.Input(target, "初值打字"),
  ])
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
/// §48 第 13 步的勾选链路，Windows 版：真勾选框 → 脚手架按 Core 算出的矩形命中它
/// （勾选框的窗口类名也是 "Button"，所以点按钮那条脚手架原样能用）→ BM_CLICK →
/// WM_COMMAND/BN_CLICKED → libui 的 onWM_COMMAND（windows/checkbox.cpp:12：它自己
/// 翻 BM_SETCHECK，因为没用 BS_AUTOCHECKBOX）报给我们 → 后端入队 `Change(target)`。
///
/// 勾选态不进事件（`Change` 只带 target），所以这条同时钉住"Core 事后读回来的是真值"
/// ——点完 `checked()` 必须翻。两次负控制：Core 程序改勾选不冒事件；矩形之外命不中
/// 第二个控件。
test "真后端：真勾选进 Change，程序改勾选不回声" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  let title = "MoonUI 勾选框事件"
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
  // 负控制一：Core 程序改勾选（BM_SETCHECK 不发 BN_CLICKED），不该冒 Change
  check.set_checked(true)
  assert_false(app.step())
  assert_true(check.checked())
  // 真人点它：从 true 翻回 false
  assert_eq(@libui-common.native_click_button_in_window(title, cx, cy), 0)
  assert_true(app.step())
  assert_eq(seen, [@moonui.Change(target)])
  assert_false(check.checked())
  // 负控制二：Core 程序改勾选框的文案不该回声成 Change。Windows 上这一句还是唯一
  // 走到 `uiCheckboxSetText` 的测试——勾选框的窗口类名与按钮同为 L"button"
  // （`checkbox.cpp:106-108`），分派要是认错人，文案就跑到别的 HWND 上，而那只有
  // 读回来才看得见，别的断言一个都不会红。
  check.set_text("同意（已阅）")
  assert_false(app.step())
  assert_eq(check.text(), "同意（已阅）")
  assert_eq(seen, [@moonui.Change(target)])
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
