///|
/// 播放偏好（DESIGN.md C-07）：音量、播放模式、最后播放的歌曲路径。
/// 启动时不自动续播，只恢复模式/音量与列表高亮——与常见音乐客户端行为一致。
/// 落在独立的 lunamusic-prefs.json（与曲库档分开：曲库是数据账，偏好是
/// 状态账）。
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
pub fn Prefs::to_json(self : Prefs) -> Json {
  Json::object(
    Map::from_array([
      ("volume", Json::number(self.volume.to_double())),
      ("mode", Json::number(PlayMode::index(self.mode).to_double())),
      (
        "last_path",
        match self.last_path {
          Some(p) => Json::string(p)
          None => Json::null()
        },
      ),
      ("eq_on", Json::number(if self.eq_on { 1.0 } else { 0.0 })),
      ("eq_bands", Json::array(eq_json(self.eq_bands))),
      ("skin", Json::string(self.skin)),
    ]),
  )
}

///|
fn eq_json(bands : Array[Int32]) -> Array[Json] {
  let out : Array[Json] = []
  for b in bands {
    out.push(Json::number(b.to_double()))
  }
  out
}

///|
/// 坏档逐字段兜底（缺字段/坏类型回默认），整体不是对象才返回 None。
pub fn Prefs::from_json(j : Json) -> Prefs? {
  match j {
    Json::Object(m) => {
      let p = Prefs::new()
      match m.get("volume") {
        Some(Json::Number(v, ..)) => p.volume = v.to_int()
        _ => ()
      }
      match m.get("mode") {
        Some(Json::Number(v, ..)) =>
          match PlayMode::of_index(v.to_int()) {
            Some(mo) => p.mode = mo
            None => ()
          }
        _ => ()
      }
      match m.get("last_path") {
        Some(Json::String(s)) => p.last_path = Some(s)
        _ => ()
      }
      match m.get("eq_on") {
        Some(Json::Number(v, ..)) => p.eq_on = v.to_int() != 0
        _ => ()
      }
      // 段数不对（旧档/坏档）就整段不要，回平直——十段的表少一段都会错位
      match m.get("eq_bands") {
        Some(Json::Array(arr)) =>
          if arr.length() == 10 {
            let bands : Array[Int32] = []
            for b in arr {
              match b {
                Json::Number(v, ..) => bands.push(v.to_int())
                _ => ()
              }
            }
            if bands.length() == 10 {
              p.eq_bands = bands
            }
          }
        _ => ()
      }
      // 皮肤：空串就是默认皮肤，非空交给启动侧按「先查内置、再当路径」去认
      match m.get("skin") {
        Some(Json::String(s)) => p.skin = s
        _ => ()
      }
      Some(p)
    }
    _ => None
  }
}

///|
/// 档文本 → Prefs（与 Library::from_text 同款：坏档回 None，调用方起步默认）。
pub fn Prefs::from_text(text : String) -> Prefs? {
  Prefs::from_json(@json.parse(text)) catch {
    _ => None
  }
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
