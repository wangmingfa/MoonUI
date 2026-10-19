///|
/// CanvasBackend 的真跑判据：开真窗口、推记账、让 poll_event 收帧，然后
/// 直接读挂窗画布的像素——面板底色、标签字迹、滑条已过段逐位核。
/// 不 pump 到有人工事件为止（`for_testing` 的有限预算），不与真鼠标交错。
test "自绘后端：记账 → 收帧 → 画布像素逐位对得上" {
  let b = @canvas-macos.CanvasBackend::for_testing(300)
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
  let canvas = @canvas-macos.CanvasBackend::window_canvas(b, win)
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
  let b = @canvas-macos.CanvasBackend::for_testing(300)
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
  @canvas-macos.CanvasBackend::translate_mouse(
    b,
    2,
    0,
    wptr,
    phys(30.0),
    phys(90.0),
  )
  @canvas-macos.CanvasBackend::translate_mouse(
    b,
    2,
    0,
    wptr,
    phys(100.0),
    phys(30.0),
  )
  // 左键在按钮上按下再抬起：MouseDown + MouseUp + Click（target 都是按钮）
  @canvas-macos.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(100.0),
    phys(30.0),
  )
  @canvas-macos.CanvasBackend::translate_mouse(
    b,
    1,
    0,
    wptr,
    phys(100.0),
    phys(30.0),
  )
  // 左键在按钮按下、空白抬起：有 Down/Up，没有 Click
  @canvas-macos.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(100.0),
    phys(30.0),
  )
  @canvas-macos.CanvasBackend::translate_mouse(
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
    ev3 is Some(@moonui.MouseDown(t, @moonui.Left, _)) && t == button_target,
  )
  let ev4 = @moonui.Backend::poll_event(b)
  assert_true(
    ev4 is Some(@moonui.MouseUp(t, @moonui.Left, _)) && t == button_target,
  )
  let ev5 = @moonui.Backend::poll_event(b)
  assert_true(ev5 is Some(@moonui.Click(t, @moonui.Left)) && t == button_target)
  let ev6 = @moonui.Backend::poll_event(b)
  assert_true(
    ev6 is Some(@moonui.MouseDown(t, @moonui.Left, _)) && t == button_target,
  )
  let ev7 = @moonui.Backend::poll_event(b)
  assert_true(
    ev7 is Some(@moonui.MouseUp(t, @moonui.Left, _)) && t == win_target,
  )
  let ev8 = @moonui.Backend::poll_event(b)
  assert_true(ev8 is None)
  @moonui.Backend::terminate(b)
}

///|
/// 按钮三态的画账：悬停/按下由记账侧自己翻（Core 的 hover 样式是另一条
/// 通道），收帧后读画布像素逐位核三种底色。
test "自绘后端：按钮三态换色，悬停/按下像素逐位核" {
  let b = @canvas-macos.CanvasBackend::for_testing(300)
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
    let c = @canvas-macos.CanvasBackend::window_canvas(b, win)
    @native-common.canvas_read_pixel(c, phys(15.0), phys(25.0))
  }
  // 常态：0xE8E8EB（圆角外的钮底默认色）
  let _ = @moonui.Backend::poll_event(b)
  assert_eq(center_px(), 0xE8E8EB)
  // 悬停：0xDCDCE0
  @canvas-macos.CanvasBackend::translate_mouse(
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
  @canvas-macos.CanvasBackend::translate_mouse(
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
  @canvas-macos.CanvasBackend::translate_mouse(
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
  @canvas-macos.CanvasBackend::translate_mouse(
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
  let b = @canvas-macos.CanvasBackend::for_testing(300)
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
  @canvas-macos.CanvasBackend::translate_mouse(
    b,
    0,
    0,
    wptr,
    phys(60.0),
    phys(30.0),
  )
  assert_eq(@moonui.Backend::widget_value(b, slider), 500)
  // 拖到 3/4：值 750，再报一条 Change
  @canvas-macos.CanvasBackend::translate_mouse(
    b,
    2,
    0,
    wptr,
    phys(85.0),
    phys(30.0),
  )
  assert_eq(@moonui.Backend::widget_value(b, slider), 750)
  // 抬起：有 MouseUp，没有 Click
  @canvas-macos.CanvasBackend::translate_mouse(
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
        let tag = if ev is @moonui.MouseDown(_, _, _) {
          "down"
        } else if ev is @moonui.Change(_) {
          "change"
        } else if ev is @moonui.MouseMove(_, _) {
          "move"
        } else if ev is @moonui.MouseUp(_, _, _) {
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
  let b = @canvas-macos.CanvasBackend::for_testing(300)
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
  let canvas = @canvas-macos.CanvasBackend::window_canvas(b, win)
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
  let b = @canvas-macos.CanvasBackend::for_testing(300)
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
  let canvas = @canvas-macos.CanvasBackend::window_canvas(b, win)
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
  let b = @canvas-macos.CanvasBackend::for_testing(300)
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
  @canvas-macos.CanvasBackend::translate_mouse(
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
  @canvas-macos.CanvasBackend::translate_mouse(
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
  @canvas-macos.CanvasBackend::translate_mouse(
    b,
    0,
    2,
    wptr,
    phys(100.0),
    phys(25.0),
  )
  @canvas-macos.CanvasBackend::translate_mouse(
    b,
    1,
    2,
    wptr,
    phys(100.0),
    phys(25.0),
  )
  match @moonui.Backend::poll_event(b) {
    Some(@moonui.MouseDown(t, @moonui.Middle, _)) =>
      assert_true(t == button_target)
    _ => assert_true(false, msg="中键按下应产 MouseDown Middle")
  }
  match @moonui.Backend::poll_event(b) {
    Some(@moonui.MouseUp(t, @moonui.Middle, _)) =>
      assert_true(t == button_target)
    _ => assert_true(false, msg="中键抬起应产 MouseUp Middle")
  }
  // 离开窗口（kind 5）落在空白：MouseMove，target 落回窗口（unhover 信号）
  @canvas-macos.CanvasBackend::translate_mouse(
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
  let b = @canvas-macos.CanvasBackend::for_testing(300)
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
  let canvas = @canvas-macos.CanvasBackend::window_canvas(b, win)
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
