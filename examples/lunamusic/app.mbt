///|
/// LunaMusicApp：把Luna主控面板/歌词秀/播放列表组装成一个可 run 的应用
/// （DESIGN.md C-05）。泛型两口注入：B 是 moonui 的 Backend（真窗 native /
/// 无头 Mock），A 是 AudioEngine（真窗的 NativeAudioEngine 在壳里 / 测试的
/// MockAudioEngine）——本体不 import backends/native-common 的约束落在这层。
///
/// 曲库变化的换树纪律：children 对包外只读，所以任何曲目数变化都走
/// rebuild_ui（整树重挂，Window::set_content）；播放状态变化只碰播放条
/// 的可变控件（set_text/set_value/set_visible），不换树。
pub(all) struct LunaMusicApp[B, A] {
  app : @moonui.App[B]
  mut lib : Library
  player : Player[A]
  mut ui : UiState[B]?
  // 歌词缓存：当前曲的 LRC 解析结果 + 其路径（路径变了才重新读文件）
  mut lyrics_path : String
  mut current_lyrics : Array[Lyric]
  // 窗口几何恢复档：四窗版按固定紧凑尺寸落座，此档暂不再消费（保留 API
  // 形状，壳侧继续传；后续做多窗存档键时再接回）。
  frame : @moonui.WindowFrame?
  /// 三个伴窗的显示开关（PL/EQ/LRC 小钮的落地端）。原版是「点一下收起/展开」，
  /// 这里同样：关掉只是 hide 窗口，不销毁。
  mut show_pl : Bool
  mut show_eq : Bool
  mut show_lrc : Bool
  /// 添加目录回调（壳提供：选目录 + worker 扫描）。rebuild_ui 每次换树都
  /// 在新按钮上重接——树外的接线（首版 bug：只接在第一棵树上）活不过重建。
  on_add_dir : () -> Unit
  /// 批量探测回调（壳提供：走原生元数据探针）。导入 m3u 拿到的是一串路径，
  /// 要不probe 就得在这层自己造 Track（只有文件名、时长未知），所以把它做成
  /// 注入口；无头测试不传，走 `Track::from_path` 的默认。
  probe_many : (Array[String]) -> Array[Track]
  // ——列表管理（第二期）：页签 / 排序 / 搜索 / 属性栏——
  /// 当前页签：0 本地音乐 / 1 我喜欢的 / 2 播放队列
  mut tab : Int32
  mut sort_key : SortKey
  mut sort_asc : Bool
  mut query : String
  /// 当前视图（页签 + 排序 + 搜索算出来的那份）。行账与队列都按它走，
  /// `lib.tracks` 始终保持扫描顺序。
  mut view : Array[Track]
  /// 属性栏展示的曲（右键「属性」钉住的那首）；None = 显示提示语
  mut prop_path : String?
  /// 迷你模式开关：收起四窗、只留一条窄条
  mut mini : Bool
  /// 卷起（shade）：只留顶条那一条
  mut rolled : Bool
  /// 桌面歌词窗是否显示
  mut show_desk : Bool
  /// 桌面歌词窗**当前真的挂着没有**。和 `show_desk`（用户开关）分开记：没歌词
  /// 时用户开着它也不挂窗，等歌词来了再挂——`Window::show` 是
  /// `makeKeyAndOrderFront:`，每拍都调会把焦点抢回来，所以显隐必须按边沿走。
  mut desk_shown : Bool
  /// 频谱条子还亮着没有（心跳靠它决定暂停后要不要再跑几拍）
  mut spectrum_lit : Bool
  /// 壳挂的心跳点火器：从「停」变「播」那一刻调一次。心跳链在停播时会自己
  /// 断掉（省唤醒），再播起来没人点火的话进度条就僵在那儿——这个回调就是
  /// 那根火柴，测试里留 None。
  mut on_play : (() -> Unit)?
  /// 上一拍在播没有：用来认「刚播起来」这个边沿
  mut was_playing : Bool
  // ——均衡器（第二期：真·十段，拖得动、进音频链路）——
  /// 十段增益，单位千分位（500 = 0dB；换算见 ui_eq.mbt 的 gain_mdb_of）
  eq_bands : Array[Int32]
  mut eq_on : Bool
  // ——皮肤（第二期：换肤）——
  /// 当前皮肤的标识：内置皮肤名，或皮肤档的路径。启动时靠它恢复——内置表里
  /// 查得到按名取，查不到就当路径让壳去读（文件被删/改名则退回默认皮肤）。
  mut skin : String
  /// 从目录加载皮肤（壳：选目录 → 扫皮肤档 → 逐个回调 `add_skin_file`）。
  /// 无头不传。
  on_load_skin_dir : () -> Unit
  /// 导出当前皮肤（壳：弹保存面板 → 写文本）。无头不传。
  on_save_skin : (String) -> Unit
  /// 目录里加载进来的皮肤（路径 + 皮肤本体）。菜单按这份追加，切回内置也不丢。
  mut extra_skins : Array[(String, Skin)]
}

///|
/// 迷你模式那条窄条（Luna的「迷你模式」）：歌名 + 上/播/下 三颗钮，
/// 没有频谱和进度——原版迷你条就是这么窄。
pub(all) struct MiniBar[B] {
  root : @moonui.Widget[B]
  title : @moonui.Widget[B]
  toggle : @moonui.Widget[B]
}

///|
pub fn[B : @moonui.Backend] MiniBar::new(
  b : B,
  on_prev : () -> Unit,
  on_toggle : () -> Unit,
  on_next : () -> Unit,
) -> MiniBar[B] raise @moonui.UiError {
  let title = @moonui.Widget::label(b, "未播放")
    .foreground(cm_text_light())
    .font_size(12.0)
  let prev = @moonui.Widget::button(b, "⏮")
  let toggle = @moonui.Widget::button(b, "▶")
  let next = @moonui.Widget::button(b, "⏭")
  cm_btn_skin(prev, cm_btn_bg(), cm_text_light(), 11.0)
  cm_btn_skin(toggle, cm_accent(), cm_text_light(), 13.0)
  cm_btn_skin(next, cm_btn_bg(), cm_text_light(), 11.0)
  let _ = prev.with_on_click(fn() { on_prev() })
  let _ = toggle.with_on_click(fn() { on_toggle() })
  let _ = next.with_on_click(fn() { on_next() })
  // mac 的迷你条也被系统红绿灯压着：左边让出整簇 62pt，歌名从 70 起。
  // 300 宽的窗里 62+88+26+30+26+12+16 = 260，留 40 的余量刚好；不让位的话
  // 三颗圆钮正好盖在歌名上。
  let mac = b.host_platform() == @moonui.HostPlatform::Macos
  let cells : Array[@moonui.Widget[B]] = []
  if mac {
    cells.push(
      @moonui.Widget::sized(b, Some(62.0), None, @moonui.Widget::spacer(b)),
    )
  }
  cells.push(
    @moonui.Widget::sized(
      b,
      Some(if mac { 88.0 } else { 150.0 }),
      Some(24.0),
      title,
    ),
  )
  cells.push(@moonui.Widget::sized(b, Some(26.0), Some(24.0), prev))
  cells.push(@moonui.Widget::sized(b, Some(30.0), Some(24.0), toggle))
  cells.push(@moonui.Widget::sized(b, Some(26.0), Some(24.0), next))
  let row = @moonui.Widget::row(b, 4.0, cells)
  // 竖着也居中：48pt 高的条里原来内容贴顶（上 8 下 16），迷你条看着像裁歪了。
  let centered = @moonui.Widget::column(b, 0.0, [
    @moonui.Widget::spacer(b).with_expand(true),
    row,
    @moonui.Widget::spacer(b).with_expand(true),
  ])
  let inner = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(0.0, 8.0),
    centered,
  )
  let mid = @moonui.Widget::panel(b, inner).background(cm_page_bg())
  let panel = cm_band(b, 48.0, mid)
  { root: panel, title, toggle, }
}

///|
/// UI 把手集中体：rebuild_ui 整树重建后整体换新。四窗各持一只句柄
/// （主控/歌词秀/播放列表/均衡器），外加迷你条窗与桌面歌词窗。
pub(all) struct UiState[B] {
  /// 主控窗口（Luna主控：顶条 + 主控面板）
  window : @moonui.Window[B]
  /// 歌词秀窗口（原版是独立窗，这里也是独立窗）
  lyrics_win : @moonui.Window[B]
  /// 播放列表窗口
  playlist_win : @moonui.Window[B]
  /// 均衡器窗口
  eq_win : @moonui.Window[B]
  /// 迷你模式那条窄条（默认不显示）
  mini_win : @moonui.Window[B]
  /// 桌面歌词窗（双行，默认显示，可关）
  desk_win : @moonui.Window[B]
  table : TrackTable[B]
  bar : PlayBar[B]
  lyrics : LyricsView[B]
  desk : DeskLyrics[B]
  mini : MiniBar[B]
  eq : EqPanel[B]
}

///|
/// 装配：库档由调用方先 load 进 lib（或空库起步），engine 已接线 on_finished。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::new(
  app : @moonui.App[B],
  engine : A,
  frame~ : @moonui.WindowFrame? = None,
  on_add_dir~ : () -> Unit = fn() { () },
  probe_many~ : (Array[String]) -> Array[Track] = fn(
    paths : Array[String],
  ) -> Array[Track] {
    let out : Array[Track] = []
    for p in paths {
      out.push(Track::from_path(p))
    }
    out
  },
  on_load_skin_dir~ : () -> Unit = fn() { () },
  on_save_skin~ : (String) -> Unit = fn(_ : String) { () },
) -> LunaMusicApp[B, A] raise @moonui.UiError {
  let lib = Library::new()
  let player = Player::new(engine, lib.tracks)
  let cm : LunaMusicApp[B, A] = {
    app,
    lib,
    player,
    ui: None,
    lyrics_path: "",
    current_lyrics: [],
    frame,
    show_pl: true,
    // 均衡器起手收起：原版主控默认只露主控 + 歌词 + 列表，EQ 是"要用才拉开"
    // 的深设置。窗照建（`show_eq` 是显隐开关，不是存在开关），EQ 钮 / 菜单
    // 一切就出来。
    show_eq: false,
    show_lrc: true,
    on_add_dir,
    probe_many,
    tab: 0,
    sort_key: ByIndex,
    sort_asc: true,
    query: "",
    view: [],
    prop_path: None,
    mini: false,
    rolled: false,
    show_desk: true,
    desk_shown: false,
    spectrum_lit: false,
    on_play: None,
    was_playing: false,
    eq_bands: eq_flat_bands(),
    eq_on: true,
    skin: cm_skin_current().name,
    on_load_skin_dir,
    on_save_skin,
    extra_skins: [],
  }
  // 播放器状态变化 → 播放条刷新（player 的 notify 广播，C-08）
  player.on_update(fn() { cm.refresh_bar() catch { _ => () } })
  cm.rebuild_ui()
  cm
}

///|
/// mac 系统红绿灯的关闭按钮框高（点）。三颗圆钮本体 12pt，按钮框 14×16、圆在
/// 框里居中——所以让 16 高的框落在顶条中线上，圆本身也就居中了。
fn cm_traffic_btn_h() -> Double {
  16.0
}

///|
/// 红绿灯左缘距窗左缘（点）。7 是 AppKit 标准标题栏的内缩，自绘顶条沿用它，
/// 整簇占 7…61。
fn cm_traffic_inset_x() -> Double {
  7.0
}

///|
/// 把 mac 的系统红绿灯摆进一条高 `bar_h` 的自绘顶条的中线。
///
/// 为什么需要：沉浸式标题栏下红绿灯浮在内容上，位置还是 AppKit 那套"标准
/// 28pt 标题栏"的，而我们的顶条是 30（主控）/ 22（伴窗）/ 48（迷你条），
/// 不调就偏上——伴窗那三颗圆钮会压到下缘的倒角线。`set_traffic_light_position`
/// 收的是"关闭按钮左上角相对窗口左上角"，所以 y = (条高 - 16)/2 就是居中。
///
/// 只在 mac 上调；其它平台没有系统红绿灯（Windows 的窗口钮是顶条右侧自绘的），
/// 这条在那边是空操作，调用点因此不用再分叉。
fn[B : @moonui.Backend] cm_place_traffic_lights(
  w : @moonui.Window[B],
  bar_h : Double,
) -> Unit {
  let y = (bar_h - cm_traffic_btn_h()) / 2.0
  let _ = w.set_traffic_light_position(
    @moonui.LogicalPoint(cm_traffic_inset_x(), y),
  ) catch {
    _ => ()
  }
}

///|
/// 桌面歌词窗该不该露头：用户开着它（`show_desk`）、不在迷你模式、而且**当前
/// 有歌词**。最后一条是这轮补的——原先是建窗就 show，没歌的时候屏幕上会一直
/// 挂着一条只写着"Luna"的空条，看着像程序没关干净。
fn cm_desk_visible(show_desk : Bool, mini : Bool, has_lyrics : Bool) -> Bool {
  show_desk && !mini && has_lyrics
}

///|
/// 整树重建：窗口在（首装）就建窗，树重挂。所有把手换新。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::rebuild_ui(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  let b = self.app.backend()
  // ——顶条（Luna招牌）：深蓝底 + ♪ Luna + 窗口钮——
  // 沉浸式标题栏下 mac 红绿灯浮在内容左上、Windows 没有系统按钮，所以这条
  // 顶条两侧都得跟着平台走：mac 左边让出红绿灯的位置、右侧一颗自绘钮都不画
  // （系统已经给了）；其余平台（Windows/Web/未知）反过来，左侧不用让位、
  // 右侧补上最小化/最大化/关闭。平台血统问后端（`HostPlatform` 的段注）。
  let mac = b.host_platform() == @moonui.HostPlatform::Macos
  let logo = @moonui.Widget::label(b, "♪ Luna")
    .foreground(cm_text_light())
    .font_size(13.0)
    .font_weight(@moonui.FontWeight::Bold)
  // 「复位窗口」：拖来拖去把六只窗摆散之后一键归位。做成顶条右侧一颗小胶囊，
  // 与走带上的 PL/EQ/LRC 同款皮肤；mac 上它还是顶条右侧唯一一颗自绘钮
  // （三颗系统圆钮在左边），Windows 上排在最小化/关闭之前。
  let btn_reset = @moonui.Widget::button(b, "复位窗口")
  cm_btn_skin(btn_reset, cm_btn_bg(), cm_text_light(), 9.0)
  let _ = btn_reset.with_on_click(fn() { self.reset_layout() })
  let title_row = if mac {
    @moonui.Widget::row(b, 8.0, [
      // 红绿灯整簇约 52pt，加上左边距留到 88：logo 与三颗圆钮不会叠。
      @moonui.Widget::sized(b, Some(88.0), None, @moonui.Widget::spacer(b)),
      logo,
      @moonui.Widget::spacer(b).with_expand(true),
      btn_reset,
    ])
  } else {
    let btn_min = @moonui.Widget::button(b, "—")
    let btn_mini = @moonui.Widget::button(b, "▣")
    let btn_close = @moonui.Widget::button(b, "✕")
    cm_btn_skin(btn_min, cm_titlebar_bg(), cm_text_light(), 10.0)
    cm_btn_skin(btn_mini, cm_titlebar_bg(), cm_text_light(), 10.0)
    cm_btn_skin(btn_close, cm_titlebar_bg(), cm_text_light(), 10.0)
    // 窗口钮接线：最小化 / 关闭（迷你模式在本单窗口版本里留作装饰）
    let _ = btn_min.with_on_click(fn() {
      match self.ui {
        Some(u) => u.window.set_minimized(true) catch { _ => () }
        None => ()
      }
    })
    let _ = btn_mini.with_on_click(fn() { () })
    let _ = btn_close.with_on_click(fn() { self.app.quit() })
    @moonui.Widget::row(b, 8.0, [
      logo,
      @moonui.Widget::spacer(b).with_expand(true),
      btn_reset,
      btn_min,
      btn_mini,
      btn_close,
    ])
  }
  // 顶条里的内容行要在 30pt 里**垂直居中**：Row 的固定项一律贴交叉轴起点摆
  // （layout_line 的规矩），直接放进 Sized 里会顶在上边——旧版上下 padding 都
  // 是 3，字数一高就变成"上 3 下 12"。上下各垫一只 expand spacer 才是真居中，
  // 而且不用把字号算成常量。
  let title_centered = @moonui.Widget::column(b, 0.0, [
    @moonui.Widget::spacer(b).with_expand(true),
    title_row,
    @moonui.Widget::spacer(b).with_expand(true),
  ])
  let title_inner = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(0.0, 8.0),
    title_centered,
  )
  let title_panel = @moonui.Widget::panel(b, title_inner)
  let _ = title_panel.set_style(
    Some(@moonui.style(background=Some(cm_titlebar_bg()))),
  )
  let title_bar = @moonui.Widget::sized(
    b,
    None,
    Some(cm_title_h()),
    title_panel,
  )

  // 伴窗显隐（PL/EQ/LRC 三个小钮的落地端）：hide 不销毁，再点回来内容还在。
  // 写成 rebuild_ui 里的局部闭包而不是 LunaMusicApp 的方法——方法上写
  // [B : @moonui.Backend] 会被编译器判成 unused_trait_bound（B 只在调
  // Window::show/hide 时用到，检查器不认这条路径），而外层本来就有这个约束。
  let aux_show = fn(show : Bool, win : @moonui.Window[B]) -> Unit {
    if show {
      win.show() catch {
        _ => ()
      }
    } else {
      win.hide() catch {
        _ => ()
      }
    }
  }

  // ——主控面板（信息条 + 频谱 + 时间状态 + 进度 + 走带）——
  let bar = PlayBar::new(
    b,
    fn() { self.player.prev() },
    fn() { self.player.toggle() },
    fn() { self.player.stop() },
    fn() { self.player.next() },
    fn(v) { self.on_seek_slider(v) },
    fn() {
      self.player.cycle_mode()
      self.refresh_bar() catch {
        _ => ()
      }
    },
    fn(v) { self.player.set_volume(v) },
    fn() {
      self.show_pl = !self.show_pl
      match self.ui {
        Some(u) => aux_show(self.show_pl, u.playlist_win)
        None => ()
      }
    },
    fn() {
      self.show_eq = !self.show_eq
      match self.ui {
        Some(u) => aux_show(self.show_eq, u.eq_win)
        None => ()
      }
    },
    fn() {
      self.show_lrc = !self.show_lrc
      match self.ui {
        Some(u) => aux_show(self.show_lrc, u.lyrics_win)
        None => ()
      }
    },
    fn() {
      // 收藏当前曲：没在播就什么都不做（没有"当前曲"这回事）
      match self.player.track() {
        Some(t) => self.toggle_favorite(t.path) catch { _ => () }
        None => ()
      }
    },
  )

  // ——歌词秀（独立窗内容）+ 桌面歌词（独立双行条）——
  let lyrics = LyricsView::new(b)
  let desk = DeskLyrics::new(b)

  // ——播放列表（独立窗内容）：视图 = 页签 + 排序 + 搜索——
  self.view = self.compute_view()
  self.sync_queue(false)
  let hooks : TableHooks = {
    on_play_all: fn() { self.play_all() },
    on_add_dir: fn() { (self.on_add_dir)() },
    on_clear: fn() { self.clear_view() catch { _ => () } },
    on_import: fn() { self.import_m3u() catch { _ => () } },
    on_export: fn() { self.export_m3u() catch { _ => () } },
    on_search: fn(text : String) {
      self.query = text
      self.rebuild_ui() catch {
        _ => ()
      }
    },
    on_sort: fn(k : Int32) { self.set_sort(k) },
    on_tab: fn(t : Int32) { self.set_tab(t) },
  }
  let table = TrackTable::new(
    b,
    self.view.length(),
    self.tab_title(),
    self.tab,
    hooks,
    fn(i : Int32) -> @moonui.Widget[B] raise @moonui.UiError {
      self.build_row(i)
    },
  )

  // ——均衡器（独立窗内容）：真·十段滑块 + 预设 + 启用开关——
  let eq = EqPanel::new(
    b,
    self.player.engine.eq_band_count(),
    self.eq_bands,
    self.eq_on,
    fn(i : Int32, v : Int32) { self.set_eq_band(i, v) },
    fn(i : Int32) { self.set_eq_preset(i) },
    fn(on : Bool) { self.set_eq_enabled(on) },
  )

  // ——主控窗内容：顶条 + 主控面板；两段高度之和 = 窗口内容高——
  // 之前是 [顶条 34 + 面板 expand]，面板里还有 Stack + expand 滑块，布局被
  // 量成 456×1e18，走带整排被推到屏幕外（界面看上去只有一片蓝）。定高拼装
  // 之后整棵树是"有限且刚好"的：没有一处依赖无界测量。
  let main_root = @moonui.Widget::column(b, 0.0, [title_bar, bar.root]).with_style(
    Some(@moonui.style(background=Some(cm_page_bg()))),
  )

  // ——四窗：首装建窗并落座，之后复用窗口只换内容——
  let first = match self.ui {
    None => true
    Some(_) => false
  }
  let mini_bar = MiniBar::new(
    b,
    fn() { self.player.prev() },
    fn() { self.player.toggle() },
    fn() { self.player.next() },
  )
  let (main, lyrics_win, playlist_win, eq_win, mini_win, desk_win) = match
    self.ui {
    Some(u) =>
      (u.window, u.lyrics_win, u.playlist_win, u.eq_win, u.mini_win, u.desk_win)
    None => {
      // 六只窗的落座全来自 cm_default_layout：建窗与「复位窗口」共用一份
      // 坐标，改这里两处一起变。（主控尺寸与面板五段高度同源，差一个像素
      // 就会在底部留一条空带。）
      let screen = self.app.backend().screen_size() catch {
          _ => @moonui.LogicalSize(1440.0, 900.0)
        }
      let lay = cm_default_layout(screen)
      let main = self.app.create_window(
        "Luna",
        @moonui.LogicalSize(lay.main.w, lay.main.h),
      )
      // 原版主控窗不能拉大（皮肤图是定尺的），这里同样锁死
      let _ = main.set_resizable(false) catch { _ => () }
      cm_adopt_window(main, lay.main)
      // 歌词秀：上排右侧，与主控顶边齐平、同高并排
      let lw = self.app.create_window(
        "歌词秀",
        @moonui.LogicalSize(lay.lyrics.w, lay.lyrics.h),
      )
      cm_adopt_window(lw, lay.lyrics)
      // 均衡器：上排整块的右侧（十段滑块 + 预设 + 开关，比主控高）。默认收起，
      // 但位置照摆——从 EQ 钮拉开时直接落在这一格，不用用户再拖。
      let ew = self.app.create_window(
        "均衡器",
        @moonui.LogicalSize(lay.eq.w, lay.eq.h),
      )
      cm_adopt_window(ew, lay.eq)
      // 播放列表：横跨上排两列的整宽，压在下面（宽 794：主控 380 + 缝 6 +
      // 歌词秀 408，右缘与歌词秀齐平）。够宽，工具条那五颗钮 + 搜索框排得开。
      let pw = self.app.create_window(
        "播放列表",
        @moonui.LogicalSize(lay.playlist.w, lay.playlist.h),
      )
      cm_adopt_window(pw, lay.playlist)
      // 迷你条：默认不显示（菜单「迷你模式」切过来）
      let mw = self.app.create_window(
        "Luna · 迷你",
        @moonui.LogicalSize(lay.mini.w, lay.mini.h),
      )
      cm_adopt_window(mw, lay.mini)
      let _ = mw.set_resizable(false) catch { _ => () }
      // 桌面歌词：屏幕底部居中
      let dw = self.app.create_window(
        "桌面歌词",
        @moonui.LogicalSize(lay.desk.w, lay.desk.h),
      )
      cm_adopt_window(dw, lay.desk)
      (main, lw, pw, ew, mw, dw)
    }
  }
  // 六只窗统一沉浸式标题栏：内容铺满整窗，自绘顶条**就是**标题栏本身。
  // 不设的话每只窗顶上还压着一条系统标题栏（灰色渐变 + 窗口名），跟下面的
  // 皮肤是两块料，怎么调都不"沉浸"。建窗那一趟已经由 `cm_adopt_window` 先
  // 设过（顺序原因见那条注释），这里兜住"复用旧窗"的路径；重复设是幂等的。
  for w in [main, lyrics_win, playlist_win, eq_win, mini_win, desk_win] {
    let _ = w.set_titlebar_style(@moonui.TitlebarStyle::Immersive) catch {
      _ => ()
    }
  }
  // 红绿灯摆进各自顶条的中线（顺序要紧：先切沉浸式再摆位——切 styleMask 会让
  // AppKit 把按钮重排回默认位置，原生层虽然会重放，这里仍按"先样式后位置"写）。
  // 桌面歌词没有顶条：它是浮在屏幕底部的一条，红绿灯留在左上角那 6pt 处即可。
  if mac {
    cm_place_traffic_lights(main, cm_title_h())
    for w in [lyrics_win, playlist_win, eq_win] {
      cm_place_traffic_lights(w, cm_strip_h())
    }
    cm_place_traffic_lights(mini_win, 48.0)
  }
  // 属性栏文案：右键「属性」钉住的那首（没有就显示提示语）
  let _ = table.prop.set_text(self.prop_text())
  // 顶条双击 = 卷起/展开（Luna双击标题栏把窗卷成一条）
  let _ = title_bar.with_on_double_click(fn() {
    self.toggle_roll() catch {
      _ => ()
    }
  })
  // ——伴窗统一外壳：顶条（标题 + 关闭）+ 内容区——
  // 四只伴窗原来都是光板一块，摆在一起像四个网页；套上同色系的顶条之后才
  // 读得出"这是同一个程序的四只窗"（原版四窗也都带这条窄标题条）。
  let pl_strip = CmStrip::new(b, "播放列表", fn() {
    self.show_pl = false
    playlist_win.hide() catch {
      _ => ()
    }
  })
  let pl_root = cm_window_shell(b, pl_strip.root, table.root, 5.0)
  let eq_strip = CmStrip::new(b, "均衡器", fn() {
    self.show_eq = false
    eq_win.hide() catch {
      _ => ()
    }
  })
  let eq_root = cm_window_shell(b, eq_strip.root, eq.root, 4.0)
  let lrc_strip = CmStrip::new(b, "歌词秀", fn() {
    self.show_lrc = false
    lyrics_win.hide() catch {
      _ => ()
    }
  })
  let lrc_root = cm_window_shell(b, lrc_strip.root, lyrics.root, 4.0)
  main.set_content(main_root)
  lyrics_win.set_content(lrc_root)
  playlist_win.set_content(pl_root)
  eq_win.set_content(eq_root)
  mini_win.set_content(mini_bar.root)
  desk_win.set_content(desk.root)
  if first {
    main.show()
    lyrics_win.show()
    playlist_win.show()
    // 均衡器默认不露（`show_eq` 起手 false）：窗已经建好、也摆好了落点，只是
    // 不显示——EQ 钮一按 `aux_show(true, ...)` 就贴回原处。
    if self.show_eq {
      eq_win.show()
    }
    // 桌面歌词：开局通常还没有歌词（current_lyrics 要等第一次播起来才读），
    // 所以这里照 `cm_desk_visible` 判一次，不满足就不 show——空条挂在屏幕上
    // 比不挂更糟。`desk_shown` 记的就是这一判的落点，后面的 sync 按它走边沿。
    let desk_on = cm_desk_visible(
      self.show_desk,
      self.mini,
      self.current_lyrics.length() > 0,
    )
    if desk_on {
      desk_win.show()
    }
    self.desk_shown = desk_on
  }
  self.ui = Some({
    window: main,
    lyrics_win,
    playlist_win,
    eq_win,
    mini_win,
    desk_win,
    table,
    bar,
    lyrics,
    desk,
    mini: mini_bar,
    eq,
  })
  self.refresh_bar()
  self.refresh_lyrics() catch {
    _ => ()
  }
}

///|
/// 表格行的格子：定宽（None = 透传给子项/交给外层弹性）+ 行带定高，内容在
/// 格内**垂直居中**、水平保持起点。为什么要这层居中：行带是 VirtualList 锁
/// 的 20pt（ui_table 的 CM_ROW_HEIGHT），格内容（文字 Label）的固有高只有
/// ~13pt，而 Row 的交叉轴是顶对齐——文字贴着行带顶，hover 底一亮就看得出
/// 没居中（真窗探针实锤：NSTextField 自己不居中，字形贴着框顶画）。上下各
/// 垫一只弹性 Spacer 把余量对半分，就是纯布局的垂直居中；Column 的横对齐
/// 维持起点，标题列的长文案不会被拖到中间去。
fn[B : @moonui.Backend] cm_row_cell(
  b : B,
  w : Double?,
  content : @moonui.Widget[B],
) -> @moonui.Widget[B] raise @moonui.UiError {
  @moonui.Widget::sized(
    b,
    w,
    Some(20.0),
    @moonui.Widget::column(b, 0.0, [
      @moonui.Widget::spacer(b),
      content,
      @moonui.Widget::spacer(b),
    ]),
  )
}

///|
/// 表格行：# 标题 歌手 时长；当前曲目高亮（▶ 前缀），双击播放。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::build_row(
  self : LunaMusicApp[B, A],
  i : Int32,
) -> @moonui.Widget[B] raise @moonui.UiError {
  let b = self.app.backend()
  // 行账走视图（排序/搜索/页签之后的那份），不是 lib.tracks——下标与
  // VirtualList 的 count 同源，越界按空行兜住（视图在重建窗缩小过）。
  if i < 0 || i >= self.view.length() {
    return @moonui.Widget::panel(b, @moonui.Widget::spacer(b))
  }
  let t = self.view[i]
  let cur = self.player.current
  let playing = cur is Some(c) && c == i
  let mark = if playing { "▶ " } else { "" }
  // 皮肤：当前曲整行蓝字 + 浅蓝底
  let row_fg = if playing { Some(cm_accent()) } else { None }
  // 列宽走 Sized 通道（style.width 不进布局账，§15 的样式只到绘制侧）；
  // 标题列 expand 吃剩余宽度——与表头同一条账，两行列缝对得齐
  let row = @moonui.Widget::row(b, 8.0, [
    cm_row_cell(
      b,
      Some(30.0),
      @moonui.Widget::label(b, "\{mark}\{i + 1}")
      .font_size(10.0)
      .foreground(
        match row_fg {
          Some(c) => c
          None => cm_muted()
        },
      ),
    ),
    cm_row_cell(
      b,
      None,
      @moonui.Widget::label(b, t.title)
      .foreground(
        match row_fg {
          Some(c) => c
          None => cm_ink()
        },
      )
      .font_size(10.0)
      .font_weight(
        if playing {
          @moonui.FontWeight::Bold
        } else {
          @moonui.FontWeight::Regular
        },
      ),
    ).with_expand(true),
    cm_row_cell(
      b,
      Some(104.0),
      @moonui.Widget::label(b, t.artist)
      .font_size(10.0)
      .foreground(
        match row_fg {
          Some(c) => c
          None => cm_muted()
        },
      ),
    ),
    cm_row_cell(
      b,
      Some(46.0),
      @moonui.Widget::label(b, format_duration(t.duration_ms))
      .font_size(10.0)
      .foreground(
        match row_fg {
          Some(c) => c
          None => cm_muted()
        },
      ),
    ),
  ])
  // 双击播放：队列先钉成当前视图（搜索结果里双击，队列就是那份结果），
  // 再按视图下标播（C-02 行为表：该行成为当前，从头播）。
  let _ = row.with_on_double_click(fn() { self.play_view_index(i) })
  // 右键菜单：播放 / 收藏 / 从列表移除 / 属性（T86① 的控件级上下文菜单）
  let play_item = @moonui.MenuItem::new("播放")
  let _ = play_item.on(fn(_) { self.play_view_index(i) })
  let fav_item = @moonui.MenuItem::new(
    if self.lib.is_favorite(t.path) {
      "取消收藏"
    } else {
      "加入收藏"
    },
  )
  let _ = fav_item.on(fn(_) { self.toggle_favorite(t.path) catch { _ => () } })
  let remove_item = @moonui.MenuItem::new("从列表移除")
  let _ = remove_item.on(fn(_) { self.remove_track(t.path) catch { _ => () } })
  let prop_item = @moonui.MenuItem::new("属性")
  let _ = prop_item.on(fn(_) {
    self.prop_path = Some(t.path)
    self.rebuild_ui() catch {
      _ => ()
    }
  })
  let _ = row.set_context_menu(
    @moonui.Menu::new("行", [
      @moonui.MenuNode::Item(play_item),
      @moonui.MenuNode::Item(fav_item),
      @moonui.MenuNode::Item(remove_item),
      @moonui.MenuNode::Item(prop_item),
    ]),
  )
  // 行的像素面：Panel（真后端上唯一吃 background 的容器，斑马画在这层）。
  // 偶数行不设底，透出页面色；斑马色给奇数行。
  let panel = @moonui.Widget::panel(b, row)
  let row_bg = if playing {
    Some(cm_accent_bg())
  } else if i % 2 == 1 {
    Some(cm_zebra())
  } else {
    None
  }
  let _ = panel.set_style(Some(@moonui.style(background=row_bg)))
  let _ = panel.set_hover_style(
    Some(@moonui.style(background=Some(cm_hover()))),
  )
  panel
}

///|
/// 从列表移除一首（右键菜单）：当前曲被移掉时停播，其余情况播放不受扰。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::remove_track(
  self : LunaMusicApp[B, A],
  path : String,
) -> Unit raise @moonui.UiError {
  self.lib.remove_track(path)
  self.player.replace_queue(self.lib.tracks)
  self.rebuild_ui()
}

///|
/// 菜单栏（C-03 映射表：MenuBar + MenuSelect）。装一次（app 级，不跟树走）。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::install_menubar(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  // 播放菜单：播放/暂停（空格）、上一首（⌘←）、下一首（⌘→）、模式切换
  let toggle = @moonui.MenuItem::new("播放/暂停")
  let _ = toggle.set_shortcut(@moonui.Shortcut::new("Space"))
  let _ = toggle.on(fn(_) {
    self.player.toggle()
    self.refresh_bar() catch {
      _ => ()
    }
  })
  let prev = @moonui.MenuItem::new("上一首")
  let _ = prev.set_shortcut(@moonui.Shortcut::meta("Left"))
  let _ = prev.on(fn(_) { self.player.prev() })
  let next = @moonui.MenuItem::new("下一首")
  let _ = next.set_shortcut(@moonui.Shortcut::meta("Right"))
  let _ = next.on(fn(_) { self.player.next() })
  let mode = @moonui.MenuItem::new("切换播放模式")
  let _ = mode.on(fn(_) {
    self.player.cycle_mode()
    self.refresh_bar() catch {
      _ => ()
    }
  })
  let play_menu = @moonui.Menu::new("播放", [
    @moonui.MenuNode::Item(toggle),
    @moonui.MenuNode::Item(prev),
    @moonui.MenuNode::Item(next),
    @moonui.MenuNode::Item(mode),
  ])
  // 控制菜单：播放全部 / 添加目录
  let play_all = @moonui.MenuItem::new("播放全部")
  let _ = play_all.on(fn(_) { self.play_all() })
  let add_dir = @moonui.MenuItem::new("添加目录…")
  let _ = add_dir.on(fn(_) { (self.on_add_dir)() })
  // 窗口菜单：迷你模式 / 卷起 / 桌面歌词（原版这三样在右键与主菜单里都有）
  let mini_item = @moonui.MenuItem::new("迷你模式")
  let _ = mini_item.on(fn(_) { self.toggle_mini() catch { _ => () } })
  let roll_item = @moonui.MenuItem::new("卷起/展开")
  let _ = roll_item.on(fn(_) { self.toggle_roll() catch { _ => () } })
  let desk_item = @moonui.MenuItem::new("桌面歌词")
  let _ = desk_item.on(fn(_) { self.toggle_desk() catch { _ => () } })
  let window_menu = @moonui.Menu::new("窗口", [
    @moonui.MenuNode::Item(mini_item),
    @moonui.MenuNode::Item(roll_item),
    @moonui.MenuNode::Item(desk_item),
  ])
  let control_menu = @moonui.Menu::new("控制", [
    @moonui.MenuNode::Item(play_all),
    @moonui.MenuNode::Item(add_dir),
  ])
  // 皮肤菜单：内置四套（radio 打勾当前）+ 导入/导出/恢复默认。
  // 换肤会整树重建并**重挂**本菜单，所以打勾每次都是照当时的皮肤算的。
  let skin_nodes : Array[@moonui.MenuNode] = []
  for s in cm_skin_builtins() {
    let name = s.name
    let item = @moonui.MenuItem::radio(name)
    item.checked = self.skin_is(name)
    let _ = item.on(fn(_) { let _ = self.set_skin_by_name(name) })
    skin_nodes.push(@moonui.MenuNode::Item(item))
  }
  // 目录里加载进来的皮肤：按名字显示，打勾按路径比（名字可能重）
  for e in self.extra_skins {
    let path = e.0
    let sk = e.1
    let extra = @moonui.MenuItem::radio(sk.name)
    extra.checked = self.skin_is(path)
    let _ = extra.on(fn(_) { self.set_skin(sk, path) })
    skin_nodes.push(@moonui.MenuNode::Item(extra))
  }
  skin_nodes.push(@moonui.MenuNode::Separator)
  let import_item = @moonui.MenuItem::new("加载皮肤目录…")
  let _ = import_item.on(fn(_) { (self.on_load_skin_dir)() })
  skin_nodes.push(@moonui.MenuNode::Item(import_item))
  let export_item = @moonui.MenuItem::new("导出当前皮肤…")
  let _ = export_item.on(fn(_) { (self.on_save_skin)(cm_skin_current().text()) })
  skin_nodes.push(@moonui.MenuNode::Item(export_item))
  let reset_item = @moonui.MenuItem::new("恢复默认皮肤")
  let _ = reset_item.on(fn(_) { self.reset_skin() })
  skin_nodes.push(@moonui.MenuNode::Item(reset_item))
  let skin_menu = @moonui.Menu::new("皮肤", skin_nodes)
  self.app.set_menubar(
    @moonui.MenuBar::new([play_menu, control_menu, window_menu, skin_menu]),
  )
}

///|
/// 播放条刷新：从 player 拉最新状态写控件（notify 广播的落地端）。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::refresh_bar(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  match self.ui {
    Some({ bar, mini, .. }) => {
      match self.player.track() {
        Some(t) => {
          let _ = bar.title.set_text(t.title)
          let _ = bar.artist.set_text("\{t.artist} - \{t.album}")
          let _ = bar.fav.set_text(
            if self.lib.is_favorite(t.path) {
              "♥"
            } else {
              "♡"
            },
          )
        }
        None => {
          let _ = bar.title.set_text("未播放")
          let _ = bar.artist.set_text("")
          let _ = bar.fav.set_text("♡")
        }
      }
      let playing = self.player.is_playing()
      let _ = bar.toggle.set_text(if playing { "⏸" } else { "▶" })
      let _ = bar.toggle.set_icon(
        if playing {
          "pause.fill"
        } else {
          "play.fill"
        },
      )
      let _ = bar.mode.set_text("")
      let _ = bar.mode.set_icon(
        match self.player.mode {
          RepeatOne => "repeat.1"
          Shuffle => "shuffle"
          Sequential => "repeat"
        },
      )
      let _ = bar.state_text.set_text(
        if playing {
          "状态: 播放"
        } else if self.player.state is Paused {
          "状态: 暂停"
        } else {
          "状态: 就绪"
        },
      )
      // 进度：千分位；时长未知（<0）钳到 0
      let dur = self.player.duration()
      let pos = self.player.position()
      let permille = if dur > 0 { (pos * 1000L / dur).to_int() } else { 0 }
      let _ = bar.progress.set_value(permille)
      // 自绘层跟着走（原生滑块被蒙住，只负责拖动）
      bar.prog_bar.set_permille(permille)
      // 没曲目时原版显示 00:00 与 00:00，不显示 --:--（那是"不知道"的占位，
      // 摆在大字号上会变成两排破折号，看着像控件坏了）
      let pos_show = if pos < 0 { 0L } else { pos }
      let dur_show = if dur < 0 { 0L } else { dur }
      let _ = bar.time_big.set_text(format_duration(pos_show))
      let _ = bar.time_total.set_text("/ " + format_duration(dur_show))
      let _ = bar.volume.set_value(self.player.volume)
      bar.vol_bar.set_permille(self.player.volume)
      // 迷你条同步（同一套状态，两处显示）
      let _ = mini.title.set_text(
        match self.player.track() {
          Some(t) => t.title
          None => "未播放"
        },
      )
      let _ = mini.toggle.set_text(if playing { "⏸" } else { "▶" })
    }
    None => ()
  }
  // 边沿：刚播起来 → 通知壳点火（心跳链停播时自己断了，得有人重新接上）
  let playing = self.player.is_playing()
  if playing && !self.was_playing {
    match self.on_play {
      Some(f) => f()
      None => ()
    }
  }
  self.was_playing = playing
}

///|
/// 进度条拖动：slider 千分位 → 毫秒 seek（C-08 行为表：播着不动）。
pub fn[B, A : AudioEngine] LunaMusicApp::on_seek_slider(
  self : LunaMusicApp[B, A],
  permille : Int32,
) -> Unit {
  let dur = self.player.duration()
  if dur > 0 {
    self.player.seek(dur * permille.to_int64() / 1000L)
  }
}

///|
/// 歌词刷新：随播放进度把当前行高亮。只在播着时由 500ms 心跳驱动（native 壳），
/// 不在 wasm 测试路径上触发（避免走到读文件的 load_lyrics_for）。
/// 当前曲路径变了才重新读 .lrc；否则只按位置重算高亮行。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::refresh_lyrics(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  match self.ui {
    Some({ lyrics, desk, .. }) =>
      match self.player.track() {
        Some(t) => {
          if t.path != self.lyrics_path {
            self.lyrics_path = t.path
            self.current_lyrics = load_lyrics_for(t.path)
          }
          let _ = lyrics.update(
            self.current_lyrics,
            self.player.position(),
            t.title,
            t.artist,
          )
          let _ = desk.update(
            self.current_lyrics,
            self.player.position(),
            t.title,
          )
        }
        None => {
          self.lyrics_path = ""
          self.current_lyrics = []
          let _ = lyrics.update(self.current_lyrics, 0L, "", "")
          let _ = desk.update(self.current_lyrics, 0L, "")
        }
      }
    None => ()
  }
  // 有没有歌词决定桌面歌词窗露不露头：换歌（读 .lrc）与停播（清空）都经过这里。
  self.sync_desk_window()
}

///|
/// 添加目录（真窗走系统选目录面板，无头走注入的 pick 回调）。
/// 扫描在调用方（FP3 的 worker 或测试的同步直灌），结果 merge 后 rebuild。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::merge_scan(
  self : LunaMusicApp[B, A],
  dir : String,
  found : Array[Track],
) -> Unit raise @moonui.UiError {
  self.lib.merge(dir, found)
  // 队列整体替换；当前曲还在库里就保住高亮
  self.player.replace_queue(self.lib.tracks)
  self.rebuild_ui()
}

///|
/// 属性栏文案：标题 / 歌手 - 专辑 / 时长 / 路径。原版是弹一个属性窗，这里
/// 单窗版没有第二层窗口位，摆成列表窗底部那行（信息量一样，少一次弹窗）。
pub fn[B, A] LunaMusicApp::prop_text(self : LunaMusicApp[B, A]) -> String {
  match self.prop_path {
    Some(p) =>
      match self.lib.find(p) {
        Some(t) => {
          let head = "属性：\{t.title} · \{t.artist} - \{t.album}"
          let tail = " · \{format_duration(t.duration_ms)} · \{t.path}"
          head + tail
        }
        None => "属性：这首已经不在库里了"
      }
    None => "属性：双击一首歌播放，右键看属性"
  }
}

///|
/// 平直的那张表（十段都是 0dB）。
fn eq_flat_bands() -> Array[Int32] {
  let out : Array[Int32] = []
  for i = 0; i < 10; i = i + 1 {
    out.push(500)
  }
  out
}

///|
/// 拖某一段：改表 → 推给引擎（原生层改 AVAudioUnitEQ 的那一段）→ 刷读数。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::set_eq_band(
  self : LunaMusicApp[B, A],
  band : Int32,
  permille : Int32,
) -> Unit {
  if band < 0 || band >= self.eq_bands.length() {
    return
  }
  self.eq_bands[band] = permille
  self.push_eq()
  match self.ui {
    Some(u) =>
      if band < u.eq.gains.length() {
        let _ = u.eq.gains[band].set_text(gain_text(gain_mdb_of(permille))) catch {
          _ => ()
        }
      }
    None => ()
  }
}

///|
/// 选预设：整张表换掉 → 推给引擎 → 十段滑块与读数一起刷回去（不重建树）。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::set_eq_preset(
  self : LunaMusicApp[B, A],
  index : Int32,
) -> Unit {
  let table = eq_presets()
  let idx = if index < 0 {
    0
  } else if index >= table.length() {
    table.length() - 1
  } else {
    index
  }
  let picked = table[idx].1
  for i = 0; i < self.eq_bands.length(); i = i + 1 {
    self.eq_bands[i] = if i < picked.length() { picked[i] } else { 500 }
  }
  self.push_eq()
  match self.ui {
    Some(u) => u.eq.set_bands(self.eq_bands) catch { _ => () }
    None => ()
  }
}

///|
/// 启用开关：旁路 EQ（关掉就是直通，与原生层的 bypass 同一条语义）。
pub fn[B, A : AudioEngine] LunaMusicApp::set_eq_enabled(
  self : LunaMusicApp[B, A],
  on : Bool,
) -> Unit {
  self.eq_on = on
  self.push_eq()
}

///|
/// 把当下的表推给引擎：段数为 0 的平台（Windows 半）这一步什么都不做。
///
/// 单位在这里换：`self.eq_bands` 存的是**千分位**（滑块位置、预设表、存档都是
/// 这一档），引擎与原生层要的是 **milli-dB**（±12000）。不换的话平直档 500 会
/// 被当成 0.5dB、拖到底也只有 1dB——整条 EQ 几乎不动。
pub fn[B, A : AudioEngine] LunaMusicApp::push_eq(
  self : LunaMusicApp[B, A],
) -> Unit {
  let gains : Array[Int32] = []
  for v in self.eq_bands {
    gains.push(gain_mdb_of(v))
  }
  self.player.engine.eq_apply(gains, self.eq_on)
}

///|
/// 频谱刷新：向引擎要 16 段能量（原生层 FFT 的活），交给可视化窗点亮。
/// 心跳调用它；没在播时原生层每读衰减一次，条子自己落回去。
pub fn[B, A : AudioEngine] LunaMusicApp::refresh_spectrum(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  let levels : Array[Int32] = []
  let mut any = false
  for i = 0; i < cm_viz_bands(); i = i + 1 {
    let lv = self.player.engine.level(i)
    if lv > 0 {
      any = true
    }
    levels.push(lv)
  }
  self.spectrum_lit = any
  match self.ui {
    Some(u) => u.bar.viz.update(levels)
    None => ()
  }
}

///|
/// 条子还亮着没有（暂停后要再跑几拍让它们落回去）。
pub fn[B, A] LunaMusicApp::spectrum_lit(self : LunaMusicApp[B, A]) -> Bool {
  self.spectrum_lit
}

// ————————————————————————————————————————————————————
// 皮肤（第二期：换肤）
// ————————————————————————————————————————————————————

///|
/// 换皮肤：换掉全局那一份 → 整树重建（颜色都在 set_style 里，不换树不变色）
/// → 重挂菜单栏（把新皮肤的打勾挪过去）。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::set_skin(
  self : LunaMusicApp[B, A],
  s : Skin,
  name : String,
) -> Unit {
  cm_skin_set(s)
  self.skin = name
  self.rebuild_ui() catch {
    _ => ()
  }
  // 菜单栏不跟树走，打勾要重挂才挪得动
  self.install_menubar() catch {
    _ => ()
  }
}

///|
/// 按内置皮肤名换（菜单那几项走这条）。查不到返回 false（调用方按"不是内置
/// 皮肤"处理）。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::set_skin_by_name(
  self : LunaMusicApp[B, A],
  name : String,
) -> Bool {
  match cm_skin_by_name(name) {
    Some(s) => {
      self.set_skin(s, s.name)
      true
    }
    None => false
  }
}

///|
/// 从皮肤档换：记下路径（下次启动照它恢复），并把它挂进 `extra_skins`——
/// 菜单靠这份在切回内置之后还能再切回来。同路径重复加载是覆盖，不是追加。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::add_skin_file(
  self : LunaMusicApp[B, A],
  path : String,
  text : String,
) -> Bool {
  match Skin::from_text(text) {
    Some(s) => {
      let mut i = 0
      let mut found = false
      while i < self.extra_skins.length() {
        if self.extra_skins[i].0 == path {
          self.extra_skins[i] = (path, s)
          found = true
          break
        }
        i = i + 1
      }
      if !found {
        self.extra_skins.push((path, s))
      }
      self.set_skin(s, path)
      true
    }
    None => false
  }
}

///|
/// 已加载的外部皮肤（路径 + 名字），菜单与测试都读这份。
pub fn[B, A] LunaMusicApp::extra_skins(
  self : LunaMusicApp[B, A],
) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for e in self.extra_skins {
    out.push((e.0, e.1.name))
  }
  out
}

///|
/// 恢复默认皮肤。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::reset_skin(
  self : LunaMusicApp[B, A],
) -> Unit {
  self.set_skin(cm_skin_default(), cm_skin_default().name)
}

///|
/// 当前皮肤标识（存档用：内置名或路径）。
pub fn[B, A] LunaMusicApp::skin_id(self : LunaMusicApp[B, A]) -> String {
  self.skin
}

///|
/// 某项是不是当前皮肤（菜单打勾用）。导入的皮肤按路径比。
pub fn[B, A] LunaMusicApp::skin_is(
  self : LunaMusicApp[B, A],
  name : String,
) -> Bool {
  self.skin == name
}

///|
/// 播放全部（工具条按钮）：队列钉成当前视图，有曲就从头播。
pub fn[B, A : AudioEngine] LunaMusicApp::play_all(
  self : LunaMusicApp[B, A],
) -> Unit {
  if self.view.length() > 0 {
    self.player.set_queue_keep_current(self.view)
    self.player.play_index(0)
  }
}

///|
/// 视图里某一行双击/右键播放：先把队列换成视图（这样"在搜索结果里双击"之后
/// 下一首跟着这份结果走），再按视图下标播。
pub fn[B, A : AudioEngine] LunaMusicApp::play_view_index(
  self : LunaMusicApp[B, A],
  i : Int32,
) -> Unit {
  self.player.set_queue_keep_current(self.view)
  self.player.play_index(i)
}

// ————————————————————————————————————————————————————
// 列表管理（第二期）：页签 / 排序 / 搜索 / 属性栏 / m3u / 收藏
// ————————————————————————————————————————————————————

///|
/// 当前视图：页签取集合 → 排序 → 搜索过滤。
/// 播放队列页签特殊：它就是 player 的队列本体，不再排序过滤（那份顺序是
/// 播放顺序，动它等于改播放顺序）。
pub fn[B, A] LunaMusicApp::compute_view(
  self : LunaMusicApp[B, A],
) -> Array[Track] {
  let base = match self.tab {
    1 => self.lib.favorite_tracks()
    2 => self.player.queue
    _ => self.lib.sorted(self.sort_key, self.sort_asc)
  }
  filter_tracks(base, self.query)
}

///|
/// 页签标题（列表窗左上角那行大字）。
pub fn[B, A] LunaMusicApp::tab_title(self : LunaMusicApp[B, A]) -> String {
  match self.tab {
    1 => "我喜欢的"
    2 => "播放队列"
    _ => "本地音乐"
  }
}

///|
/// 队列跟随视图：只在「视图结构变了」时换（换页签/改排序/清空搜索/播放全部/
/// 双击播放），搜索打字期间不换——否则每敲一个字都重洗一次随机牌堆。
/// force=false 且搜索框非空时不动队列（只动显示）。
pub fn[B, A] LunaMusicApp::sync_queue(
  self : LunaMusicApp[B, A],
  force : Bool,
) -> Unit {
  if self.tab == 2 {
    return // 队列页签：视图就是队列，不能自己换自己
  }
  if !force && self.query.length() > 0 {
    return
  }
  self.player.set_queue_keep_current(self.view)
}

///|
/// 换页签：跟随原版「点一下切列表」，队列同步过去（force）。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::set_tab(
  self : LunaMusicApp[B, A],
  t : Int32,
) -> Unit {
  self.tab = t
  self.view = self.compute_view()
  self.sync_queue(true)
  self.rebuild_ui() catch {
    _ => ()
  }
}

///|
/// 点列头：同一列再点是升降翻转，换列则回到升序。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::set_sort(
  self : LunaMusicApp[B, A],
  key : Int32,
) -> Unit {
  let k = match key {
    1 => ByTitle
    2 => ByArtist
    3 => ByDuration
    _ => ByIndex
  }
  if k == self.sort_key {
    self.sort_asc = !self.sort_asc
  } else {
    self.sort_key = k
    self.sort_asc = true
  }
  self.view = self.compute_view()
  self.sync_queue(true)
  self.rebuild_ui() catch {
    _ => ()
  }
}

///|
/// 清空：按页签语义——本地音乐清曲库与目录，收藏页签清收藏，队列页签只停播
/// 并清空队列。问一句再动手（Backend::confirm，无头测试返回默认）。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::clear_view(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  let what = self.tab_title()
  if !self.app.backend().confirm("清空", "确定清空「\{what}」？") {
    return
  }
  match self.tab {
    1 => self.lib.favorites.clear()
    2 => {
      self.player.stop()
      self.player.replace_queue([])
    }
    _ => {
      self.lib.tracks.clear()
      self.lib.dirs.clear()
      self.player.replace_queue([])
    }
  }
  self.view = self.compute_view()
  self.rebuild_ui()
}

///|
/// 导出 m3u：把当前视图写进用户挑的文件（系统保存面板）。
/// 路径按原样写绝对路径——本地库本来就是绝对路径，相对路径的解法留给播放器。
pub fn[B : @moonui.Backend, A] LunaMusicApp::export_m3u(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  if self.view.length() == 0 {
    let _ = self.app.backend().confirm("导出 m3u", "当前列表是空的")
    return
  }
  match self.app.backend().save_file("导出 m3u", "playlist.m3u") {
    Some(p) => {
      let text = m3u_export(self.view)
      library_save(p, text) catch {
        _ => ()
      }
    }
    None => ()
  }
}

///|
/// 导入 m3u：系统打开面板 → 读文本 → 解析路径 → 走注入的批量探测 → 并入库。
/// 探测失败的歌也会进来（`Track::from_path` 兜底），不阻塞导入。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::import_m3u(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  match self.app.backend().open_file("导入 m3u") {
    Some(p) =>
      match library_load(p) {
        Some(text) => {
          let paths = m3u_import(text, dir_of(p))
          let found = (self.probe_many)(paths)
          self.lib.merge("(m3u)", found)
          self.player.replace_queue(self.lib.tracks)
          self.rebuild_ui()
        }
        None => ()
      }
    None => ()
  }
}

// ————————————————————————————————————————————————————
// 窗口生态（第二期）：卷起 / 迷你模式 / 桌面歌词 / 滚轮调音量 / 托盘
// ————————————————————————————————————————————————————

///|
/// 卷起（shade）：把主控窗高度压到只剩顶条，再双击展开回去。原版皮肤是定尺
/// 图，卷起来正好是标题条那一条；这里同样只留 `cm_title_h()`。
pub fn[B : @moonui.Backend, A] LunaMusicApp::toggle_roll(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  match self.ui {
    Some(u) => {
      let h = if self.rolled { cm_main_h() } else { cm_title_h() }
      u.window.set_size(@moonui.LogicalSize(cm_main_w(), h))
      self.rolled = !self.rolled
    }
    None => ()
  }
}

///|
/// 一键复位：把六只窗摆回 `cm_default_layout` 给的默认位置与尺寸。
///
/// 用户拖窗口是常事，拖散了想回到"刚装好那样"却没有回头路。几处讲究：
/// - 屏幕尺寸**当场再读一次**，换过外接屏/分辨率之后复位到的是当前屏的默认，
///   而不是建窗那天的坐标；
/// - 复位顺带把卷起展开（`rolled` 归 false）。否则尺寸回到全高、状态还记着
///   "卷着"，下一次双击会朝反方向走；
/// - 尺寸先落、位置后落（见 `cm_animate_placement`——位置是滑过去的，不是
///   瞬移；下限/尺寸仍当场落）。
pub fn[B : @moonui.Backend, A] LunaMusicApp::reset_layout(
  self : LunaMusicApp[B, A],
) -> Unit {
  match self.ui {
    Some(u) => {
      let screen = self.app.backend().screen_size() catch {
          _ => @moonui.LogicalSize(1440.0, 900.0)
        }
      let lay = cm_default_layout(screen)
      self.rolled = false
      cm_animate_placement(u.window, lay.main)
      cm_animate_placement(u.lyrics_win, lay.lyrics)
      cm_animate_placement(u.eq_win, lay.eq)
      cm_animate_placement(u.playlist_win, lay.playlist)
      cm_animate_placement(u.mini_win, lay.mini)
      cm_animate_placement(u.desk_win, lay.desk)
    }
    None => ()
  }
}

///|
/// 迷你模式：四窗（与桌面歌词）收起，只留迷你条；再切一次按各窗自己的
/// 显示开关还原（PL/EQ/LRC 关掉过的窗不会被强行拉回来）。
pub fn[B : @moonui.Backend, A] LunaMusicApp::toggle_mini(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  match self.ui {
    Some(u) => {
      self.mini = !self.mini
      if self.mini {
        u.window.hide()
        u.lyrics_win.hide()
        u.playlist_win.hide()
        u.eq_win.hide()
        u.mini_win.show()
      } else {
        u.mini_win.hide()
        u.window.show()
        if self.show_lrc {
          u.lyrics_win.show()
        }
        if self.show_pl {
          u.playlist_win.show()
        }
        if self.show_eq {
          u.eq_win.show()
        }
      }
      // 桌面歌词跟 `mini` 走：进迷你模式收起，出来时只有"有歌词"才挂回来。
      self.sync_desk_window()
    }
    None => ()
  }
}

///|
/// 桌面歌词显隐（原版是右键菜单里的开关，这里走控制菜单与托盘菜单）。
///
/// 开关与"现在挂不挂"分开：开着的状态会被记住，但没歌词时窗还是不挂
/// （见 `cm_desk_visible`）——等歌词读进来了，心跳里的 sync 会把它挂上。
pub fn[B : @moonui.Backend, A] LunaMusicApp::toggle_desk(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  self.show_desk = !self.show_desk
  self.sync_desk_window()
}

///|
/// 桌面歌词窗的显隐落地端：**按边沿**触底。
///
/// 为什么不能每拍无脑 show：`Window::show` 落的是
/// `makeKeyAndOrderFront:`，播放时 500ms 一拍，等于每半秒把焦点从用户正在
/// 用的程序抢回来。所以先和 `desk_shown` 比一次，只有"该变"了才碰窗口。
fn[B : @moonui.Backend, A] LunaMusicApp::sync_desk_window(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  let want = cm_desk_visible(
    self.show_desk,
    self.mini,
    self.current_lyrics.length() > 0,
  )
  match self.ui {
    Some(u) => {
      if want == self.desk_shown {
        return
      }
      if want {
        u.desk_win.show()
      } else {
        u.desk_win.hide()
      }
      self.desk_shown = want
    }
    None => ()
  }
}

///|
/// 滚轮调音量：一格 50‰（千分位），上下按 delta 的符号走——向上滚（delta 为
/// 正、内容下移）是加音量。事件由壳订阅主控窗的 `Scroll` 后转进来。
pub fn[B, A : AudioEngine] LunaMusicApp::wheel_volume(
  self : LunaMusicApp[B, A],
  delta : Double,
) -> Unit {
  let step = if delta > 0.0 { 50 } else if delta < 0.0 { -50 } else { 0 }
  if step != 0 {
    self.player.set_volume(self.player.volume + step)
  }
}

///|
/// 托盘（T86⑥）：图标 + 右键菜单（播放/暂停、上一首、下一首、迷你模式、
/// 桌面歌词、退出）。托盘是进程级一只，装一次即可，不跟树走。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::install_tray(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  let _ = self.app.set_tray_icon("assets/logo/luna")
  let toggle = @moonui.MenuItem::new("播放/暂停")
  let _ = toggle.on(fn(_) {
    self.player.toggle()
    self.refresh_bar() catch {
      _ => ()
    }
  })
  let prev = @moonui.MenuItem::new("上一首")
  let _ = prev.on(fn(_) { self.player.prev() })
  let next = @moonui.MenuItem::new("下一首")
  let _ = next.on(fn(_) { self.player.next() })
  let mini = @moonui.MenuItem::new("迷你模式")
  let _ = mini.on(fn(_) { self.toggle_mini() catch { _ => () } })
  let desk = @moonui.MenuItem::new("桌面歌词")
  let _ = desk.on(fn(_) { self.toggle_desk() catch { _ => () } })
  let quit = @moonui.MenuItem::new("退出")
  let _ = quit.on(fn(_) { self.app.quit() })
  let _ = self.app.set_tray_menu(
    @moonui.Menu::new("Luna", [
      @moonui.MenuNode::Item(toggle),
      @moonui.MenuNode::Item(prev),
      @moonui.MenuNode::Item(next),
      @moonui.MenuNode::Separator,
      @moonui.MenuNode::Item(mini),
      @moonui.MenuNode::Item(desk),
      @moonui.MenuNode::Separator,
      @moonui.MenuNode::Item(quit),
    ]),
  )
}

///|
/// 收藏开关（播放条 ♡ 与右键菜单共用）：改完重建（列表窗的收藏页签与行色
/// 都要跟着变，行色本来就走 rebuild 换树）。
pub fn[B : @moonui.Backend, A : AudioEngine] LunaMusicApp::toggle_favorite(
  self : LunaMusicApp[B, A],
  path : String,
) -> Unit raise @moonui.UiError {
  let _ = self.lib.toggle_favorite(path)
  self.rebuild_ui()
}
