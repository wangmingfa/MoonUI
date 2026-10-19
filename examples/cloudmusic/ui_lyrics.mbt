///|
/// 歌词秀（千千静听的精神主体）：居中 3 行，中间是当前句（大字高亮 + 强调蓝），
/// 上下两句淡灰小字；随播放进度每拍由 app.refresh_lyrics 重设文字与颜色
/// （卡拉OK式，不重建整树——复用 set_text/set_style 把手模式）。
///
/// 现在是主控面板下方的紧凑歌词条（原版歌词秀是独立窗，这里单窗内下挂）。
pub(all) struct LyricsView[B] {
  root : @moonui.Widget[B]
  song : @moonui.Widget[B]
  lines : Array[@moonui.Widget[B]]
}

///|
pub fn[B : @moonui.Backend] LyricsView::new(
  b : B,
) -> LyricsView[B] raise @moonui.UiError {
  let song = @moonui.Widget::label(b, "").foreground(cm_muted()).font_size(11.0)
  let lines : Array[@moonui.Widget[B]] = []
  let cells : Array[@moonui.Widget[B]] = []
  for i = 0; i < 3; i = i + 1 {
    let l = @moonui.Widget::label(
        b,
        if i == 1 {
          "（暂无歌词）"
        } else {
          ""
        },
      )
      .foreground(if i == 1 { cm_lyric_cur() } else { cm_lyric_dim() })
      .font_size(if i == 1 { 17.0 } else { 12.0 })
      .font_weight(
        if i == 1 {
          @moonui.FontWeight::Bold
        } else {
          @moonui.FontWeight::Regular
        },
      )
    lines.push(l)
    // 居中的写法：`Center` 只在**给足 frame** 时才居中（它量的是子项固有宽、
    // 摆位按外面的 frame 算），所以每行外面套一层定宽 Sized 把 frame 撑满。
    // 注意：`lines` 里留的是**标签本体**（app 要 set_text），树里挂的是包装层。
    cells.push(
      @moonui.Widget::sized(
        b,
        Some(cm_main_w() - 40.0),
        None,
        @moonui.Widget::center(b, l),
      ),
    )
  }
  let lines_col = @moonui.Widget::column(b, 6.0, cells)
  // 上下弹性 spacer 把歌词簇推到垂直中线
  let song_row = @moonui.Widget::sized(
    b,
    Some(cm_main_w() - 40.0),
    None,
    @moonui.Widget::center(b, song),
  )
  let inner = @moonui.Widget::column(b, 0.0, [
    song_row,
    @moonui.Widget::spacer(b).with_expand(true),
    lines_col,
    @moonui.Widget::spacer(b).with_expand(true),
  ])
  let padded = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(10.0, 24.0),
    inner,
  )
  let root = @moonui.Widget::panel(b, padded)
  let _ = root.set_style(Some(@moonui.style(background=Some(cm_lyric_bg()))))
  { root, song, lines, }
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
  if lyrics.length() == 0 {
    for i = 0; i < 3; i = i + 1 {
      let txt = if i == 1 {
        if title == "" {
          "（暂无歌词）"
        } else {
          title
        }
      } else {
        ""
      }
      let _ = self.lines[i].set_text(txt)
      let _ = self.lines[i].set_style(
        Some(
          @moonui.style(
            foreground=Some(
              if i == 1 {
                cm_lyric_cur()
              } else {
                cm_lyric_dim()
              },
            ),
            font_size=Some(if i == 1 { 17.0 } else { 12.0 }),
            font_weight=Some(
              if i == 1 {
                @moonui.FontWeight::Bold
              } else {
                @moonui.FontWeight::Regular
              },
            ),
          ),
        ),
      )
    }
    return
  }
  let active = active_lyric_index(lyrics, pos_ms)
  for i = 0; i < 3; i = i + 1 {
    let idx = active - 1 + i
    let txt = if idx >= 0 && idx < lyrics.length() {
      lyrics[idx].text
    } else {
      ""
    }
    let _ = self.lines[i].set_text(txt)
    let is_cur = i == 1
    let _ = self.lines[i].set_style(
      Some(
        @moonui.style(
          foreground=Some(if is_cur { cm_lyric_cur() } else { cm_lyric_dim() }),
          font_size=Some(if is_cur { 17.0 } else { 12.0 }),
          font_weight=Some(
            if is_cur {
              @moonui.FontWeight::Bold
            } else {
              @moonui.FontWeight::Regular
            },
          ),
        ),
      ),
    )
  }
}

///|
/// 桌面歌词（千千静听那块浮在屏幕底部的双行条）：当前句大字在上、下一句小字
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
  let cur = @moonui.Widget::label(b, "千千静听")
    .foreground(cm_text_light())
    .font_size(18.0)
    .font_weight(@moonui.FontWeight::Bold)
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
    let _ = self.cur.set_text(if title == "" { "千千静听" } else { title })
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
