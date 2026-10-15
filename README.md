# MoonUI

MoonBit 的 GUI 框架。目标不是"某个 C GUI 库的 MoonBit 绑定"，而是让 MoonBit 能写桌面应用的那层框架：布局、事件、控件、主题、HiDPI、菜单与对话框都在 Core 里定义，平台原生 API 的差异留在 Backend 实现侧（macOS 直写 AppKit、Windows 直写 Win32）。

> MoonBit API 是第一公民，C 只是实现手段，Backend 永远不能反向决定 MoonUI 的 API。（`T82`，2026-10-15：框架收敛到原生后端单后端，libui 那份 Backend 已删除——DESIGN.md 附录第 7 条记着这笔，"删一个 Backend 恰是这条原则的实证"。）

| | |
| --- | --- |
| 版本 | 0.1.0（后端无关的第一层已交付，真后端有 Windows 与 macOS） |
| 工具链 | moon 0.1.20260920，`preferred_target = "native"` |
| 测试 | native 185 条 + wasm 178 条 + 真窗口 macOS 14 条（原生 Cocoa）+ Windows 15 条（原生 Win32），一条命令 `bash scripts/test-local.sh`。真窗口那两批逐条钉了什么、各自量出过哪些只有真窗口才有的牙，见[「真窗口那两批逐条」](#真窗口那两批逐条) |
| CI | `.github/workflows/ci.yml`：`core`（三平台门禁）+ `core-portability`（wasm 证明 Core 不含任何 GUI 库）+ `macos-backend-link`（macOS 真后端：**真跑**原生 Cocoa 那批真窗口测试，gallery 只连不跑）+ `windows-backend-link`（Windows 真后端的**链接**闸门：只连不跑） |
| 许可 | Apache-2.0 |
| 设计文档 | [DESIGN.md](DESIGN.md)：51 节的初稿，README、TODO.md 和代码注释里那些 `§14`、`§48-09~11`、`§47 风险 1` 全部按它的小节号引用，所以编号不要重排 |
| 待办 | 全部记在 [TODO.md](TODO.md)，接力开发的规矩在 [AGENTS.md](AGENTS.md) |

## 首次上手（从 clone 到跑通）

**前置**（版本以文件头那张表的"工具链"为准）：

1. [MoonBit](https://docs.moonbitlang.com) 工具链——macOS/Linux 用官方脚本装，Windows 用官方 PowerShell 脚本：
   ```sh
   curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
   ```
2. **node**（任何较新版本）——构建依赖它：仓库根 `prebuild-link.js` 在每次 native 构建前
   由 moon 调起，按宿主注入链接参数、并现编平台 C adapter（`_build/prebuild/`），PATH 里没有
   node 时 native 链接这步会红。
3. 平台编译器：macOS 的 Xcode 命令行工具（`xcode-select --install`，编真后端要 clang）；
   Windows 无头开发不额外要，编真后端要 MSVC + vcvars（见「真后端」）。

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

**阅读顺序**：AGENTS.md（工程约定，最短）→ 本 README 的「它是什么，不是什么」与
「目录」→ [DESIGN.md](DESIGN.md) 的 §14（布局）、§10（事件）、§48（路线图）→
TODO.md（挑活：`- [ ]` 的都能领，每条自带"现在什么是真的"）。提改动前跑一遍
`moon info && moon fmt`，`pkg.generated.mbti` 跟着代码一起提交。


## 它是什么，不是什么

是**框架**：Core 拥有布局算法、事件路由、句柄生命周期、样式与主题的层叠、无障碍视图的推导；后端只负责把算好的矩形和属性写进原生层，并把原生事件送回 `App`。

不是**绑定**：`uiButton*`、`HWND`、`SDL_Window*` 这类东西不出现在公共 API 上，它们被 `NativeHandle` 和 External 对象的生命周期挡在 Backend 实现侧。判据是可执行的——§47 第 6 条要求 Core 里绝不出现 libui / GTK / SDL / Win32 / Cocoa 这些字样，CI 用一条 wasm job 证明它（wasm 上根本没有 native FFI，能编译就说明这一层干净）。

## 快速开始（无头，三平台都行）

不需要任何 GUI 库，Core + `MockBackend` 就能写完、测完整个应用。本地门禁一条命令跑完，按宿主系统分叉（native 测试、六个 Demo、wasm 那一层、`.mbti` 与格式，Windows / macOS 上再加各自那批真窗口的测试）：

```sh
bash scripts/test-local.sh
```

拆开跑是这几条。`check` 不链接、也不编 C，所以四个 native only 的包（三个真后端 `backends/native-common`、`backends/native-windows`、`backends/native-macos`，加上 `examples/gallery-native`）三平台都进得了闸门：

```sh
moon check --deny-warn          # 警告在本项目里是错误
moon run examples/hello         # §49 的 Demo 各是一个可执行包，画册（gallery）也在其中
moon run examples/counter       # 下面四个同理：form / todo / file-manager / gallery
```

只有 `moon test` **不能在仓库根裸跑**：仓库根那条裸命令会去链接 `backends/native-windows` 的测试二进制，而它那批 `moonui_native_*` 符号只有 prebuild 现编的 Win32 adapter 提供（`adapter_native.c` 由 cl 现编，宿主不是 Windows 就没有这一步）——macOS / Linux 上符号找不到，链接必红。所以清单是**双向**排除的——`ci-packages.sh` 的 core 口径不含 backends，wasm 口径带上但不编 C，真窗口那批由 `test-local.sh` 按 `uname -s` 各跑各的。

把测试范围写出来就行，清单由 `scripts/ci-packages.sh` 打印——`core` 与 `core-portability` 两个 job 用的就是同一份，不会各说一套（两个后端 job `macos-backend-link` / `windows-backend-link` 不共用这份清单：mac 侧的后端测试二进制自 T6 起真跑，Windows 侧整侧只到链接；examples 下的 gallery-native 在两边都只连不跑）：

```sh
moon test $(bash scripts/ci-packages.sh packages examples tests _doccheck)
```

wasm 那一层不能整仓一条命令：`examples/gallery-native` 是 native only 的**可执行**包，入口 .mbt 被门控掉之后 wasm 侧它没有 main，moon 报 4067。同一份脚本换一套目录参数就是 wasm 的口径（多带 `backends/`）：

```sh
moon test --target wasm $(bash scripts/ci-packages.sh packages examples tests backends _doccheck)
```

每台机器哪几条能跑、哪几条跑不了，集中在「每个系统上分别跑什么」那张表里。

## 真后端（平台原生 API：Windows 与 macOS）

`moon test backends/native-windows`（Windows）与 `moon test backends/native-macos`（macOS）会连各自那份平台 C Adapter 一起编链——跑起来就是桌面上真的开窗口、真的各按一次按钮，每条测试自己关掉了，不需要人工操作。平台 C（macOS 的 `adapter_native.m` 直写 AppKit、Windows 的 `adapter_native.c` 直写 Win32）由仓库根 `prebuild-link.js` 在构建前自动现编成 `_build/prebuild/adapter_native.o|.obj`，连同平台链接参数一起挂在 `backends/native-common` 上顺 import 传给所有下游：

```sh
moon run examples/gallery-native   # 组件画册开真窗口：左栏选组件、右栏看效果，关窗口退出（2026-10-12 建壳，2026-10-14 合并平台壳）
```

真窗口的 Demo 今天只有一份画册（gallery-native，两平台共用同一份壳）。`T82`（2026-10-15）删 libui 之前，§49 的六份 Demo 曾各有一份 `-libui` 真窗口壳（2026-10-10 两侧都建好并逐份真开过窗口——mac 那半是 `T28`，Windows 那半是 `T50`；它们都**要真人动手才退出**，循环只有在你关掉那只窗口时结束，所以不进任何自动闸门。Windows 那半在真跑之外还多量过一步：counter 的按钮不用真人点，PowerShell 侧 `SetProcessDPIAware` 后按真物理坐标 `SetCursorPos` 加 `mouse_event` 投了两轮按下抬起，进程打出 `第 1 次点击：Count: 1`、`第 2 次点击：Count: 2`——不先 `SetProcessDPIAware` 读到的客户区是被虚化的 800x600，坐标差 1.25 倍；`mouse_event` 不带 MOVE 光标根本不动。这段经验记着，将来补第二份真窗口 Demo 时直接可用）。

平台分叉落在**两份 C** 和 prebuild 脚本里的分支，不在 MoonBit 层：Windows 那份是 `backends/native-windows/adapter_native.c`，macOS 那份是 `backends/native-macos/adapter_native.m`。链接参数、连同"现编哪份 C"都在仓库根的 `prebuild-link.js` 里，唯一一份配置挂 `backends/native-common` 单点（`T59`/`T60` 从各自 moon.pkg 收拢、`T67`/`T69`/`T70` 砍挂点包的历史、`T80` 的共享半回避随 `T82` 失去前提并回单点——演进全程见 git log）。MoonBit 侧共用 `backends/native-common/` 的 `ffi.mbt`（两平台同一份 FFI 声明）和 `backend.mbt`（`@moonui.Backend` 实现）加 ABI 头 `adapter.h`（`T82` 起从 libui-common 移居到此），那个目录里既没有 C 也没有 `link`。

**这条分工不只是描述，是定了的**（TODO `T18`，2026-10-09 定案）：某一侧先接上某个能力时，走"两份 C 各返回一个'本平台没实现'的错误码，共享 `backend.mbt` 把错误码映射成那句 `Unsupported`"，而不是把 `ffi.mbt` + `backend.mbt` 复制进两个平台包各一份——后者的代价是 `.mbti` 碎成两份、几十个方法加一批 `extern "c"` 从此手工同步、"改一条 `Unsupported` 文案要三处一起动"的钉子变四处。**判据**是"只有当两侧的**行为形状**在 MoonBit 层就分叉才值得走那条复制的路"，单纯"这侧还没接上"不算。这条判据九次照抄同一套路（`T23` 两种事件、`T19` 剪贴板、`T20` 对话框、`T21` 文件面板、`T22` 菜单栏、`T39` 键盘与焦点、`T40` 系统外观、`T42` 按窗口工作区、`T39` 鼠标那一半），每轮都是"两份 C 各实现一遍、MoonBit 一行按平台分叉都没有"；唯一动到 trait 的是 `T22`——§25 的勾选态只存在 Core、原生条目只有写入口，Core 必须把它算出来的结果**推**给后端（`set_menu_item_checked`）。连两侧行为真不一样那次也没分叉：Win32 逐 UTF-16 code unit 发一条 `WM_CHAR`，打一串字出 N 条 `Input`；macOS 一次 `insertText:` 整串，只出 1 条——差异落在 C 和各自那份真窗口测试的断言里，MoonBit 读不出来。（`T82` 前这些轮次的两份 C 是 libui 的 adapter.c / adapter_macos.m，`T82` 后原生后端的两份 C 接管同一套 ABI——Windows 份文件头明写"逐段从 adapter.c 搬过来"。）

**这句话已经被验证过多回，不再是推断**：`T72-T76` 接原生 Cocoa/Win32 后端时共享 MoonBit 层一行没改（`git diff` 里它们不在改动清单上），新增的只有两份 adapter_native、各自的 moon.pkg 和真窗口测试。§47 风险 6 要的就是这条判据。Core 那一层更是与系统无关——同一份源码 native 与 wasm 两边全绿（§47 第 6 条）。所以"换平台不动 MoonBit"要读成"**平台差异**不写进 MoonBit"，不是"MoonBit 永远不动"；`T82` 删整个 Backend 也是同一句话的另一面——Core 一行没改，删的是 Backend 实现侧。

但要说清一件事：**"没接的那一份返回一个'本平台没实现'的错误码、共享实现把它映射成 `Unsupported`"那一半到现在还没有测试跑到**——`adapter.h` 里目前没有"未实现"这个码（`backend.mbt` 里那句 `Unsupported` 也早在四处能力落地后就一句不剩）。这条挂在 TODO `T38`，真要走到那一步得拿**新代码**里"这一侧还没接上"的入口当载体，`T48` 的主题切换监听是眼下剩下的候选；账也分得清了——`moonui_set_menu_bar` 那两个负数码从 MoonBit 走不到（是防我们自己布局漂移的响 guard），`moonui_menu_click_item` 的 `-2`（置灰项不派发）倒是两侧测试都钉住的，见 `T38`。

## 每个系统上分别跑什么

MoonBit 那几层三平台是同一份代码，差别只有一格：**能不能链接真后端**。装好 MoonBit 之后照这张表走（“同左”就是字面一样）：

| 想做的事 | Windows | macOS | Linux |
| --- | --- | --- | --- |
| 本地门禁，一条命令跑完 | `bash scripts/test-local.sh` | 同左 | 同左（到类型闸门为止） |
| 备真后端的依赖 | 什么都不用备：平台 C（`adapter_native.c`）由 prebuild 在首次 `moon build` 时用本机/runner 已有的 MSVC 现编，编不出来时链接自己红、stderr 有完整构建日志 | 同左（clang 由 Xcode 命令行工具提供） | 还没有这条路（原生后端的 Linux 半在 TODO.md） |
| 无头测试（Core + MockBackend） | `moon test $(bash scripts/ci-packages.sh packages examples tests _doccheck)` | 同左 | 同左 |
| wasm 那一层（§47 第 6 条的证明） | `moon test --target wasm $(bash scripts/ci-packages.sh packages examples tests backends _doccheck)` | 同左 | 同左 |
| 类型闸门，含四个 native only 的包 | `moon check --deny-warn` | 同左 | 同左 |
| 接口与格式收尾 | `moon info && moon fmt`，然后提交 `.mbti` | 同左 | 同左 |
| 真窗口的测试 | `moon test backends/native-windows`（15 条，原生 Win32 直写；每条开头替上一条补跑收尾的隔离沿用 libui 时代定下的形状——`T9`/`T10` 两批红出来的教训，隔离的沿革与 libui 那批 38 条的九批欠账史注见[「真窗口那两批逐条」](#真窗口那两批逐条)） | `moon test backends/native-macos`（14 条，`T76` 之后含对话框/文件面板/菜单栏/剪贴板；真鼠标交错会让测试假红——跑之前让 owner 停下操作） | 跑不了：原生后端的 Linux 半还没有 |
| 真窗口的 Demo | `moon run examples/gallery-native`（组件画册；两平台共用同一份壳；要真人动手，等你关窗口才退出，所以不进自动闸门） | 同左：同一个包，换宿主就是同一条命令 | 跑不了，同上 |

四条会咬人的细节：

- **`moon test` 要带包清单**，除非你在 Windows 或 macOS 上点名本平台那批真窗口的测试。链接参数由仓库根 `prebuild-link.js` 注进构建图、顺 import 传到可执行包（`T59`/`T60` 从各自 moon.pkg 收拢），但 `link_configs` 没有宿主系统这一维（只按输出后端 native / js / wasm 分档）、平台 C 也只在对应宿主上现编——于是仓库根裸跑会去链接 `backends/native-windows` 的测试二进制，而它那批 `moonui_native_*` 符号只有 prebuild 现编的 Win32 adapter 提供，macOS / Linux 上符号找不到、链接必红，看到它就是跑错平台了。反过来在 Windows 上点名 `backends/native-macos` 同理（“这边没有 Cocoa”，而 Windows 的 cl 也编不了 ObjC）。`moon check` 和 `moon info` 两头的坑都不沾，它们不链接、也不编 C，所以真后端的类型闸门在三个平台上都跑得动。
- **所有 `moon` 命令都在仓库根跑**：prebuild 现编产物路径与链接参数里的相对路径都按当前工作目录展开。`scripts/test-local.sh` 自己 `cd` 到根，从哪儿调用都可以。
- **Windows 上那个 bash 是 git-bash**：脚本认 `uname -s` 的 `MINGW*` / `MSYS*` / `CYGWIN*` / `Windows_NT`，用纯 PowerShell 时没有 `bash`，就按表里逐条手敲。
- **Windows 侧编真后端要把 MSVC 的 bin 排到 PATH 前头**（本地开过 vcvars 或 “x64 Native Tools Command Prompt” 就天然满足；CI 用 `ilammy/msvc-dev-cmd` 干同一件事）。原因是 Git for Windows 附带 coreutils 的 `link.exe`（创建硬链接那个）会抢在 MSVC 链接器前面——`T11` 在 meson 时代量过这条，`T82` 删掉 libui 现编链后这件事只剩 prebuild 里那条 cl 调用还关心它。

`scripts/test-local.sh` 在 Windows 和 macOS 上各多跑本平台那批真窗口的测试，平台 C 由 prebuild 现编、编不出来时明确红掉，不会“跳过然后照样报绿”；Linux 上它到类型闸门为止。它另外多出来的一步是 `T40` 带来的：非 Windows 宿主上若 PATH 里有 `x86_64-w64-mingw32-gcc`（Homebrew 的 mingw-w64），就拿它把 `backends/native-windows/adapter_native.c` 过一遍 `-fsyntax-only -Wall`，`-I` 指到 `$MOON_HOME/include` 取 `moonbit.h`。这一步管的是语法与类型（`cl` 那边迟早一样红），第一次用就抓到 `MF_RADIOCHECK` 这个不存在的宏——MinGW 与 MSDN 都拼作 `MFT_RADIOCHECK`，同一个值 0x200。没有那个编译器就打印一句跳过、不算失败：那台 Windows 机器本来就会真编一遍，所以那一支整段包在 `uname -s` 的 `MINGW* | MSYS* | CYGWIN* | Windows_NT` 之后，在那台机器上是空过。（`T82` 前这道闸门还护着 libui 的 `adapter.c`——那条按 error 拦、自带两条已知警告，`T82` 后只剩 native 那份、按零警告拦。）


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
| 示例 | §49 六个 Demo：Hello / Counter / Login / Todo / File Manager / Gallery（组件画册，2026-10-12），各自是 `examples/` 下的可执行包；同一批在 macOS 与 Windows 上各有一份跑真窗口的版本（2026-10-13 起曾合并成单排 `-libui` 六份；`T82` 2026-10-15 删 libui 后真窗口壳只剩画册那份 `gallery-native`——两平台共用同一份壳，2026-10-14 由 `-native-macos`/`-native-windows` 两壳合并而来；无头六份原样都在）；全部示例共用仓库里的 MoonUI logo 当应用图标（`assets/logo/moonui`，`App::set_icon` 传不带扩展名的 stem：mac 补 `.png`、Windows 补 `.ico`，§26，2026-10-12） |
| 测试后端 | `MockBackend`：无头跑完整事件循环与布局数值 |

真实后端按 §48 的顺序接到了第 11 步（`Backend` 实现 + 真窗口的 Hello Demo）、第 15 步（Stack 的层叠）与第 20 步（菜单栏），两个平台上都有。**史注先说清**：这一段的九批能力（`T23`/`T19`/`T20`/`T21`/`T22`/`T39`/`T40`/`T42`/`T48`）逐批真跑时量出的账，多半记在 libui 那两份 C 上——`T82`（2026-10-15）删 libui 后那两份文件没了，原生后端的两份 C（形状逐段从 adapter.c 搬过来）接管同一套 ABI，量出的结论原样成立，个别指向 adapter.c / libui-common 的路径按删除后的树读。§48-21（HiDPI）里"系统缩放变化推成一条 `ScaleChanged`"那一格是 `T24`；§48-21（HiDPI）里"系统缩放变化推成一条 `ScaleChanged`"那一格是 `T24`，mac 在这台机器跑绿、Windows 那份同形测试 2026-10-10 在那台机器跑绿（`T51`）。§12 的居中与 §20 的屏幕读数是 `T42`：`Window::center` 现在量的是**这只窗口当下所在那块屏**的工作区（trait 多一条 `window_work_area`，两份 C 各两条 `moonui_window_screen_*`），进程级那条 `screen_size()` 按定义只有主屏、从此只服务 Core 那句"屏幕多大"；mac 同样在这台机器跑绿，Windows 那份同形测试 2026-10-10 在那台机器跑绿（`T52`）。第 11 步那句"真窗口的 Hello Demo"今天在这一侧宽了一格：§49 五份 Demo 在 macOS 与 Windows 上各有一只真窗口（`examples/` 下那五份 `-native-macos` 与五份 `-libui`，2026-10-10，`T28`/`T50`）。§48-16 那一格（Event）里五种事件现在都有原生来源：按钮点击（§48-12）两侧早就各跑绿一轮，输入框文本变化（§48-13）与勾选框勾选是 `T23`——macOS 在这台机器跑绿（当时 14 条，`T22` 之后是 16 条），Windows 那份由那台机器跑绿（16 条，TODO `T34`）。§48-19（Clipboard）是 `T19`：`ui.h` 里压根没有剪贴板 API，所以 `adapter.h` 加两条入口（`moonui_clipboard_text` / `moonui_clipboard_set_text`，`moonui_*` 从 50 到 52），Cocoa 走 `NSPasteboard`、Win32 走 `OpenClipboard` + `CF_UNICODETEXT`，MoonBit 侧只多两条 `extern "c"` 和两个包装——又是 `T18` 定的 (a)，一行按平台分叉都没有。mac 在这台机器跑绿并配两条负控制（摘掉读、把写换成空转），Windows 那份 2026-10-10 在那台机器跑绿（`T37`，顺带量出 `OpenClipboard` 的系统级锁有短暂争用、adapter.c 加了有界重试）；§48-18 的对话框半（消息框／确认框）是 `T20`：`uiMsgBox` 返回 `void`、拿不到用户的选择，所以两份 C 各自直接调原生面板（Cocoa 的 `NSAlert runModal`、Win32 的 `MessageBoxW` + `MB_TASKMODAL`），`adapter.h` 到 55 个 `moonui_*` 入口——多出来的三条是两条对话框入口加一条测试脚手架 `moonui_auto_dismiss_dialog`（模态是同步阻塞的，测试靠它先安排"按哪只按钮"）；mac 在这台机器跑绿并配两条负控制（`confirm` 恒置 1、消息框换成空转），Windows 那份 2026-10-10 在那台机器跑绿（`T43`）；§48-18 的文件选择半是 `T21`：`adapter.h` 再加五条（打开 / 保存 / 选文件夹三条入口、一条取走路径、一条脚手架 `moonui_auto_answer_file_dialog`）到 60 个 `moonui_*`，Cocoa 走 `NSOpenPanel`/`NSSavePanel`、Win32 走 `IFileDialog`，脚手架同样因为模态阻塞——macOS 15.6 上面板住在 `com.apple.appkit.xpc.openAndSavePanelService` 里、客户端没有替按"接受"的通道，所以 mac 那条测试钉的是阻塞时间与取消映射，"选了 → 路径"由 Windows 那份真跑（`T44`，2026-10-10 已跑绿）；§48-20 的菜单栏是 `T22`，它把 `backend.mbt` 里最后那句 `Unsupported` 也一并清掉了（四处能力落地之后 `grep -c 'Unsupported("'` 于共享实现 = 0——该次量的那份文件住 libui-common，`T82` 起同形状住在 native-common——§48-18 的对话框与文件面板、§48-19 的剪贴板、§48-20 的菜单栏，而 `T39`（键盘与焦点）再加六条——一条进程级的键盘监听 `moonui_on_key`、四条按键读数 `moonui_key_target` / `moonui_key_is_down` / `moonui_key_modifiers` / `moonui_key_name`、一条焦点回读 `moonui_focused_control`——加两条测试脚手架，`adapter.h` 到 72 个入口；`T40`（系统外观）再加一条 `moonui_system_theme`，到 **73** 个，两份 C 各读自己系统的设置（mac 读 `NSApp.effectiveAppearance` 的 `name` 里含不含 `Dark`，Windows 读注册表的 `AppsUseLightTheme`），读不到一律当浅色、两侧都没有错误码；`T42`（按窗口取屏幕工作区）再加两条 `moonui_window_screen_origin` / `moonui_window_screen_size`，到 **75** 个，mac 走 `[win screen].visibleFrame`、Win32 走 `MonitorFromWindow(MONITOR_DEFAULTTONEAREST)` + `GetMonitorInfoW`，这一批和 `T22` 一样又动到了 trait（多一条 `window_work_area`，因为"这只窗口在哪块屏"只能按句柄问，进程级那条 `screen_size()` 按定义只有主屏）。键盘与焦点没有多出一条 trait 方法：它们是 `poll_event` 冒出来的事件，mac 侧靠 `[NSEvent addLocalMonitorForEventsMatchingMask:]` 收键、靠轮询 `firstResponder` 出 `Focus`/`Blur`（在 MoonBit 侧去重，所以程序自己挪焦点不会冒出多余的事件），⌘Q 那类被主菜单认领的组合由 `moonui_menu_claims` 吞掉、不回声成 `KeyDown`；§48-21 的 `ScaleChanged` 是 `T24`，它是这九批能力里唯一一份 C 没进 diff 的那批：`moonui_window_dpi` 本来就是逐窗口现读的（mac 走 `[window backingScaleFactor]`，Windows 走 `GetDpiForWindow`，进程在 `adapter.c` 开头就把自己声明成 `PER_MONITOR_AWARE_V2`），而 `scale_of_window` 每圈换算尺寸时都在调它，于是 `refresh_scale` 挂在 `pump` 里紧挨 `refresh_focus`，每圈按 `live_windows` 问一遍 DPI、**只在差异上**发一条事件，去重和那张读数表（`dpi_of`）都在 MoonBit 这一侧，那一轮 `adapter.h` 的 73 条声明一字未动；代价照实说——灵敏度上限是 `wait_slice_ms`（8 毫秒一档），与 `T39` 的焦点同一档取舍。真后端今天能构造 18 个 `Event` 变体里的 17 个（`Frame` 是 `T31` 给自绘后端留的续命信号，原生控件后端不构造它——重绘是系统的事，`request_redraw` 在这侧是空操作；`ThemeChanged` 是 `T48` 落地的，2026-10-10：和 `T24` 一样走每圈轮询而不是原生监听——`refresh_theme` 挂在 `pump` 里紧挨 `refresh_scale`，现读一次 `native_system_theme_is_dark`、只在差异上给每只存活窗口发一条；App 侧收到后给目标窗口重算 `style_base` 并下发。选轮询而不是 `AppleInterfaceThemeChangedNotification`/`WM_SETTINGCHANGE` 的理由：两边的监听不是同一种便宜（mac 十几行，Windows 得先立一只 `HWND_MESSAGE` 隐藏窗口），而读数是现成的、两侧同一份代码，所以 `T38` 挂账里"这条最可能第一次用上未实现码"的预测没有发生——一行 C 都没动。mac 的真窗口测试用 `T40` 那个进程级外观覆盖当微分，翻转方向按进入测试时的系统外观现推，浅色深色桌面都成立）（鼠标那五个是 `T39` 的鼠标那一半落地的，2026-10-10：进程级一份监听加 C 侧 `hitTest:` / `ChildWindowFromPoint` 反查命中，pos 除以命中控件的 Scale、滚轮增量 C 侧已换算完一次不除）。菜单栏这一格值得多说两句（这段的账量在 libui 时代，`T82` 删 libui 后读作史注——结论就是原生后端为什么也把菜单搭在原生层）：它是这几条里唯一**libui 的现成 API 两侧都不能用**的一格：mac 上 `uiNewWindow` 末尾会 `uiprivFinalizeMenus()`，建过窗口之后再 `uiNewMenu` 就撞 `uiprivUserBug`——那是个当场终止进程的东西，而 §25 的菜单是运行时才装的；Windows 上 libui 的窗口过程把不认识的 `WM_COMMAND` id 一律交给 `runMenuEvent`，那里对未知 id 直接 `uiprivImplBug` = `DebugBreak()`，而我们的 id 是 Core 分配的编号、libui 的账本里没有。所以 C 把菜单搭在原生层（Cocoa 往 `[NSApp mainMenu]` 上整棵换，Win32 给每只活窗口建一份自己的 `HMENU` 并经典子类化窗口过程截自己那一段 id 基址——原生后端的两份 C 原样沿用这套形状），MoonBit 只做两件事：把 Core 那棵树打包成一段字节（`ffi.mbt` 的 `menu_tree`，布局写在 `adapter.h`），和把原生派发回来的 id 变成 `MenuSelect`。反方向另开了一条 trait 方法（`set_menu_item_checked`），理由见上面 `T22` 那一段。Win32 这一侧还量出一条几何账（史注同上）：`SetMenu` 会吃掉客户区一行，而 §25 是运行时才装的、建窗口时按"没有菜单位"算的外框事后并不知道，所以要么建窗口就把菜单位算上（`menu_pad` 必须留 0），要么事后装并**量**出那一行（全摘量一次、挂上再量一次，不抄 `SM_CYMENU`——不同 DPI 与菜单字体下它和真行高不等），随后每一次改客户区尺寸都加回这个 `menu_pad`；mac 那边没这一问，主菜单不占窗口客户区。`backends/native-common/` 是共享的 MoonBit FFI 层与 `@moonui.Backend` 实现加那份 ABI 头（`adapter.h`，`T82` 起移居此处），`backends/native-windows/` 只有 Win32 那份 C（`adapter_native.c`，形状逐段从 libui 时代的 adapter.c 搬过来）加它那 15 条真窗口测试，`backends/native-macos/` 只有 Cocoa 那份 C（`adapter_native.m`）加 14 条真窗口测试。两边的 `moon test` 都会在桌面上真开窗口、把真控件按 MoonUI 算出的矩形摆进客户区、按坐标命中它再往那个控件直接投一条原生动作（按钮是 `BM_CLICK` / `performClick:`，输入框是逐 code unit 的 `WM_CHAR` / field editor 的 `insertText:`），然后断言句柄表归零。将来接原生后端的 Linux 半（GTK 直写）就是第三份 adapter，形状与 `-windows`/`-macos` 对称，MoonBit 侧照旧不动。

CI 绿**不等于**真后端绿——`backends/` 在 native 门禁里被有意排除（要链接现编的库、还要一只会点鼠标的手），本地必须跑上面那两条真窗口的测试。

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
                  Windows 半：Win32 直写的 C Adapter（adapter_native.c，形状逐段
                  从 libui 时代 adapter.c 搬过来）+ 15 条真窗口的测试
backends/native-macos/
                  macOS 半：Cocoa 直写的 C Adapter（adapter_native.m）+
                  14 条真窗口的测试，MoonBit 侧 import 上面那个包
scripts/          ci-packages.sh：core 与 core-portability 两个 job 共用的门禁包清单
                  test-local.sh：本地一条命令的门禁，按宿主系统分叉
_doccheck/        README 那段代码的独立包验证
```

和 §4 的清单有三处不一致，都是权衡之后留下的：

- **`Backend` trait 留在 Core，没有单独的 `packages/backend/`。** trait 的方法签名要用 `NativeHandle`、`Event`、`LogicalSize` 这些 Core 类型，`App[B : Backend]` 也要用它当类型参数；trait 单独成包就变成 moonui ↔ backend 互相依赖，而 MoonBit 的包不允许成环。§4 给 `packages/backend/` 安排的活儿（§18 Renderer、§22 Native API）本来也是"实现侧"，等真实后端接入时再建，那时它是叶子。
- **`packages/widgets/` 暂时不建。** §4 列的 radio / slider / progress / image / list / tree / table / tabs 一个都还没实现，而现有的四类控件和 §14 的布局节点共用同一个 `Widget` 类型与同一张句柄表；拆包要么把 `Widget` 的构造暴露成公共字段，要么把类型参数约束复制一遍，两种都比现在多一层 API。§17 的 Custom Widget 落地之后这个包才有真实住户——那时"在 Core 之外定义控件"是需求，不是提前设计。
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

这段是编译过的：`packages/moonui/moonui_test.mbt` 里有一条 blackbox 测试按原样跑它，`_doccheck/` 是同一份代码的独立包验证。`@moonui` 是导入路径末段决定的默认别名（`import { "username/MoonUI/packages/moonui" }`）。

与设计文档 §50 的期望形态差两处，都是当前工具链逼出来的：`trait` 不是类型、也没有 `dyn`，所以后端在编译期随 `App[B]` 选定，构造控件必须显式交后端；`fn { }` 的无参写法已废弃。

## 真后端量出来的事

记下来免得再踩。**史注先说清**（`T82`，2026-10-15）：这一节量出的对象是 libui 那两份 C（adapter.c / adapter_macos.m），删 libui 后文件没了——但原生后端的两份 C 形状逐段从 adapter.c 搬过来（Windows 份文件头自证），这些结论跟着形状一起活在现树上，个别指向已删文件的路径按删除后的树读。Windows 那半（Win32 + libui-ng 的 `windows/`）八条：

- **libui 的文案 getter 是分配语义。** `uiButtonText()` 返回它自己 malloc 的一份拷贝，契约要求调用方 `uiFreeText()`；Adapter 拷进 `Bytes` 之后就还掉。还漏一块的后果不是慢慢漏，是退出时炸。
- **`uiUninit()` 末尾审计 libui 自己的分配表，发现泄漏就直接 `DebugBreak()`**（libui-ng 的 release 构建也不关这条）。没有调试器时这就是一个退不出去的测试进程 / 0x80000003。所以 `terminate()` 的前提是 MoonBit 侧句柄表已经归零，里程碑测试断言的正是这一点。这条在测试里的形状 Windows 上量过，和 mac 上不一样：一条真窗口测试中途 raise 漏下窗口，红的不是"后面每条各报一次 `1 != 0`"，而是下一条走到 `terminate()` 的测试直接死在这里，整批 `moon test backends/libui-windows` 拿不到一行测试输出（native 的 println 全缓冲，abort 即丢）。两份真窗口的测试因此各自加了"每条开头替上一条补跑收尾"的隔离（mac 是 `macos_test.mbt` 的 `sweep_leaked_handles`；Windows 那份在 `backend_wbtest.mbt` 里同一套之外还多两张按种类分开的登记表，因为 `ffi_wbtest.mbt` 那 6 条不建后端实例）。
- **`uiInit()` / `uiUninit()` 没有引用计数**，重复 init 会因窗口类已存在而失败。Adapter 把这一对守成幂等单例，同一个测试进程里跑两条冒烟才安全。
- **静态库带不进 manifest**，Common Controls v6 与 DPI 感知由 `adapter.c` 自己补（`#pragma comment(linker, ...)` + 建窗口前 `SetProcessDpiAwarenessContext`）。
- **链接参数里的 `-link` 前缀不能去。** 它是 moon 把后面一串参数转交给 link.exe 的通道，代价是每次链接多印一句 `LNK4044：无法识别的选项 "/link"，已忽略`——这条无害；去掉前缀就变成 `LNK1104：打不开 libui.a`。两头都在 Windows 上实测过：删掉那 5 个字符，先由 cl 报 `D9002`（`/LIBPATH` 被当陌生选项吞掉）和 `D9024`（`libui.a` 当源文件、"object file assumed"），再由 link.exe 报三条 `LNK1104`，三个测试 exe 一个都产不出来。
- **`ChildWindowFromPoint` 和 `SetWindowPos` 在同一个坐标系里。** 前者收父窗口客户区坐标，后者摆的也是客户区，所以按坐标注入点击不需要任何换算；命不中子窗口时它返回父窗口自己，于是"点在空白处"和"控件摆错了位置"落在同一个负数返回上——点击因此能反过来验证布局矩形真的落到了原生 HWND。
- **`MsgWaitForMultipleObjects` 报的是"上次醒来之后新到的消息"，不是"队列里还有消息"。** 队列里有积压时它能一直返回 `WAIT_TIMEOUT`，而 WM_QUIT 就躺在队列里读不到——"等一次、走一步"的泵因此会在预算无限时空转。所以 `pump` 先用 `PeekMessage(PM_NOREMOVE)` 探测、把已有消息排干才去等，并且用墙钟（`GetTickCount64`）兜一条硬预算。libui 的 `uiMainStep(0)` 帮不上忙：它把"处理了一条"和"队列本来空"都返回 1，只有 WM_QUIT 返回 0。
- **`link` 只在可执行包里生效，不会顺着 import 传下来。** `backends/libui-windows/moon.pkg` 声明的那串库对它的测试包够用（测试包本身就是可执行包），但示例壳必须自己再写一遍，否则就是整套 53 条 LNK2019——这是 MoonBit 的链接模型（`T59`/`T60` 起 example 不再手抄：prebuild-link.js 的 `link_configs` 顺 import 传播，就是为绕开这一条）。
- **libui 的菜单 API 在 Windows 上是个陷阱：不认识的命令 id 直接 `DebugBreak()`。** `windows/menu.cpp:296` 把 `runMenuEvent` 里查不到的那一条交给 `uiprivImplBug`，而 §25 的菜单项 id 是 Core 分配的编号、libui 的账本里没有，所以 `T22` 自己搭 `HMENU`（逐窗口一份，活窗口记在 64 槽的登记表里），并用经典子类化把窗口过程筛成"`WM_COMMAND` 且 `lParam=0` 且 `HIWORD(wParam)=0` 且 id 在我们那段基址（`0x4000`）之上"才接、其余原样放行（`IDOK`/`IDCANCEL` 正是 libui 要吞的那两条）。这条过滤放宽一寸，后果不是某条测试红，而是整进程 `0x80000003`、零行输出——和上面 `uiUninit` 那条同一个形态。另外两笔只在这边存在的账：`SetMenu` 会吃掉客户区一行，而 §25 是运行时才装的、libui 建窗口时按"没有菜单位"算的外框事后并不知道，所以要么建窗口就把最后一个参数给 1（让 libui 自己现量，`menu_pad` 必须留 0），要么事后装并**量**出那一行（全摘一次、挂上一次的差值；不抄 `SM_CYMENU`，不同 DPI 与菜单字体下它和真行高不等），随后每一次 `uiWindowSetContentSize` 都加回去；`MFT_RADIOCHECK` 是**类型**位不是状态位（勾选态读回要看 `fType`），`MF_DISABLED` 从不回写（写回去会变成 `MF_GRAYED`，而置灰检查读的正是它）。**这一条整段已经过真跑**：快照逐字符、两种装序的 pad、radio 读回、置灰那发 `-2` 都在那台 Windows 机器上跑绿（`T45`，2026-10-10——真跑量出 `GetMenuItemInfoW` 读回的 fType 不带 `MF_POPUP` 位，快照函数改认 `hSubMenu`）。

macOS 那半（Cocoa + libui-ng 的 `darwin/`）另加八条：

- **自动释放池是栈式的，而 `uiInit` 自己压了一层。** 把 `uiInit`/`uiUninit` 包进 `@autoreleasepool` 就是弹非栈顶的池，运行期直接 fatal（`objc: Invalid or prematurely-freed autorelease pool`），而且测试进程一行输出都不留——因为 `uiInit` 压进去的那层（libui 的 `globalPool`）活得比这次调用久。做法是自己 alloc 一层存在 `adapter_macos.m:89`，`uiUninit` 之后才 drain；`uiMainSteps`/`uiMainStep`/`uiQuit` 三个循环入口干脆不套池，AppKit 的事件对象不归本次调用管。
- **翻折自逆，所以方向单靠自己测不出来。** MoonUI 的矩形从左上量，Cocoa 的 view 从左下量，这一翻写在 `moonui_flip_y`（`adapter_macos.m:229`）里、摆位和读数共用一条公式。负控制实测：把它改成恒等，"控件矩形往返"那条的坐标断言**一条都没红**——写反的两次翻折仍然互相抵消。要钉住方向必须引入一个不经过这条路径的坐标，于是有了 `moonui_cocoa_origin_of_widget`（同文件 :1278）：顶边的控件在 Cocoa 原始 frame 里 `origin.y` 必须接近"父视图高 - 控件高"，这一条是全 suite 里唯一为方向红的。共享实现里所有别的坐标断言都做不到这件事。（那次运行其余几条也红，是 `native_live_handles()` 量的那张**进程全局**表被中途 raise 的测试污染：raise 跳过它自己的 `terminate()`，而表在 `backends/libui-common/ffi.mbt:17`、跟后端实例无关。这条已经修掉——`macos_test.mbt` 里每条测试开头替上一条补跑一次 `terminate()`（`sweep_leaked_handles`），实测注入一条故意失败的测试时红数从"9 条红 8 条"收到只红它自己，把清场改成空转又回到 8 条。更自然的 `defer` 写法走不通：MoonBit 的 panic 不执行 defer，本机量过。）
- **AppKit 不给出 `buttonType` 的读取口。** 只有 `setButtonType:`，所以 `-[NSButtonCell buttonType]` 在运行期是 unrecognized selector（实测崩在测试脚手架里）。想在 Cocoa 上把 checkbox 从"按钮"里剔出去得去问无障碍角色；而 Win32 那份本来也没剔（它的类名判断同样把 BS_CHECKBOX 算进 Button），所以两边按 `isKindOfClass:[NSButton class]` 一致，反而不用细分。
- **Cocoa 的层叠就是 `subviews` 数组顺序，和 Win32 是同一种话。** "Cocoa 没有 z-order"这句先前的判断是错的：数组末尾画在最上面，`addSubview:positioned:NSWindowBelow`（:904）就是 `SetWindowPos(HWND_BOTTOM)`，`NSWindowAbove` 就是 `HWND_TOP`。所以两个后端量出来的数一模一样——Row 得 `[0,1,2]`，同样三个控件放进 Stack 得 `[2,1,0]`（`backends/libui-macos/macos_test.mbt` 与 Windows 那份 `backend_wbtest.mbt` 各钉一条）。层叠与 Tab 在两边也确实共用同一条列表：Cocoa 靠 `setAutorecalculatesKeyViewLoop:` 按 subviews 顺序重算焦点链。
- **点是单位，Retina 是倍数。** libui-ng 的 darwin 后端根本没有 DPI 概念，`backingScaleFactor` 就是全部信息，于是 `moonui_window_dpi` 报的是倍数乘 96（本机 Retina 读出 192）。控件矩形这里过一道 px→点→px，AppKit 存的是小数坐标，所以往返自逆、断言能写到 1 逻辑像素内；而 libui 收 int 的入口（窗口尺寸、窗口位置）只吃整点，窗口级的量最坏差 1 物理像素——这就是 mac 那份测试的容差比 Windows 那份松一格的原因。
- **`uiQuit` 是 `[NSApp terminate:]`，但在 steps 模式下它只把循环标成"跑完了"。** 实测调用后进程照常在，`uiMainStep` 从这里开始返回 0，之后还能再 init 一轮——所以共享实现里 `loop_ended` 那条判定在 mac 上也成立，测试敢调它。
- **darwin 的 libui 把"固有尺寸"整个交给了 Auto Layout，`ui_darwin.h` 里没有 minimum size 的对应物。** 于是 §18 那句"量由原生层做"在 mac 上是直接问 AppKit，而且要同时问两条再**逐维取大**（`adapter_macos.m` 的 `moonui_widget_minimum_size` 起）：`intrinsicContentSize` 和 `[cell cellSize]`（后者正是 NSButton 自己算固有尺寸的算法）。只取前一条会截字——实测 label 报 81.5 而 cell 要 85.3，按钮 72x20 而 86x32，勾选框 63x16 而 65x18；差的那几像素是边框的 `alignmentRectInsets`（按钮左右各 7pt），标题在 72pt 的 frame 里只拿到 48pt，而 "Click Me" 要 52pt，于是 Demo 上显示成 "Click M"。反过来 TextInput 的 `intrinsicContentSize`（宽 96）比 `cellSize`（66）大，那是可编辑区的最小宽度而不是截字，所以取大不会把它压小。测试那条对照组直接读 AppKit 的 `[cell cellSize]`（`moonui_cocoa_cell_size_of_widget`，在文件末尾的测试脚手架那一节），不拿我们自己的数字当尺子；把实现改回只取 `intrinsicContentSize`，label、按钮、勾选框三条一起红。控件 view 一出生也没有 superview（darwin 的控件构造只 alloc/init，挂进窗口是 libui 自己的 `SetSuperview` 的事，而我们从不叫它），所以"搬进窗口客户区"这一步在 mac 上比 Windows 还短——就是 `addSubview:`。

- **libui 的 darwin 菜单在建过窗口之后就封版了，而且它的勾选是个"翻"。** `uiNewWindow` 末尾调 `uiprivFinalizeMenus()`（`third-party/libui/src/darwin/window.m:438`），此后 `uiNewMenu` 与建条目都撞 `uiprivUserBug`（`darwin/menu.m:339`）——在这台机器上是当场终止进程，而 §25 的菜单恰好是运行时才装的，所以 `T22` 的 Cocoa 那半直接搭 `NSMenu` 挂到 `[NSApp mainMenu]`（整棵换，旧的 `removeItem:` 拆干净）。第二处更要紧：`uiMenuItemSetChecked` 压根不看入参（`darwin/menu.m:252`），只把当前态翻一下——§25 的勾选态只存在 Core，"翻"在框架层就是错的语义，这就是 `Backend` 多一条 `set_menu_item_checked(id, checked)` 的原因（Core 算完**推**给后端，Radio 连同组兄弟一起推，互斥是 Core 的事、原生层不会自己取消谁）。独立尺子是 `[NSApp mainMenu]` 本身：那三条测试逐字符比的是主菜单里当下真挂着的那几顶，不是 adapter 自己抄的名单；四条负控制（摘掉 `addItem:`、摘掉 `terminate` 里那次 `moonui_menu_clear()`、摘掉交给 MoonBit 的那次调用、摘掉 `setState:`）各红在预测的那一处，逐条记在 `macos_test.mbt` 的注释与 TODO `T22` 里。顺带一条 AppKit 的规矩：`setAutoenablesItems:` 得关掉，否则 AppKit 会按"target 现在能不能响应"自己置灰我们那些没有 action 的条目，于是 `isEnabled` 变成它说了算、Core 推过去的置灰就看不见。

### §14 的落点：控件按 HWND 自己摆

libui-ng 的 Windows 后端只有容器布局（uiBox / uiGrid / uiForm），没有绝对摆放；而 §14 要 MoonUI 自己做布局、纯布局节点不占原生对象、叶子的原生父级只有窗口，§32 又要真控件保住原生外观与无障碍。三条候选路里只有"绕过 libui 的布局层"同时保住这两条，所以 Adapter 用 `moonui_control_attach` 把控件的 HWND 从 libui 的隐藏工具窗口（`windows/control.cpp` 里所有控件出生时的 parent）搬进目标窗口客户区，再按 MoonUI 算出的矩形 `SetWindowPos`。

两条不变量支撑这条捷径，都是从 vendored 源码读出来、再被冒烟测试验证的：

- 回调路由按控件 HWND 查表（`windows/events.cpp` 的 `runWM_COMMAND` 拿 `lParam` 当键，不是控件 ID），所以换父级不影响 `WM_COMMAND`；顺带一提，控件挂在 utilWindow 下时这条路由是**故意被跳过**的，搬进真窗口才收得到点击。
- 主循环对顶层祖先跑 `IsDialogMessage`（`windows/main.cpp` 的 `processMessage`），键盘 Tab 因此照旧，只是顺序跟 z-order 走。所以首次挂载把控件插到 z-order 末尾——挂载顺序即 Tab 顺序；之后的重新布局只改矩形、不动 z-order，免得 resize 把焦点链重排一遍。

代价是 libui 的容器不再替窗口收尾：控件必须在所属窗口之前逐个 `destroy_button`，否则 `DestroyWindow` 连带释放 HWND，libui 那份控件对象却不回收，退出时的分配审计就把这次运行变成 `DebugBreak`。挂回调的控件由同一次 `destroy_button` 松开闭包引用（§47 风险 1：C 长期持有的闭包不 decref 就是泄漏，不 incref 就是悬垂）。

Cocoa 那份把同一件事又做了一遍，而且更短：`moonui_control_attach` 就是 `[contentView addSubview:v positioned:NSWindowBelow]` 加一句 `setTranslatesAutoresizingMaskIntoConstraints:YES`（`adapter_macos.m` 里的 `moonui_control_attach`，按名字读）——后者是"这个 view 的 frame 由 MoonUI 管，别给它生成约束"的正式写法，而 libui 自己的容器布局站在反方向（NO + Auto Layout），既然不建 `uiBox` 就必须站到 YES 这边，否则第一次 layout 就把 `setFrame:` 的结果覆盖掉。回调路由也不看父级：action 落在控件自己的 target 上。收尾那条代价两边同名，只是 mac 上是"view 还留在 subviews 里而它的 libui 对象已经没了"，所以 `moonui_widget_destroy` 里先 `removeFromSuperview`。

### §48-15 的落点：层叠与焦点链都收到 Core

原生层只有一份顺序，它同时管着"谁画在上面"和"谁先响应 Tab"，而挂载只能给一个方向。Stack 的契约（数组靠后的盖住靠前的）和挂载顺序正好相反。`T29` 把这件事从"靠 attach/raise 的增量去凑"改成"Core 算好整份推下去"：`Widget::paint_order` 算出整窗**从顶层到底层**的绘画顺序（普通容器先序、Stack 子树叶子倒序），`set_content` 挂载之后整份推给 `Backend::set_paint_order`；焦点链是另一条——声明顺序（先序，`collect_native` 收出来的 `leaves` 原样），整份推给 `Backend::set_focus_chain`。两条链在 Core 里分开算、分开推，后端只负责"落"。不含 Stack 的树两条链同值（先序 = 声明序），行为与旧的"挂载顺序 = Tab 顺序"一致；Stack 里两条链分道——层叠倒序、焦点声明序，Tab 不再跟着层叠翻。

写出来的方向是被真窗口量过的，不是靠文档印象：`moonui_control_z_index` 在 Windows 读 `GetWindow(GW_HWNDPREV)` 的步数，在 macOS 从 `subviews` 数组末尾倒数，两边都是 0 = 最上层。同一组控件在两个后端上给同一组数——Row 的三个控件 `[0, 1, 2]`，同样三个控件放进 Stack `[2, 1, 0]`（`backends/libui-windows/backend_wbtest.mbt` 与 `backends/libui-macos/macos_test.mbt` 各钉一条）。这不是巧合，是 `set_paint_order` 在 LibuiBackend 里按倒序逐个 `raise_widget`（底层先提、顶层后提）翻译成 z-order 的结果——和旧的"挂载压底 + Stack 逐个提顶"逐位相同，所以这两条真窗口测试原样绿；"Cocoa 没有 z-order"那句旧话就是在这里被推翻的。Core 的 `paint_order` 因此可以只写一遍。

焦点链在原生后端上今天还是空操作：`LibuiBackend::set_focus_chain` 只 `check_initialized()` 一句（和 `T31` 的 `request_redraw` 在原生后端上空转同一种"契约先行、机制后补"），所以真窗口上 Tab 暂时仍是旧行为——不含 Stack 的树无感，Stack 里 Tab 仍跟着层叠翻成数组倒序。把声明顺序真正接进原生焦点机制（macOS 的 `nextKeyView` 链、Windows 的 z-order 与 Tab 本就同源）那一格挂在 TODO `T66`。没有量的那一维是 Tab 的落点：合成一条 `VK_TAB` 要先让测试进程抢到前台，而前台归属是这台机器的用户状态，实测落点跟着激活时序漂，所以没留这个脚手架（见 `adapter.h` 的说明）——`T66` 的验证要么靠真窗口上人工 Tab 走一遍、要么得先补一套稳定的 Tab 脚手架。

### §48-16 的落点：三种事件都从原生回调入队

按钮点击之外，输入框的文本变化和勾选框的勾选现在也从真控件的回调里出来（`T23`）。三条走的是同一套机制：`backend.mbt` 的 `create_widget` 在建好原生控件之后按种类挂一个闭包（`native_widget_on_click` / `on_text_changed` / `on_toggled`），C 侧用一张 `(owner, fn)` 的槽位表接住它——incref 一次，同 owner 同 fn 重复注册是替换而不是再加，槽位在 `moonui_widget_destroy` 里整批放开，所以挂三种事件不需要动销毁路径。libui 给每种控件的回调函数指针类型不同（`void(*)(uiEntry*,void*)` 对 `void(*)(uiCheckbox*,void*)`），所以每种各一个 trampoline，不能共用一个函数；trampoline 丢掉 libui 递来的 sender，因为 MoonBit 侧要的是"回头问那个控件现在的状态"，不是它报的那半句话。

于是 `push_input` 在回调里再读一次 `widget_text`，把**那一刻的全文**入队成 `Input(target, 全文)`——§48-16 那句"通知只说变了、内容要问原生对象"就落在这一步；勾选那条不需要读，`BN_CLICKED` / `onToggled:` 之后 libui 已经把状态翻好了，读的是 `moonui_widget_checked`。

测试侧的脚手架是"按坐标命中真控件，再对它做这个平台上真人会做的那件事"，两条各用各的原生入口：Windows 把焦点给那个 `edit` 再逐 UTF-16 code unit 发一条 `WM_CHAR`，macOS 把 focus view 给那只文本框再让它的 field editor 走 `insertText:`。两者都**不用**程序化改文本的入口（`EM_REPLACESEL` / `SetWindowText` / `setStringValue:`），因为那正是"Core 自己 `set_text` 不该回声成一条 `Input`"要排除的东西；这条区分是被负控制钉住的——把 mac 那份换成 `setStringValue:` 那条测试就红（Windows 侧的对应物已经在那台机器实测过了：`uiEntrySetText` 期间由 `inhibitChanged` 压住 `EN_CHANGE`，见 TODO `T34`——而且是先红了一次才逼出来的：那边原先直接发 `WM_SETTEXT`，跳过这道闸，Core 改文案于是回声成一条多余的 `Input`）。

顺着这条还钉住一件 Windows 特有的事：**勾选框和按钮共用同一个窗口类名**。libui 拿 `L"button"` 创建两者，只把样式位分开（`BS_PUSHBUTTON` 对 `BS_CHECKBOX`，`button.cpp:92-94`、`checkbox.cpp:106-108`），所以 `moonui_widget_set_text` 想按类名分派到 libui 自己的 setter（必须走 setter，见上面那条 `inhibitChanged`），在 `button` 那一支还得再看一次 `GWL_STYLE & BS_TYPEMASK`，否则就是把 `uiCheckbox*` 当 `uiButton*` 使。

这层分派改的是**类型正确性，不是可观测行为**，说清楚免得把测试估高：错派成 `uiButtonSetText` 今天看不出来——两个 setter 函数体逐行相同（`button.cpp:72-77` 对 `checkbox.cpp:70-75`），`hwnd` 在两个结构体里也同偏移（都是 `uiWindowsControl c` 之后紧跟 `HWND hwnd`）。错派成 `uiEntrySetText` 就确实是踩内存，但咬的位置和先前记的不同：`BOOL inhibitChanged` 是 `struct uiEntry` 的**最后一个**字段，而 `struct uiCheckbox` 到 `onToggledData` 就结束了（`entry.cpp:4-8` 对 `checkbox.cpp:4-8`），于是那两句赋值是往这只对象末尾**之外**多写 4 字节（先 `TRUE` 后 `NULL`），落在堆的 slack 里，今天既不弄哑勾选框也不红一条测试。所以新加那句勾选测试（`check.set_text` 之后 `assert_false(app.step())` 与 `check.text()`）钉的是"这条分支真跑过、读写都对"，它的下界由两次负控制给出：把勾选框那一支改成什么都不做 → `check.text()` 那句红；在那句 setter 之后补一次 `BM_CLICK` → 紧跟其后的 `assert_false(app.step())` 红。mac 那侧不需要这层分派（按钮与勾选框同为 `NSButton`，`setTitle:` 一支就够），但两条测试同形同序。（AppKit 里确实有一个官方的"别带我玩"开关：`NSCell` 的 `mimicOptOut` / `isMimic`——鼠标跟踪期间被收进同一个 mimic set 的一组 cell 只会各自收到 drawing 与 action **一次**，opt-out 的那个连画都不画。但那条机制只在真人鼠标 tracking 的循环里生效，我们这两句 setter 根本不进 tracking，所以"程序赋值不回声"靠的是"不发消息"，不是 mimic。写在这儿是为了下次有人问到"同一批 NSButton 会不会被连带触发"时不必再查一遍。）

一个诚实的差异：**同样一串字在两侧产生的事件条数不同**。Windows 逐 code unit 发 `WM_CHAR`，edit 每个字符发一次 `EN_CHANGE`，所以往"初值"里打两个字出**两条** `Input`（第一条带的是打进去一个字之后的"初值打"，第二条才是"初值打字"）；macOS 一次 `insertText:` 整串，同样这段只出**一条**。Core 收到的还是同一种事件（每条都带当时读回的全文），所以 MoonBit 里一行按平台分叉的代码都没有——差异全部留在两份 C 和两份测试的断言里。这正是 `T18` 定的 (a) 那个形状，也是它第一次真被用上。

macOS 这条路上有一个坑值得单独记：`hitTest:` 命中的是 **field editor**（一只 `NSTextView`，它是文本框的子视图，窗口一显示就已经在编辑），不是那只 `NSTextField`。所以命中之后得往上退到包住它的那只文本框，而且不许越过 `contentView`——不然标题栏附近那只真的 `NSTextField` 会被误认成内容区的输入框。

### 死在哪一次 FFI 调用

两份 Adapter 都有 `TRACE(...)`，打开方式是在对应包的 `moon.pkg` 里临时加回 `stub-cc-flags`：Windows 那半 `"-DMOONUI_TRACE"` 在 `backends/libui-windows`，macOS 那半在同一条字段、写在 `backends/libui-macos`。这条现在得手写、不能常驻，正是 `stub-cc-flags` 被从 `backends/libui-windows/moon.pkg` 里去掉的原因——它原先住在共享那个包（改名前的 `backends/libui`）里，`native-stub` 顺着 import 传，一份 flags 会同时喂给 cl 和 clang，而两边只有 `-D` 与 `/D` 这一字之差。加回来验完就删，别把它留在库里。

为什么需要它：native 测试进程里 MoonBit 的 `println` 是全缓冲的，异常退出时整段丢失（macOS 上第一次撞自动释放池那次就是零输出），只有 C 侧即时 `fflush` 的 trace 留得住顺序。

## 测试怎么分层

§37 的三层在前两层进了 CI 闸门；第三层自 2026-10-14（`T6`）起进的是**链接加真跑**——`macos-backend-link` 现编 `libui.a` 之后真跑 `backends/libui-macos`（44 条）与 `backends/native-macos`（14 条）两批真窗口测试，`examples/` 下那六份 `-libui` 仍只连不跑。仍只能本地跑的只剩六份示例：它们要真人关窗口才退出。唯一的未知（无头 runner 上起不起得来 `NSApplication`）要等这个仓库第一次推上 remote 才有答案，退路是把那两步换回 `--build-only`。

| 层 | 跑什么 | 证明什么 |
| --- | --- | --- |
| 第一层：Core + Mock | `moon test packages/moonui` | 布局数值、事件路由、生命周期与句柄回收，全在 `MockBackend` 上，无头 |
| 第二层：FFI 探针 | `moon test tests/ffi` | 自包含 C stub，不依赖任何外部 GUI 库，只验 MoonBit ↔ C 这一对能不能通 |
| 第三层：真后端 | `moon test backends/native-windows`（Windows，15 条）、`moon test backends/native-macos`（macOS，14 条；真鼠标交错会让测试假红——跑之前让 owner 停下操作） | 真开窗口、真摆放、真按一次坐标点击（现在还有真打字、真勾选、真读写系统剪贴板、真弹原生对话框与文件面板、真往原生菜单位里装一棵并点它、真按键与真改焦点）、真读一次系统外观（深色还是浅色由进程自己的覆盖决定，不动用户的系统设置）、真把窗口搬到另一块屏、真按窗口所在那块屏量一次工作区并把窗口居中到它、真关闭，最后断言句柄表归零。两边都做了句柄隔离，一条中途失败只红它自己。逐条钉了什么、各自量出过哪些只有真窗口才有的牙，见[「真窗口那两批逐条」](#真窗口那两批逐条) |

另外两类不属于 §37 的分层，但同样在闸门里：`examples/*` 和 `_doccheck` 只用公开 API，公开 API 不够用就是该补 API 的信号；`moon test --target wasm` 证明 Core 与第一/第二层不含任何 GUI 库依赖（§47 第 6 条）。

### 真窗口那两批逐条

**史注先说清**（`T82`，2026-10-15）：标题里那“两批”是 libui 后端的真窗口测试（macOS 40/44 条、Windows 35/38 条），随删 libui 整体退场——还在树上的现役批是原生后端的 `backends/native-macos` 14 条与 `backends/native-windows` 15 条（`native_test.mbt`，逐条钉了什么见 TODO `T75`/`T77` 的完成注），这一节按史注保留：它钉的每一条形状（句柄隔离、剪贴板复原、模态脚手架、菜单快照、缩放分叉）在原生后端的同形测试里都在，读它就是读那些测试的形状账。macOS 那批按测试名读、不按行号（往被引用的文件插一行就把后面的引用全挪走，而挪走的引用不会自己报错）。两批都做了句柄隔离：每条开头替上一条补跑收尾，一条中途失败只红它自己，不再需要"只看第一条红"。

macOS 40 条（`backends/libui-macos`，2x 屏机器上刚跑过）：

- `T19` 剪贴板往返「真后端读写系统剪贴板，测完把原内容放回去」——读写的就是这台机器上用户的剪贴板，复原只覆盖文本形态。
- `T20` 对话框「消息框与确认框真弹原生面板，答案是按钮给的」——模态面板靠预排的那发脚手架替用户按按钮、答案来自面板自己。
- `T21` 文件 / 保存 / 文件夹「真弹出来，答案是取消」——`NSOpenPanel`/`NSSavePanel` 真弹，macOS 15.6 上面板在 XPC 服务进程里、客户端没有替按"接受"的通道，所以钉的是阻塞时间与取消映射，"选了 → 路径"交给 Windows 那份真跑（`T44`）。
- `T22` 菜单栏三条（整棵装进原生主菜单的逐字符快照 / 真点击回流成 `MenuSelect` / 失败形态和 MockBackend 逐字相同），尺子是 `[NSApp mainMenu]` 本身。
- `T39` 键盘与焦点三条（真按键成 `KeyDown`/`KeyUp`、菜单认领的 ⌘Q 只回一条 `MenuSelect` 不双响、改焦点出恰好一条 `Focus` 挪走补一条 `Blur`）加鼠标五条（按下与拖拽成 `MouseDown`/`MouseMove` 点是客户区物理像素、抬起只从不自跑的控件报上来、一条双击配一条 `Click`、滚轮方向与量级往返且两轴同时非零当场报 -5、三种失败形态返回码报回去而一条事件不许多）。
- `T40` 系统外观读数钉在「窗口尺寸、位置、缩放按物理像素往返」里，靠一条只影响本进程的 `NSApp.setAppearance:` 覆盖双向钉住（深色读到 `Dark`、浅色读到 `Light`、取消覆盖读回原值），和跑它的那台机器当下是什么主题无关，也不动用户的系统设置。
- `T24` 缩放变化两条（「窗口停在同一块屏上时一条 ScaleChanged 都不许多」与「窗口搬去另一块屏出恰好一条 ScaleChanged，搬回来再来一条」），目的屏从活后端的 `screen_size()` 现读、换屏的触发前提在移动前后各量一次 DPI，只有一块屏的机器走 `else` 分支钉"不许冒多余的那条"并打印一句换屏触发没跑到；`adapter.c` 与 `adapter_macos.m` 这次一个字都没动，它是 MoonBit 侧在每轮 `pump` 里读一次已经读过的 DPI 去重。
- `T42` 按窗口工作区一条「工作区读数与居中跟着窗口自己那块屏走」，尺子是 `[win screen].visibleFrame` 读回来的矩形对 `screen_size()` 那份**主屏**读数——这台机器的副屏 scale 是 1.0，拿主屏的倍数换算必错；窗口还没上屏时 C 退回主屏那块，而不是报一个 0 尺寸（0 尺寸会被 `LogicalRect::center` 读成"摆到左上角"，症状会被误读成居中 bug）。
- `T54` 补 mac 侧对 Windows 的两处测试不对称：「未初始化的真后端拒绝创建对象」负控制进了 `macos_test.mbt` 第一条，六条 libui 冒烟（真按钮被点一次句柄全收 / 重新摆放只改矩形不动挂接 / 点第二个只触发第二个 / 四种控件状态读写都落在真 view 上 / 窗口几何可读可写且摘下来的控件不再响应点击 / 纯布局节点没有原生对象可读）新起一份白盒 `backends/libui-macos/ffi_wbtest.mbt`，mac 那批从 28 涨到 35（28 + 1 + 6）；几何那条顺手钉住 Cocoa 的真分叉——子视图在窗口变大时锚着左下原点不动，mac 版断言是"显式 `set_bounds` 之后 origin 恢复"，与 Windows 那份的直等断言刻意不同。
- `T55` set_text 自动重排（b6537ce）的同形缺口——set_style / set_insets 存值后现在也沿父链标脏：真窗口的 set_insets 同形测试（尺子是孩子的原生 origin：内边距 10 → 30 逻辑点两轴各挪 20，mac 侧 36/36 全绿）。
- 鼠标那两条在本机量到过环境性偶发红（有人在机器上动真鼠标时，真事件和脚手架的合成事件在同一支队列里交错，排好的抬起偶发整条没送进监听），空闲机器上连跑二十次单测加四次全套全绿——真鼠标在真窗口上本来就该赢，无头 CI（`T6`）上没有真指针，这条自然消失。

Windows 35 条（`backends/libui-windows`，2026-10-11 在那台机器整批跑绿 35/35，末行 `Total tests: 35, passed: 35, failed: 0.`）：代码里是 34 条（`backend_wbtest.mbt` 28 + `ffi_wbtest.mbt` 6），2026-10-10 整批跑绿、退出码 0；2026-10-11 加上 `T55` 的 set_insets 同形测试后整批 35 条再跑一遍全绿，同轮把 `T58` 的无障碍真验一并做了。此前在那台机器跑绿过 16 条（`T34`/`T36`，2026-10-09；上一轮 14 条也是同一台机器量的，那次跑的是同步过来的提交 `9acc6b5…`，核对走内容探针——那边的提交号与本仓库对不上，两边历史分叉），原先那条"菜单如实报不支持"的钉子随 `T22` 落地删掉了，补上的 18 条就是 TODO 里九批欠账的收口，每一批都在真跑里量出过至少一枚只有真窗口才有的牙：

- 剪贴板往返（`T37`）量出 `OpenClipboard` 会被系统的剪贴板监视进程短暂占住，adapter.c 的打开加了 10 次 × 10 毫秒的有界重试。
- 对话框与文件 / 保存 / 文件夹面板（`T43`/`T44`）把模态脚手架在那台机器上真走到面板跟前。
- 菜单栏那四条（`T45`）量出 `GetMenuItemInfoW` 读回的 fType 不带 `MF_POPUP` 位（本机探针实测 fType=0x0、hSubMenu 有值），子菜单只能认 `hSubMenu`，adapter.c 的快照函数为此改了一处。
- 键盘与焦点那三条（`T46`）量出真硬件发的 VK 是大写 `0x41`~`0x5A` 而查找表折成小写，`moonui_key_read_name` 补成两种都收、出口统一小写。
- 系统外观读数（`T47`）是那条几何测试按注册表读数的复跑。
- 缩放变化那两条（`T51`）在这台单屏机器走"不许冒多余的那条"分支。
- 按窗口的工作区那一条（`T52`）把 `MonitorFromWindow` 那两条从没进过编译器的入口第一次真编真跑。
- 鼠标那半那五条（`T53`）量出脚手架的滚轮格数要按 Win32 的规矩乘上 `WHEEL_DELTA` 进 HIWORD 才读得回来（投裸格数恒得 `Scroll(0,0)`），以及 BS_PUSHBUTTON 把 `WM_LBUTTONDBLCLK` 当一次按下、双击总账两边从此同形为 1 DoubleClick 配 2 Click 而不是 3——`adapter.h` 的判据段照实订正。

这台 Mac 给 Windows 那批到的还是类型检查，从 `T40` 起还多一道交叉预编译（`scripts/test-local.sh` 里若有 `x86_64-w64-mingw32-gcc` 就拿它把 `adapter.c` 过一遍 `-fsyntax-only -Wall`；第一次用就抓到 `MF_RADIOCHECK` 这个不存在的宏，正确拼写是 `MFT_RADIOCHECK`）。牙齿是往新测试里插一句不存在的名字：`T23` 那次是 `let _bogus_probe : Int = "teeth-check"` → Error 4014，`T22` 那次是把「菜单栏整棵装进活窗口的原生菜单位」那条里的 `menu_dump_full` 改成不存在的名字 → Error 4021 unbound；两次都当场改回，`moon check` 会说 `now up to date` 吃缓存，所以不发这一探针就不能说"读过这个文件"。顺带留一句 `T23` 那次真跑的收获，它揪出的是只有 Windows 才有的 bug——`moonui_widget_set_text` 原先直接发 `WM_SETTEXT`，绕过 libui 的 `inhibitChanged`，于是 Core 自己改文案会回声成一条多余的 `Input`，现在改成走 libui 的 setter。

`macos-backend-link` 为什么是"测试真跑 + 示例只连"而不是一条命令：闸门是 `moon test --target native backends/libui-macos`（2026-10-14 `T6` 起去掉 `--build-only`，44 条真窗口测试当场跑）+ `moon test --target native backends/native-macos`（原生 Cocoa 那半，14 条）+ `moon build --target native examples/hello-libui examples/counter-libui examples/form-libui examples/todo-libui examples/file-manager-libui examples/gallery-libui`（只连不跑，要真人关窗口）。听起来更直白的 `moon build backends/libui-macos` 在本机冷 target-dir 实测是**红的**——库包没有 `main`，`moon build` 照样去链接它，健康的树也报 `Undefined symbols: _main`。这几条盖的链接配置现在只有**一份**：仓库根 `prebuild-link.js`（moon.mod 的 `--moonbit-unstable-prebuild` 指过去，构建前注入 `backends/libui-macos`、顺 import 传给这几条命令要链接的每个可执行产物，TODO `T59`）。2026-10-11 之前是**六份**——库包 `backends/libui-macos/moon.pkg` 那一份，和 `examples/` 下五份可执行包各自 `moon.pkg` 里的副本（`link` 不顺着 import 传，副本会独自腐烂，在它进闸门之前没有任何 job 编过它）；五份副本是 2026-10-10 从一份涨上来的（`T28` 的 macOS 那半新建 counter / form / todo / file-manager 四份，每份把同一串 `-lobjc -framework Cocoa third-party/libui/lib/libui.a` 再抄一遍），`T59` 用 prebuild 机制收成了一份。产物凭什么算"真的链接过"：`nm` 数出来 428 个 `_ui*`/`_uipriv*`（只可能来自 `third-party/libui/lib/libui.a`）、49 个 `_moonui_*` 是已定义的外部符号（`adapter_macos.m` 编出来的），`_uiInit` 是 `T` 而不是 `U`，`otool -L` 里 Cocoa / AppKit / libobjc 三条 load command 都在。**这几个数里只有 `_moonui_*` 那一个当天就写明了口径（已定义的外部符号），`T22` 之后在同一道闸门上重数：它从 49 涨到 66**——ABI 从 47 个入口涨到 64 个，另加两个 `moonui_cocoa_*` 探针，逐条对得上；`T39` 之后在同一道口径下再数是 74（72 条 ABI 入口加那两个探针）；`T40` 之后在本机最近一次 mac 真窗口测试的产物（`_build/native/debug/test/backends/libui-macos/libui-macos.blackbox_test.exe`）上按同一条口径重数：**76**，逐条对得上——73 条 ABI 入口加三条 mac 专用探针（`moonui_cocoa_origin_of_widget` / `moonui_cocoa_cell_size_of_widget` / `moonui_cocoa_set_appearance_override`，最后那条是 `T40` 为外观断言加的进程级覆盖，申报在 `adapter_macos.m` 而不是 `adapter.h`，所以不进 ABI 计数）；同一条口径今天在本机全量重编之后的五份 `-native-macos` 可执行文件上各数了一遍，**五份都是 78**（`T42` 给 ABI 加了那两条按窗口的工作区入口，于是 75 条 ABI 入口加三条探针），`_uiInit` 五份都是 `T`，未定义的 `_moonui_*` 一份都是 0，这条数是本机量的，CI 那道闸门上的产物要等那一次真跑才算它自己的数；而那句"428 个 `_ui*`/`_uipriv*`"今天在同一份产物上数不出同一个数（`nm -g | grep ' _ui\| _uipriv'` 是 276 行，只算已定义是 269 个），当时用的到底是哪一条命令没写下来，所以链接这一格别再拿总数当尺子，判据留给"`_uiInit` 是 `T`、`_moonui_*` 全部已定义、三条 load command 都在"这三句。这些尺子来自链接器、`nm` 和 `otool`，不是我们自己的代码。这个 job 本身在 CI 上的第一次真跑没法本地验证——本仓库没有 remote，workflow 要推上去才跑得起。

快照测试和断言测试的取舍写在 AGENTS.md：稳定的结果用 `assert_eq`，结构化的调试输出用 `debug_inspect`。

## 平台支持

| 平台 | 后端 | 状态 |
| --- | --- | --- |
| Windows | 平台原生 API（Win32 直写，`adapter_native.c`） | 已接，§48-03/09~11/15 落地，§48-13 与勾选框由 `T23` 在那台机器跑绿（`T34`/`T36`）；§48-18/19/20 那四格（剪贴板、对话框、文件面板、菜单栏）加 §48-16 的键盘与焦点、§16 的系统外观、§48-21 的缩放变化、§12 的按窗口工作区、§30 的鼠标五变体，2026-10-10 全部在那台机器跑绿（`T37`/`T43`/`T44`/`T45`/`T46`/`T47`/`T51`/`T52`/`T53`，九批收口）。逐条钉了什么、各自量出过哪些只有真窗口才有的牙，见[「真窗口那两批逐条」](#真窗口那两批逐条)。CI 里现在有 `windows-backend-link` 的**链接**闸门（真窗口的测试还不在里面：无头 runner 起不起得来窗口没验过，见 `ci.yml` 文件头） |
| macOS | 平台原生 API（Cocoa 直写，`adapter_native.m`） | 已接，§48-03/09~11/15 落地（`backends/libui-macos/adapter_macos.m`），§48-13 与勾选框（`T23`）、§48-19 剪贴板（`T19`）、§48-18 对话框与文件面板（`T20`/`T21`）、§48-20 菜单栏（`T22`）、§48-16 键盘与焦点加鼠标（`T39`）、§16 系统外观（`T40`）、§48-21 缩放变化（`T24`）、§12 按窗口工作区（`T42`）都在这台机器跑绿。逐条钉了什么、各自量出过哪些只有真窗口才有的牙，见[「真窗口那两批逐条」](#真窗口那两批逐条)。libui 那套菜单 API 两侧都不能用的理由写在上面"现在能用什么"那一节。§49 六个 Demo 的真窗口版本就是 `examples/` 下那六份 `-libui`（此前两排平台壳分别于 2026-10-10 建好并真开过窗口——mac 那半 `T28`、Windows 那半 `T50`；2026-10-13 合并成单排 `T67`）。CI 里有 `macos-backend-link`：现编 `libui.a`，真跑 libui 那半 44 条与原生 Cocoa 那半 14 条真窗口测试（2026-10-14 `T6` 换上来），六份例子只连不跑 |
| Linux | 平台原生 API（GTK3 直写） | 未接：没有 GTK3 那份 Adapter，`build-libui.sh` 也只写了 darwin 这一支（TODO.md） |
| wasm | 无 | Core 的"不含任何 GUI 库"证明，CI 里当可移植性闸门 |

后端顺序按设计文档：Backend #1 曾是 libui-ng（真控件、原生外观）→ SDL3（自绘）→ 可能的 Win32/Cocoa/GTK 直连，见 §48 与 §51。第二个平台接上之后，"`Backend` 这个形状够不够"已经不只是推断了：`ffi.mbt` 与 `backend.mbt` 一行没改就能接 Cocoa，而 Cocoa 逼出来的差异全在 C 侧那一份文件里（单位是点、y 轴朝上、文案分居 `stringValue`/`title`、detach 是 `removeFromSuperview`）。剩下的形状风险只有一类：libui-ng 替两个平台都定不了的事（§32 的焦点链、自绘后端的帧），那些账在 TODO.md 的 Core 欠账一节。

## 约定

- 公共 API 一律逻辑像素，物理换算只发生在 `Scale` 里（§30）。macOS 上确实还有第二道换算，但它整段在 C 侧、只有一处（`adapter_macos.m:199-206` 的 `moonui_px_to_pt` / `moonui_pt_to_px`）：AppKit 收的是"点"，而 `adapter.h` 的契约是物理像素，于是 MoonUI 那次除法（DPI）和 Cocoa 那次除法（倍数）之间隔着这条 ABI，谁也不在自己的层里替对方换算。y 轴方向同理，只有 `moonui_flip_y` 一处。
- 样式由 Core 层叠（Theme → 父容器 → 自身），在 `Window::relayout` 里先下发给叶子后端、再测量：`widget_intrinsic_size` 报的就是后端当下持有那份样式下的尺寸（§15/§16/§18）。顺序反了就会拿旧字号的度量排新矩形。原生控件后端有权完全不读它——§32 要保住系统原生外观，这条豁免连同它的代价写在 `backends/libui-common/backend.mbt` 里。
- Core 不缓存窗口与控件状态，原生层是唯一事实来源；例外只有 min/max 约束、菜单勾选状态和快捷键表。
- 纯布局节点不占原生对象，叶子的原生父级只有窗口（§14）。
- 事件优先：`on_click` 只是 `Event::Click` 的过滤器糖，路由与派发在 `App` 一处完成（§10）。
- 无障碍视图是推导出来的，不是另登一份名册：Actions 来自事件订阅，State 来自原生层；纯布局节点只有显式声明 Role 才进视图（§32）。

## 接手开发

- 待办一律进 [TODO.md](TODO.md)：每条带日期、引 §48 步骤号、写清"现在什么是真的"，不写只有目标的一句话。已完成的满一个月就从文件里删掉（git log 是档案）；未完成的多久都留着，超期没动的通常正是最难那条。
- MoonBit 侧的写法约定、`moon info` / `moon fmt` / `moon test` 的收尾顺序在 [AGENTS.md](AGENTS.md)。
- 文中 `§nn` 是设计文档的小节号，留着是为了能和 README、代码注释、TODO 对上；§48 那条路线是当前进度轴。

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。（`T82` 前还 vendored 过 libui-ng 以固定提交单独检出到 `third-party/`，不入库，遵循它自己的 MIT 许可。
