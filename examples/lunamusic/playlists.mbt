///|
/// 用户歌单（`T175`）：名称 + 有序 path 清单。账在偏好档
/// （~/.lunamusic-prefs.json 的 `playlists` 键，owner 拍板不另开档）——歌单是
/// 用户的播放意图清单，与曲库数据（歌在哪儿、标签是什么）分开。
///
/// path 只记路径不拷贝 Track：曲是曲库的，歌单只是"这几首按这个顺序"。
/// path 失效（文件删了）不清出歌单——文件回来歌还在原位，展示时跳过缺席的。
pub(all) struct Playlist {
  name : String
  paths : Array[String]
}

///|
/// 按名找歌单下标；没有回 -1。
pub fn playlist_index_of(pls : Array[Playlist], name : String) -> Int32 {
  for i, p in pls {
    if p.name == name {
      return i
    }
  }
  -1
}

///|
/// 新建空歌单。重名 / 空名拒绝（重名是"拒绝"不是自动后缀：自动后缀会把
/// "我的歌单"悄悄变成"我的歌单2"，用户要的账没记上还不自知）。
pub fn playlist_add(pls : Array[Playlist], name : String) -> Bool {
  if name == "" || playlist_index_of(pls, name) >= 0 {
    return false
  }
  pls.push({ name, paths: [], })
  true
}

///|
/// 改名。新名重名 / 空名拒绝；名字没变也算成功（幂等）。
pub fn playlist_rename(
  pls : Array[Playlist],
  old : String,
  new : String,
) -> Bool {
  if new == "" {
    return false
  }
  let i = playlist_index_of(pls, old)
  if i < 0 {
    return false
  }
  if new != old && playlist_index_of(pls, new) >= 0 {
    return false
  }
  pls[i] = { name: new, paths: pls[i].paths, }
  true
}

///|
/// 删除歌单。没有这名回 false。
pub fn playlist_remove(pls : Array[Playlist], name : String) -> Bool {
  let i = playlist_index_of(pls, name)
  if i < 0 {
    return false
  }
  let _ = pls.remove(i)
  true
}

///|
/// 往歌单加曲（paths 按给定顺序入账）。**同 path 跳过**（幂等，与收藏同一条
/// 口径：加两遍不出现两行）；返回实际新加的条数。
pub fn playlist_add_paths(
  pls : Array[Playlist],
  name : String,
  paths : Array[String],
) -> Int32 {
  let i = playlist_index_of(pls, name)
  if i < 0 {
    return 0
  }
  let mut added = 0
  for p in paths {
    if !pls[i].paths.contains(p) {
      pls[i].paths.push(p)
      added = added + 1
    }
  }
  added
}

///|
/// 从歌单移除一曲。本来就没有回 false。
pub fn playlist_remove_path(
  pls : Array[Playlist],
  name : String,
  path : String,
) -> Bool {
  let i = playlist_index_of(pls, name)
  if i < 0 {
    return false
  }
  for j, p in pls[i].paths {
    if p == path {
      let _ = pls[i].paths.remove(j)
      return true
    }
  }
  false
}

///|
/// 歌单账 → JSON：`[{"name":..,"paths":[..]}, ..]`。整键重写——集合小，
/// 每次变更全量重写比增量记账便宜，也不会留半份账。
pub fn playlists_to_json(pls : Array[Playlist]) -> Json {
  let items : Array[Json] = []
  for p in pls {
    let paths : Array[Json] = []
    for path in p.paths {
      paths.push(Json::string(path))
    }
    items.push(
      Json::object({ "name": Json::string(p.name), "paths": Json::array(paths) }),
    )
  }
  Json::array(items)
}

///|
/// JSON → 歌单账。容错口径：整键缺席/不是数组 → 空账；某一条不是对象、
/// 没有合法 name、paths 不是纯字符串数组 → **只扔那一条**（一条坏账不清掉
/// 用户其余的歌单）；重名只留先到的那条（后到的同名按坏账扔）。
pub fn playlists_of_json(j : Json?) -> Array[Playlist] {
  let out : Array[Playlist] = []
  match j {
    Some(Json::Array(items)) =>
      for it in items {
        match it {
          Json::Object(m) => {
            let name = match m.get("name") {
              Some(Json::String(s)) => s
              _ => continue
            }
            let paths : Array[String] = match m.get("paths") {
              Some(Json::Array(ps)) => {
                let ok : Array[String] = []
                let mut bad = false
                for p in ps {
                  match p {
                    Json::String(s) => ok.push(s)
                    _ => {
                      bad = true
                      break
                    }
                  }
                }
                if bad {
                  continue
                }
                ok
              }
              _ => continue
            }
            if name != "" && playlist_index_of(out, name) < 0 {
              out.push({ name, paths, })
            }
          }
          _ => continue
        }
      }
    _ => ()
  }
  out
}
