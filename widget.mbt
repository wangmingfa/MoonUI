///|
/// Widget（设计文档 §13、§8、§9，开发顺序 §48 第 10~15 步）。
///
/// 本版本 MoonBit 没有 `dyn`，`children` 装不下异构的 trait 对象，所以 Widget 用
/// **单结构体 + 种类标签**：所有 §13 列出的基础能力（visible / enabled / width /
/// height / position / style / parent / children / event handlers）都是这张表上的
/// 字段和方法。代价是种类错误（比如给 Label 设勾选状态）只能在运行期靠
/// `Unsupported` 拦住，编译期不管——这是当前工具链下换整棵异构树的唯一可行形态。
///
/// §14 的另一条决定在这里落地：Row/Column/Padding/Center/Spacer 是 **纯布局节点**，
/// 不占原生对象。布局由 MoonUI 自己算绝对边界，所有叶子控件的原生父级都是窗口。
/// libui-ng 的 uiBox 是堆叠式容器，塞不进这套绝对定位模型，所以后端只需要
/// `attach_widget(window, child)` 一个挂接动作（§20 接上时可以直接验证这一点）。

///|
pub(all) enum WidgetKind {
  Label
  Button
  TextInput
  Checkbox
  Row
  Column
  Padding
  Spacer
  Center
  Stack
  Grid
  Scroll
} derive(Debug, Eq)

///|
/// 纯布局节点没有原生对象，其余种类都必须向后端要一个句柄。
///
/// `Scroll` 暂时也归为纯布局节点：Core 只保证"内容按完整尺寸摆好、可以超出视口"，
/// 真正的裁剪与滚动条属于后端。等 §20 接上 libui-ng 的 uiScrollContainer（或 §21
/// 的 SDL3 Scroll）时，这里要改成"占用一个原生对象"，并给 `attach_widget` 增加
/// 容器父级的概念——那是后端层的改动，不该在没有原生库时假装完成。
pub fn WidgetKind::is_layout_only(self : WidgetKind) -> Bool {
  match self {
    WidgetKind::Row
    | WidgetKind::Column
    | WidgetKind::Padding
    | WidgetKind::Spacer
    | WidgetKind::Center
    | WidgetKind::Stack
    | WidgetKind::Grid
    | WidgetKind::Scroll => true
    _ => false
  }
}

///|
/// 一条控件侧的事件订阅（§9 的 Widget └ EventHandlers）。
/// `accept` 是事件过滤器：`on_click` 只放行 `Click`，`on_any_event` 全放行。
pub(all) struct HandlerEntry {
  id : Int
  accept : (Event) -> Bool
  call : (Event) -> Unit raise UiError
}

///|
pub struct Widget[B] {
  backend : B
  mut handle : NativeHandle?
  kind : WidgetKind
  mut frame : LogicalRect
  mut expand : Bool
  mut spacing : Double
  mut insets : EdgeInsets
  mut columns : Int
  mut axis : Axis
  mut style : Style?
  mut children : Array[Widget[B]]
  mut parent : Widget[B]?
  mut attached : Bool
  mut closed : Bool
  mut handlers : Array[HandlerEntry]
  mut next_handler_id : Int
}

///|
fn[B : Backend] Widget::make(
  backend : B,
  kind : WidgetKind,
  text : String,
) -> Widget[B] raise UiError {
  let handle = if kind.is_layout_only() {
    None
  } else {
    Some(Backend::create_widget(backend, kind, text))
  }
  Widget::{
    backend,
    handle,
    kind,
    frame: LogicalRect::{
      origin: LogicalPoint::{ x: 0.0, y: 0.0, },
      size: LogicalSize::zero(),
    },
    expand: false,
    spacing: 0.0,
    insets: EdgeInsets::zero(),
    columns: 1,
    axis: Vertical,
    style: None,
    children: [],
    parent: None,
    attached: false,
    closed: false,
    handlers: [],
    next_handler_id: 0,
  }
}

///|
pub fn[B : Backend] Widget::label(
  backend : B,
  text : String,
) -> Widget[B] raise UiError {
  Widget::make(backend, WidgetKind::Label, text)
}

///|
pub fn[B : Backend] Widget::button(
  backend : B,
  text : String,
) -> Widget[B] raise UiError {
  Widget::make(backend, WidgetKind::Button, text)
}

///|
pub fn[B : Backend] Widget::text_input(
  backend : B,
  text : String,
) -> Widget[B] raise UiError {
  Widget::make(backend, WidgetKind::TextInput, text)
}

///|
pub fn[B : Backend] Widget::checkbox(
  backend : B,
  text : String,
  checked : Bool,
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Checkbox, text)
  w.set_checked(checked)
  w
}

///|
/// 横向容器（§14）。`spacing` 只加在相邻子项之间。
pub fn[B : Backend] Widget::row(
  backend : B,
  spacing : Double,
  children : Array[Widget[B]],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Row, "")
  w.spacing = spacing
  for c in children {
    w.add_child(c)
  }
  w
}

///|
/// 纵向容器（§14）。
pub fn[B : Backend] Widget::column(
  backend : B,
  spacing : Double,
  children : Array[Widget[B]],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Column, "")
  w.spacing = spacing
  for c in children {
    w.add_child(c)
  }
  w
}

///|
pub fn[B : Backend] Widget::padding(
  backend : B,
  insets : EdgeInsets,
  child : Widget[B],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Padding, "")
  w.insets = insets
  w.add_child(child)
  w
}

///|
pub fn[B : Backend] Widget::center(
  backend : B,
  child : Widget[B],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Center, "")
  w.add_child(child)
  w
}

///|
/// 弹性占位：把主轴剩余空间均分给各个 Spacer（§14）。
pub fn[B : Backend] Widget::spacer(backend : B) -> Widget[B] raise UiError {
  Widget::make(backend, WidgetKind::Spacer, "")
}

///|
/// 叠放容器（§14）：子项共用同一个原点，数组靠后的画在上层。
pub fn[B : Backend] Widget::stack(
  backend : B,
  children : Array[Widget[B]],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Stack, "")
  for c in children {
    w.add_child(c)
  }
  w
}

///|
/// 均匀网格（§14）。`columns` 小于 1 按 1 处理、负间距按 0 处理，
/// 夹紧规则和布局引擎共用同一套语义，避免两处各说各话。
pub fn[B : Backend] Widget::grid(
  backend : B,
  columns : Int,
  spacing : Double,
  children : Array[Widget[B]],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Grid, "")
  w.columns = if columns < 1 { 1 } else { columns }
  w.spacing = if spacing < 0.0 { 0.0 } else { spacing }
  for c in children {
    w.add_child(c)
  }
  w
}

///|
/// 滚动视口（§14）。内容按完整尺寸摆放、可以超出框架；裁剪与滚动条属于
/// 后端（§20/§21），所以这里不存滚动偏移——Core 存了也不会生效，反而骗人。
pub fn[B : Backend] Widget::scroll(
  backend : B,
  axis : Axis,
  child : Widget[B],
) -> Widget[B] raise UiError {
  let w = Widget::make(backend, WidgetKind::Scroll, "")
  w.axis = axis
  w.add_child(child)
  w
}

///|
pub fn[B] Widget::kind(self : Widget[B]) -> WidgetKind {
  self.kind
}

///|
pub fn[B] Widget::handle(self : Widget[B]) -> NativeHandle? {
  self.handle
}

///|
/// 事件订阅用的目标 id。纯布局节点收不到原生事件，因此没有 target。
pub fn[B] Widget::target(self : Widget[B]) -> EventTarget raise UiError {
  match self.handle {
    Some(h) => EventTarget::{ id: h.id, }
    None =>
      raise Unsupported("布局节点没有原生对象，不能订阅事件")
  }
}

///|
pub fn[B] Widget::is_closed(self : Widget[B]) -> Bool {
  self.closed
}

///|
pub fn[B] Widget::is_attached(self : Widget[B]) -> Bool {
  self.attached
}

///|
pub fn[B] Widget::children(self : Widget[B]) -> Array[Widget[B]] {
  self.children
}

///|
pub fn[B] Widget::parent(self : Widget[B]) -> Widget[B]? {
  self.parent
}

///|
pub fn[B] Widget::check_open(self : Widget[B]) -> Unit raise UiError {
  if self.closed {
    raise Destroyed
  }
}

///|
/// 取原生句柄。布局节点在这里报 `Unsupported`，绝不把空句柄递到后端。
fn[B] Widget::need_handle(self : Widget[B]) -> NativeHandle raise UiError {
  self.check_open()
  match self.handle {
    Some(h) => h
    None => raise Unsupported("布局节点没有原生对象")
  }
}

///|
/// 文本类控件才有文本（§13）。种类不符时是明确错误，不是静默无效。
fn[B] Widget::check_text_kind(self : Widget[B]) -> Unit raise UiError {
  match self.kind {
    WidgetKind::Label
    | WidgetKind::Button
    | WidgetKind::TextInput
    | WidgetKind::Checkbox => ()
    _ => raise Unsupported("该控件没有文本属性")
  }
}

///|
pub fn[B : Backend] Widget::text(self : Widget[B]) -> String raise UiError {
  self.check_text_kind()
  Backend::widget_text(self.backend, self.need_handle())
}

///|
pub fn[B : Backend] Widget::set_text(
  self : Widget[B],
  text : String,
) -> Unit raise UiError {
  self.check_text_kind()
  Backend::set_widget_text(self.backend, self.need_handle(), text)
}

///|
pub fn[B : Backend] Widget::checked(self : Widget[B]) -> Bool raise UiError {
  Backend::widget_checked(self.backend, self.need_handle())
}

///|
pub fn[B : Backend] Widget::set_checked(
  self : Widget[B],
  v : Bool,
) -> Unit raise UiError {
  Backend::set_widget_checked(self.backend, self.need_handle(), v)
}

///|
/// 可见性对容器生效意味着整棵子树一起隐藏——叶子控件的原生父级是窗口，
/// 容器本身没有原生对象可以藏，所以必须自己递归。
pub fn[B : Backend] Widget::set_visible(
  self : Widget[B],
  v : Bool,
) -> Unit raise UiError {
  self.check_open()
  match self.handle {
    Some(h) => Backend::set_widget_visible(self.backend, h, v)
    None => ()
  }
  for c in self.children {
    c.set_visible(v)
  }
}

///|
/// 读取可见性：容器返回"子树是否全部可见"，叶子读原生状态。
pub fn[B : Backend] Widget::visible(self : Widget[B]) -> Bool raise UiError {
  self.check_open()
  let own = match self.handle {
    Some(h) => Backend::widget_visible(self.backend, h)
    None => true
  }
  let mut all = own
  for c in self.children {
    if !c.visible() {
      all = false
    }
  }
  all
}

///|
pub fn[B : Backend] Widget::set_enabled(
  self : Widget[B],
  v : Bool,
) -> Unit raise UiError {
  self.check_open()
  match self.handle {
    Some(h) => Backend::set_widget_enabled(self.backend, h, v)
    None => ()
  }
}

///|
pub fn[B : Backend] Widget::enabled(self : Widget[B]) -> Bool raise UiError {
  self.check_open()
  match self.handle {
    Some(h) => Backend::widget_enabled(self.backend, h)
    None => true
  }
}

///|
pub fn[B] Widget::expand(self : Widget[B]) -> Bool {
  self.expand
}

///|
/// `expand=true` 的叶子与 `Spacer` 一起参与弹性分配（§14）。
pub fn[B] Widget::set_expand(self : Widget[B], v : Bool) -> Unit raise UiError {
  self.check_open()
  if self.kind == WidgetKind::Spacer && !v {
    raise Unsupported("Spacer 本身就是弹性项")
  }
  self.expand = v
}

///|
pub fn[B] Widget::spacing(self : Widget[B]) -> Double raise UiError {
  self.check_open()
  match self.kind {
    WidgetKind::Row | WidgetKind::Column | WidgetKind::Grid => self.spacing
    _ => raise Unsupported("只有 Row/Column/Grid 有间距")
  }
}

///|
pub fn[B] Widget::set_spacing(
  self : Widget[B],
  v : Double,
) -> Unit raise UiError {
  self.check_open()
  match self.kind {
    WidgetKind::Row | WidgetKind::Column | WidgetKind::Grid =>
      self.spacing = if v < 0.0 { 0.0 } else { v }
    _ => raise Unsupported("只有 Row/Column/Grid 有间距")
  }
}

///|
/// Grid 的列数（其余种类没有这个属性）。
pub fn[B] Widget::columns(self : Widget[B]) -> Int raise UiError {
  self.check_open()
  match self.kind {
    WidgetKind::Grid => self.columns
    _ => raise Unsupported("只有 Grid 有列数")
  }
}

///|
/// Scroll 的滚动方向（其余种类没有轴向）。
pub fn[B] Widget::axis(self : Widget[B]) -> Axis raise UiError {
  self.check_open()
  match self.kind {
    WidgetKind::Scroll => self.axis
    _ => raise Unsupported("只有 Scroll 有滚动方向")
  }
}

///|
pub fn[B] Widget::insets(self : Widget[B]) -> EdgeInsets raise UiError {
  self.check_open()
  match self.kind {
    WidgetKind::Padding => self.insets
    _ => raise Unsupported("只有 Padding 有内边距")
  }
}

///|
pub fn[B] Widget::set_insets(
  self : Widget[B],
  v : EdgeInsets,
) -> Unit raise UiError {
  self.check_open()
  match self.kind {
    WidgetKind::Padding => self.insets = v
    _ => raise Unsupported("只有 Padding 有内边距")
  }
}

///|
pub fn[B] Widget::style(self : Widget[B]) -> Style? {
  self.style
}

///|
/// 局部样式覆盖（§15）。这里只存"这一层要覆盖什么"，
/// 真正的生效值由 `resolved_style` 沿祖先链算出来。
pub fn[B] Widget::set_style(self : Widget[B], s : Style?) -> Unit raise UiError {
  self.check_open()
  self.style = s
}

///|
/// 样式层叠解析（§15/§16）：Theme 默认样式 -> 祖先链（由外向内）-> 自身。
/// `base` 来自 `App::style_base`；每层只覆盖显式设置的字段。
///
/// 祖先链不会成环：进入树里的控件都被标了 `attached`，而 `add_child` 与
/// `Window::set_content` 都拒绝已归属的控件，所以这里不需要访问标记。
pub fn[B] Widget::resolved_style(self : Widget[B], base : Style) -> Style {
  let inherited = match self.parent {
    Some(p) => p.resolved_style(base)
    None => base
  }
  let own = match self.style {
    Some(s) => s
    None => Style::empty()
  }
  inherited.layer(own)
}

///|
pub fn[B] Widget::frame(self : Widget[B]) -> LogicalRect {
  self.frame
}

///|
/// 绝对边界（逻辑像素）：Core 记下它，叶子同时推给后端。
pub fn[B : Backend] Widget::set_bounds(
  self : Widget[B],
  rect : LogicalRect,
) -> Unit raise UiError {
  self.check_open()
  let r = rect.normalized()
  self.frame = r
  match self.handle {
    Some(h) => Backend::set_widget_bounds(self.backend, h, r)
    None => ()
  }
}

///|
pub fn[B : Backend] Widget::bounds(
  self : Widget[B],
) -> LogicalRect raise UiError {
  self.check_open()
  match self.handle {
    Some(h) => Backend::widget_bounds(self.backend, h)
    None => self.frame
  }
}

///|
/// 原生固有尺寸：叶子问后端（字体度量属于原生层，§18），布局节点为零。
pub fn[B : Backend] Widget::intrinsic_size(
  self : Widget[B],
) -> LogicalSize raise UiError {
  match self.handle {
    Some(h) => Backend::widget_intrinsic_size(self.backend, h)
    None => LogicalSize::zero()
  }
}

///|
/// 挂接子控件（§8）。已被持有的控件不能二次归属，否则窗口销毁时会出现
/// 两个父级各自销毁同一个原生对象——文档 §47 风险 2 的另一种形态。
pub fn[B] Widget::add_child(
  self : Widget[B],
  child : Widget[B],
) -> Unit raise UiError {
  self.check_open()
  if self.kind == WidgetKind::Spacer {
    raise Unsupported("Spacer 不能有子控件")
  }
  if child.closed {
    raise Destroyed
  }
  if child.attached {
    raise AlreadyOwned
  }
  child.attached = true
  child.parent = Some(self)
  self.children.push(child)
}

///|
/// 销毁控件：先销毁叶子（原生对象在这里消失），再清 Core 引用。
/// 子树整棵一起关闭，因为 §8 的所有权是"容器持有子项"。
/// 0.1 不提供"从父级摘下单个控件"——那需要控件的引用身份比较，等 §40 的
/// 动态列表真要用时再设计，避免现在塞进一个语义含糊的 API。
pub fn[B : Backend] Widget::close_tree(self : Widget[B]) -> Unit raise UiError {
  if self.closed {
    raise Destroyed
  }
  for c in self.children {
    c.close_tree()
  }
  self.children = []
  match self.handle {
    Some(h) => {
      Backend::destroy_widget(self.backend, h)
      self.handle = None
    }
    None => ()
  }
  self.handlers = []
  self.parent = None
  self.attached = false
  self.closed = true
}

///|
/// 树中叶子控件数（含自身），用来断言"销毁后后端句柄归零"。
pub fn[B] Widget::leaf_count(self : Widget[B]) -> Int {
  let mut n = match self.handle {
    Some(_) => 1
    None => 0
  }
  for c in self.children {
    n = n + c.leaf_count()
  }
  n
}

///|
/// 收集子树里所有叶子的原生句柄，供 `Window::set_content` 挂接到窗口（§8）。
/// 布局节点没有句柄，因此不出现在结果里——这正是 §14 那条决定的直接体现。
fn[B] Widget::collect_native(
  self : Widget[B],
  out : Array[NativeHandle],
) -> Unit {
  match self.handle {
    Some(h) => out.push(h)
    None => ()
  }
  for c in self.children {
    c.collect_native(out)
  }
}

///|
/// 沿 Core 树找叶子控件；`do_layout` 用它把算好的矩形写回控件。
/// id 来自全局句柄表，所以窗口与控件不会互相冒充（§6）。
pub fn[B] Widget::find_by_id(self : Widget[B], id : Int) -> Widget[B]? {
  match self.handle {
    Some(mine) =>
      if mine.id == id {
        Some(self)
      } else {
        lookup_children(self.children, id)
      }
    None => lookup_children(self.children, id)
  }
}

///|
fn[B] lookup_children(children : Array[Widget[B]], id : Int) -> Widget[B]? {
  let mut found : Widget[B]? = None
  for c in children {
    match c.find_by_id(id) {
      Some(w) => found = Some(w)
      None => ()
    }
  }
  found
}

///|
/// 接入 §14 的布局引擎：控件树 -> LayoutSpec。
/// 叶子的固有尺寸来自后端测量，容器用 Core 侧的 spacing/insets。
pub fn[B : Backend] Widget::to_layout_spec(
  self : Widget[B],
) -> LayoutSpec raise UiError {
  match self.kind {
    WidgetKind::Spacer => LayoutSpec::Spacer
    WidgetKind::Row =>
      LayoutSpec::Row(LineSpec::{
        axis: Horizontal,
        spacing: self.spacing,
        children: self.child_specs(),
      })
    WidgetKind::Column =>
      LayoutSpec::Column(LineSpec::{
        axis: Vertical,
        spacing: self.spacing,
        children: self.child_specs(),
      })
    WidgetKind::Padding => {
      let child = self.only_child("Padding")
      LayoutSpec::Padding(PaddingSpec::{
        insets: self.insets,
        child: child.to_layout_spec(),
      })
    }
    WidgetKind::Center => {
      let child = self.only_child("Center")
      LayoutSpec::Center(CenterSpec::{ child: child.to_layout_spec(), })
    }
    WidgetKind::Stack =>
      LayoutSpec::Stack(StackSpec::{ children: self.child_specs(), })
    WidgetKind::Grid =>
      LayoutSpec::Grid(GridSpec::{
        columns: self.columns,
        spacing: self.spacing,
        children: self.child_specs(),
      })
    WidgetKind::Scroll => {
      let child = self.only_child("Scroll")
      LayoutSpec::Scroll(ScrollSpec::{
        axis: self.axis,
        child: child.to_layout_spec(),
      })
    }
    _ => {
      let h = self.need_handle()
      LayoutSpec::Leaf(LeafSpec::{
        id: h.id,
        intrinsic: Backend::widget_intrinsic_size(self.backend, h),
        expand: self.expand,
      })
    }
  }
}

///|
fn[B : Backend] Widget::child_specs(
  self : Widget[B],
) -> Array[LayoutSpec] raise UiError {
  let out : Array[LayoutSpec] = []
  for c in self.children {
    out.push(c.to_layout_spec())
  }
  out
}

///|
fn[B] Widget::only_child(
  self : Widget[B],
  what : String,
) -> Widget[B] raise UiError {
  if self.children.length() != 1 {
    raise OperationFailed("\{what} 必须恰好有一个子控件")
  }
  self.children[0]
}

///|
/// 测量整棵子树的固有尺寸（§14）。
pub fn[B : Backend] Widget::measure(
  self : Widget[B],
  c : BoxConstraints,
) -> LogicalSize raise UiError {
  measure(self.to_layout_spec(), c)
}

///|
/// 在给定框架内布局，把每个叶子的绝对边界写回后端（§14、§18 的公共入口）。
/// 返回值与 `layout` 的一致，方便断言。
pub fn[B : Backend] Widget::do_layout(
  self : Widget[B],
  frame : LogicalRect,
) -> Array[Placed] raise UiError {
  self.check_open()
  let placed : Array[Placed] = []
  layout(self.to_layout_spec(), frame, placed)
  for p in placed {
    match self.find_by_id(p.id) {
      Some(w) => w.set_bounds(p.frame)
      None => raise InvalidHandle
    }
  }
  placed
}

///|
/// 通用订阅：`accept` 决定放行哪些事件，返回 handler id。
/// handler 失败会沿 `dispatch` 传出，控件不吞异常（§33）。
pub fn[B] Widget::on(
  self : Widget[B],
  accept : (Event) -> Bool,
  handler : (Event) -> Unit raise UiError,
) -> Int raise UiError {
  self.check_open()
  let id = self.next_handler_id
  self.next_handler_id = id + 1
  self.handlers.push(HandlerEntry::{ id, accept, call: handler, })
  id
}

///|
/// 当前 handler 数：`close_tree` 之后应为 0（§47 风险 1 的闭包泄漏检查）。
pub fn[B] Widget::handler_count(self : Widget[B]) -> Int {
  self.handlers.length()
}

///|
/// 派发一个事件到本控件的 handler，返回调用次数。
/// 只遍历本轮开始时的长度，handler 里新加的订阅留到下一轮。
pub fn[B] Widget::fire(self : Widget[B], ev : Event) -> Int raise UiError {
  if self.closed {
    raise Destroyed
  }
  let n = self.handlers.length()
  let mut hits = 0
  for i = 0; i < n; i = i + 1 {
    let e = self.handlers[i]
    if (e.accept)(ev) {
      (e.call)(ev)
      hits = hits + 1
    }
  }
  hits
}

///|
/// §10 的高级 API：`button.on_click(...)`。种类不匹配不会报错——
/// 事件本来就可能来自任何地方，过滤器只在真的收到时放行。
pub fn[B] Widget::on_click(
  self : Widget[B],
  f : () -> Unit raise UiError,
) -> Int raise UiError {
  self.on(
    ev => {
      match ev {
        Click(_, _) => true
        _ => false
      }
    },
    fn(_) raise UiError { f() },
  )
}

///|
pub fn[B] Widget::on_double_click(
  self : Widget[B],
  f : () -> Unit raise UiError,
) -> Int raise UiError {
  self.on(
    ev => {
      match ev {
        DoubleClick(_) => true
        _ => false
      }
    },
    fn(_) raise UiError { f() },
  )
}

///|
pub fn[B] Widget::on_change(
  self : Widget[B],
  f : () -> Unit raise UiError,
) -> Int raise UiError {
  self.on(
    ev => {
      match ev {
        Change(_) => true
        _ => false
      }
    },
    fn(_) raise UiError { f() },
  )
}

///|
/// 文本变化，携带变化后的全文（§10 的 `Input`）。
pub fn[B] Widget::on_input(
  self : Widget[B],
  f : (String) -> Unit raise UiError,
) -> Int raise UiError {
  self.on(
    ev => {
      match ev {
        Input(_, _) => true
        _ => false
      }
    },
    fn(ev) raise UiError {
      match ev {
        Input(_, text) => f(text)
        _ => ()
      }
    },
  )
}

///|
pub fn[B] Widget::on_focus(
  self : Widget[B],
  f : () -> Unit raise UiError,
) -> Int raise UiError {
  self.on(
    ev => {
      match ev {
        Focus(_) => true
        _ => false
      }
    },
    fn(_) raise UiError { f() },
  )
}

///|
pub fn[B] Widget::on_blur(
  self : Widget[B],
  f : () -> Unit raise UiError,
) -> Int raise UiError {
  self.on(
    ev => {
      match ev {
        Blur(_) => true
        _ => false
      }
    },
    fn(_) raise UiError { f() },
  )
}

///|
/// 不过滤任何事件，用于集成测试与全局观察。
pub fn[B] Widget::on_any(
  self : Widget[B],
  handler : (Event) -> Unit raise UiError,
) -> Int raise UiError {
  self.on(_ => true, handler)
}

///|
fn mock_widgets() -> MockBackend raise UiError {
  let b = MockBackend::new()
  Backend::init(b)
  b
}

///|
/// §33：控件不吞 handler 的异常，测试里统一用它把错误收成语明。
fn widget_error(body : () -> Unit raise UiError) -> String? {
  let out : String? = try {
    body()
    None
  } catch {
    e => Some(UiError::message(e))
  }
  out
}

///|
fn rect(x : Double, y : Double, w : Double, h : Double) -> LogicalRect {
  LogicalRect::{
    origin: LogicalPoint::{ x, y, },
    size: LogicalSize::{ width: w, height: h, },
  }
}

///|
test "叶子控件的属性读写都走 Backend，种类守卫拦住误用" {
  let b = mock_widgets()
  let label = Widget::label(b, "Title")
  assert_eq(label.kind(), WidgetKind::Label)
  assert_true(label.handle() is Some(_))
  assert_eq(label.text(), "Title")
  assert_eq(label.intrinsic_size(), LogicalSize::{ width: 48.0, height: 20.0, })
  label.set_text("Longer title")
  assert_eq(label.text(), "Longer title")
  // 文本变长，固有尺寸跟着变——真实后端就是重新测量
  assert_eq(label.intrinsic_size().width, 104.0)
  label.set_visible(false)
  assert_false(label.visible())
  label.set_enabled(false)
  assert_false(label.enabled())
  label.set_style(Some(Style::empty()))
  assert_eq(label.style(), Some(Style::empty()))

  let btn = Widget::button(b, "Ok")
  assert_eq(btn.intrinsic_size(), LogicalSize::{ width: 40.0, height: 28.0, })
  let input = Widget::text_input(b, "")
  assert_eq(input.intrinsic_size(), LogicalSize::{ width: 160.0, height: 24.0, })
  let cb = Widget::checkbox(b, "On", true)
  assert_true(cb.checked())
  cb.set_checked(false)
  assert_false(cb.checked())

  // 属性种类守卫：每个误用都是明确错误，不是静默无效
  assert_eq(
    widget_error(fn() raise UiError { label.set_checked(true) }),
    Some("不支持的操作：只有复选框有勾选状态"),
  )
  assert_eq(
    widget_error(fn() raise UiError { label.set_spacing(4.0) }),
    Some("不支持的操作：只有 Row/Column/Grid 有间距"),
  )
  assert_eq(
    widget_error(fn() raise UiError { label.set_insets(EdgeInsets::zero()) }),
    Some("不支持的操作：只有 Padding 有内边距"),
  )
  assert_eq(widget_error(fn() raise UiError { btn.set_text("x") }), None)
  let row0 = Widget::row(b, 0.0, [])
  assert_eq(
    widget_error(fn() raise UiError { row0.set_text("x") }),
    Some("不支持的操作：该控件没有文本属性"),
  )
}

///|
/// §8：容器持有子项。已被持有的控件不能二次归属，否则销毁时会有两个父级
/// 各自销毁同一个原生对象。
test "容器持有子项，二次归属与已销毁子项都被拒绝" {
  let b = mock_widgets()
  let btn = Widget::button(b, "Ok")
  let row1 = Widget::row(b, 0.0, [btn])
  let row2 = Widget::column(b, 0.0, [])
  assert_true(btn.is_attached())
  assert_eq(
    widget_error(fn() raise UiError { row2.add_child(btn) }),
    Some("该控件已被其他容器持有"),
  )
  assert_eq(row1.children().length(), 1)
  assert_eq(row2.children().length(), 0)

  let orphan = Widget::label(b, "Gone")
  orphan.close_tree()
  assert_eq(
    widget_error(fn() raise UiError { row2.add_child(orphan) }),
    Some("对象已销毁"),
  )
  // 关闭后的控件任何操作都是 Destroyed
  assert_eq(
    widget_error(fn() raise UiError { let _ = orphan.text() }),
    Some("对象已销毁"),
  )
  // Spacer 是终端节点
  let sp = Widget::spacer(b)
  assert_eq(
    widget_error(fn() raise UiError { sp.add_child(btn) }),
    Some("不支持的操作：Spacer 不能有子控件"),
  )
  assert_eq(
    widget_error(fn() raise UiError { sp.set_expand(false) }),
    Some("不支持的操作：Spacer 本身就是弹性项"),
  )
}

///|
/// Row 的绝对边界：主轴按固有尺寸累加、间距只加在相邻项之间，
/// 交叉轴保持固有尺寸，算完写回后端（§14）。
test "Row 布局把绝对边界写回每个叶子控件" {
  let b = mock_widgets()
  let label = Widget::label(b, "Ab")
  let btn = Widget::button(b, "Ok")
  let row = Widget::row(b, 10.0, [label, btn])
  let placed = row.do_layout(rect(20.0, 30.0, 400.0, 200.0))
  assert_eq(placed.length(), 2)
  // "Ab" -> 2*8+8 = 24 x 20；"Ok" -> 2*8+24 = 40 x 28
  assert_eq(label.bounds(), rect(20.0, 30.0, 24.0, 20.0))
  assert_eq(btn.bounds(), rect(54.0, 30.0, 40.0, 28.0))
  assert_eq(label.frame(), rect(20.0, 30.0, 24.0, 20.0))
}

///|
/// Column + Padding + Center 组合：内缩先减边距，居中用余量的一半。
test "Column 套 Padding 再 Center，边界逐级传递" {
  let b = mock_widgets()
  let a = Widget::label(b, "A")
  let c = Widget::label(b, "B")
  let col = Widget::column(b, 6.0, [a, c])
  let pad = Widget::padding(b, EdgeInsets::all(10.0), col)
  let center = Widget::center(b, pad)
  // 两个 16x20 的标签 + 6 间距 -> 16x46；内边距 10 -> 36x66
  assert_eq(pad.measure(BoxConstraints::loose(200.0, 100.0)), LogicalSize::{
    width: 36.0,
    height: 66.0,
  })
  let placed = center.do_layout(rect(0.0, 0.0, 200.0, 100.0))
  assert_eq(placed.length(), 2)
  // 居中后的 Padding 外框 (82,17)，内缩 10 -> 内容起点 (92,27)
  assert_eq(a.bounds(), rect(92.0, 27.0, 16.0, 20.0))
  assert_eq(c.bounds(), rect(92.0, 53.0, 16.0, 20.0))
}

///|
/// 弹性分配：Spacer 与 expand 叶子均分剩余主轴空间（§14）。
test "Spacer 吃掉 Row 的剩余空间" {
  let b = mock_widgets()
  let btn = Widget::button(b, "Ok")
  let sp = Widget::spacer(b)
  let label = Widget::label(b, "Ab")
  let row = Widget::row(b, 0.0, [btn, sp, label])
  let placed = row.do_layout(rect(0.0, 0.0, 200.0, 100.0))
  // 固定项 40 + 24 = 64，剩余 136 归 Spacer，标签被推到 176
  assert_eq(placed.length(), 2)
  assert_eq(btn.bounds(), rect(0.0, 0.0, 40.0, 28.0))
  assert_eq(label.bounds(), rect(176.0, 0.0, 24.0, 20.0))
  // expand 的叶子参与同一轮分配
  let label2 = Widget::label(b, "Ab")
  let input = Widget::text_input(b, "")
  let grow = Widget::row(b, 0.0, [label2, input])
  input.set_expand(true)
  assert_true(input.expand())
  let _ = grow.do_layout(rect(0.0, 0.0, 200.0, 40.0))
  assert_eq(input.bounds(), rect(24.0, 0.0, 176.0, 40.0))
}

///|
/// 可见性对容器递归：叶子的原生父级是窗口，容器自己没有原生对象可藏。
test "容器可见性递归到整棵子树" {
  let b = mock_widgets()
  let label = Widget::label(b, "A")
  let btn = Widget::button(b, "Ok")
  let row = Widget::row(b, 0.0, [label, btn])
  assert_true(row.visible())
  row.set_visible(false)
  assert_false(label.visible())
  assert_false(btn.visible())
  assert_false(row.visible())
  label.set_visible(true)
  // 子树里还有一个隐藏的叶子，容器就不算可见
  assert_false(row.visible())
  assert_true(label.visible())
  btn.set_visible(true)
  assert_true(row.visible())
}

///|
test "布局节点不占原生对象，也没有事件目标" {
  let b = mock_widgets()
  let label = Widget::label(b, "A")
  let btn = Widget::button(b, "Ok")
  let row = Widget::row(b, 4.0, [label, btn])
  assert_true(row.handle() is None)
  assert_eq(row.leaf_count(), 2)
  // 只有两个叶子向后端要过对象
  assert_eq(b.live(), 2)
  assert_eq(
    widget_error(fn() raise UiError { let _ = row.target() }),
    Some(
      "不支持的操作：布局节点没有原生对象，不能订阅事件",
    ),
  )
  assert_eq(
    widget_error(fn() raise UiError { row.set_bounds(rect(0.0, 0.0, 1.0, 1.0)) }),
    None,
  )
  assert_eq(row.spacing(), 4.0)
}

///|
/// §47 风险 1：关闭子树后原生句柄必须全部归还，handler 引用链同时清空。
test "close_tree 释放整棵子树的原生句柄与闭包" {
  let b = mock_widgets()
  let label = Widget::label(b, "A")
  let btn = Widget::button(b, "Ok")
  let row = Widget::row(b, 0.0, [label, btn])
  let _ = btn.on_click(fn() { () })
  assert_eq(b.live(), 2)
  assert_eq(btn.handler_count(), 1)
  row.close_tree()
  assert_eq(b.live(), 0)
  assert_eq(btn.handler_count(), 0)
  assert_eq(row.children().length(), 0)
  assert_true(row.is_closed())
  assert_true(btn.handle() is None)
  assert_eq(
    widget_error(fn() raise UiError { row.close_tree() }),
    Some("对象已销毁"),
  )
  Backend::terminate(b)
}

///|
/// §9/§10：`on_click` 之类是 `Event` 的过滤器糖，命中才调用。
test "on_click 只放行 Click，handler 的异常沿 fire 传出" {
  let b = mock_widgets()
  let btn = Widget::button(b, "Ok")
  let log : Array[String] = []
  let _ = btn.on_click(fn() { log.push("click") })
  let _ = btn.on_input(fn(s) { log.push("input:\{s}") })
  let _ = btn.on_change(fn() { log.push("change") })
  let t = btn.target()
  assert_eq(btn.fire(Event::Click(t, MouseButton::Left)), 1)
  assert_eq(btn.fire(Event::Change(t)), 1)
  assert_eq(btn.fire(Event::Input(t, "abc")), 1)
  assert_eq(btn.fire(Event::Focus(t)), 0)
  assert_eq(log, ["click", "change", "input:abc"])

  // handler 失败不被控件吞掉（§33）
  let boom = Widget::button(b, "Boom")
  let _ = boom.on_any(fn(_) raise UiError {
    raise OperationFailed("handler 内部失败")
  })
  assert_eq(
    widget_error(fn() raise UiError {
      let _ = boom.fire(Event::Click(boom.target(), MouseButton::Left))
    }),
    Some("操作失败：handler 内部失败"),
  )
  // 关闭后的控件不能再派发
  boom.close_tree()
  assert_eq(
    widget_error(fn() raise UiError {
      let _ = boom.fire(
        Event::Click(EventTarget::{ id: 999, }, MouseButton::Left),
      )
    }),
    Some("对象已销毁"),
  )
}

///|
test "find_by_id 沿 Core 树找回叶子控件" {
  let b = mock_widgets()
  let label = Widget::label(b, "Aim")
  let btn = Widget::button(b, "Ok")
  let row = Widget::row(b, 0.0, [label, btn])
  let t = label.target()
  let found = row.find_by_id(t.id)
  assert_true(found is Some(_))
  match found {
    Some(w) => assert_eq(w.text(), "Aim")
    None => ()
  }
  assert_true(row.find_by_id(-7) is None)
}

///|
/// §15/§16 的层叠语义：稀疏覆盖表逐层合并，自身最优先，没写的字段才往下继承。
/// 配色不缓存，`set_theme` 之后下一次解析就生效。
test "样式按 Theme -> 父容器 -> 自身 层叠" {
  let b = mock_widgets()
  let app = App::new(b)
  app.set_theme(Dark)
  assert_eq(app.theme(), Dark)
  assert_eq(app.appearance(), Dark)
  let dark = Theme::dark_palette()
  let base = app.style_base()
  assert_eq(base.background, Some(dark.surface))
  assert_eq(base.foreground, Some(dark.text))

  let row = Widget::row(b, 0.0, [])
  let label = Widget::label(b, "A")
  row.add_child(label)
  row.set_style(Some(style(font_size=Some(18.0))))
  label.set_style(Some(style(foreground=Some(Color::rgb(200, 30, 30)))))
  let s = label.resolved_style(base)
  // 字号来自父容器，前景色来自自身，底色仍来自 Theme
  assert_eq(s.font_size, Some(18.0))
  assert_eq(s.foreground, Some(Color::rgb(200, 30, 30)))
  assert_eq(s.background, Some(dark.surface))
  assert_eq(s.radius, None)
  // 父容器不吃子控件的覆盖
  assert_eq(row.resolved_style(base).foreground, Some(dark.text))

  // System 落到 Backend 报告的外观上
  app.set_theme(System)
  b.set_appearance(Light)
  assert_eq(app.appearance(), Light)
  let light = Theme::light_palette()
  assert_eq(
    label.resolved_style(app.style_base()).background,
    Some(light.surface),
  )
  b.set_appearance(Dark)
  assert_eq(app.appearance(), Dark)
  assert_eq(
    label.resolved_style(app.style_base()).background,
    Some(dark.surface),
  )
  // 自身覆盖始终压过主题与父级
  assert_eq(
    label.resolved_style(app.style_base()).foreground,
    Some(Color::rgb(200, 30, 30)),
  )
}

///|
test "Stack 的叶子叠在同一原点，容器本身不占原生对象" {
  let b = mock_widgets()
  let back = Widget::label(b, "Ab")
  let badge = Widget::button(b, "Ok")
  assert_true(WidgetKind::Stack.is_layout_only())
  let stack = Widget::stack(b, [back, badge])
  assert_eq(stack.kind(), WidgetKind::Stack)
  assert_true(stack.handle() is None)
  assert_eq(stack.leaf_count(), 2)
  // 只有两个叶子向后端要过对象
  assert_eq(b.live(), 2)
  let placed = stack.do_layout(rect(5.0, 7.0, 200.0, 200.0))
  assert_eq(placed.length(), 2)
  assert_eq(back.bounds(), rect(5.0, 7.0, 24.0, 20.0))
  assert_eq(badge.bounds(), rect(5.0, 7.0, 40.0, 28.0))
}

///|
test "Grid 均匀单元格，非法列数与负间距在构造时夹紧" {
  let b = mock_widgets()
  let a = Widget::label(b, "Ab")
  let c = Widget::label(b, "Abcd")
  let d = Widget::label(b, "A")
  let grid = Widget::grid(b, 2, 4.0, [a, c, d])
  assert_true(WidgetKind::Grid.is_layout_only())
  assert_eq(grid.columns(), 2)
  assert_eq(grid.spacing(), 4.0)
  // 单元格取最大固有尺寸 40x20；2 列 2 行 => 40*2+4=84，20*2+4=44
  assert_eq(grid.measure(BoxConstraints::loose(300.0, 300.0)), LogicalSize::{
    width: 84.0,
    height: 44.0,
  })
  let placed = grid.do_layout(rect(0.0, 0.0, 300.0, 300.0))
  assert_eq(placed.length(), 3)
  assert_eq(a.bounds(), rect(0.0, 0.0, 24.0, 20.0))
  assert_eq(c.bounds(), rect(44.0, 0.0, 40.0, 20.0))
  assert_eq(d.bounds(), rect(0.0, 24.0, 16.0, 20.0))

  let e = Widget::label(b, "Ab")
  let f = Widget::label(b, "Ab")
  let one_col = Widget::grid(b, 0, -4.0, [e, f])
  assert_eq(one_col.columns(), 1)
  assert_eq(one_col.spacing(), 0.0)
  let _ = one_col.do_layout(rect(0.0, 0.0, 100.0, 100.0))
  assert_eq(f.bounds(), rect(0.0, 20.0, 24.0, 20.0))
}

///|
test "Scroll 把内容按完整高度排布，超出视口的部分即滚动行程" {
  let b = mock_widgets()
  let x = Widget::button(b, "A")
  let y = Widget::button(b, "A")
  let z = Widget::button(b, "A")
  let col = Widget::column(b, 0.0, [x, y, z])
  let sc = Widget::scroll(b, Axis::Vertical, col)
  assert_true(WidgetKind::Scroll.is_layout_only())
  assert_eq(sc.axis(), Axis::Vertical)
  assert_true(sc.handle() is None)
  // 视口主轴铺满给到的 30，交叉轴随内容收缩到 32
  assert_eq(sc.measure(BoxConstraints::loose(200.0, 30.0)), LogicalSize::{
    width: 32.0,
    height: 30.0,
  })
  let placed = sc.do_layout(rect(0.0, 0.0, 200.0, 30.0))
  assert_eq(placed.length(), 3)
  assert_eq(y.bounds(), rect(0.0, 28.0, 32.0, 28.0))
  // 第三个按钮整体落在视口之外，后端沿 y 平移内容就能滚到它
  assert_eq(z.bounds(), rect(0.0, 56.0, 32.0, 28.0))
}

///|
test "Scroll 必须恰好一个子控件，Grid/Scroll 属性有种类守卫" {
  let b = mock_widgets()
  let one = Widget::label(b, "Ab")
  let two = Widget::label(b, "Cd")
  let sc = Widget::scroll(b, Axis::Vertical, one)
  sc.add_child(two)
  assert_eq(
    widget_error(fn() raise UiError {
      let _ = sc.measure(BoxConstraints::loose(100.0, 100.0))
    }),
    Some("操作失败：Scroll 必须恰好有一个子控件"),
  )
  let plain = Widget::label(b, "Ab")
  assert_eq(
    widget_error(fn() raise UiError { let _ = plain.columns() }),
    Some("不支持的操作：只有 Grid 有列数"),
  )
  assert_eq(
    widget_error(fn() raise UiError { let _ = plain.axis() }),
    Some("不支持的操作：只有 Scroll 有滚动方向"),
  )
  let grid = Widget::grid(b, 3, 0.0, [])
  assert_eq(
    widget_error(fn() raise UiError { let _ = grid.axis() }),
    Some("不支持的操作：只有 Scroll 有滚动方向"),
  )
  assert_eq(
    widget_error(fn() raise UiError { let _ = grid.target() }),
    Some(
      "不支持的操作：布局节点没有原生对象，不能订阅事件",
    ),
  )
}
