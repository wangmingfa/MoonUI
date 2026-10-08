# MoonUI

MoonBit 的 GUI 框架。目标不是"libui-ng 的 MoonBit 绑定"，而是让 MoonBit 能写桌面应用的那层框架：布局、事件、控件、主题、HiDPI、菜单与对话框都在 Core 里定义，具体 GUI 库的差异留在 Backend 实现侧。

> MoonBit API 是第一公民，C 只是实现手段，libui-ng 只是 Backend #1，Backend 永远不能反向决定 MoonUI 的 API。

| | |
| --- | --- |
| 版本 | 0.1.0（后端无关的第一层已交付，真后端只有 Windows） |
| 工具链 | moon 0.1.20260920，`preferred_target = "native"` |
| 测试 | native 147 条 + libui 真窗口 14 条 + wasm 140 条 |
| CI | `.github/workflows/ci.yml`：`core`（三平台门禁）+ `core-portability`（wasm 证明 Core 不含任何 GUI 库） |
| 许可 | Apache-2.0 |
| 待办 | 全部记在 [TODO.md](TODO.md)，接力开发的规矩在 [AGENTS.md](AGENTS.md) |

## 它是什么，不是什么

是**框架**：Core 拥有布局算法、事件路由、句柄生命周期、样式与主题的层叠、无障碍视图的推导；后端只负责把算好的矩形和属性写进原生层，并把原生事件送回 `App`。

不是**绑定**：`uiButton*`、`HWND`、`SDL_Window*` 这类东西不出现在公共 API 上，它们被 `NativeHandle` 和 External 对象的生命周期挡在 Backend 实现侧。判据是可执行的——§47 第 6 条要求 Core 里绝不出现 libui / GTK / SDL / Win32 / Cocoa 这些字样，CI 用一条 wasm job 证明它（wasm 上根本没有 native FFI，能编译就说明这一层干净）。

## 快速开始（无头，三平台都行）

不需要任何 GUI 库，Core + `MockBackend` 就能写完、测完整个应用：

```sh
moon check --deny-warn          # 警告在本项目里是错误
moon test                       # 会连带编 backends/libui，见下一节
moon run examples/hello         # §49 五个 Demo 各是一个可执行包
moon run examples/counter       # 下面三个同理：form / todo / file-manager
```

只要 Core 那一层（macOS / unix 上目前只能这样）就把范围写出来，清单由 `scripts/ci-packages.sh` 打印——CI 用的就是同一份，两个 job 不会各说一套：

```sh
moon test $(bash scripts/ci-packages.sh packages examples tests _doccheck)
```

wasm 那一层不能整仓一条命令：`examples/hello-native` 是 native only 的**可执行**包，入口 .mbt 被门控掉之后 wasm 侧它没有 main，moon 报 4067。同一份脚本换一套目录参数就是 wasm 的口径（多带 `backends/`，`-native` 那条排除规则照旧）：

```sh
moon test --target wasm $(bash scripts/ci-packages.sh packages examples tests backends _doccheck)
```

## 真后端（Windows / libui-ng）

`moon test` 不带包路径时会连 `backends/libui` 一起编——跑起来就是桌面上真的开窗口、真的各按一次按钮，每条测试自己关掉了，不需要人工操作。但它要链接现编的 libui-ng，所以先跑一次构建脚本：

```sh
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-libui.ps1
moon test backends/libui        # 必须在仓库根跑：链接期的 /LIBPATH 是相对 shell 工作目录的
moon run examples/hello-native  # 同一份 Hello Demo 开真窗口：点按钮改文案，关窗口退出
```

`scripts/build-libui.ps1` 只做一件事：把 libui-ng 的固定提交（pin 在 `43ba1ef553c8993a43a67f1ce6e35983a2660d8c`）编成 `third-party/libui/lib/libui.a`，并把同提交的 `ui.h` 原样拷进 `backends/libui/`——那份头文件的 `git diff` 就是 ABI 漂移的信号。编法的三条理由（静态、/MT、release）写在脚本头部。工具链是 meson + ninja + Python，装在 `D:\Apps\moonui-toolchain`，不进 PATH、不写注册表；libui-ng 没有 CMake 工程，也不发布预编译包。`scripts/build-libui.sh`（unix / macOS）故意还没写：本机验不了，账记在 TODO.md。

`third-party/` 整个在 `.gitignore` 里，产物不入库。

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

真实后端按 §48 的顺序接到了第 11 步（`Backend` 实现 + 真窗口的 Hello Demo）与第 15 步（Stack 的层叠），目前只有 Windows：`backends/libui/` 是 libui-ng 的 C Adapter 与 MoonBit FFI 层，`moon test backends/libui` 会在桌面上真开窗口、把真按钮按 MoonUI 算出的矩形摆进客户区、按坐标真点一次，然后断言句柄表归零。

CI 绿**不等于**真后端绿——`backends/` 在 native 门禁里被有意排除（要链接现编的库、还要一只会点鼠标的手），本地必须跑上面那三条。

## 目录

§4 建议的结构里，只有已经存在的东西才有目录，没建的不留空壳：

```text
packages/moonui/  Core：error / geometry / event / style / theme / handle / layout
                  widget / window / app / backend trait / clipboard / dialog
                  menu / shortcut / accessibility + MockBackend + §49 五个 Demo
examples/         hello counter form todo file-manager 五个无头可执行包
                  + hello-native：同一份 Demo 跑真窗口，只在 native 下存在
tests/ffi/        §37 第二层：native FFI 探针（自包含 C stub，不依赖外部库）
backends/libui/   §48-03/09~11：libui-ng 的 C Adapter（adapter.c/.h）
                  + MoonBit FFI 层（ffi.mbt）+ @moonui.Backend 实现（backend.mbt）
scripts/          build-libui.ps1：从 pin 的提交现编 Windows 静态库
                  ci-packages.sh：CI 两个 job 共用的门禁包清单
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

## 真后端量出来的八件事

记下来免得再踩：

- **libui 的文案 getter 是分配语义。** `uiButtonText()` 返回它自己 malloc 的一份拷贝，契约要求调用方 `uiFreeText()`；Adapter 拷进 `Bytes` 之后就还掉。还漏一块的后果不是慢慢漏，是退出时炸。
- **`uiUninit()` 末尾审计 libui 自己的分配表，发现泄漏就直接 `DebugBreak()`**（libui-ng 的 release 构建也不关这条）。没有调试器时这就是一个退不出去的测试进程 / 0x80000003。所以 `terminate()` 的前提是 MoonBit 侧句柄表已经归零，里程碑测试断言的正是这一点。
- **`uiInit()` / `uiUninit()` 没有引用计数**，重复 init 会因窗口类已存在而失败。Adapter 把这一对守成幂等单例，同一个测试进程里跑两条冒烟才安全。
- **静态库带不进 manifest**，Common Controls v6 与 DPI 感知由 `adapter.c` 自己补（`#pragma comment(linker, ...)` + 建窗口前 `SetProcessDpiAwarenessContext`）。
- **链接参数里的 `-link` 前缀不能去。** 它是 moon 把后面一串参数转交给 link.exe 的通道，代价是每次链接多印一句 `LNK4044：无法识别的选项 "/link"，已忽略`——这条无害；去掉前缀就变成 `LNK1104：打不开 libui.a`。
- **`ChildWindowFromPoint` 和 `SetWindowPos` 在同一个坐标系里。** 前者收父窗口客户区坐标，后者摆的也是客户区，所以按坐标注入点击不需要任何换算；命不中子窗口时它返回父窗口自己，于是"点在空白处"和"控件摆错了位置"落在同一个负数返回上——点击因此能反过来验证布局矩形真的落到了原生 HWND。
- **`MsgWaitForMultipleObjects` 报的是"上次醒来之后新到的消息"，不是"队列里还有消息"。** 队列里有积压时它能一直返回 `WAIT_TIMEOUT`，而 WM_QUIT 就躺在队列里读不到——"等一次、走一步"的泵因此会在预算无限时空转。所以 `pump` 先用 `PeekMessage(PM_NOREMOVE)` 探测、把已有消息排干才去等，并且用墙钟（`GetTickCount64`）兜一条硬预算。libui 的 `uiMainStep(0)` 帮不上忙：它把"处理了一条"和"队列本来空"都返回 1，只有 WM_QUIT 返回 0。
- **`link` 只在可执行包里生效，不会顺着 import 传下来。** `backends/libui/moon.pkg` 声明的那串库对它的测试包够用（测试包本身就是可执行包），但 `examples/hello-native` 必须自己再写一遍，否则就是整套 53 条 LNK2019。那两份不是复制粘贴的疏忽，是 MoonBit 的链接模型。

### §14 的落点：控件按 HWND 自己摆

libui-ng 的 Windows 后端只有容器布局（uiBox / uiGrid / uiForm），没有绝对摆放；而 §14 要 MoonUI 自己做布局、纯布局节点不占原生对象、叶子的原生父级只有窗口，§32 又要真控件保住原生外观与无障碍。三条候选路里只有"绕过 libui 的布局层"同时保住这两条，所以 Adapter 用 `moonui_control_attach` 把控件的 HWND 从 libui 的隐藏工具窗口（`windows/control.cpp` 里所有控件出生时的 parent）搬进目标窗口客户区，再按 MoonUI 算出的矩形 `SetWindowPos`。

两条不变量支撑这条捷径，都是从 vendored 源码读出来、再被冒烟测试验证的：

- 回调路由按控件 HWND 查表（`windows/events.cpp` 的 `runWM_COMMAND` 拿 `lParam` 当键，不是控件 ID），所以换父级不影响 `WM_COMMAND`；顺带一提，控件挂在 utilWindow 下时这条路由是**故意被跳过**的，搬进真窗口才收得到点击。
- 主循环对顶层祖先跑 `IsDialogMessage`（`windows/main.cpp` 的 `processMessage`），键盘 Tab 因此照旧，只是顺序跟 z-order 走。所以首次挂载把控件插到 z-order 末尾——挂载顺序即 Tab 顺序；之后的重新布局只改矩形、不动 z-order，免得 resize 把焦点链重排一遍。

代价是 libui 的容器不再替窗口收尾：控件必须在所属窗口之前逐个 `destroy_button`，否则 `DestroyWindow` 连带释放 HWND，libui 那份控件对象却不回收，退出时的分配审计就把这次运行变成 `DebugBreak`。挂回调的控件由同一次 `destroy_button` 松开闭包引用（§47 风险 1：C 长期持有的闭包不 decref 就是泄漏，不 incref 就是悬垂）。

### §48-15 的落点：Stack 的层叠

原生层只有一份顺序，它同时管着"谁画在上面"和"谁先响应 Tab"，而挂载只能给一个方向。Stack 的契约（数组靠后的盖住靠前的）和挂载顺序正好相反，所以 `Backend::raise_widget` 提供"提到所在子窗口列表最上层"这一个动作，Core 在 `set_content` 挂完之后按每个 Stack 的数组顺序逐个提（`Widget::apply_layers`）——提完的层叠就是数组倒序。不含 Stack 的树一条都不提，"挂载顺序 = Tab 顺序"那条不变量照旧。

写出来的方向是被真窗口量过的，不是靠文档印象：`moonui_control_z_index` 读的是 `GetWindow(GW_HWNDPREV)` 的步数，0 = 最上层，Row 的三个控件得到 `[0, 1, 2]`，同样三个控件放进 Stack 得到 `[2, 1, 0]`。

没有量的那一维是 Tab 的落点：合成一条 `VK_TAB` 要先让测试进程抢到前台，而前台归属是这台机器的用户状态，实测落点跟着激活时序漂，所以没留这个脚手架（见 `adapter.h` 的说明）。这里也不需要它——叠放和 Tab 用的是同一条列表，翻了顺序就是同时翻了两者，方向本身是 Win32 的定义。

明说的代价：Stack 内部叶子的 Tab 变成数组倒序，而且这些叶子整体跳到树里其他控件前面。两者兼得要 Core 自己管焦点链，那是 §32 后续的事。

### 死在哪一次 FFI 调用

在 `backends/libui/moon.pkg` 的 `stub-cc-flags` 里加 `/DMOONUI_TRACE`：native 测试进程里 MoonBit 的 `println` 是全缓冲的，异常退出时整段丢失，只有 C 侧即时 `fflush` 的 trace 留得住顺序。

## 测试怎么分层

§37 的三层在前两层进了 CI 闸门，第三层只能本地跑（要现编的 GUI 库和一只真鼠标）：

| 层 | 跑什么 | 证明什么 |
| --- | --- | --- |
| 第一层：Core + Mock | `moon test packages/moonui` | 布局数值、事件路由、生命周期与句柄回收，全在 `MockBackend` 上，无头 |
| 第二层：FFI 探针 | `moon test tests/ffi` | 自包含 C stub，不依赖任何外部 GUI 库，只验 MoonBit ↔ C 这一对能不能通 |
| 第三层：真后端 | `moon test backends/libui` | 真开窗口、真摆放、真按一次坐标点击、真关闭，最后断言句柄表归零 |

另外两类不属于 §37 的分层，但同样在闸门里：`examples/*` 和 `_doccheck` 只用公开 API，公开 API 不够用就是该补 API 的信号；`moon test --target wasm` 证明 Core 与第一/第二层不含任何 GUI 库依赖（§47 第 6 条）。

快照测试和断言测试的取舍写在 AGENTS.md：稳定的结果用 `assert_eq`，结构化的调试输出用 `debug_inspect`。

## 平台支持

| 平台 | 后端 | 状态 |
| --- | --- | --- |
| Windows | libui-ng（Win32） | 已接，§48-03/09~11/15 落地，CI 排除（要现编的库和真鼠标） |
| macOS | libui-ng（Cocoa） | 未接：没有 `build-libui.sh`，Adapter 里 Win32 那半要换掉（TODO.md） |
| Linux | libui-ng（GTK3） | 未接，同上 |
| wasm | 无 | Core 的"不含任何 GUI 库"证明，CI 里当可移植性闸门 |

后端顺序按设计文档是 libui-ng（真控件、原生外观）→ SDL3（自绘）→ 可能的 Win32/Cocoa/GTK 直连，见 §48 与 §51。

## 约定

- 公共 API 一律逻辑像素，物理换算只发生在 `Scale` 里（§30）。
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
