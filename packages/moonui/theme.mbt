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
/// 主题层叠出控件默认样式：前景色缺省时按底色亮度推导，保证自定义
/// background 也不会出现白字白底。
pub fn Theme::default_style(self : Theme, system : Theme) -> Style {
  let p = self.resolve(system)
  Style::{
    width: None,
    height: None,
    min_width: None,
    max_width: None,
    margin: None,
    padding: None,
    background: Some(p.surface),
    foreground: Some(p.text),
    font_size: None,
    font_weight: None,
    radius: None,
    opacity: None,
  }
}

///|
test "Theme::resolve 把 System 落到具体配色" {
  assert_eq(Theme::Light.resolve(Theme::Dark), Theme::light_palette())
  assert_eq(Theme::Dark.resolve(Theme::Light), Theme::dark_palette())
  assert_eq(Theme::System.resolve(Theme::Dark), Theme::dark_palette())
  assert_eq(Theme::System.resolve(Theme::System), Theme::light_palette())
}
