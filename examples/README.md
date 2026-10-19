# examples：无头十个，真窗口两份

这里的目录按"事件从哪来"分成两类，而不是按功能分——同一个 Demo（hello /
counter / form / todo / file-manager / gallery 经典六份，2026-10-15 `T88` 起 +
settings-center / markdown-editor / data-admin 三份 DX 示例）在无头入口里各
有一份，MoonBit 侧的 Demo 逻辑共用，一行不差。gallery 是组件画册：左栏组件
清单、右栏示例代码加真控件，0.1 的全部控件各一页（Demo 本体在
`packages/moonui/gallery.mbt`；三份 DX 示例的本体住库 `demo_dx.mbt`，验证
各自的地基：设置中心验持久化闭环、编辑器验落盘读档、后台在 1000 行合成数据
复验虚拟化）。（2026-10-16 曾有 playground 双档示例——DSL 构树描述 + 参数
面板，同日 owner 裁决删除。）

2026-10-16 起第十个无头包是 `examples/cloudmusic`——一比一复刻网易云桌面端的
**应用本体库包**（DESIGN.md 见该目录）：AudioEngine trait 注入（测试用
MockAudioEngine，wasm 可跑全套状态机）、VirtualList 表格、播放条、抽屉；
真音频（AVAudioPlayer）与目录扫描住在 `examples/cloudmusic-native` 壳的
~40 行适配里——设计、行为表与分期判据都在 `examples/cloudmusic/DESIGN.md`。

## 两类入口

| 目录 | 事件来源 | 平台 | 怎么跑 |
| --- | --- | --- | --- |
| `examples/` 下这十个 | MockBackend 的注入队列 | 任何平台（含 wasm） | `moon run examples/counter` |
| `examples/gallery-native` | 真控件的原生回调（AppKit / Win32 直写） | macOS 与 Windows 同一份 | `moon run examples/gallery-native`（要真人关窗口才退出） |
| `examples/cloudmusic-native` | 真音频 + 真目录扫描 + 真窗口 | macOS 已接（AVAudioPlayer）；Windows 是 FP4 的档（音频 ABI 恒返 -3） | `moon run examples/cloudmusic-native`（要真人关窗口才退出） |

真后端入口不需要手动准备依赖：平台 C（macOS 的 `adapter_native.m` 直写
AppKit、Windows 的 `adapter_native.c` 直写 Win32）由 `prebuild-link.js` 在
首次构建时现编成 `_build/prebuild/adapter_native.o|.obj`，连同平台链接参数
挂在 `backends/native-common` 上顺 import 传进壳。`moon` 命令必须在仓库根跑
——链接参数里的路径按当前工作目录展开。（`T82`，2026-10-15 删 libui 之前，
§49 六个 Demo 曾各有一份 `-libui` 真窗口壳——2026-10-10 两侧都建好并逐份真
开过窗口，mac 那半 `T28`、Windows 那半 `T50`；那批壳随删 libui 退场，真窗口
入口只剩画册这份。）

## 第三方用户该看懂的一件事

**你的应用代码只有一份，平台壳也只剩一份。** 六个 Demo 的 UI、事件、布局全走
`@moonui.*` 的公开 API（Demo 本体在 `packages/moonui` 的 `demo.mbt`，
`examples/common` 放共用的打印工具），里面一个平台名都不出现。
`gallery-native/` 的 `main.mbt` 在 macOS 与 Windows 上逐字相同，`moon.pkg`
也是同一份（TODO `T67`），平台分叉整条链路上只剩 `prebuild-link.js` 里的
一个 if。

壳里 import 的就是 `@native-common`（共享的 MoonBit 实现）加前台门
`@moonui-app`（`new_app()` 三步糖，`T82` 后直接返回 `App[NativeBackend]`）。
`prebuild-link.js` 在构建前按宿主编译对应的平台 C adapter，把产物连同链接
参数挂到 `native-common` 上、顺 import 传进壳——于是壳不需要知道自己跑在
哪个平台上。

## 曾经"壳要按操作系统分"，现在不用了

历史的坑留在这里，免得别的项目再踩：

- `moon.pkg` 的 `link` **没有宿主 OS 维度**，只能按输出目标（native / wasm /
  js）分档；两套链接配置互斥——mac 要 `-framework Cocoa`，Windows 要 MSVC 的
  `/utf-8` + 一串 `.lib`，mac 上的 clang 会把 `/utf-8` 当文件路径读。
- 链接参数**只在可执行包里生效**，库包（`backends/*`）声明的不顺
  `moon.pkg` 传下来。
- import 的后端包本身就不同：真后端时代两排平台壳各 import 各的平台包
  （2026-10-13 单排合并是 `T67`；libui 那份后端 2026-10-15 `T82` 整体删除）。

这三条分别被 `--moonbit-unstable-prebuild`（构建前脚本能拿到
`MOON_HOST_OS`、`link_configs` 顺 import 传播）、脚本自己 spawn clang/cl 编 C、
把链接配置挂到共享库包上顺 import 下发，逐一绕开
（TODO `T59`/`T60`/`T67`）。`moon.pkg` 哪天真加了 host 维度，
`prebuild-link.js` 那个 if 也能收回去。（2026-10-13 曾经有个
`backends/libui-native` 纯挂点包，因为链接参数不能挂 libui-common——那会让
自带 native-stub 的后端测试包把 adapter 链两遍、撞重复符号；测试包也改吃
prebuild 产物之后这个障碍消失，挂点包随之删除。libui 整个后端又在
2026-10-15 随 `T82` 退场，挂点包的故事一并成为历史。）

另外注意：`-native` 这个后缀不只是命名习惯，`scripts/ci-packages.sh` 靠它把
native-only 可执行包从跨平台的 core / wasm 门禁里排除——新建真后端示例请沿用
这个后缀约定（无头示例不带后缀、三平台通用）。
