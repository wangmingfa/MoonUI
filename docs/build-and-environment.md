# 构建、环境与排错

> README 的「快速开始」只覆盖正常路径。本页收录三类内容：构建链的硬性前置条件、各平台准备与已知环境失败项、IDE / Agent 内嵌终端中的宿主级问题。日常构建无需阅读；遇到构建或测试失败时按本页逐项排查。

## 1. 构建链的四个硬性前置条件（`T234`）

全仓 native 构建均依赖 `moon.mod` 中的 `--moonbit-unstable-prebuild` 一项配置，**没有第二条编译路径**。使用前请先确认以下四项：

- **Node.js 22**：`prebuild-link.js` 由 node 执行；PATH 中没有 node 时脚本**不会被调用**，`moon build` 只会在链接期报告大量缺失符号。`scripts/test-local.sh` 在任何 moon 命令之前检查 node 并给出中文诊断；CI 的五个 job 使用 `actions/setup-node@v4` 固定 `22`，并显式打印 `node --version`。
- **`MOON_HOST_OS`**：prebuild 依赖它区分宿主平台，缺失时回退到 `process.platform`。Linux 分支已接入（`T235` P1/P2：由 gcc 现场编译 `adapter_native_gtk.c`，并通过 `pkg-config gtk4 cairo` 取参数）。CI 的 `linux-backend-link` 在 ubuntu 上实际编译、实际链接，并运行四道检查。
- **仓库根**：脚本中的相对路径按当前工作目录展开，`moon` 命令须在仓库根目录执行（`scripts/test-local.sh` 会自行切换到仓库根）。
- **平台编译器**：macOS 的 `cc`（Xcode CLT；不可用时 prebuild 输出中文诊断）、Windows 的 MSVC + vcvars（`T125` 对应的诊断）、Linux 的 gcc + GTK4 / Cairo 开发包（缺件时 prebuild 按 `/etc/os-release` 给出本机发行版的安装命令，见 §2）。

该机制本身仍标记为 unstable：上游 `moon` 仓库的 `mod.schema.json`（2026-11-14 复查 main 分支）仍只有 `--moonbit-unstable-prebuild` 一个 prebuild 项，且仍标注 Experimental（「API may change at any time without warning」），未见稳定替代方案。schema 描述已将脚本类型扩展到 `.js/.cjs/.mjs/.py/.mbtx`，并固定了 `MOON_MOD`、`MOON_BUILD_DIR`、`MOON_HOST_OS/ARCH`、`MOON_BACKEND/PROFILE/JOBS` 与 stdin/stdout 契约；但本仓使用的是发布版，main 分支的变更不代表发布版已具备。本仓没有第二份实现，迁移与 fallback 的排期记录在 `TODO.md T234`。

## 2. 各平台准备

| 平台 | 需要 | 备注 |
| --- | --- | --- |
| Windows | MSVC + vcvars | 执行过 vcvars 即可；`bash` 指 Git for Windows 的 git-bash |
| macOS | Xcode 命令行工具 | 提供 `cc` / `ar`；prebuild 现场编译 `adapter_native.m` |
| Linux | `gcc` + GTK4 开发包（**≥ 4.6**）+ Cairo 开发包 + `pkg-config`；无头环境另需 `xvfb` | 包名随发行版变（Debian 系 `libgtk-4-dev` / `libcairo2-dev`，Fedora 系 `gtk4-devel` / `cairo-devel`），见下面的安装命令；prebuild 通过 `pkg-config --cflags/--libs gtk4 cairo` 现场获取参数 |
| wasm | 无 | `moon check` / `moon test --target wasm` 不运行 prebuild、不编译 C |

Linux 上装齐这套依赖（`T396`：包名随发行版变，照别的发行版抄会装不上）：

```bash
# Debian / Ubuntu
sudo apt install -y gcc pkg-config libgtk-4-dev libcairo2-dev

# Fedora / RHEL（RHEL 9+ 的 gtk4-devel 在 CRB 仓库：sudo dnf config-manager --set-enabled crb）
sudo dnf install -y gcc pkg-config gtk4-devel cairo-devel

# Arch
sudo pacman -S --needed gcc pkgconf gtk4 cairo

# openSUSE
sudo zypper install -y gcc pkg-config gtk4-devel cairo-devel
```

- 要的是**开发包**（头文件 + `.pc`），只装运行库不算：`pkg-config` 找不到 `gtk4`，
  编译期 `#include <gtk/gtk.h>` 也找不到头。
- 连 `cc` 都没有时，`moon` 自己会报 `no system C compiler found; tried cc, gcc, clang`
  ——那是同一件事（缺 C 编译器），不是 GTK 的错，先装 `gcc`。
- 可选：HUD 置顶窗（`T343`）要 `gtk4-layer-shell`（Debian 系
  `libgtk4-layer-shell-dev`，Fedora 系 `gtk4-layer-shell-devel`）；不装就走空桩降级。
- 装完先 `moon clean` 再跑 moon 命令（`T157`：不 clean 会复用旧产物）。
- 缺件时 prebuild 与几道 Linux 闸（`canvas-pixel-check.sh` / `gtk-xinput-check.sh` /
  `linux-real-check.sh`）打印的安装命令由 `scripts/linux-deps.js` 按 `/etc/os-release`
  现算，认不出发行版时会把 Debian / Fedora / Arch / openSUSE 四套都列出来。

以下细节容易出现错误：

- **Windows 上编译真后端须将 MSVC 的 bin 置于 PATH 前部**（执行过 vcvars 即满足）。原因是 Git for Windows 附带的 coreutils `link.exe` 会优先于 MSVC 链接器被调用。
- **Windows 上的 `bash` 指 git-bash**：脚本识别 `uname -s` 输出中的 `MINGW*` / `MSYS*` / `CYGWIN*` / `Windows_NT`；使用纯 PowerShell 时需按 README 与本页表格逐项手动执行。
- **macOS 真窗口测试对鼠标操作与机器负载敏感**：测试期间人工移动鼠标会导致个别用例误报失败；`T101`（自绘像素）与 `T152`（定时投递）两条对负载敏感（记录在 `TODO.md`），偶发失败时应先重跑再判定。
- **Linux 真机复验**（文件拖入 / 输入法组合）：运行 `bash scripts/linux-real-check.sh` 打开 `examples/linux-probe-native`，按 A/B/C 清单人工核对；该项不属于门禁，不进入 CI。

## 3. `test-local.sh` 主流程之外的检查项

主流程见 README 的「测试与 CI」。脚本开头固定先执行 `moon clean`（moon 不把平台 C adapter 视为 native 测试目标的输入，修改 `.m` / `.c` 后未清理会使用旧测试二进制而误报通过，`T157`），随后按宿主平台分支：

- `scripts/detlint.sh` 的棘轮计数（`T144`）：`backend-platform-capability` 将 `Backend` 中的平台服务方法限制为 0 条，`core-platform-leak` 将 Core 包中的应用专属语义限制为 0 条（那 6 个能力已迁至独立包 `packages/platform-services`），`core-audio-leak` 将应用音频语义限制为 0 条，`shell-native-leak` 约束共享装配壳不得 import `native-common`。规则与基线位于脚本与 `scripts/detlint.baseline`。
- 一道 grep 检查约束 `packages/widgets` 只能 import Core、不得依赖 `backends/`（`T107`）。
- macOS / Linux 上若 PATH 中存在 `x86_64-w64-mingw32-gcc`，则以 `-fsyntax-only -Wall -Werror` 检查 `backends/native-windows/adapter_native.c` 与 `packages/moonui/fs_utf8.c`（`T189`/`T204`；首次启用时即发现 `MF_RADIOCHECK` 应为 `MFT_RADIOCHECK`）。
- `scripts/abi-symbols.sh` 核对 `extern "c"` 符号名是否确实在本平台 adapter 中定义（`T145`，三份 C 互相校验）。工具链缺失时按跳过处理，并**明确标注「一份都没核（不是通过）」**。
- `node scripts/logo-check.js`：将图标资产与仓库中已有的 Pillow 产物做像素级 A/B 比对（全仓移除 Python 依赖后仅使用 Node 内置 zlib）。
- macOS 额外项：GTK4 的三道本机检查（`mock-gtk-check.sh` / `gtk4-sysroot-check.sh` / `canvas-pixel-check.sh`）、段回收检查（`linux-gc-sections-check.sh`）、`moon test backends/native-macos`、产品 exe 符号核对（`moon build examples/gallery-native` + `product-symbol-audit.sh`，`T233`）、vendored 解码器的声明 / 实现分离检查（`vorbis-unit-check.sh`）。
- Linux 额外项：外部真实输入检查（`gtk-xinput-check.sh`，需要 X11 XTEST；无 DISPLAY 时自行以 `xvfb-run` 重入）与段回收检查。
- Windows 额外项：`moon test backends/native-windows`。真后端画册（`gallery-native`）不运行——需人工关闭窗口。

## 4. 已知环境失败项与判据陷阱

### 4.1 锁屏导致 macOS 真窗口批次误报失败（`T238`）

本机锁屏（前台为 `loginwindow`）时 `T110` / `T129` / `T210` 必定失败，全量门禁停在 `EXIT=2`；解锁并让桌面存在前台应用后，同一份代码、同一条命令为 **86/86 全部通过、`EXIT=0`**（当时读数）。判定时使用 `lsappinfo list | grep '(in front)'`——`loginwindow` 按 ASN 恒排第 1 行，不能只看第一行。**不应为此修改判据或增加重试机制。**

### 4.2 Windows 真窗口批次的两次历史失败——均已修复，不应按删除竞态增加重试

- `T202` 曾报告「文件打不开（写）：`...\Local\Tempmoonui-t202-…`」，53 条中失败 1 条。根因是会话注入的 `TMPDIR`（`C:\Users\...\AppData\Local\Temp`）**缺少尾部分隔符**，而当时 `temp_dir_base()` 的注释承诺带尾分隔符，实现却直接返回环境变量原值。自 `T277` 起 `Fs::temp_dir()` 幂等保证尾分隔符。
- `T202` 另一次为**随机**失败，失败点在 3471 / 3472 / 3498 / `.tmp` 写入之间漂移，临时目录中出现带乱码后缀的目录。根因是 `backends/native-windows/native_test.mbt::utf16z()` 丢弃了 `Bytes::add` 的返回值（它**不原地修改**），补入的两字节 NUL 被丢弃，CRT 宽字符 API 读到堆上相邻内存。自 `T278` 起 `utf16z` 直接返回 `.add(Bytes::make(2, 0))` 的结果，并补充一条「恒带 NUL 收尾」的确定性判据；修复后连续运行 10 轮均为 54/54。**根因在字符串终止，与操作系统无关。**

### 4.3 产品 exe 的符号核对不应使用 `dumpbin /SYMBOLS` 或字节搜索（`T233` ①）

两者**均无法得到有效结果**——COFF 符号表与调试名都已被剥离，连 `moonui_native_init` 都是 0 命中，因此不能以「0 命中」作为通过依据。正确做法是读链接器 map：`prebuild-link.js` 的 `windowsNativeLinkFlags` 末尾的 `/MAP`（省略文件名 ⇒ 与 exe 同目录同基名，`gallery-native.exe` ↔ `gallery-native.map`）在链接期生成 map，其中 `/OPT:REF,NOICF` 之后只列**留下来**的符号，正好是段回收的正面读数。

自 `T233` 第六刀起这件事是常驻闸而不是一次性手工读数：`bash scripts/product-symbol-audit.sh` 在 MSYS/MINGW 宿主上自动找同名 map 来核（6 个 BAN 名字必须为 0、`moonui_native_init` 必须在、名单仍声明在 `adapter.h` 里），已接进 `test-local.sh` 的 Windows 分支与 CI 的 `windows-backend-link` job。本机读数：正向 `pass=8 fail=0`（map 23115 行、定义符号 23053 个、`moonui_native_*` 381 个、6 个 BAN 全 0）；负控制把 `/OPT:REF,NOICF` 换成 `/OPT:NOREF` 重链后 `fail=1`（map 31912 行、`moonui_native_*` 575 个、5 个名字点名回来——第 6 个 `drag_hit_probe` 在 Windows 半的 C 里没有定义，故两态都为 0）。负控制两组：往 BAN 名单塞一个不存在的名字 ⇒ `adapter.h` 那条断言红；把 map 挪走 ⇒ 点名「缺 map」而不是静默 SKIP。数据与结论见 `TODO.md` `T233` ① 与第六刀落地注。

### 4.4 CI 日志与 `gh`

CI 的失败 job / step / 日志用 GitHub CLI 取，不靠网页逐页翻：`gh run view <run-id> --log-failed`。匿名访问只能拿到 job 列表与 annotations，日志正文会返回 `403 Must have admin rights`；认证后的命令、安装与登录步骤、以及 401 / 403 / 404 的排查见 [github-cli.md](github-cli.md)。

## 5. IDE / Agent 内嵌终端

在普通终端中执行 `bash scripts/test-local.sh` 即可。以下问题**仅**在会话注入了文件删除钩子、且输出被工具管道捕获时出现。它们属于宿主环境问题，并非判据失败，不应为此修改判据、增加重试机制或调整构建配置。

| 症状 | 根因 | 规避方式 |
| --- | --- | --- |
| `scripts/detlint.sh` 六条棘轮判据 0/0 全部通过，却仍 RC=1，报告 `embedded drive prefix is not allowed` ×3 | 会话的 safe-delete 钩子（如 `CODEBUDDY_SAFE_DELETE_SANDBOX=1`）拒绝带盘符 `TMPDIR`（`C:\Users\...\Temp`）下 `mktemp` 文件的 `rm` | `TMPDIR=/tmp bash scripts/detlint.sh`，或为整条门禁加上 `TMPDIR=/tmp`（Git Bash 的 POSIX 路径）。免沙箱开关无效——该钩子由 Node shim / 环境变量注入实现，并非沙箱隔离层 |
| 从零构建时 moon 派生的 `cl.exe` / `lib.exe` 停在某条 runtime C（`stdio.c` / `watch_kqueue.c` …）上，CPU≈0、`.obj` 不生成 | Git Bash 的 MSYS PTY，或 moon 的输出被 PowerShell 管道捕获时，MSVC 子进程继承管道句柄后不退出 | 以 PowerShell **不带输出管道**直接调用 moon：`& moon test --target native backends/native-windows 2>&1; Write-Output "RC=$LASTEXITCODE"`；若仍挂起，则加 `-j 1` 串行编译那 27 个 runtime C（实测 54s / 17s 可完成） |
| `scripts/abi-symbols.sh` 在「一份都没核」之后仍 RC=1，stderr 同样报告 `embedded drive prefix` | 与 detlint 同源：收尾 trap 的 `rm` 被 safe-delete 钩子拒绝，trap 退出码覆盖了设计上的 `exit 0` | 同样使用 `TMPDIR=/tmp`；该脚本在 `checked=0` 时设计即为 RC=0 并自述「不是通过」，不应将 RC=1 理解为符号不匹配 |
| `moon clean` 后 `moon check` / `moon info` 停在 `mooninfo.exe`，CPU≈0、`.mbti` 只写入一半 | Git Bash 的 MSYS 层或默认并行度下原生子进程等待；`moon info` **不支持** `-j`（传入后 RC=2 属于参数错误，不是判据失败） | 为 `check` / `test` 加上 `-j 1` 串行执行；`moon info` 通过 PowerShell 无管道直调（实测 3s RC=0）。`info` 重写的 `.mbti` 仅为 LF/CRLF 行尾噪声（`git diff --numstat` 为 0 增 0 删），还原即可 |

多个问题可能叠加在同一条门禁上（detlint 先失败、重跑后原生子进程挂起），此时应分项取证。2026-11-14 在 win11 上对 `test-local.sh` 的 Windows 分支逐项完整运行了一遍：

1. `moon clean`
2. `TMPDIR=/tmp bash scripts/detlint.sh`（六条棘轮 0/0）+ `packages/widgets` 依赖方向 grep
3. `moon check -j 1 --deny-warn`（RC=0）
4. core native 无头 **674/674**
5. 6 个无头 Demo 全部 RC=0
6. `moon check --target wasm --deny-warn`（RC=0）+ wasm 无头 **694/694**
7. `moon info`（PowerShell 直调 RC=0、`.mbti` 无语义漂移）+ `moon fmt --check`（RC=0）
8. `node scripts/logo-check.js`（8 项 PASS / 0 失败）
9. `TMPDIR=/tmp bash scripts/abi-symbols.sh`（RC=0，但**一份都没核，脚本自述不是通过**）
10. `moon test backends/native-windows`（`TMPDIR` 补尾斜杠后 **53/53**）

`x86_64-w64-mingw32-gcc` 缺失，两道交叉语法检查按 Windows 分支约定不运行。**分项通过仍不等于全量门禁通过**：整条 `bash scripts/test-local.sh` 在本会话中未能完整执行通过（宿主守卫、`git diff` 漂移判据与脚本编排均未完整验证），需在普通终端中另行执行一次 `TMPDIR=/tmp bash scripts/test-local.sh`，才能取得完整基线。（该轮为 `T277` 修复前的取证；修复后 core 675/675、wasm 695/695、真窗口批次无需补尾斜杠亦为 53/53；`T278` 补充 NUL 收尾判据后真窗口批次为 **54/54**。）

在同一工作树上按「在普通终端另行执行一次完整基线」又尝试了四次 `bash scripts/test-local.sh`：**每一步分项均通过，但单进程 `EXIT=0` 仍未取得**——阻塞点在宿主环境，不在判据。

- **① 前台 Git Bash + `TMPDIR=/tmp`**：从 `moon clean` 一直执行到 `moon fmt --check`，最终因 10 分钟工具时限被 SIGTERM 终止。
- **②③ 后台运行**（Git Bash / PowerShell 各一次）：`moon test --target wasm` 启动进程后 20 分钟内零输出、无子进程、CPU≈0，属于会话中已知的原生子进程挂起。
- **④ 前台 `env -u TMPDIR`**（detlint 单测仍为 RC=0）：挂起在 `moon check --deny-warn`。

同一条 wasm 批次由 **PowerShell 直接调用**（不经过 bash 脚本）时即时得到 **695/695、RC=0**，`moon fmt --check` 单独运行亦为 RC=0，因此阻塞点在进程 / 句柄继承，不在工具链或判据。⇒ 会话内**仍需在普通终端另行执行一次** `TMPDIR=/tmp bash scripts/test-local.sh` 才能取得整条 `EXIT=0`；此处证据只覆盖每一步与脚本编排至 fmt 之前的阶段，不覆盖末尾的 `=== 本地门禁通过 ===`，不应据此表述为「全量门禁已通过」。

## 6. 与平台相关的工程边界

- **音频不在框架承诺范围（`T237` 裁决，2026-11-08）**：`AudioEngine`（`examples/lunamusic/engine.mbt`，22 个方法，带 `Track` / `AudioError` 应用类型）由 `NativeAudioEngine` / `MockAudioEngine` 各自实现，前者直连 `backends/native-common` 音频段的 28 个 `moonui_native_audio_*` extern（平台分叉仍只在 C，§47）；detlint 的 `core-audio-leak` 将这些语义限制在 Core 之外。
- **共享装配层已解耦（`T253`，2026-11-11）**：`NativeAudioEngine` 与 7 处非音频 FFI（`native_walk_dir`、`native_time_ms` ×2、`worker_run` ×2、`native_snapshot_all`）均收进 native-only 的 `examples/lunamusic-host`；`examples/lunamusic-shell` 不再 import `native-common`，改为接收 `@lunamusic.AppHost[B]` 与一个 `AudioEngine` 参数，接入第三个后端时只需再编写一个 host 注入点。detlint 的 `shell-native-leak` 基线为 0。`packages/moonui-app` 仍直接绑定后端，这是有意的 native 前台门（`new_app()` 三步便捷构造，CI 显式排除）。
- **Linux 平台的显式缺席**：GTK4 4.6 未提供的 API（如 `gtk_window_move`、同步文件对话框）按契约返回缺席码或兜底，不伪装为中性值；19 条 WebView 与 34 条音频接口如实缺席，Tab 键的真实派发仍待外部输入。逐条清单见 `TODO.md T235`。

> CI 通过**不等于**真后端通过——`backends/` 被有意排除在 native 门禁之外（需要链接现场编译的库，且依赖人工操作窗口），本地必须另行运行真窗口测试。
