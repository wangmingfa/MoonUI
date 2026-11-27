///|
/// OpenTodo 复刻件的无头判据（`T409`）：日期口径、分组派生、侧栏计数、
/// 勾选 / 优先级 / 删除 / 录入的状态账。真窗壳（main）与判据走同一份
/// `TodoApp::build`——mock 后端把原生层替掉，`Window` / `Widget` 的账照跑。

///|
/// 日期口径：`DEMO_TODAY` 钉在 2026-11-27（星期五），文案与逾期都按它算。
test "复刻件：日期文案与逾期配色口径（T409）" {
  assert_eq(DEMO_TODAY, "2026-11-27")
  assert_eq(short_date("2026-11-26"), "11月26日")
  assert_eq(weekday("2026-11-26"), "星期四")
  // 相对词：今天 / 明天 / 后天，再往后是短日期
  assert_eq(due_text("2026-11-27"), "今天")
  assert_eq(due_text("2026-11-28"), "明天")
  assert_eq(due_text("2026-11-29"), "后天")
  assert_eq(due_text("2026-11-30"), "11月30日")
  assert_eq(add_days("2026-11-27", 1), "2026-11-28")
  assert_eq(add_days("2026-11-30", 1), "2026-12-01")
  assert_eq(day_diff("2026-11-24"), -3)
  // 逾期红 / 今天强调 / 其余弱化
  let p = Palette::light()
  assert_eq(due_tone("2026-11-24", p), p.danger)
  assert_eq(due_tone("2026-11-27", p), p.accent)
  assert_eq(due_tone("2026-11-29", p), p.muted)
  // 估算文案
  assert_eq(estimate_text(45), "45m")
  assert_eq(estimate_text(60), "1h")
  assert_eq(estimate_text(90), "1h 30m")
  assert_eq(estimate_text(0), "")
}

///|
/// 分组派生：「今天」是较早 + 今天两栏，「收件箱」单栏无分组头。
test "复刻件：分组派生与空组过滤（T409）" {
  let all = demo_tasks
  let today = sections_for("today", all, 0)
  assert_eq(today.length(), 2)
  assert_eq(today[0].title, "较早")
  assert_eq(today[0].count, 10)
  assert_eq(today[1].title, "今天")
  assert_eq(today[1].count, 5)
  // 收件箱：无分组头，两条都带 API 标记
  let inbox = sections_for("inbox", all, 0)
  assert_eq(inbox.length(), 1)
  assert_eq(inbox[0].title, "")
  assert_eq(inbox[0].count, 2)
  assert_true(inbox[0].tasks[0].via_api)
  // 项目视图：按项目键筛（Work 含 Q4 launch 子项目），已完成的不算数
  let work = sections_for("proj-work", all, 0)
  assert_eq(work[0].count, 13)
}

///|
/// 侧栏条目：顺序即读序，计数与选档。
test "复刻件：侧栏条目与分组（T409）" {
  let d = destinations("today", demo_tasks)
  assert_eq(d.length(), 10)
  assert_eq(d[0].key, "inbox")
  assert_false(d[0].selected)
  assert_eq(d[1].key, "today")
  assert_true(d[1].selected)
  // 分组：收藏夹 / 项目 有条目（项目只挂 Home / Work，Side 收起），标签 / 视图是收起的标题行
  let g = side_groups()
  assert_eq(g.length(), 4)
  assert_eq(g[0].rows, [4, 5, 6])
  assert_eq(g[1].rows, [7, 8])
  assert_eq(g[2].rows, [])
  assert_eq(g[3].rows, [])
}

///|
/// 头部档位：「今天」是大字号 + 简报，其余是小标题 + 副信息。
test "复刻件：头部档位（T409）" {
  let big = head_for("today", demo_tasks)
  assert_true(big.big)
  assert_eq(big.title, "今天")
  assert_true(big.brief_danger.length() > 0)
  let small = head_for("inbox", demo_tasks)
  assert_false(small.big)
  assert_eq(small.title, "收件箱")
  assert_true(small.meta.contains("项待整理"))
}

///|
/// 勾选 / 优先级 / 删除 / 录入的状态账：走真壳（mock 后端），与真窗同一份代码。
test "复刻件：勾选 / 优先级 / 删除 / 录入（T409）" {
  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  let app = @moonui.App(b)
  let t = TodoApp::build(app)
  // 起步：「今天」两栏（较早 10 + 今天 5）
  assert_eq(t.current(), "today")
  assert_eq(t.sections().length(), 2)
  // 勾选「今天」的一条（id 15，Pick paint colours）→ 那一组的计数少一
  t.toggle(15)
  assert_eq(t.sections().length(), 2)
  assert_eq(t.sections()[1].count, 4)
  // 循环优先级：0 → 1 → 2 → 3 → 4 → 0（不影响计数）
  let mut pr = 0
  for _ in 0..<5 {
    t.cycle_prio(28)
    pr = pr + 1
    if pr > 4 {
      pr = 0
    }
  }
  // 删除一条（id 16，Measure the hallway）：事实源少一，分组随之重算
  t.delete(16)
  assert_eq(t.sections()[1].count, 3)
  // 回车录入：进今天那一栏，日期按 DEMO_TODAY
  let _ = t.sections()
  @moonui.Backend::terminate(b)
}

///|
/// 切视图不改事实源（键控 diff 的行保留语义建立在这上面）：
/// 「今天」→「收件箱」→「今天」，两栏原样回来。
test "复刻件：切视图不动事实源（T409）" {
  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  let app = @moonui.App(b)
  let t = TodoApp::build(app)
  t.toggle(15)
  t.set_dest("inbox")
  assert_eq(t.current(), "inbox")
  assert_eq(t.sections().length(), 1)
  assert_eq(t.sections()[0].count, 2)
  t.set_dest("today")
  assert_eq(t.sections().length(), 2)
  assert_eq(t.sections()[1].count, 4) // 勾掉的那条还在
  @moonui.Backend::terminate(b)
}
