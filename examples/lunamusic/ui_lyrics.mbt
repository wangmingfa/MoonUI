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
/// 拖动中画一条横条 + 右端时间点，是被拖行的**上缘**——参考主流播放器的
/// 「按到哪里就从哪里开始」，横条压在目标句上方，读起来是"指针 = 这一句的起点"。
pub(all) struct LyricsView[B] {
  mut root : @moonui.Widget[B]
  song : @moonui.Widget[B]
  /// 五行自绘面（`T161`）
  mut face : @moonui.Widget[B]
  /// 当前五行要画的文字（下标 0 = 最上面一行）；自绘回调每次重画都读它
  lines : Array[String]
  /// 当前句在**整首歌词**里的下标（-1 = 没有）
  mut active : Int32
  /// 整首歌词：拖动时按行号换算下标、取那一刻的时间点
  mut lyrics : Array[Lyric]
  /// 拖动中被按住的那一行（0..4）；-1 = 没在拖
  mut drag_row : Int32
  /// 拖动中该行对应的时间点（毫秒），画在横条右端
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
pub fn[B : @moonui.Backend] LyricsView::new(
  b : B,
  on_scrub : (Int32) -> Unit,
  on_scrub_end : () -> Unit,
) -> LyricsView[B] raise @moonui.UiError {
  let song = @moonui.Widget::label(b, "").foreground(cm_muted()).font_size(11.0)
  let lines : Array[String] = []
  for i = 0; i < cm_lyric_lines(); i = i + 1 {
    lines.push(if i == cm_lyric_center() { "（暂无歌词）" } else { "" })
  }
  // 视图账：`lines` / `active` / `drag_row` / `drag_ms` / `lyrics` 都是自绘回调
  // 每次重画时现读的；`update` 只改这些格子再 `repaint()`，不碰树。
  let view : LyricsView[B] = {
    root: @moonui.Widget::spacer(b), // 占位，下面替换成真正的根
    song,
    face: @moonui.Widget::spacer(b), // 同上
    lines,
    active: -1,
    lyrics: [],
    drag_row: -1,
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
  // 同一个空间，相减得到控件局部 y。不夹在 face 内部也没关系——拖出上下边界
  // 时行号会越界，下面按 `[0, lyrics-1]` 夹住，正好是"拖到最前/最后"。
  let _ = face.on_any(fn(ev) raise @moonui.UiError {
    match ev {
      @moonui.MouseDown(_, @moonui.Left, p) => {
        let row = cm_lyric_row_at(view, p)
        view.drag_row = row
        view.drag_ms = 0L
        let idx = cm_lyric_index_at(view, row)
        if idx >= 0 && idx < view.lyrics.length() {
          view.drag_ms = (view.lyrics[idx].t * 1000.0).to_int64()
          on_scrub(idx)
        }
        face.repaint()
      }
      @moonui.MouseMove(_, p) =>
        if view.drag_row >= 0 {
          let row = cm_lyric_row_at(view, p)
          if row != view.drag_row {
            view.drag_row = row
            let idx = cm_lyric_index_at(view, row)
            if idx >= 0 && idx < view.lyrics.length() {
              view.drag_ms = (view.lyrics[idx].t * 1000.0).to_int64()
              on_scrub(idx)
            }
            face.repaint()
          }
        }
      @moonui.MouseUp(_, @moonui.Left, _) =>
        if view.drag_row >= 0 {
          view.drag_row = -1
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
/// 绝对坐标 → 五行里的第几行（`None` 语义用 -1：没落在面上）。
fn[B] cm_lyric_row_at(view : LyricsView[B], p : @moonui.LogicalPoint) -> Int32 {
  let origin = view.face.frame().origin
  let y = p.y - origin.y
  let row = (y / cm_lyric_row_h()).to_int()
  if row < 0 {
    0
  } else if row >= cm_lyric_lines() {
    cm_lyric_lines() - 1
  } else {
    row
  }
}

///|
/// 行号 → 整首歌词里的下标：第 i 行 = `active - 居中行 + i`。
///
/// 拖动时 `active` 是**拖动前**那一句的锚点，所以按住正中那行再往下拖两行，
/// 就是"从当前句往后两句"——与主流播放器的行为一致。越界夹到首/末句，
/// 拖过头停在第一句或最后一句（而不是什么都没有）。
fn[B] cm_lyric_index_at(view : LyricsView[B], row : Int32) -> Int32 {
  let n = view.lyrics.length()
  if n == 0 {
    return -1
  }
  let base = if view.active < 0 { 0 } else { view.active }
  let idx = base - cm_lyric_center() + row
  if idx < 0 {
    0
  } else if idx >= n {
    n - 1
  } else {
    idx
  }
}

///|
/// 画一帧：五行文字 + （拖动时）横条与时间点。
///
/// 正常帧与拖动帧共用同一份 `lines`：拖动中不改 `lines`（app 那边 `refresh_lyrics`
/// 已经把拖动位置喂了进去，所以 `active` 跟着走，五行自然就翻到那一句）。
/// 拖动帧额外做的两件事：
/// - 被拖的那一行按**当前句**的样式（17pt 粗 + 强调色）——视觉上"这行就是
///   指针落点"；
/// - 上缘一条 2pt 强调色横条横跨整宽 + 右端上方的时间点。
fn[B] paint_lyrics(
  view : LyricsView[B],
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let row_h = cm_lyric_row_h()
  let mid = cm_lyric_center()
  for i = 0; i < cm_lyric_lines(); i = i + 1 {
    let text = if i < view.lines.length() { view.lines[i] } else { "" }
    if text.length() == 0 {
      continue
    }
    let is_cur = i == mid || i == view.drag_row
    let size = if is_cur { 17.0 } else { 12.0 }
    let bold = is_cur
    let (tw, th) = env.measure_text(text, size, bold)
    // 行内垂直居中：行带高 row_h，字形高 th，两者差的一半就是上边距
    let ty = i.to_double() * row_h + (row_h - th) / 2.0
    dl.text(
      text,
      (w - tw) / 2.0,
      ty,
      size~,
      bold~,
      rgb=if is_cur { cm_lyric_cur_rgb() } else { cm_lyric_dim_rgb() },
    )
  }
  if view.drag_row >= 0 {
    let y = view.drag_row.to_double() * row_h
    dl.fill_rect(0.0, y, w, 2.0, radius=1.0, rgb=cm_accent_rgb())
    // 时间点右对齐压在横条上沿之上一点点（12pt，免得与横条贴死）
    let ts = format_duration(view.drag_ms)
    let (tw, _) = env.measure_text(ts, 10.0, true)
    dl.text(ts, w - tw, y - 13.0, size=10.0, bold=true, rgb=cm_accent_rgb())
  }
}

///|
/// 按当前播放位置刷新 5 行。无歌词时中间行显示歌名作占位。
pub fn[B : @moonui.Backend] LyricsView::update(
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
  let n = cm_lyric_lines()
  let mid = cm_lyric_center()
  if lyrics.length() == 0 {
    self.active = -1
    for i = 0; i < n; i = i + 1 {
      self.lines[i] = if i == mid {
        if title == "" {
          "（暂无歌词）"
        } else {
          title
        }
      } else {
        ""
      }
    }
    self.face.repaint()
    return
  }
  let active = active_lyric_index(lyrics, pos_ms)
  self.active = active
  for i = 0; i < n; i = i + 1 {
    // 当前句落在正中那一行，上下各铺 `mid` 行：第 i 行对应 active - mid + i
    let idx = active - mid + i
    self.lines[i] = if idx >= 0 && idx < lyrics.length() {
      lyrics[idx].text
    } else {
      ""
    }
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
pub fn[B : @moonui.Backend] DeskLyrics::new(
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
pub fn[B : @moonui.Backend] DeskLyrics::update(
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
