///|
fn build(app : @moonui.App[@moonui.MockBackend]) -> Unit raise @moonui.UiError {
  let backend = app.backend()
  let message = @moonui.Widget::label(backend, "Hello MoonUI")
  let button = @moonui.Widget::button(backend, "Click Me")
  let _ = button.on_click(fn() raise @moonui.UiError {
    message.set_text("Clicked!")
  })
  let window = app.create_window("MoonUI", @moonui.LogicalSize::{
    width: 800.0,
    height: 600.0,
  })
  window.set_content(@moonui.Widget::column(backend, 16.0, [message, button]))
  window.show()
}

///|
test "readme snippet compiles and wires up" {
  let b = @moonui.MockBackend::new()
  b.init()
  let app = @moonui.App::new(b)
  build(app)
  // 窗口 + 两个叶子控件，Column 不占原生对象
  assert_eq(b.live(), 3)
}
