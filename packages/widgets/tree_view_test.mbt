///|
/// `TreeView` 的判据（`T102` 第二刀）。
///
/// 与 `data_grid_test.mbt` 同一层：测的是**配方**——摆进布局之后后端收到的那份
/// `DrawList` 里到底是什么命令、按什么参数。坐标全部手算写死，不调被测代码里的
/// 任何计算函数（`tree_first_row` 之类包外也看不见）。
///
/// 度量口径（`MockBackend::measure_text`）：宽 = 字符数 × 8 × 字号/12，
/// 粗体再 × 1.25；高 = 16 × 字号/12。所以 12px 正文每字符 8 宽、16 高。
///
/// 这一刀的四件账：缩进与箭头的位置、窗口只画看得见的行、参考线按窗口内最大
/// 深度铺、命中盒只有箭头那一格。

///|
/// 一棵有形状的树：root → A（含 a1/a2，带副文案）/ B（含 b1）。
fn tree_fixture() -> @widgets.TreeNode {
  @widgets.TreeNode::new(1, "root", children=[
    @widgets.TreeNode::new(
      2,
      "A",
      children=[
        @widgets.TreeNode::new(4, "a1"),
        @widgets.TreeNode::new(5, "a2"),
      ],
      detail="3 项",
    ),
    @widgets.TreeNode::new(3, "B", children=[@widgets.TreeNode::new(6, "b1")]),
  ])
}

///|
test "TreeView：缩进、箭头、副文案各就各位（T102）" {
  let b = mock()
  let tree = @widgets.TreeView::new(
    b,
    tree_fixture(),
    width=200.0,
    height=100.0,
    show_root=true,
    expanded=[1],
  )
  let wg = tree.widget()
  assert_eq(wg.kind(), @moonui.Custom)
  assert_eq(wg.intrinsic_size(), @moonui.LogicalSize(200.0, 100.0))
  // 只有 root 是展开的：3 行可见，A / B 都收着
  assert_eq(tree.visible_count(), 3)
  assert_eq(tree.visible_id(0), Some(1))
  assert_eq(tree.visible_depth(0), Some(0))
  assert_eq(tree.visible_depth(1), Some(1))
  assert_eq(tree.visible_id(9), None)
  assert_eq(tree.row_of(3), Some(2))
  assert_eq(tree.row_of(6), None)
  let dl = place(b, wg)
  // 1 底 + 1 参考线（窗口内最大深度 1）+ 行 0（箭头 + 文案）
  // + 行 1（箭头 + 文案 + 副文案）+ 行 2（箭头 + 文案） = 9
  assert_eq(dl.len(), 9)
  let cmds = dl.commands()
  match cmds[0] {
    @moonui.FillRect(x, y, fw, fh, _, rgb, alpha) => {
      assert_true(near(x, 0.0) && near(y, 0.0))
      assert_true(near(fw, 200.0) && near(fh, 100.0))
      assert_eq(rgb, 0xFFFFFF)
      assert_eq(alpha, 255)
    }
    _ => fail("第一条不是整块底色")
  }
  // 参考线：第 0 层缩进槽的中线 = 8 + 14 / 2 = 15，整条通到底
  match cmds[1] {
    @moonui.Line(x0, y0, x1, y1, width, rgb) => {
      assert_true(near(x0, 15.0) && near(x1, 15.0))
      assert_true(near(y0, 0.0) && near(y1, 100.0))
      assert_true(near(width, 1.0))
      assert_eq(rgb, 0xE2E8F0)
    }
    _ => fail("第二条不是缩进参考线")
  }
  // 行 0（depth 0）：箭头槽 [8, 22]，"▾" 8 宽 → x = 8 + 3 = 11；
  // 文案 x = 8 + 14 = 22；竖直居中 (22 - 16) / 2 = 3
  match cmds[2] {
    @moonui.Text(text, x, y, _, bold, rgb) => {
      assert_eq(text, "▾")
      assert_true(near(x, 11.0) && near(y, 3.0))
      assert_false(bold)
      assert_eq(rgb, 0x718096)
    }
    _ => fail("第三条不是展开箭头")
  }
  match cmds[3] {
    @moonui.Text(text, x, y, _, bold, rgb) => {
      assert_eq(text, "root")
      assert_true(near(x, 22.0) && near(y, 3.0))
      assert_false(bold)
      assert_eq(rgb, 0x1A202C)
    }
    _ => fail("第四条不是根文案")
  }
  // 行 1（depth 1，y = 22）：槽 [22, 36] → 箭头 x = 25，文案 x = 36
  match cmds[4] {
    @moonui.Text(text, x, y, _, _, _) => {
      assert_eq(text, "▸")
      assert_true(near(x, 25.0) && near(y, 25.0))
    }
    _ => fail("第五条不是收起箭头")
  }
  match cmds[5] {
    @moonui.Text(text, x, y, _, _, _) => {
      assert_eq(text, "A")
      assert_true(near(x, 36.0) && near(y, 25.0))
    }
    _ => fail("第六条不是 A 的文案")
  }
  // 副文案右对齐：3 字符 × 8 = 24，贴右内边距 → x = 200 - 8 - 24 = 168
  match cmds[6] {
    @moonui.Text(text, x, y, _, _, rgb) => {
      assert_eq(text, "3 项")
      assert_true(near(x, 168.0) && near(y, 25.0))
      assert_eq(rgb, 0x718096)
    }
    _ => fail("第七条不是右对齐的副文案")
  }
  match cmds[8] {
    @moonui.Text(text, x, y, _, _, _) => {
      assert_eq(text, "B")
      assert_true(near(x, 36.0) && near(y, 47.0))
    }
    _ => fail("第九条不是 B 的文案")
  }
  // 展开 A：多出 a1/a2 两行（depth 2），窗口内最大深度变成 2 → 两条参考线
  tree.expand(2)
  assert_eq(tree.is_expanded(2), true)
  assert_eq(tree.visible_count(), 5)
  assert_eq(tree.visible_id(2), Some(4))
  assert_eq(tree.visible_depth(2), Some(2))
  let open = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  // 1 底 + 2 参考线 + root（2）+ A（箭头 + 文案 + 副文案 3）
  // + a1（1）+ a2（1）+ B（2） = 12
  assert_eq(open.len(), 12)
  let oc = open.commands()
  match oc[2] {
    @moonui.Line(x0, _, x1, _, _, _) =>
      assert_true(near(x0, 29.0) && near(x1, 29.0))
    _ => fail("第三条不是第二层参考线")
  }
  // a1 是叶子（没有箭头），x = 8 + 2 × 14 + 14 = 50，y = 44 + 3 = 47；
  // A 多一条副文案，所以 a1 落在第 8 条（编号从 0 起）
  match oc[8] {
    @moonui.Text(text, x, y, _, _, _) => {
      assert_eq(text, "a1")
      assert_true(near(x, 50.0) && near(y, 47.0))
    }
    _ => fail("第八条不是 a1 的文案")
  }
  b.terminate()
}

///|
test "TreeView：偏移推进虚拟窗口，滚到底不空屏（T102）" {
  let b = mock()
  let kids : Array[@widgets.TreeNode] = []
  for i in 0..<10 {
    kids.push(@widgets.TreeNode::new(10 + i, "c\{i}"))
  }
  let root = @widgets.TreeNode::new(1, "root", children=kids)
  // 根不显示：10 个叶子从 depth 0 开始排，全是没有箭头的简单行
  let tree = @widgets.TreeView::new(b, root, width=100.0, height=100.0)
  assert_eq(tree.visible_count(), 10)
  assert_eq(tree.row_height(), 22.0)
  let wg = tree.widget()
  let dl = place(b, wg)
  // 22 一行、100 高 → 看得到 5 行（第 6 行顶边 110 已经出去了）；
  // 全是叶子、没有深度 → 没有参考线。1 底 + 5 文案
  assert_eq(dl.len(), 6)
  match dl.commands()[1] {
    @moonui.Text(text, x, y, _, _, _) => {
      assert_eq(text, "c0")
      assert_true(near(x, 22.0) && near(y, 3.0))
    }
    _ => fail("第二条不是第一行")
  }
  // 偏移 44 = 正好滚过两行：窗口从 c2 起
  tree.set_offset(44.0)
  assert_eq(tree.offset(), 44.0)
  let mid = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  assert_eq(mid.len(), 6)
  match mid.commands()[1] {
    @moonui.Text(text, x, y, _, _, _) => {
      assert_eq(text, "c2")
      assert_true(near(x, 22.0) && near(y, 3.0))
    }
    _ => fail("滚动之后第二条不是窗口第一行")
  }
  // 行号换算：正文第一像素就是 c2 那一行的顶边
  assert_eq(tree.row_at(0.0), Some(2))
  assert_eq(tree.row_at(21.0), Some(2))
  assert_eq(tree.row_at(22.0), Some(3))
  assert_eq(tree.row_at(500.0), None)
  // 负偏移夹到 0；越尾夹到"最后一行贴底" = 220 - 100 = 120
  tree.set_offset(-5.0)
  assert_eq(tree.offset(), 0.0)
  tree.set_offset(1000.0)
  assert_eq(tree.offset(), 120.0)
  // 偏移 120 时第一行（c5）只露了下半截，y = 0 落在它身上
  assert_eq(tree.row_at(0.0), Some(5))
  let tail = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  assert_eq(tail.len(), 6)
  match tail.commands()[5] {
    @moonui.Text(text, _, y, _, _, _) => {
      assert_eq(text, "c9")
      assert_true(near(y, 81.0))
    }
    _ => fail("滚到底最后一条不是 c9")
  }
  // scroll_to_row 按行高换算，顺带证明它走的是同一条夹法
  tree.scroll_to_row(3)
  assert_eq(tree.offset(), 66.0)
  b.terminate()
}

///|
test "TreeView：参考线按窗口内最大深度铺，选中压在参考线之下（T102）" {
  let b = mock()
  let root = @widgets.TreeNode::new(1, "root", children=[
    @widgets.TreeNode::new(2, "A", children=[
      @widgets.TreeNode::new(3, "B", children=[@widgets.TreeNode::new(4, "C")]),
    ]),
  ])
  let tree = @widgets.TreeView::new(b, root, width=200.0, height=100.0, expanded=[
    2, 3,
  ])
  let wg = tree.widget()
  let _ = place(b, wg)
  // A / B / C 三层：depth 2 存在 → 第 0、1 层各一条参考线
  assert_eq(tree.visible_count(), 3)
  tree.select_id(3)
  assert_eq(tree.selected_id(), 3)
  let dl = match b.drawn(wg.handle().unwrap()) {
    Some(dl) => dl
    None => abort("没画过")
  }
  // 1 底 + 1 选中底 + 2 参考线 + A（2）+ B（2）+ C（1）= 9
  assert_eq(dl.len(), 9)
  let cmds = dl.commands()
  // 选中的是 B（第 1 行）：底色 y = 22、整行宽
  match cmds[1] {
    @moonui.FillRect(x, y, fw, fh, _, rgb, _) => {
      assert_true(near(x, 0.0) && near(y, 22.0))
      assert_true(near(fw, 200.0) && near(fh, 22.0))
      assert_eq(rgb, 0xEBF4FF)
    }
    _ => fail("第二条不是选中行底色")
  }
  // 参考线排在选中底色之后：线压在底上，字压在线之上（顺序就是层次）
  match cmds[2] {
    @moonui.Line(_, _, _, _, _, rgb) => assert_eq(rgb, 0xE2E8F0)
    _ => fail("第三条不是参考线")
  }
  match cmds[4] {
    @moonui.Text(text, _, _, _, _, _) => assert_eq(text, "▾")
    _ => fail("第五条不是 A 的箭头")
  }
  // C 在 depth 2：没有箭头，文案 x = 8 + 2 × 14 + 14 = 50
  match cmds[8] {
    @moonui.Text(text, x, _, _, _, _) => {
      assert_eq(text, "C")
      assert_true(near(x, 50.0))
    }
    _ => fail("最后一条不是 C 的文案")
  }
  // 关掉参考线：同形状的树只少那两条线
  let b2 = mock()
  let bare = @widgets.TreeView::new(
    b2,
    root,
    width=200.0,
    height=100.0,
    expanded=[2, 3],
    guides=false,
  )
  let bdl = place(b2, bare.widget())
  // 1 底 + A（2）+ B（2）+ C（1）
  assert_eq(bdl.len(), 6)
  for c in bdl.commands() {
    match c {
      @moonui.Line(_, _, _, _, _, _) => fail("关掉参考线之后还有 Line")
      _ => ()
    }
  }
  b.terminate()
  b2.terminate()
}

///|
test "TreeView：只有箭头那一格能折叠，叶子点不动（T102）" {
  let b = mock()
  let tree = @widgets.TreeView::new(
    b,
    tree_fixture(),
    width=200.0,
    height=100.0,
    show_root=true,
    expanded=[1, 2],
  )
  let wg = tree.widget()
  let _ = place(b, wg)
  // 展开到 5 行：root / A / a1 / a2 / B
  assert_eq(tree.visible_count(), 5)
  // 点 A 的箭头：depth 1 → 槽 [22, 36]，y 落在 A 那一行（22..44）
  assert_eq(tree.toggle_at(25.0, 30.0), Some(2))
  assert_eq(tree.is_expanded(2), false)
  assert_eq(tree.visible_count(), 3)
  // 再点一下展开回来
  assert_eq(tree.toggle_at(25.0, 30.0), Some(2))
  assert_eq(tree.visible_count(), 5)
  // 点同一行的文字区（x = 100）：不折叠，也不吃这个事件
  assert_eq(tree.toggle_at(100.0, 30.0), None)
  assert_eq(tree.visible_count(), 5)
  // 叶子点不动：a1 在 depth 2（第 2 行，y 44..66），它的槽是 [36, 50]
  assert_eq(tree.toggle_at(40.0, 50.0), None)
  // 点空白 / 越界
  assert_eq(tree.toggle_at(25.0, 200.0), None)
  // 收起 root：整棵只剩它自己，子节点全部消失
  assert_eq(tree.toggle_at(15.0, 5.0), Some(1))
  assert_eq(tree.visible_count(), 1)
  assert_eq(tree.visible_id(0), Some(1))
  // 全部收起后再全展开：可见行 = 6 个节点
  tree.expand_all()
  assert_eq(tree.visible_count(), 6)
  assert_eq(tree.expanded_ids(), [1, 2, 3])
  tree.collapse_all()
  assert_eq(tree.visible_count(), 1)
  assert_eq(tree.expanded_ids(), [])
  b.terminate()
}

///|
test "TreeView：副文案最多占 45%，空树文案居中，换树保住展开集（T102）" {
  let b = mock()
  // 宽度 120：标签起点 22、右内边距 8 → 标签区 90 宽，副文案最多 40.5
  let root = @widgets.TreeNode::new(1, "root", children=[
    @widgets.TreeNode::new(2, "item", detail="abcdefghij"),
  ])
  let tree = @widgets.TreeView::new(b, root, width=120.0, height=100.0)
  let wg = tree.widget()
  let dl = place(b, wg)
  let cmds = dl.commands()
  // 标签 "item" 32 宽 ≤ 41.5：直接画；副文案 80 宽 > 40.5：省略 + 夹住
  // 1 底 + 1 标签 + Save / ClipRect / Text / Restore = 6
  assert_eq(dl.len(), 6)
  match cmds[1] {
    @moonui.Text(text, x, y, _, _, _) => {
      assert_eq(text, "item")
      assert_true(near(x, 22.0) && near(y, 3.0))
    }
    _ => fail("第二条不是标签")
  }
  match cmds[2] {
    @moonui.Save => ()
    _ => fail("溢出的副文案没有先压栈")
  }
  match cmds[3] {
    @moonui.ClipRect(x, y, cw, ch) => {
      assert_true(near(x, 71.5) && near(y, 0.0))
      assert_true(near(cw, 40.5) && near(ch, 22.0))
    }
    _ => fail("副文案没有夹在自己的宽度里")
  }
  // 40.5 宽放得下 4 个字符 + 省略号（5 × 8 = 40），右端贴 112
  match cmds[4] {
    @moonui.Text(text, x, y, _, _, rgb) => {
      assert_eq(text, "abcd…")
      assert_true(near(x, 72.0) && near(y, 3.0))
      assert_eq(rgb, 0x718096)
    }
    _ => fail("副文案没有省略")
  }
  match cmds[5] {
    @moonui.Restore => ()
    _ => fail("副文案没有出栈")
  }
  // 空树：根不显示、没有子节点 → 只剩底色 + 居中文案
  let b2 = mock()
  let empty = @widgets.TreeView::new(
    b2,
    @widgets.TreeNode::new(1, "root"),
    width=200.0,
    height=100.0,
    empty_text="空",
  )
  let edl = place(b2, empty.widget())
  assert_eq(empty.visible_count(), 0)
  assert_eq(edl.len(), 2)
  // "空" 1 字符 = 8 宽 → x = (200 - 8) / 2 = 96；y = (100 - 16) / 2 = 42
  match edl.commands()[1] {
    @moonui.Text(text, x, y, _, bold, _) => {
      assert_eq(text, "空")
      assert_true(near(x, 96.0) && near(y, 42.0))
      assert_false(bold)
    }
    _ => fail("空树没有居中文案")
  }
  // 换树：展开集保留（同一个 id 还是同一个节点）
  tree.expand(2)
  assert_eq(tree.is_expanded(2), true)
  let swapped = @widgets.TreeNode::new(1, "root", children=[
    @widgets.TreeNode::new(2, "item", children=[@widgets.TreeNode::new(3, "x")]),
  ])
  tree.set_root(swapped)
  assert_eq(tree.is_expanded(2), true)
  assert_eq(tree.visible_count(), 2)
  assert_eq(tree.visible_id(1), Some(3))
  // 换成没有 id 2 的树：展开集里那个 id 不再被问到，行数只剩根的子节点
  tree.set_root(
    @widgets.TreeNode::new(1, "root", children=[@widgets.TreeNode::new(9, "z")]),
  )
  assert_eq(tree.visible_count(), 1)
  assert_eq(tree.visible_id(0), Some(9))
  assert_eq(tree.row_of(2), None)
  // 行高为 0 直接拒绝：布局会算出无穷多行
  let err : String? = try {
    let _ = @widgets.TreeView::new(b, tree_fixture(), row_height=0.0)
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(err, Some("操作失败：树的行高必须为正"))
  b.terminate()
  b2.terminate()
}

///|
/// `T102` 第八刀：树的滚轮默认接线。
///
/// 数据集与"滚到底不空屏"那条同一套：10 行 × 22 = 220，控件 100 高 →
/// 上限 120。判据既要看见偏移变了，也要看见**窗口第一行换成谁**——只断言
/// offset 的话，增量单位写错（乘了行高）也照样能过。
test "TreeView：滚轮滚动走自己的偏移，滚到顶底夹住（T102 第八刀）" {
  let b = mock()
  let kids : Array[@widgets.TreeNode] = []
  for i in 0..<10 {
    kids.push(@widgets.TreeNode::new(10 + i, "c\{i}"))
  }
  let root = @widgets.TreeNode::new(1, "root", children=kids)
  let tree = @widgets.TreeView::new(b, root, width=100.0, height=100.0)
  let wg = tree.widget()
  let app = @moonui.App::new(b)
  let win = app.create_window(
    "MoonUI 树滚轮",
    @moonui.LogicalSize(200.0, 200.0),
  )
  win.set_content(@moonui.Widget::column(b, 0.0, [wg]))
  win.show()
  let _ = app.step()
  // 按内容取第一条正文文字：不写死命令下标，免得别处往清单前面插一条背景/
  // 参考线就把这条判据连带弄红（红得没意义）。
  fn first_text() -> String raise @moonui.UiError {
    let dl = match b.drawn(wg.handle().unwrap()) {
      Some(dl) => dl
      None => abort("没画过")
    }
    for cmd in dl.commands() {
      match cmd {
        @moonui.Text(text, _, _, _, _, _) => return text
        _ => ()
      }
    }
    raise @moonui.OperationFailed("正文没有文字")
  }
  assert_eq(tree.offset(), 0.0)
  assert_eq(first_text(), "c0")
  // 滚 22（一整行）→ c1；增量是逻辑像素，不乘行高
  b.push_event(@moonui.Scroll(wg.target(), @moonui.LogicalPoint(0.0, 22.0)))
  let _ = app.step()
  assert_eq(tree.offset(), 22.0)
  assert_eq(first_text(), "c1")
  // 再滚 22 → 44，第一行 c2
  b.push_event(@moonui.Scroll(wg.target(), @moonui.LogicalPoint(0.0, 22.0)))
  let _ = app.step()
  assert_eq(tree.offset(), 44.0)
  assert_eq(first_text(), "c2")
  // 滚到底：夹在 220 - 100 = 120，第一行 c5（上半截被切掉）
  b.push_event(@moonui.Scroll(wg.target(), @moonui.LogicalPoint(0.0, 1000.0)))
  let _ = app.step()
  assert_eq(tree.offset(), 120.0)
  assert_eq(first_text(), "c5")
  // 反向大幅滚：夹在顶 0，第一行回 c0
  b.push_event(@moonui.Scroll(wg.target(), @moonui.LogicalPoint(0.0, -1000.0)))
  let _ = app.step()
  assert_eq(tree.offset(), 0.0)
  assert_eq(first_text(), "c0")
  // 纯横向滚不动树的纵向偏移（树没有横向滚动，这一发等于没接）
  b.push_event(@moonui.Scroll(wg.target(), @moonui.LogicalPoint(30.0, 0.0)))
  let _ = app.step()
  assert_eq(tree.offset(), 0.0)
  assert_eq(first_text(), "c0")
  b.terminate()
}
