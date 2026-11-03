# MoonUI

MoonBit 的 GUI 框架。目标不是"某个 C GUI 库的 MoonBit 绑定"，而是让 MoonBit 能写桌面应用的那层框架：布局、事件、控件、主题、HiDPI、菜单与对话框都在 Core 里定义，平台原生 API 的差异留在 Backend 实现侧（macOS 直写 AppKit、Windows 直写 Win32）。

> MoonBit API 是第一公民，C 只是实现手段，Backend 永远不能反向决定 MoonUI 的 API。

| | |
| --- | --- |
| 版本 | 0.1.0（后端无关的第一层已交付，真后端有 Windows 与 macOS） |
| 工具链 | moon 0.1.20261028，`preferred_target = "native"` |
| 测试 | native 566 条 + wasm 571 条 + 真窗口 macOS 65 条（Cocoa）+ Windows 47 条（Win32），本机一条 `bash scripts/test-local.sh` |
| CI | `.github/workflows/ci.yml` 四个 job：`core` / `core-portability` / `macos-backend-link` / `windows-backend-link` |
| 许可 | Apache-2.0 |
| 设计文档 | [DESIGN.md](DESIGN.md)：52 节 + 附录。`§14`、`§48-09~11` 这类引用全按它的小节号，编号不要重排 |
| API 文档 | [API.md](API.md)：全量公开 API 的中文参考 |
| 待办 | 全部记在 [TODO.md](TODO.md)，接力规矩在 [AGENTS.md](AGENTS.md) |

## 它是什么，不是什么

是**框架**：Core 拥有布局算法、事件路由、句柄生命周期、样式与主题的层叠、无障碍视图的推导；后端只负责把算好的矩形和属性写进原生层，并把原生事件送回 `App`。

不是**绑定**：`uiButton*`、`HWND`、`SDL_Window*` 这类东西不出现在公共 API 上，它们被 `NativeHandle` 和 External 对象的生命周期挡在 Backend 实现侧。判据是可执行的——§47 第 6 条要求 Core 里绝不出现 libui / GTK / SDL / Win32 / Cocoa 这些字样，CI 用一条 wasm job 证明它（wasm 上根本没有 native FFI，能编译就说明这一层干净）。

## 跑起来

**前置**：

1. [MoonBit 工具链](https://docs.moonbitlang.com)——macOS/Linux 用 `curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash`，Windows 用官方 PowerShell 脚本。
2. **node**（任何较新版本）。仓库根 `prebuild-link.js` 在每次 native 构建前由 moon 调起，按宿主注入链接参数并现编平台 C adapter；PATH 里没有 node 时 native 链接这步会红。
3. 平台编译器：macOS 的 Xcode 命令行工具（`xcode-select --install`）；Windows 的 MSVC + vcvars。

**四步跑通**（全部在仓库根跑——链接参数里的相对路径按当前工作目录展开）：

```sh
moon check --deny-warn       # ① 类型与警告闸门，最快确认环境对了
moon run examples/hello      # ② 无头 Demo：终端打印事件与几何，不开窗口
moon run examples/gallery    # ③ 画册的逐页打印版（真窗口版是 examples/gallery-native）
bash scripts/test-local.sh   # ④ 全量门禁：native + wasm + Demo + 格式，本机是 macOS/Windows 时再跑真窗口测试
```

**想看真窗口**：

```sh
moon run examples/gallery-native   # 左栏选组件、右栏看效果，关窗口退出
```

**阅读顺序**：AGENTS.md（工程约定，最短）→ 本 README 的「它是什么，不是什么」与「目录」→ [DESIGN.md](DESIGN.md) 的 §14（布局）、§10（事件）、§48（路线图）→ [API.md](API.md)（查具体 API）→ TODO.md（挑活）。提改动前跑一遍 `moon info && moon fmt`，`pkg.generated.mbti` 跟着代码一起提交。

## 每个系统上分别跑什么

MoonBit 那几层三平台是同一份代码，差别只有一格：**能不能链接真后端**。

| 想做的事 | Windows | macOS | Linux |
| --- | --- | --- | --- |
| 本地门禁，一条命令跑完 | `bash scripts/test-local.sh` | 同左 | 同左（到类型闸门为止） |
| 备真后端的依赖 | 什么都不用备：平台 C 由 prebuild 首次 `moon build` 时用本机 MSVC 现编 | 同左（clang 由 Xcode 命令行工具提供） | 还没有这条路 |
| 无头测试（Core + MockBackend） | `moon test $(bash scripts/ci-packages.sh packages examples tests _doccheck)` | 同左 | 同左 |
| wasm 那一层（§47 第 6 条的证明） | `moon test --target wasm $(bash scripts/ci-packages.sh packages examples tests backends _doccheck)` | 同左 | 同左 |
| 类型闸门，含 native only 的包 | `moon check --deny-warn` | 同左 | 同左 |
| 接口与格式收尾 | `moon info && moon fmt`，然后提交 `.mbti` | 同左 | 同左 |
| 真窗口的测试 | `moon test backends/native-windows`（47 条） | `moon test backends/native-macos`（64 条） | 跑不了 |
| 真窗口的 Demo | `moon run examples/gallery-native` | 同左 | 跑不了 |

五条会咬人的细节：

- **`moon test` 要带包清单**，除非点名本平台那批真窗口测试。仓库根那条裸命令会去链接 `backends/native-windows` 的测试二进制，而它那批 `moonui_native_*` 符号只有 prebuild 现编的 Win32 adapter 提供——宿主不是 Windows 时链接必红。`moon check` / `moon info` 不链接、也不编 C，所以真后端的类型闸门在三平台都跑得动。
- **所有 `moon` 命令都在仓库根跑**。`scripts/test-local.sh` 自己 `cd` 到根，从哪儿调用都可以。
- **macOS 真窗口测试怕真鼠标、也怕机器忙**：测试期间 owner 动了鼠标会让个别用例假红；`T101`（自绘像素）与 `T152`（定时投递）两条对负载敏感（记在 TODO.md），偶发红先重跑再判定。
- **Windows 上那个 bash 是 git-bash**：脚本认 `uname -s` 的 `MINGW*` / `MSYS*` / `CYGWIN*` / `Windows_NT`，用纯 PowerShell 时按表逐条手敲。
- **Windows 侧编真后端要把 MSVC 的 bin 排到 PATH 前头**（开过 vcvars 就天然满足）。原因是 Git for Windows 附带的 coreutils `link.exe` 会抢在 MSVC 链接器前面。

`scripts/test-local.sh` 除了上表那些，还会：在 macOS / Linux 上若 PATH 里有 `x86_64-w64-mingw32-gcc`，用它把 `backends/native-windows/adapter_native.c` 过一遍 `-fsyntax-only -Wall -Werror`（第一次用就抓到不存在的 `MF_RADIOCHECK`，正确拼写是 `MFT_RADIOCHECK`）；跑 `scripts/abi-symbols.sh` 核对 195 个 `extern "c"` 符号名在本平台 adapter 里真的被定义（`T145`）；跑 `scripts/detlint.sh` 的棘轮计数（`T144`）；以及一道 grep 闸门钉住 `packages/widgets` 只许 import Core、不许碰 `backends/`。

## 现在能用什么

0.1 阶段交付的是**后端无关的第一层**，全部有测试覆盖：

| 层 | 内容 |
| --- | --- |
| Core 类型 | `UiError`、几何（逻辑/物理像素、`Scale`）、`Event`、`Style`/`Theme` |
| 布局 | Row / Column / Padding / Spacer / Center / Stack / Grid / Scroll |
| 生命周期 | `NativeHandle` + 句柄表（generation 防悬垂）、`App` 事件主循环 |
| 控件 | 0.1 四件（Label / Button / TextInput / Checkbox）+ 0.2 九种原生控件（PasswordInput / Separator / Slider / Spinbox / Progress / ComboBox / Multiline / RadioButtons / DatePicker）+ 八个组合组件（RadioGroup / Tabs / Steps / Alert / Card / Breadcrumb / Pagination / Rate，纯 MoonBit 拼装） |
| 平台能力接口 | 剪贴板、对话框、菜单栏 + 快捷键、`Backend` trait |
| 自定义绘制 | `Widget::custom(size, paint, focusable~=false)` + `DrawList`（14 条纯数据绘制命令）+ `PaintEnv` + `repaint()`。清单是控件局部逻辑像素，重放与逻辑→物理换算归后端。`focusable=true` 是键盘焦点的 opt-in，默认关 |
| 无障碍视图 | Role / Label / Description / State / Actions 的推导与声明（§32） |
| 测试后端 | `MockBackend`：无头跑完整事件循环与布局数值 |

**住户控件**（`packages/widgets`，只 import Core，所以原生后端 / 自绘后端 / mock 上同一份配方）：

- **`ProgressRing`** —— 环形进度，中心自动百分比。
- **`Sparkline`** —— 迷你折线，自适应值域 + 滚动窗口；`area~` 打开时折线下方填成闭合多边形（面积图）。
- **`DataGrid`** —— 只读数据表。固定列宽或自然宽自适应，表头 + 斑马 + 选中，行列都按视口虚拟化，固定宽模式下可横向滚动。已接线：点表头排序（同列再点翻方向；数字列声明 `numeric` 后按数值排；排序稳定且不改动数据行号）、滚轮、按住正文行拖拽重排、方向键 / `Home` / `End` / `PageUp` / `PageDown` 移动与翻页。公开 API 的行号一律指数据行号。
- **`TreeView`** —— 可折叠树。缩进 + 箭头 + 参考线 + 右对齐副文案，用 `TreeNode` 扁平化后按视口虚拟化，纵向滚轮已接线。

**示例**：§49 的五个经典 Demo（Hello / Counter / Login / Todo / File Manager）本体在 `packages/moonui/demo.mbt`，加组件画册 Gallery；另有三个 DX 示例 settings-center / markdown-editor / data-admin，以及一套真实应用 `examples/lunamusic*`（桌面音乐播放器）。全部示例共用 `assets/logo/` 里的 MoonUI logo 当应用图标。

## 目录

§4 建议的结构里，只有已经存在的东西才有目录，没建的不留空壳：

```text
packages/
  moonui/      Core：error / geometry / event / style / theme / handle / layout
               widget / window / app / backend trait / clipboard / dialog
               menu / shortcut / accessibility + MockBackend
               + demo.mbt / demo_dx.mbt / gallery.mbt（§49 Demo 本体，回归载体）
  moonui-app/  前台门（§47 注记）：new_app() 三步糖直接返回 App[NativeBackend]，
               用户从此不 import 后端包
  widgets/     住户控件：ProgressRing / Sparkline / DataGrid / TreeView
backends/
  native-common/    原生后端的共享 MoonBit 层（ffi.mbt + backend.mbt + canvas.mbt
                    + painter.mbt）+ ABI 头 adapter.h。两平台共用，无 C、无 link
  native-abi/       零宿主的纯函数包：ABI 编码 → Event 的判定表（鼠标 / 手势 /
                    滑向 / 走包解码），可进 wasm 门
  native-windows/   Windows 半：Win32 直写的 C Adapter + 47 条真窗口测试
  native-macos/     macOS 半：Cocoa 直写的 C Adapter + 64 条真窗口测试
  canvas-common/    自绘后端的绘制配方与录制式判据（不渲染、不比位图，wasm 可测）
  canvas-macos/     自绘后端本体（Backend #3）：窗口与系统服务转发给原生后端，
                    控件批改走记账；光栅器（CG / Metal 两档）住在 native-macos 的
                    C adapter 里（`T190`）
examples/
  common/           示例共用件
  无头可执行包（MockBackend，任何平台含 wasm 都能跑）：
    hello counter form todo file-manager gallery
    settings-center markdown-editor data-admin
  应用本体库包（无 main，被壳引用）：
    lunamusic/          桌面音乐播放器本体
    lunamusic-shell/    壳 + 真音频 / 目录扫描适配
    lunamusic-tag/      音频标签解析（ID3 / FLAC / mp4；部分 vendored 自 moontag，
                        同为 Apache-2.0，见该目录 LICENSE）
  真窗口可执行包（链接现编的平台 C）：
    gallery-native interact-native render-backend-native
    hello-canvas-native lunamusic-canvas-native lunamusic-native
tests/ffi/    §37 第二层：native FFI 探针（自包含 C stub，不依赖外部库）
scripts/      ci-packages.sh（core 与 core-portability 共用的门禁清单）
              test-local.sh（本地一条命令的门禁，按宿主分叉）
              abi-symbols.sh / detlint.sh / stress-cpu.sh / screenshot-window.sh
docs/         backend-lessons.md（后端踩坑与真窗口逐条验证）
              code-wiki/ + 若干调研笔记
_doccheck/    README 那段代码的独立包验证
```

和 §4 的清单有三处不一致，都是权衡之后留下的：

- **`Backend` trait 留在 Core，没有单独的 `packages/backend/`。** trait 的方法签名要用 `NativeHandle`、`Event`、`LogicalSize` 这些 Core 类型，`App[B : Backend]` 也要用它当类型参数；trait 单独成包就变成 moonui ↔ backend 互相依赖，而 MoonBit 的包不允许成环。
- **`packages/widgets/` 只有四个住户。** §4 里其余高阶控件（`CodeEditor` / `Terminal`）仍在 TODO：要键盘与 IME 的余账。这个包**只许 import Core 与标准库**，不许碰任何 `backends/`——`scripts/test-local.sh` 开头有一道 grep 闸门钉着。
- **Demo 的代码留在 `packages/moonui/`，`examples/` 只做驱动。** Demo 在这里同时是框架的回归载体：布局数值、句柄回收、事件派发都要拿一棵真实的树来断言，放进 `examples/` 就只能变成"跑过但没验证"。`examples/*` 反过来只准用公开 API，公开 API 不够用就是该补 API 的信号。

## API 长什么样

```moonbit nocheck
///|
fn build(app : @moonui.App[@moonui.MockBackend]) -> Unit raise @moonui.UiError {
  let backend = app.backend()
  let message = @moonui.Widget::label(backend, "Hello MoonUI")
  let button = @moonui.Widget::button(backend, "Click Me")
  let _ = button.on_click(fn() raise @moonui.UiError {
    message.set_text("Clicked!")
  })
  let window = app.create_window("MoonUI", @moonui.LogicalSize::{
    width: 800.0,
    height: 600.0,
  })
  window.set_content(@moonui.Widget::column(backend, 16.0, [message, button]))
  window.show()
}
```

这段是编译过的：`packages/moonui/moonui_test.mbt` 里有一条 blackbox 测试按原样跑它，`_doccheck/` 是同一份代码的独立包验证。`@moonui` 是导入路径末段决定的默认别名。与设计文档 §50 的期望形态差两处，都是当前工具链逼出来的：`trait` 不是类型、也没有 `dyn`，所以后端在编译期随 `App[B]` 选定，构造控件必须显式交后端；`fn { }` 的无参写法已废弃。

## 测试怎么分层

§37 三层的前两层进 CI 的 `core` job；第三层自 2026-10-14（`T6`）起 mac 侧是**链接加真跑**，Windows 侧自 2026-10-22（`T78`）起同形。仍只能本地跑的只剩真窗口 Demo：它们要真人关窗口才退出。

| 层 | 跑什么 | 证明什么 |
| --- | --- | --- |
| 第一层：Core + Mock | `moon test packages/moonui` | 布局数值、事件路由、生命周期与句柄回收，全在 `MockBackend` 上，无头 |
| 第二层：FFI 探针 | `moon test tests/ffi` | 自包含 C stub，不依赖任何外部 GUI 库，只验 MoonBit ↔ C 这一对能不能通 |
| 第三层：真后端 | `moon test backends/native-{macos,windows}` | 真开窗口、真摆放、真点菜单项、真读写剪贴板、真弹原生对话框与文件面板、真装应用图标、真关闭并断言句柄表归零；控件属性往返与画布绘制各在各自那半 |

第三层逐条钉了什么见 [`docs/backend-lessons.md`](docs/backend-lessons.md)。**覆盖到哪一侧**：按坐标点击、打字、勾选、按键、改焦点五项在 macOS 已由真窗断言钉住（`T103`），输入法组合相位也在 mac 真跑（`T90`）；Windows 侧脚手架在、断言仍欠（`T103` 尾）。建窗时按所在屏量一次工作区并居中、重排时读一次系统外观——这两条是代码路径真跑，但没有单独断言。

另外两类不属于 §37 的分层，但同样在闸门里：`examples/*` 和 `_doccheck` 只用公开 API，公开 API 不够用就是该补 API 的信号；`moon test --target wasm` 证明 Core 与第一/第二层不含任何 GUI 库依赖（§47 第 6 条）。

## 平台支持

| 平台 | 后端 | 状态 |
| --- | --- | --- |
| Windows | 原生 API（Win32 直写，`adapter_native.c`） | 已接。§48-03/09~11/15、§48-13、§48-16 键盘与焦点、§48-18/19/20、§16 系统外观、§48-21 缩放、§12 按窗口工作区、§30 鼠标五变体均真跑绿，47 条真窗口测试 |
| macOS | 原生 API（Cocoa 直写，`adapter_native.m`） | 已接。同上各项均在本机跑绿，64 条真窗口测试 |
| Linux | 原生 API（GTK3 直写） | 未接：没有 GTK3 那份 Adapter |
| wasm | 无 | Core 的"不含任何 GUI 库"证明，CI 里当可移植性闸门 |

平台分叉只落在**两份 C**（`backends/native-windows/adapter_native.c`、`backends/native-macos/adapter_native.m`）和 prebuild 脚本里；MoonBit 层共用 `backends/native-common/`，一行按平台分叉的代码都没有（分工定案见 TODO `T18`）。接入时量出的工程事实（文案分配语义、自动释放池栈式、层叠即 subviews 顺序、翻折自逆等）全部记在 [`docs/backend-lessons.md`](docs/backend-lessons.md)。

> CI 绿**不等于**真后端绿——`backends/` 在 native 门禁里被有意排除（要链接现编的库、还要一只会点鼠标的手），本地必须跑真窗口测试。

## 工程约定

- 公共 API 一律逻辑像素，物理换算只发生在 `Scale` 里（§30）。macOS 上还有第二道换算，但整段在 C 侧、只有一处（`adapter_native.m` 的 `moonui_native_px_to_pt` / `moonui_native_pt_to_px`）；y 轴方向不靠单独翻转换算，而是让视图 `isFlipped` 返回真、坐标口径在入口处就统一。
- 样式由 Core 层叠（Theme → 父容器 → 自身），在 `Window::relayout` 里先下发给叶子后端、再测量：顺序反了就会拿旧字号的度量排新矩形。原生控件后端有权完全不读它——§32 要保住系统原生外观。
- Core 不缓存窗口与控件状态，原生层是唯一事实来源；例外只有 min/max 约束、菜单勾选状态和快捷键表。
- 纯布局节点不占原生对象，叶子的原生父级只有窗口（§14）。
- 事件优先：`on_click` 只是 `Event::Click` 的过滤器糖，路由与派发在 `App` 一处完成（§10）。
- 无障碍视图是推导出来的，不是另登一份名册：Actions 来自事件订阅，State 来自原生层；纯布局节点只有显式声明 Role 才进视图（§32）。

## 深入资料与接手开发

- 后端踩坑与真窗口逐条验证：[`docs/backend-lessons.md`](docs/backend-lessons.md)
- 设计文档：[DESIGN.md](DESIGN.md)（§48 是当前进度轴）
- 全量 API 参考：[API.md](API.md)
- 待办与接力规矩：[TODO.md](TODO.md) / [AGENTS.md](AGENTS.md)
- 待办一律进 TODO.md：每条带永久编号与日期、引 §48 步骤号、写清"现在什么是真的"；已完成满一个月就删（git log 是档案），未完成的多久都留着。
- MoonBit 侧写法约定、`moon info` / `moon fmt` / `moon test` 的收尾顺序在 AGENTS.md。

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。（`T82` 前曾 vendored libui-ng，不入库，遵循它自己的 MIT 许可。`examples/lunamusic-tag` vendored 了 moontag，同样 Apache-2.0。）
