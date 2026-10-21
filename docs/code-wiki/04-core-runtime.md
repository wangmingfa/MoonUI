# 04 运行时核心

本篇覆盖 `App`、`Window`、`Backend`、`MockBackend` 与句柄生命周期。相关源码：

- [app.mbt](../../packages/moonui/app.mbt)
- [window.mbt](../../packages/moonui/window.mbt)
- [backend.mbt](../../packages/moonui/backend.mbt)
- [handle.mbt](../../packages/moonui/handle.mbt)
- [error.mbt](../../packages/moonui/error.mbt)

## 4.1 错误模型：`UiError`

```moonbit
pub(all) suberror UiError {
  ...
}
```

`UiError` 是框架唯一公开的失败类型，几乎所有跨平台调用都写成 `... raise UiError`。约定：

- 可恢复的用户输入错误（无效句柄、重复销毁、后端不支持某能力）必须抛这个类型，而不是让程序崩溃。
- 构造函数/方法把 `UiError` 原样向上传，不吞。
- `App::run` 捕获第一个错误，先 `backend.terminate()` 再抛出。

常用变体（见 [error.mbt](../../packages/moonui/error.mbt)）：`InitializationFailed(String)`、`BackendUnavailable(String)`、`InvalidHandle`、`OperationFailed(String)`、`Unsupported(String)`、`Destroyed`、`AlreadyOwned`；`WindowState` 在 wasm 上读档会显式抛 `Unsupported`。

## 4.2 句柄：`NativeHandle` + `HandleTable`

Core 与公共 API 永远看不到 `HWND` / `NSView*`。所有原生对象用：

```moonbit
pub(all) struct NativeHandle {
  id : Int32
  generation : Int32
}
```

`HandleTable`（[handle.mbt#L34](../../packages/moonui/handle.mbt#L34)）负责 `id → NativePtr`：

- `register(ptr)`：优先复用 `free_ids` 里的 id，并把该槽的 `generation + 1`，返回新句柄。
- `resolve(h)`：代际或存活标志不符 → `InvalidHandle`，绝不把野指针交给 C。
- `unregister(h)`：已死再注销 → `Destroyed`，把 double free 变成可测错误。
- `live()` / `stats()`：存活数与历史峰值（`T88①`），供泄漏断言。
- `alive_handles()`：退出时统一回收还没显式销毁的对象。

因为 id 会复用，`EventTarget` 也必须带 `generation`（见 [event.mbt#L15](../../packages/moonui/event.mbt#L15)）。订阅、菜单项编号与控件句柄是两个独立空间，菜单靠 `Event::MenuSelect` 变体隔离。

## 4.3 `Backend` trait

定义在 [backend.mbt#L29](../../packages/moonui/backend.mbt#L29)，`pub(open) trait Backend`。它是 Core 与平台之间的**唯一边界**。方法可按职责分组：

| 组 | 方法（节选） | 说明 |
| --- | --- | --- |
| 生命周期 | `init`、`terminate`、`poll_event`、`request_redraw` | `poll_event` 非阻塞，队空返回 `None`；坐标必须已是逻辑像素 |
| 窗口 | `create_window`、`destroy_window`、`show_window`、`hide_window`、`set_window_title/size/position`、`window_size/position/scale`、`set_window_min/max_size`、`set_window_resizable/fullscreen/minimized/maximized`、`window_state`、`window_work_area`、`screen_size`、`set_window_titlebar_style`、`set_window_traffic_light_position`、`set_window_live_redraw` | 逻辑像素输入；`window_work_area` 驱动居中与吸附 |
| 窗口控件 | `create_widget`、`create_ranged_widget`、`destroy_widget`、`attach_widget`、`attach_widget_to`、`detach_widget`、`raise_widget`、`set_widget_bounds`、`widget_bounds`、`widget_intrinsic_size` | 树形挂接 + 绝对矩形摆放 |
| 控件属性 | `set_widget_text`、`widget_text`、`set_widget_checked/checked`、`set_widget_value/value`、`set_widget_range`、`append_widget_option`、`set_widget_selected/selected`、`set_widget_datetime/datetime`、`set_widget_visible/visible`、`set_widget_enabled/enabled`、`set_widget_opacity`、`set_widget_insets`、`set_widget_icon`、`set_widget_image_path`、`set_widget_image_bytes` | 属性往返；不支持的能力抛 `Unsupported` |
| 样式主题 | `set_widget_style`、`set_theme_base`、`system_theme`、`host_platform`、`get_prefers_reduced_motion`、`get_prefers_high_contrast` | `set_theme_base` 是样式层叠起点；`host_platform` 决定是否要自绘窗口按钮 |
| 绘制 | `draw_custom`、`measure_text` | `DrawList` 重放与文本度量 |
| 层级/焦点 | `set_paint_order`、`set_focus_chain` | 由 Core 算好整份推下来；`MockBackend` 分开记录 |
| 滚动/容器 | `set_scroll_content`、`attach_widget_to` | `Scroll` / `Panel` 内容视图 |
| 菜单/托盘 | `set_menu_bar`、`set_menu_item_checked`、`show_context_menu`、`set_tray_icon`、`set_tray_menu` | 菜单项编号是独立空间 |
| 系统能力 | `clipboard_text`、`set_clipboard_text`、`show_message`、`confirm`、`open_file`、`save_file`、`select_folder`、`notify`、`set_app_icon` | 对话框是可注入/可脚本化的 |
| 实时通道 | `set_live_dispatch` | 原生回调线程/栈内直接派发（live resize 等） |

实现者需要遵守的契约：

1. **逻辑像素**：所有坐标、尺寸、滚动增量都是逻辑像素；物理换算在实现内部（`Scale`）。
2. **事件入队前换算**：C 侧拿到的是物理坐标，`poll_event` 前必须除以该窗口 Scale；不要在 Core 再除一次。
3. **`request_redraw` 后下一轮至少一条 `Frame`**：原生控件后端可空操作；自绘后端必须兑现。
4. **句柄校验**：所有接收 `NativeHandle` 的方法先 `resolve`，失败抛 `InvalidHandle`。
5. **不支持就报错**：不能用静默 no-op 假装成功（测试会断言"调用真的到了后端"）。

## 4.4 `MockBackend`

位于 [backend.mbt#L376](../../packages/moonui/backend.mbt#L376)，是无头测试的核心设施：

- 用 `HandleTable` 模拟句柄，维护 `MockWindow` / `MockWidget` 状态（标题、尺寸、位置、可见、最小尺寸、缩放、工作区、`z_order`、`focus_chain`、min/max 状态等）。
- `push_event(Event)` 注入事件，`poll_event` 排空；`set_screen_size` 驱动居中测试。
- 记录 API 调用账：对话框日志、确认/路径应答队列、菜单安装次数与勾选流水、图标/托盘/通知日志、主题底样式、bounds/opacity 推送流水。
- 默认 `appearance = Light`、`host = Unknown`、偏好开关为 false，保证测试基线稳定。
- 可注入 live dispatch、屏幕尺寸、宿主平台、减少动态/高对比偏好，用来测试分支。

`MockBackend` 同时是"新 Backend 方法的行为参考"：在它上面把语义写成可断言的状态，再接真后端。

## 4.5 `App`

### 4.5.1 结构

`App[B]` 大约持有（见 [pkg.generated.mbti#L113](../../packages/moonui/pkg.generated.mbti#L113)）：

- `backend : B`
- `windows : Array[Window[B]]`
- `subs : Array[Subscription]`
- `posted : Array[PostedTask]`、`next_sub_id`
- `theme : Theme`、`anim_clock`、`anim_wake`
- 快捷键表、菜单栏、事件追踪 sink、Docking 开关、任务表等（私有字段）

### 4.5.2 生命周期

| 方法 | 作用 |
| --- | --- |
| `App::new(backend)` | 创建空应用；安装 live dispatch；设置默认主题与时钟 |
| `App::run()` | `backend.init()` → 循环 `step` → 空闲等待 → `terminate`；异常先清理再抛 |
| `App::step()` | 单步推进，返回"是否还有活干"；测试与嵌入式驱动用 |
| `App::quit()` | 请求退出；`run` 在下一轮结束 |
| `is_running` / `is_finished` | 状态查询 |

`run` 的实际循环在 `drive`（[app.mbt#L947](../../packages/moonui/app.mbt#L947)）：没有窗口、`quit_requested`、或 `step` 返回 false 且无消息时退出。退出时把所有存活窗口 `close_tree`，再 `backend.terminate`。

### 4.5.3 窗口管理

| 方法 | 说明 |
| --- | --- |
| `create_window(title, size)` | 新建并登记窗口 |
| `create_window_restored(title, size, frame?)` | 带存档恢复位置/尺寸 |
| `window_count` / `live_window_count` | 计数（后者排除已关闭） |
| `window_frame()` | 当前焦点窗口的 `WindowFrame`（用于存档） |
| `save_window_state(key)` / `load_window_state(key)` | JSON 存档，native 落盘、wasm 报 `Unsupported` |
| `follow_move(target, p)` | 吸附：把同一组窗口按位移一起移动 |

### 4.5.4 事件与订阅

| 方法 | 说明 |
| --- | --- |
| `dispatch(event) -> Int32` | 返回命中的处理器数；见 [06](06-events.md) |
| `on(target, accept, handler) -> Int32` | 订阅，"谁 + 接受条件 + 回调" |
| `on_event(target, handler) -> Int32` | 只按目标订阅，接受所有事件 |
| `unsubscribe(id)` / `subscription_count` | 取消/计数 |
| `fire_shortcut(key : KeyPress) -> Int32` | 手动触发快捷键（测试/脚本） |
| `set_event_trace(sink)` / `clear_event_trace` | 打开派发追踪 |

订阅命中条件是 **完整 `EventTarget` 相等**（id + generation），并且在派发时先快照订阅列表、执行前再检查 id 是否仍存在，避免处理器中途退订造成悬空。

### 4.5.5 任务与定时

| 方法 | 说明 |
| --- | --- |
| `post(fn)` | 下一轮主循环执行，不返回值 |
| `post_task(fn) -> TaskId` | 可取消任务 |
| `cancel_task(id) -> Bool` | 取消；已执行返回 false |
| `set_anim_clock(fn) -> Int32` | 注入动画时钟（毫秒） |
| `set_anim_wake(fn)` | 动画需要下一帧时的唤醒回调（自绘后端用） |

### 4.5.6 主题、菜单、系统能力

| 方法 | 说明 |
| --- | --- |
| `set_theme(Theme)` | Light/Dark/System；立即重算所有窗口 `style_base` 并重排 |
| `theme()` / `appearance()` / `palette()` / `style_base()` | 读取生效主题与配色 |
| `set_menubar(MenuBar)` / `menubar()` / `click_menu_item(id)` | 菜单栏与脚本触发 |
| `register_shortcut(Shortcut, handler)` / `unregister_shortcut` | 快捷键；`KeyDown` 时先于控件处理 |
| `show_message` / `confirm` / `open_file` / `save_file` / `select_folder` | 系统对话框 |
| `clipboard_text` / `set_clipboard_text` | 剪贴板 |
| `set_icon` / `set_tray_icon` / `set_tray_menu` / `notify` | 应用图标、托盘、通知 |
| `set_live_redraw(enabled)` / `dock_enabled` | 实时重绘与吸附开关 |

## 4.6 `Window`

### 4.6.1 结构

`Window[B]`（[pkg.generated.mbti#L1474](../../packages/moonui/pkg.generated.mbti#L1474)）持有：

- `backend : B`、`handle : NativeHandle`
- `content : Widget[B]?`、`closed`
- `min_size` / `max_size`、`visible`、`last_origin`
- `style_base : Style`（该窗口样式层叠起点）
- `live_redraw` / `live_default`、`move_anim`

### 4.6.2 主要方法

| 分类 | 方法 |
| --- | --- |
| 创建/内容 | `Window::new(backend, title, size)`、`set_content(root)`、`content()`、`widget_at(point)`、`target()`、`handle()` |
| 显示 | `show`、`hide`、`close`、`is_closed`、`center` |
| 几何 | `size`、`physical_size`、`position`、`scale`、`set_size`、`set_position`、`set_position_animated`、`set_min_size`、`set_max_size`、`sync_size`、`apply_frame` |
| 窗口态 | `set_resizable`、`set_fullscreen`、`set_minimized`、`set_maximized`、`window_state` |
| 外观 | `set_title`、`set_titlebar_style`、`set_traffic_light_position`、`set_live_redraw` |
| 布局/调试 | `relayout`、`dump_layout` |

### 4.6.3 `set_content` 与重排

`set_content`（[window.mbt#L687](../../packages/moonui/window.mbt#L687)）：

1. 若已有内容，递归 `close_tree()` 销毁旧控件（原生对象 + 句柄）。
2. 新根 `attach_widget(window, root)`。
3. 为每个 native-backed 控件创建原生对象；布局节点跳过。
4. 建立父子关系、处理器表、可达性信息。
5. `relayout()`。

`relayout`（[window.mbt#L779](../../packages/moonui/window.mbt#L779)）顺序：

1. `refresh_style_base(theme)` — 主题变化时换底样式。
2. `apply_styles(base)` — 递归解析每个控件的最终 `Style`（层叠）。
3. `push_order_chains()` — 仅当绘制顺序/焦点链变化时推送。
4. `do_layout(rect)` — `measure` + `layout`，输出 `Placed[]`。
5. `set_bounds` 到后端；`Custom` 控件标记重绘。
6. 清理本轮销毁的子树。

### 4.6.4 事件路由

`Window::handle_event` 处理目标是窗口本身的事件（`Resize`、`Moved`、`Close`、`ScaleChanged`、`ThemeChanged`、`Frame`）。控件目标由 `Window::find_widget(target)` 找到后走 `Widget::route_with_phases`：

```
capture（根→目标，可拦截）
  → direct（目标自身处理器）
    → bubble（目标→根，可停止）
```

`Click` / `Scroll` / `Moved` 等还有 Core 内建行为（合成悬停、滚动容器位移、窗口吸附等）。

## 4.7 生命周期与回收

- **窗口关闭**：`Window::close` → `backend.destroy_window` → `content.close_tree()` → 每个控件 `destroy_widget` + `HandleTable::unregister`。
- **内容替换**：旧树整体销毁，新树重建；不做 diff。
- **App 退出**：关闭所有窗口；真后端测试会断言句柄表 `live == 0`。
- **重复销毁**：抛 `Destroyed`，不是未定义行为。
- **旧句柄**：generation 不匹配 → `InvalidHandle`，即使 id 已被新对象复用。

## 4.8 一个最小可运行应用

```moonbit
fn main raise {
  let app = @moonui-app.new_app()          // App[NativeBackend]
  let win = app.create_window("Hello", @moonui.LogicalSize(480.0, 320.0))
  let label = @moonui.Widget::label(app.backend(), "Hello, MoonUI")
  win.set_content(label)
  win.show()
  app.run()
}
```

`App::backend()` 返回后端实例，只是为了让构造控件时能拿到 `B`；Core 不鼓励绕过 `App` 直接调后端。

无头版本把 `new_app()` 换成 `@moonui.App::new(@moonui.MockBackend::new())`，用 `step()` 驱动。

下一篇：[05 布局与样式](05-layout-and-style.md)。
