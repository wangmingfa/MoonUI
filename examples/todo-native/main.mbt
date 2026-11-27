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
