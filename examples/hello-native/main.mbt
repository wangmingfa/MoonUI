///|
/// §50 的 Hello Demo 跑在真窗口上（§48 第 03/09~11 步的验收件）。
///
/// `moon run examples/hello-native` 开一只真窗口：点按钮把 "Hello MoonUI"
/// 改成 "Clicked!"，关窗口退出。macOS 与 Windows 共用这一份——实现全在
/// `@libui-common.LibuiBackend`，底下的 C 由 prebuild-link.js 按宿主挑一份编。
/// §47 风险 6 要验证的正是这条：Core 一行都不改，抽象就能接上两个平台的真窗口。
///
/// macOS 上有一处肉眼可见的差别：Retina 屏的倍数在这里是真实存在的，启动打印的
/// `scale` 在 5K/Retina 上是 2.0，而 Windows 那份只在系统缩放不是 100% 时才偏离 1。
///
/// 这个例子不进 CI：它既要现编的 libui-ng 静态库（scripts/build-libui.sh），又要一只
/// 会点鼠标的手。真窗口链路在 CI 上的等价验证是两个后端包各自的测试——它们用
/// hitTest 与 performClose: 合成点击和关闭，把同一条链路跑完。

///|
fn main raise {
  let b = @libui-common.LibuiBackend::new()
  // 控件在 `App::run` 之前就要建出来（下面 Demo 会建窗口和按钮），
  // 所以先手工初始化。`run` 里的第二次 init 在 C 侧是单例守卫下的空操作。
  b.init()
  let app = @moonui.App::new(b)
  // §26：stem 不带扩展名，mac 补 .png、Windows 补 .ico，两侧共用这一行
  app.set_icon("assets/logo/moonui")
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
