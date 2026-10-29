///|
/// 曲库档落盘的 wasm 半（targets 门控）：没有文件系统，结构性地缺席——
/// 显式报错，不假静默（§33）。真窗壳是 native-only，永远走不到这半。
pub fn library_save(
  path : String,
  content : String,
) -> Unit raise @moonui.UiError {
  // cm_cstr 过一遍编码：让 utf8 依赖在两个目标上都有真实消费点
  // （moonui 的 cstr 布局同款理由），编码结果本身在这个半边用不上。
  let _ = cm_cstr(path)
  let _ = content
  raise @moonui.Unsupported(
    "wasm 目标没有文件系统，曲库档不可用",
  )
}

///|
pub fn library_load(path : String) -> String? raise @moonui.UiError {
  let _ = path
  raise @moonui.Unsupported(
    "wasm 目标没有文件系统，曲库档不可用",
  )
}

///|
pub fn load_lyric_text(path : String) -> String? raise @moonui.UiError {
  // 与 library_load 同一条账：wasm 半没有文件系统，结构性地缺席，显式报错。
  let _ = path
  raise @moonui.Unsupported(
    "wasm 目标没有文件系统，歌词档不可用",
  )
}

///|
pub fn save_lyric_text(
  path : String,
  text : String,
) -> Unit raise @moonui.UiError {
  // 同上：没有文件系统，显式缺席。
  let _ = path
  let _ = text
  raise @moonui.Unsupported(
    "wasm 目标没有文件系统，歌词缓存写不出去",
  )
}

///|
pub fn library_remove(path : String) -> Unit {
  let _ = path
}
