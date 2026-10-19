///|
/// 画布门面（§52.2）：绘制配方的唯一入口形状。真实现（canvas-macos 后端）
/// 把 `moonui_canvas_*` ABI 适配进来（含 Scale 的逻辑→物理换算，§30）；
/// 测试用 `RecordCanvas` 录调用序列逐条比（§52.4 的录制式判据）。

///|
/// 坐标一律逻辑像素；颜色 0xRRGGBB（与皮肤通道同一口径），alpha 0..255
/// 走独立参数（T98② 毛玻璃起；255=不透明，与旧口径逐位一致）。
pub(open) trait Painter {
  /// 圆角矩形填充。radius=0 是直角；alpha 0..255（255 不透明）。
  fn fill_rect(
    self : Self,
    x : Double,
    y : Double,
    w : Double,
    h : Double,
    radius : Double,
    rgb : Int32,
    alpha : Int32,
  ) -> Unit raise @moonui.UiError
  /// 区域模糊（T98② 毛玻璃的"毛"）：对 (x,y,w,h) 那块已画内容做原地高斯
  /// 近似模糊。radius 是逻辑像素；0 是恒等。毛玻璃配方先调它再叠半透底。
  fn blur_region(
    self : Self,
    x : Double,
    y : Double,
    w : Double,
    h : Double,
    radius : Double,
  ) -> Unit raise @moonui.UiError
  /// 圆角矩形描边。width 是描边宽。
  fn stroke_rect(
    self : Self,
    x : Double,
    y : Double,
    w : Double,
    h : Double,
    radius : Double,
    width : Double,
    rgb : Int32,
  ) -> Unit raise @moonui.UiError
  /// 垂直线性渐变（上→下）。stops 是 (0..1 位置, 0xRRGGBB)。
  fn fill_linear(
    self : Self,
    x : Double,
    y : Double,
    w : Double,
    h : Double,
    stops : Array[(Double, Int32)],
  ) -> Unit raise @moonui.UiError
  /// 投影状态：设了之后填充带影，直到 restore 或 blur=0 清零。
  fn shadow(self : Self, dx : Double, dy : Double, blur : Double, rgb : Int32) -> Unit raise @moonui.UiError
  fn line(
    self : Self,
    x0 : Double,
    y0 : Double,
    x1 : Double,
    y1 : Double,
    width : Double,
    rgb : Int32,
  ) -> Unit raise @moonui.UiError
  /// 文本绘制（y 是顶边）。度量走 Painter::measure_text——同一个实现
  /// 必须保证"量出来的就是画出来的"（adapter.h 画布段的契约）。
  fn text(
    self : Self,
    text : String,
    x : Double,
    y : Double,
    size : Double,
    bold : Bool,
    rgb : Int32,
  ) -> Unit raise @moonui.UiError
  /// 文本度量（宽, 高），与本实现的字体/字号对应。
  fn measure_text(self : Self, text : String, size : Double, bold : Bool) -> (
    Double,
    Double,
  ) raise @moonui.UiError
  /// 位图贴图（bytes 是平台认得的图像编码，解码归实现）。缩放到给定矩形。
  fn draw_image(
    self : Self,
    bytes : Bytes,
    x : Double,
    y : Double,
    w : Double,
    h : Double,
  ) -> Unit raise @moonui.UiError
  /// 状态栈：配方的 hover/press 差异靠它包住，出界自动还原。
  fn save(self : Self) -> Unit raise @moonui.UiError
  fn restore(self : Self) -> Unit raise @moonui.UiError
  /// 裁剪区：之后的绘制只落在 (x,y,w,h) 内（与 save/restore 配对，restore
  /// 还原裁剪）。滚动视口裁剪用它把文档区子树锁回最近 Scroll 的视口里
  /// （T98②）——滚出视口的行不画。
  fn clip_rect(self : Self, x : Double, y : Double, w : Double, h : Double) -> Unit raise @moonui.UiError
}

///|
/// 录制式画布：把每次调用记成一行（"fill_rect 10 10 40 40 r8 0xFF0000"），
/// 测试拿整张序列表逐条比。逻辑像素原样记录——换算是真实现的事，录制器
/// 对坐标不做任何加工，断言的就是配方说了什么。
pub(all) struct RecordCanvas {
  mut log : Array[String]
  /// 度量的假账：RecordCanvas 没有字体，按"每字符 8×字号/16"给确定性
  /// 尺寸（与 mock 的启发式同一条思路，§18），够配方断言用。
  mut measure_calls : Int32
}

///|
pub fn RecordCanvas::new() -> RecordCanvas {
  { log: [], measure_calls: 0, }
}

///|
/// 取整条录制序列（测试断言口）。
pub fn RecordCanvas::lines(self : RecordCanvas) -> Array[String] {
  self.log
}

///|
fn fmt(v : Double) -> String {
  // 去掉整数的 ".0"，让断言行干净
  if v == v.floor() && v < 1000000000000000.0 {
    v.to_int().to_string()
  } else {
    // 配方里有 (h-th)/2 这类除不尽的账，抹掉浮点尾噪再记
    let r = (v * 1000.0).to_int().to_double() / 1000.0
    r.to_string()
  }
}

///|
fn hex(rgb : Int32) -> String {
  fn two(v : Int32) -> String {
    let hexs = "0123456789abcdef"
    let v = v & 0xFF
    "\{hexs[v / 16].to_char().unwrap()}\{hexs[v % 16].to_char().unwrap()}"
  }
  two(rgb >> 16) + two(rgb >> 8) + two(rgb)
}

///|
pub impl Painter for RecordCanvas with fn fill_rect(
  self,
  x,
  y,
  w,
  h,
  radius,
  rgb,
  alpha,
) -> Unit raise @moonui.UiError {
  // alpha=255（不透明）不记，保持旧断言行干净；半透才带 a 后缀
  let a = if alpha == 255 { "" } else { " a\{alpha}" }
  self.log.push(
    "fill_rect \{fmt(x)} \{fmt(y)} \{fmt(w)} \{fmt(h)} r\{fmt(radius)} #\{hex(rgb)}\{a}",
  )
}

///|
pub impl Painter for RecordCanvas with fn blur_region(self, x, y, w, h, radius) -> Unit raise @moonui.UiError {
  self.log.push(
    "blur_region \{fmt(x)} \{fmt(y)} \{fmt(w)} \{fmt(h)} r\{fmt(radius)}",
  )
}

///|
pub impl Painter for RecordCanvas with fn stroke_rect(
  self,
  x,
  y,
  w,
  h,
  radius,
  width,
  rgb,
) -> Unit raise @moonui.UiError {
  let line = "stroke_rect \{fmt(x)} \{fmt(y)} \{fmt(w)} \{fmt(h)} r\{fmt(radius)} w\{fmt(width)} #\{hex(rgb)}"
  self.log.push(line)
}

///|
pub impl Painter for RecordCanvas with fn fill_linear(self, x, y, w, h, stops) -> Unit raise @moonui.UiError {
  let mut parts = ""
  for i, s in stops {
    let sep = if i == 0 { "" } else { "," }
    parts = "\{parts}\{sep}\{fmt(s.0)}:#\{hex(s.1)}"
  }
  self.log.push(
    "fill_linear \{fmt(x)} \{fmt(y)} \{fmt(w)} \{fmt(h)} [\{parts}]",
  )
}

///|
pub impl Painter for RecordCanvas with fn shadow(self, dx, dy, blur, rgb) -> Unit raise @moonui.UiError {
  self.log.push("shadow \{fmt(dx)} \{fmt(dy)} b\{fmt(blur)} #\{hex(rgb)}")
}

///|
pub impl Painter for RecordCanvas with fn line(self, x0, y0, x1, y1, width, rgb) -> Unit raise @moonui.UiError {
  let line = "line \{fmt(x0)} \{fmt(y0)} \{fmt(x1)} \{fmt(y1)} w\{fmt(width)} #\{hex(rgb)}"
  self.log.push(line)
}

///|
pub impl Painter for RecordCanvas with fn text(
  self,
  text,
  x,
  y,
  size,
  bold,
  rgb,
) -> Unit raise @moonui.UiError {
  let weight = if bold { "bold" } else { "regular" }
  let line = "text \"\{text}\" \{fmt(x)} \{fmt(y)} s\{fmt(size)} \{weight} #\{hex(rgb)}"
  self.log.push(line)
}

///|
pub impl Painter for RecordCanvas with fn measure_text(self, text, size, bold) -> (
  Double,
  Double,
) raise @moonui.UiError {
  self.measure_calls = self.measure_calls + 1
  // 确定性假账：每字符 8 逻辑像素宽（与 mock 的启发式同一根尺），高 = 字号×1.4
  let w = text.length().to_double() * 8.0 * (if bold { 1.25 } else { 1.0 })
  (w, size * 1.4)
}

///|
pub impl Painter for RecordCanvas with fn draw_image(self, bytes, x, y, w, h) -> Unit raise @moonui.UiError {
  self.log.push(
    "draw_image \{bytes.length()}B \{fmt(x)} \{fmt(y)} \{fmt(w)} \{fmt(h)}",
  )
}

///|
pub impl Painter for RecordCanvas with fn save(self : RecordCanvas) -> Unit raise @moonui.UiError {
  self.log.push("save")
}

///|
pub impl Painter for RecordCanvas with fn restore(self : RecordCanvas) -> Unit raise @moonui.UiError {
  self.log.push("restore")
}

///|
pub impl Painter for RecordCanvas with fn clip_rect(self, x, y, w, h) -> Unit raise @moonui.UiError {
  self.log.push("clip_rect \{fmt(x)} \{fmt(y)} \{fmt(w)} \{fmt(h)}")
}

///|
/// 显式把 Painter 方法挂成 RecordCanvas 的普通方法（新语法要求，避免隐式提升的弃用告警）。
pub extend RecordCanvas with Painter::{
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
