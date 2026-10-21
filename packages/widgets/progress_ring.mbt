///|
/// `ProgressRing`——环形进度（`T107` 的第一位住户）。
///
/// 为什么它是"自定义绘制面"而不是原生控件：macOS 的 `NSProgressIndicator` 只有
/// 条状与不定长转圈两种，Win32 的进度条同样只有条状，两边都没有"已知比例的
/// 环"；而配额卡、播放器、仪表盘里到处是这个东西。
///
/// 画法：**轨道一圈 + 进度一段，各是一条 `StrokeArc`**（`T109` 第一刀）。它原本
/// 是 72 段 `Line` 拼的（每 5°，8px 线宽下接缝缺口 `w/2 × sin(2.5°)` ≈ 0.09px）
/// ——先拼是有意的：让真实控件把缺口顶出来，再决定要不要动 ABI。顶出来的结论
/// 很具体（缺的就是"弧"），于是 `DrawList::stroke_arc` 落地，一个环从 73 条命令
/// 降到 2 条，大尺寸、粗线宽下也不再有棱角。
///
/// 坐标一律控件局部逻辑像素（`T101` 的契约），逻辑→物理换算归后端。

///|
/// 夹到 0..1。`NaN` 也归 0——进度条拿一个 NaN 进来通常意味上游算错了，画一个
/// 空环比画一条"整圈但没完成"的假象更诚实。
fn clamp_unit(v : Double) -> Double {
  if v != v {
    // NaN 自反：`NaN != NaN` 为真，所以这一支只有 NaN 进得来
    0.0
  } else if v < 0.0 {
    0.0
  } else if v > 1.0 {
    1.0
  } else {
    v
  }
}

///|
/// 自动文案：四舍五入到整数百分比。`value` 已在 0..1 内，所以加 0.5 再截断就是
/// 四舍五入（负数不用管）。
fn percent_text(value : Double) -> String {
  let pct = (value * 100.0 + 0.5).to_int()
  "\{pct}%"
}

///|
/// 环的可变账：绘制回调每帧读它，`set_*` 改完立刻 `repaint`。
///
/// 为什么状态和控件分两张：绘制回调是在 `Widget::custom` 那一刻注册的，那一刻
/// 控件还不存在（它没法捕获自己），所以闭包捕获的是这份状态，控件只是它的
/// 宿主与重画入口。`T101` 的选择是"Core 不缓存清单"，于是"数据在哪"这件事就
/// 必须由控件自己回答——在这里就是这张小表。
struct RingState {
  mut value : Double
  mut label : String
  mut show_label : Bool
  thickness : Double
  track : Int32
  mut accent : Int32
  text_color : Int32
  font_size : Double
}

///|
/// 环形进度控件。`new` 之后用 `widget()` 拿控件进布局，用 `set_value()` 推数据
/// （自动重画）；尺寸由构造参数 `size` 定（正方形），`.width()/.height()` 仍可
/// 覆盖——覆盖之后环按较小的那条边自适应，不会画成椭圆。
pub struct ProgressRing[B] {
  widget : @moonui.Widget[B]
  state : RingState
  side : Double
}

///|
/// 造一个环形进度。
///
/// 参数口径：
/// - `value` 0..1（越界夹住）；`label` 空串 = 自动百分比，非空 = 原样显示；
/// - `show_label=false` 时中心什么都不画（纯环，适合小尺寸或外部已有文案）；
/// - `thickness<=0` = 不画环（只留中心文案）：零宽的描边没有意义，与其让后端
///   报错，不如在这里说清"没有环"；
/// - `font_size=0` = 自动（边长 × 0.22），给了就按给的走；
/// - 颜色是 0xRRGGBB。**没有从 `Theme` 取色**：`Theme` 挂在 `App` 上，控件拿
///   不到（`Widget` 只有 style），所以先由调用方把色板传进来——等 Core 长出
///   "控件读主题令牌"的口子再接，别在这里造第二套主题。
pub fn[B : @moonui.Backend] ProgressRing::new(
  backend : B,
  value : Double,
  size~ : Double = 96.0,
  thickness~ : Double = 8.0,
  track~ : Int32 = 0xE2E8F0,
  accent~ : Int32 = 0x2B6CB0,
  text_color~ : Int32 = 0x1A202C,
  label~ : String = "",
  show_label~ : Bool = true,
  font_size~ : Double = 0.0,
) -> ProgressRing[B] raise @moonui.UiError {
  let side = if size > 0.0 { size } else { 0.0 }
  let state = RingState::{
    value: clamp_unit(value),
    label,
    show_label,
    thickness: if thickness > 0.0 {
      thickness
    } else {
      0.0
    },
    track,
    accent,
    text_color,
    font_size: if font_size > 0.0 {
      font_size
    } else {
      0.0
    },
  }
  let widget = @moonui.Widget::custom(
    backend,
    @moonui.LogicalSize(side, side),
    fn(dl, env) { paint_ring(state, dl, env) },
  )
  { widget, state, side, }
}

///|
/// 把环画进这份清单。纯函数：不读后端、不 raise，度量全走 `PaintEnv`。
fn paint_ring(
  state : RingState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let side = if w < h { w } else { h }
  let thick = state.thickness
  // 描边是"以半径为中心线"往两边各半个线宽，所以半径要收回半个线宽，
  // 否则环会被控件的矩形裁掉外侧一半。
  let r = side / 2.0 - thick / 2.0
  // 线宽非正 = 没有环可画（`thickness=0` 的构造参数被夹到 0）：中心文案照旧，
  // 别把 0 宽描边丢给后端——那是调用方的口径错误，不是"画一条发丝线"
  if thick > 0.0 && r > 0.0 {
    let cx = w / 2.0
    let cy = h / 2.0
    // 底圈整圈，再从十二点方向叠进度：两段都从同一条半径起，接缝天然对齐
    dl.stroke_arc(cx, cy, r, 0.0, 360.0, width=thick, rgb=state.track)
    if state.value > 0.0 {
      dl.stroke_arc(
        cx,
        cy,
        r,
        -90.0,
        360.0 * state.value,
        width=thick,
        rgb=state.accent,
      )
    }
  }
  if !state.show_label {
    return
  }
  let text = if state.label == "" {
    percent_text(state.value)
  } else {
    state.label
  }
  let font = if state.font_size > 0.0 {
    state.font_size
  } else {
    // 边长 × 0.22：96px 的环给 21px，正好放得下"100%"三个字还留白
    side * 0.22
  }
  let (tw, th) = env.measure_text(text, font, true)
  dl.text(
    text,
    (w - tw) / 2.0,
    (h - th) / 2.0,
    size=font,
    bold=true,
    rgb=state.text_color,
  )
}

///|
/// 拿控件进布局（同一个控件可以反复取，返回的是同一个对象）。
pub fn[B] ProgressRing::widget(self : ProgressRing[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
/// 当前进度（0..1）。
pub fn[B] ProgressRing::value(self : ProgressRing[B]) -> Double {
  self.state.value
}

///|
/// 声明尺寸（正方形边长）。
pub fn[B] ProgressRing::side(self : ProgressRing[B]) -> Double {
  self.side
}

///|
/// 推一个新进度并重画。越界按夹住后的值算（`value()` 读到的也是夹住后的）。
///
/// 每次调用都重画，不做"同值跳过"：省那一帧的代价是"我改了数据但屏幕没变"这
/// 种只有用户能发现的 bug，而一帧两条弧在真机上远不到一毫秒。
pub fn[B : @moonui.Backend] ProgressRing::set_value(
  self : ProgressRing[B],
  value : Double,
) -> Unit raise @moonui.UiError {
  self.state.value = clamp_unit(value)
  self.widget.repaint()
}

///|
/// 换中心文案并重画。`""` = 回到自动百分比。
pub fn[B : @moonui.Backend] ProgressRing::set_label(
  self : ProgressRing[B],
  label : String,
) -> Unit raise @moonui.UiError {
  self.state.label = label
  self.widget.repaint()
}

///|
/// 开关中心文案并重画。
pub fn[B : @moonui.Backend] ProgressRing::set_show_label(
  self : ProgressRing[B],
  show : Bool,
) -> Unit raise @moonui.UiError {
  self.state.show_label = show
  self.widget.repaint()
}

///|
/// 换主色（进度那一截）并重画。
pub fn[B : @moonui.Backend] ProgressRing::set_accent(
  self : ProgressRing[B],
  accent : Int32,
) -> Unit raise @moonui.UiError {
  self.state.accent = accent
  self.widget.repaint()
}
