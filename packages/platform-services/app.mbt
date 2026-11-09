// `T239`：这三条转发原来住在 `packages/moonui/app.mbt`，随平台能力一起迁出。
//
// 形态从 `App::xxx(...)` 方法改成自由函数，原因是 MoonBit 不允许给外部包的
// 类型定义方法（4059）。`App::backend()` 是 Core 已有的公开读数口，所以
// 转发不需要给 Core 加任何新 API；调用点写
// `@platform-services.set_tray_icon(app, name)`。
//
// 约束仍是 `B : PlatformServices`（子 trait 自动带上 `Backend` 的 87 个方法），
// 没实现平台能力的后端连这些函数都调不了——编译期事实。

///|
/// 系统托盘图标（`T86⑥`）：参数沿 `set_icon` 的 stem 约定（平台各自补
/// `.png`/`.ico`）。托盘是进程级单例，一个应用一只，不占句柄表。
pub fn[B : PlatformServices] set_tray_icon(
  app : @moonui.App[B],
  name : String,
) -> Unit raise @moonui.UiError {
  PlatformServices::set_tray_icon(app.backend(), name)
}

///|
/// 系统托盘菜单（`T86⑥`）：整份替换（与 `set_menubar` 同一条重建语义）。
/// 选中的语义同上下文菜单——同步解析，勾选态改在 Core、回调当场跑（`T86⑥`
/// 落地注记）。点击动作/气泡的第一版不做。
pub fn[B : PlatformServices] set_tray_menu(
  app : @moonui.App[B],
  menu : @moonui.Menu,
) -> Unit raise @moonui.UiError {
  PlatformServices::set_tray_menu(app.backend(), menu)
}

///|
/// 系统通知（`T86⑥`）：投出去即返回，投递本身是异步的；点击动作第一版不做。
pub fn[B : PlatformServices] notify(
  app : @moonui.App[B],
  title : String,
  body : String,
) -> Unit raise @moonui.UiError {
  PlatformServices::notify(app.backend(), title, body)
}
