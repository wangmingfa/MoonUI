#!/usr/bin/env bash
# CI 的包清单（§48 第 22~24 步的门禁口径）。
#
# 两个 job 共用这一份，避免"core 门禁用一套包、wasm 门禁用另一套"这种漂移：
# 调用方按目录传参，本脚本负责排除规则和排序。
#
# 排除规则只有一条：包名以 -native 或 -native-macos 结尾的（目前是
# examples/hello-native 与 examples/hello-native-macos）。这类包是**只在 native
# 下存在的可执行包**——入口 .mbt 被门控成 native only，于是 wasm 侧它一个文件都
# 没有，而 moon 对可执行包要求必须有 main，直接报 4067。它链接的是现编的原生库，
# 本来也不属于"纯 MoonBit"的门禁。
#
# 两个真后端的包（backends/libui 与 backends/libui-macos）在这里**不**按宿主分档：
# 上面那两个清单都不做 native 链接（core 清单压根没列 backends，wasm 清单不编 C），
# 所以两边都能过。真窗口的测试是调用方按 uname 各跑各的——见 test-local.sh 末尾
# 那个 case，Windows 跑 backends/libui、macOS 跑 backends/libui-macos。
#
# 唯一在本清单之外做 native 链接的是 ci.yml 里的 `macos-backend-link` job：它按名字
# 点两个包（backends/libui-macos 与 examples/hello-native-macos），只到链接为止、
# 不执行产物，所以它不共用这份排除规则——被 `-native-macos` 挡掉的那个可执行包恰好
# 是它要编的。改动这里时别顺手把那两个包"收编"进来：core 与 wasm 两份清单在三个平台
# 上跑，Windows 编不了 mac 那份 C，Linux 两边都编不了。
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
      *-native | *-native-macos) continue ;;
    esac
    out="$out $pkg"
  done
done
echo "${out# }"
