///|
/// 播放偏好（DESIGN.md C-07）：音量、播放模式、最后播放的歌曲路径。
/// 启动时不自动续播，只恢复模式/音量与列表高亮——与常见音乐客户端行为一致。
/// 落在独立的 lunamusic-prefs.json（与曲库档分开：曲库是数据账，偏好是
/// 状态账）。
///
/// `T197` 起读写走框架的 `@moonui.Settings`（逐字段兜底 + 原子写）：这里只剩
/// "哪一格叫什么、坏值怎么退"这层领域语义，JSON 的解析与合并交给框架。
pub(all) struct Prefs {
  mut volume : Int32 // 千分位 0..1000
  mut mode : PlayMode
  mut last_path : String? // None = 没播过
  /// 均衡器十段增益（千分位，500 = 0dB）——原版关掉再打开 EQ 还在，这里同样
  mut eq_bands : Array[Int32]
  /// 均衡器旁路开关
  mut eq_on : Bool
  /// 当前皮肤：内置皮肤名，或皮肤档路径。空串/查不到/读不出来都回默认皮肤。
  mut skin : String
  /// 歌名/歌手这两格按文件名还是按标签显示（`T193`）。默认文件名。
  mut display : DisplaySource
  /// 桌面歌词浮条的开关（`T195`）：用户关掉之后下次启动仍保持关闭。
  ///
  /// 存的是**意图**（想不想挂），不是"退出那一刻是否可见"——可见性还要叠加
  /// 迷你模式与有没有歌词（`cm_desk_visible`）。存可见性会把"上次没歌词所以
  /// 没显示"错记成"用户不要它"，下次有词了也不出来。默认开（与原版一致）。
  mut show_desk : Bool
}

///|
pub fn Prefs::new() -> Prefs {
  {
    volume: 1000,
    mode: Sequential,
    last_path: None,
    eq_bands: flat_eq(),
    eq_on: true,
    skin: "",
    display: cm_display_source_default(),
    show_desk: true,
  }
}

///|
/// 平直的那张 EQ 表（十段 0dB）。
fn flat_eq() -> Array[Int32] {
  let out : Array[Int32] = []
  for i = 0; i < 10; i = i + 1 {
    out.push(500)
  }
  out
}

///|
/// 档格式**不变**（`eq_on`/`show_desk` 仍旧存 1/0 而不是布尔）：老用户的档
/// 已经在盘上了，改格式就得写迁移，而这里没有值得付那笔账的收益。
pub fn Prefs::to_json(self : Prefs) -> Json {
  let s = @moonui.Settings::new()
  s.set_int("volume", self.volume)
  s.set_int("mode", PlayMode::index(self.mode))
  s.set_json(
    "last_path",
    match self.last_path {
      Some(p) => Json::string(p)
      None => Json::null()
    },
  )
  s.set_int("eq_on", if self.eq_on { 1 } else { 0 })
  s.set_int_array("eq_bands", self.eq_bands)
  s.set_string("skin", self.skin)
  s.set_string("display", self.display.key())
  s.set_int("show_desk", if self.show_desk { 1 } else { 0 })
  s.to_json()
}

///|
/// 坏档逐字段兜底（缺字段/坏类型回默认），整体不是对象才返回 None。
/// 每一格的"读法"都短到一行，靠的是 `Settings` 的 `get_*` 已经把
/// "缺字段""类型不对"统一成"返回默认值"。
pub fn Prefs::from_json(j : Json) -> Prefs? {
  match @moonui.Settings::from_json(j) {
    None => None
    Some(s) => {
      let p = Prefs::new()
      p.volume = s.get_int("volume", p.volume)
      // 模式用序数存；认不出的序数保持默认（顺序播放）
      p.mode = match PlayMode::of_index(s.get_int("mode", 0)) {
        Some(mo) => mo
        None => p.mode
      }
      match s.get_json("last_path") {
        Some(Json::String(x)) => p.last_path = Some(x)
        _ => ()
      }
      p.eq_on = s.get_int("eq_on", if p.eq_on { 1 } else { 0 }) != 0
      // 段数不对（旧档/坏档）就整段不要，回平直——十段的表少一段都会错位
      match s.get_int_array("eq_bands") {
        Some(bands) => if bands.length() == 10 { p.eq_bands = bands }
        None => ()
      }
      // 皮肤：空串就是默认皮肤，非空交给启动侧按「先查内置、再当路径」去认
      p.skin = s.get_string("skin", p.skin)
      // 显示口径：旧档没有这一格 / 认不出的键都回默认（文件名）
      p.display = match DisplaySource::of_key(s.get_string("display", "")) {
        Some(d) => d
        None => p.display
      }
      // 桌面歌词开关（`T195`）：旧档没有这一格就保持默认开——
      // 升级前用户没表达过"不要它"，按原版默认挂着。
      p.show_desk = s.get_int("show_desk", if p.show_desk { 1 } else { 0 }) != 0
      Some(p)
    }
  }
}

///|
/// 档文本 → Prefs（与 Library::from_text 同款：坏档回 None，调用方起步默认）。
pub fn Prefs::from_text(text : String) -> Prefs? {
  let j = @json.parse(text) catch { _ => return None }
  Prefs::from_json(j)
}

///|
/// 模式 ↔ 序数（JSON 档用序数存，坏值回 Sequential）。
pub fn PlayMode::index(self : PlayMode) -> Int32 {
  match self {
    Sequential => 0
    RepeatOne => 1
    Shuffle => 2
  }
}

///|
pub fn PlayMode::of_index(i : Int32) -> PlayMode? {
  match i {
    0 => Some(Sequential)
    1 => Some(RepeatOne)
    2 => Some(Shuffle)
    _ => None
  }
}
