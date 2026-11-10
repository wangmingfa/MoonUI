#!/usr/bin/env bash
# MoonUI · Linux/GTK4 后端（T235 P9）——**外部真实输入**闸。
#
# 这是第四道 Linux 闸，只补前三道证不了的那一块：
#   ① scripts/mock-gtk-check.sh      假头语法 + 纯逻辑（不碰真 GTK）
#   ② scripts/gtk4-sysroot-check.sh  真 GTK4 头两档版本口径（不链接）
#   ③ scripts/canvas-pixel-check.sh 真链接 + 真跑，但事件都是
#      g_signal_emit_by_name 驱动的 GTK 信号或进程内 helper
#   ④ 本闸                           xdotool 从**另一个进程**经 XTEST 发真键
#      真滚轮，验 Tab 真派发 / 焦点按声明链走 / 滚轮 delta 方向 / 真打字
#
# 为什么单独一份、不塞进 ③：③ 在本机 macOS 上也要跑（私有 cairo 运行时），
# 而 XTEST 只在 X11 有；塞进去会让那 60 条判据跟着一个平台专属条件分叉。
# 分开之后，这一道红不会污染 "60-0-1" 那个结论，日志里一眼看得出是哪层。
#
# 缺件时的纪律与其它 Linux 闸一致：**SKIP ≠ PASS**。本机没 X11/xdotool 时
# 点名原因后 exit 0；设了 CI 时 SKIP 一律 exit 1 —— 2026-11-09 CI 第二轮
# 就是 ③ 静默 SKIP 让那一批判据一条没跑还继续往下走。
#
# 证据边界：判据本体（scripts/gtk-xinput-selftest.c）在 macOS 上编不过也
# 跑不了 XTEST，所以本机只能证「C 在真 GTK4 头下语法通」「脚本护栏真按
# 预期 SKIP/FAIL」。真事件注入的红绿只能由 ubuntu/xvfb 的 CI 给出。
#
# 前置：libgtk-4-dev libcairo2-dev pkg-config xvfb xauth xdotool
# 用法：xvfb-run -a bash scripts/gtk-xinput-check.sh
#   MOONUI_XINPUT_NEGCTL_NO_INPUT=1  Linux 上的语义负控制：不发任何外部输入，判据应全红
#                                    （CI 下禁用这个开关，防止拿负控制当通过）
set -uo pipefail

skip_or_fail() {
  echo "[gtk-xinput] SKIP：$1"
  echo "[gtk-xinput] SKIP ≠ PASS：外部输入判据这一次没跑。"
  if [[ -n "${CI:-}" ]]; then
    echo "[gtk-xinput] CI 环境不允许 SKIP，按 FAIL 处理" >&2
    exit 1
  fi
  exit 0
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/backends/native-linux/adapter_native_gtk.c"
TEST="$ROOT/scripts/gtk-xinput-selftest.c"
HELPER="$ROOT/scripts/gtk-xinput-helper.sh"
MOONLIB="${MOON_RUNTIME_OBJ:-$HOME/.moon/lib/libmoonbitrun.o}"
CC_BIN="${CC:-cc}"

HOST="${MOONUI_HOST_OS:-$(uname -s)}"
case "$HOST" in
  Linux|linux) ;;
  *) skip_or_fail "XTEST 只在 X11 上有，当前宿主是 ${HOST}（macOS 用不了 xdotool 发键）" ;;
esac

for f in "$SRC" "$TEST" "$HELPER" "$MOONLIB"; do
  [[ -f "$f" ]] || { echo "[gtk-xinput] 缺文件：${f}" >&2; exit 1; }
done
command -v pkg-config >/dev/null 2>&1 || skip_or_fail "没有 pkg-config"
command -v xdotool >/dev/null 2>&1 || skip_or_fail "没有 xdotool（apt install xdotool）"

PKGS=(gtk4 cairo)
for p in pangocairo-1.0 gdk-pixbuf-2.0; do
  if pkg-config --exists "$p" 2>/dev/null; then PKGS+=("$p"); fi
done
for p in "${PKGS[@]}"; do
  if ! pkg-config --print-errors --exists "$p"; then
    echo "[gtk-xinput] 诊断：pkg-config 解析不了 ${p}（上面是它自己的报错）" >&2
    skip_or_fail "pkg-config 找不到所需包 ${PKGS[*]}"
  fi
done

if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
  if command -v xvfb-run >/dev/null 2>&1; then
    echo "[gtk-xinput] 没有 DISPLAY：用 xvfb-run 重入"
    exec xvfb-run -a "$0" "$@"
  fi
  skip_or_fail "没有 DISPLAY 也没有 xvfb-run"
fi
# Wayland 上没有 XTEST：xdotool 的 key/click 会静默打到别处，判据会超时。
# 与其让它红得莫名其妙，不如在这里把原因说清（CI 用的是 xvfb，不会走到）。
if [[ -n "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
  skip_or_fail "纯 Wayland 会话没有 XTEST（需要 X11 或 XWayland 的 DISPLAY）"
fi
if ! xdotool getdisplaygeometry >/dev/null 2>&1; then
  skip_or_fail "xdotool 连不上当前 DISPLAY（${DISPLAY:-空}）"
fi

# 负控制开关不许在 CI 里出现：那会把"故意不发输入"伪装成一道闸。
NEGCTL="${MOONUI_XINPUT_NEGCTL_NO_INPUT:-0}"
if [[ "$NEGCTL" == "1" && -n "${CI:-}" ]]; then
  echo "[gtk-xinput] CI 里不许设 MOONUI_XINPUT_NEGCTL_NO_INPUT" >&2
  exit 1
fi

BUILD="$(mktemp -d /tmp/moonui-gtk-xinput.XXXXXX)" || exit 1
trap 'rm -rf "$BUILD"' EXIT
BIN="$BUILD/gtk-xinput-selftest"

# shellcheck disable=SC2207  # 要的就是按空白切分 pkg-config 的输出
INC=( $(pkg-config --cflags "${PKGS[@]}") )
# shellcheck disable=SC2207
LIB=( $(pkg-config --libs "${PKGS[@]}") )
# 与 ③ 同一条理由：cc 一步编+链，libm 必须排在 adapter 之后（GNU ld 单遍扫描
# + --as-needed），否则 llround 那一族会报 DSO missing from command line。
LIB+=("-lm")
INC+=("-I$ROOT/backends/native-common" "-I$ROOT/backends/native-linux" "-I$HOME/.moon/include")

echo "[gtk-xinput] 编译：真 GTK4 头 + 同一份 adapter_native_gtk.c"
"$CC_BIN" -Wall -Wextra -o "$BIN" "$TEST" "$SRC" "${INC[@]}" \
  -DGDK_VERSION_MIN_REQUIRED=GDK_VERSION_4_6 \
  -DGDK_VERSION_MAX_ALLOWED=GDK_VERSION_4_6 \
  -DGLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_2_72 \
  -DGLIB_VERSION_MAX_ALLOWED=GLIB_VERSION_2_72 \
  "${LIB[@]}" "$MOONLIB" -Wl,--unresolved-symbols=ignore-in-object-files
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "[gtk-xinput] 编译/链接失败：见上面 ${CC_BIN} 输出" >&2
  exit 1
fi

# 与 ③ 同形：GtkWindow 在部分 GLib 版本上读 GSettings，缺 schema 时 GTK 是
# g_error() 直接 abort。用内存后端 + 发行版已编好的 schema，不往 /usr 写文件。
SCHEMAS="$(pkg-config --variable=prefix gtk4)/share/glib-2.0/schemas"
if [[ -d "$SCHEMAS" && -f "$SCHEMAS/gschemas.compiled" ]]; then
  export XDG_DATA_DIRS="$(dirname "$(dirname "$SCHEMAS")")${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
fi
export GSETTINGS_BACKEND="${GSETTINGS_BACKEND:-memory}"

if [[ "$NEGCTL" == "1" ]]; then
  # 语义负控制：一个事件都不发，selftest 的事件账全空，四条判据必须红。
  # 用来证明"没真输入就不会报绿"；不进 CI，也不写 done。
  echo "[gtk-xinput] NEGCTL：不发外部输入，期望 selftest 非 0"
  "$BIN" > "$BUILD/negctl.log" 2>&1
  rc=$?
  tail -n 20 "$BUILD/negctl.log"
  if [[ $rc -eq 0 ]]; then
    echo "[gtk-xinput] NEGCTL FAILED：零输入时判据竟全绿（判据不可观测）" >&2
    exit 1
  fi
  echo "[gtk-xinput] NEGCTL OK：零输入 rc=${rc}，判据确实点名红了"
  exit 0
fi

echo "[gtk-xinput] 启动 xdotool helper（另一进程，经 XTEST 发真输入）"
bash "$HELPER" "$BUILD" > "$BUILD/helper.log" 2>&1 &
HPID=$!

MOONUI_XINPUT_DIR="$BUILD" "$BIN"
rc=$?
wait "$HPID"
hrc=$?

echo "--- helper.log ---"
cat "$BUILD/helper.log"
if [[ $hrc -ne 0 ]]; then
  echo "[gtk-xinput] helper 退出码 ${hrc}：外部输入序列没发完" >&2
  exit 1
fi
if [[ $rc -ne 0 ]]; then
  echo "[gtk-xinput] 判据红：见上面 FAIL 行" >&2
  exit $rc
fi
echo "[gtk-xinput] OK：真 Tab / Shift+Tab / 真打字 / 真滚轮都经 XTEST 到账，"
echo "  焦点按声明链推进（不是 GTK z 序），滚轮 dy 反号；滚轮单位与倍数仍按 TODO T235 P8⑤ 留作未决"
