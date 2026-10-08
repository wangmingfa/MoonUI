///|
/// `MockBackend` 的控件侧实现（§13、§37 第一层）。
///
/// mock 存在的意义是让 Widget 层的生命周期、所有权和布局在拿到 libui-ng 之前
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
    Label => LogicalSize::{ width: text_width + 8.0, height: 20.0 * scale, }
    Button => LogicalSize::{ width: text_width + 24.0, height: 28.0 * scale, }
    TextInput => LogicalSize::{ width: 160.0, height: 24.0 * scale, }
    Checkbox => LogicalSize::{ width: text_width + 24.0, height: 20.0 * scale, }
    // 纯布局节点（§14）不会拿到原生对象，这条分支只是穷尽性兜底
    Row | Column | Padding | Spacer | Center | Stack | Grid | Scroll =>
      LogicalSize::zero()
  }
}

///|
pub impl Backend for MockBackend with fn create_widget(self, kind, text) -> NativeHandle raise UiError {
  self.check_initialized()
  let index = self.widgets.length()
  self.widgets.push(MockWidget::{
    kind,
    text,
    checked: false,
    visible: true,
    enabled: true,
    bounds: LogicalRect::{
      origin: LogicalPoint::{ x: 0.0, y: 0.0, },
      size: LogicalSize::zero(),
    },
    parent: None,
    intrinsic: mock_intrinsic(kind, text, None),
    style: None,
  })
  let h = self.handles.register(NativePtr((index * 2 + 1).to_int64()))
  h
}

///|
pub impl Backend for MockBackend with fn destroy_widget(self, h) -> Unit raise UiError {
  let w = self.widget(h)
  // 先断开父子关系再注销，避免遗留一个指向已销毁句柄的父指针
  match w.parent {
    Some(p) =>
      match self.windows_at(self.window_slot(p)) {
        Some(win) => win.z_order = z_order_without(win.z_order, h)
        None => ()
      }
    None => ()
  }
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
pub impl Backend for MockBackend with fn set_widget_checked(self, h, v) -> Unit raise UiError {
  let w = self.widget(h)
  if w.kind != Checkbox {
    raise Unsupported("只有复选框有勾选状态")
  }
  w.checked = v
}

///|
pub impl Backend for MockBackend with fn widget_checked(self, h) -> Bool raise UiError {
  let w = self.widget(h)
  if w.kind != Checkbox {
    raise Unsupported("只有复选框有勾选状态")
  }
  w.checked
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
pub impl Backend for MockBackend with fn set_widget_style(self, h, s) -> Unit raise UiError {
  let w = self.widget(h)
  w.style = Some(s)
  // 与 set_widget_text 同一条规矩：影响度量的属性一变更就重算，
  // 这样 widget_intrinsic_size 永远反映后端当下的状态（§18 的唯一事实来源）
  w.intrinsic = mock_intrinsic(w.kind, w.text, Some(s))
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
pub impl Backend for MockBackend with fn detach_widget(self, child) -> Unit raise UiError {
  let c = self.widget(child)
  match c.parent {
    Some(p) =>
      match self.windows_at(self.window_slot(p)) {
        Some(win) => win.z_order = z_order_without(win.z_order, child)
        None => ()
      }
    None => ()
  }
  c.parent = None
}

///|
pub impl Backend for MockBackend with fn raise_widget(self, child) -> Unit raise UiError {
  let c = self.widget(child)
  match c.parent {
    Some(p) =>
      match self.windows_at(self.window_slot(p)) {
        Some(win) => win.z_order = z_order_move(win.z_order, child, true)
        None => ()
      }
    None => ()
  }
}

///|
test "mock 控件按种类给出确定性固有尺寸" {
  let b = MockBackend::new()
  Backend::init(b)
  assert_eq(
    Backend::widget_intrinsic_size(b, Backend::create_widget(b, Label, "Hello")),
    LogicalSize::{ width: 48.0, height: 20.0, },
  )
  assert_eq(
    Backend::widget_intrinsic_size(b, Backend::create_widget(b, Button, "Go")),
    LogicalSize::{ width: 40.0, height: 28.0, },
  )
  assert_eq(
    Backend::widget_intrinsic_size(b, Backend::create_widget(b, TextInput, "")),
    LogicalSize::{ width: 160.0, height: 24.0, },
  )
  assert_eq(
    Backend::widget_intrinsic_size(
      b,
      Backend::create_widget(b, Checkbox, "记住我"),
    ),
    LogicalSize::{ width: 48.0, height: 20.0, },
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
  assert_eq(Backend::widget_intrinsic_size(b, w), LogicalSize::{
    width: 48.0,
    height: 20.0,
  })
  Backend::set_widget_style(b, w, style(font_size=Some(24.0)))
  assert_eq(Backend::widget_intrinsic_size(b, w), LogicalSize::{
    width: 88.0,
    height: 40.0,
  })
  // 字重在 mock 里是 1.25 倍宽：只为让"样式进度量"有第二条可断言的轴
  Backend::set_widget_style(
    b,
    w,
    style(font_size=Some(24.0), font_weight=Some(Bold)),
  )
  assert_eq(Backend::widget_intrinsic_size(b, w), LogicalSize::{
    width: 108.0,
    height: 40.0,
  })
  // 样式之后改文本，重算必须沿用后端持有的那份样式：忽略样式的话这里会是 104.0
  Backend::set_widget_style(
    b,
    w,
    style(font_size=Some(24.0), font_weight=Some(Bold)),
  )
  Backend::set_widget_text(b, w, "Hello MoonUI")
  assert_eq(Backend::widget_intrinsic_size(b, w), LogicalSize::{
    width: 248.0,
    height: 40.0,
  })
  // 样式里没写字号就是 1.0 缩放，和没下发样式同值——区分开"没设"与"设了别的"
  Backend::set_widget_style(b, w, style(background=Some(Color::rgb(1, 2, 3))))
  assert_eq(Backend::widget_intrinsic_size(b, w), LogicalSize::{
    width: 104.0,
    height: 20.0,
  })
  // TextInput 的 160.0 是默认字段宽，不随字号变，高度照变
  let field = Backend::create_widget(b, TextInput, "")
  Backend::set_widget_style(b, field, style(font_size=Some(6.0)))
  assert_eq(Backend::widget_intrinsic_size(b, field), LogicalSize::{
    width: 160.0,
    height: 12.0,
  })
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
  Backend::set_widget_bounds(b, w, LogicalRect::{
    origin: LogicalPoint::{ x: 4.0, y: 6.0, },
    size: LogicalSize::{ width: 40.0, height: 20.0, },
  })
  assert_eq(Backend::widget_bounds(b, w).origin, LogicalPoint::{
    x: 4.0,
    y: 6.0,
  })
  // 文本变了，固有尺寸必须跟着变（真实后端就是重新测量文本）
  Backend::set_widget_text(b, w, "hello")
  assert_eq(Backend::widget_intrinsic_size(b, w), LogicalSize::{
    width: 48.0,
    height: 20.0,
  })
  // 勾选状态只属于 Checkbox
  let msg = try {
    Backend::set_widget_checked(b, w, true)
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("不支持的操作：只有复选框有勾选状态"))
  // 窗口句柄不能用于控件操作
  let win = b.create_window("W", LogicalSize::{ width: 10.0, height: 10.0, })
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
  let win = b.create_window("W", LogicalSize::{ width: 200.0, height: 200.0, })
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
