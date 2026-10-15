///|
/// 原生 Cocoa 后端的真窗口验证（设计文档 §51 的 Backend #2，macOS 半，FP1）。
///
/// 被测的是"共享的 MoonBit 实现 + 直写 AppKit 的 C Adapter"这一对：
/// `@native-common.NativeBackend` 底下不经过任何中间 GUI 库，窗口、事件循环、回调全部
/// 直写 Cocoa（见 ../native-macos/adapter_native.m）。所以这里的每条断言都在问
/// "不经过中间 GUI 库也能开窗、跑循环、收事件"——这是 FP1 要证明的方向。
///
/// 这些测试会真的开窗口。带 App 的那条用 `for_testing` 的有限等待预算，
/// 链路断了就是测试失败，不会挂住 CI。

///|
/// 逻辑尺寸往返的容差：物理取整最多让一个方向差 1 像素；macOS 还要多一道"点"的
/// 取整，所以窗口级的量允许差到 1 逻辑像素。
fn close_to(a : Double, b : Double) -> Bool {
  let d = a - b
  d < 1.0 && d > -1.0
}

///|
/// 登记在册的后端：每条测试开头先清场（把上一条没收尾的后端 terminate 掉），
/// 再建一个新的。进程级单例（NSApplication）意味着同一时刻只能有一份活着的
/// 后端，所以这里按登记顺序遍历收尾。
let backends_in_play : Array[@native-common.NativeBackend] = []

///|
fn sweep_leaked_handles() -> Unit {
  for b in backends_in_play {
    b.terminate()
  }
  backends_in_play.clear()
}

///|
fn open_backend() -> @native-common.NativeBackend {
  sweep_leaked_handles()
  let b = @native-common.NativeBackend::new()
  backends_in_play.push(b)
  b
}

///|
fn open_backend_for_testing(
  wait_budget_ms : Int32,
) -> @native-common.NativeBackend {
  sweep_leaked_handles()
  let b = @native-common.NativeBackend::for_testing(wait_budget_ms)
  backends_in_play.push(b)
  b
}

///|
/// 不 `init()` 就动手，后端必须当场拒绝——这条钉的是 `check_initialized` 那道闸。
/// 末尾 init 一次、terminate 两次：确认这一对是幂等的（NSApplication 是进程级
/// 单例，MoonBit 侧的 terminate 走 `moonui_native_terminate` 的"没 inited 就直接返回"）。
test "原生后端：未初始化的真后端拒绝创建对象" {
  let b = open_backend()
  let msg = try {
    let _ = b.create_window(
      "MoonUI 原生 未初始化",
      @moonui.LogicalSize(100.0, 80.0),
    )
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(msg, Some("UI 初始化失败：Backend 尚未初始化"))
  b.init()
  b.terminate()
  b.terminate()
}

///|
/// 窗口几何、缩放、屏幕信息。这条顺带钉住"macOS 的 dpi 就是倍数乘 96"：
/// adapter.h 说 C 侧只报 DPI 不做换算，而 Cocoa 只有倍数，所以 192 这种读数
/// 是本文件那次乘法的直接结果，Scale 拿到的还是同一个数。
test "原生后端：窗口尺寸、位置、缩放按物理像素往返" {
  let b = open_backend()
  b.init()
  let win = b.create_window(
    "MoonUI 原生 窗口几何",
    @moonui.LogicalSize(300.0, 200.0),
  )
  let scale = b.window_scale(win)
  assert_true(scale.x >= 1.0 && scale.y >= 1.0)
  let size = b.window_size(win)
  assert_true(close_to(size.width, 300.0))
  assert_true(close_to(size.height, 200.0))
  b.set_window_size(win, @moonui.LogicalSize(420.0, 260.0))
  let grown = b.window_size(win)
  assert_true(close_to(grown.width, 420.0))
  assert_true(close_to(grown.height, 260.0))
  b.set_window_position(win, @moonui.LogicalPoint(40.0, 60.0))
  let origin = b.window_position(win)
  assert_true(close_to(origin.x, 40.0))
  assert_true(close_to(origin.y, 60.0))
  b.set_window_title(win, "MoonUI 原生 窗口几何 — 改名")
  b.set_window_resizable(win, false)
  b.hide_window(win)
  b.show_window(win)
  let screen = b.screen_size()
  assert_true(screen.width > 100.0 && screen.height > 100.0)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 沉浸式标题栏（§12）：`set_titlebar_style(Immersive)` 之后，原生层真的变成
/// fullSizeContentView + 透明标题栏 + 隐藏标题文字（三条都置位 = 打包位 7），
/// 切回 `Standard` 又摘干净（回到 0）。
test "原生后端：沉浸式标题栏设了真的生效，切回标准又摘干净" {
  let b = open_backend()
  b.init()
  let win = b.create_window(
    "MoonUI 原生 沉浸式标题栏",
    @moonui.LogicalSize(300.0, 200.0),
  )
  assert_eq(@native-common.native_window_titlebar_style(win), 0)
  b.set_window_titlebar_style(win, @moonui.TitlebarStyle::Immersive)
  assert_eq(@native-common.native_window_titlebar_style(win), 7)
  b.set_window_titlebar_style(win, @moonui.TitlebarStyle::Standard)
  assert_eq(@native-common.native_window_titlebar_style(win), 0)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 红绿灯位置（§12）：`set_traffic_light_position` 之后关闭按钮左上角真的落到
/// 指定的逻辑坐标（读回走的是同一套 pt/px 换算，断言按物理像素对表 scale）。
test "原生后端：红绿灯位置设了真的生效" {
  let b = open_backend()
  b.init()
  let win = b.create_window(
    "MoonUI 原生 红绿灯位置",
    @moonui.LogicalSize(300.0, 200.0),
  )
  b.set_window_traffic_light_position(win, @moonui.LogicalPoint(12.0, 8.0))
  let (px, py) = @native-common.native_window_traffic_light_position(win)
  let scale = b.window_scale(win)
  assert_true(close_to(px.to_double(), 12.0 * scale.x))
  assert_true(close_to(py.to_double(), 8.0 * scale.y))
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// poll_event 的两个终止条件：没有存活窗口时返回 None（循环结束），有窗口时
/// 阻塞到有事件或等待预算用完。这条用 `for_testing` 的有限预算，链路断了就是
/// 测试失败，不会挂住 CI。
test "原生后端：poll_event 的两个终止条件" {
  let b = open_backend_for_testing(3000)
  b.init()
  // 没有窗口：循环结束，返回 None
  assert_eq(b.poll_event(), None)
  let win = b.create_window(
    "MoonUI 原生 循环终止",
    @moonui.LogicalSize(200.0, 120.0),
  )
  // 有窗口：阻塞到有事件或预算用完。这里没有事件源，所以会空转到预算用完返回
  // None——但关键是它**没有**因为"没有窗口"而立刻返回，而是真的泵了循环。
  let _ = b.poll_event()
  b.destroy_window(win)
  assert_eq(b.poll_event(), None)
  b.terminate()
}

///|
/// 多窗口：建两只、各自独立、销毁一只不影响另一只。
test "原生后端：多窗口各自独立" {
  let b = open_backend()
  b.init()
  let one = b.create_window(
    "MoonUI 原生 多窗口之一",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let two = b.create_window(
    "MoonUI 原生 多窗口之二",
    @moonui.LogicalSize(300.0, 180.0),
  )
  assert_true(b.window_size(one).width < b.window_size(two).width)
  b.destroy_window(one)
  // 销毁一只后另一只还在
  assert_true(close_to(b.window_size(two).width, 300.0))
  b.destroy_window(two)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 画册在原生后端上端到端（FP2 的判据）：把共享的 `Gallery` 建在
/// `@native-common.NativeBackend` 上，逐页 `select` 一遍——每一页的 `build_demo`
/// 都会真建一批原生控件（Label/Button/TextInput/Checkbox/Slider/Spinbox/Progress/
/// ComboBox/PasswordInput/MultilineEntry/Separator/RadioButtons/DatePicker 加八个
/// 组合组件），所以这条测的是"不经过中间库，画册要的那批控件在直写 AppKit 的
/// C 上都能建出来、摆进窗口、换页时整棵拆掉不泄漏"。
///
/// 顺带钉住左栏的形状：macOS 设置那种"一行一项"的扁平菜单——侧栏第 4 项
/// （children()[3]）是"布局基础"那组的 Column，它的 9 个子项全是 MenuRow（不再是
/// 两列按钮网格），选中态走 checked 通道（当前页那行 checked 为真）。
test "原生后端：画册逐页建控件，左栏是扁平菜单行，句柄不泄漏" {
  let b = open_backend()
  b.init()
  let app = @moonui.App::new(b)
  let g = @moonui.Gallery::demo(app)
  let n = @moonui.Gallery::section_names().length()
  assert_eq(n, 26)
  // 逐页切一遍：每页 build_demo 真建一批原生控件，set_content 把旧树整棵拆掉。
  for i = 0; i < n; i = i + 1 {
    g.select(i)
    assert_eq(g.current(), i)
    match g.window().content() {
      None => assert_true(false) // unreachable
      Some(root) => assert_true(root.leaf_count() > 0)
    }
  }
  // 循环走完停在第 25 页（Rate），先切回第 0 页（Label）再量左栏的选中态。
  g.select(0)
  // 左栏形状（T74 起左栏包进滚动）：Padding -> Row -> [侧栏 Scroll, 竖线,
  // 右栏]；Scroll 里是侧栏 Column，第 4 项是"布局基础"那组的扁平菜单列，
  // 9 个子项全是 MenuRow。
  let sidebar = match g.window().content() {
    None => abort("画册没有内容树")
    Some(root) => root.children()[0].children()[0].children()[0]
  }
  let group = sidebar.children()[3]
  assert_eq(group.children().length(), 9)
  for row in group.children() {
    assert_eq(row.kind(), @moonui.WidgetKind::MenuRow)
  }
  // 选中态走 checked 通道：当前页（第 0 页 = Label）那行 checked 为真，
  // 其余为假。
  assert_true(group.children()[0].checked())
  assert_false(group.children()[1].checked())
  // 换页后选中态跟着走：切到第 2 页（TextInput），第 0 行变假、第 2 行变真。
  g.select(2)
  let sidebar2 = match g.window().content() {
    None => abort("画册没有内容树")
    Some(root) => root.children()[0].children()[0].children()[0]
  }
  let group2 = sidebar2.children()[3]
  assert_false(group2.children()[0].checked())
  assert_true(group2.children()[2].checked())
  // 收尾：整棵内容树 + 窗口全拆，句柄表清零。
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// 测试探针：C 那一份 `moonui_native_app_icon_present`（0/1），见 adapter.h。
extern "c" fn c_app_icon_present() -> Int32 = "moonui_native_app_icon_present"

///|
/// §25 那棵菜单在真窗口测试里的夹具（和 Windows 半 native_test 的 menu_fixture
/// 同一棵树——这套夹具原是三份共用的，含 libui 那份（`T82` 删）：
/// 两边断言的是同一根 dump 文本，夹具也必须同一棵，否则"逐字符一致"就无从谈起）。
/// 注释里的数字是 `MenuBar::new` 按整棵树深度优先重排出来的 id，也就是原生侧
/// 看到的那个数（NSMenuItem.tag）：
///   File：Quit(0, Meta+q)、Sidebar(1, 勾选框)、分隔线、Zoom{ Small(2, radio), Large(3, radio) }
///   Edit：Copy(4, Ctrl+c)、Sync(5, 勾选框且禁用)
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
/// 夹具那棵菜单装好之后，原生侧应该长成的样子（格式在 adapter.h）。整根文本和
/// Windows 半 native_test 的 `menu_dump_full` 逐字符相同（libui 那份的测试也曾
/// 断言这一根，`T82` 删）——不同后端建出的菜单是同一副面孔，这根文本就是那件事的钉子。
let menu_dump_full : String = "File{#0:n.e:Quit:Mq,#1:c-e:Sidebar:.,-,+Zoom{#2:r-e:Small:.,#3:r-e:Large:.}};Edit{#4:n.e:Copy:Cc,#5:c-d:Sync:.}"

///|
/// 快照里有没有某一项的完整记录。逐项盯时仍然写全
/// `#<id>:<role><check><enabled>:<label>:<sc>` 一整节，不是只查一个 `+`。
fn menu_dump_has(entry : String) -> Bool {
  @native-common.native_menu_dump().contains(entry)
}

///|
/// T76「装上去」这一半：Core 那棵树整棵打包给 C，C 建出真的 NSMenu 挂进
/// `[NSApp mainMenu]`，快照读回来的是**主菜单里的那几顶**，不是 adapter 自己记的
/// 名单。和 Windows 半 native_test 那条同名测试断言的是同一串文本（libui 那份同名
/// 测试亦然，`T82` 删）——布局（MoonBit 的序列化器对
/// adapter.h）、组合落到项上（`<sc>` 一栏读的是 NSMenuItem 自己的
/// keyEquivalent）、拆干净（换树整棵替换、空树就是拆、terminate 之后还是空）
/// 三件事一起钉住。
///
/// 原生后端多一条 libui 那份（`T82` 删）没有的前提：`moonui_native_init` 要先建一只空的主菜单
/// （本后端不经过中间库的 uiInit，没人替我们装），不然 `set_menu_bar` 只能报 -2。
test "原生后端：菜单栏整棵装进原生主菜单，快照逐字符对得上" {
  let b = open_backend()
  b.init()
  b.set_menu_bar(menu_fixture())
  assert_eq(@native-common.native_menu_dump(), menu_dump_full)
  assert_eq(@native-common.native_live_handles(), 0)
  // 换一棵：旧的整棵摘掉，所以旧树里的 id 在原生侧不再有对应项
  b.set_menu_bar(
    @moonui.MenuBar::new([
      @moonui.Menu::new("Edit", [
        @moonui.MenuNode::Item(@moonui.MenuItem::new("Copy")),
      ]),
    ]),
  )
  assert_eq(@native-common.native_menu_dump(), "Edit{#0:n.e:Copy:.}")
  assert_eq(@native-common.native_menu_click_item(1), -1)
  // 空的一棵 = 拆掉
  b.set_menu_bar(@moonui.MenuBar::new([]))
  assert_eq(@native-common.native_menu_dump(), "")
  // 再装一次再收尾：terminate 里那次拆干净只有在这里才量得到。
  b.set_menu_bar(menu_fixture())
  assert_eq(@native-common.native_menu_dump(), menu_dump_full)
  b.terminate()
  assert_eq(@native-common.native_menu_dump(), "")
}

///|
/// T76「点下去」这一半：脚手架对真 NSMenuItem 走 `performActionForItemAtIndex:`
/// （不是把 MoonBit 的回调直接调一遍）→ 回调读的是 `item.tag` → 后端入队
/// `MenuSelect` → App 派发。勾选态是反方向：每次点击之后由 `App::click_menu_item`
/// 推给后端，快照里 `c-` 变 `c+` 看得见这次推送。
test "原生后端：真点击菜单项回流成 MenuSelect，勾选态推回原生菜单" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  app.set_menubar(menu_fixture())
  assert_eq(@native-common.native_menu_dump(), menu_dump_full)
  let seen : Array[@moonui.Event] = []
  let sidebar = @moonui.EventTarget::{ id: 1, generation: 0, }
  let _ = app.on_event(sidebar, fn(ev) { seen.push(ev) })
  assert_eq(@native-common.native_menu_click_item(1), 0)
  assert_true(app.step())
  assert_eq(seen, [@moonui.MenuSelect(sidebar)])
  assert_true(menu_dump_has("#1:c+e:Sidebar:."))
  // 再点一次：推的是改完之后的状态，不是"点一下就勾上"
  assert_eq(@native-common.native_menu_click_item(1), 0)
  assert_true(app.step())
  assert_true(menu_dump_has("#1:c-e:Sidebar:."))
  // Radio：点 Large，同组的 Small 一起被推（Core 算的互斥要看得见）
  assert_eq(@native-common.native_menu_click_item(3), 0)
  assert_true(app.step())
  assert_true(menu_dump_has("#3:r+e:Large:."))
  assert_true(menu_dump_has("#2:r-e:Small:."))
  assert_eq(@native-common.native_menu_click_item(2), 0)
  assert_true(app.step())
  assert_true(menu_dump_has("#2:r+e:Small:."))
  assert_true(menu_dump_has("#3:r-e:Large:."))
  // 禁用项：-2，且没有事件冒出来
  assert_eq(@native-common.native_menu_click_item(5), -2)
  assert_false(app.step())
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 菜单失败的那几条形态：脚手架的 0 / -1 / -2，和 `set_menu_item_checked` 的报错
/// 文案（和 `MockBackend` 逐字相同，§33）。最后一条是"能改"而不是"改得对"：
/// 禁用项允许推勾选态（`#5:c-d` 变 `c+d`），夹具的 5 号因此做成"禁用 + 勾选框"。
test "原生后端：菜单的失败形态和 MockBackend 逐字相同" {
  let b = open_backend()
  b.init()
  b.set_menu_bar(menu_fixture())
  assert_eq(@native-common.native_menu_click_item(6), -1)
  assert_eq(@native-common.native_menu_click_item(99), -1)
  let msg = try {
    b.set_menu_item_checked(999, true)
    "没有报错"
  } catch {
    e => @moonui.UiError::message(e)
  }
  assert_eq(msg, "操作失败：菜单项 999 不在已安装的菜单栏里")
  b.set_menu_item_checked(5, true)
  assert_true(menu_dump_has("#5:c+d:Sync:."))
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 真剪贴板往返（§23 / §48-19，T76）。**这条测试动的是用户机器上的真剪贴板**，
/// 复原只覆盖文本形态。三个断言各钉一件事：写空串再读 → `None`（不是
/// `Some("")`）；非空往返 → `Some(原文)`（文案带中文，UTF-8 那条路过一次）；
/// 覆盖一次 → 只剩最后一份。失败时复原跑不到、测试文案会留在剪贴板里，所以开头
/// 把"正是本条测试自己写过的那两句"当空的看，别把它当成用户的内容存回去。
test "原生后端读写系统剪贴板，测完把原内容放回去" {
  let b = open_backend()
  b.init()
  let saved = match b.clipboard_text() {
    Some(t) if t == "MoonUI 的一段文案" || t == "覆盖一次" => None
    s => s
  }
  b.set_clipboard_text("")
  assert_eq(b.clipboard_text(), None)
  b.set_clipboard_text("MoonUI 的一段文案")
  assert_eq(b.clipboard_text(), Some("MoonUI 的一段文案"))
  b.set_clipboard_text("覆盖一次")
  assert_eq(b.clipboard_text(), Some("覆盖一次"))
  assert_eq(@native-common.native_live_handles(), 0)
  // 复原用户原来的复制内容（只有文本形态放得回去）
  match saved {
    None => b.set_clipboard_text("")
    Some(s) => b.set_clipboard_text(s)
  }
  b.terminate()
}

///|
/// 消息框与确认框（§24，T76）。面板同步阻塞，测试先安排"用户怎么答"（300 毫秒后
/// 替按），再量那段阻塞真的发生过——空转的实现立刻返回，量不到这 300 毫秒。
/// 越界的 index 在"装"的那一步就报回来，不许留到运行时什么也按不下。
test "原生后端：消息框与确认框真弹原生面板，答案是按钮给的" {
  let b = open_backend()
  b.init()
  let t0 = @native-common.native_time_ms()
  assert_eq(@native-common.native_auto_dismiss_dialog(300, 0), 0)
  b.show_message("MoonUI 的消息框", "正文")
  let blocked = @native-common.native_time_ms() - t0
  assert_true(blocked >= 250)
  assert_eq(@native-common.native_auto_dismiss_dialog(300, 0), 0)
  assert_true(b.confirm("MoonUI 的确认框", "要继续吗？"))
  assert_eq(@native-common.native_auto_dismiss_dialog(300, 1), 0)
  assert_false(b.confirm("MoonUI 的确认框", "要继续吗？"))
  assert_eq(@native-common.native_auto_dismiss_dialog(10, 2), -1)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 文件面板（§24，T76）的 macOS 版。macOS 15.6 上只安排得了"取消"这一种答案
/// （面板跑在系统 XPC 服务里，客户端的 [panel ok:] 是个桩，证据链在 TODO 的 T21
/// 行；libui 那份 adapter 的同名注释已随 `T82` 删），所以这条钉的是：三只面板都真弹了、真
/// 阻塞、取消是面板自己的答案（`None`）。替按接受当场报 -2；空 path 的 -1 校验
/// 排在它前面。
test "原生后端：文件 / 保存 / 文件夹面板真弹出来，答案是取消" {
  let b = open_backend()
  b.init()
  let t0 = @native-common.native_time_ms()
  assert_eq(@native-common.native_auto_answer_file_dialog(300, "", false), 0)
  assert_eq(b.open_file("MoonUI 的打开"), None)
  assert_true(@native-common.native_time_ms() - t0 >= 250)
  let t1 = @native-common.native_time_ms()
  assert_eq(@native-common.native_auto_answer_file_dialog(300, "", false), 0)
  assert_eq(b.save_file("MoonUI 的保存", "moonui-t76-save-probe.txt"), None)
  assert_true(@native-common.native_time_ms() - t1 >= 250)
  let t2 = @native-common.native_time_ms()
  assert_eq(@native-common.native_auto_answer_file_dialog(300, "", false), 0)
  assert_eq(b.select_folder("MoonUI 的文件夹"), None)
  assert_true(@native-common.native_time_ms() - t2 >= 250)
  assert_eq(
    @native-common.native_auto_answer_file_dialog(300, "/bin/ls", true),
    -2,
  )
  assert_eq(@native-common.native_auto_answer_file_dialog(300, "", true), -1)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// set_app_icon（§26，T76）：PNG 真喂给了 NSApp（探针读的是 C 侧装的记号），
/// 坏路径按 §33 报错，文案和 MockBackend 逐字相同（libui 那份也是这一句，`T82` 删）。终止之后再设：
/// 共享 backend.mbt 的 check_initialized 先拦，报"还没初始化"。
test "原生后端：set_app_icon 把 PNG 喂给 NSApp，坏路径按 §33 报错" {
  let b = open_backend()
  b.init()
  assert_eq(c_app_icon_present(), 0)
  b.set_app_icon("assets/logo/moonui")
  assert_eq(c_app_icon_present(), 1)
  let msg = try {
    b.set_app_icon("no/such/icon")
    "没有报错"
  } catch {
    @moonui.OperationFailed(m) => m
    _ => "别的错"
  }
  assert_eq(
    msg, "图标文件读不出来（路径不对或格式不受支持）：no/such/icon",
  )
  b.terminate()
  let after = try {
    b.set_app_icon("assets/logo/moonui")
    "没有报错"
  } catch {
    @moonui.InitializationFailed(m) => m
    _ => "别的错"
  }
  assert_eq(after, "Backend 尚未初始化")
}
