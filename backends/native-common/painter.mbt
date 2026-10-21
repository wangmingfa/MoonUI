///|
/// Painter 的真实现（§52.5 分期②）：把 canvas-common 绘制配方的逻辑像素账
/// 翻译成 moonui_canvas_* 的物理像素 ABI（adapter.h 画布段）。
///
/// 为什么住在 native-common 而不是 canvas-macos（`T101` 2026-10-20 搬家）：
/// 它包的是 `moonui_canvas_*` 那批 FFI，而**那批声明本来就住在这个包**
/// （canvas.mbt）。自定义绘制面（`WidgetKind::Custom`）在原生后端上也是
/// "把清单画进一张画布"，用的是同一个实现——留在 canvas-macos 的话，原生
/// 后端要用它就得反向 import 自绘后端（依赖倒置），或者复制一份换算账
/// （两处换算 = 两处 HiDPI bug）。搬到这里之后两个后端共用一份。
///
/// 换算的口径（§30）：
///   - 坐标/宽高：逻辑 × scale，四舍五入到物理整数；
///   - radius/blur/描边宽/字号：同为逻辑量，乘同一份 scale；
///   - 度量是双向的：draw 拿物理字号去画，measure 量回来再除回逻辑——
///     "量出来的就是画出来的"在换算层保持成立（配方只见逻辑账）。
///
/// scale 取窗口的 Scale（x=y，位图是物理像素方形栅格）；位图上下文在
/// C 侧开帧时已经把 y 翻成 UI 惯用的左上原点，这里不用再操心。

///|
/// 一支"画到画布上"的画笔：画布句柄 + 逻辑→物理的比例。两个后端共用
/// ——自绘后端画窗口帧，原生后端画自定义绘制面那块位图。
pub struct CanvasPainter {
  canvas : Canvas
  scale : Double
}

///|
pub fn CanvasPainter::new(canvas : Canvas, scale : Double) -> CanvasPainter {
  { canvas, scale, }
}

///|
/// 逻辑值 × scale 四舍五入到物理整数。负坐标用 floor 半径（-3.5 → -4），
/// 保证零附近的值不因为向零截断而偏进相邻像素。
fn CanvasPainter::px(self : CanvasPainter, v : Double) -> Int32 {
  (v * self.scale + 0.5).floor().to_int()
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn fill_rect(
  self,
  x,
  y,
  w,
  h,
  radius,
  rgb,
  alpha,
) -> Unit raise @moonui.UiError {
  canvas_fill_rect(
    self.canvas,
    self.px(x),
    self.px(y),
    self.px(w),
    self.px(h),
    radius=radius * self.scale,
    rgb~,
    alpha~,
  )
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn blur_region(
  self,
  x,
  y,
  w,
  h,
  radius,
) -> Unit raise @moonui.UiError {
  canvas_blur_region(
    self.canvas,
    self.px(x),
    self.px(y),
    self.px(w),
    self.px(h),
    radius=radius * self.scale,
  )
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn stroke_rect(
  self,
  x,
  y,
  w,
  h,
  radius,
  width,
  rgb,
) -> Unit raise @moonui.UiError {
  canvas_stroke_rect(
    self.canvas,
    self.px(x),
    self.px(y),
    self.px(w),
    self.px(h),
    radius=radius * self.scale,
    width=width * self.scale,
    rgb~,
  )
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn fill_linear(
  self,
  x,
  y,
  w,
  h,
  stops,
) -> Unit raise @moonui.UiError {
  // stops 的位置是 0..1 的比例，不随 scale 换算（它量的是矩形自身的宽高）
  canvas_fill_linear(
    self.canvas,
    self.px(x),
    self.px(y),
    self.px(w),
    self.px(h),
    stops,
  )
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn shadow(
  self,
  dx,
  dy,
  blur,
  rgb,
) -> Unit raise @moonui.UiError {
  canvas_shadow(
    self.canvas,
    self.px(dx),
    self.px(dy),
    blur=blur * self.scale,
    rgb~,
  )
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn line(
  self,
  x0,
  y0,
  x1,
  y1,
  width,
  rgb,
) -> Unit raise @moonui.UiError {
  canvas_line(
    self.canvas,
    self.px(x0),
    self.px(y0),
    self.px(x1),
    self.px(y1),
    width=width * self.scale,
    rgb~,
  )
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn stroke_arc(
  self,
  cx,
  cy,
  r,
  start_deg,
  sweep_deg,
  width,
  rgb,
) -> Unit raise @moonui.UiError {
  // 角度不随 scale 变（度就是度），圆心/半径/线宽跟着 scale 走物理像素
  canvas_stroke_arc(
    self.canvas,
    self.px(cx),
    self.px(cy),
    self.px(r),
    start_deg~,
    sweep_deg~,
    width=width * self.scale,
    rgb~,
  )
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn fill_polygon(
  self,
  points,
  rgb,
  alpha,
) -> Unit raise @moonui.UiError {
  // 顶点是坐标，跟着 scale 走物理像素（与 line / fill_rect 同一条）
  let phys : Array[(Int32, Int32)] = []
  for p in points {
    phys.push((self.px(p.0), self.px(p.1)))
  }
  canvas_fill_polygon(self.canvas, phys, rgb~, alpha~)
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn text(
  self,
  text,
  x,
  y,
  size,
  bold,
  rgb,
) -> Unit raise @moonui.UiError {
  canvas_draw_text(
    self.canvas,
    text,
    self.px(x),
    self.px(y),
    size * self.scale,
    bold~,
    rgb~,
  )
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn measure_text(
  self,
  text,
  size,
  bold,
) -> (Double, Double) raise @moonui.UiError {
  let (w, h) = canvas_measure_text(text, size * self.scale, bold~)
  // 物理量除回逻辑，配方的账本仍是逻辑像素
  (w / self.scale, h / self.scale)
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn save(
  self : CanvasPainter,
) -> Unit raise @moonui.UiError {
  canvas_save(self.canvas)
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn restore(
  self : CanvasPainter,
) -> Unit raise @moonui.UiError {
  canvas_restore(self.canvas)
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn clip_rect(
  self,
  x,
  y,
  w,
  h,
) -> Unit raise @moonui.UiError {
  canvas_clip_rect(self.canvas, self.px(x), self.px(y), self.px(w), self.px(h))
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn draw_image(
  self,
  bytes,
  x,
  y,
  w,
  h,
) -> Unit raise @moonui.UiError {
  canvas_draw_image(
    self.canvas,
    bytes,
    self.px(x),
    self.px(y),
    self.px(w),
    self.px(h),
  )
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn translate(
  self,
  dx,
  dy,
) -> Unit raise @moonui.UiError {
  canvas_translate(self.canvas, self.px(dx), self.px(dy))
}

///|
/// 显式把 Painter 方法挂成 CanvasPainter 的普通方法（新语法要求，避免
/// 隐式提升的弃用告警）。
pub extend CanvasPainter with @canvas-common.Painter::{
  fill_rect,
  blur_region,
  stroke_rect,
  fill_linear,
  shadow,
  line,
  stroke_arc,
  fill_polygon,
  text,
  measure_text,
  draw_image,
  save,
  restore,
  clip_rect,
  translate,
}
