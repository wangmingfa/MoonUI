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
/// 渲染后端选择（T99 B 方案：2D 与 Metal 共存的可切换后端）。
/// 枚举值跨平台中性；mac 上 `Auto` 解析为 `CoreGraphics`（默认、§52 严格路径），
/// `Metal` 在 P0 尚未实现，请求时回退 CG 并告警。Windows 端无 Metal。
///
/// `pub(all)`（`T396`）：应用要能在代码里 `set_render_backend(~backend: Metal)`，
/// 需要跨包构造变体——`pub enum` 的变体对包外是只读的（只能经
/// `render_backend_of_code` 拿值），`pub(all)` 才放行构造。严格放宽，无既有破坏。
pub(all) enum RenderBackend {
  Auto
  CoreGraphics
  Metal
}

///|
/// 枚举 ↔ 与 C 侧 `MoonuiRenderBackend` 对齐的整型码（Auto=0 / CG=1 / Metal=2）。
pub fn RenderBackend::to_code(self : RenderBackend) -> Int32 {
  match self {
    Auto => 0
    CoreGraphics => 1
    Metal => 2
  }
}

///|
/// 整型码 → 枚举（未知码回落 CoreGraphics，与 C 侧 resolve 的默认一致）。
pub fn render_backend_of_code(code : Int32) -> RenderBackend {
  match code {
    0 => Auto
    2 => Metal
    _ => CoreGraphics
  }
}

///|
extern "c" fn c_canvas_create() -> Int64 = "moonui_canvas_create"

///|
extern "c" fn c_canvas_create_with_backend(backend : Int32) -> Int64 = "moonui_canvas_create_with_backend"

///|
extern "c" fn c_canvas_set_backend(c : Int64, backend : Int32) -> Int32 = "moonui_canvas_set_backend"

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
extern "c" fn c_canvas_stroke_arc(
  c : Int64,
  cx : Int32,
  cy : Int32,
  r : Int32,
  start_deg_permille : Int32,
  sweep_deg_permille : Int32,
  rgb : Int64,
  width_permille : Int32,
) -> Int32 = "moonui_canvas_stroke_arc"

///|
#borrow(points)
extern "c" fn c_canvas_fill_polygon(
  c : Int64,
  points : Bytes, // n × 8 字节：[int32 x][int32 y]（物理像素）
  n : Int32,
  rgb : Int64,
  alpha : Int32,
) -> Int32 = "moonui_canvas_fill_polygon"

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
/// 把当前帧贴到**指定视图**的 layer 上（`T101`）：自定义绘制面的位图不铺满
/// 整窗，只属于它自己那只 NSView。
extern "c" fn c_canvas_present_view(c : Int64, view : Int64) -> Int32 = "moonui_canvas_present_view"

///|
/// 24 个 `canvas_*` 封装共用的返回码 → `UiError` 翻译。算式本体在
/// `@native-abi.check_rc`（`T230`，纯函数、进 wasm 门）；这里把 "画布 动作"
/// 拼成完整上下文递过去，最终错误文本与搬来之前逐字一致
/// （"画布 填充 失败（rc=-1）"）。0 是唯一成功值，正 rc 同样算失败。
fn canvas_check(rc : Int32, what : String) -> Unit raise @moonui.UiError {
  @native-abi.check_rc(rc, "画布 \{what}")
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
/// 测试专用：绕过 env resolve，强制指定后端创建画布（验证 Metal 路径用）。
/// `backend` 用 `RenderBackend::to_code()` 的整型码（Auto=0 / CG=1 / Metal=2）。
pub fn canvas_create_with_backend(
  backend : Int32,
) -> Canvas raise @moonui.UiError {
  let p = c_canvas_create_with_backend(backend)
  if p == 0L {
    raise @moonui.OperationFailed(
      "画布创建失败（平台缺席或分配失败）",
    )
  }
  { ptr: p, }
}

///|
/// 运行时切换渲染后端（`T396`）：`backend` 是目标；`Auto` 表示回到 env/偏好
/// 文件的默认解析（mac 上 CoreGraphics）。**下一帧起生效**——调用方须在两帧
/// 之间调（自绘后端的 `CanvasBackend::set_render_backend` 就是这种用法）。
/// 两路共享同一块位图与上屏路径，切换只换"谁往里画"；无 GPU 请求 Metal
/// 回退 CoreGraphics。Windows/Linux 只有一种光栅后端，no-op 成功。
pub fn canvas_set_backend(
  c : Canvas,
  backend : RenderBackend,
) -> Unit raise @moonui.UiError {
  canvas_check(
    c_canvas_set_backend(c.ptr, backend.to_code()),
    "切换渲染后端",
  )
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
/// 把当前帧位图贴到给定视图上（`T101` 的自定义绘制面）：视图转 layer-backed，
/// 位图成为它的 `layer.contents`。`view` 是原生视图指针（调用方从句柄反查）。
pub fn canvas_present_view(
  c : Canvas,
  view : Int64,
) -> Unit raise @moonui.UiError {
  canvas_check(c_canvas_present_view(c.ptr, view), "贴图到视图")
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
/// 圆弧描边（物理像素）。角度是**度 × 1000**：0° = 三点钟、顺时针为正，
/// `-90` 是十二点；扫过角为负是逆时针，`|扫过角| ≥ 360` 画整圈。
pub fn canvas_stroke_arc(
  c : Canvas,
  cx : Int32,
  cy : Int32,
  r : Int32,
  start_deg~ : Double,
  sweep_deg~ : Double,
  width~ : Double,
  rgb~ : Int32,
) -> Unit raise @moonui.UiError {
  canvas_check(
    c_canvas_stroke_arc(
      c.ptr,
      cx,
      cy,
      r,
      (start_deg * 1000.0).to_int(),
      (sweep_deg * 1000.0).to_int(),
      rgb.to_int64(),
      (width * 1000.0).to_int(),
    ),
    "画弧",
  )
}

///|
/// 闭合多边形填充（物理像素）。points 是首尾相连的轮廓顶点（最后一点自动
/// 连回第一点）；少于 3 点画不出面积，返回 -1。
///
/// 顶点打包成 n × 8 字节（每点两个 int32：x、y，小端）——与 `fill_linear`
/// 打包 stops 同一条路：MoonBit 侧把数组摊平成一块 `Bytes` 再递指针 + 长度，
/// C 侧按定长读。
pub fn canvas_fill_polygon(
  c : Canvas,
  points : Array[(Int32, Int32)],
  rgb~ : Int32,
  alpha~ : Int32 = 255,
) -> Unit raise @moonui.UiError {
  let n = points.length()
  if n < 3 {
    raise @moonui.OperationFailed("画布多边形填充：顶点不足三个")
  }
  let packed = Bytes::makei(n * 8, fn(i) {
    let pt = i / 8
    let off = i % 8
    let (px, py) = points[pt]
    let v = if off < 4 { px.to_int64() } else { py.to_int64() }
    ((v >> (8 * (off % 4))) & 0xFF).to_byte()
  })
  canvas_check(
    c_canvas_fill_polygon(c.ptr, packed, n, rgb.to_int64(), alpha),
    "多边形填充",
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
  // 拆包算式搬到 `@native-abi.unpack_measure_text`（`T230`）：低位用无符号
  // mask、高位用算术右移，和 `unpack2` 的"低位也当有符号"不是同一口径，
  // 两条都由 wasm 门的判据钉着。行为逐字不变。
  @native-abi.unpack_measure_text(packed)
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

///|
extern "c" fn c_canvas_ime_begin(
  window : Int64,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
  font_px : Int32,
) -> Int32 = "moonui_canvas_ime_begin"

///|
extern "c" fn c_canvas_ime_move(
  window : Int64,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
) -> Int32 = "moonui_canvas_ime_move"

///|
extern "c" fn c_canvas_ime_end(window : Int64) -> Unit = "moonui_canvas_ime_end"

///|
#borrow(bytes)
extern "c" fn c_canvas_ime_set_state(
  window : Int64,
  bytes : Bytes,
  len : Int32,
  caret : Int32,
) -> Int32 = "moonui_canvas_ime_set_state"

///|
extern "c" fn c_canvas_ime_text(window : Int64) -> Bytes = "moonui_canvas_ime_text"

///|
extern "c" fn c_canvas_ime_caret(window : Int64) -> Int32 = "moonui_canvas_ime_caret"

///|
extern "c" fn c_canvas_ime_set_selection(
  window : Int64,
  caret : Int32,
  sel : Int32,
) -> Int32 = "moonui_canvas_ime_set_selection"

///|
extern "c" fn c_canvas_ime_marked(window : Int64) -> Bytes = "moonui_canvas_ime_marked"

///|
#borrow(bytes)
extern "c" fn c_canvas_ime_compose_in_window(
  window : Int64,
  bytes : Bytes,
  len : Int32,
) -> Int32 = "moonui_canvas_ime_compose_in_window"

///|
#borrow(bytes)
extern "c" fn c_canvas_ime_commit_in_window(
  window : Int64,
  bytes : Bytes,
  len : Int32,
) -> Int32 = "moonui_canvas_ime_commit_in_window"

///|
/// 画布输入法代理（`T375`）：在窗口 contentView 上挂一只隐形 NSTextView 并
/// 立为 first responder。矩形是客户区物理像素、左上原点（与 canvas_* 同尺）。
/// 返回码原样交给调用方：0 成功、-1 窗口无效、-4 抢焦点失败——这些不是
/// `UiError` 能表达的分支（抢不到焦点要退回裸键编辑，不该炸整窗）。
pub fn canvas_ime_begin(
  window : Int64,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
  font_px : Int32,
) -> Int32 {
  c_canvas_ime_begin(window, x, y, w, h, font_px)
}

///|
/// 只挪代理框（滚动/尺寸变化时跟光标），返回码同 `canvas_ime_begin`。
pub fn canvas_ime_move(
  window : Int64,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
) -> Int32 {
  c_canvas_ime_move(window, x, y, w, h)
}

///|
/// 让代理 resign 并取消组合；代理本身留到窗口销毁。
pub fn canvas_ime_end(window : Int64) -> Unit {
  c_canvas_ime_end(window)
}

///|
/// 把文本与光标写进代理（程序化同步，不产生用户输入）。
pub fn canvas_ime_set_state(
  window : Int64,
  text : String,
  caret : Int32,
) -> Unit {
  let b = @utf8.encode(text)
  let _ = c_canvas_ime_set_state(window, b, b.length(), caret)
}

///|
/// 读回代理当前文本（UTF-8）；没有代理给空串。
pub fn canvas_ime_text(window : Int64) -> String {
  @utf8.decode_lossy(c_canvas_ime_text(window))
}

///|
/// 读回代理光标（UTF-16 下标，与 MoonBit String 同口径）。
pub fn canvas_ime_caret(window : Int64) -> Int32 {
  c_canvas_ime_caret(window)
}

///|
/// 把本层的选区账推回代理（`T395`/`T393` 已知边界）：`caret` 活动端、`sel`
/// 锚点（UTF-16 下标）。代理只镜像文本与插入点、不管理选区——拖选/点击定位/
/// Shift 扩选后直接打字会插在旧位置而不是选区活动端，这里把 (caret, sel) 设回
/// 代理的 `selectedRange`（caret==sel 即插点）。返回码同 `canvas_ime_begin`。
pub fn canvas_ime_set_selection(
  window : Int64,
  caret : Int32,
  sel : Int32,
) -> Int32 {
  c_canvas_ime_set_selection(window, caret, sel)
}

///|
/// 读回组合中的标记串；不在组合给空串。
pub fn canvas_ime_marked(window : Int64) -> String {
  @utf8.decode_lossy(c_canvas_ime_marked(window))
}

///|
/// 判据替投：真实走 `setMarkedText:`，返回码同 `canvas_ime_begin`。
pub fn canvas_ime_compose_in_window(window : Int64, text : String) -> Int32 {
  let b = @utf8.encode(text)
  c_canvas_ime_compose_in_window(window, b, b.length())
}

///|
/// 判据替投：真实走 `insertText:`（上屏），返回码同 `canvas_ime_begin`。
pub fn canvas_ime_commit_in_window(window : Int64, text : String) -> Int32 {
  let b = @utf8.encode(text)
  c_canvas_ime_commit_in_window(window, b, b.length())
}
