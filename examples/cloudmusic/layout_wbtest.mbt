///|
/// 布局回归护栏：把上一版「界面只剩一片蓝」的病根钉在测试里。
///
/// 病根是**无界测量**：进度条在 Column 里挂了 `with_expand(true)`（Column 的
/// 主轴是竖直），而外层 `Stack` 用 1e18 的无界上限去量它，于是滑块被量成
/// `456×1000000000000000000`，下面整排走带控件被推到 y=1e18（屏幕外）——
/// 用户看到的就是一个纯色空窗。
///
/// 两条判据：
/// 1. 树里不许出现 1e18 量级的尺寸（无界值泄漏到 frame 就是布局炸了）；
/// 2. 主控窗内容必须恰好是 cm_main_w × cm_main_h（五段定高之和），
///    差一点都会在底部留空带或裁掉走带。
test "layout: 主控窗无无界尺寸，内容恰好等于窗口尺寸" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  engine.stub(trk("/m/1.mp3", 1L), [])
  let cm = CloudMusicApp::new(app, engine)
  let ui = cm.ui.unwrap()
  let dump = @moonui.Window::dump_layout(ui.window)
  // ① 无界哨兵（layout.mbt 的 Infinity = 1e18）不许出现在任何 frame 里
  assert_false(dump.contains("1000000000000000"))
  // ② 五段定高之和 = 窗口内容高（不是 240 那种"窗比内容高"的错位）
  assert_eq(cm_main_h(), 176.0)
  assert_eq(cm_main_w(), 380.0)
  assert_eq(
    cm_title_h() + cm_info_h() + cm_face_h() + cm_prog_h() + cm_transport_h(),
    cm_main_h(),
  )
  // ③ 三个伴窗都在（PL/EQ/LRC 的落地端）
  assert_true(@moonui.Window::dump_layout(ui.lyrics_win).length() > 0)
  assert_true(@moonui.Window::dump_layout(ui.playlist_win).length() > 0)
  assert_true(@moonui.Window::dump_layout(ui.eq_win).length() > 0)
  @moonui.Backend::terminate(b)
}
