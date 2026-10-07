///|
/// 对话框门面（设计文档 §24）。
///
/// 文档写的是 `Dialog::confirm("Delete this file?")` 这种全局形态，但当前 MoonBit
/// 版本的 trait 不是类型、也没有 `dyn`，后端只能在编译期随 `App[B]` 确定，所以对话框
/// 挂在 App 上：`app.confirm(...)`。语义不变——同步返回用户的选择，因此只应在事件
/// 循环内（handler 或 `post` 的任务）调用，不要在 `run()` 之前抢弹窗。

///|
/// 只有"确定"按钮的提示框（§24 的 `Dialog::message`）。
pub fn[B : Backend] App::show_message(
  self : App[B],
  title : String,
  text : String,
) -> Unit raise UiError {
  Backend::show_message(self.backend, title, text)
}

///|
/// 确认框：`true` 表示用户选"是"。
/// 取消和失败是两条不同的路——取消返回 `false`，后端出错一律 `raise`，不混在一起。
pub fn[B : Backend] App::confirm(
  self : App[B],
  title : String,
  text : String,
) -> Bool raise UiError {
  Backend::confirm(self.backend, title, text)
}

///|
/// 选文件，用户取消时 `None`（§24）。
pub fn[B : Backend] App::open_file(
  self : App[B],
  title : String,
) -> String? raise UiError {
  Backend::open_file(self.backend, title)
}

///|
/// 定保存路径，`default_name` 是后端填给用户的初始文件名。
pub fn[B : Backend] App::save_file(
  self : App[B],
  title : String,
  default_name : String,
) -> String? raise UiError {
  Backend::save_file(self.backend, title, default_name)
}

///|
pub fn[B : Backend] App::select_folder(
  self : App[B],
  title : String,
) -> String? raise UiError {
  Backend::select_folder(self.backend, title)
}

///|
fn dialog_app() -> (App[MockBackend], MockBackend) raise UiError {
  let b = MockBackend::new()
  Backend::init(b)
  (App::new(b), b)
}

///|
test "对话框穿过 Backend，应答由脚本决定（§24）" {
  let (app, b) = dialog_app()
  app.show_message("MoonUI", "已保存")
  b.push_confirm_reply(true)
  assert_true(app.confirm("删除", "确定删除这个文件吗？"))
  b.push_path_reply(Some("D:/data/notes.txt"))
  assert_eq(app.open_file("打开文件"), Some("D:/data/notes.txt"))
  b.push_path_reply(None)
  assert_eq(app.save_file("保存文件", "notes.txt"), None)
  // 脚本用完之后仍然是"取消"，不会卡住 headless 测试
  assert_eq(app.select_folder("选择目录"), None)
  assert_eq(b.dialog_requests(), [
    "message:MoonUI|已保存", "confirm:删除|确定删除这个文件吗？",
    "open:打开文件", "save:保存文件|notes.txt", "folder:选择目录",
  ])
  assert_eq(b.pending_dialog_replies(), 0)
}

///|
test "Backend 未初始化时对话框直接失败，不静默返回默认值" {
  let app = App::new(MockBackend::new())
  let msg = try {
    let _ = app.confirm("x", "y")
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("UI 初始化失败：Backend 尚未初始化"))
}
