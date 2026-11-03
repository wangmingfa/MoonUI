///|
/// 界面上「歌名/歌手」这两格从哪儿取（`T193`）。
///
/// owner 2026-11-02 点的：探针修好之后标签里有真值了，但**默认仍按文件名显示**
/// ——下载来的文件命名本身就带着「歌手-歌名」的信息，而且和用户当初存文件时
/// 看到的样子一致；标签值五花八门（有的带 `(silence)`、有的整串乱码修不好），
/// 一上来就换成标签反而认不出是哪首。想换成标签的，在「控制 → 歌曲信息显示」
/// 里点一下，选择落在 `Prefs` 里（`C-07` 的状态账）。
///
/// 这一层只管**展示**：`Track` 里存的始终是探针读到的真值，排序、搜索、
/// 属性栏里的路径、写标签、在线取词都不受影响——换个显示口径不该改变任何
/// 数据口径。
pub(all) enum DisplaySource {
  /// 只认文件名（默认）
  FileName
  /// 认探针读到的标签
  Tags
} derive(Debug, Eq)

///|
/// 默认口径：文件名。不叫 `default` 是为了不跟 `Default` trait 的方法撞名。
pub fn cm_display_source_default() -> DisplaySource {
  FileName
}

///|
/// 菜单文案。
pub fn DisplaySource::label(self : DisplaySource) -> String {
  match self {
    FileName => "文件名"
    Tags => "标签信息"
  }
}

///|
/// 存档键。用可读字符串而不是序数：偏好档是给人看/手改的，`"filename"` 比
/// `0` 自解释（`mode` 那个用序数是历史包袱，不再扩）。
pub fn DisplaySource::key(self : DisplaySource) -> String {
  match self {
    FileName => "filename"
    Tags => "tags"
  }
}

///|
/// 坏值/未知键回 `None`，调用方按默认起步。
pub fn DisplaySource::of_key(s : String) -> DisplaySource? {
  match s {
    "filename" => Some(FileName)
    "tags" => Some(Tags)
    _ => None
  }
}

///|
/// 展示用的（歌名, 歌手）。两格都可能为空串——调用方按「空就不画这段」处理。
///
/// 「文件名」那一支复用在线取词那侧的 `tag_filename_readings`
/// （`tag.mbt`）：同一套切分规则，两处显示才和「机器替我挑的查询词」一致。
/// 文件名给不出歌手（只有一段）时歌手就是空串——**不留「未知」**：那是标签
/// 缺失的哨兵，"文件名里本来没有歌手"是另一件事，硬写「未知」等于假装查过。
pub fn cm_display_fields(t : Track, source : DisplaySource) -> (String, String) {
  let file_name = cm_file_name(t.path)
  let stem = cm_strip_extension(file_name)
  match source {
    FileName =>
      match tag_filename_readings(file_name) {
        [] => (stem, "")
        [first, ..] => first
      }
    Tags => {
      // 标题等于文件名去扩展名 = 探针没读出标题，这个值是 `Track::from_path`
      // 的兜底而不是标签（判据与 `tag_query_candidates` 同一条）。
      let title = if tag_field_missing(t.title) ||
        @util.same_text_ci(t.title, stem) {
        stem
      } else {
        @util.trim_ws(t.title)
      }
      let artist = if tag_field_missing(t.artist) {
        ""
      } else {
        @util.trim_ws(t.artist)
      }
      (title, artist)
    }
  }
}

///|
/// 展示用的专辑名。「文件名」那一支恒空——文件名里没有专辑这一格，从别处
/// 猜会把播放条那一行塞满噪音。
pub fn cm_display_album(t : Track, source : DisplaySource) -> String {
  match source {
    FileName => ""
    Tags => if tag_field_missing(t.album) { "" } else { @util.trim_ws(t.album) }
  }
}

///|
/// 把非空的几段用 ` - ` 接起来（播放条那行的「歌手 - 专辑」、歌词窗顶的
/// 「歌名 - 歌手」都是这个形状）。全空返回空串，调用方据此留白而不是画一根
/// 光秃秃的横杠。
pub fn cm_join_meta(a : String, b : String) -> String {
  if a == "" {
    b
  } else if b == "" {
    a
  } else {
    "\{a} - \{b}"
  }
}

///|
/// 1×1 全透明 PNG（`T174`）：换到没有封面的曲目时灌给播放条那张 `Image`，
/// 把上一首的封面盖掉。
///
/// 为什么不"什么都不做"：`Image` 的源是**整源替换**语义，不动就一直是上一张
/// ——用户看到的是"点了一首没封面的歌、脸面上却摆着别的专辑"，比空白更糟。
/// 为什么不用 `set_image_bytes(b"")`：空字节在原生侧会被当成解码失败报错
/// （`OperationFailed`），这不是错误路径，只是"没有图"。
pub fn cm_blank_cover() -> Bytes {
  b"\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x0c\x49\x44\x41\x54\x78\xda\x63\x60\x60\x60\x00\x00\x00\x04\x00\x01\xc8\xea\xeb\xf9\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82"
}
