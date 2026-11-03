///|
/// 文件能力的落盘半（`T197`，native 目标限定——见 moon.pkg 的 targets 门控）。
///
/// 零 C 的实现口径照 `T86⑦`：这里只有 MoonBit 侧的 `extern` 声明，符号直接指向
/// libc 的 stdio（fopen/fwrite/fread/fclose/remove/rename）——没有新增 C 源、
/// 没有动 Backend trait、没有动两份 adapter。这是 Core 自己的文件账，不经过后端。
///
/// 平台注记（`T189` 的老账，不在这一轮）：CRT 家族的 fopen 按 ANSI 码页解路径，
/// 非 ASCII 路径在 Windows 半打不开；宽字符家族（`_wfopen`）是 Windows 独有
/// 符号，没法与 mac 共用同一份声明。
///
/// **模式串一律带 `b`**（`T112`②）：Windows 文本档的 `ftell` 报物理字节数
/// （`\n` 落盘成 `\r\n`）、`fread` 报翻译后的逻辑字符数，两边对不上会被判成
/// "没读完"；二进制模式两清，POSIX 侧 `b` 是无操作的同义词。

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
/// whence 的 `SEEK_END`（stdio.h 里就是 2，直接写数值——不为一个常量拉头文件）。
extern "c" fn c_fseek(f : Int64, off : Int64, whence : Int32) -> Int32 = "fseek"

///|
extern "c" fn c_ftell(f : Int64) -> Int64 = "ftell"

///|
extern "c" fn c_rewind(f : Int64) -> Unit = "rewind"

///|
#borrow(path)
extern "c" fn c_remove(path : Bytes) -> Int32 = "remove"

///|
#borrow(old, new)
extern "c" fn c_rename(old : Bytes, new : Bytes) -> Int32 = "rename"

///|
/// 把 path 上的整份内容读成字节。文件不存在返回 `None`（不是错误）；
/// 存在但读不完整是显式错误——半份内容读出来只会让上层解析出一堆垃圾。
fn fs_read_bytes(path : String) -> Bytes? raise UiError {
  let f = c_fopen(cstr(path), cstr("rb"))
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
    raise OperationFailed("文件关闭失败：\{path}")
  }
  ok
}

///|
/// 把整份字节写进 path（**非原子**，原子版本在门面 `fs.mbt` 的
/// `fs_write_atomic` 里做 tmp + rename）。打不开/没写完都是显式错误（§33）。
fn fs_write_bytes(path : String, data : Bytes) -> Unit raise UiError {
  let f = c_fopen(cstr(path), cstr("wb"))
  if f == 0 {
    raise OperationFailed("文件打不开（写）：\{path}")
  }
  let written = c_fwrite(data, 1, data.length().to_int64(), f)
  let closed = c_fclose(f)
  if written != data.length().to_int64() || closed != 0 {
    raise OperationFailed("文件没写完整：\{path}")
  }
}

///|
/// 文本读：字节通道 + 宽容解码。用 `decode_lossy` 而不是 `decode`，是因为
/// 用户给的文本档可能是 GBK 之类（`T193` 见过伪装成 Latin-1 的标签），
/// 整份读失败会把"能救回来的大部分内容"一起扔掉。
fn fs_read_text(path : String) -> String? raise UiError {
  match fs_read_bytes(path) {
    None => None
    Some(buf) => Some(@utf8.decode_lossy(buf.exact_view()))
  }
}

///|
/// 删文件；不存在返回 `false`（清理路径上的常态，不是错误）。
fn fs_remove(path : String) -> Bool {
  c_remove(cstr(path)) == 0
}

///|
/// 改名（同目录内即原子替换）。
fn fs_rename(old : String, new : String) -> Bool {
  c_rename(cstr(old), cstr(new)) == 0
}

///|
/// 判据：文本往返 + 缺档缺席 + **字节通道不吃 UTF-8 解码**（二进制往返逐字节
/// 一致）。第三条是这个门面存在的理由之一：`read_text` 会把非法字节换成
/// U+FFFD，标签写回就是这么毁文件的。
test "Fs：文本/字节往返与缺档缺席（T197）" {
  let base = temp_path("moonui_fs_roundtrip")
  let text_path = base + ".txt"
  let bin_path = base + ".bin"
  // 自产自销：跑前清一次（上次残留会让"缺席"断言假红），跑后再清
  let _ = Fs::remove(text_path)
  let _ = Fs::remove(bin_path)
  // 缺档 → None（不是错误）
  assert_eq(Fs::read_text(text_path), None)
  assert_eq(Fs::read_bytes(bin_path), None)
  // 文本往返（原子写）
  Fs::write_text_atomic(text_path, "第一行\nsecond line\n")
  assert_eq(Fs::read_text(text_path), Some("第一行\nsecond line\n"))
  // 覆盖写：同一路径再写一次，读到的是新内容（不是追加）
  Fs::write_text_atomic(text_path, "换了")
  assert_eq(Fs::read_text(text_path), Some("换了"))
  // 字节往返：0xFF 0xFE 这种非法 UTF-8 必须原样回来
  let raw = Bytes::from_array([0xFF, 0xFE, 0x00, 0x41])
  Fs::write_bytes_atomic(bin_path, raw)
  assert_eq(Fs::read_bytes(bin_path), Some(raw))
  // 原子写的临时档不许留在盘上
  assert_eq(Fs::read_bytes(text_path + ".tmp"), None)
  assert_true(Fs::remove(text_path))
  assert_false(Fs::remove(text_path))
  let _ = Fs::remove(bin_path)
}

///|
/// 判据：原子替换在"目标已存在且正被读"的语义下不会留下半份——
/// 写完之后目录里只有目标文件，没有 `.tmp` 残渣。
test "Fs：原子写不残留临时档（T197）" {
  let path = temp_path("moonui_fs_atomic") + ".json"
  let _ = Fs::remove(path)
  Fs::write_text_atomic(path, "{\"a\":1}")
  Fs::write_text_atomic(path, "{\"a\":2}")
  assert_eq(Fs::read_text(path), Some("{\"a\":2}"))
  assert_eq(Fs::read_text(path + ".tmp"), None)
  let _ = Fs::remove(path)
}
