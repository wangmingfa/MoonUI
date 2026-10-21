# 02 整体架构

## 2.1 分层

```
┌──────────────────────────────────────────────────────────────┐
│ 应用 / 示例 / 组件                                             │
│ examples/*、packages/widgets、packages/moonui-app              │
└───────────────────────────┬──────────────────────────────────┘
                            │ 只用公开 API（App / Window / Widget / Event / Style）
┌───────────────────────────▼──────────────────────────────────┐
│ Core：packages/moonui                                         │
│                                                              │
│  app.mbt      主循环、任务、订阅、快捷键、菜单、主题、存档       │
│  window.mbt   窗口生命周期、重排、绘制顺序、焦点链、事件路由    │
│  widget.mbt   控件树、WidgetKind、属性、绘制清单                 │
│  layout.mbt   纯布局算法：measure / layout                      │
│  event.mbt    事件与目标                                        │
│  style.mbt / theme.mbt / palette.mbt   样式与主题                 │
│  geometry.mbt 逻辑像素几何、Scale、Rect、Insets                  │
│  handle.mbt   NativeHandle + HandleTable（防悬空/防复用）        │
│  backend.mbt  trait Backend + MockBackend（无头实现）             │
│  ...          菜单、动画、无障碍、Docking、Runner、Inspector 等   │
└───────────────────────────┬──────────────────────────────────┘
                            │ 唯一平台缝：trait Backend（静态分发）
        ┌───────────────────┴────────────────────┐
        ▼                                        ▼
┌───────────────────────┐              ┌──────────────────────────┐
│ native-common          │              │ canvas-common            │
│  MoonBit 侧 trait 实现 │              │  Painter trait + 绘制配方 │
│  ffi.mbt（extern "c"） │              │  零 C、零 FFI            │
│  adapter.h（C ABI）    │              └──────────┬───────────────┘
└──────────┬────────────┘                          │
           │ prebuild-link.js 现编并挂链接           │
     ┌─────┴──────┐                                 │
     ▼            ▼                                 ▼
 native-windows  native-macos              canvas-macos
 adapter_native.c adapter_native.m         CanvasBackend
 （Win32）        （Cocoa）                 包住 NativeBackend，
                                            Custom 画进 canvas
```

关键点：

- **依赖方向单向**：`packages/moonui` 不 import 任何 `backends/*`。`wasm` 目标能构建 Core 是这条规则的机器证明。
- **平台分叉只到 C**：`native-common` 的 `ffi.mbt` / `backend.mbt` 在 Windows 与 macOS 上完全相同；两平台差异只在 `adapter_native.c` / `adapter_native.m` 与 `prebuild-link.js` 的链接段。
- **链接配置挂在 `native-common`**：adapter 由 prebuild 现编后挂到 `native-common`，顺 import 传播给测试二进制和示例壳，避免同一份 adapter 被链接两遍（见各 `moon.pkg` 注释与 [07](07-backends-and-ffi.md)）。
- **前台门 `packages/moonui-app`**：用户不直接 import 后端包，通过 `new_app()` 拿到 `App[NativeBackend]`，省掉后端构造与 `init` 时序。

## 2.2 对象模型

```
App[B]
 ├─ backend : B                     具体后端实例
 ├─ windows : Array[Window[B]]      存活窗口（按创建顺序）
 ├─ subs    : Array[Subscription]   事件订阅（target + accept + handler）
 ├─ posted  : Array[PostedTask]     post / post_task 队列
 ├─ theme / style_base             全局主题与样式层叠起点
 └─ shortcuts / menubar / traces   ...

Window[B]
 ├─ backend : B
 ├─ handle  : NativeHandle          原生窗口句柄（id + generation）
 ├─ content : Widget[B]?            根控件
 ├─ style_base : Style              该窗口的样式基线（受主题影响）
 └─ move_anim / last_origin / ...   位移动画、吸附跟随

Widget[B]
 ├─ kind : WidgetKind               控件类型标签
 ├─ handle : NativeHandle?          原生对象句柄（布局节点为 None）
 ├─ children : Array[Widget[B]]
 ├─ style : Style?    resolved : Style?
 ├─ handlers : Array[...]           事件处理器（capture / bubble / any）
 └─ ...                             文本、值、可达性、动画
```

`Backend` 是无状态偏好的**服务对象**：Core 把 `NativeHandle` 传给它的每个方法，由它转成平台对象。`NativeHandle` 只是 `id + generation`，真正的指针映射在 `HandleTable` 里（`MockBackend` 也有一张），因此 Core 不持有任何平台指针。

## 2.3 一次运行：`App::run`

入口在 [app.mbt](../../packages/moonui/app.mbt#L964)。简化后的顺序：

```
App::new(backend)                 创建订阅表、窗口表、默认主题
App::run
  ├─ backend.init()                初始化原生工具链
  ├─ 创建/显示窗口（用户代码在此之前已做）
  ├─ drive()                       循环直到 quit / 无窗口
  │    ├─ step()                   见下
  │    └─ 空闲时等待原生消息（后端 wait）
  ├─ backend.terminate()           释放资源
  └─ 汇总第一个 UiError 抛出
```

`App::step`（[app.mbt#L907](../../packages/moonui/app.mbt#L907)）是**单步推进**，测试与服务端模式都用它：

1. `drain_posted()` — 执行 `post` / `post_task` 投递的回调；
2. `backend.poll_event()` — 非阻塞取一条原生事件；取到就 `dispatch(event)`；
3. `flush_layout()` — 处理本步产生的布局脏标记，对脏窗口 `relayout()`；
4. `poll_long_press()` — 用 `anim_clock` 判定长按；
5. `pump_animations()` — 推进补间动画，必要时 `backend.request_redraw`；
6. 返回"是否还有活干"（posted/动画/事件/脏布局任一为真）。

`App::run` 的 `drive` 会捕获 `UiError`，先停后端再抛出，保证不会把错误吞掉。

## 2.4 一次事件：`App::dispatch`

`dispatch` 在 [app.mbt#L760](../../packages/moonui/app.mbt#L760)，分三条互斥/叠加的路径：

```
dispatch(event)
 ├─ 1. 菜单事件：Event::MenuSelect
 │      → 找菜单项回调 → 调 handler → 结束
 ├─ 2. 窗口/控件路由（其余事件）
 │      ├─ 按 target.id 找窗口或控件
 │      ├─ 构造路由链（capture 由外到内，bubble 由内到外）
 │      ├─ 命中即调用处理器；Click/Scroll 等还会触发 Core 内建行为
 │      ├─ KeyDown → 先查窗口快捷键表 → 再进控件
 │      ├─ ThemeChanged → 重算窗口 style_base → relayout
 │      └─ Close → 关闭窗口、回收控件树
 └─ 3. 订阅广播：所有 accept(event) 为真的 Subscription 依次执行
        （在状态更新之后，保证订阅看到新状态）
```

要点：

- **处理器返回值表示"吃掉"**：`Widget::on` 的 `accept` 返回 `Bool`，为真则停止向下一级传播；`on_any` 不参与决定。
- **capture/bubble**：`on_capture` 由根向叶，`on_bubble` 由叶向根；`on_click` 等是 bubble 语义的语法糖。
- **`EventTarget` 带 `generation`**：句柄 id 会被回收复用，只比 id 会命中"同号新主人"，所以订阅与事件目标都记 `id + generation`。
- **悬停是 Core 合成的**：后端只发 `MouseMove`，Core 在目标变化时补 `MouseLeave` / `MouseEnter`。
- **订阅在状态更新后执行**：适合做日志、持久化、跨窗口联动；不要在这里修改导致再次派发的事件，除非用 `post` 推迟。

## 2.5 一次重排：`Window::relayout`

`Window::relayout` 在 [window.mbt#L779](../../packages/moonui/window.mbt#L779)，是"样式 → 布局 → 原生几何 → 绘制顺序"的唯一入口：

```
relayout()
 ├─ 生成 style_base（主题 + 窗口基线）
 ├─ walk 控件树：apply_styles()         解析每个控件的最终 Style（层叠）
 ├─ push_order_chains()                 把 paint order / focus chain 推给后端（去重）
 ├─ do_layout(window_rect)              递归 measure + layout，得到 Placed[]
 ├─ 对每个 Placed：set_bounds()         原生控件设物理位置（逻辑→物理由后端换算）
 └─ 对 Custom / 自绘后端：request_redraw / draw_custom
```

`push_order_chains`（[window.mbt#L728](../../packages/moonui/window.mbt#L728)）会缓存上次推送的 `pushed_order` / `pushed_chain`，只在与新值不同时调 `set_paint_order` / `set_focus_chain`，避免每帧重建原生层级。

布局本身是纯函数：`Widget::to_layout_spec` 把控件树投影成 `LayoutSpec`，`measure()` 与 `layout()`（[layout.mbt#L169](../../packages/moonui/layout.mbt#L169)、[#L210](../../packages/moonui/layout.mbt#L210)）不接触任何后端。原生控件的"固有尺寸"通过一次 `widget_intrinsic_size` 查询进入 `LeafSpec`，之后布局计算全在 MoonBit 内完成。

## 2.6 一次建窗与销毁

```
App::create_window(title, size)
  └─ Window::new(backend, title, size)
       ├─ backend.create_window → NativeHandle
       ├─ 读 Scale、屏幕工作区、系统主题
       └─ 设置窗口基线 Style
Window::set_content(root)
  ├─ 若已有内容：close_tree（递归销毁原生控件）
  ├─ attach_widget(window, root) 挂根
  ├─ 为每个控件建原生对象（布局节点除外）
  └─ relayout()
Window::close()
  ├─ backend.destroy_window
  └─ close_tree → 逐个 destroy_widget，句柄表回收
```

布局节点（`Row` / `Column` / `Padding` / `Spacer` / `Center` / `Stack` / `Grid` / `Sized`）**不创建原生对象**；它们的子控件通过 `attach_widget_to(container, child)` 挂到最近的原生容器（窗口或 `Panel` / `Scroll` 的内容视图）上，再由 Core 计算绝对矩形后 `set_bounds`。

## 2.7 线程与任务模型

- UI 全部在主线程；`App` 与 `Window`/`Widget` 不是线程安全的，也不打算是。
- 后台工作用 `App::post(fn)`（下一轮执行）或 `App::post_task(fn) -> TaskId`（可取消）。
- `TaskId` 可传给 `cancel_task`；任务执行时若已取消则跳过。
- 平台事件循环在 `run` 里由后端 `wait` 驱动；`step` 模式下由调用方自己驱动。

## 2.8 架构约束与权衡

| 约束 | 原因 | 影响 |
| --- | --- | --- |
| `App[B]`、`Widget[B]` 全泛型 | MoonBit 没有 `dyn`，trait 不是类型 | 后端编译期选定；一个可执行包只能用一个后端（`CanvasBackend` 通过包住 `NativeBackend` 规避） |
| `Backend` 方法多（70+） | 所有平台能力集中一处，Core 不散落平台判断 | 接新平台要一次实现完整 trait；缺失能力用显式错误返回 |
| 控件单结构体 + 枚举 | 避免类继承与 trait 对象；布局节点与原生控件共用树 | 某些方法只对特定 kind 有意义，错误时 `UiError` |
| 布局节点无原生对象 | 减少原生层级、布局完全可控 | 需要 `Panel`/`Scroll` 这类真实容器时单独建原生对象 |
| 链接配置在 prebuild | `moon.pkg` 不能按宿主 OS 分支 | 所有 `moon` 命令必须在仓库根跑；需要 node |
| 自绘后端包住原生后端 | 窗口/事件/菜单复用原生实现，只替换绘制 | 仅 macOS 有；`Custom` 之外仍走原生控件 |

下一篇：[03 模块地图](03-modules.md)。
