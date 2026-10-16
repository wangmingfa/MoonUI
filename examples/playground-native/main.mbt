///|
/// Playground 的真窗口版（[Demo 10]）：同一份 Demo 本体（库
/// `demo_playground.mbt`）换真后端——左树右面板真控件，关窗口才退出。
/// 与 gallery-native 同款不进任何自动闸门（ci-packages.sh 按 -native 后缀
/// 排除；判据全在无头壳与库侧测试上闭环）。
///
/// 面板行的接线随重建自挂（build_panel 每次重建都挂真事件），真窗上改值→
/// 重建一直活着；内容树的真点击选中需要"重建后重挂命中订阅"的钩子（面板
/// 接线随树幸存、内容树的不随——库头注记案），第一版选中走无头判据与
/// `select_at` 程序 API，真窗上程序选中演示一次面板读回。
fn main raise {
  // 前台门（packages/moonui-app）：new_app() 三步糖（T82 后直接返回
  // App[NativeBackend]）——本壳不 import 后端包。
  let app = @moonui-app.new_app()
  app.set_icon("assets/logo/moonui")
  let demo = @moonui.PlaygroundDemo::demo(app, @moonui.PLAYGROUND_DEFAULT_DESC)
  println(
    "真窗口已打开（原生后端）：左树右面板，关窗口退出",
  )
  println(
    "  右半面板的控件接线随重建自挂——面板改值→描述变→整棵重建，真控件即时重渲染",
  )
  println(
    "  内容树的真点击选中第一版走 select_at 程序 API（重建钩子等真需求，见库头注）——程序选中演示一次：",
  )
  match demo.window().content() {
    None => println("  ！没有内容树")
    Some(root) => {
      let btn = root.children()[0].children()[1].children()[0]
      let f = btn.frame()
      demo.select_at(@moonui.LogicalPoint(f.origin.x + 1.0, f.origin.y + 1.0))
      for row in demo.panel_rows() {
        println("    " + row)
      }
    }
  }
  app.run()
  println("循环结束：Playground 关窗退场")
}
