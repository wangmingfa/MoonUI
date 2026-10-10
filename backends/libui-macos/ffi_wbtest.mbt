///|
/// FFI 层的冒烟测试：真窗口、真控件、真点击，全部按物理像素对话（`T54` 补的
/// mac 侧同形物，形状照 `backends/libui-windows/ffi_wbtest.mbt`）。
///
/// 这几条测试会在桌面上真的开窗口——`moonui_click_button_in_window` 按客户区
/// 坐标 hitTest 命中 NSButton、`performClick:` 让真按钮自己发 action，消息进的
/// 是 libui 注册的 onClicked:——和人手点下去完全同一条路径，不是把回调函数直接
/// 调一遍。窗口在同一条测试里就关掉，不阻塞、不等人工操作，`moon test` 因此能
/// 无人值守跑完。
///
/// 这一层只验 `native_*` 的形状对不对（坐标、状态读写、路由）。契约级的往返
/// 在 `macos_test.mbt`，那里走 `Backend` trait 和逻辑像素。
///
/// 点击是按客户区坐标命中的，所以控件的矩形真的参与了验证：
/// `native_control_set_bounds` 摆错位置的话这里就点不到。
///
/// 登记表与清场在本文件**自带一份**，不像 Windows 那样借 `backend_wbtest.mbt`
/// 的：那边两份都是白盒、同命名空间；这边 `macos_test.mbt` 是黑盒（`_test` 后缀
/// 自成一组、看不见白盒的私有物），而 wbtest 文件各自产一份测试二进制，泄漏本来
/// 就不穿进程边界——共享的只是形状，不是状态。

///|
/// 矩形中心点，用来按坐标命中。
fn center(rect : (Int, Int, Int, Int)) -> (Int, Int) {
  let (x, y, w, h) = rect
  (x + w / 2, y + h / 2)
}

///|
/// 建了对象就登记，让中途 raise 的那一条能被下一条的 prologue 补收。
/// 先控件后窗口是硬顺序：uiUninit 的分配审计要求控件先于窗口销毁
/// （`../libui-common/backend.mbt` 里 `Backend::terminate` 上面那段注释），
/// 所以清场不能只靠"把表倒出来挨个销毁"——分两张表就是给这个顺序留的位置。
let native_widgets_in_play : Array[@moonui.NativeHandle] = []

///|
/// 见 `native_widgets_in_play`。
let native_windows_in_play : Array[@moonui.NativeHandle] = []

///|
/// 清掉上一条失败时漏下的原生对象，让这一条从空的句柄表开始。已经收过尾的句柄
/// 也在这两张表里，对它们是空转：`native_*_destroy` 撞上过期句柄就报错并被丢掉
/// （`handle.mbt` 的 `HandleTable::resolve`：id 会复用，但 generation 递增，
/// 旧句柄不会命中新对象），而 `moonui_terminate` 在没 inited 时直接返回。
/// 只漏裸句柄时补一次 terminate：C 侧的回调槽位是有限的
/// （`ffi.mbt` 的"回调槽位已用满"），只有 terminate 会松开它们。
fn sweep_leaked_handles() -> Unit {
  let leaked_native = native_widgets_in_play.length() > 0 ||
    native_windows_in_play.length() > 0
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
  if leaked_native {
    @libui-common.native_terminate()
  }
}

///|
/// 每条测试的开头：先替上一条清场，再 init。`moonui_init` 是幂等的
/// （adapter_macos.m 里已 inited 就直接返回 0），所以上一条有没有 uninit
/// 都能接着跑；真正不能留的是它的窗口和控件。
fn begin_native_session() -> Unit raise @moonui.UiError {
  sweep_leaked_handles()
  @libui-common.native_init()
}

///|
/// 建了就登记的窗口版。
fn tracked_window_new(
  title : String,
  width : Int,
  height : Int,
) -> @moonui.NativeHandle raise @moonui.UiError {
  let h = @libui-common.native_window_new(title, width, height)
  native_windows_in_play.push(h)
  h
}

///|
/// `tracked_window_new` 的控件版。失败（比如纯布局节点）时不进表：那时什么都没建。
fn tracked_widget_new(
  kind : @moonui.WidgetKind,
  text : String,
) -> @moonui.NativeHandle raise @moonui.UiError {
  let h = @libui-common.native_widget_new(kind, text)
  native_widgets_in_play.push(h)
  h
}

///|
test "libui 冒烟：真按钮被点一次，句柄全部回收" {
  begin_native_session()
  // 标题在这台机器上必须唯一：点击注入是按标题找回窗口的
  let title = "MoonUI libui smoke 43ba1ef mac"
  let win = tracked_window_new(title, 240, 120)
  let btn = tracked_widget_new(@moonui.Button, "按下我")
  @libui-common.native_control_attach(win, btn)
  let log : Array[String] = []
  @libui-common.native_widget_on_click(btn, fn() { log.push("点击") })
  @libui-common.native_control_set_bounds(btn, 8, 8, 120, 32)
  @libui-common.native_window_show(win)
  @libui-common.native_main_steps()
  let (cx, cy) = center((8, 8, 120, 32))
  assert_eq(@libui-common.native_click_button_in_window(title, cx, cy), 0)
  // performClick: 是同步的：回调在上一行返回前就走完了
  assert_eq(log.length(), 1)
  // 空白处点不到任何按钮——这条保证上面那条 0 不是"随便点哪里都算命中"
  assert_true(@libui-common.native_click_button_in_window(title, 200, 100) < 0)
  // 文案往返同时验 UTF-8 进出；中文标题找得到窗口也顺带证明了这点
  assert_eq(@libui-common.native_widget_text(btn), "按下我")
  @libui-common.native_widget_set_text(btn, "点过了")
  assert_eq(@libui-common.native_widget_text(btn), "点过了")
  @libui-common.native_window_hide(win)
  // §14 的代价：窗口不替控件收尾，控件必须在窗口之前逐个销毁
  @libui-common.native_widget_destroy(btn)
  @libui-common.native_window_destroy(win)
  assert_eq(@libui-common.native_live_handles(), 0)
  @libui-common.native_terminate()
}

///|
/// 挂接与摆放是两个调用（Core 的顺序是先 attach 再布局），重新布局只改矩形：
/// 这里用命中测试证明控件真的搬到了新位置——旧位置点不到，新位置点得到。
test "libui 冒烟：重新摆放只改矩形不动挂接" {
  begin_native_session()
  let title = "MoonUI libui smoke 重新布局 mac"
  let win = tracked_window_new(title, 240, 200)
  let btn = tracked_widget_new(@moonui.Button, "搬家")
  let log : Array[String] = []
  @libui-common.native_control_attach(win, btn)
  @libui-common.native_widget_on_click(btn, fn() { log.push("点击") })
  @libui-common.native_control_set_bounds(btn, 8, 8, 120, 32)
  @libui-common.native_window_show(win)
  @libui-common.native_main_steps()
  let (ox, oy) = center((8, 8, 120, 32))
  assert_eq(@libui-common.native_click_button_in_window(title, ox, oy), 0)
  assert_eq(log, ["点击"])
  @libui-common.native_control_set_bounds(btn, 60, 90, 120, 32)
  assert_true(@libui-common.native_click_button_in_window(title, ox, oy) < 0)
  let (nx, ny) = center((60, 90, 120, 32))
  assert_eq(@libui-common.native_click_button_in_window(title, nx, ny), 0)
  assert_eq(log, ["点击", "点击"])
  // origin/size 读回来就是刚摆过去的位置（物理像素，与客户区坐标同一套；
  // adapter 内部过一遍"点"的换算和 y 翻折，这条同时钉住那两步没改坏）
  assert_eq(@libui-common.native_widget_origin(btn), (60, 90))
  assert_eq(@libui-common.native_widget_size(btn), (120, 32))
  @libui-common.native_window_hide(win)
  @libui-common.native_widget_destroy(btn)
  @libui-common.native_window_destroy(win)
  assert_eq(@libui-common.native_live_handles(), 0)
  @libui-common.native_terminate()
}

///|
/// 多个真控件挂在同一个窗口下时，点击仍然只落到被点的那一个：
/// 命中走的是 contentView 的 hitTest，不查控件 ID，所以挂接顺序在这里
/// 不参与路由（层叠的顺序才吃 subviews 顺序，那是 macos_test 那半的事）。
test "libui 冒烟：点第二个按钮只触发第二个" {
  begin_native_session()
  let title = "MoonUI libui smoke 三个按钮 mac"
  let win = tracked_window_new(title, 240, 200)
  let first = tracked_widget_new(@moonui.Button, "甲")
  let second = tracked_widget_new(@moonui.Button, "乙")
  let third = tracked_widget_new(@moonui.Button, "丙")
  let log : Array[String] = []
  @libui-common.native_control_attach(win, first)
  @libui-common.native_control_set_bounds(first, 8, 8, 120, 32)
  @libui-common.native_control_attach(win, second)
  @libui-common.native_control_set_bounds(second, 8, 48, 120, 32)
  @libui-common.native_control_attach(win, third)
  @libui-common.native_control_set_bounds(third, 8, 88, 120, 32)
  @libui-common.native_widget_on_click(first, fn() { log.push("甲") })
  @libui-common.native_widget_on_click(second, fn() { log.push("乙") })
  // third 不挂回调：点它应当只是没人接，不能牵连别人
  @libui-common.native_window_show(win)
  @libui-common.native_main_steps()
  let (cx, cy) = center((8, 48, 120, 32))
  assert_eq(@libui-common.native_click_button_in_window(title, cx, cy), 0)
  assert_eq(log, ["乙"])
  let (ex, ey) = center((8, 88, 120, 32))
  assert_eq(@libui-common.native_click_button_in_window(title, ex, ey), 0)
  let _ = @libui-common.native_main_step(false)
  assert_eq(log, ["乙"])
  @libui-common.native_window_hide(win)
  @libui-common.native_widget_destroy(third)
  @libui-common.native_widget_destroy(second)
  @libui-common.native_widget_destroy(first)
  @libui-common.native_window_destroy(win)
  assert_eq(@libui-common.native_live_handles(), 0)
  @libui-common.native_terminate()
}

///|
/// 四种控件的创建与状态读写。Cocoa 那侧文案分居两个属性（NSTextField 的
/// stringValue、NSButton 的 title，见 adapter_macos.m 的 moonui_widget_set_text），
/// MoonBit 侧读的是同一个统一入口，这条顺带钉住那个分派没把谁漏下。
test "libui 冒烟：四种控件的状态读写都落在真 view 上" {
  begin_native_session()
  let title = "MoonUI libui smoke 四种控件 mac"
  let win = tracked_window_new(title, 320, 240)
  let label = tracked_widget_new(@moonui.Label, "只读文案")
  let entry = tracked_widget_new(@moonui.TextInput, "初值")
  let check = tracked_widget_new(@moonui.Checkbox, "同意")
  // 依次往下摆，窗口 show 之后三者都在屏幕上
  @libui-common.native_control_attach(win, label)
  @libui-common.native_control_set_bounds(label, 8, 0, 260, 28)
  @libui-common.native_control_attach(win, entry)
  @libui-common.native_control_set_bounds(entry, 8, 32, 260, 28)
  @libui-common.native_control_attach(win, check)
  @libui-common.native_control_set_bounds(check, 8, 64, 260, 28)
  @libui-common.native_window_show(win)
  assert_eq(@libui-common.native_widget_text(label), "只读文案")
  // uiNewEntry 不收文案（libui 的输入框默认空），adapter 建完再填——这条读数
  // 钉的就是"再填"那一步
  assert_eq(@libui-common.native_widget_text(entry), "初值")
  @libui-common.native_widget_set_text(entry, "改过的")
  assert_eq(@libui-common.native_widget_text(entry), "改过的")
  assert_false(@libui-common.native_widget_checked(check))
  @libui-common.native_widget_set_checked(check, true)
  assert_true(@libui-common.native_widget_checked(check))
  @libui-common.native_widget_set_checked(check, false)
  assert_false(@libui-common.native_widget_checked(check))
  // 窗口已经 show，挂进来的控件因此是"屏幕上看得见"
  assert_true(@libui-common.native_widget_visible(entry))
  @libui-common.native_widget_set_visible(entry, false)
  assert_false(@libui-common.native_widget_visible(entry))
  @libui-common.native_widget_set_visible(entry, true)
  assert_true(@libui-common.native_widget_visible(entry))
  assert_true(@libui-common.native_widget_enabled(entry))
  @libui-common.native_widget_set_enabled(entry, false)
  assert_false(@libui-common.native_widget_enabled(entry))
  @libui-common.native_widget_set_enabled(entry, true)
  // 固有尺寸来自 AppKit 的 cellSize，非零即可——具体像素取决于这台机器的字体
  let (lw, lh) = @libui-common.native_widget_minimum_size(label)
  assert_true(lw > 0 && lh > 0)
  let (ew, eh) = @libui-common.native_widget_minimum_size(entry)
  assert_true(ew > 0 && eh > 0)
  // DPI 不返回 0：0 会让 MoonBit 侧的除法变成无穷大
  assert_true(@libui-common.native_window_dpi(win) > 0)
  @libui-common.native_widget_destroy(check)
  @libui-common.native_widget_destroy(entry)
  @libui-common.native_widget_destroy(label)
  @libui-common.native_window_destroy(win)
  assert_eq(@libui-common.native_live_handles(), 0)
  @libui-common.native_terminate()
}

///|
/// 窗口几何往返 + detach 的后果。位置用物理像素，adapter 过"点"的换算；
/// detach 之后控件搬到 adapter 自建的 parking 位置，原来的矩形因此点不到。
test "libui 冒烟：窗口几何可读可写，摘下来的控件不再响应点击" {
  begin_native_session()
  @libui-common.native_main_steps()
  let title = "MoonUI libui smoke 窗口几何 mac"
  let win = tracked_window_new(title, 200, 150)
  let btn = tracked_widget_new(@moonui.Button, "摘我")
  let log : Array[String] = []
  @libui-common.native_control_attach(win, btn)
  @libui-common.native_widget_on_click(btn, fn() { log.push("点击") })
  @libui-common.native_control_set_bounds(btn, 10, 10, 120, 32)
  @libui-common.native_window_show(win)
  let (cx, cy) = center((10, 10, 120, 32))
  assert_eq(@libui-common.native_click_button_in_window(title, cx, cy), 0)
  assert_eq(log, ["点击"])
  // 摘下来：同一个坐标上什么都没有了（hitTest 落回 contentView，类名检查不认）
  @libui-common.native_control_detach(btn)
  assert_true(@libui-common.native_click_button_in_window(title, cx, cy) < 0)
  @libui-common.native_control_set_bounds(btn, 10, 10, 120, 32)
  assert_true(@libui-common.native_click_button_in_window(title, cx, cy) < 0)
  // 重新挂回去，路由照旧（libui 的回调表跟 uiControl 走，不受搬动影响）
  @libui-common.native_control_attach(win, btn)
  @libui-common.native_control_set_bounds(btn, 10, 10, 120, 32)
  assert_eq(@libui-common.native_click_button_in_window(title, cx, cy), 0)
  assert_eq(log, ["点击", "点击"])
  // 客户区尺寸：设进去和读出来一致（libui 会自己换算外层窗口）。
  // 量完之后要重新摆一次按钮：Cocoa 的子视图 frame 不跟窗口长大挪动（仍钉在
  // 离底边同样的位置），客户区坐标系里它已经不在 (10, 10) 了——Win32 的子窗口
  // 不跟父窗口挪，这是两平台的刻意分叉，下面先按读数钉住"真的挪了"再摆回去。
  @libui-common.native_window_set_content_size(win, 260, 180)
  assert_eq(@libui-common.native_window_content_size(win), (260, 180))
  assert_true(@libui-common.native_widget_origin(btn) != (10, 10))
  @libui-common.native_control_set_bounds(btn, 10, 10, 120, 32)
  assert_eq(@libui-common.native_widget_origin(btn), (10, 10))
  @libui-common.native_window_set_position(win, 40, 60)
  assert_eq(@libui-common.native_window_position(win), (40, 60))
  @libui-common.native_window_set_resizable(win, false)
  @libui-common.native_window_set_title(win, "MoonUI libui smoke 改了名 mac")
  assert_eq(
    @libui-common.native_click_button_in_window(
      "MoonUI libui smoke 改了名 mac", cx, cy,
    ),
    0,
  )
  // 主屏工作区非零，且窗口标题改名后旧标题找不到了
  let (sw, sh) = @libui-common.native_screen_work_area()
  assert_true(sw > 0 && sh > 0)
  assert_true(@libui-common.native_system_dpi() >= 96)
  @libui-common.native_window_hide(win)
  @libui-common.native_widget_destroy(btn)
  @libui-common.native_window_destroy(win)
  assert_eq(@libui-common.native_live_handles(), 0)
  @libui-common.native_terminate()
}

///|
/// 布局节点不该向原生层要对象：kind 映射在 FFI 层就报错，C 侧根本不会被调到。
test "libui 冒烟：纯布局节点没有原生对象可读" {
  begin_native_session()
  let msg = try {
    let _ = tracked_widget_new(@moonui.Row, "")
    None
  } catch {
    e => Some(e.message())
  }
  assert_eq(
    msg,
    Some(
      "不支持的操作：纯布局节点（Row/Column/…）不占原生对象",
    ),
  )
  @libui-common.native_terminate()
}
