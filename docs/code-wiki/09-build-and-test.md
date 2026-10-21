# 09 构建与测试

## 9.1 环境要求

| 需要 | 用途 |
| --- | --- |
| MoonBit 工具链（moon ≥ 0.1.20260920） | 所有命令 |
| Node.js | `prebuild-link.js`（`moon.mod` 的 `--moonbit-unstable-prebuild`），只在 native 后端构建时跑 |
| Windows：MSVC（`cl` / `link`） | 现编 `adapter_native.c` |
| macOS：Xcode 命令行工具（`cc` / `ar`） | 现编 `adapter_native.m` |
| 可选：`x86_64-w64-mingw32-gcc` | macOS/Linux 上对 Windows adapter 做语法交叉检查 |

`moon check` 与 `--target wasm` 不跑 prebuild，不需要 C 工具链。

## 9.2 命令

所有命令**在仓库根**执行：

```bash
# 类型 + 警告闸门（不链接、不编 C）
moon check --deny-warn

# 包清单测试（必须带清单，见 9.4）
moon test $(bash scripts/ci-packages.sh packages examples tests _doccheck)

# wasm 无头测试
moon test --target wasm $(bash scripts/ci-packages.sh packages examples tests backends _doccheck)

# 无头 Demo
moon run examples/hello
moon run examples/gallery

# 真窗口（需要平台工具链 + 桌面会话）
moon run examples/gallery-native
moon run examples/hello-canvas-native
moon run examples/lunamusic-native
moon run examples/lunamusic-canvas-native

# 真窗口测试（按宿主）
moon test backends/native-windows      # Windows
moon test backends/native-macos        # macOS

# 一条命令全跑
bash scripts/test-local.sh

# 收尾（改过公开 API 或需要格式化时）
moon info && moon fmt
```

## 9.3 包清单：`scripts/ci-packages.sh`

按目录收集 `*/moon.pkg`，然后排除两类：

| 排除 | 原因 |
| --- | --- |
| `examples/*-native*` | 入口 `.mbt` 门控成 native only，wasm 侧没有 `main`，moon 报 4067；且链接现编原生库 |
| `packages/moonui-app` | import 真后端、引用 extern，任何测试二进制都会把 C 拉进链接，ubuntu 上无 GUI 库可链 |

今天受影响的只有 `gallery-native`、`hello-canvas-native`、`lunamusic-native`、`lunamusic-canvas-native` 与前台门。

`backends/` 三个包**不在**排除规则里：core 清单不列它们，wasm 清单列但走 wasm，它们的 `.mbt` 全门控成 native，wasm 上是空包。

## 9.4 为什么不能裸跑 `moon test`

裸 `moon test` 会链接 `backends/native-windows` 的测试二进制，它的 C adapter 只能由 Windows 的 `cl` 编译；`moon.pkg` 无法按宿主 OS 分支（只能按输出 target），链接参数改由 `prebuild-link.js` 按宿主注入。所以：

- 本机全量：`bash scripts/test-local.sh`（按 `uname -s` 选清单与真窗口测试）；
- CI：`core` / `core-portability` 两个 job 用同一份 `ci-packages.sh` 清单。

## 9.5 测试分层

| 层 | 位置 | 内容 | 跑在哪 |
| --- | --- | --- | --- |
| 纯逻辑 | `packages/moonui/*_test.mbt`、`*_wbtest.mbt` | 布局数值、样式层叠、事件路由、句柄、动画曲线、菜单、存档序列化 | 三平台 + wasm |
| Mock 集成 | 同上，用 `MockBackend` | `App`/`Window`/`Widget` 全链路、订阅、快捷键、任务、主题切换、Demo 全链路 | 三平台 + wasm |
| 自绘 | `backends/canvas-common`（`RecordCanvas` 断言绘制清单）、`backends/canvas-macos` 测试 | 配方输出、帧循环、鼠标翻译、pixel 断言 | macOS（配方层可 wasm） |
| 平台 FFI | `tests/ffi`（自带 C stub） | MoonBit ↔ C 的类型/字符串/借用/结构体往返 | 三平台 |
| 真窗口 | `backends/native-windows/native_test.mbt`（15 条）、`backends/native-macos/native_test.mbt`（14 条）+ `scaffold.mbt` | 真控件创建/销毁、属性往返、菜单、剪贴板、文件面板、托盘、通知、图像、手势 | 对应宿主 |

真窗口测试的约定：

- 脚手架**直接向控件投消息**（`BM_CLICK`、`SendMessageW(WM_CHAR)`、`PostMessageW(WM_CLOSE)`），全仓库没有 `SendInput` / `SetCursorPos`，所以不需要前台归属、不动真光标。
- macOS 上跑之前要停下手上操作：真鼠标交错会让测试假红。
- 测试结束断言 `HandleTable.live() == 0`。

自绘后端测试无头：`RecordCanvas` 记录 `DrawList` 命令与参数，断言"画了什么"，不需要屏幕。

## 9.6 CI：四个 job

| job | 平台 | 做什么 |
| --- | --- | --- |
| `core` | windows-latest、macos-latest、ubuntu-latest（`fail-fast: false`） | `moon check --deny-warn` → `moon test`（清单）→ 跑 5 个无头 Demo（`hello counter form todo file-manager`）→ `moon info` → `moon fmt --check` → `git diff --exit-code` |
| `core-portability` | ubuntu-latest | `moon check/test --target wasm`，证明 Core 里没有平台依赖 |
| `macos-backend-link` | macos-latest | `moon test --target native backends/native-macos`（**真跑**，T6）→ `moon build --target native examples/gallery-native`（只链接） |
| `windows-backend-link` | windows-latest | 装 MSVC 环境 → `moon test --build-only --target native backends/native-windows` → `moon build --target native examples/gallery-native`（只链接） |

要点：

- 警告即错误：`unused_mut`、`partial_match` 这类会改变 API 语义。
- `.mbti` 漂移即失败：`moon info` 后 `git diff --exit-code`。
- 两个 backend job 不共用 `ci-packages.sh` 的排除规则：它们要编的恰好是被排除的那几个包。
- 本仓库没有 remote，workflow 从未真跑；`macos-backend-link` 若红在"起不来 NSApplication"，退路是换回 `--build-only`（T6）。

## 9.7 本地门禁 `scripts/test-local.sh`

按顺序：

1. `packages/widgets` 依赖方向 grep（不许 import `backends/`，T107）；
2. `moon check --deny-warn`（全仓，三平台都可跑）；
3. `moon test <core 清单>`；
4. `moon run` 六个无头 Demo（比 CI 多一个 `gallery`）；
5. `moon check/test --target wasm <清单>`；
6. `.mbti` 漂移检查（只比 `.mbti`，不看整个工作区）；
7. `moon fmt --check`；
8. 非 Windows 宿主：若装了 mingw-w64，用 `-fsyntax-only -Wall` 交叉检查 Windows adapter（零警告）；没装则跳过；
9. 按宿主跑真窗口测试：Windows → `moon test backends/native-windows`，Darwin → `moon test backends/native-macos`，其余平台只到类型闸门。

最后打印"本地门禁通过"。任何一步红都立即退出（`set -eu`）。

## 9.8 常见红与排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `moon` 命令在子目录报找不到 `prebuild-link.js` | prebuild 相对路径以仓库根为基准 | 回到仓库根 |
| `cl.exe` / `cc` 找不到 | C 工具链不在 PATH | Windows 用 "Developer PowerShell for VS"；macOS 装 Xcode CLT |
| 链接期出现重复符号 | 给平台包另加了链接配置，adapter 被链接两遍 | 链接配置只留在 `native-common` |
| `error: 4067`（可执行包缺 main） | wasm 下跑了 `*-native` 包 | 用 `ci-packages.sh` 生成清单 |
| `pkg.generated.mbti` 与代码不一致 | 改了公开 API 没跑 `moon info` | `moon info && moon fmt` 后一起提交 |
| 真窗口测试偶发假红 | 真鼠标/键盘打断 | 停手后重跑；macOS 尤其注意 |
| 找不到 `adapter_native.obj` | prebuild 缓存但源文件没变、或从未编过 | 删 `_build/prebuild` 重跑 |
| 想看 FFI 死在哪一次调用 | — | `MOONUI_NATIVE_TRACE=1` 开启 C 侧逐调用日志 |

## 9.9 发布与版本

- 模块名 `username/MoonUI`，版本 `0.1.0`，`preferred_target = "native"`。
- 0.1 阶段 `.mbti` 不稳定，公开 API 会变；`moon info` 的 diff 就是 API 变更清单。
- 提交信息不带 `Co-Authored-By` trailer（仓库约定）。

下一篇：[10 API 速查](10-api-reference.md)。
