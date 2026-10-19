///|
/// CanvasPainter 的真跑判据（mac 链 CoreGraphics）：配方的逻辑像素账，
/// 经过 scale 换算落在位图上，read_pixel 按物理坐标逐位核。与
/// canvas-common 的录制式判据互补：那边断"配方说了什么"，这边断
/// "翻成 CG 之后落在哪"。
test "Painter 真实现：scale=2 的换算落点逐位对得上" {
  let c = @native-common.canvas_create()
  // 100×60 逻辑 @2x → 200×120 物理
  @native-common.canvas_begin_frame(c, 200, 120)
  let p = @canvas-macos.CanvasPainter::new(c, 2.0)
  // 面板：逻辑 (10,10,40,30) → 物理 (20,20,80,60)，圆角 4→8
  @canvas-common.paint_panel(p, 10.0, 10.0, 40.0, 30.0, 0xFF0000, radius=4.0)
  // 中心点在面板里（物理 60,50）
  assert_eq(@native-common.canvas_read_pixel(c, 60, 50), 0xFF0000)
  // 逻辑左上角外一格（物理 18,18）没画到
  let outside = try {
    let _ = @native-common.canvas_read_pixel(c, 18, 18)
    true
  } catch {
    _ => false
  }
  assert_true(!outside)
  // 滑条：逻辑 (10,45,50,8) → 轨道 y = 45+(8-4)/2 = 47 逻辑 → 物理 94，
  // 轨道高 4→8；value=500 → 已过段 25 逻辑宽 → 50 物理
  @canvas-common.paint_slider(
    p,
    10.0,
    45.0,
    50.0,
    8.0,
    500,
    track=0xCCCCCC,
    accent=0xEC4141,
    thumb=0xFFFFFF,
  )
  // 采样点避开圆角、边缘与路径接缝（C 侧圆角路径在 radius=半宽时圆心
  // 附近有 1px 抗锯齿缝，探针实测）：灰段取拇指右外（90,98），红段取
  // 拇指左内（30,98），拇指白取右半心（60,100）
  assert_eq(@native-common.canvas_read_pixel(c, 90, 98), 0xCCCCCC)
  assert_eq(@native-common.canvas_read_pixel(c, 30, 98), 0xEC4141)
  assert_eq(@native-common.canvas_read_pixel(c, 60, 100), 0xFFFFFF)
  // 标签：16pt 的字在 2x 位图上量出来的逻辑高度应该在 14..26 之间
  // （系统行高 1.2~1.6×字号带余量，太离谱就是换算丢了/乘重了）
  let (_, th) = @canvas-macos.CanvasPainter::measure_text(
    p, "云音乐", 16.0, false,
  )
  assert_true(th > 14.0 && th < 26.0)
  @native-common.canvas_end_frame(c)
  @native-common.canvas_destroy(c)
}
