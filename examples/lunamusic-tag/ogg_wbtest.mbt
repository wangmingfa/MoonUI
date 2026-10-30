// ogg_wbtest.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 ogg_wbtest.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE。测试原样保留（未裁剪），
// 裁剪清单与上游出处见本目录 README.md。
//
// Ogg comment 读写判据：页解析、packet 重组、多 packet 分页、
// Vorbis 与 Opus 的魔数区分。

///|
/// 拼一个最小 Ogg 页（无 CRC 校验的读路径，写路径才校验）。
fn tb_ogg_page_raw(
  serial : Int32,
  seq : Int32,
  header_type : Int32,
  payload : Bytes,
) -> Bytes {
  make_page(serial, seq, header_type, 0L, payload)
}

///|
/// 拼一个最小 Vorbis 流：ident + comment + setup 三 packet。
fn tb_vorbis_stream(vendor : String, entries : Array[String]) -> Bytes {
  let ident = Bytes::from_array([0x01, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]).add(
    Bytes::from_array([
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]),
  )
  let comment = Bytes::from_array([0x03, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]).add(
    serialize_vorbis_comment({ vendor, entries, }),
  )
  let setup = Bytes::from_array([0x05, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]).add(
    Bytes::make(64, 0xAA),
  )
  let page0 = tb_ogg_page_raw(42, 0, 0x02, ident)
  let page1 = make_page_multi(42, 1, 0x00, 0L, [comment, setup])
  page0.add(page1)
}

///|
test "Ogg 页解析：头部字段与 lacing" {
  let page = tb_ogg_page_raw(42, 3, 0x02, Bytes::make(100, b'X'))
  let parsed = parse_page(page, 0)
  @test.assert_eq(parsed.serial, 42)
  @test.assert_eq(parsed.seq, 3)
  @test.assert_eq(parsed.is_bos, true)
  @test.assert_eq(parsed.n_segments, 1)
  @test.assert_eq(parsed.segment_len(0), 100)
  @test.assert_eq(parsed.total_len, 27 + 1 + 100)
}

///|
test "Ogg lacing：255 分段与尾段" {
  // 300 字节 payload → [255, 45]
  let payload = Bytes::make(300, b'Y')
  let page = make_page(1, 0, 0x00, 0L, payload)
  let parsed = parse_page(page, 0)
  @test.assert_eq(parsed.n_segments, 2)
  @test.assert_eq(parsed.segment_len(0), 255)
  @test.assert_eq(parsed.segment_len(1), 45)
}

///|
test "Ogg packet 重组：单页多段" {
  // 两个 packet：107 字节 + 64 字节，同页
  let p1 = Bytes::make(107, b'A')
  let p2 = Bytes::make(64, b'B')
  let page = make_page_multi(7, 0, 0x00, 0L, [p1, p2])
  let parsed = parse_page(page, 0)
  let packets = assemble_packets(page, [parsed])
  @test.assert_eq(packets.length(), 2)
  @test.assert_eq(packets[0].length(), 107)
  @test.assert_eq(packets[1].length(), 64)
  @test.assert_eq(packets[0].at(0).to_int(), 0x41)
  @test.assert_eq(packets[1].at(0).to_int(), 0x42)
}

///|
test "Ogg Vorbis comment 定位与解析" {
  let stream = tb_vorbis_stream("TestVendor", ["TITLE=歌", "ARTIST=手"])
  let loc = match read_ogg_comment(stream) {
    Some(l) => l
    None => abort("未定位到 comment")
  }
  @test.assert_eq(loc.is_opus, false)
  @test.assert_eq(loc.serial, 42)
  let vc = parse_ogg_comment_payload(loc)
  @test.assert_eq(vc.vendor, "TestVendor")
  @test.assert_eq(vc.get("title"), Some("歌"))
  @test.assert_eq(vc.get("artist"), Some("手"))
}

///|
test "Ogg Opus comment 定位（OpusTags 魔数）" {
  let ident = @utf8.encode("OpusHead").add(Bytes::make(11, 0x00))
  let comment = @utf8.encode("OpusTags").add(
    serialize_vorbis_comment(empty_vorbis_comment("v").set_key("TITLE", "歌")),
  )
  let page0 = tb_ogg_page_raw(9, 0, 0x02, ident)
  let page1 = tb_ogg_page_raw(9, 1, 0x00, comment)
  let stream = page0.add(page1)
  let loc = match read_ogg_comment(stream) {
    Some(l) => l
    None => abort("未定位到 Opus comment")
  }
  @test.assert_eq(loc.is_opus, true)
  let vc = parse_ogg_comment_payload(loc)
  @test.assert_eq(vc.get("title"), Some("歌"))
}

///|
test "Ogg 写入 round-trip：改 comment 后 setup 与音频保留" {
  let stream = tb_vorbis_stream("v", ["TITLE=旧"])
  let vc = match read_ogg_comment(stream) {
    Some(l) => parse_ogg_comment_payload(l)
    None => abort("未定位")
  }
  let out = set_ogg_comment(
    stream,
    vc.set_key("TITLE", "新标题").set_key("ALBUM", "专辑"),
  )
  // 读回
  let loc2 = match read_ogg_comment(out) {
    Some(l) => l
    None => abort("写后读不到")
  }
  let vc2 = parse_ogg_comment_payload(loc2)
  @test.assert_eq(vc2.get("title"), Some("新标题"))
  @test.assert_eq(vc2.get("album"), Some("专辑"))
  // setup 的 64 字节 0xAA 应在文件里
  @test.assert_eq(out.find(Bytes::make(64, 0xAA)) is Some(_), true)
}

///|
test "Ogg 负例：不是 Ogg 魔数" {
  try {
    let _ = parse_page(Bytes::make(40, b'X'), 0)
    abort("应当报错")
  } catch {
    TagError::NotTagged(..) => ()
    _ => abort("错误类型不对")
  }
}
