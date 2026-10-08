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
test "未初始化的真后端拒绝创建对象" {
  let b = LibuiBackend::new()
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
  let b = LibuiBackend::new()
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
  assert_eq(native_live_handles(), 0)
  b.terminate()
}

///|
/// 控件属性与矩形往返。`create_widget` 建的对象一出生挂在 libui 的隐藏工具窗口
/// 下，所以可见性要等 attach + 窗口 show 之后才是 true。
test "控件属性、矩形与固有尺寸在真后端上往返" {
  let b = LibuiBackend::new()
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
  assert_eq(native_live_handles(), 0)
  b.terminate()
}

///|
/// §48 的里程碑要求"关闭后句柄表归零"，这里连 handler 失败的路径一起验：
/// terminate 必须自己把没销毁的控件和窗口扫干净，否则 uiUninit 的分配审计
/// 会把测试进程挂死在 DebugBreak 上。
test "terminate 扫掉遗留对象，退出后句柄表归零" {
  let b = LibuiBackend::new()
  b.init()
  let _ = b.create_window("MoonUI 遗留清理", @moonui.LogicalSize::{
    width: 120.0,
    height: 90.0,
  })
  let _ = b.create_widget(@moonui.Button, "没人销毁我")
  assert_eq(native_live_handles(), 2)
  b.terminate()
  assert_eq(native_live_handles(), 0)
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
  let b = LibuiBackend::new()
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
  let b = LibuiBackend::new()
  b.init()
  assert_eq(b.poll_event(), None)
  let win = b.create_window("MoonUI 循环终止", @moonui.LogicalSize::{
    width: 100.0,
    height: 80.0,
  })
  // 无限预算 + 有存活窗口，只有 WM_QUIT 能让它回来
  native_quit()
  assert_eq(b.poll_event(), None)
  // 已经知道循环结束了，再来一次也不等
  assert_eq(b.poll_event(), None)
  b.destroy_window(win)
  assert_eq(native_live_handles(), 0)
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
  let b = LibuiBackend::new()
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
  assert_eq(native_live_handles(), 0)
  b.terminate()
}

///|
/// 控件在真窗口子窗口列表里的位置，0 = 最上层。
fn z_indices(
  widgets : Array[@moonui.Widget[LibuiBackend]],
) -> Array[Int] raise @moonui.UiError {
  let out : Array[Int] = []
  for w in widgets {
    out.push(native_control_z_index(w.handle().unwrap()))
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
  let b = LibuiBackend::for_testing(4000)
  let app = @moonui.App::new(b)
  b.init()
  let demo = @moonui.Demo::hello(app)
  let title = "MoonUI"
  assert_eq(demo.status().text(), "Hello MoonUI")
  assert_eq(native_live_handles(), 3)
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
  assert_eq(native_click_button_in_window(title, cx, cy), 0)
  // 空白处：布局矩形之外，不该有第二个可点的按钮
  assert_true(native_click_button_in_window(title, cx + 200, cy + 200) < 0)
  assert_eq(native_request_window_close(title), 0)
  app.run()
  assert_true(demo.window().is_closed())
  assert_true(demo.status().is_closed())
  assert_eq(hits, 1)
  assert_eq(native_live_handles(), 0)
  assert_true(app.is_finished())
}
