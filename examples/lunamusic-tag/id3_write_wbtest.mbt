// id3_write_wbtest.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 id3_write_wbtest.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE。测试原样保留（未裁剪），
// 裁剪清单与上游出处见本目录 README.md。
//
// F2 判据：写入后的标签必须能被自己读回（round-trip），
// 且两个版本的尺寸/编码语义都不能混用。

///|
/// 造一个"标签 + 假音频"的完整文件：音频用可识别的字节填充，
/// 便于检查写入时音频是否被原样保留。
fn tb_file(tag_bytes : Bytes, audio_len : Int32) -> Bytes {
  let audio = Bytes::make(audio_len, 0x55)
  tag_bytes.add(audio)
}

///|
/// 取某帧的文本；不存在返回 None。
fn tb_peek(data : Bytes, id : String) -> String? {
  let tag = parse(data.exact_view()) catch { _ => return None }
  tag.text(id) catch {
    _ => None
  }
}

///|
test "F2 无标签文件：新建 v2.4 标签并可读回" {
  let audio = Bytes::make(64, 0x55)
  let out = set_fields(
    audio.exact_view(),
    [field("TIT2", "New Title"), field("TPE1", "New Artist")],
    WriteOptions::default(),
  )
  @test.assert_eq(tb_peek(out, "TIT2"), Some("New Title"))
  @test.assert_eq(tb_peek(out, "TPE1"), Some("New Artist"))
  // 音频数据必须原样保留
  let tag = parse(out.exact_view())
  @test.assert_eq(out.length() - tag.total_size, 64)
  for i in tag.total_size..<out.length() {
    @test.assert_eq(out.at(i).to_int(), 0x55)
  }
}

///|
test "F2 v2.4：改写已有帧，版本不变" {
  let inner = tb_tag(
    4,
    0,
    [tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode("Old")))],
    16,
  )
  let file = tb_file(inner, 32)
  let out = set_fields(
    file.exact_view(),
    [field("TIT2", "Replaced")],
    WriteOptions::default(),
  )
  let tag = parse(out.exact_view())
  @test.assert_eq(tag.major, 4)
  @test.assert_eq(tb_peek(out, "TIT2"), Some("Replaced"))
}

///|
test "F2 v2.3：改写已有帧，版本保持 3 且用 UTF-16 编码" {
  let inner = tb_tag(
    3,
    0,
    [tb_frame(3, "TIT2", 0, tb_text(0, @utf8.encode("Old")))],
    16,
  )
  let file = tb_file(inner, 32)
  let out = set_fields(
    file.exact_view(),
    [field("TIT2", "中文标题")],
    WriteOptions::default(),
  )
  let tag = parse(out.exact_view())
  @test.assert_eq(tag.major, 3)
  // v2.3 不允许 UTF-8($03)，必须写成 UTF-16($01)
  let f = match tag.frame("TIT2") {
    Some(f) => f
    None => abort("无 TIT2")
  }
  @test.assert_eq(f.data.at(0).to_int(), 1)
  @test.assert_eq(tb_peek(out, "TIT2"), Some("中文标题"))
}

///|
test "F2 新增帧不影响已有帧" {
  let inner = tb_tag(
    4,
    0,
    [
      tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode("T"))),
      tb_frame(4, "TALB", 0, tb_text(3, @utf8.encode("Album"))),
    ],
    32,
  )
  let file = tb_file(inner, 16)
  let out = set_fields(
    file.exact_view(),
    [field("TPE1", "Artist")],
    WriteOptions::default(),
  )
  @test.assert_eq(tb_peek(out, "TIT2"), Some("T"))
  @test.assert_eq(tb_peek(out, "TALB"), Some("Album"))
  @test.assert_eq(tb_peek(out, "TPE1"), Some("Artist"))
}

///|
test "F2 空值表示删除该帧" {
  let inner = tb_tag(
    4,
    0,
    [
      tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode("T"))),
      tb_frame(4, "TALB", 0, tb_text(3, @utf8.encode("Album"))),
    ],
    16,
  )
  let file = tb_file(inner, 16)
  let out = set_fields(
    file.exact_view(),
    [field("TALB", "")],
    WriteOptions::default(),
  )
  @test.assert_eq(tb_peek(out, "TIT2"), Some("T"))
  @test.assert_eq(tb_peek(out, "TALB") is None, true)
}

///|
test "F2 未知帧（APIC 等）原样保留" {
  let apic_payload = Bytes::from_array([
    0x00, 0x69, 0x6D, 0x67, 0x00, 0x03, 0x00, 0xDE, 0xAD,
  ])
  let inner = tb_tag(
    4,
    0,
    [
      tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode("T"))),
      tb_frame(4, "APIC", 0, apic_payload),
    ],
    16,
  )
  let file = tb_file(inner, 16)
  let out = set_fields(
    file.exact_view(),
    [field("TIT2", "New")],
    WriteOptions::default(),
  )
  let tag = parse(out.exact_view())
  @test.assert_eq(tag.frames.length(), 2)
  let apic = match tag.frame("APIC") {
    Some(f) => f
    None => abort("APIC 被丢掉了")
  }
  @test.assert_eq(apic.data.length(), apic_payload.length())
  for i in 0..<apic_payload.length() {
    @test.assert_eq(apic.data.at(i).to_int(), apic_payload.at(i).to_int())
  }
}

///|
test "F2 padding 预算内原地复用：音频起点不变" {
  let inner = tb_tag(
    4,
    0,
    [tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode("A")))],
    200,
  )
  let file = tb_file(inner, 100)
  let before = parse(file.exact_view()).total_size
  // 新值比旧值长一点，但仍在 200 字节 padding 预算内
  let out = set_fields(
    file.exact_view(),
    [field("TIT2", "A longer title within padding")],
    WriteOptions::default(),
  )
  let after = parse(out.exact_view()).total_size
  @test.assert_eq(after, before)
  @test.assert_eq(out.length(), file.length())
  @test.assert_eq(tb_peek(out, "TIT2"), Some("A longer title within padding"))
}

///|
test "F2 padding 不够时标签增长，音频整体后移且内容不变" {
  let inner = tb_tag(
    4,
    0,
    [tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode("A")))],
    0,
  )
  let file = tb_file(inner, 50)
  let before = parse(file.exact_view()).total_size
  let out = set_fields(
    file.exact_view(),
    [field("TPE1", Bytes::make(300, b'X').to_unchecked_string())],
    WriteOptions::default(),
  )
  let after = parse(out.exact_view()).total_size
  @test.assert_eq(after > before, true)
  // 音频 50 字节 0x55 必须完整保留在末尾
  @test.assert_eq(out.length() - after, 50)
  for i in after..<out.length() {
    @test.assert_eq(out.at(i).to_int(), 0x55)
  }
}

///|
test "F2 round-trip：写入后再读回，所有保留帧与新增帧一致" {
  let inner = tb_tag(
    4,
    0,
    [
      tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode("Title"))),
      tb_frame(4, "TALB", 0, tb_text(3, @utf8.encode("Album"))),
      tb_frame(4, "APIC", 0, Bytes::from_array([0x00, 0x01])),
    ],
    64,
  )
  let file = tb_file(inner, 32)
  let out = set_fields(
    file.exact_view(),
    [field("TPE1", "Artist"), field("TALB", "New Album")],
    WriteOptions::default(),
  )
  let tag = parse(out.exact_view())
  @test.assert_eq(tag.frames.length(), 4)
  @test.assert_eq(tb_peek(out, "TIT2"), Some("Title"))
  @test.assert_eq(tb_peek(out, "TALB"), Some("New Album"))
  @test.assert_eq(tb_peek(out, "TPE1"), Some("Artist"))
  // 二次 round-trip：幂等（同样的输入再写一次，字节相同）
  let out2 = set_fields(
    out.exact_view(),
    [field("TPE1", "Artist"), field("TALB", "New Album")],
    WriteOptions::default(),
  )
  @test.assert_eq(out2.equal(out), true)
}

///|
test "F2 负例：帧 ID 不是 4 字符报错" {
  let file = Bytes::make(64, 0x55)
  try {
    let _ = set_fields(
      file.exact_view(),
      [field("TIT", "x")],
      WriteOptions::default(),
    )
    abort("应当报错")
  } catch {
    TagError::BadFrameHeader(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "F2 负例：非文本帧 ID 报 Unsupported" {
  let file = Bytes::make(64, 0x55)
  try {
    let _ = set_fields(
      file.exact_view(),
      [field("APIC", "x")],
      WriteOptions::default(),
    )
    abort("应当报错")
  } catch {
    TagError::Unsupported(..) => ()
    _ => abort("错误类型不对")
  }
}
