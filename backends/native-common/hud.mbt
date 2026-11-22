///|
/// HUD 置顶窗（`T343`）：`@moonui.HudMetrics` 的原生显示端。
///
/// 这一层在 `backends/native-common` 而不是 `packages/moonui`：它带 extern
/// C 调用，跟着真后端走（该目录不在 core/wasm 门禁清单里）。Core 侧的
/// 指标采集与监听住在 `packages/moonui/hud.mbt`，两边靠 `HudMetrics` 值对接。
///
/// 平台口径：Windows 是真 layered 置顶窗；mac/linux 第一期是 stub——
/// `create` 返回 0，包装层如实报"未实现"，不假装有窗。

///|
extern "c" fn c_hud_create(x : Int32, y : Int32, w : Int32, h : Int32) -> Int64 = "moonui_native_hud_create"

///|
/// `T349`：应用内档。`owner` 是宿主窗口的原生句柄（`Window::handle()`），
/// HUD 变成它的 owned window。
extern "c" fn c_hud_create_attached(
  owner : Int64,
  corner : Int32,
  dx : Int32,
  dy : Int32,
  w : Int32,
  h : Int32,
) -> Int64 = "moonui_native_hud_create_attached"

///|
#borrow(text)
extern "c" fn c_hud_update(hud : Int64, text : Bytes, len : Int32) -> Int32 = "moonui_native_hud_update"

///|
extern "c" fn c_hud_move(hud : Int64, x : Int32, y : Int32) -> Int32 = "moonui_native_hud_move"

///|
extern "c" fn c_hud_close(hud : Int64) -> Int32 = "moonui_native_hud_close"

///|
/// HUD 窗句柄。`None` 只在平台不支持/创建失败时出现，之后所有方法空转。
pub struct NativeHud {
  ptr : Int64
}

///|
/// 建一只**全局** HUD 窗：独立、鼠标穿透、置顶，浮在所有应用之上。
/// 坐标与尺寸都是**物理像素**、屏幕坐标（左上原点）。失败时返回 `None`。
///
/// 想让它只属于某个应用窗口（跟着宿主走、宿主最小化一起隐藏、被别的应用
/// 盖住），用 `NativeHud::create_in_window`（`T349`）。
pub fn NativeHud::create(
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
) -> NativeHud? {
  let p = c_hud_create(x, y, w, h)
  if p == 0 {
    None
  } else {
    Some(NativeHud::{ ptr: p, })
  }
}

///|
/// HUD 在宿主窗口客户区上的锚点（`T349`）。九宫格顺序与 C 侧 `corner` 同序：
/// 0=左上、1=上中、2=右上、3=左中、4=正中、5=右中、6=左下、7=下中、8=右下。
pub(all) enum HudCorner {
  TopLeft
  TopCenter
  TopRight
  LeftCenter
  Center
  RightCenter
  BottomLeft
  BottomCenter
  BottomRight
}

///|
fn HudCorner::code(self : HudCorner) -> Int32 {
  match self {
    TopLeft => 0
    TopCenter => 1
    TopRight => 2
    LeftCenter => 3
    Center => 4
    RightCenter => 5
    BottomLeft => 6
    BottomCenter => 7
    BottomRight => 8
  }
}

///|
/// 建一只**应用内**的 HUD 窗（`T349`）：贴在 `owner` 客户区的指定角上，
/// 随宿主窗口移动/缩放自己跟随，宿主最小化时一起隐藏，切到别的应用时被
/// 盖住（不再像全局档那样浮在所有应用之上）。
///
/// `dx`/`dy` 与 `w`/`h` 都是**物理像素**，与 `NativeHud::create` 的坐标口径
/// 一致。`owner` 句柄失效或平台未实现时返回 `None`。
pub fn NativeHud::create_in_window(
  owner : @moonui.NativeHandle,
  corner : HudCorner,
  dx : Int32,
  dy : Int32,
  w : Int32,
  h : Int32,
) -> NativeHud? {
  let ptr = handles.resolve(owner).0 catch { _ => return None }
  let p = c_hud_create_attached(ptr, corner.code(), dx, dy, w, h)
  if p == 0 {
    None
  } else {
    Some(NativeHud::{ ptr: p, })
  }
}

///|
/// 更新卡片文本。多行用 `\n` 分隔，每行一条；超出行数的行被窗高裁掉。
/// 返回是否真的更新了（平台不支持或未创建时为 `false`）。
pub fn NativeHud::update(self : NativeHud, text : String) -> Bool {
  if self.ptr == 0 {
    return false
  }
  let bytes = @utf8.encode(text)
  c_hud_update(self.ptr, bytes, bytes.length()) == 0
}

///|
/// 把一份指标快照渲染成默认两行文本（FPS / 帧耗时），外加调用方给的自定义行。
/// 返回 `NativeHud::update` 的结果。
pub fn NativeHud::show_metrics(
  self : NativeHud,
  m : @moonui.HudMetrics,
  extra : Array[String],
) -> Bool {
  let fps = fixed1(m.fps)
  let ms = fixed1(m.frame_ms)
  let mut lines = "FPS  \{fps}\nFrame  \{ms} ms\nCmds  \{m.draw_cmds}"
  for e in extra {
    lines = lines + "\n" + e
  }
  self.update(lines)
}

///|
/// 挪位置。全局档传新的屏幕坐标；应用内档（`create_in_window`）传的是
/// **相对锚点的新偏移**，之后宿主再移动也仍然跟着。
pub fn NativeHud::move_to(self : NativeHud, x : Int32, y : Int32) -> Bool {
  self.ptr != 0 && c_hud_move(self.ptr, x, y) == 0
}

///|
/// 关窗。幂等：关过之后再关是空操作。
pub fn NativeHud::close(self : NativeHud) -> Unit {
  if self.ptr != 0 {
    let _ = c_hud_close(self.ptr)
  }
}

///|
/// 一位小数，HUD 读数统一口径。负数/FPS 初始 0.0 直接出 "0.0"。
fn fixed1(v : Double) -> String {
  let neg = v < 0.0
  let x = if neg { -v } else { v }
  let scaled = (x * 10.0 + 0.5).to_int()
  let whole = scaled / 10
  let frac = scaled % 10
  if neg && scaled > 0 {
    "-\{whole}.\{frac}"
  } else {
    "\{whole}.\{frac}"
  }
}
