#!/usr/bin/env bash
# T234 第五刀（2026-11-21）：fallback 发射模式的常驻闸。
#
# 全仓 native 编译押在 moon 的 `--moonbit-unstable-prebuild` 钩子 + node 上
# （unstable API，T234 记的单点）。逃生路是 `node prebuild-link.js --fallback`：
# 同一份 compileAdapter + flags 代码直接在命令行现编 adapter、打印可粘回执行壳
# moon.pkg 的链接参数。这条闸钉三件事：
#   ① 模式能脱离 moon 钩子独立跑通（exit 0）；
#   ② 产物路径真实存在、flags 非空且带平台特征库；
#   ③ 负控制：不在仓库根跑必须显式红（cwd 守卫对 fallback 同样生效）。
# 不 diff prebuild JSON 与 fallback 输出——两者同一份代码，不存在漂移面；
# 这条闸防的是"逃生路本身坏了没人发现"。

set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

fail() {
  echo "FAIL $1"
  exit 1
}

# ① 独立跑通。
out=$(node prebuild-link.js --fallback 2>&1)
rc=$?
if [ $rc -ne 0 ]; then
  echo "fallback 发射模式非零退出（rc=$rc）："
  echo "$out"
  fail "prebuild-fallback-run"
fi

# ② 产物存在 + flags 内容对平台。
objpath=$(printf '%s\n' "$out" | grep -o '_build/prebuild/[^ ]*' | head -1)
if [ -z "$objpath" ]; then
  fail "prebuild-fallback-objpath"
fi
if [ ! -e "$objpath" ]; then
  echo "fallback 报的产物不存在：$objpath"
  fail "prebuild-fallback-artifact"
fi
flags_line=$(printf '%s\n' "$out" | grep '^  link_flags:' | head -1)
if [ -z "$flags_line" ]; then
  fail "prebuild-fallback-flags-line"
fi
case "$flags_line" in
  *"-lgtk-4 "* | *"-framework Cocoa"* | *"user32.lib"*) ;;
  *) echo "flags 缺平台特征库：$flags_line"; fail "prebuild-fallback-platform-flags" ;;
esac
# 顺序契约（T234/T235）：adapter 产物必须排在系统库之前。
# 库标记的写法按平台分叉：MSVC 吐裸 .lib（user32.lib），GNU/Clang 吐 -lfoo。
# 原来这里只 grep '\-l'——Windows 宿主一条都匹配不到、libpos 恒空，于是明明
# adapter.obj 排在所有 .lib 之前也被误判成顺序错（本机 Windows 首跑即咬到）。
case "$flags_line" in
  *"user32.lib"*) libpat='\.lib' ;;   # Windows / MSVC
  *) libpat='\-l' ;;                  # macOS / Linux
esac
objpos=$(printf '%s' "$flags_line" | grep -ob "$objpath" | head -1 | cut -d: -f1)
libpos=$(printf '%s' "$flags_line" | grep -ob "$libpat" | head -1 | cut -d: -f1)
if [ -z "$objpos" ] || [ -z "$libpos" ] || [ "$objpos" -gt "$libpos" ]; then
  echo "adapter 产物不在系统库之前：$flags_line"
  fail "prebuild-fallback-order"
fi
# 可粘的 moon.pkg 片段得在场。
printf '%s\n' "$out" | grep -q 'cc-link-flags' || fail "prebuild-fallback-snippet"

# ③ 负控制：离开仓库根，cwd 守卫必须点名红。
out2=$(cd /tmp && node "$REPO/prebuild-link.js" --fallback 2>&1)
rc2=$?
if [ $rc2 -eq 0 ]; then
  fail "prebuild-fallback-negative-control"
fi
printf '%s\n' "$out2" | grep -q "不在仓库根" || fail "prebuild-fallback-negative-message"

echo "PASS prebuild-fallback-check（独立跑通、产物在、flags 带平台库、离根即红）"
