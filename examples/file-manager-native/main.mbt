///|
/// §50 的第五个 Demo：File Manager 跑在 Windows 的真窗口上（§49 说"这个跑得通就
/// 证明框架有实际开发价值"）。
///
/// `moon run examples/file-manager-native`：点左列每行的勾选框选中一个条目，
/// "打开"进目录、"上一级"退出去，"删除"走 §24 那条确认框——在这里它是**真的（Win32 的 `MessageBoxW`，`T43` 真跑钉过）**
/// 由你本人按"确定"或"取消"，答案从面板回到 `FileManager`，
/// 非空目录那条仍然不弹面板、直接拒绝。关窗口退出。
///
/// 假数据在 Demo 里，Core 不做文件 IO（§47 的依赖闸门）。和 ../file-manager 的
/// 差别只在两处：无头那份用 `b.push_confirm_reply(true)` 替用户按确定，这里由真
/// 面板给答案；无头那份用 `press_row` / `press_open` 直发事件，这里的事件来自真控件。
///
/// 这一份也不订阅任何控件：列表每次换目录、每次增删都重建整棵树，`App::on_event`
/// 只按 id 匹配而 id 会被复用（见 TODO `T49`）。收尾读数走 Core 的账（`path` /
/// `entry_count` / `selected` 三条都不碰原生句柄），标签文案在 `terminate` 之后
/// 就不能问了。

///|
fn main raise {
  let b = @libui-common.LibuiBackend::new()
  b.init()
  let app = @moonui.App::new(b)
  let fm = @moonui.FileManager::demo(app)
  let win = fm.window()
  let size = win.size()
  println("真窗口已打开：勾选一行→打开/删除，关窗口退出")
  println(
    "  客户区 " +
    size.width.to_string() +
    "x" +
    size.height.to_string() +
    " 逻辑像素，缩放 " +
    win.scale().x.to_string(),
  )
  println(
    "  位置：" + fm.path() + "，条目：" + fm.entry_count().to_string(),
  )
  match win.content() {
    None => println("  ！窗口没有内容")
    Some(content) => {
      let panes = content.children()[0].children()
      println("  状态栏 " + @common.rect_text(panes[2].frame()))
      match fm.row(0) {
        None => println("        ！列表空了")
        Some(row) =>
          println("  首行 " + @common.rect_text(row.children()[0].frame()))
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
    }
  }
  app.run()
  println("循环结束：位置 " + fm.path())
  match fm.selected() {
    None => println("  没选中条目")
    Some(i) => println("  选中第 " + i.to_string() + " 行")
  }
  let n = fm.entry_count()
  for i = 0; i < n; i = i + 1 {
    match fm.entry(i) {
      None => ()
      Some(e) => println("    " + e.name + (if e.is_dir { "/" } else { "" }))
    }
  }
  println(
    "  残留原生对象：" + @libui-common.native_live_handles().to_string(),
  )
}
