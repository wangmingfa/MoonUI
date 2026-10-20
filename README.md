# MoonUI

MoonBit 的 GUI 框架。目标不是"某个 C GUI 库的 MoonBit 绑定"，而是让 MoonBit 能写桌面应用的那层框架：布局、事件、控件、主题、HiDPI、菜单与对话框都在 Core 里定义，平台原生 API 的差异留在 Backend 实现侧（macOS 直写 AppKit、Windows 直写 Win32）。

> MoonBit API 是第一公民，C 只是实现手段，Backend 永远不能反向决定 MoonUI 的 API。（`T82`：框架已收敛到原生后端单后端，libui 那份 Backend 已删除。）

| | |
| --- | --- |
| 版本 | 0.1.0（后端无关的第一层已交付，真后端有 Windows 与 macOS） |
| 工具链 | moon 0.1.20260920，`preferred_target = "native"` |
| 测试 | native 260 条 + wasm 258 条 + 真窗口 macOS 15 条（原生 Cocoa）+ Windows 15 条（原生 Win32），一条命令 `bash scripts/test-local.sh` |
| CI | `.github/workflows/ci.yml`：`core`（三平台门禁）+ `core-portability`（wasm 证明 Core 不含任何 GUI 库）+ `macos-backend-link`（macOS 真后端真跑原生 Cocoa 真窗口测试）+ `windows-backend-link`（Windows 真后端的链接闸门：只连不跑） |
| 许可 | Apache-2.0 |
| 设计文档 | [DESIGN.md](DESIGN.md)：51 节初稿，README / TODO.md / 代码注释里的 `§14`、`§48-09~11`、`§47 风险 1` 全部按它的小节号引用，编号不要重排 |
| API 文档 | [API.md](API.md)：全量公开 API 的中文参考，按模块组织，含签名、说明与最小用法 |
| 待办 | 全部记在 [TODO.md](TODO.md)，接力开发的规矩在 [AGENTS.md](AGENTS.md) |

## 首次上手（从 clone 到跑通）

**前置**（版本以文件头那张表的"工具链"为准）：

1. [MoonBit](https://docs.moonbitlang.com) 工具链——macOS/Linux 用官方脚本装，Windows 用官方 PowerShell 脚本：
   ```sh
   curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
   ```
2. **node**（任何较新版本）——构建依赖它：仓库根 `prebuild-link.js` 在每次 native 构建前由 moon 调起，按宿主注入链接参数、并现编平台 C adapter；PATH 里没有 node 时 native 链接这步会红。
3. 平台编译器：macOS 的 Xcode 命令行工具（`xcode-select --install`，编真后端要 clang）；Windows 编真后端要 MSVC + vcvars。

**四步跑通**（全部在仓库根跑——链接参数里的相对路径按当前工作目录展开）：

```sh
moon check --deny-warn       # ① 类型与警告闸门，最快确认环境对了
moon run examples/hello      # ② 无头 Demo：终端打印事件与几何，不开窗口
moon run examples/gallery    # ③ 画册的逐页打印版（真窗口版是 examples/gallery-native）
bash scripts/test-local.sh   # ④ 全量门禁：native + wasm + Demo + 格式；本机是 macOS/Windows 时再跑真窗口测试
```

**想看真窗口**（可选，macOS；Windows 同形状换成 gallery-native）：

```sh
moon run examples/gallery-native     # 组件画册开真窗口：左栏选组件、右栏看效果，关窗口退出
```

**阅读顺序**：AGENTS.md（工程约定，最短）→ 本 README 的「它是什么，不是什么」与「目录」→ [DESIGN.md](DESIGN.md) 的 §14（布局）、§10（事件）、§48（路线图）→ [API.md](API.md)（查具体 API）→ TODO.md（挑活）。提改动前跑一遍 `moon info && moon fmt`，`pkg.generated.mbti` 跟着代码一起提交。

## 它是什么，不是什么

是**框架**：Core 拥有布局算法、事件路由、句柄生命周期、样式与主题的层叠、无障碍视图的推导；后端只负责把算好的矩形和属性写进原生层，并把原生事件送回 `App`。

不是**绑定**：`uiButton*`、`HWND`、`SDL_Window*` 这类东西不出现在公共 API 上，它们被 `NativeHandle` 和 External 对象的生命周期挡在 Backend 实现侧。判据是可执行的——§47 第 6 条要求 Core 里绝不出现 libui / GTK / SDL / Win32 / Cocoa 这些字样，CI 用一条 wasm job 证明它（wasm 上根本没有 native FFI，能编译就说明这一层干净）。

## 快速开始（无头，三平台都行）

不需要任何 GUI 库，Core + `MockBackend` 就能写完、测完整个应用。本地门禁一条命令跑完：

```sh
bash scripts/test-local.sh
```

拆开跑是这几条。`check` 不链接、也不编 C，所以四个 native only 的包（`backends/native-common`、`backends/native-windows`、`backends/native-macos`，加上 `examples/gallery-native`）三平台都进得了闸门：

```sh
moon check --deny-warn          # 警告在本项目里是错误
moon run examples/hello         # §49 的 Demo 各是一个可执行包，画册（gallery）也在其中
moon run examples/counter       # 下面四个同理：form / todo / file-manager / gallery
```

只有 `moon test` **不能在仓库根裸跑**：仓库根那条裸命令会去链接 `backends/native-windows` 的测试二进制，而它那批 `moonui_native_*` 符号只有 prebuild 现编的 Win32 adapter 提供（宿主不是 Windows 就没有这一步）——macOS / Linux 上符号找不到，链接必红。清单由 `scripts/ci-packages.sh` 打印，按宿主双向排除：

```sh
moon test $(bash scripts/ci-packages.sh packages examples tests _doccheck)                       # 无头 + 原生（不含 backends）
moon test --target wasm $(bash scripts/ci-packages.sh packages examples tests backends _doccheck) # wasm 那一层（多带 backends）
```

每台机器哪几条能跑、哪几条跑不了，集中在「每个系统上分别跑什么」那张表里。

## 真后端（平台原生 API：Windows 与 macOS）

`moon test backends/native-windows`（Windows）与 `moon test backends/native-macos`（macOS）会连各自那份平台 C Adapter 一起编链——跑起来就是桌面上真的开窗口、真的各按一次按钮，每条测试自己关掉了，不需要人工操作：

```sh
moon run examples/gallery-native   # 组件画册开真窗口：左栏选组件、右栏看效果，关窗口退出
```

平台分叉只落在**两份 C**（`backends/native-windows/adapter_native.c` 直写 Win32、`backends/native-macos/adapter_native.m` 直写 Cocoa）和 prebuild 脚本里；MoonBit 层共用 `backends/native-common/`（`ffi.mbt` + `backend.mbt` + ABI 头 `adapter.h`），一行按平台分叉的代码都没有（分工定案见 TODO `T18`）。接入时量出的工程事实（文案分配语义、自动释放池栈式、层叠即 subviews 顺序、翻折自逆等）全部记在 [`docs/backend-lessons.md`](docs/backend-lessons.md)。

> CI 绿**不等于**真后端绿——`backends/` 在 native 门禁里被有意排除（要链接现编的库、还要一只会点鼠标的手），本地必须跑上面那两条真窗口的测试。

## 每个系统上分别跑什么

MoonBit 那几层三平台是同一份代码，差别只有一格：**能不能链接真后端**。装好 MoonBit 之后照这张表走（"同左"就是字面一样）：

| 想做的事 | Windows | macOS | Linux |
| --- | --- | --- | --- |
| 本地门禁，一条命令跑完 | `bash scripts/test-local.sh` | 同左 | 同左（到类型闸门为止） |
| 备真后端的依赖 | 什么都不用备：平台 C 由 prebuild 首次 `moon build` 时用本机 MSVC 现编，编不出来时链接自己红 | 同左（clang 由 Xcode 命令行工具提供） | 还没有这条路（原生后端的 Linux 半在 TODO.md） |
| 无头测试（Core + MockBackend） | `moon test $(bash scripts/ci-packages.sh packages examples tests _doccheck)` | 同左 | 同左 |
| wasm 那一层（§47 第 6 条的证明） | `moon test --target wasm $(bash scripts/ci-packages.sh packages examples tests backends _doccheck)` | 同左 | 同左 |
| 类型闸门，含四个 native only 的包 | `moon check --deny-warn` | 同左 | 同左 |
| 接口与格式收尾 | `moon info && moon fmt`，然后提交 `.mbti` | 同左 | 同左 |
| 真窗口的测试 | `moon test backends/native-windows`（15 条，原生 Win32 直写） | `moon test backends/native-macos`（14 条，含对话框/文件面板/菜单栏/剪贴板；真鼠标交错会让测试假红——跑之前让 owner 停下操作） | 跑不了：原生后端的 Linux 半还没有 |
| 真窗口的 Demo | `moon run examples/gallery-native`（组件画册；要真人动手，等你关窗口才退出，不进自动闸门） | 同左 | 跑不了，同上 |

四条会咬人的细节：

- **`moon test` 要带包清单**，除非在 Windows 或 macOS 上点名本平台那批真窗口测试（见上表）。`moon check` / `moon info` 不链接、也不编 C，所以真后端的类型闸门在三平台都跑得动。
- **所有 `moon` 命令都在仓库根跑**：prebuild 现编产物路径与链接参数里的相对路径都按当前工作目录展开。`scripts/test-local.sh` 自己 `cd` 到根，从哪儿调用都可以。
- **Windows 上那个 bash 是 git-bash**：脚本认 `uname -s` 的 `MINGW*` / `MSYS*` / `CYGWIN*` / `Windows_NT`，用纯 PowerShell 时没有 `bash`，就按表里逐条手敲。
- **Windows 侧编真后端要把 MSVC 的 bin 排到 PATH 前头**（本地开过 vcvars 或 "x64 Native Tools Command Prompt" 就天然满足；CI 用 `ilammy/msvc-dev-cmd`）。原因是 Git for Windows 附带 coreutils 的 `link.exe` 会抢在 MSVC 链接器前面。

`scripts/test-local.sh` 在 Windows / macOS 上各多跑本平台那批真窗口测试，平台 C 由 prebuild 现编、编不出来时明确红掉；Linux 上到类型闸门为止。它另外在 macOS / Linux 上若 PATH 里有 `x86_64-w64-mingw32-gcc`，就拿它把 `backends/native-windows/adapter_native.c` 过一遍 `-fsyntax-only -Wall`（`-I` 指到 `$MOON_HOME/include` 取 `moonbit.h`），第一次用就抓到 `MF_RADIOCHECK` 这个不存在的宏（正确拼写 `MFT_RADIOCHECK`）。

## 现在能用什么

0.1 阶段交付的是**后端无关的第一层**，全部有测试覆盖：

| 层 | 内容 |
| --- | --- |
| Core 类型 | `UiError`、几何（逻辑/物理像素、`Scale`）、`Event`、`Style`/`Theme` |
| 布局 | Row / Column / Padding / Spacer / Center / Stack / Grid / Scroll |
| 生命周期 | `NativeHandle` + 句柄表（generation 防悬垂）、`App` 事件主循环 |
| 界面对象 | `Window`、`Widget`：0.1 四件（Label / Button / TextInput / Checkbox）+ 0.2 九种原生控件（PasswordInput / Separator / Slider / Spinbox / Progress / ComboBox / Multiline / RadioButtons / DatePicker）+ 八个组合组件（RadioGroup / Tabs / Steps / Alert / Card / Breadcrumb / Pagination / Rate，纯 MoonBit 拼装） |
| 平台能力接口 | 剪贴板、对话框、菜单栏 + 快捷键、`Backend` trait |
| 无障碍视图 | Role / Label / Description / State / Actions 的推导与声明（§32） |
| 示例 | §49 六个 Demo：Hello / Counter / Login / Todo / File Manager / Gallery（组件画册）；另有三份 DX 示例 settings-center / markdown-editor / data-admin；真窗口版只有 `gallery-native`（两平台共用同一份壳）。全部示例共用仓库里的 MoonUI logo 当应用图标 |
| 测试后端 | `MockBackend`：无头跑完整事件循环与布局数值 |

真实后端已按 §48 顺序接到多步（Backend 实现 + 真窗口 Hello、Stack 层叠、菜单栏等），两个平台上都有。能力逐批真跑时量出的账、以及真窗口测试的逐条验证，记在 [`docs/backend-lessons.md`](docs/backend-lessons.md)。CI 绿不等于真后端绿——`backends/` 在 native 门禁里被有意排除，本地必须跑真窗口测试。

## 目录

§4 建议的结构里，只有已经存在的东西才有目录，没建的不留空壳：

```text
packages/moonui/  Core：error / geometry / event / style / theme / handle / layout
                  widget / window / app / backend trait / clipboard / dialog
                  menu / shortcut / accessibility + MockBackend + §49 六个 Demo
packages/moonui-app/
                  前台门（§47 注记）：new_app() 三步糖直接返回 App[NativeBackend]，
                  用户从此不 import 后端包（T82 后单后端，不再装箱枚举）
examples/         hello counter form todo file-manager gallery 六个无头可执行包
                  + gallery-native：画册的真窗口版（T82 后唯一的真后端壳，
                  两平台共用同一份壳；prebuild-link.js 按宿主编 C、把链接配置挂到
                  backends/native-common 顺 import 传进来）
tests/ffi/        §37 第二层：native FFI 探针（自包含 C stub，不依赖外部库）
backends/native-common/
                  原生后端的共享 MoonBit 层（ffi.mbt + backend.mbt）+ ABI 头
                  adapter.h（T82 起从 libui-common 移居此处）。两个平台共用这一份，
                  目录里既没有 C 也没有 link
backends/native-windows/
                  Windows 半：Win32 直写的 C Adapter（adapter_native.c）+ 15 条真窗口测试
backends/native-macos/
                  macOS 半：Cocoa 直写的 C Adapter（adapter_native.m）+ 14 条真窗口测试
scripts/          ci-packages.sh：core 与 core-portability 两个 job 共用的门禁包清单
                  test-local.sh：本地一条命令的门禁，按宿主系统分叉
_doccheck/        README 那段代码的独立包验证
```

和 §4 的清单有三处不一致，都是权衡之后留下的：

- **`Backend` trait 留在 Core，没有单独的 `packages/backend/`。** trait 的方法签名要用 `NativeHandle`、`Event`、`LogicalSize` 这些 Core 类型，`App[B : Backend]` 也要用它当类型参数；trait 单独成包就变成 moonui ↔ backend 互相依赖，而 MoonBit 的包不允许成环。
- **`packages/widgets/` 暂时不建。** §4 列的 radio / slider / progress / image / list / tree / table / tabs 一个都还没实现，而现有的四类控件和 §14 的布局节点共用同一个 `Widget` 类型与同一张句柄表；拆包要么把 `Widget` 的构造暴露成公共字段，要么把类型参数约束复制一遍。§17 的 Custom Widget 落地之后这个包才有真实住户。
- **五个 Demo 的代码留在 `packages/moonui/demo.mbt`，`examples/` 只做驱动。** Demo 在这里同时是框架的回归载体：布局数值、句柄回收、事件派发都要拿一棵真实的树来断言，放进 `examples/` 就只能变成"跑过但没验证"。`examples/*` 反过来只准用公开 API，公开 API 不够用就是该补 API 的信号。

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

§37 的三层在前两层进了 CI 闸门；第三层自 2026-10-14（`T6`）起进的是**链接加真跑**——`macos-backend-link` 真跑 `backends/native-macos`（14 条）真窗口测试，`windows-backend-link` 只到链接。仍只能本地跑的只剩真窗口 Demo：它们要真人关窗口才退出。

| 层 | 跑什么 | 证明什么 |
| --- | --- | --- |
| 第一层：Core + Mock | `moon test packages/moonui` | 布局数值、事件路由、生命周期与句柄回收，全在 `MockBackend` 上，无头 |
| 第二层：FFI 探针 | `moon test tests/ffi` | 自包含 C stub，不依赖任何外部 GUI 库，只验 MoonBit ↔ C 这一对能不能通 |
| 第三层：真后端 | `moon test backends/native-windows`（Windows，15 条）、`moon test backends/native-macos`（macOS，14 条；真鼠标交错会让测试假红——跑之前让 owner 停下操作） | 真开窗口、真摆放、真按坐标点击（含真打字、真勾选、真读写系统剪贴板、真弹原生对话框与文件面板、真往原生菜单位里装一棵并点它、真按键与真改焦点）、真读一次系统外观、真把窗口搬到另一块屏、真按窗口所在那块屏量一次工作区并居中、真关闭，最后断言句柄表归零。逐条钉了什么，见 [`docs/backend-lessons.md`](docs/backend-lessons.md) |

另外两类不属于 §37 的分层，但同样在闸门里：`examples/*` 和 `_doccheck` 只用公开 API，公开 API 不够用就是该补 API 的信号；`moon test --target wasm` 证明 Core 与第一/第二层不含任何 GUI 库依赖（§47 第 6 条）。

## 平台支持

| 平台 | 后端 | 状态 |
| --- | --- | --- |
| Windows | 平台原生 API（Win32 直写，`adapter_native.c`） | 已接。§48-03/09~11/15 落地，§48-13 与勾选框、§48-18/19/20（剪贴板/对话框/文件面板/菜单栏）、§48-16 键盘与焦点、§16 系统外观、§48-21 缩放、§12 按窗口工作区、§30 鼠标五变体均真跑绿。逐条验证见 [`docs/backend-lessons.md`](docs/backend-lessons.md)。CI 有 `windows-backend-link` 链接闸门（真窗口测试还不在里面） |
| macOS | 平台原生 API（Cocoa 直写，`adapter_native.m`） | 已接。§48-03/09~11/15 落地，§48-13 与勾选框、§48-19 剪贴板、§48-18 对话框与文件面板、§48-20 菜单栏、§48-16 键盘与焦点加鼠标、§16 系统外观、§48-21 缩放、§12 按窗口工作区均在本机跑绿。CI 有 `macos-backend-link`：真跑原生 Cocoa 那半 14 条真窗口测试，示例只连不跑 |
| Linux | 平台原生 API（GTK3 直写） | 未接：没有 GTK3 那份 Adapter（TODO.md） |
| wasm | 无 | Core 的"不含任何 GUI 库"证明，CI 里当可移植性闸门 |

后端顺序按设计文档：Backend #1 曾是 libui-ng → SDL3（自绘）→ 可能的 Win32/Cocoa/GTK 直连，见 §48 与 §51。第二个平台接上之后，"`Backend` 这个形状够不够"已不只是推断：`ffi.mbt` 与 `backend.mbt` 一行没改就能接 Cocoa，而 Cocoa 逼出来的差异全在 C 侧那一份文件里。

## 工程约定

- 公共 API 一律逻辑像素，物理换算只发生在 `Scale` 里（§30）。macOS 上还有第二道换算，但整段在 C 侧、只有一处（`adapter_macos.m` 的 `moonui_px_to_pt` / `moonui_pt_to_px`）；y 轴方向同理，只有 `moonui_flip_y` 一处。
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
- 待办一律进 TODO.md：每条带日期、引 §48 步骤号、写清"现在什么是真的"；已完成满一个月就删（git log 是档案），未完成的多久都留着。
- MoonBit 侧写法约定、`moon info` / `moon fmt` / `moon test` 的收尾顺序在 AGENTS.md。

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。（`T82` 前曾 vendored libui-ng，不入库，遵循它自己的 MIT 许可。）
