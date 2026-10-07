#!/usr/bin/env bash
# CI 的包清单（§48 第 22~24 步的门禁口径）。
#
# 两个 job 共用这一份，避免"core 门禁用一套包、wasm 门禁用另一套"这种漂移：
# 调用方按目录传参，本脚本负责排除规则和排序。
#
# 排除规则只有一条：包名以 -native 结尾的（目前是 examples/hello-native）。
# 这类包是**只在 native 下存在的可执行包**——入口 .mbt 被门控成 native only，
# 于是 wasm 侧它一个文件都没有，而 moon 对可执行包要求必须有 main，
# 直接报 4067。它链接的是现编的原生库，本来也不属于"纯 MoonBit"的门禁。
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
      *-native) continue ;;
    esac
    out="$out $pkg"
  done
done
echo "${out# }"
