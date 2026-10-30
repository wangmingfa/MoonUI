// mp4_ilst.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 mp4_ilst.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE。本仓库只做按需裁剪，
// 未改动实现；裁剪清单与上游出处见本目录 README.md。
//
// MP4/M4A 的 iTunes 风格标签（`moov/udta/meta/ilst`）读写。
//
// 路径：moov → udta → meta（FullBox，4 字节 version/flags 之后才是子盒）→ ilst
//
// ilst 的每个条目是"用标签名当盒类型"的容器盒：
//   ilst → ©nam → data（FullBox：type + locale + 载荷）
//
// `meta` 是唯一一个"盒子套盒子但中间多了 4 字节"的结构——这是 MP4 解析
// 最常见的坑，漏掉这 4 字节会让后面全部错位。

///|
/// 一个 MP4 盒：类型码 + 在文件中的区间。
pub struct Mp4Box {
  /// 4 字符类型码（如 `moov`、`©nam`）。
  kind : String
  /// 盒载荷起点（不含 8 字节头）。
  offset : Int32
  /// 盒载荷长度。
  length : Int32
  /// 盒在文件中的起点（含头）。
  start : Int32
}

///|
/// 读 4 字节类型码。
fn mp4_type(data : BytesView, pos : Int32) -> String {
  let buf = StringBuilder()
  for i in 0..<4 {
    buf.write_char(Int32::unsafe_to_char(data.at(pos + i).to_int()))
  }
  buf.to_string()
}

///|
/// 在 `[start, end)` 区间内枚举同级盒。
fn list_boxes(
  data : BytesView,
  start : Int32,
  end : Int32,
) -> Array[Mp4Box] raise TagError {
  let out : Array[Mp4Box] = []
  let mut pos = start
  while pos + 8 <= end {
    let size = read_be(data, pos, 4)
    let kind = mp4_type(data, pos + 4)
    // size==0 表示"到文件结尾"；size==1 表示 64 位长度（本实现不支持）
    let (actual_size, header) = if size == 0 {
      (end - pos, 8)
    } else if size == 1 {
      raise Unsupported(what="MP4 盒使用 64 位长度")
    } else {
      (size, 8)
    }
    if actual_size < header || pos + actual_size > end {
      raise BadHeader(reason="MP4 盒 \{kind} 尺寸 \{actual_size} 越界")
    }
    out.push({
      kind,
      offset: pos + header,
      length: actual_size - header,
      start: pos,
    })
    pos += actual_size
  }
  out
}

///|
/// 在盒列表里找第一个指定类型；找不到返回 `None`。
fn find_box(boxes : Array[Mp4Box], kind : String) -> Mp4Box? {
  for b in boxes {
    if b.kind == kind {
      return Some(b)
    }
  }
  None
}

///|
/// 定位 ilst 盒；文件没有返回 `None`。
pub fn find_ilst(data : BytesView) -> Mp4Box? raise TagError {
  let top = list_boxes(data, 0, data.length())
  let moov = match find_box(top, "moov") {
    None => return None
    Some(b) => b
  }
  let moov_children = list_boxes(data, moov.offset, moov.offset + moov.length)
  let udta = match find_box(moov_children, "udta") {
    None => return None
    Some(b) => b
  }
  let udta_children = list_boxes(data, udta.offset, udta.offset + udta.length)
  let meta = match find_box(udta_children, "meta") {
    None => return None
    Some(b) => b
  }
  // meta 是 FullBox：载荷前 4 字节是 version(1) + flags(3)，子盒从 +4 开始
  let meta_children = list_boxes(
    data,
    meta.offset + 4,
    meta.offset + meta.length,
  )
  find_box(meta_children, "ilst")
}

///|
/// 一个 iTunes 标签条目。
pub struct Mp4Tag {
  /// 键（如 `©nam`，其中 © 是 0xA9）。
  key : String
  /// 值字节（data 盒里去掉 type/locale 之后的部分）。
  value : Bytes
  /// data 盒的 type 字段（1=UTF-8 文本，13/14=JPEG/PNG 封面等）。
  data_type : Int32
}

///|
/// 解析 ilst 下全部条目。
pub fn parse_ilst(
  data : BytesView,
  ilst : Mp4Box,
) -> Array[Mp4Tag] raise TagError {
  let entries = list_boxes(data, ilst.offset, ilst.offset + ilst.length)
  let out : Array[Mp4Tag] = []
  for e in entries {
    // 每个条目是容器盒，里面应当有一个 data 盒
    let children = list_boxes(data, e.offset, e.offset + e.length) catch {
      _ => continue
    }
    let data_box = match find_box(children, "data") {
      None => continue
      Some(b) => b
    }
    // data 盒：version(1)+flags(3) 共 4 字节（type 就在 flags 里），
    // 然后是 locale(4)，之后才是值。
    if data_box.length < 8 {
      continue
    }
    let data_type = read_be(data, data_box.offset + 1, 3)
    let value_start = data_box.offset + 8
    let value = slice_bytes(
      data,
      value_start,
      data_box.offset + data_box.length,
    )
    out.push({ key: e.kind, value, data_type, })
  }
  out
}

///|
/// 取文本类型的标签值。
pub fn text_of(entries : Array[Mp4Tag], key : String) -> String? {
  for e in entries {
    if e.key == key {
      return Some(@utf8.decode_lossy(e.value.exact_view()))
    }
  }
  None
}

///|
/// 取第一个封面（data type 13=JPEG、14=PNG）。
pub fn cover_of(entries : Array[Mp4Tag]) -> Bytes? {
  for e in entries {
    if e.key == "covr" {
      return Some(e.value)
    }
  }
  None
}

///|
/// 读 MP4 文件的全部 ilst 条目；没有则返回空数组。
pub fn read_mp4_tags(data : BytesView) -> Array[Mp4Tag] raise TagError {
  match find_ilst(data) {
    None => []
    Some(ilst) => parse_ilst(data, ilst)
  }
}
