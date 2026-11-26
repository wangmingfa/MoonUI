///|
/// 绘制配方的录制式判据（§52.4）：配方说了什么，RecordCanvas 逐行记下，
/// 断言就是整张序列表——不渲染、不比位图，wasm 门就能测。

///|
test "配方：面板画一张底色圆角面" {
  let p = @canvas-common.RecordCanvas()
  @canvas-common.paint_panel(p, 0.0, 0.0, 200.0, 640.0, 0xF5F5F7, radius=0.0)
  assert_eq(p.lines(), ["fill_rect 0 0 200 640 r0 #f5f5f7"])
}

///|
test "配方：标签垂直居中，加粗走 bold 通道" {
  let p = @canvas-common.RecordCanvas()
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
  let p = @canvas-common.RecordCanvas()
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
  let p = @canvas-common.RecordCanvas()
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
    // 拇指：直径 12（T203② 与原生对齐），圆心 = clamp(50, 6, 94) = 50，
    // 左缘 = 44，cy = 0+(24-12)/2 = 6
     "fill_rect 44 6 12 12 r6 #ffffff",
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
    // 已过段 0 宽不画；圆心夹到左端 d/2 = 6，左缘 0
     "fill_rect 0 6 12 12 r6 #ffffff",
  ])
  // 自定义映射与形状（T203②：三个参数都由调用方给——换皮肤不改配方）
  p.lines().clear()
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
    knob_d=14.0,
    knob_map=Some(fn(w, t) { w * t - 2.0 }),
  )
  assert_eq(p.lines(), [
    "fill_rect 0 10 100 4 r2 #dddddd", "fill_rect 0 10 50 4 r2 #ec4141",
    // 映射给的圆心 = 48，左缘 41，cy = 5
     "fill_rect 41 5 14 14 r7 #ffffff",
  ])
}

///|
test "配方：菜单行选中态换底换字色，缩进 12" {
  let p = @canvas-common.RecordCanvas()
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
  let p = @canvas-common.RecordCanvas()
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
  let p = @canvas-common.RecordCanvas()
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
  let p = @canvas-common.RecordCanvas()
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

///|
/// 重放层：`DrawCmd` → `Painter` 的每一条命令都得有臂（`T109` 加了 `StrokeArc`）。
///
/// 为什么为一条命令单开判据：`replay` 是**唯一**一处对 `DrawCmd` 做穷尽匹配的
/// 地方，但漏一条臂并不会编译错（只有"枚举多了成员、匹配没跟上"才会），它只会
/// 让那条命令在两条后端上同时静默消失——静默正是最该被钉住的那种错。这里用
/// "命令进、录制行出"把桥本身钉住：命令名、参数顺序、角度符号都在一行里。
test "重放：StrokeArc 落到画笔的 stroke_arc（T109）" {
  let p = @canvas-common.RecordCanvas()
  let dl = @moonui.DrawList()
  // 进度环那两笔：整圈轨道 + 从十二点顺时针 90°
  dl.stroke_arc(40.0, 40.0, 36.0, 0.0, 360.0, width=8.0, rgb=0xE2E8F0)
  dl.stroke_arc(40.0, 40.0, 36.0, -90.0, 90.0, width=8.0, rgb=0x2B6CB0)
  @canvas-common.replay(p, dl)
  assert_eq(p.lines(), [
    "stroke_arc 40 40 r36 a0 s360 w8 #e2e8f0", "stroke_arc 40 40 r36 a-90 s90 w8 #2b6cb0",
  ])
}

///|
/// 重放层：`FillPolygon` 落到画笔的 `fill_polygon`（`T109` 第二刀）。
///
/// 与 `StrokeArc` 那条同一条理由：`replay` 是唯一一处对 `DrawCmd` 做穷尽匹配
/// 的地方，漏一条臂不会编译错，只会让那条命令在两条后端上**同时静默消失**。
/// 这里把桥钉住：顶点表、颜色、透明度都在一行里。
test "重放：FillPolygon 落到画笔的 fill_polygon（T109）" {
  let p = @canvas-common.RecordCanvas()
  let dl = @moonui.DrawList()
  // 面积图那笔轮廓：三点（首尾相连，最后一点连回第一点）
  dl.fill_polygon(
    [(0.0, 40.0), (50.0, 10.0), (100.0, 40.0)],
    rgb=0x2B6CB0,
    alpha=64,
  )
  @canvas-common.replay(p, dl)
  assert_eq(p.lines(), ["fill_polygon [0,40,50,10,100,40] #2b6cb0 a64"])
}

///|
/// 顶点不足三个画不出面积——那条命令**不进清单**（省掉一条"什么也没画"的
/// 命令，重放方也省得判）。
///
/// 为什么要单独钉：`fill_polygon` 在 `DrawList` 这一层就把这种调用丢了，
/// 如果放行到重放层，各后端得各自判一遍"点够不够"——三处判三遍，漏一处
/// 就在那条后端上画出一条退化多边形（一条线 / 一个点）。
test "DrawList：顶点不足三个的多边形不进清单（T109）" {
  let dl = @moonui.DrawList()
  dl.fill_polygon([], rgb=0x2B6CB0)
  dl.fill_polygon([(0.0, 0.0)], rgb=0x2B6CB0)
  dl.fill_polygon([(0.0, 0.0), (10.0, 10.0)], rgb=0x2B6CB0)
  assert_eq(dl.len(), 0)
  // 三个点就该进了
  dl.fill_polygon([(0.0, 0.0), (10.0, 10.0), (20.0, 0.0)], rgb=0x2B6CB0)
  assert_eq(dl.len(), 1)
}

///|
/// 逻辑→物理换算是 15 个 Painter impl 共用的唯一一条算式。它原先住在
/// native-common/painter.mbt（整包 native-only，wasm 门进不去），因此一直
/// 没有任何无头判据；抽到 canvas-common 之后这里能逐条钉住。
test "换算：@1x 的四舍五入边界（half-up）" {
  assert_eq(@canvas-common.px_of(1.0, 10.0), 10)
  assert_eq(@canvas-common.px_of(1.0, 10.4), 10)
  assert_eq(@canvas-common.px_of(1.0, 10.5), 11)
  assert_eq(@canvas-common.px_of(1.0, 10.6), 11)
  assert_eq(@canvas-common.px_of(1.0, 0.0), 0)
}

///|
test "换算：@2x 先乘 scale 再取整，不是取整后再乘" {
  assert_eq(@canvas-common.px_of(2.0, 10.25), 21)
  assert_eq(@canvas-common.px_of(2.0, 10.24), 20)
  assert_eq(@canvas-common.px_of(2.0, 0.25), 1)
  assert_eq(@canvas-common.px_of(2.0, 0.24), 0)
  assert_eq(@canvas-common.px_of(3.0, 7.5), 23)
}

///|
/// 负坐标这条**钉的是已裁决的约定**（`T232`，2026-11-08）：floor(v + 0.5)
/// 在 .5 处向 +∞ 偏，所以正负数不对称（3.5 → 4，-3.5 → -3）。原 painter.mbt
/// 注释写的「-3.5 → -4」描述的是 floor 本身，不是这个表达式的结果；冲突的
/// 只是那句注释。裁决结论是保留行为、订正注释，不把期望值换成「应该的值」。
test "换算：负坐标与零附近不因向零截断偏进相邻像素" {
  assert_eq(@canvas-common.px_of(1.0, -3.5), -3)
  assert_eq(@canvas-common.px_of(1.0, -3.6), -4)
  assert_eq(@canvas-common.px_of(1.0, -0.5), 0)
  assert_eq(@canvas-common.px_of(1.0, -0.6), -1)
}

///|
/// `T232` 收口后把「有意不对称」写成一条独立判据：同一组绝对值，正负两边的
/// .5 边界结果不同。若哪天有人把 `px_of` 换成对称取整
/// （round-half-away-from-zero），这条和上面那条都会红——那是**改约定**，
/// 不是修 bug，必须走完整 A/B 复验并先补可观测负 .5 绘制结果的判据
/// （见 TODO.md `T232` 落地注）。
test "换算：.5 边界正负不对称是已裁决约定（T232）" {
  assert_eq(@canvas-common.px_of(1.0, 3.5), 4)
  assert_eq(@canvas-common.px_of(1.0, -3.5), -3)
  assert_eq(@canvas-common.px_of(1.0, 0.5), 1)
  assert_eq(@canvas-common.px_of(1.0, -0.5), 0)
  assert_eq(@canvas-common.px_of(2.0, -1.75), -3)
}

///|
test "换算：非整数 scale 与大值" {
  assert_eq(@canvas-common.px_of(1.5, 100.0), 150)
  assert_eq(@canvas-common.px_of(1.5, 0.1), 0)
  assert_eq(@canvas-common.px_of(1.25, 8.0), 10)
}

///|
/// 口令掩码（`T372`）：逐字符换圆点，空串仍是空串。按字符数而不是字节数——
/// 中文口令与英文口令都只该露出"打了几个字"。
test "配方：口令掩码逐字符换圆点" {
  assert_eq(@canvas-common.mask_secret("abc"), "•••")
  assert_eq(@canvas-common.mask_secret(""), "")
  assert_eq(@canvas-common.mask_secret("口令"), "••")
}

///|
/// 文本框光标（`T374`）：按**原文**字符下标量前缀宽（假账 8px/字），线宽 1.5、
/// 与文本同一条垂直居中；`caret = -1` 时不画（缺省值，旧调用逐字不变）。
/// 颜色走 `caret_fg`（正文墨色，不是强调蓝——`T379` 真窗口反馈）。
test "配方：文本框光标按字符前缀定位" {
  let p = @canvas-common.RecordCanvas()
  @canvas-common.paint_text_input(
    p,
    "ab",
    10.0,
    10.0,
    120.0,
    28.0,
    fg=0x333333,
    caret=1,
  )
  assert_eq(p.lines(), [
    "stroke_rect 10 10 120 28 r8 w1 #dddddd", "text \"ab\" 18 14.9 s13 regular #333333",
    "line 26 14.9 26 33.1 w1.5 #333333",
  ])
  // -1：不画光标
  p.lines().clear()
  @canvas-common.paint_text_input(p, "ab", 10.0, 10.0, 120.0, 28.0, fg=0x333333)
  assert_eq(p.lines(), [
    "stroke_rect 10 10 120 28 r8 w1 #dddddd", "text \"ab\" 18 14.9 s13 regular #333333",
  ])
  // 越界夹到末尾：前缀 "ab" → 10 + 8 + 16 = 34
  p.lines().clear()
  @canvas-common.paint_text_input(
    p,
    "ab",
    10.0,
    10.0,
    120.0,
    28.0,
    fg=0x333333,
    caret=99,
  )
  assert_eq(p.lines()[2], "line 34 14.9 34 33.1 w1.5 #333333")
  // 空文本 + 占位符：占位符与正文同起点，光标压在首字左缘——聚焦/闪烁时
  // 占位符都不平移（`T379` 真窗口反馈"聚焦后被挤了一段""一直抖"）。
  p.lines().clear()
  @canvas-common.paint_text_input(
    p,
    "",
    10.0,
    10.0,
    120.0,
    28.0,
    fg=0x333333,
    placeholder="hi",
    caret=0,
  )
  assert_eq(p.lines()[1], "text \"hi\" 18 14.9 s13 regular #aaaaaa")
  assert_eq(p.lines()[2], "line 18 14.9 18 33.1 w1.5 #333333")
  // 闪烁的暗相位（caret=-1）：占位符还在原地，画面只少一根光标
  p.lines().clear()
  @canvas-common.paint_text_input(
    p,
    "",
    10.0,
    10.0,
    120.0,
    28.0,
    fg=0x333333,
    placeholder="hi",
  )
  assert_eq(p.lines()[1], "text \"hi\" 18 14.9 s13 regular #aaaaaa")
}

///|
/// 数字框光标（`T374`）：同一套前缀定位，右侧夹在步进区之前（`x + w - 20`）。
test "配方：数字框光标让开步进区" {
  let p = @canvas-common.RecordCanvas()
  @canvas-common.paint_spinbox(
    p,
    "12",
    10.0,
    10.0,
    120.0,
    28.0,
    fg=0x333333,
    caret=1,
  )
  assert_eq(p.lines()[2], "line 26 14.9 26 33.1 w1.5 #333333")
  // 长文本把光标推到步进区边缘：x + w - 20 = 110
  p.lines().clear()
  @canvas-common.paint_spinbox(
    p,
    "123456789012345",
    10.0,
    10.0,
    120.0,
    28.0,
    fg=0x333333,
    caret=15,
  )
  assert_eq(p.lines()[2], "line 110 14.9 110 33.1 w1.5 #333333")
}

///|
/// 多行框光标（`T389`）：按**可视行**落位——下标 1 在首行内，5 是末行末（跨行）。
/// 线从该行顶起、高 = 字号×1.4。
test "配方：多行框光标按可视行落位" {
  let p = @canvas-common.RecordCanvas()
  @canvas-common.paint_multiline_entry(
    p,
    "ab\ncd",
    10.0,
    10.0,
    120.0,
    48.0,
    fg=0x333333,
    caret=1,
  )
  assert_eq(p.lines()[5], "line 26 16 26 34.2 w1.5 #333333")
  // 下标 5 = 末行末（`ab\ncd` 的 d 之后）：第二行 x = 18 + 16 = 34，
  // 顶 = 16 + 18.2（`T374` 的第一刀夹在首行末尾，`T389` 起跨行）
  p.lines().clear()
  @canvas-common.paint_multiline_entry(
    p,
    "ab\ncd",
    10.0,
    10.0,
    120.0,
    48.0,
    fg=0x333333,
    caret=5,
  )
  assert_eq(p.lines()[5], "line 34 34.2 34 52.4 w1.5 #333333")
}

///|
/// 下拉框（收起态）：描边 + 当前选项 + 右侧下折线箭头。箭头中心离右边 10px。
test "配方：下拉框画当前选项与右侧箭头" {
  let p = @canvas-common.RecordCanvas()
  @canvas-common.paint_combo_box(p, "高", 10.0, 10.0, 120.0, 28.0, fg=0x333333)
  assert_eq(p.lines(), [
    "stroke_rect 10 10 120 28 r6 w1 #dddddd", "text \"高\" 18 14.9 s13 regular #333333",
    "line 117 22.5 120 25.5 w1.5 #333333", "line 120 25.5 123 22.5 w1.5 #333333",
  ])
}

///|
/// 多行文本框：按 `\n` 分行、行高 = 字号×1.4、首行离顶 6px；文本锁在框内
/// （save/clip/restore）。空文本时画占位灰字。
test "配方：多行文本框分行并锁在框内" {
  let p = @canvas-common.RecordCanvas()
  @canvas-common.paint_multiline_entry(
    p,
    "a\nbb",
    10.0,
    10.0,
    120.0,
    48.0,
    fg=0x333333,
  )
  assert_eq(p.lines(), [
    "stroke_rect 10 10 120 48 r6 w1 #dddddd", "save", "clip_rect 11 11 118 46", "text \"a\" 18 16 s13 regular #333333",
    "text \"bb\" 18 34.2 s13 regular #333333", "restore",
  ])
  // 空文本 → 占位灰字，颜色走 mute
  p.lines().clear()
  @canvas-common.paint_multiline_entry(
    p,
    "",
    0.0,
    0.0,
    100.0,
    40.0,
    fg=0x333333,
    placeholder="写点什么",
  )
  assert_eq(p.lines(), [
    "stroke_rect 0 0 100 40 r6 w1 #dddddd", "save", "clip_rect 1 1 98 38", "text \"写点什么\" 8 6 s13 regular #b8b8bd",
    "restore",
  ])
}

///|
/// 日期框：描边 + 日期文案 + 右侧日历字形（框 + 两根装订线 + 表头横线）。
/// 没设值时占位破折号走 mute 色。
test "配方：日期框画日期与日历字形" {
  let p = @canvas-common.RecordCanvas()
  @canvas-common.paint_date_picker(
    p,
    "2026-11-24",
    10.0,
    10.0,
    140.0,
    28.0,
    fg=0x333333,
  )
  assert_eq(p.lines(), [
    "stroke_rect 10 10 140 28 r6 w1 #dddddd", "text \"2026-11-24\" 18 14.9 s13 regular #333333",
    "stroke_rect 130 17 14 14 r2 w1 #333333", "line 134 15 134 19 w1 #333333", "line 140 15 140 19 w1 #333333",
    "line 130 21 144 21 w1 #333333",
  ])
  // 没设值 → 占位破折号走 mute 色；日历字形仍用前景色（控件本身没禁用）
  p.lines().clear()
  @canvas-common.paint_date_picker(
    p,
    "",
    10.0,
    10.0,
    140.0,
    28.0,
    fg=0x333333,
    placeholder="—",
  )
  assert_eq(p.lines(), [
    "stroke_rect 10 10 140 28 r6 w1 #dddddd", "text \"—\" 18 14.9 s13 regular #b8b8bd",
    "stroke_rect 130 17 14 14 r2 w1 #333333", "line 134 15 134 19 w1 #333333", "line 140 15 140 19 w1 #333333",
    "line 130 21 144 21 w1 #333333",
  ])
}

///|
/// 排版表（`T389`）：硬行、词换行与空行各占一条可视行。RecordCanvas 的度量假账
/// 是每字符 8 逻辑像素，所以 `"ab cd ef"` 宽 64，`max_w=40` 装不下 → 在空格处
/// 断。断点那个空格归上一行，保证每个下标只属于一条可视行。
test "排版表：硬行、词换行与空行各占一条（T389）" {
  let p = @canvas-common.RecordCanvas()
  // `"a\n\nb"` 中间的 `\n\n` 是空行：不量字，但占一条（`start == end`、零宽）
  let ls = @canvas-common.wrap_lines(p, "a\n\nb", 13.0, 100.0)
  assert_eq(ls.length(), 3)
  assert_eq(ls[0].start, 0)
  assert_eq(ls[0].end, 1)
  assert_eq(ls[0].width, 8.0)
  assert_eq((ls[1].start, ls[1].end, ls[1].width), (2, 2, 0.0))
  assert_eq(ls[2].start, 3)
  assert_eq(ls[2].end, 4)
  // 词换行：`"ab cd ef"` 宽 64 > 40，`"ab cd "`（6 字符 = 48）也装不下，
  // 得退回 `"ab "`（24）；下一行 `"cd ef"` 正好 40。断点那个空格归上一行，
  // 保证每个下标只属于一条可视行。
  let ls2 = @canvas-common.wrap_lines(p, "ab cd ef", 13.0, 40.0)
  assert_eq(ls2.length(), 2)
  assert_eq((ls2[0].start, ls2[0].end, ls2[0].width), (0, 3, 24.0))
  assert_eq((ls2[1].start, ls2[1].end, ls2[1].width), (3, 8, 40.0))
  // max_w <= 0 = 不折断行（超长行原样溢出，与旧配方一致）
  let ls3 = @canvas-common.wrap_lines(p, "ab cd ef", 13.0, 0.0)
  assert_eq(ls3.length(), 1)
  assert_eq(ls3[0].end, 8)
}

///|
/// 排版表：行尾下标归上一行末（`T389`）。`"ab\ncd"` 的下标 2 是首行行尾，
/// 光标要画在那一行的行尾，不能跳到第二行行首。
test "排版表：行尾下标归上一行末（T389）" {
  let p = @canvas-common.RecordCanvas()
  let ls = @canvas-common.wrap_lines(p, "ab\ncd", 13.0, 100.0)
  assert_eq(@canvas-common.vline_of(ls, 0), 0)
  assert_eq(@canvas-common.vline_of(ls, 2), 0)
  assert_eq(@canvas-common.vline_of(ls, 3), 1)
  assert_eq(@canvas-common.vline_of(ls, 5), 1)
}

///|
/// 排版表：行内 x 与下标互逆（`T389`）。点击定位与光标绘制走同一对函数，
/// 一来一回必须回到同一个下标。
test "排版表：行内 x 与下标互逆（T389）" {
  let p = @canvas-common.RecordCanvas()
  let ls = @canvas-common.wrap_lines(p, "abc\nde", 13.0, 100.0)
  let l0 = ls[0]
  let t = "abc\nde"
  assert_eq(@canvas-common.line_x(p, t, l0, 0, 13.0), 0.0)
  assert_eq(@canvas-common.line_x(p, t, l0, 3, 13.0), 24.0)
  assert_eq(@canvas-common.char_at(p, t, l0, 13.0, 0.0), 0)
  assert_eq(@canvas-common.char_at(p, t, l0, 13.0, 16.0), 2)
  assert_eq(@canvas-common.char_at(p, t, l0, 13.0, 99.0), 3)
}

///|
/// 排版表：光标所在行滚进视口（`T389`）。六行文本、行高 18.2、可视高 40，
/// 最多滚到 6×18.2 − 40 = 69.2。
test "排版表：光标滚进视口（T389）" {
  let p = @canvas-common.RecordCanvas()
  let ls = @canvas-common.wrap_lines(p, "a\nb\nc\nd\ne\nf", 13.0, 100.0)
  assert_eq(ls.length(), 6)
  assert_eq(@canvas-common.caret_scroll(ls, 0, 0.0, 18.2, 40.0), 0.0)
  // 光标落到最后一行（下标 10）：滚到底 6×18.2 − 40（浮点尾噪用容差比）
  assert_true(
    (@canvas-common.caret_scroll(ls, 10, 0.0, 18.2, 40.0) - 69.2).abs() < 0.001,
  )
  // 回到首行：滚回 0
  assert_eq(@canvas-common.caret_scroll(ls, 0, 69.2, 18.2, 40.0), 0.0)
}

///|
/// 选区反白（`T389`）：选区底画实（alpha 255，日志不带 `a` 后缀），选中段用
/// 白字重画一遍；`sel_solid=false` 仍是旧的半透明叠蓝、文字不变白。
test "配方：选区反白（T389）" {
  let p = @canvas-common.RecordCanvas()
  @canvas-common.paint_text_input(
    p,
    "abc",
    10.0,
    10.0,
    120.0,
    28.0,
    fg=0x333333,
    sel=0,
    caret=3,
  )
  let ls = p.lines()
  assert_eq(ls[1], "text \"abc\" 18 14.9 s13 regular #333333")
  assert_eq(ls[2], "fill_rect 18 14.9 24 18.2 r0 #335eea")
  assert_eq(ls[3], "text \"abc\" 18 14.9 s13 regular #ffffff")
  assert_eq(ls[4], "line 42 14.9 42 33.1 w1.5 #333333")
  // 半透明档：仍按 alpha 叠蓝，文字不变白（少一条重画）
  p.lines().clear()
  @canvas-common.paint_text_input(
    p,
    "abc",
    10.0,
    10.0,
    120.0,
    28.0,
    fg=0x333333,
    sel=0,
    caret=3,
    sel_solid=false,
  )
  assert_eq(p.lines()[2], "fill_rect 18 14.9 24 18.2 r0 #335eea a110")
  assert_eq(p.lines().length(), 4)
}

///|
/// 多行选区（`T389`）：`[1,5)` 跨两行，逐可视行画一段。第一行画 `b`（下标 1
/// 到行尾 2），第二行画整行 `cd`；每段都是"实底 + 白字重画"。
test "配方：多行选区逐可视行画（T389）" {
  let p = @canvas-common.RecordCanvas()
  @canvas-common.paint_multiline_entry(
    p,
    "ab\ncd",
    10.0,
    10.0,
    120.0,
    48.0,
    fg=0x333333,
    sel=1,
    caret=5,
  )
  let ls = p.lines()
  assert_eq(ls[5], "fill_rect 26 16 8 18.2 r0 #335eea")
  assert_eq(ls[6], "text \"b\" 26 16 s13 regular #ffffff")
  assert_eq(ls[7], "fill_rect 18 34.2 16 18.2 r0 #335eea")
  assert_eq(ls[8], "text \"cd\" 18 34.2 s13 regular #ffffff")
  // 光标落在末行末
  assert_eq(ls[9], "line 34 34.2 34 52.4 w1.5 #333333")
}
