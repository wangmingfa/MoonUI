#!/usr/bin/env bash
# MoonUI · Linux/GTK4 后端（T235 P4~P6-5c）——在 **macOS 与 Linux 上真跑**的判据。
#
# 这道闸补的是另外两道闸的盲区：
#   ① scripts/mock-gtk-check.sh      假头语法 + 纯逻辑（不需要 GTK4）
#   ② scripts/gtk4-sysroot-check.sh  真头**编译**（-fsyntax-only，不链接）
#   ③ 本脚本                          真头编译 + **真链接 + 真跑**：像素 / 控件层结构 /
#                                    剪贴板 / 对话框 / 菜单 / 主题 / 无障碍 / 控件叶子 / 焦点链 / 自绘面点击 / 滚动内容，逐条断言
#                                    行为而不是"能编过"
#
# 两个宿主，同一份判据（T235 P7）：
#   · macOS：画布只用 cairo（pixman 软件光栅）+ pango + gdk-pixbuf，不碰显示服务器。
#     brew 的 bottle 是 arm64 macOS 二进制，scripts/macos-cairo-runtime.js 把它们拼成
#     一个私有可运行目录（不动系统、不装包），于是这份 C 能在本机跑起来。
#   · Linux：系统就有 GTK4，头与库由 `pkg-config --cflags/--libs gtk4 cairo`
#     现取（另两个包可选探测；发行版/多架构下硬编码必漏）。控件那半
#     要一个 display，所以没有 DISPLAY 时脚本会自己 `exec xvfb-run -a` 重入一次
#     （CI 的 linux-backend-link job 也是这么包的）。
#   两条分支只有"库从哪来 / 私有运行时要不要拼 / 未定义符号怎么放行"这三处不同，
#   判据本体（scripts/canvas-pixel-selftest.c）一字不改。
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
# P6-5c 起还跑**七构造族**（kinds 6..12，走**专属构造入口**不是 `(kind,text)` 工厂）：
# 类型读 G_OBJECT_TYPE_NAME（GtkScale / GtkSpinButton / GtkProgressBar / GtkDropDown /
# GtkTextView / GtkBox / GtkCalendar）；值读 GTK 自己的 getter 与 ABI 回读两条对拍
# （Slider/Spinbox）；Progress 验 fraction 与 `-1` 不定哨兵（GTK 读不回、靠缓存）；
# ComboBox 验模型计数、选中往返、**未选中 -1**（GtkDropDown 不支持无选中，靠
# `combo_has_sel` 跟踪）；RadioButtons 验三选项互斥；MultilineEntry 验多行文本往返；
# DatePicker 验日期文本**原文往返**（GtkCalendar 只认日期、时间靠 `date_cache`）；
# 六条 on_* 的 kind 护栏 + Slider `value-changed` 真派发、程序化改值不回声。
#
# 它**证不了**的：真窗口上屏（attach/present 要 GTK 显示服务器；Linux 上 xvfb 只
# 提供一个 X server，**上屏之后的真实分配尺寸与观感**仍要真机 P8）、字体度量与
# Linux 的差异（selftest 里文本只验"量得出、画得上"）、剪贴板的**跨进程**交接
# （这里是自己写自己读）、文件面板走 **portal** 的形态（两条分支都走内置
# GtkFileChooserDialog）。
#
# 前置：
#   · macOS：sysroot 在 $GTK4_SYSROOT（默认 /tmp/gtk4-sysroot），由
#     scripts/gtk4-sysroot-fetch.sh 取。没有就 SKIP（不是 PASS）。
#   · Linux：`libgtk-4-dev` / `libcairo2-dev` / `pkg-config`；没有就 SKIP。
#   · 两边都要 moonbit 运行时对象（$MOON_RUNTIME_OBJ，默认 ~/.moon/lib/libmoonbitrun.o）。
#
# 用法：bash scripts/canvas-pixel-check.sh
#   MOONUI_HOST_OS=linux 可在 mac 上"干跑"另一条分支的命令形状（本机自测用，见
#   scripts/ 里的验证注；正常路径永远看 uname）。
set -uo pipefail

# CI 里"没跑"不许报绿：本闸是 Linux 后端唯一真链接真跑的一层。缺件时若
# 还 exit 0，job 会带着那一批判据一条没跑继续往下走（2026-11-09 CI 第二轮
# 实测：apt 装齐了 GTK4，脚本却因 pkg-config 多列的两个可选包静默 SKIP，
# 直到后面 gallery 链接失败才红）。本机没装包时仍允许 SKIP，但要点名原因，
# 且不再长得像 PASS。
skip_or_fail() {
  echo "[canvas-pixel] SKIP：$1"
  echo "[canvas-pixel] SKIP ≠ PASS：像素判据这一次没跑。"
  if [[ -n "${CI:-}" ]]; then
    echo "[canvas-pixel] CI 环境不允许 SKIP，按 FAIL 处理" >&2
    exit 1
  fi
  exit 0
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/backends/native-linux/adapter_native_gtk.c"
TEST="$ROOT/scripts/canvas-pixel-selftest.c"
MOONLIB="${MOON_RUNTIME_OBJ:-$HOME/.moon/lib/libmoonbitrun.o}"
CC_BIN="${CC:-cc}"

HOST="${MOONUI_HOST_OS:-$(uname -s)}"
case "$HOST" in
  Darwin|darwin|macos) PLAT=macos ;;
  Linux|linux)         PLAT=linux ;;
  *)
    skip_or_fail "这道闸只服务 macOS / Linux 宿主（当前 ${HOST}）"
    ;;
esac

if [[ ! -f "$SRC" ]]; then echo "[canvas-pixel] 找不到 ${SRC}" >&2; exit 1; fi
if [[ ! -f "$TEST" ]]; then echo "[canvas-pixel] 找不到 ${TEST}" >&2; exit 1; fi
if [[ ! -f "$MOONLIB" ]]; then
  skip_or_fail "找不到 ${MOONLIB}（moonbit 运行时对象；MOON_RUNTIME_OBJ 可覆盖）"
fi

# P6-6：窗口状态那一片的**仓库接线**静态断言。真跑判据在 canvas-pixel-selftest.c，
# 但「探针绿了、生成器其实没接上」这种事 C 层看不见，所以这里从生成器常量、
# 生成物结构和 .inc 函数体三层各钉一遍。只读定义/函数体，不全文 includes
#（注释里也有同名串，全文搜会假绿——T233 的段回收闸当场抓到过）。
node - "$ROOT" <<'P66_STATIC'
/* 要插进 canvas-pixel-check.sh 的静态断言段（P6-6）。
 * 防「探针绿了、仓库其实没接上」：只读常量定义 / 函数体 / 生成物结构，
 * 不全文 includes —— 注释里也有同名串，全文搜会假绿（T233 抓到过）。 */
const fs = require("fs"), path = require("path");
const ROOT = process.argv[2];
const GEN = path.join(ROOT, "scripts/gen-native-linux-gtk.js");
const OUT = path.join(ROOT, "backends/native-linux/adapter_native_gtk.c");
const INC = path.join(ROOT, "backends/native-linux/windows_gtk.inc");
let fail = 0;
function ck(name, ok, detail) {
  if (ok) console.log("PASS  [p66-static] " + name);
  else { ++fail; console.log("FAIL  [p66-static] " + name + "：" + detail); }
}
const gen = fs.readFileSync(GEN, "utf8");
const out = fs.readFileSync(OUT, "utf8");
const inc = fs.readFileSync(INC, "utf8");

const NAMES = ["moonui_native_window_set_min_size", "moonui_native_window_min_size",
  "moonui_native_window_set_resizable", "moonui_native_window_set_fullscreen",
  "moonui_native_window_set_minimized", "moonui_native_window_set_maximized",
  "moonui_native_window_state", "moonui_native_window_is_key",
  "moonui_native_request_window_close"];

// ① 生成器 IMPL_FILES 数组（只读数组定义，不读全文）
const arr = (gen.match(/const IMPL_FILES = \[([\s\S]*?)\];/) || [, ""])[1];
ck("IMPL_FILES 里有第十二片 windows_gtk.inc",
   /"backends\/native-linux\/windows_gtk\.inc"/.test(arr),
   "生成器没接第十二片，真实现不会被 include");
ck("IMPL_FILES 里有第十三片 probes_gtk.inc（P6-16）",
   /"backends\/native-linux\/probes_gtk\.inc"/.test(arr),
   "生成器没接第十三片，两条探针会被退回留桩");
// ② 生成物头注片数（防史注漂移）
ck("生成物头注是「十三片」", out.includes("十三片手写实现"),
   "头注片数没同步");
// ③ 真头构建真的 include 了这一片
// prelude 里也有一个 #ifndef MOONUI_MOCK_GTK（第 88 行那段），必须取**最后**
// 一个才是 include 手写实现的那段；用 indexOf 会切到 prelude 里，③ 恒红、
// ⑤ 的 nonMock 只剩前 88 行（那 9 条「不再是裸桩」会变成假绿）。
const a = out.lastIndexOf("#ifndef MOONUI_MOCK_GTK"), b = out.indexOf("#endif", a);
const realSeg = a >= 0 && b > a ? out.slice(a, b) : "";
ck("非 mock 段 include 了 windows_gtk.inc",
   realSeg.includes('#include "windows_gtk.inc"'),
   "真头构建里这一片没被编进来");
ck("非 mock 段 include 了 probes_gtk.inc",
   realSeg.includes('#include "probes_gtk.inc"'),
   "真头构建里两条探针没被编进来");
// ④ 假头构建保住每个 ABI 符号都有定义
const m = out.indexOf("#ifdef MOONUI_MOCK_GTK", b);
const mockSeg = m >= 0 ? out.slice(m) : "";
for (const n of NAMES) {
  const re = new RegExp("\\b" + n + "\\s*\\([^;]*\\)\\s*\\{\\s*(?:return 0;)?\\s*\\}");
  ck("假头构建有 " + n + " 的替身桩", re.test(mockSeg),
     "假头闸门会缺符号（或替身签名写得不对）");
}
// ⑤ 真头构建里这 9 条不能还是中性桩（生成物是生成物，不手改）
// 真实定义区 = include 段之前 + include 段之后到 mock 段之前，两截都要，
// 否则 stub 区（在两者之间）根本没被检查。
const nonMock = (a >= 0 && b > a && m > b) ? out.slice(0, a) + out.slice(b, m) : out;
for (const n of NAMES) {
  const re = new RegExp("^[^\\n]*\\b" + n + "\\s*\\([^;]*\\)\\s*\\{\\s*(?:return 0;)?\\s*\\}\\s*$", "m");
  ck("真头段里 " + n + " 不再是裸桩", !re.test(nonMock),
     "生成物里仍是 return 0 的桩（手改了生成物？）");
}
// ⑥ 每条函数体真的调了对应的 GTK API（先去注释，只读函数体）
const clean = inc.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
const EXPECT = [
  ["moonui_native_window_set_min_size", "gtk_widget_set_size_request"],
  ["moonui_native_window_min_size", "gtk_widget_get_size_request"],
  ["moonui_native_window_set_resizable", "gtk_window_set_resizable"],
  ["moonui_native_window_set_fullscreen", "gtk_window_fullscreen"],
  ["moonui_native_window_set_minimized", "gtk_window_minimize"],
  ["moonui_native_window_set_maximized", "gtk_window_maximize"],
  ["moonui_native_window_state", "gdk_toplevel_get_state"],
  ["moonui_native_window_is_key", "gtk_window_is_active"],
  ["moonui_native_request_window_close", "gtk_window_close"],
];
for (const [fn, api] of EXPECT) {
  const re = new RegExp("\\b" + fn + "\\s*\\([^)]*\\)\\s*\\{([\\s\\S]*?)\\n\\}");
  const hit = clean.match(re);
  ck(fn + " 函数体调了 " + api, !!hit && hit[1].includes(api),
     "函数体缺真 GTK 调用（或函数被删/改名）");
}
console.log("[p66-static] " + (fail === 0 ? "OK：21 项静态断言全绿" : "FAIL " + fail + " 条"));
process.exit(fail === 0 ? 0 : 1);
P66_STATIC
if [[ $? -ne 0 ]]; then
  echo "[canvas-pixel] P6-6 静态断言红：见上面 FAIL 行" >&2
  exit 1
fi

# P6-7：窗口几何口径（3 条真 + 12 条空操作/兜底）与 render_backend 6 条的
# **仓库接线**静态断言。真跑判据在 canvas-pixel-selftest.c / mock-gtk-selftest.c，
# 这里只钉「生成器接了、生成物不是裸桩、函数体真的调了对的 API」三层——探针
# 绿了但生成器没接上，C 层看不出来。同样只读定义/函数体，不全文搜。
node - "$ROOT" <<'P67_STATIC'
const fs = require("fs"), path = require("path");
const ROOT = process.argv[2];
const GEN = path.join(ROOT, "scripts/gen-native-linux-gtk.js");
const OUT = path.join(ROOT, "backends/native-linux/adapter_native_gtk.c");
const INC = path.join(ROOT, "backends/native-linux/windows_gtk.inc");
let fail = 0;
function ck(name, ok, detail) {
  if (ok) console.log("PASS  [p67-static] " + name);
  else { ++fail; console.log("FAIL  [p67-static] " + name + "：" + detail); }
}
const gen = fs.readFileSync(GEN, "utf8");
const out = fs.readFileSync(OUT, "utf8");
const inc = fs.readFileSync(INC, "utf8");

const WINDOW_NAMES = ["moonui_native_window_in_live_resize",
  "moonui_native_window_set_position", "moonui_native_window_position",
  "moonui_native_window_move_external", "moonui_native_window_drag_step",
  "moonui_native_window_set_titlebar_style", "moonui_native_window_titlebar_style",
  "moonui_native_window_set_drag_band", "moonui_native_window_drag_band",
  "moonui_native_window_movable_probe",
  "moonui_native_window_set_traffic_light_position",
  "moonui_native_window_traffic_light_position",
  "moonui_native_screen_work_area",
  "moonui_native_window_screen_origin", "moonui_native_window_screen_size"];
const RENDER_NAMES = ["parse", "resolve", "resolve_at", "write_pref",
  "write_pref_at", "pref_code_at"];

// ① 生成器 REAL 表接了 6 条 render_backend（只读 REAL.set 的键，不读全文）
for (const n of RENDER_NAMES) {
  const re = new RegExp('REAL\\.set\\("moonui_render_backend_' + n + '"');
  ck("生成器 REAL 表接了 moonui_render_backend_" + n, re.test(gen),
     "写在注释里但没进 REAL 表 = 生成物仍是 return 0 的桩");
}
// ② 生成物头注与实现一致（防史注漂移）
ck("生成物头注提到 P6-7 的 15 条窗口口径", out.includes("P6-7 的窗口几何口径 15 条"),
   "头注没同步 P6-7");
ck("生成物头注提到 render_backend 6 条", out.includes("render_backend 6 条"),
   "头注没同步 render_backend");
// ③ 真头构建真的 include 了 windows_gtk.inc（取最后一个 #ifndef 才是那一段）
const a = out.lastIndexOf("#ifndef MOONUI_MOCK_GTK"), b = out.indexOf("#endif", a);
const realSeg = a >= 0 && b > a ? out.slice(a, b) : "";
ck("非 mock 段 include 了 windows_gtk.inc",
   realSeg.includes('#include "windows_gtk.inc"'),
   "真头构建里窗口片没被编进来");
// ④ 假头构建保住 15 个符号都有替身桩
const m = out.indexOf("#ifdef MOONUI_MOCK_GTK", b);
const mockSeg = m >= 0 ? out.slice(m) : "";
for (const n of WINDOW_NAMES) {
  const re = new RegExp("\\b" + n + "\\s*\\([^;]*\\)\\s*\\{\\s*(?:return 0;)?\\s*\\}");
  ck("假头构建有 " + n + " 的替身桩", re.test(mockSeg),
     "假头闸门会缺符号（或替身签名写得不对）");
}
// ⑤ 真头段里 15 条都不能还是裸桩（含 12 条有注释的空操作：它们不是 return 0; 的单行桩）
const nonMock = (a >= 0 && b > a && m > b) ? out.slice(0, a) + out.slice(b, m) : out;
for (const n of WINDOW_NAMES) {
  const re = new RegExp("^[^\\n]*\\b" + n + "\\s*\\([^;]*\\)\\s*\\{\\s*(?:return 0;)?\\s*\\}\\s*$", "m");
  ck("真头段里 " + n + " 不再是裸桩", !re.test(nonMock),
     "生成物里仍是 return 0 的桩（手改了生成物？）");
}
// ⑥ 函数体真的调了对的 API（先去注释，只读函数体）
const clean = inc.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
function bodyOf(fn) {
  const re = new RegExp("\\b" + fn + "\\s*\\([^)]*\\)\\s*\\{([\\s\\S]*?)\\n\\}");
  const hit = clean.match(re);
  return hit ? hit[1] : "";
}
const helper = bodyOf("moonui_p67_monitor_geometry");
ck("monitor 帮手读了 gdk_monitor_get_geometry",
   helper.includes("gdk_monitor_get_geometry"), "帮手缺几何读数");
ck("monitor 帮手读了 gdk_monitor_get_scale_factor",
   helper.includes("gdk_monitor_get_scale_factor"), "帮手缺 scale 换算");
for (const n of ["moonui_native_screen_work_area",
                 "moonui_native_window_screen_origin",
                 "moonui_native_window_screen_size"]) {
  ck(n + " 走 monitor 帮手", bodyOf(n).includes("moonui_p67_monitor_geometry"),
     "函数体没接几何读数（或函数被删/改名）");
}
ck("window_position 回打包坐标", bodyOf("moonui_native_window_position").includes("moonui_pack2"),
   "兜底常量不是 pack2(0,0)");
ck("traffic_light_position 回打包坐标",
   bodyOf("moonui_native_window_traffic_light_position").includes("moonui_pack2"),
   "兜底常量不是 pack2(0,0)");
ck("movable_probe 保留 -1 = 找不到窗口",
   bodyOf("moonui_native_window_movable_probe").includes("return -1"),
   "契约里的 -1 分支没了");
console.log("[p67-static] " + (fail === 0 ? "OK：静态断言全绿" : "FAIL " + fail + " 条"));
process.exit(fail === 0 ? 0 : 1);
P67_STATIC
if [[ $? -ne 0 ]]; then
  echo "[canvas-pixel] P6-7 静态断言红：见上面 FAIL 行" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# T235 P6-8：应用身份 / 显式缺席 / 目录行走 的静态断言。
# 只读"生成器表里有没有接"与"生成物函数体里调了什么"——真头编译在
# gtk4-sysroot-check.sh，纯逻辑真跑在 mock-gtk-check.sh 第 17 组。
# ---------------------------------------------------------------------------
node - "$ROOT" <<'P68_STATIC'
const fs = require("fs"), path = require("path");
const ROOT = process.argv[2];
const gen = fs.readFileSync(path.join(ROOT, "scripts/gen-native-linux-gtk.js"), "utf8");
const out = fs.readFileSync(path.join(ROOT, "backends/native-linux/adapter_native_gtk.c"), "utf8");
let fail = 0;
function ck(name, ok, detail) {
  if (ok) console.log("PASS  [p68-static] " + name);
  else { ++fail; console.log("FAIL  [p68-static] " + name + "：" + detail); }
}
const clean = out.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
function bodyOf(fn) {
  const re = new RegExp("\\b" + fn + "\\s*\\([^)]*\\)\\s*\\{([\\s\\S]*?)\\n\\}");
  const hit = clean.match(re);
  return hit ? hit[1] : "";
}

const REAL_NAMES = ["moonui_native_host_platform", "moonui_native_set_app_name",
  "moonui_native_set_app_icon", "moonui_native_app_icon_present",
  "moonui_native_walk_dir"];
for (const n of REAL_NAMES) {
  ck("生成器 REAL 表接了 " + n,
     new RegExp('REAL\\.set\\("' + n + '"').test(gen),
     "写在注释里但没进 REAL 表 = 生成物仍是 return 0 的桩");
}
ck("生成物 include 了 <dirent.h>", out.includes("#include <dirent.h>"),
   "walk_dir 的 opendir 族没头文件");
ck("生成物头注提到 P6-8", out.includes("P6-8 的应用身份 5 条"), "头注没同步 P6-8");

const walk = bodyOf("moonui_native_walk_dir");
ck("walk_dir 调了 opendir/readdir/closedir",
   walk.includes("opendir(") && walk.includes("readdir(") && walk.includes("closedir("),
   "函数体缺目录遍历三件");
ck("walk_dir 的失败支全是 0 字节空包（≥3 处）",
   (walk.match(/moonbit_make_bytes\(0, 0\)/g) || []).length >= 3,
   "NULL/开不了/溢出三支没走同一口径");
ck("walk_dir 绝不返 NULL", !/\breturn\s+NULL\s*;/.test(walk),
   "adapter.h 明令不许 NULL（MoonBit 侧直接 .length()）");
ck("set_app_name 调了 g_set_application_name",
   bodyOf("moonui_native_set_app_name").includes("g_set_application_name"),
   "名字没交到 GLib");
ck("set_app_icon 收下返 0",
   bodyOf("moonui_native_set_app_icon").includes("return 0"),
   "Linux 没有按文件装图标的 API，口径是收下返 0（边界写在 adapter.h）");
ck("host_platform 回 0（= 共享层 Unknown）",
   bodyOf("moonui_native_host_platform").includes("return 0"),
   "冒出一个共享层不认识的宿主码");

const ABSENT_CODES = {
  moonui_native_app_icon_content_permille: "-1",
  moonui_native_notify: "-3",
  moonui_native_tray_set_icon: "-1",
  moonui_native_tray_set_menu: "-1",
};
for (const n of Object.keys(ABSENT_CODES)) {
  const code = ABSENT_CODES[n];
  ck("生成器 ABSENT 表把 " + n + " 定为 " + code,
     new RegExp('ABSENT\\.set\\("' + n + '",\\s*`\\s*return ' + code + ';').test(gen),
     "缺席码与 Windows 半口径不一致，或仍留在中性桩里");
}
console.log("[p68-static] " + (fail === 0 ? "OK：静态断言全绿" : "FAIL " + fail + " 条"));
process.exit(fail === 0 ? 0 : 1);
P68_STATIC
if [[ $? -ne 0 ]]; then
  echo "[canvas-pixel] P6-8 静态断言红：见上面 FAIL 行" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# T235 P6-9：图像源两条（image_set_path / image_set_data）的静态断言。
# 只看三层：生成器 REAL 表接没接、生成物函数体调的是 4.6 就有的那几个 API、
# kind 16 的构造换成了 GtkPicture。真解码在 canvas-pixel-selftest.c（真 GdkTexture
# 解出像素尺寸），纯逻辑真跑在 mock-gtk-check.sh 第 18 组。
# ---------------------------------------------------------------------------
node - "$ROOT" <<'P69_STATIC'
const fs = require("fs"), path = require("path");
const ROOT = process.argv[2];
const GEN = path.join(ROOT, "scripts/gen-native-linux-gtk.js");
const OUT = path.join(ROOT, "backends/native-linux/adapter_native_gtk.c");
const WID = path.join(ROOT, "backends/native-linux/widgets_gtk.inc");
let fail = 0;
function ck(name, ok, detail) {
  if (ok) console.log("PASS  [p69-static] " + name);
  else { ++fail; console.log("FAIL  [p69-static] " + name + "：" + detail); }
}
const gen = fs.readFileSync(GEN, "utf8");
const out = fs.readFileSync(OUT, "utf8");
const wid = fs.readFileSync(WID, "utf8")
  .replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
const clean = out.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
function bodyOf(fn) {
  const re = new RegExp("\\b" + fn + "\\s*\\([^)]*\\)\\s*\\{([\\s\\S]*?)\\n\\}");
  const hit = clean.match(re);
  return hit ? hit[1] : "";
}

for (const n of ["moonui_native_image_set_path", "moonui_native_image_set_data"]) {
  ck("生成器 REAL 表接了 " + n,
     new RegExp('REAL\\.set\\("' + n + '"').test(gen),
     "写在注释里但没进 REAL 表 = 生成物仍是 return 0 的桩");
  ck("真头段里 " + n + " 不再是裸桩",
     !new RegExp("^[^\\n]*\\b" + n + "\\s*\\([^;]*\\)\\s*\\{\\s*(?:return 0;)?\\s*\\}\\s*$", "m").test(clean),
     "生成物里仍是 return 0 的桩（手改了生成物？）");
}
ck("生成物头注提到 P6-9 的图像源 2 条",
   out.includes("P6-9 的图像源 2 条"), "头注没同步 P6-9");
ck("kind 16 的构造换成了 gtk_picture_new",
   /case MOONUI_LEAF_IMAGE:[\s\S]{0,300}gtk_picture_new\(\)/.test(wid),
   "GtkImage 按固有尺寸出画、没有 can-shrink，对不上 mac 的等比缩放");
ck("图像片里不再造 GtkImage", !/gtk_image_new\(\)/.test(wid),
   "P6-9 订正后不该再有 GtkImage 构造");

const p = bodyOf("moonui_native_image_set_path");
ck("set_path 走 gdk_texture_new_from_filename",
   p.includes("gdk_texture_new_from_filename"), "4.6 的纹理解码入口没接上");
ck("set_path 保留 -2 = 不指图像控件", p.includes("return -2"),
   "kind 护栏被删：非图像句柄会被当成装上了");
ck("set_path 失败支放掉 GError", p.includes("g_error_free"),
   "坏路径会漏一条 GLib 错误对象");
const d = bodyOf("moonui_native_image_set_data");
ck("set_data 走 g_bytes_new + gdk_texture_new_from_bytes",
   d.includes("g_bytes_new") && d.includes("gdk_texture_new_from_bytes"),
   "内存源的两个入口缺一个");
ck("set_data 放掉 GBytes", d.includes("g_bytes_unref"), "每次 set_data 漏一个 GBytes");
ck("set_data 保留 -2 = 不指图像控件", d.includes("return -2"),
   "kind 护栏被删：非图像句柄会被当成装上了");
const helper = bodyOf("moonui_gtk_image_take");
ck("帮手走 gtk_picture_set_paintable",
   helper.includes("gtk_picture_set_paintable"), "纹理没交给 GtkPicture");
ck("帮手显式开 can-shrink", helper.includes("gtk_picture_set_can_shrink"),
   "关着就不会随控件缩小，语义退回 GtkImage 那套");
ck("帮手放掉自己那份纹理引用", helper.includes("g_object_unref"),
   "控件持一份、我们也要放一份，否则每张图漏一个纹理");
ck("两条都走同一个帮手",
   p.includes("moonui_gtk_image_take") && d.includes("moonui_gtk_image_take"),
   "整源替换的落点分叉成了两份");
ck("全生成物不用已弃用的 gtk_image_set_from_file",
   !out.includes("gtk_image_set_from_file"),
   "该接口 4.10 起弃用，4.6 最低口径下就是 -Wdeprecated 红");
console.log("[p69-static] " + (fail === 0 ? "OK：静态断言全绿" : "FAIL " + fail + " 条"));
process.exit(fail === 0 ? 0 : 1);
P69_STATIC
if [[ $? -ne 0 ]]; then
  echo "[canvas-pixel] P6-9 静态断言红：见上面 FAIL 行" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# T235 P6-10：文件拖入三条的静态判据。真跑那半（GdkFileList → 快照 → 闭包）
# 在 selftest 的 t_file_drop，这里钉的是"接上了没有"：REAL 表、建窗挂点、
# 信号连接、编码方向、临时内存与引用配平。全部先在**剥掉注释**的生成物上
# 匹配——注释里写着名字但代码没接，是这个仓库最容易出现的假绿。
node - "$ROOT" <<'P610_STATIC'
const fs = require("fs"), path = require("path");
const ROOT = process.argv[2];
const GEN = path.join(ROOT, "scripts/gen-native-linux-gtk.js");
const OUT = path.join(ROOT, "backends/native-linux/adapter_native_gtk.c");
const MOCK = path.join(ROOT, "scripts/mock-gtk.h");
let fail = 0;
function ck(name, ok, detail) {
  if (ok) console.log("PASS  [p610-static] " + name);
  else { ++fail; console.log("FAIL  [p610-static] " + name + "：" + detail); }
}
const gen = fs.readFileSync(GEN, "utf8");
const out = fs.readFileSync(OUT, "utf8");
const mock = fs.readFileSync(MOCK, "utf8");
const clean = out.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
function bodyOf(fn) {
  const hit = clean.match(new RegExp("\\b" + fn + "\\s*\\([^)]*\\)\\s*\\{([\\s\\S]*?)\\n\\}"));
  return hit ? hit[1] : "";
}

const ABI = ["moonui_native_on_file_drop", "moonui_native_file_drop_target",
             "moonui_native_file_drop_paths"];
for (const n of ABI) {
  ck("生成器 REAL 表接了 " + n,
     new RegExp('REAL\\.set\\("' + n + '"').test(gen),
     "没进 REAL 表 = 生成物仍是中性桩");
  ck("真头段里 " + n + " 不再是裸桩",
     !new RegExp("^[^\\n]*\\b" + n + "\\s*\\([^;]*\\)\\s*\\{\\s*(?:return 0;)?\\s*\\}\\s*$", "m").test(clean),
     "生成物里仍是 return 0 的桩（手改了生成物？）");
}
ck("生成物头注提到 P6-10 的文件拖入 3 条",
   out.includes("P6-10 的文件拖入 3 条"), "头注没同步 P6-10");

const win = bodyOf("moonui_native_window_new");
ck("建窗就挂文件落点（与 mac/win 同一时机）",
   win.includes("moonui_gtk_filedrop_attach"), "窗口没有 GtkDropTarget");
const windestroy = bodyOf("moonui_native_window_destroy");
ck("收窗清掉指向它的拖入快照",
   windestroy.includes("moonui_drop_snapshot_clear"),
   "file_drop_target 会继续把已销毁的句柄交出去");

const attach = bodyOf("moonui_gtk_filedrop_attach");
ck("落点用 GtkDropTarget + GDK_TYPE_FILE_LIST",
   attach.includes("gtk_drop_target_new") && attach.includes("GDK_TYPE_FILE_LIST"),
   "文件拖拽的类型对不上 GdkFileList（4.6 的口径）");
ck("落点 action 是 COPY", attach.includes("GDK_ACTION_COPY"),
   "拖入动作没钉住，光标反馈会随落点变");
ck("落点连 \"drop\" 信号并交给控件",
   attach.includes('"drop"') && attach.includes("gtk_widget_add_controller"),
   "控制器没挂到窗口上");

const drop = bodyOf("moonui_gtk_on_file_drop");
ck("drop 回调刻意非 static（真跑闸要 extern）",
   /gboolean\s+moonui_gtk_on_file_drop\s*\(/.test(clean),
   "写成 static 之后 canvas-pixel 的真跑判据接不到它");
ck("drop 回调从 boxed 值取 GdkFileList",
   drop.includes("g_value_get_boxed") && drop.includes("gdk_file_list_get_files"),
   "GdkFileList 入口缺一个");
ck("drop 回调逐条取路径", drop.includes("g_file_get_path"),
   "GFile 没换成路径就打包，读回会是空");
ck("取到的路径用 g_free 放掉（不是 free）",
   drop.includes("g_free(paths[i])"),
   "g_file_get_path 的内存是 g_malloc 的，混用 free 是未定义行为");
ck("临时数组本身用 free 放掉", drop.includes("free(paths)"),
   "每颗 drop 漏一个指针数组");
ck("快照写好之后才调闭包",
   drop.indexOf("moonui_drop_snapshot_set") < drop.indexOf("moonui_drop_fn("),
   "闭包先跑、读回后写，Core 会读到上一条");
ck("没有路径就不产事件", drop.includes("moonui_drop_paths_len > 0"),
   "空路径也调闭包 = Core 收到一条空通知");

const set = bodyOf("moonui_drop_snapshot_set");
ck("编码先写 count", set.includes("moonui_drop_put_i32(buf, count)"),
   "adapter.h 的布局是 i32 count 打头");
ck("每项先写长度再写内容",
   set.indexOf("moonui_drop_put_i32(buf + off, n)") < set.indexOf("memcpy(buf + off"),
   "长度与内容的顺序反了");
ck("只有 count > 0 才分配", set.includes("if (count <= 0)"),
   "空数组会写一张 4 字节空表，与「空 bytes = 没有路径」冲突");

const on = bodyOf("moonui_native_on_file_drop");
ck("on_file_drop 走统一闭包槽并恒 0",
   on.includes("moonui_closure_replace") && on.includes("return 0"),
   "单槽进程级回调的语义与 on_key/on_mouse 不一致");
const paths = bodyOf("moonui_native_file_drop_paths");
ck("paths 复制成 moonbit_bytes_t（不交内部缓冲）",
   paths.includes("moonbit_make_bytes") && paths.includes("memcpy"),
   "把内部缓冲直接交出去，下一次拖入会覆盖它");
const term = bodyOf("moonui_native_terminate");
ck("terminate 放掉拖入闭包与快照",
   term.includes("moonui_drop_snapshot_clear") && term.includes("moonbit_decref(moonui_drop_closure)"),
   "跨 init/terminate 会漏一份闭包引用 + 一块路径缓冲");

ck("假头补了文件拖入的形状（假头构建也要编）",
   mock.includes("GdkFileList") && mock.includes("gtk_drop_target_new"),
   "MOONUI_MOCK_GTK 构建会缺声明");
console.log("[p610-static] " + (fail === 0 ? "OK：静态断言全绿" : "FAIL " + fail + " 条"));
process.exit(fail === 0 ? 0 : 1);
P610_STATIC
if [[ $? -ne 0 ]]; then
  echo "[canvas-pixel] P6-10 静态断言红：见上面 FAIL 行" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# T235 P6-11：WebView 五条的显式缺席。GTK4 本体没有网页视图（接入 WebKitGTK
# 是新的运行时依赖决策），中性桩的 return 0 却在 on / load 上谎报成功。这里
# 钉住「五条都进了 ABSENT 表且码值与 adapter.h 的 Windows 半逐条对齐」，以及
# kind 19 的构造仍然不存在（不给 Core 半个控件）。
node - "$ROOT" <<'P611_STATIC'
const fs = require("fs"), path = require("path");
const ROOT = process.argv[2];
const GEN = path.join(ROOT, "scripts/gen-native-linux-gtk.js");
const OUT = path.join(ROOT, "backends/native-linux/adapter_native_gtk.c");
let fail = 0;
function ck(name, ok, detail) {
  if (ok) console.log("PASS  [p611-static] " + name);
  else { ++fail; console.log("FAIL  [p611-static] " + name + "：" + detail); }
}
const gen = fs.readFileSync(GEN, "utf8");
const out = fs.readFileSync(OUT, "utf8");
const clean = out.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
function bodyOf(fn) {
  const hit = clean.match(new RegExp("\\b" + fn + "\\s*\\([^)]*\\)\\s*\\{([\\s\\S]*?)\\n\\}"));
  return hit ? hit[1] : "";
}
const absent = (n, body) =>
  new RegExp('ABSENT\\.set\\("' + n + '",\\s*`\\s*' + body).test(gen);

ck("on_webview 进 ABSENT 且返回 -1",
   absent("moonui_native_on_webview", "return -1;"), "仍是中性桩的 return 0");
ck("webview_target 进 ABSENT 且恒 0",
   absent("moonui_native_webview_target", "return 0;"), "读回必须恒零");
ck("webview_phase 进 ABSENT 且恒 0",
   absent("moonui_native_webview_phase", "return 0;"), "读回必须恒零");
ck("webview_detail 进 ABSENT 且是空包",
   absent("moonui_native_webview_detail", "return moonbit_make_bytes\\(0, 0\\);"),
   "detail 必须是空包而不是 NULL");
ck("webview_load 进 ABSENT 且返回 -2",
   absent("moonui_native_webview_load", "return -2;"),
   "平台没有桥时 load 不能报 0（会当成递进去了）");
ck("生成物里 on_webview 不再是裸桩",
   bodyOf("moonui_native_on_webview").includes("return -1;"),
   "生成物与生成器不同步？");
ck("生成物里 webview_load 不再是裸桩",
   bodyOf("moonui_native_webview_load").includes("return -2;"),
   "生成物与生成器不同步？");
const leaf = bodyOf("moonui_gtk_leaf_of_kind");
ck("kind 19 没有构造分支（建不出半个控件）",
   !/case\s+19\s*:/.test(leaf), "leaf 表里给 19 开了分支");
ck("生成物头注提到 P6-11 的 WebView 缺席",
   out.includes("P6-11 的 WebView 5 条"), "头注没同步 P6-11");
console.log("[p611-static] " + (fail === 0 ? "OK：静态断言全绿" : "FAIL " + fail + " 条"));
process.exit(fail === 0 ? 0 : 1);
P611_STATIC
if [[ $? -ne 0 ]]; then
  echo "[canvas-pixel] P6-11 静态断言红：见上面 FAIL 行" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# T235 P6-12：worker_run 的线程与落地。这条 ABI 的语义是"work 在 worker 线程
# 跑、land 投回 UI 线程"，中性桩的 return 0 会让 Core 以为任务排上了、而闭包
# 永远不执行。这里钉住「REAL 表接了转调、线程与落地两步都在、失败路径退引用」。
node - "$ROOT" <<'P612_STATIC'
const fs = require("fs"), path = require("path");
const ROOT = process.argv[2];
const GEN = path.join(ROOT, "scripts/gen-native-linux-gtk.js");
const OUT = path.join(ROOT, "backends/native-linux/adapter_native_gtk.c");
const PB = path.join(ROOT, "prebuild-link.js");
let fail = 0;
function ck(name, ok, detail) {
  if (ok) console.log("PASS  [p612-static] " + name);
  else { ++fail; console.log("FAIL  [p612-static] " + name + "：" + detail); }
}
const gen = fs.readFileSync(GEN, "utf8");
const out = fs.readFileSync(OUT, "utf8");
const pb = fs.readFileSync(PB, "utf8");
const clean = out.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
function bodyOf(fn) {
  const hit = clean.match(new RegExp("\\b" + fn + "\\s*\\([^)]*\\)\\s*\\{([\\s\\S]*?)\\n\\}"));
  return hit ? hit[1] : "";
}
ck("worker_run 进了 REAL 表且转调 moonui_worker_spawn",
   /REAL\.set\("moonui_native_worker_run",\s*`int moonui_native_worker_run\([^`]*moonui_worker_spawn\(work_call, work_closure, land_call, land_closure\)/.test(gen),
   "生成器里没有这条 REAL 转调（仍是中性桩）");
ck("生成物里 worker_run 不再是裸桩",
   bodyOf("moonui_native_worker_run").includes("moonui_worker_spawn(work_call"),
   "生成物与生成器不同步？");
const spawn = bodyOf("moonui_worker_spawn");
ck("spawn 用 pthread_create", spawn.includes("pthread_create(&thread, 0, moonui_worker_main, t)"),
   "没有起线程");
ck("spawn 失败路径退两份引用", /pthread_create[\s\S]*moonbit_decref\(work_closure\);[\s\S]*moonbit_decref\(land_closure\);[\s\S]*free\(t\);/.test(spawn),
   "起线程失败会漏引用");
ck("spawn 成功即 detach（一次投递一条线程）", spawn.includes("pthread_detach(thread)"),
   "没有 detach，线程资源不回收");
ck("spawn 先拿住两份引用", /moonbit_incref\(work_closure\);[\s\S]*moonbit_incref\(land_closure\);[\s\S]*malloc/.test(spawn),
   "没有在起线程前 incref");
const main = bodyOf("moonui_worker_main");
ck("worker 线程先跑 work 再投递落地",
   /work_call\(t->work_closure\);[\s\S]*moonbit_decref\(t->work_closure\);[\s\S]*g_idle_add\(moonui_worker_land, t\)/.test(main),
   "work / decref / 投递的顺序不对");
ck("g_idle_add 失败由 worker 自退 land 引用",
   /g_idle_add\(moonui_worker_land, t\) == 0\)\s*\{[\s\S]*moonbit_decref\(t->land_closure\);[\s\S]*free\(t\);/.test(main),
   "投递失败会漏 land 引用");
const land = bodyOf("moonui_worker_land");
ck("落地回调先跑 land 再退引用",
   /land_call\(t->land_closure\);[\s\S]*moonbit_decref\(t->land_closure\);[\s\S]*free\(t\);/.test(land),
   "land 的执行点没有回收引用");
ck("落地回调返回 FALSE（一次即摘）", /return\s+FALSE;/.test(land), "idle 源会被反复触发");
ck("生成物 include 了 pthread.h", out.includes("#include <pthread.h>"),
   "pthread_create 没头文件");
ck("生成物头注提到 P6-12", out.includes("P6-12 的后台任务 1 条"), "头注没同步 P6-12");
ck("假头声明了 g_idle_add",
   fs.readFileSync(path.join(ROOT, "scripts/mock-gtk.h"), "utf8").includes("guint g_idle_add(GSourceFunc function, gpointer data);"),
   "假头构建编不过");
function fnBody(src, re) {
  const hit = src.match(re);
  return hit ? hit[1] : "";
}
const linkFn = fnBody(pb, /function linuxNativeLinkFlags\(\)\s*\{([\s\S]*?)\n\}/);
const compFn = fnBody(pb, /function linuxNativeCompileFlags\(\)\s*\{([\s\S]*?)\n\}/);
ck("Linux 链接参数显式带 -pthread", linkFn.includes("-pthread"),
   "glib 的 .pc 不保证写它，旧 glibc 起线程会缺符号");
ck("Linux 编译参数显式带 -pthread", compFn.includes('flags.push("-pthread")'),
   "编译期没写 -pthread");
console.log("[p612-static] " + (fail === 0 ? "OK：静态断言全绿" : "FAIL " + fail + " 条"));
process.exit(fail === 0 ? 0 : 1);
P612_STATIC
if [[ $? -ne 0 ]]; then
  echo "[canvas-pixel] P6-12 静态断言红：见上面 FAIL 行" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# T235 P6-13：输入法组合四条。GTK4 4.6 没有组合事件源（GtkEntry / GtkText 的
# IM context 无公开取口），所以这四条的正确形状是「监听登记真的做、三问恒报
# 空状态」。这里钉住它没有退回中性桩（裸 return 0 会把 ime_text 变成 NULL），
# 也钉住 terminate 的清账。
node - "$ROOT" <<'P613_STATIC'
const fs = require("fs"), path = require("path");
const ROOT = process.argv[2];
const GEN = path.join(ROOT, "scripts/gen-native-linux-gtk.js");
const OUT = path.join(ROOT, "backends/native-linux/adapter_native_gtk.c");
const HDR = path.join(ROOT, "backends/native-common/adapter.h");
let fail = 0;
function ck(name, ok, detail) {
  if (ok) console.log("PASS  [p613-static] " + name);
  else { ++fail; console.log("FAIL  [p613-static] " + name + "：" + detail); }
}
const gen = fs.readFileSync(GEN, "utf8");
const out = fs.readFileSync(OUT, "utf8");
const hdr = fs.readFileSync(HDR, "utf8");
const clean = out.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
function bodyOf(fn) {
  const hit = clean.match(new RegExp("\\b" + fn + "\\s*\\([^)]*\\)\\s*\\{([\\s\\S]*?)\\n\\}"));
  return hit ? hit[1] : "";
}
const four = ["on_ime", "ime_target", "ime_phase", "ime_text"];
for (const fn of four) {
  ck(fn + " 进了 REAL 表",
     gen.includes('REAL.set("moonui_native_' + fn + '"'), "生成器里没有这条 REAL");
}
const on = bodyOf("moonui_native_on_ime");
ck("on_ime 先退旧监听再换人",
   /moonui_ime_drop_listener\(\);[\s\S]*moonui_ime_fn = fn;[\s\S]*moonui_ime_closure = closure;/.test(on),
   "换回调没有走统一簿记");
ck("on_ime 只在闭包非空时 incref",
   /if \(closure != 0\) moonbit_incref\(closure\);/.test(on), "会对空闭包拿引用");
ck("on_ime 回 0（负码会判死文本控件）", /return 0;/.test(on) && !/return -1;/.test(on),
   "给 Core 回 -1 会让 Linux 上所有输入框建不出来");
ck("ime_target 读回快照里的控件",
   /return \(moonui_ptr\)\(uintptr_t\)moonui_ime_target_widget;/.test(bodyOf("moonui_native_ime_target")),
   "target 没有接到相位快照上");
ck("ime_phase 读回快照里的相位",
   /return moonui_ime_phase_now;/.test(bodyOf("moonui_native_ime_phase")),
   "phase 没有接到相位快照上");
const text = bodyOf("moonui_native_ime_text");
ck("ime_text 回快照副本（空串也是空包非 NULL）",
   text.includes("moonui_ime_text_now") && text.includes("moonbit_make_bytes(n, 0)") &&
     text.includes("if (n > 0) memcpy") && !/return 0;\s*$/.test(text),
   "NULL bytes 在 MoonBit 侧按 Bytes 解会崩");
ck("prelude 的监听清账先 decref 后归零",
   /static void moonui_ime_drop_listener\(void\) \{[\s\S]*moonbit_decref\(moonui_ime_closure\);[\s\S]*moonui_ime_closure = 0;[\s\S]*moonui_ime_fn = 0;/.test(clean),
   "清账形状不对");
ck("terminate 收口监听与相位快照",
   /moonui_ime_drop_listener\(\);[\s\S]*moonui_ime_reset_state\(\);/.test(bodyOf("moonui_native_terminate")),
   "terminate 会漏掉输入法闭包引用或快照串");
ck("生成物头注同步 P6-13 / T251", out.includes("P6-13 / T251 的输入法组合"), "头注没改");
ck("adapter.h 段注写明旁听路线",
   hdr.includes("从控件自己的 IM context 旁听"), "平台分法没同步");
ck("生成器注释点明取口（observe_controllers / key controller / delegate）",
   gen.includes("gtk_widget_observe_controllers") &&
     gen.includes("gtk_event_controller_key_get_im_context") &&
     gen.includes("gtk_editable_get_delegate"),
   "旁听取口没写清");
console.log("[p613-static] " + (fail === 0 ? "OK：静态断言全绿" : "FAIL " + fail + " 条"));
process.exit(fail === 0 ? 0 : 1);
P613_STATIC
if [[ $? -ne 0 ]]; then
  echo "[canvas-pixel] P6-13 静态断言红：见上面 FAIL 行" >&2
  exit 1
fi

# ---- P6-14 / T251：组合相位旁听的接线与相位机（静态面）----
node - "$ROOT" <<'P614_STATIC'
const fs = require("fs"), path = require("path");
const ROOT = process.argv[2];
const GEN = path.join(ROOT, "scripts/gen-native-linux-gtk.js");
const OUT = path.join(ROOT, "backends/native-linux/adapter_native_gtk.c");
const W1 = path.join(ROOT, "backends/native-linux/widgets_gtk.inc");
const W2 = path.join(ROOT, "backends/native-linux/widgets2_gtk.inc");
const MOCK = path.join(ROOT, "scripts/mock-gtk.h");
const SELF = path.join(ROOT, "scripts/canvas-pixel-selftest.c");
let fail = 0;
function ck(name, ok, detail) {
  if (ok) console.log("PASS  [p614-static] " + name);
  else { ++fail; console.log("FAIL  [p614-static] " + name + "：" + detail); }
}
const gen = fs.readFileSync(GEN, "utf8");
const out = fs.readFileSync(OUT, "utf8");
const w1 = fs.readFileSync(W1, "utf8");
const w2 = fs.readFileSync(W2, "utf8");
const mock = fs.readFileSync(MOCK, "utf8");
const self = fs.readFileSync(SELF, "utf8");
const clean = out.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
function bodyOf(fn) {
  const hit = clean.match(new RegExp("\\b" + fn + "\\s*\\([^)]*\\)\\s*\\{([\\s\\S]*?)\\n\\}"));
  return hit ? hit[1] : "";
}
ck("attach 枚举控件挂着的 controller",
   /gtk_widget_observe_controllers\(edit\)/.test(bodyOf("moonui_gtk_ime_attach")),
   "没走 observe_controllers，取不到控件那份 IM context");
ck("attach 经 editable delegate 取内部编辑视图",
   /gtk_editable_get_delegate\(GTK_EDITABLE\(w\)\)/.test(bodyOf("moonui_gtk_ime_attach")),
   "GtkEntry / GtkPasswordEntry 的内部 GtkText 没被取到");
ck("attach 从 key controller 取 im_context",
   /gtk_event_controller_key_get_im_context\(GTK_EVENT_CONTROLLER_KEY\(item\)\)/.test(bodyOf("moonui_gtk_ime_attach")),
   "没有取口的最后一步");
ck("attach 取不到 ctx 就不连信号",
   /if \(ctx == 0\) return;[\s\S]*g_signal_connect\(ctx, "preedit-start"/.test(bodyOf("moonui_gtk_ime_attach")),
   "空 ctx 仍往下连，会在 NULL 上连信号");
for (const sig of ["preedit-start", "preedit-changed", "preedit-end", "commit"]) {
  ck("attach 连了 " + sig + " 信号",
     new RegExp('g_signal_connect\\(ctx, "' + sig + '"').test(bodyOf("moonui_gtk_ime_attach")),
     "少连一个信号，相位就缺一段");
}
ck("changed 从 IM context 读组合串",
   /gtk_im_context_get_preedit_string\(ctx, &str, 0, 0\)/.test(bodyOf("moonui_ime_on_changed")),
   "没有真正读组合串");
ck("同串去重（不重复发进行）",
   /strcmp\(moonui_ime_last, str\) == 0/.test(bodyOf("moonui_ime_on_changed")),
   "逐键回声会变成重复 update");
ck("单行 / 密码控件构造时挂旁听",
   /leaf == MOONUI_LEAF_ENTRY \|\| leaf == MOONUI_LEAF_PASSWORD[\s\S]*moonui_gtk_ime_attach\(w\)/.test(w1),
   "文本控件建出来却没挂");
ck("多行控件构造时挂旁听",
   /moonui_gtk_ime_attach\(w\);[\s\S]*moonui_gtk_register_widget\(w, 10\)/.test(w2),
   "GtkTextView 建出来却没挂");
ck("控件销毁清掉它的相位快照",
   /moonui_ime_forget\(w\);/.test(w1) && /static void moonui_ime_forget/.test(clean),
   "销毁后 target 会悬空");
ck("假头声明了旁听取口与串读回",
   mock.includes("gtk_widget_observe_controllers") &&
     mock.includes("gtk_event_controller_key_get_im_context") &&
     mock.includes("gtk_im_context_get_preedit_string"),
   "假头缺声明，mock 构建编不过");
ck("真 GTK 自检有 P6-14 组",
   /t_ime_preedit\(\)/.test(self) && /preedit-start/.test(self) && /preedit-end/.test(self),
   "接线没有真跑判据");
console.log("[p614-static] " + (fail === 0 ? "OK：静态断言全绿" : "FAIL " + fail + " 条"));
process.exit(fail === 0 ? 0 : 1);
P614_STATIC
if [[ $? -ne 0 ]]; then
  echo "[canvas-pixel] P6-14 静态断言红：见上面 FAIL 行" >&2
  exit 1
fi

# ---- P6-15 / T252：剩余 37 条中性桩的定性（静态面）----
# 真跑判据在 mock 第 24 组与 canvas 的 t_image_probe；这里钉"生成器里真的
# 分了类、契约段注真的写了、假头与两个自检真的接上了"，防探针绿了仓库没接。
node - "$ROOT" <<'P615_STATIC'
const fs = require("fs"), path = require("path");
const ROOT = process.argv[2];
const GEN = path.join(ROOT, "scripts/gen-native-linux-gtk.js");
const OUT = path.join(ROOT, "backends/native-linux/adapter_native_gtk.c");
const HDR = path.join(ROOT, "backends/native-common/adapter.h");
const MOCK = path.join(ROOT, "scripts/mock-gtk.h");
const MSELF = path.join(ROOT, "scripts/mock-gtk-selftest.c");
const CSELF = path.join(ROOT, "scripts/canvas-pixel-selftest.c");
let fail = 0;
function ck(name, ok, detail) {
  if (ok) console.log("PASS  [p615-static] " + name);
  else { ++fail; console.log("FAIL  [p615-static] " + name + "：" + detail); }
}
const gen = fs.readFileSync(GEN, "utf8");
const out = fs.readFileSync(OUT, "utf8");
const hdr = fs.readFileSync(HDR, "utf8");
const mock = fs.readFileSync(MOCK, "utf8");
const mself = fs.readFileSync(MSELF, "utf8");
const cself = fs.readFileSync(CSELF, "utf8");
const clean = out.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
function bodyOf(fn) {
  const hit = clean.match(new RegExp("\\b" + fn + "\\s*\\([^)]*\\)\\s*\\{([\\s\\S]*?)\\n\\}"));
  return hit ? hit[1] : "";
}

/* ① 5 条如实读数在 REAL 表，且函数体不是裸桩。 */
const HONEST = [
  ["moonui_native_widget_set_icon", "return 0;"],
  ["moonui_native_ls_name_dump", "moonbit_make_bytes(0, 0)"],
  ["moonui_native_window_icon_installed", "return 0;"],
  ["moonui_native_tray_probe", "return 0;"],
  ["moonui_native_image_probe", "gdk_texture_get_width"],
];
for (const [fn, needle] of HONEST) {
  ck(fn + " 在 REAL 表",
     new RegExp('^\\s*REAL\\.set\\("' + fn + '"', "m").test(gen),
     "生成器没把它从自动桩里拿出来（或被注释掉了）");
  ck(fn + " 函数体有真读数", bodyOf(fn).includes(needle),
     "生成物里不是预期的显式读数");
}

/* ② 30 条显式缺席：生成器有、生成物体是契约里那一档。 */
const ABSENT = [
  ["moonui_native_send_key_in_window", "-1"],
  ["moonui_native_type_text_in_window", "-1"],
  ["moonui_native_send_mouse_in_window", "-1"],
  ["moonui_native_click_button_in_window", "-1"],
  ["moonui_native_right_click_in_window", "-1"],
  ["moonui_native_click_custom_in_window", "-1"],
  ["moonui_native_press_custom_in_window", "-1"],
  ["moonui_native_ime_compose_in_window", "-1"],
  ["moonui_native_ime_commit_in_window", "-1"],
  ["moonui_native_simulate_file_drop", "-1"],
  ["moonui_native_magnify_in_window", "-1"],
  ["moonui_native_rotate_in_window", "-1"],
  ["moonui_native_swipe_in_window", "-1"],
  ["moonui_native_synth_mouse_mods_set", "(void)mods;"],
  ["moonui_native_widget_alpha_probe", "-1"],
  ["moonui_native_clipsiblings_probe", "-2"],
  ["moonui_native_transparent_probe", "-2"],
  ["moonui_native_overlay_probe", "return 2;"],
  ["moonui_native_panel_probe", "3 << 56"],
  ["moonui_native_button_probe", "3 << 56"],
  ["moonui_native_icon_pose_probe", "1 << 16"],
  ["moonui_native_immersive_probe", "1 << 4"],
  ["moonui_native_slider_knob_probe", "-2147483647 - 1"],
  ["moonui_native_slider_click_probe", "-2147483647 - 1"],
  ["moonui_native_snapshot_all", "-3"],
  ["moonui_native_click_tray_item", "-3"],
  ["moonui_native_custom_probe", "-1"],
  ["moonui_native_media_probe", "-1"],
  ["moonui_native_hotkey_probe", "-1"],
  ["moonui_native_hotkey_probe_id", "-1"],
];
for (const [fn, needle] of ABSENT) {
  ck(fn + " 在 ABSENT 表",
     new RegExp('^\\s*ABSENT\\.set\\("' + fn + '"', "m").test(gen),
     "生成器没把它从自动桩里拿出来（或被注释掉了）");
  ck(fn + " 函数体是 " + needle, bodyOf(fn).includes(needle),
     "生成物里不是契约里那一档");
}

/* ③ P6-16：最后两条已从留桩改成真实现（probes_gtk.inc），不许再退回留桩 / 缺席。 */
ck("file_drop_probe / drag_hit_probe 已是真实现",
   gen.includes("probes_gtk.inc") &&
   !gen.includes("两条留桩挂 T252") &&
   !gen.includes('ABSENT.set("moonui_native_file_drop_probe"') &&
   !gen.includes('ABSENT.set("moonui_native_drag_hit_probe"'),
   "又被改回留桩或缺席了");

/* ④ 契约段注：GTK4 路线写清楚（事实 + 判定 + 真输入去哪）。 */
ck("adapter.h 段注写了 GDK4 的构造缺口",
   hdr.includes("GDK4") && hdr.includes("gdk_event_new"), "段注没交代为什么造不出事件");
ck("adapter.h 段注点了 gtk_test_widget_send_key",
   hdr.includes("gtk_test_widget_send_key"), "段注没交代 GTK4 测试 API 已不存在");
ck("adapter.h 段注指到 P9 的 xdotool 判据",
   hdr.includes("gtk-xinput-check.sh") && hdr.includes("P9"), "真输入路线没写");
ck("adapter.h 段注说明探针码只表示问不到",
   hdr.includes("本平台问不到"), "平台专属探针的码值语义没写");

/* ⑤ 假头 + 两个自检接上了。 */
ck("假头有 GDK_IS_TEXTURE", /#define GDK_IS_TEXTURE/.test(mock), "假头缺纹理判定");
ck("假头有 gtk_picture_get_paintable", mock.includes("gtk_picture_get_paintable"), "读口没声明");
ck("假头有 gdk_texture_get_width/height",
   mock.includes("gdk_texture_get_width") && mock.includes("gdk_texture_get_height"),
   "尺寸读口没声明");
ck("mock 自检有第 24 组", mself.includes("第 24 组：中性桩收口"), "纯逻辑判据没接上");
ck("canvas 自检有 t_image_probe 且被调用",
   cself.includes("static void t_image_probe(void)") && cself.includes("t_image_probe();"),
   "真 GTK 判据没接上");

/* ⑥ 不许在生成器里再出现合成事件的错路线（只查代码，注释里正解释它不存在）。 */
const genCode = gen.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
ck("生成器没有 gdk_event_new",
   !/\bgdk_event_new\s*\(/.test(genCode), "又回去造 GDK 事件了（GTK4 没有这个入口）");

console.log("[p615-static] " + (fail === 0 ? "OK：静态断言全绿" : "FAIL " + fail + " 条"));
process.exit(fail === 0 ? 0 : 1);
P615_STATIC
if [[ $? -ne 0 ]]; then
  echo "[canvas-pixel] P6-15 静态断言红：见上面 FAIL 行" >&2
  exit 1
fi

case "$PLAT" in

macos)
  SYS="${GTK4_SYSROOT:-/tmp/gtk4-sysroot}"
  RUN="${MOONUI_CAIRO_RUNTIME:-/tmp/moonui-cairo-runtime}"
  BIN="$RUN/canvas-pixel-selftest"
  if [[ ! -f "$SYS/include/gtk-4.0/gtk/gtk.h" ]]; then
    skip_or_fail "${SYS} 下没有 GTK4 头（先跑 scripts/gtk4-sysroot-fetch.sh）"
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

  LIB=(-L"$RUN" -lgtk-4 -lgobject-2.0 -lglib-2.0 -lcairo -lpangocairo-1.0 -lpango-1.0
       -lgdk_pixbuf-2.0 -lgio-2.0)
  # 未定义符号放行：libmoonbitrun.o 不导出 `moonbit_incref` / `moonbit_decref`。
  # P6-12 起自检自己给了这两个的计数桩（要量 worker_run 的引用配平），所以现在
  # 正常情况下没有未定义符号；这条参数留着兜其它运行时符号，mac 上靠 dyld 的
  # 延迟绑定，Linux 侧见下面的镜像写法。
  LINK_EXTRA=(-Wl,-undefined,dynamic_lookup)
  SCHEMAS="$SYS/share/glib-2.0/schemas"
  ;;

linux)
  if ! command -v pkg-config >/dev/null 2>&1; then
    skip_or_fail "没有 pkg-config（apt install pkg-config）"
  fi
  # 库与头从 pkg-config 现取。必需集合与 prebuild-link.js / gtk4-flags.sh
  # 一致（这两个已在 CI 上验证通过）：gtk4 的 Requires 会把 pango /
  # pangocairo / gdk-pixbuf 的 -I 与 -l 全都展开——CI 日志里
  # `pkg-config --libs gtk4 cairo` 的输出就含 -lpangocairo-1.0 与
  # -lgdk_pixbuf-2.0，真头闸也是靠这两个包编过 adapter 的。
  # 原先四个包一起写死想"缺包时点名"，结果新版发行版里其中一个不再单独
  # 提供同名 .pc，整道闸就静默 SKIP（2026-11-09 CI 实测）。现在这两个作为
  # **可选**逐个探测：在就显式列进来多一层库名核对，不在也不影响必需集合。
  PKGS=(gtk4 cairo)
  for p in pangocairo-1.0 gdk-pixbuf-2.0; do
    if pkg-config --exists "$p" 2>/dev/null; then PKGS+=("$p"); fi
  done
  # 逐个查、把 pkg-config 的诊断放出来：四个包一起 `--exists` 再加
  # `2>/dev/null` 只会得到一句"找不到"，看不出到底哪个包缺、还是 Requires
  # 不满足（2026-11-09 CI 上就是这样静默 SKIP 的）。
  for p in "${PKGS[@]}"; do
    if ! pkg-config --print-errors --exists "$p"; then
      echo "[canvas-pixel] 诊断：pkg-config 解析不了 ${p}（上面是它自己的报错）" >&2
      skip_or_fail "pkg-config 找不到所需包 ${PKGS[*]}（apt install libgtk-4-dev libcairo2-dev）"
    fi
  done

  # 控件那半要 display。没有就自己包一层 xvfb 重入（CI 用同一条；重入后 DISPLAY
  # 已设，不会再来一次）。xvfb 也没有时不擅自降级——让下面的 selftest 如实 SKIP
  # 并**以非 0 退出**（见 selftest 末尾那条"无显示不许报绿"的护栏）。
  if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    if command -v xvfb-run >/dev/null 2>&1; then
      echo "[canvas-pixel] 没有 DISPLAY：用 xvfb-run 重入"
      exec xvfb-run -a "$0" "$@"
    fi
    echo "[canvas-pixel] 警告：没有 DISPLAY 也没有 xvfb-run，控件判据会全部 SKIP" >&2
  fi

  BUILD="$(mktemp -d /tmp/moonui-canvas-pixel.XXXXXX)" || exit 1
  trap 'rm -rf "$BUILD"' EXIT
  BIN="$BUILD/canvas-pixel-selftest"

  # shellcheck disable=SC2207  # 这里要的就是按空白切分 pkg-config 的输出
  INC=( $(pkg-config --cflags "${PKGS[@]}") )
  # shellcheck disable=SC2207
  LIB=( $(pkg-config --libs "${PKGS[@]}") )
  # 与 prebuild-link.js 的 Linux 分支同一条理由：adapter_native_gtk.c 用了
  # `llround` / `floor` 一族 libm 符号，而这道闸是 `cc` 一步到位编+链，没有
  # moon 工具链给的 `-lm`。LIB 排在源文件之后，追加到末尾即可保证 GNU ld
  # 扫到 libm 时那些符号已经处于未定义状态（Ubuntu 还带 --as-needed）。
  LIB+=("-lm")
  INC+=("-I$ROOT/backends/native-common" "-I$ROOT/backends/native-linux" "-I$HOME/.moon/include")
  # 与 mac 的 `-Wl,-undefined,dynamic_lookup` 同一个意思、范围更窄：只放过**目标
  # 文件**里未定义的符号。P6-12 起两个引用计数函数由自检自己提供，这里主要是
  # 兜住其它可能缺的运行时符号；共享库之间的符号仍然逐个核对——写错 -l 照样在
  # 链接期红。不这么写，GNU ld 遇到任何未定义符号都会在最后一步拦住整道闸。
  LINK_EXTRA=(-Wl,--unresolved-symbols=ignore-in-object-files)
  # 系统包已经装好并编译过 schema（发行版的 postinst 干的）。不要在这里往 /usr
  # 里写文件——那是系统目录，CI 上也没有写权限。
  SCHEMAS="$(pkg-config --variable=prefix gtk4)/share/glib-2.0/schemas"
  ;;

esac

# 版本口径与 prebuild-link.js / gtk4-sysroot-check.sh 一字不差：GTK 4.6
# （Ubuntu 22.04）+ glib 2.72 的 MIN/MAX 一对。后者钉住 g_free 宏在
# >=2.78 时展开成 g_free_sized 的隐含依赖；只写 MAX 会被 glib 的 sanity
# check 直接 #error（T235 CI 首跑② 第三枚缺口，2026-11-10 补）。
"$CC_BIN" -o "$BIN" "$TEST" "$SRC" "${INC[@]}" \
  -DGDK_VERSION_MIN_REQUIRED=GDK_VERSION_4_6 \
  -DGDK_VERSION_MAX_ALLOWED=GDK_VERSION_4_6 \
  -DGLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_2_72 \
  -DGLIB_VERSION_MAX_ALLOWED=GLIB_VERSION_2_72 \
  -pthread \
  "${LIB[@]}" "$MOONLIB" "${LINK_EXTRA[@]}"
if [[ $? -ne 0 ]]; then
  echo "[canvas-pixel] 编译/链接失败：见上面 ${CC_BIN} 输出" >&2
  exit 1
fi

# 链接器给可执行记的是"我找到的那个文件名"（-lcairo 找到的是别名 libcairo.dylib），
# 而 dylib 之间记的是真实文件名；两条路径指同一个文件时 dyld 会当成两份加载
# （objc 会抱怨 class 重复实现）。这里把可执行自己的依赖也统一成真实文件名。
# 只有私有运行时（mac）需要这一步——Linux 的 .so 是 soname，没有这个别名问题。
if [[ "$PLAT" == macos ]]; then
  node "$ROOT/scripts/fix-dylib-aliases.js" "$BIN" "$RUN"
fi

# P6-3 的文件面板判据要 GSettings schema。mac 的私有 sysroot 里只有 `*.gschema.xml`、
# 没有编译产物 `gschemas.compiled`（brew bottle 不带），而 GtkFileChooserNative 一 show
# 就要读 `org.gtk.Settings.FileChooser`，读不到时 GTK 走 `g_error()` —— 那是 abort，
# 不是返回错误码。所以先编一份，再挂到 XDG_DATA_DIRS 上：
#   - 已经有 `gschemas.compiled` 就直接用（Linux 发行版装包时已编好，别去写 /usr）；
#   - GSETTINGS_BACKEND=memory 是为了让 GSettings 别去找 dconf（沙箱里没有 session bus；
#     探针实测不设这个会在 destroy 阶段同样 abort）；
#   - 两件都齐了才导出 MOONUI_FILE_PANEL=1。缺一样就让那组 SKIP ——"判据把测试进程
#     干掉"绝不能被当成一条红。
if [[ -d "$SCHEMAS" ]]; then
  if [[ -f "$SCHEMAS/gschemas.compiled" ]] ||
     { command -v glib-compile-schemas >/dev/null 2>&1 &&
       glib-compile-schemas "$SCHEMAS" >/dev/null 2>&1 &&
       [[ -f "$SCHEMAS/gschemas.compiled" ]]; }; then
    export XDG_DATA_DIRS="$(dirname "$(dirname "$SCHEMAS")")${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
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
echo "[canvas-pixel] OK（${PLAT}）：真链接 + 真跑的判据全绿（像素 + 控件层结构 + 控件叶子 + 剪贴板 + 对话框 + 菜单 + 主题 + 无障碍 + 七构造族 + 真窗）；真窗口的上屏/mapped/分配尺寸/焦点遍历已由 P8 判据钉住，缺的是 Linux 真机上的观感与 Wayland 差异"
