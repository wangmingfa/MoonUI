// mp4_write.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 mp4_write.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE；本仓库只改下述范围：
//   - 抽出 set_mp4_tags_with_delete（上游的 set_mp4_tags 表达不了删除字段，
//     set_mp4_tags 本身行为不变，改为委托给它）
// 除裁剪外未改动实现；上游测试原样保留在 mp4_wbtest.mbt。
//
// MP4 ilst 写入。
//
// 难点在于 moov 的 `udta/meta/ilst` 可能根本不存在：
// 这时要新建整条路径，并把每一层父盒的尺寸重新算对。
// 本实现的做法是"自底向上重算"：只重建从 ilst 到 moov 这条链上的盒，
// 其它同级盒（如 trak、mdat）的原始字节原样保留。

///|
/// 拼一个盒：类型 + 载荷（尺寸自动计算）。
fn make_box(kind : String, payload : Bytes) -> Bytes {
  let total = payload.length() + 8
  let out = @buffer.Buffer()
  out.write_bytes(write_u32be(total))
  for c in kind {
    out.write_byte(c.to_int().to_byte())
  }
  out.write_bytes(payload)
  out.to_bytes()
}

///|
/// 对一个 ilst 条目（如 `©nam`）构造完整字节。
///
/// `data` 盒结构：version(1 字节) + **flags(3 字节，高 8 位存 data type)**
/// + locale(4 字节) + 值。注意 type 在 flags 的**最低字节**，不是单独的 4 字节
/// ——多写 4 字节会让后续所有解析错位，且播放器读出空值。
fn make_ilst_entry(key : String, data_type : Int32, value : Bytes) -> Bytes {
  let data_box = @buffer.Buffer()
  // version = 0，flags 低 8 位 = data type
  data_box.write_byte(b'\x00')
  data_box.write_byte(b'\x00')
  data_box.write_byte(b'\x00')
  data_box.write_byte((data_type & 0xFF).to_byte())
  data_box.write_bytes(write_u32be(0)) // locale
  data_box.write_bytes(value)
  let data_bytes = make_box("data", data_box.to_bytes())
  make_box(key, data_bytes)
}

///|
/// 拼一个新的 ilst 盒。
fn make_ilst(entries : Array[Bytes]) -> Bytes {
  let inner = @buffer.Buffer()
  for e in entries {
    inner.write_bytes(e)
  }
  make_box("ilst", inner.to_bytes())
}

///|
/// 用一批条目重写 MP4 文件的 ilst。
///
/// `updates` 是按 key 的完整替换（同 key 会被整体替换，不会叠加）；
/// 未在 `updates` 里出现的既有条目原样保留。
/// 返回完整的新文件字节。
pub fn set_mp4_tags(
  data : BytesView,
  updates : Array[Mp4Tag],
) -> Bytes raise TagError {
  set_mp4_tags_with_delete(data, updates, [])
}

///|
/// 同 `set_mp4_tags`，但额外按 key 删除条目。
///
/// vendored 新增（上游没有）：上游的 `set_mp4_tags` 只能"写入或替换"，
/// 表达不了"清空这个字段"——而另外三种容器（ID3v2 的 `set_fields`、
/// FLAC/Ogg 的 `VorbisComment::set_key`）都能用空串删除。lunamusic 要求
/// 四种格式的"清空字段 = 删除"语义一致，故补这一个入口；
/// `deletes` 里的 key 先被丢掉，`updates` 里同名 key 仍会写回。
pub fn set_mp4_tags_with_delete(
  data : BytesView,
  updates : Array[Mp4Tag],
  deletes : Array[String],
) -> Bytes raise TagError {
  // 收集既有条目
  let existing = read_mp4_tags(data)
  let final_entries : Array[Mp4Tag] = []
  for e in existing {
    let mut replaced = false
    for u in updates {
      if u.key == e.key {
        replaced = true
      }
    }
    for d in deletes {
      if d == e.key {
        replaced = true
      }
    }
    if !replaced {
      final_entries.push(e)
    }
  }
  for u in updates {
    final_entries.push(u)
  }
  // 拼新 ilst
  let entry_bytes : Array[Bytes] = []
  for e in final_entries {
    entry_bytes.push(make_ilst_entry(e.key, e.data_type, e.value))
  }
  let new_ilst = make_ilst(entry_bytes)
  // 重建 moov/udta/meta 链
  rebuild_moov(data, new_ilst)
}

///|
/// 重建 moov：替换其中的 udta/meta/ilst，其余盒原样保留。
///
/// **媒体定位保持**：若 moov 在 mdat 之前（faststart 布局），moov 变长会让
/// mdat 后移，此时 stco/co64 里的绝对 chunk offset 必须同步增加 delta，
/// 否则播放器读到错位字节（实测：标签增长后 ffmpeg 报
/// `Error submitting packet to decoder`）。moov 在 mdat 之后时 mdat 不动，
/// 无需修正。
fn rebuild_moov(data : BytesView, new_ilst : Bytes) -> Bytes raise TagError {
  let top = list_boxes(data, 0, data.length())
  // fragmented MP4 的 chunk 位置记在 moof/traf/trun（及 tfhd 的 base_data_offset），
  // 不在 stco/co64 里。本实现不维护这些偏移，必须**明确拒绝**——静默改写会产出
  // 能通过解析、但音频已损坏的文件（实测 ffmpeg 报 "Error submitting packet to decoder"）。
  for b in top {
    if b.kind == "moof" {
      raise Unsupported(what="fragmented MP4（moof）的标签改写")
    }
  }
  // 找 mdat 位置（判断 moov 是否在 mdat 之前）
  let mut first_mdat_start = -1
  for b in top {
    if b.kind == "mdat" {
      first_mdat_start = b.start
      break
    }
  }
  let out = @buffer.Buffer()
  let mut found_moov = false
  for b in top {
    if b.kind == "moov" {
      found_moov = true
      let old_moov_total = b.length + 8
      let moov_children = list_boxes(data, b.offset, b.offset + b.length)
      // moov 里有 mvex 也是 fragmented MP4 的标志（空 moov + moof 序列）
      if find_box(moov_children, "mvex") is Some(_) {
        raise Unsupported(what="fragmented MP4（mvex）的标签改写")
      }
      // 处理 udta
      let new_udta = match find_box(moov_children, "udta") {
        None => make_box("udta", make_meta_with_ilst(new_ilst))
        Some(udta) => {
          let udta_children = list_boxes(
            data,
            udta.offset,
            udta.offset + udta.length,
          )
          let meta_bytes = match find_box(udta_children, "meta") {
            None => make_meta_with_ilst(new_ilst)
            Some(meta) => {
              let meta_children = list_boxes(
                data,
                meta.offset + 4,
                meta.offset + meta.length,
              )
              // 保留 meta 内除 ilst 外的子盒
              let inner = @buffer.Buffer()
              for c in meta_children {
                if c.kind != "ilst" {
                  inner.write_bytes(
                    slice_bytes(data, c.start, c.start + 8 + c.length),
                  )
                }
              }
              inner.write_bytes(new_ilst)
              // meta 是 FullBox：version/flags 4 字节 + 子盒
              let payload = @buffer.Buffer()
              payload.write_bytes(Bytes::from_array([0x00, 0x00, 0x00, 0x00]))
              payload.write_bytes(inner.to_bytes())
              make_box("meta", payload.to_bytes())
            }
          }
          // udta 内除 meta 外的子盒保留
          let udta_inner = @buffer.Buffer()
          for c in udta_children {
            if c.kind != "meta" {
              udta_inner.write_bytes(
                slice_bytes(data, c.start, c.start + 8 + c.length),
              )
            }
          }
          udta_inner.write_bytes(meta_bytes)
          make_box("udta", udta_inner.to_bytes())
        }
      }
      // moov 内除 udta 外的子盒保留
      let moov_inner = @buffer.Buffer()
      for c in moov_children {
        if c.kind != "udta" {
          moov_inner.write_bytes(
            slice_bytes(data, c.start, c.start + 8 + c.length),
          )
        }
      }
      moov_inner.write_bytes(new_udta)
      let new_moov = make_box("moov", moov_inner.to_bytes())
      let delta = new_moov.length() - old_moov_total
      let moov_before_mdat = first_mdat_start > b.start
      if delta != 0 && moov_before_mdat {
        // moov 变长且在 mdat 之前：修正 stco/co64 的绝对偏移
        let payload = slice_bytes(new_moov.exact_view(), 8, new_moov.length())
        let fixed = fix_offsets_in_tree(
          payload.exact_view(),
          0,
          payload.length(),
          delta,
        )
        out.write_bytes(make_box("moov", fixed))
      } else {
        out.write_bytes(new_moov)
      }
    } else {
      out.write_bytes(slice_bytes(data, b.start, b.start + 8 + b.length))
    }
  }
  if !found_moov {
    raise BadHeader(reason="MP4 文件缺少 moov 盒")
  }
  out.to_bytes()
}

///|
/// 容器盒（可递归进入寻找 stco/co64）。
fn is_container_box(kind : String) -> Bool {
  kind == "moov" ||
  kind == "trak" ||
  kind == "mdia" ||
  kind == "minf" ||
  kind == "stbl"
}

///|
/// 递归重建盒树，遇到 stco/co64 时把每个 chunk offset += delta。
fn fix_offsets_in_tree(
  data : BytesView,
  start : Int32,
  end : Int32,
  delta : Int32,
) -> Bytes raise TagError {
  let boxes = list_boxes(data, start, end)
  let out = @buffer.Buffer()
  for b in boxes {
    if b.kind == "stco" || b.kind == "co64" {
      out.write_bytes(fix_stco_box(data, b, delta))
    } else if is_container_box(b.kind) {
      let inner = fix_offsets_in_tree(
        data,
        b.offset,
        b.offset + b.length,
        delta,
      )
      out.write_bytes(make_box(b.kind, inner))
    } else {
      out.write_bytes(slice_bytes(data, b.start, b.start + 8 + b.length))
    }
  }
  out.to_bytes()
}

///|
/// 修正单个 stco/co64 盒内的偏移条目。
///
/// 结构：size(4) + type(4) + version/flags(4) + entry_count(4) + entries。
/// stco 每条 4 字节 BE u32，co64 每条 8 字节 BE u64。
fn fix_stco_box(
  data : BytesView,
  b : Mp4Box,
  delta : Int32,
) -> Bytes raise TagError {
  let raw = slice_bytes(data, b.start, b.start + 8 + b.length)
  let view = raw.exact_view()
  let entry_count = read_be(view, 12, 4)
  let out = @buffer.Buffer()
  // 复制盒头（size + type + version/flags + entry_count = 16 字节）
  out.write_bytes(slice_bytes(view, 0, 16))
  if b.kind == "stco" {
    for i in 0..<entry_count {
      let offset = read_be(view, 16 + i * 4, 4)
      out.write_bytes(write_u32be(offset + delta))
    }
  } else {
    for i in 0..<entry_count {
      let offset = read_be64(view, 16 + i * 8)
      out.write_bytes(write_be64(offset + Int64::from_int(delta)))
    }
  }
  out.to_bytes()
}

///|
/// 拼一个只含 ilst 的 meta 盒载荷。
fn make_meta_with_ilst(ilst : Bytes) -> Bytes {
  let payload = @buffer.Buffer()
  payload.write_bytes(Bytes::from_array([0x00, 0x00, 0x00, 0x00]))
  payload.write_bytes(make_box("hdlr", mp4_hdlr_payload()))
  payload.write_bytes(ilst)
  make_box("meta", payload.to_bytes())
}

///|
/// 标准的 `mdir` handler 载荷（meta 盒要求有 hdlr）。
fn mp4_hdlr_payload() -> Bytes {
  let out = @buffer.Buffer()
  out.write_bytes(Bytes::from_array([0x00, 0x00, 0x00, 0x00])) // version+flags
  out.write_bytes(Bytes::from_array([0x00, 0x00, 0x00, 0x00])) // pre_defined
  out.write_bytes(Bytes::from_array([0x6D, 0x64, 0x69, 0x72])) // 'mdir'
  out.write_bytes(Bytes::from_array([0x61, 0x70, 0x70, 0x6C])) // 'appl'
  out.write_bytes(Bytes::from_array([0x00, 0x00, 0x00, 0x00])) // reserved
  out.write_bytes(Bytes::from_array([0x00, 0x00, 0x00, 0x00])) // reserved
  out.write_bytes(Bytes::from_array([0x00])) // name（空串 + 终止）
  out.to_bytes()
}

///|
/// 构造一个文本条目。
pub fn mp4_text_tag(key : String, value : String) -> Mp4Tag {
  { key, value: @utf8.encode(value), data_type: 1, }
}

///|
/// 构造一个封面条目（`covr`）；data type：13=JPEG，14=PNG。
pub fn mp4_cover_tag(image : Bytes, is_png : Bool) -> Mp4Tag {
  { key: "covr", value: image, data_type: if is_png { 14 } else { 13 }, }
}
