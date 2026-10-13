// Blackbox tests run against the package's public API. Use `@moonui` to import.
// Prefer high-level behaviors over implementation details.
// Run `moon test` to execute and `moon test --update` to refresh snapshots.

///|
/// 画册的目录不许悄悄变：每加一个组件页，`section_names` 的长度与
/// `gallery_code` / `build_demo` 的分支要一起动——这条断言就是提醒。
test "gallery：目录二十六页，页页有代码与真控件" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let g = @moonui.Gallery::demo(app)
  assert_eq(@moonui.Gallery::section_names().length(), 26)
  // 每页的标题与目录名对得上，内容树非空。
  for i = 0; i < 26; i = i + 1 {
    g.select(i)
    assert_eq(g.current(), i)
    let content = g.window().content()
    assert_true(content is Some(_))
    match content {
      None => assert_true(false) // unreachable
      Some(root) => {
        // 内容树形状：Padding -> Row -> [侧栏, 竖线, 右栏]，右栏第一叶是
        // "组件：…"标题。
        let row = root.children()[0]
        let pane = row.children()[2]
        assert_eq(
          pane.children()[0].text(),
          "组件：" + @moonui.Gallery::section_names()[i],
        )
        assert_true(root.leaf_count() > 0)
      }
    }
  }
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// 侧栏按钮是真的：fire 一次 Click，画册换页；换页把旧树整棵关闭，
/// 句柄必须回收（live 只在"窗口 + 当前页"这一档，不随切换次数上涨）。
test "gallery：点侧栏换页，旧树句柄不泄漏" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let g = @moonui.Gallery::demo(app)
  // 侧栏：Padding -> Row -> [侧栏 Column, 竖线, 右栏]；侧栏第 4 项
  // （children()[3]）是布局组网格，TextInput 页是它的 3 号按钮（包在
  // Sized 里等宽）。
  let sidebar = match g.window().content() {
    None => abort("画册没有内容树")
    Some(root) => root.children()[0].children()[0]
  }
  let grid = sidebar.children()[3]
  let button = grid.children()[2].children()[0]
  assert_eq(button.text(), "○ TextInput 输入框")
  let live_before = b.live()
  let _ = button.fire(
    @moonui.Event::Click(button.target(), @moonui.MouseButton::Left),
  )
  assert_eq(g.current(), 2)
  // 旧树（26 个侧栏按钮 + 上一页）整棵关闭，新树挂上；两次测量都只剩
  // "窗口 + 当前页"那一档。页与页叶子数不同，这里只钉"不随切换上涨"。
  let live_after = b.live()
  assert_true(live_after <= live_before + 9)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// 状态活得过重建：Button 页点两次、换走再换回来接着点，计数从 2 续到 3。
/// 树每次切换都是新的，`clicks` 存在 Gallery 上——这是画册的关键设计。
test "gallery：交互状态在换页重建后保留" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let g = @moonui.Gallery::demo(app)
  // 画册从 Label 页起步，这条测的是 Button 页：先切过去。
  g.select(1)
  // 右栏结构：[标题, 说明, 横线, 代码区, 横线, 效果区]，效果区 =
  // Column[计数, 按钮, 禁用键]。
  fn demo_area() -> @moonui.Widget[@moonui.MockBackend] {
    match g.window().content() {
      None => abort("画册没有内容树")
      Some(root) => root.children()[0].children()[2].children()[5].children()[1]
    }
  }
  let btn = demo_area().children()[1]
  let _ = btn.fire(
    @moonui.Event::Click(btn.target(), @moonui.MouseButton::Left),
  )
  let _ = btn.fire(
    @moonui.Event::Click(btn.target(), @moonui.MouseButton::Left),
  )
  assert_eq(g.click_count(), 2)
  g.select(8) // 换去 Scroll 页，Button 页的树整棵销毁
  g.select(1) // 换回来，树是新的
  let btn2 = demo_area().children()[1]
  assert_eq(btn2.text(), "点我") // 新树长得一样
  let _ = btn2.fire(
    @moonui.Event::Click(btn2.target(), @moonui.MouseButton::Left),
  )
  assert_eq(g.click_count(), 3) // 计数续上了
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}
