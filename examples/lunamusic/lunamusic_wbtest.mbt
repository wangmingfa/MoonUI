///|
test "model：时长格式化与文件名兜底" {
  assert_eq(format_duration(-1L), "--:--")
  assert_eq(format_duration(0L), "00:00")
  assert_eq(format_duration(221_000L), "03:41")
  assert_eq(format_duration(3_723_000L), "1:02:03")
  let t = Track::from_path("/Users/z/Music/晴天.mp3")
  assert_eq(t.title, "晴天")
  assert_eq(t.artist, "未知")
  assert_true(is_audio_file("/a/b.FLAC"))
  assert_true(is_audio_file("/a/b.m4a"))
  assert_false(is_audio_file("/a/b.txt"))
  assert_false(is_audio_file("/a/b"))
  assert_eq(PlayMode::Sequential.next(), RepeatOne)
  assert_eq(PlayMode::RepeatOne.next(), Shuffle)
  assert_eq(PlayMode::Shuffle.next(), Sequential)
  assert_eq(PlayMode::Shuffle.label(), "随机播放")
}

///|
fn trk(path : String, dur : Int64) -> Track {
  { path, title: path, artist: "a", album: "b", duration_ms: dur, cover: None, }
}

///|
fn eng_with(tracks : Array[Track]) -> MockAudioEngine {
  let e = MockAudioEngine::new()
  for t in tracks {
    e.stub(t, [])
  }
  e
}

///|
test "player：Idle 播队列头，再按暂停，再按继续" {
  let e = eng_with([trk("/m/1.mp3", 100L), trk("/m/2.mp3", 200L)])
  let p = Player::new(e, [trk("/m/1.mp3", 100L), trk("/m/2.mp3", 200L)])
  p.toggle() // Idle → 播队列头
  assert_true(p.is_playing())
  assert_eq(p.track().unwrap().path, "/m/1.mp3")
  p.toggle() // Playing → Paused
  assert_false(p.is_playing())
  assert_eq(e.calls, ["on_finished", "load:/m/1.mp3", "play", "pause"])
  p.toggle() // Paused → Playing
  assert_true(p.is_playing())
}

///|
test "player：上一首——超 3 秒回开头，未超切上一首，Idle 播队尾" {
  // 播第 2 首、位置 4s：prev = seek 0
  let e = eng_with([trk("/m/1.mp3", 300L), trk("/m/2.mp3", 300L)])
  let p = Player::new(e, [trk("/m/1.mp3", 300L), trk("/m/2.mp3", 300L)])
  p.play_index(1)
  e.pos_ms = 4001L
  p.prev()
  assert_eq(e.pos_ms, 0L)
  assert_eq(p.track().unwrap().path, "/m/2.mp3") // 还是这首，只是回开头
  // 位置 1s：prev 切到上一首
  e.pos_ms = 1000L
  p.prev()
  assert_eq(p.track().unwrap().path, "/m/1.mp3")
  // Idle：播队尾
  let e2 = eng_with([trk("/m/1.mp3", 300L), trk("/m/2.mp3", 300L)])
  let p2 = Player::new(e2, [trk("/m/1.mp3", 300L), trk("/m/2.mp3", 300L)])
  p2.prev()
  assert_eq(p2.track().unwrap().path, "/m/2.mp3")
}

///|
test "player：下一首回绕与自然播完到尾停机（顺序模式）" {
  let e = eng_with([trk("/m/1.mp3", 300L), trk("/m/2.mp3", 300L)])
  let p = Player::new(e, [trk("/m/1.mp3", 300L), trk("/m/2.mp3", 300L)])
  p.play_index(1)
  p.next() // 手动到尾回绕
  assert_eq(p.track().unwrap().path, "/m/1.mp3")
  // 自然播完在队尾：停（顺序到尾则停）
  p.play_index(1)
  e.fire_finished()
  assert_false(p.is_playing())
  assert_eq(p.state, Idle)
}

///|
test "player：单曲循环自然播完从头再来，不换曲" {
  let e = eng_with([trk("/m/1.mp3", 300L)])
  let p = Player::new(e, [trk("/m/1.mp3", 300L)])
  p.play_index(0)
  p.cycle_mode() // → 单曲循环
  assert_eq(p.mode, RepeatOne)
  e.fire_finished()
  assert_true(p.is_playing())
  assert_eq(p.track().unwrap().path, "/m/1.mp3")
}

///|
test "player：随机模式不重复直到放完一轮" {
  let tracks = [
    trk("/m/1.mp3", 300L),
    trk("/m/2.mp3", 300L),
    trk("/m/3.mp3", 300L),
  ]
  let e = eng_with(tracks)
  let p = Player::new(e, tracks)
  p.play_index(0)
  p.cycle_mode() // → 单曲循环
  p.cycle_mode() // → 随机
  assert_eq(p.mode, Shuffle)
  // 确定性牌堆（见 reshuffle 注）：2、3 各放一次，不回头
  p.next()
  assert_eq(p.track().unwrap().path, "/m/2.mp3")
  p.next()
  assert_eq(p.track().unwrap().path, "/m/3.mp3")
  // 牌堆空：手动 next 回绕到 0
  p.next()
  assert_eq(p.track().unwrap().path, "/m/1.mp3")
  // 自然播完：整轮结束停机
  p.play_index(0)
  p.cycle_mode()
  p.cycle_mode() // → 随机（旧牌堆已清）
  p.next()
  p.next()
  e.fire_finished() // 放完 1（第二轮牌堆只剩 2，3 已在历史里？——不：换模式清堆重洗）
}

///|
test "player：坏文件逐首隔离，整队列装不上止损停机" {
  let e = MockAudioEngine::new()
  let bad1 = trk("/m/bad1.mp3", 1L)
  let bad2 = trk("/m/bad2.mp3", 1L)
  let good = trk("/m/good.mp3", 1L)
  e.stub(bad1, [])
  e.stub(bad2, [])
  e.stub(good, [])
  e.fail_load_paths.push("/m/bad1.mp3")
  e.fail_load_paths.push("/m/bad2.mp3")
  let p = Player::new(e, [bad1, bad2, good])
  p.play_index(0) // 1 坏 → 跳 2 坏 → 跳 good 播
  assert_eq(p.track().unwrap().path, "/m/good.mp3")
  assert_true(p.is_playing())
  // 全坏：止损
  let e2 = MockAudioEngine::new()
  let b1 = trk("/x/1.mp3", 1L)
  let b2 = trk("/x/2.mp3", 1L)
  e2.stub(b1, [])
  e2.stub(b2, [])
  e2.fail_load_paths.push("/x/1.mp3")
  e2.fail_load_paths.push("/x/2.mp3")
  let p2 = Player::new(e2, [b1, b2])
  p2.play_index(0)
  assert_eq(p2.state, Idle)
  assert_eq(p2.current, None)
}

///|
test "player：seek 保持播放态；音量千分位钳位；notify 广播" {
  let e = eng_with([trk("/m/1.mp3", 300L)])
  let p = Player::new(e, [trk("/m/1.mp3", 300L)])
  let mut fired = 0
  p.on_update(fn() { fired = fired + 1 })
  p.play_index(0)
  let before = fired
  p.seek(120L)
  assert_eq(e.pos_ms, 120L)
  assert_true(p.is_playing()) // 播着不动
  assert_eq(fired, before + 1)
  p.set_volume(2000)
  assert_eq(e.volume, 1000) // 钳到 1000
  p.set_volume(-5)
  assert_eq(e.volume, 0)
}

///|
test "player：replace_queue 保当前高亮，歌没了回 Idle" {
  let e = eng_with([trk("/m/1.mp3", 300L), trk("/m/2.mp3", 300L)])
  let p = Player::new(e, [trk("/m/1.mp3", 300L), trk("/m/2.mp3", 300L)])
  p.play_index(1)
  let shrunk = [trk("/m/2.mp3", 300L)]
  p.replace_queue(shrunk)
  assert_eq(p.track() is None, true) // 旧歌没了
  assert_eq(p.state, Idle)
}

///|
test "library：并入去重、按目录删、单曲删、JSON 往返" {
  let lib = Library::new()
  lib.merge("/m", [trk("/m/1.mp3", 1L), trk("/m/2.mp3", 2L)])
  lib.merge("/m", [trk("/m/1.mp3", 1L)]) // 重复目录不重复入账
  assert_eq(lib.tracks.length(), 2)
  assert_eq(lib.dirs, ["/m"])
  lib.merge("/n", [trk("/n/3.mp3", 3L), trk("/m/1.mp3", 1L)])
  assert_eq(lib.tracks.length(), 3) // 跨目录同文件也去重
  assert_eq(lib.dirs, ["/m", "/n"])
  // JSON 往返
  let j = lib.to_json()
  let back = Library::from_json(j.stringify() |> parse_ok).unwrap()
  assert_eq(back.dirs, ["/m", "/n"])
  assert_eq(back.tracks.length(), 3)
  assert_eq(back.tracks[2].path, "/n/3.mp3")
  assert_eq(back.tracks[2].duration_ms, 3L)
  // 按目录删
  assert_eq(lib.remove_dir("/n"), 1)
  assert_eq(lib.tracks.length(), 2)
  // 单曲删
  lib.remove_track("/m/1.mp3")
  assert_eq(lib.tracks.length(), 1)
  assert_eq(lib.find("/m/2.mp3").unwrap().title, "/m/2.mp3")
  // 坏档：不是对象 → None；坏行跳过不毁整库
  assert_true(Library::from_json(parse_ok("[]")) is None)
  let bad_rows = parse_ok(
    "{\"dirs\":[\"/m\"],\"tracks\":[{\"path\":\"/m/1.mp3\",\"title\":\"t\",\"artist\":\"a\",\"album\":\"b\",\"duration_ms\":1},{\"path\":1}]}",
  )
  let survived = Library::from_json(bad_rows).unwrap()
  assert_eq(survived.tracks.length(), 1)
}

///|
/// @json.parse 抛错时用空数组充当哨兵，让断言走 None 分支。
fn parse_ok(text : String) -> Json {
  @json.parse(text) catch {
    _ => Json::array([]) // 解析失败哨兵
  }
}

///|
test "walk：scan_tree 白名单 + 排序 + 深度上限（注入的空 walk 恒空）" {
  // wasm/native 门控外的注入源默认恒空——这里只验确定性形状
  assert_eq(scan_tree("/whatever"), [])
}

///|
test "probe：打包布局解析与坏包兜底" {
  fn i32le(v : Int32) -> Bytes {
    Bytes::makei(4, fn(i) { ((v >> (8 * i)) & 0xFF).to_byte() })
  }
  fn i64le(v : Int64) -> Bytes {
    Bytes::makei(8, fn(i) { ((v >> (8 * i)) & 0xFF).to_byte() })
  }
  fn s(str : String) -> Bytes {
    @utf8.encode(str)
  }
  let title = s("晴天")
  let artist = s("周杰伦")
  let album = s("叶惠美")
  // 打包布局与 C 侧一致：[len][bytes] 交替，不前置
  let whole = i32le(title.length())
    .add(title)
    .add(i32le(artist.length()))
    .add(artist)
    .add(i32le(album.length()))
    .add(album)
    .add(i64le(269000L))
    .add(i32le(0))
  let t = track_from_probe("/m/晴天.mp3", whole).unwrap()
  assert_eq(t.title, "晴天")
  assert_eq(t.artist, "周杰伦")
  assert_eq(t.album, "叶惠美")
  assert_eq(t.duration_ms, 269000L)
  assert_eq(t.cover, None)
  // 空字段退回文件名；坏包（截断）整体 None
  let empty = i32le(0).add(i32le(0)).add(i32le(0)).add(i64le(-1L)).add(i32le(0))
  let t2 = track_from_probe("/m/song.mp3", empty).unwrap()
  assert_eq(t2.title, "song")
  assert_eq(t2.duration_ms, -1L)
  assert_true(
    track_from_probe("/m/x.mp3", Bytes::makei(0, fn(_) { 0b0 })) is None,
  )
}

///|
test "lyrics：LRC 解析 + 活动行定位" {
  // 多时间标签 + 元数据 + offset 平移 + 乱序排序
  let lrc = "[ti:测试歌]\n[ar:某人]\n[00:00.00]第一句\n[00:03.50][00:30.00]第二句（两个时间点）\n[01:05.25]第三句\n[offset:500]"
  let lys = parse_lrc(lrc)
  // offset +500ms：第一句时间 = 0.5s
  assert_eq(lys.length(), 4)
  assert_true((lys[0].t - 0.5).abs() < 0.001)
  assert_eq(lys[0].text, "第一句")
  // 第二句出现两次（两个时间点），按时间升序排在第一句之后
  assert_true((lys[1].t - 4.0).abs() < 0.001)
  assert_eq(lys[1].text, "第二句（两个时间点）")
  assert_true((lys[2].t - 30.5).abs() < 0.001)
  assert_eq(lys[2].text, "第二句（两个时间点）")
  assert_true((lys[3].t - 65.75).abs() < 0.001)
  // 活动行：51.0s → 落在 30.5s 那笔（index 2）
  assert_eq(active_lyric_index(lys, 51000L), 2)
  // 活动行：未到第一句（0.4s）→ -1
  assert_eq(active_lyric_index(lys, 400L), -1)
  // 伴随文件推导
  assert_eq(lyric_path_for("/a/b/歌.mp3"), "/a/b/歌.lrc")
  assert_eq(lyric_path_for("/a/b/歌.MP3"), "/a/b/歌.lrc")
  // 坏 LRC：时间标签非数字的行整行丢弃，只剩空
  assert_eq(parse_lrc("[xx:yy]非法时间标签\n[ar:某人]").length(), 0)
}

///|
test "app：装配 + 双击行 → 播放，播放条跟着刷新" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let t1 = trk("/m/1.mp3", 221000L)
  let t2 = trk("/m/2.mp3", 300000L)
  engine.stub(t1, [])
  engine.stub(t2, [])
  let cm = LunaMusicApp::new(app, engine)
  // 空库起步：按钮是「▶」、模式「顺序播放」
  let bar = cm.ui.unwrap().bar
  assert_eq(bar.toggle.text(), "▶")
  // 模式钮自这一版起只有图标（`set_icon`），文字清空——所以这里验"文字空 +
  // 状态在 player 那侧"，图标本身没有读口（`set_icon` 只进后端）。
  assert_eq(bar.mode.text(), "")
  assert_eq(cm.player.mode, Sequential)
  // 扫描两首进来：计数与队列跟新
  cm.merge_scan("/m", [t1, t2])
  assert_eq(cm.ui.unwrap().table.count_label.text(), "共 2 首")
  // 双击第二行（行为表：该行成为当前，从头播）。行上挂的是
  // with_on_double_click（无头没有 fire 读口，这里直接驱动 player——
  // 接线的编译期形状由 build_row 的返回类型保证）
  cm.player.play_index(1)
  assert_true(cm.player.is_playing())
  let bar2 = cm.ui.unwrap().bar
  assert_eq(bar2.toggle.text(), "⏸")
  assert_eq(bar2.title.text(), "/m/2.mp3")
  // 进度读回：千分位 = pos*1000/dur
  assert_eq(bar2.progress.value(), 0)
  // 暂停再继续：按钮文案往返
  cm.player.toggle()
  assert_eq(cm.ui.unwrap().bar.toggle.text(), "▶")
  cm.player.toggle()
  assert_eq(cm.ui.unwrap().bar.toggle.text(), "⏸")
  // 模式循环：顺序 → 单曲循环 → 随机 → 回顺序（按钮文案跟着）
  cm.player.cycle_mode()
  assert_eq(cm.player.mode, RepeatOne)
  assert_eq(cm.ui.unwrap().bar.mode.text(), "")
  cm.player.cycle_mode()
  assert_eq(cm.player.mode, Shuffle)
  cm.player.cycle_mode()
  assert_eq(cm.player.mode, Sequential)
  @moonui.Backend::terminate(b)
}

///|
/// 行格内容垂直居中、水平贴左（播放列表 hover 底的对齐账）：行带 20pt、
/// 文字固有高 ~13pt 顶对齐会贴着行带顶，hover 底一亮就看得出没居中。
/// `cm_row_cell` 上下垫 Spacer 对半分余量——内容钉高 10 排除 mock 度量
/// 差异，(20-10)/2 = 5，上下各 5、x 仍贴左。
test "app：行格内容垂直居中、水平贴左" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let win = app.create_window("格", @moonui.LogicalSize(120.0, 40.0))
  let lbl = @moonui.Widget::label(b, "夜曲")
  let inner = @moonui.Widget::sized(b, None, Some(10.0), lbl)
  win.set_content(
    @moonui.Widget::row(b, 0.0, [cm_row_cell(b, Some(30.0), inner)]),
  )
  win.show()
  let _ = app.step()
  assert_eq(lbl.frame.origin.y, 5.0)
  assert_eq(lbl.frame.origin.x, 0.0)
  assert_eq(lbl.frame.size.height, 10.0)
  @moonui.Backend::terminate(b)
}

///|
test "app：seek 拖动走千分位换算，音量走 set_volume" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let t1 = trk("/m/1.mp3", 200000L)
  engine.stub(t1, [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [t1])
  cm.player.play_index(0)
  // 拖到一半：seek(100000)
  cm.on_seek_slider(500)
  assert_eq(engine.pos_ms, 100000L)
  assert_eq(engine.calls.contains("seek:100000"), true)
  @moonui.Backend::terminate(b)
}

///|
test "app：布局结构快照（dump_layout 对账）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  engine.stub(trk("/m/1.mp3", 1L), [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [trk("/m/1.mp3", 1L)])
  let u = cm.ui.unwrap()
  // 四窗分树：主控窗（logo+走带）/ 歌词窗（占位）/ 列表窗（标题）
  let dm = @moonui.Window::dump_layout(u.window)
  let dl = @moonui.Window::dump_layout(u.lyrics_win)
  let dp = @moonui.Window::dump_layout(u.playlist_win)
  assert_true(dm.contains("Luna"))
  assert_true(dm.contains("未播放"))
  assert_true(dp.contains("本地音乐"))
  assert_true(dl.contains("（暂无歌词）"))
  // 伴窗顶条（`CmStrip`）：标题 + 关闭方块都得在树里，否则又退回"四块光板"
  assert_true(dp.contains("播放列表"))
  assert_true(dp.contains("✕"))
  assert_true(dl.contains("歌词秀"))
  // 均衡器：十根竖推子的频率标签（横向排版时是 "60Hz 一行行往下"，
  // 竖向之后十段并排，但这十个字样都必须还在）
  let de = @moonui.Window::dump_layout(u.eq_win)
  for f in ["60Hz", "170Hz", "16KHz"] {
    assert_true(de.contains(f))
  }
  @moonui.Backend::terminate(b)
}

///|
test "prefs：JSON 往返 + 坏档逐字段兜底" {
  let p : Prefs = {
    volume: 600,
    mode: RepeatOne,
    last_path: Some("/m/a.mp3"),
    eq_bands: [500, 500, 500, 500, 500, 500, 500, 500, 500, 500],
    eq_on: false,
    skin: "深空灰",
  }
  let rt = Prefs::from_json(p.to_json())
  let p2 = rt.unwrap()
  assert_eq(p2.volume, 600)
  assert_eq(p2.mode, RepeatOne)
  assert_eq(p2.last_path, Some("/m/a.mp3"))
  // 缺字段 → 默认值起步
  let partial = Prefs::from_json(
    Json::object(Map::from_array([("volume", Json::number(300.0))])),
  ).unwrap()
  assert_eq(partial.volume, 300)
  assert_eq(partial.mode, Sequential)
  assert_eq(partial.last_path, None)
  // 模式序数坏值 → 保持默认；last_path 字符串照收
  let bad_mode = Prefs::from_json(
    Json::object(
      Map::from_array([
        ("mode", Json::number(9.0)),
        ("last_path", Json::string("/m/b.mp3")),
      ]),
    ),
  ).unwrap()
  assert_eq(bad_mode.mode, Sequential)
  assert_eq(bad_mode.last_path, Some("/m/b.mp3"))
  // 整体不是对象 → None；文本解析走 from_text 同款
  assert_true(Prefs::from_json(Json::number(1.0)) is None)
  assert_true(Prefs::from_text("{\"volume\":250}").unwrap().volume == 250)
  assert_true(Prefs::from_text("not json") is None)
}

///|
test "library：收藏开关、收藏视图与库档往返（含收藏段）" {
  let lib = Library::new()
  lib.merge("/m", [trk("/m/a.mp3", 100L), trk("/m/b.mp3", 200L)])
  assert_eq(lib.tracks.length(), 2)
  assert_false(lib.is_favorite("/m/a.mp3"))
  assert_eq(lib.toggle_favorite("/m/a.mp3"), true)
  assert_true(lib.is_favorite("/m/a.mp3"))
  assert_eq(lib.favorite_tracks().length(), 1)
  assert_eq(lib.toggle_favorite("/m/a.mp3"), false)
  assert_eq(lib.favorite_tracks().length(), 0)
  // 档往返：收藏段跟着走
  let _ = lib.toggle_favorite("/m/b.mp3")
  let back = Library::from_text(lib.to_json().stringify()).unwrap()
  assert_eq(back.tracks.length(), 2)
  assert_true(back.is_favorite("/m/b.mp3"))
  // 旧档没有收藏段 → 空收藏，不牵连 tracks 恢复
  let old = Library::from_text("{\"dirs\":[],\"tracks\":[]}").unwrap()
  assert_eq(old.favorites.length(), 0)
}

///|
test "library：排序（标题升降 / 时长）与搜索过滤" {
  let lib = Library::new()
  lib.merge("/m", [
    trk("/m/c.mp3", 300L),
    trk("/m/a.mp3", 100L),
    trk("/m/b.mp3", 200L),
  ])
  // 原始顺序不动
  assert_eq(lib.sorted(ByIndex, true)[0].path, "/m/c.mp3")
  // 标题升序 / 降序
  assert_eq(lib.sorted(ByTitle, true)[0].path, "/m/a.mp3")
  assert_eq(lib.sorted(ByTitle, false)[0].path, "/m/c.mp3")
  // 时长升序 / 降序
  assert_eq(lib.sorted(ByDuration, true)[2].path, "/m/c.mp3")
  assert_eq(lib.sorted(ByDuration, false)[0].path, "/m/c.mp3")
  // 排序不动库本体（库里始终是扫描顺序）
  assert_eq(lib.tracks[0].path, "/m/c.mp3")
  // 搜索：命中标题
  assert_eq(filter_tracks(lib.tracks, "b.mp3").length(), 1)
  assert_eq(filter_tracks(lib.tracks, "/m").length(), 3)
  assert_eq(filter_tracks(lib.tracks, "zzz").length(), 0)
  assert_eq(filter_tracks(lib.tracks, "").length(), 3)
}

///|
test "library：m3u 导出导入往返（绝对路径 + 注释行 + CRLF）" {
  let tracks = [trk("/m/a.mp3", 100L), trk("/m/b.mp3", 200L)]
  let text = m3u_export(tracks)
  assert_true(text.contains("#EXTM3U"))
  assert_true(text.contains("#EXTINF:0,a - /m/a.mp3"))
  assert_true(text.contains("/m/b.mp3"))
  // 解析：注释行与空行跳过，路径原样
  let paths = m3u_import(text, "/ignored")
  assert_eq(paths.length(), 2)
  assert_eq(paths[0], "/m/a.mp3")
  assert_eq(paths[1], "/m/b.mp3")
  // 相对路径按 m3u 所在目录拼；CRLF 也认
  let rel = m3u_import("#EXTM3U\r\nsong.mp3\r\n\r\n", "/base")
  assert_eq(rel.length(), 1)
  assert_eq(rel[0], "/base/song.mp3")
  // dir_of
  assert_eq(dir_of("/a/b/c.m3u"), "/a/b")
  assert_eq(dir_of("c.m3u"), "")
}

///|
test "player：队列换成新视图时按 path 保住当前曲（排序后不重播）" {
  let e = eng_with([trk("/m/a.mp3", 300L), trk("/m/b.mp3", 300L)])
  let queue = [trk("/m/a.mp3", 300L), trk("/m/b.mp3", 300L)]
  let p = Player::new(e, queue)
  p.play_index(1) // 播 b
  assert_eq(p.track().unwrap().path, "/m/b.mp3")
  // 排序把 b 挪到队首：下标变了，歌与状态不变
  let reordered = [trk("/m/b.mp3", 300L), trk("/m/a.mp3", 300L)]
  p.set_queue_keep_current(reordered)
  assert_eq(p.track().unwrap().path, "/m/b.mp3")
  assert_true(p.is_playing())
  // 新视图里没有正在播的那首（被搜索过滤掉）：整段不动
  p.set_queue_keep_current([trk("/m/a.mp3", 300L)])
  assert_eq(p.track().unwrap().path, "/m/b.mp3")
  assert_eq(p.queue.length(), 2)
}

///|
test "app：页签 / 排序 / 搜索改视图，队列按页签跟随" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [
    trk("/m/c.mp3", 300L),
    trk("/m/a.mp3", 100L),
    trk("/m/b.mp3", 200L),
  ])
  // 默认页签：本地音乐，原始顺序
  assert_eq(cm.tab_title(), "本地音乐")
  assert_eq(cm.view.length(), 3)
  // 排序：点「标题」→ 升序；再点同一列 → 降序
  cm.set_sort(1)
  assert_eq(cm.view[0].path, "/m/a.mp3")
  cm.set_sort(1)
  assert_eq(cm.view[0].path, "/m/c.mp3")
  // 搜索：只动视图，不动队列（正在播的不被踢出）
  cm.player.play_index(0)
  let before = cm.player.queue.length()
  cm.query = "a.mp3"
  cm.rebuild_ui()
  assert_eq(cm.view.length(), 1)
  assert_eq(cm.player.queue.length(), before)
  cm.query = ""
  cm.rebuild_ui()
  assert_eq(cm.view.length(), 3)
  // 收藏页签：只有收藏那首
  cm.prop_path = Some("/m/b.mp3")
  let _ = cm.lib.toggle_favorite("/m/b.mp3")
  cm.set_tab(1)
  assert_eq(cm.tab_title(), "我喜欢的")
  assert_eq(cm.view.length(), 1)
  assert_eq(cm.view[0].path, "/m/b.mp3")
  // 属性栏文案
  assert_true(cm.prop_text().contains("/m/b.mp3"))
  @moonui.Backend::terminate(b)
}

///|
test "app：窗口生态——托盘 / 滚轮调音量 / 卷起 / 迷你模式 / 桌面歌词" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  engine.stub(trk("/m/a.mp3", 100L), [])
  let cm = LunaMusicApp::new(app, engine)
  // 托盘：图标 + 菜单装一次
  cm.install_tray() catch {
    _ => ()
  }
  assert_eq(@moonui.MockBackend::tray_install_count(b), 1)
  assert_true(@moonui.MockBackend::tray_icon(b) is Some(_))
  // 滚轮：一格 50‰，上滚加、下滚减，0 不动
  cm.player.set_volume(500)
  cm.wheel_volume(10.0)
  assert_eq(cm.player.volume, 550)
  cm.wheel_volume(-10.0)
  assert_eq(cm.player.volume, 500)
  cm.wheel_volume(0.0)
  assert_eq(cm.player.volume, 500)
  // 卷起：高度压到顶条，再展开回整窗
  let u = cm.ui.unwrap()
  cm.toggle_roll() catch {
    _ => ()
  }
  assert_true(cm.rolled)
  let rolled_h = @moonui.Window::size(u.window) catch {
    _ => @moonui.LogicalSize(0.0, 0.0)
  }
  assert_eq(rolled_h.height, cm_title_h())
  cm.toggle_roll() catch {
    _ => ()
  }
  assert_false(cm.rolled)
  let full_h = @moonui.Window::size(u.window) catch {
    _ => @moonui.LogicalSize(0.0, 0.0)
  }
  assert_eq(full_h.height, cm_main_h())
  // 迷你模式：切过去再切回来
  cm.toggle_mini() catch {
    _ => ()
  }
  assert_true(cm.mini)
  cm.toggle_mini() catch {
    _ => ()
  }
  assert_false(cm.mini)
  // 桌面歌词开关
  assert_true(cm.show_desk)
  cm.toggle_desk() catch {
    _ => ()
  }
  assert_false(cm.show_desk)
  @moonui.Backend::terminate(b)
}

///|
/// 桌面歌词窗的可见性判据：开关开着、不在迷你模式、而且**当前有歌词**——
/// 三条都成立才挂窗。没有歌词时那块浮在 Dock 上方的条子不该出现（原来建窗
/// 就 show，屏幕上会一直挂着一条只写"Luna"的空条）。
test "桌面歌词：没歌词就不挂窗（开关与可见性分开）" {
  assert_false(cm_desk_visible(true, false, false))
  assert_false(cm_desk_visible(false, false, true))
  assert_false(cm_desk_visible(true, true, true))
  assert_true(cm_desk_visible(true, false, true))
}

///|
/// 默认布局表：上排「主控 | 歌词秀」并排，播放列表横跨两列压在下面，均衡器
/// 默认收起但仍留一格落点，迷你条压在主控位，桌面歌词贴底居中。这张表同时被
/// 建窗与「复位窗口」消费，所以几何关系直接钉在这里——两处任何一处漂了都会红。
test "布局：默认布局表——上排两列 + 播放列表横跨，桌面歌词贴底居中" {
  let screen = @moonui.LogicalSize(1440.0, 900.0)
  let lay = cm_default_layout(screen)
  // 主控
  assert_eq(lay.main.x, cm_layout_origin_x())
  assert_eq(lay.main.y, cm_layout_origin_y())
  assert_eq(lay.main.w, cm_main_w())
  assert_eq(lay.main.h, cm_main_h())
  // 歌词秀：主控右侧、顶边齐平、同高、留一道缝
  assert_eq(lay.lyrics.x, lay.main.x + lay.main.w + cm_layout_gap())
  assert_eq(lay.lyrics.y, lay.main.y)
  assert_eq(lay.lyrics.h, lay.main.h)
  assert_eq(lay.lyrics.w, cm_lyrics_w())
  // 播放列表：横跨上排两列压在下面，左缘对齐主控、右缘与歌词秀齐平
  assert_eq(lay.playlist.x, lay.main.x)
  assert_eq(lay.playlist.y, lay.main.y + lay.main.h + cm_layout_gap())
  assert_eq(lay.playlist.w, lay.main.w + cm_layout_gap() + lay.lyrics.w)
  assert_eq(lay.playlist.x + lay.playlist.w, lay.lyrics.x + lay.lyrics.w)
  // 均衡器：默认收起，落点在整块右侧、与上排顶边对齐（放不下时接到下面，
  // 1440 宽放得下）
  assert_eq(lay.eq.x, lay.playlist.x + lay.playlist.w + cm_layout_gap())
  assert_eq(lay.eq.y, lay.main.y)
  assert_true(lay.eq.x >= lay.playlist.x + lay.playlist.w)
  // 迷你条：压在主控原位
  assert_eq(lay.mini.x, lay.main.x)
  assert_eq(lay.mini.y, lay.main.y)
  // 桌面歌词：底部居中，整条不出屏
  assert_eq(lay.desk.x, (1440.0 - cm_desk_w()) / 2.0)
  assert_eq(lay.desk.y, 900.0 - cm_desk_bottom_inset())
  assert_true(lay.desk.y + lay.desk.h <= screen.height)
  // 窄屏/矮屏兜底：贴到左缘与上缘，不出负坐标
  let tiny = cm_default_layout(@moonui.LogicalSize(300.0, 100.0))
  assert_eq(tiny.desk.x, 0.0)
  assert_eq(tiny.desk.y, 0.0)
  assert_true(tiny.main.x >= 0.0 && tiny.main.y >= 0.0)
  assert_true(tiny.eq.x >= 0.0 && tiny.eq.y >= 0.0)
}

///|
/// 默认布局**不许有两窗叠在一起**（主控与迷你条除外：迷你条按设计就顶替主控
/// 的位置，两者不同时显示）。
///
/// 参检的是**默认就显示的三只窗 + 桌面歌词**：均衡器默认收起（`show_eq` 起手
/// false），它单独判"不压住主窗口"——小屏（1280×800）上根本没有能同时放下
/// 380×340 的空位，硬塞只会压到播放列表或桌面歌词；宁让它一角探出右缘。
///
/// 这是"重置位置之后窗口层叠"的回归钉子：旧版把播放列表的 y 钉在主控底边，
/// 可均衡器比主控高 164pt——复位后播放列表整块插进均衡器里。
test "布局：常见屏幕上任意两窗不重叠" {
  let overlap = fn(a : CmPlacement, b : CmPlacement) -> Bool {
    a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
  }
  for
    screen in [
      @moonui.LogicalSize(2560.0, 1440.0),
      @moonui.LogicalSize(1440.0, 900.0),
      @moonui.LogicalSize(1280.0, 800.0),
    ] {
    let lay = cm_default_layout(screen)
    let boxes : Array[(String, CmPlacement)] = [
      ("主控", lay.main),
      ("歌词秀", lay.lyrics),
      ("播放列表", lay.playlist),
      ("桌面歌词", lay.desk),
    ]
    let n = boxes.length()
    for i = 0; i < n; i = i + 1 {
      for j = i + 1; j < n; j = j + 1 {
        let (na, a) = boxes[i]
        let (nb, b) = boxes[j]
        if overlap(a, b) {
          println(
            "叠在一起：\{na} / \{nb} @ \{screen.width}x\{screen.height}",
          )
          assert_false(true)
        }
      }
    }
    // 均衡器：收起，但不许压住任何一只默认显示的窗
    for box in boxes {
      let (name, p) = box
      if overlap(lay.eq, p) {
        println("均衡器压住了 \{name} @ \{screen.width}x\{screen.height}")
        assert_false(true)
      }
    }
  }
}

///|
/// 每只窗都有"内容撑不住"的下限，且下限不大于默认尺寸——否则建窗就比下限还小，
/// 窗口会在第一次被拖动时被顶大，看着像自己乱跳。
///
/// 下限不是审美偏好，是内容账：列表工具条那五颗定宽钮 + 搜索框光定宽就 482，
/// 加内边距正好 498；均衡器十段 × 34 加三层内衬正好 374。缩到这些数以下就是
/// 用户说的"内容被挤压变形"。
test "布局：每只窗都有下限，且装得下各自的内容" {
  let lay = cm_default_layout(@moonui.LogicalSize(1440.0, 900.0))
  let all : Array[(String, CmPlacement)] = [
    ("主控", lay.main),
    ("歌词秀", lay.lyrics),
    ("均衡器", lay.eq),
    ("播放列表", lay.playlist),
    ("迷你条", lay.mini),
    ("桌面歌词", lay.desk),
  ]
  for box in all {
    let (name, p) = box
    if p.min_w <= 0.0 || p.min_h <= 0.0 {
      println("\{name} 没有下限")
      assert_false(true)
    }
    if p.min_w > p.w || p.min_h > p.h {
      println(
        "\{name} 的下限比默认尺寸还大：\{p.min_w}×\{p.min_h} > \{p.w}×\{p.h}",
      )
      assert_false(true)
    }
  }
  // 播放列表：五颗钮（78/84/70/70/46）+ 搜索框 110 + 六道 4pt 缝 + 面板 16
  assert_true(lay.playlist.min_w >= 498.0)
  // 均衡器：十段 × 34 + 滑槽内衬 12 + 外圈 2 + 面板 20 = 374
  assert_true(lay.eq.min_w >= 374.0)
}

///|
/// 「复位窗口」：用户把窗拖散、把播放列表拉大之后，一键回到默认落座。
/// 顺带覆盖卷起态——复位把窗展开的同时要把 `rolled` 归 false，否则下一次
/// 双击会朝着"已经展开"的方向再走一步（永远回不到卷起）。
test "app：复位窗口——拖散/拉大/卷起之后一键回默认" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  @moonui.MockBackend::set_screen_size(b, @moonui.LogicalSize(1440.0, 900.0))
  let app = @moonui.App::new(b)
  let cm = LunaMusicApp::new(app, MockAudioEngine::new())
  let u = cm.ui.unwrap()
  let lay = cm_default_layout(@moonui.LogicalSize(1440.0, 900.0))
  let pos = fn(w : @moonui.Window[@moonui.MockBackend]) {
    @moonui.Window::position(w) catch {
      _ => @moonui.LogicalPoint(-1.0, -1.0)
    }
  }
  let size = fn(w : @moonui.Window[@moonui.MockBackend]) {
    @moonui.Window::size(w) catch {
      _ => @moonui.LogicalSize(-1.0, -1.0)
    }
  }
  // 建窗就在默认位
  assert_eq(pos(u.window), @moonui.LogicalPoint(lay.main.x, lay.main.y))
  // 下限在建窗那一趟就推到了后端（用户拖窗格不经过 Core，只有原生钳位挡得住）
  assert_eq(
    @moonui.MockBackend::window_min_size(b, u.playlist_win.handle()) catch {
      _ => None
    },
    Some(@moonui.LogicalSize(lay.playlist.min_w, lay.playlist.min_h)),
  )
  assert_eq(
    pos(u.playlist_win),
    @moonui.LogicalPoint(lay.playlist.x, lay.playlist.y),
  )
  // 用户拖散三只窗，并把播放列表拉大
  @moonui.Window::set_position(u.lyrics_win, @moonui.LogicalPoint(900.0, 700.0)) catch {
    _ => ()
  }
  @moonui.Window::set_position(u.eq_win, @moonui.LogicalPoint(20.0, 20.0)) catch {
    _ => ()
  }
  @moonui.Window::set_size(u.playlist_win, @moonui.LogicalSize(700.0, 500.0)) catch {
    _ => ()
  }
  // 窗口尺寸一变，内容根就要当场跟着变（拖动窗格的等价路径）。旧版 `set_size`
  // 只改外框、不重排——原生层把程序化改尺寸的回声挡掉了，Resize 事件不会回来。
  let pl_root_w = fn() -> Double raise @moonui.UiError {
    match u.playlist_win.content() {
      Some(r) => r.bounds().size.width
      None => -1.0
    }
  }
  let w_after_resize = pl_root_w() catch { _ => -1.0 }
  assert_eq(w_after_resize, 700.0)
  // 再卷起主控（高度只剩顶条）
  cm.toggle_roll() catch {
    _ => ()
  }
  assert_true(cm.rolled)
  cm.reset_layout()
  assert_false(cm.rolled)
  // 位置是**滑**回去的（set_position_animated）：落点由动画泵兑现，没接帧钟
  // 的测试环境那一圈直接落——所以断言前先推一圈泵
  let _ = app.step()
  // 六只窗全部归位，尺寸也回到默认
  assert_eq(pos(u.window), @moonui.LogicalPoint(lay.main.x, lay.main.y))
  assert_eq(size(u.window), @moonui.LogicalSize(lay.main.w, lay.main.h))
  assert_eq(pos(u.lyrics_win), @moonui.LogicalPoint(lay.lyrics.x, lay.lyrics.y))
  assert_eq(pos(u.eq_win), @moonui.LogicalPoint(lay.eq.x, lay.eq.y))
  assert_eq(
    pos(u.playlist_win),
    @moonui.LogicalPoint(lay.playlist.x, lay.playlist.y),
  )
  assert_eq(
    size(u.playlist_win),
    @moonui.LogicalSize(lay.playlist.w, lay.playlist.h),
  )
  assert_eq(pos(u.mini_win), @moonui.LogicalPoint(lay.mini.x, lay.mini.y))
  assert_eq(pos(u.desk_win), @moonui.LogicalPoint(lay.desk.x, lay.desk.y))
  // 复位也要把内容带回来：窗是 560、内容还按 700 画的话，右侧会露出一条空带，
  // 原生搜索框还会飘在空带里（这就是「拖过宽度再点复位」看到的那个样子）。
  let w_after_reset = pl_root_w() catch { _ => -1.0 }
  assert_eq(w_after_reset, lay.playlist.w)
  @moonui.Backend::terminate(b)
}

///|
/// 复位是**滑**回去的（`set_position_animated`），不是瞬间闪回去：接了帧钟时
/// 起跑零动、中途帧在 from 与 to 之间、退场推精确落点；没接帧钟的那一圈直接
/// 落（上一条用例的口径）。这条只盯一只窗的位移账，其余窗同一条通道。
test "app：复位窗口的位置是滑过去的，不是瞬移" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  @moonui.MockBackend::set_screen_size(b, @moonui.LogicalSize(1440.0, 900.0))
  let app = @moonui.App::new(b)
  let cell : Array[Int32] = [0]
  app.set_anim_clock(fn() { cell[0] })
  let cm = LunaMusicApp::new(app, MockAudioEngine::new())
  let u = cm.ui.unwrap()
  let lay = cm_default_layout(@moonui.LogicalSize(1440.0, 900.0))
  let pos = fn(w : @moonui.Window[@moonui.MockBackend]) {
    @moonui.Window::position(w) catch {
      _ => @moonui.LogicalPoint(-1.0, -1.0)
    }
  }
  // 把歌词秀拖到远处，然后复位
  @moonui.Window::set_position(u.lyrics_win, @moonui.LogicalPoint(900.0, 700.0)) catch {
    _ => ()
  }
  cm.reset_layout()
  // 起跑圈：补记时刻、零推送——还停在拖走的位置
  let _ = app.step()
  assert_eq(pos(u.lyrics_win), @moonui.LogicalPoint(900.0, 700.0))
  // 中途帧（150ms = 半程，EaseInOut(0.5) = 0.5）落在 from 与 to 之间
  cell[0] = 150
  let _ = app.step()
  let mid = pos(u.lyrics_win)
  assert_true(mid.x > lay.lyrics.x && mid.x < 900.0)
  assert_true(mid.y > lay.lyrics.y && mid.y < 700.0)
  // 退场推精确落点
  cell[0] = 400
  let _ = app.step()
  assert_eq(pos(u.lyrics_win), @moonui.LogicalPoint(lay.lyrics.x, lay.lyrics.y))
  @moonui.Backend::terminate(b)
}

// ————————————————————————————————————————————————————
// 第二期 A 批：真均衡器 + 真频谱
// ————————————————————————————————————————————————————

///|
test "eq：增益换算（千分位 ↔ milli-dB 往返）与读数文案" {
  assert_eq(cm_eq_freqs().length(), 10)
  // 中点 500 = 0dB；两端 ±12dB（= ±12000 milli-dB）
  assert_eq(gain_mdb_of(500), 0)
  assert_eq(gain_mdb_of(1000), 12000)
  assert_eq(gain_mdb_of(0), -12000)
  // 逆变换：来回一趟回到原值（取整误差在 1/24 dB 内，滑块一格之内）
  for v in [0, 1, 250, 500, 501, 750, 999, 1000] {
    assert_eq(permille_of(gain_mdb_of(v)), v)
  }
  // 读数：一位小数 + dB
  assert_eq(gain_text(0), "+0.0dB")
  assert_eq(gain_text(3200), "+3.2dB")
  assert_eq(gain_text(-6000), "-6.0dB")
  assert_eq(gain_text(-12000), "-12.0dB")
}

///|
test "eq：预设表——8 张、每段十段、平直全 500、重低音抬低频" {
  let table = eq_presets()
  assert_eq(table.length(), 8)
  for p in table {
    assert_eq(p.1.length(), 10)
    for v in p.1 {
      assert_true(v >= 0 && v <= 1000)
    }
  }
  // 平直：十段全在中点
  for v in table[0].1 {
    assert_eq(v, 500)
  }
  assert_eq(table[0].0, "平直")
  // 重低音：低频抬、高频压（形状对，不是抄某产品的精确曲线）
  let bass = table[7].1
  assert_eq(table[7].0, "重低音")
  assert_true(bass[0] > 600)
  assert_true(bass[9] < 500)
}

///|
test "eq：拖段 / 选预设 / 开关——推给引擎的是 milli-dB 不是千分位" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  // 初始平直：推下去是 0dB（千分位 500 若被当成 milli-dB 会变成 0.5dB）
  cm.push_eq()
  assert_eq(engine.eq_bands.length(), 10)
  for g in engine.eq_bands {
    assert_eq(g, 0)
  }
  assert_true(engine.eq_on)
  // 拖第 3 段到 750 → +6.0dB（表存千分位，引擎收 milli-dB）
  cm.set_eq_band(3, 750)
  assert_eq(cm.eq_bands[3], 750)
  assert_eq(engine.eq_bands[3], 6000)
  // 拖到两端 → 夹到 ±12dB
  cm.set_eq_band(0, 1000)
  assert_eq(engine.eq_bands[0], 12000)
  cm.set_eq_band(0, 0)
  assert_eq(engine.eq_bands[0], -12000)
  // 越界段号：整表不动（不崩、不写脏值）
  cm.set_eq_band(99, 800)
  cm.set_eq_band(-1, 800)
  assert_eq(engine.eq_bands[1], 0)
  // 选预设「重低音」（下标 7）：整张表换掉并推下去
  cm.set_eq_preset(7)
  assert_eq(cm.eq_bands[0], 700)
  assert_eq(engine.eq_bands[0], 4800)
  // 下标越界往两端夹：-5 → 平直；999 → 最后一张（重低音）
  cm.set_eq_preset(-5)
  assert_eq(cm.eq_bands[0], 500)
  cm.set_eq_preset(999)
  assert_eq(cm.eq_bands[0], 700)
  // 开关：关掉就是旁路
  cm.set_eq_enabled(false)
  assert_false(engine.eq_on)
  cm.set_eq_enabled(true)
  assert_true(engine.eq_on)
  @moonui.Backend::terminate(b)
}

///|
test "eq：段数为 0 的平台不画滑块（宁可空着也不摆假控件）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let flat : Array[Int32] = [500, 500, 500, 500, 500, 500, 500, 500, 500, 500]
  // Windows 半：段数 0 → 一只滑块都不建
  let p0 = EqPanel::new(
    b,
    0,
    flat,
    false,
    fn(_i : Int32, _v : Int32) { () },
    fn(_i : Int32) { () },
    fn(_on : Bool) { () },
  )
  assert_eq(p0.sliders.length(), 0)
  assert_eq(p0.gains.length(), 0)
  // mac 半：十只滑块、十只读数，位置 = 存档里的千分位
  let p1 = EqPanel::new(
    b,
    10,
    flat,
    true,
    fn(_i : Int32, _v : Int32) { () },
    fn(_i : Int32) { () },
    fn(_on : Bool) { () },
  )
  assert_eq(p1.sliders.length(), 10)
  assert_eq(p1.gains.length(), 10)
  assert_eq(p1.sliders[0].value() catch { _ => -1 }, 500)
  // 预设落地：只换样式不重建树，滑块位置跟着走
  p1.set_bands(eq_presets()[7].1) catch {
    _ => ()
  }
  assert_eq(p1.sliders[0].value() catch { _ => -1 }, 700)
  @moonui.Backend::terminate(b)
}

///|
test "spectrum：向引擎要 16 段能量，全 0 时熄灭" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  assert_eq(cm_viz_bands(), 16)
  assert_eq(cm_viz_segs(), 7)
  // 没在播：全 0，条子不亮
  cm.refresh_spectrum() catch {
    _ => ()
  }
  assert_false(cm.spectrum_lit())
  // 编排十六段：只要有一段有能量就算亮着
  let levels : Array[Int32] = []
  for i = 0; i < cm_viz_bands(); i = i + 1 {
    levels.push(if i == 0 { 1000 } else { 0 })
  }
  engine.set_levels(levels)
  cm.refresh_spectrum() catch {
    _ => ()
  }
  assert_true(cm.spectrum_lit())
  // 引擎只给两段（段数更少的平台）：多出来的读 0，不越界
  engine.set_levels([0, 0])
  cm.refresh_spectrum() catch {
    _ => ()
  }
  assert_false(cm.spectrum_lit())
  @moonui.Backend::terminate(b)
}

///|
test "app：从停到播的边沿点火一次（心跳链断了要能重新接上）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  engine.stub(trk("/m/a.mp3", 100L), [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [trk("/m/a.mp3", 100L)])
  let fires : Array[Int32] = []
  cm.on_play = Some(fn() { fires.push(1) })
  // 还没播：刷多少拍都不点火
  cm.refresh_bar() catch {
    _ => ()
  }
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_eq(fires.length(), 0)
  // 播起来：正好一次（这次 broadcast 已经把 refresh_bar 带到）
  cm.player.toggle()
  assert_true(cm.player.is_playing())
  assert_eq(fires.length(), 1)
  // 播着继续刷拍：不重复点火
  cm.refresh_bar() catch {
    _ => ()
  }
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_eq(fires.length(), 1)
  // 暂停再播：又一个边沿
  cm.player.toggle()
  assert_false(cm.player.is_playing())
  cm.refresh_bar() catch {
    _ => ()
  }
  cm.player.toggle()
  assert_true(cm.player.is_playing())
  assert_eq(fires.length(), 2)
  @moonui.Backend::terminate(b)
}

///|
test "skin：hex 往返与 token 读法（0xRRGGBB ↔ #RRGGBB）" {
  assert_eq(cm_hex_of(0x1874BE), "#1874BE")
  assert_eq(cm_hex_of(0x000000), "#000000")
  assert_eq(cm_hex_of(0xFFFFFF), "#FFFFFF")
  // 认 #RRGGBB、认不带 # 的、认大小写；长度不对/有非十六进制字符 → None
  assert_eq(cm_hex_parse("#1874BE"), Some(0x1874BE))
  assert_eq(cm_hex_parse("1874be"), Some(0x1874BE))
  assert_eq(cm_hex_parse("  #ffffff  "), Some(0xFFFFFF))
  assert_eq(cm_hex_parse("#12345"), None)
  assert_eq(cm_hex_parse("#1234567"), None)
  assert_eq(cm_hex_parse("#GGGGGG"), None)
  assert_eq(cm_hex_parse(""), None)
}

///|
test "skin：内置皮肤表（四套 / 默认第一套 / 按名取）" {
  let all = cm_skin_builtins()
  assert_eq(all.length(), 4)
  assert_eq(cm_skin_names(), ["经典蓝", "深空灰", "绯红", "松林绿"])
  assert_eq(cm_skin_default().name, "经典蓝")
  // 四套互不相同（整表比，避免哪两套撞了）
  for i, a in all {
    for j, b in all {
      if i != j {
        assert_true(a != b)
      }
    }
  }
  // 按名取
  assert_eq(cm_skin_by_name("绯红").unwrap().name, "绯红")
  assert_eq(cm_skin_by_name("没有这套"), None)
  // 每套都是完整的一套（没有哪个 token 是漏掉的 0 值以外的怪值）
  for s in all {
    assert_true(s.name.length() > 0)
    assert_true(s.page_bg >= 0 && s.page_bg <= 0xFFFFFF)
  }
}

///|
test "skin：JSON 往返；缺字段按默认补齐，不是对象/二进制 → None" {
  let s = cm_skin_red()
  let rt = Skin::from_text(s.text()).unwrap()
  assert_eq(rt, s) // 整表比对：二十一个 token 一个不差
  // 倒角那两颗也点名一次：`assert_eq(rt, s)` 已经覆盖，但字段将来若从 JSON
  // 两头之一漏掉，整表比对报的是"整份不等"；这两行直接指出是哪一颗。
  assert_eq(rt.bevel_hi, s.bevel_hi)
  assert_eq(rt.bevel_lo, s.bevel_lo)
  // 只写半张表：缺的按默认皮肤补齐，不整张作废
  let half = Skin::from_text("{\"name\":\"半张\",\"accent\":\"#010203\"}").unwrap()
  assert_eq(half.name, "半张")
  assert_eq(half.accent, 0x010203)
  assert_eq(half.page_bg, cm_skin_default().page_bg)
  // 坏值（非十六进制 / 数字类型）也要能读：前者退默认，后者按整数收
  let odd = Skin::from_text("{\"accent\":\"not-a-color\",\"bar\":16711680}").unwrap()
  assert_eq(odd.accent, cm_skin_default().accent)
  assert_eq(odd.bar, 0xFF0000)
  // 老版Luna的 .skn 是二进制资源包：内容不是 JSON → None
  assert_eq(Skin::from_text("PK\u0003\u0004....binary"), None)
  assert_eq(Skin::from_text(""), None)
  assert_eq(Skin::from_text("[1,2,3]"), None)
  assert_eq(Skin::from_text("{ 坏 JSON"), None)
}

///|
test "skin：换肤——全局那一份跟着变，token 读出来就是新的" {
  cm_skin_reset()
  assert_eq(cm_skin_current().name, "经典蓝")
  assert_eq(cm_skin_current().accent, 0x2C6FB5)
  cm_skin_set(cm_skin_dark())
  assert_eq(cm_skin_current().name, "深空灰")
  assert_eq(cm_skin_current().accent, 0x5AB0FF)
  cm_skin_reset()
  assert_eq(cm_skin_current().name, "经典蓝")
  // token 读法跟着当前皮肤走（Color 拆不出 rgb，比 accent 的整数即可）
  assert_eq(cm_skin_current().accent, 0x2C6FB5)
  assert_eq(cm_skin_current().inset, 0x0E2338)
}

///|
test "app：按名换肤 / 从档换肤 / 恢复默认，皮肤标识随之外化" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  cm_skin_reset()
  // 默认：经典蓝
  assert_eq(cm.skin_id(), "经典蓝")
  assert_true(cm.skin_is("经典蓝"))
  // 按内置名换
  assert_true(cm.set_skin_by_name("绯红"))
  assert_eq(cm.skin_id(), "绯红")
  assert_eq(cm_skin_current().name, "绯红")
  // 内置表里没有 → false，皮肤不动
  assert_false(cm.set_skin_by_name("没有这套"))
  assert_eq(cm.skin_id(), "绯红")
  // 从皮肤档换：记路径，并挂进外部皮肤表（切回内置还能再切回来）
  let text = cm_skin_green().text()
  assert_true(cm.add_skin_file("/skins/绿.skn", text))
  assert_eq(cm.skin_id(), "/skins/绿.skn")
  assert_eq(cm_skin_current().name, "松林绿")
  assert_eq(cm.extra_skins().length(), 1)
  assert_eq(cm.extra_skins()[0].0, "/skins/绿.skn")
  // 同一个路径再加载一次：覆盖不是追加
  assert_true(cm.add_skin_file("/skins/绿.skn", text))
  assert_eq(cm.extra_skins().length(), 1)
  // 坏的档：不进表、不改当前皮肤
  assert_false(cm.add_skin_file("/skins/坏.skn", "not json"))
  assert_eq(cm.extra_skins().length(), 1)
  assert_eq(cm.skin_id(), "/skins/绿.skn")
  // 切回内置再切回文件那套
  assert_true(cm.set_skin_by_name("经典蓝"))
  assert_eq(cm_skin_current().name, "经典蓝")
  // 恢复默认
  cm.reset_skin()
  assert_eq(cm.skin_id(), "经典蓝")
  @moonui.Backend::terminate(b)
  cm_skin_reset()
}

///|
test "prefs：皮肤标识进档（内置名与路径都照收）" {
  let p = Prefs::new()
  assert_eq(p.skin, "")
  p.skin = "深空灰"
  assert_eq(Prefs::from_json(p.to_json()).unwrap().skin, "深空灰")
  p.skin = "/skins/绿.skn"
  assert_eq(Prefs::from_json(p.to_json()).unwrap().skin, "/skins/绿.skn")
  // 旧档没有这一字段 → 空串（空串即默认皮肤）
  let old = Prefs::from_json(
    Json::object(Map::from_array([("volume", Json::number(300.0))])),
  ).unwrap()
  assert_eq(old.skin, "")
}

///|
test "model：皮肤档扩展名白名单" {
  assert_true(is_skin_file("/skins/a.skn"))
  assert_true(is_skin_file("/skins/a.SKN"))
  assert_true(is_skin_file("/skins/a.json"))
  assert_true(is_skin_file("/skins/a.mskn"))
  assert_false(is_skin_file("/skins/a.txt"))
  assert_false(is_skin_file("/skins/a.mp3"))
  assert_false(is_skin_file("/skins/noext"))
}

///|
/// 自绘进度/音量条（`CmBar`）：点亮颗数 = 千分位 × n / 1000，两端夹紧；
/// 值没变时一次样式都不刷（每拍 64 颗 set_style 会把动画帧挤掉）。
test "CmBar：点亮数按千分位换算，负值与超额都夹紧" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let slider = @moonui.Widget::slider(b, 0, 1000)
  let bar = CmBar::new(
    b,
    slider,
    10,
    64.0,
    12.0,
    2.0,
    cm_accent(),
    cm_transport_bg(),
  )
  assert_eq(bar.blocks.length(), 10)
  // 初始 last = -1（没有"上一次"，第一次一定刷）
  assert_eq(bar.last, -1)
  bar.set_permille(0)
  assert_eq(bar.last, 0)
  bar.set_permille(500)
  assert_eq(bar.last, 5)
  bar.set_permille(1000)
  assert_eq(bar.last, 10)
  // 出界：负值算 0 颗，超额算满格（不越界取 blocks，也不画到条外）
  bar.set_permille(-250)
  assert_eq(bar.last, 0)
  bar.set_permille(123456)
  assert_eq(bar.last, 10)
  // 同一个值再来一次：last 不变，说明走了"没变就返回"那一支
  let before = bar.last
  bar.set_permille(123456)
  assert_eq(bar.last, before)
  @moonui.Backend::terminate(b)
}

///|
/// 伴窗顶条的平台分叉：mac 有系统红绿灯，自绘那颗 ✕ 就不该出现；其余宿主
/// （Windows/Web/未知）没有系统按钮，必须自绘。`CmStrip::new` 按后端血统
/// 选分支，这里两支各验一次——顺带钉住"标题两平台都在"。
test "CmStrip：mac 不画自绘关闭钮，其余宿主画" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let noop = fn() { () }
  b.set_host_platform(Macos)
  let mac = CmStrip::new(b, "播放列表", noop)
  assert_eq(mac.title.text(), "播放列表")
  assert_true(mac.close is None)
  b.set_host_platform(Windows)
  let win = CmStrip::new(b, "播放列表", noop)
  assert_true(win.close is Some(_))
  b.set_host_platform(Unknown)
  let unk = CmStrip::new(b, "均衡器", noop)
  assert_true(unk.close is Some(_))
  @moonui.Backend::terminate(b)
}

///|
/// 自绘顶条的**装箱**（`T116`，判据 `T120` 修）：Windows 上系统标题栏与菜单栏都
/// 摘了，四组菜单收进 logo 右边四颗文字钮、右侧再补一颗「复位」和三颗窗口钮。
/// 这一行必须装得进 380 宽的主控窗——装不下的后果不是"挤一挤"，而是最后一颗
/// 「✕」整颗掉到窗外，用户没有关闭按钮可用。
///
/// **这条判据原先一直是盲的**（`T120` 发现）：`Sized` 是纯布局节点，`layout()`
/// 的 `Sized` 分支只把**子项**写进 `Placed` 表、自己不写（见 `layout.mbt` 的
/// `Sized(sized) => layout(sized.child, f, out)`），所以 `Widget::frame()` 对
/// 三颗窗口钮恒等于零矩形——而旧判据是"`right <= limit`，宽度 0 的跳过不判"，
/// 零矩形**永远**满足。讽刺的是它点名要保护的那三颗钮，恰是它唯一没真量过的。
/// 现在按"钻一层取子项矩形"来量：`Sized` 自己报零就取它的孩子，报非零就用它自己。
///
/// 判据逐个核右缘，不写死"总共几颗钮"：多一颗少一颗是设计选择，溢出才是缺陷。
test "app：Windows 自绘顶条装得进主控窗宽，窗口钮不掉到窗外（T116）" {
  let b = @moonui.MockBackend::new()
  b.set_host_platform(Windows)
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  engine.stub(trk("/m/1.mp3", 1L), [])
  let cm = LunaMusicApp::new(app, engine)
  let ui = cm.ui.unwrap()
  let root = @moonui.Window::content(ui.window).unwrap()
  // 树形：Column → [Sized(30) → Panel → Padding → Column → [Spacer, Row, Spacer], ...]
  // 顶条那一行是第一个 Sized 里的 Row，按层找下去比按下标猜稳。
  let bar_sized = root.children()[0]
  let panel = bar_sized.children()[0]
  let padding = panel.children()[0]
  let centered = padding.children()[0]
  let row = centered.children()[1]
  assert_true(row.spacing() > 0.0)
  let cells = row.children()
  assert_true(cells.length() >= 9)
  let limit = cm_main_w()
  // 取这一格真正占的矩形：`Sized` 自己不进 `Placed`（纯布局节点），报零就下钻
  // 到它的孩子——`Sized(24)` 里那颗窗口钮的矩形才是落在屏幕上那块。
  let cell_rect = fn(c : @moonui.Widget[@moonui.MockBackend]) {
    let r = c.frame()
    if r.size.width > 0.0 {
      r
    } else {
      let kids = c.children()
      if kids.length() > 0 {
        kids[0].frame()
      } else {
        r
      }
    }
  }
  let mut widest_right = 0.0
  for c in cells {
    let r = cell_rect(c)
    let right = r.origin.x + r.size.width
    // 弹性 spacer 会被量成 0 宽，不参与装箱判断；其余每一项都得在窗内。
    if r.size.width > 0.0 {
      assert_true(right <= limit)
      if right > widest_right {
        widest_right = right
      }
    }
  }
  // 三颗窗口钮是顶条最右的固定项，逐颗点名核一次：**宽度必须真量出来**（零宽
  // 就说明它被挤没了，这正是旧判据漏掉的形状），右缘必须在窗内。
  let n = cells.length()
  for i = n - 3; i < n; i = i + 1 {
    let r = cell_rect(cells[i])
    assert_true(r.size.width > 0.0)
    assert_true(r.origin.x + r.size.width <= limit)
  }
  // 整行没有溢出：最右那一项的右缘得落在窗内。留一点余量核对，不然 mock 的
  // 字体启发式一变就会顶穿（这条是"装得下"的总账，上面那些是逐项的点名）。
  assert_true(widest_right <= limit)
  @moonui.Backend::terminate(b)
}
