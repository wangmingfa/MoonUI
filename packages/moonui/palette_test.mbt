///|
/// `T199`：`"#RRGGBB"` / `"RRGGBB"` / `"#RRGGBBAA"` 三种写法都认，坏值一律
/// `None`；`to_hex` 与它成对——写出去的文本读得回来。
test "Color：hex 往返与拒绝（T199）" {
  let blue = @moonui.Color::rgb(24, 116, 190)
  // 大小写与首尾空白都不算坏值：这几个字都是从人手写的配色档里来的
  assert_eq(@moonui.Color::from_hex("#1874BE"), Some(blue))
  assert_eq(@moonui.Color::from_hex("1874be"), Some(blue))
  assert_eq(
    @moonui.Color::from_hex("  #ffffff  "),
    Some(@moonui.Color::rgb(255, 255, 255)),
  )
  // 八位时后两位是 alpha
  assert_eq(
    @moonui.Color::from_hex("#11223344"),
    Some(@moonui.Color::rgba(17, 34, 51, 68)),
  )
  // 不补零、不截断：长度不对就是不对（少一位是笔误，猜出来的颜色更难查）
  assert_eq(@moonui.Color::from_hex("#12345"), None)
  assert_eq(@moonui.Color::from_hex("#1234567"), None)
  assert_eq(@moonui.Color::from_hex("#GGGGGG"), None)
  assert_eq(@moonui.Color::from_hex(""), None)
  assert_eq(@moonui.Color::from_hex("#"), None)
  // 写出去：不透明省掉 alpha，半透明补上
  assert_eq(blue.to_hex(), "#1874BE")
  assert_eq(@moonui.Color::rgba(17, 34, 51, 68).to_hex(), "#11223344")
  // 往返：读进来再写出去，字面原样（八位那两例也走这条）
  for s in ["#000000", "#FFFFFF", "#1874BE", "#11223344"] {
    assert_eq(@moonui.Color::from_hex(s).unwrap().to_hex(), s)
  }
}

///|
/// 测试用的档：读不懂就让判据当场红，不写"读不懂就当空档"的兜底——那条兜底
/// 会把"这段 JSON 本身写错了"伪装成"配色兜默认了"。
fn palette_settings_of(text : String) -> @moonui.Settings {
  match @moonui.Settings::parse(text) {
    Some(s) => s
    None => abort("测试档读不懂：\{text}")
  }
}

///|
/// `T199`：缺 token 兜默认、坏值也兜默认，而且**每一格独立兜**——一个 token
/// 写坏不该把整份档带走。
test "Palette：缺 token 与坏值逐格兜默认（T199）" {
  let light = @moonui.Theme::light_palette()
  // 空档：五格全默认
  assert_eq(@moonui.Palette::from_settings(palette_settings_of("{}")), light)
  // 只写了一格：那一格生效，其余留默认
  let red = @moonui.Palette::from_settings(
    palette_settings_of("{\"accent\":\"#FF0000\"}"),
  )
  assert_eq(red.accent, @moonui.Color::rgb(255, 0, 0))
  assert_eq(red.background, light.background)
  assert_eq(red.surface, light.surface)
  assert_eq(red.text, light.text)
  assert_eq(red.border, light.border)
  // 坏值三态：不是颜色 / 不是字符串 / 长度不对——各自退回默认，好那几格照旧生效
  let mixed = @moonui.Palette::from_settings(
    palette_settings_of(
      "{\"accent\":\"not-a-color\",\"surface\":123,\"background\":\"#12\",\"text\":\"#00FF00\"}",
    ),
  )
  assert_eq(mixed.accent, light.accent)
  assert_eq(mixed.surface, light.surface)
  assert_eq(mixed.background, light.background)
  assert_eq(mixed.text, @moonui.Color::rgb(0, 255, 0))
}

///|
/// `T199`：`overlay` 让调用方自己挑底——深色族做底时，档里只写想改的那几格，
/// 没写的仍然是深色默认，不会掉回浅色。
test "Palette：overlay 以调用方给的底兜默认（T199）" {
  let dark = @moonui.Theme::dark_palette()
  let p = dark.overlay(
    palette_settings_of("{\"accent\":\"#FF0000\"}").to_json(),
  )
  assert_eq(p.accent, @moonui.Color::rgb(255, 0, 0))
  assert_eq(p.background, dark.background)
  assert_eq(p.text, dark.text)
  assert_true(p != @moonui.Theme::light_palette())
  // 顶层不是对象（数组/标量）：整份原样返回，不清空。清空等于"写坏一个字符
  // 就换了张脸"，而 JSON 里最容易被写坏的就是顶层括号。
  let not_object = palette_settings_of("{\"x\":[]}").get_json("x").unwrap()
  assert_eq(dark.overlay(not_object), dark)
  assert_eq(
    @moonui.Palette::from_json(not_object),
    @moonui.Theme::light_palette(),
  )
}

///|
/// `T199`：配色能存成档再读回来（`to_settings` / `from_settings` 成对）。
/// 断言走一遍文本——只比结构的话，"写出去的东西 `from_settings` 读不回"这种
/// 半边坏掉的情形看不出来。
test "Palette：存成档再读回来逐格相同（T199）" {
  let p = @moonui.Palette::{
    background: @moonui.Color::rgb(16, 16, 20),
    surface: @moonui.Color::rgb(24, 24, 32),
    text: @moonui.Color::rgb(236, 236, 240),
    accent: @moonui.Color::rgb(110, 160, 255),
    border: @moonui.Color::rgb(58, 58, 66),
  }
  let text = p.to_settings().to_json().stringify()
  assert_eq(@moonui.Palette::from_settings(palette_settings_of(text)), p)
  // 档里的值就是十六进制文本，不是数字或对象（人能看懂、手能改）
  assert_eq(p.to_settings().get_string("accent", ""), "#6EA0FF")
}

///|
/// `T199`：底样式从配色来——底色用 `surface`、前景用 `text`。
/// 这是 `App::style_base` 现在走的唯一一条路（改配色就改这一份）。
test "Palette：default_style 用 surface 做底、text 做前景（T199）" {
  let p = @moonui.Theme::dark_palette()
  let s = p.default_style()
  assert_eq(s.background, Some(p.surface))
  assert_eq(s.foreground, Some(p.text))
  // 其余属性留空，等着控件与父容器往上盖
  assert_eq(s.font_size, None)
  assert_eq(s.radius, None)
}
