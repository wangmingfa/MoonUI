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

///|
/// 日期模型（`T341`）：`@语法` 录入到期日，"今天"视图按到期日过滤、
/// 过期未完成高亮。mock 注入 `local_date` 让判定可复现。
test "TodoApp：@语法到期日 + 今天视图过滤 + 过期判定（T341）" {
  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  @moonui.Assets::clear_for_test()
  // 注入"今天"：2026-11-22
  b.set_local_date(Some("2026-11-22"))
  let app = @moonui.App(b)
  let t = TodoApp::build(app)
  assert_eq(t.today, "2026-11-22")
  // @今天 → due = 今天；@明天 → due = 明天（跨日历）；@2026-11-20 → 过期
  t.input_sig.set("买牛奶 @今天")
  t.add_from_input()
  t.input_sig.set("交房租 @明天")
  t.add_from_input()
  t.input_sig.set("还书 @2026-11-20")
  t.add_from_input()
  let items = t.items_sig.get()
  assert_eq(items.length(), 3)
  assert_eq(items[0].due, Some("2026-11-22"))
  assert_eq(items[1].due, Some("2026-11-23"))
  assert_eq(items[2].due, Some("2026-11-20"))
  // 文本清掉标记，剩余是正文
  assert_eq(items[0].text, "买牛奶")
  assert_eq(items[2].text, "还书")
  // 未完成视图（`T341` 新语义）：今天到期 + 过期 = 2 条；「交房租 @明天」
  // 到期日在明天，不属于"今天"。
  assert_eq(t.visible_sig.get().length(), 2)
  // 已完成视图：空
  t.set_view(Done)
  assert_eq(t.visible_sig.get().length(), 0)
  // 全部视图：3
  t.set_view(All)
  assert_eq(t.visible_sig.get().length(), 3)
  // 勾选过期条目（id 2）→ 已完成视图剩 1
  t.toggle(2)
  t.set_view(Done)
  assert_eq(t.visible_sig.get().length(), 1)
  // 回到今天视图：剩「买牛奶」
  t.set_view(Today)
  assert_eq(t.visible_sig.get().length(), 1)
  // 删除：事实源 2
  t.remove(0)
  assert_eq(t.items_sig.get().length(), 2)
  @moonui.Assets::clear_for_test()
  @moonui.Backend::terminate(b)
}

///|
/// 到期日排序（`T341` 延伸）：有日期在前按升序、无日期靠后；同序保持
/// 插入序。sort_by 的比较器对同键返回 0，插入序由数组遍历的稳定追加保证。
test "TodoApp：全部视图按到期日排序、无日期靠后（T341）" {
  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  @moonui.Assets::clear_for_test()
  b.set_local_date(Some("2026-11-22"))
  let app = @moonui.App(b)
  let t = TodoApp::build(app)
  // 乱序录入：无日期、后天、过期、今天
  t.input_sig.set("无日期条目")
  t.add_from_input()
  t.input_sig.set("后天交 @2026-11-24")
  t.add_from_input()
  t.input_sig.set("已过期 @2026-11-20")
  t.add_from_input()
  t.input_sig.set("今天到期 @2026-11-22")
  t.add_from_input()
  t.set_view(All)
  let vis = t.visible_sig.get()
  assert_eq(vis.length(), 4)
  // 有日期在前按升序，无日期靠后
  assert_eq(vis[0].text, "已过期")
  assert_eq(vis[1].text, "今天到期")
  assert_eq(vis[2].text, "后天交")
  assert_eq(vis[3].text, "无日期条目")
  assert_eq(vis[3].due, None)
  @moonui.Assets::clear_for_test()
  @moonui.Backend::terminate(b)
}
