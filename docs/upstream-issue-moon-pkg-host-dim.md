# 上游 issue 草稿：moon.pkg 的 import 缺"构建宿主"维度

> 用途：这是给 [moonbitlang/moon](https://github.com/moonbitlang/moon) 的 issue 草稿，
> 记录在 TODO `T61` 的结论之后。**发出去之前先在 GitHub 上搜一遍现有的
> issues/discussions**——上游若已有同题讨论，改为跟帖并附我们的用例。
> 全文用英文写：moon 仓库的 issue 惯例是英文。
>
> 2026-10-13 补注：`T67` 之后我们已经在 prebuild 脚本里绕开了这条限制
> （脚本按 `MOON_HOST_OS` 自己编 C、把产物挂到 `link_configs` 顺 import 传播，
> 见仓库根 prebuild-link.js 与 TODO `T67`），所以这份 issue 从"阻塞我们的
> 分包"降级为"请求把绕开手法变成正式机制"。下面的用例仍然成立，正文里的
> 旧路径名（-native-macos / -native-windows 那两排壳）保留原样当历史现场。

---

## Title

`moon.pkg`: request host-OS-conditional imports — the moon equivalent of Cargo's `[target.'cfg(...)'.dependencies]`

## Body

### Problem

Multi-platform MoonBit libraries (GUI frameworks in particular) need to select a
platform backend by the **build host OS**, and `moon.pkg` currently has no
dimension for that.

What we mean concretely. In [MoonUI](https://github.com/<补上本仓公开地址>) a GUI framework is
split as:

- `packages/moonui` — backend-agnostic core, driven by a `Backend` trait;
- `backends/libui-common` — shared MoonBit FFI + trait implementation;
- `backends/libui-macos` and `backends/libui-windows` — two C adapters
  (`adapter_macos.m` / `adapter.c`) exposing the **same** `moonui_*` symbols
  for two different platforms.

Link flags for the two backends are already solved nicely by
`--moonbit-unstable-prebuild`: a prebuild script emits `link_configs` per
package and they propagate to dependent executables, so no shell duplicates
link flags. Thank you for that mechanism.

What remains unsolvable is the **import**: an executable package cannot say
"import the macos backend when building on macOS, the windows backend on
Windows". Importing both is impossible (duplicate `moonui_*` symbols), so every
demo has to ship one shell package per OS that differs only by one import line:

```
examples/hello-native-macos/moon.pkg   → import backends/libui-macos
examples/hello-native-windows/moon.pkg → import backends/libui-windows
```

— five demos, ten shells, and the Windows ones can't even be type-checked on a
mac (they import a package whose C stub only compiles under MSVC). We're not
alone: [MoUI](https://github.com/wzzc-dev/MoUI) (the largest MoonBit GUI
framework) has exactly the same shape — `backend/macos`, `backend/windows`,
`backend/linux`, … subpackages plus a per-platform prebuild `build.js`, and
per-target example shells.

The C side can't be unified as a workaround either: `native-stub` lists can't
branch per host, and even with `#ifdef` guards a `.m` file fails at the MSVC
driver level before preprocessing, so a single package hosting both adapters is
out (short of rewriting all of AppKit usage in pure C via `dlopen`'d libobjc —
possible, see e.g. justjavac/moonbit-tray, but a poor trade for a
3600-line ObjC adapter).

### Request

A way to express host-conditional imports (and ideally `native-stub`
selection) in `moon.pkg`, for example:

```moonbit
import {
  "username/MoonUI/backends/libui-macos" for host "macos",
  "username/MoonUI/backends/libui-windows" for host "windows",
}
```

— or, alternatively, letting the prebuild JSON emit an `import_configs`/
`stub_configs` section the same way it already emits `link_configs`, which
would keep the feature opt-in and consistent with the existing mechanism.

Either shape would let a framework expose **one** shell per demo that builds
everywhere, with the platform fork living entirely inside backend packages.

### Environment

- moon via `moon upgrade`, `--moonbit-unstable-prebuild` in active use;
- real-world consumers: MoonUI (libui-ng backends for macOS/Windows) and
  MoUI (Skia-based, macOS/Windows/Linux and more).

Happy to turn this into a design discussion if there's a preferred direction —
the prebuild-extension route in particular looks cheap from the outside.
