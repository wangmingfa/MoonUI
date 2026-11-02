///|
/// T190 P0.5 演示：用户侧渲染后端切换。
///
/// 下拉给出「自动 / CoreGraphics / Metal」，保存按钮把选择写进
/// `$HOME/.moonui/render_backend`；进程下次启动时 `moonui_render_backend_resolve`
/// 读这份偏好（env `MOONUI_RENDER_BACKEND` 仍最高优先）。无头跑默认**不写**，
/// 只打印当前生效后端；要验证写入，带 `MOONUI_SET_BACKEND_PREF=metal` 跑。
fn backend_label(code : Int32) -> String {
  match code {
    2 => "Metal"
    1 => "CoreGraphics"
    _ => "自动（→CoreGraphics）"
  }
}

///|
fn pref_name(index : Int32) -> String {
  match index {
    2 => "metal"
    1 => "cg"
    _ => "auto"
  }
}

///|
fn main raise {
  let app = @common.new_app()
  let b = app.backend()
  let pick = @moonui.Widget::combobox(b, ["自动", "CoreGraphics", "Metal"])
  pick.set_selected(0)
  let status = @moonui.Widget::label(
    b,
    "当前生效后端：" +
    backend_label(@native-macos.render_backend_resolve()),
  )
  let save = @moonui.Widget::button(b, "保存（重启生效）")
  let _ = save.with_on_click(fn() raise @moonui.UiError {
    let name = pref_name(pick.selected())
    if @native-macos.set_render_backend_pref(name) {
      status.set_text("已保存 \{name}，重启后生效")
    } else {
      status.set_text("保存失败：写不了偏好文件")
    }
  })
  let root = @moonui.Widget::column(b, 16.0, [pick, save, status])
  let win = app.create_window(
    "渲染后端（T190 P0.5）",
    @moonui.LogicalSize(420.0, 220.0),
  )
  win.set_content(root)
  win.show()
  println("[Demo] 渲染后端切换")
  println(
    "  当前生效后端：" +
    backend_label(@native-macos.render_backend_resolve()),
  )
  // 无头默认不写偏好（不污染 $HOME）；带 env 时才写，供人工验证往返。
  match @env.get_env_var("MOONUI_SET_BACKEND_PREF") {
    Some(name) =>
      println(
        "  写入偏好 " +
        name +
        " → " +
        @native-macos.set_render_backend_pref(name).to_string(),
      )
    None =>
      println(
        "  （设 MOONUI_SET_BACKEND_PREF=metal/cg/auto 可验证写入）",
      )
  }
  app.quit()
  app.run()
}
