///|
/// L10n 读档在 wasm 侧的缺席（`T93②`，wasm 目标限定——见 moon.pkg 的 targets
/// 门控）。门面 `L10n::add_archive_file` 在两边都编得动，wasm 上撞 `Fs` 的
/// 显式 `Unsupported`（`fs_wasm.mbt`）；这条判据钉住的是**错误类型不是被吞成
/// 空档**——调用方在 wasm 上看见的是"不支持"，不是一份静默的空档案。

///|
test "L10n 读档：wasm 档显式缺席，不静默注册空档（T93②判据·§33）" {
  let l10n = L10n::new()
  let err = try {
    l10n.add_archive_file("zh", "moonui_l10n_wasm_probe.json")
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(
    err,
    Some(
      "不支持的操作：文件读取在 wasm 侧不可用（无文件系统）",
    ),
  )
  // 缺席没有留下半份档：切档当场报错，而不是切到一份空档
  assert_eq(
    try {
      l10n.set_locale("zh")
      None
    } catch {
      e => Some(UiError::message(e))
    },
    Some("操作失败：L10n 未注册 locale zh，不能切换"),
  )
}
