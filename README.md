# MoonUI

MoonBit 的桌面 GUI 框架。布局、事件、控件、样式、主题、HiDPI 与无障碍视图均在**后端无关的 Core** 中实现；平台差异保留在 Backend 实现侧——macOS 直写 AppKit、Windows 直写 Win32、Linux 直写 GTK4。应用代码切换后端时无需修改。

> MoonBit API 是第一公民，C 只是实现手段，Backend 永远不能反向决定 MoonUI 的 API。

**0.1.0** · Apache-2.0 · Windows / macOS / Linux(GTK4) 原生后端 · wasm 可移植性闸门

| 文档 | 内容 |
| --- | --- |
| [DESIGN.md](DESIGN.md) | 设计文档（53 节 + 附录）；代码中的 `§nn` 引用均指向它 |
| [API.md](API.md) | 全量公开 API 中文参考（响应式见 §19） |
| [TODO.md](TODO.md) | 全部待办与完成记录，按 `Tnn` 编号 |
| [AGENTS.md](AGENTS.md) | 工程约定与协作规则（篇幅最短） |
| [docs/backend-lessons.md](docs/backend-lessons.md) | 后端实现要点与真窗口验证记录 |
| [docs/build-and-environment.md](docs/build-and-environment.md) | 构建链前置条件、平台准备、环境排错 |
| [docs/code-wiki](docs/code-wiki/README.md) | 代码级导读（2026-10-21 基线，非权威来源） |

**建议阅读顺序**：AGENTS.md → 本页的「定位」与「目录」→ DESIGN.md §14（布局）/ §10（事件）/ §48（路线图）→ API.md（查询具体 API）→ TODO.md（认领任务）。提交改动前先运行 `moon info && moon fmt`，并将 `pkg.generated.mbti` 与代码一同提交。

## 定位：框架，而非绑定

**是框架**：Core 负责布局算法、事件路由、句柄生命周期、样式与主题的层叠、无障碍视图的推导；后端只负责把计算完成的矩形与属性写入原生层，并将原生事件送回 `App`。

**不是绑定**：`uiButton*`、`HWND`、`SDL_Window*` 等原生符号不出现在公共 API 上，它们由 `NativeHandle` 与 External 对象的生命周期隔离在 Backend 实现侧。该判据可执行：§47 第 6 条要求 Core 中不出现 libui / GTK / SDL / Win32 / Cocoa 等字样，CI 以一条 wasm job 验证——wasm 目标不提供 native FFI，编译通过即说明 Core 不依赖平台层。

## 快速开始

前置条件三项：MoonBit 工具链、**Node.js 22**（native 构建前的 `prebuild-link.js` 由它执行）、平台 C 编译器（Xcode CLT / MSVC / GTK4 开发包）。各平台的具体依赖与常见问题见 [docs/build-and-environment.md](docs/build-and-environment.md)。

```sh
moon check --deny-warn       # ① 类型与警告检查：快速确认环境配置正确
moon run examples/hello      # ② 无头 Demo：在终端打印事件与几何数据，不打开窗口
moon run examples/gallery    # ③ 组件画册的无头逐页输出
bash scripts/test-local.sh   # ④ 全量本地门禁：脚本先执行 moon clean，再运行 native + wasm 测试、无头 Demo 与格式检查；macOS / Windows 上另跑真窗口测试
```

运行真窗口示例（需手动关闭窗口后退出）：

```sh
moon run examples/gallery-native    # 组件画册
moon run examples/counter-native    # Counter：响应式绑定在原生后端工作
moon run examples/form-native       # Login：bind_input / bind_check 双向
moon run examples/todo-native       # Todo：for_list 键控 diff，行实例保留
moon run examples/tetris-native     # 俄罗斯方块帧率基准（右上角 FPS；TETRIS_BENCH_MS=5000 自动跑分）
```

所有 `moon` 命令须在仓库根目录执行——链接参数中的相对路径按当前工作目录展开；`scripts/test-local.sh` 会自行切换到仓库根。

## 平台支持

| 平台 | 后端 | 状态 |
| --- | --- | --- |
| Windows | Win32 直写（`backends/native-windows/adapter_native.c`） | 已接入；真窗口测试在本机与 CI 的 `windows-backend-link` 中运行 |
| macOS | Cocoa 直写（`backends/native-macos/adapter_native.m`） | 已接入；真窗口测试在本机与 CI 的 `macos-backend-link` 中运行 |
| Linux | GTK4 直写（`backends/native-linux/adapter_native_gtk.c`，由 `adapter.h` 生成 + 手写 `.inc`） | 已接入；真窗口与外部输入测试由 CI 的 `linux-backend-link` 运行。GTK4 4.6 未提供的 API 按契约显式缺席，逐条清单见 `TODO.md T235` |
| wasm | 无 | Core「不含任何 GUI 库」的可移植性闸门 |

另有自绘后端 `backends/canvas-macos`（Backend #3）：窗口与系统服务转发给原生后端，控件绘制以记账方式批处理，光栅器位于 macOS 的 C adapter 中（默认 CoreGraphics，Metal 为可选项）。平台分叉仅存在于三份 C adapter 与 `prebuild-link.js`；MoonBit 层共用 `backends/native-common/`，无按平台分叉的代码（分工定案见 `TODO.md T18`）。

## 能做什么

已实现的能力如下，均有测试覆盖：

| 层 | 内容 |
| --- | --- |
| Core 类型 | `UiError`、几何（逻辑 / 物理像素、`Scale`）、`Event`、`Style` / `Theme` |
| 布局 | Row / Column / Padding / Spacer / Center / Stack / Grid / Scroll |
| 生命周期 | `NativeHandle` + 句柄表（generation 防悬垂）、`App` 事件主循环 |
| 控件 | 0.1 阶段四种（Label / Button / TextInput / Checkbox）+ 0.2 阶段九种原生控件（PasswordInput / Separator / Slider / Spinbox / Progress / ComboBox / Multiline / RadioButtons / DatePicker）+ 八种组合组件（RadioGroup / Tabs / Steps / Alert / Card / Breadcrumb / Pagination / Rate） |
| 平台能力 | 剪贴板、对话框、文件面板、菜单栏 + 快捷键、`Backend` trait |
| 自定义绘制 | `Widget::custom(size, paint, focusable~=false)` + `DrawList`（14 条纯数据绘制命令）+ `PaintEnv` + `repaint()` |
| 无障碍 | Role / Label / Description / State / Actions 的推导与声明（§32） |
| 响应式（MVVM） | `Signal` / `computed` / `effect` / `watch` / `batch`；`bind_*` 单向九种 + `bind_input` / `bind_check` 双向；`Widget::reactive` 条件子树与 `Widget::for_list` 键控 diff。命令式 API 原样共存，见 [API.md §19](API.md#19-响应式mvvm) |
| 持久化 | 窗口存档（`WindowFrame`）、文件能力 `Fs`、设置档 `Settings` |
| 测试后端 | `MockBackend`：无头运行完整事件循环与布局数值 |

**住户控件**（`packages/widgets`，仅依赖 Core，因此在原生后端、自绘后端与 `MockBackend` 上行为一致）：

- **`ProgressRing`** —— 环形进度条，中心自动显示百分比。
- **`Sparkline`** —— 迷你折线图，自适应值域并支持滚动窗口；开启 `area~` 时填充为面积图。
- **`DataGrid`** —— 只读数据表：含表头、斑马纹与选中态，行与列均按视口虚拟化，固定列宽时可横向滚动；点击表头排序、拖拽重排、方向键 / `Home` / `End` / `PageUp` / `PageDown` 均已支持。
- **`TreeView`** —— 可折叠树：缩进、箭头、参考线与右对齐副文本，扁平化后按视口虚拟化，已支持纵向滚轮。

**示例**：五个经典 Demo（Hello / Counter / Login / Todo / File Manager）与三个 DX 示例（settings-center / markdown-editor / data-admin）的实现位于 `packages/moonui/`，`examples/` 仅作入口驱动；另有组件画册 Gallery 与一套完整应用 `examples/lunamusic*`（桌面音乐播放器）。入口分类与真窗口壳说明见 [examples/README.md](examples/README.md)。

## 目录

目录只列出实际存在的包，不为规划中的包预留空目录：

```text
packages/
  moonui/            Core：error / geometry / event / style / theme / handle / layout
                     widget / window / app / backend trait / clipboard / dialog
                     menu / shortcut / accessibility / reactive + MockBackend
                     + demo.mbt / demo_dx.mbt / gallery.mbt（Demo 实现，兼回归载体）
  moonui-app/        前台门（§47）：new_app() 以三步便捷构造直接返回 App[NativeBackend]
  widgets/           住户控件：ProgressRing / Sparkline / DataGrid / TreeView
  platform-services/ 可选平台能力（托盘 / 通知 / 媒体键 / 全局热键 / Now Playing）
  util/              稳定排序与文本工具（Core 依赖的叶包）
backends/
  native-common/     原生后端共享 MoonBit 层 + ABI 头 adapter.h
  native-abi/        零宿主纯函数包：ABI 编码 → Event 的判定表（可进 wasm 门）
  native-windows/    Win32 C adapter + 真窗口测试
  native-macos/      Cocoa C adapter + 真窗口测试
  native-linux/      GTK4 C adapter（生成物 + 手写 .inc）+ 真窗口测试
  canvas-common/     自绘配方与录制式判据（不渲染、不比位图，wasm 可测）
  canvas-macos/      自绘后端（Backend #3）：CoreGraphics 默认，Metal 可选
examples/            无头 Demo、真窗口壳、lunamusic 应用（见 examples/README.md）
tests/ffi/           §37 第二层：native FFI 探针（自包含 C stub）
scripts/             门禁与环境脚本（test-local.sh / ci-packages.sh / abi-symbols.sh 等）
docs/                后端笔记、构建排错、code-wiki
_doccheck/           README 示例的独立包验证
```

与 DESIGN §4 的清单有四处差异，均为权衡后的取舍：

- **`Backend` trait 保留在 Core，未单独成 `packages/backend/`。** trait 的方法签名需要 `NativeHandle`、`Event`、`LogicalSize` 等 Core 类型，`App[B : Backend]` 也以其为类型参数；若单独成包会形成相互依赖，而 MoonBit 的包不允许循环依赖。
- **`packages/widgets/` 目前只有四个控件。** 其余高阶控件（`CodeEditor` / `Terminal`）的键盘与 IME 支持尚未完成；该包只允许 import Core，不得依赖 `backends/`，`test-local.sh` 中有一道 grep 检查约束。
- **平台能力单独成包，不放在 Core。** 托盘 / 通知 / 媒体键 / 全局热键 / Now Playing 属于应用层需求，通用框架不在公开 API 中承诺 `set_now_playing(...)`；detlint 的 `core-platform-leak` 基线为 0。
- **Demo 代码保留在 `packages/moonui/`，`examples/` 仅作入口驱动。** Demo 同时承担框架回归职责；`examples/*` 只允许使用公开 API，公开 API 不足时应补充 API，而非绕过。

## API 示例

```moonbit
///|
fn build(app : @moonui.App[@moonui.MockBackend]) -> Unit raise @moonui.UiError {
  let backend = app.backend()
  let message = @moonui.Widget::label(backend, "Hello MoonUI")
  let button = @moonui.Widget::button(backend, "Click Me")
  let _ = button.on_click(fn() raise @moonui.UiError {
    message.set_text("Clicked!")
  })
  let window = app.create_window("MoonUI", @moonui.LogicalSize(800.0, 600.0))
  window.set_content(@moonui.Widget::column(backend, 16.0, [message, button]))
  window.show()
}
```

同一棵控件树的**响应式写法**——事件回调只改状态，文案与条件子树自动跟上（三层：`Signal` → `bind_*` → `Widget::reactive`）：

```moonbit
///|
fn reactive_counter(app : @moonui.App[@moonui.MockBackend]) -> Unit raise @moonui.UiError {
  let b = app.backend()
  // Layer 1：唯一的事实源
  let count = @moonui.Signal(0)
  // Layer 2：标签绑到状态上，不再手写 set_text
  let label = @moonui.Widget::label(b, "")
  let _ = label.bind_text_fmt(count, fn(c : Int32) { "\{c} 次" })
  // Layer 3：条件子树（依赖变才重建，父容器不动）
  let hint = @moonui.Widget::reactive(b, fn() raise @moonui.UiError {
    if count.get() > 0 {
      @moonui.Widget::label(b, "已经点过了")
    } else {
      @moonui.Widget::label(b, "还没点")
    }
  })
  // 事件回调只改状态
  let button = @moonui.Widget::button(b, "+1")
  let _ = button.on_click(fn() raise @moonui.UiError {
    count.update(fn(c) { c + 1 })
  })
  let window = app.create_window("Reactive", @moonui.LogicalSize(320.0, 200.0))
  window.set_content(@moonui.Widget::column(b, 8.0, [label, hint, button]))
  window.show()
}
```

两个示例都经过编译验证：`_doccheck/` 以独立包按原样编译，`packages/moonui/moonui_test.mbt` 中另有一条等价的黑盒测试（同一控件树，并附加点击断言）。键控列表（`Widget::for_list`，重排保留行实例）与 `Signal` / `computed` / `effect` / `watch` 的完整签名见 [API.md §19](API.md#19-响应式mvvm)。

`@moonui` 是由导入路径末段决定的默认别名。与 DESIGN §50 的期望形态有两处差异，均受当前工具链限制：`trait` 不是类型，也没有 `dyn`，因此后端在编译期随 `App[B]` 选定，构造控件时必须显式传入后端；`fn { }` 的无参写法已废弃。

### HUD：指标监听 + 置顶窗

两件事分开：`packages/moonui` 负责采集与监听（纯 Core、三端通用），`backends/native-common` 的 `NativeHud` 负责显示（Windows 真 layered 置顶窗，mac/linux 第一期返回 `None`）。时钟按项目惯例注入，Core 不自己读墙钟：

```moonbit
///|
fn hud_demo(app : @moonui.App[@moonui_app.NativeBackend]) -> Unit {
  // 1. 监听：500ms 一跳、值变了才回调
  app.set_hud_clock(fn() { @native-common.native_time_ms() })
  let _ = app.on_hud_metrics(500, fn(m) raise @moonui.UiError {
    println("FPS \{m.fps}, \{m.frame_ms} ms, \{m.draw_cmds} cmds")
    // 这里**不要**再 repaint：帧节拍每 16ms 已经重画过一次，HUD 回调再补一发
    // 就是同一帧两份 DrawList、两次 present。
  })
  // 2. 显示：独立的鼠标穿透置顶窗；坐标/尺寸是物理像素、屏幕坐标
  match @native-common.NativeHud::create(1480, 60, 210, 116) {
    Some(w) => {
      let m = app.hud_metrics()
      let _ = w.show_metrics(m, ["Level 3"])  // 可加任意自定义行
      w.close()
    }
    None => ()  // 平台未实现
  }
}
```

`NativeHud::move_to(x, y)` 可在主窗移动时同步 HUD 位置；HUD 窗自己不进主窗重绘账，因此不会把 HUD 的绘制成本混进被测 FPS。完整示例见 `examples/tetris-native`。

### 帧节拍：`post_animation` 与 60fps

动画/渲染循环用 **`post_animation`**，不要用 `post_every`。两者只差一件事，但差的是帧率上限：

| | 续期方式 | 真周期 |
| --- | --- | --- |
| `post_every` | `task` 返回**之后**再等 `interval` | 本拍耗时 + interval |
| `post_animation` | 按**绝对节拍**续期（`interval` 减去本拍已用） | 本拍耗时小于 interval 时就是 interval；超时则立刻接上 |

```moonbit
let ticker = @moonui.Ticker()
let _ = app.post_animation(ticker, 16, fn(_first) {
  face.repaint()   // 一帧一份 DrawList
  true
})
```

在 16ms 的预算里，`post_every` 的"干完再等 16ms"意味着 20ms 的一帧只能量出 27fps——画得再快也到不了 60。`post_animation` 把绘制耗时从间隔里扣掉，配上后端约 4ms 的绘制，实测稳定 61fps。

`examples/tetris-native` 是这条口径的基准：`TETRIS_BENCH_MS=5000 moon run examples/tetris-native` 跑 5 秒自动打印 `frames / avg fps / worst-window / paint ms / cmds` 并退出。本机 Win11 实测（三轮）**61.0~61.2fps、最差 500ms 窗口 60.5~60.9fps、单帧绘制 4.0ms（最大 6ms）**。

## 测试与 CI

按 §37 分为三层：

| 层 | 跑什么 | 证明什么 |
| --- | --- | --- |
| 第一层：Core + Mock | `moon test packages/moonui` | 布局数值、事件路由、生命周期与句柄回收，全部运行在 `MockBackend` 上，无需窗口 |
| 第二层：FFI 探针 | `moon test tests/ffi` | 自包含 C stub，不依赖外部 GUI 库，仅验证 MoonBit ↔ C 调用链是否连通 |
| 第三层：真后端 | `moon test backends/native-{macos,windows}`（Linux 由 CI 的 GTK 检查覆盖） | 真实打开窗口、布局摆放、点击菜单项、读写剪贴板、弹出原生对话框 / 文件面板、安装应用图标、关闭窗口并断言句柄表归零 |

测试条数随判据增删而变化，**一律以 `bash scripts/test-local.sh` 的输出为准**。第三层覆盖的具体判据见 [docs/backend-lessons.md](docs/backend-lessons.md)；macOS 已通过真窗口断言覆盖坐标点击、文本输入、勾选、按键、焦点切换（`T103`）与输入法组合相位（`T90`），Windows 侧已有脚手架，断言尚未补齐（`T103` 尾）。

CI（`.github/workflows/ci.yml`）共五个 job：

- `core`：在三个平台（ubuntu / macOS / Windows）运行 `check --deny-warn`、Core + Mock + 文档示例测试、无头 Demo、`moon info` / `fmt --check`、detlint、ABI 符号核对。
- `core-portability`：wasm 编译与测试，证明 Core 不含任何 GUI 库依赖（§47 第 6 条）。
- `macos-backend-link` / `windows-backend-link` / `linux-backend-link`：真后端链接，并运行本平台的真窗口 / GTK4 检查。

本地门禁在上述内容之外还会运行棘轮 lint、`abi-symbols.sh`、图标像素 A/B、Windows C 的 mingw 交叉语法检查，以及宿主专属的真窗口与 GTK4 检查；清单见 [docs/build-and-environment.md](docs/build-and-environment.md) 第 3 节。

CI 红了用 `gh run view <run-id> --log-failed` 取失败 step 的全文日志；`gh` 的安装、登录与完整命令见 [docs/github-cli.md](docs/github-cli.md)。

> CI 通过**不等于**真后端通过——`backends/` 被有意排除在 native 门禁之外（需要链接现场编译的库，且依赖人工操作窗口），本地必须另行运行真窗口测试。

**常见问题**（完整排错见 [docs/build-and-environment.md](docs/build-and-environment.md)）：

- `moon test` **必须带包清单**，除非显式指定本平台的真窗口测试。在仓库根直接执行不带清单的命令会链接 `backends/native-windows`，宿主非 Windows 时链接必然失败。包清单由 `scripts/ci-packages.sh` 生成。
- **修改平台 C adapter 后须先执行 `moon clean`**：moon 不将其视为 native 测试目标的输入，未清理时会使用旧二进制而误报通过（`T157`）。`test-local.sh` 已包含此步骤，手动单独运行测试时需自行执行。
- **Node.js 22**：缺失时 prebuild 不会被调用，症状为链接期大量缺失符号（`T234`）。
- **macOS 真窗口测试对鼠标操作与机器负载敏感**；锁屏状态下 `T110` / `T129` / `T210` 必定失败（`T238`），解锁后同一命令全部通过。不应为此修改判据或增加重试机制。
- **Windows 上使用 git-bash**，且 MSVC 的 bin 目录须位于 PATH 前部（否则 Git 自带的 `link.exe` 会优先被调用）。

## 工程约定

- 公共 API 一律使用逻辑像素，物理换算只发生在 `Scale` 中（§30）。macOS 的第二道换算整段位于 C 侧、仅有一处；y 轴方向通过视图 `isFlipped` 统一，不单独翻转。
- `CanvasPainter` 的逻辑→物理取整只有一条算式：`(v * scale + 0.5).floor()`（`T232` 裁决）。`.5` 处正负**有意不对称**（`3.5 → 4`、`-3.5 → -3`、`-0.5 → 0`）；改为对称取整属于修改约定，须先补充能观测负 `.5` 的判据。
- 样式由 Core 层叠（Theme → 父容器 → 自身），在 `Window::relayout` 中先下发至叶子、再测量：顺序颠倒会以旧字号的度量排布新矩形。原生控件后端有权完全不读取它——§32 要保留系统原生外观。
- Core 不缓存窗口与控件状态，原生层是唯一事实来源；例外仅有 min/max 约束、菜单勾选状态和快捷键表。
- 纯布局节点不占原生对象，叶子的原生父级只有窗口（§14）。
- 事件优先：`on_click` 只是 `Event::Click` 的过滤封装，路由与派发统一在 `App` 中完成（§10）。
- 无障碍视图是推导出来的，不另维护一份名册：Actions 来自事件订阅，State 来自原生层；纯布局节点只有显式声明 Role 才进入视图（§32）。

## 深入资料

- 后端实现要点与真窗口验证记录：[docs/backend-lessons.md](docs/backend-lessons.md)
- 构建链、平台准备与环境排错：[docs/build-and-environment.md](docs/build-and-environment.md)
- GitHub CLI（`gh`）安装、登录与查 CI 日志：[docs/github-cli.md](docs/github-cli.md)
- 代码级导读：[docs/code-wiki](docs/code-wiki/README.md)
- 设计文档：[DESIGN.md](DESIGN.md)（§48 是当前进度轴）
- 全量 API：[API.md](API.md)
- 待办与协作规则：[TODO.md](TODO.md) / [AGENTS.md](AGENTS.md)
- 所有待办一律记录在 TODO.md：每条带永久编号与日期、引用 §48 步骤号、写明当前实际状态；完成后满一个月即删除（git 历史即归档），未完成项不限保留时长。
- MoonBit 侧的写法约定、`moon info` / `moon fmt` / `moon test` 的收尾顺序见 AGENTS.md。

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。（`T82` 之前曾 vendored libui-ng，未入库，遵循其自身的 MIT 许可；`examples/lunamusic-tag` vendored 了 moontag，同为 Apache-2.0。）
