///|
/// 音频文件字节级读写的 wasm 半（targets 控）：没有文件系统，结构性地缺席——
/// 显式报错，不假静默（§33）。与 `storage_wasm.mbt` 同一条账。
pub fn file_read_bytes(path : String) -> Bytes? raise @moonui.UiError {
  let _ = path
  raise @moonui.Unsupported(
    "wasm 目标没有文件系统，读不到音频文件",
  )
}

///|
pub fn file_write_bytes_atomic(
  path : String,
  data : Bytes,
) -> Unit raise @moonui.UiError {
  let _ = path
  let _ = data
  raise @moonui.Unsupported(
    "wasm 目标没有文件系统，写不回音频标签",
  )
}
