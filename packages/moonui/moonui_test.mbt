// Blackbox tests run against the package's public API. Use `@moonui` to import.
// Prefer high-level behaviors over implementation details.
// Run `moon test` to execute and `moon test --update` to refresh snapshots.

///|
/// README 里那段示例必须真的能编译，所以把它放在这里而不是只写在文档里：
/// 它是唯一从包外验证公共 API 够不够用测试——只碰导出名字，不碰 Core 内部 helper。
test "README 示例：从包外拼出 Hello 界面并点一次" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
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
  // 窗口 + 两个叶子控件；Column 是纯布局节点，不占原生对象（§14）
  assert_eq(b.live(), 3)
  assert_eq(message.text(), "Hello MoonUI")
  let _ = button.fire(
    @moonui.Event::Click(button.target(), @moonui.MouseButton::Left),
  )
  assert_eq(message.text(), "Clicked!")
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// §15 的覆盖必须沿树往下走：纯布局节点不占原生对象、自己不收样式（§14），
/// 但它设的字号要进到子控件的度量里。"hi" 是 2 个码元：
/// 基准 2×8+8 = 24.0，字号 24.0 下 2×8×2+8 = 40.0。
test "容器上的字号进叶子：Column 的覆盖要影响子控件宽度" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let label = @moonui.Widget::label(backend, "hi")
  let column = @moonui.Widget::column(backend, 0.0, [label])
  let window = app.create_window("MoonUI", @moonui.LogicalSize::{
    width: 400.0,
    height: 300.0,
  })
  window.set_content(column)
  assert_eq(label.bounds().size.width, 24.0)
  column.set_style(Some(@moonui.style(font_size=Some(24.0))))
  window.relayout()
  assert_eq(label.bounds().size.width, 40.0)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// §15/§16 的样式必须进到测量，否则公共 API 上的 `set_style` 就是只写字段。
/// 数值是 mock 的确定性度量（`mock_widget.mbt`：文字宽度 = 码元数 × 8.0 × 字号/12.0，
/// 外加不随字号缩放的控件内边距），"Size me" 是 7 个码元：
/// 无字号时 7×8+8 = 64.0，字号 24.0（相对 12.0 的两倍）下 7×8×2+8 = 120.0。
test "字号进布局：set_style 之后重排要按新度量给矩形" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let label = @moonui.Widget::label(backend, "Size me")
  let window = app.create_window("MoonUI", @moonui.LogicalSize::{
    width: 400.0,
    height: 300.0,
  })
  window.set_content(@moonui.Widget::column(backend, 0.0, [label]))
  assert_eq(label.bounds().size.width, 64.0)
  label.set_style(Some(@moonui.style(font_size=Some(24.0))))
  window.relayout()
  assert_eq(label.bounds().size.width, 120.0)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}
