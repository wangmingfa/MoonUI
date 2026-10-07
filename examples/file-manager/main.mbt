///|
/// §49 第五个 Demo：File Manager（§49 说"这个跑得通就证明框架有实际开发价值"）。
/// 两栏界面 + 目录导航 + 带确认框的删除，数据是 Demo 自带的假目录树。
/// 无障碍视图在这里最能说明 §14 与 §32 的交界：列表容器和每一行都没有原生对象，
/// 声明角色之后才进视图，勾选态则从 Core 的 selected 现读。
fn main raise {
  let app = @common.new_app()
  let b = app.backend()
  let fm = @moonui.FileManager::demo(app)
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
      println("  布局：状态栏 " + @common.rect_text(panes[2].frame()))
      match fm.row(0) {
        None => println("        ！列表空了")
        Some(row) =>
          println(
            "        首行 " + @common.rect_text(row.children()[0].frame()),
          )
      }
      let nodes = content.accessibility_tree()
      println(
        "  无障碍：" +
        @common.nodes_text(@common.nodes_of_role(nodes, @moonui.List)),
      )
      println(
        "        条目：" +
        @common.nodes_text(@common.nodes_of_role(nodes, @moonui.ListItem)),
      )
      println(
        "        勾选：" +
        @common.nodes_text(@common.nodes_of_role(nodes, @moonui.CheckBox)),
      )
    }
  }
  fm.window().close()
  println("  关闭后残留原生对象：" + b.live().to_string())
}
