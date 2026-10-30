// id3_write.mbt
//
// ID3v2 标签写入（F2）。
//
// 设计要点：
//   • 保持原文件的版本（v2.3 或 v2.4），因为帧尺寸的编码方式由版本决定；
//   • 原文件没有 ID3 标签时新建 v2.4 标签；
//   • padding 能复用就复用（避免每次小改都平移整段音频数据）；
//   • 未知帧原样保留——丢弃别人的帧是标签编辑最容易犯的错。
//
// v2.3 与 v2.4 的两处硬差异（这里必须显式分支，不能靠"看起来一样"）：
//   1. 帧尺寸：v2.3 普通 u32，v2.4 synchsafe；
//   2. 文本编码：v2.3 无 UTF-8（$03），只能用 ISO-8859-1 或 UTF-16。
//
// vendored 自 cp15695540483/moontag@0.1.1 的 id3_write.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE；本仓库只改下述范围：
//   - 删除 set_picture（封面写入）：它依赖没有拉进来的 id3_apic.mbt。
//     需要封面时按本目录 README 的「暂未取用」一节回上游取。
// 除裁剪外未改动实现；上游测试原样保留在 id3_write_wbtest.mbt。

///|
/// 待写入的文本帧：帧 ID + 文本值。
pub struct TagField {
  /// 4 字符帧 ID（如 `TIT2`）。
  id : String
  /// 文本值。
  value : String
}

///|
/// 构造一个待写字段。
pub fn field(id : String, value : String) -> TagField {
  { id, value, }
}

///|
/// 写入选项。
pub struct WriteOptions {
  /// 新建标签时预留的 padding 字节数。
  padding : Int32
  /// 是否写入 v2.4（仅当原文件没有标签时生效）。
  default_major : Int32
}

///|
/// 默认写入选项：1024 字节 padding、新建时用 v2.4。
pub fn WriteOptions::default() -> WriteOptions {
  { padding: 1024, default_major: 4, }
}

///|
/// 原文件里 ID3 标签占据的字节数与解析结果。
///
/// 没有标签时 `tag` 为 `None`、`size` 为 0。
pub struct ExistingTag {
  tag : Id3Tag?
  /// 标签占用的总字节数（音频数据起点）。
  size : Int32
}

///|
/// 定位文件开头的 ID3 标签；没有标签不算错误。
fn locate_tag(data : BytesView) -> ExistingTag {
  if data.length() < 10 ||
    data.at(0) != b'I' ||
    data.at(1) != b'D' ||
    data.at(2) != b'3' {
    return { tag: None, size: 0, }
  }
  let major = data.at(3).to_int()
  if major != 3 && major != 4 {
    return { tag: None, size: 0, }
  }
  let parse_result : Id3Tag? = Some(parse(data)) catch { _ => None }
  match parse_result {
    None => { tag: None, size: 0, }
    Some(t) => { tag: Some(t), size: t.total_size, }
  }
}

///|
/// 把标签里除 `ids` 之外的帧原样保留（`ids` 中出现的帧由调用方重新生成）。
fn keep_frames(tag : Id3Tag, ids : Array[String]) -> Array[Frame] {
  let out : Array[Frame] = []
  for f in tag.frames {
    let mut drop = false
    for id in ids {
      if f.id == id {
        drop = true
        break
      }
    }
    // tag-alter preservation：置位表示"标签被修改时丢弃"，尊重原作者意图
    let discard_on_alter = if tag.major == 4 {
      (f.status_flags & 0x40) != 0
    } else {
      (f.status_flags & 0x80) != 0
    }
    if !drop && !discard_on_alter {
      out.push(f)
    }
  }
  out
}

///|
/// 选文本编码：v2.3 用 UTF-16（$01），v2.4 用 UTF-8（$03）。
///
/// v2.3 规范只定义了 $00/$01，写 UTF-8 会让老播放器解出乱码；
/// v2.4 加进了 $03，此时 UTF-8 体积更小、兼容性也更好。
fn encoding_for(major : Int32) -> TextEncoding {
  if major == 4 {
    Utf8
  } else {
    Utf16Bom
  }
}

///|
/// 把字符串按编码序列化（不含终止符）。
fn encode_string(value : String, encoding : TextEncoding) -> Bytes {
  match encoding {
    Latin1 => latin1_encode(value)
    Utf8 => @utf8.encode(value)
    // 两种 UTF-16 都带 BOM：v2.3 的 $01 要求 BOM 决定字节序
    Utf16Bom => @utf16.encode(value, bom=true, endianness=Little)
    Utf16Be => @utf16.encode(value, bom=false, endianness=Big)
  }
}

///|
/// ISO-8859-1 编码：码点 > 0xFF 的字符退化成 `?`（该编码无法表示）。
fn latin1_encode(value : String) -> Bytes {
  let out = @buffer.Buffer()
  for c in value {
    let cp = c.to_int()
    if cp <= 0xFF {
      out.write_byte(cp.to_byte())
    } else {
      out.write_byte(b'?')
    }
  }
  out.to_bytes()
}

///|
/// 构造一个文本帧的完整字节（帧头 + 载荷）。
fn encode_text_frame(
  major : Int32,
  id : String,
  value : String,
  encoding : TextEncoding,
) -> Bytes {
  let text = encode_string(value, encoding)
  let payload = @buffer.Buffer()
  payload.write_byte(encoding.code().to_byte())
  payload.write_bytes(text)
  build_frame(major, id, 0, payload.to_bytes())
}

///|
/// 拼帧头 + 载荷。尺寸字段按版本编码。
fn build_frame(
  major : Int32,
  id : String,
  format_flags : Int32,
  payload : Bytes,
) -> Bytes {
  let out = @buffer.Buffer()
  for c in id {
    out.write_byte(c.to_int().to_byte())
  }
  let n = payload.length()
  if major == 4 {
    for shift in [21, 14, 7, 0] {
      out.write_byte(((n >> shift) & 0x7F).to_byte())
    }
  } else {
    for shift in [24, 16, 8, 0] {
      out.write_byte(((n >> shift) & 0xFF).to_byte())
    }
  }
  out.write_byte(b'\x00')
  out.write_byte(format_flags.to_byte())
  out.write_bytes(payload)
  out.to_bytes()
}

///|
/// 把已存在的帧（来自解析结果）重新序列化。
///
/// 解析时已经还原过 unsynchronisation，所以这里按"未同步"形态写回，
/// 并清掉帧头里的 unsync 位——否则读者会对同一份数据再还原一次。
fn reserialize_frame(major : Int32, f : Frame) -> Bytes {
  let format_flags = if major == 4 {
    // 清 bit1（unsync）；其余格式位（分组/压缩/加密）在读取阶段已拒绝
    f.format_flags & 0xFD
  } else {
    f.format_flags
  }
  build_frame(major, f.id, format_flags, f.data)
}

///|
/// 序列化整个标签：头 + 帧 + padding。
fn serialize_tag(
  major : Int32,
  frames : Array[Bytes],
  padding : Int32,
  revision : Int32,
) -> Bytes {
  let body = @buffer.Buffer()
  for f in frames {
    body.write_bytes(f)
  }
  for _ in 0..<padding {
    body.write_byte(b'\x00')
  }
  let content = body.to_bytes()
  let out = @buffer.Buffer()
  out.write_byte(b'I')
  out.write_byte(b'D')
  out.write_byte(b'3')
  out.write_byte(major.to_byte())
  out.write_byte(revision.to_byte())
  // 新标签不带扩展头、不带 footer、全帧未同步
  out.write_byte(b'\x00')
  let n = content.length()
  for shift in [21, 14, 7, 0] {
    out.write_byte(((n >> shift) & 0x7F).to_byte())
  }
  out.write_bytes(content)
  out.to_bytes()
}

///|
/// 用一批字段更新文件里的 ID3v2 标签。
///
/// `fields` 里 `value` 为空字符串表示**删除**该帧。
/// 返回完整的新文件字节：新标签 + 原音频数据（未改动）。
pub fn set_fields(
  data : BytesView,
  fields : Array[TagField],
  options : WriteOptions,
) -> Bytes raise TagError {
  // 字段 ID 必须是 4 字符、以 T/W 开头的文本帧；其他帧的语义各不相同，
  // 通用 `set_fields` 不替它们猜编码。
  for f in fields {
    if f.id.length() != 4 {
      raise BadFrameHeader(reason="帧 ID \{f.id} 长度不是 4")
    }
    if !f.id.has_prefix("T") && !f.id.has_prefix("W") {
      raise Unsupported(
        what="set_fields 只支持文本帧（T***/W***），收到 \{f.id}",
      )
    }
  }
  let major = resolve_major(data, options)
  let enc = encoding_for(major)
  let new_blobs : Array[Bytes] = []
  for f in fields {
    // 空值表示删除：不生成新帧，只把它加入"待替换 ID"
    if f.value == "" {
      continue
    }
    new_blobs.push(encode_text_frame(major, f.id, f.value, enc))
  }
  let replace_ids : Array[String] = []
  for f in fields {
    replace_ids.push(f.id)
  }
  rewrite_tag(data, replace_ids, new_blobs, options)
}

///|
/// 决定要写入的版本：文件有标签就沿用，否则用 options 指定的默认版本。
fn resolve_major(data : BytesView, options : WriteOptions) -> Int32 {
  match locate_tag(data).tag {
    Some(t) => t.major
    None => options.default_major
  }
}

///|
/// 重写标签的公共内核。
///
/// `replace_ids` 里的帧会被丢弃（由 `new_blobs` 提供新版本），
/// 其余帧原样保留。
fn rewrite_tag(
  data : BytesView,
  replace_ids : Array[String],
  new_blobs : Array[Bytes],
  options : WriteOptions,
) -> Bytes raise TagError {
  let existing = locate_tag(data)
  let (major, revision, old_tag, audio_start) = match existing.tag {
    None => (options.default_major, 0, None, 0)
    Some(t) => (t.major, t.revision, Some(t), existing.size)
  }
  // 原标签里除被替换的帧之外，其余帧原样保留
  let kept = match old_tag {
    None => []
    Some(t) => keep_frames(t, replace_ids)
  }
  // 帧区内容 = 保留帧 + 新帧
  let frame_blobs : Array[Bytes] = []
  let mut frame_bytes = 0
  for f in kept {
    let b = reserialize_frame(major, f)
    frame_bytes += b.length()
    frame_blobs.push(b)
  }
  for b in new_blobs {
    frame_bytes += b.length()
    frame_blobs.push(b)
  }
  // padding 预算：以原标签体为上限，装得下就原地复用（音频数据不移动）
  let padding = match old_tag {
    None => options.padding
    Some(t) => {
      let budget = tag_body_len(t)
      if frame_bytes <= budget {
        budget - frame_bytes
      } else {
        options.padding
      }
    }
  }
  let tag_bytes = serialize_tag(major, frame_blobs, padding, revision)
  let audio = slice_bytes(data, audio_start, data.length())
  tag_bytes.add(audio)
}

///|
/// 标签体长度（不含 10 字节头，也不含 footer）。
fn tag_body_len(tag : Id3Tag) -> Int32 {
  let has_footer = tag.major == 4 && (tag.flags & 0x10) != 0
  let total = tag.total_size - 10 - (if has_footer { 10 } else { 0 })
  if total < 0 {
    0
  } else {
    total
  }
}
