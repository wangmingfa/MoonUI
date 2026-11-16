///|
/// Login 表单的原生后端壳（Backend #2）：`moon run examples/form-native`。
/// 与 examples/form 同一棵 `LoginForm::demo` 树，一行 Core 代码不改——
/// §51 的「换后端只换壳」在真窗口上落的又一处地。
///
/// 字段与状态都住 `Signal`，控件经 `bind_input` / `bind_check` / `bind_text`
/// 双向接信号：用户打字 → `Input` 事件写回信号 → 校验读信号、写状态文案，
/// 没有显式 `set_text`。
fn main raise {
  let app = @moonui-app.new_app()
  app.set_icon("assets/logo/moonui")
  let form = @moonui.LoginForm::demo(app)
  println(
    "真窗口已打开（原生后端）：填用户名/密码、勾「记住我」、点登录——状态文案由响应式绑定自动更新，关窗口退出",
  )
  println(
    "  客户区 " +
    form.window().size().width.to_string() +
    "x" +
    form.window().size().height.to_string() +
    " 逻辑像素，缩放 " +
    form.window().scale().x.to_string(),
  )
  app.run()
  let result = match form.signed_in() {
    None => "未登录"
    Some(name) => name
  }
  println("  循环结束：登录结果 " + result)
}
