///|
/// 自定义控件的绘制清单（`T101`，§17 的 CustomWidget 地基）。
///
/// 为什么记一份清单、而不是"直接发一支画笔"：Core 不能依赖任何后端包（§4 的
/// 依赖方向），而 `Painter`（`backends/canvas-common`）住在后端那一侧——把画笔
/// 塞进 Core 的控件里，就得先让 Core 认识后端的类型，方向反过来。清单是**纯
/// 数据**：`Widget::custom` 的绘制回调往里写，Core 交给后端的 `draw_custom`，
/// 后端用自己那支画笔重放。于是同一个自定义控件在原生后端画进一只 NSView 的
/// 位图、在自绘后端画进窗口帧，Core 一个字不改；wasm 上还能用 MockBackend
/// 断言"画了什么、按什么参数画"，不用开窗。
///
/// 坐标是**控件局部**的逻辑像素（原点 = 控件左上角、y 向下），与 Core 的布局
/// 口径一致（§30）。逻辑→物理的换算归后端——只有它知道这台机器的 Scale，两边
/// 都换算就会出现"除两次"的经典 HiDPI 位移（同 `Backend::poll_event` 的契约）。
///
/// 这套命令与 `Painter` 的方法一一对应（含 `save`/`restore`/`clip_rect`），是
/// 重放能逐条对上的前提。要加命令就两边一起加，别只加一边——只在一侧存在的
/// 命令在另一条后端上必然被静默丢掉。

///|
/// 一条绘制命令。字段顺序与 `Painter` 同名方法的参数顺序一致（读重放代码时
/// 不用来回翻签名）。
pub(all) enum DrawCmd {
  /// 圆角矩形填充：x, y, w, h, radius, rgb(0xRRGGBB), alpha(0..255)
  FillRect(Double, Double, Double, Double, Double, Int32, Int32)
  /// 圆角矩形描边：x, y, w, h, radius, width, rgb
  StrokeRect(Double, Double, Double, Double, Double, Double, Int32)
  /// 垂直线性渐变：x, y, w, h, stops[(0..1 位置, rgb)]
  FillLinear(Double, Double, Double, Double, Array[(Double, Int32)])
  /// 投影状态：dx, dy, blur, rgb——设后下一次填充带影，直到 Restore 或 blur=0
  Shadow(Double, Double, Double, Int32)
  /// 直线：x0, y0, x1, y1, width, rgb
  Line(Double, Double, Double, Double, Double, Int32)
  /// 圆弧描边：cx, cy, r, 起始角（度）, 扫过角（度）, 线宽, rgb
  ///
  /// 角度口径：0° = 三点钟方向（正右），**顺时针为正**（与 y 向下的屏幕坐标
  /// 一致），所以 -90° 是十二点；扫过角为负表示逆时针。`|扫过角| ≥ 360` 就是
  /// 一整圈（闭合）。
  StrokeArc(Double, Double, Double, Double, Double, Double, Int32)
  /// 闭合多边形填充：顶点表[(x, y)], rgb, alpha
  ///
  /// 顶点表是**首尾相连**的：最后一点自动连回第一点，调用方只给轮廓上的点、
  /// 不必重复首点。少于 3 点画不出面积（一条线 / 一个点），那条命令什么都不画。
  ///
  /// 为什么单开一条命令而不是让住户口拼矩形：面积图（折线下方的填充）是
  /// `T109` 里真实住户的需求——`Sparkline::area~` 就是它。拿 1px 竖条去糊面积
  /// 会得到一张"条纹图"，看着像有面积其实没有。
  FillPolygon(Array[(Double, Double)], Int32, Int32)
  /// 区域模糊：x, y, w, h, radius（对已画内容原地模糊，`T98②` 毛玻璃）
  BlurRegion(Double, Double, Double, Double, Double)
  /// 文本：内容, x, y（顶边）, 字号, 粗体, rgb
  Text(String, Double, Double, Double, Bool, Int32)
  /// 位图：bytes（平台认得的编码）, x, y, w, h
  Image(Bytes, Double, Double, Double, Double)
  /// 压栈 / 出栈（与 CG 的 save/restore 同构）
  Save
  Restore
  /// 裁剪：之后的绘制只落在 (x,y,w,h) 内，出栈还原
  ClipRect(Double, Double, Double, Double)
  /// 平移坐标系：之后画的都挪 (dx, dy)，出栈还原
  Translate(Double, Double)
} derive(Debug, Eq)

///|
/// 一份绘制清单。`cmds` 追加式增长——一次绘制就是一整份新的清单，不复用旧的
/// （重放方按帧消费，复用会让"这一帧画了什么"变成两句真话）。
pub(all) struct DrawList {
  mut cmds : Array[DrawCmd]
} derive(Debug, Eq)

///|
pub fn DrawList::new() -> DrawList {
  { cmds: [], }
}

///|
/// 清单条数（测试与"空清单不重放"的短路用）。
pub fn DrawList::len(self : DrawList) -> Int32 {
  self.cmds.length()
}

///|
pub fn DrawList::is_empty(self : DrawList) -> Bool {
  self.cmds.length() == 0
}

///|
/// 命令序列（测试断言口，与 `RecordCanvas::lines` 同一条思路：读的是"说了
/// 什么"，不是"画成了什么"）。
pub fn DrawList::commands(self : DrawList) -> Array[DrawCmd] {
  self.cmds
}

///|
pub fn DrawList::fill_rect(
  self : DrawList,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  radius~ : Double = 0.0,
  rgb~ : Int32,
  alpha~ : Int32 = 255,
) -> Unit {
  self.cmds.push(FillRect(x, y, w, h, radius, rgb, alpha))
}

///|
pub fn DrawList::stroke_rect(
  self : DrawList,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  radius~ : Double = 0.0,
  width~ : Double = 1.0,
  rgb~ : Int32,
) -> Unit {
  self.cmds.push(StrokeRect(x, y, w, h, radius, width, rgb))
}

///|
pub fn DrawList::fill_linear(
  self : DrawList,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  stops~ : Array[(Double, Int32)],
) -> Unit {
  self.cmds.push(FillLinear(x, y, w, h, stops))
}

///|
pub fn DrawList::shadow(
  self : DrawList,
  dx : Double,
  dy : Double,
  blur : Double,
  rgb : Int32,
) -> Unit {
  self.cmds.push(Shadow(dx, dy, blur, rgb))
}

///|
pub fn DrawList::line(
  self : DrawList,
  x0 : Double,
  y0 : Double,
  x1 : Double,
  y1 : Double,
  width~ : Double = 1.0,
  rgb~ : Int32,
) -> Unit {
  self.cmds.push(Line(x0, y0, x1, y1, width, rgb))
}

///|
/// 圆弧描边（`T109` 的第一刀）：圆心、半径、起始角、扫过角都是逻辑像素 / 度。
///
/// 为什么单开一条命令而不是让住户口拼折线：`ProgressRing` 拼过——96px 的环
/// 要 72 条 `Line`（每 5°），线宽一涨接缝缺口就可见，而且每帧 72 次重放。
/// 一条命令把这三笔账一次收掉，代价是四个后端各补一个实现（`Painter` trait、
/// 重放、画布 ABI、两份 C）——这就是"先用现有命令顶，顶不住才动 ABI"的兑现。
pub fn DrawList::stroke_arc(
  self : DrawList,
  cx : Double,
  cy : Double,
  r : Double,
  start_deg : Double,
  sweep_deg : Double,
  width~ : Double = 1.0,
  rgb~ : Int32,
) -> Unit {
  self.cmds.push(StrokeArc(cx, cy, r, start_deg, sweep_deg, width, rgb))
}

///|
/// 闭合多边形填充（`T109` 的第二刀）：顶点表、颜色、透明度。
///
/// 顶点表是**首尾相连**的轮廓（最后一点自动连回第一点，不必重复首点）。
/// 少于 3 点画不出面积——那种命令直接不进清单（省掉一条"什么也没画"的命令，
/// 重放方也省得判）。
///
/// `alpha` 0..255（255 不透明），与 `fill_rect` 同一条口径。
pub fn DrawList::fill_polygon(
  self : DrawList,
  points : Array[(Double, Double)],
  rgb~ : Int32,
  alpha~ : Int32 = 255,
) -> Unit {
  if points.length() < 3 {
    return
  }
  self.cmds.push(FillPolygon(points, rgb, alpha))
}

///|
pub fn DrawList::blur_region(
  self : DrawList,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  radius : Double,
) -> Unit {
  self.cmds.push(BlurRegion(x, y, w, h, radius))
}

///|
pub fn DrawList::text(
  self : DrawList,
  text : String,
  x : Double,
  y : Double,
  size~ : Double,
  bold~ : Bool = false,
  rgb~ : Int32,
) -> Unit {
  self.cmds.push(Text(text, x, y, size, bold, rgb))
}

///|
pub fn DrawList::image(
  self : DrawList,
  bytes : Bytes,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
) -> Unit {
  self.cmds.push(Image(bytes, x, y, w, h))
}

///|
pub fn DrawList::save(self : DrawList) -> Unit {
  self.cmds.push(Save)
}

///|
pub fn DrawList::restore(self : DrawList) -> Unit {
  self.cmds.push(Restore)
}

///|
pub fn DrawList::clip_rect(
  self : DrawList,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
) -> Unit {
  self.cmds.push(ClipRect(x, y, w, h))
}

///|
pub fn DrawList::translate(self : DrawList, dx : Double, dy : Double) -> Unit {
  self.cmds.push(Translate(dx, dy))
}

///|
/// 绘制回调看到的环境：这块面多大、以及"这段文字量出来多宽多高"。
///
/// 度量为什么必须由后端给：字体度量属于原生层（§18），Core 里没有字体，编不出
/// 一个诚实的数字。为此 `Backend::measure_text` 是一条独立口子（画布 ABI 的
/// `moonui_canvas_measure_text` 就是它的 mac 实现），自定义控件里"把文字居中"
/// 这类最常见的事才有解。
///
/// 度量拿不到时给 (0, 0)：能走到绘制这一步说明这台机器的画布是活的，量不到
/// 只可能是空串或平台真没有度量（Windows 半的画布缺席，那种机器上
/// `draw_custom` 也会如实拒绝）。
pub(all) struct PaintEnv {
  size : LogicalSize
  measure : (String, Double, Bool) -> (Double, Double)
}

///|
/// 量一段文字（宽, 高），字号与粗体是绘制时同一套参数。
pub fn PaintEnv::measure_text(
  self : PaintEnv,
  text : String,
  size : Double,
  bold : Bool,
) -> (Double, Double) {
  (self.measure)(text, size, bold)
}

///|
/// 这块面的尺寸（逻辑像素）——绘制回调里每一次"居中/贴边"都要读它。
pub fn PaintEnv::width(self : PaintEnv) -> Double {
  self.size.width
}

///|
pub fn PaintEnv::height(self : PaintEnv) -> Double {
  self.size.height
}
