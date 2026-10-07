///|
/// 剪贴板门面（设计文档 §23）。
///
/// 和对话框一样：§23 的 `Clipboard::get_text()` 全局形态需要一个编译期可确定的后端，
/// 所以这里挂在 App 上。`get_image` / `set_image` 是文档里明说的"以后"，
/// 不在 0.1 预留空接口。

///|
/// 读文本剪贴板；内容为空或非文本时返回 `None`。
pub fn[B : Backend] App::clipboard_text(self : App[B]) -> String? raise UiError {
  Backend::clipboard_text(self.backend)
}

///|
/// 写文本剪贴板（UTF-8，§29）。
pub fn[B : Backend] App::set_clipboard_text(
  self : App[B],
  text : String,
) -> Unit raise UiError {
  Backend::set_clipboard_text(self.backend, text)
}

///|
test "剪贴板读写穿过 Backend（§23）" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  assert_eq(app.clipboard_text(), None)
  app.set_clipboard_text("复制这段")
  assert_eq(app.clipboard_text(), Some("复制这段"))
  app.set_clipboard_text("覆盖一次")
  assert_eq(app.clipboard_text(), Some("覆盖一次"))
}
