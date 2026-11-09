// `T239`：无头后端的平台能力实现落在 capability 包，不留在框架里。
//
// 为什么 impl 可以在这里：MoonBit 允许「trait 所在包」为**外部类型**写 impl
// （`/tmp` 最小探针实测；`moon check --deny-warn` 通过）。反过来不行——
// 给外部类型定义方法或 `extend` 都报 4059，所以下面 7 个读数/触发口是
// 自由函数，不是 `MockBackend::*` 方法；`App` 的三条转发同理（见 `app.mbt`）。
//
// 账本存在 Core 的通用脚本槽（`MockBackend::slot_*`）里：Core 只提供按 tag
// 存取的无语义容器，不解释 tag，也不解释载荷格式。这样框架公开面里连
// `tray_icon` / `now_playing_log` 这类名字都不再有。行为与 `T231` 时逐字一致。

///|
/// `T86⑥` 判据的调用账：托盘是进程级单例（不占句柄表），mock 只记快照。
pub impl PlatformServices for @moonui.MockBackend with fn set_tray_icon(
  self,
  name,
) -> Unit raise @moonui.UiError {
  self.ensure_initialized()
  self.set_slot_string("tray_icon", name)
}

///|
pub impl PlatformServices for @moonui.MockBackend with fn set_tray_menu(
  self,
  menu,
) -> Unit raise @moonui.UiError {
  self.ensure_initialized()
  self.set_slot_menu("tray_menu", menu)
  self.bump_slot("tray_installs")
}

///|
pub impl PlatformServices for @moonui.MockBackend with fn notify(
  self,
  title,
  body,
) -> Unit raise @moonui.UiError {
  self.ensure_initialized()
  self.push_slot_line("notify_log", "notify:" + title + "|" + body)
}

///|
/// `T181` 的三条（不 raise，与 trait 注一致）：mock 只记回调与流水，
/// init 与否都收——"没接"在 mock 里没有对应物，没有初始化检查那道门。
pub impl PlatformServices for @moonui.MockBackend with fn on_media_key(
  self,
  cb : (Int32) -> Unit,
) -> Unit {
  self.set_slot_callback("media_key_cb", cb)
}

///|
pub impl PlatformServices for @moonui.MockBackend with fn set_global_hotkeys(
  self,
  cb : (Int32) -> Unit,
) -> Unit {
  self.set_slot_callback("hotkey_cb", cb)
}

///|
pub impl PlatformServices for @moonui.MockBackend with fn set_now_playing(
  self,
  title : String,
  artist : String,
  elapsed_ms : Int64,
  duration_ms : Int64,
  playing : Bool,
) -> Unit {
  self.push_slot_line(
    "now_playing_log",
    "\{title}|\{artist}|\{elapsed_ms}|\{duration_ms}|\{if playing { 1 } else { 0 }}",
  )
}

// ---------------------------------------------------------------------------
// 读数 / 触发口：原来是 `MockBackend::*` 的 7 个方法，迁出后改自由函数。
// 名字与返回形状逐字保留，调用点只需换成 `@platform-services.xxx(b)`。
// ---------------------------------------------------------------------------

///|
/// 最后一次 `set_tray_icon` 收到的 stem（`T86⑥`），None = 没设过。
pub fn tray_icon(b : @moonui.MockBackend) -> String? {
  b.slot_string("tray_icon")
}

///|
/// 最后一次 `set_tray_menu` 收到的菜单快照（`T86⑥`），None = 没装过。
pub fn tray_menu(b : @moonui.MockBackend) -> @moonui.Menu? {
  b.slot_menu("tray_menu")
}

///|
/// `set_tray_menu` 被调用过几次。
pub fn tray_install_count(b : @moonui.MockBackend) -> Int32 {
  b.slot_count("tray_installs")
}

///|
/// `T86⑥` 判据的读数口：按投递顺序的通知流水，形如 `"notify:标题|正文"`。
pub fn notify_log(b : @moonui.MockBackend) -> Array[String] {
  b.slot_lines("notify_log")
}

///|
/// `T181` 判据的触发口：判定装上的媒体键回调，收命令码（0/1/2）。没装过
/// 是静默 no-op——与真后端"没接的平台回调永不触发"同一形态。
pub fn fire_media_key(b : @moonui.MockBackend, code : Int32) -> Unit {
  b.fire_slot_callback("media_key_cb", code)
}

///|
pub fn fire_hotkey(b : @moonui.MockBackend, code : Int32) -> Unit {
  b.fire_slot_callback("hotkey_cb", code)
}

///|
/// now-playing 推送流水（判据②的尺子）：`"标题|歌手|elapsed_ms|duration_ms|playing"`。
pub fn now_playing_log(b : @moonui.MockBackend) -> Array[String] {
  b.slot_lines("now_playing_log")
}

///|
/// `T86⑥` 判据（托盘/通知的 API 调用账）：原来住在 `packages/moonui/backend.mbt`，
/// `T239` 随能力一起迁到本包。托盘图标、托盘菜单按 stem/快照记账，通知按投递
/// 顺序记流水；未初始化的拒绝同既有语义。
test "托盘与通知的 API 调用账（T86⑥判据）" {
  let app = @moonui.App::new(@moonui.MockBackend::new())
  let b = app.backend()
  @moonui.Backend::init(b)
  let item = @moonui.MenuItem::new("退出")
  let _ = item.on(fn(_) { () })
  set_tray_icon(app, "moonui")
  set_tray_menu(
    app,
    @moonui.Menu::new("托盘", [
      @moonui.MenuNode::Item(item),
      @moonui.MenuNode::Separator,
    ]),
  )
  notify(app, "同步完成", "今天也是 42 个任务")
  assert_eq(tray_icon(b), Some("moonui"))
  assert_eq(tray_install_count(b), 1)
  match tray_menu(b) {
    Some(m) => {
      assert_eq(m.title(), "托盘")
      assert_eq(m.item_count(), 1)
    }
    None => fail("托盘菜单没有记账")
  }
  assert_eq(notify_log(b), ["notify:同步完成|今天也是 42 个任务"])
  // 未初始化的拒绝与既有读取同一条语义。
  @moonui.Backend::terminate(b)
  let msg = try {
    notify(app, "x", "y")
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(msg, Some("UI 初始化失败：Backend 尚未初始化"))
}
