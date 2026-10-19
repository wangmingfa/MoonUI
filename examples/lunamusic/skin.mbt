///|
/// 皮肤账：一套皮肤 = 一组颜色 token + 一个名字（Luna那套换肤的第二期
/// 形态，第一期的颜色是写死在这文件里的常量）。
///
/// 为什么是「颜色 token」而不是原版那种位图皮肤：MoonUI 的 `Style` 只有纯色
/// 与渐变（无位图），原版 `.skn` 是「zip 改后缀 + 一堆 bmp + 一份配置」的
/// 二进制资源包，这里做不了位图那一层。能做的是**配色可换**：二十一个 token
/// 全覆盖（顶条/脸面/信息条/频谱窗/列表/歌词），换一套就是换一整套配色。
///
/// 皮肤文件格式：JSON 文本，每个 token 是 `"#RRGGBB"`（也认不带 # 的与整数）。
/// 缺字段按默认皮肤补齐——手写半张表不该整张作废。老版二进制 `.skn` 读进来
/// 会得到 None（首字符不是 `{` 就直接拒），UI 侧给「不认得这份皮肤」。
///
/// 颜色为什么存 `Int32`（0xRRGGBB）而不是 `@moonui.Color`：`Color` 没有公开
/// 的 r/g/b 读法，存了就导不回 `#RRGGBB` 文本；存整数则进 JSON、出 JSON、
/// 转 `Color` 三条路都通。
pub(all) struct Skin {
  name : String
  /// 强调色（已播进度 / 当前歌词 / 高亮行）
  accent : Int32
  /// 强调浅底（正在播行 / 选中高亮）
  accent_bg : Int32
  /// 列表区主文字（列表 / 歌词区）
  ink : Int32
  /// 列表区次要文字（歌手/专辑/表头/说明）
  muted : Int32
  /// 窗体底色（脸面）
  page_bg : Int32
  /// 顶条底（承载 logo 与窗口钮）
  titlebar_bg : Int32
  /// 信息条底（承载歌名/格式滚动信息）
  face_light : Int32
  /// 频谱可视化窗的深底
  inset : Int32
  /// 频谱条（可视化窗里跳动的那两根）
  bar : Int32
  /// 深底上的亮文字（顶条 logo / 大号时间 / 走带字形）
  text_light : Int32
  /// 信息条/状态行文字（与 face_light 成对，保证对比度）
  face_text : Int32
  /// 列表卡片底
  playlist_bg : Int32
  /// 歌词区底
  lyric_bg : Int32
  /// 歌词当前句
  lyric_cur : Int32
  /// 歌词上下句
  lyric_dim : Int32
  /// 斑马行底（奇数行）
  zebra : Int32
  /// 悬停高亮（列表行 hover）
  hover : Int32
  /// 脸面渐变顶色（上缘高光）
  face_top : Int32
  /// 脸面渐变底色（下缘回落）
  face_bottom : Int32
  /// 走带/进度那两条底带
  transport_bg : Int32
  /// 走带小钮底（比走带带再亮一档）
  btn_bg : Int32
  /// 倒角高光（每条带上缘 1px 的亮线；Winamp 风格皮肤的立体感全靠它）
  bevel_hi : Int32
  /// 倒角阴影（每条带下缘 1px 的暗线，与 bevel_hi 成对）
  bevel_lo : Int32
} derive(Eq, Debug)

///|
/// 默认皮肤：Luna经典光泽蓝。脸面淡蓝、顶条深蓝、信息条浅蓝、频谱窗
/// 深底亮青条；文字在蓝底上取白/深蓝两档。MoonUI 无渐变/位图，靠三档蓝的
/// 层次近似那层光泽（顶条最深、脸面次之、信息条最浅）。
pub fn cm_skin_blue() -> Skin {
  {
    name: "经典蓝",
    accent: 0x2C6FB5,
    accent_bg: 0xC8E2F6,
    ink: 0x1A2A38,
    muted: 0x5E7688,
    page_bg: 0x4A85BA,
    titlebar_bg: 0x1F4468,
    face_light: 0xA9CBE6,
    inset: 0x0E2338,
    bar: 0x7ED0FF,
    text_light: 0xF2F8FF,
    face_text: 0x0D2436,
    playlist_bg: 0xF7FAFD,
    lyric_bg: 0xFBFDFF,
    lyric_cur: 0x1F6BB0,
    lyric_dim: 0x93A8BA,
    zebra: 0xEFF6FC,
    hover: 0xD3E7F7,
    face_top: 0x7FB1D8,
    face_bottom: 0x33638D,
    transport_bg: 0x2B5985,
    btn_bg: 0x4C86B8,
    bevel_hi: 0xB9DCF5,
    bevel_lo: 0x16304A,
  }
}

///|
/// 深空灰：整窗压暗，列表区也跟着暗（文字转浅），强调色抬到亮蓝才压得住底色。
pub fn cm_skin_dark() -> Skin {
  {
    name: "深空灰",
    accent: 0x5AB0FF,
    accent_bg: 0x22303E,
    ink: 0xE6EDF5,
    muted: 0x8FA3B8,
    page_bg: 0x232A33,
    titlebar_bg: 0x171C22,
    face_light: 0x2C3540,
    inset: 0x10141A,
    bar: 0x7FD8FF,
    text_light: 0xF2F6FA,
    face_text: 0xC6D2E0,
    playlist_bg: 0x1E242C,
    lyric_bg: 0x1A1F26,
    lyric_cur: 0x7FD8FF,
    lyric_dim: 0x5C6B7C,
    zebra: 0x262D36,
    hover: 0x2E3946,
    face_top: 0x333D49,
    face_bottom: 0x1D242C,
    transport_bg: 0x161C23,
    btn_bg: 0x2A333D,
    bevel_hi: 0x46586C,
    bevel_lo: 0x080B0F,
  }
}

///|
/// 绯红：窗体压成常见音乐客户端那档红（#C20C0C 一圈），脸面亮红、顶条暗红。
pub fn cm_skin_red() -> Skin {
  {
    name: "绯红",
    accent: 0xC20C0C,
    accent_bg: 0xFBE3E3,
    ink: 0x262626,
    muted: 0x8A8A8A,
    page_bg: 0xC62F2F,
    titlebar_bg: 0xA01818,
    face_light: 0xF0C6C6,
    inset: 0x5C1010,
    bar: 0xFFB3B3,
    text_light: 0xFFF5F5,
    face_text: 0x4A1010,
    playlist_bg: 0xFFF9F9,
    lyric_bg: 0xFFFBFA,
    lyric_cur: 0xC20C0C,
    lyric_dim: 0xB8A0A0,
    zebra: 0xFDF0F0,
    hover: 0xFBDDDD,
    face_top: 0xE07373,
    face_bottom: 0xB42929,
    transport_bg: 0x9A1E1E,
    btn_bg: 0xD45252,
    bevel_hi: 0xF2B4B4,
    bevel_lo: 0x5C0C0C,
  }
}

///|
/// 松林绿：低饱和绿的一套，走带与脸面的层次同经典蓝那套。
pub fn cm_skin_green() -> Skin {
  {
    name: "松林绿",
    accent: 0x2E8B57,
    accent_bg: 0xD8F0E2,
    ink: 0x1E3228,
    muted: 0x6E8C7A,
    page_bg: 0x5FA47E,
    titlebar_bg: 0x3B7C5A,
    face_light: 0xC8E8D6,
    inset: 0x1A3D2C,
    bar: 0xA8F0C8,
    text_light: 0xF6FFF9,
    face_text: 0x10301F,
    playlist_bg: 0xFAFFFB,
    lyric_bg: 0xFBFFFC,
    lyric_cur: 0x2E8B57,
    lyric_dim: 0xA0B8AA,
    zebra: 0xF0F8F3,
    hover: 0xDDF0E6,
    face_top: 0x8CC4A6,
    face_bottom: 0x4C8F6C,
    transport_bg: 0x356B52,
    btn_bg: 0x66A886,
    bevel_hi: 0xB4DCC8,
    bevel_lo: 0x16321F,
  }
}

///|
/// 内置皮肤表（菜单与「按名找皮肤」都从这张表走）。第一项是默认皮肤。
pub fn cm_skin_builtins() -> Array[Skin] {
  [cm_skin_blue(), cm_skin_dark(), cm_skin_red(), cm_skin_green()]
}

///|
/// 默认皮肤（启动/坏档兜底都用它）。
pub fn cm_skin_default() -> Skin {
  cm_skin_blue()
}

///|
/// 内置皮肤的名字表（菜单照这个顺序列）。
pub fn cm_skin_names() -> Array[String] {
  let out : Array[String] = []
  for s in cm_skin_builtins() {
    out.push(s.name)
  }
  out
}

///|
/// 按名字找内置皮肤；没有就是 None（调用方按"不是内置"处理，比如当路径）。
pub fn cm_skin_by_name(name : String) -> Skin? {
  for s in cm_skin_builtins() {
    if s.name == name {
      return Some(s)
    }
  }
  None
}

// ————————————————————————————————————————————————————
// 当前皮肤：一只盒子装着（struct 是引用，字段可变）
// ————————————————————————————————————————————————————

///|
/// 当前皮肤的盒子。为什么不是全局 `let mut`：MoonBit 顶层 `let` 够用——盒子
/// 本身不变（`let`），里面的 `cur` 是 `mut` 字段。测试里靠 `cm_skin_reset()`
/// 收尾，避免跨测试串味。
priv struct SkinBox {
  mut cur : Skin
}

///|
let cm_skin_box : SkinBox = { cur: cm_skin_default(), }

///|
/// 当前皮肤。
pub fn cm_skin_current() -> Skin {
  cm_skin_box.cur
}

///|
/// 换皮肤（只换盒子里的值；调用方负责重建 UI——换肤要整树重刷）。
pub fn cm_skin_set(s : Skin) -> Unit {
  cm_skin_box.cur = s
}

///|
/// 回到默认皮肤（测试收尾与「恢复默认」菜单项）。
pub fn cm_skin_reset() -> Unit {
  cm_skin_box.cur = cm_skin_default()
}

// ————————————————————————————————————————————————————
// 序列化：#RRGGBB ↔ Int32 ↔ Color
// ————————————————————————————————————————————————————

///|
/// 0xRRGGBB → "#RRGGBB"（大写，与手写皮肤档的惯例一致）。
pub fn cm_hex_of(v : Int32) -> String {
  let digits = "0123456789ABCDEF".to_array()
  let mut out = "#"
  for i = 5; i >= 0; i = i - 1 {
    let d = (v >> (4 * i)) & 15
    out = out + digits[d].to_string()
  }
  out
}

///|
/// "#RRGGBB" / "RRGGBB" → 0xRRGGBB；长度不对或有非十六进制字符 → None。
pub fn cm_hex_parse(s : String) -> Int32? {
  let t = s.trim().to_owned()
  let body = if t.has_prefix("#") { t[1:].to_owned() } else { t }
  let cs = body.to_array()
  if cs.length() != 6 {
    return None
  }
  let mut v = 0
  for c in cs {
    match cm_hex_digit(c) {
      Some(d) => v = v * 16 + d
      None => return None
    }
  }
  Some(v)
}

///|
fn cm_hex_digit(c : Char) -> Int32? {
  let n = c.to_int()
  if n >= 48 && n <= 57 {
    Some(n - 48)
  } else if n >= 65 && n <= 70 {
    Some(n - 65 + 10)
  } else if n >= 97 && n <= 102 {
    Some(n - 97 + 10)
  } else {
    None
  }
}

///|
/// 0xRRGGBB → Color（`Color` 没有公开的 r/g/b 读法，所以拆分在整数这侧做）。
pub fn cm_color_of(v : Int32) -> @moonui.Color {
  @moonui.Color::rgb((v >> 16) & 255, (v >> 8) & 255, v & 255)
}

///|
/// 皮肤 → JSON（导出与存档都用这一份）。
pub fn Skin::to_json(self : Skin) -> Json {
  Json::object(
    Map::from_array([
      ("name", Json::string(self.name)),
      ("accent", Json::string(cm_hex_of(self.accent))),
      ("accent_bg", Json::string(cm_hex_of(self.accent_bg))),
      ("ink", Json::string(cm_hex_of(self.ink))),
      ("muted", Json::string(cm_hex_of(self.muted))),
      ("page_bg", Json::string(cm_hex_of(self.page_bg))),
      ("titlebar_bg", Json::string(cm_hex_of(self.titlebar_bg))),
      ("face_light", Json::string(cm_hex_of(self.face_light))),
      ("inset", Json::string(cm_hex_of(self.inset))),
      ("bar", Json::string(cm_hex_of(self.bar))),
      ("text_light", Json::string(cm_hex_of(self.text_light))),
      ("face_text", Json::string(cm_hex_of(self.face_text))),
      ("playlist_bg", Json::string(cm_hex_of(self.playlist_bg))),
      ("lyric_bg", Json::string(cm_hex_of(self.lyric_bg))),
      ("lyric_cur", Json::string(cm_hex_of(self.lyric_cur))),
      ("lyric_dim", Json::string(cm_hex_of(self.lyric_dim))),
      ("zebra", Json::string(cm_hex_of(self.zebra))),
      ("hover", Json::string(cm_hex_of(self.hover))),
      ("face_top", Json::string(cm_hex_of(self.face_top))),
      ("face_bottom", Json::string(cm_hex_of(self.face_bottom))),
      ("transport_bg", Json::string(cm_hex_of(self.transport_bg))),
      ("btn_bg", Json::string(cm_hex_of(self.btn_bg))),
      ("bevel_hi", Json::string(cm_hex_of(self.bevel_hi))),
      ("bevel_lo", Json::string(cm_hex_of(self.bevel_lo))),
    ]),
  )
}

///|
/// 皮肤 → 文本（写档用）。
pub fn Skin::text(self : Skin) -> String {
  self.to_json().stringify()
}

///|
/// JSON → 皮肤：缺字段按默认皮肤补齐，坏值也退回默认那一个（手写半张表不该
/// 整张作废）。整体不是对象 → None。
pub fn Skin::from_json(j : Json) -> Skin? {
  match j {
    Json::Object(m) => {
      let d = cm_skin_default()
      let name = match m.get("name") {
        Some(Json::String(s)) => s
        _ => "导入皮肤"
      }
      Some({
        name,
        accent: cm_json_color(m, "accent", d.accent),
        accent_bg: cm_json_color(m, "accent_bg", d.accent_bg),
        ink: cm_json_color(m, "ink", d.ink),
        muted: cm_json_color(m, "muted", d.muted),
        page_bg: cm_json_color(m, "page_bg", d.page_bg),
        titlebar_bg: cm_json_color(m, "titlebar_bg", d.titlebar_bg),
        face_light: cm_json_color(m, "face_light", d.face_light),
        inset: cm_json_color(m, "inset", d.inset),
        bar: cm_json_color(m, "bar", d.bar),
        text_light: cm_json_color(m, "text_light", d.text_light),
        face_text: cm_json_color(m, "face_text", d.face_text),
        playlist_bg: cm_json_color(m, "playlist_bg", d.playlist_bg),
        lyric_bg: cm_json_color(m, "lyric_bg", d.lyric_bg),
        lyric_cur: cm_json_color(m, "lyric_cur", d.lyric_cur),
        lyric_dim: cm_json_color(m, "lyric_dim", d.lyric_dim),
        zebra: cm_json_color(m, "zebra", d.zebra),
        hover: cm_json_color(m, "hover", d.hover),
        face_top: cm_json_color(m, "face_top", d.face_top),
        face_bottom: cm_json_color(m, "face_bottom", d.face_bottom),
        transport_bg: cm_json_color(m, "transport_bg", d.transport_bg),
        btn_bg: cm_json_color(m, "btn_bg", d.btn_bg),
        bevel_hi: cm_json_color(m, "bevel_hi", d.bevel_hi),
        bevel_lo: cm_json_color(m, "bevel_lo", d.bevel_lo),
      })
    }
    _ => None
  }
}

///|
/// 读一个 token：优先 `#RRGGBB` 字符串，也认整数（手写时图省事的写法），
/// 缺/坏都退回默认皮肤那一个。
fn cm_json_color(m : Map[String, Json], key : String, dft : Int32) -> Int32 {
  match m.get(key) {
    Some(Json::String(s)) =>
      match cm_hex_parse(s) {
        Some(v) => v
        None => dft
      }
    Some(Json::Number(n, ..)) => n.to_int()
    _ => dft
  }
}

///|
/// 皮肤档文本 → 皮肤。老版Luna的 `.skn` 是二进制资源包（zip 改后缀），
/// 这里只认 JSON 文本——首字符不是 `{` 就直接拒，UI 侧给「不认得这份皮肤」。
pub fn Skin::from_text(text : String) -> Skin? {
  let t = text.trim().to_owned()
  if !t.has_prefix("{") {
    return None
  }
  Skin::from_json(@json.parse(t)) catch {
    _ => None
  }
}

// ————————————————————————————————————————————————————
// token 读法：以下这些是 UI 侧唯一该碰颜色的入口
// ————————————————————————————————————————————————————

///|
/// 强调色（已播进度 / 当前歌词 / 高亮行）
fn cm_accent() -> @moonui.Color {
  cm_color_of(cm_skin_current().accent)
}

///|
/// 关键词浅底（正在播行 / 选中高亮）
fn cm_accent_bg() -> @moonui.Color {
  cm_color_of(cm_skin_current().accent_bg)
}

///|
/// 列表区主文字（列表 / 歌词区）
fn cm_ink() -> @moonui.Color {
  cm_color_of(cm_skin_current().ink)
}

///|
/// 列表区次要文字（歌手/专辑/表头/说明）
fn cm_muted() -> @moonui.Color {
  cm_color_of(cm_skin_current().muted)
}

///|
/// 窗体底色 = 脸面
fn cm_page_bg() -> @moonui.Color {
  cm_color_of(cm_skin_current().page_bg)
}

///|
/// 顶条底（承载「Luna」logo 与窗口钮）
fn cm_titlebar_bg() -> @moonui.Color {
  cm_color_of(cm_skin_current().titlebar_bg)
}

///|
/// 信息条底（承载歌名/格式滚动信息）
fn cm_face_light() -> @moonui.Color {
  cm_color_of(cm_skin_current().face_light)
}

///|
/// 频谱可视化窗的深底
fn cm_inset() -> @moonui.Color {
  cm_color_of(cm_skin_current().inset)
}

///|
/// 频谱条（可视化窗里跳动的那两根）
fn cm_bar() -> @moonui.Color {
  cm_color_of(cm_skin_current().bar)
}

///|
/// 深底上的亮文字（顶条 logo / 大号时间 / 走带按钮字形）
fn cm_text_light() -> @moonui.Color {
  cm_color_of(cm_skin_current().text_light)
}

///|
/// 信息条/状态行文字（与 face_light 成对）
fn cm_face_text() -> @moonui.Color {
  cm_color_of(cm_skin_current().face_text)
}

///|
/// 列表卡片底
fn cm_playlist_bg() -> @moonui.Color {
  cm_color_of(cm_skin_current().playlist_bg)
}

///|
/// 歌词区底
fn cm_lyric_bg() -> @moonui.Color {
  cm_color_of(cm_skin_current().lyric_bg)
}

///|
/// 歌词当前句
fn cm_lyric_cur() -> @moonui.Color {
  cm_color_of(cm_skin_current().lyric_cur)
}

///|
/// 歌词上下句
fn cm_lyric_dim() -> @moonui.Color {
  cm_color_of(cm_skin_current().lyric_dim)
}

///|
/// 斑马行底（奇数行）
fn cm_zebra() -> @moonui.Color {
  cm_color_of(cm_skin_current().zebra)
}

///|
/// 悬停高亮（列表行 hover）
fn cm_hover() -> @moonui.Color {
  cm_color_of(cm_skin_current().hover)
}

///|
/// 脸面渐变顶色（上缘高光）
fn cm_face_top() -> @moonui.Color {
  cm_color_of(cm_skin_current().face_top)
}

///|
/// 脸面渐变底色（下缘回落）
fn cm_face_bottom() -> @moonui.Color {
  cm_color_of(cm_skin_current().face_bottom)
}

///|
/// 走带/进度那两条底带
fn cm_transport_bg() -> @moonui.Color {
  cm_color_of(cm_skin_current().transport_bg)
}

///|
/// 走带小钮底（比走带带再亮一档）
fn cm_btn_bg() -> @moonui.Color {
  cm_color_of(cm_skin_current().btn_bg)
}

///|
/// 倒角高光（带上缘 1px 亮线）
fn cm_bevel_hi() -> @moonui.Color {
  cm_color_of(cm_skin_current().bevel_hi)
}

///|
/// 倒角阴影（带下缘 1px 暗线）
fn cm_bevel_lo() -> @moonui.Color {
  cm_color_of(cm_skin_current().bevel_lo)
}

// ————————————————————————————————————————————————————
// 尺寸（换肤不改尺寸，这些与皮肤无关，留在同一处便于对账）
// ————————————————————————————————————————————————————

///|
/// 顶条高（沉浸式标题栏下，红绿灯浮在这条上，logo 从 88 起）
pub fn cm_title_h() -> Double {
  30.0
}

///|
/// 信息条高（歌名 / 歌手 - 专辑）
pub fn cm_info_h() -> Double {
  20.0
}

///|
/// 脸面高（频谱窗 + 大字时间 / 立体声 / 状态）
pub fn cm_face_h() -> Double {
  68.0
}

///|
/// 进度条带高（原生滑块的固有高度约 21，给 22 不裁切）
pub fn cm_prog_h() -> Double {
  22.0
}

///|
/// 走带条高（按钮 + 音量 + PL·EQ·LRC）
pub fn cm_transport_h() -> Double {
  36.0
}

///|
/// 主控窗宽（Luna是窄条：宽高比约 2.2:1，不是过去那版 480×240 的方脸）
pub fn cm_main_w() -> Double {
  380.0
}

///|
/// 主控窗内容总高 = 五段之和。窗口尺寸与分段高度用同一组常量，
/// 避免"窗给 240、内容只有 176"那种底下空一条的错位。
pub fn cm_main_h() -> Double {
  cm_title_h() + cm_info_h() + cm_face_h() + cm_prog_h() + cm_transport_h()
}

///|
/// 均衡器窗高：标题行 + 十段（每段 26）+ 边距，够放下十根滑块与预设下拉。
pub fn cm_eq_h() -> Double {
  340.0
}

///|
/// 歌词秀窗宽：主控右侧那一条。比主控宽一截（默认布局里它与主控同高并排，
/// 宽 408 才容得下长句中段不被早早裁掉；三窗拼成的整块宽 794，播放列表横跨）。
pub fn cm_lyrics_w() -> Double {
  408.0
}
