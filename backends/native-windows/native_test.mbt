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
  let b = @native-common.NativeBackend()
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
  // §15/§16 的样式下发在 Label 这一处**真消费**（皮肤通道的三处定点之一，
  // 见 ../native-common/adapter.h 与 C 侧 widget_set_style 的段注）：
  // 字号推大之后，控件报的度量必须跟着长——量的时候问的是控件自己挂的
  // HFONT（WM_GETFONT），画的也是它，两把尺才对得上。
  b.set_widget_style(label, @moonui.style(font_size=Some(32.0)))
  let styled = b.widget_intrinsic_size(label)
  assert_true(styled.width > long.width)
  assert_true(styled.height > long.height)
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
/// Panel（kind 17）的收编路径：`collect_attach` 里 Panel 认领子树，Core 走
/// `attach_widget_to`——mac 半是真 NSView 容器；Windows 半的 Panel 是一只空
/// STATIC，坐标契约又是"窗口绝对坐标"（`set_bounds` 只对 Scroll 平移），所以
/// C 侧把子控件平铺挂到 Panel 的父窗口上。2026-10-22 的真实现象：这条没接，
/// lunamusic 的整棵 UI（几乎全包在 Panel 里）全留在 park，六只窗全白。这条
/// 红的时候控件的矩形读回会变成 park 客户区的负角坐标。
test "原生后端：Panel 收编子控件平铺挂窗，不留在 park" {
  let b = open_backend()
  b.init()
  let win = b.create_window(
    "MoonUI 原生 Panel 收编",
    @moonui.LogicalSize(300.0, 200.0),
  )
  let panel = b.create_widget(@moonui.Panel, "")
  let btn = b.create_widget(@moonui.Button, "钮")
  b.attach_widget(win, panel)
  b.set_widget_bounds(
    panel,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(300.0, 200.0),
    ),
  )
  // Panel 认领子树——与 Window::set_content 的 collect_attach 同一条路
  b.attach_widget_to(panel, btn)
  b.set_widget_bounds(
    btn,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 12.0),
      @moonui.LogicalSize(80.0, 30.0),
    ),
  )
  b.show_window(win)
  // 真挂进窗了：可见，矩形按窗口客户区读回（留在 park 的话这条读回是
  // 屏幕负角的大负数，widget_visible 也恒 false）。
  assert_true(b.widget_visible(btn))
  let rect = b.widget_bounds(btn)
  assert_true(close_to(rect.origin.x, 10.0))
  assert_true(close_to(rect.origin.y, 12.0))
  assert_true(close_to(rect.size.width, 80.0))
  assert_true(close_to(rect.size.height, 30.0))
  b.destroy_widget(btn)
  b.destroy_widget(panel)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
#borrow(title)
extern "c" fn c_clipsiblings_probe(title : Bytes, title_len : Int32) -> Int64 = "moonui_native_clipsiblings_probe"

///|
fn clipsiblings_probe(title : String) -> Int64 {
  let t = @utf8.encode(title)
  c_clipsiblings_probe(t, t.length())
}

///|
#borrow(title)
extern "c" fn c_transparent_probe(title : Bytes, title_len : Int32) -> Int64 = "moonui_native_transparent_probe"

///|
fn transparent_probe(title : String) -> Int64 {
  let t = @utf8.encode(title)
  c_transparent_probe(t, t.length())
}

///|
#borrow(title)
extern "c" fn c_overlay_probe(title : Bytes, title_len : Int32) -> Int64 = "moonui_native_overlay_probe"

///|
fn overlay_probe(title : String) -> Int64 {
  let t = @utf8.encode(title)
  c_overlay_probe(t, t.length())
}

///|
/// 2026-10-22 lunamusic 那次"整窗空白、鼠标划过才显形"的回归钉：子控件必须
/// 带 WS_CLIPSIBLINGS。缺这一位时，z 序在下面的兄弟（kind 17 的空白 Panel
/// Static、各种占位的空 Static）重画会把自己整块矩形刷成类底色，把压在上面
/// 的标签/按钮整片盖住。真跑取证：把 6 只大 Static 藏起来，内容当场全露；
/// 加上这一位后开窗即见内容。
///
/// 判据用的是"扫过几只 + 缺几只"打包值，所以这条同时钉住"探针真的扫到了
/// 控件"（低 32 位非零）——没有控件时高 32 位也会是 0，光判高 32 位等于空转。
test "原生后端：子控件带 WS_CLIPSIBLINGS，不盖住兄弟（2026-10-22 整窗空白）" {
  let b = open_backend()
  b.init()
  let win = b.create_window(
    "MoonUI 原生 兄弟裁剪",
    @moonui.LogicalSize(300.0, 200.0),
  )
  let panel = b.create_widget(@moonui.Panel, "")
  let label = b.create_widget(@moonui.Label, "标签")
  let btn = b.create_widget(@moonui.Button, "钮")
  b.attach_widget(win, panel)
  b.set_widget_bounds(
    panel,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(300.0, 200.0),
    ),
  )
  b.attach_widget_to(panel, label)
  b.set_widget_bounds(
    label,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(120.0, 20.0),
    ),
  )
  b.attach_widget_to(panel, btn)
  b.set_widget_bounds(
    btn,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 40.0),
      @moonui.LogicalSize(80.0, 30.0),
    ),
  )
  b.show_window(win)
  let packed = clipsiblings_probe("MoonUI 原生 兄弟裁剪")
  assert_true(packed >= 0)
  let scanned = packed & 0xFFFF_FFFFL
  let missing = (packed >> 32) & 0xFFFF_FFFFL
  // 探针真的扫到了控件：三只（Panel + 标签 + 按钮）都在窗口名下
  assert_true(scanned >= 3L)
  // 一只都不许缺
  assert_eq(missing, 0L)
  b.destroy_widget(btn)
  b.destroy_widget(label)
  b.destroy_widget(panel)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 2026-10-23 那次"部分内容出不来、鼠标移上去才出来 / 某些区域直接看见后面的
/// 窗口"的回归钉（`T117`）。根因是**裁剪账的另一半**：
///
/// 一只子窗口如果自己什么都不画（滚动视口 kind 15、没底色的透明 Panel），它的
/// 矩形需要底下那位替它铺。可父窗口带 `WS_CLIPCHILDREN`（擦背景时跳过子窗口
/// 矩形），底下的兄弟带 `WS_CLIPSIBLINGS`（画时被上面这位裁掉）——两边都不落
/// 笔，那块矩形就没有像素，DWM 直接把**后面的窗口**透出来。真实现象：lunamusic
/// 的播放列表里露出背后的终端；鼠标划过让邻居失效重画、把这块带了进去，内容
/// 才回来。`WS_EX_TRANSPARENT` 把裁剪顺序拧成"先画兄弟、再画自己"，洞就没了。
///
/// **但这把刀两边都割**：同一位的副作用是把这只排到所有兄弟之后画，给不透明
/// 的大 Panel 挂上就变成盖住一切的覆盖层（2026-10-23 当日咬回来的第二张截图：
/// 打开一片蓝、鼠标划过才冒出几颗按钮）。所以判据必须是双向的——不画的必须
/// 带（否则留洞），会画的必须不带（否则压住兄弟），两个方向都为零才算过。
test "原生后端：WS_EX_TRANSPARENT 不给自己留洞，也不许盖住兄弟（T117）" {
  let b = open_backend()
  b.init()
  let win = b.create_window(
    "MoonUI 原生 透明裁剪",
    @moonui.LogicalSize(300.0, 200.0),
  )
  // 不透明的整窗底：会自己画，**不许**带这一位（带上了它就是覆盖层）。
  let solid = b.create_widget(@moonui.Panel, "")
  // 透明面板：不画自己的底，**必须**带这一位。
  let clear = b.create_widget(@moonui.Panel, "")
  // 滚动视口：占着矩形、自己什么都不画，必须带。
  let scroll = b.create_widget(@moonui.Scroll, "")
  let label = b.create_widget(@moonui.Label, "标签")
  b.attach_widget(win, solid)
  b.set_widget_style(
    solid,
    @moonui.style(background=Some(@moonui.Color::rgb(0x1F, 0x44, 0x68))),
  )
  b.set_widget_bounds(
    solid,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(300.0, 200.0),
    ),
  )
  b.attach_widget_to(solid, clear)
  // 不给底色：透明底板（Panel 的默认语义）
  b.set_widget_bounds(
    clear,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(300.0, 200.0),
    ),
  )
  b.attach_widget_to(clear, scroll)
  b.set_widget_bounds(
    scroll,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(280.0, 120.0),
    ),
  )
  b.attach_widget_to(scroll, label)
  b.set_widget_bounds(
    label,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(4.0, 4.0),
      @moonui.LogicalSize(120.0, 20.0),
    ),
  )
  b.show_window(win)
  let packed = transparent_probe("MoonUI 原生 透明裁剪")
  assert_true(packed >= 0)
  let scanned = packed & 0xFFFFL
  let hole_kind = (packed >> 16) & 0xFFFFL
  let hole = (packed >> 32) & 0xFFFFL
  let overlay = (packed >> 48) & 0xFFFFL
  // 探针真的扫到了控件。**三只**：kind 17 的子树是平铺到窗口名下的（见
  // `moonui_native_container_attach` 的 kind 17 分支），所以不透明 Panel、
  // 透明 Panel、滚动视口三只都是顶层窗口的直属子窗口；标签挂在**视口里面**
  // （`SetParent` 到视口），不在这份账上。缺陷只发生在直属子窗口之间，扫这一
  // 层就够，不必往下钻。
  assert_eq(scanned, 3L)
  // 不画却没带 = 会留洞。先核 `hole_kind`：它是"第一只出问题的子窗口的
  // kind+1"，红的时候直接告诉你是哪一种，省得再回去猜。
  assert_eq(hole_kind, 0L)
  assert_eq(hole, 0L)
  // 会画却带了 = 压住兄弟（2026-10-23 第二张截图那个形状）
  assert_eq(overlay, 0L)
  b.destroy_widget(label)
  b.destroy_widget(scroll)
  b.destroy_widget(clear)
  b.destroy_widget(solid)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 2026-10-28 应 owner"鼠标从红色箭头指的地方移过时，那些地方显示异常了"
/// （`T140`）：无底标签的字被底下那层重画盖掉。
///
/// `T117` 的 `WS_EX_TRANSPARENT` 只解决"同一轮更新里谁后画"——它让标签排到
/// 兄弟之后，但前提是**这一轮轮到了标签**。底下那层（脸面渐变条带、顶部条）
/// 自己重新失效时，标签并不在更新区里，于是只有底落笔、字被新底覆盖，此后
/// 也不会自愈；鼠标划过触发整树重推样式、每只控件各失效一次，就把这件事放大
/// 成整窗文字成批消失（真窗量到：顶部条单独失效一遍，标题框颜色种类 29→1）。
///
/// 判据读的是**更新区**：底失效之后标签那格必须跟着脏。用更新区而不是像素，
/// 是因为 `PrintWindow` / `WM_PRINTCLIENT` 走的是应用自己那份绘制顺序，会把
/// "有没有轮到标签"整个抹平（同一支像素探针在两种构建间会 0/442 地跳）。
test "原生后端：底重画时无底标签跟着失效（T140）" {
  let b = open_backend()
  b.init()
  let win = b.create_window(
    "MoonUI 原生 透明标签联动",
    @moonui.LogicalSize(300.0, 200.0),
  )
  // 会画底的兄弟：整窗铺一层不透明底色，标签压在它上面。
  let back = b.create_widget(@moonui.Panel, "")
  let note = b.create_widget(@moonui.Label, "标签")
  b.attach_widget(win, back)
  b.set_widget_style(
    back,
    @moonui.style(background=Some(@moonui.Color::rgb(0x1F, 0x44, 0x68))),
  )
  b.set_widget_bounds(
    back,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(300.0, 200.0),
    ),
  )
  b.attach_widget(win, note)
  b.set_widget_bounds(
    note,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(120.0, 20.0),
    ),
  )
  // 只给文字色、不给底色：这才是脸面上那五块的形状（`T139` 在
  // `widget_set_style` 里按 `bg < 0` 挂 `WS_EX_TRANSPARENT` 并登记）。
  b.set_widget_style(
    note,
    @moonui.style(foreground=Some(@moonui.Color::rgb(0xE8, 0xF3, 0xFF))),
  )
  b.show_window(win)
  let packed = overlay_probe("MoonUI 原生 透明标签联动")
  let status = packed & 0xFFL
  let flagged = (packed >> 16) & 0xFFFFL
  let paired = (packed >> 32) & 0xFFFFL
  let scanned = (packed >> 48) & 0xFFFFL
  let dirty_before = (packed >> 8) & 1L
  let followed = (packed >> 10) & 1L
  // 状态 0 = 找到了窗口、透明标签、压着它的底。
  assert_eq(status, 0L)
  // 探针真扫到了控件，且无底标签确实带了那一层标记（T139 的约定还在）。
  assert_true(scanned >= 2L)
  assert_true(flagged >= 1L)
  // 配对表里确实有这只标签（登记没漏）。
  assert_true(paired >= 1L)
  // 开测前不该已经脏着，否则"跟着脏"就无从分辨。
  assert_eq(dirty_before, 0L)
  // 底失效之后这次重画必须**轮到了标签**。`T318` 之后两笔是同一个调用里
  // 落完的，更新区随即清空，所以这里读的是配对计数（位 10）而不是
  // `dirty_after`（位 9 保留读回，不再断言）——验的是"标签被带上了"这个
  // 事实，不是"脏区还留着"这个手段。
  assert_eq(followed, 1L)
  b.destroy_widget(note)
  b.destroy_widget(back)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
#borrow(title)
extern "c" fn c_panel_probe(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int64 = "moonui_native_panel_probe"

///|
fn panel_probe(title : String, x : Int32, y : Int32) -> Int64 {
  let t = @utf8.encode(title)
  c_panel_probe(t, t.length(), x, y)
}

///|
/// 皮肤通道的 Windows 半（Panel 底色 + 圆角）——真画出来、真读像素。
///
/// 为什么不读属性表：prop 只能证明"值到了"，证明不了"画成了那个样子"。圆角
/// 这一项尤其如此，中间有三处会让记下的值和看到的画面分家：类背景刷先把角
/// 刷平、WM_PAINT 没接、GDI+ 没起来。所以这条走 `moonui_native_panel_probe`
/// ——让面板用**它自己那份画法**（WM_PRINTCLIENT，与 WM_PAINT 共用一个绘制
/// 函数）离屏重画一遍，再读中心与四个角的像素。
///
/// 三段判据，正好是负控制的两端：
///   ① 直角（radius 0）：中心是面色，四角**也**是面色（都染上了）；
///   ② 圆角（radius 12）：中心是面色，四个角**都**不是面色（被圆角切掉）；
///   ③ 没给底色：中心不是那个色（面板透明，什么都不画）。
/// ②红在"角是面色"= 圆角没画出来；③红在"中心是面色"= 不给底也糊了一块色。
test "原生后端：Panel 的底色与圆角真画出来，像素逐点对账" {
  // 有限等待预算（`open_backend_for_testing`）：这条改样式之后要推一轮 step 让
  // 重排把新样式下发，而样式改动本身**不产生事件**——无限预算的 `step()` 会
  // 一直等下去（同族测试都走这条入口，理由与 "poll_event 的两个终止条件"
  // 那条一样：链路断了是失败，不是挂住）。
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App(b)
  let win = app.create_window(
    "MoonUI 原生 Panel 皮肤",
    @moonui.LogicalSize(240.0, 180.0),
  )
  let panel = @moonui.Widget::panel(b, @moonui.Widget::spacer(b))
  win.set_content(panel)
  // 一块扎眼的面色（0x3366CC），出任何偏差都藏不住。
  let face = @moonui.Color::rgb(0x33, 0x66, 0xCC)
  let _ = panel.set_style(
    Some(@moonui.style(background=Some(face), radius=Some(0.0))),
  )
  win.show()
  let _ = app.step()
  let title = "MoonUI 原生 Panel 皮肤"
  match panel.handle() {
    Some(_) => {
      let f = panel.frame()
      let dpi = @native-common.native_window_dpi(win.handle())
      let (cx, cy) = scaffold_center(f, dpi)
      // ① 直角：中心与四角都是面色
      let square = panel_probe(title, cx, cy)
      assert_eq((square >> 56) & 0xFFL, 0L)
      assert_eq((square >> 48) & 1L, 1L)
      assert_eq((square >> 49) & 0xFL, 0L)
      // 中心像素的低 24 位就是下发的那份 0xRRGGBB（0x3366CC 原样回来：
      // 探针按 0xRRGGBB 打包，与 set_style 收的那套同序，不在这里再翻一次）
      assert_eq(square & 0xFF_FFFFL, 0x33_66CCL)
      // ② 圆角：四角全被切掉
      let _ = panel.set_style(
        Some(@moonui.style(background=Some(face), radius=Some(12.0))),
      )
      let _ = app.step()
      let round = panel_probe(title, cx, cy)
      assert_eq((round >> 56) & 0xFFL, 0L)
      assert_eq((round >> 48) & 1L, 1L)
      assert_eq((round >> 49) & 0xFL, 0xFL)
      // ③ 撤掉底色：面板透明，中心不再是那块色
      let _ = panel.set_style(Some(@moonui.style(radius=Some(0.0))))
      let _ = app.step()
      let blank = panel_probe(title, cx, cy)
      assert_eq((blank >> 56) & 0xFFL, 0L)
      assert_eq((blank >> 48) & 1L, 0L)
    }
    None => assert_true(false)
  }
  // 负控制：坐标不在 Panel 上 / 窗口不存在
  assert_eq((panel_probe("没有这只窗口", 4, 4) >> 56) & 0xFFL, 1L)
  // 收尾顺序照 `T111` 那条：先 terminate 再数句柄——App 那条路的窗口与控件
  // 都归 backend 管，terminate 之前它们本来就还在表里。
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
#borrow(title)
extern "c" fn c_font_family_probe(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int64 = "moonui_native_font_family_probe"

///|
#borrow(title)
extern "c" fn c_button_probe(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int64 = "moonui_native_button_probe"

///|
#borrow(title)
extern "c" fn c_single_font_probe(title : Bytes, title_len : Int32) -> Int64 = "moonui_native_single_font_probe"

///|
fn button_probe(title : String, x : Int32, y : Int32) -> Int64 {
  let t = @utf8.encode(title)
  c_button_probe(t, t.length(), x, y)
}

///|
/// 跨平台统一外观：应用选定的字体族真下到原生 HFONT——不只看 prop 记没记，
/// 还看 `WM_GETFONT` 拿到的 face 名。字族 + 字号一起设（只设字族而字号继承时
/// Windows 侧也会按需补造一只字，这条走的是有字号的常规路径）。
test "原生后端：字体族真落到 HFONT 的 face 名" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App(b)
  let title = "MoonUI 原生 字体族"
  let win = app.create_window(title, @moonui.LogicalSize(280.0, 160.0))
  let label = @moonui.Widget::label(b, "Hello")
  win.set_content(@moonui.Widget::column(b, 12.0, [label]))
  let _ = label.set_style(
    Some(@moonui.style(font_family=Some("Arial"), font_size=Some(16.0))),
  )
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let (cx, cy) = scaffold_center(label.frame(), dpi)
  let t = @utf8.encode(title)
  let probe = c_font_family_probe(t, t.length(), cx, cy)
  // 低 8 位：family prop 记着；次 8 位：HFONT face 名与之相同
  assert_eq(probe & 0xFFL, 1L)
  assert_eq((probe >> 8) & 0xFFL, 1L)
  b.destroy_window(win.handle())
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// 只钉字族、不钉字号（TodoList::demo 的 `unified_style(family)` 就是这条），
/// 字族也必须真的落到 HFONT 的 face 名。否则 label 量宽度用的是系统消息字体
/// （缺中文字形），而 STATIC 画中文时系统做字体链接换成中文字体——两把尺，
/// 末尾的汉字（如 "0/29 已完成" 的"成"）就被裁掉。字体族 prop 记着但 HFONT
/// 没换，是最容易假绿的那类 bug，所以判据只读 face 名。
test "原生后端：只钉字族不钉字号，face 名也真的换（CJK 裁字根因）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App(b)
  let title = "MoonUI 原生 字族无字号"
  let win = app.create_window(title, @moonui.LogicalSize(280.0, 160.0))
  let label = @moonui.Widget::label(b, "0/29 已完成")
  win.set_content(@moonui.Widget::column(b, 12.0, [label]))
  // 只给 font_family，不给 font_size——与 demo 的 unified_style 同形
  let _ = label.set_style(Some(@moonui.style(font_family=Some("Arial"))))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let (cx, cy) = scaffold_center(label.frame(), dpi)
  let t = @utf8.encode(title)
  let probe = c_font_family_probe(t, t.length(), cx, cy)
  assert_eq(probe & 0xFFL, 1L) // family prop 记着
  assert_eq((probe >> 8) & 0xFFL, 1L) // HFONT face 名也换成了 Arial
  b.destroy_window(win.handle())
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// **`T313`：一个窗口里只有一种字，而且就是系统 UI 字体。**
///
/// owner 2026-11-18 截图问"为什么一个界面上有各种各样的字体"。查下来不是应用
/// 给了几种字：**没下发过字号的控件根本没有字**——`WM_GETFONT` 是空的，Win32
/// 就按类默认字体（`DEFAULT_GUI_FONT`，本机实测是宋体）画；而下发过字号的控件
/// 用的是消息字体（中文 Win11 = Microsoft YaHei UI）。于是同一屏上侧栏三个
/// 页签是宋体、其余是雅黑，量宽与画字还不是同一只字。
///
/// 判据读的是**控件自己那只字**（`WM_GETFONT` 的 face 名），不是应用下发的
/// 样式——样式里本来什么都没有，读它永远是绿的。四段：
/// ① 扫到了至少三只文字控件（防"一只都没扫到"的假绿）；
/// ② 全窗只有**一种** face 名（含"没字体"这个特殊名）；
/// ③ 自绘面选的字族**能扛 CJK**——这条三端都成立（GDI+ 的 DrawString 不做
///    字体回退，选错族就是豆腐块）；
/// ④ **消息字体自己扛得住 CJK 时**，自绘面还得与它同族——"一屏一种字"的
///    字面意思。英文 Windows 的消息字体是 Segoe UI（纯拉丁），这时画布只能
///    退雅黑，两半本来就不可能同族：④的前提不成立，按不约束处理。
///
/// ④ 这么写是因为先把"同族"当成无条件契约，本机（中文 Windows）绿、runner
/// （英文 Windows Server）红（run `44258328850`，两条 `0 != 1`）——红的是
/// 判据，不是产品。
/// 负控制：给其中一只显式钉 `Arial`，②必须变成 2——证明这个"数"真的在数。
test "原生后端：一个窗口里只有一种字，且与自绘面同族（T313）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App(b)
  let title = "MoonUI 原生 一种字"
  let win = app.create_window(title, @moonui.LogicalSize(320.0, 200.0))
  // 三只控件三种"下发情况"：给了字号 / 什么都不给 / 菜单行（侧栏那种）
  let sized = @moonui.Widget::label(b, "标题").font_size(14.0)
  let bare = @moonui.Widget::label(b, "共 0 首")
  let row = @moonui.Widget::menu_row(b, "我的音乐", true)
  win.set_content(@moonui.Widget::column(b, 12.0, [sized, bare, row]))
  // 不 show()：这条判据读的是"控件自己挂的那只字"，不需要真上屏；而且屏幕
  // 像素类的判据（滚动残影那两条）读的是 `GetDC(0)`，多一只窗就多一层遮挡，
  // 这里少一次上屏就少一份干扰。
  let _ = app.step()
  let t = @utf8.encode(title)
  let probe = c_single_font_probe(t, t.length())
  assert_eq((probe >> 56) & 0xFFL, 0L) // 找到了窗口
  assert_true((probe & 0xFFL) >= 3L) // 三只文字控件都数到了
  assert_eq((probe >> 8) & 0xFFL, 1L) // 全窗一种 face 名
  assert_eq((probe >> 24) & 1L, 1L) // 画布那族扛得住 CJK
  // ④：消息字体扛 CJK → 必须同族（英文系统上这条不约束，见上面的注释）
  assert_true(((probe >> 16) & 1L) == 1L || ((probe >> 25) & 1L) == 0L)
  // 负控制：钉一只 Arial → 族数变 2（"数"有区分力），画布那条不受影响
  let _ = bare.set_style(Some(@moonui.style(font_family=Some("Arial"))))
  let _ = app.step()
  let probe2 = c_single_font_probe(t, t.length())
  assert_eq((probe2 >> 8) & 0xFFL, 2L)
  assert_eq((probe2 >> 24) & 1L, 1L)
  b.destroy_window(win.handle())
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
#borrow(title, name)
extern "c" fn c_font_switch_probe(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
  name : Bytes,
  name_len : Int32,
) -> Int64 = "moonui_native_font_switch_probe"

///|
/// **`T314`：应用层一条 `set_font_family`，控件与自绘面一起换、也能一起切回来。**
///
/// owner 2026-11-18：「统一字体这个我想要是框架内部解决，应用层支持切换字体的
/// api 就行」。框架内部那半是 `T313`（缺省就是系统 UI 字体）；这条判据管的是
/// 应用层那一条 API——它得同时改到两条不同的账：原生控件的 HFONT（per-widget
/// 的 family prop）与自绘面（进程级的画布字族覆盖，`DrawList::text` 不带字族）。
///
/// 形状是 `0 -> 1 -> 0`：默认（跟随系统）时两半都不是 `Arial`；切过去两半都是；
/// 传 `None` 两半都回到系统字。只测前半段会留下"切得过去、切不回来"——那正是
/// `NativeBackend` 旧实现在 `None` 上省掉 FFI 的后果。负控制天然在这一串里：
/// 任何一半没跟着动，对应的那一段就停在 0 或 1，`0 -> 1 -> 0` 立刻断链。
test "原生后端：应用级切换字体，控件与自绘面一起换（T314）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App(b)
  let title = "MoonUI 原生 切换字体"
  let win = app.create_window(title, @moonui.LogicalSize(300.0, 160.0))
  let label = @moonui.Widget::label(b, "Ab")
  win.set_content(@moonui.Widget::column(b, 12.0, [label]))
  // 不 show()：这条判据读的是控件挂的那只字与画布字族，不需要真上屏；少一次
  // 上屏就少一层对"读屏幕像素"那几条判据（滚动残影）的干扰，同 `T313`。
  let _ = app.step()
  let t = @utf8.encode(title)
  let arial = @utf8.encode("Arial")
  let probe = fn() -> Int64 raise @moonui.UiError {
    let dpi = @native-common.native_window_dpi(win.handle())
    let (cx, cy) = scaffold_center(label.frame(), dpi)
    c_font_switch_probe(t, t.length(), cx, cy, arial, arial.length())
  }
  // ① 默认：跟随系统，两半都不是 Arial
  let before = probe()
  assert_eq((before >> 16) & 1L, 1L) // 找到窗口
  assert_eq((before >> 17) & 1L, 1L) // 找到控件
  assert_eq(before & 1L, 0L) // 自绘面不是 Arial
  assert_eq((before >> 8) & 1L, 0L) // 控件不是 Arial
  // ② 应用层切到 Arial——一个控件样式都不动
  let _ = app.set_font_family(Some("Arial"))
  let _ = app.step()
  let after = probe()
  assert_eq(after & 1L, 1L) // 自绘面换过去了
  assert_eq((after >> 8) & 1L, 1L) // 控件也换过去了
  // ③ 传 None 切回系统默认：两半都得回来
  let _ = app.set_font_family(None)
  let _ = app.step()
  let back = probe()
  assert_eq(back & 1L, 0L) // 自绘面回到系统族
  assert_eq((back >> 8) & 1L, 0L) // 控件的 HFONT 也真是系统字（不是留着旧族）
  // 整窗仍只有一种字，且画布那族扛得住 CJK——切换不破坏 `T313` 的口径。
  // 「画布与消息字体同族」不在这儿再断言一次：它是 `T313` 位 16/25 那对
  // 条件（英文 Windows 上消息字体是 Segoe UI，画布必须退雅黑），不是切换
  // 字体这条要守的性质。
  let single = c_single_font_probe(t, t.length())
  assert_eq((single >> 8) & 0xFFL, 1L)
  assert_eq((single >> 24) & 1L, 1L)
  b.destroy_window(win.handle())
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T115`①：按钮的平面底在 Windows 上真画出来。
///
/// 这条的**前身是一条假绿**：改之前 `background` 照样记在属性表上、`style`
/// 读回来一模一样，但画出来的始终是 comctl32 的主题脸——读 prop 的判据从头
/// 到尾看不见这件事。所以判据只能是像素：让按钮把**它自己那份画法**离屏重画
/// 一遍（WM_PRINTCLIENT，与 WM_PAINT 共用同一个绘制函数），数"正好是下发
/// 底色"的像素占多少。
///
/// 三段都是负控制：① 有底色 → 覆盖率高、直角四角也是面色；② 圆角 → 左上角
/// 被切掉；③ 撤掉底色 → 覆盖率归零（退回系统脸，本探针一次都不填）。
test "原生后端：按钮的平面底真画出来，像素覆盖率对账（T115①）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App(b)
  let title = "MoonUI 原生 平面钮"
  let win = app.create_window(title, @moonui.LogicalSize(280.0, 160.0))
  let btn = @moonui.Widget::button(b, "确定")
  win.set_content(@moonui.Widget::column(b, 12.0, [btn]))
  // 一块扎眼的面色：主题脸是浅灰，出任何偏差都数得出来。
  let face = @moonui.Color::rgb(0x33, 0x66, 0xCC)
  let _ = btn.set_style(Some(@moonui.style(background=Some(face))))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let (cx, cy) = scaffold_center(btn.frame(), dpi)
  // ① 直角：脸铺满，四角也在
  let flat = button_probe(title, cx, cy)
  assert_eq((flat >> 56) & 0xFFL, 0L)
  // 覆盖率是主判据：平面钮的脸占绝大部分；主题脸（改之前的样子）这里是 0。
  assert_true(((flat >> 40) & 0xFFL) > 60L)
  // 直角钮：左上角**是**面色
  assert_eq((flat >> 48) & 1L, 0L)
  // ② 圆角：左上角被切掉
  let _ = btn.set_style(
    Some(@moonui.style(background=Some(face), radius=Some(8.0))),
  )
  let _ = app.step()
  let round = button_probe(title, cx, cy)
  assert_eq((round >> 56) & 0xFFL, 0L)
  assert_eq((round >> 48) & 1L, 1L)
  // ③ 撤掉底色：退回系统脸，覆盖率归零（同样一句"平面钮才填这段"的负控制）
  let _ = btn.set_style(Some(@moonui.style(radius=Some(0.0))))
  let _ = app.step()
  let gone = button_probe(title, cx, cy)
  assert_eq((gone >> 56) & 0xFFL, 0L)
  assert_eq((gone >> 40) & 0xFFL, 0L)
  // 负控制：坐标处没有按钮（按钮在列首、只占固有高，窗底那块是空白）/
  // 窗口不存在
  assert_eq(
    (button_probe(title, cx, scaffold_px(150.0, dpi)) >> 56) & 0xFFL,
    2L,
  )
  assert_eq((button_probe("没有这只窗口", 4, 4) >> 56) & 0xFFL, 1L)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// `T115`① 的第二半：**禁用态**与点击回流。
///
/// 为什么挑禁用态而不是悬停：四态里禁用是唯一完全由 Core 侧驱动的（`set_enabled`
/// → `IsWindowEnabled`），确定性最好。悬停那一态只能靠真光标——它的沿是
/// `TrackMouseEvent` + `WM_MOUSELEAVE`，而脚手架投的是合成鼠标消息、物理
/// 光标不在钮上，系统当场就把 leave 发回来了（真跑咬出：投一条 WM_MOUSEMOVE
/// 之后读回的画态仍是 0）。合成消息驱动不了它，这一态归人工过一眼截图，
/// 不在这里假装钉住。
///
/// 同时复钉一件事：换成子类过程之后**点击照样回流**（BN_CLICKED 走的是系统
/// 按钮自己的路，被我们换掉的只有绘制那几条消息）。这条比"没坏"更重要
/// 的理由是——`T115` 原本的打算是整只钮改 `BS_OWNERDRAW`，那条路会把
/// `BN_CLICKED` 的产生位置整个挪走；改走子类化之后，这条断言就是那个选择的
/// 保险丝。
test "原生后端：平面钮的禁用态真换脸，点击照样回流（T115①）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App(b)
  let title = "MoonUI 原生 平面钮禁用"
  let win = app.create_window(title, @moonui.LogicalSize(280.0, 160.0))
  let btn = @moonui.Widget::button(b, "禁用")
  let clicks : Array[Unit] = []
  let _ = btn.with_on_click(fn() { clicks.push(()) })
  win.set_content(@moonui.Widget::column(b, 12.0, [btn]))
  let _ = btn.set_style(
    Some(
      @moonui.style(
        background=Some(@moonui.Color::rgb(0x33, 0x66, 0xCC)),
        radius=Some(6.0),
      ),
    ),
  )
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let (cx, cy) = scaffold_center(btn.frame(), dpi)
  // 基线：正常态，脸就是下发的那份底色
  let live = button_probe(title, cx, cy)
  assert_eq((live >> 50) & 0xFL, 0L)
  assert_true(((live >> 40) & 0xFFL) > 60L)
  // 禁用：画态翻到 3，脸往中性灰偏——覆盖率（正好是下发底色的像素）归零
  btn.set_enabled(false)
  let off = button_probe(title, cx, cy)
  assert_eq((off >> 50) & 0xFL, 3L)
  assert_eq((off >> 40) & 0xFFL, 0L)
  // 放开：回到正常态、脸回到原色
  btn.set_enabled(true)
  let back = button_probe(title, cx, cy)
  assert_eq((back >> 50) & 0xFL, 0L)
  assert_true(((back >> 40) & 0xFFL) > 60L)
  // 点击回流：换过程之后 BN_CLICKED 仍到 Core
  assert_eq(click_button_in_window(title, cx, cy), 0)
  assert_true(app.step())
  assert_eq(clicks.length(), 1)
  scaffold_drain(app)
  assert_eq(clicks.length(), 1)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
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
  // 新范围真的落到了原生轨道上（`T137`）：把值往外推两次，让**轨道自己**按
  // 新上限/新下限夹回来。范围没换手的话这两下会读回 100 / 0，判据当场红。
  b.set_widget_value(slider, 4000)
  assert_eq(b.widget_value(slider), 40)
  b.set_widget_value(slider, -4000)
  assert_eq(b.widget_value(slider), 10)
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
  let app = @moonui.App(b)
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
/// 就无从谈起）。注释里的数字是 `MenuBar()` 按整棵树深度优先重排出来的 id，
/// 也就是原生侧看到的那个数（WM_COMMAND 的 wParam）：
///   File：Quit(0, Meta+q)、Sidebar(1, 勾选框)、分隔线、Zoom{ Small(2, radio), Large(3, radio) }
///   Edit：Copy(4, Ctrl+c)、Sync(5, 勾选框且禁用)
fn menu_fixture() -> @moonui.MenuBar {
  let quit = @moonui.MenuItem("Quit")
  quit.set_shortcut(@moonui.Shortcut::meta("q"))
  let sidebar = @moonui.MenuItem::checkbox("Sidebar")
  let small = @moonui.MenuItem::radio("Small")
  let large = @moonui.MenuItem::radio("Large")
  let copy = @moonui.MenuItem("Copy")
  copy.set_shortcut(@moonui.Shortcut::ctrl("c"))
  let sync = @moonui.MenuItem::checkbox("Sync")
  sync.set_enabled(false)
  @moonui.MenuBar([
    @moonui.Menu("File", [
      Item(quit),
      Item(sidebar),
      Separator,
      Submenu("Zoom", [Item(small), Item(large)]),
    ]),
    @moonui.Menu("Edit", [Item(copy), Item(sync)]),
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
    @moonui.MenuBar([@moonui.Menu("Edit", [Item(@moonui.MenuItem("Copy"))])]),
  )
  assert_eq(@native-common.native_menu_dump(), "Edit{#0:n.e:Copy:.}")
  assert_eq(@native-common.native_menu_click_item(1), -1)
  // 空的一棵 = 拆掉，窗口照旧活着
  b.set_menu_bar(@moonui.MenuBar([]))
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
  let app = @moonui.App(b)
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
  b.set_menu_bar(@moonui.MenuBar([]))
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
#borrow(title)
extern "c" fn c_immersive_probe(title : Bytes, title_len : Int32) -> Int64 = "moonui_native_immersive_probe"

///|
fn immersive_probe(title : String) -> Int64 {
  let t = @utf8.encode(title)
  c_immersive_probe(t, t.length())
}

///|
/// 沉浸式标题栏（`T116`）：Windows 上摘掉系统标题栏与系统菜单条，客户区铺满
/// 整窗，自绘顶条就是标题栏。三件事一起钉：
///
/// ① 切沉浸式之后，`WS_CAPTION` 不在风格位上、窗口不挂菜单条、客户区与外框
///    是**同一块矩形**。第三条是关键——只摘风格位不接 `WM_NCCALCSIZE` 的话，
///    系统还按旧账切掉一圈，客户区就比外框小，像素上看就是"顶条被咬了"。
/// ② 尺寸设定在外框恒等之后**不再长大**：连设三次同一个尺寸，读回还是那个
///    数。这一条钉的是 `moonui_native_outer_size` 的恒等短路——少了它，
///    `AdjustWindowRectEx` 每次把 `WS_THICKFRAME` 的边框加回去，三次之后窗
///    就胖了一圈（lunamusic 上表现为"点了三次复位窗口，窗越来越胖"）。
/// ③ 切回 `Standard` 之后三样全回来：风格位、菜单条、非客户区那一圈。
///
/// 菜单条那一半不另设：切沉浸式时窗口已经挂着一棵，正好验"摘掉"，切回时
/// 验"按存下来的树重建"。
test "原生后端：沉浸式标题栏摘净系统标题栏与菜单条，切回标准态全回来（T116）" {
  let b = open_backend()
  b.init()
  let title = "MoonUI 原生 沉浸式标题栏"
  let win = b.create_window(title, @moonui.LogicalSize(320.0, 240.0))
  b.show_window(win)
  b.set_menu_bar(menu_fixture())
  // 标准态：风格位在、菜单条在、客户区比外框小（有系统标题栏那一条）
  let before = immersive_probe(title)
  assert_eq(before & 1L, 1L)
  assert_eq(before & 2L, 2L)
  assert_eq(before & 4L, 0L)
  // 切沉浸式
  b.set_window_titlebar_style(win, @moonui.TitlebarStyle::Immersive)
  let after = immersive_probe(title)
  assert_eq(after & 1L, 0L)
  assert_eq(after & 2L, 0L)
  assert_eq(after & 4L, 4L)
  // 摘干净之后，"点一下窗口"不该在客户区顶上留下东西（`T124`）：位 5 是
  // 真屏面像素在激活切换前后的差分，系统还把非客户区画在我们客户区上时才置位。
  assert_eq(after & 32L, 0L)
  // 尺寸幂等：外框恒等之后连设三次都不长大
  for i = 0; i < 3; i = i + 1 {
    b.set_window_size(win, @moonui.LogicalSize(320.0, 240.0))
  }
  let size = b.window_size(win)
  assert_true(close_to(size.width, 320.0))
  assert_true(close_to(size.height, 240.0))
  assert_eq(immersive_probe(title) & 4L, 4L)
  // 切回标准态：三样全回来
  b.set_window_titlebar_style(win, @moonui.TitlebarStyle::Standard)
  let back = immersive_probe(title)
  assert_eq(back & 1L, 1L)
  assert_eq(back & 2L, 2L)
  assert_eq(back & 4L, 0L)
  b.set_menu_bar(@moonui.MenuBar([]))
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 自绘顶条的拖动带（`T116`）：Core 只知道顶条多高（每只窗不一样），原生层
/// 据此在 `WM_NCHITTEST` 里报 `HTCAPTION`——窗才拖得动。
///
/// 这里钉三件：①按逻辑像素送进来、按该窗缩放换算成物理像素存下（100% 屏上
/// 两者相等，高 DPI 屏上比值就是 scale——所以断言拿 scale 算，不写死数值）；
/// ②同一个值重设幂等；③0 与负数都归 0（没有拖动带），不许留下负数让"点落在
/// 带里"那个判据永远不成立。
test "原生后端：拖动带按逻辑像素换算后往返，负值归零（T116）" {
  let b = open_backend()
  b.init()
  let win = b.create_window(
    "MoonUI 原生 拖动带",
    @moonui.LogicalSize(320.0, 240.0),
  )
  assert_eq(@native-common.native_window_drag_band(win), 0)
  b.set_window_drag_band(win, 30.0)
  let scale = b.window_scale(win)
  let got = @native-common.native_window_drag_band(win)
  assert_true(close_to(got.to_double(), 30.0 * scale.y))
  // 幂等：同一个值再送一次，读回还是那个数
  b.set_window_drag_band(win, 30.0)
  assert_eq(@native-common.native_window_drag_band(win), got)
  // 0 与负数都是"没有拖动带"
  b.set_window_drag_band(win, 0.0)
  assert_eq(@native-common.native_window_drag_band(win), 0)
  b.set_window_drag_band(win, -12.0)
  assert_eq(@native-common.native_window_drag_band(win), 0)
  b.destroy_window(win)
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
/// 异步替按的进度记录（`T306`）：右键菜单 / 自动关对话框 / 文件面板三处替按
/// 共用一只记录。`kind` 说明最近一次武装的是哪一处，位表示它走到哪一步——
/// 位值定义在 `adapter_native.c` 的 `MOONUI_ARM_*`，这里只按名字取掩码，不
/// 自己算位（两边各写一份位名表，写歪了反而误导）。
extern "c" fn c_arm_kind() -> Int32 = "moonui_native_arm_kind_state"

///|
extern "c" fn c_arm_has(mask : Int32) -> Int32 = "moonui_native_arm_has"

///|
extern "c" fn c_arm_wait(wait_ms : Int32) -> Int32 = "moonui_native_arm_wait"

///|
extern "c" fn c_arm_text() -> Bytes = "moonui_native_arm_text"

///|
let arm_target : Int32 = 2

///|
let arm_acted : Int32 = 16

///|
let arm_done : Int32 = 64

///|
let arm_fallback : Int32 = 256

///|
let arm_kind_menu : Int32 = 1

///|
let arm_kind_dialog : Int32 = 2

///|
let arm_kind_file : Int32 = 3

///|
/// 判据等替按的预算（`T310`）：**必须 ≥ 替按自己的预算**，否则 `abort` 会抢在
/// 替按写 `DONE` 之前触发，读到的永远是中间态——「菜单没弹」「弹得比判据慢」
/// 「点了没回流」三种原因又混成同一句话，而且替按线程还活着、下一拍可能点到
/// 下一只窗上去。三处替按的预算都在 C 侧写死：
/// - 菜单：武装延迟 `ms` + `MOONUI_MENU_PICK_TIMEOUT`（5000）
/// - 对话框 / 文件面板：延迟 `ms` + `MOONUI_DISMISS_LOOK_MS`（4000）
///
/// 判据里给的 `ms` 都是几百毫秒级，6000 覆盖三者的上界。C 侧那两个常量若调大，
/// 这里要跟着调——两者是「判据的耐心」与「被等者的预算」的对账关系。
let arm_budget_ms : Int32 = 6000

///|
fn arm_text() -> String {
  @utf8.decode(c_arm_text()) catch {
    _ => "<进度串解码失败>"
  }
}

///|
/// 一处替按的收尾判据（`T306`）：必须停在 `kind` 上，`need` 的位都在、`forbid`
/// 的位都不在。红了就把 C 侧拼好的可读串打出来——「目标窗没出现」「拿到了却
/// 没按下去」「靠兜底关的窗」三种原因因此分得开，不必复跑去猜。`forbid` 里最
/// 常用的是 FALLBACK：判据本来是绿的、其实是兜底把它救绿的，那条主路径坏了
/// 也看不出来。
fn assert_arm(kind : Int32, need : Array[Int32], forbid : Array[Int32]) -> Unit {
  let _ = c_arm_wait(arm_budget_ms)
  let k = c_arm_kind()
  if k != kind {
    abort(
      "替按没落到预期的那一处：kind=\{k}，期望 \{kind}；进度 \{arm_text()}",
    )
  }
  for m in need {
    if c_arm_has(m) == 0 {
      abort("替按少了必经的一步：进度 \{arm_text()}")
    }
  }
  for m in forbid {
    if c_arm_has(m) != 0 {
      abort(
        "替按是靠兜底收的场，主路径没成：进度 \{arm_text()}",
      )
    }
  }
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
/// 每一发弹出的同时核一次替按进度（`T306`）：找到对话框 → 真按下去 → 收工，
/// 且**不是**靠兜底关窗收的场——判据绿而主路径坏的那种情况才藏得住。
test "原生后端：消息框与确认框真弹原生面板，答案是按钮给的" {
  let b = open_backend()
  b.init()
  // 消息框：300 毫秒之后替用户按下那唯一一只"确定"
  let t0 = @native-common.native_time_ms()
  assert_eq(@native-common.native_auto_dismiss_dialog(300, 0), 0)
  b.show_message("MoonUI 的消息框", "正文")
  let blocked = @native-common.native_time_ms() - t0
  assert_true(blocked >= 250)
  // `T306`：这一发真走到了「找到对话框 → 按下去 → 收工」，不是靠兜底关的窗
  assert_arm(arm_kind_dialog, [arm_target, arm_acted, arm_done], [arm_fallback])
  // 确认框：先按"是"（IDYES），再按"否"（IDNO）
  assert_eq(@native-common.native_auto_dismiss_dialog(300, 0), 0)
  assert_true(b.confirm("MoonUI 的确认框", "要继续吗？"))
  assert_arm(arm_kind_dialog, [arm_target, arm_acted, arm_done], [arm_fallback])
  assert_eq(@native-common.native_auto_dismiss_dialog(300, 1), 0)
  assert_false(b.confirm("MoonUI 的确认框", "要继续吗？"))
  assert_arm(arm_kind_dialog, [arm_target, arm_acted, arm_done], [arm_fallback])
  // 越界的 index 在"装"的那一步就报回来，不许留到运行时什么也按不下
  assert_eq(@native-common.native_auto_dismiss_dialog(10, 2), -1)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
#borrow(p)
extern "c" fn c_long_path(p : Bytes, len : Int32) -> Bytes = "moonui_native_long_path"

///|
/// 路径归一化脚手架（`T302`）：把 8.3 短名展开成长名，走的是适配器处理面板
/// 结果时用的同一个函数。期望值必须过这一步——hosted runner 的用户目录是
/// `C:\Users\RUNNER~1\...`，而 `@moonui.Fs::temp_dir()` 读的是环境变量原值，
/// 不归一化就是「面板回长名、期望是短名」。展开失败原样返回（C 侧同时保证
/// 不返回空串）。
fn long_path(s : String) -> String {
  let b = @utf8.encode(s)
  let r = c_long_path(b, b.length())
  if r.length() == 0 {
    return s
  }
  @utf8.decode(r) catch {
    _ => s
  }
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
/// 每一发布局都核一次替按进度（`T306`）：找到面板窗 → 真按下去 → 收工，且
/// 不是靠强制关窗兜底收的场。
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
  // `T306`：找到面板窗 → 导航到装好的路径 → 真按下去 → 收工（靠兜底关窗会报出来）
  assert_arm(arm_kind_file, [arm_target, arm_acted, arm_done], [arm_fallback])
  // 保存文件：目标文件不必存在——保存面板给的是"打算写到哪"。路径必须落在
  // 当前用户的可写临时目录：钉死 C:\Windows\Temp 会撞系统的权限确认弹窗
  // （"你没有权限在此位置中保存文件"），测试就只能靠人手关窗才能继续。
  let save_path = @moonui.Fs::temp_dir() + "moonui-t77-save-probe.txt"
  let t1 = @native-common.native_time_ms()
  assert_eq(
    @native-common.native_auto_answer_file_dialog(2000, save_path, true),
    0,
  )
  // 期望侧同过一遍长名归一化（`T302`）：面板结果由适配器展开，而
  // Fs::temp_dir() 读的是 TEMP 原值，runner 上它就是 C:\Users\RUNNER~1\...
  // 上面两条用 C:\Windows 下的固定路径，任何宿主都不会是 8.3 短名，故不归一化。
  assert_eq(
    b.save_file("MoonUI 的保存", "moonui-t77-save-probe.txt"),
    Some(long_path(save_path)),
  )
  assert_true(@native-common.native_time_ms() - t1 >= 250)
  assert_arm(arm_kind_file, [arm_target, arm_acted, arm_done], [arm_fallback])
  // 选文件夹
  let t2 = @native-common.native_time_ms()
  assert_eq(
    @native-common.native_auto_answer_file_dialog(2000, "C:\\Windows", true),
    0,
  )
  assert_eq(b.select_folder("MoonUI 的文件夹"), Some("C:\\Windows"))
  assert_true(@native-common.native_time_ms() - t2 >= 250)
  assert_arm(arm_kind_file, [arm_target, arm_acted, arm_done], [arm_fallback])
  // 取消
  assert_eq(@native-common.native_auto_answer_file_dialog(2000, "", false), 0)
  assert_eq(b.open_file("MoonUI 的打开"), None)
  // 取消走的是 WM_CLOSE 那条主路径，同样不许落到兜底
  assert_arm(arm_kind_file, [arm_target, arm_acted, arm_done], [arm_fallback])
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
/// 按标题问一只窗口的图标装没装上：位 0 = 窗口自己的 WM_SETICON 图标，位 1 =
/// 窗口类图标（`T316` 起两份账分开读，探针在 C 侧比对 HICON 原值，不是"非空
/// 就算"）。
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
  // 推路收口：活着的窗口收到 WM_SETICON，类图标也一起换了（位 0 + 位 1）。
  // 位 1 是 `T316` 补的：系统的兜底顺序是 WM_GETICON → 类图标 → exe 图标，
  // 类图标此前钉在 IDI_APPLICATION，一被兜底就是那只通用白窗口（任务栏上看
  // 不到应用图标）。两份账都断言，别让"只做了窗口那条"混过去。
  assert_eq(window_icon_installed("MoonUI 原生 图标推路"), 3)
  // 建窗补挂路：图标已装，新建的窗口自己挂上（两条账同样是两份）
  let win2 = b.create_window(
    "MoonUI 原生 图标补挂",
    @moonui.LogicalSize(200.0, 120.0),
  )
  b.show_window(win2)
  assert_eq(window_icon_installed("MoonUI 原生 图标补挂"), 3)
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
/// 把逻辑坐标换成**后端回传口径**：先按 DPI 落到整物理像素（脚手架投递时
/// 就走这一步），再按同一比例除回逻辑坐标（事件里给的点就是这个数）。
///
/// `T111` 的捕获判据要用它比坐标：按钮高 25（奇数）时中心落在半格上，
/// `120.5` 在像素网格里不存在，后端只能回整数。旧版按钮高 24、中心正好整格，
/// 所以那条断言一直是绿的——一旦版面动一格就红在"半像素"上，与捕获路由无关。
fn scaffold_round_trip(
  p : @moonui.LogicalPoint,
  dpi : Int32,
) -> @moonui.LogicalPoint {
  let scale = dpi.to_double() / 96.0
  @moonui.LogicalPoint(
    scaffold_px(p.x, dpi).to_double() / scale,
    scaffold_px(p.y, dpi).to_double() / scale,
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
/// 自绘面合成之后显示出来的色（`T311`，Windows 专属脚手架，见 adapter.h）：
/// 离屏铺一张洋红哨兵再让这块面 `WM_PRINTCLIENT` 重画一遍，读回那一点。
#borrow(title)
extern "c" fn c_custom_under_probe(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int64 = "moonui_native_custom_under_probe"

///|
fn custom_under_probe(title : String, x : Int32, y : Int32) -> Int64 {
  let t = @utf8.encode(title)
  c_custom_under_probe(t, t.length(), x, y)
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
  let app = @moonui.App(b)
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
/// 自绘面的透明处必须补上底下那块底色（`T311`）。
///
/// 现场：歌词秀那块面（360×120）里透出的是**背后窗口的一张快照**，拖窗口也不
/// 变。根因不在画布——`paint_lyrics` 只画文字，帧的其余部分 alpha=0 是对的；
/// `AlphaBlend` 对 alpha=0 的源像素不动目标，而这块矩形下头没有人补底：同父的
/// Panel 带 `WS_CLIPSIBLINGS` 画不到兄弟压着的那一格，顶层窗又是沉浸式的
/// （`WM_ERASEBKGND` 回 1、客户区从不落笔）。于是它停着"窗口第一次盖住屏幕时
/// 的那块像素"。
///
/// 判据用一对探针把两层分开（见 adapter.h）：
/// - `custom_probe` 读画布帧 ⇒ 全透明（0），证明补底不是靠往画布里填色换来的；
/// - `custom_under_probe` 读合成结果 ⇒ 底下那块 Panel 的底色。
/// 只有这一对同时成立，"面显示对了、画布语义没被改"才是被证过的。面里一笔都
/// 不画是最坏情形，也是歌词秀空闲时的真实形状。
test "原生后端：自绘面的透明处补底下那块底色（T311）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App(b)
  let title = "MoonUI 原生 自绘面补底"
  let win = app.create_window(title, @moonui.LogicalSize(320.0, 240.0))
  let face = @moonui.Widget::custom(b, @moonui.LogicalSize(160.0, 80.0), fn(
    dl,
    env,
  ) {
    // 一笔不画：帧整块透明
    let _ = dl
    let _ = env
  })
  let panel = @moonui.Widget::panel(
    b,
    @moonui.Widget::padding(b, @moonui.EdgeInsets::all(20.0), face),
  )
  let _ = panel.set_style(
    Some(@moonui.style(background=Some(@moonui.Color::rgb(0x33, 0x66, 0xCC)))),
  )
  win.set_content(panel)
  win.show()
  let _ = app.step()
  scaffold_drain(app)
  let dpi = @native-common.native_window_dpi(win.handle())
  let (cx, cy) = scaffold_center(face.frame(), dpi)
  // ① 画布帧仍然整块透明：契约一字没动，补底发生在合成那一层
  assert_eq(custom_probe(title, cx, cy), 0L)
  // ② 合成之后这块面显示的是底下 Panel 的色（不是哨兵洋红，也不是原来的黑）
  assert_eq(custom_under_probe(title, cx, cy), 0x3366CCL)
  // ③ 负控制：面的外面（Panel 的 padding 区）不是自绘面
  assert_eq(
    custom_under_probe(title, scaffold_px(5.0, dpi), scaffold_px(5.0, dpi)),
    -2L,
  )
  // ④ 负控制：没有这只窗
  assert_eq(custom_under_probe("MoonUI 原生 没有这只窗", 4, 4), -1L)
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
  let app = @moonui.App(b)
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
  let app = @moonui.App(b)
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
  let bf_center = @moonui.LogicalPoint(
    bf.origin.x + bf.size.width / 2.0,
    bf.origin.y + bf.size.height / 2.0,
  )
  // 坐标要按"后端回传口径"比：脚手架按 DPI 落整到物理像素投出去，事件里的
  // 点是除回逻辑坐标的那个整数。按钮高 25（`T313` 起量宽量高都按消息字体，
  // 比宋体高 1）时中心落在半格上，`120.5` 这个位置在像素网格里不存在——旧
  // 版按钮高 24、中心正好整格，这条断言才一直是绿的。
  let over_btn = scaffold_round_trip(bf_center, dpi)
  let face_events : Array[@moonui.Event] = []
  let _ = app.on_event(face.target(), fn(ev) {
    match ev {
      @moonui.MouseMove(_, _) | @moonui.MouseUp(_, @moonui.Left, _, _) =>
        face_events.push(ev)
      _ => ()
    }
  })
  let btn_events : Array[@moonui.Event] = []
  let _ = app.on_event(btn.target(), fn(ev) {
    match ev {
      @moonui.MouseMove(_, _) | @moonui.MouseUp(_, @moonui.Left, _, _) =>
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
    @moonui.MouseUp(face.target(), @moonui.Left, over_btn, @moonui.Mods::none()),
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
  let app = @moonui.App(b)
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
  let app = @moonui.App(b)
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
  let app = @moonui.App(b)
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
  let app = @moonui.App(b)
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
  let app = @moonui.App(b)
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
  let app = @moonui.App(b)
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
  let app = @moonui.App(b)
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
  let app = @moonui.App(b)
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
  let app = @moonui.App(b)
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
    @moonui.Menu("MoonUI", [
      Item(@moonui.MenuItem("显示")),
      Separator,
      Item(@moonui.MenuItem("退出")),
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
/// 替按进度位（`T304`）的读回口：等这一轮收尾或超时，返回最终进度位。位序
/// 与 `adapter_native.c` 的 `MOONUI_MENU_PICK_*` 一致：1 已武装 / 2 找到菜单
/// 窗 / 4 拿到菜单 / 8 量到项矩形 / 16 已投递点击 / 64 已收尾。`clicked` 是
/// 模态循环消化消息时填的、进度位是替按线程置的，两者先后不保证，所以断言
/// 「点到了」得先等收尾。
extern "c" fn c_menu_pick_wait(wait_ms : Int32) -> Int32 = "moonui_native_menu_pick_wait"

///|
/// 带显式找窗窗口的武装入口，只给负控制用（默认那条的窗口是 5 秒）。
extern "c" fn c_auto_pick_context_menu_within(
  ms : Int32,
  index : Int32,
  timeout_ms : Int32,
) -> Int32 = "moonui_native_auto_pick_context_menu_within"

///|
/// 「只认新出现的菜单窗」这条判定（`T305`）的判据出口：两个包好的句柄表，
/// 每句柄 4 位、低位在前，返回第一个新窗在 `now` 里的下标，没有给 -1。真实
/// 替按用的是同一个 C 函数（`moonui_menu_pick_first_new`），这里换的只是把
/// 句柄塞进去的方式。
extern "c" fn c_menu_pick_new_index(
  base_packed : Int32,
  base_n : Int32,
  now_packed : Int32,
  now_n : Int32,
) -> Int32 = "moonui_native_menu_pick_new_index"

///|
/// 把 0..15 的假句柄按 4 位一格压成一个 Int32（低位在前），与 C 侧的拆法对称。
fn pack_handles(handles : Array[Int32]) -> Int32 {
  let mut packed = 0
  for i, h in handles {
    packed = packed | (h << (4 * i))
  }
  packed
}

///|
/// 替按的「残窗不算新菜单」是一条纯逻辑，不必非等真菜单才验得到（留一只
/// `#32768` 残窗挂在进程里在真窗测试里没法确定性构造——那是系统菜单类，应用
/// 注册不出来）。四种形态各钉一格：只剩残窗、残窗 + 新窗、无残窗、残窗换了
/// 但都不是新的。
test "原生后端：替按只认新出现的菜单窗（T305 纯逻辑判据）" {
  // 武装时已有 1、2，现在还是这两只：没有新窗，必须 -1（原实现会拿 1 当中选）
  assert_eq(
    c_menu_pick_new_index(pack_handles([1, 2]), 2, pack_handles([1, 2]), 2),
    -1,
  )
  // 残窗 1、2 还在，第三只 3 是新弹的：下标 2
  assert_eq(
    c_menu_pick_new_index(pack_handles([1, 2]), 2, pack_handles([1, 2, 3]), 3),
    2,
  )
  // 武装时一只都没有：第一只就是新的，下标 0
  assert_eq(c_menu_pick_new_index(0, 0, pack_handles([7]), 1), 0)
  // 残窗已经走了、又只剩别的旧窗：仍然不算「新菜单」
  assert_eq(
    c_menu_pick_new_index(pack_handles([4, 5]), 2, pack_handles([5, 4]), 2),
    -1,
  )
}

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
  // 负控制（`T304`）：本用例内还没有任何菜单弹过，替按必然等不到菜单窗——
  // 进度位必须停在「已武装 + 已收尾」（1+64=65），而不是让 clicked 空着让人
  // 去猜。找窗窗口压到 300ms，不必陪它空等满 5 秒；这处等待只需 ≥ 300ms
  // （预算 = `ms(0)` + 300），2000 已有余量，不必跟着 `arm_budget_ms` 走。
  assert_eq(c_auto_pick_context_menu_within(0, 1, 300), 0)
  assert_eq(c_menu_pick_wait(2000), 65)
  let app = @moonui.App(b)
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
      @moonui.MouseDown(t, @moonui.Right, p, _) =>
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
  let first = @moonui.MenuItem("一")
  let second = @moonui.MenuItem("二")
  let clicked : Array[Int32] = []
  let _ = second.on(fn(_) { clicked.push(second.id) })
  label.set_context_menu(@moonui.Menu("Menu", [Item(first), Item(second)]))
  // 收集右键事件——回调在 Modal loop 里读窗口态（③ 的重入判据）
  let reenter_ok : Array[Bool] = []
  let _ = label.on(fn(ev) { ev is @moonui.MouseDown(_, @moonui.Right, _, _) }, fn(
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
  // 替按走到哪一步必须自己说得清（`T304`）：clicked 为空时先打出进度位，
  // 不让「菜单没弹」「量不到项矩形」「点到了没生效」挤成同一句 `[] != [1]`。
  // 等满替按自己的预算（`T310`）：这里的 `ms=100` + 找窗窗口 5000 = 5100ms，
  // 原来只等 2000ms，`run 44087201257` 上就撞进中间态、报出 `kind=menu
  // bits=armed`（武装了但一个目标位都没亮），把「弹得慢」误判成「没弹」。
  let _ = c_menu_pick_wait(arm_budget_ms)
  if clicked.length() == 0 {
    abort("替按没选到第 2 项，进度：\{arm_text()}")
  }
  // 选中走 MenuItem 自己的回调同步解析，不经事件队列
  assert_eq(clicked, [second.id])
  assert_eq(reenter_ok, [true])
  // 正面路径也要自证：进度位得走到「已投递点击 + 已收尾」，且确实是菜单那一处
  assert_arm(arm_kind_menu, [arm_acted, arm_done], [])
  // 收干净之后再弹一次：菜单本身在 set_context_menu 之外也可以直接弹
  // （菜单栏判据那批已有同形覆盖，这里只验上下文菜单这条的重复可用性）
  let ctx2 : Array[Int32] = []
  assert_eq(c_auto_pick_context_menu(100, 0), 0)
  @native-common.native_show_context_menu(
    @moonui.MenuBar([@moonui.Menu("M", [Item(first), Item(second)])]),
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
  let app = @moonui.App(b)
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
  let app = @moonui.App(b)
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

///|
/// T89② 落点判据的真窗口半条（mac 半同形的镜像，见 native-macos 的同名测试）：
/// 真窗动画走真钟（前台门同款两行接线——时刻从 native_time_ms 来；激活沿把
/// poll_event 的等待预算换成 8ms 档），逐帧驱动是真时间自旋、天然计时易碎，
/// 所以**不做中间帧断言**——step 轮询到落点：每圈 step 后读 `widget_bounds`，
/// 直到稳定或超时，用差分口径断言（bounds 的落点 delta == Core frame 的落点
/// delta，逐位）。触发走**纯平移档**（spacer 收缩 → label 只挪 origin、尺寸
/// 不动）——宽度/文本档在 mac 半被咬过（width 不进测量账、文本度量归后端），
/// Windows 同一条判据用同一格：origin 是 Core 全权拥有的那格几何。
/// 偏好开着（系统 reduced-motion）动画当圈退场：轮询第一圈就收敛、帧钟从未
/// 激活——两种系统态都在判据内（本机实测时偏好是关，走 wake 两沿分支）。
test "原生后端：真窗 Resize 的动画 step 轮询到落点，widget_bounds 逐位读回" {
  let b = open_backend_for_testing(300)
  b.init()
  let app = @moonui.App(b)
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
  // 先 show 再触发：动画推的是看得见的窗口（SetWindowPos 对隐藏窗同样收，
  // 但真跑形状与 mac 对齐）。
  win.show()
  // 初始收敛态（差分基线）：`native_widget_origin` 报父客户区坐标（ScreenToClient
  // 后的那套，与 set_bounds 同空间）——Core 的 frame 同为父客户区原点，但取整
  // 路径（GetWindowRect 物理值 / scale 乘除）可能带 ±1 结构差，差分口径把它
  // 消掉。收敛判读 = 连续两次读回相等。
  let mut stable = false
  let mut before = @moonui.Backend::widget_bounds(b, h)
  // `T221`：本文件这三处等待预算统一改成**已耗时**口径（`now - t0 < 2000`），
  // 不再写 `deadline = native_time_ms() + 2000` 再比绝对值——`native_time_ms` 是
  // int64 开机毫秒截成 Int32（`backends/native-common/ffi.mbt`，Windows 侧那把钟
  // 是 GetTickCount64），开机满 2^31 毫秒（≈24.85 天）那一圈读数本身变负，绝对
  // deadline 正好压在回绕点上时 `now < deadline` 恒假，等待窗口被读成 0，失败方向
  // 是**当场假红**（不是挂住）。差值口径跨回绕不受影响；阈值 2000 毫秒一个字没动。
  let settle_t0 = @native-common.native_time_ms()
  while !stable {
    let _ = app.step()
    let now = @moonui.Backend::widget_bounds(b, h)
    if now == before {
      stable = true
    } else {
      before = now
    }
    if @native-common.native_time_ms() - settle_t0 >= 2000 {
      break
    }
  }
  let bounds_before = before
  let frame_before = label.frame()
  // 触发变更：spacer 收缩 → label 从右缘往左挪（纯平移，尺寸不动）。
  let _ = sp.with_expand(false)
  // step 轮询到落点（T89② 形状）：先 step 后读，收敛判读"稳定两读 **且 wake
  // 退休"——只看两读相等会在起跑圈假收敛（起跑圈零推送、头两步读数天然相等，
  // mac 半的 dump 诊断在案）；reduced 档当圈退场推精确 to、wake 恒空，读数
  // 动一次即到。
  // `T221`：等待预算改成已耗时口径（理由见本文件上面 settle_t0 那段注），阈值不动。
  let land_t0 = @native-common.native_time_ms()
  let mut landed = false
  let mut now = @moonui.Backend::widget_bounds(b, h)
  while !landed {
    let _ = app.step()
    let next = @moonui.Backend::widget_bounds(b, h)
    landed = next == now && (reduced || wake.length() >= 2)
    if next == now {
      // 读数相等但沿未到齐：继续 step 等（不更新基线）
    } else {
      now = next
    }
    if @native-common.native_time_ms() - land_t0 >= 2000 {
      break
    }
  }
  let bounds_after = now
  let frame_after = label.frame()
  // 差分断言：bounds 的落点 delta == Core frame 的落点 delta（逐位）。
  // 超时也红在这里，失败消息带两侧 delta。
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
  // 落点真的挪了（spacer 收缩，label 往左挪——origin 实移）：钉住"轮询收敛
  // 在变更之后"，不是初始态碰巧相等。
  assert_true(label.frame().origin.x < frame_before.origin.x)
  if reduced {
    // 帧钟从未激活：偏好开着动画当圈退场，预算一次都不换（零开销）
    assert_eq(wake, [])
  } else {
    // 等退场沿（真钟 300ms 档 + 余量）。恰好 [true, false] 两条切换沿 =
    // 预算换过一次、恢复过一次——退场后帧钟恢复零开销。
    // `T221`：已耗时口径，见本文件上面 settle_t0 那段注。
    let wake_t0 = @native-common.native_time_ms()
    while wake.length() < 2 && @native-common.native_time_ms() - wake_t0 < 2000 {
      let _ = app.step()
    }
    assert_eq(wake, [true, false])
  }
  // 收尾：窗口拆掉，句柄表清零。
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
#borrow(title)
extern "c" fn c_paint_probe_begin(title : Bytes, title_len : Int32) -> Int32 = "moonui_native_paint_probe_begin"

///|
#borrow(title)
extern "c" fn c_paint_probe_report(title : Bytes, title_len : Int32) -> Int64 = "moonui_native_paint_probe_report"

///|
#borrow(title)
extern "c" fn c_paint_probe_end(title : Bytes, title_len : Int32) -> Unit = "moonui_native_paint_probe_end"

///|
#borrow(title)
extern "c" fn c_paint_probe_validate(title : Bytes, title_len : Int32) -> Int32 = "moonui_native_paint_probe_validate"

///|
/// 给窗口的每只后代装一只只数 `WM_PAINT` 的子类过程，返回登记了几只。装表要放
/// 在 `show` **之前**：要数的正是"显示这一下有没有把整棵子树排进待画队列"。
fn paint_probe_begin(title : String) -> Int32 {
  let t = @utf8.encode(title)
  c_paint_probe_begin(t, t.length())
}

///|
/// `(total, painted, limbo)`：后代总数 / 装表之后真收到过 `WM_PAINT` 的只数 /
/// 既没画过、此刻也没有非空失效区的只数。limbo 是 `T121` 的症状。
fn paint_probe_report(title : String) -> (Int32, Int32, Int32) {
  let t = @utf8.encode(title)
  let packed = c_paint_probe_report(t, t.length())
  (
    (packed & 0xFFFFL).to_int(),
    ((packed >> 16) & 0xFFFFL).to_int(),
    ((packed >> 32) & 0xFFFFL).to_int(),
  )
}

///|
fn paint_probe_end(title : String) -> Unit {
  let t = @utf8.encode(title)
  c_paint_probe_end(t, t.length())
}

///|
/// 把登记过的后代的待画队列抹平（`ValidateRect`）：模拟"控件在 park 里或上一轮
/// 显示期已经真画过一次"的状态——它以为自己不欠画了。返回抹平了几只。
fn paint_probe_validate(title : String) -> Int32 {
  let t = @utf8.encode(title)
  c_paint_probe_validate(t, t.length())
}

///|
/// 显示之后每只后代都欠一次重画，不许有 limbo（`T121`）。
///
/// 应用侧的真实顺序是 `Window::set_content` 早于 `show`（见
/// examples/lunamusic/app.mbt 的建窗段）：控件搬进一只**藏着**的窗口时，attach
/// 打的那次失效不会变成 `WM_PAINT`。"显示这一下由谁负责把整棵子树排进待画
/// 队列"因此必须由我们显式承担（`window_show` 里的
/// `RedrawWindow(... RDW_ALLCHILDREN)`），不能指望系统顺手补。
///
/// 判据：先把整棵子树的待画队列抹平（`paint_probe_validate`，等价于"每只都
/// 已经画过"），再 `show`。此后
///   - `show` 一返回：limbo 必须是 0（每只都被重新排进待画队列）；
///   - 泵一批消息之后：每只都真收到过 `WM_PAINT`，且一只 limbo 都不剩。
/// **这条判据不锁那句 `RedrawWindow`**：2026-10-26 的负控制量过，把这句停掉
/// 它照样全绿——这台 Win32 的 `ShowWindow` 自己就会把整棵子树排进队列。它锁的
/// 是用户看得见的那条性质（"显示完不许有既不画也不排队的控件"）；换成哪个
/// 平台、哪版系统不再替我们兜时，它会红。
/// 树照播放列表窗的形状：Panel（kind 17）收编一行控件、滚动视口（kind 15）里再
/// 放一只——只走视口那条 attach 路径的控件在这里也数一遍。
test "原生后端：显示后每只后代都欠一次重画，不留 limbo（T121）" {
  let title = "MoonUI 原生 重画探针"
  let b = open_backend_for_testing(5)
  b.init()
  let win = b.create_window(title, @moonui.LogicalSize(360.0, 260.0))
  let panel = b.create_widget(@moonui.Panel, "")
  let strip = b.create_widget(@moonui.Label, "顶条")
  let tab = b.create_widget(@moonui.Label, "页签")
  let btn = b.create_widget(@moonui.Button, "清空")
  let scroll = b.create_widget(@moonui.Scroll, "")
  let row = b.create_widget(@moonui.Label, "滚动里的行")
  b.attach_widget(win, panel)
  b.set_widget_style(
    panel,
    @moonui.style(background=Some(@moonui.Color::rgb(0x1F, 0x44, 0x68))),
  )
  b.set_widget_bounds(
    panel,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(360.0, 260.0),
    ),
  )
  b.attach_widget_to(panel, strip)
  b.set_widget_bounds(
    strip,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(360.0, 24.0),
    ),
  )
  b.attach_widget_to(panel, tab)
  b.set_widget_bounds(
    tab,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(8.0, 30.0),
      @moonui.LogicalSize(80.0, 24.0),
    ),
  )
  b.attach_widget_to(panel, btn)
  b.set_widget_bounds(
    btn,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(120.0, 30.0),
      @moonui.LogicalSize(80.0, 24.0),
    ),
  )
  b.attach_widget_to(panel, scroll)
  b.set_widget_bounds(
    scroll,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(8.0, 64.0),
      @moonui.LogicalSize(340.0, 180.0),
    ),
  )
  b.attach_widget_to(scroll, row)
  b.set_widget_bounds(
    row,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(4.0, 4.0),
      @moonui.LogicalSize(200.0, 20.0),
    ),
  )
  // 六只后代：panel、顶条、页签、按钮、视口、视口里的行。Panel 的子树在
  // Windows 半是平铺挂到窗口名下的（kind 17），但仍是这只窗口的后代。
  assert_eq(paint_probe_begin(title), 6)
  // 起手先把待画队列抹平：每只都当成"已经画过"，只剩 `show` 这一下能救。
  assert_eq(paint_probe_validate(title), 6)
  b.show_window(win)
  let (total, painted_at_show, limbo_at_show) = paint_probe_report(title)
  assert_eq(total, 6)
  assert_eq(limbo_at_show, 0)
  // 泵：`WM_PAINT` 在队里等，poll_event 每条分派一条（预算 5ms，这里几十条够了）。
  for _ in 0..<60 {
    let _ = b.poll_event()
  }
  let (total_after, painted, limbo) = paint_probe_report(title)
  assert_eq(total_after, total)
  assert_true(painted >= painted_at_show)
  assert_eq(painted, total)
  assert_eq(limbo, 0)
  paint_probe_end(title)
  b.destroy_widget(row)
  b.destroy_widget(scroll)
  b.destroy_widget(btn)
  b.destroy_widget(tab)
  b.destroy_widget(strip)
  b.destroy_widget(panel)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
#borrow(path)
extern "c" fn c_test_wmkdir(path : Bytes) -> Int32 = "_wmkdir"

///|
#borrow(path)
extern "c" fn c_test_wrmdir(path : Bytes) -> Int32 = "_wrmdir"

///|
/// CRT 宽字符 API 要 NUL 结尾的 UTF-16：@utf16 编完补两字节零。
/// T278：`Bytes::add` **不原地改**，返回的是新 buffer（本机实测 "abc" 编码后
/// enc.length()=6，enc.add(两个零).length()=8）。原先写 `let _ = enc.add(...); enc`
/// 等于把补的那两字节丢掉，CRT 一路读到堆上相邻内存——路径随机多出乱码后缀
/// （实测建出了 `moonui-t202-夜曲库 ਰ`），T202 的 _wmkdir / _wrmdir / 写 tmp
/// 就随机报红，且失败点漂移。恒用 add 的返回值，与全仓另六处补 NUL 同形状。
fn utf16z(s : String) -> Bytes {
  @utf16.encode(s, bom=false, endianness=Little).add(Bytes::make(2, 0))
}

///|
/// T278：把「NUL 收尾」钉成确定性判据，不靠真窗跑运气。缺收尾时
/// utf16z("abc") 只有 6 字节，第一条就红，不必等 CRT 读到脏内存。
test "Win32 宽字符路径恒带 NUL 收尾（T278）" {
  let z = utf16z("abc")
  assert_eq(z.length(), 8)
  assert_eq(z[6], b'\x00')
  assert_eq(z[7], b'\x00')
  let cjk = utf16z("夜曲库")
  assert_eq(cjk.length(), 8)
  assert_eq(cjk[6], b'\x00')
  assert_eq(cjk[7], b'\x00')
}

///|
/// T202 的真窗判据：Windows 半的 `moonui_native_walk_dir` 不再是空包。契约
/// （adapter.h 行走段）与 mac 半 readdir 同一条：只列**直接**子项、上报
/// **绝对路径**、文件与子目录都给；递归策略与排序在 MoonBit 侧的 `Fs::walk`。
/// 树搭在系统临时目录下（仓库里不留东西），目录名带中文——非 ASCII 正是这条
/// 空桩欠的第二道坎。注意路径里的 `\` 一律 `"\\\" + "..."` 拼接，不写
/// `"\中文"`：moonc 对反斜杠转义紧邻多字节字符的字面量会 ICE（Char.chr，
/// 2026-11-06 实测），拼接形状绕开它。
test "原生后端：目录行走列直接子项，非 ASCII 路径照收（T202）" {
  let sep = "\\"
  let root = @moonui.Fs::temp_dir() + "moonui-t202-夜曲库"
  let sub = root + sep + "子目录"
  // 预清场：上一轮红在半路（比如负控制）时树会留在盘上，_wmkdir 撞已存在
  // 返回 -1 会把"残留"误报成"建树失败"。只删本测试自己种的那几样，结果不管。
  let _ = @moonui.Fs::remove(root + sep + "夜曲.mp3")
  let _ = @moonui.Fs::remove(root + sep + "蓝色狂想曲.flac")
  let _ = @moonui.Fs::remove(sub + sep + "小星星.wav")
  let _ = c_test_wrmdir(utf16z(sub))
  let _ = c_test_wrmdir(utf16z(root))
  assert_eq(c_test_wmkdir(utf16z(root)), 0)
  assert_eq(c_test_wmkdir(utf16z(sub)), 0)
  let _ = @moonui.Fs::write_text_atomic(root + sep + "夜曲.mp3", "x")
  let _ = @moonui.Fs::write_text_atomic(
    root + sep + "蓝色狂想曲.flac",
    "x",
  )
  let _ = @moonui.Fs::write_text_atomic(sub + sep + "小星星.wav", "x")
  // 直接子项：两个文件 + 一个子目录，全是绝对路径、前缀 root+\、逐项对上
  let kids = @native-common.native_walk_dir(root)
  let expected : Array[String] = [
    root + sep + "夜曲.mp3",
    root + sep + "蓝色狂想曲.flac",
    sub,
  ]
  assert_eq(kids.length(), 3)
  for e in expected {
    assert_true(kids.contains(e))
  }
  // 子目录那一层照走：嵌套由 MoonBit 侧递归，C 只管一层
  assert_eq(@native-common.native_walk_dir(sub), [sub + sep + "小星星.wav"])
  // 打不开的目录恒空（不闪退、不报裸名——T142 的旧病）
  assert_eq(@native-common.native_walk_dir(root + sep + "没有这只目录"), [])
  // 清场：文件走 Fs::remove，目录用 _wrmdir（空的才删得掉）
  let _ = @moonui.Fs::remove(root + sep + "夜曲.mp3")
  let _ = @moonui.Fs::remove(root + sep + "蓝色狂想曲.flac")
  let _ = @moonui.Fs::remove(sub + sep + "小星星.wav")
  assert_eq(c_test_wrmdir(utf16z(sub)), 0)
  assert_eq(c_test_wrmdir(utf16z(root)), 0)
}

///|
/// T220 的真窗判据（探针是分平台的测试脚手架，声明只在测试文件）：占位提示
/// 在 Windows 半由 EDIT 的子类过程自己画（`T317` 起；此前是系统
/// `EM_SETCUEBANNER`），四格——占位真画出来（WM_PRINTCLIENT 离屏重画数异色
/// 像素，与空字段基线比）、ES_PASSWORD（kind 4）上画不画、聚焦后画不画、
/// 聚焦态下换文案 / 撤文案是否当场生效。
/// 本机（125% DPI，comctl6）实测读数：空字段基线 0，挂「搜索标题 / 歌手」约
/// 2500 个异色像素（自绘那条按同一只字画，比系统 cue 的 600 明显更多——系统
/// cue 那 600 是抗锯齿更薄的一份），清成空串回 0；密码框挂「密码」同样一大片
/// （**画**，所以 C 侧 kind 门保持 2|4 不收窄）；聚焦后不塌。
/// 负控制（把 C 侧绘制那一步短路 → 判据红）见 TODO `T317` 完成记录。
#borrow(title)
extern "c" fn c_edit_probe(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int64 = "moonui_native_edit_probe"

///|
fn edit_probe(title : String, x : Int32, y : Int32) -> Int64 {
  let t = @utf8.encode(title)
  c_edit_probe(t, t.length(), x, y)
}

///|
test "原生后端：占位提示真画出来，密码框与聚焦态同账（T220）" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App(b)
  let title = "MoonUI 原生 占位提示"
  let win = app.create_window(title, @moonui.LogicalSize(320.0, 160.0))
  let input = @moonui.Widget::text_input(b, "")
  let pwd = @moonui.Widget::password_input(b, "")
  win.set_content(@moonui.Widget::column(b, 12.0, [input, pwd]))
  win.show()
  let _ = app.step()
  let dpi = @native-common.native_window_dpi(win.handle())
  let cue = "搜索标题 / 歌手"
  // ① TextInput：先量空字段基线，挂提示后异色像素必须多出一大片（灰字 +
  // 抗锯齿圈至少几十像素，阈值 20 把"什么都没画"和"画了字"分开）
  let (ix, iy) = scaffold_center(input.frame(), dpi)
  let base = edit_probe(title, ix, iy)
  assert_true(base == 0)
  let _ = input.with_placeholder(cue)
  let _ = app.step()
  let with_cue = edit_probe(title, ix, iy)
  assert_true(with_cue >= base + 20)
  // 清掉：空串即清（撤 prop，下一帧不再落笔）
  let _ = input.with_placeholder("")
  let _ = app.step()
  assert_true(edit_probe(title, ix, iy) <= base + 5)
  // ② PasswordInput：占位同样要画（kind 4 也过 C 侧的 kind 门）
  let (px, py) = scaffold_center(pwd.frame(), dpi)
  let pbase = edit_probe(title, px, py)
  assert_true(pbase == 0)
  let _ = pwd.with_placeholder("密码")
  let _ = app.step()
  let pwith = edit_probe(title, px, py)
  assert_true(pwith >= pbase + 20)
  let _ = pwd.with_placeholder("")
  let _ = app.step()
  // ③ 有焦点也画（`T317`：占位改成自己画之后与焦点态无关，这一格把"点进去
  // 就没了"钉死）：聚焦 TextInput 后再读，像素不塌回基线
  assert_eq(focus_widget_in_window(title, ix, iy), 0)
  scaffold_drain(app)
  let _ = input.with_placeholder(cue)
  let _ = app.step()
  let focused_cue = edit_probe(title, ix, iy)
  assert_true(focused_cue >= base + 20)
  // 聚焦态下换文案 / 撤文案也要当场生效（旧实现走系统 cue，撤文案靠"空文案顶
  // 掉"，聚焦态那条路没人验过；这里是同一条账的另一半）
  let _ = input.with_placeholder("")
  let _ = app.step()
  assert_true(edit_probe(title, ix, iy) <= base + 5)
  let _ = input.with_placeholder(cue)
  let _ = app.step()
  assert_true(edit_probe(title, ix, iy) >= base + 20)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// T150 的 Windows 半（判据刻意弱一档）：拖到哪个千分位，自绘圆点圆心就压在
/// "指针能到的圆心"底下。探针与画法同读 TBM_GETTHUMBRECT / TBM_GETCHANNELRECT
/// （拿控件的账核控件自己），这份只钉"映射没有退回旧的 W·t"——真指针那份
/// 强的在 mac（AppKit 跟踪循环）。
/// 本机（125% DPI）实测：41 个点逐位 |err| 最大 100（=1pt，出在 pm=25），两端
/// 0、中点 100——那是轨道条摆拇指时对通道余量的整像素取整，不是映射的系统性
/// 漂；容差留到 500（5pt）是给换 DPI 档的余量，旧映射（W·t）在两端差半个拇指
/// 宽（≈16pt），扫一遍必红。
test "原生后端：拖到哪圆点跟到哪，逐千分位扫（T150 Windows 半）" {
  let b = open_backend_for_testing(100)
  b.init()
  let win = b.create_window(
    "MoonUI 圆点跟手 win",
    @moonui.LogicalSize(420.0, 120.0),
  )
  let slider = b.create_ranged_widget(@moonui.Slider, 0, 1000)
  b.attach_widget(win, slider)
  // 与 Luna 的进度条同宽（368 逻辑点）：旧画法的差在这条宽度上最大
  b.set_widget_bounds(
    slider,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 30.0),
      @moonui.LogicalSize(368.0, 22.0),
    ),
  )
  b.show_window(win)
  // 单位百分之一点：500 = 5pt。旧映射（W·t）在两端差半个拇指宽，扫一遍必红
  for pm = 0; pm <= 1000; pm = pm + 25 {
    let err = @native-common.native_slider_knob_probe(slider, pm)
    assert_eq(
      if err <= 500 && err >= -500 {
        "ok"
      } else {
        "pm=\{pm} err=\{err}"
      },
      "ok",
    )
  }
  // 负控制的形状：中点两把尺本来就重合，单独钉一次。实测容差 1px（读数
  // 100 = 1pt）：轨道条自己摆拇指时对通道余量取整，与本探针的线性模型
  // 在半像素上可以差一格，钉的形状是"没有系统性的漂"而不是"逐位相等"。
  let mid = @native-common.native_slider_knob_probe(slider, 500)
  assert_eq(if mid <= 150 && mid >= -150 { "ok" } else { "mid=\{mid}" }, "ok")
  b.destroy_window(win)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
#borrow(title)
extern "c" fn c_slider_drag(
  title : Bytes,
  title_len : Int32,
  kind_button : Int32,
  x : Int32,
  y : Int32,
) -> Int64 = "moonui_native_slider_drag_in_window"

///|
/// 拖动三件套（SendMessage 当场递进，见 C 侧说明）：0=按下、8=抬起、16=移动、
/// 24=按下（在拇指上，返回拇指圆心 x）。
fn slider_drag(title : String, kb : Int32, x : Int32, y : Int32) -> Int64 {
  let t = @utf8.encode(title)
  c_slider_drag(t, t.length(), kb, x, y)
}

///|
/// T148/T149 的 Windows 半：拖动**进行中**changed 就逐条回流、值就跟着走，
/// 不等抬起。轨道条不跑模态循环——SetCapture 之后逐条 WM_MOUSEMOVE，位置每
/// 变一次发一条 WM_HSCROLL（TB_THUMBTRACK）给父窗口，`moonui_native_dispatch`
/// 当场报 changed。按下与移动走 SendMessage 当场递进（按下要落在拇指上才
/// 进拖动态，见 C 侧 kind 3 的说明），拖到一半的读数与事件数就是"拖动中"的账。
test "原生后端：拖动中 changed 实时回流，读数与值同步走（T148/T149 Windows 半）" {
  let b = open_backend_for_testing(200)
  b.init()
  let title = "MoonUI 拖动实时"
  let win = b.create_window(title, @moonui.LogicalSize(420.0, 120.0))
  let slider = b.create_ranged_widget(@moonui.Slider, 0, 1000)
  b.attach_widget(win, slider)
  b.set_widget_bounds(
    slider,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 30.0),
      @moonui.LogicalSize(368.0, 22.0),
    ),
  )
  b.show_window(win)
  let mut changes = 0
  @native-common.native_slider_on_changed(slider, fn() { changes = changes + 1 })
  // kind_button 编码：kind*8+button——0=按下、8=抬起、16=按住移动、24=按住拇指
  // 坐标是物理客户区（ChildWindowFromPoint 收的那套）：逻辑点按窗口 DPI 乘
  // 上去——本机 125%，写死逻辑 24 会落在轨道左缘外一格（T148 真跑咬出）。
  let dpi = @native-common.native_window_dpi(win)
  let rb = b.widget_bounds(slider)
  let y = scaffold_px(41.0, dpi)
  // 扫整条通道：12 个点把滑块宽（逻辑 20..388）十三等分，落点都在条内。
  // 旧版从 204 起步、每步 24 逻辑点，第 8 步就出了右缘——后半段只剩
  // 饱和前的最后一次真移动，"逐条回流"只核到一条。
  let lx = fn(i : Int32) -> Double { 20.0 + 368.0 * i.to_double() / 13.0 }
  let x_at = fn(i : Int32) -> Int32 { scaffold_px(lx(i), dpi) }
  let rb_ok = rb.contains(@moonui.LogicalPoint(lx(1), 41.0)) &&
    rb.contains(@moonui.LogicalPoint(lx(12), 41.0))
  assert_eq(
    if rb_ok {
      "ok"
    } else {
      "rb x=\{rb.origin.x} y=\{rb.origin.y} w=\{rb.size.width} h=\{rb.size.height}"
    },
    "ok",
  )
  // 拖动三件套用"按住"那条（send_mouse_in_window 的按下是按下+抬起一对，
  // 造不出拖动）：按下必须落在**拇指上**（comctl 对离拇指的按下走"翻页"，
  // 不进拖动态——真机排障实测：点中段每下只进一页 200/1000，读数于是卡在
  // [200,350] 那条阶梯上），所以按下走 kind 3，让 C 侧自己去按拇指圆心。
  // 移动/抬起给窗客户区物理坐标（逻辑点按窗口 DPI 乘上去，本机 125%）。
  // kind 3 的坐标只是"用哪只窗定位"的落点，给轨道条中部即可。
  let thumb_x = slider_drag(title, 24, x_at(1), y)
  assert_eq(if thumb_x > 0 { "ok" } else { "thumb=\{thumb_x}" }, "ok")
  // 逐条核对两笔账：值跟着指针走（与该点在线性映射上的位置差 ≤100 千分位，
  // 也就是 ±13 逻辑点——翻页的 200 那一档必红，退回旧的 W·t 也在两端超），
  // 且每条移动恰好回流一条 changed（TB_THUMBTRACK 一条不落、也不重）。
  for i = 1; i <= 6; i = i + 1 {
    assert_eq(slider_drag(title, 16, x_at(i), y), 0)
    let v = b.widget_value(slider)
    let want = 1000 * i / 13
    let d = if v > want { v - want } else { want - v }
    assert_eq(if d <= 100 { "ok" } else { "i=\{i} v=\{v} want=\{want}" }, "ok")
    assert_eq(changes, i)
  }
  // 拖到一半：changed 已经来了一串，值已经离开 0（实时，不等抬起）
  let mid_changes = changes
  let mid_value = b.widget_value(slider)
  assert_eq(mid_changes, 6)
  assert_true(mid_value > 0 && mid_value < 1000)
  for i = 7; i <= 12; i = i + 1 {
    assert_eq(slider_drag(title, 16, x_at(i), y), 0)
    let v = b.widget_value(slider)
    let want = 1000 * i / 13
    let d = if v > want { v - want } else { want - v }
    assert_eq(if d <= 100 { "ok" } else { "i=\{i} v=\{v} want=\{want}" }, "ok")
    assert_eq(changes, i)
  }
  // 后半段同样逐条来（连续拖动 = 逐条通知，不是只有抬起那一条）
  assert_true(changes > mid_changes)
  assert_true(b.widget_value(slider) > mid_value)
  assert_eq(slider_drag(title, 8, x_at(12), y), 0)
  let _ = b.poll_event()
  b.destroy_window(win)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// 判据：**Windows 这侧"文件读不出"是 -2，不是"本平台没接音频"的 -3**
/// （`T38` 错误码那一半的平台侧取证）。
///
/// `T38` 立这条时的原文是反面——Windows 整段音频是 FP4 空桩、必须如实报 -3。
/// `T326` 把 Media Foundation + WASAPI 接进来之后，这一侧的语义与 mac 对齐了，
/// 只剩"平台真的还没有的那几样"（set_rate / prime 家族 / EQ / 频谱）还吐 -3；
/// load / play 这两个最容易踩的入口必须走正常错误码：文件打不开就是 -2，壳才
/// 报 `LoadFailed` 而不是"本平台还没接"。
///
/// 这条不建窗、不 `native_init`：音频栈自带 `wa_ensure()`（MFStartup + 引擎
/// 线程），与 UI 的初始化是两条独立的生命周期。
test "原生后端：音频的 -2 与 -1 分得清，不会被读成本平台没接（T326）" {
  // 没装任何歌时的空转账：位置/时长/seek 都得是 -1（不是 0 假装在第一毫秒）
  assert_eq(@native-common.native_audio_stop(), 0)
  assert_eq(@native-common.native_audio_position_ms(), -1L)
  assert_eq(@native-common.native_audio_duration_ms(), -1L)
  assert_eq(@native-common.native_audio_seek_ms(0L), -1)
  // 不存在的路径：MF 起得来、源解析器打不开 → -2（**不是** -3）
  assert_eq(
    @native-common.native_audio_load(
      "backends/native-windows/fixtures/no_such_t326.wav",
    ),
    -2,
  )
  // 真 wav：装得上，时长 0.5s（8kHz 单声道，夹具见 fixtures/README.md）
  assert_eq(
    @native-common.native_audio_load(
      "backends/native-windows/fixtures/t326_sine.wav",
    ),
    0,
  )
  let dur = @native-common.native_audio_duration_ms()
  assert_true(dur > 300L && dur < 800L)
  // 装载完位置在 0（没有"上一首的位置"漏过来）
  assert_eq(@native-common.native_audio_position_ms(), 0L)
  assert_true(@native-common.native_audio_is_playing() == false)
  // 清场，别把装载态留给后面的测试
  assert_eq(@native-common.native_audio_stop(), 0)
  assert_eq(@native-common.native_audio_duration_ms(), -1L)
}

///|
/// 播放一条龙（`T326`）：load → 停着 seek → play → 位置推进 → 自然播完回调。
/// 走真 WF 解码 + 真 WASAPI 出声，墙钟兜底防挂。
///
/// 与 mac 的 `T166` 一条龙同构，但**前提不同**：出声那一段要求"这台机器有
/// 默认渲染端点"（`GetDefaultAudioEndpoint`）。没有端点时 `wa_open_out` 失败、
/// `play` 回 -4（2026-11-20 起与 -2「文件打不开」分开的一档），而前面的
/// 装载 / 时长 / 停着 seek 三段照旧真跑。CI 的 Windows runner 恒为 -4，所以
/// 出声段在那里按读数跳过；本机有端点，走完整条链。
test "原生后端：装载、停着 seek、播放推进、播完回调（T326）" {
  let b = open_backend_for_testing(50)
  b.init()
  // 必须有一只活窗口：播完回调走 `MOONUI_AUDIO_MSG` 投回窗口线程，没有窗口
  // 就没人泵消息、回调永远不执行（mac 那侧的 T166 是同一条教训）。
  let _ = b.create_window(
    "MoonUI 原生 T326 音频",
    @moonui.LogicalSize(120.0, 80.0),
  )
  let app = @moonui.App(b)
  // 进程级播放器单例：先清场，别吃前面测试残留的装载态
  let _ = @native-common.native_audio_stop()
  assert_eq(
    @native-common.native_audio_load(
      "backends/native-windows/fixtures/t326_sine.wav",
    ),
    0,
  )
  let dur = @native-common.native_audio_duration_ms()
  assert_true(dur > 300L && dur < 800L)
  // 停着 seek：位置账要挪到位但不发声（C-08 行为表：seek 不改播放状态）
  assert_eq(@native-common.native_audio_seek_ms(dur - 100L), 0)
  assert_eq(@native-common.native_audio_position_ms(), dur - 100L)
  assert_true(@native-common.native_audio_is_playing() == false)
  let finished : Array[Bool] = []
  let _ = @native-common.native_audio_on_finished(
    Some(fn() { finished.push(true) }),
  )
  // 出声这一段的前提是"本机有可用输出端点"：`play` 在没有端点的机器上回 -4
  // （`T326` 2026-11-20 补的那一档）。CI 的 Windows runner 恒为 -4——装载 /
  // 时长 / 停着 seek 三段已经真跑过并有区分力，出声段在那台机器上没有断言
  // 对象，所以如实记读数再走，不当失败；有端点的机器（本机）走完整条链。
  let play_rc = @native-common.native_audio_play()
  if play_rc == -4 {
    println(
      "T326 无输出端点（play=-4）：出声段跳过，前四段已验",
    )
    assert_true(@native-common.native_audio_is_playing() == false)
  } else {
    assert_eq(play_rc, 0)
    assert_true(@native-common.native_audio_is_playing())
    // 播完回调投回窗口线程，靠 app.step 泵消息排水；墙钟 5s 兜底
    let t0 = @native-common.native_time_ms()
    let mut pos_max : Int64 = 0L
    while finished.length() == 0 && @native-common.native_time_ms() - t0 < 5000 {
      let _ = app.step()
      let pos = @native-common.native_audio_position_ms()
      if pos > pos_max {
        pos_max = pos
      }
    }
    // 位置真的从 dur-100 起往前推（不是 seek 完原地踏步也没播）
    assert_true(pos_max > dur - 100L)
    assert_eq(finished.length(), 1)
    assert_true(@native-common.native_audio_is_playing() == false)
  }
  // 清场：撤回调、卸载，别把尾巴留给后面的测试
  assert_eq(@native-common.native_audio_on_finished(None), 0)
  assert_eq(@native-common.native_audio_stop(), 0)
  b.terminate()
  assert_eq(@native-common.native_live_handles(), 0)
}

///|
/// 格式档（`T326`）：**源格式与设备混音格式不同**也要能播——44.1kHz 立体声
/// 源交给 48kHz 立体声的共享模式缓冲，靠 `IMFSourceReader` 的
/// `SetCurrentMediaType` 自动插入重采样。这条钉的是"同格式能过"之外的那一半：
/// `wa_open_out` 在源声道数对不上混音声道数时是**如实失败**（不做矩阵混音），
/// 所以这里必须真的换了格式还能装载（有声卡时还要能出声——无声卡的 runner 上
/// `play` 回 -4，按读数跳过那一段）。
test "原生后端：源格式与设备混音格式不同也装得上、放得出（T326）" {
  let _ = @native-common.native_audio_stop()
  assert_eq(
    @native-common.native_audio_load(
      "backends/native-windows/fixtures/t326_stereo.wav",
    ),
    0,
  )
  let dur = @native-common.native_audio_duration_ms()
  assert_true(dur > 300L && dur < 800L)
  // 同第一条判据：出声那一步需要输出端点，没有就回 -4（CI runner 常态）。
  // 本条的"格式"这一半仍然成立——`audio_load` 已经按设备混音格式走通了
  // `SetCurrentMediaType`，装不上就轮不到 -4。
  let play_rc = @native-common.native_audio_play()
  if play_rc == -4 {
    println(
      "T326 格式档：无输出端点（play=-4）：装载与时长已验，出声段跳过",
    )
  } else {
    assert_eq(play_rc, 0)
    assert_true(@native-common.native_audio_is_playing())
    // 真出声是实时钟：忙等位置转正（500ms 墙钟兜底）
    let t0 = @native-common.native_time_ms()
    let mut moved = false
    while !moved && @native-common.native_time_ms() - t0 < 500 {
      if @native-common.native_audio_position_ms() > 0L {
        moved = true
      }
    }
    assert_true(moved)
  }
  assert_eq(@native-common.native_audio_stop(), 0)
  assert_true(@native-common.native_audio_is_playing() == false)
}

///|
/// 真窗批里把 backend 队列排空，顺带数出 Click 的条数：一条都不能多。
/// `T256` Windows 半的判据要用三遍，抽成顶层函数，不引闭包。
fn drain_count_clicks(b : @native-common.NativeBackend) -> Int32 {
  let mut clicks = 0
  let mut left = 8
  let mut done = false
  while left > 0 && !done {
    match b.poll_event() {
      Some(@moonui.Click(_, _)) => clicks = clicks + 1
      Some(_) => ()
      None => done = true
    }
    left = left - 1
  }
  clicks
}

///|
/// `T256` Windows 半的回归闸：共享 `create_widget` 给 Panel 装 Click 源之后，
/// Windows 的 `moonui_native_custom_on_clicked` 必须认 kind 17，否则建控件
/// 这一步当场抛错——2026-11-11 的 CI 就是六条建 Panel 的判据抛错、跳过
/// 收尾，全局句柄表留下 5 个孤儿，后面 33 条以 `native_live_handles()`
/// 收尾的判据连锁红（52 条里 39 红）。这条还要真点一次，钉住"装上了"
/// 不等于"按得响"：`panel_proc` 的 WM_LBUTTONUP 得把 customclick 槽位派出去。
///
/// 诚实边界：本机（mac）只进 `moon check` 的类型闸门，不真跑；这条判据的
/// 真跑证据只能来自 Windows 宿主 / GitHub 的 windows-latest 真窗 job。
test "原生后端：Panel 的单击真回流成 Click（T256 Windows 半）" {
  let b = open_backend_for_testing(200)
  b.init()
  let title = "MoonUI 原生 Panel 单击"
  let win = b.create_window(title, @moonui.LogicalSize(300.0, 200.0))
  // 一只**空** Panel：Windows 半把 Panel 的子树平铺到父窗（孩子是它的兄弟、
  // 不是子窗口），挂了孩子命中就落在孩子身上、顺着父链找不到 kind 17。
  // 只留底板，点中心才真落在 Panel 自己那块窗口上。
  let panel = b.create_widget(@moonui.Panel, "")
  b.attach_widget(win, panel)
  let rect = @moonui.LogicalRect(
    @moonui.LogicalPoint(20.0, 20.0),
    @moonui.LogicalSize(160.0, 80.0),
  )
  b.set_widget_bounds(panel, rect)
  b.show_window(win)
  let dpi = @native-common.native_window_dpi(win)
  let (cx, cy) = scaffold_center(rect, dpi)
  // show 之后不该有 Click：先排空，后面两次计数才有意义。
  assert_eq(drain_count_clicks(b), 0)
  // ① 真点：按下并原地抬起回流一条 Click，归属是 Panel 自己（不是窗口、
  //    也不是别人的槽位）。回调登记若不认 kind 17，根本走不到这一行。
  assert_eq(click_custom_in_window(title, cx, cy), 0)
  assert_eq(drain_count_clicks(b), 1)
  // ② 负控制：Panel 之外的空白不是可点面（报 -4），一条 Click 都不多。
  //    合成点击的回退命中只认"真装过 customclick 槽位"的 kind 17，
  //    纯装饰底板与 Column 容器都不算，旧判据的 -4 不会被吃掉。
  assert_eq(
    click_custom_in_window(
      title,
      scaffold_px(280.0, dpi),
      scaffold_px(180.0, dpi),
    ),
    -4,
  )
  assert_eq(drain_count_clicks(b), 0)
  // ③ 负控制：没有这只窗报 -2。
  assert_eq(click_custom_in_window("MoonUI 原生 没有这只窗", cx, cy), -2)
  b.destroy_widget(panel)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 用户报告（2026-11-16）：todo-native 添加一屏以上的条目后逐个点 x 删除，
/// 删到最后列表仍画着行、点了没反应。判据走**真实 NativeBackend**：Core 删除
/// 之后，C 侧真实控件（HWND）必须一起销毁——mock 的 `live()` 只是句柄表计数，
/// 这里读的是 C 侧 `native_live_handles()`，两者不一致正是幽灵 view 的铁证。
test "原生后端：Todo 超一屏逐行删空，C 侧控件全回收" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App(b)
  let list = @moonui.TodoList::demo(app)
  // 空列表基线：窗口 + 标题 + 输入框 + 添加按钮 + 滚动视口 = 5
  let baseline = @native-common.native_live_handles()
  // 30 行远超 400x300 窗口的一屏，触发滚动路径
  for i = 0; i < 30; i = i + 1 {
    list.add("第 " + i.to_string() + " 项")
  }
  assert_eq(list.item_count(), 30)
  assert_eq(@native-common.native_live_handles(), baseline + 60)
  // 逐行点 x：走事件路径，每起 fire 后让 app 推进一轮（含 flush_layout）
  while list.item_count() > 0 {
    match list.row(0) {
      Some(row) => {
        let kids = row.children()
        let btn = kids[1]
        let _ = btn.fire(@moonui.Click(btn.target(), @moonui.MouseButton::Left))
      }
      None => ()
    }
    let _ = app.step()
  }
  assert_eq(list.item_count(), 0)
  assert_true(list.row(0) is None)
  // 关键：30 行 = 60 个控件，删空后 C 侧活句柄必须回落到添加前的基线。
  // 若高于基线，就是"Core 删了、屏幕还画着"的幽灵行——点它当然没反应。
  assert_eq(@native-common.native_live_handles(), baseline)
  list.window().close()
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
extern "c" fn c_erase_probe_reset() -> Unit = "moonui_native_erase_probe_reset"

///|
extern "c" fn c_erase_probe() -> Int32 = "moonui_native_erase_probe"

///|
/// 删除一行时的"内容闪一下"根因诊断：数删除前后带 erase 的失效次数。
/// demo 的 status / checkbox / x 都是 kind 0/1/3，样式下发走 invalidate(erase=1)
/// ——系统在重画前先用类背景刷擦白整块。删一行触发整树 relayout，几十只控件
/// 同时被带 erase 失效，中间那一帧就是整片空白；输入框(kind 2)走 §32 豁免不
/// 失效，所以截图里只有它和"添加"按钮不闪。修法把这类失效收敛为 erase=0。
test "原生后端：删除一行不触发整窗带 erase 的失效" {
  let b = open_backend_for_testing(200)
  b.init()
  let app = @moonui.App(b)
  let list = @moonui.TodoList::demo(app)
  for i = 0; i < 6; i = i + 1 {
    list.add("第 " + i.to_string() + " 项")
  }
  // 收敛到静止：再没有别的失效来源混进计数
  for _ in 0..<8 {
    let _ = app.step()
  }
  c_erase_probe_reset()
  // 删第 0 行，走真实事件路径
  match list.row(0) {
    Some(row) => {
      let btn = row.children()[1]
      let _ = btn.fire(@moonui.Click(btn.target(), @moonui.MouseButton::Left))
    }
    None => ()
  }
  let _ = app.step()
  // 删除这一轮不应该有任何带 erase 的失效：内容靠子控件自己重画，不该先擦白
  assert_eq(c_erase_probe(), 0)
  list.window().close()
  b.terminate()
}

///|
/// 真滚动（Windows）：kind 15 视口自己承载滚动条 + 后端记账偏移。Core 只给
/// 文档坐标、不存滚动（window.mbt §14），滚动整件事在 C 侧。这条钉三件事：
/// ① `set_scroll_content` 内容超视口 → 纵向滚动条真的开（has_vertical_scroller）；
/// ② 投一颗滚轮 → 视口里的子控件按偏移整体上移（native_widget_origin 的 y 变小），
///    证明"滚的是 view"而不是只把 Scroll 事件报给 Core；
/// ③ 内容缩回一屏内 → 滚动条关闭（不预留轨道，与 mac 半同款）。
test "原生后端：真滚动——滚动条开关、子控件随偏移动、收缩后关条" {
  let b = open_backend_for_testing(200)
  b.init()
  let win = b.create_window(
    "MoonUI 原生 真滚动",
    @moonui.LogicalSize(200.0, 160.0),
  )
  let scroll = b.create_widget(@moonui.Scroll, "")
  // 放两行在文档坐标 y=0 / y=120（视口矩形先给 100 高，远超一屏）
  let row0 = b.create_widget(@moonui.Label, "滚行零")
  let row1 = b.create_widget(@moonui.Label, "滚行一")
  b.attach_widget(win, scroll)
  b.set_widget_bounds(
    scroll,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(160.0, 100.0),
    ),
  )
  b.attach_widget_to(scroll, row0)
  b.set_widget_bounds(
    row0,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(4.0, 0.0),
      @moonui.LogicalSize(100.0, 20.0),
    ),
  )
  b.attach_widget_to(scroll, row1)
  b.set_widget_bounds(
    row1,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(4.0, 120.0),
      @moonui.LogicalSize(100.0, 20.0),
    ),
  )
  // 内容全长 260 > 视口 100 → 纵向滚动条开
  b.set_scroll_content(
    scroll,
    @moonui.Vertical,
    @moonui.LogicalSize(160.0, 260.0),
  )
  assert_eq(@native-common.native_scroll_has_vertical_scroller(scroll), 1)
  let y_before = @native-common.native_widget_origin(row1).1
  // 在视口空白区（右半，避开两行 label）投滚轮往下读。命中视口自己 →
  // WM_MOUSEWHEEL 直达 scroll_proc → scroll_on_bar 平移子控件。
  let sent = send_mouse_in_window(
    "MoonUI 原生 真滚动",
    4 * 8,
    140,
    60,
    0,
    60,
  )
  assert_eq(sent, 0)
  // PostMessage 异步：排空队列让滚动条消息/滚轮落进 scroll_proc
  for _ in 0..<12 {
    let _ = b.poll_event()
  }
  let y_after = @native-common.native_widget_origin(row1).1
  assert_true(y_after < y_before)
  // 滚动位置非零时 Core 重排（删/加行都会触发）：重发同一份文档坐标，
  // 落位仍须落在滚动后的位置——否则每次重排都把内容弹回顶部，正是
  // 用户"删着删着列表错位 / 点了没反应"的观感来源。
  b.set_widget_bounds(
    row1,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(4.0, 120.0),
      @moonui.LogicalSize(100.0, 20.0),
    ),
  )
  let y_after_relayout = @native-common.native_widget_origin(row1).1
  assert_eq(y_after_relayout, y_after)
  // 内容缩回一屏 → 滚动条关（且 offset clamp 回 0，子控件回到文档坐标）
  b.set_scroll_content(
    scroll,
    @moonui.Vertical,
    @moonui.LogicalSize(160.0, 80.0),
  )
  assert_eq(@native-common.native_scroll_has_vertical_scroller(scroll), 0)
  // offset 本身必须归零（不只是子控件位置碰巧对）——避免"位置对、账没平"
  // 的假绿，那会让下一次滚动从错的地方起步。
  assert_eq(scroll_offset_of("MoonUI 原生 真滚动"), 0L)
  let y_reset = @native-common.native_widget_origin(row1).1
  assert_eq(y_reset, y_before)
  b.destroy_widget(row1)
  b.destroy_widget(row0)
  b.destroy_widget(scroll)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
#borrow(title)
extern "c" fn c_scroll_offset_of(title : Bytes, title_len : Int32) -> Int64 = "moonui_native_scroll_offset_of"

///|
/// 视口滚动偏移（pack2：(y << 32) | x）。按窗口标题找视口——测试侧的
/// `NativeHandle` 是 `{id, generation}`，不是裸 HWND，直接传进 C 会读到
/// 不存在的窗口、恒返回 0（2026-11-17 撞到的假绿）。
fn scroll_offset_of(title : String) -> Int64 {
  let t = @utf8.encode(title)
  c_scroll_offset_of(t, t.length())
}

///|
#borrow(title)
extern "c" fn c_scroll_surface_pixel(
  title : Bytes,
  title_len : Int32,
  x : Int32,
  y : Int32,
) -> Int64 = "moonui_native_scroll_surface_pixel"

///|
fn scroll_surface_pixel(title : String, x : Int32, y : Int32) -> Int64 {
  let t = @utf8.encode(title)
  c_scroll_surface_pixel(t, t.length(), x, y)
}

///|
/// 滚动残影判据（用户 2026-11-17 截图）：子控件用 SetWindowPos 平移后，旧位置
/// 的像素必须被视口背景擦掉。视口 kind 15 是 WS_EX_TRANSPARENT 且自己不画
/// （scroll_proc 无 WM_PAINT 落笔），所以平移后必须显式安排一次**带 erase**
/// 的背景重画；否则旧位置的 checkbox / x 永久留在屏幕上。
///
/// 方法：视口里放一块扎眼底色（0x3366CC）的 Panel 铺满上半，窗口真显示后读
/// 视口中心像素 = 面色；向下滚过一整屏，Panel 移出视口，再读同一点必须
/// **不再是面色**（恢复窗口底色）。先让滚动发生、再对比像素，不用猜窗口
/// 底色是什么色。
test "原生后端：滚动后旧位置像素被擦掉，不留残影" {
  let title = "MoonUI 原生 滚动残影"
  let b = open_backend_for_testing(200)
  b.init()
  let win = b.create_window(title, @moonui.LogicalSize(240.0, 200.0))
  let scroll = b.create_widget(@moonui.Scroll, "")
  b.attach_widget(win, scroll)
  b.set_widget_bounds(
    scroll,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(160.0, 100.0),
    ),
  )
  // 铺满视口上半的实色面板（kind 17，挂在 kind 15 下是直属孩子，跟着滚）
  let face = @moonui.Color::rgb(0x33, 0x66, 0xCC)
  let band = b.create_widget(@moonui.Panel, "")
  b.attach_widget_to(scroll, band)
  b.set_widget_bounds(
    band,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(150.0, 90.0),
    ),
  )
  b.set_widget_style(
    band,
    @moonui.style(background=Some(face), radius=Some(0.0)),
  )
  // 第二块放到文档 200 以下，撑出滚动行程；滚到底把第一块推离视口
  let far = b.create_widget(@moonui.Panel, "")
  b.attach_widget_to(scroll, far)
  b.set_widget_bounds(
    far,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 200.0),
      @moonui.LogicalSize(150.0, 20.0),
    ),
  )
  b.set_scroll_content(
    scroll,
    @moonui.Vertical,
    @moonui.LogicalSize(160.0, 400.0),
  )
  b.show_window(win)
  for _ in 0..<12 {
    let _ = b.poll_event()
  }
  let dpi = @native-common.native_window_dpi(win)
  // 视口客户区中心（panel_probe 那套物理坐标换算，原点在视口左上）
  let px = scaffold_px(70.0, dpi)
  let py = scaffold_px(40.0, dpi)
  let before = scroll_surface_pixel(title, px, py)
  assert_eq((before >> 56) & 0xFFL, 0L)
  assert_eq(before & 0xFF_FFFFL, 0x33_66CCL)
  // 滚轮往下滚一整屏：面板从文档 y=0 被推到 y=-100 以上，离开采样点
  let sent = send_mouse_in_window(
    title,
    4 * 8,
    scaffold_px(140.0, dpi),
    60,
    0,
    1000,
  )
  assert_eq(sent, 0)
  for _ in 0..<12 {
    let _ = b.poll_event()
  }
  // 面板确已移开——先钉住"几何上离开"，像素断言才有意义
  assert_true(@native-common.native_widget_origin(band).1 < -40)
  let after = scroll_surface_pixel(title, px, py)
  assert_eq((after >> 56) & 0xFFL, 0L)
  let after_rgb = after & 0xFF_FFFFL
  assert_true(after_rgb != 0x33_66CCL)
  b.destroy_widget(far)
  b.destroy_widget(band)
  b.destroy_widget(scroll)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 行底换色时，整行必须**当场**画完，不留一格待画（`T318`）。
///
/// 现场（owner 2026-11-18 截图）：鼠标在播放列表上滑过，划过的每一行都变成
/// 一条只剩底色的空行，移开鼠标才刷回来。机制：列表行的"底"是一块 Panel，
/// 行里的字是它**同父**的几只透明标签（`WS_EX_TRANSPARENT`，自己不铺底）。
/// 悬停换底时 Panel 立刻重画，把压在它身上的字的像素盖掉；而标签的重画只被
/// 排进更新区、要等下一帧才落笔——中间那一格就是"新底色 + 没有字"，人手
/// 划过的每一行都闪一下，划得快就能同时看到好几行。
///
/// 判据读系统自己的画笔账（`paint_probe`，`T121` 那套）：推一次新底色之后
/// **不泵消息**，底和三只标签必须都已经收到过 `WM_PAINT`。修复前这里是 0
/// ——`moonui_native_invalidate` 只做了 `InvalidateRect`，笔一直欠着。
///
/// 为什么不读屏幕像素（首版就是那么写的）：那条路要窗口此刻真压在桌面最上
/// 层，本机开着 Chrome / VMware / 终端，读回来的是别人窗口的像素；"待画区
/// 还没被消费"才是那个空白帧的因，量因比量果稳。
test "原生后端：行底换色时整行当场画完，不留待画的空白帧（T318）" {
  let title = "MoonUI 原生 行底换色"
  let b = open_backend_for_testing(200)
  b.init()
  let win = b.create_window(title, @moonui.LogicalSize(320.0, 120.0))
  let bg_a = @moonui.Color::rgb(0xF7, 0xFA, 0xFD)
  let bg_b = @moonui.Color::rgb(0xE8, 0xEF, 0xF5)
  let ink = @moonui.Color::rgb(0x22, 0x22, 0x22)
  // 先挂字、后挂行底：`attach_tail` 把每只新控件插到 z 序末尾（`HWND_BOTTOM`），
  // 所以后挂的在下面。真实行里字压在行的底色之上，脚手架得照同一个次序搭——
  // 反过来搭（先底后字）时底会整块盖住标签，标签的可见区是空的，系统连
  // `WM_PAINT` 都不发（实测 `GetClipBox` = NULLREGION），判据失去意义。
  let cells : Array[@moonui.NativeHandle] = []
  let texts = ["1", "track00", "04:00"]
  for i, txt in texts {
    let c = b.create_widget(@moonui.Label, txt)
    b.attach_widget(win, c)
    b.set_widget_bounds(
      c,
      @moonui.LogicalRect(
        @moonui.LogicalPoint(12.0 + 90.0 * i.to_double(), 10.0),
        @moonui.LogicalSize(60.0, 17.0),
      ),
    )
    b.set_widget_style(
      c,
      @moonui.style(foreground=Some(ink), font_size=Some(10.0)),
    )
    cells.push(c)
  }
  let row = b.create_widget(@moonui.Panel, "")
  b.attach_widget(win, row)
  b.set_widget_bounds(
    row,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(8.0, 8.0),
      @moonui.LogicalSize(300.0, 20.0),
    ),
  )
  b.set_widget_style(
    row,
    @moonui.style(background=Some(bg_a), radius=Some(0.0)),
  )
  b.show_window(win)
  for _ in 0..<12 {
    let _ = b.poll_event()
  }
  // 装表 = 从这一刻起只数新的 `WM_PAINT`；再把可能还挂着的待画抹平，让每只
  // 都回到"以为自己画过"的状态——下面数到的就纯粹是推样式带出来的那一笔。
  // 一行 = 三只标签 + 一块 Panel，都挂在窗口名下。
  let n = paint_probe_begin(title)
  assert_eq(n, 4)
  assert_eq(paint_probe_validate(title), n)
  let (total0, painted0, _) = paint_probe_report(title)
  assert_eq(total0, n)
  assert_eq(painted0, 0)
  // 换底（模拟悬停）：不泵消息，底和三只标签都必须已经画完。
  b.set_widget_style(
    row,
    @moonui.style(background=Some(bg_b), radius=Some(0.0)),
  )
  let (total, painted, limbo) = paint_probe_report(title)
  println("T318 total=\{total} painted=\{painted} limbo=\{limbo}")
  assert_eq(total, n)
  assert_eq(painted, n)
  assert_eq(limbo, 0)
  paint_probe_end(title)
  for c in cells {
    b.destroy_widget(c)
  }
  b.destroy_widget(row)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// `present` 不许"只看谁恰好欠画"：整棵子树的透明层都得请去重画（`T326③`）。
///
/// 病根在 `moonui_native_present_subtree` 的透明窗分支：`UpdateWindow` 对
/// `WS_EX_TRANSPARENT` 子窗**回成功但一次 `WM_PAINT` 都不发**（`T318` 实测），
/// 于是落笔全靠后面那一发 `SendMessage(WM_PAINT)`；而老代码把它挂在
/// `GetUpdateRect != 0` 的条件下——`BeginPaint` 的 `rcPaint` 取更新区，没有更新区
/// 时系统 STATIC 就用空矩形裁字，一个字都不画。
///
/// 缺陷现场（2026-11-19 在 `examples/lunamusic-native` 上用同一条探针量）：窗口
/// 露出后 present 入口读到 `vis=210`，而**定位好的行标签一只更新区都没有**
/// （只有 43 只 0×0 的占位标签还挂着创建时的脏区）——它们在藏着的父窗里被
/// `SetWindowPos` 摆位置，那次失效被可见区裁成了空；`RedrawWindow(RDW_ALLCHILDREN)`
/// 同样空转。老代码因此一条 `WM_PAINT` 都不发，屏幕上整片列表只有斑马底没有字；
/// 鼠标划过哪行、哪行走了 `T318` 的配对收笔才冒出来（owner 报的就是这个）。
///
/// 判据不数"收到过 `WM_PAINT`"（`T121` 那三个数数的是这个），而是先把所有人的
/// 待画队列抹平（`paint_probe_validate`，等价于"每只都以为自己画过"——正是上面
/// 量到的现场），再调一次 `present`，要求**每只透明标签都真被请去重画**。
/// 旧实现这一发一只都不发（`painted=0`），修复后是全员。
test "原生后端：present 不看谁恰好欠画，透明层全员重画（T326③）" {
  let title = "MoonUI 原生 欠画"
  let b = open_backend_for_testing(200)
  b.init()
  let win = b.create_window(title, @moonui.LogicalSize(360.0, 200.0))
  let ink = @moonui.Color::rgb(0x22, 0x22, 0x22)
  let cells : Array[@moonui.NativeHandle] = []
  for i in 0..<9 {
    let c = b.create_widget(@moonui.Label, "track \{i}")
    b.attach_widget(win, c)
    b.set_widget_style(
      c,
      @moonui.style(foreground=Some(ink), font_size=Some(10.0)),
    )
    // 样式之后才定尺寸：这一步只标父窗，不给标签自己留更新区。
    b.set_widget_bounds(
      c,
      @moonui.LogicalRect(
        @moonui.LogicalPoint(12.0, 6.0 + 20.0 * i.to_double()),
        @moonui.LogicalSize(160.0, 17.0),
      ),
    )
    cells.push(c)
  }
  b.show_window(win)
  let n = paint_probe_begin(title)
  assert_eq(n, 9)
  // 抹平待画队列 = 缺陷现场：每只都"以为自己画过"，谁也不欠画。
  assert_eq(paint_probe_validate(title), n)
  let (_, before, _) = paint_probe_report(title)
  assert_eq(before, 0)
  @native-common.native_window_present(win)
  let (total, painted, limbo) = paint_probe_report(title)
  println("T326③ total=\{total} painted=\{painted} limbo=\{limbo}")
  assert_eq(total, n)
  assert_eq(painted, n)
  assert_eq(limbo, 0)
  paint_probe_end(title)
  for c in cells {
    b.destroy_widget(c)
  }
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 透明标签**自己**换字色时也要当场落笔（`T329`）。
///
/// `T326③` 补的是 `present_subtree` 那条路；可点击换选中态走的是另一条：
/// `set_widget_style` → `moonui_native_invalidate`。配对那一支会把压在面板上的
/// 标签一起再画一遍，但标签自己这条分支原来是"只标脏、不当场画"，而透明标签
/// 的定位/重排常常裁出空更新区（`T326③` 量到 210 只里只有 43 只有更新区）。
/// 于是新底色已经落屏、字要等消息泵隔 8ms 再补——那一帧就是 owner 报的
/// "点一下轻微闪一下"。
///
/// 判据量结果不量手段：先把待画队列抹平，再逐只换字色，**不泵任何事件**，
/// 要求每只标签都真收到过 `WM_PAINT`。旧实现这里读到 0，修复后是全员。
test "原生后端：透明标签换字色当场重画（T329）" {
  let title = "MoonUI 原生 标签即时落笔"
  let b = open_backend_for_testing(200)
  b.init()
  let win = b.create_window(title, @moonui.LogicalSize(360.0, 200.0))
  let ink = @moonui.Color::rgb(0x22, 0x22, 0x22)
  let accent = @moonui.Color::rgb(0x99, 0x33, 0x11)
  let cells : Array[@moonui.NativeHandle] = []
  for i in 0..<6 {
    let c = b.create_widget(@moonui.Label, "track \{i}")
    b.attach_widget(win, c)
    b.set_widget_bounds(
      c,
      @moonui.LogicalRect(
        @moonui.LogicalPoint(12.0, 6.0 + 20.0 * i.to_double()),
        @moonui.LogicalSize(160.0, 17.0),
      ),
    )
    b.set_widget_style(
      c,
      @moonui.style(foreground=Some(ink), font_size=Some(10.0)),
    )
    cells.push(c)
  }
  b.show_window(win)
  let n = paint_probe_begin(title)
  assert_eq(n, 6)
  // 抹平既有欠账：下面读数里只准出现这次换色引起的 WM_PAINT。
  assert_eq(paint_probe_validate(title), n)
  let (_, before, _) = paint_probe_report(title)
  assert_eq(before, 0)
  // 不泵事件：这一发必须就在 set_widget_style 里同步落完。
  for c in cells {
    b.set_widget_style(c, @moonui.style(foreground=Some(accent)))
  }
  let (total, painted, limbo) = paint_probe_report(title)
  println("T329 total=\{total} painted=\{painted} limbo=\{limbo}")
  assert_eq(total, n)
  assert_eq(painted, n)
  assert_eq(limbo, 0)
  paint_probe_end(title)
  for c in cells {
    b.destroy_widget(c)
  }
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
#borrow(title)
extern "c" fn c_scroll_edge_pixel(
  title : Bytes,
  title_len : Int32,
  dx : Int32,
  y : Int32,
) -> Int64 = "moonui_native_scroll_edge_pixel"

///|
fn scroll_edge_pixel(title : String, dx : Int32, y : Int32) -> Int64 {
  let t = @utf8.encode(title)
  c_scroll_edge_pixel(t, t.length(), dx, y)
}

///|
/// 滚动条判据（owner 2026-11-17 截图①）：内容刚超一屏就必须出条，不能等到
/// 将近两屏。旧实现把 `SCROLLINFO.nMax` 写成 `content - view`，而 Win32 的
/// 显示判据是 `nMax - nMin + 1 <= nPage` 就藏条——代进去等于要
/// `content > 2*view - 1` 才现身，于是"能滚（滚轮读 SCROLLINFO）却没条"。
///
/// 这条钉三件事：① 1.8 屏内容就出条（旧实现红线）；② 装得下就收条；
/// ③ 滚到底的最大偏移仍是 `content - view`（改 nMax 语义时别把行程也改了）。
test "原生后端：滚动条在内容刚超一屏时就出现" {
  let title = "MoonUI 原生 滚动条阈值"
  let b = open_backend_for_testing(200)
  b.init()
  let win = b.create_window(title, @moonui.LogicalSize(240.0, 200.0))
  let scroll = b.create_widget(@moonui.Scroll, "")
  b.attach_widget(win, scroll)
  b.set_widget_bounds(
    scroll,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(160.0, 100.0),
    ),
  )
  let row = b.create_widget(@moonui.Label, "滚行")
  b.attach_widget_to(scroll, row)
  b.set_widget_bounds(
    row,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(4.0, 0.0),
      @moonui.LogicalSize(100.0, 20.0),
    ),
  )
  // 1.8 屏：100 的视口放 180 的内容。旧实现要 200 以上才给条，这里是红线。
  b.set_scroll_content(
    scroll,
    @moonui.Vertical,
    @moonui.LogicalSize(160.0, 180.0),
  )
  assert_eq(@native-common.native_scroll_has_vertical_scroller(scroll), 1)
  // 滚到底：最大偏移必须是 content - view（改 nMax 语义后行程不能跟着变）。
  // 一格一格投（脚手架按"格"编码，一次投太多格会被 SHORT 截断），投够为止。
  let dpi = @native-common.native_window_dpi(win)
  let y_before = @native-common.native_widget_origin(row).1
  for _ in 0..<6 {
    let sent = send_mouse_in_window(
      title,
      4 * 8,
      scaffold_px(80.0, dpi),
      scaffold_px(60.0, dpi),
      0,
      60,
    )
    assert_eq(sent, 0)
    for _ in 0..<6 {
      let _ = b.poll_event()
    }
  }
  assert_true(@native-common.native_widget_origin(row).1 < y_before)
  let off_y = (scroll_offset_of(title) >> 32) & 0xFF_FFFF_FFL
  let expected = scaffold_px(180.0, dpi).to_int64() -
    scaffold_px(100.0, dpi).to_int64()
  assert_eq(off_y, expected)
  // 再滚一格：已经到底，偏移不许再动（clamp 用的是 content - view）
  let sent2 = send_mouse_in_window(
    title,
    4 * 8,
    scaffold_px(140.0, dpi),
    scaffold_px(60.0, dpi),
    0,
    60,
  )
  assert_eq(sent2, 0)
  for _ in 0..<6 {
    let _ = b.poll_event()
  }
  assert_eq((scroll_offset_of(title) >> 32) & 0xFF_FFFF_FFL, off_y)
  // 装得下（95 < 100）就收条
  b.set_scroll_content(
    scroll,
    @moonui.Vertical,
    @moonui.LogicalSize(160.0, 95.0),
  )
  assert_eq(@native-common.native_scroll_has_vertical_scroller(scroll), 0)
  b.destroy_widget(row)
  b.destroy_widget(scroll)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
#borrow(title)
extern "c" fn c_scroll_blank_probe(title : Bytes, title_len : Int32) -> Int64 = "moonui_native_scroll_blank_probe"

///|
fn scroll_blank_probe(title : String) -> Int64 {
  let t = @utf8.encode(title)
  c_scroll_blank_probe(t, t.length())
}

///|
/// 滚动之后，视口里的每一行必须**当场**画完（`T319`）。
///
/// 现场（owner 2026-11-18 截图）：拖动/滚轮翻页时，新露出来的几行先是只剩
/// 斑马底的空行，过一会儿才一行行冒出字。
///
/// 机制：一次翻页要画的是"视口底色 + 每块面板 + 每只标签"，在 Windows 上是
/// **每只窗口各一条 `WM_PAINT`**，而 `moonui_native_main_step` 一圈只泵一条
/// 消息。只把这一堆标脏的话，整帧要好几轮才补完——中间那几轮屏幕上就是空的。
///
/// 判据两条，量的是"画了没有"而不是"脏没脏"：
///   ① `paint_probe`（`T121` 那套）——滚这一下，视口底色与视口内每一行都必须
///      真收到过 `WM_PAINT`（16 只；第 0 行整行滚出视口，不算）。只标脏不落笔
///      时这里只有 6 只——其余是 `SetWindowPos` 露出来的那些，碰巧被系统补了。
///   ② `moonui_native_scroll_blank_probe`——收笔之后不许再留着待画区。
///
/// 为什么不只量待画区：负控制里看得很清楚，把收笔短路之后待画区在很多脚手架
/// 里本来就可能是空的（没人标脏就没欠账），"没画"与"画完了"读出来一样，判据
/// 失去区分力。① 才是那个空白帧的直接对证。也不读屏幕像素：那条路要求窗口
/// 真压在桌面最上层，本机开着别的窗时读回来的是别人的像素。
///
/// 行结构照真实列表搭：先挂字、后挂行底（`attach_tail` 往 `HWND_BOTTOM` 插，
/// 后挂的在下面），字压在底上——反过来搭的话底会整块盖住标签，见 `T318`。
test "原生后端：滚动之后视口内的行当场画完，不留空白（T319）" {
  let title = "MoonUI 原生 滚动收笔"
  let b = open_backend_for_testing(200)
  b.init()
  let win = b.create_window(title, @moonui.LogicalSize(320.0, 200.0))
  let scroll = b.create_widget(@moonui.Scroll, "")
  b.attach_widget(win, scroll)
  b.set_widget_bounds(
    scroll,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(8.0, 8.0),
      @moonui.LogicalSize(200.0, 100.0),
    ),
  )
  let bg = @moonui.Color::rgb(0xF7, 0xFA, 0xFD)
  let ink = @moonui.Color::rgb(0x22, 0x22, 0x22)
  let made : Array[@moonui.NativeHandle] = []
  // 六行 × 20 = 120，比视口 100 高一屏多一点：翻页之后最底下那行是新露出来的。
  for i in 0..<6 {
    let y = (i * 20).to_double()
    for j in 0..<2 {
      let lab = b.create_widget(@moonui.Label, "行\{i}-\{j}")
      b.attach_widget_to(scroll, lab)
      b.set_widget_bounds(
        lab,
        @moonui.LogicalRect(
          @moonui.LogicalPoint(6.0 + 60.0 * j.to_double(), y),
          @moonui.LogicalSize(50.0, 17.0),
        ),
      )
      b.set_widget_style(
        lab,
        @moonui.style(foreground=Some(ink), font_size=Some(10.0)),
      )
      made.push(lab)
    }
    // 行底只铺 160 宽：右边留一条空的视口（滚轮要点在视口本体上才轮得到
    // 滚动逻辑——投给行里的字或底，那条消息不会往父窗转发）。
    let row = b.create_widget(@moonui.Panel, "")
    b.attach_widget_to(scroll, row)
    b.set_widget_bounds(
      row,
      @moonui.LogicalRect(
        @moonui.LogicalPoint(0.0, y),
        @moonui.LogicalSize(160.0, 20.0),
      ),
    )
    b.set_widget_style(
      row,
      @moonui.style(background=Some(bg), radius=Some(0.0)),
    )
    made.push(row)
  }
  b.set_scroll_content(
    scroll,
    @moonui.Vertical,
    @moonui.LogicalSize(200.0, 120.0),
  )
  b.show_window(win)
  // 泵到账平为止：一次显示要画"视口 + 6 行 × 3 只窗"，而一圈只泵一条消息，
  // 固定轮数（12）在这台机器上会剩几笔没画完，那与滚动无关。
  for _ in 0..<80 {
    if scroll_blank_probe(title) == 0L {
      break
    }
    let _ = b.poll_event()
  }
  // 滚之前先确认账是平的：不平的话下面那条 0 就不再有区分力。
  let settled = scroll_blank_probe(title)
  assert_eq(settled, 0L)
  // 装表：从这一刻起数"谁真收到过 `WM_PAINT`"（`T121` 那套）。`paint_probe_begin`
  // 递归枚举整棵树，所以视口与它的子窗全在表里；`paint_probe_validate` 把还挂着
  // 的待画抹平，免得滚动之前那点余账混进下面的读数。
  let probed = paint_probe_begin(title)
  assert_eq(probed, 19)
  assert_eq(paint_probe_validate(title), probed)
  let dpi = @native-common.native_window_dpi(win)
  let sent = send_mouse_in_window(
    title,
    4 * 8,
    scaffold_px(180.0, dpi),
    scaffold_px(40.0, dpi),
    0,
    200,
  )
  assert_eq(sent, 0)
  // 滚轮是 `PostMessage` 投的：泵到偏移真的动了就停手。这一条消息正是滚动
  // 处理本身——它返回时屏幕上是什么，就是用户翻页时看到的那一帧；再多泵几条
  // 就把"后来补上的"也算进去了，判据就没有区分力了。
  for _ in 0..<40 {
    if ((scroll_offset_of(title) >> 32) & 0xFF_FFFF_FFL) != 0L {
      break
    }
    let _ = b.poll_event()
  }
  let off_y = (scroll_offset_of(title) >> 32) & 0xFF_FFFF_FFL
  let expected = scaffold_px(120.0, dpi).to_int64() -
    scaffold_px(100.0, dpi).to_int64()
  assert_eq(off_y, expected)
  // 主判据：滚这一下，谁真收到过 `WM_PAINT`。滚一屏 20，第 0 行整行滚出视口
  // （它本来就不该在屏幕上出现），其余 5 行 + 视口底色共 16 只必须都画过。
  // 这条量的是"画了没有"，不是"脏没脏"——只标脏不落笔的时候，子窗的待画区
  // 在这些脚手架里本来就可能是空的，光量脏区验不出空白帧（负控制里看得很清楚）。
  let (total, painted, limbo) = paint_probe_report(title)
  println(
    "T319 total=\{total} painted=\{painted} limbo=\{limbo} pending=\{scroll_blank_probe(title)}",
  )
  assert_eq(total, 19)
  // 视口底色 1 + 5 行 × 3 只 = 16。
  assert_eq(painted, 16)
  // 剩下 3 只是第 0 行：整行滚出视口，既没画、也不该有待画区——`limbo` 数的正是
  // "没画过又没脏"的那些，所以这里是 3 而不是 0。
  assert_eq(limbo, 3)
  // 收笔之后不该再留着待画区（`T318` 那条的另一半账：配对 + 落笔之后不能有欠账）。
  assert_eq(scroll_blank_probe(title), 0L)
  paint_probe_end(title)
  for w in made {
    b.destroy_widget(w)
  }
  b.destroy_widget(scroll)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 滚动条左缘白线判据（owner 2026-11-17 截图②）：滚动条与正文交界那一列
/// 不能是白的。空白视口里取两点对比——正文里的底色 vs 客户区右缘第一列
/// （`dx = 0`，就是滚动条的左边缘）。两者不一致就说明这一列没人按底色画。
test "原生后端：滚动条左缘不留白线" {
  let title = "MoonUI 原生 滚动条白线"
  let b = open_backend_for_testing(200)
  b.init()
  let win = b.create_window(title, @moonui.LogicalSize(300.0, 240.0))
  let scroll = b.create_widget(@moonui.Scroll, "")
  b.attach_widget(win, scroll)
  b.set_widget_bounds(
    scroll,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(200.0, 160.0),
    ),
  )
  b.set_scroll_content(
    scroll,
    @moonui.Vertical,
    @moonui.LogicalSize(200.0, 640.0),
  )
  b.show_window(win)
  for _ in 0..<12 {
    let _ = b.poll_event()
  }
  let dpi = @native-common.native_window_dpi(win)
  let py = scaffold_px(40.0, dpi)
  // 视口里没有任何子控件 → 左边这一点就是裸底色
  let bg = scroll_edge_pixel(title, -20, py)
  assert_eq((bg >> 56) & 0xFFL, 0L)
  let edge = scroll_edge_pixel(title, 0, py)
  assert_eq((edge >> 56) & 0xFFL, 0L)
  assert_eq(edge & 0xFF_FFFFL, bg & 0xFF_FFFFL)
  b.destroy_widget(scroll)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
extern "c" fn c_style_probe_reset() -> Unit = "moonui_native_style_probe_reset"

///|
extern "c" fn c_style_probe() -> Int32 = "moonui_native_style_probe"

///|
/// 删除闪烁的根因判据（owner 2026-11-17 第二次报告）：Core 每次 relayout 都对
/// 整棵树重推同一份样式（`apply_styles`），后端照单全做的话要重建画刷、再让每只
/// 控件失效重画一次——删一行就是这样把整片内容闪一下。
/// 这条钉住"同一份样式重复下发 = 零失效"：先把一份样式落下去，清账，再把**同
/// 一份**推一遍，失效数必须是 0；换一个字段再推，必须是 1（别把闸门做成"永不
/// 重画"，那会让真改动也画不出来）。
test "原生后端：同一份样式重复下发不失效重画" {
  let b = open_backend_for_testing(200)
  b.init()
  let win = b.create_window(
    "MoonUI 原生 样式重复下发",
    @moonui.LogicalSize(240.0, 160.0),
  )
  let label = b.create_widget(@moonui.Label, "样式")
  b.attach_widget(win, label)
  b.set_widget_bounds(
    label,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(100.0, 20.0),
    ),
  )
  let base = @moonui.style(
    background=Some(@moonui.Color::rgb(0xEE, 0xEE, 0xEE)),
    font_size=Some(14.0),
    radius=Some(4.0),
  )
  b.set_widget_style(label, base)
  c_style_probe_reset()
  // 同一份：一笔都不该落
  b.set_widget_style(label, base)
  assert_eq(c_style_probe(), 0)
  // 换底色：必须失效一次，否则新颜色永远不露面
  let changed = @moonui.style(
    background=Some(@moonui.Color::rgb(0xCC, 0xDD, 0xEE)),
    font_size=Some(14.0),
    radius=Some(4.0),
  )
  b.set_widget_style(label, changed)
  assert_eq(c_style_probe(), 1)
  b.destroy_widget(label)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 换文案时，**底由兄弟画**也得把那块地重铺一遍（`T327`）。
///
/// 病根：`T321` 的擦除靠"沿 holder 链往上找第一只自己画底的祖先"。播放条的脸面
/// 是 `stack([gradient_panel, face_body])`——渐变条带是标签子树的**兄弟**，祖先链
/// 上根本没有画底的那只。实测链路（2026-11-19 的临时探针）：`label →
/// MoonuiWndClass` 一级就断（`holder` 与 `GetParent` 都断在那里），于是 `T321`
/// 那一路整段放弃：`SetWindowTextW` 之后旧字留在原地、新字叠上去——`00:00 →
/// 00:12` 糊成一团、`状态: 就绪 → 状态: 播放` 两串压在一起（owner 2026-11-19
/// 截图）。列表行、页签标题没有这个现象，正是因为它们的底由祖先 Panel 画。
///
/// 判据问"该重画的那一次真发生了没有"：先用 `paint_probe_validate` 把所有人的
/// 待画队列抹平（每只都"以为自己画过"、谁也不欠画），再换一次文案，然后要求
/// 这棵树里**每只都被同步重画**。老代码这一发谁都不动（`painted=0`）——它连
/// "该找谁重铺"都没找到；修复后兄弟面板与标签各得一次。
///
/// 不数屏幕像素：2026-11-20 量过，本机真窗判据里 `GetPixel(GetDC(0))` 对这只
/// 未上屏的测试窗一律回 `CLR_INVALID`（连"全像素"档都数出 0），拿它当判据只会
/// 得到一条与环境无关的假读数。
test "原生后端：底由兄弟画时换文案也重铺那块地（T327）" {
  let title = "MoonUI 原生 兄弟底"
  let b = open_backend_for_testing(200)
  b.init()
  let win = b.create_window(title, @moonui.LogicalSize(240.0, 90.0))
  // 底：一只铺满的实色 Panel。它与标签是**兄弟**（都直接挂在窗口下），不在
  // 标签的祖先链上——正是 `stack([gradient_panel, ...])` 的形状。
  let blue = @moonui.Color::rgb(0x00, 0x00, 0xFF)
  let bgp = b.create_widget(@moonui.Panel, "")
  b.attach_widget(win, bgp)
  b.set_widget_bounds(
    bgp,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(240.0, 90.0),
    ),
  )
  b.set_widget_style(
    bgp,
    @moonui.style(background=Some(blue), radius=Some(0.0)),
  )
  let red = @moonui.Color::rgb(0xFF, 0x00, 0x00)
  let label = b.create_widget(@moonui.Label, "00:00")
  b.attach_widget(win, label)
  b.set_widget_bounds(
    label,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(16.0, 24.0),
      @moonui.LogicalSize(200.0, 40.0),
    ),
  )
  b.set_widget_style(
    label,
    @moonui.style(foreground=Some(red), font_size=Some(24.0)),
  )
  b.show_window(win)
  for _ in 0..<10 {
    let _ = b.poll_event()
  }
  let n = paint_probe_begin(title)
  assert_eq(n, 2)
  // 抹平待画队列：没人欠画，接下来那一发只能来自换文案自己的重铺。
  assert_eq(paint_probe_validate(title), n)
  let (_, before, _) = paint_probe_report(title)
  assert_eq(before, 0)
  b.set_widget_text(label, "00:12")
  let (total, painted, limbo) = paint_probe_report(title)
  println("T327 total=\{total} painted=\{painted} limbo=\{limbo}")
  assert_eq(total, n)
  // 兄弟面板 + 标签，两只都得被请去重画：只画标签等于旧字还留着。
  assert_eq(painted, n)
  assert_eq(limbo, 0)
  paint_probe_end(title)
  b.destroy_widget(label)
  b.destroy_widget(bgp)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}
