/* MoonUI · Linux/GTK4 · 自绘输入法**真键路由**闸（T392 ①的另半）。
 *
 * 证什么：X11 真键 → `moonui_key_pressed` → `moonui_canvas_ime_filter_key`
 * → `gtk_im_context_filter_keypress` → preedit/commit 信号 → 代理镜像
 * （`moonui_canvas_ime_text/marked/caret`）。这是 T392 真键路由那条链，判据
 * 此前只在 `canvas-shared` 用**注入**（`canvas_ime_compose_in_window` /
 * `commit_in_window`）验代理逻辑，不覆盖 filter→IM→信号→镜像这一段。
 *
 * 为什么能确定性：强制 `GTK_IM_MODULE=gtk-im-context-simple`（GTK 内置，
 * 不依赖 fcitx/ibus 状态）。simple 模块对可打印 ASCII 键**逐个经 commit
 * 信号提交**（无 preedit），所以注入 "abc" 后镜像必为 text="abc" marked=""
 * caret=3——与系统输入法当前是什么模式无关（fcitx 拼音态会组 "nihao"→
 * "你好"，不可作为判据；simple 是确定性的）。判据不依赖任何 IM 守护进程。
 *
 * 环境边界（如实 SKIP，SKIP ≠ PASS）：
 *  - 本机会话默认 Wayland，GTK 挑 Wayland 后端没有 XID 可投键，强制
 *    `GDK_BACKEND=x11`（XWayland）；XWayland 不可用则 gtk_init 失败 → SKIP。
 *  - 键没到窗口（诊断控制器一枚没收到）→ 环境没把键送进来，SKIP——这只
 *    证明不了链；键到了而镜像没更新才是**真回归**（FAIL）。
 *  - libXtst 缺失由 scripts/gtk-ime-check.sh 在**构建**阶段 SKIP。
 *
 * 与 gtk-xinput（T235 P9）的分工：那一闸用 xdotool 从另一进程发键、验 Tab
 * 焦点链/滚轮；本闸**同进程** XTest 直发键、验自绘输入法真键路由。两条都
 * 只 X11 有效，各自 SKIP 缺件。
 */
#include <gtk/gtk.h>
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "adapter.h"

/* XTest 无头文件（发行版常只有 libXtst.so.6，没有 libXtst.so），手动声明。 */
extern int XTestFakeKeyEvent(Display *dpy, unsigned int keycode,
                             int is_press, unsigned long delay);
extern int XTestFakeButtonEvent(Display *dpy, unsigned int button,
                                int is_press, unsigned long delay);
extern int XTestFakeMotionEvent(Display *dpy, int screen, int x, int y,
                                unsigned long delay);

static int g_pass = 0;
static int g_fail = 0;
static int g_skip = 0;

static void ok(const char *name) {
  g_pass++;
  printf("PASS  %s\n", name);
}
static void bad(const char *name, const char *detail) {
  g_fail++;
  printf("FAIL  %s  (%s)\n", name, detail);
}
static void skip(const char *name, const char *why) {
  g_skip++;
  printf("SKIP  %s  (%s)\n", name, why);
}

/* libmoonbitrun.o 不导出 moonbit_make_bytes / incref / decref：补替身（与
 * scripts/canvas-pixel-selftest.c 同款，布局逐字节一致）。 */
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
void moonbit_incref(void *obj) { (void)obj; }
void moonbit_decref(void *obj) { (void)obj; }

static void pump_gtk(int ms) {
  GMainContext *mc = g_main_context_default();
  gint64 end = g_get_monotonic_time() + (gint64)ms * 1000;
  while (g_get_monotonic_time() < end) {
    while (g_main_context_pending(mc))
      g_main_context_iteration(mc, FALSE);
    g_usleep(5000);
  }
}

static int g_xerr = 0;
static int xerr_handler(Display *d, XErrorEvent *e) {
  (void)d;
  g_xerr++;
  fprintf(stderr, "  [xerr] opcode=%d code=%d id=0x%lx\n",
          e->request_code, e->error_code, (unsigned long)e->resourceid);
  return 0;
}

/* 诊断键控制器：数「键到没到窗口」。一枚都没到 = 环境没把键送进来，SKIP；
 * 到了而镜像没更新 = 真回归，FAIL。 */
static int g_keys_seen = 0;
static gboolean diag_key(GtkEventControllerKey *c, guint keyval, guint keycode,
                         GdkModifierType state, gpointer data) {
  (void)c; (void)keyval; (void)keycode; (void)state; (void)data;
  g_keys_seen++;
  return FALSE;
}

static void send_key(Display *dpy, KeySym ks) {
  KeyCode kc = XKeysymToKeycode(dpy, ks);
  if (kc == 0) return;
  XTestFakeKeyEvent(dpy, kc, 1, 0);
  XFlush(dpy);
  pump_gtk(80);
  XTestFakeKeyEvent(dpy, kc, 0, 0);
  XFlush(dpy);
  pump_gtk(80);
}

/* 读镜像进栈缓冲：moonbit_bytes_t 只保证 `meta` 个字节有效（不保证 NUL），
 * 按 Moonbit_array_length 拷长度再补 NUL。 */
static void snapshot(moonui_ptr win, char *text, int text_sz,
                     char *marked, int marked_sz, int *caret) {
  moonbit_bytes_t bt = moonui_canvas_ime_text(win);
  moonbit_bytes_t bm = moonui_canvas_ime_marked(win);
  int nt = bt ? (int)Moonbit_array_length(bt) : 0;
  int nm = bm ? (int)Moonbit_array_length(bm) : 0;
  if (nt > text_sz - 1) nt = text_sz - 1;
  if (nm > marked_sz - 1) nm = marked_sz - 1;
  if (nt > 0 && bt) memcpy(text, bt, (size_t)nt);
  text[nt] = '\0';
  if (nm > 0 && bm) memcpy(marked, bm, (size_t)nm);
  marked[nm] = '\0';
  *caret = moonui_canvas_ime_caret(win);
}

static void t_t392_ime_key_route(void) {
  const char *name = "T392 自绘输入法真键路由：filter→GtkIMContext→信号→镜像（simple 模块）";
  moonui_ptr win;
  GtkWidget *gw;
  GdkSurface *surface;
  Display *dpy;
  Window xid;
  char text[256], marked[256];
  int caret;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器 / XWayland 不可用）");
    return;
  }
  dpy = XOpenDisplay(NULL);
  if (!dpy) {
    skip(name, "XOpenDisplay 失败（无 X11 / XWayland）");
    return;
  }
  XSetErrorHandler(xerr_handler);
  win = moonui_native_window_new("t392-ime", 9, 320, 240);
  if (!win) {
    bad(name, "window_new 返 0");
    return;
  }
  gw = (GtkWidget *)(uintptr_t)win;
  /* 空窗口没内容可画，XWayland 下可能永远不 map（帧钟不来）；给个 label
   * 内容，窗口才有东西可 map（与探针同款，内容不影响键路由）。 */
  gtk_window_set_child(GTK_WINDOW(gw), gtk_label_new("ime route"));
  {
    GtkEventController *diag = gtk_event_controller_key_new();
    gtk_widget_add_controller(gw, diag);
    g_signal_connect(diag, "key-pressed", G_CALLBACK(diag_key), NULL);
  }
  gtk_window_present(GTK_WINDOW(gw));
  pump_gtk(400);
  for (int i = 0; i < 60 && !gtk_widget_get_mapped(gw); i++) pump_gtk(50);
  if (!gtk_widget_get_mapped(gw)) {
    moonui_native_window_destroy(win);
    skip(name, "窗口 3s 内没 mapped（XWayland 没起来？）");
    return;
  }
  surface = gtk_native_get_surface(GTK_NATIVE(gw));
  if (!surface) {
    moonui_native_window_destroy(win);
    skip(name, "窗口没有 GDK surface");
    return;
  }
  xid = GDK_SURFACE_XID(surface);
  XMapWindow(dpy, xid);
  XSync(dpy, False);
  for (int i = 0; i < 100; i++) {
    XWindowAttributes attrs;
    if (XGetWindowAttributes(dpy, xid, &attrs) && attrs.map_state == IsViewable)
      break;
    pump_gtk(50);
  }
  /* 焦点：先点一下窗口中心（Wayland 合成器按点击给焦点），再 XSetInputFocus
   * 兜底。XWayland 内 XSetInputFocus 决定哪只 X 窗口收键，但 Wayland 键盘焦点
   * 得先落在 XWayland surface 上——点击才能换来。本桌面（niri）指针路由到顶层
   * surface（`T355`），点击未必落到本窗：重试若干轮，直到键真到窗口；一轮都
   * 没到 = 环境不给，SKIP。 */
  {
    int tries;
    int got = 0;
    for (tries = 0; tries < 12 && !got; tries++) {
      /* 先把自己抬到 X 栈顶 + 再 present 一次：合成器给键盘焦点看「谁是最新
       * 交互的表面」，raise/present 是最近似「用户点了它」的一步。 */
      XRaiseWindow(dpy, xid);
      XFlush(dpy);
      gtk_window_present(GTK_WINDOW(gw));
      pump_gtk(120);
      XTestFakeMotionEvent(dpy, 0, 160, 120, 0);
      XFlush(dpy);
      pump_gtk(80);
      XTestFakeButtonEvent(dpy, 1, 1, 0);
      XFlush(dpy);
      pump_gtk(50);
      XTestFakeButtonEvent(dpy, 1, 0, 0);
      XFlush(dpy);
      pump_gtk(80);
      XSetInputFocus(dpy, xid, RevertToParent, CurrentTime);
      XFlush(dpy);
      pump_gtk(120);
      g_keys_seen = 0;
      send_key(dpy, XK_z);
      if (g_keys_seen > 0) got = 1;
    }
    if (!got) {
      moonui_native_window_destroy(win);
      skip(name, "12 轮点击+focus 后键仍未到窗口（合成器不给键盘焦点）");
      return;
    }
  }

  /* 负控制：未 ime_begin 时注入键，镜像必须不动（ime_active 闸着）。
   * 键能不能到已经由上面 12 轮重试保证，这里只证「闸」。 */
  g_keys_seen = 0;
  send_key(dpy, XK_a);
  snapshot(win, text, sizeof text, marked, sizeof marked, &caret);
  if (text[0] != '\0' || marked[0] != '\0') {
    bad(name, "未 begin 时键竟进了镜像（ime_active 闸失效）");
    moonui_native_window_destroy(win);
    return;
  }
  if (g_keys_seen == 0) {
    moonui_native_window_destroy(win);
    skip(name, "焦点又丢了（上一轮还在，这一轮键没到）");
    return;
  }

  /* 真链：begin（激活 GtkIMContext）→ 注入 "abc" → simple 模块逐键 commit
   * 信号 → 镜像。 */
  if (moonui_canvas_ime_begin(win, 0, 0, 10, 10, 16) != 0) {
    bad(name, "ime_begin 返非 0（代理没起来）");
    moonui_native_window_destroy(win);
    return;
  }
  pump_gtk(300); /* 让 IM context 消化 focus_in */
  snapshot(win, text, sizeof text, marked, sizeof marked, &caret);
  if (text[0] != '\0' || marked[0] != '\0') {
    bad(name, "begin 后镜像应空（残留上一轮？）");
  }
  g_keys_seen = 0;
  send_key(dpy, XK_a);
  send_key(dpy, XK_b);
  send_key(dpy, XK_c);
  snapshot(win, text, sizeof text, marked, sizeof marked, &caret);
  if (g_keys_seen == 0) {
    moonui_canvas_ime_end(win);
    moonui_native_window_destroy(win);
    skip(name, "注入的键没到窗口（环境没把键送来）");
    return;
  }
  if (strcmp(text, "abc") != 0 || marked[0] != '\0' || caret != 3) {
    char d[700];
    snprintf(d, sizeof d, "镜像 text=\"%s\" marked=\"%s\" caret=%d，期望 \"abc\"/\"\"/3",
             text, marked, caret);
    bad(name, d);
  } else {
    /* 到这里 PASS：键到、IM 吞、信号写镜像，整条链成立。 */
    ok(name);
  }
  moonui_canvas_ime_end(win);
  moonui_native_window_destroy(win);
}

int main(void) {
  /* 本机会话默认 Wayland：GTK 挑 Wayland 后端就没有 XID 可投键。强制 X11
   * 后端（XWayland），键才能落在 GDK 的 X 事件流里。必须在 gtk_init 前。 */
  setenv("GDK_BACKEND", "x11", 1);
  /* 确定性输入法：GTK 内置 simple 模块，逐个提交可打印 ASCII，不依赖
   * fcitx/ibus 当前状态（拼音态会组词，不可判据）。 */
  setenv("GTK_IM_MODULE", "gtk-im-context-simple", 1);

  t_t392_ime_key_route();

  printf("[gtk-ime] pass=%d fail=%d skip=%d\n", g_pass, g_fail, g_skip);
  if (g_fail > 0) {
    printf("[gtk-ime] 有判据红——本闸按 FAIL 收尾\n");
    return 1;
  }
  /* SKIP 不算 PASS：判据没跑过。但缺件是环境，进程返 0（check.sh 在 CI 下
   * 才把 SKIP 升级成 FAIL，与其它 Linux 闸同一条纪律）。 */
  return 0;
}
