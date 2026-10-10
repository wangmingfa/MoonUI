///|
/// §50 的第二个 Demo：Counter 跑在 Windows 的真窗口上（§48 第 09~11 步的验收件，
/// 和 `backends/libui-windows/backend_wbtest.mbt` 里那条真点击是同一条链路，只是这里
/// 按鼠标的手是真人）。
///
/// `moon run examples/counter-native-windows`：点 "Click Me"，标签从 "Count: 0"
/// 一路往上加，终端每点印一行；关窗口退出，退出后印残留的原生对象数。
///
/// 和 ../counter 的差别只在事件的来源：无头那份往 mock 的队列里 `push_event`，
/// 这一份由真按钮的原生回调往 `LibuiBackend` 自己的队列里放同一个 `Click`。
/// Demo 的 MoonBit 代码两者共用，计数存在 Core，不读标签文案（§49 那条取舍）。
///
/// 这里订阅的是按钮自己的 target，而 Counter 的控件树建一次就不动，所以订阅不会
/// 错位。todo / file-manager 那两份 native 正因为每次增删都换整棵树，才不订阅、
/// 只在收尾读数——`App::on_event` 只按 id 匹配，而 id 会被回收复用（TODO `T49`）。

///|
fn main raise {
  let b = @libui-common.LibuiBackend::new()
  // 控件要在 `App::run` 之前建出来（下面的 Demo 会建窗口和按钮），所以先手工
  // 初始化；`run` 里的第二次 init 在 C 侧是单例守卫下的空操作。
  b.init()
  let app = @moonui.App::new(b)
  let demo = @moonui.Demo::counter(app)
  let win = demo.window()
  let size = win.size()
  println("真窗口已打开：点按钮计数，关窗口退出")
  println(
    "  客户区 " +
    size.width.to_string() +
    "x" +
    size.height.to_string() +
    " 逻辑像素，缩放 " +
    win.scale().x.to_string(),
  )
  println(
    "  文案 " +
    demo.status().text() +
    "，按钮 " +
    @common.rect_text(demo.action().frame()),
  )
  let _ = app.on_event(demo.action_target(), fn(ev) raise @moonui.UiError {
    // `App::on_event` 只按 target 的 id 匹配、不看事件种类：真窗口一显示，按钮
    // 就拿到焦点，实测有一条 `Focus(target=1)`（1 正是这只按钮的句柄 id）走到这里，
    // 不筛就启动多印一行"第 0 次点击"。Widget 上的 `on_click` 自带种类过滤器，
    // app 级订阅没有——这一层差别记在 TODO `T49`。
    match ev {
      @moonui.Event::Click(_, _) =>
        println(
          "  第 " +
          demo.click_count().to_string() +
          " 次点击：" +
          demo.status().text(),
        )
      _ => ()
    }
  })
  app.run()
  println(
    "循环结束：一共点了 " + demo.click_count().to_string() + " 次",
  )
  println("  窗口已关闭：" + win.is_closed().to_string())
  println(
    "  残留原生对象：" + @libui-common.native_live_handles().to_string(),
  )
}
