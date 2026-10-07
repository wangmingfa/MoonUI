///|
/// 第一阶段 Demo（设计文档 §49 "最重要的 Demo"、§50 "核心 API 示例"）。
///
/// Demo 写在库里而不是只写在 README，是为了让它有可回归的载体：
/// `moon test` 每次都把 Hello/Counter 从头跑一遍（建窗口、装内容、点按钮、
/// 读回文案），接上 libui-ng 之后同一份代码换个后端就是真窗口。
///
/// 与 §50 期望形态的两处差距，都是当前工具链逼出来的，不是设计偏离：
/// - `@moonui.App::new()` / `@moonui.Label::new("Hello MoonUI")` 不带后端参数：
///   本版 MoonBit 的 trait 不是类型、没有 `dyn`，后端只能在编译期随 `App[B]`
///   确定，所以构造控件必须显式交后端（`Widget::label(app.backend(), ...)`）。
/// - `button.on_click(fn { ... })` 的无参 `fn { }` 写法已废弃，这里用 `fn() { ... }`。

///|
/// 一个可回归的 Demo：窗口 + 一个显示文案的标签 + 一个触发变化的按钮。
/// Hello 与 Counter 的差别只在回调里写了什么。
pub struct Demo[B] {
  window : Window[B]
  status : Widget[B]
  action : Widget[B]
  mut clicks : Int
}

///|
pub fn[B] Demo::window(self : Demo[B]) -> Window[B] {
  self.window
}

///|
pub fn[B] Demo::status(self : Demo[B]) -> Widget[B] {
  self.status
}

///|
pub fn[B] Demo::action(self : Demo[B]) -> Widget[B] {
  self.action
}

///|
pub fn[B] Demo::click_count(self : Demo[B]) -> Int {
  self.clicks
}

///|
/// 按钮的事件目标，供测试把原生 Click 事件塞进后端队列（§10 Event First）。
pub fn[B] Demo::action_target(self : Demo[B]) -> EventTarget raise UiError {
  self.action.target()
}

///|
/// §50 的示例骨架：800x600 窗口，`Column(spacing=16, children=[文案, 按钮])`。
fn[B : Backend] make_demo_shell(
  app : App[B],
  title : String,
  text : String,
  button_text : String,
) -> (Window[B], Widget[B], Widget[B]) raise UiError {
  let b = app.backend()
  let status = Widget::label(b, text)
  let button = Widget::button(b, button_text)
  let content = Widget::column(b, 16.0, [status, button])
  let window = app.create_window(title, LogicalSize::{
    width: 800.0,
    height: 600.0,
  })
  window.set_content(content)
  window.show()
  (window, status, button)
}

///|
/// 第一个 Demo：点一下把 "Hello MoonUI" 改成 "Clicked!"（§49、§50）。
pub fn[B : Backend] Demo::hello(app : App[B]) -> Demo[B] raise UiError {
  let (window, status, button) = make_demo_shell(
    app, "MoonUI", "Hello MoonUI", "Click Me",
  )
  let demo = Demo::{ window, status, action: button, clicks: 0, }
  let _ = button.on_click(fn() raise UiError {
    demo.clicks = demo.clicks + 1
    status.set_text("Clicked!")
  })
  demo
}

///|
/// 第二个 Demo：Counter，每次点击把计数写回标签（§49）。
/// 计数存在 Core 而不是读标签文本再解析——文案是给人看的，不是状态来源。
pub fn[B : Backend] Demo::counter(app : App[B]) -> Demo[B] raise UiError {
  let (window, status, button) = make_demo_shell(
    app, "MoonUI Counter", "Count: 0", "Click Me",
  )
  let demo = Demo::{ window, status, action: button, clicks: 0, }
  let _ = button.on_click(fn() raise UiError {
    demo.clicks = demo.clicks + 1
    status.set_text("Count: " + demo.clicks.to_string())
  })
  demo
}

///|
/// 模拟用户点击按钮：走 `Widget::fire` 的事件路径而不是直接调回调，
/// 这样 Demo 验证的是 §10 的 Event First，而不只是一个闭包。
pub fn[B] Demo::click(self : Demo[B]) -> Unit raise UiError {
  let _ = self.action.fire(Click(self.action.target(), MouseButton::Left))
}

///|
fn demo_app() -> (App[MockBackend], MockBackend) raise UiError {
  let b = MockBackend::new()
  Backend::init(b)
  (App::new(b), b)
}

///|
/// 尺寸读的是 mock 的确定性启发式：码元数 × 8 加内边距（见 mock_widget.mbt）。
/// "Hello MoonUI" -> 12*8+8=104，"Click Me" -> 8*8+24=88，"Clicked!" -> 8*8+8=72。
test "Hello Demo：文案、点击、布局一条链跑通（§50）" {
  let (app, b) = demo_app()
  let demo = Demo::hello(app)
  assert_eq(demo.status().text(), "Hello MoonUI")
  assert_eq(b.window(demo.window().handle()).title, "MoonUI")
  assert_eq(demo.click_count(), 0)
  // 一个窗口 + 两个叶子：Column 这类纯布局节点不占原生对象（§14）
  assert_eq(b.live(), 3)
  assert_true(demo.window().content() is Some(_))
  assert_true(b.window(demo.window().handle()).visible)
  // set_content 立即布局：文案在上，16 间距后是按钮
  assert_eq(demo.status().frame(), rect(0.0, 0.0, 104.0, 20.0))
  assert_eq(demo.action().frame(), rect(0.0, 36.0, 88.0, 28.0))

  demo.click()
  assert_eq(demo.status().text(), "Clicked!")
  assert_eq(demo.click_count(), 1)
  // 文案变短了，但边界要等重排才更新——布局不是属性写操作的副作用
  demo.window().relayout()
  assert_eq(demo.status().frame(), rect(0.0, 0.0, 72.0, 20.0))
  assert_eq(b.live(), 3)
}

///|
/// Counter 用 `step` 逐圈推进而不是 `run`：`run` 收尾会 `terminate` 后端，
/// 循环结束后再读原生文案就只剩 `Destroyed`（§11 的取舍，app.mbt 里有对照测试）。
test "Counter Demo：三次点击经事件队列得到 Count: 3" {
  let (app, b) = demo_app()
  let demo = Demo::counter(app)
  assert_eq(demo.status().text(), "Count: 0")
  let target = demo.action_target()
  for i = 0; i < 3; i = i + 1 {
    b.push_event(Click(target, MouseButton::Left))
  }
  assert_true(app.step())
  assert_true(app.step())
  assert_true(app.step())
  assert_false(app.step())
  assert_eq(demo.status().text(), "Count: 3")
  assert_eq(demo.click_count(), 3)
}

///|
/// 完整主循环：Close 释放窗口，`run` 走完 init → 派发 → terminate，句柄表归零。
/// 这里只断言 Core 侧还读得到的状态（点击计数、窗口已关闭）。
test "Demo 跑在真实主循环上：Close 退出后句柄表归零（§11）" {
  let (app, b) = demo_app()
  let demo = Demo::counter(app)
  let click_target = demo.action_target()
  let win_target = demo.window().target()
  for i = 0; i < 2; i = i + 1 {
    b.push_event(Click(click_target, MouseButton::Left))
  }
  b.push_event(Close(win_target))
  app.run()
  assert_eq(demo.click_count(), 2)
  assert_true(demo.window().is_closed())
  assert_eq(b.live(), 0)
  assert_eq(app.window_count(), 1)
  assert_eq(app.live_window_count(), 0)
}
