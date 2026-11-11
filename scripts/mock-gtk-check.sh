#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# T235 P3：在 macOS（无 GTK4 头）上验 GTK4 适配器里**本机可证的部分**。两段：
#
#   ① 语法检查（cc -fsyntax-only）：括号 / 帮助函数 / 未声明符号拼写等。不验证
#      GTK4 真实 API 正确性——那一步在 scripts/gtk4-sysroot-check.sh（真 GTK4 头，
#      本机就能跑）；真链接与真窗行为才在 Linux 真机（CI 的 linux-backend-link，
#      P7 起这个 job 也跑本脚本，所以这一层在 ubuntu 上有同一份判据）。
#   ② 纯逻辑自检（编译并**真跑**）：键名词表、pack2 打包、修饰键位、鼠标钮号
#      映射，以及对话框码表、菜单树、P6-4b 的 CSS 拼串与深色判定（第 10 组）、
#      P6-4c 的无障碍角色表 / state 位包 / 按长度复制 / 偏好读数（第 11 组）、
#      P6-5 的 kind → 构造形态表 / 文案通道号 / 按长度复制（第 12 组）；P6-5b 的焦点链 ids 解析 / 下一跳 / 自绘面点击判定 / Tab 推进（第 13 组）；P6-5c 的日期文本解析 `moonui_gtk_parse_datetime`（第 14 组）；T241 的 display scale 注入（第 15 组）；T235 P6-7 的渲染后端名字表与偏好文件往返（第 16 组）；T235 P6-8 的应用身份 / 显式缺席 / 目录行走（第 17 组）；T235 P6-9 图像源两条的返回码三态 / GError 释放 / 纹理与 GBytes 引用配平（第 18 组）；T235 P6-10 文件拖入的路径编码布局 / target 读回 / 空数组清空 / 重复装载覆盖（第 19 组）；T235 P6-11 WebView 五条的显式缺席码值（第 20 组）；T235 P6-12 后台任务的真 pthread 起线程 / 落地投递 / 引用配平（第 21 组）；T235 P6-13 输入法组合四条的监听簿记 / 空状态读回（第 22 组）；T251 组合相位旁听的取口 / 相位机 / 销毁清账（第 23 组）；T235 P6-15 / T252 中性桩收口的 30 条显式缺席码与 5 条如实读数（第 24 组）；全组共 595 项纯逻辑判据（以本脚本实跑输出为准）。
#      这几块不调 GTK，所以在 macOS 上能拿到可执行判据——键名拼错一处，
#      Linux 上那类键会静默变成"没有事件"，这条自检就是为它设的。
#
# 用法：bash scripts/mock-gtk-check.sh
#
# 两个宿主都能跑（T235 P7）：这道闸不碰真 GTK，只差"未定义符号怎么放行"这一条
# 链接参数。宿主按 uname 判，MOONUI_HOST_OS 可覆盖（本机干跑另一条分支用），
# CC 可换编译器（与 canvas-pixel-check.sh 同一个口子）。
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/backends/native-linux/adapter_native_gtk.c"
MOCK="$REPO/scripts/mock-gtk.h"
SELFTEST="$REPO/scripts/mock-gtk-selftest.c"
TMP="$(mktemp /tmp/adapter_native_gtk_mock.XXXXXX.c)"
TMPRUN="$(mktemp /tmp/adapter_native_gtk_selftest.XXXXXX.c)"
BIN="$(mktemp /tmp/adapter_native_gtk_selftest.XXXXXX)"
MOON_INCLUDE="${MOON_INCLUDE:-$HOME/.moon/include}"
CC_BIN="${CC:-cc}"
HOST="${MOONUI_HOST_OS:-$(uname -s)}"

cleanup() { rm -f "$TMP" "$TMPRUN" "$BIN"; }
trap cleanup EXIT

if [ ! -f "$SRC" ]; then echo "[mock-check] 找不到 $SRC" >&2; exit 1; fi
if [ ! -f "$MOCK" ]; then echo "[mock-check] 找不到 $MOCK" >&2; exit 1; fi
if [ ! -f "$SELFTEST" ]; then echo "[mock-check] 找不到 $SELFTEST" >&2; exit 1; fi
if [ ! -d "$MOON_INCLUDE" ]; then echo "[mock-check] 找不到 moonbit.h 目录 ${MOON_INCLUDE}（MOON_INCLUDE 可覆盖）" >&2; exit 1; fi

# 把真实 GTK 包含换成 mock 头（gdk/gdk.h 一并去掉）
node -e 'const fs = require("fs");
let s = fs.readFileSync(process.argv[1], "utf8");
s = s.replace("#include <gtk/gtk.h>", `#include "${process.argv[2]}"`);
s = s.replace("#include <gdk/gdk.h>", "");
fs.writeFileSync(process.argv[3], s);' "$SRC" "$MOCK" "$TMP"

INC=(-I"$REPO/backends/native-common" -I"$REPO/backends/native-linux" -I"$MOON_INCLUDE")

# `-DMOONUI_MOCK_GTK` 是**必须**的，不是可选开关（T235 P4 加进 `canvas_gtk.inc`
# 之后才需要）：那份 .inc 是整段手写的 cairo/pango/pixbuf 实现，假头里没有这些
# 库的声明，所以生成器把它包在 `#ifndef MOONUI_MOCK_GTK` 里、并在末尾
# `#ifdef MOONUI_MOCK_GTK` 下补了 24 条同签名替身。不定义这个宏时编译器会真去
# `#include <cairo.h>`——mac 上没有那个头，① 直接报 `'cairo.h' file not found`。
# 实测症状（2026-11-08）：单独跑 gtk4-sysroot-check 与 canvas-pixel-check 都绿，
# 只有全量门禁会红在这里，因为那两道闸都拿**真** sysroot、从不走假头这条路。
DEFS=(-DMOONUI_MOCK_GTK)

# ---- ① 语法 ----
"$CC_BIN" -fsyntax-only -pthread "${DEFS[@]}" "${INC[@]}" "$TMP"
RC1=$?
if [ $RC1 -ne 0 ]; then
  echo "[mock-check] ① 语法检查失败：见上面 cc 输出" >&2
  exit $RC1
fi
echo "[mock-check] ① 语法 OK（这只证 C 自洽；API 用法要过 gtk4-sysroot-check.sh）"

# ---- ② 纯逻辑自检（同一翻译单元，静态函数可见；运行时符号留未定义）----
cat "$TMP" "$SELFTEST" > "$TMPRUN"
# 未定义符号怎么放行，两个宿主写法不同（T235 P7，为了让这道闸在 ubuntu 的 CI
# 上也跑）：macOS 靠 dyld 的延迟绑定（-undefined,dynamic_lookup）；Linux 上 GNU
# ld 默认把可执行里的未定义符号当硬错误，等价物是
# --unresolved-symbols=ignore-in-object-files（**只**放过目标文件里的未定义符号，
# 共享库之间照旧逐个核对）。两条的语义一样：只有真被调用到时才会炸，而自检调用
# 的 GTK 函数全在下面这份假头 + selftest 的替身里。
case "$HOST" in
  Darwin|darwin|macos) LINK_UNDEF=(-Wl,-undefined,dynamic_lookup) ;;
  *)                   LINK_UNDEF=(-Wl,--unresolved-symbols=ignore-in-object-files) ;;
esac
"$CC_BIN" -o "$BIN" -pthread "${DEFS[@]}" "${INC[@]}" "$TMPRUN" "${LINK_UNDEF[@]}"
RC2=$?
if [ $RC2 -ne 0 ]; then
  echo "[mock-check] ② 自检编译失败：见上面 cc 输出" >&2
  exit $RC2
fi
"$BIN"
RC2=$?
if [ $RC2 -ne 0 ]; then
  echo "[mock-check] ② 纯逻辑自检红：见上面 FAIL 行" >&2
  exit $RC2
fi
echo "[mock-check] 全部 OK：语法 + 纯逻辑判据（真头编译见 gtk4-sysroot-check.sh，真链接+真跑见 canvas-pixel-check.sh）"
exit 0
