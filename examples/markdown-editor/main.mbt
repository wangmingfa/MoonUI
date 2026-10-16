///|
/// `T88④` 第二个验证性示例：Markdown 编辑器。验证的地基是分栏（左编辑右
/// 预览）+ 行账最小编排（标题/列表/粗体/正文四类——不是完整 Markdown）+
/// 落盘读档（文件半沿 `T86⑦` 的 extern 先例同款：native 真读写，wasm 上
/// `Unsupported` 显式缺席——判据的文件半在 native 门控里闭环）。
/// 无头演示，真窗编辑留给 owner 手动跑。
fn main raise {
  let app = @common.new_app()
  let text = "# 设置中心\n\n- 表单档\n**偏好同步**\n正文一行"
  let demo = @moonui.MarkdownDemo::demo(app, text)
  println("[Demo 8] Markdown 编辑器")
  match demo.window().content() {
    Some(r) =>
      println(
        "  分栏：" +
        r.children().length().to_string() +
        " 格（左编辑右预览，编辑器是多行域）",
      )
    None => println("  分栏：无")
  }
  println(
    "  行账：" +
    demo.parsed().length().to_string() +
    " 行（标题/列表/粗体/正文四类，空行不进账）",
  )
  println("  预览：" + @common.join(demo.preview_texts(), " ｜ "))
  // 落盘读档往返：存 → 读回 → 行账与预览重拼一致（文件半的真读写）
  let path = "/tmp/moonui-demo-markdown.md"
  demo.save_to(path)
  demo.load_from(path)
  println(
    "  落盘读档往返：编辑器 " +
    demo.editor_text().length().to_string() +
    " 字符，预览重拼 " +
    demo.preview_texts().length().to_string() +
    " 行",
  )
  app.quit()
  app.run()
  let b = app.backend()
  let stats = b.handle_stats()
  println(
    "  退出句柄统计：live=" +
    stats.live.to_string() +
    " 峰值=" +
    stats.high_water.to_string() +
    "（预览重拼回收过旧标签——峰值照见）",
  )
}
