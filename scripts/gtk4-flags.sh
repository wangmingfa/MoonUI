#!/usr/bin/env bash
# GTK4 编译期旗标的**唯一来源**（`T235 P8`）。
#
# 为什么要有这一份：真头闸（gtk4-sysroot-check.sh）与 ABI 符号核对
# （abi-symbols.sh）都要拿「真 GTK4 头 + 仓库头 + moonbit 头」这套 -I 去编
# 同一份 adapter_native_gtk.c。这套目录表有 16 条，其中一条（libunistring 自带
# 的 include/unistring/stdint.h 会顶掉系统 <stdint.h>）是踩过的坑——抄第二份的
# 那天起，两份就会各走各的。所以只留这一份，两边都问它。
#
# 用法（只读查询，一次一个；都不写文件）：
#   bash scripts/gtk4-flags.sh mode          # 输出 sysroot / pkgconfig；拿不到头则 exit 2
#   bash scripts/gtk4-flags.sh sysroot-path  # 私有 sysroot 路径，回落时输出 "(system)"
#   bash scripts/gtk4-flags.sh version       # GTK4 版本，如 4.24 / 4.6.9
#   bash scripts/gtk4-flags.sh cflags        # 一行一个 flag（已含仓库头与 moonbit 头）
#
# 环境：
#   GTK4_SYSROOT     私有 sysroot（默认 /tmp/gtk4-sysroot）
#   MOONUI_HOST_OS   覆盖宿主判定（mac 上干跑 Linux 分支用）
#   CC / HOME        与其它闸一致
#
# 双宿主的差别只有「头从哪来」：mac 上只有私有 sysroot（系统没有 GTK4），
# Linux 上系统就有——缺 sysroot 时回落 pkg-config（与 prebuild-link.js 的
# linuxNativeCompileFlags 同源）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYS="${GTK4_SYSROOT:-/tmp/gtk4-sysroot}"
HOST="${MOONUI_HOST_OS:-$(uname -s)}"

# 私有 sysroot 在不在：判据是 gtk.h，不是目录在不在（空目录也算「没有」）。
have_sysroot() { [[ -f "$SYS/include/gtk-4.0/gtk/gtk.h" ]]; }
# 能不能回落 pkg-config：只有 Linux 宿主才这么干（mac 上没有系统 GTK4）。
have_pkgconfig() {
  [[ "$HOST" == "Linux" || "$HOST" == "linux" ]] &&
    command -v pkg-config >/dev/null 2>&1 &&
    pkg-config --exists gtk4 2>/dev/null
}

case "${1:-}" in
  mode)
    if have_sysroot; then
      echo sysroot
    elif have_pkgconfig; then
      echo pkgconfig
    else
      exit 2
    fi
    ;;
  sysroot-path)
    if have_sysroot; then echo "$SYS"; else echo "(system)"; fi
    ;;
  version)
    if have_sysroot; then
      awk '/define GTK_MAJOR_VERSION/{ma=$3} /define GTK_MINOR_VERSION/{mi=$3} \
        END{gsub(/[()]/,"",ma); gsub(/[()]/,"",mi); print ma "." mi}' \
        "$SYS/include/gtk-4.0/gtk/gtkversion.h" 2>/dev/null
    elif have_pkgconfig; then
      pkg-config --modversion gtk4
    else
      exit 2
    fi
    ;;
  cflags)
    if have_sysroot; then
      # 搜索路径**显式列举**，不要"把 include/ 下每个子目录都加进来"：
      # libunistring 自带 include/unistring/stdint.h，把它放上 -I 就会顶掉系统的
      # <stdint.h>，症状是一堆 "unknown type name uint64_t"（2026-11-08 实测踩过）。
      # 这份列表就等于 pkg-config --cflags 在 Linux 上会给的那几个目录。
      for d in \
        "$SYS/include" \
        "$SYS/include/gtk-4.0" \
        "$SYS/include/glib-2.0" \
        "$SYS/lib/glib-2.0/include" \
        "$SYS/include/gio-unix-2.0" \
        "$SYS/include/pango-1.0" \
        "$SYS/include/cairo" \
        "$SYS/include/gdk-pixbuf-2.0" \
        "$SYS/include/graphene-1.0" \
        "$SYS/lib/graphene-1.0/include" \
        "$SYS/include/harfbuzz" \
        "$SYS/include/fribidi" \
        "$SYS/include/freetype2" \
        "$SYS/include/fontconfig" \
        "$SYS/include/libpng16" \
        "$SYS/include/pixman-1"; do
        [[ -d "$d" ]] && echo "-I$d"
      done
    elif have_pkgconfig; then
      # pkg-config 的输出按空白切（一行一个），调用方直接 while read 收进数组。
      # shellcheck disable=SC2046
      for f in $(pkg-config --cflags gtk4 cairo); do echo "$f"; done
    else
      exit 2
    fi
    echo "-I$ROOT/backends/native-common"
    echo "-I$ROOT/backends/native-linux"
    echo "-I$HOME/.moon/include"
    ;;
  *)
    echo "用法：bash scripts/gtk4-flags.sh {mode|sysroot-path|version|cflags}" >&2
    exit 64
    ;;
esac
