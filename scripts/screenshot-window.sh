#!/usr/bin/env bash
# 窗口截图工具（T88③）：按窗口 id 截图 + 解码像素读数，批二/批四真窗批用过的
# /tmp 临时脚本固化成的产品化工具（mac 侧 `screencapture -x -l <id>` 路线已在
# T81 的 Scroll 滚动条批验证过——按窗 id 截 + 最小 PNG 解码像素断言）。
#
# 用法（三个子命令，参数化窗口 id 与输出路径）：
#   scripts/screenshot-window.sh list <pid> [layer]
#       列出某进程名下的窗口 id（CGWindowID）与几何——窗口 id 从这里取。
#       MoonUI 的窗口句柄是原生对象指针，不是 CGWindowID，所以要按 owner 进程
#       枚举一跳。layer 可选（默认 0，普通窗口层）。
#   scripts/screenshot-window.sh capture <window-id> [output]
#       按窗口 id 截图（静音、不含影子）。output 缺省落系统临时目录
#       （$TMPDIR/moonui-shot-<id>.png）——仓库里不留任何文件（AGENTS.md）。
#   scripts/screenshot-window.sh decode <png> [stride]
#       最小 PNG 解码（zlib inflate + unfilter，沿批二/批四的解码读数同款），
#       打印尺寸头 + 按步长采样的亮度矩阵（0-255）。像素断言按诊断逐次手写
#       ——亮度读数就是断言载体（批二读法：槽位亮度 ~237 + 滑块 ~171）。
#
# 为什么不接进门禁（记案）：截图断言依赖真窗交互——窗口要真的开在屏幕上、
# 真人停手操作才能截（真鼠标交错会让像素账假红，见记忆 warn-before-real-
# window-tests 的同一条理由）。它是手工诊断工具，不是 CI——真窗批的等价
# CI 验证是 backends/native-macos 的真窗口测试（T6 起真跑）。
#
# 零 Python（2026-11-09）：list 由 scripts/window-list.c 现编的 C helper 直调
# CoreGraphics，decode 用 scripts/png-decode.js（Node 内置 zlib），capture 只用
# 系统 screencapture。既不装包也不引 npm 依赖——macOS 自带 cc / shasum / node 即可。
# 平台：三个子命令都只在 macOS 上有意义（screencapture / CoreGraphics），
# 其它平台明确报错退出，不静默。
#
# 两处旧缺陷**故意照抄**以保住旧行为（见 TODO `T242`）：① list 传给
# CGWindowListCopyWindowInfo 的是 2，它不是旧注释里写的 "all windows"，
# 而是 kCGWindowListOptionOnScreenAboveWindow（All=0，实测 386 窗 vs 59 窗）；
# ② bounds 字典的键拼成 "kCGWindowBoundsX" 等，实际取不到值，几何恒
# [0,0 0x0]。换语言不改语义，要修单独一条。

set -eu

usage() {
  grep '^#  ' "$0" | sed 's/^#  //'
  exit "${1:-0}"
}

need_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "screenshot-window.sh 只在 macOS 上有意义（screencapture / CoreGraphics），当前宿主：$(uname -s)" >&2
    exit 2
  fi
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 只有 decode 需要 node；MoonBit 工具链本来就跑 Node（prebuild-link.js），
# 缺了就明确报错，不静默。
need_node() {
  if ! command -v node >/dev/null 2>&1; then
    echo "需要 node（png-decode.js 只用内置模块，不装包）" >&2
    exit 2
  fi
}

# C helper 现编到临时目录，按**源码内容哈希**复用（约 0.2s）。别用 `-nt`：
# 同一秒内改写源码时 mtime 判不出脏，会静默跑旧二进制（负控制实测踩过，
# 两条改动因此假绿）。哈希键改了名字就变，不存在脆索引。
build_window_list() {
  local src="$ROOT/scripts/window-list.c"
  local sum bin
  sum="$(shasum -a 256 "$src")" || { echo "算不出 $src 的哈希" >&2; exit 2; }
  sum="${sum%% *}"
  bin="${TMPDIR:-/tmp/}moonui-window-list-${sum:0:12}"
  if [[ ! -x "$bin" ]]; then
    cc -O2 -framework CoreGraphics -framework CoreFoundation -o "$bin" "$src" || {
      echo "编译 $src 失败（需要 macOS CLT / Xcode 的 cc）" >&2
      exit 2
    }
  fi
  echo "$bin"
}

tmp_base() {
  echo "${TMPDIR:-/tmp/}"
}

# list：按 owner 进程枚举窗口 id。C helper 直调 CoreGraphics 的
# CGWindowListCopyWindowInfo（C 函数，CFArray/CFDictionary 读出来），
# 不依赖任何第三方库，也不需要 Python ctypes。
cmd_list() {
  need_macos
  local pid="${1:?用法: list <pid> [layer]}"
  local layer="${2:-0}"
  local bin
  bin="$(build_window_list)"
  "$bin" "$pid" "$layer"
}

# capture：按窗口 id 截图。output 缺省落系统临时目录。
cmd_capture() {
  need_macos
  local wid="${1:?用法: capture <window-id> [output]}"
  local out="${2:-$(tmp_base)moonui-shot-${wid}.png}"
  mkdir -p "$(dirname "$out")"
  # -x 静音（不出快门声）、-l 按窗口 id、-o 不含窗口影子
  screencapture -x -o -l "$wid" "$out"
  echo "$out"
}

# decode：最小 PNG 解码 + 亮度采样。PNG 是 zlib 压缩的 IDAT 流，
# unfilter 五种滤波（None/Sub/Up/Average/Paeth）后按 stride 采样打印。
cmd_decode() {
  need_macos
  need_node
  local png="${1:?用法: decode <png> [stride]}"
  local stride="${2:-8}"
  node "$ROOT/scripts/png-decode.js" "$png" "$stride"
}

case "${1:-}" in
  list) shift; cmd_list "$@" ;;
  capture) shift; cmd_capture "$@" ;;
  decode) shift; cmd_decode "$@" ;;
  *) usage 1 ;;
esac
