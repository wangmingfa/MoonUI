///|
/// `T88④` 先例同款的无头演示壳（[Demo 10]）：Playground 双档——DSL 构树
/// 描述档加参数面板档（Demo 本体在库 `demo_playground.mbt`，判据测试随包
/// playground_test.mbt——这里是给人跑的无头演示：同一份描述换后端就是
/// ../playground-native 的真窗版）。
fn main raise {
  let app = @common.new_app()
  let demo = @moonui.PlaygroundDemo::demo(app, @moonui.PLAYGROUND_DEFAULT_DESC)
  println("[Demo 10] Playground")
  println(
    "  描述（DSL 构树描述，11 个种类全齐、11 条外观链盖 7 条——库头注的文法定稿表）：",
  )
  println("    " + demo.description())
  // 左树右面板：内容树的种类清单与 dump（无头不开窗）
  match demo.window().content() {
    None => println("  ！没有内容树")
    Some(root) => {
      let content = root.children()[0]
      println(
        "  内容树叶子 " +
        content.leaf_count().to_string() +
        " 个（右半面板列 " +
        root.children()[1].leaf_count().to_string() +
        " 个控件）",
      )
      println("  内容树 dump：")
      println(content.dump_layout())
    }
  }
  // 面板闭环演示：命中反查选中 → 读回 → 改值 → 描述变 → 重建 → 新参数生效
  match demo.window().content() {
    None => println("  ！没有内容树")
    Some(root) => {
      // 选中内容根的 Text("Playground")（children[0]，带 font_size/字重/前景三条链）
      let head = root.children()[0].children()[0]
      let f = head.frame()
      demo.select_at(@moonui.LogicalPoint(f.origin.x + 1.0, f.origin.y + 1.0))
      println("  面板读回：")
      for row in demo.panel_rows() {
        println("    " + row)
      }
      // 改字号 → 描述变 → 重建 → 读回跟上
      demo.panel_edit_chain("font_size", "24")
      println("  改 font_size=24 后描述：")
      println("    " + demo.description())
      for row in demo.panel_rows() {
        println("    " + row)
      }
    }
  }
  app.quit()
  app.run()
  let b = app.backend()
  let stats = b.handle_stats()
  println(
    "  退出句柄统计：live=" +
    stats.live.to_string() +
    " 峰值=" +
    stats.high_water.to_string() +
    "（重建整棵换的回收账归零读数——T88① 的泄漏检查两只读数）",
  )
}
