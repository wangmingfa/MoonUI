///|
/// 布局检查器（设计文档 §14、§18，`T88①`）：把窗口的内容树渲染成树形缩进的
/// 逐行账——带句柄的行是"种类 + 句柄 id + 绝对边界 + margin/padding 消费账 +
/// 命中区标记"，纯布局节点的行只报种类与容器属性（spacing/insets/fixed）——
/// 矩形缺席本身进账（§14：Core 里只有带句柄的节点有矩形）。Menu dump 的形状
/// 先例（`MenuItem::describe` 渲染成一行可读文本）沿到树上：dump 是给人读的
/// 调试档，也是回归判据的断言载体（mock 的度量是确定性启发式，码元数 × 8 加
/// 内边距，见 mock_widget.mbt——同样的树在判据里逐字符相等）。
///
/// 消费账的口径沿 `T87①` 落地后的布局语义，两笔各归各（条目原句）：
/// - margin 是**这一层自己的** Style 覆盖（`own_margin`，非继承），消费口对
///   非零值包一层 Padding——占用 = frame 外扩一圈；零值与未设置都不包，账上
///   同形（既有判据"零 margin 与无 margin 的树逐位同值"）。
/// - padding 是容器的 insets（`WidgetKind::Padding`）或 MenuRow 的绘制缩进——
///   逐行账只报容器那笔（MenuRow 的缩进账在固有尺寸里，`leaf_intrinsic`）。
///
/// 命中区的口径沿 `hit_test`：Core 里有矩形的是带句柄的节点（叶子 + 占用原生
/// 视口的 Scroll，`T74`），纯布局节点没有句柄也没有 id，进不了命中（§14）。
/// 每行的括号标记就是这条账的可视化；点查命中另有 `Window::widget_at`。
///
/// 形状偏差（记案）：真窗可视化那半欠账——树形缩进文本在真后端上读数照常可用
/// （frame 是 Core 侧的绝对边界，§14），但真窗的边界描框/命中高亮（Xcode
/// Debug View Hierarchy 那种档）需要在后端画图，无头 CI 断不了，挂 TODO 报告。

///|
/// 控件种类的可读名。显式穷举而非派生 Debug 的输出——dump 的逐字符判据要
/// 钉住名字集合，derive 输出跟着编译器漂的话账就跟漂了。
fn kind_name(kind : WidgetKind) -> String {
  match kind {
    WidgetKind::Label => "Label"
    WidgetKind::Button => "Button"
    WidgetKind::TextInput => "TextInput"
    WidgetKind::Checkbox => "Checkbox"
    WidgetKind::PasswordInput => "PasswordInput"
    WidgetKind::Separator => "Separator"
    WidgetKind::Slider => "Slider"
    WidgetKind::Spinbox => "Spinbox"
    WidgetKind::Progress => "Progress"
    WidgetKind::ComboBox => "ComboBox"
    WidgetKind::MultilineEntry => "MultilineEntry"
    WidgetKind::Panel => "Panel"
    WidgetKind::RadioButtons => "RadioButtons"
    WidgetKind::DatePicker => "DatePicker"
    WidgetKind::MenuRow => "MenuRow"
    WidgetKind::VSeparator => "VSeparator"
    WidgetKind::Row => "Row"
    WidgetKind::Column => "Column"
    WidgetKind::Padding => "Padding"
    WidgetKind::Spacer => "Spacer"
    WidgetKind::Center => "Center"
    WidgetKind::Stack => "Stack"
    WidgetKind::Grid => "Grid"
    WidgetKind::Scroll => "Scroll"
    WidgetKind::Sized => "Sized"
    WidgetKind::Image => "Image"
  }
}

///|
/// 有文本属性的种类（`check_text_kind` 的那份名单）：逐行账带文本摘录。
fn kind_has_text(kind : WidgetKind) -> Bool {
  match kind {
    WidgetKind::Label
    | WidgetKind::Button
    | WidgetKind::TextInput
    | WidgetKind::Checkbox
    | WidgetKind::PasswordInput
    | WidgetKind::MultilineEntry
    | WidgetKind::MenuRow => true
    _ => false
  }
}

///|
/// 矩形的逐行账读法：`[x,y w×h]`（逻辑像素，Double 最短渲染——整值不带尾零）。
fn fmt_rect(r : LogicalRect) -> String {
  "[\{r.origin.x},\{r.origin.y} \{r.size.width}x\{r.size.height}]"
}

///|
/// 四向内边距的读法：`[top,end,bottom,start]`——字段序与 `EdgeInsets` 结构序
/// 一致，与布局消费的 `f.inset(top, end, bottom, start)` 同一顺序。
fn fmt_e(e : EdgeInsets) -> String {
  "[\{e.top},\{e.end},\{e.bottom},\{e.start}]"
}

///|
/// margin 的消费账（`T87①`）：占用 = frame 外扩一圈。方向映射沿 Padding
/// 消费口——start 在左、end 在右、top 在上、bottom 在下（`f.inset` 的逆）。
fn margin_occupancy(f : LogicalRect, e : EdgeInsets) -> LogicalRect {
  LogicalRect(
    LogicalPoint(f.origin.x - e.start, f.origin.y - e.top),
    LogicalSize(
      f.size.width + e.start + e.end,
      f.size.height + e.top + e.bottom,
    ),
  )
}

///|
/// 递归渲染：一行一个节点，缩进两格一层。行的拼装顺序固定：
/// `种类#id frame=… [spacing|columns|insets|fixed|margin 占用] ["文本"] （命中标记）`
/// ——属性段只报设置过的（未设置的不出现），文本只报文本类种类，命中标记
/// 按句柄有无论。
///
/// frame 只报**带句柄**的节点：布局写回的是带 id 的那批 `Placed`（叶子和占用
/// 原生视口的 Scroll），纯布局节点在 Core 里没有矩形（§14 的架构事实——
/// `hit_test` 同一句注），它们的行不出现 frame 字段，缺席本身就是账。
fn[B : Backend] Widget::dump_lines(
  self : Widget[B],
  indent : String,
  out : Array[String],
) -> Unit raise UiError {
  self.check_open()
  let id = match self.handle {
    Some(h) => h.id.to_string()
    None => "-"
  }
  let mut line = "\{indent}\{kind_name(self.kind)}#\{id}"
  match self.handle {
    Some(_) => line = line + " frame=\{fmt_rect(self.frame)}"
    None => ()
  }
  match self.kind {
    WidgetKind::Row | WidgetKind::Column | WidgetKind::Grid =>
      line = line + " spacing=\{self.spacing}"
    _ => ()
  }
  if self.kind == WidgetKind::Grid {
    line = line + " columns=\{self.columns}"
  }
  if self.kind == WidgetKind::Padding {
    line = line + " insets=\{fmt_e(self.insets)}"
  }
  if self.kind == WidgetKind::Sized {
    match self.fixed_w {
      Some(w) => line = line + " fixed_w=\{w}"
      None => ()
    }
    match self.fixed_h {
      Some(h) => line = line + " fixed_h=\{h}"
      None => ()
    }
  }
  match self.own_margin() {
    Some(e) =>
      if e.horizontal() > 0.0 || e.vertical() > 0.0 {
        // 消费账：占用是非零 margin 包层后这一格真的吃掉的行程（`T87①` 的
        // 外扩账）；frame 仍在占用之内被压进一格
        line = line +
          " margin=\{fmt_e(e)} 占用=\{fmt_rect(margin_occupancy(self.frame, e))}"
      }
    None => ()
  }
  if kind_has_text(self.kind) {
    let text = self.text()
    if text != "" {
      line = line + " \"\{text}\""
    }
  }
  match self.handle {
    Some(_) => line = line + " （命中区）"
    None => line = line + " （布局节点·命中缺席）"
  }
  out.push(line)
  for c in self.children {
    c.dump_lines(indent + "  ", out)
  }
}

///|
/// 子树的布局逐行账（`T88①`）。行与行之间用 `\n` 拼接，尾行不带换行。
/// 判据逐字符断言；给人看的场合 println 即得。
pub fn[B : Backend] Widget::dump_layout(
  self : Widget[B],
) -> String raise UiError {
  let out : Array[String] = []
  self.dump_lines("", out)
  join_lines(out)
}

///|
/// 窗口内容树的布局逐行账（`T88①`）。`set_content` 立即布局的账（§8）在这里
/// 读得到：dump 读的是当下 frame，没重排过的标脏账不进（重排后 dump 会追上，
/// 与 bounds/frame 的读法同一纪律）。没有内容树返回单行说明。
pub fn[B : Backend] Window::dump_layout(
  self : Window[B],
) -> String raise UiError {
  match self.content {
    Some(root) => root.dump_layout()
    None => "(无内容树)"
  }
}

///|
fn join_lines(out : Array[String]) -> String {
  let mut text = ""
  for i = 0; i < out.length(); i = i + 1 {
    if i > 0 {
      text = text + "\n"
    }
    text = text + out[i]
  }
  text
}

///|
test "dump_layout 的逐行账：树形缩进 + frame + 命中标记（T88①判据）" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let win = app.create_window("MoonUI", LogicalSize(800.0, 600.0))
  win.set_content(
    Widget::column(b, 16.0, [
      Widget::label(b, "Hello"),
      Widget::button(b, "Click Me"),
    ]),
  )
  // mock 度量："Hello" 5 码元 → 48x20；"Click Me" 8 码元 → 88x28。
  // 列的 spacing=16；纯布局节点无 id（#-）、无矩形（frame 字段缺席——§14 只
  // 有带句柄的节点在 Core 里有矩形）、无命中（括号里的缺席标记）。行内字段
  // 序固定：frame → 消费账 → 文本摘录 → 命中标记。尾行不带换行。
  assert_eq(
    win.dump_layout(),
    [
      "Column#- spacing=16 （布局节点·命中缺席）", "  Label#1 frame=[0,0 48x20] \"Hello\" （命中区）",
      "  Button#2 frame=[0,36 88x28] \"Click Me\" （命中区）",
    ].join("\n"),
  )
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
test "dump_layout 的消费账：margin 外扩与 padding 内缩同框（T88①判据·T87①两笔各归各）" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let win = app.create_window("MoonUI", LogicalSize(400.0, 300.0))
  let label = Widget::label(b, "hi")
  win.set_content(
    Widget::padding(b, EdgeInsets::all(10.0), Widget::row(b, 0.0, [label])),
  )
  label.set_style(Some(style(margin=Some(EdgeInsets::all(8.0)))))
  win.relayout()
  // 消费账逐行账逐字符断言：padding 容器报 insets（内缩那笔），margin 项报
  // 外扩的占用（frame [18,18 24x20] 外扩 8 一圈 → [10,10 40x36]）。两笔各归
  // 各、同框叠加——数字沿既有 T87① 判据的读法（label 落在 10+8）
  assert_eq(
    win.dump_layout(),
    [
      "Padding#- insets=[10,10,10,10] （布局节点·命中缺席）", "  Row#- spacing=0 （布局节点·命中缺席）",
      "    Label#1 frame=[18,18 24x20] margin=[8,8,8,8] 占用=[10,10 40x36] \"hi\" （命中区）",
    ].join("\n"),
  )
  // 行内 spacing=0 也进账：设置过（哪怕零值）与未设置不同形
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
test "dump_layout 的命中标记与 widget_at 同账：标记即命中区的可视化（T88①判据）" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let win = app.create_window("MoonUI", LogicalSize(400.0, 300.0))
  let leaf = Widget::label(b, "leaf")
  win.set_content(Widget::column(b, 0.0, [leaf]))
  let f = leaf.frame()
  // 命中标记宣称"Label 是命中区"——与点查命中互证：叶子的中心点查回叶子，
  // 叶子之外的点查回 None（布局节点的缺席标记与这条缺席同义）
  assert_true(
    win.widget_at(LogicalPoint(f.origin.x + 1.0, f.origin.y + 1.0)) is Some(_),
  )
  assert_true(win.widget_at(LogicalPoint(399.0, 299.0)) is None)
  // 没挂内容树的窗口：单行说明，不报错（DX 工具不因空树失败）
  let empty = app.create_window("Empty", LogicalSize(100.0, 100.0))
  assert_eq(empty.dump_layout(), "(无内容树)")
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}
