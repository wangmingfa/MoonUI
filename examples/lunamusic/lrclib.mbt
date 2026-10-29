///|
/// lrclib.net 的**纯逻辑**半边（`T158`）：URL 构造 + 响应解析。
/// 一个字节的网络都不在这里——`online_lyrics.mbt`（native 半）负责发请求，
/// 这一层只吃文本、吐结果，所以能全量无头测试。
///
/// 接口形状照 lrclib.net 的公开 REST（2026-10-29 实跑核对）：
///
/// ```text
/// GET /api/get?track_name=&artist_name=&duration=  → 单个对象 / 404
/// GET /api/search?track_name=&artist_name=         → 数组（可能空）
/// ```
///
/// 两处实跑观察决定了这个模块的形状：
/// 1. `/api/get` 是**精确匹配**：多一个字（「听妈妈的话（钢琴版）」）就 404。
///    所以文件名里带版本后缀的歌得先查 `/api/search`。
/// 2. `/api/search` 的结果里 `syncedLyrics` 可能为 null 而 `plainLyrics` 有
///    值——没时间轴的歌词也能显示（整段一行行铺开，不做逐句高亮）。

///|
/// 一条候选：标题、歌手、时长（秒，未知给 0）、带时间轴的 LRC、纯文本歌词。
/// 网络层把这些原样搬回来，挑选逻辑在这里。
pub(all) struct OnlineLyricHit {
  track_name : String
  artist_name : String
  duration_s : Double
  synced : String?
  plain : String?
} derive(Debug)

///|
/// 一次查询要问的东西：两种切法各一条（`tag_query_candidates` 的顺序），
/// 外加时长（秒，0 = 不知道）。
pub(all) struct OnlineLyricQuery {
  title : String
  artist : String
  duration_s : Double
}

///|
/// `perc` 编码：把一段文本编成能放进 query string 的形式。
///
/// 只留 RFC 3986 的 unreserved（`A-Z a-z 0-9 - . _ ~`），其余一律 `%XX`。
/// **按 UTF-8 字节编而不是按字符**——中文一个字三个字节，编某个「字符」是
/// 没有意义的。空格编成 `%20` 而不是 `+`：lrclib 两种都收，但 `%20` 不会
/// 在别的服务器上被误当成字面加号。
pub fn url_encode(s : String) -> String {
  let bytes = @utf8.encode(s)
  let mut out = ""
  for i = 0; i < bytes.length(); i = i + 1 {
    let b = bytes[i].to_int()
    let unreserved = (b >= 65 && b <= 90) ||
      (b >= 97 && b <= 122) ||
      (b >= 48 && b <= 57) ||
      b == 45 ||
      b == 46 ||
      b == 95 ||
      b == 126
    if unreserved {
      // b 一定是 ASCII（unreserved 那几条判据全在 7 位范围内），to_char 的
      // Option 到这里必是 Some——坏码元走不到这一支。
      out = out + b.to_char().unwrap().to_string()
    } else {
      out = out + "%" + hex_upper(b / 16) + hex_upper(b % 16)
    }
  }
  out
}

///|
fn hex_upper(v : Int32) -> String {
  if v < 10 {
    v.to_string()
  } else {
    match v {
      10 => "A"
      11 => "B"
      12 => "C"
      13 => "D"
      14 => "E"
      _ => "F"
    }
  }
}

///|
/// `/api/get` 的完整 URL。`duration_s <= 0` 时不带 duration 参数——带了 0 会
/// 让 lrclib 按「时长 0 秒」去精确匹配，必然 404。
///
/// 空 artist 也照发（不带这个参数）：只凭歌名查虽然命中率低，但比不发好，
/// 而且 lrclib 对缺参数的响应是空数组而不是错误。
pub fn lrclib_get_url(q : OnlineLyricQuery) -> String {
  let mut url = "https://lrclib.net/api/get?track_name=" + url_encode(q.title)
  if q.artist.length() > 0 {
    url = url + "&artist_name=" + url_encode(q.artist)
  }
  if q.duration_s > 0.0 {
    // 取整秒：lrclib 的 duration 是 Float，但它按 ±2s 容差比，取整足够。
    url = url + "&duration=" + q.duration_s.round().to_int().to_string()
  }
  url
}

///|
/// `/api/search` 的完整 URL（同上：空 artist / 未知时长就不带那个参数）。
pub fn lrclib_search_url(q : OnlineLyricQuery) -> String {
  let mut url = "https://lrclib.net/api/search?track_name=" +
    url_encode(q.title)
  if q.artist.length() > 0 {
    url = url + "&artist_name=" + url_encode(q.artist)
  }
  url
}

///|
/// 解析 `/api/get` 的 200 响应体：单个对象。解析不出、缺字段、两个歌词都空
/// 都返回 None（调用方据此换下一个候选）。
pub fn parse_lrclib_get(body : String) -> OnlineLyricHit? {
  hit_from_json(parse_json_or_null(body))
}

///|
/// 解析 `/api/search` 的响应体：数组，按原序给（不在这里排序——挑选规则在
/// `pick_lyrics_hit`，它需要看到全部候选才谈得上挑）。坏行逐条跳过。
pub fn parse_lrclib_search(body : String) -> Array[OnlineLyricHit] {
  let out : Array[OnlineLyricHit] = []
  match parse_json_or_null(body) {
    Json::Array(items) =>
      for it in items {
        match hit_from_json(it) {
          Some(h) => out.push(h)
          None => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// `@json.parse` 抛错时给 `Json::null()` 当哨兵——坏响应体是常态（服务器报错
/// 页、代理塞的 HTML），不该让整条取词链路 raise。与 wbtest 里的 `parse_ok`
/// 同一条手法，冒号这里用 null 而不是空数组：数组哨兵会让 search 的坏响应
/// 读成"查到 0 条"，而 null 在两处都是"解析不了"的干净答案。
fn parse_json_or_null(body : String) -> Json {
  @json.parse(body) catch {
    _ => Json::null()
  }
}

///|
/// 一个 JSON 对象 → 候选。缺 `trackName`/`artistName` 不算坏（那是数组里位置
/// 的语义），但两个歌词字段都空就是没用的候选，直接丢。
fn hit_from_json(j : Json) -> OnlineLyricHit? {
  match j {
    Json::Object(m) => {
      let synced = json_str(m, "syncedLyrics")
      let plain = json_str(m, "plainLyrics")
      let has_synced = match synced {
        Some(s) => s.length() > 0
        None => false
      }
      let has_plain = match plain {
        Some(s) => s.length() > 0
        None => false
      }
      if !has_synced && !has_plain {
        return None
      }
      Some({
        track_name: json_str(m, "trackName").unwrap_or(""),
        artist_name: json_str(m, "artistName").unwrap_or(""),
        duration_s: json_num(m, "duration"),
        synced,
        plain,
      })
    }
    _ => None
  }
}

///|
fn json_str(m : Map[String, Json], key : String) -> String? {
  match m.get(key) {
    Some(Json::String(s)) => Some(s)
    _ => None
  }
}

///|
fn json_num(m : Map[String, Json], key : String) -> Double {
  match m.get(key) {
    Some(Json::Number(v, ..)) => v
    _ => 0.0
  }
}

///|
/// 从一批候选里挑一条（`T158` 的挑选规则）。挑不到返回 None。
///
/// 三条优先级，都是实跑 lrclib 之后定的：
/// 1. **带时间轴的优先**：`syncedLyrics` 有值 > 只有 `plainLyrics`。没有时间
///    轴就做不了逐句高亮，只能整段铺开——能用但不是我们要的形状。
/// 2. **时长最接近的优先**：给了 duration 就按 |差| 排序。同一首歌常有现场版
///    和录音室版，时长差 30 秒的显然是另一个版本，配上去时间轴会整体错位。
/// 3. **标题/歌手一致的优先**：`/api/search` 是模糊匹配，会带回一堆同歌不同
///    人的翻唱。与查询词逐字相同的那条最可信（忽略大小写与空白）。
///
/// 三条同时参与排分，分数从大到小取第一条；同分保持服务器原序（stable）。
pub fn pick_lyrics_hit(
  hits : Array[OnlineLyricHit],
  q : OnlineLyricQuery,
) -> OnlineLyricHit? {
  if hits.length() == 0 {
    return None
  }
  // 先打标签再排序：只用 (score, index) 排，避免对结构体本身做比较
  let order : Array[(Double, Int32)] = []
  for i = 0; i < hits.length(); i = i + 1 {
    order.push((hit_score(hits[i], q), i))
  }
  // 插入排序，稳定、降序
  for i = 1; i < order.length(); i = i + 1 {
    let key = order[i]
    let mut j = i - 1
    while j >= 0 && order[j].0 < key.0 {
      order[j + 1] = order[j]
      j = j - 1
    }
    order[j + 1] = key
  }
  Some(hits[order[0].1])
}

///|
/// 一条候选的排分。分数之间只有大小关系有意义，绝对值无所谓：
/// - 有时间轴 +1000（压过一切其它项）；
/// - 标题逐字相同 +100，歌手逐字相同 +100；
/// - 时长差每 1 秒 -1（同分位再靠稳定序保服务器原序）。
fn hit_score(h : OnlineLyricHit, q : OnlineLyricQuery) -> Double {
  let mut s = 0.0
  match h.synced {
    Some(v) => if v.length() > 0 { s = s + 1000.0 }
    None => ()
  }
  if cm_same_text(h.track_name, q.title) {
    s = s + 100.0
  }
  if q.artist.length() > 0 && cm_same_text(h.artist_name, q.artist) {
    s = s + 100.0
  }
  if q.duration_s > 0.0 && h.duration_s > 0.0 {
    let d = h.duration_s - q.duration_s
    let ad = if d < 0.0 { -d } else { d }
    s = s - ad
  }
  s
}

///|
/// 一个候选最终该给 UI 什么：**LRC 文本**。
///
/// 有时间轴就原样回去走 `parse_lrc`（与本地 `.lrc` 同一条路，逐句高亮）；
/// 只有纯文本就把它合成一份「没有时间标签」的 LRC——`parse_lrc` 会把这些行
/// 全丢掉，所以这里改成给每行补一个**递增的假时间轴**：第 k 行在第 k 秒。
/// 这比「整段塞一行」好：歌词秀至少会一屏一屏往前走，不会整段挤在中间那行
/// 字上。真时间轴拿不到是服务器的事，不是我们的编造——注释里写清楚。
pub fn hit_to_lrc(h : OnlineLyricHit) -> String? {
  match h.synced {
    Some(s) =>
      if s.length() > 0 {
        Some(s)
      } else {
        plain_to_pseudo_lrc(h.plain)
      }
    None => plain_to_pseudo_lrc(h.plain)
  }
}

///|
fn plain_to_pseudo_lrc(plain : String?) -> String? {
  match plain {
    Some(p) =>
      if p.length() == 0 {
        None
      } else {
        let lines = p.split("\n").to_array()
        let mut out = ""
        let mut k = 0
        for raw in lines {
          let line = cm_trim(raw.to_owned())
          if line.length() == 0 {
            continue
          }
          // 第 k 句放在第 k 秒（够用：高亮跟着走，节奏不是真的）
          out = out + "[" + pad_ts(k) + "]" + line + "\n"
          k = k + 1
        }
        if out.length() == 0 {
          None
        } else {
          Some(out)
        }
      }
    None => None
  }
}

///|
/// 秒数 → `mm:ss.xx`（假时间轴用，两位小数固定）。
fn pad_ts(sec : Int32) -> String {
  let m = sec / 60
  let s = sec % 60
  let ms = if m < 10 { "0" } else { "" }
  let ss = if s < 10 { "0" } else { "" }
  "\{ms}\{m}:\{ss}\{s}.00"
}

// ---- 取词计划与决策机（`T158`）：纯逻辑，网络在 online_lyrics.mbt ----

///|
/// 查询计划：把 `tag_query_candidates` 的候选表翻成实际要发的 URL 序列
/// （**纯逻辑、无网络**，所以这一条也在无头测试的覆盖里）。
///
/// 每个候选发两条：先 `/api/get`（精确匹配，命中就是对的那一首），没命中再
/// `/api/search`（模糊，同名不同版都能回来，由 `pick_lyrics_hit` 挑）。
/// 顺序就是候选表的顺序——「两种都查，命中优先」的落地点在这里：
/// `周杰伦 - 晴天.mp3` 先按 (晴天, 周杰伦) 查，没命中再按 (周杰伦, 晴天) 查。
///
/// 只发 title 非空的 URL：空标题查不出东西，白花一次往返。
///
/// 每一格是 `(候选序号, 是不是 /api/get, URL)`。带上候选序号是因为空标题的
/// 候选会被跳过——`online_lyrics_step` 若拿 `i / 2` 反推候选，遇到被跳过的那
/// 一格就会取到错的人（用甲的歌手去挑乙的结果）。
pub fn online_lyrics_plan(
  candidates : Array[(String, String)],
  duration_s : Double,
) -> Array[(Int32, Bool, String)] {
  let out : Array[(Int32, Bool, String)] = []
  for ci = 0; ci < candidates.length(); ci = ci + 1 {
    let (title, artist) = candidates[ci]
    if title.length() == 0 {
      continue
    }
    let q = OnlineLyricQuery::{ title, artist, duration_s, }
    // 中间那格 true = 这一条是 /api/get（精确），false = /api/search
    out.push((ci, true, lrclib_get_url(q)))
    out.push((ci, false, lrclib_search_url(q)))
  }
  out
}

///|
/// 一轮取词的**纯逻辑骨架**：喂它「URL + 已取到的响应体」，它说下一步干什么。
///
/// 这是把网络从决策里剥出来的那一层——native 半按返回值发请求，测试直接喂
/// 假响应体就能把整条决策路径跑完（不需要网络就能证明"精确命中的优先"、
/// "404 换下一个"、"全空返回 None"）。
pub(all) enum OnlineStep {
  /// 去取这个 URL
  Fetch(String)
  /// 查到了，收工
  Done(String)
  /// 查不到，收工
  GiveUp
}

///|
/// 决策状态机。`responses` 与 `plan` 一一对应（第 i 格是第 i 条 URL 的响应
/// 体，None = 请求失败/超时）。返回 Done 就不用再取；Fetch 是下一条要取的。
///
/// 挑选规则（实跑 lrclib 之后定的）：
/// 1. `/api/get` 命中就用——它是精确匹配，回来的就是对的那首；
/// 2. `/api/get` 404 就换 `/api/search`，用 `pick_lyrics_hit` 挑（这条覆盖
///    「文件名带版本后缀」那类：`听妈妈的话（钢琴版）` 精确查是 404，模糊查
///    能回来）；
/// 3. 一个候选两个都空就换下一个候选（第二层「两种都查」）；
/// 4. 全空 → GiveUp。
///
/// `responses` 比 `plan` 短 = 还没取到那一步；这时返回 `Fetch(plan[len])`。
pub fn online_lyrics_step(
  plan : Array[(Int32, Bool, String)],
  candidates : Array[(String, String)],
  duration_s : Double,
  responses : Array[String?],
) -> OnlineStep {
  let mut i = 0
  while i < plan.length() {
    let (ci, is_get, url) = plan[i]
    if i >= responses.length() {
      return OnlineStep::Fetch(url)
    }
    match responses[i] {
      Some(body) =>
        if is_get {
          match parse_lrclib_get(body) {
            Some(hit) =>
              match hit_to_lrc(hit) {
                Some(lrc) => return OnlineStep::Done(lrc)
                None => ()
              }
            None => ()
          }
        } else {
          // 挑选要用**这一格所属**候选的词（不是 i/2 反推的：空标题的候选
          // 在 plan 里被跳过，序号与位置不再对齐）
          let q = if ci < candidates.length() {
            let (title, artist) = candidates[ci]
            OnlineLyricQuery::{ title, artist, duration_s, }
          } else {
            OnlineLyricQuery::{ title: "", artist: "", duration_s, }
          }
          let hits = parse_lrclib_search(body)
          match pick_lyrics_hit(hits, q) {
            Some(hit) =>
              match hit_to_lrc(hit) {
                Some(lrc) => return OnlineStep::Done(lrc)
                None => ()
              }
            None => ()
          }
        }
      None => ()
    }
    i = i + 1
  }
  OnlineStep::GiveUp
}
