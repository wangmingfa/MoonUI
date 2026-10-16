///|
/// 设置中心与 Markdown 编辑器的落盘判据（`T88④` 文件半，native 目标限定——
/// 见 moon.pkg 的 targets 门控）。wasm 没有文件系统，这两条在那一档结构性
/// 缺席；缺席的形状沿 `T86⑦` 的既定口径——`archive_read`/`archive_write`
/// 的 wasm 半报 `Unsupported`，编辑器与设置中心在 wasm 上落盘不可用不静默。
///
/// 门控形状沿 window_state_file_native.mbt 的先例：判据与落盘机器同档门控，
/// 跑在 native 清单上（core 清单就是 native 宿主），临时档自产自销。

///|
/// 判据专用临时档路径（`T88④` 文件半判据自产自销——跑前清、跑后清，不给
/// 系统临时目录留跨跑残留）。TMPDIR/TEMP/TMP 的惯例档沿 `temp_archive_path`
/// 同一条读法，档名按判据区分（设置档 / 编辑器档各一条）。住在门控文件里
/// ——唯一调用方是这两条 native 判据，wasm 档整只缺席不出现 unused 假警报。
fn dx_temp_path(name : String) -> String {
  let base = match @env.get_env_var("TMPDIR") {
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
  base + "moonui_dx_" + name + "_native_test.json"
}

///|
/// `T88④` 判据·设置中心持久化闭环（文件半）：存 → 关窗 → 按档恢复，
/// 几何逐位落上（`T86⑦` 的恢复点在建窗前）、浅深主题与偏好应用回去；
/// 没写过档读回默认账（第一次启动的形状，§33 的 Option 缺席读法）。
/// 表单档是会话态不进档——恢复的是默认账（记案边界）。
test "设置中心持久化闭环：存 → 关窗 → 按档恢复（T88④判据·文件半）" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let path = dx_temp_path("settings")
  let _ = c_remove(cstr(path))
  // 没写过档：第一次启动形状——默认尺寸、默认浅深、偏好关
  let fresh = SettingsDemo::restored(app, path, LogicalSize(400.0, 300.0))
  assert_eq(fresh.window().size(), LogicalSize(400.0, 300.0))
  assert_eq(fresh.theme(), Light)
  assert_false(fresh.reduced_motion())
  // 存档：几何 + 浅深 + 偏好一起进档（先改几何——快照读的是当下，不是默认值）
  fresh.set_theme_choice(Dark)
  fresh.set_reduced_motion(true)
  fresh.window().set_size(LogicalSize(800.0, 600.0))
  fresh.window().set_position(LogicalPoint(30.0, 40.0))
  fresh.save_settings(path)
  fresh.window().close()
  // 按档恢复：几何逐位落上、偏好与主题应用回去（App 档也跟上）
  let back = SettingsDemo::restored(app, path, LogicalSize(400.0, 300.0))
  assert_eq(back.window().size(), LogicalSize(800.0, 600.0))
  assert_eq(back.window().position(), LogicalPoint(30.0, 40.0))
  assert_eq(back.theme(), Dark)
  assert_true(back.reduced_motion())
  assert_eq(app.theme(), Dark)
  // 表单档是会话态：恢复的是默认账（档不存表单值——第一版边界注记）
  assert_eq(back.username_text(), "用户名")
  assert_false(back.notify_checked())
  back.window().close()
  let _ = c_remove(cstr(path))
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// `T88④` 判据·Markdown 编辑器落盘读档（文件半）：写档的那只与读档的那只
/// 是两只不同的编辑器——全文逐位一致、行账重拼一致、预览重拼一致；没有档
/// 是常态（清空左栏、预览清账），不是错误（§33 的 Option 缺席读法）。
test "Markdown 编辑器落盘读档：另一只编辑器从档读回（T88④判据·文件半）" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let text = "# 标题\n\n- 一\n**粗体**\n正文"
  let writer = MarkdownDemo::demo(app, text)
  let path = dx_temp_path("markdown")
  let _ = c_remove(cstr(path))
  writer.save_to(path)
  // 读者：空编辑器从档读回——全文逐位一致、行账与预览重拼一致
  let reader = MarkdownDemo::demo(app, "")
  reader.load_from(path)
  assert_eq(reader.editor_text(), text)
  assert_eq(reader.parsed(), MarkdownLine::parse(text))
  assert_eq(reader.preview_texts(), ["标题", "• 一", "粗体", "正文"])
  // 没有档：缺席是常态（清空左栏、预览清账），不是错误
  let absent = dx_temp_path("absent")
  let _ = c_remove(cstr(absent))
  reader.load_from(absent)
  assert_eq(reader.editor_text(), "")
  assert_eq(reader.preview_texts(), [])
  assert_eq(reader.parsed(), [])
  // 自产自销：临时档跑前清、跑后清，不给系统临时目录留跨跑残留
  let _ = c_remove(cstr(path))
  let _ = c_remove(cstr(absent))
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}
