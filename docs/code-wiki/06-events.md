# 06 事件、动画与无障碍

相关源码：[event.mbt](../../packages/moonui/event.mbt)、[app.mbt](../../packages/moonui/app.mbt) 的 `dispatch`、[widget.mbt](../../packages/moonui/widget.mbt) 的处理器、[animation.mbt](../../packages/moonui/animation.mbt)、[accessibility.mbt](../../packages/moonui/accessibility.mbt)、[menu.mbt](../../packages/moonui/menu.mbt)、[shortcut.mbt](../../packages/moonui/shortcut.mbt)、[trace.mbt](../../packages/moonui/trace.mbt)。

## 6.1 `Event` 全量（27 个变体）

| 变体 | 载荷 | 语义 |
| --- | --- | --- |
| `Click(t, btn)` | 目标、鼠标键 | 原生点击或脚本注入 |
| `DoubleClick(t)` | 目标 | 双击 |
| `Change(t)` | 目标 | 控件值变化（勾选、下拉、滑块等） |
| `Input(t, text)` | 目标、变化后全文 | 文本内容变化 |
| `Focus(t)` / `Blur(t)` | 目标 | 焦点进入/离开 |
| `Close(t)` | 窗口 | 用户关窗（可在此拦截） |
| `Resize(t, size)` | 窗口、逻辑尺寸 | 用户拖拽改变尺寸 |
| `Moved(t, p)` | 窗口、逻辑原点 | **仅用户拖动**产生；Core 自己的 `set_position` 会被抑制，避免吸附回声 |
| `KeyDown(t, kp)` / `KeyUp(t, kp)` | 目标、`KeyPress` | 键盘 |
| `MouseDown/MouseUp(t, btn, p)` | 目标、键、逻辑坐标 | 鼠标按钮 |
| `MouseMove(t, p)` | 目标、逻辑坐标 | 移动；悬停由 Core 合成 |
| `MouseEnter(t)` / `MouseLeave(t)` | 目标 | Core 从 `MouseMove` 目标变化合成，后端不发 |
| `Scroll(t, delta)` | 目标、逻辑像素增量 | 滚轮/触控板滚动 |
| `MenuSelect(t)` | 菜单项编号 | `t.id` 属于菜单编号空间，与控件/窗口句柄无关 |
| `ScaleChanged(t, scale)` | 窗口、新 Scale | 拖到不同 DPI 屏或系统改缩放 |
| `ThemeChanged(t, theme)` | 窗口、新外观 | 系统深浅色变化；后端给每只存活窗口各发一条 |
| `Frame(t)` | 窗口 | 该画一帧；自绘后端靠它续命 |
| `ImeStart(t)` / `ImeCompose(t, s)` / `ImeEnd(t)` | 文本控件、组合串 | 输入法组合三相位；上屏全文仍走 `Input` |
| `LongPress(t)` | 目标 | Core 计时补发；移动超阈或抬起取消 |
| `FileDrop(t, paths)` | 窗口、路径数组 | 外部文件拖入（第一期） |
| `Gesture(t, g)` | 目标、`Gesture` | 捏合/旋转/滑动 |

辅助：

```moonbit
Event::target(e) -> EventTarget     // 统一取目标
Event::is_mouse_press(e) -> Bool
EventTarget::of(handle) -> EventTarget
EventTarget{ id, generation }       // 必须整体比较
```

`Gesture`：`Magnify(factor, phase)`、`Rotate(radians, phase)`、`Swipe(SwipeDirection)`；`GesturePhase`：`Began/Changed/Ended/Cancelled`。

## 6.2 目标与路由

事件目标是 `EventTarget`（`id + generation`），不是 `NativeHandle` 本身，但由它转换而来。原因：句柄 id 会被回收复用，只比 id 会让旧事件打到新对象上。

`App::dispatch` 的三条路径（[app.mbt#L760](../../packages/moonui/app.mbt#L760)）：

```
dispatch(ev)
 ├─ MenuSelect → 查菜单项回调，命中即调用；结束（不进控件路由）
 ├─ 其余：
 │    ├─ 匹配窗口（win.target() == target）→ win.handle_event(ev)
 │    ├─ 否则在存活窗口里 find_widget(target) → w.route_with_phases(ev)
 │    ├─ 拖动窗口先做吸附（Moved → follow_move），再路由
 │    ├─ 长按/悬停记账（观察者，不改路由）
 │    └─ KeyDown → 先查快捷键，再进控件
 └─ 订阅广播：目标匹配的 Subscription，accept 为真才调用
```

`route_with_phases` 的三段：

```
capture（根 → 目标）   on_capture(accept, call)，call 返回 true 即拦截
  ↓ 未被拦截
direct（目标自身）     on(accept, handler) / on_any(handler)
  ↓
bubble（目标 → 根）    on_bubble(accept, call)，call 返回 true 即停止
```

约定：

- `on_capture` / `on_bubble` 的 `call` 返回 `Bool` 表示"吃掉，停止后续阶段"。
- `Widget::on` 的 `handler` 是 `Unit`；`accept` 决定是否接收这类事件。
- `on_any` 不做裁决，永远接收。
- `Event::is_mouse_press` 区分按下类事件，供拖动/按压逻辑使用。
- 派发过程中订阅先快照，再逐个校验 id 仍存在，处理器里退订不会造成迭代失效。

## 6.3 处理器 API

| 方法 | 语义 |
| --- | --- |
| `on(accept, handler) -> Int32` | 目标自身直派；返回处理器 id |
| `on_any(handler)` | 接收所有事件 |
| `on_capture(accept, call)` | 捕获阶段，可拦截 |
| `on_bubble(accept, call)` | 冒泡阶段，可停止 |
| `on_click(handler)` / `on_double_click` | `Click` / `DoubleClick` 糖 |
| `on_change(handler)` | `Change` 糖 |
| `on_input(handler)` | `Input` 糖，参数是全文 |
| `on_focus` / `on_blur` | 焦点糖 |
| `off(id)` | 移除处理器 |

`on_click` 等糖与 `on` 共用同一张处理器表，没有第二套机制。

## 6.4 订阅

`Subscription{ id, target, accept, handler }`。

| 方法 | 说明 |
| --- | --- |
| `App::on(target, accept, handler)` | 订阅指定目标；返回订阅 id |
| `App::on_event(target, handler)` | 接受该目标的所有事件 |
| `App::unsubscribe(id)` | 取消 |
| `App::subscription_count()` | 计数 |

时序：**先路由、后订阅**。订阅看到的是状态已更新后的事件，适合日志、持久化、跨窗口联动。若订阅里要触发新的派发，用 `App::post` 推到下一轮，避免重入。

## 6.5 快捷键与菜单

`Shortcut` 描述组合键；`App::register_shortcut(sc, handler) -> Int32` 注册，`unregister_shortcut(id)` 移除。

- `KeyDown` 的处理顺序：窗口快捷键表 → 控件处理器。
- 菜单项编号独立于句柄空间，`Event::MenuSelect(id)` 靠变体本身区分。
- `App::click_menu_item(id)` 可脚本触发菜单项（测试/自动化）。
- 菜单栏下发用 `App::set_menubar(MenuBar)`；勾选态通过 `set_menu_item_checked` 推给后端。
- 右键菜单：`Widget::show_context_menu` 或 `App` 侧对应方法（`T86①`）。
- 安装菜单时会检查快捷键冲突（`menu.mbt`）。

## 6.6 动画

动画是**纯 MoonBit**，不读时钟、不碰平台 API：

```moonbit
pub(all) enum AnimationCurve { Linear, EaseIn, EaseOut, EaseInOut }
AnimationCurve::progress(curve, t) -> Double   // 纯函数，端点精确 0/1
```

- 时长固定 `ANIMATION_DURATION_MS = 300`。
- 三条插值账（span）：`BoundsSpan`（`LogicalRect`）、`OpacitySpan`（`Double`）、`MoveSpan`（窗口 `LogicalPoint`，用于 `Window::set_position_animated`）。
- **变更点当场写真相**（Core 的 frame 永远是布局结果），后端显示由泵逐帧追。
- 起跑时刻由泵第一圈补记（`start_ms = -1` 表示未起跑）。
- **退场帧推精确的 `to`，不做插值**：浮点上 `lerp(a,b,1)` 未必逐位等于 `b`，测试要求"动画结束后与无动画树逐位同值"。
- 被中断的动画从**当前显示值**续跑，不从上一次真相续跑，避免跳变。

启用方式：`Widget::animate_bounds(curve?)` / `animate_opacity(curve?)`；`Window::set_position_animated(p, curve?)`。树的根会记 `needs_anim`，泵据此零开销跳过无动画树。

`App::pump_animations()` 每轮推进一帧；没有动画时一次 FFI 都不花。

## 6.7 任务与长按

- `App::post(fn)`：下一轮执行。
- `App::post_task(fn) -> TaskId`、`cancel_task(id)`。
- 长按：`MouseDown` 后由 `App::poll_long_press()` 用 `anim_clock` 判定，超过阈值且未移动则补发 `LongPress`。零 C。
- 悬停：`hover_track` 在 `MouseMove` 目标变化时补 `MouseLeave`/`MouseEnter`，并驱动 `set_hover_style` 的翻面。

## 6.8 无障碍

```moonbit
pub(all) enum AccessRole {
  Text | Button | CheckBox | TextBox | Group | List | ListItem
  | Window | SliderRole | ProgressRole
}
pub(all) struct AccessState { visible : Bool, enabled : Bool, checked : Bool? }
pub(all) struct Accessibility {
  id : Int32?
  role : AccessRole
  label : String
  description : String
  state : AccessState
  actions : Array[AccessAction]
}
```

- `Widget::set_accessibility(a)` 设置；`Widget::accessibility()` 读取解析后的值。
- `Widget::accessibility_tree()` 返回整棵子树的可达性节点（先序）。
- 每次重排 `apply_styles` 会把可达性信息一并下发（`set_widget_accessibility`），因为 `state` 是现读的（visible/enabled/checked 都问后端），改了勾选/禁用后下一次重排即同步。
- 没有角色的控件不发这次 FFI。

## 6.9 事件追踪

`DispatchTrace` 是 `T88①` 的观察者机制：

```moonbit
pub(all) struct DispatchTrace {
  event : Event
  mut route : TraceRoute     // MenuHit / MenuMiss / WindowArm / TreeArm / Missed / ThemeRefreshed
  capture : Array[TraceStop]
  direct : Array[TraceStop]
  bubble : Array[TraceStop]
  mut intercepted : Bool
  subscribed : Array[TraceStop]
}
pub(all) struct TraceStop { owner : Int32, accepted : Bool }
```

`App::set_event_trace(sink)` 打开；sink 在派发开始时快照，处理器中途换 sink 不影响本回合。关闭时零分配零调用。

用途：调试"事件为什么没到"、写断言、Inspector。

## 6.10 窗口移动与吸附

`Event::Moved` 只在**用户拖动**时产生：

1. 原生层发出 `Moved`；
2. `App::dispatch` 先 `follow_move(target, p)`，把同组的邻居窗口按同样位移带走；
3. 再路由给被拖窗口。

顺序不能反：邻居位移要按"这只窗已经到位"之后的几何算，否则每一步差一拍，拖动会越拖越散。

Core 自己调用 `set_position` 或做位移动画时，原生层会抑制 `Moved`（与 `suppress_resize` 同一条约定），避免"拖一只、带走邻居"时邻居的移动又回声成 `Moved`。

下一篇：[07 后端与 FFI](07-backends-and-ffi.md)。
