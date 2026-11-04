///|
/// 跨控件拖放会话的行为判据（`T102` 第二十四刀，纯 Core，零 ABI）：会话内
/// 移动改发 `DragOver`、左键抬起改发 `DragDrop` 并收会话、空白处不放不发但
/// 会话照收、长按识别被会话取消。命中测试走 Core 既有 `Window::widget_at`
/// （绘制顺序里最后一个含住点的叶子），判据只验 Core 侧路由。

///|
/// 会话全流程：按下里发起 → 移动发给光标下的目标控件（每次移动都发）→
/// 抬起落给命中控件、会话收掉 → 会话外移动恢复普通路由。
test "drag：会话内 DragOver / 抬起 DragDrop / 会话收尾（T102 第二十四刀）" {
  let app = api_app()
  let b = app.backend()
  let win = app.create_window("drag", @moonui.LogicalSize(200.0, 200.0))
  let src = @moonui.Widget::label(b, "源")
  let dst = @moonui.Widget::label(b, "目标")
  win.set_content(@moonui.Widget::column(b, 0.0, [src, dst]))
  win.show()
  let _ = app.step()
  let t_src = @moonui.EventTarget::of(src.handle.unwrap())
  let t_dst = @moonui.EventTarget::of(dst.handle.unwrap())
  // 摆出来了才谈得上命中：frame 是空的就没法选点
  let f_src = src.frame()
  let f_dst = dst.frame()
  assert_true(f_dst.size.height > 0.0)
  let p_in_src = @moonui.LogicalPoint(
    f_src.origin.x + 1.0,
    f_src.origin.y + 1.0,
  )
  let p_in_dst = @moonui.LogicalPoint(
    f_dst.origin.x + 1.0,
    f_dst.origin.y + 1.0,
  )
  let over_log : Array[@moonui.LogicalPoint] = []
  let drop_log : Array[String] = []
  let _ = app.on(
    t_dst,
    fn(e : @moonui.Event) -> Bool {
      e is @moonui.DragOver(_, _, _) || e is @moonui.DragDrop(_, _, _)
    },
    fn(e : @moonui.Event) {
      match e {
        @moonui.DragOver(_, p, _) => over_log.push(p)
        @moonui.DragDrop(_, _, pl) => drop_log.push(pl)
        _ => ()
      }
    },
  )
  // 源控件在按下里发起会话（典型用法：按下 / 过阈后首条移动里 begin_drag）
  let begun = [false]
  let _ = app.on(
    t_src,
    fn(e : @moonui.Event) -> Bool { e is @moonui.MouseDown(_, _, _, _) },
    fn(_) { begun[0] = app.begin_drag("item-7") },
  )
  assert_false(app.drag_active())
  let _ = app.dispatch(
    @moonui.MouseDown(t_src, @moonui.Left, p_in_src, @moonui.Mods::none()),
  )
  assert_true(begun[0])
  assert_true(app.drag_active())
  // 会话内移动：事件 target 还是源控件（真机上指针捕获归源面），Core 改发给
  // 光标下的目标控件——每次移动都发，载荷原样携带
  let _ = app.dispatch(@moonui.MouseMove(t_src, p_in_dst))
  let _ = app.dispatch(@moonui.MouseMove(t_src, p_in_dst))
  assert_eq(over_log.length(), 2)
  // 左键抬起：落点控件收 DragDrop，会话当场收掉
  let _ = app.dispatch(
    @moonui.MouseUp(t_src, @moonui.Left, p_in_dst, @moonui.Mods::none()),
  )
  assert_eq(drop_log, ["item-7"])
  assert_false(app.drag_active())
  // 会话外的移动恢复普通路由：不再产生 DragOver
  let _ = app.dispatch(@moonui.MouseMove(t_dst, p_in_dst))
  assert_eq(over_log.length(), 2)
}

///|
/// 放在空白处：不产 DragDrop（放哪儿了没人接），但会话照样结束——
/// "拖出去松手"不是"拖着不放"。
test "drag：空白处松手不发 DragDrop、会话照收（T102 第二十四刀）" {
  let app = api_app()
  let b = app.backend()
  let win = app.create_window("drag-blank", @moonui.LogicalSize(200.0, 300.0))
  let src = @moonui.Widget::label(b, "源")
  win.set_content(@moonui.Widget::column(b, 0.0, [src]))
  win.show()
  let _ = app.step()
  let t_src = @moonui.EventTarget::of(src.handle.unwrap())
  let f_src = src.frame()
  let p_in_src = @moonui.LogicalPoint(
    f_src.origin.x + 1.0,
    f_src.origin.y + 1.0,
  )
  let drop_log : Array[String] = []
  let _ = app.on(
    t_src,
    fn(e : @moonui.Event) -> Bool { e is @moonui.DragDrop(_, _, _) },
    fn(e : @moonui.Event) {
      match e {
        @moonui.DragDrop(_, _, pl) => drop_log.push(pl)
        _ => ()
      }
    },
  )
  let begun = [false]
  let _ = app.on(
    t_src,
    fn(e : @moonui.Event) -> Bool { e is @moonui.MouseDown(_, _, _, _) },
    fn(_) { begun[0] = app.begin_drag("x") },
  )
  let _ = app.dispatch(
    @moonui.MouseDown(t_src, @moonui.Left, p_in_src, @moonui.Mods::none()),
  )
  assert_true(begun[0])
  assert_true(app.drag_active())
  // 窗口右下角空白处松手（内容只有一只 label，够不着那里）
  let _ = app.dispatch(
    @moonui.MouseUp(
      t_src,
      @moonui.Left,
      @moonui.LogicalPoint(199.0, 299.0),
      @moonui.Mods::none(),
    ),
  )
  assert_eq(drop_log.length(), 0)
  assert_false(app.drag_active())
}

///|
/// begin_drag 的两格如实拒绝：会话已在跑（DragOver 的 handler 里再发起）、
/// 不在任何事件派发中（post 的任务里调，锚不到窗口）。
test "drag：begin_drag 两格如实拒绝（T102 第二十四刀）" {
  let app = api_app()
  let b = app.backend()
  let win = app.create_window("drag-refuse", @moonui.LogicalSize(200.0, 200.0))
  let src = @moonui.Widget::label(b, "源")
  let dst = @moonui.Widget::label(b, "目标")
  win.set_content(@moonui.Widget::column(b, 0.0, [src, dst]))
  win.show()
  let _ = app.step()
  // 格 1：不在派发中
  assert_false(app.begin_drag("x"))
  let t_src = @moonui.EventTarget::of(src.handle.unwrap())
  let t_dst = @moonui.EventTarget::of(dst.handle.unwrap())
  let f_dst = dst.frame()
  let p_in_dst = @moonui.LogicalPoint(
    f_dst.origin.x + 1.0,
    f_dst.origin.y + 1.0,
  )
  let refused : Array[Bool] = []
  let _ = app.on(
    t_dst,
    fn(e : @moonui.Event) -> Bool { e is @moonui.DragOver(_, _, _) },
    fn(_) { refused.push(app.begin_drag("y")) },
  )
  let begun = [false]
  let _ = app.on(
    t_src,
    fn(e : @moonui.Event) -> Bool { e is @moonui.MouseDown(_, _, _, _) },
    fn(_) { begun[0] = app.begin_drag("item") },
  )
  let _ = app.dispatch(
    @moonui.MouseDown(
      t_src,
      @moonui.Left,
      @moonui.LogicalPoint(1.0, 1.0),
      @moonui.Mods::none(),
    ),
  )
  assert_true(begun[0])
  // 会话中的移动 → dst 收 DragOver，handler 里再发起 = 格 2 的拒绝
  let _ = app.dispatch(@moonui.MouseMove(t_src, p_in_dst))
  assert_eq(refused, [false])
  assert_true(app.drag_active())
}

///|
/// 拖动开始即取消长按识别：按住后发起会话，推进过阈值也不会补发 LongPress
/// ——拖着走的按住不是长按，两套语义不并行。
test "drag：begin_drag 取消长按识别（T102 第二十四刀）" {
  let app = api_app()
  let b = app.backend()
  let now = [0]
  app.set_anim_clock(fn() { now[0] })
  let win = app.create_window(
    "drag-longpress",
    @moonui.LogicalSize(200.0, 200.0),
  )
  let src = @moonui.Widget::label(b, "源")
  let dst = @moonui.Widget::label(b, "目标")
  win.set_content(@moonui.Widget::column(b, 0.0, [src, dst]))
  win.show()
  let _ = app.step()
  let t_src = @moonui.EventTarget::of(src.handle.unwrap())
  let press : Array[@moonui.Event] = []
  let _ = app.on(
    t_src,
    fn(e : @moonui.Event) -> Bool { e is @moonui.LongPress(_) },
    fn(e : @moonui.Event) { press.push(e) },
  )
  let begun = [false]
  let _ = app.on(
    t_src,
    fn(e : @moonui.Event) -> Bool { e is @moonui.MouseDown(_, _, _, _) },
    fn(_) { begun[0] = app.begin_drag("x") },
  )
  now[0] = 0
  let _ = app.dispatch(
    @moonui.MouseDown(
      t_src,
      @moonui.Left,
      @moonui.LogicalPoint(1.0, 1.0),
      @moonui.Mods::none(),
    ),
  )
  assert_true(begun[0])
  // 推进过阈值（≥400ms）：识别账已被会话清掉，不补发
  now[0] = 500
  assert_false(app.step())
  assert_eq(press.length(), 0)
}
