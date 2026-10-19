///|
/// 自绘后端（设计文档 §52 的 Backend #3，macOS 半）：窗口、事件循环、
/// 系统服务（剪贴板/对话框/菜单/托盘）全部复用原生后端（NativeBackend，
/// Backend #2）——自绘后端不碰窗口，只接管"控件"那一半：
///
///   - `create_widget` 不再给 C 造 NSView，而是开一条记账（`CwRec`）；
///     Core 推来的 bounds/样式/文案/值全部记账，句柄是记账表的索引。
///   - 任何记账变动都把全窗标脏；`poll_event` 先把脏窗整帧重画进挂窗
///     画布（canvas-common 的绘制配方 + CanvasPainter 换算），present
///     上屏，再让原生后端泵事件。一帧一贴，§52.4 的帧循环账。
///
/// 第一刀（分期②收尾）只保证"画得出来"：四种 kind 有真配方（Panel/Label/
/// Button/Slider），其余 kind 画占位圆角面；鼠标事件仍由原生后端报——
/// 自绘控件没有原生对象，C 侧只会报到窗口，命中测试（自绘半的
/// `NativeBackend::handle_of_ptr` 对应物）在下一刀接上。
pub struct CanvasBackend {
  mut inner : @native-common.NativeBackend
  /// 记账表：index → 记录；free 复用死槽（HandleTable 的 id 复用同款思想，
  /// 但这里句柄的 id 就是索引，generation 归下面的句柄表管）
  mut recs : Array[CwRec?]
  mut free : Array[Int32]
  /// 句柄表：NativeHandle(id, generation) ↔ 记账索引。ptr 里存的是
  /// 索引 + 基数，与 native-common 的真指针（堆地址）永不撞——基数取
  /// 0x7F0000000000，远在任何堆区间之外。
  table : @moonui.HandleTable
  /// 每窗绘制账：paint order（Core 推的整份）+ 挂窗画布 + 脏位
  mut windows : Array[CwWin]
  /// 皮肤底账：重画时未显式给样式字段的控件吃这份底的对应字段
  mut theme_base : @moonui.Style
  /// 自绘鼠标闭包自己的事件队列（poll_event 先于 inner 的队列收）
  mut queue : Array[@moonui.Event]
  /// 自绘鼠标闭包装上过没有（进程槽位一份，首窗创建时顶掉 inner 的）
  mut mouse_installed : Bool
  /// 左键按下落在（target, 窗口下标）上——抬起同点才算一次 Click
  mut press : (@moonui.NativeHandle, Int32)?
  /// 最近一次 MouseMove 命中的记账句柄（悬停态的画账；None = 悬在空白）
  mut hover : @moonui.NativeHandle?
}

///|
/// 自绘控件的一条记账。Core 推什么就记什么；重画时配方按 kind 挑着吃。
struct CwRec {
  kind : @moonui.WidgetKind
  mut text : String
  mut bounds : @moonui.LogicalRect
  mut visible : Bool
  mut enabled : Bool
  mut bg : Int32? // 0xRRGGBB
  /// 底色 alpha（0..255，T98② 毛玻璃起）：bg 只存 0xRRGGBB，alpha 单独记
  /// （pack_color 丢 alpha 的旧账，这里补一条）。None = 不透明（255）。
  mut bg_alpha : Int32?
  /// 线性渐变底（§15）：Some 时 Panel 走 `paint_gradient_panel`（垂直
  /// fill_linear / 水平条带），优先于纯色 bg 绘制。None = 纯色/毛玻璃路径。
  mut bg_gradient : @moonui.Gradient?
  mut fg : Int32?
  mut radius : Double?
  /// 毛玻璃半径（逻辑像素，T98②）：Some 时 Panel 走毛玻璃配方（先模糊
  /// 栏后内容再叠半透底），None 是普通面板。
  mut backdrop_blur : Double?
  mut font_size : Double?
  mut bold : Bool
  mut checked : Bool
  mut min : Int32
  mut max : Int32
  mut value : Int32
  mut selected : Int32
  mut icon : String
  /// 图像源（set_image_bytes 的原话，0xRRGGBB 通道外的唯一字节账）
  mut image : Bytes
  /// 最近认领祖先的记账索引（`attach_widget_to` 的 container，T98② 滚动偏移起）：
  /// Core 把 Scroll 文档区子树按**文档坐标**推给后端（减去最近 Scroll 的视口原点），
  /// 原生后端对（NSScrollView 的 documentView 原点=视口左上），画布按**窗口绝对坐标**
  /// 画，得沿这条链把每层 Scroll 的视口原点加回去。Panel 也认领子树但不贡献原点
  /// （只有 Scroll 加），链要穿过它才能到外层 Scroll。None = 直接挂窗（无认领祖先）。
  /// 字段随记账生死（destroy 置 None），不跨树留旧链。
  mut scroll_parent : Int32?
}

///|
/// 每窗绘制账：order 是 Core `set_paint_order` 推的整份句柄序，canvas
/// 惰性建（第一次重画才挂窗），dirty 在 poll_event 开头收。
struct CwWin {
  handle : @moonui.NativeHandle
  mut order : Array[@moonui.NativeHandle]
  mut canvas : @native-common.Canvas?
  mut dirty : Bool
}

///|
/// 记账句柄的 ptr 基数：与真堆指针（native-common 那张表）分道扬镳的
/// 车道。指针是 0x7F0000000000 + 索引，越界即坏账。
let rec_base = 0x7F0000000000L

///|
pub fn CanvasBackend::new() -> CanvasBackend {
  CanvasBackend::{
    inner: @native-common.NativeBackend::new(),
    recs: [],
    free: [],
    table: @moonui.HandleTable::new(),
    windows: [],
    theme_base: @moonui.Style::empty(),
    queue: [],
    mouse_installed: false,
    press: None,
    hover: None,
  }
}

///|
/// 记账 → 句柄（进表拿 generation）。槽位索引复用 free 表。
fn CanvasBackend::alloc(
  self : CanvasBackend,
  kind : @moonui.WidgetKind,
  text : String,
) -> @moonui.NativeHandle {
  let idx : Int32 = match self.free.pop() {
    Some(i) => i
    None => {
      self.recs.push(None)
      self.recs.length() - 1
    }
  }
  let rec = CwRec::{
    kind,
    text,
    bounds: @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(0.0, 0.0),
    ),
    visible: true,
    enabled: true,
    bg: None,
    bg_alpha: None,
    bg_gradient: None,
    fg: None,
    radius: None,
    backdrop_blur: None,
    font_size: None,
    bold: false,
    checked: false,
    min: 0,
    max: 100,
    value: 0,
    selected: 0,
    icon: "",
    image: b"",
    scroll_parent: None,
  }
  self.recs[idx] = Some(rec)
  self.table.register(@moonui.NativePtr(rec_base + idx.to_int64()))
}

///|
/// 句柄 → 记账索引。坏账（过期/外乡句柄）raise，§33 在唯一一处拦。
fn CanvasBackend::idx_of(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
) -> Int32 raise @moonui.UiError {
  let ptr = self.table.resolve(h).0
  if ptr < rec_base {
    raise @moonui.InvalidHandle
  }
  let idx = (ptr - rec_base).to_int()
  if idx < 0 || idx >= self.recs.length() {
    raise @moonui.InvalidHandle
  }
  match self.recs[idx] {
    Some(_) => idx
    None => raise @moonui.InvalidHandle
  }
}

///|
/// 句柄 → 记录的只读捷径（写走 rec_mut）。
fn CanvasBackend::rec_of(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
) -> CwRec raise @moonui.UiError {
  let idx = self.idx_of(h)
  match self.recs[idx] {
    Some(r) => r
    None => raise @moonui.InvalidHandle
  }
}

///|
/// 滚动文档区 → 窗口绝对坐标的平移量（T98② 滚动偏移）。Core 把 Scroll 文档区
/// 子树按文档坐标推给后端（减去最近 Scroll 的视口原点），画布按窗口绝对坐标画，
/// 得沿 `scroll_parent` 链把每层 Scroll 的视口原点加回去。
///
/// 链上每个节点存的是它**相对最近认领祖先**的坐标：Scroll 节点的原点相对它自己的
/// 外层 Scroll（嵌套时），Panel 节点的原点相对窗口（Panel 不贡献原点，只透传链）。
/// 所以从本节点往上走，把链上每个 Scroll 的 `bounds.origin` 累加，就是本节点文档
/// 坐标到窗口绝对坐标的总平移。非 Scroll 节点（Panel/叶子）自身原点不累加——
/// 只有"文档区原点"这一层要补，叶子在文档区里的位置 Core 已经算进它的文档坐标了。
///
/// 坏账（链上索引已销毁）截断：加到能加为止，不拖垮整帧。
fn CanvasBackend::scroll_offset(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
) -> @moonui.LogicalPoint {
  let mut ox = 0.0
  let mut oy = 0.0
  let rec0 : CwRec? = Some(self.rec_of(h)) catch { _ => None }
  let mut cur : Int32? = match rec0 {
    Some(r) => r.scroll_parent
    None => None
  }
  while cur is Some(i) {
    match self.recs[i] {
      Some(r) => {
        if r.kind is @moonui.Scroll {
          ox = ox + r.bounds.origin.x
          oy = oy + r.bounds.origin.y
        }
        cur = r.scroll_parent
      }
      None => cur = None
    }
  }
  @moonui.LogicalPoint(ox, oy)
}

///|
/// 滚动视口裁剪矩形（T98② 滚动视口裁剪）：沿 `scroll_parent` 链找**最近**
/// 的 Scroll 节点，返回它的视口矩形（窗口绝对坐标 = 该 Scroll 的 `bounds`）。
/// 文档区子树画完要锁回这块视口里——滚出视口的行不画。
///
/// 与 `scroll_offset` 同一条链、同一个"最近 Scroll"的口径：offset 累加链上
/// **所有** Scroll 的原点（嵌套时逐层补），clip 只取**最近**那一个（内层
/// 视口已经裁过，外层视口更大、裁它没意义）。链上无 Scroll（非滚动内容）
/// 返回 None，原样画不裁。
///
/// 坏账（链上索引已销毁）截断：走到能走为止，找不到就 None。
fn CanvasBackend::scroll_clip_rect(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
) -> @moonui.LogicalRect? {
  let rec0 : CwRec? = Some(self.rec_of(h)) catch { _ => None }
  let mut cur : Int32? = match rec0 {
    Some(r) => r.scroll_parent
    None => None
  }
  while cur is Some(i) {
    match self.recs[i] {
      Some(r) => {
        if r.kind is @moonui.Scroll {
          return Some(r.bounds)
        }
        cur = r.scroll_parent
      }
      None => cur = None
    }
  }
  None
}

///|
/// 全窗标脏。第一刀不追"哪只控件属于哪扇窗"的账——窗口数是一两只，
/// 整帧重画的成本可控，先把"画得出来"立住；局部脏区是优化账，不是正确性账。
fn CanvasBackend::mark_dirty(self : CanvasBackend) -> Unit {
  for w in self.windows {
    w.dirty = true
  }
}

///|
/// 找一只窗口在绘制账里的下标（结构体是值语义，改字段必须回数组原位，
/// 所以这里给下标不给副本）。外乡句柄（原生窗口）认得出：windows 里存的
/// 都是 create_window 转发回来的句柄。
fn CanvasBackend::win_idx(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
) -> Int32? {
  for i = 0; i < self.windows.length(); i = i + 1 {
    if self.windows[i].handle == h {
      return Some(i)
    }
  }
  None
}

///|
/// 测试口：取一只窗口的挂窗画布（收帧后读像素断言用）。窗口没有画布
/// （还没收过帧）就 raise。
pub fn CanvasBackend::window_canvas(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
) -> @native-common.Canvas raise @moonui.UiError {
  match self.win_idx(h) {
    Some(i) =>
      match self.windows[i].canvas {
        Some(c) => c
        None => raise @moonui.OperationFailed("这窗还没收过帧")
      }
    None => raise @moonui.OperationFailed("不是自绘后端的窗口")
  }
}

///|
/// 测试用后端：内嵌的原生后端空转最多 `budget_ms` 毫秒就不再等事件
/// （NativeBackend::for_testing 同款）——测试里 poll_event 才会返回。
pub fn CanvasBackend::for_testing(budget_ms : Int32) -> CanvasBackend {
  let b = CanvasBackend::new()
  b.inner = @native-common.NativeBackend::for_testing(budget_ms)
  b
}
