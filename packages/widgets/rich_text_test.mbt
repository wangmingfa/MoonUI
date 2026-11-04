///|
/// `RichText` 的判据（`T102` 第二十二刀）。
///
/// 与 `data_grid_test.mbt` 同一层：测的是**配方**——摆进布局之后后端收到的
/// `DrawList` 里到底是什么命令、按什么参数。所有坐标都是按 mock 度量口径
/// 手算写死的，不调被测代码里的任何计算函数。
///
/// 度量口径（`MockBackend::measure_text`）：宽 = 字符数 × 8 × 字号/12，粗体
/// 再 ×1.25；高 = 16 × 字号/12。本文件统一 font=12 → 每字符 8 宽、粗体 10、
/// 行高 16；`line_spacing` 用默认 6 → 第二行 y = 22。
///
/// 判据形状上的一条：抽命令**不按下标**（`T102` 第五刀的教训——下标会被
/// 上下游命令的增删整体挪位），全部按"这条命令自己带的字段"筛与断言。

///|
/// 这一帧的全部 `Text` 命令，按绘制顺序抽成 (文本, x, y, bold, rgb)。
/// 只适用于不含链接 span 的内容——链接会多画 `Line` 下划线，那种判据走
/// 下面的 `rich_texts_sized` / `rich_lines`。
fn rich_texts(
  dl : @moonui.DrawList,
) -> Array[(String, Double, Double, Bool, Int32)] raise {
  let out : Array[(String, Double, Double, Bool, Int32)] = []
  for cmd in dl.commands() {
    match cmd {
      @moonui.Text(text, x, y, _, bold, rgb) =>
        out.push((text, x, y, bold, rgb))
      _ => fail("RichText 的清单里出现了非 Text 命令")
    }
  }
  out
}

///|
/// 西文词在空格处断行、行首空格丢弃、行内同样式合并成一条命令。
/// "hello world"（11 字符 88 宽）塞不进 80：断在空格，行 1 是 "hello "（词 +
/// 空格合并成一条），行 2 "world" 落 y = 16 + 6 = 22、x 回到 0。
test "RichText：空格断行、行首空格丢弃、同款合并（T102）" {
  let b = mock()
  let rt = @widgets.RichText::new(
    b,
    [@widgets.RichSpan::plain("hello world")],
    width=80.0,
    height=60.0,
    font=12.0,
  )
  let w = rt.widget()
  assert_eq(w.kind(), @moonui.Custom)
  assert_eq(w.intrinsic_size(), @moonui.LogicalSize(80.0, 60.0))
  assert_eq(rt.line_count(), 2)
  assert_eq(rt.content_height(), 38.0) // 16 + 6 + 16
  let dl = place(b, w)
  let ts = rich_texts(dl)
  assert_eq(ts.length(), 2)
  let (t0, x0, y0, b0, c0) = ts[0]
  assert_eq(t0, "hello ")
  assert_true(near(x0, 0.0))
  assert_true(near(y0, 0.0))
  assert_false(b0)
  assert_eq(c0, 0x1A202C) // 默认色
  let (t1, x1, y1, _, _) = ts[1]
  assert_eq(t1, "world")
  assert_true(near(x1, 0.0))
  assert_true(near(y1, 22.0))
}

///|
/// 样式各管各的：颜色、加粗、**后续 piece 的 x 被粗体宽度推走**（粗体 10/字
/// 符 vs 常规 8——bold 只改宽度不改 x，所以牙口必须放在"它后面那一格"上，
/// 与 `DataGrid` 的"改一格看下一列表头"同一招）。None 色继承默认色。
test "RichText：颜色与加粗，x 被粗体宽度推走（T102）" {
  let b = mock()
  let rt = @widgets.RichText::new(
    b,
    [
      @widgets.RichSpan::plain("ab"),
      @widgets.RichSpan::styled("cd", color=0xFF0000, bold=true),
      @widgets.RichSpan::plain("ef"),
    ],
    width=200.0,
    height=60.0,
    font=12.0,
    color=0x111111,
  )
  assert_eq(rt.line_count(), 1)
  let dl = place(b, rt.widget())
  let ts = rich_texts(dl)
  assert_eq(ts.length(), 3) // 三种样式，互不合并
  let (t0, x0, _, b0, c0) = ts[0]
  assert_eq(t0, "ab")
  assert_true(near(x0, 0.0))
  assert_false(b0)
  assert_eq(c0, 0x111111)
  let (t1, x1, _, b1, c1) = ts[1]
  assert_eq(t1, "cd")
  assert_true(near(x1, 16.0)) // 2 × 8
  assert_true(b1)
  assert_eq(c1, 0xFF0000)
  let (t2, x2, _, _, _) = ts[2]
  assert_eq(t2, "ef")
  assert_true(near(x2, 36.0)) // 16 + 2 × 10（粗体）
}

///|
/// CJK 逐字断行（中文没有空格，按词断等于整段不断）：四字塞 24 宽（3 字），
/// 行 1 三字、行 2 一字；字之间同样式合并成一条命令。
test "RichText：CJK 逐字断行（T102）" {
  let b = mock()
  let rt = @widgets.RichText::new(
    b,
    [@widgets.RichSpan::plain("歌曲天下")],
    width=24.0,
    height=60.0,
    font=12.0,
  )
  assert_eq(rt.line_count(), 2)
  let dl = place(b, rt.widget())
  let ts = rich_texts(dl)
  assert_eq(ts.length(), 2)
  let (t0, x0, y0, _, _) = ts[0]
  assert_eq(t0, "歌曲天")
  assert_true(near(x0, 0.0))
  assert_true(near(y0, 0.0))
  let (t1, x1, y1, _, _) = ts[1]
  assert_eq(t1, "下")
  assert_true(near(x1, 0.0))
  assert_true(near(y1, 22.0))
}

///|
/// 西文长词超过整行宽：按字符硬断（宁可劈开也不丢字）。8 字母词塞 40 宽
/// （5 字符）→ "abcde" / "fgh"，一个字符都不能少。
test "RichText：长词硬断不丢字（T102）" {
  let b = mock()
  let rt = @widgets.RichText::new(
    b,
    [@widgets.RichSpan::plain("abcdefgh")],
    width=40.0,
    height=60.0,
    font=12.0,
  )
  assert_eq(rt.line_count(), 2)
  let dl = place(b, rt.widget())
  let ts = rich_texts(dl)
  assert_eq(ts.length(), 2)
  assert_eq(ts[0].0, "abcde")
  assert_eq(ts[1].0, "fgh")
}

///|
/// 行 1 的 "a b" 是**一条**命令（词 + 空格 + 词同款合并）；行 2 "c" 前的
/// 空格被丢掉（换行重试时空格落在行首）。
test "RichText：行内合并成一条命令 + 行 2 空格不落行首（T102）" {
  let b = mock()
  let rt = @widgets.RichText::new(
    b,
    [@widgets.RichSpan::plain("a b c")],
    width=24.0,
    height=60.0,
    font=12.0,
  )
  assert_eq(rt.line_count(), 2)
  let dl = place(b, rt.widget())
  let ts = rich_texts(dl)
  assert_eq(ts.length(), 2)
  assert_eq(ts[0].0, "a b")
  assert_true(near(ts[0].2, 0.0))
  assert_eq(ts[1].0, "c")
  assert_true(near(ts[1].2, 22.0))
}

///|
/// 窗口化：控件高只装得下一行（height 20 < 22），第二行整行不发命令——
/// "看不见的就不画"，与 `DataGrid` / `TreeView` 同一条。
test "RichText：超出控件高的行不发命令（T102）" {
  let b = mock()
  let rt = @widgets.RichText::new(
    b,
    [@widgets.RichSpan::plain("hello world")],
    width=80.0,
    height=20.0,
    font=12.0,
  )
  let dl = place(b, rt.widget())
  let ts = rich_texts(dl)
  assert_eq(ts.length(), 1)
  assert_eq(ts[0].0, "hello ")
}

///|
/// 换内容：set_spans 之后行数与清单跟着变（布局缓存一并失效——宽度没变
/// 也要重排）。
test "RichText：set_spans 重排（T102）" {
  let b = mock()
  let rt = @widgets.RichText::new(
    b,
    [@widgets.RichSpan::plain("hello world")],
    width=80.0,
    height=60.0,
    font=12.0,
  )
  assert_eq(rt.line_count(), 2)
  rt.set_spans([@widgets.RichSpan::plain("hi")])
  assert_eq(rt.line_count(), 1)
  assert_eq(rt.span_count(), 1)
  let dl = place(b, rt.widget())
  let ts = rich_texts(dl)
  assert_eq(ts.length(), 1)
  assert_eq(ts[0].0, "hi")
}

///|
/// 空内容：一行空行、零条命令、总高 0。
test "RichText：空内容零命令（T102）" {
  let b = mock()
  let rt = @widgets.RichText::new(b, [], width=80.0, height=60.0, font=12.0)
  assert_eq(rt.line_count(), 1)
  assert_eq(rt.content_height(), 0.0)
  let dl = place(b, rt.widget())
  assert_eq(rich_texts(dl).length(), 0)
}

///|
/// 这一帧的全部 `Text` 命令，带字号（第二十六刀起 span 可带字号）。链接的
/// 清单里还有下划线 `Line`，老的 `rich_texts` 对非 Text 命令是炸——新判据
/// 一律用这两只宽松抽取器，只筛自己要的那一种。
fn rich_texts_sized(
  dl : @moonui.DrawList,
) -> Array[(String, Double, Double, Double, Bool, Int32)] {
  let out : Array[(String, Double, Double, Double, Bool, Int32)] = []
  for cmd in dl.commands() {
    match cmd {
      @moonui.Text(text, x, y, size, bold, rgb) =>
        out.push((text, x, y, size, bold, rgb))
      _ => ()
    }
  }
  out
}

///|
/// 这一帧的全部 `Line` 命令，抽成 (x0, y0, x1, y1, rgb)。
fn rich_lines(
  dl : @moonui.DrawList,
) -> Array[(Double, Double, Double, Double, Int32)] {
  let out : Array[(Double, Double, Double, Double, Int32)] = []
  for cmd in dl.commands() {
    match cmd {
      @moonui.Line(x0, y0, x1, y1, _, rgb) => out.push((x0, y0, x1, y1, rgb))
      _ => ()
    }
  }
  out
}

///|
/// span 级字号（第二十六刀之一）：24 号的 "Hi" 与 12 号的 " ok" 同行混排，
/// 行高取本行最大（32 = 16 × 24/12），小字的 y 沉到 32 − 16 = 16——**盒底
/// 对齐**，两个 piece 的底边都是 32。各 piece 的 `size` 跟自己的字号走。
/// 这条也是基线的负控制：paint 若无视 piece 高（y 直接用行顶），" ok" 的
/// y 会是 0，判据红。
test "RichText：span 级字号混排，盒底对齐（T102）" {
  let b = mock()
  let rt = @widgets.RichText::new(
    b,
    [
      @widgets.RichSpan::styled("Hi", color=0xFF0000, size=Some(24.0)),
      @widgets.RichSpan::plain(" ok"),
    ],
    width=200.0,
    height=60.0,
    font=12.0,
  )
  assert_eq(rt.line_count(), 1)
  assert_eq(rt.content_height(), 32.0) // 只有一行，行高 = 32
  let dl = place(b, rt.widget())
  let ts = rich_texts_sized(dl)
  assert_eq(ts.length(), 2)
  let (t0, x0, y0, s0, b0, c0) = ts[0]
  assert_eq(t0, "Hi")
  assert_true(near(x0, 0.0))
  assert_true(near(y0, 0.0)) // 高 32 = 行高，盒底对齐退化成行顶
  assert_true(near(s0, 24.0))
  assert_false(b0)
  assert_eq(c0, 0xFF0000)
  let (t1, x1, y1, s1, _, c1) = ts[1]
  assert_eq(t1, " ok") // 空格在行中保留，与 "ok" 同款合并
  assert_true(near(x1, 32.0)) // "Hi" = 2 字 × 8 × 24/12 = 32 宽
  assert_true(near(y1, 16.0)) // 32 − 16：小字沉到行底
  assert_true(near(s1, 12.0))
  assert_eq(c1, 0x1A202C)
}

///|
/// 跨 span 词合并（第二十六刀之二）：相邻两段同款 span 拼出的同一个西文词
/// 先并成一枚再装行——① 宽够时一条命令；② 24 宽（3 字符）装不下 4 字母词
/// 时按字符硬断成 "abc"/"d"，**不在 span 边界断成 "ab"/"cd"**（旧账正是
/// 那样，这条判据对旧实现红）。
test "RichText：跨 span 同款词合并，不在词内断（T102）" {
  let b = mock()
  let rt = @widgets.RichText::new(
    b,
    [@widgets.RichSpan::plain("ab"), @widgets.RichSpan::plain("cd")],
    width=200.0,
    height=60.0,
    font=12.0,
  )
  assert_eq(rt.line_count(), 1)
  let dl = place(b, rt.widget())
  let ts = rich_texts(dl)
  assert_eq(ts.length(), 1) // 旧实现这里是 2 条
  assert_eq(ts[0].0, "abcd")
  assert_true(near(ts[0].1, 0.0))
  // 宽不够：整词硬断，span 边界不算断点
  let b2 = mock()
  let rt2 = @widgets.RichText::new(
    b2,
    [@widgets.RichSpan::plain("ab"), @widgets.RichSpan::plain("cd")],
    width=24.0,
    height=60.0,
    font=12.0,
  )
  assert_eq(rt2.line_count(), 2)
  let ts2 = rich_texts(place(b2, rt2.widget()))
  assert_eq(ts2.length(), 2)
  assert_eq(ts2[0].0, "abc")
  assert_eq(ts2[1].0, "d")
}

///|
/// 滚动偏移（第二十六刀之三）：账面值不夹、**读的时候夹**。38 高的内容装
/// 20 高的视口，上限 18；超了夹到 18、负了夹到 0。绘制按生效偏移平移：
/// offset 18 时行 1 整行滚出视口顶（不发命令），行 2 落 y = 22 − 18 = 4。
test "RichText：滚动偏移读写与绘制平移（T102）" {
  let b = mock()
  let rt = @widgets.RichText::new(
    b,
    [@widgets.RichSpan::plain("hello world")],
    width=80.0,
    height=20.0,
    font=12.0,
  )
  rt.set_offset(100.0)
  assert_eq(rt.offset(), 18.0) // 内容 38 − 视口 20
  let ts = rich_texts(place(b, rt.widget()))
  assert_eq(ts.length(), 1)
  assert_eq(ts[0].0, "world")
  assert_true(near(ts[0].2, 4.0)) // 22 − 18
  // 下限：负值夹到 0（新控件——widget 进过一次容器就不能再进）
  let b2 = mock()
  let rt2 = @widgets.RichText::new(
    b2,
    [@widgets.RichSpan::plain("hello world")],
    width=80.0,
    height=20.0,
    font=12.0,
  )
  rt2.set_offset(-5.0)
  assert_eq(rt2.offset(), 0.0)
  let ts2 = rich_texts(place(b2, rt2.widget()))
  assert_eq(ts2.length(), 1) // 行 2 的顶 22 ≥ 视口 20，整行不发
  assert_eq(ts2[0].0, "hello ")
}

///|
/// `Scroll` 事件的默认接线（`DataGrid` 点表头排序同一条理由）：不调任何
/// 方法，只往事件队列塞 `Scroll`，偏移自己动。delta.y=24 一步到上限 18，
/// 再滚 −100 回 0。
test "RichText：Scroll 事件增减偏移（T102）" {
  let b = mock()
  let rt = @widgets.RichText::new(
    b,
    [@widgets.RichSpan::plain("a b c")],
    width=24.0,
    height=20.0,
    font=12.0,
  )
  let app = @moonui.App::new(b)
  let win = app.create_window("滚", @moonui.LogicalSize(200.0, 200.0))
  win.set_content(rt.widget())
  win.show()
  let _ = app.step()
  b.push_event(
    @moonui.Scroll(rt.widget().target(), @moonui.LogicalPoint(0.0, 24.0)),
  )
  let _ = app.step()
  assert_eq(rt.offset(), 18.0) // 38 − 20
  b.push_event(
    @moonui.Scroll(rt.widget().target(), @moonui.LogicalPoint(0.0, -100.0)),
  )
  let _ = app.step()
  assert_eq(rt.offset(), 0.0)
  b.terminate()
}

///|
/// 链接（第二十六刀之四）：链接 span 画下划线（`Line` 命令，宽 1、同色，
/// y = piece 底 16）；`link_at` 只认链接 piece——普通文字上回 None，行间
/// 空隙回 None；y 先加生效偏移换内容坐标（set_offset 6 之后 y=2 也能命中
/// ——命中与绘制共用同一笔偏移账）。
test "RichText：链接下划线与 link_at 命中（T102）" {
  let b = mock()
  let rt = @widgets.RichText::new(
    b,
    [
      @widgets.RichSpan::plain("see "),
      @widgets.RichSpan::link("moonbit"),
      @widgets.RichSpan::plain(" now"),
    ],
    width=200.0,
    height=40.0,
    font=12.0,
  )
  let dl = place(b, rt.widget())
  let ts = rich_texts_sized(dl)
  assert_eq(ts.length(), 3)
  let (_, lx, ly, _, _, lc) = ts[1]
  assert_eq(ts[1].0, "moonbit")
  assert_true(near(lx, 32.0)) // "see " = 4 字 × 8 = 32
  assert_true(near(ly, 0.0))
  assert_eq(lc, 0x3182CE) // 默认链接蓝
  let ls = rich_lines(dl)
  assert_eq(ls.length(), 1)
  let (x0, y0, x1, y1, rgb) = ls[0]
  assert_true(near(x0, 32.0))
  assert_true(near(y0, 16.0)) // piece 底 = 0 + 16
  assert_true(near(x1, 88.0)) // 32 + 7 字 × 8
  assert_true(near(y1, 16.0))
  assert_eq(rgb, 0x3182CE)
  // 命中：链接 piece 横向 32..88；普通文字与行间空隙都不是链接
  assert_true(rt.link_at(40.0, 8.0) is Some((1, "moonbit")))
  assert_true(rt.link_at(0.0, 8.0) is None)
  assert_true(rt.link_at(40.0, 30.0) is None) // 30 ≥ 16 + 6，落空隙外
  // 偏移共用：往下滚 6，屏幕 y=2 就是内容 y=8
  rt.set_offset(6.0)
  assert_true(rt.link_at(40.0, 2.0) is Some((1, "moonbit")))
}

///|
/// 链接点击的默认接线：不调 `link_at`，只往事件队列塞 `MouseDown`，
/// `on_link(span 序号, 文本)` 收到 (1, "moonbit")；`set_on_link(None)` 后
/// 点了不炸、也不再回调。
test "RichText：点链接回调 on_link（T102）" {
  let b = mock()
  let rt = @widgets.RichText::new(
    b,
    [
      @widgets.RichSpan::plain("see "),
      @widgets.RichSpan::link("moonbit"),
      @widgets.RichSpan::plain(" now"),
    ],
    width=200.0,
    height=40.0,
    font=12.0,
  )
  let hits : Array[(Int32, String)] = []
  rt.set_on_link(Some(fn(si, text) { hits.push((si, text)) }))
  let app = @moonui.App::new(b)
  let win = app.create_window("链接", @moonui.LogicalSize(200.0, 200.0))
  win.set_content(rt.widget())
  win.show()
  let _ = app.step()
  b.push_event(
    @moonui.MouseDown(
      rt.widget().target(),
      @moonui.Left,
      @moonui.LogicalPoint(40.0, 8.0),
      @moonui.Mods::none(),
    ),
  )
  let _ = app.step()
  assert_eq(hits.length(), 1)
  assert_eq(hits[0].0, 1)
  assert_eq(hits[0].1, "moonbit")
  // 撤掉回调：点了也不炸、也不再记
  rt.set_on_link(None)
  b.push_event(
    @moonui.MouseDown(
      rt.widget().target(),
      @moonui.Left,
      @moonui.LogicalPoint(40.0, 8.0),
      @moonui.Mods::none(),
    ),
  )
  let _ = app.step()
  assert_eq(hits.length(), 1)
  b.terminate()
}
