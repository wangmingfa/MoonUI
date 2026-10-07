// Blackbox tests run against the package's public API. Use `@MoonUI` to import.
// Prefer high-level behaviors over implementation details.
// Run `moon test` to execute and `moon test --update` to refresh snapshots.

///|
/// README 里那段示例必须真的能编译，所以把它放在这里而不是只写在文档里：
/// 它是唯一从包外验证公共 API 够不够用测试——只碰导出名字，不碰 Core 内部 helper。
test "README 示例：从包外拼出 Hello 界面并点一次" {
  let b = @MoonUI.MockBackend::new()
  @MoonUI.Backend::init(b)
  let app = @MoonUI.App::new(b)
  let backend = app.backend()
  let message = @MoonUI.Widget::label(backend, "Hello MoonUI")
  let button = @MoonUI.Widget::button(backend, "Click Me")
  let _ = button.on_click(fn() raise @MoonUI.UiError {
    message.set_text("Clicked!")
  })
  let window = app.create_window("MoonUI", @MoonUI.LogicalSize::{
    width: 800.0,
    height: 600.0,
  })
  window.set_content(@MoonUI.Widget::column(backend, 16.0, [message, button]))
  window.show()
  // 窗口 + 两个叶子控件；Column 是纯布局节点，不占原生对象（§14）
  assert_eq(b.live(), 3)
  assert_eq(message.text(), "Hello MoonUI")
  let _ = button.fire(
    @MoonUI.Event::Click(button.target(), @MoonUI.MouseButton::Left),
  )
  assert_eq(message.text(), "Clicked!")
  @MoonUI.Backend::terminate(b)
  assert_eq(b.live(), 0)
}
