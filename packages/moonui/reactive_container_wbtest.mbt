///|
/// `T285` 响应式容器判据（DESIGN §53.5 的 Layer 3 占位）。白盒：能读
/// `Widget.children` 钉"子树真的被换掉"。走 public API：`Widget::reactive` 建
/// 节点，`Signal::set` 触发 effect 重建，断言新子树已就位、旧句柄已回收。
///
/// 判据清单（T285 完成注）：
/// ① `reactive` 依赖变 → 子树自动重建（`build` 重跑、新子树替换旧子树）
/// ② `reactive` 无 Signal 依赖 → 不重建（build 只跑一次）
/// ③ 嵌在 Column 里 → 依赖变重建子项，父容器原样
/// ④ `close_tree` → effect 停止，信号再变不重建

///|
fn reactive_app() -> (App[MockBackend], MockBackend) raise UiError {
  let b = MockBackend::new()
  Backend::init(b)
  (App::new(b), b)
}

///|
/// ① 依赖变 → 子树自动重建。`count.set` 后 effect 同步重跑 `build`，旧 label
/// 的句柄在 `close_tree` 里回收、新 label 的句柄由 `build` 建好——`live()` 不涨。
test "reactive：Signal 变→子树自动重建、句柄回收" {
  let (app, b) = reactive_app()
  let win = app.create_window("reactive", LogicalSize(200.0, 100.0))
  let count : Signal[Int32] = Signal::new(0)
  let content = Widget::reactive(app.backend(), fn() raise UiError {
    Widget::label(app.backend(), "Count: " + count.get().to_string())
  })
  win.set_content(content)
  win.show()
  // 构造期 effect 求值一次：子控件已建
  assert_eq(content.children.length(), 1)
  assert_eq(content.children[0].text(), "Count: 0")
  // 窗口 + 一个 label；Reactive 是纯布局节点，不占原生对象
  assert_eq(b.live(), 2)
  // 依赖变：effect 重跑 → 新子树替换旧子树
  count.set(1)
  assert_eq(content.children[0].text(), "Count: 1")
  assert_eq(b.live(), 2) // 旧 label 句柄已回收、新 label 句柄已建
  count.set(5)
  assert_eq(content.children[0].text(), "Count: 5")
  assert_eq(b.live(), 2)
}

///|
/// ② `build` 没读任何 Signal → effect 只跑一次，外界信号变不触发重建。
test "reactive：无 Signal 依赖→不重建" {
  let (app, _b) = reactive_app()
  let mut builds = 0
  let _content = Widget::reactive(app.backend(), fn() raise UiError {
    builds = builds + 1
    Widget::label(app.backend(), "static")
  })
  assert_eq(builds, 1) // 构造期求值一次
  let unrelated : Signal[Int32] = Signal::new(0)
  unrelated.set(1) // reactive 不依赖它
  assert_eq(builds, 1) // 没重建
}

///|
/// ③ 嵌在 Column 里：父容器原样，reactive 子项依赖变时只换自己的子树。
test "reactive：嵌在 Column 里，依赖变重建子项" {
  let (app, b) = reactive_app()
  let win = app.create_window("r", LogicalSize(300.0, 100.0))
  let count : Signal[Int32] = Signal::new(0)
  let reactive = Widget::reactive(app.backend(), fn() raise UiError {
    Widget::label(app.backend(), "n=" + count.get().to_string())
  })
  let column = Widget::column(app.backend(), 8.0, [
    Widget::label(app.backend(), "标题"),
    reactive,
  ])
  win.set_content(column)
  win.show()
  // column 子项 [标题, reactive]；reactive 的子项 [label]
  assert_eq(column.children.length(), 2)
  assert_eq(column.children[1].children[0].text(), "n=0")
  count.set(2)
  assert_eq(column.children[1].children[0].text(), "n=2")
  // 窗口 + 标题 + n-label；Reactive/Column 不占原生对象
  assert_eq(b.live(), 3)
}

///|
/// ④ `close_tree` 后 effect 已 stop，信号再变不重建、不碰已销毁节点。
test "reactive：close_tree 后 Signal 变不再重建" {
  let (app, _b) = reactive_app()
  let count : Signal[Int32] = Signal::new(0)
  let content = Widget::reactive(app.backend(), fn() raise UiError {
    Widget::label(app.backend(), "x")
  })
  assert_true(!content.closed)
  content.close_tree()
  assert_true(content.closed)
  assert_eq(content.children.length(), 0) // 子控件随树关闭
  count.set(1) // effect 已 stop：不重建、不 raise
  assert_true(content.closed)
}

///|
/// ⑤ `T287` window 链：依赖变换出来的新 label 的原生 view 补挂进窗口
/// （旧 label 随 `close_tree` 的 `destroy_widget` 摘掉）。T285 占位期只
/// `mark_needs_layout`，真窗上新子树不可见——这条钉住补挂真的发生了。
test "reactive：换子树后新叶子补挂进窗口（T287）" {
  let (app, b) = reactive_app()
  let win = app.create_window("reactive", LogicalSize(200.0, 100.0))
  let wh = win.handle()
  let count : Signal[Int32] = Signal::new(0)
  let content = Widget::reactive(app.backend(), fn() raise UiError {
    Widget::label(app.backend(), "Count: " + count.get().to_string())
  })
  win.set_content(content)
  win.show()
  assert_eq(b.child_z_order(wh).length(), 1) // 初挂：一个 label
  count.set(1)
  // 换完：窗口里仍是一个 label（旧的摘掉、新的补挂），且正是新子树那个
  let order = b.child_z_order(wh)
  assert_eq(order.length(), 1)
  assert_eq(order[0], content.children[0].handle().unwrap())
}
