///|
/// 曲库（DESIGN.md C-07）：目录清单 + 扫描出来的曲目缓存。
/// 纯逻辑：磁盘行走（walk_native/wasm）与落盘（storage_native/wasm）
/// 都在外面，这里只管合并、去重、增删与 JSON 序列化。
pub(all) struct Library {
  dirs : Array[String]
  tracks : Array[Track]
  /// 收藏（「我喜欢的音乐」）：只记 path，曲目本身仍在 `tracks` 里。
  /// 落盘为独立数组——旧档没有这段时按空收藏恢复（C-07 的坏档逐字段兜底）。
  favorites : Array[String]
} derive(Debug)

///|
pub fn Library::new() -> Library {
  { dirs: [], tracks: [], favorites: [], }
}

///|
/// 扫描结果并入曲库：按 path 去重（重复目录/重复文件不重复入账），目录同去重。
pub fn Library::merge(
  self : Library,
  dir : String,
  found : Array[Track],
) -> Unit {
  let mut known = false
  for d in self.dirs {
    if d == dir {
      known = true
      break
    }
  }
  if !known {
    self.dirs.push(dir)
  }
  let seen : Map[String, Bool] = Map([])
  for t in self.tracks {
    seen.set(t.path, true)
  }
  for t in found {
    if !seen.get(t.path).unwrap_or(false) {
      seen.set(t.path, true)
      self.tracks.push(t)
    }
  }
}

///|
/// 路径是否落在某目录下（含相等）。core 没有 startsWith，切片比对。
fn under_dir(path : String, dir : String) -> Bool {
  if path == dir {
    return true
  }
  let prefix = dir + "/"
  path.length() > prefix.length() &&
  path[0:prefix.length()].to_owned() == prefix
}

///|
/// 绝对路径判据（POSIX 与 Win32 两种根都认）。
fn is_abs_path(path : String) -> Bool {
  if path.has_prefix("/") {
    return true
  }
  // Win32 UNC：`\\server\share`（两个反斜杠开头）
  if path.has_prefix("\\\\") {
    return true
  }
  // Win32 盘符：`C:\...` / `C:/...`（盘符 + 冒号 + 分隔符）
  path.length() >= 3 &&
  path[1:2].to_owned() == ":" &&
  (path[2:3].to_owned() == "/" || path[2:3].to_owned() == "\\")
}

///|
/// 档里是否还有**裸文件名**（`T142` 之前的旧档）。
///
/// `moonui_native_walk_dir` 当年把 `readdir` 的 `d_name` 直接上报，违反了
/// adapter.h"绝对路径"的约定，扫描入库于是全是 `夜曲.mp3` 这种相对名。装歌
/// 按相对路径找，相对的是进程当前目录（`moon run` 下是仓库根），永远找不到，
/// `start_at` 逐首重试全败后 `stop_all`——双击行看着就是"没反应"。
///
/// C 侧已改成拼 `dir + "/" + name`，但 C-07 的缓存是"直接入账不重探"，旧档
/// 不会自己变好。壳据此判一次重扫（裸名丢了子目录层级，纯逻辑猜不回来，
/// 只有重新走一遍目录才拿得准）。
pub fn Library::has_bare_paths(self : Library) -> Bool {
  for t in self.tracks {
    if !is_abs_path(t.path) {
      return true
    }
  }
  false
}

///|
/// 移除一个目录及其全部曲目。返回被移除的曲目数。
pub fn Library::remove_dir(self : Library, dir : String) -> Int32 {
  let mut removed = 0
  let kept_dirs : Array[String] = []
  for d in self.dirs {
    if d != dir {
      kept_dirs.push(d)
    }
  }
  self.dirs.clear()
  for d in kept_dirs {
    self.dirs.push(d)
  }
  let kept : Array[Track] = []
  for t in self.tracks {
    if under_dir(t.path, dir) {
      removed = removed + 1
    } else {
      kept.push(t)
    }
  }
  self.tracks.clear()
  for t in kept {
    self.tracks.push(t)
  }
  removed
}

///|
/// 从列表移除单曲（右键菜单「从列表移除」）。
pub fn Library::remove_track(self : Library, path : String) -> Unit {
  let kept : Array[Track] = []
  for t in self.tracks {
    if t.path != path {
      kept.push(t)
    }
  }
  self.tracks.clear()
  for t in kept {
    self.tracks.push(t)
  }
}

///|
/// 就地替换同 path 那条曲的展示字段（DESIGN.md C-16）。
///
/// `Track` 是不可变的，所以重建一个新值放回原位——**位置不变**，
/// 列表顺序与曲库计数都不受影响。返回是否命中（没这条返回 false，调用方
/// 据此判断"库里没有这首"而不是静默成功）。
pub fn Library::set_meta(
  self : Library,
  path : String,
  title : String,
  artist : String,
  album : String,
) -> Bool {
  for i, t in self.tracks {
    if t.path == path {
      self.tracks[i] = {
        path: t.path,
        title,
        artist,
        album,
        duration_ms: t.duration_ms,
        cover: t.cover,
      }
      return true
    }
  }
  false
}

///|
/// 按 path 查曲。
pub fn Library::find(self : Library, path : String) -> Track? {
  for t in self.tracks {
    if t.path == path {
      return Some(t)
    }
  }
  None
}

///|
/// 序列化（DESIGN.md C-07 落盘格式）：{ "dirs": [...], "tracks": [...] }。
/// 封面字节不落盘（体积）；恢复时由扫描器按 mtime 缓存判据决定重探。
pub fn Library::to_json(self : Library) -> Json {
  let dirs : Array[Json] = []
  for d in self.dirs {
    dirs.push(Json::string(d))
  }
  let tracks : Array[Json] = []
  for t in self.tracks {
    tracks.push(
      Json::object(
        Map::from_array([
          ("path", Json::string(t.path)),
          ("title", Json::string(t.title)),
          ("artist", Json::string(t.artist)),
          ("album", Json::string(t.album)),
          ("duration_ms", Json::number(t.duration_ms.to_double())),
        ]),
      ),
    )
  }
  let favs : Array[Json] = []
  for f in self.favorites {
    favs.push(Json::string(f))
  }
  Json::object(
    Map::from_array([
      ("dirs", Json::array(dirs)),
      ("tracks", Json::array(tracks)),
      ("favorites", Json::array(favs)),
    ]),
  )
}

///|
/// 档文本直读：壳（load 后）与测试共用的一条收口。
/// 解析不了 → None（调用方按「没有档」重建，坏档不假静默成空库重建以外的语义）。
pub fn Library::from_text(text : String) -> Library? {
  Library::from_json(@json.parse(text)) catch {
    _ => None
  }
}

///|
/// 反序列化。坏行逐条跳过（§33 精神：单行损坏不毁整个库）；
/// 整体不是对象/缺段返回 None，由调用方当「没有档」重建。
pub fn Library::from_json(j : Json) -> Library? {
  match j {
    Json::Object(root) => library_from_root(root)
    _ => None
  }
}

///|
/// 收藏段单独挂在库档里：缺段/坏行按「没有收藏」处理，不牵连 tracks 的恢复
/// （与 tracks 的逐行兜底同一条纪律：一段坏了不能毁整个库）。
fn read_favorites(root : Map[String, Json], lib : Library) -> Unit {
  match root.get("favorites") {
    Some(Json::Array(fs)) =>
      for f in fs {
        match f {
          Json::String(s) => lib.favorites.push(s)
          _ => () // 坏行跳过
        }
      }
    _ => ()
  }
}

///|
fn library_from_root(root : Map[String, Json]) -> Library? {
  let lib = Library::new()
  match (root.get("dirs"), root.get("tracks")) {
    (Some(Json::Array(dirs)), Some(Json::Array(tracks))) => {
      for d in dirs {
        match d {
          Json::String(s) => lib.dirs.push(s)
          _ => () // 坏行跳过
        }
      }
      for t in tracks {
        if t is Json::Object(m) {
          match
            (
              m.get("path"),
              m.get("title"),
              m.get("artist"),
              m.get("album"),
              m.get("duration_ms"),
            ) {
            (
              Some(Json::String(p)),
              Some(Json::String(title)),
              Some(Json::String(artist)),
              Some(Json::String(album)),
              Some(Json::Number(d, ..)),
            ) =>
              lib.tracks.push({
                path: p,
                title,
                artist,
                album,
                duration_ms: d.to_int64(),
                cover: None,
              })
            _ => () // 坏行跳过，不阻塞恢复
          }
        }
      }
      read_favorites(root, lib)
      Some(lib)
    }
    _ => None
  }
}

// ————————————————————————————————————————————————————————————
// 第二期追加的库操作：收藏、排序、搜索、m3u 导入导出。全部纯逻辑零 UI，
// 与上面的合并/增删同款——无头可测（wasm 门禁跑得到）。
// ————————————————————————————————————————————————————————————

///|
/// 排序维度：与列表列头一一对应（# 是库里的原始顺序）。
pub(all) enum SortKey {
  ByIndex
  ByTitle
  ByArtist
  ByDuration
} derive(Debug, Eq)

///|
/// 收藏开关：返回切换**之后**的状态（true = 已收藏）。
pub fn Library::toggle_favorite(self : Library, path : String) -> Bool {
  let mut idx = -1
  for i, p in self.favorites {
    if p == path {
      idx = i
      break
    }
  }
  if idx >= 0 {
    let _ = self.favorites.remove(idx)
    return false
  }
  self.favorites.push(path)
  true
}

///|
pub fn Library::is_favorite(self : Library, path : String) -> Bool {
  for p in self.favorites {
    if p == path {
      return true
    }
  }
  false
}

///|
/// 收藏集合对应的曲目（按 tracks 里的原顺序，保住稳定性）。
pub fn Library::favorite_tracks(self : Library) -> Array[Track] {
  let out : Array[Track] = []
  for t in self.tracks {
    if self.is_favorite(t.path) {
      out.push(t)
    }
  }
  out
}

///|
/// 排序后的曲目副本（不动 `tracks` 本身——库里的顺序始终是扫描顺序，
/// 排序只是视图账）。插入排序：稳定、零依赖，几百首量级足够。
pub fn Library::sorted(
  self : Library,
  key : SortKey,
  asc : Bool,
) -> Array[Track] {
  let out : Array[Track] = []
  for t in self.tracks {
    out.push(t)
  }
  sort_tracks(out, key, asc)
  out
}

///|
fn sort_tracks(arr : Array[Track], key : SortKey, asc : Bool) -> Unit {
  let n = arr.length()
  for i = 1; i < n; i = i + 1 {
    let cur = arr[i]
    let mut j = i - 1
    while j >= 0 && !in_order(arr[j], cur, key, asc) {
      arr[j + 1] = arr[j]
      j = j - 1
    }
    arr[j + 1] = cur
  }
}

///|
/// `a` 是否应排在 `b` 前面（按 key 与升/降序）。
fn in_order(a : Track, b : Track, key : SortKey, asc : Bool) -> Bool {
  let cmp = match key {
    ByIndex => 0 // 原始顺序：任何两首都算"已经排好"，保持不动
    ByTitle => cmp_str(a.title, b.title)
    ByArtist => cmp_str(a.artist, b.artist)
    ByDuration =>
      if a.duration_ms < b.duration_ms {
        -1
      } else if a.duration_ms > b.duration_ms {
        1
      } else {
        0
      }
  }
  if asc {
    cmp <= 0
  } else {
    cmp >= 0
  }
}

///|
/// 字符串序：core 的 `compare` 即字典序（中文按码位，够用——不做本地化排序）。
fn cmp_str(a : String, b : String) -> Int32 {
  String::compare(a, b)
}

///|
/// 搜索过滤：标题/歌手/专辑任一命中即留（大小写敏感——core 没有 to_lower，
/// 逐字符降 ASCII 会踩 UTF-8 边界，不做半吊子的小写化）。空串 = 不过滤。
pub fn filter_tracks(tracks : Array[Track], query : String) -> Array[Track] {
  if query.length() == 0 {
    let all : Array[Track] = []
    for t in tracks {
      all.push(t)
    }
    all
  } else {
    let out : Array[Track] = []
    for t in tracks {
      if t.title.contains(query) ||
        t.artist.contains(query) ||
        t.album.contains(query) {
        out.push(t)
      }
    }
    out
  }
}

///|
/// m3u 导出：标准头 + `#EXTINF:<秒>,<标题>` + 路径行。路径按原样写（本地库
/// 全是绝对路径，相对路径的 m3u 留给播放器自己解，这里不猜基准目录）。
pub fn m3u_export(tracks : Array[Track]) -> String {
  let mut s = "#EXTM3U\n"
  for t in tracks {
    let secs = if t.duration_ms > 0 {
      (t.duration_ms / 1000L).to_int()
    } else {
      -1
    }
    s = s + "#EXTINF:\{secs},\{t.artist} - \{t.title}\n\{t.path}\n"
  }
  s
}

///|
/// m3u 导入：只认路径行（`#` 开头的是 `#EXTM3U`/`#EXTINF` 注释行），
/// 空行跳过；返回路径数组（绝对路径直接用，相对路径按 m3u 文件所在目录拼）。
/// 不做去重与探测——那是调用方（壳）的事。
pub fn m3u_import(text : String, base_dir : String) -> Array[String] {
  let out : Array[String] = []
  for raw in text.split("\n").to_array() {
    let line = chomp(raw.to_owned())
    if line.length() == 0 {
      continue
    }
    if is_comment(line) {
      continue
    }
    out.push(resolve_m3u_path(line, base_dir))
  }
  out
}

///|
/// 去行尾的 \r（Windows 写的 m3u）。
fn chomp(line : String) -> String {
  let segs = line.split("\r").to_array()
  if segs.length() == 0 {
    line
  } else {
    segs[0].to_owned()
  }
}

///|
/// 注释行判定：按 `#` 切一段——首段为空就说明行首是 `#`。
/// （不按下标取字符：`line[0:1]` 遇到中文路径会切在 UTF-8 中间而 panic。）
fn is_comment(line : String) -> Bool {
  let segs = line.split("#").to_array()
  segs.length() > 0 && segs[0].to_owned().length() == 0
}

///|
/// 取文件所在目录（m3u 里的相对路径要按它拼）。没有分隔符时返回空串——
/// 调用方见空串就按原样使用路径。
pub fn dir_of(path : String) -> String {
  let segs = path.split("/").to_array()
  if segs.length() < 2 {
    return ""
  }
  let mut out = ""
  for i = 0; i < segs.length() - 1; i = i + 1 {
    if i > 0 {
      out = out + "/"
    }
    out = out + segs[i].to_owned()
  }
  out
}

///|
/// 相对路径按 m3u 所在目录拼；绝对路径（以 `/` 起，`split` 后首段为空）原样返回。
fn resolve_m3u_path(path : String, base_dir : String) -> String {
  if base_dir.length() == 0 {
    return path
  }
  let segs = path.split("/").to_array()
  if segs.length() > 0 && segs[0].to_owned().length() == 0 {
    path
  } else {
    base_dir + "/" + path
  }
}
