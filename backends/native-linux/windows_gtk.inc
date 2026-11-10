/* =========================================================================
 * T235 P6-6：窗口状态与尺寸下限（第十二片 IMPL_FILES）
 *
 * 九条 ABI：window_set_min_size / window_min_size / window_set_resizable /
 *          window_set_fullscreen / window_set_minimized /
 *          window_set_maximized / window_state / window_is_key /
 *          request_window_close。
 *
 * 形态由 2026-11-10 的 /tmp 探针（moonui-p66-probe{,2}.c，真 GTK 4.24.1 /
 * GdkMacosDisplay、4.6 最低版本宏下编译）实测定下，不是照 mac 抄：
 *   ① set_resizable / set_decorated / size_request / maximize+is_maximized
 *      都是真 set→get 往返；present 之后 mapped=1 / is_active=1。
 *   ② 两只窗 present A → active(A)=1,active(B)=0；present B → 0/1；
 *      present A again → 1/0。所以 window_is_key 的焦点 A/B 能真跑。
 *   ③ size_request 清限制要用 -1：set(0,0) 会把窗口钳成 0x0，而契约里
 *      的「传 0 = 清掉限制」要先转成 -1（读回 -1 再转成打包的 0）。
 *   ④ **unfullscreen 之后 is_fullscreen 仍读 1**（泵 400 / 1600 轮都不回落，
 *      Quartz 侧还报 _gdk_macos_surface_update_fullscreen_state 断言）；
 *      minimize / unminimize 的 mapped / active 全不变。也就是这两组状态
 *      在本机私有运行时里**读不回**，判据只能验「真 API 被调用 + 属性往返」，
 *      状态真生效归 CI 的 4.6 / X11 + xvfb，不能拿本机恒 1 当绿。
 *
 * 证据边界：4.6 真头里这些 API 全在（gtkwindow.h / gdktoplevel.h /
 * gtkwidget.h），但本机真跑的是 4.24.1 / Quartz；minimized 位、全屏回落、
 * Wayland 下的窗口位置都不由本机证明。
 *
 * 本片**不碰**另外 14 条窗口 ABI（position / screen_* / titlebar_style /
 * drag_band / traffic_light / live_resize / 各类 probe）：GTK4 4.6 没有
 * gtk_window_move / gdk_monitor_get_workarea，红绿灯与拖动带是 mac/Win32
 * 专属。更关键的是它们多数是**打包坐标的 getter**，契约要求兜底而不是错误码
 * （adapter.h:214-217 明写 0 尺寸会让 Window::center 把窗口堆到左上角），
 * 逐条改成 -3 类缺席码会直接破坏 Core 摆位。它们的口径要单独定一片，
 * 本片只在生成器头注与 TODO 落地注里把「有意不接」记成可验的账。
 * ========================================================================= */

/* 内部帮手一律 static：生成器只把**非 static** 的 moonui_* 定义认作 ABI 符号。
 * 只认我们自己登记过的窗口——外面随手造的 GtkWindow 不归这条 ABI 管。 */
static GtkWidget *moonui_p66_win(moonui_ptr w) {
  GtkWidget *win = (GtkWidget *)(uintptr_t)w;
  if (win == NULL || moonui_win_slot_of(win) == NULL) return NULL;
  return win;
}

/* 客户区最小尺寸（§12），物理像素；width/height <= 0 = 清掉限制。
 * GTK4 没有「窗口级最小尺寸」这个独立开关，唯一对位是 widget 的 size
 * request，单位是**逻辑点**，所以按 set_content_size 同一套 scale 换算
 * （prelude 的 moonui_scale_of，T241 已把 NULL 与 display 口径统一）。
 * 与 mac 的 contentMinSize / Win32 的 ptMinTrackSize 的差别：GTK4 把
 * headerbar 也算在 window widget 里，所以这里的下限含标题栏那一行；
 * 契约要的是客户区，这个差在装了菜单栏的窗口上会多一行，如实留着。 */
void moonui_native_window_set_min_size(moonui_ptr w, int width, int height) {
  GtkWidget *win = moonui_p66_win(w);
  int scale, wpt, hpt;
  if (win == NULL) return;
  scale = moonui_scale_of(win);
  wpt = width <= 0 ? -1 : (int)llround((double)width / scale);
  hpt = height <= 0 ? -1 : (int)llround((double)height / scale);
  gtk_widget_set_size_request(win, wpt, hpt);
}

/* 读回最小尺寸，打包 (width, height)，物理像素。GTK 用 -1 表示无限制，
 * 契约用 0，两者在这里对齐。 */
int64_t moonui_native_window_min_size(moonui_ptr w) {
  GtkWidget *win = moonui_p66_win(w);
  int mw = -1, mh = -1, scale;
  if (win == NULL) return moonui_pack2(0, 0);
  gtk_widget_get_size_request(win, &mw, &mh);
  scale = moonui_scale_of(win);
  if (mw < 0) mw = 0;
  if (mh < 0) mh = 0;
  return moonui_pack2((int)llround((double)mw * scale),
                      (int)llround((double)mh * scale));
}

void moonui_native_window_set_resizable(moonui_ptr w, int resizable) {
  GtkWidget *win = moonui_p66_win(w);
  if (win != NULL) gtk_window_set_resizable(GTK_WINDOW(win), resizable != 0);
}

void moonui_native_window_set_fullscreen(moonui_ptr w, int fullscreen) {
  GtkWidget *win = moonui_p66_win(w);
  if (win == NULL) return;
  if (fullscreen) gtk_window_fullscreen(GTK_WINDOW(win));
  else gtk_window_unfullscreen(GTK_WINDOW(win));
}

void moonui_native_window_set_minimized(moonui_ptr w, int minimized) {
  GtkWidget *win = moonui_p66_win(w);
  if (win == NULL) return;
  if (minimized) gtk_window_minimize(GTK_WINDOW(win));
  else gtk_window_unminimize(GTK_WINDOW(win));
}

void moonui_native_window_set_maximized(moonui_ptr w, int maximized) {
  GtkWidget *win = moonui_p66_win(w);
  if (win == NULL) return;
  if (maximized) gtk_window_maximize(GTK_WINDOW(win));
  else gtk_window_unmaximize(GTK_WINDOW(win));
}

/* bit0 = 最小化、bit1 = 最大化（adapter.h:1931，与 mac/Win 半同位）。
 * GTK4 4.6 没有 gtk_window_is_minimized，最小化那一位只能读 GdkToplevel
 * 的 state（gdktoplevel.h:107）；未上屏时 surface 为 NULL，按「没最小化」兜底。
 * 最大化用 gtk_window_is_maximized（探针真往返验过）。 */
int moonui_native_window_state(moonui_ptr w) {
  GtkWidget *win = moonui_p66_win(w);
  GdkSurface *surf;
  int bits = 0;
  if (win == NULL) return 0;
  surf = gtk_native_get_surface(GTK_NATIVE(win));
  if (surf != NULL &&
      (gdk_toplevel_get_state(GDK_TOPLEVEL(surf)) & GDK_TOPLEVEL_STATE_MINIMIZED) != 0) {
    bits |= 1;
  }
  if (gtk_window_is_maximized(GTK_WINDOW(win))) bits |= 2;
  return bits;
}

/* 焦点探针（T210）：GTK4 的对位是 gtk_window_is_active。
 * 找不到窗口回 -1（契约），别把「没这只窗」报成「不是 key」。 */
int moonui_native_window_is_key(moonui_ptr w) {
  GtkWidget *win = moonui_p66_win(w);
  if (win == NULL) return -1;
  return gtk_window_is_active(GTK_WINDOW(win)) ? 1 : 0;
}

/* 等价于「用户点了标题匹配窗口的关闭按钮」。0 = 已投递、-1 编码失败、
 * -2 找不到窗口（adapter.h:1340-1343）。只在登记表里按标题找，与
 * focus_gtk.inc 的找窗同一口径。
 * 与 Win32 PostMessage(WM_CLOSE) 的差别：gtk_window_close() 是**当场**发
 * close-request（同步走我们的 on_close_request 回调），不是「之后事件循环
 * 才处理」；Core 只用返回码判断有没有找到窗口，这个时序差如实留着。 */
int moonui_native_request_window_close(const char *title, int title_len) {
  char *dup = moonui_dup(title, title_len);
  int i;
  if (dup == NULL) return -1;
  for (i = 0; i < MOONUI_WIN_SLOTS; ++i) {
    MoonuiWinSlot *s = &moonui_wins[i];
    const char *t;
    if (s->win == NULL) continue;
    t = gtk_window_get_title(GTK_WINDOW(s->win));
    if (t != NULL && strcmp(t, dup) == 0) {
      free(dup);
      gtk_window_close(GTK_WINDOW(s->win));
      return 0;
    }
  }
  free(dup);
  return -2;
}
