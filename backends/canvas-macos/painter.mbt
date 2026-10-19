///|
/// Painter 的真实现（§52.5 分期②）：把 canvas-common 绘制配方的逻辑像素账
/// 翻译成 moonui_canvas_* 的物理像素 ABI（adapter.h 画布段）。
///
/// 换算的口径（§30）：
///   - 坐标/宽高：逻辑 × scale，四舍五入到物理整数；
///   - radius/blur/描边宽/字号：同为逻辑量，乘同一份 scale；
///   - 度量是双向的：draw 拿物理字号去画，measure 量回来再除回逻辑——
///     "量出来的就是画出来的"在换算层保持成立（配方只见逻辑账）。
///
/// scale 取窗口的 Scale（x=y，位图是物理像素方形栅格）；位图上下文在
/// C 侧开帧时已经把 y 翻成 UI 惯用的左上原点，这里不用再操心。
pub struct CanvasPainter {
  canvas : @native-common.Canvas
  scale : Double
}

///|
pub fn CanvasPainter::new(
  canvas : @native-common.Canvas,
  scale : Double,
) -> CanvasPainter {
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
  @native-common.canvas_fill_rect(
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
  @native-common.canvas_blur_region(
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
  @native-common.canvas_stroke_rect(
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
  @native-common.canvas_fill_linear(
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
  @native-common.canvas_shadow(
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
  @native-common.canvas_line(
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
pub impl @canvas-common.Painter for CanvasPainter with fn text(
  self,
  text,
  x,
  y,
  size,
  bold,
  rgb,
) -> Unit raise @moonui.UiError {
  @native-common.canvas_draw_text(
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
  let (w, h) = @native-common.canvas_measure_text(
    text,
    size * self.scale,
    bold~,
  )
  // 物理量除回逻辑，配方的账本仍是逻辑像素
  (w / self.scale, h / self.scale)
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn save(
  self : CanvasPainter,
) -> Unit raise @moonui.UiError {
  @native-common.canvas_save(self.canvas)
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn restore(
  self : CanvasPainter,
) -> Unit raise @moonui.UiError {
  @native-common.canvas_restore(self.canvas)
}

///|
pub impl @canvas-common.Painter for CanvasPainter with fn clip_rect(
  self,
  x,
  y,
  w,
  h,
) -> Unit raise @moonui.UiError {
  @native-common.canvas_clip_rect(
    self.canvas,
    self.px(x),
    self.px(y),
    self.px(w),
    self.px(h),
  )
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
  @native-common.canvas_draw_image(
    self.canvas,
    bytes,
    self.px(x),
    self.px(y),
    self.px(w),
    self.px(h),
  )
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
  text,
  measure_text,
  draw_image,
  save,
  restore,
  clip_rect,
}
