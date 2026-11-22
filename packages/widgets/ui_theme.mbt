///|
/// 自绘控件的一套设计令牌（`T350`）：颜色、圆角、控件高度、字号。
///
/// 为什么先立令牌再写控件：原生控件之所以"看着不像一套"，根子不在单个控件
/// 的画法，而在每个控件各挑各的灰、各定各的高。`packages/widgets/ui_*` 这批
/// 控件共用一份 `UiTheme`，换个主题只换这一个值，不动任何一个控件的画法。
///
/// 为什么不直接读 `@moonui.Theme`：`Theme` 挂在 `App` 上（`App::palette`
/// 是解析后的那份），而控件只拿得到一个 `Backend`——`Widget` 没有"问应用要
/// 主题"的口子（`ProgressRing` 的段注同一条账）。所以令牌由调用方从
/// `App::palette` 转一次带进来：`UiTheme::from_palette(app.palette())`。
///
/// 颜色一律 `0xRRGGBB`（与 `DrawList` 同一条口径），不透明；需要透明度的地方
/// 由这里先混好色再交给画笔——`DrawCmd::StrokeRect` 没有 alpha 通道，混在令牌
/// 层比在每个控件里各混一次可靠。

///|
/// 一套令牌。字段都是"最终值"：控件只读不推导，换主题就是换这一整份。
pub(all) struct UiTheme {
  /// 窗口/页面底（自绘控件背后那一层，混合禁用态、描边过渡时当参照色）
  bg : Int32
  /// 控件静息底（次级按钮、输入框、勾选框未选时的面）
  surface : Int32
  surface_hover : Int32
  surface_active : Int32
  /// 凹槽底（分段控件、进度条轨道这一类"垫在下面的槽"）
  surface_sunken : Int32
  text : Int32
  text_muted : Int32
  text_disabled : Int32
  border : Int32
  border_strong : Int32
  accent : Int32
  accent_hover : Int32
  accent_active : Int32
  /// 主色块上的文字色
  on_accent : Int32
  danger : Int32
  success : Int32
  warning : Int32
  /// 进度条/开关的轨道
  track : Int32
  /// 键盘焦点环（已按底色调好，直接描一圈就是焦点态）
  focus_ring : Int32
  /// 控件圆角（按钮、输入框、分段控件的外框）
  radius : Double
  /// 正文（按钮/输入框标签）字号
  font_size : Double
  /// 小字（标签、分段控件的项、角标）字号
  font_size_sm : Double
}

///|
/// 浅色令牌。
///
/// 取值的口径：底色与面色差一格（`#F6F7F9` / `#FFFFFF`），边框比面色深两格
/// （`#DBDFE6`），主色 `#2B6CF0` 与 `on_accent` 白字对比度 4.6:1——过 WCAG
/// AA 的正文线，这是一颗"能当主按钮"的蓝，不是装饰蓝。
pub fn UiTheme::light() -> UiTheme {
  UiTheme::{
    bg: 0xF6F7F9,
    surface: 0xFFFFFF,
    surface_hover: 0xF1F3F6,
    surface_active: 0xE7EAEF,
    surface_sunken: 0xF0F2F5,
    text: 0x16181D,
    text_muted: 0x6B7280,
    text_disabled: 0xA8AEB8,
    border: 0xDBDFE6,
    border_strong: 0xC2C8D2,
    accent: 0x2B6CF0,
    accent_hover: 0x1E5FD9,
    accent_active: 0x1750BE,
    on_accent: 0xFFFFFF,
    danger: 0xE5484D,
    success: 0x1A9E5C,
    warning: 0xD98212,
    track: 0xE4E7EC,
    focus_ring: 0x8CB4F8,
    radius: 8.0,
    font_size: 13.0,
    font_size_sm: 12.0,
  }
}

///|
/// 深色令牌。
///
/// 深色下"悬停变亮、按下更亮"（而不是变暗）：在暗底上提亮才读得出"指针在这
/// 儿"，这是深色族与浅色族唯一不能共用的那条方向，所以 hover/active 两档在
/// 这里逐个写死，不按比例从 surface 推导。
pub fn UiTheme::dark() -> UiTheme {
  UiTheme::{
    bg: 0x16171B,
    surface: 0x22242A,
    surface_hover: 0x2B2E36,
    surface_active: 0x33363F,
    surface_sunken: 0x1B1D22,
    text: 0xECEDF1,
    text_muted: 0x9AA0AA,
    text_disabled: 0x5C616B,
    border: 0x383B44,
    border_strong: 0x4A4E59,
    accent: 0x4F8DF7,
    accent_hover: 0x6BA1FF,
    accent_active: 0x3C7BE0,
    on_accent: 0xFFFFFF,
    danger: 0xF26B6F,
    success: 0x3CCB7F,
    warning: 0xF0A93B,
    track: 0x2E3138,
    focus_ring: 0x2F4E86,
    radius: 8.0,
    font_size: 13.0,
    font_size_sm: 12.0,
  }
}

///|
/// 从 Core 的 `Palette` 转一套令牌：五格配色照抄，其余按深浅两侧各推一份。
///
/// 为什么还要一个 `dark` 参数：`Palette` 只有五个 token，看不出自己是深是浅
/// （深色的 `surface` 就是暗的，浅色的就是亮的——靠亮度猜会在中灰主题上翻车）。
/// 调用方本来就知道自己在哪个主题下（它选的就是 `Theme::Dark` 那支），说出来
/// 比猜可靠。
pub fn UiTheme::from_palette(
  p : @moonui.Palette,
  dark~ : Bool = false,
) -> UiTheme {
  let base = if dark { UiTheme::dark() } else { UiTheme::light() }
  let surface = ui_rgb_of(p.surface)
  let accent = ui_rgb_of(p.accent)
  // 悬停/按下的方向随深浅翻：浅色变暗一格、深色提亮一格（见两族令牌的段注）。
  let hover = if dark {
    ui_mix(surface, 0xFFFFFF, 0.08)
  } else {
    ui_mix(surface, 0x000000, 0.04)
  }
  let active = if dark {
    ui_mix(surface, 0xFFFFFF, 0.14)
  } else {
    ui_mix(surface, 0x000000, 0.09)
  }
  UiTheme::{
    bg: ui_rgb_of(p.background),
    surface,
    surface_hover: hover,
    surface_active: active,
    surface_sunken: if dark {
      ui_mix(ui_rgb_of(p.background), 0x000000, 0.25)
    } else {
      ui_mix(ui_rgb_of(p.background), 0x000000, 0.03)
    },
    text: ui_rgb_of(p.text),
    // 次级文字与禁用文字按正文色向底色调——两族令牌里那两格是同一套比例。
    text_muted: ui_mix(ui_rgb_of(p.text), ui_rgb_of(p.background), 0.38),
    text_disabled: ui_mix(ui_rgb_of(p.text), ui_rgb_of(p.background), 0.62),
    border: ui_rgb_of(p.border),
    border_strong: ui_mix(ui_rgb_of(p.border), ui_rgb_of(p.text), 0.18),
    accent,
    accent_hover: if dark {
      ui_mix(accent, 0xFFFFFF, 0.12)
    } else {
      ui_mix(accent, 0x000000, 0.10)
    },
    accent_active: if dark {
      ui_mix(accent, 0x000000, 0.12)
    } else {
      ui_mix(accent, 0x000000, 0.20)
    },
    // 主色够深就配白字、够浅就配深字：自定义主题的主色可能是浅黄。
    on_accent: if ui_luminance(accent) > 0.62 {
      0x16181D
    } else {
      0xFFFFFF
    },
    danger: base.danger,
    success: base.success,
    warning: base.warning,
    track: if dark {
      ui_mix(surface, 0xFFFFFF, 0.06)
    } else {
      ui_mix(surface, 0x000000, 0.08)
    },
    focus_ring: if dark {
      ui_mix(accent, ui_rgb_of(p.background), 0.45)
    } else {
      ui_mix(accent, 0xFFFFFF, 0.55)
    },
    radius: base.radius,
    font_size: base.font_size,
    font_size_sm: base.font_size_sm,
  }
}

///|
/// 三档控件尺寸。同一套控件在小号工具栏与大号表单里只换这一格。
pub(all) enum UiSize {
  UiSmall
  UiMedium
  UiLarge
}

///|
/// 一档尺寸落到具体数值：高度、左右内缩、项间距、字号、圆角。
///
/// 这些数不是随手挑的：高度 28/32/40 对应"工具栏 / 表单 / 触屏"三档，左右
/// 内缩约等于高度的 0.44 倍（32 × 0.44 ≈ 14），按钮看起来才不挤；圆角逐档
/// 加 1，与高度同步，免得大按钮的角看着像没磨过。
pub(all) struct UiMetrics {
  height : Double
  pad_x : Double
  gap : Double
  font : Double
  radius : Double
}

///|
pub fn UiTheme::metrics(self : UiTheme, size : UiSize) -> UiMetrics {
  match size {
    UiSmall =>
      UiMetrics::{
        height: 28.0,
        pad_x: 10.0,
        gap: 6.0,
        font: self.font_size_sm,
        radius: if self.radius > 1.0 {
          self.radius - 2.0
        } else {
          self.radius
        },
      }
    UiMedium =>
      UiMetrics::{
        height: 32.0,
        pad_x: 14.0,
        gap: 8.0,
        font: self.font_size,
        radius: self.radius,
      }
    UiLarge =>
      UiMetrics::{
        height: 40.0,
        pad_x: 18.0,
        gap: 10.0,
        font: self.font_size + 2.0,
        radius: self.radius + 2.0,
      }
  }
}

///|
/// `0xRRGGBB` 打包。
pub fn ui_rgb(r : Int32, g : Int32, b : Int32) -> Int32 {
  ((r & 255) << 16) | ((g & 255) << 8) | (b & 255)
}

///|
/// `@moonui.Color` → `0xRRGGBB`（alpha 不进画布命令：`Text`/`FillRect` 的色
/// 都是不透明 RGB，需要半透明请先混色）。
pub fn ui_rgb_of(c : @moonui.Color) -> Int32 {
  ui_rgb(c.r, c.g, c.b)
}

///|
/// 两色线性混合：`t=0` 取 `a`、`t=1` 取 `b`，越界夹住，四舍五入到整数通道。
///
/// 整数运算（与 `@moonui.Color::blend` 同一条规矩）：三端后端要得到逐位一致
/// 的颜色，浮点舍入差异会让"同一套令牌"在 mac 与 Windows 上差一格。
pub fn ui_mix(a : Int32, b : Int32, t : Double) -> Int32 {
  let k = if t < 0.0 { 0.0 } else if t > 1.0 { 1.0 } else { t }
  fn ch(c : Int32, shift : Int32) -> Int32 {
    (c >> shift) & 255
  }
  fn lerp(x : Int32, y : Int32) -> Int32 {
    (x.to_double() + (y - x).to_double() * k + 0.5).to_int()
  }
  (lerp(ch(a, 16), ch(b, 16)) << 16) |
  (lerp(ch(a, 8), ch(b, 8)) << 8) |
  lerp(ch(a, 0), ch(b, 0))
}

///|
/// 向黑混 `t`——浅色族的"悬停暗一格"。
pub fn ui_darken(c : Int32, t : Double) -> Int32 {
  ui_mix(c, 0x000000, t)
}

///|
/// 向白混 `t`——深色族的"悬停亮一格"，也用来做浅底上的淡色药丸（角标）。
pub fn ui_lighten(c : Int32, t : Double) -> Int32 {
  ui_mix(c, 0xFFFFFF, t)
}

///|
/// 感知亮度 0..1（Rec.709 系数，与 `@moonui.Color::luminance` 同一套）——
/// "这块底该配深字还是浅字"的唯一判据。
pub fn ui_luminance(c : Int32) -> Double {
  let r = ((c >> 16) & 255).to_double()
  let g = ((c >> 8) & 255).to_double()
  let b = (c & 255).to_double()
  (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
}

///|
/// 交互三态（悬停 / 按下 / 焦点）+ 使能。
///
/// 为什么状态与控件分两张（`RingState` 同一条账）：绘制回调是在 `Widget::custom`
/// 那一刻注册的，那时控件还不存在，闭包只能捕获这份状态；事件订阅在控件建好
/// 之后挂，捕获的也是同一份——于是"事件改状态 → 状态驱动重画"这条链在
/// Core 侧闭合，不需要给 Widget 加任何新字段。
priv struct UiInteract {
  mut hovered : Bool
  mut pressed : Bool
  mut focused : Bool
  mut enabled : Bool
}

///|
fn UiInteract::new(enabled~ : Bool = true) -> UiInteract {
  { hovered: false, pressed: false, focused: false, enabled, }
}

///|
/// 把三态的订阅一次挂齐：悬停 / 按下 / 焦点各翻一位，翻面就重画一次。
///
/// 只订阅"会改这三位"的事件，别的（Click、Input、Scroll）一概不进来——自绘
/// 面的事件处理器是按条匹配的，多接一类就多一条每事件的分支。
///
/// `MouseDown` 只认左键：右键是上下文菜单的地盘（`set_context_menu`），把它
/// 画成"按下"会让右键菜单弹出前按钮先凹一下。
fn[B : @moonui.Backend] ui_watch_state(
  w : @moonui.Widget[B],
  it : UiInteract,
) -> Unit raise @moonui.UiError {
  let _ = w.on(
    fn(e) {
      match e {
        @moonui.MouseEnter(_) | @moonui.MouseLeave(_) => true
        @moonui.MouseDown(_, @moonui.Left, _, _) => true
        @moonui.MouseUp(_, @moonui.Left, _, _) => true
        @moonui.Focus(_) | @moonui.Blur(_) => true
        _ => false
      }
    },
    fn(e) raise @moonui.UiError {
      match e {
        @moonui.MouseEnter(_) =>
          if !it.hovered {
            it.hovered = true
            w.repaint()
          }
        @moonui.MouseLeave(_) =>
          // 离开时把"按下"一并摘掉：指针从按钮上拖出去就是取消这次点击，
          // 不摘的话回来时按钮还凹着（抬起发生在别处，收不到 MouseUp）。
          if it.hovered || it.pressed {
            it.hovered = false
            it.pressed = false
            w.repaint()
          }
        @moonui.MouseDown(_, _, _, _) =>
          if !it.pressed && it.enabled {
            it.pressed = true
            w.repaint()
          }
        @moonui.MouseUp(_, _, _, _) =>
          if it.pressed {
            it.pressed = false
            w.repaint()
          }
        @moonui.Focus(_) =>
          if !it.focused {
            it.focused = true
            w.repaint()
          }
        @moonui.Blur(_) =>
          if it.focused {
            it.focused = false
            w.repaint()
          }
        _ => ()
      }
    },
  )
}

///|
/// 画一块圆角实色。半径按短边的一半夹住——`DrawCmd::FillRect` 的半径超过
/// 半高就是椭圆，后端各自夹的口径不一定一样（`fill_rect` 只有 GDI+ 与
/// CG 两支实现），夹在这里四端一致。
fn ui_paint_fill(
  dl : @moonui.DrawList,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  radius : Double,
  rgb : Int32,
) -> Unit {
  let r = ui_clamp_radius(radius, w, h)
  dl.fill_rect(x, y, w, h, radius=r, rgb~)
}

///|
/// 描一圈圆角边：`inset` 是描边中心线离矩形边的距离（0.5 = 1px 线画在边上）。
fn ui_paint_stroke(
  dl : @moonui.DrawList,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  radius : Double,
  inset : Double,
  width : Double,
  rgb : Int32,
) -> Unit {
  let ww = w - inset * 2.0
  let hh = h - inset * 2.0
  if ww <= 0.0 || hh <= 0.0 {
    return
  }
  dl.stroke_rect(
    x + inset,
    y + inset,
    ww,
    hh,
    radius=ui_clamp_radius(radius - inset, ww, hh),
    width~,
    rgb~,
  )
}

///|
/// 半径夹到"短边的一半"以内，负值归零。
fn ui_clamp_radius(radius : Double, w : Double, h : Double) -> Double {
  let half = if w < h { w / 2.0 } else { h / 2.0 }
  if radius <= 0.0 {
    0.0
  } else if radius > half {
    half
  } else {
    radius
  }
}

///|
/// 在 [x, x+w] × [y, y+h] 这个盒子里画一行居中的字：放不下就省略号收尾
/// （`text_fit.mbt` 的 `ellipsize`，与表格单元格同一条截断算术），放得下就
/// 按量出来的宽度真正居中——不用"估计宽度"那一半，否则不同字族的按钮里
/// 文字左右留白会各差一格。
fn ui_paint_center_text(
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  text : String,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  font : Double,
  bold : Bool,
  rgb : Int32,
) -> Unit {
  if text == "" || w <= 0.0 || h <= 0.0 {
    return
  }
  let (tw, th) = env.measure_text(text, font, bold)
  let ty = y + (h - th) / 2.0
  // 与 `draw_fitted_text` 同一条容差：按文案算宽的控件里"刚好卡满"是最常见
  // 的一档，差 1e-15 就退到省略号那一支会整行不画（`TEXT_FIT_EPS` 段注）。
  if tw <= w + 0.01 {
    dl.text(text, x + (w - tw) / 2.0, ty, size=font, bold~, rgb~)
    return
  }
  let shown = ellipsize(env, text, font, bold, w)
  if shown == "" {
    return
  }
  let (sw, _) = env.measure_text(shown, font, bold)
  dl.save()
  dl.clip_rect(x, y, w, h)
  dl.text(shown, x + (w - sw) / 2.0, ty, size=font, bold~, rgb~)
  dl.restore()
}

///|
/// 焦点环：沿控件外框描 1.5px。没有 alpha 通道，所以焦点色由令牌先混好
/// （`focus_ring`），这里不叠透明度——描两遍同色会把环画粗一倍。
fn ui_paint_focus_ring(
  dl : @moonui.DrawList,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  radius : Double,
  rgb : Int32,
) -> Unit {
  ui_paint_stroke(dl, x, y, w, h, radius, 1.25, 1.5, rgb)
}

///|
/// 一个圆：`fill_rect` 的半径等于半高，四端都画成圆（`DrawCmd` 没有单独的
/// 画圆命令——`ProgressRing` 用的是描边弧，实心圆只能这样拼）。
fn ui_paint_dot(
  dl : @moonui.DrawList,
  cx : Double,
  cy : Double,
  r : Double,
  rgb : Int32,
) -> Unit {
  if r <= 0.0 {
    return
  }
  dl.fill_rect(cx - r, cy - r, r * 2.0, r * 2.0, radius=r, rgb~)
}

///|
/// 一段文字按后端度量算宽度（`Backend::measure_text`）。构造期就要定固有
/// 尺寸的控件（按钮、页签、角标）靠它，而不是等第一次绘制——布局不能等到
/// 画的那一刻才知道自己多宽。
///
/// 量不到给零宽：真机上走不到（画布活着），mock 上按"每字符 8 × 字号/12"
/// 给确定性值，判据因此能写死期望尺寸。
fn[B : @moonui.Backend] ui_measure(
  backend : B,
  text : String,
  font : Double,
  bold : Bool,
) -> (Double, Double) {
  if text == "" {
    return (0.0, 0.0)
  }
  @moonui.Backend::measure_text(backend, text, font, bold) catch {
    _ => (0.0, 0.0)
  }
}

///|
/// 语义色档（`T351`）：角标、进度条、提示条共用一套"好消息/坏消息"的颜色。
///
/// 为什么不直接传一个 `Int32`：调用方要的从来不是"某个绿"，而是"成功"这个
/// 语义；由令牌给出具体颜色，深色主题下才不用调用方自己挑一遍。`UiNeutral`
/// 是"没有语义"（灰），不是"没有颜色"。
#derive(Debug, Eq)
pub(all) enum UiTone {
  UiNeutral
  UiAccent
  UiSuccess
  UiWarning
  UiDanger
}

///|
/// 语义色 → 具体颜色（取令牌里对应的那一格）。
pub fn UiTheme::tone(self : UiTheme, tone : UiTone) -> Int32 {
  match tone {
    UiNeutral => self.text_muted
    UiAccent => self.accent
    UiSuccess => self.success
    UiWarning => self.warning
    UiDanger => self.danger
  }
}

///|
/// 语义色的淡底（角标、药丸那种"浅底 + 同色字"）：把语义色往面色里混。
///
/// 深浅由面色的亮度自己判：暗面混得多一点——同比例混在暗底上会得到一块"闷"
/// 的色块，浅色主题下的同款比例反而正好。这条判据不看 `UiTheme` 之外的东西，
/// 所以从 `App::palette` 转出来的自定义主题也照走。
pub fn UiTheme::tone_surface(self : UiTheme, tone : UiTone) -> Int32 {
  let c = self.tone(tone)
  if ui_luminance(self.surface) < 0.5 {
    ui_mix(c, self.surface, 0.78)
  } else {
    ui_mix(c, self.surface, 0.88)
  }
}

///|
/// `0xRRGGBB` → `@moonui.Color`：样式表那条通道（Panel 的底、圆角）只吃
/// `Color`，而令牌里全是打包好的 `Int32`（`DrawList` 那条通道的口径）。
/// 两套表示之间只有这一处转换，和 `ui_rgb_of` 正好互为逆。
pub fn ui_color(c : Int32) -> @moonui.Color {
  @moonui.Color::rgb((c >> 16) & 255, (c >> 8) & 255, c & 255)
}
