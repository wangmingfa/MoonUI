#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""T235 P3：从 backends/native-common/adapter.h 生成 GTK4 后端适配器
adapter_native_gtk.c —— 对 P3 目标符号（窗口 / 事件循环 / 键盘 / 鼠标 /
手势）落地真实 GTK4·Cairo 实现，其余保持 unsupported 中性桩。

为什么还是生成的：
  adapter.h 里 ~264 条 ABI 声明，逐一手写易错且会与头文件漂移。本脚本沿用
  P2 的「解析 adapter.h → 签名逐字一致」策略：所有非 P3 符号仍由解析结果自动
  产出中性桩；P3 符号由本脚本内嵌的真实实现替换（REAL 字典，含完整签名）。
  这样加一个新 ABI 符号时，桩会自动跟上，P3 真实实现只动它该动的那些。

P3 真实实现区间（与 mac adapter 同形的「全局回调 + 读回」pull 模型）：
  - 初始化 / 事件循环：gtk_init_check + g_main_context_iteration / g_main_context_pending
  - 窗口：GtkWindow 创建 / 显示 / 隐藏 / 销毁 / 标题 / 内容尺寸（物理↔逻辑像素
    按 GDK scale 换算，与 mac 的 backingScaleFactor 同口径）
  - 窗口回调：close-request（返 TRUE 把销毁权交还 Core，同 mac windowShouldClose
    返 NO）/ realize→GdkSurface::resize（resized + moved）
  - 键盘：GtkEventControllerKey → 存状态 + 触发全局闭包
  - 鼠标：GtkEventControllerMotion（移动/离开）+ GtkGestureClick（按下/抬起/双击）
    + GtkEventControllerScroll（滚轮）→ 存状态 + 触发全局闭包；坐标物理像素、
    delta 逻辑像素（与 ABI 口径一致）
  - 手势：GtkGestureZoom / Rotate / Swipe（触控板捏合/旋转/双指滑动）

证据边界（2026-11-08 订正）：本文件 `#include <gtk/gtk.h>`，**本机也能真编**——
scripts/gtk4-sysroot-fetch.sh 从 brew bottle 解一份私有 sysroot（不动系统、不装包），
scripts/gtk4-sysroot-check.sh 拿真头做两道闸：①抓「GTK4 里根本没有这个函数」，
②抓「用了比 4.6 新的 API」。这道闸第一跑就抓出 5 处 GTK3 遗留，所以**别再拿
mock 假头去证 API 用法**（假头只能证 C 自洽，证不了用对）。真链接 / xvfb 真窗
仍由 CI 的 linux-backend-link job 负责。

用法：
  python3 scripts/gen-native-linux-gtk.py [output.c]
默认输出到 backends/native-linux/adapter_native_gtk.c。
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HDR = os.path.join(REPO, "backends", "native-common", "adapter.h")
OUT = os.path.join(REPO, "backends", "native-linux", "adapter_native_gtk.c")

# ---------------------------------------------------------------------------
# P3 真实实现区间：GTK 头 + 全局状态 + 工具 + 信号处理器（一次前置）
# ---------------------------------------------------------------------------
PREAMBLE = r'''/* ===================== P3 真实实现区间（GTK4） ===================== */
/* 最低版本闸写进**编译单元自身**，不只靠构建脚本传 -D：
 *   - GDK_VERSION_MIN_REQUIRED = 4.6 有两个作用，缺一不可：
 *     ① 用了比 4.6 新的 API 时，GDK_AVAILABLE_IN_4_x 展开成 "unavailable" 报错
 *        （看 gdk-visibility.h：`#if GDK_VERSION_MIN_REQUIRED < GDK_VERSION_4_8`
 *        时才把 4.8 的接口标成不可用）；
 *     ② **4.10 起弃用的 API 不再报弃用**——同样是上面那个 #if 的另一半
 *        （`#if GDK_VERSION_MIN_REQUIRED >= GDK_VERSION_4_10` 才标 GDK_DEPRECATED）。
 *        语义是对的：还要支持 4.6 的人，4.10 才弃用的接口就是他唯一的选择。
 *        P6-3 的对话框正卡在这条上：4.6 上只有 GtkMessageDialog /
 *        GtkFileChooserNative 可用（GtkAlertDialog / GtkFileDialog 要 4.10），
 *        不写这一行，2026-11-08 实测每条都刷一遍 -Wdeprecated-declarations。
 *   - GDK_VERSION_MAX_ALLOWED = 4.6 是传统那半（对齐 gtk4-sysroot-check.sh 的
 *     -D 口径），把"更高版本才有的东西"也一并钉住。
 * 宏体里的 GDK_VERSION_4_6 此刻还没定义，但宏是延迟展开的：首次求值发生在
 * gdkversionmacros.h 内部的 #if，那时版本宏早已定义（见该头 99 行起）。
 * 假头构建（MOONUI_MOCK_GTK）没有这些宏，整段跳过。 */
#ifndef MOONUI_MOCK_GTK
#ifndef GDK_VERSION_MIN_REQUIRED
#define GDK_VERSION_MIN_REQUIRED GDK_VERSION_4_6
#endif
#ifndef GDK_VERSION_MAX_ALLOWED
#define GDK_VERSION_MAX_ALLOWED GDK_VERSION_4_6
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
} MoonuiWinSlot;
static MoonuiWinSlot moonui_wins[MOONUI_WIN_SLOTS];

/* ---- 控件登记表（T235 P6）----
 * 每个经 moonui_native_widget_new 造出来的控件在这里记一行 GtkWidget* → kind。
 * 为什么需要这本账：GTK4 的控件是统一类型，`gtk_widget_get_type()` 问不出"这是
 * Label 还是 Panel"（我们用容器与绘制面拼，类型未必不同），而 set_style /
 * 命中反查 / z 序这些入口都要按 kind 分派。mac 半用 objc_setAssociatedObject
 * 存 kind+1、Windows 半用 SetPropW——同一本账的三种落法，这里用静态表（与
 * 窗口登记表、画布上屏面登记表同一套形状）。
 *
 * 存 kind+1、0 表示空槽：kind 0 是 Label，用 0 当"空"会把 Label 读成没登记。
 * 登记/销账必须跟着 create/destroy 走（`T110` 那条老课：后端自建的"身份登记表"
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
  if (s != NULL) memset(s, 0, sizeof(MoonuiWidgetSlot));
}
/* -1 = 不是我们造的控件（或空指针）。 */
static int moonui_widget_kind_of(GtkWidget *w) {
  MoonuiWidgetSlot *s = moonui_wslot_of(w);
  return s == NULL ? -1 : s->kind1 - 1;
}

/* 命中反查（`mouse_owner`）：从 pick 到的那个 widget 沿父链往上找，第一个
 * "登记表里有"的就是 owner。找不到（点到空白、点到窗口自己）返回 0——ABI 的
 * "0 = 空白"。为什么要沿父链：GTK4 里控件的内部分件会被 pick 命中，而 Core
 * 要的是那个控件句柄（mac 半靠 hitTest + owner 记号做同一件事，见 `T86①`）。 */
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
 * 真头下编译直接报 undeclared）：缩放挂在 surface / monitor 上。窗口还没 realize
 * 时没有 surface，退回 1——未上屏谈缩放没有意义。 */
static int moonui_scale_of(GtkWidget *w) {
  int s = 0;
  if (w != NULL) {
    GdkSurface *surf;
    s = gtk_widget_get_scale_factor(w);
    if (s <= 0) {
      surf = gtk_native_get_surface(GTK_NATIVE(w));
      if (surf != NULL) s = gdk_surface_get_scale_factor(surf);
    }
  }
  return s > 0 ? s : 1;
}
static char *moonui_dup(const char *s, int len) {
  char *out;
  if (len < 0) return 0;
  out = (char *)malloc((size_t)len + 1u);
  if (out == 0) return 0;
  if (len > 0) memcpy(out, s, (size_t)len);
  out[len] = '\0';
  return out;
}
static moonbit_bytes_t moonui_bytes_of(const char *s) {
  int n = (int)strlen(s);
  moonbit_bytes_t out = moonbit_make_bytes(n, 0);
  if (n > 0) memcpy(out, s, (size_t)n);
  return out;
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
 * 词表的正本是 mac 的 `moonui_native_key_name_of_code`（Enter / Tab / Escape /
 * Backspace / Delete / Home / End / PageUp / PageDown / Left / Right / Up /
 * Down / F1..F12 + 单个小写字母 + 单个数字 + Space）。
 * gdk_keyval_name 给的拼法有 5 处不同（Return / BackSpace / Page_Up /
 * Page_Down / space），其余同名；词表以外的键（修饰键自己、输入法、媒体键）
 * 一律留空串，调用方据此**不产事件**——同 mac 的 `moonui_native_key_notify`
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
  moonui_key_name_buf[0] = '\0';
  if (n == NULL) return;
  /* 单字符：字母折小写（Shift+a 的 keyval 是 'A'，mac 那侧同样折成 'a'，
   * 大写由修饰键位表达）、数字原样。 */
  if (n[1] == '\0') {
    char c = n[0];
    if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
      moonui_key_name_buf[0] = c;
      moonui_key_name_buf[1] = '\0';
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
  moonui_key_name_buf[sizeof(moonui_key_name_buf) - 1] = '\0';
}

/* ---- 窗口登记表 ---- */
static MoonuiWinSlot *moonui_win_slot_of(GtkWidget *w) {
  int i;
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

/* 闭包槽位换人：先把旧的那份松掉再装新的。mac 那侧 `moonui_native_take_slot`
 * 与 `moonui_native_key_drop_closure` 是同一件事（adapter.h 的「重复调用只换
 * 回调」），不松就每换一次漏一个 MoonBit 对象。 */
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
 * 可读（客户端拿不到自己的位置），`layout`/`resize` 也不区分有没有真变，而
 * `gtk_widget_get_width/height` 是确定有的读数、且和 content_size 同一套口径。
 * 回声挡：程序自己 `set_content_size` 之后置 suppress_resize，下一圈看见的第一次
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
  (void)keycode; (void)data;
  moonui_key_name_store(keyval);
  /* 词表外的键（修饰键自己、输入法、媒体键）不产事件，同 mac 的
   * moonui_native_key_notify。 */
  if (moonui_key_name_buf[0] == '\0') return FALSE;
  if (moonui_key_fn == 0) return FALSE;
  moonui_key_target_ptr = (moonui_ptr)(uintptr_t)win;
  moonui_key_down = 1;
  moonui_key_mods = moonui_mods_of(state);
  moonui_key_fn(moonui_key_closure);
  return FALSE; /* 不吞：原生控件与输入法照旧收得到 */
}
static void moonui_key_released(GtkEventControllerKey *self, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
  GtkWidget *win = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(self));
  (void)keycode; (void)data;
  moonui_key_name_store(keyval);
  if (moonui_key_name_buf[0] == '\0') return;
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
  /* 这一格是**已知未校准**的转换，别当它已经对好了：
   * ① 单位——ABI 要逻辑像素，且 mac 那边"一格滚轮 ≈ 3 行 × 每行 10 px = 30"；
   *    GTK 的 `GtkEventControllerScroll` 不带 DISCRETE 旗标时给的是 smooth delta，
   *    离散滚轮在 GTK 内部被折成 ±1，与 mac 那套不是同一个量纲。要按
   *    `gdk_scroll_event_get_unit()` 分档乘倍数才对，但那几个 accessor 没在本机
   *    编过，先用原值透传、把"量一次再定倍数"写进 P8 判据（TODO T235）。
   * ② 方向——ABI 正 = 往下/往右读；GTK 的 dy 正也是"内容往上走"，同向，但
   *    "自然滚动"取反要等真机量（`isDirectionInvertedFromDevice` 的对位物）。
   * ③ pos——滚轮事件没有坐标，这里留的是上一颗鼠标事件的位置；ABI 的
   *    `Event::Scroll` 只带 delta、不消费 pos，所以不影响 Core。 */
  moonui_mouse_ldx = (int)llround(dx);
  moonui_mouse_ldy = (int)llround(dy);
  if (moonui_mouse_fn) moonui_mouse_fn(moonui_mouse_closure);
  return FALSE;
}
/* 手势（P3.1，GTK4 触控板）：pinch/rotate/swipe。若 Linux 真机编译不过，可临时
 * 注释本段并把 moonui_native_on_gesture 改成 `return -1;`（同 Windows 口径）。 */
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

/* ===================== 以下为 P3 真实函数体（由 REAL 字典注入） ===================== */
'''

# ---------------------------------------------------------------------------
# P3 真实函数体（完整签名 + 实现）。键名须与 adapter.h 中的符号一致。
# ---------------------------------------------------------------------------
REAL = {}

REAL["moonui_native_init"] = r'''int moonui_native_init(void) {
  if (moonui_inited) return 0;
  moonui_last_error_buf[0] = '\0';
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
}'''

REAL["moonui_native_last_error"] = r'''moonbit_bytes_t moonui_native_last_error(void) {
  return moonui_bytes_of(moonui_last_error_buf);
}'''

REAL["moonui_native_terminate"] = r'''void moonui_native_terminate(void) {
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
  moonui_key_name_buf[0] = '\0';
  moonui_quit_flag = FALSE;
  moonui_inited = FALSE;
}'''

REAL["moonui_native_time_ms"] = r'''int64_t moonui_native_time_ms(void) {
  /* 单调时钟（glib 的 monotonic 就是 mac 那侧 mach_absolute_time 的对位物），
   * 单位毫秒。动画/计时全部吃这条，返回 0 会让每一帧都是"时间没走"。 */
  return (int64_t)(g_get_monotonic_time() / 1000);
}'''

REAL["moonui_native_window_new"] = r'''moonui_ptr moonui_native_window_new(const char *title, int title_len, int width, int height) {
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
}'''

REAL["moonui_native_window_show"] = r'''void moonui_native_window_show(moonui_ptr w) {
  gtk_window_present(GTK_WINDOW((GtkWidget *)(uintptr_t)w));
}'''

REAL["moonui_native_window_hide"] = r'''void moonui_native_window_hide(moonui_ptr w) {
  /* gtk_widget_hide 自 4.10 弃用（真头下 -Wall 报 deprecated），
   * set_visible(FALSE) 语义相同。 */
  gtk_widget_set_visible((GtkWidget *)(uintptr_t)w, FALSE);
}'''

REAL["moonui_native_window_destroy"] = r'''void moonui_native_window_destroy(moonui_ptr w) {
  GtkWidget *win = (GtkWidget *)(uintptr_t)w;
  MoonuiWinSlot *slot = moonui_win_slot_of(win);
  if (slot) {
    if (slot->closing_cl) moonbit_decref(slot->closing_cl);
    if (slot->resized_cl) moonbit_decref(slot->resized_cl);
    if (slot->moved_cl)   moonbit_decref(slot->moved_cl);
    memset(slot, 0, sizeof(MoonuiWinSlot));
  }
  if (win) gtk_window_destroy(GTK_WINDOW(win));
}'''

REAL["moonui_native_window_set_title"] = r'''void moonui_native_window_set_title(moonui_ptr w, const char *title, int title_len) {
  char *t = moonui_dup(title, title_len);
  gtk_window_set_title(GTK_WINDOW((GtkWidget *)(uintptr_t)w), t ? t : "");
  if (t) free(t);
}'''

REAL["moonui_native_window_set_content_size"] = r'''void moonui_native_window_set_content_size(moonui_ptr w, int width, int height) {
  GtkWidget *win = (GtkWidget *)(uintptr_t)w;
  MoonuiWinSlot *slot = moonui_win_slot_of(win);
  int scale = moonui_scale_of(win);
  int wpt = (int)llround((double)width / scale);
  int hpt = (int)llround((double)height / scale);
  /* **GTK4 删掉了 gtk_window_resize**（GTK3 才有；真头下报 undeclared）。
   * 拆成两条：default_size 管"还没上屏时的请求值"，size_request 管"已上屏后
   * 真把窗口撑到这么大"。两个都设是因为 Core 两个阶段都会调过来（先摆尺寸再
   * show、以及 show 之后改），只设任一条都会有一边不生效。 */
  gtk_window_set_default_size(GTK_WINDOW(win), wpt, hpt);
  gtk_widget_set_size_request(win, wpt, hpt);
  /* 这是 Core 自己发起的改尺寸：下一圈轮询看到的那一次变化按基准吞掉，不回声
   * 成一条 Resize（adapter.h 的 on_resized 契约）。 */
  if (slot != NULL) slot->suppress_resize = 1;
}'''

REAL["moonui_native_window_content_size"] = r'''int64_t moonui_native_window_content_size(moonui_ptr w) {
  GtkWidget *win = (GtkWidget *)(uintptr_t)w;
  int scale = moonui_scale_of(win);
  int width = 0, height = 0;
  /* 上了屏就用真实客户区尺寸（与核心布局看到的一致），没上屏退回 default-size
   * ——后者是请求值，可能还没被窗口管理器兑现。 */
  if (win != NULL) {
    width = gtk_widget_get_width(win);
    height = gtk_widget_get_height(win);
  }
  if (width <= 0 || height <= 0) {
    gtk_window_get_default_size(GTK_WINDOW(win), &width, &height);
  }
  return moonui_pack2((int)llround(width * scale), (int)llround(height * scale));
}'''

REAL["moonui_native_window_on_closing"] = r'''int moonui_native_window_on_closing(moonui_ptr w, moonui_closure_fn fn, void *closure) {
  MoonuiWinSlot *s = moonui_win_slot_of((GtkWidget *)(uintptr_t)w);
  if (!s) return -1;
  moonui_closure_replace(&s->closing_fn, &s->closing_cl, fn, closure);
  return 0;
}'''

REAL["moonui_native_window_on_resized"] = r'''int moonui_native_window_on_resized(moonui_ptr w, moonui_closure_fn fn, void *closure) {
  MoonuiWinSlot *s = moonui_win_slot_of((GtkWidget *)(uintptr_t)w);
  if (!s) return -1;
  moonui_closure_replace(&s->resized_fn, &s->resized_cl, fn, closure);
  return 0;
}'''

REAL["moonui_native_window_on_moved"] = r'''int moonui_native_window_on_moved(moonui_ptr w, moonui_closure_fn fn, void *closure) {
  MoonuiWinSlot *s = moonui_win_slot_of((GtkWidget *)(uintptr_t)w);
  if (!s) return -1;
  /* GTK4 / Wayland 下客户端读不到自己窗口的位置，这条回调**装得上但永不触发**
   * （见本函数上方的说明）。装而不报不是撒谎：Core 摆位只靠自己的账本，位置
   * 读数（moonui_native_window_position）同样是 stub。 */
  moonui_closure_replace(&s->moved_fn, &s->moved_cl, fn, closure);
  return 0;
}'''

REAL["moonui_native_system_dpi"] = r'''int moonui_native_system_dpi(void) {
  return 96 * moonui_scale_of(NULL);
}'''

REAL["moonui_native_window_dpi"] = r'''int moonui_native_window_dpi(moonui_ptr w) {
  return 96 * moonui_scale_of((GtkWidget *)(uintptr_t)w);
}'''

REAL["moonui_native_on_key"] = r'''int moonui_native_on_key(moonui_closure_fn fn, void *closure) {
  moonui_closure_replace(&moonui_key_fn, &moonui_key_closure, fn, closure);
  return 0;
}'''

REAL["moonui_native_key_target"] = r'''moonui_ptr moonui_native_key_target(void) { return moonui_key_target_ptr; }'''
REAL["moonui_native_key_is_down"] = r'''int moonui_native_key_is_down(void) { return moonui_key_down; }'''
REAL["moonui_native_key_modifiers"] = r'''int moonui_native_key_modifiers(void) { return moonui_key_mods; }'''
REAL["moonui_native_key_name"] = r'''moonbit_bytes_t moonui_native_key_name(void) { return moonui_bytes_of(moonui_key_name_buf); }'''

REAL["moonui_native_on_mouse"] = r'''int moonui_native_on_mouse(moonui_closure_fn fn, void *closure) {
  moonui_closure_replace(&moonui_mouse_fn, &moonui_mouse_closure, fn, closure);
  return 0;
}'''

REAL["moonui_native_mouse_target"] = r'''moonui_ptr moonui_native_mouse_target(void) { return moonui_mouse_target_ptr; }'''
# mouse_owner 不在这张表里：它的实现在 widgets_gtk.inc（要查控件登记表）。
REAL["moonui_native_mouse_kind_button"] = r'''int moonui_native_mouse_kind_button(void) { return moonui_mouse_code; }'''
REAL["moonui_native_mouse_mods"] = r'''int moonui_native_mouse_mods(void) { return moonui_mouse_mods_val; }'''
REAL["moonui_native_mouse_pos"] = r'''int64_t moonui_native_mouse_pos(void) { return moonui_pack2(moonui_mouse_px, moonui_mouse_py); }'''
REAL["moonui_native_mouse_delta"] = r'''int64_t moonui_native_mouse_delta(void) { return moonui_pack2(moonui_mouse_ldx, moonui_mouse_ldy); }'''

REAL["moonui_native_on_gesture"] = r'''int moonui_native_on_gesture(moonui_closure_fn fn, void *closure) {
  moonui_closure_replace(&moonui_gesture_fn, &moonui_gesture_closure, fn, closure);
  return 0;
}'''
REAL["moonui_native_gesture_target"] = r'''moonui_ptr moonui_native_gesture_target(void) { return moonui_gesture_target_ptr; }'''
REAL["moonui_native_gesture_kind"] = r'''int moonui_native_gesture_kind(void) { return moonui_gesture_kind; }'''
REAL["moonui_native_gesture_phase"] = r'''int moonui_native_gesture_phase(void) { return moonui_gesture_phase; }'''
REAL["moonui_native_gesture_direction"] = r'''int moonui_native_gesture_direction(void) { return moonui_gesture_dir; }'''
REAL["moonui_native_gesture_value"] = r'''int64_t moonui_native_gesture_value(void) { return moonui_gesture_value; }'''

REAL["moonui_native_main_steps"] = r'''void moonui_native_main_steps(void) {
  /* GTK4 无需 finishLaunching 类比；gtk_init 已在 init 完成。 */
}'''
REAL["moonui_native_main_step"] = r'''int moonui_native_main_step(int wait) {
  (void)wait;
  if (moonui_quit_flag) return 0;
  g_main_context_iteration(NULL, FALSE);
  /* 尺寸变化是轮询出来的（见 moonui_poll_geometry），所以每泵一圈都要量一次；
   * 放在 iteration 之后，这一圈刚被窗口管理器改过的尺寸当圈就能报出去。 */
  moonui_poll_geometry();
  return 1;
}'''
REAL["moonui_native_messages_pending"] = r'''int moonui_native_messages_pending(void) {
  return g_main_context_pending(NULL) ? 1 : 0;
}'''
REAL["moonui_native_wait_messages"] = r'''/* 有界睡眠 + 顺带泵消息：MoonBit 侧（native-common/backend.mbt）把这条**只当
 * 有界睡眠用**，返回值不参与判断（`let _ = native_wait_messages(...)`），
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
}'''
REAL["moonui_native_quit"] = r'''void moonui_native_quit(void) { moonui_quit_flag = TRUE; }'''
REAL["moonui_native_quit_requested"] = r'''int moonui_native_quit_requested(void) { return moonui_quit_flag; }'''


# 手写实现文件：**同一个翻译单元**（被生成物 #include），所以能共用 static 状态、
# 也不给 prebuild 增加编译单元。生成器只做两件事：把文件原样收进来、把里面定义
# 的符号从"桩"里剔除（否则重定义）。想做下一片真实实现时，往这个列表里加文件即可。
#
# **顺序即 include 顺序**：widgets 在前，因为它那层（窗口内容容器 / GtkFixed 摆放）
# 是 canvas 的 attach_window 要用的；反过来 canvas 里没有任何符号被 widgets 引用。
# clipboard 与那两片无依赖关系，放其后；dialogs 只用 prelude 里的纯映射函数，与前三
# 片都不交叉。将来的"菜单 / 主题"也照此追加。
IMPL_FILES = [
    "backends/native-linux/widgets_gtk.inc",
    "backends/native-linux/canvas_gtk.inc",
    "backends/native-linux/clipboard_gtk.inc",
    "backends/native-linux/dialogs_gtk.inc",
]


# 「本平台未实现」表：这些符号在 Linux 上**不打算**实现，但也不能当中性桩。
#
# 为什么要单列一张表：中性桩一律 `return 0`，而 ABI 里 0 在**大多数**函数上是
# "成功"。对"这一侧根本没接"的功能，返 0 就是谎报——最刺眼的是
# `moonui_native_audio_load`：返 0 会被应用壳当成"歌装上了"，于是播放器画出来、
# 进度条能拖、永远不出声。所以这批要按 adapter.h 各段注释里写明的码逐个填。
#
# 音频（`T235` P5）：`T237` 已裁决③「音频是应用自带能力、不在框架承诺范围」，
# 所以 Linux 半不写 GStreamer/ALSA 那一套，只如实报缺席。码表照
# backends/native-windows/adapter_native.c 的音频段**逐条对齐**（那是同一条
# "没接的那侧返回 -3"契约的先例）：播放核心 -3、读回用哨兵（rate 1000、
# position/duration -1、is_playing 0）、EQ/频谱读回 0（= 这侧没有，UI 据此不画
# 假滑块）、bytes 出参给**空包**而不是 NULL（MoonBit 侧拿返回值直接 .length()）。
# 壳里把 load/play/unpause 的 -3 映射成 AudioError::Unsupported（DESIGN.md C-10
# 风险 4 / `T38`），状态行说「本平台还没接音频」。
ABSENT = {}


def absent(name, body):
    ABSENT[name] = body


# ---- 播放核心 ----
absent("moonui_native_audio_load", "  return -3;")
absent("moonui_native_audio_play", "  return -3;")
absent("moonui_native_audio_pause", "  return -3;")
absent("moonui_native_audio_stop", "  return -3;")
absent("moonui_native_audio_position_ms", "  return -1;")
absent("moonui_native_audio_duration_ms", "  return -1;")
absent("moonui_native_audio_seek_ms", "  return -3;")
absent("moonui_native_audio_set_volume", "  return -3;")
absent("moonui_native_audio_is_playing", "  return 0;")
# ---- 播放速率（`T171`）：读回恒 1000（原速），如实缺席而不是假装记下来 ----
absent("moonui_native_audio_set_rate", "  return -3;")
absent("moonui_native_audio_rate", "  return 1000;")
# ---- 播完回调 ----
absent("moonui_native_audio_on_finished", "  return -3;")
absent("moonui_native_audio_clear_on_finished", "  return -3;")
# ---- 无缝播放（`T168`）：调用方静默退「播完回调→load→play」老路 ----
absent("moonui_native_audio_prime", "  return -3;")
absent("moonui_native_audio_prime_clear", "  return -3;")
absent("moonui_native_audio_on_primed", "  return -3;")
absent("moonui_native_audio_clear_on_primed", "  return -3;")
# ---- 音量归一化（`T170`）：响度恒「测不出」，gain 直通（set 记不住、读回 0）----
absent("moonui_native_audio_loudness_start", "  return -3;")
absent("moonui_native_audio_on_loudness", "  return -3;")
absent("moonui_native_audio_clear_on_loudness", "  return -3;")
absent("moonui_native_audio_set_track_gain", "  return 0;")
absent("moonui_native_audio_track_gain", "  return 0;")
# ---- 频谱与均衡器：读回 0 = 这侧没有，UI 据此不画一排拖了没反应的假滑块 ----
absent("moonui_native_audio_level", "  return 0;")
absent("moonui_native_audio_eq_band_count", "  return 0;")
absent("moonui_native_audio_eq_set_band", "  return -3;")
absent("moonui_native_audio_eq_band_gain", "  return 0;")
absent("moonui_native_audio_eq_set_enabled", "  return -3;")
absent("moonui_native_audio_eq_enabled", "  return 0;")
# ---- 输出设备（`T169`）：列表 [int32 count=0][int32 current=-1] 的空包 ----
absent(
    "moonui_native_audio_output_list",
    "  static const unsigned char empty[8] = {0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF};\n"
    "  moonbit_bytes_t packed = moonbit_make_bytes(8, 0);\n"
    "  memcpy(packed, empty, 8);\n"
    "  return (moonui_ptr)packed;",
)
absent("moonui_native_audio_output_set", "  return -3;")
# ---- 探针：空包 = 读不出（MoonBit 侧退 Track::from_path 的文件名兜底）----
absent(
    "moonui_native_audio_probe",
    "  return (moonui_ptr)moonbit_make_bytes(0, 0);",
)
# ---- 媒体键 / 全局热键 / 正在播放（`T181`）：Linux 上要 X11 grab 或 MPRIS，
#     这层没接，同样如实 -3 而不是"注册成功"（否则系统那头永远不会有反应）----
absent("moonui_native_media_keys_set", "  return -3;")
absent("moonui_native_hotkeys_set", "  return -3;")
absent("moonui_native_now_playing_set", "  return -3;")


def load_impl_files():
    """返回 (拼接后的 C 文本, 里面定义的 moonui_* 符号集合)。"""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    chunks = []
    names = set()
    for rel in IMPL_FILES:
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            # 拼错文件名时给一句话，别让 Python 的 FileNotFoundError 栈往上冒：
            # 栈里看不出"你这是 IMPL_FILES 写错了"，而这条错会让整份实现消失
            # （生成物退回全桩），正是最容易被当成"P6 还没做"的那种假象。
            sys.stderr.write(
                "[gen] IMPL_FILES 里的文件不存在：%s\n"
                "      路径按仓库根展开，检查拼写与目录名。\n" % rel
            )
            raise SystemExit(1)
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
        # 只认**非 static** 的定义算 ABI 符号：手写文件里的内部帮手一律要写
        # static（文件本就是个翻译单元）。这条不是风格洁癖——它让"ABI 名字拼错"
        # 变成硬错：拼错的名字（如 moonui_canvas_fill_rectt）不会出现在 adapter.h
        # 里，于是被当成"外部符号"抓出来；否则它会静默变成一个没人调用的帮手，
        # 而真名继续拿桩。
        for m in re.finditer(
            r"^([A-Za-z_][A-Za-z0-9_ \t\*]*?)\b(moonui_[A-Za-z0-9_]+)\s*\(",
            text,
            re.M,
        ):
            prefix = m.group(1)
            if "static" in prefix.split():
                continue
            names.add(m.group(2))
        chunks.append("/* ---- 手写实现：%s ---- */\n%s" % (rel, text))
    return "\n".join(chunks), names


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    text = re.sub(r"//[^\n]*", " ", text)
    return text


def parse_decls(text):
    """返回 [(ret_type_str, name, args_str), ...]，仅含 moonui_* 函数声明。"""
    decls = []
    for m in re.finditer(r"moonui_[A-Za-z0-9_]+\s*\(", text):
        name = m.group(0).split("(")[0].strip()
        open_paren = m.end() - 1
        depth = 0
        i = open_paren
        n = len(text)
        while i < n:
            c = text[i]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        args = text[open_paren + 1 : i].strip()
        j = m.start() - 1
        while j >= 0 and text[j] not in ";}{":
            j -= 1
        ret = text[j + 1 : m.start()].strip().replace('extern "C"', "").strip()
        if "(*" in ret:
            continue
        decls.append((ret, name, args))
    seen = set()
    uniq = []
    for d in decls:
        if d[1] in seen:
            continue
        seen.add(d[1])
        uniq.append(d)
    return uniq


def main():
    with open(HDR, "r", encoding="utf-8") as f:
        raw = f.read()
    text = strip_comments(raw)
    decls = parse_decls(text)
    impl_text, impl_names = load_impl_files()
    declared_all = set(d[1] for d in decls)
    stray = sorted(impl_names - declared_all)
    if stray:
        sys.stderr.write(
            "[gen] 手写实现里有 adapter.h 中不存在的符号（拼错了？）：%s\n"
            % ", ".join(stray)
        )
        sys.exit(1)
    both = sorted(impl_names & set(REAL))
    if both:
        sys.stderr.write(
            "[gen] 符号同时出现在 REAL 表与手写实现里：%s\n" % ", ".join(both)
        )
        sys.exit(1)
    # 同一套对账给「本平台未实现」表：拼错名字会让真正的符号继续拿中性桩
    # （return 0 = 谎报成功），而这条错在生成物里看不出来——必须硬报。
    absent_stray = sorted(set(ABSENT) - declared_all)
    if absent_stray:
        sys.stderr.write(
            "[gen] ABSENT 表里有 adapter.h 中不存在的符号（拼错了？）：%s\n"
            % ", ".join(absent_stray)
        )
        sys.exit(1)
    absent_clash = sorted((set(ABSENT) & set(REAL)) | (set(ABSENT) & impl_names))
    if absent_clash:
        sys.stderr.write(
            "[gen] 符号同时出现在 ABSENT 与 REAL/手写实现里：%s\n" % ", ".join(absent_clash)
        )
        sys.exit(1)

    lines = []
    lines.append("/*")
    lines.append(" * MoonUI 原生后端 · Linux / GTK4 适配器（T235 P3–P6，自动生成）。")
    lines.append(" *")
    lines.append(" * 已接真实 GTK4 实现的：P3 的窗口 / 事件循环 / 键盘 / 鼠标 / 手势，")
    lines.append(" * P4 的画布 24 条（cairo，住 canvas_gtk.inc），P6-1 的控件挂载层")
    lines.append(" * （widgets_gtk.inc：窗口内容容器 GtkOverlay→GtkFixed、Panel/Custom 两种")
    lines.append(" * 控件、attach/摆放/层叠、命中反查），P6-2 的剪贴板 2 条（clipboard_gtk.inc；")
    lines.append(" * GTK4 的读是异步的，所以那片在 C 里泵临时 GMainLoop 到回调为止），")
    lines.append(" * P6-3 的对话框与文件面板 8 条（dialogs_gtk.inc：GtkMessageDialog +")
    lines.append(" * GtkFileChooserNative，4.6 上唯一可用的形态；GTK4 已没有同步的 run，")
    lines.append(" * 同样靠临时 GMainLoop 等 response）。四片手写实现都被本文件 #include 进")
    lines.append(" * 同一个翻译单元。P5 的音频 34 条是**显式缺席**：不写 GStreamer/ALSA")
    lines.append(" * （T237 裁决③），但按 adapter.h 的口径逐条给 -3 / 哨兵值——中性桩的")
    lines.append(" * return 0 在 audio_load 上会被壳当成「歌装上了」。其余 ABI 符号保持")
    lines.append(" * unsupported 中性桩（整数 0 / 指针 NULL / 空）。")
    lines.append(" * 生成方式：python3 scripts/gen-native-linux-gtk.py")
    lines.append(" *   解析源是 backends/native-common/adapter.h（保证签名与 ABI 头逐字一致）。")
    lines.append(" * 验证：真头编译由 scripts/gtk4-sysroot-check.sh 在本机做（私有 sysroot")
    lines.append(" * + 4.6 最低版本闸，该闸已写进下面的 prelude 而不只靠 -D）；假头语法与")
    lines.append(" * 纯逻辑判据见 scripts/mock-gtk-check.sh；画布像素 / 控件层结构 / 剪贴板")
    lines.append(" * 写读 / 对话框真跑的**真链接 + 真跑判据**见 scripts/canvas-pixel-check.sh。")
    lines.append(" * xvfb 真窗由 CI 的 linux-backend-link job 负责。")
    lines.append(" */")
    lines.append("")
    lines.append('#include "adapter.h"')
    lines.append("#include <string.h>")
    lines.append("#include <stdlib.h>")
    lines.append("")
    lines.append("#if defined(__GNUC__) || defined(__clang__)")
    lines.append("#pragma GCC diagnostic ignored \"-Wunused-parameter\"")
    lines.append("#pragma GCC diagnostic ignored \"-Wunused-function\"")
    lines.append("#endif")
    lines.append("")
    lines.append("/* moonbit.h 中 moonbit_bytes_t=uint8_t*、moonbit_string_t=uint16_t* 均")
    lines.append(" * 为指针，故 return 0 对全部非 void 返回类型均合法（指针→NULL，整数→0）。")
    lines.append(" * 桩体一律空/return 0；P3/P4 真实实现见下方。 */")
    lines.append("")
    lines.append(PREAMBLE)
    lines.append("")
    lines.append("/* 手写实现（同一翻译单元）。假头构建跳过：mock-gtk.h 里没有 cairo/")
    lines.append(" * pango/gdk-pixbuf，这几片的真实实现在那个构建里由文件末尾的同签名桩顶上。 */")
    lines.append("#ifndef MOONUI_MOCK_GTK")
    for rel in IMPL_FILES:
        lines.append('#include "%s"' % rel.rsplit("/", 1)[-1])
    lines.append("#endif")

    # REAL 表里写错的键会**静默**落回 stub（生成物照样编得过），所以这里先对账：
    # 表里每个键都必须在 adapter.h 里存在，否则点名退出。
    declared = set(d[1] for d in decls)
    unknown = sorted(set(REAL) - declared)
    if unknown:
        sys.stderr.write(
            "[gen] REAL 表里有 adapter.h 中不存在的符号（改了名？）：%s\n"
            % ", ".join(unknown)
        )
        sys.exit(1)

    real_count = 0
    stub_count = 0
    impl_count = 0
    absent_count = 0
    impl_stubs = []
    absent_header_done = False
    for ret, name, args in decls:
        if name in REAL:
            lines.append(REAL[name])
            lines.append("")
            real_count += 1
        elif name in impl_names:
            # 真实实现在手写实现文件里（widgets_gtk.inc / canvas_gtk.inc，已在上方
            # include）。假头构建里那几份被跳过，
            # 所以攒一条同签名桩，末尾统一放进 #ifdef MOONUI_MOCK_GTK。
            body = " { }" if ret == "void" else " { return 0; }"
            impl_stubs.append("%s %s(%s)%s" % (ret, name, args, body))
            impl_count += 1
        elif name in ABSENT:
            # 显式缺席：码按 adapter.h 的口径（不是中性桩的 0）。这批不依赖任何
            # 外部库，所以假头构建里照用，没有 MOONUI_MOCK_GTK 替身。
            if not absent_header_done:
                lines.append("")
                lines.append("/* ---- 本平台未实现（T235 P5）：码按 adapter.h 口径 ----")
                lines.append(" * 这些不是中性桩。中性桩 return 0，而 0 在 ABI 上多数是「成功」——")
                lines.append(" * 对「这侧根本没接」的功能，返 0 就是谎报（audio_load 返 0 会被壳")
                lines.append(" * 当成「歌装上了」，播放器画得出来却永远不出声）。码表与 Windows 半")
                lines.append(" * 的音频段逐条一致；壳把 -3 映射成 AudioError::Unsupported。")
                lines.append(" * 音频不在框架承诺范围（T237 裁决③），故这里不写 GStreamer/ALSA。 */")
                absent_header_done = True
            lines.append("%s %s(%s) {" % (ret, name, args))
            lines.append(ABSENT[name])
            lines.append("}")
            lines.append("")
            absent_count += 1
        else:
            if ret == "void":
                body = " { }"
            else:
                body = " { return 0; }"
            lines.append("%s %s(%s)%s" % (ret, name, args, body))
            stub_count += 1

    if impl_stubs:
        lines.append("")
        lines.append("#ifdef MOONUI_MOCK_GTK")
        lines.append("/* 假头构建专用：手写实现文件的替身，保住\"每个 ABI 符号都有定义\"。 */")
        lines.extend(impl_stubs)
        lines.append("#endif")

    out = sys.argv[1] if len(sys.argv) > 1 else OUT
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    sys.stderr.write(
        "[gen] real=%d impl=%d absent=%d stubs=%d -> %s\n"
        % (real_count, impl_count, absent_count, stub_count, out)
    )


if __name__ == "__main__":
    main()
