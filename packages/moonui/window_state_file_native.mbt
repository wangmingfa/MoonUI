///|
/// 窗口存档的落盘半（`T86⑦`，native 目标限定——见 moon.pkg 的 targets 门控）。
///
/// 零 C 的实现口径：这里只有 MoonBit 侧的 `extern` 声明，符号直接指向 libc 的
/// stdio（fopen/fwrite/fread/fclose）——没有新增 C 源、没有动 Backend trait、
/// 没有动两份 adapter（`adapter.h` 一个字没变）。把 libc 声明进来而不是写 C
/// 包装，跟 §34/§35 "ABI 只在 trait" 的分工不冲突：这是 Core 自己的文件账，
/// 不经过后端。
///
/// `Bytes` 进 extern 的 lowering 是指针到数据区——同包 `backends/native-common`
/// 的标题参数（`c_window_new(title : Bytes, …)`）同一个形状，14/14 真窗口测试
/// 实证过；fread 让 libc 往这块数据区里写，是同一份 lowering 的写方向。
///
/// 平台注记（记案）：CRT 家族的 fopen 按 ANSI 码页解路径（Windows 半不含
/// UTF-8），非 ASCII 的临时路径在这一档上打不开——判据记 ASCII 路径档；
/// 宽字符路径按 `T18` 判据分（半宽字符家族 `_wfopen` 是 Windows 独有符号，
/// 无法与 mac 同一份声明共存，不夹带）。

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
/// 清档用（POSIX 与 CRT 都有 remove）：测试的临时档自产自销，不给系统
/// 临时目录留跨跑残留（上一次跑存的档会让下一次跑的"缺席"断言假红）。
#borrow(path)
extern "c" fn c_remove(path : Bytes) -> Int32 = "remove"

///|
/// 把整份内容写进 path（`T86⑦` 落盘半）。打不开/没写完都是显式错误（§33），
/// 半份档不许存在（fwrite 返回不足即报，fclose 失败也报）。
fn archive_write(path : String, content : String) -> Unit raise UiError {
  let f = c_fopen(cstr(path), cstr("w"))
  if f == 0 {
    raise OperationFailed("窗口存档打不开（写）：\{path}")
  }
  let bytes = @utf8.encode(content)
  let written = c_fwrite(bytes, 1, bytes.length().to_int64(), f)
  let closed = c_fclose(f)
  if written != bytes.length().to_int64() || closed != 0 {
    raise OperationFailed("窗口存档没写完整：\{path}")
  }
}

///|
/// 把 path 上的整份内容读出来（`T86⑦` 读盘半）。文件不存在返回 `None`
/// （第一次启动没有档是常态）；存在就读全量——存档只有一条 JSON 对象，
/// 撑不过几 KB，一次读尽不循环。
fn archive_read(path : String) -> String? raise UiError {
  let f = c_fopen(cstr(path), cstr("r"))
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
    raise OperationFailed("窗口存档关闭失败：\{path}")
  }
  ok
}

///|
/// 路径判据（`T86⑦判据·文件半`）：存 → 关窗 → 读 → 按档建窗，几何逐位一致；
/// 以及"没写过档读回 `None`"的显式缺席。跑在 native 门控里——wasm 半没有
/// 文件系统（见 window_state_file_wasm.mbt），这条在那一档结构性缺席。
test "窗口存档落盘往返：存 → 读 → 按档恢复建窗（T86⑦文件半）" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let win = app.create_window("MoonUI", LogicalSize(640.0, 480.0))
  win.set_position(LogicalPoint(12.0, 34.0))
  let path = temp_archive_path()
  // 自产自销：跑前清一次（上次跑的残留会让"缺席"断言假红），跑后再清
  let _ = c_remove(cstr(path))
  // 没写过档：读回 None（显式缺席，不是错误）
  assert_eq(app.load_window_state(path), None)
  let f = app.window_frame()
  app.save_window_state(path)
  // 往返：快照逐位回到 frame；再存一次覆盖同一路径仍然逐位一致
  assert_eq(app.load_window_state(path), f)
  app.save_window_state(path)
  assert_eq(app.load_window_state(path), f)
  win.close()
  let restored = app.create_window_restored(
    "MoonUI",
    LogicalSize(400.0, 300.0),
    app.load_window_state(path),
  )
  assert_eq(restored.size(), LogicalSize(640.0, 480.0))
  assert_eq(restored.position(), LogicalPoint(12.0, 34.0))
  restored.close()
  let _ = c_remove(cstr(path))
  Backend::terminate(b)
}
