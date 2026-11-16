# 构建、环境与排错

> README 的「快速开始」只覆盖正常路径。这里收三样东西：构建链的硬前置、各平台的准备与已知环境红、IDE / Agent 内嵌终端里的宿主级坑。日常构建不需要读；卡住时按本页对号入座。

## 1. 构建链的四个硬前置（`T234`）

全仓 native 构建都押在 `moon.mod` 那一条 `--moonbit-unstable-prebuild` 上，**没有第二条编译路径**。下面四项先核一遍：

- **Node.js 22**：`prebuild-link.js` 由 node 执行；PATH 里没有 node 时脚本**根本不会被调起**，`moon build` 只会在链接期报一堆缺符号。`scripts/test-local.sh` 在任何 moon 命令之前先查 node 并给中文诊断；CI 五个 job 用 `actions/setup-node@v4` 钉 `22`、显式打印 `node --version`。
- **`MOON_HOST_OS`**：prebuild 靠它分宿主，缺了回退 `process.platform`。Linux 分支已接上（`T235` P1/P2：gcc 现编 `adapter_native_gtk.c` + `pkg-config gtk4 cairo`）。CI 的 `linux-backend-link` 在 ubuntu 上真编译、真链接、真跑四道闸。
- **仓库根**：脚本里的相对路径按当前工作目录展开，`moon` 命令都要在仓库根跑（`scripts/test-local.sh` 自己 `cd` 到根）。
- **平台编译器**：macOS 的 `cc`（Xcode CLT；起不来时 prebuild 打中文诊断），Windows 的 MSVC + vcvars（`T125` 那条诊断），Linux 的 gcc + GTK4 / Cairo 开发包。

机制本身名义 unstable：上游 `moon` 仓库的 `mod.schema.json`（2026-11-14 复查 main 分支）仍只有 `--moonbit-unstable-prebuild` 一个 prebuild 项、仍标 Experimental（「API may change at any time without warning」），未见稳定替代。描述已把脚本类型扩到 `.js/.cjs/.mjs/.py/.mbtx`，并钉了 `MOON_MOD`、`MOON_BUILD_DIR`、`MOON_HOST_OS/ARCH`、`MOON_BACKEND/PROFILE/JOBS` 与 stdin/stdout 契约；但本仓用的是发布版，main 的变化不等于发布版已具备。本仓没有第二份实现，迁移与 fallback 的排期记在 `TODO.md T234`。

## 2. 各平台准备

| 平台 | 需要 | 备注 |
| --- | --- | --- |
| Windows | MSVC + vcvars | 开过 vcvars 即可；`bash` 指 Git for Windows 的 git-bash |
| macOS | Xcode 命令行工具 | 提供 `cc` / `ar`；prebuild 现编 `adapter_native.m` |
| Linux | `libgtk-4-dev`（**≥ 4.6**）+ `libcairo2-dev` + `pkg-config`；无头环境再加 `xvfb` | prebuild 用 `pkg-config --cflags/--libs gtk4 cairo` 现取参数 |
| wasm | 无 | `moon check` / `moon test --target wasm` 不跑 prebuild、不编 C |

几条会咬人的细节：

- **Windows 侧编真后端要把 MSVC 的 bin 排到 PATH 前头**（开过 vcvars 就天然满足）。原因是 Git for Windows 附带的 coreutils `link.exe` 会抢在 MSVC 链接器前面。
- **Windows 上那个 bash 是 git-bash**：脚本认 `uname -s` 的 `MINGW*` / `MSYS*` / `CYGWIN*` / `Windows_NT`，用纯 PowerShell 时按 README / 本页的表格逐条手敲。
- **macOS 真窗口测试怕真鼠标、也怕机器忙**：测试期间 owner 动了鼠标会让个别用例假红；`T101`（自绘像素）与 `T152`（定时投递）两条对负载敏感（记在 `TODO.md`），偶发红先重跑再判定。
- **Linux 真机复验**（文件拖入 / 输入法组合）：`bash scripts/linux-real-check.sh` 开 `examples/linux-probe-native`，照 A/B/C 清单人工核对；非门禁、不进 CI。

## 3. `scripts/test-local.sh` 除了主流程还跑什么

主流程见 README 的「测试与 CI」。脚本开头固定先 `moon clean`（moon 不把平台 C adapter 算成 native 测试目标的输入，改过 `.m`/`.c` 不 clean 会拿旧测试二进制报绿，`T157`），然后按宿主分叉：

- `scripts/detlint.sh` 的棘轮计数（`T144`）：`backend-platform-capability` 把 `Backend` 里的平台服务方法钉在 0 条，`core-platform-leak` 把 Core 包里的应用专属语义钉在 0 条（那 6 个能力已迁到独立包 `packages/platform-services`），`core-audio-leak` 把应用音频语义钉在 0 条，`shell-native-leak` 钉住共享装配壳不 import `native-common`。规则与基线在脚本和 `scripts/detlint.baseline`。
- 一道 grep 闸门钉住 `packages/widgets` 只许 import Core、不许碰 `backends/`（`T107`）。
- macOS / Linux 上若 PATH 里有 `x86_64-w64-mingw32-gcc`，用它对 `backends/native-windows/adapter_native.c` 与 `packages/moonui/fs_utf8.c` 过 `-fsyntax-only -Wall -Werror`（`T189`/`T204`；第一次用就抓到 `MF_RADIOCHECK` 应为 `MFT_RADIOCHECK`）。
- `scripts/abi-symbols.sh` 核对 `extern "c"` 符号名在本平台 adapter 里真的被定义（`T145`，三份 C 互校）。工具链缺席时按跳过处理并**明说「一份都没核（不是通过）」**。
- `node scripts/logo-check.js`：图标资产与仓库里现存的 Pillow 产物做像素级 A/B（全仓去 Python 后仅依赖 Node 内置 zlib）。
- macOS 额外：GTK4 的三道本机闸（`mock-gtk-check.sh` / `gtk4-sysroot-check.sh` / `canvas-pixel-check.sh`）、段回收闸（`linux-gc-sections-check.sh`）、`moon test backends/native-macos`、产品 exe 符号账（`moon build examples/gallery-native` + `product-symbol-audit.sh`，`T233`）、vendored 解码器声明/实现分离（`vorbis-unit-check.sh`）。
- Linux 额外：外部真实输入闸（`gtk-xinput-check.sh`，需要 X11 XTEST；无 DISPLAY 时自己 `xvfb-run` 重入）与段回收闸。
- Windows 额外：`moon test backends/native-windows`。真后端画册（`gallery-native`）不跑——要真人关窗口。

## 4. 已知环境红与判据陷阱

### 4.1 锁屏会让 mac 真窗批假红（`T238`）

本机锁屏（前台是 `loginwindow`）时 `T110` / `T129` / `T210` 必红，全量门禁停在 `EXIT=2`；解锁并让桌面有前台应用后，同一份代码、同一条命令是 **86/86 全绿、`EXIT=0`**（当时读数）。判读用 `lsappinfo list | grep '(in front)'`——loginwindow 按 ASN 恒排第 1 行，别只看第一行。**别为此改判据或加重试护栏。**

### 4.2 Windows 真窗批的两次历史红——都已修，别按删除竞态加重试

- `T202` 曾报「文件打不开（写）：`...\Local\Tempmoonui-t202-…`」，53 条里红 1 条。根因是会话注入的 `TMPDIR`（`C:\Users\...\AppData\Local\Temp`）**无尾部分隔符**，而当时 `temp_dir_base()` 注释承诺带尾分隔符、实现却直接返回环境变量原值。`T277` 起 `Fs::temp_dir()` 幂等保证尾分隔符。
- `T202` 另一次**随机**红，失败点在 3471 / 3472 / 3498 / `.tmp` 写之间漂移，临时目录里出现带乱码后缀的目录。根因是 `backends/native-windows/native_test.mbt::utf16z()` 丢掉了 `Bytes::add` 的返回值（它**不原地改**），补的两字节 NUL 被丢掉，CRT 宽字符 API 读到堆上相邻内存。`T278` 起 `utf16z` 直接返回 `.add(Bytes::make(2, 0))` 的结果，并补一条「恒带 NUL 收尾」的确定性判据；修后连跑 10 轮 54/54。**根因在字符串终止、不在 OS。**

### 4.3 核产品 exe 的符号账别用 `dumpbin /SYMBOLS` 或字节搜索（`T233` ①）

两者**都会空转**——COFF 符号表与调试名都被剥了，连 `moonui_native_init` 都 0 命中，拿「0 命中」当通过不成立。要在 `prebuild-link.js` 的 `windowsNativeLinkFlags` 临时挂 `/MAP:<系统 temp 路径>` 重链，用 map 做正向（`/Gy` + `/OPT:REF,NOICF`，6 个 BAN 全 0）与负控制（临时改 `/OPT:NOREF`，5 个各回 2 处；第 6 个 `drag_hit_probe` 在 Windows C 里根本没定义），做完完整还原，map 不进仓库。数据与收口见 `TODO.md` `T233` ① 落地注。

## 5. IDE / Agent 内嵌终端

普通终端里 `bash scripts/test-local.sh` 就够。下面几条**只**在会话注入了文件删除钩子、且输出被工具管道捕获时才会咬人。它们是宿主环境问题，不是判据红，别为此改判据、加重试护栏或动构建配置。

| 症状 | 根因 | 绕法 |
| --- | --- | --- |
| `scripts/detlint.sh` 六条棘轮判据 0/0 全过，却仍 RC=1，报 `embedded drive prefix is not allowed` ×3 | 会话的 safe-delete 钩子（如 `CODEBUDDY_SAFE_DELETE_SANDBOX=1`）拒掉带盘符 `TMPDIR`（`C:\Users\...\Temp`）下 `mktemp` 文件的 `rm` | `TMPDIR=/tmp bash scripts/detlint.sh`，或给整条门禁加 `TMPDIR=/tmp`（Git Bash 的 POSIX 路径）。免沙箱开关无效——钩子是 Node shim / 环境变量注入，不是沙箱隔离层 |
| 从零构建时 moon 派生的 `cl.exe` / `lib.exe` 停在某条 runtime C（`stdio.c` / `watch_kqueue.c` …）上，CPU≈0、`.obj` 不生成 | Git Bash 的 MSYS PTY，或 moon 的输出被 PowerShell 管道捕获时，MSVC 子进程继承管道句柄后不退出 | PowerShell **不带输出管道**直调 moon：`& moon test --target native backends/native-windows 2>&1; Write-Output "RC=$LASTEXITCODE"`；仍挂就加 `-j 1` 串行编那 27 个 runtime C（实测 54s / 17s 跑通） |
| `scripts/abi-symbols.sh` 在「一份都没核」之后仍 RC=1，stderr 同样报 `embedded drive prefix` | 与 detlint 同源：收尾 trap 的 `rm` 被 safe-delete 钩子拒，trap 退出码覆盖了设计上的 `exit 0` | 同一个 `TMPDIR=/tmp`；该脚本 `checked=0` 时设计就是 RC=0 并自述「不是通过」，别把 RC=1 读成符号对不上 |
| `moon clean` 后 `moon check` / `moon info` 停在 `mooninfo.exe`，CPU≈0、`.mbti` 只写一半 | Git Bash 的 MSYS 层或默认并行度下原生子进程等待；`moon info` **不支持** `-j`（传了 RC=2 是参数错误，不是判据红） | `check` / `test` 加 `-j 1` 串行；`moon info` 走 PowerShell 无管道直调（实测 3s RC=0）。`info` 重写的 `.mbti` 只是 LF/CRLF 行尾噪声（`git diff --numstat` 为 0 增 0 删），还原即可 |

几个坑会叠在同一条门禁上（detlint 先红、重跑后卡原生子进程），此时分项取证。2026-11-14 在 win11 把 `test-local.sh` 的 Windows 分支分项全跑了一遍：

1. `moon clean`
2. `TMPDIR=/tmp bash scripts/detlint.sh`（六条棘轮 0/0）+ `packages/widgets` 依赖方向 grep
3. `moon check -j 1 --deny-warn`（RC=0）
4. core native 无头 **674/674**
5. 6 个无头 Demo 全 RC=0
6. `moon check --target wasm --deny-warn`（RC=0）+ wasm 无头 **694/694**
7. `moon info`（PowerShell 直调 RC=0、`.mbti` 无语义漂移）+ `moon fmt --check`（RC=0）
8. `node scripts/logo-check.js`（8 项 PASS / 0 红）
9. `TMPDIR=/tmp bash scripts/abi-symbols.sh`（RC=0，但**一份都没核，脚本自述不是通过**）
10. `moon test backends/native-windows`（`TMPDIR` 补尾斜杠后 **53/53**）

`x86_64-w64-mingw32-gcc` 缺席，两道交叉语法闸按 Windows 分支约定不跑。**分项绿仍不等于全量门禁绿**：整条 `bash scripts/test-local.sh` 在本会话没跑通（宿主守卫、`git diff` 漂移判据、脚本编排都没整体验过），普通终端里补一次 `TMPDIR=/tmp bash scripts/test-local.sh` 才是完整基线。（该轮为 `T277` 修复前取证；修复后 core 675/675、wasm 695/695、真窗批无需补尾斜杠亦 53/53；`T278` 补上 NUL 收尾判据后真窗批为 **54/54**。）

同一棵树上按「普通终端补一次完整基线」又试了四次 `bash scripts/test-local.sh`：**每一步都分项绿，但单进程 `EXIT=0` 仍没取到**——卡的是宿主，不是判据。

- **① 前台 Git Bash + `TMPDIR=/tmp`**：从 `moon clean` 一路走到 `moon fmt --check`，最后撞上 10 分钟工具时限被 SIGTERM。
- **②③ 后台跑**（Git Bash / PowerShell 各一次）：`moon test --target wasm` 起进程后 20 分钟零输出、无子进程、CPU≈0，是会话里已知的原生子进程挂起。
- **④ 前台 `env -u TMPDIR`**（detlint 单测仍 RC=0）：挂在 `moon check --deny-warn`。

同一条 wasm 批由 **PowerShell 直接调**（不经 bash 脚本）当场 **695/695、RC=0**，`moon fmt --check` 单独跑也 RC=0，所以卡点在进程/句柄继承，不在工具链或判据。⇒ 会话内**仍须在普通终端补一次** `TMPDIR=/tmp bash scripts/test-local.sh` 才能拿到整条 `EXIT=0`；这里的证据只覆盖每一步与脚本编排到 fmt 之前那段，不覆盖末尾的 `=== 本地门禁通过 ===`，别把它写成「全量门禁已通过」。

## 6. 与平台相关的工程边界

- **音频不在框架承诺范围（`T237` 裁决，2026-11-08）**：`AudioEngine`（`examples/lunamusic/engine.mbt`，22 方法，带 `Track` / `AudioError` 应用类型）由 `NativeAudioEngine` / `MockAudioEngine` 各自实现，前者直连 `backends/native-common` 音频段的 28 个 `moonui_native_audio_*` extern（平台分叉仍只在 C，§47）；detlint `core-audio-leak` 把这些语义钉在 Core 之外。
- **共享装配层已解耦（`T253`，2026-11-11）**：`NativeAudioEngine` 与 7 处非音频 FFI（`native_walk_dir`、`native_time_ms` ×2、`worker_run` ×2、`native_snapshot_all`）都收进 native-only 的 `examples/lunamusic-host`；`examples/lunamusic-shell` 不再 import `native-common`，改为接收 `@lunamusic.AppHost[B]` 与一只 `AudioEngine` 参数，换第三个后端时只需再写一个 host 注入点。detlint `shell-native-leak` 基线 0 钉住。`packages/moonui-app` 仍直接绑后端，那是刻意的 native 前台门（`new_app()` 三步糖，CI 显式排除）。
- **Linux 平台的显式缺席**：GTK4 4.6 没有的 API（如 `gtk_window_move`、同步文件对话框）按契约返回缺席码或兜底，不伪装成中性值；19 条 WebView 与音频 34 条如实缺席，Tab 键真派发仍待外部输入。逐条账在 `TODO.md T235`。

> CI 绿**不等于**真后端绿——`backends/` 在 native 门禁里被有意排除（要链接现编的库、还要一只会点鼠标的手），本地必须跑真窗口测试。
