# MoonUI Code Wiki

MoonUI 的代码级说明文档。面向"要读代码、改代码、接后端、跑测试"的人，不是营销材料。

| 项 | 值 |
| --- | --- |
| 模块名 | `username/MoonUI` |
| 版本 | 0.1.0 |
| 语言/工具链 | MoonBit，`preferred_target = "native"`，moon 0.1.20260920 |
| 许可 | Apache-2.0 |
| 文档基线 | 2026-10-21 的仓库状态 |
| 权威来源 | [README.md](../../README.md)、[DESIGN.md](../../DESIGN.md)、[API.md](../../API.md)、[TODO.md](../../TODO.md)、[AGENTS.md](../../AGENTS.md) |

> 这套文档是**导读与索引**，不替代上面几份源头文档。设计动机与取舍看 `DESIGN.md`（它按 `§nn` 分节，所有代码注释里的 `§nn` 都指向它）；具体签名看 `API.md` 与各包的 `pkg.generated.mbti`；未完成事项看 `TODO.md`（按 `Tnn` 编号引用）。

## 一句话架构

**Core 定义一切与平台无关的东西（布局、事件、控件、样式、主题、HiDPI 几何），Backend 只负责把原生 API 翻译成 Core 的 `Backend` trait；通过泛型静态分发 `App[B]` 在编译期选定后端。**

```
应用代码  →  packages/moonui (Core)  →  Backend trait  →  native-common / native-windows / native-macos
                                              ↘  canvas-common + canvas-macos（自绘后端，macOS）
```

## 阅读路径

| 你的目的 | 建议顺序 |
| --- | --- |
| 第一次接触项目 | 本页 → [01 项目概览](01-overview.md) → [02 整体架构](02-architecture.md) |
| 写一个应用 | [01 项目概览](01-overview.md) → [04 运行时](04-core-runtime.md) → [05 布局与样式](05-layout-and-style.md) → [08 组件与示例](08-components-and-examples.md) |
| 改 Core | [02 架构](02-architecture.md) → [03 模块地图](03-modules.md) → [04 运行时](04-core-runtime.md) → [05](05-layout-and-style.md) / [06](06-events.md) |
| 接一个新平台后端 | [02 架构](02-architecture.md) → [07 后端与 FFI](07-backends-and-ffi.md) → [09 构建与测试](09-build-and-test.md) |
| 查 API | [10 API 速查](10-api-reference.md) |
| 提 PR / 排错 | [09 构建与测试](09-build-and-test.md) → [11 工程约定与边界](11-conventions-and-limits.md) |

## 文档索引

1. [01 项目概览](01-overview.md) — 定位、设计原则、能力范围、术语表、不是什么。
2. [02 整体架构](02-architecture.md) — 分层、依赖方向、对象模型、一次事件/布局/窗口生命周期。
3. [03 模块地图](03-modules.md) — 目录与包的职责、依赖图、Core 文件逐个说明、改哪里。
4. [04 运行时核心](04-core-runtime.md) — `App`、`Window`、`Backend` trait、`MockBackend`、句柄表与生命周期。
5. [05 布局与样式](05-layout-and-style.md) — `Widget`/`WidgetKind`、`LayoutSpec`、测量与摆放算法、`Style`/`Theme`/级联。
6. [06 事件、动画与无障碍](06-events.md) — `Event` 全量、路由三路径、订阅、快捷键、动画/任务、无障碍。
7. [07 后端与 FFI](07-backends-and-ffi.md) — C ABI、`native-common`、平台 adapter、`prebuild-link.js`、自绘后端。
8. [08 组件与示例](08-components-and-examples.md) — `packages/widgets`、核心控件、六个 Demo、LunaMusic。
9. [09 构建与测试](09-build-and-test.md) — 命令、包清单、测试三层、CI 四个 job、常见红。
10. [10 API 速查](10-api-reference.md) — `App`/`Window`/`Widget`/`Backend`/布局类型的高频签名。
11. [11 工程约定与边界](11-conventions-and-limits.md) — 代码风格、`.mbti`/格式化、临时文件禁令、已知限制。

## 30 秒上手

```bash
moon check --deny-warn                 # 类型 + 警告闸门，不链接、不编 C
moon run examples/hello                # 无头 Demo，终端打印事件与几何
bash scripts/test-local.sh             # 全量本地门禁（按宿主追加真窗口测试）
moon run examples/gallery-native       # 真窗口组件画册（需要平台工具链，手动关窗退出）
```

所有 `moon` 命令都在**仓库根**执行；`moon test` 必须带包清单，不能裸跑（原因见 [09](09-build-and-test.md)）。

## 事实核对清单

写文档时依据的是仓库中的这些事实，代码变更后请同步核对：

- `Backend` trait 共 70+ 个方法，位于 [backend.mbt](../../packages/moonui/backend.mbt)，`pub(open) trait Backend` 从第 29 行开始。
- `WidgetKind` 共 27 个变体（`Label` … `Custom`），其中 `is_layout_only()` 为真的只有 8 个（`Row` / `Column` / `Padding` / `Spacer` / `Center` / `Stack` / `Grid` / `Sized`）。
- `Event` 共 27 个变体（见 [event.mbt](../../packages/moonui/event.mbt)），包含 `Frame`、`ImeStart/Compose/End`、`Gesture`、`LongPress`、`FileDrop`。
- `App[B]` 的公开方法 50+ 个，`Window[B]` 约 35 个，`Widget[B]` 约 130 个（见 `pkg.generated.mbti`）。
- 原生后端是三个包：`native-common`（MoonBit 侧 + ABI + 链接汇总点）、`native-windows`（Win32 C）、`native-macos`（Cocoa C）。
- 自绘后端是 `canvas-common`（`Painter` + 绘制配方）与 `canvas-macos`（`CanvasBackend` 包住 `NativeBackend`）。
- 已删除的 `backends/libui-*` 不再存在；`docs/backend-lessons.md` 是接平台时量出来的工程账。
