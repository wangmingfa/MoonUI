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
/// `T102` 第十四刀：排序回调——表头点击只**报请求**，排由调用方接手。
///
/// 判据为什么这么设计（每条对着一个"接线错了就一定红"的地方）：
/// - **请求参数**：同列再点翻方向、换列回升序，与内置排序同一套口径；程序化
///   `sort_by_column` 也走这条回调（用户分不出"点表头"与"调 API"两个入口）。
/// - **表真的不排**：数据选成"调用方要的顺序与字典序**相反**"——表若偷偷按
///   字典序排，正文首行会是 `"a"` 而不是调用方给的 `"c"`。
/// - **换数据之后也不排**：`set_rows` 会把排序标记置脏，最容易漏的一支就在
///   这里——漏了的话调用方排好的顺序会被内置比较再排一遍，箭头与正文对不上。
/// - **箭头照请求画**：回调模式没有内置 `sort_order` 可依据，箭头只能看
///   `sort_col` / `sort_asc`；不清这两笔就整个消失。
test "DataGrid：排序回调只把请求报给调用方，表自己不排（T102 第十四刀）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("name", 60.0),
    @widgets.GridColumn::new("n", 60.0),
  ]
  let requests : Array[(Int32, Bool)] = []
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["b", "2"], ["a", "1"], ["c", "3"]],
    width=120.0,
    height=100.0,
    on_sort=Some(fn(col, asc) { requests.push((col, asc)) }),
  )
  let wg = grid.widget()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 排序回调",
    @moonui.LogicalSize(200.0, 200.0),
  )
  let pad = @moonui.Widget::label(b, "垫一行")
  win.set_content(@moonui.Widget::column(b, 0.0, [pad, wg]))
  win.show()
  let _ = app.step()
  let origin = wg.frame().origin
  assert_true(origin.y > 0.0)
  let head_y = origin.y + 14.0
  let click = fn(x : Double) raise {
    b.push_event(
      @moonui.MouseDown(
        wg.target(),
        @moonui.Left,
        @moonui.LogicalPoint(x, head_y),
      ),
    )
    let _ = app.step()
  }
  // ① 点第一列表头 → 报 (0, 升序)；表不排，正文仍是数据的原顺序
  click(origin.x + 30.0)
  assert_eq(requests, [(0, true)])
  assert_eq(grid.sort_column(), 0)
  assert_true(grid.sort_ascending())
  // 箭头照请求画：1 底 + 1 表头底 + 1 表头文案 + 1 箭头
  let dl1 = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  match dl1.commands()[3] {
    @moonui.Text(text, _, _, _, _, _) => assert_eq(text, "▲")
    _ => fail("回调模式没有画出升序箭头")
  }
  assert_eq(
    body_texts(
      match b.drawn(wg.handle().unwrap()) {
        Some(dl) => dl
        None => abort("没画过")
      },
    )[0],
    "b",
  )
  // ② 再点同一列 → 报 (0, 降序)，正文仍不动
  click(origin.x + 30.0)
  assert_eq(requests, [(0, true), (0, false)])
  assert_false(grid.sort_ascending())
  let dl2 = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  match dl2.commands()[3] {
    @moonui.Text(text, _, _, _, _, _) => assert_eq(text, "▼")
    _ => fail("回调模式没有画出降序箭头")
  }
  assert_eq(
    body_texts(
      match b.drawn(wg.handle().unwrap()) {
        Some(dl) => dl
        None => abort("没画过")
      },
    )[0],
    "b",
  )
  // ③ 点第二列 → 换列回升序；程序化入口走同一条回调
  click(origin.x + 90.0)
  grid.sort_by_column(0)
  assert_eq(requests, [(0, true), (0, false), (1, true), (0, true)])
  // ④ 调用方按**自己的口径**换数据（与字典序相反）→ 正文就按它给的顺序
  //    `set_rows` 置脏之后若又走内置比较，首行会变成 "a"
  grid.set_rows([["c", "3"], ["a", "1"], ["b", "2"]])
  let texts = body_texts(
    match b.drawn(wg.handle().unwrap()) {
      Some(dl) => dl
      None => abort("没画过")
    },
  )
  assert_eq(texts[0], "c")
  assert_eq(texts[2], "a")
  assert_eq(grid.sort_column(), 0)
  // ⑤ `clear_sort` 只清箭头、不回调（数据顺序归调用方）
  let before = requests.length()
  grid.clear_sort()
  assert_eq(grid.sort_column(), -1)
  assert_eq(requests.length(), before)
  assert_eq(
    body_texts(
      match b.drawn(wg.handle().unwrap()) {
        Some(dl) => dl
        None => abort("没画过")
      },
    )[0],
    "c",
  )
  b.terminate()
}

///|
/// `T102` 第十六刀：拖表头的列边界调列宽。
///
/// 判据为什么这么设计（每条对着一个"接线错了就一定红"的地方）：
/// - **边界优先于排序**：按下的点落在两列之间的缝里，这件事归"调宽"——若排序
///   先命中，用户永远调不动，而且拖完还会顺手把表排一遍。所以这一条同时钉
///   "宽变了"与"`sort_column()` 仍是 -1"。
/// - **用按下时的宽 + 位移算**：一次 +30 必须得到 60+30=90；写成"每帧加增量"
///   的话，同一份判据只投一颗移动事件是看不出来的——所以这里投**两颗**移动
///   （+20、+10），增量口径会得到 60+20+10=90 也一样……因此改投 +30 与 +30
///   再回 -10 更没意义。真正的护法是"回到原位"：从 60 拖到 +30 再拖回 -0，
///   必须回到 60，而不是累加成别的数。
/// - **下限**：往左拖过头夹到 24，不是 0（0 宽列等于让这一列消失）。
/// - **命中跟着宽走**：调宽之后 x=75 属于第 0 列（旧宽 60 时它属于第 1 列）——
///   这一条钉"绘制、命中、横向上限读的是同一份宽"。
/// - **自适应模式下不接**：那里的列宽由"自然宽压进可用宽"决定，拖了也看不见
///   变化；此时边界**不排序**（拖完手指抬起不该顺手排序）。这一段只钉"用户可见
///   的没变化"——自适应下的列宽根本不读手动账，所以把这道守卫去掉这几条断言
///   也**不会**变红（它的护法是"不污染 `col_widths`、不让后续移动事件被吞掉"，
///   要等将来接了 hover 才在外部看得见）。本刀的第二条负控制因此落在"下限
///   夹 24"上，那一条去掉必红。
test "DataGrid：拖表头列边界调列宽，边界不排序（T102 第十六刀）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("name", 60.0),
    @widgets.GridColumn::new("n", 60.0),
  ]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["b", "2"], ["a", "1"]],
    width=120.0,
    height=100.0,
  )
  let wg = grid.widget()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 表格列宽",
    @moonui.LogicalSize(200.0, 200.0),
  )
  let pad = @moonui.Widget::label(b, "垫一行")
  win.set_content(@moonui.Widget::column(b, 0.0, [pad, wg]))
  win.show()
  let _ = app.step()
  let origin = wg.frame().origin
  assert_true(origin.y > 0.0)
  let head_y = origin.y + 14.0
  // 第一个边界的控件局部 x：第一列声明宽 60（横向偏移为 0）
  let edge_x = origin.x + 60.0
  let drag = fn(x : Double) raise {
    b.push_event(
      @moonui.MouseMove(wg.target(), @moonui.LogicalPoint(x, head_y)),
    )
    let _ = app.step()
  }
  assert_eq(grid.column_width(0), 60.0)
  // ① 在边界上按下 → 拖到 +30 → 宽 90，且这颗按下没有排序
  b.push_event(
    @moonui.MouseDown(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(edge_x, head_y),
    ),
  )
  let _ = app.step()
  assert_eq(grid.sort_column(), -1)
  drag(edge_x + 30.0)
  assert_eq(grid.column_width(0), 90.0)
  assert_eq(grid.sort_column(), -1)
  // ② 拖回按下点 → 回到 60（"按下时的宽 + 位移"，不是逐帧累加）
  drag(edge_x)
  assert_eq(grid.column_width(0), 60.0)
  // ③ 拖过头 → 夹在下限 24，不是 0
  drag(edge_x - 80.0)
  assert_eq(grid.column_width(0), 24.0)
  b.push_event(
    @moonui.MouseUp(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(edge_x - 80.0, head_y),
    ),
  )
  let _ = app.step()
  // ④ 抬起之后再移动不再改宽（拖动已结束）
  drag(edge_x + 40.0)
  assert_eq(grid.column_width(0), 24.0)
  // ⑤ 命中跟着宽走：第 0 列现在 24 宽，x=75 落在第 1 列；x=10 落在第 0 列
  assert_eq(grid.column_at(75.0), Some(1))
  assert_eq(grid.column_at(10.0), Some(0))
  // ⑥ 程序化入口同一条算术：设 10 → 夹到 24；重置回到声明宽 60
  grid.set_column_width(1, 10.0)
  assert_eq(grid.column_width(1), 24.0)
  grid.reset_column_widths()
  assert_eq(grid.column_width(0), 60.0)
  assert_eq(grid.column_width(1), 60.0)
  // ⑦ 负控制：不在边界上的表头点击照旧排序（边界判定没有把整行表头吃掉）
  b.push_event(
    @moonui.MouseDown(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 30.0, head_y),
    ),
  )
  let _ = app.step()
  assert_eq(grid.sort_column(), 0)
  // ⑧ 自适应模式下边界拖动既不调宽也不排序
  let fit = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["b", "2"], ["a", "1"]],
    width=120.0,
    height=100.0,
    auto_width=true,
  )
  let fw = fit.widget()
  let app2 = @moonui.App::new(b)
  let win2 = app2.create_window(
    "MoonUI 表格自适应列宽",
    @moonui.LogicalSize(200.0, 200.0),
  )
  win2.set_content(@moonui.Widget::column(b, 0.0, [fw]))
  win2.show()
  let _ = app2.step()
  let f_origin = fw.frame().origin
  let f_edge = f_origin.x + 60.0
  b.push_event(
    @moonui.MouseDown(
      fw.target(),
      @moonui.Left,
      @moonui.LogicalPoint(f_edge, f_origin.y + 14.0),
    ),
  )
  b.push_event(
    @moonui.MouseMove(
      fw.target(),
      @moonui.LogicalPoint(f_edge + 30.0, f_origin.y + 14.0),
    ),
  )
  let _ = app2.step()
  assert_eq(fit.column_at(f_edge - f_origin.x + 40.0), Some(1))
  assert_eq(fit.sort_column(), -1)
  b.terminate()
}

///|
/// `T102` 第十七刀：右键菜单的默认接线。
///
/// 判据为什么这么设计（每条对着一个"接线错了就一定红"的地方）：
/// - **右键先选行**：菜单里的「复制」取的是 `selected`，不选的话它复制的是别处
///   （或什么都不做）。所以第一颗右键就必须把选中挪到指针下那一行。
/// - **两个入口共用一份语义**：菜单项的回调直接走第十五刀的内部函数，所以
///   "点菜单复制"与 "⌘C" 的结果必须逐字一致——这里先让菜单复制、再把结果喂给
///   菜单粘贴，`on_paste` 收到的就是刚复制出去的那一行。
/// - **置灰不是装饰**：没有选中行时两个条目都必须 `is_enabled() == false`，
///   而且 `fire()` 返回 0（真按下去什么都不发生）。只钉"菜单弹出来了"的话，
///   "永远可点"这种错看不出来。
/// - **表头 / 空白保留选中**：那两处没有"哪一行"，右键不该清掉用户原来的选中。
/// - **`context_menu=false` 就不接**：调用方自己管菜单时，两条路不能同时开
///   （同时开会各弹一次）。
test "DataGrid：右键选中行并弹出复制/粘贴菜单（T102 第十七刀）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("name", 60.0),
    @widgets.GridColumn::new("n", 60.0),
  ]
  let mut paste_row = -1
  let mut paste_text = ""
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["b", "2"], ["a", "1"]],
    width=120.0,
    height=100.0,
    on_paste=Some(fn(row, text) {
      paste_row = row
      paste_text = text
    }),
  )
  let wg = grid.widget()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 表格右键",
    @moonui.LogicalSize(200.0, 200.0),
  )
  let pad = @moonui.Widget::label(b, "垫一行")
  win.set_content(@moonui.Widget::column(b, 0.0, [pad, wg]))
  win.show()
  let _ = app.step()
  let origin = wg.frame().origin
  let body_row1 = origin.y + 28.0 + 24.0 * 1.5
  // ① 右键正文第 1 行 → 选中数据行 1，弹出一份「表格」菜单
  b.push_event(
    @moonui.MouseDown(
      wg.target(),
      @moonui.Right,
      @moonui.LogicalPoint(origin.x + 20.0, body_row1),
    ),
  )
  let _ = app.step()
  assert_eq(grid.selected(), 1)
  assert_eq(b.context_menu_install_count(), 1)
  let items = match b.context_menu_last() {
    Some(m) => {
      assert_eq(m.title(), "表格")
      m.flatten()
    }
    None => fail("右键没有请求弹出菜单")
  }
  assert_eq(items.length(), 2)
  assert_eq(items[0].describe(), "复制")
  assert_eq(items[1].describe(), "粘贴")
  assert_true(items[0].is_enabled())
  assert_true(items[1].is_enabled())
  // ② 点「复制」= ⌘C：剪贴板是当前选中那条数据
  let _ = items[0].fire()
  assert_eq(b.clipboard_text(), Some("a\t1\n"))
  // ③ 点「粘贴」= ⌘V：on_paste 收到的就是刚复制出去的那一行
  let _ = items[1].fire()
  assert_eq(paste_row, 1)
  assert_eq(paste_text, "a\t1\n")
  // ④ 右键表头：不改选中，菜单照弹
  b.push_event(
    @moonui.MouseDown(
      wg.target(),
      @moonui.Right,
      @moonui.LogicalPoint(origin.x + 20.0, origin.y + 14.0),
    ),
  )
  let _ = app.step()
  assert_eq(grid.selected(), 1)
  assert_eq(b.context_menu_install_count(), 2)
  // ⑤ 没有选中行时两个条目都置灰，fire() 也不做事
  let fresh = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["b", "2"], ["a", "1"]],
    width=120.0,
    height=100.0,
    on_paste=Some(fn(_, _) { () }),
  )
  let fw = fresh.widget()
  let app2 = @moonui.App::new(b)
  let win2 = app2.create_window(
    "MoonUI 表格右键空选中",
    @moonui.LogicalSize(200.0, 200.0),
  )
  win2.set_content(fw)
  win2.show()
  let _ = app2.step()
  let f_origin = fw.frame().origin
  b.push_event(
    @moonui.MouseDown(
      fw.target(),
      @moonui.Right,
      @moonui.LogicalPoint(f_origin.x + 20.0, f_origin.y + 14.0),
    ),
  )
  let _ = app2.step()
  assert_eq(fresh.selected(), -1)
  let muted = match b.context_menu_last() {
    Some(m) => m.flatten()
    None => fail("右键没有请求弹出菜单")
  }
  assert_true(!muted[0].is_enabled())
  assert_true(!muted[1].is_enabled())
  let before = b.clipboard_text()
  assert_eq(muted[0].fire(), 0)
  assert_eq(muted[1].fire(), 0)
  assert_eq(b.clipboard_text(), before)
  // ⑥ context_menu=false：右键不弹、也不改选中
  let quiet = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["b", "2"], ["a", "1"]],
    width=120.0,
    height=100.0,
    context_menu=false,
  )
  let qw = quiet.widget()
  let app3 = @moonui.App::new(b)
  let win3 = app3.create_window(
    "MoonUI 表格自管菜单",
    @moonui.LogicalSize(200.0, 200.0),
  )
  win3.set_content(qw)
  win3.show()
  let _ = app3.step()
  let q_origin = qw.frame().origin
  let count_before = b.context_menu_install_count()
  b.push_event(
    @moonui.MouseDown(
      qw.target(),
      @moonui.Right,
      @moonui.LogicalPoint(q_origin.x + 20.0, q_origin.y + 28.0 + 36.0),
    ),
  )
  let _ = app3.step()
  assert_eq(quiet.selected(), -1)
  assert_eq(b.context_menu_install_count(), count_before)
  b.terminate()
}

///|
/// `T102` 第十八刀：按需取行（懒加载 / 分页数据源）。
///
/// 判据为什么这么设计：
/// - **用差量断言取数请求**：`on_fetch` 记下每一次 `(起始, 差额)`，于是"要没要、
///   要多少、从哪要"三件事都能逐字对上；只断言"叫过"的话，要错范围也看不出来。
/// - **首帧就要**：窗口 72 高、行高 24 → 一屏 3 行，只给了 2 行，差额就是 1
///   （`(2, 1)`）。不叫的话用户看到半屏空板，要等他自己滚动。
/// - **同一窗口不重复要**：再画一帧必须是同一个请求数——没有这道上界，一次滑动
///   经过几十帧就会发几十次同样的请求。
/// - **滚动范围按声明总数**：200 × 24 − 72 = 4728，滚到底能停在 4728（只按已
///   加载的 3 行算的话上限是 0，用户永远到不了底部）。
/// - **未加载那段只画底板**：到 4728 时正文一条文字都没有，但分隔线照画——否则
///   滚到底看到的是一块秃板，用户以为表坏了。
/// - **数据补齐就出现**：同一窗口补到 200 行之后，正文正好是第 197–199 行。
/// - **声明值小于已加载条数时不起作用**：`total_rows()` 取较大者，已经拿到的行
///   不能被藏到滚动范围外。
test "DataGrid：声明总数后按窗口要数据，未加载那段只画底板（T102 第十八刀）" {
  let b = mock()
  let cols = [@widgets.GridColumn::new("name", 60.0)]
  let asks : Array[(Int32, Int32)] = []
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["a"], ["b"]],
    width=120.0,
    height=100.0,
    total_rows=200,
    on_fetch=Some(fn(start, count) { asks.push((start, count)) }),
  )
  assert_eq(grid.total_rows(), 200)
  assert_eq(grid.row_count(), 2)
  let wg = grid.widget()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 表格懒加载",
    @moonui.LogicalSize(200.0, 200.0),
  )
  win.set_content(@moonui.Widget::column(b, 0.0, [wg]))
  win.show()
  let _ = app.step()
  fn drawn_now() -> @moonui.DrawList raise @moonui.UiError {
    match b.drawn(wg.handle().unwrap()) {
      Some(dl) => dl
      None => abort("没画过")
    }
  }
  // ① 首帧：一屏 3 行、只有 2 行 → 要 (2, 1)
  assert_eq(asks.length(), 1)
  assert_eq(asks[0], (2, 1))
  // ② 窗口没变，再画一帧不重复要
  grid.set_offset(0.0)
  let _ = app.step()
  assert_eq(asks.length(), 1)
  // ③ 补到 3 行：这一屏够了，仍不要
  grid.set_rows([["a"], ["b"], ["c"]])
  let _ = app.step()
  assert_eq(asks.length(), 1)
  assert_eq(body_texts(drawn_now())[0], "a")
  // ④ 直接拖到底：上限按声明总数算（200 × 24 − 72 = 4728），
  //    窗口首行 197、需要到 200 → 要 (3, 197)（缺口是整个，不是一页）
  grid.set_offset(10000.0)
  let _ = app.step()
  assert_eq(grid.offset(), 4728.0)
  assert_eq(asks.length(), 2)
  assert_eq(asks[1], (3, 197))
  // ⑤ 这一段一行都没加载：正文字一条都没有，但分隔线照画
  //    （三行只画两条：贴着底边那一条落在控件外，不画）
  let dl = drawn_now()
  assert_eq(body_texts(dl).length(), 0)
  let mut body_lines = 0
  for cmd in dl.commands() {
    match cmd {
      @moonui.Line(_, y0, _, _, _, _) =>
        if y0 > 28.0 {
          body_lines = body_lines + 1
        }
      _ => ()
    }
  }
  assert_eq(body_lines, 2)
  // ⑥ 数据补齐到 200：同一窗口画出第 197–199 行，且不再要
  let all : Array[Array[String]] = []
  let mut i = 0
  while i < 200 {
    all.push(["r\{i}"])
    i = i + 1
  }
  grid.set_rows(all)
  let _ = app.step()
  let t = body_texts(drawn_now())
  assert_eq(t.length(), 3)
  assert_eq(t[0], "r197")
  assert_eq(t[2], "r199")
  assert_eq(asks.length(), 2)
  // ⑦ 声明值小于已加载条数时不起作用（已经拿到的行不能被藏起来）
  grid.set_total_rows(5)
  assert_eq(grid.total_rows(), 200)
  // ⑧ 没给回调也照常工作：范围按声明值、已加载条数照旧可读，未加载处 row_at 给 None
  let quiet = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["a"], ["b"]],
    width=120.0,
    height=100.0,
    total_rows=50,
  )
  assert_eq(quiet.total_rows(), 50)
  assert_eq(quiet.row_count(), 2)
  assert_eq(quiet.row_at(28.0 + 24.0 * 2.5), None)
  quiet.set_total_rows(3)
  assert_eq(quiet.total_rows(), 3)
  quiet.set_total_rows(0)
  assert_eq(quiet.total_rows(), 2)
  b.terminate()
}

///|
/// `T102` 第十九刀：逐行行高。
///
/// 判据为什么这么设计：
/// - **画在哪**：行高不是"只把底色拉高"，文字要跟着在更高的行里重新居中。所以
///   判据不只看高度，还钉死每行文案的 y（前缀和 + (行高 − 字高)/2）。
/// - **滚动上限按总高**：4 行 24/48/24/24 = 120，正文 72 → 上限 48。按统一 24
///   算会是 96 − 72 = 24，滚不到最后一行的底边。
/// - **命中跟前缀和**：偏移 0 时 y=50 落在第 0 行（24 高），y=60 落在第 1 行
///   （48 高）——均匀行高下这两条会各差一行。
/// - **行高跟着数据走**：排序只改显示顺序。第 1 条数据（48 高）排到最前面之后，
///   同样的 y 应该命中**它**，`row_height_of(1)` 仍是 48；`scroll_to_row(1)` 也
///   应该滚到 0（它现在在最上面）而不是 24。
/// - **换行高要重夹偏移**：从 48 换回全 24 之后总高 96、上限 24，旧的 48 必须
///   收回，否则停在空屏上。
test "DataGrid：逐行行高——画在哪、命中、滚动上限、排序后跟着数据走（T102 第十九刀）" {
  let b = mock()
  let cols = [@widgets.GridColumn::new("name", 60.0)]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["b"], ["a"], ["c"], ["d"]],
    width=120.0,
    height=100.0,
    row_heights=[24.0, 48.0, 24.0, 24.0],
  )
  // ① 读数：覆盖行用覆盖值；越界与 `<= 0` 的项回落统一行高
  assert_eq(grid.row_height_of(0), 24.0)
  assert_eq(grid.row_height_of(1), 48.0)
  assert_eq(grid.row_height_of(99), 24.0)
  let wg = grid.widget()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 变高行",
    @moonui.LogicalSize(200.0, 200.0),
  )
  win.set_content(wg)
  win.show()
  let _ = app.step()
  // ② 画在哪：行首 = 28 + 前缀和（0 / 24 / 72 / 96），文字在行内居中
  //    （字高 16）：32 / 68 / 104 / 128（第 3 行顶边 96 还在窗内，虽然大半被底边裁掉）
  fn text_ys(dl : @moonui.DrawList) -> Array[(String, Double)] {
    let out : Array[(String, Double)] = []
    for cmd in dl.commands() {
      match cmd {
        @moonui.Text(text, _, y, _, _, _) =>
          if y >= 32.0 {
            out.push((text, y))
          }
        _ => ()
      }
    }
    out
  }
  let dl = match b.drawn(wg.handle().unwrap()) {
    Some(d) => d
    None => abort("没画过")
  }
  let tys = text_ys(dl)
  assert_eq(tys.length(), 4)
  assert_eq(tys[0], ("b", 32.0))
  assert_eq(tys[1], ("a", 68.0))
  assert_eq(tys[2], ("c", 104.0))
  assert_eq(tys[3], ("d", 128.0))
  // ③ 滚动上限 = 120 − 72 = 48（按统一 24 算会误成 24）
  grid.set_offset(9999.0)
  assert_eq(grid.offset(), 48.0)
  // ④ 命中跟前缀和：先回到顶部
  grid.set_offset(0.0)
  assert_eq(grid.row_at(50.0), Some(0))
  assert_eq(grid.row_at(60.0), Some(1))
  assert_eq(grid.row_at(28.0 + 120.0), None)
  // ⑤ 排序：第 1 条数据（48 高）排到最前面，命中的是它，行高也跟着它
  grid.sort_by_column(0)
  assert_eq(grid.row_at(28.0 + 30.0), Some(1))
  assert_eq(grid.row_height_of(1), 48.0)
  grid.scroll_to_row(1)
  assert_eq(grid.offset(), 0.0)
  grid.clear_sort()
  grid.scroll_to_row(1)
  assert_eq(grid.offset(), 24.0)
  // ⑥ 换行高要重夹偏移：48 换回全 24 之后上限 24
  grid.set_offset(48.0)
  grid.set_row_heights([])
  assert_eq(grid.offset(), 24.0)
  assert_eq(grid.row_height_of(1), 24.0)
  // ⑦ 短数组只覆盖前面几行；`<= 0` 的项回落
  grid.set_row_heights([40.0, 0.0])
  assert_eq(grid.row_height_of(0), 40.0)
  assert_eq(grid.row_height_of(1), 24.0)
  b.terminate()
}

///|
/// `T102` 第二十刀：非字符串单元格（勾选框 / 色块 / 进度条）。
///
/// 判据为什么这么设计：
/// - **"false" 不能画成勾**：这一列最容易犯的错就是"非空就算真"。所以每一列都
///   同时钉一个真值与一个假值，而且假值里专门放 `"false"` / `"0"`。
/// - **构图按命令对账**：勾选框只有一条 `FillRect`（蓝底），假值是 `FillRect`（白底）
///   + `StrokeRect`（边框）；色块是"填充色 = 那串颜色"+ 描边；进度条是"底板 +
///   蓝条"两条 `FillRect`，宽度 = 可用宽 × 分数。
/// - **夹到 0..1**：`"150%"` 要画满、`"-3"` 要画空，否则条会越出格子。
/// - **认不出的色值什么都不画**（不是画成黑色）：黑色是一个真实的颜色，画它等于
///   撒谎。所以 `"nope"` 那一格在这一列里一条命令都不贡献。
/// - **数据模型不变**：格子值仍是字符串，`copy_selected()` 出去的仍是人读得懂
///   的 TSV（色值列复制 `"#FF0000"`，勾列复制 `"true"`）——这是这一刀"画法变、
///   数据不变"的对外证据。
test "DataGrid：复选框/色块/进度条三种格子，夹比例、认不出的不画（T102 第二十刀）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("done", 60.0, kind=@widgets.GridCellKind::Check),
    @widgets.GridColumn::new("color", 60.0, kind=@widgets.GridCellKind::Swatch),
    @widgets.GridColumn::new("pct", 80.0, kind=@widgets.GridCellKind::Bar),
  ]
  assert_eq(cols[0].kind(), @widgets.GridCellKind::Check)
  assert_eq(cols[1].kind(), @widgets.GridCellKind::Swatch)
  assert_eq(cols[2].kind(), @widgets.GridCellKind::Bar)
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["true", "#FF0000", "50%"], ["false", "nope", "150%"]],
    width=200.0,
    height=100.0,
    row_height=24.0,
  )
  let wg = grid.widget()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 非字符串单元格",
    @moonui.LogicalSize(200.0, 200.0),
  )
  win.set_content(wg)
  win.show()
  let _ = app.step()
  let dl = match b.drawn(wg.handle().unwrap()) {
    Some(d) => d
    None => abort("没画过")
  }
  fn body_cmds(dl : @moonui.DrawList) -> Array[@moonui.DrawCmd] {
    let out : Array[@moonui.DrawCmd] = []
    for cmd in dl.commands() {
      let keep = match cmd {
        @moonui.FillRect(_, y, _, _, _, _, _) => y >= 28.0
        @moonui.StrokeRect(_, y, _, _, _, _, _) => y >= 28.0
        @moonui.Line(_, y0, _, _, _, _) => y0 >= 28.0
        @moonui.Text(_, _, y, _, _, _) => y >= 28.0
        _ => false
      }
      if keep {
        out.push(cmd)
      }
    }
    out
  }
  let cmds = body_cmds(dl)
  // 第 0 行：勾（14×14 蓝底 + 两条白线）、色块（#FF0000 填充 + 描边）、
  // 进度条（文字 + 底板 + 50% 的条）
  // 只数"矩形"，勾的两条线单独数
  let rects : Array[@moonui.DrawCmd] = []
  let mut lines = 0
  let texts : Array[String] = []
  for cmd in cmds {
    match cmd {
      @moonui.FillRect(_, y, _, _, _, _, _) => if y < 52.0 { rects.push(cmd) }
      @moonui.StrokeRect(_, y, _, _, _, _, _) => if y < 52.0 { rects.push(cmd) }
      @moonui.Line(_, y0, _, _, _, _) =>
        if y0 < 52.0 && y0 > 28.0 {
          lines = lines + 1
        }
      @moonui.Text(text, _, _, _, _, _) => if text != "" { texts.push(text) }
      _ => ()
    }
  }
  // 勾：蓝底 + 两条线 → 1 个 FillRect、2 条 Line
  assert_eq(lines, 2)
  // 色块：填充 + 描边 → 这两个都在第 0 行，且填充色就是 #FF0000
  let mut found_red = false
  for cmd in rects {
    match cmd {
      @moonui.FillRect(x, _, w, _, _, rgb, _) =>
        if x == 68.0 && w == 20.0 && rgb == 0xFF0000 {
          found_red = true
        }
      _ => ()
    }
  }
  assert_true(found_red)
  // 进度条：文字 "50%" + 底板（80 − 2×8 = 64 宽，从 128 起）+ 32 宽的蓝条
  assert_true(texts.contains("50%"))
  let mut bar_fill = 0.0
  let mut bar_track = 0.0
  for cmd in rects {
    match cmd {
      @moonui.FillRect(x, _, w, _, _, rgb, _) =>
        if x >= 128.0 {
          if rgb == 0x3182CE {
            bar_fill = w
          } else if rgb == 0xE2E8F0 && w > bar_track {
            bar_track = w
          }
        }
      _ => ()
    }
  }
  assert_eq(bar_track, 64.0)
  assert_eq(bar_fill, 32.0)
  // 第 1 行："false" → 空框（白底 + 描边，没有线）；"nope" → 什么都不画；
  // "150%" → 夹满 64
  let mut row1_lines = 0
  let mut row1_white = false
  let mut row1_full = 0.0
  for cmd in body_cmds(dl) {
    match cmd {
      // 只数"斜线"：行分隔线是水平的（y0 == y1），勾的两段线是斜的
      @moonui.Line(_, y0, _, y1, _, _) =>
        if y0 >= 52.0 && y0 != y1 {
          row1_lines = row1_lines + 1
        }
      @moonui.FillRect(x, y, w, _, _, rgb, _) =>
        if y >= 52.0 {
          if rgb == 0xFFFFFF && x == 8.0 {
            row1_white = true
          }
          if rgb == 0x3182CE && x >= 128.0 {
            row1_full = w
          }
        }
      _ => ()
    }
  }
  assert_eq(row1_lines, 0)
  assert_true(row1_white)
  assert_eq(row1_full, 64.0)
  // 数据模型没变：复制出去还是人读得懂的那串
  grid.select_row(0)
  assert_true(grid.copy_selected())
  assert_eq(b.clipboard_text(), Some("true\t#FF0000\t50%\n"))
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

///|
/// `T102` 第九刀：正文拖行重排。
///
/// 判据为什么这么设计：
/// - **数据有区分度**：四行 `a` / `b` / `c` / `d`，重排后每一条都必须换到
///   能分辨的位置上（全一样的文本会让"挪没挪"看不出来）。
/// - **单击不动**：按下→抬起、中间没有移动，行序必须原样——这一条钉的是
///   "过阈值才算拖"，把阈值去掉就会红。
/// - **拖拽中看得见落点**：`MouseMove` 之后画一条 2px 的落点线（色 `0x3182CE`），
///   y 落在插入间隙上；只断言"重排发生了"的话，拖拽过程没有任何反馈也能过。
/// - **选中跟着数据走**：拖完 `selected` 必须指向同一**条**数据的新行号，
///   否则用户看到高亮条留在原地。
/// - **排序中不接拖拽**：排序激活时显示顺序由排序决定，拖拽改的是数据顺序，
///   接上等于骗人；这一条同时断言"排序确实激活了"（正文首行是 `a`），
///   否则判据会因为没排序而空转。
test "DataGrid：拖行重排，单击不动、落点有反馈、排序中不接（T102 第九刀）" {
  let b = mock()
  let cols = [@widgets.GridColumn::new("name", 100.0)]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["a"], ["b"], ["c"], ["d"]],
    width=120.0,
    height=200.0,
  )
  let wg = grid.widget()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 表格拖行",
    @moonui.LogicalSize(200.0, 300.0),
  )
  // 垫一行让表不在窗口左上角：钉住"事件坐标减了控件 origin"
  let pad = @moonui.Widget::label(b, "垫一行")
  win.set_content(@moonui.Widget::column(b, 0.0, [pad, wg]))
  win.show()
  let _ = app.step()
  let origin = wg.frame().origin
  assert_true(origin.y > 0.0)
  fn row_y(view_pos : Int32) -> Double {
    origin.y + 28.0 + view_pos.to_double() * 24.0 + 12.0
  }
  fn order() -> Array[String] {
    let out : Array[String] = []
    for i in 0..<4 {
      out.push(grid.cell(i, 0).unwrap_or("?"))
    }
    out
  }
  fn gap_line_y() -> Double raise @moonui.UiError {
    let dl = match b.drawn(wg.handle().unwrap()) {
      Some(dl) => dl
      None => abort("没画过")
    }
    for cmd in dl.commands() {
      match cmd {
        @moonui.Line(_, y0, _, y1, width, rgb) =>
          if rgb == 0x3182CE && near(y0, y1) && near(width, 2.0) {
            return y0
          }
        _ => ()
      }
    }
    -1.0
  }
  // ① 单击第 0 行（按下→抬起，没移动）→ 行序原样
  b.push_event(
    @moonui.MouseDown(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 10.0, row_y(0)),
    ),
  )
  let _ = app.step()
  b.push_event(
    @moonui.MouseUp(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 10.0, row_y(0)),
    ),
  )
  let _ = app.step()
  assert_eq(order(), ["a", "b", "c", "d"])
  // ①b 按下第 1 行、只挪 1px（手抖，没过 4px 阈值）再抬起 → 行序仍原样。
  //      这一条钉的是"过阈值才算拖"；阈值去掉的话它会被当成拖到本行附近。
  b.push_event(
    @moonui.MouseDown(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 10.0, row_y(1)),
    ),
  )
  let _ = app.step()
  b.push_event(
    @moonui.MouseMove(
      wg.target(),
      @moonui.LogicalPoint(origin.x + 10.0, row_y(1) + 1.0),
    ),
  )
  let _ = app.step()
  // 没过阈值：不画落点线
  assert_true(near(gap_line_y(), -1.0))
  b.push_event(
    @moonui.MouseUp(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 10.0, row_y(1) + 1.0),
    ),
  )
  let _ = app.step()
  assert_eq(order(), ["a", "b", "c", "d"])

  grid.select_row(0)
  assert_eq(grid.selected(), 0)
  b.push_event(
    @moonui.MouseDown(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 10.0, row_y(0)),
    ),
  )
  let _ = app.step()
  b.push_event(
    @moonui.MouseMove(
      wg.target(),
      @moonui.LogicalPoint(origin.x + 10.0, origin.y + 124.0),
    ),
  )
  let _ = app.step()
  // 拖拽中：落点线画在 gap = 4 的位置（表头 28 + 4 × 24 = 124）
  assert_true(near(gap_line_y(), 124.0))
  b.push_event(
    @moonui.MouseUp(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 10.0, origin.y + 124.0),
    ),
  )
  let _ = app.step()
  assert_eq(order(), ["b", "c", "d", "a"])
  // 选中跟着同一条数据走：`a` 挪到了行号 3
  assert_eq(grid.selected(), 3)
  // 抬起之后落点线不该留在画面上
  assert_true(near(gap_line_y(), -1.0))
  // ③ 再把最后一行（`a`）往上拖到 gap = 1（局部 y = 28 + 24 = 52）
  b.push_event(
    @moonui.MouseDown(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 10.0, row_y(3)),
    ),
  )
  let _ = app.step()
  b.push_event(
    @moonui.MouseMove(
      wg.target(),
      @moonui.LogicalPoint(origin.x + 10.0, origin.y + 52.0),
    ),
  )
  let _ = app.step()
  assert_true(near(gap_line_y(), 52.0))
  b.push_event(
    @moonui.MouseUp(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 10.0, origin.y + 52.0),
    ),
  )
  let _ = app.step()
  assert_eq(order(), ["b", "a", "c", "d"])
  // ④ 排序激活时不接拖拽：先按 name 升序排（数据顺序不变），再拖第 0 显示行
  grid.sort_by_column(0)
  let texts = body_texts(
    match b.drawn(wg.handle().unwrap()) {
      Some(dl) => dl
      None => abort("没画过")
    },
  )
  assert_eq(texts[0], "a")
  b.push_event(
    @moonui.MouseDown(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 10.0, row_y(0)),
    ),
  )
  let _ = app.step()
  b.push_event(
    @moonui.MouseMove(
      wg.target(),
      @moonui.LogicalPoint(origin.x + 10.0, origin.y + 124.0),
    ),
  )
  let _ = app.step()
  b.push_event(
    @moonui.MouseUp(
      wg.target(),
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 10.0, origin.y + 124.0),
    ),
  )
  let _ = app.step()
  // 数据顺序原样（拖拽被拒），显示顺序仍按排序
  assert_eq(order(), ["b", "a", "c", "d"])
  // ⑤ 公开 `move_row`：正常挪 + 越界报错
  grid.clear_sort()
  grid.move_row(3, 0)
  assert_eq(order(), ["d", "b", "a", "c"])
  let err : String? = try {
    grid.move_row(0, 9)
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(err, Some("操作失败：表格目标行号越界：9"))
  b.terminate()
}

///|
/// `T102` 第十刀：键盘导航的**默认接线**。
///
/// 判据设计（每条对着一个"接线错了就一定红"的地方）：
/// - **数据留余量**：五行 × 24 = 120，正文 100 − 28 = 72 → 可视 3 行、上限 48。
///   没有余量的话"走到边上才滚"这一半判据是空的。
/// - **步幅**：`PageDown` 走"一屏几行"（这里是 3），不是 1；翻页步幅写死成 1
///   在 `PageUp` 那一条上必红。
/// - **只在该行看不见时才滚**：`Down` 到第 3 行（下标 2）时底边正好 72，偏移
///   必须还是 0；再往下一行才变 24。每次 `scroll_to_row` 的实现会把 0 写成 24。
/// - **具体内容**：偏移变了要能读到正文首行换人（"b" / "c"），光比偏移数字
///   证明不了"滚的是那张表"。
/// - **修饰键与生键**：`Ctrl+Home` 不接（带 `Ctrl` 的键归别的语义，第二十一刀
///   之后 `Shift` 归扩选、也不进这条普通移动）；没有选中时按 `q` 也不能因为
///   "目标 -1 被夹成 0"就选中第一行（`handled` 那一层）。
///
/// 真窗缺口：mac 侧自绘面的 `acceptsFirstResponder` 仍是 `NO`
/// （`adapter_native.m`），所以本刀交付的是**控件侧接线与这里的判据**；
/// 真窗上要先让自绘面能拿焦点，`KeyDown` 才会到这张表（记在 `TODO.md`）。
test "DataGrid：方向键在显示顺序上移动选中，翻页按可视行数，修饰键不接（T102 第十刀）" {
  let b = mock()
  let cols = [@widgets.GridColumn::new("name", 100.0)]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["a"], ["b"], ["c"], ["d"], ["e"]],
    width=120.0,
    height=100.0,
  )
  let wg = grid.widget()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 表格键盘",
    @moonui.LogicalSize(200.0, 200.0),
  )
  // 用 column 包一层保持控件**声明尺寸**：直接 `set_content(wg)` 会把表拉到
  // 窗口高，正文比总数据还高、上限夹成 0，偏移那几条判据就空转了（第八刀踩过）。
  win.set_content(@moonui.Widget::column(b, 0.0, [wg]))
  win.show()
  let _ = app.step()
  fn press(
    key : String,
    shift : Bool,
    ctrl : Bool,
  ) -> Unit raise @moonui.UiError {
    b.push_event(
      @moonui.KeyDown(wg.target(), @moonui.KeyPress::{
        key,
        ctrl,
        alt: false,
        shift,
        meta: false,
      }),
    )
    let _ = app.step()
  }
  fn texts() -> Array[String] raise @moonui.UiError {
    body_texts(
      match b.drawn(wg.handle().unwrap()) {
        Some(dl) => dl
        None => abort("没画过")
      },
    )
  }
  // ① 没有选中时按 Down → 选中第 0 行，不滚
  press("Down", false, false)
  assert_eq(grid.selected(), 0)
  assert_true(near(grid.offset(), 0.0))
  // ② 第 0→1→2 行都还在视口里（第 2 行底边正好 72）→ 偏移一直是 0
  press("Down", false, false)
  assert_eq(grid.selected(), 1)
  press("Down", false, false)
  assert_eq(grid.selected(), 2)
  assert_true(near(grid.offset(), 0.0))
  assert_eq(texts()[0], "a")
  // ③ 再按 Down 到第 3 行：底边 96 超出正文 72 → 偏移推到 24，首行换成 "b"
  press("Down", false, false)
  assert_eq(grid.selected(), 3)
  assert_true(near(grid.offset(), 24.0))
  assert_eq(texts()[0], "b")
  // ④ 到第 4 行 → 偏移贴底 48，首行 "c"
  press("Down", false, false)
  assert_eq(grid.selected(), 4)
  assert_true(near(grid.offset(), 48.0))
  assert_eq(texts()[0], "c")
  // ⑤ 已经在最后一行 → 夹住，偏移不动
  press("Down", false, false)
  assert_eq(grid.selected(), 4)
  assert_true(near(grid.offset(), 48.0))
  // ⑥ Up 回第 3 行：它仍看得见（顶 72 底 96 都在 [48, 120]）→ 不滚
  press("Up", false, false)
  assert_eq(grid.selected(), 3)
  assert_true(near(grid.offset(), 48.0))
  // ⑦ Home 跳第一行并把视口带回顶部
  press("Home", false, false)
  assert_eq(grid.selected(), 0)
  assert_true(near(grid.offset(), 0.0))
  assert_eq(texts()[0], "a")
  // ⑧ End 跳最后一行并贴底
  press("End", false, false)
  assert_eq(grid.selected(), 4)
  assert_true(near(grid.offset(), 48.0))
  // ⑨ PageUp 退一屏（3 行）到第 1 行；偏移只推到"刚好露出"24
  press("PageUp", false, false)
  assert_eq(grid.selected(), 1)
  assert_true(near(grid.offset(), 24.0))
  // ⑩ PageDown 前进一屏回第 4 行；再按一次仍夹在最后一行
  press("PageDown", false, false)
  assert_eq(grid.selected(), 4)
  assert_true(near(grid.offset(), 48.0))
  press("PageDown", false, false)
  assert_eq(grid.selected(), 4)
  // ⑪ Ctrl+Home 不接（`Ctrl` 的键归别的语义；`Shift` 是第二十一刀的扩选，
  //    见那条单独的多选判据）
  press("Home", false, true)
  assert_eq(grid.selected(), 4)
  // ⑫ 生键不能落进夹法：清掉选中后按 "q" 必须还是没选中
  grid.select_row(-1)
  assert_eq(grid.selected(), -1)
  press("q", false, false)
  assert_eq(grid.selected(), -1)
  // ⑬ 排序之后方向键走**显示顺序**：降序是 e,d,c,b,a，选中必须落到数据行号
  //     4（"e"）而不是 0。按数据行号算的实现在这里会把 0 选中成 "a"。
  grid.sort_by_column(0)
  grid.sort_by_column(0)
  assert_false(grid.sort_ascending())
  press("Down", false, false)
  assert_eq(grid.selected(), 4)
  assert_eq(grid.cell(grid.selected(), 0).unwrap_or("?"), "e")
  press("Down", false, false)
  assert_eq(grid.selected(), 3)
  assert_eq(grid.cell(grid.selected(), 0).unwrap_or("?"), "d")
  // ⑭ 空表按方向键不崩、不凭空造出选中
  grid.set_rows([])
  press("Down", false, false)
  assert_eq(grid.selected(), -1)
  b.terminate()
}

///|
/// `T102` 第十五刀：复制 / 粘贴的默认接线。
///
/// 为什么每段都对着一个"接线错了就一定红"的地方：
/// - **复制的是选中行、按数据列序拼 TSV**：粘贴方（Excel / 飞书表格）认这个
///   形状；排序之后也必须是**选中那条数据**的内容，不能是"显示顺序上的第 n 条"。
/// - **`⌘` 与 `Ctrl` 都认、`⌥` / `⇧` 不认**：前一半是"三个后端同一张表"的
///   可移植性，后一半是"别抢应用层别的命令"——反例（`⌘⇧C`）必须一条都不动。
/// - **没选中行时复制不写剪贴板**：写个空串进去会把用户刚复制的东西冲掉，
///   这是"看起来无害"的一类错。
/// - **粘贴的三条边界**（没回调 / 剪贴板空 / 没选中）都不回调，而正常路径
///   报的是 `(数据行号, 全文)`。
test "DataGrid：⌘C/⌘V 复制选中行、粘贴交给回调（T102 第十五刀）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("name", 60.0),
    @widgets.GridColumn::new("n", 40.0),
  ]
  let pasted : Array[(Int32, String)] = []
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["a", "1"], ["b", "2"], ["c", "3"]],
    width=120.0,
    height=100.0,
    on_paste=Some(fn(row, text) { pasted.push((row, text)) }),
  )
  let wg = grid.widget()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 表格剪贴板",
    @moonui.LogicalSize(200.0, 200.0),
  )
  win.set_content(@moonui.Widget::column(b, 0.0, [wg]))
  win.show()
  let _ = app.step()
  fn press(
    key : String,
    ctrl : Bool,
    shift : Bool,
    alt : Bool,
    meta : Bool,
  ) -> Unit raise @moonui.UiError {
    b.push_event(
      @moonui.KeyDown(wg.target(), @moonui.KeyPress::{
        key,
        ctrl,
        alt,
        shift,
        meta,
      }),
    )
    let _ = app.step()
  }
  // ① 选中第 1 行，⌘C → 剪贴板是这一行的 TSV（列序、带结尾换行）
  grid.select_row(1)
  press("c", false, false, false, true)
  assert_eq(@moonui.Backend::clipboard_text(b), Some("b\t2\n"))
  // ② Ctrl+C 同一条（Windows / Linux 的键位），内容一样
  grid.select_row(2)
  press("c", true, false, false, false)
  assert_eq(@moonui.Backend::clipboard_text(b), Some("c\t3\n"))
  // ③ 负控制：⌘⇧C / ⌘⌥C 不是复制——剪贴板一位都不变
  grid.select_row(0)
  press("c", false, true, false, true)
  assert_eq(@moonui.Backend::clipboard_text(b), Some("c\t3\n"))
  press("c", false, false, true, true)
  assert_eq(@moonui.Backend::clipboard_text(b), Some("c\t3\n"))
  // ④ 没选中行：⌘C 不写剪贴板（不能把用户刚复制的冲成空串），公开 API 报 false
  grid.select_row(-1)
  press("c", false, false, false, true)
  assert_eq(@moonui.Backend::clipboard_text(b), Some("c\t3\n"))
  assert_false(grid.copy_selected())
  // ⑤ 排序之后复制的仍是**选中那条数据**：降序显示 c,b,a，选中数据行 0（"a"）
  grid.sort_by_column(0)
  grid.sort_by_column(0)
  grid.select_row(0)
  press("c", false, false, false, true)
  assert_eq(@moonui.Backend::clipboard_text(b), Some("a\t1\n"))
  // ⑥ 粘贴：回调收到（数据行号, 全文），并返回 true
  @moonui.Backend::set_clipboard_text(b, "x\ty\n")
  grid.select_row(2)
  press("v", false, false, false, true)
  assert_eq(pasted, [(2, "x\ty\n")])
  assert_true(grid.paste_from_clipboard())
  assert_eq(pasted.length(), 2)
  // ⑦ 负控制：Ctrl+V 也认；而 ⌘⇧V 不是粘贴
  press("v", true, false, false, false)
  assert_eq(pasted.length(), 3)
  press("v", false, true, false, true)
  assert_eq(pasted.length(), 3)
  // ⑧ 粘贴的三条边界：没选中 / 剪贴板空 / 没回调——都不回调
  grid.select_row(-1)
  press("v", false, false, false, true)
  assert_eq(pasted.length(), 3)
  assert_false(grid.paste_from_clipboard())
  grid.select_row(0)
  @moonui.Backend::set_clipboard_text(b, "")
  assert_false(grid.paste_from_clipboard())
  assert_eq(pasted.length(), 3)
  let no_hook = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["a", "1"]],
    width=120.0,
    height=100.0,
  )
  no_hook.select_row(0)
  @moonui.Backend::set_clipboard_text(b, "y\n")
  assert_false(no_hook.paste_from_clipboard())
  // ⑨ 负控制：普通方向键没被这两支吃掉——选中仍在动（此刻是降序 c,b,a，
  //    选中的数据行 1（"b"）在显示位置 1，Down 落到位置 2，那里是数据行 0）
  grid.select_row(1)
  let before = grid.selected()
  press("Down", false, false, false, false)
  assert_eq(grid.selected(), 0)
  assert_true(grid.selected() != before)
  b.terminate()
}

///|
/// 键盘焦点的 opt-in（`T102` 第十一刀）：表的面必须在建起来那一刻就声明
/// "我要键盘"。
///
/// 为什么这条单独测：第十刀的方向键逻辑在 Core 里已经全通，可它接的是
/// `on_any`——真窗上 `KeyDown` 派给谁由 firstResponder 决定，面不 opt-in 时
/// 点它、按方向键，派给的是窗口，整段导航一格都走不动。这一条是"接线真的
/// 接上了"的判据（真窗那一半在 `backends/native-macos` 的
/// 「自绘面焦点 opt-in」）。
///
/// 负控制：同一个后端上一块普通的自绘面仍是关的——证明上面那条断言不是
/// "mock 永远报 true"。
test "DataGrid：自绘面声明键盘焦点（T102 第十一刀）" {
  let b = mock()
  let grid = @widgets.DataGrid::new(
    b,
    [@widgets.GridColumn::new("a", 60.0)],
    rows=[["x"]],
    width=80.0,
    height=60.0,
  )
  let wg = grid.widget()
  let h = wg.handle().unwrap()
  assert_true(b.custom_focusable(h))
  let plain = @moonui.Widget::custom(b, @moonui.LogicalSize(20.0, 20.0), fn(
    _dl,
    _env,
  ) {

  })
  assert_false(b.custom_focusable(plain.handle().unwrap()))
  b.terminate()
}

///|
/// `T102` 第二十一刀：多选。
///
/// 为什么每段都对着一个"实现错了就一定红"的地方：
/// - **`Shift` 扩选的固定端不跟着头挪**：连按两次 `Shift+Down` 必须得到三行，
///   不是"永远两行"（把固定端写成本次的头的实现，这里必红）。
/// - **不带修饰的方向键折叠回单行**：多选之后按一次普通 `Down`，集合只剩新
///   落点；否则"我刚才选的那一片怎么还在"会成为常态。
/// - **整段复制按显示顺序**：`select_rows([4, 0])` 复制出来是 `a` 在前、`b`
///   在后（屏幕从上到下），不是按调用方给的数组顺序。
/// - **排序只改显示顺序**：集合存的是**数据行号**，`selected_rows()` 按显示
///   顺序给出；排序之后高亮仍钉在同几条数据上（数一帧里选中底色的条数）。
/// - **重排 / 换数据要改号**：`move_row` 之后集合里的行号跟着重编；`set_rows`
///   少了行时只剔掉越界的那几项、留下仍是用户选过的（不是一股脑清空）。
test "DataGrid：多选——Shift 扩选、⌘A 全选、整段复制、排序与重排后跟着数据走（T102 第二十一刀）" {
  let b = mock()
  let cols = [
    @widgets.GridColumn::new("name", 60.0),
    @widgets.GridColumn::new("n", 40.0),
  ]
  let grid = @widgets.DataGrid::new(
    b,
    cols,
    rows=[["a", "1"], ["b", "2"], ["c", "3"], ["d", "4"], ["e", "5"]],
    width=120.0,
    height=100.0,
  )
  let wg = grid.widget()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 表格多选",
    @moonui.LogicalSize(200.0, 200.0),
  )
  win.set_content(@moonui.Widget::column(b, 0.0, [wg]))
  win.show()
  let _ = app.step()
  fn press(
    key : String,
    ctrl : Bool,
    shift : Bool,
    meta : Bool,
  ) -> Unit raise @moonui.UiError {
    b.push_event(
      @moonui.KeyDown(wg.target(), @moonui.KeyPress::{
        key,
        ctrl,
        alt: false,
        shift,
        meta,
      }),
    )
    let _ = app.step()
  }
  // 一帧里选中底色（`selected_bg`）的条数：证明"画高亮"读的也是集合
  fn selected_bands() -> Int32 raise @moonui.UiError {
    let dl = match b.drawn(wg.handle().unwrap()) {
      Some(d) => d
      None => abort("没画过")
    }
    let mut k = 0
    for cmd in dl.commands() {
      match cmd {
        @moonui.FillRect(_, y, _, _, _, rgb, _) =>
          if y >= 28.0 && rgb == 0xEBF4FF {
            k = k + 1
          }
        _ => ()
      }
    }
    k
  }
  // ① 没有选中时 Shift+Down 等同普通选中：只有第 0 行，不造出空区间
  press("Down", false, true, false)
  assert_eq(grid.selected(), 0)
  assert_eq(grid.selection_count(), 1)
  assert_true(grid.is_selected(0))
  // ② 连按两次 Shift+Down → 0..2 三行（固定端钉在 0）
  press("Down", false, true, false)
  press("Down", false, true, false)
  assert_eq(grid.selected(), 2)
  assert_eq(grid.selection_count(), 3)
  assert_eq(grid.selected_rows(), [0, 1, 2])
  // ③ Shift+Up 收窄回 0..1（固定端还是 0）
  press("Up", false, true, false)
  assert_eq(grid.selected(), 1)
  assert_eq(grid.selected_rows(), [0, 1])
  // ④ 普通 Down 折叠回单行
  press("Down", false, false, false)
  assert_eq(grid.selected(), 2)
  assert_eq(grid.selected_rows(), [2])
  // ⑤ Shift+End 从 2 扩到 4
  press("End", false, true, false)
  assert_eq(grid.selected(), 4)
  assert_eq(grid.selected_rows(), [2, 3, 4])
  // ⑥ ⌘A 全选（头回第一行），Ctrl+A 走同一条
  press("a", false, false, true)
  assert_eq(grid.selection_count(), 5)
  assert_eq(grid.selected(), 0)
  assert_eq(grid.selected_rows(), [0, 1, 2, 3, 4])
  press("a", true, false, false)
  assert_eq(grid.selection_count(), 5)
  // ⑦ ⌘C 复制**整段**：按显示顺序一行接一行
  press("c", false, false, true)
  assert_eq(
    @moonui.Backend::clipboard_text(b),
    Some("a\t1\nb\t2\nc\t3\nd\t4\ne\t5\n"),
  )
  // ⑧ toggle：移掉 b 后剩 4 行，头（0）不动；加回来头落到它身上；越界无效
  grid.toggle_row(1)
  assert_eq(grid.selection_count(), 4)
  assert_true(!grid.is_selected(1))
  assert_eq(grid.selected(), 0)
  grid.toggle_row(1)
  assert_eq(grid.selection_count(), 5)
  assert_eq(grid.selected(), 1)
  grid.toggle_row(99)
  assert_eq(grid.selection_count(), 5)
  // ⑨ select_rows 去重去越界；复制按**显示顺序**（a 先于 e，不是数组顺序）
  grid.select_rows([4, 0, 0, 99])
  assert_eq(grid.selected_rows(), [0, 4])
  assert_eq(grid.selected(), 0)
  assert_true(grid.copy_selected())
  assert_eq(@moonui.Backend::clipboard_text(b), Some("a\t1\ne\t5\n"))
  // ⑩ move_row 之后集合里的行号跟着重编：a 挪到末尾 → {3, 4}
  grid.move_row(0, 4)
  assert_eq(grid.selected_rows(), [3, 4])
  assert_eq(grid.selected(), 4)
  assert_true(grid.is_selected(3))
  assert_eq(grid.cell(3, 0).unwrap_or("?"), "e")
  assert_eq(grid.cell(4, 0).unwrap_or("?"), "a")
  // ⑪ 排序升序（a,b,c,d,e）后集合按显示顺序给出；高亮条数与集合行数一致
  grid.sort_by_column(0)
  grid.select_row(4)
  grid.toggle_row(0)
  assert_eq(grid.selected_rows(), [4, 0])
  // 键盘那几段把窗口滚到底了；先回到顶，高亮条数才数得准
  grid.scroll_to_row(4)
  let _ = app.step()
  assert_eq(selected_bands(), 2)
  assert_true(grid.copy_selected())
  assert_eq(@moonui.Backend::clipboard_text(b), Some("a\t1\nb\t2\n"))
  // ⑫ 换数据少了行：只剔掉越界项，头掉了落到最后一个留下的行
  grid.set_rows([["a", "1"], ["b", "2"]])
  assert_eq(grid.selection_count(), 1)
  assert_eq(grid.selected(), 0)
  assert_true(grid.is_selected(0))
  assert_true(!grid.is_selected(4))
  // ⑬ 越界 select_row / 空 select_rows 都等于清空
  grid.select_row(5)
  assert_eq(grid.selection_count(), 0)
  assert_eq(grid.selected(), -1)
  grid.select_rows([0])
  assert_eq(grid.selection_count(), 1)
  grid.select_rows([])
  assert_eq(grid.selection_count(), 0)
  assert_eq(grid.selected(), -1)
  b.terminate()
}
