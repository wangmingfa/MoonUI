///|
/// `Backend` 契约在 libui-ng 真后端上的验证（§48 第 09~11 步，§37 第三层的真实版）。
///
/// 这些测试会真的开窗口：契约里"读回来的是原生层的真实值"这一条，只有真窗口
/// 能证明——mock 后端永远会把刚写进去的数原样吐回来，量不出换算有没有错。
///
/// 会推进消息循环的那几条——菜单点击、完整事件循环、打字、勾选，再加 `T39` 的键盘两条与
/// 焦点一条——都走 `for_testing` 的有限等待预算，链路断了就是断言失败；消息框/确认框与
/// 文件面板那两条阻塞在模态面板里、靠预排的脚手架替按（TODO `T43`/`T44`）。
///
/// 这一边的测试按行号引用别处（`:383` 那种写法）已经停用了：插入一条会把后面全部挪走，
/// 而挪走的引用不会自己报错。要指位置就按测试名或 TODO 的永久号。

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
/// 句柄表是**进程全局**的：`../libui-common/ffi.mbt` 包级那个 `let handles` 和
/// `LibuiBackend` 实例无关，而 `Backend::terminate` 只收实例自己记着的
/// `live_widgets`/`live_windows`（`../libui-common/backend.mbt` 里那个 impl）。MoonBit native
/// 的 panic 不执行 `defer`，所以一条测试在断言
/// 处失败时，它建的窗口和控件连着那个实例一起留在表上。
///
/// Windows 上这一漏的后果比 mac 上记的更硬：不是"后面每条跟着红"，而是下一条走到
/// `terminate()` 的测试直接死在 `uiUninit` 末尾的分配审计上（`adapter.c` 的
/// `moonui_terminate` 里那条注释写明它会 `DebugBreak`），整个测试进程以 `0x80000003` 退出，而 native 的 println 是全缓冲的，
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
/// 循环不分种类，而 `uiUninit` 的分配审计要求**控件先于窗口**（`../libui-common/backend.mbt`
/// 里 `Backend::terminate` 上面那段注释），
/// 所以清场不能只靠"把表倒出来挨个销毁"。
let native_widgets_in_play : Array[@moonui.NativeHandle] = []

///|
/// 见 `native_widgets_in_play`。
let native_windows_in_play : Array[@moonui.NativeHandle] = []

///|
/// 清掉上一条失败时漏下的原生对象，让这一条从空的句柄表开始。已经自己收过尾的后端
/// 和句柄也在这几张表里，对它们是空转：`Backend::terminate` 末尾会清空自己的两个数组，
/// `native_*_destroy` 撞上过期句柄就报错并被丢掉（`handle.mbt` 的 `HandleTable::resolve`：
/// id 会复用，但 generation 递增，旧句柄不会命中新对象），
/// 而 `moonui_terminate` 在没 inited 时直接返回（`adapter.c` 里那一句 `if (!moonui_inited)`）。
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
  // 外观（§16）：现在读的是注册表 HKCU\Software\Microsoft\Windows\CurrentVersion\
  // Themes\Personalize\AppsUseLightTheme（0 = 深色；键或值不在 = 浅色），不再是恒报。
  // 这句钉的浅色是那台机器当时的注册表读数，独立尺子是 PowerShell 的
  // `Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`
  // （见 TODO `T40`）；那边若是深色，这条红是读数对了、字面值该跟着改，不是后端坏了。
  // Windows 没有 mac 那种进程级外观覆盖，所以这一侧没有"翻一下再看"的微分，
  // 负控制只能是恒返回相反值那一条（同样见 `T40`）。
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
/// §25 那棵菜单在 Windows 真窗口测试里的夹具，和 `backends/libui-macos/macos_test.mbt`
/// 那一份逐字相同——连注释里的编号也是：id 是 `MenuBar::new` 按整棵树深度优先重排出来的，
/// 归 Core 分配、与后端无关，所以两边拿到同一组数（mac 把它存进 `NSMenuItem.tag`，这边
/// 存进命令 id 的低 16 位，role 另存一份在条目的 `dwItemData` 上）：
///   File：Quit(0, Meta+q)、Sidebar(1, 勾选框)、分隔线、Zoom{ Small(2, radio), Large(3, radio) }
///   Edit：Copy(4, Ctrl+c)、Sync(5, 勾选框且禁用)
/// 5 号故意做成"禁用 + 可勾选"：`moonui_menu_click_item` 的 -2 那一支要它，而 adapter.h
/// 的"禁用项也允许推勾选态"（置灰的菜单项下次启用时勾还看得见）只在 Check/Radio 上量得到
/// ——Normal 项在快照里恒为 `.`。
///
/// 文案一律避开 `;` `{` `}` `,` `:` 和以 `-` 开头：快照用这几个字符分段（adapter.h）。
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
/// 夹具装好之后原生侧应该长成的样子（格式在 adapter.h）。这一串和 mac 那份
/// `menu_dump_full` **逐字符相同**，而那不是巧合而是这次设计的一部分：Windows 这边把
/// 组合拼进标题（`Quit\tMeta+q`）、mac 那边写进 `keyEquivalent` + modifier mask，radio
/// 这边是 `MFT_RADIOCHECK` 的圆点、那边是 AppKit 的勾选点，两份 C 各自把自己平台的原生
/// 状态读回同一根文本——对不上就说明某一边的解析和 `adapter.h` 的布局错位了。
/// （mac 那边本机跑绿过；这一边只到类型检查，真跑欠在 `T45`。）
let menu_dump_full : String = "File{#0:n.e:Quit:Mq,#1:c-e:Sidebar:.,-,+Zoom{#2:r-e:Small:.,#3:r-e:Large:.}};Edit{#4:n.e:Copy:Cc,#5:c-d:Sync:.}"

///|
/// 快照里有没有某一项的完整记录。用在勾选态随点击变化的那几条：整串比对已经在
/// `menu_dump_full` 上做过一次了，这里要逐项盯，但仍然写全 `#<id>:<role><check><enabled>:
/// <label>:<sc>` 一整节，不是只查一个 `+`——只查 `+` 的话格式挪位也照样绿。
fn menu_dump_has(entry : String) -> Bool {
  @libui-common.native_menu_dump().contains(entry)
}

///|
/// §48-20 的"装上去"这一半，Windows 版。和 mac 那份差一处而那一处是本质的：这边没有
/// 进程级主菜单，菜单位是**逐窗口**的（libui 自己也是每只窗口一份 `HMENU`，
/// `windows/window.cpp:554`），所以快照要读出东西必须先有一只活窗口——`moonui_menu_dump`
/// 走的是登记表里最后一只"系统里真挂着菜单"的窗口的 `GetMenu`，不是 adapter 自己记的
/// 那份名单。于是这一条比 mac 多钉一件事：装菜单那一步真的对活窗口调过 `SetMenu`
/// （把 `SetMenu` 整段删掉，`moonui_set_menu_bar` 照旧报 0、树的副本照旧留着，而快照
/// 是空串）。
/// 于是这一条同时钉三件事：
/// - 布局：MoonBit 的序列化器和两份 C 的解析器对的是同一份 adapter.h 布局，一个字段
///   错位就整串对不上；`Submenu` 的递归、分隔线不占 id、禁用项的 `d` 都在这里。
/// - 组合落到了项上：`<sc>` 那一栏读的是条目自己的文案里 `\t` 之后那一段，所以它证明的
///   是"Core 给的 Meta+q / Ctrl+c 真的写进了原生项"。
/// - 拆干净：换一棵是整棵替换（快照只剩 Edit 那一项，旧树里的 id 报 -1），空的一棵就是
///   拆掉——而这里连"窗口还活着"一起断言，所以那个空串是"系统里没挂菜单"给的，不是
///   "没窗口可问"给的。
///
/// 句柄表只有那一只窗口：菜单栏不占 MoonUI 句柄（`set_menu_bar` 不建控件）。
/// 这一条在 mac 那边是 0，因为 mac 装菜单不需要窗口。
test "真后端：菜单栏整棵装进活窗口的原生菜单位，快照逐字符对得上" {
  let b = open_backend()
  b.init()
  let win = b.create_window("MoonUI 菜单栏", @moonui.LogicalSize::{
    width: 300.0,
    height: 200.0,
  })
  b.show_window(win)
  b.set_menu_bar(menu_fixture())
  assert_eq(@libui-common.native_menu_dump(), menu_dump_full)
  assert_eq(@libui-common.native_live_handles(), 1)
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
  // 空的一棵 = 拆掉，窗口照旧活着
  b.set_menu_bar(@moonui.MenuBar::new([]))
  assert_eq(@libui-common.native_menu_dump(), "")
  // 再装一次：拆干净之后重装要还能长成同一根文本——每一棵都是新建的 HMENU，
  // 没有"改旧的"这条路可走（adapter.h：§25 的契约本来就是换一份菜单栏）
  b.set_menu_bar(menu_fixture())
  assert_eq(@libui-common.native_menu_dump(), menu_dump_full)
  b.destroy_window(win)
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
  // 收尾之后再读还是空。这一句在两边钉的不是同一件事：mac 那边菜单是进程全局的，
  // 空串说明 `moonui_menu_clear()` 真的把 `[NSApp mainMenu]` 拆干净了；这边没有活窗口
  // 本来就读不出东西，所以 `terminate` 里那次拆干净改由下面那条"事后才装"的测试开头钉
  // （漏拆的话，那一跑的 `moonui_window_new` 会照着还留着的树给新窗口挂上菜单位，
  // 于是那句"装之前快照是空的"读回来的是整根 `menu_dump_full`）。
  assert_eq(@libui-common.native_menu_dump(), "")
}

///|
/// §48-20 的"点下去"这一半，Windows 版：脚手架对真 HMENU 里的真条目发一条
/// `WM_COMMAND`（`lParam=0` + `HIWORD(wParam)=0`，也就是菜单自己发上来的那个形状，
/// 不是把 MoonBit 的回调直接调一遍）→ 子类化后的窗口过程把命中我们基址的那一条截下来
/// → 回调只报 id → 后端入队 `MenuSelect` → App 派发给订阅者。整条链上没有一个事件是
/// 测试自己造的，所以那句 `assert_eq(seen, [MenuSelect(...)])` 钉的是"命令 id 从原生
/// 条目上带回来了"（顺带钉子类化没漏：把 `moonui_menu_wndproc` 那一层摘掉，这条消息就
/// 落到 libui 的 `runMenuEvent`，那里对未知 id 直接 `DebugBreak`，整个测试进程当场停）。
///
/// 后半截是反方向：§25 的勾选态只存在 Core，原生条目只有写入口，所以每次点击之后由
/// `App::click_menu_item` 逐项推给后端。快照里 `c-` 变 `c+` 看得见这次推送，再点一次变回
/// `c-`（写死成 `true` 的实现在第二发上就红）；Radio 那一对比的是"同组一起推"：互斥是
/// Core 算的，原生层不会自己取消兄弟项，漏推一个就留下两个选中点。
///
/// 禁用那一项（5 号）报 -2 且队列里什么都不冒：`PostMessage` 会绕过置灰直接进窗口过程，
/// 所以脚手架在发之前先查 `GetMenuState` 那一头的位、查到置灰就原样退回（adapter.h
/// 要求两边报同一套码）。
test "真后端：真点击菜单项回流成 MenuSelect，勾选态推回原生菜单位" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  let win = app.create_window("MoonUI 菜单点击", @moonui.LogicalSize::{
    width: 260.0,
    height: 180.0,
  })
  win.show()
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
  win.close()
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 菜单失败的那几条形态。和 mac 那份逐字相同的一处是报错文案：`set_menu_item_checked`
/// 抛的是共享 `backend.mbt` 里的 `OperationFailed`，`MockBackend` 那份断言同一句话
/// （§33 的"同一个失败在所有后端上长成同一个样子"），文案里不许带平台名字。
///
/// 这一边多一处 mac 没有的规矩：那两条 -1 要**在有活窗口、树也装着**的时候问，否则
/// "这个 id 不在当前那棵菜单里"和"没地方可问"是同一条返回值，测了等于没测（mac 那边
/// 菜单是进程全局的，没有这一层）。6 号"上一个 id 都不存在"和 99 号"从没出现过"必须
/// 同为 -1——夹具的编号到 5 为止，写成别的数字就是抄了一份实现。
///
/// 最后一条是"能改"而不是"改得对"：禁用项允许推勾选态，快照里 `#5:c-d` 变 `c+d`。
test "真后端：菜单的失败形态和 MockBackend 逐字相同" {
  let b = open_backend()
  b.init()
  let win = b.create_window("MoonUI 菜单失败形态", @moonui.LogicalSize::{
    width: 260.0,
    height: 180.0,
  })
  b.show_window(win)
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
  b.destroy_window(win)
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 菜单位挤掉的那一行高，两种装序都要还给 Core。这条只在 Windows 存在：mac 的主菜单
/// 不占窗口客户区，而 Win32 的 `SetMenu` 会让客户区矮掉一行，偏偏 §25 的菜单是运行时
/// 才装的，libui 建窗口时按"没有菜单位"算的外框（`hasMenubar=0`）事后并不知道。
///
/// 两种装序的算法不一样，所以两边各钉一半：
/// - 事后才装（产品路径）：`moonui_menu_apply` 摘掉量一次、挂上再量一次，差值就是这一行
///   真正占掉多少（不抄 `SM_CYMENU`：不同 DPI、不同菜单字体下它和实际行高不等），随后
///   每一次 `uiWindowSetContentSize` 都加上这个 `menu_pad`。没补的话读回来的高度少一行
///   （约 20 物理像素，远超 `close_to` 的那 1 像素容差），按这个高度摆下去的控件矩形
///   因此整体偏矮。
/// - 建窗口时就有一棵：`moonui_window_new` 给 libui 的最后一个参数是 1，它自己每次换算
///   都现量当下挂着的那棵（`windows/winutil.cpp:80-106`），所以 `menu_pad` 必须是 0——
///   再加一遍就多了两行，同样红。
/// 拆掉之后 `menu_pad` 要跟着归零，这也是"拆干净"的一部分：留着的话拆完那次
/// `set_window_size` 会多长一行，红在最后那两句上。
///
/// 开头的"装之前快照是空的"看着多余，它量的是 `moonui_terminate` 里那次
/// `moonui_menu_clear_all()`：上一条测试收尾时树还装着，而这边没有活窗口就读不出东西，
/// 只有走到这里新建了窗口才量得到有没有留货（注释在上一条测试的末尾）。
test "真后端：菜单位挤掉的那一行高，两种装序都还给 Core" {
  let b = open_backend()
  b.init()
  assert_eq(@libui-common.native_menu_dump(), "")
  let late = b.create_window("MoonUI 菜单位高度-事后装", @moonui.LogicalSize::{
    width: 300.0,
    height: 200.0,
  })
  b.show_window(late)
  assert_true(close_to(b.window_size(late).height, 200.0))
  b.set_menu_bar(menu_fixture())
  let kept = b.window_size(late)
  assert_true(close_to(kept.width, 300.0))
  assert_true(close_to(kept.height, 200.0))
  b.set_window_size(late, @moonui.LogicalSize::{ width: 420.0, height: 260.0, })
  let grown = b.window_size(late)
  assert_true(close_to(grown.width, 420.0))
  assert_true(close_to(grown.height, 260.0))
  // 拆掉：那一行还给客户区，换算里不能再加它
  b.set_menu_bar(@moonui.MenuBar::new([]))
  assert_true(close_to(b.window_size(late).height, 260.0))
  b.set_window_size(late, @moonui.LogicalSize::{ width: 300.0, height: 200.0, })
  assert_true(close_to(b.window_size(late).height, 200.0))
  b.destroy_window(late)
  // 建窗口时就已经有一棵：libui 自己算过那一行，这里加的必须是 0
  b.set_menu_bar(menu_fixture())
  let early = b.create_window("MoonUI 菜单位高度-建时装", @moonui.LogicalSize::{
    width: 300.0,
    height: 200.0,
  })
  b.show_window(early)
  assert_eq(@libui-common.native_menu_dump(), menu_dump_full)
  assert_true(close_to(b.window_size(early).height, 200.0))
  b.set_window_size(early, @moonui.LogicalSize::{ width: 380.0, height: 240.0, })
  assert_true(close_to(b.window_size(early).height, 240.0))
  b.destroy_window(early)
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 真剪贴板往返（§23 / §48-19）：和 macOS 那份 `真后端读写系统剪贴板，测完把原内容放回去`
/// 同形，钉的是同一件事——写进去的字要能从系统里读回来，读的是真剪贴板而不是 adapter
/// 存的一份影子。
///
/// 这条动的是**用户机器上的真剪贴板**，所以开头把原内容读出来、结尾放回去；复原只覆盖
/// 文本形态，运行时若是图片或文件（CF_HDROP 之类）会被 `EmptyClipboard` 清掉且放不回去。
///
/// 结尾那句复原在测试失败时跑不到——MoonBit 的 panic 不执行后面的语句，和本文件上面
/// `native_windows_in_play` / `backends_in_play` 记的是同一条事实。于是一次失败会把测试
/// 文案留在用户剪贴板里，下一跑还把它当成用户原本的内容存走。包级便条救不了这个：测试
/// 每跑一次都是新进程，进程里的状态带不到下一跑。挡得住的是别把自家文案当用户内容——
/// 开头读回来正是本条写过的那两句时当作空的，结尾那发复原把剪贴板清干净。那一跑用户
/// 原本的内容已经找不回来了，这里只做止损。
///
/// 三个断言各钉一件事：
/// - 写空串再读 → `None`：§23 的"内容为空返回 None"在 Win32 上的形状。C 侧把空文案
///   写成块里那一个 L'\0'（CF_UNICODETEXT 要求带终止符），读回来是空 bytes → None，
///   不是 `Some("")`。空串那一发不能交给 MultiByteToWideChar 的 cbMultiByte=0 形态，
///   那一形是"自己数到终止符"，而 MoonBit 的 Bytes 不保证 NUL 结尾。
/// - 非空往返 → 选 CF_UNICODETEXT 的意义就在这条：文案是中文，走 CF_TEXT 要过当前
///   ANSI 代码页，会丢字。
/// - 覆盖一次 → 只剩最后一份。
///
/// 句柄表照旧归零：剪贴板两条入口都不带句柄、不建原生对象。
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
/// 消息框与确认框（§24 / §48-18）的 Win32 版，和 macOS 那份
/// `test "macOS 后端：消息框与确认框真弹原生面板，答案是按钮给的"` 同形：两条从
/// "如实报 Unsupported"换成真弹 `MessageBoxW`（`T20` 那一轮）。
///
/// 对话框是同步阻塞的（`Backend::confirm` 要当场给答案），所以测试必须先安排好
/// "用户会按哪只按钮"：脚手架那发 `native_auto_dismiss_dialog` 起一条 helper 线程，
/// 到点找到 `#32770` 那只对话框并按控件 ID 发 `BM_CLICK`，于是 MessageBoxW 的返回值
/// 是它自己的按钮给的，不是脚手架编的。
///
/// 三个断言和 mac 那份一一对应：
/// - 消息框：那段阻塞真发生过（空转的实现量不到那 300 毫秒）；
/// - 确认框按 IDYES → `true`、按 IDNO → `false`；
/// - 句柄表归零（对话框不属于任何窗口）。
///
/// **这条测试在本机只到类型检查**：`adapter.c` 的那两条实现与这条脚手架线程都没被
/// cl 编过、也没跑过，真跑欠在那台 Windows 机器上（TODO 的 `T43`）。特别怕是它
/// 挂住而不是红——`moonui_dismiss_worker` 里那两级兜底（`WM_CLOSE`、`VK_ESCAPE`）
/// 就是为这个准备的，真跑之前先读一遍那段注释。
test "真后端：消息框与确认框真弹原生面板，答案是按钮给的" {
  let b = open_backend()
  b.init()
  // 消息框：300 毫秒之后替用户按下那唯一一只"确定"
  let t0 = @libui-common.native_time_ms()
  assert_eq(@libui-common.native_auto_dismiss_dialog(300, 0), 0)
  b.show_message("月 UI 的消息框", "正文")
  let blocked = @libui-common.native_time_ms() - t0
  assert_true(blocked >= 250)
  // 确认框：先按"是"（IDYES），再按"否"（IDNO）
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
/// 文件面板（§24 / §48-18）的 Win32 版，和 macOS 那份
/// `test "macOS 后端：文件 / 保存 / 文件夹面板真弹出来，答案是取消"` 同形，但多
/// 钉一条 mac 钉不了的：接受（`Some(路径)`）。IFileDialog 在**本进程**的模态循环
/// 里跑，替用户按下"接受"是普通窗口消息（先投回车、再退到 IDOK 的 `BM_CLICK`，
/// 见 adapter.c 的 moonui_file_answer_worker）；macOS 15.6 的面板在 XPC 服务进程
/// 里，accept 在那边直接报 -2，原因见 adapter.h。
///
/// 各断言：
/// - 打开：返回的就是装的那条路径（`C:\Windows\win.ini`，系统自带的真文件）；并且
///   那段阻塞**真发生过**——空转的实现立刻返回，量不到这 2 秒。
/// - 保存：同形状。目标文件不必存在：保存面板给的是"打算写到哪"。
/// - 选文件夹：`FOS_PICKFOLDERS` 那一支真工作。
/// - 取消：返回 `None` 而不是上一条的路径——结果在每次面板打开时先清掉，取走语义
///   不会把上一场的答案漏给这一场。
/// - 装"接受"却不给 path 在装的那一步就报 -1（写错的脚手架红在断言上，不许挂住
///   整轮），和越界按钮 index 同一条规矩；这条不弹面板。
/// - 句柄表归零：面板不属于任何窗口，三条入口一个 MoonUI 句柄都不建。
///
/// **这条测试在本机只到类型检查**：`adapter.c` 的 IFileDialog 那半与这条脚手架
/// 线程都没被 cl 编过、也没跑过，真跑欠在那台 Windows 机器上（TODO 的 `T44`）。
/// 特别怕是它挂住而不是红——worker 的逐级兜底（回车 → IDOK → `WM_CLOSE` →
/// `VK_ESCAPE`）就是为这个准备的，真跑之前先读一遍那段注释。2 秒那几发给的是
/// shell 视图装完的时间，真跑嫌早/嫌晚就在那台机器上改。
test "真后端：文件 / 保存 / 文件夹面板真弹出来，路径是面板给的" {
  let b = open_backend()
  b.init()
  // 打开文件
  let t0 = @libui-common.native_time_ms()
  assert_eq(
    @libui-common.native_auto_answer_file_dialog(
      2000, "C:\\Windows\\win.ini", true,
    ),
    0,
  )
  assert_eq(b.open_file("月 UI 的打开"), Some("C:\\Windows\\win.ini"))
  assert_true(@libui-common.native_time_ms() - t0 >= 250)
  // 保存文件
  let t1 = @libui-common.native_time_ms()
  assert_eq(
    @libui-common.native_auto_answer_file_dialog(
      2000, "C:\\Windows\\Temp\\moonui-t21-save-probe.txt", true,
    ),
    0,
  )
  assert_eq(
    b.save_file("月 UI 的保存", "moonui-t21-save-probe.txt"),
    Some("C:\\Windows\\Temp\\moonui-t21-save-probe.txt"),
  )
  assert_true(@libui-common.native_time_ms() - t1 >= 250)
  // 选文件夹
  let t2 = @libui-common.native_time_ms()
  assert_eq(
    @libui-common.native_auto_answer_file_dialog(2000, "C:\\Windows", true),
    0,
  )
  assert_eq(b.select_folder("月 UI 的文件夹"), Some("C:\\Windows"))
  assert_true(@libui-common.native_time_ms() - t2 >= 250)
  // 取消
  assert_eq(@libui-common.native_auto_answer_file_dialog(2000, "", false), 0)
  assert_eq(b.open_file("月 UI 的打开"), None)
  // 写错的脚手架当场红
  assert_eq(@libui-common.native_auto_answer_file_dialog(2000, "", true), -1)
  assert_eq(@libui-common.native_live_handles(), 0)
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
/// 下面这六条过滤是 `backends/libui-macos/macos_test.mbt` 同名的那六条的 Windows 对照，
/// 需要的原因是共享那半（`../libui-common/backend.mbt` 的 `refresh_focus`，`T39`）：焦点
/// 没有既及时又不侵入的原生回调，后端每圈事件循环问一次原生焦点、只在和上一圈不一样时
/// 发事件。于是 `Focus` / `Blur` 现在**可能出现在任何一圈里**，那两条"程序改了不该冒回声"
/// 的负控制再拿整串 `seen` 比对，红的就不是它们要钉的那件事了。
///
/// 过滤不是放水：订阅本来就挂在某一只控件的 target 上，留在数组里的每一条都已经是它的
/// target，比对的只是事件种类。焦点自己由后面那三条专门钉（`T39` 的 Windows 那半）。
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
/// 键盘事件的顺序表：`(打在谁身上, 键, 按下还是抬起)`。
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
/// 用：动作之间比的是"这一步新冒出来什么"。mac 那份给出的理由是 AppKit 会自己定
/// initialFirstResponder；这一边的理由不同而更硬：窗口显示时**整个进程不在前台**，
/// 键盘焦点归谁不归我们说（`moonui_thread_focus` 那段），所以"表最后停在谁身上"才是
/// 能钉的，"第几条开始出现"不能钉。
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
/// 菜单项被点回来的顺序表（§25）。`T39` 那条"这边没有加速键表"要把它和键事件分开数：
/// 两个订阅挂在同一份 `seen` 上，整串比对会把焦点也算进来。
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
/// 缩放事件的顺序表（§30，`T24`）。按种类过滤读的理由和 `focus_events` 同一条：
/// 轮询出来的事件和原生消息落在同一个队列里。
fn scale_events(
  evs : Array[@moonui.Event],
) -> Array[(@moonui.EventTarget, @moonui.Scale)] {
  let out : Array[(@moonui.EventTarget, @moonui.Scale)] = []
  for ev in evs {
    match ev {
      @moonui.ScaleChanged(t, s) => out.push((t, s))
      _ => ()
    }
  }
  out
}

///|
/// Core 摆出去的那只矩形，中心点的物理像素坐标。点击、打字、挪焦点三条脚手架都按坐标
/// 命中而不是"取第几只控件"——布局摆错了它们就命不中（理由见 adapter.h）。
fn phys_center(
  scale : @moonui.Scale,
  frame : @moonui.LogicalRect,
) -> (Int, Int) {
  let spot = @moonui.Scale::to_physical_rect(scale, frame)
  (spot.origin.x + spot.size.width / 2, spot.origin.y + spot.size.height / 2)
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
  // 只数 `Change`：这条钉的是"那一次点击恰好派发了一次"，而焦点读数（`T39`）也算在这只
  // 按钮的 target 上，整串计数会让这条红在窗口显示时焦点归谁那种和点击无关的事上。
  let _ = app.on_event(demo.action_target(), fn(ev) {
    match ev {
      @moonui.Change(_) => hits = hits + 1
      _ => ()
    }
  })
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
  // 空转到预算用完：逐字符那两条都在、每条带的是当时读回的全文，set_text 没有回声。
  // 不写成"step 两次然后队列空"，是因为焦点读数（`T39`）现在也可能在这一圈里冒出
  // `Focus`/`Blur`，谁先回来不是这条要钉的事——按种类过滤才是这条的意思。
  while app.step() {

  }
  assert_eq(input_texts(seen), ["初值打", "初值打字"])
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
  while app.step() {

  }
  assert_eq(changes(seen), [])
  assert_true(check.checked())
  // 负控制二：Core 程序改勾选框的文案不该回声成 Change，读回来的还得是写进去的那句。
  // 勾选框的窗口类名与按钮同为 `L"button"`（`checkbox.cpp:106-108` 拿 `BS_CHECKBOX` 建的），
  // 所以新加的那层 `BS_TYPEMASK` 分派需要一个真走到 `uiCheckboxSetText` 的入口，就是这一句。
  // 限界要说清楚：这一句测不出"分派认错了人"。`uiButtonSetText`（`button.cpp:72-77`）与
  // `uiCheckboxSetText`（`checkbox.cpp:70-75`）函数体逐行相同、`hwnd` 在两个结构体里同偏移，
  // 错派到按钮那一支照样全绿——分派改的是"别 cast 错类型"，不是行为。真能把这一句的下界
  // 钉住的是另外两次：把勾选框那一支改成什么都不做（`check.text()` 那句红），以及在那句
  // setter 之后补一次 `BM_CLICK`（紧跟其后的 `assert_eq(changes(seen), [])` 红）。
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
/// §10/§26 的键盘这一半（`T39` 方案甲），Windows 版：脚手架往**当下有焦点的那只 HWND**
/// 投递 `WM_KEYDOWN`/`WM_KEYUP`，本文件后面那节里的 `WH_GETMESSAGE` 钩子在事件循环**取到
/// 它的那一刻**响，于是走的是和真键盘同一道门，不是"把回调调一遍"。和 mac 那份的时机差
/// 就是这条测试每句断言前面都要 `while app.step() {}` 的原因：那边 `[NSApp sendEvent:]`
/// 同步把回调跑完才返回，这边的回调发生在下一次取消息（`adapter.h` 的脚手架那段写明）。
///
/// 四件事各钉一处：
/// - 一条按键 = 一条事件，按下抬起各一条。钩子只在 `wParam == TRUE`（这条真的被取走）时
///   报，`moonui_messages_pending` 那次 `PM_NOREMOVE` 探测不算——写错的话每颗键数两遍，
///   而这条是按条数判的。
/// - 归属：`moonui_key_owner_of_msg` 从消息自己的 HWND 往上退到第一个打过标记的。焦点在
///   输入框上时 target 是那只输入框，不是窗口。mac 那边中间隔着共享的 field editor，这边
///   中间可能隔着 libui 的 container 窗口——同一档判断，两个平台各种自己那一层。
/// - 键名归一化在 C：脚手架收 Core 那套词（`"a"` / `"Enter"`），读回来也是那套词。Enter
///   在 mac 是 0x24、这边是 `VK_RETURN`，物理键码一个都不许漏到 MoonBit 这一侧。
/// - 修饰键：Windows 的 `WM_KEYDOWN` 不带 ctrl 位（lParam 里只有 bit29 那一位 Alt 上下文），
///   而 `GetKeyState` 归的是"当前前台那套键盘"的账，测试进程没有前台。所以那份自己数
///   （`moonui_mod_count`）：下面给 ⌃⇧ = 5 钉的就是这份自计的状态机，写死成 1 或 4 都会
///   在下一句红。mac 那边同一句读的是 `NSEvent.modifierFlags`，两边到 MoonBit 是同一个字节。
///
/// Alt 那一位**不测**：投递 `VK_MENU` 的按下会让 `DefWindowProc` 进菜单模式，那是用户
/// 桌面上的事而不是断言；meta 也不投，`VK_LWIN` 归系统热键管，投了量不到我们想量的东西。
/// 所以这一边的组合只用 ctrl / shift（mac 那边 ⌘ 归 meta，同一个坑不存在）。
///
/// 词表外的键在派发之前就退回 -4、一条事件都不产：这一句同时钉 `adapter.h` 那五个返回码里
/// "键不在词表里"的那一个。等待预算 200ms 和输入框那条同一个理由：预算是给"证明没有多余
/// 那条"封顶，不是链路的一部分。
test "真后端：真按键成 KeyDown/KeyUp，打在谁身上跟着焦点走" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  let title = "MoonUI Windows 键盘"
  let entry = @moonui.Widget::text_input(b, "")
  let content = @moonui.Widget::column(b, 16.0, [entry])
  let win = app.create_window(title, @moonui.LogicalSize::{
    width: 320.0,
    height: 240.0,
  })
  win.set_content(content)
  win.show()
  let (cx, cy) = phys_center(win.scale(), entry.frame())
  // 0 = 命中的是我们的控件，焦点已经交给它了。没有这一句，下面每一条断言都可能红在
  // "这颗键没有归属、整条被丢掉"上（`moonui_send_key_in_window` 会先报 -3），而不是红在
  // 想钉的那一环。
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
  // ⌃⇧s：bit0 + bit2。这两条投出去的是 VK_CONTROL、VK_SHIFT、's' 三条按下，抬起反过来，
  // 那一头数出来的组合和人手按出来的同一种形状。
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
/// `T39` 的 mac 那条（"菜单认领的 ⌘Q 只回一条 MenuSelect，不双响成 KeyDown"）的镜像：
/// **这一边没有那一档**。`adapter.c` 建 `HMENU` 时明确不建加速键表（"组合的显示文本拼在
/// 标题里，§26 的派发在 Core 的事件循环里"），`TranslateMessage` 也就没有东西可派发，
/// 于是同一个组合在这里只会成为键事件，`MenuSelect` 一条都不许多。
///
/// 这条钉两件事：
/// - 组合真的落成了键事件：夹具的 Copy 带着 Ctrl+c，按下抬起各一条、修饰键读回 ctrl。哪天
///   有人给菜单补了一张加速键表，那两条就变成一条 MenuSelect，下面两句立刻红——这条测试
///   是那一档改动的警报器，而不是"顺手测一下 Windows 没有菜单认领"。
/// - 菜单本身没坏：同一条 ⌃c 之后再按真条目（`native_menu_click_item(4)`）照样回一条
///   MenuSelect。少了这一句，"整条链路没接上"也能让上面两句绿（那是 `[] == []`）。
///
/// ⌃c 打在输入框上不会写剪贴板：编辑框自己判组合用的是 `GetKeyState`，而投递的消息改不了
/// 前台键盘状态（正是同一份 C 里修饰键要自己数的那条理由），所以它只当收到一颗普通的 c。
///
/// 菜单在窗口显示之后才装，`frame()` 在那之后读：菜单位挤掉的行高两种装序都会还给 Core
/// （见"菜单位挤掉的那一行高"那条），命中用的矩形因此是摆好之后的那个。
test "真后端：组合只成键事件，Windows 没有加速键表把它派生成 MenuSelect" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  let title = "MoonUI Windows 菜单不认领组合"
  let entry = @moonui.Widget::text_input(b, "")
  let content = @moonui.Widget::column(b, 16.0, [entry])
  let win = app.create_window(title, @moonui.LogicalSize::{
    width: 320.0,
    height: 240.0,
  })
  win.set_content(content)
  win.show()
  app.set_menubar(menu_fixture())
  let (cx, cy) = phys_center(win.scale(), entry.frame())
  assert_eq(@libui-common.native_focus_widget_in_window(title, cx, cy), 0)
  let seen : Array[@moonui.Event] = []
  let copy = @moonui.EventTarget::{ id: 4, }
  let _ = app.on_event(copy, fn(ev) { seen.push(ev) })
  let _ = app.on_event(entry.target(), fn(ev) { seen.push(ev) })
  while app.step() {

  }
  assert_eq(@libui-common.native_send_key_in_window(title, "c", 1, true), 0)
  assert_eq(@libui-common.native_send_key_in_window(title, "c", 1, false), 0)
  while app.step() {

  }
  assert_eq(menu_selects(seen), [])
  let ctrl_c = @moonui.KeyPress::{
    key: "c",
    ctrl: true,
    alt: false,
    shift: false,
    meta: false,
  }
  assert_eq(key_events(seen), [
    (entry.target(), ctrl_c, true),
    (entry.target(), ctrl_c, false),
  ])
  // 菜单还活着：条目按下去照旧回一条 MenuSelect，而它不带任何键事件
  assert_eq(@libui-common.native_menu_click_item(4), 0)
  while app.step() {

  }
  assert_eq(menu_selects(seen), [copy])
  assert_eq(key_events(seen).length(), 2)
  assert_eq(@libui-common.native_request_window_close(title), 0)
  while app.step() {

  }
  assert_true(win.is_closed())
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// §32 的焦点这一半（`T39` 方案甲的另一半），Windows 版：焦点没有回调，后端每圈事件循环
/// 问一次 `native_focused_control`，只在和上一圈不一样时发事件。"连着抽两圈什么新事件都不
/// 冒"是这套轮询唯一的形状，也是它和"每次 poll 都抄一遍原生焦点"的差别——后者会把 `Focus`
/// 刷成一条不停的消息。
///
/// 和 mac 那份的三处不同，每一处都是平台的形状而不是写法：
/// - 归属那一层：mac 从 firstResponder 退到"被编辑的那只控件"（共享 field editor），这边从
///   `GetFocus`/`GetGUIThreadInfo` 给的 HWND 往上退到第一个打过标记的祖先。
/// - "是我们的控件但拿不了焦点"这一档用的是**禁用控件**，不是 mac 那边的 label：`SetFocus`
///   文档写明的失败只有"句柄无效""不在本线程消息队列上"和"禁用（`ERROR_INVALID_PARAMETER`
///   0x57）"三种，STATIC 能不能拿焦点不在文档里，所以那一档留给 TODO `T46` 去量。两边共用
///   同一条判据（**回读**而不是 `SetFocus` 的返回值：那条 API 分不清"失败"和"本来就没焦点"，
///   两种都给 NULL），因此 `-4` 这一档在两边是同一个数。
/// - 失败的这一步焦点**根本不动**，所以第四步表里一条都不许多。mac 那边 label 那次会冒一条
///   `Blur`：`makeFirstResponder:` 答应之后 firstResponder 落回窗口自己，焦点真的离开了
///   输入框。同一句"原生答应了"和"焦点真到了我们控件上"的分叉，两边各给了一个不同答案。
///
/// 第四步之后那两条失败形态钉的是 -3（点落在窗口之外——`ChildWindowFromPoint` 只在点出了
/// 父窗口客户区时才返回 NULL）和 -2（根本没有这只窗口），都是"焦点没动"。
/// "客户区里的空白处"这一条 mac 有、这边**故意没有**：命中的很可能是那只列自己的 container
/// 窗口，而列是我们创建的控件、打过标记，于是往上退那一步当场就命中，`-4` 那一档变成"容器
/// 能不能拿焦点"的问题——同样是 `T46` 要量的，量出来之前写死任何一个数都是抄一份猜测。
///
/// 第五步关掉窗口：不留尾巴上的 `Blur`。焦点表按 `live_windows` 重建，销毁的窗口整个从表里
/// 掉出去（Core 本来也不给关掉的窗口派发，§12）。
test "真后端：改焦点出恰好一条 Focus，挪走补一条 Blur，不再改就不多冒" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  let title = "MoonUI Windows 焦点"
  let first = @moonui.Widget::text_input(b, "第一只")
  let second = @moonui.Widget::text_input(b, "第二只")
  let off = @moonui.Widget::text_input(b, "这只被禁用了")
  off.set_enabled(false)
  let content = @moonui.Widget::column(b, 16.0, [first, second, off])
  let win = app.create_window(title, @moonui.LogicalSize::{
    width: 320.0,
    height: 240.0,
  })
  win.set_content(content)
  win.show()
  let (fx, fy) = phys_center(win.scale(), first.frame())
  let (sx, sy) = phys_center(win.scale(), second.frame())
  let (ox, oy) = phys_center(win.scale(), off.frame())
  let seen : Array[@moonui.Event] = []
  let _ = app.on_event(first.target(), fn(ev) { seen.push(ev) })
  let _ = app.on_event(second.target(), fn(ev) { seen.push(ev) })
  let _ = app.on_event(off.target(), fn(ev) { seen.push(ev) })
  while app.step() {

  }
  // 一、焦点给第二只输入框：只钉"最后停在谁身上"。窗口显示时整个进程不在前台，键盘焦点
  // 归谁不由我们说（见 `focus_new` 那段），所以这一步不管表里先前冒了几条。
  assert_eq(@libui-common.native_focus_widget_in_window(title, sx, sy), 0)
  while app.step() {

  }
  let now = focus_events(seen)
  assert_eq(now[now.length() - 1], ("+", second.target()))
  let mut from = now.length()
  // 二、挪回第一只：先 Blur 再 Focus，两条都在且顺序不反（§32 的"先告别再欢迎"）
  assert_eq(@libui-common.native_focus_widget_in_window(title, fx, fy), 0)
  while app.step() {

  }
  assert_eq(focus_new(seen, from), [
    ("-", second.target()),
    ("+", first.target()),
  ])
  from = focus_events(seen).length()
  // 三、再"给"一次已经拿着它的那只：一条都不许多。写错成"每次问都发"在这里红。
  assert_eq(@libui-common.native_focus_widget_in_window(title, fx, fy), 0)
  while app.step() {

  }
  while app.step() {

  }
  assert_eq(focus_new(seen, from), [])
  // 四、焦点给禁用控件：-4，而且表里一条都不许多——SetFocus 当场失败，焦点还在第一只上。
  assert_eq(@libui-common.native_focus_widget_in_window(title, ox, oy), -4)
  while app.step() {

  }
  assert_eq(focus_new(seen, from), [])
  from = focus_events(seen).length()
  // 五、两条失败形态各钉一个返回码，焦点同样没动。
  assert_eq(
    [
      @libui-common.native_focus_widget_in_window(title, fx + 4000, fy),
      @libui-common.native_focus_widget_in_window("没有这只窗口", 5, 5),
    ],
    [-3, -2],
  )
  while app.step() {

  }
  assert_eq(focus_new(seen, from), [])
  // 六、关窗口：尾巴上不留 Blur
  assert_eq(@libui-common.native_request_window_close(title), 0)
  while app.step() {

  }
  assert_true(win.is_closed())
  assert_eq(focus_new(seen, from), [])
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 缩放轮询不许有空转事件（§30、§48 第 21 步，`T24`）。这条和 mac 那份
/// "窗口停在同一块屏上时一条 ScaleChanged 都不许多" 同形；`backend.mbt` 的
/// `refresh_scale` 是两侧共用的同一份 MoonBit 代码，所以这一边要钉的不是那段逻辑
/// （那在 mac 上跑绿了），而是它接到 Win32 读数上会不会自己动：`moonui_window_dpi`
/// 在那边是 `GetDpiForWindow`，取不到才退回 `moonui_system_dpi`（adapter.c 的
/// `moonui_dpi_of`），两条路径都不该在窗口没动的时候给出两个不同的数。
///
/// 三段各钉一种"读了但没变"，和 mac 那三条一一对应：第一圈只记不报、同一块屏内
/// 挪两次窗口、什么都不做再抽干一次。等待预算 200ms = 25 圈轮询。
///
/// **这一条今天在这台 Mac 上没跑过**，只过了类型闸门；红线位置由那台机器量，
/// 账在 TODO `T51`。
test "真后端：窗口停在同一块屏上时一条 ScaleChanged 都不许多" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  let title = "MoonUI 缩放轮询"
  let note = @moonui.Widget::label(b, "停在原处")
  let content = @moonui.Widget::column(b, 16.0, [note])
  let win = app.create_window(title, @moonui.LogicalSize::{
    width: 320.0,
    height: 240.0,
  })
  win.set_content(content)
  win.show()
  let seen : Array[@moonui.Event] = []
  let _ = app.on_event(win.target(), fn(ev) { seen.push(ev) })
  // 一、第一圈只记不报
  while app.step() {

  }
  assert_eq(scale_events(seen), [])
  let before = win.scale()
  // 二、同一块屏内挪动：换位置不换屏
  win.set_position(@moonui.LogicalPoint::{ x: 40.0, y: 60.0, })
  while app.step() {

  }
  win.set_position(@moonui.LogicalPoint::{ x: 120.0, y: 80.0, })
  while app.step() {

  }
  assert_eq(scale_events(seen), [])
  // 三、什么都不做，再抽干一次
  while app.step() {

  }
  assert_eq(scale_events(seen), [])
  assert_eq(win.scale(), before)
  win.close()
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 换屏真触发（§30、§48 第 21 步，`T24`）：`GetDpiForWindow` 是不是真的跟着窗口
/// 当下所在那块屏走。mac 那一侧这台机器已经量到"搬过去读数 192→96、恰好一条事件"，
/// 这一条要在那台机器上给同一个数——它是这条能力在 Windows 上唯一的证据。
///
/// 形状抄 mac 那份，两点按 Windows 改写：
/// - 前题照样是**量**出来的：搬之前读一次 Scale、搬之后读一次，不同才走"恰好一条"
///   那一支；那台机器若只有一块屏（或两块屏倍数一样），这一支退化成"搬动不冒事件"
///   并打一行说明。写死成"必须不同"就是把测试变成对显示器配置的断言。
/// - 搬动的距离用**物理像素**算：Windows 是 DPI 感知的，`moonui_window_set_position`
///   直接收像素，所以目标点取"主屏工作区右边界再往右 300 像素"，而工作区宽度要先
///   从 `screen_size()`（那边是 `SPI_GETWORKAREA`）换算回物理像素才不被缩放吃掉。
///   留 300 的理由和 mac 同一条：任务栏在哪一侧会让工作区宽度少掉一截，余量太薄的
///   话窗口可能整体还压在两块屏的交界上，那不算换屏。
///
/// **这一条今天在这台 Mac 上没跑过**，只过了类型闸门；账在 TODO `T51`。
test "真后端：窗口搬去另一块屏出恰好一条 ScaleChanged，搬回来再来一条" {
  let b = open_backend_for_testing(200)
  let app = @moonui.App::new(b)
  b.init()
  let title = "MoonUI 换屏"
  let note = @moonui.Widget::label(b, "换屏")
  let content = @moonui.Widget::column(b, 16.0, [note])
  let win = app.create_window(title, @moonui.LogicalSize::{
    width: 320.0,
    height: 240.0,
  })
  win.set_content(content)
  win.show()
  let seen : Array[@moonui.Event] = []
  let _ = app.on_event(win.target(), fn(ev) { seen.push(ev) })
  while app.step() {

  }
  assert_eq(scale_events(seen), [])
  let scale = win.scale()
  // 主屏工作区的右边界，物理像素：screen_size 给的是逻辑值，这里乘回去。
  let right = scale.to_physical_size(b.screen_size()).width.to_double()
  win.set_position(@moonui.LogicalPoint::{
    x: (right + 300.0) / scale.x,
    y: 40.0,
  })
  let after = win.scale()
  if after != scale {
    while app.step() {

    }
    assert_eq(scale_events(seen), [(win.target(), after)])
    // 搬回主屏：又一个方向，读数要回到出发时那一份
    win.set_position(@moonui.LogicalPoint::{ x: 40.0, y: 40.0, })
    while app.step() {

    }
    assert_eq(scale_events(seen), [(win.target(), after), (win.target(), scale)])
    assert_eq(win.scale(), scale)
  } else {
    println(
      "换屏触发没跑到：这块机器上搬出去前后的 DPI 读数一样，只钉了搬动不冒事件",
    )
    while app.step() {

    }
    assert_eq(scale_events(seen), [])
  }
  win.close()
  assert_eq(@libui-common.native_live_handles(), 0)
  b.terminate()
}
