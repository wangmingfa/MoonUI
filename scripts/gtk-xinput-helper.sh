#!/usr/bin/env bash
# T235 P9 · 从**另一个进程**经 XTEST 给真 GTK4 窗口发真实输入。
#
# 由 scripts/gtk-xinput-check.sh 在后台启动，参数是握手套件的目录：
#   $1/ready  selftest 把窗口 present 出来、回调注册好之后写
#   $1/done   本脚本发完最后一颗事件之后写（selftest 等它，不靠固定 sleep）
#
# 为什么事件要从另一个进程发：GTK4 公开头没有 GdkEvent 构造函数，进程内
# 合成不了真事件（T235 P8⑥）。xdotool 走 XTEST，是 X11 上最接近真人的一条路。
# 它只在 X11 有效——Wayland 没有 XTEST，check.sh 会在入口 SKIP（CI 下 FAIL）。
#
# 序列与判据一一对应（scripts/gtk-xinput-selftest.c）：
#   Tab      b1 → b3      声明链 [b1,b3,entry]，GTK 默认 z 序会走到 b2
#   Tab      b3 → entry
#   type ab 焦点在 entry，两颗真键落进 GtkEntry
#   shift+Tab entry → b3  反向；ISO_Left_Tab 不在键名词表，所以焦点靠主循环采样
#   click 4 / click 5     两次垂直滚轮，判据验 dy 反号
#   shift+a               键名折成 'a' 且 mods 带 shift 位，验修饰键翻译
#
# 注意：xvfb 里没有窗口管理器，`windowactivate`（要 EWMH _NET_ACTIVE_WINDOW）
# 会挂住或失败，所以只用 XSetInputFocus 语义的 `windowfocus`，不带 --sync。
set -uo pipefail

DIR="${1:-}"
[[ -n "$DIR" ]] || { echo "[gtk-xinput-helper] 缺握手套件目录" >&2; exit 2; }

# 等窗口真上屏。ready 是 selftest 在 mapped + grab_focus 之后写的，所以这里
# 拿到它时，判据的事件账已经注册好了，不会漏掉第一颗键。
for _ in $(seq 1 120); do
  [[ -f "$DIR/ready" ]] && break
  sleep 0.05
done
if [[ ! -f "$DIR/ready" ]]; then
  echo "[gtk-xinput-helper] 6s 内没等到 ready：窗口没上屏？" >&2
  exit 1
fi

WID="$(xdotool search --onlyvisible --name moonui-xinput 2>/dev/null | head -n 1)"
if [[ -z "$WID" ]]; then
  echo "[gtk-xinput-helper] 找不到标题含 moonui-xinput 的可见窗口" >&2
  echo "[gtk-xinput-helper] xdotool search 全量输出：" >&2
  xdotool search --name . 2>&1 | head -n 20 >&2
  exit 1
fi
echo "[gtk-xinput-helper] 目标窗口 XID=${WID}"

xdotool windowfocus "$WID" || { echo "[gtk-xinput-helper] windowfocus 失败" >&2; exit 1; }
# 滚轮不带坐标，适配器的命中反查要用"上一颗鼠标事件的位置"，所以先把指针
# 移进窗口客户区；顺带让 XTEST 的按键发给有焦点的那只窗口。
xdotool mousemove --window "$WID" 60 60 || true
sleep 0.3
echo "[gtk-xinput-helper] 当前焦点 XID=$(xdotool getwindowfocus 2>/dev/null)"

# 每一步之间留 300ms：判据主循环每 5ms 采样一次焦点，足够看清每一次变化；
# 也不至于让整道闸慢到被人误认为挂住。
xdotool key Tab;          sleep 0.3
xdotool key Tab;          sleep 0.3
xdotool type --delay 80 'ab'; sleep 0.3
xdotool key --clearmodifiers shift+Tab; sleep 0.3
xdotool click 4;          sleep 0.3
xdotool click 5;          sleep 0.3
xdotool key --clearmodifiers shift+a; sleep 0.3

touch "$DIR/done"
echo "[gtk-xinput-helper] 序列发完，done 已写"
