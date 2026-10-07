///|
/// §49 第四个 Demo：Todo。
/// 重点不是"能加能删"，而是每次增删都换掉整棵内容树：删除按钮的 handler 亲手
/// 销毁自己所在的树，句柄必须一个不剩地回收（§8 所有权、§6 句柄表）。
/// 行是纯布局节点，所以要从父行的 children 里取勾选框和删除键（§14）。
fn main raise {
  let app = @common.new_app()
  let b = app.backend()
  let list = @moonui.TodoList::demo(app)
  println("[Demo 4] Todo")
  list.type_input("写字")
  list.press_add()
  list.type_input("读书")
  list.press_add()
  println("  初始：" + list.status_text())
  // 勾掉第一行：Change 事件进 handler，handler 重建整棵树
  match list.row(0) {
    None => println("  ！第 0 行不存在")
    Some(row) => {
      let box = row.children()[0]
      let _ = box.fire(@moonui.Event::Change(box.target()))
      println("  勾掉第一行：" + list.status_text())
    }
  }
  // 删掉第二行：被点的按钮就在这棵要被销毁的旧树里
  match list.row(1) {
    None => println("  ！第 1 行不存在")
    Some(row) => {
      let btn = row.children()[1]
      let _ = btn.fire(
        @moonui.Event::Click(btn.target(), @moonui.MouseButton::Left),
      )
      println("  删掉第二行：" + list.status_text())
    }
  }
  let n = list.item_count()
  for i = 0; i < n; i = i + 1 {
    match list.item(i) {
      None => ()
      Some(it) =>
        println("    " + (if it.done { "[x] " } else { "[ ] " }) + it.text)
    }
  }
  match list.row(0) {
    None => println("  ！列表空了")
    Some(row) =>
      println(
        "  布局：首行勾选框 " +
        @common.rect_text(row.children()[0].frame()),
      )
  }
  // 关窗口把最后一版内容树一并回收
  list.window().close()
  println("  关闭后残留原生对象：" + b.live().to_string())
}
