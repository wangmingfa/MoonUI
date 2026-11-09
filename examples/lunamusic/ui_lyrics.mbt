///|
/// 歌词秀的行数（`T159`③）：当前句居中，上下各两行。
///
/// 从 3 行改到 5 行是 owner 2026-10-29 点的：3 行只看得见紧邻的上下各一句，
/// 一句唱完就立刻换屏，读歌词像在追字幕；5 行能提前看到下一句、也能回味上一句，
/// 才是"看歌词"的节奏。窗口高 240 装 5 行（17 + 4×12 + 行距）绰绰有余。
pub fn cm_lyric_lines() -> Int32 {
  5
}

///|
/// 当前句在 `lines` 里的下标（5 行时是 2，居中的那一行）。
fn cm_lyric_center() -> Int32 {
  cm_lyric_lines() / 2
}

///|
/// 歌词秀（Luna的精神主体）：居中 5 行，中间是当前句（大字高亮 + 强调蓝），
/// 上下各两句淡灰小字；随播放进度每拍由 app.refresh_lyrics 重设。
///
/// **`T161` 起五行是一整块自绘面**（`Widget::custom`），不是五只 `Label`。
/// 理由只有一条：拖动定位需要 `MouseDown`/`MouseMove`/`MouseUp` 三个带坐标的
/// 事件，而框架只把它们投给自绘面（`backends/native-abi/native_abi.mbt`：
/// `target_is_custom` 才翻 `PressTo`/`ReleaseTo`）。叠一层透明面在标签上又
/// 不可靠——那取决于整窗是否 layer-backed，没法在无头侧证明。
///
/// 代价：五行没有原生文本对象了，`dump_layout` 不再有那五段文案断言（测试改
/// 读自绘清单），也没有无障碍文本。歌名那一行仍是普通 Label，不受影响。
///
/// 拖动链路（`T161`②）：
/// - 按下 → 把 y 换成行号、行号换成歌词下标 → `on_scrub(idx)`（app 立刻 seek）；
/// - 移动 → 同上重算，只有变了才重画；
/// - 抬起 → `on_scrub_end()`（app 清拖动账、把进度条拉回真实位置）。
///
/// **`T191` 改手感：拖动是"抓住这张纸在拖"，不是"点哪跳哪"**（owner 2026-11-02
/// 报的两条：拖动一格一格跳、方向反了）。旧版把指针 y 直接换算成行号、行号再
/// 换算成歌词下标，而画面又恒以 `active` 居中重排——于是①指针在行内移动时画面
/// 纹丝不动，跨过行边界就整块换一行，看着就是"跳"；②指针往下 = 下标变大 = 时间
/// 往后，与"用手把歌词往下拽"的直觉相反。
///
/// 现在窗口位置是一个**连续的小数滚动位置** `scroll`（可见窗口最上面那一行对应
/// 的歌词下标）。按下时记下指针处的小数下标作锚点，之后恒有
/// `scroll = drag_anchor - 局部 y / 行高`，按住的**那条**歌词始终贴在指针下面——
/// 指针每挪一像素，文字就跟着挪一像素；往下拽 = `scroll` 变小 = 前面的歌词从
/// 顶上露出来。
///
/// 目标句由**正中那一行**决定（横条恒画在正中行上缘）：纸跟着手走，指针与内容
/// 相对静止，只有固定不动的中点才能当指针用。正中句一变就 `on_scrub(idx)`；
/// 抬起后 `scroll` 回到 `active - 居中行` 的整数位。
pub(all) struct LyricsView[B] {
  mut root : @moonui.Widget[B]
  song : @moonui.Widget[B]
  /// 五行自绘面（`T161`）
  mut face : @moonui.Widget[B]
  /// 整首歌词：自绘回调按 `scroll` 现取可见的那几行
  mut lyrics : Array[Lyric]
  /// 当前句在**整首歌词**里的下标（-1 = 没有）
  mut active : Int32
  /// 可见窗口**最上面那一行**对应的歌词下标。不拖动时是整数
  /// （`active - 居中行`），拖动时是小数——平滑跟手全靠它。
  mut scroll : Double
  /// 没有歌词时正中那行显示的字（歌名 /（暂无歌词））
  mut placeholder : String
  /// 是否正在拖动（`MouseDown` 到 `MouseUp` 之间）
  mut dragging : Bool
  /// 按下那一刻指针处的**小数歌词下标**：`scroll + 局部 y / 行高`。
  /// 松开之前 `scroll` 恒由它和当前指针位置算出，按住的歌词才不会脱手。
  mut drag_anchor : Double
  /// 拖动中正中那行对应的时间点（毫秒），画在横条右端
  mut drag_ms : Int64
}

///|
/// 每行的高度。17pt 的当前句 + 4 行 12pt，24 一行留得出行距又不散。
pub fn cm_lyric_row_h() -> Double {
  24.0
}

///|
/// 歌词自绘面的宽度：与歌词窗内容区同宽（窗宽减两侧内边距）。
fn cm_lyric_face_w() -> Double {
  cm_lyrics_w() - 48.0
}

///|
/// 局部 y（相对面左上）→ 指针处的小数歌词下标：`scroll + y / 行高`。
/// 拖动期间"按住的那一句"就靠这条恒等式跟着指针走。
fn[B] cm_lyric_pos_at(view : LyricsView[B], p : @moonui.LogicalPoint) -> Double {
  let origin = view.face.frame().origin
  view.scroll + (p.y - origin.y) / cm_lyric_row_h()
}

///|
/// **正中行**此刻压着的小数位置——拖动期间它充当指针：纸跟着手走，只有窗口
/// 里固定不动的那一点能用来取样。
///
/// 正中第 `mid` 行占的区间是 `[scroll+mid, scroll+mid+1)`，这里取带**中央**
/// （`+0.5`）：静止时 `scroll = active - mid`，结果正好是 `active`；拖动中上下
/// 挪不足半行仍是同一句。
///
/// **不能省掉那个 `+0.5`**：`cm_lyric_pos_at` 问的是"手指压住的像素属于哪一
/// 行"，区间本就从整数起，纯 `floor` 就对；这里问的是"窗口正中看着哪一行"，
/// 少了 `+0.5` 就是在行带的**上边界**取样，指针往下挪一像素正中句就翻到上一句
/// （`T191` 第一版栽在这，平滑判据 `2 != 4` 抓住的）。
fn[B] cm_lyric_center_pos(view : LyricsView[B]) -> Double {
  view.scroll + cm_lyric_center().to_double() + 0.5
}

///|
/// 小数下标 → 夹在 `[0, n-1]` 的整数下标。
///
/// 取 `floor` 不是 `round`：第 i 句占的是小数区间 `[i, i+1)`，指针落在区间
/// 中间（`i+0.5`，也就是行带的垂直中央）时仍属于第 i 句。用 `round` 的话
/// "正中那行的正中央"会跳到下一句，静止时（`scroll = active - 居中行`）正好
/// 错开半行。
fn cm_lyric_clamp_idx(n : Int32, pos : Double) -> Int32 {
  if n <= 0 {
    return -1
  }
  let i = pos.floor().to_int()
  if i < 0 {
    0
  } else if i >= n {
    n - 1
  } else {
    i
  }
}

///|
pub fn[B : @platform-services.PlatformServices] LyricsView::new(
  b : B,
  on_scrub : (Int32) -> Unit,
  on_scrub_end : () -> Unit,
) -> LyricsView[B] raise @moonui.UiError {
  let song = @moonui.Widget::label(b, "").foreground(cm_muted()).font_size(11.0)
  // 视图账：`scroll` / `active` / `dragging` / `drag_anchor` / `drag_ms` / `lyrics`
  // 都是自绘回调每次重画时现读的；`update` 只改这些格子再 `repaint()`，不碰树。
  let view : LyricsView[B] = {
    root: @moonui.Widget::spacer(b), // 占位，下面替换成真正的根
    song,
    face: @moonui.Widget::spacer(b), // 同上
    lyrics: [],
    active: -1,
    scroll: 0.0,
    placeholder: "（暂无歌词）",
    dragging: false,
    drag_anchor: 0.0,
    drag_ms: 0L,
  }
  let face = @moonui.Widget::custom(
    b,
    @moonui.LogicalSize(
      cm_lyric_face_w(),
      cm_lyric_lines().to_double() * cm_lyric_row_h(),
    ),
    fn(dl, env) { paint_lyrics(view, dl, env) },
  )
  view.face = face
  // 拖动接线：三个事件都在这一处收（`data_grid.mbt` 的同款手法）。
  //
  // 坐标口径：`Event` 里给的点是**窗口内容区的绝对坐标**，`face.frame()` 也在
  // 同一个空间，相减得到控件局部 y。拖出上下边界也没关系——`scroll` 是小数、
  // 正经由夹取的行号换算时间，越界那段自然收敛到首/末句。
  let _ = face.on_any(fn(ev) raise @moonui.UiError {
    match ev {
      @moonui.MouseDown(_, @moonui.Left, p, _) => {
        // 锚点 = 指针此刻压着的那一句（小数）。松手之前 scroll 由它反推，
        // 所以手指抓住的那行字始终在指针底下。
        view.drag_anchor = cm_lyric_pos_at(view, p)
        view.dragging = true
        view.drag_ms = 0L
        let idx = cm_lyric_clamp_idx(view.lyrics.length(), view.drag_anchor)
        if idx >= 0 && idx < view.lyrics.length() {
          view.drag_ms = (view.lyrics[idx].t * 1000.0).to_int64()
          on_scrub(idx)
        }
        face.repaint()
      }
      @moonui.MouseMove(_, p) =>
        if view.dragging {
          // 纸跟着手走：scroll 逐像素连续变化（旧版在这里按行号跳）。
          let sc = view.drag_anchor -
            (p.y - view.face.frame().origin.y) / cm_lyric_row_h()
          view.scroll = sc
          // 目标句由**正中那一行**决定：纸动的时候只有中点不动，它是唯一的
          // 指针。正中那行 = 窗口顶 + 居中行。
          let idx = cm_lyric_clamp_idx(
            view.lyrics.length(),
            cm_lyric_center_pos(view),
          )
          if idx >= 0 && idx < view.lyrics.length() {
            let ms = (view.lyrics[idx].t * 1000.0).to_int64()
            if ms != view.drag_ms {
              view.drag_ms = ms
              on_scrub(idx)
            }
          }
          face.repaint()
        }
      @moonui.MouseUp(_, @moonui.Left, _, _) =>
        if view.dragging {
          view.dragging = false
          on_scrub_end()
          face.repaint()
        }
      _ => ()
    }
  })
  let song_row = @moonui.Widget::sized(
    b,
    Some(cm_main_w() - 40.0),
    None,
    @moonui.Widget::center(b, song),
  )
  // 上下弹性 spacer 把歌词簇推到垂直中线
  let inner = @moonui.Widget::column(b, 0.0, [
    song_row,
    @moonui.Widget::spacer(b).with_expand(true),
    @moonui.Widget::center(b, face),
    @moonui.Widget::spacer(b).with_expand(true),
  ])
  let padded = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(10.0, 24.0),
    inner,
  )
  let root = @moonui.Widget::panel(b, padded)
  let _ = root.set_style(Some(@moonui.style(background=Some(cm_lyric_bg()))))
  view.root = root
  view
}

///|
/// 画一帧：从 `scroll` 起取五行文字（小数位移，跨行的部分被面裁掉）+
/// （拖动时）横条与时间点。
///
/// **不是每行一个整数下标**（`T191`）：`scroll` 是小数，第 i 行的画面 y 由
/// `(scroll + i - first) * row_h` 反推，`first = floor(scroll)`。拖动时指针挪
/// 一像素这里就挪一像素——旧版按整数行下标取文字，所以只能整行整行地跳。
fn[B] paint_lyrics(
  view : LyricsView[B],
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  let row_h = cm_lyric_row_h()
  let mid = cm_lyric_center()
  let n = view.lyrics.length()
  // 拖动时首尾两行会画出面外（y 为负 / 超过面高）：夹一层，别让字溢到面板上。
  // 静止帧 `scroll` 是整数，夹取不改变任何一条命令——正常帧逐位同旧值。
  dl.save()
  dl.clip_rect(0.0, 0.0, w, h)
  // 视野要覆盖的那一段：从 floor(scroll) 起多取一行，上下各留一格余量，
  // 免得小数位移把首尾那一行切掉半截就没了。
  let first = view.scroll.floor().to_int() - 1
  let last = view.scroll.floor().to_int() + cm_lyric_lines()
  for i = first; i <= last; i = i + 1 {
    let text = if i >= 0 && i < n { view.lyrics[i].text } else { "" }
    // 高亮的是**正中那一行**（拖动中中点是指针，静止时就是当前句）。
    // 静止时 `scroll` 是整数，静止帧的高亮因此与旧的"第 mid 行"逐位一致。
    let bold = i == cm_lyric_clamp_idx(n, cm_lyric_center_pos(view))
    // 没有歌词时正中那行给占位字（歌名 /（暂无歌词）），其余留空
    let shown = if text.length() > 0 {
      text
    } else if bold && n == 0 {
      view.placeholder
    } else {
      ""
    }
    if shown.length() == 0 {
      continue
    }
    // 这一行在面里的连续 y：拖动时随 scroll 平滑移动
    let y = (i.to_double() - view.scroll) * row_h
    if y < -row_h || y > cm_lyric_lines().to_double() * row_h {
      continue // 整行都在面外，白画
    }
    // 行内垂直居中：行带高 row_h，字形高 th，两者差的一半就是上边距
    let size = if bold { 17.0 } else { 12.0 }
    let (tw, th) = env.measure_text(shown, size, bold)
    dl.text(
      shown,
      (w - tw) / 2.0,
      y + (row_h - th) / 2.0,
      size~,
      bold~,
      rgb=if bold { cm_lyric_cur_rgb() } else { cm_lyric_dim_rgb() },
    )
  }
  if view.dragging {
    // 横条恒在正中行上缘：纸在动，只有中点不动，它是拖动期间的指针。
    let y = mid.to_double() * row_h
    dl.fill_rect(0.0, y, w, 2.0, radius=1.0, rgb=cm_accent_rgb())
    // 时间点右对齐压在横条上沿之上一点点（12pt，免得与横条贴死）
    let ts = format_duration(view.drag_ms)
    let (tw, _) = env.measure_text(ts, 10.0, true)
    dl.text(ts, w - tw, y - 13.0, size=10.0, bold=true, rgb=cm_accent_rgb())
  }
  dl.restore()
}

///|
/// 按当前播放位置刷新 5 行。无歌词时中间行显示歌名作占位。
pub fn[B : @platform-services.PlatformServices] LyricsView::update(
  self : LyricsView[B],
  lyrics : Array[Lyric],
  pos_ms : Int64,
  title : String,
  artist : String,
) -> Unit raise @moonui.UiError {
  let _ = self.song.set_text(
    if title == "" {
      ""
    } else {
      "\{title} - \{artist}"
    },
  )
  self.lyrics = lyrics
  let mid = cm_lyric_center()
  if lyrics.length() == 0 {
    self.active = -1
    self.scroll = 0.0
    self.placeholder = if title == "" { "（暂无歌词）" } else { title }
    self.face.repaint()
    return
  }
  let active = active_lyric_index(lyrics, pos_ms)
  self.active = active
  // 拖动中不抢 `scroll`：纸在用户手里，`update`（500ms 心跳 + seek 回调）每拍
  // 都会到，一写就把跟手打断——拖动帧的画面只由指针位置决定。
  if !self.dragging {
    // 当前句落在正中那一行：窗口顶那一行 = active - 居中行
    self.scroll = (active - mid).to_double()
  }
  self.face.repaint()
}

///|
/// 桌面歌词（Luna那块浮在屏幕底部的双行条）：当前句大字在上、下一句小字
/// 在下，随播放进度每拍由 app.refresh_lyrics 重设。无歌词时上行走歌名。
/// 原版是穿透点击 + 可拖动的悬浮窗，这里是一只有标题栏的独立小窗（框架没有
/// 无边框穿透窗这条能力，窗口本身可拖动——形状近似，交互差一层）。
pub(all) struct DeskLyrics[B] {
  root : @moonui.Widget[B]
  cur : @moonui.Widget[B]
  next : @moonui.Widget[B]
}

///|
pub fn[B : @platform-services.PlatformServices] DeskLyrics::new(
  b : B,
) -> DeskLyrics[B] raise @moonui.UiError {
  let cur = @moonui.Widget::label(b, "Luna")
    .foreground(cm_text_light())
    .font_size(18.0)
    .font_weight(Bold)
  let next = @moonui.Widget::label(b, "").foreground(cm_bar()).font_size(12.0)
  // 两行各自居中（同歌词秀：定宽 Sized 撑出 frame，Center 才真的居中）
  let wide = 520.0 - 32.0
  let cur_cell = @moonui.Widget::sized(
    b,
    Some(wide),
    None,
    @moonui.Widget::center(b, cur),
  )
  let next_cell = @moonui.Widget::sized(
    b,
    Some(wide),
    None,
    @moonui.Widget::center(b, next),
  )
  let col = @moonui.Widget::column(b, 4.0, [cur_cell, next_cell])
  let inner = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(8.0, 16.0),
    col,
  )
  let root = @moonui.Widget::panel(b, inner)
  let _ = root.set_style(Some(@moonui.style(background=Some(cm_inset()))))
  { root, cur, next, }
}

///|
/// 按当前播放位置刷新两行：当前句 + 下一句（没有就留空）。
pub fn[B : @platform-services.PlatformServices] DeskLyrics::update(
  self : DeskLyrics[B],
  lyrics : Array[Lyric],
  pos_ms : Int64,
  title : String,
) -> Unit raise @moonui.UiError {
  if lyrics.length() == 0 {
    let _ = self.cur.set_text(if title == "" { "Luna" } else { title })
    let _ = self.next.set_text("")
    return
  }
  let active = active_lyric_index(lyrics, pos_ms)
  let _ = self.cur.set_text(
    if active >= 0 && active < lyrics.length() {
      lyrics[active].text
    } else {
      ""
    },
  )
  let nxt = active + 1
  let _ = self.next.set_text(
    if nxt >= 0 && nxt < lyrics.length() {
      lyrics[nxt].text
    } else {
      ""
    },
  )
}
