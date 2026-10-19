///|
/// 绘制配方的录制式判据（§52.4）：配方说了什么，RecordCanvas 逐行记下，
/// 断言就是整张序列表——不渲染、不比位图，wasm 门就能测。

///|
test "配方：面板画一张底色圆角面" {
  let p = @canvas-common.RecordCanvas::new()
  @canvas-common.paint_panel(p, 0.0, 0.0, 200.0, 640.0, 0xF5F5F7, radius=0.0)
  assert_eq(p.lines(), ["fill_rect 0 0 200 640 r0 #f5f5f7"])
}

///|
test "配方：标签垂直居中，加粗走 bold 通道" {
  let p = @canvas-common.RecordCanvas::new()
  @canvas-common.paint_label(
    p,
    "本地音乐",
    12.0,
    0.0,
    120.0,
    24.0,
    0x333333,
    size=20.0,
    bold=true,
  )
  // 高 = 20×1.4 = 28，垂直居中在 24 高的行框里 → y = 0 + (24-28)/2 = -2
  assert_eq(p.lines(), ["text \"本地音乐\" 12 -2 s20 bold #333333"])
}

///|
test "配方：图标钮三态换底色，字形居中" {
  let p = @canvas-common.RecordCanvas::new()
  let face : @canvas-common.ButtonFace = {
    normal_bg: 0xFFFFFF,
    hover_bg: 0xE8E8EB,
    pressed_bg: 0xDCDCE0,
    fg: 0xEC4141,
    radius: 6.0,
  }
  // 常态：底 + 字形。字形"▶"宽 8（单字符 ×8）、高 14×1.4=19.6，
  // 32×32 的钮里 → x = 10+(32-8)/2 = 22，y = 10+(32-19.6)/2 = 16.2
  @canvas-common.paint_icon_button(
    p,
    "▶",
    10.0,
    10.0,
    32.0,
    32.0,
    face,
    @canvas-common.Normal,
  )
  assert_eq(p.lines(), [
    "fill_rect 10 10 32 32 r6 #ffffff", "text \"▶\" 22 16.2 s14 regular #ec4141",
  ])
  // 悬停：只有底色行换，字形行不变
  p.lines().clear()
  @canvas-common.paint_icon_button(
    p,
    "▶",
    10.0,
    10.0,
    32.0,
    32.0,
    face,
    @canvas-common.Hover,
  )
  assert_eq(p.lines(), [
    "fill_rect 10 10 32 32 r6 #e8e8eb", "text \"▶\" 22 16.2 s14 regular #ec4141",
  ])
  // 按下：压色底
  p.lines().clear()
  @canvas-common.paint_icon_button(
    p,
    "▶",
    10.0,
    10.0,
    32.0,
    32.0,
    face,
    @canvas-common.Pressed,
  )
  assert_eq(p.lines(), [
    "fill_rect 10 10 32 32 r6 #dcdce0", "text \"▶\" 22 16.2 s14 regular #ec4141",
  ])
}

///|
test "配方：滑条轨道/已过段/拇指按千分位摆" {
  let p = @canvas-common.RecordCanvas::new()
  // 100 宽、24 高的条，value=500（一半）
  @canvas-common.paint_slider(
    p,
    0.0,
    0.0,
    100.0,
    24.0,
    500,
    track=0xDDDDDD,
    accent=0xEC4141,
    thumb=0xFFFFFF,
  )
  assert_eq(p.lines(), [
    // 轨道：y = 0+(24-4)/2 = 10，圆角 = 2
    "fill_rect 0 10 100 4 r2 #dddddd",
    // 已过段：50 宽
     "fill_rect 0 10 50 4 r2 #ec4141",
    // 拇指：直径 14，cx = 0+50-7 = 43，cy = 0+(24-14)/2 = 5
     "fill_rect 43 5 14 14 r7 #ffffff",
  ])
  // 钳位：千分位超界不画爆炸图形（负已过段不画，全量不超）
  p.lines().clear()
  @canvas-common.paint_slider(
    p,
    0.0,
    0.0,
    100.0,
    24.0,
    0,
    track=0xDDDDDD,
    accent=0xEC4141,
    thumb=0xFFFFFF,
  )
  assert_eq(p.lines(), [
    "fill_rect 0 10 100 4 r2 #dddddd",
    // 已过段 0 宽不画
     "fill_rect -7 5 14 14 r7 #ffffff",
  ])
}

///|
test "配方：菜单行选中态换底换字色，缩进 12" {
  let p = @canvas-common.RecordCanvas::new()
  // 选中：高亮底 + 红字（"乐"3 字符，宽 3×8=24，高 14×1.4=19.6）
  @canvas-common.paint_menu_row(
    p,
    "本地音乐",
    0.0,
    0.0,
    120.0,
    32.0,
    selected=true,
    fg=0x333333,
    selected_fg=0xEC4141,
  )
  assert_eq(p.lines(), [
    "fill_rect 0 0 120 32 r6 #efeff1", "text \"本地音乐\" 12 6.2 s14 regular #ec4141",
  ])
  // 常态：只画字
  p.lines().clear()
  @canvas-common.paint_menu_row(
    p,
    "本地音乐",
    0.0,
    0.0,
    120.0,
    32.0,
    selected=false,
    fg=0x333333,
    selected_fg=0xEC4141,
  )
  assert_eq(p.lines(), ["text \"本地音乐\" 12 6.2 s14 regular #333333"])
}

///|
test "配方：毛玻璃面板先模糊栏后内容再叠半透底" {
  let p = @canvas-common.RecordCanvas::new()
  // YPM navbar：rgba(255,255,255,0.86) → bg=0xFFFFFF, alpha≈219，模糊半径 30
  @canvas-common.paint_frosted_panel(
    p,
    0.0,
    0.0,
    1000.0,
    64.0,
    0xFFFFFF,
    219,
    blur=30.0,
  )
  // 顺序钉死：先 blur_region（"毛"），再半透 fill_rect（"玻璃"，带 a 后缀）
  assert_eq(p.lines(), [
    "blur_region 0 0 1000 64 r30", "fill_rect 0 0 1000 64 r0 #ffffff a219",
  ])
}

///|
test "配方：文本框描边 + 文案缩进 8，分隔线居中 1px" {
  let p = @canvas-common.RecordCanvas::new()
  // 文案："搜"1 字符宽 8，高 13×1.4=18.2 → y = 0+(28-18.2)/2 = 4.9
  @canvas-common.paint_text_input(
    p,
    "搜索",
    10.0,
    0.0,
    160.0,
    28.0,
    fg=0x999999,
  )
  assert_eq(p.lines(), [
    "stroke_rect 10 0 160 28 r8 w1 #dddddd", "text \"搜索\" 18 4.9 s13 regular #999999",
  ])
  p.lines().clear()
  @canvas-common.paint_separator(p, 0.0, 0.0, 200.0, 10.0, rgb=0xE0E0E0)
  assert_eq(p.lines(), ["line 0 4.5 200 4.5 w1 #e0e0e0"])
}

///|
test "配方：渐变面板垂直走 fill_linear，水平拆条带" {
  let p = @canvas-common.RecordCanvas::new()
  let stops : Array[(Double, Int32)] = [(0.0, 0x000000), (1.0, 0xFFFFFF)]
  // 垂直：单次 fill_linear（Painter 的纵向原语）
  @canvas-common.paint_gradient_panel(p, 0.0, 0.0, 200.0, 80.0, stops)
  assert_eq(p.lines(), ["fill_linear 0 0 200 80 [0:#000000,1:#ffffff]"])
  // 水平：2 条带，各自取中点色（0.25→0x40，0.75→0xBF）
  p.lines().clear()
  @canvas-common.paint_gradient_panel(
    p,
    0.0,
    0.0,
    100.0,
    80.0,
    stops,
    horizontal=true,
    bands=2,
  )
  assert_eq(p.lines(), [
    "fill_rect 0 0 50.5 80 r0 #404040", "fill_rect 50 0 50.5 80 r0 #bfbfbf",
  ])
}
