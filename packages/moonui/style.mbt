///|
/// 样式（设计文档 §15）。主题的解析与层叠在 `theme.mbt`（§16）。
///
/// 第一版不做 CSS：`Style` 只放框架真正需要的属性，字段为 `T?` 表示
/// "未显式设置"，让 Widget 的样式可以从 Theme -> 父容器 -> 自身 逐层继承。

///|
/// 0..255 的 RGBA。用 Int 而非 Double，是为了与 Backend 传色值的习惯一致。
pub(all) struct Color {
  r : Int
  g : Int
  b : Int
  a : Int
} derive(Debug, Eq)

///|
pub fn Color::rgb(r : Int, g : Int, b : Int) -> Color {
  Color::{ r, g, b, a: 255, }
}

///|
pub fn Color::rgba(r : Int, g : Int, b : Int, a : Int) -> Color {
  Color::{ r, g, b, a, }
}

///|
/// 按 alpha(0..255) 做整数线性混合，`base` 为底色。
/// 用整数而非浮点，是为了让三端 Backend 得到逐位一致的颜色，
/// 避免浮点舍入差异进入快照测试。
pub fn Color::blend(base : Color, over : Color) -> Color {
  let na = over.a
  let inv = 255 - na
  Color::{
    r: (over.r * na + base.r * inv) / 255,
    g: (over.g * na + base.g * inv) / 255,
    b: (over.b * na + base.b * inv) / 255,
    // 上层不透明则完全覆盖，半透明则保留底层 alpha
    a: if na == 0 {
      base.a
    } else if na >= 255 {
      255
    } else {
      clamp_component(na + inv * base.a / 255)
    },
  }
}

///|
/// 亮度（0..1），用于从单一主色推导可读的前景色。
pub fn Color::luminance(self : Color) -> Double {
  (
    0.2126 * self.r.to_double() +
    0.7152 * self.g.to_double() +
    0.0722 * self.b.to_double()
  ) /
  255.0
}

///|
/// 前景色取对比方向：底色亮则用深字，底色暗则用浅字。
pub fn Color::readable_foreground(self : Color) -> Color {
  if self.luminance() > 0.5 {
    Color::rgb(20, 20, 24)
  } else {
    Color::rgb(240, 240, 244)
  }
}

///|
fn clamp_component(v : Int) -> Int {
  if v < 0 {
    0
  } else if v > 255 {
    255
  } else {
    v
  }
}

///|
/// 四边内缩/外边距。命名用 `start/end` 便于以后做 RTL。
pub(all) struct EdgeInsets {
  top : Double
  end : Double
  bottom : Double
  start : Double
} derive(Debug, Eq)

///|
pub fn EdgeInsets::zero() -> EdgeInsets {
  EdgeInsets::{ top: 0.0, end: 0.0, bottom: 0.0, start: 0.0, }
}

///|
pub fn EdgeInsets::all(v : Double) -> EdgeInsets {
  EdgeInsets::{ top: v, end: v, bottom: v, start: v, }
}

///|
pub fn EdgeInsets::symmetric(
  vertical : Double,
  horizontal : Double,
) -> EdgeInsets {
  EdgeInsets::{
    top: vertical,
    end: horizontal,
    bottom: vertical,
    start: horizontal,
  }
}

///|
/// 横向总占用
pub fn EdgeInsets::horizontal(self : EdgeInsets) -> Double {
  self.start + self.end
}

///|
/// 纵向总占用
pub fn EdgeInsets::vertical(self : EdgeInsets) -> Double {
  self.top + self.bottom
}

///|
pub fn EdgeInsets::add(self : EdgeInsets, other : EdgeInsets) -> EdgeInsets {
  EdgeInsets::{
    top: self.top + other.top,
    end: self.end + other.end,
    bottom: self.bottom + other.bottom,
    start: self.start + other.start,
  }
}

///|
pub(all) enum FontWeight {
  Regular
  Medium
  Bold
} derive(Debug, Eq)

///|
/// 第一版的样式集合。字段为 None 表示继承，不参与 `merge` 覆盖。
pub(all) struct Style {
  width : Double?
  height : Double?
  min_width : Double?
  max_width : Double?
  margin : EdgeInsets?
  padding : EdgeInsets?
  background : Color?
  foreground : Color?
  font_size : Double?
  font_weight : FontWeight?
  radius : Double?
  opacity : Double?
} derive(Debug, Eq)

///|
pub fn Style::empty() -> Style {
  Style::{
    width: None,
    height: None,
    min_width: None,
    max_width: None,
    margin: None,
    padding: None,
    background: None,
    foreground: None,
    font_size: None,
    font_weight: None,
    radius: None,
    opacity: None,
  }
}

///|
/// §15 的构造形态：`style(padding=Some(EdgeInsets::all(12.0)), radius=Some(8.0))`。
/// 没写出来的字段保持 `None`，交给层叠去继承——这就是"第一版不做 CSS"的落地方式：
/// 样式表是一张稀疏的覆盖表，不是一条完整声明。
///
/// 形参用带默认值的 label 参数（`padding~ : EdgeInsets? = None`），因为这个版本的
/// MoonBit 不支持 `?padding : EdgeInsets` 的可选项写法，而默认值只能给 label 参数。
pub fn style(
  width? : Double? = None,
  height? : Double? = None,
  min_width? : Double? = None,
  max_width? : Double? = None,
  margin? : EdgeInsets? = None,
  padding? : EdgeInsets? = None,
  background? : Color? = None,
  foreground? : Color? = None,
  font_size? : Double? = None,
  font_weight? : FontWeight? = None,
  radius? : Double? = None,
  opacity? : Double? = None,
) -> Style {
  Style::{
    width,
    height,
    min_width,
    max_width,
    margin,
    padding,
    background,
    foreground,
    font_size,
    font_weight,
    radius,
    opacity,
  }
}

///|
/// 样式层叠：`self` 为低优先级（Theme/父容器），`over` 为高优先级（Widget 自身）。
/// 只覆盖 `over` 中显式设置的字段，这正是 §15 "第一版不做 CSS" 能成立的关键。
pub fn Style::layer(self : Style, over : Style) -> Style {
  Style::{
    width: pick(over.width, self.width),
    height: pick(over.height, self.height),
    min_width: pick(over.min_width, self.min_width),
    max_width: pick(over.max_width, self.max_width),
    margin: pick(over.margin, self.margin),
    padding: pick(over.padding, self.padding),
    background: pick(over.background, self.background),
    foreground: pick(over.foreground, self.foreground),
    font_size: pick(over.font_size, self.font_size),
    font_weight: pick(over.font_weight, self.font_weight),
    radius: pick(over.radius, self.radius),
    opacity: pick(over.opacity, self.opacity),
  }
}

///|
/// 有效内缩：未设置按零处理。
pub fn Style::effective_padding(self : Style) -> EdgeInsets {
  match self.padding {
    Some(e) => e
    None => EdgeInsets::zero()
  }
}

///|
fn[T] pick(over : T?, base : T?) -> T? {
  match over {
    Some(_) => over
    None => base
  }
}

///|
test "Color 混合与亮度推导" {
  let white = Color::rgb(255, 255, 255)
  let black = Color::rgb(0, 0, 0)
  // 完全不透明的上层直接覆盖
  assert_eq(Color::blend(white, black), Color::rgb(0, 0, 0))
  let half = Color::rgba(0, 0, 0, 128)
  let mixed = Color::blend(white, half)
  assert_true(mixed.r < 130 && mixed.r > 120)
  assert_true(white.luminance() > black.luminance())
  assert_eq(white.readable_foreground(), Color::rgb(20, 20, 24))
  assert_eq(black.readable_foreground(), Color::rgb(240, 240, 244))
}

///|
test "Style::layer 只覆盖显式设置的字段" {
  let base = Style::{
    width: None,
    height: None,
    min_width: None,
    max_width: None,
    margin: None,
    padding: None,
    background: Some(Color::rgb(1, 2, 3)),
    foreground: None,
    font_size: Some(14.0),
    font_weight: None,
    radius: Some(4.0),
    opacity: None,
  }
  let over = Style::{
    width: None,
    height: None,
    min_width: None,
    max_width: None,
    margin: None,
    padding: None,
    background: Some(Color::rgb(9, 9, 9)),
    foreground: None,
    font_size: None,
    font_weight: None,
    radius: None,
    opacity: Some(0.5),
  }
  let m = base.layer(over)
  assert_eq(m.background, Some(Color::rgb(9, 9, 9)))
  assert_eq(m.font_size, Some(14.0))
  assert_eq(m.radius, Some(4.0))
  assert_eq(m.opacity, Some(0.5))
  assert_eq(m.width, None)
}

///|
test "EdgeInsets 汇总与叠加" {
  let e = EdgeInsets::symmetric(8.0, 16.0)
  assert_eq(e.horizontal(), 32.0)
  assert_eq(e.vertical(), 16.0)
  assert_eq(EdgeInsets::all(2.0).add(e), EdgeInsets::{
    top: 10.0,
    end: 18.0,
    bottom: 10.0,
    start: 18.0,
  })
  assert_eq(Style::empty().effective_padding(), EdgeInsets::zero())
}
