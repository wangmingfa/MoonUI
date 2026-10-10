///|
/// §50 的第四个 Demo：Todo 跑在 macOS 的真窗口上。
///
/// `moon run examples/todo-native-macos`：在输入框里打字、点 "添加"、勾每一行的
/// 勾选框、按 "x" 删行；关窗口退出。
///
/// 这一份是四只真窗口 Demo 里最能说明 §8 所有权的一条：每次增删都把**整棵内容树**
/// 换掉（`TodoList::render_at`），旧的那一版在 `Window::set_content` 里逐控件销毁。
/// 加三行、勾掉一行、删掉一行之后关窗口，终端最后印的残留原生对象数仍是 0，
/// 这条链路的句柄账就当场看得见了。
///
/// 它因此不订阅任何控件：`App::on_event` 只按 target 的 id 匹配，而 id 会被
/// 句柄表回收复用，订阅一棵会重建的树里的控件，早晚会命中到另一只新控件上
/// （判据与量法见 TODO `T49`；counter / form 那两份的树建一次不动，才敢订阅）。
/// 收尾那份读数走 Core 自己的账（`item_count` / `done_count` / `item`，三条都不
/// 碰原生句柄），不读标签文案——`app.run()` 末尾的 `terminate` 已经把控件回收了，
/// 那时候再问 `status_text()` 就是问一只死句柄。

///|
fn main raise {
  let b = @libui-common.LibuiBackend::new()
  b.init()
  let app = @moonui.App::new(b)
  let list = @moonui.TodoList::demo(app)
  let win = list.window()
  let size = win.size()
  println(
    "真窗口已打开：打字→添加，勾选框切换，x 删除，关窗口退出",
  )
  println(
    "  客户区 " +
    size.width.to_string() +
    "x" +
    size.height.to_string() +
    " 逻辑像素，缩放 " +
    win.scale().x.to_string(),
  )
  match win.content() {
    None => println("  ！窗口没有内容")
    Some(content) => {
      let body = content.children()[0].children()
      println("  提示 " + @common.rect_text(body[0].frame()))
      // 中间那格是 `Row`、最后是 `Scroll`，两个都是纯布局节点：没有原生对象，
      // 也就没有自己的 frame（§14），要读尺寸只能读它们的孩子。
      let input_row = body[1].children()
      println("  输入框 " + @common.rect_text(input_row[0].frame()))
      println("  添加键 " + @common.rect_text(input_row[1].frame()))
      println(
        "  列表当前 " +
        list.item_count().to_string() +
        " 行，加一行才有行可读",
      )
    }
  }
  app.run()
  println(
    "循环结束：" +
    list.done_count().to_string() +
    "/" +
    list.item_count().to_string() +
    " 已完成",
  )
  let n = list.item_count()
  for i = 0; i < n; i = i + 1 {
    match list.item(i) {
      None => ()
      Some(it) =>
        println("    " + (if it.done { "[x] " } else { "[ ] " }) + it.text)
    }
  }
  println(
    "  残留原生对象：" + @libui-common.native_live_handles().to_string(),
  )
}
