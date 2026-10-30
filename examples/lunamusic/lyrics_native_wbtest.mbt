///|
/// 手动选中的歌词**覆盖**已有 `.lrc`（`T161`①，owner 的原话：「如果已经存在
/// 歌词文件，直接覆盖」）。
///
/// 与 `lyric_save_path` 的「已经有就不写」是两件事：那条服务于**自动**取词
/// （机器不该覆盖用户放好的词），这条是用户亲手挑的，覆盖就是它的语义本身。
///
/// 判据只能跑在 native 上：`save_lyric_text` / `load_lyric_text` 的 wasm 半是
/// 结构性缺席（显式 `Unsupported`），而这里要证的恰恰是"真的落到了磁盘、且
/// 旧内容一个字都没剩"。文件全落在系统临时目录，跑前跑后各清一次
/// （AGENTS.md：仓库里不留任何文件）。
test "app：手动选中的歌词覆盖已有 .lrc（T161）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let audio = cm_temp_dir() + "lunamusic_t161_cover.mp3"
  let lrc_path = lyric_path_for(audio)
  save_lyric_text(lrc_path, "[00:00.00]旧的一句") catch {
    _ => ()
  }
  // 前置：旧文件真的在磁盘上——否则下面那句"覆盖"会退化成"首次写"，
  // 这条判据就什么都没证。
  assert_eq(
    load_lyric_text(lrc_path) catch {
      _ => None
    },
    Some("[00:00.00]旧的一句"),
  )
  let engine = MockAudioEngine::new()
  engine.stub(trk(audio, 10000L), [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [trk(audio, 10000L)])
  cm.player.play_index(0)
  cm.lyrics_path = audio
  cm.apply_searched_lyric(LyricSearchResult::{
    title: "晴天",
    artist: "周杰伦",
    duration_s: 4.0,
    lrc: "[00:00.00]新的一句\n[00:02.00]新的一句二",
  })
  // ① 磁盘上是新那份，旧内容一个字都不剩
  assert_eq(
    load_lyric_text(lrc_path) catch {
      _ => None
    },
    Some("[00:00.00]新的一句\n[00:02.00]新的一句二"),
  )
  // ② 内存里立刻换过去了（不用等下一次心跳）
  assert_eq(cm.current_lyrics.length(), 2)
  assert_eq(cm.current_lyrics[0].text, "新的一句")
  // ③ 已经替用户问过了：自动那条路不会再把同一首问一遍
  assert_eq(cm.lyrics_asked_path, audio)
  library_remove(lrc_path)
  @moonui.Backend::terminate(b)
}
