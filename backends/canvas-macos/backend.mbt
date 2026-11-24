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
  /// 自绘鼠标闭包装上过没有（进程槽位一份，首窗创建时顶掉 inner 的）
  mut mouse_installed : Bool
  /// 左键按下落在（target, 窗口下标）上——抬起同点才算一次 Click
  mut press : (@moonui.NativeHandle, Int32)?
  /// 最近一次 MouseMove 命中的记账句柄（悬停态的画账；None = 悬在空白）
  mut hover : @moonui.NativeHandle?
  /// 最大呈现帧率（`set_max_fps`，默认 60）。自绘壳只在应用要画时才画，
  /// 所以这条以"节拍合同"的形式落地：`present_interval_ms()` 是应用排帧的
  /// 权威读数，`flush_dirty` 也按它压到点——早到的脏帧留在脏位上，等槽位
  /// 到了再上屏（不丢帧，只顺延）。
  mut max_fps : Int32
  /// 垂直同步开关（`set_vsync`，默认开）。开 = 节拍向显示器刷新网格取整
  /// （60/120Hz 屏上 90fps 会落到 60fps，因为 90 不是刷新周期的整倍数）；
  /// 关 = 只按 `max_fps` 自由排。mac 上画面本身经 layer 合成、不会撕裂，
  /// 这条管的是"帧什么时候交出去"。
  mut vsync : Bool
  /// 显示器刷新率缓存（`native_display_refresh_hz` 首次查询后记住）。
  /// 0 = 取不到，节拍退回"只按 max_fps 排"。
  mut refresh_hz : Int32
  /// 下一次允许上屏的墙钟时刻（差值形：`now - next_present >= 0` 即到期，
  /// 跨 `2^31` 回绕不受影响）。
  mut next_present : Int32
  /// 已经上过一帧没有：第一帧不节流（否则首帧要等一个完整周期）。
  mut presented : Bool
  /// 帧率节流总开关。`for_testing` 关掉它——测试按调用次数收帧，
  /// 吃墙钟会把连续两次 `poll_event` 的第二帧挡掉。
  mut pacing : Bool
  /// App 经 `set_wait_cap` 推下来的等待上限（-1 = 不限制）；真正转发给
  /// 内层的是它和"下一拍还剩多久"的较小值（见 `forward_wait_cap`）。
  mut app_wait_cap : Int32
  /// 上一次真转发给内层的等待上限（去重：没变就不碰 C）。
  mut pushed_cap : Int32
  /// 键窗探针的测试覆盖（`T371`）：`None` = 每圈问原生 `window_is_key`（真窗）；
  /// `Some(v)` = 判据直接钉住 1/0，不用真窗也能跑激活/失活两态。
  mut key_probe : Int32?
  /// 输入法代理总开关（`T375`，默认开）。生产路径必须开——没有它，中文输入法
  /// 收不到键；`for_testing` 关掉，让 T374 的裸键判据继续跑「没有代理」那条
  /// 回退路径，T375 的判据再显式打开。
  mut ime_proxy : Bool
  /// 自己改写出来的键事件（`T378` 回声门）：改写后的键仍以窗口/焦点为 target，
  /// 形状与原生键事件**一模一样**。单队列下一旦回到 `poll_event` 就分不清，
  /// 再翻译一遍会让 Tab 一次走两步、字符键派发两次。投递时在这里记一笔，
  /// 取到相等的一条就原样交出去，不再进翻译。
  mut key_echo : Array[@moonui.Event]
}

///|
/// 自绘控件的一条记账。Core 推什么就记什么；重画时配方按 kind 挑着吃。
struct CwRec {
  kind : @moonui.WidgetKind
  mut text : String
  /// 占位提示（TextInput / PasswordInput）：字段空时画的灰字；空串 = 没设。
  mut placeholder : String
  mut bounds : @moonui.LogicalRect
  mut visible : Bool
  mut enabled : Bool
  /// 键盘焦点的 opt-in（`T369`）：`Widget::custom(focusable=true)` 经
  /// `set_custom_focusable` 落在这条账上。只有它为真的记账能成为焦点、能被
  /// Tab 环选中；其余控件（Label / 非 opt-in 的自绘面）照旧把键让给窗口。
  /// 可编辑四类（TextInput / PasswordInput / Spinbox / MultilineEntry）不靠
  /// 这一位——它们默认就能取焦（`editable` 判据），否则自绘输入框永远打不了字。
  mut focusable : Bool
  /// 文本光标（`T374`）：字符下标（不是字节/UTF-16），只在 `editable` 记账上
  /// 有意义。0 = 文本最前，`edit_limit()` = 可编辑区间末尾。绘制时只有本窗
  /// 焦点落在这条记账上才画（`frame.mbt` 的 `caret_of`）。
  mut caret : Int32
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
  /// 日期框的日期文本（`set_widget_datetime` 的原话）：格式归 Core/应用，
  /// 自绘只负责画字符串。空串 = 还没设值（配方画占位）。
  mut datetime : String
  /// 单选/下拉的选项文本（Core 经 `append_widget_option` 逐条追加）：自绘
  /// RadioButtons 要把整列文字画出来，ComboBox 本轮不画但先记着。
  options : Array[String]
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
  /// 自定义绘制面（`T101`）最近一次拿到的整份清单；None = 还没画过（或不是
  /// Custom）。重画时整份替换，与原生后端"上一帧不留底"同一条语义。
  mut draw : @moonui.DrawList?
}

///|
/// 每窗绘制账：order 是 Core `set_paint_order` 推的整份句柄序，canvas
/// 惰性建（第一次重画才挂窗），dirty 在 poll_event 开头收。
struct CwWin {
  handle : @moonui.NativeHandle
  mut order : Array[@moonui.NativeHandle]
  mut canvas : @native-common.Canvas?
  mut dirty : Bool
  /// 焦点链（`T369`）：Core 推来的声明序整份快照（`set_focus_chain`）。Tab /
  /// Shift+Tab 在这条链里循环，只停在 `CwRec.focusable` 的记账上。
  mut chain : Array[@moonui.NativeHandle]
  /// 当前键盘焦点（`T369`）：`None` = 焦点在窗口身上，键事件照旧以窗口为
  /// target 交 Core（窗口级订阅仍然工作）。记账销毁/隐藏/收回 focusable 后由
  /// `focus_of` 读账时判失效，不在这里留悬空判断。
  mut focus : @moonui.NativeHandle?
  /// 上一圈这扇窗是不是键窗（`T371`）：失键 → 清焦点补 `Blur`；重新成键且
  /// 焦点为空 → 首焦点落回链里第一只可聚焦的记账（等价于原生后端把 first
  /// responder 交给默认控件）。初值 false，首圈若已是键窗就走一次"成键"。
  mut was_key : Bool
  /// IME 代理是否接管本窗编辑（`T375`）：true = 一台隐形 NSTextView 是 first
  /// responder，字符/退格/组合全由它自己编辑，`translate_key` 不再 `apply_edit`。
  mut ime : Bool
  /// 代理状态的上圈快照（`T375`）：文本、组合标记串。每圈读一次与它们比较，
  /// 文本变推 `Input`、标记串变推 `ImeStart/Compose/End`；光标每次照镜像写回，
  /// 不另存快照。
  mut ime_text : String
  mut ime_marked : String
  /// 本次组合挂在哪条记账上（`T375`）：Tab 换焦时焦点已经改指新控件，组合的
  /// `ImeEnd` 仍要报给旧控件，所以相位事件用这份目标而不是"泵的时候的焦点"。
  mut ime_target : @moonui.NativeHandle?
  /// 本次组合**开始前**的文本（`T375`）：组合取消时代理文本会退回它，
  /// 与它相同就不补 `Input`（取消不是输入）。
  mut ime_pre : String
  /// 代理框上一次摆到的物理像素矩形（x, y, w, h）。滚动/布局变化才重摆，
  /// 免得每圈给隐形视图设一次 frame 触发排版。
  mut ime_box : (Int32, Int32, Int32, Int32)?
}

///|
/// 记账句柄的 ptr 基数：与真堆指针（native-common 那张表）分道扬镳的
/// 车道。指针是 0x7F0000000000 + 索引，越界即坏账。
let rec_base = 0x7F0000000000L

///|
/// 记账句柄的 id 起点：与窗口句柄的编号空间错开。窗口（以及原生控件）的
/// 句柄来自 native-common 的进程级句柄表，从 0 开始发号；这里若也从 0 发，
/// 第一只控件就和第一扇窗同号（都是 id 0、generation 0）。Core 的
/// `App::dispatch_round` 先比窗口臂、再找控件，同号时事件被当成交给窗口
/// （`Window::handle_event` 只认 Resize/Close），控件 handler 永远不跑。
/// 1 << 20 之后的这一段在真机上永远走不到窗口号，够用又不浪费。
let handle_base : Int32 = 1048576

///|
pub fn CanvasBackend::CanvasBackend() -> CanvasBackend {
  CanvasBackend::{
    inner: @native-common.NativeBackend(),
    recs: [],
    free: [],
    table: @moonui.HandleTable::with_id_base(handle_base),
    windows: [],
    theme_base: @moonui.Style::empty(),
    mouse_installed: false,
    press: None,
    hover: None,
    max_fps: 60,
    vsync: true,
    refresh_hz: 0,
    next_present: 0,
    presented: false,
    pacing: true,
    app_wait_cap: -1,
    pushed_cap: -1,
    key_probe: None,
    ime_proxy: true,
    key_echo: [],
  }
}

///|
/// 发一条事件（`T378`）：一律投到**内层的队列**。内层的等待只在 `take()` 有货
/// 时才回来（点击回调发生在它的 runloop 里），自绘壳另开一条队列既叫不醒它、
/// 也会把两条队列的顺序拆开——真窗上就是"点击不重画，直到下一颗按键把它顺手
/// 叫醒"。键、焦点、输入法、鼠标全走这一条，顺序即投递顺序。
fn CanvasBackend::post(self : CanvasBackend, ev : @moonui.Event) -> Unit {
  @native-common.NativeBackend::push(self.inner, ev)
}

///|
/// 发一颗**改写出来**的键事件（`T378` 回声门）：先记进 `key_echo` 再投队。
/// 记的这一笔是给 `poll_event` 认自己人的——队列是单条，原生键与自己改写的
/// 键同形，不记就分不清，Tab/字符键会被翻译第二次。
fn CanvasBackend::post_key(self : CanvasBackend, ev : @moonui.Event) -> Unit {
  self.key_echo.push(ev)
  self.post(ev)
}

///|
/// 帧钟预算转发给内嵌原生后端（动画唤醒用，见 moonui `App` 的 `anim_wake`）：
/// 自绘后端自己不持事件循环，重绘与节流都来自 inner 的原生 `poll_event`——
/// 动画激活时把等待预算从 -1（永久等）切到 8ms（每圈醒来推进插值），停了
/// 再切回 -1。不接这条，canvas 壳的动画会卡在空闲不推进（与 native 壳
/// `new_app()` 里那条接线对齐——那里直接在 NativeBackend 上调用）。
pub fn CanvasBackend::set_frame_budget(
  self : CanvasBackend,
  active : Bool,
) -> Unit {
  self.inner.set_frame_budget(active)
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
    placeholder: "",
    bounds: @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(0.0, 0.0),
    ),
    visible: true,
    enabled: true,
    focusable: false,
    caret: 0,
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
    datetime: "",
    options: [],
    icon: "",
    image: b"",
    scroll_parent: None,
    draw: None,
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
/// 可编辑控件判据（`T374`）：这四类有文本通道，自绘后端替它们管编辑状态
/// （C 的键盘监听只报窗口，编辑真相只能落在记账侧）。
fn CwRec::editable(self : CwRec) -> Bool {
  match self.kind {
    @moonui.TextInput
    | @moonui.PasswordInput
    | @moonui.Spinbox
    | @moonui.MultilineEntry => true
    _ => false
  }
}

///|
/// 编辑/光标使用的文本（`T374`）：Spinbox 没有 Core 文本通道，`text` 空时
/// 显示值本身；焦点进入会把这份值起稿进 `text`，之后两者是同一份真相。
fn CwRec::edit_text(self : CwRec) -> String {
  if self.kind is @moonui.Spinbox && self.text == "" {
    self.value.to_string()
  } else {
    self.text
  }
}

///|
/// 可编辑字符上限（`T374`）：多行第一刀只编辑首行（首个 `\n` 之前），其余
/// kind 是全串。光标与插入都夹在这条上限内。
fn CwRec::edit_limit(self : CwRec) -> Int32 {
  let s = self.edit_text()
  if self.kind is @moonui.MultilineEntry {
    let mut n = 0
    for c in s.to_array() {
      if c == '\n' {
        break
      }
      n = n + 1
    }
    n
  } else {
    s.length()
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
/// `ime_proxy` 默认关：T374 的裸键判据要跑「没有代理」的回退路径；
/// T375 的判据显式传 `ime_proxy=true` 才起隐形 NSTextView。
pub fn CanvasBackend::for_testing(
  budget_ms : Int32,
  ime_proxy~ : Bool = false,
) -> CanvasBackend {
  let b = CanvasBackend()
  b.inner = @native-common.NativeBackend::for_testing(budget_ms)
  b.pacing = false
  b.ime_proxy = ime_proxy
  b
}

///|
/// 键窗探针的测试覆盖（`T371`）：`None` 恢复"问原生"，`Some(1)`/`Some(0)`
/// 钉住成键/失键——判据不用真窗也能走完激活与失活两条路。生产代码不调。
pub fn CanvasBackend::set_key_probe_for_testing(
  self : CanvasBackend,
  v : Int32?,
) -> Unit {
  self.key_probe = v
}

///|
/// 最大呈现帧率（1..1000，默认 60）。这条是自绘壳的**节拍合同**：应用按
/// `present_interval_ms()` 排帧，壳在同一口径上收口——脏帧到点就上屏，
/// 早到的顺延到下一槽（不丢帧）。不调用它就是 60fps。
pub fn CanvasBackend::set_max_fps(self : CanvasBackend, fps : Int32) -> Unit {
  self.max_fps = if fps < 1 { 1 } else if fps > 1000 { 1000 } else { fps }
}

///|
pub fn CanvasBackend::max_fps(self : CanvasBackend) -> Int32 {
  self.max_fps
}

///|
/// 垂直同步开关（默认开）。开：节拍向显示器刷新网格取整（见
/// `present_interval_ms`）；关：只按 `max_fps` 自由排。
pub fn CanvasBackend::set_vsync(self : CanvasBackend, on : Bool) -> Unit {
  self.vsync = on
}

///|
pub fn CanvasBackend::vsync(self : CanvasBackend) -> Bool {
  self.vsync
}

///|
/// 显示器刷新率（Hz），取不到是 0。首次查询后记住——刷新率要重开窗口才变，
/// 不值得每帧问一次 C。
pub fn CanvasBackend::refresh_hz(self : CanvasBackend) -> Int32 {
  if self.refresh_hz <= 0 {
    self.refresh_hz = @native-common.native_display_refresh_hz()
  }
  self.refresh_hz
}

///|
/// 一帧的最小间隔（毫秒）：应用排帧与壳的上屏节流共用这一条。
///
/// 垂直同步开着且拿得到刷新率时，间隔向上取整到刷新周期的**整倍数**——
/// 90fps 在 120Hz 屏上不是整倍数，落在 60fps；120fps 在 120Hz 屏上正好
/// 一拍。拿不到刷新率就退回 `1000 / max_fps`。
pub fn CanvasBackend::present_interval_ms(self : CanvasBackend) -> Int32 {
  let base = 1000 / self.max_fps
  let base = if base < 1 { 1 } else { base }
  if !self.vsync {
    return base
  }
  let hz = self.refresh_hz()
  if hz <= 0 {
    return base
  }
  let steps = (base * hz + 999) / 1000
  let steps = if steps < 1 { 1 } else { steps }
  let interval = steps * 1000 / hz
  if interval < 1 {
    1
  } else {
    interval
  }
}

///|
/// 有没有脏窗等着上屏。
fn CanvasBackend::has_dirty(self : CanvasBackend) -> Bool {
  for w in self.windows {
    if w.dirty {
      return true
    }
  }
  false
}

///|
/// 把"下一拍还剩多久"和 App 的等待上限取小，转给内层——脏帧被节流顺延时，
/// 事件循环要正好在槽位到点时醒来，否则画面会停在脏帧上等下一个原生事件。
fn CanvasBackend::forward_wait_cap(self : CanvasBackend) -> Unit {
  let mut cap = self.app_wait_cap
  if self.pacing && self.has_dirty() {
    let rem = self.next_present - @native-common.native_time_ms()
    let rem = if rem > 0 { rem } else { 1 }
    if cap < 0 || rem < cap {
      cap = rem
    }
  }
  if cap != self.pushed_cap {
    self.pushed_cap = cap
    self.inner.set_wait_cap(cap)
  }
}
