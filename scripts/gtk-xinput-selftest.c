/*
 * MoonUI · Linux/GTK4 后端（T235 P9）——**外部真实输入**判据。
 *
 * 为什么必须有这一份、而且不能并进 canvas-pixel-selftest.c：
 *   T235 P8 查实 GTK4 的公开头里**没有任何 GdkEvent 构造函数**
 *   （gdk_event_new / gdk_key_event_new / gdk_scroll_event_new 全无，
 *   gdk_display_put_event 自 4.10 起弃用且仍要一个既存事件），所以
 *   "在进程内合成一条真事件喂进去"没有公开路径。此前所有事件判据都是
 *   g_signal_emit_by_name 驱动的 GTK 信号，或 mock 层的纯逻辑对拍——
 *   它们证得了"回调接线对"，证不了"X11 上真按一颗 Tab 键，GTK 会不会
 *   把事件送到我们的 key controller、我们的 focus_tab_step 有没有真的
 *   把 GTK 默认遍历吞掉、滚轮 delta 是什么符号"。
 *   这一份由 scripts/gtk-xinput-check.sh 在 xvfb 里启动，另有
 *   scripts/gtk-xinput-helper.sh 用 xdotool 从**另一个进程**经 XTEST 发
 *   真键 / 真滚轮。两个进程靠 $MOONUI_XINPUT_DIR 下的 ready / done 两个
 *   文件握手，判据本体只泵 GTK 主循环、读 ABI 的事件账，不自己造事件。
 *
 * 判据能不能区分"真的按链遍历"和"GTK 自己按 z 序遍历"：能。控件按
 *   z 序 b1,b2,b3,entry 挂载，而 set_focus_chain 声明的是 b1,b3,entry。
 *   初始焦点在 b1，两次 Tab 之后按链应落在 entry，按 GTK 默认 z 序会落在
 *   b3。判据在主循环里**每圈采样** focused_control 记成序列（不依赖 key
 *   回调有没有触发：ISO_Left_Tab 不在词表里，Shift+Tab 那条 keyup 可能
 *   根本没有回调），断言序列里出现 b1→b3→entry→b3 且**从不出现 b2**。
 *
 * 证据边界（别把这里的绿读成别的）：
 *   - 只在 X11 / xvfb 上成立；Wayland 没有 XTEST，脚本会 SKIP（CI 下 FAIL）。
 *   - 滚轮只钉「两次方向相反、dx=0、dy 非 0」和实测值，**不钉绝对值**：
 *     gdk_scroll_event_get_unit / GdkScrollUnit 是 GTK 4.8 起才有，而本后端
 *     最低口径是 4.6，单位换算究竟该不该乘倍数仍是 TODO T235 P8 的未决项。
 *   - 真打字只验 ASCII 'a'/'b' 落进 GtkEntry；输入法组合相位（T90）没验。
 *   - 这里读的是适配器自己的事件账（ABI getter），不是 MoonBit 侧 Core
 *     的事件队列；那条链由 native_test.mbt / gallery 的链接闸另证。
 *
 * 用法：由 scripts/gtk-xinput-check.sh 编译并驱动，不单独运行。
 *   未设 MOONUI_XINPUT_DIR 时是「无外部输入」自检模式：判据应当全红
 *   （用来证明这些判据不是恒绿，见 check.sh 的负控制说明）。
 */
#include "adapter.h"

#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* libmoonbitrun.o 不导出 moonbit_make_bytes，而生成物里的 moonui_bytes_of
 * 用它造 Bytes。与 canvas-pixel-selftest.c 同形的替身：对象头
 * { int32_t rc; uint32_t meta; } 必须逐字节一致，Moonbit_array_length 才
 * 读得到长度。判据里所有 Bytes 都按 (ptr,len) 比，不靠 NUL 结尾。 */
moonbit_bytes_t moonbit_make_bytes(int32_t size, int value) {
  struct moonbit_object *hdr;
  uint8_t *payload;
  if (size < 0) size = 0;
  hdr = (struct moonbit_object *)malloc(sizeof(struct moonbit_object) + (size_t)size);
  if (hdr == NULL) abort();
  hdr->rc = (int32_t)(((uint32_t)1 << MOONBIT_RC_COUNT_SHIFT) |
                      (uint32_t)moonbit_BLOCK_KIND_VAL_ARRAY);
  hdr->meta = (uint32_t)size;
  payload = (uint8_t *)(hdr + 1);
  memset(payload, value, (size_t)size);
  return payload;
}

static int g_pass = 0;
static int g_fail = 0;

static void ok(const char *name) {
  g_pass++;
  printf("PASS  %s\n", name);
}

static void bad(const char *name, const char *detail) {
  g_fail++;
  printf("FAIL  %s  (%s)\n", name, detail);
}

static void finish(const char *name, int fail_before) {
  if (g_fail == fail_before) ok(name);
}

/* ---- 事件账：回调里当场读 ABI 的四个 getter，不缓存第二次读取的结果 ---- */
typedef struct {
  char name[32];
  int down;
  int mods;
  moonui_ptr target;
} KeyRec;

typedef struct {
  int code;
  int dx;
  int dy;
  moonui_ptr target;
} MouseRec;

#define MAX_REC 96
static KeyRec g_keys[MAX_REC];
static int g_key_n = 0;
static MouseRec g_mice[MAX_REC];
static int g_mouse_n = 0;
static moonui_ptr g_focus_seq[MAX_REC];
static int g_focus_n = 0;
static moonui_ptr g_win = 0;

static char *bytes_dup(moonbit_bytes_t b) {
  int32_t n;
  char *s;
  if (b == NULL) return NULL;
  n = (int32_t)Moonbit_array_length(b);
  s = (char *)malloc((size_t)n + 1);
  if (s == NULL) return NULL;
  if (n > 0) memcpy(s, b, (size_t)n);
  s[n] = '\0';
  return s;
}

static void on_key(void *cl) {
  char *s;
  moonbit_bytes_t b;
  (void)cl;
  if (g_key_n >= MAX_REC) return;
  b = moonui_native_key_name();
  s = bytes_dup(b);
  memset(&g_keys[g_key_n], 0, sizeof(g_keys[0]));
  if (s != NULL) {
    strncpy(g_keys[g_key_n].name, s, sizeof(g_keys[0].name) - 1);
    free(s);
  }
  g_keys[g_key_n].down = moonui_native_key_is_down();
  g_keys[g_key_n].mods = moonui_native_key_modifiers();
  g_keys[g_key_n].target = moonui_native_key_target();
  g_key_n++;
}

static void on_mouse(void *cl) {
  int64_t d;
  (void)cl;
  if (g_mouse_n >= MAX_REC) return;
  memset(&g_mice[g_mouse_n], 0, sizeof(g_mice[0]));
  g_mice[g_mouse_n].code = moonui_native_mouse_kind_button();
  d = moonui_native_mouse_delta();
  g_mice[g_mouse_n].dx = (int32_t)(d >> 32);
  g_mice[g_mouse_n].dy = (int32_t)(d & 0xFFFFFFFFLL);
  g_mice[g_mouse_n].target = moonui_native_mouse_target();
  g_mouse_n++;
}

static moonui_ptr focus_now(void) { return moonui_native_focused_control(g_win); }

static void focus_sample(moonui_ptr f) {
  if (f == 0) return;
  if (g_focus_n > 0 && g_focus_seq[g_focus_n - 1] == f) return;
  if (g_focus_n >= MAX_REC) return;
  g_focus_seq[g_focus_n++] = f;
}

static void print_focus_seq(char *buf, size_t cap, const moonui_ptr *seq, int n) {
  size_t used = 0;
  int i;
  buf[0] = '\0';
  for (i = 0; i < n && used + 24 < cap; ++i) {
    used += (size_t)snprintf(buf + used, cap - used, "%s%p", i ? "→" : "",
                             (void *)(uintptr_t)seq[i]);
  }
}

static int file_exists(const char *dir, const char *leaf) {
  char p[512];
  FILE *f;
  snprintf(p, sizeof(p), "%s/%s", dir, leaf);
  f = fopen(p, "r");
  if (f == NULL) return 0;
  fclose(f);
  return 1;
}

static void touch_ready(const char *dir) {
  char p[512];
  FILE *f;
  snprintf(p, sizeof(p), "%s/ready", dir);
  f = fopen(p, "w");
  if (f == NULL) {
    bad("外部输入：握手", "写 ready 文件失败，helper 会等到超时");
    return;
  }
  fputs("ready\n", f);
  fclose(f);
}

/* ① Tab 真派发：焦点按声明链走，不是 GTK 默认 z 序。 */
static void t_tab_chain(moonui_ptr b1, moonui_ptr b2, moonui_ptr b3, moonui_ptr entry) {
  const char *name = "P9 外部输入：Tab 按声明链遍历（不是 GTK 默认 z 序）";
  int before = g_fail;
  char got[512], want[256];
  moonui_ptr expect[4];
  int i, seen_b2 = 0;

  print_focus_seq(got, sizeof(got), g_focus_seq, g_focus_n);
  expect[0] = b1; expect[1] = b3; expect[2] = entry; expect[3] = b3;
  print_focus_seq(want, sizeof(want), expect, 4);
  for (i = 0; i < g_focus_n; ++i) if (g_focus_seq[i] == b2) seen_b2 = 1;

  if (g_focus_n < 4) {
    char d[1200];
    snprintf(d, sizeof(d), "焦点变化只有 %d 次（期望 4 次）：实际 [%s]，期望 [%s]。"
             "xdotool 的键没到窗口？看 helper.log 与 windowfocus", g_focus_n, got, want);
    bad(name, d);
  } else if (g_focus_seq[0] != b1 || g_focus_seq[1] != b3 ||
             g_focus_seq[2] != entry || g_focus_seq[3] != b3) {
    char d[1200];
    snprintf(d, sizeof(d), "焦点序列不是声明链：实际 [%s]，期望 [%s]", got, want);
    bad(name, d);
  }
  if (seen_b2) {
    bad(name, "焦点序列里出现了 b2（只挂在 z 序、不在声明链里）——"
              "key-pressed 返 TRUE 没有吞掉 GTK 默认遍历，或链根本没设上");
  }
  finish(name, before);
}

/* ② 真键盘到账：键名 / 按下抬起 / Shift 修饰位 / 归属窗口。 */
static void t_real_keys(void) {
  const char *name = "P9 外部输入：真键盘事件到账（键名 + 按下抬起 + Shift 位 + 归属）";
  int before = g_fail;
  int i, tab_down = 0, tab_up = 0, shift_a = 0, wrong_target = 0;
  char d[256];

  for (i = 0; i < g_key_n; ++i) {
    if (strcmp(g_keys[i].name, "Tab") == 0) {
      if (g_keys[i].down) tab_down++; else tab_up++;
    }
    /* xdotool key shift+a 的物理 keyval 是 'A'，词表折成 'a'，mods 带 bit2 */
    if (strcmp(g_keys[i].name, "a") == 0 && (g_keys[i].mods & 4) != 0) shift_a++;
    if (g_keys[i].target != g_win) wrong_target++;
  }
  if (g_key_n < 8) {
    snprintf(d, sizeof(d), "只收到 %d 条键盘通知（期望 >= 8：两次 Tab + a/b 打字 + shift+a 各按下抬起）", g_key_n);
    bad(name, d);
  }
  if (tab_down < 2 || tab_up < 2) {
    snprintf(d, sizeof(d), "Tab 的按下/抬起不齐：down=%d up=%d（期望各 >= 2）", tab_down, tab_up);
    bad(name, d);
  }
  if (shift_a == 0) bad(name, "没读到带 Shift 修饰位的 'a'（期望至少 1 条 mods&4 != 0）");
  if (wrong_target != 0) {
    snprintf(d, sizeof(d), "%d 条键盘通知的 target 不是本窗口（期望 0）", wrong_target);
    bad(name, d);
  }
  finish(name, before);
}

/* ③ 滚轮：方向相反、dx=0、dy 非 0；实测值打 NOTE 供后续定单位倍数。 */
static void t_scroll(void) {
  const char *name = "P9 外部输入：滚轮 delta 方向相反且量得到";
  int before = g_fail;
  int i, n = 0, a = -1, b = -1, dx_bad = 0;
  char d[256];

  for (i = 0; i < g_mouse_n; ++i) {
    if (g_mice[i].code != 4 * 8 + 0) continue; /* kind 4 滚轮 */
    n++;
    /* 用 -1 当哨兵，别用 0：第一条鼠标通知恰好就是滚轮时（xdotool 的
     * mousemove 没送到 motion 控制器），索引 0 会被误判成"还没赋值"。 */
    if (a < 0) a = i; else if (b < 0) b = i;
    if (g_mice[i].dx != 0) dx_bad++;
  }
  if (n < 2) {
    snprintf(d, sizeof(d), "只收到 %d 条 kind=4 滚轮事件（期望 >= 2：click 4 与 click 5）", n);
    bad(name, d);
  } else {
    int dy1 = g_mice[a].dy, dy2 = g_mice[b].dy;
    printf("NOTE  P9 滚轮实测：click4 dy=%d dx=%d / click5 dy=%d dx=%d"
           "（单位与倍数仍未定，见 TODO T235 P8⑤）\n",
           dy1, g_mice[a].dx, dy2, g_mice[b].dx);
    if (dy1 == 0 || dy2 == 0) {
      snprintf(d, sizeof(d), "有一条滚轮 dy=0（期望两条都非 0）：%d 与 %d", dy1, dy2);
      bad(name, d);
    }
    if ((dy1 > 0 && dy2 > 0) || (dy1 < 0 && dy2 < 0)) {
      snprintf(d, sizeof(d), "上下滚的 dy 同号（期望符号相反）：%d 与 %d", dy1, dy2);
      bad(name, d);
    }
    if (dx_bad != 0) {
      snprintf(d, sizeof(d), "%d 条滚轮事件带了非零 dx（垂直滚轮期望 dx=0）", dx_bad);
      bad(name, d);
    }
  }
  finish(name, before);
}

/* ④ 真打字：ASCII 两键经 XTEST 落进 GtkEntry，读 ABI 的 Bytes（含长度）。 */
static void t_real_typing(moonui_ptr entry) {
  const char *name = "P9 外部输入：真打字进 GtkEntry（Bytes 内容与长度都对）";
  int before = g_fail;
  moonbit_bytes_t b = moonui_native_widget_text(entry);
  char *got = bytes_dup(b);
  int n = (b == NULL) ? -1 : (int)Moonbit_array_length(b);
  char d[256];

  if (got == NULL) {
    bad(name, "widget_text 返回 NULL（ABI 要给空 Bytes，不能给空指针）");
    return;
  }
  if (strcmp(got, "ab") != 0 || n != 2) {
    snprintf(d, sizeof(d), "期望 [ab] / 2 字节，实际 [%s] / %d 字节", got, n);
    bad(name, d);
  }
  free(got);
  finish(name, before);
}

int main(void) {
  const char *dir = getenv("MOONUI_XINPUT_DIR");
  const char *title = "moonui-xinput";
  moonui_ptr b1, b2, b3, entry;
  GtkWidget *gw;
  char ids[192], d[256];
  int scale, i, ready = 0;
  int64_t waited = 0;
  moonui_ptr last = 0;

  if (moonui_native_init() != 0) {
    bad("P9 外部输入：gtk_init", "gtk_init 失败（xvfb / DISPLAY 没起来）");
    printf("\n[gtk-xinput] pass=%d fail=%d\n", g_pass, g_fail);
    return 1;
  }
  g_win = moonui_native_window_new(title, (int)strlen(title), 320, 240);
  b1 = moonui_native_widget_new(1, "1", 1);
  b2 = moonui_native_widget_new(1, "2", 1);
  b3 = moonui_native_widget_new(1, "3", 1);
  entry = moonui_native_widget_new(2, "", 0);
  if (g_win == 0 || b1 == 0 || b2 == 0 || b3 == 0 || entry == 0) {
    bad("P9 外部输入：建窗与控件", "窗口或四只控件造不出来");
    return 1;
  }
  scale = moonui_native_window_dpi(g_win) / 96;
  if (scale < 1) scale = 1;
  /* z 序 b1,b2,b3,entry（四只都挂上），声明链却是 b1,b3,entry。 */
  moonui_native_control_attach(g_win, b1);
  moonui_native_control_attach(g_win, b2);
  moonui_native_control_attach(g_win, b3);
  moonui_native_control_attach(g_win, entry);
  moonui_native_control_set_bounds(b1, 20 * scale, 20 * scale, 100 * scale, 30 * scale);
  moonui_native_control_set_bounds(b2, 20 * scale, 60 * scale, 100 * scale, 30 * scale);
  moonui_native_control_set_bounds(b3, 20 * scale, 100 * scale, 100 * scale, 30 * scale);
  moonui_native_control_set_bounds(entry, 20 * scale, 140 * scale, 120 * scale, 30 * scale);
  snprintf(ids, sizeof(ids), "%llu %llu %llu",
           (unsigned long long)(uintptr_t)b1,
           (unsigned long long)(uintptr_t)b3,
           (unsigned long long)(uintptr_t)entry);
  if (moonui_native_set_focus_chain(g_win, ids, (int)strlen(ids)) != 0)
    bad("P9 外部输入：set_focus_chain", "声明链没设上（期望返回 0）");
  if (moonui_native_on_key(on_key, NULL) != 0)
    bad("P9 外部输入：on_key", "键盘回调没注册上（期望返回 0）");
  if (moonui_native_on_mouse(on_mouse, NULL) != 0)
    bad("P9 外部输入：on_mouse", "鼠标回调没注册上（期望返回 0）");

  gw = (GtkWidget *)(uintptr_t)g_win;
  moonui_native_window_show(g_win);
  for (i = 0; i < 400; ++i) {
    if (gtk_widget_get_mapped(gw) && gtk_widget_get_width(gw) > 0) break;
    g_main_context_iteration(NULL, FALSE);
    g_usleep(5000);
  }
  if (!gtk_widget_get_mapped(gw)) {
    bad("P9 外部输入：窗口上屏", "present 之后 2s 内没映射（xvfb / WM 没起来）");
    printf("\n[gtk-xinput] pass=%d fail=%d\n", g_pass, g_fail);
    return 1;
  }
  /* 真 GTK 对象上摆初始焦点；之后的每一次变化都由外部 Tab 驱动。 */
  gtk_widget_grab_focus((GtkWidget *)(uintptr_t)b1);
  g_focus_n = 0;
  focus_sample(focus_now());

  if (dir == NULL) {
    /* 无外部输入自检：helper 不在，所有基于事件账的判据必须红。
     * check.sh 的 N3 负控制就跑这一路，用来证明判据不是恒绿。 */
    printf("NOTE  P9 无外部输入自检（MOONUI_XINPUT_DIR 未设）：以下判据应当全红\n");
  } else {
    touch_ready(dir);
  }

  /* 有界泵：等 helper 的 done，最多 12s。每圈采样一次焦点（不依赖 key
   * 回调是否触发——ISO_Left_Tab 不在词表，Shift+Tab 的 keyup 可能根本没回调）。 */
  while (waited < 12000) {
    moonui_ptr f;
    g_main_context_iteration(NULL, FALSE);
    f = focus_now();
    if (f != last) { focus_sample(f); last = f; }
    if (dir != NULL && file_exists(dir, "done")) { ready = 1; break; }
    if (dir == NULL && waited > 1200) break;
    g_usleep(5000);
    waited += 5;
  }
  if (dir != NULL && !ready) {
    snprintf(d, sizeof(d), "helper 在 %lldms 内没写 done（看 helper.log：xdotool / 窗口焦点）",
             (long long)waited);
    bad("P9 外部输入：握手", d);
  }
  /* done 之后多泵几圈，让最后一颗事件的回调与焦点变化都落账。 */
  for (i = 0; i < 40; ++i) {
    moonui_ptr f;
    g_main_context_iteration(NULL, FALSE);
    f = focus_now();
    if (f != last) { focus_sample(f); last = f; }
    g_usleep(2000);
  }

  t_tab_chain(b1, b2, b3, entry);
  t_real_keys();
  t_scroll();
  t_real_typing(entry);

  {
    char got[512];
    print_focus_seq(got, sizeof(got), g_focus_seq, g_focus_n);
    printf("NOTE  P9 实测：scale=%d 焦点序列=[%s] 键盘通知=%d 鼠标通知=%d\n",
           scale, got, g_key_n, g_mouse_n);
  }

  moonui_native_window_destroy(g_win);
  printf("\n[gtk-xinput] pass=%d fail=%d\n", g_pass, g_fail);
  return g_fail > 0 ? 1 : 0;
}
