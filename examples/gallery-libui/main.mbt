///|
/// 组件画册跑在真窗口上（§49 第六个 Demo 的真后端半）。
///
/// `moon run examples/gallery-libui` 开一只 960x480 的画册窗：
/// 左栏点按钮换组件页，右栏同时给示例代码与真控件；关窗口退出。
/// 代码与 ../gallery-native（原生直写后端）逐行同构——两壳的后端都经
/// packages/moonui-app 的前台门拿，main.mbt 除了枚举值（Backend::Libui 对
/// Backend::Native）一行不差，这正是 §47 风险 6 要验证的形状。
///
/// 换页走 Window::set_content 整树重建，交互状态存在 Gallery 结构体上，
/// 所以这一侧没有额外的事件订阅要配——侧栏按钮的 on_click 在
/// packages/moonui/gallery.mbt 里就绑好了。

///|
fn main raise {
  // 前台门（packages/moonui-app）：构造 + init + App::new 三步包成一步，
  // 本壳从此不 import 后端包——换后端只换枚举值，见 ../gallery-native。
  let app = @moonui-app.new_app(backend=@moonui-app.Backend::Libui)
  // §26：stem 不带扩展名，mac 补 .png、Windows 补 .ico，两侧共用这一行
  app.set_icon("assets/logo/moonui")
  let g = @moonui.Gallery::demo(app)
  println(
    "真窗口已打开：左栏选组件、右栏看代码与效果，关窗口退出",
  )
  println("  目录：" + @common.join(@moonui.Gallery::section_names(), " / "))
  println(
    "  客户区 " +
    g.window().size().width.to_string() +
    "x" +
    g.window().size().height.to_string() +
    " 逻辑像素，缩放 " +
    g.window().scale().x.to_string(),
  )
  app.run()
  println(
    "循环结束：停在 " +
    @moonui.Gallery::section_names()[g.current()] +
    "，按钮累计点击 " +
    g.click_count().to_string() +
    " 次",
  )
}
