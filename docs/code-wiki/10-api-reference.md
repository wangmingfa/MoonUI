# 10 API 速查

以 `packages/moonui/pkg.generated.mbti` 为准；本篇只收高频调用。完整签名以 `.mbti` 为唯一事实来源。

## 10.1 前台门 `packages/moonui-app`

```moonbit
pub fn new_app() -> @moonui.App[@native-common.NativeBackend] raise @moonui.UiError
pub fn worker_run(
  @moonui.App[@native-common.NativeBackend],
  () -> Unit,
  () -> Unit raise @moonui.UiError,
) -> Unit raise @moonui.UiError
```

`new_app()` 等价于"构造 `NativeBackend` + `Backend::init` + `App::new`"三步。

## 10.2 `App[B]`

```moonbit
// 生命周期
App::new(B) -> App[B]
App::run(Self) -> Unit raise UiError
App::step(Self) -> Bool raise UiError
App::quit(Self) -> Unit
App::is_running(Self) -> Bool
App::is_finished(Self) -> Bool

// 窗口
App::create_window(Self, String, LogicalSize) -> Window[B] raise UiError
App::window_count(Self) -> Int32
App::live_window_count(Self) -> Int32
App::window_frame(Self) -> WindowFrame? raise UiError
App::save_window_state(Self, String) -> Unit raise UiError
App::load_window_state(Self, String) -> WindowFrame? raise UiError

// 事件
App::dispatch(Self, Event) -> Int32 raise UiError
App::on(Self, EventTarget, (Event) -> Bool, (Event) -> Unit raise UiError) -> Int32
App::on_event(Self, EventTarget, (Event) -> Unit raise UiError) -> Int32
App::unsubscribe(Self, Int32) -> Bool
App::register_shortcut(Self, Shortcut, (Shortcut) -> Unit raise UiError) -> Int32

// 任务/时钟
App::post(Self, () -> Unit raise UiError) -> Unit
App::post_task(Self, () -> Unit raise UiError) -> TaskId
App::cancel_task(Self, TaskId) -> Bool
App::set_anim_clock(Self, () -> Int32) -> Unit
App::set_anim_wake(Self, (Bool) -> Unit) -> Unit

// 主题
App::set_theme(Self, Theme) -> Unit raise UiError
App::theme(Self) -> Theme
App::appearance(Self) -> Theme raise UiError
App::palette(Self) -> Palette raise UiError
App::style_base(Self) -> Style raise UiError

// 菜单与系统能力
App::set_menubar(Self, MenuBar) -> Unit raise UiError
App::show_message(Self, String, String) -> Unit raise UiError
App::confirm(Self, String, String) -> Bool raise UiError
App::open_file(Self, String) -> String? raise UiError
App::save_file(Self, String, String) -> String? raise UiError
App::select_folder(Self, String) -> String? raise UiError
App::clipboard_text(Self) -> String? raise UiError
App::set_clipboard_text(Self, String) -> Unit raise UiError
App::set_icon(Self, String) -> Unit raise UiError
App::notify(Self, String, String) -> Unit raise UiError
```

## 10.3 `Window[B]`

```moonbit
Window::new(B, String, LogicalSize) -> Window[B] raise UiError

// 内容与布局
Window::set_content(Self, Widget[B]) -> Unit raise UiError
Window::content(Self) -> Widget[B]?
Window::relayout(Self) -> Unit raise UiError
Window::widget_at(Self, LogicalPoint) -> Widget[B]?
Window::dump_layout(Self) -> String raise UiError

// 显示
Window::show(Self) -> Unit raise UiError
Window::hide(Self) -> Unit raise UiError
Window::close(Self) -> Unit raise UiError
Window::is_closed(Self) -> Bool
Window::center(Self) -> Unit raise UiError

// 几何（全部逻辑像素）
Window::size(Self) -> LogicalSize raise UiError
Window::physical_size(Self) -> PhysicalSize raise UiError
Window::position(Self) -> LogicalPoint raise UiError
Window::scale(Self) -> Scale raise UiError
Window::set_size(Self, LogicalSize) -> Unit raise UiError
Window::set_position(Self, LogicalPoint) -> Unit raise UiError
Window::set_position_animated(Self, LogicalPoint) -> Unit raise UiError
Window::sync_size(Self, LogicalSize) -> LogicalSize raise UiError
Window::apply_frame(Self, WindowFrame) -> Unit raise UiError

// 尺寸约束与窗口态
Window::set_min_size(Self, LogicalSize?) -> Unit raise UiError
Window::set_max_size(Self, LogicalSize?) -> Unit raise UiError
Window::set_resizable(Self, Bool) -> Unit raise UiError
Window::set_fullscreen(Self, Bool) -> Unit raise UiError
Window::set_minimized(Self, Bool) -> Unit raise UiError
Window::set_maximized(Self, Bool) -> Unit raise UiError
Window::window_state(Self) -> WindowState raise UiError

// 外观
Window::set_title(Self, String) -> Unit raise UiError
Window::set_titlebar_style(Self, TitlebarStyle) -> Unit raise UiError
Window::set_traffic_light_position(Self, LogicalPoint) -> Unit raise UiError
Window::set_live_redraw(Self, Bool?) -> Unit raise UiError
Window::live_redraw(Self) -> Bool?

// 目标
Window::handle(Self) -> NativeHandle
Window::target(Self) -> EventTarget
```

## 10.4 `Widget[B]` 构造

```moonbit
Widget::label(B, String) -> Widget[B] raise UiError
Widget::button(B, String) -> Widget[B] raise UiError
Widget::text_input(B, String) -> Widget[B] raise UiError
Widget::multiline(B, String) -> Widget[B] raise UiError
Widget::password_input(B, String) -> Widget[B] raise UiError
Widget::checkbox(B, String, Bool) -> Widget[B] raise UiError
Widget::slider(B, Int32, Int32) -> Widget[B] raise UiError
Widget::spinbox(B, Int32, Int32) -> Widget[B] raise UiError
Widget::progress(B) -> Widget[B] raise UiError
Widget::combobox(B, Array[String]) -> Widget[B] raise UiError
Widget::radio_buttons(B, Array[String]) -> Widget[B] raise UiError
Widget::date_picker(B) -> Widget[B] raise UiError
Widget::separator(B) -> Widget[B] raise UiError
Widget::vseparator(B) -> Widget[B] raise UiError
Widget::menu_row(B, String, Bool) -> Widget[B] raise UiError
Widget::image(B) -> Widget[B] raise UiError
Widget::custom(B, LogicalSize, (DrawList, PaintEnv) -> Unit) -> Widget[B] raise UiError

// 布局节点
Widget::row(B, Double, Array[Widget[B]]) -> Widget[B] raise UiError
Widget::column(B, Double, Array[Widget[B]]) -> Widget[B] raise UiError
Widget::padding(B, EdgeInsets, Widget[B]) -> Widget[B] raise UiError
Widget::spacer(B) -> Widget[B] raise UiError
Widget::center(B, Widget[B]) -> Widget[B] raise UiError
Widget::stack(B, Array[Widget[B]]) -> Widget[B] raise UiError
Widget::grid(B, Int32, Double, Array[Widget[B]]) -> Widget[B] raise UiError
Widget::sized(B, Double?, Double?, Widget[B]) -> Widget[B] raise UiError

// 原生容器
Widget::panel(B, Widget[B]) -> Widget[B] raise UiError
Widget::scroll(B, Axis, Widget[B]) -> Widget[B] raise UiError
```

## 10.5 `Widget[B]` 属性与事件

```moonbit
Widget::add_child(Self, Widget[B]) -> Unit raise UiError
Widget::children(Self) -> Array[Widget[B]]
Widget::parent(Self) -> Widget[B]?
Widget::handle(Self) -> NativeHandle?
Widget::frame(Self) -> LogicalRect
Widget::dump_layout(Self) -> String raise UiError

// 属性
Widget::text(Self) -> String raise UiError
Widget::set_text(Self, String) -> Unit raise UiError
Widget::checked(Self) -> Bool raise UiError
Widget::set_checked(Self, Bool) -> Unit raise UiError
Widget::value(Self) -> Int32 raise UiError
Widget::set_value(Self, Int32) -> Unit raise UiError
Widget::set_range(Self, Int32, Int32) -> Unit raise UiError
Widget::selected(Self) -> Int32 raise UiError
Widget::set_selected(Self, Int32) -> Unit raise UiError
Widget::append_option(Self, String) -> Unit raise UiError
Widget::datetime_text(Self) -> String raise UiError
Widget::set_datetime_text(Self, String) -> Unit raise UiError
Widget::visible(Self) -> Bool raise UiError
Widget::set_visible(Self, Bool) -> Unit raise UiError
Widget::enabled(Self) -> Bool raise UiError
Widget::set_enabled(Self, Bool) -> Unit raise UiError
Widget::set_icon(Self, String) -> Unit raise UiError
Widget::set_image_path(Self, String) -> Unit raise UiError
Widget::set_image_bytes(Self, Bytes) -> Unit raise UiError

// 链式快捷构造（返回 Self，便于一行搭树）
Widget::width(Self, Double) -> Widget[B] raise UiError
Widget::radius(Self, Double) -> Widget[B] raise UiError
Widget::opacity(Self, Double) -> Widget[B] raise UiError
Widget::background(Self, Color) -> Widget[B] raise UiError
Widget::animation(Self, AnimationCurve) -> Widget[B] raise UiError
Widget::with_child(Self, Widget[B]) -> Widget[B] raise UiError
Widget::with_children(Self, Array[Widget[B]]) -> Widget[B] raise UiError
Widget::with_on_click(Self, () -> Unit raise UiError) -> Widget[B] raise UiError
Widget::with_expand(Self, Bool) -> Widget[B] raise UiError

// 样式
Widget::style(Self) -> Style?
Widget::set_style(Self, Style?) -> Unit raise UiError
Widget::set_hover_style(Self, Style?) -> Unit raise UiError
Widget::resolved_style(Self, Style) -> Style

// 事件（返回处理器 id）
Widget::on(Self, (Event) -> Bool, (Event) -> Unit raise UiError) -> Int32 raise UiError
Widget::on_any(Self, (Event) -> Unit raise UiError) -> Int32 raise UiError
Widget::on_capture(Self, (Event) -> Bool, (Event) -> Bool raise UiError) -> Int32 raise UiError
Widget::on_bubble(Self, (Event) -> Bool, (Event) -> Unit raise UiError) -> Int32 raise UiError
Widget::on_click(Self, () -> Unit raise UiError) -> Int32 raise UiError
Widget::on_change(Self, () -> Unit raise UiError) -> Int32 raise UiError
Widget::on_input(Self, (String) -> Unit raise UiError) -> Int32 raise UiError
Widget::on_focus(Self, () -> Unit raise UiError) -> Int32 raise UiError

// 绘制 / 可达性
Widget::repaint(Self) -> Unit raise UiError
Widget::accessibility(Self) -> Accessibility? raise UiError
Widget::accessibility_tree(Self) -> Array[Accessibility] raise UiError
```

## 10.6 值类型

```moonbit
LogicalPoint::LogicalPoint(Double, Double)
LogicalPoint::offset(Self, Double, Double) -> LogicalPoint

LogicalSize::LogicalSize(Double, Double)
LogicalSize::zero() -> LogicalSize
LogicalSize::clamp(Self, LogicalSize, LogicalSize) -> LogicalSize
LogicalSize::non_negative(Self) -> LogicalSize
LogicalSize::area(Self) -> Double

LogicalRect::LogicalRect(LogicalPoint, LogicalSize)
LogicalRect::contains(Self, LogicalPoint) -> Bool
LogicalRect::intersect(Self, LogicalRect) -> LogicalRect
LogicalRect::inset(Self, Double, Double, Double, Double) -> LogicalRect
LogicalRect::center(Self, LogicalSize) -> LogicalRect

EdgeInsets::all(Double) / zero() / symmetric(Double, Double)
EdgeInsets::horizontal(Self) / vertical(Self) / add(Self, Self)

BoxConstraints::tight(Double, Double) / loose(Double, Double) / unbounded()
BoxConstraints::constrain(Self, LogicalSize) -> LogicalSize

Color::rgb(Int32, Int32, Int32)
Color::rgba(Int32, Int32, Int32, Int32)
Color::blend(Self, Color) / luminance(Self) / readable_foreground(Self)

Gradient::horizontal(Color, Color) / vertical(Color, Color)
Gradient::at(Self, Double) -> Color
```

## 10.7 样式与主题

```moonbit
Style::empty() -> Style
Style::layer(Self, Style) -> Style        // 参数中非 None 的字段覆盖 self
Style::effective_padding(Self) -> EdgeInsets

// Style 字段：width/height/min_width/max_width/margin/padding/background/
// background_gradient/foreground/font_size/font_weight/radius/opacity/backdrop_blur

Theme::Light / Dark / System
Theme::light_palette() -> Palette
Theme::dark_palette() -> Palette
Theme::resolve(Self, system : Theme) -> Palette      // System → 按 system 落到 Light/Dark
Theme::default_style(Self, system : Theme) -> Style
Palette { background, surface, text, accent, border }
```

## 10.8 布局类型

```moonbit
LayoutSpec::Leaf(LeafSpec) | Row(LineSpec) | Column(LineSpec) | Padding(PaddingSpec)
  | Spacer | Center(CenterSpec) | Stack(StackSpec) | Grid(GridSpec) | Scroll(ScrollSpec)
  | Panel(PanelSpec) | Sized(SizedSpec) | Unbounded(LayoutSpec) | Expand(LayoutSpec)

LeafSpec { id : Int32, intrinsic : LogicalSize, expand : Bool, fill_cross : Bool }
LineSpec { axis : Axis, spacing : Double, children : Array[LayoutSpec] }
Placed { id : Int32, frame : LogicalRect }

measure(LayoutSpec, BoxConstraints) -> LogicalSize
layout(LayoutSpec, LogicalRect, Array[Placed]) -> Unit
```

## 10.9 事件

```moonbit
Event::target(Self) -> EventTarget
Event::is_mouse_press(Self) -> Bool
EventTarget::of(NativeHandle) -> EventTarget
EventTarget { id : Int32, generation : Int32 }
```

`Event` 的 27 个变体见 [06](06-events.md#61-event-全量27-个变体)。

## 10.10 菜单与快捷键

```moonbit
MenuBar::new(Array[Menu]) -> MenuBar
MenuBar::find(Self, Int32) -> MenuItem?
MenuBar::click(Self, Int32) -> MenuItem? raise UiError
MenuBar::set_checked(Self, Int32, Bool) -> Bool
MenuBar::toggle(Self, Int32) -> Bool
MenuBar::top_labels(Self) -> Array[String]

Menu::new(String, Array[MenuNode])
Menu::find(Self, Int32) -> MenuItem?
Menu::flatten(Self) -> Array[MenuItem]

MenuItem::checkbox(String)
MenuItem::fire(Self) -> Int32 raise UiError
MenuItem::describe(Self) -> String
```

## 10.11 `Backend` trait（实现者用）

`pub(open) trait Backend`（[backend.mbt#L29](../../packages/moonui/backend.mbt#L29)）的主要分组：

| 组 | 方法 |
| --- | --- |
| 生命周期 | `init`、`terminate`、`poll_event`、`request_redraw`、`set_live_dispatch` |
| 窗口 | `create_window`、`destroy_window`、`show_window`、`hide_window`、`set_window_title/size/position/min_size/resizable/fullscreen/minimized/maximized/titlebar_style/traffic_light_position/live_redraw`、`window_size/position/scale/state/work_area`、`screen_size` |
| 控件 | `create_widget`、`create_ranged_widget`、`destroy_widget`、`attach_widget`、`attach_widget_to`、`detach_widget`、`raise_widget`、`set_scroll_content` |
| 属性 | `set_widget_text/widget_text`、`set_widget_checked/widget_checked`、`set_widget_value/widget_value`、`set_widget_range`、`append_widget_option`、`set_widget_selected/widget_selected`、`set_widget_datetime/widget_datetime`、`set_widget_visible/widget_visible`、`set_widget_enabled/widget_enabled`、`set_widget_opacity`、`set_widget_insets`、`set_widget_icon/image_path/image_bytes` |
| 样式/主题 | `set_widget_style`、`set_theme_base`、`system_theme`、`host_platform`、`get_prefers_reduced_motion`、`get_prefers_high_contrast` |
| 布局/绘制 | `set_widget_bounds`、`widget_bounds`、`widget_intrinsic_size`、`set_paint_order`、`set_focus_chain`、`draw_custom`、`measure_text` |
| 系统 | `clipboard_text`、`set_clipboard_text`、`show_message`、`confirm`、`open_file`、`save_file`、`select_folder`、`set_menu_bar`、`set_menu_item_checked`、`show_context_menu`、`set_app_icon`、`set_tray_icon`、`set_tray_menu`、`notify` |

共 83 个方法。实现契约见 [04 运行时核心](04-core-runtime.md#43-backend-trait)。

## 10.12 `packages/widgets`

```moonbit
DataGrid::new(B, Array[GridColumn], rows?~, width?~, height?~, row_height?~,
  header_height?~, font_size?~, header_font_size?~, pad?~, auto_width?~, zebra?~,
  bg?~, header_bg?~, zebra_bg?~, selected_bg?~, text_color?~, header_text?~,
  border?~, empty_text?~) -> DataGrid[B] raise UiError
DataGrid::widget(Self) -> Widget[B]
DataGrid::select_row(Self, Int32) -> Unit raise UiError
DataGrid::set_rows(Self, Array[Array[String]]) -> Unit raise UiError
DataGrid::set_cell(Self, Int32, Int32, String) -> Unit raise UiError
DataGrid::sort_by_column(Self, Int32) -> Unit raise UiError
DataGrid::clear_sort(Self) -> Unit raise UiError

GridColumn::new(String, Double, right?~, numeric?~) -> GridColumn raise UiError

ProgressRing::new(B, Double, size?~, thickness?~, track?~, accent?~, text_color?~,
  label?~, show_label?~, font_size?~) -> ProgressRing[B] raise UiError
ProgressRing::set_value(Self, Double) -> Unit raise UiError

Sparkline::new(B, Array[Double], width?~, height?~, line?~, line_width?~, baseline?~,
  baseline_color?~, dot?~, min?~, max?~, max_points?~, area?~, area_color?~,
  area_alpha?~) -> Sparkline[B] raise UiError
Sparkline::push(Self, Double) -> Unit raise UiError
Sparkline::set_series(Self, Array[Double]) -> Unit raise UiError

TreeNode::new(Int32, String, children?~ : Array[TreeNode], detail?~ : String) -> TreeNode
TreeView::new(B, TreeNode, width?~, height?~, row_height?~, font_size?~, indent?~,
  pad?~, show_root?~, expanded?~, guides?~, bg?~, selected_bg?~, text_color?~,
  detail_color?~, glyph_color?~, guide_color?~, empty_text?~) -> TreeView[B] raise UiError
TreeView::toggle(Self, Int32) -> Unit raise UiError
TreeView::toggle_at(Self, Double, Double, height?~) -> Int32? raise UiError
TreeView::expand(Self, Int32) / expand_all(Self) -> Unit raise UiError
TreeView::collapse(Self, Int32) / collapse_all(Self) -> Unit raise UiError
TreeView::select_id(Self, Int32) -> Unit raise UiError
TreeView::selected_id(Self) -> Int32
TreeView::row_of(Self, Int32) -> Int32?
TreeView::row_at(Self, Double, height?~) -> Int32?
TreeView::visible_count(Self) -> Int32
TreeView::expanded_ids(Self) -> Array[Int32]
TreeView::is_expanded(Self, Int32) -> Bool
TreeView::set_root(Self, TreeNode) -> Unit raise UiError
```

每个组件都有 `widget()` 取回 `Widget[B]`。

## 10.13 绘制

```moonbit
DrawList::new() -> DrawList
DrawList::fill_rect(Self, Double, Double, Double, Double, radius?~, rgb~, alpha?~)
DrawList::stroke_rect(...)
DrawList::fill_linear(Self, Double, Double, Double, Double, stops~)
DrawList::fill_polygon(Self, Array[(Double, Double)], rgb~, alpha?~)
DrawList::line(Self, Double, Double, Double, Double, width?~, rgb~)
DrawList::stroke_arc(Self, Double, Double, Double, Double, Double, width?~, rgb~)
DrawList::shadow(Self, Double, Double, Double, Int32)
DrawList::blur_region(Self, Double, Double, Double, Double, Double)
DrawList::text(Self, String, Double, Double, size~, bold?~, rgb~)
DrawList::image(Self, Bytes, Double, Double, Double, Double)
DrawList::save() / restore() / clip_rect(...) / translate(Double, Double)
DrawList::commands(Self) -> Array[DrawCmd]
```

下一篇：[11 工程约定与边界](11-conventions-and-limits.md)。
