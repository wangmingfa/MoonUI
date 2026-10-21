///|
/// `DataGrid` 的判据（`T102` 第一刀）。
///
/// 和 `widgets_test.mbt` 同一层：测的是**配方**——摆进布局之后后端收到的那份
/// `DrawList` 里到底是什么命令、按什么参数。所有坐标都是手算写死的，不调
/// 被测代码里的任何计算函数（`grid_first_row` 之类包外也看不见）——判据与
/// 实现共用一条公式，只能证明"实现没变"，证明不了"画对了"。
///
/// 度量口径（`MockBackend::measure_text`）：宽 = 字符数 × 8 × 字号/12，
/// 粗体再 × 1.25；高 = 16 × 字号/12。所以 12px 正文每字符 8 宽、16 高，
/// 12px 粗体每字符 10 宽。

///|
/// 把这一帧里**正文**（表头以下）的文案按顺序抽出来。
///
/// 为什么不直接用命令下标取正文：表头那几条命令里混着排序箭头，箭头出现与否
/// 会让下标整体挪一位——下标一旦挪了，"正文第一条是什么"就取到了表头的文案，
/// 判据变成测别的东西。这里按"y 在正文区"筛，箭头增删都不影响。
///
/// 正文第一行的文案 y = 28（表头高）+ 4（(24 - 16) / 2）= 32，所以 y ≥ 32 即正文。
fn body_texts(dl : @moonui.DrawList) -> Array[String] {
  let out : Array[String] = []
  let cmds = dl.commands()
  let mut i = 0
  while i < cmds.length() {
    match cmds[i] {
      @moonui.Text(text, _, y, _, _, _) => if y >= 32.0 { out.push(text) }
      _ => ()
    }
    i = i + 1
  }
  out
}

///|
/// 正文第一条文案的位置（x, y）；一条都没有就给 (-1.0, -1.0)。
///
/// 位置单独取，判据就能既验"画的是哪句话"又验"它画在哪儿"，两头都不必挂在
/// 命令下标上。
fn first_body_pos(dl : @moonui.DrawList) -> (Double, Double) {
  let cmds = dl.commands()
  let mut i = 0
  while i < cmds.length() {
    match cmds[i] {
      @moonui.Text(_, x, y, _, _, _) => if y >= 32.0 { return (x, y) }
      _ => ()
    }
    i = i + 1
  }
  (-1.0, -1.0)
}

///|
test "DataGrid：表头两列、数值右对齐、隔行底色、竖线在最后（T102）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("name", 100.0),
    @widgets.GridColumn::new("n", 60.0, right=true),
  ]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["a1", "1"], ["b2", "2"]],
    width=160.0,
    height=100.0,
  )
  let wg = grid.widget()
  assert_eq(wg.kind(), @moonui.Custom)
  assert_eq(wg.intrinsic_size(), @moonui.LogicalSize(160.0, 100.0))
  assert_eq(grid.row_count(), 2)
  assert_eq(grid.column_count(), 2)
  assert_eq(grid.row_height(), 24.0)
  assert_eq(grid.header_height(), 28.0)
  assert_eq(grid.offset(), 0.0)
  assert_eq(grid.selected(), -1)
  let dl = place(b, wg)
  // 1 底 + 1 表头底 + 2 表头文案 + 1 表头下边线
  // + 行 0（2 文案 + 1 分隔线）+ 行 1（1 斑马底 + 2 文案 + 1 分隔线）
  // + 1 竖向分列线
  assert_eq(dl.len(), 13)
  let cmds = dl.commands()
  match cmds[0] {
    @moonui.FillRect(x, y, fw, fh, radius, rgb, alpha) => {
      assert_true(near(x, 0.0) && near(y, 0.0))
      assert_true(near(fw, 160.0) && near(fh, 100.0))
      assert_true(near(radius, 0.0))
      assert_eq(rgb, 0xFFFFFF)
      assert_eq(alpha, 255)
    }
    _ => fail("第一条不是整块底色")
  }
  match cmds[1] {
    @moonui.FillRect(_, _, fw, fh, _, rgb, _) => {
      assert_true(near(fw, 160.0) && near(fh, 28.0))
      assert_eq(rgb, 0xF1F5F9)
    }
    _ => fail("第二条不是表头底色")
  }
  // 表头文案：左列贴左内边距 8，右列贴右（100 + 60 - 8 - 10 = 142，粗体 1 字符 = 10），
  // 竖直居中 (28 - 16) / 2 = 6
  match cmds[2] {
    @moonui.Text(text, x, y, size, bold, rgb) => {
      assert_eq(text, "name")
      assert_true(near(x, 8.0) && near(y, 6.0))
      assert_true(near(size, 12.0))
      assert_true(bold)
      assert_eq(rgb, 0x4A5568)
    }
    _ => fail("第三条不是表头文案")
  }
  match cmds[3] {
    @moonui.Text(text, x, y, _, bold, _) => {
      assert_eq(text, "n")
      assert_true(near(x, 142.0) && near(y, 6.0))
      assert_true(bold)
    }
    _ => fail("第四条不是右对齐的表头文案")
  }
  // 表头下边线正好在表头高上
  match cmds[4] {
    @moonui.Line(x0, y0, x1, y1, width, rgb) => {
      assert_true(near(x0, 0.0) && near(y0, 28.0))
      assert_true(near(x1, 160.0) && near(y1, 28.0))
      assert_true(near(width, 1.0))
      assert_eq(rgb, 0xE2E8F0)
    }
    _ => fail("第五条不是表头下边线")
  }
  // 行 0：y = 28，文案竖直居中 28 + (24 - 16) / 2 = 32；"1" 右对齐
  // 100 + 60 - 8 - 8 = 144
  match cmds[5] {
    @moonui.Text(text, x, y, _, bold, rgb) => {
      assert_eq(text, "a1")
      assert_true(near(x, 8.0) && near(y, 32.0))
      assert_false(bold)
      assert_eq(rgb, 0x1A202C)
    }
    _ => fail("第六条不是第一行第一格")
  }
  match cmds[6] {
    @moonui.Text(text, x, y, _, _, _) => {
      assert_eq(text, "1")
      assert_true(near(x, 144.0) && near(y, 32.0))
    }
    _ => fail("第七条不是右对齐的数字")
  }
  assert_true(
    match cmds[7] {
      @moonui.Line(_, y0, _, y1, _, _) => near(y0, 52.0) && near(y1, 52.0)
      _ => false
    },
  )
  // 行 1 是斑马行：底色只画一层，y = 28 + 24 = 52
  match cmds[8] {
    @moonui.FillRect(x, y, fw, fh, _, rgb, _) => {
      assert_true(near(x, 0.0) && near(y, 52.0))
      assert_true(near(fw, 160.0) && near(fh, 24.0))
      assert_eq(rgb, 0xF7FAFC)
    }
    _ => fail("第九条不是斑马底")
  }
  match cmds[9] {
    @moonui.Text(text, _, y, _, _, _) => {
      assert_eq(text, "b2")
      assert_true(near(y, 56.0))
    }
    _ => fail("第十条不是第二行第一格")
  }
  // 竖向分列线在 x = 100，从表头下沿贯穿到底（画在最后，不许被斑马底盖掉）
  match cmds[12] {
    @moonui.Line(x0, y0, x1, y1, width, rgb) => {
      assert_true(near(x0, 100.0) && near(x1, 100.0))
      assert_true(near(y0, 28.0) && near(y1, 100.0))
      assert_true(near(width, 1.0))
      assert_eq(rgb, 0xE2E8F0)
    }
    _ => fail("最后一条不是竖向分列线")
  }
  b.terminate()
}

///|
test "DataGrid：偏移推进虚拟窗口，滚到底不空屏（T102）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("id", 40.0),
    @widgets.GridColumn::new("v", 60.0, right=true),
  ]
  let rows : Array[Array[String]] = []
  for i in 0..<10 {
    rows.push(["r\{i}", "\{i}"])
  }
  let grid = @widgets.DataGrid::new(b, cols, rows~, width=100.0, height=100.0)
  let wg = grid.widget()
  let _ = place(b, wg)
  // 表头 28、正文 72、行高 24 → 一次只看得到 3 行；偏移 48 = 正好滚过两行
  grid.set_offset(48.0)
  assert_eq(grid.offset(), 48.0)
  let dl = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  let cmds = dl.commands()
  // 1 底 + 1 表头底 + 2 表头文案 + 1 表头下边线 = 5 条，正文从第 6 条起。
  // 正文三行（行 2/3/4）：行 3 是斑马行多一条底色，行 4 的分隔线落在底边
  // 之外不画，最后加一条竖向分列线 → 5 + 4 + 3 + 2 + 1 = 15
  assert_eq(dl.len(), 15)
  // 第一条正文文案是第 3 行（r2），紧贴表头下沿 y = 28、文案 y = 32——
  // 窗口外的两行一条命令都不发（虚拟化）
  match cmds[5] {
    @moonui.Text(text, x, y, _, _, _) => {
      assert_eq(text, "r2")
      assert_true(near(x, 8.0) && near(y, 32.0))
    }
    _ => fail("滚动之后第六条不是窗口第一行")
  }
  // 行号换算：表头里没有行，正文第一像素就是 r2；跨过一行就是 r3
  assert_eq(grid.row_at(0.0), None)
  assert_eq(grid.row_at(27.0), None)
  assert_eq(grid.row_at(28.0), Some(2))
  assert_eq(grid.row_at(51.0), Some(2))
  assert_eq(grid.row_at(52.0), Some(3))
  // 负偏移夹到 0；越尾夹到"最后一行贴底" = 240 - 72 = 168
  grid.set_offset(-5.0)
  assert_eq(grid.offset(), 0.0)
  grid.set_offset(1000.0)
  assert_eq(grid.offset(), 168.0)
  assert_eq(grid.row_at(28.0), Some(7))
  let tail = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  assert_eq(tail.len(), 16)
  // 最后一行 y = 28 + 9 × 24 - 168 = 76，文案 y = 80：底边不空。
  // 行 9 是斑马行（多一条底色），所以它的文案落在第 14 条
  match tail.commands()[13] {
    @moonui.Text(text, _, y, _, _, _) => {
      assert_eq(text, "r9")
      assert_true(near(y, 80.0))
    }
    _ => fail("滚到底之后倒数第二行文案不是 r9")
  }
  // scroll_to_row 按行高换算（第 3 行 → 72），顺带证明它走的是同一条夹法
  grid.scroll_to_row(3)
  assert_eq(grid.offset(), 72.0)
  b.terminate()
}

///|
test "DataGrid：放不下才省略，省略的那一格才夹（T102）" {
  let b = mock()
  let cols = [@widgets.GridColumn::new("c", 40.0)]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["abcdefgh"], ["ok"]],
    width=40.0,
    height=100.0,
  )
  let wg = grid.widget()
  let dl = place(b, wg)
  let cmds = dl.commands()
  // 单列没有竖线：1 底 + 1 表头底 + 1 表头文案 + 1 边线
  // + 行 0（Save / ClipRect / Text / Restore + 分隔线）
  // + 行 1（斑马底 + Text + 分隔线）
  assert_eq(dl.len(), 12)
  // 表头 "c" 放得下（40 - 16 = 24 ≥ 10）：不夹
  match cmds[2] {
    @moonui.Text(text, x, _, _, bold, _) => {
      assert_eq(text, "c")
      assert_true(near(x, 8.0))
      assert_true(bold)
    }
    _ => fail("第三条不是表头文案")
  }
  // "abcdefgh" 每字符 8 宽，可用宽 40 - 16 = 24 → 只放得下 "ab…"（3 × 8 = 24）
  match cmds[4] {
    @moonui.Save => ()
    _ => fail("溢出格没有先压栈")
  }
  // 夹的是**文字区**（左右各让出内边距 8）：文字本来只画在 8..32 之间，
  // 夹到格子边只是多留了 8px 空白——`text_fit.mbt` 把这条口子收窄之后，
  // 树的行文案与表格的单元格共用同一份裁剪语义
  match cmds[5] {
    @moonui.ClipRect(x, y, cw, ch) => {
      assert_true(near(x, 8.0) && near(y, 28.0))
      assert_true(near(cw, 24.0) && near(ch, 24.0))
    }
    _ => fail("溢出格没有夹在列内")
  }
  match cmds[6] {
    @moonui.Text(text, x, y, _, _, _) => {
      assert_eq(text, "ab…")
      assert_true(near(x, 8.0) && near(y, 32.0))
    }
    _ => fail("溢出格没有写省略后的文案")
  }
  match cmds[7] {
    @moonui.Restore => ()
    _ => fail("溢出格没有出栈")
  }
  // 放得下的格子不夹：省掉 Save / ClipRect / Restore 三条（行 1 是斑马行，
  // 所以先有一条斑马底）
  match cmds[9] {
    @moonui.FillRect(_, y, _, fh, _, rgb, _) => {
      assert_true(near(y, 52.0) && near(fh, 24.0))
      assert_eq(rgb, 0xF7FAFC)
    }
    _ => fail("第二行没有斑马底")
  }
  match cmds[10] {
    @moonui.Text(text, x, y, _, _, _) => {
      assert_eq(text, "ok")
      assert_true(near(x, 8.0) && near(y, 56.0))
    }
    _ => fail("第二行没有直接写文案")
  }
  b.terminate()
}

///|
test "DataGrid：空表文案居中，选中盖住斑马，越界改格报错（T102）" {
  let b = mock()
  let cols = [@widgets.GridColumn::new("name", 100.0)]
  let empty = @widgets.DataGrid::new(
    b,
    cols,
    width=160.0,
    height=100.0,
    empty_text="暂无数据",
  )
  let ew = empty.widget()
  let dl = place(b, ew)
  // 1 底 + 1 表头底 + 1 表头文案 + 1 边线 + 1 空表文案（单列没有竖线）
  assert_eq(dl.len(), 5)
  // "暂无数据" 4 字符 × 8 = 32 → x = (160 - 32) / 2 = 64；正文 72 高、16 字高
  // → y = 28 + (72 - 16) / 2 = 56
  match dl.commands()[4] {
    @moonui.Text(text, x, y, _, bold, _) => {
      assert_eq(text, "暂无数据")
      assert_true(near(x, 64.0) && near(y, 56.0))
      assert_false(bold)
    }
    _ => fail("空表没有居中文案")
  }
  // 选中：行 1 本来是斑马行，选中之后只剩一层底（选中的那层）
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["a"], ["b"], ["c"]],
    width=160.0,
    height=100.0,
  )
  let wg = grid.widget()
  let _ = place(b, wg)
  grid.select_row(1)
  assert_eq(grid.selected(), 1)
  let sel = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  assert_eq(sel.len(), 10)
  let cmds = sel.commands()
  match cmds[6] {
    @moonui.FillRect(x, y, fw, fh, _, rgb, _) => {
      assert_true(near(x, 0.0) && near(y, 52.0))
      assert_true(near(fw, 160.0) && near(fh, 24.0))
      assert_eq(rgb, 0xEBF4FF)
    }
    _ => fail("选中行没有底色")
  }
  // 正文里只有这一条底色（斑马被选中盖掉，不是两层叠着画）
  let mut fills = 0
  for i = 4; i < cmds.length(); i = i + 1 {
    match cmds[i] {
      @moonui.FillRect(_, _, _, _, _, _, _) => fills = fills + 1
      _ => ()
    }
  }
  assert_eq(fills, 1)
  // 越界选中 = 清掉选中
  grid.select_row(9)
  assert_eq(grid.selected(), -1)
  // 越界改格：报出来，不吞
  let err : String? = try {
    grid.set_cell(9, 0, "x")
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(err, Some("操作失败：表格行号越界：9"))
  assert_eq(grid.cell(0, 0), Some("a"))
  assert_eq(grid.cell(0, 5), None)
  b.terminate()
}

///|
/// `DataGrid` 自适应列宽的判据（`T102` 第三刀）。
///
/// 度量口径同文件头（`MockBackend::measure_text`）：12px 正文每字符 8 宽、
/// 12px 粗体（表头）每字符 10 宽。
///
/// 三条各钉一件事：①自然宽怎么算、声明宽当下限；②总宽装不下时按比例压缩；
/// ③数据变了要重量（缓存失效）。期望值全是手算写死的——不调被测代码里的任何
/// 计算函数（`grid_natural_widths` 之类包外也看不见），判据与实现共用一条公式
/// 只能证明"实现没变"，证明不了"画对了"。

///|
test "DataGrid：自适应列宽按自然宽排布，声明宽当下限（T102）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("name", 40.0),
    @widgets.GridColumn::new("n", 30.0),
  ]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["abcd", "1"]],
    width=200.0,
    height=100.0,
    auto_width=true,
  )
  let wg = grid.widget()
  let dl = place(b, wg)
  // 1 底 + 1 表头底 + 2 表头文案 + 1 表头下边线 + 2 单元格文案 + 1 行分隔线
  // + 1 竖向分列线
  assert_eq(dl.len(), 9)
  let cmds = dl.commands()
  // 列 0：表头 "name" 粗体 4 字 = 40，格 "abcd" 4 字 = 32 → 取 40，加内边距
  // 2×8 = 16 → 自然宽 56；声明的 40 是下限，比不过自然宽
  // 列 1：表头 "n" 粗体 1 字 = 10，格 "1" 1 字 = 8 → 取 10，加 16 = 26，
  // 但声明的 30 是下限 → 取 30
  // 于是两列 56 / 30：表头 "n" 落在 56 + 8 = 64，竖线落在 56
  match cmds[2] {
    @moonui.Text(text, x, y, size, bold, rgb) => {
      assert_eq(text, "name")
      assert_true(near(x, 8.0) && near(y, 6.0))
      assert_true(near(size, 12.0))
      assert_true(bold)
      assert_eq(rgb, 0x4A5568)
    }
    _ => fail("第三条不是第一列表头文案")
  }
  match cmds[3] {
    @moonui.Text(text, x, y, _, bold, _) => {
      assert_eq(text, "n")
      assert_true(near(x, 64.0) && near(y, 6.0))
      assert_true(bold)
    }
    _ => fail("第四条不是第二列表头文案")
  }
  // 行 0 的两格文案：列 0 贴左内边距 8，列 1 在 56 + 8 = 64
  match cmds[5] {
    @moonui.Text(text, x, y, _, bold, rgb) => {
      assert_eq(text, "abcd")
      assert_true(near(x, 8.0) && near(y, 32.0))
      assert_false(bold)
      assert_eq(rgb, 0x1A202C)
    }
    _ => fail("第六条不是第一行第一格")
  }
  match cmds[6] {
    @moonui.Text(text, x, y, _, _, _) => {
      assert_eq(text, "1")
      assert_true(near(x, 64.0) && near(y, 32.0))
    }
    _ => fail("第七条不是第一行第二格")
  }
  // 竖向分列线落在第一列的右边界 56
  assert_true(
    match cmds[8] {
      @moonui.Line(x0, y0, x1, y1, _, _) =>
        near(x0, 56.0) && near(y0, 28.0) && near(x1, 56.0) && near(y1, 100.0)
      _ => false
    },
  )
  b.terminate()
}

///|
test "DataGrid：总宽装不下时按比例压缩（T102）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("a", 20.0),
    @widgets.GridColumn::new("b", 20.0),
  ]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["x", "y"]],
    width=30.0,
    height=100.0,
    pad=2.0,
    auto_width=true,
  )
  let wg = grid.widget()
  let dl = place(b, wg)
  assert_eq(dl.len(), 9)
  let cmds = dl.commands()
  // 自然宽：表头 "a" 粗体 1 字 = 10、格 "x" 1 字 = 8 → 取 10，加 2×2 = 14；
  // 声明的 20 是下限 → 20。两列都是 20，合计 40 > 可用 30 → 按比例压到
  // 20 × (30 / 40) = 15。于是表头 "b" 落在 15 + 2 = 17，竖线落在 15。
  match cmds[2] {
    @moonui.Text(text, x, y, _, bold, _) => {
      assert_eq(text, "a")
      assert_true(near(x, 2.0) && near(y, 6.0))
      assert_true(bold)
    }
    _ => fail("第三条不是第一列表头文案")
  }
  match cmds[3] {
    @moonui.Text(text, x, y, _, bold, _) => {
      assert_eq(text, "b")
      assert_true(near(x, 17.0) && near(y, 6.0))
      assert_true(bold)
    }
    _ => fail("第四条不是第二列表头文案")
  }
  match cmds[5] {
    @moonui.Text(text, x, y, _, _, _) => {
      assert_eq(text, "x")
      assert_true(near(x, 2.0) && near(y, 32.0))
    }
    _ => fail("第六条不是第一行第一格")
  }
  match cmds[6] {
    @moonui.Text(text, x, y, _, _, _) => {
      assert_eq(text, "y")
      assert_true(near(x, 17.0) && near(y, 32.0))
    }
    _ => fail("第七条不是第一行第二格")
  }
  // 竖线落在压缩后的第一列右边界 15
  assert_true(
    match cmds[8] {
      @moonui.Line(x0, _, x1, _, _, _) => near(x0, 15.0) && near(x1, 15.0)
      _ => false
    },
  )
  b.terminate()
}

///|
test "DataGrid：数据变了要重量，列宽跟着变（T102）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("a", 20.0),
    @widgets.GridColumn::new("b", 20.0),
  ]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["x", "y"]],
    width=200.0,
    height=100.0,
    auto_width=true,
  )
  let wg = grid.widget()
  let _ = place(b, wg)
  let h = match wg.handle() {
    Some(h) => h
    None => abort("控件没有原生句柄")
  }
  // 初始：表头 "a" 粗体 = 10、格 "x" = 8 → 取 10，加 16 = 26；声明 20 是下限
  // → 26。两列 26 / 26，第二列表头落在 26 + 8 = 34
  let second_header_x = fn(dl : @moonui.DrawList) -> Double {
    match dl.commands()[3] {
      @moonui.Text(_, x, _, _, _, _) => x
      _ => -1.0
    }
  }
  let first = match b.drawn(h) {
    Some(dl) => dl
    None => abort("自定义绘制面一次都没画过")
  }
  assert_true(near(second_header_x(first), 34.0))
  // 改一格：第一列的 "x" 换成 10 个字符（10 × 8 = 80）→ 自然宽 80 + 16 = 96，
  // 第二列被推到 96 + 8 = 104。自然宽是量全表得来的，数据变了必须重量——
  // 缓存不失效的话这里会停在 34
  grid.set_cell(0, 0, "xxxxxxxxxx")
  let second = match b.drawn(h) {
    Some(dl) => dl
    None => abort("自定义绘制面一次都没画过")
  }
  assert_true(near(second_header_x(second), 104.0))
  // 整份换数据：第一列缩回 "y" → 自然宽回到 26，第二列回到 34
  grid.set_rows([["y", "z"]])
  let third = match b.drawn(h) {
    Some(dl) => dl
    None => abort("自定义绘制面一次都没画过")
  }
  assert_true(near(second_header_x(third), 34.0))
  b.terminate()
}

///|
/// `DataGrid` 横向滚动与列命中的判据（`T102` 第四刀）。
///
/// 度量口径同文件头（`MockBackend::measure_text`）：12px 正文每字符 8 宽、
/// 12px 粗体（表头）每字符 10 宽。
///
/// 这一刀钉三件事：①横向滚动把列一起左移，滚出视野的列**整列不发命令**；
/// ②`column_at` 把 x 换算成列号，滚过去之后换算跟着走；③`scroll_to_column`
/// 把列滚进视野（以及自适应模式下横向偏移恒为 0）。
/// 期望值全是手算写死的——不调被测代码里的任何计算函数。

///|
test "DataGrid：横向滚动，滚出视野的列整列不画（T102）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("c0", 60.0),
    @widgets.GridColumn::new("c1", 60.0),
    @widgets.GridColumn::new("c2", 60.0),
  ]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["a", "b", "c"]],
    width=100.0,
    height=100.0,
  )
  let wg = grid.widget()
  let dl = place(b, wg)
  // 1 底 + 1 表头底 + 2 表头文案（c2 完全在右侧外，不画）+ 1 表头下边线
  // + 2 单元格文案 + 1 行分隔线 + 1 分列线（第二根在 120，界外也不画）
  assert_eq(dl.len(), 9)
  let cmds = dl.commands()
  match cmds[2] {
    @moonui.Text(text, x, _, _, _, _) => {
      assert_eq(text, "c0")
      assert_true(near(x, 8.0))
    }
    _ => fail("第三条不是第一列表头文案")
  }
  match cmds[3] {
    @moonui.Text(text, x, _, _, _, _) => {
      assert_eq(text, "c1")
      assert_true(near(x, 68.0))
    }
    _ => fail("第四条不是第二列表头文案")
  }
  // 第一根分列线在 60（第二列的左边界）
  assert_true(
    match cmds[8] {
      @moonui.Line(x0, _, x1, _, _, _) => near(x0, 60.0) && near(x1, 60.0)
      _ => false
    },
  )
  // 横着滚 40：列一起左移 40，第三列进入视野
  grid.set_h_offset(40.0)
  assert_eq(grid.h_offset(), 40.0)
  let dl2 = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  // 1 底 + 1 表头底 + 3 表头 + 1 边线 + 3 单元格 + 1 行分隔线 + 2 分列线
  assert_eq(dl2.len(), 12)
  let cmds2 = dl2.commands()
  match cmds2[2] {
    @moonui.Text(text, x, _, _, _, _) => {
      assert_eq(text, "c0")
      // 负 x 是被控件左缘裁掉的那一段：真后端会裁，mock 不裁所以看得见
      assert_true(near(x, -32.0))
    }
    _ => fail("滚过去之后第三条不是第一列表头文案")
  }
  match cmds2[4] {
    @moonui.Text(text, x, _, _, _, _) => {
      assert_eq(text, "c2")
      assert_true(near(x, 88.0))
    }
    _ => fail("滚过去之后第五条不是第三列表头文案")
  }
  // 滚到头（总列宽 180 - 控件宽 100 = 80）：第一列整列滚出去了
  grid.set_h_offset(80.0)
  assert_eq(grid.h_offset(), 80.0)
  let dl3 = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  // 1 底 + 1 表头底 + 2 表头 + 1 边线 + 2 单元格 + 1 行分隔线 + 1 分列线
  assert_eq(dl3.len(), 9)
  let cmds3 = dl3.commands()
  // 第一列表头文案整条不见了（位置让给了第二列）
  match cmds3[2] {
    @moonui.Text(text, _, _, _, _, _) => assert_eq(text, "c1")
    _ => fail("滚到头之后第三条不是第二列表头文案")
  }
  // 越界夹取：往右滚过头就是"最后一列贴右"，往左滚过头归零
  grid.set_h_offset(999.0)
  assert_eq(grid.h_offset(), 80.0)
  grid.set_h_offset(-10.0)
  assert_eq(grid.h_offset(), 0.0)
  b.terminate()
}

///|
test "DataGrid：column_at 把 x 换算成列号，滚过去之后跟着换（T102）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("c0", 60.0),
    @widgets.GridColumn::new("c1", 60.0),
    @widgets.GridColumn::new("c2", 60.0),
  ]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["a", "b", "c"]],
    width=100.0,
    height=100.0,
  )
  let wg = grid.widget()
  let _ = place(b, wg)
  // 没滚：x 直接落列
  assert_eq(grid.column_at(0.0), Some(0))
  assert_eq(grid.column_at(59.0), Some(0))
  assert_eq(grid.column_at(60.0), Some(1))
  assert_eq(grid.column_at(99.0), Some(1))
  // 控件外：负 x 与 x >= 控件宽都给 None
  assert_eq(grid.column_at(-1.0), None)
  assert_eq(grid.column_at(100.0), None)
  // 滚 40 之后：屏幕 x 要加上横向偏移才是内容坐标
  grid.set_h_offset(40.0)
  assert_eq(grid.column_at(0.0), Some(0))
  assert_eq(grid.column_at(19.0), Some(0))
  assert_eq(grid.column_at(20.0), Some(1))
  assert_eq(grid.column_at(79.0), Some(1))
  assert_eq(grid.column_at(80.0), Some(2))
  b.terminate()
}

///|
test "DataGrid：scroll_to_column 把列滚进视野，自适应模式横向偏移恒为 0（T102）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("c0", 60.0),
    @widgets.GridColumn::new("c1", 60.0),
    @widgets.GridColumn::new("c2", 60.0),
  ]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["a", "b", "c"]],
    width=100.0,
    height=100.0,
  )
  let wg = grid.widget()
  let _ = place(b, wg)
  // 列2 在内容区间 [120, 180)：右边超出控件（80 + 100 = 180）→ 滚到 80 让它贴右
  grid.scroll_to_column(2)
  assert_eq(grid.h_offset(), 80.0)
  // 列0 在 [0, 60)：左边超出 → 滚回 0
  grid.scroll_to_column(0)
  assert_eq(grid.h_offset(), 0.0)
  // 列1 在 [60, 120)：右边超出 20 → 滚 20（贴着右缘，完整可见）
  grid.scroll_to_column(1)
  assert_eq(grid.h_offset(), 20.0)
  // 越界按 scroll_to_row 的规则夹住
  grid.scroll_to_column(-1)
  assert_eq(grid.h_offset(), 0.0)
  grid.scroll_to_column(99)
  assert_eq(grid.h_offset(), 80.0)
  // 自适应模式：列被压进可用宽，横向没有余量，偏移恒为 0
  let auto = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["a", "b", "c"]],
    width=100.0,
    height=100.0,
    auto_width=true,
  )
  let _ = place(b, auto.widget())
  auto.set_h_offset(50.0)
  assert_eq(auto.h_offset(), 0.0)
  b.terminate()
}

///|
/// `DataGrid` 排序的判据（`T102` 第五刀）。
///
/// 度量口径同文件头（`MockBackend::measure_text`）：12px 正文每字符 8 宽、
/// 12px 粗体（表头）每字符 10 宽。
///
/// 这一刀钉四件事：①按列排序后**显示顺序**变了、但**数据行号不变**（`cell` 读
/// 到的还是同一条数据）；②数字列按数值排（不是字典序）；③同键的行保持原有
/// 先后（排序稳定）；④表头画出方向箭头。
/// 期望值全部手算写死——不调被测代码里的任何计算函数。

///|
test "DataGrid：按列排序，显示顺序变、数据行号不变（T102）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("name", 60.0),
    @widgets.GridColumn::new("n", 60.0),
  ]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["b", "2"], ["a", "1"], ["c", "3"]],
    width=120.0,
    height=100.0,
  )
  let wg = grid.widget()
  let _ = place(b, wg)
  assert_eq(grid.sort_column(), -1)
  assert_true(grid.sort_ascending())
  // 按第一列（name）升序排：b/a/c → a/b/c
  grid.sort_by_column(0)
  assert_eq(grid.sort_column(), 0)
  assert_true(grid.sort_ascending())
  // 显示出来的第一行是 "a"（原来在中间）
  let dl = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  // 正文按行取：第一行是 a / 1
  let texts = body_texts(dl)
  assert_eq(texts.length(), 6)
  assert_eq(texts[0], "a")
  assert_eq(texts[1], "1")
  // 第一列第一行的位置：左内边距 8，竖直 (28 + 4) = 32
  let (fx, fy) = first_body_pos(dl)
  assert_true(near(fx, 8.0) && near(fy, 32.0))
  // **数据行号不变**：`cell(1, 0)` 仍是原来那一行的 "b"——
  // 排序动的是显示顺序，不是数据
  assert_eq(grid.cell(0, 0), Some("b"))
  assert_eq(grid.cell(1, 0), Some("a"))
  assert_eq(grid.cell(2, 0), Some("c"))
  // 再点同一列：翻成降序，c/b/a
  grid.sort_by_column(0)
  assert_false(grid.sort_ascending())
  let dl2 = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  assert_eq(body_texts(dl2)[0], "c")
  // 换一列：回到升序
  grid.sort_by_column(1)
  assert_eq(grid.sort_column(), 1)
  assert_true(grid.sort_ascending())
  // 取消排序：回到原序（b 在第一行）
  grid.clear_sort()
  assert_eq(grid.sort_column(), -1)
  let dl3 = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  assert_eq(body_texts(dl3)[0], "b")
  // 越界排序列号：报出来，不吞
  let err : String? = try {
    grid.sort_by_column(9)
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(err, Some("操作失败：表格排序列号越界：9"))
  b.terminate()
}

///|
test "DataGrid：数字列按数值排，字典序会把 10 排在 9 前面（T102）" {
  let b = mock()
  // 同一批数据，第二次用 numeric 声明
  let text_cols = [
    @widgets.GridColumn::new("v", 60.0, right=true),
    @widgets.GridColumn::new("v", 60.0, right=true, numeric=true),
  ]
  let rows = [["10"], ["9"], ["100"]]
  let text_grid = @widgets.DataGrid::new(
    b,
    [text_cols[0]],
    rows~,
    width=60.0,
    height=100.0,
  )
  let num_grid = @widgets.DataGrid::new(
    b,
    [text_cols[1]],
    rows~,
    width=60.0,
    height=100.0,
  )
  let _ = place(b, text_grid.widget())
  let _ = place(b, num_grid.widget())
  // 字典序："10" < "100" < "9"（"1" 开头的都比 "9" 小）
  text_grid.sort_by_column(0)
  let tdl = match b.drawn(text_grid.widget().handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  let ttexts = body_texts(tdl)
  assert_eq(ttexts.length(), 3)
  assert_eq(ttexts[0], "10")
  assert_eq(ttexts[1], "100")
  assert_eq(ttexts[2], "9")
  // 数值序：9 < 10 < 100
  num_grid.sort_by_column(0)
  let ndl = match b.drawn(num_grid.widget().handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  let ntexts = body_texts(ndl)
  assert_eq(ntexts.length(), 3)
  assert_eq(ntexts[0], "9")
  assert_eq(ntexts[1], "10")
  assert_eq(ntexts[2], "100")
  b.terminate()
}

///|
test "DataGrid：同键的行保持原有先后（T102）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("k", 60.0),
    @widgets.GridColumn::new("v", 60.0),
  ]
  // 三行的排序键一样，但**第二列各带一个可区分的值**：只看第一列的话，
  // 三行的文案完全相同，顺序被打乱也看不出来——那样的判据是空的。
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["same", "r1"], ["same", "r2"], ["same", "r3"]],
    width=120.0,
    height=100.0,
  )
  let wg = grid.widget()
  let _ = place(b, wg)
  grid.sort_by_column(0)
  // 键全相同：排序不能打乱它们的先后（`Array::sort_by` 本身不稳定，
  // 所以比较函数里必须带原行号做 tiebreak）
  let dl = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  // 第二列（x = 60 + 8 = 68）的**正文**文案序列（y ≥ 32，表头那行 y = 6 不算）
  // 必须还是 r1、r2、r3
  let cmds = dl.commands()
  let seq : Array[String] = []
  let mut i = 0
  while i < cmds.length() {
    match cmds[i] {
      @moonui.Text(text, x, y, _, _, _) =>
        if near(x, 68.0) && y >= 32.0 {
          seq.push(text)
        }
      _ => ()
    }
    i = i + 1
  }
  assert_eq(seq.length(), 3)
  assert_eq(seq[0], "r1")
  assert_eq(seq[1], "r2")
  assert_eq(seq[2], "r3")
  b.terminate()
}

///|
test "DataGrid：表头画出排序方向箭头（T102）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("a", 60.0),
    @widgets.GridColumn::new("b", 60.0),
  ]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["x", "y"]],
    width=120.0,
    height=100.0,
  )
  let wg = grid.widget()
  let dl = place(b, wg)
  // 没排序时没有箭头：1 底 + 1 表头底 + 2 表头文案 + 1 边线 + 2 单元格 + 1 分隔线
  // + 1 竖线 = 9
  assert_eq(dl.len(), 9)
  // 排第 0 列：表头多一条箭头命令
  grid.sort_by_column(0)
  let dl2 = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  // 1 底 + 1 表头底 + 1 表头文案 + 1 箭头 + 1 表头文案 + 1 边线 + 2 单元格
  // + 1 分隔线 + 1 竖线 = 10
  assert_eq(dl2.len(), 10)
  let cmds = dl2.commands()
  // 箭头紧跟在被排的列表头文案之后
  match cmds[3] {
    @moonui.Text(text, x, y, size, bold, rgb) => {
      assert_eq(text, "▲")
      // 箭头宽 = 1 字符 × 8 = 8（非粗体量），贴列右内侧：60 - 8 - 8 = 44
      assert_true(near(x, 44.0))
      assert_true(near(y, 6.0))
      assert_true(near(size, 12.0))
      assert_false(bold)
      assert_eq(rgb, 0x4A5568)
    }
    _ => fail("第四条不是排序箭头")
  }
  // 翻成降序：箭头换成 ▼
  grid.sort_by_column(0)
  let dl3 = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  match dl3.commands()[3] {
    @moonui.Text(text, _, _, _, _, _) => assert_eq(text, "▼")
    _ => fail("降序之后箭头不是 ▼")
  }
  b.terminate()
}

///|
/// `DataGrid` 排序之后**行号口径**的判据（`T102` 第六刀）。
///
/// 排序把"第几行"劈成了两个意思：**显示位置**（屏幕上第几行）与**数据行号**
/// （`rows` 里的第几条）。公开 API 一律用**数据行号**——`cell` / `set_cell` /
/// `select_row` / `selected` 都是这个口径。第五刀之前两者恒等（没有排序），
/// 第五刀把它们拆开了却没同步另外两头，于是排序之后"选中"与"命中"会指着
/// 另一条数据。这三条判据钉的就是这个不变量。
///
/// 数据用 ["b", "a", "c"]：按第一列升序排完显示顺序是 a、b、c，于是
/// **显示位置 0 = 数据行号 1**、显示位置 1 = 数据行号 0——两者分家，
/// 判据才有区分力（用 ["a", "b", "c"] 的话排序前后都一样，判据是空的）。

///|
test "DataGrid：排序后选中仍指着同一条数据，不是显示位置（T102）" {
  let b = mock()
  let cols = [@widgets.GridColumn::new("name", 60.0)]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["b"], ["a"], ["c"]],
    width=60.0,
    height=100.0,
  )
  let wg = grid.widget()
  let _ = place(b, wg)
  // 先选中数据行号 0（内容 "b"）
  grid.select_row(0)
  assert_eq(grid.selected(), 0)
  assert_eq(grid.cell(0, 0), Some("b"))
  // 按第一列升序排：显示顺序变成 a、b、c，"b" 挪到了显示位置 1
  grid.sort_by_column(0)
  let texts = body_texts(
    match b.drawn(wg.handle().unwrap()) {
      Some(dl) => dl
      None => abort("没画过")
    },
  )
  assert_eq(texts[0], "a")
  assert_eq(texts[1], "b")
  // **选中的还是数据行号 0**（那条 "b"），不是显示位置 0
  assert_eq(grid.selected(), 0)
  assert_eq(grid.cell(0, 0), Some("b"))
  // 高亮画在**显示位置 1**（"b" 那一行，y = 28 + 24 = 52），
  // 而不是显示位置 0 —— 比错了就高亮到 "a" 上去了
  let dl = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  let cmds = dl.commands()
  // 找那条选中底色（0xEBF4FF）：它必须落在 y = 52 那一行
  let mut sel_y = -1.0
  let mut i = 0
  while i < cmds.length() {
    match cmds[i] {
      @moonui.FillRect(_, y, _, _, _, rgb, _) =>
        if rgb == 0xEBF4FF {
          sel_y = y
        }
      _ => ()
    }
    i = i + 1
  }
  assert_true(near(sel_y, 52.0))
  b.terminate()
}

///|
test "DataGrid：排序后 row_at 返回数据行号，不是显示位置（T102）" {
  let b = mock()
  let cols = [@widgets.GridColumn::new("name", 60.0)]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["b"], ["a"], ["c"]],
    width=60.0,
    height=100.0,
  )
  let wg = grid.widget()
  let _ = place(b, wg)
  grid.sort_by_column(0)
  // 正文第一行（y = 28 起）显示的是 "a"，它是**数据行号 1**
  // （排序后显示位置 0 = 数据行号 1）
  assert_eq(grid.row_at(28.0), Some(1))
  // 第二行显示 "b"，那是数据行号 0
  assert_eq(grid.row_at(52.0), Some(0))
  // 第三行显示 "c"，数据行号 2
  assert_eq(grid.row_at(76.0), Some(2))
  // 拿 row_at 的结果去读格子，读到的必须是那一行的内容
  assert_eq(grid.cell(grid.row_at(28.0).unwrap(), 0), Some("a"))
  assert_eq(grid.cell(grid.row_at(52.0).unwrap(), 0), Some("b"))
  b.terminate()
}

///|
test "DataGrid：排序后 scroll_to_row 滚到那条数据现在所在的位置（T102）" {
  let b = mock()
  let cols = [@widgets.GridColumn::new("name", 60.0)]
  // 四行数据、正文高 72px（100 - 28 表头）：可显 3 行，**有滚动余量**。
  // 三行数据的话正文刚好填满（3 × 24 = 72），偏移上限是 0，滚不动——
  // 那种数据下这条判据是空的（怎么滚都是 0）。
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["b"], ["a"], ["c"], ["d"]],
    width=60.0,
    height=100.0,
  )
  let wg = grid.widget()
  let _ = place(b, wg)
  grid.sort_by_column(0)
  // 排序后显示顺序是 a、b、c、d：数据行号 0（"b"）在显示位置 1、
  // 数据行号 1（"a"）在显示位置 0
  let texts = body_texts(
    match b.drawn(wg.handle().unwrap()) {
      Some(dl) => dl
      None => abort("没画过")
    },
  )
  assert_eq(texts[0], "a")
  assert_eq(texts[1], "b")
  assert_eq(texts[2], "c")
  // 滚到数据行号 0（"b"）：它在显示位置 1，偏移 = 1 × 24 = 24。
  // 滚过去之后正文顶边那条必须是 "b"（不是 "a"——那是"滚到显示位置 0"的做法）
  grid.scroll_to_row(0)
  assert_eq(grid.offset(), 24.0)
  let t2 = body_texts(
    match b.drawn(wg.handle().unwrap()) {
      Some(dl) => dl
      None => abort("没画过")
    },
  )
  assert_eq(t2[0], "b")
  // 滚到数据行号 3（"d"）：它在显示位置 3，偏移 = 3 × 24 = 72，
  // 但上限是"最后一行贴底" = 4 × 24 - 72 = 24 → 夹到 24。
  // 夹住是对的：再往下滚就没有内容了（这一格验的是"夹法仍然生效"，
  // 数据行号 → 显示位置的映射由上面那条 24 验）。
  grid.scroll_to_row(3)
  assert_eq(grid.offset(), 24.0)
  b.terminate()
}

///|
/// `T110`：表头点击的**默认接线**。
///
/// 这条判据钉的是"点表头就排序"这条**默认行为**：不调 `sort_by_column`，
/// 只往事件队列里塞一条 `MouseDown`（坐标落在表头那一列上），表自己就该排。
///
/// 判据为什么这么设计（每一条都对着一个"接线错了就一定红"的地方）：
/// - **数据有区分度**：三行是 `b` / `a` / `c`，排完序第一行必须是 `a`。
///   用 `["a", "b", "c"]` 这种数据的话，排序前后第一行都是 `a`，判据是空的
///   （`T102` 第五刀踩过这个坑）。
/// - **坐标带偏移**：表摆在窗口里不是贴着左上角的（前面垫一个 10px 的行），
///   所以事件坐标 = 控件局部坐标 + 控件 origin。这一条钉住"接线减了
///   `frame().origin`"——不减的话点表头会算到别的列上去。
/// - **正文点击不排序**：点在正文区（表头以下）不该排序，排序是表头的事。
/// - **表头外不排序**：点在控件右侧的空白处（没有列）也不该排序。
test "DataGrid：点表头就按那一列排序，正文与空白处不排（T110）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("name", 60.0),
    @widgets.GridColumn::new("n", 60.0),
  ]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["b", "2"], ["a", "1"], ["c", "3"]],
    width=120.0,
    height=100.0,
  )
  let wg = grid.widget()
  // 摆进窗口：前面垫一行 10px，表因此不在窗口左上角（origin 非零）
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 表格接线",
    @moonui.LogicalSize(200.0, 200.0),
  )
  let pad = @moonui.Widget::label(b, "垫一行")
  win.set_content(@moonui.Widget::column(b, 0.0, [pad, wg]))
  win.show()
  let _ = app.step()
  let origin = wg.frame().origin
  // 摆出来了才谈得上"点在表头上"：控件没被摆出来时 frame 是空的
  assert_true(origin.y > 0.0)
  // 第一列（name，60 宽）的表头中心：局部 x = 30，局部 y = 14（表头高 28 的一半）
  let head_x = origin.x + 30.0
  let head_y = origin.y + 14.0
  // ① 点第一列表头 → 按 name 升序排
  b.push_event(
    @moonui.MouseDown(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(head_x, head_y),
    ),
  )
  let _ = app.step()
  assert_eq(grid.sort_column(), 0)
  assert_true(grid.sort_ascending())
  // 显示顺序真的变了：第一行是 "a"（原来在中间）
  let texts = body_texts(
    match b.drawn(wg.handle().unwrap()) {
      Some(dl) => dl
      None => abort("没画过")
    },
  )
  assert_eq(texts[0], "a")
  assert_eq(texts[1], "1")
  // ② 再点同一列表头 → 翻成降序（第一行回到 "c"）
  b.push_event(
    @moonui.MouseDown(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(head_x, head_y),
    ),
  )
  let _ = app.step()
  assert_eq(grid.sort_column(), 0)
  assert_false(grid.sort_ascending())
  let texts2 = body_texts(
    match b.drawn(wg.handle().unwrap()) {
      Some(dl) => dl
      None => abort("没画过")
    },
  )
  assert_eq(texts2[0], "c")
  // ③ 点第二列表头 → 换列，回到升序
  let head_x2 = origin.x + 60.0 + 30.0
  b.push_event(
    @moonui.MouseDown(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(head_x2, head_y),
    ),
  )
  let _ = app.step()
  assert_eq(grid.sort_column(), 1)
  assert_true(grid.sort_ascending())
  // ④ 点正文区（表头以下）→ 不排序（排序是表头的事）
  grid.clear_sort()
  b.push_event(
    @moonui.MouseDown(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(head_x, origin.y + 40.0),
    ),
  )
  let _ = app.step()
  assert_eq(grid.sort_column(), -1)
  // ⑤ 点控件右侧的空白（120 宽的表，点在 x = 150）→ 没有列，不排序
  b.push_event(
    @moonui.MouseDown(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 150.0, head_y),
    ),
  )
  let _ = app.step()
  assert_eq(grid.sort_column(), -1)
  b.terminate()
}

///|
/// `T102` 第八刀：滚轮的**默认接线**。
///
/// 判据为什么这么设计（每条对着一个"接线错了就一定红"的地方）：
/// - **数据留余量**：五行 × 24 = 120，正文高 100 − 28 = 72 → 纵向上限 48。
///   正文刚好填满的话上限是 0，"怎么滚都是 0"，判据是空的（第六刀踩过）。
/// - **断言具体内容**：光断言"offset 变了"不够——正文首行的文案从 "a" 换到
///   "b"、再换到 "c"，增量单位错（比如误乘行高）会在这里红。
/// - **两笔账分开**：横向滚只动 `h_offset`，纵向 `offset` 必须纹丝不动。
/// - **边界夹住**：滚到底停在 48、滚到顶停在 0；横向停在 60 / 0。
test "DataGrid：滚轮滚动走自己的偏移，纵向与横向各夹各的（T102 第八刀）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("name", 60.0),
    @widgets.GridColumn::new("n", 60.0),
    @widgets.GridColumn::new("tag", 60.0),
  ]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[
      ["a", "1", "A"],
      ["b", "2", "B"],
      ["c", "3", "C"],
      ["d", "4", "D"],
      ["e", "5", "E"],
    ],
    width=120.0,
    height=100.0,
  )
  let wg = grid.widget()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 表格滚轮",
    @moonui.LogicalSize(200.0, 200.0),
  )
  win.set_content(@moonui.Widget::column(b, 0.0, [wg]))
  win.show()
  let _ = app.step()
  fn texts_now() -> Array[String] raise @moonui.UiError {
    let dl = match b.drawn(wg.handle().unwrap()) {
      Some(dl) => dl
      None => abort("没画过")
    }
    body_texts(dl)
  }
  fn first_pos_now() -> (Double, Double) raise @moonui.UiError {
    let dl = match b.drawn(wg.handle().unwrap()) {
      Some(dl) => dl
      None => abort("没画过")
    }
    first_body_pos(dl)
  }
  // 滚轮增量是**逻辑像素**：24 正好一整行。正 = 往下读（adapter.h 鼠标段）。
  // ① 向下滚 24 → 偏移 24，正文首行从 "a" 换到 "b"
  b.push_event(@moonui.Scroll(wg.target(), @moonui.LogicalPoint(0.0, 24.0)))
  let _ = app.step()
  assert_eq(grid.offset(), 24.0)
  let t1 = texts_now()
  assert_eq(t1[0], "b")
  assert_eq(t1[1], "2")
  // ② 再滚 24 → 48（正好是上限 120 − 72），首行 "c"、末行贴底 "e"
  b.push_event(@moonui.Scroll(wg.target(), @moonui.LogicalPoint(0.0, 24.0)))
  let _ = app.step()
  assert_eq(grid.offset(), 48.0)
  let t2 = texts_now()
  assert_eq(t2[0], "c")
  // 三列 180 宽、控件 120：横向 0 时第三列整列在视野外，正文只剩前两列，
  // 所以 offset 48 下的正文是 c / 3 / d / 4 / e / 5
  assert_eq(t2[4], "e")
  // ③ 已经到底再滚 24 → 夹在 48，首行还是 "c"（"最后一行贴底"）
  b.push_event(@moonui.Scroll(wg.target(), @moonui.LogicalPoint(0.0, 24.0)))
  let _ = app.step()
  assert_eq(grid.offset(), 48.0)
  assert_eq(texts_now()[0], "c")
  // ④ 反向大幅滚 → 夹在顶 0，首行回到 "a"
  b.push_event(@moonui.Scroll(wg.target(), @moonui.LogicalPoint(0.0, -100.0)))
  let _ = app.step()
  assert_eq(grid.offset(), 0.0)
  assert_eq(texts_now()[0], "a")
  // ⑤ 横向滚 24 → 只动 h_offset，offset 必须还是 0；首列整体左移，
  //    第一列第一行的文字 x 从 8 落到 -16
  b.push_event(@moonui.Scroll(wg.target(), @moonui.LogicalPoint(24.0, 0.0)))
  let _ = app.step()
  assert_eq(grid.h_offset(), 24.0)
  assert_eq(grid.offset(), 0.0)
  let (hx, _) = first_pos_now()
  assert_true(near(hx, -16.0))
  assert_eq(texts_now()[0], "a")
  // ⑥ 横向再滚 60 → 夹在上限 60（三列 180 − 控件 120）；首列整列滚出视野，
  //    正文第一条变成第二列的 "1"——位置与内容两头都变了，这才是"真滚了"
  b.push_event(@moonui.Scroll(wg.target(), @moonui.LogicalPoint(60.0, 0.0)))
  let _ = app.step()
  assert_eq(grid.h_offset(), 60.0)
  let t3 = texts_now()
  assert_eq(t3[0], "1")
  let (hx2, _) = first_pos_now()
  assert_true(near(hx2, 8.0))
  // ⑦ 横向反向大幅滚 → 夹在 0；纵向偏移自始至终没被横向滚带走
  b.push_event(@moonui.Scroll(wg.target(), @moonui.LogicalPoint(-100.0, 0.0)))
  let _ = app.step()
  assert_eq(grid.h_offset(), 0.0)
  assert_eq(grid.offset(), 0.0)
  assert_eq(texts_now()[0], "a")
  b.terminate()
}
