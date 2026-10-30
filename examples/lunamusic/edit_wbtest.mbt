///|
/// 「编辑信息」整条链路的无头判据（DESIGN.md C-16）。
///
/// 注入一个假 `write_tags`，把"写文件"这步换成可控结果，其余走真实现：
/// 库、队列、界面、属性栏都按真路径更新。

///|
/// 造一个能被 `probe_many` 返回的 Track。
fn ew_track(path : String) -> Track {
  {
    path,
    title: "旧标题",
    artist: "旧歌手",
    album: "旧专辑",
    duration_ms: 100000L,
    cover: None,
  }
}

///|
test "edit：保存成功——库、队列、播放条、属性栏都换成新值" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let t = ew_track("/m/a.mp3")
  engine.stub(t, [])
  // 假写标签：记下收到了什么，回 Written；探针回一份新元数据。
  let seen : Array[(String, String, String, String)] = []
  let probed : Array[Track] = [
    {
      path: "/m/a.mp3",
      title: "新标题",
      artist: "新歌手",
      album: "新专辑",
      duration_ms: 100000L,
      cover: None,
    },
  ]
  let saved_lib : Array[Bool] = []
  let cm = LunaMusicApp::new(
    app,
    engine,
    probe_many=fn(_paths) { probed },
    write_tags=fn(path, title, artist, album) {
      seen.push((path, title, artist, album))
      Written
    },
    on_library_changed=fn() { saved_lib.push(true) },
  )
  cm.merge_scan("/m", [t])
  cm.prop_path = Some("/m/a.mp3")
  cm.player.replace_queue(cm.lib.tracks)
  cm.player.play_index(0)
  assert_eq(cm.player.track().unwrap().title, "旧标题")
  // 走真保存路径
  cm.save_track_info("/m/a.mp3", "新标题", "新歌手", "新专辑")
  assert_eq(seen.length(), 1)
  assert_eq(seen[0].0, "/m/a.mp3")
  // ① 曲库换新、位置不变、计数不变
  assert_eq(cm.lib.tracks.length(), 1)
  assert_eq(cm.lib.find("/m/a.mp3").unwrap().title, "新标题")
  // ② 队列里那首也是新值（update_track_meta 不清历史/牌堆）
  assert_eq(cm.player.track().unwrap().title, "新标题")
  assert_eq(cm.player.track().unwrap().artist, "新歌手")
  assert_true(cm.player.is_playing())
  // ③ 属性栏文案跟着变
  let prop = cm.ui.unwrap().table.prop.text()
  assert_true(prop.contains("新标题"))
  assert_true(prop.contains("新歌手"))
  // ④ 曲库档即时落盘一次
  assert_eq(saved_lib.length(), 1)
  // ⑤ 播放条读的是 player.track()，所以也是新标题
  assert_eq(cm.ui.unwrap().bar.title.text(), "新标题")
  @moonui.Backend::terminate(b)
}

///|
test "edit：写入失败——库与界面一个字都不改，弹一句原因" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let t = ew_track("/m/b.mp3")
  engine.stub(t, [])
  let saved_lib : Array[Bool] = []
  let cm = LunaMusicApp::new(
    app,
    engine,
    write_tags=fn(_p, _t, _a, _al) { Failed("磁盘满了") },
    on_library_changed=fn() { saved_lib.push(true) },
  )
  cm.merge_scan("/m", [t])
  cm.save_track_info("/m/b.mp3", "新标题", "新歌手", "新专辑")
  // 库没改
  assert_eq(cm.lib.find("/m/b.mp3").unwrap().title, "旧标题")
  // 曲库档没落
  assert_eq(saved_lib.length(), 0)
  // 弹了原因（MockBackend 记 message:标题|正文）
  let dialogs = @moonui.MockBackend::dialog_requests(b)
  assert_eq(dialogs.length(), 1)
  assert_true(dialogs[0].contains("磁盘满了"))
  @moonui.Backend::terminate(b)
}

///|
test "edit：格式不支持——同样不改库，提示不支持写入" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let t = ew_track("/m/c.wav")
  engine.stub(t, [])
  let cm = LunaMusicApp::new(app, engine, write_tags=fn(_p, _t, _a, _al) {
    UnsupportedFormat
  })
  cm.merge_scan("/m", [t])
  cm.save_track_info("/m/c.wav", "x", "y", "z")
  assert_eq(cm.lib.find("/m/c.wav").unwrap().title, "旧标题")
  let dialogs = @moonui.MockBackend::dialog_requests(b)
  assert_eq(dialogs.length(), 1)
  assert_true(dialogs[0].contains("不支持写入"))
  @moonui.Backend::terminate(b)
}

///|
test "edit：小窗懒建且 rebuild_ui 不重建它（输入不丢）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let t = ew_track("/m/d.mp3")
  engine.stub(t, [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [t])
  // 装配完还没打开过：窗还不存在
  assert_true(cm.edit is None)
  cm.open_edit(cm.lib.tracks[0])
  assert_true(cm.edit is Some(_))
  // 用户已经打了半个字，此时整树重建（比如切页签/加目录）——窗必须还是同一只，
  // 输入框里的内容不能被销毁。
  let d = cm.edit.unwrap()
  d.title_in.set_text("打了一半") catch {
    _ => ()
  }
  cm.rebuild_ui()
  assert_eq(cm.edit.unwrap().title_in.text() catch { _ => "" }, "打了一半")
  // 再打开一次复用同一只窗，并预填成新那首的值
  cm.open_edit(cm.lib.tracks[0])
  assert_eq(cm.edit.unwrap().title_in.text() catch { _ => "" }, "旧标题")
  // 取消关窗
  cm.close_edit()
  @moonui.Backend::terminate(b)
}

///|
test "library.set_meta：只换那一条，其余与计数不动" {
  let lib = Library::new()
  lib.merge("/m", [
    {
      path: "/m/1.mp3",
      title: "一",
      artist: "a",
      album: "x",
      duration_ms: 1L,
      cover: None,
    },
    {
      path: "/m/2.mp3",
      title: "二",
      artist: "b",
      album: "y",
      duration_ms: 2L,
      cover: None,
    },
  ])
  assert_true(lib.set_meta("/m/1.mp3", "壹", "A", "X"))
  assert_eq(lib.tracks.length(), 2)
  assert_eq(lib.tracks[0].title, "壹")
  assert_eq(lib.tracks[0].artist, "A")
  assert_eq(lib.tracks[0].album, "X")
  // 另一条一位不动
  assert_eq(lib.tracks[1].title, "二")
  assert_eq(lib.tracks[1].artist, "b")
  // 不存在的 path 返回 false，不新增
  assert_false(lib.set_meta("/m/3.mp3", "三", "c", "z"))
  assert_eq(lib.tracks.length(), 2)
}

///|
test "player.update_track_meta：改在播那首后状态与历史都不动" {
  let e = MockAudioEngine::new()
  let t1 = trk("/m/1.mp3", 1000L)
  let t2 = trk("/m/2.mp3", 2000L)
  e.stub(t1, [])
  e.stub(t2, [])
  let p = Player::new(e, [t1, t2])
  p.play_index(1)
  assert_eq(p.state, Playing)
  let hist_before = p.history.length()
  let updated : Track = {
    path: "/m/2.mp3",
    title: "改过的",
    artist: "改过的歌手",
    album: "改过的专辑",
    duration_ms: 2000L,
    cover: None,
  }
  p.update_track_meta(updated)
  // 当前曲是新值，播放态没变，历史没被清
  assert_eq(p.track().unwrap().title, "改过的")
  assert_eq(p.state, Playing)
  assert_eq(p.history.length(), hist_before)
  // 队列里另一首原样
  assert_eq(p.queue[0].title, "/m/1.mp3")
}
