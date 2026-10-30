// ogg_page.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 ogg_page.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE。本仓库只做按需裁剪，
// 未改动实现；裁剪清单与上游出处见本目录 README.md。
//
// OGG 页面层的读写（为 Vorbis/Opus 的 comment packet 提供容器能力）。
//
// 页面结构（RFC 3533 / Ogg bitstream）：
//   0..4   "OggS"
//   4      版本（恒 0）
//   5      header type：bit0=continued, bit1=BOS, bit2=EOS
//   6..14  granule position（8 字节小端）
//   14..18 serial number（4 字节小端）
//   18..22 页序号（4 字节小端）
//   22..26 CRC-32（Ogg 非反射算法，见下）
//   26      段数（lacing count）
//   27..    lacing 值表 + 段载荷

///|
/// OGG 页头长度（固定 27 字节，不含 lacing 表）。
pub const OGG_HEADER_SIZE : Int32 = 27

///|
/// 一个 OGG 页（位置描述）。
pub struct OggPage {
  /// 页在文件中的起始偏移。
  offset : Int32
  /// 段数（lacing count）。
  n_segments : Int32
  /// 完整页长度（含头与全部段载荷）。
  total_len : Int32
  /// 段 0 的载荷起始偏移。
  body_offset : Int32
  /// 是否 BOS。
  is_bos : Bool
  /// 是否 EOS。
  is_eos : Bool
  /// 是否 continued。
  is_continued : Bool
  /// 流序列号。
  serial : Int32
  /// 页序号。
  seq : Int32
  /// 原始数据。
  data : Bytes
}

///|
/// 从文件头开始解析 OGG 页。
pub fn parse_page(data : Bytes, offset : Int32) -> OggPage raise TagError {
  require_range(data, offset, OGG_HEADER_SIZE)
  if data.at(offset) != b'O' ||
    data.at(offset + 1) != b'g' ||
    data.at(offset + 2) != b'g' ||
    data.at(offset + 3) != b'S' {
    raise NotTagged(format="ogg")
  }
  let version = data.at(offset + 4).to_int()
  if version != 0 {
    raise BadHeader(reason="Ogg 版本 \{version} != 0")
  }
  let header_type = data.at(offset + 5).to_int()
  let n_segments = data.at(offset + 26).to_int()
  let body_offset = offset + OGG_HEADER_SIZE + n_segments
  let mut total = 0
  for i in 0..<n_segments {
    total += data.at(offset + OGG_HEADER_SIZE + i).to_int()
  }
  let total_len = OGG_HEADER_SIZE + n_segments + total
  require_range(data, offset, total_len)
  {
    offset,
    n_segments,
    total_len,
    body_offset,
    is_bos: (header_type & 0x02) != 0,
    is_eos: (header_type & 0x04) != 0,
    is_continued: (header_type & 0x01) != 0,
    serial: read_le32_raw(data.exact_view(), offset + 14),
    seq: read_le32_raw(data.exact_view(), offset + 18),
    data,
  }
}

///|
/// 段长度（lacing 值）。
pub fn OggPage::segment_len(self : OggPage, i : Int32) -> Int32 {
  self.data.at(self.offset + OGG_HEADER_SIZE + i).to_int()
}

///|
/// 把连续若干页的段重组成逻辑 packet（跨页未完成也处理）。
pub fn assemble_packets(data : Bytes, pages : Array[OggPage]) -> Array[Bytes] {
  let out : Array[Bytes] = []
  let buf = @buffer.Buffer()
  for p in pages {
    let mut cursor = p.body_offset
    for i in 0..<p.n_segments {
      let seg_len = p.segment_len(i)
      for j in 0..<seg_len {
        buf.write_byte(data.at(cursor + j))
      }
      cursor += seg_len
      if seg_len < 255 {
        out.push(buf.to_bytes())
        buf.reset()
      }
    }
  }
  out
}

///|
/// 把 payload 切分成 lacing 段（每段 ≤255，最后一段 <255 表示 packet 结束）。
fn lacing_values(payload : Bytes) -> Array[Int32] {
  let n = payload.length()
  if n == 0 {
    return [0]
  }
  let out : Array[Int32] = []
  let mut remaining = n
  while remaining > 255 {
    out.push(255)
    remaining -= 255
  }
  out.push(remaining)
  out
}

///|
/// 构造一个 OGG 页（含 CRC 计算）。
///
/// `header_type` 用 bit1=BOS；comment 页与普通页用 0。
pub fn make_page(
  serial : Int32,
  seq : Int32,
  header_type : Int32,
  granule : Int64,
  payload : Bytes,
) -> Bytes {
  make_page_multi(serial, seq, header_type, granule, [payload])
}

///|
/// 构造一个含**多个 packet**的 OGG 页。
///
/// 每个 packet 独立做 lacing（段结束标记 <255），packet 之间在页内
/// 顺序拼接。这是 Vorbis 头页的正确形态：comment 与 setup 是两个
/// packet，虽然同页，但必须各自成段。
pub fn make_page_multi(
  serial : Int32,
  seq : Int32,
  header_type : Int32,
  granule : Int64,
  packets : Array[Bytes],
) -> Bytes {
  // 合并 lacing 表与载荷
  let lacing : Array[Int32] = []
  let body = @buffer.Buffer()
  for p in packets {
    let l = lacing_values(p)
    for v in l {
      lacing.push(v)
    }
    body.write_bytes(p)
  }
  let n = lacing.length()
  let payload = body.to_bytes()
  // 页头：27 字节 + lacing 表；CRC 字段（22..26）先填 0
  let mut head = Bytes::from_array([
    0x4F,
    0x67,
    0x67,
    0x53,
    0x00,
    header_type.to_byte(),
  ])
  head = head.add(write_le64(granule))
  head = head.add(write_le32_bytes(serial))
  head = head.add(write_le32_bytes(seq))
  head = head.add(Bytes::from_array([0x00, 0x00, 0x00, 0x00]))
  head = head.add(Bytes::from_array([n.to_byte()]))
  for l in lacing {
    head = head.add(Bytes::from_array([l.to_byte()]))
  }
  let page_with_zero_crc = head.add(payload)
  // 计算 CRC（把 CRC 字段当 0 参与计算，即整页直接算）
  let crc = ogg_crc32(page_with_zero_crc)
  // 把 CRC 写回 22..26（小端）
  let mut final_bytes = page_with_zero_crc
  final_bytes = patch_bytes(
    final_bytes,
    22,
    write_le32_bytes(crc.reinterpret_as_int()),
  )
  final_bytes
}

///|
/// 把 `replacement` 写到 `data` 的 `offset` 处。
fn patch_bytes(data : Bytes, offset : Int32, replacement : Bytes) -> Bytes {
  let out = @buffer.Buffer()
  let mut i = 0
  while i < offset {
    out.write_byte(data.at(i))
    i += 1
  }
  out.write_bytes(replacement)
  let mut j = offset + replacement.length()
  while j < data.length() {
    out.write_byte(data.at(j))
    j += 1
  }
  out.to_bytes()
}

///|
/// 写 8 字节小端。
fn write_le64(v : Int64) -> Bytes {
  let out = @buffer.Buffer()
  for shift in [0, 8, 16, 24, 32, 40, 48, 56] {
    let byte = ((v >> shift) & 0xFFL).to_int().to_byte()
    out.write_byte(byte)
  }
  out.to_bytes()
}

///|
/// 写 4 字节小端。
fn write_le32_bytes(v : Int32) -> Bytes {
  Bytes::from_array([
    (v & 0xFF).to_byte(),
    ((v >> 8) & 0xFF).to_byte(),
    ((v >> 16) & 0xFF).to_byte(),
    ((v >> 24) & 0xFF).to_byte(),
  ])
}

///|
/// Ogg CRC-32：非反射（MSB-first）算法，多项式 0x04C11DB7，
/// 初始 0、无最终异或。与 zlib/标准 CRC-32 不同，不能复用。
pub fn ogg_crc32(data : Bytes) -> UInt32 {
  let table = ogg_crc_table()
  let mut c : UInt32 = 0U
  for i in 0..<data.length() {
    let byte = data.at(i).to_uint()
    let idx = ((c >> 24) ^ byte).reinterpret_as_int()
    c = (c << 8) ^ table[idx]
  }
  c
}

///|
/// Ogg CRC 查找表（惰性构造一次）。
fn ogg_crc_table() -> FixedArray[UInt32] {
  let table = FixedArray::make(256, 0U)
  for i in 0..<256 {
    let mut r : UInt32 = i.reinterpret_as_uint() << 24
    for _ in 0..<8 {
      if (r & 0x80000000U) != 0U {
        r = (r << 1) ^ 0x04C11DB7U
      } else {
        r = r << 1
      }
    }
    table[i] = r
  }
  table
}
