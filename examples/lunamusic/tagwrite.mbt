///|
/// 歌曲信息写回音频文件（DESIGN.md C-16）。
///
/// 纯逻辑、不门控：输入整个文件的 `Bytes`，输出新的 `Bytes`，不碰文件系统。
/// 真正落盘由壳注入的 `write_tags` 调 `file_write_bytes_atomic` 完成——
/// 这样 wasm 门禁能编，测试也不需要音频素材（造最小骨架即可往返）。

///|
/// 写入结果。`Failed` 带一句人话（上来的 `TagError::message()`）。
pub(all) enum TagWriteResult {
  Written
  UnsupportedFormat
  Failed(String)
} derive(Debug, Eq)

///|
/// 把 title / artist / album 写进 `data` 的标签，返回完整的新文件字节。
///
/// **空串 = 删除该字段**（四种容器语义一致：ID3v2 的 `set_fields`、
/// FLAC/Ogg 的 `VorbisComment::set_key`、MP4 由 `set_mp4_tags_with_delete` 补上）。
/// 删空之后 `Track` 由 `track_from_probe` 退回文件名兜底，与扫描同一条路。
///
/// 失败时返回**原样的 `data`**，调用方据此保证"不写盘"。
pub fn cm_write_tags(
  data : Bytes,
  title : String,
  artist : String,
  album : String,
) -> (Bytes, TagWriteResult) {
  let format = @lunamusic-tag.detect_format(data.exact_view())
  match format {
    Unknown => (data, UnsupportedFormat)
    _ =>
      write_by_format(format, data, title, artist, album) catch {
        e => (data, Failed(@lunamusic-tag.TagError::message(e)))
      }
  }
}

///|
/// 按格式分派到对应的写入入口。
fn write_by_format(
  format : @lunamusic-tag.AudioFormat,
  data : Bytes,
  title : String,
  artist : String,
  album : String,
) -> (Bytes, TagWriteResult) raise @lunamusic-tag.TagError {
  match format {
    Mp3 =>
      (
        @lunamusic-tag.set_fields(
          data.exact_view(),
          [
            @lunamusic-tag.field("TIT2", title),
            @lunamusic-tag.field("TPE1", artist),
            @lunamusic-tag.field("TALB", album),
          ],
          @lunamusic-tag.WriteOptions::default(),
        ),
        Written,
      )
    Flac => {
      let vc = match @lunamusic-tag.read_vorbis_comment(data.exact_view()) {
        Some(vc) => vc
        None => @lunamusic-tag.empty_vorbis_comment("lunamusic")
      }
      let vc = vc.set_key("TITLE", title)
      let vc = vc.set_key("ARTIST", artist)
      let vc = vc.set_key("ALBUM", album)
      (@lunamusic-tag.set_vorbis_comment(data.exact_view(), vc), Written)
    }
    Ogg => {
      let loc = match @lunamusic-tag.read_ogg_comment(data) {
        Some(l) => l
        // Ogg 容器但不是 Vorbis/Opus（例如 Ogg Theora）：不假装成功。
        // 上游的 TagError 变体跨包只读，构造不出来，直接给结论。
        None =>
          return (
            data,
            Failed(
              "这个 Ogg 文件不是 Vorbis/Opus，没有可写的 comment",
            ),
          )
      }
      let vc = @lunamusic-tag.parse_ogg_comment_payload(loc)
      let vc = vc.set_key("TITLE", title)
      let vc = vc.set_key("ARTIST", artist)
      let vc = vc.set_key("ALBUM", album)
      (@lunamusic-tag.set_ogg_comment(data, vc), Written)
    }
    Mp4 => {
      let updates : Array[@lunamusic-tag.Mp4Tag] = []
      let deletes : Array[String] = []
      // 空串走删除：MP4 的 ilst 没有"空值条目"这种表达。
      let fields : Array[(String, String)] = [
        ("©nam", title),
        ("©ART", artist),
        ("©alb", album),
      ]
      for pair in fields {
        let (k, v) = pair
        if v == "" {
          deletes.push(k)
        } else {
          updates.push(@lunamusic-tag.mp4_text_tag(k, v))
        }
      }
      (
        @lunamusic-tag.set_mp4_tags_with_delete(
          data.exact_view(),
          updates,
          deletes,
        ),
        Written,
      )
    }
    Unknown => (data, UnsupportedFormat)
  }
}
