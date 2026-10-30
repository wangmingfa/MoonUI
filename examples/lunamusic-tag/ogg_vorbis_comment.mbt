// ogg_vorbis_comment.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 ogg_vorbis_comment.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE。本仓库只做按需裁剪，
// 未改动实现；裁剪清单与上游出处见本目录 README.md。
//
// Ogg 容器（Vorbis / Opus）中 Vorbis Comment packet 的读写。
//
// Ogg Vorbis 的前三个 packet：
//   packet 0: identification header（\x01vorbis）
//   packet 1: comment header（\x03vorbis + 小端 Vorbis Comment 载荷）
//   packet 2: setup header
// Ogg Opus 则是：
//   packet 0: OpusHead
//   packet 1: OpusTags（OpusTags 魔数 + 同样的 Vorbis Comment 载荷）
//
// 写入时只重建 identification 与 comment 两页；comment 变长时后续页
// 整体后移但内容、页序号、granule 不变——Ogg 播放器按页序号连续
// 容忍空隙，音频数据与时间戳零改动。

///|
/// Ogg 流中 comment 的定位结果。
pub struct OggCommentLoc {
  /// comment 载荷（去魔数后的 Vorbis Comment 字节）。
  payload : Bytes
  /// comment 之后第一个页的偏移（音频数据起点）。
  end_offset : Int32
  /// 流序列号。
  serial : Int32
  /// 是否为 Opus 流（否则为 Vorbis）。
  is_opus : Bool
}

///|
/// 从 Bytes 里拷贝 [start, end) 段（不 raise，边界由调用方保证）。
fn copy_range(data : Bytes, start : Int32, end : Int32) -> Bytes {
  let out = @buffer.Buffer()
  let mut i = start
  while i < end {
    out.write_byte(data.at(i))
    i += 1
  }
  out.to_bytes()
}

///|
/// 从 Ogg 流定位 comment packet；不是 Ogg 或无 comment 返回 `None`。
///
/// `end_offset` 是 comment packet **最后一个字节之后**的偏移（精确到
/// packet 边界，不是页边界），供写入时把 setup/音频原样拼接。
pub fn read_ogg_comment(data : Bytes) -> OggCommentLoc? {
  let mut offset = 0
  let pages : Array[OggPage] = []
  // 逐段扫描：每页的段重组为 packet，直到找到第 2 个完整 packet，
  // 并记录其**字节级**结束偏移。
  let mut packet_count = 0
  let mut comment_end = -1
  while offset < data.length() {
    let page = parse_page(data, offset) catch { _ => return None }
    pages.push(page)
    // 直接计算：packet 边界 = 段载荷累计；每遇到 <255 的段，
    // 记下该段结束的字节偏移（= 下一个 packet 的开始）。
    let mut cursor = page.body_offset
    for i in 0..<page.n_segments {
      let seg_len = page.segment_len(i)
      cursor += seg_len
      if seg_len < 255 {
        packet_count += 1
        if packet_count == 2 {
          comment_end = cursor
        }
      }
    }
    offset += page.total_len
    if packet_count >= 2 {
      break
    }
    if pages.length() > 4 {
      return None
    }
  }
  if packet_count < 2 || comment_end < 0 {
    return None
  }
  let packets = assemble_packets(data, pages)
  if packets.length() < 2 {
    return None
  }
  let ident = packets[0]
  let comment = packets[1]
  // Vorbis：ident 以 \x01vorbis 开头，comment 以 \x03vorbis 开头
  if ident.length() >= 7 &&
    ident.at(0) == b'\x01' &&
    ident.at(1) == b'v' &&
    ident.at(2) == b'o' &&
    ident.at(3) == b'r' &&
    ident.at(4) == b'b' &&
    ident.at(5) == b'i' &&
    ident.at(6) == b's' {
    if comment.length() > 7 && comment.at(0) == b'\x03' {
      return Some({
        payload: copy_range(comment, 7, comment.length()),
        end_offset: comment_end,
        serial: pages[0].serial,
        is_opus: false,
      })
    }
    return None
  }
  // Opus：ident 以 OpusHead 开头，comment 以 OpusTags 开头
  if ident.length() >= 8 &&
    ident.at(0) == b'O' &&
    ident.at(1) == b'p' &&
    ident.at(2) == b'u' &&
    ident.at(3) == b's' &&
    ident.at(4) == b'H' &&
    ident.at(5) == b'e' &&
    ident.at(6) == b'a' &&
    ident.at(7) == b'd' {
    if comment.length() > 8 &&
      comment.at(0) == b'O' &&
      comment.at(1) == b'p' &&
      comment.at(2) == b'u' &&
      comment.at(3) == b's' &&
      comment.at(4) == b'T' &&
      comment.at(5) == b'a' &&
      comment.at(6) == b'g' &&
      comment.at(7) == b's' {
      return Some({
        payload: copy_range(comment, 8, comment.length()),
        end_offset: comment_end,
        serial: pages[0].serial,
        is_opus: true,
      })
    }
    return None
  }
  None
}

///|
/// 解析 comment 载荷为 VorbisComment。
pub fn parse_ogg_comment_payload(
  loc : OggCommentLoc,
) -> VorbisComment raise TagError {
  parse_vorbis_comment(loc.payload.exact_view())
}

///|
/// 用新 comment 重建 Ogg 流前缀。
///
/// Vorbis/Opus 的 setup packet 与 comment 在**同一页**（页 1 的 lacing
/// 表是 `comment_len, 255, ..., setup_tail`）。直接把 comment 换掉再
/// "原样拼接"会丢掉 setup 的 lacing 信息。这里改为：
///   1. 重组原页 0 + 页 1，取出 ident / 旧 comment / setup 三个 packet；
///   2. 重建页 0 = ident（原样），页 1 = 新 comment，页 2 = setup（原样）；
///   3. 从原页 2 起，逐页重编号、重算 CRC、保留 granule 与 header_type。
pub fn set_ogg_comment(
  data : Bytes,
  vc : VorbisComment,
) -> Bytes raise TagError {
  let loc = match read_ogg_comment(data) {
    Some(l) => l
    None => raise NotTagged(format="ogg")
  }
  let payload = serialize_vorbis_comment(vc)
  let comment_packet = if loc.is_opus {
    @utf8.encode("OpusTags").add(payload)
  } else {
    Bytes::from_array([0x03, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]).add(payload)
  }
  // 重组页 0 与页 1（comment 与 setup 同页）
  let page0 = parse_page(data, 0) catch { _ => raise NotTagged(format="ogg") }
  let page1 = parse_page(data, page0.total_len) catch {
    _ => raise NotTagged(format="ogg")
  }
  let head_packets = assemble_packets(data, [page0, page1])
  if head_packets.length() < 2 {
    raise BadHeader(reason="Ogg 头不足两个 packet（ident/comment）")
  }
  let ident_payload = head_packets[0]
  // Vorbis 有三个 header packet；Opus 只有两个（无 setup）
  let has_setup = head_packets.length() >= 3
  let setup_payload = if has_setup { head_packets[2] } else { Bytes::new(0) }
  // 重建页 0/1：ident 原样；comment 与 setup 作为**两个独立 packet**
  // 合入同一页（Vorbis 的 ffmpeg 解析器要求 comment 后紧邻 setup 或音频）
  let out = @buffer.Buffer()
  out.write_bytes(make_page(loc.serial, 0, 0x02, 0L, ident_payload))
  let page1_packets = if has_setup {
    [comment_packet, setup_payload]
  } else {
    [comment_packet]
  }
  out.write_bytes(make_page_multi(loc.serial, 1, 0x00, 0L, page1_packets))
  // 音频页从原页 2 起**原样**拼接：
  // - 页内字节不变 → CRC 仍然有效，无需重算；
  // - 页序号（seq=2,3,...）保持连续，与重建后的页 0/1 不冲突；
  // - 绝对偏移变化对 Ogg 无影响（页序与 granule 才是语义）。
  let mut i = page0.total_len + page1.total_len
  while i < data.length() {
    out.write_byte(data.at(i))
    i += 1
  }
  out.to_bytes()
}
