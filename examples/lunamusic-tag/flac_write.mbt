// flac_write.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 flac_write.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE。本仓库只做按需裁剪，
// 未改动实现；裁剪清单与上游出处见本目录 README.md。
//
// FLAC 元数据块链的重写（F4 写入侧）。
//
// 策略：重新拼出整个元数据区，然后追加原音频帧。
// padding 复用是这里的关键：FLAC 文件通常预留一块 PADDING 用于标签编辑，
// 若不复用，每次改标签都会让整个音频区平移——播放器 seek 位置、
// 增量同步工具都会被打乱，文件也会越来越大。

///|
/// 用新的 Vorbis Comment 重写 FLAC 文件。
///
/// 原文件没有 VORBIS_COMMENT 块时插入到 STREAMINFO 之后（规范建议位置）。
pub fn set_vorbis_comment(
  data : BytesView,
  vc : VorbisComment,
) -> Bytes raise TagError {
  let meta = parse_meta(data)
  let payload = serialize_vorbis_comment(vc)
  // 收集保留块（除 VORBIS_COMMENT 外的全部），按原顺序
  let kept : Array[(Int32, Bytes)] = []
  let mut comment_index = -1
  for b in meta.blocks {
    if b.code == 4 {
      if comment_index < 0 {
        comment_index = kept.length()
        kept.push((4, payload))
      }
    } else if b.code == 1 {
      // PADDING 先记下总长度，最后统一重算
      kept.push((1, Bytes::new(0)))
    } else {
      kept.push((b.code, slice_bytes(data, b.offset, b.offset + b.length)))
    }
  }
  if comment_index < 0 {
    // 没有 COMMENT 块：插到 STREAMINFO（第一个块）之后
    let out : Array[(Int32, Bytes)] = []
    out.push(kept[0])
    out.push((4, payload))
    for i in 1..<kept.length() {
      out.push(kept[i])
    }
    return assemble_flac(out, data, meta)
  }
  assemble_flac(kept, data, meta)
}

///|
/// 按 padding 预算拼装并输出 FLAC 字节。
///
/// 预算 = 原元数据区总字节数。若新块链比预算小，差额补进 PADDING 块
/// （没有 PADDING 块就在末尾追加一个），从而**音频区完全不动**；
/// 若超出预算，则清空 PADDING 并接受音频区后移。
fn assemble_flac(
  blocks : Array[(Int32, Bytes)],
  data : BytesView,
  meta : FlacMeta,
) -> Bytes raise TagError {
  // 原元数据区大小 = 音频起点 - 4 字节魔数
  let budget = meta.audio_offset - 4
  // 先算出不含 padding 载荷时各块占用的字节数
  let mut used = 0
  let mut has_padding = false
  for pair in blocks {
    let (code, payload) = pair
    used += 4 + payload.length()
    if code == 1 {
      has_padding = true
    }
  }
  // padding 载荷大小：预算富余量（块头 4 字节也要算进去）
  let mut padding_len = if budget >= used { budget - used } else { 0 }
  let out : Array[(Int32, Bytes)] = []
  if has_padding {
    for pair in blocks {
      let (code, payload) = pair
      if code == 1 {
        // 单个 PADDING 块吃掉全部富余量
        out.push((1, Bytes::make(padding_len, b'\x00')))
        padding_len = 0
      } else {
        out.push((code, payload))
      }
    }
  } else if padding_len >= 4 {
    // 没有 PADDING 块但有富余：追加一个，让下次编辑也能原地进行
    for pair in blocks {
      out.push(pair)
    }
    out.push((1, Bytes::make(padding_len - 4, b'\x00')))
  } else {
    for pair in blocks {
      out.push(pair)
    }
  }
  emit_flac(out, data, meta.audio_offset)
}

///|
/// 拼 FLAC 字节：`fLaC` + 块链 + 原音频。
///
/// 块头 4 字节：last 位 + 7 位类型码 + 24 位大端长度。
fn emit_flac(
  blocks : Array[(Int32, Bytes)],
  data : BytesView,
  audio_offset : Int32,
) -> Bytes raise TagError {
  let out = @buffer.Buffer()
  out.write_byte(b'f')
  out.write_byte(b'L')
  out.write_byte(b'a')
  out.write_byte(b'C')
  for i, (code, payload) in blocks {
    let is_last = i == blocks.length() - 1
    let first = if is_last { 0x80 | code } else { code }
    out.write_byte(first.to_byte())
    let n = payload.length()
    if n > 0xFFFFFF {
      raise Unsupported(what="元数据块长度 \{n} 超出 24 位上限")
    }
    out.write_byte(((n >> 16) & 0xFF).to_byte())
    out.write_byte(((n >> 8) & 0xFF).to_byte())
    out.write_byte((n & 0xFF).to_byte())
    out.write_bytes(payload)
  }
  // 音频数据原样追加
  let audio = slice_bytes(data, audio_offset, data.length())
  out.write_bytes(audio)
  out.to_bytes()
}

///|
/// 读 FLAC 文件里的 Vorbis Comment；没有该块时返回 `None`。
pub fn read_vorbis_comment(data : BytesView) -> VorbisComment? raise TagError {
  let meta = parse_meta(data)
  match meta.block(FlacBlockType::VorbisComment) {
    None => None
    Some(b) =>
      Some(
        parse_vorbis_comment(
          data.exact_view(start=b.offset, end=b.offset + b.length),
        ),
      )
  }
}
