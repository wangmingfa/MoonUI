///|
/// §49 第三个 Demo：Login（§4 的目录里这个例子叫 `form`）。
/// 一张表单同时验四件事：`Padding + Column` 的嵌套边界、校验分支、
/// §32 的字段朗读名来自声明而不是输入框里的值、以及只读公开 API 能不能拿到布局。
fn main raise {
  let app = @common.new_app()
  let form = @moonui.LoginForm::demo(app)
  println("[Demo 3] Login")
  println("  初始文案：" + form.status_text())
  form.press_submit()
  println("  空提交：" + form.status_text())
  form.fill("wmf", "", false)
  form.press_submit()
  let half = match form.signed_in() {
    None => "未登录"
    Some(name) => name
  }
  println("  只填用户名：" + half)
  form.fill("wmf", "s3cret", true)
  form.press_submit()
  println("  登录结果：" + form.status_text())
  // 包外不暴露字段，布局只能从窗口内容树往下读：Padding -> Column -> 五个控件
  match form.window().content() {
    None => println("  ！窗口没有内容")
    Some(content) => {
      let fields = content.children()[0].children()
      println("  布局：提示 " + @common.rect_text(fields[0].frame()))
      println("        用户名 " + @common.rect_text(fields[1].frame()))
      println("        登录键 " + @common.rect_text(fields[4].frame()))
      // §32：朗读名称来自 set_access_label，动作来自 on_click 的订阅
      println(
        "  无障碍：" + @common.nodes_text(content.accessibility_tree()),
      )
    }
  }
  println("  原生对象数：" + app.backend().live().to_string())
}
