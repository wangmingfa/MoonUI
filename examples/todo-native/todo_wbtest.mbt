///|
/// TodoApp 的 mock 无头判据（`T340`）：增删勾与视图过滤的状态派生。
/// 真窗壳（main）与判据走同一份 `TodoApp::build`。
test "TodoApp：增删勾与视图过滤（T340）" {
  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  let app = @moonui.App(b)
  let t = TodoApp::build(app)
  // 空态起步
  assert_eq(t.items_sig.get().length(), 0)
  assert_eq(t.visible_sig.get().length(), 0)
  // 空文案：无操作（不弹条、不建行）
  t.add_from_input()
  assert_eq(t.items_sig.get().length(), 0)
  // 连续录入两条
  t.input_sig.set("买牛奶")
  t.add_from_input()
  t.input_sig.set("交房租")
  t.add_from_input()
  assert_eq(t.items_sig.get().length(), 2)
  // 未完成视图（默认）：两条都可见
  assert_eq(t.visible_sig.get().length(), 2)
  // 勾选第一条（id 0）→ 未完成视图剩 1
  t.toggle(0)
  assert_eq(t.visible_sig.get().length(), 1)
  assert_eq(t.items_sig.get()[0].done, true)
  // 全部视图：2；已完成视图：1
  t.set_view(All)
  assert_eq(t.visible_sig.get().length(), 2)
  t.set_view(Done)
  assert_eq(t.visible_sig.get().length(), 1)
  // 删除已勾的（id 0）→ 全部视图只剩「交房租」
  t.remove(0)
  t.set_view(All)
  assert_eq(t.items_sig.get().length(), 1)
  assert_eq(t.items_sig.get()[0].text, "交房租")
  assert_eq(t.items_sig.get()[0].done, false)
  @moonui.Backend::terminate(b)
}

///|
/// 视图切换不改事实源（`T340`）：切到「已完成」再切回来，条目原样在——
/// 键控 diff 的行实例保留语义建立在事实源不被视图污染上。
test "TodoApp：切视图不动事实源（T340）" {
  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  let app = @moonui.App(b)
  let t = TodoApp::build(app)
  t.input_sig.set("第一条")
  t.add_from_input()
  t.input_sig.set("第二条")
  t.add_from_input()
  t.set_view(Done)
  assert_eq(t.visible_sig.get().length(), 0)
  t.set_view(Today)
  assert_eq(t.visible_sig.get().length(), 2)
  assert_eq(t.items_sig.get().length(), 2)
  assert_eq(t.items_sig.get()[0].text, "第一条")
  assert_eq(t.items_sig.get()[1].text, "第二条")
  @moonui.Backend::terminate(b)
}
