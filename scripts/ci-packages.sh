#!/usr/bin/env bash
# CI 的包清单（§48 第 22~24 步的门禁口径）。
#
# 两个 job 共用这一份，避免"core 门禁用一套包、wasm 门禁用另一套"这种漂移：
# 调用方按目录传参，本脚本负责排除规则和排序。
#
# 排除规则只有一条：examples/ 下带 -libui / -native 后缀的可执行包。这类包是
# **只在 native 下存在的可执行包**——入口 .mbt 被门控成 native only，于是 wasm 侧
# 它一个文件都没有，而 moon 对可执行包要求必须有 main，直接报 4067。它链接的是
# 现编的原生库，本来也不属于"纯 MoonBit"的门禁。今天在场的是七份（hello /
# counter / form / todo / file-manager / gallery 的 `-libui`，2026-10-13 由两排
# 平台壳合并而来、2026-10-14 从 `-native` 改名（那名字撞了"原生后端"的说法，
# 实际链接的是 libui 后端），恰好是 ci.yml 两个 link job 按名字点进来只编不跑
# 的那六份；再加 gallery-native——原生直写后端那份画册，2026-10-14 合并自
# -native-macos / -native-windows 两壳，不进 CI 的 link job，真跑靠本机）。
#
# `backends/libui-native` 那个纯链接挂点包已删（2026-10-13：链接配置改挂
# libui-common，见 prebuild-link.js 的说明），这里不再需要为它留特例。
#
# 三个真后端的包（backends/libui-common、backends/libui-windows、backends/libui-macos）
# 在这里**不**按宿主分档：上面那两个清单都不做 native 链接（core 清单压根没列 backends，
# wasm 清单不编 C），所以两边都能过。真窗口的测试是调用方按 uname 各跑各的——见
# test-local.sh 末尾那个 case，Windows 跑 backends/libui-windows、macOS 跑 backends/libui-macos。
# 目录改名之后多了一个好处：libui-common 里既没有 C 也没有 link，三个平台上它都只是
# 一份 MoonBit；MSVC 那串 flags 全在 prebuild-link.js 里，闸门清单的形状没变。
#
# 唯一在本清单之外做 native 链接的是 ci.yml 里的 `macos-backend-link` /
# `windows-backend-link` 两个 job：它们按名字点七（mac，外加 backends/native-macos）
# 个包（后端测试包与 examples/ 下那六份 `-libui`），mac 侧的测试二进制链接完当场
# 真跑（T6）、示例只连不跑，Windows 侧整侧只到链接为止——所以它们不共用这份排除
# 规则：被 `-libui` 挡掉的六个可执行包恰好是它们要编的。改动这里时别顺手把这些包
# "收编"进来：core 与 wasm 两份清单在三个平台上跑，而两个 job 各自只在自己的
# 宿主上才编得动对应平台的 C。
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
      # 任何带 `-libui` / `-native` 后缀的可执行包都只在 native 下存在（入口 .mbt
      # 门控成 native only，wasm 侧一个文件都没有，moon 对可执行包要求必须有 main，
      # 直接报 4067）。今天在场的是七份：六份单排 `-libui`（libui 后端，mac+Windows
      # 共用，即 ci.yml 两个 link job 点名的那六份）加一份 `gallery-native`
      # （原生直写后端的画册，2026-10-14 合并自 -native-macos / -native-windows
      # 两壳，不进 link job，真跑靠本机）。
      examples/*-libui*|examples/*-native*) continue ;;
    esac
    out="$out $pkg"
  done
done
echo "${out# }"
