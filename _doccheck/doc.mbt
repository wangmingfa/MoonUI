///|
fn build(app : @MoonUI.App[@MoonUI.MockBackend]) -> Unit raise @MoonUI.UiError {
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
}

///|
test "readme snippet compiles and wires up" {
  let b = @MoonUI.MockBackend::new()
  b.init()
  let app = @MoonUI.App::new(b)
  build(app)
  // 窗口 + 两个叶子控件，Column 不占原生对象
  assert_eq(b.live(), 3)
}
