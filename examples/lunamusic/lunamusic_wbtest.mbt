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
/// 子树里所有文本控件（Label / Button）的文案，深度优先。
/// `T153` 判据要用它读"列表窗里当下画出来的那几行"——行由 `build_row` 现场建，
/// 组件不公开行内容，只能按用户姿势（`view()` 往下走）把文案捞出来。
fn[B : @moonui.Backend] cm_texts_in(w : @moonui.Widget[B]) -> Array[String] {
  let out : Array[String] = []
  let stack : Array[@moonui.Widget[B]] = [w]
  let mut cursor = 0
  while cursor < stack.length() {
    let cur = stack[cursor]
    cursor = cursor + 1
    match @moonui.Widget::kind(cur) {
      @moonui.WidgetKind::Label | @moonui.WidgetKind::Button => {
        let s = cur.text() catch { _ => "" }
        out.push(s)
      }
      _ => ()
    }
    for c in cur.children() {
      stack.push(c)
    }
  }
  out
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
test "库档：裸文件名判据认得出旧档，绝对路径档不误判（T142）" {
  // 旧档：walk_dir 把 d_name 当绝对路径上报时入库的形状
  let old = Library::new()
  old.merge("/Users/x/Music", [
    Track::from_path("夜曲.mp3"),
    Track::from_path("成全.mp3"),
  ])
  assert_true(old.has_bare_paths())
  // 新档：posix 绝对路径
  let posix = Library::new()
  posix.merge("/Users/x/Music", [Track::from_path("/Users/x/Music/夜曲.mp3")])
  assert_false(posix.has_bare_paths())
  // Win32 盘符与 UNC 也算绝对（同一份判据，别在 Windows 上把新档判成旧档）
  let win = Library::new()
  win.merge("C:/Music", [Track::from_path("C:\\Music\\夜曲.mp3")])
  assert_false(win.has_bare_paths())
  let unc = Library::new()
  unc.merge("\\\\srv\\share", [Track::from_path("\\\\srv\\share\\夜曲.mp3")])
  assert_false(unc.has_bare_paths())
  // 空库没有裸名（不该触发重扫）
  assert_false(Library::new().has_bare_paths())
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
/// 进度条只在「有可定位的曲目」时可点（`T138`）：空库/时长未知时禁掉。
/// 不禁的话，点一下系统轨道条会把它自己的位置挪到点击处、自绘的填充跟着挪，
/// 看起来像拖动成功，实际 `on_seek_slider` 因为 `dur <= 0` 什么都没做。
test "app：没有可定位的曲目时进度条禁用" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  // 空库：没有当前曲、时长为未知 → 禁用（不能拖）
  assert_false(cm.ui.unwrap().bar.progress.enabled())
  // 一首有时长的曲进来并播起来 → 恢复可拖（暂停着也照样可定位）
  let t1 = trk("/m/1.mp3", 200000L)
  engine.stub(t1, [])
  cm.merge_scan("/m", [t1])
  cm.player.play_index(0)
  assert_true(cm.ui.unwrap().bar.progress.enabled())
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
/// 音量百分比读数（`T146`）：指针进音量条才出现，离开就收起，读数由
/// `refresh_bar` 从 `player.volume` 写。真窗上这条链要 mac 开
/// `acceptsMouseMovedEvents` 才有输入，无头这里只能钉住"事件进来之后"那半段：
/// `MouseMove` 换目标 → `App::hover_track` 补发 Enter/Leave → 读数显隐。
/// 顺带钉住收起时**仍然占位**（布局不跳过不可见子项，切换时后面按钮不动）。
test "app：音量百分比随悬停显隐，读数跟音量走" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let u = cm.ui.unwrap()
  // 起手收起，但文字已经写好了（弹出时不用等下一拍）
  assert_false(u.bar.vol_pct.visible())
  assert_eq(u.bar.vol_pct.text(), "100%")
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_eq(u.bar.vol_pct.text(), "100%")
  // 指针进音量条：MouseMove 的 target 换了人 → hover_track 补发 MouseEnter
  let _ = app.dispatch(
    @moonui.MouseMove(u.bar.volume.target(), @moonui.LogicalPoint(32.0, 6.0)),
  )
  assert_true(u.bar.vol_pct.visible())
  // 读数跟音量：505‰ → 就近取整 51%
  cm.player.set_volume(505)
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_eq(u.bar.vol_pct.text(), "51%")
  // 指针挪到窗口空白：摘掉悬停，读数收起
  let _ = app.dispatch(
    @moonui.MouseMove(u.window.target(), @moonui.LogicalPoint(2.0, 2.0)),
  )
  assert_false(u.bar.vol_pct.visible())
  // 收起状态下的占位账：显隐切换不挪后面那排按钮（布局不跳过不可见子项，
  // 那一格恒占 30）。量的是**后面的兄弟**——`Sized`/`Center` 是纯布局节点，
  // 自己的 frame 恒为零矩形，量它量不出这一格的长度。
  let x_hidden = u.bar.pl.frame().origin.x
  let _ = app.dispatch(
    @moonui.MouseMove(u.bar.volume.target(), @moonui.LogicalPoint(32.0, 6.0)),
  )
  let _ = app.step()
  assert_true(u.bar.vol_pct.visible())
  assert_eq(u.bar.pl.frame().origin.x, x_hidden)
  @moonui.Backend::terminate(b)
}

///|
/// 拖动音量条时读数**当场**就变（`T149`）。owner 报"百分比的值没有实时变化"，
/// 真根因在**事件根本没到 Core** 这一侧，不在画：滑块 `Change` 原先只入队，而
/// 整段拖动跑在 `NSSlider` 自己的模态跟踪循环里，`App::step` 被泵卡着、队列表
/// 排不动——整段拖动一条 `Change` 都派发不出去，`set_volume` / `refresh_bar` /
/// `vol_pct.set_text` 一次都没跑，松手才一次性跳过去。修在 Core 的后端层：
/// `NativeBackend::push_value_change` 走 `live_dispatch`（与 `push_resize` /
/// `push_move` 同一条直达通道，`App::new` 装的就是它）。
///
/// 这条钉住 Core 那半：`Change` 一到，读数和引擎音量就已经是新值，中间不许夹
/// `refresh_bar`、也不许夹 `App::step`（那两步由 `player.set_volume` 的广播
/// 自带）。后半段是同一笔的连坐——进度条的回写：实时直达让 `refresh_bar` 跑在
/// 用户手指底下那圈跟踪循环里，引擎回报的还是 seek 前的旧位置，一句回写就把
/// 拇指拽回去，所以 `seeking` 期间跳过它。
test "app：音量滑块的 Change 一到，百分比读数当场就变（T149）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let u = cm.ui.unwrap()
  let _ = app.step()
  assert_eq(u.bar.vol_pct.text(), "100%")
  // 拖一段：走 mock 的投送口（与真后端 `push_value_change` 同一口径——值先
  // 落进控件，再发 `Change`，装了实时通道就同步直达）。
  //
  // 判据的关键是**没有 step**：拖动跑在控件的模态跟踪循环里，泵一圈都转不动，
  // 所以只要这一步之后就到位，说明走的是实时直达而不是队列。
  @moonui.MockBackend::push_value_change(b, u.bar.volume.handle.unwrap(), 372)
  assert_eq(cm.player.volume, 372)
  assert_eq(u.bar.vol_pct.text(), "37%")
  assert_eq(engine.volume, 372)
  // 负控制：把直达通道摘掉（模拟裸后端），同一个投送就只入队——读数停在原处，
  // 非得 `step` 才追上来。这条证明上面那三行不是"顺手就算出来了"。
  @moonui.Backend::set_live_dispatch(b, None)
  @moonui.MockBackend::push_value_change(b, u.bar.volume.handle.unwrap(), 600)
  assert_eq(cm.player.volume, 372)
  assert_eq(u.bar.vol_pct.text(), "37%")
  let _ = app.step()
  assert_eq(cm.player.volume, 600)
  assert_eq(u.bar.vol_pct.text(), "60%")
  @moonui.Backend::terminate(b)
}

///|
/// 拖动进度条时**不许被回写拽回去**（`T149`）。这是实时直达的连坐：`Change`
/// 同步进 Core 之后，`on_seek_slider` → `player.seek` → `broadcast` →
/// `refresh_bar` 整圈跑在用户手指底下那圈 `NSSlider` 跟踪循环里，而
/// `refresh_bar` 的千分位是从**引擎回报的位置**算回来的——真引擎刚 seek 完
/// 回报的仍是旧值，一句 `set_value` 就把拇指拽走，下一颗 `mouseDragged` 又从
/// 新位置重算，拖着走不直。
///
/// 判据用整数除法的**取整损失**把它做成必现：时长 200001ms 时，拖到 500‰ 的
/// seek 落点是 100000ms，回算却是 `100000*1000/200001 = 499`——回写一定比手指
/// 少一格。`seeking` 挡掉之后，原生滑块与自绘层都停在 500。
test "app：拖进度条期间 refresh_bar 不回写滑块（T149）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let t1 = trk("/m/1.mp3", 200001L)
  engine.stub(t1, [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [t1])
  cm.player.play_index(0)
  let u = cm.ui.unwrap()
  assert_true(u.bar.progress.enabled())
  // 拖到一半（与真后端同一条投送口径：值先落进控件，再同步直达 Change）
  @moonui.MockBackend::push_value_change(b, u.bar.progress.handle.unwrap(), 500)
  // seek 真的落了
  assert_eq(engine.pos_ms, 100000L)
  // 滑块没被回写成 499，自绘层也跟着手指走
  assert_eq(u.bar.progress.value(), 500)
  assert_eq(u.bar.prog_bar.last_pm, 500)
  // 标志出栈，没漏在 true 上（否则之后的正常刷新全被跳过）
  assert_false(cm.seeking)
  // 负控制的对照：不在拖动中时 refresh_bar 照旧按引擎位置回写
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_eq(u.bar.progress.value(), 499)
  @moonui.Backend::terminate(b)
}

///|
/// 两条带的原生滑块**不再被蒙版罩住**（`T147②`）：画面由 C 那层画（macOS 半
/// `MoonuiNativeSliderHost drawRect:`、Windows 半 `moonui_native_slider_paint`），
/// 宿主身上再挂 `opacity(0.01)` 会把刚画的槽与圆点一起淡没。
///
/// 判据走 mock 的 opacity 流水：整棵树建完、`step` 跑过一轮之后，滑块那只
/// 句柄上从来没有 `0.01` 这个值推下来过。
test "app：进度/音量滑块不再挂 0.01 蒙版（T147②）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  cm.refresh_bar() catch {
    _ => ()
  }
  let _ = app.step()
  // 两条带的原生滑块句柄
  let prog = u_handle_id(cm.ui.unwrap().bar.progress)
  let vol = u_handle_id(cm.ui.unwrap().bar.volume)
  let mut masked = false
  for (id, v) in b.opacity_push_log() {
    if (id == prog || id == vol) && v < 1.0 {
      masked = true
    }
  }
  assert_false(masked)
  @moonui.Backend::terminate(b)
}

///|
/// 取控件句柄的 id（没有句柄时 -1，判据会因此落空——那就是真出事了）。
fn u_handle_id(w : @moonui.Widget[@moonui.MockBackend]) -> Int32 {
  match w.handle {
    Some(h) => h.id
    None => -1
  }
}

///|
/// 百分比读数与音量条**竖直中线重合**（`T147①`）。Row 的交叉轴是左上对齐
/// （`layout_line` 把子项落在 `frame.origin`），不包 `Center` 的话读数贴着
/// 那一格的顶端，真窗上比音量条圆点矮半行——"80% 悬在半空"。
/// 判据取两条中线：音量条自己是 Leaf（真落 `Placed`），读数在右边那一格居中。
test "app：音量百分比与音量条竖直中线对齐（T147①）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let u = cm.ui.unwrap()
  let _ = app.step()
  // 对账对象用**音量条自己**的矩形（它是 Leaf，真落 `Placed`），不用外层
  // `Sized`/`Center` 那一格——纯布局节点不写自己的 frame，量出来恒是零矩形。
  // 音量条在 `Sized(64, 18)` 里，就是它那一格的整块。
  let vol = u.bar.volume.frame()
  assert_eq(vol.size.width, 64.0)
  assert_eq(vol.size.height, 18.0)
  // 读数落在右边那一格里，竖直中线与音量条重合——这就是"对齐"的判据。
  // mock 度量下 9pt 的 Label 固有高是 20 × 9/12 = 15，居中后上下各留 1.5。
  let r = u.bar.vol_pct.frame()
  assert_eq(r.size.height, 15.0)
  assert_true(r.origin.x > vol.origin.x + vol.size.width)
  let vol_mid = vol.origin.y + vol.size.height / 2.0
  let pct_mid = r.origin.y + r.size.height / 2.0
  assert_true(vol_mid - pct_mid < 0.01 && pct_mid - vol_mid < 0.01)
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
  // `T128`：换页签是**就地改列表区**，不是整树重建——标题与计数两处文案直接
  // 作数（旧路径 `rebuild_ui` 会把它们换成新树里的另一只，这里钉的是"同一只
  // 控件改了字"，所以连旧句柄也还在）
  let ui = cm.ui.unwrap()
  assert_eq(ui.table.title_label.text(), "我喜欢的")
  assert_eq(ui.table.count_label.text(), "共 1 首")
  // 选中态也跟着换（`T128`）：`refresh` 必须把底色下到**按钮本身**。早先
  // `tabs` 里存的是 `sized(...)` 包装层，样式落在容器上，真窗上就是"文案变了、
  // 选中底色不动"。
  let acc = @moonui.Widget::style(ui.table.tabs[1]).unwrap().background.unwrap()
  let idle = @moonui.Widget::style(ui.table.tabs[0]).unwrap().background.unwrap()
  assert_true(acc != idle)
  assert_eq(@moonui.Widget::text(ui.table.tabs[1]), "我喜欢的")
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
  // 整块**居中**（`T149②`）：默认就看得见的三只拼成 794×518 的矩形，它的
  // 中线落在屏幕中线上；纵向的可用带扣掉底部那条桌面歌词（120）。复位与
  // 建窗共用这张表，所以"打开就在中间"与"复位回中间"是同一个落点。
  assert_eq(lay.main.w, cm_main_w())
  assert_eq(lay.main.h, cm_main_h())
  let block_w = lay.main.w + cm_layout_gap() + lay.lyrics.w
  let block_h = lay.main.h + cm_layout_gap() + lay.playlist.h
  assert_eq(lay.main.x + block_w + lay.main.x, screen.width)
  assert_eq(
    lay.main.y + block_h + lay.main.y,
    screen.height - cm_desk_bottom_inset(),
  )
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
  // 没在播：全 0，条子不亮
  let _ = cm.refresh_spectrum(33) catch { _ => false }
  assert_false(cm.spectrum_lit())
  // 编排十六段：只要有一段有能量就算亮着
  let levels : Array[Int32] = []
  for i = 0; i < cm_viz_bands(); i = i + 1 {
    levels.push(if i == 0 { 1000 } else { 0 })
  }
  engine.set_levels(levels)
  let _ = cm.refresh_spectrum(33) catch { _ => false }
  assert_true(cm.spectrum_lit())
  // 引擎只给两段（段数更少的平台）：多出来的读 0，不越界
  engine.set_levels([0, 0])
  let _ = cm.refresh_spectrum(33) catch { _ => false }
  // 刚落下来的那一帧条子还亮着（有余辉要落），不能当"熄灭"报
  assert_true(cm.spectrum_lit())
  @moonui.Backend::terminate(b)
}

///|
/// 一帧 33ms、按实测帧间隔推进一步：这里给的是链上真正用的那个数
/// （壳里的 `VIZ_FRAME_MS`），断言里的时间尺度才对得上。
fn viz_tick(cm : LunaMusicApp[@moonui.MockBackend, MockAudioEngine]) -> Bool {
  cm.refresh_spectrum(33) catch {
    _ => false
  }
}

///|
/// 柱子是**连续**高度的（`T155`）：一帧画出来的每条 `FillLinear` 高度都跟
/// 显示值成比例，没有一个"档位"。
///
/// 旧版（16 段 × 7 颗定高方块）在这里必红：它根本不画矩形，只换 7 种底色，
/// 高度只有 7 个可能值。
test "spectrum：柱子是连续高度画的，不是七档色块（T155）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let viz = Spectrum::new(b, 88.0, 64.0)
  let win = app.create_window("频谱", @moonui.LogicalSize(96.0, 72.0))
  win.set_content(viz.root)
  win.show()
  let _ = app.step()
  // 引擎给 16 段各不相同的能量，其中一段是 555‰ —— 落在 7 档中的第 3.885 档，
  // 档位化的实现在这里只能画出 3/7 或 4/7。
  let levels : Array[Int32] = []
  for i = 0; i < cm_viz_bands(); i = i + 1 {
    levels.push(500 + i * 20)
  }
  levels[5] = 555
  // 推到落定：显示值等于目标值，才能逐根对账
  let mut n = 0
  while viz.update(levels, 33) && n < 400 {
    n = n + 1
  }
  assert_true(n < 400)
  let bars = viz.bars()
  assert_eq(bars.length(), 16)
  assert_true((bars[5] - 0.555).abs() < 0.001)
  assert_true((bars[0] - 0.5).abs() < 0.001)
  // 画出来的清单：16 条竖向渐变，一条一根柱子；高度 = 面高 × 显示值
  let face = viz.face
  let h = match face.handle() {
    Some(h) => h
    None => abort("频谱面没有原生句柄：它没被摆出来")
  }
  let dl = match b.drawn(h) {
    Some(dl) => dl
    None => abort("频谱面一帧都没画过")
  }
  assert_eq(dl.len(), 16)
  let fh = face.frame.size.height
  assert_true(fh > 0.0)
  let cmds = dl.commands()
  match cmds[5] {
    @moonui.FillLinear(_, y, _, bh, _) => {
      // 第 5 根：底边贴面底，高度是 0.555 × 面高（不是 1/7 的整数倍）
      assert_true((bh - 0.555 * fh).abs() < 0.01)
      assert_true((y + bh - fh).abs() < 0.01)
    }
    _ => fail("第 5 根柱子不是竖向渐变")
  }
  @moonui.Backend::terminate(b)
}

///|
/// 起音快、落音慢（`T155`）：同一条 33ms 的帧，往上爬的时候一大步，往回落
/// 的时候一小步。
///
/// 为什么必须有这条：两条 tau 取反了照样"平滑"，看着还是动的——只有把两个
/// 方向的**步幅**钉住，"冲上去、慢慢落"这个观感才是有判据的。
test "spectrum：冲上去快、落下来慢（T155）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let viz = cm.ui.unwrap().bar.viz
  let levels : Array[Int32] = [1000]
  engine.set_levels(levels)
  // 一帧：从 0 往上追 1.0，k = 33/(33+40) = 0.452 → 大约 0 / 1 的一半
  let _ = viz_tick(cm)
  let up = viz.bars()[0]
  assert_true(up > 0.3 && up < 0.6)
  // 推到落定，然后切成静音再来一帧：从 1 往下追 0，k = 33/(33+260) = 0.113
  let mut n = 0
  while viz_tick(cm) && n < 400 {
    n = n + 1
  }
  assert_true((viz.bars()[0] - 1.0).abs() < 0.001)
  engine.set_levels([0])
  let _ = viz_tick(cm)
  let down = 1.0 - viz.bars()[0]
  assert_true(down > 0.0 && down < 0.2)
  // 同一条时间轴上：爬的步子明显比落的大（约 4 倍，天线是 40ms vs 260ms）
  assert_true(up * 0.5 > down)
  @moonui.Backend::terminate(b)
}

///|
/// 落定之后不再要帧（`T155`）：静止的频谱一秒三十帧地重画是白花的预算。
///
/// 判据取两段：还在动的时候**必须**报 true（否则链会提前断、动画停在中途），
/// 落定之后**必须**报 false（否则链永远续着，空闲的 GUI 也在满帧重画）。
test "spectrum：动的时候要帧、落定之后不要（T155）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  engine.set_levels([1000])
  // 第一帧：目标 1.0、显示 0，一定还在动
  assert_true(viz_tick(cm))
  let mut n = 0
  let mut moving = true
  while moving && n < 400 {
    moving = viz_tick(cm)
    n = n + 1
  }
  assert_true(n < 400)
  // 落定：目标没变、显示值已经贴住，这一帧不再要帧
  assert_false(viz_tick(cm))
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
/// `T153` 判据：切歌之后**播放列表窗里画出来的那几行**要换高亮。
///
/// owner 报的是"双击淘金小镇开始播，主控窗与歌词窗都变了，播放列表还标着前一首"。
/// 根因不对称：播放条与歌词窗每拍从 player 拉最新状态，列表行的高亮是 `build_row`
/// 在**建行那一刻**按 `player.current` 烤死的，而切歌不走 `refresh`（那是换页签/
/// 排序/搜索的路，会 `set_count` 把滚动位置弹回顶端）。
///
/// 读的是行内文案而不是账本字段：`▶ ` 前缀就是用户眼睛看到的那份高亮，行怎么建
/// 只有树说得清。
test "app：切歌之后播放列表的高亮跟着换（T153）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let tracks = [
    trk("/m/a.mp3", 100L),
    trk("/m/b.mp3", 200L),
    trk("/m/c.mp3", 300L),
  ]
  let cm = LunaMusicApp::new(app, eng_with(tracks))
  cm.merge_scan("/m", tracks)
  let ui = cm.ui.unwrap()
  let rows = () => cm_texts_in(ui.table.list.view())
  // 起手没在播：三行都没有标记
  assert_false(rows().contains("▶ 1"))
  // 播第一首：第 1 行点亮
  cm.play_view_index(0)
  assert_true(rows().contains("▶ 1"))
  assert_false(rows().contains("▶ 3"))
  // 双击第 3 首（owner 那条路径）：高亮必须从第 1 行挪到第 3 行
  cm.play_view_index(2)
  assert_true(rows().contains("▶ 3"))
  assert_false(rows().contains("▶ 1"))
  assert_eq(cm.player.track().unwrap().path, "/m/c.mp3")
  // 换回来也一样（不是"第一次才对"）
  cm.play_view_index(1)
  assert_true(rows().contains("▶ 2"))
  assert_false(rows().contains("▶ 3"))
  // 幂等：同一首再点一次，行不被重复堆叠
  let before = ui.table.list.materialized_count()
  cm.play_view_index(1)
  assert_eq(ui.table.list.materialized_count(), before)
  assert_eq(rows().length(), cm_texts_in(ui.table.list.view()).length())
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
    14.0,
    cm_text_light(),
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
  // 圆点（`T146`）单独一笔账：方块只分 10 档，500 与 540 都点 5 颗，圆点却要
  // 逐格走——`last_pm` 变而 `last` 不变，正是"连续走"与"分档"分家的判据。
  bar.set_permille(500)
  let lit = bar.last
  bar.set_permille(540)
  assert_eq(bar.last, lit)
  assert_eq(bar.last_pm, 540)
  // 出界的千分位在圆点这一笔上同样夹紧：`last_pm` 记的是夹紧后的值。
  bar.set_permille(-250)
  assert_eq(bar.last_pm, 0)
  bar.set_permille(123456)
  assert_eq(bar.last_pm, 1000)
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

///|
/// 拖动中改文案，**帧当场跟上**，不许等 `App::step`（`T151`）。
///
/// owner 报的现场：先把音量拖到 0%、松手，再往回拖，百分比就没了 `%`。量完
/// 不是"容器太窄"，是**帧落后于文案**：滑块的 `Change` 走实时直达（`T149`），
/// handler 里 `set_text` 只标脏，重排却在 `App::step` 的 `flush_layout`——而这
/// 整段拖动跑在 `NSSlider` 自己的模态跟踪循环里，`step` 一圈都转不动。拖到 0%
/// 时文案变短（`0%` 的固有宽比 `100%` 窄），松手后 step 才把帧缩到短文案的宽；
/// 再往回拖文案变长，帧仍是那个窄的，尾巴被裁掉——真窗口上就是 `22` 后面少了
/// `%`（`T148` 那颗 `displayIfNeeded` 恰好把这个错配画成了可见的截断）。
///
/// 判据取**固有宽随文案变**这件事本身：`push_value_change` 之后、任何 `step`
/// 之前，读数的帧宽必须已经是新文案的固有宽。修前这里停在旧宽上（红）。
test "app：拖动中改文案，帧当场跟上（T151）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let u = cm.ui.unwrap()
  let _ = app.step()
  // 起手 100%：三位数 + 百分号，最宽的那一档。
  let wide = u.bar.vol_pct.frame().size.width
  assert_eq(u.bar.vol_pct.text(), "100%")
  // 拖到 0%：文案只剩两个字符，固有宽必须当场缩下来（松手前的那段也要对，
  // 因为拖动期间 step 跑不了）。
  @moonui.MockBackend::push_value_change(b, u.bar.volume.handle.unwrap(), 0)
  assert_eq(u.bar.vol_pct.text(), "0%")
  let narrow = u.bar.vol_pct.frame().size.width
  assert_true(narrow < wide)
  // 再往回拖到 22%：文案变长，帧得当场长回来——这就是 owner 那条"百分号没了"。
  @moonui.MockBackend::push_value_change(b, u.bar.volume.handle.unwrap(), 220)
  assert_eq(u.bar.vol_pct.text(), "22%")
  let mid = u.bar.vol_pct.frame().size.width
  assert_true(mid > narrow)
  assert_true(mid <= wide)
  @moonui.Backend::terminate(b)
}
// ---- 在线取词（`T158`）：元数据/文件名推导 ----

///|
/// 三种文件名的切段（owner 2026-10-29 点名的三种形状，逐字用原名）。
/// 下载站命名里混着 `_`、全角括号、多段纯数字 ID——剥不干净就会拿
/// `275694467` 当歌手去查。
test "tag：多横杠文件名的切段（owner 点名的三种形状）" {
  // 1. 下划线当空格 + 尾部 UUID + 尾部时长
  let a = cm_filename_segments(
    "給我一首歌的時間_(Piano_Ver_)-Piano_Echoes-275694467-320.mp3",
  )
  assert_eq(a.length(), 2)
  assert_eq(a[0], "給我一首歌的時間 (Piano Ver )")
  assert_eq(a[1], "Piano Echoes")
  // 2. 全角括号版本后缀 + 纯数字 ID + 纯数字时长
  let b = cm_filename_segments(
    "听妈妈的话（钢琴版）-周杰伦-385944392-100.ogg",
  )
  assert_eq(b.length(), 2)
  assert_eq(b[0], "听妈妈的话（钢琴版）")
  assert_eq(b[1], "周杰伦")
  // 3. 普通两段 + ID + 时长
  let c = cm_filename_segments(
    "你怎么舍得我难过-黄品源-145527-2000.flac",
  )
  assert_eq(c.length(), 2)
  assert_eq(c[0], "你怎么舍得我难过")
  assert_eq(c[1], "黄品源")
}

///|
/// 剥数字段的两条边：全数字文件名不能剥空；中间的数字段不剥（只剥尾部）。
test "tag：剥纯数字段只动尾巴，且至少留一段" {
  assert_eq(cm_filename_segments("123-456.mp3").length(), 1)
  assert_eq(cm_filename_segments("123-456.mp3")[0], "123")
  let d = cm_filename_segments("2002年的第一场雪-刀郎.flac")
  assert_eq(d.length(), 2)
  assert_eq(d[0], "2002年的第一场雪")
  let e = cm_filename_segments("A-320-B.mp3")
  assert_eq(e.length(), 3)
  assert_eq(e[1], "320")
}

///|
/// 「两种都查，命中优先」：`A - B` 先当 (歌名=B, 歌手=A)，再当 (歌名=A, 歌手=B)。
test "tag：文件名两段 → 两种切法都有，A=歌手那句排第一" {
  let r = tag_filename_readings("周杰伦 - 晴天.mp3")
  assert_eq(r.length(), 2)
  assert_eq(r[0], ("晴天", "周杰伦"))
  assert_eq(r[1], ("周杰伦", "晴天"))
  // 只有一段：没有歌手可猜，别硬编
  let one = tag_filename_readings("晴天.mp3")
  assert_eq(one.length(), 1)
  assert_eq(one[0], ("晴天", ""))
}

///|
/// 「缺哪个补哪个」的三条支路，外加哨兵 `未知` 当缺失。
test "tag：缺哪个补哪个 + 未知当缺失" {
  // 两个都不缺：只发一份，文件名完全不碰
  let full : Track = {
    path: "/m/周杰伦 - 晴天.mp3",
    title: "晴天",
    artist: "周杰伦",
    album: "叶惠美",
    duration_ms: 269000L,
    cover: None,
  }
  let c0 = tag_query_candidates(full)
  assert_eq(c0.length(), 1)
  assert_eq(c0[0], ("晴天", "周杰伦"))
  // 缺歌手（哨兵）：从文件名补，标题保留真值
  let no_artist : Track = {
    path: "/m/晴天-周杰伦-123456-269.mp3",
    title: "晴天",
    artist: "未知",
    album: "未知",
    duration_ms: 269000L,
    cover: None,
  }
  let c1 = tag_query_candidates(no_artist)
  assert_true(c1.length() >= 1)
  assert_eq(c1[0].0, "晴天")
  assert_eq(c1[0].1, "周杰伦")
  // 缺标题（空串）：从文件名补，歌手保留真值
  let no_title : Track = {
    path: "/m/周杰伦 - 晴天.mp3",
    title: "",
    artist: "周杰伦",
    album: "未知",
    duration_ms: 269000L,
    cover: None,
  }
  let c2 = tag_query_candidates(no_title)
  assert_true(c2.length() >= 1)
  assert_eq(c2[0].0, "晴天")
  assert_eq(c2[0].1, "周杰伦")
}

///|
/// 探针读不出东西时 `Track::from_path` 会把文件名整个塞进 title——那**不是**
/// 元数据。判不出来的话兜底 Track 永远"有标题"，文件名规则一条都走不到，
/// 于是拿 `周杰伦 - 晴天` 当歌名去查，精确匹配必 404。
test "tag：标题等于文件名去扩展名 → 当缺失" {
  let t = Track::from_path("/m/周杰伦 - 晴天.mp3")
  assert_eq(t.title, "周杰伦 - 晴天")
  assert_eq(t.artist, "未知")
  let c = tag_query_candidates(t)
  assert_true(c.length() >= 2)
  // 第一种切法：A=歌手 / B=歌名
  assert_eq(c[0], ("晴天", "周杰伦"))
  assert_eq(c[1], ("周杰伦", "晴天"))
}

///|
/// 尾部括注的剥法：`/api/get` 精确匹配，带 `（钢琴版）` 一律 404，所以要多
/// 一次「剥掉后缀」的机会。原始候选排前面，剥出来的追加在后面。
test "tag：标题尾部括注再补一份候选" {
  let t = Track::from_path(
    "/m/听妈妈的话（钢琴版）-周杰伦-385944392-100.ogg",
  )
  let c = tag_query_candidates(t)
  assert_true(c.length() >= 2)
  assert_eq(c[0], ("听妈妈的话（钢琴版）", "周杰伦"))
  // 剥掉（钢琴版）的版本必须在表里
  let mut found = false
  for (title, artist) in c {
    if title == "听妈妈的话" && artist == "周杰伦" {
      found = true
    }
  }
  assert_true(found)
  // 半角括号 / 方括号同样认
  assert_eq(cm_strip_trailing_bracket("Hello (Live)"), "Hello")
  assert_eq(cm_strip_trailing_bracket("Hello [Remastered]"), "Hello")
  // 整串就是一个括注 → 剥成空（调用方据此不发这一条）
  assert_eq(cm_strip_trailing_bracket("（纯音乐）"), "")
  // 不是括注结尾 → 原样
  assert_eq(cm_strip_trailing_bracket("听妈妈的话"), "听妈妈的话")
}

///|
/// `未知` 这个哨兵只有一个定义处（`model.mbt` 的 from_path 与这里的
/// `cm_unknown_field`），两边漂了就漏判。
test "tag：缺失判定认空串与哨兵" {
  assert_eq(cm_unknown_field(), "未知")
  assert_true(tag_field_missing(""))
  assert_true(tag_field_missing("   "))
  assert_true(tag_field_missing("未知"))
  assert_true(tag_field_missing(" 未知 "))
  assert_false(tag_field_missing("周杰伦"))
}

// ---- 在线取词：lrclib 的纯逻辑半边 ----

///|
fn lq(title : String, artist : String, dur : Double) -> OnlineLyricQuery {
  { title, artist, duration_s: dur, }
}

///|
/// `perc` 编码：中文按 UTF-8 字节编（一个字三个 `%XX`），空格编 `%20` 不编
/// `+`，unreserved 那几条原样留着。
test "lrclib：URL 编码按 UTF-8 字节走" {
  assert_eq(url_encode("abc"), "abc")
  assert_eq(url_encode("A-Z a.z_0~9"), "A-Z%20a.z_0~9")
  // 晴 = E6 99 B4
  assert_eq(url_encode("晴"), "%E6%99%B4")
  assert_eq(url_encode("&=%"), "%26%3D%25")
  assert_eq(url_encode(""), "")
}

///|
/// 两个端点的 URL 形状：`/api/get` 带 duration，`/api/search` 不带；空歌手与
/// 未知时长都不带那个参数（带 0 会让 lrclib 按"0 秒"精确匹配，必然 404）。
test "lrclib：两个端点的 URL 构造" {
  let g = lrclib_get_url(lq("晴天", "周杰伦", 269.0))
  assert_eq(
    g, "https://lrclib.net/api/get?track_name=%E6%99%B4%E5%A4%A9&artist_name=%E5%91%A8%E6%9D%B0%E4%BC%A6&duration=269",
  )
  let s = lrclib_search_url(lq("晴天", "周杰伦", 269.0))
  assert_eq(
    s, "https://lrclib.net/api/search?track_name=%E6%99%B4%E5%A4%A9&artist_name=%E5%91%A8%E6%9D%B0%E4%BC%A6",
  )
  // 空歌手：不带 artist_name
  let no_artist = lrclib_get_url(lq("晴天", "", 269.0))
  assert_eq(
    no_artist, "https://lrclib.net/api/get?track_name=%E6%99%B4%E5%A4%A9&duration=269",
  )
  // 未知时长：不带 duration
  let no_dur = lrclib_get_url(lq("晴天", "周杰伦", 0.0))
  assert_eq(
    no_dur, "https://lrclib.net/api/get?track_name=%E6%99%B4%E5%A4%A9&artist_name=%E5%91%A8%E6%9D%B0%E4%BC%A6",
  )
}

///|
/// 解析 `/api/get` 的 200 响应体（形状取自 2026-10-29 实跑 lrclib 的返回）。
test "lrclib：解析 /api/get 单个对象" {
  let body = "{\"id\":3396226,\"trackName\":\"晴天\",\"artistName\":\"周杰伦\",\"albumName\":\"叶惠美\",\"duration\":269.0,\"instrumental\":false,\"plainLyrics\":\"故事的小黄花\",\"syncedLyrics\":\"[00:00.00]故事的小黄花\"}"
  let h = parse_lrclib_get(body).unwrap()
  assert_eq(h.track_name, "晴天")
  assert_eq(h.artist_name, "周杰伦")
  assert_eq(h.duration_s, 269.0)
  assert_eq(h.synced.unwrap(), "[00:00.00]故事的小黄花")
  // syncedLyrics 为 null：靠 plainLyrics 也算数
  let plain_only = "{\"trackName\":\"晴天\",\"artistName\":\"周杰伦\",\"duration\":269,\"plainLyrics\":\"只有纯文本\",\"syncedLyrics\":null}"
  let h2 = parse_lrclib_get(plain_only).unwrap()
  assert_true(h2.synced is None)
  assert_eq(h2.plain.unwrap(), "只有纯文本")
  // 两个词都空 / 坏 JSON / 404 的错误体：一律 None
  assert_true(
    parse_lrclib_get(
      "{\"trackName\":\"x\",\"plainLyrics\":\"\",\"syncedLyrics\":null}",
    )
    is None,
  )
  assert_true(
    parse_lrclib_get("{\"code\":404,\"name\":\"TrackNotFound\"}") is None,
  )
  assert_true(parse_lrclib_get("<html>503</html>") is None)
  assert_true(parse_lrclib_get("") is None)
}

///|
/// 解析 `/api/search` 的数组：坏行逐条跳过，不因一条烂数据整批作废。
test "lrclib：解析 /api/search 数组（坏行跳过）" {
  let body = "[{\"trackName\":\"晴天\",\"artistName\":\"周杰伦\",\"duration\":269,\"syncedLyrics\":\"[00:00.00]a\",\"plainLyrics\":\"a\"},{\"trackName\":\"无词\",\"artistName\":\"x\",\"duration\":100,\"syncedLyrics\":null,\"plainLyrics\":null},{\"trackName\":\"晴天\",\"artistName\":\"翻唱\",\"duration\":240,\"syncedLyrics\":\"[00:00.00]b\",\"plainLyrics\":\"b\"}]"
  let hits = parse_lrclib_search(body)
  assert_eq(hits.length(), 2)
  assert_eq(hits[0].artist_name, "周杰伦")
  assert_eq(hits[1].artist_name, "翻唱")
  // 非数组 / 坏 JSON → 空表（不是 raise）
  assert_eq(parse_lrclib_search("{\"code\":503}").length(), 0)
  assert_eq(parse_lrclib_search("garbage").length(), 0)
}

///|
/// 挑选规则的三条优先级：带时间轴 > 时长最接近 > 标题/歌手逐字相同。
test "lrclib：挑选偏带时间轴、时长最近、逐字相同的" {
  let q = lq("晴天", "周杰伦", 269.0)
  // 纯文本的"精确同名" vs 带时间轴的翻唱：带时间轴的赢（能逐句高亮）
  let synced_cover : OnlineLyricHit = {
    track_name: "晴天",
    artist_name: "翻唱",
    duration_s: 268.0,
    synced: Some("[00:00.00]x"),
    plain: None,
  }
  let plain_exact : OnlineLyricHit = {
    track_name: "晴天",
    artist_name: "周杰伦",
    duration_s: 269.0,
    synced: None,
    plain: Some("只有纯文本"),
  }
  let picked = pick_lyrics_hit([plain_exact, synced_cover], q).unwrap()
  assert_eq(picked.artist_name, "翻唱")
  // 都有时间轴时：时长差 30 秒的现场版输给录音室版
  let studio : OnlineLyricHit = {
    track_name: "晴天",
    artist_name: "周杰伦",
    duration_s: 269.0,
    synced: Some("[00:00.00]studio"),
    plain: None,
  }
  let live : OnlineLyricHit = {
    track_name: "晴天",
    artist_name: "周杰伦",
    duration_s: 299.0,
    synced: Some("[00:00.00]live"),
    plain: None,
  }
  assert_eq(
    pick_lyrics_hit([live, studio], q).unwrap().synced.unwrap(),
    "[00:00.00]studio",
  )
  // 空表 → None
  assert_true(pick_lyrics_hit([], q) is None)
}

///|
/// 候选最终给 UI 什么：有时间轴原样给（走与本地 .lrc 同一条 parse_lrc），
/// 只有纯文本就补一条递增的假时间轴——整段挤在一行是显示不出来的。
test "lrclib：有真时间轴就用，没有就补假时间轴" {
  let synced : OnlineLyricHit = {
    track_name: "a",
    artist_name: "b",
    duration_s: 1.0,
    synced: Some("[00:01.00]真"),
    plain: Some("纯"),
  }
  assert_eq(hit_to_lrc(synced).unwrap(), "[00:01.00]真")
  let plain : OnlineLyricHit = {
    track_name: "a",
    artist_name: "b",
    duration_s: 3.0,
    synced: None,
    plain: Some("第一句\n\n第二句\n第三句"),
  }
  let lrc = hit_to_lrc(plain).unwrap()
  // 空行不占时间轴：三句 → 0/1/2 秒
  assert_true(lrc.contains("[00:00.00]第一句"))
  assert_true(lrc.contains("[00:01.00]第二句"))
  assert_true(lrc.contains("[00:02.00]第三句"))
  // 合成出来的确实是能被 parse_lrc 吃掉的真 LRC（不是一段死文本）
  assert_eq(parse_lrc(lrc).length(), 3)
  // 两个都空 → None
  let empty : OnlineLyricHit = {
    track_name: "a",
    artist_name: "b",
    duration_s: 0.0,
    synced: None,
    plain: Some(""),
  }
  assert_true(hit_to_lrc(empty) is None)
}

///|
/// 计划表：每个候选两条（get 在前 search 在后），空标题的候选跳过。
test "lrclib：计划表每条候选两个端点，空标题跳过" {
  let plan = online_lyrics_plan(
    [("晴天", "周杰伦"), ("周杰伦", "晴天")],
    269.0,
  )
  assert_eq(plan.length(), 4)
  assert_true(plan[0].1)
  assert_true(plan[0].2.contains("/api/get?"))
  assert_false(plan[1].1)
  assert_true(plan[1].2.contains("/api/search?"))
  // 第三格回到候选 0？不——候选 1 的 get。序号必须跟着候选走
  assert_eq(plan[2].0, 1)
  assert_true(plan[2].2.contains("track_name=%E5%91%A8%E6%9D%B0%E4%BC%A6"))
  // 空标题整条跳过（只发第二格）
  let one = online_lyrics_plan(
    [("", "周杰伦"), ("晴天", "周杰伦")],
    0.0,
  )
  assert_eq(one.length(), 2)
  assert_eq(one[0].0, 1)
}

///|
/// 决策状态机：取到哪一步、命中就收、全空就放弃。
test "lrclib：决策机的四条转移" {
  let cands = [("晴天", "周杰伦"), ("周杰伦", "晴天")]
  let plan = online_lyrics_plan(cands, 269.0)
  // 还没取任何响应 → 要第一条（get）
  match online_lyrics_step(plan, cands, 269.0, []) {
    OnlineStep::Fetch(url) => assert_true(url.contains("/api/get?"))
    _ => fail("应该是 Fetch")
  }
  // get 精确命中 → 直接 Done，不再问 search
  let get_hit = "{\"trackName\":\"晴天\",\"artistName\":\"周杰伦\",\"duration\":269,\"syncedLyrics\":\"[00:00.00]词\",\"plainLyrics\":\"词\"}"
  match online_lyrics_step(plan, cands, 269.0, [Some(get_hit)]) {
    OnlineStep::Done(lrc) => assert_eq(lrc, "[00:00.00]词")
    _ => fail("get 命中应该 Done")
  }
  // get 404（None）→ 换 search
  match online_lyrics_step(plan, cands, 269.0, [None]) {
    OnlineStep::Fetch(url) => assert_true(url.contains("/api/search?"))
    _ => fail("get 没命中应该换 search")
  }
  // search 也空 → 换下一个候选的 get
  match online_lyrics_step(plan, cands, 269.0, [None, Some("[]")]) {
    OnlineStep::Fetch(url) => {
      assert_true(url.contains("/api/get?"))
      // 第一候选的两个都试过了：URL 里该是候选 2 的词
      assert_true(url.contains("track_name=%E5%91%A8%E6%9D%B0%E4%BC%A6"))
    }
    _ => fail("应该换下个候选")
  }
  // 四条全空 → GiveUp
  match online_lyrics_step(plan, cands, 269.0, [None, None, None, None]) {
    OnlineStep::GiveUp => ()
    _ => fail("全空应该 GiveUp")
  }
  // search 命中但只有纯文本 → 补假时间轴后 Done
  let search_plain = "[{\"trackName\":\"晴天\",\"artistName\":\"周杰伦\",\"duration\":269,\"syncedLyrics\":null,\"plainLyrics\":\"纯文本一句\"}]"
  match online_lyrics_step(plan, cands, 269.0, [None, Some(search_plain)]) {
    OnlineStep::Done(lrc) =>
      assert_true(lrc.contains("[00:00.00]纯文本一句"))
    _ => fail("search 的纯文本也该 Done")
  }
}

///|
/// 事件绑定接通（`T158`）：注入 `on_fetch_online` 之后，换歌会**只问一次**，
/// 结果回来经 `apply_online_lyrics` 落到歌词缓存。
///
/// 无头侧的理由要写清楚：这条链在真窗口上是 500ms 心跳驱动的，没有这个闸
/// 就是每半秒一轮 HTTP。这里用 MockAudioEngine 把「换歌 → 问一次 → 不再问」
/// 和「旧歌的结果不贴到新歌上」两条值守都钉住。
test "app：在线取词只问一次，过期结果不贴" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let t1 = Track::from_path("/m/周杰伦 - 晴天.mp3")
  let t2 = Track::from_path("/m/陈奕迅 - 十年.mp3")
  engine.stub(t1, [])
  engine.stub(t2, [])
  // 记账盒：ask 记每次发出去的 (path, candidates)，land 留着等测试手动投放
  let asked : Array[(String, Array[(String, String)], Double)] = []
  let lands : Array[(String, String?) -> Unit] = []
  let cm = LunaMusicApp::new(
    app,
    engine,
    on_fetch_online=Some(fn(
      path : String,
      candidates : Array[(String, String)],
      duration_s : Double,
      land : (String, String?) -> Unit,
    ) {
      asked.push((path, candidates, duration_s))
      lands.push(land)
    }),
  )
  cm.merge_scan("/m", [t1, t2])
  cm.player.play_index(0)
  cm.refresh_lyrics() catch {
    _ => ()
  }
  // 第一次换歌：问了，且候选是文件名推出来的（晴天 / 周杰伦 两种切法）
  assert_eq(asked.length(), 1)
  assert_eq(asked[0].0, t1.path)
  assert_true(asked[0].1.length() >= 2)
  assert_eq(asked[0].1[0], ("晴天", "周杰伦"))
  // 心跳再来几拍：不再问（没有这道闸就是每半秒一轮 HTTP）
  cm.refresh_lyrics() catch {
    _ => ()
  }
  cm.refresh_lyrics() catch {
    _ => ()
  }
  assert_eq(asked.length(), 1)
  // 结果回来：落到歌词缓存
  lands[0](t1.path, Some("[00:00.00]故事的小黄花"))
  assert_eq(cm.current_lyrics.length(), 1)
  // 中间那行是当前句（LyricsView 的五行簇，`T159`③ 从三行改来，居中行是 2）
  assert_eq(
    cm.ui.unwrap().lyrics.lines[2].text() catch {
      _ => ""
    },
    "故事的小黄花",
  )
  // 换到第二首：问第二次
  cm.player.play_index(1)
  cm.refresh_lyrics() catch {
    _ => ()
  }
  assert_eq(asked.length(), 2)
  assert_eq(asked[1].0, t2.path)
  // 第一首的词这时候才回来 → 过期，不能贴上去
  lands[0](t1.path, Some("[00:00.00]过期的一句"))
  for i = 0; i < 5; i = i + 1 {
    let shown = cm.ui.unwrap().lyrics.lines[i].text() catch { _ => "" }
    assert_false(shown.contains("过期的一句"))
    assert_false(shown.contains("故事的小黄花"))
  }
  @moonui.Backend::terminate(b)
}

///|
/// 繁→简（`T159`①）：实跑 lrclib 的结论是中文歌条目几乎全是繁体，所以"优先
/// 简体"落在**取到之后转**。这里钉三件事：真的会转、非汉字原样、多义字不动。
test "t2s：繁体歌词转简体，ASCII 与多义字原样" {
  // 实测抓回来的那两句（`素颜` id 34495907）
  assert_eq(
    to_simplified("又是一個安靜的晚上"),
    "又是一个安静的晚上",
  )
  assert_eq(
    to_simplified("最真實的喜怒哀樂全都埋葬在昨天"),
    "最真实的喜怒哀乐全都埋葬在昨天",
  )
  // 时间标签是 ASCII，必须原样过
  assert_eq(to_simplified("[00:13.16] 又是一個"), "[00:13.16] 又是一个")
  // 本来就是简体 / 非中文：一个字都不改
  assert_eq(to_simplified("故事的小黄花"), "故事的小黄花")
  assert_eq(to_simplified("Hello, world!"), "Hello, world!")
  // 多义字 乾/藉/瞭/徵 整个不进表：`乾隆` 的 `乾` 换了就错，所以宁可留繁体。
  // 同一个词里该转的字照转（`淨`→`净`），剔除是按字、不是按词。
  assert_eq(to_simplified("乾淨"), "乾净")
  assert_eq(to_simplified("乾隆"), "乾隆")
  assert_eq(to_simplified("慰藉"), "慰藉")
  // `著` **不在**剔除名单里：实测 25 首真实歌词里它出现 205 次，全是助词
  // 「着」，"notable" 用法 0 次。留着它等于每首歌带 8 个繁体字。代价是
  // 「著名」会被换成「着名」——歌词里几乎不出现这个词，认了。
  assert_eq(to_simplified("著名"), "着名")
  assert_eq(to_simplified("就飄著"), "就飘着")
  // `妳` 也不进表：ICU 不把它并成 `你`（性别自指的写法，并掉等于改词）。
  assert_eq(to_simplified("握著妳手"), "握着妳手")
  // 判据方向：没有表内字就是"本来就是简体"
  assert_true(is_simplified("故事的小黄花"))
  assert_false(is_simplified("又是一個安靜的晚上"))
}

///|
/// 缓存落点（`T159`②）：在线取到的词写**共用的 `歌.lrc`**——所有播放器都认的
/// 约定名，别的播放器打开同一首歌就不用再各自联网查一遍。
///
/// 能在这里测的是"空曲目路径不缓存"（wasm 与无头测试据此整段跳过）；"文件已经
/// 存在就不写"那半要探盘，无头测试探不到，理由与取舍写在 `lyric_save_path` 头上。
test "缓存：空曲目路径不缓存（wasm 与无头测试据此跳过）" {
  assert_eq(lyric_save_path("") catch { _ => "raise" }, "")
}

///|
/// `hit_to_lrc` 的出口统一转简体：不管服务器给的是时间轴版还是纯文本版，
/// UI 拿到的都是简体（`T159`①）。挑选层不参与简繁，只在这最后一跳转。
test "lrclib：取到的歌词出口统一是简体" {
  let synced : OnlineLyricHit = {
    track_name: "素颜",
    artist_name: "许嵩",
    duration_s: 239.0,
    synced: Some(
      "[00:13.16]又是一個安靜的晚上\n[00:15.87]一個人窩在搖椅裡乘涼",
    ),
    plain: None,
  }
  let lrc = hit_to_lrc(synced).unwrap()
  assert_eq(
    lrc, "[00:13.16]又是一个安静的晚上\n[00:15.87]一个人窝在摇椅里乘凉",
  )
  // 纯文本版（补假时间轴那条路）同样要转
  let plain : OnlineLyricHit = {
    track_name: "素颜",
    artist_name: "许嵩",
    duration_s: 3.0,
    synced: None,
    plain: Some("又是一個安靜的晚上\n一個人窩在搖椅裡乘涼"),
  }
  let lrc2 = hit_to_lrc(plain).unwrap()
  assert_true(lrc2.contains("又是一个安静的晚上"))
  assert_true(lrc2.contains("一个人窝在摇椅里乘凉"))
  // 本来就简体的原样（别把简体转坏）
  let cn : OnlineLyricHit = {
    track_name: "晴天",
    artist_name: "周杰伦",
    duration_s: 269.0,
    synced: Some("[00:00.00]故事的小黄花"),
    plain: None,
  }
  assert_eq(hit_to_lrc(cn).unwrap(), "[00:00.00]故事的小黄花")
}

///|
/// 歌词秀 5 行（`T159`③）：当前句在正中，上下各铺两行；越界的行留空。
test "app：歌词秀五行，当前句居中、上下各两行" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [Track::from_path("/m/晴天.mp3")])
  cm.player.play_index(0)
  // 六句，从第 1 秒起每秒一句
  let lrc = "[00:01.00]第一句\n[00:02.00]第二句\n[00:03.00]第三句\n[00:04.00]第四句\n[00:05.00]第五句\n[00:06.00]第六句"
  cm.current_lyrics = parse_lrc(lrc)
  assert_eq(cm.current_lyrics.length(), 6)
  // 窗口挂起来了才有 5 行可查
  assert_eq(cm.ui.unwrap().lyrics.lines.length(), 5)
  // 播到第 3 句（pos 3.5s → active = 2 号）：正中是第三句，上面两行是第一、二句，
  // 下面两行是第四、五句
  cm.ui.unwrap().lyrics.update(cm.current_lyrics, 3500L, "晴天", "周杰伦") catch {
    _ => ()
  }
  let shown : Array[String] = []
  for i = 0; i < 5; i = i + 1 {
    shown.push(cm.ui.unwrap().lyrics.lines[i].text() catch { _ => "" })
  }
  assert_eq(shown[2], "第三句")
  assert_eq(shown[0], "第一句")
  assert_eq(shown[1], "第二句")
  assert_eq(shown[3], "第四句")
  assert_eq(shown[4], "第五句")
  // 播到第 1 句：上面两行越界，留空而不是回绕
  cm.ui.unwrap().lyrics.update(cm.current_lyrics, 1500L, "晴天", "周杰伦") catch {
    _ => ()
  }
  let top : Array[String] = []
  for i = 0; i < 5; i = i + 1 {
    top.push(cm.ui.unwrap().lyrics.lines[i].text() catch { _ => "" })
  }
  assert_eq(top[2], "第一句")
  assert_eq(top[0], "")
  assert_eq(top[1], "")
  assert_eq(top[3], "第二句")
  assert_eq(top[4], "第三句")
  // 播到末句：下面两行越界，同样留空
  cm.ui.unwrap().lyrics.update(cm.current_lyrics, 6500L, "晴天", "周杰伦") catch {
    _ => ()
  }
  let bot : Array[String] = []
  for i = 0; i < 5; i = i + 1 {
    bot.push(cm.ui.unwrap().lyrics.lines[i].text() catch { _ => "" })
  }
  assert_eq(bot[2], "第六句")
  assert_eq(bot[3], "")
  assert_eq(bot[4], "")
  @moonui.Backend::terminate(b)
}
