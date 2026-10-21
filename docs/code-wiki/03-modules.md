# 03 模块地图

## 3.1 包一览

| 包 | 路径 | 角色 | 关键依赖 | 目标 |
| --- | --- | --- | --- | --- |
| Core | `packages/moonui` | 框架本体：布局、事件、控件、样式、主循环、Mock | 标准库（`utf8` / `json` / `env`） | native + wasm |
| 前台门 | `packages/moonui-app` | `new_app()` / `worker_run()`，把真后端收进一个入口 | Core、`native-common` | 仅 native |
| 组件 | `packages/widgets` | 基于 `Widget::custom` 的高阶控件 | Core、`core/string` | native + wasm |
| 原生共享 | `backends/native-common` | `Backend` 的 MoonBit 实现、`extern "c"` 声明、C ABI 头、`Canvas` FFI、`CanvasPainter`、链接汇总点 | Core、`canvas-common` | 仅 native |
| Windows 后端 | `backends/native-windows` | Win32 C adapter + 真窗口测试 | Core、`native-common` | 仅 native |
| macOS 后端 | `backends/native-macos` | Cocoa C adapter + 真窗口测试 + 测试脚手架 | Core、`native-common` | 仅 native |
| 自绘共享 | `backends/canvas-common` | `Painter` trait、绘制配方、`RecordCanvas` | Core | native + wasm |
| 自绘 mac | `backends/canvas-macos` | `CanvasBackend`：包住 `NativeBackend`，记录 `CwRec`、帧循环、鼠标翻译 | Core、`native-common`、`canvas-common` | 仅 native |
| 示例 | `examples/*` | 可执行 Demo 与示例装配 | Core / 前台门 / 后端 | 见各包 |
| FFI 探针 | `tests/ffi` | 自带 C stub，只验证 MoonBit ↔ C | Core | native |
| 文档校验 | `_doccheck` | 用公开 API 编译 README 片段 | Core | 全部 |

（`backends/libui-*` 已删除，不再存在。）

## 3.2 包依赖图

```
packages/widgets ───────────────┐
examples/* ── packages/moonui-app ── backends/native-common ── backends/canvas-common
                     │                     │                    │
                     └── packages/moonui ◄─┴────────────────────┘
                                              ▲
examples/gallery-native ──────────────────────┘（经 native-common 的 prebuild 链接）
examples/hello-canvas-native ── backends/canvas-macos ── native-common + canvas-common
examples/lunamusic-native ── lunamusic-shell ── moonui-app / moonui
examples/lunamusic-canvas-native ── lunamusic-shell + canvas-macos
```

硬性约束：

- `packages/widgets` **只能** import Core 与标准库，不能碰 `backends/`（`scripts/test-local.sh` 开头有 grep 闸门）。理由：一份控件配方要能在原生后端、自绘后端、Mock 上都成立。
- `packages/moonui` 不能 import 任何 backend；wasm 门禁结构性钉住这条。
- `native-common` 可以 import `canvas-common`（`Painter` 是共同语言），反向不行，避免成环。
- 任何可执行包只能 import 一个真后端；换后端只换 import，Core 不改。

## 3.3 Core 文件地图

| 文件 | 行数量级 | 职责 | 关键符号 |
| --- | --- | --- | --- |
| [app.mbt](../../packages/moonui/app.mbt) | ~1500 | 应用对象、主循环、派发、任务、订阅、快捷键、主题、菜单、对话框、存档 | `App`、`App::new/run/step/dispatch/post/set_theme` |
| [window.mbt](../../packages/moonui/window.mbt) | ~1200 | 窗口生命周期、内容挂接、重排、绘制顺序、焦点链、事件路由、窗口状态 | `Window`、`set_content`、`relayout`、`push_order_chains` |
| [widget.mbt](../../packages/moonui/widget.mbt) | ~3000 | 控件树、全部构造器与属性、样式解析、布局投影、事件处理器 | `Widget`、`WidgetKind`、`on_click`、`to_layout_spec` |
| [layout.mbt](../../packages/moonui/layout.mbt) | ~1250 | 纯布局：约束、测量、摆放、各容器算法 | `LayoutSpec`、`measure`、`layout`、`Placed` |
| [backend.mbt](../../packages/moonui/backend.mbt) | ~1700 | `Backend` trait、`MockBackend`、平台枚举 | `Backend`、`MockBackend`、`HostPlatform` |
| [event.mbt](../../packages/moonui/event.mbt) | ~315 | 事件、目标、按键、鼠标键、手势 | `Event`、`EventTarget`、`KeyPress` |
| [style.mbt](../../packages/moonui/style.mbt) | ~431 | 样式结构与层叠 | `Style`、`Style::layer` |
| [theme.mbt](../../packages/moonui/theme.mbt) | ~101 | 浅色/深色/系统主题与默认样式 | `Theme`、`Theme::resolve` |
| [geometry.mbt](../../packages/moonui/geometry.mbt) | ~534 | 点、尺寸、矩形、缩进、约束、Scale | `LogicalPoint`、`LogicalRect`、`BoxConstraints`、`Scale` |
| [handle.mbt](../../packages/moonui/handle.mbt) | ~365 | 句柄与句柄表 | `NativeHandle`、`HandleTable` |
| [error.mbt](../../packages/moonui/error.mbt) | ~92 | 统一错误 | `UiError` |
| [draw_list.mbt](../../packages/moonui/draw_list.mbt) | ~297 | 纯数据绘制清单 | `DrawList`、绘制命令 |
| [menu.mbt](../../packages/moonui/menu.mbt) | ~948 | 菜单栏、菜单、快捷键冲突检查 | `MenuBar`、`Menu`、`MenuItem` |
| [shortcut.mbt](../../packages/moonui/shortcut.mbt) | ~164 | 快捷键描述与匹配 | `Shortcut` |
| [animation.mbt](../../packages/moonui/animation.mbt) | ~167 | 补间曲线与动画状态 | `AnimationCurve` |
| [accessibility.mbt](../../packages/moonui/accessibility.mbt) | ~597 | 可达性角色/标签/树 | `Accessibility`、`AccessRole` |
| [docking.mbt](../../packages/moonui/docking.mbt) | ~313 | 窗口吸附/跟随移动 | 见 `App::follow_move` |
| [declarative.mbt](../../packages/moonui/declarative.mbt) | ~436 | 轻量声明式构建辅助 | 构建函数 |
| [components.mbt](../../packages/moonui/components.mbt) | ~887 | 可复用复合控件（`Tabs` 等） | `Tabs`、`Form` 等 |
| [gallery.mbt](../../packages/moonui/gallery.mbt) | ~748 | 组件画册的树（无头/真窗口共用） | `Gallery::demo` |
| [demo.mbt](../../packages/moonui/demo.mbt) | ~1515 | Hello/Counter/Form/Todo/FileManager 演示树 | `Demo::hello` 等 |
| [demo_dx.mbt](../../packages/moonui/demo_dx.mbt) | ~826 | DX 示例树 | settings/markdown/data-admin |
| [window_state.mbt](../../packages/moonui/window_state.mbt) | ~340 | 窗口位置/尺寸/状态的序列化 | `WindowState`、`WindowFrame` |
| `window_state_file_native.mbt` | ~138 | native 存档落盘（libc stdio extern） | 按 targets 门控 |
| `window_state_file_wasm.mbt` | ~19 | wasm 半显式缺席，报 `Unsupported` | 按 targets 门控 |
| [trace.mbt](../../packages/moonui/trace.mbt) | ~302 | 事件派发追踪 | `DispatchTrace` |
| [inspector.mbt](../../packages/moonui/inspector.mbt) | ~282 | 控件树/布局调试输出 | `dump_layout` |
| [mock_widget.mbt](../../packages/moonui/mock_widget.mbt) | ~714 | 测试用控件辅助 | Mock 侧构造 |
| [l10n.mbt](../../packages/moonui/l10n.mbt) | ~216 | 文案/本地化辅助 | — |
| [clipboard.mbt](../../packages/moonui/clipboard.mbt) | ~33 | 剪贴板门面 | — |
| [dialog.mbt](../../packages/moonui/dialog.mbt) | ~93 | 对话框门面 | — |
| `*_test.mbt` / `*_wbtest.mbt` | ~3000 | blackbox / whitebox 测试 | 见 [09](09-build-and-test.md) |

## 3.4 后端文件地图

### `backends/native-common`

| 文件 | 职责 |
| --- | --- |
| `ffi.mbt` | 所有 `extern "c"` 声明（`moonui_native_*`、`moonui_canvas_*`、音频、菜单、托盘、对话框等），是 MoonBit 侧唯一出现平台函数名的地方 |
| `backend.mbt` | `impl @moonui.Backend for NativeBackend`，把事件队列、句柄表、窗口/控件生命周期、菜单、主题、无障碍等接到 FFI |
| `canvas.mbt` | `Canvas` 类型与 `moonui_canvas_*` 的 MoonBit 包装、`CanvasPainter` |
| `painter.mbt` | `impl Painter for CanvasPainter`（逻辑→物理换算） |
| `adapter.h` | 唯一的 C ABI 头；两平台 adapter 都 include 它 |

### `backends/native-windows` / `backends/native-macos`

| 文件 | 职责 |
| --- | --- |
| `adapter_native.c` / `adapter_native.m` | 平台实现：窗口、原生控件、事件、菜单、剪贴板、对话框、托盘、画布、音频 |
| `native_test.mbt` | 真窗口测试（创建窗口、控件往返、菜单、剪贴板、图像、手势等） |
| `scaffold.mbt`（仅 mac） | 测试脚手架（坐标点击、打字、勾选、焦点等，`T103`） |

### `backends/canvas-common`

| 文件 | 职责 |
| --- | --- |
| `painter.mbt` | `Painter` trait、可复用绘制配方（`paint_panel`、`paint_gradient_panel`、`paint_frosted_panel`、`paint_label`、`paint_slider`、`paint_text_input`、`paint_icon_button`、`paint_menu_row`、`paint_separator`、`replay`） |
| `widgets.mbt` | 控件外观配方（按 `WidgetKind` 分派） |
| `RecordCanvas` | 录制式画布，测试断言"画了什么、按什么参数画" |

### `backends/canvas-macos`

| 文件 | 职责 |
| --- | --- |
| `backend.mbt` | `CanvasBackend` 结构、`Backend` 转发、资源表 |
| `impl.mbt` | 各 trait 方法实现与 WidgetKind → 绘制配方分派 |
| `frame.mbt` | 帧预算、`request_redraw`、`Frame` 事件、逐帧绘制 |
| `mouse.mbt` | 鼠标事件翻译、悬停/按压状态、逻辑坐标 |
| `native_test.mbt` 等价物：`canvas_backend_test.mbt` / `canvas_macos_test.mbt` | 无头/真画布测试 |

## 3.5 示例地图

| 目录 | 类型 | 说明 |
| --- | --- | --- |
| `examples/hello` | 无头 | 最小窗口 + 标签 + 按钮，打印事件 |
| `examples/counter` | 无头 | 状态更新与 `set_text` |
| `examples/form` | 无头 | 登录表单、输入校验、焦点 |
| `examples/todo` | 无头 | 列表增删、滚动容器 |
| `examples/file-manager` | 无头 | `FsStore` + 行选择 + 详情面板 |
| `examples/gallery` | 无头 | 组件画册逐页打印 |
| `examples/gallery-native` | 真窗口 | 组件画册，左栏选组件、右栏看效果；两平台共用一份壳 |
| `examples/settings-center` | 无头 DX | 设置界面（导航 + 分组表单） |
| `examples/markdown-editor` | 无头 DX | 编辑器 + 预览 |
| `examples/data-admin` | 无头 DX | `DataGrid` 表格管理 |
| `examples/hello-canvas-native` | 真窗口 | 与 `hello` 同一棵树，后端换成 `CanvasBackend` |
| `examples/lunamusic` | 库 | LunaMusic 的模型/皮肤/布局/播放器/歌词/UI 组件 |
| `examples/lunamusic-shell` | 库 | 应用装配，两种壳共用 |
| `examples/lunamusic-native` | 真窗口 | 原生后端壳 |
| `examples/lunamusic-canvas-native` | 真窗口 | 自绘后端壳，同一棵树 |

## 3.6 改哪里

| 需求 | 去处 |
| --- | --- |
| 新增布局容器 | `layout.mbt` 加 `LayoutSpec` 变体与 measure/layout 分支；`widget.mbt` 加构造器与 `to_layout_spec`；`WidgetKind` 加标签 |
| 新增原生控件 | `WidgetKind` + `Widget` 构造器；`Backend::create_widget`（若需新原生类型）；两侧 C adapter 各加实现 |
| 新增事件 | `event.mbt` 加变体；`native-common/ffi.mbt` + `backend.mbt` 翻译；两侧 C 入队 |
| 新增样式属性 | `Style` 字段 + `Style::layer`；`Widget::apply_styles`；`Backend::set_widget_style` 与两侧 C |
| 新增平台能力 | `Backend` trait 方法 → `NativeBackend` 实现 → `ffi.mbt` extern → 两侧 C；`MockBackend` 给默认/记录实现 |
| 新增高阶控件 | 优先 `packages/widgets`，用 `Widget::custom` + `DrawList`，不要碰 backend |
| 新增示例 | `examples/<name>` + `main.mbt` + `moon.pkg`；无头用 `MockBackend`，真窗口用 `moonui-app` |
| 修改链接/平台编译 | `prebuild-link.js`；不要在 `moon.pkg` 里加 `link`（宿主无法分支） |

下一篇：[04 运行时核心](04-core-runtime.md)。
