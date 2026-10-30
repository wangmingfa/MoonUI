///|
/// 歌曲信息写回（DESIGN.md C-16）的环形自证：写进去 → 用 vendored 标签库读回来。
///
/// 不需要音频素材——造最小容器骨架即可（上游测试的 `tb_*` 手法）。
/// 这些用例全在 wasm 门禁里跑：`cm_write_tags` 是纯逻辑，不碰文件系统。

///|
/// 一段最简"无标签 mp3"：帧同步头 + 填充。`detect_format` 认 0xFF 0xE0。
fn tw_mp3_audio(len : Int32) -> Bytes {
  Bytes::from_array([0xFF, 0xFB, 0x90, 0x00]).add(Bytes::make(len, 0x55))
}

///|
/// 最简 FLAC：`fLaC` + 一个 last 的 STREAMINFO 块 + 假音频。
fn tw_flac() -> Bytes {
  // 块头：bit7 = last，bit0..6 = 类型 0（STREAMINFO）；后 3 字节大端长度。
  let header = Bytes::from_array([0x80, 0x00, 0x00, 0x22])
  // STREAMINFO 载荷 34 字节：min/max blocksize 各 2、min/max framesize 各 3、
  // 之后 8 字节采样/声道/位深/总样本数。内容随意（不解析）。
  let body = Bytes::make(34, 0x00)
  Bytes::from_array([0x66, 0x4C, 0x61, 0x43])
  .add(header)
  .add(body)
  .add(Bytes::make(20, 0xAA))
}

///|
/// MP4 的一个盒：4 字节大端长度（含头）+ 4 字节类型 + 载荷。
fn tw_box(kind : Bytes, payload : Bytes) -> Bytes {
  let n = 8 + payload.length()
  Bytes::from_array([
    ((n >> 24) & 0xFF).to_byte(),
    ((n >> 16) & 0xFF).to_byte(),
    ((n >> 8) & 0xFF).to_byte(),
    (n & 0xFF).to_byte(),
  ])
  .add(kind)
  .add(payload)
}

///|
/// 最简 M4A 骨架：ftyp + moov/udta/meta(FullBox)/hdlr + mdat。
/// 没有 ilst —— 覆盖"从零新建整条路径"那条分支。
fn tw_m4a() -> Bytes {
  let ftyp = tw_box(
    Bytes::from_array([0x66, 0x74, 0x79, 0x70]),
    Bytes::from_array([
      0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D, 0x4D, 0x34, 0x41, 0x20,
    ]),
  )
  let hdlr = tw_box(
    Bytes::from_array([0x68, 0x64, 0x6C, 0x72]),
    Bytes::make(24, 0x00),
  )
  let meta = tw_box(
    Bytes::from_array([0x6D, 0x65, 0x74, 0x61]),
    Bytes::make(4, 0x00).add(hdlr),
  )
  let udta = tw_box(Bytes::from_array([0x75, 0x64, 0x74, 0x61]), meta)
  let moov = tw_box(Bytes::from_array([0x6D, 0x6F, 0x6F, 0x76]), udta)
  let mdat = tw_box(
    Bytes::from_array([0x6D, 0x64, 0x61, 0x74]),
    Bytes::make(64, 0xAA),
  )
  ftyp.add(moov).add(mdat)
}

///|
test "tagwrite：mp3 往返——写入后可读回，音频字节原样保留" {
  let audio = tw_mp3_audio(32)
  let (out, r) = cm_write_tags(audio, "晴天", "周杰伦", "叶惠美")
  assert_true(r is Written)
  let tag = @lunamusic-tag.parse(out.exact_view())
  assert_eq(tag.text("TIT2") catch { _ => None }, Some("晴天"))
  assert_eq(tag.text("TPE1") catch { _ => None }, Some("周杰伦"))
  assert_eq(tag.text("TALB") catch { _ => None }, Some("叶惠美"))
  // 音频段必须一位不差地留在标签之后
  for i in 0..<audio.length() {
    assert_eq(out.at(tag.total_size + i).to_int(), audio.at(i).to_int())
  }
}

///|
test "tagwrite：mp3 清空字段 = 删除标签" {
  let audio = tw_mp3_audio(16)
  let (first, r1) = cm_write_tags(audio, "有标题", "有歌手", "有专辑")
  assert_true(r1 is Written)
  let (second, r2) = cm_write_tags(first, "", "", "")
  assert_true(r2 is Written)
  let tag = @lunamusic-tag.parse(second.exact_view())
  assert_eq(tag.text("TIT2") catch { _ => None }, None)
  assert_eq(tag.text("TPE1") catch { _ => None }, None)
  assert_eq(tag.text("TALB") catch { _ => None }, None)
}

///|
test "tagwrite：flac 往返——Vorbis Comment 写入后可读回" {
  let (out, r) = cm_write_tags(tw_flac(), "轻音乐", "某乐团", "合集")
  assert_true(r is Written)
  let vc = @lunamusic-tag.read_vorbis_comment(out.exact_view()).unwrap()
  assert_eq(vc.get("TITLE"), Some("轻音乐"))
  assert_eq(vc.get("ARTIST"), Some("某乐团"))
  assert_eq(vc.get("ALBUM"), Some("合集"))
}

///|
test "tagwrite：flac 清空字段 = 删除键" {
  let (first, _) = cm_write_tags(tw_flac(), "A", "B", "C")
  let (second, r) = cm_write_tags(first, "", "", "")
  assert_true(r is Written)
  let vc = @lunamusic-tag.read_vorbis_comment(second.exact_view()).unwrap()
  assert_eq(vc.get("TITLE"), None)
  assert_eq(vc.get("ARTIST"), None)
  assert_eq(vc.get("ALBUM"), None)
}

///|
test "tagwrite：m4a 往返——从零新建 ilst 后可读回" {
  let (out, r) = cm_write_tags(tw_m4a(), "标题", "艺术家", "专辑")
  assert_true(r is Written)
  let entries = @lunamusic-tag.read_mp4_tags(out.exact_view())
  assert_eq(@lunamusic-tag.text_of(entries, "©nam"), Some("标题"))
  assert_eq(@lunamusic-tag.text_of(entries, "©ART"), Some("艺术家"))
  assert_eq(@lunamusic-tag.text_of(entries, "©alb"), Some("专辑"))
}

///|
test "tagwrite：m4a 清空字段 = 删除条目" {
  let (first, _) = cm_write_tags(tw_m4a(), "T", "A", "L")
  let (second, r) = cm_write_tags(first, "", "", "")
  assert_true(r is Written)
  let entries = @lunamusic-tag.read_mp4_tags(second.exact_view())
  assert_eq(@lunamusic-tag.text_of(entries, "©nam"), None)
  assert_eq(@lunamusic-tag.text_of(entries, "©ART"), None)
  assert_eq(@lunamusic-tag.text_of(entries, "©alb"), None)
}

///|
test "tagwrite：未知格式报 UnsupportedFormat 且返回原字节" {
  let riff = Bytes::from_array([0x52, 0x49, 0x46, 0x46]).add(
    Bytes::make(40, 0x00),
  )
  let (out, r) = cm_write_tags(riff, "t", "a", "al")
  assert_true(r is UnsupportedFormat)
  assert_eq(out.length(), riff.length())
  for i in 0..<riff.length() {
    assert_eq(out.at(i).to_int(), riff.at(i).to_int())
  }
}

///|
test "tagwrite：坏 Ogg（不是 Vorbis/Opus）报 Failed，不崩不写" {
  // OggS 页头 + 一段凑不出来的载荷：read_ogg_comment 返回 None。
  let ogg = Bytes::from_array([0x4F, 0x67, 0x67, 0x53]).add(
    Bytes::make(40, 0x00),
  )
  let (out, r) = cm_write_tags(ogg, "t", "a", "al")
  assert_true(r is Failed(_))
  assert_eq(out.length(), ogg.length())
}
