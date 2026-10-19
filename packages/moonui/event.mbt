///|
/// 事件模型（设计文档 §10）。
///
/// 这里是纯数据：Backend 负责把原生消息翻译成 `Event`，Core 负责派发。
/// 公共 API 上的 `on_click` 之类只是 `Event::Click` 的语法糖，
/// 这样第六节 "Event First" 才成立——高级 API 和底层事件共用一套模型。

///|
/// 触发事件的控件句柄。用 `Int` 而非原生指针，避免 Backend 细节泄漏到 Core。
/// `generation` 沿用 `NativeHandle` 那套防复用账（`T49`）：句柄表的 `free_ids`
/// 会把销毁过的 id 发给下一只新控件，只比 id 的订阅早晚会命中"同一个数字的
/// 新主人"——事件目标是订阅那一刻的一次快照，id 之外还得记下是第几代。
/// 菜单项不走句柄表（§25 的独立编号空间），generation 恒 0，靠 `MenuSelect`
/// 这个变体本身与控件路由隔离。
pub(all) struct EventTarget {
  id : Int32
  generation : Int32
} derive(Debug, Eq)

///|
/// 从句柄取事件目标：id 和 generation 一起带走。手造 `EventTarget` 的地方
/// 要想清楚——拿真句柄的都该走这一条（`T49`）。
pub fn EventTarget::of(h : NativeHandle) -> EventTarget {
  EventTarget::{ id: h.id, generation: h.generation, }
}

///|
pub(all) enum MouseButton {
  Left
  Right
  Middle
  Extra1
  Extra2
} derive(Debug, Eq)

///|
/// 键名统一用可读字符串（`"Enter"` / `"F5"` / `"a"`），
/// 各平台的物理键码差异留给 Backend 归一化。
pub(all) struct KeyPress {
  key : String
  ctrl : Bool
  alt : Bool
  shift : Bool
  meta : Bool
} derive(Debug, Eq)

///|
pub(all) enum Event {
  Click(EventTarget, MouseButton)
  DoubleClick(EventTarget)
  Change(EventTarget)
  /// 文本控件内容变化，携带变化后的全文
  Input(EventTarget, String)
  Focus(EventTarget)
  Blur(EventTarget)
  Close(EventTarget)
  Resize(EventTarget, LogicalSize)
  /// 窗口被**移动**了（`T89` 吸附）：target 是那只窗口，坐标与
  /// `Window::position` 同一套（外层左上角、该屏可见区原点）。
  ///
  /// 只有**用户拖动**才产这条：Core 自己 `set_position` / 位移动画推的位置，
  /// 原生层会抑制掉（与 `suppress_resize` 同一条约定）——否则"拖一只、带走
  /// 邻居"里邻居的移动又回声成一条 Moved，吸附加法自己打自己。
  ///
  /// Core 拿它做两件事：记下这只窗的新原点（算位移要"上一次在哪"），以及把
  /// 吸附在同一块里的其它窗按同样的位移一起带走（`App::follow_move`）。
  Moved(EventTarget, LogicalPoint)
  KeyDown(EventTarget, KeyPress)
  KeyUp(EventTarget, KeyPress)
  MouseDown(EventTarget, MouseButton, LogicalPoint)
  MouseUp(EventTarget, MouseButton, LogicalPoint)
  MouseMove(EventTarget, LogicalPoint)
  /// 悬停进入（皮肤账）：Core 从 MouseMove 的目标变化里合成——目标从 A 换成
  /// B 时给 A 补 MouseLeave、给 B 补 MouseEnter（同一条 MouseMove 路由前后）。
  /// 后端不产这条（悬停是 Core 的账，C 只报移动）。
  MouseEnter(EventTarget)
  /// 悬停离开（同上，成对出现）
  MouseLeave(EventTarget)
  /// 滚动，单位为逻辑像素增量
  Scroll(EventTarget, LogicalPoint)
  /// 用户点了某一项菜单（§25）。target.id 是菜单项在 `MenuBar` 里的编号，
  /// 与窗口/控件的句柄 id 是两个独立空间，靠这个变体本身区分。
  MenuSelect(EventTarget)
  /// 窗口所在屏幕的缩放因子变了（拖到另一块 DPI 不同的屏、系统改缩放）。
  /// §30 要求 HiDPI 从第一版就考虑，缺了这个事件，Core 只能在窗口创建时
  /// 读一次 Scale，之后所有物理尺寸都是过期的。
  ScaleChanged(EventTarget, Scale)
  /// 系统主题变了（用户在系统设置里切深浅色，`T48`）。主题本身是进程级的事，
  /// 但派发路由按句柄走，所以后端给每只存活窗口各发一条；携带的是新的生效
  /// 外观（Light/Dark——Backend 的读数里 System 已经解析掉了）。App 收到后
  /// 会给目标窗口重算 `style_base` 并重排（§16：样式层叠的起点换了）。
  ThemeChanged(EventTarget, Theme)
  /// 该给这只窗口画一帧了（`T31`）。原生控件后端用不到它——重绘是系统的事，
  /// 窗口脏了系统自己会画；自绘后端（§51 的 Backend #2）没有系统替它画，
  /// 空闲时 `poll_event` 返回 `None`、`run` 的 while 就 break 了，只能靠这条
  /// 事件续命：后端在需要重绘时 `request_redraw`，下一圈 `poll_event` 吐一条
  /// `Frame`，Core 据此驱动自绘后端画一帧。target 是那只窗口的句柄。
  Frame(EventTarget)
  /// 输入法组合开始（`T85②`）：组合串从无到有，target 是正在组合的文本控件。
  /// 通知不携带组合串（与 Win32 的 `WM_IME_STARTCOMPOSITION` 对齐——它同样不带
  /// 内容），串跟在同一条序列的下一条 `ImeCompose` 上。组合期间原生控件自己
  /// 处理输入法 UI（候选词窗口等，§32 红利不重复建），Core 只收相位通知。
  ImeStart(EventTarget)
  /// 输入法组合进行（`T85②`）：组合串变了，携带当下的组合串（标记串）。
  /// mac 半来自 field editor 的标记串子串，Windows 半来自 `WM_IME_COMPOSITION`
  /// 的 `GCS_COMPSTR`；组合串上屏时的全文随既有 `Input` 事件走，不在这里重复。
  ImeCompose(EventTarget, String)
  /// 输入法组合结束（`T85②`）：组合串上屏或被取消。上屏的全文随既有 `Input`
  /// 走（§32 原生红利），取消时没有 `Input`——"串去哪儿了"由后端自己说明。
  ImeEnd(EventTarget)
  /// 长按（`T86⑧`）：按下后 `LONG_PRESS_DURATION_MS` 未抬起且未超移动阈值时由
  /// Core 侧计时识别补发（进程级鼠标监听 `T39` 只保证按下/抬起到达 MoonBit，
  /// "按了多久"是 Core 的事，零 C）。target 是收到那条 `MouseDown` 的控件，
  /// 移动超阈或抬起都会取消（不补发也不取消已发的那条）。仅左键启动。
  LongPress(EventTarget)
  /// 文件拖入（`T86③` 第一期档案，§47 的形状判据"拖入文件路径事件"）：用户把
  /// 外部文件拖到窗口上松手。target 是接住拖入的那只窗口，paths 是拖入的文件
  /// 路径数组（平台层给的顺序原样照抄）。控件间拖动与数据格式打包是第二期的
  /// 档（`T86③` 分期），这条只覆盖外部文件拖入。
  FileDrop(EventTarget, Array[String])
} derive(Debug, Eq)

///|
/// 事件目标，用于 Core 做派发路由。
pub fn Event::target(self : Event) -> EventTarget {
  match self {
    Click(t, _)
    | DoubleClick(t)
    | Change(t)
    | Input(t, _)
    | Focus(t)
    | Blur(t)
    | Close(t)
    | Resize(t, _)
    | Moved(t, _)
    | KeyDown(t, _)
    | KeyUp(t, _)
    | MouseDown(t, _, _)
    | MouseUp(t, _, _)
    | MouseMove(t, _)
    | MouseEnter(t)
    | MouseLeave(t)
    | Scroll(t, _)
    | MenuSelect(t)
    | ScaleChanged(t, _)
    | ThemeChanged(t, _)
    | Frame(t)
    | ImeStart(t)
    | ImeCompose(t, _)
    | ImeEnd(t)
    | LongPress(t)
    | FileDrop(t, _) => t
  }
}

///|
/// 是否为鼠标按下类事件——派发时需要做命中测试的就是这几类。
pub fn Event::is_mouse_press(self : Event) -> Bool {
  match self {
    Click(_, _) | DoubleClick(_) | MouseDown(_, _, _) => true
    _ => false
  }
}

///|
/// 快捷键匹配：只比较修饰键组合与键名，不做物理键码判断。
pub fn KeyPress::matches(
  self : KeyPress,
  key : String,
  ctrl : Bool,
  alt : Bool,
  shift : Bool,
  meta : Bool,
) -> Bool {
  self.key == key &&
  self.ctrl == ctrl &&
  self.alt == alt &&
  self.shift == shift &&
  self.meta == meta
}

///|
test "Event::target 对每种事件都能取出目标" {
  let a = EventTarget::{ id: 7, generation: 0, }
  let b = EventTarget::{ id: 9, generation: 0, }
  assert_eq(Event::target(Click(a, MouseButton::Left)), a)
  assert_eq(Event::target(Input(b, "hi")), b)
  assert_eq(Event::target(Resize(a, LogicalSize(1.0, 2.0))), a)
  assert_eq(
    Event::target(MouseDown(b, MouseButton::Right, LogicalPoint(3.0, 4.0))),
    b,
  )
}

///|
test "鼠标按下类事件被正确归类" {
  let t = EventTarget::{ id: 1, generation: 0, }
  assert_true(Event::is_mouse_press(Click(t, MouseButton::Left)))
  assert_true(
    Event::is_mouse_press(
      MouseDown(t, MouseButton::Left, LogicalPoint(0.0, 0.0)),
    ),
  )
  assert_false(Event::is_mouse_press(Change(t)))
  assert_false(
    Event::is_mouse_press(MouseUp(t, MouseButton::Left, LogicalPoint(0.0, 0.0))),
  )
}

///|
test "LongPress 的目标可取出（T86⑧——识别账在 App 侧，这里是纯数据）" {
  let t = EventTarget::{ id: 5, generation: 0, }
  let ev : Event = LongPress(t)
  assert_eq(Event::target(ev), t)
  // 长按不是鼠标按下类：命中测试/直派路由不走那一臂
  assert_false(Event::is_mouse_press(ev))
}

///|
test "FileDrop 的目标可取出且路径原样携带（T86③判据）" {
  let t = EventTarget::{ id: 3, generation: 0, }
  let paths = ["/Users/me/Desktop/a.png", "/tmp/b.md"]
  let ev : Event = FileDrop(t, paths)
  assert_eq(Event::target(ev), t)
  assert_false(Event::is_mouse_press(ev))
  assert_eq(ev, FileDrop(t, ["/Users/me/Desktop/a.png", "/tmp/b.md"]))
}

///|
test "KeyPress::matches 要求修饰键组合完全一致" {
  let kp = KeyPress::{
    key: "s",
    ctrl: true,
    alt: false,
    shift: false,
    meta: false,
  }
  assert_true(kp.matches("s", true, false, false, false))
  assert_false(kp.matches("s", false, false, false, false))
  assert_false(kp.matches("s", true, false, true, false))
  assert_false(kp.matches("S", true, false, false, false))
}
