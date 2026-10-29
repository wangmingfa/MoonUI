///|
/// 歌词（LRC 解析产物）。t 是相对歌曲开头的秒数；text 是那一句的文字。
pub(all) struct Lyric {
  t : Double
  text : String
}

///|
/// 把整段 .lrc 文本解析成按时间升序的歌词行。逐行处理，坏行整行丢弃不阻断
/// （与 probe 的逐字段兜底同一条健壮性账）：
/// - 时间标签 [mm:ss.xx] 一行可多次（同一句多个时间点都记）；
/// - 元数据 [ti:]/[ar:]/[al:]/[by:] 忽略；[offset:±ms] 用于整体平移；
/// - 时间格式错 / 含非数字的行丢弃。
pub fn parse_lrc(text : String) -> Array[Lyric] {
  let raw : Array[(Double, String)] = []
  let mut offset_ms = 0L
  for r in text.split("\n").to_array() {
    let line = r.to_owned()
    if line.length() == 0 {
      continue
    }
    let segs = line.split("[").to_array()
    // segs[0] 是首个 '[' 之前的文字（通常是空）
    let mut lyric_text = segs[0].to_owned()
    let times : Array[Double] = []
    for k = 1; k < segs.length(); k = k + 1 {
      let seg = segs[k].to_owned()
      let rb = find_char(seg, ']', 0)
      if rb < 0 {
        continue
      }
      let tag = seg[0:rb].to_owned()
      let after = seg[rb + 1:].to_owned()
      // 标签形如 mm:ss.xx（时间）或 ti:/ar:/al:/by:/offset:（元数据）
      let colon = find_char(tag, ':', 0)
      if colon < 0 {
        continue
      }
      let key = tag[0:colon].to_owned()
      let val = tag[colon + 1:].to_owned()
      if is_all_digits(key) {
        match parse_lrc_time(tag) {
          Some(t) => times.push(t)
          None => ()
        }
      } else if key == "offset" {
        offset_ms = parse_int_maybe(val)
      }
      lyric_text = lyric_text + after
    }
    if times.length() > 0 && lyric_text.length() > 0 {
      for t in times {
        raw.push((t, lyric_text))
      }
    }
  }
  // offset 对整个文件统一生效（标签可在任意位置）
  let off = offset_ms.to_double() / 1000.0
  let out : Array[Lyric] = []
  for (t, txt) in raw {
    out.push({ t: t + off, text: txt, })
  }
  // 按时间升序（插入排序，行数小）
  for i = 1; i < out.length(); i = i + 1 {
    let key = out[i]
    let mut j = i - 1
    while j >= 0 && out[j].t > key.t {
      out[j + 1] = out[j]
      j = j - 1
    }
    out[j + 1] = key
  }
  out
}

///|
/// 给定播放位置（毫秒），返回当前应高亮的歌词下标；未到第一句返回 -1。
pub fn active_lyric_index(lyrics : Array[Lyric], pos_ms : Int64) -> Int32 {
  if lyrics.length() == 0 {
    return -1
  }
  let pos = pos_ms.to_double() / 1000.0
  let mut idx = -1
  for i = 0; i < lyrics.length(); i = i + 1 {
    if lyrics[i].t <= pos {
      idx = i
    } else {
      break
    }
  }
  idx
}

///|
/// 由音频路径推歌词伴随文件路径：同目录、扩展名换成 .lrc。
pub fn lyric_path_for(audio_path : String) -> String {
  let segs = audio_path.split(".").to_array()
  if segs.length() < 2 {
    return audio_path + ".lrc"
  }
  let mut base = ""
  for i = 0; i < segs.length() - 1; i = i + 1 {
    if i > 0 {
      base = base + "."
    }
    base = base + segs[i].to_owned()
  }
  base + ".lrc"
}

///|
/// 读歌词并解析；文件缺失或解析不出返回空（无歌词是常态，不报错）。
///
/// 只读**同目录同名的 `歌.lrc`**（`lyric_path_for`）——用户手工放的、别的播放器
/// 下载的、本程序在线取到后写的，都在这个名字上。没有私有档：见 `lyric_save_path`。
///
/// 解析出非空才算数：一份时间标签全坏的 `.lrc` 等于没有词，让调用方照常去联网，
/// 而不是留一份空壳把它当成"已经有歌词了"。
pub fn load_lyrics_for(path : String) -> Array[Lyric] raise @moonui.UiError {
  match load_lyric_text(lyric_path_for(path)) {
    Some(text) => parse_lrc(text)
    None => []
  }
}

///|
/// 在线词该往哪写（`T159`②）：**`歌.lrc` 还空着就写它；已经有这个文件就不写**。
///
/// **为什么写共用的名字**：`歌.lrc` 是所有播放器（foobar、网易云、各种小众客户端）
/// 都认的约定名。写个私有的 `歌.lunamusic.lrc` 等于把词锁在 Luna 里——别的播放器
/// 打开同一首歌还得各自联网再查一遍。既然已经拿到词，就该写成人人都看得懂的名字。
///
/// **为什么已经有就不写**：走到这一跳的前提是 `load_lyrics_for` 没读出词，那只可能
/// 是两种情形——① `歌.lrc` 不存在（该写，也是绝大多数情况）；② 它在但一行时间标签
/// 都解析不出来（纯文本歌词、或用户放了个坏文件）。②很罕见，而为它备一套私有档名
/// 的代价是每次都要多解释一遍"这两个文件谁是谁"；**不动别人的文件**永远比"我有
/// 更好的版本"更稳。②的后果只是这首歌下次还会联网一次，代价可接受。
///
/// 空路径（wasm / 无头测试）返回空串，调用方据此整段跳过。
pub fn lyric_save_path(audio_path : String) -> String raise @moonui.UiError {
  if audio_path.length() == 0 {
    return ""
  }
  let shared = lyric_path_for(audio_path)
  match load_lyric_text(shared) {
    // 已经有这个文件（不管内容好坏）：不碰
    Some(_) => ""
    // 没有：写共用的那个，别的播放器也能直接用
    None => shared
  }
}

///|
fn find_char(s : String, c : Char, from : Int32) -> Int32 {
  let n = s.length()
  let mut i = from
  while i < n {
    if s[i].to_int() == c.to_int() {
      return i
    }
    i = i + 1
  }
  -1
}

///|
fn is_all_digits(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for i = 0; i < s.length(); i = i + 1 {
    let ch = s[i]
    if !(ch.to_int() >= '0'.to_int() && ch.to_int() <= '9'.to_int()) {
      return false
    }
  }
  true
}

///|
/// 把纯数字串转 Int64；含非数字返回 -1。
fn digits_to_int(s : String) -> Int64 {
  if s.length() == 0 {
    return -1L
  }
  let mut v = 0L
  for i = 0; i < s.length(); i = i + 1 {
    let ch = s[i]
    if !(ch >= '0' && ch <= '9') {
      return -1L
    }
    v = v * 10L + (ch.to_int() - 48).to_int64()
  }
  v
}

///|
/// 整数解析（允许负号），用于 [offset:±ms]；非法返回 0。
fn parse_int_maybe(s : String) -> Int64 {
  if s.length() == 0 {
    return 0L
  }
  if s[0] == '-' {
    let v = digits_to_int(s[1:].to_owned())
    if v < 0L {
      return 0L
    }
    return -v
  }
  let v = digits_to_int(s)
  if v < 0L {
    return 0L
  }
  v
}

///|
/// 解析 [mm:ss.xx] 时间标签为秒（Double）。格式错返回 None。
fn parse_lrc_time(tag : String) -> Double? {
  let colon = find_char(tag, ':', 0)
  if colon <= 0 {
    return None
  }
  let mm = digits_to_int(tag[0:colon].to_owned())
  if mm < 0L {
    return None
  }
  let rest = tag[colon + 1:].to_owned()
  let dot = find_char(rest, '.', 0)
  let (ss_str, frac_str) = if dot >= 0 {
    (rest[0:dot].to_owned(), rest[dot + 1:].to_owned())
  } else {
    (rest, "")
  }
  let ss = digits_to_int(ss_str)
  if ss < 0L {
    return None
  }
  let frac = digits_to_int(frac_str)
  let mut div = 1.0
  for k = 0; k < frac_str.length(); k = k + 1 {
    div = div * 10.0
  }
  let frac_val = if frac < 0L { 0.0 } else { frac.to_double() / div }
  Some((mm * 60L).to_double() + ss.to_double() + frac_val)
}
