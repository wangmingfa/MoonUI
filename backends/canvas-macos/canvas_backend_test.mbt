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

///|
/// 句柄编号空间分家（回归）：窗口句柄来自 native-common 的进程级句柄表
/// （从 0 起），自绘记账句柄若也从 0 起，第一只控件就和第一扇窗同号。
/// Core 的 `dispatch_round` 先比窗口臂、再找控件，同号时发给控件的事件
/// 会被当成发给窗口（`Window::handle_event` 只认 Resize/Close），控件的
/// 点击 handler 永远不跑——T367 的按钮点了没反应就是这条。
test "自绘后端：控件句柄与窗口句柄不同号" {
  let b = @canvas-macos.CanvasBackend::for_testing(200)
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
  let b = @canvas-macos.CanvasBackend::for_testing(200)
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
  @canvas-macos.CanvasBackend::translate_mouse(
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
  let b = @canvas-macos.CanvasBackend::for_testing(50)
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
  assert_true(@canvas-macos.CanvasBackend::translate_key(b, win, tab, true))
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.KeyDown(t, _)) && t == tw,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == ta,
  )
  // ② 第二颗：键给旧焦点 a，Blur(a) → Focus(c)
  assert_true(@canvas-macos.CanvasBackend::translate_key(b, win, tab, true))
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
  assert_true(@canvas-macos.CanvasBackend::translate_key(b, win, tab, true))
  let _ = @moonui.Backend::poll_event(b) // KeyDown(c)
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Blur(t)) && t == tc,
  )
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == ta,
  )
  // ④ Shift+Tab 反向：a 往前一回落到 c
  assert_true(
    @canvas-macos.CanvasBackend::translate_key(
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
    @canvas-macos.CanvasBackend::translate_key(b, win, mk_key("=", false), true),
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
    !@canvas-macos.CanvasBackend::translate_key(
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
  @canvas-macos.CanvasBackend::translate_mouse(
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
/// 焦点环（`T370`）：只有正握焦点的记账沿边画一圈强调色描边——内缩 1px、
/// 线宽 2px，整圈落在控件矩形内；取焦/收回后下一帧跟着出现/消失。像素逐位核。
test "自绘后端：焦点环只画在正握焦点的记账上" {
  let b = @canvas-macos.CanvasBackend::for_testing(300)
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
  let canvas = @canvas-macos.CanvasBackend::window_canvas(b, win)
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
  assert_true(@canvas-macos.CanvasBackend::translate_key(b, win, tab, true))
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
/// 键窗生命周期（`T371`）：成键把首焦点交给链头、失键清焦点补 `Blur`，两次
/// 迁移都同一帧重画；焦点环的颜色随 `style_base` 下发的 accent。键窗探针是
/// 测试覆盖口，不靠真窗。
test "自绘后端：成键落首焦点、失键清焦点、焦点环跟 accent" {
  let b = @canvas-macos.CanvasBackend::for_testing(300)
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
  @canvas-macos.CanvasBackend::set_key_probe_for_testing(b, Some(0))
  let ev0 = @moonui.Backend::poll_event(b)
  assert_false(ev0 is Some(@moonui.Focus(_)))
  let canvas = @canvas-macos.CanvasBackend::window_canvas(b, win)
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(11.0), px(20.0)),
    0xF5F5F7,
  )
  // ② 成键：首焦点落到链头 ta，同一帧画出 accent 环
  @canvas-macos.CanvasBackend::set_key_probe_for_testing(b, Some(1))
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == ta_t,
  )
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(11.0), px(20.0)),
    0x0099FF,
  )
  // ③ 失键：清焦点、补 Blur，同一帧环消失
  @canvas-macos.CanvasBackend::set_key_probe_for_testing(b, Some(0))
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Blur(t)) && t == ta_t,
  )
  assert_eq(
    @native-common.canvas_read_pixel(canvas, px(11.0), px(20.0)),
    0xF5F5F7,
  )
  // ④ 再成键：焦点回到首项（失键时没记位置，这是既定语义）
  @canvas-macos.CanvasBackend::set_key_probe_for_testing(b, Some(1))
  assert_true(
    @moonui.Backend::poll_event(b) is Some(@moonui.Focus(t)) && t == ta_t,
  )
  @canvas-macos.CanvasBackend::set_key_probe_for_testing(b, None)
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
  let b = @canvas-macos.CanvasBackend::for_testing(300)
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
  let canvas = @canvas-macos.CanvasBackend::window_canvas(b, win)
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
  let b = @canvas-macos.CanvasBackend::for_testing(300)
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
  let canvas = @canvas-macos.CanvasBackend::window_canvas(b, win)
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
  let b = @canvas-macos.CanvasBackend::for_testing(300)
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
  let canvas = @canvas-macos.CanvasBackend::window_canvas(b, win)
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
  let b = @canvas-macos.CanvasBackend::for_testing(300)
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
  let canvas = @canvas-macos.CanvasBackend::window_canvas(b, win)
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
  let b = @canvas-macos.CanvasBackend::for_testing(300)
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
  let canvas = @canvas-macos.CanvasBackend::window_canvas(b, win)
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
