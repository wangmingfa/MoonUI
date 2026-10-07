///|
/// §48 第 03 步的里程碑验证：真窗口、真按钮、真点击、关闭后句柄归零。
///
/// 这几条测试会在桌面上真的开窗口——`BM_CLICK` 要求按钮有真实的 Win32 父级，
/// 点击消息才会走 libui 自己的 WM_COMMAND 路由，而不是把回调函数直接调一遍。
/// 窗口在同一条测试里就关掉，不阻塞、不等人工操作，`moon test` 因此能无人值守跑完。
///
/// 点击是按客户区坐标命中的（见 `click_button_in_window`），所以控件的矩形
/// 真的参与了验证：`attach_control` 摆错位置的话这里就点不到。

///|
/// 矩形中心点，用来按坐标命中。
fn center(rect : (Int, Int, Int, Int)) -> (Int, Int) {
  let (x, y, w, h) = rect
  (x + w / 2, y + h / 2)
}

///|
test "libui 冒烟：真按钮被点一次，句柄全部回收" {
  initialize()
  // 标题在这台机器上必须唯一：点击注入是按标题找回窗口 HWND 的
  let title = "MoonUI libui smoke 43ba1ef"
  let win = create_window(title, 240, 120)
  let btn = create_button("按下我")
  attach_control(win, btn, 8, 8, 120, 32)
  let log : Array[String] = []
  button_on_click(btn, fn() { log.push("点击") })
  show_window(win)
  main_steps()
  let (cx, cy) = center((8, 8, 120, 32))
  assert_eq(click_button_in_window(title, cx, cy), 0)
  // BM_CLICK 是同步的：回调在上一行返回前就走完了
  assert_eq(log.length(), 1)
  // 空白处点不到任何按钮——这条保证上面那条 0 不是"随便点哪里都算命中"
  assert_true(click_button_in_window(title, 200, 100) < 0)
  // 文案往返同时验 UTF-8 进出；中文标题找得到窗口也顺带证明了这点
  assert_eq(button_text(btn), "按下我")
  set_button_text(btn, "点过了")
  assert_eq(button_text(btn), "点过了")
  hide_window(win)
  // §14 的代价：窗口不替控件收尾，控件必须在窗口之前逐个销毁
  destroy_button(btn)
  destroy_window(win)
  assert_eq(live_handles(), 0)
  terminate()
}

///|
/// 重新布局走的是同一条 attach：只改矩形，不重新排队 z-order。
/// 这里用命中测试证明控件真的搬到了新位置——旧位置点不到，新位置点得到。
test "libui 冒烟：重新布局会把控件搬到新矩形" {
  initialize()
  let title = "MoonUI libui smoke 重新布局"
  let win = create_window(title, 240, 200)
  let btn = create_button("搬家")
  let log : Array[String] = []
  attach_control(win, btn, 8, 8, 120, 32)
  button_on_click(btn, fn() { log.push("点击") })
  show_window(win)
  main_steps()
  let (ox, oy) = center((8, 8, 120, 32))
  assert_eq(click_button_in_window(title, ox, oy), 0)
  assert_eq(log, ["点击"])
  attach_control(win, btn, 60, 90, 120, 32)
  assert_true(click_button_in_window(title, ox, oy) < 0)
  let (nx, ny) = center((60, 90, 120, 32))
  assert_eq(click_button_in_window(title, nx, ny), 0)
  assert_eq(log, ["点击", "点击"])
  hide_window(win)
  destroy_button(btn)
  destroy_window(win)
  assert_eq(live_handles(), 0)
  terminate()
}

///|
/// 多个真控件挂在同一个窗口下时，点击仍然只落到被点的那一个：
/// libui 的 WM_COMMAND 是按控件 HWND 查表的（third-party/libui/src/windows/
/// events.cpp 的 runWM_COMMAND 拿 lParam 当键，不用控件 ID），
/// 所以 MoonUI 自己 SetParent 之后回调路由不会串。
test "libui 冒烟：点第二个按钮只触发第二个" {
  initialize()
  let title = "MoonUI libui smoke 三个按钮"
  let win = create_window(title, 240, 200)
  let first = create_button("甲")
  let second = create_button("乙")
  let third = create_button("丙")
  let log : Array[String] = []
  attach_control(win, first, 8, 8, 120, 32)
  attach_control(win, second, 8, 48, 120, 32)
  attach_control(win, third, 8, 88, 120, 32)
  button_on_click(first, fn() { log.push("甲") })
  button_on_click(second, fn() { log.push("乙") })
  // third 不挂回调：BM_CLICK 到它身上应当只是没人接，不能牵连别人
  show_window(win)
  main_steps()
  let (cx, cy) = center((8, 48, 120, 32))
  assert_eq(click_button_in_window(title, cx, cy), 0)
  assert_eq(log, ["乙"])
  let (ex, ey) = center((8, 88, 120, 32))
  assert_eq(click_button_in_window(title, ex, ey), 0)
  let _ = main_step(false)
  assert_eq(log, ["乙"])
  hide_window(win)
  destroy_button(third)
  destroy_button(second)
  destroy_button(first)
  destroy_window(win)
  assert_eq(live_handles(), 0)
  terminate()
}
