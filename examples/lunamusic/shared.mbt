///|
/// String → UTF-8 Bytes（extern 的 Bytes lowering 要数据指针）。
/// 放在门控无关的文件里：native 的落盘半消费它，wasm 半也看得见这个消费点
/// （不出现 wasm 侧 unused_package 的假警报，moonui 的 cstr 同款布局）。
///
/// **这是"内容"用的**：`c_fwrite` 显式传长度，多一个字节就多写一个字节。
fn cm_utf8(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
/// NUL 结尾的 C 字符串（`fopen` / `rename` / `remove` 靠 NUL 分界，长度不显式传）。
///
/// 与 `packages/moonui/window_state.mbt:33` 的 `cstr` 同一口径——那边 `T86⑦`
/// （2026-10-22）就补上了 NUL，lunamusic 这份漏了，一直靠堆上恰好有零字节蒙
/// 过去（未定义行为，`T188` 2026-10-30 修）。
///
/// **路径和模式串走这里，文件内容走 `cm_utf8`**：`Bytes` 本身不保证 NUL 结尾，
/// 而 C 那边两条规矩正好相反——带长度的符号不许尾巴多一个字节，靠 NUL 分界的
/// 必须有一个。
fn cm_cstr(text : String) -> Bytes {
  cm_utf8(text).add(Bytes::make(1, 0))
}

///|
/// 系统临时目录（`T161` 的落盘往返测试用）。按惯例档查 TMPDIR（mac/Linux）、
/// TEMP/TMP（Windows），都没有落回 `/tmp`——与 `packages/moonui/window_state.mbt`
/// 的 `temp_archive_path` 同一条账。
///
/// **放在门控无关的这半**：native 那半的测试才用它，但 `@env` 的导入得在
/// 两个目标上都有消费点，否则 `moon check --target wasm` 会判 unused_package
/// （moonui 的 `cstr` / `temp_archive_path` 同款布局）。
/// `pub` 而不是 `priv`：只有测试用它，而 `moon check` 不看测试文件，私有函数
/// 会被判 `unused_value`。`cm_lyric_row_h` 这类"给测试读的常量"同一口径。
pub fn cm_temp_dir() -> String {
  match @env.get_env_var("TMPDIR") {
    Some(d) => d
    None =>
      match @env.get_env_var("TEMP") {
        Some(d) => d
        None =>
          match @env.get_env_var("TMP") {
            Some(d) => d
            None => "/tmp/"
          }
      }
  }
}
