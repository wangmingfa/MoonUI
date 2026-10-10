///|
/// §50 的第三个 Demo：Login 表单（§4 的目录里这个例子叫 `form`）跑在 Windows 的
/// 真窗口上。
///
/// `moon run examples/form-native-windows`：在两只输入框里真打字、勾真勾选框、点
/// "登录"，终端跟着印校验结果；关窗口退出。
///
/// 这一份是四种真窗口 Demo 里事件种类最全的一只：`Click`（按钮）、`Input`（输入框
/// 文本变化，`T23` 在 mac 上是整串一次 `insertText:` 一条事件）、`Change`（勾选框，
/// §48-13）。无头那份靠 `form.fill(...)` 直接写文案，这里的文案是真键盘进原生编辑框（Win32 是 EDIT，`T46` 逐字符那条路）
/// 之后由原生回调送进队列、再由 Core 读回来的——同一段 `check_login` 读的仍是
/// `username.text()`，一行没分叉。
///
/// 表单的控件树建一次就不动，所以订阅按 id 匹配在这里是安全的（对比 todo /
/// file-manager 那两份，见 TODO `T49`）。订阅里读 `status_text()` 是安全的——回调
/// 在 `app.run()` 的循环里跑，控件还活着；循环结束时的 `terminate` 把控件回收了，
/// 所以收尾那句只问 Core 自己的账（`signed_in()`，不碰原生句柄）。

///|
fn main raise {
  let b = @libui-common.LibuiBackend::new()
  b.init()
  let app = @moonui.App::new(b)
  let form = @moonui.LoginForm::demo(app)
  let win = form.window()
  println("真窗口已打开：打字、勾选、点登录，关窗口退出")
  match win.content() {
    None => println("  ！窗口没有内容")
    Some(content) => {
      let fields = content.children()[0].children()
      let hint = fields[0]
      let username = fields[1]
      let submit = fields[4]
      println("  提示 " + @common.rect_text(hint.frame()))
      println("  用户名框 " + @common.rect_text(username.frame()))
      println("  登录键 " + @common.rect_text(submit.frame()))
      println(
        "  无障碍：" + @common.nodes_text(content.accessibility_tree()),
      )
      // 两条订阅都自己筛事件种类：`App::on_event` 只按 target 的 id 匹配（窗口
      // 一显示，输入框拿到焦点，那条 `Focus` 就会命中下面第二条），见 TODO `T49`。
      let _ = app.on_event(submit.target(), fn(ev) raise @moonui.UiError {
        match ev {
          @moonui.Event::Click(_, _) =>
            println("  点登录：" + form.status_text())
          _ => ()
        }
      })
      let _ = app.on_event(username.target(), fn(ev) raise @moonui.UiError {
        match ev {
          @moonui.Event::Input(_, _) =>
            println("  用户名框现在是：" + username.text())
          _ => ()
        }
      })
    }
  }
  app.run()
  let who = match form.signed_in() {
    None => "没登录成"
    Some(name) => "欢迎，" + name
  }
  println("循环结束：" + who)
  println(
    "  残留原生对象：" + @libui-common.native_live_handles().to_string(),
  )
}
