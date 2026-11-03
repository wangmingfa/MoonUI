///|
/// 文件能力的缺席半（`T197`，wasm 目标限定——见 moon.pkg 的 targets 门控）。
///
/// wasm 没有文件系统，与 `window_state_file_wasm.mbt` 同一套口径：同签名、
/// 显式报 `Unsupported`（§33——不支持的能力报明确错误，不静默装作成功）。
///
/// 两个返回布尔的删/改名不 raise（它们的门面本来就不 raise）：在 wasm 上恒
/// `false`，调用方按布尔决定要不要在意。写路径会先撞上 `fs_write_bytes` 的
/// `Unsupported`，所以这里不会出现"以为自己写成功了"的假象。

///|
fn fs_read_bytes(path : String) -> Bytes? raise UiError {
  let _ = path
  raise Unsupported("文件读取在 wasm 侧不可用（无文件系统）")
}

///|
fn fs_write_bytes(path : String, data : Bytes) -> Unit raise UiError {
  let _ = path
  let _ = data
  raise Unsupported("文件写入在 wasm 侧不可用（无文件系统）")
}

///|
fn fs_read_text(path : String) -> String? raise UiError {
  let _ = path
  raise Unsupported("文件读取在 wasm 侧不可用（无文件系统）")
}

///|
fn fs_remove(path : String) -> Bool {
  let _ = path
  false
}

///|
fn fs_rename(old : String, new : String) -> Bool {
  let _ = old
  let _ = new
  false
}

///|
/// 判据：wasm 档上文件读写必须是**显式**缺席（不是静默返回 None）。
test "Fs：wasm 档显式缺席（T197）" {
  let path = "moonui_fs_wasm_probe.txt"
  let read_err = try {
    let _ = Fs::read_text(path)
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(
    read_err,
    Some(
      "不支持的操作：文件读取在 wasm 侧不可用（无文件系统）",
    ),
  )
  let write_err = try {
    Fs::write_text_atomic(path, "x")
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(
    write_err,
    Some(
      "不支持的操作：文件写入在 wasm 侧不可用（无文件系统）",
    ),
  )
  assert_false(Fs::remove(path))
}
