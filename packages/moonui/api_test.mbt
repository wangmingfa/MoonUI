// 声明式链（T83）的黑盒测试：全部走公共 API（`@moonui.` 前缀），在 MockBackend
// 上跑。判据是 TODO 里那条"**新 API 建的树与旧 API 逐位同值**"——同一棵树，
// 声明式脸（构造参数 + 返 self 的链）与命令式脸（旧构造 + set_* setter）摆出
// 来必须一个样：kind / frame / 局部样式 / 后端收到的推送 / 固有尺寸 / 事件
// 订阅计数，一样都不能差。种类守卫的语义也必须同句（同一个 Unsupported）。

///|
/// 把错误收成语明（§33 的既有测试形状，黑盒版）。
fn error_of(body : () -> Unit raise @moonui.UiError) -> String? {
  let out : String? = try {
    body()
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  out
}

///|
fn unwrap_handle(
  w : @moonui.Widget[@moonui.MockBackend],
) -> @moonui.NativeHandle raise @moonui.UiError {
  match w.handle() {
    Some(h) => h
    None => raise @moonui.InvalidHandle
  }
}

///|
/// 两棵树按同一把尺对账：kind / frame / 局部样式 / 订阅数 / 后端固有尺寸 /
/// 子项数逐位相同；文本账与 insets 账只在有这些属性的种类上读（其余种类
/// 读回是 Unsupported，不是"空"）。
/// assert_eq 的错误类型是通用 Error，widget 方法的 UiError 是它的子类型，
/// 所以对账函数声明 raise Error（测试块的驱动本来就按 Error 收）。
fn assert_same_tree(
  a : @moonui.Widget[@moonui.MockBackend],
  c : @moonui.Widget[@moonui.MockBackend],
) -> Unit raise Error {
  assert_eq(a.kind(), c.kind())
  assert_eq(a.frame(), c.frame())
  assert_eq(a.style(), c.style())
  assert_eq(a.handler_count(), c.handler_count())
  assert_eq(a.intrinsic_size(), c.intrinsic_size())
  let ca = a.children()
  let cc = c.children()
  assert_eq(ca.length(), cc.length())
  match a.kind() {
    Label
    | Button
    | TextInput
    | Checkbox
    | PasswordInput
    | MultilineEntry
    | MenuRow => assert_eq(a.text(), c.text())
    _ => ()
  }
  match a.kind() {
    Padding | MenuRow => assert_eq(a.insets(), c.insets())
    _ => ()
  }
  for i = 0; i < ca.length(); i = i + 1 {
    assert_same_tree(ca[i], cc[i])
  }
}

///|
fn api_app() -> @moonui.App[@moonui.MockBackend] raise @moonui.UiError {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  @moonui.App::new(b)
}

///|
/// TODO 示例第一句的可行读法：`Text::new("Hello").font_size(18).foreground(...)`
/// ——身份留在构造（`Widget::label(b, "Hello")`），外观走返 self 的链。
/// 判据：与命令式脸（旧构造 + 整张 `set_style`）逐位同值——kind / 文案 /
/// 局部样式读回 / 后端固有尺寸（mock 的字号缩放账）/ to_layout_spec 全一样。
test "逐位同值：外观链与整张 set_style 是同一格" {
  let app = api_app()
  let b = app.backend()
  let win = app.create_window("T83", @moonui.LogicalSize(800.0, 600.0))
  // 声明式脸：链上叠两格
  let declared = @moonui.Widget::label(b, "Hello")
    .font_size(18.0)
    .foreground(@moonui.Color::rgb(200, 30, 30))
  // 命令式脸：同一格账，一次交整张
  let imperative = @moonui.Widget::label(b, "Hello")
  imperative.set_style(
    Some(
      @moonui.style(
        font_size=Some(18.0),
        foreground=Some(@moonui.Color::rgb(200, 30, 30)),
      ),
    ),
  )
  assert_eq(declared.kind(), imperative.kind())
  assert_eq(declared.text(), "Hello")
  assert_eq(declared.style(), imperative.style())
  // 挂进窗口：relayout 在布局之前把解析样式下发后端，后端的度量才是
  // "这份样式下的度量"——固有尺寸读回必须一样（5*8*1.5+8=68，20*1.5=30）
  win.set_content(@moonui.Widget::column(b, 0.0, [declared, imperative]))
  win.show()
  assert_eq(declared.intrinsic_size(), imperative.intrinsic_size())
  assert_eq(declared.intrinsic_size(), @moonui.LogicalSize(68.0, 30.0))
  // 摆出来的账也共用同一个：读回值 = spec 里的固有值（MenuRow 那条的规矩）。
  // spec 里的 id 是原生身份，两个控件自然不同，账比对的是固有值与铺排位。
  match (declared.to_layout_spec(), imperative.to_layout_spec()) {
    (Leaf(da), Leaf(di)) => {
      assert_eq(da.intrinsic, di.intrinsic)
      assert_eq(da.expand, di.expand)
      assert_eq(da.fill_cross, di.fill_cross)
    }
    _ => assert_true(false)
  }
}

///|
/// TODO 示例第三句的可行读法：`MenuRow::new("原生控件", selected=false)
/// .insets(...).on_click(fn(){...})` ——身份留在构造（文案与选中态本来就是
/// 构造参数），内缩与订阅走 `.with_insets(...)` / `.with_on_click(...)`。
/// 判据：与命令式脸逐位同值，连"语义真的到了后端"的推送账都要一样。
test "逐位同值：MenuRow 的 insets 与点击订阅" {
  let app = api_app()
  let b = app.backend()
  let mut hits = 0
  // 声明式脸
  let declared = @moonui.Widget::menu_row(b, "原生控件", false)
    .with_insets(@moonui.EdgeInsets::all(8.0))
    .with_on_click(fn() { hits = hits + 1 })
  // 命令式脸
  let imperative = @moonui.Widget::menu_row(b, "原生控件", false)
  imperative.set_insets(@moonui.EdgeInsets::all(8.0))
  let _ = imperative.on_click(fn() { hits = hits + 10 })
  assert_eq(declared.insets(), imperative.insets())
  assert_eq(declared.style(), imperative.style())
  // 选中态构造参数原样落在 checked 通道上
  assert_false(declared.checked())
  // 内缩账真的到了后端：mock 把最近一次推下来的 insets 记在控件上
  assert_eq(
    b.widget(unwrap_handle(declared)).insets,
    @moonui.EdgeInsets::all(8.0),
  )
  assert_eq(
    b.widget(unwrap_handle(imperative)).insets,
    @moonui.EdgeInsets::all(8.0),
  )
  // 固有 = 内容 + insets，两个脸长同样大
  assert_eq(declared.intrinsic_size(), imperative.intrinsic_size())
  // 订阅数一样；点击真的进了声明式那条订阅（hits +1），命令式那条也进了（+10）
  assert_eq(declared.handler_count(), imperative.handler_count())
  let _ = declared.fire(Click(declared.target(), Left))
  let _ = imperative.fire(Click(imperative.target(), Left))
  assert_eq(hits, 11)
  // 种类守卫同句：链与 setter 在同一个名单上拦
  assert_eq(
    error_of(fn() raise @moonui.UiError { let _ = declared.with_spacing(4.0) }),
    error_of(fn() raise @moonui.UiError { imperative.set_spacing(4.0) }),
  )
}

///|
/// TODO 示例第二句的可行读法：`Column::new(spacing=8).children([...])` ——
/// 间距与子项本来就是 `Widget::column` 的构造参数；外观走链。整棵树
/// （Padding -> Column -> [字号 Label, 勾选 Checkbox, 禁用 Button, 内缩
/// MenuRow]）两个脸各拼一份，挂进两个窗口摆出来逐位对账。
test "逐位同值：整棵树两个脸摆出来一个样" {
  let app = api_app()
  let b = app.backend()
  let color = @moonui.Color::rgb(96, 92, 240)
  // 声明式脸：外观/行为全在链上，结构（谁包含谁）走构造
  let tree_a = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::zero(),
    @moonui.Widget::column(b, 8.0, []).with_children([
      @moonui.Widget::label(b, "字号标签").font_size(18.0).foreground(color),
      @moonui.Widget::checkbox(b, "记住我", false).with_checked(true),
      @moonui.Widget::button(b, "禁用按钮").with_enabled(false),
      @moonui.Widget::menu_row(b, "菜单行", true).with_insets(
        @moonui.EdgeInsets::symmetric(4.0, 8.0),
      ),
    ]),
  ).with_insets(@moonui.EdgeInsets::all(12.0))
  // 命令式脸：同一份构图，账全在 set_* 上
  let label = @moonui.Widget::label(b, "字号标签")
  label.set_style(
    Some(@moonui.style(font_size=Some(18.0), foreground=Some(color))),
  )
  let checkbox = @moonui.Widget::checkbox(b, "记住我", false)
  checkbox.set_checked(true)
  let button = @moonui.Widget::button(b, "禁用按钮")
  button.set_enabled(false)
  let menu = @moonui.Widget::menu_row(b, "菜单行", true)
  menu.set_insets(@moonui.EdgeInsets::symmetric(4.0, 8.0))
  let column = @moonui.Widget::column(b, 8.0, [label, checkbox, button, menu])
  let tree_c = @moonui.Widget::padding(b, @moonui.EdgeInsets::all(12.0), column)
  assert_eq(tree_a.kind(), tree_c.kind())
  // 各挂一个窗口，set_content 即布局：同一构图、同一布局引擎、同一份样式
  // 下发账——两个脸摆出来的 frame 必须逐位相同
  let win_a = app.create_window("声明式", @moonui.LogicalSize(800.0, 600.0))
  win_a.set_content(tree_a)
  win_a.show()
  let win_c = app.create_window("命令式", @moonui.LogicalSize(800.0, 600.0))
  win_c.set_content(tree_c)
  win_c.show()
  assert_same_tree(tree_a, tree_c)
}

///|
/// 外观链是"只改这一格"：`.foreground(...).font_size(...)` 两次独立叠进
/// 局部样式，已有的覆盖原样保留——不是"第二次把第一次抹掉"。与命令式
/// 的整张写法读回同值。
test "外观链只改一格，已有覆盖原样保留" {
  let app = api_app()
  let b = app.backend()
  let declared = @moonui.Widget::label(b, "Title")
    .foreground(@moonui.Color::rgb(96, 92, 240))
    .font_size(18.0)
    .font_weight(Bold)
  let imperative = @moonui.Widget::label(b, "Title")
  imperative.set_style(
    Some(
      @moonui.style(
        foreground=Some(@moonui.Color::rgb(96, 92, 240)),
        font_size=Some(18.0),
        font_weight=Some(Bold),
      ),
    ),
  )
  assert_eq(declared.style(), imperative.style())
  assert_eq(
    declared.style(),
    Some(
      @moonui.style(
        foreground=Some(@moonui.Color::rgb(96, 92, 240)),
        font_size=Some(18.0),
        font_weight=Some(Bold),
      ),
    ),
  )
  // 同格覆盖：后一次盖前一次（层叠语义，pick 只认显式值）
  let replaced = declared.background(@moonui.Color::rgb(10, 20, 30))
  assert_eq(
    replaced.style(),
    Some(
      @moonui.style(
        background=Some(@moonui.Color::rgb(10, 20, 30)),
        foreground=Some(@moonui.Color::rgb(96, 92, 240)),
        font_size=Some(18.0),
        font_weight=Some(Bold),
      ),
    ),
  )
}

///|
/// 行为链继承被包裹 setter 的全部语义：种类守卫同名单同句、错误传播
/// 不改形状（§33 控件不吞异常）。链不改守卫的一个字。
test "行为链继承种类守卫：同名单同句" {
  let app = api_app()
  let b = app.backend()
  let label = @moonui.Widget::label(b, "Title")
  let twin = @moonui.Widget::label(b, "Title")
  assert_eq(
    error_of(fn() raise @moonui.UiError { let _ = label.with_spacing(4.0) }),
    error_of(fn() raise @moonui.UiError { twin.set_spacing(4.0) }),
  )
  assert_eq(
    error_of(fn() raise @moonui.UiError {
      let _ = label.with_insets(@moonui.EdgeInsets::all(2.0))
    }),
    error_of(fn() raise @moonui.UiError {
      twin.set_insets(@moonui.EdgeInsets::all(2.0))
    }),
  )
  assert_eq(
    error_of(fn() raise @moonui.UiError { let _ = label.with_checked(true) }),
    error_of(fn() raise @moonui.UiError { twin.set_checked(true) }),
  )
  // 错误传播不改形状：链在关闭的控件上照样把 Destroyed 沿调用传出
  let ghost = @moonui.Widget::label(b, "Ghost")
  ghost.close_tree()
  assert_eq(
    error_of(fn() raise @moonui.UiError { let _ = ghost.with_visible(false) }),
    error_of(fn() raise @moonui.UiError { ghost.set_visible(false) }),
  )
}

///|
/// 链返回 self 的证明是效果而不是身份比较：订阅/置值如果落在副本上，
/// 原控件的订阅数与后端状态都不会动。效果全在原控件上，副本不存在。
test "链返回 self：效果落在原控件上" {
  let app = api_app()
  let b = app.backend()
  let mut hits = 0
  let button = @moonui.Widget::button(b, "Ok")
  let _ = button.with_on_click(fn() { hits = hits + 1 })
  // 订阅真的挂在 button 上（副本链会让这条断言红）
  assert_eq(button.handler_count(), 1)
  let _ = button.fire(Click(button.target(), Left))
  assert_eq(hits, 1)
  // 返回值继续接链：订阅、置值在同一句里叠
  let slider = @moonui.Widget::slider(b, 0, 100)
    .with_value(40)
    .with_on_change(fn() { hits = hits + 100 })
  assert_eq(slider.value(), 40)
  assert_eq(slider.handler_count(), 1)
  let _ = slider.fire(Change(slider.target()))
  assert_eq(hits, 101)
  // 订阅族逐条读回：文本变化携带全文（§10 的 Input）
  let mut last : String = ""
  let input = @moonui.Widget::text_input(b, "").with_on_input(fn(t) { last = t })
  let _ = input.fire(Input(input.target(), "MoonUI"))
  assert_eq(last, "MoonUI")
}

///|
/// `with_children` 是追加账不是替换账：结构身份不换（self 还是同一个
/// 容器），与构造参数字面量 + `add_child` 循环同账——挂进窗口后两个脸
/// 的 frame 逐位相同。
test "with_children 是追加账：与 add_child 循环同值" {
  let app = api_app()
  let b = app.backend()
  let first = @moonui.Widget::label(b, "第一项")
  let second = @moonui.Widget::label(b, "第二项")
  let third = @moonui.Widget::label(b, "第三项")
  let declared = @moonui.Widget::column(b, 6.0, [first])
    .with_children([second, third])
    .with_spacing(8.0)
  let imperative_first = @moonui.Widget::label(b, "第一项")
  let imperative_second = @moonui.Widget::label(b, "第二项")
  let imperative_third = @moonui.Widget::label(b, "第三项")
  let imperative = @moonui.Widget::column(b, 6.0, [imperative_first])
  imperative.add_child(imperative_second)
  imperative.add_child(imperative_third)
  imperative.set_spacing(8.0)
  assert_eq(declared.children().length(), 3)
  assert_eq(declared.spacing(), imperative.spacing())
  // 同整棵树那条的规矩：各挂各的窗口，绝对 frame 才是同一把尺
  let win_d = app.create_window(
    "追加声明式",
    @moonui.LogicalSize(800.0, 600.0),
  )
  win_d.set_content(declared)
  win_d.show()
  let win_i = app.create_window(
    "追加命令式",
    @moonui.LogicalSize(800.0, 600.0),
  )
  win_i.set_content(imperative)
  win_i.show()
  assert_same_tree(declared, imperative)
}

///|
/// 无障碍链与 `set_access_*` 同账：覆盖值落在同三个格上，§32 推导出的
/// 生效视图（现读的 role / label / description）逐位相同。
test "无障碍链：与 set_access 同账" {
  let app = api_app()
  let b = app.backend()
  let declared = @moonui.Widget::label(b, "用户名")
    .with_access_role(Some(@moonui.ListItem))
    .with_access_label(Some("登录用户"))
    .with_access_description(Some("当前已登录的用户"))
  let imperative = @moonui.Widget::label(b, "用户名")
  imperative.set_access_role(Some(@moonui.ListItem))
  imperative.set_access_label(Some("登录用户"))
  imperative.set_access_description(Some("当前已登录的用户"))
  let declared_view = declared.accessibility()
  let imperative_view = imperative.accessibility()
  assert_true(declared_view is Some(_))
  assert_eq(declared.style(), imperative.style())
  match (declared_view, imperative_view) {
    (Some(da), Some(ci)) => {
      assert_eq(da.role, ci.role)
      assert_eq(da.label, ci.label)
      assert_eq(da.description, ci.description)
    }
    _ => assert_true(false)
  }
}

///|
/// 整张样式覆盖（`.with_style`）与逐格外观链是同一张表的两条写法：
/// 从空白局部样式出发，读回同值；种类守卫与标脏账同在被包裹的
/// `set_style` 一处。
test "with_style 与外观链读回同值" {
  let app = api_app()
  let b = app.backend()
  let declared = @moonui.Widget::label(b, "整张").with_style(
    Some(@moonui.style(font_size=Some(14.0), opacity=Some(0.8))),
  )
  let imperative = @moonui.Widget::label(b, "整张")
    .font_size(14.0)
    .opacity(0.8)
  assert_eq(declared.style(), imperative.style())
  assert_eq(
    declared.style(),
    Some(@moonui.style(font_size=Some(14.0), opacity=Some(0.8))),
  )
}
