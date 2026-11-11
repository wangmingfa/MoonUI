#!/usr/bin/env bash
# MoonUI · Linux 真机复验（`T235` 文件拖入交接 / `T251` ibus·fcitx5 组合相位）
#
# 为什么要有这个脚本：自动化的那几道闸只能证"机制接对了"——
#   · scripts/canvas-pixel-selftest.c 用 g_signal_emit_by_name 驱动组合相位、
#     用 GdkFileList 直接喂 drop 分发；
#   · P6-16 的 drag_hit_probe 只证"落点归属"，不证 GTK 真把 drop 交给谁。
# "文件管理器真把 URI 交给 GTK"和"ibus / fcitx5 真把 preedit 递进来"只有
# 真桌面能证。本脚本打印环境事实 + 清单，然后开 examples/linux-probe-native，
# 把 FileDrop / ImeStart / ImeCompose / ImeEnd / Input 五条事件原样打出来。
#
# 它**不是**门禁：不判红绿、不进 CI。判据仍以那几道闸为准；这里产出的是
# 人在真机上照单核对后抄进 TODO 的复验记录。
#
# 用法：bash scripts/linux-real-check.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "[linux-real] FAIL：$1" >&2
  exit 1
}

say() {
  echo "[linux-real] $1"
}

# 1. 宿主：只认 Linux 真桌面。xvfb 里没有文件管理器，也起不了输入法。
if [[ "$(uname -s)" != Linux ]]; then
  fail "这个脚本只在 Linux 真机上跑（当前 $(uname -s)）；mac / Windows 没有 X11 文件管理器与 ibus / fcitx5 这条链。"
fi
if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
  fail "没有 DISPLAY / WAYLAND_DISPLAY：请在一台真实桌面会话里跑，不要塞进 xvfb。"
fi
command -v moon >/dev/null 2>&1 || fail "PATH 里没有 moon。"
pkg-config --exists gtk4 2>/dev/null ||
  fail "pkg-config 找不到 gtk4（Ubuntu：sudo apt-get install libgtk-4-dev libcairo2-dev）"

# 2. 环境事实：先让人看见"输入法到底挂没挂上"，再谈期望。
say "会话：XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-未知} DISPLAY=${DISPLAY:-空} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-空}"
say "GTK：$(pkg-config --modversion gtk4)"
say "输入法环境：GTK_IM_MODULE=${GTK_IM_MODULE:-未设} XMODIFIERS=${XMODIFIERS:-未设} QT_IM_MODULE=${QT_IM_MODULE:-未设}"
if pgrep -x ibus-daemon >/dev/null 2>&1; then
  say "ibus：ibus-daemon 在跑"
elif command -v ibus >/dev/null 2>&1; then
  say "ibus：装了但 ibus-daemon 没在跑（先 ibus-daemon -drx，再用 Super+Space 切中文）"
else
  say "ibus：没装"
fi
if pgrep -x fcitx5 >/dev/null 2>&1; then
  say "fcitx5：fcitx5 在跑"
elif command -v fcitx5 >/dev/null 2>&1; then
  say "fcitx5：装了但没在跑（fcitx5 -d，再用 Ctrl+Space 切中文）"
else
  say "fcitx5：没装"
fi
echo ""
say "下面开窗。清单（A 拖入 / B 组合 / C 焦点）会同时打到终端与窗口日志。"
echo ""

# 3. 开探针。moon 命令按仓库约定在根目录跑。
cd "$ROOT" || fail "进不去仓库根 $ROOT"
moon run examples/linux-probe-native
rc=$?

# 4. 复验记录模板：人照终端里的事件行填，填完抄进 TODO 的 T235 / T251。
echo ""
say "探针已退出（rc=$rc）。把下面三项填进 TODO 的复验记录："
echo "  A 拖入：拖了 __ 个文件；终端 [FileDrop] __ 条；路径顺序与拖入一致？__；拖文本/链接时是否误报？__"
echo "  B 组合：输入法 __（ibus __ / fcitx5 __）；start __ 次 / compose __ 次 / end __ 次；最终 [Input] 全文 __；组合期间有逐键 Input？__"
echo "  C 焦点：点走再点回输入框，相位是否重新 start？__；取消组合（Esc）是否只有 end、没有 Input？__"
exit "$rc"
