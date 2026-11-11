///|
/// 判据：ABI 返回码 → `AudioError` 的码表逐档钉死（`T38` 欠的错误码那一半）。
///
/// 这里**不调真 C**：两侧返回码本来就不同（mac 的文件读不出是 -2、Windows 的
/// 音频整段是 FP4 空桩、每个入口 -3），把真码混进一份共享测试里必红在其中一边。
/// 按 `T18` 的口径，平台分叉落在 C 和各自平台的测试里——真码由
/// `backends/native-macos/native_test.mbt` 与 Windows 侧同形的那条各自钉。
/// 本文件只钉共享层读到码之后怎么说。`T253` 起这两张码表随实现搬到
/// `examples/lunamusic-host`，判据跟着搬。
///
/// 判据的形状是"逐档一命一答"：`-3` 改道 `Unsupported`（这一侧根本没接），
/// `-2` 与其他非零维持原样（`LoadFailed` / `PlayFailed`，载荷照旧是路径/操作名），
/// 0 不进这两个函数（调用点先判 `!= 0`）。
test "壳：音频返回码 -3 映射 Unsupported，其余维持原样（T38）" {
  // ——load 那一支——
  assert_true(audio_load_error(-3, "/m/1.mp3") is Unsupported)
  // mac 的 -2（文件读不出/解码不了）：还是文件问题，走逐首跳的恢复路径，
  // 载荷仍是那首歌的 path（界面要说得出是哪一首）
  assert_true(audio_load_error(-2, "/m/1.mp3") is LoadFailed("/m/1.mp3"))
  // -1（参数残缺）与任何别的非零码同样归 LoadFailed：未知码不许静默成功
  for rc in [-1, 1, 2, 3, -999, 100000] {
    assert_true(audio_load_error(rc, "/x.mp3") is LoadFailed("/x.mp3"))
  }
  // ——play / unpause 那一支——
  assert_true(audio_play_error(-3, "play") is Unsupported)
  assert_true(audio_play_error(-3, "unpause") is Unsupported)
  assert_true(audio_play_error(-2, "play") is PlayFailed("play"))
  assert_true(audio_play_error(-1, "unpause") is PlayFailed("unpause"))
  for rc in [1, -999, 4004] {
    assert_true(audio_play_error(rc, "seek") is PlayFailed("seek"))
  }
}

///|
/// `T253` 的接线判据：共享壳拿到的三件宿主能力不是空壳。
///
/// 只钉"接上了、兜底对"，不钉行为细节：
///   · `now_ms` 在走：连读若干次至少出现一次变化（不钉符号/量级——开机
///     毫秒在大端机上超过 `Int32` 上限会溢出成负数，>0 是假判据）；
///   · 不存在的目录 `walk_dir` 回空（C 半 opendir 失败给空包，不是 NULL）；
///   · 不存在的文件 `probe_track` 退 `Track::from_path`（读不出元数据时标题
///     取去扩展名的文件名）。
/// 这三条把「`app_host()` 的字段接错了实现」挡在门禁里；`worker_run` /
/// `snapshot_all` 仍要线程与真窗，证据边界见 TODO `T253`。
test "T253：AppHost 的 now_ms / walk_dir / probe_track 接线" {
  let host : @lunamusic.AppHost[Unit] = app_host()
  // 时钟在走：有界轮询到读数变化为止（不假设初值符号与分辨率）
  let t0 = (host.now_ms)()
  let mut ticks = false
  for _ in 0..<10_000_000 {
    if (host.now_ms)() != t0 {
      ticks = true
      break
    }
  }
  assert_true(ticks)
  let missing_dir = "/nonexistent-moonui-t253-dir"
  assert_eq((host.walk_dir)(missing_dir).length(), 0)
  let missing_song = "/nonexistent-moonui-t253-dir/song.mp3"
  let t = (host.probe_track)(missing_song)
  assert_eq(t.path, missing_song)
  assert_eq(t.title, "song")
  assert_eq(t.artist, "未知")
}
