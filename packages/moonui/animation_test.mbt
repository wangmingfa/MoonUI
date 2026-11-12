// 动画第一版（T84）的黑盒测试：全部走公共 API，在 MockBackend 上跑。
// 判据全在 TODO 条目里：
//   ① Mock 上动画是纯函数——同一棵树、同一变更点、同一曲线，断言**中间帧序列**
//     （时间→值插值逐帧可断言；时刻是测试注入的参数，动画模块不读时钟）；
//   ② 落点断言——真后端没法断言中间帧，落点用现有 geometry 读回（本文件先钉
//     mock 形：`widget_bounds` 逐位落点；native 那半同一通道，欠真窗口跑）；
//   ③ 每帧推送走现有 ABI 的**计数断言**——激活期每帧恰好一批推送、退场后零推送；
//   ④ 动画退场断言——落点后状态与无动画树**逐位同值**（"动画是糖，落点即真相"）。
// 激活期等待预算改短的断言（Mock 侧可模拟）与零开销负控制也在本文件。

///|
/// 把句柄收成语明（api_test 同形）。
fn anim_handle(
  w : @moonui.Widget[@moonui.MockBackend],
) -> @moonui.NativeHandle raise Error {
  match w.handle() {
    Some(h) => h
    None => raise @moonui.InvalidHandle
  }
}

///|
/// 判据① + 时钟域基准的驱动器：同一棵树（row + spacer + 配了曲线的 label）、同一个
/// 变更点（窗口 200→300 的 Resize，label 从 x=176 挪到 x=276）、同一串注入
/// 时刻，跑完整段动画。返回逐圈读回的 `widget_bounds(...).origin.x`——
/// 时间→值的帧序列；`wake` 收帧钟开关的切换沿（激活 true / 全退场 false）。
/// 时刻走测试自控的数组格（引用语义），动画模块一行不读时钟。
/// `base` 是整条时钟域的起点平移（`T219`：native 的 `native_time_ms` 开机满
/// 2^31 毫秒后转负，判据要在负数域再跑一遍）。
fn drive_frames_at(
  base : Int32,
  curve : @moonui.AnimationCurve,
  wake : Array[Bool],
) -> Array[Double] raise Error {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [base]
  app.set_anim_clock(fn() { cell[0] })
  app.set_anim_wake(fn(active) { wake.push(active) })
  let win = app.create_window("动画", @moonui.LogicalSize(200.0, 100.0))
  let label = @moonui.Widget::label(b, "Ab").animation(curve)
  let sp = @moonui.Widget::spacer(b)
  win.set_content(@moonui.Widget::row(b, 0.0, [sp, label]))
  // 变更点：Resize 200→300。变更圈把变更点记成动画起点（起跑零推送——
  // 后端此刻显示的正是 from），之后的圈每圈一帧。
  @moonui.Backend::set_window_size(
    b,
    win.handle(),
    @moonui.LogicalSize(300.0, 100.0),
  )
  b.push_event(Resize(win.target(), @moonui.LogicalSize(300.0, 100.0)))
  assert_true(app.step())
  let h = anim_handle(label)
  let frames : Array[Double] = []
  for ms in [50, 100, 150, 200, 250, 300, 350, 400] {
    cell[0] = base + ms
    let _ = app.step()
    frames.push(@moonui.Backend::widget_bounds(b, h).origin.x)
  }
  frames
}

///|
fn drive_frames(
  curve : @moonui.AnimationCurve,
  wake : Array[Bool],
) -> Array[Double] raise Error {
  drive_frames_at(0, curve, wake)
}

///|
/// 判据① + ②的 mock 形：中间帧序列逐帧可断言（时间→值），同一棵树、同一
/// 变更点、同一曲线跑两遍序列逐位同值（纯函数），落点（300ms 后）逐位精确。
test "T84 判据①：中间帧序列逐帧可断言且是纯函数，落点精确" {
  let wake_a : Array[Bool] = []
  let wake_b : Array[Bool] = []
  let a = drive_frames(@moonui.EaseInOut, wake_a)
  let b = drive_frames(@moonui.EaseInOut, wake_b)
  // 纯函数：同输入（树/变更点/曲线/时刻串）同输出，逐位同值
  assert_eq(a.length(), b.length())
  for i = 0; i < a.length(); i = i + 1 {
    assert_eq(a[i], b[i])
  }
  // 逐帧账：from=176、to=276、时长 300，帧值 = 176 + 100·easeInOut(ms/300)，
  // 300ms 起退场推**精确的 to**（不做插值）。帧值用同一条 pub 曲线函数算，
  // 两侧是同一串确定的浮点运算，逐位相等。
  let expected : Array[Double] = []
  for ms in [50, 100, 150, 200, 250, 300, 350, 400] {
    if ms >= 300 {
      expected.push(276.0)
    } else {
      let k = @moonui.EaseInOut.progress(ms.to_double() / 300.0)
      expected.push(176.0 + (276.0 - 176.0) * k)
    }
  }
  assert_eq(a, expected)
  // 帧钟开关沿切换沿各发一次：激活 true、全退场 false，不许多
  assert_eq(wake_a, [true, false])
}

///|
/// 判据③：激活期每帧**恰好一批**推送（本树恰好 label 一条 bounds，走现有
/// ABI），退场帧恰好一条（精确落点），退场后零推送——不许多。
test "T84 判据③：激活期每帧恰好一批推送、退场后零推送" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let win = app.create_window("计数", @moonui.LogicalSize(200.0, 100.0))
  let label = @moonui.Widget::label(b, "Ab").animation(@moonui.Linear)
  let sp = @moonui.Widget::spacer(b)
  win.set_content(@moonui.Widget::row(b, 0.0, [sp, label]))
  let h = anim_handle(label)
  let log = b.bounds_push_log()
  let before = log.length()
  @moonui.Backend::set_window_size(
    b,
    win.handle(),
    @moonui.LogicalSize(300.0, 100.0),
  )
  b.push_event(Resize(win.target(), @moonui.LogicalSize(300.0, 100.0)))
  assert_true(app.step())
  // 变更圈：label 零推送（显示由泵逐帧追）；spacer 的重排推送是既有语义
  let mut label_pushes = 0
  for i = before; i < log.length(); i = i + 1 {
    let (id, _) = log[i]
    if id == h.id {
      label_pushes = label_pushes + 1
    }
  }
  assert_eq(label_pushes, 0)
  assert_eq(@moonui.Backend::widget_bounds(b, h).origin.x, 176.0)
  // 激活圈：每圈恰好一批 = 全树恰好一条推送，且就是 label 的那一帧
  let mut prev = log.length()
  for ms in [50, 100, 150, 200, 250] {
    cell[0] = ms
    let _ = app.step()
    assert_eq(log.length() - prev, 1)
    let (id, _) = log[log.length() - 1]
    assert_eq(id, h.id)
    prev = log.length()
  }
  // 退场圈：恰好一条，值是**精确的 to**
  cell[0] = 300
  assert_true(app.step())
  assert_eq(log.length() - prev, 1)
  let (last_id, last) = log[log.length() - 1]
  assert_eq(last_id, h.id)
  assert_eq(last.origin.x, 276.0)
  assert_eq(@moonui.Backend::widget_bounds(b, h).origin.x, 276.0)
  prev = log.length()
  // 退场后零推送：泵一圈只花一次旗标比较，一次 ABI 都不多花
  for ms in [350, 400, 450] {
    cell[0] = ms
    assert_false(app.step())
    assert_eq(log.length() - prev, 0)
    prev = log.length()
  }
}

///|
/// 判据④："动画是糖，落点即真相"——跑完整段动画的树与从未配过动画的同构树，
/// 同样的变更点之后，后端持有的 bounds 与 Core 的 frame 逐位同值；再改一次
/// 布局（退场后的变更直接落）仍然同值。opacity 通道也一样（配动画的树首推
/// 建立初值 1.0，无动画树是同值默认）。
test "T84 判据④：退场后与无动画树逐位同值" {
  // 两棵同构树，左配动画、右不配
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let win = app.create_window("配动画", @moonui.LogicalSize(200.0, 100.0))
  let label = @moonui.Widget::label(b, "Ab").animation(@moonui.EaseOut)
  let sp = @moonui.Widget::spacer(b)
  win.set_content(@moonui.Widget::row(b, 0.0, [sp, label]))
  let twin_b = @moonui.MockBackend::new()
  @moonui.Backend::init(twin_b)
  let twin_app = @moonui.App::new(twin_b)
  let twin_win = twin_app.create_window(
    "无动画",
    @moonui.LogicalSize(200.0, 100.0),
  )
  let twin = @moonui.Widget::label(twin_b, "Ab")
  let twin_sp = @moonui.Widget::spacer(twin_b)
  twin_win.set_content(@moonui.Widget::row(twin_b, 0.0, [twin_sp, twin]))
  let h = anim_handle(label)
  let twin_h = anim_handle(twin)
  // 同样的变更点：左跑完整段动画，右直接落
  @moonui.Backend::set_window_size(
    b,
    win.handle(),
    @moonui.LogicalSize(300.0, 100.0),
  )
  b.push_event(Resize(win.target(), @moonui.LogicalSize(300.0, 100.0)))
  let _ = app.step()
  for ms in [50, 150, 250, 300] {
    cell[0] = ms
    let _ = app.step()
  }
  @moonui.Backend::set_window_size(
    twin_b,
    twin_win.handle(),
    @moonui.LogicalSize(300.0, 100.0),
  )
  twin_b.push_event(
    Resize(twin_win.target(), @moonui.LogicalSize(300.0, 100.0)),
  )
  let _ = twin_app.step()
  // 落点对账：后端 bounds 逐位、Core frame 逐位、后端 opacity 逐位
  assert_eq(
    @moonui.Backend::widget_bounds(b, h),
    @moonui.Backend::widget_bounds(twin_b, twin_h),
  )
  assert_eq(label.frame(), twin.frame())
  assert_eq(b.widget(h).opacity, twin_b.widget(twin_h).opacity)
  // 退场后再来一次变更（300→400）：曲线还配着，新变更点照样新起一段——
  // 把时刻拨回 0 跑完这一段，仍然同值
  cell[0] = 0
  @moonui.Backend::set_window_size(
    b,
    win.handle(),
    @moonui.LogicalSize(400.0, 100.0),
  )
  b.push_event(Resize(win.target(), @moonui.LogicalSize(400.0, 100.0)))
  let _ = app.step()
  for ms in [50, 150, 250, 300] {
    cell[0] = ms
    let _ = app.step()
  }
  @moonui.Backend::set_window_size(
    twin_b,
    twin_win.handle(),
    @moonui.LogicalSize(400.0, 100.0),
  )
  twin_b.push_event(
    Resize(twin_win.target(), @moonui.LogicalSize(400.0, 100.0)),
  )
  let _ = twin_app.step()
  assert_eq(
    @moonui.Backend::widget_bounds(b, h),
    @moonui.Backend::widget_bounds(twin_b, twin_h),
  )
  assert_eq(label.frame(), twin.frame())
}

///|
/// opacity 通道（§32 豁免破的那条）：透明度是动画逐帧推进的值——激活期每帧
/// 一条 `set_widget_opacity`、退场帧推**精确落点**；样式写死的初值首推建立、
/// 不过渡（与 bounds 同一条规则）。
test "T84 opacity 通道：中间帧逐帧推、退场推精确落点" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let win = app.create_window("透明", @moonui.LogicalSize(200.0, 100.0))
  // 初值随样式建立（0.8 直接落，不过渡）
  let label = @moonui.Widget::label(b, "Ab")
    .animation(@moonui.Linear)
    .opacity(0.8)
  win.set_content(@moonui.Widget::column(b, 0.0, [label]))
  let h = anim_handle(label)
  assert_eq(b.widget(h).opacity, 0.8)
  let log = b.opacity_push_log()
  assert_eq(log.length(), 1)
  let _ = log[0].1 == 0.8
  // 变更点：改透明度 + 重排。变更圈记账零推送（起跑圈后端显示的正是 from），
  // 圈上没有别的事，step 返回 false——"这圈没进展"是正确语义。
  let _ = label.opacity(0.2)
  win.relayout()
  assert_false(app.step())
  assert_eq(log.length(), 1)
  // 激活圈：每圈恰好一条，值 = 0.8 + (0.2-0.8)·linear(ms/300)
  for ms in [50, 100, 150, 200, 250] {
    cell[0] = ms
    let _ = app.step()
    let k = @moonui.Linear.progress(ms.to_double() / 300.0)
    assert_eq(b.widget(h).opacity, 0.8 + (0.2 - 0.8) * k)
  }
  assert_eq(log.length(), 6)
  // 退场圈：精确落点 0.2（不做插值）
  cell[0] = 300
  assert_true(app.step())
  assert_eq(b.widget(h).opacity, 0.2)
  assert_eq(log.length(), 7)
  let (last_id, last) = log[log.length() - 1]
  assert_eq(last_id, h.id)
  assert_eq(last, 0.2)
  // 退场后零推送
  cell[0] = 350
  assert_false(app.step())
  assert_eq(log.length(), 7)
}

///|
/// 激活期等待预算改短的断言（Mock 侧可模拟——判据钉的就是帧钟开关的切换沿）：
/// 配了动画的树在激活沿发 true、全退场沿发 false；没配动画的树怎么推都不碰
/// 开关——预算改短只在真有动画时发生。
test "T84 等待预算：激活期改短、退场恢复，无动画的树不碰开关" {
  let wake_anim : Array[Bool] = []
  let _ = drive_frames(@moonui.EaseIn, wake_anim)
  assert_eq(wake_anim, [true, false])
  // 负控制：同构树不配动画——变更、重排、退场后的圈，开关一次都不响
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let wake : Array[Bool] = []
  app.set_anim_wake(fn(active) { wake.push(active) })
  let win = app.create_window("无动画", @moonui.LogicalSize(200.0, 100.0))
  let label = @moonui.Widget::label(b, "Ab")
  let sp = @moonui.Widget::spacer(b)
  win.set_content(@moonui.Widget::row(b, 0.0, [sp, label]))
  @moonui.Backend::set_window_size(
    b,
    win.handle(),
    @moonui.LogicalSize(300.0, 100.0),
  )
  b.push_event(Resize(win.target(), @moonui.LogicalSize(300.0, 100.0)))
  let _ = app.step()
  for ms in [50, 100, 150] {
    cell[0] = ms
    let _ = app.step()
  }
  assert_eq(wake, [])
}

///|
/// 零开销闸门：样式没写 opacity、控件也没配动画时，opacity 通道一个 FFI 都
/// 不花（通道未建立）；没配动画的变更点即落点（一次推送直接到位，没有中间帧）。
test "T84 零开销：无动画的树不碰动画通道，无曲线的变更直接落" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let win = app.create_window("零开销", @moonui.LogicalSize(200.0, 100.0))
  let label = @moonui.Widget::label(b, "Ab")
  let sp = @moonui.Widget::spacer(b)
  win.set_content(@moonui.Widget::row(b, 0.0, [sp, label]))
  let h = anim_handle(label)
  // 通道未建立：没写 opacity、没配动画，一次 opacity FFI 都没有
  assert_eq(b.opacity_push_log().length(), 0)
  // 没配曲线的变更点即落点：一次推送直接到位
  @moonui.Backend::set_window_size(
    b,
    win.handle(),
    @moonui.LogicalSize(300.0, 100.0),
  )
  b.push_event(Resize(win.target(), @moonui.LogicalSize(300.0, 100.0)))
  assert_true(app.step())
  assert_eq(@moonui.Backend::widget_bounds(b, h).origin.x, 276.0)
  assert_eq(b.opacity_push_log().length(), 0)
  for ms in [50, 100] {
    cell[0] = ms
    assert_false(app.step())
  }
  // 样式写了 opacity 但没配动画：变更直接落，同样没有中间帧（推送发生在
  // relayout 那一格，之后的圈无事可做）
  let _ = label.opacity(0.5)
  win.relayout()
  assert_false(app.step())
  assert_eq(b.widget(h).opacity, 0.5)
  assert_eq(b.opacity_push_log().length(), 1)
  for ms in [150, 200] {
    cell[0] = ms
    assert_false(app.step())
  }
  assert_eq(b.opacity_push_log().length(), 1)
}

///|
/// 时刻注入的退化形状：没接帧钟的 App 上 `.animation` 退化为"变更点当圈直接
/// 落"——推精确落点、账当圈清零，与无动画树逐位同值；帧钟开关一次都不响
/// （动画从未真正激活，预算不该改短）。
test "T84 无帧钟退化：变更点当圈直接落，开关不响" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let wake : Array[Bool] = []
  app.set_anim_wake(fn(active) { wake.push(active) })
  let win = app.create_window("没钟", @moonui.LogicalSize(200.0, 100.0))
  let label = @moonui.Widget::label(b, "Ab").animation(@moonui.EaseInOut)
  let sp = @moonui.Widget::spacer(b)
  win.set_content(@moonui.Widget::row(b, 0.0, [sp, label]))
  let h = anim_handle(label)
  let log = b.bounds_push_log()
  let before = log.length()
  @moonui.Backend::set_window_size(
    b,
    win.handle(),
    @moonui.LogicalSize(300.0, 100.0),
  )
  b.push_event(Resize(win.target(), @moonui.LogicalSize(300.0, 100.0)))
  assert_true(app.step())
  // 变更圈直接落精确落点：label 恰好一条推送、值就是 to
  let mut label_pushes = 0
  let mut last = 0.0
  for i = before; i < log.length(); i = i + 1 {
    let (id, r) = log[i]
    if id == h.id {
      label_pushes = label_pushes + 1
      last = r.origin.x
    }
  }
  assert_eq(label_pushes, 1)
  assert_eq(last, 276.0)
  assert_false(app.step())
  assert_eq(wake, [])
}

///|
/// 初次出现不过渡（与 SwiftUI 同一条规则）：配了动画的控件首推建立初始态
/// 直接落，set_content 的装载布局不做动画。
test "T84 初次出现不过渡：装载布局直接落" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let win = app.create_window("装载", @moonui.LogicalSize(200.0, 100.0))
  let label = @moonui.Widget::label(b, "Ab").animation(@moonui.EaseInOut)
  let sp = @moonui.Widget::spacer(b)
  let log = b.bounds_push_log()
  win.set_content(@moonui.Widget::row(b, 0.0, [sp, label]))
  let h = anim_handle(label)
  // 装载那一圈 label 直接落到位（x=176），恰好一次推送、没有 span
  let mut found = 0
  for entry in log {
    let (id, r) = entry
    if id == h.id {
      found = found + 1
      assert_eq(r.origin.x, 176.0)
    }
  }
  assert_eq(found, 1)
  cell[0] = 100
  assert_false(app.step())
  assert_eq(@moonui.Backend::widget_bounds(b, h).origin.x, 176.0)
}

///|
/// T87③ reduced-motion 判据（偏好开着起跑）：变更当圈推**精确的 to**、账
/// 当圈清零——没有中间帧，显示值不停在中间态（与无动画树逐位同值）。帧钟
/// 一次都不响：记账当圈收拾，激活沿从未真正立起（偏好开着动画零开销）。
/// 偏好关的负控制由既有 T84 判据块全程担任（它们从不注入偏好，默认 false）。
test "T87③ reduced-motion 开：变更当圈推精确落点、无中间帧、帧钟不响" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  b.set_prefers_reduced_motion(true)
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let wake : Array[Bool] = []
  app.set_anim_wake(fn(active) { wake.push(active) })
  let win = app.create_window("退场", @moonui.LogicalSize(200.0, 100.0))
  let label = @moonui.Widget::label(b, "Ab").animation(@moonui.EaseInOut)
  let sp = @moonui.Widget::spacer(b)
  win.set_content(@moonui.Widget::row(b, 0.0, [sp, label]))
  let h = anim_handle(label)
  let log = b.bounds_push_log()
  let before = log.length()
  // 变更点与既有判据同款：Resize 200→300，label 从 x=176 挪到 x=276
  @moonui.Backend::set_window_size(
    b,
    win.handle(),
    @moonui.LogicalSize(300.0, 100.0),
  )
  b.push_event(Resize(win.target(), @moonui.LogicalSize(300.0, 100.0)))
  assert_true(app.step())
  // 变更圈：label 恰好一条推送、值就是精确的 to——没有起跑圈、没有中间帧
  let mut label_pushes = 0
  let mut last = 0.0
  for i = before; i < log.length(); i = i + 1 {
    let (id, r) = log[i]
    if id == h.id {
      label_pushes = label_pushes + 1
      last = r.origin.x
    }
  }
  assert_eq(label_pushes, 1)
  assert_eq(last, 276.0)
  assert_eq(@moonui.Backend::widget_bounds(b, h).origin.x, 276.0)
  // 帧钟不响：偏好开着动画从未真正激活，预算零开销
  assert_eq(wake, [])
  // 账已清零：之后的圈零推送（退场后零开销同款账）
  cell[0] = 400
  assert_false(app.step())
  assert_false(app.step())
  assert_eq(log.length(), before + label_pushes)
}

///|
/// T87③ reduced-motion 判据（偏好进行中开）：起跑照旧逐帧（偏好关的那段
/// 就是 T84 既有路径原样），偏好开着的那圈把进行中的账当圈推**精确的 to**、
/// 账清零；退场沿恰好一条 wake(false)（激活沿在起跑圈照旧发过 wake(true)）
/// ——帧钟在那圈恢复零开销。之后零推送。
test "T87③ reduced-motion 进行中开：当圈推精确落点、退场沿正确、之后零推送" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let wake : Array[Bool] = []
  app.set_anim_wake(fn(active) { wake.push(active) })
  let win = app.create_window("中途", @moonui.LogicalSize(200.0, 100.0))
  let label = @moonui.Widget::label(b, "Ab").animation(@moonui.Linear)
  let sp = @moonui.Widget::spacer(b)
  win.set_content(@moonui.Widget::row(b, 0.0, [sp, label]))
  let h = anim_handle(label)
  let log = b.bounds_push_log()
  // 装载那一圈 label 直接落到位（x=176）：这条就是账上的第一笔
  let before = log.length()
  @moonui.Backend::set_window_size(
    b,
    win.handle(),
    @moonui.LogicalSize(300.0, 100.0),
  )
  b.push_event(Resize(win.target(), @moonui.LogicalSize(300.0, 100.0)))
  assert_true(app.step())
  // 偏好关的起跑段照旧：起跑圈零推送（账停在装载那一笔）、激活沿已发
  assert_eq(log.length(), before)
  assert_eq(wake, [true])
  cell[0] = 50
  assert_true(app.step())
  // 中间帧照旧（值 = 176 + 100·linear(50/300)，与推送同一条算术逐位同值）
  assert_eq(
    @moonui.Backend::widget_bounds(b, h).origin.x,
    176.0 + 100.0 * @moonui.Linear.progress(50.0 / 300.0),
  )
  assert_eq(log.length(), before + 1)
  // 偏好开着的那圈：中间帧整体跳过，推精确的 to、账清零
  b.set_prefers_reduced_motion(true)
  cell[0] = 100
  assert_true(app.step())
  assert_eq(@moonui.Backend::widget_bounds(b, h).origin.x, 276.0)
  assert_eq(log.length(), before + 2)
  // 退场沿恰好一条（激活 true 之后退场 false），帧钟恢复零开销
  assert_eq(wake, [true, false])
  // 之后零推送
  cell[0] = 150
  assert_false(app.step())
  assert_eq(log.length(), before + 2)
}

///|
/// 控件档触发的真账（真窗批 T89② 咬出后钉进 Mock）：expand 收缩触发——
/// fill 收缩、label 只挪 origin（尺寸不动，Core 全权拥有 origin 那格），
/// frame 跳变在前、bounds 动画追在后、wake 双沿到齐。set_expand 标脏修复
/// （T55 同形缺口）由这条钉住。
test "expand 收缩触发动画：frame 跳变在前 bounds 追在后，wake 双沿" {
  let b = @moonui.MockBackend::new()
  b.init()
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() -> Int32 {
    cell[0] = cell[0] + 50
    cell[0]
  })
  let wake : Array[Bool] = []
  app.set_anim_wake(fn(active) { wake.push(active) })
  let win = app.create_window("probe", @moonui.LogicalSize(200.0, 100.0))
  let lbl = @moonui.Widget::label(b, "Ab").animation(@moonui.EaseInOut)
  let fill = @moonui.Widget::label(b, "").with_expand(true)
  win.set_content(@moonui.Widget::row(b, 0.0, [fill, lbl]))
  win.show()
  let _ = app.step()
  let _ = app.step()
  let ox_before = lbl.frame().origin.x
  let h = match lbl.handle() {
    Some(h) => h
    None => abort("no handle")
  }
  let bx_before = @moonui.Backend::widget_bounds(b, h).origin.x
  let _ = fill.with_expand(false)
  // 起跑圈：记 span 零推送 + 泵起跑圈零推送——后端显示的正是 from，
  // 读数还没动（真窗批假收敛的教训钉在这条负控制里）
  let _ = app.step()
  assert_eq(lbl.frame().origin.x < ox_before, true)
  assert_eq(@moonui.Backend::widget_bounds(b, h).origin.x, bx_before)
  // 推进到退场：frame 先到、bounds 追到、wake 两沿
  let mut turns = 0
  while wake.length() < 2 && turns < 40 {
    let _ = app.step()
    turns = turns + 1
  }
  assert_eq(wake, [true, false])
  assert_eq(lbl.frame().origin.x, @moonui.Backend::widget_bounds(b, h).origin.x)
}

///|
/// 窗口位移动画（`set_position_animated`，复位窗口那类"把窗送到位"的滑动）：
/// 与树账同一台泵、同一套规则——起跑圈补记时刻零推送（窗口停在 from）、中间
/// 帧按曲线逐帧滑、退场推**精确的 to**。逐帧值用同一条 pub 曲线函数算。
test "T84 窗口位移：逐帧滑到落点，退场推精确落点" {
  let b = @moonui.MockBackend::new()
  b.init()
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let wake : Array[Bool] = []
  app.set_anim_wake(fn(active) { wake.push(active) })
  let win = app.create_window("滑", @moonui.LogicalSize(200.0, 100.0))
  let _ = win.set_position(@moonui.LogicalPoint(10.0, 20.0)) catch { _ => () }
  let _ = win.set_position_animated(@moonui.LogicalPoint(210.0, 220.0)) catch {
    _ => ()
  }
  let pos = fn() -> @moonui.LogicalPoint {
    @moonui.Window::position(win) catch {
      _ => @moonui.LogicalPoint(-1.0, -1.0)
    }
  }
  // 起跑圈：补记时刻、零推送——窗口还停在 from（这圈没有帧可推）
  let _ = app.step()
  assert_eq(pos(), @moonui.LogicalPoint(10.0, 20.0))
  // 逐帧：from=(10,20)、to=(210,220)、300ms EaseInOut；>=300 退场推精确 to
  for ms in [50, 100, 150, 200, 250, 300, 350] {
    cell[0] = ms
    let _ = app.step()
    let k = if ms >= 300 {
      1.0
    } else {
      @moonui.EaseInOut.progress(ms.to_double() / 300.0)
    }
    assert_eq(pos(), @moonui.LogicalPoint(10.0 + 200.0 * k, 20.0 + 200.0 * k))
  }
  assert_eq(pos(), @moonui.LogicalPoint(210.0, 220.0))
  // 帧钟开关沿：激活 true、全退场 false（预算换一次、恢复一次）
  assert_eq(wake, [true, false])
}

///|
/// 没接帧钟：位移当圈直接落（等于瞬移）——与无动画窗口逐位同值（判据④的
/// 窗口半条）。系统"减少动态效果"开着走同一条退化路。
test "T84 窗口位移：没接帧钟当场落，reduced-motion 同款" {
  let b = @moonui.MockBackend::new()
  b.init()
  let app = @moonui.App::new(b)
  let win = app.create_window("瞬", @moonui.LogicalSize(200.0, 100.0))
  let _ = win.set_position(@moonui.LogicalPoint(5.0, 6.0)) catch { _ => () }
  let _ = win.set_position_animated(@moonui.LogicalPoint(105.0, 106.0)) catch {
    _ => ()
  }
  let _ = app.step()
  let p1 = @moonui.Window::position(win) catch {
    _ => @moonui.LogicalPoint(-1.0, -1.0)
  }
  assert_eq(p1, @moonui.LogicalPoint(105.0, 106.0))
  // 接了钟但偏好开着：同样当圈退场，帧钟一次都不响
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let wake : Array[Bool] = []
  app.set_anim_wake(fn(active) { wake.push(active) })
  b.set_prefers_reduced_motion(true)
  let _ = win.set_position_animated(@moonui.LogicalPoint(0.0, 0.0)) catch {
    _ => ()
  }
  cell[0] = 50
  let _ = app.step()
  let p2 = @moonui.Window::position(win) catch {
    _ => @moonui.LogicalPoint(-1.0, -1.0)
  }
  assert_eq(p2, @moonui.LogicalPoint(0.0, 0.0))
  assert_eq(wake, [])
}

///|
/// 时钟域平移不变（`T219` 咬出来的那条）：三台泵（bounds / opacity / 窗口位移）在
/// **负数**时刻起点下，逐帧值与帧钟沿必须和非负域逐位同值——动画只准看差值。
/// 负数不是假想敌：`native_time_ms` 把 int64 毫秒截成 Int32（`backends/native-common/ffi.mbt`
/// 的注记就是这条口径），mac 侧那是 `mach_absolute_time` 折算的**开机毫秒**，开机满
/// 2^31 毫秒（≈24.85 天）读数转负；本机 2026-11-06 实测 `clk_0=-2129800004`，与
/// `uptime`（25 天）和 `kern.boottime`（2026-10-12 14:57:37）两把尺子对得上。
/// 而起跑状态编码成了 `start_ms < 0`：负数时钟下每一圈都被认成起跑圈——elapsed 恒 0、
/// 零推送、`remain` 永不归零，真窗那条落点判据从此恒红，帧钟还永远停在 8ms 档。
test "T84 时钟域平移不变：负数起点下三台泵逐帧同值、帧钟双沿照到" {
  let neg = -2129800004
  // ① bounds 泵：复用判据①那棵树，只把整条时刻域平移过去
  let wake_pos : Array[Bool] = []
  let wake_neg : Array[Bool] = []
  let at_zero = drive_frames_at(0, @moonui.EaseInOut, wake_pos)
  let at_neg = drive_frames_at(neg, @moonui.EaseInOut, wake_neg)
  assert_eq(at_neg, at_zero)
  assert_eq(wake_neg, wake_pos)
  // ② opacity 泵：起跑圈零推送、中间帧按曲线、退场推精确落点，全在负数域跑
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [neg]
  app.set_anim_clock(fn() { cell[0] })
  let wake : Array[Bool] = []
  app.set_anim_wake(fn(active) { wake.push(active) })
  let win = app.create_window("透明负域", @moonui.LogicalSize(200.0, 100.0))
  let label = @moonui.Widget::label(b, "Ab")
    .animation(@moonui.Linear)
    .opacity(0.8)
  win.set_content(@moonui.Widget::column(b, 0.0, [label]))
  let h = anim_handle(label)
  let _ = label.opacity(0.2)
  win.relayout()
  assert_false(app.step())
  assert_eq(b.widget(h).opacity, 0.8)
  for ms in [50, 100, 150, 200, 250] {
    cell[0] = neg + ms
    let _ = app.step()
    assert_eq(
      b.widget(h).opacity,
      0.8 + (0.2 - 0.8) * @moonui.Linear.progress(ms.to_double() / 300.0),
    )
  }
  cell[0] = neg + 300
  assert_true(app.step())
  assert_eq(b.widget(h).opacity, 0.2)
  assert_eq(wake, [true, false])
  // ③ 窗口位移泵：同一套规则，中间帧就落在窗口上（窗口没有真相/显示两份账）
  let mb = @moonui.MockBackend::new()
  @moonui.Backend::init(mb)
  let mapp = @moonui.App::new(mb)
  let mcell : Array[Int32] = [neg]
  mapp.set_anim_clock(fn() { mcell[0] })
  let mwake : Array[Bool] = []
  mapp.set_anim_wake(fn(active) { mwake.push(active) })
  let mwin = mapp.create_window("滑负域", @moonui.LogicalSize(200.0, 100.0))
  let _ = mwin.set_position(@moonui.LogicalPoint(10.0, 20.0)) catch { _ => () }
  let _ = mwin.set_position_animated(@moonui.LogicalPoint(210.0, 220.0)) catch {
    _ => ()
  }
  let pos = fn() -> @moonui.LogicalPoint {
    @moonui.Window::position(mwin) catch {
      _ => @moonui.LogicalPoint(-1.0, -1.0)
    }
  }
  let _ = mapp.step()
  assert_eq(pos(), @moonui.LogicalPoint(10.0, 20.0))
  for ms in [50, 100, 150, 200, 250, 300, 350] {
    mcell[0] = neg + ms
    let _ = mapp.step()
    let k = if ms >= 300 {
      1.0
    } else {
      @moonui.EaseInOut.progress(ms.to_double() / 300.0)
    }
    assert_eq(pos(), @moonui.LogicalPoint(10.0 + 200.0 * k, 20.0 + 200.0 * k))
  }
  assert_eq(mwake, [true, false])
}

///|
/// `T89③` 可见性过渡（owner 口径：只做淡入）：隐藏的控件在配了 `.animation`
/// 时，显示的那一刻把 opacity 归 0 再按曲线淡到真值；隐藏仍立即直切——不推迟
/// `set_visible` 的推送语义，判据④「退场后与无动画树逐位同值」不动。
/// 只对**有句柄的叶子**起淡入（容器 alpha 盖住子树，避免双重淡入）。
test "T89③ 可见性淡入：显示按曲线 0→真值，隐藏立即直切" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let wake : Array[Bool] = []
  app.set_anim_wake(fn(active) { wake.push(active) })
  let win = app.create_window("淡入", @moonui.LogicalSize(200.0, 100.0))
  let label = @moonui.Widget::label(b, "Ab").animation(@moonui.Linear)
  let sp = @moonui.Widget::spacer(b)
  win.set_content(@moonui.Widget::row(b, 0.0, [sp, label]))
  let h = anim_handle(label)
  let log = b.opacity_push_log()
  // 装载：首推建立初值 1.0（不过渡），只有这一笔
  assert_eq(b.widget(h).opacity, 1.0)
  assert_eq(log.length(), 1)
  // 隐藏立即直切：可见位翻掉，opacity 与推送账都不动
  label.set_visible(false)
  assert_false(@moonui.Backend::widget_visible(b, h))
  assert_eq(b.widget(h).opacity, 1.0)
  assert_eq(log.length(), 1)
  // 显示：当场推 0（不是等 relayout），随后由既有 opacity 泵接管
  label.set_visible(true)
  assert_true(@moonui.Backend::widget_visible(b, h))
  assert_eq(b.widget(h).opacity, 0.0)
  assert_eq(log.length(), 2)
  let (start_id, start_v) = log[1]
  assert_eq(start_id, h.id)
  assert_eq(start_v, 0.0)
  // 变更点（relayout 建 0→1 的 span）零推送：后端此刻显示的正是 from
  win.relayout()
  assert_eq(log.length(), 2)
  assert_eq(b.widget(h).opacity, 0.0)
  // 起跑圈零推送，之后逐帧推 linear(ms/300)
  assert_false(app.step())
  assert_eq(log.length(), 2)
  for ms in [50, 150, 250] {
    cell[0] = ms
    let _ = app.step()
    assert_eq(
      b.widget(h).opacity,
      @moonui.Linear.progress(ms.to_double() / 300.0),
    )
  }
  // 退场圈：推精确落点 1.0、账清零，帧钟双沿到齐
  cell[0] = 300
  assert_true(app.step())
  assert_eq(b.widget(h).opacity, 1.0)
  assert_eq(wake, [true, false])
  let settled = log.length()
  cell[0] = 400
  assert_false(app.step())
  assert_eq(log.length(), settled)
}

///|
/// `T89③` 的负控制：没配曲线时隐藏→显示不碰 opacity 通道（与旧版逐位同值）；
/// 已经可见时再 `set_visible(true)` 不重播淡入。
test "T89③ 淡入负控制：无曲线直切、已可见不重播" {
  // 无曲线：隐藏→显示一条 opacity 推送都不多花
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let win = app.create_window("直切", @moonui.LogicalSize(200.0, 100.0))
  let label = @moonui.Widget::label(b, "Ab")
  win.set_content(@moonui.Widget::column(b, 0.0, [label]))
  let h = anim_handle(label)
  assert_eq(b.opacity_push_log().length(), 0)
  label.set_visible(false)
  label.set_visible(true)
  assert_true(@moonui.Backend::widget_visible(b, h))
  assert_eq(b.opacity_push_log().length(), 0)
  win.relayout()
  assert_false(app.step())
  assert_eq(b.opacity_push_log().length(), 0)
  // 已可见再 set_visible(true)：读回仍是 1.0，推送账一条不增
  let b2 = @moonui.MockBackend::new()
  @moonui.Backend::init(b2)
  let app2 = @moonui.App::new(b2)
  let cell2 : Array[Int32] = [0]
  app2.set_anim_clock(fn() { cell2[0] })
  let win2 = app2.create_window("不重播", @moonui.LogicalSize(200.0, 100.0))
  let label2 = @moonui.Widget::label(b2, "Ab").animation(@moonui.Linear)
  win2.set_content(@moonui.Widget::column(b2, 0.0, [label2]))
  let h2 = anim_handle(label2)
  let before = b2.opacity_push_log().length()
  assert_eq(before, 1)
  label2.set_visible(true)
  assert_eq(b2.opacity_push_log().length(), before)
  assert_eq(b2.widget(h2).opacity, 1.0)
  win2.relayout()
  cell2[0] = 100
  assert_false(app2.step())
  assert_eq(b2.opacity_push_log().length(), before)
}

///|
/// `T264` 显示偏移的三条账：**只动后端、不动布局真相**、子树整条跟着走。
///
/// 为什么钉"布局真相不动"：偏移的用途是拖动中让行浮起来跟手、让别的行让位，
/// 而布局（行序、滚动行程、命中槽位）必须保持静止——真相要是跟着动了，滚动
/// 行程会抖、`widget_at` 会命中到浮起来那一行自己，槽位算法就地失效。
/// 判据读两侧：后端 `widget_bounds` 变了，`frame()` 一位没变。
test "T264 框架：显示偏移只动后端坐标、不动布局真相，子树整条继承" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let win = app.create_window("偏移", @moonui.LogicalSize(300.0, 200.0))
  let a = @moonui.Widget::label(b, "Aa")
  let c = @moonui.Widget::label(b, "Bb")
  let col = @moonui.Widget::column(b, 0.0, [a, c])
  win.set_content(col)
  let _ = app.step()
  let ha = anim_handle(a)
  let hc = anim_handle(c)
  let a0 = @moonui.Backend::widget_bounds(b, ha)
  let c0 = @moonui.Backend::widget_bounds(b, hc)
  // ① 叶子自己设偏移：后端立刻跟着走，布局真相（frame）一位不动
  a.set_display_offset(0.0, 30.0)
  assert_eq(@moonui.Backend::widget_bounds(b, ha).origin.y, a0.origin.y + 30.0)
  assert_eq(a.frame().origin.y, a0.origin.y)
  assert_eq(a.display_offset().y, 30.0)
  // 别的控件不受牵连（偏移不带继承污染）
  assert_eq(@moonui.Backend::widget_bounds(b, hc).origin.y, c0.origin.y)
  // ② 往回设同一个值：零变化，读回不变（幂等，拖动中每帧重复设不抖）
  a.set_display_offset(0.0, 30.0)
  assert_eq(@moonui.Backend::widget_bounds(b, ha).origin.y, a0.origin.y + 30.0)
  // ③ 在容器上设偏移：两个叶子同时平移同一条量（偏移沿祖先链累加），
  //    叶子自己的真相仍不含偏移
  col.set_display_offset(0.0, 10.0)
  assert_eq(
    @moonui.Backend::widget_bounds(b, ha).origin.y,
    a0.origin.y + 30.0 + 10.0,
  )
  assert_eq(@moonui.Backend::widget_bounds(b, hc).origin.y, c0.origin.y + 10.0)
  assert_eq(a.frame().origin.y, a0.origin.y)
  // ④ 归零：回到布局位置，逐位精确（`0.0 + 0.0` 无浮点债）
  a.set_display_offset(0.0, 0.0)
  col.set_display_offset(0.0, 0.0)
  assert_eq(@moonui.Backend::widget_bounds(b, ha).origin.y, a0.origin.y)
  assert_eq(@moonui.Backend::widget_bounds(b, hc).origin.y, c0.origin.y)
  @moonui.Backend::terminate(b)
}

///|
/// `T264` 带曲线的偏移：中间帧逐帧可断言（时间→值），落点推精确的 `to`，
/// 且有偏移期间**布局真相与命中槽位都不跟着动**。
///
/// 这条是"让位平滑"的底层判据：应用层只负责算"谁该移到哪"，平滑由这本账
/// 保证。断言的帧值用同一条 pub 曲线函数算——两侧是同一串确定的浮点运算。
test "T264 框架：带曲线的偏移逐帧可断言，落点精确，布局不动" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let win = app.create_window("让位", @moonui.LogicalSize(300.0, 200.0))
  let a = @moonui.Widget::label(b, "Aa")
  win.set_content(@moonui.Widget::column(b, 0.0, [a]))
  let _ = app.step()
  let h = anim_handle(a)
  let y0 = @moonui.Backend::widget_bounds(b, h).origin.y
  // 从 0 让到 -20（正是"上面那行被抽走、这一行上移一行"的形状）
  a.set_display_offset_animated(0.0, -20.0, @moonui.Linear)
  // 起跑圈：补记时刻、零推送，后端仍显示 from
  let _ = app.step()
  assert_eq(@moonui.Backend::widget_bounds(b, h).origin.y, y0)
  // 逐帧：y = y0 + (-20)·linear(ms/300)
  for ms in [100, 200] {
    cell[0] = ms
    let _ = app.step()
    let k = @moonui.Linear.progress(ms.to_double() / 300.0)
    assert_eq(
      @moonui.Backend::widget_bounds(b, h).origin.y,
      y0 + (y0 - 20.0 - y0) * k,
    )
    // 布局真相整段不动
    assert_eq(a.frame().origin.y, y0)
  }
  // 退场帧：推精确的 to（不插值），账清空后不再推
  cell[0] = 300
  let _ = app.step()
  assert_eq(@moonui.Backend::widget_bounds(b, h).origin.y, y0 - 20.0)
  cell[0] = 400
  let _ = app.step()
  assert_eq(@moonui.Backend::widget_bounds(b, h).origin.y, y0 - 20.0)
  assert_eq(a.display_offset().y, -20.0)
  @moonui.Backend::terminate(b)
}

///|
/// `T266` 偏移时长是**逐次参数**，不是全局常量：同一条曲线、同一个位移，600ms
/// 档在 300ms 时还在半途，默认档（300ms）同刻已经落定。
///
/// 为什么这条值得单独钉：拖动里"让位"要比"落位"慢——两个时长必须能分开指定，
/// 而全局 `ANIMATION_DURATION_MS` 一改会把 bounds / opacity / move 三本账一起
/// 拖慢。判据把两档摆在同一条时间线上对读，改回常量就当场红。
test "T266 框架：偏移时长逐次可指定——600ms 档半途、默认档落定" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let win = app.create_window("时长", @moonui.LogicalSize(300.0, 200.0))
  let slow = @moonui.Widget::label(b, "慢")
  let fast = @moonui.Widget::label(b, "快")
  win.set_content(@moonui.Widget::column(b, 0.0, [slow, fast]))
  let _ = app.step()
  let hs = anim_handle(slow)
  let hf = anim_handle(fast)
  let ys0 = @moonui.Backend::widget_bounds(b, hs).origin.y
  let yf0 = @moonui.Backend::widget_bounds(b, hf).origin.y
  // 同一条 Linear、同一个位移 -40，只有时长不同
  slow.set_display_offset_animated_ms(0.0, -40.0, @moonui.Linear, 600) catch {
    _ => ()
  }
  fast.set_display_offset_animated(0.0, -40.0, @moonui.Linear) catch {
    _ => ()
  }
  // 起跑圈：补记时刻、零推送
  let _ = app.step()
  assert_eq(@moonui.Backend::widget_bounds(b, hs).origin.y, ys0)
  assert_eq(@moonui.Backend::widget_bounds(b, hf).origin.y, yf0)
  // 300ms 那一刻：600ms 档走了一半，默认档已经退场
  cell[0] = 300
  let _ = app.step()
  let k = @moonui.Linear.progress(300.0 / 600.0)
  assert_eq(@moonui.Backend::widget_bounds(b, hs).origin.y, ys0 - 40.0 * k)
  assert_eq(@moonui.Backend::widget_bounds(b, hf).origin.y, yf0 - 40.0)
  // 600ms：慢的那只也落定，且推的是精确的 to（不是插值算出来的）
  cell[0] = 600
  let _ = app.step()
  assert_eq(@moonui.Backend::widget_bounds(b, hs).origin.y, ys0 - 40.0)
  assert_eq(slow.display_offset().y, -40.0)
  // 布局真相全程不动
  assert_eq(slow.frame().origin.y, ys0)
  assert_eq(fast.frame().origin.y, yf0)
  @moonui.Backend::terminate(b)
}

///|
/// `T267` **零句柄容器上的偏移也要过场**——这一条是拖动让位的手感底线。
///
/// 偏移的宿主在最常见的场景里根本没有句柄：`VirtualList` 的行是 `Sized` 锁高
/// 壳，`Column` / `Row` / `Center` 也都是纯布局节点（`kind.is_layout_only()` →
/// `handle = None`）。而 `shown_bounds` 只有在自己带句柄时才被写
/// （`push_bounds_displayed` 的 `Some(h)` 分支），所以"`shown_bounds` 是 `None`
/// 就当首推、当圈落到终点"这条兜底判据在这些宿主上**恒成立**——设定动画等于
/// 设定终值，视觉上让位没有过场、瞬间到位。
///
/// 判据把三种宿主摆在一起读同一本账：起跑圈后端零推送（还在原位，不是终点）、
/// 半途落在两端之间、到点推精确的 `to`。改回按 `shown_bounds` 判首推，第一条
/// 断言当场红。
test "T267 框架：零句柄容器上的偏移动画照样过场（行壳/Column 就是这一款）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let win = app.create_window("零句柄", @moonui.LogicalSize(300.0, 200.0))
  let a = @moonui.Widget::label(b, "Aa")
  // 宿主 `col` 是零句柄容器，句柄只在叶子上——与行壳 + 行内面板同形
  let col = @moonui.Widget::column(b, 0.0, [a])
  win.set_content(col)
  let _ = app.step()
  assert_true(
    match col.handle() {
      None => true
      Some(_) => false
    },
  )
  let ha = anim_handle(a)
  let y0 = @moonui.Backend::widget_bounds(b, ha).origin.y
  let f0 = col.frame().origin.y
  col.set_display_offset_animated_ms(0.0, -30.0, @moonui.Linear, 400) catch {
    _ => ()
  }
  // 起跑圈：补记时刻、零推送——后端还在原位。这一条就是"瞬间到位"的判据
  let _ = app.step()
  assert_eq(@moonui.Backend::widget_bounds(b, ha).origin.y, y0)
  // 半途：按曲线插值落在两端之间（叶子读祖先链的显示值，不是真相）
  cell[0] = 200
  let _ = app.step()
  let k = @moonui.Linear.progress(200.0 / 400.0)
  assert_eq(@moonui.Backend::widget_bounds(b, ha).origin.y, y0 - 30.0 * k)
  // 到点：推精确的 to，账清空；布局真相整段一位不动
  cell[0] = 400
  let _ = app.step()
  assert_eq(@moonui.Backend::widget_bounds(b, ha).origin.y, y0 - 30.0)
  assert_eq(col.display_offset().y, -30.0)
  assert_eq(col.frame().origin.y, f0)
  assert_eq(a.frame().origin.y, y0)
  @moonui.Backend::terminate(b)
}
