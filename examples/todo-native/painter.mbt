///|
/// OpenTodo 复刻件的绘制层（`T409`）。
///
/// 这一层只回答"像素落在哪儿"：设计 token 翻译成 `@moonui.Color`、线性图标
/// 全部用 `DrawList` 描出来、半透叠色手算（原生面板的底色只认不透明色，
/// `Style.background` 给不出 alpha，所以"浅底"一律在 MoonBit 侧混成实色）。
///
/// 不摆位、不取数据：摆位在 `todo_ui`，数据在 `todo`。

///|
/// 0xRRGGBB → `@moonui.Color`。
pub fn rgb(v : Int32) -> @moonui.Color {
  @moonui.Color::rgb((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
}

///|
/// `over` 以 `a`（0..<255）盖在 `base` 上。用于优先级环的浅底与标签 chip 的浅底。
pub fn mix(hi : Int32, a : Int32, base : Int32) -> Int32 {
  let inv = 255 - a
  let r = (((hi >> 16) & 255) * a + ((base >> 16) & 255) * inv) / 255
  let g = (((hi >> 8) & 255) * a + ((base >> 8) & 255) * inv) / 255
  let b = ((hi & 255) * a + (base & 255) * inv) / 255
  (r << 16) | (g << 8) | b
}

///|
/// 配色档（浅色 / 深色）。浅色是网页 `light` 主题的实测值，深色是其 `dark` 档。
pub struct Palette {
  canvas : Int32
  surface : Int32
  raised : Int32
  sunken : Int32
  hover : Int32
  selected : Int32
  strong : Int32
  muted : Int32
  faint : Int32
  border : Int32
  border_soft : Int32
  line : Int32
  accent : Int32
  accent_soft : Int32
  success : Int32
  success_soft : Int32
  warning : Int32
  warning_soft : Int32
  danger : Int32
  danger_soft : Int32
  info_soft : Int32
  info_text : Int32
  p1 : Int32
  p2 : Int32
  p3 : Int32
  p4 : Int32
}

///|
pub fn Palette::light() -> Palette {
  Palette::{
    canvas: 0xEFF0F2,
    surface: 0xFFFFFF,
    raised: 0xF7F7F7,
    sunken: 0xF1F3F5,
    hover: 0xF8F8F8,
    selected: 0xE7E9EC,
    strong: 0x17191C,
    muted: 0x5C6169,
    faint: 0x62686F,
    border: 0xDEE0E3,
    border_soft: 0xE1E3E6,
    line: 0xD4D7DB,
    accent: 0x047857,
    accent_soft: 0xE7F5EF,
    success: 0x047857,
    success_soft: 0xECFDF5,
    warning: 0x8A5200,
    warning_soft: 0xFEFAE7,
    danger: 0xBD2F2A,
    danger_soft: 0xFDF2F2,
    info_soft: 0xF2F9FF,
    info_text: 0x075985,
    p1: 0xDC2626,
    p2: 0xEA580C,
    p3: 0x2562EB,
    p4: 0x64748B,
  }
}

///|
pub fn Palette::dark() -> Palette {
  Palette::{
    canvas: 0x0D0E10,
    surface: 0x141518,
    raised: 0x191A1E,
    sunken: 0x1E2024,
    hover: 0x1F2126,
    selected: 0x26292E,
    strong: 0xECEDEF,
    muted: 0xA3A7AE,
    faint: 0x8A8F98,
    border: 0x232529,
    border_soft: 0x1F2126,
    line: 0x2E3238,
    accent: 0x34D399,
    accent_soft: 0x16241F,
    success: 0x34D399,
    success_soft: 0x16241F,
    warning: 0xFBBF24,
    warning_soft: 0x241E10,
    danger: 0xF0716D,
    danger_soft: 0x241516,
    info_soft: 0x121B26,
    info_text: 0x7CC0F0,
    p1: 0xF87171,
    p2: 0xFB923C,
    p3: 0x60A5FA,
    p4: 0x94A3B8,
  }
}

///|
/// 优先级环的浅底与环色（`P1` 55%、`P2` 25%，无优先级是中性灰环）。
pub fn prio_fill(p : Palette, prio : Int32) -> Int32 {
  if prio == 1 {
    mix(p.p1, 140, p.surface)
  } else if prio == 2 {
    mix(p.p2, 64, p.surface)
  } else if prio == 3 {
    mix(p.p3, 46, p.surface)
  } else if prio == 4 {
    mix(p.p4, 46, p.surface)
  } else {
    0
  }
}

///|
/// 优先级环的描边色。
pub fn prio_line(p : Palette, prio : Int32) -> Int32 {
  if prio == 1 {
    p.p1
  } else if prio == 2 {
    p.p2
  } else if prio == 3 {
    p.p3
  } else if prio == 4 {
    p.p4
  } else {
    0x9AA1AB
  }
}

///|
/// 16 网格上的坐标换算（归一化后整体缩放到 `sz`）。
fn gx(ox : Double, v : Double, s : Double) -> Double {
  ox + v * s
}

///|
fn gy(oy : Double, v : Double, s : Double) -> Double {
  oy + v * s
}

///|
/// 线宽：最小 1px，保证小尺寸下不断线。
fn gw(v : Double, s : Double) -> Double {
  if v * s < 1.0 {
    1.0
  } else {
    v * s
  }
}

///|
/// 网格线段。
fn gl(
  dl : @moonui.DrawList,
  ox : Double,
  oy : Double,
  s : Double,
  c : Int32,
  x0 : Double,
  y0 : Double,
  x1 : Double,
  y1 : Double,
  w : Double,
) -> Unit {
  dl.line(
    gx(ox, x0, s),
    gy(oy, y0, s),
    gx(ox, x1, s),
    gy(oy, y1, s),
    rgb=c,
    width=gw(w, s),
  )
}

///|
/// 网格多边形。
fn gt(
  dl : @moonui.DrawList,
  ox : Double,
  oy : Double,
  s : Double,
  c : Int32,
  pts : Array[(Double, Double)],
) -> Unit {
  let out : Array[(Double, Double)] = []
  for pt in pts {
    out.push((gx(ox, pt.0, s), gy(oy, pt.1, s)))
  }
  dl.fill_polygon(out, rgb=c)
}

///|
/// 描边折线（网页的 chevron / 箭头是细线，不是实心三角）。
fn gtline(
  dl : @moonui.DrawList,
  ox : Double,
  oy : Double,
  s : Double,
  c : Int32,
  pts : Array[(Double, Double)],
  w : Double,
) -> Unit {
  for i in 0..<(pts.length() - 1) {
    dl.line(
      gx(ox, pts[i].0, s),
      gy(oy, pts[i].1, s),
      gx(ox, pts[i + 1].0, s),
      gy(oy, pts[i + 1].1, s),
      rgb=c,
      width=gw(w, s),
    )
  }
}

///|
/// 网格圆角矩形（实心）。
fn gr(
  dl : @moonui.DrawList,
  ox : Double,
  oy : Double,
  s : Double,
  c : Int32,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  r : Double,
) -> Unit {
  dl.fill_rect(
    gx(ox, x, s),
    gy(oy, y, s),
    gx(ox, x + w, s) - gx(ox, x, s),
    gy(oy, y + h, s) - gy(oy, y, s),
    radius=gw(r, s),
    rgb=c,
  )
}

///|
/// 网格描边圆角矩形。
fn gs(
  dl : @moonui.DrawList,
  ox : Double,
  oy : Double,
  s : Double,
  c : Int32,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  r : Double,
  lw : Double,
) -> Unit {
  dl.stroke_rect(
    gx(ox, x, s),
    gy(oy, y, s),
    gx(ox, x + w, s) - gx(ox, x, s),
    gy(oy, y + h, s) - gy(oy, y, s),
    radius=gw(r, s),
    rgb=c,
    width=gw(lw, s),
  )
}

///|
/// 一枚 16 网格的矢量图标，画在 `(ox, oy)` 起、边长 `sz` 的盒子里。
///
/// 全部用 `DrawList` 的直线 / 圆角矩形 / 圆 / 多边形拼：网页侧是 SVG path，
/// 这里取"同一形状、同一视觉重量"，不是同一份 path 数据。
pub fn glyph(
  dl : @moonui.DrawList,
  name : String,
  ox : Double,
  oy : Double,
  sz : Double,
  c : Int32,
) -> Unit {
  let s = sz / 16.0
  match name {
    "inbox" => {
      // 收件箱托盘：圆角框 + 中部横线 + 中央下凹 V 口（lucide inbox）
      gs(dl, ox, oy, s, c, 1.0, 4.5, 14.0, 11.0, 2.5, 1.4)
      gtline(
        dl,
        ox,
        oy,
        s,
        c,
        [(1.0, 9.5), (4.6, 9.5), (8.0, 12.3), (11.4, 9.5), (15.0, 9.5)],
        1.4,
      )
    }
    "today" => {
      gs(dl, ox, oy, s, c, 1.5, 3.5, 13.0, 11.0, 2.0, 1.4)
      gl(dl, ox, oy, s, c, 1.5, 7.4, 14.5, 7.4, 1.4)
      gl(dl, ox, oy, s, c, 5.0, 1.4, 5.0, 4.2, 1.4)
      gl(dl, ox, oy, s, c, 11.0, 1.4, 11.0, 4.2, 1.4)
      gl(dl, ox, oy, s, c, 5.4, 10.6, 7.1, 12.3, 1.6)
      gl(dl, ox, oy, s, c, 7.1, 12.3, 11.2, 8.5, 1.6)
    }
    "calendar" => {
      gs(dl, ox, oy, s, c, 1.5, 3.0, 13.0, 11.5, 2.0, 1.4)
      gl(dl, ox, oy, s, c, 1.5, 6.8, 14.5, 6.8, 1.4)
      gl(dl, ox, oy, s, c, 5.0, 1.0, 5.0, 3.8, 1.4)
      gl(dl, ox, oy, s, c, 11.0, 1.0, 11.0, 3.8, 1.4)
      gl(dl, ox, oy, s, c, 4.2, 9.6, 8.0, 9.6, 1.4)
      let dxx = gx(ox, 11.2, s)
      let dyy = gy(oy, 9.6, s)
      let dr = 1.2 * s
      dl.fill_rect(dxx - dr, dyy - dr, dr * 2.0, dr * 2.0, radius=dr, rgb=c)
    }
    "upcoming" => {
      dl.stroke_arc(
        gx(ox, 8.0, s),
        gy(oy, 8.4, s),
        6.0 * s,
        0.0,
        360.0,
        rgb=c,
        width=gw(1.4, s),
      )
      gl(dl, ox, oy, s, c, 8.0, 8.4, 8.0, 4.8, 1.4)
      gl(dl, ox, oy, s, c, 8.0, 8.4, 11.0, 9.0, 1.4)
    }
    "view" => gr(dl, ox, oy, s, c, 2.0, 2.0, 12.0, 12.0, 3.0)
    "project" => {
      gr(dl, ox, oy, s, c, 2.0, 2.0, 5.0, 2.4, 1.2)
      gr(dl, ox, oy, s, c, 1.0, 4.2, 14.0, 9.8, 2.0)
    }
    "plus" => {
      gl(dl, ox, oy, s, c, 8.0, 3.2, 8.0, 12.8, 1.7)
      gl(dl, ox, oy, s, c, 3.2, 8.0, 12.8, 8.0, 1.7)
    }
    "chevron_right" =>
      gtline(dl, ox, oy, s, c, [(6.4, 4.0), (11.4, 8.0), (6.4, 12.0)], 1.5)
    "chevron_down" =>
      gtline(dl, ox, oy, s, c, [(4.0, 6.4), (12.0, 6.4), (8.0, 11.4)], 1.5)
    "check" => {
      gl(dl, ox, oy, s, c, 3.6, 8.4, 6.8, 11.6, 1.9)
      gl(dl, ox, oy, s, c, 6.8, 11.6, 12.4, 4.8, 1.9)
    }
    "pencil" => {
      gt(dl, ox, oy, s, c, [
        (2.6, 13.4),
        (4.2, 11.8),
        (11.4, 4.6),
        (13.2, 6.4),
        (6.0, 13.6),
      ])
      gl(dl, ox, oy, s, c, 2.4, 13.6, 4.4, 13.6, 1.4)
    }
    "calendar_small" => {
      gs(dl, ox, oy, s, c, 2.0, 3.4, 12.0, 10.6, 1.6, 1.3)
      gl(dl, ox, oy, s, c, 2.0, 6.6, 14.0, 6.6, 1.3)
      gl(dl, ox, oy, s, c, 5.0, 1.8, 5.0, 3.8, 1.3)
      gl(dl, ox, oy, s, c, 11.0, 1.8, 11.0, 3.8, 1.3)
    }
    "monitor" => {
      // 显示器（网页头部第 2 枚图标）：屏幕圆角框 + 支架颈 + 底座
      gs(dl, ox, oy, s, c, 1.4, 1.6, 13.2, 9.6, 1.6, 1.4)
      gl(dl, ox, oy, s, c, 6.6, 11.2, 9.4, 11.2, 1.4)
      gl(dl, ox, oy, s, c, 4.4, 13.4, 11.6, 13.4, 1.5)
    }
    // 文件夹：左上角的标签 + 圆角盒身（lucide folder 的口径）
    "folder" => {
      gtline(
        dl,
        ox,
        oy,
        s,
        c,
        [(1.5, 4.6), (1.5, 2.9), (5.4, 2.9), (7.4, 4.6)],
        1.4,
      )
      gs(dl, ox, oy, s, c, 1.5, 4.6, 13.0, 8.6, 1.8, 1.4)
    }
    // 标签（tag）：切掉左上角的五边形 + 穿孔小圈
    "tag" => {
      gtline(
        dl,
        ox,
        oy,
        s,
        c,
        [
          (2.2, 6.6),
          (6.6, 2.2),
          (13.8, 2.2),
          (13.8, 9.4),
          (6.6, 13.8),
          (2.2, 6.6),
        ],
        1.4,
      )
      dl.stroke_arc(
        gx(ox, 5.3, s),
        gy(oy, 5.3, s),
        1.3 * s,
        0.0,
        360.0,
        rgb=c,
        width=gw(1.3, s),
      )
    }
    "flag" => {
      gl(dl, ox, oy, s, c, 4.2, 2.0, 4.2, 14.0, 1.5)
      gt(dl, ox, oy, s, c, [
        (5.0, 3.0),
        (13.4, 3.0),
        (11.4, 6.2),
        (13.4, 9.4),
        (5.0, 9.4),
      ])
    }
    "dots" =>
      for i in [4.0, 8.0, 12.0] {
        gr(dl, ox, oy, s, c, i - 1.3, 6.7, 2.6, 2.6, 1.3)
      }
    "close" => {
      gl(dl, ox, oy, s, c, 4.2, 4.2, 11.8, 11.8, 1.7)
      gl(dl, ox, oy, s, c, 11.8, 4.2, 4.2, 11.8, 1.7)
    }
    "help" => {
      dl.stroke_arc(
        gx(ox, 8.0, s),
        gy(oy, 8.0, s),
        6.2 * s,
        0.0,
        360.0,
        rgb=c,
        width=gw(1.3, s),
      )
      dl.text(
        "?",
        gx(ox, 6.0, s),
        gy(oy, 2.4, s),
        size=sz * 0.55,
        bold=true,
        rgb=c,
      )
    }
    "alarm" => {
      dl.stroke_arc(
        gx(ox, 8.0, s),
        gy(oy, 9.0, s),
        5.4 * s,
        0.0,
        360.0,
        rgb=c,
        width=gw(1.3, s),
      )
      gl(dl, ox, oy, s, c, 8.0, 9.0, 8.0, 5.6, 1.3)
      gl(dl, ox, oy, s, c, 2.6, 2.4, 5.2, 3.6, 1.3)
      gl(dl, ox, oy, s, c, 13.4, 2.4, 10.8, 3.6, 1.3)
    }
    "grip" =>
      for i in [4.0, 8.0, 12.0] {
        gr(dl, ox, oy, s, c, 5.6, i - 1.1, 2.2, 2.2, 1.1)
        gr(dl, ox, oy, s, c, 9.8, i - 1.1, 2.2, 2.2, 1.1)
      }
    "note" => {
      gs(dl, ox, oy, s, c, 2.6, 2.4, 10.8, 11.2, 1.6, 1.3)
      gl(dl, ox, oy, s, c, 5.0, 6.4, 11.0, 6.4, 1.3)
      gl(dl, ox, oy, s, c, 5.0, 9.2, 11.0, 9.2, 1.3)
    }
    "subtask" => {
      gs(dl, ox, oy, s, c, 1.6, 3.2, 12.8, 10.0, 2.0, 1.3)
      gl(dl, ox, oy, s, c, 4.4, 8.2, 6.4, 10.2, 1.3)
      gl(dl, ox, oy, s, c, 6.4, 10.2, 10.4, 5.4, 1.3)
    }
    "comment" =>
      gt(dl, ox, oy, s, c, [
        (2.0, 4.2),
        (2.0, 10.6),
        (5.2, 10.6),
        (5.2, 13.6),
        (9.0, 10.6),
        (14.0, 10.6),
        (14.0, 4.2),
      ])
    "person" => {
      // 头像：头圆 + 肩弧
      dl.stroke_arc(
        gx(ox, 8.0, s),
        gy(oy, 5.6, s),
        2.6 * s,
        0.0,
        360.0,
        rgb=c,
        width=gw(1.4, s),
      )
      dl.stroke_arc(
        gx(ox, 8.0, s),
        gy(oy, 12.2, s),
        4.6 * s,
        180.0,
        360.0,
        rgb=c,
        width=gw(1.4, s),
      )
    }
    "repeat" => {
      // 循环：上下两条弧 + 左右箭头
      dl.stroke_arc(
        gx(ox, 8.0, s),
        gy(oy, 8.0, s),
        5.0 * s,
        20.0,
        160.0,
        rgb=c,
        width=gw(1.4, s),
      )
      dl.stroke_arc(
        gx(ox, 8.0, s),
        gy(oy, 8.0, s),
        5.0 * s,
        200.0,
        340.0,
        rgb=c,
        width=gw(1.4, s),
      )
      gl(dl, ox, oy, s, c, 12.6, 1.8, 13.6, 3.0, 1.4)
      gl(dl, ox, oy, s, c, 12.6, 1.8, 11.6, 2.8, 1.4)
      gl(dl, ox, oy, s, c, 3.4, 14.2, 2.4, 13.0, 1.4)
      gl(dl, ox, oy, s, c, 3.4, 14.2, 4.4, 13.2, 1.4)
    }
    "bars" => {
      // 竖条（Weekly review 的图标）
      gl(dl, ox, oy, s, c, 3.6, 4.0, 3.6, 13.0, 1.7)
      gl(dl, ox, oy, s, c, 8.0, 7.0, 8.0, 13.0, 1.7)
      gl(dl, ox, oy, s, c, 12.4, 2.0, 12.4, 13.0, 1.7)
    }
    "signal" => {
      // 优先级信号：三根递增的竖条。网页实测（2x 截图量得）：条宽 2px、条心横向
      // 相隔 5px=2.5 格、三根底端齐平、高度 1/3/5 格。原先按 16 格铺满画，出来是
      // 网页的 2 倍大（复刻件 22×20px 对参考 12×10px）；条心相隔也只该 2.5 格。
      gl(dl, ox, oy, s, c, 4.25, 8.75, 4.25, 9.25, 1.0)
      gl(dl, ox, oy, s, c, 6.75, 6.25, 6.75, 9.25, 1.0)
      gl(dl, ox, oy, s, c, 9.25, 4.25, 9.25, 9.25, 1.0)
    }
    "check_circle" => {
      // 子任务进度：圆圈 + 对勾
      dl.stroke_arc(
        gx(ox, 8.0, s),
        gy(oy, 8.0, s),
        6.0 * s,
        0.0,
        360.0,
        rgb=c,
        width=gw(1.4, s),
      )
      gl(dl, ox, oy, s, c, 4.8, 8.2, 6.8, 10.2, 1.4)
      gl(dl, ox, oy, s, c, 6.8, 10.2, 11.2, 5.0, 1.4)
    }
    "shared" => {
      // 共享项目：两个交叠圆
      dl.stroke_arc(
        gx(ox, 6.6, s),
        gy(oy, 8.0, s),
        4.4 * s,
        0.0,
        360.0,
        rgb=c,
        width=gw(1.3, s),
      )
      dl.stroke_arc(
        gx(ox, 10.4, s),
        gy(oy, 8.0, s),
        4.4 * s,
        0.0,
        360.0,
        rgb=c,
        width=gw(1.3, s),
      )
    }
    "logo" => {
      gr(dl, ox, oy, s, c, 0.0, 0.0, 16.0, 16.0, 4.0)
      gl(dl, ox, oy, s, 0xFFFFFF, 4.6, 8.2, 7.0, 10.8, 1.7)
      gl(dl, ox, oy, s, 0xFFFFFF, 7.0, 10.8, 11.6, 5.0, 1.7)
    }
    "bell" => {
      gt(dl, ox, oy, s, c, [
        (4.0, 11.0),
        (4.6, 6.2),
        (8.0, 3.2),
        (11.4, 6.2),
        (12.0, 11.0),
      ])
      gl(dl, ox, oy, s, c, 3.2, 11.0, 12.8, 11.0, 1.4)
      gr(dl, ox, oy, s, c, 7.0, 11.8, 2.0, 2.0, 1.0)
    }
    "star" =>
      gt(dl, ox, oy, s, c, [
        (8.0, 2.0),
        (10.0, 6.4),
        (14.8, 6.8),
        (11.1, 9.9),
        (12.2, 14.6),
        (8.0, 12.2),
        (3.8, 14.6),
        (4.9, 9.9),
        (1.2, 6.8),
        (6.0, 6.4),
      ])
    "filter" =>
      // 漏斗（网页头部第 1 枚图标）：宽顶 + 收成细颈。原先误画成三条递减横线，
      // 与网页的漏斗轮廓完全不同。
      gtline(
        dl,
        ox,
        oy,
        s,
        c,
        [
          (3.0, 3.0),
          (13.0, 3.0),
          (9.2, 8.6),
          (9.2, 14.6),
          (6.8, 14.6),
          (6.8, 8.6),
          (3.0, 3.0),
        ],
        1.5,
      )
    "sliders" => {
      // 水平滑杆 + 每根一个小旋钮（网页头部第 3 枚图标）
      gl(dl, ox, oy, s, c, 2.0, 4.0, 14.0, 4.0, 1.5)
      let kx = gx(ox, 9.5, s)
      let ky = gy(oy, 4.0, s)
      let kr = 1.8 * s
      dl.fill_rect(kx - kr, ky - kr, kr * 2.0, kr * 2.0, radius=kr, rgb=c)
      gl(dl, ox, oy, s, c, 2.0, 8.0, 14.0, 8.0, 1.5)
      let kx2 = gx(ox, 5.0, s)
      let ky2 = gy(oy, 8.0, s)
      dl.fill_rect(kx2 - kr, ky2 - kr, kr * 2.0, kr * 2.0, radius=kr, rgb=c)
      gl(dl, ox, oy, s, c, 2.0, 12.0, 14.0, 12.0, 1.5)
      let kx3 = gx(ox, 11.5, s)
      let ky3 = gy(oy, 12.0, s)
      dl.fill_rect(kx3 - kr, ky3 - kr, kr * 2.0, kr * 2.0, radius=kr, rgb=c)
    }
    "search" => {
      dl.stroke_arc(
        gx(ox, 7.2, s),
        gy(oy, 7.2, s),
        4.8 * s,
        0.0,
        360.0,
        rgb=c,
        width=gw(1.4, s),
      )
      gl(dl, ox, oy, s, c, 10.6, 10.6, 14.0, 14.0, 1.6)
    }
    "sort" => {
      gl(dl, ox, oy, s, c, 3.0, 4.0, 13.0, 4.0, 1.5)
      gl(dl, ox, oy, s, c, 3.0, 8.0, 10.0, 8.0, 1.5)
      gl(dl, ox, oy, s, c, 3.0, 12.0, 7.0, 12.0, 1.5)
    }
    "list" =>
      for i in [4.0, 8.0, 12.0] {
        gr(dl, ox, oy, s, c, 2.0, i - 1.3, 2.6, 2.6, 1.3)
        gl(dl, ox, oy, s, c, 7.0, i, 14.0, i, 1.4)
      }
    _ => gs(dl, ox, oy, s, c, 2.0, 2.0, 12.0, 12.0, 2.0, 1.4)
  }
}

///|
/// 拖拽握把（`name = "grip"` 的 `glyph` 别名，语义上更清楚）。
pub fn grip_glyph(
  dl : @moonui.DrawList,
  ox : Double,
  oy : Double,
  c : Int32,
) -> Unit {
  glyph(dl, "grip", ox, oy, 16.0, c)
}

///|
fn max(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}

///|
/// 勾选环：`sz` 见方面里的圆，2px 环。
///
/// 完成 = 强调色实心 + 白勾；悬停未完成 = 浅绿底 + 强调色环；常态 = 优先级浅底 +
/// 优先级 2px 环。与网页 `TaskCircle` 的三档一致。
pub fn ring(
  dl : @moonui.DrawList,
  p : Palette,
  prio : Int32,
  done : Bool,
  hot : Bool,
  ox : Double,
  oy : Double,
  sz : Double,
) -> Unit {
  let r = sz / 2.0 - 1.0
  let cx = ox + sz / 2.0
  let cy = oy + sz / 2.0
  if done {
    dl.fill_rect(cx - r, cy - r, r * 2.0, r * 2.0, radius=r, rgb=p.accent)
    dl.line(
      cx - 0.34 * sz,
      cy + 0.04 * sz,
      cx - 0.10 * sz,
      cy + 0.28 * sz,
      rgb=0xFFFFFF,
      width=max(1.6, 0.11 * sz),
    )
    dl.line(
      cx - 0.10 * sz,
      cy + 0.28 * sz,
      cx + 0.38 * sz,
      cy - 0.28 * sz,
      rgb=0xFFFFFF,
      width=max(1.6, 0.11 * sz),
    )
  } else if hot {
    dl.fill_rect(cx - r, cy - r, r * 2.0, r * 2.0, radius=r, rgb=p.success_soft)
    dl.stroke_rect(
      cx - r + 1.0,
      cy - r + 1.0,
      r * 2.0 - 2.0,
      r * 2.0 - 2.0,
      radius=r - 1.0,
      rgb=p.accent,
      width=2.0,
    )
  } else {
    let fill = prio_fill(p, prio)
    if fill != 0 {
      dl.fill_rect(cx - r, cy - r, r * 2.0, r * 2.0, radius=r, rgb=fill)
    }
    dl.stroke_rect(
      cx - r + 1.0,
      cy - r + 1.0,
      r * 2.0 - 2.0,
      r * 2.0 - 2.0,
      radius=r - 1.0,
      rgb=prio_line(p, prio),
      width=2.0,
    )
  }
}

///|
/// 实心圆点（项目色 / 标签色）。
pub fn dot(
  dl : @moonui.DrawList,
  cx : Double,
  cy : Double,
  r : Double,
  c : Int32,
) -> Unit {
  dl.fill_rect(cx - r, cy - r, r * 2.0, r * 2.0, radius=r, rgb=c)
}

///|
/// 头像（首字母圆块）。
pub fn avatar(
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  initials : String,
  sz : Double,
  bg : Int32,
  fg : Int32,
) -> Unit {
  dl.fill_rect(0.0, 0.0, sz, sz, radius=sz / 2.0, rgb=bg)
  let (w, h) = env.measure_text(initials, sz * 0.45, true)
  dl.text(
    initials,
    (sz - w) / 2.0,
    (sz - h) / 2.0,
    size=sz * 0.45,
    bold=true,
    rgb=fg,
  )
}

///|
/// 徽标数字块（铃铛上的 "2"）。
pub fn badge(
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  n : String,
  d : Double,
  bg : Int32,
  fg : Int32,
  ox : Double,
  oy : Double,
) -> Unit {
  let (w, h) = env.measure_text(n, d * 0.6, true)
  dl.fill_rect(ox, oy, d, d, radius=d / 2.0, rgb=bg)
  dl.text(
    n,
    ox + (d - w) / 2.0,
    oy + (d - h) / 2.0,
    size=d * 0.6,
    bold=true,
    rgb=fg,
  )
}

///|
/// 圆角 1px 描边的面（覆盖在内容之上，`env.size` 是真实显示尺寸）。
pub fn outline(
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  radius : Double,
  c : Int32,
) -> Unit {
  let w = env.size.width
  let h = env.size.height
  dl.stroke_rect(0.5, 0.5, w - 1.0, h - 1.0, radius~, rgb=c, width=1.0)
}

///|
/// 底部一条 1px 细线（顶栏下缘 / 分隔）。
pub fn hairline(
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  c : Int32,
) -> Unit {
  dl.fill_rect(0.0, env.size.height - 1.0, env.size.width, 1.0, rgb=c)
}
