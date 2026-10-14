///|
/// 组件画册跑在**原生 Cocoa 后端**上（设计文档 §51 的 Backend #2，macOS 半，FP2）。
///
/// `moon run examples/gallery-native-macos` 开一只 960x640 的画册窗（左/右栏超出视口的部分由真滚动条滚到，T74）：
/// 左栏是 macOS 设置那种"一行一项"的扁平菜单（MenuRow，选中高亮），点一项换右栏；
/// 右栏同时给示例代码与真控件；关窗口退出。
///
/// 代码与 ../gallery-native（libui-ng 后端）逐行同构——换掉的只有底下的 C
/// （@native-common 直写 AppKit，不经过 libui-ng），MoonBit 侧一行不差，
/// 这正是 §47 风险 6 要验证的形状。
///
/// 换页走 Window::set_content 整树重建，交互状态存在 Gallery 结构体上，
/// 所以这一侧没有额外的事件订阅要配——侧栏菜单行的 on_click 在
/// packages/moonui/gallery.mbt 里就绑好了。
///
/// 图标（T76）：stem 交给 C，那边补 `.png` 喂给 [NSApp setApplicationIconImage:]
/// ——Dock、Cmd-Tab、窗口代理图标都从它来。

///|
fn main raise {
  let b = @native-common.NativeBackend::new()
  b.init()
  let app = @moonui.App::new(b)
  app.set_icon("assets/logo/moonui")
  let g = @moonui.Gallery::demo(app)
  println(
    "真窗口已打开（原生 Cocoa 后端）：左栏选组件、右栏看代码与效果，关窗口退出",
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
    "  残留原生对象：" + @native-common.native_live_handles().to_string(),
  )
}
