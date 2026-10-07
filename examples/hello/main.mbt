///|
/// §49 第一个 Demo：Hello World。证明"建窗口、挂内容、点一次、文案变了"这条
/// 最短链路在 mock 后端上是通的，顺带看布局给的绝对边界。
fn main raise {
  let app = @common.new_app()
  let demo = @moonui.Demo::hello(app)
  println("[Demo 1] Hello MoonUI")
  println("  文案：" + demo.status().text())
  println("  布局：文案 " + @common.rect_text(demo.status().frame()))
  println("        按钮 " + @common.rect_text(demo.action().frame()))
  demo.click()
  println("  点击后文案：" + demo.status().text())
  demo.window().relayout()
  println("  重排后布局：" + @common.rect_text(demo.status().frame()))
  println("  原生对象数：" + app.backend().live().to_string())
}
