///|
/// Todo 的原生后端壳（Backend #2）：`moon run examples/todo-native`。
/// 与 examples/todo 同一棵 `TodoList::demo` 树，一行 Core 代码不改——
/// §51 的「换后端只换壳」在真窗口上落的又一处地。
///
/// 列表走 `Widget::for_list` 的键控 diff（`T286`）：增删/勾选不再整树重建，
/// 匹配行实例保留（勾选状态/焦点不丢）。输入文案与状态进度走
/// `bind_input` / `bind_text`，行内勾选走 `done_sigs[id]` 的 `bind_checked`。
fn main raise {
  let app = @moonui-app.new_app()
  app.set_icon("assets/logo/moonui")
  let todo = @moonui.TodoList::demo(app)
  println(
    "真窗口已打开（原生后端）：加条目、勾选、删除——列表走 for_list 键控 diff，行实例保留，关窗口退出",
  )
  println(
    "  客户区 " +
    todo.window().size().width.to_string() +
    "x" +
    todo.window().size().height.to_string() +
    " 逻辑像素，缩放 " +
    todo.window().scale().x.to_string(),
  )
  app.run()
  println(
    "  循环结束：条目 " +
    todo.item_count().to_string() +
    "，已完成 " +
    todo.done_count().to_string(),
  )
}
