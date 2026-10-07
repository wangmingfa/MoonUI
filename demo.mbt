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

///|
/// 第三个 Demo：Login（§49）。整张表单只用已经有过的控件，不新增任何 API——
/// 这正是 §13 控件面的验收：文本框、复选框、按钮、标签加 §14 的容器就够表达。
pub struct LoginForm[B] {
  window : Window[B]
  status : Widget[B]
  username : Widget[B]
  password : Widget[B]
  remember : Widget[B]
  submit : Widget[B]
  mut signed_in : String?
}

///|
pub fn[B] LoginForm::window(self : LoginForm[B]) -> Window[B] {
  self.window
}

///|
pub fn[B : Backend] LoginForm::status_text(
  self : LoginForm[B],
) -> String raise UiError {
  self.status.text()
}

///|
pub fn[B] LoginForm::signed_in(self : LoginForm[B]) -> String? {
  self.signed_in
}

///|
/// 校验规则住在 Demo 里，不住在 Core：Core 不该知道什么叫"登录成功"。
fn[B : Backend] check_login(form : LoginForm[B]) -> Unit raise UiError {
  let name = form.username.text()
  let secret = form.password.text()
  let empty_name = name.length() == 0
  let empty_secret = secret.length() == 0
  if empty_name || empty_secret {
    form.signed_in = None
    form.status.set_text("用户名和密码都不能为空")
  } else {
    form.signed_in = Some(name)
    let suffix = if form.remember.checked() {
      "（已记住）"
    } else {
      "（未记住）"
    }
    form.status.set_text("欢迎，" + name + suffix)
  }
}

///|
/// `Padding(24) + Column(12)`：外边距给表单留呼吸空间，纵向间距统一 12。
pub fn[B : Backend] LoginForm::demo(app : App[B]) -> LoginForm[B] raise UiError {
  let b = app.backend()
  let status = Widget::label(b, "请登录")
  let username = Widget::text_input(b, "")
  let password = Widget::text_input(b, "")
  let remember = Widget::checkbox(b, "记住我", false)
  let submit = Widget::button(b, "登录")
  let content = Widget::padding(
    b,
    EdgeInsets::all(24.0),
    Widget::column(b, 12.0, [status, username, password, remember, submit]),
  )
  let window = app.create_window("MoonUI Login", LogicalSize::{
    width: 360.0,
    height: 240.0,
  })
  let form = LoginForm::{
    window,
    status,
    username,
    password,
    remember,
    submit,
    signed_in: None,
  }
  let _ = submit.on_click(fn() raise UiError { check_login(form) })
  window.set_content(content)
  window.show()
  form
}

///|
/// 按下登录：走事件而不是直调 `check_login`，这样测试覆盖的是路由 + handler。
pub fn[B] LoginForm::press_submit(self : LoginForm[B]) -> Unit raise UiError {
  let _ = self.submit.fire(Click(self.submit.target(), MouseButton::Left))
}

///|
/// 包外（`cmd/main`、README 之外写的示例）唯一的输入通道：字段本身不公开，
/// 因为让用户拿到 Widget 就能绕过校验直接改状态。这里只写文案与勾选，
/// 不伪造 Input 事件——键入路径在 Todo 的 `type_input` 里已经压过一遍。
pub fn[B : Backend] LoginForm::fill(
  self : LoginForm[B],
  username : String,
  password : String,
  remember : Bool,
) -> Unit raise UiError {
  self.username.set_text(username)
  self.password.set_text(password)
  self.remember.set_checked(remember)
}

///|
/// 一条待办。文案与完成状态都存在 Core：文案是给人看的，勾选才是事实。
pub(all) struct TodoItem {
  mut text : String
  mut done : Bool
} derive(Debug, Eq)

///|
/// 第四个 Demo：Todo（§49）。
///
/// 0.1 的 Widget 层没有增量更新，也没有 §42 的虚拟化列表，所以列表变化一律
/// "重建整棵内容树"。这不是取巧：`set_content` 换树时旧树整棵 `close_tree`
/// （§8 的所有权），于是每次增删都真实压测一遍句柄回收——连"点击删除按钮的
/// 那个按钮本身正在被销毁"这种情况都要能活下来。
/// 代价是输入框会被重建，焦点与光标位置丢失，这条限制记在这里而不是藏起来。
pub struct TodoList[B] {
  window : Window[B]
  mut status : Widget[B]
  mut input : Widget[B]
  mut add_button : Widget[B]
  mut items : Array[TodoItem]
  mut rows : Array[Widget[B]]
}

///|
pub fn[B] TodoList::window(self : TodoList[B]) -> Window[B] {
  self.window
}

///|
pub fn[B] TodoList::item_count(self : TodoList[B]) -> Int {
  self.items.length()
}

///|
pub fn[B] TodoList::done_count(self : TodoList[B]) -> Int {
  let mut n = 0
  for it in self.items {
    if it.done {
      n = n + 1
    }
  }
  n
}

///|
pub fn[B] TodoList::item(self : TodoList[B], i : Int) -> TodoItem? {
  if i < 0 || i >= self.items.length() {
    None
  } else {
    Some(self.items[i])
  }
}

///|
/// 测试用的行访问：拿到第 i 行的容器，再 `children()` 就是勾选框与删除按钮。
pub fn[B] TodoList::row(self : TodoList[B], i : Int) -> Widget[B]? {
  if i < 0 || i >= self.rows.length() {
    None
  } else {
    Some(self.rows[i])
  }
}

///|
pub fn[B : Backend] TodoList::status_text(
  self : TodoList[B],
) -> String raise UiError {
  self.status.text()
}

///|
fn progress_text(done : Int, total : Int) -> String {
  done.to_string() + "/" + total.to_string() + " 已完成"
}

///|
/// 一帧内容树的零件。构造和挂回调分成两步，是因为"添加"按钮的回调要捕获
/// `TodoList` 自身，而 `demo` 建第一帧时这个结构体还不存在。
priv struct TodoTree[B] {
  content : Widget[B]
  status : Widget[B]
  input : Widget[B]
  add_button : Widget[B]
  rows : Array[Widget[B]]
}

///|
/// 纯构造：不碰窗口、不绑回调，只按 items 画出一棵新树。
fn[B : Backend] build_todo_tree(
  b : B,
  items : Array[TodoItem],
  keep_text : String,
  done : Int,
) -> TodoTree[B] raise UiError {
  let rows : Array[Widget[B]] = []
  for it in items {
    let done_box = Widget::checkbox(b, it.text, it.done)
    let remove_btn = Widget::button(b, "x")
    rows.push(Widget::row(b, 8.0, [done_box, remove_btn]))
  }
  let status = Widget::label(b, progress_text(done, items.length()))
  let input = Widget::text_input(b, keep_text)
  let add_button = Widget::button(b, "添加")
  let body = Widget::column(b, 10.0, [
    status,
    Widget::row(b, 8.0, [input, add_button]),
    Widget::scroll(b, Axis::Vertical, Widget::column(b, 6.0, rows)),
  ])
  TodoTree::{
    content: Widget::padding(b, EdgeInsets::all(16.0), body),
    status,
    input,
    add_button,
    rows,
  }
}

///|
/// 把回调绑到刚建好的一帧上。行号要 `let idx = i` 抄一份：闭包捕获循环变量
/// 的本体，直接捕获 `i` 会让所有行都指向最后一行。
fn[B : Backend] TodoList::wire(
  self : TodoList[B],
  tree : TodoTree[B],
) -> Unit raise UiError {
  let input = tree.input
  let _ = tree.add_button.on_click(fn() raise UiError { self.add(input.text()) })
  for i = 0; i < tree.rows.length(); i = i + 1 {
    let idx = i
    let kids = tree.rows[i].children()
    let _ = kids[0].on_change(fn() raise UiError { self.toggle(idx) })
    let _ = kids[1].on_click(fn() raise UiError { let _ = self.remove(idx) })
  }
}

///|
/// 重建整棵树，输入框文案由调用方决定：`add` 之后要清空，勾选/删除时要保留
/// 用户正在打的字。旧树在 `set_content` 里整棵回收，所以文案不能等重建后再读。
fn[B : Backend] TodoList::render_at(
  self : TodoList[B],
  keep_text : String,
) -> Unit raise UiError {
  let tree = build_todo_tree(
    self.window.backend,
    self.items,
    keep_text,
    self.done_count(),
  )
  self.wire(tree)
  // 先换引用再换内容：set_content 会关掉旧树，此后 self.status 等
  // 必须指向新树里的控件，否则下一次渲染就读到死句柄
  self.rows = tree.rows
  self.status = tree.status
  self.input = tree.input
  self.add_button = tree.add_button
  self.window.set_content(tree.content)
}

///|
/// 保留当前输入文案重画一次（勾选、删除走这里）。
fn[B : Backend] TodoList::render(self : TodoList[B]) -> Unit raise UiError {
  self.render_at(self.input.text())
}

///|
/// 建 Demo：窗口 400x300，首屏直接由 `build_todo_tree` 画，不预留占位控件——
/// 没挂进窗口的控件没人 `close_tree`，占位的那三个原生对象会一直漏到程序结束。
pub fn[B : Backend] TodoList::demo(app : App[B]) -> TodoList[B] raise UiError {
  let b = app.backend()
  let window = app.create_window("MoonUI Todo", LogicalSize::{
    width: 400.0,
    height: 300.0,
  })
  let tree = build_todo_tree(b, [], "", 0)
  let list = TodoList::{
    window,
    status: tree.status,
    input: tree.input,
    add_button: tree.add_button,
    items: [],
    rows: tree.rows,
  }
  list.wire(tree)
  window.set_content(tree.content)
  window.show()
  list
}

///|
/// 添加一条。空文案只改提示，不重建树；成功时清空输入框，和真实待办应用一致。
pub fn[B : Backend] TodoList::add(
  self : TodoList[B],
  text : String,
) -> Unit raise UiError {
  if text.length() == 0 {
    self.status.set_text("待办内容不能为空")
  } else {
    self.items.push(TodoItem::{ text, done: false, })
    self.render_at("")
  }
}

///|
/// 勾选/取消勾选。真实后端里原生复选框自己会翻转，这里翻转的是 Core 的事实来源。
pub fn[B : Backend] TodoList::toggle(
  self : TodoList[B],
  i : Int,
) -> Unit raise UiError {
  if i < 0 || i >= self.items.length() {
    ()
  } else {
    let item = self.items[i]
    item.done = !item.done
    self.render()
  }
}

///|
/// 删除一行；越界返回 false 且不重排。返回 true 表示确实少了一项。
pub fn[B : Backend] TodoList::remove(
  self : TodoList[B],
  i : Int,
) -> Bool raise UiError {
  if i < 0 || i >= self.items.length() {
    false
  } else {
    let kept : Array[TodoItem] = []
    for j = 0; j < self.items.length(); j = j + 1 {
      if j != i {
        kept.push(self.items[j])
      }
    }
    self.items = kept
    self.render()
    true
  }
}

///|
/// 点"添加"：走事件路径，测的是路由 + handler + 整树重建。
pub fn[B] TodoList::press_add(self : TodoList[B]) -> Unit raise UiError {
  let _ = self.add_button.fire(
    Click(self.add_button.target(), MouseButton::Left),
  )
}

///|
/// 模拟用户打字：原生控件先自己更新文案、再发 `Input`，mock 按同样顺序做，
/// 这样紧接着的 `press_add` 读到的就是用户输入的内容。
pub fn[B : Backend] TodoList::type_input(
  self : TodoList[B],
  text : String,
) -> Unit raise UiError {
  self.input.set_text(text)
  let _ = self.input.fire(Input(self.input.target(), text))
}

///|
test "Login Demo：校验文案与登录状态（§49 第 3 个）" {
  let (app, b) = demo_app()
  let form = LoginForm::demo(app)
  assert_eq(form.status_text(), "请登录")
  assert_true(form.signed_in() is None)
  form.press_submit()
  assert_eq(form.status_text(), "用户名和密码都不能为空")
  // 只填一半仍然失败
  form.fill("wmf", "", false)
  form.press_submit()
  assert_true(form.signed_in() is None)
  form.fill("wmf", "s3cret", false)
  form.press_submit()
  assert_eq(form.signed_in(), Some("wmf"))
  assert_eq(form.status_text(), "欢迎，wmf（未记住）")
  form.fill("wmf", "s3cret", true)
  form.press_submit()
  assert_eq(form.status_text(), "欢迎，wmf（已记住）")
  // 窗口 + 5 个叶子控件；Padding 与 Column 不占原生对象（§14）
  assert_eq(b.live(), 6)
}

///|
test "Login Demo：Padding 24 套 Column 12 逐级给出绝对边界" {
  let (app, _) = demo_app()
  let form = LoginForm::demo(app)
  assert_eq(form.status.frame(), rect(24.0, 24.0, 32.0, 20.0))
  assert_eq(form.username.frame(), rect(24.0, 56.0, 160.0, 24.0))
  assert_eq(form.password.frame(), rect(24.0, 92.0, 160.0, 24.0))
  assert_eq(form.remember.frame(), rect(24.0, 128.0, 48.0, 20.0))
  assert_eq(form.submit.frame(), rect(24.0, 160.0, 40.0, 28.0))
}

///|
test "Todo Demo：加、勾、删都重建整棵树并回收句柄（§49 第 4 个）" {
  let (app, b) = demo_app()
  let list = TodoList::demo(app)
  assert_eq(list.status_text(), "0/0 已完成")
  assert_eq(list.item_count(), 0)
  // 空文案不改结构，只换提示
  list.press_add()
  assert_eq(list.status_text(), "待办内容不能为空")
  assert_eq(b.live(), 4)
  list.type_input("写字")
  list.press_add()
  assert_eq(list.item_count(), 1)
  assert_eq(list.status_text(), "0/1 已完成")
  // 添加之后输入框清空，和真实待办应用一致
  assert_eq(list.input.text(), "")
  list.type_input("读书")
  list.press_add()
  list.type_input("跑步")
  list.press_add()
  assert_eq(list.item_count(), 3)
  assert_eq(list.input.text(), "")
  // 窗口 + 标题 + 输入框 + 添加按钮 + 每行两个控件
  assert_eq(b.live(), 4 + 3 * 2)
  assert_eq(list.item(0), Some(TodoItem::{ text: "写字", done: false, }))
  assert_true(list.item(3) is None)

  // 勾掉第二行：走 Change 事件，handler 里重建整棵树
  assert_true(list.row(1) is Some(_))
  match list.row(1) {
    Some(row) => {
      let kids = row.children()
      assert_eq(kids.length(), 2)
      let _ = kids[0].fire(Change(kids[0].target()))
    }
    None => ()
  }
  assert_eq(list.done_count(), 1)
  assert_eq(list.status_text(), "1/3 已完成")
  assert_eq(list.item(1), Some(TodoItem::{ text: "读书", done: true, }))
  // 行容器是纯布局节点，重建前后原生对象数不变
  assert_eq(b.live(), 4 + 3 * 2)

  // 删除第一行：被点的按钮自己就在这棵要被销毁的旧树里
  assert_true(list.row(0) is Some(_))
  match list.row(0) {
    Some(row) => {
      let kids = row.children()
      let _ = kids[1].fire(Click(kids[1].target(), MouseButton::Left))
    }
    None => ()
  }
  assert_eq(list.item_count(), 2)
  assert_eq(list.item(0), Some(TodoItem::{ text: "读书", done: true, }))
  assert_eq(b.live(), 4 + 2 * 2)
  assert_eq(list.status_text(), "1/2 已完成")
}

///|
/// 列表的绝对边界：Padding 16 -> Column 10，标题 20 高、输入行 28 高，
/// 所以第一行的勾选框落在 y=84。删除按钮横向紧跟勾选框，中间隔 8。
test "Todo Demo：三行的边界逐级排出来" {
  let (app, _) = demo_app()
  let list = TodoList::demo(app)
  list.add("写字")
  list.add("读书")
  assert_eq(list.status.frame(), rect(16.0, 16.0, 64.0, 20.0))
  assert_eq(list.input.frame(), rect(16.0, 46.0, 160.0, 24.0))
  assert_eq(list.add_button.frame(), rect(184.0, 46.0, 40.0, 28.0))
  assert_true(list.row(0) is Some(_))
  match list.row(0) {
    Some(row) => {
      let kids = row.children()
      // 勾选框文案 2 字 -> 2*8+24 = 40，删除按钮 "x" -> 8+24 = 32
      assert_eq(kids[0].frame(), rect(16.0, 84.0, 40.0, 20.0))
      assert_eq(kids[1].frame(), rect(64.0, 84.0, 32.0, 28.0))
    }
    None => ()
  }
  assert_true(list.row(1) is Some(_))
  match list.row(1) {
    // Row 节点本身不占原生对象，也就没有边界可查——只有叶子会被写回 frame。
    // 第二行的勾选框：第一行占 28 高（行内取按钮的高度），再加 6 的间距。
    Some(row) => {
      let kids = row.children()
      assert_eq(kids[0].frame(), rect(16.0, 118.0, 40.0, 20.0))
      assert_eq(kids[1].frame(), rect(64.0, 118.0, 32.0, 28.0))
    }
    None => ()
  }
}
