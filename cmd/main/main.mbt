///|
/// §49 前两个 Demo 的无头跑法：mock 后端 + 真实事件循环，把界面状态打印出来。
///
/// 这份代码存在的意义是"换个后端不用改逻辑"：接上 libui-ng 之后，唯一要替换的
/// 是 `MockBackend`，布局、事件路由、回调一律不动。
/// 文案在 `run()` 之后读不到——循环收尾会 `terminate` 后端并回收句柄（§11），
/// 所以 Counter 只打印 Core 侧仍持有的计数。

///|
fn rect_text(r : @MoonUI.LogicalRect) -> String {
  "x=" +
  r.origin.x.to_string() +
  " y=" +
  r.origin.y.to_string() +
  " w=" +
  r.size.width.to_string() +
  " h=" +
  r.size.height.to_string()
}

///|
fn new_app() -> @MoonUI.App[@MoonUI.MockBackend] raise @MoonUI.UiError {
  let b = @MoonUI.MockBackend::new()
  b.init()
  @MoonUI.App::new(b)
}

///|
fn hello_demo() -> Unit raise @MoonUI.UiError {
  let app = new_app()
  let demo = @MoonUI.Demo::hello(app)
  println("[Demo 1] Hello MoonUI")
  println("  文案：" + demo.status().text())
  println("  布局：文案 " + rect_text(demo.status().frame()))
  println("        按钮 " + rect_text(demo.action().frame()))
  demo.click()
  println("  点击后文案：" + demo.status().text())
  demo.window().relayout()
  println("  重排后布局：" + rect_text(demo.status().frame()))
  println("  原生对象数：" + app.backend().live().to_string())
}

///|
fn counter_demo() -> Unit raise @MoonUI.UiError {
  let app = new_app()
  let b = app.backend()
  let demo = @MoonUI.Demo::counter(app)
  for i = 0; i < 3; i = i + 1 {
    b.push_event(
      @MoonUI.Event::Click(demo.action_target(), @MoonUI.MouseButton::Left),
    )
  }
  b.push_event(@MoonUI.Event::Close(demo.window().target()))
  app.run()
  println("[Demo 2] Counter")
  println("  点击次数：" + demo.click_count().to_string())
  println("  窗口已关闭：" + demo.window().is_closed().to_string())
  println("  残留原生对象：" + b.live().to_string())
}

///|
/// 两个 Demo 都可能因为后端拒绝某个操作而 raise：让错误直接终止进程，
/// 比在 main 里吞掉更符合"无头跑法只用来验证链路"的定位。
fn main raise {
  hello_demo()
  counter_demo()
}
