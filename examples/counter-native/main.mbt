///|
/// Counter 的原生后端壳（Backend #2）：`moon run examples/counter-native`。
/// 与 examples/counter 同一棵 `Demo::counter` 树，一行 Core 代码不改——
/// §51 的「换后端只换壳」在真窗口上落的又一处地。
///
/// 点击走真控件回调（AppKit / Win32 / GTK4 直写），响应式绑定
/// （`bind_text_fmt`）在原生后端照常工作：点按钮只改信号，文案自动变，
/// 没有显式 `set_text`。
fn main raise {
  let app = @moonui-app.new_app()
  app.set_icon("assets/logo/moonui")
  let demo = @moonui.Demo::counter(app)
  println(
    "真窗口已打开（原生后端）：点按钮计数，文案由响应式绑定自动更新，关窗口退出",
  )
  println(
    "  客户区 " +
    demo.window().size().width.to_string() +
    "x" +
    demo.window().size().height.to_string() +
    " 逻辑像素，缩放 " +
    demo.window().scale().x.to_string(),
  )
  app.run()
  println(
    "  循环结束：点击 " +
    demo.click_count().to_string() +
    " 次，窗口已关闭：" +
    demo.window().is_closed().to_string(),
  )
}
