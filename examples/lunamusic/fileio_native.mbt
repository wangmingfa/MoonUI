///|
/// 音频文件的字节级读写（native 目标限定，moon.pkg targets 控）。
///
/// 与 `storage_native.mbt` 同一批 libc stdio extern（同包内 `extern "c" fn`
/// 重名会撞，所以这里只补 `rename`，其余复用）。
///
/// **为什么不复用 `library_load`**：它走 `@utf8.decode_lossy`，会把标签里的
/// 封面等二进制字节替换成 U+FFFD，写回去就毁文件。这里必须原样搬运字节。

///|
#borrow(old, new)
extern "c" fn c_rename(old : Bytes, new : Bytes) -> Int32 = "rename"

///|
/// 把 path 上的文件整份读成字节。文件不存在返回 None（不是错误）。
pub fn file_read_bytes(path : String) -> Bytes? raise @moonui.UiError {
  let f = c_fopen(cm_cstr(path), cm_cstr("rb"))
  if f == 0 {
    return None
  }
  let _ = c_fseek(f, 0, 2)
  let len = c_ftell(f)
  let ok : Bytes? = if len <= 0 {
    None
  } else {
    c_rewind(f)
    let buf = Bytes::make(len.to_int(), 0)
    let got = c_fread(buf, 1, len, f)
    if got != len {
      None
    } else {
      Some(buf)
    }
  }
  let closed = c_fclose(f)
  if closed != 0 {
    raise @moonui.OperationFailed("音频文件关闭失败：\{path}")
  }
  ok
}

///|
/// 原子地把 data 写进 path：先写 `path.lunatmp`，再 `rename` 覆盖。
///
/// **为什么必须原子**：macOS 侧的 `AVAudioPlayer` 在播放期间一直持有这个文件。
/// 原地截断再写会让正在播的那首当场读出错位字节甚至静音。POSIX 的 `rename`
/// 是原子替换——旧 inode 由播放器继续持有、新 inode 接到文件名上，两边都不坏。
///
/// Windows 注记：CRT 的 `rename` 不覆盖已存在的目标，退化成
/// `remove(目标)` + `rename`，**这一步不原子**（中间有一个目标不存在的窗口）。
/// 目前 Windows 半的音频探针还是空实现（`adapter_native.c:10145`），
/// 整条链路在那边本来就不可用，等补探针时一起处理。
pub fn file_write_bytes_atomic(
  path : String,
  data : Bytes,
) -> Unit raise @moonui.UiError {
  let tmp = "\{path}.lunatmp"
  let f = c_fopen(cm_cstr(tmp), cm_cstr("wb"))
  if f == 0 {
    raise @moonui.OperationFailed("临时文件打不开（写）：\{tmp}")
  }
  let written = c_fwrite(data, 1, data.length().to_int64(), f)
  let closed = c_fclose(f)
  if written != data.length().to_int64() || closed != 0 {
    let _ = c_remove(cm_cstr(tmp))
    raise @moonui.OperationFailed("临时文件没写完整：\{tmp}")
  }
  if c_rename(cm_cstr(tmp), cm_cstr(path)) != 0 {
    // Windows 侧的退化路径：先删目标再改名（不原子，见上面的注记）。
    let _ = c_remove(cm_cstr(path))
    if c_rename(cm_cstr(tmp), cm_cstr(path)) != 0 {
      let _ = c_remove(cm_cstr(tmp))
      raise @moonui.OperationFailed("改名失败：\{tmp} → \{path}")
    }
  }
}
