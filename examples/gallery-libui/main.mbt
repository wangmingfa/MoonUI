///|
/// 组件画册跑在真窗口上（§49 第六个 Demo 的真后端半）。
///
/// `moon run examples/gallery-libui` 开一只 960x480 的画册窗：
/// 左栏点按钮换组件页，右栏同时给示例代码与真控件；关窗口退出。
/// 代码与 ../gallery-native（原生直写后端）逐行同构——换掉的只有底下的 C
/// （libui-ng 一份 adapter，prebuild 按宿主挑平台实现），MoonBit 侧一行不差，
/// 这正是 §47 风险 6 要验证的形状。
///
/// 换页走 Window::set_content 整树重建，交互状态存在 Gallery 结构体上，
/// 所以这一侧没有额外的事件订阅要配——侧栏按钮的 on_click 在
/// packages/moonui/gallery.mbt 里就绑好了。

///|
fn main raise {
  let b = @libui-common.LibuiBackend::new()
  b.init()
  let app = @moonui.App::new(b)
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
  println(
    "  残留原生对象：" + @libui-common.native_live_handles().to_string(),
  )
}
