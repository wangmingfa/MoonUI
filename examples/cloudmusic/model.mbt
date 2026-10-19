///|
/// 一首歌的元数据——纯数据，零 UI 零后端（DESIGN.md C-05）。
/// probe 读不出的字段由构造方退回文件名 /「未知」；duration_ms 未知为 -1。
pub(all) struct Track {
  path : String
  title : String
  artist : String
  album : String
  duration_ms : Int64
  cover : Bytes?
} derive(Debug)

///|
/// 从路径反推展示字段：标题 = 去扩展名的文件名，歌手/专辑 = 「未知」。
/// 原生探针给不了元数据时的兜底（C-10 风险 4）。
pub fn Track::from_path(path : String) -> Track {
  // split 产 StringView，to_owned 落回 String（demo_dx 行解析同款惯用法）
  let segs = path.split("/").to_array()
  let base = segs[segs.length() - 1].to_owned()
  let dot = base.split(".").to_array()
  let mut title = base
  if dot.length() > 1 {
    title = ""
    for i = 0; i < dot.length() - 1; i = i + 1 {
      if i > 0 {
        title = title + "."
      }
      title = title + dot[i].to_owned()
    }
  }
  {
    path,
    title,
    artist: "未知",
    album: "未知",
    duration_ms: -1L,
    cover: None,
  }
}

///|
/// 播放模式，循环顺序与网易云一致：顺序播放 → 单曲循环 → 随机播放 → 回顺序（C-08）。
pub(all) enum PlayMode {
  Sequential
  RepeatOne
  Shuffle
} derive(Debug, Eq)

///|
pub fn PlayMode::next(self : PlayMode) -> PlayMode {
  match self {
    Sequential => RepeatOne
    RepeatOne => Shuffle
    Shuffle => Sequential
  }
}

///|
/// 模式文案，播放条按钮的提示语。
pub fn PlayMode::label(self : PlayMode) -> String {
  match self {
    Sequential => "顺序播放"
    RepeatOne => "单曲循环"
    Shuffle => "随机播放"
  }
}

///|
/// 时长格式化：毫秒 → "mm:ss"（超一小时进位到 h:mm:ss）；未知（<0）→ "--:--"。
pub fn format_duration(ms : Int64) -> String {
  if ms < 0 {
    return "--:--"
  }
  let total = ms / 1000L
  let h = total / 3600L
  let m = total % 3600L / 60L
  let s = total % 60L
  if h > 0 {
    "\{h}:\{pad2(m)}:\{pad2(s)}"
  } else {
    "\{pad2(m)}:\{pad2(s)}"
  }
}

///|
/// 扫描白名单：原生层能解的扩展名（C-04：AVAudioPlayer 全包；忽略 ASCII 大小写）。
pub fn is_audio_file(path : String) -> Bool {
  let segs = path.split(".").to_array()
  if segs.length() < 2 {
    return false
  }
  let ext = segs[segs.length() - 1].to_owned()
  // core 没有 String 小写化；白名单就 8 项，逐项忽略大小写比对即可
  let whitelist = ["mp3", "flac", "wav", "m4a", "aac", "alac", "aiff", "ogg"]
  let mut hit = false
  for w in whitelist {
    if String::compare_ignore_ascii_case(w, ext) == 0 {
      hit = true
      break
    }
  }
  hit
}

///|
/// 皮肤档白名单：`.skn`（千千静听皮肤的后缀，这里装的是 JSON 文本）与
/// `.json`（手写时图的方便）。老的二进制 `.skn` 会被内容这一关挡掉——扩展名
/// 认，内容不认，UI 侧给「不认得这份皮肤」。
pub fn is_skin_file(path : String) -> Bool {
  let segs = path.split(".").to_array()
  if segs.length() < 2 {
    return false
  }
  let ext = segs[segs.length() - 1].to_owned()
  let whitelist = ["skn", "json", "mskn"]
  let mut hit = false
  for w in whitelist {
    if String::compare_ignore_ascii_case(w, ext) == 0 {
      hit = true
      break
    }
  }
  hit
}

///|
fn pad2(n : Int64) -> String {
  if n < 10 {
    "0\{n}"
  } else {
    "\{n}"
  }
}
