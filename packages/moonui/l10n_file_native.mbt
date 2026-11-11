///|
/// L10n 读档的文件半（`T93②`，native 目标限定——见 moon.pkg 的 targets 门控）。
/// wasm 没有文件系统，这条在那一档结构性缺席：`L10n::add_archive_file` 在 wasm
/// 上调 `Fs::read_text` 会拿到 `Unsupported`（`fs_wasm.mbt` 的同签名缺席），
/// 形状与 `T88④`/`T86⑦`/`T199` 一致——门控与落盘机器同档，临时档自产自销。
///
/// 判据分两半：好档往返（含中文与转义），坏档/缺档四条错误路径逐个点名 path。
/// 后者才是本条的重点——文案档坏了必须当场报错，让调用方在启动时就能看见
/// "少了一份档"，而不是等界面四处显式缺席才发现。

///|
test "L10n 从文件读档：好档往返、缺档与坏档显式点名 path（T93②判据）" {
  let path = temp_path("moonui_l10n_native_test.json")
  let _ = Fs::remove(path)
  let l10n = L10n::new()
  let msg = fn(f : () -> Unit raise UiError) -> String? {
    try {
      f()
      None
    } catch {
      e => Some(e.message())
    }
  }

  // 缺档：点名 path 与 locale（语言档不是"第一次启动没有是常态"的档）
  assert_eq(
    msg(fn() raise UiError { l10n.add_archive_file("zh", path) }),
    Some("操作失败：L10n 文案档不存在：\{path}（locale=zh）"),
  )

  // 好档：写下去再读回来，中文与转义原样
  Fs::write_text_atomic(
    path, "{\"app.title\": \"月亮\", \"app.quote\": \"他说：\\\"好\\\"\"}",
  )
  l10n.add_archive_file("zh", path)
  l10n.set_locale("zh")
  assert_eq(l10n.text("app.title"), "月亮")
  assert_eq(l10n.text("app.quote"), "他说：\"好\"")

  // 坏档：错误串带文件路径（不是"内存文本"），且不覆盖已注册的那份
  Fs::write_text_atomic(path, "{not json")
  assert_eq(
    msg(fn() raise UiError { l10n.add_archive_file("zh", path) }),
    Some(
      "操作失败：L10n 文案档 \{path} 不是合法 JSON（locale=zh）",
    ),
  )
  assert_eq(l10n.text("app.title"), "月亮")

  // 顶层不是对象
  Fs::write_text_atomic(path, "[1, 2]")
  assert_eq(
    msg(fn() raise UiError { l10n.add_archive_file("zh", path) }),
    Some(
      "操作失败：L10n 文案档 \{path} 顶层必须是 JSON 对象（locale=zh）",
    ),
  )

  // 值不是字符串：点名 key
  Fs::write_text_atomic(path, "{\"app.ok\": true}")
  assert_eq(
    msg(fn() raise UiError { l10n.add_archive_file("zh", path) }),
    Some(
      "操作失败：L10n 文案档 \{path} 的 key app.ok 不是字符串（locale=zh）",
    ),
  )

  let _ = Fs::remove(path)
  assert_eq(Fs::read_text(path), None)
}
