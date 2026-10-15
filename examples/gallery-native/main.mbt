///|
/// 组件画册跑在**原生后端**上（设计文档 §51 的 Backend #2：macOS 直写 AppKit、
/// Windows 直写 Win32，平台分叉只在 C，见 prebuild-link.js 按宿主选的那份 adapter）。
///
/// `moon run examples/gallery-native` 开一只 960x480 的画册窗（左/右栏超出视口
/// 的部分由真滚动条滚到，T74）：左栏是 macOS 设置那种"一行一项"的扁平菜单
/// （MenuRow，选中高亮——Windows 半先落标准按钮的形状，T77），点一项换右栏；
/// 右栏同时给示例代码与真控件；关窗口退出。
///
/// 后端经 packages/moonui-app 的前台门拿（`T82` 删 libui 收敛单后端之后，
/// 前台门是 `new_app()` 一个三步糖，直接返回 `App[NativeBackend]`）。
///
/// 换页走 Window::set_content 整树重建，交互状态存在 Gallery 结构体上，
/// 所以这一侧没有额外的事件订阅要配——侧栏菜单行的 on_click 在
/// packages/moonui/gallery.mbt 里就绑好了。
///
/// 图标（T76）：stem 交给 C，macOS 那半补 `.png` 喂 [NSApp
/// setApplicationIconImage:]，Windows 那半补 `.ico` 走 LoadImageW。

///|
fn main raise {
  // 前台门（packages/moonui-app）：构造 + init + App::new 三步包成一步，
  // 本壳从此不 import 后端包。
  let app = @moonui-app.new_app()
  app.set_icon("assets/logo/moonui")
  let g = @moonui.Gallery::demo(app)
  println(
    "真窗口已打开（原生后端）：左栏选组件、右栏看代码与效果，关窗口退出",
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
