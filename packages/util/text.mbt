///|
/// 文本小工具（`T200`）：core 缺的那几件，外加一条 CJK 坑的钉子。
///
/// 来源：`examples/lunamusic/tag.mbt` 里手写了一整套（`cm_trim` /
/// `cm_squeeze_ws` / `cm_same_text` / `cm_is_all_digits`），`lyrics.mbt` 里
/// 还另写了一份 `is_all_digits`——同一个判断两份实现，改一处忘一处只是时间
/// 问题。这类东西与 UI 无关，但要每个应用各写一遍就更没道理。
///
/// **这个包里没有排序**：原计划的"稳定 `sort_by`"没有落地——core 的
/// `Array::stable_sort_by` 本身就是稳定排序（`builtin/array_stable_sort_by_impl.mbt`），
/// 再包一层只是凭空多一个名字。四处手写插入排序直接换成了它。

///|
/// 空白字符集（**含全角空格** U+3000）——本包所有"空白"判断的唯一口径。
///
/// 为什么是这五个：`\t` `\n` `\r` 空格是 core 的默认集，U+3000 是中文文本里
/// 最常见的那个"看不见的空格"（输入法打出来的、从网页复制来的）。少认它，
/// 「周杰伦」与「周杰伦　」就成了两个人。
const WS_CHARS : String = "\t\n\r \u{3000}"

///|
/// 去掉两侧空白（含全角空格）。
///
/// core 的 `String::trim()` 默认只认 `\t\n\r `，中文文本里直接用它等于漏掉
/// 全角空格——这条不是"多一个方便函数"，是那个默认值不够用。
pub fn trim_ws(s : String) -> String {
  s.trim(chars=WS_CHARS).to_owned()
}

///|
/// 删掉**全部**空白（不是 trim，中间的也删）。
///
/// 用途是"两段文字算不算同一回事"这种比较：元数据里的标题常带一堆格式化空白
/// （`"晴天 - 周杰伦"` 与 `"晴天-周杰伦"`、`"Live 版"` 与 `"Live　版"`），
/// 比之前先把空白抹平，比逐字符判等省事得多。
///
/// 实现上按**段**切片再拼接，不逐字符重建：`s[i]` 取的是 UTF-16 码元，把码元
/// 一个个拼回去会把代理对拆开（emoji、生僻字变乱码）。只删不重新组码元就绕开了
/// 这件事。
pub fn squeeze_ws(s : String) -> String {
  let n = s.length()
  let mut out = ""
  let mut start = 0
  let mut i = 0
  while i < n {
    if is_ws_unit(s[i]) {
      if i > start {
        out = out + s[start:i].to_owned()
      }
      start = i + 1
    }
    i = i + 1
  }
  if start < n {
    out = out + s[start:n].to_owned()
  }
  out
}

///|
/// 两段文字算不算同一回事：先抹平空白，再忽略 ASCII 大小写。
///
/// 元数据的「周杰伦」与文件名的「周杰伦 」是同一个，`"Hello"` 与 `"hello"` 也
/// 是同一个——不该被当成两次不同的内容。只忽略 **ASCII** 大小写（core 的
/// `compare_ignore_ascii_case` 的口径）：非 ASCII 的大小写折叠是各语言自己的
/// 规则，猜错一次就是一条谁也查不出来的行为差异。
pub fn same_text_ci(a : String, b : String) -> Bool {
  String::compare_ignore_ascii_case(squeeze_ws(a), squeeze_ws(b)) == 0
}

///|
/// 纯 ASCII 数字串（至少一位）。空串不算。
///
/// 认 `0-9` 就够：调用方拿它判"这一段是不是年份 / 音轨号"（`"2004"`、
/// `"03"`），全角数字（`"２０"`）当标签的一部分处理更安全——它们是歌名里
/// 的字符，不是编号。
pub fn is_all_digits(s : String) -> Bool {
  let n = s.length()
  if n == 0 {
    return false
  }
  let mut i = 0
  while i < n {
    let v = s[i].to_int()
    if v < 48 || v > 57 {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// 空白口径只有一份：`WS_CHARS`（`trim_ws` 用的字符集）与 `is_ws_unit`
/// （`squeeze_ws` 逐码元扫用的判定）必须逐字对应。
///
/// 这两处表述是同一条口径的两种用法——一个是"给 `String::trim` 的字符集"，
/// 一个是"自己扫的时候查表"。分开写是必要的，**漂了就出事**：只有一处认全角
/// 空格时，`trim_ws("　晴天")` 能给对结果而 `squeeze_ws("晴　天")` 给错，
/// 症状是"有的地方好、有的地方不好"。所以用一条判据把它们钉在一起。
test "空白口径两处表述一致（T200）" {
  for i = 0; i < WS_CHARS.length(); i = i + 1 {
    assert_true(is_ws_unit(WS_CHARS[i]))
  }
  // 反过来：不在集合里的不该被当成空白（含全角句号 U+3002 这个"看着像空格"
  // 的邻居，以及 NUL）
  for c in ["a", "０", "。"] {
    for j = 0; j < c.length(); j = j + 1 {
      assert_false(is_ws_unit(c[j]))
    }
  }
  assert_false(is_ws_unit(0))
}

///|
/// 单个 **UTF-16 码元**是不是空白（口径见 `WS_CHARS`）。
///
/// 参数类型是 `UInt16`：`s[i]` 给的就是码元，逐码元扫描的地方（切分、逐位判定）
/// 直接用这个，不必先转 `Char`。公开它是为了让"空白字符集只有一份"——应用自己
/// 写一份 `is_space` 就又会漏掉全角空格。
pub fn is_ws_unit(c : UInt16) -> Bool {
  let v = c.to_int()
  v == 32 || v == 9 || v == 10 || v == 13 || v == 0x3000
}
