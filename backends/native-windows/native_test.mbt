///|
/// 原生 Win32 后端的真窗口验证（设计文档 §51 的 Backend #2，Windows 半，T75）。
///
/// 被测的是"共享的 MoonBit 实现 + 直写 Win32 的 C Adapter"这一对：
/// `@native-common.NativeBackend` 底下不经过任何中间 GUI 库，窗口、控件、事件循环
/// 全部直写 Win32（见 ../native-windows/adapter_native.c）。所以这里的每条断言
/// 都在问"不经过中间 GUI 库也能开窗、跑循环、收事件"——和 mac 原生那份
/// （../native-macos/native_test.mbt）同一批 FP1 判据。
///
/// 这份文件只在 Windows 宿主上才真正跑（scripts/test-local.sh 的 Windows
/// 分支）；在 mac 上它只进 `moon check` 的类型闸门，不进真窗口断言。

///|
/// 逻辑尺寸往返的容差：物理取整最多让一个方向差 1 像素；Win32 的 DPI 换算还要
/// 多一道四舍五入，所以窗口级的量允许差到 1 逻辑像素。
fn close_to(a : Double, b : Double) -> Bool {
  let d = a - b
  d < 1.0 && d > -1.0
}

///|
/// 登记在册的后端：每条测试开头先清场（把上一条没收尾的后端 terminate 掉），
/// 再建一个新的。Win32 那侧没有进程级单例（NSApplication 那种），但两只后端
/// 各自的窗口类是全局注册的，重复 init 在 C 侧直接幂等返回，所以这里按登记顺序
/// 遍历收尾，和 mac 那份同一套形状。
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
/// 末尾 init 一次、terminate 两次：确认这一对是幂等的（C 那侧 moonui_native_terminate
/// 对"没 inited"的重复调用就是直接返回）。
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
/// 窗口几何、缩放、屏幕信息。这条顺带钉住"Win32 的 DPI 就是每英寸像素数"：
/// adapter.h 说 C 侧只报 DPI 不做换算，96 这条基线（100% 缩放）读回来就是 96
/// 的整数倍，Scale 拿到的还是同一个数。
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
/// 控件属性与矩形往返（FP2 的基础判据），和 libui-windows 那条同名测试同形
/// （那份已随 `T82` 删）：`create_widget` 建的对象一出生挂在 C 侧的 park 窗口下，
/// 可见性要等 attach + 窗口 show 之后才是 true。
test "原生后端：控件属性、矩形与固有尺寸在真后端上往返" {
  let b = open_backend()
  b.init()
  let win = b.create_window(
    "MoonUI 原生 控件往返",
    @moonui.LogicalSize(320.0, 240.0),
  )
  let btn = b.create_widget(@moonui.Button, "确定")
  let label = b.create_widget(@moonui.Label, "说明")
  let entry = b.create_widget(@moonui.TextInput, "初值")
  let check = b.create_widget(@moonui.Checkbox, "同意")
  b.attach_widget(win, btn)
  b.set_widget_bounds(
    btn,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(6.0, 8.0),
      @moonui.LogicalSize(140.0, 34.0),
    ),
  )
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
  // 固有尺寸来自 Win32 通用控件自己的测量（GetTextExtentPoint32 那一路），
  // 宽度随文案变、且不为零（§18 不让 Core 猜字体）。
  let short = b.widget_intrinsic_size(label)
  b.set_widget_text(label, "说明说明说明说明")
  let long = b.widget_intrinsic_size(label)
  assert_true(short.width > 0.0 && short.height > 0.0)
  assert_true(long.width > short.width)
  // §15/§16 的样式下发在原生控件后端上**有意不生效**（豁免写在
  // ../native-common/backend.mbt，§32 要保住系统原生外观）：可调用、不报错，
  // 推个大字号之后控件报的度量一个像素都不变。这条钉的就是"不生效"那一半。
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
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 九种扩展控件（0.2 那批，T64 的形状）在直写 Win32 的 C 上按 kind 往返：
/// 文本、数值（含越界夹紧与改范围）、条目、日期四条通道全走一遍。Windows 侧的
/// 分派全靠 SetPropW 挂的 kind 记号（spinbox 是 edit + 附着 updown 兄弟、
/// multiline 按 kind 分派多行读写），这一条红在哪个通道，就说明哪个 kind 的
/// 挂记或分派坏了，不用再猜。
test "原生后端：九种扩展控件的属性按 kind 记号分派往返" {
  let b = open_backend()
  b.init()
  let win = b.create_window(
    "MoonUI 原生 扩展控件",
    @moonui.LogicalSize(360.0, 300.0),
  )
  b.show_window(win)
  // 文本通道：PasswordInput 与普通 entry 同一条路；MultilineEntry 在 C 侧
  // 按 kind 分派到多行读写下。
  let pw = b.create_widget(@moonui.PasswordInput, "secret")
  let ml = b.create_widget(@moonui.MultilineEntry, "第一行\n第二行")
  b.attach_widget(win, pw)
  b.attach_widget(win, ml)
  assert_eq(b.widget_text(pw), "secret")
  assert_eq(b.widget_text(ml), "第一行\n第二行")
  b.set_widget_text(ml, "一行\n两行\n三行")
  assert_eq(b.widget_text(ml), "一行\n两行\n三行")
  // 数值通道：值、越界夹紧（trackbar / updown 由原生控件自己夹）、改范围
  let slider = b.create_ranged_widget(@moonui.Slider, 0, 100)
  let spin = b.create_ranged_widget(@moonui.Spinbox, -5, 5)
  let bar = b.create_widget(@moonui.Progress, "")
  b.attach_widget(win, slider)
  b.attach_widget(win, spin)
  b.attach_widget(win, bar)
  assert_eq(b.widget_value(slider), 0)
  b.set_widget_value(slider, 42)
  assert_eq(b.widget_value(slider), 42)
  b.set_widget_value(slider, 500)
  assert_eq(b.widget_value(slider), 100)
  assert_eq(b.widget_value(spin), -5)
  b.set_widget_value(spin, -99)
  assert_eq(b.widget_value(spin), -5)
  b.set_widget_value(bar, 30)
  assert_eq(b.widget_value(bar), 30)
  b.set_widget_range(slider, 10, 40)
  assert_eq(b.widget_value(slider), 40)
  // 条目通道：没选中是 -1（Win32 ComboBox / 单选组的哨兵），下标读写往返
  let combo = b.create_widget(@moonui.ComboBox, "")
  let radio = b.create_widget(@moonui.RadioButtons, "")
  b.attach_widget(win, combo)
  b.attach_widget(win, radio)
  b.append_widget_option(combo, "苹果")
  b.append_widget_option(combo, "香蕉")
  b.append_widget_option(radio, "红")
  b.append_widget_option(radio, "绿")
  assert_eq(b.widget_selected(combo), -1)
  b.set_widget_selected(combo, 1)
  assert_eq(b.widget_selected(combo), 1)
  b.set_widget_selected(radio, 0)
  assert_eq(b.widget_selected(radio), 0)
  // 日期通道：约定格式往返；坏格式必须报错而不是静默
  let dp = b.create_widget(@moonui.DatePicker, "")
  b.attach_widget(win, dp)
  b.set_widget_datetime(dp, "2026-10-12 08:30:00")
  assert_eq(b.widget_datetime(dp), "2026-10-12 08:30:00")
  let msg = try {
    b.set_widget_datetime(dp, "10/12/2026")
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_true(msg is Some(_))
  // Separator：纯装饰，创建可见即可；VSeparator 走同一个通用构造入口
  let line = b.create_widget(@moonui.Separator, "")
  b.attach_widget(win, line)
  assert_true(b.widget_visible(line))
  let vline = b.create_widget(@moonui.VSeparator, "")
  b.attach_widget(win, vline)
  assert_true(b.widget_visible(vline))
  b.destroy_widget(vline)
  b.destroy_widget(line)
  b.destroy_widget(dp)
  b.destroy_widget(radio)
  b.destroy_widget(combo)
  b.destroy_widget(bar)
  b.destroy_widget(spin)
  b.destroy_widget(slider)
  b.destroy_widget(ml)
  b.destroy_widget(pw)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 画册在原生后端上端到端（FP2 的判据，与 ../native-macos/native_test.mbt 那条
/// 同形）：把共享的 `Gallery` 建在 `@native-common.NativeBackend` 上，逐页
/// `select` 一遍——每一页的 `build_demo` 都会真建一批原生控件，所以这条测的是
/// "不经过中间库，画册要的那批控件在直写 Win32 的 C 上都能建出来、摆进窗口、
/// 换页时整棵拆掉不泄漏"。
///
/// 顺带钉住左栏的形状：侧栏第 4 项（children()[3]）是"布局基础"那组的 Column，
/// 它的 9 个子项全是 MenuRow，选中态走 checked 通道（当前页那行 checked 为真）。
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
/// §25 那棵菜单在真窗口测试里的夹具（和 mac 原生那份的 menu_fixture 同一棵树——
/// 这套夹具原是三份共用的，含 libui 那份（`T82` 删）：断言的是同一根 dump 文本，
/// 夹具也必须同一棵，否则"逐字符一致"
/// 就无从谈起）。注释里的数字是 `MenuBar::new` 按整棵树深度优先重排出来的 id，
/// 也就是原生侧看到的那个数（WM_COMMAND 的 wParam）：
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
/// native-macos 那份测试的 `menu_dump_full` 逐字符相同（libui-windows 那份也曾
/// 断言同一根，`T82` 删）——这些后端建出的菜单是同一副面孔，这根文本就是那件事的钉子。
let menu_dump_full : String = "File{#0:n.e:Quit:Mq,#1:c-e:Sidebar:.,-,+Zoom{#2:r-e:Small:.,#3:r-e:Large:.}};Edit{#4:n.e:Copy:Cc,#5:c-d:Sync:.}"

///|
/// 快照里有没有某一项的完整记录。逐项盯时仍然写全
/// `#<id>:<role><check><enabled>:<label>:<sc>` 一整节，不是只查一个 `+`。
fn menu_dump_has(entry : String) -> Bool {
  @native-common.native_menu_dump().contains(entry)
}

///|
/// 「装上去」这一半：Core 那棵树整棵打包给 C，C 建出真的 HMENU 挂进窗口的
/// 菜单位，快照读回来的是 **GetMenu 给回来的那棵**，不是 adapter 自己记的
/// 名单。和 libui-windows 那条同名测试同形（那份已随 `T82` 删；Win32 的菜单位逐窗口，所以要一只
/// 活着的窗口）；布局（MoonBit 的序列化器对 adapter.h）、组合落到项上、拆干净
/// （换树整棵替换、空树就是拆、terminate 之后还是空）三件事一起钉住。
test "原生后端：菜单栏整棵装进活窗口的原生菜单位，快照逐字符对得上" {
  let b = open_backend()
  b.init()
  let win = b.create_window(
    "MoonUI 原生 菜单栏",
    @moonui.LogicalSize(300.0, 200.0),
  )
  b.show_window(win)
  b.set_menu_bar(menu_fixture())
  assert_eq(@native-common.native_menu_dump(), menu_dump_full)
  assert_eq(@native-common.native_live_handles(), 1)
  // 换一棵：旧的整棵摘掉，所以旧树里的 id 在原生侧不再有对应项
  b.set_menu_bar(
    @moonui.MenuBar::new([
      @moonui.Menu::new("Edit", [Item(@moonui.MenuItem::new("Copy"))]),
    ]),
  )
  assert_eq(@native-common.native_menu_dump(), "Edit{#0:n.e:Copy:.}")
  assert_eq(@native-common.native_menu_click_item(1), -1)
  // 空的一棵 = 拆掉，窗口照旧活着
  b.set_menu_bar(@moonui.MenuBar::new([]))
  assert_eq(@native-common.native_menu_dump(), "")
  // 再装一次：拆干净之后重装要还能长成同一根文本——每一棵都是新建的 HMENU，
  // 没有"改旧的"这条路可走（adapter.h：§25 的契约本来就是换一份菜单栏）
  b.set_menu_bar(menu_fixture())
  assert_eq(@native-common.native_menu_dump(), menu_dump_full)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
  // 收尾之后再读还是空。这边钉的是 terminate 里 moonui_native_menu_clear_all 那次
  // 拆干净：漏拆的话，下一只建出来的窗口会被 moonui_native_menu_register 照着残留的
  // 树挂上菜单位——那件事由下面"菜单位行高"那条测试开头的"装之前快照是空的"
  // 钉住。
  assert_eq(@native-common.native_menu_dump(), "")
}

///|
/// 「点下去」这一半：脚手架对真 HMENU 里的真条目发一条 WM_COMMAND
/// （lParam=0 + HIWORD(wParam)=0，也就是菜单自己发上来的那个形状，不是把
/// MoonBit 的回调直接调一遍）→ 我们自己的顶层窗口过程按 lParam 把它认成菜单
/// 命令 → 回调只报 id → 后端入队 MenuSelect → App 派发给订阅者。T75 分叉
/// 清单里"菜单不走子类化"的正半面就在这条：命令截在 moonui_native_wndproc 里就地完成。
///
/// 后半截是反方向：§25 的勾选态只存在 Core，原生条目只有写入口，所以每次点击
/// 之后由 `App::click_menu_item` 逐项推给后端。快照里 `c-` 变 `c+` 看得见这次
/// 推送，再点一次变回 `c-`（写死成 `true` 的实现在第二发上就红）。Radio 那
/// 一对比的是"同组一起推"：互斥是 Core 算的，原生层不会自己取消兄弟项，漏推
/// 一个就留下两个选中点。
///
/// 禁用那一项（5 号）报 -2 且队列里什么都不冒：SendMessage 会绕过置灰直接进
/// 窗口过程，所以脚手架在发之前先查灰位、查到置灰就原样退回（adapter.h 要求
/// 各后端报同一套码）。
test "原生后端：真点击菜单项回流成 MenuSelect，勾选态推回原生菜单位" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  let win = app.create_window(
    "MoonUI 原生 菜单点击",
    @moonui.LogicalSize(260.0, 180.0),
  )
  win.show()
  app.set_menubar(menu_fixture())
  assert_eq(@native-common.native_menu_dump(), menu_dump_full)
  // 装菜单的补偿（set_client_size）和窗口 show 都会发 WM_SIZE → 队列里躺着
  // Resize 存量；先把它们排空，别让第一次 step 被它吃掉。
  while app.step() {

  }
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
  // 禁用项：-2，且没有事件冒出来（预算之内空转，红在 app.step() 上就是多冒了一条）
  assert_eq(@native-common.native_menu_click_item(5), -2)
  assert_false(app.step())
  win.close()
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 菜单失败的那几条形态。和 mac 那份逐字相同的一处是报错文案（libui 那份也是这一句，`T82` 删）：
/// `set_menu_item_checked` 抛的是共享 backend.mbt 里的 `OperationFailed`，
/// `MockBackend` 那份断言同一句话（§33 的"同一个失败在所有后端上长成同一个
/// 样子"），文案里不许带平台名字。
///
/// 这一边多一处 mac 没有的规矩：那两条 -1 要**在有活窗口、树也装着**的时候问，
/// 否则"这个 id 不在当前那棵菜单里"和"没地方可问"是同一条返回值，测了等于没测
/// （mac 那边菜单是进程全局的，没有这一层）。6 号"上一个 id 都不存在"和 99 号
/// "从没出现过"必须同为 -1——夹具的编号到 5 为止，写成别的数字就是抄了一份实现。
///
/// 最后一条是"能改"而不是"改得对"：禁用项允许推勾选态，快照里 `#5:c-d` 变
/// `c+d`。
test "原生后端：菜单的失败形态和 MockBackend 逐字相同" {
  let b = open_backend()
  b.init()
  let win = b.create_window(
    "MoonUI 原生 菜单失败形态",
    @moonui.LogicalSize(260.0, 180.0),
  )
  b.show_window(win)
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
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 菜单位挤掉的那一行高，两种装序都要还给 Core（与 libui-windows 那条同形，
/// 那份已随 `T82` 删；补偿机制不同：libui 那侧靠 adapter.c 的 menu_pad 手工账，本后端的
/// `moonui_native_set_client_size` 用 AdjustWindowRectEx 现量"当下挂着的菜单"自己
/// 把这一行算进去，所以这里验的是"两种装序下那条现量都对"）。
///
/// - 事后才装（产品路径）：`moonui_native_menu_apply` 挂上之后发现客户区矮了一行，
///   现场补一次 set_client_size；随后每次 set_window_size 也现量当下挂着的那
///   棵。没补的话读回来的高度少一行（远超 close_to 的 1 像素容差）。
/// - 建窗口时就有一棵：外框在 `moonui_native_window_new` 里就把菜单位算进去了，
///   apply 量不出差、不补偿——再补一遍就多了两行，同样红。
///
/// 开头的"装之前快照是空的"量的是上一条测试收尾时 terminate 里那次
/// `moonui_native_menu_clear_all()`：这边没有活窗口就读不出东西，只有走到这里新建
/// 了窗口才量得到有没有留货。
test "原生后端：菜单位挤掉的那一行高，两种装序都还给 Core" {
  let b = open_backend()
  b.init()
  assert_eq(@native-common.native_menu_dump(), "")
  let late = b.create_window(
    "MoonUI 原生 菜单位高度-事后装",
    @moonui.LogicalSize(300.0, 200.0),
  )
  b.show_window(late)
  assert_true(close_to(b.window_size(late).height, 200.0))
  b.set_menu_bar(menu_fixture())
  let kept = b.window_size(late)
  assert_true(close_to(kept.width, 300.0))
  assert_true(close_to(kept.height, 200.0))
  b.set_window_size(late, @moonui.LogicalSize(420.0, 260.0))
  let grown = b.window_size(late)
  assert_true(close_to(grown.width, 420.0))
  assert_true(close_to(grown.height, 260.0))
  // 拆掉：那一行还给客户区，换算里不能再算它
  b.set_menu_bar(@moonui.MenuBar::new([]))
  assert_true(close_to(b.window_size(late).height, 260.0))
  b.set_window_size(late, @moonui.LogicalSize(300.0, 200.0))
  assert_true(close_to(b.window_size(late).height, 200.0))
  b.destroy_window(late)
  // 建窗口时就已经有一棵：外框自己算过那一行，事后不许再补
  b.set_menu_bar(menu_fixture())
  let early = b.create_window(
    "MoonUI 原生 菜单位高度-建时装",
    @moonui.LogicalSize(300.0, 200.0),
  )
  b.show_window(early)
  assert_eq(@native-common.native_menu_dump(), menu_dump_full)
  assert_true(close_to(b.window_size(early).height, 200.0))
  b.set_window_size(early, @moonui.LogicalSize(380.0, 240.0))
  assert_true(close_to(b.window_size(early).height, 240.0))
  b.destroy_window(early)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 真剪贴板往返（§23 / §48-19），与 mac 那份同形（libui 那份亦然，`T82` 删）。**这条测试动的是
/// 用户机器上的真剪贴板**，复原只覆盖文本形态。三个断言各钉一件事：写空串再读
/// → `None`（不是 `Some("")`）；非空往返 → `Some(原文)`（文案带中文，UTF-8 →
/// UTF-16 那条路过一次）；覆盖一次 → 只剩最后一份。失败时复原跑不到、测试文案
/// 会留在剪贴板里，所以开头把"正是本条测试自己写过的那两句"当空的看。
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
/// 消息框与确认框（§24 / §48-18）的 Win32 版，与 libui-windows 那条（`T82` 删）同形：
/// 对话框是同步阻塞的（`Backend::confirm` 要当场给答案），所以测试必须先安排好
/// "用户会按哪只按钮"——脚手架那发 `native_auto_dismiss_dialog` 起一条 helper
/// 线程，到点找到 `#32770` 那只对话框并按控件 ID 发 `BM_CLICK`，于是
/// MessageBoxW 的返回值是它自己的按钮给的，不是脚手架编的。
///
/// 三个断言：消息框那段阻塞真发生过（空转的实现量不到那 300 毫秒）；确认框按
/// IDYES → `true`、按 IDNO → `false`；越界的 index 在"装"的那一步就报回来。
test "原生后端：消息框与确认框真弹原生面板，答案是按钮给的" {
  let b = open_backend()
  b.init()
  // 消息框：300 毫秒之后替用户按下那唯一一只"确定"
  let t0 = @native-common.native_time_ms()
  assert_eq(@native-common.native_auto_dismiss_dialog(300, 0), 0)
  b.show_message("MoonUI 的消息框", "正文")
  let blocked = @native-common.native_time_ms() - t0
  assert_true(blocked >= 250)
  // 确认框：先按"是"（IDYES），再按"否"（IDNO）
  assert_eq(@native-common.native_auto_dismiss_dialog(300, 0), 0)
  assert_true(b.confirm("MoonUI 的确认框", "要继续吗？"))
  assert_eq(@native-common.native_auto_dismiss_dialog(300, 1), 0)
  assert_false(b.confirm("MoonUI 的确认框", "要继续吗？"))
  // 越界的 index 在"装"的那一步就报回来，不许留到运行时什么也按不下
  assert_eq(@native-common.native_auto_dismiss_dialog(10, 2), -1)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 文件面板（§24 / §48-18）的 Win32 版，与 libui-windows 那条（`T82` 删）同形，钉的是
/// mac 上钉不了的"接受"（`Some(路径)`）：IFileDialog 在**本进程**的模态循环里
/// 跑，替用户按下"接受"是普通窗口消息（先投回车、再退到 IDOK 的 `BM_CLICK`，
/// 见 adapter_native.c 的 moonui_native_file_answer_worker）；macOS 15.6 的面板在
/// XPC 服务进程里，accept 在那边直接报 -2。
///
/// 各断言：打开 / 保存 / 文件夹三只面板都真弹、真阻塞、返回的就是装的那条路径
/// （取消之后返回 `None` 而不是上一场的路径——结果每次打开先清掉）；装"接受"
/// 却不给 path 在装的那一步就报 -1；句柄表归零（面板不属于任何窗口）。
test "原生后端：文件 / 保存 / 文件夹面板真弹出来，路径是面板给的" {
  let b = open_backend()
  b.init()
  // 打开文件
  let t0 = @native-common.native_time_ms()
  assert_eq(
    @native-common.native_auto_answer_file_dialog(
      2000, "C:\\Windows\\win.ini", true,
    ),
    0,
  )
  assert_eq(b.open_file("MoonUI 的打开"), Some("C:\\Windows\\win.ini"))
  assert_true(@native-common.native_time_ms() - t0 >= 250)
  // 保存文件：目标文件不必存在——保存面板给的是"打算写到哪"
  let t1 = @native-common.native_time_ms()
  assert_eq(
    @native-common.native_auto_answer_file_dialog(
      2000, "C:\\Windows\\Temp\\moonui-t77-save-probe.txt", true,
    ),
    0,
  )
  assert_eq(
    b.save_file("MoonUI 的保存", "moonui-t77-save-probe.txt"),
    Some("C:\\Windows\\Temp\\moonui-t77-save-probe.txt"),
  )
  assert_true(@native-common.native_time_ms() - t1 >= 250)
  // 选文件夹
  let t2 = @native-common.native_time_ms()
  assert_eq(
    @native-common.native_auto_answer_file_dialog(2000, "C:\\Windows", true),
    0,
  )
  assert_eq(b.select_folder("MoonUI 的文件夹"), Some("C:\\Windows"))
  assert_true(@native-common.native_time_ms() - t2 >= 250)
  // 取消
  assert_eq(@native-common.native_auto_answer_file_dialog(2000, "", false), 0)
  assert_eq(b.open_file("MoonUI 的打开"), None)
  // 写错的脚手架当场红
  assert_eq(@native-common.native_auto_answer_file_dialog(2000, "", true), -1)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 测试探针：C 那一份 `moonui_native_app_icon_present` / `moonui_native_window_icon_installed`
/// （见 adapter.h / adapter_native.c）。后者只在本后端的 Windows C 里实现，所以
/// 走测试文件里的本地 extern，不进 ../native-common/ffi.mbt 的公共面。
extern "c" fn c_app_icon_present() -> Int32 = "moonui_native_app_icon_present"

///|
#borrow(title)
extern "c" fn c_window_icon_installed(
  title : Bytes,
  title_len : Int32,
) -> Int32 = "moonui_native_window_icon_installed"

///|
/// 按标题问一只窗口的 WM_SETICON 图标是不是我们装的那只（探针在 C 侧比对
/// HICON 原值，类图标兜底不会误报）。
fn window_icon_installed(title : String) -> Int32 {
  let t = @utf8.encode(title)
  c_window_icon_installed(t, t.length())
}

///|
/// set_app_icon（§26，T76 的 mac 版同形 + libui-windows 那条（`T82` 删）的 WM_SETICON 两条
/// 路）：ICO 真装上了（探针读 C 侧的记号），且活着的窗口 / 新建的窗口都吃到
/// WM_SETICON（登记表推路 / 建窗补挂路）。坏路径按 §33 报错，文案和
/// MockBackend 逐字相同（libui 那份也是这一句，`T82` 删）。终止之后再设：共享 backend.mbt 的
/// check_initialized 先拦，报"还没初始化"。
///
/// 两条路必须钉在这条里、在第一次 `set_app_icon` 之前量"没推到"：C 那两只全局
/// HICON 装上后不随 terminate 清（进程内跨测试常驻），一旦装过，后建的窗口一律
/// 走补挂——单独一条测试拿不到"装之前"的窗口。
test "原生后端：set_app_icon 把 ICO 装上，坏路径按 §33 报错" {
  let b = open_backend()
  b.init()
  assert_eq(c_app_icon_present(), 0)
  // 登记表推路：窗口先在，此刻还没装过图标，探针必须是 0
  let win1 = b.create_window(
    "MoonUI 原生 图标推路",
    @moonui.LogicalSize(200.0, 120.0),
  )
  b.show_window(win1)
  assert_eq(window_icon_installed("MoonUI 原生 图标推路"), 0)
  b.set_app_icon("assets/logo/moonui")
  assert_eq(c_app_icon_present(), 1)
  // 推路收口：活着的窗口收到 WM_SETICON
  assert_eq(window_icon_installed("MoonUI 原生 图标推路"), 1)
  // 建窗补挂路：图标已装，新建的窗口自己挂上
  let win2 = b.create_window(
    "MoonUI 原生 图标补挂",
    @moonui.LogicalSize(200.0, 120.0),
  )
  b.show_window(win2)
  assert_eq(window_icon_installed("MoonUI 原生 图标补挂"), 1)
  b.destroy_window(win2)
  b.destroy_window(win1)
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
  // 终止之后按 §33 报"还没初始化"——共享 backend.mbt 的 check_initialized 先拦
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
/// 画布（`T98`④ 的 Windows 半）：GDI+ 光栅化进预乘 BGRA 位图，read_pixel
/// 逐位对账。与 mac 那份（native-macos/native_test.mbt 同名测试）同一套
/// 判据——两边各自钉"像素真落在了该在的地方"，坐标口径（左上原点、y 向下）
/// 由这套采样点共同钉住（镜像翻转这类错在 (11,11) 空与 (30,30) 红这对
/// 采样上当场红）。
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
  // 文本：画得出来（覆盖处不再是空像素），度量随字号长高。字族取微软雅黑
  //（见 adapter 的字族段注：GDI+ 不做字体回退，选两种文字都有的字族），
  // 所以这里与 mac 半一样可以用汉字采样。
  @native-common.canvas_draw_text(c, "云", 60, 50, 16.0, rgb=0x000000)
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
  // 状态栈：save → 投影 → restore 之后不带影（与 mac 半同一笔账）
  @native-common.canvas_save(c)
  @native-common.canvas_shadow(c, 0, 0, blur=6.0, rgb=0x00FF00)
  @native-common.canvas_fill_rect(c, 10, 10, 10, 10, radius=0.0, rgb=0x000000)
  @native-common.canvas_restore(c)
  @native-common.canvas_fill_rect(c, 70, 10, 10, 10, radius=0.0, rgb=0xFF0000)
  // GDI+ 对整列矩形边缘也做抗锯齿（CG 是像素对齐直落）——角上那一格
  // 是红叠白布的混合色，采样挪到块中心
  assert_eq(@native-common.canvas_read_pixel(c, 75, 15), 0xFF0000)
  // 收尾幂等
  @native-common.canvas_end_frame(c)
  @native-common.canvas_destroy(c)
}

///|
/// 画布坏参数走 §33 的拦截面（raise 不跨 C 帧）——与 mac 半同形。
test "画布：坏参数 raise，不崩" {
  let c = @native-common.canvas_create()
  let raised = try {
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
/// 画布上屏那两个入口的状态机（`T98`④：attach 记宿主、present 把帧记到
/// 窗口属性表上并 InvalidateRect）。断的是状态机，"屏幕上看得见"归真窗
/// 判据（kind 18 自绘面那批，T111）。
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
test "画布：attach/present 上屏状态机" {
  // 窗口类要在 init 里注册（probe_window_new 直写 CreateWindowExW，
  // 上一条测试 terminate 时已把类注销）——先起一个后端把类钉住。
  let b = open_backend()
  b.init()
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
  b.terminate()
}

///|
/// 画布的弧/多边形/区域模糊（`T109` 的形状 + `T98`② 的模糊）在 Windows 半
/// 的无头像素判据：不进真窗口，直接对着帧缓冲读——把"角度方向、顶点顺序、
/// 预乘混合、模糊渗色"这四样各自钉一个像素。镜像的那几条真窗判据（贴在
/// kind 18 面上之后探针读回）归 T111 那批。
test "画布：弧的方向、多边形、半透明混合与模糊渗色都对着像素" {
  let c = @native-common.canvas_create()
  @native-common.canvas_begin_frame(c, 100, 100)
  // 弧：从十二点顺时针扫 90° 到三点。采样两端 + 中段都该是红；对面的
  // 四分之一（六点、九点方向）必须空——方向要是翻了，红的是这一侧。
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
  assert_eq(@native-common.canvas_read_pixel(c, 50, 20), 0xFF0000)
  assert_eq(@native-common.canvas_read_pixel(c, 80, 50), 0xFF0000)
  assert_eq(@native-common.canvas_read_pixel(c, 71, 29), 0xFF0000)
  let dark = Some(@native-common.canvas_read_pixel(c, 50, 80)) catch {
    _ => None
  }
  assert_true(dark is None)
  let dark2 = Some(@native-common.canvas_read_pixel(c, 20, 50)) catch {
    _ => None
  }
  assert_true(dark2 is None)
  // 多边形：上半区三角实填，越界与圆心侧都空
  @native-common.canvas_fill_rect(c, 0, 0, 100, 100, radius=0.0, rgb=0xFFFFFF)
  @native-common.canvas_fill_polygon(
    c,
    [(10, 10), (50, 10), (30, 40)],
    rgb=0x2B6CB0,
  )
  assert_eq(@native-common.canvas_read_pixel(c, 30, 15), 0x2B6CB0)
  assert_eq(@native-common.canvas_read_pixel(c, 30, 45), 0xFFFFFF)
  assert_eq(@native-common.canvas_read_pixel(c, 5, 5), 0xFFFFFF)
  // 半透明多边形压在实色上：预乘混合——蓝掉进来的同时白布的红绿也
  // 掉一半（b≈254，r=g≈127），两半各自钉一格
  @native-common.canvas_fill_polygon(
    c,
    [(60, 10), (90, 10), (75, 40)],
    rgb=0x0000FF,
    alpha=128,
  )
  let blend = @native-common.canvas_read_pixel(c, 75, 15)
  // 红绿都掉半（≈127），蓝几乎满（254）：alpha 128 的预乘混合逐位可算
  assert_true(blend >> 16 > 120 && blend >> 16 < 135)
  assert_true(((blend >> 8) & 0xFF) > 120 && ((blend >> 8) & 0xFF) < 135)
  assert_true((blend & 0xFF) > blend >> 16)
  // 区域模糊：先铺白底、左半幅压红，再把边界那段糊 4px。read_pixel 是
  // 预乘展开的——半透明红会被归一化回全红，"渗出来的红淡一些"在红通道上
  // 验不出来，要靠被冲淡的绿/蓝通道说话。
  @native-common.canvas_begin_frame(c, 64, 32)
  @native-common.canvas_fill_rect(c, 0, 0, 64, 32, radius=0.0, rgb=0xFFFFFF)
  @native-common.canvas_fill_rect(c, 0, 0, 32, 32, radius=0.0, rgb=0xFF0000)
  @native-common.canvas_blur_region(c, 16, 0, 32, 32, radius=4.0)
  // 边界右外侧（红原来越不过 31）：糊完渗进红，绿/蓝被冲淡但没清零
  let seep = @native-common.canvas_read_pixel(c, 34, 16)
  assert_eq(seep >> 16, 0xFF)
  let seep_gb = (seep >> 8) & 0xFF
  assert_true(seep_gb > 60 && seep_gb < 240)
  // 区域内（糊之前是纯红，绿蓝为零）：糊完绿蓝被白渗进来抬高——不糊这格
  // 就是 0，这是"模糊真跑了"的负控制
  let inner = @native-common.canvas_read_pixel(c, 30, 16)
  assert_eq(inner >> 16, 0xFF)
  assert_true(((inner >> 8) & 0xFF) > 0)
  // 区域外（x=60）：模糊不越界，还是纯白
  let outside = @native-common.canvas_read_pixel(c, 60, 16)
  assert_eq(outside, 0xFFFFFF)
  @native-common.canvas_destroy(c)
}

///|
/// T103 断言的公共换算（与 mac 侧同形）：逻辑坐标 → MoonUI 物理像素
/// （96 = 100%，窗口 DPI 现读，不猜缩放档）。坐标口径是脚手架收的那套
/// （客户区左上原点、y 向下）。
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
/// 把积压的事件排空（一圈一条，最多 8 圈兜底）——mac 侧 `T103` 真跑咬出的
/// 同一笔账：不排干净时 `App::step` 一圈一条的配额被旧事件吃掉，断言看到
/// 的是空数组。Windows 的投递是 PostMessage（异步），排空更是必经一步。
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
/// 鼠标动作投送（adapter.h「测试脚手架」段：kind/button 编码、坐标、滚轮
/// 增量）。Windows 侧 PostMessage——回调在下一次 step 才跑，断言前要排空。
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
fn send_mouse_in_window(
  title : String,
  kb : Int32,
  x : Int32,
  y : Int32,
  dx : Int32,
  dy : Int32,
) -> Int32 {
  let t = @utf8.encode(title)
  c_send_mouse_in_window(t, t.length(), kb, x, y, dx, dy)
}

///|
/// 键盘投送：焦点在谁身上这颗键就算给谁（先把焦点放好再投）。
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
fn send_key_in_window(
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
#borrow(title)
extern "c" fn c_focus_widget_in_window(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int32 = "moonui_native_focus_widget_in_window"

///|
fn focus_widget_in_window(title : String, x : Int32, y : Int32) -> Int32 {
  let t = @utf8.encode(title)
  c_focus_widget_in_window(t, t.length(), x, y)
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
fn click_custom_in_window(title : String, x : Int32, y : Int32) -> Int32 {
  let t = @utf8.encode(title)
  c_click_custom_in_window(t, t.length(), x, y)
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
fn custom_probe(title : String, x : Int32, y : Int32) -> Int64 {
  let t = @utf8.encode(title)
  c_custom_probe(t, t.length(), x, y)
}

///|
/// 按住自绘面不抬（`T111`：Windows 专属脚手架，见 adapter.h 那条声明）——
/// SendMessage 同步跑，SetCapture 在返回时已经生效。
#borrow(title)
extern "c" fn c_press_custom_in_window(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int32 = "moonui_native_press_custom_in_window"

///|
fn press_custom_in_window(title : String, x : Int32, y : Int32) -> Int32 {
  let t = @utf8.encode(title)
  c_press_custom_in_window(t, t.length(), x, y)
}

///|
/// `T111`：自定义绘制面（`WidgetKind::Custom`，kind 18）在 Windows 原生后端
/// 是"一只宿主子窗口 + 画布帧"。这条钉的是那两层之间的账——与 mac 半的
/// T101 判据同形：布局把面摆到该在的地方、清单重放后像素真贴在**这块面
/// 自己的**缓冲里（探针读画布帧，不是屏幕）、repaint 换色整份覆盖、点击按
/// "按下并原地抬起"回流成 Click。
test "原生后端：自定义绘制面真画进自己那块，像素可寻址（T111）" {
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
    custom_probe(title, scaffold_px(x, dpi), scaffold_px(y, dpi))
  }
  // ② 三个点：左上角那块、正中、左下角那块。后两个一起钉住 y 没翻错——
  //    只测一个点的话"上下镜像"这种错照样能过。先排空：draw_custom 在
  //    首次布局后跑，present 已把画布记到面的属性表上。
  scaffold_drain(app)
  assert_eq(at(4.0, 4.0), 0xFF0000FF)
  assert_eq(at(80.0, 40.0), 0x2B6CB0FF)
  assert_eq(at(4.0, 76.0), 0x00FF00FF)
  // ③ repaint：同一张位图上重画整份清单，旧颜色不残留
  accent = 0xFF00FF
  face.repaint()
  scaffold_drain(app)
  assert_eq(at(4.0, 4.0), 0xFF00FFFF)
  assert_eq(at(80.0, 40.0), 0x2B6CB0FF)
  // ④ 点击：SendMessage 按下/抬起，"按下并原地抬起"成一条 Click
  let (cx, cy) = scaffold_center(face.frame(), dpi)
  assert_eq(click_custom_in_window(title, cx, cy), 0)
  scaffold_drain(app)
  assert_eq(clicks, ["Click"])
  // ⑤ 负控制：面之外的空白处不是自绘面（probe -2 / 点击 -4），不多出声
  assert_eq(at(300.0, 200.0), -2L)
  assert_eq(
    click_custom_in_window(
      title,
      scaffold_px(300.0, dpi),
      scaffold_px(200.0, dpi),
    ),
    -4,
  )
  scaffold_drain(app)
  assert_eq(clicks, ["Click"])
  // ⑥ 负控制：没有这只窗时 probe -1、点击 -2
  assert_eq(custom_probe("MoonUI 原生 没有这只窗", 4, 4), -1L)
  assert_eq(click_custom_in_window("MoonUI 原生 没有这只窗", cx, cy), -2)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T102` 第十一刀（Windows 半）：自绘面的键盘焦点 opt-in。默认不收键盘
/// （点它也不抢焦点）；声明过 focusable 的面点一下就拿到焦点，键事件
/// 落到它身上（WH_GETMESSAGE 钩子按"谁有焦点"认领）。
test "原生后端：自绘面焦点 opt-in 后真收键盘，默认面不抢焦点（T111）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let title = "MoonUI 原生 自绘面焦点"
  let win = app.create_window(title, @moonui.LogicalSize(320.0, 240.0))
  let keys_log : Array[String] = []
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
  win.show()
  let _ = app.step()
  scaffold_drain(app)
  let dpi = @native-common.native_window_dpi(win.handle())
  let (kx, ky) = scaffold_center(keys.frame(), dpi)
  // ① 没点它之前：焦点在窗口身上，键没人接（-3）
  assert_eq(send_key_in_window(title, "Right", 0, true), -3)
  // ② 点它 → 焦点落到面 → 真键事件派给它
  assert_eq(click_custom_in_window(title, kx, ky), 0)
  scaffold_drain(app)
  assert_eq(send_key_in_window(title, "Right", 0, true), 0)
  assert_eq(send_key_in_window(title, "Right", 0, false), 0)
  scaffold_drain(app)
  assert_eq(keys_log, ["Right"])
  // ③ 回读焦点确实落在它身上（不是"派给了窗口"的假绿）
  assert_eq(focus_widget_in_window(title, kx, ky), 0)
  // ④ 默认面（没声明 focusable）点了也不抢：换树后点邻居，键还归声明过的那块
  let plain_log : Array[String] = []
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
  let _ = app.step()
  scaffold_drain(app)
  let (px, py) = scaffold_center(plain.frame(), dpi)
  assert_eq(click_custom_in_window(title, px, py), 0)
  scaffold_drain(app)
  // 焦点仍在 keys 上（它还在树里被 detach 了……换树后 plain 是唯一叶子），
  // 键无人接：plain 没声明过 focusable，焦点链首空转
  assert_eq(send_key_in_window(title, "Home", 0, true), -3)
  assert_eq(plain_log, [])
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T102` 第十三刀（Windows 半）：自绘面的**指针捕获**。按下那一刻
/// SetCapture 把收件人钉住——拖出面外后 `MouseMove` / `MouseUp` 仍归那块
/// 面（钩子按消息的 hwnd 认领，捕获让系统把消息投给它）；抬起在面外不算
/// Click。放开捕获之后再动，事件归坐标底下那个人。
test "原生后端：按住自绘面拖出面外，移动与抬起仍归它（T111）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let title = "MoonUI 原生 指针捕获"
  let win = app.create_window(title, @moonui.LogicalSize(360.0, 260.0))
  let face = @moonui.Widget::custom(b, @moonui.LogicalSize(200.0, 100.0), fn(
    dl,
    env,
  ) {
    dl.fill_rect(0.0, 0.0, env.width(), env.height(), rgb=0x2B6CB0)
  })
  let btn = @moonui.Widget::button(b, "邻居")
  let clicks : Array[String] = []
  let _ = face.on_any(fn(ev) {
    match ev {
      @moonui.Click(_, _) => clicks.push("Click")
      _ => ()
    }
  })
  win.set_content(@moonui.Widget::column(b, 8.0, [face, btn]))
  win.show()
  let _ = app.step()
  scaffold_drain(app)
  let dpi = @native-common.native_window_dpi(win.handle())
  let (fx, fy) = scaffold_center(face.frame(), dpi)
  let (bx, by) = scaffold_center(btn.frame(), dpi)
  let bf = btn.frame()
  let over_btn = @moonui.LogicalPoint(
    bf.origin.x + bf.size.width / 2.0,
    bf.origin.y + bf.size.height / 2.0,
  )
  let face_events : Array[@moonui.Event] = []
  let _ = app.on_event(face.target(), fn(ev) {
    match ev {
      @moonui.MouseMove(_, _) | @moonui.MouseUp(_, @moonui.Left, _) =>
        face_events.push(ev)
      _ => ()
    }
  })
  let btn_events : Array[@moonui.Event] = []
  let _ = app.on_event(btn.target(), fn(ev) {
    match ev {
      @moonui.MouseMove(_, _) | @moonui.MouseUp(_, @moonui.Left, _) =>
        btn_events.push(ev)
      _ => ()
    }
  })
  // ① 按住不抬（SendMessage 同步：捕获在返回时已生效），拖到邻居上、在
  //    邻居上抬起——send_mouse 按 GetCapture 路由，三颗都归面
  assert_eq(press_custom_in_window(title, fx, fy), 0)
  assert_eq(send_mouse_in_window(title, 16, bx, by, 0, 0), 0)
  assert_eq(send_mouse_in_window(title, 8, bx, by, 0, 0), 0)
  scaffold_drain(app)
  // ② 面收到了"移动到按钮中心"与"在按钮中心抬起"（坐标是窗口局部口径）
  assert_eq(face_events, [
    @moonui.MouseMove(face.target(), over_btn),
    @moonui.MouseUp(face.target(), @moonui.Left, over_btn),
  ])
  // 抬起发生在面外：不算 Click（按下并**原地**抬起才是一条）
  assert_eq(clicks, [])
  // ③ 按钮一条都没有（捕获是"换收件人"，不是"多派一份"）
  assert_eq(btn_events.length(), 0)
  // ④ 抬起后捕获已放开：再在按钮上动，事件归按钮、面一条都不多
  assert_eq(send_mouse_in_window(title, 16, bx, by, 0, 0), 0)
  scaffold_drain(app)
  assert_true(btn_events.length() >= 1)
  assert_eq(face_events.length(), 2)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
#borrow(title)
extern "c" fn c_click_button_in_window(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int32 = "moonui_native_click_button_in_window"

///|
fn click_button_in_window(title : String, x : Int32, y : Int32) -> Int32 {
  let t = @utf8.encode(title)
  c_click_button_in_window(t, t.length(), x, y)
}

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
fn type_text_in_window(
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
/// 键事件流水：只留 KeyDown/KeyUp，压成 "down:s" / "up:s" 形状。
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
/// T103 Windows 半①：坐标点击落到勾选框上，BM_CLICK 走 BN_CLICKED 的真路
/// （不是把回调调一遍），勾选态真翻、程序读回对得上——两次都翻才算闭环。
test "原生后端：坐标点击真落到勾选框上，勾选态两次翻转（T103）" {
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
  assert_eq(click_button_in_window("MoonUI 原生 脚手架勾选", cx, cy), 0)
  assert_true(app.step())
  assert_true(cb.checked())
  // 再点一下：翻回去——两次都是真点击，不是"点一下就勾上"
  assert_eq(click_button_in_window("MoonUI 原生 脚手架勾选", cx, cy), 0)
  assert_true(app.step())
  assert_false(cb.checked())
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// T103 Windows 半②：打字进输入框——type_text_in_window 逐字符 SendMessage
/// WM_CHAR（键盘消息进 EDIT 的正门），一条 EN_CHANGE 配一条 Input（mac 半
/// 是整串一次 insertText: 只来一条——两侧差异留在各自的测试里，T18 的形状）。
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
  // 后挂回去报"已被其他容器持有"（mac 半真跑咬出的同一颗坑）。
  win.set_content(@moonui.Widget::column(b, 12.0, [input, btn]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let (cx, cy) = scaffold_center(input.frame(), dpi)
  assert_eq(
    type_text_in_window("MoonUI 原生 脚手架打字", cx, cy, "世界"),
    0,
  )
  scaffold_drain(app)
  assert_eq(input.text(), "预置世界")
  // Windows 侧一个字符一条 EN_CHANGE：两个字符两条 Input，各自带全文回声
  assert_eq(texts, ["预置世", "预置世界"])
  // 负控制：打字目标不是输入框时 -4，文案一字不动
  let (bx, by) = scaffold_center(btn.frame(), dpi)
  assert_eq(
    type_text_in_window("MoonUI 原生 脚手架打字", bx, by, "x"),
    -4,
  )
  scaffold_drain(app)
  assert_eq(input.text(), "预置世界")
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// T103 Windows 半③：⌃S 组合只成键事件（Windows 没有加速键表把它派生成
/// MenuSelect——T39 钉过的平台差异），down/up 各一条、修饰位 ctrl 真落
/// 在 KeyPress 上，菜单一档一条都不多。
test "原生后端：⌃S 只响键事件，修饰位与菜单账各归各位（T103）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 原生 脚手架键组合",
    @moonui.LogicalSize(300.0, 200.0),
  )
  let input = @moonui.Widget::text_input(b, "")
  win.set_content(@moonui.Widget::column(b, 12.0, [input]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let title = "MoonUI 原生 脚手架键组合"
  let seen : Array[@moonui.Event] = []
  let _ = app.on_event(input.target(), fn(ev) { seen.push(ev) })
  let menus : Array[@moonui.Event] = []
  let _ = app.on_event(win.target(), fn(ev) {
    match ev {
      @moonui.MenuSelect(_) => menus.push(ev)
      _ => ()
    }
  })
  // 焦点先放到输入框上（键的归属靠焦点，adapter.h 键盘段注）
  let (cx, cy) = scaffold_center(input.frame(), dpi)
  assert_eq(focus_widget_in_window(title, cx, cy), 0)
  scaffold_drain(app)
  seen.clear()
  // ⌃S：ctrl 是 mods 的 bit0（moonui_native_mod_vk：ctrl/alt/shift/meta）
  assert_eq(send_key_in_window(title, "s", 1, true), 0)
  assert_eq(send_key_in_window(title, "s", 1, false), 0)
  scaffold_drain(app)
  assert_eq(scaffold_key_log(seen), ["down:s", "up:s"])
  // 修饰位真落在 KeyPress 上：两条的 ctrl 都是 true
  let mut ctrl_count = 0
  for ev in seen {
    match ev {
      @moonui.KeyDown(_, kp) => if kp.ctrl { ctrl_count = ctrl_count + 1 }
      @moonui.KeyUp(_, kp) => if kp.ctrl { ctrl_count = ctrl_count + 1 }
      _ => ()
    }
  }
  assert_eq(ctrl_count, 2)
  // Windows 没有加速键表：组合不产 MenuSelect，一条都没有
  assert_eq(menus.length(), 0)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// T103 Windows 半①的另一半：坐标点击落到**普通按钮**上，BM_CLICK →
/// BN_CLICKED → WM_COMMAND 走我们自己的顶层过程那条真路，Click 事件真回流
/// （与 mac 半的「坐标点击真落到按钮上」同形判据）。
test "原生后端：坐标点击真落到按钮上，Click 回流（T103）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 原生 脚手架点击",
    @moonui.LogicalSize(300.0, 200.0),
  )
  let btn = @moonui.Widget::button(b, "点我")
  let clicks : Array[@moonui.Event] = []
  let _ = btn.on_any(fn(ev) {
    match ev {
      @moonui.Click(_, _) => clicks.push(ev)
      _ => ()
    }
  })
  win.set_content(@moonui.Widget::column(b, 12.0, [btn]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let (bx, by) = scaffold_center(btn.frame(), dpi)
  assert_eq(click_button_in_window("MoonUI 原生 脚手架点击", bx, by), 0)
  assert_true(app.step())
  assert_eq(clicks.length(), 1)
  // 负控制：窗口空白处 -4，一条事件都不多
  assert_eq(
    click_button_in_window("MoonUI 原生 脚手架点击", 10, 180),
    -4,
  )
  scaffold_drain(app)
  assert_eq(clicks.length(), 1)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
extern "c" fn c_win_prefers_reduced_motion() -> Int32 = "moonui_native_prefers_reduced_motion"

///|
extern "c" fn c_win_prefers_high_contrast() -> Int32 = "moonui_native_prefers_high_contrast"

///|
/// T92 的两条系统读数真跑：SPI_GETCLIENTAREAANIMATION / SPI_GETHIGHCONTRAST
/// 这两条 C 路在挂账到本次之前从未被任何测试执行过（后台模式核心测试不碰
/// 系统外观，mac 半另走 NSWorkspace）。真跑只验"执行、落 0/1、两次同账"
/// ——具体值跟系统外观走，断不到固定字面量；"对账系统设置切换"那半仍是
/// 人工步（见 TODO T92 注）。共享 ffi 的 Bool 包装顺带各真跑一次。
test "原生后端：两条系统偏好读数真跑，落 0/1 且两次同账（T92）" {
  let rm1 = c_win_prefers_reduced_motion()
  let rm2 = c_win_prefers_reduced_motion()
  assert_true(rm1 == 0 || rm1 == 1)
  assert_eq(rm1, rm2)
  let hc1 = c_win_prefers_high_contrast()
  let hc2 = c_win_prefers_high_contrast()
  assert_true(hc1 == 0 || hc1 == 1)
  assert_eq(hc1, hc2)
  assert_eq(@native-common.native_prefers_reduced_motion(), rm1 != 0)
  assert_eq(@native-common.native_prefers_high_contrast(), hc1 != 0)
}

///|
#borrow(title)
extern "c" fn c_widget_alpha_probe(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int32 = "moonui_native_widget_alpha_probe"

///|
fn widget_alpha_probe(title : String, x : Int32, y : Int32) -> Int32 {
  let t = @utf8.encode(title)
  c_widget_alpha_probe(t, t.length(), x, y)
}

///|
/// `T89①`：opacity 的 Win 半（WS_EX_LAYERED + LWA_ALPHA）此前只过 mingw
/// 语法闸门，从未真编译真跑。真跑实测（2026-10-22，Win11 22631 RDP 会话）和干净最小
/// 复刻一样：WS_EX_LAYERED 在子窗口上被系统整体拒绝（创建报 87、运行时置位被静默剥掉），
/// 顶层窗口完全正常——owner 裁决“顶层生效 + 控件级记平台限制”（控件级等 §44 自绘用
/// 画布乘 alpha 覆盖）。这条钉顶层路径的四档：半透明置位且 alpha 字节逐位
/// ((0.5*1000)*255)/1000=127；0 仍分层但字节归零；1000 撤位恢复原生绘制；出界值两侧夹紧。
/// 再钉控件级调用“不崩、无效”的平台事实（探针读回 -1，分层位被系统剥掉）。
test "原生后端：不透明度在顶层窗口真落到分层位上（T89①）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 原生 不透明度",
    @moonui.LogicalSize(300.0, 200.0),
  )
  let btn = @moonui.Widget::button(b, "半透明")
  win.set_content(@moonui.Widget::column(b, 12.0, [btn]))
  win.show()
  let _ = app.step()
  let title = "MoonUI 原生 不透明度"
  let dpi = @native-common.native_window_dpi(win.handle())
  let (bx, by) = scaffold_center(btn.frame(), dpi)
  // 顶层：0.5 → 置位 + alpha 字节 127（千分比整数换算在 ffi 那层）
  @native-common.native_widget_set_opacity(win.handle(), 0.5)
  assert_eq(widget_alpha_probe(title, -1, -1), 127)
  // 0 → 仍分层，字节归零
  @native-common.native_widget_set_opacity(win.handle(), 0.0)
  assert_eq(widget_alpha_probe(title, -1, -1), 0)
  // 1.0 → 撤位恢复原生绘制
  @native-common.native_widget_set_opacity(win.handle(), 1.0)
  assert_eq(widget_alpha_probe(title, -1, -1), -1)
  // 出界负值夹到 0：分层、字节 0
  @native-common.native_widget_set_opacity(win.handle(), -0.5)
  assert_eq(widget_alpha_probe(title, -1, -1), 0)
  // 出界大值夹到 1000：撤位
  @native-common.native_widget_set_opacity(win.handle(), 1.5)
  assert_eq(widget_alpha_probe(title, -1, -1), -1)
  // 负控制：找不到窗口 -2
  assert_eq(widget_alpha_probe("不存在的窗口", -1, -1), -2)
  // 控件级：本机（RDP）实测子窗口分层被系统剥掉——只断言
  // “调用不崩、无效”这个平台事实，不断言效果（控件级生效靠 §44 自绘覆盖）
  match btn.handle() {
    Some(h) => {
      @native-common.native_widget_set_opacity(h, 0.5)
      assert_eq(widget_alpha_probe(title, bx, by), -1)
    }
    None => assert_true(false)
  }
  scaffold_drain(app)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
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
fn ime_compose_in_window(
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
fn ime_commit_in_window(
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
/// 真输入法对程序化 SCS_SETSTR 的反应实测是“同一条
/// WM_IME_COMPOSITION 发两遍”（lParam 逐位相同，微软拼音的行为；真人每次敲键只来一条）。
/// 断言序列时把相邻的重复项压回一份——相位的“开始/进行/结束”顺序才是产品
/// 契约，重复计数是环境细节。
fn ime_dedupe(seq : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for entry in seq {
    if out.length() == 0 || out[out.length() - 1] != entry {
      out.push(entry)
    }
  }
  out
}

///|
/// `T90①/③` Windows 半：IME 组合相位整条真跑。脚手架替真输入法投
/// WM_IME_*（组合串经 ImmSetCompositionStringW 写进输入上下文，产品代码
/// 在消息间隙当场读回——ImmGetContext 前提与 GCS_COMPSTR 字节计数在这条
/// 上过秤）。判据：①单行两次组合（串加深）只发一次 start；②多行同一套；
/// ③取消：组合中上屏空串只收 end、文本不留痕；④上屏全文经既有 Input 通道
/// 回 Core；⑤子类链不打架：紧跟着 type_text 的 WM_CHAR 通道照常工作；
/// ⑥负控制：没有这只窗 -2、label 上 -4。
test "原生后端：单行与多行的输入法组合相位都真跑（T90①）" {
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
  scaffold_drain(app)
  // 负控制先走：都不产相位
  assert_eq(
    ime_compose_in_window("MoonUI 原生 没有这只窗", ix, iy, "x"),
    -2,
  )
  assert_eq(ime_compose_in_window(title, lx, ly, "x"), -4)
  assert_eq(ime_dedupe(seq), [])
  assert_eq(ime_dedupe(ml_seq), [])
  // ① 单行：两次组合（串加深）+ 上屏
  assert_eq(ime_compose_in_window(title, ix, iy, "ni"), 0)
  scaffold_drain(app)
  assert_eq(ime_dedupe(seq), ["start", "compose:ni"])
  // Windows 替投定稿的是当前组合串（IMM 没有结果串写口，拼音→汉字是真输入法的事）：
  // 第二次组合直接写“你好”再定稿，上屏文本就是它。
  assert_eq(ime_compose_in_window(title, ix, iy, "你好"), 0)
  scaffold_drain(app)
  assert_eq(ime_dedupe(seq), ["start", "compose:ni", "compose:你好"])
  assert_eq(ime_commit_in_window(title, ix, iy, "你好"), 0)
  scaffold_drain(app)
  assert_eq(ime_dedupe(seq), ["start", "compose:ni", "compose:你好", "end"])
  assert_eq(input.text(), "你好")
  // ② 多行：同一套（相位认的是 ES_MULTILINE 的 EDIT，子类过程同一只）
  assert_eq(ime_compose_in_window(title, mx, my, "中文"), 0)
  scaffold_drain(app)
  assert_eq(ime_dedupe(ml_seq), ["start", "compose:中文"])
  assert_eq(ime_commit_in_window(title, mx, my, "中文"), 0)
  scaffold_drain(app)
  assert_eq(ime_dedupe(ml_seq), ["start", "compose:中文", "end"])
  assert_eq(ml.text(), "中文")
  // ③ 取消：组合中上屏空串 = 撤掉组合，相位只收 end、文本不留痕
  assert_eq(ime_compose_in_window(title, mx, my, "取消"), 0)
  scaffold_drain(app)
  assert_eq(ml.text(), "中文")
  assert_eq(ime_commit_in_window(title, mx, my, ""), 0)
  scaffold_drain(app)
  assert_eq(ime_dedupe(ml_seq), [
    "start", "compose:中文", "end", "start", "compose:取消", "end",
  ])
  assert_eq(ml.text(), "中文")
  // ⑤ 子类链不打架：组合之后 type_text 的 WM_CHAR 通道照常
  assert_eq(type_text_in_window(title, ix, iy, "!"), 0)
  scaffold_drain(app)
  assert_eq(input.text(), "你好!")
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T90⑤` Windows 半：组合中程序化 set_text。mac 那侧 field editor 的标记
/// 区间会被 setString 整段清掉（要"取标记串→写正文→标回去"绕路）；Windows
/// 的组合串住在输入上下文里、不进编辑框正文，SetWindowText 理论上碰不到它
/// ——这条真跑钉实况：①组合中 set_text 不产相位、不打断组合（后续组合
///   只发"进行"）；②上屏收 end、全文经 Input 回声；③多行连改两次同套；
/// ④不在组合中改文本不发任何相位。
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
  // ① 单行：组合中 set_text 不产相位；组合未断（再组合只发"进行"）
  assert_eq(ime_compose_in_window(title, ix, iy, "ni"), 0)
  scaffold_drain(app)
  assert_eq(ime_dedupe(seq), ["start", "compose:ni"])
  input.set_text("预置世")
  scaffold_drain(app)
  assert_eq(ime_dedupe(seq), ["start", "compose:ni"])
  assert_eq(input.text(), "预置世")
  assert_eq(ime_compose_in_window(title, ix, iy, "你好"), 0)
  scaffold_drain(app)
  // set_text 没打断组合：再组合只发“进行”，没有新的 start 边
  assert_eq(ime_dedupe(seq), ["start", "compose:ni", "compose:你好"])
  assert_eq(ime_commit_in_window(title, ix, iy, "你好"), 0)
  scaffold_drain(app)
  assert_eq(ime_dedupe(seq), ["start", "compose:ni", "compose:你好", "end"])
  // ② 上屏落点（平台差异记在案）：SetWindowText 把选中区重置到 0，定稿串
  // 落在正文开头——与 mac（正文 + 组合串）不同；组合未断是共同点。
  assert_eq(input.text(), "你好预置世")
  // ③ 多行：连改两次文本同套
  assert_eq(ime_compose_in_window(title, mx, my, "中"), 0)
  scaffold_drain(app)
  assert_eq(ime_dedupe(ml_seq), ["start", "compose:中"])
  ml.set_text("第一行")
  scaffold_drain(app)
  ml.set_text("改过的")
  scaffold_drain(app)
  assert_eq(ime_dedupe(ml_seq), ["start", "compose:中"])
  assert_eq(ime_commit_in_window(title, mx, my, "中"), 0)
  scaffold_drain(app)
  assert_eq(ime_dedupe(ml_seq), ["start", "compose:中", "end"])
  assert_eq(ml.text(), "中改过的")
  // ④ 负控制：不在组合中改文本，一条相位都不发
  input.set_text("纯净")
  scaffold_drain(app)
  assert_eq(ime_dedupe(seq)[ime_dedupe(seq).length() - 1], "end")
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T91②`：SW_ 系列的真跑——set_minimized/set_maximized 真落到 ShowWindow，
/// window_state 读回 IsIconic/IsZoomed 的实况，重发同一条意图不抖
/// （只在差异上动的那半由 IsIconic/IsZoomed 闸住，这里断言读回值不斜）。
test "原生后端：窗口最小化/最大化真落 SW_ 并读回（T91②）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 原生 窗口态",
    @moonui.LogicalSize(320.0, 200.0),
  )
  win.show()
  let _ = app.step()
  // 初态：两开
  let st0 = win.window_state()
  assert_false(st0.minimized)
  assert_false(st0.maximized)
  // 最小化：真落 SW_MINIMIZE，IsIconic 翻真
  win.set_minimized(true)
  scaffold_drain(app)
  let st1 = win.window_state()
  assert_true(st1.minimized)
  // 重发同一条：读回不抖（开关闸，不重复 ShowWindow）
  win.set_minimized(true)
  assert_true(win.window_state().minimized)
  // 恢复
  win.set_minimized(false)
  scaffold_drain(app)
  assert_false(win.window_state().minimized)
  // 最大化：SW_MAXIMIZE → IsZoomed；再最小化是叠加态（最小化优先显示）
  win.set_maximized(true)
  scaffold_drain(app)
  assert_true(win.window_state().maximized)
  assert_false(win.window_state().minimized)
  // 恢复：SW_RESTORE 回原尺寸
  win.set_maximized(false)
  scaffold_drain(app)
  let st2 = win.window_state()
  assert_false(st2.maximized)
  assert_false(st2.minimized)
  let size = win.size()
  assert_true(size.width > 200.0 && size.width < 400.0)
  assert_true(size.height > 120.0 && size.height < 300.0)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T91⑤` Windows 半：WIC 解码→HBITMAP→STM_SETIMAGE 真跑。探针
/// `image_probe`（本条补的 Windows 半）读 STATIC 自己的 STM_GETIMAGE，
/// 证"解码真出了位图、真装上了"：空控件 has=0；装 1024×1024 的 PNG 后
/// has=1 且像素尺寸逐位对得上（WIC 的像素账，不是 Core 的缓存）；
/// 整源替换后读回仍 1024（STM_SETIMAGE 返回旧图被 Delete，不叠加）；
/// 坏路径按 §33 报调用方错。
test "原生后端：WIC 解码真装进 STATIC，探针读回逐位（T91⑤）" {
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
  // 真装一张图：路径通道（WIC 解码归平台）
  img.set_image_path("assets/logo/moonui.png")
  let (has, px_w, px_h) = @native-common.native_image_probe(h)
  assert_true(has)
  assert_eq(px_w, 1024)
  assert_eq(px_h, 1024)
  // 整源替换：换成另一张同尺寸的图，读回照旧（替换不是叠加）
  img.set_image_path("assets/logo/luna.png")
  let (has2, w2, h2) = @native-common.native_image_probe(h)
  assert_true(has2)
  assert_eq(w2, 1024)
  assert_eq(h2, 1024)
  // 字节通道同一张图走一遍（数据进内存解码，不经文件系统）
  // 字节通道的口粮：88 字节的最小 PNG（3x2 纯红、存储型 deflate）
  let tiny_png : Bytes = Bytes::from_array([
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 3, 0,
    0, 0, 2, 8, 2, 0, 0, 0, 18, 22, 241, 77, 0, 0, 0, 31, 73, 68, 65, 84, 120, 1,
    1, 20, 0, 235, 255, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 0, 255, 0, 0, 255, 0,
    0, 255, 0, 0, 65, 210, 5, 251, 108, 246, 61, 186, 0, 0, 0, 0, 73, 69, 78, 68,
    174, 66, 96, 130,
  ])
  img.set_image_bytes(tiny_png)
  let (has3, w3, h3) = @native-common.native_image_probe(h)
  assert_true(has3)
  assert_eq(w3, 3)
  assert_eq(h3, 2)
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
/// `T91⑥` Windows 半：托盘真显 + 气球真投递。判据读自己的 NOTIFYICONDATAW
/// 副本（Shell_NotifyIcon 没有读回口，NIM_ADD/MODIFY 成功本身已由返回码
/// 0 证明）；探针的 24..39 位复核 NIF_INFO 定宽截断（标题 63 字符、正文
/// 255 字符，比限宽长的部分不假装投出去）。

///|
extern "c" fn c_win_tray_probe() -> Int64 = "moonui_native_tray_probe"

///|
test "原生后端：托盘真装真菜单，气球定宽截断有账（T91⑥）" {
  let b = open_backend_for_testing(200)
  b.init()
  // 初态：三个存在位全零（进程级单例，随上一个后端 terminate 清干净）
  let (item0, icon0, menu0, count0) = @native-common.native_tray_probe()
  assert_false(item0)
  assert_false(icon0)
  assert_false(menu0)
  assert_eq(count0, 0)
  // 图标：沿 app icon 的 stem 约定（C 侧补 .ico）
  b.set_tray_icon("assets/logo/luna")
  let (item1, icon1, menu1, count1) = @native-common.native_tray_probe()
  assert_true(item1)
  assert_true(icon1)
  assert_false(menu1)
  assert_eq(count1, 0)
  // 菜单：三行真挂上
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
  // 气球：正文正常长度整段投递（NIF_INFO 的 NIM_MODIFY 返回 TRUE）
  b.notify("MoonUI 测试", "通知正文")
  // 定宽截断：超限的标题/正文在 NOTIFYICONDATAW 副本上各截到 63/255 字符
  let long_title = "一二三四五六七八九十".repeat(10)
  let long_body = "零一二三四五六七八九".repeat(40)
  b.notify(long_title, long_body)
  let bits = c_win_tray_probe()
  let title_len = ((bits >> 24) % 256L).to_int()
  let body_len = ((bits >> 32) % 256L).to_int()
  assert_eq(title_len, 63)
  assert_eq(body_len, 255)
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
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
#borrow(ms)
extern "c" fn c_auto_pick_context_menu(ms : Int32, index : Int32) -> Int32 = "moonui_native_auto_pick_context_menu"

///|
/// `T91①` Windows 半：右键真窗 + 上下文菜单真弹。
/// ①右键经 send_mouse（钩子只认队列消息，WM_RBUTTONDOWN/UP 真投）回流成
///   MouseDown(Right)，target 与坐标按真命中对账；
/// ②set_context_menu 的订阅真走一遍：右键 → Core 回调 → show_context_menu
///   → TrackPopupMenuEx 模态循环真弹，替按（旁观线程 Post 一对点击）选第
///   2 项，选中按 TPM_RETURNCMD 同步回流；
/// ③回调里能重入后端（读窗口态），模态循环没有把 UI 线程锁死；
/// ④负控制：没有这只窗报 -2、点在客户区外报 -3。
test "原生后端：右键真窗 + 上下文菜单真弹真选（T91①）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let title = "MoonUI 原生 上下文菜单"
  let win = app.create_window(title, @moonui.LogicalSize(340.0, 240.0))
  let label = @moonui.Widget::label(b, "右键这里")
  win.set_content(@moonui.Widget::column(b, 8.0, [label]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let (lx, ly) = scaffold_center(label.frame(), dpi)
  // ① 右键真窗：一对真消息回流成 MouseDown(Right)，target 与坐标对账
  let seen : Array[@moonui.Event] = []
  let _ = label.on_any(fn(ev) { seen.push(ev) })
  assert_eq(send_mouse_in_window(title, 1, lx, ly, 0, 0), 0)
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
      assert_true(close_to(p.x, center.origin.x + center.size.width / 2.0))
      assert_true(close_to(p.y, center.origin.y + center.size.height / 2.0))
    }
    None => abort("右键没有回流成 MouseDown(Right)")
  }
  // 负控制：点在客户区外 -3
  assert_eq(send_mouse_in_window(title, 1, -5, -5, 0, 0), -3)
  // ② 菜单真弹真选：先装 set_context_menu，再武装替按、真右键
  let first = @moonui.MenuItem::new("一")
  let second = @moonui.MenuItem::new("二")
  let clicked : Array[Int32] = []
  let _ = second.on(fn(_) { clicked.push(second.id) })
  label.set_context_menu(@moonui.Menu::new("Menu", [Item(first), Item(second)]))
  // 收集右键事件——回调在 Modal loop 里读窗口态（③ 的重入判据）
  let reenter_ok : Array[Bool] = []
  let _ = label.on(fn(ev) { ev is @moonui.MouseDown(_, @moonui.Right, _) }, fn(
    _,
  ) {
    let st = Some(@moonui.Backend::window_state(b, win.handle())) catch {
      _ => None
    }
    match st {
      Some(s) => reenter_ok.push(!s.minimized && !s.maximized)
      None => reenter_ok.push(false)
    }
  })
  assert_eq(c_auto_pick_context_menu(100, 1), 0)
  assert_eq(send_mouse_in_window(title, 1, lx, ly, 0, 0), 0)
  scaffold_drain(app)
  // 选中走 MenuItem 自己的回调同步解析，不经事件队列
  assert_eq(clicked, [second.id])
  assert_eq(reenter_ok, [true])
  // 收干净之后再弹一次：菜单本身在 set_context_menu 之外也可以直接弹
  // （菜单栏判据那批已有同形覆盖，这里只验上下文菜单这条的重复可用性）
  let ctx2 : Array[Int32] = []
  assert_eq(c_auto_pick_context_menu(100, 0), 0)
  @native-common.native_show_context_menu(
    @moonui.MenuBar::new([@moonui.Menu::new("M", [Item(first), Item(second)])]),
    fn(id) { ctx2.push(id) },
  )
  assert_eq(ctx2, [first.id])
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
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
fn simulate_file_drop(title : String, paths : String) -> Int32 {
  let t = @utf8.encode(title)
  let s = @utf8.encode(paths)
  c_simulate_file_drop(t, t.length(), s, s.length())
}

///|
#borrow(title)
extern "c" fn c_file_drop_probe(title : Bytes, title_len : Int32) -> Int64 = "moonui_native_file_drop_probe"

///|
fn file_drop_probe(title : String) -> (Bool, Bool, Bool) {
  let t = @utf8.encode(title)
  let bits = c_file_drop_probe(t, t.length())
  (bits % 2L == 1L, bits / 2L % 2L == 1L, bits / 4L % 2L == 1L)
}

///|
/// `T91③` Windows 半（DragAcceptFiles/WM_DROPFILES 便宜路径，owner
/// 2026-10-22 裁决顶上）：①建窗即开接受门（WS_EX_ACCEPTFILES 由系统样式
/// 自己作证），订阅后监听真装上；②替投（内存 DROPFILES → SendMessage
/// WM_DROPFILES，DragQueryFileW 读的就是真拖同一只结构）两条路径（含中文
/// 与空格）原样往返成 FileDrop 事件，target 是这只窗口；③负控制：没有
/// 这只窗报 -2。IDropTarget 的 DoP/DragOver 协议仍是第二期的账。
test "原生后端：文件拖入真收到、路径往返（T91③）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App::new(b)
  let title = "MoonUI 原生 拖入"
  let win = app.create_window(title, @moonui.LogicalSize(340.0, 240.0))
  let label = @moonui.Widget::label(b, "拖到这里")
  win.set_content(@moonui.Widget::column(b, 8.0, [label]))
  win.show()
  let _ = app.step()
  // 订阅触发共享层的惰性安装（与键盘/鼠标监听同一套形状）
  let events : Array[@moonui.Event] = []
  let _ = app.on_event(win.target(), fn(ev) { events.push(ev) })
  scaffold_drain(app)
  // ① 接受门 + 监听：建窗开了 WS_EX_ACCEPTFILES，订阅装上了监听
  let (installed0, registered0, taken0) = file_drop_probe(title)
  assert_true(installed0)
  assert_true(registered0)
  assert_false(taken0)
  // 负控制：窗口不存在时替投报 -2，不产事件
  assert_eq(
    simulate_file_drop("MoonUI 原生 没有这只窗", "C:/tmp/a.txt"),
    -2,
  )
  // ② 真投两条（含中文与空格）：DROPFILES → DragQueryFile → UTF-8 打包
  // → unpack → FileDrop 事件
  assert_eq(
    simulate_file_drop(title, "C:/tmp/一.txt\nC:/tmp/二 空格.txt"),
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
  assert_eq(dropped, Some(["C:/tmp/一.txt", "C:/tmp/二 空格.txt"]))
  let (_, _, taken2) = file_drop_probe(title)
  assert_true(taken2)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
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
fn magnify_in_window(
  title : String,
  x : Int32,
  y : Int32,
  value_micro : Int64,
  phase : Int32,
) -> Int32 {
  let t = @utf8.encode(title)
  c_magnify_in_window(t, t.length(), x, y, value_micro, phase)
}

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
fn rotate_in_window(
  title : String,
  x : Int32,
  y : Int32,
  value_micro : Int64,
  phase : Int32,
) -> Int32 {
  let t = @utf8.encode(title)
  c_rotate_in_window(t, t.length(), x, y, value_micro, phase)
}

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
fn swipe_in_window(
  title : String,
  x : Int32,
  y : Int32,
  direction : Int32,
) -> Int32 {
  let t = @utf8.encode(title)
  c_swipe_in_window(t, t.length(), x, y, direction)
}

///|
/// 手势流水：只留 `Gesture` 的载荷，压成数组（与 mac 半同形）。
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
/// `T106` Windows 半：WM_GESTURE 真接线——合成真 WM_GESTURE 消息
/// （GESTUREINFO 走 GlobalAlloc 的 HGESTUREINFO），解析、累计账、四样读回、
/// Core 翻译整条产品路径都被跑到。①捏合三步（增量定点往返，值取 2 的幂次
/// 分数防整数地板）；②旋转两步（弧度换算的往返一致性）；③swipe 四向
/// （Win32 没有对应物，直走 dispatch 只验共享层翻译）；④归属：控件上报表
/// 控件、空白处报窗口；⑤负控制。
test "原生后端：WM_GESTURE 手势真到达 Core，量与归属都对（T106）" {
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
  let events : Array[@moonui.Event] = []
  let _ = app.on_event(label.target(), fn(ev) { events.push(ev) })
  let _ = app.on_event(win.target(), fn(ev) { events.push(ev) })
  let (cx, cy) = scaffold_center(label.frame(), dpi)
  // ① 捏合三步：增量与相位原样到达（31250 = 0.03125、46875 = 0.046875，
  // 都是 2 的幂次分数，定点往返不损）
  assert_eq(magnify_in_window(title, cx, cy, 31250L, 0), 0)
  assert_eq(magnify_in_window(title, cx, cy, 46875L, 1), 0)
  assert_eq(magnify_in_window(title, cx, cy, 0L, 2), 0)
  scaffold_drain(app)
  assert_eq(scaffold_gesture_log(events), [
    @moonui.Gesture::Magnify(0.03125, @moonui.GesturePhase::Began),
    @moonui.Gesture::Magnify(0.046875, @moonui.GesturePhase::Changed),
    @moonui.Gesture::Magnify(0.0, @moonui.GesturePhase::Ended),
  ])
  for ev in events {
    match ev {
      @moonui.Gesture(t, _) => assert_eq(t, label.target())
      _ => ()
    }
  }
  // ② 旋转两步：1e6 定点弧度 → 1/100 度 → 回读，往返一致
  events.clear()
  assert_eq(rotate_in_window(title, cx, cy, 1570800L, 0), 0)
  assert_eq(rotate_in_window(title, cx, cy, -785400L, 1), 0)
  scaffold_drain(app)
  assert_eq(scaffold_gesture_log(events), [
    @moonui.Gesture::Rotate(1.5708, @moonui.GesturePhase::Began),
    @moonui.Gesture::Rotate(-0.7854, @moonui.GesturePhase::Changed),
  ])
  // ③ 双指滑动四向（Win32 无对应物，dispatch 层直投）
  events.clear()
  assert_eq(swipe_in_window(title, cx, cy, 0), 0)
  assert_eq(swipe_in_window(title, cx, cy, 1), 0)
  assert_eq(swipe_in_window(title, cx, cy, 2), 0)
  assert_eq(swipe_in_window(title, cx, cy, 3), 0)
  scaffold_drain(app)
  assert_eq(scaffold_gesture_log(events), [
    @moonui.Gesture::Swipe(@moonui.SwipeDirection::Left),
    @moonui.Gesture::Swipe(@moonui.SwipeDirection::Right),
    @moonui.Gesture::Swipe(@moonui.SwipeDirection::Up),
    @moonui.Gesture::Swipe(@moonui.SwipeDirection::Down),
  ])
  // ④ 空白处：报窗口自己
  events.clear()
  let empty_x = scaffold_px(180.0, dpi)
  let empty_y = scaffold_px(240.0, dpi)
  assert_eq(magnify_in_window(title, empty_x, empty_y, 31250L, 1), 0)
  scaffold_drain(app)
  for ev in events {
    match ev {
      @moonui.Gesture(t, _) => assert_eq(t, win.target())
      _ => ()
    }
  }
  // ⑤ 负控制：客户区外 -3、没有这只窗 -2
  assert_eq(magnify_in_window(title, -5, -5, 31250L, 1), -3)
  assert_eq(magnify_in_window("没有这只窗", cx, cy, 31250L, 1), -2)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}
