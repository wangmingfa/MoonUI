///|
/// 文件能力的落盘半（`T197`，native 目标限定——见 moon.pkg 的 targets 门控）。
///
/// 口径照 `T86⑦`：这层不碰 Backend trait、不加适配器入口；文件账是 Core 自己
/// 的，不经过后端。**`T189` 起多了一份 C 垫片**（`fs_utf8.c`，native-stub）：
/// 下面这三个符号指向它而不是 libc 的窄字符版——
///
///   Windows 的 CRT 用 ANSI 码页解 `fopen`/`remove`/`rename` 的路径，UTF-8 的
///   `听妈妈的话.lrc` 打不开；宽字符家族（`_wfopen` 一族）只在 Windows 存在，
///   而 MoonBit 的 `extern "c"` 声明是各宿主共用的（`options(targets:)` 认输出
///   后端、不认宿主 OS，见 `docs/upstream-issue-moon-pkg-host-dim.md`），直接声明
///   会在 macOS 链接失败。C 有这个分叉：一份源码 `#ifdef _WIN32`，POSIX 半逐字
///   转发、Windows 半转 UTF-16 再走宽字符。签名与 libc 窄字符版逐字一致，所以
///   这层只换符号名、调用约定一字节没动。
///
/// **模式串一律带 `b`**（`T112`②）：Windows 文本档的 `ftell` 报物理字节数
/// （`\n` 落盘成 `\r\n`）、`fread` 报翻译后的逻辑字符数，两边对不上会被判成
/// "没读完"；二进制模式两清，POSIX 侧 `b` 是无操作的同义词。

///|
#borrow(path, mode)
extern "c" fn c_fopen(path : Bytes, mode : Bytes) -> Int64 = "moonui_fs_fopen"

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
extern "c" fn c_remove(path : Bytes) -> Int32 = "moonui_fs_remove"

///|
#borrow(old, new)
extern "c" fn c_rename(old : Bytes, new : Bytes) -> Int32 = "moonui_fs_rename"

///|
/// 8.3 短名 → 长名（`T303`）。结果写进调用方给的缓冲，返回写了多少字节
/// （不含 NUL）：`0` 是不用展开/展不开，负数报的是「缓冲至少要多宽」。
/// 走 `fs_utf8.c` 与上面三个同一条缝——Windows 侧是 `GetLongPathNameW`，
/// POSIX 侧逐字转发（那边没有 8.3 概念）。
#borrow(src, out)
extern "c" fn c_long_path(src : Bytes, out : Bytes, out_cap : Int32) -> Int32 = "moonui_fs_long_path"

///|
/// 把一条路径的 8.3 短名展开成长名（`T303`）。
///
/// 展不开就原样返回：`Fs::temp_dir()` 的契约是「系统临时目录」，短名指向的
/// 也是同一个目录，展开只是让用户看见的东西更好看，不是让路径变得能用。
/// 缓冲不够时报出的长度够大就按它重来一次——静默截断一条路径比多一次系统
/// 调用糟得多（截断的目录名还能"成功"建出另一棵树）。
///
/// 不含 `~` 的直接返回：Windows 的 8.3 名格式固定是 `XXXXXX~N`，没有 `~` 就
/// 不可能是短名。这条让绝大多数调用（本机 `TEMP`、整个 POSIX）零系统往返——
/// `Fs::temp_dir()` 是公开 API，不能在每次调用上无条件做一次 Win32 查询。
/// 长名里真含 `~` 的（罕见）只是多走一次调用，结果幂等。
fn fs_long_path(path : String) -> String {
  if !path.contains("~") {
    return path
  }
  let cap = 512
  let buf = Bytes::make(cap, 0)
  let n = c_long_path(cstr(path), buf, cap)
  if n > 0 {
    return @utf8.decode_lossy(buf.exact_view(end=n))
  }
  if n == 0 {
    return path
  }
  // 负数报的是"缓冲至少要多宽"（取正是需要的字节数）
  let need = -n
  let big = Bytes::make(need, 0)
  let n2 = c_long_path(cstr(path), big, need)
  if n2 > 0 {
    @utf8.decode_lossy(big.exact_view(end=n2))
  } else {
    path
  }
}

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

///|
/// 判据：**非 ASCII 路径**能写、能读、能删（`T189`）。
///
/// 这条钉的是"分叉放在 C 垫片"那条缝：路径从 `String` 编成 UTF-8 字节之后，
/// 一路走到 `moonui_fs_fopen` / `moonui_fs_remove`，中间不许有哪一环把它当
/// ANSI 串处理。文件名带汉字，`听妈妈的话.lrc` 那个真实现场照抄。原子写本身
/// 就是 tmp + **rename**，所以这一条顺带把改名那个入口也踩到了。
///
/// 诚实边界：这台机器是 macOS，POSIX 半的窄字符 API 本来就吃 UTF-8 字节，
/// 所以**这条在改垫片前后都绿**——它钉住的是"垫片没把 POSIX 这条路径改坏"，
/// **不是**"Windows 那条通了"。Windows 半的判据要那台机器上真跑（见 TODO
/// `T189`）；本机能给的最强证据是 mingw 交叉的 `-fsyntax-only` 过闸。
test "Fs：非 ASCII 路径写读删（T189）" {
  let base = temp_path("moonui_fs_utf8_听妈妈的话")
  let path = base + ".lrc"
  let _ = Fs::remove(path)
  // 缺档回来的是 None（不是错误），路径里的汉字不影响这个判断
  assert_eq(Fs::read_text(path), None)
  Fs::write_text_atomic(path, "第一行\n")
  assert_eq(Fs::read_text(path), Some("第一行\n"))
  // 覆盖写：同一条路径再走一次 rename，读到的是新内容
  Fs::write_text_atomic(path, "换了")
  assert_eq(Fs::read_text(path), Some("换了"))
  // 临时档不许留在盘上（它的名字也是这条路径拼出来的）
  assert_eq(Fs::read_text(path + ".tmp"), None)
  assert_true(Fs::remove(path))
  assert_false(Fs::remove(path))
}

///|
/// 判据：8.3 短名展开（`T303`）——真短名展成长名，其余情况原样返回。
///
/// 输入用本机真实存在的 `C:\PROGRA~1`：只有 Windows 才有 8.3 名，所以这条在
/// POSIX 上前件为假（`fs_long_path` 恒等）、跳过展开那半，不制造假红。真区分
/// 力在 `core` job 的 windows-latest 那格——它的 `TEMP` 就是
/// `C:/Users/RUNNER~1/AppData/Local/Temp`，`Fs::temp_dir()` 那条断言在那里
/// 才咬得住东西（本机用户目录名不带空格，Windows 不给它生成短名）。
///
/// 三条不依赖平台的：不展开的必须原样（不是空串）、空串原样、幂等。
test "Fs：8.3 短名展开（T303）" {
  // ① 真短名：展得开就不许还剩 ~，且必须是磁盘上的真实拼法
  let short = "C:\\PROGRA~1\\"
  let long = fs_long_path(short)
  if long != short {
    assert_false(long.contains("~"))
    assert_true(long.contains("Program Files"))
  }
  // 展不开也是原样返回，不是空串——`Fs::temp_dir()` 拼文件名靠这条
  assert_true(long != "")
  // ② 不存在的短名段：GetLongPathNameW 要求整条存在（去尾分隔符重试也失败），
  //    原样返回。POSIX 恒等，同样成立。
  let missing = "C:\\moonui~1\\definitely-missing-dir\\"
  assert_eq(fs_long_path(missing), missing)
  // ③ 空串：不展开也不落回别的值（落回 /tmp/ 是 with_trailing_sep 的事，
  //    不归这一条管）
  assert_eq(fs_long_path(""), "")
  // ④ 幂等：长名再展一次还是自己（`Fs::temp_dir()` 每次调用都过这道）
  assert_eq(fs_long_path(long), long)
}

///|
/// 判据：`Fs::temp_dir()` 不给 8.3 短名（`T303`）。
///
/// 前件只在 Windows 上为真（绝对路径 + 反斜杠 + 盘符冒号），POSIX 那条路径
/// 形态不同、空转。runner 的 `C:/Users/RUNNER~1/AppData/Local/Temp` 是本条
/// 唯一的真区分场景——展开前它含 `RUNNER~1`，断言当场红。
test "Fs：temp_dir 不含 8.3 短名（T303）" {
  let d = Fs::temp_dir()
  assert_true(d.has_suffix("/") || d.has_suffix("\\"))
  assert_true(d != "")
  let windows_abs = d.contains(":") && d.contains("\\")
  if windows_abs {
    assert_false(d.contains("~"))
  }
  // 无论展开与否，再展一次不变（展开失败时这一步是恒等的平凡情形）
  assert_eq(fs_long_path(d), d)
}
