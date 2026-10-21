# 08 组件与示例

## 8.1 `packages/widgets`：高阶控件

定位：只依赖 Core（`@moonui`）与标准库，**不碰任何 `backends/`**（`scripts/test-local.sh` 的 grep 闸门守着这条）。所有控件都基于 `Widget::custom` + `DrawList`，因此在原生后端、自绘后端、Mock 上表现一致。

| 控件 | 入口 | 能力 |
| --- | --- | --- |
| `DataGrid` | `DataGrid::new(backend, columns, rows?, ...)` | 表头 + 行、列宽、横向滚动、选中行、排序（`sort_by_column` / `clear_sort`）、斑马纹、空态 |
| `GridColumn` | `GridColumn::new(title, width, right?, numeric?)` | 列定义 |
| `ProgressRing` | `ProgressRing::new(backend, value, size?, thickness?, ...)` | 环形进度、标签、强调色 |
| `Sparkline` | `Sparkline::new(backend, series, ...)` | 折线/面积、基线、端点、范围、`push` 追加 |
| `TreeView` | `TreeView::new(backend, root, width?, height?, row_height?, indent?, ...)` | 可展开树、缩进、引导线、选中、滚动、`toggle` |
| `TreeNode` | `TreeNode::new(id, label, children?, detail?)` | 树节点数据 |

共同模式：

```moonbit
let grid = @widgets.DataGrid::new(app.backend(), columns, rows~)
let w = grid.widget()          // 拿回 Widget[B] 挂进树
grid.select_row(3)             // 改状态，内部 repaint
```

这些控件内部维护自己的状态（偏移、选中、排序），通过 `repaint()` 触发重绘；不依赖后端事件回调，点击坐标用 `row_at` / `column_at` 自己做命中测试。

## 8.2 Core 内置复合组件

`packages/moonui/components.mbt` 提供一套"可复用但不是自绘"的复合结构（`Card`、`Tabs`、`Pagination`、`Breadcrumb`、`RadioGroup`、`Rate`、`Steps`、`Alert`、`VirtualList`），它们由现有 `Widget` 组合而成，会创建原生控件：

| 组件 | 形态 |
| --- | --- |
| `Card` | 标题 + 若干子控件，容器带样式 |
| `Tabs` | 标签栏 + 懒构建内容（`Array<() -> Widget[B]>`） |
| `Pagination` | 上一页/页码/下一页 + `on_change` |
| `Breadcrumb` | 路径片段 + `on_navigate` |
| `RadioGroup` | 单选组 + 标题 + `on_change` |
| `Rate` | N 颗星 + `set_value` / `value` |
| `Steps` | 步骤条 + `set_current` |
| `Alert` | 类型、标题、描述 |
| `VirtualList` | 固定行高的虚拟化列表，自带滚动与可见区裁剪 |

与 `packages/widgets` 的区别：这些是"布局 + 原生控件的组合"，需要后端支持原生控件；`packages/widgets` 是"一块画布自己画"，只依赖 `DrawList`。

## 8.3 无头示例（9 个）

全部用 `examples/common.new_app()`（内部是 `MockBackend`）+ `App::step` 驱动，任何平台（含 wasm）可跑：

```bash
moon run examples/hello
moon run examples/counter
moon run examples/form
moon run examples/todo
moon run examples/file-manager
moon run examples/gallery
moon run examples/settings-center
moon run examples/markdown-editor
moon run examples/data-admin
```

`examples/lunamusic` 是**库包**不是可执行包，没有 `main.mbt`，不能 `moon run`；它是 `lunamusic-shell` 与两个真窗口壳共用的应用本体（见 8.5）。`examples/common` 也是库包，提供 `new_app()`（返回 `App[MockBackend]`）、`rect_text`、`join`、无障碍打印等工具。

| 示例 | 验证什么 | 本体位置 |
| --- | --- | --- |
| `hello` | 最小链路：建窗、挂内容、点击改文案、布局矩形 | `packages/moonui/demo.mbt` 的 `Demo::hello` |
| `counter` | 状态更新与 `set_text`、重排 | `Demo::counter` |
| `form` | 登录表单、输入、校验、焦点 | `LoginForm` |
| `todo` | 列表增删 + 滚动容器 | `demo.mbt` |
| `file-manager` | `FsStore`、行选择、详情面板、面包屑 | `FileManager` |
| `gallery` | 组件画册（无头逐页） | `packages/moonui/gallery.mbt` |
| `settings-center` | 设置页持久化闭环 | `demo_dx.mbt` |
| `markdown-editor` | 编辑器 + 解析 + 落盘读档 | `MarkdownDemo` |
| `data-admin` | 1000 行合成数据下的虚拟化 | `DataAdminDemo` |

关键设计：**Demo 本体在 Core 库里，入口只有几行**。这样同一份 UI 逻辑能同时跑无头与真窗口，测试断言与示例输出不会分叉。

## 8.4 真窗口示例

### `gallery-native`

```bash
moon run examples/gallery-native
```

- 960×480 画册窗口，左栏 `MenuRow` 清单、右栏示例代码 + 真控件。
- 换页走 `Window::set_content` 整树重建，交互状态存在 `Gallery` 结构体上。
- macOS 与 Windows 共用**逐字相同**的 `main.mbt` 与 `moon.pkg`。
- 不进 CI：需要真人点鼠标；编译链路会被 CI 的 `moon build` 覆盖。

### `hello-canvas-native`

```bash
moon run examples/hello-canvas-native
```

与 `hello` 同一棵树，唯一差别是后端：

```moonbit
let b = @canvas-macos.CanvasBackend::new()
@moonui.Backend::init(b)
let app = @moonui.App::new(b)
```

用来证明"同树双后端"：Core 一行不改。

### `lunamusic-native` / `lunamusic-canvas-native`

```bash
moon run examples/lunamusic-native
moon run examples/lunamusic-canvas-native
```

两个壳只差后端构造，装配逻辑在 `examples/lunamusic-shell`：

```moonbit
// 原生壳
let app = @moonui-app.new_app()
@lunamusic-shell.launch(app)

// 自绘壳
let b = @canvas-macos.CanvasBackend::new()
@moonui.Backend::init(b)
let app = @moonui.App::new(b)
app.set_anim_clock(@native-common.native_time_ms)
app.set_anim_wake(fn(active) { b.set_frame_budget(active) })
@lunamusic-shell.launch(app)
```

自绘壳必须显式接时钟与唤醒：`CanvasBackend` 不持事件循环，`set_frame_budget` 把等待预算转发给内嵌的 `NativeBackend`（`-1 ↔ 8ms`）。

## 8.5 LunaMusic

`examples/lunamusic` 是一比一复刻常见音乐客户端桌面端的**应用本体库包**，不是示例壳：

| 部分 | 说明 |
| --- | --- |
| `AudioEngine` trait | 音频抽象；测试用 `MockAudioEngine`，wasm 可跑全套状态机 |
| `NativeAudioEngine` | 在 `lunamusic-shell`，唯一碰 `moonui_native_audio_*` 的 MoonBit 代码 |
| 存储/目录行走 | `storage_native.mbt` / `walk_native.mbt`（native）与 `*_wasm.mbt`（显式 `Unsupported`），按 `targets` 门控 |
| UI | 播放条、曲库表格（`VirtualList`）、抽屉、歌词、皮肤 |
| 设计文档 | `examples/lunamusic/DESIGN.md` |

门控约定：`moon.pkg` 的 `options(targets: {...})` 按文件指定目标，native 半声明 libc/音频符号，wasm 半同签名显式缺席。**不允许静默假装成功**。

## 8.6 写一个新示例

无头：

```
examples/my-demo/
  moon.pkg      # import packages/moonui 与 examples/common
  main.mbt      # 构造 MockBackend，App::step 驱动，打印断言
```

真窗口：

```
examples/my-demo-native/
  moon.pkg      # import packages/moonui-app（+ 可选后端）
  main.mbt      # new_app() → 建 UI → app.run()
```

约定：

- 真后端目录名以 `-native` 结尾（`scripts/ci-packages.sh` 靠后缀把 native-only 包排除出跨平台门禁）。
- 无头示例不带后缀，必须能在 wasm 目标下编译。
- UI 树尽量放回 `packages/moonui` 的 `demo*.mbt`，入口保持几行，便于无头与真窗口共用。

## 8.7 示例与测试的关系

- `gallery` 的每一页控件都在 `packages/moonui` 里有测试断言（布局矩形、文本、状态往返）。
- 真窗口测试在 `backends/native-windows` / `backends/native-macos` 的 `native_test.mbt`，不在示例里。
- CI 对示例只做编译/链接（`gallery-native`），不运行（要人关窗）。

下一篇：[09 构建与测试](09-build-and-test.md)。
