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
///
/// 三个形状参数与原生半对齐（`T203`②）：`knob_d` 圆点直径（原生半是 12pt），
/// `track_h` 槽高（原生半是整高 1/3 夹 3..10，换算归调用方），`knob_map`
/// 千分位→圆心横偏移的映射。原生半读系统拇指的真矩形，自绘没有那把尺可读，
/// 默认取它的近似形状 `clamp(W·t, d/2, W−d/2)`——两端各让出半个圆点，中段
/// 与"已过段端点 = 圆心"同线；换皮肤时给一份自己的映射即可，不必改配方。
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
  knob_d~ : Double = 12.0,
  track_h~ : Double = 4.0,
  knob_map~ : ((Double, Double) -> Double)? = None,
) -> Unit raise @moonui.UiError {
  // 轨道：垂直居中，高由调用方给
  let ty = y + (h - track_h) / 2.0
  p.fill_rect(x, ty, w, track_h, track_h / 2.0, track, 255)
  // 已过段：按千分位截宽
  let t = value.to_double() / 1000.0
  let filled = w * t
  if filled > 0.5 {
    p.fill_rect(x, ty, filled, track_h, track_h / 2.0, accent, 255)
  }
  // 拇指钮：圆心在映射给出的横偏移上（默认 clamp(W·t, d/2, W−d/2)）
  let cx_off = match knob_map {
    Some(f) => f(w, t)
    None => {
      let raw = filled
      let lo = knob_d / 2.0
      let hi = w - knob_d / 2.0
      if raw < lo {
        lo
      } else if raw > hi {
        hi
      } else {
        raw
      }
    }
  }
  let cx = x + cx_off - knob_d / 2.0
  let cy = y + (h - knob_d) / 2.0
  p.fill_rect(cx, cy, knob_d, knob_d, knob_d / 2.0, thumb, 255)
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
/// 配方本身不画聚焦态——焦点环由后端统一画（`T370` 的 `paint_focus_ring`），
/// 框色由调用方给。
/// `text` 为空且 `placeholder` 非空时画占位灰字（`placeholder_fg`），语义与
/// 原生半的 placeholderString / EM_SETCUEBANNER 对齐。
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
  placeholder~ : String = "",
  placeholder_fg~ : Int32 = 0xAAAAAA,
  caret~ : Int32 = -1,
  caret_fg~ : Int32 = 0x333333,
) -> Unit raise @moonui.UiError {
  p.stroke_rect(x, y, w, h, radius, 1.0, border)
  let shown = if text.length() == 0 { placeholder } else { text }
  let color = if text.length() == 0 && placeholder.length() > 0 {
    placeholder_fg
  } else {
    fg
  }
  // 占位符与正文同一条起点（`T379` 真窗口反馈）：之前给光标让 2px 车道，聚焦
  // 那一刻整段字会平移，看着像"输入框被挤了一下"。现在不让——光标就落在首字
  // 左缘，与原生输入框一致。
  let text_x = x + 8.0
  // 空串不量也不画：原生 `canvas_measure_text/draw_text` 对空串返回失败，
  // 会把整条配方挂掉（同一帧后面的焦点环也跟着丢）。
  if shown != "" {
    let (_, th) = p.measure_text(shown, size, false)
    p.text(shown, text_x, y + (h - th) / 2.0, size, false, color)
  }
  // 光标（`T374`）：按**原文**字符下标量前缀宽，空文本落在 x+8（占位符起点）。
  // 空前缀量不出行高（原生给 0），光标高度退回 1.4 倍字号。颜色走独立入参
  // `caret_fg`，按**正文墨色**传（不跟占位灰走）；线宽 1.5——1px 在 Retina 上
  // 偏细（`T379` 真窗口反馈），再粗就盖住字形了。
  if caret >= 0 {
    let idx = caret.clamp(min=0, max=text.length())
    let prefix = text[0:idx].to_owned()
    let mut cw = 0.0
    let mut ch = size * 1.4
    if prefix != "" {
      let (mwo, mho) = p.measure_text(prefix, size, false)
      cw = mwo
      ch = mho
    }
    let cx = (x + 8.0 + cw).clamp(min=x + 1.0, max=x + w - 2.0)
    let top = y + (h - ch) / 2.0
    p.line(cx, top, cx, top + ch, 1.5, caret_fg)
  }
}

///|
/// 勾选框：左边一个方框 + 右边文案。选中时方框填强调色并画白色勾；禁用态
/// 只降对比（边框/文字/勾选底一起换灰），形状不变。
///
/// 方框边长随行高收放（`clamp(h-4, 12, 18)`），垂直居中；文案缩进 = 方框宽
/// + 8。勾用两段 `line` 画（不量字、不依赖字体里有没有勾字符）。
pub fn[P : Painter] paint_checkbox(
  p : P,
  text : String,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  checked~ : Bool,
  fg~ : Int32,
  accent~ : Int32,
  border~ : Int32 = 0xDDDDDD,
  mute~ : Int32 = 0xB8B8BD,
  size~ : Double = 13.0,
  enabled~ : Bool = true,
) -> Unit raise @moonui.UiError {
  let raw = h - 4.0
  let s = if raw < 12.0 { 12.0 } else if raw > 18.0 { 18.0 } else { raw }
  let by = y + (h - s) / 2.0
  let line_rgb = if enabled { border } else { 0xE0E0E3 }
  if checked {
    p.fill_rect(
      x,
      by,
      s,
      s,
      s / 4.0,
      if enabled {
        accent
      } else {
        0xC9C9CE
      },
      255,
    )
    // 白勾：左下 → 谷底 → 右上，线宽随方框收放
    let lw = if s < 16.0 { 1.5 } else { 2.0 }
    p.line(
      x + s * 0.25,
      by + s * 0.55,
      x + s * 0.43,
      by + s * 0.72,
      lw,
      0xFFFFFF,
    )
    p.line(
      x + s * 0.43,
      by + s * 0.72,
      x + s * 0.75,
      by + s * 0.30,
      lw,
      0xFFFFFF,
    )
  } else {
    p.fill_rect(x, by, s, s, s / 4.0, 0xFFFFFF, 255)
    p.stroke_rect(x, by, s, s, s / 4.0, 1.0, line_rgb)
  }
  let (_, th) = p.measure_text(text, size, false)
  p.text(
    text,
    x + s + 8.0,
    y + (h - th) / 2.0,
    size,
    false,
    if enabled {
      fg
    } else {
      mute
    },
  )
  ignore(w)
}

///|
/// 进度条：整条槽 + 左侧已过段（强调色）。`value` 走 Core 的口径——0..100，
/// `-1` 是"不定进度"。
///
/// 不定进度画一段固定的 30% 强调段（起点 35%）：相位动画归应用/控件，配方
/// 无状态、只保证"看得出它在忙"。槽与已过段都用半高圆角，两端是圆的。
pub fn[P : Painter] paint_progress(
  p : P,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  value : Int32,
  track~ : Int32,
  accent~ : Int32,
) -> Unit raise @moonui.UiError {
  let r = h / 2.0
  p.fill_rect(x, y, w, h, r, track, 255)
  if value < 0 {
    let seg = w * 0.30
    p.fill_rect(x + w * 0.35, y, seg, h, r, accent, 255)
  } else {
    let v = if value > 100 { 100 } else { value }
    let t = v.to_double() / 100.0
    let filled = w * t
    if filled > 0.5 {
      p.fill_rect(x, y, filled, h, r, accent, 255)
    }
  }
}

///|
/// 数字框：圆角描边框 + 左对齐文案 + 右侧 18px 步进区（竖分隔线 + 上下两个
/// 折线箭头）。箭头用 `line` 画，不依赖字体里的三角字符；禁用态整体换灰。
pub fn[P : Painter] paint_spinbox(
  p : P,
  text : String,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  fg~ : Int32,
  border~ : Int32 = 0xDDDDDD,
  mute~ : Int32 = 0xB8B8BD,
  size~ : Double = 13.0,
  radius~ : Double = 6.0,
  enabled~ : Bool = true,
  caret~ : Int32 = -1,
  caret_fg~ : Int32 = 0x333333,
) -> Unit raise @moonui.UiError {
  let edge = if enabled { border } else { 0xE0E0E3 }
  p.stroke_rect(x, y, w, h, radius, 1.0, edge)
  let color = if enabled { fg } else { mute }
  if text != "" {
    let (_, th) = p.measure_text(text, size, false)
    p.text(text, x + 8.0, y + (h - th) / 2.0, size, false, color)
  }
  // 光标（`T374`）：与文本框同一套前缀定位；右侧让开步进区。
  if caret >= 0 {
    let idx = caret.clamp(min=0, max=text.length())
    let prefix = text[0:idx].to_owned()
    let mut cw = 0.0
    let mut ch = size * 1.4
    if prefix != "" {
      let (mwo, mho) = p.measure_text(prefix, size, false)
      cw = mwo
      ch = mho
    }
    let right = if w > 26.0 { x + w - 20.0 } else { x + w - 2.0 }
    let cx = (x + 8.0 + cw).clamp(min=x + 1.0, max=right)
    let top = y + (h - ch) / 2.0
    p.line(cx, top, cx, top + ch, 1.5, caret_fg)
  }
  // 步进区：右侧 18px，竖分隔线 + 两个折线箭头
  let step_w = 18.0
  let div = x + w - step_w
  if w > step_w + 8.0 {
    p.line(div, y + 1.0, div, y + h - 1.0, 1.0, edge)
    let cx = div + step_w / 2.0
    let cy1 = y + h * 0.30
    let cy2 = y + h * 0.70
    let arrow = if enabled { fg } else { mute }
    p.line(cx - 3.0, cy1 + 2.0, cx, cy1 - 2.0, 1.5, arrow)
    p.line(cx, cy1 - 2.0, cx + 3.0, cy1 + 2.0, 1.5, arrow)
    p.line(cx - 3.0, cy2 - 2.0, cx, cy2 + 2.0, 1.5, arrow)
    p.line(cx, cy2 + 2.0, cx + 3.0, cy2 - 2.0, 1.5, arrow)
  }
}

///|
/// 单选项列表：每行一个圆圈 + 文案。选中行画强调色圆环 + 实心圆心，未选行
/// 画灰色圆环 + 白底。`options` 是 Core 经 `append_widget_option` 下发的整份
/// 文本；`selected` 是下标（越界按"都没选中"画）。
pub fn[P : Painter] paint_radio_options(
  p : P,
  options : Array[String],
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  selected~ : Int32,
  fg~ : Int32,
  accent~ : Int32,
  border~ : Int32 = 0xDDDDDD,
  mute~ : Int32 = 0xB8B8BD,
  size~ : Double = 13.0,
  enabled~ : Bool = true,
) -> Unit raise @moonui.UiError {
  let n = options.length()
  if n == 0 {
    return
  }
  let row_h = h / n.to_double()
  let raw = row_h - 6.0
  let d = if raw < 12.0 { 12.0 } else if raw > 16.0 { 16.0 } else { raw }
  let edge = if enabled { border } else { 0xE0E0E3 }
  for i = 0; i < n; i = i + 1 {
    let ry = y + row_h * i.to_double()
    let cx = x + 4.0 + d / 2.0
    let cy = ry + row_h / 2.0
    let on = i == selected
    p.fill_rect(cx - d / 2.0, cy - d / 2.0, d, d, d / 2.0, 0xFFFFFF, 255)
    if on {
      p.stroke_rect(
        cx - d / 2.0,
        cy - d / 2.0,
        d,
        d,
        d / 2.0,
        2.0,
        if enabled {
          accent
        } else {
          0xC9C9CE
        },
      )
      let dot = d * 0.45
      p.fill_rect(
        cx - dot / 2.0,
        cy - dot / 2.0,
        dot,
        dot,
        dot / 2.0,
        if enabled {
          accent
        } else {
          0xC9C9CE
        },
        255,
      )
    } else {
      p.stroke_rect(cx - d / 2.0, cy - d / 2.0, d, d, d / 2.0, 1.0, edge)
    }
    let (_, th) = p.measure_text(options[i], size, false)
    p.text(
      options[i],
      x + 4.0 + d + 8.0,
      ry + (row_h - th) / 2.0,
      size,
      false,
      if enabled {
        fg
      } else {
        mute
      },
    )
  }
  ignore(w)
}

///|
/// 口令掩码：每个字符换一个圆点，供 PasswordInput 复用文本框配方。纯函数，
/// 与绘制无关——放这里是为了能在无头测试里直接断言（真窗像素断言不了字）。
pub fn mask_secret(text : String) -> String {
  let mut out = ""
  for _c in text.to_array() {
    out = out + "•"
  }
  out
}

///|
/// 下拉框（收起态）：圆角描边框 + 左对齐的当前选项 + 右侧下折线箭头。展开
/// 的弹出列表归原生半/应用，配方只画"选中了什么"这一格。
pub fn[P : Painter] paint_combo_box(
  p : P,
  text : String,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  fg~ : Int32,
  border~ : Int32 = 0xDDDDDD,
  mute~ : Int32 = 0xB8B8BD,
  size~ : Double = 13.0,
  radius~ : Double = 6.0,
  enabled~ : Bool = true,
) -> Unit raise @moonui.UiError {
  let edge = if enabled { border } else { 0xE0E0E3 }
  let ink = if enabled { fg } else { mute }
  p.stroke_rect(x, y, w, h, radius, 1.0, edge)
  let (_, th) = p.measure_text(text, size, false)
  p.text(text, x + 8.0, y + (h - th) / 2.0, size, false, ink)
  // 右侧下折线箭头（不量字）：箭头中心离右边 10px
  let cx = x + w - 10.0
  let cy = y + h / 2.0
  p.line(cx - 3.0, cy - 1.5, cx, cy + 1.5, 1.5, ink)
  p.line(cx, cy + 1.5, cx + 3.0, cy - 1.5, 1.5, ink)
}

///|
/// 多行文本框：圆角描边框 + 按 `\n` 分行的文案，行高 = 字号×1.4，首行离框
/// 顶 6px。文本**锁在框内**（save/clip/restore 配对），超出的行被裁掉；
/// 自动换行归应用/原生半，配方不量宽断行。
pub fn[P : Painter] paint_multiline_entry(
  p : P,
  text : String,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  fg~ : Int32,
  border~ : Int32 = 0xDDDDDD,
  placeholder~ : String = "",
  mute~ : Int32 = 0xB8B8BD,
  size~ : Double = 13.0,
  radius~ : Double = 6.0,
  enabled~ : Bool = true,
  caret~ : Int32 = -1,
  caret_fg~ : Int32 = 0x333333,
) -> Unit raise @moonui.UiError {
  let edge = if enabled { border } else { 0xE0E0E3 }
  p.stroke_rect(x, y, w, h, radius, 1.0, edge)
  let empty = text == ""
  let shown = if empty { placeholder } else { text }
  let color = if !enabled || empty { mute } else { fg }
  let lh = size * 1.4
  let lines = shown.split("\n").to_array()
  p.save()
  p.clip_rect(x + 1.0, y + 1.0, w - 2.0, h - 2.0)
  for i = 0; i < lines.length(); i = i + 1 {
    // 空行不量也不画（原生 ABI 对空串返回失败；`"a\n\nb"` 这类段落会带空行）
    if lines[i].length() > 0 {
      p.text(
        lines[i].to_owned(),
        x + 8.0,
        y + 6.0 + lh * i.to_double(),
        size,
        false,
        color,
      )
    }
  }
  // 光标（`T374`）：多行第一刀只编辑首行——光标按首行字符前缀定位；空文本
  // 停在占位符起点。
  if caret >= 0 {
    let line0 = if empty { "" } else { lines[0].to_owned() }
    let idx = caret.clamp(min=0, max=line0.length())
    let prefix = line0[0:idx].to_owned()
    let mut cw = 0.0
    let mut ch = lh
    if prefix != "" {
      let (mwo, mho) = p.measure_text(prefix, size, false)
      cw = mwo
      ch = mho
    }
    let cx = (x + 8.0 + cw).clamp(min=x + 1.0, max=x + w - 2.0)
    p.line(cx, y + 6.0, cx, y + 6.0 + ch, 1.5, caret_fg)
  }
  p.restore()
}

///|
/// 日期框：圆角描边框 + 左对齐日期文案 + 右侧日历字形（14×14 方框 + 两根
/// 装订线 + 一条表头分隔线）。日期格式归 Core/应用，配方只画字符串。
pub fn[P : Painter] paint_date_picker(
  p : P,
  text : String,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  fg~ : Int32,
  border~ : Int32 = 0xDDDDDD,
  placeholder~ : String = "",
  mute~ : Int32 = 0xB8B8BD,
  size~ : Double = 13.0,
  radius~ : Double = 6.0,
  enabled~ : Bool = true,
) -> Unit raise @moonui.UiError {
  let edge = if enabled { border } else { 0xE0E0E3 }
  let ink = if enabled { fg } else { mute }
  p.stroke_rect(x, y, w, h, radius, 1.0, edge)
  let empty = text == ""
  let shown = if empty { placeholder } else { text }
  let (_, th) = p.measure_text(shown, size, false)
  p.text(
    shown,
    x + 8.0,
    y + (h - th) / 2.0,
    size,
    false,
    if empty {
      mute
    } else {
      ink
    },
  )
  // 日历字形：14×14 框 + 两根装订线 + 表头横线
  let gy = y + (h - 14.0) / 2.0
  let gx = x + w - 20.0
  p.stroke_rect(gx, gy, 14.0, 14.0, 2.0, 1.0, ink)
  p.line(gx + 4.0, gy - 2.0, gx + 4.0, gy + 2.0, 1.0, ink)
  p.line(gx + 10.0, gy - 2.0, gx + 10.0, gy + 2.0, 1.0, ink)
  p.line(gx, gy + 4.0, gx + 14.0, gy + 4.0, 1.0, ink)
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
