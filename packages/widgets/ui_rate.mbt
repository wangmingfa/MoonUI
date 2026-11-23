///|
/// `UiRate`——自绘评分星（`T360` 第三档）。
///
/// 原生控件没有评分星；社区做法是五个按钮里塞 `★`/`☆` 字符，缺点很实在：
/// 字符的大小、基线、间距都随字体走，五颗星很难对得齐，深色主题下 `☆` 的空心
/// 笔画还会糊成一团。自绘之后每颗星是一个十顶点多边形（`FillPolygon`），亮星
/// 用警告色、暗星用轨道色，圆心与半径全由控件自己算——五颗星永远一样大、一样
/// 齐。`T109` 之后 `packages/widgets` 连 `@math` 都不 import，所以这里**不**算
/// 三角函数：五角星的十个单位顶点是手算好的常量表（见 `UI_STAR_UNIT`），
/// 只做"乘半径 + 平移"。
///
/// 悬停预览（指针扫过第几颗就亮到第几颗）是评分控件的灵魂：不预览的话用户
/// 得点下去才知道自己选了几星。预览只改绘制、不写 `value`，离开即恢复。
///
/// 键盘：左右键加减一星，与滑块同一条口径（`0` 到 `max`）。

///|
/// 五角星的十个单位顶点（外/内半径交替，从正上方顺时针）。
///
/// 内半径取外半径的 0.42——小于 0.38 星角会瘦成针、大于 0.5 会胖成齿轮；0.42
/// 是常见五角星的比例。坐标是 `cos/sin` 手算后写死的：判据因此逐位确定，
/// 也不给这个包加一条 `@math` 依赖（`moon.pkg` 的段注解释了为什么）。
fn ui_star_unit() -> Array[(Double, Double)] {
  [
    (0.0, -1.0),
    (0.2468, -0.3398),
    (0.9511, -0.3090),
    (0.3995, 0.1298),
    (0.5878, 0.8090),
    (0.0, 0.42),
    (-0.5878, 0.8090),
    (-0.3995, 0.1298),
    (-0.9511, -0.3090),
    (-0.2468, -0.3398),
  ]
}

///|
/// 评分的账：值、上限、星径、悬停预览。
struct RateState {
  mut theme : UiTheme
  /// 已选星数（0..max）
  mut value : Int32
  max : Int32
  /// 单颗星的直径
  star : Double
  gap : Double
  /// 悬停到第几颗（0 起，-1 = 没悬停）——只影响绘制，不改 `value`
  mut hover : Int32
  mut handler : ((Int32) -> Unit raise @moonui.UiError)?
}

///|
/// 自绘评分星。
pub struct UiRate[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : RateState
}

///|
/// 星与星之间的空隙。
const UI_RATE_GAP : Double = 4.0

///|
/// 尺寸档 → 单颗星的直径。16/20/24 与三档控件高度同比例。
fn ui_rate_star(size : UiSize) -> Double {
  match size {
    UiSmall => 16.0
    UiMedium => 20.0
    UiLarge => 24.0
  }
}

///|
/// 固有宽：`max` 颗星 + 间距。
fn ui_rate_width(st : RateState) -> Double {
  st.max.to_double() * st.star + (st.max - 1).to_double() * st.gap
}

///|
/// 第 i 颗星的圆心。
fn ui_rate_center(st : RateState, i : Int32) -> (Double, Double) {
  let d = st.star
  (i.to_double() * (d + st.gap) + d / 2.0, d / 2.0)
}

///|
/// 画 `max` 颗星：前 `lit` 颗亮、其余暗。`lit` 由"悬停预览优先于已选值"给出。
fn ui_paint_rate(
  st : RateState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 || st.max <= 0 {
    return
  }
  let t = st.theme
  let lit = if st.hover >= 0 { st.hover + 1 } else { st.value }
  let r = st.star / 2.0
  let mut i = 0
  while i < st.max {
    let (cx, cy) = ui_rate_center(st, i)
    let pts : Array[(Double, Double)] = []
    for u in ui_star_unit() {
      pts.push((cx + u.0 * r, cy + u.1 * r))
    }
    dl.fill_polygon(pts, rgb=if i < lit { t.warning } else { t.track })
    i = i + 1
  }
}

///|
/// 指针 → 星序号（-1 = 不在任何一颗上）。
fn[B] ui_rate_hit(
  w : @moonui.Widget[B],
  st : RateState,
  p : @moonui.LogicalPoint,
) -> Int32 {
  let step = st.star + st.gap
  if step <= 0.0 {
    return -1
  }
  let x = p.x - w.frame().origin.x
  let y = p.y - w.frame().origin.y
  if y < 0.0 || y > st.star {
    return -1
  }
  let idx = (x / step).to_int()
  if idx < 0 || idx >= st.max {
    -1
  } else {
    idx
  }
}

///|
/// 提交一个星数（0..max），变了才回调。
fn[B : @moonui.Backend] ui_rate_commit(
  w : @moonui.Widget[B],
  st : RateState,
  raw : Int32,
) -> Unit raise @moonui.UiError {
  let v = if raw < 0 { 0 } else if raw > st.max { st.max } else { raw }
  let changed = v != st.value
  st.value = v
  w.repaint()
  if changed {
    match st.handler {
      Some(f) => f(v)
      None => ()
    }
  }
}

///|
/// 造一排评分星。`value` 夹在 0..max。
pub fn[B : @moonui.Backend] UiRate::UiRate(
  backend : B,
  value~ : Int32 = 0,
  max~ : Int32 = 5,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
) -> UiRate[B] raise @moonui.UiError {
  let n = if max < 1 { 1 } else { max }
  let v = if value < 0 { 0 } else if value > n { n } else { value }
  let state = RateState::{
    theme,
    value: v,
    max: n,
    star: ui_rate_star(size),
    gap: UI_RATE_GAP,
    hover: -1,
    handler: None,
  }
  let widget = @moonui.Widget::custom(
    backend,
    @moonui.LogicalSize(ui_rate_width(state), state.star),
    fn(dl, env) { ui_paint_rate(state, dl, env) },
    focusable=true,
  )
  let _ = widget.on(
    fn(e) {
      match e {
        @moonui.MouseUp(_, @moonui.Left, _, _) => true
        @moonui.MouseMove(_, _) => true
        @moonui.MouseLeave(_) => true
        @moonui.KeyDown(_, kp) => kp.key == "Left" || kp.key == "Right"
        _ => false
      }
    },
    fn(e) raise @moonui.UiError {
      match e {
        @moonui.MouseMove(_, p) => {
          let h = ui_rate_hit(widget, state, p)
          if h != state.hover {
            state.hover = h
            widget.repaint()
          }
        }
        @moonui.MouseLeave(_) =>
          if state.hover != -1 {
            state.hover = -1
            widget.repaint()
          }
        @moonui.MouseUp(_, _, p, _) => {
          let idx = ui_rate_hit(widget, state, p)
          if idx >= 0 {
            ui_rate_commit(widget, state, idx + 1)
          }
        }
        @moonui.KeyDown(_, kp) =>
          if kp.key == "Left" {
            ui_rate_commit(widget, state, state.value - 1)
          } else if kp.key == "Right" {
            ui_rate_commit(widget, state, state.value + 1)
          }
        _ => ()
      }
    },
  )
  { backend, widget, state, }
}

///|
pub fn[B] UiRate::widget(self : UiRate[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
pub fn[B] UiRate::value(self : UiRate[B]) -> Int32 {
  self.state.value
}

///|
/// 当下悬停预览（-1 = 没有）。
pub fn[B] UiRate::hover(self : UiRate[B]) -> Int32 {
  self.state.hover
}

///|
/// 程序设值（夹在 0..max，变了才回调）。
pub fn[B : @moonui.Backend] UiRate::set_value(
  self : UiRate[B],
  value : Int32,
) -> Unit raise @moonui.UiError {
  ui_rate_commit(self.widget, self.state, value)
}

///|
/// 换值回调（用户点星或按键时触发；程序调 `set_value` 也走同一条）。
pub fn[B] UiRate::on_change(
  self : UiRate[B],
  f : (Int32) -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
/// 换令牌并重画（星径由尺寸档定，不由字号定——星不是字）。
pub fn[B : @moonui.Backend] UiRate::set_theme(
  self : UiRate[B],
  theme : UiTheme,
) -> Unit raise @moonui.UiError {
  self.state.theme = theme
  self.widget.repaint()
}
