// vorbis_wbtest.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 vorbis_wbtest.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE。测试原样保留（未裁剪），
// 裁剪清单与上游出处见本目录 README.md。
//
// F4 判据：Vorbis Comment 的解析/序列化、FLAC 块链遍历、padding 复用。

///|
/// 拼一个小端 u32。
fn tb_le32(v : Int32) -> Array[Byte] {
  [
    (v & 0xFF).to_byte(),
    ((v >> 8) & 0xFF).to_byte(),
    ((v >> 16) & 0xFF).to_byte(),
    ((v >> 24) & 0xFF).to_byte(),
  ]
}

///|
/// 拼 Vorbis Comment 载荷。
fn tb_vc(vendor : String, entries : Array[String]) -> Bytes {
  let buf = @buffer.Buffer()
  let vb = @utf8.encode(vendor)
  for b in tb_le32(vb.length()) {
    buf.write_byte(b)
  }
  buf.write_bytes(vb)
  for b in tb_le32(entries.length()) {
    buf.write_byte(b)
  }
  for e in entries {
    let eb = @utf8.encode(e)
    for b in tb_le32(eb.length()) {
      buf.write_byte(b)
    }
    buf.write_bytes(eb)
  }
  buf.to_bytes()
}

///|
/// 拼一个 FLAC 元数据块头。
fn tb_block_header(code : Int32, len : Int32, is_last : Bool) -> Bytes {
  let first = if is_last { 0x80 | code } else { code }
  Bytes::from_array([
    first.to_byte(),
    ((len >> 16) & 0xFF).to_byte(),
    ((len >> 8) & 0xFF).to_byte(),
    (len & 0xFF).to_byte(),
  ])
}

///|
/// 拼一个 FLAC 文件：魔数 + 块链 + 音频。
///
/// `blocks` 的最后一块自动置 last 位。
fn tb_flac(blocks : Array[(Int32, Bytes)], audio : Bytes) -> Bytes {
  let out = @buffer.Buffer()
  out.write_bytes(Bytes::from_array([0x66, 0x4C, 0x61, 0x43]))
  for i, pair in blocks {
    let (code, payload) = pair
    out.write_bytes(
      tb_block_header(code, payload.length(), i == blocks.length() - 1),
    )
    out.write_bytes(payload)
  }
  out.write_bytes(audio)
  out.to_bytes()
}

///|
/// 最小 STREAMINFO 载荷（34 字节，内容对标签逻辑不重要）。
fn tb_streaminfo() -> Bytes {
  Bytes::make(34, 0x11)
}

///|
test "F4 解析 Vorbis Comment：vendor、条目顺序与大小写保持" {
  let payload = tb_vc("TestVendor 1.0", [
    "title=Song", "ARTIST=Someone", "artist=Another",
  ])
  let vc = parse_vorbis_comment(payload.exact_view())
  @test.assert_eq(vc.vendor, "TestVendor 1.0")
  @test.assert_eq(vc.entries.length(), 3)
  @test.assert_eq(vc.entries[0], "title=Song")
  @test.assert_eq(vc.entries[1], "ARTIST=Someone")
  @test.assert_eq(vc.entries[2], "artist=Another")
}

///|
test "F4 get 不区分 ASCII 大小写，返回靠前的一个" {
  let vc = parse_vorbis_comment(
    tb_vc("v", ["TITLE=First", "title=Second"]).exact_view(),
  )
  @test.assert_eq(vc.get("title"), Some("First"))
  @test.assert_eq(vc.get("TITLE"), Some("First"))
  @test.assert_eq(vc.get("TiTlE"), Some("First"))
  @test.assert_eq(vc.get("album") is None, true)
}

///|
test "F4 get_all 保留全部同 key 条目与顺序" {
  let vc = parse_vorbis_comment(
    tb_vc("v", ["ARTIST=A", "ARTIST=B", "ARTIST=C"]).exact_view(),
  )
  let all = vc.get_all("artist")
  @test.assert_eq(all.length(), 3)
  @test.assert_eq(all[0], "A")
  @test.assert_eq(all[1], "B")
  @test.assert_eq(all[2], "C")
}

///|
test "F4 含中文与 = 号的值" {
  let vc = parse_vorbis_comment(
    tb_vc("v", ["TITLE=中文标题", "COMMENT=a=b=c"]).exact_view(),
  )
  @test.assert_eq(vc.get("title"), Some("中文标题"))
  // 值里的 '=' 必须完整保留（按第一个 '=' 切分）
  @test.assert_eq(vc.get("comment"), Some("a=b=c"))
}

///|
test "F4 set_key 替换已有 key 并把 KEY 转大写" {
  let vc = parse_vorbis_comment(
    tb_vc("v", ["title=Old", "ARTIST=A"]).exact_view(),
  )
  let vc2 = vc.set_key("Title", "New")
  @test.assert_eq(vc2.get("title"), Some("New"))
  @test.assert_eq(vc2.get_all("title").length(), 1)
  @test.assert_eq(vc2.get("artist"), Some("A"))
  // 写入时统一大写
  let mut found = false
  for e in vc2.entries {
    if e == "TITLE=New" {
      found = true
    }
  }
  @test.assert_eq(found, true)
}

///|
test "F4 set_key 空值表示删除" {
  let vc = parse_vorbis_comment(
    tb_vc("v", ["title=Old", "ARTIST=A"]).exact_view(),
  )
  let vc2 = vc.set_key("title", "")
  @test.assert_eq(vc2.get("title") is None, true)
  @test.assert_eq(vc2.get("artist"), Some("A"))
}

///|
test "F4 负例：非法 KEY（含 =、非 ASCII、空）被拒绝" {
  let vc = empty_vorbis_comment("v")
  for bad in ["", "A=B", "中文"] {
    try {
      let _ = vc.set_key(bad, "x")
      abort("KEY {bad} 应当被拒绝")
    } catch {
      TagError::BadFrameData(..) => ()
      _ => abort("错误类型不对")
    }
  }
}

///|
test "F4 序列化后再解析：round-trip 一致" {
  let vc = empty_vorbis_comment("moontag 0.1")
  let vc2 = vc.set_key("TITLE", "标题").set_key("ARTIST", "歌手")
  let bytes = serialize_vorbis_comment(vc2)
  let back = parse_vorbis_comment(bytes.exact_view())
  @test.assert_eq(back.vendor, "moontag 0.1")
  @test.assert_eq(back.get("title"), Some("标题"))
  @test.assert_eq(back.get("artist"), Some("歌手"))
}

///|
test "F4 负例：载荷不足 8 字节报 BadFrameData" {
  try {
    let _ = parse_vorbis_comment(Bytes::from_array([0x01, 0x00]).exact_view())
    abort("应当报错")
  } catch {
    TagError::BadFrameData(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "F4 负例：条目长度超出载荷报 Truncated" {
  // vendor 长度 0、count 1、条目声明 100 字节但只有 2
  let buf = @buffer.Buffer()
  for b in tb_le32(0) {
    buf.write_byte(b)
  }
  for b in tb_le32(1) {
    buf.write_byte(b)
  }
  for b in tb_le32(100) {
    buf.write_byte(b)
  }
  buf.write_byte(b'A')
  buf.write_byte(b'B')
  try {
    let _ = parse_vorbis_comment(buf.to_bytes().exact_view())
    abort("应当报错")
  } catch {
    TagError::Truncated(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "F4 FLAC 块链遍历：类型与偏移" {
  let vc_payload = tb_vc("v", ["TITLE=T"])
  let padding = Bytes::make(64, 0x00)
  let audio = Bytes::make(100, 0xAA)
  let file = tb_flac(
    [(0, tb_streaminfo()), (4, vc_payload), (1, padding)],
    audio,
  )
  let meta = parse_meta(file.exact_view())
  @test.assert_eq(meta.blocks.length(), 3)
  @test.assert_eq(meta.blocks[0].code, 0)
  @test.assert_eq(meta.blocks[0].length, 34)
  @test.assert_eq(meta.blocks[1].code, 4)
  @test.assert_eq(meta.blocks[2].code, 1)
  @test.assert_eq(meta.blocks[2].is_last, true)
  // 音频起点 = 4 + (4+34) + (4+vc) + (4+64)
  @test.assert_eq(meta.audio_offset, 4 + 38 + 4 + vc_payload.length() + 68)
  @test.assert_eq(file.length() - meta.audio_offset, 100)
}

///|
test "F4 保留类型块（7..126）跳过而不报错" {
  let file = tb_flac(
    [
      (0, tb_streaminfo()),
      (42, Bytes::make(8, 0xFF)),
      (4, tb_vc("v", ["TITLE=T"])),
    ],
    Bytes::make(10, 0xAA),
  )
  let meta = parse_meta(file.exact_view())
  @test.assert_eq(meta.blocks.length(), 3)
  @test.assert_eq(meta.blocks[1].code, 42)
  // 保留块不影响 Vorbis Comment 读取
  let vc = read_vorbis_comment(file.exact_view())
  @test.assert_eq(
    match vc {
      Some(c) => c.get("title")
      None => None
    },
    Some("T"),
  )
}

///|
test "F4 负例：类型 127 报 BadHeader" {
  let mut file = Bytes::from_array([0x66, 0x4C, 0x61, 0x43])
  file = file.add(tb_block_header(127, 0, true))
  try {
    let _ = parse_meta(file.exact_view())
    abort("应当报错")
  } catch {
    TagError::BadHeader(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "F4 负例：不是 FLAC 报 NotTagged" {
  try {
    let _ = parse_meta(Bytes::make(20, b'X').exact_view())
    abort("应当报错")
  } catch {
    TagError::NotTagged(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "F4 负例：块长度超出文件报 Truncated" {
  // 声明 1000 字节块，实际只给 10
  let mut file = Bytes::from_array([0x66, 0x4C, 0x61, 0x43])
  file = file.add(tb_block_header(0, 1000, true))
  file = file.add(Bytes::make(10, 0x11))
  try {
    let _ = parse_meta(file.exact_view())
    abort("应当报错")
  } catch {
    TagError::Truncated(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "F4 写入复用 padding：文件总长不变、音频字节不动" {
  let audio = Bytes::make(200, 0xAA)
  let file = tb_flac(
    [
      (0, tb_streaminfo()),
      (4, tb_vc("v", ["TITLE=Old"])),
      (1, Bytes::make(512, 0x00)),
    ],
    audio,
  )
  let vc = read_vorbis_comment(file.exact_view()).unwrap()
  let vc2 = vc.set_key("TITLE", "标题长一点点")
  let out = set_vorbis_comment(file.exact_view(), vc2)
  @test.assert_eq(out.length(), file.length())
  // 音频字节必须原样
  let meta_before = parse_meta(file.exact_view())
  let meta_after = parse_meta(out.exact_view())
  @test.assert_eq(meta_after.audio_offset, meta_before.audio_offset)
  for i in 0..<audio.length() {
    @test.assert_eq(
      out.at(meta_after.audio_offset + i).to_int(),
      audio.at(i).to_int(),
    )
  }
}

///|
test "F4 写入后能读回新值" {
  let file = tb_flac(
    [
      (0, tb_streaminfo()),
      (4, tb_vc("v", ["TITLE=Old"])),
      (1, Bytes::make(128, 0x00)),
    ],
    Bytes::make(50, 0xAA),
  )
  let vc = read_vorbis_comment(file.exact_view()).unwrap()
  let out = set_vorbis_comment(
    file.exact_view(),
    vc.set_key("TITLE", "New").set_key("ALBUM", "Alb"),
  )
  let back = read_vorbis_comment(out.exact_view()).unwrap()
  @test.assert_eq(back.get("title"), Some("New"))
  @test.assert_eq(back.get("album"), Some("Alb"))
}

///|
test "F4 原文件没有 COMMENT 块时插入到 STREAMINFO 之后" {
  let file = tb_flac(
    [(0, tb_streaminfo()), (1, Bytes::make(256, 0x00))],
    Bytes::make(50, 0xAA),
  )
  let out = set_vorbis_comment(
    file.exact_view(),
    empty_vorbis_comment("moontag").set_key("TITLE", "插入"),
  )
  let meta = parse_meta(out.exact_view())
  @test.assert_eq(meta.blocks.length(), 3)
  @test.assert_eq(meta.blocks[0].code, 0)
  @test.assert_eq(meta.blocks[1].code, 4)
  @test.assert_eq(meta.blocks[2].code, 1)
  let back = read_vorbis_comment(out.exact_view()).unwrap()
  @test.assert_eq(back.get("title"), Some("插入"))
}

///|
test "F4 多值 ARTIST 写入后仍保持多值" {
  let file = tb_flac(
    [
      (0, tb_streaminfo()),
      (4, tb_vc("v", ["ARTIST=A", "ARTIST=B"])),
      (1, Bytes::make(128, 0x00)),
    ],
    Bytes::make(20, 0xAA),
  )
  let vc = read_vorbis_comment(file.exact_view()).unwrap()
  @test.assert_eq(vc.get_all("artist").length(), 2)
  // 改写其他字段不应影响多值
  let out = set_vorbis_comment(file.exact_view(), vc.set_key("TITLE", "T"))
  let back = read_vorbis_comment(out.exact_view()).unwrap()
  let artists = back.get_all("artist")
  @test.assert_eq(artists.length(), 2)
  @test.assert_eq(artists[0], "A")
  @test.assert_eq(artists[1], "B")
}
