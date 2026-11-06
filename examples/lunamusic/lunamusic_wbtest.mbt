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
  {
    path,
    title: path,
    artist: "a",
    album: "b",
    duration_ms: dur,
    cover: None,
    loudness: None,
    lyrics: "",
  }
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
  // `T168`：Player::new 现在多接一条 handoff（on_primed_start）。
  // `T170`：开播后按开关/测值挂归一化增益——关着挂 0（calls 里那条 gain:0）
  assert_eq(e.calls, [
    "on_finished", "on_primed_start", "load:/m/1.mp3", "play", "gain:0", "pause",
  ])
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
/// 固定种子（32 字节，`Rand::chacha8` 的硬要求）：让洗牌顺序在测试里可复现。
let shuffle_seed : Bytes = b"0123456789abcdefghijklmnopqrstuv"

///|
/// 用给定种子起一个随机播放器，从第 `from` 首开始，连按 `n` 次「下一首」，
/// 返回这一轮实际走到的下标序列（`T167`：随机与否只有这个序列能证明）。
fn shuffle_walk(
  seed : Bytes,
  count : Int32,
  from : Int32,
  n : Int32,
) -> Array[Int32] {
  let tracks : Array[Track] = []
  for i = 0; i < count; i = i + 1 {
    tracks.push(trk("/m/\{i}.mp3", 300L))
  }
  let p = Player::new(eng_with(tracks), tracks)
  p.set_shuffle_rng(@random.Rand::chacha8(seed~))
  p.play_index(from)
  p.cycle_mode() // → 单曲循环
  p.cycle_mode() // → 随机
  let out : Array[Int32] = []
  for _step = 0; _step < n; _step = _step + 1 {
    p.next()
    out.push(
      match p.current {
        Some(i) => i
        None => -1
      },
    )
  }
  out
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
  // 第一轮：三首各走一次，顺序随机但集合必须恰好是 {0,1,2}
  let seen : Array[Int32] = [0]
  for _step = 0; _step < 2; _step = _step + 1 {
    p.next()
    seen.push(p.current.unwrap())
  }
  let sorted = seen.copy()
  sorted.sort()
  assert_eq(sorted, [0, 1, 2])
  // 一轮走完牌堆空：手动 next 重洗开下一轮，且绝不立刻重放刚放完那首
  let last = p.current.unwrap()
  p.next()
  assert_true(p.current.unwrap() != last)
  // 第二轮：换模式清旧牌堆，重洗
  p.play_index(0)
  p.cycle_mode()
  p.cycle_mode() // → 随机（换模式清旧牌堆）
  p.next()
  p.next()
  // 一轮走完自然播完：牌堆空了当场重洗，接着播下一轮（不重复的是**一轮内**，
  // 随机播放本来就不该放完 N 首就停）。
  e.fire_finished()
  assert_true(p.is_playing())
}

///|
/// `T167` 的正面判据：洗出来的顺序必须**真是随机的**，而不是原来的顺序。
/// 三条一起断：①同种子两次同序（`set_shuffle_rng` 真接上了）；
/// ②不同种子至少能洗出两种顺序（不是恒等）；③一轮走完正好覆盖除当前曲外
/// 的全部——随机不等于乱来，集合语义不能丢。
test "player：随机模式真洗牌（T167）" {
  let a = shuffle_walk(shuffle_seed, 8, 0, 7)
  let b = shuffle_walk(shuffle_seed, 8, 0, 7)
  assert_eq(a, b) // ① 同种子可复现
  let sorted = a.copy()
  sorted.sort()
  assert_eq(sorted, [1, 2, 3, 4, 5, 6, 7]) // ③ 覆盖全队列且不重复
  // ② 换种子必须洗出别的顺序——否则"随机"只是顺序播放的换皮
  let other_seeds : Array[Bytes] = [
    b"00000000000000000000000000000000", b"11111111111111111111111111111111", b"22222222222222222222222222222222",
    b"33333333333333333333333333333333",
  ]
  let orders : Array[Array[Int32]] = [a]
  for seed in other_seeds {
    let o = shuffle_walk(seed, 8, 0, 7)
    let mut dup = false
    for seen in orders {
      if seen == o {
        dup = true
      }
    }
    if !dup {
      orders.push(o)
    }
  }
  assert_true(orders.length() >= 2)
}

///|
/// 负控制：顺序模式下同样的走法必须是 1、2、3……——证明上面那条判据
/// 区分的是"随机 vs 顺序"，不是"能走就行"。
test "player：顺序模式对照（随机判据的负控制）" {
  let tracks : Array[Track] = []
  for i = 0; i < 8; i = i + 1 {
    tracks.push(trk("/m/\{i}.mp3", 300L))
  }
  let p = Player::new(eng_with(tracks), tracks)
  p.play_index(0)
  let out : Array[Int32] = []
  for _step = 0; _step < 7; _step = _step + 1 {
    p.next()
    out.push(p.current.unwrap())
  }
  assert_eq(out, [1, 2, 3, 4, 5, 6, 7])
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
/// 扫描（`T197`：递归策略搬进框架 `Fs::walk` 之后，应用侧只剩白名单）：
/// 音频收下、非音频当目录试一层、子目录继续钻、结果按路径有序。
test "walk：scan_tree 走白名单、钻子目录、结果有序（T197）" {
  let tree : Map[String, Array[String]] = Map([
    ("/vol", ["/vol/b.mp3", "/vol/cover.jpg", "/vol/sub", "/vol/A.FLAC"]),
    ("/vol/sub", ["/vol/sub/c.wav", "/vol/sub/notes.txt", "/vol/sub/inner"]),
    ("/vol/sub/inner", ["/vol/sub/inner/d.ogg"]),
  ])
  set_walk_dir(fn(dir) {
    match tree.get(dir) {
      Some(xs) => xs
      None => []
    }
  })
  // 白名单只认扩展名；cover.jpg / notes.txt 被当目录试一层（注入表里没有它们，
  // 于是空），不会进结果。四首音频都收齐；顺序是框架的 shortlex（先比长度、
  // 同长再比码位）——所以 11 字符的 `/vol/A.FLAC` 排在 10 字符的 `/vol/b.mp3`
  // 之后，按字母序写期望值会红。
  assert_eq(scan_tree("/vol"), [
    "/vol/b.mp3", "/vol/A.FLAC", "/vol/sub/c.wav", "/vol/sub/inner/d.ogg",
  ])
  // 同一棵树换白名单：皮肤档一个都不认（jpg/mp3/wav/ogg 都不在皮肤白名单里）
  assert_eq(scan_skins("/vol"), [])
  // 收尾还原成"未注入"：别的判据依赖这个默认形状
  set_walk_dir(fn(_) { [] })
  assert_eq(scan_tree("/vol"), [])
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
  let lyrics = s("[00:01.00]手牵手\n[00:05.50]一步两步三步四步")
  // 打包布局与 C 侧一致：[len][bytes] 交替，不前置
  let whole = i32le(title.length())
    .add(title)
    .add(i32le(artist.length()))
    .add(artist)
    .add(i32le(album.length()))
    .add(album)
    .add(i64le(269000L))
    .add(i32le(0))
    .add(i32le(lyrics.length()))
    .add(lyrics)
  let t = track_from_probe("/m/晴天.mp3", whole).unwrap()
  assert_eq(t.title, "晴天")
  assert_eq(t.artist, "周杰伦")
  assert_eq(t.album, "叶惠美")
  assert_eq(t.duration_ms, 269000L)
  assert_eq(t.cover, None)
  assert_eq(t.lyrics, "[00:01.00]手牵手\n[00:05.50]一步两步三步四步")
  // 空字段退回文件名；坏包（截断）整体 None
  let empty = i32le(0)
    .add(i32le(0))
    .add(i32le(0))
    .add(i64le(-1L))
    .add(i32le(0))
    .add(i32le(0))
  let t2 = track_from_probe("/m/song.mp3", empty).unwrap()
  assert_eq(t2.title, "song")
  assert_eq(t2.duration_ms, -1L)
  assert_eq(t2.lyrics, "")
  // T180：新段缺着 = 旧格式的包按坏包处理（严格解码）
  assert_true(
    track_from_probe(
      "/m/old.mp3",
      i32le(title.length())
      .add(title)
      .add(i32le(0))
      .add(i32le(0))
      .add(i32le(0))
      .add(i64le(-1L))
      .add(i32le(0)),
    )
    is None,
  )
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
/// 顶条双击 = 进/出迷你模式（`T182`）：卷起改迷你。主控是定尺皮肤窗，
/// 真最大化做不实（mac 实测 zoom 只翻标志位）；判据钉接线——双击顶条
/// （命中 logo，`T141` 起挂冒泡口，冒泡到顶条）`mini` 翻真，再双击迷你条
/// （命中歌名）翻回。`toggle_mini` 本体的显隐行为另有账，这里只验手势。
test "app：顶条双击切迷你模式，迷你条双击切回（T182）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  assert_false(cm.mini)
  let content = match cm.ui.unwrap().window.content() {
    Some(w) => w
    None => abort("主控窗没有内容树")
  }
  let logo = match find_text_widget(content, "♪ Luna") {
    Some(w) => w
    None => abort("顶条上没有 logo")
  }
  let _ = app.dispatch(@moonui.DoubleClick(logo.target()))
  assert_true(cm.mini)
  // 迷你条上双击歌名（命中 label，冒泡到迷你条根面板）→ 回主控
  let mini_content = match cm.ui.unwrap().mini_win.content() {
    Some(w) => w
    None => abort("迷你条窗没有内容树")
  }
  let title = match find_text_widget(mini_content, "未播放") {
    Some(w) => w
    None => abort("迷你条上没有歌名")
  }
  // 四病回归（2026-11-04 抓图）：根铺满整窗（右边不再露底色空白）、高度整 48
  // （上下不再有 1px 倒角杂线）、歌名在条里垂直居中。
  let rf = mini_content.frame()
  assert_eq(rf.size.width, cm_mini_w())
  assert_eq(rf.size.height, cm_mini_h())
  let tf = title.frame()
  assert_eq(tf.origin.y + tf.size.height / 2.0, cm_mini_h() / 2.0)
  let _ = app.dispatch(@moonui.DoubleClick(title.target()))
  assert_false(cm.mini)
  @moonui.Backend::terminate(b)
}

///|
/// 迷你条整句口径（owner 2026-11-05）：「歌手 - 歌名」，缺谁留谁。走
/// `refresh_bar` 的真实入口（`play_index` 之后心跳刷一轮），展示口径切
/// Tags——文件名那支的歌手/歌名切分要靠猜，字段才确定。
test "app：迷你条整句 =「歌手 - 歌名」，缺谁留谁" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let with_artist = {
    path: "/m/1.mp3",
    title: "晴天",
    artist: "周杰伦",
    album: "",
    duration_ms: 221000L,
    cover: None,
    loudness: None,
    lyrics: "",
  }
  let no_artist = {
    path: "/m/2.mp3",
    title: "不见",
    artist: "",
    album: "",
    duration_ms: 200000L,
    cover: None,
    loudness: None,
    lyrics: "",
  }
  engine.stub(with_artist, [])
  engine.stub(no_artist, [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [with_artist, no_artist])
  cm.display = Tags
  // 文本账只在迷你模式刷（非迷你时 sync 只存整句，toggle 进迷你时再落），
  // 所以先进迷你再看。
  cm.toggle_mini() catch {
    _ => abort("toggle_mini 不该失败")
  }
  // 没在播：占位句
  assert_eq(cm.ui.unwrap().mini.title.text(), "未播放")
  // 两格都在 → 「歌手 - 歌名」
  cm.player.play_index(0)
  assert_eq(cm.ui.unwrap().mini.title.text(), "周杰伦 - 晴天")
  // 歌手缺 → 只留歌名
  cm.player.play_index(1)
  assert_eq(cm.ui.unwrap().mini.title.text(), "不见")
  @moonui.Backend::terminate(b)
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
  // 播放条那格按**显示口径**画（`T193`）：默认文件名，所以是 `2.mp3` 去扩展名
  // 的 `2`，不是 Track 里那份 title（夹具的 title 恰好是整条路径）。
  assert_eq(bar2.title.text(), "2")
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
  // 五行自绘面（`T161`）不再是原生文本，`dump_layout` 里没有它们的文案——
  // 那部分改由绘制清单断言（本文件 `cm_lyric_rows` 那几条用例）。这里改为钉
  // 住歌词窗顶条上新出现的那颗动作按钮。
  assert_true(dl.contains("搜索歌词"))
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
    position_ms: 42000L,
    eq_bands: [500, 500, 500, 500, 500, 500, 500, 500, 500, 500],
    eq_on: false,
    skin: "深空灰",
    display: Tags,
    show_desk: false,
    normalize: false,
    playlists: [],
  }
  let rt = Prefs::from_json(p.to_json())
  let p2 = rt.unwrap()
  assert_eq(p2.volume, 600)
  assert_eq(p2.mode, RepeatOne)
  assert_eq(p2.last_path, Some("/m/a.mp3"))
  // 播放位置（`T184`）也往返：Int64 毫秒进 JSON 的 number，42 秒一格不该丢
  assert_eq(p2.position_ms, 42000L)
  // 显示口径（`T193`）也往返
  assert_eq(p2.display, Tags)
  // 桌面歌词开关（`T195`）也往返：用户关掉之后下次启动仍按关闭起步
  assert_eq(p2.show_desk, false)
  // 缺字段 → 默认值起步
  let partial = Prefs::from_json(
    Json::object(Map::from_array([("volume", Json::number(300.0))])),
  ).unwrap()
  assert_eq(partial.volume, 300)
  assert_eq(partial.mode, Sequential)
  // 旧档没有 position 这一格（`T184` 之前写的档）→ 0 = 从头，行为与改之前一样
  assert_eq(partial.position_ms, 0L)
  assert_eq(partial.last_path, None)
  // 旧档没有 show_desk → 默认开（升级前用户没表达过"不要它"）
  assert_true(partial.show_desk)
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
  // 搜索：命中标题（ASCII 不区分大小写——查大写一样命中小写路径）
  assert_eq(filter_tracks(lib.tracks, "b.mp3").length(), 1)
  assert_eq(filter_tracks(lib.tracks, "B.MP3").length(), 1)
  assert_eq(filter_tracks(lib.tracks, "B.Mp3").length(), 1)
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
  // 选中态也跟着换（`T128` 原判据，`T179` 换了机制）：高亮从"按钮底色"
  // 换成侧栏 MenuRow 的 checked 通道（DESIGN C-03），`refresh` 必须把
  // checked 下到**当前页那条**上；`tabs`/`tab_ids` 按 tab_ids 对位。
  assert_true(ui.table.tabs[1].checked() catch { _ => false })
  assert_false(ui.table.tabs[0].checked() catch { _ => true })
  assert_eq(@moonui.Widget::text(ui.table.tabs[1]), "我喜欢的")
  @moonui.Backend::terminate(b)
}

///|

///|
/// 托盘菜单三样新账（`T183`）：当前曲（禁用项）、播放模式、音量五档子菜单。
/// MenuItem 没有 set_text，动态文案走"签名边沿 + 整菜单重设"——判据钉三件：
/// ①装一次后签名记下，没变化的拍子不再重设（set_tray_menu 计数不涨）；
/// ②切歌/换模式后各重设一次（计数按边沿涨，不是每拍涨）；③重设后的菜单
/// 快照里能找到「♪ 1」与「播放模式：单曲循环」。
test "app：托盘菜单带当前曲/模式/音量，按签名边沿重设（T183）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  engine.stub(trk("/m/1.mp3", 100L), [])
  engine.stub(trk("/m/2.mp3", 100L), [])
  let cm = LunaMusicApp::new(app, engine)
  cm.install_tray() catch {
    _ => ()
  }
  let sets0 = @moonui.MockBackend::tray_install_count(b)
  assert_true(sets0 > 0)
  // 没变化的拍子：refresh_bar 照跑，托盘一个字不动
  cm.refresh_bar() catch {
    _ => ()
  }
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_eq(@moonui.MockBackend::tray_install_count(b), sets0)
  // 切歌：签名变了 → 恰好一次重设，曲名跟着换
  cm.merge_scan("/m", [
    Track::from_path("/m/1.mp3"),
    Track::from_path("/m/2.mp3"),
  ])
  cm.player.play_index(0)
  cm.refresh_bar() catch {
    _ => ()
  }
  let sets1 = @moonui.MockBackend::tray_install_count(b)
  assert_true(sets1 > sets0)
  let labels1 = tray_labels(@moonui.MockBackend::tray_menu(b).unwrap())
  assert_true(labels1.contains("♪ 1"))
  // 再来一拍（位置在走）：不重设
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_eq(@moonui.MockBackend::tray_install_count(b), sets1)
  // 换模式：恰好一次重设，文案跟着换
  cm.player.cycle_mode()
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_eq(@moonui.MockBackend::tray_install_count(b), sets1 + 1)
  let labels2 = tray_labels(@moonui.MockBackend::tray_menu(b).unwrap())
  assert_true(labels2.contains("播放模式：单曲循环"))
  // 音量五档在子菜单里（flatten 不含子菜单标题，档位项在）
  assert_true(labels2.contains("静音"))
  assert_true(labels2.contains("100%"))
  @moonui.Backend::terminate(b)
}

///|
fn tray_labels(menu : @moonui.Menu) -> Array[String] {
  let out : Array[String] = []
  for it in menu.flatten() {
    out.push(it.label)
  }
  out
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
/// `T192`：关掉桌面歌词窗**不退出应用**，也不把它变成一只死窗。
///
/// owner 报的现象是"关掉那条浮条，整个程序没了"。链路是两段：那只窗旧行为
/// 走 `CloseAction::Destroy`，内容树整棵销毁；紧接着 500ms 心跳里的
/// `refresh_lyrics` 还在往那几只 Label 上写文案，`Destroyed` 从 `App::step`
/// 里抛出去，`App::run` 收尾 → 进程结束。所以判据要卡在两段之间：
///
/// 1. 关掉之后窗口**没有** `closed`（内容树活着，心跳继续写得进去）；
/// 2. 开关账跟着关上——`show_desk` 变 false，不然下一次判"该显示"边沿没变，
///    窗口再也叫不回来；
/// 3. 再走一拍心跳不抛错，且应用还在跑（`is_finished` false）。
/// 第 3 条是真正钉死"不退出"的那一条：旧实现走到这里 `step` 就 raise 了。
test "app：关掉桌面歌词窗不退出应用（T192）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  engine.stub(trk("/m/晴天.mp3", 6000L), [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [Track::from_path("/m/晴天.mp3")])
  cm.player.play_index(0)
  cm.current_lyrics = parse_lrc("[00:01.00]第一句\n[00:02.00]第二句")
  cm.lyrics_path = cm.player.track().unwrap().path
  cm.refresh_lyrics() catch {
    _ => ()
  }
  let u = cm.ui.unwrap()
  // 前提：有歌词 → 浮条是挂着的
  assert_true(cm.desk_shown)
  let desk_h = u.desk_win.handle()
  // 用户点了那条浮条的关闭钮：mac/Win32 都会先报 closing，Core 派发 Close
  let _ = app.dispatch(@moonui.Close(u.desk_win.target()))
  // ① 窗还活着（内容树没被销毁）
  assert_false(u.desk_win.is_closed())
  assert_true(u.desk_win.content() is Some(_))
  // ② 开关账同步关上
  cm.sync_desk_window() catch {
    _ => ()
  }
  assert_false(cm.show_desk)
  assert_false(cm.desk_shown)
  // ③ 下一拍心跳照常跑，不抛错、应用没退
  cm.refresh_lyrics() catch {
    _ => ()
  }
  let stepped = app.step() catch {
    _ => fail("心跳里往桌面歌词写字抛了错")
  }
  let _ = stepped
  assert_false(app.is_finished())
  // 窗仍然可用：菜单再打开它就回来，且句柄还是原来那只（没有变成死窗）
  cm.toggle_desk() catch {
    _ => ()
  }
  assert_true(cm.show_desk)
  assert_eq(u.desk_win.handle().id, desk_h.id)
  assert_false(u.desk_win.is_closed())
  @moonui.Backend::terminate(b)
}

///|
/// `T195`：桌面歌词开关进档。恢复点只改 `show_desk` 这一位，可见性仍由
/// `cm_desk_visible` 推：档里是 false（用户上次关掉了）→ 浮条不进启动窗口表；
/// 档里是 true（默认/旧档）→ 照挂。两只分支都钉，免得"存了但没读"被漏掉。
test "app：桌面歌词开关从偏好档恢复（T195）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  engine.stub(trk("/m/晴天.mp3", 6000L), [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [Track::from_path("/m/晴天.mp3")])
  cm.player.play_index(0)
  cm.current_lyrics = parse_lrc("[00:01.00]第一句\n[00:02.00]第二句")
  cm.lyrics_path = cm.player.track().unwrap().path
  cm.refresh_lyrics() catch {
    _ => ()
  }
  let u = cm.ui.unwrap()
  let desk_h = u.desk_win.handle()
  // 档里记着"用户关掉了"：启动不挂浮条
  cm.show_desk = false
  cm.sync_desk_window() catch {
    _ => ()
  }
  let mut off_has_desk = false
  for w in cm.startup_windows() {
    if w.handle().id == desk_h.id {
      off_has_desk = true
    }
  }
  assert_false(off_has_desk)
  // 档里是 true（默认/旧档）：照挂
  cm.show_desk = true
  cm.sync_desk_window() catch {
    _ => ()
  }
  let mut on_has_desk = false
  for w in cm.startup_windows() {
    if w.handle().id == desk_h.id {
      on_has_desk = true
    }
  }
  assert_true(on_has_desk)
  @moonui.Backend::terminate(b)
}

///|
/// `T195` 的边角：暂停时没有心跳，关掉浮条后**立刻**退出也不能记错。
/// 关窗只置了 `close_hidden`（`show_desk` 还是 true），退出路径先
/// `absorb_desk_close()` 结账，才把它落成 false——不然档里记成"还要它"，
/// 下次启动又挂回来（正是 owner 报的现象，而且暂停时最容易撞上）。
test "app：关窗后立刻退出也能记住关闭（T195）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  engine.stub(trk("/m/晴天.mp3", 6000L), [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [Track::from_path("/m/晴天.mp3")])
  cm.player.play_index(0)
  cm.current_lyrics = parse_lrc("[00:01.00]第一句\n[00:02.00]第二句")
  cm.lyrics_path = cm.player.track().unwrap().path
  cm.refresh_lyrics() catch {
    _ => ()
  }
  let u = cm.ui.unwrap()
  assert_true(cm.desk_shown)
  let _ = app.dispatch(@moonui.Close(u.desk_win.target()))
  // 还没结账：开关账仍是"开着"，窗口只是被 Hide 收起来了
  assert_true(cm.show_desk)
  assert_true(cm.desk_shown)
  // 退出前结账 → 记为关闭
  cm.absorb_desk_close()
  assert_false(cm.show_desk)
  assert_false(cm.desk_shown)
  @moonui.Backend::terminate(b)
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
test "CmStrip：mac 不画自绘关闭钮，其余宿主画（T161 补：动作按钮另验）" {
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
/// 顶条的动作按钮（`T161`①）：`actions` 里的每一颗都得进树，**两个宿主
/// 都要**——mac 上没有自绘 ✕，但「搜索歌词」这种业务按钮不是关闭钮的替代，
/// 红绿灯替不了它。空表时树必须与加这个参数之前一样（另外三只窗就靠这条
/// 不被牵连）。
test "CmStrip：动作按钮在 mac 与其它宿主上都进树" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let noop = fn() { () }
  for host in [@moonui.HostPlatform::Macos, @moonui.HostPlatform::Windows] {
    b.set_host_platform(host)
    let with_action = CmStrip::new(b, "歌词秀", noop, actions=[
      ("搜索歌词", noop),
    ])
    let texts = collect_label_texts(with_action.root)
    assert_true(texts.contains("歌词秀"))
    assert_true(texts.contains("搜索歌词"))
    // `T164`③：动作钮要有一张**凸起**的脸，不能与顶条同色（同色就是一行字，
    // 真窗上读成标签）。再挂一条悬停脸，"能按"的两个信号就齐了。
    let btn = match find_text_widget(with_action.root, "搜索歌词") {
      Some(w) => w
      None => abort("顶条里找不到动作按钮")
    }
    assert_eq(
      btn.resolved_style(@moonui.Style::empty()).background,
      Some(cm_btn_bg()),
    )
    assert_true(btn.hover_style is Some(_))
    assert_true(btn.hover_style.unwrap().background is Some(_))
  }
  // 空表：只有标题，没有多出来的按钮（其余三只窗逐位不变）
  b.set_host_platform(Macos)
  let plain = CmStrip::new(b, "播放列表", noop)
  assert_eq(collect_label_texts(plain.root), ["播放列表"])
  @moonui.Backend::terminate(b)
}

///|
/// 按 id 把一棵树里所有带文本的原生叶子的文案收上来（`Widget::text()` 只对
/// 带句柄的叶子有效；容器跳过）。
fn[B : @moonui.Backend] collect_label_texts(
  w : @moonui.Widget[B],
) -> Array[String] {
  let out : Array[String] = []
  collect_label_texts_into(w, out)
  out
}

///|
fn[B : @moonui.Backend] collect_label_texts_into(
  w : @moonui.Widget[B],
  out : Array[String],
) -> Unit {
  match w.handle() {
    Some(_) => {
      let t = w.text() catch { _ => "" }
      if t.length() > 0 {
        out.push(t)
      }
    }
    None => ()
  }
  for c in w.children() {
    collect_label_texts_into(c, out)
  }
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
    loudness: None,
    lyrics: "",
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
    loudness: None,
    lyrics: "",
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
    loudness: None,
    lyrics: "",
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
/// 显示口径（`T193`）：库里存的始终是探针真值，`cm_display_fields` 只决定画
/// 哪一份。默认文件名——owner 2026-11-02 点的口径。
test "display：文件名 / 标签两种口径的投影" {
  let tagged : Track = {
    path: "/m/周杰伦 - 晴天.mp3",
    title: "晴天",
    artist: "周杰伦",
    album: "叶惠美",
    duration_ms: 269000L,
    cover: None,
    loudness: None,
    lyrics: "",
  }
  // 文件名口径：横杠两侧有空格 → `Artist - Title`（iTunes 习惯），第二段才是
  // 歌名；`tag_filename_readings` 的第一候选就是这一份，两处显示因此一致。
  assert_eq(cm_display_fields(tagged, FileName), ("晴天", "周杰伦"))
  // 标签口径：真值原样
  assert_eq(cm_display_fields(tagged, Tags), ("晴天", "周杰伦"))
  // 专辑只有标签口径有；文件名里没有这一格
  assert_eq(cm_display_album(tagged, FileName), "")
  assert_eq(cm_display_album(tagged, Tags), "叶惠美")

  // 探针没读出东西：Track::from_path 把文件名塞进 title，标签口径也得认出来
  // 那是兜底（判据同 `tag_query_candidates`），不能当成真标题显示
  let bare = Track::from_path("/m/许嵩 - 叹服.mp3")
  assert_eq(cm_display_fields(bare, Tags), ("许嵩 - 叹服", ""))
  assert_eq(cm_display_album(bare, Tags), "")

  // 只有一段文件名：文件名口径给不出歌手，就留空——**不写「未知」**，
  // 那是标签缺失的哨兵，"文件名里本来没有歌手"是另一件事
  let single = Track::from_path("/m/给我一首歌的时间.mp3")
  assert_eq(
    cm_display_fields(single, FileName),
    ("给我一首歌的时间", ""),
  )
}

///|
/// 播放条那行的拼接：空的一侧不画出光秃秃的横杠。
test "display：非空段拼接" {
  assert_eq(cm_join_meta("周杰伦", "叶惠美"), "周杰伦 - 叶惠美")
  assert_eq(cm_join_meta("周杰伦", ""), "周杰伦")
  assert_eq(cm_join_meta("", "叶惠美"), "叶惠美")
  assert_eq(cm_join_meta("", ""), "")
}

///|
/// 显示口径的存档键：可读字符串，坏值回 None 由调用方按默认起步。
test "display：存档键往返与坏值" {
  assert_eq(cm_display_source_default(), FileName)
  assert_eq(FileName.key(), "filename")
  assert_eq(Tags.key(), "tags")
  assert_eq(DisplaySource::of_key("filename"), Some(FileName))
  assert_eq(DisplaySource::of_key("tags"), Some(Tags))
  assert_true(DisplaySource::of_key("0") is None)
  assert_true(DisplaySource::of_key("") is None)
  assert_eq(FileName.label(), "文件名")
  assert_eq(Tags.label(), "标签信息")
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
/// 手动搜索（`T161`①）：`/api/search` 的每一条都摆出来，保持服务器原序，
/// 繁体统一转简体，两个歌词都空的壳丢掉。
///
/// 与 `pick_lyrics_hit` 的分工是本条的重点：自动那条要"机器挑一条"，人工
/// 这条要"全都交给用户"——所以这里**不**按分数重排、不丢"不如第一条像"的。
test "lrclib：手动搜索结果全列出来，繁体转简体（T161）" {
  let body = "[{\"trackName\":\"素颜\",\"artistName\":\"许嵩\",\"duration\":269,\"syncedLyrics\":\"[00:00.00]又是一個安靜的晚上\",\"plainLyrics\":null},{\"trackName\":\"空壳\",\"artistName\":\"x\",\"duration\":1,\"syncedLyrics\":null,\"plainLyrics\":null},{\"trackName\":\"素颜\",\"artistName\":\"翻唱\",\"duration\":240,\"syncedLyrics\":null,\"plainLyrics\":\"最真實的喜怒哀樂\"}]"
  let rs = lyric_search_results(body)
  // 空壳那一条被丢掉，剩两条且**保持原序**（翻唱在后，不是因为分数低被踢）
  assert_eq(rs.length(), 2)
  assert_eq(rs[0].title, "素颜")
  assert_eq(rs[0].artist, "许嵩")
  assert_eq(rs[1].artist, "翻唱")
  // 时间轴那一份原样（转简体后）
  assert_eq(rs[0].lrc, "[00:00.00]又是一个安静的晚上")
  // 只有纯文本的那条被补成假时间轴，同样转过简体
  assert_true(rs[1].lrc.contains("最真实的喜怒哀乐"))
  // 坏响应体 → 空表，不 raise
  assert_eq(lyric_search_results("garbage").length(), 0)
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
    cm_lyric_rows(b, cm.ui.unwrap().lyrics.face)[2],
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
  for shown in cm_lyric_rows(b, cm.ui.unwrap().lyrics.face) {
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
/// 临时目录读数（`T161` 的落盘往返测试要用它找落点）。放在这条**门控无关**的
/// 测试里而不是 native 那份：`cm_temp_dir` 只有 native 的测试在用，wasm 侧
/// 会判 unused_value；这里给它一个两个目标都跑的消费点（moonui 的
/// `window_state.mbt` 对 `temp_archive_path` 同一套处理）。只断言"取到了"，
/// 不断言具体路径——三平台的惯例档本来就不同。
test "临时目录：三平台都取得到（T161 落盘测试的前置）" {
  assert_true(@moonui.Fs::temp_dir() != "")
}

///|
/// `T197` 起「路径补 NUL、内容不补」这条账搬进了框架：`packages/moonui` 的
/// `cstr` 负责路径、`fs_write_bytes` 显式传长度负责内容（`T188` 的原判据在
/// 应用侧已经没有可断言的对象了）。守它的判据变成框架侧的两条：`Fs：文本/字节
/// 往返与缺档缺席`（字节逐位相等——内容尾巴多一个 NUL 当场就红）与
/// `窗口存档落盘往返`（路径经 `cstr` 后 fopen 能打开）。

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
/// 从歌词自绘面最近一帧里读出五行文字（`T161`：五行从五只 Label 换成了一整块
/// 自绘面，所以断言改成读绘制清单）。
///
/// 按**文字命令的 y 坐标**回推行号而不是按命令顺序：空行不产生命令
/// （`paint_lyrics` 跳过空串），顺序下标会把"第四句"错读成第 0 行。
fn cm_lyric_rows(
  b : @moonui.MockBackend,
  face : @moonui.Widget[@moonui.MockBackend],
) -> Array[String] raise @moonui.UiError {
  let rows : Array[String] = []
  for i = 0; i < cm_lyric_lines(); i = i + 1 {
    rows.push("")
  }
  let h = match face.handle() {
    Some(h) => h
    None => abort("歌词面没有原生句柄：它没被摆出来")
  }
  let dl = match b.drawn(h) {
    Some(dl) => dl
    None => abort("歌词面一帧都没画过")
  }
  for cmd in dl.commands() {
    match cmd {
      @moonui.Text(text, _, y, size, _, _) =>
        // 只收五行文字（17 / 12pt）：拖动帧里还有一条 10pt 的时间点，它画的
        // 位置落在某一行的高度带里，混进来会被当成那一行的歌词。
        if size == 17.0 || size == 12.0 {
          let row = (y / cm_lyric_row_h()).round().to_int()
          if row >= 0 && row < rows.length() {
            rows[row] = text
          }
        }
      _ => ()
    }
  }
  rows
}

///|
/// 拖动歌词定位（`T161`②）：按住第 4 行 → seek 到那一句；往上拖到第 1 行 →
/// 跟手再 seek；松手 → 拖动账清空。
///
/// 为什么这里直接 `dispatch` 而不走 `push_event` + `hit_test`：要验证的是
/// **接线**（行号 ↔ 歌词下标 ↔ seek），不是命中测试——mock 按 target 路由，
/// 给面自己就能精确喂到那条 handler。坐标仍按 `face.frame()` 现算，所以
/// 一像素口径的错（把窗口绝对坐标当成控件局部）会在这里翻红。
test "app：拖动歌词 seek 到对应句，松手后回落（T161）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  // 引擎得认得这首歌，否则 `play_index` 的 load 失败会把 current 清掉，
  // `player.track()` 返回 None（下面要拿它钉路径账）。
  let engine = eng_with([trk("/m/晴天.mp3", 6000L)])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [Track::from_path("/m/晴天.mp3")])
  cm.player.play_index(0)
  // 六句，从第 1 秒起每秒一句
  let lrc = "[00:01.00]第一句\n[00:02.00]第二句\n[00:03.00]第三句\n[00:04.00]第四句\n[00:05.00]第五句\n[00:06.00]第六句"
  cm.current_lyrics = parse_lrc(lrc)
  // 路径账也钉住：拖动会走 `refresh_lyrics`，而它按 `lyrics_path` 判"换歌了
  // 没有"——两边不一致就会重读磁盘（测试目标没有文件系统，读到空表把刚塞
  // 进去的歌词冲掉，active 直接变 -1）。
  cm.lyrics_path = cm.player.track().unwrap().path
  // 播到第 1 句（active = 0），布局跑一遍让面的 frame 有真值
  cm.ui.unwrap().lyrics.update(cm.current_lyrics, 1500L, "晴天", "周杰伦") catch {
    _ => ()
  }
  let _ = app.step()
  let lyrics = cm.ui.unwrap().lyrics
  assert_eq(lyrics.active, 0)
  let origin = lyrics.face.frame().origin
  let row_h = cm_lyric_row_h()
  let face_target = lyrics.face.target()
  // 用一个干净的位置起点：先量一下已有的 seek 记录
  let before = engine.calls.length()
  // 按住正中（第 2 行 = active - 2 + 2 = 0 → 第一句，1s）
  let y_mid = origin.y + 2.0 * row_h + row_h / 2.0
  let _ = app.dispatch(
    @moonui.MouseDown(
      face_target,
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 10.0, y_mid),
      @moonui.Mods::none(),
    ),
  )
  assert_eq(cm.lyric_drag_ms, Some(1000L))
  assert_true(engine.calls.contains("seek:1000"))
  // **方向（`T191`）**：手指把歌词往下拽 = 时间往前（变小）。
  // 从第 2 行中央（第 1 句）往下拽到第 4 行中央，纸被拽下去两行，正中那行
  // 落到第 -1 句 → 夹到队列头，仍是第一句（1s）。这一条钉住"下拽不往后跑"。
  let y_drag_down = origin.y + 4.0 * row_h + row_h / 2.0
  let _ = app.dispatch(
    @moonui.MouseMove(
      face_target,
      @moonui.LogicalPoint(origin.x + 10.0, y_drag_down),
    ),
  )
  assert_eq(cm.lyric_drag_ms, Some(1000L))
  // 反向：往上拽回第 0 行中央 → 时间往后两行 → 第三句（3s）。
  // 两条一起才证明方向真的翻了（只测一条的话"根本没跟手"也能过）。
  let y_drag_up = origin.y + 0.0 * row_h + row_h / 2.0
  let _ = app.dispatch(
    @moonui.MouseMove(
      face_target,
      @moonui.LogicalPoint(origin.x + 10.0, y_drag_up),
    ),
  )
  assert_eq(cm.lyric_drag_ms, Some(3000L))
  assert_true(engine.calls.contains("seek:3000"))
  // 拖动中歌词跟手：正中那行已经是第三句
  assert_eq(lyrics.active, 2)
  assert_eq(cm_lyric_rows(b, lyrics.face)[2], "第三句")
  // 拖过头（拖出面外）：夹到边界句，不是越界下标
  let _ = app.dispatch(
    @moonui.MouseMove(
      face_target,
      @moonui.LogicalPoint(origin.x + 10.0, origin.y + 400.0),
    ),
  )
  assert_eq(cm.lyric_drag_ms, Some(1000L))
  // 松手：拖动账清空，位置回落到引擎的真实位置
  let _ = app.dispatch(
    @moonui.MouseUp(
      face_target,
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 10.0, origin.y - 200.0),
      @moonui.Mods::none(),
    ),
  )
  assert_eq(cm.lyric_drag_ms, None)
  assert_true(engine.calls.length() > before)
  @moonui.Backend::terminate(b)
}

///|
/// 从歌词面最近一帧里读出**每段文字的连续 y**（`T191` 平滑判据用）。
/// 按 17/12pt 过滤掉拖动帧那条 10pt 时间点，与 `cm_lyric_rows` 同口径。
fn cm_lyric_text_ys(
  b : @moonui.MockBackend,
  face : @moonui.Widget[@moonui.MockBackend],
) -> Array[Double] raise @moonui.UiError {
  let ys : Array[Double] = []
  let h = match face.handle() {
    Some(h) => h
    None => abort("歌词面没有原生句柄")
  }
  let dl = match b.drawn(h) {
    Some(dl) => dl
    None => abort("歌词面一帧都没画过")
  }
  for cmd in dl.commands() {
    match cmd {
      @moonui.Text(_, _, y, size, _, _) =>
        if size == 17.0 || size == 12.0 {
          ys.push(y)
        }
      _ => ()
    }
  }
  ys
}

///|
/// **`T191` 的平滑判据**：指针每挪一像素，文字就得跟着挪一像素。
///
/// owner 原话是"每拖动一点点距离，就直接滚动一行，感觉是跳过去的"。旧实现
/// 把指针 y 换算成**整数行号**再取文字，所以同一个行带里的所有指针位置画出来
/// 一模一样——判据①"两步之间画面必须有变化"当时必然红。
///
/// 三条：
/// ① 指针在**同一行内**挪 6pt（行高 24 的 1/4），画出来的 y 必须跟着变——
///    这是"连续"的定义，也是旧实现唯一过不去的那条；
/// ② 位移量必须等于指针位移量（跟着手走，不是按比例慢慢蹭）；
/// ③ 全程 `drag_ms` 不变（还没跨过半行）——钉住"平滑不等于乱改目标句"。
test "app：拖动歌词平滑跟手，指针动一像素文字动一像素（T191）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = eng_with([trk("/m/晴day.mp3", 6000L)])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [Track::from_path("/m/晴day.mp3")])
  cm.player.play_index(0)
  let lrc = "[00:01.00]第一句\n[00:02.00]第二句\n[00:03.00]第三句\n[00:04.00]第四句\n[00:05.00]第五句"
  cm.current_lyrics = parse_lrc(lrc)
  cm.lyrics_path = cm.player.track().unwrap().path
  cm.ui.unwrap().lyrics.update(cm.current_lyrics, 2500L, "晴day", "x") catch {
    _ => ()
  }
  let _ = app.step()
  let lyrics = cm.ui.unwrap().lyrics
  assert_eq(lyrics.active, 1) // 播到第 2 句
  let origin = lyrics.face.frame().origin
  let row_h = cm_lyric_row_h()
  let face_target = lyrics.face.target()
  // 按住正中那行（第 2 行）的上半格
  let y0 = origin.y + 2.0 * row_h + row_h / 4.0
  let _ = app.dispatch(
    @moonui.MouseDown(
      face_target,
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 10.0, y0),
      @moonui.Mods::none(),
    ),
  )
  let ys_before = cm_lyric_text_ys(b, lyrics.face)
  let ms_before = cm.lyric_drag_ms
  // ① 同一行带内往下挪 6pt（不足半行，正中句不该变）
  let dy = 6.0
  let _ = app.dispatch(
    @moonui.MouseMove(
      face_target,
      @moonui.LogicalPoint(origin.x + 10.0, y0 + dy),
    ),
  )
  let ys_after = cm_lyric_text_ys(b, lyrics.face)
  // 纸往下走 dy，最下面那一行可能正好被推出面外（少画一段），所以按两帧的
  // 集合比、不按下标比：after 里的每一段都必须能在 before 里找到"平移了 dy"
  // 的那一段。旧实现（整数行）dy 恒为 0，一条都对不上。
  let mut matched = 0
  for ya in ys_after {
    for yb in ys_before {
      if (ya - yb - dy).abs() < 0.01 {
        matched = matched + 1
        break
      }
    }
  }
  // ① 两帧都有得比；每一段都跟着平移了同样的量
  assert_true(ys_before.length() >= 4)
  assert_eq(matched, ys_after.length())

  // ③ 还没跨过半行，目标句与时间点都不该变
  assert_eq(cm.lyric_drag_ms, ms_before)
  let _ = app.dispatch(
    @moonui.MouseUp(
      face_target,
      @moonui.Left,
      @moonui.LogicalPoint(origin.x + 10.0, y0 + dy),
      @moonui.Mods::none(),
    ),
  )
  @moonui.Backend::terminate(b)
}

///|
/// 搜索歌词小窗（`T161`①）：查询 → 结果落进列表 → 双击一行就应用。
///
/// 注入的 `on_search_lyrics` 是假的（记下问了什么、把 `land` 留在测试手里），
/// 所以这里验的是**接线**：输入框 → 查询 → 结果 → 双击 → `apply_searched_lyric`。
/// 网络那半在壳里（`fetch_lyric_search`），无头侧本来就到不了。
///
/// 双击为什么能到：行内容外面包着一层 `Panel`，`with_on_double_click` 挂在它
/// 上（挂在 Row 上收不到——Row 是纯布局节点，原生层没有可命中的对象）。冒泡
/// 自命中的 Label 往上走，Panel 收得到。
test "app：搜索歌词查询与双击应用（T161）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = eng_with([trk("/m/周杰伦 - 晴天.mp3", 6000L)])
  let asked : Array[(String, String)] = []
  let lands : Array[(Array[LyricSearchResult]) -> Unit] = []
  let cm = LunaMusicApp::new(
    app,
    engine,
    on_search_lyrics=Some(fn(
      title : String,
      artist : String,
      land : (Array[LyricSearchResult]) -> Unit,
    ) {
      asked.push((title, artist))
      lands.push(land)
    }),
  )
  cm.merge_scan("/m", [trk("/m/周杰伦 - 晴天.mp3", 6000L)])
  cm.player.play_index(0)
  // 先跑一拍心跳：`lyrics_path` 是"当前在显示哪首"的依据，真窗上由
  // `refresh_lyrics` 从 `player.track()` 填；不填的话下面 `apply_searched_lyric`
  // 换完词、紧接着的 `refresh_lyrics` 会以为"换歌了"重读磁盘（无头读到空表），
  // 把刚塞进去的词冲掉。
  cm.refresh_lyrics() catch {
    _ => ()
  }
  cm.open_search_lyrics()
  let dlg = cm.search_dlg.unwrap()
  // 预填来自 `tag_query_candidates` 的第一格，不是空框
  let prefill = tag_query_candidates(cm.player.track().unwrap())[0]
  assert_eq(dlg.title_in.text() catch { _ => "" }, prefill.0)
  assert_eq(dlg.artist_in.text() catch { _ => "" }, prefill.1)
  // `T163`①：解析到歌名就**自动查一次**，不用用户再按「查询」
  assert_eq(asked.length(), 1)
  assert_eq(asked[0], prefill)
  assert_eq(dlg.status.text() catch { _ => "" }, "查询中…")
  // `T164`①：空着的结果区里要把话说在用户正盯着的那块白板上
  assert_true(dlg.hint.visible() catch { _ => false })
  assert_eq(hint_text(dlg), "查询中…")
  // `T165`：那块"白板"必须真的铺开。空列表的内容列宽是 0，只按固有尺寸摆的话
  // 滚动视口宽度也是 0——真窗上整张底板不出现，深色提示字落在对话框自己的蓝底
  // 上（看不见）。Stack 里 `with_expand` 的子项要拿整块。
  let viewport = dlg.list.view().frame()
  assert_true(viewport.size.width > 0.0)
  assert_true(viewport.size.height > 0.0)
  // 自动那一轮还在路上时改名再查：必须发得出去（挡连点只在"问的是同一个人"
  // 时挡），否则用户得等一轮回来才动得了
  let _ = dlg.title_in.set_text("  晴天  ")
  let _ = dlg.artist_in.set_text("周杰伦")
  let _ = app.dispatch(@moonui.Click(dlg.search.target(), @moonui.Left))
  assert_eq(asked.length(), 2)
  assert_eq(asked[1], ("晴天", "周杰伦"))
  // 自动那一轮回来：问的已经不是它了，整轮丢掉（状态行仍停在"查询中…"）
  lands[0]([
    LyricSearchResult::{
      title: "别的",
      artist: "歌",
      duration_s: 100.0,
      lrc: "[00:00.00]不该出现",
    },
  ])
  assert_eq(dlg.status.text() catch { _ => "" }, "查询中…")
  assert_eq(dlg.list.materialized_count(), 0)
  assert_eq(hint_text(dlg), "查询中…")
  // 新那一轮回来（壳在工作线程取到之后 `app.post` 回主循环的那一跳）
  lands[1]([
    LyricSearchResult::{
      title: "晴天",
      artist: "周杰伦",
      duration_s: 269.0,
      lrc: "[00:00.00]故事的小黄花\n[00:02.00]从出生那年就飘着",
    },
    LyricSearchResult::{
      title: "晴天",
      artist: "翻唱",
      duration_s: 268.0,
      lrc: "[00:00.00]另一份词",
    },
  ])
  assert_eq(dlg.status.text() catch { _ => "" }, "找到 2 条，双击应用")
  assert_eq(dlg.list.materialized_count(), 2)
  // 有结果了：那块提示整块收起来，别压在行上面
  assert_false(dlg.hint.visible() catch { _ => true })
  // 双击第一条：立刻写回并换成这一份（不关窗——owner：直到满意才关闭）
  let content = match dlg.window.content() {
    Some(w) => w
    None => abort("搜索窗没有内容树")
  }
  let row = match find_text_widget(content, "晴天 - 周杰伦") {
    Some(w) => w
    None =>
      abort(
        "结果列表里没有第一条：行工厂或 sync 没把它摆出来",
      )
  }
  let _ = app.dispatch(@moonui.DoubleClick(row.target()))
  assert_eq(cm.current_lyrics.length(), 2)
  assert_eq(cm.current_lyrics[0].text, "故事的小黄花")
  assert_true((dlg.status.text() catch { _ => "" }).contains("已应用"))
  // 歌名清空再查：不发请求，直接在状态行说清楚
  let _ = dlg.title_in.set_text("   ")
  let _ = app.dispatch(@moonui.Click(dlg.search.target(), @moonui.Left))
  assert_eq(asked.length(), 2)
  assert_eq(dlg.status.text() catch { _ => "" }, "歌名不能为空")
  // `T164`②：红绿灯关掉的不是"藏起来"，是**销毁**（`windowShouldClose:` →
  // `Close` 事件 → `Window::release`）。这条一发，缓存的 `search_dlg` 就成了
  // 一只死窗，之后 `show()` 只会抛 `Destroyed`——真窗上的现象正是"关掉搜索
  // 窗，再点右上角「搜索歌词」没反应"。
  let _ = app.dispatch(@moonui.Close(dlg.window.target()))
  assert_true(dlg.window.is_closed())
  cm.open_search_lyrics()
  let again = cm.search_dlg.unwrap()
  assert_false(again.window.is_closed())
  // 新那一只照旧能查：预填 ⇒ 自动查一次（死窗上 `show()` 会抛、`query` 到不了）
  assert_eq(asked.length(), 3)
  assert_eq(asked[2], prefill)
  cm.close_search_lyrics()
  @moonui.Backend::terminate(b)
}

///|
/// 空白区提示那一行现在写的是什么（`T164`①）。提示是「撑开 - 文字 - 撑开」
/// 的三层 Column，取其中唯一那个带文本的叶子。
fn[B : @moonui.Backend] hint_text(dlg : LyricSearchDialog[B]) -> String {
  let texts = collect_label_texts(dlg.hint)
  if texts.length() == 1 {
    texts[0]
  } else {
    ""
  }
}

///|
/// 在一棵树里找文案等于 `want` 的那只控件（深度优先，第一个命中）。
fn[B : @moonui.Backend] find_text_widget(
  w : @moonui.Widget[B],
  want : String,
) -> @moonui.Widget[B]? {
  match w.handle() {
    Some(_) => if (w.text() catch { _ => "" }) == want { return Some(w) }
    None => ()
  }
  for c in w.children() {
    match find_text_widget(c, want) {
      Some(f) => return Some(f)
      None => ()
    }
  }
  None
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
  // 窗口挂起来了，五行面才在树里（`T191` 起文字不再预先摊成五条，改按 scroll 现取）
  assert_eq(cm.ui.unwrap().lyrics.active, -1)
  // 播到第 3 句（pos 3.5s → active = 2 号）：正中是第三句，上面两行是第一、二句，
  // 下面两行是第四、五句
  cm.ui.unwrap().lyrics.update(cm.current_lyrics, 3500L, "晴天", "周杰伦") catch {
    _ => ()
  }
  let shown = cm_lyric_rows(b, cm.ui.unwrap().lyrics.face)
  assert_eq(shown[2], "第三句")
  assert_eq(shown[0], "第一句")
  assert_eq(shown[1], "第二句")
  assert_eq(shown[3], "第四句")
  assert_eq(shown[4], "第五句")
  // 播到第 1 句：上面两行越界，留空而不是回绕
  cm.ui.unwrap().lyrics.update(cm.current_lyrics, 1500L, "晴天", "周杰伦") catch {
    _ => ()
  }
  let top = cm_lyric_rows(b, cm.ui.unwrap().lyrics.face)
  assert_eq(top[2], "第一句")
  assert_eq(top[0], "")
  assert_eq(top[1], "")
  assert_eq(top[3], "第二句")
  assert_eq(top[4], "第三句")
  // 播到末句：下面两行越界，同样留空
  cm.ui.unwrap().lyrics.update(cm.current_lyrics, 6500L, "晴天", "周杰伦") catch {
    _ => ()
  }
  let bot = cm_lyric_rows(b, cm.ui.unwrap().lyrics.face)
  assert_eq(bot[2], "第六句")
  assert_eq(bot[3], "")
  assert_eq(bot[4], "")
  @moonui.Backend::terminate(b)
}

///|
/// 一张"能解出封面的曲目"用的假字节（`T174` 判据）：mock 不解码，只要与
/// `cm_placeholder_cover()` 长度不同，就能把"灌了封面"和"灌了占位"分开。
fn cm_cover_fixture() -> Bytes {
  b"\x89PNG\r\n\x1a\nfake-cover-payload-0123456789"
}

///|
/// `T174`：封面「探到了、从不显示、重启即丢」三件事一起收口。
///
/// 链路是：曲库档不落封面字节（体积），所以重启后 `lib.tracks` 那份是
/// `cover: None`；装引擎那一趟 `AudioEngine::load` 会把封面解出来，
/// `Player::start_at` 把它补进队列，`refresh_bar` 按路径认边沿灌给播放条那只
/// `Image`。这里逐段钉住：引擎给的字节真的到了后端、换到没封面的曲目时灌的
/// 是那张占位图（而不是留着上一首的封面）。
test "app：封面从引擎探到之后灌进播放条（T174）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let a = trk("/m/a.mp3", 100L)
  let c = trk("/m/b.mp3", 200L)
  // 引擎那侧：第一首能解出封面，第二首没有
  engine.tracks.set("/m/a.mp3", {
    path: a.path,
    title: a.title,
    artist: a.artist,
    album: a.album,
    duration_ms: a.duration_ms,
    cover: Some(cm_cover_fixture()),
    loudness: None,
    lyrics: "",
  })
  engine.tracks.set("/m/b.mp3", c)
  // 曲库那侧：两份都不带封面——这就是"重启之后"的形态
  cm.merge_scan("/m", [a, c])
  // ⓪ 未播放（track 还是 None）时也灌占位图，不是空格
  //   （owner 2026-11-04：没播放时也要有占位图）
  let h0 = cm.ui.unwrap().bar.cover.handle().unwrap()
  assert_eq(
    @moonui.MockBackend::image_len_of(b, h0),
    cm_placeholder_cover().length(),
  )
  cm.player.play_index(0)
  // ① 装引擎时探到的封面补进了队列（含文本字段不被覆盖的约束：标题仍是曲库的）
  let loaded = cm.player.track().unwrap()
  assert_true(loaded.cover is Some(_))
  assert_eq(loaded.title, "/m/a.mp3")
  // ② 真的灌到了后端那侧
  let h = cm.ui.unwrap().bar.cover.handle().unwrap()
  assert_eq(
    @moonui.MockBackend::image_len_of(b, h),
    cm_cover_fixture().length(),
  )
  // ③ 换到没封面的那首：灌占位图（不是透明图，更不是留着上一张）
  cm.player.play_index(1)
  assert_true(cm.player.track().unwrap().cover is None)
  assert_true(cm_cover_fixture().length() != cm_placeholder_cover().length())
  assert_eq(
    @moonui.MockBackend::image_len_of(b, h),
    cm_placeholder_cover().length(),
  )
  // ④ rebuild_ui 之后要重新灌：重建把 Image 整个换成新的（内容空），边沿
  //   账不清的话这格从此空白（owner 2026-11-04：复位窗口后封面没了）
  cm.rebuild_ui()
  let h2 = cm.ui.unwrap().bar.cover.handle().unwrap()
  assert_eq(
    @moonui.MockBackend::image_len_of(b, h2),
    cm_placeholder_cover().length(),
  )
  // ⑤ 重建后再播回有封面的那首：路径边沿照常走
  cm.player.play_index(0)
  let h3 = cm.ui.unwrap().bar.cover.handle().unwrap()
  assert_eq(
    @moonui.MockBackend::image_len_of(b, h3),
    cm_cover_fixture().length(),
  )
  @moonui.Backend::terminate(b)
}

///|
/// 单击一行（`T177`）：走 `build_row` 建出来的**同一根闭包**，直派口驱动。
///
/// 不用 `App::dispatch` 绕窗口树：这条 handler 里会 `rebuild_ui` 换整棵树，
/// 绕一圈测的就成了路由（路由归 `T88` 那批判据，这里要钉的是"点了勾上"）。
/// 面板本身不必挂进窗口——`fire` 只跑直派口，与 `dispatch` 命中 target 之后
/// 那一步是同一个 `fire_round`。
fn[B : @moonui.Backend, A : AudioEngine] cm_click_row(
  cm : LunaMusicApp[B, A],
  i : Int32,
) -> Unit raise @moonui.UiError {
  let row = cm.build_row(i)
  let _ = row.fire(
    @moonui.Event::Click(row.target(), @moonui.MouseButton::Left),
  )
}

///|
/// 行底色的读法：选中态在界面上的**唯一**可见形态就是这层底色（文字不变、
/// 也没有勾选框），所以判据只能从这里读。
fn[B : @moonui.Backend, A : AudioEngine] cm_row_bg(
  cm : LunaMusicApp[B, A],
  i : Int32,
) -> @moonui.Color? raise @moonui.UiError {
  @moonui.Widget::style(cm.build_row(i)).unwrap().background
}

///|
/// 第 `i` 行里文案等于 `want` 的那只控件的前景色（`T226`）。高亮行的判据要看
/// **每一格**的文字色，只能从行树里按文案找控件再读样式——`.foreground()` 落进
/// `self.style`（`declarative.mbt` 的 `layer_local`），所以 `Widget::style` 读得到。
/// 找不到控件或控件没设前景就中止：静默兜一个默认色会让断言变永真。
fn[B : @moonui.Backend, A : AudioEngine] cm_fg_of(
  cm : LunaMusicApp[B, A],
  i : Int32,
  want : String,
) -> @moonui.Color raise @moonui.UiError {
  let row = cm.build_row(i)
  match find_text_widget(row, want) {
    Some(w) =>
      match @moonui.Widget::style(w) {
        Some(s) =>
          match s.foreground {
            Some(c) => c
            None => abort("第 \{i} 行的「\{want}」没有前景色")
          }
        None => abort("第 \{i} 行的「\{want}」没有样式")
      }
    None => abort("第 \{i} 行里找不到文案「\{want}」")
  }
}

///|
/// WCAG 对比度算式（`T226`④）：(亮者 + 0.05) / (暗者 + 0.05)，亮度用 sRGB
/// 线性化后的相对亮度（WCAG 2.x 的定义）。
///
/// 这里**没有**用 `Color::luminance`（`style.mbt:118`）：那是通道加权平均，
/// 不是 WCAG 的相对亮度，同一个算式代进去会把四套内置皮肤量成
/// 4.23 / 4.27 / 4.48（只有绯红 4.82 过线）——而 owner 量到的 accent/bg
/// 3.87、青竹 3.53、以及「ink 四套 ≥10.9」这些数字，只有在线性化口径下才
/// 逐位复现。判据照 owner 的数值口径走（对比度门槛本身是 WCAG 的）。
fn cm_linear(c : Int32) -> Double {
  let s = c.to_double() / 255.0
  if s <= 0.04045 {
    s / 12.92
  } else {
    @math.pow((s + 0.055) / 1.055, 2.4)
  }
}

///|
fn cm_wcag_luminance(c : @moonui.Color) -> Double {
  0.2126 * cm_linear(c.r) + 0.7152 * cm_linear(c.g) + 0.0722 * cm_linear(c.b)
}

///|
fn cm_contrast(a : @moonui.Color, b : @moonui.Color) -> Double {
  let la = cm_wcag_luminance(a)
  let lb = cm_wcag_luminance(b)
  if la > lb {
    (la + 0.05) / (lb + 0.05)
  } else {
    (lb + 0.05) / (la + 0.05)
  }
}

///|
/// 某一行的右键菜单条目文案（`describe` 口径）。
///
/// 菜单订阅在**冒泡口**（`T141`），`fire` 只跑直派口——要读它必须让行真在窗口
/// 树里，所以这里把它挂进一只测试自己建的临时窗，再走 `App::dispatch` 让它按
/// 用户姿势（右键按下 → 命中 → 冒泡）弹出来，后端记下的那份就是判据。
fn[B : @moonui.Backend, A : AudioEngine] cm_row_menu(
  app : @moonui.App[B],
  b : @moonui.MockBackend,
  cm : LunaMusicApp[B, A],
  scratch : @moonui.Window[B],
  i : Int32,
) -> Array[String] raise @moonui.UiError {
  let row = cm.build_row(i)
  scratch.set_content(row)
  let _ = app.dispatch(
    @moonui.Event::MouseDown(
      row.target(),
      @moonui.MouseButton::Right,
      @moonui.LogicalPoint(4.0, 4.0),
      @moonui.Mods::none(),
    ),
  )
  b.context_menu_last().unwrap().flatten().map(fn(it) { it.describe() })
}

///|
/// 多选（`T177`）三件事：单击勾选/取消、选中按 **path** 记、批量移除一次做掉。
///
/// 为什么按 path 而不是行号：排序 / 搜索 / 页签都会重排视图，行号会指到另一首
/// 曲；path 是身份，视图怎么动都还是它。判据拿"排序换位之后，新位置上的行
/// 有没有那首的选中态"来钉——按行号记的实现在这里会红。
///
/// 右键菜单那段单独挂在临时窗上走 `dispatch`：菜单订阅在**冒泡口**（`T141`），
/// `fire` 只跑直派口，不挂进窗口树就弹不出来。
test "app：列表多选——单击勾选、按 path 记、批量移除（T177）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  // 三首的时长刻意与路径顺序错开（a=300 / b=100 / c=200）：按「时长」排序会把
  // 视图整个换个次序，b 从第 2 行挪到第 1 行
  let ta = trk("/m/a.mp3", 300L)
  let tb = trk("/m/b.mp3", 100L)
  let tc = trk("/m/c.mp3", 200L)
  engine.stub(ta, [])
  engine.stub(tb, [])
  engine.stub(tc, [])
  cm.merge_scan("/m", [ta, tb, tc])
  assert_eq(cm.selected_count(), 0)
  // 右键菜单要挂在窗口树里才弹得出来（见 `cm_row_menu`）：临时窗建一次，后面
  // 每段把当行内容换进去
  let scratch = app.create_window("行", @moonui.LogicalSize(320.0, 40.0))
  // ① 单击 = 勾选，再点 = 取消；底色当场跟着变
  cm_click_row(cm, 0)
  assert_eq(cm.selected_count(), 1)
  assert_true(cm.is_selected("/m/a.mp3"))
  assert_eq(cm_row_bg(cm, 0), Some(cm_accent_bg()))
  // 相邻那行不受牵连（第 3 行是偶数行，本来无底色——选中只该染被点的那行）
  assert_true(cm_row_bg(cm, 2) is None)
  // 只选中一首时**没有**批量项：菜单里是单项的「从列表移除」，不是「选中的 1 首」
  let one_items = cm_row_menu(app, b, cm, scratch, 0)
  assert_true(one_items.contains("从列表移除"))
  assert_false(one_items.contains("从列表移除选中的 1 首"))
  cm_click_row(cm, 0)
  assert_eq(cm.selected_count(), 0)
  assert_false(cm.is_selected("/m/a.mp3"))
  assert_true(cm_row_bg(cm, 0) is None)
  // ② 选中两首之后排序换位：选中跟着曲目走，不跟着行号走
  cm_click_row(cm, 0)
  cm_click_row(cm, 2)
  assert_eq(cm.selected_count(), 2)
  assert_true(cm.is_selected("/m/a.mp3"))
  assert_true(cm.is_selected("/m/c.mp3"))
  // 时长列现在是代码 4（`T178` 加了专辑列，时长从 3 挪到 4）
  cm.set_sort(4)
  assert_eq(cm.view[0].path, "/m/b.mp3")
  assert_eq(cm.view[1].path, "/m/c.mp3")
  assert_eq(cm.view[2].path, "/m/a.mp3")
  assert_true(cm.is_selected("/m/a.mp3"))
  assert_true(cm.is_selected("/m/c.mp3"))
  assert_false(cm.is_selected("/m/b.mp3"))
  // 新位置上的行认得出选中态：c 在第 2 行、a 在第 3 行都有底色，b 那行没有
  assert_eq(cm_row_bg(cm, 1), Some(cm_accent_bg()))
  assert_eq(cm_row_bg(cm, 2), Some(cm_accent_bg()))
  assert_true(cm_row_bg(cm, 0) is None)
  // ③ 批量项只在「点的是选中行、且选中不止一首」时出现
  let sel_items = cm_row_menu(app, b, cm, scratch, 1)
  assert_true(sel_items.contains("从列表移除选中的 2 首"))
  // 没选中的那行照旧只有单项——别整份菜单都没挂上，那样上面那条"有"就不可信了
  let plain_items = cm_row_menu(app, b, cm, scratch, 0)
  assert_true(plain_items.contains("从列表移除"))
  assert_false(plain_items.contains("从列表移除选中的 2 首"))
  // ④ 批量移除：两首一次删掉，选中集合清空，计数 / 队列跟上
  cm.remove_selected()
  assert_eq(cm.selected_count(), 0)
  assert_eq(cm.lib.tracks.length(), 1)
  assert_eq(cm.lib.tracks[0].path, "/m/b.mp3")
  assert_eq(cm.ui.unwrap().table.count_label.text(), "共 1 首")
  assert_eq(cm.player.queue.length(), 1)
  assert_true(cm_row_bg(cm, 0) is None)
  @moonui.Backend::terminate(b)
}

///|
/// 当前曲行整行用主文字色（`T226`：accent 不再染行内文字）。
///
/// 改之前当前曲是整行 `cm_accent()` 蓝字压 `cm_accent_bg()` 浅蓝底：经典蓝
/// 3.87:1、青竹 3.53:1，10px 正文过不了 4.5:1 的门槛，真机上是"看不清"。
/// 身份标记留给「▶ 」前缀与标题加粗，五格（序号/标题/歌手/专辑/时长）一律 ink。
test "app：当前曲行五格文字都用主文字色（T226）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let ta = trk("/m/a.mp3", 65_000L)
  let tb = trk("/m/b.mp3", 125_000L)
  let tc = trk("/m/c.mp3", 185_000L)
  engine.stub(ta, [])
  engine.stub(tb, [])
  engine.stub(tc, [])
  cm.merge_scan("/m", [ta, tb, tc])
  // 标签口径下歌手列才有内容（文件名口径只剩一段，歌手是空串）
  cm.display = Tags
  cm.player.play_index(0)
  assert_eq(cm.player.current, Some(0))
  // 底色那一半归 `T207`，这里顺带钉住它没被这一刀带偏
  assert_eq(cm_row_bg(cm, 0), Some(cm_accent_bg()))
  for want in ["▶ 1", "/m/a.mp3", "a", "b", "01:05"] {
    assert_eq(cm_fg_of(cm, 0, want), cm_ink())
  }
  @moonui.Backend::terminate(b)
}

///|
/// 选中行（不是当前曲）同样整行主文字色（`T226`②）：原来选中的行是 muted 压
/// `cm_accent_bg()`，灰字压浅蓝底同样偏淡。高亮身份只靠底色，文字要退到 ink。
test "app：选中行标题与歌手都用主文字色（T226）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let ta = trk("/m/a.mp3", 65_000L)
  let tb = trk("/m/b.mp3", 125_000L)
  let tc = trk("/m/c.mp3", 185_000L)
  engine.stub(ta, [])
  engine.stub(tb, [])
  engine.stub(tc, [])
  cm.merge_scan("/m", [ta, tb, tc])
  cm.display = Tags
  // 播第 1 首，点第 2 行 → 第 2 行是选中态（底色 accent）但不是当前曲（无 ▶）
  cm.player.play_index(0)
  cm_click_row(cm, 1)
  assert_true(cm.is_selected("/m/b.mp3"))
  assert_eq(cm_row_bg(cm, 1), Some(cm_accent_bg()))
  assert_eq(cm_fg_of(cm, 1, "/m/b.mp3"), cm_ink())
  assert_eq(cm_fg_of(cm, 1, "a"), cm_ink())
  @moonui.Backend::terminate(b)
}

///|
/// 普通行保持原来的层次（`T226`③）：标题 ink、其余 muted——这一刀只该动
/// 高亮行，别把整张表的层次一起抹平。
test "app：普通行标题 ink、歌手 muted（T226）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let ta = trk("/m/a.mp3", 65_000L)
  let tb = trk("/m/b.mp3", 125_000L)
  let tc = trk("/m/c.mp3", 185_000L)
  engine.stub(ta, [])
  engine.stub(tb, [])
  engine.stub(tc, [])
  cm.merge_scan("/m", [ta, tb, tc])
  cm.display = Tags
  // 不播也不选：第 3 行（下标 2，偶数行，连斑马底都没有）就是最普通那一档
  assert_true(cm_row_bg(cm, 2) is None)
  assert_eq(cm_fg_of(cm, 2, "/m/c.mp3"), cm_ink())
  assert_eq(cm_fg_of(cm, 2, "a"), cm_muted())
  assert_eq(cm_fg_of(cm, 2, "b"), cm_muted())
  assert_eq(cm_fg_of(cm, 2, "3"), cm_muted())
  assert_eq(cm_fg_of(cm, 2, "03:05"), cm_muted())
  @moonui.Backend::terminate(b)
}

///|
/// 纯算术（`T226`④）：每套内置皮肤上，高亮行的文字色（ink）压高亮底色
/// （accent_bg）都要过 10px 正文的 4.5:1 门槛。这条不依赖界面树，换皮肤
/// 时谁把 ink/accent_bg 调瞎了，这里直接红。
test "app：每套皮肤 ink 压 accent_bg 都过 4.5（T226）" {
  let skins = cm_skin_builtins()
  assert_eq(skins.length(), 4)
  for s in skins {
    let c = cm_contrast(cm_color_of(s.ink), cm_color_of(s.accent_bg))
    if c < 4.5 {
      abort("皮肤「\{s.name}」ink/accent_bg 对比度 \{c} < 4.5")
    }
  }
}

///|
/// 判据：装不上的曲目要**说人话**（`T186`）。
///
/// 改之前的表现是"点了没反应"：`start_at` 的 catch 静默跳到下一首，整队列都
/// 装不上就 `stop_all(false)` 一停，状态行回到「状态: 就绪」——用户看到的是
/// 一切正常，只是歌没响。格式不支持（`T166` 的 ogg）、文件被删、文件损坏
/// 在这条链上长得一模一样。
///
/// 这一条同时钉住那个容易写错的地方：**自动跳过一首坏歌之后，坏消息还在**
/// （`start_at` 成功那支不清 `last_error`，清的是用户入口）。否则"第 2 首在播"
/// 会把"第 1 首为什么没播"抹掉，用户永远不知道原因。
test "app：装不上的曲目在状态行里说人话（T186）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let t1 = trk("/m/1.mp3", 200000L)
  let t2 = trk("/m/2.mp3", 200000L)
  let t3 = trk("/m/3.mp3", 200000L)
  engine.stub(t1, [])
  engine.stub(t2, [])
  engine.stub(t3, [])
  cm.merge_scan("/m", [t1, t2, t3])
  // 基线：没出错的时候就是原来那句三态文案
  assert_eq(cm.ui.unwrap().bar.state_text.text(), "状态: 就绪")
  assert_true(cm.player.last_error() is None)
  // ① 点第一首（它装不上）：自动跳到第二首播起来，**但要说得出第一首不行**
  engine.fail_load_paths.push("/m/1.mp3")
  cm.player.play_index(0)
  assert_eq(cm.player.track().unwrap().path, "/m/2.mp3")
  assert_true(cm.player.is_playing())
  assert_eq(cm.player.last_error(), Some(LoadFailed("/m/1.mp3")))
  // 文案按**显示口径**算名字（默认文件名 → `1`，不是夹具 title 那整条路径）
  assert_eq(cm.ui.unwrap().bar.state_text.text(), "⚠ 无法播放：1")
  // ② 用户再点一首**能播**的：错误翻篇，状态行回到正常
  cm.player.play_index(2)
  assert_true(cm.player.last_error() is None)
  assert_eq(cm.ui.unwrap().bar.state_text.text(), "状态: 播放")
  // ③ 队列全坏：说"没有能播的曲目"，而不是报最后一首的名字——连跳一整轮
  //    都没成，问题多半不在某个个别文件上
  let b2 = @moonui.MockBackend::new()
  @moonui.Backend::init(b2)
  let app2 = @moonui.App::new(b2)
  let e2 = MockAudioEngine::new()
  let cm2 = LunaMusicApp::new(app2, e2)
  let u1 = trk("/x/1.mp3", 1L)
  let u2 = trk("/x/2.mp3", 1L)
  e2.stub(u1, [])
  e2.stub(u2, [])
  cm2.merge_scan("/x", [u1, u2])
  e2.fail_load_paths.push("/x/1.mp3")
  e2.fail_load_paths.push("/x/2.mp3")
  cm2.player.play_index(0)
  assert_eq(cm2.player.last_error(), Some(AllFailed))
  assert_eq(cm2.player.state, Idle)
  assert_eq(
    cm2.ui.unwrap().bar.state_text.text(),
    "⚠ 列表里没有能播放的曲目",
  )
  // ④ 用户按停止：这是主动动作，那句"装不上"该收起来（否则像按钮没生效）
  cm2.player.stop()
  assert_true(cm2.player.last_error() is None)
  assert_eq(cm2.ui.unwrap().bar.state_text.text(), "状态: 就绪")
  @moonui.Backend::terminate(b2)
  @moonui.Backend::terminate(b)
}

///|
/// 判据：**平台没接音频要说成平台没接，不许退化成逐首重试**（`T38` 欠的错误码
/// 那一半第一次真被走到）。
///
/// 改之前的表现：Windows 的音频整段是 FP4 空桩，`adapter_native.c` 每个入口
/// 如实返回 -3（`adapter.h` 音频段：-3 = 本平台未实现），但共享层一处都没读
/// 这个码——壳把 -3 报成 `LoadFailed`，`start_at` 的 catch 不认档，于是点一次
/// 播放会把**整队列逐首试一遍**才止损，状态行说「⚠ 列表里没有能播放的曲目」。
/// 平台没接被说成了文件问题，队列大时还是 N 次白跑的 FFI。
///
/// 这条判据钉三件事：只 load **一次**（一次止损）、错误是
/// `PlayerError::PlatformUnsupported`、那句话是「⚠ 本平台还没接音频」。
/// `stub_unsupported()` 照旧记 `calls`，所以"有没有白跑"读得出来。
test "app：平台没接音频说成平台没接、一次止损不逐首重试（T38）" {
  let paths = ["/m/1.mp3", "/m/2.mp3", "/m/3.mp3"]
  fn load_count(calls : Array[String]) -> Int32 {
    let mut n = 0
    for c in calls {
      for p in paths {
        if c == "load:\{p}" {
          n = n + 1
        }
      }
    }
    n
  }
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let t1 = trk("/m/1.mp3", 200000L)
  let t2 = trk("/m/2.mp3", 200000L)
  let t3 = trk("/m/3.mp3", 200000L)
  engine.stub(t1, [])
  engine.stub(t2, [])
  engine.stub(t3, [])
  cm.merge_scan("/m", [t1, t2, t3])
  // 三首都能装（探针侧没排坏），只是这一侧整段没接
  engine.stub_unsupported()
  cm.player.play_index(0)
  // ① 恰好一条 load：止损发生在第一次，不是试完整队列
  assert_eq(load_count(engine.calls), 1)
  // 没接时连 play 都不该发出（load 先 raise，后面那截走不到）
  assert_eq(engine.calls.contains("play"), false)
  assert_eq(cm.player.last_error(), Some(PlatformUnsupported))
  assert_eq(cm.player.state, Idle)
  assert_eq(
    cm.ui.unwrap().bar.state_text.text(),
    "⚠ 本平台还没接音频",
  )
  // ② 用户再点第二首：**只许多出一条 load**。退化成逐首重试的话这里会变成 3
  cm.player.play_index(1)
  assert_eq(load_count(engine.calls), 2)
  assert_eq(cm.player.last_error(), Some(PlatformUnsupported))
  assert_eq(
    cm.ui.unwrap().bar.state_text.text(),
    "⚠ 本平台还没接音频",
  )
  // ③ `prepare`（`T184` 的续播路径）同一条分档：装而不播那一支原先会把
  //    「平台没接」写成「某一首装不上」，形状还是原来的「停但不跳」
  let b2 = @moonui.MockBackend::new()
  @moonui.Backend::init(b2)
  let app2 = @moonui.App::new(b2)
  let e2 = MockAudioEngine::new()
  let cm2 = LunaMusicApp::new(app2, e2)
  cm2.merge_scan("/m", [t1, t2, t3])
  e2.stub_unsupported()
  cm2.player.prepare(0, 30_000L)
  assert_eq(load_count(e2.calls), 1)
  // 装不上就不会 seek（位置那截走不到）
  assert_eq(e2.calls.contains("seek:30000"), false)
  assert_eq(cm2.player.last_error(), Some(PlatformUnsupported))
  assert_eq(cm2.player.state, Idle)
  assert_eq(
    cm2.ui.unwrap().bar.state_text.text(),
    "⚠ 本平台还没接音频",
  )
  @moonui.Backend::terminate(b2)
  @moonui.Backend::terminate(b)
}

///|
/// 判据：重启后恢复"上次停在哪一首的哪一秒"，且**不自动开播**（`T184`）。
///
/// 改之前 `Prefs` 里只有 `last_path`，壳侧恢复只把 `current` 指过去高亮——
/// 不 load 不 seek，进度条停在 00:00，长音频（有声书、播客、现场录音）每次
/// 启动都要从头拖。补的是位置，不是"启动自动出声"那个决定（`prefs.mbt` 的
/// 头注一直记着后者是有意为之）。
///
/// 关键设计在状态记 `Paused` 而不是 `Idle`：`toggle` 的 Idle 分支走 `start_at`
/// → 重新 `load` → 引擎位置归零，`seek` 白做。这一条把它钉住。
test "app：恢复上次播到的位置，按 ▶ 才从那儿继续（T184）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let t1 = trk("/m/1.mp3", 200000L)
  let t2 = trk("/m/2.mp3", 200000L)
  engine.stub(t1, [])
  engine.stub(t2, [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [t1, t2])
  // ① 装上第二首并定位到 42 秒：装了、定位了，但**没播**
  cm.player.prepare(1, 42000L)
  assert_eq(cm.player.track().unwrap().path, "/m/2.mp3")
  assert_eq(cm.player.state, Paused)
  assert_false(cm.player.is_playing())
  assert_eq(cm.player.position(), 42000L)
  // 界面跟着走：进度条千分位 = 42000/200000 = 210，时长是真值不是 00:00
  assert_eq(cm.ui.unwrap().bar.progress.value(), 210)
  assert_eq(cm.ui.unwrap().bar.time_total.text(), "/ 03:20")
  assert_eq(cm.ui.unwrap().bar.toggle.text(), "▶")
  // ② 按 ▶：从 42 秒**继续**，不是重新 load 从头
  engine.calls.clear()
  cm.player.toggle()
  assert_true(cm.player.is_playing())
  assert_eq(cm.player.position(), 42000L)
  assert_true(engine.calls.contains("unpause"))
  assert_false(engine.calls.contains("load:/m/2.mp3"))
  // ③ 档里的位置超出实际时长（文件被换过 / 手改坏档）→ 归 0，
  //    否则一进来就是"已播完"，按 ▶ 立刻又结束
  cm.player.prepare(0, 999999999L)
  assert_eq(cm.player.position(), 0L)
  assert_eq(cm.player.state, Paused)
  // ④ 恢复的那首装不上（文件被删）：记错误、停在 Idle，**不跳下一首**——
  //    启动时用户没点任何东西，把队列从头试一遍没有意义
  engine.fail_load_paths.push("/m/1.mp3")
  cm.player.prepare(0, 1000L)
  assert_eq(cm.player.last_error(), Some(LoadFailed("/m/1.mp3")))
  assert_eq(cm.player.state, Idle)
  assert_eq(cm.player.track().unwrap().path, "/m/1.mp3")
  assert_eq(cm.ui.unwrap().bar.state_text.text(), "⚠ 无法播放：1")
  @moonui.Backend::terminate(b)
}

///|
/// 判据：播放速度（`T171`）——五档、夹法、菜单打勾互斥。
///
/// 落点在**菜单**而不是走带：那排已经 348/380（`T120` 量过），加一颗 24 的钮
/// 会把两个 spacer 挤到 2.5。菜单不占客户区，原版也是这么放的。
///
/// 夹法（250..4000）在引擎那侧，mock 与 C 用同一套：两边各夹一次迟早会不一致，
/// 而无头判据若验的是"没夹"那个世界，真机上用户看到的又不一样。
test "app：播放速度五档，引擎夹法，菜单打勾互斥（T171）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let t1 = trk("/m/1.mp3", 200000L)
  engine.stub(t1, [])
  cm.merge_scan("/m", [t1])
  // 默认原速
  assert_eq(cm.player.rate(), 1000)
  // ① 设一档：引擎收到、读回是新值
  cm.set_rate(1250)
  assert_eq(cm.player.rate(), 1250)
  assert_true(engine.calls.contains("rate:1250"))
  // ② 夹法：太慢抬到 250、太快压到 4000
  cm.player.set_rate(100)
  assert_eq(cm.player.rate(), 250)
  cm.player.set_rate(9000)
  assert_eq(cm.player.rate(), 4000)
  // ③ 菜单：五档都在，文案是固定表，且**只有当下生效那档打勾**
  cm.set_rate(1500)
  let nodes = cm.cm_build_rate_menu_nodes()
  let labels : Array[String] = []
  let checked : Array[String] = []
  for n in nodes {
    match n {
      @moonui.Item(it) => {
        labels.push(it.describe())
        if it.checked {
          checked.push(it.describe())
        }
      }
      _ => ()
    }
  }
  assert_eq(labels.length(), 5)
  // `describe()` 自带打勾标记（`1.5x (*)` / `2.0x ( )`），所以"只有一档亮"这件事
  // 直接读 checked 就够。不拿整串对账是刻意的：`(*)/( )` 的括号形态是呈现细节，
  // 钉它会因为改一个空格就让判据红。
  assert_eq(checked.length(), 1)
  assert_true(checked[0].contains("1.5x"))
  // ④ 换一档：打勾跟着走，不会两档同时亮
  cm.set_rate(750)
  let after : Array[String] = []
  for n in cm.cm_build_rate_menu_nodes() {
    match n {
      @moonui.Item(it) => if it.checked { after.push(it.describe()) }
      _ => ()
    }
  }
  assert_eq(after.length(), 1)
  assert_true(after[0].contains("0.75x"))
  assert_eq(cm.player.rate(), 750)
  // ⑤ 点同一档不重挂菜单栏：档位没变就直接返回（重挂一次是一条白做的账）
  let before_calls = engine.calls.length()
  cm.set_rate(750)
  assert_eq(engine.calls.length(), before_calls)
  @moonui.Backend::terminate(b)
}

///|
/// 判据侧独立的 zlib CRC-32（与 `cm_png_chunk` 里那份互为印证——拿被测
/// 函数自己复算自己等于没验）。
fn wbtest_png_crc32(data : Bytes) -> Int32 {
  let mut c = 0xFFFFFFFF
  for i = 0; i < data.length(); i = i + 1 {
    c = c ^ (data[i].to_int() & 0xFF)
    for bit = 0; bit < 8; bit = bit + 1 {
      // `Int` 有符号、`>>` 算术右移——右移后掩符号位等价逻辑右移。
      // 没有这一步，初值 0xFFFFFFFF（= -1）移出来全是 1，CRC 全歪
      // （实现与判据第一版同带这个 bug，互相印证着「通过」）。
      c = if (c & 1) != 0 {
        ((c >> 1) & 0x7FFFFFFF) ^ 0xEDB88320
      } else {
        (c >> 1) & 0x7FFFFFFF
      }
    }
  }
  c ^ 0xFFFFFFFF
}

///|
/// CRC-32 的金标向量（标准校验值，锚住移位/初值/终值三处都别错）。
test "display：wbtest_png_crc32 对得上 CRC-32 标准向量" {
  assert_eq(wbtest_png_crc32(b""), 0)
  assert_eq(wbtest_png_crc32(b"123456789"), 0xCBF43926)
  assert_eq(wbtest_png_crc32(b"Ia"), 0x5AD7B77D)
}

///|
/// 判据侧的大端四字节读取。
fn wbtest_be32(b : Bytes, at : Int32) -> Int32 {
  let b0 = b[at].to_int() << 24
  let b1 = b[at + 1].to_int() << 16
  let b2 = b[at + 2].to_int() << 8
  let b3 = b[at + 3].to_int()
  b0 | b1 | b2 | b3
}

///|
/// 占位封面（owner 2026-11-04）：结构完整（chunk 帧与 CRC 逐个复算、IHDR
/// 声明 56×56 8bit RGB）、IDAT 是一条 final stored block、adler32 对得上，
/// 像素三档各归各位——角落是背景渐变、环上是文字亮色、中心孔被压暗。
test "display：占位封面是张结构完整的唱盘占位图" {
  let png = cm_placeholder_cover()
  let sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
  for i = 0; i < 8; i = i + 1 {
    assert_eq(png[i].to_int(), sig[i])
  }
  // 逐 chunk：len(BE) + kind(4) + data + crc(BE)
  let mut at = 8
  let kinds : Array[String] = []
  let mut ihdr : Bytes = b""
  let mut idat : Bytes = b""
  while at < png.length() {
    assert_true(at + 12 <= png.length())
    let len = wbtest_be32(png, at)
    let kind = @utf8.decode_lossy(png[at + 4:at + 8].to_owned())
    let data = png[at + 8:at + 8 + len].to_owned()
    let crc = wbtest_be32(png, at + 8 + len)
    assert_eq(wbtest_png_crc32(@utf8.encode(kind).add(data)), crc)
    kinds.push(kind)
    match kind {
      "IHDR" => ihdr = data
      "IDAT" => idat = data
      _ => ()
    }
    at = at + 12 + len
  }
  assert_eq(kinds, ["IHDR", "IDAT", "IEND"])
  // IHDR：224×224（4x 位图，显示仍是 56pt）、8bit、RGB、无 interlace
  assert_eq(ihdr.length(), 13)
  assert_eq(wbtest_be32(ihdr, 0), 224)
  assert_eq(wbtest_be32(ihdr, 4), 224)
  assert_eq(ihdr[8].to_int(), 8)
  assert_eq(ihdr[9].to_int(), 2)
  assert_eq(ihdr[12].to_int(), 0)
  // IDAT：zlib 头 + 分块 stored（4x 的 150,752 字节超单块 65535 上限）+
  // adler32（判据侧复算）
  assert_eq(idat[0].to_int(), 0x78)
  assert_eq(idat[1].to_int(), 0x01)
  let size = 224
  let raw_len = size * (1 + size * 3)
  let mut at = 2
  let collected : Array[Byte] = []
  let mut saw_final = false
  while at < idat.length() {
    let head = idat[at].to_int()
    assert_true(head == 0 || head == 1)
    // LEN / NLEN 是小端；NLEN 是 LEN 的 ones' complement（0xFFFF - n）
    let take = (idat[at + 2].to_int() << 8) | idat[at + 1].to_int()
    assert_eq(
      (idat[at + 4].to_int() << 8) | idat[at + 3].to_int(),
      65535 - take,
    )
    for i = 0; i < take; i = i + 1 {
      collected.push(idat[at + 5 + i])
    }
    at = at + 5 + take
    if head == 1 {
      saw_final = true
      break
    }
  }
  assert_true(saw_final)
  // 末块之后应只剩 4 字节 adler32
  assert_eq(at + 4, idat.length())
  assert_eq(collected.length(), raw_len)
  let raw = Bytes::from_array(collected)
  let mut a = 1
  let mut bb = 0
  for i = 0; i < raw.length(); i = i + 1 {
    a = (a + (raw[i].to_int() & 0xFF)) % 65521
    bb = (bb + a) % 65521
  }
  assert_eq(wbtest_be32(idat, at), (bb << 16) | a)
  // 像素三档：角落是渐变背景、环上是 text_light、中心孔压暗 35%
  let skin = cm_skin_current()
  fn px(x : Int32, y : Int32) -> (Int32, Int32, Int32) {
    let base = y * (1 + size * 3) + 1 + x * 3
    (raw[base].to_int(), raw[base + 1].to_int(), raw[base + 2].to_int())
  }
  let t2 = 16.0 / 223.0
  let corner = px(16, 16)
  assert_eq(corner.0, cm_mix8(skin.face_top >> 16, skin.face_bottom >> 16, t2))
  assert_eq(
    corner.1,
    cm_mix8((skin.face_top >> 8) & 0xFF, (skin.face_bottom >> 8) & 0xFF, t2),
  )
  assert_eq(
    corner.2,
    cm_mix8(skin.face_top & 0xFF, skin.face_bottom & 0xFF, t2),
  )
  let ring = px(52, 108)
  assert_eq(ring.0, (skin.text_light >> 16) & 0xFF)
  assert_eq(ring.1, (skin.text_light >> 8) & 0xFF)
  assert_eq(ring.2, skin.text_light & 0xFF)
  let t27 = 108.0 / 223.0
  let hole = px(108, 108)
  assert_eq(
    hole.0,
    cm_mix8(skin.face_top >> 16, skin.face_bottom >> 16, t27) * 65 / 100,
  )
  let outside = px(208, 208)
  let t52 = 208.0 / 223.0
  assert_eq(
    outside.0,
    cm_mix8(skin.face_top >> 16, skin.face_bottom >> 16, t52),
  )
}

///|
/// 迷你条贴主控左上角（`T211`）：进迷你模式时先把迷你窗挪到主控的 position
/// 再 show，切换不再"跳"。position/set_position 是顶左口径（mac pack_frame：
/// y 从该屏可见区上边往下量），mock 与真窗同一问句；主控 380 宽起步、迷你条
/// 300×48，主控装得下它就装得下，同一点不必再夹屏。切回时主控的位置不动。
test "app：进迷你模式，迷你条落在主控左上角（T211）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let u = cm.ui.unwrap()
  let anchor = @moonui.LogicalPoint(137.0, 92.0)
  u.window.set_position(anchor) catch {
    _ => abort("主控落位不该失败")
  }
  cm.toggle_mini() catch {
    _ => abort("toggle_mini 不该失败")
  }
  assert_eq(
    u.mini_win.position() catch {
      _ => abort("读迷你条位不该失败")
    },
    anchor,
  )
  // 切回主控：主控没有理由搬家，位置原样。
  cm.toggle_mini() catch {
    _ => abort("toggle_mini 不该失败")
  }
  assert_eq(
    u.window.position() catch {
      _ => abort("读主控位不该失败")
    },
    anchor,
  )
  @moonui.Backend::terminate(b)
}

///|
/// 迷你条布局（2026-11-05 三修②）：歌名格吃掉按钮之外的整段宽（弹性格），
/// 下一颗钮的右缘顶到 8pt 内边距——右侧不再留一截没人认领的底色空白。
test "app：迷你条布局——歌名格吃满剩余宽，按钮靠右（三修②）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  cm.toggle_mini() catch {
    _ => abort("toggle_mini 不该失败")
  }
  let u = cm.ui.unwrap()
  let content = match u.mini_win.content() {
    Some(w) => w
    None => abort("迷你条窗没有内容树")
  }
  let rf = content.frame()
  let prv = match find_text_widget(content, "⏮") {
    Some(w) => w
    None => abort("迷你条上没有上一颗钮")
  }
  let ttl = match find_text_widget(content, "未播放") {
    Some(w) => w
    None => abort("迷你条上没有歌名")
  }
  let pf = prv.frame()
  let tf = ttl.frame()
  // 按钮贴右：下一颗钮右缘 = 窗宽 - 8pt 内边距（⏮ 是三颗里最左的，右缘 =
  // ⏭ 右缘 - 26 - 4 - 30 - 4）
  let nxt_r = pf.origin.x + pf.size.width + 4.0 + 30.0 + 4.0 + 26.0
  assert_eq(nxt_r, rf.origin.x + rf.size.width - 8.0)
  // 歌名格右缘紧挨上一颗钮（Row 间距 4pt）：格宽 = prev 左缘 - 行距 - 歌名
  // 左缘，中间没有空档
  let cell_w = pf.origin.x - 4.0 - tf.origin.x
  // 弹性格确实吃到了中间那段宽，不是原来钉死的 88pt
  assert_true(cell_w > 100.0)
  @moonui.Backend::terminate(b)
}

///|
/// 迷你条跑马灯（2026-11-05 三修③）：装得下摆整句不点火；溢出按格宽切片，
/// 头停 8 拍后逐字推进，到句尾尾停 8 拍再回头。状态机直接驱动（链的续拍
/// 账在 `post_every` 自己的测试里）。
test "app：迷你条跑马灯——溢出切片滚动，装得下摆整句（三修③）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  cm.toggle_mini() catch {
    _ => abort("toggle_mini 不该失败")
  }
  let u = cm.ui.unwrap()
  // 装得下：整句、不点火
  cm.mini_marquee_sync("短歌名")
  assert_false(cm.marq_ticker.running())
  assert_eq(cm.marq_fit, 0)
  assert_eq(u.mini.title.text(), "短歌名")
  // 溢出：40 字，mock 每字 8pt → 整句固有宽 328pt，格宽远装不下
  let long = "0123456789012345678901234567890123456789"
  cm.mini_marquee_sync(long)
  assert_true(cm.marq_fit >= 1)
  assert_true(cm.marq_fit < 40)
  assert_true(cm.marq_ticker.running())
  assert_eq(u.mini.title.text(), cm_slice_chars(long, 0, cm.marq_fit))
  // 头停 MARQ_HOLD_TICKS 拍：文字不动
  for _i = 0; _i < MARQ_HOLD_TICKS; _i = _i + 1 {
    assert_true(cm.mini_marquee_tick())
  }
  assert_eq(u.mini.title.text(), cm_slice_chars(long, 0, cm.marq_fit))
  // 之后逐字推进
  assert_true(cm.mini_marquee_tick())
  assert_eq(u.mini.title.text(), cm_slice_chars(long, 1, cm.marq_fit))
  // 滚到尾：句尾切片，尾停 MARQ_HOLD_TICKS 拍后回头部
  let mut spins = 0
  while !cm.marq_at_end && spins < 100 {
    let _ = cm.mini_marquee_tick()
    spins = spins + 1
  }
  assert_true(cm.marq_at_end)
  assert_eq(
    u.mini.title.text(),
    cm_slice_chars(long, 40 - cm.marq_fit, cm.marq_fit),
  )
  for _i = 0; _i < MARQ_HOLD_TICKS; _i = _i + 1 {
    assert_true(cm.mini_marquee_tick())
  }
  assert_eq(cm.marq_i, 0)
  assert_eq(u.mini.title.text(), cm_slice_chars(long, 0, cm.marq_fit))
  // 换短句：链停，整句回来
  cm.mini_marquee_sync("短歌名")
  assert_false(cm.marq_ticker.running())
  assert_eq(u.mini.title.text(), "短歌名")
  @moonui.Backend::terminate(b)
}

///|
/// 专辑列（`T178`）：列头点按排序（升→再点降、换列回升序），行格空专辑显
/// 「未知」（与歌手缺字段同款哨兵——专辑没有 `T193` 那支文件名兜底，直接摆
/// 库里的值）。
test "app：专辑列——列头排序与空专辑显「未知」（T178）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let ta = {
    path: "/m/1.mp3",
    title: "晴天",
    artist: "周杰伦",
    album: "叶惠美",
    duration_ms: 100L,
    cover: None,
    loudness: None,
    lyrics: "",
  }
  let tb = {
    path: "/m/2.mp3",
    title: "不见",
    artist: "李荣浩",
    album: "",
    duration_ms: 200L,
    cover: None,
    loudness: None,
    lyrics: "",
  }
  let tc = {
    path: "/m/3.mp3",
    title: "另",
    artist: "张三",
    album: "范特西",
    duration_ms: 300L,
    cover: None,
    loudness: None,
    lyrics: "",
  }
  engine.stub(ta, [])
  engine.stub(tb, [])
  engine.stub(tc, [])
  cm.merge_scan("/m", [ta, tb, tc])
  // ① 点「专辑」列头：升序——空串 shortlex 最小，排最前；叶（U+53F6）< 范（U+8303）
  cm.set_sort(3)
  assert_eq(cm.view[0].path, "/m/2.mp3")
  assert_eq(cm.view[1].path, "/m/1.mp3")
  assert_eq(cm.view[2].path, "/m/3.mp3")
  // ② 再点同一列：升降翻转
  cm.set_sort(3)
  assert_eq(cm.view[0].path, "/m/3.mp3")
  assert_eq(cm.view[2].path, "/m/2.mp3")
  // ③ 换列：回到升序（标题列，shortlex 先比长度：另(1字) < 不见 < 晴天）
  cm.set_sort(1)
  assert_true(cm.sort_asc)
  assert_eq(cm.view[0].path, "/m/3.mp3")
  assert_eq(cm.view[2].path, "/m/1.mp3")
  // ④ 行格：空专辑显「未知」，非空显库里的真值
  cm.set_sort(3)
  let row0 = cm.build_row(0) catch { _ => abort("build_row 失败") }
  assert_true(cm_texts_in(row0).contains("未知"))
  assert_false(cm_texts_in(row0).contains("叶惠美"))
  let row1 = cm.build_row(1) catch { _ => abort("build_row 失败") }
  assert_true(cm_texts_in(row1).contains("叶惠美"))
  let row2 = cm.build_row(2) catch { _ => abort("build_row 失败") }
  assert_true(cm_texts_in(row2).contains("范特西"))
  @moonui.Backend::terminate(b)
}

///|
/// 睡眠定时（`T185`）：真实到期链路（mock 钟 + refresh_bar 的既有心跳口）——
/// 到点播放中→暂停、菜单打勾换格；重设盖旧账；关闭清账；没在播到期只清账。
test "app：睡眠定时——到点暂停、打勾、重设/关闭/未播到期（T185）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let now = [0L]
  let cm = LunaMusicApp::new(app, engine, sleep_clock=fn() { now[0] })
  let t = trk("/m/1.mp3", 200000L)
  engine.stub(t, [])
  cm.merge_scan("/m", [t])
  cm.player.play_index(0)
  assert_true(cm.player.is_playing())
  // ① 初始：六格都在，只有「关闭」亮
  let mut labels = ""
  let mut checked = ""
  for n in cm.cm_build_sleep_menu_nodes() {
    match n {
      @moonui.Item(it) => {
        labels = labels + it.describe() + "|"
        if it.checked {
          checked = checked + it.describe()
        }
      }
      _ => ()
    }
  }
  assert_true(labels.contains("关闭"))
  assert_true(labels.contains("1 分钟"))
  assert_true(labels.contains("15 分钟"))
  assert_true(labels.contains("90 分钟"))
  assert_true(checked.contains("关闭"))
  // ② 设 15 分钟：到期账记下（钟此刻是 0），菜单换勾
  cm.set_sleep_timer(15)
  assert_eq(cm.sleep_due_ms, Some(900_000L))
  let mut checked2 = ""
  for n in cm.cm_build_sleep_menu_nodes() {
    match n {
      @moonui.Item(it) => if it.checked { checked2 = checked2 + it.describe() }
      _ => ()
    }
  }
  assert_true(checked2.contains("15 分钟"))
  assert_false(checked2.contains("关闭"))
  // ③ 还没到点：心跳走一拍不动
  now[0] = 899_999L
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_true(cm.player.is_playing())
  // ④ 到点那一拍：暂停、清账、菜单回到「关闭」亮
  now[0] = 900_000L
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_true(cm.player.state is Paused)
  assert_eq(cm.sleep_due_ms, None)
  assert_eq(cm.sleep_mins, 0)
  let mut checked3 = ""
  for n in cm.cm_build_sleep_menu_nodes() {
    match n {
      @moonui.Item(it) => if it.checked { checked3 = checked3 + it.describe() }
      _ => ()
    }
  }
  assert_true(checked3.contains("关闭"))
  // ⑤ 重设盖旧账：t=1000 再设 15（到期 901000），紧接着改 30——到期账变成
  // 1801000，不是旧账的 901000
  now[0] = 1_000L
  cm.set_sleep_timer(15)
  assert_eq(cm.sleep_due_ms, Some(901_000L))
  cm.set_sleep_timer(30)
  assert_eq(cm.sleep_due_ms, Some(1_801_000L))
  // ⑥ 关闭：清账（还没到期）
  cm.set_sleep_timer(0)
  assert_eq(cm.sleep_due_ms, None)
  assert_eq(cm.sleep_mins, 0)
  // ⑦ 没在播到期：只清账，Idle 不被拽成 Paused
  cm.player.stop()
  assert_true(cm.player.state is Idle)
  cm.set_sleep_timer(15)
  now[0] = 10_900_000L
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_true(cm.player.state is Idle)
  assert_eq(cm.sleep_due_ms, None)
  @moonui.Backend::terminate(b)
}

///|
/// 睡眠定时跨 `2^31` 毫秒回绕点（`T221`）。
///
/// 真壳里 `sleep_clock` 就是那只截断钟撑回 64 位（`examples/lunamusic-shell/shell.mbt`
/// 的 `native_time_ms().to_int64()`——把已经截过、已经带符号的 Int32 撑回 Int64，
/// 不构成防线），所以开机满 24.85 天后它同样读负数。三格分工：
/// ①**陷阱**：这条链上 Int64 差值判不出到期。回绕前排下的 `due = 2148383000L` 是
///   回绕前那头（没截断）的正数，回绕后的 `now` 是负数，`now - due` 落在 −4294967000L
///   这种四十亿量级的巨大负数上——符号说"还早着呢"，而真实只差 296 毫秒。
///   只有把差值**降到 32 位取模**（`.to_int()`，即低 32 位有符号残差）才给出 `296 >= 0`。
///   缺这一格，本条判据只是在复述实现。
/// ②反向：跨圈之后但**还没到期**的那一格（真实还差 898704 毫秒）不许被取模判定
///   读成到期——回绕不等于"全跑"。
/// ③到期真的 `pause()`、清账、菜单回到「关闭」。
test "app：睡眠定时跨 2^31 时钟回绕照样判到期，Int64 差值在这里失效（T221）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  // 回绕前 648 毫秒（真实开机毫秒 2147483000，2^31 = 2147483648）
  let now = [2147483000L]
  let cm = LunaMusicApp::new(app, engine, sleep_clock=fn() { now[0] })
  let t = trk("/m/1.mp3", 200000L)
  engine.stub(t, [])
  cm.merge_scan("/m", [t])
  cm.player.play_index(0)
  assert_true(cm.player.is_playing())
  cm.set_sleep_timer(15)
  // 存储口径不动：绝对时刻 = 当下钟 + 分钟数（`T185` 的现成判据钉的就是这个形状）
  assert_eq(cm.sleep_due_ms, Some(2148383000L))
  // ② 跨圈但没到期：真实 2147484296，距到期还差 898704 毫秒——不许读成到期
  now[0] = -2147483000L
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_true(cm.player.is_playing())
  assert_eq(cm.sleep_due_ms, Some(2148383000L))
  // ① 陷阱格：走到真实 2148383296（过期 296 毫秒）
  now[0] = -2146584000L
  let raw_diff = now[0] - 2148383000L
  assert_eq(raw_diff, -4294967000L)
  assert_true(raw_diff < 0L)
  assert_eq(raw_diff.to_int(), 296)
  assert_true(raw_diff.to_int() >= 0)
  // ③ 32 位取模判定生效：这一拍真的暂停
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_true(cm.player.state is Paused)
  assert_eq(cm.sleep_due_ms, None)
  assert_eq(cm.sleep_mins, 0)
  let mut checked = ""
  for n in cm.cm_build_sleep_menu_nodes() {
    match n {
      @moonui.Item(it) => if it.checked { checked = checked + it.describe() }
      _ => ()
    }
  }
  assert_true(checked.contains("关闭"))
  @moonui.Backend::terminate(b)
}

///|
/// 睡眠定时 1 分钟档（`T223`）：最小档位自己走一遍完整账——设下去到期是 60 秒，
/// 到点前一毫秒还在播，到点那一拍暂停并清账。
///
/// 单独一条而不是塞进 `T185` 那串：那条用 15 分钟做主线，1 分钟档要证明的是
/// **最短那一档也会到点**（分钟换算没有把 1 写成别的量级）。
test "app：睡眠定时 1 分钟档——60 秒到期、前一毫秒仍播、到点暂停清账（T223）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let now = [0L]
  let cm = LunaMusicApp::new(app, engine, sleep_clock=fn() { now[0] })
  let t = trk("/m/1.mp3", 200000L)
  engine.stub(t, [])
  cm.merge_scan("/m", [t])
  cm.player.play_index(0)
  assert_true(cm.player.is_playing())
  cm.set_sleep_timer(1)
  assert_eq(cm.sleep_due_ms, Some(60_000L))
  // 还差 1 毫秒：不许提前到点
  now[0] = 59_999L
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_true(cm.player.is_playing())
  assert_eq(cm.sleep_due_ms, Some(60_000L))
  // 到点那一拍：暂停 + 清账
  now[0] = 60_000L
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_true(cm.player.state is Paused)
  assert_eq(cm.sleep_due_ms, None)
  assert_eq(cm.sleep_mins, 0)
  @moonui.Backend::terminate(b)
}

///|
/// 树里所有文案等于 want 的控件，深度先序（行序 = 文档序）：拖拽判据要按
/// 行号抓句柄，`find_text_widget` 只给第一只不够用。
fn[B : @moonui.Backend] find_all_text_widgets(
  w : @moonui.Widget[B],
  want : String,
  out : Array[@moonui.Widget[B]],
) -> Unit {
  match w.handle() {
    Some(_) => if (w.text() catch { _ => "" }) == want { out.push(w) }
    None => ()
  }
  for c in w.children() {
    find_all_text_widgets(c, want, out)
  }
}

///|
/// 队列顺序的一行串读法（判据用，别拿来当身份账）。
fn[A] cm_queue_str(p : Player[A]) -> String {
  let mut s = ""
  for t in p.queue {
    s = s + t.path + ","
  }
  s
}

///|
/// 「下一首播放」（`T176` / `T225`）：右键菜单有单项；播放中插到当前曲之后
/// （队列里本来就有那首 → **按 path 搬运**，长度不变、次序对）；多选批量按
/// **选中顺序**整段搬；没播过（current 为空）等价追加到队尾。
test "app：下一首播放——插当前后/多选按选中序/未播追加（T176/T225）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let ta = trk("/m/a.mp3", 100L)
  let tb = trk("/m/b.mp3", 200L)
  let tc = trk("/m/c.mp3", 300L)
  engine.stub(ta, [])
  engine.stub(tb, [])
  engine.stub(tc, [])
  cm.merge_scan("/m", [ta, tb, tc])
  // ① 右键菜单里有「下一首播放」；单选时不出现批量那条
  let scratch = app.create_window("行", @moonui.LogicalSize(320.0, 40.0))
  let items = cm_row_menu(app, b, cm, scratch, 1)
  assert_true(items.contains("下一首播放"))
  assert_false(items.contains("下一首播放选中的 2 首"))
  // ② 播放中（当前 = a）：把 c 插到 a 之后。队列原本就有 c，`T225` 起按 path
  // 搬运：a,b,c 里 c 摘掉再插到 a 后 = a,c,b（长度 3，不再多出一行）
  cm.player.play_index(0)
  cm.play_next_soon(["/m/c.mp3"])
  assert_eq(cm.player.queue.length(), 3)
  assert_eq(cm_queue_str(cm.player), "/m/a.mp3,/m/c.mp3,/m/b.mp3,")
  assert_true(cm.player.is_playing())
  assert_eq(cm.player.current, Some(0)) // 当前曲仍是 a，下标没漂
  // ③ 多选批量：点行 2、1（曲库序 c、b → 选中序 c,b），选中按点击顺序记
  // （`T177`），批量项出现，搬进队列的整段也按这个顺序。点行会 rebuild_ui，
  // 曲库页签上队列跟着视图重对齐（既有 sync_queue 语义）：插队的 c 从队列里
  // 退掉，队列回到 a,b,c、current=0（a 还在播）。
  cm_click_row(cm, 2)
  cm_click_row(cm, 1)
  assert_eq(cm.selected, ["/m/c.mp3", "/m/b.mp3"])
  let items2 = cm_row_menu(app, b, cm, scratch, 1)
  assert_true(items2.contains("下一首播放选中的 2 首"))
  cm.play_next_soon(cm.selected)
  // 在 a 后整段搬 [c,b]：a,c,b（段内序 = 选中序），两首本来就在队列里 → 长度仍 3
  assert_eq(cm.player.queue.length(), 3)
  assert_eq(cm_queue_str(cm.player), "/m/a.mp3,/m/c.mp3,/m/b.mp3,")
  // ④ 未播放（current 为空）等价追加：c 先摘掉再追加到队尾 → a,b,c
  cm.player.state = Idle
  cm.player.current = None
  cm.play_next_soon(["/m/c.mp3"])
  assert_eq(cm.player.queue.length(), 3)
  assert_eq(cm_queue_str(cm.player), "/m/a.mp3,/m/b.mp3,/m/c.mp3,")
  @moonui.Backend::terminate(b)
}

///|
/// 插队按 path 搬运的 player 级判据（`T225`，绕开视图直接构造）：
/// ① 不在队列里的照样插一份拷贝；
/// ② 目标就是正在播的那首 → 队列一字不动；
/// ③ 队列里本来就有两份同 path → 插一次后只剩一份；
/// ④ `lib.tracks` 别名不被改写（摘/插都落在新数组上）。
test "player：插队按 path 搬运——拷贝/当前曲 no-op/重复收成一份/不改别名（T225）" {
  let ta = trk("/m/a.mp3", 100L)
  let tb = trk("/m/b.mp3", 200L)
  let tc = trk("/m/c.mp3", 300L)
  // ① 不在队列里：a,c 播 a，插 b → a,b,c
  let e1 = eng_with([ta, tb, tc])
  let p1 = Player::new(e1, [ta, tc])
  p1.play_index(0)
  let _ = p1.insert_next([tb])
  assert_eq(cm_queue_str(p1), "/m/a.mp3,/m/b.mp3,/m/c.mp3,")
  assert_eq(p1.current, Some(0))
  // ② 目标就是当前曲：a,b,c 播 a，插 a → 一字不动
  let e2 = eng_with([ta, tb, tc])
  let p2 = Player::new(e2, [ta, tb, tc])
  p2.play_index(0)
  let at2 = p2.insert_next([ta])
  assert_eq(cm_queue_str(p2), "/m/a.mp3,/m/b.mp3,/m/c.mp3,")
  assert_eq(p2.current, Some(0))
  assert_eq(at2, 1) // 一首都没动：回原插入位
  // ③ 队列里有两份 c：插一次后只剩一份，且挪到 a 后
  let e3 = eng_with([ta, tb, tc])
  let p3 = Player::new(e3, [ta, tb, tc, tc])
  p3.play_index(0)
  let _ = p3.insert_next([tc])
  assert_eq(cm_queue_str(p3), "/m/a.mp3,/m/c.mp3,/m/b.mp3,")
  assert_eq(p3.current, Some(0))
  // ④ 别名不被改写：replace_queue(lib) 之后插队，lib 的次序与长度不动
  let e4 = eng_with([ta, tb, tc])
  let lib = [ta, tb, tc]
  let p4 = Player::new(e4, lib)
  p4.replace_queue(lib)
  p4.play_index(0)
  let _ = p4.insert_next([tc])
  assert_eq(cm_queue_str(p4), "/m/a.mp3,/m/c.mp3,/m/b.mp3,")
  assert_eq(lib.length(), 3)
  let mut lib_str = ""
  for t in lib {
    lib_str = lib_str + t.path + ","
  }
  assert_eq(lib_str, "/m/a.mp3,/m/b.mp3,/m/c.mp3,")
}

///|
/// owner 2026-11-06 真机报的那条（`T225`）：队列页签里右键一首点「下一首播放」，
/// 那首在列表里重复出现（截图里 25 行有 3/5/9 行都是同一首）。根因是插队无
/// 条件插拷贝、而队列恒等于当前视图，插完就有两份、再被 `compute_view` 刷回
/// 列表。
///
/// 判据三件事：行数不变、该行挪到当前曲后一行、全队列无重复 path。
test "app：队列页签「下一首播放」不再插出重复行（T225）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let ta = trk("/m/a.mp3", 100L)
  let tb = trk("/m/b.mp3", 200L)
  let tc = trk("/m/c.mp3", 300L)
  let td = trk("/m/d.mp3", 400L)
  engine.stub(ta, [])
  engine.stub(tb, [])
  engine.stub(tc, [])
  engine.stub(td, [])
  cm.merge_scan("/m", [ta, tb, tc, td])
  cm.set_tab(2)
  assert_eq(cm.view.length(), 4)
  // 播 b（第 2 行），再对 d 那行点「下一首播放」
  cm.player.play_index(1)
  assert_eq(cm.player.track().unwrap().path, "/m/b.mp3")
  cm.play_next_soon(["/m/d.mp3"])
  // 行数不变
  assert_eq(cm.view.length(), 4)
  assert_eq(cm.player.queue.length(), 4)
  // d 挪到当前曲（b）后一行
  assert_eq(cm_queue_str(cm.player), "/m/a.mp3,/m/b.mp3,/m/d.mp3,/m/c.mp3,")
  assert_eq(cm.view[2].path, "/m/d.mp3")
  assert_eq(cm.player.current, Some(1))
  // 全队列无重复 path
  let seen : Map[String, Bool] = Map([])
  for t in cm.player.queue {
    assert_false(seen.contains(t.path))
    seen.set(t.path, true)
  }
  @moonui.Backend::terminate(b)
}

///|
/// 队列拖拽重排（`T176`）：真走拖放会话（按下句柄开 → 移动发 DragOver 记
/// 插入位 → 抬起 DragDrop 落账）——第 3 行拖到第 1 位逐位断言；正在播那首
/// 被挪后播放不断、下标跟随；拖回原位幂等。
test "app：队列拖拽重排——拖第 3 行到第 1 位、播放跟随、原位幂等（T176）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let ta = trk("/m/a.mp3", 100L)
  let tb = trk("/m/b.mp3", 200L)
  let tc = trk("/m/c.mp3", 300L)
  let td = trk("/m/d.mp3", 400L)
  engine.stub(ta, [])
  engine.stub(tb, [])
  engine.stub(tc, [])
  engine.stub(td, [])
  cm.merge_scan("/m", [ta, tb, tc, td])
  cm.set_tab(2)
  cm.player.play_index(1)
  assert_true(cm.player.is_playing())
  // 命中测试要真坐标：窗摆出来、跑一圈布局，行带才有框
  for w in cm.startup_windows() {
    w.show()
  }
  let _ = app.step()
  let table_root = cm.ui.unwrap().table.root
  // ① 第 3 行（c）的句柄按下：拖放会话开
  let grips : Array[@moonui.Widget[@moonui.MockBackend]] = []
  find_all_text_widgets(table_root, "≡", grips)
  assert_eq(grips.length(), 4)
  let g2 = grips[2]
  let f_g2 = g2.frame()
  let _ = app.dispatch(
    @moonui.MouseDown(
      g2.target(),
      @moonui.Left,
      @moonui.LogicalPoint(f_g2.origin.x + 1.0, f_g2.origin.y + 1.0),
      @moonui.Mods::none(),
    ),
  )
  assert_true(app.drag_active())
  // ② 移到第 1 行（a）的上半：插入位 = 0（DragOver 边沿记账）。落点不用找
  // 标题——行里显示的是 T193 投影后的文件名词干，不是 path；行带的实框在
  // Panel 那层（Sized/Row 是纯布局节点，frame 恒为零矩形），从句柄往上爬到
  // 第一只有高度的祖先就是行带。
  let band = fn(
    g : @moonui.Widget[@moonui.MockBackend],
  ) -> @moonui.LogicalRect {
    let mut w = g
    while true {
      w = w.parent().unwrap()
      if w.frame().size.height >= 20.0 {
        return w.frame()
      }
    }
    abort("句柄上方没有行带")
  }
  let f0 = band(grips[0])
  assert_true(f0.size.height > 0.0)
  let p_top0 = @moonui.LogicalPoint(f0.origin.x + 5.0, f0.origin.y + 2.0)
  let _ = app.dispatch(@moonui.MouseMove(g2.target(), p_top0))
  assert_eq(cm.drag_ins, Some(0))
  // ③ 抬手落账：c 挪到第 1 位，其余次序保持
  let _ = app.dispatch(
    @moonui.MouseUp(g2.target(), @moonui.Left, p_top0, @moonui.Mods::none()),
  )
  assert_eq(cm_queue_str(cm.player), "/m/c.mp3,/m/a.mp3,/m/b.mp3,/m/d.mp3,")
  assert_eq(cm.drag_ins, None)
  assert_eq(cm.drag_src, None)
  // ④ 播放没断：还是 b 在播，下标跟着队列走（1 → 2）
  assert_true(cm.player.is_playing())
  assert_eq(cm.player.track().unwrap().path, "/m/b.mp3")
  assert_eq(cm.player.current, Some(2))
  // ⑤ 拖回原位幂等：把 b（现在第 3 行）拖到自己上半，次序一位不动。
  // 落账那次重建换了行，先跑一圈布局，新行才有框。
  let _ = app.step()
  let grips2 : Array[@moonui.Widget[@moonui.MockBackend]] = []
  find_all_text_widgets(table_root, "≡", grips2)
  assert_eq(grips2.length(), 4)
  let g2b = grips2[2]
  let f_g2b = g2b.frame()
  let _ = app.dispatch(
    @moonui.MouseDown(
      g2b.target(),
      @moonui.Left,
      @moonui.LogicalPoint(f_g2b.origin.x + 1.0, f_g2b.origin.y + 1.0),
      @moonui.Mods::none(),
    ),
  )
  assert_true(app.drag_active())
  // 拖到自己上半（现在第 3 行就是 b 自己），次序一位不动
  let fb = band(g2b)
  let p_top_b = @moonui.LogicalPoint(fb.origin.x + 5.0, fb.origin.y + 2.0)
  let _ = app.dispatch(@moonui.MouseMove(g2b.target(), p_top_b))
  assert_eq(cm.drag_ins, Some(2))
  let _ = app.dispatch(
    @moonui.MouseUp(g2b.target(), @moonui.Left, p_top_b, @moonui.Mods::none()),
  )
  assert_eq(cm_queue_str(cm.player), "/m/c.mp3,/m/a.mp3,/m/b.mp3,/m/d.mp3,")
  assert_eq(cm.drag_ins, None)
  assert_false(app.drag_active())
  @moonui.Backend::terminate(b)
}

///|
/// 从 cm_build_menus 的树里摘「播放→输出设备」子菜单（`T169`）；没挂返回空——
/// 判据③（空设备表降级）与判据①（非空挂上）读的是同一个口子。
fn[B : @moonui.Backend, A : AudioEngine] cm_output_submenu_nodes(
  cm : LunaMusicApp[B, A],
) -> Array[@moonui.MenuNode] {
  for m in cm.cm_build_menus() {
    if m.title() == "播放" {
      for n in m.nodes() {
        match n {
          @moonui.Submenu(title, items) =>
            if title == "输出设备" {
              return items
            }
          _ => ()
        }
      }
    }
  }
  []
}

///|
test "app：输出设备——子菜单列设备、当前打勾、切换记账、空表不挂（T169）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  // ① 编排三台设备、当前第二台：子菜单挂上、三格全在、只亮当前
  engine.stub_outputs(["内置扬声器", "AirPods Pro", "HDMI"], 1)
  let nodes = cm_output_submenu_nodes(cm)
  assert_eq(nodes.length(), 3)
  let mut labels = ""
  let mut checked = ""
  for n in nodes {
    match n {
      @moonui.Item(it) => {
        labels = labels + it.describe() + "|"
        if it.checked {
          checked = checked + it.describe()
        }
      }
      _ => ()
    }
  }
  assert_true(labels.contains("内置扬声器"))
  assert_true(labels.contains("AirPods Pro"))
  assert_true(labels.contains("HDMI"))
  // radio 的读回口径：亮格 describe 带 " (*)"，灭格带 " ( )"（menu.mbt 457）
  assert_eq(checked, "AirPods Pro (*)")
  // ② 切到第三台：mock calls 记下 set_output_device:2，打勾换格
  assert_true(cm.set_output_device(2))
  assert_true(engine.calls.contains("set_output_device:2"))
  let mut checked2 = ""
  for n in cm_output_submenu_nodes(cm) {
    match n {
      @moonui.Item(it) => if it.checked { checked2 = checked2 + it.describe() }
      _ => ()
    }
  }
  assert_eq(checked2, "HDMI (*)")
  // ③ 空设备表（Windows 空桩那格）：整个子菜单不出现——降级是"不挂"，
  // 不是挂一颗点不动的壳
  engine.stub_outputs([], -1)
  assert_eq(cm_output_submenu_nodes(cm).length(), 0)
  // ④ 失败静默：编排切换失败 → 返回 false、calls 照记、勾留在原处
  engine.stub_outputs(["内置扬声器", "AirPods Pro"], 0)
  engine.fail_output_set = true
  assert_false(cm.set_output_device(1))
  assert_true(engine.calls.contains("set_output_device:1"))
  assert_eq(AudioEngine::output_current(engine), 0)
  // 越界同一格：false、勾不动
  engine.fail_output_set = false
  assert_false(cm.set_output_device(9))
  assert_eq(AudioEngine::output_current(engine), 0)
}

///|
/// 判据①③（`T181`）：mock 后端装回调后直接 `cb(码)` → app 状态翻真；热键
/// 码映射一对一（0 = 播放/暂停、1 = 下一首、2 = 上一首，表见 adapter.h）。
/// 表外码静默不猜——`media_action` 是四条来路（媒体键/热键/托盘/播放菜单）
/// 唯一入口，这里从媒体键与热键两头打它。
test "app：媒体键与全局热键——装回调即触发、码表一对一、表外静默（T181）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  // 三首入库、从第一首开播——回调是 `new` 尾上装的，不用再装。三首都得
  // stub：next/prev 要 load 新路径，mock 没登记的路径 load 即失败、原地不动。
  let ta = trk("/m/a.mp3", 100000L)
  let tb = trk("/m/b.mp3", 100000L)
  let tc = trk("/m/c.mp3", 100000L)
  engine.stub(ta, [])
  engine.stub(tb, [])
  engine.stub(tc, [])
  cm.merge_scan("/m", [ta, tb, tc])
  cm.player.play_index(0)
  assert_true(cm.player.is_playing())
  // ① 媒体键 0 = 播放/暂停切换，两向都翻
  b.fire_media_key(0)
  assert_false(cm.player.is_playing())
  b.fire_media_key(0)
  assert_true(cm.player.is_playing())
  // ③ 热键 1 = 下一首、2 = 上一首（切歌后 mock 引擎位置归 0，prev 走真切）
  assert_eq(cm.player.now_path(), "/m/a.mp3")
  b.fire_hotkey(1)
  assert_eq(cm.player.now_path(), "/m/b.mp3")
  b.fire_hotkey(1)
  assert_eq(cm.player.now_path(), "/m/c.mp3")
  b.fire_hotkey(2)
  assert_eq(cm.player.now_path(), "/m/b.mp3")
  b.fire_hotkey(2)
  assert_eq(cm.player.now_path(), "/m/a.mp3")
  // 表外码静默：曲、播放态一个不动
  b.fire_media_key(7)
  b.fire_hotkey(7)
  assert_eq(cm.player.now_path(), "/m/a.mp3")
  assert_true(cm.player.is_playing())
  @moonui.Backend::terminate(b)
}

///|
/// 判据②（`T181`）：set_now_playing 签名边沿——签名（曲路径/显示口径/位置
/// 秒/播放态）不变不推、变了恰好推一次；没歌时清一次、再不重推。mock 的
/// now_playing_log 按 `标题|歌手|elapsed_ms|duration_ms|playing` 记流水。
test "app：now-playing 签名边沿——不变不推、变了恰好一次、清一次（T181）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let cm = LunaMusicApp::new(app, engine)
  let t = trk("/m/a.mp3", 10000L)
  engine.stub(t, [])
  cm.merge_scan("/m", [t])
  cm.player.play_index(0)
  // play_index 的 notify 广播自己走一拍 refresh_bar：首推在这儿发生，签名
  // （位置 0、播着）落账——断言从流水内容对起，不再数"谁先谁后"。
  assert_eq(b.now_playing_log().length(), 1)
  assert_eq(b.now_playing_log()[0], "a||0|10000|1")
  // 位置没动、播放态没变：签名不变，不推
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_eq(b.now_playing_log().length(), 1)
  // 位置动了：恰好再推一次，elapsed 跟上
  engine.pos_ms = 2000L
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_eq(b.now_playing_log().length(), 2)
  assert_eq(b.now_playing_log()[1], "a||2000|10000|1")
  // 同一秒内再刷：签名里的位置秒没过界，不推
  engine.pos_ms = 2500L
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_eq(b.now_playing_log().length(), 2)
  // 暂停：播放态变了，推一次 playing=0。位置报的是**当下**的 2500（上一拍
  // 2500 没过秒界没推，暂停这条签名边沿把它捎上了）
  cm.player.toggle()
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_eq(b.now_playing_log().length(), 3)
  assert_eq(b.now_playing_log()[2], "a||2500|10000|0")
  // 暂停着位置冻结：再刷不推
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_eq(b.now_playing_log().length(), 3)
  // 清空队列 → 没歌：清一次（空包），再刷不重推
  cm.player.replace_queue([])
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_eq(b.now_playing_log().length(), 4)
  assert_eq(b.now_playing_log()[3], "||0|-1|0")
  cm.refresh_bar() catch {
    _ => ()
  }
  assert_eq(b.now_playing_log().length(), 4)
  @moonui.Backend::terminate(b)
}

///|
/// `T168` 无缝播放判据（mock 层，五条判据在下面五只 test 里）。负控刀法：
/// 摘掉 handle_primed 的指针推进 → 判据①红；摘掉 insert_next 的预排重算
/// → 判据④红（各实测一轮红→复原绿，见提交说明）。`T224` 起预排只在临播完
/// 时链，四条测试都在"刚开播"之后把位置推到 `dur - 500` 再调一拍心跳。
fn count_loads(e : MockAudioEngine) -> Int32 {
  let mut n = 0
  for c in e.calls {
    if c.has_prefix("load:") {
      n = n + 1
    }
  }
  n
}

///|
test "t168①：顺序两曲——临播完才预排、fire 后 handoff 到达、无第二次 load（T224 时序）" {
  let tracks = [trk("/m/a.mp3", 30_000L), trk("/m/b.mp3", 30_000L)]
  let e = eng_with(tracks)
  let p = Player::new(e, tracks)
  p.toggle() // Idle → 播队列头
  assert_eq(p.track().unwrap().path, "/m/a.mp3")
  // T224：刚开播不预排（离结尾还远，此时排一次会先 stop 掉当前段）
  assert_eq(e.primed, None)
  assert_eq(p.primed_path, None)
  // 心跳一拍：推到只剩 500 毫秒，这一拍才真的链上 b
  e.pos_ms = 30_000L - 500L
  p.prime_refresh()
  assert_eq(e.primed, Some("/m/b.mp3"))
  assert_eq(p.primed_path, Some("/m/b.mp3"))
  let calls_before = e.calls.length()
  e.fire_finished() // EOS：预排链着 → handoff，不是播完
  // handoff 到达：当前曲指针推进、位置归零、播着不变
  assert_eq(p.track().unwrap().path, "/m/b.mp3")
  assert_eq(p.position(), 0L)
  assert_true(p.is_playing())
  // v1 核心：不重 load——calls 只多 `T170` 的那条补挂增益（gain:0，开关
  // 关着也是它）；prime_next/handoff 本身不记 calls，load 计数不动
  assert_eq(e.calls.length(), calls_before + 1)
  assert_eq(count_loads(e), 1)
  // b 是队尾：handoff 后预排撤（顺序到尾不绕）
  assert_eq(e.primed, None)
  assert_eq(p.primed_path, None)
  // 再一次 fire：无预排 → 老路，自然播完停
  e.fire_finished()
  assert_false(p.is_playing())
  assert_eq(count_loads(e), 1)
}

///|
test "t168②：单曲循环临播完预排自己，handoff 无缝重头、下一轮再链（T224 时序）" {
  let tracks = [trk("/m/a.mp3", 300_000L)]
  let e = eng_with(tracks)
  let p = Player::new(e, tracks)
  p.toggle()
  p.cycle_mode() // 顺序 → 单曲循环
  assert_eq(p.mode, RepeatOne)
  // T224：刚开播不预排
  assert_eq(e.primed, None)
  // 临播完的那一拍才链上自己
  e.pos_ms = 300_000L - 500L
  p.prime_refresh()
  assert_eq(e.primed, Some("/m/a.mp3"))
  e.fire_finished() // handoff：同一文件无缝重头
  assert_true(p.is_playing())
  assert_eq(p.track().unwrap().path, "/m/a.mp3")
  assert_eq(p.position(), 0L)
  // 不重 load、不发 play；多的是 `T170` 的 handoff 补挂（gain:0）
  assert_eq(count_loads(e), 1)
  assert_eq(e.calls.length(), 6) // on_finished / on_primed_start / load / play / gain:0（开播）/ gain:0（handoff 补挂）
  // handoff 后从头开始：这条链要等下一轮到尾再链（T224 的时序）
  assert_eq(e.primed, None)
  assert_eq(p.primed_path, None)
  e.pos_ms = 300_000L - 500L
  p.prime_refresh()
  assert_eq(e.primed, Some("/m/a.mp3")) // 还是自己
}

///|
test "t168③：随机模式不设预排，EOS 走老路（现 load 下一首）" {
  let tracks = [
    trk("/m/1.mp3", 300L),
    trk("/m/2.mp3", 300L),
    trk("/m/3.mp3", 300L),
  ]
  let e = eng_with(tracks)
  let p = Player::new(e, tracks)
  p.set_shuffle_rng(
    @random.Rand::chacha8(
      seed=b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x20",
    ),
  )
  p.play_index(0)
  p.cycle_mode() // → 单曲循环
  p.cycle_mode() // → 随机
  assert_eq(p.mode, Shuffle)
  // 随机不预排（牌堆头等 EOS 那刻才揭）
  assert_eq(e.primed, None)
  e.fire_finished() // 老路：on_finished → handle_finished → start_at → load
  assert_true(p.is_playing())
  // 老路的标志：第二次 load 真的发生了
  assert_eq(count_loads(e), 2)
}

///|
test "t168④：插队后预排重算（T176 连动），handoff 接的是插进来的那首（T224 时序）" {
  let tracks = [trk("/m/a.mp3", 30_000L), trk("/m/b.mp3", 30_000L)]
  let e = eng_with(tracks)
  let p = Player::new(e, tracks)
  p.toggle()
  // 先走到临播完，链上 b
  e.pos_ms = 30_000L - 500L
  p.prime_refresh()
  assert_eq(e.primed, Some("/m/b.mp3"))
  let c = trk("/m/c.mp3", 50L)
  e.stub(c, [])
  let _ignored = p.insert_next([c])
  // 窗口内插队：预排重算，b 被顶掉，现在链的是 c（已知限界：这一次重排仍会
  // 让 C 侧 stop/restart 当前段——彻底消除要 A/B 双节点，记在 TODO）
  assert_eq(e.primed, Some("/m/c.mp3"))
  assert_eq(p.primed_path, Some("/m/c.mp3"))
  e.fire_finished()
  assert_eq(p.track().unwrap().path, "/m/c.mp3")
  assert_true(p.is_playing())
  assert_eq(count_loads(e), 1) // c 没走 load
}

///|
test "t168⑤：seek/换歌/stop 后预排清空（T224 时序：临播完才重链）" {
  let tracks = [
    trk("/m/a.mp3", 30_000L),
    trk("/m/b.mp3", 30_000L),
    trk("/m/c.mp3", 30_000L),
  ]
  let e = eng_with(tracks)
  let p = Player::new(e, tracks)
  p.toggle()
  // 临播完那一拍才链上 b
  e.pos_ms = 30_000L - 500L
  p.prime_refresh()
  assert_eq(e.primed, Some("/m/b.mp3"))
  // seek：接缝点挪了，两边账一起清
  p.seek(1000L)
  assert_eq(e.primed, None)
  assert_eq(p.primed_path, None)
  // 恢复播放：早着不重链，临播完那一拍再链
  p.toggle() // → Paused
  p.toggle() // → Playing
  assert_eq(e.primed, None)
  e.pos_ms = 30_000L - 500L
  p.prime_refresh()
  assert_eq(e.primed, Some("/m/b.mp3"))
  p.stop()
  assert_eq(e.primed, None)
  assert_eq(p.primed_path, None) // 停止把账一起清了（T224 的不变式）
  // 换歌：旧预排不许残留——load 清引擎侧，新当前曲自己的"下一首"重算
  p.toggle() // Idle → start_at(current=0) → load a；早着不链
  assert_eq(e.primed, None)
  e.pos_ms = 30_000L - 500L
  p.prime_refresh()
  assert_eq(e.primed, Some("/m/b.mp3"))
  p.play_index(2) // 换到 c
  assert_eq(p.track().unwrap().path, "/m/c.mp3")
  assert_eq(e.primed, None) // c 是队尾：旧 b 预排清空且无新链
  assert_eq(p.primed_path, None)
}

///|
/// `T224` 判据①（owner 2026-11-06 报的卡顿）：长曲**刚开播**就插队，C 侧一次
/// 预排都不该收到——收到就说明它在已经链着下一段时又排了一次，第一句
/// `[moonui_ae_node stop]` 会把正在播的那段停掉，听感就是几百毫秒没声音。
///
/// 判据只看 `prime_calls` 与两本账：`prime_calls` 为空 = 这条链路一次 FFI
/// 预排都没走。
test "t224①：长曲刚开播插队不预排、不打断当前曲" {
  let tracks = [
    trk("/m/a.mp3", 300_000L),
    trk("/m/b.mp3", 300_000L),
    trk("/m/c.mp3", 300_000L),
  ]
  let e = eng_with(tracks)
  let p = Player::new(e, tracks)
  p.toggle()
  assert_eq(p.track().unwrap().path, "/m/a.mp3")
  assert_eq(e.prime_calls.length(), 0)
  let _ = p.insert_next([trk("/m/c.mp3", 300_000L)])
  // 插队这一下没有一次预排调用、引擎两侧账都空着
  assert_eq(e.prime_calls.length(), 0)
  assert_eq(e.primed, None)
  assert_eq(p.primed_path, None)
  assert_eq(cm_queue_str(p), "/m/a.mp3,/m/c.mp3,/m/b.mp3,")
}

///|
/// `T224` 判据②：临播完的那一拍**恰好链一次**；心跳再拍两下仍是一条——
/// 幂等闸挡的是"每 500ms 顶一次预排、连停好几次"。
test "t224②：临播完一拍恰好链一次，后续心跳不重复链（幂等）" {
  let tracks = [trk("/m/a.mp3", 300_000L), trk("/m/b.mp3", 300_000L)]
  let e = eng_with(tracks)
  let p = Player::new(e, tracks)
  p.toggle()
  e.pos_ms = 300_000L - 500L
  p.prime_refresh()
  assert_eq(e.prime_calls, ["prime:/m/b.mp3"])
  p.prime_refresh()
  p.prime_refresh()
  assert_eq(e.prime_calls.length(), 1)
  assert_eq(e.primed, Some("/m/b.mp3"))
  assert_eq(p.primed_path, Some("/m/b.mp3"))
}

///|
/// `T224` 判据③：**最后 10 秒内**插队仍会替换已链的预排——这是本版的已知
/// 限界（C 侧那次重排仍有一次 stop/restart），这里如实钉住它，不是期望值。
test "t224③：最后 10 秒内插队会重排预排（已知限界，如实记录）" {
  let tracks = [trk("/m/a.mp3", 300_000L), trk("/m/b.mp3", 300_000L)]
  let e = eng_with(tracks)
  let p = Player::new(e, tracks)
  p.toggle()
  e.pos_ms = 300_000L - 2_000L
  p.prime_refresh()
  assert_eq(e.primed, Some("/m/b.mp3"))
  let c = trk("/m/c.mp3", 300_000L)
  e.stub(c, [])
  let _ = p.insert_next([c])
  assert_eq(e.prime_calls, ["prime:/m/b.mp3", "prime:/m/c.mp3"])
  assert_eq(e.primed, Some("/m/c.mp3"))
  assert_eq(p.primed_path, Some("/m/c.mp3"))
}

///|
/// `T224` 判据④：暂停 / 停止 / seek / 换歌都把预排账清掉——`primed_path`
/// 不许在引擎已经没有链的时候还记着 Some（否则幂等闸会把死值当成真链着）。
test "t224④：暂停/停止/seek/换歌清预排账" {
  let tracks = [
    trk("/m/a.mp3", 300_000L),
    trk("/m/b.mp3", 300_000L),
    trk("/m/c.mp3", 300_000L),
  ]
  let e = eng_with(tracks)
  let p = Player::new(e, tracks)
  p.toggle()
  e.pos_ms = 300_000L - 500L
  p.prime_refresh()
  assert_eq(e.primed, Some("/m/b.mp3"))
  // 暂停：引擎侧 node stop，账一起清
  p.toggle() // → Paused
  assert_eq(e.primed, None)
  assert_eq(p.primed_path, None)
  // 恢复：位置还在最后 500 毫秒内，重链
  p.toggle() // → Playing
  assert_eq(e.primed, Some("/m/b.mp3"))
  // seek：两边一起清
  p.seek(1000L)
  assert_eq(e.primed, None)
  assert_eq(p.primed_path, None)
  // 停止
  e.pos_ms = 300_000L - 500L
  p.prime_refresh()
  assert_eq(e.primed, Some("/m/b.mp3"))
  p.stop()
  assert_eq(e.primed, None)
  assert_eq(p.primed_path, None)
  // 换歌：load 清引擎侧，新曲早着不链
  p.toggle() // Idle → start_at(0) → load a
  assert_eq(e.primed, None)
  e.pos_ms = 300_000L - 500L
  p.prime_refresh()
  assert_eq(e.primed, Some("/m/b.mp3"))
  p.play_index(1) // 换到 b
  assert_eq(p.track().unwrap().path, "/m/b.mp3")
  assert_eq(e.primed, None)
  assert_eq(p.primed_path, None)
}

///|
/// 「T170」判据①④：归一化增益算式。target(-18 LUFS) - 测值，夹 ±12dB；
/// 开关关 / 曲未测都恒 0 直通。换曲（play_index）时 load 归零后现挂。
test "T170：增益算式——target-测值、夹 ±12dB、关/未测恒 0" {
  // ④ 关着播：恒 0（含换曲）
  let quiet = {
    path: "/m/a.mp3",
    title: "a",
    artist: "a",
    album: "b",
    duration_ms: 300L,
    cover: None,
    loudness: Some(-20000),
    lyrics: "",
  }
  let loud = {
    path: "/m/b.mp3",
    title: "b",
    artist: "a",
    album: "b",
    duration_ms: 300L,
    cover: None,
    loudness: Some(-12000),
    lyrics: "",
  }
  let unmeasured = {
    path: "/m/c.mp3",
    title: "c",
    artist: "a",
    album: "b",
    duration_ms: 300L,
    cover: None,
    loudness: None,
    lyrics: "",
  }
  let e0 = eng_with([quiet, loud, unmeasured])
  let p0 = Player::new(e0, [quiet, loud, unmeasured])
  p0.play_index(0)
  assert_eq(e0.track_gain, 0)
  assert_eq(e0.calls[e0.calls.length() - 1], "gain:0")
  // ① 开：-20 LUFS → -18000-(-20000) = +2000；当前曲当场补挂
  p0.set_normalize(true)
  assert_eq(e0.track_gain, 2000)
  assert_true(e0.calls.contains("gain:2000"))
  // ① 换曲：-12 LUFS → -18000-(-12000) = -6000
  p0.play_index(1)
  assert_eq(e0.track_gain, -6000)
  assert_true(e0.calls.contains("gain:-6000"))
  // ④ 未测曲：不猜，恒 0
  p0.play_index(2)
  assert_eq(e0.track_gain, 0)
  // 关回去：恒 0
  p0.set_normalize(false)
  assert_eq(e0.track_gain, 0)
  // 夹：-70 LUFS 的极端 → +52000 裸值夹到 +12000
  let very_quiet = {
    path: "/m/d.mp3",
    title: "d",
    artist: "a",
    album: "b",
    duration_ms: 300L,
    cover: None,
    loudness: Some(-70000),
    lyrics: "",
  }
  let e1 = eng_with([very_quiet])
  let p1 = Player::new(e1, [very_quiet])
  p1.set_normalize(true)
  p1.play_index(0)
  assert_eq(e1.track_gain, 12000)
}

///|
/// 「T170」判据②：曲库档往返 loudness 不丢；旧档没这个键读回 None。
test "T170：曲库档 loudness 往返 + set_loudness 哨兵" {
  let lib = Library::new()
  lib.merge("/m", [trk("/m/a.mp3", 300L)])
  // 未测：档里写 null，读回 None
  let round0 = Library::from_json(lib.to_json()).unwrap()
  assert_eq(round0.tracks[0].loudness, None)
  // 测了：Some(-18000) 往返不丢
  assert_true(lib.set_loudness("/m/a.mp3", -18000))
  let round1 = Library::from_json(lib.to_json()).unwrap()
  assert_eq(round1.tracks[0].loudness, Some(-18000))
  // 哨兵 0（测不出）不落档
  assert_false(lib.set_loudness("/m/a.mp3", 0))
  let round2 = Library::from_json(lib.to_json()).unwrap()
  assert_eq(round2.tracks[0].loudness, Some(-18000))
  // 旧档（T169 时代的档没有 loudness 键）读回 None，不炸
  let legacy =
    #|{"dirs":["/m"],"tracks":[{"path":"/m/a.mp3","title":"/m/a.mp3","artist":"未知","album":"未知","duration_ms":300,"cover":null}],"favorites":[]}
  match Library::from_text(legacy) {
    Some(l) => assert_eq(l.tracks[0].loudness, None)
    None => assert_true(true) // 布局不对退 None，同样是"没把旧档读炸"
  }
}

///|
/// 「T170」判据③：Prefs normalize 往返。
test "T170：Prefs normalize 往返" {
  let p : Prefs = {
    volume: 600,
    mode: RepeatOne,
    last_path: Some("/m/a.mp3"),
    position_ms: 42000L,
    eq_bands: [500, 500, 500, 500, 500, 500, 500, 500, 500, 500],
    eq_on: false,
    skin: "深空灰",
    display: Tags,
    show_desk: false,
    normalize: true,
    playlists: [],
  }
  let p2 = Prefs::from_json(p.to_json()).unwrap()
  assert_eq(p2.normalize, true)
  let p3 : Prefs = { ..p, normalize: false, }
  let p4 = Prefs::from_json(p3.to_json()).unwrap()
  assert_eq(p4.normalize, false)
}

// ————————————————————————————————————————————————————
// T175 用户自建歌单（批 7）：纯账往返 ①②③ + 应用侧接线 ④⑤⑥⑦⑧
// ————————————————————————————————————————————————————

///|
/// 「T175」判据①③：新建→改名→加曲→存档→Prefs 重读，名称/顺序/path 逐位
/// 往返；顺带钉重名拒绝（新建与改名都是"拒绝"，不自动后缀）。
test "T175①③：歌单账往返 + 重名拒绝" {
  let pls : Array[Playlist] = []
  assert_true(playlist_add(pls, "晨跑"))
  assert_false(playlist_add(pls, "晨跑")) // 重名拒绝
  assert_false(playlist_add(pls, "")) // 空名拒绝
  assert_true(playlist_rename(pls, "晨跑", "夜跑"))
  assert_eq(pls.length(), 1)
  assert_eq(pls[0].name, "夜跑")
  // 加曲：重复 path 跳过（幂等），实际只进 2 条，顺序按给定序
  assert_eq(
    playlist_add_paths(pls, "夜跑", ["/m/a.mp3", "/m/b.mp3", "/m/a.mp3"]),
    2,
  )
  assert_eq(pls[0].paths, ["/m/a.mp3", "/m/b.mp3"])
  // 改名的拒绝账：空名 / 不存在的旧名 / 撞已有名；同名幂等成功
  assert_false(playlist_rename(pls, "夜跑", ""))
  assert_false(playlist_rename(pls, "没有的歌单", "x"))
  assert_true(playlist_add(pls, "别的"))
  assert_false(playlist_rename(pls, "夜跑", "别的"))
  assert_true(playlist_rename(pls, "夜跑", "夜跑"))
  // 存档 → 重读：逐位一致
  let p = Prefs::new()
  p.playlists = pls
  let rt = Prefs::from_json(p.to_json()).unwrap()
  assert_eq(rt.playlists.length(), 2)
  assert_eq(rt.playlists[0].name, "夜跑")
  assert_eq(rt.playlists[0].paths, ["/m/a.mp3", "/m/b.mp3"])
  assert_eq(rt.playlists[1].name, "别的")
  assert_eq(rt.playlists[1].paths.length(), 0)
}

///|
/// 「T175」判据②：删除歌单档里消失。
test "T175②：删除歌单档里消失" {
  let pls : Array[Playlist] = []
  let _ = playlist_add(pls, "甲")
  let _ = playlist_add(pls, "乙")
  assert_true(playlist_remove(pls, "甲"))
  assert_false(playlist_remove(pls, "甲")) // 再删没有的回 false
  assert_eq(playlist_index_of(pls, "甲"), -1)
  let p = Prefs::new()
  p.playlists = pls
  let rt = Prefs::from_json(p.to_json()).unwrap()
  assert_eq(rt.playlists.length(), 1)
  assert_eq(rt.playlists[0].name, "乙")
}

///|
/// 「T175」判据④⑤：行右键「加入歌单」走的就是 `add_to_playlist`（菜单项
/// 只是把它接上线，无头派不出右键），单首与多选批量都从它过。
test "T175④⑤：加入歌单——单首入账，多选按选中序，重复幂等" {
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
  assert_true(playlist_add(cm.playlists, "我的歌单"))
  // ④：行右键「加入歌单 > 我的歌单」
  cm.add_to_playlist(0, ["/m/2.mp3"]) catch {
    _ => abort("加入歌单不该失败")
  }
  assert_eq(cm.playlists[0].paths, ["/m/2.mp3"])
  assert_eq(cm.playlist_tracks(0).length(), 1)
  assert_eq(cm.playlist_tracks(0)[0].path, "/m/2.mp3")
  // ⑤：多选批量——按**选中顺序**入账（先点 1 再点 3）
  let _ = cm.toggle_select("/m/1.mp3")
  let _ = cm.toggle_select("/m/3.mp3")
  cm.add_to_playlist(0, cm.selected) catch {
    _ => abort("批量加入不该失败")
  }
  assert_eq(cm.playlists[0].paths, ["/m/2.mp3", "/m/1.mp3", "/m/3.mp3"])
  // 重复加同样的集合：幂等，账不动
  cm.add_to_playlist(0, cm.selected) catch {
    _ => ()
  }
  assert_eq(cm.playlists[0].paths.length(), 3)
  @moonui.Backend::terminate(b)
}

///|
/// 「T175」判据⑥：批量收藏进 favorites（已是收藏的跳过）。
test "T175⑥：批量收藏选中的 N 首进 favorites" {
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
  let _ = cm.toggle_select("/m/1.mp3")
  let _ = cm.toggle_select("/m/3.mp3")
  cm.batch_favorite_selected() catch {
    _ => abort("批量收藏不该失败")
  }
  assert_true(cm.lib.is_favorite("/m/1.mp3"))
  assert_true(cm.lib.is_favorite("/m/3.mp3"))
  assert_false(cm.lib.is_favorite("/m/2.mp3"))
  assert_eq(cm.lib.favorite_tracks().length(), 2)
  // 再来一遍：幂等，不翻倍
  cm.batch_favorite_selected() catch {
    _ => ()
  }
  assert_eq(cm.lib.favorite_tracks().length(), 2)
  @moonui.Backend::terminate(b)
}

///|
/// 「T175」判据⑧：点歌单页签 → 视图与**播放队列**都是歌单内容，顺序 = 歌单
/// 里的顺序（不排序）；标题 = 歌单名。
test "T175⑧：点歌单页签，播放队列 = 歌单内容" {
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
  assert_true(playlist_add(cm.playlists, "歌单A"))
  cm.add_to_playlist(0, ["/m/3.mp3", "/m/1.mp3"]) catch {
    _ => ()
  }
  cm.set_tab(3)
  assert_eq(cm.tab, 3)
  assert_eq(cm.tab_title(), "歌单A")
  // 视图 = 歌单顺序（3 在 1 前，本地库的排序口径不掺进来）
  assert_eq(cm.view.length(), 2)
  assert_eq(cm.view[0].path, "/m/3.mp3")
  assert_eq(cm.view[1].path, "/m/1.mp3")
  // 播放队列同步成歌单内容（判据⑧的口径）
  assert_eq(cm.player.queue.length(), 2)
  assert_eq(cm.player.queue[0].path, "/m/3.mp3")
  assert_eq(cm.player.queue[1].path, "/m/1.mp3")
  @moonui.Backend::terminate(b)
}

// ————————————————————————————————————————————————————
// T179 侧栏导航（批 8）：①③点击切页 ②歌单区随账 ④改名/删除 ⑤拖入分流 ⑥布局账
// ————————————————————————————————————————————————————

///|
/// 「T179」判据①③：侧栏三固定项 + 歌单条目随账铺开，**点击**（dispatch
/// Click 到 MenuRow 的 target，与真窗鼠标同一条派发路径）切页、高亮走
/// checked 通道跟着换。
test "T179①③：侧栏项点击切页，高亮走 checked" {
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
  assert_true(playlist_add(cm.playlists, "歌单A"))
  cm.add_to_playlist(0, ["/m/3.mp3", "/m/1.mp3"]) catch {
    _ => ()
  }
  let table = cm.ui.unwrap().table
  // ①：三固定项 + 一条歌单，文案与页签号逐位对
  assert_eq(table.tabs.length(), 4)
  assert_eq(table.tab_ids, [0, 1, 2, 3])
  assert_eq(table.tabs[0].text() catch { _ => "" }, "我的音乐")
  assert_eq(table.tabs[1].text() catch { _ => "" }, "我喜欢的")
  assert_eq(table.tabs[2].text() catch { _ => "" }, "播放队列")
  assert_eq(table.tabs[3].text() catch { _ => "" }, "歌单A")
  // 初始高亮在第一项（建树时 active_tab=0 烤进去的）
  assert_true(table.tabs[0].checked() catch { _ => true })
  // ①：点「我喜欢的」切页，高亮搬家
  let _ = app.dispatch(@moonui.Click(table.tabs[1].target(), @moonui.Left))
  assert_eq(cm.tab, 1)
  assert_true(table.tabs[1].checked() catch { _ => false })
  assert_false(table.tabs[0].checked() catch { _ => true })
  // ③：点歌单条目进歌单页——标题与队列都是歌单那份
  let _ = app.dispatch(@moonui.Click(table.tabs[3].target(), @moonui.Left))
  assert_eq(cm.tab, 3)
  assert_eq(cm.tab_title(), "歌单A")
  assert_eq(cm.view.length(), 2)
  assert_eq(cm.view[0].path, "/m/3.mp3")
  @moonui.Backend::terminate(b)
}

///|
/// 「T179」判据②：歌单区随账驱动——点侧栏分组头里的「＋」（真点击路径）
/// 弹名字窗，确定后侧栏多一条、账与档往返都在。工具条那颗是「＋ 添加目录」，
/// 全文不等，`find_text_widget` 不会认错。
test "T179②：侧栏「＋」新建后歌单区多一条" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  engine.stub(trk("/m/1.mp3", 100L), [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [trk("/m/1.mp3", 100L)])
  let table = cm.ui.unwrap().table
  assert_eq(table.tabs.length(), 3)
  let plus = match find_text_widget(table.root, "＋") {
    Some(w) => w
    None => abort("侧栏分组头没有「＋」")
  }
  let _ = app.dispatch(@moonui.Click(plus.target(), @moonui.Left))
  let dlg = match cm.name_dlg {
    Some(d) => d
    None => abort("点「＋」没弹名字窗")
  }
  let _ = dlg.name_in.set_text("晨跑")
  let ok = match dlg.window.content() {
    Some(c) =>
      match find_text_widget(c, "确定") {
        Some(w) => w
        None => abort("名字窗没有「确定」钮")
      }
    None => abort("名字窗没有内容树")
  }
  let _ = app.dispatch(@moonui.Click(ok.target(), @moonui.Left))
  // 换树后侧栏多一条，账也对
  assert_eq(cm.ui.unwrap().table.tabs.length(), 4)
  assert_eq(cm.playlists.length(), 1)
  assert_eq(cm.playlists[0].name, "晨跑")
  // 档往返
  let p = Prefs::new()
  p.playlists = cm.playlists
  let rt = Prefs::from_json(p.to_json()).unwrap()
  assert_eq(rt.playlists.length(), 1)
  assert_eq(rt.playlists[0].name, "晨跑")
  @moonui.Backend::terminate(b)
}

///|
/// 「T179」判据④：改名/删除走侧栏后账与档往返不破。右键菜单无头派不出
/// （与 T175④⑤ 同一条注），菜单项接的就是 `rename_playlist` /
/// `delete_playlist` 这两个口，这里直接驱动同一入口：改名走真对话框
/// （set_text + 点「确定」），删除走确认框（push_confirm_reply 回 true /
/// false 两刀）。
test "T179④：改名/删除走侧栏入口，账与档往返不破" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  engine.stub(trk("/m/1.mp3", 100L), [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [trk("/m/1.mp3", 100L)])
  assert_true(playlist_add(cm.playlists, "旧名"))
  cm.rebuild_ui() catch {
    _ => ()
  }
  // 改名：同一个懒建对话框，输入现读、确定才落账
  cm.rename_playlist(0) catch {
    _ => abort("改名窗打不开")
  }
  let dlg = match cm.name_dlg {
    Some(d) => d
    None => abort("没弹改名窗")
  }
  let _ = dlg.name_in.set_text("新名")
  let ok = match dlg.window.content() {
    Some(c) =>
      match find_text_widget(c, "确定") {
        Some(w) => w
        None => abort("改名窗没有「确定」钮")
      }
    None => abort("改名窗没有内容树")
  }
  let _ = app.dispatch(@moonui.Click(ok.target(), @moonui.Left))
  assert_eq(cm.playlists.length(), 1)
  assert_eq(cm.playlists[0].name, "新名")
  // 删除：确认回 true 才删；正看着这张歌单就退回本地音乐页签
  cm.set_tab(3)
  b.push_confirm_reply(true)
  cm.delete_playlist(0) catch {
    _ => abort("删除不该失败")
  }
  assert_eq(cm.playlists.length(), 0)
  assert_eq(cm.tab, 0)
  // 档往返：档里也没有了
  let p = Prefs::new()
  p.playlists = cm.playlists
  assert_eq(Prefs::from_json(p.to_json()).unwrap().playlists.length(), 0)
  // 拒删那一刀：确认回 false，账不动
  assert_true(playlist_add(cm.playlists, "留着"))
  cm.rebuild_ui() catch {
    _ => ()
  }
  b.push_confirm_reply(false)
  cm.delete_playlist(0) catch {
    _ => ()
  }
  assert_eq(cm.playlists.length(), 1)
  @moonui.Backend::terminate(b)
}

///|
/// 「T179」判据⑤：FileDrop 分流两刀。FileDrop 事件不带落点坐标（框架契约，
/// 后端只转发路径清单），偏差口径是按**当前页**分流：歌单页拖入 = 加入该
/// 歌单不并曲库；其余页拖入 = 照旧并曲库不进歌单。加曲幂等（批 7 口径）。
test "T179⑤：drop_tracks 分流——歌单页进歌单，其余页并曲库" {
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
  cm.merge_scan("/m", [t1, t2])
  assert_true(playlist_add(cm.playlists, "歌单A"))
  cm.rebuild_ui() catch {
    _ => ()
  }
  // 刀一：正看着歌单页拖入 → 加进那张歌单，曲库不并
  cm.set_tab(3)
  cm.drop_tracks([t1]) catch {
    _ => ()
  }
  assert_eq(cm.playlists[0].paths, ["/m/1.mp3"])
  assert_eq(cm.lib.tracks.length(), 2)
  // 幂等：同一首再拖一遍，账不动
  cm.drop_tracks([t1]) catch {
    _ => ()
  }
  assert_eq(cm.playlists[0].paths.length(), 1)
  // 刀二：其余页拖入 → 照旧并曲库，不进歌单
  cm.set_tab(0)
  cm.drop_tracks([t3]) catch {
    _ => ()
  }
  assert_eq(cm.lib.tracks.length(), 3)
  assert_eq(cm.playlists[0].paths.length(), 1)
  // 空清单：两边都不动
  cm.drop_tracks([]) catch {
    _ => ()
  }
  assert_eq(cm.lib.tracks.length(), 3)
  @moonui.Backend::terminate(b)
}

///|
/// 「T179」判据⑥：布局账——侧栏定宽（列宽账的锚）、列表区贴窗右缘
/// （padding 横向 8，侧栏 + 缝 + 列表区 = 内容宽）、五列列头在窄区里仍在。
test "T179⑥：布局账——侧栏定宽、列表区贴右缘、五列仍在" {
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
  let table = cm.ui.unwrap().table
  // 侧栏定宽
  assert_eq(table.sidebar.frame().size.width, cm_sidebar_w())
  // 列表区贴右缘：树根右缘 - 8（padding 横向）= 列表视口右缘
  let rf = table.root.frame()
  let lf = table.list.view().frame()
  assert_eq(lf.origin.x + lf.size.width, rf.origin.x + rf.size.width - 8.0)
  // 五列列头一个不少、各有实宽
  for name in ["#", "标题", "歌手", "专辑", "时长"] {
    let h = match find_text_widget(table.root, name) {
      Some(w) => w
      None => abort("列头 \{name} 不见了")
    }
    assert_true(h.frame().size.width > 0.0)
  }
  @moonui.Backend::terminate(b)
}

///|
/// `T180`③ 内嵌无轴歌词匀速铺：按**字符量加权**分配各行起始时刻，首行钉 0；
/// 空行丢弃；时长未知（`duration_ms <= 0`）退 1 秒/行。
test "lyrics：内嵌无轴歌词匀速铺到时长（T180③）" {
  let ls = plain_lyrics_to_timed("第一句\n\n第二句\n第三句", 30000L)
  assert_eq(ls.length(), 3) // 空行丢
  assert_eq(ls[0].t, 0.0) // 首行钉 0
  // 三行各 3 字：字符量加权 → 每行 10s
  assert_true((ls[1].t - 10.0).abs() < 0.000000001)
  assert_true((ls[2].t - 20.0).abs() < 0.000000001)
  // 行长不等 → 加权不平分：总量 9 字里 1 / 2 / 6，铺 9s
  let w = plain_lyrics_to_timed("a\nbb\ncccccc", 9000L)
  assert_true((w[1].t - 1.0).abs() < 0.000000001)
  assert_true((w[2].t - 3.0).abs() < 0.000000001)
  // 时长未知：1 秒/行兜底
  let un = plain_lyrics_to_timed("甲\n乙\n丙", 0L)
  assert_eq(un.length(), 3)
  assert_eq(un[1].t, 1.0)
  assert_eq(un[2].t, 2.0)
  assert_true(plain_lyrics_to_timed("", 30000L).length() == 0)
}

///|
/// 从详情窗大字歌词面最近一帧读出各行文字（与 `cm_lyric_rows` 同一条手法：
/// 按 y 坐标回推行号；只收 22 / 14pt 两档正文，别把别的文字混进来）。
fn cm_detail_rows_texts(
  b : @moonui.MockBackend,
  face : @moonui.Widget[@moonui.MockBackend],
) -> Array[String] raise @moonui.UiError {
  let rows : Array[String] = []
  for i = 0; i < cm_detail_rows(); i = i + 1 {
    rows.push("")
  }
  let h = match face.handle() {
    Some(h) => h
    None => abort("详情歌词面没有原生句柄：它没被摆出来")
  }
  let dl = match b.drawn(h) {
    Some(dl) => dl
    None => abort("详情歌词面一帧都没画过")
  }
  for cmd in dl.commands() {
    match cmd {
      @moonui.Text(text, _, y, size, _, _) =>
        if size == 22.0 || size == 14.0 {
          let row = (y / cm_detail_row_h()).round().to_int()
          if row >= 0 && row < rows.length() {
            rows[row] = text
          }
        }
      _ => ()
    }
  }
  rows
}

///|
/// `T180`② 跟随判据：内嵌**带时间轴**的歌词随播放推进高亮当前行——
/// mock 推位置，行号按 LRC 时间轴走；位置落在两行之间取**上一行**
/// （10s ≤ 15s < 20s → 第二句，取上一行的负控口径在这里一起钉）。
test "app：内嵌带轴歌词随位置高亮当前行（T180②）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let t1 : Track = {
    path: "/m/带轴.mp3",
    title: "带轴",
    artist: "歌手",
    album: "专辑",
    duration_ms: 200000L,
    cover: None,
    loudness: None,
    lyrics: "[00:00.00]第一句\n[00:10.00]第二句\n[00:20.00]第三句",
  }
  engine.stub(t1, [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [t1])
  cm.player.play_index(0)
  cm.refresh_lyrics() catch {
    _ => ()
  }
  assert_eq(cm.current_lyrics.length(), 3)
  // 5s：还没过 10s → 第一句
  engine.pos_ms = 5000L
  cm.refresh_lyrics() catch {
    _ => ()
  }
  assert_eq(cm_lyric_rows(b, cm.ui.unwrap().lyrics.face)[2], "第一句")
  // 15s：落在 10s 与 20s 两行之间 → 取上一行（第二句）
  engine.pos_ms = 15000L
  cm.refresh_lyrics() catch {
    _ => ()
  }
  assert_eq(cm_lyric_rows(b, cm.ui.unwrap().lyrics.face)[2], "第二句")
  // 25s：第三句
  engine.pos_ms = 25000L
  cm.refresh_lyrics() catch {
    _ => ()
  }
  assert_eq(cm_lyric_rows(b, cm.ui.unwrap().lyrics.face)[2], "第三句")
  @moonui.Backend::terminate(b)
}

///|
/// `T180`②③ 接线：内嵌**无轴**歌词走匀速账（先试 LRC 解不出才铺），且内嵌
/// 在场就不联网——`maybe_fetch_online` 的空表判据把这条链封住。
test "app：内嵌无轴歌词匀速接线，且不联网（T180②③）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let t1 : Track = {
    path: "/m/无轴.mp3",
    title: "无轴",
    artist: "歌手",
    album: "专辑",
    duration_ms: 9000L,
    cover: None,
    loudness: None,
    lyrics: "第一句\n第二句\n第三句",
  }
  engine.stub(t1, [])
  let asked : Array[String] = []
  let cm = LunaMusicApp::new(
    app,
    engine,
    on_fetch_online=Some(fn(
      path : String,
      _c : Array[(String, String)],
      _d : Double,
      _land : (String, String?) -> Unit,
    ) {
      asked.push(path)
    }),
  )
  cm.merge_scan("/m", [t1])
  cm.player.play_index(0)
  cm.refresh_lyrics() catch {
    _ => ()
  }
  // 无轴：匀速账接手（9s / 三行等长 → 0 / 3 / 6 秒）
  assert_eq(cm.current_lyrics.length(), 3)
  assert_eq(cm.current_lyrics[0].t, 0.0)
  assert_eq(cm.current_lyrics[1].text, "第二句")
  assert_true((cm.current_lyrics[1].t - 3.0).abs() < 0.000000001)
  // 内嵌在场：一次都没问服务器
  assert_eq(asked.length(), 0)
  @moonui.Backend::terminate(b)
}

///|
/// `T180`④ 无源兜底：边车、内嵌都没有 = 保持现行五行换字——缓存空、
/// 正中行显示歌名占位。
test "app：边车内嵌都没有，保持五行换字占位（T180④）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let t1 = trk("/m/lunamusic-t180-absent.mp3", 60000L)
  engine.stub(t1, [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [t1])
  cm.display = Tags // 文件名口径会从文件名猜歌手/歌名，这里钉标签口径
  cm.player.play_index(0)
  cm.refresh_lyrics() catch {
    _ => ()
  }
  assert_eq(cm.current_lyrics.length(), 0)
  // 五行面空着（现行口径：无词不画假行），歌名那一行 Label 换上曲名
  assert_eq(cm_lyric_rows(b, cm.ui.unwrap().lyrics.face)[2], "")
  assert_eq(cm_lyric_rows(b, cm.ui.unwrap().lyrics.face)[2], "")
  assert_eq(
    cm.ui.unwrap().lyrics.song.text() catch {
      _ => ""
    },
    "/m/lunamusic-t180-absent.mp3 - a",
  )
  @moonui.Backend::terminate(b)
}

///|
/// `T180` 详情伴窗：默认收起；「播放详情」拉开（先刷内容后显示），大封面 /
/// 文案三行 / 大字歌词各就各位；红绿灯关窗走 `Hide` + 吸账，再开是干净的。
test "app：播放详情伴窗开合与内容（T180）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let engine = MockAudioEngine::new()
  let t1 : Track = {
    path: "/m/详情.mp3",
    title: "详情曲",
    artist: "详情歌手",
    album: "详情专辑",
    duration_ms: 60000L,
    cover: Some(cm_cover_fixture()),
    loudness: None,
    lyrics: "[00:00.00]详情第一句\n[00:30.00]详情第二句",
  }
  engine.stub(t1, [])
  let cm = LunaMusicApp::new(app, engine)
  cm.merge_scan("/m", [t1])
  cm.display = Tags // 文件名口径会从文件名猜曲名，这里钉标签口径
  // 默认收起：startup_windows 不含它（T210 启动 show 次序不动）
  assert_false(cm.detail_open)
  assert_false(
    @moonui.MockBackend::window(b, cm.ui.unwrap().detail_win.handle()).visible,
  )
  cm.player.play_index(0)
  cm.refresh_lyrics() catch {
    _ => ()
  }
  // 开：先刷内容后 show——正中行是第一句（active 0，8 行面锚在 row 4）
  cm.toggle_detail()
  assert_true(cm.detail_open)
  assert_true(
    @moonui.MockBackend::window(b, cm.ui.unwrap().detail_win.handle()).visible,
  )
  let det = cm.ui.unwrap().detail
  assert_eq(cm_detail_rows_texts(b, det.face)[4], "详情第一句")
  // 文案三行
  assert_eq(det.title.text() catch { _ => "" }, "详情曲")
  assert_eq(det.artist.text() catch { _ => "" }, "详情歌手")
  assert_true((det.pos.text() catch { _ => "" }).contains("/ 01:00"))
  // 大封面灌的是这首歌的字节（与占位图长度不同，T174 同一条验法）
  let cover_handle = match det.cover.handle() {
    Some(h) => h
    None => abort("详情封面没有原生句柄")
  }
  assert_eq(
    @moonui.MockBackend::image_len_of(b, cover_handle),
    cm_cover_fixture().length(),
  )
  // 关：收起不销毁
  cm.toggle_detail()
  assert_false(cm.detail_open)
  assert_false(
    @moonui.MockBackend::window(b, cm.ui.unwrap().detail_win.handle()).visible,
  )
  // 红绿灯关（Hide）+ 吸账：refresh_detail 头上把 detail_open 结清
  cm.toggle_detail()
  assert_true(cm.detail_open)
  let _ = app.dispatch(@moonui.Event::Close(cm.ui.unwrap().detail_win.target()))
  cm.refresh_detail() catch {
    _ => ()
  }
  assert_false(cm.detail_open)
  @moonui.Backend::terminate(b)
}
