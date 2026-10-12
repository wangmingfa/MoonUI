// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "username/MoonUI"

version = "0.1.0"

readme = "README.md"

repository = ""

license = "Apache-2.0"

keywords = [ "gui", "ui", "widget", "layout", "desktop" ]

preferred_target = "native"
// TODO `T59`：构建前脚本，把两个后端包的链接配置注入构建图、顺 import
// 传给十个 native 壳——壳里的 `link.native` 副本因此可以删掉。机制名义
// unstable（moon 源码里 `link_configs` 的传播与 MSVC 翻译在
// `propagate_link_config`），只在 native/LLVM 后端跑，`moon check` 跳过。

description = "A GUI framework for MoonBit: backend-agnostic Core (layout, events, widgets, theme, HiDPI geometry) behind a Backend trait, with a MockBackend for headless development and testing."

options(
  "--moonbit-unstable-prebuild": "prebuild-link.js",
)
