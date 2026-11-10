#!/usr/bin/env bash
# 用**真 GTK4 头**编一遍 Linux 适配器（T235）。
#
# 为什么要有这道：scripts/mock-gtk-check.sh 用的是我们自己写的假头（scripts/mock-gtk.h），
# 它只能证明「C 结构 / 类型 / 签名自洽」，**证不了 GTK4 的 API 名字与签名用对了**。
# 真头在手上才能证那一层——而这一层正是最容易写错的地方：P3 第一次跑这道闸就抓出
# 5 处 GTK3 遗留（gtk_main_iteration_do / gtk_events_pending / gtk_window_resize /
# gdk_display_get_scale_factor / gtk_widget_hide 弃用），假头一个都发现不了。
#
# 两道闸：
#   ① 默认（以 sysroot 里的头为准，当前 4.24）：抓「GTK4 里根本没有这个函数」。
#   ② 最低版本闸（GDK_VERSION_MAX_ALLOWED=4.6）：抓「用了比 4.6 新的 API」。
#      4.24 的头会无条件接受新 API，而 Ubuntu 22.04 只有 4.6；不设这道，
#      写出来的代码在旧发行版上直接编不过，而我们本机看不见。
#      机制已验证：故意用 4.12 的 gtk_css_provider_load_from_string，这道会报
#      "Not available before 4.12"。
#      2026-11-10 起两档都另带 GLIB_VERSION_{MIN_REQUIRED,MAX_ALLOWED}=2.72
#      （glversion 的同一套机制，两条必须成对）：Ubuntu 22.04 的 glib 是 2.72，
#      而 glib >=2.78 的 gmem.h 会把 `g_free(mem)` 展开成
#      `g_free_sized(mem, __builtin_object_size(..))`，不钉住就隐含依赖 2.78+
#      的符号（T235 CI 首跑② 记下的第三枚缺口）。只写 MAX 时
#      gversionmacros.h 的 sanity check 会 #error（MIN 默认 CUR_STABLE > MAX），
#      gstring.h 的 g_string_free 宏还会按 MIN >= 2.76 展开成 2.76 API，
#      让 -Werror=deprecated-declarations 把 glib 自己的头判成红。
#      生成物 prelude 与 prebuild-link.js 的 Linux 编译参数都写了同一对。
#
# 用法：
#   bash scripts/gtk4-sysroot-check.sh              # 用 $GTK4_SYSROOT 或 /tmp/gtk4-sysroot
#   GTK4_SYSROOT=/path bash scripts/gtk4-sysroot-check.sh
#   GTK4_MIN_MINOR=8 bash scripts/gtk4-sysroot-check.sh   # 改最低版本口径
#
# sysroot 怎么来（macOS，不装系统包、不动 brew 已装依赖）：
#   brew fetch --force --bottle-tag=arm64_sequoia gtk4 glib pango cairo gdk-pixbuf \
#     graphene harfbuzz fribidi libepoxy freetype fontconfig libpng pixman gettext libffi pcre2
#   对每个 bottle tarball：tar -xzf <f>.tar.gz -C $GTK4_SYSROOT --strip-components=2
#   （bottle 布局是 <pkg>/<ver>/...，去掉两级正好得到 include/ 与 lib/）
# Linux 上不需要这套：pkg-config --cflags gtk4 直接给全。T235 P7 起脚本自己认
# 这件事——$GTK4_SYSROOT 下没有头、宿主又是 Linux 时，回落 pkg-config（CI 的
# linux-backend-link 走的正是这条），两档版本口径不变。
#
# 边界：只做 -fsyntax-only（预处理 + 类型检查），**不链接**，也不证明运行时行为。
# 真窗判据在 Linux 真机（CI linux-backend-link）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN_MINOR="${GTK4_MIN_MINOR:-6}"
SRC="${GTK4_SRC:-$ROOT/backends/native-linux/adapter_native_gtk.c}"
CC_BIN="${CC:-cc}"
FLAGS="$ROOT/scripts/gtk4-flags.sh"

# 头从哪来（mac 的私有 sysroot / Linux 系统自带的 GTK4）由**旗标助手**统一判
# ——那一套 -I 目录表只留一份（T235 P8 抽出来的），这里不再抄第二遍。
# 两份都拿不到才是 SKIP：那句"SKIP ≠ PASS"必须说出来，静默跳过会被读成已覆盖。
if ! bash "$FLAGS" mode >/dev/null 2>&1; then
  echo "[gtk4-check] SKIP：${GTK4_SYSROOT:-/tmp/gtk4-sysroot} 下没有 GTK4 头（见本脚本头部注释里的 brew fetch 配方）"
  echo "[gtk4-check] SKIP ≠ PASS：真头验证这一次没做。"
  exit 0
fi
SYS="$(bash "$FLAGS" sysroot-path)"
INC=()
while IFS= read -r f; do INC+=("$f"); done < <(bash "$FLAGS" cflags)

MOONINC="$HOME/.moon/include"
[[ -d "$MOONINC" ]] || { echo "[gtk4-check] 找不到 moonbit 头：$MOONINC" >&2; exit 1; }

VER="$(bash "$FLAGS" version)"
echo "[gtk4-check] sysroot=$SYS  gtk4=${VER:-?}  最低版本口径=4.${MIN_MINOR}"

# ① 抓「不存在 / 已删除 / 已弃用」的 API。真头下这些就是硬错误与真警告。
"$CC_BIN" -fsyntax-only -Wall -Wextra -x c \
  -DGLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_2_72 \
  -DGLIB_VERSION_MAX_ALLOWED=GLIB_VERSION_2_72 "${INC[@]}" "$SRC"
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "[gtk4-check] FAILED(①)：真 GTK4 头下编不过——这是**真实缺陷**，按报错改 C。"
  exit $rc
fi

# ② 抓「比最低口径更新」的 API。注意这类只报警告（-Wdeprecated-declarations），
#    所以必须 -Werror 才拦得住。
"$CC_BIN" -fsyntax-only -Wall -Wextra -Werror=deprecated-declarations -x c \
  -DGDK_VERSION_MIN_REQUIRED=GDK_VERSION_4_"$MIN_MINOR" \
  -DGDK_VERSION_MAX_ALLOWED=GDK_VERSION_4_"$MIN_MINOR" \
  -DGLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_2_72 \
  -DGLIB_VERSION_MAX_ALLOWED=GLIB_VERSION_2_72 \
  "${INC[@]}" "$SRC"
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "[gtk4-check] FAILED(②)：用了比最低口径更新的 API（报错里写着 Not available before X.Y）。"
  echo "[gtk4-check] 两档口径：GTK 4.${MIN_MINOR} 与 glib 2.72（Ubuntu 22.04）。4.x 那条改 API 或抬 GTK4_MIN_MINOR；"
  echo "[gtk4-check] 2.7x 那条是 glib 新 API（含 g_free_sized 那类隐含依赖），换旧 API 或抬最低系统版本。"
  exit $rc
fi

echo "[gtk4-check] OK：真头下通过预处理与类型检查，两套最低口径都守住（GTK 4.${MIN_MINOR} / glib 2.72，未链接）。"
