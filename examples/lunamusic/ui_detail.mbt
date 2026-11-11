///|
/// 播放详情伴窗的大字歌词行数（`T180`）：比歌词秀的五行多——详情窗就是为了
/// "看着歌词听歌"存在的，视野多铺几行才有详情页的意思。
pub fn cm_detail_rows() -> Int32 {
  8
}

///|
/// 见 `cm_detail_rows`：一行的行带高。当前句 22pt + 其余 14pt，40 一行放得下
/// 行距，也和"大字"的定位相称。
pub fn cm_detail_row_h() -> Double {
  40.0
}

///|
/// 播放详情窗（`T180`，DESIGN.md C-11 的落地）：大封面 + 大字歌词 + 基础走带
/// 信息。与歌词秀分工——歌词秀是常驻的横向字幕带，这里是"想认真看的时候拉开"
/// 的竖版详情页。
///
/// 歌词区也是一整块自绘面（与 `LyricsView` 同一条理由：大字排版要走
/// `DrawList`）。**不带拖动定位**：scrub 那套账（`T191`）在歌词秀已经齐了，
/// 详情窗的用户姿势是"看"不是"抓"，复制一套拖动状态机换不来等量的东西——
/// `refresh_detail` 只管把行和高亮画对。
pub(all) struct DetailView[B] {
  mut root : @moonui.Widget[B]
  /// 大封面（`T174` 同款 Image，`set_image_bytes` 灌字节）
  cover : @moonui.Widget[B]
  title : @moonui.Widget[B]
  artist : @moonui.Widget[B]
  /// 已播 / 总时长（"1:23 / 4:56"；总时长未知只给左半）
  pos : @moonui.Widget[B]
  /// 大字歌词自绘面
  mut face : @moonui.Widget[B]
  mut lyrics : Array[Lyric]
  /// 当前句下标（-1 = 没有）
  mut active : Int32
  /// 没有歌词时正中那行显示的字
  mut placeholder : String
  /// 大封面已灌的是哪首（路径）。边沿账自带在视图里（app 侧的 `cover_path`
  /// 是播放条那只 Image 的，两只控件各记各的）；初值是不可能出现的哨兵，
  /// 保证第一次 `set_cover`（哪怕 None + ""）也真的灌占位图。
  mut cover_track : String
}

///|
/// 详情窗大字歌词面的定宽：窗宽 520 减左右内边距 48。
fn cm_detail_face_w() -> Double {
  cm_detail_w() - 48.0
}

///|
pub fn[B : @platform-services.PlatformServices] DetailView::new(
  b : B,
) -> DetailView[B] raise @moonui.UiError {
  let cover = @moonui.Widget::image(b)
  // 直接让 `Sized` 的 200×200 落到 Image 上（与播放条 `Sized(56,56, cover)`
  // 同一条路）。**不要再套 `Center`**：`Sized` 把 frame 原样给子项，而 `Center`
  // 按子项**固有尺寸**居中——占位封面是 224×224，会从 200 的框里各溢 12pt，
  // 压住下面的曲名（`T254` 的实案）。
  let cover_box = @moonui.Widget::sized(b, Some(200.0), Some(200.0), cover)
  let title = @moonui.Widget::label(b, "")
    .foreground(cm_text_light())
    .font_size(18.0)
    .font_weight(Bold)
  let artist = @moonui.Widget::label(b, "")
    .foreground(cm_muted())
    .font_size(13.0)
  let pos = @moonui.Widget::label(b, "").foreground(cm_muted()).font_size(12.0)
  let view : DetailView[B] = {
    root: @moonui.Widget::spacer(b),
    cover,
    title,
    artist,
    pos,
    face: @moonui.Widget::spacer(b),
    lyrics: [],
    active: -1,
    placeholder: "（暂无歌词）",
    cover_track: "\u{0}init",
  }
  let face = @moonui.Widget::custom(
    b,
    @moonui.LogicalSize(
      cm_detail_face_w(),
      cm_detail_rows().to_double() * cm_detail_row_h(),
    ),
    fn(dl, env) { paint_detail_lyrics(view, dl, env) },
  )
  view.face = face
  let rows = @moonui.Widget::column(b, 8.0, [
    cover_box,
    @moonui.Widget::sized(
      b,
      Some(cm_detail_face_w()),
      None,
      @moonui.Widget::center(b, title),
    ),
    @moonui.Widget::sized(
      b,
      Some(cm_detail_face_w()),
      None,
      @moonui.Widget::center(b, artist),
    ),
    @moonui.Widget::sized(
      b,
      Some(cm_detail_face_w()),
      None,
      @moonui.Widget::center(b, pos),
    ),
    @moonui.Widget::spacer(b).with_expand(true),
    face,
    @moonui.Widget::spacer(b).with_expand(true),
  ])
  let padded = @moonui.Widget::padding(b, @moonui.EdgeInsets::all(24.0), rows)
  let root = @moonui.Widget::panel(b, padded)
  let _ = root.set_style(Some(@moonui.style(background=Some(cm_page_bg()))))
  view.root = root
  view
}

///|
/// 画一帧大字歌词：以当前句为锚的整数滚动（`scroll = active - 上半`，与歌词秀
/// 静止帧同一条账），当前句大字高亮，上下句淡灰。
fn[B] paint_detail_lyrics(
  view : DetailView[B],
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  let row_h = cm_detail_row_h()
  let n = view.lyrics.length()
  let rows = cm_detail_rows()
  dl.save()
  dl.clip_rect(0.0, 0.0, w, h)
  let first = view.active - rows / 2
  for r = 0; r < rows; r = r + 1 {
    let i = first + r
    let text = if i >= 0 && i < n { view.lyrics[i].text } else { "" }
    let bold = i == view.active
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
    let size = if bold { 22.0 } else { 14.0 }
    let (tw, th) = env.measure_text(shown, size, bold)
    dl.text(
      shown,
      (w - tw) / 2.0,
      r.to_double() * row_h + (row_h - th) / 2.0,
      size~,
      bold~,
      rgb=if bold { cm_lyric_cur_rgb() } else { cm_lyric_dim_rgb() },
    )
  }
  dl.restore()
}

///|
/// 灌大封面（`T174` 同款路径边沿）：换曲才解码一次。没封面的曲（含没在播）
/// 灌占位图，不空着。字节解不出也退占位图，别让这格白着。
pub fn[B : @platform-services.PlatformServices] DetailView::set_cover(
  self : DetailView[B],
  cover : Bytes?,
  path : String,
) -> Unit {
  if path == self.cover_track {
    return
  }
  self.cover_track = path
  self.cover.set_image_bytes(
    match cover {
      Some(c) => c
      None => cm_placeholder_cover()
    },
  ) catch {
    _ => self.cover.set_image_bytes(cm_placeholder_cover()) catch { _ => () }
  }
}

///|
/// 按当前播放位置刷新详情窗：文案三行 + 歌词高亮。`pos_ms`/`dur_ms` 只喂
/// 时间那一行；封面走 `set_cover` 自己的路径边沿——image 解码比 label 重，
/// 跟着心跳走没有边沿就是每 500ms 重解一遍。
pub fn[B : @platform-services.PlatformServices] DetailView::update(
  self : DetailView[B],
  lyrics : Array[Lyric],
  pos_ms : Int64,
  dur_ms : Int64,
  title : String,
  artist : String,
) -> Unit raise @moonui.UiError {
  let _ = self.title.set_text(title)
  let _ = self.artist.set_text(artist)
  let _ = self.pos.set_text(
    if dur_ms > 0L {
      "\{format_duration(pos_ms)} / \{format_duration(dur_ms)}"
    } else {
      format_duration(pos_ms)
    },
  )
  self.lyrics = lyrics
  self.active = active_lyric_index(lyrics, pos_ms)
  self.placeholder = if title == "" { "（暂无歌词）" } else { title }
  self.face.repaint()
}
