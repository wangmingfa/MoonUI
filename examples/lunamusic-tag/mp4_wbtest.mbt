// mp4_wbtest.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 mp4_wbtest.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE。测试原样保留（未裁剪），
// 裁剪清单与上游出处见本目录 README.md。
//
// F6 判据：MP4 盒树定位（尤其 meta 是 FullBox 的 +4 偏移）、
// ilst 条目解析、data 盒的 version/flags/type 布局、写入 round-trip、
// faststart 布局（moov 前置）的 stco/co64 偏移修正。

///|
/// 拼一个 MP4 盒（尺寸自动计算）。
///
/// 类型码按**原始字节**写：`©` 在 MP4 里是单字节 0xA9，不是 UTF-8 的 C2 A9。
fn tb_box_raw(kind_bytes : Bytes, payload : Bytes) -> Bytes {
  let total = payload.length() + 8
  let head = Bytes::from_array([
    ((total >> 24) & 0xFF).to_byte(),
    ((total >> 16) & 0xFF).to_byte(),
    ((total >> 8) & 0xFF).to_byte(),
    (total & 0xFF).to_byte(),
  ])
  head.add(kind_bytes).add(payload)
}

///|
/// 拼一个 ASCII 类型码的盒。
fn tb_box(kind : String, payload : Bytes) -> Bytes {
  tb_box_raw(@utf8.encode(kind), payload)
}

///|
/// 拼一个 ilst 条目。
///
/// 键名以 `©` 开头时（如 `©nam`）按 MP4 惯例写成单字节 0xA9 + 3 个 ASCII；
/// 其余键（如 `covr`、`trkn`）全部是 ASCII。
fn tb_ilst_entry(key : String, data_type : Int32, value : Bytes) -> Bytes {
  let data_payload = Bytes::from_array([
    0x00,
    0x00,
    0x00,
    data_type.to_byte(),
    0x00,
    0x00,
    0x00,
    0x00,
  ]).add(value)
  let key_bytes = if key.has_prefix("©") {
    let mut out = Bytes::from_array([0xA9])
    let mut n = 0
    for c in key {
      if n > 0 {
        out = out.add(Bytes::from_array([c.to_int().to_byte()]))
      }
      n += 1
    }
    out
  } else {
    @utf8.encode(key)
  }
  tb_box_raw(key_bytes, tb_box("data", data_payload))
}

///|
/// 拼一个含 ilst 的完整 M4A 结构。
fn tb_m4a(entries : Array[Bytes], extra_moov : Array[Bytes]) -> Bytes {
  let ilst_inner = @buffer.Buffer()
  for e in entries {
    ilst_inner.write_bytes(e)
  }
  let ilst = tb_box("ilst", ilst_inner.to_bytes())
  // meta 是 FullBox：4 字节 version/flags 之后才是子盒
  let hdlr = tb_box("hdlr", Bytes::make(24, 0x00))
  let meta = tb_box(
    "meta",
    Bytes::from_array([0x00, 0x00, 0x00, 0x00]).add(hdlr).add(ilst),
  )
  let udta = tb_box("udta", meta)
  let moov_inner = @buffer.Buffer()
  for e in extra_moov {
    moov_inner.write_bytes(e)
  }
  moov_inner.write_bytes(udta)
  let moov = tb_box("moov", moov_inner.to_bytes())
  let ftyp = tb_box(
    "ftyp",
    Bytes::from_array([
      0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D, 0x4D, 0x34, 0x41, 0x20,
    ]),
  )
  let mdat = tb_box("mdat", Bytes::make(64, 0xAA))
  ftyp.add(moov).add(mdat)
}

///|
test "F6 定位 ilst 并解析条目（含 meta 的 FullBox +4 偏移）" {
  let file = tb_m4a(
    [
      tb_ilst_entry("©nam", 1, @utf8.encode("标题")),
      tb_ilst_entry("©ART", 1, @utf8.encode("艺术家")),
    ],
    [],
  )
  let entries = read_mp4_tags(file.exact_view())
  @test.assert_eq(entries.length(), 2)
  @test.assert_eq(entries[0].key, "©nam")
  @test.assert_eq(entries[0].data_type, 1)
  @test.assert_eq(text_of(entries, "©nam"), Some("标题"))
  @test.assert_eq(text_of(entries, "©ART"), Some("艺术家"))
}

///|
test "F6 data 盒的 type 在 flags 最低字节（不是独立 4 字节）" {
  // 若把 type 当成独立 4 字节读，这里会读到 0 且值前面多出 4 个空字节
  let file = tb_m4a([tb_ilst_entry("©nam", 1, @utf8.encode("X"))], [])
  let entries = read_mp4_tags(file.exact_view())
  @test.assert_eq(entries[0].data_type, 1)
  @test.assert_eq(entries[0].value.length(), 1)
  @test.assert_eq(entries[0].value.at(0).to_int(), 0x58)
}

///|
test "F6 没有 ilst 的文件返回空数组" {
  let ftyp = tb_box(
    "ftyp",
    Bytes::from_array([
      0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D, 0x4D, 0x34, 0x41, 0x20,
    ]),
  )
  let moov = tb_box("moov", tb_box("mvhd", Bytes::make(20, 0x00)))
  let file = ftyp.add(moov)
  @test.assert_eq(read_mp4_tags(file.exact_view()).length(), 0)
}

///|
test "F6 写入新条目：round-trip 且不改动 mdat" {
  let file = tb_m4a([tb_ilst_entry("©nam", 1, @utf8.encode("旧"))], [])
  let out = set_mp4_tags(file.exact_view(), [mp4_text_tag("©nam", "新标题")])
  let entries = read_mp4_tags(out.exact_view())
  @test.assert_eq(text_of(entries, "©nam"), Some("新标题"))
  // mdat 载荷必须原样保留
  @test.assert_eq(out.has_suffix(Bytes::make(64, 0xAA)), true)
}

///|
test "F6 同 key 替换不叠加" {
  let file = tb_m4a(
    [
      tb_ilst_entry("©nam", 1, @utf8.encode("旧")),
      tb_ilst_entry("©ART", 1, @utf8.encode("艺术家")),
    ],
    [],
  )
  let out = set_mp4_tags(file.exact_view(), [mp4_text_tag("©nam", "新")])
  let entries = read_mp4_tags(out.exact_view())
  let mut count = 0
  for e in entries {
    if e.key == "©nam" {
      count += 1
    }
  }
  @test.assert_eq(count, 1)
  @test.assert_eq(text_of(entries, "©nam"), Some("新"))
  @test.assert_eq(text_of(entries, "©ART"), Some("艺术家"))
}

///|
test "F6 新增之前不存在的键" {
  let file = tb_m4a([tb_ilst_entry("©nam", 1, @utf8.encode("T"))], [])
  let out = set_mp4_tags(file.exact_view(), [
    mp4_text_tag("©alb", "专辑"),
    mp4_text_tag("©day", "2026"),
  ])
  let entries = read_mp4_tags(out.exact_view())
  @test.assert_eq(entries.length(), 3)
  @test.assert_eq(text_of(entries, "©alb"), Some("专辑"))
  @test.assert_eq(text_of(entries, "©day"), Some("2026"))
  @test.assert_eq(text_of(entries, "©nam"), Some("T"))
}

///|
test "F6 封面：covr 条目与 data type 14（PNG）" {
  let png = Bytes::from_array([0x89, 0x50, 0x4E, 0x47])
  let file = tb_m4a([tb_ilst_entry("©nam", 1, @utf8.encode("T"))], [])
  let out = set_mp4_tags(file.exact_view(), [mp4_cover_tag(png, true)])
  let entries = read_mp4_tags(out.exact_view())
  let cover = match cover_of(entries) {
    Some(c) => c
    None => abort("没有 covr")
  }
  @test.assert_eq(cover.length(), 4)
  @test.assert_eq(cover.at(0).to_int(), 0x89)
  // 找到 covr 的 data_type
  let mut ctype = -1
  for e in entries {
    if e.key == "covr" {
      ctype = e.data_type
    }
  }
  @test.assert_eq(ctype, 14)
}

///|
test "F6 moov 里其他盒（如 mvhd）被保留" {
  let mvhd = tb_box("mvhd", Bytes::make(100, 0x11))
  let file = tb_m4a([tb_ilst_entry("©nam", 1, @utf8.encode("T"))], [mvhd])
  let out = set_mp4_tags(file.exact_view(), [mp4_text_tag("©nam", "New")])
  // mvhd 的 100 字节 0x11 载荷应仍在输出里
  @test.assert_eq(out.find(Bytes::make(100, 0x11)) is Some(_), true)
}

///|
test "F6 负例：盒尺寸越界报 BadHeader" {
  // 声明 9999 字节的 ftyp，实际只有几个字节
  let bad = Bytes::from_array([0x00, 0x00, 0x27, 0x0F, 0x66, 0x74, 0x79, 0x70])
  try {
    let _ = read_mp4_tags(bad.exact_view())
    abort("应当报错")
  } catch {
    TagError::BadHeader(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "F6 负例：写不含 moov 的文件报 BadHeader" {
  let ftyp = tb_box(
    "ftyp",
    Bytes::from_array([
      0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D, 0x4D, 0x34, 0x41, 0x20,
    ]),
  )
  try {
    let _ = set_mp4_tags(ftyp.exact_view(), [mp4_text_tag("©nam", "X")])
    abort("应当报错")
  } catch {
    TagError::BadHeader(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "F6 无 ilst 时写入会新建整条 udta/meta/ilst 路径" {
  let ftyp = tb_box(
    "ftyp",
    Bytes::from_array([
      0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D, 0x4D, 0x34, 0x41, 0x20,
    ]),
  )
  let moov = tb_box("moov", tb_box("mvhd", Bytes::make(20, 0x00)))
  let mdat = tb_box("mdat", Bytes::make(32, 0xBB))
  let file = ftyp.add(moov).add(mdat)
  let out = set_mp4_tags(file.exact_view(), [mp4_text_tag("©nam", "新建")])
  let entries = read_mp4_tags(out.exact_view())
  @test.assert_eq(text_of(entries, "©nam"), Some("新建"))
  // mdat 保留
  @test.assert_eq(out.has_suffix(Bytes::make(32, 0xBB)), true)
  // moov 里原有的 mvhd 保留
  @test.assert_eq(out.find(Bytes::make(20, 0x00)) is Some(_), true)
}

///|
/// 拼一个 faststart MP4：ftyp + moov(含 stco) + mdat。
/// stco 记录 mdat 的起始偏移（moov 之后）。
fn tb_faststart_mp4(moov_payload : Bytes, mdat_payload : Bytes) -> Bytes {
  let ftyp = tb_box(
    "ftyp",
    Bytes::from_array([
      0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D, 0x4D, 0x34, 0x41, 0x20,
    ]),
  )
  let moov = tb_box("moov", moov_payload)
  let mdat = tb_box("mdat", mdat_payload)
  ftyp.add(moov).add(mdat)
}

///|
/// 拼一个 stco 盒：version(1)+flags(3)+entry_count(4)+entries(u32 BE)。
fn tb_stco(offsets : Array[Int32]) -> Bytes {
  let payload = @buffer.Buffer()
  payload.write_bytes(Bytes::from_array([0x00, 0x00, 0x00, 0x00]))
  payload.write_bytes(write_u32be(offsets.length()))
  for off in offsets {
    payload.write_bytes(write_u32be(off))
  }
  tb_box("stco", payload.to_bytes())
}

///|
/// 读文件里的第一个 stco 盒的首个 offset。
fn tb_first_chunk_offset(data : Bytes) -> Int32? {
  let boxes = list_boxes(data.exact_view(), 0, data.length()) catch {
    _ => return None
  }
  let moov = match find_box(boxes, "moov") {
    None => return None
    Some(b) => b
  }
  // moov → trak → mdia → minf → stbl → stco
  let moov_children = list_boxes(
    data.exact_view(),
    moov.offset,
    moov.offset + moov.length,
  ) catch {
    _ => return None
  }
  let trak = match find_box(moov_children, "trak") {
    None => return None
    Some(b) => b
  }
  let trak_children = list_boxes(
    data.exact_view(),
    trak.offset,
    trak.offset + trak.length,
  ) catch {
    _ => return None
  }
  let mdia = match find_box(trak_children, "mdia") {
    None => return None
    Some(b) => b
  }
  let mdia_children = list_boxes(
    data.exact_view(),
    mdia.offset,
    mdia.offset + mdia.length,
  ) catch {
    _ => return None
  }
  let minf = match find_box(mdia_children, "minf") {
    None => return None
    Some(b) => b
  }
  let minf_children = list_boxes(
    data.exact_view(),
    minf.offset,
    minf.offset + minf.length,
  ) catch {
    _ => return None
  }
  let stbl = match find_box(minf_children, "stbl") {
    None => return None
    Some(b) => b
  }
  let stbl_children = list_boxes(
    data.exact_view(),
    stbl.offset,
    stbl.offset + stbl.length,
  ) catch {
    _ => return None
  }
  let stco = match find_box(stbl_children, "stco") {
    None => return None
    Some(b) => b
  }
  let v = read_be(data.exact_view(), stco.offset + 8, 4) catch {
    _ => return None
  }
  Some(v)
}

///|
test "F6 faststart（moov 前置）：标签增长时 stco 偏移自动修正" {
  // mdat 载荷 64 字节，放在 moov 之后；stco 记录 mdat 的绝对起始偏移
  let mdat_payload = Bytes::make(64, 0xCC)
  // 初始：ftyp(20) + moov + mdat；mdat 起始 = 20 + moov_len
  // moov 内含 mvhd（占位）+ trak/mdia/minf/stbl/stco
  let mvhd = tb_box("mvhd", Bytes::make(20, 0x00))
  // 先算出 moov 的总长度（用于构造 stco 里的偏移）
  // moov = 8(头) + mvhd(28) + trak(...);trk 内含 stco
  // 用迭代法：先放一个占位 stco，算出长度，再用真实偏移重建
  let stbl_placeholder = tb_box("stbl", tb_stco([0]))
  let minf_placeholder = tb_box("minf", stbl_placeholder)
  let mdia_placeholder = tb_box("mdia", minf_placeholder)
  let trak_placeholder = tb_box("trak", mdia_placeholder)
  let moov_len = 8 + mvhd.length() + trak_placeholder.length()
  let mdat_start = 20 + moov_len
  // 用真实 mdat_start 构造 stco
  let stco = tb_stco([mdat_start])
  let minf = tb_box("minf", tb_box("stbl", stco))
  let mdia = tb_box("mdia", minf)
  let trak = tb_box("trak", mdia)
  let moov_payload = mvhd.add(trak)
  let file = tb_faststart_mp4(moov_payload, mdat_payload)
  // 验证 stco 原值
  let orig_offset = match tb_first_chunk_offset(file) {
    Some(v) => v
    None => abort("未找到 stco")
  }
  @test.assert_eq(orig_offset, mdat_start)
  // 写入更长的标签，moov 会变长
  let long = String::make(300, 'B')
  let out = set_mp4_tags(file.exact_view(), [
    mp4_text_tag("©nam", "New"),
    mp4_text_tag("©ART", long),
  ])
  // 新 stco 偏移必须指向新的 mdat 位置
  let new_offset = match tb_first_chunk_offset(out) {
    Some(v) => v
    None => abort("写后未找到 stco")
  }
  let new_mdat_start = new_offset
  // mdat 起始应该等于 stco 记录的值（偏移已修正）
  let boxes = list_boxes(out.exact_view(), 0, out.length())
  let mdat = match find_box(boxes, "mdat") {
    None => abort("未找到 mdat")
    Some(b) => b
  }
  @test.assert_eq(new_mdat_start, mdat.start)
  // 原值应不同（moov 变长了）
  @test.assert_eq(orig_offset != new_offset, true)
  // mdat 载荷原样保留
  @test.assert_eq(
    out
    .exact_view(start=mdat.offset, end=mdat.offset + 64)
    .data()
    .find(Bytes::make(64, 0xCC))
    is Some(_),
    true,
  )
}

///|
test "F6 负例：fragmented MP4（moof）必须拒绝改写而非静默损坏" {
  let ftyp = tb_box(
    "ftyp",
    Bytes::from_array([
      0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D, 0x4D, 0x34, 0x41, 0x20,
    ]),
  )
  let moov = tb_box("moov", tb_box("mvhd", Bytes::make(20, 0x00)))
  let moof = tb_box("moof", Bytes::make(16, 0x00))
  let mdat = tb_box("mdat", Bytes::make(32, 0xBB))
  let file = ftyp.add(moov).add(moof).add(mdat)
  try {
    let _ = set_mp4_tags(file.exact_view(), [mp4_text_tag("©nam", "X")])
    abort("fMP4 应当被拒绝")
  } catch {
    TagError::Unsupported(..) => ()
    _ => abort("错误类型应为 Unsupported")
  }
}

///|
test "F6 负例：moov 内含 mvex 的 fMP4 也拒绝" {
  let ftyp = tb_box(
    "ftyp",
    Bytes::from_array([
      0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D, 0x4D, 0x34, 0x41, 0x20,
    ]),
  )
  let moov = tb_box(
    "moov",
    tb_box("mvhd", Bytes::make(20, 0x00)).add(
      tb_box("mvex", Bytes::make(12, 0x00)),
    ),
  )
  let mdat = tb_box("mdat", Bytes::make(32, 0xBB))
  let file = ftyp.add(moov).add(mdat)
  try {
    let _ = set_mp4_tags(file.exact_view(), [mp4_text_tag("©nam", "X")])
    abort("含 mvex 的 fMP4 应当被拒绝")
  } catch {
    TagError::Unsupported(..) => ()
    _ => abort("错误类型应为 Unsupported")
  }
}
