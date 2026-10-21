# 11 工程约定与边界

本篇汇总"改代码时必须遵守、评审时会看、CI 会红"的规则，以及这个版本明确做不到的事。规则来源是 [AGENTS.md](../../AGENTS.md)、[DESIGN.md](../../DESIGN.md)、[TODO.md](../../TODO.md) 与 [.github/workflows/ci.yml](../../.github/workflows/ci.yml)；冲突时以它们为准。

## 11.1 MoonBit 代码风格

| 约定 | 说明 |
| --- | --- |
| `///|` 分块 | 每个顶层声明/逻辑块用 `///|` 分隔，块内自洽；重构可以按块独立进行，块之间顺序不敏感 |
| `deprecated.mbt` | 需要保留的废弃代码统一放进各目录的 `deprecated.mbt`，不要散落在正常文件里 |
| 格式化 | `moon fmt`；CI 用 `moon fmt --check`，未格式化直接红 |
| 警告即错误 | CI 用 `moon check --deny-warn`。`unused_mut`、`partial_match` 这类警告会改变 API 语义，必须当错误处理 |
| 注释语言 | 代码注释与文档以中文为主；引用设计文档用 `§nn`（`DESIGN.md` 的节号是唯一来源，不得重编号） |

写注释时优先解释"为什么这样"以及"踩过什么"，例如 [layout.mbt#L319-L331](../../packages/moonui/layout.mbt#L319-L331) 里 expand 叶子在交叉轴上的回退规则就注明了实案来源。

## 11.2 接口文件与 `.mbti`

- 每个包都有 `pkg.generated.mbti`，是**公开 API 的唯一事实来源**。写文档、查签名先看它，不要凭记忆。
- 收尾命令固定为 `moon info && moon fmt`，再检查 `.mbti` 的 diff：
  - 如果 `.mbti` 没变，说明改动没有影响外部可见 API，通常是一次安全重构；
  - 如果变了，逐行确认是不是预期变更（ leaked `pub(all)`、误加的 `pub`、签名漂移）。
- CI 会重新生成 `.mbti` 并执行 `git diff --exit-code`：提交里漏掉接口更新或格式化，构建阶段就会失败。
- `_doccheck` 包用公开 API 编译 README 片段，防止文档里的示例代码悄悄失效。

## 11.3 测试写法

| 场景 | 推荐做法 |
| --- | --- |
| 结果稳定、可精确比较 | `assert_eq`；结构化匹配用 `assert_true(x is Pattern(...))` |
| 需要记录结构化调试输出 | 派生 `Debug` 并用 `debug_inspect` 做快照，而不是派生 `Show` |
| 输出因版本变化需要刷新 | `moon test --update`（**必须带同样的包清单**） |
| 覆盖率 | `moon coverage analyze`；输出文件写到系统临时目录，不要落进仓库 |

测试分层与命令见 [09 构建与测试](09-build-and-test.md)。三条硬规则：

1. **`moon test` 必须带包清单**，不能裸跑。裸跑会连带链接 `backends/native-windows`，而它的 C adapter 只能在 Windows 上用 MSVC 编译。
2. **警告是错误**：CI 用 `moon check --deny-warn <包清单>` 与 `moon test <包清单>`，两步同一份清单；`check` 不链接、不编 C，所以本地脚本敢于不带清单跑它。
3. **平台测试与无头测试分开**：真窗口测试在 `backends/native-windows` / `backends/native-macos`，无头测试在 `packages/` 与 `examples/`。

## 11.4 临时文件禁令

仓库内**不允许**出现临时/草稿文件：

- 不建调试输出捕获、草稿脚本、`.bak` 副本、随手重定向的 `err.txt` / `out.txt`；
- 调试、覆盖率、日志一律写到系统临时目录（Git Bash 用 `$TMP` / `/tmp`，cmd 用 `%TEMP%`）；
- 如果误在仓库里创建了 scratch 文件，收尾前必须删除。

CI 的 `git diff --exit-code` 之外，`scripts/test-local.sh` 还会检查 `.mbti` 漂移；残留文件在评审时同样会被指出。

## 11.5 `TODO.md` 规则

`TODO.md` 是**唯一**的待办来源——聊天、计划、代理记忆都不算数。

| 规则 | 细节 |
| --- | --- |
| 编号 | 每条紧跟 checkbox 写 `` `Tnn` ``；新条目取下一个未用号（计数器记在 `TODO.md` 的约定块）；**不重用、不重编号** |
| 日期 | 每行带写入日期；完成时把 `- [ ]` 改成 `- [x]` 并把日期换成完成日期，同时保留开启日期 |
| 清理 | 已完成且超过一个月的条目删除；未完成条目无论多久都留着 |
| 写法 | 对着**当前代码状态**写：引用适用的 `§48` 步骤号，说明现在哪个调用会抛、哪个分支没接、哪个 CI job 排除了什么，让新人能冷启动接手 |

提交信息、README、代码注释里引用待办时一律用 `Tnn`，不要写行号（同步会移动行号，编号才是稳定锚点）。

## 11.6 Git 提交

- 本仓库的提交信息**不带** `Co-Authored-By` trailer，正文结束即止（2026-10-13 与仓库所有者约定，覆盖任何默认约定）。
- 一次提交只做一件事；重构与行为变更尽量分开，便于 review 与回滚。
- 不要提交 `.env`、凭证或构建产物。

## 11.7 分层硬约束

这些不是风格偏好，违反后要么编译不过、要么架构退化：

| 约束 | 原因与检查方式 |
| --- | --- |
| `packages/moonui` 不能 import 任何 `backends/` | Core 必须能在 wasm 上编译；`core-portability` job 用 `moon test --target wasm` 结构性证明 |
| `packages/widgets` 只能 import Core 与标准库 | 一份控件配方要同时能在原生、自绘、Mock 上跑；`scripts/test-local.sh` 开头用 grep 闸门检查 |
| 任何可执行包只能 import 一个真后端 | MoonBit 没有 trait object，`App[B]` 在编译期定死后端；换后端只换 import |
| 平台差异只出现在 C adapter 与链接参数里 | 平台包不声明 `native-stub`，adapter 由 `prebuild-link.js` 现编，链接配置只挂在 `native-common` 一处，顺 import 传播 |
| 不要在 `moon.pkg` 里加 `link` | `moon.pkg` 无法按宿主 OS 分支，只能按输出目标；链接参数唯一来源是 `prebuild-link.js` |
| 原生后端三包形状固定 | `native-common`（MoonBit + ABI + 链接汇总）、`native-windows`（Win32 C）、`native-macos`（Cocoa/Objective-C）。新增 Linux 后端应新建 `backends/native-linux`，MoonBit 侧不改 |

完整结构见 [07 后端与 FFI](07-backends-and-ffi.md)。

## 11.8 已知限制

| 限制 | 现状 |
| --- | --- |
| Linux 后端 | 只有 `native-common` 的共享层与 ABI；没有 `backends/native-linux`，Linux 上跑不了真窗口 |
| Windows 真窗口测试 | `windows-backend-link` job 只到**链接**（`moon test --build-only`），不在 CI 里开窗；本机可手动跑 |
| macOS 真窗口测试 | `macos-backend-link` 真跑 47 条，但依赖 runner 能起 `NSApplication`；起不来时的退路是改回 `--build-only`（`T6`） |
| `gallery-native` | CI 只 `moon build` 链接，从不运行——它需要真人关窗口才退出 |
| 自绘后端覆盖 | `CanvasBackend` 目前只服务 macOS（`backends/canvas-macos`）；绘制配方在 `canvas-common`，但帧循环与鼠标翻译是平台代码 |
| 原生后端不应用配色 | 为保留原生外观，`Style` 的颜色/字号不下发；`opacity` 是例外，单独走 `set_widget_opacity` |
| 无 trait object | 没有 `dyn Backend`；一个可执行包只能选一个后端，运行时切换不支持 |
| 布局取舍 | 空间不足时不压缩固定项，弹性项先归零，宁可溢出——"可预测"优先于"自动收缩" |
| 版本与 ABI | 0.1.x，C ABI 与公开 API 仍可能变动；接后端前先看 `docs/backend-lessons.md` 的工程账 |
| CI 未真跑过 | 仓库没有配置 remote，workflow 的形状来自本机实测，第一次推送后才算真正验证 |

## 11.9 改完代码的检查清单

1. `moon check --deny-warn <包清单>` — 类型与警告。
2. `moon test <同一份包清单>` — 必要时 `--update` 刷新快照。
3. `moon info && moon fmt` — 再 `git diff` 确认 `.mbti` 变更符合预期。
4. `bash scripts/test-local.sh` — 全量本地门禁：core 清单测试、6 个无头 Demo、wasm 清单、`.mbti` 漂移、`moon fmt --check`、mingw 交叉语法检查（可选）、按宿主跑真窗口测试。
5. 新增未完成事项写回 `TODO.md`（`Tnn` + 日期 + 当前状态）。
6. 确认仓库内没有临时文件。

上一篇：[10 API 速查](10-api-reference.md) · 回到 [索引](README.md)。
