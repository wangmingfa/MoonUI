#!/usr/bin/env bash
# T233 第五刀的判据：vendored stb_vorbis **真的**编在独立 .o 里，声明单元没有
# 把实现又 include 回去，第三方原件一字未改，两个单元的裁剪宏没有各写各的。
#
# 为什么非要读 .o 的符号表不可（本闸存在的主要理由）：把声明单元里的
# `STB_VORBIS_HEADER_ONLY` 摘掉、又整份 include，链接照样成功、产品 exe 的
# 「未定义符号 = 0」也照样绿——实现只是回到了 adapter.o 里，是典型的等价变换
# 假绿。只有「adapter.o 里 stb_vorbis_* 必须是 U、且 U 集合非空」这一条能咬住。
#
# 判据读的是**真产物**（_build/prebuild 下的 .o / .a / exe），不读脚本自己那份
# 账；名单从 nm 输出现取，不硬编码 6 / 18 这类会随上游同步变化的数字。
#
# 前置：先跑过一次 native 构建（prebuild 会产出两个 .o 与 .a）。用法：
#   bash scripts/vorbis-unit-check.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRE="$ROOT/_build/prebuild"
LIB="$PRE/libadapter_native.a"
A="$PRE/adapter_native.o"
B="$PRE/stb_vorbis.o"
VENDORED="$ROOT/backends/native-common/third-party/stb_vorbis.c"
CONFIG="$ROOT/backends/native-common/stb_vorbis_config.h"
UNIT="$ROOT/backends/native-common/stb_vorbis_unit.c"
ADAPTER="$ROOT/backends/native-macos/adapter_native.m"

# 上游 v1.22 原件（2026-11-05 取）的 sha256。同步上游替换 vendored 文件后这条
# 会红，那是提醒复核包装与裁剪宏是否仍配套——把常量和 README 一起更新，别靠
# 改判据蒙过去。
BASELINE_SHA="4c7cb2ff1f7011e9d67950446b7eb9ca044f2e464d76bfbb0b84dd2e23e65636"

skip_or_fail() {
  echo "[vorbis-unit] SKIP：${1}"
  echo "[vorbis-unit] SKIP ≠ PASS：声明/实现分离这一次没核。"
  if [[ -n "${CI:-}" ]]; then
    echo "[vorbis-unit] CI 环境不允许 SKIP，按 FAIL 处理" >&2
    exit 1
  fi
  exit 0
}

for tool in nm ar shasum; do
  command -v "$tool" >/dev/null 2>&1 || skip_or_fail "没有 ${tool}"
done
for f in "$LIB" "$A" "$B" "$VENDORED" "$CONFIG" "$UNIT" "$ADAPTER"; do
  [[ -f "$f" ]] || skip_or_fail "缺 ${f}（先跑一次 moon build --target native examples/lunamusic-native）"
done

pass=0
fail=0
ck() {
  if [[ "$2" == "0" ]]; then
    pass=$((pass + 1)); echo "PASS ${1}"
  else
    fail=$((fail + 1)); echo "FAIL ${1}：${3}"
  fi
}

# ── ① 静态库恰两个成员 ────────────────────────────────────────────────────
# `ar rcs` 是「替换/添加」语义，漏传某个成员会在旧库里留下僵尸成员，所以既要
# 核数量也要核名字，不能只看 `ar t | wc -l`。
members="$(ar t "$LIB" 2>/dev/null | grep -v '^__\.SYMDEF' || true)"
if [[ "$members" == $'adapter_native.o\nstb_vorbis.o' ]]; then
  ck "libadapter_native.a 恰含 adapter_native.o + stb_vorbis.o" 0 ""
else
  ck "libadapter_native.a 恰含 adapter_native.o + stb_vorbis.o" 1 \
    "实际成员：$(printf '%s' "$members" | tr '\n' ' ')"
fi

# ── ② 符号归属：本闸的核心 ────────────────────────────────────────────────
defs_of() {
  nm -g "$1" 2>/dev/null |
    awk '$2=="T"||$2=="D"||$2=="B"||$2=="R"{print $3}' |
    sed 's/^_//' | grep '^stb_vorbis_' | sort -u || true
}
undefs_of() {
  nm -u "$1" 2>/dev/null |
    sed 's/^[[:space:]]*//' | sed 's/^_//' | grep '^stb_vorbis_' | sort -u || true
}
a_def="$(defs_of "$A")"
a_undef="$(undefs_of "$A")"
b_def="$(defs_of "$B")"

if [[ -z "$a_def" ]]; then
  ck "adapter_native.o 里没有 stb_vorbis_* 定义（实现没被编回去）" 0 ""
else
  ck "adapter_native.o 里没有 stb_vorbis_* 定义（实现没被编回去）" 1 \
    "又出现了：$(printf '%s' "$a_def" | tr '\n' ' ')"
fi
if [[ -n "$a_undef" ]]; then
  ck "adapter_native.o 有非空的 stb_vorbis_* 未定义集合（判据不空转）" 0 ""
else
  ck "adapter_native.o 有非空的 stb_vorbis_* 未定义集合（判据不空转）" 1 \
    "一个 U 都没有：要么声明/实现没分开，要么调用点被删了"
fi
missing=""
while IFS= read -r s; do
  [[ -z "$s" ]] && continue
  grep -qx "$s" <<<"$b_def" || missing="$missing $s"
done <<<"$a_undef"
if [[ -z "$missing" ]]; then
  ck "stb_vorbis.o 提供 adapter 引用的每一个 stb_vorbis_*" 0 ""
else
  ck "stb_vorbis.o 提供 adapter 引用的每一个 stb_vorbis_*" 1 "缺：${missing}"
fi
if [[ -n "$b_def" ]]; then
  ck "stb_vorbis.o 的 stb_vorbis_* 定义集合非空" 0 ""
else
  ck "stb_vorbis.o 的 stb_vorbis_* 定义集合非空" 1 "实现单元里一个定义都读不到"
fi
echo "[vorbis-unit] adapter.o: U=$(printf '%s' "$a_undef" | grep -c . ) T=$(printf '%s' "$a_def" | grep -c . )；stb_vorbis.o: T=$(printf '%s' "$b_def" | grep -c . )"

# ── ③ 产品 exe 不许留未定义的 stb_vorbis_* ────────────────────────────────
# 静态库按成员拉取：引用 ogg 的 exe 会拉进 stb_vorbis.o，不引用的不拉。两种
# 都不该有未定义符号。exe 一个都没有时点名 SKIP，不假装核过。
EXES=()
shopt -s nullglob
for f in "$ROOT"/_build/native/*/build/examples/*-native/*.exe; do
  EXES+=("$f")
done
shopt -u nullglob
if [[ ${#EXES[@]} -eq 0 ]]; then
  skip_or_fail "没找到产品 exe（先 moon build --target native examples/gallery-native）"
fi
for exe in "${EXES[@]}"; do
  name="$(basename "$exe")"
  undef="$(nm -u "$exe" 2>/dev/null | sed 's/^[[:space:]]*//' | sed 's/^_//' | grep '^stb_vorbis_' || true)"
  if [[ -z "$undef" ]]; then
    ck "${name} 没有未定义的 stb_vorbis_*" 0 ""
  else
    ck "${name} 没有未定义的 stb_vorbis_*" 1 \
      "未定义：$(printf '%s' "$undef" | tr '\n' ' ')"
  fi
done

# ── ④ vendored 原件身份 ───────────────────────────────────────────────────
sha="$(shasum -a 256 "$VENDORED" | awk '{print $1}')"
if [[ "$sha" == "$BASELINE_SHA" ]]; then
  ck "third-party/stb_vorbis.c 一字未改（sha256 对得上）" 0 ""
else
  ck "third-party/stb_vorbis.c 一字未改（sha256 对得上）" 1 \
    "实际 ${sha}，基线 ${BASELINE_SHA}——上游同步了吗？复核包装与裁剪宏后更新常量与 README"
fi

# ── ⑤ 裁剪宏只有一个来源 ─────────────────────────────────────────────────
# 两枚宏在 vendored 的**声明段**也生效，两边不一致时多出来的声明只要没人调用
# 就静默，链接期报不出来，所以这层只能静态钉。
if grep -q 'STB_VORBIS_NO_PUSHDATA_API' "$CONFIG" &&
   grep -q 'STB_VORBIS_NO_INTEGER_CONVERSION' "$CONFIG"; then
  ck "config.h 定义两枚裁剪宏" 0 ""
else
  ck "config.h 定义两枚裁剪宏" 1 "缺宏"
fi
for pair in "$UNIT|stb_vorbis_config.h" "$ADAPTER|stb_vorbis_config.h"; do
  src="${pair%%|*}"; hdr="${pair##*|}"
  if grep -q "#include .*${hdr}" "$src"; then
    ck "$(basename "$src") 走 config.h" 0 ""
  else
    ck "$(basename "$src") 走 config.h" 1 "没有 include ${hdr}"
  fi
  if grep -qE '^[[:space:]]*#define[[:space:]]+STB_VORBIS_NO_(PUSHDATA_API|INTEGER_CONVERSION)' "$src"; then
    ck "$(basename "$src") 没有自己 #define 裁剪宏" 1 "发现裸 #define，两个单元会漂移"
  else
    ck "$(basename "$src") 没有自己 #define 裁剪宏" 0 ""
  fi
done
if grep -q 'STB_VORBIS_HEADER_ONLY' "$ADAPTER" &&
   grep -q '#include "../native-common/third-party/stb_vorbis.c"' "$ADAPTER"; then
  ck "adapter 侧用 HEADER_ONLY 只取声明" 0 ""
else
  ck "adapter 侧用 HEADER_ONLY 只取声明" 1 "HEADER_ONLY 或 include 不见了"
fi

echo "[vorbis-unit] pass=${pass} fail=${fail}"
[[ $fail -eq 0 ]] || exit 1
