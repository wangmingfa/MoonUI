# MoonUI

MoonBit 的桌面 GUI 框架。布局、事件、控件、样式、主题、HiDPI 与无障碍视图都在**后端无关的 Core** 里实现；平台差异留在 Backend 实现侧——macOS 直写 AppKit、Windows 直写 Win32、Linux 直写 GTK4。同一份应用代码换后端不用改。

> MoonBit API 是第一公民，C 只是实现手段，Backend 永远不能反向决定 MoonUI 的 API。

**0.1.0** · Apache-2.0 · Windows / macOS / Linux(GTK4) 原生后端 · wasm 可移植性闸门

| 文档 | 内容 |
| --- | --- |
| [DESIGN.md](DESIGN.md) | 设计文档（53 节 + 附录）；代码里的 `§nn` 都指向它 |
| [API.md](API.md) | 全量公开 API 中文参考（响应式在 §19） |
| [TODO.md](TODO.md) | 全部待办与完成记录，按 `Tnn` 编号 |
| [AGENTS.md](AGENTS.md) | 工程约定与接力规矩（最短的一份） |
| [docs/backend-lessons.md](docs/backend-lessons.md) | 后端踩坑与真窗口逐条验证 |
| [docs/build-and-environment.md](docs/build-and-environment.md) | 构建链前置、平台准备、环境排错 |
| [docs/code-wiki](docs/code-wiki/README.md) | 代码级导读（2026-10-21 基线，非权威来源） |

**建议阅读顺序**：AGENTS.md → 本页的「它是什么」「目录」→ DESIGN.md §14（布局）/ §10（事件）/ §48（路线图）→ API.md（查具体 API）→ TODO.md（挑活）。提改动前跑一遍 `moon info && moon fmt`，`pkg.generated.mbti` 跟着代码一起提交。

## 它是什么，不是什么

**是框架**：Core 拥有布局算法、事件路由、句柄生命周期、样式与主题的层叠、无障碍视图的推导；后端只负责把算好的矩形和属性写进原生层，并把原生事件送回 `App`。

**不是绑定**：`uiButton*`、`HWND`、`SDL_Window*` 这类东西不出现在公共 API 上，它们被 `NativeHandle` 和 External 对象的生命周期挡在 Backend 实现侧。判据是可执行的：§47 第 6 条要求 Core 里绝不出现 libui / GTK / SDL / Win32 / Cocoa 这些字样，CI 用一条 wasm job 证明它（wasm 上根本没有 native FFI，能编译就说明这一层干净）。

## 快速开始

前置三样：MoonBit 工具链、**Node.js 22**（native 构建前的 `prebuild-link.js` 由它执行）、平台 C 编译器（Xcode CLT / MSVC / GTK4 开发包）。各平台的具体依赖与常见坑见 [docs/build-and-environment.md](docs/build-and-environment.md)。

```sh
moon check --deny-warn       # ① 类型与警告闸门：最快确认环境对了
moon run examples/hello      # ② 无头 Demo：终端打印事件与几何，不开窗口
moon run examples/gallery    # ③ 画册的逐页打印版
bash scripts/test-local.sh   # ④ 全量本地门禁：脚本自己先 moon clean，再跑 native + wasm + Demo + 格式；macOS / Windows 上再跑真窗口测试
```

想看真窗口（要真人关窗口才退出）：

```sh
moon run examples/gallery-native
```

所有 `moon` 命令都在仓库根跑——链接参数里的相对路径按当前工作目录展开；`scripts/test-local.sh` 自己会 `cd` 到根。

## 平台支持

| 平台 | 后端 | 状态 |
| --- | --- | --- |
| Windows | Win32 直写（`backends/native-windows/adapter_native.c`） | 已接；真窗口测试由本机与 CI 的 `windows-backend-link` 跑 |
| macOS | Cocoa 直写（`backends/native-macos/adapter_native.m`） | 已接；真窗口测试由本机与 CI 的 `macos-backend-link` 跑 |
| Linux | GTK4 直写（`backends/native-linux/adapter_native_gtk.c`，由 `adapter.h` 生成 + 手写 `.inc`） | 已接；真窗口与外部输入由 CI 的 `linux-backend-link` 跑。GTK4 4.6 没有的 API 按契约显式缺席，逐条账见 `TODO.md T235` |
| wasm | 无 | Core「不含任何 GUI 库」的可移植性闸门 |

另有一个自绘后端 `backends/canvas-macos`（Backend #3）：窗口与系统服务转发给原生后端，控件批改走记账，光栅器在 mac 的 C adapter 里（默认 CoreGraphics，Metal 是 opt-in）。平台分叉只落在三份 C adapter 和 `prebuild-link.js` 里；MoonBit 层共用 `backends/native-common/`，没有按平台分叉的代码（分工定案见 `TODO.md T18`）。

## 能做什么

能力面如下，全部有测试覆盖：

| 层 | 内容 |
| --- | --- |
| Core 类型 | `UiError`、几何（逻辑 / 物理像素、`Scale`）、`Event`、`Style` / `Theme` |
| 布局 | Row / Column / Padding / Spacer / Center / Stack / Grid / Scroll |
| 生命周期 | `NativeHandle` + 句柄表（generation 防悬垂）、`App` 事件主循环 |
| 控件 | 0.1 四件（Label / Button / TextInput / Checkbox）+ 0.2 九种原生控件（PasswordInput / Separator / Slider / Spinbox / Progress / ComboBox / Multiline / RadioButtons / DatePicker）+ 八个组合组件（RadioGroup / Tabs / Steps / Alert / Card / Breadcrumb / Pagination / Rate） |
| 平台能力 | 剪贴板、对话框、文件面板、菜单栏 + 快捷键、`Backend` trait |
| 自定义绘制 | `Widget::custom(size, paint, focusable~=false)` + `DrawList`（14 条纯数据绘制命令）+ `PaintEnv` + `repaint()` |
| 无障碍 | Role / Label / Description / State / Actions 的推导与声明（§32） |
| 响应式（MVVM） | `Signal` / `computed` / `effect` / `watch` / `batch`；`bind_*` 单向九种 + `bind_input` / `bind_check` 双向；`Widget::reactive` 条件子树与 `Widget::for_list` 键控 diff。命令式 API 原样共存，见 [API.md §19](API.md#19-响应式mvvm) |
| 持久化 | 窗口存档（`WindowFrame`）、文件能力 `Fs`、设置档 `Settings` |
| 测试后端 | `MockBackend`：无头跑完整事件循环与布局数值 |

**住户控件**（`packages/widgets`，只 import Core，所以原生后端 / 自绘后端 / mock 上同一份配方）：

- **`ProgressRing`** —— 环形进度，中心自动百分比。
- **`Sparkline`** —— 迷你折线，自适应值域 + 滚动窗口；`area~` 打开时填成面积图。
- **`DataGrid`** —— 只读数据表：表头 + 斑马 + 选中，行列都按视口虚拟化，固定宽可横向滚动；点表头排序、拖拽重排、方向键 / `Home` / `End` / `PageUp` / `PageDown` 均已接线。
- **`TreeView`** —— 可折叠树：缩进 + 箭头 + 参考线 + 右对齐副文案，扁平化后按视口虚拟化，纵向滚轮已接线。

**示例**：五个经典 Demo（Hello / Counter / Login / Todo / File Manager）与三个 DX 示例（settings-center / markdown-editor / data-admin）本体在 `packages/moonui/`，`examples/` 只做驱动；另有组件画册 Gallery 与一套真实应用 `examples/lunamusic*`（桌面音乐播放器）。入口分类与真窗口壳见 [examples/README.md](examples/README.md)。

## 目录

只有已经存在的东西才有目录，没建的不留空壳：

```text
packages/
  moonui/            Core：error / geometry / event / style / theme / handle / layout
                     widget / window / app / backend trait / clipboard / dialog
                     menu / shortcut / accessibility / reactive + MockBackend
                     + demo.mbt / demo_dx.mbt / gallery.mbt（Demo 本体，回归载体）
  moonui-app/        前台门（§47）：new_app() 三步糖直接返回 App[NativeBackend]
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
  canvas-macos/      自绘后端（Backend #3）：CG 默认，Metal opt-in
examples/            无头 Demo、真窗口壳、lunamusic 应用（见 examples/README.md）
tests/ffi/           §37 第二层：native FFI 探针（自包含 C stub）
scripts/             门禁与环境脚本（test-local.sh / ci-packages.sh / abi-symbols.sh 等）
docs/                后端笔记、构建排错、code-wiki
_doccheck/           README 示例的独立包验证
```

和 DESIGN §4 的清单有四处不一致，都是权衡之后留下的：

- **`Backend` trait 留在 Core，没有单独的 `packages/backend/`。** trait 的方法签名要用 `NativeHandle`、`Event`、`LogicalSize` 这些 Core 类型，`App[B : Backend]` 也要用它当类型参数；单独成包就变成相互依赖，而 MoonBit 的包不允许成环。
- **`packages/widgets/` 只有四个住户。** 其余高阶控件（`CodeEditor` / `Terminal`）仍欠键盘与 IME 的账；这个包只许 import Core，不许碰 `backends/`，`test-local.sh` 有一道 grep 闸门钉着。
- **平台能力单独成包，不放在 Core。** 托盘 / 通知 / 媒体键 / 全局热键 / Now Playing 是应用需求，通用框架不在公开面里承诺 `set_now_playing(...)`；detlint `core-platform-leak` 基线 0 钉住。
- **Demo 代码留在 `packages/moonui/`，`examples/` 只做驱动。** Demo 同时是框架的回归载体；`examples/*` 反过来只准用公开 API，公开 API 不够用就是该补 API 的信号。

## API 长什么样

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

这段是编译过的：`_doccheck/` 用独立包按原样编译它，`packages/moonui/moonui_test.mbt` 有一条等价的黑盒测试（同一棵树，另加点击断言）。同一棵树的响应式写法（`Signal` + `bind_text_fmt` + `Widget::for_list`）见 [API.md §19](API.md#19-响应式mvvm)。

`@moonui` 是导入路径末段决定的默认别名。与 DESIGN §50 的期望形态差两处，都是当前工具链逼出来的：`trait` 不是类型、也没有 `dyn`，所以后端在编译期随 `App[B]` 选定，构造控件必须显式交后端；`fn { }` 的无参写法已废弃。

## 测试与 CI

§37 三层：

| 层 | 跑什么 | 证明什么 |
| --- | --- | --- |
| 第一层：Core + Mock | `moon test packages/moonui` | 布局数值、事件路由、生命周期与句柄回收，全在 `MockBackend` 上，无头 |
| 第二层：FFI 探针 | `moon test tests/ffi` | 自包含 C stub，不依赖外部 GUI 库，只验 MoonBit ↔ C 能不能通 |
| 第三层：真后端 | `moon test backends/native-{macos,windows}`（Linux 由 CI 的 GTK 闸） | 真开窗口、真摆放、真点菜单项、真读写剪贴板、真弹原生对话框 / 文件面板、真装应用图标、真关闭并断言句柄表归零 |

「条数」随判据增删变化，**一律以 `bash scripts/test-local.sh` 的输出为准**。第三层逐条钉了什么见 [docs/backend-lessons.md](docs/backend-lessons.md)；macOS 已用真窗断言覆盖按坐标点击、打字、勾选、按键、改焦点（`T103`）与输入法组合相位（`T90`），Windows 侧脚手架在、断言仍欠（`T103` 尾）。

CI（`.github/workflows/ci.yml`）五个 job：

- `core`：三平台（ubuntu / macOS / Windows）跑 `check --deny-warn`、Core + Mock + 文档示例测试、无头 Demo、`moon info` / `fmt --check`、detlint、ABI 符号核对。
- `core-portability`：wasm 编译与测试，证明 Core 不含任何 GUI 库依赖（§47 第 6 条）。
- `macos-backend-link` / `windows-backend-link` / `linux-backend-link`：真后端链接，并跑本平台的真窗口 / GTK4 闸。

本地门禁除上述内容外还跑棘轮 lint、`abi-symbols.sh`、图标像素 A/B、Windows C 的 mingw 交叉语法闸，以及宿主专属的真窗与 GTK 闸；清单见 [docs/build-and-environment.md](docs/build-and-environment.md) 第 3 节。

> CI 绿**不等于**真后端绿——`backends/` 在 native 门禁里被有意排除（要链接现编的库、还要一只会点鼠标的手），本地必须跑真窗口测试。

**几条最容易踩的**（完整排错见 [docs/build-and-environment.md](docs/build-and-environment.md)）：

- `moon test` **要带包清单**，除非点名本平台那批真窗口测试。仓库根那条裸命令会去链接 `backends/native-windows`，宿主不是 Windows 时链接必红。清单由 `scripts/ci-packages.sh` 给出。
- **改过平台 C adapter 后先 `moon clean`**：moon 不把它算成 native 测试目标的输入，不 clean 会拿旧二进制报绿（`T157`）。`test-local.sh` 已内置，手动单跑时自己来。
- **Node 22**：缺了它 prebuild 根本不会被调起，症状是链接期一堆缺符号（`T234`）。
- **macOS 真窗测试怕真鼠标、也怕机器忙**；锁屏会让 `T110` / `T129` / `T210` 必红（`T238`），解锁后同一条命令全绿。别为此改判据或加重试护栏。
- **Windows 用 git-bash**，且 MSVC 的 bin 要排在 PATH 前头（否则 Git 自带的 `link.exe` 会抢先）。

## 工程约定

- 公共 API 一律逻辑像素，物理换算只发生在 `Scale` 里（§30）。macOS 的第二道换算整段在 C 侧、只有一处；y 轴方向靠视图 `isFlipped` 统一，不单独翻转。
- `CanvasPainter` 的逻辑→物理取整只有一条算式：`(v * scale + 0.5).floor()`（`T232` 裁决）。`.5` 处正负**有意不对称**（`3.5 → 4`、`-3.5 → -3`、`-0.5 → 0`）；改成对称属于改约定，须先补能观测负 `.5` 的判据。
- 样式由 Core 层叠（Theme → 父容器 → 自身），在 `Window::relayout` 里先下发给叶子、再测量：顺序反了会拿旧字号的度量排新矩形。原生控件后端有权完全不读它——§32 要保住系统原生外观。
- Core 不缓存窗口与控件状态，原生层是唯一事实来源；例外只有 min/max 约束、菜单勾选状态和快捷键表。
- 纯布局节点不占原生对象，叶子的原生父级只有窗口（§14）。
- 事件优先：`on_click` 只是 `Event::Click` 的过滤器糖，路由与派发在 `App` 一处完成（§10）。
- 无障碍视图是推导出来的，不是另登一份名册：Actions 来自事件订阅，State 来自原生层；纯布局节点只有显式声明 Role 才进视图（§32）。

## 深入资料

- 后端踩坑与真窗口逐条验证：[docs/backend-lessons.md](docs/backend-lessons.md)
- 构建链、平台准备与环境排错：[docs/build-and-environment.md](docs/build-and-environment.md)
- 代码级导读：[docs/code-wiki](docs/code-wiki/README.md)
- 设计文档：[DESIGN.md](DESIGN.md)（§48 是当前进度轴）
- 全量 API：[API.md](API.md)
- 待办与接力规矩：[TODO.md](TODO.md) / [AGENTS.md](AGENTS.md)
- 待办一律进 TODO.md：每条带永久编号与日期、引 §48 步骤号、写清「现在什么是真的」；完成满一个月就删（git log 是档案），未完成的多久都留着。
- MoonBit 侧写法约定、`moon info` / `moon fmt` / `moon test` 的收尾顺序在 AGENTS.md。

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。（`T82` 前曾 vendored libui-ng，不入库，遵循它自己的 MIT 许可。`examples/lunamusic-tag` vendored 了 moontag，同样 Apache-2.0。）
