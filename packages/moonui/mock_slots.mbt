// `T239`（2026-11-08）：无头后端的**通用脚本槽**。
//
// 由来：平台能力（托盘 / 通知 / 媒体键 / 全局热键 / Now Playing）原先在
// `MockBackend` 里各占一组专用字段和读数方法，`packages/moonui` 的公开面
// 因此躺着音乐播放器语义。`T239` 把那些能力整体迁到独立包
// `packages/platform-services`，本文件留下的是**不含任何应用语义**的底座：
// 五张按 tag 索引的槽，Core 不解释 tag、不解释载荷格式，也不承诺有哪些
// capability 会来注册。可选能力包在自己的 impl 里决定 tag 与日志格式。
//
// 这层是 `T197` / `T198` / `T199` 那种「通用能力上移」的正例：无头后端要能
// 替任何可选能力记账，机制只有一份；与「把应用专属方法塞进 Backend」是
// 相反的两件事。判据仍由能力包持有（`packages/platform-services/mock.mbt`）。

///|
/// 初始化检查的公开读数口：能力包的 impl 要和 `Backend` 的其它实现走同一道
/// 门（未初始化时拒绝）。包装一层而不复制判断，口径只有一处。
pub fn MockBackend::ensure_initialized(
  self : MockBackend,
) -> Unit raise UiError {
  self.check_initialized()
}

///|
pub fn MockBackend::set_slot_string(
  self : MockBackend,
  tag : String,
  value : String,
) -> Unit {
  self.slot_strings.set(tag, value)
}

///|
pub fn MockBackend::slot_string(self : MockBackend, tag : String) -> String? {
  self.slot_strings.get(tag)
}

///|
pub fn MockBackend::set_slot_menu(
  self : MockBackend,
  tag : String,
  menu : Menu,
) -> Unit {
  self.slot_menus.set(tag, menu)
}

///|
pub fn MockBackend::slot_menu(self : MockBackend, tag : String) -> Menu? {
  self.slot_menus.get(tag)
}

///|
pub fn MockBackend::bump_slot(self : MockBackend, tag : String) -> Unit {
  match self.slot_counts.get(tag) {
    Some(n) => self.slot_counts.set(tag, n + 1)
    None => self.slot_counts.set(tag, 1)
  }
}

///|
pub fn MockBackend::slot_count(self : MockBackend, tag : String) -> Int32 {
  match self.slot_counts.get(tag) {
    Some(n) => n
    None => 0
  }
}

///|
pub fn MockBackend::push_slot_line(
  self : MockBackend,
  tag : String,
  line : String,
) -> Unit {
  match self.slot_logs.get(tag) {
    Some(xs) => xs.push(line)
    None => self.slot_logs.set(tag, [line])
  }
}

///|
pub fn MockBackend::slot_lines(
  self : MockBackend,
  tag : String,
) -> Array[String] {
  match self.slot_logs.get(tag) {
    Some(xs) => xs
    None => []
  }
}

///|
pub fn MockBackend::set_slot_callback(
  self : MockBackend,
  tag : String,
  cb : (Int32) -> Unit,
) -> Unit {
  self.slot_callbacks.set(tag, cb)
}

///|
/// 触发已装回调；没装过是静默 no-op（与真后端「没接的平台回调永不触发」
/// 同一形态）。
pub fn MockBackend::fire_slot_callback(
  self : MockBackend,
  tag : String,
  code : Int32,
) -> Unit {
  match self.slot_callbacks.get(tag) {
    Some(cb) => cb(code)
    None => ()
  }
}
