// flac_meta.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 flac_meta.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE。本仓库只做按需裁剪，
// 未改动实现；裁剪清单与上游出处见本目录 README.md。
//
// FLAC 元数据块链的解析与重写（F4 的基础）。
//
// 结构：`fLaC` 魔数 + 一个或多个元数据块 + 音频帧。
// 每个块头 4 字节：1 位"是否最后一个块" + 7 位块类型 + 24 位大端长度。
//
// 本文件只负责"块链"这一层；VORBIS_COMMENT 的载荷语义在 vorbis_comment.mbt。

///|
/// FLAC 元数据块类型码。
pub enum FlacBlockType {
  StreamInfo
  Padding
  Application
  SeekTable
  VorbisComment
  CueSheet
  Picture
  /// 4..126 为保留区，原样保留。
  Reserved
  /// 127 为非法值。
  Invalid
}

///|
/// 元数据块类型码 → 枚举。
pub fn FlacBlockType::from_code(code : Int32) -> FlacBlockType {
  match code {
    0 => StreamInfo
    1 => Padding
    2 => Application
    3 => SeekTable
    4 => VorbisComment
    5 => CueSheet
    6 => Picture
    127 => Invalid
    _ => Reserved
  }
}

///|
/// 一个元数据块（位置 + 类型，载荷按需切片）。
pub struct FlacBlock {
  /// 块类型码（原始值）。
  code : Int32
  /// 相对文件起始的载荷偏移。
  offset : Int32
  /// 载荷长度。
  length : Int32
  /// 是否为最后一个元数据块。
  is_last : Bool
}

///|
/// 元数据块链解析结果。
pub struct FlacMeta {
  /// 全部元数据块（含 STREAMINFO，按文件顺序）。
  blocks : Array[FlacBlock]
  /// 第一个音频帧的偏移。
  audio_offset : Int32
}

///|
/// 解析 FLAC 元数据块链。
///
/// 注意 7..126 是**保留**类型而非非法类型：RFC 9639 只把 127 定为 forbidden，
/// 保留类型应当跳过而不是报错（xiph 官方测试集里确有此类文件）。
pub fn parse_meta(data : BytesView) -> FlacMeta raise TagError {
  if data.length() < 4 {
    raise Truncated(offset=0, need=4, actual=data.length())
  }
  if data.at(0) != b'f' ||
    data.at(1) != b'L' ||
    data.at(2) != b'a' ||
    data.at(3) != b'C' {
    raise NotTagged(format="flac")
  }
  let blocks : Array[FlacBlock] = []
  let mut pos = 4
  let mut last = false
  while !last {
    require_range(data, pos, 4)
    let first = data.at(pos).to_int()
    last = (first & 0x80) != 0
    let code = first & 0x7F
    if code == 127 {
      raise BadHeader(reason="FLAC 元数据块类型 127 为禁用值")
    }
    let len = read_be(data, pos + 1, 3)
    let payload_off = pos + 4
    require_range(data, payload_off, len)
    blocks.push({ code, offset: payload_off, length: len, is_last: last, })
    pos = payload_off + len
  }
  { blocks, audio_offset: pos, }
}

///|
/// 取第一个指定类型的块。
pub fn FlacMeta::block(self : FlacMeta, type_ : FlacBlockType) -> FlacBlock? {
  let code = type_.code()
  for b in self.blocks {
    if b.code == code {
      return Some(b)
    }
  }
  None
}

///|
/// 块类型枚举 → 类型码。
pub fn FlacBlockType::code(self : FlacBlockType) -> Int32 {
  match self {
    StreamInfo => 0
    Padding => 1
    Application => 2
    SeekTable => 3
    VorbisComment => 4
    CueSheet => 5
    Picture => 6
    Reserved => 7
    Invalid => 127
  }
}
