// id3_tag.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 id3_tag.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE。本仓库只做按需裁剪，
// 未改动实现；裁剪清单与上游出处见本目录 README.md。
//
// ID3v2 标签解析（读取侧）。
//
// 结构：10 字节标签头 → 可选扩展头 → 帧序列 → 可选 padding → 可选 footer。
// 两个大版本的差异必须分别处理：
//   • v2.3 的帧尺寸是普通 u32，标签级 unsynchronisation 作用于整个标签体；
//   • v2.4 的帧尺寸是 synchsafe，且 unsynchronisation 按帧作用于帧载荷。
// 把两者混用是 ID3v2 实现最常见的 bug，这里用 `major` 分支显式区分。

///|
/// 一个 ID3v2 帧。
pub struct Frame {
  /// 4 字符帧 ID（如 `TIT2`）。
  id : String
  /// 帧载荷（已完成 unsynchronisation 还原）。
  data : Bytes
  /// 帧头第一字节（状态标志）。
  status_flags : Int32
  /// 帧头第二字节（格式标志）。
  format_flags : Int32
}

///|
/// 解析出的 ID3v2 标签。
pub struct Id3Tag {
  /// 主版本号（3 或 4）。
  major : Int32
  /// 修订号。
  revision : Int32
  /// 标签头原始 flags 字节。
  flags : Int32
  /// 帧序列（保持文件内顺序）。
  frames : Array[Frame]
  /// 标签（含头/扩展头/padding/footer）占用的总字节数，即音频数据起点。
  total_size : Int32
}

///|
/// 解析 ID3v2 标签。数据必须从文件起点开始。
///
/// 没有 ID3 标签时抛 `NotTagged`；被截断时抛 `Truncated`。
pub fn parse(data : BytesView) -> Id3Tag raise TagError {
  if data.length() < 10 {
    raise Truncated(offset=0, need=10, actual=data.length())
  }
  if data.at(0) != b'I' || data.at(1) != b'D' || data.at(2) != b'3' {
    raise NotTagged(format="id3v2")
  }
  let major = data.at(3).to_int()
  let revision = data.at(4).to_int()
  if major != 3 && major != 4 {
    raise UnsupportedVersion(version=major)
  }
  let flags = data.at(5).to_int()
  // flags 的低 4 位必须为 0（v2.4 定义了 bit4 = footer，v2.3 未定义 bit4）。
  let size = read_synchsafe32(data, 6)
  let has_footer = major == 4 && (flags & 0x10) != 0
  let total_size = 10 + size + (if has_footer { 10 } else { 0 })
  // 标签体按声明尺寸切片；文件里音频数据不足不影响读取标签。
  let body_end = 10 + size
  if body_end > data.length() {
    raise Truncated(offset=10, need=size, actual=data.length() - 10)
  }
  let raw_body = data.exact_view(start=10, end=body_end)
  // v2.3：unsynchronisation 作用于整个标签体，先整体还原再切帧。
  // v2.4：作用于帧载荷，帧尺寸仍按磁盘上的字节数计算，所以不能整体还原。
  let tag_unsync = (flags & 0x80) != 0
  let body = if major == 3 && tag_unsync {
    unsynchronise(raw_body).exact_view()
  } else {
    raw_body
  }
  let mut pos = 0
  if (flags & 0x40) != 0 {
    pos += extended_header_len(body, major)
  }
  let frames = parse_frames(body, pos, major, tag_unsync)
  { major, revision, flags, frames, total_size, }
}

///|
/// 跳过扩展头，返回其字节长度。
fn extended_header_len(body : BytesView, major : Int32) -> Int32 raise TagError {
  if major == 3 {
    // v2.3：4 字节普通 u32，值**不含自身**（6 或 10）。
    let ext_size = read_u32be(body, 0)
    if ext_size != 6 && ext_size != 10 {
      raise BadHeader(
        reason="v2.3 扩展头尺寸 \{ext_size} 非法（应为 6 或 10）",
      )
    }
    4 + ext_size
  } else {
    // v2.4：4 字节 synchsafe，值**包含自身**，最小 6。
    let ext_size = read_synchsafe32(body, 0)
    if ext_size < 6 {
      raise BadHeader(reason="v2.4 扩展头尺寸 \{ext_size} 小于 6")
    }
    ext_size
  }
}

///|
/// 遍历帧直到 padding（全零）或标签体结束。
fn parse_frames(
  body : BytesView,
  start : Int32,
  major : Int32,
  tag_unsync : Bool,
) -> Array[Frame] raise TagError {
  let out : Array[Frame] = []
  let mut pos = start
  while pos + 10 <= body.length() {
    // padding：剩余的字节全是 0
    if body.at(pos) == b'\x00' {
      break
    }
    if !is_valid_frame_id(body, pos) {
      // 非零且非合法帧 ID：规范上属于损坏数据，但真实文件里常见
      // （尤其 v2.2 帧混入、尾部残留）。按 padding 处理更宽容。
      break
    }
    let id = read_frame_id(body, pos)
    // v2.3 普通 u32，v2.4 synchsafe —— 混用会让后续帧全部错位。
    let size = if major == 4 {
      read_synchsafe32(body, pos + 4)
    } else {
      read_u32be(body, pos + 4)
    }
    let status_flags = body.at(pos + 8).to_int()
    let format_flags = body.at(pos + 9).to_int()
    let payload_start = pos + 10
    if size == 0 {
      // 规范要求帧至少 1 字节；size 0 视为数据损坏。
      raise BadFrameHeader(reason="帧 \{id} 的尺寸为 0")
    }
    if payload_start + size > body.length() {
      raise FrameOutOfBounds(
        frame_id=id,
        size~,
        available=body.length() - payload_start,
      )
    }
    // 跳过帧内的附加头字段（分组字节 / 数据长度指示 / 加密方法），
    // 其中加密与压缩明确不支持。
    let extra = extra_header_len(id, major, status_flags, format_flags)
    let data_start = payload_start + extra
    let data_end = payload_start + size
    if data_start > data_end {
      raise BadFrameHeader(reason="帧 \{id} 的附加头字段超出帧尺寸")
    }
    let raw = body.exact_view(start=data_start, end=data_end)
    // v2.4：帧级 unsync（或标签级 unsync 表示所有帧都还原）
    let frame_unsync = major == 4 && (tag_unsync || (format_flags & 0x02) != 0)
    let data = if frame_unsync {
      unsynchronise(raw)
    } else {
      slice_bytes(body, data_start, data_end)
    }
    out.push({ id, data, status_flags, format_flags, })
    pos = data_end
  }
  out
}

///|
/// 帧附加头字段的字节数；加密/压缩直接报不支持。
fn extra_header_len(
  id : String,
  major : Int32,
  status_flags : Int32,
  format_flags : Int32,
) -> Int32 raise TagError {
  if major == 3 {
    // %ijk00000：i 压缩 $80、j 加密 $40、k 分组 $20
    let compressed = (format_flags & 0x80) != 0
    let encrypted = (format_flags & 0x40) != 0
    let grouped = (format_flags & 0x20) != 0
    if compressed {
      raise Unsupported(what="帧 \{id} 使用了 zlib 压缩")
    }
    if encrypted {
      raise Unsupported(what="帧 \{id} 已加密")
    }
    if grouped {
      1
    } else {
      0
    }
  } else {
    // %0h00kmnp：h 分组 $40、k 压缩 $08、m 加密 $04、p 数据长度指示 $01
    let grouped = (format_flags & 0x40) != 0
    let compressed = (format_flags & 0x08) != 0
    let encrypted = (format_flags & 0x04) != 0
    let has_dli = (format_flags & 0x01) != 0
    if compressed {
      raise Unsupported(what="帧 \{id} 使用了 zlib 压缩")
    }
    if encrypted {
      raise Unsupported(what="帧 \{id} 已加密")
    }
    let mut n = 0
    if grouped {
      n += 1
    }
    if has_dli {
      n += 4
    }
    let _ = status_flags
    n
  }
}

///|
/// 读 4 字符帧 ID。
///
/// 注意不能用 `Buffer::to_string`：它按 UTF-16LE 解释字节，会把
/// "TIT2" 变成乱码。这里逐字节转字符再拼。
fn read_frame_id(body : BytesView, pos : Int32) -> String {
  let buf = StringBuilder()
  for i in 0..<4 {
    buf.write_char(Int32::unsafe_to_char(body.at(pos + i).to_int()))
  }
  buf.to_string()
}

///|
/// 取第一个指定 ID 的帧。
pub fn Id3Tag::frame(self : Id3Tag, id : String) -> Frame? {
  for f in self.frames {
    if f.id == id {
      return Some(f)
    }
  }
  None
}

///|
/// 取所有指定 ID 的帧（规范允许多值的帧，如多个 `TXXX`）。
pub fn Id3Tag::frames_with_id(self : Id3Tag, id : String) -> Array[Frame] {
  let out : Array[Frame] = []
  for f in self.frames {
    if f.id == id {
      out.push(f)
    }
  }
  out
}

///|
/// 取某个文本帧的解码字符串；帧不存在或载荷为空时返回 `None`。
pub fn Id3Tag::text(self : Id3Tag, id : String) -> String? raise TagError {
  match self.frame(id) {
    None => None
    Some(f) => f.as_text()
  }
}

///|
/// 把帧当作文本帧解码；非文本帧（ID 不以 `T` 开头）返回 `None`。
///
/// `TXXX` 这类"描述 + 值"的帧只返回第一个字符串（描述）——
/// 需要分别取描述和值时用 `TXXX` 专用接口。
pub fn Frame::as_text(self : Frame) -> String? raise TagError {
  if self.data.length() == 0 {
    return None
  }
  // 文本帧 ID 一律以 T 开头；其他帧首字节不是编码字节，不能按文本解。
  if self.id.length() != 4 || !self.id.has_prefix("T") {
    return None
  }
  let code = self.data.at(0).to_int()
  // 编码字节只允许 0..3；越界说明不是文本帧。
  if code > 3 {
    return None
  }
  let enc = TextEncoding::from_code(code)
  let parts = split_strings(self.data.exact_view(), enc, 1, self.data.length())
  if parts.length() == 0 {
    Some("")
  } else {
    Some(parts[0])
  }
}
