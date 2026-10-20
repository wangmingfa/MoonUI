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
      Submenu("Zoom", [
        Item(small),
        Item(large),
      ]),
    ]),
    @moonui.Menu::new("Edit", [
      Item(copy),
      Item(sync),
    ]),
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
      @moonui.Menu::new("Edit", [
        Item(@moonui.MenuItem::new("Copy")),
      ]),
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
