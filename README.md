# MoonUI

MoonBit 的 GUI 框架。目标不是"某个 C GUI 库的 MoonBit 绑定"，而是让 MoonBit 能写桌面应用的那层框架：布局、事件、控件、主题、HiDPI、菜单与对话框都在 Core 里定义，平台原生 API 的差异留在 Backend 实现侧（macOS 直写 AppKit、Windows 直写 Win32）。

> MoonBit API 是第一公民，C 只是实现手段，Backend 永远不能反向决定 MoonUI 的 API。

| | |
| --- | --- |
| 版本 | 0.1.0（后端无关的第一层已交付，真后端有 Windows 与 macOS） |
| 工具链 | moon 0.1.20261028，`preferred_target = "native"` |
| 测试 | 三层判据 800+ 条；条数随判据增删变化，**一律以 `bash scripts/test-local.sh` 的输出为准**（2026-11-08 本机读数：native 649/649、wasm 663/663、mac 真窗 86 条） |
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
2. **Node.js 22**（本机与四个 CI job 钉同一档）。仓库根 `prebuild-link.js` 在每次 native 构建前由 moon 调起，按宿主注入链接参数并现编平台 C adapter；PATH 里没有 node 时 native 链接这步会红。
3. 平台编译器：macOS 的 Xcode 命令行工具（`xcode-select --install`）；Windows 的 MSVC + vcvars。

**构建链的四个硬前置**（`T234`）：全仓 native 构建都押在 `moon.mod` 那一条 `--moonbit-unstable-prebuild` 上，**没有第二条编译路径**，所以下面四项最好先自己核一遍。

- **node 22**：prebuild 脚本由 node 执行，缺了它脚本**根本不会被调起**，`moon build` 只会在链接期报一堆缺符号。`bash scripts/test-local.sh` 在任何 moon 命令之前先查 node 并给中文诊断；CI 四个 job 用 `actions/setup-node@v4` 钉 `22`、显式打印 `node --version`。
- **`MOON_HOST_OS`**：prebuild 靠它分宿主，缺了回退 `process.platform`；Linux 分支已接上（`T235` P1/P2：gcc 现编 `adapter_native_gtk.c` + `pkg-config gtk4 cairo`）。2026-11-09 起 CI 的 `linux-backend-link` 已在 ubuntu 上**真编译、真链接、真跑四道闸**（三轮修红后 2026-11-10 由 owner 确认全绿，见 `TODO.md` 的 `T235 CI 首跑②` / `P9`）；仍待真机的只剩 X11 / Wayland 上的**观感**与 HiDPI 缩放（`T241`）。
- **仓库根**：脚本里的相对路径按当前工作目录展开，`moon` 命令都要在仓库根跑（`scripts/test-local.sh` 自己 `cd` 到根）。
- **平台编译器**：macOS 的 `cc`（Xcode CLT；起不来时 prebuild 打中文诊断），Windows 的 MSVC + vcvars（`T125` 那条诊断）。

机制本身名义 unstable：上游 `moon` 仓库的 `mod.schema.json` 至今把这个 option 标为 Experimental（「API may change at any time without warning」），检索未见稳定替代；文档说 prebuild 也支持 Python 脚本，但本仓没有第二份实现。迁移与 fallback 的排期记在 `TODO.md T234`。

**真窗三条「既有红」先查桌面**（`T238`）：本机锁屏（前台是 `loginwindow`）时
`T110` / `T129` / `T210` 必红，全量门禁停在 `EXIT=2`；解锁并让桌面有前台应用后，
同一份代码、同一条命令是 **86/86 全绿、`EXIT=0`**。判读用
`lsappinfo list | grep '(in front)'`——loginwindow 按 ASN 恒排第 1 行，别只看第一行。
别为此改判据或加重试护栏。

**四步跑通**（全部在仓库根跑——链接参数里的相对路径按当前工作目录展开）：

```sh
moon check --deny-warn       # ① 类型与警告闸门，最快确认环境对了
moon run examples/hello      # ② 无头 Demo：终端打印事件与几何，不开窗口
moon run examples/gallery    # ③ 画册的逐页打印版（真窗口版是 examples/gallery-native）
bash scripts/test-local.sh   # ④ 全量门禁：脚本自己先 moon clean，再跑 native + wasm + Demo + 格式；本机是 macOS/Windows 时再跑真窗口测试
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
| 备真后端的依赖 | 什么都不用备：平台 C 由 prebuild 首次 `moon build` 时用本机 MSVC 现编 | 同左（clang 由 Xcode 命令行工具提供） | `libgtk-4-dev`（**≥ 4.6**）+ `libcairo2-dev` + `pkg-config`（无头环境再加 `xvfb`）；prebuild 用 `pkg-config --cflags/--libs gtk4 cairo` 现取参数（`T235` P1） |
| 无头测试（Core + MockBackend） | `moon test $(bash scripts/ci-packages.sh packages examples tests _doccheck)` | 同左 | 同左 |
| wasm 那一层（§47 第 6 条的证明） | `moon test --target wasm $(bash scripts/ci-packages.sh packages examples tests backends _doccheck)` | 同左 | 同左 |
| 类型闸门，含 native only 的包 | `moon check --deny-warn` | 同左 | 同左 |
| 接口与格式收尾 | `moon info && moon fmt`，然后提交 `.mbti` | 同左 | 同左 |
| 真窗口的测试 | `moon test backends/native-windows` | `moon test backends/native-macos` | 跑不了 |
| 真窗口的 Demo | `moon run examples/gallery-native` | 同左 | 跑不了 |

五条会咬人的细节：

- **`moon test` 要带包清单**，除非点名本平台那批真窗口测试。仓库根那条裸命令会去链接 `backends/native-windows` 的测试二进制，而它那批 `moonui_native_*` 符号只有 prebuild 现编的 Win32 adapter 提供——宿主不是 Windows 时链接必红。`moon check` / `moon info` 不链接、也不编 C，所以真后端的类型闸门在三平台都跑得动。
- **所有 `moon` 命令都在仓库根跑**。`scripts/test-local.sh` 自己 `cd` 到根，从哪儿调用都可以；它开头会先 `moon clean`——moon 不把平台 C adapter 算成 native 测试目标的输入，改过 `.m`/`.c` 不 clean 会拿旧测试二进制报绿（`T157`）。手动单跑 `moon test` / `moon build` 时仍要自己先 clean。
- **macOS 真窗口测试怕真鼠标、也怕机器忙**：测试期间 owner 动了鼠标会让个别用例假红；`T101`（自绘像素）与 `T152`（定时投递）两条对负载敏感（记在 TODO.md），偶发红先重跑再判定。
- **Windows 上那个 bash 是 git-bash**：脚本认 `uname -s` 的 `MINGW*` / `MSYS*` / `CYGWIN*` / `Windows_NT`，用纯 PowerShell 时按表逐条手敲。
- **Windows 侧编真后端要把 MSVC 的 bin 排到 PATH 前头**（开过 vcvars 就天然满足）。原因是 Git for Windows 附带的 coreutils `link.exe` 会抢在 MSVC 链接器前面。

`scripts/test-local.sh` 除了上表那些，还会：在 macOS / Linux 上若 PATH 里有 `x86_64-w64-mingw32-gcc`，用它把 `backends/native-windows/adapter_native.c` 过一遍 `-fsyntax-only -Wall -Werror`（第一次用就抓到不存在的 `MF_RADIOCHECK`，正确拼写是 `MFT_RADIOCHECK`）；跑 `scripts/abi-symbols.sh` 核对 226 个 `extern "c"` 符号名在本平台 adapter 里真的被定义（`T145`）；跑 `scripts/detlint.sh` 的棘轮计数（`T144`；`backend-platform-capability` 把 `Backend` 里的平台服务方法钉在 0 条，`core-platform-leak` 把 Core 包里的应用专属语义钉在 0 条——那 6 个能力已迁到独立包 `packages/platform-services`，`core-audio-leak` 把应用音频语义钉在 0 条，见 `API.md` §18）；以及一道 grep 闸门钉住 `packages/widgets` 只许 import Core、不许碰 `backends/`。

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
  platform-services/  可选平台能力（托盘 / 通知 / 媒体键 / 全局热键 / Now Playing）：
                      `PlatformServices` trait + 三条 App 转发 + MockBackend 实现。
                      **不属于 Core**，只依赖 Core；`T239` 从 `packages/moonui` 迁出
backends/
  native-common/    原生后端的共享 MoonBit 层（ffi.mbt + backend.mbt + canvas.mbt
                    + painter.mbt）+ ABI 头 adapter.h。两平台共用，无 C、无 link
  native-abi/       零宿主的纯函数包：ABI 编码 → Event 的判定表（鼠标 / 手势 /
                    滑向 / 走包解码），可进 wasm 门
  native-windows/   Windows 半：Win32 直写的 C Adapter + 真窗口测试
  native-macos/     macOS 半：Cocoa 直写的 C Adapter + 真窗口测试
  canvas-common/    自绘后端的绘制配方与录制式判据（不渲染、不比位图，wasm 可测）
  canvas-macos/     自绘后端本体（Backend #3）：窗口与系统服务转发给原生后端，
                    控件批改走记账；光栅器住在 native-macos 的 C adapter 里
                    （`T190`）：默认 CG（§52 严格路径），Metal 是 opt-in——
                    env / 偏好文件指定、无 GPU 自动回退 CG；P0~P4 与 5 条 Metal
                    容差冒烟已交付，剩余四项有意挂起见 `TODO.md` `T190`
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

和 §4 的清单有四处不一致，都是权衡之后留下的：

- **`Backend` trait 留在 Core，没有单独的 `packages/backend/`。** trait 的方法签名要用 `NativeHandle`、`Event`、`LogicalSize` 这些 Core 类型，`App[B : Backend]` 也要用它当类型参数；trait 单独成包就变成 moonui ↔ backend 互相依赖，而 MoonBit 的包不允许成环。
- **`packages/widgets/` 只有四个住户。** §4 里其余高阶控件（`CodeEditor` / `Terminal`）仍在 TODO：要键盘与 IME 的余账。这个包**只许 import Core 与标准库**，不许碰任何 `backends/`——`scripts/test-local.sh` 开头有一道 grep 闸门钉着。
- **平台能力单独成包，不放在 Core。** 托盘 / 通知 / 媒体键 / 全局热键 / Now Playing
  是 `lunamusic` 的应用需求，通用 GUI 框架不该在公开面里承诺 `set_now_playing(...)`。
  `T231` 先把它们从 `Backend` 拆成子 trait，`T239` 再把 trait、三份转发与
  `MockBackend` 的实现整体迁到 `packages/platform-services`；Core 的 `.mbti` 里
  这些名字为 0 命中，由 detlint `core-platform-leak` 基线 0 钉着（§18）。
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

§37 三层的前两层进 CI 的 `core` job；第三层自 2026-10-14（`T6`）起 mac 侧是**链接加真跑**，Windows 侧自 2026-10-22（`T78`）起同形。Linux 侧的第三层 P7 起接进 `linux-backend-link`（P8 补真窗判据、P9 补外部真实输入）；三道常规闸（假头语法 + 纯逻辑、真 GTK4 头编译、画布的**真链接 + 真跑**像素判据）现在是 mac 本机与 ubuntu/xvfb **同一份脚本**，见 `scripts/mock-gtk-check.sh` / `gtk4-sysroot-check.sh` / `canvas-pixel-check.sh`；**第四道** `scripts/gtk-xinput-check.sh` 要 X11 的 XTEST（xdotool 从另一进程发真键与真滚轮），只在 ubuntu/xvfb 上跑。2026-11-10 owner 确认该 job 全绿。仍只能本地跑的只剩真窗口 Demo：它们要真人关窗口才退出。

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
| Windows | 原生 API（Win32 直写，`adapter_native.c`） | 已接。§48-03/09~11/15、§48-13、§48-16 键盘与焦点、§48-18/19/20、§16 系统外观、§48-21 缩放、§12 按窗口工作区、§30 鼠标五变体均真跑绿（真窗口判据条数看门禁输出） |
| macOS | 原生 API（Cocoa 直写，`adapter_native.m`） | 已接。同上各项均有真窗判据；本机 2026-11-07 读数 83/86，3 条红是既有环境债（T110 / T129 / T210，干净 HEAD 上同样红）；2026-11-10 的 `T244` 已把 `T129` 从「剪贴板假绿」修成恒无条件判据（后台直派 responder 动作 + 剪贴板哨兵），本轮全量门禁里稳定绿；`T110` / `T210` 与 `T101`（HiDPI 波动，`T215`）仍随前台/缩放状态起伏，本轮 85/86、干净 HEAD 快照同值，见 TODO.md |
| Linux | 原生 API（GTK4 直写，`adapter_native_gtk.c`） | **已接（`T235` P0~P8 落地、2026-11-10 CI 全绿；P9 补外部真实输入判据）**：窗口生命周期 / 事件循环 / 键盘 / 鼠标 / 手势（P3）、**画布 24 条**（P4，cairo）、**音频 34 条如实缺席**（P5，返回 `-3`/哨兵值而不是中性桩的 `0`）、**控件挂载层 18 条**（P6-1：`GtkOverlay`→`GtkFixed` 的窗口内容容器、Panel/Custom 两种控件、attach/摆放/层叠/命中反查）、**剪贴板 2 条**（P6-2：`GdkClipboard`，读是异步的所以在 C 里泵到回调为止、上限 250ms）、**对话框与文件面板 8 条**（P6-3：`GtkMessageDialog` + `GtkFileChooserNative`——4.6 上唯一可用的形态，4.10 才有的 `GtkAlertDialog`/`GtkFileDialog` 用不了；GTK4 已没有同步的 run，同样靠临时 `GMainLoop` 等 `response`）、**菜单栏与上下文菜单 7 条**（P6-4a：`GtkPopoverMenuBar` + `GMenuModel` + `GSimpleActionGroup`，分隔线用 section 表达、radio 显示勾、快捷键走 `accel` 属性；装了菜单栏的窗口内容换成 `GtkBox[bar, overlay]`，客户区尺寸在请求值上补一行菜单栏——与 Win32「`SetMenu` 之后客户区矮一行」同一个问题）、**系统外观与控件样式 2 条**（P6-4b：`GtkSettings` 的 4.20+ `gtk-interface-color-scheme` 与 4.0 起 `prefer-dark`/`gtk-theme-name` 两代读口、`GtkCssProvider` + 每 widget 唯一 CSS class；CSS 文本拼串放在生成物 prelude，真 GTK 对象那半在 `theme_gtk.inc`）、**无障碍 4 条**（P6-4c：`GtkAccessible` 的 role / `LABEL` / `DESCRIPTION` / `CHECKED` 下发、两条系统偏好读数 `prefers_reduced_motion` / `prefers_high_contrast`、自绘面焦点 opt-in；`DISABLED`/`HIDDEN` 按 `T58` 定案不注记快照、留给 GTK 按活值自己算）已是明确的实现；**控件叶子 8 条**（P6-5：`widget_new` 从 2 种 kind 扩到 10 种真 GTK 对象，文案 / 占位 / 勾选 / 三条回调各走真 GTK 对象，程序化改值不回声；`fg`/`font`/`weight` 三条通道在真 `GtkLabel` 上由样式级联与 Pango 读数验过）也已落地；其余 91 个 ABI 符号仍是中性桩（19 WebView 等仍如实缺席；Tab 键真派发仍待外部输入——GTK4 公开头里没有事件构造函数）。`scripts/abi-symbols.sh` 从 P8 起也核这一份（以前只核 mac/win 两份 C）。**七构造族（P6-5c）**：kinds 6..12 的专属构造入口全部落地，产物 `backends/native-linux/widgets2_gtk.inc`（第十一片 `IMPL_FILES`）——Slider=`GtkScale` / Spinbox=`GtkSpinButton` / Progress=`GtkProgressBar` / ComboBox=`GtkDropDown`+`GtkStringList` / MultilineEntry=`GtkTextView` / RadioButtons=`GtkBox` 装互斥 `GtkCheckButton` / DatePicker=`GtkCalendar`；通用属通分派 `set_value`/`value`（Slider/Spinbox/Progress，Progress 的 `-1` 是"不定"哨兵、GTK 读不回所以缓存）、`append_option`/`set_selected`/`selected`（ComboBox 因 `GtkDropDown` 不支持无选中而用 `combo_has_sel` 跟踪 `-1`，RadioButtons 遍历子节点读 active）、`set_insets` 四方向 margin，`datepicker_set_text`/`text`（`GtkCalendar` 只认日期、时间靠 `date_cache` 原文往返）与六条 `on_*`（共用一条 change 闭包槽）一并落地；`widget_new` 对 6..12 如实回 0（它们走专属入口，不是 `(kind,text)` 通用工厂）。**控件叶子补完与焦点链 / 自绘面点击（P6-5b）**：`widget_new` 再扩 14 MenuRow（真 `GtkToggleButton`，勾选走 active 通道、文案走 Button 通道、CSS 消费面与 Button 同形）/ 15 Scroll（真 `GtkScrolledWindow`，内容自动包 `GtkViewport`，`scroll_set_content` 按 axis 落尺寸与滚动策略），`custom_on_clicked`（自绘面按下并原地抬起、拖出 / 多击不算）与焦点链三条（`focused_control` 沿父链反查 `GtkEntry` 的内部 `GtkText`、`set_focus_chain` 整份替换、`focus_widget_in_window` 按坐标命中）一并落地；C 已在本机用**真 GTK4 4.24 头**编过（`scripts/gtk4-sysroot-check.sh`，零错误零警告，并验过不依赖高于 4.6 的 API）；画布另有**真链接 + 真跑的像素判据**（`scripts/canvas-pixel-check.sh`，本机 60 绿 1 跳过（P8 起有真窗判据：present 出去、泵到映射再量分配尺寸与 GTK 自己的焦点遍历），像素级证据成立因为 cairo 在 mac 与 Linux 是同一份软件光栅器）；控件层、剪贴板、消息框、菜单、主题、无障碍、控件叶子、焦点链、自绘面点击与滚动内容同样是**真 GTK4 真跑**（同一道闸：无显示器下 `gtk_init_check` 也成立，所以造控件 / 挂载 / 摆放 / 层叠 / 摘挂 / 画布与控件共存 / 剪贴板写读往返 / 消息框点确定·是·否都在本机验过）；文件面板另需私有 sysroot 里编一份 GSettings schema，缺了就 SKIP 而不是红，身份账另有纯指针判据（`scripts/mock-gtk-check.sh` 的假 widget 树），主题 / CSS / 无障碍 / 控件叶子 / 焦点链 / 自绘面点击的纯逻辑另有第 10、11、12、13 组逐字对拍（全组 367 项，以 mock-gtk-check.sh 输出为准）；**Linux 侧的真链接只发生在 CI**：`linux-backend-link` 那个 job 现在跑同一份三道常规闸（假头 367 项纯逻辑 / 真头 4.24 与 4.6 两档 / 真链接真跑 60 条，xvfb 包住）加 P9 的外部输入闸、`moon test` 与 gallery 链接；2026-11-09 起已在 GitHub Actions **真跑过三轮**（三轮修红见 `TODO.md` 的 `T235 CI 首跑②`），**2026-11-10 由 owner 确认全绿**；ubuntu/xvfb 的 linker 行为与真窗上屏已由 CI 日志给出，仍待真机的只剩主题 / 字体的观感；真窗口判据 P8 起落在 `scripts/canvas-pixel-selftest.c` 的 `t_p8_real_window`（present 出去、泵到 mapped、320x240 分配尺寸、`widget_size` 两档、GTK 自己的焦点遍历、销毁后读 0），C 层直接调 GTK、不经过 MoonBit；事件真派发与 Tab 键真输入已由 **P9** 的 `scripts/gtk-xinput-check.sh` 落地（xdotool 经 XTEST 从另一进程发真键 / 真滚轮，判据区分声明链与 GTK 默认 z 序），它的红绿由下一轮 CI 给 |
| wasm | 无 | Core 的"不含任何 GUI 库"证明，CI 里当可移植性闸门 |

平台分叉只落在**三份 C**（`backends/native-windows/adapter_native.c`、`backends/native-macos/adapter_native.m`、`backends/native-linux/adapter_native_gtk.c`——最后这份由 `scripts/gen-native-linux-gtk.js` 从 `adapter.h` 生成，画布 / 控件层 / 控件叶子 / 剪贴板 / 对话框 / 菜单 / 主题 / 无障碍 / 焦点链 / 滚动内容 / 七构造族那十一段是手写的 `*.inc`，被生成物 `#include` 进同一个翻译单元）和 prebuild 脚本里；MoonBit 层共用 `backends/native-common/`，一行按平台分叉的代码都没有（分工定案见 TODO `T18`）。接入时量出的工程事实（文案分配语义、自动释放池栈式、层叠即 subviews 顺序、翻折自逆等）全部记在 [`docs/backend-lessons.md`](docs/backend-lessons.md)。

**音频与应用装配层的边界（`T237` 裁决，2026-11-08）**：音频播放**不在框架承诺范围**。`AudioEngine`（`examples/lunamusic/engine.mbt`，22 方法，带 `Track` / `AudioError` 应用类型）由 `NativeAudioEngine` / `MockAudioEngine` 各自实现，前者直连 `backends/native-common` 音频段的 28 个 `moonui_native_audio_*` extern（平台分叉仍只在两份 C，§47）；detlint `core-audio-leak` 把这些语义钉在 Core 之外（基线 0），与 `core-platform-leak` 分别挡「音频上移」与「6 个平台能力回灌」。
**换第三后端要换的不只是音频**：`examples/lunamusic-shell` 除 27 处音频调用外还直连 7 处非音频 FFI（`native_walk_dir`、`native_time_ms` ×2、`worker_run` ×2、`native_snapshot_all`），`packages/moonui-app` 也 import `native-common`——共享装配层整包绑在 `native-common` 上。这一半由 `T235` 自担，见 `TODO.md` `T235` / `T237`。

> CI 绿**不等于**真后端绿——`backends/` 在 native 门禁里被有意排除（要链接现编的库、还要一只会点鼠标的手），本地必须跑真窗口测试。

## 工程约定

- 公共 API 一律逻辑像素，物理换算只发生在 `Scale` 里（§30）。macOS 上还有第二道换算，但整段在 C 侧、只有一处（`adapter_native.m` 的 `moonui_native_px_to_pt` / `moonui_native_pt_to_px`）；y 轴方向不靠单独翻转换算，而是让视图 `isFlipped` 返回真、坐标口径在入口处就统一。
- **`CanvasPainter` 的逻辑→物理取整口径（`T232` 裁决，2026-11-08）**：唯一算式是 `backends/canvas-common/painter.mbt` 的 `px_of` = `(v * scale + 0.5).floor()`（round-half-up，向 +∞）。`.5` 处正负**有意不对称**：`3.5 → 4`、`-3.5 → -3`、`-0.5 → 0`。§30 只规定 Logical/Physical，没有规定取整方向；改成对称取整属于**改约定**而非修 bug，须先补一条能观测负 `.5` 绘制结果的判据再动。15 个 Painter impl 方法共用这一条算式，行为从 `T109` 第二刀起未变；A/B 实测与证据边界见 `TODO.md` `T232` 落地注。
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
