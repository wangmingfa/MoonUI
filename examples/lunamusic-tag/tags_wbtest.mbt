// tags_wbtest.mbt
//
// F7 判据：格式自动识别。
//
// vendored 自 cp15695540483/moontag@0.1.1 的 tags_wbtest.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE；本仓库只改下述范围：
//   - 只保留 detect_format 与 AudioFormat::name 的判据
//   - 删除全部"统一视图"测试（依赖 read_track_info / TrackInfo 与 APEv2，
//     这两个本仓库没有取用，见 tags.mbt 的文件头）

///|
test "F7 格式识别：FLAC 魔数" {
  let file = tb_flac([(0, tb_streaminfo())], Bytes::make(10, 0xAA))
  @test.assert_eq(detect_format(file.exact_view()) is Flac, true)
}

///|
test "F7 格式识别：MP4 ftyp" {
  let file = tb_box(
    "ftyp",
    Bytes::from_array([
      0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D, 0x4D, 0x34, 0x41, 0x20,
    ]),
  )
  @test.assert_eq(detect_format(file.exact_view()) is Mp4, true)
}

///|
test "F7 格式识别：ID3v2 前缀" {
  let file = tb_tag(
    4,
    0,
    [tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode("T")))],
    0,
  )
  @test.assert_eq(detect_format(file.exact_view()) is Mp3, true)
}

///|
test "F7 格式识别：MP3 帧同步（无 ID3 标签）" {
  let file = Bytes::from_array([0xFF, 0xFB, 0x90, 0x00, 0x11, 0x22])
  @test.assert_eq(detect_format(file.exact_view()) is Mp3, true)
}

///|
test "F7 格式识别：无法识别返回 Unknown" {
  let file = Bytes::make(20, 0x00)
  @test.assert_eq(detect_format(file.exact_view()) is Unknown, true)
}

///|
test "F7 格式识别：OggS 魔数" {
  let file = Bytes::from_array([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02]).add(
    Bytes::make(20, 0x00),
  )
  @test.assert_eq(detect_format(file.exact_view()) is Ogg, true)
}

///|
test "F7 统一视图：Ogg 的格式名可读" {
  @test.assert_eq(AudioFormat::Ogg.name(), "Ogg / Vorbis Comment")
}
