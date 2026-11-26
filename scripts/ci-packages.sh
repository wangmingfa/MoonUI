#!/usr/bin/env bash
# CI 的包清单（§48 第 22~24 步的门禁口径）。
#
# 两个 job 共用这一份，避免"core 门禁用一套包、wasm 门禁用另一套"这种漂移：
# 调用方按目录传参，本脚本负责排除规则和排序。
#
# 排除规则的判据只有一句：**这个包在 wasm 侧有没有文件**。没有的就不能进清单
# ——moon 会把"目标下零个源文件"报成一堆找不到类型/值的错，红的是清单口径，
# 不是代码。现在有三条（按加进来的顺序）：
#
#   ① examples/ 下带 -native 后缀的可执行包：入口 .mbt 被门控成 native only，
#      wasm 侧一个文件都没有，而 moon 对可执行包要求必须有 main，直接报 4067。
#      今天在场的是一份 gallery-native（原生直写后端那份画册，2026-10-14 合并
#      自 -native-macos / -native-windows 两壳，不进 CI 的 link job，真跑靠本机）。
#   ② packages/moonui-app（2026-10-14）：前台门，import 真后端、逐文件门控成
#      native only。
#   ③ backends/canvas-macos（`T382`，2026-11-25）：自绘后端的 mac 半整包
#      native-only，见下面 case 分支里的详注。
#
# `T82`（2026-10-15）删 libui 之后六份 `-libui` 壳随包删除。
#
# `backends/libui-native` 那个纯链接挂点包已删（2026-10-13），`T82` 又把整个
# libui 三包删掉——闸门清单里不再有为 libui 留的特例。
#
# 真后端的包（backends/native-common、backends/native-windows、backends/native-macos）
# 在这里**不**按宿主分档：上面那两个清单都不做 native 链接（core 清单压根没列
# backends，wasm 清单不编 C），所以两边都能过。真窗口的测试是调用方按 uname 各
# 跑各的——见 test-local.sh 末尾那个 case，Windows 跑 backends/native-windows、
# macOS 跑 backends/native-macos。共享 MoonBit 层住在 native-common（ffi.mbt +
# backend.mbt + ABI 头 adapter.h，`T82` 起从 libui-common 移居），那个目录里既
# 没有 C 也没有 link，所以换平台不动 MoonBit。
#
# 唯一在本清单之外做 native 链接的是 ci.yml 里的 `macos-backend-link` /
# `windows-backend-link` 两个 job：它们按名字点名后端测试包（mac 外加
# backends/native-macos），mac 侧的测试二进制链接完当场真跑（T6）、示例只连
# 不跑，Windows 侧整侧只到链接为止——所以它们不共用这份排除规则：被 -native
# 挡掉的那个可执行包恰好是它们要编的。改动这里时别顺手把它"收编"进来：
# core 与 wasm 两份清单在三个平台上跑，而两个 job 各自只在自己的宿主上才编得
# 动对应平台的 C。
#
# 用法：bash scripts/ci-packages.sh packages examples tests _doccheck
set -eu

out=""
for dir in "$@"; do
  # 两种形状都要：`packages/moonui/moon.pkg` 这类子包，和 `_doccheck/moon.pkg`
  # 这种目录本身就是包的。
  for f in "$dir"/moon.pkg "$dir"/*/moon.pkg; do
    [ -e "$f" ] || continue
    pkg=${f%/moon.pkg}
    case "$pkg" in
      # 带 -native 后缀的可执行包只在 native 下存在（入口 .mbt 门控成 native
      # only，wasm 侧一个文件都没有，moon 对可执行包要求必须有 main，直接报
      # 4067）。今天在场的是一份 gallery-native。
      examples/*-native*) continue ;;
      # 前台门 packages/moonui-app 也排除（2026-10-14）：它 import 真后端、
      # 逐文件门控成 native only，引用着真后端的 extern——任何测试二进制都会把
      # C 拉进链接，ubuntu 上没有 GUI 库可链。core/wasm 两份门禁都不该含它，
      # 它的验证跟着真后端的真窗口测试与画册壳走。`T82` 之后它是一份 new_app()
      # 三步糖（不再 import 两份后端），排除的理由不变。
      packages/moonui-app) continue ;;
      # 自绘后端的三个包（`T372`/`T392`）**整包** native-only：moon.pkg 把每个
      # .mbt 逐个门控成 `options(targets: {... ["native"]})`——它们 import
      # native-common 的 extern（`moonui_canvas_*` 那批），wasm 侧一个文件都没有。
      # 留在清单里 `moon check --target wasm` 必红：2026-11-25 实测 canvas-macos
      # rc=1、31 处错误全在这个包（`CanvasBackend not found` ×8、
      # `native_window_is_key not found` 等），排掉它之后 26 包 rc=0（`T382`）。
      # 红的是清单口径，不是代码。
      #
      # `T392` 起自绘后端拆成「共享半 + 平台壳」：实现（CanvasBackend + 记账 +
      # 帧循环 + 48 条真窗判据）住在 backends/canvas-shared，canvas-macos 与
      # canvas-linux 是 `pub type CanvasBackend = @canvas-shared.CanvasBackend`
      # 的别名壳。三个包都是整包 native-only，逐一点名。
      #
      # **别写成 `backends/canvas-*`**：`canvas-common` 是零 C 零 FFI 的共享绘制
      # 层（配方 + RecordCanvas 尺子），§47 第 6 条「Core 里不许出现 GUI 库名字」
      # 那条门禁正是靠它上 wasm 来证的。将来的 canvas-windows 若也是整包
      # native-only，照这里逐一点名，不要图省事通配。
      backends/canvas-macos) continue ;;
      backends/canvas-shared) continue ;;
      backends/canvas-linux) continue ;;
    esac
    out="$out $pkg"
  done
done
echo "${out# }"
