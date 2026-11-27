///|
/// OpenTodo 复刻件的入口（`T409`）。
///
/// 只建应用与窗口，跑事件循环——状态与摆位在 `todo_app` / `todo_ui`，
/// 数据与日期口径在 `todo`，像素与矢量图标在 `painter`。
///
/// 跑法：`moon run examples/todo-native`（macOS / Windows / Linux 三端同一入口）。
fn main raise {
  let app = @moonui-app.new_app()
  app.set_icon("assets/logo/moonui")
  // T412：网页用 Inter（@font-face OpenTodo Inter，Latin 子集）+ 系统字回退；
  // 本端默认 SF Pro 推进宽度比 Inter 窄 ~8.7%（简报两行的宽度差、run 间 stretch
  // 缝隙都是这个）。Inter 先前测过"不动"是因为它没装（set_font_family 静默回落
  // 系统字）；已装 InterVariable 到 ~/Library/Fonts。用 Inter 后 Latin 字形对齐
  // 网页、CJK 由 NSAttributedString 自动回退系统字（与网页的 CJK 回退同源）。
  app.set_font_family(Some("Inter"))
  let _ = TodoApp::build(app)
  snapshot_then_quit(app)
  app.run()
}

///|
/// TEMP（取证用，勿提交）
fn snapshot_then_quit(app : @moonui.App[@native-common.NativeBackend]) -> Unit {
  let _ = app.post_after(700, fn() -> Unit {
    let _ = @native-common.native_snapshot_all("/tmp/todo_shots")
    app.quit()
  })
}
