#!/usr/bin/env bash
# ABI 符号交叉核对（`T145`）：`backends/native-common` 里 `extern "c"` 声明的每一个
# `moonui_*`，必须在**本平台**那份 adapter 的已定义符号里真的存在。
#
# 为什么需要这一道：三个平台包里，只有 C 是分平台写的，MoonBit 声明只有一份。
# 声明改了而 C 没跟上（或 C 那边被改名、被删）时，唯一的暴露口是**真链接**——
# 而真链接只在本平台发生：mac 半由 `prebuild-link.js` 现编、Windows 半只在这台
# Windows 上编。于是在 macOS 上把 Windows 半的 ABI 弄坏，本机一条门禁都不会红。
#
# 实测（2026-10-28，负控制）：把 `moonui_native_window_new` 的**定义**改个名，
# `x86_64-w64-mingw32-gcc -fsyntax-only -Wall` rc=0（只报既有的 `blob` 警告）、
# `moon check --target native backends/native-windows` rc=0（它不编 C）、
# `scripts/detlint.sh` rc=0。本脚本对同一次改动立刻吐出那一个名字。
#
# 为什么不用"两边符号集必须相同"当判据：探测函数（`*_probe`、`*_in_window`）
# 本来就是分平台的测试脚手架，今天有 5 个只在 mac、14 个只在 Windows。真实的
# 不变量只有一个方向——**声明必须被本平台定义**；C 多定义的东西不欠账。
#
# 工具链缺席时明确说"这一份没核"，不静默当作通过（静默跳过会被读成"已覆盖"）。

set -eu

cd "$(dirname "$0")/.."

MOON_INCLUDE="${MOON_HOME:-$HOME/.moon}/include"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ---- 声明侧：native-common 里所有 extern "c" 的实际符号名 ----
#
# 形状有两种：单行 `extern "c" fn c_x() -> T = "moonui_x"`，和多行（参数一行一个，
# `) -> T = "moonui_x"` 收尾）。所以用状态机：见到 `extern "c" fn` 置 pend，
# 之后第一个 `= "..."` 就是名字，取到即清。
decls=$tmp/decls
awk '
  /extern[[:space:]]+"c"[[:space:]]+fn/ { pend = 1 }
  pend && match($0, /= *"[A-Za-z0-9_]+"/) {
    s = substr($0, RSTART, RLENGTH)
    gsub(/= *"|"/, "", s)
    print s
    pend = 0
  }
' backends/native-common/*.mbt | sort -u > "$decls"

if [ ! -s "$decls" ]; then
  echo "✗ 一个 extern 声明都没解析出来——本脚本的解析前提变了（backends/native-common 的写法？）"
  exit 1
fi
decls_count=$(wc -l < "$decls" | tr -d ' ')

# 解析完整性：从**符号串本身**数一遍，和状态机认出的名字数比。
#
# 为什么非要这一道（2026-10-28 实测）：把 `extern "c"` 全改成 `extern "C"` 之后，
# 这个状态机只认出 23 个名字（剩下的是别的形状），而 23 个名字**当然**全有定义
# ——判据于是报绿。少认 168 个声明和"它们全都没问题"在这份输出上一模一样。判据
# 静默缩小自己的检查范围，比没有判据更坏：绿会被读成"核过了"。
#
# 数的那一边**不能用 `extern` 关键字**：第一版就是拿 `grep -c 'extern "c" fn'`
# 跟状态机比，关键字一改两边一起塌，等于没查。`= "moonui_xxx"` 这个形状是符号
# 串本身，与关键字拼法无关，改关键字改不掉它。
sym_count=$(cat backends/native-common/*.mbt |
  grep -ohE '= *"moonui_[a-z0-9_]+"' | sed 's/.*"\(moonui_[a-z0-9_]*\)"/\1/' | sort -u | wc -l |
  tr -d ' ')
if [ "$decls_count" -ne "$sym_count" ]; then
  echo "✗ 解析不完整：状态机认出 $decls_count 个符号，文件里的符号串有 $sym_count 个（去重后）。"
  echo "  backends/native-common 里出现了本脚本没覆盖的写法，判据会在缩小后的范围上报绿。"
  exit 1
fi

# ---- 定义侧：从对象文件里取已定义的全局符号 ----
#
# nm 的两套输出都要认：GNU（PE/ELF）的 `地址 类型 名字`，Apple 的 `地址 类型 _名字`
# （Mach-O 前缀一个下划线，去掉）。未定义符号的类型是 U，按字段筛掉——比认
# `--defined-only` 稳，Apple 的 nm 不认这个长选项。
defined_syms() {
  nm -g "$1" 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) if ($i == "U") next
      n = $NF
      sub(/^_/, "", n)
      print n
    }
  ' | sort -u
}

# 核对一份 adapter：$1 = 名字（给人看的），$2 = 这一份的已定义符号表文件
check_one() {
  local label=$1 syms=$2
  local missing=$tmp/missing
  comm -23 "$decls" "$syms" > "$missing"
  if [ -s "$missing" ]; then
    echo "✗ $label：声明了但没定义 $(wc -l < "$missing" | tr -d ' ') 个"
    sed 's/^/    /' "$missing"
    return 1
  fi
  echo "· $label：$(wc -l < "$decls" | tr -d ' ') 个声明全有定义"
  return 0
}

fail=0
checked=0

# ---- Windows 半：mingw 交叉编到对象，只取符号表 ----
#
# 这里**不**要警告：警告由 test-local.sh 那道 `-fsyntax-only -Wall` 负责（那是
# `T75` 的验收线），这一步只为拿符号表，重复刷一遍警告只会把真信号挤下去。
if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 &&
  command -v x86_64-w64-mingw32-nm >/dev/null 2>&1; then
  if x86_64-w64-mingw32-gcc -w -c -O0 \
    -Ibackends/native-windows -Ibackends/native-common -I"$MOON_INCLUDE" \
    backends/native-windows/adapter_native.c -o "$tmp/win.o" 2>/dev/null; then
    defined_syms "$tmp/win.o" > "$tmp/win.syms"
    check_one "Windows 半（adapter_native.c，mingw 交叉编）" "$tmp/win.syms" || fail=1
    checked=$((checked + 1))
  else
    echo "✗ Windows 半：mingw 编译失败（adapter_native.c）"
    fail=1
  fi
else
  echo "（Windows 半这一份没核：没有 x86_64-w64-mingw32-gcc / -nm）"
fi

# ---- Windows 宿主：本平台由真链接覆盖，不用交叉编 ----
#
# `moon test backends/native-windows` 在这里是真的链接（cl 编 adapter、link.exe
# 认符号），比这道交叉核对更强——同一个平台上再交叉编一遍只多花时间。说明白，
# 不数进 checked（那不是这道脚本核的），但也不让它变成一句沉默的跳过。
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    echo "（Windows 半由本平台真链接覆盖：moon test backends/native-windows 就在这里链）"
    ;;
esac

# ---- macOS 半：只在这台是 Darwin 时编得动（要 Cocoa 的头） ----
case "$(uname -s)" in
  Darwin)
    if cc -w -c -O0 -x objective-c \
      -Ibackends/native-macos -Ibackends/native-common -I"$MOON_INCLUDE" \
      backends/native-macos/adapter_native.m -o "$tmp/mac.o" 2>/dev/null; then
      defined_syms "$tmp/mac.o" > "$tmp/mac.syms"
      check_one "macOS 半（adapter_native.m，本机 cc 现编）" "$tmp/mac.syms" || fail=1
      checked=$((checked + 1))
    else
      echo "✗ macOS 半：本机 cc 编译失败（adapter_native.m）"
      fail=1
    fi
    ;;
  *)
    echo "（macOS 半这一份没核：只有 Darwin 宿主编得动 ObjC + Cocoa 的头）"
    ;;
esac

if [ "$fail" != 0 ]; then
  echo
  echo "声明与定义对不上 = 那个平台一链接就缺符号（本机看不到，只有真链接/真 CI 才红）。"
  exit 1
fi

# 一份都没核成时不能只说"通过"。工具链缺席在这个仓库里按跳过处理（与上面那道
# mingw 语法门同一套约定：那台真机器会自己编一遍），但跳过必须**说出来**——
# 一句干净的"通过"会被读成"两份都核过了"。
if [ "$checked" = 0 ]; then
  echo "=== ABI 符号核对：这一台没有可用工具链，一份都没核（不是通过） ==="
  exit 0
fi

echo "=== ABI 符号核对通过（核了 $checked 份） ==="
