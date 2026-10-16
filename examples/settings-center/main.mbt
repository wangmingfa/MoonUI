///|
/// `T88④` 第一个验证性示例：设置中心。验证的地基是 `T86⑦` 持久化闭环——
/// 表单档四种控件、浅深主题切换的真语义（App 底样式跟上）、`T87③` 偏好档、
/// `T85①` 异步档，最后用 `T88①` 的句柄统计读数收尾（live 归零 + 峰值还在）。
/// 判据测试在包里的黑盒判据（dx_demo_test.mbt）加落盘文件半（native 门控），
/// 这里是给人跑的无头演示。
fn main raise {
  let app = @common.new_app()
  let demo = @moonui.SettingsDemo::demo(app, @moonui.LogicalSize(800.0, 600.0))
  println("[Demo 7] 设置中心")
  println(
    "  表单档默认账：用户名「" +
    demo.username_text() +
    "」 通知 " +
    demo.notify_checked().to_string() +
    " 引擎 " +
    demo.engine_selected().to_string() +
    " 渠道 " +
    demo.channel_selected().to_string(),
  )
  demo.set_username("明")
  demo.set_notify(true)
  demo.set_engine(1)
  demo.set_channel(1)
  demo.set_theme_choice(@moonui.Theme::Dark)
  demo.set_reduced_motion(true)
  let theme_text = match demo.theme() {
    @moonui.Theme::Light => "浅色"
    @moonui.Theme::Dark => "深色"
    @moonui.Theme::System => "跟随系统"
  }
  println(
    "  切换后：主题 " +
    theme_text +
    " 偏好(reduced-motion) " +
    demo.reduced_motion().to_string(),
  )
  // 几何改了再快照——持久化闭环的读数半（存档半在判据的文件半上闭环）
  demo.window().set_size(@moonui.LogicalSize(1024.0, 768.0))
  demo.window().set_position(@moonui.LogicalPoint(40.0, 60.0))
  match app.window_frame() {
    Some(f) =>
      println(
        "  快照：" +
        f.width.to_string() +
        "x" +
        f.height.to_string() +
        " @" +
        f.x.to_string() +
        "," +
        f.y.to_string() +
        " 最大化 " +
        f.maximized.to_string(),
      )
    None => println("  快照：无")
  }
  // 异步档：post_task 一圈落状态行（T85① 的可用性演示）
  let _ = demo.refresh_async()
  let _ = app.step()
  println("  异步档：" + demo.status_text())
  app.quit()
  app.run()
  let b = app.backend()
  let stats = b.handle_stats()
  println(
    "  退出句柄统计：live=" +
    stats.live.to_string() +
    " 峰值=" +
    stats.high_water.to_string() +
    "（归零读数 + 高水位——T88① 的泄漏检查两只读数）",
  )
}
