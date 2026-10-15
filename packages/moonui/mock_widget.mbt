///|
/// `MockBackend` 的控件侧实现（§13、§37 第一层）。
///
/// mock 存在的意义是让 Widget 层的生命周期、所有权和布局不依赖任何 GUI 库
/// 就能被断言：属性读写、父子挂接、句柄误用都必须有确定的行为。
/// 固有尺寸用"码元数 × 8.0 × 字号缩放 + 内边距"这种确定性启发式，绝不依赖字体系统，
/// 否则快照测试会在不同机器上漂移。

///|
pub struct MockWidget {
  kind : WidgetKind
  mut text : String
  mut checked : Bool
  mut visible : Bool
  mut enabled : Bool
  mut bounds : LogicalRect
  mut parent : NativeHandle?
  mut intrinsic : LogicalSize
  /// §15/§16 下发的生效样式；`widget_intrinsic_size` 就是按它重算度量的。
  /// 未推过样式时是 `None`，度量退回 12.0 基准，所以没接样式的老断言逐条不变。
  mut style : Style?
  /// §32 的语义最近一次下发的内容（`T41`）；`None` = 还没随重排推过。
  /// 测试靠它断言"语义真的到了后端"，而不是 Core 里算得对就算完。
  mut accessibility : Accessibility?
  /// 数值控件的当前值（Slider / Spinbox / Progress）。
  mut value : Int32
  /// 条目控件（ComboBox / RadioButtons）的选项与选中下标；`selected = -1`
  /// 是沿 libui 的"没选中"哨兵。选项数组本身不需要 `mut`：MoonBit 数组是引用
  /// 语义，`push` 改内容不改引用。
  options : Array[String]
  mut selected : Int32
  /// DatePicker 的值（"YYYY-MM-DD HH:MM:SS"）。空串 = 没设过。
  mut datetime : String
  /// 滚动视口最近一次推下来的内容尺寸与方向（`T74`）；None = 没推过。
  /// 测试靠它断言"滚动行程真的到了后端"。
  mut scroll_content : (Axis, LogicalSize)?
  /// MenuRow 内边距最近一次推下来的值（§51）；零值 = 没推过。测量账归 Core
  /// （`to_layout_spec` 统一加），mock 无绘制载体——存下只为测试能断言
  /// "语义真的到了后端"。
  mut insets : EdgeInsets
} derive(Debug, Eq)

///|
/// mock 的字号缩放：相对 12.0 基准线性放大。没有 `font_size` 就是 1.0，
/// 这是"样式没下发"和"样式下发了但没写字号"共同的退路。
fn mock_font_scale(s : Style?) -> Double {
  match s {
    Some(st) =>
      match st.font_size {
        Some(f) => f / 12.0
        None => 1.0
      }
    None => 1.0
  }
}

///|
fn mock_intrinsic(kind : WidgetKind, text : String, s : Style?) -> LogicalSize {
  let scale = mock_font_scale(s)
  let is_bold = match s {
    Some(st) => st.font_weight == Some(Bold)
    None => false
  }
  // 只有文字部分随字号与字重变：宽度里那 8.0/24.0 是控件内边距，
  // TextInput 的 160.0 是默认字段宽，两者都跟字号无关（真机上是原生层的事，§18）。
  let text_width = text.length().to_double() *
    8.0 *
    scale *
    (if is_bold { 1.25 } else { 1.0 })
  match kind {
    Label => LogicalSize(text_width + 8.0, 20.0 * scale)
    Button => LogicalSize(text_width + 24.0, 28.0 * scale)
    TextInput | PasswordInput => LogicalSize(160.0, 24.0 * scale)
    Checkbox => LogicalSize(text_width + 24.0, 20.0 * scale)
    Slider => LogicalSize(120.0, 24.0 * scale)
    Spinbox => LogicalSize(80.0, 24.0 * scale)
    Progress => LogicalSize(120.0, 16.0 * scale)
    Separator => LogicalSize(2.0, 2.0)
    VSeparator => LogicalSize(2.0, 2.0)
    ComboBox => LogicalSize(120.0, 24.0 * scale)
    MultilineEntry => LogicalSize(200.0, 80.0 * scale)
    RadioButtons => LogicalSize(120.0, 20.0 * scale)
    DatePicker => LogicalSize(160.0, 24.0 * scale)
    // 扁平可点文本行（§51 画册左栏）：宽度随文案 + 左右内边距，高度一行
    MenuRow => LogicalSize(text_width + 16.0, 24.0 * scale)
    // 纯布局节点（§14）不会拿到原生对象，这条分支只是穷尽性兜底
    Row | Column | Padding | Spacer | Center | Stack | Grid | Scroll | Sized =>
      LogicalSize::zero()
  }
}

///|
/// 条目控件（ComboBox / RadioButtons）的固有尺寸随选项走：宽度取最长选项，
/// 高度一行一条（RadioButtons）/ 固定一行（ComboBox）。mock 里没有这个信息
/// 就只能报固定值，追加选项的断言会漂，所以由 `append_widget_option` 和
/// `set_widget_text` 的同一条规矩在选项变化时重算。
fn mock_options_intrinsic(
  kind : WidgetKind,
  options : Array[String],
  s : Style?,
) -> LogicalSize {
  let scale = mock_font_scale(s)
  let mut text_width = 0.0
  for o in options {
    let w = o.length().to_double() * 8.0 * scale
    if w > text_width {
      text_width = w
    }
  }
  let height = match kind {
    RadioButtons => 20.0 * scale * options.length().to_double()
    _ => 24.0 * scale
  }
  LogicalSize(text_width + 24.0, height)
}

///|
pub impl Backend for MockBackend with fn create_widget(self, kind, text) -> NativeHandle raise UiError {
  self.check_initialized()
  self.push_mock_widget(kind, text, 0, 0)
}

///|
/// `create_widget` 与 `create_ranged_widget` 的公共底座。
fn MockBackend::push_mock_widget(
  self : MockBackend,
  kind : WidgetKind,
  text : String,
  min : Int32,
  max : Int32,
) -> NativeHandle {
  // 不 raise：两条公开通道（create_widget / create_ranged_widget）各自做种类
  // 校验后再进这里，底座没有可失败的分支。
  let index = self.widgets.length()
  self.widgets.push(MockWidget::{
    kind,
    text,
    checked: false,
    visible: true,
    enabled: true,
    bounds: LogicalRect(LogicalPoint(0.0, 0.0), LogicalSize::zero()),
    parent: None,
    intrinsic: mock_intrinsic(kind, text, None),
    style: None,
    accessibility: None,
    value: min,
    options: [],
    selected: -1,
    datetime: "",
    scroll_content: None,
    insets: EdgeInsets::zero(),
  })
  let h = self.handles.register(NativePtr((index * 2 + 1).to_int64()))
  // mock 不存范围（没有要夹紧的行为），值从 min 起步只是沿 libui 的
  // "初始值等于最小值"口径，让跨后端断言可比。
  let _ = (min, max)
  h
}

///|
pub impl Backend for MockBackend with fn create_ranged_widget(
  self,
  kind,
  min,
  max,
) -> NativeHandle raise UiError {
  self.check_initialized()
  match kind {
    Slider | Spinbox => self.push_mock_widget(kind, "", min, max)
    _ =>
      raise Unsupported("只有 Slider / Spinbox 走带范围的创建通道")
  }
}

///|
/// parent 是窗口时从它的层叠表里摘掉 `h`；parent 是容器控件（T74 的 Scroll
/// 文档区）时什么都不用做——容器子控件本来就不在窗口的 z_order 里。
fn MockBackend::remove_from_parent_z(
  self : MockBackend,
  w : MockWidget,
  h : NativeHandle,
) -> Unit raise UiError {
  match w.parent {
    Some(p) => {
      // 偶数指针是窗口、奇数是控件（见 slot_of 的对表）
      let NativePtr(ptr) = self.handles.resolve(p)
      if ptr % 2 == 0 {
        match self.windows_at(self.window_slot(p)) {
          Some(win) => win.z_order = z_order_without(win.z_order, h)
          None => ()
        }
      }
    }
    None => ()
  }
}

///|
pub impl Backend for MockBackend with fn destroy_widget(self, h) -> Unit raise UiError {
  let w = self.widget(h)
  // 先断开父子关系再注销，避免遗留一个指向已销毁句柄的父指针
  self.remove_from_parent_z(w, h)
  w.parent = None
  self.handles.unregister(h)
}

///|
pub impl Backend for MockBackend with fn set_widget_text(self, h, text) -> Unit raise UiError {
  let w = self.widget(h)
  w.text = text
  w.intrinsic = mock_intrinsic(w.kind, text, w.style)
}

///|
pub impl Backend for MockBackend with fn widget_text(self, h) -> String raise UiError {
  let w = self.widget(h)
  w.text
}

///|
pub impl Backend for MockBackend with fn set_widget_value(self, h, v) -> Unit raise UiError {
  let w = self.widget(h)
  match w.kind {
    Slider | Spinbox | Progress => w.value = v
    _ => raise Unsupported("该控件没有数值属性")
  }
}

///|
pub impl Backend for MockBackend with fn widget_value(self, h) -> Int32 raise UiError {
  let w = self.widget(h)
  match w.kind {
    Slider | Spinbox | Progress => w.value
    _ => raise Unsupported("该控件没有数值属性")
  }
}

///|
pub impl Backend for MockBackend with fn set_widget_range(self, h, min, max) -> Unit raise UiError {
  let w = self.widget(h)
  match w.kind {
    Slider =>
      // mock 里不存范围本身，只把越界的当前值夹回新范围——真后端由原生控件夹。
      w.value = if w.value < min {
        min
      } else if w.value > max {
        max
      } else {
        w.value
      }
    _ => raise Unsupported("只有 Slider 能改范围")
  }
}

///|
pub impl Backend for MockBackend with fn append_widget_option(self, h, text) -> Unit raise UiError {
  let w = self.widget(h)
  match w.kind {
    ComboBox | RadioButtons => {
      w.options.push(text)
      mock_recompute(w)
    }
    _ => raise Unsupported("该控件没有选项属性")
  }
}

///|
pub impl Backend for MockBackend with fn set_widget_selected(self, h, index) -> Unit raise UiError {
  let w = self.widget(h)
  match w.kind {
    ComboBox | RadioButtons => w.selected = index
    _ => raise Unsupported("该控件没有选项属性")
  }
}

///|
pub impl Backend for MockBackend with fn widget_selected(self, h) -> Int32 raise UiError {
  let w = self.widget(h)
  match w.kind {
    ComboBox | RadioButtons => w.selected
    _ => raise Unsupported("该控件没有选项属性")
  }
}

///|
pub impl Backend for MockBackend with fn set_widget_datetime(self, h, text) -> Unit raise UiError {
  let w = self.widget(h)
  match w.kind {
    DatePicker => w.datetime = text
    _ => raise Unsupported("只有 DatePicker 有日期时间属性")
  }
}

///|
pub impl Backend for MockBackend with fn widget_datetime(self, h) -> String raise UiError {
  let w = self.widget(h)
  match w.kind {
    DatePicker => w.datetime
    _ => raise Unsupported("只有 DatePicker 有日期时间属性")
  }
}

///|
pub impl Backend for MockBackend with fn set_widget_checked(self, h, v) -> Unit raise UiError {
  let w = self.widget(h)
  if w.kind != Checkbox && w.kind != MenuRow {
    raise Unsupported("只有复选框和菜单行有勾选状态")
  }
  w.checked = v
}

///|
pub impl Backend for MockBackend with fn widget_checked(self, h) -> Bool raise UiError {
  let w = self.widget(h)
  if w.kind != Checkbox && w.kind != MenuRow {
    raise Unsupported("只有复选框和菜单行有勾选状态")
  }
  w.checked
}

///|
pub impl Backend for MockBackend with fn set_widget_insets(self, h, v) -> Unit raise UiError {
  let w = self.widget(h)
  if w.kind != MenuRow {
    raise Unsupported("只有菜单行有内边距")
  }
  // 只存不消费：测量账归 Core（`to_layout_spec` 统一加），mock 没有绘制载体。
  // 同 accessibility / scroll_content 的先例——存下让测试能断言"语义真的
  // 到了后端"，而不是 Core 里算得对就算完。
  w.insets = v
}

///|
pub impl Backend for MockBackend with fn set_widget_visible(self, h, v) -> Unit raise UiError {
  let w = self.widget(h)
  w.visible = v
}

///|
pub impl Backend for MockBackend with fn widget_visible(self, h) -> Bool raise UiError {
  let w = self.widget(h)
  w.visible
}

///|
pub impl Backend for MockBackend with fn set_widget_enabled(self, h, v) -> Unit raise UiError {
  let w = self.widget(h)
  w.enabled = v
}

///|
pub impl Backend for MockBackend with fn widget_enabled(self, h) -> Bool raise UiError {
  let w = self.widget(h)
  w.enabled
}

///|
pub impl Backend for MockBackend with fn set_widget_bounds(self, h, rect) -> Unit raise UiError {
  let w = self.widget(h)
  w.bounds = rect.normalized()
}

///|
pub impl Backend for MockBackend with fn widget_bounds(self, h) -> LogicalRect raise UiError {
  let w = self.widget(h)
  w.bounds
}

///|
pub impl Backend for MockBackend with fn set_widget_accessibility(self, h, a) -> Unit raise UiError {
  let w = self.widget(h)
  w.accessibility = Some(a)
}

///|
/// 度量的统一重算入口：条目控件随选项表走，其余随文案走。`set_widget_text`
/// / `append_widget_option` / `set_widget_style` 三处都从这进，
/// 不然三处各算各的迟早漂。
fn mock_recompute(w : MockWidget) -> Unit {
  w.intrinsic = match w.kind {
    ComboBox | RadioButtons =>
      mock_options_intrinsic(w.kind, w.options, w.style)
    _ => mock_intrinsic(w.kind, w.text, w.style)
  }
}

///|
pub impl Backend for MockBackend with fn set_widget_style(self, h, s) -> Unit raise UiError {
  let w = self.widget(h)
  w.style = Some(s)
  // 与 set_widget_text 同一条规矩：影响度量的属性一变更就重算，
  // 这样 widget_intrinsic_size 永远反映后端当下的状态（§18 的唯一事实来源）
  mock_recompute(w)
}

///|
/// 读的是当下持有的样式所对应的度量，所以调用方必须先 `set_widget_style` 再测量
/// （trait 里那条"先推样式、再测量"的契约）。
pub impl Backend for MockBackend with fn widget_intrinsic_size(self, h) -> LogicalSize raise UiError {
  let w = self.widget(h)
  w.intrinsic
}

///|
pub impl Backend for MockBackend with fn attach_widget(self, window, child) -> Unit raise UiError {
  let win = self.window(window)
  let c = self.widget(child)
  c.parent = Some(window)
  // 插到最底层：抄 Win32 的 SetWindowPos(HWND_BOTTOM)，挂载顺序就是 Tab 顺序，
  // 后挂的画在下面。层叠要反过来就得靠 raise_widget。
  win.z_order = z_order_move(win.z_order, child, false)
}

///|
/// 挂进容器（`T74`）：只记父子关系，不动窗口层叠——容器子控件不在窗口的
/// z_order 里，mock 的整份层叠由 `set_paint_order` 一次推平，这里没有增量可做。
pub impl Backend for MockBackend with fn attach_widget_to(
  self,
  container,
  child,
) -> Unit raise UiError {
  let c = self.widget(child)
  c.parent = Some(container)
}

///|
/// 滚动行程（`T74`）：记在控件上，测试读它断言"内容尺寸真的到了后端"。
pub impl Backend for MockBackend with fn set_scroll_content(
  self,
  scroll,
  axis,
  size,
) -> Unit raise UiError {
  let w = self.widget(scroll)
  match w.kind {
    Scroll => w.scroll_content = Some((axis, size))
    _ => raise Unsupported("只有 Scroll 有滚动行程")
  }
}

///|
pub impl Backend for MockBackend with fn detach_widget(self, child) -> Unit raise UiError {
  let c = self.widget(child)
  self.remove_from_parent_z(c, child)
  c.parent = None
}

///|
pub impl Backend for MockBackend with fn raise_widget(self, child) -> Unit raise UiError {
  let c = self.widget(child)
  // 容器子控件（T74）不在任何窗口的 z_order 里，提层是空操作
  match c.parent {
    Some(p) => {
      let NativePtr(ptr) = self.handles.resolve(p)
      if ptr % 2 == 0 {
        match self.windows_at(self.window_slot(p)) {
          Some(win) => win.z_order = z_order_move(win.z_order, child, true)
          None => ()
        }
      }
    }
    None => ()
  }
}

///|
/// 整窗绘画顺序（`T29`）：mock 没有原生 z-order，这份列表就是它的全部层叠状态，
/// 直接存进 `z_order`（从顶层到底层，和 `child_z_order` 的读法同向）。Core 算好
/// 整份推下来，mock 不再靠 attach/raise 的增量去凑——这正是自绘后端的形状。
pub impl Backend for MockBackend with fn set_paint_order(self, window, order) -> Unit raise UiError {
  let win = self.window(window)
  win.z_order = order
}

///|
/// 控件最近一次推下来的滚动行程（`T74`），测试侧读数口；不是 Scroll 或还没推过
/// 都是 `None`。
pub fn MockBackend::scroll_content_of(
  self : MockBackend,
  widget : NativeHandle,
) -> (Axis, LogicalSize)? raise UiError {
  self.widget(widget).scroll_content
}

///|
/// 焦点链（`T29`）：mock 没有原生焦点机制，这份声明顺序列表就是它的全部焦点状态，
/// 直接存进 `focus_chain`。和 `set_paint_order` 分开存：Stack 里层叠是倒序、焦点是
/// 声明序，两者不同，测试靠 `focus_chain` 读它断言"声明顺序真的到了后端"。
pub impl Backend for MockBackend with fn set_focus_chain(self, window, chain) -> Unit raise UiError {
  let win = self.window(window)
  win.focus_chain = chain
}

///|
test "mock 控件按种类给出确定性固有尺寸" {
  let b = MockBackend::new()
  Backend::init(b)
  assert_eq(
    Backend::widget_intrinsic_size(b, Backend::create_widget(b, Label, "Hello")),
    LogicalSize(48.0, 20.0),
  )
  assert_eq(
    Backend::widget_intrinsic_size(b, Backend::create_widget(b, Button, "Go")),
    LogicalSize(40.0, 28.0),
  )
  assert_eq(
    Backend::widget_intrinsic_size(b, Backend::create_widget(b, TextInput, "")),
    LogicalSize(160.0, 24.0),
  )
  assert_eq(
    Backend::widget_intrinsic_size(
      b,
      Backend::create_widget(b, Checkbox, "记住我"),
    ),
    LogicalSize(48.0, 20.0),
  )
}

///|
/// §15/§16 的"先推样式、再测量"契约在 mock 上的落点：文字部分随字号与字重变，
/// 控件内边距与 TextInput 的默认字段宽不变。没推样式时退回 12.0 基准，
/// 所以这条测试的对照组就是上面那条"按种类给出确定性固有尺寸"。
test "mock 度量跟着下发的样式走" {
  let b = MockBackend::new()
  Backend::init(b)
  let w = Backend::create_widget(b, Label, "Hello")
  assert_eq(Backend::widget_intrinsic_size(b, w), LogicalSize(48.0, 20.0))
  Backend::set_widget_style(b, w, style(font_size=Some(24.0)))
  assert_eq(Backend::widget_intrinsic_size(b, w), LogicalSize(88.0, 40.0))
  // 字重在 mock 里是 1.25 倍宽：只为让"样式进度量"有第二条可断言的轴
  Backend::set_widget_style(
    b,
    w,
    style(font_size=Some(24.0), font_weight=Some(Bold)),
  )
  assert_eq(Backend::widget_intrinsic_size(b, w), LogicalSize(108.0, 40.0))
  // 样式之后改文本，重算必须沿用后端持有的那份样式：忽略样式的话这里会是 104.0
  Backend::set_widget_style(
    b,
    w,
    style(font_size=Some(24.0), font_weight=Some(Bold)),
  )
  Backend::set_widget_text(b, w, "Hello MoonUI")
  assert_eq(Backend::widget_intrinsic_size(b, w), LogicalSize(248.0, 40.0))
  // 样式里没写字号就是 1.0 缩放，和没下发样式同值——区分开"没设"与"设了别的"
  Backend::set_widget_style(b, w, style(background=Some(Color::rgb(1, 2, 3))))
  assert_eq(Backend::widget_intrinsic_size(b, w), LogicalSize(104.0, 20.0))
  // TextInput 的 160.0 是默认字段宽，不随字号变，高度照变
  let field = Backend::create_widget(b, TextInput, "")
  Backend::set_widget_style(b, field, style(font_size=Some(6.0)))
  assert_eq(Backend::widget_intrinsic_size(b, field), LogicalSize(160.0, 12.0))
}

///|
test "控件属性读写、窗口句柄不能当控件用" {
  let b = MockBackend::new()
  Backend::init(b)
  let w = Backend::create_widget(b, Label, "one")
  Backend::set_widget_text(b, w, "two")
  assert_eq(Backend::widget_text(b, w), "two")
  assert_eq(Backend::widget_visible(b, w), true)
  Backend::set_widget_visible(b, w, false)
  assert_false(Backend::widget_visible(b, w))
  Backend::set_widget_enabled(b, w, false)
  assert_false(Backend::widget_enabled(b, w))
  Backend::set_widget_bounds(
    b,
    w,
    LogicalRect(LogicalPoint(4.0, 6.0), LogicalSize(40.0, 20.0)),
  )
  assert_eq(Backend::widget_bounds(b, w).origin, LogicalPoint(4.0, 6.0))
  // 文本变了，固有尺寸必须跟着变（真实后端就是重新测量文本）
  Backend::set_widget_text(b, w, "hello")
  assert_eq(Backend::widget_intrinsic_size(b, w), LogicalSize(48.0, 20.0))
  // 勾选状态只属于 Checkbox 与 MenuRow（Label 没有）
  let msg = try {
    Backend::set_widget_checked(b, w, true)
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(
    msg,
    Some("不支持的操作：只有复选框和菜单行有勾选状态"),
  )
  // 窗口句柄不能用于控件操作
  let win = b.create_window("W", LogicalSize(10.0, 10.0))
  let msg2 = try {
    let _ = Backend::widget_text(b, win)
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg2, Some("无效的原生句柄"))
  assert_eq(b.live(), 2)
}

///|
test "控件挂到窗口、摘下来、销毁" {
  let b = MockBackend::new()
  Backend::init(b)
  let win = b.create_window("W", LogicalSize(200.0, 200.0))
  let child = Backend::create_widget(b, Button, "A")
  Backend::attach_widget(b, win, child)
  assert_eq(b.widget(child).parent, Some(win))
  Backend::detach_widget(b, child)
  assert_eq(b.widget(child).parent, None)
  // 控件句柄不能当窗口用
  let msg = try {
    Backend::attach_widget(b, child, child)
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("无效的原生句柄"))
  Backend::attach_widget(b, win, child)
  Backend::destroy_widget(b, child)
  assert_eq(b.live(), 1)
  // 销毁后的句柄再读写都是无效句柄
  let msg2 = try {
    let _ = Backend::widget_text(b, child)
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg2, Some("无效的原生句柄"))
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}
