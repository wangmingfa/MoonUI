///|
/// 自绘控件的绘制配方（§52.5 分期②）：配方只说"这个 kind 在这个状态画
/// 什么"，不问画布底下是 CoreGraphics 还是录制器——Backend 永远不能反向
/// 决定 API（§51），配方也不能。
///
/// 输入全是**逻辑像素**与已解析的样式值（颜色/字号/圆角），状态由调用方
/// （后端装配）从记账里带来；配方无状态。

///|
/// 面板（皮肤账的载体）：一张底色圆角面。bg/radius 是解析后的生效值。
pub fn[P : Painter] paint_panel(
  p : P,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  bg : Int32,
  radius~ : Double = 0.0,
) -> Unit raise @moonui.UiError {
  p.fill_rect(x, y, w, h, radius, bg, 255)
}

///|
/// 毛玻璃面板（T98②，YesPlayMusic navbar/player 的观感）：先把这块区域
/// **后面已画上去的内容**原地模糊（blur_region，"毛"的来源），再叠一层
/// 半透底（bg + alpha，"玻璃"的来源）。顺序不能反——先叠底再模糊会把
/// 半透底自己也糊掉。bg 是 0xRRGGBB，alpha 0..255（YPM navbar 是
/// rgba(255,255,255,0.86) → bg=0xFFFFFF, alpha≈219）。
pub fn[P : Painter] paint_frosted_panel(
  p : P,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  bg : Int32,
  alpha : Int32,
  blur~ : Double,
  radius~ : Double = 0.0,
) -> Unit raise @moonui.UiError {
  p.blur_region(x, y, w, h, blur)
  p.fill_rect(x, y, w, h, radius, bg, alpha)
}

///|
/// 标签：单行文本，垂直居中在给定行框里。fg/size/bold 是解析后的生效值。
pub fn[P : Painter] paint_label(
  p : P,
  text : String,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  fg : Int32,
  size~ : Double,
  bold~ : Bool = false,
) -> Unit raise @moonui.UiError {
  // w 留在签名里是行框口径的一部分（配方入参全对称），本配方不按宽裁剪
  ignore(w)
  let (_, th) = p.measure_text(text, size, bold)
  let ty = y + (h - th) / 2.0
  p.text(text, x, ty, size, bold, fg)
}

///|
/// 控件状态三件（自绘语义的最小集）：常态/悬停/按下。
pub(all) enum PaintState {
  Normal
  Hover
  Pressed
}

///|
/// 按钮配色账：状态→底色/前景色。三个色都由调用方解析（主题/皮肤说了算），
/// 配方只负责"哪个状态用哪个、怎么摆"。
pub(all) struct ButtonFace {
  normal_bg : Int32
  hover_bg : Int32
  pressed_bg : Int32
  fg : Int32
  radius : Double
}

///|
/// 图标钮：圆角底 + 居中字形（icon 用文本字形画——录制式与位图两态都可断言；
/// 真位图图标走 draw_image，是另一条配方）。
pub fn[P : Painter] paint_icon_button(
  p : P,
  glyph : String,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  face : ButtonFace,
  state : PaintState,
  glyph_size~ : Double = 14.0,
) -> Unit raise @moonui.UiError {
  let bg = match state {
    Normal => face.normal_bg
    Hover => face.hover_bg
    Pressed => face.pressed_bg
  }
  p.fill_rect(x, y, w, h, face.radius, bg, 255)
  // 字形居中：先量，再按矩形心摆
  let (gw, gh) = p.measure_text(glyph, glyph_size, false)
  let gx = x + (w - gw) / 2.0
  let gy = y + (h - gh) / 2.0
  p.text(glyph, gx, gy, glyph_size, false, face.fg)
}

///|
/// 滑条：轨道 + 已过段 + 拇指钮。value 是千分位 0..1000。轨道色/已过段色
/// （常见音乐客户端的红色轨道就是 accent）/拇指色都由调用方给。
pub fn[P : Painter] paint_slider(
  p : P,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  value : Int32,
  track~ : Int32,
  accent~ : Int32,
  thumb~ : Int32,
) -> Unit raise @moonui.UiError {
  // 轨道：高 4，垂直居中
  let track_h = 4.0
  let ty = y + (h - track_h) / 2.0
  p.fill_rect(x, ty, w, track_h, track_h / 2.0, track, 255)
  // 已过段：按千分位截宽
  let filled = w * value.to_double() / 1000.0
  if filled > 0.5 {
    p.fill_rect(x, ty, filled, track_h, track_h / 2.0, accent, 255)
  }
  // 拇指钮：直径 14 的圆（圆角半径 = 半径），心在已过段的端点上
  let d = 14.0
  let cx = x + filled - d / 2.0
  let cy = y + (h - d) / 2.0
  p.fill_rect(cx, cy, d, d, d / 2.0, thumb, 255)
}

///|
/// 菜单行（常见音乐客户端侧栏那种"一行一项"）：选中时圆角高亮底 + 强调色文案，
/// 常态纯文案。文本左对齐带 12 缩进、垂直居中——真后端（mac 设置侧栏）
/// 的形状在这里画出来（§51 MenuRow 的自绘半）。
pub fn[P : Painter] paint_menu_row(
  p : P,
  text : String,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  selected~ : Bool,
  fg~ : Int32,
  selected_fg~ : Int32,
  selected_bg~ : Int32 = 0xEFEFF1,
  size~ : Double = 14.0,
  bold~ : Bool = false,
) -> Unit raise @moonui.UiError {
  if selected {
    p.fill_rect(x, y, w, h, 6.0, selected_bg, 255)
  }
  // 垂直居中在行框里；选中换强调色文案
  let color = if selected { selected_fg } else { fg }
  let (_, th) = p.measure_text(text, size, bold)
  p.text(text, x + 12.0, y + (h - th) / 2.0, size, bold, color)
}

///|
/// 文本输入框：圆角描边框 + 左对齐垂直居中的文案（占位符由调用方换色）。
/// 聚焦态的第一版不做（没有焦点事件源），框色由调用方给。
pub fn[P : Painter] paint_text_input(
  p : P,
  text : String,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  fg~ : Int32,
  border~ : Int32 = 0xDDDDDD,
  size~ : Double = 13.0,
  radius~ : Double = 8.0,
) -> Unit raise @moonui.UiError {
  p.stroke_rect(x, y, w, h, radius, 1.0, border)
  ignore(w)
  let (_, th) = p.measure_text(text, size, false)
  p.text(text, x + 8.0, y + (h - th) / 2.0, size, false, fg)
}

///|
/// 分隔线：水平 1px 线，垂直居中在给定行框里（Column/Row 里当间距件用）。
pub fn[P : Painter] paint_separator(
  p : P,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  rgb~ : Int32 = 0xE0E0E0,
) -> Unit raise @moonui.UiError {
  p.line(x, y + (h - 1.0) / 2.0, x + w, y + (h - 1.0) / 2.0, 1.0, rgb)
}

///|
/// 渐变面板（§15）：垂直渐变走 `fill_linear`（单次调用，Painter 的纵向原语）；
/// 水平渐变没有对应原语，用 N 条竖带 `fill_rect` 采样近似。stops 是
/// (位置 0..1, 0xRRGGBB) 升序表。半径在渐变路径下不做圆角裁剪（与原生一致：
/// 真渐变面板按矩形铺，圆角是纯色面板/毛玻璃的事）。
pub fn[P : Painter] paint_gradient_panel(
  p : P,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  stops : Array[(Double, Int32)],
  horizontal~ : Bool = false,
  bands~ : Int32 = 32,
) -> Unit raise @moonui.UiError {
  if !horizontal {
    p.fill_linear(x, y, w, h, stops)
    return
  }
  let n : Int32 = if bands < 2 { 2 } else { bands }
  let step = w / n.to_double()
  for i = 0; i < n; i = i + 1 {
    let t = (i.to_double() + 0.5) / n.to_double()
    let c = sample_stops(stops, t)
    // +0.5 叠边，避免浮点缝隙露底
    p.fill_rect(
      x + w * i.to_double() / n.to_double(),
      y,
      step + 0.5,
      h,
      0.0,
      c,
      255,
    )
  }
}

///|
/// 在色标表上按位置取 0xRRGGBB（分段线性，t 钳在 [0,1]）。空表返回黑色。
fn sample_stops(stops : Array[(Double, Int32)], t : Double) -> Int32 {
  let n = stops.length()
  if n == 0 {
    return 0
  }
  let tt : Double = if t < 0.0 { 0.0 } else if t > 1.0 { 1.0 } else { t }
  let first = stops[0]
  if tt <= first.0 {
    return first.1
  }
  for i = 1; i < n; i = i + 1 {
    let a = stops[i - 1]
    let b = stops[i]
    if tt <= b.0 {
      let span = b.0 - a.0
      let k : Double = if span <= 0.0 { 0.0 } else { (tt - a.0) / span }
      return lerp_rgb(a.1, b.1, k)
    }
  }
  stops[n - 1].1
}

///|
/// 两色 0xRRGGBB 线性混合（k=0 → a，k=1 → b）。
fn lerp_rgb(a : Int32, b : Int32, k : Double) -> Int32 {
  fn ch(shift : Int32) -> Int32 {
    let ca = (a >> shift) & 0xFF
    let cb = (b >> shift) & 0xFF
    (ca.to_double() + (cb - ca).to_double() * k + 0.5).to_int() << shift
  }
  ch(16) | ch(8) | ch(0)
}
