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
 * P6-6 本片**不碰**下面 15 条窗口 ABI（position / screen_* / titlebar_style /
 * drag_band / traffic_light / live_resize / 各类 probe）：GTK4 4.6 没有
 * gtk_window_move / gdk_monitor_get_workarea，红绿灯与拖动带是 mac/Win32
 * 专属。更关键的是它们多数是**打包坐标的 getter**，契约要求兜底而不是错误码
 * （adapter.h:214-217 明写 0 尺寸会让 Window::center 把窗口堆到左上角），
 * 逐条改成 -3 类缺席码会直接破坏 Core 摆位。这 15 条的口径在下方 P6-7 段
 * 落地：3 条 screen_* 用 GdkMonitor 整屏 geometry 真实现，12 条按契约空操作 /
 * 兜底常量（2026-11-10）。
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

/* =========================================================================
 * T235 P6-7：窗口几何与平台专属读数的口径（第十二片续）
 *
 * 15 条窗口 ABI 在 P6-6 之后还剩这些。它们分成两半：
 *   ① **真实现**（3 条）：`screen_work_area` / `window_screen_origin` /
 *      `window_screen_size`。GDK4 没有 workarea 读口，用 GdkMonitor 的**整屏
 *      geometry** 兜底（任务栏/Dock 不扣除，已知边界），保证 `Window::center`
 *      在多屏上至少拿到非 0 的可用矩形，而不是把窗口堆到左上角
 *      （adapter.h:214-217）。
 *   ② **如实不接**（12 条）：GTK4 没有窗口位置读写、没有拖动带、没有红绿灯、
 *      没有 live-resize 会话通知，这些是 mac/Win32 的窗口管理概念。按契约给
 *      空操作或兜底常量，**不**返回 -3 类缺席码——它们多数是打包坐标/位标志
 *      的 getter，错误码会被 Core 当成几何或状态用。
 *
 * 坐标口径：GdkMonitor 的 geometry 是**逻辑点**，ABI 要物理像素，所以乘该
 * monitor 的 scale factor。混合 DPI 下「monitor 局部逻辑坐标 × 该屏 scale」
 * 是近似（GDK 没有跨屏统一的物理坐标口径），如实留在注释里。
 * 窗口位置 `position()` 在 Linux 恒 (0,0)（GTK4 无读口），所以
 * `screen_origin` 与 `Window::center` 的配合是「同一后端内自洽」：origin/size
 * 给摆位算点，算完再交给同后端的 set_position（那一条在 Linux 是空操作）。
 * ========================================================================= */

/* 窗口所在 monitor 的整屏 geometry（逻辑点）与该屏 scale。
 * win 为 NULL / 未上屏 / 查不到 → 主屏（monitor 列表首项，与
 * moonui_display_scale 的取法一致）；都拿不到 → geometry 清零、scale=1。 */
static void moonui_p67_monitor_geometry(GtkWidget *win, GdkRectangle *geo,
                                        int *scale) {
  GdkDisplay *d = NULL;
  GdkMonitor *m = NULL;
  int full_ref = 0;
  geo->x = 0;
  geo->y = 0;
  geo->width = 0;
  geo->height = 0;
  *scale = 1;
  if (win != NULL) {
    GdkSurface *surf = gtk_native_get_surface(GTK_NATIVE(win));
    if (surf != NULL) {
      d = gdk_surface_get_display(surf);
      if (d == NULL) d = gdk_display_get_default();
      if (d != NULL) m = gdk_display_get_monitor_at_surface(d, surf);
      /* transfer none：不做 unref。 */
    }
  }
  if (m == NULL) {
    if (d == NULL) {
      d = win != NULL ? gtk_widget_get_display(win) : gdk_display_get_default();
    }
    if (d != NULL) {
      GListModel *mons = gdk_display_get_monitors(d);
      if (mons != NULL && g_list_model_get_n_items(mons) > 0) {
        /* transfer full：下面读完要 unref，否则每次 center 漏一块 monitor。 */
        m = (GdkMonitor *)g_list_model_get_item(mons, 0);
        full_ref = 1;
      }
    }
  }
  if (m != NULL) {
    gdk_monitor_get_geometry(m, geo);
    *scale = gdk_monitor_get_scale_factor(m);
    if (*scale <= 0) *scale = 1;
    if (full_ref) g_object_unref(m);
  }
}

/* 主屏整屏尺寸，打包 (width, height)，物理像素。
 * 主屏 = monitor 列表首项（GDK4 没有 primary monitor 的概念，与
 * moonui_display_scale 同一条理由）。**不减任务栏**：GDK4 没有 workarea
 * 读口，这是已知边界，不拿猜测（例如减一个固定高度）冒充真实可用区。 */
int64_t moonui_native_screen_work_area(void) {
  GdkRectangle geo;
  int scale;
  moonui_p67_monitor_geometry(NULL, &geo, &scale);
  return moonui_pack2(geo.width * scale, geo.height * scale);
}

/* 窗口当下所在那块屏的左上角，打包 (x, y)，物理像素。
 * 窗口未上屏 / 查不到 / 句柄不认识 → 主屏（和 screen_work_area 同值），
 * 与 adapter.h 的兜底口径一致。 */
int64_t moonui_native_window_screen_origin(moonui_ptr w) {
  GtkWidget *win = moonui_p66_win(w);
  GdkRectangle geo;
  int scale;
  moonui_p67_monitor_geometry(win, &geo, &scale);
  return moonui_pack2(geo.x * scale, geo.y * scale);
}

/* 窗口所在那块屏的整屏尺寸，打包 (width, height)，物理像素；兜底同 origin。 */
int64_t moonui_native_window_screen_size(moonui_ptr w) {
  GtkWidget *win = moonui_p66_win(w);
  GdkRectangle geo;
  int scale;
  moonui_p67_monitor_geometry(win, &geo, &scale);
  return moonui_pack2(geo.width * scale, geo.height * scale);
}

/* 当下是不是在用户拖拽改尺寸的会话里。GTK4 把交互式 resize 交给合成器，
 * 客户端没有 inLiveResize 的对位，恒 0（程序化改尺寸本来也不算，Core 的
 * set_size 自己当场重排）。 */
int moonui_native_window_in_live_resize(moonui_ptr w) {
  (void)w;
  return 0;
}

/* 窗口外层左上角摆位。GTK4 4.6 已没有 gtk_window_move（4.0 起移除），
 * Wayland 也不允许程序化摆位；空操作，位置由合成器/用户决定。 */
void moonui_native_window_set_position(moonui_ptr w, int x, int y) {
  (void)w;
  (void)x;
  (void)y;
}

/* 读窗口位置。GTK4 没有任何窗口位置读口（gtk_window_get_position 也已移除），
 * 与空操作的 set_position 保持一致回打包的 (0,0)。Linux 上 `Moved` 不会由
 * 后端产生，消费点（Core 的 push_move）在本平台不会拿到这条读数。 */
int64_t moonui_native_window_position(moonui_ptr w) {
  (void)w;
  return moonui_pack2(0, 0);
}

/* 测试缝：模拟 WindowServer 把窗挪走、AppKit 没通知的中间态——mac 专属。
 * Linux 的窗口移动由合成器直接完成，没有这个中间态，空操作。 */
void moonui_native_window_move_external(moonui_ptr w, int x, int y) {
  (void)w;
  (void)x;
  (void)y;
}

/* 测试缝：喂一拍合成拖动（mac 方案 B）。Linux 没有可读的拖动期位置，
 * 空操作。 */
void moonui_native_window_drag_step(moonui_ptr w, int x, int y) {
  (void)w;
  (void)x;
  (void)y;
}

/* 标题栏样式（沉浸式 = 内容铺满 + 标题栏透明 + 隐藏标题文字）。GTK4 4.6
 * 没有按窗口控制这三条的 API：标题栏由 CSD 主题/合成器决定，客户端只能
 * 整只开关装饰（gtk_window_set_decorated），语义对不上，所以空操作。 */
void moonui_native_window_set_titlebar_style(moonui_ptr w, int immersive) {
  (void)w;
  (void)immersive;
}

/* 读回标题栏样式位。setter 是空操作，恒非沉浸（0）；
 * 契约的三位置 1 只属于 mac/Win32。 */
int moonui_native_window_titlebar_style(moonui_ptr w) {
  (void)w;
  return 0;
}

/* 自绘顶条的拖动带高度。那是 Win32 的 WM_NCHITTEST / mac 的
 * movableByWindowBackground 概念；GTK4 的窗口拖动由合成器按 CSD 决定，
 * 空操作。 */
void moonui_native_window_set_drag_band(moonui_ptr w, int height) {
  (void)w;
  (void)height;
}

/* 读回拖动带高度：没有这个概念，恒 0。 */
int moonui_native_window_drag_band(moonui_ptr w) {
  (void)w;
  return 0;
}

/* 整窗拖动探针的两位（isMovableByWindowBackground / mouseDownCanMoveWindow）
 * 都是 AppKit 概念，Win32 半同样恒 0；Linux 保留 -1 = 找不到窗口的契约。 */
int64_t moonui_native_window_movable_probe(moonui_ptr w) {
  if (moonui_p66_win(w) == NULL) return -1;
  return 0;
}

/* 红绿灯位置。GTK4 的窗口控制按钮由 CSD 主题摆放，没有按窗口挪红绿灯的
 * API；空操作。 */
void moonui_native_window_set_traffic_light_position(moonui_ptr w, int x,
                                                     int y) {
  (void)w;
  (void)x;
  (void)y;
}

/* 读回红绿灯位置：没有红绿灯，恒 (0,0)（与 Windows 半同口径）。 */
int64_t moonui_native_window_traffic_light_position(moonui_ptr w) {
  (void)w;
  return moonui_pack2(0, 0);
}
