///|
/// 画布（§52，自绘后端的绘制通道）的 FFI 声明与 MoonBit 封装。
///
/// 第一期只做离屏位图帧：`begin_frame` 开一张物理像素位图，各 `canvas_*`
/// 往上画，`read_pixel` 供测试断言；上屏的 attach 在 canvas-macos 后端那批
/// 再进 ABI（adapter.h 画布段注）。逻辑像素换算**不在这层**——调用方
/// （未来的 canvas 后端）拿着窗口 Scale 自己换物理，这里的数全是物理像素。
///
/// Windows 半第一期整体缺席（C 侧全返回 -2，Direct2D 在 52.5 分期④），
/// 本文件 extern 照常声明：wasm/无 Windows 链接路径上没人调用它们，
/// 与既有 extern 同一条不link不炸的账。

///|
/// 画布句柄：C 侧上下文指针的包装。`Invalid`/`Closed` 是构造时的哨兵，
/// 调用方拿到的要么是活的，要么 raise（§33：可疑输入在唯一一处拦住）。
pub(all) struct Canvas {
  ptr : Int64 // 0 = 无效（create 失败）
}

///|
extern "c" fn c_canvas_create() -> Int64 = "moonui_canvas_create"

///|
extern "c" fn c_canvas_destroy(c : Int64) -> Int32 = "moonui_canvas_destroy"

///|
extern "c" fn c_canvas_begin_frame(c : Int64, w : Int32, h : Int32) -> Int32 = "moonui_canvas_begin_frame"

///|
extern "c" fn c_canvas_end_frame(c : Int64) -> Int32 = "moonui_canvas_end_frame"

///|
extern "c" fn c_canvas_save(c : Int64) -> Int32 = "moonui_canvas_save"

///|
extern "c" fn c_canvas_restore(c : Int64) -> Int32 = "moonui_canvas_restore"

///|
extern "c" fn c_canvas_clip_rect(
  c : Int64,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
) -> Int32 = "moonui_canvas_clip_rect"

///|
extern "c" fn c_canvas_translate(c : Int64, dx : Int32, dy : Int32) -> Int32 = "moonui_canvas_translate"

///|
extern "c" fn c_canvas_fill_rect(
  c : Int64,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
  radius_permille : Int32,
  rgb : Int64,
  alpha : Int32,
) -> Int32 = "moonui_canvas_fill_rect"

///|
extern "c" fn c_canvas_blur_region(
  c : Int64,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
  radius_permille : Int32,
) -> Int32 = "moonui_canvas_blur_region"

///|
extern "c" fn c_canvas_stroke_rect(
  c : Int64,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
  radius_permille : Int32,
  rgb : Int64,
  width_permille : Int32,
) -> Int32 = "moonui_canvas_stroke_rect"

///|
#borrow(stops)
extern "c" fn c_canvas_fill_linear(
  c : Int64,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
  stops : Bytes, // n × 16 字节：[int64 pos_permille][int64 rgb]
  n : Int32,
) -> Int32 = "moonui_canvas_fill_linear"

///|
extern "c" fn c_canvas_shadow(
  c : Int64,
  dx : Int32,
  dy : Int32,
  blur_permille : Int32,
  rgb : Int64,
) -> Int32 = "moonui_canvas_shadow"

///|
extern "c" fn c_canvas_line(
  c : Int64,
  x0 : Int32,
  y0 : Int32,
  x1 : Int32,
  y1 : Int32,
  rgb : Int64,
  width_permille : Int32,
) -> Int32 = "moonui_canvas_line"

///|
#borrow(text)
extern "c" fn c_canvas_measure_text(
  text : Bytes,
  len : Int32,
  font_permille : Int32,
  weight : Int32,
) -> Int64 = "moonui_canvas_measure_text"

///|
#borrow(text)
extern "c" fn c_canvas_draw_text(
  c : Int64,
  text : Bytes,
  len : Int32,
  x : Int32,
  y : Int32,
  font_permille : Int32,
  weight : Int32,
  rgb : Int64,
) -> Int32 = "moonui_canvas_draw_text"

///|
#borrow(bytes)
extern "c" fn c_canvas_draw_image(
  c : Int64,
  bytes : Bytes,
  len : Int32,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
) -> Int32 = "moonui_canvas_draw_image"

///|
extern "c" fn c_canvas_read_pixel(c : Int64, x : Int32, y : Int32) -> Int64 = "moonui_canvas_read_pixel"

///|
extern "c" fn c_canvas_attach_window(c : Int64, window : Int64) -> Int32 = "moonui_canvas_attach_window"

///|
extern "c" fn c_canvas_present(c : Int64) -> Int32 = "moonui_canvas_present"

///|
fn canvas_check(rc : Int32, what : String) -> Unit raise @moonui.UiError {
  if rc != 0 {
    raise @moonui.OperationFailed("画布 \{what} 失败（rc=\{rc}）")
  }
}

///|
/// 开一张画布。平台缺席/分配失败 raise（§33）。
pub fn canvas_create() -> Canvas raise @moonui.UiError {
  let p = c_canvas_create()
  if p == 0L {
    raise @moonui.OperationFailed(
      "画布创建失败（平台缺席或分配失败）",
    )
  }
  { ptr: p, }
}

///|
pub fn canvas_destroy(c : Canvas) -> Unit raise @moonui.UiError {
  canvas_check(c_canvas_destroy(c.ptr), "销毁")
}

///|
/// 开一帧：w/h 是物理像素。上一帧自动作废（换新位图）。
pub fn canvas_begin_frame(
  c : Canvas,
  w : Int32,
  h : Int32,
) -> Unit raise @moonui.UiError {
  canvas_check(c_canvas_begin_frame(c.ptr, w, h), "开帧")
}

///|
pub fn canvas_end_frame(c : Canvas) -> Unit raise @moonui.UiError {
  canvas_check(c_canvas_end_frame(c.ptr), "收帧")
}

///|
pub fn canvas_save(c : Canvas) -> Unit raise @moonui.UiError {
  canvas_check(c_canvas_save(c.ptr), "save")
}

///|
pub fn canvas_restore(c : Canvas) -> Unit raise @moonui.UiError {
  canvas_check(c_canvas_restore(c.ptr), "restore")
}

///|
pub fn canvas_clip_rect(
  c : Canvas,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
) -> Unit raise @moonui.UiError {
  canvas_check(c_canvas_clip_rect(c.ptr, x, y, w, h), "裁剪")
}

///|
pub fn canvas_translate(
  c : Canvas,
  dx : Int32,
  dy : Int32,
) -> Unit raise @moonui.UiError {
  canvas_check(c_canvas_translate(c.ptr, dx, dy), "平移")
}

///|
/// 圆角矩形填充。radius 是逻辑像素（这里换千分比过 FFI，与皮肤通道同口径）。
/// alpha 0..255（默认 255 不透明；T98② 毛玻璃起半透底走这条）。
pub fn canvas_fill_rect(
  c : Canvas,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
  radius~ : Double = 0.0,
  rgb~ : Int32,
  alpha~ : Int32 = 255,
) -> Unit raise @moonui.UiError {
  canvas_check(
    c_canvas_fill_rect(
      c.ptr,
      x,
      y,
      w,
      h,
      (radius * 1000.0).to_int(),
      rgb.to_int64(),
      alpha,
    ),
    "填充",
  )
}

///|
/// 区域模糊（T98② 毛玻璃的"毛"）：对位图里 (x,y,w,h) 那块做原地高斯近似
/// 模糊。radius 是逻辑像素（换千分比过 FFI）。模糊的是"栏后面已画上去的
/// 内容"——毛玻璃配方先调它再叠半透底。radius=0 是恒等。
pub fn canvas_blur_region(
  c : Canvas,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
  radius~ : Double,
) -> Unit raise @moonui.UiError {
  canvas_check(
    c_canvas_blur_region(c.ptr, x, y, w, h, (radius * 1000.0).to_int()),
    "区域模糊",
  )
}

///|
/// 圆角矩形描边。width 是描边宽（逻辑像素）。
pub fn canvas_stroke_rect(
  c : Canvas,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
  radius~ : Double = 0.0,
  width~ : Double = 1.0,
  rgb~ : Int32,
) -> Unit raise @moonui.UiError {
  canvas_check(
    c_canvas_stroke_rect(
      c.ptr,
      x,
      y,
      w,
      h,
      (radius * 1000.0).to_int(),
      rgb.to_int64(),
      (width * 1000.0).to_int(),
    ),
    "描边",
  )
}

///|
/// 垂直线性渐变（上→下）。stops 是 (位置0..1, 0xRRGGBB) 数组，位置按
/// 千分比打包。
pub fn canvas_fill_linear(
  c : Canvas,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
  stops : Array[(Double, Int32)],
) -> Unit raise @moonui.UiError {
  let packed = Bytes::makei(stops.length() * 16, fn(i) {
    let stop = i / 16
    let off = i % 16
    let (pos, rgb) = stops[stop]
    let v = if off < 8 { (pos * 1000.0).to_int64() } else { rgb.to_int64() }
    ((v >> (8 * (off % 8))) & 0xFF).to_byte()
  })
  canvas_check(
    c_canvas_fill_linear(c.ptr, x, y, w, h, packed, stops.length()),
    "渐变",
  )
}

///|
/// 投影状态：设了之后所有填充带影，直到 restore 或 blur=0 清零。
pub fn canvas_shadow(
  c : Canvas,
  dx : Int32,
  dy : Int32,
  blur~ : Double,
  rgb~ : Int32,
) -> Unit raise @moonui.UiError {
  canvas_check(
    c_canvas_shadow(c.ptr, dx, dy, (blur * 1000.0).to_int(), rgb.to_int64()),
    "投影",
  )
}

///|
pub fn canvas_line(
  c : Canvas,
  x0 : Int32,
  y0 : Int32,
  x1 : Int32,
  y1 : Int32,
  width~ : Double = 1.0,
  rgb~ : Int32,
) -> Unit raise @moonui.UiError {
  canvas_check(
    c_canvas_line(
      c.ptr,
      x0,
      y0,
      x1,
      y1,
      rgb.to_int64(),
      (width * 1000.0).to_int(),
    ),
    "画线",
  )
}

///|
/// 文本度量（物理像素）：返回 (宽, 高)。
pub fn canvas_measure_text(
  text : String,
  size : Double,
  bold~ : Bool = false,
) -> (Double, Double) raise @moonui.UiError {
  let t = @utf8.encode(text)
  let packed = c_canvas_measure_text(
    t,
    t.length(),
    (size * 1000.0).to_int(),
    if bold {
      2
    } else {
      0
    },
  )
  if packed < 0L {
    raise @moonui.OperationFailed("画布文本度量失败")
  }
  let w = (packed >> 32).to_double()
  let h = (packed & 0xFFFFFFFFL).to_double()
  (w, h)
}

///|
/// 文本绘制（y 是顶边，物理像素）。
pub fn canvas_draw_text(
  c : Canvas,
  text : String,
  x : Int32,
  y : Int32,
  size : Double,
  bold~ : Bool = false,
  rgb~ : Int32,
) -> Unit raise @moonui.UiError {
  let t = @utf8.encode(text)
  canvas_check(
    c_canvas_draw_text(
      c.ptr,
      t,
      t.length(),
      x,
      y,
      (size * 1000.0).to_int(),
      if bold {
        2
      } else {
        0
      },
      rgb.to_int64(),
    ),
    "画字",
  )
}

///|
/// 位图绘制（bytes 是平台认得的图像编码，沿 T86⑤ 约定）。
pub fn canvas_draw_image(
  c : Canvas,
  bytes : Bytes,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
) -> Unit raise @moonui.UiError {
  canvas_check(
    c_canvas_draw_image(c.ptr, bytes, bytes.length(), x, y, w, h),
    "贴图",
  )
}

///|
/// 读像素（测试断言用）：返回 0xRRGGBB；越界/全透明 raise。
pub fn canvas_read_pixel(
  c : Canvas,
  x : Int32,
  y : Int32,
) -> Int32 raise @moonui.UiError {
  let v = c_canvas_read_pixel(c.ptr, x, y)
  if v < 0L {
    raise @moonui.OperationFailed("画布读像素越界或全透明")
  }
  v.to_int()
}

///|
/// 把画布挂到一只原生窗口上（窗口句柄来自 NativeBackend 的 create_window）。
/// 分期②的上屏账：present 把当前帧位图贴进窗口 contentView 的 layer。
pub fn canvas_attach_window(
  c : Canvas,
  window : Int64,
) -> Unit raise @moonui.UiError {
  canvas_check(c_canvas_attach_window(c.ptr, window), "挂窗")
}

///|
/// 把当前帧上屏（一次一贴；重画靠再一轮 begin_frame）。
pub fn canvas_present(c : Canvas) -> Unit raise @moonui.UiError {
  canvas_check(c_canvas_present(c.ptr), "上屏")
}
