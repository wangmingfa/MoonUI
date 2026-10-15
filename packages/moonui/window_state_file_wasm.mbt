///|
/// 窗口存档的落盘半（`T86⑦`，wasm 目标限定——见 moon.pkg 的 targets 门控）。
///
/// 与 window_state_file_native.mbt 同签名的显式缺席半：wasm 没有文件系统，
/// 落盘两半都报 `Unsupported`（§33——不支持的能力报明确错误，不静默装作
/// 成功）。几何/序列化那半条（`window_frame` / `frame_to_json` /
/// `create_window_restored`）不在这里——它们与文件无关，wasm 照常可用，
/// Mock 往返判据在那一半上闭环。
fn archive_write(path : String, content : String) -> Unit raise UiError {
  let _ = path
  let _ = content
  raise Unsupported("窗口存档在 wasm 侧不可用（无文件系统）")
}

///|
fn archive_read(path : String) -> String? raise UiError {
  let _ = path
  raise Unsupported("窗口存档在 wasm 侧不可用（无文件系统）")
}
