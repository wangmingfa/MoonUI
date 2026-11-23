///|
/// `UiAlert`——自绘提示条（`T360` 第三档）。
///
/// 原生控件里没有"提示条"这一档：它要么是一块彩色 Label（不能圆角、不能左侧
/// 竖条），要么是一张 `MessageBox`（模态、要用户点掉）。自绘之后它是一条带语义
/// 色的横幅：淡色底 + 左侧语义竖条 + 可选标题 + 正文 + 可选关闭。
///
/// 语义由 `UiTone` 给，与角标共用同一套"淡底 + 同色字"的混色口径
/// （`tone_surface`），所以一条警告和一颗警告角标放在一起不会串味。
///
/// 关闭按钮是**唯一**的命中区：点提示条主体不做事。理由与 `UiTag` 不做"可关闭"
/// 同一条——点主体算什么（跳详情？展开？）只有应用知道，框架不猜。
///
/// 高度按"有没有标题"两档算：一行正文，或标题 + 正文两行。不做自动换行——
/// 多行正文该用 `RichText`，提示条保持"一眼扫过"的定位。

///|
/// 提示条的账：文案、标题、语义、是否可关闭。
struct AlertState {
  mut theme : UiTheme
  size : UiSize
  mut metrics : UiMetrics
  mut title : String
  mut text : String
  mut tone : UiTone
  closable : Bool
  /// 固有宽（换文案时重算高要用它；读 frame 在布局前会是 0）
  width : Double
  it : UiInteract
  /// 按下那刻指针是否落在关闭区：抬起时还在才触发，拖出去算取消
  mut press_close : Bool
  mut handler : (() -> Unit raise @moonui.UiError)?
}

///|
/// 自绘提示条。
pub struct UiAlert[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : AlertState
}

///|
/// 提示条的上下内边距（逻辑像素）。
const UI_ALERT_PAD_Y : Double = 12.0

///|
/// 关闭区的边长（命中用的方块）。
const UI_ALERT_CLOSE_BOX : Double = 22.0

///|
/// 行高：字号 × 1.45。标题与正文共用同一档，两行之间只多 2px。
fn ui_alert_line(st : AlertState) -> Double {
  st.metrics.font * 1.45
}

///|
/// 固有高：上下内边距 + 正文一行（有标题再加一行 + 2）。
fn ui_alert_height(st : AlertState) -> Double {
  let line = ui_alert_line(st)
  let base = UI_ALERT_PAD_Y * 2.0 + line
  if st.title == "" {
    base
  } else {
    base + line + 2.0
  }
}

///|
/// 关闭区在控件内的矩形（x, y, w, h）：右上角留 6px 边距。
fn ui_alert_close_box(w : Double) -> (Double, Double, Double, Double) {
  let b = UI_ALERT_CLOSE_BOX
  (w - b - 6.0, 6.0, b, b)
}

///|
/// 画一条提示：淡底（悬停微深）+ 左竖条 + 标题 + 正文 + 关闭叉。
fn ui_paint_alert(
  st : AlertState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let t = st.theme
  let c = t.tone(st.tone)
  let base = t.tone_surface(st.tone)
  // 悬停让底色朝面色再混一格：提示条本身不可点，但指针停上来时"这一条被读到"
  // 的反馈比完全静止更像 UI，且不影响任何命中判定。
  let bg = ui_mix(base, t.surface_hover, 0.16 * st.it.hover_amt)
  ui_paint_fill(dl, 0.0, 0.0, w, h, st.metrics.radius, bg)
  // 左侧竖条：3px 宽、独立圆角，两端不会被底色的圆角吃掉。
  ui_paint_fill(dl, 0.0, 0.0, 3.0, h, 1.5, c)
  let close_w = if st.closable { UI_ALERT_CLOSE_BOX + 10.0 } else { 0.0 }
  let tx = 12.0
  let tw = w - tx - 12.0 - close_w
  let line = ui_alert_line(st)
  if st.title == "" {
    ui_paint_line_text(
      dl,
      env,
      st.text,
      tx,
      UI_ALERT_PAD_Y,
      tw,
      line,
      st.metrics.font,
      false,
      t.text,
    )
  } else {
    ui_paint_line_text(
      dl,
      env,
      st.title,
      tx,
      UI_ALERT_PAD_Y,
      tw,
      line,
      st.metrics.font,
      true,
      c,
    )
    ui_paint_line_text(
      dl,
      env,
      st.text,
      tx,
      UI_ALERT_PAD_Y + line + 2.0,
      tw,
      line,
      st.metrics.font,
      false,
      t.text,
    )
  }
  if st.closable {
    let (bx, by, bw, bh) = ui_alert_close_box(w)
    let fg = if st.it.pressed && st.press_close { t.text } else { t.text_muted }
    ui_paint_center_text(
      dl,
      env,
      "×",
      bx,
      by,
      bw,
      bh,
      st.metrics.font + 2.0,
      true,
      fg,
    )
  }
}

///|
/// 指针账：按下时记"是否落在叉上"，抬起时仍落在同一块才回调。
fn[B : @moonui.Backend] ui_alert_watch(
  w : @moonui.Widget[B],
  st : AlertState,
) -> Unit raise @moonui.UiError {
  let hit_close = fn(p : @moonui.LogicalPoint) -> Bool {
    if !st.closable {
      return false
    }
    let fw = w.frame().size.width
    let ox = w.frame().origin.x
    let oy = w.frame().origin.y
    let (bx, by, bw, bh) = ui_alert_close_box(fw)
    let x = p.x - ox
    let y = p.y - oy
    x >= bx && x <= bx + bw && y >= by && y <= by + bh
  }
  let _ = w.on(
    fn(e) {
      match e {
        @moonui.MouseDown(_, @moonui.Left, _, _) => true
        @moonui.MouseUp(_, @moonui.Left, _, _) => true
        _ => false
      }
    },
    fn(e) raise @moonui.UiError {
      match e {
        @moonui.MouseDown(_, _, p, _) =>
          if st.closable {
            st.press_close = hit_close(p)
          }
        @moonui.MouseUp(_, _, p, _) => {
          let fire = st.press_close && hit_close(p)
          st.press_close = false
          w.repaint()
          if fire {
            match st.handler {
              Some(f) => f()
              None => ()
            }
          }
        }
        _ => ()
      }
    },
  )
}

///|
/// 造一条提示。`title` 为空就是单行条；`closable` 打开后右上角出现 `×`，
/// 点它触发 `on_close`（**不会**自己从布局里消失——那是调用方的事）。
pub fn[B : @moonui.Backend] UiAlert::UiAlert(
  backend : B,
  text : String,
  title~ : String = "",
  tone~ : UiTone = UiTone::UiAccent,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
  width~ : Double = 360.0,
  closable~ : Bool = false,
  app~ : @moonui.App[B]? = None,
) -> UiAlert[B] raise @moonui.UiError {
  let metrics = theme.metrics(size)
  let w = if width > 0.0 { width } else { 360.0 }
  let state = AlertState::{
    theme,
    size,
    metrics,
    title,
    text,
    tone,
    closable,
    width: w,
    it: UiInteract::new(),
    press_close: false,
    handler: None,
  }
  let widget = @moonui.Widget::custom(
    backend,
    @moonui.LogicalSize(w, ui_alert_height(state)),
    fn(dl, env) { ui_paint_alert(state, dl, env) },
  )
  ui_watch_state(widget, state.it, app~)
  ui_alert_watch(widget, state)
  { backend, widget, state, }
}

///|
pub fn[B] UiAlert::widget(self : UiAlert[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
pub fn[B] UiAlert::text(self : UiAlert[B]) -> String {
  self.state.text
}

///|
pub fn[B] UiAlert::tone(self : UiAlert[B]) -> UiTone {
  self.state.tone
}

///|
/// 关闭回调（只在 `closable` 且真点到叉上时触发）。
pub fn[B] UiAlert::on_close(
  self : UiAlert[B],
  f : () -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
/// 换文案：单行条宽度不变，高度按"有没有标题"重算。
pub fn[B : @moonui.Backend] UiAlert::set_text(
  self : UiAlert[B],
  text : String,
) -> Unit raise @moonui.UiError {
  if self.state.text == text {
    return
  }
  self.state.text = text
  self.widget.set_custom_size(
    @moonui.LogicalSize(self.state.width, ui_alert_height(self.state)),
  )
  self.widget.repaint()
}

///|
/// 换标题（空串 = 去掉标题行）。
pub fn[B : @moonui.Backend] UiAlert::set_title(
  self : UiAlert[B],
  title : String,
) -> Unit raise @moonui.UiError {
  if self.state.title == title {
    return
  }
  self.state.title = title
  self.widget.set_custom_size(
    @moonui.LogicalSize(self.state.width, ui_alert_height(self.state)),
  )
  self.widget.repaint()
}

///|
/// 换语义色（成功/警告/危险/中性/主色）。
pub fn[B : @moonui.Backend] UiAlert::set_tone(
  self : UiAlert[B],
  tone : UiTone,
) -> Unit raise @moonui.UiError {
  if self.state.tone == tone {
    return
  }
  self.state.tone = tone
  self.widget.repaint()
}

///|
/// 换整套令牌：字号变了行高与固有高都要跟着重算。
pub fn[B : @moonui.Backend] UiAlert::set_theme(
  self : UiAlert[B],
  theme : UiTheme,
) -> Unit raise @moonui.UiError {
  self.state.theme = theme
  self.state.metrics = theme.metrics(self.state.size)
  self.widget.set_custom_size(
    @moonui.LogicalSize(self.state.width, ui_alert_height(self.state)),
  )
  self.widget.repaint()
}
