///|
/// 目录行走的 wasm 半（targets 门控）：没有文件系统，行走结构性地缺席。
/// scan_tree 仍可用（纯 MoonBit），但注入源在 wasm 下恒为空——无头测试
/// 用 scan_tree 的可注入性喂合成目录树。
pub fn scan_tree(root : String) -> Array[String] {
  let _ = root
  []
}

///|
/// 皮肤档扫描的 wasm 半：与 native 半同名同签名，结构性缺席（恒空）。
/// 白名单判定 `is_skin_file` 是纯函数、两边同形，测试照那条走。
pub fn scan_skins(root : String) -> Array[String] {
  let _ = root
  []
}

///|
/// 行走注入的 wasm 半：native 半那只盒子在这里没有对应物（无文件系统），
/// 留同名空实现只为两侧符号齐平——壳只在 native 下注入。
pub fn set_walk_dir(_walk : (String) -> Array[String]) -> Unit {
  ()
}
