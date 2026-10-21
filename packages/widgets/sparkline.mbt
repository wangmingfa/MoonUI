///|
/// `Sparkline`——迷你折线图（`T107` 的第二位住户）。
///
/// 它要的东西比环还少：一串点连成折线，就是 `n-1` 条 `Line`——这是 `Line` 的
/// 本义，不算绕路。面积填充（线下方的闭合多边形）是 `T109` 第二刀给 `DrawList`
/// 补了 `fill_polygon` 之后才有的——`area~` 打开它就把折线下方填成一块半透明
/// 的底色（轮廓 = 折线顶点 + 底边两点，首尾相连）。
///
/// 画法上一条要紧的：面积**画在折线之前**。反过来那块半透明底色会盖在线上，
/// 线看着变淡了——那不是"面积"该有的样子。
///
/// 取值域：不给 `min`/`max` 就按数据自适应；只给一侧时另一侧仍自动。数据全等
/// （或只有一个点）时值域宽度为 0，折线画在**竖直居中**——贴着顶或贴底都会
/// 被误读成"到顶了"。
///
/// 坐标一律控件局部逻辑像素（`T101` 的契约）。内边距按"最胖的那一笔"算——
/// `max(line_width / 2, dot) + 1`：只按线宽算的话，最高/最低那个点的端点圆会
/// 被控件矩形裁掉一半（顶点圆比半根线宽大得多）。

///|
/// 折线图的可变账（与 `RingState` 同一条理由：绘制回调捕获状态，控件只是宿主）。
struct SparkState {
  mut series : Array[Double]
  mut min : Double?
  mut max : Double?
  mut line : Int32
  line_width : Double
  baseline : Bool
  baseline_color : Int32
  dot : Double
  max_points : Int32
  area : Bool
  area_color : Int32
  area_alpha : Int32
}

///|
/// 迷你折线图。`new` 之后用 `widget()` 进布局，`set_series()` / `push()` 推数据
/// （自动重画）。`width`/`height` 是声明尺寸，`.width()/.height()` 仍可覆盖，
/// 覆盖之后点按实际尺寸重算。
pub struct Sparkline[B] {
  widget : @moonui.Widget[B]
  state : SparkState
  size : @moonui.LogicalSize
}

///|
/// 造一个折线图。
///
/// - `line_width` 是折线粗细；`dot` 是端点圆点半径，`0` = 不画端点；
/// - `baseline=true` 会在底边画一条 1px 的基准线（适合"离零多远"的读数）；
/// - `area=true` 会把折线**下方**填成一块闭合多边形（面积图，`T109` 第二刀
///   给 `DrawList` 补了 `fill_polygon` 之后才有的）；填充底边是控件底边
///   （与 `baseline` 那条线同一条），颜色 `area_color`、透明度 `area_alpha`；
/// - `min`/`max` 给 `Some` 就钉住那一侧的值域，值落在域外时**夹到边**（不是
///   画到框外——框外会被后端裁掉，看着像断线）；
/// - `max_points` > 0 时，`push` 超长会从头部丢弃（滚动窗口）；`set_series`
///   不裁剪，调用方给多长就画多长。
pub fn[B : @moonui.Backend] Sparkline::new(
  backend : B,
  series : Array[Double],
  width~ : Double = 160.0,
  height~ : Double = 48.0,
  line~ : Int32 = 0x2B6CB0,
  line_width~ : Double = 1.5,
  baseline~ : Bool = false,
  baseline_color~ : Int32 = 0xE2E8F0,
  dot~ : Double = 3.0,
  min~ : Double? = None,
  max~ : Double? = None,
  max_points~ : Int32 = 0,
  area~ : Bool = false,
  area_color~ : Int32 = 0x2B6CB0,
  area_alpha~ : Int32 = 64,
) -> Sparkline[B] raise @moonui.UiError {
  let w = if width > 0.0 { width } else { 0.0 }
  let h = if height > 0.0 { height } else { 0.0 }
  let state = SparkState::{
    series,
    min,
    max,
    line,
    line_width: if line_width > 0.0 {
      line_width
    } else {
      1.0
    },
    baseline,
    baseline_color,
    dot: if dot > 0.0 {
      dot
    } else {
      0.0
    },
    max_points,
    area,
    area_color,
    area_alpha,
  }
  let widget = @moonui.Widget::custom(backend, @moonui.LogicalSize(w, h), fn(
    dl,
    env,
  ) {
    paint_spark(state, dl, env)
  })
  { widget, state, size: @moonui.LogicalSize(w, h), }
}

///|
/// 值域：显式给的那一侧优先，另一侧从数据里扫。空数组时返回 `(0, 0)`。
fn spark_domain(state : SparkState) -> (Double, Double) {
  let mut mn = 0.0
  let mut mx = 0.0
  let mut first = true
  for v in state.series {
    if first {
      mn = v
      mx = v
      first = false
    } else {
      if v < mn {
        mn = v
      }
      if v > mx {
        mx = v
      }
    }
  }
  let lo = match state.min {
    Some(v) => v
    None => mn
  }
  let hi = match state.max {
    Some(v) => v
    None => mx
  }
  (lo, hi)
}

///|
/// 把折线画进这份清单。纯函数：不读后端、不 raise。
fn paint_spark(
  state : SparkState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let lw = state.line_width
  // 内边距要把"最胖的那一笔"让出来：端点圆的半径通常比半根线宽还大，只按
  // 线宽算的话，最高/最低那个点的圆会被控件矩形切掉一半。
  let half = if lw / 2.0 > state.dot { lw / 2.0 } else { state.dot }
  let pad = half + 1.0
  // 极小控件（比内边距还窄）时把行程压到 0，点会叠在中心——总比负数行程
  // 把线画到框外强
  let inner_w = if w > pad * 2.0 { w - pad * 2.0 } else { 0.0 }
  let inner_h = if h > pad * 2.0 { h - pad * 2.0 } else { 0.0 }
  if state.baseline {
    dl.line(pad, h - pad, w - pad, h - pad, width=1.0, rgb=state.baseline_color)
  }
  let n = state.series.length()
  if n == 0 {
    return
  }
  let (lo, hi) = spark_domain(state)
  let span = hi - lo
  let x_of = fn(i : Int32) -> Double {
    if n <= 1 {
      w / 2.0
    } else {
      pad + inner_w * i.to_double() / (n - 1).to_double()
    }
  }
  let y_of = fn(v : Double) -> Double {
    if span <= 0.0 {
      // 全等数据（或单点）：居中，别贴着上下边误导读数
      h / 2.0
    } else {
      let mut t = (v - lo) / span
      if t < 0.0 {
        t = 0.0
      } else if t > 1.0 {
        t = 1.0
      }
      pad + inner_h * (1.0 - t)
    }
  }
  let mut i = 1
  // 面积填充（`T109` 第二刀）：轮廓 = 折线顶点 + 底边两点，首尾相连。
  // **画在折线之前**——否则那块半透明底色会盖在线上，线看着变淡了。
  if state.area && n >= 2 {
    let poly : Array[(Double, Double)] = []
    let mut j = 0
    while j < n {
      poly.push((x_of(j), y_of(state.series[j])))
      j = j + 1
    }
    // 底边：右端点 → 右下 → 左下 → 左端点（首尾相连，最后一点连回第一点）
    let base_y = h - pad
    poly.push((x_of(n - 1), base_y))
    poly.push((x_of(0), base_y))
    dl.fill_polygon(poly, rgb=state.area_color, alpha=state.area_alpha)
  }
  while i < n {
    dl.line(
      x_of(i - 1),
      y_of(state.series[i - 1]),
      x_of(i),
      y_of(state.series[i]),
      width=lw,
      rgb=state.line,
    )
    i = i + 1
  }
  if state.dot > 0.0 {
    let r = state.dot
    let x = x_of(n - 1)
    let y = y_of(state.series[n - 1])
    // 圆 = 圆角半径取边长一半的方（与环里"用 Line 拼弧"同一条"现有命令够用"）
    dl.fill_rect(x - r, y - r, r * 2.0, r * 2.0, radius=r, rgb=state.line)
  }
}

///|
/// 拿控件进布局。
pub fn[B] Sparkline::widget(self : Sparkline[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
/// 声明尺寸。
pub fn[B] Sparkline::size(self : Sparkline[B]) -> @moonui.LogicalSize {
  self.size
}

///|
/// 当前点数。
pub fn[B] Sparkline::length(self : Sparkline[B]) -> Int32 {
  self.state.series.length()
}

///|
/// 当前数据的一份**拷贝**。不把内部数组直接递出去：数组是引用语义，递出去等于
/// 把"必须 repaint"的账交给调用方去猜。
pub fn[B] Sparkline::series(self : Sparkline[B]) -> Array[Double] {
  let out : Array[Double] = []
  for v in self.state.series {
    out.push(v)
  }
  out
}

///|
/// 整份换数据并重画。
pub fn[B : @moonui.Backend] Sparkline::set_series(
  self : Sparkline[B],
  series : Array[Double],
) -> Unit raise @moonui.UiError {
  self.state.series = series
  self.widget.repaint()
}

///|
/// 追加一个点并重画。设了 `max_points` 就从头部丢弃，保持"最近 N 个"的滚动
/// 窗口语义（丢弃是 O(n) 的：图表的 n 一般几十到几百，不值得上环形缓冲）。
pub fn[B : @moonui.Backend] Sparkline::push(
  self : Sparkline[B],
  value : Double,
) -> Unit raise @moonui.UiError {
  self.state.series.push(value)
  let cap = self.state.max_points
  if cap > 0 && self.state.series.length() > cap {
    let drop = self.state.series.length() - cap
    let kept : Array[Double] = []
    let mut i = drop
    while i < self.state.series.length() {
      kept.push(self.state.series[i])
      i = i + 1
    }
    self.state.series = kept
  }
  self.widget.repaint()
}

///|
/// 钉住 / 放开值域（`None` = 自动）。改完立刻重画。
pub fn[B : @moonui.Backend] Sparkline::set_range(
  self : Sparkline[B],
  min~ : Double?,
  max~ : Double?,
) -> Unit raise @moonui.UiError {
  self.state.min = min
  self.state.max = max
  self.widget.repaint()
}

///|
/// 换线色并重画。
pub fn[B : @moonui.Backend] Sparkline::set_line_color(
  self : Sparkline[B],
  line : Int32,
) -> Unit raise @moonui.UiError {
  self.state.line = line
  self.widget.repaint()
}
