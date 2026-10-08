# MoonUI

MoonBit 的 GUI 框架。目标不是"libui-ng 的 MoonBit 绑定"，而是让 MoonBit 能写桌面应用的那层框架：布局、事件、控件、主题、HiDPI、菜单与对话框都在 Core 里定义，具体 GUI 库的差异留在 Backend 实现侧。

> MoonBit API 是第一公民，C 只是实现手段，libui-ng 只是 Backend #1，Backend 永远不能反向决定 MoonUI 的 API。

| | |
| --- | --- |
| 版本 | 0.1.0（后端无关的第一层已交付，真后端有 Windows 与 macOS） |
| 工具链 | moon 0.1.20260920，`preferred_target = "native"` |
| 测试 | native 151 条 + wasm 144 条 + libui 真窗口 macOS 8 条（这三批在 macOS 2x 屏上刚跑过）；Windows 真窗口 14 条已在那台机器上复跑，14/14 全绿——核的是这轮的工作树内容，那边的提交号与本仓库对不上，细节记在 TODO.md |
| CI | `.github/workflows/ci.yml`：`core`（三平台门禁）+ `core-portability`（wasm 证明 Core 不含任何 GUI 库）+ `macos-backend-link`（macOS 真后端**链接**闸门：现编 `libui.a`，把后端包与 native 例子各连成可执行文件，不执行、不开窗口） |
| 许可 | Apache-2.0 |
| 设计文档 | [DESIGN.md](DESIGN.md)：51 节的初稿，README、TODO.md 和代码注释里那些 `§14`、`§48-09~11`、`§47 风险 1` 全部按它的小节号引用，所以编号不要重排 |
| 待办 | 全部记在 [TODO.md](TODO.md)，接力开发的规矩在 [AGENTS.md](AGENTS.md) |

## 它是什么，不是什么

是**框架**：Core 拥有布局算法、事件路由、句柄生命周期、样式与主题的层叠、无障碍视图的推导；后端只负责把算好的矩形和属性写进原生层，并把原生事件送回 `App`。

不是**绑定**：`uiButton*`、`HWND`、`SDL_Window*` 这类东西不出现在公共 API 上，它们被 `NativeHandle` 和 External 对象的生命周期挡在 Backend 实现侧。判据是可执行的——§47 第 6 条要求 Core 里绝不出现 libui / GTK / SDL / Win32 / Cocoa 这些字样，CI 用一条 wasm job 证明它（wasm 上根本没有 native FFI，能编译就说明这一层干净）。

## 快速开始（无头，三平台都行）

不需要任何 GUI 库，Core + `MockBackend` 就能写完、测完整个应用。本地门禁一条命令跑完，按宿主系统分叉（native 测试、五个 Demo、wasm 那一层、`.mbti` 与格式，Windows / macOS 上再加各自那批真窗口的测试）：

```sh
bash scripts/test-local.sh
```

拆开跑是这几条。`check` 不链接、也不编 C，所以四个 native only 的包（`backends/libui`、`backends/libui-macos`、`examples/hello-native`、`examples/hello-native-macos`）三平台都进得了闸门：

```sh
moon check --deny-warn          # 警告在本项目里是错误
moon run examples/hello         # §49 五个 Demo 各是一个可执行包
moon run examples/counter       # 下面三个同理：form / todo / file-manager
```

只有 `moon test` **不能在仓库根裸跑**：它会把 `backends/libui` 和 `examples/hello-native` 一起**链接**，而那两个包的链接参数是 MSVC 写法加一串 Windows 库。`moon.pkg` 的 `link` 只按输出后端（native / js / wasm）分档，没有宿主系统这一维，所以一份配置只能是一份：macOS / Linux 上 moon 驱动的是 clang，它把 `/` 开头的参数当文件路径，仓库根那条裸命令必然报

```
clang: error: no such file or directory: '/utf-8'
clang: error: no such file or directory: '/W3'
```

同一件事在 Windows 上反过来也成立（这条是推断，本机没有 Windows 可实测）：仓库根那条裸命令会去编 `backends/libui-macos/adapter_macos.m`，而那边没有 Cocoa。所以清单是**双向**排除的——`ci-packages.sh` 既不含 Windows 那两个包，也不含 macOS 那两个，真窗口那批由 `test-local.sh` 按 `uname -s` 各跑各的。

把测试范围写出来就行，清单由 `scripts/ci-packages.sh` 打印——`core` 与 `core-portability` 两个 job 用的就是同一份，不会各说一套（第三个 job `macos-backend-link` 按名字点两个 native 包，不共用这份清单）：

```sh
moon test $(bash scripts/ci-packages.sh packages examples tests _doccheck)
```

wasm 那一层不能整仓一条命令：`examples/hello-native` 是 native only 的**可执行**包，入口 .mbt 被门控掉之后 wasm 侧它没有 main，moon 报 4067。同一份脚本换一套目录参数就是 wasm 的口径（多带 `backends/`，`-native` 那条排除规则照旧）：

```sh
moon test --target wasm $(bash scripts/ci-packages.sh packages examples tests backends _doccheck)
```

每台机器哪几条能跑、哪几条跑不了，集中在「每个系统上分别跑什么」那张表里。

## 真后端（libui-ng：Windows 与 macOS）

`moon test backends/libui`（Windows）与 `moon test backends/libui-macos`（macOS）会连各自那份 C Adapter 一起编链——跑起来就是桌面上真的开窗口、真的各按一次按钮，每条测试自己关掉了，不需要人工操作。它们要链接现编的 libui-ng，所以先跑一次本平台的生产依赖：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-libui.ps1
moon test backends/libui        # 必须在仓库根跑：链接期的 /LIBPATH 是相对 shell 工作目录的
moon run examples/hello-native  # 同一份 Hello Demo 开真窗口：点按钮改文案，关窗口退出
```

```sh
bash scripts/build-libui.sh
moon test backends/libui-macos  # 同样必须在仓库根跑：链接参数里的 libui.a 是相对路径
moon run examples/hello-native-macos
```

两个构建脚本做的是同一件事：把 libui-ng 的固定提交（pin 在 `43ba1ef553c8993a43a67f1ce6e35983a2660d8c`）编成 `third-party/libui/lib/libui.a`，并把同提交的原生头文件原样拷进后端目录——那份头文件的 `git diff` 就是 ABI 漂移的信号。Windows 那半是 `ui.h` → `backends/libui/`，编法三条理由（静态、/MT、release）写在 `build-libui.ps1` 头部，工具链是 meson + ninja + Python，装在 `D:\Apps\moonui-toolchain`，不进 PATH、不写注册表。macOS 这半不用 meson：darwin 这条路径上 libui-ng 没有**配置期**依赖（`darwin/meson.build:56-62` 只要 `-lobjc` 和 Foundation/AppKit 两个 framework，`meson.build:69-79` 给的全部编译参数就是 `-mmacosx-version-min=10.8` 与两条 `-arch`），所以 `build-libui.sh` 直接把 `common/meson.build` 与 `darwin/meson.build` 的源清单交给 clang 逐个编，再 `xcrun libtool -static` 归档；头文件是 `ui.h` + `ui_darwin.h` → `backends/libui-macos/`，后者是 libui 的内部声明头，`uiControlHandle` 之外的一切都得从它拿。libui-ng 没有 CMake 工程，也不发布预编译包，所以两台机器上这步都是"从 pin 现编"；unix（GTK3）那半真的要 meson + pkg-config，还没写，账在 TODO.md。

平台分叉落在这**两份 C** 和它们的链接配置上，不在 MoonBit 层：Windows 那份是 `backends/libui/adapter.c`（整个文件被 `#if defined(_WIN32)` 包着——`native-stub` 会顺着 import 传到 macOS 那个包，所以在 clang 下它必须是个空翻译单元），macOS 那份是 `backends/libui-macos/adapter_macos.m`。MoonBit 侧共用 `backends/libui/` 的 `ffi.mbt`（47 条 `extern "c"`，0 个 Win32 名字）和 `backend.mbt`（42 个 trait 实现）。

**这句话已经被验证过一回，不再是推断**：接 Cocoa 时这两个 MoonBit 文件一行都没改（`git diff` 里它们不在改动清单上），新增的只有 `adapter_macos.m`、它的 `moon.pkg` 和 mac 那份真窗口测试。§47 风险 6 要的就是这条判据。Core 那一层更是与系统无关——同一份源码 native 与 wasm 两边全绿（§47 第 6 条）。

`third-party/` 整个在 `.gitignore` 里，产物不入库。

## 每个系统上分别跑什么

MoonBit 那几层三平台是同一份代码，差别只有一格：**能不能链接真后端**。装好 MoonBit 之后照这张表走（"同左"就是字面一样）：

| 想做的事 | Windows | macOS | Linux |
| --- | --- | --- | --- |
| 本地门禁，一条命令跑完 | `bash scripts/test-local.sh` | 同左 | 同左（到类型闸门为止） |
| 备真后端的依赖 | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-libui.ps1` | `bash scripts/build-libui.sh` | 还没有这条路（GTK3 那半在 TODO.md） |
| 无头测试（Core + MockBackend） | `moon test $(bash scripts/ci-packages.sh packages examples tests _doccheck)` | 同左 | 同左 |
| wasm 那一层（§47 第 6 条的证明） | `moon test --target wasm $(bash scripts/ci-packages.sh packages examples tests backends _doccheck)` | 同左 | 同左 |
| 类型闸门，含四个 native only 的包 | `moon check --deny-warn` | 同左 | 同左 |
| 接口与格式收尾 | `moon info && moon fmt`，然后提交 `.mbti` | 同左 | 同左 |
| 真窗口的测试 | `moon test backends/libui`（14 条） | `moon test backends/libui-macos`（8 条） | 跑不了：GTK3 那份 adapter 还没有 |
| 真窗口的 Hello Demo | `moon run examples/hello-native`（要真人点鼠标才退出） | `moon run examples/hello-native-macos`（同左的约束） | 跑不了，同上 |

四条会咬人的细节：

- **`moon test` 要带包清单**，除非你在 Windows 或 macOS 上且已经跑过本平台的构建脚本。`backends/libui/moon.pkg:31-32` 与 `examples/hello-native/moon.pkg:24-25` 写的是 MSVC 参数加一串 `.lib`，而 `moon.pkg` 的 `link` 只按输出后端（native / js / wasm）分档、分不出宿主系统，于是 macOS / Linux 上 clang 把 `/utf-8` 当文件名——报错是 51 行 `clang: error: no such file or directory`（`/utf-8`、`/LIBPATH:…` 加上那 15 个 `.lib` 各一行，三个链接目标各一组），本机能原样复现，看到它就是跑错平台了。**Windows 那一侧的对应结论现在是实测不是推断**：同一份 MSVC 写法在那台机器上链接通过、14 条真窗口的测试全绿，`/LIBPATH` 确实生效（不生效就是 LNK2019，`uiNewWindow` 那批符号找不到）；`adapter.c` 也没有报 `C4819` 之类的编码错，说明用文件头 BOM 顶替 `stub-cc-flags: "/utf-8 /W3"` 这条路成立。唯一带出来的噪音是三个测试二进制各印一条 `LNK4044: unrecognized option '/link'; ignored`——`cc-link-flags` 开头那个 `-link` 被链接器当陌生选项忽略了，链接照样成功（要不要去掉它只有 Windows 能验，已挂账 TODO）。反过来在 Windows 上**裸跑** `moon test` 会去编 `adapter_macos.m`，那边没有 Cocoa（这半仍是推断，那台机器上只跑了 `moon test backends/libui`，没跑裸的）。`moon check` 和 `moon info` 两头的坑都不沾，它们不链接、也不编 C，所以两个真后端的类型闸门在三个平台上都跑得动。
- **所有 `moon` 命令都在仓库根跑**：`/LIBPATH:"third-party/libui/lib"` 和 macOS 那串里的 `third-party/libui/lib/libui.a` 都是相对当前工作目录展开的。`scripts/test-local.sh` 自己 `cd` 到根，从哪儿调用都可以。
- **Windows 上那个 bash 是 git-bash**：脚本认 `uname -s` 的 `MINGW*` / `MSYS*` / `CYGWIN*` / `Windows_NT`，用纯 PowerShell 时没有 `bash`，就按表里逐条手敲。
- **表里"备真后端的依赖"那一格，Windows 侧要自己装 Meson，macOS 侧什么都不用装。** libui-ng 既不发布预编译包、也没有 CMake 工程，只认 meson，所以 `scripts/build-libui.ps1` 跑的是 `meson setup` + `meson compile`（:120 与 :142），前提是 **Meson 加 Ninja** 都在 PATH 上。最省事的是官方 MSI，它一次把两个都装上：在 https://github.com/mesonbuild/meson/releases 取最新 release 资产里的 `.msi`（装进 Program Files 要管理员；本机装出来的就是 `D:\Program Files\Meson\` 里的 `meson.exe` + `ninja.exe`）。**装完要另开一个 PowerShell**——PATH 不会刷新到已开的窗口里，脚本那句 `Get-Command meson`（:75）照样找不到。不想升管理员、机器上有真 Python 的话 `py -3 -m pip install meson ninja` 也够（别用 `...WindowsApps\python.exe`，Version `0.0.0.0` 那个是 Microsoft Store 的执行别名占位，不是 Python）；两条都不走就用脚本认的第一个入口——`$env:MOONUI_MESON` 指到 `meson.exe`（:73）。这一步另外还吃两样：`git` 在 PATH 上（要 `git fetch --depth 1` 取 pin 的提交），以及装了 MSVC 的 C++ 工作负载。**但光有 VS 不够，普通 PowerShell 里 `meson setup` 会失败**（Windows 实测）：

  ```
  third-party\libui\src\meson.build:6:0: ERROR: Found GNU link.exe instead of MSVC link.exe
  in C:\Program Files\Git\usr\bin\link.EXE. This link.exe is not a linker.
  ```

  那是 **Git for Windows 附带的 coreutils `link.exe`**（创建硬链接那个）抢在 MSVC 的链接器前面，而上面第三格里"Windows 上那个 bash 是 git-bash"要求装的正是同一个 Git——所以这条撞上是常态，不是配置错了机器。办法是先初始化 VS 的开发环境再跑脚本，同一个 PowerShell 里：

  ```powershell
  & 'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\Launch-VsDevShell.ps1' -Arch amd64 -SkipAutomaticLocation
  cd F:\shared\MoonUI   # 仓库根
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-libui.ps1
  ```

  （或者从开始菜单开 "x64 Native Tools Command Prompt for VS 2022" 再 `cd` 到仓库根；`Community` 那段按你的版本换 `Professional` / `Enterprise` / `BuildTools`。）脚本现在在 `meson setup` 失败时把这段 remedy 原样打出来。macOS 那半不经 meson：darwin 这条路径的配置期依赖只有 `-lobjc` 和两个 framework，`scripts/build-libui.sh` 按 `common/meson.build` + `darwin/meson.build` 的源清单逐个 clang、再 `xcrun libtool -static` 归档，所以本机一个安装包都不用手点。

`scripts/test-local.sh` 在 Windows 和 macOS 上各多跑本平台那批真窗口的测试，缺 `libui.a` 会明确停下并提示先跑对应的构建脚本，不会"跳过然后照样报绿"；Linux 上它到类型闸门为止。

## 现在能用什么

0.1 阶段交付的是**后端无关的第一层**，全部有测试覆盖：

| 层 | 内容 |
| --- | --- |
| Core 类型 | `UiError`、几何（逻辑/物理像素、`Scale`）、`Event`、`Style`/`Theme` |
| 布局 | Row / Column / Padding / Spacer / Center / Stack / Grid / Scroll |
| 生命周期 | `NativeHandle` + 句柄表（generation 防悬垂）、`App` 事件主循环 |
| 界面对象 | `Window`、`Widget`（Label / Button / TextInput / Checkbox） |
| 平台能力接口 | 剪贴板、对话框、菜单栏 + 快捷键、`Backend` trait |
| 无障碍视图 | Role / Label / Description / State / Actions 的推导与声明（§32） |
| 示例 | §49 五个 Demo：Hello / Counter / Login / Todo / File Manager，各自是 `examples/` 下的可执行包 |
| 测试后端 | `MockBackend`：无头跑完整事件循环与布局数值 |

真实后端按 §48 的顺序接到了第 11 步（`Backend` 实现 + 真窗口的 Hello Demo）与第 15 步（Stack 的层叠），两个平台上都有：`backends/libui/` 是共享的 MoonBit FFI 层与 `@moonui.Backend` 实现加 Windows 那份 C Adapter，`backends/libui-macos/` 只有 Cocoa 那份 C 和它的链接配置。两边的 `moon test` 都会在桌面上真开窗口、把真按钮按 MoonUI 算出的矩形摆进客户区、按坐标真点一次，然后断言句柄表归零。

CI 绿**不等于**真后端绿——`backends/` 在 native 门禁里被有意排除（要链接现编的库、还要一只会点鼠标的手），本地必须跑上面那两条真窗口的测试。

## 目录

§4 建议的结构里，只有已经存在的东西才有目录，没建的不留空壳：

```text
packages/moonui/  Core：error / geometry / event / style / theme / handle / layout
                  widget / window / app / backend trait / clipboard / dialog
                  menu / shortcut / accessibility + MockBackend + §49 五个 Demo
examples/         hello counter form todo file-manager 五个无头可执行包
                  + hello-native / hello-native-macos：同一份 Demo 跑真窗口，
                    各自只在 native 下存在，也各自只在对应平台的宿主上编得动
tests/ffi/        §37 第二层：native FFI 探针（自包含 C stub，不依赖外部库）
backends/libui/   §48-03/09~11：libui-ng 的 MoonBit FFI 层（ffi.mbt）+
                  @moonui.Backend 实现（backend.mbt）+ Windows 的 C Adapter
                  （adapter.c/.h，整个文件在 #if defined(_WIN32) 里）
backends/libui-macos/
                  §48-03 的 macOS 半：只有 Cocoa 的 C Adapter（adapter_macos.m）
                  和它的链接配置，MoonBit 侧 import 上面那个包
scripts/          build-libui.ps1 / build-libui.sh：从 pin 的提交现编静态库
                  （前者 Windows，后者 macOS；产物都是 third-party/libui/lib/）
                  ci-packages.sh：core 与 core-portability 两个 job 共用的门禁包清单
                  test-local.sh：本地一条命令的门禁，按宿主系统分叉
_doccheck/        README 那段代码的独立包验证
third-party/      libui-ng 的检出与构建产物，全部不入库（.gitignore）
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

记下来免得再踩。Windows 那半（Win32 + libui-ng 的 `windows/`）八条：

- **libui 的文案 getter 是分配语义。** `uiButtonText()` 返回它自己 malloc 的一份拷贝，契约要求调用方 `uiFreeText()`；Adapter 拷进 `Bytes` 之后就还掉。还漏一块的后果不是慢慢漏，是退出时炸。
- **`uiUninit()` 末尾审计 libui 自己的分配表，发现泄漏就直接 `DebugBreak()`**（libui-ng 的 release 构建也不关这条）。没有调试器时这就是一个退不出去的测试进程 / 0x80000003。所以 `terminate()` 的前提是 MoonBit 侧句柄表已经归零，里程碑测试断言的正是这一点。
- **`uiInit()` / `uiUninit()` 没有引用计数**，重复 init 会因窗口类已存在而失败。Adapter 把这一对守成幂等单例，同一个测试进程里跑两条冒烟才安全。
- **静态库带不进 manifest**，Common Controls v6 与 DPI 感知由 `adapter.c` 自己补（`#pragma comment(linker, ...)` + 建窗口前 `SetProcessDpiAwarenessContext`）。
- **链接参数里的 `-link` 前缀不能去。** 它是 moon 把后面一串参数转交给 link.exe 的通道，代价是每次链接多印一句 `LNK4044：无法识别的选项 "/link"，已忽略`——这条无害；去掉前缀就变成 `LNK1104：打不开 libui.a`。
- **`ChildWindowFromPoint` 和 `SetWindowPos` 在同一个坐标系里。** 前者收父窗口客户区坐标，后者摆的也是客户区，所以按坐标注入点击不需要任何换算；命不中子窗口时它返回父窗口自己，于是"点在空白处"和"控件摆错了位置"落在同一个负数返回上——点击因此能反过来验证布局矩形真的落到了原生 HWND。
- **`MsgWaitForMultipleObjects` 报的是"上次醒来之后新到的消息"，不是"队列里还有消息"。** 队列里有积压时它能一直返回 `WAIT_TIMEOUT`，而 WM_QUIT 就躺在队列里读不到——"等一次、走一步"的泵因此会在预算无限时空转。所以 `pump` 先用 `PeekMessage(PM_NOREMOVE)` 探测、把已有消息排干才去等，并且用墙钟（`GetTickCount64`）兜一条硬预算。libui 的 `uiMainStep(0)` 帮不上忙：它把"处理了一条"和"队列本来空"都返回 1，只有 WM_QUIT 返回 0。
- **`link` 只在可执行包里生效，不会顺着 import 传下来。** `backends/libui/moon.pkg` 声明的那串库对它的测试包够用（测试包本身就是可执行包），但 `examples/hello-native` 必须自己再写一遍，否则就是整套 53 条 LNK2019。那两份不是复制粘贴的疏忽，是 MoonBit 的链接模型。

macOS 那半（Cocoa + libui-ng 的 `darwin/`）另加七条：

- **自动释放池是栈式的，而 `uiInit` 自己压了一层。** 把 `uiInit`/`uiUninit` 包进 `@autoreleasepool` 就是弹非栈顶的池，运行期直接 fatal（`objc: Invalid or prematurely-freed autorelease pool`），而且测试进程一行输出都不留——因为 `uiInit` 压进去的那层（libui 的 `globalPool`）活得比这次调用久。做法是自己 alloc 一层存在 `adapter_macos.m:89`，`uiUninit` 之后才 drain；`uiMainSteps`/`uiMainStep`/`uiQuit` 三个循环入口干脆不套池，AppKit 的事件对象不归本次调用管。
- **翻折自逆，所以方向单靠自己测不出来。** MoonUI 的矩形从左上量，Cocoa 的 view 从左下量，这一翻写在 `moonui_flip_y`（`adapter_macos.m:227`）里、摆位和读数共用一条公式。负控制实测：把它改成恒等，"控件矩形往返"那条的坐标断言**一条都没红**——写反的两次翻折仍然互相抵消。要钉住方向必须引入一个不经过这条路径的坐标，于是有了 `moonui_cocoa_origin_of_widget`（同文件 :1147）：顶边的控件在 Cocoa 原始 frame 里 `origin.y` 必须接近"父视图高 - 控件高"，这一条是全 suite 里唯一为方向红的。共享实现里所有别的坐标断言都做不到这件事。（那次运行其余几条也红，是 `native_live_handles()` 量的那张**进程全局**表被中途 raise 的测试污染：raise 跳过它自己的 `terminate()`，而表在 `backends/libui/ffi.mbt:17`、跟后端实例无关。这条已经修掉——`macos_test.mbt` 里每条测试开头替上一条补跑一次 `terminate()`（`sweep_leaked_handles`），实测注入一条故意失败的测试时红数从"9 条红 8 条"收到只红它自己，把清场改成空转又回到 8 条。更自然的 `defer` 写法走不通：MoonBit 的 panic 不执行 defer，本机量过。）
- **AppKit 不给出 `buttonType` 的读取口。** 只有 `setButtonType:`，所以 `-[NSButtonCell buttonType]` 在运行期是 unrecognized selector（实测崩在测试脚手架里）。想在 Cocoa 上把 checkbox 从"按钮"里剔出去得去问无障碍角色；而 Win32 那份本来也没剔（它的类名判断同样把 BS_CHECKBOX 算进 Button），所以两边按 `isKindOfClass:[NSButton class]` 一致，反而不用细分。
- **Cocoa 的层叠就是 `subviews` 数组顺序，和 Win32 是同一种话。** "Cocoa 没有 z-order"这句先前的判断是错的：数组末尾画在最上面，`addSubview:positioned:NSWindowBelow`（:851）就是 `SetWindowPos(HWND_BOTTOM)`，`NSWindowAbove` 就是 `HWND_TOP`。所以两个后端量出来的数一模一样——Row 得 `[0,1,2]`，同样三个控件放进 Stack 得 `[2,1,0]`（`backends/libui-macos/macos_test.mbt` 与 Windows 那份 `backend_wbtest.mbt` 各钉一条）。层叠与 Tab 在两边也确实共用同一条列表：Cocoa 靠 `setAutorecalculatesKeyViewLoop:` 按 subviews 顺序重算焦点链。
- **点是单位，Retina 是倍数。** libui-ng 的 darwin 后端根本没有 DPI 概念，`backingScaleFactor` 就是全部信息，于是 `moonui_window_dpi` 报的是倍数乘 96（本机 Retina 读出 192）。控件矩形这里过一道 px→点→px，AppKit 存的是小数坐标，所以往返自逆、断言能写到 1 逻辑像素内；而 libui 收 int 的入口（窗口尺寸、窗口位置）只吃整点，窗口级的量最坏差 1 物理像素——这就是 mac 那份测试的容差比 Windows 那份松一格的原因。
- **`uiQuit` 是 `[NSApp terminate:]`，但在 steps 模式下它只把循环标成"跑完了"。** 实测调用后进程照常在，`uiMainStep` 从这里开始返回 0，之后还能再 init 一轮——所以共享实现里 `loop_ended` 那条判定在 mac 上也成立，测试敢调它。
- **darwin 的 libui 把"固有尺寸"整个交给了 Auto Layout，`ui_darwin.h` 里没有 minimum size 的对应物。** 于是 §18 那句"量由原生层做"在 mac 上是直接问 AppKit，而且要同时问两条再**逐维取大**（`adapter_macos.m:731` 起）：`intrinsicContentSize` 和 `[cell cellSize]`（后者正是 NSButton 自己算固有尺寸的算法）。只取前一条会截字——实测 label 报 81.5 而 cell 要 85.3，按钮 72x20 而 86x32，勾选框 63x16 而 65x18；差的那几像素是边框的 `alignmentRectInsets`（按钮左右各 7pt），标题在 72pt 的 frame 里只拿到 48pt，而 "Click Me" 要 52pt，于是 Demo 上显示成 "Click M"。反过来 TextInput 的 `intrinsicContentSize`（宽 96）比 `cellSize`（66）大，那是可编辑区的最小宽度而不是截字，所以取大不会把它压小。测试那条对照组直接读 AppKit 的 `[cell cellSize]`（`moonui_cocoa_cell_size_of_widget`，同文件 :1180），不拿我们自己的数字当尺子；把实现改回只取 `intrinsicContentSize`，label、按钮、勾选框三条一起红。控件 view 一出生也没有 superview（darwin 的控件构造只 alloc/init，挂进窗口是 libui 自己的 `SetSuperview` 的事，而我们从不叫它），所以"搬进窗口客户区"这一步在 mac 上比 Windows 还短——就是 `addSubview:`。

### §14 的落点：控件按 HWND 自己摆

libui-ng 的 Windows 后端只有容器布局（uiBox / uiGrid / uiForm），没有绝对摆放；而 §14 要 MoonUI 自己做布局、纯布局节点不占原生对象、叶子的原生父级只有窗口，§32 又要真控件保住原生外观与无障碍。三条候选路里只有"绕过 libui 的布局层"同时保住这两条，所以 Adapter 用 `moonui_control_attach` 把控件的 HWND 从 libui 的隐藏工具窗口（`windows/control.cpp` 里所有控件出生时的 parent）搬进目标窗口客户区，再按 MoonUI 算出的矩形 `SetWindowPos`。

两条不变量支撑这条捷径，都是从 vendored 源码读出来、再被冒烟测试验证的：

- 回调路由按控件 HWND 查表（`windows/events.cpp` 的 `runWM_COMMAND` 拿 `lParam` 当键，不是控件 ID），所以换父级不影响 `WM_COMMAND`；顺带一提，控件挂在 utilWindow 下时这条路由是**故意被跳过**的，搬进真窗口才收得到点击。
- 主循环对顶层祖先跑 `IsDialogMessage`（`windows/main.cpp` 的 `processMessage`），键盘 Tab 因此照旧，只是顺序跟 z-order 走。所以首次挂载把控件插到 z-order 末尾——挂载顺序即 Tab 顺序；之后的重新布局只改矩形、不动 z-order，免得 resize 把焦点链重排一遍。

代价是 libui 的容器不再替窗口收尾：控件必须在所属窗口之前逐个 `destroy_button`，否则 `DestroyWindow` 连带释放 HWND，libui 那份控件对象却不回收，退出时的分配审计就把这次运行变成 `DebugBreak`。挂回调的控件由同一次 `destroy_button` 松开闭包引用（§47 风险 1：C 长期持有的闭包不 decref 就是泄漏，不 incref 就是悬垂）。

Cocoa 那份把同一件事又做了一遍，而且更短：`moonui_control_attach` 就是 `[contentView addSubview:v positioned:NSWindowBelow]` 加一句 `setTranslatesAutoresizingMaskIntoConstraints:YES`（`adapter_macos.m:834-853`）——后者是"这个 view 的 frame 由 MoonUI 管，别给它生成约束"的正式写法，而 libui 自己的容器布局站在反方向（NO + Auto Layout），既然不建 `uiBox` 就必须站到 YES 这边，否则第一次 layout 就把 `setFrame:` 的结果覆盖掉。回调路由也不看父级：action 落在控件自己的 target 上。收尾那条代价两边同名，只是 mac 上是"view 还留在 subviews 里而它的 libui 对象已经没了"，所以 `moonui_widget_destroy` 里先 `removeFromSuperview`。

### §48-15 的落点：Stack 的层叠

原生层只有一份顺序，它同时管着"谁画在上面"和"谁先响应 Tab"，而挂载只能给一个方向。Stack 的契约（数组靠后的盖住靠前的）和挂载顺序正好相反，所以 `Backend::raise_widget` 提供"提到所在子窗口列表最上层"这一个动作，Core 在 `set_content` 挂完之后按每个 Stack 的数组顺序逐个提（`Widget::apply_layers`）——提完的层叠就是数组倒序。不含 Stack 的树一条都不提，"挂载顺序 = Tab 顺序"那条不变量照旧。

写出来的方向是被真窗口量过的，不是靠文档印象：`moonui_control_z_index` 在 Windows 读 `GetWindow(GW_HWNDPREV)` 的步数，在 macOS 从 `subviews` 数组末尾倒数，两边都是 0 = 最上层。同一组控件在两个后端上给同一组数——Row 的三个控件 `[0, 1, 2]`，同样三个控件放进 Stack `[2, 1, 0]`（`backends/libui/backend_wbtest.mbt` 与 `backends/libui-macos/macos_test.mbt` 各钉一条）。这不是巧合，是挂载时 `HWND_BOTTOM` 对 `NSWindowBelow`、raise 时 `HWND_TOP` 对 `NSWindowAbove` 写成了同一种话的结果；"Cocoa 没有 z-order"那句旧话就是在这里被推翻的。Core 的 `apply_layers` 因此可以只写一遍。

没有量的那一维是 Tab 的落点：合成一条 `VK_TAB` 要先让测试进程抢到前台，而前台归属是这台机器的用户状态，实测落点跟着激活时序漂，所以没留这个脚手架（见 `adapter.h` 的说明）。这里也不需要它——叠放和 Tab 用的是同一条列表，翻了顺序就是同时翻了两者，方向本身是 Win32 的定义。

明说的代价：Stack 内部叶子的 Tab 变成数组倒序，而且这些叶子整体跳到树里其他控件前面。两者兼得要 Core 自己管焦点链，那是 §32 后续的事。

### 死在哪一次 FFI 调用

两份 Adapter 都有 `TRACE(...)`，打开方式是在对应包的 `moon.pkg` 里临时加回 `stub-cc-flags`：Windows 那半 `"-DMOONUI_TRACE"` 在 `backends/libui`，macOS 那半在同一条字段、写在 `backends/libui-macos`。这条现在得手写、不能常驻，正是 `stub-cc-flags` 被从 `backends/libui/moon.pkg` 里去掉的原因——`native-stub` 顺着 import 传，一份 flags 会同时喂给 cl 和 clang，而两边只有 `-D` 与 `/D` 这一字之差。加回来验完就删，别把它留在库里。

为什么需要它：native 测试进程里 MoonBit 的 `println` 是全缓冲的，异常退出时整段丢失（macOS 上第一次撞自动释放池那次就是零输出），只有 C 侧即时 `fflush` 的 trace 留得住顺序。

## 测试怎么分层

§37 的三层在前两层进了 CI 闸门；第三层今天进去的是**链接**那一半——`macos-backend-link` 现编 `libui.a`，把 `backends/libui-macos` 的测试二进制和 `examples/hello-native-macos` 各连成可执行文件（`moon test --build-only` / `moon build`，都不执行产物），跑的是"这份 Cocoa 的 Adapter 还连不连得上现编的 libui-ng 与 `adapter.h` 那套 ABI"。运行时那一半仍只能本地跑，因为它要的 CI 上没有：一只真鼠标，以及一个不一定存在、能让 `NSApplication` 起得来的登录会话。

| 层 | 跑什么 | 证明什么 |
| --- | --- | --- |
| 第一层：Core + Mock | `moon test packages/moonui` | 布局数值、事件路由、生命周期与句柄回收，全在 `MockBackend` 上，无头 |
| 第二层：FFI 探针 | `moon test tests/ffi` | 自包含 C stub，不依赖任何外部 GUI 库，只验 MoonBit ↔ C 这一对能不能通 |
| 第三层：真后端 | `moon test backends/libui`（Windows）、`moon test backends/libui-macos`（macOS） | 真开窗口、真摆放、真按一次坐标点击、真关闭，最后断言句柄表归零 |

另外两类不属于 §37 的分层，但同样在闸门里：`examples/*` 和 `_doccheck` 只用公开 API，公开 API 不够用就是该补 API 的信号；`moon test --target wasm` 证明 Core 与第一/第二层不含任何 GUI 库依赖（§47 第 6 条）。

`macos-backend-link` 为什么是两条命令而不是一条：闸门是 `moon test --build-only --target native backends/libui-macos` + `moon build --target native examples/hello-native-macos`。听起来更直白的 `moon build backends/libui-macos` 在本机冷 target-dir 实测是**红的**——库包没有 `main`，`moon build` 照样去链接它，健康的树也报 `Undefined symbols: _main`。两条各盖一份 `link` 配置：库包 `backends/libui-macos/moon.pkg:31` 那份，和可执行包 `examples/hello-native-macos/moon.pkg:34` 里那份副本（`link` 不顺着 import 传，副本会独自腐烂，在它进闸门之前没有任何 job 编过它）。产物凭什么算"真的链接过"：`nm` 数出来 428 个 `_ui*`/`_uipriv*`（只可能来自 `third-party/libui/lib/libui.a`）、49 个 `_moonui_*` 是已定义的外部符号（`adapter_macos.m` 编出来的），`_uiInit` 是 `T` 而不是 `U`，`otool -L` 里 Cocoa / AppKit / libobjc 三条 load command 都在。这些尺子来自链接器、`nm` 和 `otool`，不是我们自己的代码。这个 job 本身在 CI 上的第一次真跑没法本地验证——本仓库没有 remote，workflow 要推上去才跑得起。

快照测试和断言测试的取舍写在 AGENTS.md：稳定的结果用 `assert_eq`，结构化的调试输出用 `debug_inspect`。

## 平台支持

| 平台 | 后端 | 状态 |
| --- | --- | --- |
| Windows | libui-ng（Win32） | 已接，§48-03/09~11/15 落地，CI 里没有它（链接要 Meson MSI + VS 开发环境，测试要真鼠标；见 `ci.yml` 文件头） |
| macOS | libui-ng（Cocoa） | 已接，§48-03/09~11/15 落地（`backends/libui-macos/adapter_macos.m`）。CI 里有 `macos-backend-link`：现编 `libui.a` 并把两个 native 产物连出来，**只链接、不开窗口**，那 8 条真窗口的测试仍在本地 |
| Linux | libui-ng（GTK3） | 未接：没有 GTK3 那份 Adapter，`build-libui.sh` 也只写了 darwin 这一支（TODO.md） |
| wasm | 无 | Core 的"不含任何 GUI 库"证明，CI 里当可移植性闸门 |

后端顺序按设计文档是 libui-ng（真控件、原生外观）→ SDL3（自绘）→ 可能的 Win32/Cocoa/GTK 直连，见 §48 与 §51。第二个平台接上之后，"`Backend` 这个形状够不够"已经不只是推断了：`ffi.mbt` 与 `backend.mbt` 一行没改就能接 Cocoa，而 Cocoa 逼出来的差异全在 C 侧那一份文件里（单位是点、y 轴朝上、文案分居 `stringValue`/`title`、detach 是 `removeFromSuperview`）。剩下的形状风险只有一类：libui-ng 替两个平台都定不了的事（§32 的焦点链、自绘后端的帧），那些账在 TODO.md 的 Core 欠账一节。

## 约定

- 公共 API 一律逻辑像素，物理换算只发生在 `Scale` 里（§30）。macOS 上确实还有第二道换算，但它整段在 C 侧、只有一处（`adapter_macos.m:199-206` 的 `moonui_px_to_pt` / `moonui_pt_to_px`）：AppKit 收的是"点"，而 `adapter.h` 的契约是物理像素，于是 MoonUI 那次除法（DPI）和 Cocoa 那次除法（倍数）之间隔着这条 ABI，谁也不在自己的层里替对方换算。y 轴方向同理，只有 `moonui_flip_y` 一处。
- 样式由 Core 层叠（Theme → 父容器 → 自身），在 `Window::relayout` 里先下发给叶子后端、再测量：`widget_intrinsic_size` 报的就是后端当下持有那份样式下的尺寸（§15/§16/§18）。顺序反了就会拿旧字号的度量排新矩形。原生控件后端有权完全不读它——§32 要保住系统原生外观，这条豁免连同它的代价写在 `backends/libui/backend.mbt` 里。
- Core 不缓存窗口与控件状态，原生层是唯一事实来源；例外只有 min/max 约束、菜单勾选状态和快捷键表。
- 纯布局节点不占原生对象，叶子的原生父级只有窗口（§14）。
- 事件优先：`on_click` 只是 `Event::Click` 的过滤器糖，路由与派发在 `App` 一处完成（§10）。
- 无障碍视图是推导出来的，不是另登一份名册：Actions 来自事件订阅，State 来自原生层；纯布局节点只有显式声明 Role 才进视图（§32）。

## 接手开发

- 待办一律进 [TODO.md](TODO.md)：每条带日期、引 §48 步骤号、写清"现在什么是真的"，不写只有目标的一句话。已完成的满一个月就从文件里删掉（git log 是档案）；未完成的多久都留着，超期没动的通常正是最难那条。
- MoonBit 侧的写法约定、`moon info` / `moon fmt` / `moon test` 的收尾顺序在 [AGENTS.md](AGENTS.md)。
- 文中 `§nn` 是设计文档的小节号，留着是为了能和 README、代码注释、TODO 对上；§48 那条路线是当前进度轴。

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。libui-ng 以固定提交单独检出到 `third-party/`，不入库，遵循它自己的 MIT 许可。
