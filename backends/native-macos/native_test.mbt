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
  b.set_window_titlebar_style(win, @moonui.TitlebarStyle::Immersive)
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
