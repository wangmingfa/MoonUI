# 01 项目概览

## 1.1 它是什么

MoonUI 是给 MoonBit 用的 **GUI 框架**，不是某个 C GUI 库的绑定。框架把下面这些"应用要用的东西"定义在 MoonBit 这一层：

- 布局（行/列/内边距/居中/层叠/网格/滚动/尺寸约束）
- 事件模型与路由（点击、键盘、输入法、手势、拖放、菜单、窗口事件）
- 控件树与生命周期（创建、挂接、重排、销毁、句柄回收）
- 样式与主题（`Style` 层叠、浅色/深色/跟随系统、系统外观变化）
- HiDPI 几何（公共 API 一律逻辑像素）
- 平台能力接口（剪贴板、对话框、文件面板、菜单栏、托盘、通知）

平台差异（AppKit / Win32 / 自绘画布）只允许出现在 Backend 实现与 C adapter 里。Core 通过一个 `Backend` trait 与具体 GUI 对话，且因为当前 MoonBit 没有 `dyn`/trait object，走的是**泛型静态分发**：类型写作 `App[B : Backend]`、`Window[B]`、`Widget[B]`，后端在编译期选定。

## 1.2 设计原则（对应 DESIGN.md）

| 原则 | 含义 | 代码落点 |
| --- | --- | --- |
| Core 不出现 GUI 库名字 | Core 只依赖标准库；`wasm` 目标能完整编译是第一层证明 | [packages/moonui/moon.pkg](../../packages/moonui/moon.pkg) |
| 唯一的平台缝是 `Backend` trait | 平台函数名只出现在 `native-common/ffi.mbt` 与 `adapter.h` | [backend.mbt](../../packages/moonui/backend.mbt#L29-L335) |
| 公共 API 用逻辑像素 | 物理像素换算只在 `Scale` 与各 adapter 的 `px_to_pt` / DPI 换算里 | [geometry.mbt](../../packages/moonui/geometry.mbt) |
| 失败必须带原因 | 几乎所有可失败操作 `raise UiError`，错误类型是公开的 `suberror` | [error.mbt](../../packages/moonui/error.mbt) |
| 事件优先 | 高级 API（`on_click` 等）只是 `Event` 的语法糖，与底层共用同一模型 | [event.mbt](../../packages/moonui/event.mbt#L92-L169) |
| 原生控件优先，自绘是第二后端 | 默认后端把控件交给系统原生控件；自绘后端目前只在 macOS 落地，接管整个控件层 | [07 后端与 FFI](07-backends-and-ffi.md) |

## 1.3 当前能力（0.1 阶段）

已交付、有测试覆盖的部分：

- **布局引擎**：`Row` / `Column` / `Padding` / `Spacer` / `Center` / `Stack` / `Panel` / `Grid` / `Scroll` / `Sized`，测量 + 摆放分离，支持 `expand` / `fill_cross` / min/max。
- **控件**：`Label`、`Button`、`TextInput`、`MultilineEntry`、`Checkbox`、`PasswordInput`、`Slider`、`Spinbox`、`Progress`、`ComboBox`、`RadioButtons`、`DatePicker`、`Separator`、`VSeparator`、`MenuRow`、`Image`、`Custom`，以及容器/布局节点。
- **样式**：`Style`（宽高、min/max、margin、padding、背景/渐变、前景、字号/字重、圆角、透明度、背景模糊），`Theme`（Light/Dark/System），`Palette`，样式层叠 `Style::layer`，悬停样式，主题切换重算。
- **事件**：点击/双击/内容变化/输入/焦点/窗口关闭/缩放/移动/键盘/鼠标五变体/滚轮/菜单选择/DPI 变化/主题变化/绘制帧/输入法组合/长按/文件拖入/触控板手势。
- **运行时**：`App::run` 主循环、`step` 单步（测试用）、任务投递 `post` / `post_task`、定时器、窗口状态保存/恢复、事件追踪 `DispatchTrace`。
- **平台能力**：剪贴板、消息/确认对话框、打开/保存/选目录、菜单栏与快捷键、应用图标、托盘、通知。
- **自定义绘制**：`Widget::custom(size, paint)` + `DrawList`（14 条纯数据绘制命令）+ `PaintEnv` 文本度量，`repaint()` 触发重绘。
- **后端**：`MockBackend`（无头）、`NativeBackend` + Win32 adapter、`NativeBackend` + Cocoa adapter、`CanvasBackend`（macOS 自绘，包住原生后端）。
- **组件包**：`ProgressRing`、`Sparkline`、`DataGrid`、`TreeView`（只依赖 Core，不依赖任何 backend）。
- **示例**：五个核心无头 Demo（Hello / Counter / Form / Todo / File Manager）+ `gallery` + 三个 DX 示例（settings-center / markdown-editor / data-admin），共九个无头包；`gallery-native` 真窗口画册；`hello-canvas-native`、`lunamusic-native`、`lunamusic-canvas-native` 三个真窗口壳。

## 1.4 平台状态

| 平台 | 后端 | 状态 |
| --- | --- | --- |
| Windows | Win32 直写，`backends/native-windows/adapter_native.c` | 可用；真窗口测试 15 条，CI 只做链接闸门 |
| macOS | Cocoa 直写，`backends/native-macos/adapter_native.m` | 可用；真窗口测试由 `macos-backend-link` 真跑（47 条），示例只链接 |
| Linux | 计划 GTK3 直写 | 未接，见 TODO.md |
| Web/wasm | 无 GUI 后端 | Core 可编译、可跑无头测试，证明 Core 无 GUI 依赖 |

## 1.5 关键术语

| 术语 | 含义 |
| --- | --- |
| Core | `packages/moonui`，平台无关部分 |
| Backend | 实现 `Backend` trait 的类型，负责原生窗口/控件/事件 |
| Native backend | `NativeBackend`，通过 C adapter 调 AppKit/Win32 |
| Canvas backend | `CanvasBackend`，在 macOS 上包住 `NativeBackend`，把控件层接管为自绘画布（窗口/事件/系统服务仍复用原生后端） |
| 逻辑像素 | 公共 API 坐标单位；物理像素 = 逻辑 × `Scale` |
| `NativeHandle` | Core 侧句柄，`id + generation`，防悬空/防复用 |
| `WidgetKind` | 控件的类型标签；单个 `Widget[B]` 结构体 + 枚举，不是类继承 |
| `LayoutSpec` | 布局输入树，`Widget::to_layout_spec` 生成 |
| `Placed` | 布局输出：某个控件 id 的最终矩形 |
| 原生控件（native-backed） | 拥有底层原生对象、可 `set_bounds` 的叶子 |
| 布局节点（layout-only） | 不创建原生对象，只影响子节点几何 |
| `UiError` | 统一错误类型，带消息 |

## 1.6 它不是什么

- **不是 libui-ng / SDL3 / GTK 的绑定**：`backends/libui-*` 已在 T82 删除。现在只有原生直写 + macOS 自绘两条。
- **不是跨平台统一外观的"像素级一致"框架**：默认走原生控件，外观由平台决定。
- **不是响应式/声明式 DSL**：API 是命令式创建 + 句柄式修改；`Widget` 是可变树，重新构建由用户代码负责。
- **不是多线程 UI**：UI 操作在主线程；后台工作通过 `App::post` / `post_task` 回到主循环。
- **不是稳定 ABI 承诺**：0.1 阶段，`.mbti` 会随版本变化。

## 1.7 从哪里开始读代码

1. `App::new` → `App::run`：[app.mbt](../../packages/moonui/app.mbt)
2. `Window::new` / `set_content` / `relayout`：[window.mbt](../../packages/moonui/window.mbt)
3. `Widget` 的构造与 `to_layout_spec`：[widget.mbt](../../packages/moonui/widget.mbt)
4. 布局算法：[layout.mbt](../../packages/moonui/layout.mbt)
5. `Backend` trait：[backend.mbt](../../packages/moonui/backend.mbt)
6. 原生实现：[native-common/backend.mbt](../../backends/native-common/backend.mbt)、[native-common/ffi.mbt](../../backends/native-common/ffi.mbt)
7. 自绘实现：[canvas-macos/backend.mbt](../../backends/canvas-macos/backend.mbt)、[canvas-common](../../backends/canvas-common)

下一篇：[02 整体架构](02-architecture.md)。
