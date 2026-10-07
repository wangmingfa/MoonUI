///|
/// §49 第二个 Demo：Counter。重点不是计数本身，而是事件走完整条路：
/// 后端队列 -> `App` 路由 -> 订阅了 `Event::Click` 的 handler，
/// 最后 `Close` 事件让窗口和内容树一起被回收（§10、§11）。
fn main raise {
  let app = @common.new_app()
  let b = app.backend()
  let demo = @moonui.Demo::counter(app)
  for i = 0; i < 3; i = i + 1 {
    b.push_event(
      @moonui.Event::Click(demo.action_target(), @moonui.MouseButton::Left),
    )
  }
  b.push_event(@moonui.Event::Close(demo.window().target()))
  app.run()
  println("[Demo 2] Counter")
  println("  点击次数：" + demo.click_count().to_string())
  println("  窗口已关闭：" + demo.window().is_closed().to_string())
  println("  残留原生对象：" + b.live().to_string())
}
