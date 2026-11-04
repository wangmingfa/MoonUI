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
/// `RichText` 不画任何底色或线条，清单里应该只有 `Text`。
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
