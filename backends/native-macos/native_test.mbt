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
  b.set_window_titlebar_style(win, Immersive)
  assert_eq(@native-common.native_window_titlebar_style(win), 7)
  b.set_window_titlebar_style(win, Standard)
  assert_eq(@native-common.native_window_titlebar_style(win), 0)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 红绿灯位置（§12）：`set_traffic_light_position` 之后关闭按钮左上角真的落到
/// 指定的逻辑坐标（读回走的是同一套 pt/px 换算，断言按物理像素对表 scale）。
///
/// 两条额外回归一起钉在这里：
///   1. 切沉浸式（`styleMask` 变更）会让 AppKit 把三只按钮重排回默认位，原生层
///      必须把自定义落点重放一遍——不然调用方"先样式后摆位"的写法一改就散。
///   2. 改窗口尺寸走 `setFrame:display:`，同样会重排；落点得是持久的而不是
///      "设一次就丢"。
test "原生后端：红绿灯位置设了真的生效，且换沉浸式/改尺寸后仍在中线上" {
  let b = open_backend()
  b.init()
  let win = b.create_window(
    "MoonUI 原生 红绿灯位置",
    @moonui.LogicalSize(300.0, 200.0),
  )
  let scale = b.window_scale(win)
  // 顶条 30pt 的中线：关闭按钮框 14×16，左上角落在 (30-16)/2 = 7 就是居中。
  b.set_window_traffic_light_position(win, @moonui.LogicalPoint(7.0, 7.0))
  let (px, py) = @native-common.native_window_traffic_light_position(win)
  assert_true(close_to(px.to_double(), 7.0 * scale.x))
  assert_true(close_to(py.to_double(), 7.0 * scale.y))
  // 沉浸式：换完 styleMask 位置要还在（AppKit 会重排）。
  b.set_window_titlebar_style(win, Immersive)
  let (_, py_im) = @native-common.native_window_traffic_light_position(win)
  assert_true(close_to(py_im.to_double(), 7.0 * scale.y))
  // 改尺寸：同上。
  b.set_window_size(win, @moonui.LogicalSize(360.0, 240.0))
  let (px2, py2) = @native-common.native_window_traffic_light_position(win)
  assert_true(close_to(px2.to_double(), 7.0 * scale.x))
  assert_true(close_to(py2.to_double(), 7.0 * scale.y))
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 最小尺寸（§12）：`set_window_min_size` 落成 AppKit 的 `contentMinSize`——
/// 这是**用户拖窗格**时的钳位（Core 的 clamped 只管程序化改尺寸），所以必须
/// 真到原生层，而不是只记在 Core 的字段里。读回走同一套 pt/px 换算对表 scale。
///
/// 读回对得上就说明这条真的进了 AppKit 的 `contentMinSize`（不是只记在 Core 的
/// 字段里——那样用户拖窗格时谁也拦不住）。`contentMinSize` 只挡**拖拽**，程序化
/// `setContentSize` 不挡（实测），所以这里不写"缩到下限以下会被顶回来"的断言。
test "原生后端：最小尺寸设了真的生效" {
  let b = open_backend()
  b.init()
  let win = b.create_window(
    "MoonUI 原生 最小尺寸",
    @moonui.LogicalSize(600.0, 400.0),
  )
  let scale = b.window_scale(win)
  b.set_window_min_size(win, Some(@moonui.LogicalSize(400.0, 300.0)))
  let (px, py) = @native-common.native_window_min_size(win)
  assert_true(close_to(px.to_double(), 400.0 * scale.x))
  assert_true(close_to(py.to_double(), 300.0 * scale.y))
  // 程序化缩到下限以下：contentMinSize 不拦这条（拦的是用户拖拽），Core 那侧
  // `Window::clamped` 负责把程序化改尺寸夹住。这里只钉"清掉限制回到 (0, 0)"。
  b.set_window_min_size(win, None)
  let (zx, zy) = @native-common.native_window_min_size(win)
  assert_eq(zx, 0)
  assert_eq(zy, 0)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 实时重排开关（live redraw）：**缺席 = 开**（没登记过的窗口按开处理），
/// 关掉读得回。拖拽会话检测（`in_live_resize`）在常态下是 0——实时路只认
/// 用户拖窗格，程序化改尺寸不算（Core 的 `set_size` 自己当场重排）。
test "原生后端：实时重排开关默认开、关掉读得回，常态不在拖拽会话里" {
  let b = open_backend()
  b.init()
  let win = b.create_window(
    "MoonUI 原生 实时重排",
    @moonui.LogicalSize(300.0, 200.0),
  )
  assert_true(b.window_live_redraw(win))
  b.set_window_live_redraw(win, false)
  assert_false(b.window_live_redraw(win))
  b.set_window_live_redraw(win, true)
  assert_true(b.window_live_redraw(win))
  assert_false(@native-common.native_window_in_live_resize(win))
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
    assert_eq(row.kind(), MenuRow)
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
/// 测试探针：C 那一份 `moonui_native_app_icon_content_permille`（内容占画布的
/// 千分比），见 adapter.h。
extern "c" fn c_app_icon_content_permille() -> Int32 = "moonui_native_app_icon_content_permille"

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
      Item(quit),
      Item(sidebar),
      Separator,
      Submenu("Zoom", [Item(small), Item(large)]),
    ]),
    @moonui.Menu::new("Edit", [Item(copy), Item(sync)]),
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
      @moonui.Menu::new("Edit", [Item(@moonui.MenuItem::new("Copy"))]),
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

///|
/// 应用图标留白（macOS 图标网格）：满幅 PNG 装进去之后，内容只能占画布
/// ≈805‰（Apple 的 824/1024），而不是 1000‰。
///
/// 这不是美术口味：Dock / Cmd-Tab 把图标当**整块画布**摆，四边贴满的图在
/// 一排图标里就是比邻居大一圈（examples 里 `luna.png` 的 alpha 包围盒
/// 正好是 (0,0,256,256)，满幅）。所以 `set_app_icon` 先量 alpha 包围盒、再按
/// 网格重排；这条测试把"留白真的生效"钉成可断言的事实，省得靠看截图猜。
test "原生后端：set_app_icon 按 macOS 图标网格补留白" {
  let b = open_backend()
  b.init()
  // 不做"初始值必须是 -1"的断言：这个探针是进程级全局量，同文件里前一条
  // set_app_icon 的测试已经装过图标，全量跑与单跑（-i）的起点不一样。
  // ① 满幅图（luna.png：内容贴满 256 画布）→ 补到 80.5%
  b.set_app_icon("assets/logo/luna")
  let full = c_app_icon_content_permille()
  assert_true(full >= 780 && full <= 830)
  // ② 已经有点留白的图（moonui.png：896/1024 = 87.5%，仍高于 86% 的放行线）
  //    也要归到同一条口径上——不能"有的补有的不补"
  b.set_app_icon("assets/logo/moonui")
  let padded = c_app_icon_content_permille()
  assert_true(padded >= 780 && padded <= 830)
  b.terminate()
}

///|
/// T89② 落点判据的真窗口半条：真窗 Resize 的动画走真钟（前台门同款两行
/// 接线——时刻从 native_time_ms 来；激活沿把 poll_event 的等待预算换成
/// 8ms 档），逐帧驱动是真时间自旋、天然计时易碎，所以这里**不做中间帧
/// 断言**——step 轮询到落点：每圈 step 后读 `widget_bounds`，直到与布局
/// 真相（`label.frame()`，变更点当场落的那份——"动画是糖，落点即真相"）
/// 逐位相等或超时。逐位相等有格点论证：布局逻辑值全部来自物理值的除法
/// （fittingSize、窗口内容尺寸都是物理/scale），乘回 scale 都是整数，Core
/// 推 bounds 的 round/ceil 逐位往返无损；异形分数缩放会把几何往返本身推
/// 离格点——那是几何账不是动画账，真撞上时红在末尾的 assert_eq、消息带
/// 当下值。真窗测试用真钟（300ms 动画档约束总时长），超时上限给足不赌下限。
/// 偏好开着（系统 reduced-motion，`T87`③ 退场闸门在真后端同样成立）动画
/// 当圈退场：轮询第一圈就收敛、帧钟从未激活——两种系统态都在判据内。
test "原生后端：真窗 Resize 的动画 step 轮询到落点，widget_bounds 逐位读回" {
  let b = open_backend_for_testing(300)
  b.init()
  let app = @moonui.App::new(b)
  // 真钟接线（前台门 @moonui_app 的同款两行，本包不 import 前台门）：
  // 时刻从平台的钟来；帧钟开关接等待预算——预算的语义（激活 8ms / 退场
  // 恢复）由切换沿本身断言，不读后端字段。
  app.set_anim_clock(@native-common.native_time_ms)
  let wake : Array[Bool] = []
  app.set_anim_wake(fn(active) {
    b.set_frame_budget(active)
    wake.push(active)
  })
  let win = app.create_window(
    "MoonUI 原生 动画落点",
    @moonui.LogicalSize(200.0, 100.0),
  )
  let label = @moonui.Widget::label(b, "Ab").animation(@moonui.EaseInOut)
  let sp = @moonui.Widget::label(b, "").with_expand(true)
  win.set_content(@moonui.Widget::row(b, 0.0, [sp, label]))
  let h = match label.handle() {
    Some(h) => h
    None => abort("label 没有句柄")
  }
  // 偏好快照：测试开跑时系统 reduced-motion 开着没有（两条系统态都进判据）
  let reduced = @moonui.Backend::get_prefers_reduced_motion(b)
  // 先 show 再触发：Resize 要对看得见的窗口才可靠（真窗尺寸变更 + 事件
  // 同款形状回流 Core——见下面触发段的注记）。
  win.show()
  // 初始收敛态（差分基线）：真窗 bounds 读回带窗口客户区原点平移（标题栏
  // 那格，NSView 翻转坐标里是负 y），Core 的 frame 不带——首跑红的正是这
  // 格结构偏移（size/x 逐位相等、动画落点本身收敛对了）。T89② 的"读回
  // 精确值"用差分口径兑现：前后两个收敛态的 delta 对 delta，结构偏移天
  // 然消掉。收敛判读 = 连续两次读回相等；假收敛（读档恰逢帧间）会被差
  // 分断言红出两侧 delta，不静默。
  let mut stable = false
  let mut before = @moonui.Backend::widget_bounds(b, h)
  let settle_deadline = @native-common.native_time_ms() + 2000
  while !stable {
    let _ = app.step()
    let now = @moonui.Backend::widget_bounds(b, h)
    if now == before {
      stable = true
    } else {
      before = now
    }
    if @native-common.native_time_ms() >= settle_deadline {
      break
    }
  }
  let bounds_before = before
  let frame_before = label.frame()
  // 触发变更走**纯平移档**（spacer 收缩→label 只挪 origin、尺寸不动），
  // 不走窗口档/width 档/文本档——三档都被真跑或探针咬过：窗口档 set_size
  // 回声抑制是设计（Core 学窗口尺寸只从 Resize 事件来、事件只能由真回调
  // 产生——几何全在原布局收敛、差分 0==0 平凡过）；width 档对 frame 零
  // 效果（定宽覆盖没进这条测量账，Mock 探针 fw 24 不动）；文本档 wake 真
  // 响但落点不一致——文本控件的 SIZE 归后端（§18 fittingSize），NSTextField
  // 自长往右、origin 纹丝不动，与 Core 说的"往左挪"打架（bounds origin
  // delta 0 对 frame origin delta -61）——文本度量归后端的控件上 Core 不
  // 全权拥有几何，动画判据的触发要挑 Core 全权拥有的那格：origin。
  let _ = sp.with_expand(false)
  // step 轮询到落点（T89② 形状）：先 step 后读，收敛判读连续两次相等。
  // 轮询绕开帧时序；退场帧推的是精确的 to（不做插值），落点即真相。
  let deadline = @native-common.native_time_ms() + 2000
  let mut landed = false
  let mut now = @moonui.Backend::widget_bounds(b, h)
  while !landed {
    let _ = app.step()
    let next = @moonui.Backend::widget_bounds(b, h)
    // 收敛判读：稳定两读 **且 wake 退休**（reduced 档当圈退场推精确 to、
    // wake 恒空，读数动一次即到；偏好关档要 [true,false] 两沿到齐）——
    // 只看"两读相等"会在起跑圈假收敛：T84 设计记 span 零推送 + 起跑圈
    // 零推送，头两步读数天然相等，轮询在动画推第一帧之前就宣布落点
    // （dump 诊断在案：ox1=4 bx1=179 wake=[true]——推还在飞，读已退出）。
    landed = next == now && (reduced || wake.length() >= 2)
    if next == now {
      // 读数相等但沿未到齐：继续 step 等（不更新基线）
    } else {
      now = next
    }
    if @native-common.native_time_ms() >= deadline {
      break
    }
  }
  let bounds_after = now
  let frame_after = label.frame()
  // 差分断言：bounds 的落点 delta == Core frame 的落点 delta（逐位），
  // 结构偏移在两个收敛态里同格已消；超时也红在这里，失败消息带两侧 delta
  assert_eq(
    bounds_after.origin.x - bounds_before.origin.x,
    frame_after.origin.x - frame_before.origin.x,
  )
  assert_eq(
    bounds_after.origin.y - bounds_before.origin.y,
    frame_after.origin.y - frame_before.origin.y,
  )
  assert_eq(
    bounds_after.size.width - bounds_before.size.width,
    frame_after.size.width - frame_before.size.width,
  )
  assert_eq(
    bounds_after.size.height - bounds_before.size.height,
    frame_after.size.height - frame_before.size.height,
  )
  // 落点真的挪了（spacer 收缩，label 从右缘往左挪——origin 实移）：钉住
  // "轮询收敛在变更之后"，不是初始态碰巧相等
  assert_true(label.frame().origin.x < frame_before.origin.x)
  if reduced {
    // 帧钟从未激活：偏好开着动画当圈退场，预算一次都不换（零开销）
    assert_eq(wake, [])
  } else {
    // 等退场沿（真钟 300ms 档 + 余量）：若上面的轮询在退场推送之外提前收敛
    // （windowDidResize 冒第二条 Resize 把真相原样重推），退场沿随后仍会到。
    // 恰好 [true, false] 两条切换沿 = 预算换过一次、恢复过一次——退场后
    // 帧钟恢复零开销的断言就是它（预算值本身在 Mock 判据钉）。
    let wake_deadline = @native-common.native_time_ms() + 2000
    while wake.length() < 2 && @native-common.native_time_ms() < wake_deadline {
      let _ = app.step()
    }
    assert_eq(wake, [true, false])
  }
  // 收尾：整棵内容树 + 窗口全拆，句柄表清零。
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// 画布（§52 第一期）：离屏位图帧的往返判据——画了什么，读回来就是什么。
/// 不开窗口（位图就是帧），进 macos 真跑批是因为 C 侧是 CoreGraphics。
test "画布：填充/描边/渐变/文本往返，read_pixel 逐位对得上" {
  let c = @native-common.canvas_create()
  @native-common.canvas_begin_frame(c, 100, 100)
  // 红色圆角矩形占住左上
  @native-common.canvas_fill_rect(c, 10, 10, 40, 40, radius=8.0, rgb=0xFF0000)
  // 中心点是纯红
  assert_eq(@native-common.canvas_read_pixel(c, 30, 30), 0xFF0000)
  // 圆角外角没画到（10,10 是圆角外）
  let corner = Some(@native-common.canvas_read_pixel(c, 11, 11)) catch {
    _ => None
  }
  assert_true(corner is None)
  // 白底上的蓝色描边（2px 线宽，中心点在内）
  @native-common.canvas_fill_rect(c, 50, 10, 40, 40, radius=0.0, rgb=0xFFFFFF)
  @native-common.canvas_stroke_rect(
    c,
    52,
    12,
    36,
    36,
    radius=0.0,
    width=2.0,
    rgb=0x0000FF,
  )
  assert_eq(@native-common.canvas_read_pixel(c, 52, 30), 0x0000FF)
  // 垂直渐变：上端近红、下端近蓝（采样点离两端各 5px，避开插值端点）
  @native-common.canvas_fill_linear(c, 10, 50, 40, 40, [
    (0.0, 0xFF0000),
    (1.0, 0x0000FF),
  ])
  let top = @native-common.canvas_read_pixel(c, 20, 55)
  let bottom = @native-common.canvas_read_pixel(c, 20, 85)
  // 0xRRGGBB：上端红分量高、蓝分量低；下端反过来
  assert_true(top >> 16 > 0xC0 && (top & 0xFF) < 0x40)
  assert_true((bottom & 0xFF) > 0xC0 && bottom >> 16 < 0x40)
  // 文本：画得出来（覆盖处不再是空像素），度量随字号长高
  @native-common.canvas_draw_text(c, "云", 60, 50, 16.0, rgb=0x000000)
  // 字符区域里扫到任何一个非空像素就算画上了（该区在文本之前是空位）
  fn pixel_alive(c : @native-common.Canvas, x : Int32, y : Int32) -> Bool {
    try {
      let _ = @native-common.canvas_read_pixel(c, x, y)
      true
    } catch {
      _ => false
    }
  }
  let mut touched = false
  for y = 50; y < 70 && !touched; y = y + 1 {
    for x = 60; x < 90 && !touched; x = x + 1 {
      if pixel_alive(c, x, y) {
        touched = true
      }
    }
  }
  assert_true(touched)
  let (_, h14) = @native-common.canvas_measure_text("云", 14.0)
  let (_, h24) = @native-common.canvas_measure_text("云", 24.0)
  assert_true(h24 > h14)
  let (w_regular, _) = @native-common.canvas_measure_text("云音乐", 16.0)
  let (w_bold, _) = @native-common.canvas_measure_text(
    "云音乐",
    16.0,
    bold=true,
  )
  assert_true(w_bold >= w_regular)
  // 状态栈：save → 清屏色 → restore 后投影/clip 不残留（画一个带投影的块，
  // restore 前后各读一次，确认影只作用在区间内）
  @native-common.canvas_save(c)
  @native-common.canvas_shadow(c, 0, 0, blur=6.0, rgb=0x00FF00)
  @native-common.canvas_fill_rect(c, 10, 10, 10, 10, radius=0.0, rgb=0x000000)
  @native-common.canvas_restore(c)
  // restore 后再画纯红块：不带影（读邻近像素应仍是上一帧内容或空）
  @native-common.canvas_fill_rect(
    c,
    200 - 200 + 70,
    10,
    10,
    10,
    radius=0.0,
    rgb=0xFF0000,
  )
  assert_eq(@native-common.canvas_read_pixel(c, 70, 10), 0xFF0000)
  // 收尾幂等
  @native-common.canvas_end_frame(c)
  @native-common.canvas_destroy(c)
}

///|
/// 画布：坏参数走 §33 的拦截面（raise 不跨 C 帧）。
test "画布：坏参数 raise，不崩" {
  let c = @native-common.canvas_create()
  let raised = try {
    // 非正尺寸开帧
    @native-common.canvas_begin_frame(c, 0, 100)
    false
  } catch {
    _ => true
  }
  assert_true(raised)
  @native-common.canvas_begin_frame(c, 10, 10)
  let oob = try {
    let _ = @native-common.canvas_read_pixel(c, 99, 99)
    false
  } catch {
    _ => true
  }
  assert_true(oob)
  @native-common.canvas_destroy(c)
}

///|
/// 测试探针：画布上屏那两个入口要的裸窗口指针，直接开一只不经 HandleTable
/// 的窗口（c_app_icon_present 同款手法）。
#borrow(title)
extern "c" fn probe_window_new(
  title : Bytes,
  title_len : Int32,
  width : Int32,
  height : Int32,
) -> Int64 = "moonui_native_window_new"

///|
extern "c" fn probe_window_destroy(w : Int64) -> Unit = "moonui_native_window_destroy"

///|
/// 分期②上屏（§52.5）：attach 挂真窗口、present 把帧贴进 contentView 的
/// layer。断的是状态机（没挂不能贴、挂了能贴、贴是幂等的）——"屏幕上看得见
/// 红色"不进断言，那是 canvas-macos 后端真窗口批的账。
test "画布：attach/present 上屏状态机" {
  let c = @native-common.canvas_create()
  // 未挂窗：present 拒绝（raise，不崩）
  let naked = try {
    @native-common.canvas_present(c)
    false
  } catch {
    _ => true
  }
  assert_true(naked)
  let title = @utf8.encode("画布上屏探针")
  let win = probe_window_new(title, title.length(), 200, 120)
  assert_true(win != 0L)
  @native-common.canvas_attach_window(c, win)
  // 开帧画满幅底色，收帧上屏；present 幂等（贴两次不炸）
  @native-common.canvas_begin_frame(c, 200, 120)
  @native-common.canvas_fill_rect(c, 0, 0, 200, 120, radius=0.0, rgb=0x3355FF)
  assert_eq(@native-common.canvas_read_pixel(c, 100, 60), 0x3355FF)
  @native-common.canvas_end_frame(c)
  @native-common.canvas_present(c)
  @native-common.canvas_present(c)
  // 换一帧重画再贴：begin_frame 自动作废上一帧（换新位图）
  @native-common.canvas_begin_frame(c, 200, 120)
  @native-common.canvas_fill_rect(c, 0, 0, 200, 120, radius=0.0, rgb=0x00AA55)
  @native-common.canvas_end_frame(c)
  @native-common.canvas_present(c)
  @native-common.canvas_destroy(c)
  probe_window_destroy(win)
}

///|
/// 拖动期跟手（2026-10-19 延迟修复的真窗回归）：mac 拖标题栏时 `windowDidMove:`
/// 只在松手/停顿约半秒才补报，拖动中途 `NSWindow.frame` 还是旧值（CocoaDev/zenn
/// 记载，探针复核）——所以"拖动中途"用测试缝 `native_window_move_external` 模拟
/// （外部移窗、无通知），由拖动期轮询从 WindowServer 读到真实位置、经 live
/// 直达把吸附邻居当场带走。断言在**泵到一半**就该成立：跟手 = 不等拖动结束。
test "原生后端：外部移窗被拖动期轮询发现，吸附邻居当场跟上" {
  let b = open_backend_for_testing(100)
  b.init()
  let app = @moonui.App::new(b)
  let left = app.create_window("左", @moonui.LogicalSize(300.0, 200.0))
  let right = app.create_window("右", @moonui.LogicalSize(300.0, 200.0))
  left.set_position(@moonui.LogicalPoint(100.0, 100.0))
  right.set_position(@moonui.LogicalPoint(406.0, 100.0))
  left.show()
  right.show()
  // 用户把左窗拖到 (+40, +25) 的中途态：窗被外部挪走、AppKit 无通知。
  // 测试缝同 `native_window_set_position` 的契约收物理像素（adapter.h），先把
  // 逻辑目标按窗口 DPI 换算过去——scale≠1 时不换算会把 (140,125) 当物理像素
  // 搬，position() 读回的逻辑值只有它的一半，断言对不上。
  let scale = @moonui.Scale::of_dpi(
    @native-common.native_window_dpi(left.handle()).to_double(),
  )
  let target = scale.to_physical_point(@moonui.LogicalPoint(140.0, 125.0))
  @native-common.native_window_move_external(left.handle(), target.x, target.y)
  // 泵到邻居跟上为止（轮询定时器在 wait_messages 的 run loop 里转，60Hz）。
  // 程序化搬窗的抑制窗（150ms）也在泵的时长里自然过期，不会挡住这条。
  let mut i = 0
  while i < 30 {
    let _ = b.poll_event()
    if close_to(right.position().x, 446.0) &&
      close_to(right.position().y, 125.0) {
      break
    }
    i = i + 1
  }
  assert_true(close_to(left.position().x, 140.0))
  assert_true(close_to(left.position().y, 125.0))
  assert_true(close_to(right.position().x, 446.0))
  assert_true(close_to(right.position().y, 125.0))
  b.terminate()
}

///|
/// 同拍跟手（方案 B 鼠标增量预测的真窗回归）：拖动期位置 = 锚点 + 鼠标位移，
/// 测试缝 `native_window_drag_step` 直接喂预测原点并**同步**走一拍轮询——
/// 发现→补报→吸附联动在缝返回前落定。断言在 `drag_step` **返回后立即**成立
/// （不泵 run loop）：邻居和被拖窗同一拍动，这是"视觉上零延迟"的机械保证。
test "原生后端：合成拖动一拍内邻居同拍跟上（鼠标增量预测）" {
  let b = open_backend_for_testing(100)
  b.init()
  let app = @moonui.App::new(b)
  let left = app.create_window("左", @moonui.LogicalSize(300.0, 200.0))
  let right = app.create_window("右", @moonui.LogicalSize(300.0, 200.0))
  left.set_position(@moonui.LogicalPoint(100.0, 100.0))
  right.set_position(@moonui.LogicalPoint(406.0, 100.0))
  left.show()
  right.show()
  // 缝的坐标契约与 set_position 相同（物理像素），按窗口 DPI 换算再喂。
  let scale = @moonui.Scale::of_dpi(
    @native-common.native_window_dpi(left.handle()).to_double(),
  )
  // 第一拍：左窗被"拖"到 (140, 125)，缝返回即断言（不泵 run loop）。
  let target = scale.to_physical_point(@moonui.LogicalPoint(140.0, 125.0))
  @native-common.native_window_drag_step(left.handle(), target.x, target.y)
  assert_true(close_to(left.position().x, 140.0))
  assert_true(close_to(left.position().y, 125.0))
  assert_true(close_to(right.position().x, 446.0))
  assert_true(close_to(right.position().y, 125.0))
  // 第二拍：继续拖到 (160, 140)，增量推算接着走，还是同一拍落定。
  let target2 = scale.to_physical_point(@moonui.LogicalPoint(160.0, 140.0))
  @native-common.native_window_drag_step(left.handle(), target2.x, target2.y)
  assert_true(close_to(left.position().x, 160.0))
  assert_true(close_to(left.position().y, 140.0))
  assert_true(close_to(right.position().x, 466.0))
  assert_true(close_to(right.position().y, 140.0))
  b.terminate()
}

///|
/// 程序化搬窗不回声成 Moved：`set_position` 登记目标位置并开抑制窗，盖过
/// WindowServer 那一拍提交延迟（探针：set 后立刻查服务器还是旧位置）。拖动期
/// 轮询因此不会把"自己搬的"当成"用户拖的"——否则联动会自拖自、邻居被搬两遍。
test "原生后端：程序化搬窗不回声成 Moved" {
  let b = open_backend_for_testing(100)
  b.init()
  let win = b.create_window("回声", @moonui.LogicalSize(200.0, 150.0))
  b.set_window_position(win, @moonui.LogicalPoint(120.0, 90.0))
  // 泵过抑制窗（150ms）与提交延迟：轮询整趟都该按兵不动
  let mut moved = 0
  let mut i = 0
  while i < 10 {
    match b.poll_event() {
      Some(@moonui.Moved(_, _)) => moved = moved + 1
      _ => ()
    }
    i = i + 1
  }
  assert_eq(moved, 0)
  let origin = b.window_position(win)
  assert_true(close_to(origin.x, 120.0))
  assert_true(close_to(origin.y, 90.0))
  b.terminate()
}

///|
/// T103 断言的公共换算：逻辑坐标 → MoonUI 物理像素（96 = 100%，窗口 DPI
/// 从 `native_window_dpi` 现读，不猜 retina/非 retina）。坐标口径是脚手架
/// 收的那套（客户区左上原点、y 向下）。
fn scaffold_px(v : Double, dpi : Int32) -> Int32 {
  (v * dpi.to_double() / 96.0 + 0.5).to_int()
}

///|
/// 帧中心的物理坐标（脚手架点的就是控件中心）。
fn scaffold_center(f : @moonui.LogicalRect, dpi : Int32) -> (Int32, Int32) {
  (
    scaffold_px(f.origin.x + f.size.width / 2.0, dpi),
    scaffold_px(f.origin.y + f.size.height / 2.0, dpi),
  )
}

///|
/// 键事件流水：只留 KeyDown/KeyUp，压成 "down:s" / "up:s" 形状——键路断言
/// 的通用读法（序、名、有无，修饰键另看 KeyPress 结构）。
fn scaffold_key_log(events : Array[@moonui.Event]) -> Array[String] {
  let out : Array[String] = []
  for ev in events {
    match ev {
      @moonui.KeyDown(_, kp) => out.push("down:\{kp.key}")
      @moonui.KeyUp(_, kp) => out.push("up:\{kp.key}")
      _ => ()
    }
  }
  out
}

///|
/// 把积压的事件排空（一圈一条，最多 8 圈兜底）：焦点搬家的 Focus/Blur、
/// 激活带回的回流都排掉，后面的断言只量自己投进去的那几条。`T103` 真跑
/// 咬出——不排干净时 `App::step` 一圈一条的配额被旧事件吃掉，键事件留在
/// 队列里，断言看到的是空数组。
fn scaffold_drain(
  app : @moonui.App[@native-common.NativeBackend],
) -> Unit raise @moonui.UiError {
  let mut left = 8
  while left > 0 {
    if !app.step() {
      break
    }
    left = left - 1
  }
}

///|
/// T103① 坐标点击：造一对真 NSEvent，按钮 action 走原生路由回流成 Click。
/// 负控制：点窗口空白处报 -4（`adapter.h` 把空白处归「命中不是按钮」那一档），
/// 一个事件都不多。
test "原生后端：坐标点击真落到按钮上，Click 回流（T103）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 原生 脚手架点击",
    @moonui.LogicalSize(300.0, 200.0),
  )
  let btn = @moonui.Widget::button(b, "点我")
  let clicks : Array[String] = []
  let _ = btn.on_any(fn(ev) {
    match ev {
      @moonui.Click(_, _) => clicks.push("Click")
      @moonui.KeyDown(_, kp) => clicks.push("down:\{kp.key}")
      @moonui.MouseMove(_, _) => clicks.push("move")
      _ => clicks.push("other")
    }
  })
  win.set_content(@moonui.Widget::column(b, 12.0, [btn]))
  win.show()
  let _ = app.step()
  // show 后的第一圈会有一条初始 Focus 落进订阅（AppKit 给窗口摆初始
  // first responder），点之前的流水清掉——这条只量点击。
  clicks.clear()
  let dpi = @native-common.native_window_dpi(win.handle())
  let (cx, cy) = scaffold_center(btn.frame(), dpi)
  assert_eq(
    @native-macos.click_button_in_window(
      "MoonUI 原生 脚手架点击", cx, cy,
    ),
    0,
  )
  assert_true(app.step())
  assert_eq(clicks, ["Click"])
  // 负控制：空白处 -4（adapter.h：命中不是按钮的含空白处），按钮一次都没多响
  assert_eq(
    @native-macos.click_button_in_window(
      "MoonUI 原生 脚手架点击", 295, 195,
    ),
    -4,
  )
  assert_false(app.step())
  assert_eq(clicks, ["Click"])
  // 收尾：整棵内容树 + 窗口全拆，句柄表清零（既有真窗批同一范式）。
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// T103② 勾选：点击复选框中心，Core 读回跟着翻——状态不是 mock 出来的。
test "原生后端：坐标点击勾选框，checked 读回跟着翻（T103）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 原生 脚手架勾选",
    @moonui.LogicalSize(300.0, 200.0),
  )
  let cb = @moonui.Widget::checkbox(b, "记住我", false)
  win.set_content(@moonui.Widget::column(b, 12.0, [cb]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let (cx, cy) = scaffold_center(cb.frame(), dpi)
  assert_false(cb.checked())
  assert_eq(
    @native-macos.click_button_in_window(
      "MoonUI 原生 脚手架勾选", cx, cy,
    ),
    0,
  )
  assert_true(app.step())
  assert_true(cb.checked())
  // 再点一下：翻回去——两次都是真点击，不是"点一下就勾上"
  assert_eq(
    @native-macos.click_button_in_window(
      "MoonUI 原生 脚手架勾选", cx, cy,
    ),
    0,
  )
  assert_true(app.step())
  assert_false(cb.checked())
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// T103③ 打字：makeFirstResponder + 共享 field editor，文本系统真改内容
/// （controlTextDidChange: 路由回流成 Input），与真人打字同一条路。
test "原生后端：打字进输入框，文本读回与 Input 事件同账（T103）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 原生 脚手架打字",
    @moonui.LogicalSize(300.0, 200.0),
  )
  let input = @moonui.Widget::text_input(b, "预置")
  let btn = @moonui.Widget::button(b, "不是输入框")
  let texts : Array[String] = []
  let _ = input.on_any(fn(ev) {
    match ev {
      @moonui.Input(_, t) => texts.push(t)
      _ => ()
    }
  })
  // 两个控件一开始就同列：set_content 换树会把旧树整棵关闭（含 input），
  // 后挂回去报"已被其他容器持有"（真跑咬出）。
  win.set_content(@moonui.Widget::column(b, 12.0, [input, btn]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let (cx, cy) = scaffold_center(input.frame(), dpi)
  assert_eq(
    @native-macos.type_text_in_window(
      "MoonUI 原生 脚手架打字", cx, cy, "世界",
    ),
    0,
  )
  assert_true(app.step())
  assert_eq(input.text(), "预置世界")
  assert_eq(texts, ["预置世界"])
  // 负控制：打字目标不是输入框时 -4，文案一字不动
  let (bx, by) = scaffold_center(btn.frame(), dpi)
  assert_eq(
    @native-macos.type_text_in_window(
      "MoonUI 原生 脚手架打字", bx, by, "x",
    ),
    -4,
  )
  assert_false(app.step())
  assert_eq(input.text(), "预置世界")
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// T103④ 改焦点：回读判据 + send_key 的归属跟着焦点走——归属靠焦点而不是
/// 坐标（adapter.h 键盘段注），焦点在谁身上、键就报给谁。
test "原生后端：改焦点真落，send_key 归属跟随（T103）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 原生 脚手架焦点",
    @moonui.LogicalSize(300.0, 220.0),
  )
  let first = @moonui.Widget::text_input(b, "")
  let second = @moonui.Widget::text_input(b, "")
  win.set_content(@moonui.Widget::column(b, 12.0, [first, second]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let title = "MoonUI 原生 脚手架焦点"
  let (sx, sy) = scaffold_center(second.frame(), dpi)
  assert_eq(@native-macos.focus_widget_in_window(title, sx, sy), 0)
  let seen : Array[@moonui.Event] = []
  let _ = app.on_event(second.target(), fn(ev) { seen.push(ev) })
  let _ = app.on_event(first.target(), fn(ev) { seen.push(ev) })
  // 焦点搬家的回流先排空，否则两条键事件被挤到 step 配额之后
  scaffold_drain(app)
  seen.clear()
  assert_eq(@native-macos.send_key_in_window(title, "s", 0, true), 0)
  assert_eq(@native-macos.send_key_in_window(title, "s", 0, false), 0)
  // step 一圈一条，但激活回流（Focus/Blur）会异步插进队列，固定走两圈会被
  // 它吃掉一圈、up 留在队列里（真跑咬出）——排空再断言。
  scaffold_drain(app)
  // down + up 都归第二个输入框（归属靠焦点）
  assert_eq(scaffold_key_log(seen), ["down:s", "up:s"])
  // 换焦点：同样的键现在归第一个
  let (fx, fy) = scaffold_center(first.frame(), dpi)
  assert_eq(@native-macos.focus_widget_in_window(title, fx, fy), 0)
  assert_eq(@native-macos.send_key_in_window(title, "s", 0, true), 0)
  assert_true(app.step())
  assert_eq(scaffold_key_log(seen), ["down:s", "up:s", "down:s"])
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// T103⑤ 键注入基础 + `T96③` 的 KeyUp 半颗：普通键 down/up 两条都到
/// （吞键登记只在被吞/被认领时挂上，普通键的抬起照报）；修饰键位经
/// NSEvent 旗标进 Core 的 KeyPress（ctrl+s 不被任何菜单认领，照报）。
test "原生后端：send_key 真跑 down/up 与修饰键位（T103）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 原生 脚手架键",
    @moonui.LogicalSize(300.0, 200.0),
  )
  let input = @moonui.Widget::text_input(b, "")
  let seen : Array[@moonui.Event] = []
  let _ = app.on_event(input.target(), fn(ev) { seen.push(ev) })
  win.set_content(@moonui.Widget::column(b, 12.0, [input]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let (cx, cy) = scaffold_center(input.frame(), dpi)
  let title = "MoonUI 原生 脚手架键"
  assert_eq(@native-macos.focus_widget_in_window(title, cx, cy), 0)
  // 焦点回流先排空（step 一圈一条，见 scaffold_drain）
  scaffold_drain(app)
  seen.clear()
  assert_eq(@native-macos.send_key_in_window(title, "s", 0, true), 0)
  assert_eq(@native-macos.send_key_in_window(title, "s", 0, false), 0)
  // 一圈一条 + 激活回流会插队：排空再断言（见 scaffold_drain）
  scaffold_drain(app)
  assert_eq(scaffold_key_log(seen), ["down:s", "up:s"])
  // 修饰键位：ctrl+s（bit0）→ KeyPress.ctrl；菜单没装，无人认领照报
  assert_eq(@native-macos.send_key_in_window(title, "s", 1, true), 0)
  assert_true(app.step())
  let mut ctrl_seen = false
  for ev in seen {
    match ev {
      @moonui.KeyDown(_, kp) => if kp.key == "s" && kp.ctrl { ctrl_seen = true }
      _ => ()
    }
  }
  assert_true(ctrl_seen)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T96①` 写回的 ⌘Q 判据 + `T96③` 的吞键半颗：主菜单认领的组合**只响一次
/// 且是 MenuSelect**——KeyDown 不产（监听把认领的组合放给 AppKit 菜单），
/// 配对的 KeyUp 也不漏（吞键登记到达即清）；抬起之后再发一颗无关的键，
/// 照报——吞键登记没有残留。
test "原生后端：⌘Q 被菜单认领只响一次且是 MenuSelect，KeyUp 不漏（T96①/③）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  app.set_menubar(menu_fixture())
  let win = app.create_window(
    "MoonUI 原生 脚手架认领",
    @moonui.LogicalSize(300.0, 200.0),
  )
  let input = @moonui.Widget::text_input(b, "")
  let seen : Array[@moonui.Event] = []
  let quit = @moonui.EventTarget::{ id: 0, generation: 0, }
  let _ = app.on_event(quit, fn(ev) { seen.push(ev) })
  let _ = app.on_event(input.target(), fn(ev) { seen.push(ev) })
  win.set_content(@moonui.Widget::column(b, 12.0, [input]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let (cx, cy) = scaffold_center(input.frame(), dpi)
  let title = "MoonUI 原生 脚手架认领"
  assert_eq(@native-macos.focus_widget_in_window(title, cx, cy), 0)
  let _ = app.step()
  // focus_in_window 的 makeFirstResponder 会回流一条 Focus（归输入框订阅），
  // 排掉再谈认领——这条只量 ⌘Q 的路由。
  seen.clear()
  // ⌘Q 按下：菜单认领 → 不产 KeyDown，MenuSelect 那条路走
  assert_eq(@native-macos.send_key_in_window(title, "q", 8, true), 0)
  assert_true(app.step())
  assert_eq(seen, [@moonui.MenuSelect(quit)])
  // `T96③`：认领的 KeyDown 登记了吞键，配对 KeyUp 到达即吞——没有半颗
  assert_eq(@native-macos.send_key_in_window(title, "q", 8, false), 0)
  scaffold_drain(app)
  assert_eq(seen, [@moonui.MenuSelect(quit)])
  // 登记已清：下一颗无关的键照报（吞键状态机不残留）
  assert_eq(@native-macos.send_key_in_window(title, "s", 0, true), 0)
  scaffold_drain(app)
  assert_eq(scaffold_key_log(seen), ["down:s"])
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// Shift+Tab 的回退 + `T96③`：监听拦下、焦点按 Core 声明的链退一步、
/// 两条（down/up）都吞——链上没有键事件漏出去，焦点真挪了（下一颗键
/// 归退到的那个控件）。
test "原生后端：Shift+Tab 回退焦点且 down/up 都吞（T66/T96③）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 原生 脚手架Tab",
    @moonui.LogicalSize(300.0, 220.0),
  )
  let first = @moonui.Widget::text_input(b, "")
  let second = @moonui.Widget::text_input(b, "")
  win.set_content(@moonui.Widget::column(b, 12.0, [first, second]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let title = "MoonUI 原生 脚手架Tab"
  let (sx, sy) = scaffold_center(second.frame(), dpi)
  assert_eq(@native-macos.focus_widget_in_window(title, sx, sy), 0)
  let seen : Array[@moonui.Event] = []
  let _ = app.on_event(second.target(), fn(ev) { seen.push(ev) })
  let _ = app.on_event(first.target(), fn(ev) { seen.push(ev) })
  // focus_widget_in_window 的 makeFirstResponder 回流 Focus（可能还带一条
  // Blur），排空再谈吞键——这条只量 Shift+Tab 的吞与退。
  scaffold_drain(app)
  seen.clear()
  // Shift+Tab（mods bit2）：拦下退一步，down 吞掉
  assert_eq(@native-macos.send_key_in_window(title, "Tab", 4, true), 0)
  // 配对的 KeyUp 同样吞（`T96③`）
  assert_eq(@native-macos.send_key_in_window(title, "Tab", 4, false), 0)
  // down/up 都被吞，流水干干净净（makeKeyWindow 可能带回 Focus，排空后按键
  // 事件流水判，不赌 step 返回值）
  scaffold_drain(app)
  assert_eq(scaffold_key_log(seen), [])
  // 焦点退到了第一个：下一颗键归它，键事件流水干干净净
  assert_eq(@native-macos.send_key_in_window(title, "s", 0, true), 0)
  scaffold_drain(app)
  assert_eq(scaffold_key_log(seen), ["down:s"])
  let mut on_first = false
  for ev in seen {
    match ev {
      @moonui.KeyDown(t, _) => if t == first.target() { on_first = true }
      _ => ()
    }
  }
  assert_true(on_first)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// 窗口态的轮询读回（`T91②`）：miniaturize/zoom 都是 AppKit 的动画，读回要
/// 泵到真钟上翻过去为止；超时返回 false，断言红在判据上而不是挂住整轮。
fn wait_window_state(
  b : @native-common.NativeBackend,
  app : @moonui.App[@native-common.NativeBackend],
  h : @moonui.NativeHandle,
  want_min : Bool,
  want_max : Bool,
) -> Bool raise @moonui.UiError {
  let deadline = @native-common.native_time_ms() + 2000
  let mut ok = false
  while !ok {
    let s = @moonui.Backend::window_state(b, h)
    if s.minimized == want_min && s.maximized == want_max {
      ok = true
    } else if @native-common.native_time_ms() >= deadline {
      break
    } else {
      let _ = app.step()
    }
  }
  ok
}

///|
/// `T91②` mac 半：miniaturize/zoom 真按与读回。两条 setter 是开关型动作
/// （`miniaturize:` / `zoom:`），判据钉三件事：按下之后原生态真的翻过去、
/// 再按回来又翻回来（含尺寸真的变/回来，不是只翻标志位）、重发同一条意图
/// 不抖（adapter.h 的"只在差异上动"）。
test "原生后端：miniaturize/zoom 真按与读回（T91②）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 原生 窗口态",
    @moonui.LogicalSize(260.0, 180.0),
  )
  win.show()
  let _ = app.step()
  let h = win.handle()
  let s0 = @moonui.Backend::window_state(b, h)
  assert_false(s0.minimized)
  assert_false(s0.maximized)
  // 最小化：真 miniaturize:，读回 bit0
  @moonui.Backend::set_window_minimized(b, h, true)
  assert_true(wait_window_state(b, app, h, true, false))
  // 已最小化时重发同一条意图：AppKit 侧不抖，读回不变
  @moonui.Backend::set_window_minimized(b, h, true)
  let _ = app.step()
  assert_true(@moonui.Backend::window_state(b, h).minimized)
  // 恢复：真 deminiaturize:，bit0 落回
  @moonui.Backend::set_window_minimized(b, h, false)
  assert_true(wait_window_state(b, app, h, false, false))
  // 最大化：真 zoom:，bit1 亮起，而且窗口真的变大了（不是只翻标志位）
  let before = @moonui.Backend::window_size(b, h)
  @moonui.Backend::set_window_maximized(b, h, true)
  assert_true(wait_window_state(b, app, h, false, true))
  let zoomed = @moonui.Backend::window_size(b, h)
  assert_true(zoomed.width > before.width)
  // 已最大化时重发同一条：尺寸一动不动（"只在差异上动"）
  @moonui.Backend::set_window_maximized(b, h, true)
  let _ = app.step()
  assert_eq(@moonui.Backend::window_size(b, h).width, zoomed.width)
  // 取消最大化：再按一次 zoom:，尺寸落回原档
  @moonui.Backend::set_window_maximized(b, h, false)
  assert_true(wait_window_state(b, app, h, false, false))
  assert_true(close_to(@moonui.Backend::window_size(b, h).width, before.width))
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T91⑤` mac 半：NSImageView 真显真图。三层判据——装源之前探针说没有图；
/// 装上 1024×1024 的 PNG 之后探针读回的像素就是文件里那两格；`fittingSize`
/// （走 `widget_minimum_size`）与图像尺寸对账，坏路径按 §33 报错。
/// 探针读的是 `NSImageView.image` 的各 rep，不是本文件记的路径——装是装上了
/// 但没有解码成位图的那种假绿在这里红。
test "原生后端：NSImageView 真显真图，fittingSize 与布局对账（T91⑤）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 原生 图像",
    @moonui.LogicalSize(320.0, 240.0),
  )
  let img = @moonui.Widget::image(b)
  win.set_content(@moonui.Widget::column(b, 0.0, [img]))
  win.show()
  let _ = app.step()
  let h = match img.handle() {
    Some(h) => h
    None => abort("image 没有句柄")
  }
  let (has0, _, _) = @native-common.native_image_probe(h)
  assert_false(has0)
  // 真装一张图：路径通道（解码归平台）
  img.set_image_path("assets/logo/moonui.png")
  let (has, px_w, px_h) = @native-common.native_image_probe(h)
  assert_true(has)
  assert_eq(px_w, 1024)
  assert_eq(px_h, 1024)
  // fittingSize 与布局对账：固有尺寸 = 图像的点尺寸（空 NSImageView 的
  // fittingSize 是 0，这一档同时证明图真进去了）
  let min = @moonui.Backend::widget_intrinsic_size(b, h)
  assert_true(close_to(min.width, 1024.0))
  assert_true(close_to(min.height, 1024.0))
  // 整源替换：换成另一张同样尺寸的图，探针照旧（替换而不是叠加）
  img.set_image_path("assets/logo/luna.png")
  let (has2, w2, h2) = @native-common.native_image_probe(h)
  assert_true(has2)
  assert_eq(w2, 1024)
  assert_eq(h2, 1024)
  // 坏路径：-1 那一档，文案与 MockBackend 同形（§33 调用方错）
  let msg = try {
    img.set_image_path("no/such/image.png")
    "没有报错"
  } catch {
    @moonui.OperationFailed(m) => m
    _ => "别的错"
  }
  assert_eq(
    msg, "图像读不出来（路径不对或格式不受支持）：no/such/image.png",
  )
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T91⑥` mac 半：托盘真图标真菜单 + 通知的如实缺席。探针读的是原生对象
/// 自己的状态（状态项在不在、按钮上有图没图、菜单挂没挂、挂了几项），不是
/// 本文件记得的名单——`statusItemWithLength:` 或 `setMenu:` 哪一步整段删掉
/// 都会红在这里。通知这一档在 `moon test` 的裸二进制里按设计是 -3（UN 那半
/// 只对打进 bundle 的应用有连接，adapter.h 的返回码表），不是没实现。
test "原生后端：托盘真图标真菜单，通知在无 bundle 的进程里如实缺席（T91⑥）" {
  let b = open_backend_for_testing(200)
  b.init()
  let (item0, icon0, menu0, count0) = @native-common.native_tray_probe()
  assert_false(item0)
  assert_false(icon0)
  assert_false(menu0)
  assert_eq(count0, 0)
  // 图标沿 app icon 的 stem 约定（C 侧补 .png），真装到状态条按钮上
  b.set_tray_icon("assets/logo/moonui")
  let (item1, icon1, menu1, count1) = @native-common.native_tray_probe()
  assert_true(item1)
  assert_true(icon1)
  assert_false(menu1)
  assert_eq(count1, 0)
  // 菜单：与菜单栏/上下文菜单同一份打包底座，挂在状态项上
  b.set_tray_menu(
    @moonui.Menu::new("MoonUI", [
      Item(@moonui.MenuItem::new("显示")),
      Separator,
      Item(@moonui.MenuItem::new("退出")),
    ]),
  )
  let (item2, icon2, menu2, count2) = @native-common.native_tray_probe()
  assert_true(item2)
  assert_true(icon2)
  assert_true(menu2)
  assert_eq(count2, 3)
  // 坏图标：-1 那一档
  let imsg = try {
    b.set_tray_icon("no/such/tray")
    "没有报错"
  } catch {
    @moonui.OperationFailed(m) => m
    _ => "别的错"
  }
  assert_eq(
    imsg, "托盘图标文件读不出来（路径不对或格式不受支持）：no/such/tray",
  )
  // 通知：裸测试进程没有 bundle，UN 那半按设计报 -3（不是崩溃、不是假成功）
  let nmsg = try {
    b.notify("MoonUI 测试", "通知在 CLI 里按设计缺席")
    "没有报错"
  } catch {
    @moonui.OperationFailed(m) => m
    _ => "别的错"
  }
  assert_eq(
    nmsg, "系统通知在这个进程形态下不可用（无 bundle）",
  )
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T91①` mac 半：右键真窗 + 上下文菜单真弹 + 弹窗嵌套循环重入 + 编辑中的
/// 输入框照弹。三段判据都是原生给的：
/// ①右键走一对真 NSEvent 经 `sendEvent:`，进程级监听把它翻成
///   `MouseDown(target, Right, point)`，target 与坐标都按真命中和真换算对账；
/// ②菜单真弹（`popUpMenuPositioningItem:` 的追踪循环）且选中项走 item 自己的
///   target/action 回流（替按在追踪循环里点第 2 项）；
/// ③重入：第 ① 份菜单的回调里再弹第 ② 份——两层追踪循环套着也能弹、也能选；
/// ④编辑中的输入框：field editor 拿着焦点时命中反查仍落回文本框，菜单照弹。
test "原生后端：右键真窗 + 上下文菜单真弹、嵌套重入、编辑中的输入框照弹（T91①）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let title = "MoonUI 原生 上下文菜单"
  let win = app.create_window(title, @moonui.LogicalSize(340.0, 240.0))
  let label = @moonui.Widget::label(b, "右键这里")
  let input = @moonui.Widget::text_input(b, "")
  win.set_content(@moonui.Widget::column(b, 8.0, [label, input]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  // ① 右键真窗：一对真 NSEvent 进 sendEvent:，监听同步跑
  let seen : Array[@moonui.Event] = []
  let _ = label.on_any(fn(ev) { seen.push(ev) })
  let (lx, ly) = scaffold_center(label.frame(), dpi)
  assert_eq(@native-macos.right_click_in_window(title, lx, ly), 0)
  scaffold_drain(app)
  let mut right_at : @moonui.LogicalPoint? = None
  for ev in seen {
    match ev {
      @moonui.MouseDown(t, @moonui.Right, p) =>
        if t == label.target() {
          right_at = Some(p)
        }
      _ => ()
    }
  }
  let center = label.frame()
  match right_at {
    Some(p) => {
      // 坐标是监听按原生 locationInWindow 换算回来的（客户区左上原点、逻辑像素）
      assert_true(close_to(p.x, center.origin.x + center.size.width / 2.0))
      assert_true(close_to(p.y, center.origin.y + center.size.height / 2.0))
    }
    None => abort("右键没有回流成 MouseDown(Right)")
  }
  // 负控制：点在客户区外报 -3，不派发
  assert_eq(@native-macos.right_click_in_window(title, -5, -5), -3)
  // ② 菜单真弹：替按在追踪循环里选第 2 项（index 1）
  let first = @moonui.MenuItem::new("一")
  let second = @moonui.MenuItem::new("二")
  let bar = @moonui.MenuBar::new([
    @moonui.Menu::new("Menu", [Item(first), Item(second)]),
  ])
  let clicked : Array[Int32] = []
  assert_eq(@native-macos.auto_pick_context_menu(50, 1), 0)
  @native-common.native_show_context_menu(bar, fn(id) { clicked.push(id) })
  assert_eq(clicked, [second.id])
  // ③ 重入：回调跑在外层菜单的追踪循环里，此时照样能回调后端（读窗口态）
  //    ——嵌套循环没有把 UI 线程锁死。另有一条本机事实记在这里：追踪期间再
  //    弹第二份菜单弹不起来（`popUpMenuPositioningItem:` 立即返回、不产回调），
  //    AppKit 一次只允许一份菜单在追踪。所以"嵌套重入"在这一层是"回调里能
  //    重入后端"，不是"叠两层菜单"；第一层收干净之后重新弹要正常。
  let inner_first = @moonui.MenuItem::new("内一")
  let inner_bar = @moonui.MenuBar::new([
    @moonui.Menu::new("Inner", [Item(inner_first)]),
  ])
  let log : Array[Int32] = []
  let reenter_ok : Array[Bool] = []
  let inner_seen : Array[Int32] = []
  assert_eq(@native-macos.auto_pick_context_menu(30, 0), 0)
  @native-common.native_show_context_menu(bar, fn(id) {
    log.push(id)
    let st = Some(@moonui.Backend::window_state(b, win.handle())) catch {
      _ => None
    }
    match st {
      Some(s) => reenter_ok.push(!s.minimized && !s.maximized)
      None => reenter_ok.push(false)
    }
    let _ = @native-macos.auto_pick_context_menu(30, 0)
    @native-common.native_show_context_menu(inner_bar, fn(inner_id) {
      inner_seen.push(inner_id)
    }) catch {
      _ => ()
    }
  })
  assert_eq(log, [first.id])
  assert_eq(reenter_ok, [true])
  assert_eq(inner_seen, [])
  // 追踪收干净之后重新弹要正常（没有残留的追踪状态）
  let again : Array[Int32] = []
  assert_eq(@native-macos.auto_pick_context_menu(30, 0), 0)
  @native-common.native_show_context_menu(inner_bar, fn(id) { again.push(id) })
  assert_eq(again, [inner_first.id])
  // ④ 编辑中的输入框：先让它进编辑态（field editor 拿焦点、真打一行字），
  //    命中反查要穿过 field editor 落回我们的文本框（和改焦点那条同一把尺），
  //    菜单照弹、回调照走。这里不投真右键：NSTextView 默认的 rightMouseDown:
  //    会先弹它自己的系统菜单（一层同步循环），自动化按不掉——那条边界记在
  //    adapter.h 与 TODO（`T91①` 尾）。
  let (ix, iy) = scaffold_center(input.frame(), dpi)
  assert_eq(@native-macos.focus_widget_in_window(title, ix, iy), 0)
  assert_eq(@native-macos.type_text_in_window(title, ix, iy, "编辑中"), 0)
  scaffold_drain(app)
  assert_eq(@native-macos.focus_widget_in_window(title, ix, iy), 0)
  let editing_clicked : Array[Int32] = []
  assert_eq(@native-macos.auto_pick_context_menu(50, 0), 0)
  @native-common.native_show_context_menu(bar, fn(id) {
    editing_clicked.push(id)
  })
  assert_eq(editing_clicked, [first.id])
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T91③` mac 半：文件拖入的三件真事。
/// ①接受门与登记：窗口建出来时后端就惰性装上了监听（`drag_installed`），
///   contentView 也登记了 file URL 这一档拖入类型；替投在没监听时被拒、
///   装上后真接。
/// ②往返回路：替投用**真 NSPasteboard** 写 file URL，走 destination 自己那条
///   "读 pasteboard → UTF-8 → i32 打包"的路，后端再把它翻成 `FileDrop` 事件
///   推给 Core——路径原样两条回来（含中文与空格），target 是这只窗口。
/// ③field editor 边界：编辑中的文本框上方命中的是 NSTextView（它自己就是
///   destination，拖拽在这一层停住），非文本控件则递退到窗口那一层。
test "原生后端：文件拖入真收到、路径往返、field editor 边界（T91③）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let title = "MoonUI 原生 拖入"
  let win = app.create_window(title, @moonui.LogicalSize(340.0, 240.0))
  let label = @moonui.Widget::label(b, "拖到这里")
  let input = @moonui.Widget::text_input(b, "")
  win.set_content(@moonui.Widget::column(b, 8.0, [label, input]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  // ① 监听与类型登记：建窗口时就都做了（后端惰性装的第一条窗口）
  let (installed0, registered0, taken0) = @native-macos.file_drop_probe(title)
  assert_true(installed0)
  assert_true(registered0)
  assert_false(taken0)
  // 负控制：窗口不存在时替投报 -2，不产事件
  assert_eq(
    @native-macos.simulate_file_drop("MoonUI 原生 没有这只窗", [
      "/tmp/a.txt",
    ]),
    -2,
  )
  // ② 真投两条（含中文与空格）：真 pasteboard → 打包 → unpack → FileDrop 事件
  let events : Array[@moonui.Event] = []
  let _ = app.on_event(win.target(), fn(ev) { events.push(ev) })
  assert_eq(
    @native-macos.simulate_file_drop(title, [
      "/tmp/一.txt", "/tmp/二 空格.txt",
    ]),
    0,
  )
  scaffold_drain(app)
  let mut dropped : Array[String]? = None
  for ev in events {
    match ev {
      @moonui.FileDrop(t, paths) =>
        if t == win.target() {
          dropped = Some(paths)
        }
      _ => ()
    }
  }
  assert_eq(dropped, Some(["/tmp/一.txt", "/tmp/二 空格.txt"]))
  let (_, _, taken2) = @native-macos.file_drop_probe(title)
  assert_true(taken2)
  // ③ field editor 边界：编辑中的文本框上方由 NSTextView 自己接
  let (ix, iy) = scaffold_center(input.frame(), dpi)
  assert_eq(@native-macos.focus_widget_in_window(title, ix, iy), 0)
  assert_eq(@native-macos.type_text_in_window(title, ix, iy, "编辑中"), 0)
  scaffold_drain(app)
  assert_eq(@native-macos.drag_hit_probe(title, ix, iy), 1)
  let (lx, ly) = scaffold_center(label.frame(), dpi)
  assert_eq(@native-macos.drag_hit_probe(title, lx, ly), 0)
  // 负控制：窗口外报 -3
  assert_eq(@native-macos.drag_hit_probe(title, -5, -5), -3)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T90④` mac 半：输入法组合相位真跑——单行与多行两侧同一条链。
///
/// 判据全部落在"Core 收到什么"上，替投的是输入法真正调的那两条
/// NSTextInputClient 方法（`setMarkedText:` / `insertText:`），不是把回调再调一遍：
/// ①单行：组合串逐步变（ni → nihao），每步一条 compose（同串的两轮通知只发
///   一次，不回声）；上屏"你好"收 end，全文随既有 Input 通道回 Core；
/// ②多行（`T90④` 补的那一半）：同一套，kind 10 的 NSTextView 走
///   `moonui_native_ime_editor_of` 的另一支；
/// ③取消：组合中上屏空串 = 撤掉标记串，相位只收 end、文本不留痕；
/// ④替投真按命中走：label 上报 -4（不是文本控件），没有这只窗报 -2。
test "原生后端：单行与多行的输入法组合相位都真跑（T90④）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let title = "MoonUI 原生 组合"
  let win = app.create_window(title, @moonui.LogicalSize(360.0, 320.0))
  let label = @moonui.Widget::label(b, "不是文本控件")
  let input = @moonui.Widget::text_input(b, "")
  let ml = @moonui.Widget::multiline(b, "")
  let _ = ml.height(80.0)
  win.set_content(@moonui.Widget::column(b, 8.0, [label, input, ml]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let (ix, iy) = scaffold_center(input.frame(), dpi)
  let (mx, my) = scaffold_center(ml.frame(), dpi)
  let (lx, ly) = scaffold_center(label.frame(), dpi)
  let seq : Array[String] = []
  let _ = input.on(
    fn(ev) {
      ev is @moonui.ImeStart(_) ||
      ev is @moonui.ImeCompose(_, _) ||
      ev is @moonui.ImeEnd(_)
    },
    fn(ev) {
      match ev {
        @moonui.ImeStart(_) => seq.push("start")
        @moonui.ImeCompose(_, s) => seq.push("compose:" + s)
        @moonui.ImeEnd(_) => seq.push("end")
        _ => ()
      }
    },
  )
  let ml_seq : Array[String] = []
  let _ = ml.on(
    fn(ev) {
      ev is @moonui.ImeStart(_) ||
      ev is @moonui.ImeCompose(_, _) ||
      ev is @moonui.ImeEnd(_)
    },
    fn(ev) {
      match ev {
        @moonui.ImeStart(_) => ml_seq.push("start")
        @moonui.ImeCompose(_, s) => ml_seq.push("compose:" + s)
        @moonui.ImeEnd(_) => ml_seq.push("end")
        _ => ()
      }
    },
  )
  // ④ 先打两条负控制：替投按坐标命中走，不是"不看坐标直接调"
  assert_eq(
    @native-macos.ime_compose_in_window(
      "MoonUI 原生 没有这只窗", ix, iy, "x",
    ),
    -2,
  )
  assert_eq(@native-macos.ime_compose_in_window(title, lx, ly, "x"), -4)
  assert_eq(seq, [])
  // ① 单行：两次组合（串加深）+ 上屏
  assert_eq(@native-macos.ime_compose_in_window(title, ix, iy, "ni"), 0)
  scaffold_drain(app)
  assert_eq(seq, ["start", "compose:ni"])
  assert_eq(@native-macos.ime_compose_in_window(title, ix, iy, "nihao"), 0)
  scaffold_drain(app)
  assert_eq(seq, ["start", "compose:ni", "compose:nihao"])
  assert_eq(@native-macos.ime_commit_in_window(title, ix, iy, "你好"), 0)
  scaffold_drain(app)
  assert_eq(seq, ["start", "compose:ni", "compose:nihao", "end"])
  // ② 多行：同一套（相位认的是多行的 NSTextView）
  assert_eq(@native-macos.ime_compose_in_window(title, mx, my, "zhong"), 0)
  scaffold_drain(app)
  assert_eq(ml_seq, ["start", "compose:zhong"])
  assert_eq(@native-macos.ime_commit_in_window(title, mx, my, "中"), 0)
  scaffold_drain(app)
  assert_eq(ml_seq, ["start", "compose:zhong", "end"])
  assert_eq(ml.text(), "中")
  // ③ 取消：组合中上屏空串 = 撤掉标记串，相位只收 end、文本不留痕
  assert_eq(@native-macos.ime_compose_in_window(title, mx, my, "quxiao"), 0)
  scaffold_drain(app)
  assert_eq(ml.text(), "中quxiao")
  assert_eq(@native-macos.ime_commit_in_window(title, mx, my, ""), 0)
  scaffold_drain(app)
  assert_eq(ml_seq, [
    "start", "compose:zhong", "end", "start", "compose:quxiao", "end",
  ])
  assert_eq(ml.text(), "中")
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T90⑤` mac 半：组合中程序化改文本不打断组合，上屏后文本照常回声到 Core。
///
/// `T90④` 把相位链修通之后，这条原本"真窗欠手工一次"的判据可以自动化：替投
/// 输入法真正调的那两条方法，中间插一次产品侧的 `Widget::set_text`。
/// ①组合中改文本：原生那侧直接 `setString:` 会把标记区间一起清掉（输入法脚下
///   的文本被整段换走），表现成 Core 收到一条 end、组合串凭空消失——现在先取
///   标记串、写正文、再原样标回去，相位一条都不多发，文本是新正文 + 组合串；
/// ②组合没断：紧接着再组合一次，相位只多一条"进行"，没有 start/end 插队；
/// ③上屏：收 end、全文随既有 `Input` 通道回 Core（回声），组合串不残留；
/// ④多行（kind 10）同一套，多测一次"组合中连着改两次文本"；
/// ⑤负控制：不在组合中改文本不发任何相位，文本就是赋进去的值。
test "原生后端：组合中 set_text 保留组合、上屏回声（T90⑤）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let title = "MoonUI 原生 组合改文本"
  let win = app.create_window(title, @moonui.LogicalSize(360.0, 320.0))
  let input = @moonui.Widget::text_input(b, "")
  let ml = @moonui.Widget::multiline(b, "")
  let _ = ml.height(80.0)
  win.set_content(@moonui.Widget::column(b, 8.0, [input, ml]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let (ix, iy) = scaffold_center(input.frame(), dpi)
  let (mx, my) = scaffold_center(ml.frame(), dpi)
  let seq : Array[String] = []
  let inputs : Array[String] = []
  let _ = input.on(
    fn(ev) {
      ev is @moonui.ImeStart(_) ||
      ev is @moonui.ImeCompose(_, _) ||
      ev is @moonui.ImeEnd(_) ||
      ev is @moonui.Input(_, _)
    },
    fn(ev) {
      match ev {
        @moonui.ImeStart(_) => seq.push("start")
        @moonui.ImeCompose(_, s) => seq.push("compose:" + s)
        @moonui.ImeEnd(_) => seq.push("end")
        @moonui.Input(_, s) => inputs.push(s)
        _ => ()
      }
    },
  )
  let ml_seq : Array[String] = []
  let _ = ml.on(
    fn(ev) {
      ev is @moonui.ImeStart(_) ||
      ev is @moonui.ImeCompose(_, _) ||
      ev is @moonui.ImeEnd(_)
    },
    fn(ev) {
      match ev {
        @moonui.ImeStart(_) => ml_seq.push("start")
        @moonui.ImeCompose(_, s) => ml_seq.push("compose:" + s)
        @moonui.ImeEnd(_) => ml_seq.push("end")
        _ => ()
      }
    },
  )
  // ① 单行：组合中改文本，组合串留在文末，相位不许多出 end
  assert_eq(@native-macos.ime_compose_in_window(title, ix, iy, "ni"), 0)
  scaffold_drain(app)
  assert_eq(seq, ["start", "compose:ni"])
  input.set_text("abc")
  scaffold_drain(app)
  assert_eq(seq, ["start", "compose:ni"])
  assert_eq(input.text(), "abcni")
  // ② 组合没断：再组合一次只多一条"进行"
  assert_eq(@native-macos.ime_compose_in_window(title, ix, iy, "nihao"), 0)
  scaffold_drain(app)
  assert_eq(seq, ["start", "compose:ni", "compose:nihao"])
  // ③ 上屏：end + 文本回声（Input 事件带全文），组合串不残留
  assert_eq(@native-macos.ime_commit_in_window(title, ix, iy, "你好"), 0)
  scaffold_drain(app)
  assert_eq(seq, ["start", "compose:ni", "compose:nihao", "end"])
  assert_eq(input.text(), "你好")
  assert_eq(inputs[inputs.length() - 1], "你好")
  // ④ 多行：同一套，组合中连改两次文本
  assert_eq(@native-macos.ime_compose_in_window(title, mx, my, "zhong"), 0)
  scaffold_drain(app)
  assert_eq(ml_seq, ["start", "compose:zhong"])
  ml.set_text("xyz")
  scaffold_drain(app)
  assert_eq(ml_seq, ["start", "compose:zhong"])
  assert_eq(ml.text(), "xyzzhong")
  ml.set_text("xyz2")
  scaffold_drain(app)
  assert_eq(ml_seq, ["start", "compose:zhong"])
  assert_eq(ml.text(), "xyz2zhong")
  // 组合还在：再组合只多一条"进行"
  assert_eq(@native-macos.ime_compose_in_window(title, mx, my, "zhongyao"), 0)
  scaffold_drain(app)
  assert_eq(ml_seq, ["start", "compose:zhong", "compose:zhongyao"])
  assert_eq(@native-macos.ime_commit_in_window(title, mx, my, "中"), 0)
  scaffold_drain(app)
  assert_eq(ml_seq, ["start", "compose:zhong", "compose:zhongyao", "end"])
  assert_eq(ml.text(), "xyz2中")
  // ⑤ 负控制：不在组合中改文本，相位一条都不多发，文本就是赋的值
  let before = seq.length()
  ml.set_text("普通赋值")
  scaffold_drain(app)
  assert_eq(ml_seq.length(), 4)
  assert_eq(seq.length(), before)
  assert_eq(ml.text(), "普通赋值")
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T91⑥` 的"点一下"半：真弹窗（`performClick:` + 追踪循环）在并行测试里会挂死
/// （`T105` 查并行时实测，那半退回人手一次），这里固化为**选中派发**——
/// `performActionForItemAtIndex:` 走 item 自己的 target/action，与用户点中这一项
/// 同一条路，考察的仍是"点了之后 Core 收到什么"。
/// ①没装状态项时 -1；②选中普通项：菜单回调真跑，参数是被选中的那一项；
/// ③选中勾选项：Core 的菜单语义照走（checked 翻转），证明落的是 `bar.click` 那条；
/// ④越界 -2，且一条回调都不多。
test "原生后端：托盘菜单选中派发，回流走 Core 的菜单语义（T91⑥）" {
  let b = open_backend_for_testing(200)
  b.init()
  // ① 没有状态项：-1（不是崩溃、不是假成功）
  assert_eq(@native-macos.click_tray_item(0), -1)
  b.set_tray_icon("assets/logo/moonui")
  let hits : Array[String] = []
  let show_item = @moonui.MenuItem::new("显示")
  let _ = show_item.on(fn(_it) { hits.push("显示") })
  let pin_item = @moonui.MenuItem::checkbox("钉住")
  let _ = pin_item.on(fn(_it) { hits.push("钉住") })
  b.set_tray_menu(
    @moonui.Menu::new("MoonUI", [
      Item(show_item),
      Separator,
      Item(pin_item),
      Item(@moonui.MenuItem::new("退出")),
    ]),
  )
  // ② 选中第 0 项：派发当场到 item 的 target/action
  assert_eq(@native-macos.click_tray_item(0), 0)
  assert_eq(hits, ["显示"])
  // ③ 点勾选项（下标 2，1 是分隔符）：勾选态翻转，说明走的是 Core 的菜单语义
  assert_false(pin_item.is_checked())
  assert_eq(@native-macos.click_tray_item(2), 0)
  assert_eq(hits, ["显示", "钉住"])
  assert_true(pin_item.is_checked())
  // ④ 越界：-2，一条回调都不多
  assert_eq(@native-macos.click_tray_item(9), -2)
  assert_eq(hits, ["显示", "钉住"])
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// 手势流水：只留 `Gesture` 的载荷，压成数组——手势路断言只量"哪一种手势、
/// 带什么量、什么相位"，target 另看（同一个数组里窗口与控件两条订阅混着收）。
fn scaffold_gesture_log(
  events : Array[@moonui.Event],
) -> Array[@moonui.Gesture] {
  let out : Array[@moonui.Gesture] = []
  for ev in events {
    match ev {
      @moonui.Gesture(_, g) => out.push(g)
      _ => ()
    }
  }
  out
}

///|
/// `T100` mac 半：触控板手势从原生侧真到达 Core。
/// ①捏合三步（began / changed / ended）：`Event::Gesture(target,
///   Gesture::Magnify(d, phase))`，`d` 是相对增量、**原样**到达（0.02 那一档
///   不许被归整成 0——C 侧是定点百万分之一，除回来还是同一个数）；
/// ②旋转：脚手架按 `NSEvent.rotation` 的单位收**角度**，C 里那个与产品路径
///   共用的 `moonui_native_rad_of_deg` 换成弧度后到达 Core——这条钉的是
///   "角度换弧度只做一次、方向不反"，把换算写反或写漏都红在这里；
/// ③双指滑动四向各一条，相位恒 changed、价量恒 0（离散事件没有中间态）；
/// ④归属：落在控件上报控件，落在窗口空白处报**窗口自己**（与滚轮同一条口径）；
/// ⑤负控制：点在客户区外 -3、窗口不存在 -2，一条事件都不多。
test "原生后端：触控板手势真到达 Core，三种手势各自的量与归属（T100）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let title = "MoonUI 原生 手势"
  let win = app.create_window(title, @moonui.LogicalSize(360.0, 260.0))
  let label = @moonui.Widget::label(b, "捏我")
  win.set_content(@moonui.Widget::column(b, 8.0, [label]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  // 两条订阅合成一个流水：控件那半验归属、窗口那半验空白处落到窗口自己。
  let events : Array[@moonui.Event] = []
  let _ = app.on_event(label.target(), fn(ev) { events.push(ev) })
  let _ = app.on_event(win.target(), fn(ev) { events.push(ev) })
  let (cx, cy) = scaffold_center(label.frame(), dpi)
  // ① 捏合三步：增量与相位都原样到达
  assert_eq(@native-macos.magnify_in_window(title, cx, cy, 0.02, 0), 0)
  assert_eq(@native-macos.magnify_in_window(title, cx, cy, 0.05, 1), 0)
  assert_eq(@native-macos.magnify_in_window(title, cx, cy, 0.0, 2), 0)
  scaffold_drain(app)
  assert_eq(scaffold_gesture_log(events), [
    @moonui.Gesture::Magnify(0.02, @moonui.GesturePhase::Began),
    @moonui.Gesture::Magnify(0.05, @moonui.GesturePhase::Changed),
    @moonui.Gesture::Magnify(0.0, @moonui.GesturePhase::Ended),
  ])
  // 归属：三条都落在 label 上（不是窗口），target 逐条对得上
  for ev in events {
    match ev {
      @moonui.Gesture(t, _) => assert_eq(t, label.target())
      _ => ()
    }
  }
  // ② 旋转：脚手架收的是角度（与 NSEvent.rotation 同一个单位），C 里那个与
  //    产品路径共用的换算把 90° 换成 1.570796 弧度、-45° 换成 -0.785398
  //    （逆时针为正，所以逆时针转回来是负号）
  events.clear()
  assert_eq(@native-macos.rotate_in_window(title, cx, cy, 90.0, 1), 0)
  assert_eq(@native-macos.rotate_in_window(title, cx, cy, -45.0, 1), 0)
  scaffold_drain(app)
  assert_eq(scaffold_gesture_log(events), [
    @moonui.Gesture::Rotate(1.570796, @moonui.GesturePhase::Changed),
    @moonui.Gesture::Rotate(-0.785398, @moonui.GesturePhase::Changed),
  ])
  // ③ 双指滑动四向：左 / 右 / 上 / 下各一条（编码 0/1/2/3）
  events.clear()
  assert_eq(@native-macos.swipe_in_window(title, cx, cy, 0), 0)
  assert_eq(@native-macos.swipe_in_window(title, cx, cy, 1), 0)
  assert_eq(@native-macos.swipe_in_window(title, cx, cy, 2), 0)
  assert_eq(@native-macos.swipe_in_window(title, cx, cy, 3), 0)
  scaffold_drain(app)
  assert_eq(scaffold_gesture_log(events), [
    @moonui.Gesture::Swipe(@moonui.SwipeDirection::Left),
    @moonui.Gesture::Swipe(@moonui.SwipeDirection::Right),
    @moonui.Gesture::Swipe(@moonui.SwipeDirection::Up),
    @moonui.Gesture::Swipe(@moonui.SwipeDirection::Down),
  ])
  // ④ 空白处：报窗口自己（自绘半按 ptr 反查窗口，报控件它会整条丢）
  events.clear()
  let empty_x = scaffold_px(180.0, dpi)
  let empty_y = scaffold_px(240.0, dpi)
  assert_eq(@native-macos.magnify_in_window(title, empty_x, empty_y, 0.1, 1), 0)
  scaffold_drain(app)
  let mut blank_target : @moonui.EventTarget? = None
  for ev in events {
    match ev {
      @moonui.Gesture(t, _) => blank_target = Some(t)
      _ => ()
    }
  }
  assert_eq(blank_target, Some(win.target()))
  // ⑤ 负控制：客户区外 -3、没这只窗 -2，一条事件都不多
  events.clear()
  assert_eq(@native-macos.magnify_in_window(title, -50, -50, 0.1, 1), -3)
  assert_eq(
    @native-macos.swipe_in_window("MoonUI 原生 没有这只窗", cx, cy, 0),
    -2,
  )
  scaffold_drain(app)
  assert_eq(scaffold_gesture_log(events), [])
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// T101：自定义绘制面（`WidgetKind::Custom`）在原生后端是"一只空 NSView +
/// 一层位图"。这条测的是那两层之间的账：布局把面摆到该在的地方、绘制清单重放
/// 之后位图真的贴在**这只 view 自己的** layer 上、坐标没有翻错、点击按
/// "按下并原地抬起"回流成 Click。
///
/// 为什么不用 `RecordCanvas` 断言清单：清单对不对是 Core 层的事（Core 侧已有
/// mock 判据），这里要证明的是"位图贴对了地方"——所以探针读的是图层里的成品
/// 像素，不是重放记录。诚实边界：这只证明 `layer.contents` 里有这些像素，
/// 不证明合成器把窗口扫到了屏上（真上屏归 §51 的 FP1 手测）。
test "原生后端：自定义绘制面真画进自己的图层，像素可寻址（T101）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let title = "MoonUI 原生 自定义绘制面"
  let win = app.create_window(title, @moonui.LogicalSize(320.0, 240.0))
  // 左上角那块的颜色由外部变量决定：改它再 repaint，就能验证"整份新清单"
  // 覆盖了旧帧（叠着画的话旧红不会消失）
  let mut accent = 0xFF0000
  let face = @moonui.Widget::custom(b, @moonui.LogicalSize(160.0, 80.0), fn(
    dl,
    env,
  ) {
    dl.fill_rect(0.0, 0.0, env.width(), env.height(), rgb=0x2B6CB0)
    dl.fill_rect(0.0, 0.0, 8.0, 8.0, rgb=accent)
    dl.fill_rect(0.0, env.height() - 8.0, 8.0, 8.0, rgb=0x00FF00)
  })
  let clicks : Array[String] = []
  let _ = face.on_any(fn(ev) {
    match ev {
      @moonui.Click(_, _) => clicks.push("Click")
      _ => ()
    }
  })
  win.set_content(@moonui.Widget::column(b, 12.0, [face]))
  win.show()
  let _ = app.step()
  clicks.clear()
  // ① 布局：列容器的唯一孩子摆在客户区左上，尺寸就是声明值
  assert_eq(
    face.frame(),
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(160.0, 80.0),
    ),
  )
  let dpi = @native-common.native_window_dpi(win.handle())
  // 逻辑坐标 → 探针口径（客户区左上原点、物理像素）
  let at = fn(x : Double, y : Double) -> Int64 {
    @native-macos.custom_probe(title, scaffold_px(x, dpi), scaffold_px(y, dpi))
  }
  // ② 三个点：左上角那块、正中、左下角那块。后两个一起钉住 y 没翻错——
  //    只测一个点的话"上下镜像"这种错照样能过。
  // 先排空：自定义面的首帧是懒显示，单步 step 后 layer.contents 未必已落地，
  // 探针会读到"还没画绿"的半成品；排空若干圈让它真正 present 再读。
  scaffold_drain(app)
  assert_eq(at(4.0, 4.0), 0xFF0000FF)
  assert_eq(at(80.0, 40.0), 0x2B6CB0FF)
  assert_eq(at(4.0, 76.0), 0x00FF00FF)
  // ③ repaint：同一张位图上重画整份清单，旧颜色不残留
  accent = 0xFF00FF
  face.repaint()
  assert_eq(at(4.0, 4.0), 0xFF00FFFF)
  assert_eq(at(80.0, 40.0), 0x2B6CB0FF)
  // ④ 点击：面自己的 mouseDown:/mouseUp: 真跑，按下并原地抬起算一次 Click
  let (cx, cy) = scaffold_center(face.frame(), dpi)
  assert_eq(@native-macos.click_custom_in_window(title, cx, cy), 0)
  scaffold_drain(app)
  assert_eq(clicks, ["Click"])
  // ⑤ 负控制：面之外的空白处不是自定义面（-2），点同一处 -4，都不多出声
  assert_eq(at(300.0, 200.0), -2)
  assert_eq(
    @native-macos.click_custom_in_window(
      title,
      scaffold_px(300.0, dpi),
      scaffold_px(200.0, dpi),
    ),
    -4,
  )
  scaffold_drain(app)
  assert_eq(clicks, ["Click"])
  // ⑥ 负控制：没有这只窗时探针 -1、点击 -2
  assert_eq(
    @native-macos.custom_probe("MoonUI 原生 没有这只窗", 4, 4),
    -1,
  )
  assert_eq(
    @native-macos.click_custom_in_window(
      "MoonUI 原生 没有这只窗", cx, cy,
    ),
    -2,
  )
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// T102 第十一刀：自绘面的键盘焦点 opt-in。第十刀的方向键导航在 Core 里已通，
/// 但真窗上 `KeyDown` 的归属由 firstResponder 决定——`T101` 的自绘面此前恒
/// `acceptsFirstResponder = NO`，点它、按方向键派给的是窗口，导航一格都走不动。
///
/// 这条钉三件事：没声明的面**拿不到**键盘（显示后在焦点链里被它自己拒掉，
/// 键没人接，脚手架 -3）；点它也不抢（`mouseDown:` 只在声明过时才
/// `makeFirstResponder:`）；声明过的那块点一下就拿到焦点，真 NSEvent 于是派给
/// 它；同窗里点没声明的邻居**不从**键盘面手里抢走焦点（"别把每块只画东西的面
/// 塞进焦点体系"正是默认关的理由）。
///
/// 为什么"显示后键没人接"也得钉：初始响应者是焦点链首，而链是
/// `collect_native` 的全量叶子；一块拒收焦点的面落在链首时，得由 AppKit 沿环
/// 找到第一个肯接受的面——窗口甲只有这么一块，所以整个窗口没有落脚点。
///
/// 诚实边界：这里投的是真 NSEvent 经 `sendEvent:`，走的仍是进程级监听 +
/// firstResponder 反查那条真路；没钉的是"用户手指按 Tab 时 AppKit 的键视图环
/// 顺序"（那要人看一眼，归 §51 手测）。
test "原生后端：自绘面焦点 opt-in 后真收键盘，默认面不抢焦点（T102）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let title = "MoonUI 原生 自绘面焦点"
  let win = app.create_window(title, @moonui.LogicalSize(320.0, 240.0))
  let plain_log : Array[String] = []
  let keys_log : Array[String] = []
  let plain = @moonui.Widget::custom(b, @moonui.LogicalSize(160.0, 80.0), fn(
    _dl,
    _env,
  ) {

  })
  let _ = plain.on_any(fn(ev) {
    match ev {
      @moonui.KeyDown(_, kp) => plain_log.push(kp.key)
      _ => ()
    }
  })
  win.set_content(@moonui.Widget::column(b, 12.0, [plain]))
  win.show()
  let _ = app.step()
  scaffold_drain(app)
  let dpi = @native-common.native_window_dpi(win.handle())
  let (px, py) = scaffold_center(plain.frame(), dpi)
  // ① 显示后没人接键：链首这块面自己拒掉焦点，AppKit 沿环也找不到下一个
  assert_eq(@native-macos.send_key_in_window(title, "Right", 0, true), -3)
  // ② 点它也不抢：mouseDown 只在声明过时才落焦点
  assert_eq(@native-macos.click_custom_in_window(title, px, py), 0)
  scaffold_drain(app)
  assert_eq(@native-macos.send_key_in_window(title, "Right", 0, true), -3)
  assert_eq(plain_log, [])
  // ③ 换成一块声明过要键盘的面（换树发生在窗口已是 key 之后）
  let keys = @moonui.Widget::custom(
    b,
    @moonui.LogicalSize(160.0, 80.0),
    fn(_dl, _env) {  },
    focusable=true,
  )
  let _ = keys.on_any(fn(ev) {
    match ev {
      @moonui.KeyDown(_, kp) => keys_log.push(kp.key)
      _ => ()
    }
  })
  win.set_content(@moonui.Widget::column(b, 12.0, [keys]))
  let _ = app.step()
  scaffold_drain(app)
  let (kx, ky) = scaffold_center(keys.frame(), dpi)
  // ④ 换树本身不挪焦点（初始响应者只在窗口成为 key 那一刻生效）
  assert_eq(@native-macos.send_key_in_window(title, "Home", 0, true), -3)
  // ⑤ 点它 → 拿到焦点 → 真 NSEvent 派给它
  assert_eq(@native-macos.click_custom_in_window(title, kx, ky), 0)
  scaffold_drain(app)
  assert_eq(@native-macos.send_key_in_window(title, "Right", 0, true), 0)
  assert_eq(@native-macos.send_key_in_window(title, "Right", 0, false), 0)
  scaffold_drain(app)
  assert_eq(keys_log, ["Right"])
  // ⑥ 回读焦点确实落在它身上（不是"派给了窗口"的假绿）
  assert_eq(@native-macos.focus_widget_in_window(title, kx, ky), 0)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// T108：鼠标动作通用投送的 mac 半。这条 ABI（`send_mouse_in_window`）此前全仓
/// 只有 Windows 一份定义，mac 侧**滚轮 / 拖动 / 双击 / 中键**四类一个自动化
/// 入口都没有——真窗 41 条里的鼠标只有三条专用口子（点按钮 / 右键 / 点自定义
/// 面）。这条钉的是"投出去的事件真被进程级监听看见"：坐标命中、kind/button
/// 编码、滚轮增量换算全由原生给，不是把回调调一遍。
///
/// 滚轮那一支的判据形状是**往返自逆**：请求给的是"Core 该看到的逻辑像素"，
/// C 按自然滚动旗标翻一次送成原生事件，监听读回时再翻一次——旗标读反、多除
/// 一次 Scale、符号丢在某一支，都红在这里（钉不住的是"真手指往下推到底是
/// 不是正"，那一半要人在 examples 里看一眼）。
///
/// 诚实边界：kind 0/1/3（按下/抬起/双击）在原生后端上没有 Core 侧翻译（闭包
/// 注释记案：左键的既有消费者是控件回调发的 Click），所以那几支这里只钉"投
/// 得出去、不多出事件、按钮的 Click 照旧回流"，不假装它们进了事件队列。
test "原生后端：滚轮/拖动/双击/中键真投到鼠标监听，增量往返自逆（T108）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let title = "MoonUI 原生 鼠标投送"
  let win = app.create_window(title, @moonui.LogicalSize(400.0, 300.0))
  let btn = @moonui.Widget::button(b, "投我")
  let label = @moonui.Widget::label(b, "一块文字")
  win.set_content(@moonui.Widget::column(b, 8.0, [btn, label]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  // 三个 target 合成一条流水：滚轮报窗口自己（mac 的滚轮是整窗手势），其余
  // 报命中的控件。
  let events : Array[@moonui.Event] = []
  let _ = app.on_event(win.target(), fn(ev) { events.push(ev) })
  let _ = app.on_event(btn.target(), fn(ev) { events.push(ev) })
  let _ = app.on_event(label.target(), fn(ev) { events.push(ev) })
  let (bx, by) = scaffold_center(btn.frame(), dpi)
  let (lx, ly) = scaffold_center(label.frame(), dpi)
  let kb = @native-macos.mouse_kind_button
  // ① 滚轮：40 进 40 出，target 是窗口自己（mac 侧滚轮恒报窗口）
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(4, 0), lx, ly, 0, 40),
    0,
  )
  scaffold_drain(app)
  assert_eq(events, [
    @moonui.Scroll(win.target(), @moonui.LogicalPoint(0.0, 40.0)),
  ])
  // ② 横向滚轮 + 反向：dx 走另一条轴，负数原样回来
  events.clear()
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(4, 0), lx, ly, -12, 0),
    0,
  )
  scaffold_drain(app)
  assert_eq(events, [
    @moonui.Scroll(win.target(), @moonui.LogicalPoint(-12.0, 0.0)),
  ])
  // ③ 拖动（kind 2 按住左键）：命中 label，坐标按逻辑像素回来（不是物理）
  events.clear()
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(2, 0), lx, ly, 0, 0),
    0,
  )
  scaffold_drain(app)
  let f = label.frame()
  assert_eq(events, [
    // 前面那条 MouseEnter 是 Core 的悬停通道自己补的（第一次进这个控件），
    // 顺带把"进入 → 移动"这条链也钉住了
    @moonui.MouseEnter(label.target()),
    @moonui.MouseMove(
      label.target(),
      @moonui.LogicalPoint(
        f.origin.x + f.size.width / 2.0,
        f.origin.y + f.size.height / 2.0,
      ),
    ),
  ])
  // ④ 中键按下：投得出去，但原生后端没有中键消费者——一条事件都不多
  events.clear()
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(0, 2), lx, ly, 0, 0),
    0,
  )
  scaffold_drain(app)
  assert_eq(events, [])
  // ⑤ 双击按钮：NSButton 的 action 在按下那颗上，第二次照样触发
  events.clear()
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(3, 0), bx, by, 0, 0),
    0,
  )
  scaffold_drain(app)
  assert_eq(events, [
    @moonui.Click(btn.target(), @moonui.Left),
    @moonui.Click(btn.target(), @moonui.Left),
  ])
  // ⑥ 负控制：越界编码 -5（kind 5 不在这套编码里、button 5 越界、滚轮两轴
  //    同时非零），客户区外 -3，窗口空白处 -4，没有这只窗 -2，一条事件都不多
  events.clear()
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(5, 0), lx, ly, 0, 0),
    -5,
  )
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(0, 5), lx, ly, 0, 0),
    -5,
  )
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(4, 0), lx, ly, 1, 1),
    -5,
  )
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(0, 0), -50, -50, 0, 0),
    -3,
  )
  assert_eq(
    @native-macos.send_mouse_in_window(
      title,
      kb(0, 0),
      scaffold_px(380.0, dpi),
      scaffold_px(290.0, dpi),
      0,
      0,
    ),
    -4,
  )
  assert_eq(
    @native-macos.send_mouse_in_window(
      "MoonUI 原生 没有这只窗",
      kb(4, 0),
      lx,
      ly,
      0,
      40,
    ),
    -2,
  )
  scaffold_drain(app)
  assert_eq(events, [])
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T102` 第十二刀：滚轮改判给**自绘面**，原生控件的滚轮仍归窗口。
///
/// 为什么要有这一刀：mac 半的鼠标监听对滚轮**恒报窗口自己**（2026-10-18 的
/// 决定，理由是滚轮是整窗手势、而 `NSScrollView` 自己把滚动吃掉了）。那条
/// 对原生控件成立，对自绘面不成立——自绘面就是一块裸 `NSView`，没有原生滚动
/// 容器，除了这条事件通道没有别的路能收到滚轮，于是"滚轮滚表"在真窗上永远
/// 不动（`T102` 第八刀记的缺口）。改判不能改 `mouse_target`：自绘后端要靠窗口
/// 指针认窗，报控件会让它整条丢。所以 C 侧另记一本 `mouse_owner`，MoonBit 只在
/// 它**是自绘面**时才改判。
///
/// 判据钉三件事，且都是真事件：①滚轮落在自绘面上 → 那条面收到 `Scroll`，窗口
/// **一条都没有**（改判是"换收件人"，不是"多派一份"）；②同一个窗口里滚过
/// 按钮 → 仍归窗口（原生控件的既有行为一个字节没变，"滚轮调音量"那类整窗手势
/// 依赖它）；③横向滚在自绘面上同样改判、增量原样透传（改判看的是位置，不是轴）。
///
/// 诚实边界：投送侧要求真命中控件（空白返回 -4），所以"滚轮落在窗口空白处仍
/// 归窗口"这一半只能由既有判据（`T108` 第一条）间接守着，这里不重复。
test "原生后端：滚轮改判给自绘面，原生控件仍归窗口（T102）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let title = "MoonUI 原生 滚轮改判"
  let win = app.create_window(title, @moonui.LogicalSize(360.0, 260.0))
  let face = @moonui.Widget::custom(b, @moonui.LogicalSize(200.0, 100.0), fn(
    _dl,
    _env,
  ) {

  })
  let btn = @moonui.Widget::button(b, "按钮")
  win.set_content(@moonui.Widget::column(b, 8.0, [face, btn]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let events : Array[@moonui.Event] = []
  let _ = app.on_event(win.target(), fn(ev) { events.push(ev) })
  let _ = app.on_event(face.target(), fn(ev) { events.push(ev) })
  let _ = app.on_event(btn.target(), fn(ev) { events.push(ev) })
  let (fx, fy) = scaffold_center(face.frame(), dpi)
  let (bx, by) = scaffold_center(btn.frame(), dpi)
  let kb = @native-macos.mouse_kind_button
  // ① 滚在自绘面上：面收到，窗口没有
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(4, 0), fx, fy, 0, 64),
    0,
  )
  scaffold_drain(app)
  assert_eq(events, [
    @moonui.Scroll(face.target(), @moonui.LogicalPoint(0.0, 64.0)),
  ])
  // ② 负控制：滚在按钮上仍归窗口（改判只对自绘面开）
  events.clear()
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(4, 0), bx, by, 0, 24),
    0,
  )
  scaffold_drain(app)
  assert_eq(events, [
    @moonui.Scroll(win.target(), @moonui.LogicalPoint(0.0, 24.0)),
  ])
  // ③ 回自绘面：横向也一样改判，量原样
  events.clear()
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(4, 0), fx, fy, -16, 0),
    0,
  )
  scaffold_drain(app)
  assert_eq(events, [
    @moonui.Scroll(face.target(), @moonui.LogicalPoint(-16.0, 0.0)),
  ])
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T110`：自定义绘制面能收到**带坐标**的左键 `MouseDown` / `MouseUp`。
///
/// 这条是 `T102` 第五刀记下的那个卡点的解法：第五刀说"表头点击归应用层"，
/// 理由是 `Click(EventTarget, MouseButton)` **不带坐标**，而自绘面此前只经
/// `mouseUp:` 回流一条 `Click`——控件拿不到"点在哪"，"点表头排序"这类接线
/// 做不了。这一刀之后自绘面能收到带坐标的 `MouseDown`。
///
/// 判据钉四件事：
/// ①**坐标是逻辑像素、且落在点上**（窗口/父局部口径，与 `MouseMove` 同源）；
/// ②按下的 `MouseDown` 与抬起的 `MouseUp` 都到；
/// ③**原生控件不受影响**——点按钮仍然只有 `Click`、没有 `MouseDown`
///    （这半条是"只对自绘面翻译"的证据：漏了这条，后端补左键翻译就会悄悄
///    改变所有原生控件的既有行为，长按识别账也会跟着动）；
/// ④自绘面原有的 `Click` 照旧回流（补 `MouseDown` 不是把 `Click` 顶掉）。
///
/// 投送走 `send_mouse_in_window`（`[NSApp sendEvent:]`）——进程级监听挂在
/// NSApp 的派发路径上，绕开它一条都收不到。
test "原生后端：自绘面收到带坐标的左键，原生控件不受影响（T110）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let title = "MoonUI 原生 自绘面左键"
  let win = app.create_window(title, @moonui.LogicalSize(320.0, 240.0))
  let face = @moonui.Widget::custom(b, @moonui.LogicalSize(160.0, 80.0), fn(
    dl,
    env,
  ) {
    dl.fill_rect(0.0, 0.0, env.width(), env.height(), rgb=0x2B6CB0)
  })
  let btn = @moonui.Widget::button(b, "原生钮")
  win.set_content(@moonui.Widget::column(b, 12.0, [face, btn]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  // 两个 target 各收一条流水：自绘面与原生按钮
  let face_events : Array[@moonui.Event] = []
  let _ = app.on_event(face.target(), fn(ev) { face_events.push(ev) })
  let btn_events : Array[@moonui.Event] = []
  let _ = app.on_event(btn.target(), fn(ev) { btn_events.push(ev) })
  let kb = @native-macos.mouse_kind_button
  // ① 点自绘面中心：按下 → MouseDown（带坐标）、抬起 → MouseUp，
  //    面自己的 Click 照旧回流
  let (fx, fy) = scaffold_center(face.frame(), dpi)
  // **先点一次做激活**：测试进程不是前台应用时，AppKit 把左键**首击**当
  // "激活点击"消费掉——那一击走完监听（MouseDown/MouseUp 照旧到）却不进
  // view 的 `mouseUp:`，所以没有 Click（`T101` 记过这个坑，本机实测：
  // 第一击只有 Down+Up，第二击才有 Click）。所以这里先点一次把窗口激活，
  // 断言放在第二击上。
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(0, 0), fx, fy, 0, 0),
    0,
  )
  scaffold_drain(app)
  face_events.clear()
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(0, 0), fx, fy, 0, 0),
    0,
  )
  scaffold_drain(app)
  let f = face.frame()
  let expect = @moonui.LogicalPoint(
    f.origin.x + f.size.width / 2.0,
    f.origin.y + f.size.height / 2.0,
  )
  assert_eq(face_events, [
    @moonui.MouseDown(face.target(), @moonui.Left, expect),
    @moonui.MouseUp(face.target(), @moonui.Left, expect),
    @moonui.Click(face.target(), @moonui.Left),
  ])
  // ② 负控制：点原生按钮——只有 Click，**没有** MouseDown / MouseUp。
  //    这半条钉住"只对自绘面翻译"：后端若把左键无条件翻译，原生按钮就会
  //    多出 MouseDown（长按识别账 `T86⑧` 也吃 MouseDown(Left)，一并会动）。
  btn_events.clear()
  let (bx, by) = scaffold_center(btn.frame(), dpi)
  // 首击仍可能被 AppKit 的激活点击吞掉（那一击不产生 Click），所以先点一次
  // 把激活做完，断言放在后面——不然这条负控制会时红时绿。
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(0, 0), bx, by, 0, 0),
    0,
  )
  scaffold_drain(app)
  btn_events.clear()
  assert_eq(
    @native-macos.send_mouse_in_window(title, kb(0, 0), bx, by, 0, 0),
    0,
  )
  scaffold_drain(app)
  assert_eq(btn_events, [@moonui.Click(btn.target(), @moonui.Left)])
  // ③ 负控制：自绘面之外的空白处报窗口自己，自绘面收不到任何东西
  face_events.clear()
  assert_eq(
    @native-macos.send_mouse_in_window(
      title,
      kb(0, 0),
      scaffold_px(300.0, dpi),
      scaffold_px(200.0, dpi),
      0,
      0,
    ),
    -4,
  )
  scaffold_drain(app)
  assert_eq(face_events, [])
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T109` 弧命令的像素判据：角度方向是这道题唯一能错的地方，而错法在清单
/// 对账里看不出来（命令参数一模一样），只有像素能说话。ABI 的口径是
/// "0° = 三点钟、顺时针为正"（与 y 向下的屏幕坐标一致），所以 -90° 是十二点。
///
/// 这条钉四件事：①从十二点顺时针扫到三点，那半圈上三点红像素到位；
/// ②反方向那半圈一个像素都没有（扫错方向、或负扫角被补成 2π 时这里会亮）；
/// ③圆心空着——描边不是填充；④负扫角（逆时针）真的往回扫，没有被补成一
/// 大圈；外加 0° 扫角是正常状态（进度 0%），什么都不画也不报错。
///
/// 两条 C 侧负控制实测过：点公式的 `sin` 符号取反 → 只有本条红；负扫角取
/// 绝对值 → 只有本条红（见 TODO `T109` 第一刀的记述）。
test "画布：圆弧从十二点顺时针扫到三点，反方向不画（T109）" {
  let c = @native-common.canvas_create()
  @native-common.canvas_begin_frame(c, 100, 100)
  fn pixel(c : @native-common.Canvas, x : Int32, y : Int32) -> Int32? {
    Some(@native-common.canvas_read_pixel(c, x, y)) catch {
      _ => None
    }
  }
  // 圆心 (50, 50)、r = 30、线宽 6：从 -90°（十二点）顺时针扫到 0°（三点）
  @native-common.canvas_stroke_arc(
    c,
    50,
    50,
    30,
    start_deg=-90.0,
    sweep_deg=90.0,
    width=6.0,
    rgb=0xFF0000,
  )
  // 取点要避开两端：方头端点正好切在过圆心的那条切线上（十二点切在 x=50、
  // 三点切在 y=50），压在边界上的那个像素是半覆盖的，读出来是"半个字"，
  // 判据会脆。所以十二点取 (52,20)、三点取 (80,47)——都在弧的带宽里，
  // 45° 处 (71,29) 取中段。
  assert_eq(pixel(c, 52, 20), Some(0xFF0000))
  assert_eq(pixel(c, 80, 47), Some(0xFF0000))
  assert_eq(pixel(c, 71, 29), Some(0xFF0000))
  // 反方向那半圈一个像素都没有——扫错方向、或者负扫角被补成 2π 时这里会亮
  assert_eq(pixel(c, 50, 80), None)
  assert_eq(pixel(c, 20, 50), None)
  // 圆心空着：描边不是填充
  assert_eq(pixel(c, 50, 50), None)
  // 负扫角 = 逆时针：从三点（0°）往回扫到十二点，画在半径 40 那一圈（蓝）
  @native-common.canvas_stroke_arc(
    c,
    50,
    50,
    40,
    start_deg=0.0,
    sweep_deg=-90.0,
    width=6.0,
    rgb=0x0000FF,
  )
  // 45° 处 (78, 22) 在蓝弧上；六点 (50, 90) 不在——负扫角若被 CG 直接收下，
  // 它会补成"剩下的 270°"（3 → 6 → 9 → 12 点），六点就会亮
  assert_eq(pixel(c, 78, 22), Some(0x0000FF))
  assert_eq(pixel(c, 50, 90), None)
  // 0° 扫角（进度 0%）是正常状态：什么都不画，也不报错
  @native-common.canvas_stroke_arc(
    c,
    50,
    50,
    40,
    start_deg=0.0,
    sweep_deg=0.0,
    width=6.0,
    rgb=0x00FF00,
  )
  assert_eq(pixel(c, 90, 50), None)
  @native-common.canvas_end_frame(c)
  @native-common.canvas_destroy(c)
}

///|
/// `T109` 第二刀的像素判据：闭合多边形填充。
///
/// 清单对账看不出**y 方向**与**填充区域**——顶点参数一样，画出来的东西可能
/// 整个上下颠倒。只有像素能说话。这条钉四件事：
///
/// ①三角形 (20,20)-(80,20)-(50,60) 填的是**上半个**画面：里面 (50,30) 是
///   红，底下 (50,80) 什么都没有——顶点 y 若被翻一次，这两处正好对调；
/// ②多边形**闭合**：只给三点，第四点不用重复给，底边照样连上（(50,50) 那
///   一行在三角形内）；
/// ③顶点不足三个 = 画不出面积 → 报错（不是静默画个怪东西）。
test "画布：多边形填在上半区，闭合，顶点不足报错（T109）" {
  let c = @native-common.canvas_create()
  @native-common.canvas_begin_frame(c, 100, 100)
  fn pixel(c : @native-common.Canvas, x : Int32, y : Int32) -> Int32? {
    Some(@native-common.canvas_read_pixel(c, x, y)) catch {
      _ => None
    }
  }
  // 顶点不足三个：画不出面积，报错（不是静默画个怪东西）
  let mut raised = false
  @native-common.canvas_fill_polygon(c, [(10, 10), (20, 20)], rgb=0xFF0000) catch {
    _ => raised = true
  }
  assert_true(raised)
  // 一个朝下的三角形，占上半区
  @native-common.canvas_fill_polygon(
    c,
    [(20, 20), (80, 20), (50, 60)],
    rgb=0xFF0000,
  )
  // 三角形内部
  assert_eq(pixel(c, 50, 30), Some(0xFF0000))
  assert_eq(pixel(c, 50, 50), Some(0xFF0000))
  // 三角形下方什么都没有——y 没被翻
  assert_eq(pixel(c, 50, 80), None)
  assert_eq(pixel(c, 50, 10), None)
  // 三角形左右两侧也没有
  assert_eq(pixel(c, 10, 30), None)
  assert_eq(pixel(c, 90, 30), None)
  @native-common.canvas_end_frame(c)
  @native-common.canvas_destroy(c)
}

///|
/// `T109` 第二刀：轮廓**不必重复首点**——最后一点自动连回第一点。
///
/// 为什么要单独钉：调用方有两种写法（重复首点 / 不重复），如果实现只认其中
/// 一种，另一种就会画出一条"少一条边"的怪形状。两种写法画出来必须**完全
/// 一样**——这才是"首尾相连"这条约定的可验形式。
///
/// 注意：**填充**路径在 CG 里天生是闭合的（`FillPath` 会自动闭合成路径），
/// 所以"闭合"这件事在填充上验不出来；能验的是"调用方给哪种写法都一样"。
test "画布：多边形轮廓不必重复首点，两种写法画出来一样（T109）" {
  let c = @native-common.canvas_create()
  @native-common.canvas_begin_frame(c, 100, 100)
  fn pixel(c : @native-common.Canvas, x : Int32, y : Int32) -> Int32? {
    Some(@native-common.canvas_read_pixel(c, x, y)) catch {
      _ => None
    }
  }
  // 不重复首点：三点
  @native-common.canvas_fill_polygon(
    c,
    [(20, 20), (80, 20), (50, 60)],
    rgb=0xFF0000,
  )
  let a1 = pixel(c, 50, 50)
  let a2 = pixel(c, 50, 30)
  let a3 = pixel(c, 50, 80)
  @native-common.canvas_end_frame(c)
  @native-common.canvas_destroy(c)
  // 重复首点：四点（第一点再来一次）
  let c2 = @native-common.canvas_create()
  @native-common.canvas_begin_frame(c2, 100, 100)
  @native-common.canvas_fill_polygon(
    c2,
    [(20, 20), (80, 20), (50, 60), (20, 20)],
    rgb=0xFF0000,
  )
  let b1 = pixel(c2, 50, 50)
  let b2 = pixel(c2, 50, 30)
  let b3 = pixel(c2, 50, 80)
  @native-common.canvas_end_frame(c2)
  @native-common.canvas_destroy(c2)
  // 三处取样点全都一样
  assert_eq(a1, b1)
  assert_eq(a2, b2)
  assert_eq(a3, b3)
  // 而且填的确实是那块地方（不是两块都不填）
  assert_eq(a1, Some(0xFF0000))
  assert_eq(a3, None)
}

///|
/// `T109` 第二刀的 alpha 判据：半透明的多边形压在实色上，读回来是混合色。
///
/// 为什么要单独一条：`alpha` 若在 C 侧被忽略（填成不透明），画面看着"更浓"
/// 而不是"更淡"——这种错在清单对账里完全看不出来（alpha 只是参数）。
/// 读像素时半透明按 a 归一展开（见 moonui_canvas_read_pixel 段注），所以
/// 蓝半透明压在红实色上，读到的是偏紫的中间色。
test "画布：多边形的 alpha 生效，半透明压在实色上是混合色（T109）" {
  let c = @native-common.canvas_create()
  @native-common.canvas_begin_frame(c, 100, 100)
  fn pixel(c : @native-common.Canvas, x : Int32, y : Int32) -> Int32? {
    Some(@native-common.canvas_read_pixel(c, x, y)) catch {
      _ => None
    }
  }
  // 先铺一层纯红
  @native-common.canvas_fill_rect(c, 0, 0, 100, 100, rgb=0xFF0000)
  assert_eq(pixel(c, 50, 50), Some(0xFF0000))
  // 再压一层半透明蓝（alpha=128，约一半）
  @native-common.canvas_fill_polygon(
    c,
    [(10, 10), (90, 10), (50, 90)],
    rgb=0x0000FF,
    alpha=128,
  )
  let mixed = match pixel(c, 50, 30) {
    Some(v) => v
    None => abort("压上去的半透明层读不到像素")
  }
  // 混合色既不是纯红（蓝没生效）也不是纯蓝（alpha 没生效）
  assert_true(mixed != 0xFF0000)
  assert_true(mixed != 0x0000FF)
  // 蓝分量确实进去了：混合色里蓝 > 0（纯红是 0x00 蓝分量）
  assert_true((mixed & 0xFF) > 0)
  @native-common.canvas_end_frame(c)
  @native-common.canvas_destroy(c)
}
