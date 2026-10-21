# MoonUI API 参考（中文）

MoonUI 是 MoonBit 的 GUI 框架。本文件是**对外公开 API 的完整中文参考**——覆盖 `packages/moonui` 主包与 `packages/moonui-app` 门面包的全部 `pub` 类型、函数与方法。签名以 `moon info` 生成的 `.mbti` 为准，代码示例均可编译（与 `packages/moonui/moonui_test.mbt` 中的 blackbox 测试同源）。

> 约定：所有公开 API 一律使用**逻辑像素**（LO 像素）。物理像素与 DPI 换算只发生在 `Scale` 与后端 C 侧，业务代码无需关心。

---

## 目录

- [1. 导入与别名](#1-导入与别名)
- [2. 最小可运行示例](#2-最小可运行示例)
- [3. 核心类型](#3-核心类型)
  - [3.1 错误 `UiError`](#31-错误-uierror)
  - [3.2 几何 `Logical*` / `Physical*` / `Scale` / `BoxConstraints` / `EdgeInsets`](#32-几何)
  - [3.3 样式 `Style` / `Color` / `Gradient` / `FontWeight`](#33-样式)
  - [3.4 主题 `Theme` / `Palette`](#34-主题-theme--palette)
  - [3.5 事件 `Event` / `EventTarget` / `MouseButton` / `KeyPress`](#35-事件)
  - [3.6 句柄 `NativeHandle` / `NativePtr` / `HandleTable`](#36-句柄)
- [4. 应用 `App`](#4-应用-app)
- [5. 窗口 `Window`](#5-窗口-window)
- [6. 控件 `Widget`](#6-控件-widget)
  - [6.1 原子控件构造器](#61-原子控件构造器)
  - [6.2 容器 / 布局控件构造器](#62-容器--布局控件构造器)
  - [6.3 流式属性设置（fluent）](#63-流式属性设置fluent)
  - [6.4 事件订阅](#64-事件订阅)
  - [6.5 状态读取 / 写入](#65-状态读取--写入)
  - [6.6 可访问性声明](#66-可访问性声明)
  - [6.7 自定义绘制面（`DrawList`）](#67-自定义绘制面drawlist)
  - [6.8 首批住户控件（`packages/widgets`）](#68-首批住户控件packageswidgets)
- [7. 组合组件（components）](#7-组合组件components)
- [8. 布局 `LayoutSpec`](#8-布局-layoutspec)
- [9. 菜单 `Menu` / `MenuBar` / `MenuItem`](#9-菜单)
- [10. 快捷键 `Shortcut`](#10-快捷键-shortcut)
- [11. 动画 `AnimationCurve`](#11-动画-animationcurve)
- [12. 可访问性 `Accessibility`](#12-可访问性-accessibility)
- [13. 国际化 `L10n`](#13-国际化-l10n)
- [14. 剪贴板 / 对话框 / 文件面板](#14-剪贴板--对话框--文件面板)
- [15. 窗口存档 `WindowFrame` / `WindowState`](#15-窗口存档-windowframe--windowstate)
- [16. 示例 Demo 辅助（库内复用）](#16-示例-demo-辅助库内复用)
- [17. 调试与测试 `MockBackend` / 事件追踪](#17-调试与测试)
- [18. 后端 `Backend` / `NativeBackend` / `CanvasBackend` / `new_app`](#18-后端)

---

## 1. 导入与别名

```moonbit
import { "username/MoonUI/packages/moonui" }          // 默认别名 @moonui
import { "username/MoonUI/packages/moonui-app" }       // 默认别名 @moonui-app
```

- `@moonui` 是主包（`packages/moonui`）的默认别名，本文件所有 `Widget::xxx`、`App::xxx` 都住在它下面。
- 写真窗口应用时再 import 后端包（如 `backends/native-common` / `backends/canvas-macos`）或直接使用门面包 `@moonui-app`。

---

## 2. 最小可运行示例

下面这段代码**原样可编译**（来自 README 与 `moonui_test.mbt`）：

```moonbit
///|
fn build(app : @moonui.App[@moonui.MockBackend]) -> Unit raise @moonui.UiError {
  let backend = app.backend()
  let message = @moonui.Widget::label(backend, "Hello MoonUI")
  let button = @moonui.Widget::button(backend, "Click Me")
  let _ = button.on_click(fn() raise @moonui.UiError {
    message.set_text("Clicked!")
  })
  let window = app.create_window("MoonUI", @moonui.LogicalSize::{ width: 800.0, height: 600.0 })
  window.set_content(@moonui.Widget::column(backend, 16.0, [message, button]))
  window.show()
}

/// 真窗口入口（macOS / Windows）
fn main raise {
  let app = @moonui-app.new_app()        // App[NativeBackend]
  let b = app.backend()
  let label = @moonui.Widget::label(b, "Hello MoonUI")
  let window = app.create_window("MoonUI", @moonui.LogicalSize::{ width: 800.0, height: 600.0 })
  window.set_content(@moonui.Widget::column(b, 16.0, [label]))
  window.show()
  app.run()?                            // 进入事件主循环
}
```

要点：

- 控件构造器一律收 **后端实例 `B`** 作首个参数（工具链尚无 `dyn`，后端在编译期随 `App[B]` 选定）。
- 大多数控件/窗口方法 `raise UiError`，调用处需 `raise UiError` 或继续上抛。
- `App::run()` 启动主循环；无头测试用 `App::step()` 单步推进（见 [§17](#17-调试与测试)）。

---

## 3. 核心类型

### 3.1 错误 `UiError`

```moonbit
pub(all) suberror UiError {
  InitializationFailed(String)
  BackendUnavailable(String)
  InvalidHandle
  OperationFailed(String)
  Unsupported(String)
  Destroyed
  AlreadyOwned
}
pub fn UiError::message(Self) -> String
pub fn UiError::to_string(Self) -> String
```

框架所有 fallible 操作统一返回 `UiError`。`BackendUnavailable` / `Unsupported` 来自尚未接好的平台能力（见 README「真后端」）；`InvalidHandle` / `Destroyed` 表示句柄已失效（窗口/控件关闭后误用）。

辅助函数：

```moonbit
pub fn[T] check_nonnull[T?](T?, String) -> T raise UiError   // None 时抛 InvalidHandle(msg)
pub fn format_size(Int) -> String                            // 字节数 → "12.3 KB"
pub fn path_text(Array[String]) -> String                    // 路径段 → "/a/b/c"
```

### 3.2 几何

所有坐标/尺寸均以**逻辑像素**表达（双精度）。

```moonbit
pub(all) struct LogicalPoint { x : Double, y : Double }
pub fn LogicalPoint::LogicalPoint(Double, Double) -> Self
pub fn LogicalPoint::offset(Self, Double, Double) -> Self

pub(all) struct LogicalSize { width : Double, height : Double }
pub fn LogicalSize::LogicalSize(Double, Double) -> Self
pub fn LogicalSize::area(Self) -> Double
pub fn LogicalSize::clamp(Self, Self, Self) -> Self
pub fn LogicalSize::non_negative(Self) -> Self
pub fn LogicalSize::zero() -> Self

pub(all) struct LogicalRect { origin : LogicalPoint, size : LogicalSize }
pub fn LogicalRect::LogicalRect(LogicalPoint, LogicalSize) -> Self
pub fn LogicalRect::center(Self, LogicalSize) -> Self           // 把某尺寸居中进本矩形
pub fn LogicalRect::contains(Self, LogicalPoint) -> Bool
pub fn LogicalRect::inset(Self, Double, Double, Double, Double) -> Self
pub fn LogicalRect::intersect(Self, Self) -> Self
pub fn LogicalRect::max(Self) -> LogicalPoint                   // 右下角
pub fn LogicalRect::normalized(Self) -> Self                    // 负宽高校正为正
```

物理像素（与后端通信、DPI 换算用）：

```moonbit
pub(all) struct PhysicalPoint { x : Int, y : Int }
pub fn PhysicalPoint::PhysicalPoint(Int, Int) -> Self
pub(all) struct PhysicalSize  { width : Int, height : Int }
pub fn PhysicalSize::PhysicalSize(Int, Int) -> Self
pub(all) struct PhysicalRect  { origin : PhysicalPoint, size : PhysicalSize }
pub fn PhysicalRect::PhysicalRect(PhysicalPoint, PhysicalSize) -> Self
```

```moonbit
pub(all) struct Scale { x : Double, y : Double }
pub fn Scale::one() -> Self
pub fn Scale::of_dpi(Double) -> Self              // dpi=192 → scale=2
pub fn Scale::normalized(Self) -> Self
pub fn Scale::to_logical_point(Self, PhysicalPoint) -> LogicalPoint
pub fn Scale::to_logical_rect(Self, PhysicalRect) -> LogicalRect
pub fn Scale::to_logical_size(Self, PhysicalSize) -> LogicalSize
pub fn Scale::to_physical_point(Self, LogicalPoint) -> PhysicalPoint
pub fn Scale::to_physical_rect(Self, LogicalRect) -> PhysicalRect
pub fn Scale::to_physical_size(Self, LogicalSize) -> PhysicalSize
```

布局约束与边距：

```moonbit
pub(all) struct BoxConstraints { min : LogicalSize, max : LogicalSize }
pub fn BoxConstraints::constrain(Self, LogicalSize) -> LogicalSize
pub fn BoxConstraints::loose(Double, Double) -> Self
pub fn BoxConstraints::tight(Double, Double) -> Self
pub fn BoxConstraints::unbounded() -> Self

pub(all) struct EdgeInsets { top : Double, end : Double, bottom : Double, start : Double }
pub fn EdgeInsets::all(Double) -> Self
pub fn EdgeInsets::symmetric(Double, Double) -> Self    // (纵向, 横向)
pub fn EdgeInsets::zero() -> Self
pub fn EdgeInsets::add(Self, Self) -> Self
pub fn EdgeInsets::horizontal(Self) -> Double
pub fn EdgeInsets::vertical(Self) -> Double
```

### 3.3 样式

```moonbit
pub(all) struct Style {
  width? : Double?
  height? : Double?
  min_width? : Double?
  max_width? : Double?
  margin? : EdgeInsets?
  padding? : EdgeInsets?
  background? : Color?
  background_gradient? : Gradient?
  foreground? : Color?
  font_size? : Double?
  font_weight? : FontWeight?
  radius? : Double?
  opacity? : Double?
  backdrop_blur? : Double?
}

pub fn style(
  width? : Double?, height? : Double?, min_width? : Double?, max_width? : Double?,
  margin? : EdgeInsets?, padding? : EdgeInsets?, background? : Color?,
  background_gradient? : Gradient?, foreground? : Color?, font_size? : Double?,
  font_weight? : FontWeight?, radius? : Double?, opacity? : Double?,
  backdrop_blur? : Double?
) -> Style

pub fn Style::empty() -> Self
pub fn Style::layer(Self, Self) -> Self          // 叠加两层样式（后者覆盖前者）
pub fn Style::effective_padding(Self) -> EdgeInsets
```

`style(...)` 是构造 `Style` 的便捷函数；`Style::layer` 用于主题/父容器/自身三层叠加（见 [§3.4](#34-主题-theme--palette)）。

```moonbit
pub(all) enum FontWeight { Regular, Medium, Bold }

pub(all) struct Color { r : Int, g : Int, b : Int, a : Int }   // 各分量 0..255
pub fn Color::rgb(Int, Int, Int) -> Self
pub fn Color::rgba(Int, Int, Int, Int) -> Self
pub fn Color::blend(Self, Self) -> Self
pub fn Color::luminance(Self) -> Double
pub fn Color::readable_foreground(Self) -> Self   // 按亮度返回黑/白可读前景

pub(all) enum GradientDir { Vertical, Horizontal }
pub(all) struct Gradient { dir : GradientDir, stops : Array[(Double, Color)] }
pub fn Gradient::horizontal(Color, Color) -> Self
pub fn Gradient::vertical(Color, Color) -> Self
pub fn Gradient::at(Self, Double) -> Color        // 取某比例处的颜色
pub fn Gradient::midpoint(Self) -> Color
```

### 3.4 主题 `Theme` / `Palette`

```moonbit
pub(all) enum Theme { Light, Dark, System }
pub fn Theme::default_style(Self, Self) -> Style   // (当前主题, 窗口主题) → 基础样式
pub fn Theme::resolve(Self, Self) -> Palette
pub fn Theme::light_palette() -> Palette
pub fn Theme::dark_palette() -> Palette

pub(all) struct Palette {
  background : Color
  surface : Color
  text : Color
  accent : Color
  border : Color
}
```

`App` 持有当前主题（`App::theme()`），`Window` 可通过样式层叠获得基础样式。`System` 主题在运行时由后端读取系统外观解析为 `Light`/`Dark`。

### 3.5 事件

```moonbit
pub(all) enum Event {
  Click(EventTarget, MouseButton)
  DoubleClick(EventTarget)
  Change(EventTarget)
  Input(EventTarget, String)
  Focus(EventTarget)
  Blur(EventTarget)
  Close(EventTarget)
  Resize(EventTarget, LogicalSize)
  Moved(EventTarget, LogicalPoint)
  KeyDown(EventTarget, KeyPress)
  KeyUp(EventTarget, KeyPress)
  MouseDown(EventTarget, MouseButton, LogicalPoint)
  MouseUp(EventTarget, MouseButton, LogicalPoint)
  MouseMove(EventTarget, LogicalPoint)
  MouseEnter(EventTarget)
  MouseLeave(EventTarget)
  Scroll(EventTarget, LogicalPoint)
  MenuSelect(EventTarget)
  ScaleChanged(EventTarget, Scale)
  ThemeChanged(EventTarget, Theme)
  Frame(EventTarget)
  ImeStart(EventTarget)
  ImeCompose(EventTarget, String)
  ImeEnd(EventTarget)
  LongPress(EventTarget)
  FileDrop(EventTarget, Array[String])
  Gesture(EventTarget, Gesture)
} derive(Eq, @debug.Debug)

pub fn Event::target(Self) -> EventTarget
pub fn Event::is_mouse_press(Self) -> Bool

/// 触控板手势（T100，§44 的 Touch 在桌面侧的形状）：桌面没有逐指触摸语义，
/// 有消费者的是捏合 / 双指旋转 / 双指滑动三种。增量都是"这一步"的，不是累计值。
pub(all) enum Gesture {
  Magnify(Double, GesturePhase)   // 相对缩放增量（NSEvent.magnification 同义，1+d）
  Rotate(Double, GesturePhase)    // 弧度，逆时针为正（C 里从角度换算，只换一次）
  Swipe(SwipeDirection)           // 离散：一次手势一条，没有相位与增量
}

pub(all) enum GesturePhase { Began; Changed; Ended; Cancelled }
pub(all) enum SwipeDirection { Left; Right; Up; Down }  // 手指的移动方向

pub(all) struct EventTarget { id : Int, generation : Int }   // 与 NativeHandle 同构
pub fn EventTarget::of(NativeHandle) -> Self

pub(all) enum MouseButton { Left, Right, Middle, Extra1, Extra2 }

pub(all) struct KeyPress {
  key : String, ctrl : Bool, alt : Bool, shift : Bool, meta : Bool
}
pub fn KeyPress::matches(Self, String, Bool, Bool, Bool, Bool) -> Bool
```

事件路由在 `App` 一处完成（捕获 → 目标 → 冒泡三阶段），详见 [§4](#4-应用-app) 订阅相关方法。`on_click` 等是 `Click` 的过滤器糖。

### 3.6 句柄

```moonbit
pub(all) struct NativeHandle { id : Int, generation : Int }
pub(all) struct NativePtr(Int64)
```

它们由框架内部生成并随控件/窗口进出生命周期，业务代码通常只经 `Widget::handle()` / `Window::handle()` 拿到并回填到 `EventTarget`，无需手动构造。`NativePtr` 是后端侧原生对象的 64 位指针封装。

句柄表（高级/测试用）：

```moonbit
pub struct HandleTable {
  slots : Array[HandleSlot]
  free_ids : Array[Int]
  mut live_count : Int
  mut high_water : Int
}
pub fn HandleTable::new() -> Self
pub fn HandleTable::register(Self, NativePtr) -> NativeHandle
pub fn HandleTable::resolve(Self, NativeHandle) -> NativePtr raise UiError
pub fn HandleTable::unregister(Self, NativeHandle) -> Unit raise UiError
pub fn HandleTable::is_alive(Self, NativeHandle) -> Bool
pub fn HandleTable::find_alive(Self, NativePtr) -> NativeHandle?
pub fn HandleTable::alive_handles(Self) -> Array[NativeHandle]
pub fn HandleTable::live(Self) -> Int
pub fn HandleTable::stats(Self) -> HandleStats
```

---

## 4. 应用 `App`

```moonbit
pub struct App[B] {
  backend : B
  windows : Array[Window[B]]
  mut theme : Theme
  mut anim_clock : (() -> Int)?
  mut anim_wake : ((Bool) -> Unit)?
  // ……（其余为内部状态：订阅表、任务队列、菜单、快捷键等）
}
```

构造与主循环：

```moonbit
pub fn[B : Backend] App::new(B) -> Self[B]
pub fn[B : Backend] App::run(Self[B]) -> Unit raise UiError        // 阻塞主循环
pub fn[B : Backend] App::step(Self[B]) -> Bool raise UiError       // 单步推进，false=已退出
pub fn[B] App::quit(Self[B]) -> Unit
pub fn[B] App::is_running(Self[B]) -> Bool
pub fn[B] App::is_finished(Self[B]) -> Bool
pub fn[B] App::backend(Self[B]) -> B
```

窗口管理：

```moonbit
pub fn[B : Backend] App::create_window(Self[B], String, LogicalSize) -> Window[B] raise UiError
pub fn[B : Backend] App::create_window_restored(
  Self[B], String, LogicalSize, WindowFrame?
) -> Window[B] raise UiError
pub fn[B] App::window_count(Self[B]) -> Int
pub fn[B] App::live_window_count(Self[B]) -> Int
```

事件分发与订阅：

```moonbit
pub fn[B : Backend] App::dispatch(Self[B], Event) -> Int raise UiError   // 手动派发，返回消费数
pub fn[B] App::on(
  Self[B], EventTarget, (Event) -> Bool, (Event) -> Unit raise UiError
) -> Int
pub fn[B] App::on_event(Self[B], EventTarget, (Event) -> Unit raise UiError) -> Int
pub fn[B] App::unsubscribe(Self[B], Int) -> Bool
pub fn[B] App::subscription_count(Self[B]) -> Int
```

`App::on` 的签名是 `(accept, handler)`：`accept(ev)` 返回 `true` 才交给 `handler`。返回值是订阅 id，用于 `unsubscribe`。

主题与外观：

```moonbit
pub fn[B] App::theme(Self[B]) -> Theme
pub fn[B : Backend] App::set_theme(Self[B], Theme) -> Unit raise UiError
pub fn[B : Backend] App::appearance(Self[B]) -> Theme raise UiError    // 系统外观（Light/Dark）
pub fn[B : Backend] App::palette(Self[B]) -> Palette raise UiError
pub fn[B] App::style_base(Self[B]) -> Style raise UiError
```

剪贴板 / 对话框 / 文件面板（见 [§14](#14-剪贴板--对话框--文件面板)）：

```moonbit
pub fn[B : Backend] App::clipboard_text(Self[B]) -> String? raise UiError
pub fn[B : Backend] App::set_clipboard_text(Self[B], String) -> Unit raise UiError
pub fn[B : Backend] App::show_message(Self[B], String, String) -> Unit raise UiError
pub fn[B : Backend] App::confirm(Self[B], String, String) -> Bool raise UiError
pub fn[B : Backend] App::open_file(Self[B], String) -> String? raise UiError
pub fn[B : Backend] App::save_file(Self[B], String, String) -> String? raise UiError
pub fn[B : Backend] App::select_folder(Self[B], String) -> String? raise UiError
```

菜单 / 托盘（见 [§9](#9-菜单)）：

```moonbit
pub fn[B] App::menubar(Self[B]) -> MenuBar?
pub fn[B : Backend] App::set_menubar(Self[B], MenuBar) -> Unit raise UiError
pub fn[B : Backend] App::click_menu_item(Self[B], Int) -> MenuItem? raise UiError
pub fn[B : Backend] App::set_tray_icon(Self[B], String) -> Unit raise UiError
pub fn[B : Backend] App::set_tray_menu(Self[B], Menu) -> Unit raise UiError
```

快捷键（见 [§10](#10-快捷键-shortcut)）：

```moonbit
pub fn[B] App::register_shortcut(
  Self[B], Shortcut, (Shortcut) -> Unit raise UiError
) -> Int
pub fn[B] App::unregister_shortcut(Self[B], Int) -> Bool
pub fn[B] App::fire_shortcut(Self[B], KeyPress) -> Int raise UiError
pub fn[B] App::shortcut_count(Self[B]) -> Int
pub fn[B] App::menu_accel_count(Self[B]) -> Int
```

动画时钟（见 [§11](#11-动画-animationcurve)）：

```moonbit
pub fn[B] App::set_anim_clock(Self[B], () -> Int) -> Unit       // 返回毫秒时钟
pub fn[B] App::set_anim_wake(Self[B], (Bool) -> Unit) -> Unit   // true=动画激活，切到高频轮询
```

应用图标 / 通知：

```moonbit
pub fn[B : Backend] App::set_icon(Self[B], String) -> Unit raise UiError   // 传不带扩展名的 stem
pub fn[B : Backend] App::notify(Self[B], String, String) -> Unit raise UiError
```

异步任务：

```moonbit
pub fn[B] App::post(Self[B], () -> Unit raise UiError) -> Unit         // 投递到主循环
pub fn[B] App::post_task(Self[B], () -> Unit raise UiError) -> TaskId  // 返回可取消的 id
pub fn[B] App::cancel_task(Self[B], TaskId) -> Bool
```

窗口存档（见 [§15](#15-窗口存档-windowframe--windowstate)）：

```moonbit
pub fn[B] App::load_window_state(Self[B], String) -> WindowFrame? raise UiError
pub fn[B : Backend] App::save_window_state(Self[B], String) -> Unit raise UiError
pub fn[B : Backend] App::window_frame(Self[B]) -> WindowFrame? raise UiError
```

拖拽联动：

```moonbit
pub fn[B : Backend] App::follow_move(Self[B], EventTarget, LogicalPoint) -> Bool
```

当某个窗口被拖动时，把邻居窗口一并搬到位（返回是否真的搬动了）。

事件追踪（调试用，见 [§17](#17-调试与测试)）：

```moonbit
pub fn[B] App::set_event_trace(Self[B], (DispatchTrace) -> Unit) -> Unit
pub fn[B] App::clear_event_trace(Self[B]) -> Unit
```

Dock / live redraw 开关（macOS dock 可见性、实时重绘）：

```moonbit
pub fn[B] App::dock_enabled(Self[B]) -> Bool
pub fn[B] App::set_dock_enabled(Self[B], Bool) -> Unit
pub fn[B] App::live_redraw(Self[B]) -> Bool
pub fn[B : Backend] App::set_live_redraw(Self[B], Bool) -> Unit raise UiError
```

---

## 5. 窗口 `Window`

```moonbit
pub struct Window[B] {
  backend : B
  handle : NativeHandle
  mut content : Widget[B]?
  mut closed : Bool
  // ……（其余为内部布局/尺寸状态）
}
```

```moonbit
pub fn[B : Backend] Window::new(B, String, LogicalSize) -> Self[B] raise UiError
pub fn[B : Backend] Window::show(Self[B]) -> Unit raise UiError
pub fn[B : Backend] Window::hide(Self[B]) -> Unit raise UiError
pub fn[B : Backend] Window::close(Self[B]) -> Unit raise UiError
pub fn[B] Window::is_closed(Self[B]) -> Bool
pub fn[B] Window::handle(Self[B]) -> NativeHandle
pub fn[B] Window::target(Self[B]) -> EventTarget
pub fn[B : Backend] Window::set_content(Self[B], Widget[B]) -> Unit raise UiError
pub fn[B] Window::content(Self[B]) -> Widget[B]?
```

几何与状态：

```moonbit
pub fn[B : Backend] Window::set_title(Self[B], String) -> Unit raise UiError
pub fn[B : Backend] Window::set_size(Self[B], LogicalSize) -> Unit raise UiError
pub fn[B : Backend] Window::size(Self[B]) -> LogicalSize raise UiError
pub fn[B : Backend] Window::physical_size(Self[B]) -> PhysicalSize raise UiError
pub fn[B : Backend] Window::set_position(Self[B], LogicalPoint) -> Unit raise UiError
pub fn[B : Backend] Window::set_position_animated(Self[B], LogicalPoint) -> Unit raise UiError
pub fn[B : Backend] Window::position(Self[B]) -> LogicalPoint raise UiError
pub fn[B : Backend] Window::set_resizable(Self[B], Bool) -> Unit raise UiError
pub fn[B : Backend] Window::set_min_size(Self[B], LogicalSize?) -> Unit raise UiError
pub fn[B : Backend] Window::set_max_size(Self[B], LogicalSize?) -> Unit raise UiError
pub fn[B] Window::min_size(Self[B]) -> LogicalSize?
pub fn[B] Window::max_size(Self[B]) -> LogicalSize?
pub fn[B : Backend] Window::set_minimized(Self[B], Bool) -> Unit raise UiError
pub fn[B : Backend] Window::set_maximized(Self[B], Bool) -> Unit raise UiError
pub fn[B : Backend] Window::set_fullscreen(Self[B], Bool) -> Unit raise UiError
pub fn[B : Backend] Window::set_titlebar_style(Self[B], TitlebarStyle) -> Unit raise UiError
pub fn[B : Backend] Window::set_traffic_light_position(Self[B], LogicalPoint) -> Unit raise UiError
pub fn[B] Window::live_redraw(Self[B]) -> Bool?
pub fn[B : Backend] Window::set_live_redraw(Self[B], Bool?) -> Unit raise UiError
```

`TitlebarStyle`：`Standard` / `Immersive`（沉浸式标题栏，内容延伸到标题区）。

HiDPI 与重排：

```moonbit
pub fn[B : Backend] Window::scale(Self[B]) -> Scale raise UiError
pub fn[B : Backend] Window::center(Self[B]) -> Unit raise UiError        // 居中到所在屏幕工作区
pub fn[B : Backend] Window::relayout(Self[B]) -> Unit raise UiError      // 主动重排内容
pub fn[B] Window::sync_size(Self[B], LogicalSize) -> LogicalSize raise UiError
pub fn[B : Backend] Window::apply_frame(Self[B], WindowFrame) -> Unit raise UiError
```

命中测试 / 状态读取：

```moonbit
pub fn[B] Window::widget_at(Self[B], LogicalPoint) -> Widget[B]?
pub fn[B : Backend] Window::window_state(Self[B]) -> WindowState raise UiError
pub fn[B : Backend] Window::dump_layout(Self[B]) -> String raise UiError
```

---

## 6. 控件 `Widget`

`Widget[B]` 是所有控件与容器的统一类型。原子控件（Label/Button…）与布局容器（Row/Column…）共用同一张句柄表。

### 6.1 原子控件构造器

```moonbit
pub fn[B : Backend] Widget::label(B, String) -> Self[B] raise UiError
pub fn[B : Backend] Widget::button(B, String) -> Self[B] raise UiError
pub fn[B : Backend] Widget::text_input(B, String) -> Self[B] raise UiError       // 单行输入
pub fn[B : Backend] Widget::password_input(B, String) -> Self[B] raise UiError   // 密码框
pub fn[B : Backend] Widget::checkbox(B, String, Bool) -> Self[B] raise UiError   // (文案, 初值)
pub fn[B : Backend] Widget::slider(B, Int, Int) -> Self[B] raise UiError         // (min, max)
pub fn[B : Backend] Widget::spinbox(B, Int, Int) -> Self[B] raise UiError
pub fn[B : Backend] Widget::progress(B) -> Self[B] raise UiError
pub fn[B : Backend] Widget::combobox(B, Array[String]) -> Self[B] raise UiError
pub fn[B : Backend] Widget::multiline(B, String) -> Self[B] raise UiError         // 多行编辑
pub fn[B : Backend] Widget::radio_buttons(B, Array[String]) -> Self[B] raise UiError
pub fn[B : Backend] Widget::date_picker(B) -> Self[B] raise UiError
pub fn[B : Backend] Widget::image(B) -> Self[B] raise UiError                   // 空图，用 set_image_* 填充
pub fn[B : Backend] Widget::separator(B) -> Self[B] raise UiError               // 水平分割线
pub fn[B : Backend] Widget::vseparator(B) -> Self[B] raise UiError              // 垂直分割线
pub fn[B : Backend] Widget::menu_row(B, String, Bool) -> Self[B] raise UiError  // (文案, 勾选)
pub fn[B : Backend] Widget::gradient_panel(
  B, Gradient, total~ : Double, width? : Double?, bands? : Int
) -> Self[B] raise UiError
pub fn[B : Backend] Widget::spacer(B) -> Self[B] raise UiError                 // 弹性空白
pub fn[B : Backend] Widget::custom(
  B, LogicalSize, (DrawList, PaintEnv) -> Unit
) -> Self[B] raise UiError                                                      // 自定义绘制面（见 6.7）
```

### 6.2 容器 / 布局控件构造器

```moonbit
pub fn[B : Backend] Widget::row(B, Double, Array[Self[B]]) -> Self[B] raise UiError      // (间距, 子项)
pub fn[B : Backend] Widget::column(B, Double, Array[Self[B]]) -> Self[B] raise UiError
pub fn[B : Backend] Widget::panel(B, Self[B]) -> Self[B] raise UiError                    // 单子容器（背景板）
pub fn[B : Backend] Widget::padding(B, EdgeInsets, Self[B]) -> Self[B] raise UiError
pub fn[B : Backend] Widget::sized(B, Double?, Double?, Self[B]) -> Self[B] raise UiError  // (宽?, 高?, 子)
pub fn[B : Backend] Widget::scroll(B, Axis, Self[B]) -> Self[B] raise UiError             // (轴, 子)
pub fn[B : Backend] Widget::center(B, Self[B]) -> Self[B] raise UiError                   // 居中子项
pub fn[B : Backend] Widget::stack(B, Array[Self[B]]) -> Self[B] raise UiError            // 层叠，后者在上
pub fn[B : Backend] Widget::grid(B, Int, Double, Array[Self[B]]) -> Self[B] raise UiError // (列数, 间距, 子)
```

`Axis`：`Horizontal` / `Vertical`。

### 6.3 流式属性设置（fluent）

下列方法返回 `Self[B]`，可链式书写（`raise UiError` 需向上传递）：

```moonbit
pub fn[B] Widget::background(Self[B], Color) -> Self[B] raise UiError
pub fn[B] Widget::foreground(Self[B], Color) -> Self[B] raise UiError
pub fn[B] Widget::font_size(Self[B], Double) -> Self[B] raise UiError
pub fn[B] Widget::font_weight(Self[B], FontWeight) -> Self[B] raise UiError
pub fn[B] Widget::radius(Self[B], Double) -> Self[B] raise UiError
pub fn[B] Widget::opacity(Self[B], Double) -> Self[B] raise UiError
pub fn[B] Widget::margin(Self[B], EdgeInsets) -> Self[B] raise UiError
pub fn[B] Widget::width(Self[B], Double) -> Self[B] raise UiError
pub fn[B] Widget::height(Self[B], Double) -> Self[B] raise UiError
pub fn[B] Widget::min_width(Self[B], Double) -> Self[B] raise UiError
pub fn[B] Widget::max_width(Self[B], Double) -> Self[B] raise UiError
pub fn[B] Widget::expand(Self[B]) -> Bool
pub fn[B] Widget::set_expand(Self[B], Bool) -> Unit raise UiError
pub fn[B] Widget::with_expand(Self[B], Bool) -> Self[B] raise UiError
pub fn[B] Widget::spacing(Self[B]) -> Double raise UiError
pub fn[B] Widget::set_spacing(Self[B], Double) -> Unit raise UiError
pub fn[B] Widget::with_spacing(Self[B], Double) -> Self[B] raise UiError
pub fn[B] Widget::insets(Self[B]) -> EdgeInsets raise UiError
pub fn[B] Widget::set_insets(Self[B], EdgeInsets) -> Unit raise UiError
pub fn[B] Widget::with_insets(Self[B], EdgeInsets) -> Self[B] raise UiError
```

`expand` 表示在父容器交叉轴上撑满（占满整行/整列高度）。

示例：

```moonbit
let title = @moonui.Widget::label(b, "标题")
  .font_size(18.0)
  .font_weight(Bold)
  .foreground(@moonui.Color::rgb(20, 20, 20))
  .margin(@moonui.EdgeInsets::all(8.0))
```

### 6.4 事件订阅

```moonbit
pub fn[B] Widget::on(Self[B], (Event) -> Bool, (Event) -> Unit raise UiError) -> Int raise UiError
pub fn[B] Widget::on_any(Self[B], (Event) -> Unit raise UiError) -> Int raise UiError
pub fn[B] Widget::on_capture(Self[B], (Event) -> Bool, (Event) -> Bool raise UiError) -> Int raise UiError
pub fn[B] Widget::on_bubble(Self[B], (Event) -> Bool, (Event) -> Unit raise UiError) -> Int raise UiError
pub fn[B] Widget::on_click(Self[B], () -> Unit raise UiError) -> Int raise UiError
pub fn[B] Widget::on_double_click(Self[B], () -> Unit raise UiError) -> Int raise UiError
pub fn[B] Widget::on_change(Self[B], () -> Unit raise UiError) -> Int raise UiError
pub fn[B] Widget::on_input(Self[B], (String) -> Unit raise UiError) -> Int raise UiError
pub fn[B] Widget::on_focus(Self[B], () -> Unit raise UiError) -> Int raise UiError
pub fn[B] Widget::on_blur(Self[B], () -> Unit raise UiError) -> Int raise UiError
pub fn[B] Widget::with_on_any(Self[B], (Event) -> Unit raise UiError) -> Self[B] raise UiError
pub fn[B] Widget::with_on_click(Self[B], () -> Unit raise UiError) -> Self[B] raise UiError
pub fn[B] Widget::with_on_change(Self[B], () -> Unit raise UiError) -> Self[B] raise UiError
pub fn[B] Widget::with_on_input(Self[B], (String) -> Unit raise UiError) -> Self[B] raise UiError
pub fn[B] Widget::with_on_focus / with_on_blur / with_on_double_click(...) -> Self[B]
```

- `on_capture` / `on_bubble` 对应事件路由的捕获阶段与冒泡阶段；`on` 默认走目标+冒泡。
- `with_*` 是返回 `Self` 的订阅糖，方便在构造链里写。
- 返回值是 handler id；`Widget` 跟随父控件销毁时自动解除。

### 6.5 状态读取 / 写入

读取：

```moonbit
pub fn[B] Widget::handle(Self[B]) -> NativeHandle?
pub fn[B] Widget::target(Self[B]) -> EventTarget raise UiError
pub fn[B] Widget::kind(Self[B]) -> WidgetKind
pub fn[B] Widget::frame(Self[B]) -> LogicalRect
pub fn[B : Backend] Widget::bounds(Self[B]) -> LogicalRect raise UiError
pub fn[B : Backend] Widget::intrinsic_size(Self[B]) -> LogicalSize raise UiError
pub fn[B : Backend] Widget::text(Self[B]) -> String raise UiError
pub fn[B : Backend] Widget::value(Self[B]) -> Int raise UiError
pub fn[B : Backend] Widget::checked(Self[B]) -> Bool raise UiError
pub fn[B : Backend] Widget::selected(Self[B]) -> Int raise UiError
pub fn[B : Backend] Widget::enabled(Self[B]) -> Bool raise UiError
pub fn[B : Backend] Widget::visible(Self[B]) -> Bool raise UiError
pub fn[B : Backend] Widget::datetime_text(Self[B]) -> String raise UiError   // DatePicker 当前值
pub fn[B] Widget::style(Self[B]) -> Style?
pub fn[B] Widget::axis(Self[B]) -> Axis raise UiError
pub fn[B] Widget::columns(Self[B]) -> Int raise UiError
pub fn[B] Widget::children(Self[B]) -> Array[Self[B]]
pub fn[B] Widget::parent(Self[B]) -> Self[B]?
pub fn[B] Widget::is_attached(Self[B]) -> Bool
pub fn[B] Widget::is_closed(Self[B]) -> Bool
pub fn[B] Widget::handler_count(Self[B]) -> Int
```

写入：

```moonbit
pub fn[B : Backend] Widget::set_text(Self[B], String) -> Unit raise UiError
pub fn[B : Backend] Widget::set_value(Self[B], Int) -> Unit raise UiError
pub fn[B : Backend] Widget::set_checked(Self[B], Bool) -> Unit raise UiError
pub fn[B : Backend] Widget::set_selected(Self[B], Int) -> Unit raise UiError
pub fn[B : Backend] Widget::set_range(Self[B], Int, Int) -> Unit raise UiError       // (min, max)
pub fn[B : Backend] Widget::set_enabled(Self[B], Bool) -> Unit raise UiError
pub fn[B : Backend] Widget::set_visible(Self[B], Bool) -> Unit raise UiError
pub fn[B : Backend] Widget::set_bounds(Self[B], LogicalRect) -> Unit raise UiError
pub fn[B : Backend] Widget::set_style(Self[B], Style?) -> Unit raise UiError
pub fn[B] Widget::set_hover_style(Self[B], Style?) -> Unit raise UiError           // 悬停态样式
pub fn[B : Backend] Widget::set_icon(Self[B], String) -> Unit raise UiError
pub fn[B : Backend] Widget::set_image_path(Self[B], String) -> Unit raise UiError
pub fn[B : Backend] Widget::set_image_bytes(Self[B], Bytes) -> Unit raise UiError
pub fn[B : Backend] Widget::set_datetime_text(Self[B], String) -> Unit raise UiError
pub fn[B : Backend] Widget::repaint(Self[B]) -> Unit raise UiError                 // 自定义绘制面重画（非 Custom 是空操作）
pub fn[B : Backend] Widget::append_option(Self[B], String) -> Unit raise UiError   // 给 ComboBox 加项
pub fn[B : Backend] Widget::set_context_menu(Self[B], Menu) -> Unit raise UiError
pub fn[B] Widget::add_child(Self[B], Self[B]) -> Unit raise UiError
pub fn[B] Widget::with_child(Self[B], Self[B]) -> Self[B] raise UiError
pub fn[B] Widget::with_children(Self[B], Array[Self[B]]) -> Self[B] raise UiError
pub fn[B] Widget::with_text(Self[B], String) -> Self[B] raise UiError
pub fn[B] Widget::with_value(Self[B], Int) -> Self[B] raise UiError
pub fn[B] Widget::with_checked(Self[B], Bool) -> Self[B] raise UiError
pub fn[B] Widget::with_selected(Self[B], Int) -> Self[B] raise UiError
pub fn[B] Widget::with_enabled(Self[B], Bool) -> Self[B] raise UiError
pub fn[B] Widget::with_visible(Self[B], Bool) -> Self[B] raise UiError
pub fn[B] Widget::with_style(Self[B], Style?) -> Self[B] raise UiError
```

派发（手动触发事件，测试/外部驱动用）：

```moonbit
pub fn[B] Widget::fire(Self[B], Event) -> Int raise UiError
```

布局（控件本身也是布局节点，可转成 `LayoutSpec`）：

```moonbit
pub fn[B : Backend] Widget::to_layout_spec(Self[B]) -> LayoutSpec raise UiError
pub fn[B : Backend] Widget::measure(Self[B], BoxConstraints) -> LogicalSize raise UiError
pub fn[B : Backend] Widget::do_layout(Self[B], LogicalRect) -> Array[Placed] raise UiError
pub fn[B : Backend] Widget::dump_layout(Self[B]) -> String raise UiError
pub fn[B] Widget::find_by_id(Self[B], Int) -> Self[B]?
pub fn[B] Widget::find_by_target(Self[B], EventTarget) -> Self[B]?
pub fn[B] Widget::leaf_count(Self[B]) -> Int
```

### 6.6 可访问性声明

```moonbit
pub fn[B] Widget::set_access_role(Self[B], AccessRole?) -> Unit raise UiError
pub fn[B] Widget::set_access_label(Self[B], String?) -> Unit raise UiError
pub fn[B] Widget::set_access_description(Self[B], String?) -> Unit raise UiError
pub fn[B] Widget::with_access_role(Self[B], AccessRole?) -> Self[B] raise UiError
pub fn[B] Widget::with_access_label(Self[B], String?) -> Self[B] raise UiError
pub fn[B] Widget::with_access_description(Self[B], String?) -> Self[B] raise UiError
pub fn[B] Widget::access_role(Self[B]) -> AccessRole?
pub fn[B] Widget::access_label(Self[B]) -> String?
pub fn[B] Widget::access_description(Self[B]) -> String?
pub fn[B : Backend] Widget::accessibility(Self[B]) -> Accessibility? raise UiError
pub fn[B : Backend] Widget::accessibility_tree(Self[B]) -> Array[Accessibility] raise UiError
```

### 6.7 自定义绘制面（`DrawList`）

`Widget::custom(size, paint)` 造一块**由应用自己画**的面：Core 只负责给它布局（尺寸取声明值，`.width()`/`.height()` 照常覆盖）与派发点击，画什么由 `paint` 回调决定。

```moonbit
// 绘制面：声明尺寸 + 绘制回调
let face = Widget::custom(b, LogicalSize(160.0, 80.0), fn(dl, env) {
  dl.fill_rect(0.0, 0.0, env.width(), env.height(), radius=6.0, rgb=0x2B6CB0)
  let (tw, th) = env.measure_text("42%", 14.0, true)
  dl.text("42%", (env.width() - tw) / 2.0, (env.height() - th) / 2.0,
    size=14.0, bold=true, rgb=0xFFFFFF)
})
let _ = face.on_any(fn(ev) { ... })   // 点击与别的控件同一条订阅口子
// 数据变了就重画——Core 不缓存清单
face.repaint()
```

回调拿到两样东西：

```moonbit
pub(all) struct PaintEnv {
  size : LogicalSize                            // 这块面多大
  measure : (String, Double, Bool) -> (Double, Double)
}
pub fn PaintEnv::measure_text(Self, String, size : Double, bold : Bool) -> (Double, Double)
pub fn PaintEnv::width(Self) -> Double
pub fn PaintEnv::height(Self) -> Double
```

`DrawList` 是**纯数据**的命令清单（这也正是 Core 不持画笔的原因：画笔住在后端包，拿进 Core 就把依赖方向反过来）。命令与后端 `Painter` 的方法一一对应，重放由后端做：

```moonbit
pub(all) enum DrawCmd {
  FillRect(Double, Double, Double, Double, Double, radius, Int32 rgb, Int32 alpha)
  StrokeRect(Double, Double, Double, Double, Double, Double, Int32)
  FillLinear(Double, Double, Double, Double, Array[(Double, Int32)])
  Shadow(Double, Double, Double, Int32)
  Line(Double, Double, Double, Double, Double, Int32)
  StrokeArc(Double, Double, Double, Double, Double, Double, Int32)  // T109：圆心、半径、起始角(度)、扫过角(度)、线宽、rgb
  FillPolygon(Array[(Double, Double)], Int32 rgb, Int32 alpha)  // T109：闭合轮廓顶点表、rgb、alpha
  BlurRegion(Double, Double, Double, Double, Double)
  Text(String, Double, Double, Double, Bool, Int32)
  Image(Bytes, Double, Double, Double, Double)
  Save
  Restore
  ClipRect(Double, Double, Double, Double)
  Translate(Double, Double)
}

pub fn DrawList::new() -> DrawList
pub fn DrawList::len(Self) -> Int
pub fn DrawList::is_empty(Self) -> Bool
pub fn DrawList::commands(Self) -> Array[DrawCmd]        // 测试断言口
// 便捷写入（除 save/restore 外都追加一条命令）
pub fn DrawList::fill_rect(Self, x, y, w, h, radius~, rgb~, alpha~) -> Unit
pub fn DrawList::stroke_rect(Self, x, y, w, h, radius~, width~, rgb~) -> Unit
pub fn DrawList::fill_linear(Self, x, y, w, h, stops~) -> Unit
pub fn DrawList::shadow(Self, dx, dy, blur, rgb) -> Unit
pub fn DrawList::line(Self, x0, y0, x1, y1, width~, rgb~) -> Unit
pub fn DrawList::stroke_arc(Self, cx, cy, r, start_deg~, sweep_deg~, width~, rgb~) -> Unit  // T109
pub fn DrawList::fill_polygon(Self, points, rgb~, alpha~) -> Unit  // T109：顶点不足三个不进清单
pub fn DrawList::blur_region(Self, x, y, w, h, radius) -> Unit
pub fn DrawList::text(Self, String, x, y, size~, bold~, rgb~) -> Unit
pub fn DrawList::image(Self, Bytes, x, y, w, h) -> Unit
pub fn DrawList::save(Self) -> Unit
pub fn DrawList::restore(Self) -> Unit
pub fn DrawList::clip_rect(Self, x, y, w, h) -> Unit
pub fn DrawList::translate(Self, dx, dy) -> Unit
```

三条要记住的约定：

1. **坐标是控件局部的逻辑像素**（原点 = 控件左上角、y 向下），与布局口径一致。逻辑→物理只换一次，归后端——在回调里再乘一次 `Scale` 就是"除两次"的经典 HiDPI 位移。
2. **每次绘制都是一整份新清单**，后端整份重放；`repaint()` 不叠加在上一帧上。所以改数据后要显式调它，Core 不替你猜缓存何时失效。
3. **尺寸为零不画**：还没摆出来的控件是 0×0，`paint` 不会跑（`repaint()` 也空过），摆出来那次自动画第一帧。

后端支撑度：mac 原生后端已接（画进控件自己的 `layer`）；Windows 原生半如实缺席（与 Direct2D 同一笔欠账），`draw_custom` 会 raise。命中测试与点击走与按钮同一套槽位机制，但自定义面**没有** `set_text`/`set_value`/`set_checked` 这类属性——它就不是那种控件。

### 6.8 首批住户控件（`packages/widgets`）

`packages/widgets`（`T107`）是建在 §6.7 之上的控件包，**只 import Core、不碰任何后端**——所以同一份配方在原生后端、自绘后端、mock 上都成立。包里的控件各自持有一份可变状态，`set_*` 改完立刻 `repaint()`（不需要你手动重画）。

```moonbit
import { "username/MoonUI/packages/widgets" }

// 环形进度：0..1，中心自动显示百分比（label="" 时）
let ring = @widgets.ProgressRing::new(b, 0.42, size=96.0, thickness=8.0)
// 折线图：一串点，自适应值域，端点画一个圆
let spark = @widgets.Sparkline::new(b, [3.0, 7.0, 5.0, 9.0], width=160.0, height=48.0)

let body = Widget::column(b, 12.0, [ring.widget(), spark.widget()])
win.set_content(body)

ring.set_value(0.75)   // 自动重画
spark.push(11.0)       // 追加一点（设了 max_points 就是滚动窗口）

// 数据表（T102）：固定列宽 + 表头 + 斑马 + 选中，行按视口虚拟化
let cols = [
  @widgets.GridColumn::new("名称", 120.0),
  @widgets.GridColumn::new("大小", 80.0, right=true, numeric=true),  // 数字列：右对齐 + 按数值排
]
let grid = @widgets.DataGrid::new(b, cols,
  rows=[["a.txt", "12"], ["b.bin", "930"]], width=200.0, height=120.0)
let page = Widget::column(b, 12.0, [grid.widget()])
win.set_content(page)

grid.set_rows([["c.md", "7"]])   // 整份换数据（选中/偏移顺手收尾）
grid.scroll_to_row(40)           // 滚到第 40 行（越界夹到最后一行贴底）
grid.select_row(2)               // 高亮一行；越界 = 清掉选中
grid.sort_by_column(1)           // 按"大小"升序（同一列再点一次翻降序）；表头画箭头
grid.clear_sort()                // 回到原序
// 点表头就排序是**默认接线**（T110）：不用调 sort_by_column，自绘面收到带
// 坐标的 MouseDown，表自己判断落在表头哪一列。同列再点翻方向；点正文不排。
// 滚轮也是**默认接线**（T102 第八刀）：落在表上的滚动直接推到 offset / h_offset
// （增量是逻辑像素，不乘行高；两端按"最后一行贴底"夹住），应用层不用转发。
// 注意：mac 原生后端目前把滚轮报给窗口自己（T102 记案），那一侧这一条默认接线
// 收不到；mock 与自绘后端能到控件。

// 树（T102）：嵌套节点 → 扁平化 → 按视口虚拟化，缩进/箭头/参考线都是画出来的
let root = @widgets.TreeNode::new(1, "src", children=[
  @widgets.TreeNode::new(2, "main.mbt", detail="4.2 KB"),
  @widgets.TreeNode::new(3, "lib", children=[
    @widgets.TreeNode::new(4, "draw.mbt"),
  ]),
])
let tree = @widgets.TreeView::new(b, root, width=240.0, height=300.0,
  expanded=[1, 3])                  // 初始展开的 id
win.set_content(tree.widget())

tree.toggle_at(x, y)                // 点箭头那一格就折叠/展开（返回被动的 id）
tree.select_id(4)                   // 选中按 id 记（行号会随展开变化）
tree.scroll_to_row(tree.row_of(4).unwrap_or(0))
// 滚轮默认接线（T102 第八刀）：落在树上的纵向滚动直接推 offset（逻辑像素、
// "最后一行贴底"夹住）；树没有横向滚动。
```

```moonbit
// ProgressRing
pub fn[B : Backend] ProgressRing::new(B, Double value, size~ : Double = 96.0,
  thickness~ : Double = 8.0, track~ : Int32 = 0xE2E8F0, accent~ : Int32 = 0x2B6CB0,
  text_color~ : Int32 = 0x1A202C, label~ : String = "", show_label~ : Bool = true,
  font_size~ : Double = 0.0) -> ProgressRing[B] raise UiError
pub fn[B] ProgressRing::widget(Self[B]) -> Widget[B]
pub fn[B] ProgressRing::value(Self[B]) -> Double
pub fn[B] ProgressRing::side(Self[B]) -> Double
pub fn[B : Backend] ProgressRing::set_value(Self[B], Double) -> Unit raise UiError
pub fn[B : Backend] ProgressRing::set_label(Self[B], String) -> Unit raise UiError
pub fn[B : Backend] ProgressRing::set_show_label(Self[B], Bool) -> Unit raise UiError
pub fn[B : Backend] ProgressRing::set_accent(Self[B], Int32) -> Unit raise UiError

// Sparkline
pub fn[B : Backend] Sparkline::new(B, Array[Double], width~ : Double = 160.0,
  height~ : Double = 48.0, line~ : Int32 = 0x2B6CB0, line_width~ : Double = 1.5,
  baseline~ : Bool = false, baseline_color~ : Int32 = 0xE2E8F0, dot~ : Double = 3.0,
  min~ : Double? = None, max~ : Double? = None,
  max_points~ : Int32 = 0) -> Sparkline[B] raise UiError
pub fn[B] Sparkline::widget(Self[B]) -> Widget[B]
pub fn[B] Sparkline::size(Self[B]) -> LogicalSize
pub fn[B] Sparkline::length(Self[B]) -> Int32
pub fn[B] Sparkline::series(Self[B]) -> Array[Double]        // 拷贝
pub fn[B : Backend] Sparkline::set_series(Self[B], Array[Double]) -> Unit raise UiError
pub fn[B : Backend] Sparkline::push(Self[B], Double) -> Unit raise UiError
pub fn[B : Backend] Sparkline::set_range(Self[B], min~ : Double?, max~ : Double?) -> Unit raise UiError
pub fn[B : Backend] Sparkline::set_line_color(Self[B], Int32) -> Unit raise UiError

// GridColumn
pub fn GridColumn::new(String title, Double width, right~ : Bool = false,
  numeric~ : Bool = false) -> GridColumn raise UiError
pub fn GridColumn::title(Self) -> String
pub fn GridColumn::width(Self) -> Double
pub fn GridColumn::right_align(Self) -> Bool
pub fn GridColumn::is_numeric(Self) -> Bool

// DataGrid（T102）
pub fn[B : Backend] DataGrid::new(B, Array[GridColumn], rows~ : Array[Array[String]] = [],
  width~ : Double = 360.0, height~ : Double = 220.0, row_height~ : Double = 24.0,
  header_height~ : Double = 28.0, font_size~ : Double = 12.0,
  header_font_size~ : Double = 0.0, pad~ : Double = 8.0, auto_width~ : Bool = false,
  zebra~ : Bool = true,
  bg~ : Int32 = 0xFFFFFF, header_bg~ : Int32 = 0xF1F5F9, zebra_bg~ : Int32 = 0xF7FAFC,
  selected_bg~ : Int32 = 0xEBF4FF, text_color~ : Int32 = 0x1A202C,
  header_text~ : Int32 = 0x4A5568, border~ : Int32 = 0xE2E8F0,
  empty_text~ : String = "") -> DataGrid[B] raise UiError
pub fn[B] DataGrid::widget(Self[B]) -> Widget[B]
pub fn[B] DataGrid::size(Self[B]) -> LogicalSize
pub fn[B] DataGrid::row_count(Self[B]) -> Int32
pub fn[B] DataGrid::column_count(Self[B]) -> Int32
pub fn[B] DataGrid::row_height(Self[B]) -> Double
pub fn[B] DataGrid::header_height(Self[B]) -> Double
pub fn[B] DataGrid::offset(Self[B]) -> Double
pub fn[B] DataGrid::h_offset(Self[B]) -> Double            // 横向偏移（自适应模式下恒为 0）
pub fn[B] DataGrid::selected(Self[B]) -> Int32            // -1 = 没选中（数据行号）
pub fn[B] DataGrid::cell(Self[B], Int32 row, Int32 col) -> String?
pub fn[B] DataGrid::row_at(Self[B], Double y, height~ : Double = -1.0) -> Int32?   // 数据行号
pub fn[B] DataGrid::column_at(Self[B], Double x, width~ : Double = -1.0) -> Int32?
pub fn[B : Backend] DataGrid::set_rows(Self[B], Array[Array[String]]) -> Unit raise UiError
pub fn[B : Backend] DataGrid::set_cell(Self[B], Int32 row, Int32 col, String) -> Unit raise UiError
pub fn[B : Backend] DataGrid::set_offset(Self[B], Double) -> Unit raise UiError
pub fn[B : Backend] DataGrid::scroll_to_row(Self[B], Int32) -> Unit raise UiError   // 数据行号
pub fn[B : Backend] DataGrid::set_h_offset(Self[B], Double) -> Unit raise UiError
pub fn[B : Backend] DataGrid::scroll_to_column(Self[B], Int32) -> Unit raise UiError
pub fn[B] DataGrid::sort_column(Self[B]) -> Int32            // -1 = 没排序
pub fn[B] DataGrid::sort_ascending(Self[B]) -> Bool
pub fn[B : Backend] DataGrid::sort_by_column(Self[B], Int32) -> Unit raise UiError
pub fn[B : Backend] DataGrid::clear_sort(Self[B]) -> Unit raise UiError
pub fn[B : Backend] DataGrid::select_row(Self[B], Int32) -> Unit raise UiError

// TreeNode（T102）
pub fn TreeNode::new(Int32 id, String label, children~ : Array[TreeNode] = [],
  detail~ : String = "") -> TreeNode
pub fn TreeNode::id(Self) -> Int32
pub fn TreeNode::label(Self) -> String
pub fn TreeNode::detail(Self) -> String
pub fn TreeNode::child_count(Self) -> Int32
pub fn TreeNode::is_leaf(Self) -> Bool

// TreeView（T102）
pub fn[B : Backend] TreeView::new(B, TreeNode root, width~ : Double = 240.0,
  height~ : Double = 300.0, row_height~ : Double = 22.0, font_size~ : Double = 12.0,
  indent~ : Double = 14.0, pad~ : Double = 8.0, show_root~ : Bool = false,
  expanded~ : Array[Int32] = [], guides~ : Bool = true, bg~ : Int32 = 0xFFFFFF,
  selected_bg~ : Int32 = 0xEBF4FF, text_color~ : Int32 = 0x1A202C,
  detail_color~ : Int32 = 0x718096, glyph_color~ : Int32 = 0x718096,
  guide_color~ : Int32 = 0xE2E8F0, empty_text~ : String = "") -> TreeView[B] raise UiError
pub fn[B] TreeView::widget(Self[B]) -> Widget[B]
pub fn[B] TreeView::size(Self[B]) -> LogicalSize
pub fn[B] TreeView::visible_count(Self[B]) -> Int32
pub fn[B] TreeView::visible_id(Self[B], Int32 row) -> Int32?
pub fn[B] TreeView::visible_depth(Self[B], Int32 row) -> Int32?
pub fn[B] TreeView::row_of(Self[B], Int32 id) -> Int32?
pub fn[B] TreeView::row_at(Self[B], Double y, height~ : Double = -1.0) -> Int32?
pub fn[B] TreeView::offset(Self[B]) -> Double
pub fn[B] TreeView::row_height(Self[B]) -> Double
pub fn[B] TreeView::selected_id(Self[B]) -> Int32            // -1 = 没选中
pub fn[B] TreeView::is_expanded(Self[B], Int32 id) -> Bool
pub fn[B] TreeView::expanded_ids(Self[B]) -> Array[Int32]    // 拷贝
pub fn[B : Backend] TreeView::toggle_at(Self[B], Double x, Double y,
  height~ : Double = -1.0) -> Int32? raise UiError
pub fn[B : Backend] TreeView::set_root(Self[B], TreeNode) -> Unit raise UiError
pub fn[B : Backend] TreeView::expand(Self[B], Int32 id) -> Unit raise UiError
pub fn[B : Backend] TreeView::collapse(Self[B], Int32 id) -> Unit raise UiError
pub fn[B : Backend] TreeView::toggle(Self[B], Int32 id) -> Unit raise UiError
pub fn[B : Backend] TreeView::expand_all(Self[B]) -> Unit raise UiError
pub fn[B : Backend] TreeView::collapse_all(Self[B]) -> Unit raise UiError
pub fn[B : Backend] TreeView::set_expanded(Self[B], Array[Int32]) -> Unit raise UiError
pub fn[B : Backend] TreeView::select_id(Self[B], Int32 id) -> Unit raise UiError
pub fn[B : Backend] TreeView::set_offset(Self[B], Double) -> Unit raise UiError
pub fn[B : Backend] TreeView::scroll_to_row(Self[B], Int32) -> Unit raise UiError
```

画法上有四条要知道的：

1. **环用 `DrawList::stroke_arc` 画**（`T109` 第一刀已落）：轨道整圈 + 进度一段，各是一条弧命令，角度口径 0° = 三点钟、顺时针为正。落地前它是一串 `Line` 拼的（每 5°），`StrokeArc` 把 72 条降到 2 条、也消除了粗线宽下的接缝；`DrawList` 仍缺"闭合多边形填充"，所以面积图还没做。
2. **折线图没有面积填充**：那需要闭合多边形填充，同一个缺口（TODO `T109` 的第二笔 `FillPolygon`）。`area~` 是它落地后第一个要加的参数。
3. **颜色自己传**：`Theme` 挂在 `App` 上，控件拿不到它，所以色板由调用方给（默认值是一套中性色）。等 Core 长出"控件读主题令牌"的口子再收编，不在控件包里另造一套主题。
4. **数据表的虚拟化省的是命令、不是句柄**：`VirtualList`（`T86④`）靠"视口内建、窗外销毁原生子控件"省句柄；自绘面只有**一个**原生对象，所以 `DataGrid` 只给与正文矩形相交的行产出命令——滚到第 500 行时前 499 行一条命令都不发，窗口起点是同一条算术（`floor(偏移 / 行高)`）。偏移由调用方推（`set_offset` / `scroll_to_row`）：Core 的事件（`MouseDown` / `MouseMove` / `Scroll`）坐标是**窗口/父局部**的，且 mac 的滚轮恒报窗口自己，所以"指针在不在表上、落在第几行"要交给拿着 `App` 的那一层——`row_at(y - 控件 frame 原点)` 就是给它的那一半。单元格文案先量后画：放得下就直接画，放不下才二分求"前缀 + 省略号"并夹在文字区（右对齐列截断后仍贴右边）。这条省略算术与树共用同一份实现（包内 `text_fit.mbt`），所以两边的省略号宽度不会漂。
   **列宽可以自适应**（`auto_width=true`，`T102` 第三刀）：每列取"自然宽"（表头与该列最宽的一格取较宽者，再加左右内边距）与声明宽（**当下限**）的较大者；装得下就按自然宽排布（富余留在右侧，不摊开——摊开之后左对齐的文字列会散得很开，跨列对读更难），装不下按比例压缩。自然宽要量全表（每格一次后端度量），所以量出来的结果缓存在状态里、**只在数据变了之后重量**（`set_rows` / `set_cell` 置脏），每帧只做"按可用宽压缩"这道纯算术。
   **横向滚动与列命中**（`T102` 第四刀）：固定宽模式下总列宽可以超过控件宽，`set_h_offset` 横着滚（越界自动夹到"最后一列贴右"），滚出视野的列**整列不发命令**——与纵向的窗口化同一条。`column_at(x)` 把控件局部 x 换算成列号（滚过去之后换算跟着走），`scroll_to_column(col)` 把某列滚进视野。这两个是留给应用层的把手："点表头按那一列排序"要用的就是 `column_at`。自适应模式下横向偏移恒为 0——列被压进可用宽，本来就没有可滚的余量。
   **排序**（`T102` 第五刀）：`sort_by_column(col)` 按列排，同一列再点一次翻方向（升 ↔ 降），`clear_sort()` 回到原序；表头画出方向箭头（▲ 升 / ▼ 降）。三条关键决定：①**排序不改动数据**——`rows` 里的数据行号在排序前后都稳定，另存一份显示顺序（`sort_order`）做映射，`set_cell(row, col)` 写的仍然是同一条数据的那一格；②**排序必须稳定**——`Array::sort_by` 本身不稳定，比较函数在键相等时按原行号兜底，同价的两行换位置是用户看得见的抖动；降序也不是"排完再反转"（反转会把同键行的次序也反过来，稳定性就没了），而是比较时把方向算进去；③**文本列按字典序、不是短 lex**——MoonBit 给 `String` 的 `Compare` 实现是**长度优先**（`"9" < "10"` 成立），短 lex 下 9 → 10 → 100 恰好与数值序一致，两个口径混在一起看不出差别，所以这里显式用 `String::lexical_compare`（逐码元比，"10" < "100" < "9"）。数字列要显式声明 `numeric~`：自动探测不可靠（"1e5" 算不算数？"" 算不算？" 3 " 带空格算不算？），与 `right~` 同一条理由；数值列里有一格解析不出来，那一格**退回字典序**（不是"当 0"——那会把 "--" 和真正的 0 混成一堆）。
   **行号一律指数据行号**（`T102` 第六刀，排序之后才显形的一条不变量）：排序把"第几行"劈成了两个意思——**显示位置**（屏幕上第几行）与**数据行号**（`rows` 里的第几条）。公开 API 一律用**数据行号**：`cell` / `set_cell` / `select_row` / `selected` / `row_at` / `scroll_to_row` 全是这一个口径，显示位置只在包内活着（包内有两个互逆的映射：`grid_data_row_at` 与 `grid_view_pos_of`）。为什么必须统一：调用方拿到 `row_at(y)` 之后多半是去 `select_row` 或 `cell` 的——给显示位置的话，选中的是另一条数据；而排序之前两者恒等（没有排序），这个洞要等第五刀才打开。`scroll_to_row(row)` 因此滚到的是那条数据**当前所在的位置**（排序后不在第 row 个显示位上了），不是"滚到第 row 个显示位置"。高亮同理：选中存的是数据行号，绘制时比的是该显示行对应的**数据行号**——比显示位置就高亮到别处去了。
5. **树多一层"扁平化"**：`TreeView` 内部缓存当前可见行的数组（`depth` / `expanded` / `leaf` 都在扁平化那一刻算好），只在换数据或展开/收起时重算（`set_root` / `expand` / `collapse` / `toggle` / `expand_all` / `collapse_all` / `set_expanded`），绘制只走窗口内那几行——一万个节点的树滚到底，与二十个节点发的命令数一样多。缩进参考线按**窗口内**最大深度铺：按全表最大深度铺的话，滚到只有浅层节点那一段会看到几条空荡荡的竖线穿到底。参考线的层次是"底色之后、文字之前"——画在底色之前会被选中行盖掉，画在文字之后会割穿字。命中框只有箭头那一格（`toggle_at` 只认那一格），点整行留给选中：两件事分开，"想选中却折了"就不会成为最常见的手误。选中按 **id** 记而不是行号——行号会随父节点折叠变化，按 id 记才不会高亮错行。

---

## 7. 组合组件（components）

下列组件是纯 MoonBit 用基础控件拼装的**高阶控件**，统一通过 `.view()` 取根 `Widget[B]`：

```moonbit
// 卡片：标题 + 子项列表
pub fn[B : Backend] Card::new(B, String, Array[Widget[B]]) -> Self[B] raise UiError
pub fn[B : Backend] Card::set_title(Self[B], String) -> Unit raise UiError
pub fn[B] Card::view(Self[B]) -> Widget[B]

// 选项卡
pub fn[B] Tabs::current(Self[B]) -> Int
pub fn[B] Tabs::new(B, Array[String], Array[() -> Widget[B] raise UiError]) -> Self[B] raise UiError
pub fn[B] Tabs::on_change(Self[B], (Int) -> Unit raise UiError) -> Unit
pub fn[B] Tabs::select(Self[B], Int) -> Unit
pub fn[B : Backend] Tabs::view(Self[B]) -> Widget[B] raise UiError

// 步骤条
pub fn[B] Steps::current(Self[B]) -> Int
pub fn[B : Backend] Steps::new(B, Array[String], Int) -> Self[B] raise UiError
pub fn[B : Backend] Steps::set_current(Self[B], Int) -> Unit raise UiError
pub fn[B] Steps::view(Self[B]) -> Widget[B]

// 提示条
pub fn[B] Alert::view(Self[B]) -> Widget[B]
pub fn[B : Backend] Alert::new(B, AlertType, String, String) -> Self[B] raise UiError
pub fn[B : Backend] Alert::set_type(Self[B], AlertType) -> Unit raise UiError
pub fn[B : Backend] Alert::set_title(Self[B], String) -> Unit raise UiError
pub fn[B : Backend] Alert::set_description(Self[B], String) -> Unit raise UiError

// 面包屑
pub fn[B] Breadcrumb::view(Self[B]) -> Widget[B]
pub fn[B : Backend] Breadcrumb::new(B, Array[String]) -> Self[B] raise UiError
pub fn[B] Breadcrumb::on_navigate(Self[B], (Int) -> Unit raise UiError) -> Unit

// 分页器
pub fn[B] Pagination::page(Self[B]) -> Int
pub fn[B] Pagination::pages(Self[B]) -> Int
pub fn[B] Pagination::view(Self[B]) -> Widget[B]
pub fn[B : Backend] Pagination::new(B, Int, Int) -> Self[B] raise UiError   // (总数, 每页)
pub fn[B] Pagination::on_change(Self[B], (Int) -> Unit raise UiError) -> Unit
pub fn[B : Backend] Pagination::set_page(Self[B], Int) -> Unit raise UiError

// 单选组
pub fn[B] RadioGroup::selected(Self[B]) -> Int
pub fn[B] RadioGroup::selected_text(Self[B]) -> String
pub fn[B : Backend] RadioGroup::new(B, Array[String], Int) -> Self[B] raise UiError  // (选项, 初选)
pub fn[B] RadioGroup::on_change(Self[B], (Int) -> Unit raise UiError) -> Unit
pub fn[B : Backend] RadioGroup::set_selected(Self[B], Int) -> Unit raise UiError
pub fn[B] RadioGroup::view(Self[B]) -> Widget[B]

// 评分
pub fn[B] Rate::value(Self[B]) -> Int
pub fn[B : Backend] Rate::new(B, Int, Int) -> Self[B] raise UiError   // (max, 初值)
pub fn[B] Rate::on_change(Self[B], (Int) -> Unit raise UiError) -> Unit
pub fn[B : Backend] Rate::set_value(Self[B], Int) -> Unit raise UiError
pub fn[B] Rate::view(Self[B]) -> Widget[B]

// 虚拟列表（只实例化可视区行，适合长列表）
pub fn[B] VirtualList::materialized_count(Self[B]) -> Int
pub fn[B] VirtualList::materialized_first(Self[B]) -> Int
pub fn[B : Backend] VirtualList::new(
  B, Int, Double, (Int) -> Widget[B] raise UiError
) -> Self[B] raise UiError                                             // (总数, 行高, 行构造器)
pub fn[B : Backend] VirtualList::sync(Self[B], Double, Double) -> Unit raise UiError  // (视口高, 滚动偏移)
pub fn[B] VirtualList::view(Self[B]) -> Widget[B]
```

示例：

```moonbit
let tabs = @moonui.Tabs::new(b, ["概览", "设置"], [
  fn() raise @moonui.UiError { @moonui.Widget::label(b, "概览页") },
  fn() raise @moonui.UiError { @moonui.Widget::label(b, "设置页") },
])
window.set_content(tabs.view())
```

---

## 8. 布局 `LayoutSpec`

`LayoutSpec` 是布局的不可变描述（也可由 `Widget::to_layout_spec` 得到）。顶层可用 `measure` / `layout` 直接计算：

```moonbit
pub fn measure(LayoutSpec, BoxConstraints) -> LogicalSize
pub fn layout(LayoutSpec, LogicalRect, Array[Placed]) -> Unit

pub(all) enum LayoutSpec {
  Leaf(LeafSpec)
  Row(LineSpec)
  Column(LineSpec)
  Padding(PaddingSpec)
  Spacer
  Center(CenterSpec)
  Stack(StackSpec)
  Grid(GridSpec)
  Scroll(ScrollSpec)
  Panel(PanelSpec)
  Sized(SizedSpec)
  Unbounded(LayoutSpec)
  Expand(LayoutSpec)
}

pub(all) struct LeafSpec   { id : Int, intrinsic : LogicalSize, expand : Bool, fill_cross : Bool }
pub(all) struct LineSpec   { axis : Axis, spacing : Double, children : Array[LayoutSpec] }
pub(all) struct PaddingSpec{ insets : EdgeInsets, child : LayoutSpec }
pub(all) struct CenterSpec { child : LayoutSpec }
pub(all) struct StackSpec  { children : Array[LayoutSpec] }
pub(all) struct GridSpec   { columns : Int, spacing : Double, children : Array[LayoutSpec] }
pub(all) struct ScrollSpec { id : Int, axis : Axis, child : LayoutSpec }
pub(all) struct PanelSpec  { id : Int, insets : EdgeInsets, child : LayoutSpec }
pub(all) struct SizedSpec  { width : Double?, height : Double?, child : LayoutSpec }
pub(all) struct Placed     { id : Int, frame : LogicalRect }
```

绝大多数业务代码**不需要手写 `LayoutSpec`**——用 `Widget::row` / `column` / `panel` / `scroll` 等构造器即可，框架会自动推导。该类型主要在自定义控件或布局测试时直接消费。

---

## 9. 菜单

```moonbit
pub(all) enum MenuNode {
  Item(MenuItem)
  Separator
  Submenu(String, Array[MenuNode])
}

pub struct MenuItem {
  mut id : Int
  label : String
  role : MenuRole
  mut checked : Bool
  mut enabled : Bool
  mut shortcut : Shortcut?
  mut radio_group : Int
  // ……（handlers 内部状态）
}
pub(all) enum MenuRole { Normal, Check, Radio }

pub fn MenuItem::new(String) -> Self
pub fn MenuItem::checkbox(String) -> Self        // 勾选项
pub fn MenuItem::radio(String) -> Self           // 单选项
pub fn MenuItem::on(Self, (Self) -> Unit raise UiError) -> Int
pub fn MenuItem::off(Self, Int) -> Bool
pub fn MenuItem::fire(Self) -> Int raise UiError          // 手动触发
pub fn MenuItem::set_enabled(Self, Bool) -> Unit
pub fn MenuItem::set_shortcut(Self, Shortcut) -> Unit
pub fn MenuItem::set_checked(Self, Bool) -> Unit
pub fn MenuItem::is_enabled(Self) -> Bool
pub fn MenuItem::is_checked(Self) -> Bool
pub fn MenuItem::shortcut_of(Self) -> Shortcut?
pub fn MenuItem::target(Self) -> EventTarget
pub fn MenuItem::handler_count(Self) -> Int
pub fn MenuItem::describe(Self) -> String
```

`Menu` / `MenuBar`：

```moonbit
pub struct Menu { label : String, nodes : Array[MenuNode] }
pub fn Menu::new(String, Array[MenuNode]) -> Self
pub fn Menu::title(Self) -> String
pub fn Menu::nodes(Self) -> Array[MenuNode]
pub fn Menu::find(Self, Int) -> MenuItem?
pub fn Menu::flatten(Self) -> Array[MenuItem]
pub fn Menu::item_count(Self) -> Int

pub struct MenuBar { menus : Array[Menu] }
pub fn MenuBar::new(Array[Menu]) -> Self
pub fn MenuBar::menus(Self) -> Array[Menu]
pub fn MenuBar::top_labels(Self) -> Array[String]
pub fn MenuBar::all_items(Self) -> Array[MenuItem]
pub fn MenuBar::find(Self, Int) -> MenuItem?
pub fn MenuBar::click(Self, Int) -> MenuItem? raise UiError
pub fn MenuBar::toggle(Self, Int) -> Bool
pub fn MenuBar::set_checked(Self, Int, Bool) -> Bool
pub fn MenuBar::shortcut_items(Self) -> Array[MenuItem]
pub fn MenuBar::menu_count(Self) -> Int
```

`MenuAccel`：`{ shortcut : Shortcut, item : MenuItem }`（菜单项快捷键的派生记录）。

用法：

```moonbit
let file = @moonui.Menu::new("文件", [
  Item(
    @moonui.MenuItem::new("打开").set_shortcut(@moonui.Shortcut::ctrl("o"))
  ),
  Separator,
  Item(@moonui.MenuItem::new("退出")),
])
let menubar = @moonui.MenuBar::new([file])
app.set_menubar(menubar)?
```

---

## 10. 快捷键 `Shortcut`

```moonbit
pub(all) struct Shortcut {
  key : String, ctrl : Bool, alt : Bool, shift : Bool, meta : Bool
}
pub fn Shortcut::new(String) -> Self
pub fn Shortcut::ctrl(String) -> Self
pub fn Shortcut::alt(String) -> Self
pub fn Shortcut::meta(String) -> Self
pub fn Shortcut::with_ctrl(Self, Bool) -> Self
pub fn Shortcut::with_alt(Self, Bool) -> Self
pub fn Shortcut::with_shift(Self, Bool) -> Self
pub fn Shortcut::with_meta(Self, Bool) -> Self
pub fn Shortcut::from_key_press(KeyPress) -> Self
pub fn Shortcut::key_press(Self) -> KeyPress
pub fn Shortcut::matches(Self, KeyPress) -> Bool
pub fn Shortcut::matches_shortcut(Self, Self) -> Bool
pub fn Shortcut::label(Self) -> String          // 人类可读，如 "⌘C"
```

快捷键通过 `App::register_shortcut` 注册（见 [§4](#4-应用-app)）：

```moonbit
app.register_shortcut(@moonui.Shortcut::ctrl("s"), fn(_s) raise @moonui.UiError {
  save()
})?
```

---

## 11. 动画 `AnimationCurve`

```moonbit
pub(all) enum AnimationCurve { Linear, EaseIn, EaseOut, EaseInOut }
pub fn AnimationCurve::progress(Self, Double) -> Double   // 归一化进度 → 缓动后进度
```

窗口尺寸补间、进度插值、均衡器动画等依赖 `App` 的动画时钟（[§4](#4-应用-app) 的 `set_anim_clock` / `set_anim_wake`）。控件可声明自身动画曲线：

```moonbit
pub fn[B] Widget::animation(Self[B], AnimationCurve) -> Self[B] raise UiError
```

> 注意：canvas 后端（自绘）自己不持事件循环，必须把 `anim_wake` 通过 `CanvasBackend::set_frame_budget` 转发到内嵌的原生后端，否则动画不推进。原生后端（`new_app()`）已自带该接线。

---

## 12. 可访问性 `Accessibility`

```moonbit
pub(all) enum AccessAction { Press, Toggle, SetValue }
pub(all) enum AccessRole {
  Text, Button, CheckBox, TextBox, Group, List, ListItem,
  Window, SliderRole, ProgressRole
}
pub(all) struct AccessState { visible : Bool, enabled : Bool, checked : Bool? }
pub(all) struct Accessibility {
  id : Int?, role : AccessRole, label : String,
  description : String, state : AccessState, actions : Array[AccessAction]
}

pub fn accessibility_actions(Array[(Event) -> Bool], Int) -> Array[AccessAction]
```

可访问性视图是**推导**出来的：Role 来自显式声明（`Widget::set_access_role`），State 来自原生层，Actions 来自事件订阅。纯布局节点只有显式声明 Role 才进视图。读取用 `Widget::accessibility_tree`（见 [§6.6](#66-可访问性声明)）。

---

## 13. 国际化 `L10n`

```moonbit
pub struct L10n {
  archives : Map[String, Map[String, String]]   // locale → (key → 文案)
  mut locale : String
}
pub fn L10n::new() -> Self
pub fn L10n::add_archive(Self, String, Map[String, String]) -> Unit
pub fn L10n::set_locale(Self, String) -> Unit raise UiError
pub fn L10n::locale(Self) -> String
pub fn L10n::text(Self, String) -> String raise UiError       // 取当前 locale 下的文案
pub fn L10n::text_or(Self, String) -> String?                 // 取不到返回 None
pub fn[B : Backend] L10n::label(Self, B, String) -> Widget[B] raise UiError
pub fn[B : Backend] L10n::button(Self, B, String) -> Widget[B] raise UiError
```

---

## 14. 剪贴板 / 对话框 / 文件面板

均在 `App` 上（[§4](#4-应用-app)），后端差异对业务透明：

```moonbit
app.set_clipboard_text("复制这段文本")?
match app.clipboard_text()? {
  Some(s) => println(s)
  None => println("(空)")
}

app.show_message("标题", "这是一条提示")?
let ok = app.confirm("确认", "确定要删除吗？")?

match app.open_file("选择文件")? {
  Some(path) => println("打开：\{path}")
  None => println("已取消")
}
match app.save_file("保存为", "report.txt")? {
  Some(path) => println("保存至：\{path}")
  None => ()
}
match app.select_folder("选择目录")? {
  Some(dir) => println("目录：\{dir}")
  None => ()
}
```

---

## 15. 窗口存档 `WindowFrame` / `WindowState`

```moonbit
pub(all) struct WindowFrame {
  width : Double, height : Double, x : Double, y : Double, maximized : Bool
}
pub(all) struct WindowState { minimized : Bool, maximized : Bool }
```

应用级存档（按 key 持久化窗口几何，重启可还原）：

```moonbit
app.save_window_state("main")?            // 写入当前几何 + 最大化状态
match app.load_window_state("main")? {
  Some(frame) => {
    let w = app.create_window_restored("主窗口", size, frame)?
    // …
  }
  None => { /* 首次启动，用默认几何 */ }
}
```

`WindowState` 用于运行时读取最小/最大化状态（`Window::window_state`）。`Window::apply_frame` 可把一份 `WindowFrame` 应用到已有窗口。

---

## 16. 示例 Demo 辅助（库内复用）

`packages/moonui` 把若干完整示例实现为 `pub` 辅助类型，便于直接复用或作为参考。它们都住在主包里（不是 `examples/`），统一通过 `::demo(app)` 构造：

| 类型 | 构造 | 用途 |
| --- | --- | --- |
| `Demo` | `Demo::hello(app)` / `Demo::counter(app)` | Hello / 计数器 |
| `LoginForm` | `LoginForm::demo(app)` | 登录表单 |
| `TodoList` | `TodoList::demo(app)` | 待办列表 |
| `FileManager` | `FileManager::demo(app)` | 文件管理器 |
| `Gallery` | `Gallery::demo(app)` | 组件画册 |
| `SettingsDemo` | `SettingsDemo::demo(app, size)` / `restored(app, key, size)` | 设置中心 |
| `MarkdownDemo` | `MarkdownDemo::demo(app, text)` | Markdown 编辑器 |
| `DataAdminDemo` | `DataAdminDemo::demo(app)` | 数据管理后台 |

每个类型均有 `.window()` 取窗口、若干 `*_text()` 取状态、`press_*` / `set_*` 模拟交互（测试用）。例如：

```moonbit
let todo = @moonui.TodoList::demo(app)?
todo.add("买牛奶")?
todo.toggle(0)?
println(todo.status_text()?)
```

这些是库内示例载体，业务项目一般直接写自己的窗口/控件，不依赖它们。

---

## 17. 调试与测试

无头测试用 `MockBackend` 跑完整事件循环与布局数值，**不需要任何 GUI 库**：

```moonbit
pub struct MockBackend { /* 内部状态：窗口/控件表、事件队列、外观等 */ }
pub fn MockBackend::new() -> Self
pub impl Backend for MockBackend          // 实现全部 Backend 方法（内存态）
```

常用测试入口：

```moonbit
pub fn MockBackend::push_event(Self, Event) -> Unit
pub fn MockBackend::poll_event(Self) -> Event?
pub fn MockBackend::widget_text(Self, NativeHandle) -> String raise UiError
pub fn MockBackend::widget_bounds(Self, NativeHandle) -> LogicalRect raise UiError
pub fn MockBackend::window_size(Self, NativeHandle) -> LogicalSize raise UiError
pub fn MockBackend::screen_size(Self) -> LogicalSize raise UiError
pub fn MockBackend::set_host_platform(Self, HostPlatform) -> Unit
pub fn MockBackend::set_prefers_reduced_motion(Self, Bool) -> Unit
pub fn MockBackend::push_confirm_reply(Self, Bool) -> Unit      // 预置 confirm 答案
pub fn MockBackend::push_path_reply(Self, String?) -> Unit       // 预置文件面板结果
pub fn MockBackend::bounds_push_log(Self) -> Array[(Int, LogicalRect)]
pub fn MockBackend::handle_stats(Self) -> HandleStats
// ……（其余为按控件种类读写文本/勾选/可见/值等断言入口）
```

`App` 的事件追踪：

```moonbit
pub(all) struct DispatchTrace {
  event : Event
  mut route : TraceRoute
  capture : Array[TraceStop]
  direct : Array[TraceStop]
  bubble : Array[TraceStop]
  mut intercepted : Bool
  subscribed : Array[TraceStop]
}
pub(all) enum TraceRoute { MenuHit(Bool), ThemeRefreshed(Int), WindowArm, TreeArm, Missed }
pub(all) struct TraceStop { owner : Int, accepted : Bool }

app.set_event_trace(fn(t : @moonui.DispatchTrace) {
  // 检查 t.capture / t.bubble 各阶段的 accept 情况
})
```

原生后端调试：设置环境变量 `MOONUI_NATIVE_TRACE=1` 可打开 adapter 的 `TRACE`（见 README「死在哪一次 FFI 调用」），无需改代码。

---

## 18. 后端

`Backend` 是框架与平台之间的 trait。业务代码通常**不直接实现它**——用现成后端即可。

```moonbit
pub(open) trait Backend {
  fn init(Self) -> Unit raise UiError
  fn terminate(Self) -> Unit
  fn poll_event(Self) -> Event?
  fn request_redraw(Self, NativeHandle) -> Unit raise UiError
  fn create_window(Self, String, LogicalSize) -> NativeHandle raise UiError
  fn destroy_window(Self, NativeHandle) -> Unit raise UiError
  // ……（完整签名见 packages/moonui/pkg.generated.mbti 的 Backend trait 段，
  //      涵盖窗口几何/可见性、控件增删改、剪贴板、对话框、文件面板、
  //      菜单栏、托盘、主题、HiDPI、无障碍等全部方法）
}
```

可用的现成后端：

- **`NativeBackend`**（包 `backends/native-common`）：平台原生后端，macOS 直写 AppKit、Windows 直写 Win32。提供 `native_time_ms()` 供动画时钟使用。
- **`CanvasBackend`**（包 `backends/canvas-macos`）：自绘后端，内嵌一个 `NativeBackend` 处理事件与系统交互。`CanvasBackend::set_frame_budget(active)` 把动画唤醒转发到内嵌原生后端（[§11](#11-动画-animationcurve)）。

门面包 `moonui-app`（推荐入口）：

```moonbit
pub fn new_app() -> @moonui.App[@native-common.NativeBackend] raise @moonui.UiError
pub fn worker_run(
  @moonui.App[@native-common.NativeBackend],
  () -> Unit,
  () -> Unit raise @moonui.UiError
) -> Unit raise @moonui.UiError
```

`new_app()` 内部完成「构造 `NativeBackend` → `Backend::init` → `App::new` → 接好动画时钟/唤醒」四步，返回已就绪的 `App[NativeBackend]`，业务代码从此不必 import 后端包。`worker_run` 用于在独立工作线程里跑后台任务（接收 `on_progress` / `on_done` 两个回调）。

```moonbit
fn main raise {
  let app = @moonui-app.new_app()
  // ……搭建窗口与控件……
  app.run()?
}
```

---

## 附：常量与杂项

```moonbit
pub const DATA_ADMIN_PAGE_SIZE : Int = 20
pub const DATA_ADMIN_ROW_HEIGHT : Double = 32.0
pub const LONG_PRESS_DURATION_MS : Int = 400
pub const LONG_PRESS_MOVE_THRESHOLD : Double = 8.0

pub fn format_size(Int) -> String
pub fn path_text(Array[String]) -> String
pub fn style(width?, height?, …) -> Style          // 见 §3.3
pub fn measure(LayoutSpec, BoxConstraints) -> LogicalSize
pub fn layout(LayoutSpec, LogicalRect, Array[Placed]) -> Unit
pub fn check_nonnull[T?](T?, String) -> T raise UiError
pub fn accessibility_actions(Array[(Event) -> Bool], Int) -> Array[AccessAction]
```

---

> 本文件所列签名均来自 `moon info` 生成的 `.mbti` 接口文件。改动 API 后请重新生成并一并提交：`moon info && moon fmt`。与各小节对应的设计依据见 [DESIGN.md](DESIGN.md)（按 `§nn` 小节号引用）。
