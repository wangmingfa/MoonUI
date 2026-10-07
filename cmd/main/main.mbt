///|
/// §49 五个 Demo 的无头跑法：mock 后端 + 真实事件循环，把界面状态打印出来。
///
/// 这份代码存在的意义是"换个后端不用改逻辑"：接上 libui-ng 之后，唯一要替换的
/// 是 `MockBackend`，布局、事件路由、回调一律不动。
/// 文案在 `run()` 之后读不到——循环收尾会 `terminate` 后端并回收句柄（§11），
/// 所以 Counter 只打印 Core 侧仍持有的计数。
///
/// 这里的无障碍打印同时是 §32 的包外验证：`cmd/main` 只能看到公开 API，
/// 读得到视图就说明那份视图不依赖包内私有字段。

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
fn role_text(r : @MoonUI.AccessRole) -> String {
  match r {
    @MoonUI.Text => "文本"
    @MoonUI.Button => "按钮"
    @MoonUI.CheckBox => "勾选框"
    @MoonUI.TextBox => "输入框"
    @MoonUI.Group => "分组"
    @MoonUI.List => "列表"
    @MoonUI.ListItem => "条目"
    @MoonUI.Window => "窗口"
  }
}

///|
fn action_text(act : @MoonUI.AccessAction) -> String {
  match act {
    @MoonUI.Press => "按下"
    @MoonUI.Toggle => "切换"
    @MoonUI.SetValue => "改值"
  }
}

///|
/// 用第一个元素决定要不要加分隔符，避免拼接出开头的空格。
fn join(parts : Array[String], sep : String) -> String {
  let mut out = ""
  for p in parts {
    out = out + (if out == "" { "" } else { sep }) + p
  }
  out
}

///|
/// 一个节点的打印形态：角色 + 朗读名称 + 可执行动作 + 勾选态 + 禁用标记。
/// runner 是人读的，宁可多打一个字，也不要把"读屏器会念什么"猜一遍。
fn node_text(a : @MoonUI.Accessibility) -> String {
  let parts : Array[String] = [role_text(a.role) + "「" + a.label + "」"]
  if a.actions.length() > 0 {
    parts.push("[" + join(a.actions.map(x => action_text(x)), "/") + "]")
  }
  match a.state.checked {
    None => ()
    Some(v) => parts.push(if v { "已勾" } else { "未勾" })
  }
  if !a.state.enabled {
    parts.push("禁用")
  }
  join(parts, " ")
}

///|
fn nodes_text(nodes : Array[@MoonUI.Accessibility]) -> String {
  join(nodes.map(n => node_text(n)), " ｜ ")
}

///|
/// 只打印某个角色的节点，用来把列表条目单独拎出来看。
fn nodes_of_role(
  nodes : Array[@MoonUI.Accessibility],
  role : @MoonUI.AccessRole,
) -> Array[@MoonUI.Accessibility] {
  let out : Array[@MoonUI.Accessibility] = []
  for n in nodes {
    if n.role == role {
      out.push(n)
    }
  }
  out
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
      // §32：朗读名称来自 set_access_label，动作来自 on_click 的订阅
      println("  无障碍：" + nodes_text(content.accessibility_tree()))
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
/// 第五个 Demo：§49 说"File Manager 跑得通就证明框架有实际开发价值"。
/// 这里跑的是两栏界面 + 导航 + 带确认框的删除，数据是 Demo 自带的假目录树。
fn file_manager_demo() -> Unit raise @MoonUI.UiError {
  let app = new_app()
  let b = app.backend()
  let fm = @MoonUI.FileManager::demo(app)
  println("[Demo 5] File Manager")
  println(
    "  位置：" +
    fm.crumb_text() +
    "，条目：" +
    fm.entry_count().to_string(),
  )
  fm.press_row(0)
  println("  勾选首行：" + fm.detail_text())
  fm.press_open()
  println(
    "  打开之后：" +
    fm.crumb_text() +
    "，条目：" +
    fm.entry_count().to_string(),
  )
  fm.press_up()
  println("  上一级：" + fm.crumb_text())
  // 非空目录不弹确认框，直接拒绝
  fm.press_row(0)
  fm.press_delete()
  println("  删非空目录：" + fm.note_text())
  // 空目录走 §24 的确认框，这里由 mock 后端替用户按"确定"
  fm.press_row(1)
  b.push_confirm_reply(true)
  fm.press_delete()
  println("  删空目录：" + fm.note_text())
  match fm.window().content() {
    None => println("  ！窗口没有内容")
    Some(content) => {
      // 包外没有控件字段可读，只能沿内容树往下走：Padding -> Column -> 三行
      let panes = content.children()[0].children()
      println("  布局：状态栏 " + rect_text(panes[2].frame()))
      match fm.row(0) {
        None => println("        ！列表空了")
        Some(row) =>
          println("        首行 " + rect_text(row.children()[0].frame()))
      }
      // §32：条目顺序就是朗读顺序，勾选态从 Core 的 selected 现读；
      // 列表容器与每一行都没有原生对象，所以它们只以角色出现在视图里。
      let nodes = content.accessibility_tree()
      println("  无障碍：" + nodes_text(nodes_of_role(nodes, @MoonUI.List)))
      println(
        "        条目：" + nodes_text(nodes_of_role(nodes, @MoonUI.ListItem)),
      )
      println(
        "        勾选：" + nodes_text(nodes_of_role(nodes, @MoonUI.CheckBox)),
      )
    }
  }
  fm.window().close()
  println("  关闭后残留原生对象：" + b.live().to_string())
}

///|
/// 五个 Demo 都可能因为后端拒绝某个操作而 raise：让错误直接终止进程，
/// 比在 main 里吞掉更符合"无头跑法只用来验证链路"的定位。
fn main raise {
  hello_demo()
  counter_demo()
  login_demo()
  todo_demo()
  file_manager_demo()
}
