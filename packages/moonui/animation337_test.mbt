// 动画扩容（T337）的黑盒测试：时长参数、重复模式、前景色账。全部走公共 API，
// 在 MockBackend 上跑；驱动器形状照 `animation_test.mbt`（T84）——时刻是测试
// 注入的参数，动画模块一行不读时钟。

///|
/// 把句柄收成语明（animation_test 同形）。
fn t337_handle(
  w : @moonui.Widget[@moonui.MockBackend],
) -> @moonui.NativeHandle raise Error {
  match w.handle() {
    Some(h) => h
    None => raise @moonui.InvalidHandle
  }
}

///|
/// 判据：anim_phase 纯函数——Once 端点精确、Loop 取模回绕、PingPong 折返镜像。
test "T337 anim_phase：Once 端点精确、Loop 回绕、PingPong 镜像" {
  // Once：播完退场，退场相位恒 1
  assert_eq(@moonui.anim_phase(@moonui.Once, 0, 300), (0.0, false))
  assert_eq(@moonui.anim_phase(@moonui.Once, 299, 300), (299.0 / 300.0, false))
  assert_eq(@moonui.anim_phase(@moonui.Once, 300, 300), (1.0, true))
  assert_eq(@moonui.anim_phase(@moonui.Once, 1000, 300), (1.0, true))
  // Loop：取模回绕，永不退场
  assert_eq(@moonui.anim_phase(@moonui.Loop, 0, 300), (0.0, false))
  assert_eq(@moonui.anim_phase(@moonui.Loop, 300, 300), (0.0, false))
  assert_eq(@moonui.anim_phase(@moonui.Loop, 350, 300), (50.0 / 300.0, false))
  // PingPong：前半程正播、后半程镜像折返，端点 k=1 恰好是精确 to
  assert_eq(@moonui.anim_phase(@moonui.PingPong, 0, 300), (0.0, false))
  assert_eq(@moonui.anim_phase(@moonui.PingPong, 150, 300), (0.5, false))
  assert_eq(@moonui.anim_phase(@moonui.PingPong, 300, 300), (1.0, false))
  assert_eq(@moonui.anim_phase(@moonui.PingPong, 450, 300), (0.5, false))
  assert_eq(@moonui.anim_phase(@moonui.PingPong, 600, 300), (0.0, false))
  // 零/负时长：不造"零时长动画"，当圈退场
  assert_eq(@moonui.anim_phase(@moonui.Once, 0, 0), (1.0, true))
}

///|
/// 判据：`.animation_ms` 的自定义时长——150ms 的账在 200ms 已退场（300ms 默认档
/// 还在中途），落点与无动画树逐位同值。
test "T337 animation_ms：自定义时长推进，落点精确" {
  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  let app = @moonui.App(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let wake : Array[Bool] = []
  app.set_anim_wake(fn(active) { wake.push(active) })
  let win = app.create_window("时长", @moonui.LogicalSize(200.0, 100.0))
  let label = @moonui.Widget::label(b, "Ab").animation_ms(
    @moonui.EaseInOut,
    150,
  )
  let sp = @moonui.Widget::spacer(b)
  win.set_content(@moonui.Widget::row(b, 0.0, [sp, label]))
  @moonui.Backend::set_window_size(
    b,
    win.handle(),
    @moonui.LogicalSize(300.0, 100.0),
  )
  b.push_event(@moonui.Resize(win.target(), @moonui.LogicalSize(300.0, 100.0)))
  assert_true(app.step())
  let h = t337_handle(label)
  // 变更圈：起跑零推送
  let at_100 = @moonui.Backend::widget_bounds(b, h).origin.x
  cell[0] = 100
  let _ = app.step()
  let mid = @moonui.Backend::widget_bounds(b, h).origin.x
  assert_true(mid > at_100)
  assert_true(mid < 276.0)
  // 200ms > 150ms：已退场，落点逐位精确
  cell[0] = 200
  let _ = app.step()
  assert_eq(@moonui.Backend::widget_bounds(b, h).origin.x, 276.0)
  // 退场后再推零变化（账清零）
  cell[0] = 400
  let _ = app.step()
  assert_eq(@moonui.Backend::widget_bounds(b, h).origin.x, 276.0)
  let _ = wake
}

///|
/// 判据：Loop 永不退场——越过默认档时长后相位回绕、往返振荡，wake 不发退场沿。
test "T337 Loop：跨周期回绕振荡，不退场" {
  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  let app = @moonui.App(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let wake : Array[Bool] = []
  app.set_anim_wake(fn(active) { wake.push(active) })
  let win = app.create_window("循环", @moonui.LogicalSize(200.0, 100.0))
  let label = @moonui.Widget::label(b, "Ab").animation_ms(
    @moonui.Linear,
    100,
    repeat=@moonui.Loop,
  )
  let sp = @moonui.Widget::spacer(b)
  win.set_content(@moonui.Widget::row(b, 0.0, [sp, label]))
  @moonui.Backend::set_window_size(
    b,
    win.handle(),
    @moonui.LogicalSize(300.0, 100.0),
  )
  b.push_event(@moonui.Resize(win.target(), @moonui.LogicalSize(300.0, 100.0)))
  assert_true(app.step())
  let h = t337_handle(label)
  cell[0] = 100
  let _ = app.step()
  let x100 = @moonui.Backend::widget_bounds(b, h).origin.x
  // 300ms = 三个整周期：相位回绕回起点附近；绝不是落点 276（Once 在这时已退场）
  cell[0] = 300
  let _ = app.step()
  let x300 = @moonui.Backend::widget_bounds(b, h).origin.x
  assert_eq(x100, x300)
  assert_true(x300 < 276.0)
  // wake 只在激活沿发过一次 true，没有退场 false
  assert_eq(wake, [true])
}

///|
/// 判据：前景色账——样式解析出的前景变了、控件配了动画，变更点记账、显示归泵；
/// 中间帧是混合色、退场推精确 to、账清零后与无动画树同值。
test "T337 前景色账：中间帧混合、退场精确、重排不扰动" {
  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  let app = @moonui.App(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let win = app.create_window("颜色", @moonui.LogicalSize(200.0, 100.0))
  let label = @moonui.Widget::label(b, "Ab").animation_ms(@moonui.Linear, 100)
  // 首推建立初始态：黑字
  label.set_style(
    Some(@moonui.style(foreground=Some(@moonui.Color::rgb(0, 0, 0)))),
  )
  win.set_content(@moonui.Widget::row(b, 0.0, [label]))
  // 与 T84 驱动器同一条口径：初始装载也要一圈事件驱动的重排，样式才真下发
  b.push_event(@moonui.Resize(win.target(), @moonui.LogicalSize(200.0, 100.0)))
  assert_true(app.step())
  let h = t337_handle(label)
  let fg_now = fn() raise {
    match b.style_of(h) {
      Some(s) =>
        match s.foreground {
          Some(c) => c
          None => @moonui.Color::rgb(255, 255, 255)
        }
      None => @moonui.Color::rgb(255, 255, 255)
    }
  }
  assert_eq(fg_now(), @moonui.Color::rgb(0, 0, 0))
  // 变更点：黑 → 深蓝。记账当圈显示仍是 shown（黑），落点由泵逐帧追
  label.set_style(
    Some(@moonui.style(foreground=Some(@moonui.Color::rgb(100, 0, 0)))),
  )
  b.push_event(@moonui.Resize(win.target(), @moonui.LogicalSize(200.0, 100.0)))
  assert_true(app.step())
  assert_eq(fg_now(), @moonui.Color::rgb(0, 0, 0))
  // 50ms：Linear 中点 = (50,0,0)
  cell[0] = 50
  let _ = app.step()
  assert_eq(fg_now(), @moonui.Color::rgb(50, 0, 0))
  // 激活期里的无关重排（同一变更点再来一次）：显示仍归泵，不跳
  b.push_event(@moonui.Resize(win.target(), @moonui.LogicalSize(200.0, 100.0)))
  assert_true(app.step())
  assert_eq(fg_now(), @moonui.Color::rgb(50, 0, 0))
  // 100ms：退场推精确 to，账清零
  cell[0] = 100
  let _ = app.step()
  assert_eq(fg_now(), @moonui.Color::rgb(100, 0, 0))
  cell[0] = 500
  let _ = app.step()
  assert_eq(fg_now(), @moonui.Color::rgb(100, 0, 0))
}
