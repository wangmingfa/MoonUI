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
  let audio = @moonui.Fs::temp_dir() + "lunamusic_t161_cover.mp3"
  let lrc_path = lyric_path_for(audio)
  @moonui.Fs::write_text_atomic(lrc_path, "[00:00.00]旧的一句") catch {
    _ => ()
  }
  // 前置：旧文件真的在磁盘上——否则下面那句"覆盖"会退化成"首次写"，
  // 这条判据就什么都没证。
  assert_eq(
    @moonui.Fs::read_text(lrc_path) catch {
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
    @moonui.Fs::read_text(lrc_path) catch {
      _ => None
    },
    Some("[00:00.00]新的一句\n[00:02.00]新的一句二"),
  )
  // ② 内存里立刻换过去了（不用等下一次心跳）
  assert_eq(cm.current_lyrics.length(), 2)
  assert_eq(cm.current_lyrics[0].text, "新的一句")
  // ③ 已经替用户问过了：自动那条路不会再把同一首问一遍
  assert_eq(cm.lyrics_asked_path, audio)
  let _ = @moonui.Fs::remove(lrc_path)
  @moonui.Backend::terminate(b)
}

///|
/// 「T175」判据⑦：批量导出写了 m3u——判据看**文件内容**（选中序，绝对路径）。
/// 只能跑在 native 上：要证的恰是"文件真的落到了磁盘"，wasm 半没有文件系统
/// （同上一条 T161 的账）。文件落在系统临时目录，跑完清掉。
test "T175：批量导出写 m3u，内容按选中序" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let t1 = trk("/m/1.mp3", 100L)
  let t2 = trk("/m/2.mp3", 200L)
  let t3 = trk("/m/3.mp3", 300L)
  engine.stub(t1, [])
  engine.stub(t2, [])
  engine.stub(t3, [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [t1, t2, t3])
  let _ = cm.toggle_select("/m/3.mp3") // 先点 3
  let _ = cm.toggle_select("/m/1.mp3") // 再点 1：选中序 = [3, 1]
  let out = @moonui.Fs::temp_dir() + "lunamusic_t175_export.m3u"
  let _ = @moonui.Fs::remove(out)
  b.push_path_reply(Some(out))
  cm.batch_export_selected() catch {
    _ => abort("批量导出不该失败")
  }
  let text = @moonui.Fs::read_text(out).unwrap()
  assert_true(text.contains("#EXTM3U"))
  // 内容按**选中顺序**（不是曲库序）——3 在 1 前
  assert_eq(m3u_import(text, "/ignored"), ["/m/3.mp3", "/m/1.mp3"])
  let _ = @moonui.Fs::remove(out)
  @moonui.Backend::terminate(b)
}

///|
/// `T180`⑤ 边车优先：同曲 .lrc 与内嵌并存取 LRC。判据只能跑在 native 上
/// （与上一条同一条理由）：要真的在磁盘上放一个 .lrc 夹具，wasm 半 Fs 结构性
/// 缺席。夹具落在系统临时目录，收尾清掉（AGENTS.md：仓库里不留任何文件）。
test "app：边车 .lrc 优先于内嵌歌词（T180⑤）" {
  let base = @moonui.Fs::temp_dir() + "/lunamusic-t180"
  let sidecar = base + ".lrc"
  let _ = @moonui.Fs::remove(sidecar)
  @moonui.Fs::write_text_atomic(
    sidecar, "[00:00.00]边车第一句\n[00:30.00]边车第二句",
  ) catch {
    _ => abort("边车夹具写不进去")
  }
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let t1 : Track = {
    path: base + ".mp3",
    title: "两全",
    artist: "歌手",
    album: "专辑",
    duration_ms: 60000L,
    cover: None,
    loudness: None,
    lyrics: "[00:00.00]内嵌第一句",
  }
  engine.stub(t1, [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [t1])
  cm.player.play_index(0)
  cm.refresh_lyrics() catch {
    _ => ()
  }
  // 边车赢了：两行都是 .lrc 里的，内嵌那句不见
  assert_eq(cm.current_lyrics.length(), 2)
  assert_eq(cm.current_lyrics[0].text, "边车第一句")
  assert_eq(cm.current_lyrics[1].text, "边车第二句")
  // 负控材料：摘边车优先（内嵌先行）这条就红。收尾清夹具。
  let _ = @moonui.Fs::remove(sidecar)
  @moonui.Backend::terminate(b)
}
