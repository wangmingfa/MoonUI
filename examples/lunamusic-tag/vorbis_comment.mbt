// vorbis_comment.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 vorbis_comment.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE。本仓库只做按需裁剪，
// 未改动实现；裁剪清单与上游出处见本目录 README.md。
//
// Vorbis Comment 的读写。
//
// 载荷布局（小端序，与 FLAC 其他部分的大端序相反——这点极易写错）：
//   vendor_length  u32 LE
//   vendor         UTF-8
//   count          u32 LE
//   每个 comment：
//     length       u32 LE
//     "KEY=value"  UTF-8
//
// 规范要求 KEY 只含 ASCII 0x20..0x7D 除去 '='，且不区分大小写。
// 写入时统一大写（这是事实上的惯例，metaflac 与 ffmpeg 都这么做）。

///|
/// 一个 Vorbis Comment 标签。
pub struct VorbisComment {
  /// vendor 字符串（写者标识）。
  vendor : String
  /// 全部 `KEY=value` 条目，保持文件内顺序与原始大小写。
  entries : Array[String]
}

///|
/// 构造一个空的 Vorbis Comment（指定 vendor）。
pub fn empty_vorbis_comment(vendor : String) -> VorbisComment {
  { vendor, entries: [], }
}

///|
/// 解析 Vorbis Comment 载荷。
pub fn parse_vorbis_comment(
  payload : BytesView,
) -> VorbisComment raise TagError {
  if payload.length() < 8 {
    raise BadFrameData(
      frame_id="VORBIS_COMMENT",
      reason="载荷不足 8 字节",
    )
  }
  let mut pos = 0
  let vendor_len = read_le32(payload, pos)
  pos += 4
  require_range(payload, pos, vendor_len)
  let vendor = @utf8.decode_lossy(
    payload.exact_view(start=pos, end=pos + vendor_len),
  )
  pos += vendor_len
  let count = read_le32(payload, pos)
  pos += 4
  let entries : Array[String] = []
  for _ in 0..<count {
    require_range(payload, pos, 4)
    let len = read_le32(payload, pos)
    pos += 4
    require_range(payload, pos, len)
    let entry = @utf8.decode_lossy(payload.exact_view(start=pos, end=pos + len))
    pos += len
    entries.push(entry)
  }
  { vendor, entries, }
}

///|
/// 序列化 Vorbis Comment 载荷。
pub fn serialize_vorbis_comment(vc : VorbisComment) -> Bytes {
  let out = @buffer.Buffer()
  let vendor_bytes = @utf8.encode(vc.vendor)
  write_le32(out, vendor_bytes.length())
  out.write_bytes(vendor_bytes)
  write_le32(out, vc.entries.length())
  for e in vc.entries {
    let eb = @utf8.encode(e)
    write_le32(out, eb.length())
    out.write_bytes(eb)
  }
  out.to_bytes()
}

///|
/// 校验 KEY：ASCII 0x20..0x7D，不含 '='，且非空。
fn is_valid_key(key : StringView) -> Bool {
  if key.is_empty() {
    return false
  }
  for c in key {
    let cp = c.to_int()
    if cp < 0x20 || cp > 0x7D || c == '=' {
      return false
    }
  }
  true
}

///|
/// 按 key 取值（不区分 ASCII 大小写）；找不到返回 `None`。
///
/// 同 key 多次出现时返回文件中靠前的一个。
pub fn VorbisComment::get(self : VorbisComment, key : String) -> String? {
  for e in self.entries {
    match e.split_once("=") {
      None => ()
      Some((k, v)) =>
        if k.equal_ignore_ascii_case(key) {
          return Some(v.to_owned())
        }
    }
  }
  None
}

///|
/// 按 key 取全部值，保持文件内顺序、不去重（规范允许多值，如多个 ARTIST）。
pub fn VorbisComment::get_all(
  self : VorbisComment,
  key : String,
) -> Array[String] {
  let out : Array[String] = []
  for e in self.entries {
    match e.split_once("=") {
      None => ()
      Some((k, v)) =>
        if k.equal_ignore_ascii_case(key) {
          out.push(v.to_owned())
        }
    }
  }
  out
}

///|
/// 设置一个 key 的值：先删除该 key 的全部旧条目，再追加新条目。
///
/// `value` 为空字符串表示只删除不追加。
pub fn VorbisComment::set_key(
  self : VorbisComment,
  key : String,
  value : String,
) -> VorbisComment raise TagError {
  if !is_valid_key(key) {
    raise BadFrameData(
      frame_id="VORBIS_COMMENT",
      reason="非法的 KEY：\{key}",
    )
  }
  let upper = key.to_upper()
  let kept : Array[String] = []
  for e in self.entries {
    match e.split_once("=") {
      None => kept.push(e)
      Some((k, _)) => if !k.equal_ignore_ascii_case(key) { kept.push(e) }
    }
  }
  if value != "" {
    kept.push("\{upper}=\{value}")
  }
  { vendor: self.vendor, entries: kept, }
}
