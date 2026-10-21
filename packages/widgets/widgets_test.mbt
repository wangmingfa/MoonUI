///|
/// `packages/widgets` 的第一批判据（`T107`）。
///
/// 这一层测的是**配方**：控件摆进布局之后，后端收到的那份 `DrawList` 里到底是
/// 什么命令、按什么参数。所以全部跑在 `MockBackend` 上（`T101` 给它加了
/// `draw_custom` 与 `drawn()` 读回口），不需要开窗、也不需要真像素——"像不像"
/// 归后端，"画了什么"归这里。`widgets` 只 import Core，于是这些判据在 wasm 门
/// 里同样成立，这是"一份配方、三个后端"的第一层证明。

///|
/// 浮点比较：坐标都是乘除算出来的（圆心 + 半径 × cos），逐位比会脆；
/// 容差 0.001 逻辑像素——比它更细的差在屏幕上是同一格像素。
fn near(a : Double, b : Double) -> Bool {
  let d = a - b
  (if d < 0.0 { -d } else { d }) < 0.001
}

///|
/// 初始化过的 mock（`T101` 的 `mock_widgets()` 是包内私有的，包外照这个形状来）。
fn mock() -> @moonui.MockBackend raise @moonui.UiError {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  b
}

///|
/// 把控件摆出来，返回它这一帧的绘制清单。
///
/// 为什么要走布局而不是直接调绘制回调：`T101` 的契约是"几何变了才画"，第一次
/// 画就发生在 `do_layout` 里；绕过布局等于绕过了真实触发路径，测到的就不是
/// 用户看到的那个时机。
fn place(
  b : @moonui.MockBackend,
  w : @moonui.Widget[@moonui.MockBackend],
) -> @moonui.DrawList raise @moonui.UiError {
  let row = @moonui.Widget::row(b, 0.0, [w])
  let _ = row.do_layout(
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(400.0, 300.0),
    ),
  )
  let h = match w.handle() {
    Some(h) => h
    None => abort("控件没有原生句柄：它没被摆出来")
  }
  match b.drawn(h) {
    Some(dl) => dl
    None => abort("自定义绘制面一次都没画过")
  }
}

///|
test "ProgressRing：轨道与进度各是一条弧，文案居中（T109）" {
  let b = mock()
  let ring = @widgets.ProgressRing::new(b, 0.25, size=80.0, thickness=8.0)
  let w = ring.widget()
  // 声明尺寸进布局，种类是自绘面；此时还没画（第一次画在 do_layout 里）
  assert_eq(ring.side(), 80.0)
  assert_eq(ring.value(), 0.25)
  assert_eq(w.kind(), @moonui.Custom)
  assert_eq(w.intrinsic_size(), @moonui.LogicalSize(80.0, 80.0))
  let dl = place(b, w)
  // 一条轨道弧 + 一条进度弧 + 一条居中文案（拼折线的年代这里是 73 条）
  assert_eq(dl.len(), 3)
  let cmds = dl.commands()
  // 轨道整圈：圆心 (40, 40)、r = 80/2 - 8/2 = 36、从 0° 扫 360°
  match cmds[0] {
    @moonui.StrokeArc(cx, cy, r, start, sweep, width, rgb) => {
      assert_true(near(cx, 40.0) && near(cy, 40.0))
      assert_true(near(r, 36.0))
      assert_true(near(start, 0.0) && near(sweep, 360.0))
      assert_true(near(width, 8.0))
      assert_eq(rgb, 0xE2E8F0)
    }
    _ => fail("第一条不是轨道弧")
  }
  // 进度：从十二点（-90°）顺时针扫 360 × 0.25 = 90°
  match cmds[1] {
    @moonui.StrokeArc(cx, cy, r, start, sweep, width, rgb) => {
      assert_true(near(cx, 40.0) && near(cy, 40.0))
      assert_true(near(r, 36.0))
      assert_true(near(start, -90.0) && near(sweep, 90.0))
      assert_true(near(width, 8.0))
      assert_eq(rgb, 0x2B6CB0)
    }
    _ => fail("第二条不是进度弧")
  }
  // 文案：自动百分比，字号 = 80 × 0.22 = 17.6，粗体，居中（mock 的度量是
  // 每字符 8×字号/12，粗体再 ×1.25）
  match cmds[2] {
    @moonui.Text(text, x, y, size, bold, rgb) => {
      assert_eq(text, "25%")
      assert_true(near(size, 17.6))
      assert_true(bold)
      assert_eq(rgb, 0x1A202C)
      assert_true(near(x, 18.0)) // (80 - 44) / 2
      assert_true(near(y, 28.266666)) // (80 - 23.466667) / 2
    }
    _ => fail("最后一条不是文案")
  }
  b.terminate()
}

///|
test "ProgressRing：越界夹住，满环/空环/无环的条数对得上（T109）" {
  let b = mock()
  let ring = @widgets.ProgressRing::new(b, 0.0, size=40.0, thickness=4.0)
  let w = ring.widget()
  let _ = place(b, w)
  // 0：只有轨道 + "0%"
  assert_eq(
    match b.drawn(w.handle().unwrap()) {
      Some(dl) => dl.len()
      None => abort("没画过")
    },
    2,
  )
  // 越过 1：夹到 1，进度整圈
  ring.set_value(2.5)
  assert_eq(ring.value(), 1.0)
  let full = match b.drawn(w.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  assert_eq(full.len(), 3)
  match full.commands()[1] {
    @moonui.StrokeArc(_, _, _, start, sweep, _, _) =>
      assert_true(near(start, -90.0) && near(sweep, 360.0))
    _ => fail("满环的第二条不是整圈进度弧")
  }
  match full.commands()[2] {
    @moonui.Text(text, _, _, _, _, _) => assert_eq(text, "100%")
    _ => fail("满环的最后一条不是文案")
  }
  // 低于 0：夹到 0
  ring.set_value(-1.0)
  assert_eq(ring.value(), 0.0)
  // 显式文案覆盖自动百分比
  ring.set_label("dry")
  let named = match b.drawn(w.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  assert_eq(named.len(), 2)
  match named.commands()[1] {
    @moonui.Text(text, _, _, _, _, _) => assert_eq(text, "dry")
    _ => fail("换文案之后第二条不是文案")
  }
  // 关掉文案：只剩轨道那一条
  ring.set_show_label(false)
  let bare = match b.drawn(w.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  assert_eq(bare.len(), 1)
  // 线宽为 0：环整条不画，只留文案（别把 0 宽描边丢给后端）
  let blank = @widgets.ProgressRing::new(b, 0.5, size=40.0, thickness=0.0)
  let bdl = place(b, blank.widget())
  assert_eq(bdl.len(), 1)
  match bdl.commands()[0] {
    @moonui.Text(text, _, _, _, _, _) => assert_eq(text, "50%")
    _ => fail("无环时剩下的那一条不是文案")
  }
  b.terminate()
}

///|
test "Sparkline：折线按值域归一，端点画圆（T107）" {
  let b = mock()
  let spark = @widgets.Sparkline::new(
    b,
    [0.0, 5.0, 10.0],
    width=100.0,
    height=40.0,
    line_width=1.5,
  )
  let w = spark.widget()
  assert_eq(w.kind(), @moonui.Custom)
  assert_eq(w.intrinsic_size(), @moonui.LogicalSize(100.0, 40.0))
  let dl = place(b, w)
  // 两条线段 + 一个端点圆
  assert_eq(dl.len(), 3)
  let cmds = dl.commands()
  // 内边距 = max(线宽/2, 端点半径) + 1 = 4；x 均分 92；y 按 [0,10] 归一
  match cmds[0] {
    @moonui.Line(x0, y0, x1, y1, width, rgb) => {
      assert_true(near(x0, 4.0) && near(y0, 36.0))
      assert_true(near(x1, 50.0) && near(y1, 20.0))
      assert_true(near(width, 1.5))
      assert_eq(rgb, 0x2B6CB0)
    }
    _ => fail("第一条不是线段")
  }
  match cmds[1] {
    @moonui.Line(x0, y0, x1, y1, _, _) => {
      assert_true(near(x0, 50.0) && near(y0, 20.0))
      assert_true(near(x1, 96.0) && near(y1, 4.0))
    }
    _ => fail("第二条不是线段")
  }
  // 端点圆 = 半径 3 的圆角方，圆心落在最后一个点上
  match cmds[2] {
    @moonui.FillRect(x, y, rw, rh, radius, rgb, alpha) => {
      assert_true(near(x, 93.0) && near(y, 1.0))
      assert_true(near(rw, 6.0) && near(rh, 6.0))
      assert_true(near(radius, 3.0))
      assert_eq(rgb, 0x2B6CB0)
      assert_eq(alpha, 255)
    }
    _ => fail("第三条不是端点圆")
  }
  b.terminate()
}

///|
test "Sparkline：空数据不画、单点居中、全等数据走中线（T107）" {
  let b = mock()
  let empty = @widgets.Sparkline::new(b, [], width=60.0, height=30.0)
  let ew = empty.widget()
  assert_eq(place(b, ew).len(), 0)
  // 单点：没有线段，只有一个端点圆，x 居中、y 也居中（值域宽度为 0）
  let one = @widgets.Sparkline::new(b, [7.0], width=60.0, height=30.0)
  let ow = one.widget()
  let one_dl = place(b, ow)
  assert_eq(one_dl.len(), 1)
  match one_dl.commands()[0] {
    @moonui.FillRect(x, y, _, _, _, _, _) =>
      assert_true(near(x, 27.0) && near(y, 12.0))
    _ => fail("单点不是端点圆")
  }
  // 全等数据：值域宽度 0，折线走竖直中线（贴边会被读成"到顶/见底"）
  let flat = @widgets.Sparkline::new(
    b,
    [3.0, 3.0, 3.0],
    width=60.0,
    height=30.0,
  )
  let fw = flat.widget()
  let flat_dl = place(b, fw)
  match flat_dl.commands()[0] {
    @moonui.Line(_, y0, _, y1, _, _) =>
      assert_true(near(y0, 15.0) && near(y1, 15.0))
    _ => fail("全等数据的第一条不是线段")
  }
  b.terminate()
}

///|
test "Sparkline：显式值域夹到边，基线在底边（T107）" {
  let b = mock()
  let spark = @widgets.Sparkline::new(
    b,
    [0.0, 5.0],
    width=100.0,
    height=40.0,
    line_width=1.5,
    baseline=true,
    min=Some(0.0),
    max=Some(10.0),
  )
  let w = spark.widget()
  let dl = place(b, w)
  // 基线 + 一条线段 + 端点
  assert_eq(dl.len(), 3)
  let cmds = dl.commands()
  match cmds[0] {
    @moonui.Line(x0, y0, x1, y1, width, rgb) => {
      assert_true(near(x0, 4.0) && near(y0, 36.0))
      assert_true(near(x1, 96.0) && near(y1, 36.0))
      assert_true(near(width, 1.0))
      assert_eq(rgb, 0xE2E8F0)
    }
    _ => fail("第一条不是基线")
  }
  match cmds[1] {
    @moonui.Line(_, y0, _, y1, _, _) =>
      assert_true(near(y0, 36.0) && near(y1, 20.0))
    _ => fail("第二条不是线段")
  }
  // 域外值夹到边：9 在 [0,4] 里算 9/4 > 1，画在顶边而不是框外
  spark.set_range(min=Some(0.0), max=Some(4.0))
  let clamped = match b.drawn(w.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  match clamped.commands()[1] {
    @moonui.Line(_, y0, _, y1, _, _) =>
      assert_true(near(y0, 36.0) && near(y1, 4.0))
    _ => fail("夹住之后第三条不是线段")
  }
  b.terminate()
}

///|
test "Sparkline：push 走滚动窗口，set_series 整份替换（T107）" {
  let b = mock()
  let spark = @widgets.Sparkline::new(
    b,
    [10.0],
    width=80.0,
    height=20.0,
    max_points=3,
  )
  let w = spark.widget()
  let _ = place(b, w)
  spark.push(20.0)
  spark.push(30.0)
  spark.push(40.0)
  // 超过 3 个就从头部丢弃：留下最近三个
  assert_eq(spark.length(), 3)
  assert_eq(spark.series(), [20.0, 30.0, 40.0])
  // 改完立刻重画：两条线段 + 端点（读的是拷贝，改拷贝不影响控件内部）
  let dl = match b.drawn(w.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  assert_eq(dl.len(), 3)
  let copy = spark.series()
  copy.push(999.0)
  assert_eq(spark.length(), 3)
  // 整份替换不裁剪：给几个画几个
  spark.set_series([1.0, 2.0])
  assert_eq(spark.length(), 2)
  let two = match b.drawn(w.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  assert_eq(two.len(), 2)
  b.terminate()
}

///|
/// `Sparkline::area~`：面积填充是一条闭合多边形（T109 第二刀）。
///
/// 轮廓 = 折线顶点 + 底边两点（首尾相连）。手算：width=100、height=40、
/// data=[0,5,10]，内边距 pad = max(线宽/2, 端点半径) + 1 = max(0.75, 3) + 1 = 4，
/// 于是 x = 4 / 50 / 96、y = 36 / 20 / 4、底边 y = 40 - 4 = 36。
/// 轮廓顶点依次是 (4,36)、(50,20)、(96,4)、(96,36)、(4,36)。
///
/// 面积画在**折线之前**——否则那块半透明底色会盖在线上。
test "Sparkline：area~ 把折线下方填成闭合多边形，画在折线之前（T109）" {
  let b = mock()
  let spark = @widgets.Sparkline::new(
    b,
    [0.0, 5.0, 10.0],
    width=100.0,
    height=40.0,
    line_width=1.5,
    area=true,
    area_color=0x2B6CB0,
    area_alpha=64,
  )
  let w = spark.widget()
  let dl = place(b, w)
  let cmds = dl.commands()
  // 多边形 + 两条线段 + 端点圆
  assert_eq(dl.len(), 4)
  match cmds[0] {
    @moonui.FillPolygon(points, rgb, alpha) => {
      assert_eq(points.length(), 5)
      assert_true(near(points[0].0, 4.0) && near(points[0].1, 36.0))
      assert_true(near(points[1].0, 50.0) && near(points[1].1, 20.0))
      assert_true(near(points[2].0, 96.0) && near(points[2].1, 4.0))
      // 底边两点：右端点正下方、左端点正下方
      assert_true(near(points[3].0, 96.0) && near(points[3].1, 36.0))
      assert_true(near(points[4].0, 4.0) && near(points[4].1, 36.0))
      assert_eq(rgb, 0x2B6CB0)
      assert_eq(alpha, 64)
    }
    _ => fail("第一条不是面积多边形")
  }
  // 多边形之后才是折线（顺序反了就是面积盖住线）
  match cmds[1] {
    @moonui.Line(_, _, _, _, _, _) => ()
    _ => fail("第二条不是线段")
  }
  b.terminate()
}

///|
/// `area~` 关着的时候**一条多边形都不画**——这是"面积是可选的"那条约定。
///
/// 顺带钉住：单点数据画不出面积（轮廓不足三点），所以只有端点圆。
test "Sparkline：area~ 关着不画多边形，单点画不出面积（T109）" {
  let b = mock()
  let plain = @widgets.Sparkline::new(b, [0.0, 5.0], width=100.0, height=40.0)
  let pd = place(b, plain.widget())
  assert_eq(pd.len(), 2) // 一条线段 + 端点圆
  // 单点 + area：轮廓只有两个点（一个折线点 + 一个底边点）→ 画不出面积
  let one = @widgets.Sparkline::new(
    b,
    [7.0],
    width=60.0,
    height=30.0,
    area=true,
  )
  let od = place(b, one.widget())
  assert_eq(od.len(), 1) // 只有端点圆
  b.terminate()
}
