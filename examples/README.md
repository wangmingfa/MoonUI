# examples：两种入口，一份代码

这里的目录按"事件从哪来"分成两种，而不是按功能分——同一个 Demo（hello /
counter / form / todo / file-manager / gallery）在两种入口里各有一份，MoonBit 侧
的 Demo 逻辑两者共用，一行不差。gallery 是组件画册：左栏组件清单、右栏示例代码
加真控件，0.1 的全部控件各一页（Demo 本体在 `packages/moonui/gallery.mbt`）。

## 两种入口

| 目录 | 事件来源 | 平台 | 怎么跑 |
| --- | --- | --- | --- |
| `examples/counter` 这六个 | MockBackend 的注入队列 | 任何平台（含 wasm） | `moon run examples/counter` |
| `examples/counter-native-macos` 这六个 | 真按钮的原生回调（libui-ng → Cocoa） | 仅 macOS | `moon run examples/counter-native-macos` |
| `examples/counter-native-windows` 这六个 | 真按钮的原生回调（libui-ng → Win32） | 仅 Windows | `moon run examples/counter-native-windows` |

native 那两排先要 `bash scripts/build-libui.sh`（Windows 用
`scripts/build-libui.ps1`）现编 `third-party/libui/lib/libui.a`，且 `moon`
命令必须在仓库根跑——链接参数里的路径按当前工作目录展开。

## 第三方用户该看懂的一件事

**你的应用代码只有一份。** 六个 Demo 的 UI、事件、布局全走 `@moonui.*` 的
公开 API（Demo 本体在 `packages/moonui` 的 `demo.mbt`，`examples/common` 放
共用的打印工具），里面一个平台名都不出现。对照：`counter-native-macos/`
与 `counter-native-windows/` 的两份 `main.mbt` 逐字相同。

**每个要变成 .app / .exe 的产物，再补一个"平台壳"。** 壳里只有两样东西：
一份 `main.mbt`（内容可以跨平台逐字相同）和一份 `moon.pkg`（import 哪个
后端包；链接参数 mac 壳走注入、Windows 壳仍写在里面，见下一节）。通常你只发
一个平台，就只写一个壳；这里两排齐备，是因为 CI 的两个 link job 要在两个
平台各链接一遍。

## 为什么壳要按操作系统分

这是 MoonBit 构建系统今天的限制，不是本库的设计选择：

- `moon.pkg` 的 `link` **没有宿主 OS 维度**，只能按输出目标（native / wasm /
  js）分档；而两套链接配置互斥——mac 要 `-framework Cocoa`，Windows 要
  MSVC 的 `/utf-8` + 一串 `.lib`，mac 上的 clang 会把 `/utf-8` 当文件路径读
  （实测坑记在 `backends/libui-windows/moon.pkg` 文件头）。
- 链接参数**只在可执行包里生效**，库包（`backends/*`）声明的不顺
  `moon.pkg` 传下来。macOS 那排壳的参数已改由仓库根 `prebuild-link.js`
  注入（见下），Windows 那排仍各抄一份。
- import 的后端包本身就不同：`backends/libui-macos` 与 `backends/libui-windows`。

C/C++ 靠 CMake 的 `if(WIN32)` 解决同一件事，Cargo 有 per-target 段；
`moon.pkg` 哪天加了 host 维度，两排壳就能合并成一个 `counter-native`，
届时这里跟着合并，你的应用代码一行不用动。

链接参数那一半不用等：`moon.mod` 的 `options("--moonbit-unstable-prebuild":
"prebuild-link.js")` 指一个构建前脚本，它输出的 `link_configs` 会挂到指定包上
**顺 import 传给可执行包**（moon 源码还会自动把 `-lfoo` 翻成 `foo.lib`）。
macOS 五份壳的 `link` 副本已由此收掉（TODO `T59`，参数唯一来源是
`prebuild-link.js`）；Windows 五份的收口要在 Windows 机器上验过再动
（TODO `T60`）——它动不了 import 列表，所以无论哪排，壳还是两排。

另外注意：`-native-macos` / `-native-windows` 这两个后缀不只是命名习惯，
`scripts/ci-packages.sh` 靠它把十二份 native-only 可执行包从跨平台的
core / wasm 门禁里排除——新建示例请沿用这个后缀约定。
