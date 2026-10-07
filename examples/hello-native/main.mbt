///|
/// §50 的 Hello Demo 跑在真窗口上（§48 第 09~11 步的验收件）。
///
/// `moon run examples/hello-native` 开一个 800x600 的真窗口：点按钮把
/// "Hello MoonUI" 改成 "Clicked!"，关窗口退出。代码与 examples/hello 同构，
/// 唯一的差别是后端——§47 风险 6 要验证的正是这条：Core 一行都不改，
/// 抽象就能接上真窗口。
///
/// 这个例子不进 CI：它既要现编的 libui-ng 静态库（scripts/build-libui.ps1），
/// 又要一只会点鼠标的手。真窗口链路在 CI 上的等价验证是
/// `backends/libui/backend_wbtest.mbt` 最后那条测试——它用消息合成点击与关闭，
/// 把同一条链路在无显示环境下跑完。

///|
fn main raise {
  let b = @libui.LibuiBackend::new()
  // 控件在 `App::run` 之前就要建出来（下面 Demo 会建窗口和按钮），
  // 所以先手工初始化。`run` 里的第二次 init 在 C 侧是单例守卫下的空操作。
  b.init()
  let app = @moonui.App::new(b)
  let demo = @moonui.Demo::hello(app)
  let win = demo.window()
  let size = win.size()
  println("真窗口已打开：点按钮改文案，关窗口退出")
  println(
    "  客户区 " +
    size.width.to_string() +
    "x" +
    size.height.to_string() +
    " 逻辑像素，缩放 " +
    win.scale().x.to_string(),
  )
  println("  按钮位置 " + @common.rect_text(demo.action().frame()))
  let _ = app.on_event(demo.action_target(), fn(_ev) {
    println("  收到点击：原生回调已经排进事件队列")
  })
  app.run()
  println("循环结束：点击 " + demo.click_count().to_string() + " 次")
}
