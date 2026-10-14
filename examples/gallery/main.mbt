///|
/// 组件画册的 mock 通道（真窗口版在 ../gallery-native，两个平台共用）：
/// 把画册当目录用，逐页打印结构与状态，
/// 不开真窗口、不用手点。真后端上同一份画册换 backend 就能跑。
fn main raise {
  let app = @common.new_app()
  let g = @moonui.Gallery::demo(app)
  println("[Demo 6] 组件画册")
  println("  目录：" + @common.join(@moonui.Gallery::section_names(), " / "))
  println("  起步页：" + @moonui.Gallery::section_names()[g.current()])
  // 逐页走一遍：每页的标题都要与目录对上，内容树都要有叶子。
  for i = 0; i < @moonui.Gallery::section_names().length(); i = i + 1 {
    g.select(i)
    match g.window().content() {
      None => println("  ！第 \{i} 页没有内容树")
      Some(content) => {
        // 右栏在 Row 的下标 2：中间隔着一根 VSeparator（见 Gallery::refresh 的
        // 树形图）；T74 起右栏整体包在 Scroll 里，标题在文档区列的第 0 项。
        let pane = content.children()[0].children()[2].children()[0]
        println(
          "  第 \{i} 页 " +
          @moonui.Gallery::section_names()[i] +
          "：标题「" +
          pane.children()[0].text() +
          "」，叶子 " +
          content.leaf_count().to_string() +
          " 个",
        )
      }
    }
  }
  // 交互状态活得过重建：Button 页点两次、换走换回、再点一次。
  g.select(1)
  match g.window().content() {
    None => println("  ！Button 页没有内容树")
    Some(content) => {
      // 内容树：Padding -> Row -> [侧栏, VSeparator, 右栏] -> 右栏[5] 效果区 ->
      // [计数, 按钮, 禁用键]（右栏六节的排布见 Gallery::build_pane）
      // T74 起右栏包在 Scroll 里，比老树多一层
      let demo = content.children()[0].children()[2].children()[0].children()[5].children()[1]
      let btn = demo.children()[1]
      let _ = btn.fire(
        @moonui.Event::Click(btn.target(), @moonui.MouseButton::Left),
      )
      let _ = btn.fire(
        @moonui.Event::Click(btn.target(), @moonui.MouseButton::Left),
      )
      g.select(8)
      g.select(1)
      let demo2 = match g.window().content() {
        None => {
          println("  ！换回来没有内容树")
          return
        }
        Some(c) =>
          c.children()[0].children()[2].children()[0].children()[5].children()[1]
      }
      let btn2 = demo2.children()[1]
      let _ = btn2.fire(
        @moonui.Event::Click(btn2.target(), @moonui.MouseButton::Left),
      )
      println(
        "  换页重建后计数续上：" +
        g.click_count().to_string() +
        "（期望 3）",
      )
    }
  }
  println("  原生对象数：" + app.backend().live().to_string())
}
