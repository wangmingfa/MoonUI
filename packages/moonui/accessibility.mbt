///|
/// Accessibility（设计文档 §32）。
///
/// §32 的原话是"第一版不必完整实现，但架构必须预留"五个口子：Role / Label /
/// Description / State / Actions。这一层就是把那五个口子落地成一份**与平台无关的
/// 无障碍视图**：Core 从控件树算出它，后端将来只负责翻译成 UIA / NSAccessibility /
/// AT-SPI（§20~§22），不需要再改动 Widget，也不需要 Demo 重新登记语义。
///
/// 三条刻意的取舍，都是为了让将来接真实后端时不必返工：
/// - State 只收 Core 今天能诚实读出的三项（visible / enabled / checked）。焦点属于
///   原生层——mock 没有焦点概念，真实后端的焦点链也只有原生层知道，所以现在填一个
///   永远为 false 的 `focused` 只会骗读的人。§20 接上原生焦点时再加。
/// - Actions 不手工登记，而是拿样本事件去问每个 handler 的 `accept` 过滤器（§10）。
///   另存一份"本控件支持哪些操作"迟早和真实订阅漂移，跟 Demo 里勾选框文案必须从
///   `selected` 现读是同一个原则：状态只有一份来源。
/// - 纯布局节点（§14）默认不进视图：Row/Column/Padding 没有语义、也没有原生对象，
///   读屏器不该看见它们。但 Demo 可以给某个容器**显式声明** Role（把列表的 Column
///   标成 `List`），这样 §17 的 TreeView/DataGrid 即使全用布局节点拼出来，也能有
///   一套说得出口的结构。

///|
/// §32 的 Role。前四个是 §13 四类基础控件的默认映射；`Group`/`List`/`ListItem`
/// 给容器与 §17 的自定义控件用；`Window` 是窗口根节点预留的名字——它要等后端补出
/// 窗口标题/可见性的读取通道（§20）才有可信的 State，现在造出来只能填假值。
pub(all) enum AccessRole {
  Text
  Button
  CheckBox
  TextBox
  Group
  List
  ListItem
  Window
} derive(Debug, Eq)

///|
/// §32 的 State。`checked` 只在复选框上是 `Some`，其余种类是 `None`——
/// "没有勾选态"和"未勾选"是两回事，读屏器播报的区别正在这里。
pub(all) struct AccessState {
  visible : Bool
  enabled : Bool
  checked : Bool?
} derive(Debug, Eq)

///|
/// §32 的 Actions：辅助技术可以直接对本控件执行的操作。
///
/// 每个动作对应一条已订阅的事件：`Press` 对 `Click`、`Toggle` 对 `Change`、
/// `SetValue` 对 `Input`。没有对应订阅就没有对应动作——读屏器按下"执行"却发现
/// 无人处理，比看不见这个按钮更糟。
pub(all) enum AccessAction {
  Press
  Toggle
  SetValue
} derive(Debug, Eq)

///|
/// 一个控件的无障碍节点。
///
/// `id` 是叶子控件的原生句柄 id（与 §10 的 `EventTarget.id` 同源，见 §6 的全局
/// 句柄表），后端据此把节点对回原生对象；显式声明角色的布局节点没有原生对象，
/// 因此是 `None`。
pub(all) struct Accessibility {
  id : Int?
  role : AccessRole
  label : String
  description : String
  state : AccessState
  actions : Array[AccessAction]
} derive(Debug, Eq)

///|
/// §13 的种类到 §32 角色的默认映射；布局节点没有默认角色。
pub fn WidgetKind::default_role(self : WidgetKind) -> AccessRole? {
  match self {
    WidgetKind::Label => Some(Text)
    WidgetKind::Button => Some(Button)
    WidgetKind::TextInput => Some(TextBox)
    WidgetKind::Checkbox => Some(CheckBox)
    WidgetKind::Row
    | WidgetKind::Column
    | WidgetKind::Padding
    | WidgetKind::Spacer
    | WidgetKind::Center
    | WidgetKind::Stack
    | WidgetKind::Grid
    | WidgetKind::Scroll => None
  }
}

///|
/// 用样本事件问一遍过滤器：只要有一个 handler 放行，该动作就成立。
///
/// 过滤器按事件变体匹配（§10 的糖都是这么写的），载荷取什么都不影响结论，
/// 因此 `on_any` 这种全放行的订阅会一次给出三个动作。
fn accepts(probes : Array[(Event) -> Bool], ev : Event) -> Bool {
  let mut hit = false
  for f in probes {
    if f(ev) {
      hit = true
    }
  }
  hit
}

///|
/// 由已订阅的事件推导 Actions，顺序固定为 Press / Toggle / SetValue，
/// 这样同一棵树每次算出的视图一致，测试可以直接断言整个数组。
pub fn accessibility_actions(
  probes : Array[(Event) -> Bool],
  id : Int,
) -> Array[AccessAction] {
  let t = EventTarget::{ id, }
  let out : Array[AccessAction] = []
  if accepts(probes, Event::Click(t, MouseButton::Left)) {
    out.push(Press)
  }
  if accepts(probes, Event::Change(t)) {
    out.push(Toggle)
  }
  if accepts(probes, Event::Input(t, "")) {
    out.push(SetValue)
  }
  out
}

///|
/// 控件的无障碍节点；没有任何角色（未声明角色的布局节点）时是 `None`。
///
/// Label 的取法：显式声明优先，否则文本类控件用自己的文本。`TextInput` 的文本是
/// **值**而不是名字，所以登录表单这类输入框必须走显式 `set_access_label`
/// （"用户名"/"密码"），否则焦点落在空输入框上时读屏器只能念出当前值。
pub fn[B : Backend] Widget::accessibility(
  self : Widget[B],
) -> Accessibility? raise UiError {
  let role = match self.access_role {
    Some(r) => Some(r)
    None => self.kind.default_role()
  }
  match role {
    None => None
    Some(r) => {
      let label = match self.access_label {
        Some(s) => s
        None => self.text_or_empty()
      }
      let description = match self.access_description {
        Some(s) => s
        None => ""
      }
      let checked = if self.kind == WidgetKind::Checkbox {
        Some(self.checked())
      } else {
        None
      }
      let id = match self.handle {
        None => None
        Some(h) => Some(h.id)
      }
      // 样本事件的 target 只用来喂过滤器，过滤器按事件变体匹配，
      // 所以布局节点（没有句柄）用 -1 也能得到同样的结论。
      let probe_id = match id {
        Some(i) => i
        None => -1
      }
      Some(Accessibility::{
        id,
        role: r,
        label,
        description,
        state: AccessState::{
          visible: self.visible(),
          enabled: self.enabled(),
          checked,
        },
        actions: accessibility_actions(
          self.handlers.map(h => h.accept),
          probe_id,
        ),
      })
    }
  }
}

///|
/// 内容树的无障碍视图，先序（与 §14 的绘制顺序、§18 的渲染顺序一致）。
///
/// 展平成序列而不是给一棵树：辅助技术要的是一维可读顺序，而 Core 的树里大部分
/// 容器没有角色，跳过它们才能让"列表标题、每个条目、状态栏"按视觉顺序连续出现。
pub fn[B : Backend] Widget::accessibility_tree(
  self : Widget[B],
) -> Array[Accessibility] raise UiError {
  let out : Array[Accessibility] = []
  self.collect_accessibility(out)
  out
}

///|
fn[B : Backend] Widget::collect_accessibility(
  self : Widget[B],
  out : Array[Accessibility],
) -> Unit raise UiError {
  match self.accessibility() {
    Some(a) => out.push(a)
    None => ()
  }
  for c in self.children {
    c.collect_accessibility(out)
  }
}

///|
/// 文本类控件的文本，其余种类为空串。判定和 `default_role` 共用一处，
/// 避免两处对"哪些种类有文本"各执一词。
fn[B : Backend] Widget::text_or_empty(self : Widget[B]) -> String raise UiError {
  match self.kind.default_role() {
    Some(_) => self.text()
    None => ""
  }
}

///|
/// 声明本控件在无障碍视图里的角色；纯布局节点只有走过这里才会进视图。
/// 传 `None` 表示回到"按种类默认"，对布局节点即等于退出视图。
pub fn[B] Widget::set_access_role(
  self : Widget[B],
  role : AccessRole?,
) -> Unit raise UiError {
  self.check_open()
  self.access_role = role
}

///|
pub fn[B] Widget::access_role(self : Widget[B]) -> AccessRole? {
  self.access_role
}

///|
/// 覆盖朗读名称。文本类控件不覆盖就是自己的文本，容器与自定义控件必须覆盖。
pub fn[B] Widget::set_access_label(
  self : Widget[B],
  label : String?,
) -> Unit raise UiError {
  self.check_open()
  self.access_label = label
}

///|
pub fn[B] Widget::access_label(self : Widget[B]) -> String? {
  self.access_label
}

///|
/// §32 的 Description：补充说明（格式要求、快捷键等），不参与布局也不影响事件。
pub fn[B] Widget::set_access_description(
  self : Widget[B],
  desc : String?,
) -> Unit raise UiError {
  self.check_open()
  self.access_description = desc
}

///|
pub fn[B] Widget::access_description(self : Widget[B]) -> String? {
  self.access_description
}

///|
/// 测试用：取控件的无障碍节点。缺角色是框架自身的错误而不是测试期望，
/// 所以走 §33 的错误类型而不是 panic——测试块的 raise 上下文会自然传播，
/// 失败信息同样可读。
fn[B : Backend] node_of(w : Widget[B]) -> Accessibility raise UiError {
  match w.accessibility() {
    Some(a) => a
    None => raise Unsupported("该控件没有无障碍角色")
  }
}

///|
/// 测试用：取窗口的内容树根节点，没有内容就报不支持。
/// 无障碍视图的入口是内容树（窗口根节点要等 §20 的后端读取通道才有可信 State）。
fn[B] window_content(w : Window[B]) -> Widget[B] raise UiError {
  match w.content() {
    Some(c) => c
    None => raise Unsupported("窗口还没有内容树")
  }
}

///|
/// 测试用：从公开的 `handle()` 访问器取叶子控件的句柄 id，用来对照视图里的 id
/// 是不是同一个（而不是把内部推导逻辑抄一遍，那样断言就成了自证）。
fn[B] leaf_id(w : Widget[B]) -> Int? {
  match w.handle {
    Some(h) => Some(h.id)
    None => None
  }
}

///|
/// §32 的 Role/Label/State 默认映射：四类控件各有角色，勾选态只属于复选框。
test "四类基础控件的默认角色与状态" {
  let b = mock_widgets()
  let lbl = Widget::label(b, "Hello MoonUI")
  let btn = Widget::button(b, "增加")
  let inp = Widget::text_input(b, "abc")
  let chk = Widget::checkbox(b, "记住我", true)

  let a = node_of(lbl)
  assert_eq(a.role, Text)
  assert_eq(a.label, "Hello MoonUI")
  assert_eq(a.description, "")
  assert_eq(a.state, AccessState::{
    visible: true,
    enabled: true,
    checked: None,
  })
  assert_eq(a.actions, [])
  // 句柄 id 与控件一致，后端将来靠它对回原生对象
  assert_eq(a.id, leaf_id(lbl))

  let ab = node_of(btn)
  assert_eq(ab.role, Button)
  assert_eq(ab.label, "增加")
  let ai = node_of(inp)
  assert_eq(ai.role, TextBox)
  // 没声明 Label 时朗读当前值——真实表单必须靠 set_access_label 锁定字段名
  assert_eq(ai.label, "abc")
  let ac = node_of(chk)
  assert_eq(ac.role, CheckBox)
  assert_eq(ac.state, AccessState::{
    visible: true,
    enabled: true,
    checked: Some(true),
  })
}

///|
/// §32 的 Actions：动作来自已订阅的事件，不是另登一份名册。
test "Actions 由事件订阅推导（§10 Event First）" {
  let b = mock_widgets()
  let btn = Widget::button(b, "增加")
  let _ = btn.on_click(fn() raise UiError { btn.set_text("增加 1") })
  assert_eq(node_of(btn).actions, [Press])
  // 再挂双击订阅不增加动作：辅助技术没有"双击"这个可执行操作，
  // 把用户代码的每条订阅都当成动作等于向读屏器撒谎。
  let _ = btn.on_double_click(fn() raise UiError { btn.set_text("双击") })
  assert_eq(node_of(btn).actions, [Press])

  let chk = Widget::checkbox(b, "记住我", false)
  let _ = chk.on_change(fn() raise UiError { chk.set_checked(true) })
  assert_eq(node_of(chk).actions, [Toggle])

  let inp = Widget::text_input(b, "")
  let _ = inp.on_input(fn(t) raise UiError { inp.set_text(t) })
  assert_eq(node_of(inp).actions, [SetValue])

  // 没有订阅就没有动作：按钮存在但按不动，视图必须如实反映
  let idle = Widget::button(b, "占位")
  assert_eq(node_of(idle).actions, [])
}

///|
/// §14 与 §32 的交界：布局节点默认不进视图，显式声明角色才进，
/// 且进了也没有原生 id（它本来就没有原生对象）。
test "布局节点默认不可见，声明角色后进入视图" {
  let b = mock_widgets()
  let a = Widget::label(b, "A")
  let c = Widget::label(b, "C")
  let col = Widget::column(b, 4.0, [a, c])
  let pad = Widget::padding(b, EdgeInsets::all(8.0), col)

  assert_eq(pad.accessibility(), None)
  assert_eq(pad.accessibility_tree().length(), 2)

  col.set_access_role(Some(List))
  assert_eq(node_of(col).role, List)
  let tree = pad.accessibility_tree()
  assert_eq(tree.length(), 3)
  // 先序：容器排在自己的子项之前
  assert_eq(tree[0].role, List)
  assert_eq(tree[0].id, None)
  assert_eq(tree[1].label, "A")
  assert_eq(tree[2].label, "C")

  // 回到默认（None）等于退出视图，Label 覆盖不会跟着串味
  col.set_access_role(None)
  assert_eq(pad.accessibility_tree().length(), 2)
}

///|
/// State 读的是原生真相：禁用、隐藏、勾选变化立刻反映到节点上；容器隐藏
/// 整棵子树后，子节点的 visible 也是 false（§14 的递归可见性）。
test "State 跟随原生状态，容器隐藏整棵子树" {
  let b = mock_widgets()
  let ok = Widget::button(b, "登录")
  let chk = Widget::checkbox(b, "记住我", false)
  let row = Widget::row(b, 6.0, [ok, chk])
  let tree = Widget::column(b, 0.0, [row])

  ok.set_enabled(false)
  assert_eq(node_of(ok).state, AccessState::{
    visible: true,
    enabled: false,
    checked: None,
  })
  chk.set_checked(true)
  assert_eq(node_of(chk).state.checked, Some(true))

  tree.set_visible(false)
  assert_false(node_of(ok).state.visible)
  // 子树销毁后不能再读节点（§8 所有权 + §33 不吞异常）
  tree.close_tree()
  assert_eq(
    widget_error(fn() raise UiError { let _ = ok.accessibility() }),
    Some("对象已销毁"),
  )
}

///|
/// Label/Description 的覆盖语义：显式声明优先于文本，取消覆盖回到文本。
/// 空标题输入框全靠这条路，否则读屏器念不出字段名。
test "显式 Label 与 Description 覆盖默认值" {
  let b = mock_widgets()
  let user = Widget::text_input(b, "")
  user.set_access_label(Some("用户名"))
  user.set_access_description(Some("最多 32 个字符"))
  let node = node_of(user)
  assert_eq(node.label, "用户名")
  assert_eq(node.description, "最多 32 个字符")
  // 用户改了输入内容，朗读名称仍锁定在字段名上，不跟着值漂移
  user.set_text("admin")
  assert_eq(node_of(user).label, "用户名")
  user.set_access_label(None)
  assert_eq(node_of(user).label, "admin")
  user.set_access_description(None)
  assert_eq(node_of(user).description, "")
}

///|
/// 推导只看过滤器，因此 `on_any` 三个动作一次成立；控件销毁后 handler 链清空，
/// 视图也就报不出任何可执行动作（§47 风险 1 的闭包泄漏在这里同样有可断言的痕迹）。
test "on_any 放行全部动作，销毁后不再有动作" {
  let b = mock_widgets()
  let w = Widget::button(b, "全量监听")
  let _ = w.on_any(fn(_) raise UiError { w.set_text("收到事件") })
  assert_eq(node_of(w).actions, [Press, Toggle, SetValue])
  w.close_tree()
  assert_eq(w.handler_count(), 0)
  let no_probes : Array[(Event) -> Bool] = []
  assert_eq(accessibility_actions(no_probes, 3), [])
}

///|
/// 视图是一条按视觉顺序展开的序列：这里用 §49 Login 的形状（两个输入框 +
/// 记住我 + 提交）验证顺序、角色、动作与 id，因为后端将来就是靠 id 把节点对回
/// 原生控件（§6 的全局句柄表）。
test "整棵内容树按视觉顺序展开，id 与原生句柄一致" {
  let b = mock_widgets()
  let user = Widget::text_input(b, "")
  user.set_access_label(Some("用户名"))
  let pwd = Widget::text_input(b, "")
  pwd.set_access_label(Some("密码"))
  let remember = Widget::checkbox(b, "记住我", false)
  let _ = remember.on_change(fn() raise UiError { remember.set_checked(true) })
  let submit = Widget::button(b, "登录")
  let _ = submit.on_click(fn() raise UiError { submit.set_text("提交中") })
  let form = Widget::column(b, 6.0, [
    user,
    pwd,
    Widget::spacer(b),
    remember,
    submit,
  ])

  let nodes = form.accessibility_tree()
  // Spacer 是布局节点、没有角色，不进视图
  assert_eq(nodes.length(), 4)
  assert_eq(nodes.map(n => n.label), [
    "用户名", "密码", "记住我", "登录",
  ])
  assert_eq(nodes.map(n => n.role), [TextBox, TextBox, CheckBox, Button])
  assert_eq(nodes.map(n => n.actions), [[], [], [Toggle], [Press]])
  assert_eq(nodes.map(n => n.id), [
    leaf_id(user),
    leaf_id(pwd),
    leaf_id(remember),
    leaf_id(submit),
  ])
}
