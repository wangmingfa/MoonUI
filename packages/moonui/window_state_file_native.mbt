///|
/// 窗口存档的落盘半（`T86⑦`，native 目标限定——见 moon.pkg 的 targets 门控）。
///
/// `T197` 起这一半不再是"自己一套 fopen"：文件能力收进了 `Fs`（`fs_native.mbt`
/// 用同一批 libc 声明），这里只留"窗口存档"这层语义——写用原子替换，读缺档
/// 返回 `None`。原先 142 行的 extern 家族与读写实现全部上移，避免同一批
/// `extern "c" fn` 在包里出现两份（同包重名会撞）。
///
/// wasm 半（`window_state_file_wasm.mbt`）仍然显式报 `Unsupported`：无文件系统
/// 的目标上存档整体不可用，不静默。

///|
/// 把整份内容写进 path。打不开/没写完都是显式错误（§33），半份档不许存在
/// （原子写保证这条：先写 `.tmp` 再 rename，失败时临时档自己清掉）。
fn archive_write(path : String, content : String) -> Unit raise UiError {
  Fs::write_text_atomic(path, content)
}

///|
/// 把 path 上的整份内容读出来。文件不存在返回 `None`（第一次启动没有档是常态）。
fn archive_read(path : String) -> String? raise UiError {
  Fs::read_text(path)
}

///|
/// 路径判据（`T86⑦判据·文件半`）：存 → 关窗 → 读 → 按档建窗，几何逐位一致；
/// 以及"没写过档读回 `None`"的显式缺席。跑在 native 门控里——wasm 半没有
/// 文件系统（见 window_state_file_wasm.mbt），这条在那一档结构性缺席。
test "窗口存档落盘往返：存 → 读 → 按档恢复建窗（T86⑦文件半）" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let win = app.create_window("MoonUI", LogicalSize(640.0, 480.0))
  win.set_position(LogicalPoint(12.0, 34.0))
  let path = temp_archive_path()
  // 自产自销：跑前清一次（上次跑的残留会让"缺席"断言假红），跑后再清
  let _ = Fs::remove(path)
  // 没写过档：读回 None（显式缺席，不是错误）
  assert_eq(app.load_window_state(path), None)
  let f = app.window_frame()
  app.save_window_state(path)
  // 往返：快照逐位回到 frame；再存一次覆盖同一路径仍然逐位一致
  assert_eq(app.load_window_state(path), f)
  app.save_window_state(path)
  assert_eq(app.load_window_state(path), f)
  win.close()
  let restored = app.create_window_restored(
    "MoonUI",
    LogicalSize(400.0, 300.0),
    app.load_window_state(path),
  )
  assert_eq(restored.size(), LogicalSize(640.0, 480.0))
  assert_eq(restored.position(), LogicalPoint(12.0, 34.0))
  restored.close()
  let _ = Fs::remove(path)
  Backend::terminate(b)
}
