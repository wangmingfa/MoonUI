///|
/// `T288` 判据：人工换树（`DataAdminDemo::replace_pane`、Markdown preview 刷新
/// 的形状）统一走 `Widget::attach_subtree`。坐标：
/// - 旧手写 `view.collect_attach(None, ...)` 只把叶子挂**窗口**——view 若在
///   Scroll/Panel 里，叶子就跑到容器外面去了（位置/裁剪都不对）。
/// - `attach_subtree` 沿 `parent` 链取**最近的** Scroll/Panel 当容器，与
///   `reactive`/`For` 同一条路径。
///
/// 白盒：`attach_subtree` 是包内私有口，这条直接从包里调它。

///|
/// ① 嵌套形状：`Scroll > pane(Column) > 新 view`。换树后新叶子挂进 Scroll 的
/// 文档区（不是窗口），且父链被标脏（下轮 `flush_layout` 会给新叶子写帧）。
test "attach_subtree：人工换树补挂到最近的 Scroll（T288）" {
  let b = MockBackend()
  Backend::init(b)
  let app = App(b)
  let win = app.create_window("attach", LogicalSize(300.0, 200.0))
  let pane = Widget::column(b, 0.0, [])
  let sc = Widget::scroll(b, Axis::Vertical, pane)
  win.set_content(sc)
  win.show()
  let sh = sc.handle().unwrap()
  // 人工换树（replace_pane / compose_preview 的形状）：新 view 先链接 parent，
  // 再走统一的补挂口。
  let fresh = Widget::column(b, 2.0, [
    Widget::label(b, "a"),
    Widget::label(b, "b"),
  ])
  fresh.parent = Some(pane)
  fresh.attached = true
  pane.children = [fresh]
  fresh.attach_subtree()
  // 两个叶子都挂进 Scroll 的文档区（手写 `None` 会挂窗口）
  for leaf in fresh.children {
    assert_eq(b.widget(leaf.handle().unwrap()).parent, Some(sh))
  }
  // 父链标脏：新子树还没有帧，下轮布局要连它一起写
  assert_true(sc.needs_layout)
}

///|
/// ② 首挂形状：`pane` 已在窗口树下（`set_content` 时还没有子项），换进一个
/// Scroll——Scroll **自己**也得补挂进窗口。这是 `DataAdminDemo::demo` 首挂
/// 表格页修掉的既有缺口（旧代码直接 `pane.children = [view]`，整只 Scroll
/// 从没 attach 过，真窗上表格恒空白）。
test "attach_subtree：首挂换树把 Scroll 自己挂进窗口（T288）" {
  let b = MockBackend()
  Backend::init(b)
  let app = App(b)
  let win = app.create_window("attach", LogicalSize(300.0, 200.0))
  let pane = Widget::column(b, 0.0, [])
  let root = Widget::column(b, 0.0, [pane])
  win.set_content(root)
  win.show()
  let wh = win.handle()
  let list = Widget::scroll(b, Axis::Vertical, Widget::column(b, 0.0, []))
  list.parent = Some(pane)
  list.attached = true
  pane.children = [list]
  list.attach_subtree()
  let sh = list.handle().unwrap()
  let mut attached = false
  for h in b.child_z_order(wh) {
    if h == sh {
      attached = true
    }
  }
  assert_true(attached)
}
