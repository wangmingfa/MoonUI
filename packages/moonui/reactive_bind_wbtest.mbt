///|
/// `T284` 响应式绑定层判据（DESIGN §53.4 / §53.8）。白盒测试（`_wbtest.mbt`）：
/// 能读 `Signal.subs` 钉 R1 的自解绑。走 public API，钉"Signal 变了 → 视图
/// 自动变"（**没显式调过 set_***）、双向防回环、R1 解绑。
///
/// 判据清单（§53.8）：
/// ① Signal 变→属性已是新值、没显式调用过 setter（mock 无头判据）
/// ② 双向绑定防回环（输入框打字不 `set_text` 回写自己）
/// ③ `close_tree` 解绑（R1：`Signal.subs` 不悬空引用已销毁控件）
/// ④ 种类守卫继承（bind_text 在无文本控件抛 `Unsupported`）
/// ⑤ 通用 `bind` 兜底
/// ⑥ 双向 check（Change→信号、信号→控件）

///|
fn bind_app() -> (App[MockBackend], MockBackend) raise UiError {
  let b = MockBackend::new()
  Backend::init(b)
  (App::new(b), b)
}

///|
/// ① bind_text_fmt：初始值立即推，Signal 变→Label 文案自动变。
test "bind_text_fmt：Signal 变→Label 文案自动变" {
  let (app, _b) = bind_app()
  let label = Widget::label(app.backend(), "0")
  let r : Signal[Int32] = Signal::new(0)
  let _ = label.bind_text_fmt(r, fn(c : Int32) { c.to_string() })
  assert_eq(label.text(), "0") // 初始值立即推
  r.set(5)
  assert_eq(label.text(), "5") // 信号变→视图自动变（没显式调 set_text）
  r.set(9)
  assert_eq(label.text(), "9")
}

///|
/// ① bind_text：`Signal[String]` 直接绑文案。
test "bind_text：Signal[String] 直接绑文案" {
  let (app, _b) = bind_app()
  let label = Widget::label(app.backend(), "")
  let r : Signal[String] = Signal::new("hello")
  let _ = label.bind_text(r)
  assert_eq(label.text(), "hello")
  r.set("world")
  assert_eq(label.text(), "world")
}

///|
/// ① bind_checked：Signal 变→checkbox 勾选自动变。
test "bind_checked：Signal 变→checkbox 勾选自动变" {
  let (app, _b) = bind_app()
  let cb = Widget::checkbox(app.backend(), "On", false)
  let r : Signal[Bool] = Signal::new(false)
  let _ = cb.bind_checked(r)
  assert_false(cb.checked())
  r.set(true)
  assert_true(cb.checked())
}

///|
/// ① bind_value：Signal 变→slider 数值自动变。
test "bind_value：Signal 变→slider 数值自动变" {
  let (app, _b) = bind_app()
  let slider = Widget::slider(app.backend(), 0, 100)
  let r : Signal[Int32] = Signal::new(40)
  let _ = slider.bind_value(r)
  assert_eq(slider.value(), 40)
  r.set(60)
  assert_eq(slider.value(), 60)
}

///|
/// ① bind_selected：Signal 变→下拉选中下标自动变。
test "bind_selected：Signal 变→下拉选中下标自动变" {
  let (app, _b) = bind_app()
  let combo = Widget::combobox(app.backend(), ["A", "B"])
  let r : Signal[Int32] = Signal::new(0)
  let _ = combo.bind_selected(r)
  assert_eq(combo.selected(), 0)
  r.set(1)
  assert_eq(combo.selected(), 1)
}

///|
/// ① bind_enabled：Signal 变→控件可用性自动变。
test "bind_enabled：Signal 变→控件可用性自动变" {
  let (app, _b) = bind_app()
  let btn = Widget::button(app.backend(), "Ok")
  let r : Signal[Bool] = Signal::new(true)
  let _ = btn.bind_enabled(r)
  assert_true(btn.enabled())
  r.set(false)
  assert_false(btn.enabled())
}

///|
/// ① bind_visible：Signal 变→控件可见性自动变。
test "bind_visible：Signal 变→控件可见性自动变" {
  let (app, _b) = bind_app()
  let btn = Widget::button(app.backend(), "Ok")
  let r : Signal[Bool] = Signal::new(true)
  let _ = btn.bind_visible(r)
  assert_true(btn.visible())
  r.set(false)
  assert_false(btn.visible())
}

///|
/// ① bind_placeholder：Signal 变→输入框占位自动变（读 mock 的后端落点）。
test "bind_placeholder：Signal 变→输入框占位自动变" {
  let (app, b) = bind_app()
  let input = Widget::text_input(app.backend(), "")
  let h = match input.handle() {
    Some(h) => h
    None => raise InvalidHandle
  }
  let r : Signal[String] = Signal::new("提示")
  let _ = input.bind_placeholder(r)
  assert_eq(b.widget(h).placeholder, "提示")
  r.set("新提示")
  assert_eq(b.widget(h).placeholder, "新提示")
}

///|
/// ① bind_style：Signal 变→控件局部样式自动变。
test "bind_style：Signal 变→控件局部样式自动变" {
  let (app, _b) = bind_app()
  let label = Widget::label(app.backend(), "x")
  let r : Signal[Style?] = Signal::new(None)
  let _ = label.bind_style(r)
  assert_eq(label.style(), None)
  let s = Style::empty()
  r.set(Some(s))
  assert_eq(label.style(), Some(s))
}

///|
/// ⑤ 通用 bind 兜底：自定义 apply。
test "bind 通用兜底：自定义 apply" {
  let (app, _b) = bind_app()
  let label = Widget::label(app.backend(), "")
  let r : Signal[Int32] = Signal::new(0)
  let _ = label.bind(r, fn(w, v) raise UiError { w.set_text(v.to_string()) })
  assert_eq(label.text(), "0")
  r.set(7)
  assert_eq(label.text(), "7")
}

///|
/// ④ 种类守卫继承：bind_text 在无文本控件（Slider）抛 `Unsupported`。
test "bind_text 种类守卫继承：无文本控件抛 Unsupported" {
  let (app, _b) = bind_app()
  let slider = Widget::slider(app.backend(), 0, 100)
  let r : Signal[String] = Signal::new("x")
  let raised = try {
    let _ = slider.bind_text(r)
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
/// ②⑥ bind_input 双向：Input 事件→信号、信号→控件文本。
test "bind_input：双向——打字写回信号、信号写回控件" {
  let (app, _b) = bind_app()
  let input = Widget::text_input(app.backend(), "")
  let r : Signal[String] = Signal::new("")
  let _ = input.bind_input(r)
  assert_eq(input.text(), "")
  // 打字（Input 事件）→ 信号
  let _ = input.fire(Input(input.target(), "abc"))
  assert_eq(r.get(), "abc")
  // 信号外部变 → 控件
  r.set("xyz")
  assert_eq(input.text(), "xyz")
}

///|
/// ② 防回环：打字后绑定**不** set_text 回写自己（suppress）。
test "bind_input：防回环——打字后绑定不 set_text 回写" {
  let (app, _b) = bind_app()
  let input = Widget::text_input(app.backend(), "")
  let r : Signal[String] = Signal::new("")
  let _ = input.bind_input(r)
  // 打字：Input 事件携带全文。mock 不模拟原生上屏（text() 仍是空），
  // 若绑定在信号方向回写 set_text，text() 会变成 "abc"——断言它仍空，
  // 证明 suppress 挡住了回写。
  let _ = input.fire(Input(input.target(), "abc"))
  assert_eq(r.get(), "abc") // 信号拿到了新值
  assert_eq(input.text(), "") // 但绑定没回写 set_text（防回环）
}

///|
/// ②⑥ bind_check 双向：Change→信号、信号→控件勾选。
test "bind_check：双向——Change 写回信号、信号写回控件" {
  let (app, _b) = bind_app()
  let cb = Widget::checkbox(app.backend(), "On", false)
  let r : Signal[Bool] = Signal::new(false)
  let _ = cb.bind_check(r)
  assert_false(cb.checked())
  // 模拟用户勾选：原生先置勾选态，再发 Change
  cb.set_checked(true)
  let _ = cb.fire(Change(cb.target()))
  assert_true(r.get()) // 信号拿到了新值
  // 信号外部变 → 控件
  r.set(false)
  assert_false(cb.checked())
}

///|
/// ③ R1：close_tree 后 Signal 变不悬空、订阅自解绑。
test "bind_text：close_tree 后 Signal 变不悬空（R1）" {
  let (app, _b) = bind_app()
  let label = Widget::label(app.backend(), "0")
  let r : Signal[String] = Signal::new("a")
  let _ = label.bind_text(r)
  assert_eq(r.subs.length(), 1) // 绑定订阅已挂
  label.close_tree()
  // 关树后信号再变：订阅看到 closed，自解绑并跳过，不碰已销毁控件
  r.set("b")
  // 订阅已自解绑（R1：Signal.subs 不再悬空引用已销毁控件）
  assert_eq(r.subs.length(), 0)
}

///|
/// ③ R1：bind_input 的自解绑与通用 `bind` 同策——控件 close_tree 后，
/// 信号再变时订阅自解绑，`Signal.subs` 不再累积悬空引用。
test "bind_input：close_tree 后自解绑（R1）" {
  let (app, _b) = bind_app()
  let input = Widget::text_input(app.backend(), "")
  let r : Signal[String] = Signal::new("")
  let _ = input.bind_input(r)
  assert_eq(r.subs.length(), 1)
  input.close_tree()
  r.set("b")
  assert_eq(r.subs.length(), 0)
}

///|
/// ③ R1：bind_check 的自解绑与通用 `bind` 同策。
test "bind_check：close_tree 后自解绑（R1）" {
  let (app, _b) = bind_app()
  let cb = Widget::checkbox(app.backend(), "On", false)
  let r : Signal[Bool] = Signal::new(false)
  let _ = cb.bind_check(r)
  assert_eq(r.subs.length(), 1)
  cb.close_tree()
  r.set(true)
  assert_eq(r.subs.length(), 0)
}
