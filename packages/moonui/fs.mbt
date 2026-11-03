///|
/// 文件能力门面（`T197`）：把"读写一个文件、原子替换、走一棵目录"从应用里
/// 收进 Core。
///
/// 为什么放在 Core：`examples/lunamusic` 为了这三件事写了 435 行
/// （`storage_native` / `fileio_native` / `walk_native` 三对平台文件 + `shared.mbt`
/// 的 C 串/UTF-8 助手），而这三件事与"音乐"毫无关系。`window_state_file_native.mbt`
/// 早就证明"Core 自己声明 libc 符号、零 C 源"这条路走得通（`T86⑦`），只是当时
/// 只服务窗口几何一档，没有做成通用能力。
///
/// 分档形状沿用那半的先例：本文件是**门控无关**的门面与纯 MoonBit 策略，
/// 真正的系统调用在两个按目标门控的文件里（`fs_native.mbt` 声明 libc 的
/// stdio/fopen 家族、`fs_wasm.mbt` 同签名显式报 `Unsupported`）。wasm 没有
/// 文件系统，这条缺席必须能被调用方看见（§33），不许静默成功。
///
/// 目录行走为什么是**注入**的：MoonBit 侧读不了 `dirent` 的指针布局（struct
/// 偏移因平台而异，core 也没有指针解引用的 FFI），`readdir` 这条线只能在 C 侧。
/// 但**递归策略**（深度上限、白名单、排序、去重）是纯 MoonBit，且正是各应用
/// 反复重写的那部分——所以这里收策略、把"列一个目录的直接子项"留成注入点，
/// 壳启动时塞进来（原生半是 `backends/native-common` 的 `native_walk_dir`）。
pub(all) struct Fs {}

///|
/// 读整份文本。文件不存在返回 `None`（第一次启动没有档是常态，不是错误）；
/// 存在但读不完整是显式错误（半份内容会被 JSON 解析成乱七八糟的东西）。
pub fn Fs::read_text(path : String) -> String? raise UiError {
  fs_read_text(path)
}

///|
/// 原子地把整份文本写进 `path`：先写 `path.tmp`，再 rename 覆盖。
///
/// 为什么默认原子：原地截断再写有一个"目标存在但不完整"的窗口——正在读这个
/// 文件的另一个进程（比如播放器持有音频、另一个实例持有偏好档）会读到半份
/// 内容。POSIX 的 rename 是原子替换；Windows 的 CRT rename 不覆盖已存在的
/// 目标，退化成 remove + rename（中间那一瞬**不原子**，这是平台事实，不假装）。
pub fn Fs::write_text_atomic(
  path : String,
  text : String,
) -> Unit raise UiError {
  fs_write_atomic(path, @utf8.encode(text))
}

///|
/// 读整份字节。**不走文本通道**：`Fs::read_text` 会 `decode_lossy`，二进制里
/// 的任意字节会被替换成 U+FFFD，写回去就毁文件（标签里的封面图就是这么坏的）。
pub fn Fs::read_bytes(path : String) -> Bytes? raise UiError {
  fs_read_bytes(path)
}

///|
/// 原子地把整份字节写进 `path`（语义同 `Fs::write_text_atomic`）。
pub fn Fs::write_bytes_atomic(
  path : String,
  data : Bytes,
) -> Unit raise UiError {
  fs_write_atomic(path, data)
}

///|
/// 系统临时目录（带结尾分隔符）。TMPDIR（mac/Linux）→ TEMP/TMP（Windows）→
/// `/tmp/` 的惯例链；判据自产自销的临时档都落在这里，仓库里不留文件。
pub fn Fs::temp_dir() -> String {
  temp_dir_base()
}

///|
/// 删一个文件；不存在或删不掉都返回 `false`（不 raise——清理路径上"本来就没有"
/// 不是错误，调用方按布尔决定要不要在意）。
pub fn Fs::remove(path : String) -> Bool {
  fs_remove(path)
}

///|
/// 一步走目录时的裁决：这一项要不要收、要不要往下钻。
///
/// 为什么不是布尔：真实扫描要区分三种——"这是个音频文件，收下"、"这是个目录，
/// 继续往下"、"这是别的文件，跳过"。用布尔会逼调用方把"跳过"和"目录"混成一支，
/// 于是每多一种白名单就得重写一遍递归。
pub(all) enum WalkStep {
  /// 收下这一项（不再往下钻）
  Take
  /// 当目录继续递归
  Descend
  /// 跳过
  Skip
}

///|
/// 「列一个目录的直接子项」的注入盒子。
///
/// 用一只可变盒子而不是顶层 `let mut`：`let mut` 在包里是全局可变状态，注入/读取
/// 的时序会散在各文件里；盒子把"有没有注入"收成一个可判定的值，未注入时恒空
/// （wasm 与无头测试的形状），扫描只是扫不到东西，不会炸。
priv struct DirLister {
  mut list : (String) -> Array[String]
}

///|
let fs_dir_lister : DirLister = { list: fn(_) { [] }, }

///|
/// 注入「列一个目录的直接子项」的实现（绝对路径数组，含文件与子目录）。
/// 原生壳在启动时把 `backends/native-common` 的 `native_walk_dir` 塞进来；
/// 不注入时所有行走返回空数组。
pub fn Fs::set_dir_lister(list : (String) -> Array[String]) -> Unit {
  fs_dir_lister.list = list
}

///|
/// 从 `root` 递归收集，按 `decide` 裁决收哪些、往哪钻。结果按路径排序
/// （扫描确定性——同一棵目录两次扫出同一个顺序，判据才写得出来）。
///
/// `max_depth` 防 symlink 环：自引用链接会让递归无限下去，深度上限是最便宜
/// 的护栏（32 层足够，正常音乐库不会更深）。
pub fn Fs::walk(
  root : String,
  decide~ : (String) -> WalkStep,
  max_depth~ : Int32 = 32,
) -> Array[String] {
  let out : Array[String] = []
  fs_walk_inner(root, decide, max_depth, 0, out)
  sort_strings(out)
  out
}

///|
fn fs_walk_inner(
  dir : String,
  decide : (String) -> WalkStep,
  max_depth : Int32,
  depth : Int32,
  out : Array[String],
) -> Unit {
  if depth > max_depth {
    return
  }
  for child in (fs_dir_lister.list)(dir) {
    match decide(child) {
      Take => out.push(child)
      // 无扩展名的项也可能是目录：真目录由注入的 list 决定，不是文件时它返回空。
      Descend => fs_walk_inner(child, decide, max_depth, depth + 1, out)
      Skip => ()
    }
  }
}

///|
/// 路径排序（插入排序）：扫描结果是几百到几千条，够用且零依赖。
/// core 只有 `FixedArray::sort`（要求 `T : Compare`），字符串数组直接用即可，
/// 但这里顺便把"确定性排序"收成一个函数，免得每个应用再写一遍。
///
/// **顺序是 shortlex**（`Compare for String` 先比长度、同长再比码位，见
/// core `string.mbt:406`），不是字典序：`/a/b.mp3` 会排在 `/z.mp3` 前面。
/// 这里只要确定性（同一棵目录两次扫出同一个顺序），用户可见的排序在列表层
/// 按标题另排，所以 shortlex 够用；但**别把它当字典序用**——判据的期望值
/// 也得按长度写，按字母序写会红。
fn sort_strings(arr : Array[String]) -> Unit {
  for i = 1; i < arr.length(); i = i + 1 {
    let key = arr[i]
    let mut j = i - 1
    while j >= 0 && arr[j] > key {
      arr[j + 1] = arr[j]
      j = j - 1
    }
    arr[j + 1] = key
  }
}

///|
/// 原子写的一半：写临时档 + rename，两件事都走门控半的原语。失败时清掉临时档
/// （失败留一堆 `.tmp` 比失败本身更烦人）。
fn fs_write_atomic(path : String, data : Bytes) -> Unit raise UiError {
  let tmp = "\{path}.tmp"
  // 失败就把临时档清掉：失败留一堆 `.tmp` 比失败本身更烦人。
  errdefer {
    let _ = fs_remove(tmp)
  }
  fs_write_bytes(tmp, data)
  if !fs_rename(tmp, path) {
    // Windows 半的退化路径：CRT 的 rename 不覆盖已存在的目标（见门面注释）。
    let _ = fs_remove(path)
    if !fs_rename(tmp, path) {
      let _ = fs_remove(tmp)
      raise OperationFailed("改名失败：\{tmp} → \{path}")
    }
  }
}

///|
/// 判据：`walk` 的三态裁决、排序确定性、深度上限。行走实现用注入的假目录树
/// 替身——这条判据要在 wasm 上也跑得动（无文件系统不影响递归策略）。
test "Fs::walk：三态裁决 + 排序 + 深度上限（T197）" {
  let tree : Map[String, Array[String]] = Map([
    ("/lib", ["/lib/b.mp3", "/lib/sub", "/lib/cover.jpg", "/lib/a.mp3"]),
    ("/lib/sub", ["/lib/sub/c.flac", "/lib/sub/deep"]),
    ("/lib/sub/deep", ["/lib/sub/deep/d.mp3"]),
  ])
  Fs::set_dir_lister(fn(dir) {
    match tree.get(dir) {
      Some(xs) => xs
      None => []
    }
  })
  // 音频收下、无扩展名的当目录钻、其余跳过
  let decided = Fs::walk(
    "/lib",
    decide=fn(p) {
      if p.has_suffix(".mp3") || p.has_suffix(".flac") {
        Take
      } else if p.has_suffix(".jpg") {
        Skip
      } else {
        Descend
      }
    },
    max_depth=1,
  )
  // 深度 1：/lib 与它的直接子目录都走到了，/lib/sub 的子目录不再进
  assert_eq(decided, ["/lib/a.mp3", "/lib/b.mp3", "/lib/sub/c.flac"])
  // 深度 0：只扫根目录这一层
  let shallow = Fs::walk(
    "/lib",
    decide=fn(p) { if p.has_suffix(".mp3") { Take } else { Descend } },
    max_depth=0,
  )
  assert_eq(shallow, ["/lib/a.mp3", "/lib/b.mp3"])
  // 未注入：恒空（无头/wasm 的形状），不炸也不假装扫到了东西
  Fs::set_dir_lister(fn(_) { [] })
  assert_eq(Fs::walk("/lib", decide=fn(_) { Take }), [])
}
