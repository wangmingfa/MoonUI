///|
/// 自绘后端上的 Hello（§52.5 分期②收尾的同树双后端验证）：
/// `moon run examples/hello-canvas-native` 开一扇 800x600 的自绘窗——
/// 文案与按钮是画布画的，不是 AppKit 控件。
fn main raise {
  let b = @canvas-macos.CanvasBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let demo = @moonui.Demo::hello(app)
  println(
    "自绘后端已打开 hello 窗（Backend #3）：文案与按钮由画布配方绘制",
  )
  println("  布局：文案 " + @common.rect_text(demo.status().frame()))
  println("        按钮 " + @common.rect_text(demo.action().frame()))
  app.run()
}
