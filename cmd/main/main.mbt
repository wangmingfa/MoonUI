///|
/// §49 前四个 Demo 的无头跑法：mock 后端 + 真实事件循环，把界面状态打印出来。
///
/// 这份代码存在的意义是"换个后端不用改逻辑"：接上 libui-ng 之后，唯一要替换的
/// 是 `MockBackend`，布局、事件路由、回调一律不动。
/// 文案在 `run()` 之后读不到——循环收尾会 `terminate` 后端并回收句柄（§11），
/// 所以 Counter 只打印 Core 侧仍持有的计数。

///|
fn rect_text(r : @MoonUI.LogicalRect) -> String {
  "x=" +
  r.origin.x.to_string() +
  " y=" +
  r.origin.y.to_string() +
  " w=" +
  r.size.width.to_string() +
  " h=" +
  r.size.height.to_string()
}

///|
fn new_app() -> @MoonUI.App[@MoonUI.MockBackend] raise @MoonUI.UiError {
  let b = @MoonUI.MockBackend::new()
  b.init()
  @MoonUI.App::new(b)
}

///|
fn hello_demo() -> Unit raise @MoonUI.UiError {
  let app = new_app()
  let demo = @MoonUI.Demo::hello(app)
  println("[Demo 1] Hello MoonUI")
  println("  文案：" + demo.status().text())
  println("  布局：文案 " + rect_text(demo.status().frame()))
  println("        按钮 " + rect_text(demo.action().frame()))
  demo.click()
  println("  点击后文案：" + demo.status().text())
  demo.window().relayout()
  println("  重排后布局：" + rect_text(demo.status().frame()))
  println("  原生对象数：" + app.backend().live().to_string())
}

///|
fn counter_demo() -> Unit raise @MoonUI.UiError {
  let app = new_app()
  let b = app.backend()
  let demo = @MoonUI.Demo::counter(app)
  for i = 0; i < 3; i = i + 1 {
    b.push_event(
      @MoonUI.Event::Click(demo.action_target(), @MoonUI.MouseButton::Left),
    )
  }
  b.push_event(@MoonUI.Event::Close(demo.window().target()))
  app.run()
  println("[Demo 2] Counter")
  println("  点击次数：" + demo.click_count().to_string())
  println("  窗口已关闭：" + demo.window().is_closed().to_string())
  println("  残留原生对象：" + b.live().to_string())
}

///|
/// 取第 i 行的容器。行缺失时打印说明而不是静默跳过——runner 是冒烟测试，
/// "行不见了"正是要暴露的故障。
fn row_at(
  list : @MoonUI.TodoList[@MoonUI.MockBackend],
  i : Int,
) -> @MoonUI.Widget[@MoonUI.MockBackend]? {
  match list.row(i) {
    None => {
      println("  ！第 " + i.to_string() + " 行不存在")
      None
    }
    Some(row) => Some(row)
  }
}

///|
fn login_demo() -> Unit raise @MoonUI.UiError {
  let app = new_app()
  let form = @MoonUI.LoginForm::demo(app)
  println("[Demo 3] Login")
  println("  初始文案：" + form.status_text())
  form.press_submit()
  println("  空提交：" + form.status_text())
  form.fill("wmf", "", false)
  form.press_submit()
  let half = match form.signed_in() {
    None => "未登录"
    Some(name) => name
  }
  println("  只填用户名：" + half)
  form.fill("wmf", "s3cret", true)
  form.press_submit()
  println("  登录结果：" + form.status_text())
  // 包外不暴露字段，布局只能从窗口内容树往下读：Padding -> Column -> 五个控件
  match form.window().content() {
    None => println("  ！窗口没有内容")
    Some(content) => {
      let fields = content.children()[0].children()
      println("  布局：提示 " + rect_text(fields[0].frame()))
      println("        用户名 " + rect_text(fields[1].frame()))
      println("        登录键 " + rect_text(fields[4].frame()))
    }
  }
  println("  原生对象数：" + app.backend().live().to_string())
}

///|
/// 第四个 Demo 的重点不是"能加能删"，而是每次增删都换掉整棵内容树：
/// 删除按钮的 handler 亲手销毁自己所在的树，句柄必须一个不剩地回收。
fn todo_demo() -> Unit raise @MoonUI.UiError {
  let app = new_app()
  let b = app.backend()
  let list = @MoonUI.TodoList::demo(app)
  println("[Demo 4] Todo")
  list.type_input("写字")
  list.press_add()
  list.type_input("读书")
  list.press_add()
  println("  初始：" + list.status_text())
  // 勾掉第一行：Change 事件进 handler，handler 重建整棵树
  match row_at(list, 0) {
    None => ()
    Some(row) => {
      let box = row.children()[0]
      let _ = box.fire(@MoonUI.Event::Change(box.target()))
      println("  勾掉第一行：" + list.status_text())
    }
  }
  // 删掉第二行：被点的按钮就在这棵要被销毁的旧树里
  match row_at(list, 1) {
    None => ()
    Some(row) => {
      let btn = row.children()[1]
      let _ = btn.fire(
        @MoonUI.Event::Click(btn.target(), @MoonUI.MouseButton::Left),
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
  match row_at(list, 0) {
    None => ()
    Some(row) =>
      println(
        "  布局：首行勾选框 " + rect_text(row.children()[0].frame()),
      )
  }
  // 关窗口把最后一版内容树一并回收
  list.window().close()
  println("  关闭后残留原生对象：" + b.live().to_string())
}

///|
/// 四个 Demo 都可能因为后端拒绝某个操作而 raise：让错误直接终止进程，
/// 比在 main 里吞掉更符合"无头跑法只用来验证链路"的定位。
fn main raise {
  hello_demo()
  counter_demo()
  login_demo()
  todo_demo()
}
