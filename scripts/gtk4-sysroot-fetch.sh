#!/usr/bin/env bash
# 在 macOS 上备一份**私有 GTK4 sysroot**，只为跑 scripts/gtk4-sysroot-check.sh。
#
# 为什么不用 `brew install gtk4`：
#   ① 它会动系统——实测要顺带升级 9 个已装依赖（glib 2.86→2.90、libpng、jpeg-turbo、
#      xz、lz4、libtiff、pcre2、brotli、libunistring）；为了验头文件去换共享库不值。
#   ② 它还会拉一堆构建依赖（go / rust / dart-sdk / z3 / docbook…），纯浪费。
#   ③ brew 7 的解包步骤自己起 sandbox-exec，在受限环境里直接失败。
# 这里只做两件事：**下载** bottle、**解包**到私有目录。系统一个字节不动。
#
# 用法：
#   bash scripts/gtk4-sysroot-fetch.sh [目标目录]     # 默认 /tmp/gtk4-sysroot
# 之后：
#   bash scripts/gtk4-sysroot-check.sh
#
# 注意 /tmp 会被系统清理，所以这份 sysroot 是**一次性**的：想长期留着就把目标目录
# 指到持久位置；CI/Linux 上根本不需要它（pkg-config --cflags gtk4 直接给全）。
set -uo pipefail

SYS="${1:-/tmp/gtk4-sysroot}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "[sysroot] 非 macOS：不需要这套。Linux 上直接用 pkg-config --cflags gtk4。" >&2
  exit 0
fi
command -v brew >/dev/null || { echo "[sysroot] 没有 brew" >&2; exit 1; }

if [[ -f "$SYS/include/gtk-4.0/gtk/gtk.h" ]]; then
  echo "[sysroot] 已存在，跳过：$SYS"
  exit 0
fi

# 只点名**带头的**那几个，不要 --deps（会把构建依赖一起拉下来）。
PKGS=(
  gtk4 glib pango cairo gdk-pixbuf graphene harfbuzz fribidi
  libepoxy freetype fontconfig libpng pixman gettext libffi pcre2
)

echo "[sysroot] 下载 bottle（已缓存的会跳过）：${#PKGS[@]} 个"
# 不加 --force：那会把已缓存的 bottle 删了重下，只补缺的那几个。
# 分两个分支而不是攒一个空数组：bash 3.2 在 set -u 下展开空数组
# （"${ARR[@]}"）会直接报 unbound variable。
if [[ -n "${GTK4_BOTTLE_TAG:-}" ]]; then
  brew fetch --bottle-tag="$GTK4_BOTTLE_TAG" "${PKGS[@]}" || {
    echo "[sysroot] brew fetch 失败" >&2; exit 1
  }
else
  brew fetch "${PKGS[@]}" || {
    echo "[sysroot] brew fetch 失败" >&2; exit 1
  }
fi

# brew --cache 给的是缓存根目录；bottle 落在它的 downloads/ 子目录里
# （直接拿根目录去 glob 会一个都找不到，报"缺 xxx 的 bottle"）。
CACHE="$(brew --cache)/downloads"
[[ -d "$CACHE" ]] || { echo "[sysroot] 找不到 bottle 缓存目录：$CACHE" >&2; exit 1; }

mkdir -p "$SYS"
n=0
for pkg in "${PKGS[@]}"; do
  f="$(ls -t "$CACHE"/*--"$pkg"--*.tar.gz 2>/dev/null | head -1)"
  if [[ -z "$f" ]]; then
    echo "[sysroot] 缺 $pkg 的 bottle（上面 brew fetch 可能报了错）" >&2
    exit 1
  fi
  # bottle 布局是 <pkg>/<ver>/...，去掉两级正好得到 include/ 与 lib/。
  tar -xzf "$f" -C "$SYS" --strip-components=2 2>/dev/null || {
    echo "[sysroot] 解包失败：$f" >&2; exit 1
  }
  n=$((n + 1))
done

if [[ ! -f "$SYS/include/gtk-4.0/gtk/gtk.h" ]]; then
  echo "[sysroot] 解包后没找到 include/gtk-4.0/gtk/gtk.h，bottle 布局变了？" >&2
  exit 1
fi
echo "[sysroot] OK：$n 个 bottle → $SYS"
echo "[sysroot] 下一步：bash scripts/gtk4-sysroot-check.sh"
