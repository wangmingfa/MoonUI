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
/// 建一只 HUD 窗。坐标与尺寸都是**物理像素**、屏幕坐标（左上原点）。
/// 失败时返回 `None`。
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
/// 挪到新的屏幕坐标（物理像素）。
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
