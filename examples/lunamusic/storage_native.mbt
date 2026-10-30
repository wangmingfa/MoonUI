///|
/// 曲库档的落盘半（native 目标限定，moon.pkg targets 门控）。
/// 零 C 源：extern 直指 libc stdio（fopen/fwrite/fread/fclose/remove），
/// 完全照 `packages/moonui/window_state_file_native.mbt` 的先例（`T86⑦`）。
///
/// 平台注记照抄：CRT 家族 fopen 按 ANSI 码页解路径（Windows 半不含 UTF-8），
/// 非 ASCII 路径档不进判据（这条缺口记在 `T189`）。
///
/// **模式串一律带 `b`**（`T112`② 2026-10-22 在 `packages/moonui` 那半修过一次，
/// lunamusic 这份是同一个写法、`T188` 2026-10-30 补上）：Windows 文本档的
/// `ftell` 报**物理**字节数（`\n` 落盘成 `\r\n`）、`fread` 报**翻译后**的逻辑
/// 字符数，两边对不上会被 `library_load` 判成"没读完"返回 `None`——曲库档每次
/// 启动都读回空库。二进制模式两清；POSIX 侧 `b` 是无操作的同义词。

///|
#borrow(path, mode)
extern "c" fn c_fopen(path : Bytes, mode : Bytes) -> Int64 = "fopen"

///|
extern "c" fn c_fclose(f : Int64) -> Int32 = "fclose"

///|
#borrow(buf)
extern "c" fn c_fwrite(
  buf : Bytes,
  size : Int64,
  nmemb : Int64,
  f : Int64,
) -> Int64 = "fwrite"

///|
#borrow(buf)
extern "c" fn c_fread(
  buf : Bytes,
  size : Int64,
  nmemb : Int64,
  f : Int64,
) -> Int64 = "fread"

///|
extern "c" fn c_fseek(f : Int64, off : Int64, whence : Int32) -> Int32 = "fseek"

///|
extern "c" fn c_ftell(f : Int64) -> Int64 = "ftell"

///|
extern "c" fn c_rewind(f : Int64) -> Unit = "rewind"

///|
#borrow(path)
extern "c" fn c_remove(path : Bytes) -> Int32 = "remove"

///|
// cm_cstr 在门控无关的 shared.mbt：wasm 也消费它，免 unused_package 假警报。

///|
/// 把整份曲库档写进 path。打不开/没写完都是显式错误（§33），半份档不许存在。
pub fn library_save(
  path : String,
  content : String,
) -> Unit raise @moonui.UiError {
  let f = c_fopen(cm_cstr(path), cm_cstr("wb"))
  if f == 0 {
    raise @moonui.OperationFailed("曲库档打不开（写）：\{path}")
  }
  // 内容走 `cm_utf8` 而不是 `cm_cstr`：`c_fwrite` 显式传长度，尾巴多一个 NUL
  // 就成了档里的一个真字节，JSON 解析当场坏掉。
  let bytes = cm_utf8(content)
  let written = c_fwrite(bytes, 1, bytes.length().to_int64(), f)
  let closed = c_fclose(f)
  if written != bytes.length().to_int64() || closed != 0 {
    raise @moonui.OperationFailed("曲库档没写完整：\{path}")
  }
}

///|
/// 把 path 上的曲库档整份读出来。文件不存在返回 None（第一次启动常态）。
pub fn library_load(path : String) -> String? raise @moonui.UiError {
  let f = c_fopen(cm_cstr(path), cm_cstr("rb"))
  if f == 0 {
    return None
  }
  let _ = c_fseek(f, 0, 2)
  let len = c_ftell(f)
  let ok : String? = if len <= 0 {
    None
  } else {
    c_rewind(f)
    let buf = Bytes::make(len.to_int(), 0)
    let got = c_fread(buf, 1, len, f)
    if got != len {
      None
    } else {
      Some(@utf8.decode_lossy(buf.exact_view()))
    }
  }
  let closed = c_fclose(f)
  if closed != 0 {
    raise @moonui.OperationFailed("曲库档关闭失败：\{path}")
  }
  ok
}

///|
/// 读 .lrc 歌词文本（与 library_load 同一条 libc 落盘半，仅文件名不同）。
/// 文件缺失返回 None（无歌词是常态，不报错）。
pub fn load_lyric_text(path : String) -> String? raise @moonui.UiError {
  library_load(path)
}

///|
/// 写 .lrc 歌词文本（在线取词的缓存落盘，`T159`②）。与 `library_save` 同一条
/// libc 半：写不完整就 raise，不留半份档。
pub fn save_lyric_text(
  path : String,
  text : String,
) -> Unit raise @moonui.UiError {
  library_save(path, text)
}

///|
/// 测试自产自销的清档口。
pub fn library_remove(path : String) -> Unit {
  let _ = c_remove(cm_cstr(path))
}
