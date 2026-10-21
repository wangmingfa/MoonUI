///|
/// `T101` 的 Core 侧判据：自定义绘制面（`WidgetKind::Custom`）的尺寸协商、
/// 绘制时机与清单内容。全部在 mock 上跑（wasm 门），不需要开窗——清单是纯
/// 数据，"画了什么、按什么参数画"就是这一层的全部语义；像不像，归后端。

///|
/// 浮点比较：绘制清单里的坐标是量出来的（`(w - tw) / 2`），逐位比会脆。
fn near(a : Double, b : Double) -> Bool {
  let d = a - b
  (if d < 0.0 { -d } else { d }) < 0.000001
}

///|
test "自定义绘制面：声明尺寸进布局，摆出来就画一帧（T101）" {
  let b = mock_widgets()
  let sizes : Array[LogicalSize] = []
  let w = Widget::custom(b, LogicalSize(120.0, 48.0), fn(dl, env) {
    sizes.push(env.size)
    dl.fill_rect(0.0, 0.0, env.width(), env.height(), radius=6.0, rgb=0x2B6CB0)
    let (tw, th) = env.measure_text("42%", 14.0, true)
    dl.text(
      "42%",
      (env.width() - tw) / 2.0,
      (env.height() - th) / 2.0,
      size=14.0,
      bold=true,
      rgb=0xFFFFFF,
    )
  })
  // 固有尺寸取声明值（后端在这条上没有意见）
  assert_eq(w.intrinsic_size(), LogicalSize(120.0, 48.0))
  assert_eq(w.kind(), WidgetKind::Custom)
  // 还没摆出来：一次都没画（`do_layout` 里 set_bounds 才是绘制时机）
  assert_eq(sizes.length(), 0)
  let row = Widget::row(b, 8.0, [w])
  let _ = row.do_layout(
    LogicalRect(LogicalPoint(10.0, 20.0), LogicalSize(240.0, 60.0)),
  )
  assert_eq(
    w.bounds(),
    LogicalRect(LogicalPoint(10.0, 20.0), LogicalSize(120.0, 48.0)),
  )
  // 摆出来那一刻画了一帧，环境给的尺寸就是这块面的尺寸
  assert_eq(sizes.length(), 1)
  assert_eq(sizes[0], LogicalSize(120.0, 48.0))
  // 清单进了后端：两条命令，坐标是**控件局部**（原点左上）
  let h = match w.handle() {
    Some(h) => h
    None => abort("unreachable")
  }
  let dl = match b.widget(h).custom_draw {
    Some(dl) => dl
    None => abort("自定义绘制面没画过")
  }
  assert_eq(dl.len(), 2)
  // 逐条比，不把整串打进失败消息：`Show` 在插值里已弃用，而 `Debug` 的
  // 断言差异由 `assert_eq` 自己给——直接比枚举值比"打一行日志"信息更多。
  let cmds = dl.commands()
  match cmds[0] {
    FillRect(x, y, rw, rh, radius, rgb, alpha) => {
      assert_eq((x, y, rw, rh), (0.0, 0.0, 120.0, 48.0))
      assert_eq((radius, rgb, alpha), (6.0, 0x2B6CB0, 255))
    }
    _ => fail("第 1 条命令不是填充矩形")
  }
  match cmds[1] {
    Text(text, tx, ty, size, bold, fg) => {
      assert_eq(text, "42%")
      assert_true(near(tx, 42.5)) // (120 - 3*8*(14/12)*1.25) / 2
      assert_true(near(ty, 14.666666)) // (48 - 16*(14/12)) / 2
      assert_eq((size, bold, fg), (14.0, true, 0xFFFFFF))
    }
    _ => fail("第 2 条命令不是文本")
  }
}

///|
test "自定义绘制面：repaint 整份替换，非 Custom 上是空操作（T101）" {
  let b = mock_widgets()
  let mut value = 1
  let w = Widget::custom(b, LogicalSize(80.0, 40.0), fn(dl, env) {
    // 每帧按当下的 value 画 value 条线：清单该跟着数据变，不该攒着旧的
    for i = 0; i < value; i = i + 1 {
      dl.line(
        0.0,
        (i + 1).to_double(),
        env.width(),
        (i + 1).to_double(),
        rgb=0xFF0000,
      )
    }
  })
  let _ = w.do_layout(
    LogicalRect(LogicalPoint(0.0, 0.0), LogicalSize(80.0, 40.0)),
  )
  let h = match w.handle() {
    Some(h) => h
    None => abort("unreachable")
  }
  assert_eq(b.widget(h).custom_draw.unwrap().len(), 1)
  value = 3
  w.repaint()
  assert_eq(b.widget(h).custom_draw.unwrap().len(), 3)
  w.repaint()
  assert_eq(b.widget(h).custom_draw.unwrap().len(), 3)
  // 非 Custom：重画请求无意义但不算错（多调一次不该是个错误）
  let label = Widget::label(b, "hi")
  let _ = label.do_layout(
    LogicalRect(LogicalPoint(0.0, 0.0), LogicalSize(60.0, 20.0)),
  )
  label.repaint()
}

///|
test "自定义绘制面：没有文本属性，绘制回调缺席时是合法空面（T101）" {
  let b = mock_widgets()
  // 空面：先占位、后接画法（与图片控件后补图像源同一条路）
  let blank = Widget::custom(b, LogicalSize(30.0, 30.0), fn(_dl, _env) {  })
  let _ = blank.do_layout(
    LogicalRect(LogicalPoint(0.0, 0.0), LogicalSize(30.0, 30.0)),
  )
  let hb = blank.handle().unwrap()
  assert_eq(b.widget(hb).custom_draw.unwrap().len(), 0)
  // kind 规矩与其它属性一致：文本/数值/勾选都不属于它
  assert_eq(
    widget_error(fn() raise UiError { blank.set_text("x") }),
    Some("不支持的操作：该控件没有文本属性"),
  )
  assert_eq(
    widget_error(fn() raise UiError { blank.set_value(1) }),
    Some("不支持的操作：该控件没有数值属性"),
  )
}

///|
test "自定义绘制面：.width()/.height() 覆盖声明尺寸（T101）" {
  let b = mock_widgets()
  let w = Widget::custom(b, LogicalSize(100.0, 50.0), fn(_dl, _env) {  })
  assert_eq(w.intrinsic_size(), LogicalSize(100.0, 50.0))
  let _ = w.width(140.0)
  assert_eq(w.intrinsic_size(), LogicalSize(140.0, 50.0))
  let _ = w.height(70.0)
  assert_eq(w.intrinsic_size(), LogicalSize(140.0, 70.0))
}

///|
/// 尺寸为零时不开帧：还没摆出来的控件每只都是 0×0，那种帧没有任何东西可画
/// （后端那边开帧也会当场拒绝）。
test "自定义绘制面：零尺寸不画（T101）" {
  let b = mock_widgets()
  let paints : Array[LogicalSize] = []
  let w = Widget::custom(b, LogicalSize(0.0, 0.0), fn(dl, env) {
    paints.push(env.size)
    dl.fill_rect(0.0, 0.0, 1.0, 1.0, rgb=0x000000)
  })
  let _ = w.do_layout(
    LogicalRect(LogicalPoint(0.0, 0.0), LogicalSize(0.0, 0.0)),
  )
  assert_eq(paints.length(), 0)
}

///|
/// 键盘焦点的 opt-in（`T102` 第十一刀）：默认**关**，声明了才到后端。
///
/// 默认关是这条的要点：自绘面是裸 `NSView`，恒 `YES` 会把每块"只画点东西"的
/// 面塞进 Tab 链、还会在点击时从文本框手里抢走焦点（`Backend` 段注）。
/// 负控制两条：没声明的那块面在同一个后端上仍是关；非 `Custom` 的控件调这条
/// 是空操作——不报错、也不记账（文档口径就是"只对自绘面有意义"）。
test "自定义绘制面：焦点 opt-in 默认关，声明才生效（T102）" {
  let b = mock_widgets()
  let plain = Widget::custom(b, LogicalSize(40.0, 30.0), fn(_dl, _env) {  })
  let hp = plain.handle().unwrap()
  assert_false(b.custom_focusable(hp))
  let keys = Widget::custom(
    b,
    LogicalSize(40.0, 30.0),
    fn(_dl, _env) {  },
    focusable=true,
  )
  assert_true(b.custom_focusable(keys.handle().unwrap()))
  // 负控制①：同一后端上没声明的那块面没被连带打开
  assert_false(b.custom_focusable(hp))
  // 负控制②：label 不是自绘面，调用是空操作
  let label = Widget::label(b, "x")
  let hl = label.handle().unwrap()
  let _ = Backend::set_custom_focusable(b, hl, true)
  assert_false(b.custom_focusable(hl))
  assert_eq(label.kind(), WidgetKind::Label)
}
