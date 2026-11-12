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
  /// 已经为哪条路径问过在线歌词（`T158`）。**只记发过一次的路径，不记结果**
  /// ——"问过但没查到"也要记住，否则每 500ms 一拍都会重发一轮请求。
  ///
  /// 不清空：一首歌问过一次就够了，这次会话里再切回来不该再打一次服务器。
  mut lyrics_asked_path : String
  /// 壳挂的在线取词器（`T158`）。`None` = 不联网（无头测试、以及 wasm 侧）。
  ///
  /// 签名里带 `Array[(String, String)]` 而不是收一个 Track，是为了让"该拿
  /// 什么去问"这件事留在本体（`tag_query_candidates`），壳只管发请求。
  ///
  /// 回调形态：`(path, lrc)` → 回主循环落结果。`path` 用来判"这份词还是不是
  /// 当前那首的"——换歌之后才回来的旧结果必须丢掉。
  mut on_fetch_online : ((
    String,
    Array[(String, String)],
    Double,
    (String, String?) -> Unit,
  ) -> Unit)?
  /// 壳挂的**手动**搜索器（`T161`①）。`None` = 不联网（无头测试 / wasm）。
  ///
  /// 与 `on_fetch_online` 是两条独立的注入口而不是一个带开关的：自动那条的
  /// 输入是候选表（"机器替我挑"），手动这条的输入是用户敲的两个词（"全都摆
  /// 出来让我挑"），签名形状本来就不同。
  mut on_search_lyrics : ((String, String, (Array[LyricSearchResult]) -> Unit) -> Unit)?
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
  /// 手动重扫回调（`T172`，壳提供：按已有目录重走行走 + 探针后替换曲库）。
  /// 与 `on_add_dir` 一样是注入而不是本体自己扫：本体不碰文件系统。
  on_rescan : () -> Unit
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
  /// 托盘菜单上一拍的签名（`T183`）：曲路径 + 模式 + 音量‰。菜单里的动态
  /// 文案（当前曲/模式/音量）没有 set_text 可走，变了只能整菜单重设——
  /// refresh_bar 每 300ms 一拍，靠签名边沿把重设压到"真的变了"才发生。
  mut tray_sig : String
  /// 「正在播放」上一拍的签名（`T181`）：曲路径 + 显示口径 + 位置秒 + 播放态。
  /// 推送时机归应用侧（trait 注）：签名没变不推，控制中心不吃重推的账。
  mut np_sig : String
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
  /// 进度条的 seek 正在跑（`T149`）。
  ///
  /// `T149` 把滑块的 `Change` 改成**实时直达**之后，`on_seek_slider` →
  /// `player.seek` → `broadcast` → `refresh_bar` 这一圈整个跑在**用户正拖着
  /// 那颗滑块**的原生回调里。`refresh_bar` 照旧按引擎位置回写进度滑块，而
  /// 这句话现在落在 `NSSlider` 自己的跟踪循环中间：拖动中被 `setDoubleValue:`
  /// 拽一下，拇指就跳走，接着下一颗 `mouseDragged` 又从新位置算——拖着走不直。
  /// 这一圈跳过回写，自绘填充改由 `on_seek_slider` 按用户拖到的千分位画。
  mut seeking : Bool
  // ——迷你条歌名跑马灯（2026-11-05 三修③）——
  /// 跑马灯的周期链句柄（长命，点火/停链都挂在它上面）。
  marq_ticker : @moonui.Ticker
  /// 正在滚的整句歌名。`refresh_bar` / `toggle_mini` 都经 `mini_marquee_sync`
  /// 进来，文字只有这一个写入口——不然每 500ms 的心跳会把整句灌回去，
  /// 滚动每半秒被顶掉一帧。
  mut marq_full : String
  /// 滚动起始字符下标（按 Char，不按字节）。
  mut marq_i : Int32
  /// 一格装得下的字符数（按平均字宽估，再用真实切片宽校准）。
  mut marq_fit : Int32
  /// 头/尾停拍的剩余拍数。
  mut marq_hold : Int32
  /// 尾停中：滚到句尾停 MARQ_HOLD_TICKS 拍后回头部。
  mut marq_at_end : Bool
  // ——均衡器（第二期：真·十段，拖得动、进音频链路）——
  /// 十段增益，单位千分位（500 = 0dB；换算见 ui_eq.mbt 的 gain_mdb_of）
  eq_bands : Array[Int32]
  mut eq_on : Bool
  // ——音量归一化（`T170`）：开关偏好 + 每曲响度缓存挂在 Track 上——
  /// 归一化总开关（「播放」菜单勾选项，选择随偏好档落盘）。开着但当前曲
  /// 没有测值 = 不挂增益（不猜），测值由壳后台批量分析逐首补。
  mut normalize : Bool
  // ——皮肤（第二期：换肤）——
  /// 当前皮肤的标识：内置皮肤名，或皮肤档的路径。启动时靠它恢复——内置表里
  /// 查得到按名取，查不到就当路径让壳去读（文件被删/改名则退回默认皮肤）。
  mut skin : String
  /// 歌名/歌手这两格按文件名还是按标签显示（`T193`）。默认文件名，界面上
  /// 「控制 → 歌曲信息显示」可切，选择随偏好档落盘。
  mut display : DisplaySource
  /// 从目录加载皮肤（壳：选目录 → 扫皮肤档 → 逐个回调 `add_skin_file`）。
  /// 无头不传。
  on_load_skin_dir : () -> Unit
  /// 导出当前皮肤（壳：弹保存面板 → 写文本）。无头不传。
  on_save_skin : (String) -> Unit
  /// 目录里加载进来的皮肤（路径 + 皮肤本体）。菜单按这份追加，切回内置也不丢。
  mut extra_skins : Array[(String, Skin)]
  /// 自绘顶条版本的快捷键登记过了没有（`T116`，见 `cm_install_strip_shortcuts`）
  mut strip_shortcuts : Bool
  /// 上一拍高亮的那首（路径，`""` = 没有当前曲）。`T153`：列表行的高亮是
  /// 建行那一刻烤进去的，只有"当前曲换了"才需要重建窗内那十来行；按路径认边沿
  /// 而不是每拍都重建（`was_playing` 认的是播放/暂停边沿，切歌时它一直是 true，
  /// 借用不上）。
  mut lit_path : String
  /// 播放条上**已经灌进去**的封面属于哪首（路径，`""` = 还没灌过，`T174`）。
  ///
  /// 只按路径认边沿：`set_image_bytes` 会让后端当场解码一张图，每拍调一次
  /// 等于每 300ms 解一遍同一张——按路径比对才只灌一次。
  ///
  /// **`rebuild_ui` 要把它清回 `""`**：重建会把 Image 控件整个换成新的
  /// （内容是空的），边沿账却还记着"灌过了"——不清账的话重建后这格永远
  /// 空白（owner 2026-11-04 截图钉出来的：复位窗口之后封面没了）。
  /// `lit_path` 是同一批账（见下），同一个规矩。
  mut cover_path : String
  /// 那格图**现在是不是占位图**（与 `cover_path` 成对）。
  ///
  /// 没在播（`track()` 是 None）时也灌占位图（owner 2026-11-04 点的），但
  /// refresh_bar 每 300ms 跑一拍——占位图也得有边沿，不然就是每拍重生成
  /// 重解码一遍。真路径的边沿记在 `cover_path` 上，占位图的记在这格：
  /// 没在播时它已经是 true 就不再灌；一回放就照常走路径边沿。
  mut cover_placeholder : Bool
  /// 播放详情伴窗开着没有（`T180`）。窗本体随 `rebuild_ui` 一起建（显隐开关
  /// 不是存在开关，与 EQ/迷你条同一条形状），默认收起——启动 show 次序
  /// （`T210`）因此不涉及它，运行时从菜单/托盘拉开，主控 key 账照常。
  mut detail_open : Bool
  /// 列表多选（`T177`）：按 **path** 记，不按行号——排序 / 搜索 / 切页签之后
  /// 行号会指到别的曲目，path 不会（`T102` 那次"位置与身份分家"的同一条）。
  ///
  /// 视图变化（排序 / 搜索 / 切页签）**不清空**：换过去再换回来，选中的那几首还
  /// 在。清空的只有「清空」这颗按钮（列表本身都没了）；重扫不清——path 还是那些
  /// path，被删掉的那几首留在集合里也不指错行（`is_selected` 只按 path 比对）。
  selected : Array[String]
  /// 「编辑信息」小窗（`C-16`）。**懒建一次就不再重建**：`rebuild_ui` 整树重挂
  /// 会销毁原生输入控件，正在打的字、光标、输入法状态全丢（`demo.mbt` 记过）。
  mut edit : EditDialog[B]?
  /// 「搜索歌词」小窗（`T161`①）。同 `edit`：懒建一次就不再重建。
  mut search_dlg : LyricSearchDialog[B]?
  /// 拖动歌词定位中的位置（`T161`②，毫秒）。`None` = 没在拖。
  ///
  /// 这一格与 `seeking`（进度滑块那条账）**分开记**：两个拖动源各有一条
  /// 独立的拖动期，混在一起会让滑块的 `Change` 回写逻辑误判（`T149`）。
  mut lyric_drag_ms : Int64?
  /// 把三个字段写回音频文件本体（壳提供）。返回 `Written` 才算成功。
  ///
  /// 注入而不是直接调 `cm_write_tags` + `file_write_bytes_atomic`，跟
  /// `probe_many` 同一条理由：这才让本体不碰文件系统，wasm 门禁编得过，
  /// 无头测试能用假实现走完整条链路（含失败分支）。
  write_tags : (String, String, String, String) -> TagWriteResult
  /// 曲库档变了（壳提供：立刻落 `lunamusic-library.json`）。
  ///
  /// 必须即时落盘：曲库档本来只在退出时存一次，而恢复时是"直接入账不重探"，
  /// 不马上写的话下次启动会读回旧标题——文件里明明已经改了，界面却是旧的。
  on_library_changed : () -> Unit
  /// 睡眠定时（`T185`）：到点时刻（ms，与壳心跳同一只钟，`sleep_clock` 注入）。
  /// `None` = 没设。判账在 `refresh_bar` 头上（`sleep_check`）——那是既有心跳
  /// 每拍都进的口，不另起线程，也不用 `post_after`（应用没挂 `anim_clock`，
  /// 延时任务会当场落到下一拍就跑，`T152` 的账）。判账按 32 位取模，理由在
  /// `sleep_check`（`T221`）。
  mut sleep_due_ms : Int64?
  /// 睡眠定时当下选中的档位（分钟，0 = 关闭）：菜单打勾用。
  mut sleep_mins : Int32
  /// 毫秒钟（壳注入 wall clock，测试注 mock）。注入而不是直接调平台钟：
  /// 应用本体不碰后端平台面（与 `probe_many` 同一条纪律），无头测试也能
  /// 拨钟走真实的到期链路。
  sleep_clock : () -> Int64
  /// 队列拖拽重排（`T176`）的插入位：插到第 pos 行**之前**（0..=队列长度）。
  /// `None` = 没在拖。DragOver 每条移动都发，这里只记边沿（变了才重建行）；
  /// 拖拽期间的显示归拖拽状态机所有，心跳不碰（`T207` 单一写入口的教训），
  /// 会话没了残留的账由 `refresh_bar` 头上的清尾收掉。
  mut drag_ins : Int32?
  /// 拖拽的**源行**（按下句柄那一行，`T176`）。DragDrop 派给的是落点行，
  /// 源行号不能从落点的闭包拿——按下时记在这里，落点写账时消费。
  mut drag_src : Int32?
  // ——用户自建歌单（`T175`）——
  /// 歌单账（名称 + 路径清单）。存**偏好档**不是曲库档：歌单是状态账（用户
  /// 排的心意），曲库是数据账——只在退出时随 Prefs 一起落盘。
  mut playlists : Array[Playlist]
  /// 歌单命名小窗（新建/重命名共用，`T175`）。同 `edit`/`search_dlg`：懒建
  /// 一次就不再重建——`rebuild_ui` 整树重挂会销毁原生输入控件，正在打的字
  /// 全丢。
  mut name_dlg : PlaylistNameDialog[B]?
}

///|
/// 迷你模式那条窄条（Luna的「迷你模式」）：歌名 + 上/播/下 三颗钮，
/// 没有频谱和进度——原版迷你条就是这么窄。歌名格是弹性格（`with_expand(true)`
/// 吃掉按钮之外的整段宽），但 Sized/Expand 不进 Core 的 placed 表、自己没有
/// frame 可读——格宽由**紧挨格子的上一颗钮**（prev）反推（见 `mini_marquee_sync`；
/// 不能拿 next：中间还隔着 toggle，反推出来会凭空多出两颗钮的宽）。
pub(all) struct MiniBar[B] {
  root : @moonui.Widget[B]
  title : @moonui.Widget[B]
  prev : @moonui.Widget[B]
  toggle : @moonui.Widget[B]
  next : @moonui.Widget[B]
}

///|
pub fn[B : @platform-services.PlatformServices] MiniBar::new(
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
  // 不让位的话三颗圆钮正好盖在歌名上。
  let mac = @moonui.Backend::host_platform(b) == Macos
  let cells : Array[@moonui.Widget[B]] = []
  if mac {
    cells.push(
      @moonui.Widget::sized(b, Some(62.0), None, @moonui.Widget::spacer(b)),
    )
  }
  // 歌名在自己的 24pt 格里也要垂直居中：Row 的固定项贴交叉轴起点摆
  // （layout_line 的规矩），label 直接进去会顶在格子上沿——上下各垫一只
  // expand spacer 才是真居中（与主窗顶条 `title_centered` 同一手筋）。
  // 格子横向弹性（2026-11-05 三修②）：吃掉按钮之外的整段宽，按钮自然靠
  // 右，右侧不再留一截没人认领的底色；宽了也正好给跑马灯用（三修③）。
  let title_cell = @moonui.Widget::sized(
    b,
    None,
    Some(24.0),
    @moonui.Widget::column(b, 0.0, [
      @moonui.Widget::spacer(b).with_expand(true),
      title,
      @moonui.Widget::spacer(b).with_expand(true),
    ]),
  ).with_expand(true)
  cells.push(title_cell)
  cells.push(@moonui.Widget::sized(b, Some(26.0), Some(24.0), prev))
  cells.push(@moonui.Widget::sized(b, Some(30.0), Some(24.0), toggle))
  cells.push(@moonui.Widget::sized(b, Some(26.0), Some(24.0), next))
  let row = @moonui.Widget::row(b, MINI_BAR_GAP, cells)
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
  // 根不套 `cm_band`（2026-11-04 抓图的四病）：`cm_band` 外层是
  // `sized(w=None)`，宽取内容固有（~248），300 宽的窗右边就露一条底色空白；
  // 上下那对 1px 倒角线在迷你条上也成了白/黑杂线。Panel 直接当根——relayout
  // 把整窗矩形交给根，`cm_page_bg` 自然铺满 300x48，倒角线也随之消失。
  let root = @moonui.Widget::panel(b, inner).background(cm_page_bg())
  { root, title, prev, toggle, next, }
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
  /// 播放详情伴窗（大封面 + 大字歌词，`T180`；默认收起）
  detail_win : @moonui.Window[B]
  table : TrackTable[B]
  bar : PlayBar[B]
  lyrics : LyricsView[B]
  desk : DeskLyrics[B]
  detail : DetailView[B]
  mini : MiniBar[B]
  eq : EqPanel[B]
}

///|
/// 装配：库档与偏好档由调用方先读好，经 `lib~` / `prefs~` 传进来（不给就按
/// 空库 / 默认偏好起步）。**`new()` 末尾那一次 `rebuild_ui` 就是定稿树**
/// （`T123`）——壳不再有第二次整树重建；皮肤恢复在这里只铺状态不走
/// `set_skin`（它自带整树重建，启动期叠上去就是把省掉的那棵树又建回来）。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::new(
  app : @moonui.App[B],
  engine : A,
  frame~ : @moonui.WindowFrame? = None,
  lib~ : Library = Library::new(),
  prefs~ : Prefs = Prefs::new(),
  on_add_dir~ : () -> Unit = fn() { () },
  on_rescan~ : () -> Unit = fn() { () },
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
  on_fetch_online~ : ((
    String,
    Array[(String, String)],
    Double,
    (String, String?) -> Unit,
  ) -> Unit)? = None,
  on_search_lyrics~ : ((String, String, (Array[LyricSearchResult]) -> Unit) -> Unit)? = None,
  write_tags~ : (String, String, String, String) -> TagWriteResult = fn(
    _path : String,
    _t : String,
    _a : String,
    _al : String,
  ) -> TagWriteResult {
    // 无头默认：没有文件系统，明说写不进去，不假装成功。
    UnsupportedFormat
  },
  on_library_changed~ : () -> Unit = fn() { () },
  sleep_clock~ : () -> Int64 = fn() { 0 },
) -> LunaMusicApp[B, A] raise @moonui.UiError {
  let player = Player::new(engine, lib.tracks)
  let cm : LunaMusicApp[B, A] = {
    app,
    lib,
    player,
    ui: None,
    lyrics_path: "",
    current_lyrics: [],
    lyrics_asked_path: "",
    on_fetch_online,
    on_search_lyrics,
    frame,
    show_pl: true,
    // 均衡器起手收起：原版主控默认只露主控 + 歌词 + 列表，EQ 是"要用才拉开"
    // 的深设置。窗照建（`show_eq` 是显隐开关，不是存在开关），EQ 钮 / 菜单
    // 一切就出来。
    show_eq: false,
    show_lrc: true,
    on_add_dir,
    on_rescan,
    probe_many,
    tab: 0,
    sort_key: ByIndex,
    sort_asc: true,
    query: "",
    view: [],
    prop_path: None,
    mini: false,
    rolled: false,
    tray_sig: "",
    np_sig: "",
    show_desk: true,
    desk_shown: false,
    spectrum_lit: false,
    on_play: None,
    was_playing: false,
    seeking: false,
    marq_ticker: @moonui.Ticker::new(),
    marq_full: "",
    marq_i: 0,
    marq_fit: 0,
    marq_hold: 0,
    marq_at_end: false,
    eq_bands: eq_flat_bands(),
    eq_on: true,
    normalize: false,
    skin: cm_skin_current().name,
    display: cm_display_source_default(),
    on_load_skin_dir,
    on_save_skin,
    extra_skins: [],
    strip_shortcuts: false,
    lit_path: "",
    cover_path: "",
    cover_placeholder: false,
    detail_open: false,
    selected: [],
    edit: None,
    search_dlg: None,
    playlists: [],
    name_dlg: None,
    lyric_drag_ms: None,
    write_tags,
    on_library_changed,
    sleep_due_ms: None,
    sleep_mins: 0,
    sleep_clock,
    drag_ins: None,
    drag_src: None,
  }
  // 播放器状态变化 → 播放条刷新（player 的 notify 广播，C-08）
  player.on_update(fn() { cm.refresh_bar() catch { _ => () } })
  // ——起步恢复（`T123`：全部只铺状态，下面那次 `rebuild_ui` 第一次就是定稿树）——
  // prefs 用默认值时每一条要么 no-op 要么与上面字面量里的默认同值。
  cm.player.set_volume(prefs.volume)
  cm.player.mode = prefs.mode
  // 显示口径直接赋：`set_display` 会重挂菜单栏并刷一遍旧树——启动期树还没建、
  // 菜单栏由壳在恢复完之后统一装（`cm_build_menus` 读当下的 `display`，打勾
  // 不会错）。
  cm.display = prefs.display
  cm.show_desk = prefs.show_desk
  // EQ 恢复：档里的十段直接推给引擎（关掉再打开 EQ 还在，与原版一致）
  for i = 0; i < cm.eq_bands.length(); i = i + 1 {
    if i < prefs.eq_bands.length() {
      cm.eq_bands[i] = prefs.eq_bands[i]
    }
  }
  cm.eq_on = prefs.eq_on
  cm.push_eq()
  // 归一化开关恢复（`T170`）：只铺状态（菜单由壳在恢复完之后统一装，打勾
  // 不会错）。开着时对恢复出来的曲子当场补挂—— Player::new 默认关、load
  // 已归零，这里不补就欠一拍。
  cm.normalize = prefs.normalize
  cm.player.set_normalize(cm.normalize)
  // 歌单账恢复（`T175`）：随偏好档一起读回，页签/视图在 rebuild_ui 时按它铺。
  cm.playlists = prefs.playlists
  // 皮肤恢复：先按内置名找，找不到就当皮肤档路径读（文件被删/改名 → 默认
  // 皮肤）。只铺状态不走 `set_skin` / `add_skin_file`——那两条都带整树重建，
  // 启动期后面紧跟的 `rebuild_ui` 会把同一棵树再建一遍。
  if prefs.skin != "" {
    match cm_skin_by_name(prefs.skin) {
      Some(s) => {
        cm_skin_set(s)
        cm.skin = s.name
      }
      None => {
        let text = @moonui.Fs::read_text(prefs.skin) catch { _ => None }
        match text {
          Some(t) =>
            match Skin::from_text(t) {
              Some(s) => {
                cm.extra_skins.push((prefs.skin, s))
                cm_skin_set(s)
                cm.skin = prefs.skin
              }
              None =>
                println(
                  "皮肤档读不懂，按默认皮肤起步：\{prefs.skin}",
                )
            }
          None =>
            println(
              "皮肤档找不着，按默认皮肤起步：\{prefs.skin}",
            )
        }
      }
    }
  }
  // 最后播放：在**播放队列**里按 path 找（不是曲库下标）：`prepare` 的 idx
  // 是队列下标，而队列在排序/搜索之后是视图那一份——拿曲库下标去喂它，一旦
  // 两者不同序就装到别的歌上（`T177` 那次"位置与身份分家"的同一条）。
  // 装而**不播**——`prepare` 把状态记成 Paused，按 ▶ 从那儿继续。装不上
  // （文件被删）时 `prepare` 记一条 `last_error` 就停，状态行会说
  // "无法播放：xxx"，而不是让启动看起来一切正常却没声。
  match prefs.last_path {
    Some(p) => {
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
  // 媒体键与全局热键（`T181`）：两条来路汇到 `media_action` 同一入口。装在
  // `new` 尾上——测试用 mock 时回调同样就位（fire_media_key/fire_hotkey 直接触
  // 发），真后端没接的平台（Windows）C 返 -3、这条静默，回调永不触发。
  let npb = cm.app.backend()
  npb.on_media_key(fn(code) { cm.media_action(code) })
  npb.set_global_hotkeys(fn(code) { cm.media_action(code) })
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
fn[B : @platform-services.PlatformServices] cm_place_traffic_lights(
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
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::rebuild_ui(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  let b = self.app.backend()
  // ——顶条（Luna招牌）：深蓝底 + ♪ Luna + 窗口钮——
  // 沉浸式标题栏下 mac 红绿灯浮在内容左上、Windows 没有系统按钮，所以这条
  // 顶条两侧都得跟着平台走：mac 左边让出红绿灯的位置、右侧一颗自绘钮都不画
  // （系统已经给了）；其余平台（Windows/Web/未知）反过来，左侧不用让位、
  // 右侧补上最小化/最大化/关闭。平台血统问后端（`HostPlatform` 的段注）。
  let mac = @moonui.Backend::host_platform(b) == Macos
  let logo = @moonui.Widget::label(b, "♪ Luna")
    .foreground(cm_text_light())
    .font_size(13.0)
    .font_weight(Bold)
  // 四组菜单收进自绘顶条（`T116`）：Windows 上没有系统菜单栏可摆，四组菜单
  // 变成 logo 右边四颗文字钮，点了在光标处弹同一棵菜单（复用上下文菜单通道）。
  // mac 那支不建——那边的系统菜单栏照旧装着，再画四颗就是两套菜单。
  let menu_buttons : Array[@moonui.Widget[B]] = []
  if !mac {
    let menus = self.cm_build_menus()
    for m in menus {
      let btn = @moonui.Widget::button(b, m.title())
      cm_btn_skin(btn, cm_titlebar_bg(), cm_text_light(), 10.0)
      let _ = btn.with_on_click(fn() {
        @moonui.Backend::show_context_menu(b, m) catch {
          _ => ()
        }
      })
      menu_buttons.push(btn)
    }
  }
  let title_row = if mac {
    // 「复位窗口」：mac 上顶条右侧那唯一一颗自绘钮（三颗系统圆钮在左边）。
    // **Windows 上它不建**——顶条装不下：四组菜单钮 + 这颗 + 三颗窗口钮实测
    // 419 宽而窗只有 380，「✕」整颗掉到窗外。那侧它落在「窗口」菜单里
    // （见 `cm_build_menus`），功能一点没少。
    let btn_reset = @moonui.Widget::button(b, "复位窗口")
    cm_btn_skin(btn_reset, cm_btn_bg(), cm_text_light(), 9.0)
    let _ = btn_reset.with_on_click(fn() { self.reset_layout() })
    @moonui.Widget::row(b, 6.0, [
      // 让位宽与四只伴窗顶条共用 `cm_traffic_reserve_w()`（红绿灯整簇
      // 7…61，留 62 不叠）；内边距、格距也收到 6/6，`♪ Luna` 与伴窗标题
      // 从此落在同一条竖线上（`T257`）。
      @moonui.Widget::sized(
        b,
        Some(cm_traffic_reserve_w()),
        None,
        @moonui.Widget::spacer(b),
      ),
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
    // 窗口钮接线：最小化 / 最大化↔还原 / 关闭。没有系统标题栏就没有系统按钮，
    // 这三颗是窗口上唯一的窗口控制（`T116`）。
    let _ = btn_min.with_on_click(fn() {
      match self.ui {
        Some(u) => u.window.set_minimized(true) catch { _ => () }
        None => ()
      }
    })
    // 最大化那颗是开关：先读当下的态再决定往哪边翻。主控窗本身不可缩放
    // （`set_resizable(false)`，皮肤图定尺），所以这颗在主控上是空操作——留着
    // 是为了树形状与 mac 那支对称，将来主控改成可缩放时不用再动结构。
    let _ = btn_mini.with_on_click(fn() {
      match self.ui {
        Some(u) => {
          let st = Some(u.window.window_state()) catch { _ => None }
          match st {
            Some(s) => u.window.set_maximized(!s.maximized) catch { _ => () }
            None => ()
          }
        }
        None => ()
      }
    })
    let _ = btn_close.with_on_click(fn() { self.app.quit() })
    // 复位钮（`T120`）：`T116` 当时把它整颗赶下了顶条——四个菜单钮 + 「复位窗口」
    // + 三颗窗口钮实测 419 宽而窗只有 380，「✕」整颗掉到窗外。这一轮改的是
    // **它自己的长度**而不是删它：标签缩成「复位」（省 30），格间距与左右内边距
    // 8→6（省 16），重新量出的右缘 356 < 372，留出 16 的余量给后端字体差异。
    // 菜单里那条「复位窗口」照留（`cm_build_menus`），两处都能进，功能不重复记账。
    let btn_reset = @moonui.Widget::button(b, "复位")
    cm_btn_skin(btn_reset, cm_btn_bg(), cm_text_light(), 9.0)
    let _ = btn_reset.with_on_click(fn() { self.reset_layout() })
    // 三颗窗口钮定宽（`T116`，与伴窗顶条那颗 ✕ 同一手法）：按钮的固有宽由后端
    // 报（Win32 走 BCM_GETIDEALSIZE、mock 是另一套），不定宽的话顶条总宽会随后
    // 端浮动——本机实测 380 装得下，CI 的 mock 量出来 386 就溢出。窗口钮本来就该
    // 等宽（系统标题栏上也是三个一样宽的方块），定死后两端读数一致。
    let cells : Array[@moonui.Widget[B]] = [logo]
    for btn in menu_buttons {
      cells.push(btn)
    }
    cells.push(@moonui.Widget::spacer(b).with_expand(true))
    cells.push(btn_reset)
    cells.push(@moonui.Widget::sized(b, Some(24.0), None, btn_min))
    cells.push(@moonui.Widget::sized(b, Some(24.0), None, btn_mini))
    cells.push(@moonui.Widget::sized(b, Some(24.0), None, btn_close))
    // 格间距 8→3（`T120`）：这是给「复位」腾位置的另一半。真机 Win32 字体下
    // 8 也能装，但 mock 的度量是"每字符 8px × 字号/12"的启发式，`♪ Luna` 那颗
    // 量出 73（真机 58.4），间距 8 时整行顶到 387、最后三颗窗口钮被压成 0 宽。
    // 收到 3 之后两端都留出余量（mock 约 363/374、真机约 356/374），吃的住后端
    // 字体差异。间距再小就贴在一起了，3 是这一行还能看的下限。
    @moonui.Widget::row(b, 3.0, cells)
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
  // 左右内边距：mac 由 8 收到 6 与伴窗同口径（`T257`）；Windows 那支原本
  // 就是 6，值不变——`T120` 为它省下的 4pt 是给「复位」与三颗窗口钮的。
  let title_inner = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(0.0, 6.0),
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
  // [B : @platform-services.PlatformServices] 会被编译器判成 unused_trait_bound（B 只在调
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
  let lyrics = LyricsView::new(b, fn(idx) { self.scrub_to_lyric(idx) }, fn() {
    self.end_lyric_scrub()
  })
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
      self.view = self.compute_view()
      self.refresh_table()
    },
    on_sort: fn(k : Int32) { self.set_sort(k) },
    on_tab: fn(t : Int32) { self.set_tab(t) },
    on_rescan: fn() { (self.on_rescan)() },
    on_playlist_new: fn() { self.new_playlist() catch { _ => () } },
    on_playlist_rename: fn(pi : Int32) {
      self.rename_playlist(pi) catch {
        _ => ()
      }
    },
    on_playlist_delete: fn(pi : Int32) {
      self.delete_playlist(pi) catch {
        _ => ()
      }
    },
  }
  let table = TrackTable::new(
    b,
    self.view.length(),
    self.tab_title(),
    self.tab,
    self.playlist_tab_names(),
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
  let mini_bar = MiniBar::new(
    b,
    fn() { self.player.prev() },
    fn() { self.player.toggle() },
    fn() { self.player.next() },
  )
  let detail = DetailView::new(b)
  let (main, lyrics_win, playlist_win, eq_win, mini_win, desk_win) = match
    self.ui {
    Some(u) =>
      (u.window, u.lyrics_win, u.playlist_win, u.eq_win, u.mini_win, u.desk_win)
    None => {
      // 六只窗的落座全来自 cm_default_layout：建窗与「复位窗口」共用一份
      // 坐标，改这里两处一起变。（主控尺寸与面板五段高度同源，差一个像素
      // 就会在底部留一条空带。）
      let screen = @moonui.Backend::screen_size(self.app.backend()) catch {
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
      // `T192`：桌面歌词是**辅助浮条**，关它不是"我不要这只窗了"，是"先收起来"。
      // 按默认的 `Destroy` 走有两个后果，owner 报的是第二个：内容树整棵销毁
      // （重建要整窗重挂），以及 500ms 心跳下一拍就往销毁掉的 Label 上写文案，
      // `Destroyed` 从心跳里抛出去、`App::run` 收尾、进程退出。`Hide` 把它变成
      // 一次 `orderOut:`，歌词窗随时能从菜单/托盘叫回来。
      dw.set_close_action(@moonui.Hide)
      (main, lw, pw, ew, mw, dw)
    }
  }
  // 播放详情伴窗（`T180`）：窗照建、默认收起——与 EQ/迷你条同一条形状（显隐
  // 开关不是存在开关），菜单/托盘「播放详情」一拉就出来。落座走同一份
  // `cm_default_layout`（detail 格），复位窗口共用一套坐标。默认收起意味着
  // `startup_windows` 不含它：`T210` 的启动 show 次序一字不动。
  let detail_win = match self.ui {
    Some(u) => u.detail_win
    None => {
      let screen = @moonui.Backend::screen_size(self.app.backend()) catch {
        _ => @moonui.LogicalSize(1440.0, 900.0)
      }
      let lay = cm_default_layout(screen)
      let detw = self.app.create_window(
        "播放详情",
        @moonui.LogicalSize(lay.detail.w, lay.detail.h),
      )
      cm_adopt_window(detw, lay.detail)
      // 心跳会往详情窗的 Label 上写文案：按默认 Destroy 关窗是内容树整棵
      // 销毁、下一拍 `Destroyed` 从心跳里抛出去（`T192` 桌面歌词的同一条
      // 课）。`Hide` 收起来，随时能再叫回来。
      detw.set_close_action(@moonui.Hide)
      detw
    }
  }
  // 六只窗统一沉浸式标题栏：内容铺满整窗，自绘顶条**就是**标题栏本身。
  // 不设的话每只窗顶上还压着一条系统标题栏（灰色渐变 + 窗口名），跟下面的
  // 皮肤是两块料，怎么调都不"沉浸"。建窗那一趟已经由 `cm_adopt_window` 先
  // 设过（顺序原因见那条注释），这里兜住"复用旧窗"的路径；重复设是幂等的。
  for
    w in [
      main, lyrics_win, playlist_win, eq_win, mini_win, desk_win, detail_win,
    ] {
    let _ = w.set_titlebar_style(Immersive) catch { _ => () }
  }
  // 红绿灯摆进各自顶条的中线（顺序要紧：先切沉浸式再摆位——切 styleMask 会让
  // AppKit 把按钮重排回默认位置，原生层虽然会重放，这里仍按"先样式后位置"写）。
  // 桌面歌词没有顶条：它是浮在屏幕底部的一条，红绿灯留在左上角那 6pt 处即可。
  if mac {
    cm_place_traffic_lights(main, cm_title_h())
    for w in [lyrics_win, playlist_win, eq_win, detail_win] {
      cm_place_traffic_lights(w, cm_strip_h())
    }
    cm_place_traffic_lights(mini_win, 48.0)
  }
  // 属性栏文案：右键「属性」钉住的那首（没有就显示提示语）
  let _ = table.prop.set_text(self.prop_text())
  // 顶条双击 = 进/出迷你模式（`T182`）：卷起是 Luna 原版语义，但"双击窗口
  // 顶端"用户预期的是"变小但仍可用"；主控是定尺皮肤窗（`set_resizable(false)`
  // 锁死），mac 实测 zoom 对它只翻标志位、窗框不动，真最大化做不实——迷你
  // 模式是同一手势下站得住的落点。菜单里仍保留「卷起/展开」；迷你条双击
  // 切回，手势对称。
  let _ = title_bar.with_on_double_click(fn() {
    self.toggle_mini() catch {
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
  let lrc_strip = CmStrip::new(
    b,
    "歌词秀",
    fn() {
      self.show_lrc = false
      lyrics_win.hide() catch {
        _ => ()
      }
    },
    actions=[("搜索歌词", fn() { self.open_search_lyrics() })],
  )
  let lrc_root = cm_window_shell(b, lrc_strip.root, lyrics.root, 4.0)
  let det_strip = CmStrip::new(b, "播放详情", fn() {
    self.detail_open = false
    detail_win.hide() catch {
      _ => ()
    }
  })
  let det_root = cm_window_shell(b, det_strip.root, detail.root, 4.0)
  main.set_content(main_root)
  lyrics_win.set_content(lrc_root)
  playlist_win.set_content(pl_root)
  eq_win.set_content(eq_root)
  mini_win.set_content(mini_bar.root)
  // 迷你条双击 = 回主控（`T182`，与顶条双击对称）。挂冒泡口（`T141`），
  // 条上除三颗走带钮自己外，双击哪里都算。
  let _ = mini_bar.root.with_on_double_click(fn() {
    self.toggle_mini() catch {
      _ => ()
    }
  })
  desk_win.set_content(desk.root)
  detail_win.set_content(det_root)
  // 首次显示不在这里（`T122`）：启动期还要读预置档、装菜单栏/托盘、再换一次树，
  // 那之前窗口露出来只会是一块白板。`present()` 由壳在 `app.run()` 前调一次。
  self.ui = Some({
    window: main,
    lyrics_win,
    playlist_win,
    eq_win,
    mini_win,
    desk_win,
    detail_win,
    table,
    bar,
    lyrics,
    desk,
    detail,
    mini: mini_bar,
    eq,
  })
  // 整树刚建，行的高亮就是按当下 `player.current` 烤的——把边沿记账对齐到
  // 这一版，免得 `refresh_bar` 头一拍就白重建一遍窗内的行（`T153`）。
  self.lit_path = self.player.now_path()
  // 封面同一条：Image 是新建的（内容空），边沿账清回"没灌过"，下一拍
  // refresh_bar 会照常灌（owner 2026-11-04：复位窗口后封面格空白）。
  self.cover_path = ""
  self.cover_placeholder = false
  self.refresh_bar()
  self.refresh_lyrics() catch {
    _ => ()
  }
}

///|
/// 首次呈现（`T122`）：启动期该做的事（预置档、菜单栏、托盘、第二次 `rebuild_ui`）
/// 全做完、`app.run()` 之前由壳问一次"开局该露哪几只窗"，再逐只 `show()`。
///
/// 为什么不放在 `rebuild_ui` 里——那样窗口会在建树①之后立刻露出来，而壳那边还要
/// 读预置档再换一次树、装菜单栏和托盘，到主循环起跑之前没有任何消息泵，用户看到的
/// 就是一块空白（真机实测：显示后约 100ms 里五块内容是整片单色，见 `T121` 的量测）。
/// 挪到启动末尾之后，窗口第一次露出来时树已定稿，`ShowWindow` 排下的整树失效
/// （`T121`）由主循环第一圈兑现；顺带省掉"树①建了又拆"的那一趟。
///
/// 返回列表而不是在这里 `show()`：`Window::show` 要 `B : Backend`，而这个方法上
/// 只写这个 bound 会被编译器判成 unused_trait_bound（检查器不认 `Window::show`
/// 那条路径，`rebuild_ui` 里 `aux_show` 那条注释记的是同一件事），所以"挑哪几只"
/// 留在这儿、"show" 交给本来就有 bound 的壳。
///
/// 均衡器默认不露（`show_eq` 起手 false）：窗已经建好、也摆好了落点，只是不显示，
/// EQ 钮一按 `aux_show(true, ...)` 就贴回原处。桌面歌词开局通常还没有歌词，照
/// `cm_desk_visible` 判一次，不满足就不挂——空条挂在屏幕上比不挂更糟；`desk_shown`
/// 记的就是这一判的落点，后面的心跳 sync 按它走边沿。
pub fn[B, A] LunaMusicApp::startup_windows(
  self : LunaMusicApp[B, A],
) -> Array[@moonui.Window[B]] {
  let windows : Array[@moonui.Window[B]] = []
  match self.ui {
    None => ()
    Some(u) => {
      windows.push(u.window)
      windows.push(u.lyrics_win)
      windows.push(u.playlist_win)
      if self.show_eq {
        windows.push(u.eq_win)
      }
      let desk_on = cm_desk_visible(
        self.show_desk,
        self.mini,
        self.current_lyrics.length() > 0,
      )
      if desk_on {
        windows.push(u.desk_win)
      }
      self.desk_shown = desk_on
    }
  }
  windows
}

///|
/// 表格行的格子：定宽（None = 透传给子项/交给外层弹性）+ 行带定高，内容在
/// 格内**垂直居中**、水平保持起点。为什么要这层居中：行带是 VirtualList 锁
/// 的 20pt（ui_table 的 CM_ROW_HEIGHT），格内容（文字 Label）的固有高只有
/// ~13pt，而 Row 的交叉轴是顶对齐——文字贴着行带顶，hover 底一亮就看得出
/// 没居中（真窗探针实锤：NSTextField 自己不居中，字形贴着框顶画）。上下各
/// 垫一只弹性 Spacer 把余量对半分，就是纯布局的垂直居中；Column 的横对齐
/// 维持起点，标题列的长文案不会被拖到中间去。
fn[B : @platform-services.PlatformServices] cm_row_cell(
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
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::build_row(
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
  // 标题/歌手两列按显示口径投影（`T193`）：库里存的始终是探针真值，
  // 这里只决定画哪一份。
  let (shown_title, shown_artist) = cm_display_fields(t, self.display)
  let cur = self.player.current
  let playing = cur is Some(c) && c == i
  let mark = if playing { "▶ " } else { "" }
  // 皮肤（`T226`）：accent 浅底那几行（当前曲 / 选中 / 拖放落点）整行用主文字
  // 色，accent 不再染行内文字。原来当前曲是整行蓝字压浅蓝底——经典蓝 3.87:1、
  // 青竹 3.53:1，10px 正文门槛 4.5:1 不过，真机上"看不清"（owner 2026-11-06）。
  // 身份标记留给「▶ 」前缀 + 标题加粗（选中行只换底色、不加粗）。
  // 判据与底色同一份（`row_is_accent`），不在这里重写条件。
  //
  // 已知边界：拖拽中的落点行由 `restyle_row_bg` 只改底色（拖拽循环里不能重建
  // 行，`T207`/`T176` 的既有约束），**已经建好的行**在拖拽开始后文字色不会跟着
  // 变；拖拽期间滚进窗口的新行会拿到正确前景。这里不做就地刷前景。
  let row_fg = if self.row_is_accent(i, t, playing) {
    Some(cm_ink())
  } else {
    None
  }
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
      @moonui.Widget::label(b, shown_title)
      .foreground(
        match row_fg {
          Some(c) => c
          None => cm_ink()
        },
      )
      .font_size(10.0)
      .font_weight(if playing { Bold } else { Regular }),
    ).with_expand(true),
    cm_row_cell(
      b,
      Some(104.0),
      @moonui.Widget::label(b, shown_artist)
      .font_size(10.0)
      .foreground(
        match row_fg {
          Some(c) => c
          None => cm_muted()
        },
      ),
    ),
    // 专辑列（`T178`）：不走 `T193` 的显示口径投影——专辑没有文件名兜底那支，
    // 直接摆库里的值；探针没探到的空串显示「未知」，与歌手缺字段同款哨兵。
    cm_row_cell(
      b,
      Some(90.0),
      @moonui.Widget::label(
        b,
        if t.album == "" {
          cm_unknown_field()
        } else {
          t.album
        },
      )
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
    // 行右缘：队列页签（且没在搜索——搜索态的视图下标与队列对不上，拖了
    // 会错位）给拖动句柄「≡」，按下即开拖放会话，移动/抬起由 Core 接管改发
    // DragOver/DragDrop（`T102` 第二十四刀）。曲库顺序 = 扫描顺序，别的页签
    // 只给等宽的空格（与表头尾格同宽，列缝对得齐）。
    cm_row_cell(
      b,
      Some(18.0),
      if self.tab == 2 && self.query == "" {
        let grip = @moonui.Widget::label(b, "≡")
          .font_size(10.0)
          .foreground(cm_muted())
        let _ = grip.with_on_any(fn(ev) {
          match ev {
            @moonui.MouseDown(_, @moonui.Left, _, _) => {
              // 源行记在 app 账上（DragDrop 派给落点行，闭包里的 i 是按下
              // 这行的——正是源行，但落点行的闭包 i 是另一行，别混）
              self.drag_src = Some(i)
              let _ = self.app.begin_drag("q:\{i}:\{t.path}")
            }
            _ => ()
          }
        })
        grip
      } else {
        @moonui.Widget::spacer(b)
      },
    ),
  ])
  // 右键菜单：播放 / 下一首播放 / 收藏 / 从列表移除 / 属性（T86① 的控件级上下文菜单）
  let play_item = @moonui.MenuItem::new("播放")
  let _ = play_item.on(fn(_) { self.play_view_index(i) })
  // 「下一首播放」（`T176`）：播放中插到当前曲之后，未播等价追加。
  let next_item = @moonui.MenuItem::new("下一首播放")
  let _ = next_item.on(fn(_) { self.play_next_soon([t.path]) })
  let fav_item = @moonui.MenuItem::new(
    if self.lib.is_favorite(t.path) {
      "取消收藏"
    } else {
      "加入收藏"
    },
  )
  let _ = fav_item.on(fn(_) { self.toggle_favorite(t.path) catch { _ => () } })
  // 「从列表移除」：歌单页签移的是**歌单里的这一条**（路径清单），曲库不动；
  // 其它页签才是从曲库/收藏/队列移（`T175`）。
  let remove_item = @moonui.MenuItem::new("从列表移除")
  let _ = remove_item.on(fn(_) {
    if self.tab >= 3 {
      self.remove_from_current_playlist(t.path) catch {
        _ => ()
      }
    } else {
      self.remove_track(t.path) catch {
        _ => ()
      }
    }
  })
  let prop_item = @moonui.MenuItem::new("属性")
  let _ = prop_item.on(fn(_) {
    self.prop_path = Some(t.path)
    self.rebuild_ui() catch {
      _ => ()
    }
  })
  // 「编辑信息…」（`C-16`）：改标题/歌手/专辑并写回音频文件本身。
  let edit_item = @moonui.MenuItem::new("编辑信息…")
  let _ = edit_item.on(fn(_) { self.open_edit(t) catch { _ => () } })
  // 行的像素面：Panel（真后端上唯一吃 background 的容器，斑马画在这层）。
  // 偶数行不设底，透出页面色；斑马色给奇数行。
  let panel = @moonui.Widget::panel(b, row)
  // 双击播放 + 右键菜单都挂在**这一层**而不是 `row`（`T141`）：Row 是纯布局
  // 节点、原生层没有可命中的对象，命中反查报的不是标题 Label（点在字上）就
  // 是这块 Panel（点在行带的空白上）。挂在 Panel 上两种都覆盖——Label 的事件
  // 沿冒泡走到它，空白直接就是它；挂 Row 只能接住前者。
  let _ = panel.with_on_double_click(fn() { self.play_view_index(i) })
  // 单击 = 勾选/取消（`T177`）。挂 Panel 与双击同一条理由（`T141`）：Row 是纯
  // 布局节点、原生层没有可命中的对象，点在字上或行带空白上都要能接住。
  let _ = panel.with_on_click(fn() {
    let _ = self.toggle_select(t.path)
    self.rebuild_ui() catch {
      _ => ()
    }
  })
  // 多选时的批量项（`T177`）：只在"点的是选中行、且选中不止一首"时出现，
  // 免得在一首没选的行上摆一条"移除选中的 N 首"。
  let menu_nodes : Array[@moonui.MenuNode] = [
    Item(play_item),
    Item(next_item),
    Item(fav_item),
    Item(remove_item),
    Item(prop_item),
    Item(edit_item),
  ]
  // 「加入歌单」（`T175`）：常驻子菜单列出各歌单；一张都没有时给灰项提示。
  // 多选批量（`T177`）：选中不止一首时整批按**选中顺序**加入。
  let pl_nodes : Array[@moonui.MenuNode] = []
  if self.playlists.length() == 0 {
    let empty = @moonui.MenuItem::new("（还没有歌单）")
    let _ = empty.set_enabled(false)
    pl_nodes.push(Item(empty))
  } else {
    let paths = if self.is_selected(t.path) && self.selected.length() > 1 {
      self.selected
    } else {
      [t.path]
    }
    for pi, pl in self.playlists {
      let pl = pl
      let it = @moonui.MenuItem::new(pl.name)
      let _ = it.on(fn(_) { self.add_to_playlist(pi, paths) catch { _ => () } })
      pl_nodes.push(Item(it))
    }
  }
  menu_nodes.push(Submenu("加入歌单", pl_nodes))
  if self.is_selected(t.path) && self.selected.length() > 1 {
    // 批量插队（`T176`）：整段按**选中顺序**插到当前曲之后
    let batch_next = @moonui.MenuItem::new(
      "下一首播放选中的 \{self.selected.length()} 首",
    )
    let _ = batch_next.on(fn(_) { self.play_next_soon(self.selected) })
    menu_nodes.push(Item(batch_next))
    let batch = @moonui.MenuItem::new(
      "从列表移除选中的 \{self.selected.length()} 首",
    )
    let _ = batch.on(fn(_) { self.remove_selected() catch { _ => () } })
    menu_nodes.push(Item(batch))
    // 批量收藏 / 批量导出（`T177` 接账，`T175` 本批接上）
    let batch_fav = @moonui.MenuItem::new(
      "收藏选中的 \{self.selected.length()} 首",
    )
    let _ = batch_fav.on(fn(_) {
      self.batch_favorite_selected() catch {
        _ => ()
      }
    })
    menu_nodes.push(Item(batch_fav))
    let batch_exp = @moonui.MenuItem::new(
      "导出选中的 \{self.selected.length()} 首…",
    )
    let _ = batch_exp.on(fn(_) {
      self.batch_export_selected() catch {
        _ => ()
      }
    })
    menu_nodes.push(Item(batch_exp))
  }
  let _ = panel.set_context_menu(@moonui.Menu::new("行", menu_nodes))
  // 队列页签的拖放落点（`T176`）：DragOver/DragDrop 由会话派给光标下的控件
  // （行内任何叶子都行——挂冒泡口，`T141` 同一条理由），落点判定用行框。
  let _ = panel.on_bubble(
    fn(ev) {
      ev is @moonui.DragOver(_, _, _) || ev is @moonui.DragDrop(_, _, _)
    },
    fn(ev) {
      match ev {
        @moonui.DragOver(_, p, _) => self.queue_drag_over(i, panel.frame(), p)
        @moonui.DragDrop(_, _, _) => self.queue_drop()
        _ => ()
      }
    },
  )
  // 落点指示（`T176`）：插入位指着这行的上缘（或队列末）时整行亮 accent——
  // VirtualList 的行是定尺锁高的（ui_table 的 CM_ROW_HEIGHT），行间没有可画的
  // 缝隙，悬浮插入线做不实；v1 用"落点行高亮"，真线要框架 overlay 的账。
  // 底色判定收在 row_bg_decision 一处（T207 单一写入口）：拖拽中改指示只
  // 就地对新旧落点行 set_style（queue_drag_over），不重建行——重建会把按下
  // 中的句柄整棵 close_tree，真窗上原生对象在拖拽循环里被销毁。
  let row_bg = self.row_bg_decision(i, t, playing)
  let _ = panel.set_style(Some(@moonui.style(background=row_bg)))
  let _ = panel.set_hover_style(
    Some(@moonui.style(background=Some(cm_hover()))),
  )
  panel
}

///|
/// 打开「编辑信息」小窗（`C-16`）。窗懒建一次，之后复用——见 `edit` 字段的注释。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::open_edit(
  self : LunaMusicApp[B, A],
  t : Track,
) -> Unit raise @moonui.UiError {
  let anchor = match self.ui {
    Some(u) => u.window
    None => return
  }
  // 同 `open_search_lyrics`：红绿灯关掉的是**销毁**（`Close` → `release`），
  // 不是藏起来（`T164`②）。留着已销毁的那只，之后每次打开都是静默失败。
  match self.edit {
    Some(d) => if d.window.is_closed() { self.edit = None }
    None => ()
  }
  let d = match self.edit {
    Some(d) => d
    None => {
      let b = self.app.backend()
      let d = EditDialog::new(
        b,
        self.app,
        fn(path, title, artist, album) {
          self.save_track_info(path, title, artist, album) catch {
            _ => ()
          }
        },
        fn() { self.close_edit() },
      )
      self.edit = Some(d)
      d
    }
  }
  d.open(t, anchor)
}

///|
/// 关掉编辑窗。
pub fn[B : @platform-services.PlatformServices, A] LunaMusicApp::close_edit(
  self : LunaMusicApp[B, A],
) -> Unit {
  match self.edit {
    Some(d) => d.close()
    None => ()
  }
}

///|
/// 保存三个字段（`C-16`）：写文件 → 重探 → 改库 + 改队列 → 刷界面 → 落档。
///
/// 顺序不能换：
/// 1. 先写文件，写不进去就**什么都不改**（库、界面、窗口全保持原样，弹一句原因）；
/// 2. 写成功后用 `probe_many` 拿回**真探针结果**，而不是自己按输入拼一个 Track
///    ——"清空字段 → 回退文件名"这条规则只长在探针那条路上，自己拼就会造出
///    界面显示空标题、扫描却显示文件名的两套行为；
/// 3. 库与队列各改一处（队列走 `update_track_meta`，不清历史/牌堆）；
/// 4. 最后才 `on_library_changed` 落档。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::save_track_info(
  self : LunaMusicApp[B, A],
  path : String,
  title : String,
  artist : String,
  album : String,
) -> Unit raise @moonui.UiError {
  if path == "" {
    return
  }
  match (self.write_tags)(path, title, artist, album) {
    Failed(msg) => {
      let _ = @moonui.Backend::show_message(
        self.app.backend(),
        "编辑信息",
        msg,
      )
      // 窗口不关：用户能改个值再试一次。
      return
    }
    UnsupportedFormat => {
      let _ = @moonui.Backend::show_message(
        self.app.backend(),
        "编辑信息",
        "这种格式不支持写入标签",
      )
      return
    }
    Written => ()
  }
  let probed = (self.probe_many)([path])
  let t = match probed {
    [one, ..] => one
    [] => Track::from_path(path)
  }
  let _ = self.lib.set_meta(path, t.title, t.artist, t.album)
  self.player.update_track_meta(t)
  self.view = self.compute_view()
  self.refresh_table()
  // 属性栏若正钉着这首，文案也要跟着变（它读 lib，不读队列）。
  match self.ui {
    Some(u) => {
      let _ = u.table.prop.set_text(self.prop_text())
    }
    None => ()
  }
  self.refresh_bar()
  (self.on_library_changed)()
  self.close_edit()
}

///|
/// 从列表移除一首（右键菜单）：当前曲被移掉时停播，其余情况播放不受扰。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::remove_track(
  self : LunaMusicApp[B, A],
  path : String,
) -> Unit raise @moonui.UiError {
  self.lib.remove_track(path)
  self.player.replace_queue(self.lib.tracks)
  self.rebuild_ui()
}

///|
/// 该曲是否在多选集合里（`T177`）。
pub fn[B, A] LunaMusicApp::is_selected(
  self : LunaMusicApp[B, A],
  path : String,
) -> Bool {
  self.selected.contains(path)
}

///|
/// 切换某首的选中态（`T177`）：没有就加、有就删，返回切换后的状态。
///
/// 单击行就是这条——**不用修饰键**：无头测试拿不到 ⌘/Ctrl，而"点了勾上、
/// 再点取消"的复选框语义在音乐列表里本来也更好按（不用先按住再点）。
/// 双击仍是播放：双击会先 toggle 一下，播的还是同一首，不冲突。
pub fn[B, A] LunaMusicApp::toggle_select(
  self : LunaMusicApp[B, A],
  path : String,
) -> Bool {
  if self.is_selected(path) {
    // 原地删（`selected` 与 `favorites` 同一条：数组字段本身不是 mut，
    // 增删都走数组自己的方法）
    for i = 0; i < self.selected.length(); i = i + 1 {
      if self.selected[i] == path {
        let _ = self.selected.remove(i)
        break
      }
    }
    false
  } else {
    self.selected.push(path)
    true
  }
}

///|
/// 选中的首数（`T177`）。
pub fn[B, A] LunaMusicApp::selected_count(self : LunaMusicApp[B, A]) -> Int32 {
  self.selected.length()
}

///|
/// 把选中的几首一起从曲库移除（`T177`）。**一次 rebuild**：`remove_track` 是
/// 每首一遍换树，批量删十首就是十次整树重挂，界面上会连闪。
/// 歌单页签（`T175`）移的是歌单里的那几条，曲库不动。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::remove_selected(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  if self.selected.length() == 0 {
    return
  }
  if self.tab >= 3 {
    let pi = self.tab - 3
    if pi < self.playlists.length() {
      for p in self.selected {
        let _ = playlist_remove_path(self.playlists, self.playlists[pi].name, p)
      }
    }
    self.selected.clear()
    self.view = self.compute_view()
    self.rebuild_ui()
    return
  }
  for p in self.selected {
    self.lib.remove_track(p)
  }
  self.selected.clear()
  self.player.replace_queue(self.lib.tracks)
  self.rebuild_ui()
}

///|
/// 四组菜单的**唯一**构建处（播放 / 控制 / 窗口 / 皮肤）。
///
/// 两个消费者：mac 那条走 `install_menubar` 装成系统菜单栏；Windows 那条不装
/// 菜单栏（沉浸式窗没有系统菜单条可摆），改成自绘顶条里的四颗文字钮，点了在
/// 光标处弹同一棵菜单（`T116`）。两条都从这里取树，条目、回调、勾选态就只有
/// 一份定义——照两份写，早晚一边加了项另一边没加。
///
/// 每次调用都现建一棵新的 `MenuItem` 集合：菜单项的回调闭包捕获 `self`，值是
/// 不可变的；重建的代价只是几个闭包，换来的好处是「换肤后重挂」不需要去改已
/// 装好的树（`MenuBar` 本身就是不可变结构）。
fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::cm_build_menus(
  self : LunaMusicApp[B, A],
) -> Array[@moonui.Menu] {
  // 播放菜单：播放/暂停（空格）、上一首（⌘←）、下一首（⌘→）、模式切换
  // 三条播放控制走 `media_action`（`T181`）：与媒体键/全局热键/托盘共用入口。
  let toggle = @moonui.MenuItem::new("播放/暂停")
  let _ = toggle.set_shortcut(@moonui.Shortcut::new("Space"))
  let _ = toggle.on(fn(_) { self.media_action(0) })
  let prev = @moonui.MenuItem::new("上一首")
  let _ = prev.set_shortcut(@moonui.Shortcut::meta("Left"))
  let _ = prev.on(fn(_) { self.media_action(2) })
  let next = @moonui.MenuItem::new("下一首")
  let _ = next.set_shortcut(@moonui.Shortcut::meta("Right"))
  let _ = next.on(fn(_) { self.media_action(1) })
  let mode = @moonui.MenuItem::new("切换播放模式")
  let _ = mode.on(fn(_) {
    self.player.cycle_mode()
    self.refresh_bar() catch {
      _ => ()
    }
  })
  // 音量归一化开关（`T170`）：勾选态读 `normalize`，点了翻转并对播着的曲
  // 当场生效（`set_normalize` 现挂/撤增益），偏好随壳的 prefs_out 落盘。
  let norm = @moonui.MenuItem::new("音量归一化")
  norm.checked = self.normalize
  let _ = norm.on(fn(_) {
    self.normalize = !self.normalize
    self.player.set_normalize(self.normalize)
    self.refresh_bar() catch {
      _ => ()
    }
  })
  let play_nodes : Array[@moonui.MenuNode] = [
    Item(toggle),
    Item(prev),
    Item(next),
    Item(mode),
    Separator,
    // 播放速度（`T171`）：走菜单而不是走带多一颗钮——走带那排已经 348/380，
    // 加一颗 24 的会把两个 spacer 挤到 2.5（`T120` 量过同一片地方）。
    Submenu("播放速度", self.cm_build_rate_menu_nodes()),
    Item(norm),
    // 睡眠定时（`T185`）：同样进子菜单，到点暂停播放（不是退出应用）。
    Submenu("睡眠定时", self.cm_build_sleep_menu_nodes()),
  ]
  // 输出设备（`T169`）：枚举得出设备才挂——空表（Windows 空桩，设备数 0）
  // 整个子菜单不出现，而不是挂一颗点不动的壳。与 eq_band_count=0 不画假滑块
  // 同一条降级形状。
  if self.player.engine.output_devices().length() > 0 {
    play_nodes.push(Submenu("输出设备", self.cm_build_output_menu_nodes()))
  }
  let play_menu = @moonui.Menu::new("播放", play_nodes)
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
  // 播放详情伴窗（`T180`）：与桌面歌词同一条开关形状，默认收起。
  let detail_item = @moonui.MenuItem::new("播放详情")
  let _ = detail_item.on(fn(_) { self.toggle_detail() })
  // 「复位窗口」在 Windows 上进菜单、不上顶条（`T116`）：顶条只有 380 宽，
  // 实测 logo + 四组菜单钮 + 复位 + 三颗窗口钮要 419——复位那 66 一加，
  // 「✕」整颗掉到窗外。顶条上真正不可省的只有窗口钮，其余能进菜单的都进菜单。
  // 菜单里本来就有「窗口」一组，归位是窗口的事，放这里比放「控制」顺。
  let window_nodes : Array[@moonui.MenuNode] = [
    Item(mini_item),
    Item(roll_item),
    Item(desk_item),
    Item(detail_item),
  ]
  if @moonui.Backend::host_platform(self.app.backend()) != Macos {
    let reset_item = @moonui.MenuItem::new("复位窗口")
    let _ = reset_item.on(fn(_) { self.reset_layout() })
    window_nodes.push(Separator)
    window_nodes.push(Item(reset_item))
  }
  let window_menu = @moonui.Menu::new("窗口", window_nodes)
  // 控制菜单：播放全部 / 添加目录 / 歌曲信息显示（子菜单，`T193`）
  //
  // 显示口径不做**第五组顶层菜单**：Windows 顶条只有 380 宽，`T120` 实测四组
  // 菜单钮 + 复位 + 三颗窗口钮已经贴到 356/372，第五颗必掉出窗外。挂成`控制`
  // 里的子菜单，两个平台都能进，顶条一颗都没多。
  let control_menu = @moonui.Menu::new("控制", [
    Item(play_all),
    Item(add_dir),
    Separator,
    Submenu("歌曲信息显示", self.cm_build_display_menu_nodes()),
  ])
  // 皮肤菜单：内置四套（radio 打勾当前）+ 导入/导出/恢复默认。
  // 换肤会整树重建并**重挂**本菜单，所以打勾每次都是照当时的皮肤算的。
  let skin_nodes : Array[@moonui.MenuNode] = []
  for s in cm_skin_builtins() {
    let name = s.name
    let item = @moonui.MenuItem::radio(name)
    item.checked = self.skin_is(name)
    let _ = item.on(fn(_) { let _ = self.set_skin_by_name(name) })
    skin_nodes.push(Item(item))
  }
  // 目录里加载进来的皮肤：按名字显示，打勾按路径比（名字可能重）
  for e in self.extra_skins {
    let path = e.0
    let sk = e.1
    let extra = @moonui.MenuItem::radio(sk.name)
    extra.checked = self.skin_is(path)
    let _ = extra.on(fn(_) { self.set_skin(sk, path) })
    skin_nodes.push(Item(extra))
  }
  skin_nodes.push(Separator)
  let import_item = @moonui.MenuItem::new("加载皮肤目录…")
  let _ = import_item.on(fn(_) { (self.on_load_skin_dir)() })
  skin_nodes.push(Item(import_item))
  let export_item = @moonui.MenuItem::new("导出当前皮肤…")
  let _ = export_item.on(fn(_) { (self.on_save_skin)(cm_skin_current().text()) })
  skin_nodes.push(Item(export_item))
  let reset_item = @moonui.MenuItem::new("恢复默认皮肤")
  let _ = reset_item.on(fn(_) { self.reset_skin() })
  skin_nodes.push(Item(reset_item))
  let skin_menu = @moonui.Menu::new("皮肤", skin_nodes)
  // 「应用」菜单（退出 ⌘Q）与「编辑」菜单（⌘Z/X/C/V/A）不在这里造：
  // mac 后端 init 时预装默认的两顶（`T129`），自定义菜单栏装上后它们挪到
  // 树末尾兜底——自己再造一份会同组合两份项，先命中先赢，容易看着都像坏的。
  [play_menu, control_menu, window_menu, skin_menu]
}

///|
/// 「播放速度」五档（`T171`）。千分位，与音量同一个单位口径。
///
/// 档位是**产品判断**不是技术上限——`AVAudioUnitTimePitch` 能到 1/32..32，
/// 但慢过 0.5x 只剩拖长的噪声、快过 2x 听不清词。这五档覆盖"听播客 / 听有声
/// 书 / 快速过一遍"的真实用法，多给几档只会让人挑花眼。
fn cm_rate_choices() -> Array[Int32] {
  [750, 1000, 1250, 1500, 2000]
}

///|
/// 档位 → 菜单文案。手写而不是格式化浮点：`0.75` 这种要靠 `%g` 之类的东西，
/// 而五档是固定表，写死最不容易在两个平台上印出 `1.0000000001x`。
fn cm_rate_label(permille : Int32) -> String {
  match permille {
    750 => "0.75x"
    1250 => "1.25x"
    1500 => "1.5x"
    2000 => "2.0x"
    _ => "1.0x"
  }
}

///|
/// 「播放速度」那几格单选的节点表（`T171`）。形状照 `cm_build_display_menu_nodes`：
/// radio、打勾的永远是当下生效那一档、点一下改账 + 重挂菜单栏。
fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::cm_build_rate_menu_nodes(
  self : LunaMusicApp[B, A],
) -> Array[@moonui.MenuNode] {
  let nodes : Array[@moonui.MenuNode] = []
  let cur = self.player.rate()
  for pm in cm_rate_choices() {
    let item = @moonui.MenuItem::radio(cm_rate_label(pm))
    item.checked = cur == pm
    let _ = item.on(fn(_) { self.set_rate(pm) })
    nodes.push(Item(item))
  }
  nodes
}

///|
/// 切播放速度（`T171`）：改引擎 → 重挂菜单栏（打勾）。
///
/// **不刷 `refresh_bar`**：状态行不显示倍速，也没有别的控件跟着它变。真要
/// 让某处显示，那是下一个消费者的账。
///
/// 同档位直接返回：`install_menubar` 会重建整份菜单树，点同一格不该付这笔账。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::set_rate(
  self : LunaMusicApp[B, A],
  permille : Int32,
) -> Unit {
  if self.player.rate() == permille {
    return
  }
  self.player.set_rate(permille)
  // 打勾不跟树走（同换肤 / 换显示口径那两处）：重挂一次菜单栏
  self.install_menubar() catch {
    _ => ()
  }
}

///|
/// 「输出设备」那几格单选的节点表（`T169`）。形状照 `cm_build_rate_menu_nodes`：
/// radio、打勾的永远是当下生效那一台（`output_current` 读回，-1 = 没有当前，
/// 一格都不亮）、点一下切换 + 重挂菜单栏。
fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::cm_build_output_menu_nodes(
  self : LunaMusicApp[B, A],
) -> Array[@moonui.MenuNode] {
  let nodes : Array[@moonui.MenuNode] = []
  let cur = self.player.engine.output_current()
  for i, name in self.player.engine.output_devices() {
    let item = @moonui.MenuItem::radio(name)
    item.checked = cur == i
    let _ = item.on(fn(_) { let _ = self.set_output_device(i) })
    nodes.push(Item(item))
  }
  nodes
}

///|
/// 切输出设备（`T169`）：改引擎 → 重挂菜单栏（打勾）。
///
/// **失败静默**（与 `set_rate` 同一条分量判断）：越界/底层拒绝时勾留在原处，
/// 下一次构建照 `output_current` 读回即真。切成功后引擎内部自己收位置续接
/// （adapter.h 输出设备段），播放不打断。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::set_output_device(
  self : LunaMusicApp[B, A],
  index : Int32,
) -> Bool {
  let ok = self.player.engine.set_output_device(index)
  self.install_menubar() catch {
    _ => ()
  }
  ok
}

///|
/// 「睡眠定时」那几格单选的节点表（`T185`）：关闭 / 1 / 15 / 30 / 45 / 60 / 90
/// 分钟（1 分钟档是 `T223` 加的）。形状照 `cm_build_rate_menu_nodes`：radio、
/// 打勾的永远是当下那一档、点一下改账 + 重挂菜单栏。
fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::cm_build_sleep_menu_nodes(
  self : LunaMusicApp[B, A],
) -> Array[@moonui.MenuNode] {
  let nodes : Array[@moonui.MenuNode] = []
  for mins in cm_sleep_choices() {
    let item = @moonui.MenuItem::radio(cm_sleep_label(mins))
    item.checked = self.sleep_mins == mins
    let _ = item.on(fn(_) { self.set_sleep_timer(mins) })
    nodes.push(Item(item))
  }
  nodes
}

///|
/// 档位表（0 = 关闭）。
///
/// `T223`：加 `1` 分钟档——真机验收"到点暂停"要等 15 分钟起，验一次干等一刻钟；
/// 1 分钟档就是给这条链路一个能坐下来看的窗。
fn cm_sleep_choices() -> Array[Int32] {
  [0, 1, 15, 30, 45, 60, 90]
}

///|
fn cm_sleep_label(mins : Int32) -> String {
  match mins {
    0 => "关闭"
    m => "\{m} 分钟"
  }
}

///|
/// 设睡眠定时（`T185`）：`mins = 0` 关闭（清账）。到点时刻 = 当下钟 + 分钟数，
/// **重设永远盖掉旧账**——连点同一格也是重开一段，与 `set_rate` 的"同档早退"
/// 不是一条账：那边的档位没有"还剩多久"的概念，这里有。
///
/// `T221`：这里存的**形状不动**（`Int64` 绝对时刻，`sleep_due_ms` 的类型也不动，
/// 现成判据 `assert_eq(cm.sleep_due_ms, Some(900_000L))` 钉的就是它）——跨回绕的
/// 账全在判账那一头，见 `sleep_check`。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::set_sleep_timer(
  self : LunaMusicApp[B, A],
  mins : Int32,
) -> Unit {
  self.sleep_mins = mins
  self.sleep_due_ms = match mins {
    0 => None
    m => Some((self.sleep_clock)() + m.to_int64() * 60_000L)
  }
  // 打勾不跟树走（同换肤那处）：重挂一次菜单栏
  self.install_menubar() catch {
    _ => ()
  }
}

///|
/// 睡眠定时到点判账（`T185`）：挂在 `refresh_bar` 头上，心跳每拍都到。到点：
/// 清账 + **播放中才暂停**（没在播只清账，别把 Idle 拽成 Paused）。已知取舍
/// （v1）：暂停之后心跳链断了（beat_tick 认 `is_playing`），残留的定时没人
/// 判——下一次任何 refresh_bar（用户动了界面）才把账清掉，行为上无感。
///
/// `T221`：到期判定**必须降到 32 位取模**，不能用 64 位差值，也不能用绝对比较。
/// `sleep_clock` 在真壳里就是 `native_time_ms().to_int64()`（那只 int64 开机毫秒
/// 截成 Int32 的钟，开机满 `2^31` 毫秒 ≈24.85 天后读数本身是负数），而 `due` 是
/// `set_sleep_timer` 当场存的**没绕过的** Int64 和：`clock() + 分钟数`——比如
/// `2147483000L + 900000L = 2148383000L`，比 Int32 上界还大，是回绕之后那一头的
/// 时刻。于是跨圈之后 `now`（负）减 `due`（正）得到 `-4294967000L` 这种**巨大**
/// 的数，符号说"还早着呢"，而真实只差 296 毫秒——64 位差值在这一格判不出到期，
/// 最长 24.8 天不睡。按 32 位取模（`.to_int()` 拿低 32 位的有符号残差）正好把
/// 那 2^32 的整圈减掉：`-4294967000L → 296 ≥ 0` = 到期。窗口同 `T221` 全局口径：
/// `|真实差| < 2^31` 毫秒，睡眠档位最长 90 分钟，远在窗口内。
fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::sleep_check(
  self : LunaMusicApp[B, A],
) -> Unit {
  match self.sleep_due_ms {
    Some(due) =>
      if ((self.sleep_clock)() - due).to_int() >= 0 {
        self.sleep_due_ms = None
        self.sleep_mins = 0
        self.player.pause()
        self.install_menubar() catch {
          _ => ()
        }
      }
    None => ()
  }
}

///|
/// 「歌曲信息显示」那两格单选的节点表（`T193`）：歌名/歌手按文件名还是按标签。
///
/// 单选（radio）而不是复选：两种口径互斥，打勾的永远是当下生效的那一格。
/// 换完要**重挂菜单栏**（打勾不跟树走，同换肤那条），再把几处显示刷一遍——
/// 列表行是建行那一刻烤进去的，得让 `VirtualList` 重建窗内那几行。
///
/// **不写 `Prefs`**：应用本体不碰文件系统（`on_library_changed` 那套注入纪律），
/// 偏好档由壳在退出时按 `self.display` 落盘。
fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::cm_build_display_menu_nodes(
  self : LunaMusicApp[B, A],
) -> Array[@moonui.MenuNode] {
  let nodes : Array[@moonui.MenuNode] = []
  for src in [FileName, Tags] {
    let item = @moonui.MenuItem::radio(src.label())
    item.checked = self.display == src
    let _ = item.on(fn(_) { self.set_display(src) })
    nodes.push(Item(item))
  }
  nodes
}

///|
/// 切显示口径（`T193`）：改账 → 重挂菜单栏（打勾）→ 三处显示就地刷。
///
/// 「就地刷」而不是 `rebuild_ui`：整树重建要 ~700ms 且会销毁原生控件（输入框
/// 里的字、光标全丢），换一个显示口径不值得。播放条与歌词窗本来每拍都从
/// player 拉状态，刷一次就对了；列表行是烤死的，得显式让 `VirtualList` 重建
/// 窗内那几行（`refresh_current` 同一条路）。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::set_display(
  self : LunaMusicApp[B, A],
  src : DisplaySource,
) -> Unit {
  if self.display == src {
    return
  }
  self.display = src
  self.refresh_bar() catch {
    _ => ()
  }
  self.refresh_lyrics() catch {
    _ => ()
  }
  match self.ui {
    Some(u) => u.table.refresh_current() catch { _ => () }
    None => ()
  }
  // 属性栏**不跟**这个口径走：那里是"这首歌的文件里写着什么"的查看口，
  // 显示口径只管列表/播放条/歌词窗这几处"看歌"的地方。
  // 菜单栏不跟树走，打勾要重挂才挪得动
  self.install_menubar() catch {
    _ => ()
  }
}

///|
/// 菜单栏（C-03 映射表：MenuBar + MenuSelect）。装一次（app 级，不跟树走）。
///
/// Windows 那支**不装**系统菜单栏：沉浸式窗的客户区铺满整窗，`SetMenu` 会从
/// 顶上硬切一行出去，等于把自绘顶条顶掉。四组菜单改由顶条里的四颗文字钮弹
/// （见 `rebuild_ui` 里那圈建菜单钮的循环与这里开头那条短路）。
/// 快捷键因此也不再由 `set_menubar` 自动登记——那条路是跟着菜单栏走的——改由
/// `cm_install_strip_shortcuts` 用 Core 的 `register_shortcut` 单独登记。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::install_menubar(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  if @moonui.Backend::host_platform(self.app.backend()) == Windows {
    // Windows：菜单栏不进原生层。这里**什么都不装**——树在 `rebuild_ui` 里
    // 交给自绘顶条的按钮，快捷键由下面那条单独登记。
    self.cm_install_strip_shortcuts()
    return
  }
  self.app.set_menubar(@moonui.MenuBar::new(self.cm_build_menus()))
}

///|
/// 自绘顶条版本的快捷键登记（`T116`，只给 Windows 那支用）。
///
/// `set_menubar` 会自动把带 shortcut 的菜单项登记成加速键（§25/§26），Windows
/// 不装菜单栏就收不到这份待遇。这里照同一份组合用 `register_shortcut` 单独登
/// 记——**只登一次**（`strip_shortcuts` 是那道闸）：`install_menubar` 在换肤时
/// 会被重调一次，重复登记会让一次按键响应两遍（`examples/lunamusic-shell/
/// shell.mbt` 那条注释记的就是这个坑）。
///
/// 组合与菜单项上写的那三条一一对应；菜单项的 `shortcut` 字段在 Windows 上不
/// 再有人去读，所以两边要一起改（这是这份实现唯一的重复之处，写在这里提醒）。
fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::cm_install_strip_shortcuts(
  self : LunaMusicApp[B, A],
) -> Unit {
  if self.strip_shortcuts {
    return
  }
  self.strip_shortcuts = true
  let play = self.player
  let _ = self.app.register_shortcut(@moonui.Shortcut::new("Space"), fn(_) {
    play.toggle()
    self.refresh_bar() catch {
      _ => ()
    }
  })
  let _ = self.app.register_shortcut(@moonui.Shortcut::meta("Left"), fn(_) {
    play.prev()
  })
  let _ = self.app.register_shortcut(@moonui.Shortcut::meta("Right"), fn(_) {
    play.next()
  })
}

///|
/// path → 当前显示口径下的名字（`T186` 的错误文案要用这一份）。
///
/// 从**曲库**里查而不是从播放队列：队列可能已经被搜索/页签换过，而用户报的
/// 是"列表里那首点不动"，曲库那份才是一直在的。查不到（文件被删、曲库刚重扫）
/// 退回文件名——路径末段总还在，总比只给一句"无法播放"强。
fn[B, A] LunaMusicApp::display_name_of_path(
  self : LunaMusicApp[B, A],
  path : String,
) -> String {
  for t in self.lib.tracks {
    if t.path == path {
      return cm_display_fields(t, self.display).0
    }
  }
  cm_strip_extension(cm_file_name(path))
}

///|
/// 播放条刷新：从 player 拉最新状态写控件（notify 广播的落地端）。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::refresh_bar(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  // 睡眠定时（`T185`）在头上判账：这里是心跳每拍都进的口，到点不欠拍。
  self.sleep_check()
  // 无缝预排（`T224`）：只在快播完时才真的链，心跳每拍回来判一次"该不该链"
  // ——插队/换下一首只改意图，别在开播那一刻就把当前段顶掉。
  self.player.prime_refresh()
  // 拖拽会话的清尾（`T176`）：拖出去松在空白处不发 DragDrop，指示账会残留
  // ——心跳这一拍发现会话已经没了就清账重画。会话在跑时**不碰**：拖拽期间
  // 的显示归拖拽状态机所有（`T207` 单一写入口的教训），心跳不许顶掉它。
  if self.drag_ins is Some(_) && !self.app.drag_active() {
    self.drag_ins = None
    self.drag_src = None
    self.cm_rebuild_list_rows()
  }
  match self.ui {
    Some({ bar, mini, .. }) => {
      match self.player.track() {
        Some(t) => {
          let (shown_title, shown_artist) = cm_display_fields(t, self.display)
          let _ = bar.title.set_text(shown_title)
          let _ = bar.artist.set_text(
            cm_join_meta(shown_artist, cm_display_album(t, self.display)),
          )
          let _ = bar.fav.set_text(
            if self.lib.is_favorite(t.path) {
              "♥"
            } else {
              "♡"
            },
          )
          // 封面（`T174`）：换曲才灌一次。`player.track()` 里的 cover 是装引擎
          // 那一趟探出来的（`Player::start_at` 把它补进队列），所以重启后第一次
          // 播放也有——曲库档本身不落封面字节（体积）。
          //
          // 没有封面时灌一张皮肤同色调的占位图（唱盘图案）而不是"什么都不做"：
          // 不动的话播放条会留着上一首的封面，看起来像点错了歌；灌透明图是
          // `T174` 的老答案，但那格空着像脸面缺了一块（owner 2026-11-04 点的）。
          if self.cover_path != t.path {
            self.cover_path = t.path
            let bytes = match t.cover {
              Some(c) => c
              None => cm_placeholder_cover()
            }
            // 这格图最终摆的是什么（真封面解不出退占位图时也是占位图）
            let mut showing_placeholder = t.cover is None
            bar.cover.set_image_bytes(bytes) catch {
              // 封面字节解不出（损坏的内嵌图）也退占位图，别让这格空着——
              // 路径边沿到这里已经消费掉了，不兜底就永远空白
              _ => {
                showing_placeholder = true
                bar.cover.set_image_bytes(cm_placeholder_cover()) catch {
                  _ => ()
                }
              }
            }
            self.cover_placeholder = showing_placeholder
          }
        }
        None => {
          let _ = bar.title.set_text("未播放")
          let _ = bar.artist.set_text("")
          let _ = bar.fav.set_text("♡")
          // 没在播（含启动后还没点过歌）：封面位同样灌占位图，别空着
          // （owner 2026-11-04 点的）。占位图有自己的边沿账
          // （cover_placeholder）：refresh_bar 每 300ms 一拍，没有它就是
          // 每拍重生成重解码；回放时路径边照常接管。
          if !self.cover_placeholder {
            self.cover_placeholder = true
            self.cover_path = ""
            bar.cover.set_image_bytes(cm_placeholder_cover()) catch {
              _ => ()
            }
          }
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
      // 状态行（`T186`）：**有播放失败就压过正常状态**。三态文案是"系统现在
      // 在干什么"，失败文案是"你想干的事为什么没成"——后者更该被看见，而且
      // 失败之后状态本来就是 Idle，"状态: 就绪"会把"点了没反应"说成一切正常，
      // 正是这条缺口当初的样子。
      let _ = bar.state_text.set_text(
        match self.player.last_error() {
          Some(err) =>
            cm_player_error_text(err, fn(p) { self.display_name_of_path(p) })
          None =>
            if playing {
              "状态: 播放"
            } else if self.player.state is Paused {
              "状态: 暂停"
            } else {
              "状态: 就绪"
            }
        },
      )
      // 进度：千分位；时长未知（<0）钳到 0
      let dur = self.player.duration()
      let pos = self.player.position()
      let permille = if dur > 0 { (pos * 1000L / dur).to_int() } else { 0 }
      // 没有可定位的曲目时把滑块禁掉（`T138`）：`on_seek_slider` 那侧本来就
      // `dur > 0` 才 seek，所以点下去什么都不会发生，但系统轨道条会照常把它的
      // 位置挪到点击处、自绘的填充跟着挪——看起来"能拖"，实际是假动作。禁掉
      // 之后点击/拖动连消息都不进控件。时长已知的暂停曲目仍可拖（合法定位）。
      let _ = bar.progress.set_enabled(dur > 0)
      // 进度条正在被拖（`T149`）：这一圈**不回写**。滑块 `Change` 改成实时
      // 直达之后，这句 `set_value` 跑在用户手指底下那圈跟踪循环里，而这里的
      // 千分位是从引擎当前位置算的——真引擎刚 `seek` 完回报的还是旧位置，
      // 一句回写就把拇指拽回去，下一颗 `mouseDragged` 又从新位置重新算，拖着
      // 走不直。拖到哪儿由 `on_seek_slider` 自己画（它同时推自绘那一层）。
      if !self.seeking {
        let _ = bar.progress.set_value(permille)
        // 自绘层跟着走（原生滑块被蒙住，只负责拖动）
        bar.prog_bar.set_permille(permille)
      }
      // 没曲目时原版显示 00:00 与 00:00，不显示 --:--（那是"不知道"的占位，
      // 摆在大字号上会变成两排破折号，看着像控件坏了）
      let pos_show = if pos < 0 { 0L } else { pos }
      let dur_show = if dur < 0 { 0L } else { dur }
      let _ = bar.time_big.set_text(format_duration(pos_show))
      let _ = bar.time_total.set_text("/ " + format_duration(dur_show))
      let _ = bar.volume.set_value(self.player.volume)
      bar.vol_bar.set_permille(self.player.volume)
      // 音量百分比（`T146`）：收起时也照写。`set_text` 不判同值，但这一轮
      // refresh_bar 本来就在改标题/时长/状态那几只标签，重排账一斤没多；
      // 这样弹出时读数一定是对的，不用另记一份"上一次显示的是多少"。
      let _ = bar.vol_pct.set_text(
        ((self.player.volume * 100 + 500) / 1000).to_string() + "%",
      )
      // 迷你条同步（同一套状态，两处显示）。迷你条整句是「歌手 - 歌名」
      // （owner 2026-11-05：只给歌名不知道是谁唱的）；缺谁就只留另一个。
      // 歌名的文字账全权交给跑马灯 sync：溢出时它按格宽切片逐拍推进，
      // 这里每 500ms 一拍不能把整句灌回去——那会让滚动每半秒被顶掉一帧。
      self.mini_marquee_sync(
        match self.player.track() {
          Some(t) => {
            let (title, artist) = cm_display_fields(t, self.display)
            match (artist, title) {
              ("", "") => ""
              ("", _) => title
              (_, "") => artist
              (a, b) => a + " - " + b
            }
          }
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
  // 边沿：当前曲换了 → 播放列表窗里被烤进去的那份高亮作废，原地重建窗内那
  // 十来行（`T153`）。播放条与歌词窗每拍都从 player 拉最新状态，所以切歌当场
  // 就变了；列表行是 `build_row` 建行那一刻按 `player.current` 烤死的，不重建
  // 就永远停在旧行——owner 报的"其它两个窗口都变过来了，播放列表还是前一首"
  // 就是这个不对称。按路径认边沿：同一首反复调会白重建（幂等但不免费）。
  let lit = self.player.now_path()
  if lit != self.lit_path {
    self.lit_path = lit
    match self.ui {
      Some(u) => u.table.refresh_current() catch { _ => () }
      None => ()
    }
  }
  // 托盘菜单跟着曲/模式/音量走（`T183`）：签名没变就一个字不动，变了整菜单
  // 重设。挂在 refresh_bar 尾上，播放条每拍刷新的那条路托盘也每拍对一次账。
  self.refresh_tray()
  // 「正在播放」推送（`T181`）：签名边沿——曲路径/显示口径/位置秒/播放态
  // 哪样变了才推。播放中位置每拍在动（控制中心的进度要它）；暂停时位置冻结，
  // 签名不再变，一次都不推。没歌时清一次（`np_sig` 归 ""），控制中心不留
  // 幽灵条目。set_now_playing 不 raise（trait 注），这里不用接错。
  match self.player.track() {
    Some(t) => {
      let (st, sa) = cm_display_fields(t, self.display)
      let pos = self.player.position()
      let pos_s = if pos < 0 { 0L } else { pos }
      let sig = "\{t.path}|\{self.display is Tags}|\{pos_s / 1000L}|\{playing}"
      if sig != self.np_sig {
        self.np_sig = sig
        self.app
        .backend()
        .set_now_playing(st, sa, pos_s, self.player.duration(), playing)
      }
    }
    None =>
      if self.np_sig != "" {
        self.np_sig = ""
        self.app.backend().set_now_playing("", "", 0L, -1L, false)
      }
  }
}

///|
/// 进度条拖动：slider 千分位 → 毫秒 seek（C-08 行为表：播着不动）。
pub fn[B, A : AudioEngine] LunaMusicApp::on_seek_slider(
  self : LunaMusicApp[B, A],
  permille : Int32,
) -> Unit {
  let dur = self.player.duration()
  if dur > 0 {
    // 在途标志把 `refresh_bar` 的那次回写挡掉（`T149`，字段上的长注释在这里
    // 落地）：拖到哪儿画哪儿，别让引擎回报的旧位置把拇指拽回去。
    self.seeking = true
    self.player.seek(dur * permille.to_int64() / 1000L)
    self.seeking = false
    // 自绘那一层照用户拖到的位置走。原生滑块自己已经在用户手指底下，不用碰
    // ——碰了反而在跟踪循环里把它拽一下。
    match self.ui {
      Some({ bar, .. }) => bar.prog_bar.set_permille(permille) catch { _ => () }
      None => ()
    }
  }
}

///|
/// 歌词刷新：随播放进度把当前行高亮。只在播着时由 500ms 心跳驱动（native 壳），
/// 不在 wasm 测试路径上触发（避免走到读文件的 load_lyrics_for）。
/// 当前曲路径变了才重新读 .lrc；否则只按位置重算高亮行。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::refresh_lyrics(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  match self.ui {
    Some({ lyrics, desk, .. }) =>
      match self.player.track() {
        Some(t) => {
          if t.path != self.lyrics_path {
            self.lyrics_path = t.path
            // 读本地 .lrc 失败（wasm 半显式 Unsupported、真机上权限/IO 错）
            // 按"没有本地词"处理，**不往上抛**：这个 raise 会直接跳过下面的
            // 在线取词，于是一次读盘失败就把整条歌词链掐死（`T158` 的 wasm
            // 测试咬出来的）。无歌词本来就是常态，安静退回空表。
            self.current_lyrics = load_lyrics_for(t.path) catch { _ => [] }
            // 第二档源（`T180`）：本地 .lrc 没有，试**内嵌歌词**。先按 LRC 解
            // （内嵌带时间轴的白赚逐句高亮），解不出任何一句才当纯文本匀速铺。
            // 内嵌在场就不会走到下面的联网取词——`maybe_fetch_online_lyrics`
            // 的空表判据天然把这条链封住。
            if self.current_lyrics.length() == 0 && t.lyrics.length() > 0 {
              let parsed = parse_lrc(t.lyrics)
              self.current_lyrics = if parsed.length() > 0 {
                parsed
              } else {
                plain_lyrics_to_timed(t.lyrics, t.duration_ms)
              }
            }
            // 本地没有词才问服务器（`T158`）。判据是"解析结果是空的"而不是
            // "文件不存在"：一份时间标签全坏的 .lrc 同样等于没有词，去网上
            // 要一份比留着空壳有用。
            self.maybe_fetch_online_lyrics(t)
          }
          // 拖动定位中（`T161`②）：歌词跟手走拖动位置，松手自然回落到播放位置。
          // `seeking` 是进度滑块那条账，这里不碰——两个拖动源各有一条独立的
          // 拖动期（`T149` 的回写规则只认滑块）。
          let pos = match self.lyric_drag_ms {
            Some(ms) => ms
            None => self.player.position()
          }
          let (shown_title, shown_artist) = cm_display_fields(t, self.display)
          let _ = lyrics.update(
            self.current_lyrics,
            pos,
            shown_title,
            shown_artist,
          )
          let _ = desk.update(
            self.current_lyrics,
            self.player.position(),
            shown_title,
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
  // 详情伴窗（`T180`）：开着才刷——收着时每拍白灌 label 与 repaint 没有意义。
  // 开着但没在播时心跳不跑，这里也就不刷；开窗那一刻 `toggle_detail` 现刷一趟。
  if self.detail_open {
    self.refresh_detail() catch {
      _ => ()
    }
  }
  // 有没有歌词决定桌面歌词窗露不露头：换歌（读 .lrc）与停播（清空）都经过这里。
  self.sync_desk_window()
}

///|
/// 播放详情伴窗（`T180`）开/关：菜单「窗口 → 播放详情」与托盘「播放详情」
/// 共用这一条。开时先刷内容再 `show`（先内容后显示，`T122` 同一条顺序观），
/// 关时只收起不销毁（窗的 CloseAction 是 `Hide`，红绿灯关窗走
/// `refresh_detail` 头上的 `take_close_hidden` 吸账）。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::toggle_detail(
  self : LunaMusicApp[B, A],
) -> Unit {
  match self.ui {
    Some(u) =>
      if self.detail_open {
        u.detail_win.hide() catch {
          _ => ()
        }
        self.detail_open = false
      } else {
        self.detail_open = true
        self.refresh_detail() catch {
          _ => ()
        }
        u.detail_win.show() catch {
          _ => ()
        }
      }
    None => ()
  }
}

///|
/// 详情伴窗的内容刷新（`T180`）：文案三行 + 大字歌词高亮 + 大封面。开着时由
/// `refresh_lyrics`（500ms 心跳）带着跑；心跳只在播着时自续，暂停期间的详情
/// 窗内容冻结——位置本来就不在动，冻结的恰是正确画面。头上有 `T192` 同款
/// 的吸账：用户按了红绿灯（CloseAction 是 `Hide`），把 `detail_open` 结清，
/// 下一次 toggle 才是干净的"开"。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::refresh_detail(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  match self.ui {
    Some(u) => {
      if u.detail_win.take_close_hidden() {
        self.detail_open = false
        return
      }
      match self.player.track() {
        Some(t) => {
          let (shown_title, shown_artist) = cm_display_fields(t, self.display)
          u.detail.update(
            self.current_lyrics,
            self.player.position(),
            self.player.duration(),
            shown_title,
            shown_artist,
          )
          u.detail.set_cover(t.cover, t.path)
        }
        None => {
          u.detail.update([], 0L, self.player.duration(), "未播放", "")
          u.detail.set_cover(None, "")
        }
      }
    }
    None => ()
  }
}

///|
/// 本地没词就走在线取词（`T158`）。**立即返回**，结果由壳在 worker 上拿回来
/// 经 `apply_online_lyrics` 落到 UI 线程。
///
/// 三条值守：
/// 1. `on_fetch_online` 是 None（无头测试 / wasm / 用户没接）就什么都不做；
/// 2. `lyrics_asked_path` 判"问过没有"——问过的一律不再问，包括没查到的。
///    这条不能漏：`refresh_lyrics` 是 500ms 心跳驱动的，没有这道闸就是每半秒
///    一轮 HTTP；
/// 3. 候选表全空（连歌名都没有）不发请求，但仍记已问过——否则那首歌会每拍
///    重走一遍这段判断。
fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::maybe_fetch_online_lyrics(
  self : LunaMusicApp[B, A],
  t : Track,
) -> Unit {
  if self.current_lyrics.length() > 0 {
    return // 本地有词，不需要联网
  }
  match self.on_fetch_online {
    None => ()
    Some(fetch) => {
      if t.path == self.lyrics_asked_path {
        return // 这首歌问过了
      }
      self.lyrics_asked_path = t.path
      let candidates = tag_query_candidates(t)
      let duration_s = if t.duration_ms > 0L {
        t.duration_ms.to_double() / 1000.0
      } else {
        0.0
      }
      // 回调形状对齐 on_fetch_online 的声明；这里不能用方法指针（闭包里要
      // 捕 self），所以包一层 lambda
      let land : (String, String?) -> Unit = fn(path : String, lrc : String?) {
        self.apply_online_lyrics(path, lrc)
      }
      fetch(t.path, candidates, duration_s, land)
    }
  }
}

///|
/// 在线取词的结果落地（`T158`）。在 UI 线程由壳投递进来。
///
/// **路径判据先过一遍**：用户可能在请求飞在路上时已经切了歌，那份词是上一首
/// 的，贴上去就是错位（`T153` 的 `lit_path` 同一个教训）。判据用 `lyrics_path`
/// （当前正在显示的那首）而不是 `player.track()`：两者在换歌那一瞬可能不同步，
/// 而 `lyrics_path` 正是我们拿去做显示依据的那一个。
///
/// 结果为空不是错误——无歌词是常态，什么都不做即可（`lyrics_asked_path` 已经
/// 挡住了重问）。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::apply_online_lyrics(
  self : LunaMusicApp[B, A],
  path : String,
  lrc : String?,
) -> Unit {
  if path != self.lyrics_path {
    return // 换歌了，这份词过期
  }
  match lrc {
    Some(text) => {
      let parsed = parse_lrc(text)
      // 解析结果为空同样按"没查到"处理，不覆盖已有的空缓存去触发一次重绘
      if parsed.length() > 0 {
        // 落音乐旁的缓存档（`T159`②）：下次打开这首歌直接读盘，不再联网。
        //
        // 落点是共用的 `歌.lrc`（别的播放器也认）；它已经存在就不写——判据与
        // 理由在 `lyric_save_path` 头上。
        //
        // 写失败不影响本次显示：音乐目录只读（外置盘/共享目录/导入的曲库）、
        // 路径太长都可能失败，那只是"下次还得再问一次服务器"，不该让这一次的
        // 歌词不显示。所以这两步的 raise 都就地吞掉。
        let cache = lyric_save_path(path) catch { _ => "" }
        if cache.length() > 0 {
          @moonui.Fs::write_text_atomic(cache, text) catch {
            _ => ()
          }
        }
        self.current_lyrics = parsed
        // 换歌词等于换内容：歌词秀与桌面歌词窗立刻跟上，不等下一个心跳
        self.refresh_lyrics() catch {
          _ => ()
        }
      }
    }
    None => ()
  }
}

///|
/// 打开「搜索歌词」小窗（`T161`①）。窗懒建一次，之后复用——见 `search_dlg`
/// 字段的注释。
///
/// 预填取 `tag_query_candidates` 的第一格：多数时候用户只是想把自动猜错的
/// 那一半改一下，从空框敲一整遍是白费。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::open_search_lyrics(
  self : LunaMusicApp[B, A],
) -> Unit {
  let t = match self.player.track() {
    Some(t) => t
    None => return // 没在放歌：没有可搜的对象
  }
  let (anchor, title, artist) = match self.ui {
    Some(u) =>
      match tag_query_candidates(t) {
        [] => (u.lyrics_win, t.title, t.artist)
        [first, ..] => (u.lyrics_win, first.0, first.1)
      }
    None => return
  }
  // 已销毁的那只不能再用（`T164`②）：mac 上这个窗唯一的关闭口是系统红绿灯，
  // 它走的是 `windowShouldClose:` → `Close` 事件 → `Window::release`——整棵
  // 内容树跟着关掉、窗口标成 `closed`，之后 `show()` 只会抛 `Destroyed`，
  // 外面 `catch` 一吞就是"第二次点「搜索歌词」没反应"。判据放在这里而不是
  // 顶层 ✕ 那条路上：那条路（`close()`）只是藏窗口，复用得正是它。
  match self.search_dlg {
    Some(d) => if d.window.is_closed() { self.search_dlg = None }
    None => ()
  }
  let d = match self.search_dlg {
    Some(d) => d
    None => {
      let b = self.app.backend()
      let d = LyricSearchDialog::new(
        b,
        self.app,
        fn(f_title, f_artist, land) {
          match self.on_search_lyrics {
            Some(fetch) => fetch(f_title, f_artist, land)
            // 没接壳（无头 / wasm）：立刻回空，让状态行从"查询中…"回到"没找到"
            None => land([])
          }
        },
        fn(r) { self.apply_searched_lyric(r) },
        fn() { self.close_search_lyrics() },
      ) catch {
        _ => return
      }
      self.search_dlg = Some(d)
      d
    }
  }
  d.open(title, artist, anchor) catch {
    _ => ()
  }
}

///|
/// 关掉搜索窗（用户点顶条 ✕）。
pub fn[B : @platform-services.PlatformServices, A] LunaMusicApp::close_search_lyrics(
  self : LunaMusicApp[B, A],
) -> Unit {
  match self.search_dlg {
    Some(d) => d.close()
    None => ()
  }
}

///|
/// 用户双击了一条搜索结果（`T161`①）：**立刻写回本地**并换成这一份。
///
/// 与自动取词那条路的**分工**是本函数最要紧的一处：
/// - `lyric_save_path`（`lyrics.mbt`）服务于"自动取词"，判据是"这个文件已经
///   存在就不碰"——机器不该覆盖别人放好的 `.lrc`；
/// - 这里走到的是用户**亲手挑的**那一条，覆盖正是它的语义（owner 的原话：
///   「如果已经存在歌词文件，直接覆盖」）。所以这里直接用共用的
///   `lyric_path_for` 拿路径，**不问存在与否**。
///
/// 两处指向同一个文件名，不引入第二个落点——别的播放器也读得到。
///
/// 解析不出任何行就什么都不做：宁可保留原来那份，也不拿一份坏 `.lrc` 去
/// 覆盖磁盘。写盘失败同样不影响本次显示（音乐目录只读、路径过长都可能失败），
/// 那只是"下次还得挑一次"。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::apply_searched_lyric(
  self : LunaMusicApp[B, A],
  r : LyricSearchResult,
) -> Unit {
  let parsed = parse_lrc(r.lrc)
  if parsed.length() == 0 {
    return
  }
  // 落盘目标：当前正在显示的那首（`lyrics_path` 是显示依据，与
  // `apply_online_lyrics` 用同一格）。没在放歌就没有落点。
  let path = self.lyrics_path
  if path.length() > 0 {
    let target = lyric_path_for(path)
    if target.length() > 0 {
      @moonui.Fs::write_text_atomic(target, r.lrc) catch {
        _ => ()
      }
    }
  }
  self.current_lyrics = parsed
  // 已经替用户问过了：别让自动那条路下一次心跳又去打一遍服务器（打回来的
  // 很可能是同一份错的词）。
  self.lyrics_asked_path = path
  self.refresh_lyrics() catch {
    _ => ()
  }
}

///|
/// 拖动歌词定位（`T161`②）：按住的这一行对应的歌词下标 → seek 过去。
///
/// **实时跟手**（owner 定的）：拖动中每一行变化就 seek 一次，不等松手。
/// `lyric_drag_ms` 记下拖动位置，`refresh_lyrics` 读它——所以歌词窗立刻翻到
/// 那一句，进度条那边也有东西可显示。
fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::scrub_to_lyric(
  self : LunaMusicApp[B, A],
  idx : Int32,
) -> Unit {
  if idx < 0 || idx >= self.current_lyrics.length() {
    return
  }
  let ms = (self.current_lyrics[idx].t * 1000.0).to_int64()
  self.lyric_drag_ms = Some(ms)
  self.player.seek(ms)
  self.refresh_lyrics() catch {
    _ => ()
  }
}

///|
/// 松手：清拖动账，把进度条拉回真实位置（拖动期间 `refresh_bar` 可能没跑）。
fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::end_lyric_scrub(
  self : LunaMusicApp[B, A],
) -> Unit {
  self.lyric_drag_ms = None
  self.refresh_bar() catch {
    _ => ()
  }
  self.refresh_lyrics() catch {
    _ => ()
  }
}

///|
/// 添加目录（真窗走系统选目录面板，无头走注入的 pick 回调）。
/// 扫描在调用方（FP3 的 worker 或测试的同步直灌），结果 merge 后 rebuild。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::merge_scan(
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
/// 拖文件进窗的落点分流（`T179`）：FileDrop 事件只带路径清单、不带落点
/// 坐标（框架契约如此，后端只转发路径），「命中侧栏哪一条」拿不到——退而
/// 求其次按**当前页**分流：正看着某张歌单页（tab ≥ 3）拖进来 = 加进那张
/// 歌单（加曲幂等口径同批 7）；其他页照旧并曲库，不碰歌单。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::drop_tracks(
  self : LunaMusicApp[B, A],
  found : Array[Track],
) -> Unit raise @moonui.UiError {
  if found.length() == 0 {
    return
  }
  if self.tab >= 3 && self.tab - 3 < self.playlists.length() {
    let paths : Array[String] = []
    for t in found {
      paths.push(t.path)
    }
    self.add_to_playlist(self.tab - 3, paths)
    return
  }
  self.merge_scan("(拖入)", found)
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
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::set_eq_band(
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
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::set_eq_preset(
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
/// 频谱推进一帧：向引擎要 16 段能量（原生层 FFT 的活），换算成目标高度后按
/// **实测帧间隔** `dt_ms` 让每根柱子追过去（起音快、落音慢，见 `Spectrum`）。
///
/// 返回值是"还有柱子没落定"——调用方据它决定要不要续下一帧：静止的频谱一秒
/// 三十帧地重画是一笔白花的预算（自绘面每帧要开一张位图、重放整份清单）。
///
/// `T155` 之前这一发挂在 500ms 心跳上，只在有能量时让条子亮灭——所以旧版
/// 频谱是"每秒两次台阶"，本来就不是动画。帧间隔由壳量了传进来（应用本体不
/// 读墙钟，`T84` 的判据全靠这条）；无头测试传自己编排的值。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::refresh_spectrum(
  self : LunaMusicApp[B, A],
  dt_ms : Int32,
) -> Bool raise @moonui.UiError {
  let levels : Array[Int32] = []
  let mut any = false
  for i = 0; i < cm_viz_bands(); i = i + 1 {
    let lv = self.player.engine.level(i)
    if lv > 0 {
      any = true
    }
    levels.push(lv)
  }
  let moving = match self.ui {
    Some(u) => u.bar.viz.update(levels, dt_ms)
    None => false
  }
  self.spectrum_lit = any || moving
  moving
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
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::set_skin(
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
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::set_skin_by_name(
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
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::add_skin_file(
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
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::reset_skin(
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
    // 歌单页（`T175`）：内容按**歌单里的顺序**摆（不排序——用户排的心意），
    // 搜索过滤照常适用；库里已删的文件跳过不进视图（path-only 账）。
    t if t >= 3 => self.playlist_tracks(t - 3)
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
    // 歌单页（`T175`）：大字就是歌单名；序号越界（歌单刚被删）兜个通用名
    t if t >= 3 =>
      if t - 3 < self.playlists.length() {
        self.playlists[t - 3].name
      } else {
        "歌单"
      }
    _ => "本地音乐"
  }
}

///|
/// 队列跟随视图：只在「视图结构变了」时换（换页签/改排序/清空搜索/播放全部/
/// 双击播放），搜索打字期间不换——否则每敲一个字都重洗一次随机牌堆。
/// force=false 且搜索框非空时不动队列（只动显示）。
pub fn[B, A : AudioEngine] LunaMusicApp::sync_queue(
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
/// 「下一首播放」（`T176`）：把 paths 里的曲**按给定顺序**插到当前曲之后；
/// 没播过（current 为空）等价追加。path 找不到的（已从曲库删掉）跳过。
/// 队列页签下就地刷（行数变了走 `refresh_table`——插队不频繁，滚动回顶
/// 可接受）；别的页签队列变化不可见，不动 UI。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::play_next_soon(
  self : LunaMusicApp[B, A],
  paths : Array[String],
) -> Unit {
  if paths.length() == 0 {
    return
  }
  let tracks : Array[Track] = []
  for p in paths {
    for t in self.lib.tracks {
      if t.path == p {
        tracks.push(t)
        break
      }
    }
  }
  if tracks.length() == 0 {
    return
  }
  let _ = self.player.insert_next(tracks)
  if self.tab == 2 {
    self.view = self.compute_view()
    self.refresh_table()
  }
}

///|
/// 队列拖拽的 DragOver 落点账（`T176`）：光标在行框上半 → 插到该行之前，
/// 下半 → 之后。只记边沿（插入位真变了才重建窗内行重画指示）——DragOver
/// 每条移动都发，不边沿就是每条移动重建一遍行。
fn[B, A] LunaMusicApp::queue_drag_over(
  self : LunaMusicApp[B, A],
  i : Int32,
  f : @moonui.LogicalRect,
  p : @moonui.LogicalPoint,
) -> Unit {
  if self.tab != 2 {
    return
  }
  let n = self.view.length()
  let mut pos = if p.y < f.origin.y + f.size.height / 2.0 { i } else { i + 1 }
  if pos > n {
    pos = n
  }
  if self.drag_ins != Some(pos) {
    // 旧/新落点行各就地板色重判一次（set_style 只下样式，不动树）——
    // pos == n 是"接到队尾"，落在最后一行上
    let old_row = match self.drag_ins {
      Some(old) => if old < n { old } else { n - 1 }
      None => -1
    }
    self.drag_ins = Some(pos)
    self.restyle_row_bg(old_row)
    self.restyle_row_bg(if pos < n { pos } else { n - 1 })
  }
}

///|
/// 这一行是不是「accent 浅底」那一类（`T226`）：拖拽落点 / 当前曲 / 选中行。
///
/// 底色与**前景**共用这一份判据（`T207` 单一写入口的同一条教训）：两处各写
/// 一遍条件，迟早出现"底色按 accent、前景按另一套"的错位。落点账照旧在这
/// 里内部算——调用方（`row_bg_decision` 与 `build_row`）都不该自己再碰
/// `drag_ins`。
fn[B, A] LunaMusicApp::row_is_accent(
  self : LunaMusicApp[B, A],
  i : Int32,
  t : Track,
  playing : Bool,
) -> Bool {
  let drop_hit = match self.drag_ins {
    Some(pos) => {
      let n = self.view.length()
      pos == i || (pos >= n && i == n - 1)
    }
    None => false
  }
  drop_hit || playing || self.is_selected(t.path)
}

///|
/// 行底色的唯一判定（`T207` 单一写入口）：落点高亮 / 当前曲 / 选中 /
/// 斑马，build_row 建行和拖拽中的就地重刷都走这里。「哪几类行是 accent 底」
/// 归 `row_is_accent`（`T226` 起前景色也读它）。
fn[B, A] LunaMusicApp::row_bg_decision(
  self : LunaMusicApp[B, A],
  i : Int32,
  t : Track,
  playing : Bool,
) -> @moonui.Color? {
  if self.row_is_accent(i, t, playing) {
    Some(cm_accent_bg())
  } else if i % 2 == 1 {
    Some(cm_zebra())
  } else {
    None
  }
}

///|
/// 就地刷第 `i` 行（视图序）的面板底色：不重建、不动树，句柄全部原样——
/// 拖拽会话中 pressed 的句柄也活着。行没 materialized（出窗）就不刷，
/// `build_row` 下次建行时会按当下账判定。
fn[B, A] LunaMusicApp::restyle_row_bg(
  self : LunaMusicApp[B, A],
  i : Int32,
) -> Unit {
  if i < 0 || i >= self.view.length() {
    return
  }
  match self.ui {
    Some(u) =>
      for pair in u.table.list.rows {
        if pair.0 == i {
          // pair.1 是 VirtualList 的 Sized 锁高壳，行 Panel 是它唯一的孩子
          match pair.1.children().get(0) {
            Some(panel) =>
              panel.set_style(
                Some(
                  @moonui.style(
                    background=self.row_bg_decision(
                      i,
                      self.view[i],
                      self.player.current is Some(c) && c == i,
                    ),
                  ),
                ),
              ) catch {
                _ => ()
              }
            None => ()
          }
        }
      }
    None => ()
  }
}

///|
/// 拖放落点写账（`T176`）：DragDrop 把源行（`drag_src`，按下句柄时记的）
/// 挪到 `drag_ins` 记的插入位，两笔账都清、就地重建行。队列页签的 view 是
/// 队列的副本（compute_view 拷贝一份），重排后重算。
fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::queue_drop(
  self : LunaMusicApp[B, A],
) -> Unit {
  let from = match self.drag_src {
    Some(f) => f
    None => return
  }
  let pos = match self.drag_ins {
    Some(p) => p
    None => return
  }
  self.drag_src = None
  self.drag_ins = None
  self.player.move_track(from, pos)
  self.view = self.compute_view()
  self.cm_rebuild_list_rows()
}

///|
/// 就地重建窗内那十来行（`T153` 同一条路）：拖拽指示/重排都不改行数，
/// 不走 `refresh_table`（那会把滚动位置弹回顶）。
fn[B : @platform-services.PlatformServices, A] LunaMusicApp::cm_rebuild_list_rows(
  self : LunaMusicApp[B, A],
) -> Unit {
  match self.ui {
    Some(u) => u.table.refresh_current() catch { _ => () }
    None => ()
  }
}

///|
/// 数据变了、树没变：就地改列表区（`T128`）。
///
/// 换页签 / 改排序 / 改搜索词 / 清空这四类入口只改"列表里放哪些歌 + 哪个页签
/// 点亮 + 标题与计数"，控件结构一模一样。旧路径全走 `rebuild_ui`——它拆掉六只
/// 窗的整棵树重造（一次 ~700ms），主控窗的播放按钮、「状态：就绪」这些跟列表
/// 无关的控件也被销毁重造，于是切一次页签整个界面闪一下。这里只让
/// `TrackTable::refresh` 改那四样，行也只重建窗内十来行。
///
/// `self.ui` 还没建（启动期还没走过 `rebuild_ui`）时什么都不用做——下一趟
/// `rebuild_ui` 会按当时的 `tab` / `view` 建出正确的树。
fn[B : @platform-services.PlatformServices, A] LunaMusicApp::refresh_table(
  self : LunaMusicApp[B, A],
) -> Unit {
  match self.ui {
    Some(u) =>
      u.table.refresh(self.view.length(), self.tab_title(), self.tab) catch {
        _ => ()
      }
    None => ()
  }
}

///|
/// 换页签：跟随原版「点一下切列表」，队列同步过去（force）。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::set_tab(
  self : LunaMusicApp[B, A],
  t : Int32,
) -> Unit {
  self.tab = t
  self.view = self.compute_view()
  self.sync_queue(true)
  self.refresh_table()
}

///|
/// 点列头：同一列再点是升降翻转，换列则回到升序。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::set_sort(
  self : LunaMusicApp[B, A],
  key : Int32,
) -> Unit {
  let k = match key {
    1 => ByTitle
    2 => ByArtist
    3 => ByAlbum
    4 => ByDuration
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
  self.refresh_table()
}

///|
/// 清空：按页签语义——本地音乐清曲库与目录，收藏页签清收藏，队列页签只停播
/// 并清空队列。问一句再动手（Backend::confirm，无头测试返回默认）。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::clear_view(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  let what = self.tab_title()
  if !@moonui.Backend::confirm(
      self.app.backend(),
      "清空",
      "确定清空「\{what}」？",
    ) {
    return
  }
  match self.tab {
    1 => self.lib.favorites.clear()
    2 => {
      self.player.stop()
      self.player.replace_queue([])
    }
    // 歌单页（`T175`）：清的是歌单的路径清单，曲库不动。必须在 `_` 兜底
    // 之前——落进兜底会清掉整个曲库！
    t if t >= 3 => {
      let pi = t - 3
      if pi < self.playlists.length() {
        self.playlists[pi].paths.clear()
      }
      self.player.replace_queue([])
    }
    _ => {
      self.lib.tracks.clear()
      self.lib.dirs.clear()
      self.player.replace_queue([])
    }
  }
  // 清空的是列表本身，选中集合跟着作废（不清的话"清空再扫回来"会看到一批
  // 莫名其妙亮着的行）——`T177`
  self.selected.clear()
  self.view = self.compute_view()
  self.refresh_table()
}

///|
/// 导出 m3u：把当前视图写进用户挑的文件（系统保存面板）。
/// 路径按原样写绝对路径——本地库本来就是绝对路径，相对路径的解法留给播放器。
pub fn[B : @platform-services.PlatformServices, A] LunaMusicApp::export_m3u(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  if self.view.length() == 0 {
    let _ = @moonui.Backend::confirm(
      self.app.backend(),
      "导出 m3u",
      "当前列表是空的",
    )
    return
  }
  match
    @moonui.Backend::save_file(self.app.backend(), "导出 m3u", "playlist.m3u") {
    Some(p) => {
      let text = m3u_export(self.view)
      @moonui.Fs::write_text_atomic(p, text) catch {
        _ => ()
      }
    }
    None => ()
  }
}

///|
/// 导入 m3u：系统打开面板 → 读文本 → 解析路径 → 走注入的批量探测 → 并入库。
/// 探测失败的歌也会进来（`Track::from_path` 兜底），不阻塞导入。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::import_m3u(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  match @moonui.Backend::open_file(self.app.backend(), "导入 m3u") {
    Some(p) =>
      match @moonui.Fs::read_text(p) {
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
// 用户自建歌单（`T175`）：账的增删改 + 命名小窗 + 批量收藏/导出（`T177` 接账）
// ————————————————————————————————————————————————————

///|
/// 页签行要铺的歌单名（TrackTable 建树用，与页签号 3+i 对齐）。
pub fn[B, A] LunaMusicApp::playlist_tab_names(
  self : LunaMusicApp[B, A],
) -> Array[String] {
  let out : Array[String] = []
  for pl in self.playlists {
    out.push(pl.name)
  }
  out
}

///|
/// 第 `idx` 张歌单的内容。path-only 账：歌单里记的是路径，曲库里已删的那首
/// 跳过不进视图（路径还留着——文件回来了歌单也就回来了）。
pub fn[B, A] LunaMusicApp::playlist_tracks(
  self : LunaMusicApp[B, A],
  idx : Int32,
) -> Array[Track] {
  let out : Array[Track] = []
  if idx >= 0 && idx < self.playlists.length() {
    for p in self.playlists[idx].paths {
      for t in self.lib.tracks {
        if t.path == p {
          out.push(t)
          break
        }
      }
    }
  }
  out
}

///|
/// 把 `paths` 按给定顺序加进第 `pi` 张歌单。重复 path 跳过（幂等，与收藏
/// 同一条口径）；真加进了才换树（页签计数与内容行都变）。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::add_to_playlist(
  self : LunaMusicApp[B, A],
  pi : Int32,
  paths : Array[String],
) -> Unit raise @moonui.UiError {
  if pi < 0 || pi >= self.playlists.length() {
    return
  }
  let n = playlist_add_paths(self.playlists, self.playlists[pi].name, paths)
  if n > 0 {
    self.rebuild_ui()
  }
}

///|
/// 「从列表移除」在歌单页签的口径：从**当前歌单**的路径清单里摘掉这一条，
/// 曲库不动。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::remove_from_current_playlist(
  self : LunaMusicApp[B, A],
  path : String,
) -> Unit raise @moonui.UiError {
  let t = self.tab
  if t < 3 || t - 3 >= self.playlists.length() {
    return
  }
  let pi = t - 3
  let _ = playlist_remove_path(self.playlists, self.playlists[pi].name, path)
  self.view = self.compute_view()
  self.rebuild_ui()
}

///|
/// 打开命名小窗（新建/重命名共用，懒建一次复用——同 `edit`/`search_dlg` 的
/// 销毁清账）。`on_ok` 收输入框现读的名字；重名/空名的拒绝账在调用方的
/// on_ok 里（对话框只管把字交出去）。
fn[B : @platform-services.PlatformServices, A] LunaMusicApp::open_name_dialog(
  self : LunaMusicApp[B, A],
  title : String,
  prefill : String,
  on_ok : (String) -> Unit,
) -> Unit raise @moonui.UiError {
  let anchor = match self.ui {
    Some(u) => u.window
    None => return
  }
  match self.name_dlg {
    Some(d) => if d.window.is_closed() { self.name_dlg = None }
    None => ()
  }
  let d = match self.name_dlg {
    Some(d) => d
    None => {
      let b = self.app.backend()
      let d = PlaylistNameDialog::new(b, self.app, title, on_ok, fn() {
        self.close_name_dialog()
      })
      self.name_dlg = Some(d)
      d
    }
  }
  d.open(title, prefill, on_ok, anchor)
}

///|
/// 关掉命名小窗。
pub fn[B : @platform-services.PlatformServices, A] LunaMusicApp::close_name_dialog(
  self : LunaMusicApp[B, A],
) -> Unit {
  match self.name_dlg {
    Some(d) => d.close()
    None => ()
  }
}

///|
/// 「＋」新建歌单：命名小窗（预填空）。空名不收；重名拒绝（不自动后缀——
/// 用户自己起的歌单名替他改了反而是惊吓，弹一句让他改）。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::new_playlist(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  self.open_name_dialog("新建歌单", "", fn(name : String) {
    self.close_name_dialog()
    if name == "" {
      return
    }
    if playlist_add(self.playlists, name) {
      self.rebuild_ui() catch {
        _ => ()
      }
    } else {
      let _ = @moonui.Backend::confirm(
        self.app.backend(),
        "新建歌单",
        "已有叫「\{name}」的歌单",
      ) catch {
        _ => false
      }
    }
  })
}

///|
/// 歌单页签右键「重命名…」：命名小窗预填旧名。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::rename_playlist(
  self : LunaMusicApp[B, A],
  pi : Int32,
) -> Unit raise @moonui.UiError {
  if pi < 0 || pi >= self.playlists.length() {
    return
  }
  let old = self.playlists[pi].name
  self.open_name_dialog("重命名歌单", old, fn(name : String) {
    self.close_name_dialog()
    if name == "" || name == old {
      return
    }
    if playlist_rename(self.playlists, old, name) {
      self.rebuild_ui() catch {
        _ => ()
      }
    } else {
      let _ = @moonui.Backend::confirm(
        self.app.backend(),
        "重命名歌单",
        "已有叫「\{name}」的歌单",
      ) catch {
        _ => false
      }
    }
  })
}

///|
/// 歌单页签右键「删除」：问一句，删账；正看着这张歌单就退回本地音乐页签。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::delete_playlist(
  self : LunaMusicApp[B, A],
  pi : Int32,
) -> Unit raise @moonui.UiError {
  if pi < 0 || pi >= self.playlists.length() {
    return
  }
  let name = self.playlists[pi].name
  if !@moonui.Backend::confirm(
      self.app.backend(),
      "删除歌单",
      "确定删除歌单「\{name}」？",
    ) {
    return
  }
  let _ = playlist_remove(self.playlists, name)
  if self.tab >= 3 {
    self.tab = 0
  }
  self.rebuild_ui()
}

///|
/// 批量收藏选中的 N 首（`T177` 接账）：已是收藏的跳过（幂等），一次换树。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::batch_favorite_selected(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  let mut n = 0
  for p in self.selected {
    if !self.lib.is_favorite(p) {
      self.lib.toggle_favorite(p) |> ignore
      n = n + 1
    }
  }
  if n > 0 {
    self.rebuild_ui()
  }
}

///|
/// 批量导出选中的 N 首成 m3u（`T177` 接账）：系统保存面板 → 按**选中顺序**
/// 写绝对路径清单。导出的口径与「导出 m3u」一致（视图无关，只看选中集合）。
pub fn[B : @platform-services.PlatformServices, A] LunaMusicApp::batch_export_selected(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  if self.selected.length() == 0 {
    return
  }
  match
    @moonui.Backend::save_file(
      self.app.backend(),
      "导出选中的 \{self.selected.length()} 首",
      "selection.m3u",
    ) {
    Some(p) => {
      // 选中集合记的是 path，导出前按曲库现解成 Track（库里的只剩这些有内容）
      let tracks : Array[Track] = []
      for path in self.selected {
        for t in self.lib.tracks {
          if t.path == path {
            tracks.push(t)
            break
          }
        }
      }
      let text = m3u_export(tracks)
      @moonui.Fs::write_text_atomic(p, text) catch {
        _ => ()
      }
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
pub fn[B : @platform-services.PlatformServices, A] LunaMusicApp::toggle_roll(
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
pub fn[B : @platform-services.PlatformServices, A] LunaMusicApp::reset_layout(
  self : LunaMusicApp[B, A],
) -> Unit {
  match self.ui {
    Some(u) => {
      let screen = @moonui.Backend::screen_size(self.app.backend()) catch {
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
pub fn[B : @platform-services.PlatformServices, A] LunaMusicApp::toggle_mini(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  match self.ui {
    Some(u) => {
      self.mini = !self.mini
      if self.mini {
        // 迷你条贴主控的**左上角**（`T211`）：不落位的话它出现在窗口几何档
        // 记的老位置，切换的瞬间窗就在两处之间"跳"。position/set_position
        // 都是顶左口径（mac pack_frame：y 从该屏可见区上边往下量），主控
        // 380 宽起步、迷你条 300×48——主控装得下它就装得下，同一点不必再
        // 夹屏。读不上/摆不动就退回老位置，切换本身不受阻。
        try {
          let anchor = u.window.position()
          u.mini_win.set_position(anchor)
        } catch {
          _ => ()
        }
        u.window.hide()
        u.lyrics_win.hide()
        u.playlist_win.hide()
        u.eq_win.hide()
        u.mini_win.show()
        // 桌面歌词跟 `mini` 走：进迷你模式收起。
        self.sync_desk_window()
        // 迷你条回来了：跑马灯重新量账点火（藏着的那些拍里链是停着的，
        // 心跳最多 500ms 才来一拍，这里先滚起来）。
        self.mini_marquee_sync(self.marq_full)
      } else {
        u.mini_win.hide()
        // 伴窗先亮、主控**最后**亮（`T210`）：mac 的 show 是
        // `makeKeyAndOrderFront`，后 show 的窗抢 key——原次序主控先亮、
        // 歌词秀/播放列表/均衡器随后各抢一次，双击回主控后键盘焦点就落在
        // 伴窗上（屏幕最前的是主控，焦点不在）。伴窗先亮顺带把层叠次序也
        // 摆正：主控压在最上面。桌面歌词也赶在主控前亮（它开着时同样抢 key）。
        if self.show_lrc {
          u.lyrics_win.show()
        }
        if self.show_pl {
          u.playlist_win.show()
        }
        if self.show_eq {
          u.eq_win.show()
        }
        self.sync_desk_window()
        u.window.show()
      }
    }
    None => ()
  }
}

///|
/// 迷你条歌名跑马灯（2026-11-05 三修③）的节奏：250ms 一拍（≈4 字/秒，
/// T214：owner 报 150ms ≈6.7 字/秒滚得太急），头/尾各停 5 拍（≈1.25s，
/// 拍数随拍距缩放、停顿的真实时长与初版 8×150ms 持平）。
const MARQ_INTERVAL_MS : Int32 = 250

///|
const MARQ_HOLD_TICKS : Int32 = 5

///|
/// 迷你条一排格子的行距（`MiniBar::new` 的 row 与格宽反推共用这一份）。
const MINI_BAR_GAP : Double = 4.0

///|
/// 歌名比格宽长时按格宽切片滚动：每拍推进一个字符（拍距见
/// `MARQ_INTERVAL_MS`），到句尾停 `MARQ_HOLD_TICKS` 拍，回头部再停同样多拍。
/// 不走 `set_bounds` 平移——容器不裁剪子树（mac 侧连
/// clipsToBounds 都没开），滚出去的字会画到按钮上；切片方案双平台一致，
/// 也用不上 Core 的 T84 动画（时长钉死 300ms，不合跑马灯的拍子）。
///
/// `refresh_bar`（每 500ms）与 `toggle_mini` 都经这里进出：链活着且句子没
/// 变时是 no-op，不打扰滚动；其余情形停旧链、量账（整句固有宽 vs 格宽，
/// 格宽是 Core 布局账，expand 格不随文字变）、再决定点火还是摆整句。
fn[B : @platform-services.PlatformServices, A] LunaMusicApp::mini_marquee_sync(
  self : LunaMusicApp[B, A],
  full : String,
) -> Unit raise @moonui.UiError {
  let changed = full != self.marq_full
  self.marq_full = full
  if !self.mini {
    let _ = self.app.cancel_every(self.marq_ticker)
    self.marquee_reset()
    return
  }
  match self.ui {
    Some(u) => {
      if self.marq_ticker.running() && !changed {
        return
      }
      let _ = self.app.cancel_every(self.marq_ticker)
      self.marquee_reset()
      u.mini.title.set_text(full)
      let n = cm_char_count(full)
      let full_w = u.mini.title.intrinsic_size().width
      // 格宽反推：歌名格是 Sized+Expand，不进 Core 的 placed 表、自己没有
      // frame；歌名 label 与上一颗钮（prev，紧挨格子右缘）都是叶子，格宽 =
      // prev 左缘 - 行距 - 歌名左缘。
      let cell_w = u.mini.prev.frame().origin.x -
        MINI_BAR_GAP -
        u.mini.title.frame().origin.x
      if full_w <= cell_w || n <= 1 {
        return
      }
      let char_w = full_w / n.to_double()
      let mut f = (cell_w / char_w).floor().to_int()
      if f > n - 1 {
        f = n - 1
      }
      // 平均字宽只是估计：切片逐字收窄，直到真的装得下——防个别宽字顶格
      // 换行，24pt 高的格里第二行是看不见的。
      let mut fitted = false
      while f >= 1 {
        u.mini.title.set_text(cm_slice_chars(full, 0, f))
        if u.mini.title.intrinsic_size().width <= cell_w {
          fitted = true
          break
        }
        f = f - 1
      }
      if !fitted {
        return
      }
      self.marq_fit = f
      let _ = self.app.post_every(self.marq_ticker, MARQ_INTERVAL_MS, _first => {
        self.mini_marquee_tick()
      })
    }
    None => ()
  }
}

///|
/// 跑马灯的一拍：头部停 → 逐字推进 → 尾停 → 回头部。返回 `false` 收链
/// （迷你条已收起 / 句账清了 / 句子装得下——sync 量过账不该点火的那几样）。
fn[B : @platform-services.PlatformServices, A] LunaMusicApp::mini_marquee_tick(
  self : LunaMusicApp[B, A],
) -> Bool raise @moonui.UiError {
  if !self.mini {
    return false
  }
  match self.ui {
    Some(u) => {
      let full = self.marq_full
      let n = cm_char_count(full)
      if self.marq_fit < 1 || self.marq_fit >= n {
        return false
      }
      if self.marq_at_end {
        self.marq_hold = self.marq_hold - 1
        if self.marq_hold <= 0 {
          self.marq_at_end = false
          self.marq_i = 0
          self.marq_hold = MARQ_HOLD_TICKS
          let _ = u.mini.title.set_text(cm_slice_chars(full, 0, self.marq_fit))
        }
        return true
      }
      if self.marq_hold > 0 {
        self.marq_hold = self.marq_hold - 1
        return true
      }
      let max_i = n - self.marq_fit
      self.marq_i = self.marq_i + 1
      if self.marq_i >= max_i {
        self.marq_i = max_i
        self.marq_at_end = true
        self.marq_hold = MARQ_HOLD_TICKS
      }
      let _ = u.mini.title.set_text(
        cm_slice_chars(full, self.marq_i, self.marq_fit),
      )
      true
    }
    None => false
  }
}

///|
/// 滚动账清零（不碰 `marq_full`——那是要不要重滚的判据）。
fn[B, A] LunaMusicApp::marquee_reset(self : LunaMusicApp[B, A]) -> Unit {
  self.marq_i = 0
  self.marq_fit = 0
  self.marq_hold = MARQ_HOLD_TICKS
  self.marq_at_end = false
}

///|
/// 字符数（按 Char，不按字节——中文一个字就是一个字）。
fn cm_char_count(s : String) -> Int32 {
  let mut n = 0
  for _ch in s {
    n = n + 1
  }
  n
}

///|
/// `s` 的第 `start` 个字符起取 `count` 个（按 Char）。尾部不足就到尾为止。
fn cm_slice_chars(s : String, start : Int32, count : Int32) -> String {
  let buf = StringBuilder()
  let mut i = 0
  for ch in s {
    if i >= start {
      buf.write_char(ch)
    }
    i = i + 1
    if i >= start + count {
      break
    }
  }
  buf.to_string()
}

///|
/// 桌面歌词显隐（原版是右键菜单里的开关，这里走控制菜单与托盘菜单）。
///
/// 开关与"现在挂不挂"分开：开着的状态会被记住，但没歌词时窗还是不挂
/// （见 `cm_desk_visible`）——等歌词读进来了，心跳里的 sync 会把它挂上。
pub fn[B : @platform-services.PlatformServices, A] LunaMusicApp::toggle_desk(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  // 先吸掉"用户按过关闭钮"那一笔（`T192`）：它在下一拍心跳之前就可能被这
  // 一下菜单点压住，不先同步，`show_desk` 还是旧的 true，翻过来变 false，
  // 用户点「桌面歌词」反而把开着的状态关掉了。
  self.sync_desk_window()
  self.show_desk = !self.show_desk
  self.sync_desk_window()
}

///|
/// 桌面歌词窗的显隐落地端：**按边沿**触底。
///
/// 为什么不能每拍无脑 show：`Window::show` 落的是
/// `makeKeyAndOrderFront:`，播放时 500ms 一拍，等于每半秒把焦点从用户正在
/// 用的程序抢回来。所以先和 `desk_shown` 比一次，只有"该变"了才碰窗口。
fn[B : @platform-services.PlatformServices, A] LunaMusicApp::sync_desk_window(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  match self.ui {
    Some(u) => {
      // `T192`：用户按了桌面歌词窗的关闭钮。那只窗的 `CloseAction` 是 `Hide`
      // （Core 只把它收起来、不销毁），所以"关掉"这件事得在这里接住：开关账
      // 一并关掉，否则下一次判"该显示"时边沿没变，窗口就再也不回来了。
      //
      // 这一笔也顺手把接在窗上的内容树保住了——旧行为是 Close 直接 `release`，
      // 内容树整棵销毁，而 500ms 心跳还在往那几只 Label 上 `set_text`，下一拍
      // 就从 `Destroyed` 里抛出来，表现正是 owner 报的"关掉桌面歌词整个程序退出"。
      if u.desk_win.take_close_hidden() {
        self.show_desk = false
        self.desk_shown = false
        return
      }
      let want = cm_desk_visible(
        self.show_desk,
        self.mini,
        self.current_lyrics.length() > 0,
      )
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
/// `T195`：退出前结算"用户按过桌面歌词关闭钮"这一笔。
///
/// 为什么不能只靠心跳：`sync_desk_window` 只在 `refresh_lyrics`（500ms 心跳）
/// 与几个显式开关里跑，而心跳只在**播着**时自续。暂停时关掉浮条再退出，
/// 没有下一拍来吸账，`show_desk` 会停在 true，档里就记成"用户还要它"——
/// 下次启动又挂回来，正是这次要修的现象。退出路径先结一次账再存档。
pub fn[B, A] LunaMusicApp::absorb_desk_close(self : LunaMusicApp[B, A]) -> Unit {
  match self.ui {
    Some(u) =>
      if u.desk_win.take_close_hidden() {
        self.show_desk = false
        self.desk_shown = false
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
/// 播放控制的**唯一**入口（`T181`）：媒体键、全局热键、托盘菜单、播放菜单
/// 四条来路汇到这里，一套状态机。码表见 adapter.h 媒体键段：0 = 播放/暂停、
/// 1 = 下一首、2 = 上一首；表外静默不猜。toggle 与菜单/托盘同款带 refresh_bar
/// （播放条图标跟手）；prev/next 的界面刷新走 player 的 notify 广播。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::media_action(
  self : LunaMusicApp[B, A],
  code : Int32,
) -> Unit {
  match code {
    1 => self.player.next()
    2 => self.player.prev()
    0 => {
      self.player.toggle()
      self.refresh_bar() catch {
        _ => ()
      }
    }
    _ => ()
  }
}

///|
/// 托盘（T86⑥）：图标 + 右键菜单。图标进程级一只装一次；菜单走
/// `refresh_tray`（`T183`）——曲名/模式/音量都在菜单里，装的时候先刷一遍。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::install_tray(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  let _ = @platform-services.set_tray_icon(self.app, "assets/logo/luna")
  self.refresh_tray()
}

///|
/// 托盘菜单（`T183`）：当前曲（禁用项，只报不改）+ 播放/暂停 / 上一首 /
/// 下一首 / 播放模式（点一下循环，与播放条模式钮同语义）/ 音量（五档子菜单）
/// / 迷你模式 / 桌面歌词 / 退出。菜单是静态装的，而 `MenuItem` 没有 set_text
/// ——曲名/模式/音量三样会变，变了整菜单重设：签名（曲路径 + 模式 + 音量‰）
/// 与上一拍相同就一个字不动（refresh_bar 每 300ms 一拍，播放中位置在变但这
/// 三样不常变），变了才重建。重设即替换（native_tray_set_menu 整树换），旧
/// 菜单的闭包随之丢弃，没有累积账。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::refresh_tray(
  self : LunaMusicApp[B, A],
) -> Unit raise @moonui.UiError {
  let (now_label, cur_path) = match self.player.track() {
    Some(t) => {
      let (shown_title, _) = cm_display_fields(t, self.display)
      ("♪ \{shown_title}", t.path)
    }
    None => ("♪ 未播放", "")
  }
  // 签名里带 display（`T193`）：口径切换会改曲名的显示文案，托盘要跟着换。
  let sig = "\{cur_path}|\{self.player.mode.label()}|\{self.player.volume}|\{self.display is Tags}"
  if sig == self.tray_sig {
    return
  }
  self.tray_sig = sig
  let now = @moonui.MenuItem::new(now_label)
  let _ = now.set_enabled(false)
  // 播放/暂停/上一首/下一首走 `media_action`（`T181`）：托盘与媒体键/全局
  // 热键/播放菜单共用同一入口，不写两份状态机。
  let toggle = @moonui.MenuItem::new("播放/暂停")
  let _ = toggle.on(fn(_) { self.media_action(0) })
  let prev = @moonui.MenuItem::new("上一首")
  let _ = prev.on(fn(_) { self.media_action(2) })
  let next = @moonui.MenuItem::new("下一首")
  let _ = next.on(fn(_) { self.media_action(1) })
  let mode = @moonui.MenuItem::new("播放模式：\{self.player.mode.label()}")
  let _ = mode.on(fn(_) {
    self.player.cycle_mode()
    self.refresh_bar() catch {
      _ => ()
    }
  })
  // 音量五档（‰ 与播放条滑块同源）：托盘上没有滑块，给档位比没有强。
  let vol_nodes : Array[@moonui.MenuNode] = []
  let vol_steps : Array[(String, Int32)] = [
    ("静音", 0),
    ("25%", 250),
    ("50%", 500),
    ("75%", 750),
    ("100%", 1000),
  ]
  for (name, v) in vol_steps {
    let item = @moonui.MenuItem::new(name)
    let _ = item.on(fn(_) {
      self.player.set_volume(v)
      self.refresh_bar() catch {
        _ => ()
      }
    })
    vol_nodes.push(Item(item))
  }
  let mini = @moonui.MenuItem::new("迷你模式")
  let _ = mini.on(fn(_) { self.toggle_mini() catch { _ => () } })
  let desk = @moonui.MenuItem::new("桌面歌词")
  let _ = desk.on(fn(_) { self.toggle_desk() catch { _ => () } })
  let detail = @moonui.MenuItem::new("播放详情")
  let _ = detail.on(fn(_) { self.toggle_detail() })
  let quit = @moonui.MenuItem::new("退出")
  let _ = quit.on(fn(_) { self.app.quit() })
  let _ = @platform-services.set_tray_menu(
    self.app,
    @moonui.Menu::new("Luna", [
      Item(now),
      Separator,
      Item(toggle),
      Item(prev),
      Item(next),
      Item(mode),
      Submenu("音量", vol_nodes),
      Separator,
      Item(mini),
      Item(desk),
      Item(detail),
      Separator,
      Item(quit),
    ]),
  )
}

///|
/// 收藏开关（播放条 ♡ 与右键菜单共用）：改完重建（列表窗的收藏页签与行色
/// 都要跟着变，行色本来就走 rebuild 换树）。
pub fn[B : @platform-services.PlatformServices, A : AudioEngine] LunaMusicApp::toggle_favorite(
  self : LunaMusicApp[B, A],
  path : String,
) -> Unit raise @moonui.UiError {
  let _ = self.lib.toggle_favorite(path)
  self.rebuild_ui()
}
