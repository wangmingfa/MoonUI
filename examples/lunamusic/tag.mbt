///|
/// 「这首歌该拿什么标题和歌手去问歌词服务器」（`T158`）。
///
/// 纯逻辑、零 IO、零网络：输入是探针读出的 Track，输出一张**有序**的查询
/// 候选表。真正的 HTTP 在 `online_lyrics.mbt`（native 半）。
///
/// 三条来源规则（owner 在 2026-10-29 定的）：
/// 1. **元数据优先**：探针读出真值（非空、非哨兵）就用它。
/// 2. **缺哪个补哪个**：只有缺失的那一半才去文件名里找；另一个是真值就原样
///    保留。两个都缺才整份走文件名规则。
/// 3. **「未知」当缺失**：`Track::from_path` 的 `"未知"` 是哨兵不是空串，
///    判缺失时必须认它，否则兜底出来的 Track 永远"有歌手"。
///
/// 文件名规则的输出形状是**有序候选表而不是一个解**——这是 owner 的
/// 「两种都查，命中优先」：`A - B` 先按 A=歌手/B=歌名 查，没命中再按
/// A=歌名/B=歌手 查，第一个命中即采用；两个都不命中就按第一种定格。

///|
/// 缺省歌手/专辑的哨兵（与 `model.mbt` 的 `Track::from_path` 一字不差）。
/// 单独拎出来是为了让「这是不是缺失」只有一处定义——两边各写一遍会漂。
pub fn cm_unknown_field() -> String {
  "未知"
}

///|
/// 这一格算不算「没有」。空串与哨兵都算缺失。
pub fn tag_field_missing(v : String) -> Bool {
  let t = cm_trim(v)
  t.length() == 0 || t == cm_unknown_field()
}

///|
/// 文件名 → 切好的段（已去扩展名、`_` 还原成空格、去掉空段、从尾部剥掉
/// 纯数字段）。这条剥离是 owner 点名的三种形状推出来的：
///
/// ```
/// 給我一首歌的時間_(Piano_Ver_)-Piano_Echoes-275694467-320.mp3
///   → ["給我一首歌的時間 (Piano Ver )", "Piano Echoes"]
/// 听妈妈的话（钢琴版）-周杰伦-385944392-100.ogg
///   → ["听妈妈的话（钢琴版）", "周杰伦"]
/// 你怎么舍得我难过-黄品源-145527-2000.flac
///   → ["你怎么舍得我难过", "黄品源"]
/// ```
///
/// 至少留一段（`123-456.mp3` 不会被剥成空）。
pub fn cm_filename_segments(file_name : String) -> Array[String] {
  let base = cm_strip_extension(file_name)
  // 下划线在下载站命名里当空格用；换成空格更好读，也不影响后面的比对
  let spaced = cm_replace_all(base, "_", " ")
  let segs : Array[String] = []
  for s in cm_split_dashes(spaced) {
    let t = cm_trim(s)
    if t.length() > 0 {
      segs.push(t)
    }
  }
  let mut keep = segs.length()
  while keep > 1 && cm_is_all_digits(segs[keep - 1]) {
    keep = keep - 1
  }
  let out : Array[String] = []
  for i = 0; i < keep; i = i + 1 {
    out.push(segs[i])
  }
  out
}

///|
/// 文件名 → 一张有序候选表 `(title, artist)`。artist 空串 = 这一格没有歌手。
///
/// - 只有一段 → `[(整段, "")]`：没有歌手可猜，别硬编；
/// - 两段及以上 → 两种切法都给（业主的「两种都查，命中优先」），**顺序**由
///   `cm_title_first` 判。
///
/// 第三段及以后在 `cm_filename_segments` 里已经被剥掉了；万一剥完还剩三段
/// （`A-B-C` 三根横杠全是文字），取前两段。
pub fn tag_filename_readings(file_name : String) -> Array[(String, String)] {
  let segs = cm_filename_segments(file_name)
  let out : Array[(String, String)] = []
  if segs.length() == 0 {
    return out
  }
  if segs.length() == 1 {
    out.push((segs[0], ""))
    return out
  }
  let (title_first, artist_first) = if cm_title_first(file_name, segs) {
    ((segs[0], segs[1]), (segs[1], segs[0]))
  } else {
    ((segs[1], segs[0]), (segs[0], segs[1]))
  }
  out.push(title_first)
  if !cm_same_text(title_first.0, artist_first.0) {
    out.push(artist_first)
  }
  out
}

///|
/// 两段里哪一段更像歌名。两个信号，按可信度排：
///
/// 1. **尾部括注**：`（钢琴版）`、`(Live)`、`[Remastered]` 只挂在歌名上，歌手
///    名不会带版本标记。剥得掉就是歌名——这条最硬，压过空格习惯。
/// 2. **横杠两侧的空格**：`Artist - Title`（两侧有空格，iTunes/手打标签的
///    习惯）歌手在前；`Title-Artist`（横杠紧贴，下载站命名的习惯）歌名在前。
///    业主给的三个例子全是紧贴写法，所以这条默认按下载站走。
///
/// 两个信号都没有（`A-B` 且都不带括注）时按第 2 条的紧贴规则：歌名在前。
fn cm_title_first(file_name : String, segs : Array[String]) -> Bool {
  let s0_bracketed = cm_strip_trailing_bracket(segs[0]) != cm_trim(segs[0])
  let s1_bracketed = cm_strip_trailing_bracket(segs[1]) != cm_trim(segs[1])
  if s1_bracketed && !s0_bracketed {
    return false // 第二段带括注 → 它是歌名
  }
  if s0_bracketed && !s1_bracketed {
    return true
  }
  // 空格习惯：看原文件名的横杠两侧有没有空格（`_` 也当空格，下载站用它代替）
  !cm_dash_flanked_by_space(file_name)
}

///|
/// 文件名里有没有「两侧都是空白」的横杠。`周杰伦 - 晴天.mp3` 有，
/// `听妈妈的话（钢琴版）-周杰伦-385944392-100.ogg` 没有。
///
/// `_` 先当空格看：`A _ B` 与 `A - B` 是同一种排版习惯。
fn cm_dash_flanked_by_space(file_name : String) -> Bool {
  let base = cm_strip_extension(file_name)
  let s = cm_replace_all(base, "_", " ")
  let n = s.length()
  for i = 1; i < n - 1; i = i + 1 {
    if cm_is_dash(s[i]) && cm_is_space(s[i - 1]) && cm_is_space(s[i + 1]) {
      return true
    }
  }
  false
}

///|
/// 元数据 + 文件名 → 查询候选表（`T158` 的最终口径）。
///
/// 返回的每一格要么是元数据的真值、要么是文件名补出来的、要么是空串（连
/// 文件名都没给出）。查询侧见空就不发这一格。三种情形：
///
/// - **两个都不缺** → 只发一份（元数据原样），文件名完全不碰；
/// - **缺一个** → 补那一半，另一个一律保留。补的时候优先取文件名里**不等于
///   已知那一半**的段（`周杰伦 - 晴天.mp3` 已知歌手是周杰伦，标题就该取
///   「晴天」而不是「周杰伦」）；文件名给不出别的段就留空；
/// - **两个都缺** → 整份走文件名规则，两种切法都发（`A - B` 的歧义）。
pub fn tag_query_candidates(t : Track) -> Array[(String, String)] {
  let file_name = cm_file_name(t.path)
  let stem = cm_strip_extension(file_name)
  // 「标题就是文件名去扩展名」= 探针没读出标题，这个标题是
  // `Track::from_path` 的兜底（`model.mbt` 那 6 行），不是元数据。判在这一层
  // 是因为兜底与真值在 Track 里长得一模一样（都是非空 String），只有对着文件名
  // 比才分得出来。判错的代价很小：真值恰好等于文件名的歌，两种走法给出的查询
  // 词是同一个。
  let title_missing = tag_field_missing(t.title) || cm_same_text(t.title, stem)
  let artist_missing = tag_field_missing(t.artist)
  let base : Array[(String, String)] = if !title_missing && !artist_missing {
    [(cm_trim(t.title), cm_trim(t.artist))]
  } else if title_missing && artist_missing {
    let out = tag_filename_readings(file_name)
    if out.length() == 0 {
      [("", "")]
    } else {
      out
    }
  } else {
    let segs = cm_filename_segments(file_name)
    if title_missing {
      // 缺标题：取文件名里不是这个歌手的段
      let known = cm_trim(t.artist)
      [(cm_pick_other_segment(segs, known), known)]
    } else {
      // 缺歌手：取文件名里不是这个标题的段
      let known = cm_trim(t.title)
      [(known, cm_pick_other_segment(segs, known))]
    }
  }
  tag_with_title_variants(base)
}

///|
/// 给每个候选再补一份「去掉标题尾部括注」的版本，追加在原表之后。
///
/// 为什么需要：`/api/get` 是精确匹配（实跑核对过），标题里带 `（钢琴版）`、
/// `(Live)`、`[Remastered]` 这类括注一律 404；而正版 lrclib 条目的标题通常没有
/// 这个后缀。原始候选排在前面，所以真有条目用原名的仍优先命中；这条只是多
/// 一次机会。
///
/// 只剥**尾部**一层括注，且剥完必须还剩字（`（纯音乐）` 整串都是括注就剥成空，
/// 那种直接不发）。补出来的版本与已有候选重复时不重复追加。
fn tag_with_title_variants(
  base : Array[(String, String)],
) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for c in base {
    out.push(c)
  }
  for (title, artist) in base {
    let stripped = cm_strip_trailing_bracket(title)
    if stripped.length() == 0 || cm_same_text(stripped, title) {
      continue
    }
    let mut dup = false
    for (t2, a2) in out {
      if cm_same_text(t2, stripped) && cm_same_text(a2, artist) {
        dup = true
        break
      }
    }
    if !dup {
      out.push((stripped, artist))
    }
  }
  out
}

///|
/// 剥掉标题尾部那一层括注：`听妈妈的话（钢琴版）` → `听妈妈的话`。
///
/// 认全角 `（）`、半角 `()`、方括号 `[]`、`【】` 四种，必须成对且收在末尾。
/// 整串就是一个括注（`（纯音乐）`）时返回空串——调用方据此跳过。
fn cm_strip_trailing_bracket(title : String) -> String {
  let s = cm_trim(title)
  let n = s.length()
  if n < 2 {
    return s
  }
  let close = s[n - 1].to_int()
  let open = match close {
    0x29 => 0x28 // ) (
    0x5D => 0x5B // ] [
    0x3011 => 0x3010 // 】【
    _ => -1
  }
  // 中文全角右括号 U+FF09 也要认
  let open = if close == 0xFF09 { 0xFF08 } else { open }
  if open < 0 {
    return s
  }
  // 从尾部往前找配对的左括号（不做嵌套处理：`(Live (2020))` 只剥一层外层）
  let mut i = n - 2
  while i >= 0 {
    if s[i].to_int() == open {
      return cm_trim(s[0:i].to_owned())
    }
    i = i - 1
  }
  s
}

///|
/// 从切好的段里挑「不是 `known` 的那一段」。优先第二段（A=歌手/B=歌名 的
/// 默认约定里歌名在后），其次第一段，都没有就空串。
fn cm_pick_other_segment(segs : Array[String], known : String) -> String {
  if segs.length() == 0 {
    return ""
  }
  if segs.length() >= 2 && !cm_same_text(segs[1], known) {
    return segs[1]
  }
  if !cm_same_text(segs[0], known) {
    return segs[0]
  }
  ""
}

///|
/// 两段文字算不算同一回事：忽略大小写、忽略内部空白。元数据的「周杰伦」与
/// 文件名的「周杰伦 」是同一个，不该被当成两次不同的内容。
fn cm_same_text(a : String, b : String) -> Bool {
  String::compare_ignore_ascii_case(cm_squeeze_ws(a), cm_squeeze_ws(b)) == 0
}

///|
/// 去掉所有空白字符（不是 trim，是把中间的也删掉）。用分段替换而不是逐字符
/// 重建：`s[i]` 给的是 UTF-16 码元，逐字符拼回去要过 `Char` 转换，而那条路
/// 在码元上是有损的。
fn cm_squeeze_ws(s : String) -> String {
  let mut out = s
  for w in [" ", "\t", "\n", "\r", "\u{3000}"] {
    out = cm_replace_all(out, w, "")
  }
  out
}

// ---- 字符串小工具（core 没有的那几个）----

///|
/// 去掉扩展名：取最后一个 `.` 之前的全部。点开头且没有别的点（`.gitignore`
/// 那种）原样返回——那不是扩展名。
pub fn cm_strip_extension(name : String) -> String {
  let n = name.length()
  if n == 0 {
    return name
  }
  let mut dot = -1
  for i = 0; i < n; i = i + 1 {
    if name[i] == '.' {
      dot = i
    }
  }
  if dot <= 0 {
    return name
  }
  name[0:dot].to_owned()
}

///|
/// 取路径最后一段（两种分隔符都认：Windows 来的路径用 `\`）。
pub fn cm_file_name(path : String) -> String {
  let n = path.length()
  let mut cut = -1
  for i = 0; i < n; i = i + 1 {
    let ch = path[i]
    if ch == '/' || ch == '\\' {
      cut = i
    }
  }
  if cut < 0 {
    return path
  }
  path[cut + 1:].to_owned()
}

///|
/// 去掉两侧空白（含全角空格 U+3000）。
pub fn cm_trim(s : String) -> String {
  let n = s.length()
  let mut a = 0
  while a < n && cm_is_space(s[a]) {
    a = a + 1
  }
  let mut b = n
  while b > a && cm_is_space(s[b - 1]) {
    b = b - 1
  }
  s[a:b].to_owned()
}

///|
/// 空白判定。参数是 String 索引出来的**码元**（UInt16）不是 Char——MoonBit 的
/// `s[i]` 给的是 UTF-16 码元，全角空格 U+3000 也在 BMP 里，这一档够用。
fn cm_is_space(c : UInt16) -> Bool {
  let v = c.to_int()
  v == 32 || v == 9 || v == 10 || v == 13 || v == 0x3000
}

///|
/// 是不是歌名里的「横杠」：半角 `-`、全角 `－`、em dash `—`、en dash `–`。
/// 中文歌名里全角连字符很常见，只认半角会把整串当成标题。
pub fn cm_is_dash(c : UInt16) -> Bool {
  let v = c.to_int()
  v == 45 || v == 0xFF0D || v == 0x2014 || v == 0x2013
}

///|
/// 按任意一种横杠切段（都在切，不要求同一个字符）。
pub fn cm_split_dashes(s : String) -> Array[String] {
  let out : Array[String] = []
  let n = s.length()
  let mut start = 0
  let mut i = 0
  while i < n {
    if cm_is_dash(s[i]) {
      out.push(s[start:i].to_owned())
      start = i + 1
    }
    i = i + 1
  }
  out.push(s[start:n].to_owned())
  out
}

///|
/// 全部替换成另一段（`_` → 空格这种）。
pub fn cm_replace_all(s : String, from : String, to : String) -> String {
  if from.length() == 0 {
    return s
  }
  let segs = s.split(from).to_array()
  let mut out = ""
  for i = 0; i < segs.length(); i = i + 1 {
    if i > 0 {
      out = out + to
    }
    out = out + segs[i].to_owned()
  }
  out
}

///|
/// 纯数字串（至少一位）。
pub fn cm_is_all_digits(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for i = 0; i < s.length(); i = i + 1 {
    let v = s[i].to_int()
    if v < 48 || v > 57 {
      return false
    }
  }
  true
}
