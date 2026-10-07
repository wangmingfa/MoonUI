///|
/// `MockBackend` 的控件侧实现（§13、§37 第一层）。
///
/// mock 存在的意义是让 Widget 层的生命周期、所有权和布局在拿到 libui-ng 之前
/// 就能被断言：属性读写、父子挂接、句柄误用都必须有确定的行为。
/// 固有尺寸用"UTF-16 码元数 × 8 + 内边距"这种确定性启发式，绝不依赖字体系统，
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
} derive(Debug, Eq)

///|
fn mock_intrinsic(kind : WidgetKind, text : String) -> LogicalSize {
  let units = text.length().to_double()
  match kind {
    Label => LogicalSize::{ width: units * 8.0 + 8.0, height: 20.0, }
    Button => LogicalSize::{ width: units * 8.0 + 24.0, height: 28.0, }
    TextInput => LogicalSize::{ width: 160.0, height: 24.0, }
    Checkbox => LogicalSize::{ width: units * 8.0 + 24.0, height: 20.0, }
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
    intrinsic: mock_intrinsic(kind, text),
  })
  let h = self.handles.register(NativePtr((index * 2 + 1).to_int64()))
  h
}

///|
pub impl Backend for MockBackend with fn destroy_widget(self, h) -> Unit raise UiError {
  let w = self.widget(h)
  // 先断开父子关系再注销，避免遗留一个指向已销毁句柄的父指针
  w.parent = None
  self.handles.unregister(h)
}

///|
pub impl Backend for MockBackend with fn set_widget_text(self, h, text) -> Unit raise UiError {
  let w = self.widget(h)
  w.text = text
  w.intrinsic = mock_intrinsic(w.kind, text)
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
pub impl Backend for MockBackend with fn widget_intrinsic_size(self, h) -> LogicalSize raise UiError {
  let w = self.widget(h)
  w.intrinsic
}

///|
pub impl Backend for MockBackend with fn attach_widget(self, window, child) -> Unit raise UiError {
  let _ = self.window(window)
  let c = self.widget(child)
  c.parent = Some(window)
}

///|
pub impl Backend for MockBackend with fn detach_widget(self, child) -> Unit raise UiError {
  let c = self.widget(child)
  c.parent = None
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
