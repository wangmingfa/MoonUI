///|
/// 目录行走的 native 半（targets 门控）：列一个目录下的直接子项。
///
/// MoonBit 侧读不了 dirent 的指针布局（struct 偏移因平台而异，core 也没有
/// 指针解引用的 FFI），所以行走函数是**注入**的：native 壳（cloudmusic-native）
/// 用自己的 native-stub 提供 `cm_walk_dir`，这里只留声明与纯 MoonBit 的
/// 递归包装（白名单过滤、深层递归、去重排序都在 MoonBit 侧可测）。

///|
/// 壳注入的「列一个目录的直接子项」实现（绝对路径数组，含文件与子目录）。
/// 这个版本没有顶层 let mut——用一只可变盒子装行走函数，
/// 未注入（wasm/测试）时恒为空，扫描结果只喂合成数据。
priv struct WalkBox {
  mut walk : (String) -> Array[String]
}

///|
let cm_walk_box : WalkBox = { walk: fn(_) { [] }, }

///|
/// 壳在启动时注入行走实现（FP3 的 native-stub 提供）。
pub fn set_walk_dir(walk : (String) -> Array[String]) -> Unit {
  cm_walk_box.walk = walk
}

///|
/// 从一个根目录递归收集音频文件（is_audio_file 白名单，model.mbt）。
/// 深度上限 32 防 symlink 环；结果按 path 排序，保证扫描确定性可测。
pub fn scan_tree(root : String) -> Array[String] {
  let out : Array[String] = []
  scan_inner(root, out, 0)
  sort_paths(out)
  out
}

///|
fn scan_inner(dir : String, out : Array[String], depth : Int32) -> Unit {
  if depth > 32 {
    return
  }
  for child in (cm_walk_box.walk)(dir) {
    if is_audio_file(child) {
      out.push(child)
    } else {
      // 无扩展名/目录：当目录再试一层（真目录行走由注入的 walk 决定）
      scan_inner(child, out, depth + 1)
    }
  }
}

///|
/// 从一个根目录递归收集**皮肤档**（is_skin_file 白名单，model.mbt）。与
/// scan_tree 同一只行走盒子——壳注入一次，两条扫描路都通。深度上限同 32。
pub fn scan_skins(root : String) -> Array[String] {
  let out : Array[String] = []
  scan_skins_inner(root, out, 0)
  sort_paths(out)
  out
}

///|
fn scan_skins_inner(dir : String, out : Array[String], depth : Int32) -> Unit {
  if depth > 32 {
    return
  }
  for child in (cm_walk_box.walk)(dir) {
    if is_skin_file(child) {
      out.push(child)
    } else {
      scan_skins_inner(child, out, depth + 1)
    }
  }
}

///|
/// 简单插入排序：扫描结果几百到几千条，够用且零依赖。
fn sort_paths(arr : Array[String]) -> Unit {
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
