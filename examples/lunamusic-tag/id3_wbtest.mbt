// id3_wbtest.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 id3_wbtest.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE。测试原样保留（未裁剪），
// 裁剪清单与上游出处见本目录 README.md。
//
// F1 判据：ID3v2 标签头与帧遍历、四种文本编码、unsynchronisation、
// 两个版本的尺寸语义差异，以及各类非法输入的报错类型。
//
// 测试标签用 tb_* 手工拼装，不依赖任何外部文件，各后端都能跑。

///|
/// synchsafe 32 位整数 → 4 字节数组。
fn tb_synchsafe(v : Int32) -> Array[Byte] {
  [
    ((v >> 21) & 0x7F).to_byte(),
    ((v >> 14) & 0x7F).to_byte(),
    ((v >> 7) & 0x7F).to_byte(),
    (v & 0x7F).to_byte(),
  ]
}

///|
/// 普通大端 u32 → 4 字节数组。
fn tb_u32be(v : Int32) -> Array[Byte] {
  [
    ((v >> 24) & 0xFF).to_byte(),
    ((v >> 16) & 0xFF).to_byte(),
    ((v >> 8) & 0xFF).to_byte(),
    (v & 0xFF).to_byte(),
  ]
}

///|
/// 按 synchsafe 写 4 字节（ID3v2.4 尺寸字段）。
fn tb_put_synchsafe(buf : @buffer.Buffer, v : Int32) -> Unit {
  for b in tb_synchsafe(v) {
    buf.write_byte(b)
  }
}

///|
/// 拼标签：头（声明尺寸=body 实际长度）+ body。
fn tb_tag_body(major : Int32, flags : Int32, body : Bytes) -> Bytes {
  let out = @buffer.Buffer()
  out.write_byte(b'I')
  out.write_byte(b'D')
  out.write_byte(b'3')
  out.write_byte(major.to_byte())
  out.write_byte(b'\x00')
  out.write_byte(flags.to_byte())
  for b in tb_synchsafe(body.length()) {
    out.write_byte(b)
  }
  out.write_bytes(body)
  out.to_bytes()
}

///|
/// 拼标签：头 + 若干帧 + padding。
fn tb_tag(
  major : Int32,
  flags : Int32,
  frames : Array[Bytes],
  padding : Int32,
) -> Bytes {
  let body = @buffer.Buffer()
  for f in frames {
    body.write_bytes(f)
  }
  for _ in 0..<padding {
    body.write_byte(b'\x00')
  }
  tb_tag_body(major, flags, body.to_bytes())
}

///|
/// 拼一个帧：尺寸编码按版本（v2.3 普通 u32，v2.4 synchsafe）。
fn tb_frame_with_size(
  major : Int32,
  id : String,
  format_flags : Int32,
  declared_size : Int32,
  payload : Bytes,
) -> Bytes {
  let out = @buffer.Buffer()
  for c in id {
    out.write_byte(c.to_int().to_byte())
  }
  if major == 4 {
    tb_put_synchsafe(out, declared_size)
  } else {
    for b in tb_u32be(declared_size) {
      out.write_byte(b)
    }
  }
  out.write_byte(b'\x00')
  out.write_byte(format_flags.to_byte())
  out.write_bytes(payload)
  out.to_bytes()
}

///|
/// 拼一个帧（声明尺寸 = 载荷长度）。
fn tb_frame(
  major : Int32,
  id : String,
  format_flags : Int32,
  payload : Bytes,
) -> Bytes {
  tb_frame_with_size(major, id, format_flags, payload.length(), payload)
}

///|
/// 文本帧载荷：编码字节 + 文本字节。
fn tb_text(enc : Int32, text : Bytes) -> Bytes {
  let out = @buffer.Buffer()
  out.write_byte(enc.to_byte())
  out.write_bytes(text)
  out.to_bytes()
}

///|
/// 拼标签并取某帧文本；帧不存在则 abort。
fn tb_text_of(data : Bytes, id : String) -> String raise TagError {
  let tag = parse(data.exact_view())
  match tag.text(id) {
    Some(t) => t
    None => abort("帧 \{id} 不存在")
  }
}

///|
test "v2.4 标签头：版本、帧数、标签总长（含 padding）" {
  let frames = [tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode("Hello")))]
  let data = tb_tag(4, 0, frames, 10)
  let tag = parse(data.exact_view())
  @test.assert_eq(tag.major, 4)
  @test.assert_eq(tag.revision, 0)
  @test.assert_eq(tag.frames.length(), 1)
  // 10 字节头 + 帧(10 + 6) + padding 10
  @test.assert_eq(tag.total_size, 10 + 16 + 10)
  @test.assert_eq(tb_text_of(data, "TIT2"), "Hello")
}

///|
test "v2.4 帧尺寸是 synchsafe：200 字节帧不被读成越界" {
  // 若把 synchsafe 误当普通 u32，尺寸会变成 200<<7 量级并立刻越界。
  let long = Bytes::make(200, b'A')
  let frames = [tb_frame(4, "TIT2", 0, tb_text(3, long))]
  let tag = parse(tb_tag(4, 0, frames, 0).exact_view())
  @test.assert_eq(tag.frames[0].data.length(), 201)
  @test.assert_eq(tag.frames[0].id, "TIT2")
}

///|
test "v2.3 帧尺寸是普通 u32（与 v2.4 语义不同）" {
  let long = Bytes::make(200, b'B')
  let frames = [tb_frame(3, "TIT2", 0, tb_text(0, long))]
  let tag = parse(tb_tag(3, 0, frames, 0).exact_view())
  @test.assert_eq(tag.major, 3)
  @test.assert_eq(tag.frames[0].data.length(), 201)
}

///|
test "多帧顺序与二元帧跳过" {
  let apic = Bytes::from_array([0x00, 0x69, 0x6D, 0x67, 0x01, 0x00])
  let frames = [
    tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode("T"))),
    tb_frame(4, "APIC", 0, apic),
    tb_frame(4, "TPE1", 0, tb_text(3, @utf8.encode("A"))),
  ]
  let tag = parse(tb_tag(4, 0, frames, 0).exact_view())
  @test.assert_eq(tag.frames.length(), 3)
  @test.assert_eq(tag.frames[0].id, "TIT2")
  @test.assert_eq(tag.frames[1].id, "APIC")
  @test.assert_eq(tag.frames[2].id, "TPE1")
  // APIC 不是文本帧：as_text 返回 None
  @test.assert_eq(tag.frames[1].as_text() is None, true)
}

///|
test "文本编码 $00 ISO-8859-1：高位字节按码点直译" {
  let payload = tb_text(0, Bytes::from_array([0x41, 0xE9, 0xFF]))
  let s = tb_text_of(tb_tag(4, 0, [tb_frame(4, "TIT2", 0, payload)], 0), "TIT2")
  @test.assert_eq(s.length(), 3)
  @test.assert_eq(s.at(0).to_int(), 0x41)
  @test.assert_eq(s.at(1).to_int(), 0xE9)
  @test.assert_eq(s.at(2).to_int(), 0xFF)
}

///|
test "文本编码 $01 UTF-16LE（带 BOM）" {
  let payload = tb_text(
    1,
    Bytes::from_array([0xFF, 0xFE, 0x2D, 0x4E, 0x87, 0x65]),
  )
  let s = tb_text_of(tb_tag(4, 0, [tb_frame(4, "TIT2", 0, payload)], 0), "TIT2")
  // U+4E2D 中、U+6587 文
  @test.assert_eq(s.length(), 2)
  @test.assert_eq(s.at(0).to_int(), 0x4E2D)
  @test.assert_eq(s.at(1).to_int(), 0x6587)
}

///|
test "文本编码 $01 UTF-16BE（带 BOM，字节序由 BOM 决定）" {
  let payload = tb_text(
    1,
    Bytes::from_array([0xFE, 0xFF, 0x4E, 0x2D, 0x65, 0x87]),
  )
  let s = tb_text_of(tb_tag(4, 0, [tb_frame(4, "TIT2", 0, payload)], 0), "TIT2")
  @test.assert_eq(s.at(0).to_int(), 0x4E2D)
  @test.assert_eq(s.at(1).to_int(), 0x6587)
}

///|
test "文本编码 $02 UTF-16BE（无 BOM）" {
  let payload = tb_text(2, Bytes::from_array([0x00, 0x41, 0x00, 0x42]))
  @test.assert_eq(
    tb_text_of(tb_tag(4, 0, [tb_frame(4, "TIT2", 0, payload)], 0), "TIT2"),
    "AB",
  )
}

///|
test "文本编码 $03 UTF-8" {
  let payload = tb_text(3, @utf8.encode("中文"))
  @test.assert_eq(
    tb_text_of(tb_tag(4, 0, [tb_frame(4, "TIT2", 0, payload)], 0), "TIT2"),
    "中文",
  )
}

///|
test "终止符之后的内容不再属于同一个字符串" {
  // "A\0B"：v2.4 允许多值，但 text() 只取第一个
  let payload = tb_text(3, Bytes::from_array([0x41, 0x00, 0x42]))
  @test.assert_eq(
    tb_text_of(tb_tag(4, 0, [tb_frame(4, "TIT2", 0, payload)], 0), "TIT2"),
    "A",
  )
}

///|
test "v2.4 帧级 unsynchronisation：FF 00 还原为 FF" {
  // 磁盘上是 FF 00 E0（伪同步被插入 00），还原后应为 FF E0
  let raw = Bytes::from_array([0x00, 0xFF, 0x00, 0xE0, 0x41])
  let frames = [tb_frame(4, "APIC", 0x02, raw)]
  let tag = parse(tb_tag(4, 0, frames, 0).exact_view())
  let d = tag.frames[0].data
  @test.assert_eq(d.length(), 4)
  @test.assert_eq(d.at(0).to_int(), 0x00)
  @test.assert_eq(d.at(1).to_int(), 0xFF)
  @test.assert_eq(d.at(2).to_int(), 0xE0)
  @test.assert_eq(d.at(3).to_int(), 0x41)
}

///|
test "v2.4 标签级 unsync 标志让所有帧都被还原" {
  let raw = Bytes::from_array([0x00, 0xFF, 0x00, 0xE0])
  let frames = [tb_frame(4, "APIC", 0x00, raw)]
  let tag = parse(tb_tag(4, 0x80, frames, 0).exact_view())
  let d = tag.frames[0].data
  @test.assert_eq(d.length(), 3)
  @test.assert_eq(d.at(1).to_int(), 0xFF)
  @test.assert_eq(d.at(2).to_int(), 0xE0)
}

///|
test "v2.4 扩展头跳过" {
  // 扩展头：synchsafe 尺寸 6（含自身）+ flag 字节数 1 + flags 0
  let ext = Bytes::from_array([0x00, 0x00, 0x00, 0x06, 0x01, 0x00])
  let frame = tb_frame(4, "TPE1", 0, tb_text(3, @utf8.encode("Y")))
  let tag = parse(tb_tag(4, 0x40, [ext.add(frame)], 0).exact_view())
  @test.assert_eq(tag.frames.length(), 1)
  @test.assert_eq(tag.frames[0].id, "TPE1")
}

///|
test "v2.3 扩展头（尺寸不含自身，6 字节）跳过" {
  // 4 字节尺寸=6 + 2 字节 flags + 4 字节 padding 尺寸
  let ext = Bytes::from_array([
    0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ])
  let frame = tb_frame(3, "TIT2", 0, tb_text(0, @utf8.encode("Z")))
  let tag = parse(tb_tag(3, 0x40, [ext.add(frame)], 0).exact_view())
  @test.assert_eq(tag.frames.length(), 1)
  @test.assert_eq(tag.frames[0].id, "TIT2")
}

///|
test "负例：数据不足 10 字节报 Truncated" {
  try {
    let _ = parse(Bytes::from_array([0x49, 0x44, 0x33]).exact_view())
    abort("应当 Truncated")
  } catch {
    TagError::Truncated(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "负例：不是 ID3 标签报 NotTagged" {
  let data = Bytes::make(100, b'X')
  try {
    let _ = parse(data.exact_view())
    abort("应当 NotTagged")
  } catch {
    TagError::NotTagged(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "负例：版本 2 与 5 报 UnsupportedVersion" {
  for v in [2, 5] {
    let data = Bytes::from_array([
      0x49,
      0x44,
      0x33,
      v.to_byte(),
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
    ])
    try {
      let _ = parse(data.exact_view())
      abort("版本 \{v} 应当 UnsupportedVersion")
    } catch {
      TagError::UnsupportedVersion(version~) => @test.assert_eq(version, v)
      _ => abort("错误类型不对")
    }
  }
}

///|
test "负例：标签体被截断报 Truncated" {
  // 头声明 1000 字节标签体，实际只给 10 字节
  let header = Bytes::from_array([
    0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x07, 0x68,
  ])
  try {
    let _ = parse(header.exact_view())
    abort("应当 Truncated")
  } catch {
    TagError::Truncated(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "负例：帧声明尺寸超出标签体报 FrameOutOfBounds" {
  let payload = Bytes::make(5, b'A')
  // 帧头声明 500 字节，实际载荷只有 5 字节
  let frame = tb_frame_with_size(4, "TIT2", 0, 500, payload)
  let data = tb_tag(4, 0, [frame], 0)
  try {
    let _ = parse(data.exact_view())
    abort("应当 FrameOutOfBounds")
  } catch {
    TagError::FrameOutOfBounds(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "负例：synchsafe 字段最高位非 0 报 BadHeader" {
  let data = Bytes::from_array([
    0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00,
  ])
  try {
    let _ = parse(data.exact_view())
    abort("应当 BadHeader")
  } catch {
    TagError::BadHeader(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "padding 之后不再解析帧" {
  let f1 = tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode("A")))
  let tag = parse(tb_tag(4, 0, [f1], 32).exact_view())
  @test.assert_eq(tag.frames.length(), 1)
  @test.assert_eq(tag.frames[0].id, "TIT2")
  // 标签总长应覆盖 padding
  @test.assert_eq(tag.total_size, 10 + 10 + 2 + 32)
}
