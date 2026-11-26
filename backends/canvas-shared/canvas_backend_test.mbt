///|
/// CanvasBackend 的真跑判据：开真窗口、推记账、让 poll_event 收帧，然后
/// 直接读挂窗画布的像素——面板底色、标签字迹、滑条已过段逐位核。
/// 不 pump 到有人工事件为止（`for_testing` 的有限预算），不与真鼠标交错。
test "自绘后端：记账 → 收帧 → 画布像素逐位对得上" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "自绘后端探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  // 记账：一段红面板 + 一条滑条
  let panel = @moonui.Backend::create_widget(b, @moonui.Panel, "")
  @moonui.Backend::set_widget_style(
    b,
    panel,
    @moonui.style(background=Some(@moonui.Color::rgb(255, 0, 0))),
  )
  @moonui.Backend::set_widget_bounds(
    b,
    panel,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(60.0, 30.0),
    ),
  )
  let slider = @moonui.Backend::create_ranged_widget(b, @moonui.Slider, 0, 100)
  @moonui.Backend::set_widget_value(b, slider, 50)
  @moonui.Backend::set_widget_bounds(
    b,
    slider,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 60.0),
      @moonui.LogicalSize(100.0, 24.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [panel, slider])
  // 收帧：poll_event 开头会把脏窗重画 + present
  let _ = @moonui.Backend::poll_event(b)
  // 读像素：先找这窗的画布（测试口：windows 账里的 canvas）
  let scale = @moonui.Backend::window_scale(b, win)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  // 面板中心：物理坐标 = 逻辑 × scale
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(40.0), px(25.0)),
    0xFF0000,
  )
  // 滑条轨道（面板外的灰）：y = 60+(24-4)/2 = 72 逻辑
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(95.0), px(72.0)),
    0xDDDDDD,
  )
  // 已过段半程是强调蓝（accent，YesPlayMusic --color-primary）
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(35.0), px(72.0)),
    0x335EEA,
  )
  // 脏账收掉了：再问一轮 poll_event 不该再重画（dirty=false，无从直接断，
  // 间接判据：帧位图还在、像素没变）
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(40.0), px(25.0)),
    0xFF0000,
  )
  // 收尾：销毁控件与窗口（顺序按 Core 的约定）
  @moonui.Backend::destroy_widget(b, panel)
  @moonui.Backend::destroy_widget(b, slider)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 命中测试（§52.5 分期③）：C 报上来的窗口级鼠标事件，经记账命中改写
/// target 再交 Core；左键同点按下/抬起合成一条 Click。参数化本体直测，
/// 不依赖真鼠标。
test "自绘后端：命中测试改写 target + Click 合成" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "命中测试探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let panel = @moonui.Backend::create_widget(b, @moonui.Panel, "")
  @moonui.Backend::set_widget_bounds(
    b,
    panel,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(60.0, 30.0),
    ),
  )
  let button = @moonui.Backend::create_widget(b, @moonui.Button, "点我")
  @moonui.Backend::set_widget_bounds(
    b,
    button,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(80.0, 10.0),
      @moonui.LogicalSize(40.0, 30.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [panel, button])
  // 裸窗口指针（C 侧 target 的原话）
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  let scale = @moonui.Backend::window_scale(b, win)
  // 逻辑点 → C 报的物理像素
  fn phys(v : Double) -> Int32 {
    (v * scale.x + 0.5).floor().to_int()
  }
  // 移动到按钮上（空白 → 窗口；按钮上 → 记账句柄）
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    2,
    0,
    wptr,
    phys(30.0),
    phys(90.0),
  )
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    2,
    0,
    wptr,
    phys(100.0),
    phys(30.0),
  )
  // 左键在按钮上按下再抬起：MouseDown + MouseUp + Click（target 都是按钮）
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(100.0),
    phys(30.0),
  )
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    1,
    0,
    wptr,
    phys(100.0),
    phys(30.0),
  )
  // 左键在按钮按下、空白抬起：有 Down/Up，没有 Click
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(100.0),
    phys(30.0),
  )
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    1,
    0,
    wptr,
    phys(30.0),
    phys(90.0),
  )
  // 逐条对账（poll_event 先抽自绘队列）
  let button_target = @moonui.EventTarget::of(button)
  let win_target = @moonui.EventTarget::of(win)
  let ev1 = @moonui.Backend::poll_event(b)
  assert_true(ev1 is Some(@moonui.MouseMove(t, _)) && t == win_target)
  let ev2 = @moonui.Backend::poll_event(b)
  assert_true(ev2 is Some(@moonui.MouseMove(t, _)) && t == button_target)
  let ev3 = @moonui.Backend::poll_event(b)
  assert_true(
    ev3 is Some(@moonui.MouseDown(t, @moonui.Left, _, _)) && t == button_target,
  )
  let ev4 = @moonui.Backend::poll_event(b)
  assert_true(
    ev4 is Some(@moonui.MouseUp(t, @moonui.Left, _, _)) && t == button_target,
  )
  let ev5 = @moonui.Backend::poll_event(b)
  assert_true(ev5 is Some(@moonui.Click(t, @moonui.Left)) && t == button_target)
  let ev6 = @moonui.Backend::poll_event(b)
  assert_true(
    ev6 is Some(@moonui.MouseDown(t, @moonui.Left, _, _)) && t == button_target,
  )
  let ev7 = @moonui.Backend::poll_event(b)
  assert_true(
    ev7 is Some(@moonui.MouseUp(t, @moonui.Left, _, _)) && t == win_target,
  )
  let ev8 = @moonui.Backend::poll_event(b)
  assert_true(ev8 is None)
  @moonui.Backend::terminate(b)
}

///|
/// 按钮三态的画账：悬停/按下由记账侧自己翻（Core 的 hover 样式是另一条
/// 通道），收帧后读画布像素逐位核三种底色。
test "自绘后端：按钮三态换色，悬停/按下像素逐位核" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "三态探针",
    @moonui.LogicalSize(120.0, 60.0),
  )
  let button = @moonui.Backend::create_widget(b, @moonui.Button, "▶")
  @moonui.Backend::set_widget_bounds(
    b,
    button,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(40.0, 30.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [button])
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  let scale = @moonui.Backend::window_scale(b, win)
  fn phys(v : Double) -> Int32 {
    (v * scale.x + 0.5).floor().to_int()
  }
  fn center_px() -> Int32 raise @moonui.UiError {
    // 按钮中心（避开字形与圆角）：逻辑 (30,25) 的物理坐标
    let c = @canvas-shared.CanvasBackend::window_canvas(b, win)
    @native-common.canvas_read_pixel(c, phys(15.0), phys(25.0))
  }
  // 常态：0xE8E8EB（圆角外的钮底默认色）
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(center_px(), 0xE8E8EB)
  // 悬停：0xDCDCE0
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    2,
    0,
    wptr,
    phys(30.0),
    phys(25.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(center_px(), 0xDCDCE0)
  // 按下：0xCCCCCC
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(30.0),
    phys(25.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(center_px(), 0xCCCCCC)
  // 抬起回悬停色
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    1,
    0,
    wptr,
    phys(30.0),
    phys(25.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(center_px(), 0xDCDCE0)
  // 移出回常态
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    2,
    0,
    wptr,
    phys(100.0),
    phys(50.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(center_px(), 0xE8E8EB)
  @moonui.Backend::terminate(b)
}

///|
/// 滑条拖拽（§52.5 分期③）：按下/拖动直接改值并报 Change，抬起不误报
/// Click（原生滑条没有 clicked action）。
test "自绘后端：滑条按下/拖动改值报 Change，不产 Click" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "滑条探针",
    @moonui.LogicalSize(200.0, 60.0),
  )
  let slider = @moonui.Backend::create_ranged_widget(b, @moonui.Slider, 0, 1000)
  @moonui.Backend::set_widget_bounds(
    b,
    slider,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 20.0),
      @moonui.LogicalSize(100.0, 20.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [slider])
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  let scale = @moonui.Backend::window_scale(b, win)
  fn phys(v : Double) -> Int32 {
    (v * scale.x + 0.5).floor().to_int()
  }
  // 按在轨道半程：值应跳到 500 并报一条 Change
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(60.0),
    phys(30.0),
  )
  assert_eq(@moonui.Backend::widget_value(b, slider), 500)
  // 拖到 3/4：值 750，再报一条 Change
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    2,
    0,
    wptr,
    phys(85.0),
    phys(30.0),
  )
  assert_eq(@moonui.Backend::widget_value(b, slider), 750)
  // 抬起：有 MouseUp，没有 Click
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    1,
    0,
    wptr,
    phys(85.0),
    phys(30.0),
  )
  // 逐条对账：Down / Change(500) / Move / Change(750) / Up——Click 不在
  // target 改写已在事件序断言里覆盖
  let kinds = []
  for i = 0; i < 5; i = i + 1 {
    match @moonui.Backend::poll_event(b) {
      Some(ev) => {
        let tag = if ev is @moonui.MouseDown(_, _, _, _) {
          "down"
        } else if ev is @moonui.Change(_) {
          "change"
        } else if ev is @moonui.MouseMove(_, _) {
          "move"
        } else if ev is @moonui.MouseUp(_, _, _, _) {
          "up"
        } else if ev is @moonui.Click(_, _) {
          "click"
        } else {
          "other"
        }
        kinds.push(tag)
      }
      None => break
    }
  }
  assert_eq(kinds, ["down", "change", "move", "change", "up"])
  let extra = @moonui.Backend::poll_event(b)
  assert_true(extra is None)
  @moonui.Backend::terminate(b)
}

///|
/// Image 贴图（T98③b 收尾）：set_image_bytes 记账 → draw_image 上画布，
/// 1×1 红像素 PNG 缩放到 40×30 的框里，中心读回应是纯红。
test "自绘后端：Image 字节通道贴图，缩放后像素对得上" {
  // 有效的 1x1 红 PNG（70 字节，zlib 生成的标准件）
  let png_vals : Array[Int32] = [
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0,
    0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 13, 73, 68, 65, 84, 120,
    156, 99, 248, 207, 192, 240, 31, 0, 5, 0, 1, 255, 137, 153, 61, 29, 0, 0, 0,
    0, 73, 69, 78, 68, 174, 66, 96, 130,
  ]
  let png : Bytes = Bytes::makei(png_vals.length(), fn(i) {
    png_vals[i].to_byte()
  })
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "贴图探针",
    @moonui.LogicalSize(120.0, 60.0),
  )
  let image = @moonui.Backend::create_widget(b, @moonui.Image, "")
  @moonui.Backend::set_widget_bounds(
    b,
    image,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(40.0, 30.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [image])
  @moonui.Backend::set_widget_image_bytes(b, image, png)
  // 收帧贴图
  let _ = @moonui.Backend::poll_event(b)
  // 框中心（逻辑 30,25）应是纯红——1x1 源缩放铺满整个框
  let scale = @moonui.Backend::window_scale(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(30.0), px(25.0)),
    0xFF0000,
  )
  // 框外一格仍是窗口底
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(5.0), px(5.0)),
    0xF5F5F7,
  )
  @moonui.Backend::terminate(b)
}

///|
/// 正圆无接缝（T98③ 圆角缝修复的钉子）：radius=半宽时圆心列必须逐位纯色
/// ——四段弧拼的旧路径在圆心上下各留 1px 抗锯齿缝，整圆分支不该有。
test "自绘后端：正圆贴满无接缝，圆心列逐位纯色" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "整圆探针",
    @moonui.LogicalSize(80.0, 80.0),
  )
  let slider = @moonui.Backend::create_ranged_widget(b, @moonui.Slider, 0, 1000)
  @moonui.Backend::set_widget_value(b, slider, 500)
  // 拇指是 14x14 的圆（radius=7=半宽），矩形放中央
  @moonui.Backend::set_widget_bounds(
    b,
    slider,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(33.0, 33.0),
      @moonui.LogicalSize(14.0, 14.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [slider])
  let _ = @moonui.Backend::poll_event(b)
  // 拇指圆心 (40,40)：沿圆心上下扫 6 点（整数 y 36..41 逻辑），全部纯白
  let scale = @moonui.Backend::window_scale(b, win)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  for y = 37; y <= 43; y = y + 1 {
    assert_eq(
      @native-common.canvas_read_pixel(canvas, px(40.0), px(y.to_double())),
      0xFFFFFF,
    )
  }
  @moonui.Backend::terminate(b)
}

///|
/// 滚轮/中键/双击/离开的事件翻译（T98①）：C 报上来的编码经记账命中改写
/// target 再交 Core。参数化本体直测，不依赖真鼠标。
///   - kind 4 滚轮 → Scroll（delta 是 C 已换算的逻辑像素，原样透传）
///   - kind 3 双击 → DoubleClick（不带点）
///   - kind 0/1 button 2 中键 → MouseDown/MouseUp Middle
///   - kind 5 离开 → MouseMove（target 落回窗口，Core 据此 unhover）
test "自绘后端：滚轮/中键/双击/离开翻译" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "事件翻译探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let button = @moonui.Backend::create_widget(b, @moonui.Button, "点我")
  @moonui.Backend::set_widget_bounds(
    b,
    button,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(80.0, 10.0),
      @moonui.LogicalSize(40.0, 30.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [button])
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  let scale = @moonui.Backend::window_scale(b, win)
  fn phys(v : Double) -> Int32 {
    (v * scale.x + 0.5).floor().to_int()
  }
  let button_target = @moonui.EventTarget::of(button)
  let win_target = @moonui.EventTarget::of(win)
  // 滚轮落在按钮上：Scroll，delta (0, 10) 逻辑像素原样透传
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    4,
    0,
    wptr,
    phys(100.0),
    phys(25.0),
    dx=0,
    dy=10,
  )
  match @moonui.Backend::poll_event(b) {
    Some(@moonui.Scroll(t, d)) => {
      assert_true(t == button_target)
      assert_true(d.x == 0.0 && d.y == 10.0)
    }
    _ => assert_true(false, msg="滚轮应产 Scroll")
  }
  // 双击落在按钮上：DoubleClick（不带点）
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    3,
    0,
    wptr,
    phys(100.0),
    phys(25.0),
  )
  match @moonui.Backend::poll_event(b) {
    Some(@moonui.DoubleClick(t)) => assert_true(t == button_target)
    _ => assert_true(false, msg="双击应产 DoubleClick")
  }
  // 中键按下/抬起落在按钮上：MouseDown/MouseUp Middle
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    2,
    wptr,
    phys(100.0),
    phys(25.0),
  )
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    1,
    2,
    wptr,
    phys(100.0),
    phys(25.0),
  )
  match @moonui.Backend::poll_event(b) {
    Some(@moonui.MouseDown(t, @moonui.Middle, _, _)) =>
      assert_true(t == button_target)
    _ => assert_true(false, msg="中键按下应产 MouseDown Middle")
  }
  match @moonui.Backend::poll_event(b) {
    Some(@moonui.MouseUp(t, @moonui.Middle, _, _)) =>
      assert_true(t == button_target)
    _ => assert_true(false, msg="中键抬起应产 MouseUp Middle")
  }
  // 离开窗口（kind 5）落在空白：MouseMove，target 落回窗口（unhover 信号）
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    5,
    0,
    wptr,
    phys(10.0),
    phys(100.0),
  )
  match @moonui.Backend::poll_event(b) {
    Some(@moonui.MouseMove(t, _)) => assert_true(t == win_target)
    _ => assert_true(false, msg="离开应产 MouseMove")
  }
  // 队列排空
  assert_true(@moonui.Backend::poll_event(b) is None)
  @moonui.Backend::terminate(b)
}

///|
/// 滚动视口裁剪（T98②）：文档区子树锁回最近 Scroll 的视口——滚出视口的行
/// 不画。Scroll 视口 (10,10,50,50)，两个文档区子：一个在视口内（画出来），
/// 一个滚出视口（被裁掉，露出窗口底）。
test "自绘后端：滚动视口裁剪，滚出视口的行不画" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "裁剪探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  // Scroll 视口（窗口绝对坐标）：(10,10) 起 50×50，y 占 10..60
  let scroll = @moonui.Backend::create_widget(b, @moonui.Scroll, "")
  @moonui.Backend::set_widget_bounds(
    b,
    scroll,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(50.0, 50.0),
    ),
  )
  // 文档区子 A：文档坐标 (0,0) 50×50 → 窗口绝对 (10,10) 50×50，落在视口内
  let inside = @moonui.Backend::create_widget(b, @moonui.Panel, "")
  @moonui.Backend::set_widget_style(
    b,
    inside,
    @moonui.style(background=Some(@moonui.Color::rgb(255, 0, 0))),
  )
  @moonui.Backend::set_widget_bounds(
    b,
    inside,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(50.0, 50.0),
    ),
  )
  // 文档区子 B：文档坐标 (0,60) 50×50 → 窗口绝对 (10,70) 50×50，滚出视口
  let outside = @moonui.Backend::create_widget(b, @moonui.Panel, "")
  @moonui.Backend::set_widget_style(
    b,
    outside,
    @moonui.style(background=Some(@moonui.Color::rgb(0, 0, 255))),
  )
  @moonui.Backend::set_widget_bounds(
    b,
    outside,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 60.0),
      @moonui.LogicalSize(50.0, 50.0),
    ),
  )
  // 认领链：两个子都挂在 Scroll 下（scroll_parent = Scroll 的记账索引）
  @moonui.Backend::attach_widget_to(b, scroll, inside)
  @moonui.Backend::attach_widget_to(b, scroll, outside)
  // 画序只放两个子（Scroll 是逻辑容器，不画可见面）
  @moonui.Backend::set_paint_order(b, win, [inside, outside])
  // 收帧
  let _ = @moonui.Backend::poll_event(b)
  let scale = @moonui.Backend::window_scale(b, win)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  // 子 A 中心 (35,35)：在视口内，画出来是红
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(35.0), px(35.0)),
    0xFF0000,
  )
  // 子 B 中心 (35,95)：滚出视口（y 70..120，视口只到 60），被裁掉，露窗口底
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(35.0), px(95.0)),
    0xF5F5F7,
  )
  @moonui.Backend::terminate(b)
}

///|
/// 句柄编号空间分家（回归）：窗口句柄来自 native-common 的进程级句柄表
/// （从 0 起），自绘记账句柄若也从 0 起，第一只控件就和第一扇窗同号。
/// Core 的 `dispatch_round` 先比窗口臂、再找控件，同号时发给控件的事件
/// 会被当成发给窗口（`Window::handle_event` 只认 Resize/Close），控件的
/// 点击 handler 永远不跑——T367 的按钮点了没反应就是这条。
test "自绘后端：控件句柄与窗口句柄不同号" {
  let b = @canvas-shared.CanvasBackend::for_testing(200)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "句柄分家探针",
    @moonui.LogicalSize(120.0, 80.0),
  )
  let face = @moonui.Backend::create_widget(b, @moonui.Custom, "")
  let win_target = @moonui.EventTarget::of(win)
  let face_target = @moonui.EventTarget::of(face)
  assert_true(face_target != win_target)
  // 整段错开而不是只差一个 generation：后建的句柄也进不来
  let face2 = @moonui.Backend::create_widget(b, @moonui.Custom, "")
  assert_true(@moonui.EventTarget::of(face2) != win_target)
  assert_true(@moonui.EventTarget::of(face2) != face_target)
  @moonui.Backend::destroy_widget(b, face)
  @moonui.Backend::destroy_widget(b, face2)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 端到端：自绘面上的一次按下要经 Core 的路由落到控件 handler 上，而不是
/// 半路被窗口臂接走。上一只是"编号不同"，这一只是"真派发得到"。
test "自绘后端：按下经 Core 派发到整窗自绘面" {
  let b = @canvas-shared.CanvasBackend::for_testing(200)
  @moonui.Backend::init(b)
  let app = @moonui.App(b)
  let win = app.create_window("派发探针", @moonui.LogicalSize(200.0, 120.0))
  let face = @moonui.Widget::custom(b, @moonui.LogicalSize(200.0, 120.0), fn(
    _dl,
    _env,
  ) {

  })
  let downs : Array[Double] = []
  let _ = face.on_any(fn(ev) {
    match ev {
      @moonui.MouseDown(_, _, p, _) => downs.push(p.x)
      _ => ()
    }
  })
  win.set_content(face)
  win.show()
  // 重排几次，让记账 bounds 与绘制序先在后端就位
  for _i in 0..<3 {
    let _ = app.step()
  }
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win.handle())
  let scale = @moonui.Backend::window_scale(b, win.handle())
  let phys = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(100.0),
    phys(60.0),
  )
  for _i in 0..<3 {
    let _ = app.step()
  }
  assert_eq(downs.length(), 1)
  assert_true(downs[0] > 90.0 && downs[0] < 110.0)
  @moonui.Backend::terminate(b)
}

///|
/// 键盘路由（`T369`）：焦点账 → target 改写、Tab / Shift+Tab 在声明序里循环、
/// 点击 focusable 记账取焦、收回权限/销毁补 `Blur`。
test "自绘后端：键盘按焦点路由，Tab 在声明序里循环" {
  let b = @canvas-shared.CanvasBackend::for_testing(50)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "键盘探针",
    @moonui.LogicalSize(160.0, 100.0),
  )
  let a = @moonui.Backend::create_widget(b, @moonui.Custom, "")
  let c = @moonui.Backend::create_widget(b, @moonui.Custom, "")
  let plain = @moonui.Backend::create_widget(b, @moonui.Label, "x")
  @moonui.Backend::set_widget_bounds(
    b,
    a,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(60.0, 30.0),
    ),
  )
  @moonui.Backend::set_widget_bounds(
    b,
    c,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 60.0),
      @moonui.LogicalSize(60.0, 30.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [plain, a, c])
  @moonui.Backend::set_custom_focusable(b, a, true)
  @moonui.Backend::set_custom_focusable(b, c, true)
  // 链里夹一只非 focusable 的 Label：Tab 必须跳过它
  @moonui.Backend::set_focus_chain(b, win, [plain, a, c])
  let ta = @moonui.EventTarget::of(a)
  let tc = @moonui.EventTarget::of(c)
  let tw = @moonui.EventTarget::of(win)
  let mk_key = fn(name : String, shift : Bool) -> @moonui.KeyPress {
    @moonui.KeyPress::{
      key: name,
      ctrl: false,
      alt: false,
      shift,
      meta: false,
    }
  }
  let tab = mk_key("Tab", false)
  // ① 首颗 Tab：键先按旧焦点（窗口）报，再把焦点交给 a（plain 被跳过）
  assert_true(@canvas-shared.CanvasBackend::translate_key(b, win, tab, true))
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.KeyDown(t, _)) && t == tw,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == ta,
  )
  // ② 第二颗：键给旧焦点 a，Blur(a) → Focus(c)
  assert_true(@canvas-shared.CanvasBackend::translate_key(b, win, tab, true))
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.KeyDown(t, _)) && t == ta,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Blur(t)) && t == ta,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == tc,
  )
  // ③ 第三颗环绕回 a
  assert_true(@canvas-shared.CanvasBackend::translate_key(b, win, tab, true))
  let _ = @moonui.Backend::poll_event(b) // KeyDown(c)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Blur(t)) && t == tc,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == ta,
  )
  // ④ Shift+Tab 反向：a 往前一回落到 c
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(
      b,
      win,
      mk_key("Tab", true),
      true,
    ),
  )
  let _ = @moonui.Backend::poll_event(b) // KeyDown(a)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Blur(t)) && t == ta,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == tc,
  )
  // ⑤ 普通键：target 改写成当前焦点 c
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(
      b,
      win,
      mk_key("=", false),
      true,
    ),
  )
  match @moonui.Backend::poll_event(b) {
    Some(@moonui.KeyDown(t, kp)) => {
      assert_true(t == tc)
      assert_eq(kp.key, "=")
    }
    _ => fail("焦点存在时普通键应以焦点为 target")
  }
  // ⑥ 收回 focusable：清焦点并补 Blur；之后键不再被接管（落回窗口）
  @moonui.Backend::set_custom_focusable(b, c, false)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Blur(t)) && t == tc,
  )
  assert_true(
    !@canvas-shared.CanvasBackend::translate_key(
      b,
      win,
      mk_key("=", false),
      true,
    ),
  )
  // ⑦ 点击 a 取焦：MouseDown 之后补 Focus(a)
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  let scale = @moonui.Backend::window_scale(b, win)
  let phys = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(30.0),
    phys(20.0),
  )
  assert_true(
    @moonui.Backend::poll_event(b)
    is Some(@moonui.MouseDown(t, @moonui.Left, _, _)) &&
    t == ta,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == ta,
  )
  // ⑧ 销毁握着焦点的记账：焦点清掉、补 Blur，不再投给死句柄
  @moonui.Backend::destroy_widget(b, a)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Blur(t)) && t == ta,
  )
  @moonui.Backend::destroy_widget(b, c)
  @moonui.Backend::destroy_widget(b, plain)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// Tab 抬起不挪焦点（`T380` 真窗口反馈"一次 Tab 跳两个"）：挪焦点只认按下，
/// 抬起照旧把 KeyUp 报给当时的焦点。
test "自绘后端：Tab 抬起只报键不挪焦点" {
  let b = @canvas-shared.CanvasBackend::for_testing(50)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "Tab 抬起探针",
    @moonui.LogicalSize(160.0, 100.0),
  )
  let a = @moonui.Backend::create_widget(b, @moonui.Custom, "")
  let c = @moonui.Backend::create_widget(b, @moonui.Custom, "")
  @moonui.Backend::set_widget_bounds(
    b,
    a,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(60.0, 30.0),
    ),
  )
  @moonui.Backend::set_widget_bounds(
    b,
    c,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 60.0),
      @moonui.LogicalSize(60.0, 30.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [a, c])
  @moonui.Backend::set_custom_focusable(b, a, true)
  @moonui.Backend::set_custom_focusable(b, c, true)
  @moonui.Backend::set_focus_chain(b, win, [a, c])
  let ta = @moonui.EventTarget::of(a)
  let tc = @moonui.EventTarget::of(c)
  let tab = @moonui.KeyPress::{
    key: "Tab",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  // 首颗按下：焦点从窗口交给 a
  assert_true(@canvas-shared.CanvasBackend::translate_key(b, win, tab, true))
  let _ = @moonui.Backend::poll_event(b) // KeyDown(窗口)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == ta,
  )
  // 第二颗按下：a → c
  assert_true(@canvas-shared.CanvasBackend::translate_key(b, win, tab, true))
  let _ = @moonui.Backend::poll_event(b) // KeyDown(a)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Blur(t)) && t == ta,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == tc,
  )
  // 抬起：只报 KeyUp(c)，焦点不动（不补 Blur/Focus，也没有环绕到 a）
  assert_true(@canvas-shared.CanvasBackend::translate_key(b, win, tab, false))
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.KeyUp(t, _)) && t == tc,
  )
  let _ = @moonui.Backend::poll_event(b) // 队列已空（收帧那一圈返回 None）
  @moonui.Backend::destroy_widget(b, a)
  @moonui.Backend::destroy_widget(b, c)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 点击自管状态的控件（`T380`）：RadioButtons 按落点所在行选中（再点同一行
/// 不挪），Checkbox 翻转勾选；两条都在 Click 之后补 Change。指针形状随命中：
/// 可编辑 → 竖线、可点 → 手型、空白 → 箭头。
test "自绘后端：radio 按行选中、checkbox 翻转、指针形状随命中" {
  let b = @canvas-shared.CanvasBackend::for_testing(50)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "自管状态探针",
    @moonui.LogicalSize(200.0, 200.0),
  )
  let radio = @moonui.Backend::create_widget(b, @moonui.RadioButtons, "")
  @moonui.Backend::append_widget_option(b, radio, "一")
  @moonui.Backend::append_widget_option(b, radio, "二")
  @moonui.Backend::append_widget_option(b, radio, "三")
  @moonui.Backend::set_widget_bounds(
    b,
    radio,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(120.0, 60.0),
    ),
  )
  let cb = @moonui.Backend::create_widget(b, @moonui.Checkbox, "勾")
  @moonui.Backend::set_widget_bounds(
    b,
    cb,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 100.0),
      @moonui.LogicalSize(80.0, 20.0),
    ),
  )
  let input = @moonui.Backend::create_widget(b, @moonui.TextInput, "")
  @moonui.Backend::set_widget_bounds(
    b,
    input,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 140.0),
      @moonui.LogicalSize(120.0, 28.0),
    ),
  )
  let label = @moonui.Backend::create_widget(b, @moonui.Label, "字")
  @moonui.Backend::set_paint_order(b, win, [radio, cb, input, label])
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  let scale = @moonui.Backend::window_scale(b, win)
  let phys = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  let click = fn(x : Double, y : Double) raise @moonui.UiError {
    @canvas-shared.CanvasBackend::translate_mouse(
      b,
      0,
      0,
      wptr,
      phys(x),
      phys(y),
    )
    @canvas-shared.CanvasBackend::translate_mouse(
      b,
      1,
      0,
      wptr,
      phys(x),
      phys(y),
    )
  }
  // 点第三行（y∈[50,70)）：选中下标 2，Click 之后跟一条 Change
  click(40.0, 60.0) catch {
    _ => ()
  }
  let _ = @moonui.Backend::poll_event(b) // MouseDown
  let _ = @moonui.Backend::poll_event(b) // MouseUp
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Click(t, @moonui.Left)) &&
    t == @moonui.EventTarget::of(radio),
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Change(t)) &&
    t == @moonui.EventTarget::of(radio),
  )
  assert_eq(@moonui.Backend::widget_selected(b, radio), 2)
  // 再点同一行：不挪（真窗口反馈的"每次点击往后切换"）
  click(40.0, 60.0) catch {
    _ => ()
  }
  let _ = @moonui.Backend::poll_event(b) // MouseDown
  let _ = @moonui.Backend::poll_event(b) // MouseUp
  let _ = @moonui.Backend::poll_event(b) // Click
  let _ = @moonui.Backend::poll_event(b) // Change（选中值不变也照报）
  assert_eq(@moonui.Backend::widget_selected(b, radio), 2)
  // Checkbox：点一下勾上、再点一下取消
  click(30.0, 110.0) catch {
    _ => ()
  }
  let _ = @moonui.Backend::poll_event(b) // MouseDown
  let _ = @moonui.Backend::poll_event(b) // MouseUp
  let _ = @moonui.Backend::poll_event(b) // Click
  let _ = @moonui.Backend::poll_event(b) // Change
  assert_true(@moonui.Backend::widget_checked(b, cb))
  click(30.0, 110.0) catch {
    _ => ()
  }
  let _ = @moonui.Backend::poll_event(b) // MouseDown
  let _ = @moonui.Backend::poll_event(b) // MouseUp
  let _ = @moonui.Backend::poll_event(b) // Click
  let _ = @moonui.Backend::poll_event(b) // Change
  assert_false(@moonui.Backend::widget_checked(b, cb))
  // 指针形状：可编辑 → 1、可点 → 2、空白/标签 → 0
  assert_eq(@canvas-shared.CanvasBackend::cursor_shape_of(b, Some(input)), 1)
  assert_eq(@canvas-shared.CanvasBackend::cursor_shape_of(b, Some(radio)), 2)
  assert_eq(@canvas-shared.CanvasBackend::cursor_shape_of(b, Some(cb)), 2)
  assert_eq(@canvas-shared.CanvasBackend::cursor_shape_of(b, Some(label)), 0)
  assert_eq(@canvas-shared.CanvasBackend::cursor_shape_of(b, None), 0)
  @moonui.Backend::destroy_widget(b, radio)
  @moonui.Backend::destroy_widget(b, cb)
  @moonui.Backend::destroy_widget(b, input)
  @moonui.Backend::destroy_widget(b, label)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 焦点环（`T370`）：只有正握焦点的记账沿边画一圈强调色描边——内缩 1px、
/// 线宽 2px，整圈落在控件矩形内；取焦/收回后下一帧跟着出现/消失。像素逐位核。
test "自绘后端：焦点环只画在正握焦点的记账上" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "焦点环探针",
    @moonui.LogicalSize(120.0, 80.0),
  )
  let face = @moonui.Backend::create_widget(b, @moonui.Custom, "")
  @moonui.Backend::set_widget_bounds(
    b,
    face,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(60.0, 40.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [face])
  @moonui.Backend::set_custom_focusable(b, face, true)
  @moonui.Backend::set_focus_chain(b, win, [face])
  let scale = @moonui.Backend::window_scale(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  // 无焦点：面内什么都不画，左边缘是窗口底
  let _ = @moonui.Backend::poll_event(b)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(21.0), px(40.0)),
    0xF5F5F7,
  )
  // Tab 取焦：下一帧左边缘（内缩 1 + 线宽 2 的中线）是强调蓝
  let tab = @moonui.KeyPress::{
    key: "Tab",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  assert_true(@canvas-shared.CanvasBackend::translate_key(b, win, tab, true))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(21.0), px(40.0)),
    0x335EEA,
  )
  // 环内侧（离边 3px）仍是窗口底：线宽 2 没有摊进去
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(24.0), px(40.0)),
    0xF5F5F7,
  )
  // 收回 focusable：清焦点 + 标脏，下一帧环消失
  @moonui.Backend::set_custom_focusable(b, face, false)
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(21.0), px(40.0)),
    0xF5F5F7,
  )
  @moonui.Backend::destroy_widget(b, face)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 点击取焦的可视回执：真 kind 的 `TextInput` 默认就可聚焦，鼠标按下命中它
/// 之后焦点环（`T370`）落在框内左边缘——像素是 accent。这条同时守住"命中
/// 测试打到 TextInput 本身、而不是外层容器"（打偏就不会取焦、也没有环）。
test "自绘后端：点击文本框取焦画出焦点环" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "点击取焦探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let input = @moonui.Backend::create_widget(b, @moonui.TextInput, "")
  @moonui.Backend::set_widget_bounds(
    b,
    input,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [input])
  @moonui.Backend::set_focus_chain(b, win, [input])
  let ti = @moonui.EventTarget::of(input)
  let scale = @moonui.Backend::window_scale(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  // 首帧把画布挂上；还没点，框内左边缘是窗口底
  let _ = @moonui.Backend::poll_event(b)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(21.0), px(34.0)),
    0xF5F5F7,
  )
  // 点击框心：MouseDown 之后补 Focus(input)，同一帧画出 accent 环
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    px(90.0),
    px(34.0),
  )
  assert_true(
    @moonui.Backend::poll_event(b)
    is Some(@moonui.MouseDown(t, @moonui.Left, _, _)) &&
    t == ti,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == ti,
  )
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(21.0), px(34.0)),
    0x335EEA,
  )
  // 环内侧（离边 3px）仍是窗口底：线宽 2 没有摊进去
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(24.0), px(34.0)),
    0xF5F5F7,
  )
  // 光标（`T376`/`T379`）：空框取焦时光标落在 x+8，用正文墨色（不是占位灰、
  // 也不是强调蓝）——深墨色压在灰占位符旁才看得见，且与系统输入框一致。
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(28.0), px(34.0)),
    0x333333,
  )
  @moonui.Backend::destroy_widget(b, input)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 命中取「最上面一层」（`T377`）：Core 的绘制序是 L[0] 最上（T29），底下
/// 的面板即使矩形更大、覆盖更广，也不能把子控件的点击截走——否则真窗里
/// 点输入框/勾选框永远命中根面板，"点击没反应"、焦点也不动。
test "自绘后端：命中取绘制序最上层，容器不截走子控件点击" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "命中序探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let panel = @moonui.Backend::create_widget(b, @moonui.Panel, "")
  @moonui.Backend::set_widget_bounds(
    b,
    panel,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(200.0, 120.0),
    ),
  )
  let input = @moonui.Backend::create_widget(b, @moonui.TextInput, "")
  @moonui.Backend::set_widget_bounds(
    b,
    input,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  // L[0] 最上：输入框在面板上面
  @moonui.Backend::set_paint_order(b, win, [input, panel])
  @moonui.Backend::set_focus_chain(b, win, [input])
  let ti = @moonui.EventTarget::of(input)
  let scale = @moonui.Backend::window_scale(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  let _ = @moonui.Backend::poll_event(b)
  // 点框心：命中必须是输入框，MouseDown 之后补 Focus(input)
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    px(90.0),
    px(34.0),
  )
  assert_true(
    @moonui.Backend::poll_event(b)
    is Some(@moonui.MouseDown(t, @moonui.Left, _, _)) &&
    t == ti,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == ti,
  )
  @moonui.Backend::destroy_widget(b, input)
  @moonui.Backend::destroy_widget(b, panel)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 键窗生命周期（`T371`）：成键把首焦点交给链头、失键清焦点补 `Blur`，两次
/// 迁移都同一帧重画；焦点环的颜色随 `style_base` 下发的 accent。键窗探针是
/// 测试覆盖口，不靠真窗。
test "自绘后端：成键落首焦点、失键清焦点、焦点环跟 accent" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "键窗探针",
    @moonui.LogicalSize(120.0, 80.0),
  )
  let ta = @moonui.Backend::create_widget(b, @moonui.Custom, "")
  let tc = @moonui.Backend::create_widget(b, @moonui.Custom, "")
  let ta_t = @moonui.EventTarget::of(ta)
  @moonui.Backend::set_widget_bounds(
    b,
    ta,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(40.0, 30.0),
    ),
  )
  @moonui.Backend::set_widget_bounds(
    b,
    tc,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(60.0, 10.0),
      @moonui.LogicalSize(40.0, 30.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [ta, tc])
  @moonui.Backend::set_custom_focusable(b, ta, true)
  @moonui.Backend::set_custom_focusable(b, tc, true)
  @moonui.Backend::set_focus_chain(b, win, [ta, tc])
  // 主题底只给 accent：环跟它走，窗口底仍是默认浅灰
  @moonui.Backend::set_theme_base(
    b,
    @moonui.style(accent=Some(@moonui.Color::rgb(0, 153, 255))),
  )
  let scale = @moonui.Backend::window_scale(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  // ① 非键窗：不抢焦点，第一帧边缘是窗口底（先收一帧把画布挂上）
  @canvas-shared.CanvasBackend::set_key_probe_for_testing(b, Some(0))
  let ev0 = @moonui.Backend::poll_event(b)
  assert_false(ev0 is Some(@moonui.Focus(_)))
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(11.0), px(20.0)),
    0xF5F5F7,
  )
  // ② 成键：首焦点落到链头 ta，同一帧画出 accent 环
  @canvas-shared.CanvasBackend::set_key_probe_for_testing(b, Some(1))
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == ta_t,
  )
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(11.0), px(20.0)),
    0x0099FF,
  )
  // ③ 失键：清焦点、补 Blur，同一帧环消失
  @canvas-shared.CanvasBackend::set_key_probe_for_testing(b, Some(0))
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Blur(t)) && t == ta_t,
  )
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(11.0), px(20.0)),
    0xF5F5F7,
  )
  // ④ 再成键：焦点回到首项（失键时没记位置，这是既定语义）
  @canvas-shared.CanvasBackend::set_key_probe_for_testing(b, Some(1))
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == ta_t,
  )
  @canvas-shared.CanvasBackend::set_key_probe_for_testing(b, None)
  @moonui.Backend::destroy_widget(b, ta)
  @moonui.Backend::destroy_widget(b, tc)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 滚动视口**不画面**（回归）：Scroll 有 handle、会进 paint order，而 repaint
/// 逆序画——它若走占位面，会最后盖住整片滚动内容。这里把 Scroll 自己放进画序
/// （Core 就是先推它、再推子树），读子树中心必须还是红色。
test "自绘后端：Scroll 自己不进画面，不盖住滚动内容" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "Scroll 透明探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let scroll = @moonui.Backend::create_widget(b, @moonui.Scroll, "")
  @moonui.Backend::set_widget_bounds(
    b,
    scroll,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(50.0, 50.0),
    ),
  )
  let inside = @moonui.Backend::create_widget(b, @moonui.Panel, "")
  @moonui.Backend::set_widget_style(
    b,
    inside,
    @moonui.style(background=Some(@moonui.Color::rgb(255, 0, 0))),
  )
  @moonui.Backend::set_widget_bounds(
    b,
    inside,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(50.0, 50.0),
    ),
  )
  @moonui.Backend::attach_widget_to(b, scroll, inside)
  // Core 的画序：Scroll 自己在前、子树在后
  @moonui.Backend::set_paint_order(b, win, [scroll, inside])
  let _ = @moonui.Backend::poll_event(b)
  let scale = @moonui.Backend::window_scale(b, win)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  // 修复前这里是 0xEFEFF1（占位面盖住子面板）
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(35.0), px(35.0)),
    0xFF0000,
  )
  @moonui.Backend::destroy_widget(b, inside)
  @moonui.Backend::destroy_widget(b, scroll)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 勾选框配方：选中填强调色、未选白底、禁用换灰。方框 18×18 在行框里垂直
/// 居中，读框内左上角 (12,22)——避让白勾那两笔。
test "自绘后端：勾选框选中/未选/禁用三态像素" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "勾选框探针",
    @moonui.LogicalSize(160.0, 60.0),
  )
  let cb = @moonui.Backend::create_widget(b, @moonui.Checkbox, "勾选")
  @moonui.Backend::set_widget_bounds(
    b,
    cb,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(140.0, 24.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [cb])
  // 先收一帧把画布挂上窗（window_canvas 只认已收过帧的窗）
  let _ = @moonui.Backend::poll_event(b)
  let scale = @moonui.Backend::window_scale(b, win)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  let probe = fn() -> Int32 raise {
    @native-common.canvas_read_pixel(canvas, px(12.0), px(22.0))
  }
  // 选中：强调蓝
  @moonui.Backend::set_widget_checked(b, cb, true)
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(probe(), 0x335EEA)
  // 未选：白底
  @moonui.Backend::set_widget_checked(b, cb, false)
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(probe(), 0xFFFFFF)
  // 禁用 + 选中：灰底（形状不变，只降对比）
  @moonui.Backend::set_widget_checked(b, cb, true)
  @moonui.Backend::set_widget_enabled(b, cb, false)
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(probe(), 0xC9C9CE)
  @moonui.Backend::destroy_widget(b, cb)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 进度条配方：0 / 50 / 100 三档的已过段端点 + -1 的不定进度段。槽与已过段
/// 同高（读 y=15 中线）。
test "自绘后端：进度条按值截段，-1 画不定段" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "进度条探针",
    @moonui.LogicalSize(160.0, 40.0),
  )
  let bar = @moonui.Backend::create_ranged_widget(b, @moonui.Progress, 0, 100)
  @moonui.Backend::set_widget_bounds(
    b,
    bar,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(100.0, 10.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [bar])
  // 先收一帧把画布挂上窗（window_canvas 只认已收过帧的窗）
  let _ = @moonui.Backend::poll_event(b)
  let scale = @moonui.Backend::window_scale(b, win)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  let at = fn(x : Double) -> Int32 raise {
    @native-common.canvas_read_pixel(canvas, px(x), px(15.0))
  }
  // 0：整条都是槽色
  @moonui.Backend::set_widget_value(b, bar, 0)
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(at(105.0), 0xE9E9EC)
  // 50：左 1/4 是强调色，右 3/4 是槽
  @moonui.Backend::set_widget_value(b, bar, 50)
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(at(35.0), 0x335EEA)
  assert_eq(at(85.0), 0xE9E9EC)
  // 100：中点也是强调色
  @moonui.Backend::set_widget_value(b, bar, 100)
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(at(60.0), 0x335EEA)
  // -1：不定段落在 35%..65%，40% 处是强调色
  @moonui.Backend::set_widget_value(b, bar, -1)
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(at(50.0), 0x335EEA)
  @moonui.Backend::destroy_widget(b, bar)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 数字框配方：描边框 + 右侧步进区的竖分隔线。框内中心保持窗口底（没有
/// 填色），两条线都读边框色。
test "自绘后端：数字框描边与步进区分隔线" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "数字框探针",
    @moonui.LogicalSize(180.0, 60.0),
  )
  let spin = @moonui.Backend::create_ranged_widget(b, @moonui.Spinbox, 0, 100)
  @moonui.Backend::set_widget_text(b, spin, "50")
  @moonui.Backend::set_widget_bounds(
    b,
    spin,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(120.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [spin])
  let _ = @moonui.Backend::poll_event(b)
  let scale = @moonui.Backend::window_scale(b, win)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  // 竖分隔线：x = 10+120-18 = 112，y 取行中段
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(112.0), px(20.0)),
    0xDDDDDD,
  )
  // 框内空白：没有填色，露窗口底
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(70.0), px(24.0)),
    0xF5F5F7,
  )
  @moonui.Backend::destroy_widget(b, spin)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 单选项配方：两行里只有选中行画强调色圆心，未选行圆心是白底。
test "自绘后端：单选只在选中行画强调色圆心" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "单选探针",
    @moonui.LogicalSize(160.0, 80.0),
  )
  let rb = @moonui.Backend::create_widget(b, @moonui.RadioButtons, "")
  @moonui.Backend::append_widget_option(b, rb, "低")
  @moonui.Backend::append_widget_option(b, rb, "高")
  @moonui.Backend::set_widget_selected(b, rb, 1)
  @moonui.Backend::set_widget_bounds(
    b,
    rb,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(120.0, 48.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [rb])
  let _ = @moonui.Backend::poll_event(b)
  let scale = @moonui.Backend::window_scale(b, win)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  // 第一行（未选）圆心：白底；第二行（选中）圆心：强调蓝
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(22.0), px(22.0)),
    0xFFFFFF,
  )
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(22.0), px(46.0)),
    0x335EEA,
  )
  @moonui.Backend::destroy_widget(b, rb)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 下拉框分派：收起态画当前选项与右侧下折线箭头。框内不填色（露窗口底），
/// 箭头区必须有笔画。
test "自绘后端：下拉框画箭头且不填底" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "下拉框探针",
    @moonui.LogicalSize(180.0, 60.0),
  )
  let cb = @moonui.Backend::create_widget(b, @moonui.ComboBox, "")
  @moonui.Backend::append_widget_option(b, cb, "低")
  @moonui.Backend::append_widget_option(b, cb, "高")
  @moonui.Backend::set_widget_selected(b, cb, 1)
  @moonui.Backend::set_widget_bounds(
    b,
    cb,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(120.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [cb])
  let _ = @moonui.Backend::poll_event(b)
  let scale = @moonui.Backend::window_scale(b, win)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  // 框内中心没填色
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(70.0), px(24.0)),
    0xF5F5F7,
  )
  // 箭头区（右侧 10px 附近）有笔画
  let mut ink = 0
  for dx = 113; dx <= 126; dx = dx + 1 {
    for dy = 20; dy <= 28; dy = dy + 1 {
      if @native-common.canvas_read_pixel(
          canvas,
          px(dx.to_double()),
          px(dy.to_double()),
        ) !=
        0xF5F5F7 {
        ink = ink + 1
      }
    }
  }
  assert_true(ink > 0)
  // 选中的下标进账
  assert_eq(@moonui.Backend::widget_selected(b, cb), 1)
  @moonui.Backend::destroy_widget(b, cb)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 多行文本框分派：按 `\n` 分行画字，且文本锁在框内（超出的行不落到框外）。
test "自绘后端：多行文本框分行且裁剪在框内" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "多行框探针",
    @moonui.LogicalSize(180.0, 120.0),
  )
  let ml = @moonui.Backend::create_widget(
    b,
    @moonui.MultilineEntry,
    "第一行\n第二行\n第三行\n第四行",
  )
  @moonui.Backend::set_widget_bounds(
    b,
    ml,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(140.0, 40.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [ml])
  let _ = @moonui.Backend::poll_event(b)
  let scale = @moonui.Backend::window_scale(b, win)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  // 第一行文字区有笔画
  let mut ink = 0
  for dx = 16; dx <= 40; dx = dx + 1 {
    for dy = 14; dy <= 30; dy = dy + 1 {
      if @native-common.canvas_read_pixel(
          canvas,
          px(dx.to_double()),
          px(dy.to_double()),
        ) !=
        0xF5F5F7 {
        ink = ink + 1
      }
    }
  }
  assert_true(ink > 0)
  // 框底之外（第四行本应落到 y≈70 附近）保持窗口底——裁剪生效
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(20.0), px(70.0)),
    0xF5F5F7,
  )
  @moonui.Backend::destroy_widget(b, ml)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 日期框分派：日期文本进账、右侧日历字形有笔画；没设值时字形仍画（前景色）。
test "自绘后端：日期框画日历字形，日期进账" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "日期框探针",
    @moonui.LogicalSize(200.0, 60.0),
  )
  let dp = @moonui.Backend::create_widget(b, @moonui.DatePicker, "")
  @moonui.Backend::set_widget_bounds(
    b,
    dp,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.LogicalSize(150.0, 28.0),
    ),
  )
  @moonui.Backend::set_widget_datetime(b, dp, "2026-11-24")
  @moonui.Backend::set_paint_order(b, win, [dp])
  let _ = @moonui.Backend::poll_event(b)
  let scale = @moonui.Backend::window_scale(b, win)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  // 日历字形：x = 10+150-20 = 140，y = 10+(28-14)/2 = 17
  let mut ink = 0
  for dx = 138; dx <= 156; dx = dx + 1 {
    for dy = 14; dy <= 33; dy = dy + 1 {
      if @native-common.canvas_read_pixel(
          canvas,
          px(dx.to_double()),
          px(dy.to_double()),
        ) !=
        0xF5F5F7 {
        ink = ink + 1
      }
    }
  }
  assert_true(ink > 0)
  assert_eq(@moonui.Backend::widget_datetime(b, dp), "2026-11-24")
  @moonui.Backend::destroy_widget(b, dp)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 自绘文本编辑（`T374`）：可编辑 kind 默认可聚焦（不需要
/// `set_custom_focusable`），字符插入、退格、左右移光标都落在记账侧；
/// 事件序为 `KeyDown` 在前、`Input` 在后，文本没变时不产 `Input`。
test "自绘后端：文本框字符插入/退格/移光标" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "文本编辑探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let input = @moonui.Backend::create_widget(b, @moonui.TextInput, "")
  @moonui.Backend::set_widget_bounds(
    b,
    input,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [input])
  @moonui.Backend::set_focus_chain(b, win, [input])
  let ti = @moonui.EventTarget::of(input)
  let tw = @moonui.EventTarget::of(win)
  let mk = fn(name : String, shift : Bool) -> @moonui.KeyPress {
    @moonui.KeyPress::{
      key: name,
      ctrl: false,
      alt: false,
      shift,
      meta: false,
    }
  }
  // Tab 取焦：键按旧焦点（窗口）报，再补 Focus
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Tab", false), true),
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.KeyDown(t, kp)) &&
    t == tw &&
    kp.key == "Tab",
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == ti,
  )
  // ① 敲 a：先键后 Input，文本成 "a"
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("a", false), true),
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.KeyDown(t, kp)) &&
    t == ti &&
    kp.key == "a",
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Input(t, s)) &&
    t == ti &&
    s == "a",
  )
  assert_eq(@moonui.Backend::widget_text(b, input), "a")
  // ② 敲 b → "ab"
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("b", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Input(t, s)) &&
    t == ti &&
    s == "ab",
  )
  // ③ 左移：只标脏，不产 Input
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Left", false), true),
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.KeyDown(t, _)) && t == ti,
  )
  assert_true(@moonui.Backend::poll_event(b) is None)
  // ④ 在中间插 X → "aXb"
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("X", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Input(t, s)) &&
    t == ti &&
    s == "aXb",
  )
  // ⑤ 退格删掉 X → "ab"
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(
      b,
      win,
      mk("Backspace", false),
      true,
    ),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Input(t, s)) &&
    t == ti &&
    s == "ab",
  )
  // ⑥ Shift + b 大写 → "aBb"；再敲 ! → "aB!b"
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("b", true), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Input(t, s)) &&
    t == ti &&
    s == "aBb",
  )
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("!", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Input(t, s)) &&
    t == ti &&
    s == "aB!b",
  )
  // ⑦ 带 ctrl 的字母不插入
  let ctrl_a = @moonui.KeyPress::{
    key: "a",
    ctrl: true,
    alt: false,
    shift: false,
    meta: false,
  }
  assert_true(@canvas-shared.CanvasBackend::translate_key(b, win, ctrl_a, true))
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.KeyDown(t, _)) && t == ti,
  )
  assert_true(@moonui.Backend::poll_event(b) is None)
  assert_eq(@moonui.Backend::widget_text(b, input), "aB!b")
  // ⑧ 右移到末尾后插入 → "aB!bZ"
  for i = 0; i < 5; i = i + 1 {
    let _ = i
    assert_true(
      @canvas-shared.CanvasBackend::translate_key(
        b,
        win,
        mk("Right", false),
        true,
      ),
    )
    let _ = @moonui.Backend::poll_event(b)
  }
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Z", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Input(t, s)) &&
    t == ti &&
    s == "aB!bZ",
  )
  // ⑨ 退到空后再退：不产 Input，也不越界
  for i = 0; i < 5; i = i + 1 {
    let _ = i
    assert_true(
      @canvas-shared.CanvasBackend::translate_key(
        b,
        win,
        mk("Backspace", false),
        true,
      ),
    )
    let _ = @moonui.Backend::poll_event(b)
    let _ = @moonui.Backend::poll_event(b)
  }
  assert_eq(@moonui.Backend::widget_text(b, input), "")
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(
      b,
      win,
      mk("Backspace", false),
      true,
    ),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(@moonui.Backend::poll_event(b) is None)
  @moonui.Backend::destroy_widget(b, input)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 密码与多行（`T374` → `T389` 起跨行）：密码文本存明文、掩码只在绘制层；多行框
/// 取焦时光标落**整串末尾**（`T374` 的第一刀只落在首行末尾），左右移越过 `\n`。
test "自绘后端：密码明文编辑与多行跨行编辑" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "密码多行探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let pwd = @moonui.Backend::create_widget(b, @moonui.PasswordInput, "")
  @moonui.Backend::set_widget_text(b, pwd, "ab")
  let ml = @moonui.Backend::create_widget(b, @moonui.MultilineEntry, "")
  @moonui.Backend::set_widget_text(b, ml, "ab\ncd")
  @moonui.Backend::set_widget_bounds(
    b,
    pwd,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_widget_bounds(
    b,
    ml,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 60.0),
      @moonui.LogicalSize(140.0, 48.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [pwd, ml])
  @moonui.Backend::set_focus_chain(b, win, [pwd, ml])
  let tp = @moonui.EventTarget::of(pwd)
  let tm = @moonui.EventTarget::of(ml)
  let mk = fn(name : String) -> @moonui.KeyPress {
    @moonui.KeyPress::{
      key: name,
      ctrl: false,
      alt: false,
      shift: false,
      meta: false,
    }
  }
  // Tab → 密码框，光标落末尾；再敲 c → 明文 "abc"
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Tab"), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == tp,
  )
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("c"), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Input(t, s)) &&
    t == tp &&
    s == "abc",
  )
  assert_eq(@moonui.Backend::widget_text(b, pwd), "abc")
  // Tab → 多行框（键按旧焦点报），光标落首行末尾
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Tab"), true),
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.KeyDown(t, _)) && t == tp,
  )
  // 换焦点：先 Blur(旧) 再 Focus(新)，与原生后端同序
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Blur(t)) && t == tp,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == tm,
  )
  // 取焦时光标落整串末尾（`T389` 跨行；`T374` 的第一刀只落首行末）：插 Y → "ab\ncdY"
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Y"), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Input(t, s)) &&
    t == tm &&
    s == "ab\ncdY",
  )
  // 右移在末尾不动；左移越过 `\n`（`T374` 的第一刀夹在首行末尾）退到第二行行首
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Right"), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (6, 6))
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Left"), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (5, 5))
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Left"), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (4, 4))
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Left"), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (3, 3))
  // 在 `\n` 之后（caret 3，c 之前）退格：删掉换行把两行并成一行 → "abcdY"
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Backspace"), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Input(t, s)) &&
    t == tm &&
    s == "abcdY",
  )
  assert_eq(@moonui.Backend::widget_text(b, ml), "abcdY")
  assert_eq(@moonui.Backend::widget_text(b, pwd), "abc")
  @moonui.Backend::destroy_widget(b, pwd)
  @moonui.Backend::destroy_widget(b, ml)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 光标像素判据（`T374`）：空文本框取焦后，光标线落在 `x + 8`（1px 宽、垂直
/// 居中）；焦点换到下一只文本框后同一点回到窗口底。
test "自绘后端：焦点文本框画出光标线" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "光标探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let a = @moonui.Backend::create_widget(b, @moonui.TextInput, "")
  let c = @moonui.Backend::create_widget(b, @moonui.TextInput, "")
  // 光标色跟主题 accent 走（`T376`）：主题底给红，光标就该是红，而不是
  // 文本前景色——文本色在空框/弱灰皮肤里太浅，1px 线等于看不见。
  @moonui.Backend::set_theme_base(
    b,
    @moonui.style(foreground=Some(@moonui.Color::rgb(255, 0, 0))),
  )
  @moonui.Backend::set_widget_bounds(
    b,
    a,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_widget_bounds(
    b,
    c,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 60.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [a, c])
  @moonui.Backend::set_focus_chain(b, win, [a, c])
  let tab = @moonui.KeyPress::{
    key: "Tab",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  let scale = @moonui.Backend::window_scale(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  let _ = @moonui.Backend::poll_event(b) // 先落一帧空态，取得画布
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  assert_true(@canvas-shared.CanvasBackend::translate_key(b, win, tab, true))
  match @moonui.Backend::poll_event(b) {
    Some(@moonui.KeyDown(_, _)) => ()
    _ => fail("首 Tab 应先报键")
  }
  match @moonui.Backend::poll_event(b) {
    Some(@moonui.Focus(t)) => assert_eq(t, @moonui.EventTarget::of(a))
    _ => fail("首 Tab 应补 Focus(a)")
  }
  // 光标线：x = 20 + 8 = 28，y 取文本垂直居中处（34）
  // 光标线：x = 20 + 8 = 28，y 取文本垂直居中处（34）
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(28.0), px(34.0)),
    0xFF0000,
  )
  // Tab 到第二只：第一只失焦，同一点回到窗口底
  assert_true(@canvas-shared.CanvasBackend::translate_key(b, win, tab, true))
  let _ = @moonui.Backend::poll_event(b)
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(28.0), px(34.0)),
    0xF5F5F7,
  )
  @moonui.Backend::destroy_widget(b, a)
  @moonui.Backend::destroy_widget(b, c)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 输入法组合（`T375`）：可编辑记账取焦后立起隐形 NSTextView 代理，组合串由
/// 代理自己维护；每圈差分推 `ImeStart` / `ImeCompose` / `ImeEnd`，上屏全文
/// 只在 `ImeEnd` 之后补一条 `Input`。Tab 换焦时代理改绑，密码框同样吃代理
/// （文本仍是明文，掩码只在绘制层）。
test "自绘后端：IME 组合相位与上屏（隐形代理镜像）" {
  let b = @canvas-shared.CanvasBackend::for_testing(300, ime_proxy=true)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "IME 组合探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let input = @moonui.Backend::create_widget(b, @moonui.TextInput, "")
  let pwd = @moonui.Backend::create_widget(b, @moonui.PasswordInput, "")
  @moonui.Backend::set_widget_text(b, pwd, "ab")
  @moonui.Backend::set_widget_bounds(
    b,
    input,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_widget_bounds(
    b,
    pwd,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 60.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [input, pwd])
  @moonui.Backend::set_focus_chain(b, win, [input, pwd])
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  let ti = @moonui.EventTarget::of(input)
  let tp = @moonui.EventTarget::of(pwd)
  let tw = @moonui.EventTarget::of(win)
  let tab = @moonui.KeyPress::{
    key: "Tab",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  // Tab → 文本框；代理随取焦立起来
  assert_true(@canvas-shared.CanvasBackend::translate_key(b, win, tab, true))
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.KeyDown(t, _)) && t == tw,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == ti,
  )
  // 组合 ni：Start + Compose；组合中的文本只画（镜像进记账），不产 Input
  assert_eq(@native-common.canvas_ime_compose_in_window(wptr, "ni"), 0)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.ImeStart(t)) && t == ti,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.ImeCompose(t, s)) &&
    t == ti &&
    s == "ni",
  )
  assert_eq(@moonui.Backend::widget_text(b, input), "ni")
  // 组合串变化：只补 Compose
  assert_eq(@native-common.canvas_ime_compose_in_window(wptr, "nihao"), 0)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.ImeCompose(t, s)) &&
    t == ti &&
    s == "nihao",
  )
  // 上屏：End 在前，全文 Input 在后
  assert_eq(@native-common.canvas_ime_commit_in_window(wptr, "你好"), 0)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.ImeEnd(t)) && t == ti,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Input(t, s)) &&
    t == ti &&
    s == "你好",
  )
  assert_eq(@moonui.Backend::widget_text(b, input), "你好")
  // Tab → 密码框：键按旧焦点报，再 Blur/Focus；代理改绑并起稿 "ab"
  assert_true(@canvas-shared.CanvasBackend::translate_key(b, win, tab, true))
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.KeyDown(t, _)) && t == ti,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Blur(t)) && t == ti,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == tp,
  )
  // 密码框里组合 c 再上屏「中」：明文 "ab中"
  assert_eq(@native-common.canvas_ime_compose_in_window(wptr, "c"), 0)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.ImeStart(t)) && t == tp,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.ImeCompose(t, s)) &&
    t == tp &&
    s == "c",
  )
  assert_eq(@native-common.canvas_ime_commit_in_window(wptr, "中"), 0)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.ImeEnd(t)) && t == tp,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Input(t, s)) &&
    t == tp &&
    s == "ab中",
  )
  assert_eq(@moonui.Backend::widget_text(b, pwd), "ab中")
  @moonui.Backend::destroy_widget(b, input)
  @moonui.Backend::destroy_widget(b, pwd)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 输入法的负控制与单插回归（`T375`）：没有代理的窗（测试默认关）与不可编辑
/// 焦点都返回 -3，坏句柄返回 -1；代理接管期间 `translate_key` 不再直接改文本，
/// 一颗键只由代理提交一次、只产一条 `Input`。
test "自绘后端：IME 负控制与代理接管时的单插" {
  // 坏句柄
  assert_eq(@native-common.canvas_ime_compose_in_window(0, "x"), -1)
  // 代理关：退回 T374 的裸键编辑，没有隐形视图可组合
  let b0 = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b0)
  let win0 = @moonui.Backend::create_window(
    b0,
    "IME 负控制探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let input0 = @moonui.Backend::create_widget(b0, @moonui.TextInput, "")
  @moonui.Backend::set_widget_bounds(
    b0,
    input0,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b0, win0, [input0])
  @moonui.Backend::set_focus_chain(b0, win0, [input0])
  let tab = @moonui.KeyPress::{
    key: "Tab",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  assert_true(@canvas-shared.CanvasBackend::translate_key(b0, win0, tab, true))
  let _ = @moonui.Backend::poll_event(b0)
  let _ = @moonui.Backend::poll_event(b0)
  assert_eq(
    @native-common.canvas_ime_compose_in_window(
      @native-common.NativeBackend::window_ptr(b0.inner, win0),
      "x",
    ),
    -3,
  )
  @moonui.Backend::destroy_widget(b0, input0)
  @moonui.Backend::destroy_window(b0, win0)
  @moonui.Backend::terminate(b0)
  // 代理开但焦点落在不可编辑控件（Label 取不到焦）：也没有代理
  let b1 = @canvas-shared.CanvasBackend::for_testing(300, ime_proxy=true)
  @moonui.Backend::init(b1)
  let win1 = @moonui.Backend::create_window(
    b1,
    "IME 不可编辑探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let label = @moonui.Backend::create_widget(b1, @moonui.Label, "只读")
  @moonui.Backend::set_widget_bounds(
    b1,
    label,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b1, win1, [label])
  @moonui.Backend::set_focus_chain(b1, win1, [label])
  assert_true(@canvas-shared.CanvasBackend::translate_key(b1, win1, tab, true))
  let _ = @moonui.Backend::poll_event(b1)
  assert_eq(
    @native-common.canvas_ime_compose_in_window(
      @native-common.NativeBackend::window_ptr(b1.inner, win1),
      "x",
    ),
    -3,
  )
  @moonui.Backend::destroy_widget(b1, label)
  @moonui.Backend::destroy_window(b1, win1)
  @moonui.Backend::terminate(b1)
  // 代理接管 + 文本框：裸键不再直接插字，只有代理提交那一次产 Input
  let b2 = @canvas-shared.CanvasBackend::for_testing(300, ime_proxy=true)
  @moonui.Backend::init(b2)
  let win2 = @moonui.Backend::create_window(
    b2,
    "IME 单插探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let input2 = @moonui.Backend::create_widget(b2, @moonui.TextInput, "")
  @moonui.Backend::set_widget_bounds(
    b2,
    input2,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b2, win2, [input2])
  @moonui.Backend::set_focus_chain(b2, win2, [input2])
  assert_true(@canvas-shared.CanvasBackend::translate_key(b2, win2, tab, true))
  let _ = @moonui.Backend::poll_event(b2)
  let _ = @moonui.Backend::poll_event(b2)
  let ti = @moonui.EventTarget::of(input2)
  let a = @moonui.KeyPress::{
    key: "a",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  let wptr2 = @native-common.NativeBackend::window_ptr(b2.inner, win2)
  assert_true(@canvas-shared.CanvasBackend::translate_key(b2, win2, a, true))
  assert_true(
    @moonui.Backend::poll_event(b2) is Some(@moonui.KeyDown(t, _)) && t == ti,
  )
  // 裸键不落账：代理想插得自己走 insertText
  assert_true(@moonui.Backend::poll_event(b2) is None)
  assert_eq(@moonui.Backend::widget_text(b2, input2), "")
  assert_eq(@native-common.canvas_ime_commit_in_window(wptr2, "a"), 0)
  assert_true(
    @moonui.Backend::poll_event(b2) is Some(@moonui.Input(t, s)) &&
    t == ti &&
    s == "a",
  )
  assert_eq(@moonui.Backend::widget_text(b2, input2), "a")
  @moonui.Backend::destroy_widget(b2, input2)
  @moonui.Backend::destroy_window(b2, win2)
  @moonui.Backend::terminate(b2)
}

///|
/// 组合中的光标（`T375`）：镜像把组合串写进记账后，光标仍由 `caret_of` 交给
/// 配方画在组合串末尾——不是组合开始前的旧位置。
test "自绘后端：IME 组合中的光标画在组合串后" {
  let b = @canvas-shared.CanvasBackend::for_testing(300, ime_proxy=true)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "IME 光标探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let input = @moonui.Backend::create_widget(b, @moonui.TextInput, "")
  @moonui.Backend::set_widget_style(
    b,
    input,
    @moonui.style(font_size=Some(14.0)),
  )
  // 光标色取主题 accent（`T376`），这里用红做墨迹探针
  @moonui.Backend::set_theme_base(
    b,
    @moonui.style(foreground=Some(@moonui.Color::rgb(255, 0, 0))),
  )
  @moonui.Backend::set_widget_bounds(
    b,
    input,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [input])
  @moonui.Backend::set_focus_chain(b, win, [input])
  let tab = @moonui.KeyPress::{
    key: "Tab",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  let scale = @moonui.Backend::window_scale(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  let _ = @moonui.Backend::poll_event(b)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  assert_true(@canvas-shared.CanvasBackend::translate_key(b, win, tab, true))
  let _ = @moonui.Backend::poll_event(b)
  let _ = @moonui.Backend::poll_event(b)
  // 组合两个空格：字形本身不着墨，行上唯一该红的就是光标线——若光标还停在
  // 组合前的位置（x+8），这一行一个红点都不会有。
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  assert_eq(@native-common.canvas_ime_compose_in_window(wptr, "  "), 0)
  let _ = @moonui.Backend::poll_event(b)
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@moonui.Backend::widget_text(b, input), "  ")
  assert_eq(@native-common.canvas_ime_caret(wptr), 2)
  // 光标线的物理 x = px(20 + 8 + 量("  "))：与配方同口径（逻辑量前缀、px 取整）
  let (tw, _) = @native-common.canvas_measure_text("  ", 14.0 * scale.x)
  let cx = (28.0 * scale.x + tw + 0.5).floor().to_int()
  let hits : Array[Int32] = []
  // 扫描带避开左右两条焦点环（环也是 accent 色），只看行中段的墨迹
  for x = px(25.0); x < px(150.0); x = x + 1 {
    if @native-common.canvas_read_pixel(canvas, x, px(34.0)) == 0xFF0000 {
      hits.push(x)
    }
  }
  // 有红点，且全部落在光标线的两三个像素内（没有第二处墨迹）
  assert_true(hits.length() > 0)
  for x in hits {
    if !(x >= cx - 3 && x <= cx + 3) {
      fail(
        "意外红点 " + x.to_string() + "，光标应在 " + cx.to_string(),
      )
    }
  }
  @moonui.Backend::destroy_widget(b, input)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 点空白失焦（`T379`）：原生点别处结束编辑，光标要跟着消失。判据直接读
/// 光标那一列的像素——焦点还在时是 accent，失焦后回到窗口底。
test "自绘后端：点空白结束编辑，光标随之消失（T379）" {
  let b = @canvas-shared.CanvasBackend::for_testing(100)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "失焦探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let input = @moonui.Backend::create_widget(b, @moonui.TextInput, "")
  @moonui.Backend::set_theme_base(
    b,
    @moonui.style(foreground=Some(@moonui.Color::rgb(255, 0, 0))),
  )
  @moonui.Backend::set_widget_bounds(
    b,
    input,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [input])
  @moonui.Backend::set_focus_chain(b, win, [input])
  let scale = @moonui.Backend::window_scale(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  let _ = @moonui.Backend::poll_event(b)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  let target = @moonui.EventTarget::of(input)
  // 点进输入框：拿焦点，光标画在文本起点（x = 20 + 8）
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    px(40.0),
    px(34.0),
  )
  let mut focused = false
  for i = 0; i < 6; i = i + 1 {
    match @moonui.Backend::poll_event(b) {
      Some(@moonui.Focus(t)) =>
        if t == target {
          focused = true
          break
        }
      Some(_) => ()
      None => break
    }
  }
  assert_true(focused)
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(28.0), px(34.0)),
    0xFF0000,
  )
  // 点空白：焦点让回窗口，补 Blur，光标像素回到窗口底
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    px(180.0),
    px(100.0),
  )
  let mut blurred = false
  for i = 0; i < 6; i = i + 1 {
    match @moonui.Backend::poll_event(b) {
      Some(@moonui.Blur(t)) =>
        if t == target {
          blurred = true
          break
        }
      Some(_) => ()
      None => break
    }
  }
  assert_true(blurred)
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(28.0), px(34.0)),
    0xF5F5F7,
  )
  @moonui.Backend::destroy_widget(b, input)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 焦点环圆角与框身同源（`T379`）：圆角框聚焦后仍是圆角，不能被方环套住。
/// 判据取"圆角外、方角内"的那一角——方环会在这里着 accent，圆环不会。
test "自绘后端：焦点环沿用框身圆角，圆角框不变成方角（T379）" {
  let b = @canvas-shared.CanvasBackend::for_testing(100)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "焦点环圆角探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let input = @moonui.Backend::create_widget(b, @moonui.TextInput, "")
  @moonui.Backend::set_widget_bounds(
    b,
    input,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [input])
  @moonui.Backend::set_focus_chain(b, win, [input])
  let scale = @moonui.Backend::window_scale(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  let _ = @moonui.Backend::poll_event(b)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  let tab = @moonui.KeyPress::{
    key: "Tab",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  assert_true(@canvas-shared.CanvasBackend::translate_key(b, win, tab, true))
  let _ = @moonui.Backend::poll_event(b)
  // 环中段（上边 y≈21.5）着 accent——焦点环确实画了
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(100.0), px(21.5)),
    0x335EEA,
  )
  // 圆角外、外接方角内：圆环在这里是窗口底；半径归零的方环会着 accent
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(21.5), px(21.5)),
    0xF5F5F7,
  )
  @moonui.Backend::destroy_widget(b, input)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 光标闪烁（`T379`）：相位翻到"暗"时不画光标，翻回"亮"再画；每次翻转补一条
/// `Frame`——否则 Core 的 step 在只有光标变化的那一拍会以为无事可做。
test "自绘后端：光标按相位闪烁，翻转时补 Frame（T379）" {
  let b = @canvas-shared.CanvasBackend::for_testing(100)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "闪烁探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let input = @moonui.Backend::create_widget(b, @moonui.TextInput, "")
  @moonui.Backend::set_theme_base(
    b,
    @moonui.style(foreground=Some(@moonui.Color::rgb(255, 0, 0))),
  )
  @moonui.Backend::set_widget_bounds(
    b,
    input,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [input])
  @moonui.Backend::set_focus_chain(b, win, [input])
  let scale = @moonui.Backend::window_scale(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  let _ = @moonui.Backend::poll_event(b)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  let tab = @moonui.KeyPress::{
    key: "Tab",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  assert_true(@canvas-shared.CanvasBackend::translate_key(b, win, tab, true))
  let _ = @moonui.Backend::poll_event(b)
  // `for_testing` 默认关闪烁：先确认常亮那一帧有光标
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(28.0), px(34.0)),
    0xFF0000,
  )
  // 手动开闪烁，把相位起点拨到"暗"区间（半周期 530ms，拨 600ms）
  @canvas-shared.CanvasBackend::set_caret_phase_for_testing(b, 600)
  let mut saw_dark = false
  for i = 0; i < 4; i = i + 1 {
    match @moonui.Backend::poll_event(b) {
      Some(@moonui.Frame(t)) =>
        if t == @moonui.EventTarget::of(win) {
          saw_dark = true
          break
        }
      Some(_) => ()
      None => break
    }
  }
  assert_true(saw_dark)
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(28.0), px(34.0)),
    0xF5F5F7,
  )
  // 相位起点拨回"亮"：同一位置再见光标，仍然补 Frame
  @canvas-shared.CanvasBackend::set_caret_phase_for_testing(b, 0)
  let mut saw_light = false
  for i = 0; i < 4; i = i + 1 {
    match @moonui.Backend::poll_event(b) {
      Some(@moonui.Frame(t)) =>
        if t == @moonui.EventTarget::of(win) {
          saw_light = true
          break
        }
      Some(_) => ()
      None => break
    }
  }
  assert_true(saw_light)
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(28.0), px(34.0)),
    0xFF0000,
  )
  @moonui.Backend::destroy_widget(b, input)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 选区第二刀（`T387`）：Shift+方向键从活动端扩出选区、无 shift 折叠；
/// 插入/退格/前删在选区上作用于整段；Home/End 带与不带 shift 两条路。
/// 判据直接读 `caret_sel_of`（(锚点, 活动端) 字符下标），不靠像素猜。
test "自绘后端：选区扩展/折叠、Home/End、前删与替换（T387）" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "选区探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let input = @moonui.Backend::create_widget(b, @moonui.TextInput, "")
  @moonui.Backend::set_widget_bounds(
    b,
    input,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [input])
  @moonui.Backend::set_focus_chain(b, win, [input])
  let ti = @moonui.EventTarget::of(input)
  let mk = fn(name : String, shift : Bool) -> @moonui.KeyPress {
    @moonui.KeyPress::{
      key: name,
      ctrl: false,
      alt: false,
      shift,
      meta: false,
    }
  }
  // Tab 取焦（caret/sel 落末尾 = 0，空串）
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Tab", false), true),
  )
  let _ = @moonui.Backend::poll_event(b) // KeyDown(Tab)
  let _ = @moonui.Backend::poll_event(b) // Focus
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (0, 0))
  // 敲 abc → "abc"，(3,3)
  for ch in ["a", "b", "c"] {
    assert_true(
      @canvas-shared.CanvasBackend::translate_key(b, win, mk(ch, false), true),
    )
    let _ = @moonui.Backend::poll_event(b) // KeyDown
    let _ = @moonui.Backend::poll_event(b) // Input
  }
  assert_eq(@moonui.Backend::widget_text(b, input), "abc")
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (3, 3))
  // Shift+Left ×2：锚点钉在 3，活动端缩到 1（选区 [1,3)）
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Left", true), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (3, 2))
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Left", true), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (3, 1))
  // Home（无 shift）折叠到行首
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Home", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (0, 0))
  // Shift+Right ×2 → 选区 [0,2)
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Right", true), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (0, 1))
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Right", true), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (0, 2))
  // 敲 X 替换选区 [0,2) → "Xc"，(1,1)
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("X", false), true),
  )
  let _ = @moonui.Backend::poll_event(b) // KeyDown
  match @moonui.Backend::poll_event(b) {
    Some(@moonui.Input(t, s)) => assert_eq((t, s), (ti, "Xc"))
    _ => fail("替换选区应产 Input(Xc)")
  }
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (1, 1))
  // End（无 shift）折叠到末尾
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("End", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (2, 2))
  // Backspace → "X"，(1,1)
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(
      b,
      win,
      mk("Backspace", false),
      true,
    ),
  )
  let _ = @moonui.Backend::poll_event(b)
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@moonui.Backend::widget_text(b, input), "X")
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (1, 1))
  // Delete 在末尾：右侧没字符，无 Input
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(
      b,
      win,
      mk("Delete", false),
      true,
    ),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(@moonui.Backend::poll_event(b) is None)
  assert_eq(@moonui.Backend::widget_text(b, input), "X")
  // 敲 Y → "XY"，(2,2)
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Y", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@moonui.Backend::widget_text(b, input), "XY")
  // Home + Shift+End → 选区 [0,2)
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Home", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("End", true), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (0, 2))
  // Delete 删整段 → ""，(0,0)
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(
      b,
      win,
      mk("Delete", false),
      true,
    ),
  )
  let _ = @moonui.Backend::poll_event(b)
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@moonui.Backend::widget_text(b, input), "")
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (0, 0))
  @moonui.Backend::destroy_widget(b, input)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 剪贴板（`T387`）：⌘C 复制选区、⌘V 在光标/选区粘贴、⌘X 剪切并删选区。
/// 判据把剪贴板钉在 `set_clipboard_for_testing` 的探针上（无头环境没有真
/// 系统剪贴板），读回用 `Backend::clipboard_text`。
test "自绘后端：⌘C/⌘V/⌘X 复制粘贴剪切（T387）" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "剪贴板探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let input = @moonui.Backend::create_widget(b, @moonui.TextInput, "")
  @moonui.Backend::set_widget_bounds(
    b,
    input,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [input])
  @moonui.Backend::set_focus_chain(b, win, [input])
  let mk = fn(name : String, shift : Bool) -> @moonui.KeyPress {
    @moonui.KeyPress::{
      key: name,
      ctrl: false,
      alt: false,
      shift,
      meta: false,
    }
  }
  let mkc = fn(name : String) -> @moonui.KeyPress {
    @moonui.KeyPress::{
      key: name,
      ctrl: false,
      alt: false,
      shift: false,
      meta: true,
    }
  }
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Tab", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  let _ = @moonui.Backend::poll_event(b)
  // 敲 hello world
  for ch in ["h", "e", "l", "l", "o", " ", "w", "o", "r", "l", "d"] {
    assert_true(
      @canvas-shared.CanvasBackend::translate_key(b, win, mk(ch, false), true),
    )
    let _ = @moonui.Backend::poll_event(b)
    let _ = @moonui.Backend::poll_event(b)
  }
  assert_eq(@moonui.Backend::widget_text(b, input), "hello world")
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (11, 11))
  // 全选 [0,11)：Home + Shift+End
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Home", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("End", true), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (0, 11))
  // ⌘C：剪贴板收到 "hello world"，无 Input（复制不产文本变化）
  @canvas-shared.CanvasBackend::set_clipboard_for_testing(b, "")
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mkc("c"), true),
  )
  let _ = @moonui.Backend::poll_event(b) // KeyDown
  assert_true(@moonui.Backend::poll_event(b) is None)
  assert_eq(@moonui.Backend::clipboard_text(b), Some("hello world"))
  // Home 折叠到 0，⌘V 在行首插入 → "hello worldhello world"，(11,11)
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Home", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (0, 0))
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mkc("v"), true),
  )
  let _ = @moonui.Backend::poll_event(b) // KeyDown
  match @moonui.Backend::poll_event(b) {
    Some(@moonui.Input(_, s)) => assert_eq(s, "hello worldhello world")
    _ => fail("⌘V 应产 Input(全文)")
  }
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (11, 11))
  // 再全选 [0,22)：⌘X 剪切 → 文本空、剪贴板是全文、(0,0)
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Home", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("End", true), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (0, 22))
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mkc("x"), true),
  )
  let _ = @moonui.Backend::poll_event(b) // KeyDown
  match @moonui.Backend::poll_event(b) {
    Some(@moonui.Input(_, s)) => assert_eq(s, "")
    _ => fail("⌘X 应产 Input(空)")
  }
  assert_eq(@moonui.Backend::clipboard_text(b), Some("hello worldhello world"))
  assert_eq(@moonui.Backend::widget_text(b, input), "")
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (0, 0))
  @moonui.Backend::destroy_widget(b, input)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 点击定位与双击选词（`T387`）：左键按下把光标放到点击的字符上（不再一律
/// 落末尾）；双击在词上按非空白串扩出选区。判据先落一帧取得画布（定位要量
/// 字），再注鼠标事件。
test "自绘后端：点击定位光标与双击选词（T387）" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "点击定位探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let input = @moonui.Backend::create_widget(b, @moonui.TextInput, "foo bar")
  @moonui.Backend::set_widget_bounds(
    b,
    input,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [input])
  @moonui.Backend::set_focus_chain(b, win, [input])
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  let scale = @moonui.Backend::window_scale(b, win)
  let phys = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  // 落一帧：caret_seek 需要画布（量字定位）
  let _ = @moonui.Backend::poll_event(b)
  // 左键按下在文本框中部（x=40，text_x=28，rel=12——落在 "fo" 附近）
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(40.0),
    phys(34.0),
  )
  let _ = @moonui.Backend::poll_event(b) // MouseDown（Focus 可能随后，不取）
  let (sel, caret) = @canvas-shared.CanvasBackend::caret_sel_of(b, input)
  assert_eq(sel, caret) // 点击不产选区
  assert_true(caret > 0 && caret < 7) // 落在中间，不是 0 也不是末尾 7
  // 抬起
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    1,
    0,
    wptr,
    phys(40.0),
    phys(34.0),
  )
  let _ = @moonui.Backend::poll_event(b) // MouseUp（Click 可能随后，不取）
  // 双击在 "bar" 上（x=70）：按非空白串扩出 [4,7)
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    3,
    0,
    wptr,
    phys(70.0),
    phys(34.0),
  )
  let _ = @moonui.Backend::poll_event(b) // DoubleClick
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (4, 7))
  @moonui.Backend::destroy_widget(b, input)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 选区横线上有没有蓝色主导像素（`T387`/`T394` 采样判据的稳健版）。
/// 单点采样 px(29),px(34) 会落在反白字形上——选区把选中段重画成
/// `sel_fg=0xFFFFFF`（白），同一逻辑坐标在 mac/linux 字体度量下可能正好在
/// 字上也可能在字缝，断言单像素即 flaky（T392 实测：Linux 上 px(29) 落在
/// 'b' 的白字上，蓝 255、红 227，差 < 40——选区整条画了却断言失败）。改扫
/// 选段横线：任一像素蓝通道 > 红通道 + 40 就算选区**真的画了出来**。
/// 扫 x∈[28,56]、y 给逻辑值：text_x = 框 x(20)+8 缩进 = 28，选段 "abc" 三字
/// 约 20-25 逻辑像素宽，[28,56] 覆盖选段、又避开框左缘的焦点环蓝（x=20-21，
/// 与选区同色 0x335EEA，扫进来会误报"无选区也有蓝"）。
fn selection_blue_on_line(
  canvas : @native-common.Canvas,
  px : (Double) -> Int32,
  y : Double,
) -> Bool raise @moonui.UiError {
  let mut found = false
  for xi = 28; xi <= 56; xi = xi + 1 {
    let v = @native-common.canvas_read_pixel(canvas, px(xi.to_double()), px(y))
    if v >= 0 {
      let r = (v >> 16) & 0xFF
      let b = v & 0xFF
      if b > r + 40 {
        found = true
      }
    }
  }
  found
}

///|
/// 选区高亮（`T387`）：Shift+方向键扩出选区后，选区矩形里的像素应偏蓝
/// （0x335EEA 半透明叠在文字/底上）；同一像素在无选区时不是蓝色主导。
/// 逻辑判据（`caret_sel_of`）已验形状，这条验的是**绘制层真把选区画出来**。
test "自绘后端：选区高亮画出来（T387）" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "选区像素探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let input = @moonui.Backend::create_widget(b, @moonui.TextInput, "")
  @moonui.Backend::set_widget_bounds(
    b,
    input,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [input])
  @moonui.Backend::set_focus_chain(b, win, [input])
  let scale = @moonui.Backend::window_scale(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  let mk = fn(name : String, shift : Bool) -> @moonui.KeyPress {
    @moonui.KeyPress::{
      key: name,
      ctrl: false,
      alt: false,
      shift,
      meta: false,
    }
  }
  let _ = @moonui.Backend::poll_event(b) // 首帧空态，取得画布
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  // 取焦 + 敲 abc（无选区）：光标在 3，x=29 处应是底/字，不是蓝色主导
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Tab", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  let _ = @moonui.Backend::poll_event(b)
  for ch in ["a", "b", "c"] {
    assert_true(
      @canvas-shared.CanvasBackend::translate_key(b, win, mk(ch, false), true),
    )
    let _ = @moonui.Backend::poll_event(b)
    let _ = @moonui.Backend::poll_event(b)
  }
  let before = @native-common.canvas_read_pixel(canvas, px(29.0), px(34.0))
  assert_true(!(((before >> 0) & 0xFF) > ((before >> 16) & 0xFF) + 40)) // 无选区：不偏蓝
  // Home + Shift+End → 选区 [0,3)
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Home", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("End", true), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (0, 3))
  // 扫选段横线：单点 px(29),px(34) 会落在反白字形上（mac/linux 字体度量下
  // 可能在字上也可能在字缝），改扫线——任一蓝主导像素就算画出来了。
  assert_true(selection_blue_on_line(canvas, px, 34.0)) // 有选区：选段上蓝主导
  @moonui.Backend::destroy_widget(b, input)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 拖选（`T388`）：左键在可编辑记账上按下并按住时，移动只带活动端 `caret`
/// 跟着鼠标走、锚点 `sel` 钉在按下处；抬起结束拖选，之后再移动不动选区。
test "自绘后端：拖选扩出选区，抬起结束（T388）" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "拖选探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let input = @moonui.Backend::create_widget(b, @moonui.TextInput, "foo bar")
  @moonui.Backend::set_widget_bounds(
    b,
    input,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [input])
  @moonui.Backend::set_focus_chain(b, win, [input])
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  let scale = @moonui.Backend::window_scale(b, win)
  let phys = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  // 落一帧：caret_seek 要量字定位，画布得先收过帧
  let _ = @moonui.Backend::poll_event(b)
  // 按下在 "foo" 中段（rel≈12）：锚点与光标落在同一点（无选区）
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(40.0),
    phys(34.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  let (sel0, caret0) = @canvas-shared.CanvasBackend::caret_sel_of(b, input)
  assert_eq(sel0, caret0)
  assert_true(sel0 > 0 && sel0 < 7)
  // 按住右拖到 "bar" 上：锚点不动、活动端跟到更右（选区扩出）
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    2,
    0,
    wptr,
    phys(80.0),
    phys(34.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  let (s1, c1) = @canvas-shared.CanvasBackend::caret_sel_of(b, input)
  assert_eq(s1, sel0)
  assert_true(c1 > s1)
  // 反向拖回文本框左缘外：活动端夹到行首，锚点仍钉在按下处（选区反向）
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    2,
    0,
    wptr,
    phys(22.0),
    phys(34.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  let (s2, c2) = @canvas-shared.CanvasBackend::caret_sel_of(b, input)
  assert_eq(s2, sel0)
  assert_true(c2 < s2)
  // 抬起：拖选结束，形状停在抬起时的反向选区
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    1,
    0,
    wptr,
    phys(22.0),
    phys(34.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq((s2, c2), @canvas-shared.CanvasBackend::caret_sel_of(b, input))
  // 抬起后再移动：不是拖选，选区不动
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    2,
    0,
    wptr,
    phys(90.0),
    phys(34.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq((s2, c2), @canvas-shared.CanvasBackend::caret_sel_of(b, input))
  @moonui.Backend::destroy_widget(b, input)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 多行框跨行编辑（`T389`）：光标越过 `\n`、上下移按 x 对齐、Home 归**可视行**
/// 行首、行首退格吞掉换行把两行并成一行、⌘A 全选跨行。`T374` 的第一刀把多行框
/// 钉在首行，这一刀把它打开。
test "自绘后端：多行框跨行编辑（T389）" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "多行跨行探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let ml = @moonui.Backend::create_widget(
    b,
    @moonui.MultilineEntry,
    "line1\nline2\nline3",
  )
  @moonui.Backend::set_widget_bounds(
    b,
    ml,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 48.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [ml])
  @moonui.Backend::set_focus_chain(b, win, [ml])
  let mk = fn(name : String, meta : Bool) -> @moonui.KeyPress {
    @moonui.KeyPress::{
      key: name,
      ctrl: false,
      alt: false,
      shift: false,
      meta,
    }
  }
  let key = fn(name : String) -> Bool {
    @canvas-shared.CanvasBackend::translate_key(b, win, mk(name, false), true)
  }
  let _ = @moonui.Backend::poll_event(b)
  // Tab → 多行框，光标落末尾（line3 之后 = 17）
  assert_true(key("Tab"))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (17, 17))
  // 右移在末尾不动；左移越过 `\n`（`T374` 的第一刀夹在首行末尾）
  assert_true(key("Right"))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (17, 17))
  assert_true(key("Left"))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (16, 16))
  // Down 顶到末行不动；Up 到第二行同一列（列 4 = 下标 10，不是行尾）
  assert_true(key("Down"))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (16, 16))
  assert_true(key("Up"))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (10, 10))
  // Home 归当前可视行行首（6，不是整串 0），敲 Z 插在第二行开头
  assert_true(key("Home"))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (6, 6))
  assert_true(key("Z"))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@moonui.Backend::widget_text(b, ml), "line1\nZline2\nline3")
  // 插完 Z 光标在 7（Z 之后），按 Home 退回本行行首 6，再退格吞掉换行
  assert_true(key("Home"))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (6, 6))
  // 行首退格吞掉换行：两行并成一行
  assert_true(key("Backspace"))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@moonui.Backend::widget_text(b, ml), "line1Zline2\nline3")
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (5, 5))
  // ⌘A 全选跨行（含两个 `\n`）→ ⌘C 复制整段
  @canvas-shared.CanvasBackend::set_clipboard_for_testing(b, "")
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("a", true), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (0, 17))
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("c", true), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@moonui.Backend::clipboard_text(b), Some("line1Zline2\nline3"))
  @moonui.Backend::destroy_widget(b, ml)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 多行框换行（`T389`）：一行比框宽就断成两条可视行，Home 归**断行后那半行**的
/// 行首（不是整串 0）；光标在断行首再退格，删掉的就是换行处那个词尾字符。
test "自绘后端：多行框断行与 Home 归可视行首（T389）" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "多行断行探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let ml = @moonui.Backend::create_widget(
    b,
    @moonui.MultilineEntry,
    "hello world",
  )
  @moonui.Backend::set_widget_bounds(
    b,
    ml,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(60.0, 48.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [ml])
  @moonui.Backend::set_focus_chain(b, win, [ml])
  let mk = fn(name : String, meta : Bool) -> @moonui.KeyPress {
    @moonui.KeyPress::{
      key: name,
      ctrl: false,
      alt: false,
      shift: false,
      meta,
    }
  }
  let key = fn(name : String) -> Bool {
    @canvas-shared.CanvasBackend::translate_key(b, win, mk(name, false), true)
  }
  let _ = @moonui.Backend::poll_event(b)
  assert_true(key("Tab"))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (11, 11))
  // Home 归**断行后那半行**的行首：既不是整串 0、也不是末尾 11——断行真发生了
  assert_true(key("Home"))
  let _ = @moonui.Backend::poll_event(b)
  let hs = @canvas-shared.CanvasBackend::caret_sel_of(b, ml).0
  assert_true(hs > 1 && hs < 11)
  // End 归可视行尾（断行那半行的末尾 = 整串末尾 11）
  assert_true(key("End"))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (11, 11))
  // 回到断行首再退格：删掉的就是断行处那个字符
  assert_true(key("Home"))
  let _ = @moonui.Backend::poll_event(b)
  assert_true(key("Backspace"))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@moonui.Backend::widget_text(b, ml).length(), 10)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (hs - 1, hs - 1))
  @moonui.Backend::destroy_widget(b, ml)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 多行框滚动跟随光标（`T389`）：内容比框高时，光标跑到框外得把内容滚上来；
/// 逐行上移把滚动量减回 0。
test "自绘后端：多行框滚动跟随光标（T389）" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "多行滚动探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let ml = @moonui.Backend::create_widget(
    b,
    @moonui.MultilineEntry,
    "l00\nl01\nl02\nl03\nl04\nl05\nl06\nl07\nl08\nl09\nl10\nl11",
  )
  @moonui.Backend::set_widget_bounds(
    b,
    ml,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 48.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [ml])
  @moonui.Backend::set_focus_chain(b, win, [ml])
  let mk = fn(name : String) -> @moonui.KeyPress {
    @moonui.KeyPress::{
      key: name,
      ctrl: false,
      alt: false,
      shift: false,
      meta: false,
    }
  }
  let key = fn(name : String) -> Bool {
    @canvas-shared.CanvasBackend::translate_key(b, win, mk(name), true)
  }
  let _ = @moonui.Backend::poll_event(b)
  // Tab → 光标落末尾（最后一行 33），滚动量到 0
  assert_true(key("Tab"))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::scroll_y_of(b, ml), 0.0)
  // 末行再按一次 Right（不动，但重算滚动）→ 内容滚到最底
  assert_true(key("Right"))
  let _ = @moonui.Backend::poll_event(b)
  assert_true(@canvas-shared.CanvasBackend::scroll_y_of(b, ml) > 100.0)
  // 逐行上移：12 行文本，11 次 Up 回到首行，滚动量回 0
  for i = 0; i < 11; i = i + 1 {
    assert_true(key("Up"))
    let _ = @moonui.Backend::poll_event(b)
  }
  assert_eq(@canvas-shared.CanvasBackend::scroll_y_of(b, ml), 0.0)
  @moonui.Backend::destroy_widget(b, ml)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 多行框点击定位与拖选（`T389`）：点击按 y 挑可视行再在行内按 x 定位；按住
/// 拖动跨行扩选区时锚点钉在按下处。
test "自绘后端：多行框点击定位与拖选跨行（T389）" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "多行点击探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let ml = @moonui.Backend::create_widget(b, @moonui.MultilineEntry, "ab\ncd")
  @moonui.Backend::set_widget_bounds(
    b,
    ml,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 48.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [ml])
  @moonui.Backend::set_focus_chain(b, win, [ml])
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  let scale = @moonui.Backend::window_scale(b, win)
  let phys = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  // 落一帧：量字定位要画布先收过帧
  let _ = @moonui.Backend::poll_event(b)
  // 点在第二行 "cd" 的右边（x 超出整行宽），按 y 挑到第二行、行内落到行尾 5
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(60.0),
    phys(53.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (5, 5))
  // 同样的 x、点在首行：按 y 挑回首行、行内落到行首 0
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(28.0),
    phys(30.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (0, 0))
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    1,
    0,
    wptr,
    phys(28.0),
    phys(30.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  // 从首行行首按下、拖到第二行末尾：锚点钉在 0、活动端跟到 5（跨行选区）
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(28.0),
    phys(30.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (0, 0))
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    2,
    0,
    wptr,
    phys(60.0),
    phys(53.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (0, 5))
  @moonui.Backend::destroy_widget(b, ml)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 多行选区像素（`T389`）：跨两行的选区每行各画一段；两行中段各取一个点验
/// 反白蓝底主导，框外同高度不是。
test "自绘后端：多行选区逐行画出（T389）" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "多行选区像素探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let ml = @moonui.Backend::create_widget(
    b,
    @moonui.MultilineEntry,
    "a      \nb      ",
  )
  @moonui.Backend::set_widget_bounds(
    b,
    ml,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 48.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [ml])
  @moonui.Backend::set_focus_chain(b, win, [ml])
  let mk = fn(name : String, shift : Bool) -> @moonui.KeyPress {
    @moonui.KeyPress::{
      key: name,
      ctrl: false,
      alt: false,
      shift,
      meta: false,
    }
  }
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Tab", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  let scale = @moonui.Backend::window_scale(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  // Tab → 光标落末尾 15；⌘A 全选 → 选区 [0,15) 覆盖两行整行（含 `\n`）
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (15, 15))
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(
      b,
      win,
      @moonui.KeyPress::{
        key: "a",
        ctrl: false,
        alt: false,
        shift: false,
        meta: true,
      },
      true,
    ),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (0, 15))
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  // 两行整行都选中；取样 x=44 落在首字符（x≈28..35）之后、行尾之前——那一段
  // 是**空格列**（每行是 "字母 + 6 空格"），没有字形，反白重画不碰它，
  // 读到的就是实底强调蓝 0x335EEA（`T389` 反白 = alpha 255）。
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(44.0), px(36.0)),
    0x335EEA,
  )
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(44.0), px(55.0)),
    0x335EEA,
  )
  // 框外同高度不是蓝底
  let far = @native-common.canvas_read_pixel(canvas, px(44.0), px(100.0))
  assert_true((far & 0xFF) < ((far >> 16) & 0xFF) + 40)
  @moonui.Backend::destroy_widget(b, ml)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// IME 代理接管期间（`T393`）：`T375` 把键盘整体交给隐形 NSTextView，但代理只
/// 镜像文本与插入点、不管理选区账——真窗里 Shift+方向键与拖选因此选不中。
/// 修复后：导航/选区键仍归本层（`apply_edit`），文本编辑键仍交代理（不双插），
/// `ime_pump` 只在文本真变了才同步光标。
test "自绘后端：IME 接管时选区键与拖选仍生效（T393）" {
  let b = @canvas-shared.CanvasBackend::for_testing(300, ime_proxy=true)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "IME 选区探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let ml = @moonui.Backend::create_widget(b, @moonui.MultilineEntry, "ab\ncd")
  @moonui.Backend::set_widget_bounds(
    b,
    ml,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 48.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [ml])
  @moonui.Backend::set_focus_chain(b, win, [ml])
  let mk = fn(name : String, shift : Bool) -> @moonui.KeyPress {
    @moonui.KeyPress::{
      key: name,
      ctrl: false,
      alt: false,
      shift,
      meta: false,
    }
  }
  let key = fn(name : String, shift : Bool) -> Bool {
    @canvas-shared.CanvasBackend::translate_key(b, win, mk(name, shift), true)
  }
  let _ = @moonui.Backend::poll_event(b)
  // Tab → 多行框，光标落末尾 5（`T389` 全串）。IME 代理此时接管（无头
  // `for_testing(ime_proxy=true)` 与 `T375` 同一条路；若环境没接管则退裸键，
  // 下面的断言两边一致）。
  assert_true(key("Tab", false))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (5, 5))
  // 普通 Left 仍移光标（导航键归本层，即使 IME 接管）
  assert_true(key("Left", false))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (4, 4))
  // Shift+Left 扩出选区：锚点钉 4、活动端 3；`ime_pump` 不得把它折叠回去
  assert_true(key("Left", true))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (4, 3))
  // 字符键在 IME 接管时交代理：本层不插（否则双插）
  assert_true(key("a", false))
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@moonui.Backend::widget_text(b, ml), "ab\ncd")
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (4, 3))
  // 拖选：按下首行行首、拖到第二行末尾——锚点钉 0、活动端 5，`ime_pump` 不覆盖
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  let scale = @moonui.Backend::window_scale(b, win)
  let phys = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(28.0),
    phys(30.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (0, 0))
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    2,
    0,
    wptr,
    phys(60.0),
    phys(53.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (0, 5))
  @moonui.Backend::destroy_widget(b, ml)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// 选区不随光标暗相位闪烁（`T394`）：`caret_of` 原先把暗相位折叠成 -1，而
/// 配方的选区条件 `caret>=0` 用它当门——光标一暗，选区跟着消失，真窗里就是
/// "选中文本背景色随光标闪烁"。修复后 `caret` 只还下标、光标线明暗独立成
/// `caret_visible`；这条验暗相位下选区仍在（蓝色主导），且相位真翻到暗
/// （收到补发的 Frame 才继续）。
test "自绘后端：选区不随光标暗相位闪烁（T394）" {
  let b = @canvas-shared.CanvasBackend::for_testing(300)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "选区不闪探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let input = @moonui.Backend::create_widget(b, @moonui.TextInput, "")
  @moonui.Backend::set_widget_bounds(
    b,
    input,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 28.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [input])
  @moonui.Backend::set_focus_chain(b, win, [input])
  let scale = @moonui.Backend::window_scale(b, win)
  let px = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  let mk = fn(name : String, shift : Bool) -> @moonui.KeyPress {
    @moonui.KeyPress::{
      key: name,
      ctrl: false,
      alt: false,
      shift,
      meta: false,
    }
  }
  let _ = @moonui.Backend::poll_event(b)
  let canvas = @canvas-shared.CanvasBackend::window_canvas(b, win)
  // 取焦 + 敲 abc，再 Home + Shift+End → 选区 [0,3)，光标 3
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Tab", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  let _ = @moonui.Backend::poll_event(b)
  for ch in ["a", "b", "c"] {
    assert_true(
      @canvas-shared.CanvasBackend::translate_key(b, win, mk(ch, false), true),
    )
    let _ = @moonui.Backend::poll_event(b)
    let _ = @moonui.Backend::poll_event(b)
  }
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Home", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("End", true), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, input), (0, 3))
  // 选段横线上有蓝主导像素（同 T387 的稳健采样：单点 px(29),px(34) 会落在
  // 反白字形上，mac/linux 字体度量不同，断言单像素即 flaky）
  let blue = fn() -> Bool raise { selection_blue_on_line(canvas, px, 34.0) }
  // 亮相位（`for_testing` 默认常亮）：选区蓝
  assert_true(blue())
  // 拨到暗相位（600ms > 半周期 530ms），等补发的 Frame——收到 Frame 即相位
  // 真翻到暗（caret_tick 只在翻转时补 Frame）
  @canvas-shared.CanvasBackend::set_caret_phase_for_testing(b, 600)
  let mut saw_dark = false
  for i = 0; i < 4; i = i + 1 {
    match @moonui.Backend::poll_event(b) {
      Some(@moonui.Frame(t)) =>
        if t == @moonui.EventTarget::of(win) {
          saw_dark = true
          break
        }
      Some(_) => ()
      None => break
    }
  }
  assert_true(saw_dark)
  // 暗相位：选区**仍在**（修复前这里变回窗底 0xF5F5F7）
  assert_true(blue())
  // 拨回亮相位：选区仍在
  @canvas-shared.CanvasBackend::set_caret_phase_for_testing(b, 0)
  let mut saw_light = false
  for i = 0; i < 4; i = i + 1 {
    match @moonui.Backend::poll_event(b) {
      Some(@moonui.Frame(t)) =>
        if t == @moonui.EventTarget::of(win) {
          saw_light = true
          break
        }
      Some(_) => ()
      None => break
    }
  }
  assert_true(saw_light)
  assert_true(blue())
  @moonui.Backend::destroy_widget(b, input)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}

///|
/// IME 接管时拖选后直接打字插在选区（`T395`/`T393` 已知边界）：代理接管期间
/// 只镜像文本与插入点、不管理选区账——拖选/点击定位/Shift 扩选后代理的
/// `selectedRange` 还停在旧插入点，直接打字会插在旧位置而不是选区活动端。
/// 修复后 `caret_seek`/`apply_edit` 把本层 (caret, sel) 经 `canvas_ime_set_selection`
/// 推回代理，打字落在正确位置（有选区则替换整段）。
test "自绘后端：IME 接管时拖选后直接打字插在选区（T395）" {
  let b = @canvas-shared.CanvasBackend::for_testing(300, ime_proxy=true)
  @moonui.Backend::init(b)
  let win = @moonui.Backend::create_window(
    b,
    "拖选打字探针",
    @moonui.LogicalSize(200.0, 120.0),
  )
  let ml = @moonui.Backend::create_widget(b, @moonui.MultilineEntry, "ab\ncd")
  @moonui.Backend::set_widget_bounds(
    b,
    ml,
    @moonui.LogicalRect(
      @moonui.LogicalPoint(20.0, 20.0),
      @moonui.LogicalSize(140.0, 48.0),
    ),
  )
  @moonui.Backend::set_paint_order(b, win, [ml])
  @moonui.Backend::set_focus_chain(b, win, [ml])
  let wptr = @native-common.NativeBackend::window_ptr(b.inner, win)
  let scale = @moonui.Backend::window_scale(b, win)
  let phys = fn(v : Double) -> Int32 { (v * scale.x + 0.5).floor().to_int() }
  let mk = fn(name : String, shift : Bool) -> @moonui.KeyPress {
    @moonui.KeyPress::{
      key: name,
      ctrl: false,
      alt: false,
      shift,
      meta: false,
    }
  }
  let _ = @moonui.Backend::poll_event(b)
  // Tab 取焦：IME 接管，光标落末尾 5
  assert_true(
    @canvas-shared.CanvasBackend::translate_key(b, win, mk("Tab", false), true),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (5, 5))
  // 拖选：按下首行行首（caret=0）、拖到第二行末尾（活动端 5，锚点钉 0）
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(28.0),
    phys(30.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  @canvas-shared.CanvasBackend::translate_mouse(
    b,
    2,
    0,
    wptr,
    phys(60.0),
    phys(53.0),
  )
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (0, 5))
  // 直接打字：交给代理 `insertText`，应替换整段 [0,5) → "X"（代理插点已被
  // `caret_seek` 推回选区；修复前代理插点停在 5，会插成 "ab\ncdX"）
  assert_eq(@native-common.canvas_ime_commit_in_window(wptr, "X"), 0)
  let _ = @moonui.Backend::poll_event(b)
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(@moonui.Backend::widget_text(b, ml), "X")
  assert_eq(@canvas-shared.CanvasBackend::caret_sel_of(b, ml), (1, 1))
  @moonui.Backend::destroy_widget(b, ml)
  @moonui.Backend::destroy_window(b, win)
  @moonui.Backend::terminate(b)
}
