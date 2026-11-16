///|
fn build(app : @moonui.App[@moonui.MockBackend]) -> Unit raise @moonui.UiError {
  let backend = app.backend()
  let message = @moonui.Widget::label(backend, "Hello MoonUI")
  let button = @moonui.Widget::button(backend, "Click Me")
  let _ = button.on_click(fn() raise @moonui.UiError {
    message.set_text("Clicked!")
  })
  let window = app.create_window("MoonUI", @moonui.LogicalSize(800.0, 600.0))
  window.set_content(@moonui.Widget::column(backend, 16.0, [message, button]))
  window.show()
}

///|
fn reactive_counter(
  app : @moonui.App[@moonui.MockBackend],
) -> Unit raise @moonui.UiError {
  let b = app.backend()
  // Layer 1：唯一的事实源
  let count = @moonui.Signal(0)
  // Layer 2：标签绑到状态上，不再手写 set_text
  let label = @moonui.Widget::label(b, "")
  let _ = label.bind_text_fmt(count, fn(c : Int32) { "\{c} 次" })
  // Layer 3：条件子树（依赖变才重建，父容器不动）
  let hint = @moonui.Widget::reactive(b, fn() raise @moonui.UiError {
    if count.get() > 0 {
      @moonui.Widget::label(b, "已经点过了")
    } else {
      @moonui.Widget::label(b, "还没点")
    }
  })
  // 事件回调只改状态
  let button = @moonui.Widget::button(b, "+1")
  let _ = button.on_click(fn() raise @moonui.UiError {
    count.update(fn(c) { c + 1 })
  })
  let window = app.create_window("Reactive", @moonui.LogicalSize(320.0, 200.0))
  window.set_content(@moonui.Widget::column(b, 8.0, [label, hint, button]))
  window.show()
}

///|
test "reactive snippet compiles and wires up" {
  let b = @moonui.MockBackend()
  b.init()
  let app = @moonui.App(b)
  reactive_counter(app)
  // 窗口 + label/hint/button 三个叶子；reactive 的透明布局节点不占原生对象
  assert_eq(b.live(), 4)
}

///|
test "readme snippet compiles and wires up" {
  let b = @moonui.MockBackend()
  b.init()
  let app = @moonui.App(b)
  build(app)
  // 窗口 + 两个叶子控件，Column 不占原生对象
  assert_eq(b.live(), 3)
}
