///|
/// `UiSkeleton`——自绘骨架屏（`T360` 第三档）。
///
/// 加载占位在原生控件里没有对应物（`Widget::progress` 是进度条，不是占位块），
/// 而"内容还没来"这一档在真实页面里用得比进度条多得多：卡片列表、表格、详情页
/// 都是先铺几行灰块再换真内容。自绘之后它就是 N 条圆角灰块，最后一条短一些
/// （阅读习惯上的"段落收尾"），色在轨道色与悬停面之间来回混——`T356` 起
/// `App::post_animation` 已经是通用帧口子，这里只是又一位用户。
///
/// 不交 `app` 就是静态灰块（mock 判据、离屏截图都能用）；交了才脉动。
/// 不做"shimmer 渐变扫过"：`DrawCmd` 有 `FillLinear`，但一次扫光要每帧重算
/// 三段渐变的停点，收益只是"更像骨架屏"，不值这一笔；脉动在深色主题下更稳。

///|
/// 骨架屏的账：尺寸、行数、脉动相位。
struct SkeletonState {
  mut theme : UiTheme
  /// 每条灰块的高（也是圆角半径的两倍）
  line_h : Double
  /// 灰块条数（至少 1）
  lines : Int32
  /// 条间距
  gap : Double
  /// 固有宽（判据与重算都读它，不读 frame）
  width : Double
  mut elapsed : Int32
  mut phase : Double
  ticker : @moonui.Ticker
}

///|
/// 自绘骨架屏。
pub struct UiSkeleton[B] {
  backend : B
  widget : @moonui.Widget[B]
  state : SkeletonState
}

///|
/// 一轮脉动周期（毫秒）：1.4s 一个来回，比进度条跑马灯慢——占位块是"还在等"，
/// 晃太快会让整页显得焦躁。
const UI_SKELETON_PERIOD_MS : Int32 = 1400

///|
/// 脉动相位（0..1 来回）：纯函数，判据能逐拍写死；与进度条跑马灯共用
/// `anim_phase` 的 PingPong 那一档。
pub fn ui_skeleton_phase(elapsed : Int32) -> Double {
  @moonui.anim_phase(
    @moonui.RepeatMode::PingPong,
    elapsed,
    UI_SKELETON_PERIOD_MS,
  ).0
}

///|
/// 一拍：推相位 + 重画；相位表一直在跑，所以链一直续着（没有"关档"这一说，
/// 控件还在页面上就该继续脉动）。
fn[B : @moonui.Backend] ui_skeleton_drive(
  st : SkeletonState,
  w : @moonui.Widget[B],
) -> (Bool) -> Bool raise @moonui.UiError {
  fn(first : Bool) -> Bool raise @moonui.UiError {
    if first {
      st.elapsed = 0
    }
    st.elapsed = st.elapsed + 16
    if st.elapsed > 100000 {
      st.elapsed = st.elapsed % UI_SKELETON_PERIOD_MS
    }
    st.phase = ui_skeleton_phase(st.elapsed)
    w.repaint()
    true
  }
}

///|
/// 第 i 条灰块的宽：最后一条取 60%（短收尾），其余满宽；下限 32px，免得
/// 在窄容器里缩成一颗点。
fn ui_skeleton_line_w(st : SkeletonState, i : Int32) -> Double {
  let raw = if i == st.lines - 1 { st.width * 0.6 } else { st.width }
  if raw < 32.0 {
    32.0
  } else if raw > st.width {
    st.width
  } else {
    raw
  }
}

///|
/// 画 N 条灰块。色在凹槽色与悬停面之间按相位混——深浅两族都只是"面色的两档"，
/// 不用为主题各写一套比例。
fn ui_paint_skeleton(
  st : SkeletonState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let t = st.theme
  let rgb = ui_mix(t.track, t.surface_hover, 0.25 + 0.5 * st.phase)
  let mut i = 0
  while i < st.lines {
    let y = i.to_double() * (st.line_h + st.gap)
    if y < h {
      let lw = ui_skeleton_line_w(st, i)
      let lh = if y + st.line_h > h { h - y } else { st.line_h }
      ui_paint_fill(dl, 0.0, y, lw, lh, st.line_h / 2.0, rgb)
    }
    i = i + 1
  }
}

///|
/// 造一块骨架屏。`lines` 至少 1；`width` 是固有宽，行高与间距决定固有高。
pub fn[B : @moonui.Backend] UiSkeleton::UiSkeleton(
  backend : B,
  width~ : Double = 320.0,
  line_h~ : Double = 12.0,
  lines~ : Int32 = 3,
  gap~ : Double = 8.0,
  theme~ : UiTheme = UiTheme::light(),
  app~ : @moonui.App[B]? = None,
) -> UiSkeleton[B] raise @moonui.UiError {
  let w = if width > 0.0 { width } else { 320.0 }
  let lh = if line_h > 2.0 { line_h } else { 12.0 }
  let n = if lines < 1 { 1 } else { lines }
  let g = if gap < 0.0 { 0.0 } else { gap }
  let state = SkeletonState::{
    theme,
    line_h: lh,
    lines: n,
    gap: g,
    width: w,
    elapsed: 0,
    phase: 0.0,
    ticker: @moonui.Ticker(),
  }
  let h = n.to_double() * lh + (n - 1).to_double() * g
  let widget = @moonui.Widget::custom(backend, @moonui.LogicalSize(w, h), fn(
    dl,
    env,
  ) {
    ui_paint_skeleton(state, dl, env)
  })
  match app {
    Some(a) => {
      let _ = a.post_animation(
        state.ticker,
        16,
        ui_skeleton_drive(state, widget),
      )
    }
    None => ()
  }
  { backend, widget, state, }
}

///|
pub fn[B] UiSkeleton::widget(self : UiSkeleton[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
/// 当下脉动相位（0..1）：判据与真窗读数都从这里取。
pub fn[B] UiSkeleton::phase(self : UiSkeleton[B]) -> Double {
  self.state.phase
}

///|
/// 帧链还在不在（不交 `app` 时恒 false）。
pub fn[B] UiSkeleton::ticking(self : UiSkeleton[B]) -> Bool {
  self.state.ticker.running()
}

///|
/// 换令牌并重画（行高由构造参数定，不随字号走——占位块本来就不是文字）。
pub fn[B : @moonui.Backend] UiSkeleton::set_theme(
  self : UiSkeleton[B],
  theme : UiTheme,
) -> Unit raise @moonui.UiError {
  self.state.theme = theme
  self.widget.repaint()
}
