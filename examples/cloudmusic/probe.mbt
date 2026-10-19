///|
/// 探针打包字节的解析（adapter.h 音频段的打包布局）：
/// [int32 title_len][title][int32 artist_len][artist][int32 album_len][album]
/// [int64 duration_ms][int32 cover_len][cover]
/// 纯 MoonBit、无头可测；壳的 NativeAudioEngine.load 把它翻成 Track。
/// 布局坏了（长度越界）整体当读不出 → None，逐字段兜底不炸扫描（C-10 风险 4）。

///|
fn read_i32_le(b : Bytes, at : Int32) -> Int32? {
  if at + 4 > b.length() {
    return None
  }
  let mut v = 0
  for i = 0; i < 4; i = i + 1 {
    v = v | (b.get(at + i).unwrap().to_int() << (8 * i))
  }
  Some(v)
}

///|
fn read_i64_le(b : Bytes, at : Int32) -> Int64? {
  if at + 8 > b.length() {
    return None
  }
  let mut v : Int64 = 0L
  for i = 0; i < 8; i = i + 1 {
    v = v | (b.get(at + i).unwrap().to_int().to_int64() << (8 * i))
  }
  Some(v)
}

///|
fn read_bytes(b : Bytes, at : Int32, len : Int32) -> Bytes? {
  if len < 0 || at + len > b.length() {
    return None
  }
  Some(b.get_view(start=at, end=at + len).unwrap().to_owned())
}

///|
/// 打包字节 → Track。空串字段退回 from_path 的文件名兜底；封面 0 长按没有。
pub fn track_from_probe(path : String, packed : Bytes) -> Track? {
  let mut at = 0
  let tlen = read_i32_le(packed, at).unwrap_or(-1)
  if tlen < 0 {
    return None
  }
  at = at + 4
  let title_b = read_bytes(packed, at, tlen) |> or_none
  at = at + tlen
  let alen = read_i32_le(packed, at).unwrap_or(-1)
  if alen < 0 {
    return None
  }
  at = at + 4
  let artist_b = read_bytes(packed, at, alen) |> or_none
  at = at + alen
  let ablen = read_i32_le(packed, at).unwrap_or(-1)
  if ablen < 0 {
    return None
  }
  at = at + 4
  let album_b = read_bytes(packed, at, ablen) |> or_none
  at = at + ablen
  let dur = read_i64_le(packed, at).unwrap_or(-1L)
  at = at + 8
  let clen = read_i32_le(packed, at).unwrap_or(-1)
  if clen < 0 {
    return None
  }
  at = at + 4
  let cover = if clen == 0 { None } else { read_bytes(packed, at, clen) }
  let fallback = Track::from_path(path)
  Some({
    path,
    title: text_or(title_b, fallback.title),
    artist: text_or(artist_b, fallback.artist),
    album: text_or(album_b, fallback.album),
    duration_ms: dur,
    cover,
  })
}

///|
fn or_none(v : Bytes?) -> Bytes {
  match v {
    Some(b) => b
    None => b""
  }
}

///|
/// 空串/坏编码退回兜底文案。
fn text_or(b : Bytes, fallback : String) -> String {
  if b.length() == 0 {
    return fallback
  }
  @utf8.decode(b.exact_view()) catch {
    _ => fallback
  }
}
