///|
/// 主题（设计文档 §16）。
///
/// `Style` 管"这一个控件长什么样"，`Theme` 管"整个应用默认长什么样"：
/// 主题只解析出一份 `Palette` 和由此层叠出的默认 `Style`，优先级永远低于控件自身。
/// `System` 不是第三种配色，而是一个"等后端报告"的占位——`App::palette` 拿后端
/// 说的真实外观去解析它，解析不出来的情况（系统也报 System）按 Light 兜底，
/// 所以这里不提供"当前是不是深色"的猜测式查询。

///|
/// 解析后的配色。`System` 只表示"跟随系统"，落到具体颜色时一定已被解析成
/// Light 或 Dark，因此 Theme 不提供"当前是不是深色"的猜测式查询。
pub(all) struct Palette {
  background : Color
  surface : Color
  text : Color
  accent : Color
  border : Color
} derive(Debug, Eq)

///|
pub(all) enum Theme {
  Light
  Dark
  /// 跟随系统；由 Backend 在 `App::run` 时报告真实外观
  System
} derive(Debug, Eq)

///|
pub fn Theme::light_palette() -> Palette {
  Palette::{
    background: Color::rgb(248, 248, 250),
    surface: Color::rgb(255, 255, 255),
    text: Color::rgb(24, 24, 28),
    accent: Color::rgb(38, 92, 208),
    border: Color::rgb(214, 214, 220),
  }
}

///|
pub fn Theme::dark_palette() -> Palette {
  Palette::{
    background: Color::rgb(22, 22, 26),
    surface: Color::rgb(32, 32, 38),
    text: Color::rgb(236, 236, 240),
    accent: Color::rgb(110, 160, 255),
    border: Color::rgb(58, 58, 66),
  }
}

///|
/// 从 JSON 读一份配色（`T199`）：键名就是五个 token，值写 `"#RRGGBB"`。
///
/// 缺 token 兜默认、坏值也兜默认——**每一格独立兜**，不因为一个 token 写坏就把
/// 整份档丢掉。这条口径与 `Settings` 一致（设置档的每一格都有默认值，坏档退回
/// 默认仍是一个能用的应用），而与窗口几何档相反（那里没有安全的默认值，必须
/// raise）。底色按 `Theme::light_palette()` 起——要让深色族做底，用
/// `Palette::overlay`：`Theme::dark_palette().overlay(j)`。
///
/// ```json
/// { "background": "#101014", "surface": "#181820", "text": "#ECECF0",
///   "accent": "#6EA0FF", "border": "#3A3A42" }
/// ```
pub fn Palette::from_json(j : Json) -> Palette {
  Theme::light_palette().overlay(j)
}

///|
/// 在这份配色上盖一层 JSON：档里有的 token 生效，没有的留原值。
///
/// 顶层不是对象时整份原样返回（不是"读不懂就清空"——清空等于让应用突然变成
/// 一份全默认的配色，用户只写坏一个字符就换了张脸）。
pub fn Palette::overlay(self : Palette, j : Json) -> Palette {
  Palette::{
    background: json_color(j, "background", self.background),
    surface: json_color(j, "surface", self.surface),
    text: json_color(j, "text", self.text),
    accent: json_color(j, "accent", self.accent),
    border: json_color(j, "border", self.border),
  }
}

///|
/// 从设置档读配色（`Settings`）：token 就是档里的顶层字段。
///
/// 应用读配色档的实际路径是 `Settings::load`——那一步已经解决了解析与"档坏了
/// 按没有档处理"，这里接过来把五格颜色读出去，调用方不必再引一层 JSON。
pub fn Palette::from_settings(s : Settings) -> Palette {
  Theme::light_palette().overlay(s.to_json())
}

///|
/// 配色 → 设置档（五个 token，值写成 `"#RRGGBB"`）。与 `from_settings` 成对：
/// 用户调过的配色存盘、下次启动读回来，走的就是这两条。
pub fn Palette::to_settings(self : Palette) -> Settings {
  let s = Settings::new()
  s.set_string("background", self.background.to_hex())
  s.set_string("surface", self.surface.to_hex())
  s.set_string("text", self.text.to_hex())
  s.set_string("accent", self.accent.to_hex())
  s.set_string("border", self.border.to_hex())
  s
}

///|
/// 从文件读配色：缺档、读不出、档不是 JSON 对象，一律 `None`（口径同
/// `Settings::load`——一个坏档不该让应用起不来）。读到了就是一份配色，
/// 缺几格补几格默认。
pub fn Palette::load(path : String) -> Palette? raise UiError {
  match Settings::load(path) {
    None => None
    Some(s) => Some(Palette::from_settings(s))
  }
}

///|
/// 取一格颜色：不是对象 / 缺这一格 / 不是字符串 / 十六进制读不出，都退回
/// `fallback`。
fn json_color(j : Json, key : String, fallback : Color) -> Color {
  match j {
    Object(m) =>
      match m.get(key) {
        Some(String(s)) =>
          match Color::from_hex(s) {
            Some(c) => c
            None => fallback
          }
        _ => fallback
      }
    _ => fallback
  }
}

///|
/// 把 `System` 解析成具体配色；Light/Dark 原样返回。
pub fn Theme::resolve(self : Theme, system : Theme) -> Palette {
  let concrete = match self {
    Light => Light
    Dark => Dark
    System =>
      match system {
        Light => Light
        Dark => Dark
        // 系统本身报告为 System 时按 Light 兜底，避免出现无法解析的外观
        System => Light
      }
  }
  match concrete {
    Light => Theme::light_palette()
    Dark => Theme::dark_palette()
    System => Theme::light_palette()
  }
}

///|
/// 一份配色给出的默认控件样式：底色用 `surface`、前景用 `text`。
/// 这是样式层叠的最底层，控件自身写了的照旧压过它。
pub fn Palette::default_style(self : Palette) -> Style {
  Style::{
    width: None,
    height: None,
    min_width: None,
    max_width: None,
    margin: None,
    padding: None,
    background: Some(self.surface),
    background_gradient: None,
    foreground: Some(self.text),
    font_size: None,
    font_weight: None,
    radius: None,
    opacity: None,
    backdrop_blur: None,
  }
}

///|
/// 主题层叠出控件默认样式：先把 `System` 解析成具体配色，再取那份配色的默认
/// 样式（底 `surface`、前景 `text`，见 `Palette::default_style`）。
pub fn Theme::default_style(self : Theme, system : Theme) -> Style {
  self.resolve(system).default_style()
}

///|
test "Theme::resolve 把 System 落到具体配色" {
  assert_eq(Theme::Light.resolve(Theme::Dark), Theme::light_palette())
  assert_eq(Theme::Dark.resolve(Theme::Light), Theme::dark_palette())
  assert_eq(Theme::System.resolve(Theme::Dark), Theme::dark_palette())
  assert_eq(Theme::System.resolve(Theme::System), Theme::light_palette())
}
