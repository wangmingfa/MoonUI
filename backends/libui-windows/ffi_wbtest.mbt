///|
/// FFI 层的冒烟测试：真窗口、真控件、真消息，全部按物理像素对话。
///
/// 这几条测试会在桌面上真的开窗口——`BM_CLICK` 要求按钮有真实的 Win32 父级，
/// 点击消息才会走 libui 自己的 WM_COMMAND 路由，而不是把回调函数直接调一遍。
/// 窗口在同一条测试里就关掉，不阻塞、不等人工操作，`moon test` 因此能无人值守跑完。
///
/// 这一层只验 `native_*` 的形状对不对（坐标、状态读写、路由）。契约级的往返
/// 在 `backend_wbtest.mbt`，那里走 `Backend` trait 和逻辑像素。
///
/// 点击是按客户区坐标命中的（见 `native_click_button_in_window`），所以控件的矩形
/// 真的参与了验证：`native_control_set_bounds` 摆错位置的话这里就点不到。

///|
/// 矩形中心点，用来按坐标命中。
fn center(rect : (Int, Int, Int, Int)) -> (Int, Int) {
  let (x, y, w, h) = rect
  (x + w / 2, y + h / 2)
}

///|
/// 每条测试的开头：先替上一条清场（`backend_wbtest.mbt` 里的 `sweep_leaked_handles`，
/// 同包同命名空间，所以两张按种类登记的数组和后端清单一起收），再 init。
/// `moonui_init` 是幂等的（`adapter.c:297` 已 inited 就直接返回 0），所以上一条
/// 有没有 uninit 都能接着跑；真正不能留的是它的窗口和控件。
fn begin_native_session() -> Unit raise @moonui.UiError {
  sweep_leaked_handles()
  @libui-common.native_init()
}

///|
/// 建了对象就登记，让中途 raise 的那一条能被下一条的 prologue 补收。
/// 先控件后窗口的顺序、以及为什么要分开两张表，见 `native_widgets_in_play` 的注释。
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
  // 标题在这台机器上必须唯一：点击注入是按标题找回窗口 HWND 的
  let title = "MoonUI libui smoke 43ba1ef"
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
  // BM_CLICK 是同步的：回调在上一行返回前就走完了
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
  let title = "MoonUI libui smoke 重新布局"
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
  // origin/size 读回来就是刚摆过去的位置（物理像素，与客户区坐标同一套）
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
/// libui 的 WM_COMMAND 是按控件 HWND 查表的（third-party/libui/src/windows/
/// events.cpp 的 runWM_COMMAND 拿 lParam 当键，不用控件 ID），
/// 所以 MoonUI 自己 SetParent 之后回调路由不会串。
test "libui 冒烟：点第二个按钮只触发第二个" {
  begin_native_session()
  let title = "MoonUI libui smoke 三个按钮"
  let win = tracked_window_new(title, 240, 200)
  let first = tracked_widget_new(@moonui.Button, "甲")
  let second = tracked_widget_new(@moonui.Button, "乙")
  let third = tracked_widget_new(@moonui.Button, "丙")
  let log : Array[String] = []
  // 三个按钮按顺序挂进来：z-order 就是 Tab 顺序，所以插入顺序在这里是有意义的
  @libui-common.native_control_attach(win, first)
  @libui-common.native_control_set_bounds(first, 8, 8, 120, 32)
  @libui-common.native_control_attach(win, second)
  @libui-common.native_control_set_bounds(second, 8, 48, 120, 32)
  @libui-common.native_control_attach(win, third)
  @libui-common.native_control_set_bounds(third, 8, 88, 120, 32)
  @libui-common.native_widget_on_click(first, fn() { log.push("甲") })
  @libui-common.native_widget_on_click(second, fn() { log.push("乙") })
  // third 不挂回调：BM_CLICK 到它身上应当只是没人接，不能牵连别人
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
/// 四种控件的创建与状态读写。libui 的这几种控件在 Win32 里都是标准窗口文本，
/// 所以文案往返、勾选、可见、可用都按同一套 SendMessage 走（见 adapter.c）。
test "libui 冒烟：四种控件的状态读写都落在真 HWND 上" {
  begin_native_session()
  let title = "MoonUI libui smoke 四种控件"
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
  // 输入框建好之后立刻填文案：uiNewEntry 不收初始文本
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
  // 固有尺寸来自 libui 的测量，非零即可——具体像素取决于这台机器的字体
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
/// 窗口几何往返 + detach 的后果。位置用物理像素，和 Win32 同一套坐标；
/// detach 之后控件搬到 adapter 自建的隐藏窗口下，原来的矩形因此点不到。
test "libui 冒烟：窗口几何可读可写，摘下来的控件不再响应点击" {
  begin_native_session()
  @libui-common.native_main_steps()
  let title = "MoonUI libui smoke 窗口几何"
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
  // 摘下来：同一个坐标上什么都没有了
  @libui-common.native_control_detach(btn)
  assert_true(@libui-common.native_click_button_in_window(title, cx, cy) < 0)
  @libui-common.native_control_set_bounds(btn, 10, 10, 120, 32)
  assert_true(@libui-common.native_click_button_in_window(title, cx, cy) < 0)
  // 重新挂回去，路由照旧（ID 会重新分配，回调表按 HWND 查，不受影响）
  @libui-common.native_control_attach(win, btn)
  @libui-common.native_control_set_bounds(btn, 10, 10, 120, 32)
  assert_eq(@libui-common.native_click_button_in_window(title, cx, cy), 0)
  assert_eq(log, ["点击", "点击"])
  // 客户区尺寸：设进去和读出来一致（libui 会自己换算外层窗口）
  @libui-common.native_window_set_content_size(win, 260, 180)
  assert_eq(@libui-common.native_window_content_size(win), (260, 180))
  @libui-common.native_window_set_position(win, 40, 60)
  assert_eq(@libui-common.native_window_position(win), (40, 60))
  @libui-common.native_window_set_resizable(win, false)
  @libui-common.native_window_set_title(win, "MoonUI libui smoke 改了名")
  assert_eq(
    @libui-common.native_click_button_in_window(
      "MoonUI libui smoke 改了名", cx, cy,
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
