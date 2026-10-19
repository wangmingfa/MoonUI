///|
/// 皮肤通道的行为判据（悬停 + Panel）：悬停账翻面与 Enter/Leave 补发、
/// Panel 的矩形写回与 padding 内缩。样式在 mock 后端的存取判据在
/// mock_widget 自己的账里，这里只验 Core 侧行为。

///|
/// 两个按钮，鼠标移动事件换目标：hovered 翻面、Leave/Enter 补发；
/// 移到空白（窗口自己）= unhover。
test "hover：MouseMove 换目标翻面 + Enter/Leave 补发" {
  let app = api_app()
  let b = app.backend()
  let win = app.create_window("hover", @moonui.LogicalSize(400.0, 300.0))
  let btn_a = @moonui.Widget::button(b, "A")
  let btn_b = @moonui.Widget::button(b, "B")
  win.set_content(@moonui.Widget::column(b, 0.0, [btn_a, btn_b]))
  win.show()
  let t_a = @moonui.EventTarget::of(btn_a.handle.unwrap())
  let t_b = @moonui.EventTarget::of(btn_b.handle.unwrap())
  // 观察账：A 上收 Enter/Leave 各几条
  let log : Array[String] = []
  let _ = app.on(
    t_a,
    fn(e : @moonui.Event) -> Bool {
      e is @moonui.MouseEnter(_) || e is @moonui.MouseLeave(_)
    },
    fn(e : @moonui.Event) {
      match e {
        @moonui.MouseEnter(_) => log.push("enter")
        @moonui.MouseLeave(_) => log.push("leave")
        _ => ()
      }
    },
  )
  let _ = app.dispatch(@moonui.MouseMove(t_a, @moonui.LogicalPoint(1.0, 1.0)))
  assert_true(btn_a.hovered)
  assert_eq(log, ["enter"])
  // 换到 B：A 摘、B 挂，A 的观察账里多一条 leave
  let _ = app.dispatch(@moonui.MouseMove(t_b, @moonui.LogicalPoint(1.0, 50.0)))
  assert_false(btn_a.hovered)
  assert_true(btn_b.hovered)
  assert_eq(log, ["enter", "leave"])
  // 移到窗口自己（空白）：全部摘掉
  let _ = app.dispatch(
    @moonui.MouseMove(win.target(), @moonui.LogicalPoint(399.0, 299.0)),
  )
  assert_false(btn_b.hovered)
  // 再移回 A：重新挂上
  let _ = app.dispatch(@moonui.MouseMove(t_a, @moonui.LogicalPoint(1.0, 1.0)))
  assert_true(btn_a.hovered)
  assert_eq(log, ["enter", "leave", "enter"])
}

///|
/// 悬停样式只在 hovered 时进层叠（resolved_style 判据），翻面由悬停账推。
test "hover：hover_style 只在悬停时进层叠" {
  let app = api_app()
  let b = app.backend()
  let win = app.create_window("hover-style", @moonui.LogicalSize(400.0, 300.0))
  let btn = @moonui.Widget::button(b, "A")
  btn.set_hover_style(
    Some(@moonui.style(background=Some(@moonui.Color::rgb(1, 2, 3)))),
  )
  win.set_content(btn)
  win.show()
  let base = app.style_base()
  let plain = btn.resolved_style(base)
  assert_eq(plain.background, base.background)
  let t = @moonui.EventTarget::of(btn.handle.unwrap())
  let _ = app.dispatch(@moonui.MouseMove(t, @moonui.LogicalPoint(1.0, 1.0)))
  let hot = btn.resolved_style(base)
  assert_eq(hot.background, Some(@moonui.Color::rgb(1, 2, 3)))
}

///|
/// Panel：占原生对象（有句柄）、矩形写回、padding 从样式里取、子树照常
/// 布局（单子容器，Scroll 的认领同款但不滚动）。
test "panel：矩形写回 + padding 内缩" {
  let app = api_app()
  let b = app.backend()
  let win = app.create_window("panel", @moonui.LogicalSize(400.0, 300.0))
  let label = @moonui.Widget::label(b, "内容")
  let panel = @moonui.Widget::panel(b, @moonui.Widget::column(b, 0.0, [label]))
  panel.set_style(
    Some(
      @moonui.style(
        padding=Some(@moonui.EdgeInsets::all(10.0)),
        background=Some(@moonui.Color::rgb(250, 250, 251)),
      ),
    ),
  )
  win.set_content(panel)
  win.show()
  assert_true(panel.handle is Some(_))
  let _ = app.step()
  // 面板铺满内容区，label 按面板 padding 内缩
  assert_eq(
    panel.frame,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(400.0, 300.0),
    ),
  )
  assert_eq(label.frame.origin.x, 10.0)
  assert_eq(label.frame.origin.y, 10.0)
}

///|
/// Enter/Leave 的 target 判据（新事件的 Event::target 读法）。
test "hover：Enter/Leave 走 Event::target" {
  let t = @moonui.EventTarget::{ id: 7, generation: 1, }
  assert_eq(@moonui.Event::target(@moonui.MouseEnter(t)), t)
  assert_eq(@moonui.Event::target(@moonui.MouseLeave(t)), t)
  assert_false(@moonui.Event::is_mouse_press(@moonui.MouseEnter(t)))
}
