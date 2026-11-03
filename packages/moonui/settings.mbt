///|
/// 设置档（`T197`）：一层 JSON 对象 + **逐字段兜底**的读法 + 原子写。
///
/// 为什么要有这一层：每个应用都会有一个"偏好/设置"文件，而正确的写法不是
/// 一坨 `if let`——是"先起一份默认值，再让档里有的字段逐个盖上去，认不出的
/// 就留默认"。`examples/lunamusic/prefs.mbt` 手写了 60 行这类代码（还有升级
/// 前字段缺席的处理），`window_state.mbt` 则是另一套写法（缺字段直接 raise）。
/// 两者都对，但**每加一个设置项就重写一遍**这件事本身是框架该接的。
///
/// 与窗口几何档不同的一条口径：**设置档坏了按"没有档"处理**（返回 `None`），
/// 不 raise。理由是不对称的——窗口几何没有安全的默认值（恢复到错的位置，窗口
/// 可能跑到屏幕外，用户看不见也够不着，所以那里必须显式报错）；而设置档的每一
/// 格都有默认值，坏档退回默认仍然是一个能用的应用。写侧是原子的
/// （`Fs::write_text_atomic`），所以"半份档"正常不该出现，坏了多半是手改或别的
/// 工具写坏的。
pub(all) struct Settings {
  values : Map[String, Json]
}

///|
/// 空档（每一格都走调用方给的默认值）。
pub fn Settings::new() -> Settings {
  { values: Map([]), }
}

///|
/// 从文本解析。不是 JSON、或不是对象都返回 `None`——设置档的顶层必须是对象
/// （数组/标量没有"字段"可言）。
pub fn Settings::parse(text : String) -> Settings? {
  let j = @json.parse(text) catch { _ => return None }
  Settings::from_json(j)
}

///|
/// 从一个已经解析好的 JSON 值建档（调用方自己解析、或在内存里拼一份档时用）。
/// 非对象返回 `None`。
pub fn Settings::from_json(j : Json) -> Settings? {
  match j {
    Object(m) => Some({ values: m, })
    _ => None
  }
}

///|
/// 从文件加载。缺档返回 `None`（第一次启动是常态）；读不出来或解析不了也返回
/// `None`（口径见上面的段注）。读失败的**系统错误**（权限、读一半）仍然 raise
/// ——那与"档里写了什么"无关，吞掉只会让人查不到原因。
pub fn Settings::load(path : String) -> Settings? raise UiError {
  match Fs::read_text(path) {
    None => None
    Some(text) => Settings::parse(text)
  }
}

///|
/// 存盘（原子替换）。内容就是 `to_json().stringify()`——与各应用自己写的格式
/// 一致，可以直接被 `Settings::parse` 读回。
pub fn Settings::save(self : Settings, path : String) -> Unit raise UiError {
  Fs::write_text_atomic(path, self.to_json().stringify())
}

///|
pub fn Settings::to_json(self : Settings) -> Json {
  Json::object(self.values)
}

///|
/// 有没有这一格（区分"没写"与"写了个空值"用）。
pub fn Settings::has(self : Settings, key : String) -> Bool {
  self.values.get(key) is Some(_)
}

///|
/// 原始 JSON（数组/嵌套对象这类结构自己解释）。
pub fn Settings::get_json(self : Settings, key : String) -> Json? {
  self.values.get(key)
}

///|
/// 取整数；缺字段、类型不对都返回 `default`。JSON 数字是双精度，这里按
/// 截断取整（与 `Json::number(...).to_int()` 同一条路，`T193`/`T195` 都这么用）。
pub fn Settings::get_int(
  self : Settings,
  key : String,
  default : Int32,
) -> Int32 {
  match self.values.get(key) {
    Some(Number(v, ..)) => v.to_int()
    _ => default
  }
}

///|
/// 取小数（窗口尺寸、音量归一值这类）。
pub fn Settings::get_number(
  self : Settings,
  key : String,
  default : Double,
) -> Double {
  match self.values.get(key) {
    Some(Number(v, ..)) => v
    _ => default
  }
}

///|
/// 取布尔；非布尔一律按默认（`"true"` 这种字符串不猜——猜错一次就是一条
/// 谁也查不出来的行为差异）。
pub fn Settings::get_bool(
  self : Settings,
  key : String,
  default : Bool,
) -> Bool {
  match self.values.get(key) {
    Some(True) => true
    Some(False) => false
    _ => default
  }
}

///|
/// 取字符串；非字符串按默认。
pub fn Settings::get_string(
  self : Settings,
  key : String,
  default : String,
) -> String {
  match self.values.get(key) {
    Some(String(s)) => s
    _ => default
  }
}

///|
/// 取整数数组（EQ 十段、最近打开、列宽这类）。缺字段/不是数组 → `None`；
/// 数组里**有一个不是数字就整份作废**——半份数字表比"没有表"更难排查
/// （长度对不上会在下游变成奇怪的越界或静默截断）。
pub fn Settings::get_int_array(self : Settings, key : String) -> Array[Int32]? {
  match self.values.get(key) {
    Some(Array(items)) => {
      let out : Array[Int32] = []
      for it in items {
        match it {
          Number(v, ..) => out.push(v.to_int())
          _ => return None
        }
      }
      Some(out)
    }
    _ => None
  }
}

///|
pub fn Settings::set_json(self : Settings, key : String, value : Json) -> Unit {
  self.values.set(key, value)
}

///|
pub fn Settings::set_int(self : Settings, key : String, value : Int32) -> Unit {
  self.values.set(key, Json::number(value.to_double()))
}

///|
pub fn Settings::set_number(
  self : Settings,
  key : String,
  value : Double,
) -> Unit {
  self.values.set(key, Json::number(value))
}

///|
pub fn Settings::set_bool(self : Settings, key : String, value : Bool) -> Unit {
  self.values.set(key, Json::boolean(value))
}

///|
pub fn Settings::set_string(
  self : Settings,
  key : String,
  value : String,
) -> Unit {
  self.values.set(key, Json::string(value))
}

///|
pub fn Settings::set_int_array(
  self : Settings,
  key : String,
  values : Array[Int32],
) -> Unit {
  let items : Array[Json] = []
  for v in values {
    items.push(Json::number(v.to_double()))
  }
  self.values.set(key, Json::array(items))
}

///|
/// 判据：缺字段/类型不对都落默认，设置过的字段逐位读回。
test "Settings：缺字段与坏类型都落默认，设过的字段读回（T197）" {
  let s = Settings::new()
  // 空档：全都是默认值
  assert_eq(s.get_int("volume", 800), 800)
  assert_eq(s.get_bool("eq_on", true), true)
  assert_eq(s.get_string("skin", "默认"), "默认")
  assert_eq(s.get_int_array("eq_bands"), None)
  assert_false(s.has("volume"))
  // 设过的字段读回
  s.set_int("volume", 600)
  s.set_bool("eq_on", false)
  s.set_string("skin", "深空灰")
  s.set_int_array("eq_bands", [500, 600, 700])
  assert_eq(s.get_int("volume", 800), 600)
  assert_eq(s.get_bool("eq_on", true), false)
  assert_eq(s.get_string("skin", "默认"), "深空灰")
  assert_eq(s.get_int_array("eq_bands"), Some([500, 600, 700]))
  assert_true(s.has("volume"))
  // 往返：写出去再读回来，逐字段一致
  let back = Settings::parse(s.to_json().stringify()).unwrap()
  assert_eq(back.get_int("volume", 0), 600)
  assert_eq(back.get_bool("eq_on", true), false)
  assert_eq(back.get_int_array("eq_bands"), Some([500, 600, 700]))
}

///|
/// 判据：类型不对的字段**不许**被"猜"成有效值——一律落默认。
/// 这条是设置档最容易写错的地方（`"volume": "600"` 到底算不算 600？我们说不算）。
test "Settings：坏类型不猜，一律落默认（T197）" {
  let s = Settings::parse(
    Json::object(
      Map([
        ("volume", Json::string("600")),
        ("eq_on", Json::number(1.0)),
        ("skin", Json::array([Json::number(1.0)])),
        ("eq_bands", Json::array([Json::number(1.0), Json::string("x")])),
      ]),
    ).stringify(),
  ).unwrap()
  assert_eq(s.get_int("volume", 800), 800)
  assert_eq(s.get_bool("eq_on", true), true)
  assert_eq(s.get_string("skin", "默认"), "默认")
  // 数组里掺一个非数字 → 整份作废（不返回半份）
  assert_eq(s.get_int_array("eq_bands"), None)
}

///|
/// 判据：坏档不是错误，按"没有档"处理（`None`）——这是与窗口几何档有意的
/// 分歧，写在这里防止后来的人"顺手统一"成 raise。
test "Settings：坏档与空档都返回 None（T197）" {
  // `Settings` 不带 Eq/Debug（它是一张 JSON 表，逐字段比较才是调用方关心的事），
  // 所以这里断言"是 None"而不是 `assert_eq(..., None)`。
  assert_true(Settings::parse("{这不是 JSON") is None)
  // 顶层不是对象：没有字段可言
  assert_true(Settings::parse("[1,2,3]") is None)
  assert_true(Settings::parse("42") is None)
  assert_eq(Settings::parse("{}").unwrap().get_int("x", 7), 7)
}
