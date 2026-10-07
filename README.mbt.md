# MoonUI

MoonBit 的 GUI 框架。目标不是"libui-ng 的 MoonBit 绑定"，而是让 MoonBit 能写桌面应用的那层框架：布局、事件、控件、主题、HiDPI、菜单与对话框都在 Core 里定义，具体 GUI 库的差异留在 Backend 实现侧。

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

真实后端按 §48 的顺序接到了第 03 步（C Adapter + 最小 FFI 闭环），并且 §14 与 libui 容器布局的取舍已经落地（见下面那一节），目前只有 Windows：`backends/libui/` 是 libui-ng 的 C Adapter 与 MoonBit FFI 层，`moon test backends/libui` 会在桌面上真开窗口、把真按钮按 MoonUI 算出的矩形摆进客户区、按坐标真点一次，然后断言句柄表归零。libui-ng 的产物不入库，要用 `scripts/build-libui.ps1` 从固定提交现编。`Backend` 实现、macOS/unix 后端还没写。

## 目录

§4 建议的结构里，只有已经存在的东西才有目录，没建的不留空壳：

```text
packages/moonui/  Core：error / geometry / event / style / theme / handle / layout
                  widget / window / app / backend trait / clipboard / dialog
                  menu / shortcut / accessibility + MockBackend + §49 五个 Demo
examples/         hello counter form todo file-manager 五个可执行包
tests/ffi/        §37 第二层：native FFI 探针（自包含 C stub，不依赖外部库）
backends/libui/   §48-03：libui-ng 的 C Adapter（adapter.c/.h）+ MoonBit FFI 层
scripts/          build-libui.ps1：从 pin 的提交现编 Windows 静态库
_doccheck/        README 那段代码的独立包验证
third-party/      libui-ng 的检出与构建产物，全部不入库（.gitignore）
```

和 §4 的清单有三处不一致，都是权衡之后留下的：

- **`Backend` trait 留在 Core，没有单独的 `packages/backend/`。** trait 的方法签名要用 `NativeHandle`、`Event`、`LogicalSize` 这些 Core 类型，`App[B : Backend]` 也要用它当类型参数；trait 单独成包就变成 moonui ↔ backend 互相依赖，而 MoonBit 的包不允许成环。§4 给 `packages/backend/` 安排的活儿（§18 Renderer、§22 Native API）本来也是"实现侧"，等真实后端接入时再建，那时它是叶子。
- **`packages/widgets/` 暂时不建。** §4 列的 radio / slider / progress / image / list / tree / table / tabs 一个都还没实现，而现有的四类控件和 §14 的布局节点共用同一个 `Widget` 类型与同一张句柄表；拆包要么把 `Widget` 的构造暴露成公共字段，要么把类型参数约束复制一遍，两种都比现在多一层 API。§17 的 Custom Widget 落地之后这个包才有真实住户——那时"在 Core 之外定义控件"是需求，不是提前设计。
- **五个 Demo 的代码留在 `packages/moonui/demo.mbt`，`examples/` 只做驱动。** Demo 在这里同时是框架的回归载体：布局数值、句柄回收、事件派发都要拿一棵真实的树来断言，放进 `examples/` 就只能变成"跑过但没验证"。`examples/*` 反过来只准用公开 API，公开 API 不够用就是该补 API 的信号。

## 跑起来

```sh
moon check --deny-warn          # 警告在本项目里是错误
moon test                       # native：Core + MockBackend + FFI 探针 + libui 冒烟
moon test --target wasm         # 同一层在 wasm 上也要过（§47：Core 不得依赖任何 GUI 库）
moon run examples/hello         # §49 五个 Demo 各是一个可执行包
moon run examples/counter       # 下面三个同理：form / todo / file-manager
```

前两条不带包路径时会连 `backends/libui` 一起编（跑起来就是桌面上真的开两个窗口、真的各按一次按钮，每条测试自己就关掉了，不需要人工操作），而它要链接现编的 libui-ng——所以先跑一次 `scripts/build-libui.ps1`。只想要 Core 那一层（macOS / unix 上目前只能这样）就把范围写出来：

```sh
moon test packages/moonui examples/common examples/counter examples/form \
  examples/hello examples/todo examples/file-manager tests/ffi _doccheck
```

CI 的门禁范围就是按这同一份 glob 收集的（`.github/workflows/ci.yml`），`backends/` 被有意排除。所以 CI 绿不等于真后端绿，本地要跑下面那一节。

## 真后端（Windows / libui-ng）

```sh
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-libui.ps1
moon test backends/libui        # 必须在仓库根跑：链接期的 /LIBPATH 是相对 shell 工作目录的
```

`scripts/build-libui.ps1` 只做一件事：把 libui-ng 的固定提交编成 `third-party/libui/lib/libui.a`，并把同提交的 `ui.h` 原样拷进 `backends/libui/`——那份头文件的 `git diff` 就是 ABI 漂移的信号，编法和三条理由（静态、/MT、release）都写在脚本头部。工具链是 meson + ninja + Python，装在 `D:\Apps\moonui-toolchain`，不进 PATH；libui-ng 没有 CMake 工程，也不发布预编译包。`scripts/build-libui.sh`（unix/macOS）故意还没写：本机验不了。

这条路上量出来的六件事，记下来免得再踩：

- **libui 的文案 getter 是分配语义。** `uiButtonText()` 返回它自己 malloc 的一份拷贝，契约要求调用方 `uiFreeText()`；Adapter 拷进 `Bytes` 之后就还掉。还漏一块的后果不是慢慢漏，是退出时炸。
- **`uiUninit()` 末尾审计 libui 自己的分配表，发现泄漏就直接 `DebugBreak()`**（libui-ng 的 release 构建也不关这条）。没有调试器时这就是一个退不出去的测试进程 / 0x80000003。所以 `terminate()` 的前提是 MoonBit 侧句柄表已经归零，里程碑测试断言的正是这一点。
- **`uiInit()` / `uiUninit()` 没有引用计数**，重复 init 会因窗口类已存在而失败。Adapter 把这一对守成幂等单例，同一个测试进程里跑两条冒烟才安全。
- **静态库带不进 manifest**，Common Controls v6 与 DPI 感知由 `adapter.c` 自己补（`#pragma comment(linker, ...)` + 建窗口前 `SetProcessDpiAwarenessContext`）。
- **链接参数里的 `-link` 前缀不能去。** 它是 moon 把后面一串参数转交给 link.exe 的通道，代价是每次链接多印一句 `LNK4044：无法识别的选项 "/link"，已忽略`——这条无害；去掉前缀就变成 `LNK1104：打不开 libui.a`。
- **`ChildWindowFromPoint` 和 `SetWindowPos` 在同一个坐标系里。** 前者收父窗口客户区坐标，后者摆的也是客户区，所以按坐标注入点击不需要任何换算；命不中子窗口时它返回父窗口自己，于是"点在空白处"和"控件摆错了位置"落在同一个负数返回上——点击因此能反过来验证布局矩形真的落到了原生 HWND。

### §14 的落点：控件按 HWND 自己摆

libui-ng 的 Windows 后端只有容器布局（uiBox / uiGrid / uiForm），没有绝对摆放；而 §14 要 MoonUI 自己做布局、纯布局节点不占原生对象、叶子的原生父级只有窗口，§32 又要真控件保住原生外观与无障碍。三条候选路里只有"绕过 libui 的布局层"同时保住这两条，所以 Adapter 用 `moonui_control_attach` 把控件的 HWND 从 libui 的隐藏工具窗口（`windows/control.cpp` 里所有控件出生时的 parent）搬进目标窗口客户区，再按 MoonUI 算出的矩形 `SetWindowPos`。

两条不变量支撑这条捷径，都是从 vendored 源码读出来、再被冒烟测试验证的：

- 回调路由按控件 HWND 查表（`windows/events.cpp` 的 `runWM_COMMAND` 拿 `lParam` 当键，不是控件 ID），所以换父级不影响 `WM_COMMAND`；顺带一提，控件挂在 utilWindow 下时这条路由是**故意被跳过**的，搬进真窗口才收得到点击。
- 主循环对顶层祖先跑 `IsDialogMessage`（`windows/main.cpp` 的 `processMessage`），键盘 Tab 因此照旧，只是顺序跟 z-order 走。所以首次挂载把控件插到 z-order 末尾——挂载顺序即 Tab 顺序；之后的重新布局只改矩形、不动 z-order，免得 resize 把焦点链重排一遍。

代价是 libui 的容器不再替窗口收尾：控件必须在所属窗口之前逐个 `destroy_button`，否则 `DestroyWindow` 连带释放 HWND，libui 那份控件对象却不回收，退出时的分配审计就把这次运行变成 `DebugBreak`。挂回调的控件由同一次 `destroy_button` 松开闭包引用（§47 风险 1：C 长期持有的闭包不 decref 就是泄漏，不 incref 就是悬垂）。已知欠账：Stack / overlay 这类需要显式层叠的布局还没有 reorder API，§48-15 落地时补。

要查"死在哪一次 FFI 调用"，在 `backends/libui/moon.pkg` 的 `stub-cc-flags` 里加 `/DMOONUI_TRACE`：native 测试进程里 MoonBit 的 `println` 是全缓冲的，异常退出时整段丢失，只有 C 侧即时 `fflush` 的 trace 留得住顺序。

## 代码长什么样

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

## 约定

- 公共 API 一律逻辑像素，物理换算只发生在 `Scale` 里（§30）。
- Core 不缓存窗口与控件状态，原生层是唯一事实来源；例外只有 min/max 约束、菜单勾选状态和快捷键表。
- 纯布局节点不占原生对象，叶子的原生父级只有窗口（§14）。
- 事件优先：`on_click` 只是 `Event::Click` 的过滤器糖，路由与派发在 `App` 一处完成（§10）。
- 无障碍视图是推导出来的，不是另登一份名册：Actions 来自事件订阅，State 来自原生层；纯布局节点只有显式声明 Role 才进视图（§32）。
