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
  id : Int
  generation : Int
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
  KeyDown(EventTarget, KeyPress)
  KeyUp(EventTarget, KeyPress)
  MouseDown(EventTarget, MouseButton, LogicalPoint)
  MouseUp(EventTarget, MouseButton, LogicalPoint)
  MouseMove(EventTarget, LogicalPoint)
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
    | KeyDown(t, _)
    | KeyUp(t, _)
    | MouseDown(t, _, _)
    | MouseUp(t, _, _)
    | MouseMove(t, _)
    | Scroll(t, _)
    | MenuSelect(t)
    | ScaleChanged(t, _)
    | ThemeChanged(t, _) => t
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
  assert_eq(
    Event::target(Resize(a, LogicalSize::{ width: 1.0, height: 2.0, })),
    a,
  )
  assert_eq(
    Event::target(
      MouseDown(b, MouseButton::Right, LogicalPoint::{ x: 3.0, y: 4.0, }),
    ),
    b,
  )
}

///|
test "鼠标按下类事件被正确归类" {
  let t = EventTarget::{ id: 1, generation: 0, }
  assert_true(Event::is_mouse_press(Click(t, MouseButton::Left)))
  assert_true(
    Event::is_mouse_press(
      MouseDown(t, MouseButton::Left, LogicalPoint::{ x: 0.0, y: 0.0, }),
    ),
  )
  assert_false(Event::is_mouse_press(Change(t)))
  assert_false(
    Event::is_mouse_press(
      MouseUp(t, MouseButton::Left, LogicalPoint::{ x: 0.0, y: 0.0, }),
    ),
  )
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
