///|
/// 曲库/皮肤扫描（`T197`）：递归、深度上限、白名单、排序全在框架的
/// `@moonui.Fs::walk` 里，这里只回答"什么算音频、什么算皮肤档"。
///
/// 为什么"列一个目录"仍然是注入的：MoonBit 读不了 `dirent` 的指针布局，真正的
/// `readdir` 只能在 C 侧（`backends/native-common/ffi.mbt` 的
/// `moonui_native_walk_dir` → mac `adapter_native.m:7939` / win
/// `adapter_native.c:10184`）。`T253` 起实现来自 `examples/lunamusic-host` 的
/// `AppHost.walk_dir`，共享壳把它塞给 `Fs::set_dir_lister`
/// （`examples/lunamusic-shell/shell.mbt`），这个包里不再自己养一只行走盒子。
///
/// 不注入时（wasm / 无头测试）`Fs::walk` 恒返回空数组——扫描扫不到东西，
/// 不会炸，也不会假装扫到了。

///|
/// 壳在启动时注入「列一个目录的直接子项」的实现（绝对路径数组，含文件与子目录）。
/// 转手给框架：全应用只有一处行走盒子，皮肤扫描与曲库扫描共用它。
pub fn set_walk_dir(walk : (String) -> Array[String]) -> Unit {
  @moonui.Fs::set_dir_lister(walk)
}

///|
/// 从一个根目录递归收集音频文件（`is_audio_file` 白名单，model.mbt）。
/// 目录里的其它项按"可能是目录"继续往下试一层；深度上限 32 防 symlink 环，
/// 结果按路径排序（框架负责）——扫描确定性是判据能写的前提。
pub fn scan_tree(root : String) -> Array[String] {
  @moonui.Fs::walk(root, decide=fn(p) {
    if is_audio_file(p) {
      @moonui.Take
    } else {
      @moonui.Descend
    }
  })
}

///|
/// 从一个根目录递归收集皮肤档（`is_skin_file` 白名单，model.mbt）。
pub fn scan_skins(root : String) -> Array[String] {
  @moonui.Fs::walk(root, decide=fn(p) {
    if is_skin_file(p) {
      @moonui.Take
    } else {
      @moonui.Descend
    }
  })
}
