///|
/// lunamusic 的双后端共享壳（§52.5 分期③，T98③d）：本文件是**唯一碰音频
/// ABI 的 MoonBit 代码**——NativeAudioEngine 把 lunamusic 的 AudioEngine
/// trait 转到 native-common 的 audio extern。装配（曲库档/偏好档/菜单栏/
/// 进度心跳/拖入）与后端无关，`launch` 收一只现成的 App：原生壳
/// （../lunamusic-native）与自绘壳（../lunamusic-canvas-native）各自
/// 构造后端后共用这里。

///|
/// NativeAudioEngine：AudioEngine → moonui_native_audio_*（adapter.h 音频段）。
/// load 合成「装歌 + 读元数据」两口（C-06）：先探针拿 Track（读不出退文件名），
/// 再把歌装进播放器。
priv enum NativeAudioEngine {
  Instance
} // 进程级单例：播放器在 C 侧，MoonBit 这侧只是 trait 的载体

///|
fn probe_track(path : String) -> @lunamusic.Track {
  match @native-common.native_audio_probe(path) {
    Some(packed) =>
      match @lunamusic.track_from_probe(path, packed) {
        Some(t) => t
        None => @lunamusic.Track::from_path(path)
      }
    None => @lunamusic.Track::from_path(path)
  }
}

///|
impl @lunamusic.AudioEngine for NativeAudioEngine with fn load(
  _ : NativeAudioEngine,
  path : String,
) -> @lunamusic.Track raise @lunamusic.AudioError {
  let track = probe_track(path)
  let rc = @native-common.native_audio_load(path)
  if rc != 0 {
    raise @lunamusic.AudioError::LoadFailed(path)
  }
  track
}

///|
impl @lunamusic.AudioEngine for NativeAudioEngine with fn play(
  _ : NativeAudioEngine,
) -> Unit raise @lunamusic.AudioError {
  if @native-common.native_audio_play() != 0 {
    raise @lunamusic.AudioError::PlayFailed("play")
  }
}

///|
impl @lunamusic.AudioEngine for NativeAudioEngine with fn pause(
  _ : NativeAudioEngine,
) -> Unit {
  let _ = @native-common.native_audio_pause()
}

///|
impl @lunamusic.AudioEngine for NativeAudioEngine with fn unpause(
  _ : NativeAudioEngine,
) -> Unit raise @lunamusic.AudioError {
  if @native-common.native_audio_play() != 0 {
    raise @lunamusic.AudioError::PlayFailed("unpause")
  }
}

///|
impl @lunamusic.AudioEngine for NativeAudioEngine with fn stop(
  _ : NativeAudioEngine,
) -> Unit {
  let _ = @native-common.native_audio_stop()
}

///|
impl @lunamusic.AudioEngine for NativeAudioEngine with fn seek(
  _ : NativeAudioEngine,
  ms : Int64,
) -> Unit {
  let _ = @native-common.native_audio_seek_ms(ms)
}

///|
impl @lunamusic.AudioEngine for NativeAudioEngine with fn position(
  _ : NativeAudioEngine,
) -> Int64 {
  @native-common.native_audio_position_ms()
}

///|
impl @lunamusic.AudioEngine for NativeAudioEngine with fn duration(
  _ : NativeAudioEngine,
) -> Int64 {
  @native-common.native_audio_duration_ms()
}

///|
impl @lunamusic.AudioEngine for NativeAudioEngine with fn set_volume(
  _ : NativeAudioEngine,
  permille : Int32,
) -> Unit {
  let _ = @native-common.native_audio_set_volume(permille)
}

///|
impl @lunamusic.AudioEngine for NativeAudioEngine with fn is_playing(
  _ : NativeAudioEngine,
) -> Bool {
  @native-common.native_audio_is_playing()
}

///|
impl @lunamusic.AudioEngine for NativeAudioEngine with fn set_rate(
  _ : NativeAudioEngine,
  permille : Int32,
) -> Unit {
  // 返回 -3（本平台没接）就静默收下：UI 那颗菜单项照常能点，只是不起作用
  let _ = @native-common.native_audio_set_rate(permille)
}

///|
impl @lunamusic.AudioEngine for NativeAudioEngine with fn rate(
  _ : NativeAudioEngine,
) -> Int32 {
  @native-common.native_audio_rate()
}

///|
impl @lunamusic.AudioEngine for NativeAudioEngine with fn on_finished(
  _ : NativeAudioEngine,
  cb : () -> Unit,
) -> Unit {
  let _ = @native-common.native_audio_on_finished(Some(cb))
}

///|
impl @lunamusic.AudioEngine for NativeAudioEngine with fn level(
  _ : NativeAudioEngine,
  band : Int32,
) -> Int32 {
  @native-common.native_audio_level(band)
}

///|
impl @lunamusic.AudioEngine for NativeAudioEngine with fn eq_band_count(
  _ : NativeAudioEngine,
) -> Int32 {
  @native-common.native_audio_eq_band_count()
}

///|
/// 整张表一次推下去：逐段 set + 开关。段数为 0（Windows 半）时什么都不做——
/// 那边没有 EQ，UI 侧也不画滑块。
impl @lunamusic.AudioEngine for NativeAudioEngine with fn eq_apply(
  _ : NativeAudioEngine,
  bands : Array[Int32],
  enabled : Bool,
) -> Unit {
  for i, g in bands {
    let _ = @native-common.native_audio_eq_set_band(i, g)
  }
  let _ = @native-common.native_audio_eq_set_enabled(enabled)
}

///|
/// 心跳周期（`T152`）：500ms 一拍，与 `examples/lunamusic/DESIGN.md` 的
/// C-08 进度推进口径一致。抽成常量是因为它现在同时是**定时投递的间隔**：
/// 主循环按它算等待上限（下一拍什么时候醒），不再只是"刷得勤不勤"。
const HEARTBEAT_MS : Int32 = 500

///|
/// 频谱帧间隔（`T155`）：30fps。它是频谱链的**自续间隔**，也是主循环等待
/// 上限的下界——静止的频谱不续链，所以这条不会把空闲的 GUI 拖成 30fps 唤醒。
const VIZ_FRAME_MS : Int32 = 33

///|
/// 33ms 频谱链（`T155`）的**时刻锚点**盒子。
///
/// `T198` 之前这里是两只装满解环机关的盒子（`TickBox`/`VizBox`：装闭包的
/// `arm` 让任务能"再 post 自己"，加一个 `live` 布尔挡重复点火）。自续、停续与
/// 幂等点火都收进了 `@moonui.Ticker`，新壳里只剩频谱这一格：帧间隔按**实测**
/// 算，不是常量——主循环被别的事情拖住时，实际隔了多久就得按多久算，否则动画
/// 在慢机器上看起来是"卡一下再猛跳"。
priv struct VizBox {
  mut last_ms : Int32
}

///|
/// 离屏取证的拍数盒子：自续到第 N 拍再截图（自续那一半归 `Ticker`，这里只数拍）。
priv struct ShotBox {
  mut n : Int32
}

///|
/// worker 与 UI 线程间的扫描结果盒子（work 写、land 读，一次扫描一只）。
priv struct FoundBox {
  mut v : Array[@lunamusic.Track]
}

///|
/// 添加目录回调的转发盒：cm 构造要这个回调、回调要 cm——解环用。
priv struct AddDirBox {
  mut fire : (() -> Unit)?
}

///|
/// 手动重扫回调的转发盒（`T172`，同 AddDirBox 的解环手法）。
priv struct RescanBox {
  mut fire : (() -> Unit)?
}

///|
/// 皮肤「加载目录」回调的转发盒（同 AddDirBox 的解环手法）。
priv struct SkinDirBox {
  mut fire : (() -> Unit)?
}

///|
/// 皮肤「导出」回调的转发盒：参数是当前皮肤的 JSON 文本。
priv struct SkinSaveBox {
  mut fire : ((String) -> Unit)?
}

///|
/// worker 与 UI 线程间的皮肤路径盒子（work 写、land 读）。
priv struct SkinPathsBox {
  mut v : Array[String]
}

///|
/// 曲库档即时落盘的转发盒（同 AddDirBox 的解环手法）：`on_library_changed`
/// 要读 `cm.lib`，而 `cm` 的构造又要这个回调。
priv struct LibSaveBox {
  mut fire : (() -> Unit)?
}

///|
fn home_dir() -> String {
  @env.get_env_var("HOME").unwrap_or("/tmp")
}

///|
fn library_path() -> String {
  home_dir() + "/.lunamusic-library.json"
}

///|
/// 偏好档（C-07）：与曲库档分开——曲库是数据账，偏好是状态账。
fn prefs_path() -> String {
  home_dir() + "/.lunamusic-prefs.json"
}

///|
/// 按已在档里的目录清单重扫一遍并替换曲库（`T142`：旧档裸文件名修补用）。
/// 走与「＋ 添加目录」同一条行走+探针链，只是不加新目录、只把既有目录重扫
/// 到的新结果当曲库本体。扫不出任何东西的目录（被删掉/权限变了）静默跳过，
/// 不把用户已有的条目清空。
fn[B, A] rebuild_from_dirs(cm : @lunamusic.LunaMusicApp[B, A]) -> Unit {
  let fresh = @lunamusic.Library::new()
  for dir in cm.lib.dirs {
    let paths = @lunamusic.scan_tree(dir)
    let found : Array[@lunamusic.Track] = []
    for p in paths {
      found.push(probe_track(p))
    }
    if found.length() > 0 {
      fresh.merge(dir, found)
    }
  }
  if fresh.tracks.length() > 0 {
    // 收藏按 path 记：重扫后 path 换成绝对路径，两边都对一遍尾段
    for t in fresh.tracks {
      let segs = t.path.split("/").to_array()
      let tail = segs[segs.length() - 1].to_owned()
      for f in cm.lib.favorites {
        let fs = f.split("/").to_array()
        if fs[fs.length() - 1].to_owned() == tail {
          fresh.favorites.push(t.path)
          break
        }
      }
    }
    cm.lib = fresh
  }
}

///|
/// 应用装配：窗口几何恢复、曲库/偏好档、菜单栏、进度心跳、拖入——
/// 后端无关（B 只要是 Backend）。收尾（存档）在返回前做完。
pub fn[B : @moonui.Backend] launch(
  app : @moonui.App[B],
) -> Unit raise @moonui.UiError {
  // 应用图标：自绘的 Luna 原创标志 256x256（stem 约定，mac 补 .png、
  // Windows 补 .ico——两份都在 assets/logo/）
  app.set_icon("assets/logo/luna")
  let engine : NativeAudioEngine = Instance
  // 注入真行走（wasm/测试侧恒空，这是唯一接通 C 的一处）
  @lunamusic.set_walk_dir(fn(p) { @native-common.native_walk_dir(p) })
  // 窗口几何档（C-07）：启动恢复，退出保存
  let frame = app.load_window_state(library_path() + ".window") catch {
    _ => None
  }
  // 添加目录回调经盒子转发：闭包要引用 cm，而 cm 构造又要这个回调——
  // 局部 fn 没法向前引用，用可变盒子解环（与 TickBox 同款手法）
  let add_dir_box : AddDirBox = { fire: None, }
  let rescan_box : RescanBox = { fire: None, }
  let skin_dir_box : SkinDirBox = { fire: None, }
  let skin_save_box : SkinSaveBox = { fire: None, }
  let lib_save_box : LibSaveBox = { fire: None, }
  let cm = @lunamusic.LunaMusicApp::new(
    app,
    engine,
    frame~,
    on_add_dir=fn() { add_dir_box.fire.unwrap()() },
    // 手动重扫（`T172`）：按已有目录整份重走行走 + 探针，替换曲库本体
    on_rescan=fn() { rescan_box.fire.unwrap()() },
    // 批量探测（导入 m3u 用）：走原生元数据探针，与扫描同一条链路
    probe_many=fn(paths : Array[String]) -> Array[@lunamusic.Track] {
      let out : Array[@lunamusic.Track] = []
      for p in paths {
        out.push(probe_track(p))
      }
      out
    },
    // 皮肤：加载目录 / 导出当前皮肤（换肤要读文件与弹面板，都在壳这一侧）
    on_load_skin_dir=fn() { skin_dir_box.fire.unwrap()() },
    on_save_skin=fn(text : String) { skin_save_box.fire.unwrap()(text) },
    // 在线取词（`T158`）：本地没 .lrc 时问 lrclib.net。整条走 worker 线程
    // （网络层与线程模型的账在 online_lyrics.mbt 的文件头），这里只转一手。
    on_fetch_online=Some(fn(
      path : String,
      candidates : Array[(String, String)],
      duration_s : Double,
      land : (String, String?) -> Unit,
    ) {
      fetch_online_lyrics(app, path, candidates, duration_s, land)
    }),
    // 手动搜索歌词（`T161`①）：用户在歌词秀顶条点「搜索歌词」时走这条。
    // 与上面那条共用 worker 线程与 UA，但只发一条 `/api/search`、全列结果。
    on_search_lyrics=Some(fn(
      title : String,
      artist : String,
      land : (Array[@lunamusic.LyricSearchResult]) -> Unit,
    ) {
      fetch_lyric_search(app, title, artist, land)
    }),
    // 歌曲信息写回（`C-16`）：读文件 → 纯逻辑改标签 → 原子落回。
    // 三步 match：任何一步失败都返回失败且**一个字节都不写**——
    // 写坏一个音频文件比不改更糟。
    write_tags=fn(
      path : String,
      title : String,
      artist : String,
      album : String,
    ) -> @lunamusic.TagWriteResult {
      let data = @moonui.Fs::read_bytes(path) catch {
        e => return Failed(@moonui.UiError::message(e))
      }
      let data = match data {
        Some(d) => d
        None => return Failed("读不出文件：\{path}")
      }
      let (out, result) = @lunamusic.cm_write_tags(data, title, artist, album)
      match result {
        Written =>
          @moonui.Fs::write_bytes_atomic(path, out) catch {
            e => return Failed(@moonui.UiError::message(e))
          }
        _ => ()
      }
      result
    },
    // 曲库档立刻落盘：档本来只在退出时存一次，恢复时又是"直接入账不重探"，
    // 不马上写的话下次启动会读回旧标题（`C-16`）。
    on_library_changed=fn() { lib_save_box.fire.unwrap()() },
  )
  lib_save_box.fire = Some(fn() {
    @moonui.Fs::write_text_atomic(library_path(), cm.lib.to_json().stringify()) catch {
      _ => println("曲库档没存上")
    }
  })
  // 添加目录（工具条按钮）：系统面板选目录 → worker 扫描（不卡 UI）→ 回
  // UI 并入。走 on_add_dir 参数——rebuild_ui 每次换树都在新按钮上重接
  // （接在树外的按钮回调活不过重建，2026-10-16 的教训）
  // 手动重扫（`T172`，标题行那颗「⟳ 重扫」）：文件删了要重启才消失、改了
  // 标签得清库重来——这条把两个洞一起补上。**同步跑**：几十首的库是秒级，
  // 而挪进 worker 要按目录回传分组结果（`rebuild_from_dirs` 是按 dir 分组
  // merge 的），形状比这条功能本身大，等真遇到万首库再改。
  rescan_box.fire = Some(fn() {
    rebuild_from_dirs(cm)
    cm.player.replace_queue(cm.lib.tracks)
    // 按钮回调不许 raise 跨 C 帧：换树失败就在这里收口（与 hooks 里的同款）
    cm.rebuild_ui() catch {
      _ => ()
    }
    // 立刻落盘：重扫结果不马上写的话，下次启动读回的是重扫前的旧档
    (cm.on_library_changed)()
  })
  add_dir_box.fire = Some(fn() {
    // select_folder 的 raise 在这收口（按钮回调不许 raise 跨 C 帧）
    try {
      let picked = app.select_folder("选择音乐目录")
      match picked {
        Some(dir) => {
          let found_box : FoundBox = { v: [], }
          let _ = @native-common.worker_run(
            app,
            fn() {
              // worker 线程：纯 C 行走 + 探针，MoonBit 侧零解码
              let paths = @lunamusic.scan_tree(dir)
              let found : Array[@lunamusic.Track] = []
              for p in paths {
                found.push(probe_track(p))
              }
              found_box.v = found
            },
            fn() { cm.merge_scan(dir, found_box.v) catch { _ => () } },
          )
        }
        None => () // 用户取消/面板失败：安静退出
      }
    } catch {
      _ => () // 面板 raise：安静退出
    }
  })
  // 加载皮肤目录：系统面板选目录 → worker 扫皮肤档 → 逐个读文本交给 app
  // 解析。坏的（二进制 .skn / 坏 JSON）只是这一份不进菜单，不影响其它几份。
  skin_dir_box.fire = Some(fn() {
    try {
      let picked = app.select_folder("选择皮肤目录")
      match picked {
        Some(dir) => {
          let paths_box : SkinPathsBox = { v: [], }
          let _ = @native-common.worker_run(
            app,
            fn() { paths_box.v = @lunamusic.scan_skins(dir) },
            fn() {
              let mut ok = 0
              let mut bad = 0
              for p in paths_box.v {
                let text = @moonui.Fs::read_text(p) catch { _ => None }
                match text {
                  Some(t) =>
                    if cm.add_skin_file(p, t) {
                      ok = ok + 1
                    } else {
                      bad = bad + 1
                    }
                  None => bad = bad + 1
                }
              }
              println("皮肤目录：载入 \{ok} 份，跳过 \{bad} 份")
            },
          )
        }
        None => ()
      }
    } catch {
      _ => ()
    }
  })
  // 导出当前皮肤：保存面板给路径 → 写文本（与曲库档同一条 libc 落盘半）
  skin_save_box.fire = Some(fn(text : String) {
    try {
      match app.save_file("导出皮肤", "my-skin.skn") {
        Some(path) =>
          @moonui.Fs::write_text_atomic(path, text) catch {
            _ => println("皮肤没写出去：\{path}")
          }
        None => ()
      }
    } catch {
      _ => ()
    }
  })
  // 启动恢复曲库档（C-07：缓存直接入账，不重探）
  match @moonui.Fs::read_text(library_path()) {
    Some(text) =>
      match @lunamusic.Library::from_text(text) {
        Some(lib) => {
          cm.lib = lib
          // 旧档的裸文件名修补（`T142`）：`walk_dir` 曾把 `d_name` 当绝对路径
          // 上报，那时入库的 path 是 `夜曲.mp3`，装歌按相对路径永远找不到
          // （双击没反应）。C 侧已改，但缓存不重探，这里据裸名判一次重扫。
          // 裸名丢了子目录层级，纯逻辑猜不回来，只有重走目录才拿得准。
          // `T193`：探针修的旧账（整档 `未知`）同样靠重扫补——探针修好之前
          // 入账的 20 首全是文件名兜底，不重扫就永远显示不出来。
          if lib.has_bare_paths() || lib.has_unknown_artists() {
            rebuild_from_dirs(cm)
          }
          cm.player.replace_queue(cm.lib.tracks)
          cm.rebuild_ui()
        }
        None => println("曲库档解析失败，按空库起步")
      }
    None =>
      println(
        "第一次启动：添加一个目录开始（＋ 添加目录，或把音乐文件拖进窗口）",
      )
  }
  // 偏好档恢复（C-07）：音量/模式直接写播放器；最后播放只做高亮不自动播。
  // 档读不上（第一次启动/坏档）按默认偏好起步，不吭声。
  let prefs : @lunamusic.Prefs = match @moonui.Fs::read_text(prefs_path()) {
    Some(text) =>
      match @lunamusic.Prefs::from_text(text) {
        Some(p) => p
        None => @lunamusic.Prefs::new()
      }
    None => @lunamusic.Prefs::new()
  }
  cm.player.set_volume(prefs.volume)
  cm.player.mode = prefs.mode
  // 显示口径（`T193`）：默认文件名。要走 `set_display` 而不是直接赋
  // `cm.display`——它带一次重挂菜单栏，菜单上的打勾才对得上档里的值
  // （`install_menubar` 在下面还会再挂一次，这里多挂一回只多几个闭包）。
  cm.set_display(prefs.display)
  // 桌面歌词开关（`T195`）：档里记的是"用户想不想挂"。窗在 `new()` 里已经
  // 建好，这里只改开关位——下面第二趟 `rebuild_ui` 会走 `refresh_lyrics` →
  // `sync_desk_window` 按它收掉浮条，`startup_windows()` 也据此决定露不露头。
  cm.show_desk = prefs.show_desk
  // EQ 恢复：档里的十段直接推给引擎（关掉再打开 EQ 还在，与原版一致）
  for i = 0; i < cm.eq_bands.length(); i = i + 1 {
    if i < prefs.eq_bands.length() {
      cm.eq_bands[i] = prefs.eq_bands[i]
    }
  }
  cm.eq_on = prefs.eq_on
  cm.push_eq()
  // 皮肤恢复：先按内置名找，找不到就当皮肤档路径读（文件被删/改名 → 默认皮肤）
  if prefs.skin != "" {
    if !cm.set_skin_by_name(prefs.skin) {
      let text = @moonui.Fs::read_text(prefs.skin) catch { _ => None }
      match text {
        Some(t) =>
          if !cm.add_skin_file(prefs.skin, t) {
            println(
              "皮肤档读不懂，按默认皮肤起步：\{prefs.skin}",
            )
          }
        None =>
          println("皮肤档找不着，按默认皮肤起步：\{prefs.skin}")
      }
    }
  }
  match prefs.last_path {
    Some(p) => {
      // 在当前库里找这首：找到就**装上并定位到上次那一刻**（`T184`）。
      //
      // 装而**不播**——`prepare` 把状态记成 Paused，按 ▶ 从那儿继续。位置为 0
      // （旧档、或者上次是从头停的）走同一条路，装完就是"停在第 0 秒"。
      // 装不上（文件被删）时 `prepare` 记一条 `last_error` 就停，状态行会说
      // "无法播放：xxx"，而不是让启动看起来一切正常却没声。
      // 在**播放队列**里按 path 找（不是曲库下标）：`prepare` 的 idx 是队列
      // 下标，而队列在排序/搜索之后是视图那一份——拿曲库下标去喂它，一旦两者
      // 不同序就装到别的歌上（`T177` 那次"位置与身份分家"的同一条）。
      let mut hit = -1
      for i, t in cm.player.queue {
        if t.path == p {
          hit = i
          break
        }
      }
      if hit >= 0 {
        cm.player.prepare(hit, prefs.position_ms)
      }
    }
    None => ()
  }
  cm.rebuild_ui()
  // 首次呈现（`T122`）：树已定稿（曲库档/偏好/皮肤都恢复完，这里刚换完第二棵树），
  // 就趁这会儿把窗口露出来——菜单栏与托盘稍后装，它们不在客户区里，晚装不会被看见。
  // `rebuild_ui` 不再自己 show：那样窗口会在建树①之后立刻露出来，而后面还有读档、
  // 换树、装壳，到 `app.run()` 起跑之前没有消息泵，露出来的就是一块白板。
  for w in cm.startup_windows() {
    w.show()
  }
  // 菜单栏（C-03）：装一次；空格/⌘←/⌘→ 由带 shortcut 的菜单项自动注册
  // 成加速键，不再手动 register_shortcut（重复注册会一次按键两响应）
  cm.install_menubar() catch {
    _ => println("菜单栏装不上")
  }
  // 托盘（`T86⑥`）：图标 + 右键菜单（播放控制 / 迷你模式 / 桌面歌词 / 退出）
  cm.install_tray() catch {
    _ => println("托盘装不上")
  }
  // 滚轮调音量：整窗手势。C 侧滚轮恒报**窗口自己**（控件级滚轮消费者在原生
  // 后端上不存在，滚动归 NSScrollView），所以订阅主控窗这一条就够。
  let win_target = @moonui.EventTarget::of(cm.ui.unwrap().window.handle())
  let _ = app.on(
    win_target,
    fn(e : @moonui.Event) -> Bool { e is @moonui.Scroll(_, _) },
    fn(e : @moonui.Event) {
      match e {
        @moonui.Scroll(_, pt) => cm.wheel_volume(pt.y)
        _ => ()
      }
    },
  )
  // 拖文件进窗口（T86③ 的 FileDrop）：音频文件直接并入当前队列
  let target = @moonui.EventTarget::of(cm.ui.unwrap().window.handle())
  let _ = app.on(
    target,
    fn(e : @moonui.Event) -> Bool { e is @moonui.FileDrop(_, _) },
    fn(e : @moonui.Event) {
      match e {
        @moonui.FileDrop(_, paths) => {
          let found : Array[@lunamusic.Track] = []
          for p in paths {
            if @lunamusic.is_audio_file(p) {
              found.push(probe_track(p))
            }
          }
          if found.length() > 0 {
            cm.merge_scan("(拖入)", found) catch {
              _ => ()
            }
          }
        }
        _ => ()
      }
    },
  )
  // 进度心跳：500ms 一拍，只在播着时活着
  //
  // `T152`：节奏来自**定时**投递（`post_after` 那本账），不是 `post_task`。
  // 这条区别就是整条心跳的成败：`post_task` 的"下一圈"在真后端上等于"下一个
  // 原生事件"，没有事件就没有圈——心跳于是退化成"用户动一下鼠标跳一秒"，
  // 表现正是播放时进度读数几秒、十几秒才跳一次。
  //
  // `T198`：自续、停续、以及"别并出第二条链"三件事收进了 `@moonui.Ticker`，
  // 这里剩下的只是一个返回布尔的**任务体**：还在播就续，停了就收。以前要为
  // 此造一只 `TickBox` 装闭包解环（任务里 post 自己），再维护一个 `live` 布尔。
  let beat = @moonui.Ticker::new()
  let beat_tick = fn(_first) -> Bool raise @moonui.UiError {
    cm.refresh_bar()
    cm.refresh_lyrics()
    // 停播就收链（省唤醒）：条子回落那几拍现在归频谱链自己管（`T155`），
    // 这条只负责进度与歌词——它没有"余辉"。
    cm.player.is_playing()
  }
  // 频谱动画链（`T155`）：与进度心跳**分开**的那条 30fps 链。
  //
  // 为什么不还挂在 500ms 心跳上：频谱的能量每 500ms 才更新一次、柱子也在那一
  // 拍才动一次，那就是"每秒两帧"的台阶——旧版看着一格一格正是这个原因。现在
  // 读数按 33ms 一拍去问（引擎那侧本来就每帧写一次），显示值逐帧追过去（起音
  // 快、落音慢），落下与否由 `refresh_spectrum` 的返回值说话：都落定了就**不再
  // 续**，静止的频谱一个唤醒都不花。
  //
  // 仍然走定时账（`T152` 的口径）：`post_task` 的"下一圈"在真后端上等于
  // "下一个原生事件"，静止的窗口没有事件，动画链会被饿死。
  let viz = @moonui.Ticker::new()
  let viz_state : VizBox = { last_ms: 0, }
  // 点火器：两条链在停播时都自己收了，下一次播起来（on_play 边沿）在这里一起
  // 接上。`post_every` 本身幂等——已经在跑的那条这一发是空操作，不会并出第二
  // 条分支（以前靠 `live` 布尔挡的就是这件事）。
  //
  // 频谱的任务体就地写在这一处（心跳的在上面另起一条，因为它开局还要单独点
  // 一次火）：它把 `refresh_spectrum` 的失败吞在体内，**永不抛**，而 `post_every`
  // 要的是可抛的闭包——就地写能让效果按调用点推出来，不必为它编一个"其实不会
  // 抛"的 `raise` 注解（那会招来 unused_error_type）。
  cm.on_play = Some(fn() {
    let _ = app.post_every(beat, HEARTBEAT_MS, beat_tick)
    let _ = app.post_every(viz, VIZ_FRAME_MS, fn(first) {
      // 重启后的第一拍：把锚点清零，dt 按一拍算。不清的话 dt 是"上次停播到
      // 现在"的整段（几十秒），显示值当场跳到目标值——起音快落音慢那套动画
      // 被这一跳整个吃掉（`T198` 之前这一格由点火器在 `on_play` 里手动清）。
      if first {
        viz_state.last_ms = 0
      }
      let now = @native-common.native_time_ms()
      let dt = if viz_state.last_ms == 0 {
        VIZ_FRAME_MS
      } else {
        let d = now - viz_state.last_ms
        // 首帧 / 时钟倒跳兜底：给一拍的默认值，不让 dt 变成 0（0 会让显示值
        // 原地不动，动画永远走不出去）。
        if d > 0 {
          d
        } else {
          VIZ_FRAME_MS
        }
      }
      viz_state.last_ms = now
      let playing = cm.player.is_playing()
      let moving = cm.refresh_spectrum(dt) catch { _ => false }
      // 在播就一直在跑（进度换、读数换，条子每帧都得追）；停播只在还没落定时
      // 再跑几帧。`spectrum_lit` 还剩 true 而柱值已经落定是不可能的——落定之后
      // 的帧会把它清掉（见 `refresh_spectrum` 里 `any || moving` 那行）。
      playing || moving
    })
  })
  // 开机先给心跳一拍：首屏的进度条与歌词按当下状态刷一次（没在播就当场收链，
  // 等 `on_play` 再点火）。频谱链要等真有声音才有读数，不在这里点。
  let _ = app.post_every(beat, HEARTBEAT_MS, beat_tick)
  println(
    "真窗口已打开：选目录扫描、双击播放、关窗口退出（档自动存 \{library_path()}）",
  )
  // 离屏取证（开发用）：MOONUI_SHOT_DIR=/tmp/x 时，先跑几拍让布局与首帧落定，
  // 再把每个窗口渲成 PNG（外加一份原生视图树 views.txt）并退出。
  // `screencapture` 在沙箱/无头环境里只能拍到全黑（没有屏幕录制权限），视图
  // 自绘这条能拿到真像素。没设这个环境变量时整段不执行，正常启动路径不受影响。
  // 要单窗对账时另开 `MOONUI_BOUNDS_TRACE=1`（adapter 会把每次 set_bounds 的
  // 进参与落点打出来）。
  match @env.get_env_var("MOONUI_SHOT_DIR") {
    Some(dir) => {
      // 拍第 3 拍就够：布局第 2 拍已经落定。以前写 12 是想等频谱/歌词的首帧，
      // 但那 9 圈每圈都要等一次 AppKit 的事件（没播放时事件很稀）——`T152`
      // 之前这条链同样是"蹭事件"的，真机上能把"截个图"拖成十几秒，看起来就
      // 像卡死。现在走定时投递，每拍 16ms 自己醒，与有没有输入无关。
      let want = 3
      let shot_count : ShotBox = { n: 0, }
      let _ = app.post_every(@moonui.Ticker::new(), 16, fn(_first) {
        shot_count.n = shot_count.n + 1
        if shot_count.n >= want {
          let n = @native-common.native_snapshot_all(dir)
          println("离屏取证：\{n} 张 → \{dir}")
          app.quit()
          false
        } else {
          true
        }
      })
    }
    None => ()
  }
  // 首次呈现已在上面 `rebuild_ui()` 之后做过（`T122`）；这里直接进主循环。
  app.run()
  // 退出收尾：曲库档 + 偏好档 + 窗口档（C-07）
  // `T195`：先把"刚关掉浮条"这一笔结掉再存档——心跳只在播着时跑，暂停时
  // 关窗后直接退出，不结账就会把 `show_desk` 记成 true，下次又挂回来。
  cm.absorb_desk_close()
  // 偏好档记当前音量/模式/正在放的那首**与播到哪儿**（`T184`）。
  //
  // `last_path` 与 `position_ms` 必须来自**同一首**：早先按 `cm.lib.tracks[ci]`
  // 取 path，那假设播放队列与曲库同序——排序/搜索/切页签之后队列是视图那份，
  // 下标会指到别的歌。`player.track()` 直接给队列里那首，位置也是它自己的。
  let cur = cm.player.track()
  let last_path : String? = match cur {
    Some(t) => Some(t.path)
    None => None
  }
  let position_ms = match cur {
    Some(_) => cm.player.position()
    None => 0L
  }
  let prefs_out : @lunamusic.Prefs = {
    volume: cm.player.volume,
    mode: cm.player.mode,
    last_path,
    position_ms,
    eq_bands: cm.eq_bands,
    eq_on: cm.eq_on,
    skin: cm.skin_id(),
    display: cm.display,
    // `T195`：关掉浮条的意图进档，下次启动仍按关闭起步（菜单/托盘可再开）
    show_desk: cm.show_desk,
  }
  @moonui.Fs::write_text_atomic(prefs_path(), prefs_out.to_json().stringify()) catch {
    _ => println("偏好档没存上")
  }
  // 窗口档存的就是这只窗的几何（save_window_state 自己拿存活窗口）
  @moonui.Fs::write_text_atomic(library_path(), cm.lib.to_json().stringify()) catch {
    _ => println("曲库档没存上")
  }
  app.save_window_state(library_path() + ".window") catch {
    _ => ()
  }
}
