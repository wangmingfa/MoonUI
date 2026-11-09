#!/usr/bin/env bash
# MoonUI · Linux/GTK4 后端（T235 P4~P6-5b）——在 **macOS 上真跑**的判据。
#
# 这道闸补的是另外两道闸的盲区：
#   ① scripts/mock-gtk-check.sh      假头语法 + 纯逻辑（不需要 GTK4）
#   ② scripts/gtk4-sysroot-check.sh  真头**编译**（-fsyntax-only，不链接）
#   ③ 本脚本                          真头编译 + **真链接 + 真跑**：像素 / 控件层结构 /
#                                    剪贴板 / 对话框 / 菜单 / 主题 / 无障碍 / 控件叶子 / 焦点链 / 自绘面点击 / 滚动内容，逐条断言
#                                    行为而不是"能编过"
#
# 为什么能跑：画布只用 cairo（pixman 软件光栅）+ pango + gdk-pixbuf，不碰显示
# 服务器。brew 的 bottle 是 arm64 macOS 二进制，scripts/macos-cairo-runtime.js
# 把它们拼成一个私有可运行目录（不动系统、不装包），于是这份 C 能在本机跑起来。
#
# P6-1 起这道闸还跑**控件层结构**：2026-11-08 实测 `gtk_init_check()` 在 macOS
# 无显示器时也返回 1，`gtk_fixed_new` / `gtk_drawing_area_new` / `gtk_overlay_new`
# 都造得出来，所以"造控件 / attach / 摆放 / 层叠 / 摘挂 / 画布与控件共存"这几条
# 也是真 GTK4 真跑（不是假 widget 树）。
#
# P6-2 起还跑**剪贴板写读往返**（真 `GdkClipboard`）。注意这一组**会临时动系统
# 剪贴板**：每条判据先备份、出口恢复（实测跑完不留痕），但原本是图片之类的非文本
# 内容会被清掉——ABI 只有文本这一形，保不真。
#
# P6-3 起还跑**消息框真应答**（真 `GtkMessageDialog`）：会在桌面上闪一下原生对话框
# （0ms 就被替按掉），这是"真跑"的代价。文件面板那组默认 SKIP——`GtkFileChooserNative`
# 一 show 就去读 `org.gtk.Settings.FileChooser`，schema 不可用时 GTK 是 `g_error()`
# 直接把进程带走（不是返回错误码）。所以下面先尝试编译 schema 并挂到 XDG_DATA_DIRS，
# 只有成功了才导出 MOONUI_FILE_PANEL=1 让那组跑起来。
#
# P6-4a 起还跑**菜单**（真 `GtkPopoverMenuBar` + `GMenuModel` + `GSimpleActionGroup`）：
# dump 读的是 `gtk_popover_menu_bar_get_menu_model` 取到的**真正挂上的**模型（不是
# 我们自己的账），点击走 `g_action_group_activate_action`（与用户点菜单项同一条
# 派发）。这一组还有一个"进程全局"的坑：菜单栏是应用级的，上一组装过的会连累下一组
# 新建的窗口，所以拆菜单那条判据开头先把残留清掉。
#
# P6-4b 起还跑**主题**（真 GtkSettings 两代深色读口 + 真 GtkCssProvider）：
# CSS 读 GTK 解析器规范化后的文本（不是我们手写的原串），前景/字号那一层用
# GTK 的**样式级联**验——往实现那只 provider 追加一条 color 规则，再读一只带
# 同款 class 的 GtkLabel 算出来的颜色；只删掉 add_provider_for_display 的话，
# provider 自己的 CSS 文本与 class 两条照旧绿，只有这条级联判据会红。
#
# P6-4c 起还跑**无障碍**（真 GtkAccessible + 真 GtkSettings 的两条偏好）：
# 语义那半读 GTK 自己的 test AT context（gtk_test_accessible_check_property /
# check_state）与 gtk_accessible_get_accessible_role，不是读实现那份待办账；
# DISABLED/HIDDEN 两条 A/B 专门盯「不许把重排快照盖到 GTK 活的 sensitive /
# visible 上」（T58 在 MSAA 上量出来的谎报）。证不了 AT-SPI 消费端与真人听朗读。
#
# P6-5 起还跑**控件叶子**（十种真 GTK 对象）：类型读 G_OBJECT_TYPE_NAME、文案读
# GTK 自己的 getter、占位与文本两条独立通道、勾选读 active、三条回调经
# g_signal_emit_by_name 真派发；程序化 set_text / set_checked 不许回声成 Input /
# Change（探针实测 GTK 自己会发信号，实现靠 inhibit 吞）。真 GtkLabel 上另验
# P6-4b 当时欠的 fg / font / weight 三条通道：读样式级联颜色与 Pango 字号字重。
# 证不了真人上屏点击与 Tab 链真遍历（P8 xvfb 真窗）。
#
# 它**证不了**的：真窗口上屏（attach/present 要 GTK 显示服务器，只在 Linux 真机
# + xvfb；控件那侧对应的是"上屏后的真实分配尺寸"）、字体度量与 Linux 的差异
# （selftest 里文本只验"量得出、画得上"）、剪贴板的**跨进程**交接（这里是自己
# 写自己读）、文件面板走 **portal** 的形态（本机走内置 GtkFileChooserDialog）。
#
# 前置：sysroot 在 $GTK4_SYSROOT（默认 /tmp/gtk4-sysroot），由
#       scripts/gtk4-sysroot-fetch.sh 取。没有就 SKIP（不是 PASS）。
#
# 用法：bash scripts/canvas-pixel-check.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYS="${GTK4_SYSROOT:-/tmp/gtk4-sysroot}"
RUN="${MOONUI_CAIRO_RUNTIME:-/tmp/moonui-cairo-runtime}"
SRC="$ROOT/backends/native-linux/adapter_native_gtk.c"
TEST="$ROOT/scripts/canvas-pixel-selftest.c"
MOONLIB="${MOON_RUNTIME_OBJ:-$HOME/.moon/lib/libmoonbitrun.o}"
BIN="$RUN/canvas-pixel-selftest"

if [[ "$(uname -s)" != "Darwin" ]]; then
  # Linux 上另有真正的路径：pkg-config + moon test（CI 的 linux-backend-link）。
  echo "[canvas-pixel] SKIP：这道闸只服务 macOS 本机（Linux 走 pkg-config + CI）。"
  exit 0
fi
if [[ ! -f "$SYS/include/gtk-4.0/gtk/gtk.h" ]]; then
  echo "[canvas-pixel] SKIP：$SYS 下没有 GTK4 头（先跑 scripts/gtk4-sysroot-fetch.sh）"
  echo "[canvas-pixel] SKIP ≠ PASS：像素判据这一次没跑。"
  exit 0
fi
if [[ ! -f "$MOONLIB" ]]; then
  echo "[canvas-pixel] SKIP：找不到 ${MOONLIB}（moonbit 运行时对象；MOON_RUNTIME_OBJ 可覆盖）"
  exit 0
fi

# 私有 dylib 目录：幂等重建（脚本自己会 rmtree）。
#
# 加一把粗锁：重建期间目录是"半成品"，另一个实例此刻进来会读到缺符号的 dylib。
# 实测症状（2026-11-08）：`Symbol not found: _libintl_bind_textdomain_codeset` +
# `Aborted`，看着像代码错，其实只是并发。用 mkdir 的原子性当锁，失败直接说清楚，
# 不排队（排队会让"谁先谁后"变得不重要却更慢）。
LOCK="$RUN.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # 变量名后面紧跟中文标点时**必须**写 `${RUN}`：mac 自带的 /bin/bash 3.2 会把
  # 那个多字节字符的首字节吞进变量名，报 `RUN<?>: unbound variable`（实测踩过）。
  echo "[canvas-pixel] 另一个实例正在重建 ${RUN}（锁：${LOCK}）。这道闸不能并发跑。" >&2
  echo "  看到 Symbol not found / Aborted 多半就是这个，不是代码错。等它结束再跑；" >&2
  echo "  确认没有别的实例后，删掉 ${LOCK} 即可。" >&2
  exit 1
fi
# 清锁用两级：`rmdir` 在某些受限沙箱里会被拦（实测返回 EPERM），那就退回 Node。
# 不留兜底的话，一次被拦就会留下陈旧锁，把后续每一次运行都挡在门外——比原来的
# 偶发 dyld 报错更难查。
cleanup_lock() {
  rmdir "$LOCK" 2>/dev/null || \
    node -e 'require("fs").rmdirSync(process.argv[1])' "$LOCK" 2>/dev/null
}
trap cleanup_lock EXIT

node "$ROOT/scripts/macos-cairo-runtime.js" "$SYS" "$RUN" >/dev/null || {
  echo "[canvas-pixel] 私有运行时拼不起来" >&2
  exit 1
}

# 头搜索路径显式列举（别把 include/ 下每个子目录都放上：libunistring 自带
# unistring/stdint.h，会把系统的 <stdint.h> 顶掉）。
INC=()
for d in \
  "$SYS/include" "$SYS/include/gtk-4.0" "$SYS/include/glib-2.0" \
  "$SYS/lib/glib-2.0/include" "$SYS/include/gio-unix-2.0" \
  "$SYS/include/pango-1.0" "$SYS/include/cairo" "$SYS/include/gdk-pixbuf-2.0" \
  "$SYS/include/graphene-1.0" "$SYS/lib/graphene-1.0/include" \
  "$SYS/include/harfbuzz" "$SYS/include/fribidi" "$SYS/include/freetype2" \
  "$SYS/include/fontconfig" "$SYS/include/libpng16" "$SYS/include/pixman-1"; do
  [[ -d "$d" ]] && INC+=("-I$d")
done
INC+=("-I$ROOT/backends/native-common" "-I$ROOT/backends/native-linux" "-I$HOME/.moon/include")

cc -o "$BIN" "$TEST" "$SRC" "${INC[@]}" \
  -DGDK_VERSION_MIN_REQUIRED=GDK_VERSION_4_6 \
  -DGDK_VERSION_MAX_ALLOWED=GDK_VERSION_4_6 \
  -L"$RUN" -lgtk-4 -lgobject-2.0 -lglib-2.0 -lcairo -lpangocairo-1.0 -lpango-1.0 \
  -lgdk_pixbuf-2.0 -lgio-2.0 "$MOONLIB" -Wl,-undefined,dynamic_lookup
if [[ $? -ne 0 ]]; then
  echo "[canvas-pixel] 编译/链接失败：见上面 cc 输出" >&2
  exit 1
fi

# 链接器给可执行记的是"我找到的那个文件名"（-lcairo 找到的是别名 libcairo.dylib），
# 而 dylib 之间记的是真实文件名；两条路径指同一个文件时 dyld 会当成两份加载
# （objc 会抱怨 class 重复实现）。这里把可执行自己的依赖也统一成真实文件名。
node "$ROOT/scripts/fix-dylib-aliases.js" "$BIN" "$RUN"

# P6-3 的文件面板判据要 GSettings schema。私有 sysroot 里只有 `*.gschema.xml`、没有
# 编译产物 `gschemas.compiled`（brew bottle 不带），而 GtkFileChooserNative 一 show
# 就要读 `org.gtk.Settings.FileChooser`，读不到时 GTK 走 `g_error()` —— 那是 abort，
# 不是返回错误码。所以先编一份，再挂到 XDG_DATA_DIRS 上：
#   - GSETTINGS_BACKEND=memory 是为了让 GSettings 别去找 dconf（沙箱里没有 session bus；
#     探针实测不设这个会在 destroy 阶段同样 abort）；
#   - 两件都齐了才导出 MOONUI_FILE_PANEL=1。缺一样就让那组 SKIP ——"判据把测试进程
#     干掉"绝不能被当成一条红。
SCHEMAS="$SYS/share/glib-2.0/schemas"
if [[ -d "$SCHEMAS" ]] && command -v glib-compile-schemas >/dev/null 2>&1; then
  if glib-compile-schemas "$SCHEMAS" >/dev/null 2>&1 &&
     [[ -f "$SCHEMAS/gschemas.compiled" ]]; then
    export XDG_DATA_DIRS="$SYS/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
    export GSETTINGS_BACKEND="${GSETTINGS_BACKEND:-memory}"
    export MOONUI_FILE_PANEL=1
  fi
fi

"$BIN"
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "[canvas-pixel] 判据红：见上面 FAIL 行" >&2
  exit $rc
fi
echo "[canvas-pixel] OK：真链接 + 真跑的判据全绿（像素 + 控件层结构 + 控件叶子 + 剪贴板 + 对话框 + 菜单 + 主题 + 无障碍；真窗口上屏仍待 Linux 真机）"
