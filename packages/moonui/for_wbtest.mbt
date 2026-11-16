///|
/// `T286` 键控 `For` 判据（DESIGN §53.5 的 keyed `For`，Layer 3 第二步）。白盒：
/// 读 `Widget.children` 钉"行实例是否保留"。走 public API：`Widget::for_list` 建
/// 列表，`Signal[Array[K]]` 触发键控 diff。
///
/// 判据清单（T286 完成注）：
/// ① 增删行 → 未删行实例保留（句柄 id 不变、行内勾选状态保留）、新行建、
///    旧行句柄回收（`live()` 不涨）
/// ② 重排 → 行跟随 key（`children` 顺序变、实例不变）
/// ③ A/B：整树重建（`set_content` 新树 → 行实例全变、焦点对象丢失）vs
///    keyed diff（`items.set` → 匹配行实例保留、焦点对象不丢）——mock 无
///    "当前焦点"状态（只有 `focus_chain`/`focusable`），用"行实例保留 =
///    原生对象不重建 = 焦点不丢"论证
/// ④ 嵌 Column + `close_tree` 停 effect（信号再变不重建）

///|
fn for_app() -> (App[MockBackend], MockBackend) raise UiError {
  let b = MockBackend()
  Backend::init(b)
  (App(b), b)
}

///|
/// 行构建：键 = 元素自身（Int32 即 key），行 = 一个勾选框（有句柄，可断言
/// 实例保留与勾选状态）。
fn row_build(b : MockBackend, k : Int32) -> Widget[MockBackend] raise UiError {
  Widget::checkbox(b, k.to_string(), false)
}

///|
/// ① 增删行：`items.set([1,2,3])` → `[1,2,4]`。行 1/2 实例保留（句柄 id 不变、
/// 勾选状态保留）、行 3 句柄回收、行 4 新建；`live()` 净零（删一建一）。
test "for_list：增删行→未删行实例保留、句柄回收" {
  let (app, b) = for_app()
  let win = app.create_window("for", LogicalSize(300.0, 200.0))
  let items : Signal[Array[Int32]] = Signal([1, 2, 3])
  let list = Widget::for_list(
    b,
    items,
    fn(k) { k },
    fn(k) raise UiError { row_build(b, k) },
    6.0,
  )
  win.set_content(list)
  win.show()
  assert_eq(list.children.length(), 3)
  let id1 = list.children[0].handle().unwrap().id
  let id2 = list.children[1].handle().unwrap().id
  let id3 = list.children[2].handle().unwrap().id
  assert_true(id1 != id2)
  assert_true(id2 != id3)
  // 行内勾选状态：行 1 勾上，后续增删不重建它 → 状态保留
  list.children[0].set_checked(true)
  let live0 = b.live()
  items.set([1, 2, 4])
  assert_eq(list.children.length(), 3)
  assert_eq(list.children[0].handle().unwrap().id, id1)
  assert_eq(list.children[1].handle().unwrap().id, id2)
  assert_true(list.children[2].handle().unwrap().id != id3) // 行 4 是新 id
  assert_eq(list.children[0].checked(), true) // 行 1 勾选状态保留
  assert_eq(list.children[2].text(), "4") // 行 4 新建
  assert_eq(b.live(), live0) // 行 3 回收、行 4 建，净零
}

///|
/// ② 重排：`items.set([3,1,2])`。行实例全保留（三个 id 都在）、`children` 顺序
/// 跟随新键序列（行 3 在首位）。行不重建 → 勾选状态随行走。
test "for_list：重排→行跟随 key 而非下标" {
  let (app, b) = for_app()
  let win = app.create_window("for", LogicalSize(300.0, 200.0))
  let items : Signal[Array[Int32]] = Signal([1, 2, 3])
  let list = Widget::for_list(
    b,
    items,
    fn(k) { k },
    fn(k) raise UiError { row_build(b, k) },
    6.0,
  )
  win.set_content(list)
  win.show()
  let id1 = list.children[0].handle().unwrap().id
  let id2 = list.children[1].handle().unwrap().id
  let id3 = list.children[2].handle().unwrap().id
  list.children[1].set_checked(true) // 行 2 勾上
  items.set([3, 1, 2])
  // 顺序变：行 3、行 1、行 2；实例全保留（id 集合不变）
  assert_eq(list.children[0].text(), "3")
  assert_eq(list.children[1].text(), "1")
  assert_eq(list.children[2].text(), "2")
  assert_eq(list.children[0].handle().unwrap().id, id3)
  assert_eq(list.children[1].handle().unwrap().id, id1)
  assert_eq(list.children[2].handle().unwrap().id, id2)
  assert_eq(list.children[2].checked(), true) // 行 2 的状态跟 key 走
}

///|
/// ③ A/B：整树重建（`set_content` 新 For → 行实例全变）vs keyed diff
/// （`items.set` → 匹配行实例保留）。焦点对象 = 行实例：A 全变（焦点丢）、
/// B 保留（焦点不丢）——mock 无"当前焦点"状态，用实例保留论证。
test "for_list：A/B 整树重建（丢实例）vs keyed diff（保实例）" {
  let (app, b) = for_app()
  let win = app.create_window("for", LogicalSize(300.0, 200.0))
  let items : Signal[Array[Int32]] = Signal([1, 2, 3])
  let list = Widget::for_list(
    b,
    items,
    fn(k) { k },
    fn(k) raise UiError { row_build(b, k) },
    6.0,
  )
  win.set_content(list)
  win.show()
  let ids : Array[Int32] = []
  for i = 0; i < list.children.length(); i = i + 1 {
    ids.push(list.children[i].handle().unwrap().id)
  }
  // A：整树重建——set_content 换一棵新 For（模拟 Todo 旧 render_at 的
  // build_todo_tree + set_content 路径），行实例全变。
  let list2 = Widget::for_list(
    b,
    items,
    fn(k) { k },
    fn(k) raise UiError { row_build(b, k) },
    6.0,
  )
  win.set_content(list2)
  win.show()
  // 记录 list2 自己的初始行 id（list2 是新建 For，行是新的 4/5/6，不是旧 ids）
  let ids2 : Array[Int32] = []
  for i = 0; i < list2.children.length(); i = i + 1 {
    ids2.push(list2.children[i].handle().unwrap().id)
  }
  for i = 0; i < list2.children.length(); i = i + 1 {
    assert_true(list2.children[i].handle().unwrap().id != ids[i])
  }
  // B：keyed diff——同一列表 items.set 触发 diff，匹配行实例保留。
  items.set([3, 1, 2])
  assert_eq(list2.children[0].handle().unwrap().id, ids2[2])
  assert_eq(list2.children[1].handle().unwrap().id, ids2[0])
  assert_eq(list2.children[2].handle().unwrap().id, ids2[1])
}

///|
/// ④ 嵌 Column：For 是 Column 形态，嵌进父容器后 diff 照常；`close_tree` 停
/// effect，信号再变不重建、不碰已销毁节点。
test "for_list：嵌 Column + close_tree 停 effect" {
  let (app, b) = for_app()
  let win = app.create_window("for", LogicalSize(300.0, 200.0))
  let items : Signal[Array[Int32]] = Signal([1, 2])
  let list = Widget::for_list(
    b,
    items,
    fn(k) { k },
    fn(k) raise UiError { row_build(b, k) },
    6.0,
  )
  let col = Widget::column(b, 8.0, [Widget::label(b, "标题"), list])
  win.set_content(col)
  win.show()
  assert_eq(col.children.length(), 2)
  assert_eq(col.children[1].children.length(), 2)
  items.set([1, 2, 3])
  assert_eq(col.children[1].children.length(), 3)
  list.close_tree()
  assert_true(list.closed)
  assert_eq(list.children.length(), 0) // 子行随树关闭
  items.set([9]) // effect 已停：不重建、不 raise
  assert_true(list.closed)
}

///|
/// ⑤ `T287` window 链：`set_content` 之后才建的行，原生 view 真的补挂进窗口
/// （mock 的窗口 `z_order` 就是"挂上了没有"的账——不补挂时新行只在 Core 的
/// `children` 里、真窗上不可见）。
test "for_list：diff 新增行补挂进窗口（T287）" {
  let (app, b) = for_app()
  let win = app.create_window("for", LogicalSize(300.0, 200.0))
  let wh = win.handle()
  let items : Signal[Array[Int32]] = Signal([1, 2])
  let list = Widget::for_list(
    b,
    items,
    fn(k) { k },
    fn(k) raise UiError { row_build(b, k) },
    6.0,
  )
  win.set_content(list)
  win.show()
  // 初挂：两行都挂进窗口
  assert_eq(b.child_z_order(wh).length(), 2)
  // 加一行：新行是 set_content 之后才建的叶子，走 `attach_subtree` 补挂
  items.set([1, 2, 3])
  let order = b.child_z_order(wh)
  assert_eq(order.length(), 3)
  let row3 = list.children[2].handle().unwrap()
  let mut attached = false
  for h in order {
    if h == row3 {
      attached = true
    }
  }
  assert_true(attached) // 新行真的挂进窗口，而不只是进了 Core 的 children
  // 删一行：句柄回收时随 destroy 摘出窗口
  items.set([1, 3])
  assert_eq(b.child_z_order(wh).length(), 2)
}

///|
/// ⑥ `T287` 容器链：For 在 Scroll 里时，新行挂进**文档区**（Scroll 句柄），
/// 与 `set_content` 的 `collect_attach` 同一条认领规则（T74）。
test "for_list：Scroll 内的新行挂进文档区（T287）" {
  let (app, b) = for_app()
  let win = app.create_window("for", LogicalSize(300.0, 200.0))
  let items : Signal[Array[Int32]] = Signal([1])
  let list = Widget::for_list(
    b,
    items,
    fn(k) { k },
    fn(k) raise UiError { row_build(b, k) },
    6.0,
  )
  let sc = Widget::scroll(b, Axis::Vertical, list)
  win.set_content(sc)
  win.show()
  let sh = sc.handle().unwrap()
  // 初挂：行在文档区（容器认领规则）
  assert_eq(b.widget(list.children[0].handle().unwrap()).parent, Some(sh))
  items.set([1, 2])
  let row2 = list.children[1].handle().unwrap()
  // 新行的原生 view 也挂进 Scroll 的文档区，不是窗口
  assert_eq(b.widget(row2).parent, Some(sh))
}
