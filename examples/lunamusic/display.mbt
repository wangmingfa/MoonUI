///|
/// 界面上「歌名/歌手」这两格从哪儿取（`T193`）。
///
/// owner 2026-11-02 点的：探针修好之后标签里有真值了，但**默认仍按文件名显示**
/// ——下载来的文件命名本身就带着「歌手-歌名」的信息，而且和用户当初存文件时
/// 看到的样子一致；标签值五花八门（有的带 `(silence)`、有的整串乱码修不好），
/// 一上来就换成标签反而认不出是哪首。想换成标签的，在「控制 → 歌曲信息显示」
/// 里点一下，选择落在 `Prefs` 里（`C-07` 的状态账）。
///
/// 这一层只管**展示**：`Track` 里存的始终是探针读到的真值，排序、搜索、
/// 属性栏里的路径、写标签、在线取词都不受影响——换个显示口径不该改变任何
/// 数据口径。
#derive(Debug, Eq)
pub(all) enum DisplaySource {
  /// 只认文件名（默认）
  FileName
  /// 认探针读到的标签
  Tags
}

///|
/// 默认口径：文件名。不叫 `default` 是为了不跟 `Default` trait 的方法撞名。
pub fn cm_display_source_default() -> DisplaySource {
  FileName
}

///|
/// 菜单文案。
pub fn DisplaySource::label(self : DisplaySource) -> String {
  match self {
    FileName => "文件名"
    Tags => "标签信息"
  }
}

///|
/// 存档键。用可读字符串而不是序数：偏好档是给人看/手改的，`"filename"` 比
/// `0` 自解释（`mode` 那个用序数是历史包袱，不再扩）。
pub fn DisplaySource::key(self : DisplaySource) -> String {
  match self {
    FileName => "filename"
    Tags => "tags"
  }
}

///|
/// 坏值/未知键回 `None`，调用方按默认起步。
pub fn DisplaySource::of_key(s : String) -> DisplaySource? {
  match s {
    "filename" => Some(FileName)
    "tags" => Some(Tags)
    _ => None
  }
}

///|
/// 展示用的（歌名, 歌手）。两格都可能为空串——调用方按「空就不画这段」处理。
///
/// 「文件名」那一支复用在线取词那侧的 `tag_filename_readings`
/// （`tag.mbt`）：同一套切分规则，两处显示才和「机器替我挑的查询词」一致。
/// 文件名给不出歌手（只有一段）时歌手就是空串——**不留「未知」**：那是标签
/// 缺失的哨兵，"文件名里本来没有歌手"是另一件事，硬写「未知」等于假装查过。
pub fn cm_display_fields(t : Track, source : DisplaySource) -> (String, String) {
  let file_name = cm_file_name(t.path)
  let stem = cm_strip_extension(file_name)
  match source {
    FileName =>
      match tag_filename_readings(file_name) {
        [] => (stem, "")
        [first, ..] => first
      }
    Tags => {
      // 标题等于文件名去扩展名 = 探针没读出标题，这个值是 `Track::from_path`
      // 的兜底而不是标签（判据与 `tag_query_candidates` 同一条）。
      let title = if tag_field_missing(t.title) ||
        @util.same_text_ci(t.title, stem) {
        stem
      } else {
        @util.trim_ws(t.title)
      }
      let artist = if tag_field_missing(t.artist) {
        ""
      } else {
        @util.trim_ws(t.artist)
      }
      (title, artist)
    }
  }
}

///|
/// 展示用的专辑名。「文件名」那一支恒空——文件名里没有专辑这一格，从别处
/// 猜会把播放条那一行塞满噪音。
pub fn cm_display_album(t : Track, source : DisplaySource) -> String {
  match source {
    FileName => ""
    Tags => if tag_field_missing(t.album) { "" } else { @util.trim_ws(t.album) }
  }
}

///|
/// 把非空的几段用 ` - ` 接起来（播放条那行的「歌手 - 专辑」、歌词窗顶的
/// 「歌名 - 歌手」都是这个形状）。全空返回空串，调用方据此留白而不是画一根
/// 光秃秃的横杠。
pub fn cm_join_meta(a : String, b : String) -> String {
  if a == "" {
    b
  } else if b == "" {
    a
  } else {
    "\{a} - \{b}"
  }
}

///|
/// 占位封面：没有专辑封面时灌给播放条那张 `Image` 的图——一块与脸面
/// 同色调的渐变底、中间一只唱盘（亮环 + 提亮的盘面 + 压暗的中心孔），
/// 显示尺寸与封面框 1:1。取代 `T174` 的 1×1 全透明 PNG：透明图是"把上一首
/// 盖掉"的正确答案（`Image` 的源是整源替换语义，不动就一直是上一张，
/// 比空白更糟），但盖掉之后那格空着，没有封面的歌看上去像脸面缺了一块；
/// 画一只唱盘，"这里是封面位"这件事自己会说。
///
/// **位图按 2x 渲染（112×112，显示仍是 56pt）**：56×56 的位图在 Retina 屏
/// 上被拉伸到 112 物理像素，插值出来就是一团糊（owner 2026-11-04 截图钉出
/// 来的）；真封面都是几百像素宽缩下来显示，占位图同一条道理。2x 后原始
/// 37744 字节仍 < 65535，一条 stored block 装下（3x 就得拆多块，不值）。
///
/// 运行时生成而不是手写字节串：底色取自**当前皮肤**（face_top /
/// face_bottom / text_light），换肤后占位图跟着换——这是字节串做不到的。
/// PNG 走最简单的存储型 deflate，不引 zlib 依赖；CRC-32 自己写——
/// `ogg_crc32` 是 Ogg 的 MSB-first 变体（初始 0、无终异或），与 PNG 的
/// zlib CRC-32 不是同一只，不能复用。每次换曲至多生成一次，成本在毫秒
/// 以下，不缓存。
pub fn cm_placeholder_cover() -> Bytes {
  let size = 112
  let top = cm_skin_current().face_top
  let bottom = cm_skin_current().face_bottom
  let ring = cm_skin_current().text_light
  let c = (size - 1).to_double() / 2.0
  // 判定阈值全部用半径平方，不引 @math（sqrt 在这没有别的消费者）。
  // 半径是 56pt 口径下 4 / 13 / 15.5 的 2x。
  let r_hole = 8.0 * 8.0
  let r_disc = 26.0 * 26.0
  let r_ring = 31.0 * 31.0
  // 逐行：filter 0 + 逐像素 RGB。背景是垂直渐变，像素级再按唱盘三档覆盖。
  let raw : Array[Byte] = []
  for y = 0; y < size; y = y + 1 {
    raw.push(b'\x00')
    let t = y.to_double() / (size - 1).to_double()
    let br = cm_mix8(top >> 16, bottom >> 16, t)
    let bg = cm_mix8((top >> 8) & 0xFF, (bottom >> 8) & 0xFF, t)
    let bb = cm_mix8(top & 0xFF, bottom & 0xFF, t)
    for x = 0; x < size; x = x + 1 {
      let dx = x.to_double() - c
      let dy = y.to_double() - c
      let d2 = dx * dx + dy * dy
      let px = if d2 <= r_hole {
        // 中心孔：背景压暗 35%
        (br * 65 / 100, bg * 65 / 100, bb * 65 / 100)
      } else if d2 < r_disc {
        // 盘面：背景提亮 12%
        (
          br + (255 - br) * 12 / 100,
          bg + (255 - bg) * 12 / 100,
          bb + (255 - bb) * 12 / 100,
        )
      } else if d2 <= r_ring {
        // 亮环：文字亮色
        ((ring >> 16) & 0xFF, (ring >> 8) & 0xFF, ring & 0xFF)
      } else {
        (br, bg, bb)
      }
      let (pr, pg, pb) = px
      raw.push(pr.to_byte())
      raw.push(pg.to_byte())
      raw.push(pb.to_byte())
    }
  }
  // zlib 流：header + 一条 final stored block + adler32
  let z : Array[Byte] = []
  z.push(b'\x78')
  z.push(b'\x01')
  let n = raw.length()
  z.push(b'\x01')
  z.push((n & 0xFF).to_byte())
  z.push(((n >> 8) & 0xFF).to_byte())
  let nlen = 65535 - n
  z.push((nlen & 0xFF).to_byte())
  z.push(((nlen >> 8) & 0xFF).to_byte())
  for byt in raw {
    z.push(byt)
  }
  let ad = cm_adler32(raw)
  z.push(((ad >> 24) & 0xFF).to_byte())
  z.push(((ad >> 16) & 0xFF).to_byte())
  z.push(((ad >> 8) & 0xFF).to_byte())
  z.push((ad & 0xFF).to_byte())
  // PNG 装配：签名 + IHDR + IDAT + IEND
  let sig : Array[Byte] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].map(fn(
    v,
  ) {
    v.to_byte()
  })
  let ihdr : Array[Byte] = []
  for b in cm_png_be32(size) {
    ihdr.push(b)
  }
  for b in cm_png_be32(size) {
    ihdr.push(b)
  }
  for v in [8, 2, 0, 0, 0] {
    ihdr.push(v.to_byte())
  }
  let out : Array[Byte] = []
  for b in sig {
    out.push(b)
  }
  for b in cm_png_chunk("IHDR", ihdr) {
    out.push(b)
  }
  for b in cm_png_chunk("IDAT", z) {
    out.push(b)
  }
  for b in cm_png_chunk("IEND", []) {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// 两色按 t（0..1）线性插值取整（0xRRGGBB 的单通道，0..255）。
fn cm_mix8(a : Int32, b : Int32, t : Double) -> Int32 {
  (a.to_double() * (1.0 - t) + b.to_double() * t + 0.5).to_int()
}

///|
/// 32 位大端四字节。
fn cm_png_be32(v : Int32) -> Array[Byte] {
  [
    ((v >> 24) & 0xFF).to_byte(),
    ((v >> 16) & 0xFF).to_byte(),
    ((v >> 8) & 0xFF).to_byte(),
    (v & 0xFF).to_byte(),
  ]
}

///|
/// zlib/ADLER-32（RFC 1950）：s1/s2 模 65521，大端两段拼一个 32 位。
fn cm_adler32(data : Array[Byte]) -> Int32 {
  let mut a = 1
  let mut b = 0
  for byt in data {
    a = (a + (byt.to_int() & 0xFF)) % 65521
    b = (b + a) % 65521
  }
  (b << 16) | a
}

///|
/// PNG chunk：长度（BE）+ 类型 + 数据 + CRC-32（对类型 + 数据算）。
fn cm_png_chunk(kind : String, data : Array[Byte]) -> Array[Byte] {
  let out : Array[Byte] = []
  let n = data.length()
  for b in cm_png_be32(n) {
    out.push(b)
  }
  let crc_in : Array[Byte] = []
  for i = 0; i < kind.length(); i = i + 1 {
    let code = @utf8.encode(kind)[i].to_int()
    crc_in.push(code.to_byte())
    out.push(code.to_byte())
  }
  for byt in data {
    crc_in.push(byt)
    out.push(byt)
  }
  // 反射 CRC-32：初值/终值全 1，多项式 0xEDB88320。
  // `Int` 是 32 位有符号——初值 0xFFFFFFFF 就是 -1，`>>` 是**算术**右移
  // （符号位保留），移出来的全是 1，CRC 直接算歪（owner 2026-11-04 真机
  // 空白钉出来的：ImageIO 校验 CRC 不过就拒解）。右移后掩掉符号位，等价
  // 逻辑右移；判据侧另有 "123456789" → 0xCBF43926 的金标向量锚着。
  let mut c = 0xFFFFFFFF
  for byt in crc_in {
    c = c ^ (byt.to_int() & 0xFF)
    for bit = 0; bit < 8; bit = bit + 1 {
      c = if (c & 1) != 0 {
        ((c >> 1) & 0x7FFFFFFF) ^ 0xEDB88320
      } else {
        (c >> 1) & 0x7FFFFFFF
      }
    }
  }
  let crc = c ^ 0xFFFFFFFF
  for b in cm_png_be32(crc) {
    out.push(b)
  }
  out
}

///|
/// 播放失败的一句话（`T186`）——喂给播放条那行「状态: xxx」。
///
/// 在此之前这些失败**一句人话都没有**：格式不支持（`T166` 的 ogg）、文件被
/// 删、文件损坏，界面上都是"点了没反应"，用户只能怀疑自己点错了。
///
/// `name_of` 由调用方给（拿 path 换成当前显示口径下的名字）：这一层不该知道
/// 曲库/队列长什么样，而 `Player` 也不该知道 `DisplaySource` 选的是哪个——两边
/// 各自只守自己那份。
///
/// 文案压到最短（9pt 的 Label，右面还挨着频谱与走带），`⚠` 打头让它在"状态:
/// 播放"那一列里一眼能认出来不是正常状态。
pub fn cm_player_error_text(
  err : PlayerError,
  name_of : (String) -> String,
) -> String {
  match err {
    LoadFailed(path) => {
      let name = name_of(path)
      if name == "" {
        "⚠ 无法播放"
      } else {
        "⚠ 无法播放：\{name}"
      }
    }
    AllFailed => "⚠ 列表里没有能播放的曲目"
  }
}
