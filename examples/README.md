# examples：两种入口，一份代码

这里的目录按"事件从哪来"分成两种，而不是按功能分——同一个 Demo（hello /
counter / form / todo / file-manager / gallery）在两种入口里各有一份，MoonBit 侧
的 Demo 逻辑两者共用，一行不差。gallery 是组件画册：左栏组件清单、右栏示例代码
加真控件，0.1 的全部控件各一页（Demo 本体在 `packages/moonui/gallery.mbt`）。

## 两种入口

| 目录 | 事件来源 | 平台 | 怎么跑 |
| --- | --- | --- | --- |
| `examples/counter` 这六个 | MockBackend 的注入队列 | 任何平台（含 wasm） | `moon run examples/counter` |
| `examples/counter-native` 这六个 | 真按钮的原生回调（libui-ng → 原生层） | macOS 与 Windows 同一份 | `moon run examples/counter-native` |

native 那一排不需要手动准备依赖：`third-party/libui/lib/libui.a` 由
`prebuild-link.js` 在首次构建时自动现编（macOS 用 `scripts/build-libui.sh`、
Windows 用 `scripts/build-libui.ps1`，自带 pin 缓存）。`moon` 命令必须在仓库根跑
——链接参数里的路径按当前工作目录展开。

## 第三方用户该看懂的一件事

**你的应用代码只有一份，平台壳也只剩一份。** 六个 Demo 的 UI、事件、布局全走
`@moonui.*` 的公开 API（Demo 本体在 `packages/moonui` 的 `demo.mbt`，
`examples/common` 放共用的打印工具），里面一个平台名都不出现。
`counter-native/` 的 `main.mbt` 在 macOS 与 Windows 上逐字相同——2026-10-13
起连 `moon.pkg` 都是同一份（TODO `T67`），平台分叉整条链路上只剩
`prebuild-link.js` 里的一个 if。

壳里 import 的就是 `@libui-common`（共享的 MoonBit 实现）本身。
`prebuild-link.js` 在构建前按宿主编译对应的 C adapter（macOS 的
`adapter_macos.m` / Windows 的 `adapter.c`），把产物连同链接参数挂到
`libui-common` 上、顺 import 传进壳——于是壳不需要知道自己跑在哪个平台上。

## 曾经"壳要按操作系统分"，现在不用了

历史的坑留在这里，免得别的项目再踩：

- `moon.pkg` 的 `link` **没有宿主 OS 维度**，只能按输出目标（native / wasm /
  js）分档；两套链接配置互斥——mac 要 `-framework Cocoa`，Windows 要 MSVC 的
  `/utf-8` + 一串 `.lib`，mac 上的 clang 会把 `/utf-8` 当文件路径读。
- 链接参数**只在可执行包里生效**，库包（`backends/*`）声明的不顺
  `moon.pkg` 传下来。
- import 的后端包本身就不同：`backends/libui-macos` 与 `backends/libui-windows`。

这三条分别被 `--moonbit-unstable-prebuild`（构建前脚本能拿到
`MOON_HOST_OS`、`link_configs` 顺 import 传播）、脚本自己 spawn clang/cl 编 C、
把链接配置挂到共享库包 `backends/libui-common` 上顺 import 下发，逐一绕开
（TODO `T59`/`T60`/`T67`）。`moon.pkg` 哪天真加了 host 维度，
`prebuild-link.js` 那个 if 也能收回去。（2026-10-13 曾经有个
`backends/libui-native` 纯挂点包，因为链接参数不能挂 libui-common——那会让
自带 native-stub 的后端测试包把 adapter 链两遍、撞重复符号；测试包也改吃
prebuild 产物之后这个障碍消失，挂点包随之删除。）

另外注意：`-native` 这个后缀不只是命名习惯，`scripts/ci-packages.sh` 靠它把
六份 native-only 可执行包从跨平台的 core / wasm 门禁里排除——新建示例请沿用
这个后缀约定。
