///|
/// 装箱的后端：两份真后端按枚举二选一。`@moonui.Backend` 的实现把每个方法
/// 转发给分支里那一份——运行期枚举 + 编译期单态派发的对齐点。为什么不用
/// trait 对象：moonc v0.10.15 上对象装箱各形状全部拒绝（`as` 装箱在定义包里
/// 也报 4175"is not a trait object type"、隐式向上 4099"is a trait, not a
/// type"、`Trait::object` 调用/类型均不存在），经验主义验证过；枚举转发是
/// 保证可行的那条，签名由编译器对着 trait 强制，漏一份 check 直接红。
///
/// 代价记在案：Backend trait 每加一个方法，这里的转发跟着加一份（61 份是
/// 当下读数）。新方法当天加，转发当天补，别欠。
///
/// 本文件由 /tmp/gen_delegation.py 从 packages/moonui/backend.mbt 的 trait
/// 声明机械生成（签名块按括号配平抽取，core 类型全路径化）——手改这份文件
/// 的转发体没意义，改生成器或直接改 trait。
pub enum AnyBackend {
  Native(@native-common.NativeBackend)
  Libui(@libui-common.LibuiBackend)
}

///|
/// 用户面的枚举参数：就是这个枚举决定用哪个后端。单元变体——构造属于门面
/// （`AnyBackend::of`），用户从此不 import 后端包、不构造后端结构、不管
/// init 时序。
pub(all) enum Backend {
  Native
  Libui
}

///|
/// 枚举选后端：按单元枚举构造装箱后端。
pub fn AnyBackend::of(choice : Backend) -> AnyBackend {
  match choice {
    Native => Native(@native-common.NativeBackend::new())
    Libui => Libui(@libui-common.LibuiBackend::new())
  }
}

///|
/// 枚举选后端造 App：构造 + init + `App::new` 三步一次做完。返回的是 core 的
/// `App[AnyBackend]`——树代码一行不改（`Gallery::demo(app)` 的 `B` 绑到装箱枚举，
/// 它实现了 `@moonui.Backend`）。
///
/// 参数是带默认值的可选参数（`backend~`）：不传就是 `Backend::Native`（自研
/// 直写后端是主方向）；要用 libui-ng 那份再显式传。
///
/// ```moonbit nocheck
/// let app = @moonui_app.new_app()                            // 默认 Native
/// let app = @moonui_app.new_app(backend=Backend::Libui)      // 显式选
/// let g = @moonui.Gallery::demo(app)
/// app.run()
/// ```
pub fn new_app(
  backend~ : Backend = Backend::Native,
) -> @moonui.App[AnyBackend] raise @moonui.UiError {
  let b = AnyBackend::of(backend)
  b.init()
  @moonui.App::new(b)
}

///|
pub impl @moonui.Backend for AnyBackend with fn init(self) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.init()
    Libui(b) => b.init()
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn terminate(self) -> Unit {
  match self {
    Native(b) => b.terminate()
    Libui(b) => b.terminate()
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn poll_event(self) -> @moonui.Event? {
  match self {
    Native(b) => b.poll_event()
    Libui(b) => b.poll_event()
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn request_redraw(self, p0) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.request_redraw(p0)
    Libui(b) => b.request_redraw(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn create_window(self, p0, p1) -> @moonui.NativeHandle raise @moonui.UiError {
  match self {
    Native(b) => b.create_window(p0, p1)
    Libui(b) => b.create_window(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn destroy_window(self, p0) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.destroy_window(p0)
    Libui(b) => b.destroy_window(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_window_title(self, p0, p1) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_window_title(p0, p1)
    Libui(b) => b.set_window_title(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_window_size(self, p0, p1) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_window_size(p0, p1)
    Libui(b) => b.set_window_size(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn show_window(self, p0) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.show_window(p0)
    Libui(b) => b.show_window(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn hide_window(self, p0) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.hide_window(p0)
    Libui(b) => b.hide_window(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn window_scale(self, p0) -> @moonui.Scale raise @moonui.UiError {
  match self {
    Native(b) => b.window_scale(p0)
    Libui(b) => b.window_scale(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn screen_size(self) -> @moonui.LogicalSize raise @moonui.UiError {
  match self {
    Native(b) => b.screen_size()
    Libui(b) => b.screen_size()
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn window_work_area(self, p0) -> @moonui.LogicalRect raise @moonui.UiError {
  match self {
    Native(b) => b.window_work_area(p0)
    Libui(b) => b.window_work_area(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn system_theme(self) -> @moonui.Theme raise @moonui.UiError {
  match self {
    Native(b) => b.system_theme()
    Libui(b) => b.system_theme()
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn window_size(self, p0) -> @moonui.LogicalSize raise @moonui.UiError {
  match self {
    Native(b) => b.window_size(p0)
    Libui(b) => b.window_size(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_window_position(
  self,
  p0,
  p1,
) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_window_position(p0, p1)
    Libui(b) => b.set_window_position(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn window_position(self, p0) -> @moonui.LogicalPoint raise @moonui.UiError {
  match self {
    Native(b) => b.window_position(p0)
    Libui(b) => b.window_position(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_window_resizable(
  self,
  p0,
  p1,
) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_window_resizable(p0, p1)
    Libui(b) => b.set_window_resizable(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_window_fullscreen(
  self,
  p0,
  p1,
) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_window_fullscreen(p0, p1)
    Libui(b) => b.set_window_fullscreen(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_window_titlebar_style(
  self,
  p0,
  p1,
) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_window_titlebar_style(p0, p1)
    Libui(b) => b.set_window_titlebar_style(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_window_traffic_light_position(
  self,
  p0,
  p1,
) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_window_traffic_light_position(p0, p1)
    Libui(b) => b.set_window_traffic_light_position(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn create_widget(self, p0, p1) -> @moonui.NativeHandle raise @moonui.UiError {
  match self {
    Native(b) => b.create_widget(p0, p1)
    Libui(b) => b.create_widget(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn create_ranged_widget(
  self,
  p0,
  p1,
  p2,
) -> @moonui.NativeHandle raise @moonui.UiError {
  match self {
    Native(b) => b.create_ranged_widget(p0, p1, p2)
    Libui(b) => b.create_ranged_widget(p0, p1, p2)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn destroy_widget(self, p0) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.destroy_widget(p0)
    Libui(b) => b.destroy_widget(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_widget_text(self, p0, p1) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_widget_text(p0, p1)
    Libui(b) => b.set_widget_text(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn widget_text(self, p0) -> String raise @moonui.UiError {
  match self {
    Native(b) => b.widget_text(p0)
    Libui(b) => b.widget_text(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_widget_checked(self, p0, p1) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_widget_checked(p0, p1)
    Libui(b) => b.set_widget_checked(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn widget_checked(self, p0) -> Bool raise @moonui.UiError {
  match self {
    Native(b) => b.widget_checked(p0)
    Libui(b) => b.widget_checked(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_widget_insets(self, p0, p1) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_widget_insets(p0, p1)
    Libui(b) => b.set_widget_insets(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_widget_value(self, p0, p1) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_widget_value(p0, p1)
    Libui(b) => b.set_widget_value(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn widget_value(self, p0) -> Int32 raise @moonui.UiError {
  match self {
    Native(b) => b.widget_value(p0)
    Libui(b) => b.widget_value(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_widget_range(
  self,
  p0,
  p1,
  p2,
) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_widget_range(p0, p1, p2)
    Libui(b) => b.set_widget_range(p0, p1, p2)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn append_widget_option(
  self,
  p0,
  p1,
) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.append_widget_option(p0, p1)
    Libui(b) => b.append_widget_option(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_widget_selected(
  self,
  p0,
  p1,
) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_widget_selected(p0, p1)
    Libui(b) => b.set_widget_selected(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn widget_selected(self, p0) -> Int32 raise @moonui.UiError {
  match self {
    Native(b) => b.widget_selected(p0)
    Libui(b) => b.widget_selected(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_widget_datetime(
  self,
  p0,
  p1,
) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_widget_datetime(p0, p1)
    Libui(b) => b.set_widget_datetime(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn widget_datetime(self, p0) -> String raise @moonui.UiError {
  match self {
    Native(b) => b.widget_datetime(p0)
    Libui(b) => b.widget_datetime(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_widget_visible(self, p0, p1) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_widget_visible(p0, p1)
    Libui(b) => b.set_widget_visible(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn widget_visible(self, p0) -> Bool raise @moonui.UiError {
  match self {
    Native(b) => b.widget_visible(p0)
    Libui(b) => b.widget_visible(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_widget_enabled(self, p0, p1) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_widget_enabled(p0, p1)
    Libui(b) => b.set_widget_enabled(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn widget_enabled(self, p0) -> Bool raise @moonui.UiError {
  match self {
    Native(b) => b.widget_enabled(p0)
    Libui(b) => b.widget_enabled(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_widget_style(self, p0, p1) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_widget_style(p0, p1)
    Libui(b) => b.set_widget_style(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_widget_accessibility(
  self,
  p0,
  p1,
) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_widget_accessibility(p0, p1)
    Libui(b) => b.set_widget_accessibility(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_widget_bounds(self, p0, p1) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_widget_bounds(p0, p1)
    Libui(b) => b.set_widget_bounds(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn widget_bounds(self, p0) -> @moonui.LogicalRect raise @moonui.UiError {
  match self {
    Native(b) => b.widget_bounds(p0)
    Libui(b) => b.widget_bounds(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn widget_intrinsic_size(self, p0) -> @moonui.LogicalSize raise @moonui.UiError {
  match self {
    Native(b) => b.widget_intrinsic_size(p0)
    Libui(b) => b.widget_intrinsic_size(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn attach_widget(self, p0, p1) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.attach_widget(p0, p1)
    Libui(b) => b.attach_widget(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn attach_widget_to(self, p0, p1) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.attach_widget_to(p0, p1)
    Libui(b) => b.attach_widget_to(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_scroll_content(
  self,
  p0,
  p1,
  p2,
) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_scroll_content(p0, p1, p2)
    Libui(b) => b.set_scroll_content(p0, p1, p2)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn detach_widget(self, p0) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.detach_widget(p0)
    Libui(b) => b.detach_widget(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn raise_widget(self, p0) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.raise_widget(p0)
    Libui(b) => b.raise_widget(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_paint_order(self, p0, p1) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_paint_order(p0, p1)
    Libui(b) => b.set_paint_order(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_focus_chain(self, p0, p1) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_focus_chain(p0, p1)
    Libui(b) => b.set_focus_chain(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn clipboard_text(self) -> String? raise @moonui.UiError {
  match self {
    Native(b) => b.clipboard_text()
    Libui(b) => b.clipboard_text()
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_clipboard_text(self, p0) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_clipboard_text(p0)
    Libui(b) => b.set_clipboard_text(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn show_message(self, p0, p1) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.show_message(p0, p1)
    Libui(b) => b.show_message(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn confirm(self, p0, p1) -> Bool raise @moonui.UiError {
  match self {
    Native(b) => b.confirm(p0, p1)
    Libui(b) => b.confirm(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn open_file(self, p0) -> String? raise @moonui.UiError {
  match self {
    Native(b) => b.open_file(p0)
    Libui(b) => b.open_file(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn save_file(self, p0, p1) -> String? raise @moonui.UiError {
  match self {
    Native(b) => b.save_file(p0, p1)
    Libui(b) => b.save_file(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn select_folder(self, p0) -> String? raise @moonui.UiError {
  match self {
    Native(b) => b.select_folder(p0)
    Libui(b) => b.select_folder(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_menu_bar(self, p0) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_menu_bar(p0)
    Libui(b) => b.set_menu_bar(p0)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_menu_item_checked(
  self,
  p0,
  p1,
) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_menu_item_checked(p0, p1)
    Libui(b) => b.set_menu_item_checked(p0, p1)
  }
}

///|
pub impl @moonui.Backend for AnyBackend with fn set_app_icon(self, p0) -> Unit raise @moonui.UiError {
  match self {
    Native(b) => b.set_app_icon(p0)
    Libui(b) => b.set_app_icon(p0)
  }
}

///|
/// 显式把 `Backend` 的方法开放为点号方法（裸 `Backend` 在本包撞了用户面
/// 枚举，trait 用全路径引用）。转发体里的 `b.init()` 走的是各真后端自己的
/// extend；这份是 AnyBackend 自己的。
pub extend AnyBackend with @moonui.Backend::{
  init,
  terminate,
  poll_event,
  request_redraw,
  create_window,
  destroy_window,
  set_window_title,
  set_window_size,
  show_window,
  hide_window,
  window_scale,
  screen_size,
  window_work_area,
  system_theme,
  window_size,
  set_window_position,
  window_position,
  set_window_resizable,
  set_window_fullscreen,
  set_window_titlebar_style,
  set_window_traffic_light_position,
  create_widget,
  create_ranged_widget,
  destroy_widget,
  set_widget_text,
  widget_text,
  set_widget_checked,
  widget_checked,
  set_widget_insets,
  set_widget_value,
  widget_value,
  set_widget_range,
  append_widget_option,
  set_widget_selected,
  widget_selected,
  set_widget_datetime,
  widget_datetime,
  set_widget_visible,
  widget_visible,
  set_widget_enabled,
  widget_enabled,
  set_widget_style,
  set_widget_accessibility,
  set_widget_bounds,
  widget_bounds,
  widget_intrinsic_size,
  attach_widget,
  attach_widget_to,
  set_scroll_content,
  detach_widget,
  raise_widget,
  set_paint_order,
  set_focus_chain,
  clipboard_text,
  set_clipboard_text,
  show_message,
  confirm,
  open_file,
  save_file,
  select_folder,
  set_menu_bar,
  set_menu_item_checked,
  set_app_icon,
}
