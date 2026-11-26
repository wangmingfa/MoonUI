#!/usr/bin/env bash
# MoonUI · Linux/GTK4 · 自绘输入法**真键路由**闸（T392 ①的另半）。
#
# 与 gtk-xinput（T235 P9）同层：真 X11 键经 XTEST 注入真窗，判据本体在
# scripts/gtk-ime-selftest.c。差别在那道闸用 xdotool 从另一进程发键、验 Tab
# 焦点链/滚轮；本闸**同进程** XTest 直发键、验自绘输入法真键路由
# （filter→GtkIMContext→信号→镜像）。两条都只 X11 有效。
#
# 确定性：selftest 强制 GTK_IM_MODULE=gtk-im-context-simple（GTK 内置，不依赖
# fcitx/ibus 状态），simple 模块对可打印 ASCII 逐个经 commit 信号提交，所以
# 注入 "abc" 后镜像必为 "abc"——判据与系统输入法当前是什么模式无关。
#
# 缺件纪律与其它 Linux 闸一致：**SKIP ≠ PASS**。无 X11 / 无 libXtst（无头
# .so.6 或没有 libXtst.so）时点名原因后 exit 0；设了 CI 时 SKIP 一律 exit 1
# （2026-11-09 CI 第二轮就是静默 SKIP 让判据一条没跑还往下走）。
#
# 本机会话（niri Wayland）键盘焦点：点击式抢焦点由 selftest 的 12 轮重试兜
# 底（指针路由到顶层 surface，`T355`）；12 轮都到不了 = 合成器不给焦点，
# selftest 如实 SKIP。CI（xvfb-run，纯 X11 无合成器）焦点稳定。
#
# 前置：GTK4 + Cairo 开发包 + pkg-config + libXtst（Debian：libxtst-dev；
#   Fedora：libXtst-devel）+ X11。
# 用法：xvfb-run -a bash scripts/gtk-ime-check.sh
set -uo pipefail

skip_or_fail() {
  echo "[gtk-ime] SKIP：$1"
  echo "[gtk-ime] SKIP ≠ PASS：真键路由判据这一次没跑。"
  if [[ -n "${CI:-}" ]]; then
    echo "[gtk-ime] CI 环境不允许 SKIP，按 FAIL 处理" >&2
    exit 1
  fi
  exit 0
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/backends/native-linux/adapter_native_gtk.c"
TEST="$ROOT/scripts/gtk-ime-selftest.c"
MOONLIB="${MOON_RUNTIME_OBJ:-$HOME/.moon/lib/libmoonbitrun.o}"
CC_BIN="${CC:-cc}"

deps_hint() {
  if command -v node >/dev/null 2>&1; then
    node "$ROOT/scripts/linux-deps.js" "$@" >&2
  else
    echo "  请装齐 $* 的开发包（发行版包名不同，见 docs/build-and-environment.md §2）" >&2
  fi
}

HOST="${MOONUI_HOST_OS:-$(uname -s)}"
case "$HOST" in
  Linux|linux) ;;
  *) skip_or_fail "XTEST 只在 X11 上有，当前宿主是 ${HOST}" ;;
esac

for f in "$SRC" "$TEST" "$MOONLIB"; do
  [[ -f "$f" ]] || { echo "[gtk-ime] 缺文件：${f}" >&2; exit 1; }
done
command -v pkg-config >/dev/null 2>&1 ||
  { deps_hint pkg-config gtk4 cairo; skip_or_fail "没有 pkg-config"; }
if ! pkg-config --exists gtk4 cairo; then
  deps_hint gtk4 cairo
  skip_or_fail "pkg-config 找不到 gtk4/cairo"
fi

# 与 canvas-pixel-check.sh / prebuild-link.js 同一档版本口径（T235 CI 首跑②）。
INC=( $(pkg-config --cflags gtk4 cairo) )
LIB=( $(pkg-config --libs gtk4 cairo) )
INC+=("-I$ROOT/backends/native-common" "-I$ROOT/backends/native-linux" "-I$HOME/.moon/include")
LIB+=("-lm" "-lX11")
LINK_EXTRA=(-Wl,--unresolved-symbols=ignore-in-object-files)

# libXtst：优先 -lXtst（有 libXtst.so 的发行版/CI），没有就找 libXtst.so.6
# （本机只有运行时库、无 dev 包）。两者都没有 = 编不了，SKIP。
XTST_FLAG=""
if echo 'int main(void){return 0;}' | "$CC_BIN" -x c - -lXtst -o /dev/null 2>/dev/null; then
  XTST_FLAG="-lXtst"
elif echo 'int main(void){return 0;}' | "$CC_BIN" -x c - -l:libXtst.so.6 -o /dev/null 2>/dev/null; then
  XTST_FLAG="-l:libXtst.so.6"
else
  deps_hint libXtst
  skip_or_fail "没有 libXtst（XTEST 键注入编不了）"
fi

BIN="$(mktemp /tmp/gtk-ime-selftest.XXXXXX)"
trap 'rm -f "$BIN"' EXIT

"$CC_BIN" -o "$BIN" "$TEST" "$SRC" "${INC[@]}" \
  -DGDK_VERSION_MIN_REQUIRED=GDK_VERSION_4_6 \
  -DGDK_VERSION_MAX_ALLOWED=GDK_VERSION_4_6 \
  -DGLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_2_72 \
  -DGLIB_VERSION_MAX_ALLOWED=GLIB_VERSION_2_72 \
  -pthread \
  "${LIB[@]}" "$XTST_FLAG" "$MOONLIB" "${LINK_EXTRA[@]}"
if [[ $? -ne 0 ]]; then
  echo "[gtk-ime] 编译/链接失败：见上面 ${CC_BIN} 输出" >&2
  exit 1
fi

# 无 DISPLAY（xvfb 没起）：selftest 的 XOpenDisplay 会失败 → 全 SKIP。
# 本机会话（niri Wayland）键盘焦点是合成器决定、点击式抢焦点 flaky（`T355`），
# selftest 自身 12 轮重试也可能全落空——这里把**整只 selftest**重试到 3 轮，
# 任一轮判据过了就算过；三轮全 SKIP 才按 SKIP 纪律收尾（CI 纯 X11 无合成器，
# 首轮即稳，重试只是本机 Wayland 的容差）。
for attempt in 1 2 3; do
  OUT="$("$BIN" 2>&1)"
  RC=$?
  echo "$OUT"
  if [[ $RC -ne 0 ]]; then
    echo "[gtk-ime] 判据红（rc=$RC）——本闸按 FAIL 收尾" >&2
    exit 1
  fi
  # selftest 返 0 且判据真跑过（pass>0）：通过。
  if echo "$OUT" | grep -qE "pass=[1-9]"; then
    echo "[gtk-ime] 真键路由判据通过"
    exit 0
  fi
  echo "[gtk-ime] 第 ${attempt} 轮全 SKIP，$([ $attempt -lt 3 ] && echo '重试' || echo '三轮都 SKIP，按 SKIP 收尾')"
done
skip_or_fail "selftest 三轮全 SKIP（键没到窗口 / 无 X11）"
