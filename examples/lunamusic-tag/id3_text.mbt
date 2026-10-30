// id3_text.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 id3_text.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE。本仓库只做按需裁剪，
// 未改动实现；裁剪清单与上游出处见本目录 README.md。
//
// ID3v2 的文本编码处理。
//
// 编码字节（帧载荷第一个字节）：
//   $00 ISO-8859-1，$00 终止
//   $01 UTF-16（带 BOM），$00 00 终止
//   $02 UTF-16BE（无 BOM），$00 00 终止
//   $03 UTF-8，$00 终止
//
// 规范允许一个文本帧内含多个以终止符分隔的字符串（v2.4 的多值语义），
// 所以这里提供"按编码切分字符串"的统一入口，而不是只解第一段。

///|
/// 文本编码枚举。
pub enum TextEncoding {
  /// `$00` ISO-8859-1
  Latin1
  /// `$01` UTF-16 with BOM
  Utf16Bom
  /// `$02` UTF-16BE without BOM
  Utf16Be
  /// `$03` UTF-8
  Utf8
}

///|
/// 把编码字节转成枚举；未知编码抛错。
pub fn TextEncoding::from_code(code : Int32) -> TextEncoding raise TagError {
  match code {
    0 => Latin1
    1 => Utf16Bom
    2 => Utf16Be
    3 => Utf8
    _ =>
      raise BadFrameData(
        frame_id="",
        reason="未知的文本编码字节 \{code}",
      )
  }
}

///|
/// 编码字节（写入用）。
pub fn TextEncoding::code(self : TextEncoding) -> Int32 {
  match self {
    Latin1 => 0
    Utf16Bom => 1
    Utf16Be => 2
    Utf8 => 3
  }
}

///|
/// 该编码的终止符长度：Latin1/UTF-8 为 1 字节，两种 UTF-16 为 2 字节。
pub fn TextEncoding::terminator_len(self : TextEncoding) -> Int32 {
  match self {
    Latin1 | Utf8 => 1
    Utf16Bom | Utf16Be => 2
  }
}

///|
/// 解码单个字符串（不含终止符）。非法序列按替换字符处理，不抛错——
/// 标签里存在历史遗留的坏字节是常态，读取侧应尽量给出可显示结果。
pub fn TextEncoding::decode(self : TextEncoding, bytes : BytesView) -> String {
  match self {
    Latin1 => latin1_decode(bytes)
    Utf8 => @utf8.decode_lossy(bytes)
    Utf16Be => @utf16.decode_lossy(bytes, ignore_bom=true, endianness=Big)
    Utf16Bom =>
      // BOM 决定字节序；缺失时按小端处理（历史实现的实际做法）。
      if bytes.length() >= 2 && bytes.at(0) == b'\xFF' && bytes.at(1) == b'\xFE' {
        @utf16.decode_lossy(bytes, ignore_bom=true, endianness=Little)
      } else if bytes.length() >= 2 &&
        bytes.at(0) == b'\xFE' &&
        bytes.at(1) == b'\xFF' {
        @utf16.decode_lossy(bytes, ignore_bom=true, endianness=Big)
      } else {
        @utf16.decode_lossy(bytes, ignore_bom=false, endianness=Little)
      }
  }
}

///|
/// ISO-8859-1 → Unicode：逐字节取码点，无需查表。
fn latin1_decode(bytes : BytesView) -> String {
  let buf = StringBuilder()
  for i in 0..<bytes.length() {
    buf.write_char(Int32::unsafe_to_char(bytes.at(i).to_int()))
  }
  buf.to_string()
}

///|
/// 在 `start` 之后找第一个字符串终止符的位置（不含终止符本身）。
///
/// UTF-16 需要按 2 字节对齐搜索，否则会在字符中间误判。
fn find_terminator(
  data : BytesView,
  start : Int32,
  encoding : TextEncoding,
  end : Int32,
) -> Int32 {
  match encoding {
    Latin1 | Utf8 => {
      let mut i = start
      while i < end {
        if data.at(i) == b'\x00' {
          return i
        }
        i += 1
      }
      end
    }
    Utf16Bom | Utf16Be => {
      let mut i = start
      while i + 1 < end {
        if data.at(i) == b'\x00' && data.at(i + 1) == b'\x00' {
          return i
        }
        i += 2
      }
      end
    }
  }
}

///|
/// 按编码把一段载荷切分为多个字符串。
///
/// 末尾的空串（终止符之后的尾随填充）会被丢弃。返回值保留原始顺序。
pub fn split_strings(
  data : BytesView,
  encoding : TextEncoding,
  start : Int32,
  end : Int32,
) -> Array[String] {
  let out : Array[String] = []
  let term = encoding.terminator_len()
  let mut pos = start
  while pos < end {
    let stop = find_terminator(data, pos, encoding, end)
    // 全零剩余视为填充，不再产出空串
    let text = encoding.decode(data.exact_view(start=pos, end=stop))
    out.push(text)
    pos = stop + term
    if stop >= end {
      break
    }
  }
  // 去掉尾部空字符串（终止符后的填充区）
  while out.length() > 0 && out[out.length() - 1] == "" {
    let _ = out.pop()
  }
  out
}
