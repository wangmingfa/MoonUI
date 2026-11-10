#!/usr/bin/env node
/* T235 P3：从 backends/native-common/adapter.h 生成 GTK4 后端适配器
 * adapter_native_gtk.c —— 对 P3 目标符号（窗口 / 事件循环 / 键盘 / 鼠标 /
 * 手势）落地真实 GTK4·Cairo 实现，其余保持 unsupported 中性桩。
 *
 * 为什么还是生成的：adapter.h 里 ~264 条 ABI 声明，逐一手写易错且会与头文件
 * 漂移。本脚本沿用 P2 的「解析 adapter.h → 签名逐字一致」策略：所有非 P3
 * 符号仍由解析结果自动产出中性桩；P3 符号由本脚本内嵌的真实实现替换
 * （REAL 表，含完整签名）。这样加一个新 ABI 符号时，桩会自动跟上，真实实现
 * 只动它该动的那些。
 *
 * 证据边界（2026-11-08 订正）：本文件 #include <gtk/gtk.h>，**本机也能真编**——
 * scripts/gtk4-sysroot-fetch.sh 从 brew bottle 解一份私有 sysroot（不动系统、
 * 不装包），scripts/gtk4-sysroot-check.sh 拿真头做两道闸。真链接 / xvfb 真窗
 * 仍由 CI 的 linux-backend-link job 负责。
 *
 * 用法：
 *   node scripts/gen-native-linux-gtk.js [output.c]
 * 默认输出到 backends/native-linux/adapter_native_gtk.c。
 *
 * 2026-11-09：从同名 .py 逐行迁来（零新增依赖，只用 Node 内置 fs / path）。
 * 大段 C 文本（PREAMBLE 与 REAL 各条）由转换脚本原样搬成模板字符串，迁移
 * 判据是「新旧生成物逐字节一致」；此后改实现仍改本文件的 REAL 表或
 * IMPL_FILES 指向的 .inc 本体，生成物不要手改。
 */

'use strict';
const fs = require('fs');
const path = require('path');

const REPO = path.dirname(path.dirname(__filename));
const HDR = path.join(REPO, 'backends', 'native-common', 'adapter.h');
const OUT = path.join(REPO, 'backends', 'native-linux', 'adapter_native_gtk.c');

// ---------------------------------------------------------------------------
// P3 真实实现区间：GTK 头 + 全局状态 + 工具 + 信号处理器（一次前置）
// ---------------------------------------------------------------------------
const PREAMBLE = `/* ===================== P3 真实实现区间（GTK4） ===================== */
/* 最低版本闸写进**编译单元自身**，不只靠构建脚本传 -D：
 *   - GDK_VERSION_MIN_REQUIRED = 4.6 有两个作用，缺一不可：
 *     ① 用了比 4.6 新的 API 时，GDK_AVAILABLE_IN_4_x 展开成 "unavailable" 报错
 *        （看 gdk-visibility.h：\`#if GDK_VERSION_MIN_REQUIRED < GDK_VERSION_4_8\`
 *        时才把 4.8 的接口标成不可用）；
 *     ② **4.10 起弃用的 API 不再报弃用**——同样是上面那个 #if 的另一半
 *        （\`#if GDK_VERSION_MIN_REQUIRED >= GDK_VERSION_4_10\` 才标 GDK_DEPRECATED）。
 *        语义是对的：还要支持 4.6 的人，4.10 才弃用的接口就是他唯一的选择。
 *        P6-3 的对话框正卡在这条上：4.6 上只有 GtkMessageDialog /
 *        GtkFileChooserNative 可用（GtkAlertDialog / GtkFileDialog 要 4.10），
 *        不写这一行，2026-11-08 实测每条都刷一遍 -Wdeprecated-declarations。
 *   - GDK_VERSION_MAX_ALLOWED = 4.6 是传统那半（对齐 gtk4-sysroot-check.sh 的
 *     -D 口径），把"更高版本才有的东西"也一并钉住。
 *   - GLIB_VERSION_{MIN_REQUIRED,MAX_ALLOWED} = 2.72 是同一条口径的 **glib 半**
 *     （T235 CI 首跑② 记下的第三枚缺口，2026-11-10 补）：README 的最低口径是
 *     GTK 4.6 / Ubuntu 22.04，那份系统的 glib 是 2.72；而 g_free(mem) 在
 *     glib >= 2.78 的 gmem.h 里是宏，会展开成
 *     g_free_sized(mem, __builtin_object_size(..))，不钉住就隐含依赖 2.78+
 *     的符号，在 22.04 上要到链接期才炸。**两条必须成对**：只写 MAX 时
 *     gversionmacros.h 的 sanity check 会 #error（MIN 默认 CUR_STABLE > MAX），
 *     而 gstring.h 的 g_string_free 宏按 MIN >= 2.76 展开成 2.76 的
 *     g_string_free_and_steal，在 -Werror=deprecated-declarations 下把 glib
 *     自己的头判成红。设 MIN 之后这两条一起消失，且 GLIB_AVAILABLE_IN_2_74
 *     /2_76 那批新 API 变成编译期可见的 "Not available"。
 * 宏体里的版本常量此刻还没定义，但宏是延迟展开的：首次求值发生在
 * gdkversionmacros.h / glib 的 gversionmacros.h 内部的 #if，那时版本宏早已
 * 定义（见 gdkversionmacros.h 99 行起）。
 * 假头构建（MOONUI_MOCK_GTK）没有这些宏，整段跳过。 */
#ifndef MOONUI_MOCK_GTK
#ifndef GDK_VERSION_MIN_REQUIRED
#define GDK_VERSION_MIN_REQUIRED GDK_VERSION_4_6
#endif
#ifndef GDK_VERSION_MAX_ALLOWED
#define GDK_VERSION_MAX_ALLOWED GDK_VERSION_4_6
#endif
#ifndef GLIB_VERSION_MIN_REQUIRED
#define GLIB_VERSION_MIN_REQUIRED GLIB_VERSION_2_72
#endif
#ifndef GLIB_VERSION_MAX_ALLOWED
#define GLIB_VERSION_MAX_ALLOWED GLIB_VERSION_2_72
#endif
#endif

#include <gtk/gtk.h>
#include <gdk/gdk.h>
#include <math.h>

/* 全局状态：与 mac adapter 同形的「全局回调 + 读回」pull 模型。
 * MoonBit 侧每次事件循环先读回状态访问器，再处理；C 侧只负责在
 * 事件到来时填状态 + 触发闭包。 */
static gboolean moonui_inited = FALSE;
static gboolean moonui_quit_flag = FALSE;
/* 失败原因（adapter.h：成功之后调用返回空 bytes）。UTF-8，静态缓冲足够——
 * 目前唯一的写入者是 init 打不开显示器那一支。 */
static char moonui_last_error_buf[192];

#define MOONUI_WIN_SLOTS 64
typedef struct MoonuiWinSlot {
  GtkWidget *win;
  moonui_closure_fn closing_fn; void *closing_cl;
  moonui_closure_fn resized_fn; void *resized_cl;
  moonui_closure_fn moved_fn;   void *moved_cl;
  double last_zoom;
  double last_angle;
  /* 几何读数（见 moonui_poll_geometry）：上一圈量到的客户区尺寸、有没有拿到过
   * 基准、下一次变化是不是我们自己发起的（一次性的回声挡）。 */
  int last_w, last_h;
  int geometry_seen;
  int suppress_resize;
  /* 内容容器（T235 P6）：overlay 是窗口唯一 child，fixed 是它里面那层绝对摆放
   * 容器（控件挂在这层）。两个都**惰性创建**——不摆控件也不上画布的窗口一个
   * 字节都不多花，而一旦创建就跟着窗口活到销毁。 */
  GtkWidget *overlay;
  GtkWidget *fixed;
  /* 菜单栏（T235 P6-4）：装了菜单栏的窗口，唯一 child 从 overlay 换成一只
   * GtkBox[menubar, overlay]，root 记的就是那只 box（没装菜单时两者都是 NULL，
   * 窗口结构因此与 P6-1 完全一致）。menubar 我们自己持一份引用——\`gtk_box_remove\`
   * 会放掉容器那份，不留一份的话「换一棵菜单」那一步就对着已释放的控件操作。 */
  GtkWidget *root;
  GtkWidget *menubar;
  /* P6-5b 焦点链：Core 整份推来的 owner 指针序列（按声明序）。Tab 由
   * moonui_gtk_focus_tab_step 按它推进。内嵌固定数组——窗口槽被 memset 时
   * 链随之清空，不用单独释放（T110 登记表跟销毁同步销账）。 */
  moonui_ptr focus_chain[64];
  int focus_chain_len;
} MoonuiWinSlot;
static MoonuiWinSlot moonui_wins[MOONUI_WIN_SLOTS];

/* 菜单栏装到新窗口上的钩子（T235 P6-4）。menus_gtk.inc 在第一次装菜单时把它
 * 指到实现上，拆掉菜单时清回 NULL；假头构建里那份实现整片被跳过，于是这里
 * 始终是 NULL，\`window_new\` 那句调用就是空操作——不需要在假头里给 GMenu 的
 * 形状，也不会出现"声明了但没有实现"的静态函数。 */
static void (*moonui_gtk_menu_attach_hook)(GtkWidget *win) = NULL;

/* ---- 控件登记表（T235 P6）----
 * 每个经 moonui_native_widget_new 造出来的控件在这里记一行 GtkWidget* → kind。
 * 为什么需要这本账：GTK4 的控件是统一类型，\`gtk_widget_get_type()\` 问不出"这是
 * Label 还是 Panel"（我们用容器与绘制面拼，类型未必不同），而 set_style /
 * 命中反查 / z 序这些入口都要按 kind 分派。mac 半用 objc_setAssociatedObject
 * 存 kind+1、Windows 半用 SetPropW——同一本账的三种落法，这里用静态表（与
 * 窗口登记表、画布上屏面登记表同一套形状）。
 *
 * 存 kind+1、0 表示空槽：kind 0 是 Label，用 0 当"空"会把 Label 读成没登记。
 * 登记/销账必须跟着 create/destroy 走（\`T110\` 那条老课：后端自建的"身份登记表"
 * 不同步销账，后来新建的控件会"继承"上一任的身份）。
 */
#define MOONUI_WIDGET_SLOTS 256
typedef struct MoonuiWidgetSlot {
  GtkWidget *w;
  int kind1; /* kind + 1；0 = 空槽 */
  /* 最近一次 control_set_bounds 落下的**逻辑**坐标/尺寸。raise 得重挂（GtkFixed
   * 没有"提到最上层"的 API，只能摘下来再放回去），而重挂会把位置清零，靠这份
   * 复原。 */
  int has_bounds;
  int bx, by, bw, bh;
  /* P6-5 控件叶子：一条 action 槽（clicked / toggled 共用，与 mac 的 wire_action
   * 同形）+ 一条 text 槽（changed）。inhibit 挡"程序化改值"的回声：真 GTK4 探针
   * 实测 gtk_editable_set_text 会发 changed、gtk_check_button_set_active 会发
   * toggled，而 ABI 契约要求程序化设置不回声（mac/win 两侧都钉着）。 */
  moonui_closure_fn action_fn;
  void *action_cl;
  moonui_closure_fn text_fn;
  void *text_cl;
  int action_connected;
  int text_connected;
  int inhibit;
  /* P6-5b 自绘面点击：与 action/text 分开一条槽——两条 ABI 是独立的，
   * 共用 action 槽会让「换一条」悄悄改掉另一条。gesture 存 void*：假头
   * 构建里没有 GtkGesture 的具体形状，而登记表本身两边都要编译。 */
  moonui_closure_fn custom_fn;
  void *custom_cl;
  int custom_connected;
  double custom_press_x, custom_press_y;
  int custom_press_armed;
  void *custom_gesture;
  /* kind 15 Scroll 的文档区 GtkFixed（不占控件槽：它是实现细节，不是 Core
   * 造出来的控件）。container_attach / is_container 靠它把子控件挂进去。 */
  GtkWidget *scroll_content;
  /* P6-5c 七构造族：一条 change 槽（6 个 on_* 回调共用，与 action/text 分开，
   * 不能共用 action 槽否则"换一条"会悄悄改掉另一条）/ Progress 的值缓存
   * （-1 = 不定进度，GTK 自身读不回）/ DatePicker 文本缓存（GtkCalendar 只认
   * 日期、时间会丢，原文往返靠这里）/ ComboBox 选中跟踪（GtkDropDown 不支持
   * "无选中"，初始默认选 0，探针实测 set_selected(INVALID) 是 no-op）。 */
  moonui_closure_fn change_fn;
  void *change_cl;
  int change_connected;
  int progress_val;
  char *date_cache;
  int combo_has_sel;
} MoonuiWidgetSlot;
static MoonuiWidgetSlot moonui_widgets[MOONUI_WIDGET_SLOTS];

static MoonuiWidgetSlot *moonui_wslot_of(GtkWidget *w) {
  int i;
  if (w == NULL) return NULL;
  for (i = 0; i < MOONUI_WIDGET_SLOTS; ++i) {
    if (moonui_widgets[i].kind1 != 0 && moonui_widgets[i].w == w) {
      return &moonui_widgets[i];
    }
  }
  return NULL;
}
static MoonuiWidgetSlot *moonui_wslot_alloc(GtkWidget *w, int kind) {
  MoonuiWidgetSlot *s;
  int i;
  if (w == NULL || kind < 0) return NULL;
  s = moonui_wslot_of(w);
  if (s != NULL) {
    s->kind1 = kind + 1;
    return s;
  }
  for (i = 0; i < MOONUI_WIDGET_SLOTS; ++i) {
    if (moonui_widgets[i].kind1 == 0) {
      memset(&moonui_widgets[i], 0, sizeof(MoonuiWidgetSlot));
      moonui_widgets[i].w = w;
      moonui_widgets[i].kind1 = kind + 1;
      return &moonui_widgets[i];
    }
  }
  return NULL; /* 表满：调用方按"造不出来"处理（宁可不给，也不给半个控件） */
}
static void moonui_wslot_free(GtkWidget *w) {
  MoonuiWidgetSlot *s = moonui_wslot_of(w);
  if (s == NULL) return;
  /* 销账要连闭包一起松：Core 交给 C 看的 closure 是 MoonBit 对象，漏一次就漏
   * 一个引用（T110 那条"登记表要跟销毁同步销账"的同一课，这次是引用不是指针）。 */
  if (s->action_cl != 0) moonbit_decref(s->action_cl);
  if (s->text_cl != 0) moonbit_decref(s->text_cl);
  if (s->custom_cl != 0) moonbit_decref(s->custom_cl);
  if (s->change_cl != 0) moonbit_decref(s->change_cl);
  if (s->date_cache != 0) free(s->date_cache);
  memset(s, 0, sizeof(MoonuiWidgetSlot));
}
/* -1 = 不是我们造的控件（或空指针）。 */
static int moonui_widget_kind_of(GtkWidget *w) {
  MoonuiWidgetSlot *s = moonui_wslot_of(w);
  return s == NULL ? -1 : s->kind1 - 1;
}

/* 命中反查（\`mouse_owner\`）：从 pick 到的那个 widget 沿父链往上找，第一个
 * "登记表里有"的就是 owner。找不到（点到空白、点到窗口自己）返回 0——ABI 的
 * "0 = 空白"。为什么要沿父链：GTK4 里控件的内部分件会被 pick 命中，而 Core
 * 要的是那个控件句柄（mac 半靠 hitTest + owner 记号做同一件事，见 \`T86①\`）。 */
static moonui_ptr moonui_owner_at(GtkWidget *win, double lx, double ly) {
  GtkWidget *hit;
  if (win == NULL) return 0;
  hit = gtk_widget_pick(win, lx, ly, GTK_PICK_DEFAULT);
  while (hit != NULL) {
    if (moonui_widget_kind_of(hit) >= 0) return (moonui_ptr)(uintptr_t)hit;
    if (hit == win) break;
    hit = gtk_widget_get_parent(hit);
  }
  return 0;
}

/* 层叠序号（ABI：0 = 最上层）。GtkFixed 的绘制顺序就是子节点顺序、后来的在上，
 * 所以"最上层"是子链表的最后一个——从尾数，不从头数。 */
static int moonui_widget_z_index(GtkWidget *w) {
  GtkWidget *parent, *it;
  int total = 0, pos = -1;
  if (w == NULL) return -1;
  parent = gtk_widget_get_parent(w);
  if (parent == NULL) return -1;
  for (it = gtk_widget_get_first_child(parent); it != NULL;
       it = gtk_widget_get_next_sibling(it)) {
    if (it == w) pos = total;
    total++;
  }
  if (pos < 0) return -1;
  return total - 1 - pos;
}

/* 键盘全局状态 */
static moonui_closure_fn moonui_key_fn = 0;
static void *moonui_key_closure = 0;
static moonui_ptr moonui_key_target_ptr = 0;
static int moonui_key_down = 0;
static int moonui_key_mods = 0;
static char moonui_key_name_buf[32];

/* 鼠标全局状态 */
static moonui_closure_fn moonui_mouse_fn = 0;
static void *moonui_mouse_closure = 0;
static moonui_ptr moonui_mouse_target_ptr = 0;
static moonui_ptr moonui_mouse_owner_ptr = 0;
static int moonui_mouse_code = 0;
static int moonui_mouse_mods_val = 0;
static int moonui_mouse_px = 0, moonui_mouse_py = 0;
static int moonui_mouse_ldx = 0, moonui_mouse_ldy = 0;

/* 手势全局状态 */
static moonui_closure_fn moonui_gesture_fn = 0;
static void *moonui_gesture_closure = 0;
static moonui_ptr moonui_gesture_target_ptr = 0;
static int moonui_gesture_kind = 0;
static int moonui_gesture_phase = 0;
static int moonui_gesture_dir = 0;
static int64_t moonui_gesture_value = 0;

/* ---- 工具 ---- */
/* 高 32 位放 a、低 32 位放 b（adapter.h 的 pack2 口径）。中转必须是无符号：
 * 有符号负数左移 32 位在 C 里是未定义行为（先转 int64 再左移同样 UB），
 * 先取 uint32 再拼才确定。负坐标（副屏在负半轴）真会走到这里。 */
static int64_t moonui_pack2(int a, int b) {
  return (int64_t)(((uint64_t)(uint32_t)a << 32) | (uint64_t)(uint32_t)b);
}
/* 取缩放因子。**GTK4 没有 gdk_display_get_scale_factor**（那是 GTK3 的 API，
 * 真头下编译直接报 undeclared）：缩放挂在 surface / monitor 上。
 *
 * T241（2026-11-10）：以前 w == NULL 时直接回 1，理由是「窗口还没 realize
 * 时没有 surface，未上屏谈缩放没有意义」。这句对 surface 成立，对 display
 * 不成立——GDK 的 monitor 列表在 gtk_init 之后就有，且 gtk_window_new()
 * 造出来的窗口未 realize 时 gtk_widget_get_scale_factor 已经报 2（本机 mac
 * 2x 屏实测：display 有两块 monitor，scale 分别 2 与 1，裸窗口报 2）。
 * 于是 window_new(320,240) 按 1 换算成 320 逻辑点，而 content_size 按
 * 2 读回，报 640x480；system_dpi 也跟着谎报 96。两处口径不一致的根因
 * 都在这一行，所以只改这里：w == NULL 时取 display 第一块 monitor 的 scale。
 *
 * 取第一块的理由：GDK4 没有 primary monitor 这个概念，列表首项正是
 * gtk_widget_get_scale_factor 对未上屏窗口用的那一块（实测同为 2）。
 * 窗口拖到另一块屏之后 scale_of(win) 会跟着变，那条由 Core 的
 * ScaleChanged 重排管，不在本函数里补。 */
static int moonui_display_scale(void) {
  GdkDisplay *d = gdk_display_get_default();
  GListModel *mons;
  GdkMonitor *m;
  int s = 1;
  if (d == NULL) return 1;
  mons = gdk_display_get_monitors(d);
  if (mons == NULL || g_list_model_get_n_items(mons) == 0) return 1;
  m = (GdkMonitor *)g_list_model_get_item(mons, 0);
  if (m != NULL) {
    s = gdk_monitor_get_scale_factor(m);
    g_object_unref(m);
  }
  return s > 0 ? s : 1;
}
static int moonui_scale_of(GtkWidget *w) {
  int s = 0;
  if (w != NULL) {
    GdkSurface *surf;
    s = gtk_widget_get_scale_factor(w);
    if (s <= 0) {
      surf = gtk_native_get_surface(GTK_NATIVE(w));
      if (surf != NULL) s = gdk_surface_get_scale_factor(surf);
    }
  } else {
    s = moonui_display_scale();
  }
  return s > 0 ? s : 1;
}
static char *moonui_dup(const char *s, int len) {
  char *out;
  if (len < 0) return 0;
  out = (char *)malloc((size_t)len + 1u);
  if (out == 0) return 0;
  if (len > 0) memcpy(out, s, (size_t)len);
  out[len] = '\\0';
  return out;
}
static moonbit_bytes_t moonui_bytes_of(const char *s) {
  int n = (int)strlen(s);
  moonbit_bytes_t out = moonbit_make_bytes(n, 0);
  if (n > 0) memcpy(out, s, (size_t)n);
  return out;
}
/* ---- 渲染后端偏好文件的三个帮手（T235 P6-7，与 mac 半同构）----
 * 路径默认 $HOME/.moonui/render_backend，内容是一行后端名。Linux 的
 * resolve 不用它们（本平台恒 Auto），但 write_pref* / pref_code_at 三条 ABI
 * 要用：写的是用户偏好，读回来的名字要能被 parse 看见原始码。 */
static int moonui_render_pref_default_path(char *buf, size_t n) {
  const char *home = getenv("HOME");
  int written;
  if (home == NULL || home[0] == '\\0') {
    return 0;
  }
  written = snprintf(buf, n, "%s/.moonui/render_backend", home);
  return written > 0 && (size_t)written < n;
}
/* 读 path 第一行并去掉尾部空白进 buf：读到非空内容返回 1，否则 0。 */
static int moonui_render_pref_read_line(const char *path, char *buf, size_t n) {
  FILE *f;
  size_t len;
  if (path == NULL || buf == NULL || n == 0) {
    return 0;
  }
  f = fopen(path, "rb");
  if (f == NULL) {
    return 0;
  }
  if (fgets(buf, (int)n, f) == NULL) {
    fclose(f);
    return 0;
  }
  fclose(f);
  len = strlen(buf);
  while (len > 0 && (buf[len - 1] == '\\n' || buf[len - 1] == '\\r' ||
                     buf[len - 1] == ' ' || buf[len - 1] == '\\t')) {
    buf[--len] = '\\0';
  }
  return len > 0;
}
/* 把后端名覆盖写进 path：0 成功、-1 失败。 */
static int moonui_render_pref_write_line(const char *path, const char *name) {
  FILE *f;
  int ok;
  if (path == NULL || name == NULL) {
    return -1;
  }
  f = fopen(path, "wb");
  if (f == NULL) {
    return -1;
  }
  ok = fprintf(f, "%s\\n", name) >= 0;
  if (fclose(f) != 0) {
    ok = 0;
  }
  return ok ? 0 : -1;
}
static int moonui_mods_of(GdkModifierType state) {
  int m = 0;
  if (state & GDK_CONTROL_MASK) m |= 1;
  if (state & GDK_ALT_MASK)     m |= 2;
  if (state & GDK_SHIFT_MASK)   m |= 4;
  if (state & (GDK_SUPER_MASK | GDK_META_MASK)) m |= 8;
  return m;
}
/* GTK 的键钮号 → ABI 的 button 位（0 Left / 1 Right / 2 Middle / 3 Extra1 /
 * 4 Extra2，见 adapter.h）。8/9 是 GTK 的侧键；其余不认识的返回 -1，调用方
 * 整条丢掉——宁可不报，也不报一个 Core 的枚举里没有的号。 */
/* kind 2 的 button 位是"按住哪颗在拖"（adapter.h）。GTK 的 GdkModifierType
 * 里 BUTTON1..5 那几位就是按住状态（1<<8 起，和修饰键那几位不重叠）。 */
static int moonui_held_button(GdkModifierType st) {
  if (st & GDK_BUTTON1_MASK) return 0;
  if (st & GDK_BUTTON3_MASK) return 1;
  if (st & GDK_BUTTON2_MASK) return 2;
  return 0;
}

static int moonui_map_button(int gtkb) {
  switch (gtkb) {
    case 1: return 0; /* Left */
    case 2: return 2; /* Middle（GTK 的 2 是中键，ABI 的 2 也是中键，这里不是笔误） */
    case 3: return 1; /* Right */
    case 8: return 3; /* Extra1 */
    case 9: return 4; /* Extra2 */
    default: return -1;
  }
}

/* ---- 键名词表 ----
 * adapter.h 键盘段钉的口径是「同一个物理键在两边给出同一个字符串」，而那张
 * 词表的正本是 mac 的 \`moonui_native_key_name_of_code\`（Enter / Tab / Escape /
 * Backspace / Delete / Home / End / PageUp / PageDown / Left / Right / Up /
 * Down / F1..F12 + 单个小写字母 + 单个数字 + Space）。
 * gdk_keyval_name 给的拼法有 5 处不同（Return / BackSpace / Page_Up /
 * Page_Down / space），其余同名；词表以外的键（修饰键自己、输入法、媒体键）
 * 一律留空串，调用方据此**不产事件**——同 mac 的 \`moonui_native_key_notify\`
 * 那一句「宁可不报，也不产一个 Core 匹配不到的名字」。 */
static const char *moonui_key_special(const char *n) {
  static const char *const kNames[] = {
      "Tab",   "Escape", "Delete", "Home", "End",   "Left",  "Right",
      "Up",    "Down",   "F1",     "F2",   "F3",    "F4",    "F5",
      "F6",    "F7",     "F8",     "F9",   "F10",   "F11",   "F12",
  };
  size_t i;
  for (i = 0; i < sizeof(kNames) / sizeof(kNames[0]); ++i) {
    if (strcmp(n, kNames[i]) == 0) return kNames[i];
  }
  return NULL;
}
static void moonui_key_name_store(guint keyval) {
  const char *n = gdk_keyval_name(keyval);
  const char *canon;
  moonui_key_name_buf[0] = '\\0';
  if (n == NULL) return;
  /* 单字符：字母折小写（Shift+a 的 keyval 是 'A'，mac 那侧同样折成 'a'，
   * 大写由修饰键位表达）、数字原样。 */
  if (n[1] == '\\0') {
    char c = n[0];
    if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
      moonui_key_name_buf[0] = c;
      moonui_key_name_buf[1] = '\\0';
      return;
    }
  }
  if (strcmp(n, "Return") == 0) canon = "Enter";
  else if (strcmp(n, "BackSpace") == 0) canon = "Backspace";
  else if (strcmp(n, "Page_Up") == 0) canon = "PageUp";
  else if (strcmp(n, "Page_Down") == 0) canon = "PageDown";
  else if (strcmp(n, "space") == 0) canon = "Space";
  else canon = moonui_key_special(n);
  if (canon == NULL) return; /* 词表外：留空串，调用方不产事件 */
  strncpy(moonui_key_name_buf, canon, sizeof(moonui_key_name_buf) - 1);
  moonui_key_name_buf[sizeof(moonui_key_name_buf) - 1] = '\\0';
}

/* ---- 窗口登记表 ---- */
static MoonuiWinSlot *moonui_win_slot_of(GtkWidget *w) {
  int i;
  /* P6-5b 真跑判据抓到的既有缺陷：空槽的 win 也是 NULL，不先挡住这句，
   * 传 NULL 会命中第一只空槽——set_focus_chain(0, ...) 因此谎报「收下」
   * （契约要求 -1）。窗口登记表按指针身份查，NULL 不是任何窗口的身份。 */
  if (w == NULL) return NULL;
  for (i = 0; i < MOONUI_WIN_SLOTS; ++i)
    if (moonui_wins[i].win == w) return &moonui_wins[i];
  return NULL;
}
static MoonuiWinSlot *moonui_win_slot_alloc(GtkWidget *w) {
  int i;
  for (i = 0; i < MOONUI_WIN_SLOTS; ++i) {
    if (moonui_wins[i].win == NULL) {
      memset(&moonui_wins[i], 0, sizeof(MoonuiWinSlot));
      moonui_wins[i].win = w;
      return &moonui_wins[i];
    }
  }
  return NULL;
}

/* ---- 内容容器（T235 P6）----
 * 窗口的唯一 child 是一只 GtkOverlay：主位（child）放整窗画布，overlay 位放
 * 绝对摆放层 GtkFixed（控件都挂在那层）。为什么不直接拿 GtkFixed 当窗口
 * child：整窗画布要跟着窗口尺寸自动铺满，而 GtkFixed 的子节点不会自动铺满，
 * 得在每圈几何轮询里手动跟；GtkOverlay 的主位天然铺满，省掉这套跟账。层叠也
 * 因此是对的——主位在下、overlay 位在上，正好是"画布当底、控件压在上面"。
 *
 * 两者都惰性创建。窗口已经带别的内容（不是我们造的）时一律不接：宁可如实
 * 返回 NULL 让调用方拿到 -1，也不去猜该怎么和别人的布局混排。
 */
static int moonui_gtk_is_container(GtkWidget *w) {
  int i;
  if (w == NULL) return 0;
  if (moonui_widget_kind_of(w) == 17) return 1; /* Panel 也是 GtkFixed */
  for (i = 0; i < MOONUI_WIN_SLOTS; ++i) {
    if (moonui_wins[i].win != NULL && moonui_wins[i].fixed == w) return 1;
  }
  /* kind 15 Scroll 的文档区：控件挂进它之后 control_set_bounds / origin /
   * raise 都要认它是容器，否则子树整体摆不了位置。 */
  for (i = 0; i < MOONUI_WIDGET_SLOTS; ++i) {
    if (moonui_widgets[i].kind1 - 1 == 15 &&
        moonui_widgets[i].scroll_content == w) return 1;
  }
  return 0;
}

static GtkWidget *moonui_gtk_window_overlay(GtkWidget *win, int create) {
  MoonuiWinSlot *s;
  GtkWidget *cur;
  if (win == NULL) return NULL;
  s = moonui_win_slot_of(win);
  if (s == NULL) return NULL; /* 不是 window_new 造出来的窗口 */
  if (s->overlay != NULL) return s->overlay;
  cur = gtk_window_get_child(GTK_WINDOW(win));
  if (cur != NULL) return NULL; /* 已有别人的内容：不接管 */
  if (!create) return NULL;
  s->overlay = gtk_overlay_new();
  if (s->overlay == NULL) return NULL;
  gtk_window_set_child(GTK_WINDOW(win), s->overlay);
  return s->overlay;
}

static GtkWidget *moonui_gtk_window_fixed(GtkWidget *win, int create) {
  GtkWidget *overlay;
  MoonuiWinSlot *s;
  if (win == NULL) return NULL;
  s = moonui_win_slot_of(win);
  if (s == NULL) return NULL;
  if (s->fixed != NULL) return s->fixed;
  overlay = moonui_gtk_window_overlay(win, create);
  if (overlay == NULL) return NULL;
  if (!create) return NULL;
  s->fixed = gtk_fixed_new();
  if (s->fixed == NULL) return NULL;
  /* overlay 位不参与测量（否则空摆放层会把窗口撑成 0×0 以外的最小值），铺满
   * 整块 overlay：这样控件坐标就是客户区坐标，与 mac 的 contentView 同口径。 */
  gtk_widget_set_halign(s->fixed, GTK_ALIGN_FILL);
  gtk_widget_set_valign(s->fixed, GTK_ALIGN_FILL);
  gtk_widget_set_hexpand(s->fixed, TRUE);
  gtk_widget_set_vexpand(s->fixed, TRUE);
  gtk_overlay_add_overlay(GTK_OVERLAY(overlay), s->fixed);
  return s->fixed;
}

/* ---- 菜单栏容器（T235 P6-4）----
 * 装了菜单栏的窗口，唯一 child 从 GtkOverlay 换成 GtkBox[GtkPopoverMenuBar, overlay]。
 * **只在真装了菜单栏时才换**：没菜单的窗口结构一动不动（P6-1 那些结构判据的形状
 * 因此不变），装菜单时换过去，菜单拆掉时再换回来。
 *
 * 为什么必须做这层容器，而不是把菜单栏叠在 overlay 上：GTK4 没有"窗口菜单栏"这个
 * 概念，控件只能进内容区；叠着放会盖住客户区顶部那一条，而 MoonUI 是整窗自绘的
 * （画布铺满客户区），被盖住的是界面本身。容器化之后客户区真的少了那一行，
 * 于是 window_content_size / set_content_size 要跟着补偿——与 Win32 半
 * 「SetMenu 之后客户区矮掉一行」是同一个问题（adapter.h 菜单栏段那段长注）。
 *
 * 引用账（GTK4 控件是 GInitiallyUnowned，这一步很容易写错）：
 *   - 换容器时 overlay 要在"两棵树之间"活着：先 g_object_ref 拿一份临时的，
 *     unparent 之后再挂进 box，最后放掉临时的。
 *   - 菜单栏由调用方自持一份（menus_gtk.inc 建它时就 ref_sink 了），这里只负责
 *     挂上/摘下，不在摘的时候销毁它。
 */

static void moonui_gtk_window_set_menubar(GtkWidget *win, GtkWidget *bar) {
  MoonuiWinSlot *s = moonui_win_slot_of(win);
  GtkWidget *overlay;
  if (s == NULL) return;
  if (s->menubar == bar) return;
  overlay = moonui_gtk_window_overlay(win, 1);
  if (overlay == NULL) return; /* 窗口带了别人的内容：不接管（与内容容器同一口径） */
  if (bar != NULL) {
    if (s->root == NULL) {
      GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
      if (box == NULL) return;
      g_object_ref(overlay);
      gtk_widget_unparent(overlay);
      gtk_window_set_child(GTK_WINDOW(win), box);
      gtk_box_append(GTK_BOX(box), overlay);
      g_object_unref(overlay);
      s->root = box;
    }
    if (s->menubar != NULL) {
      gtk_box_remove(GTK_BOX(s->root), s->menubar);
    }
    gtk_box_prepend(GTK_BOX(s->root), bar);
    s->menubar = bar;
  } else {
    if (s->menubar != NULL) {
      gtk_box_remove(GTK_BOX(s->root), s->menubar);
      s->menubar = NULL;
    }
    if (s->root != NULL) {
      g_object_ref(overlay);
      gtk_box_remove(GTK_BOX(s->root), overlay);
      gtk_window_set_child(GTK_WINDOW(win), overlay);
      g_object_unref(overlay);
      /* 上一步 set_child 已经把 box 从窗口上摘下来（它是唯一引用，就此销毁）；
       * 这里只清指针，不再 unparent，免得对着已释放对象操作。 */
      s->root = NULL;
    }
  }
  /* 装/拆菜单栏会改变客户区高度，但这不是 Core 要求的改尺寸：挡掉下一圈轮询的
   * 那次回声，别让它冒成一条 Resize 事件（adapter.h 的 on_resized 契约）。 */
  s->suppress_resize = 1;
}

/* 菜单栏占掉的逻辑像素高度（没有菜单栏 / 还没排版时是 0）。measure 而不是读
 * allocated height：\`set_content_size\` 可能发生在窗口上屏之前，那时分配尺寸还是
 * 0，而首选高度已经量得出来（本机实测菜单栏 24）。 */
static int moonui_gtk_menubar_height(GtkWidget *win) {
  MoonuiWinSlot *s = moonui_win_slot_of(win);
  int minimum = 0;
  int natural = 0;
  if (s == NULL || s->menubar == NULL) return 0;
  if (!gtk_widget_get_visible(s->menubar)) return 0;
  gtk_widget_measure(s->menubar, GTK_ORIENTATION_VERTICAL, -1, &minimum, &natural,
                     NULL, NULL);
  if (natural < 0) natural = 0;
  return natural;
}

/* 窗口销毁时把菜单栏那份自持引用放掉（控件树本身由 GTK 拆，这里只管我们自己
 * 拿的那一份）。幂等：没装菜单时什么都不做。 */
static void moonui_gtk_window_release_menu(GtkWidget *win) {
  MoonuiWinSlot *s = moonui_win_slot_of(win);
  if (s == NULL) return;
  if (s->menubar != NULL) {
    g_object_unref(s->menubar);
    s->menubar = NULL;
  }
  s->root = NULL;
}

/* 窗口被 GTK 直接销毁（不是走 Core 的 window_destroy）时的兜底清账：登记表不能
 * 留一个已释放的窗口指针，否则下一个同地址窗口会"继承"它的槽位（\`T110\` 那条老课）。
 * Core 主动销毁时 slot 已经先被清掉，这里查不到、什么都不做。 */
static void moonui_gtk_on_window_destroy(GtkWidget *win, gpointer data) {
  MoonuiWinSlot *s = moonui_win_slot_of(win);
  (void)data;
  if (s == NULL) return;
  moonui_gtk_window_release_menu(win);
  if (s->closing_cl != 0) moonbit_decref(s->closing_cl);
  if (s->resized_cl != 0) moonbit_decref(s->resized_cl);
  if (s->moved_cl != 0) moonbit_decref(s->moved_cl);
  memset(s, 0, sizeof(MoonuiWinSlot));
}

/* 闭包槽位换人：先把旧的那份松掉再装新的。mac 那侧 \`moonui_native_take_slot\`
 * 与 \`moonui_native_key_drop_closure\` 是同一件事（adapter.h 的「重复调用只换
 * 回调」），不松就每换一次漏一个 MoonBit 对象。 */
/* 带 id 的那一族闭包（菜单栏 / 上下文菜单）用这一条：\`moonui_closure_replace\`
 * 收的是 \`void (*)(void *)\`，而菜单回调是 \`void (*)(void *, int)\`——C 里这两个
 * 函数指针类型不兼容，硬转过去在 \`-Werror\` 下编不过（也不该转）。 */
static void moonui_closure_id_replace(moonui_closure_id_fn *slot_fn,
                                      void **slot_cl, moonui_closure_id_fn fn,
                                      void *closure) {
  if (*slot_cl != 0 && *slot_cl != closure) {
    moonbit_decref(*slot_cl);
  }
  *slot_fn = fn;
  *slot_cl = closure;
  if (closure != 0) {
    moonbit_incref(closure);
  }
}

static void moonui_closure_replace(moonui_closure_fn *slot_fn, void **slot_cl,
                                   moonui_closure_fn fn, void *closure) {
  if (*slot_cl != 0 && *slot_cl != closure) {
    moonbit_decref(*slot_cl);
  }
  *slot_fn = fn;
  *slot_cl = closure;
  if (closure != 0) {
    moonbit_incref(closure);
  }
}

/* 客户区尺寸变化走**轮询**（同 mac 侧的 T24/T39 那套「每圈问一次、只在差异上
 * 发」）。为什么不用信号：GTK4 的 GdkSurface 在 Wayland 下既不保证「窗口被挪」
 * 可读（客户端拿不到自己的位置），\`layout\`/\`resize\` 也不区分有没有真变，而
 * \`gtk_widget_get_width/height\` 是确定有的读数、且和 content_size 同一套口径。
 * 回声挡：程序自己 \`set_content_size\` 之后置 suppress_resize，下一圈看见的第一次
 * 变化按基准吞掉，不对 Core 报 Resize（adapter.h 那句「Core 自己发起的改尺寸
 * 不会回声成一条 Resize 事件」）。 */
static void moonui_poll_geometry(void) {
  int i;
  for (i = 0; i < MOONUI_WIN_SLOTS; ++i) {
    MoonuiWinSlot *s = &moonui_wins[i];
    int w, h;
    if (s->win == NULL) continue;
    w = gtk_widget_get_width(s->win);
    h = gtk_widget_get_height(s->win);
    if (w <= 0 || h <= 0) continue; /* 还没上屏：不算变化，也不算基准 */
    if (!s->geometry_seen) {
      s->geometry_seen = 1;
      s->last_w = w;
      s->last_h = h;
      s->suppress_resize = 0;
      continue;
    }
    if (s->suppress_resize) {
      s->suppress_resize = 0;
      s->last_w = w;
      s->last_h = h;
      continue;
    }
    if (w == s->last_w && h == s->last_h) continue;
    s->last_w = w;
    s->last_h = h;
    if (s->resized_fn) s->resized_fn(s->resized_cl);
  }
}

/* ---- 信号处理器前向声明（静态，供 REAL 函数连接）---- */
/* P6-5b：Tab 焦点链定义在 prelude 末尾（那里窗口槽与控件槽都已就绪）。
 * 刻意非 static：canvas-pixel 真跑判据与生成物是两个翻译单元，要 extern 到
 * 它才能驱动「按链推进」；prelude 不参与生成器的 ABI 名字扫描（那只扫
 * IMPL_FILES 的 .inc），所以这不是一条 adapter.h ABI。 */
int moonui_gtk_focus_tab_step(GtkWidget *win, int backward);
/* Scroll 文档区的内容指针定义在 scroll_gtk.inc；widgets_gtk.inc 的
 * container_attach 在它之前 include，所以这里给一份前向声明。 */
static GtkWidget *moonui_gtk_scroll_content(GtkWidget *sw);
static gboolean moonui_on_close_request(GtkWindow *win, gpointer data);
static gboolean moonui_key_pressed(GtkEventControllerKey *self, guint keyval, guint keycode, GdkModifierType state, gpointer data);
static void moonui_key_released(GtkEventControllerKey *self, guint keyval, guint keycode, GdkModifierType state, gpointer data);
static void moonui_motion(GtkEventControllerMotion *self, double x, double y, gpointer data);
static void moonui_motion_leave(GtkEventControllerMotion *self, gpointer data);
static void moonui_click_pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data);
static void moonui_click_released(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data);
static gboolean moonui_scroll(GtkEventControllerScroll *self, double dx, double dy, gpointer data);
static void moonui_gesture_zoom_begin(GtkGesture *g, GdkEvent *e, gpointer data);
static void moonui_gesture_zoom_scale(GtkGestureZoom *g, double scale, gpointer data);
static void moonui_gesture_zoom_end(GtkGesture *g, GdkEvent *e, gpointer data);
static void moonui_gesture_rotate_begin(GtkGesture *g, GdkEvent *e, gpointer data);
static void moonui_gesture_rotate_angle(GtkGestureRotate *g, double angle, double delta, gpointer data);
static void moonui_gesture_rotate_end(GtkGesture *g, GdkEvent *e, gpointer data);
static void moonui_gesture_swipe(GtkGestureSwipe *g, double vx, double vy, gpointer data);

/* ---- 信号处理器（静态，供 REAL 函数连接）---- */
static gboolean moonui_on_close_request(GtkWindow *win, gpointer data) {
  MoonuiWinSlot *slot = moonui_win_slot_of(GTK_WIDGET(win));
  (void)data;
  if (slot == NULL || slot->closing_fn == 0) {
    /* 没人订阅就放行 GTK 默认销毁——订阅了才由 Core 决定顺序（同 mac 的
     * windowShouldClose 返 NO 只在有回调时）。 */
    return FALSE;
  }
  slot->closing_fn(slot->closing_cl);
  return TRUE;
}
static gboolean moonui_key_pressed(GtkEventControllerKey *self, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
  GtkWidget *win = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(self));
  const char *kn;
  int is_tab, backward, handled = 0;
  (void)keycode; (void)data;
  moonui_key_name_store(keyval);
  /* 两条早退改写成条件块：Tab 无论如何都要走到下面的焦点链拦截，而事件流
   * 不动——Core 照旧在按下那一刻的持有者身上看到 KeyDown/KeyUp（adapter.h
   * :1806 的契约），只是 GTK 默认那套 z 序遍历被我们接管。 */
  if (moonui_key_name_buf[0] != '\\0' && moonui_key_fn != 0) {
    moonui_key_target_ptr = (moonui_ptr)(uintptr_t)win;
    moonui_key_down = 1;
    moonui_key_mods = moonui_mods_of(state);
    moonui_key_fn(moonui_key_closure);
  }
  kn = gdk_keyval_name(keyval);
  /* 按 gdk_keyval_name 的**名字**认，不硬编码 keyval 数值（P6-4c 的 GEnum
   * 按名字查同一条纪律）。Shift+Tab 在 GDK 上是 ISO_Left_Tab，也有合成器
   * 报 Tab+Shift，两条都收。 */
  is_tab = (kn != NULL && (strcmp(kn, "Tab") == 0 ||
                           strcmp(kn, "ISO_Left_Tab") == 0));
  backward = (kn != NULL && strcmp(kn, "ISO_Left_Tab") == 0) ||
             ((state & GDK_SHIFT_MASK) != 0);
  if (is_tab) handled = moonui_gtk_focus_tab_step(win, backward);
  /* 有链并接管了才吞：空链交回 GTK 自己的 z 序（契约：空串 = 清空链）。 */
  return handled ? TRUE : FALSE;
}
static void moonui_key_released(GtkEventControllerKey *self, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
  GtkWidget *win = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(self));
  (void)keycode; (void)data;
  moonui_key_name_store(keyval);
  if (moonui_key_name_buf[0] == '\\0') return;
  if (moonui_key_fn == 0) return;
  moonui_key_target_ptr = (moonui_ptr)(uintptr_t)win;
  moonui_key_down = 0;
  moonui_key_mods = moonui_mods_of(state);
  moonui_key_fn(moonui_key_closure);
}
static void moonui_motion(GtkEventControllerMotion *self, double x, double y, gpointer data) {
  GtkWidget *win = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(self));
  GdkEvent *ev = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(self));
  int scale = moonui_scale_of(win);
  GdkModifierType st = ev ? gdk_event_get_modifier_state(ev) : (GdkModifierType)0;
  (void)data;
  moonui_mouse_target_ptr = (moonui_ptr)(uintptr_t)win;
  /* 命中反查在这里做、不在读回口子做：ABI 要的是"**这一颗**事件命中谁"，
   * 读回时再 pick 一次读到的是当时指针的位置，是另一件事。 */
  moonui_mouse_owner_ptr = moonui_owner_at(win, x, y);
  /* kind 2：没按住键是悬停移动、按住键是拖拽——两种在 ABI 里同一个 kind，
   * 差别只在 button 位（同 mac 的 *MouseDragged 与 hover 通道合流）。 */
  moonui_mouse_code = 2 * 8 + moonui_held_button(st);
  moonui_mouse_mods_val = moonui_mods_of(st);
  moonui_mouse_px = (int)llround(x * scale);
  moonui_mouse_py = (int)llround(y * scale);
  moonui_mouse_ldx = 0; moonui_mouse_ldy = 0;
  if (moonui_mouse_fn) moonui_mouse_fn(moonui_mouse_closure);
}
static void moonui_motion_leave(GtkEventControllerMotion *self, gpointer data) {
  GtkWidget *win = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(self));
  (void)data;
  moonui_mouse_target_ptr = (moonui_ptr)(uintptr_t)win;
  moonui_mouse_owner_ptr = 0;
  moonui_mouse_code = 5 * 8 + 0; /* kind 5 离开窗口 */
  moonui_mouse_mods_val = 0;
  if (moonui_mouse_fn) moonui_mouse_fn(moonui_mouse_closure);
}
static void moonui_click_pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data) {
  GtkWidget *win = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
  GdkEvent *ev = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(gesture));
  int scale = moonui_scale_of(win);
  int button = ev ? moonui_map_button((int)gdk_button_event_get_button(ev)) : 0;
  int kind = (n_press == 2) ? 3 : 0; /* 第二击=双击（同 mac clickCount==2）；其余=按下 */
  (void)data;
  if (button < 0) return; /* ABI 里没有这颗钮，整条丢掉 */
  moonui_mouse_target_ptr = (moonui_ptr)(uintptr_t)win;
  moonui_mouse_owner_ptr = moonui_owner_at(win, x, y);
  moonui_mouse_code = kind * 8 + button;
  moonui_mouse_mods_val = ev ? moonui_mods_of(gdk_event_get_modifier_state(ev)) : 0;
  moonui_mouse_px = (int)llround(x * scale);
  moonui_mouse_py = (int)llround(y * scale);
  moonui_mouse_ldx = 0; moonui_mouse_ldy = 0;
  if (moonui_mouse_fn) moonui_mouse_fn(moonui_mouse_closure);
}
static void moonui_click_released(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data) {
  GtkWidget *win = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
  GdkEvent *ev = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(gesture));
  int scale = moonui_scale_of(win);
  int button = ev ? moonui_map_button((int)gdk_button_event_get_button(ev)) : 0;
  (void)n_press; (void)data;
  if (button < 0) return;
  moonui_mouse_target_ptr = (moonui_ptr)(uintptr_t)win;
  moonui_mouse_owner_ptr = moonui_owner_at(win, x, y);
  moonui_mouse_code = 1 * 8 + button; /* kind 1 抬起 */
  moonui_mouse_mods_val = ev ? moonui_mods_of(gdk_event_get_modifier_state(ev)) : 0;
  moonui_mouse_px = (int)llround(x * scale);
  moonui_mouse_py = (int)llround(y * scale);
  moonui_mouse_ldx = 0; moonui_mouse_ldy = 0;
  if (moonui_mouse_fn) moonui_mouse_fn(moonui_mouse_closure);
}
static gboolean moonui_scroll(GtkEventControllerScroll *self, double dx, double dy, gpointer data) {
  GtkWidget *win = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(self));
  GdkEvent *ev = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(self));
  (void)data;
  moonui_mouse_target_ptr = (moonui_ptr)(uintptr_t)win;
  /* 滚轮事件自己不带坐标，命中反查只能拿上一颗鼠标事件的位置凑——这也是
   * mac 半的口径（滚轮落到自绘面身上靠的就是"光标当下在谁上面"）。 */
  moonui_mouse_owner_ptr = moonui_owner_at(
      win, (double)moonui_mouse_px / (double)moonui_scale_of(win),
      (double)moonui_mouse_py / (double)moonui_scale_of(win));
  moonui_mouse_code = 4 * 8 + 0; /* kind 4 滚轮；button 位恒 0 */
  moonui_mouse_mods_val = ev ? moonui_mods_of(gdk_event_get_modifier_state(ev)) : 0;
  /* 这一格是**已知未校准**的转换，别当它已经对好了。T235 P8 把三个未知里
   * 两个查清、一个坐实为「当前口径下无解」：
   * ① 单位——ABI 要逻辑像素，而 mac 那边"一格滚轮 ≈ 3 行 × 每行 10 px = 30"。
   *    GTK 的文档把两种单位分得很清（gdk/gdkevents.h 的 GdkScrollUnit）：
   *    \`GDK_SCROLL_UNIT_WHEEL\` 是**格数**（1.0 = 一格），\`GDK_SCROLL_UNIT_SURFACE\`
   *    才是表面逻辑像素。要按单位分档乘倍数，本来该读
   *    \`gtk_event_controller_scroll_get_unit()\`——但它是 **GTK 4.8 起**才有的
   *    （头里 GDK_AVAILABLE_IN_4_8，GdkScrollUnit 也是 Since 4.8），而本后端的最低
   *    口径是 4.6（Ubuntu 22.04 系统那份），用了就过不了
   *    scripts/gtk4-sysroot-check.sh 的第二档。所以这里**原值透传**：读得到的就是
   *    GtkEventControllerScroll 给的 delta（不带 DISCRETE 旗标时 GTK 自己已把离散
   *    滚轮插值成 smooth 值）。要对齐 mac 那个 30，只有两条路——把最低版本抬到
   *    4.8，或在真机上量一次后按平台定倍数；两条都写在 TODO T235 P8 里。
   * ② 方向——ABI 正 = 往下/往右读；GTK 的 dy 正也是"内容往上走"，同向。
   *    "自然滚动"取反要等真机量（\`isDirectionInvertedFromDevice\` 的对位物）；
   *    GTK 4.20 才有 \`GTK_EVENT_CONTROLLER_SCROLL_PHYSICAL_DIRECTION\`，同样高于
   *    我们的最低口径，不能用来区分。
   * ③ pos——滚轮事件没有坐标，这里留的是上一颗鼠标事件的位置；ABI 的
   *    \`Event::Scroll\` 只带 delta、不消费 pos，所以不影响 Core。
   *
   * 顺带记一条 P8 查实的事：**GTK4 的公开头里没有任何 GdkEvent 构造函数**
   * （\`gdk_event_new\` / \`gdk_key_event_new\` / \`gdk_scroll_event_new\` 全都没有，
   * gdk_display_put_event 自 4.10 起弃用且仍要一个既存事件），所以"合成一个真
   * 事件喂进去"在进程内做不到。滚轮 delta 与 Tab 真派发都只能由**外部输入**驱动
   * （X 下 xdotool），即只能在 CI 的 xvfb 里量。 */
  moonui_mouse_ldx = (int)llround(dx);
  moonui_mouse_ldy = (int)llround(dy);
  if (moonui_mouse_fn) moonui_mouse_fn(moonui_mouse_closure);
  return FALSE;
}
/* 手势（P3.1，GTK4 触控板）：pinch/rotate/swipe。若 Linux 真机编译不过，可临时
 * 注释本段并把 moonui_native_on_gesture 改成 \`return -1;\`（同 Windows 口径）。 */
static void moonui_gesture_zoom_begin(GtkGesture *g, GdkEvent *e, gpointer data) {
  MoonuiWinSlot *slot = (MoonuiWinSlot *)data;
  (void)g; (void)e;
  moonui_gesture_kind = 0; moonui_gesture_phase = 0; /* began */
  moonui_gesture_target_ptr = (moonui_ptr)(uintptr_t)gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(g));
  moonui_gesture_dir = 0; moonui_gesture_value = 0;
  if (slot) slot->last_zoom = 1.0;
  if (moonui_gesture_fn) moonui_gesture_fn(moonui_gesture_closure);
}
static void moonui_gesture_zoom_scale(GtkGestureZoom *g, double scale, gpointer data) {
  MoonuiWinSlot *slot = (MoonuiWinSlot *)data;
  double d = scale - (slot ? slot->last_zoom : 1.0);
  if (slot) slot->last_zoom = scale;
  (void)g;
  moonui_gesture_kind = 0; moonui_gesture_phase = 1; /* changed */
  moonui_gesture_value = (int64_t)llround(d * 1e6); /* 定点百万分之一 */
  if (moonui_gesture_fn) moonui_gesture_fn(moonui_gesture_closure);
}
static void moonui_gesture_zoom_end(GtkGesture *g, GdkEvent *e, gpointer data) {
  (void)g; (void)e; (void)data;
  moonui_gesture_kind = 0; moonui_gesture_phase = 2; /* ended */
  if (moonui_gesture_fn) moonui_gesture_fn(moonui_gesture_closure);
}
static void moonui_gesture_rotate_begin(GtkGesture *g, GdkEvent *e, gpointer data) {
  MoonuiWinSlot *slot = (MoonuiWinSlot *)data;
  (void)g; (void)e;
  moonui_gesture_kind = 1; moonui_gesture_phase = 0;
  moonui_gesture_target_ptr = (moonui_ptr)(uintptr_t)gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(g));
  if (slot) slot->last_angle = 0.0;
  if (moonui_gesture_fn) moonui_gesture_fn(moonui_gesture_closure);
}
static void moonui_gesture_rotate_angle(GtkGestureRotate *g, double angle, double delta, gpointer data) {
  MoonuiWinSlot *slot = (MoonuiWinSlot *)data;
  (void)g; (void)slot;
  moonui_gesture_kind = 1; moonui_gesture_phase = 1;
  moonui_gesture_value = (int64_t)llround(delta * (180.0 / G_PI) * 1e6); /* 弧度→角度→定点 */
  if (moonui_gesture_fn) moonui_gesture_fn(moonui_gesture_closure);
}
static void moonui_gesture_rotate_end(GtkGesture *g, GdkEvent *e, gpointer data) {
  (void)g; (void)e; (void)data;
  moonui_gesture_kind = 1; moonui_gesture_phase = 2;
  if (moonui_gesture_fn) moonui_gesture_fn(moonui_gesture_closure);
}
static void moonui_gesture_swipe(GtkGestureSwipe *g, double vx, double vy, gpointer data) {
  (void)data;
  moonui_gesture_kind = 2; moonui_gesture_phase = 1; /* swipe 是离散事件，phase 恒 1 */
  moonui_gesture_target_ptr = (moonui_ptr)(uintptr_t)gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(g));
  /* 方向：手指往哪儿划；vx<0 向右、>0 向左；vy<0 向下、>0 向上（同 mac 口径） */
  if (vx < 0) moonui_gesture_dir = 1;
  else if (vx > 0) moonui_gesture_dir = 0;
  else if (vy < 0) moonui_gesture_dir = 3;
  else if (vy > 0) moonui_gesture_dir = 2;
  else moonui_gesture_dir = 0;
  moonui_gesture_value = 0;
  if (moonui_gesture_fn) moonui_gesture_fn(moonui_gesture_closure);
}

/* ---- 对话框的 response → ABI 返回码（T235 P6-3）----
 * 这两条是**纯映射**，所以放在 prelude 而不是 dialogs_gtk.inc：假头构建会跳过
 * 那片手写实现（它要真 GtkMessageDialog），但映射本身与 GTK 无关，放在这里
 * scripts/mock-gtk-selftest.c 就能真跑判据。口径与 mac 那半逐字对齐（见
 * adapter_native.m 的 moonui_native_dialog_message / _confirm 返回处）：
 *   - message：只有一只按钮，"按了确定"与"面板被关掉"对调用方是同一件事（§24 的
 *     message 返回 Unit，这个区别没有地方放），一律 0；
 *   - confirm：只有 GTK_RESPONSE_YES 算"同意"，其余（NO / CANCEL / DELETE_EVENT /
 *     Esc / 直接关窗）一律 0——§24 的"取消返回 false"。 */
static int moonui_dialog_message_result(int response) {
  (void)response;
  return 0;
}
static int moonui_dialog_confirm_result(int response) {
  return response == GTK_RESPONSE_YES ? 1 : 0;
}

/* ---- 菜单树（T235 P6-4）----
 * 字节布局见 adapter.h 的菜单栏段（整数一律小端 i32；字符串 = i32 字节数 + UTF-8，
 * 不带 NUL）。这里把它解析成下面这棵结构，随后由 menus_gtk.inc 译成 GMenuModel。
 *
 * **为什么放在 prelude 而不是 menus_gtk.inc**：解析与格式化都不碰 GTK，假头构建
 * 照样能真跑判据（与 P6-3 那两条 response → 返回码同一考虑）。menus_gtk.inc 要
 * 真 GMenu/GtkPopoverMenuBar，在假头构建里整片被跳过，只在真链接闸里跑。
 *
 * 树是**一次调用的快照**：装完就没人再读它（dump 走原生模型，见 menus_gtk.inc），
 * 所以解析出来用完即释放，不做增量修改。
 */

#define MOONUI_MENU_ITEM 0
#define MOONUI_MENU_SEP 1
#define MOONUI_MENU_SUB 2

#define MOONUI_MENU_MAX_DEPTH 32

typedef struct MoonuiMenuNode MoonuiMenuNode;
struct MoonuiMenuNode {
  int kind;      /* MOONUI_MENU_ITEM / _SEP / _SUB */
  char *label;   /* 可点项与子菜单的文案；分隔线为 NULL */
  int id;        /* 可点项的 Core 编号（原样放进行动名，点击时送回） */
  int role;      /* 0 = Normal 1 = Check 2 = Radio */
  int checked;
  int enabled;
  int has_shortcut;
  int mods;      /* bit0 ctrl bit1 alt bit2 shift bit3 meta */
  char *key;     /* Core 词表的键名（event.mbt）；无组合时 NULL */
  MoonuiMenuNode *children;
  int child_count;
};

typedef struct {
  char *label;
  MoonuiMenuNode *nodes;
  int node_count;
} MoonuiMenu;

typedef struct {
  MoonuiMenu *menus;
  int menu_count;
} MoonuiMenuTree;

/* 解析游标。\`bad\` 一旦立起来，后面每个读口都只返回零值——调用方只在最后看一次，
 * 不在每个字段后写检查（半棵树的状态没有意义，装一半的菜单栏比装不上更难查）。 */
typedef struct {
  const unsigned char *p;
  int len;
  int pos;
  int bad;
} MoonuiMenuCursor;

static int moonui_menu_u8(MoonuiMenuCursor *c) {
  if (c->bad || c->pos >= c->len) {
    c->bad = 1;
    return 0;
  }
  return (int)c->p[c->pos++];
}

static int moonui_menu_i32(MoonuiMenuCursor *c) {
  unsigned v;
  if (c->bad || c->pos + 4 > c->len) {
    c->bad = 1;
    return 0;
  }
  v = (unsigned)c->p[c->pos] | ((unsigned)c->p[c->pos + 1] << 8) |
      ((unsigned)c->p[c->pos + 2] << 16) | ((unsigned)c->p[c->pos + 3] << 24);
  c->pos += 4;
  return (int)v;
}

static char *moonui_menu_str(MoonuiMenuCursor *c) {
  int n = moonui_menu_i32(c);
  char *s;
  if (c->bad || n < 0 || n > c->len - c->pos) {
    c->bad = 1;
    return NULL;
  }
  s = (char *)malloc((size_t)n + 1);
  if (s == NULL) {
    c->bad = 1;
    return NULL;
  }
  if (n > 0) memcpy(s, c->p + c->pos, (size_t)n);
  s[n] = '\\0';
  c->pos += n;
  return s;
}

static void moonui_menu_nodes_free(MoonuiMenuNode *nodes, int count) {
  int i;
  if (nodes == NULL) return;
  for (i = 0; i < count; ++i) {
    free(nodes[i].label);
    free(nodes[i].key);
    moonui_menu_nodes_free(nodes[i].children, nodes[i].child_count);
  }
  free(nodes);
}

static void moonui_menu_tree_free(MoonuiMenuTree *t) {
  int i;
  if (t == NULL) return;
  for (i = 0; i < t->menu_count; ++i) {
    free(t->menus[i].label);
    moonui_menu_nodes_free(t->menus[i].nodes, t->menus[i].node_count);
  }
  free(t->menus);
  memset(t, 0, sizeof(*t));
}

/* 解析 n 个同级节点。递归由 depth 兜底：故意做深的树（或坏输入造成的环状读法）
 * 在这里被拒，而不是把栈打穿。 */
static MoonuiMenuNode *moonui_menu_nodes(MoonuiMenuCursor *c, int n, int depth,
                                         int *out_count) {
  MoonuiMenuNode *nodes;
  int i;
  *out_count = 0;
  if (c->bad || n < 0) {
    c->bad = 1;
    return NULL;
  }
  if (n == 0) return NULL;
  if (depth > MOONUI_MENU_MAX_DEPTH) {
    c->bad = 1;
    return NULL;
  }
  nodes = (MoonuiMenuNode *)calloc((size_t)n, sizeof(MoonuiMenuNode));
  if (nodes == NULL) {
    c->bad = 1;
    return NULL;
  }
  for (i = 0; i < n; ++i) {
    int kind = moonui_menu_u8(c);
    if (c->bad) break;
    nodes[i].kind = kind;
    if (kind == MOONUI_MENU_SEP) {
      continue;
    }
    if (kind == MOONUI_MENU_ITEM) {
      nodes[i].label = moonui_menu_str(c);
      nodes[i].id = moonui_menu_i32(c);
      nodes[i].role = moonui_menu_u8(c);
      nodes[i].checked = moonui_menu_u8(c);
      nodes[i].enabled = moonui_menu_u8(c);
      nodes[i].has_shortcut = moonui_menu_u8(c);
      if (nodes[i].has_shortcut) {
        nodes[i].mods = moonui_menu_u8(c);
        nodes[i].key = moonui_menu_str(c);
      }
    } else if (kind == MOONUI_MENU_SUB) {
      int sub_n;
      nodes[i].label = moonui_menu_str(c);
      sub_n = moonui_menu_i32(c);
      if (c->bad) break;
      nodes[i].children = moonui_menu_nodes(c, sub_n, depth + 1,
                                            &nodes[i].child_count);
      if (c->bad) break;
    } else {
      /* 未知 kind：整棵树作废（adapter.h 的 -1 那一支）。 */
      c->bad = 1;
      break;
    }
  }
  if (c->bad) {
    moonui_menu_nodes_free(nodes, n);
    return NULL;
  }
  *out_count = n;
  return nodes;
}

/* 顶层：version(1) + menu_count(i32) + menu_count × menu。
 * 最短合法树是 5 字节（空的菜单栏 = 把菜单拆掉）。返回 0 / -1。
 * 与 mac 半同一口径：不要求把字节读干净（多出来的尾巴不看）。 */
static int moonui_menu_parse(const char *data, int len, MoonuiMenuTree *out) {
  MoonuiMenuCursor c;
  int version;
  int count;
  int i;
  memset(out, 0, sizeof(*out));
  if (data == NULL || len < 5) return -1;
  c.p = (const unsigned char *)data;
  c.len = len;
  c.pos = 0;
  c.bad = 0;
  version = moonui_menu_u8(&c);
  count = moonui_menu_i32(&c);
  if (c.bad || version != 1 || count < 0 || count > 4096) return -1;
  if (count == 0) return 0;
  out->menus = (MoonuiMenu *)calloc((size_t)count, sizeof(MoonuiMenu));
  if (out->menus == NULL) return -1;
  out->menu_count = count;
  for (i = 0; i < count; ++i) {
    int node_n;
    out->menus[i].label = moonui_menu_str(&c);
    node_n = moonui_menu_i32(&c);
    if (c.bad) {
      moonui_menu_tree_free(out);
      return -1;
    }
    out->menus[i].nodes =
        moonui_menu_nodes(&c, node_n, 1, &out->menus[i].node_count);
    if (c.bad) {
      moonui_menu_tree_free(out);
      return -1;
    }
  }
  return 0;
}

/* ---- dump 的字符串拼接（不用 GString：这一段要在假头构建里也能编）---- */

typedef struct {
  char *p;
  size_t len;
  size_t cap;
} MoonuiMenuText;

static void moonui_menu_text_putn(MoonuiMenuText *t, const char *s, size_t n) {
  if (t->len + n + 1 > t->cap) {
    size_t cap = t->cap == 0 ? 64 : t->cap;
    while (cap < t->len + n + 1) cap *= 2;
    {
      char *p = (char *)realloc(t->p, cap);
      if (p == NULL) return; /* 内存没了：保留已有前缀，判据会红在内容上 */
      t->p = p;
      t->cap = cap;
    }
  }
  if (n > 0) memcpy(t->p + t->len, s, n);
  t->len += n;
  t->p[t->len] = '\\0';
}

static void moonui_menu_text_put(MoonuiMenuText *t, const char *s) {
  if (s != NULL) moonui_menu_text_putn(t, s, strlen(s));
}

static void moonui_menu_text_put_int(MoonuiMenuText *t, int v) {
  char buf[16];
  int i = 0;
  unsigned u;
  if (v < 0) {
    moonui_menu_text_put(t, "-");
    u = (unsigned)(-(v + 1)) + 1u;
  } else {
    u = (unsigned)v;
  }
  do {
    buf[i++] = (char)('0' + (u % 10u));
    u /= 10u;
  } while (u > 0 && i < (int)sizeof(buf));
  while (i > 0) moonui_menu_text_putn(t, &buf[--i], 1);
}

/* 组合这一栏：与 mac / Windows 两份逐字符一致（adapter.h 那段）。
 * 有组合时是"修饰键字母 + 键名"，一个修饰键都没有写 "-"；没有组合写 "."。 */
static void moonui_menu_format_combo(MoonuiMenuText *t, int has_shortcut,
                                     int mods, const char *key) {
  if (!has_shortcut || key == NULL) {
    moonui_menu_text_put(t, ".");
    return;
  }
  if (mods & 1) moonui_menu_text_put(t, "C");
  if (mods & 2) moonui_menu_text_put(t, "A");
  if (mods & 4) moonui_menu_text_put(t, "S");
  if (mods & 8) moonui_menu_text_put(t, "M");
  if (mods == 0) moonui_menu_text_put(t, "-");
  moonui_menu_text_put(t, key);
}

/* 可点项那一段：#<id>:<role><check><enabled>:<label>:<sc>
 * 单独成函数是为了让 menus_gtk.inc 的"走原生模型"那份能逐字复用同一套格式
 * ——判据比对的就是同一个拼法，不给两边写歪的机会。 */
static void moonui_menu_format_item(MoonuiMenuText *t, int id, int role,
                                    int checked, int enabled, const char *label,
                                    int has_shortcut, int mods,
                                    const char *key) {
  moonui_menu_text_put(t, "#");
  moonui_menu_text_put_int(t, id);
  moonui_menu_text_put(t, ":");
  if (role == 1) {
    moonui_menu_text_put(t, checked ? "c+" : "c-");
  } else if (role == 2) {
    moonui_menu_text_put(t, checked ? "r+" : "r-");
  } else {
    moonui_menu_text_put(t, "n.");
  }
  moonui_menu_text_put(t, enabled ? "e" : "d");
  moonui_menu_text_put(t, ":");
  moonui_menu_text_put(t, label != NULL ? label : "");
  moonui_menu_text_put(t, ":");
  moonui_menu_format_combo(t, has_shortcut, mods, key);
}

/* 一棵解析好的树 → adapter.h 约定的那根文本。只给纯逻辑判据用（真后端那份
 * 读的是原生模型，见 menus_gtk.inc），两边的拼法共用上面两个 format 函数。 */
static void moonui_menu_dump_nodes(MoonuiMenuText *t, const MoonuiMenuNode *nodes,
                                   int count) {
  int i;
  for (i = 0; i < count; ++i) {
    const MoonuiMenuNode *n = &nodes[i];
    if (i > 0) moonui_menu_text_put(t, ",");
    if (n->kind == MOONUI_MENU_SEP) {
      moonui_menu_text_put(t, "-");
    } else if (n->kind == MOONUI_MENU_SUB) {
      moonui_menu_text_put(t, "+");
      moonui_menu_text_put(t, n->label != NULL ? n->label : "");
      moonui_menu_text_put(t, "{");
      moonui_menu_dump_nodes(t, n->children, n->child_count);
      moonui_menu_text_put(t, "}");
    } else {
      moonui_menu_format_item(t, n->id, n->role, n->checked, n->enabled,
                              n->label, n->has_shortcut, n->mods, n->key);
    }
  }
}

static void moonui_menu_dump_tree(MoonuiMenuText *t, const MoonuiMenuTree *tree) {
  int i;
  for (i = 0; i < tree->menu_count; ++i) {
    if (i > 0) moonui_menu_text_put(t, ";");
    moonui_menu_text_put(t, tree->menus[i].label != NULL ? tree->menus[i].label
                                                         : "");
    moonui_menu_text_put(t, "{");
    moonui_menu_dump_nodes(t, tree->menus[i].nodes, tree->menus[i].node_count);
    moonui_menu_text_put(t, "}");
  }
}

/* ---- 主题 / 样式的纯逻辑（T235 P6-4b）----
 * 与 P6-3 的 response 映射同一条理由：放 prelude，假头构建里也能真跑
 * （scripts/mock-gtk-selftest.c 第 10 组）。真 GTK 对象那半在 theme_gtk.inc。
 *
 * CSS 口径（2026-11-09 真 GTK4 4.24 探针实测）：
 *   - font-size / border-radius 写 px，小数三位也能吃（14.500px → 14.5px，
 *     Pango 读到 14.5×1024）；pt 与 px 在 Pango 读数上无差别，不绕 pt。
 *   - font-weight 400/500/700 三档都能被 Pango 兑现（mac 半只有两档，Medium
 *     退 Regular——各平台按自己的能力消费，不改契约）。
 *   - 每个 widget 一条 .moonui-w-<hex> 规则，由唯一 CSS class 认领；同一只
 *     provider 重灌 load_from_data 会即时更新，不需要重建 provider。 */

/* permille → "N.mmm"（不引 stdio：生成物只有 string.h / stdlib.h）。 */
static void moonui_menu_text_put_permille(MoonuiMenuText *t, int v) {
  int frac;
  if (v < 0) return;
  moonui_menu_text_put_int(t, v / 1000);
  moonui_menu_text_put(t, ".");
  frac = v % 1000;
  if (frac < 100) moonui_menu_text_put(t, "0");
  if (frac < 10) moonui_menu_text_put(t, "0");
  moonui_menu_text_put_int(t, frac);
}

static int moonui_gtk_style_weight_css(int weight) {
  if (weight == 2) return 700;
  if (weight == 1) return 500;
  return 400; /* 0 = Regular；未知值也按 Regular，不发明第四档 */
}

/* 按 kind 决定消费面（与 mac 半 adapter_native.m 的三处定点豁免同形）：
 *   17 Panel / 1 Button / 14 MenuRow 吃 bg + radius；
 *   0 Label / 1 Button / 14 MenuRow 吃 fg + font + weight。
 * 14 与 Button 同形：MenuRow 是「选中高亮的扁平行」，T115① 在 mac/win 上
 * 就是那块实色铺底。其余 kind 返回 -1（调用方据此"静默忽略、返回 0"）。
 * -1 是"未设置"哨兵：那一项不写进 CSS；state 里保留上次的值，由调用方累积。 */
static int moonui_gtk_style_css(MoonuiMenuText *t, const char *cls, int kind,
                                int64_t bg, int64_t fg, int radius_pm,
                                int font_pm, int weight) {
  int use_bg = (kind == 17 || kind == 1 || kind == 14);
  int use_fg = (kind == 0 || kind == 1 || kind == 14);
  if (t == NULL || cls == NULL || (!use_bg && !use_fg)) return -1;
  moonui_menu_text_put(t, ".");
  moonui_menu_text_put(t, cls);
  moonui_menu_text_put(t, " {\\n");
  if (use_bg && bg >= 0) {
    moonui_menu_text_put(t, "  background-color: rgb(");
    moonui_menu_text_put_int(t, (int)((bg >> 16) & 0xFF));
    moonui_menu_text_put(t, ",");
    moonui_menu_text_put_int(t, (int)((bg >> 8) & 0xFF));
    moonui_menu_text_put(t, ",");
    moonui_menu_text_put_int(t, (int)(bg & 0xFF));
    moonui_menu_text_put(t, ");\\n");
  }
  if (use_bg && radius_pm >= 0) {
    moonui_menu_text_put(t, "  border-radius: ");
    moonui_menu_text_put_permille(t, radius_pm);
    moonui_menu_text_put(t, "px;\\n");
  }
  if (use_fg && fg >= 0) {
    moonui_menu_text_put(t, "  color: rgb(");
    moonui_menu_text_put_int(t, (int)((fg >> 16) & 0xFF));
    moonui_menu_text_put(t, ",");
    moonui_menu_text_put_int(t, (int)((fg >> 8) & 0xFF));
    moonui_menu_text_put(t, ",");
    moonui_menu_text_put_int(t, (int)(fg & 0xFF));
    moonui_menu_text_put(t, ");\\n");
  }
  if (use_fg && font_pm >= 0) {
    moonui_menu_text_put(t, "  font-size: ");
    moonui_menu_text_put_permille(t, font_pm);
    moonui_menu_text_put(t, "px;\\n");
  }
  if (use_fg && weight >= 0) {
    moonui_menu_text_put(t, "  font-weight: ");
    moonui_menu_text_put_int(t, moonui_gtk_style_weight_css(weight));
    moonui_menu_text_put(t, ";\\n");
  }
  moonui_menu_text_put(t, "}\\n");
  return (int)t->len;
}

/* 系统深色的判定（4.6 与 4.20+ 两条读口都覆盖）。
 * scheme 是 gtk-interface-color-scheme 的当前值；dark_value / light_value 是
 * 运行时按 GEnum nick 查出来的枚举值（-1 = 4.6 上没有这个属性）。
 * 口径：新属性明确 DARK → 1、明确 LIGHT → 0（不再看老属性，避免"系统说浅色、
 * 应用偏好说深色"时撒谎）；DEFAULT / UNSUPPORTED / 属性不存在 → 回落到
 * 4.0 起就有的 prefer-dark 与 gtk-theme-name（Adwaita:dark / Adwaita-dark）。
 * 全都读不到一律 0（adapter.h：读不到不是失败，猜错的代价与"没接"相同）。 */
static int moonui_gtk_theme_dark(int scheme, int dark_value, int light_value,
                                 int prefer_dark, const char *theme_name) {
  char lower[128];
  int i;
  if (dark_value >= 0 && scheme == dark_value) return 1;
  if (light_value >= 0 && scheme == light_value) return 0;
  if (prefer_dark) return 1;
  if (theme_name == NULL) return 0;
  for (i = 0; theme_name[i] != '\\0' && i < (int)sizeof(lower) - 1; ++i) {
    char c = theme_name[i];
    lower[i] = (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
  }
  lower[i] = '\\0';
  return strstr(lower, "dark") != NULL ? 1 : 0;
}

/* ---- 无障碍的纯逻辑（T235 P6-4c）----
 * 放 prelude 的同一条理由：假头构建里也能真跑（scripts/mock-gtk-selftest.c
 * 第 11 组）。真 GTK 对象那半在 a11y_gtk.inc。
 *
 * 口径（2026-11-09 真 GTK4 4.24 探针实测）：
 *   - role 是 Core 的 AccessRole 声明序号 0..9；这里只给 GTK 枚举**名字**，
 *     真 GTK 侧按名字查 GEnum 值（4.6 / 4.24 枚举值若增删都不会写错）。
 *   - state 位包 bit0=visible、bit1=enabled、bits2-3=checked。前两位是 GTK
 *     按 widget 活值自己算的（set_sensitive 一调 DISABLED 立刻变），注记快照
 *     会像 T58 的 MSAA 那样撒谎，所以这里**只解 checked**。
 *   - 4.20+ 的 gtk-interface-contrast 是 MORE/LESS/NO_PREFERENCE/UNSUPPORTED
 *     四档；4.6 上属性不存在，回落到 gtk-theme-name / gtk-icon-theme-name
 *     里的 HighContrast 线索。GNOME 的高对比主题叫 HighContrast，不是 "dark"。
 *   - (ptr,len) 是 UTF-8 字节串、不保证 NUL 结尾，也可能内嵌 NUL；按长度复制。
 */

/* role 序号 → GTK 枚举名字（名字是 4.0 就有的，编译期引用常量值反而脆）。 */
static const char *moonui_gtk_a11y_role_name(int role) {
  static const char *const names[] = {
    "GTK_ACCESSIBLE_ROLE_LABEL",         /* 0 Text（静态文本）*/
    "GTK_ACCESSIBLE_ROLE_BUTTON",        /* 1 Button */
    "GTK_ACCESSIBLE_ROLE_CHECKBOX",      /* 2 CheckBox */
    "GTK_ACCESSIBLE_ROLE_TEXT_BOX",      /* 3 TextBox */
    "GTK_ACCESSIBLE_ROLE_GROUP",         /* 4 Group */
    "GTK_ACCESSIBLE_ROLE_LIST",          /* 5 List */
    "GTK_ACCESSIBLE_ROLE_LIST_ITEM",     /* 6 ListItem */
    "GTK_ACCESSIBLE_ROLE_WINDOW",        /* 7 Window */
    "GTK_ACCESSIBLE_ROLE_SLIDER",        /* 8 SliderRole */
    "GTK_ACCESSIBLE_ROLE_PROGRESS_BAR"   /* 9 ProgressRole */
  };
  if (role < 0 || role >= (int)(sizeof(names) / sizeof(names[0]))) return NULL;
  return names[role];
}

/* 只取 bits2-3：0=无此态、1=未勾、2=已勾、3=混合。bit0/bit1 显式不读。 */
static int moonui_gtk_a11y_checked(int state) {
  return (state >> 2) & 3;
}

/* (ptr,len) → NUL 结尾副本；NULL / len<=0 给 NULL（调用方据此 reset 属性）。
 * 不能用 strdup：Core 的 Bytes 是 UTF-8 字节串，不保证以 NUL 结尾。 */
static char *moonui_gtk_a11y_text(const char *p, int len) {
  char *out;
  if (p == NULL || len <= 0) return NULL;
  out = (char *)calloc((size_t)len + 1, 1);
  if (out == NULL) return NULL;
  memcpy(out, p, (size_t)len);
  return out;
}

/* 主题名里有没有高对比线索（大小写归一 + 子串，与 P6-4b 判 dark 同形）。
 * 是启发式：Adwaita-highcontrastish 这类名字也会被算进来，边界记在 TODO。 */
static int moonui_gtk_a11y_hc_name(const char *name) {
  char lower[128];
  int i;
  if (name == NULL) return 0;
  for (i = 0; name[i] != '\\0' && i < (int)sizeof(lower) - 1; ++i) {
    char c = name[i];
    lower[i] = (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
  }
  lower[i] = '\\0';
  return (strstr(lower, "highcontrast") != NULL ||
          strstr(lower, "high-contrast") != NULL) ? 1 : 0;
}

/* 减少动态效果：gtk-enable-animations 的反面。读不到一律 0（偏好关）。 */
static int moonui_gtk_a11y_reduced_motion(int has_prop, int enable_animations) {
  if (!has_prop) return 0;
  return enable_animations ? 0 : 1;
}

/* 高对比读数。more/less/no_pref/unsupported 是运行时按 GEnum 名字查出来的值
 * （-1 = 4.6 上属性不存在）。明确 MORE → 1、明确 LESS → 0（都不看主题名）；
 * NO_PREFERENCE / UNSUPPORTED / 属性不存在 → 回落主题名；未来冒出的未知枚举
 * 不乱猜，按没开。 */
static int moonui_gtk_a11y_high_contrast(int contrast, int more, int less,
                                          int no_pref, int unsupported,
                                          const char *theme,
                                          const char *icon_theme) {
  if (more >= 0 && contrast == more) return 1;
  if (less >= 0 && contrast == less) return 0;
  if (more >= 0 && contrast >= 0 &&
      contrast != no_pref && contrast != unsupported) return 0;
  return (moonui_gtk_a11y_hc_name(theme) ||
          moonui_gtk_a11y_hc_name(icon_theme)) ? 1 : 0;
}

/* ---- 控件叶子 / 焦点链 / 自绘面点击的纯逻辑（T235 P6-5 + P6-5b）----
 * 放 prelude 的同一条理由：不碰 GTK，假头构建也能真跑（scripts/
 * mock-gtk-selftest.c 第 12、13 组）。真 GTK 对象那半在 leaves_gtk.inc /
 * focus_gtk.inc / scroll_gtk.inc。
 *
 * 这里是**唯一**一张 kind 到构造形态的映射：widget_new 与文案/勾选/回调那几条
 * 都从它派生，不在 .inc 里再写一遍 kind 列表。P6-4b 那次负控制全绿的成因就是
 * "两处各写一遍护栏，只拆一处是等价变换"，别再踩。
 *
 * kind 编码来自 adapter.h 控件段与 native-abi/native_abi.mbt 的 kind_code：
 * 0 Label / 1 Button / 2 TextInput / 3 Checkbox / 4 PasswordInput /
 * 5 Separator / 13 VSeparator / 14 MenuRow / 15 Scroll / 16 Image /
 * 17 Panel / 18 Custom / 19 WebView；6..12 走专属构造入口，不进这张表。
 * P6-5b 起 14（GtkToggleButton）与 15（GtkScrolledWindow + GtkViewport +
 * GtkFixed 文档区）落地；19 WebView 仍**如实缺席**——GTK4 本体没有 WebView，
 * WebKitGTK 是另一份依赖，不在这套 4.6 sysroot 里，造空壳冒充控件会让 Core
 * 以为建成了（与中性桩 return 0 那种谎报同款）。6..12 七个专属构造族同理
 * 另起一片（P6-5c）：探针已证 4.6 上七个原生对象都在，但每族自带
 * 属性/回调/探针，是 25 条 ABI 的独立一整片。
 */
#define MOONUI_LEAF_NONE     0
#define MOONUI_LEAF_LABEL    1
#define MOONUI_LEAF_BUTTON   2
#define MOONUI_LEAF_ENTRY    3
#define MOONUI_LEAF_PASSWORD 4
#define MOONUI_LEAF_CHECK    5
#define MOONUI_LEAF_SEP_H    6
#define MOONUI_LEAF_SEP_V    7
#define MOONUI_LEAF_IMAGE    8
#define MOONUI_LEAF_PANEL    9
#define MOONUI_LEAF_CUSTOM  10
#define MOONUI_LEAF_MENUROW 11
#define MOONUI_LEAF_SCROLL  12
#define MOONUI_LEAF_TEXTVIEW 13

static int moonui_gtk_leaf_of_kind(int kind) {
  switch (kind) {
    case 0:  return MOONUI_LEAF_LABEL;
    case 1:  return MOONUI_LEAF_BUTTON;
    case 2:  return MOONUI_LEAF_ENTRY;
    case 3:  return MOONUI_LEAF_CHECK;
    case 4:  return MOONUI_LEAF_PASSWORD;
    case 5:  return MOONUI_LEAF_SEP_H;
    case 13: return MOONUI_LEAF_SEP_V;
    case 14: return MOONUI_LEAF_MENUROW;
    case 15: return MOONUI_LEAF_SCROLL;
    case 16: return MOONUI_LEAF_IMAGE;
    case 17: return MOONUI_LEAF_PANEL;
    case 18: return MOONUI_LEAF_CUSTOM;
    case 10: return MOONUI_LEAF_TEXTVIEW; /* P6-5c 多行文本 */
    default: return MOONUI_LEAF_NONE; /* 19 WebView 如实缺席 */
  }
}

/* 文案落到 GTK 的哪一类 API。这一层不碰 GTK 类型，纯粹是分派号。
 * 14 归 BUTTON：真 GTK4 探针实测 GTK_IS_BUTTON(GtkToggleButton)=1，
 * gtk_button_set_label 在它身上照常生效。 */
#define MOONUI_LEAF_TEXT_NONE     0
#define MOONUI_LEAF_TEXT_LABEL    1
#define MOONUI_LEAF_TEXT_BUTTON   2
#define MOONUI_LEAF_TEXT_CHECK    3
#define MOONUI_LEAF_TEXT_EDITABLE 4
#define MOONUI_LEAF_TEXT_VIEW     5
static int moonui_gtk_leaf_text_channel(int leaf) {
  switch (leaf) {
    case MOONUI_LEAF_LABEL:    return MOONUI_LEAF_TEXT_LABEL;
    case MOONUI_LEAF_BUTTON:
    case MOONUI_LEAF_MENUROW:  return MOONUI_LEAF_TEXT_BUTTON;
    case MOONUI_LEAF_CHECK:    return MOONUI_LEAF_TEXT_CHECK;
    case MOONUI_LEAF_ENTRY:
    case MOONUI_LEAF_PASSWORD: return MOONUI_LEAF_TEXT_EDITABLE;
    case MOONUI_LEAF_TEXTVIEW:  return MOONUI_LEAF_TEXT_VIEW;
    default:                   return MOONUI_LEAF_TEXT_NONE;
  }
}

/* 勾选态落到 GTK 的哪一类 API。GtkCheckButton 与 GtkToggleButton **不是**
 * 同一族（探针实测 GTK_IS_BUTTON(GtkCheckButton)=0），不能共用一个宏；
 * 这一层同样只是分派号。 */
#define MOONUI_LEAF_ACTIVE_NONE   0
#define MOONUI_LEAF_ACTIVE_CHECK  1
#define MOONUI_LEAF_ACTIVE_TOGGLE 2
static int moonui_gtk_leaf_active_channel(int leaf) {
  switch (leaf) {
    case MOONUI_LEAF_CHECK:   return MOONUI_LEAF_ACTIVE_CHECK;
    case MOONUI_LEAF_MENUROW: return MOONUI_LEAF_ACTIVE_TOGGLE;
    default:                  return MOONUI_LEAF_ACTIVE_NONE;
  }
}

/* 判据对拍用：名字是写死的期望值，不与实现共用一张表。 */
static const char *moonui_gtk_leaf_name(int leaf) {
  static const char *const names[] = {
    "NONE", "LABEL", "BUTTON", "ENTRY", "PASSWORD",
    "CHECK", "SEP_H", "SEP_V", "IMAGE", "PANEL", "CUSTOM",
    "MENUROW", "SCROLL", "TEXTVIEW"
  };
  if (leaf < 0 || leaf >= (int)(sizeof(names) / sizeof(names[0]))) return NULL;
  return names[leaf];
}

/* (ptr,len) 到 NUL 结尾副本。Core 的 Bytes 不保证 NUL 结尾，也可能内嵌 NUL；
 * 文本通道里空串/NULL/负长度是"清空"，不是"保留旧值"（与 a11y 那条给 NULL
 * 表示 reset 不同，两条语义分开写，别复用错了）。 */
static char *moonui_gtk_leaf_dup_text(const char *p, int len) {
  char *out;
  if (p == NULL || len <= 0) return (char *)calloc(1, 1);
  out = (char *)calloc((size_t)len + 1, 1);
  if (out == NULL) return NULL;
  memcpy(out, p, (size_t)len);
  return out;
}

/* ---- P6-5c 纯逻辑：日期文本 "YYYY-MM-DD HH:MM:SS" 解析 ----
 * (ptr,len) 不保证 NUL 结尾。返回 1 = 解析成功且各字段在合理范围，
 * 0 = 格式不符 / 字段越界 / 有多余字符。手动扫十进制（不碰 sscanf / strtoull，
 * 同 focus_parse 的取舍），并强制 i==len 杜绝尾部垃圾。时间组件单独校验是因为
 * GTK 的 GtkCalendar 只认日期、会丢掉时间（实现侧靠 date_cache 缓存原文往返），
 * 但解析本身是纯逻辑、可脱离 GTK 真跑（mock 第 14 组逐字钉死）。 */
static int moonui_gtk_parse_datetime(const char *p, int len, int *Y, int *M,
                                      int *D, int *h, int *mi, int *sd) {
  int i = 0;
  if (p == NULL || len < 19 || len > 31) return 0; /* 最短 19 字符 */
#define MOONUI_RD_DT(F) do { \
    unsigned long long v = 0; int d = 0; \
    if (i >= len || p[i] < '0' || p[i] > '9') return 0; \
    while (i < len && p[i] >= '0' && p[i] <= '9') { \
      v = v * 10ULL + (unsigned long long)(p[i] - '0'); d++; i++; \
      if (v > 99999ULL) return 0; \
    } \
    if (d == 0) return 0; \
    *(F) = (int)v; \
  } while (0)
  MOONUI_RD_DT(Y);
  if (i >= len || p[i++] != '-') return 0;
  MOONUI_RD_DT(M);
  if (i >= len || p[i++] != '-') return 0;
  MOONUI_RD_DT(D);
  if (i >= len || p[i++] != ' ') return 0;
  MOONUI_RD_DT(h);
  if (i >= len || p[i++] != ':') return 0;
  MOONUI_RD_DT(mi);
  if (i >= len || p[i++] != ':') return 0;
  MOONUI_RD_DT(sd);
  if (i != len) return 0; /* 不能有多余字符 */
#undef MOONUI_RD_DT
  if (*Y < 1 || *Y > 9999) return 0;
  if (*M < 1 || *M > 12) return 0;
  if (*D < 1 || *D > 31) return 0;
  if (*h < 0 || *h > 23) return 0;
  if (*mi < 0 || *mi > 59) return 0;
  if (*sd < 0 || *sd > 59) return 0;
  return 1;
}

/* ---- P6-5b 纯逻辑之一：焦点链文本 ----
 * ids 是「空格分隔的十进制 owner 指针」，(ptr,len) 不保证 NUL 结尾。
 * 返回条数（0 = 空链，清空），-3 = 文本解析失败（非数字 / 负号 / 溢出 /
 * 超过容量）。按长度扫、不碰 strtoull，免得 locale 与 NUL 结尾的假设混进来。 */
#define MOONUI_FOCUS_CHAIN_MAX 64
static int moonui_gtk_focus_parse(const char *s, int len, moonui_ptr *out,
                                  int cap) {
  int i = 0, n = 0;
  if (len < 0) return -3;
  if (s == NULL || len == 0) return 0;
  while (i < len) {
    unsigned long long v = 0;
    int digits = 0;
    while (i < len && s[i] == ' ') i++;
    if (i >= len) break;
    while (i < len && s[i] >= '0' && s[i] <= '9') {
      int d = s[i] - '0';
      if (v > ((unsigned long long)(~(moonui_ptr)0) - (unsigned long long)d) /
                  10ULL) return -3;
      v = v * 10ULL + (unsigned long long)d;
      digits++;
      i++;
    }
    if (digits == 0) return -3;
    if (i < len && s[i] != ' ') return -3;
    if (n >= cap) return -3;
    out[n++] = (moonui_ptr)v;
  }
  return n;
}

/* 纯逻辑之二：链里的下一跳。cur = 当前焦点在链里的下标（-1 = 焦点不在链上）。
 * 尾回链头、Shift 反向；没有链返回 -1（交回 GTK 自己的 z 序）。 */
static int moonui_gtk_focus_next_index(int len, int cur, int backward) {
  if (len <= 0) return -1;
  if (cur < 0 || cur >= len) return backward ? len - 1 : 0;
  return backward ? (cur - 1 + len) % len : (cur + 1) % len;
}

/* 纯逻辑之三：自绘面「按下并原地抬起」。slop 与 mac/Win 的判定同一口径
 * （拖出去松手不算、多击不算、没按下过的 released 不算）。pressed 记下
 * 起点，released 返回「要不要派发回调」，两种相位都只碰登记表。 */
#define MOONUI_CUSTOM_CLICK_SLOP 4.0
static int moonui_gtk_custom_click_edge(MoonuiWidgetSlot *s, int n_press,
                                        double x, double y, int release) {
  double dx, dy;
  if (s == NULL) return 0;
  if (!release) {
    if (n_press != 1) {
      s->custom_press_armed = 0;
      return 0;
    }
    s->custom_press_x = x;
    s->custom_press_y = y;
    s->custom_press_armed = 1;
    return 0;
  }
  if (!s->custom_press_armed || n_press != 1) {
    s->custom_press_armed = 0;
    return 0;
  }
  s->custom_press_armed = 0;
  dx = x - s->custom_press_x;
  if (dx < 0) dx = -dx;
  dy = y - s->custom_press_y;
  if (dy < 0) dy = -dy;
  return (dx <= MOONUI_CUSTOM_CLICK_SLOP &&
          dy <= MOONUI_CUSTOM_CLICK_SLOP) ? 1 : 0;
}

/* 焦点落点反查：真 GTK4 探针实测 gtk_window_get_focus 对 GtkEntry 返回内部
 * GtkText，沿父链才找得到 Entry；Button / ToggleButton 则直接返回自己。
 * 与 P6-1 的 moonui_owner_at 是同一课，只是这里从焦点而不是 pick 出发。 */
static moonui_ptr moonui_focus_owner_of(GtkWidget *w) {
  while (w != NULL) {
    if (moonui_widget_kind_of(w) >= 0) return (moonui_ptr)(uintptr_t)w;
    w = gtk_widget_get_parent(w);
  }
  return 0;
}

/* Tab 按链推进（定义在这里是因为要用上面那些纯逻辑 + 两张登记表）。
 * 返回 1 = 我们接管了这颗 Tab，key-pressed 因此返回 TRUE 吞掉 GTK 默认遍历；
 * 0 = 没有链或链里没有活控件，交回 GTK 自己的 z 序。
 * 非 static 只为让 canvas-pixel 真跑判据能 extern 到它（prelude 不参与
 * 生成器的 ABI 名字扫描，这不是一条 adapter.h ABI）。 */
int moonui_gtk_focus_tab_step(GtkWidget *win, int backward) {
  MoonuiWinSlot *ws = moonui_win_slot_of(win);
  GtkWidget *target;
  moonui_ptr owner;
  int cur = -1, i, next;
  if (ws == NULL || ws->focus_chain_len <= 0) return 0;
  owner = moonui_focus_owner_of(gtk_window_get_focus(GTK_WINDOW(win)));
  for (i = 0; i < ws->focus_chain_len; ++i) {
    if (ws->focus_chain[i] == owner) {
      cur = i;
      break;
    }
  }
  next = moonui_gtk_focus_next_index(ws->focus_chain_len, cur, backward);
  if (next < 0) return 0;
  target = (GtkWidget *)(uintptr_t)ws->focus_chain[next];
  if (moonui_wslot_of(target) == NULL)
    return 0; /* 链里是已销毁/不认识的 owner：不把野指针喂给 GTK */
  gtk_widget_grab_focus(target);
  return 1;
}

/* 真跑判据要拿到自绘面上那只手势控制器（canvas-pixel selftest 与生成物是
 * 两个翻译单元，static 拿不到）。同样不是 adapter.h 的 ABI。 */
void *moonui_gtk_probe_gesture_of(GtkWidget *w) {
  MoonuiWidgetSlot *s = moonui_wslot_of(w);
  return s == NULL ? NULL : s->custom_gesture;
}

/* ===================== 以下为 P3 真实函数体（由 REAL 字典注入） ===================== */
`;

const REAL = new Map();
REAL.set("moonui_native_init", `int moonui_native_init(void) {
  if (moonui_inited) return 0;
  moonui_last_error_buf[0] = '\\0';
  moonui_quit_flag = FALSE;
  /* gtk_init_check 而不是 gtk_init：后者打不开显示器直接 abort，CI 上那种
   * 失败只会留下一句 "cannot open display" 就没了；前者让我们把原因带回
   * MoonBit（moonui_native_last_error），失败也是一条可读的账。 */
  if (!gtk_init_check()) {
    strncpy(moonui_last_error_buf, "GTK4 初始化失败：打不开显示器（DISPLAY/WAYLAND_DISPLAY 没设？）",
            sizeof(moonui_last_error_buf) - 1);
    return -1;
  }
  moonui_inited = TRUE;
  return 0;
}`);
REAL.set("moonui_native_last_error", `moonbit_bytes_t moonui_native_last_error(void) {
  return moonui_bytes_of(moonui_last_error_buf);
}`);
REAL.set("moonui_native_terminate", `void moonui_native_terminate(void) {
  int i;
  /* 收尾：把还挂着的窗口拆掉、所有闭包松掉、状态归零。前提是 Core 已经把
   * 控件和窗口销毁干净（adapter.h 的 terminate 契约），这里对残留窗口做的是
   * 兜底——不拆的话下一次 init 的窗口表会带着上一轮的指针。 */
  for (i = 0; i < MOONUI_WIN_SLOTS; ++i) {
    MoonuiWinSlot *s = &moonui_wins[i];
    if (s->win != NULL) {
      gtk_window_destroy(GTK_WINDOW(s->win));
    }
    if (s->closing_cl) moonbit_decref(s->closing_cl);
    if (s->resized_cl) moonbit_decref(s->resized_cl);
    if (s->moved_cl) moonbit_decref(s->moved_cl);
    memset(s, 0, sizeof(MoonuiWinSlot));
  }
  if (moonui_key_closure) { moonbit_decref(moonui_key_closure); moonui_key_closure = 0; }
  if (moonui_mouse_closure) { moonbit_decref(moonui_mouse_closure); moonui_mouse_closure = 0; }
  if (moonui_gesture_closure) { moonbit_decref(moonui_gesture_closure); moonui_gesture_closure = 0; }
  moonui_key_fn = 0;
  moonui_mouse_fn = 0;
  moonui_gesture_fn = 0;
  moonui_key_target_ptr = 0;
  moonui_mouse_target_ptr = 0;
  moonui_mouse_owner_ptr = 0;
  moonui_gesture_target_ptr = 0;
  moonui_key_name_buf[0] = '\\0';
  moonui_quit_flag = FALSE;
  moonui_inited = FALSE;
}`);
REAL.set("moonui_native_time_ms", `int64_t moonui_native_time_ms(void) {
  /* 单调时钟（glib 的 monotonic 就是 mac 那侧 mach_absolute_time 的对位物），
   * 单位毫秒。动画/计时全部吃这条，返回 0 会让每一帧都是"时间没走"。 */
  return (int64_t)(g_get_monotonic_time() / 1000);
}`);
REAL.set("moonui_native_window_new", `moonui_ptr moonui_native_window_new(const char *title, int title_len, int width, int height) {
  GtkWidget *win;
  MoonuiWinSlot *slot;
  char *t;
  int scale = moonui_scale_of(NULL);
  int wpt = (int)llround((double)width / scale);
  int hpt = (int)llround((double)height / scale);
  t = moonui_dup(title, title_len);
  win = gtk_window_new();
  gtk_window_set_title(GTK_WINDOW(win), t ? t : "");
  gtk_window_set_default_size(GTK_WINDOW(win), wpt, hpt);
  if (t) free(t);
  slot = moonui_win_slot_alloc(win);
  if (slot == NULL) {
    gtk_window_destroy(GTK_WINDOW(win));
    return 0;
  }
  g_signal_connect(win, "close-request", G_CALLBACK(moonui_on_close_request), NULL);
  /* GTK 自己把窗口销毁时（不是走 Core 的 window_destroy）也要把登记表清干净，
   * 否则槽位里留着一个已释放的指针（\`T110\` 那条老课）。 */
  g_signal_connect(win, "destroy", G_CALLBACK(moonui_gtk_on_window_destroy), NULL);
  /* 菜单栏是应用级的：装过菜单之后新建的窗口也要补上（T235 P6-4）。没装过菜单
   * 时这个钩子是 NULL，这一句是空操作。 */
  if (moonui_gtk_menu_attach_hook != NULL) moonui_gtk_menu_attach_hook(win);
  {
    GtkEventController *kc = gtk_event_controller_key_new();
    gtk_widget_add_controller(win, kc);
    g_signal_connect(kc, "key-pressed", G_CALLBACK(moonui_key_pressed), NULL);
    g_signal_connect(kc, "key-released", G_CALLBACK(moonui_key_released), NULL);
  }
  {
    GtkEventController *mc = gtk_event_controller_motion_new();
    gtk_widget_add_controller(win, mc);
    g_signal_connect(mc, "motion", G_CALLBACK(moonui_motion), NULL);
    g_signal_connect(mc, "leave", G_CALLBACK(moonui_motion_leave), NULL);
  }
  {
    GtkGesture *gc = gtk_gesture_click_new();
    gtk_widget_add_controller(win, GTK_EVENT_CONTROLLER(gc));
    g_signal_connect(gc, "pressed", G_CALLBACK(moonui_click_pressed), NULL);
    g_signal_connect(gc, "released", G_CALLBACK(moonui_click_released), NULL);
  }
  {
    GtkEventController *sc = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    gtk_widget_add_controller(win, sc);
    g_signal_connect(sc, "scroll", G_CALLBACK(moonui_scroll), NULL);
  }
  {
    GtkGesture *zc = gtk_gesture_zoom_new();
    gtk_widget_add_controller(win, GTK_EVENT_CONTROLLER(zc));
    g_signal_connect(zc, "begin", G_CALLBACK(moonui_gesture_zoom_begin), slot);
    g_signal_connect(zc, "scale-changed", G_CALLBACK(moonui_gesture_zoom_scale), slot);
    g_signal_connect(zc, "end", G_CALLBACK(moonui_gesture_zoom_end), slot);
  }
  {
    GtkGesture *rc = gtk_gesture_rotate_new();
    gtk_widget_add_controller(win, GTK_EVENT_CONTROLLER(rc));
    g_signal_connect(rc, "begin", G_CALLBACK(moonui_gesture_rotate_begin), slot);
    g_signal_connect(rc, "angle-changed", G_CALLBACK(moonui_gesture_rotate_angle), slot);
    g_signal_connect(rc, "end", G_CALLBACK(moonui_gesture_rotate_end), slot);
  }
  {
    GtkGesture *sw = gtk_gesture_swipe_new();
    gtk_widget_add_controller(win, GTK_EVENT_CONTROLLER(sw));
    g_signal_connect(sw, "swipe", G_CALLBACK(moonui_gesture_swipe), slot);
  }
  (void)slot;
  return (moonui_ptr)(uintptr_t)win;
}`);
REAL.set("moonui_native_window_show", `void moonui_native_window_show(moonui_ptr w) {
  gtk_window_present(GTK_WINDOW((GtkWidget *)(uintptr_t)w));
}`);
REAL.set("moonui_native_window_hide", `void moonui_native_window_hide(moonui_ptr w) {
  /* gtk_widget_hide 自 4.10 弃用（真头下 -Wall 报 deprecated），
   * set_visible(FALSE) 语义相同。 */
  gtk_widget_set_visible((GtkWidget *)(uintptr_t)w, FALSE);
}`);
REAL.set("moonui_native_window_destroy", `void moonui_native_window_destroy(moonui_ptr w) {
  GtkWidget *win = (GtkWidget *)(uintptr_t)w;
  MoonuiWinSlot *slot = moonui_win_slot_of(win);
  if (slot) {
    /* 菜单栏那份引用是我们自持的（换菜单时要活过 gtk_box_remove），窗口没了
     * 就放掉；控件树本身由 gtk_window_destroy 拆。 */
    moonui_gtk_window_release_menu(win);
    if (slot->closing_cl) moonbit_decref(slot->closing_cl);
    if (slot->resized_cl) moonbit_decref(slot->resized_cl);
    if (slot->moved_cl)   moonbit_decref(slot->moved_cl);
    memset(slot, 0, sizeof(MoonuiWinSlot));
  }
  if (win) gtk_window_destroy(GTK_WINDOW(win));
}`);
REAL.set("moonui_native_window_set_title", `void moonui_native_window_set_title(moonui_ptr w, const char *title, int title_len) {
  char *t = moonui_dup(title, title_len);
  gtk_window_set_title(GTK_WINDOW((GtkWidget *)(uintptr_t)w), t ? t : "");
  if (t) free(t);
}`);
REAL.set("moonui_native_window_set_content_size", `void moonui_native_window_set_content_size(moonui_ptr w, int width, int height) {
  GtkWidget *win = (GtkWidget *)(uintptr_t)w;
  MoonuiWinSlot *slot = moonui_win_slot_of(win);
  int scale = moonui_scale_of(win);
  int wpt = (int)llround((double)width / scale);
  int hpt = (int)llround((double)height / scale);
  /* **GTK4 删掉了 gtk_window_resize**（GTK3 才有；真头下报 undeclared）。
   * 拆成两条：default_size 管"还没上屏时的请求值"，size_request 管"已上屏后
   * 真把窗口撑到这么大"。两个都设是因为 Core 两个阶段都会调过来（先摆尺寸再
   * show、以及 show 之后改），只设任一条都会有一边不生效。 */
  /* 装了菜单栏的窗口，Core 要的是**客户区**这个尺寸，而窗口尺寸还得加上菜单栏
   * 那一行——与 Win32 半"SetMenu 之后客户区矮一行"同一个问题，只是这边补在
   * 请求值上（GTK 没有事后改外框的入口，只能一开始就把这一行算进去）。 */
  hpt += moonui_gtk_menubar_height(win);
  gtk_window_set_default_size(GTK_WINDOW(win), wpt, hpt);
  gtk_widget_set_size_request(win, wpt, hpt);
  /* 这是 Core 自己发起的改尺寸：下一圈轮询看到的那一次变化按基准吞掉，不回声
   * 成一条 Resize（adapter.h 的 on_resized 契约）。 */
  if (slot != NULL) slot->suppress_resize = 1;
}`);
REAL.set("moonui_native_window_content_size", `int64_t moonui_native_window_content_size(moonui_ptr w) {
  GtkWidget *win = (GtkWidget *)(uintptr_t)w;
  MoonuiWinSlot *slot = moonui_win_slot_of(win);
  int scale = moonui_scale_of(win);
  int width = 0, height = 0;
  /* 上了屏就用真实客户区尺寸（与核心布局看到的一致），没上屏退回 default-size
   * ——后者是请求值，可能还没被窗口管理器兑现。
   *
   * 装了菜单栏时客户区是**菜单栏下面那块**（overlay），不是整窗：画布与控件都
   * 摆在 overlay 里，回报整窗高度会让 Core 以为下面还有空间。overlay 还没排版
   * （上屏前）就按请求值减掉菜单栏那一行，两边因此是同一个口径。 */
  if (win != NULL) {
    if (slot != NULL && slot->menubar != NULL && slot->overlay != NULL) {
      width = gtk_widget_get_width(slot->overlay);
      height = gtk_widget_get_height(slot->overlay);
      if (width > 0 && height > 0) {
        return moonui_pack2((int)llround(width * scale),
                            (int)llround(height * scale));
      }
    }
    width = gtk_widget_get_width(win);
    height = gtk_widget_get_height(win);
  }
  if (width <= 0 || height <= 0) {
    gtk_window_get_default_size(GTK_WINDOW(win), &width, &height);
    if (slot != NULL && slot->menubar != NULL) {
      height -= moonui_gtk_menubar_height(win);
      if (height < 0) height = 0;
    }
  }
  return moonui_pack2((int)llround(width * scale), (int)llround(height * scale));
}`);
REAL.set("moonui_native_window_on_closing", `int moonui_native_window_on_closing(moonui_ptr w, moonui_closure_fn fn, void *closure) {
  MoonuiWinSlot *s = moonui_win_slot_of((GtkWidget *)(uintptr_t)w);
  if (!s) return -1;
  moonui_closure_replace(&s->closing_fn, &s->closing_cl, fn, closure);
  return 0;
}`);
REAL.set("moonui_native_window_on_resized", `int moonui_native_window_on_resized(moonui_ptr w, moonui_closure_fn fn, void *closure) {
  MoonuiWinSlot *s = moonui_win_slot_of((GtkWidget *)(uintptr_t)w);
  if (!s) return -1;
  moonui_closure_replace(&s->resized_fn, &s->resized_cl, fn, closure);
  return 0;
}`);
REAL.set("moonui_native_window_on_moved", `int moonui_native_window_on_moved(moonui_ptr w, moonui_closure_fn fn, void *closure) {
  MoonuiWinSlot *s = moonui_win_slot_of((GtkWidget *)(uintptr_t)w);
  if (!s) return -1;
  /* GTK4 / Wayland 下客户端读不到自己窗口的位置，这条回调**装得上但永不触发**
   * （见本函数上方的说明）。装而不报不是撒谎：Core 摆位只靠自己的账本，位置
   * 读数（moonui_native_window_position）同样是 stub。 */
  moonui_closure_replace(&s->moved_fn, &s->moved_cl, fn, closure);
  return 0;
}`);
REAL.set("moonui_native_system_dpi", `int moonui_native_system_dpi(void) {
  return 96 * moonui_scale_of(NULL);
}`);
REAL.set("moonui_native_window_dpi", `int moonui_native_window_dpi(moonui_ptr w) {
  return 96 * moonui_scale_of((GtkWidget *)(uintptr_t)w);
}`);
REAL.set("moonui_native_on_key", `int moonui_native_on_key(moonui_closure_fn fn, void *closure) {
  moonui_closure_replace(&moonui_key_fn, &moonui_key_closure, fn, closure);
  return 0;
}`);
REAL.set("moonui_native_key_target", `moonui_ptr moonui_native_key_target(void) { return moonui_key_target_ptr; }`);
REAL.set("moonui_native_key_is_down", `int moonui_native_key_is_down(void) { return moonui_key_down; }`);
REAL.set("moonui_native_key_modifiers", `int moonui_native_key_modifiers(void) { return moonui_key_mods; }`);
REAL.set("moonui_native_key_name", `moonbit_bytes_t moonui_native_key_name(void) { return moonui_bytes_of(moonui_key_name_buf); }`);
REAL.set("moonui_native_on_mouse", `int moonui_native_on_mouse(moonui_closure_fn fn, void *closure) {
  moonui_closure_replace(&moonui_mouse_fn, &moonui_mouse_closure, fn, closure);
  return 0;
}`);
REAL.set("moonui_native_mouse_target", `moonui_ptr moonui_native_mouse_target(void) { return moonui_mouse_target_ptr; }`);
REAL.set("moonui_native_mouse_kind_button", `int moonui_native_mouse_kind_button(void) { return moonui_mouse_code; }`);
REAL.set("moonui_native_mouse_mods", `int moonui_native_mouse_mods(void) { return moonui_mouse_mods_val; }`);
REAL.set("moonui_native_mouse_pos", `int64_t moonui_native_mouse_pos(void) { return moonui_pack2(moonui_mouse_px, moonui_mouse_py); }`);
REAL.set("moonui_native_mouse_delta", `int64_t moonui_native_mouse_delta(void) { return moonui_pack2(moonui_mouse_ldx, moonui_mouse_ldy); }`);
REAL.set("moonui_native_on_gesture", `int moonui_native_on_gesture(moonui_closure_fn fn, void *closure) {
  moonui_closure_replace(&moonui_gesture_fn, &moonui_gesture_closure, fn, closure);
  return 0;
}`);
REAL.set("moonui_native_gesture_target", `moonui_ptr moonui_native_gesture_target(void) { return moonui_gesture_target_ptr; }`);
REAL.set("moonui_native_gesture_kind", `int moonui_native_gesture_kind(void) { return moonui_gesture_kind; }`);
REAL.set("moonui_native_gesture_phase", `int moonui_native_gesture_phase(void) { return moonui_gesture_phase; }`);
REAL.set("moonui_native_gesture_direction", `int moonui_native_gesture_direction(void) { return moonui_gesture_dir; }`);
REAL.set("moonui_native_gesture_value", `int64_t moonui_native_gesture_value(void) { return moonui_gesture_value; }`);
REAL.set("moonui_native_main_steps", `void moonui_native_main_steps(void) {
  /* GTK4 无需 finishLaunching 类比；gtk_init 已在 init 完成。 */
}`);
REAL.set("moonui_native_main_step", `int moonui_native_main_step(int wait) {
  (void)wait;
  if (moonui_quit_flag) return 0;
  g_main_context_iteration(NULL, FALSE);
  /* 尺寸变化是轮询出来的（见 moonui_poll_geometry），所以每泵一圈都要量一次；
   * 放在 iteration 之后，这一圈刚被窗口管理器改过的尺寸当圈就能报出去。 */
  moonui_poll_geometry();
  return 1;
}`);
REAL.set("moonui_native_messages_pending", `int moonui_native_messages_pending(void) {
  return g_main_context_pending(NULL) ? 1 : 0;
}`);
REAL.set("moonui_native_wait_messages", `/* 有界睡眠 + 顺带泵消息：MoonBit 侧（native-common/backend.mbt）把这条**只当
 * 有界睡眠用**，返回值不参与判断（\`let _ = native_wait_messages(...)\`），
 * 所以这里返回"睡完还有没有活"只是尽量接近 mac 那侧的语义。用
 * g_main_context_iteration 而不是阻塞式等待，是因为要跟着 ms 到点就走。 */
int moonui_native_wait_messages(int ms) {
  gint64 deadline;
  if (g_main_context_pending(NULL)) return 1;
  deadline = g_get_monotonic_time() + (gint64)ms * 1000;
  do {
    g_main_context_iteration(NULL, FALSE);
    if (g_main_context_pending(NULL)) return 1;
    g_usleep(2000);
  } while (g_get_monotonic_time() < deadline);
  return g_main_context_pending(NULL) ? 1 : 0;
}`);
REAL.set("moonui_native_quit", `void moonui_native_quit(void) { moonui_quit_flag = TRUE; }`);
REAL.set("moonui_native_quit_requested", `int moonui_native_quit_requested(void) { return moonui_quit_flag; }`);

/* ---- 渲染后端选择（T235 P6-7，纯逻辑、零 GTK）----
 * 名字表与 mac 半逐字同构：`metal`→Metal、`cg`/`coregraphics`→CoreGraphics、
 * NULL/未知→Auto。Linux 上**生效后端恒 Auto**（只有 cairo/pixman 一种光栅
 * 后端，没有 CG/Metal 二选一，也没有 Metal 可用性回退）。名字表仍要实现，
 * 因为 pref_code_at 要用它把「偏好文件里存的名字」读成原始码——那是给测试
 * 看的账，不是生效后端的谎报。 */
REAL.set("moonui_render_backend_parse", `MoonuiRenderBackend moonui_render_backend_parse(const char *s) {
  if (s == NULL) {
    return MOONUI_RENDER_AUTO;
  }
  if (strncmp(s, "metal", 5) == 0) {
    return MOONUI_RENDER_METAL;
  }
  if (strncmp(s, "cg", 2) == 0) {
    return MOONUI_RENDER_COREGRAPHICS;
  }
  if (strncmp(s, "coregraphics", 12) == 0) {
    return MOONUI_RENDER_COREGRAPHICS;
  }
  return MOONUI_RENDER_AUTO; /* auto / 未知 → Auto */
}`);
REAL.set("moonui_render_backend_resolve", `MoonuiRenderBackend moonui_render_backend_resolve(void) {
  /* Linux 只有 cairo/pixman 一种光栅后端，没有 CoreGraphics / Metal 的选择，
   * 所以生效后端恒为 Auto（Core 侧 render_backend_of_code(0) → Auto）。
   * env \`MOONUI_RENDER_BACKEND\` 与偏好文件在 Linux 上不改变绘制路径——写了
   * \`metal\` 也不会生效；偏好文件仍可读写，只是不影响 resolve。结果与输入
   * 无关，不做进程内缓存。 */
  return MOONUI_RENDER_AUTO;
}`);
REAL.set("moonui_render_backend_resolve_at", `MoonuiRenderBackend moonui_render_backend_resolve_at(const char *pref_path) {
  /* 测试钩子与 resolve 同口径：Linux 上没有「按偏好文件切换后端」这回事，
   * 恒 Auto。要看偏好文件里存的名字，用 pref_code_at（原始码，不是生效后端）。 */
  (void)pref_path;
  return MOONUI_RENDER_AUTO;
}`);
REAL.set("moonui_render_backend_write_pref", `int moonui_render_backend_write_pref(const char *name) {
  char path[1024];
  char dir[1024];
  const char *home = getenv("HOME");
  if (home == NULL || home[0] == '\\0') {
    return -1;
  }
  if (snprintf(dir, sizeof(dir), "%s/.moonui", home) <= 0) {
    return -1;
  }
  mkdir(dir, 0755); /* 已存在（EEXIST）也无妨 */
  if (!moonui_render_pref_default_path(path, sizeof(path))) {
    return -1;
  }
  return moonui_render_pref_write_line(path, name);
}`);
REAL.set("moonui_render_backend_write_pref_at", `int moonui_render_backend_write_pref_at(const char *path, const char *name) {
  return moonui_render_pref_write_line(path, name);
}`);
REAL.set("moonui_render_backend_pref_code_at", `int moonui_render_backend_pref_code_at(const char *pref_path) {
  char pref[32];
  if (!moonui_render_pref_read_line(pref_path, pref, sizeof(pref))) {
    return -1;
  }
  return (int)moonui_render_backend_parse(pref);
}`);

const IMPL_FILES = [
  "backends/native-linux/widgets_gtk.inc",
  "backends/native-linux/leaves_gtk.inc",
  "backends/native-linux/canvas_gtk.inc",
  "backends/native-linux/clipboard_gtk.inc",
  "backends/native-linux/dialogs_gtk.inc",
  "backends/native-linux/menus_gtk.inc",
  "backends/native-linux/theme_gtk.inc",
  "backends/native-linux/a11y_gtk.inc",
  "backends/native-linux/focus_gtk.inc",
  "backends/native-linux/scroll_gtk.inc",
  "backends/native-linux/widgets2_gtk.inc",
  "backends/native-linux/windows_gtk.inc",
];

const ABSENT = new Map();
ABSENT.set("moonui_native_audio_load", `  return -3;`);
ABSENT.set("moonui_native_audio_play", `  return -3;`);
ABSENT.set("moonui_native_audio_pause", `  return -3;`);
ABSENT.set("moonui_native_audio_stop", `  return -3;`);
ABSENT.set("moonui_native_audio_position_ms", `  return -1;`);
ABSENT.set("moonui_native_audio_duration_ms", `  return -1;`);
ABSENT.set("moonui_native_audio_seek_ms", `  return -3;`);
ABSENT.set("moonui_native_audio_set_volume", `  return -3;`);
ABSENT.set("moonui_native_audio_is_playing", `  return 0;`);
ABSENT.set("moonui_native_audio_set_rate", `  return -3;`);
ABSENT.set("moonui_native_audio_rate", `  return 1000;`);
ABSENT.set("moonui_native_audio_on_finished", `  return -3;`);
ABSENT.set("moonui_native_audio_clear_on_finished", `  return -3;`);
ABSENT.set("moonui_native_audio_prime", `  return -3;`);
ABSENT.set("moonui_native_audio_prime_clear", `  return -3;`);
ABSENT.set("moonui_native_audio_on_primed", `  return -3;`);
ABSENT.set("moonui_native_audio_clear_on_primed", `  return -3;`);
ABSENT.set("moonui_native_audio_loudness_start", `  return -3;`);
ABSENT.set("moonui_native_audio_on_loudness", `  return -3;`);
ABSENT.set("moonui_native_audio_clear_on_loudness", `  return -3;`);
ABSENT.set("moonui_native_audio_set_track_gain", `  return 0;`);
ABSENT.set("moonui_native_audio_track_gain", `  return 0;`);
ABSENT.set("moonui_native_audio_level", `  return 0;`);
ABSENT.set("moonui_native_audio_eq_band_count", `  return 0;`);
ABSENT.set("moonui_native_audio_eq_set_band", `  return -3;`);
ABSENT.set("moonui_native_audio_eq_band_gain", `  return 0;`);
ABSENT.set("moonui_native_audio_eq_set_enabled", `  return -3;`);
ABSENT.set("moonui_native_audio_eq_enabled", `  return 0;`);
ABSENT.set("moonui_native_audio_output_list", `  static const unsigned char empty[8] = {0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF};
  moonbit_bytes_t packed = moonbit_make_bytes(8, 0);
  memcpy(packed, empty, 8);
  return (moonui_ptr)packed;`);
ABSENT.set("moonui_native_audio_output_set", `  return -3;`);
ABSENT.set("moonui_native_audio_probe", `  return (moonui_ptr)moonbit_make_bytes(0, 0);`);
ABSENT.set("moonui_native_media_keys_set", `  return -3;`);
ABSENT.set("moonui_native_hotkeys_set", `  return -3;`);
ABSENT.set("moonui_native_now_playing_set", `  return -3;`);

// ---------------------------------------------------------------------------
// 「本平台未实现」表：这些符号在 Linux 上**不打算**实现，但也不能当中性桩。
// 中性桩一律 return 0，而 ABI 里 0 在**大多数**函数上是"成功"——对"这一侧
// 根本没接"的功能，返 0 就是谎报。音频（T235 P5）按 T237 裁决③只如实报
// 缺席，码表照 backends/native-windows/adapter_native.c 的音频段逐条对齐。
// ---------------------------------------------------------------------------

function loadImplFiles() {
  // 返回 [拼接后的 C 文本, 里面定义的 moonui_* 符号集合]。
  const chunks = [];
  const names = new Set();
  for (const rel of IMPL_FILES) {
    const p = path.join(REPO, rel);
    if (!fs.existsSync(p) || !fs.statSync(p).isFile()) {
      // 拼错文件名时给一句话，别让 Node 的 ENOENT 栈往上冒：栈里看不出
      // "你这是 IMPL_FILES 写错了"，而这条错会让整份实现消失（生成物退回全桩）。
      process.stderr.write(
        `[gen] IMPL_FILES 里的文件不存在：${rel}\n` +
        '      路径按仓库根展开，检查拼写与目录名。\n');
      process.exit(1);
    }
    const text = fs.readFileSync(p, 'utf8');
    // 只认**非 static** 的定义算 ABI 符号：手写文件里的内部帮手一律要写
    // static（文件本就是个翻译单元）。拼错的名字不会出现在 adapter.h 里，
    // 于是被当成"外部符号"抓出来，而不是静默变成没人调用的帮手。
    const re = /^([A-Za-z_][A-Za-z0-9_ \t\*]*?)\b(moonui_[A-Za-z0-9_]+)\s*\(/gm;
    let m;
    while ((m = re.exec(text)) !== null) {
      if (m[1].split(/\s+/).includes('static')) continue;
      names.add(m[2]);
    }
    chunks.push(`/* ---- 手写实现：${rel} ---- */\n${text}`);
  }
  return [chunks.join('\n'), names];
}

function stripComments(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}

function parseDecls(text) {
  // 返回 [[ret_type, name, args], ...]，仅含 moonui_* 函数声明。
  const decls = [];
  const re = /moonui_[A-Za-z0-9_]+\s*\(/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const name = m[0].split('(')[0].trim();
    const openParen = m.index + m[0].length - 1;
    let depth = 0;
    let i = openParen;
    const n = text.length;
    while (i < n) {
      const c = text[i];
      if (c === '(') depth += 1;
      else if (c === ')') {
        depth -= 1;
        if (depth === 0) break;
      }
      i += 1;
    }
    const args = text.slice(openParen + 1, i).trim();
    let j = m.index - 1;
    while (j >= 0 && !';}{'.includes(text[j])) j -= 1;
    const ret = text.slice(j + 1, m.index).trim()
      .replace(/extern "C"/g, '').trim();
    if (ret.includes('(*')) continue;
    decls.push([ret, name, args]);
  }
  const seen = new Set();
  const uniq = [];
  for (const d of decls) {
    if (seen.has(d[1])) continue;
    seen.add(d[1]);
    uniq.push(d);
  }
  return uniq;
}

function fail(msg) {
  process.stderr.write(msg + '\n');
  process.exit(1);
}

function main() {
  const raw = fs.readFileSync(HDR, 'utf8');
  const text = stripComments(raw);
  const decls = parseDecls(text);
  const [implText, implNames] = loadImplFiles();
  void implText; // 与 Python 版一致：拼接文本只用于校验，输出靠 #include。
  const declaredAll = new Set(decls.map((d) => d[1]));

  const stray = [...implNames].filter((n) => !declaredAll.has(n)).sort();
  if (stray.length) {
    fail('[gen] 手写实现里有 adapter.h 中不存在的符号（拼错了？）：' + stray.join(', '));
  }
  const both = [...implNames].filter((n) => REAL.has(n)).sort();
  if (both.length) {
    fail('[gen] 符号同时出现在 REAL 表与手写实现里：' + both.join(', '));
  }
  // 同一套对账给「本平台未实现」表：拼错名字会让真正的符号继续拿中性桩。
  const absentStray = [...ABSENT.keys()].filter((n) => !declaredAll.has(n)).sort();
  if (absentStray.length) {
    fail('[gen] ABSENT 表里有 adapter.h 中不存在的符号（拼错了？）：' + absentStray.join(', '));
  }
  const clash = new Set();
  for (const n of ABSENT.keys()) if (REAL.has(n) || implNames.has(n)) clash.add(n);
  const absentClash = [...clash].sort();
  if (absentClash.length) {
    fail('[gen] 符号同时出现在 ABSENT 与 REAL/手写实现里：' + absentClash.join(', '));
  }

  const lines = [];
  lines.push('/*');
  lines.push(' * MoonUI 原生后端 · Linux / GTK4 适配器（T235 P3–P6，自动生成）。');
  lines.push(' *');
  lines.push(' * 已接真实 GTK4 实现的：P3 的窗口 / 事件循环 / 键盘 / 鼠标 / 手势，');
  lines.push(' * P4 的画布 24 条（cairo，住 canvas_gtk.inc），P6-1 的控件挂载层');
  lines.push(' * （widgets_gtk.inc：窗口内容容器 GtkOverlay→GtkFixed、Panel/Custom 两种');
  lines.push(' * 控件、attach/摆放/层叠、命中反查），P6-2 的剪贴板 2 条（clipboard_gtk.inc；');
  lines.push(' * GTK4 的读是异步的，所以那片在 C 里泵临时 GMainLoop 到回调为止），');
  lines.push(' * P6-3 的对话框与文件面板 8 条（dialogs_gtk.inc：GtkMessageDialog +');
  lines.push(' * GtkFileChooserNative，4.6 上唯一可用的形态；GTK4 已没有同步的 run，');
  lines.push(' * 同样靠临时 GMainLoop 等 response）；P6-4a 的菜单栏与上下文菜单 7 条');
  lines.push(' * （menus_gtk.inc：GtkPopoverMenuBar + GMenuModel + GSimpleActionGroup）；');
  lines.push(' * P6-4b 的系统外观与控件样式 2 条（theme_gtk.inc：GtkSettings 两代');
  lines.push(' * 深色读口 + 每 widget 一只 GtkCssProvider；CSS 文本拼串在下面 prelude）；');
  lines.push(' * P6-4c 的无障碍 4 条（a11y_gtk.inc：GtkAccessible 的 role/LABEL/');
  lines.push(' * DESCRIPTION/CHECKED、两条系统偏好读数、自绘面焦点 opt-in；state 的');
  lines.push(' * DISABLED/HIDDEN 由 GTK 按活值自己算，T58 定案不注记快照）；');
  lines.push(' * P6-5 的控件叶子 8 条（leaves_gtk.inc：文案/占位/勾选/三条回调；');
  lines.push(' * widget_new 在 widgets_gtk.inc 里从 2 种扩到 10 种 kind，kind 映射表');
  lines.push(' * 是 prelude 里唯一那份）；');
  lines.push(' * P6-5b 的焦点链/自绘面点击 4 条（focus_gtk.inc）、滚动内容 1 条');
  lines.push(' * （scroll_gtk.inc），widget_new 再扩 14 MenuRow / 15 Scroll 两种 kind。');
  lines.push(' * P6-5c 的七构造族（widgets2_gtk.inc：Slider/Spinbox/Progress/');
  lines.push(' * ComboBox/MultilineEntry/RadioButtons/DatePicker）与 P8 真窗判据已落地；');
  lines.push(' * P6-6 的窗口状态与尺寸下限 9 条 + P6-7 的窗口几何口径 15 条');
  lines.push(' * （windows_gtk.inc：前者 min_size/resizable/fullscreen/minimized/');
  lines.push(' * maximized/state/is_key/request_close；后者 screen_work_area /');
  lines.push(' * window_screen_origin/size 用 GdkMonitor 整屏 geometry 真实现，');
  lines.push(' * 任务栏/Dock 不扣除是已知边界；其余 12 条位置/标题栏/拖动带/');
  lines.push(' * 红绿灯/live-resize 是 mac/Win32 概念，按契约空操作或兜底常量）。');
  lines.push(' * render_backend 6 条（parse/resolve/resolve_at/write_pref/');
  lines.push(' * write_pref_at/pref_code_at）在 REAL 段纯逻辑实现：名字表与 mac');
  lines.push(' * 同构，resolve 在 Linux 恒 Auto（没有 Metal/CG 二选一）。');
  lines.push(' * 19 WebView 仍如实缺席（GTK4 本体没有 WebView），归后续片。');
  lines.push(' * 十二片手写实现都被本文件 #include 进同一个翻译单元。');
  lines.push(' * P5 的音频 34 条是**显式缺席**：不写 GStreamer/ALSA');
  lines.push(' * （T237 裁决③），但按 adapter.h 的口径逐条给 -3 / 哨兵值——中性桩的');
  lines.push(' * return 0 在 audio_load 上会被壳当成「歌装上了」。其余 ABI 符号保持');
  lines.push(' * unsupported 中性桩（整数 0 / 指针 NULL / 空）。P6-6 那 9 条只真跑');
  lines.push(' * 验到「set→get 往返 + 焦点 A/B」；fullscreen 回落与 minimized 状态');
  lines.push(' * 在 mac 私有运行时读不回，要 CI 的 4.6 / X11，见 windows_gtk.inc 头注。');
  lines.push(' * P6-7 的 12 条空操作只验「兜底常量守约 + 不破坏几何」；screen_* 与');
  lines.push(' * GdkMonitor 读数对拍（真 GTK4 4.24/Quartz 本机可跑）。');
  lines.push(' * 生成方式：node scripts/gen-native-linux-gtk.js');
  lines.push(' *   解析源是 backends/native-common/adapter.h（保证签名与 ABI 头逐字一致）。');
  lines.push(' * 验证：真头编译由 scripts/gtk4-sysroot-check.sh 在本机做（私有 sysroot');
  lines.push(' * + 4.6 最低版本闸，该闸已写进下面的 prelude 而不只靠 -D）；假头语法与');
  lines.push(' * 纯逻辑判据见 scripts/mock-gtk-check.sh；画布像素 / 控件层结构 / 剪贴板');
  lines.push(' * 写读 / 对话框 / 菜单 / 主题 / 无障碍 / 控件叶子 / 焦点链真跑的**真链接 +');
  lines.push(' * 真跑判据**见 scripts/canvas-pixel-check.sh；主题 / CSS / 无障碍 /');
  lines.push(' * 控件叶子 / 焦点链与自绘面点击的纯逻辑另见假头闸第 10、11、12、13 组；');
  lines.push(' * render_backend 的名字表与偏好文件往返见第 16 组。');
  lines.push(' * xvfb 真窗由 CI 的 linux-backend-link job 负责。');
  lines.push(' */');
  lines.push('');
  lines.push('#include "adapter.h"');
  lines.push('#include <string.h>');
  lines.push('#include <stdlib.h>');
  /* T235 P6-7：渲染后端偏好文件（fopen/fgets/snprintf）与 $HOME/.moonui 建目录
   * （mkdir）要这两个头。REAL 段的函数在假头构建里也编译，所以放公共区。 */
  lines.push('#include <stdio.h>');
  lines.push('#include <sys/stat.h>');
  lines.push('');
  lines.push('#if defined(__GNUC__) || defined(__clang__)');
  lines.push('#pragma GCC diagnostic ignored "-Wunused-parameter"');
  lines.push('#pragma GCC diagnostic ignored "-Wunused-function"');
  lines.push('#endif');
  lines.push('');
  lines.push('/* moonbit.h 中 moonbit_bytes_t=uint8_t*、moonbit_string_t=uint16_t* 均');
  lines.push(' * 为指针，故 return 0 对全部非 void 返回类型均合法（指针→NULL，整数→0）。');
  lines.push(' * 桩体一律空/return 0；P3/P4 真实实现见下方。 */');
  lines.push('');
  lines.push(PREAMBLE);
  lines.push('');
  lines.push('/* 手写实现（同一翻译单元）。假头构建跳过：mock-gtk.h 里没有 cairo/');
  lines.push(' * pango/gdk-pixbuf，这几片的真实实现在那个构建里由文件末尾的同签名桩顶上。 */');
  lines.push('#ifndef MOONUI_MOCK_GTK');
  for (const rel of IMPL_FILES) {
    lines.push('#include "' + rel.split('/').pop() + '"');
  }
  lines.push('#endif');

  // REAL 表里写错的键会**静默**落回 stub（生成物照样编得过），所以先对账。
  const declared = new Set(decls.map((d) => d[1]));
  const unknown = [...REAL.keys()].filter((n) => !declared.has(n)).sort();
  if (unknown.length) {
    fail('[gen] REAL 表里有 adapter.h 中不存在的符号（改了名？）：' + unknown.join(', '));
  }

  let realCount = 0;
  let stubCount = 0;
  let implCount = 0;
  let absentCount = 0;
  const implStubs = [];
  let absentHeaderDone = false;
  for (const [ret, name, args] of decls) {
    if (REAL.has(name)) {
      lines.push(REAL.get(name));
      lines.push('');
      realCount += 1;
    } else if (implNames.has(name)) {
      // 真实实现在手写实现文件里（已在上方 include）。假头构建里那几份被跳过，
      // 所以攒一条同签名桩，末尾统一放进 #ifdef MOONUI_MOCK_GTK。
      const body = ret === 'void' ? ' { }' : ' { return 0; }';
      implStubs.push(`${ret} ${name}(${args})${body}`);
      implCount += 1;
    } else if (ABSENT.has(name)) {
      if (!absentHeaderDone) {
        lines.push('');
        lines.push('/* ---- 本平台未实现（T235 P5）：码按 adapter.h 口径 ----');
        lines.push(' * 这些不是中性桩。中性桩 return 0，而 0 在 ABI 上多数是「成功」——');
        lines.push(' * 对「这侧根本没接」的功能，返 0 就是谎报（audio_load 返 0 会被壳');
        lines.push(' * 当成「歌装上了」，播放器画得出来却永远不出声）。码表与 Windows 半');
        lines.push(' * 的音频段逐条一致；壳把 -3 映射成 AudioError::Unsupported。');
        lines.push(' * 音频不在框架承诺范围（T237 裁决③），故这里不写 GStreamer/ALSA。 */');
        absentHeaderDone = true;
      }
      lines.push(`${ret} ${name}(${args}) {`);
      lines.push(ABSENT.get(name));
      lines.push('}');
      lines.push('');
      absentCount += 1;
    } else {
      const body = ret === 'void' ? ' { }' : ' { return 0; }';
      lines.push(`${ret} ${name}(${args})${body}`);
      stubCount += 1;
    }
  }

  if (implStubs.length) {
    lines.push('');
    lines.push('#ifdef MOONUI_MOCK_GTK');
    lines.push('/* 假头构建专用：手写实现文件的替身，保住"每个 ABI 符号都有定义"。 */');
    lines.push(...implStubs);
    lines.push('#endif');
  }

  const out = process.argv[2] || OUT;
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, lines.join('\n') + '\n');
  process.stderr.write(
    `[gen] real=${realCount} impl=${implCount} absent=${absentCount} stubs=${stubCount} -> ${out}\n`);
}

main();
