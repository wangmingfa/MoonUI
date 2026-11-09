/* =========================================================================
 * T235 P6-5b：焦点链与自绘面点击（第九片 IMPL_FILES）
 *
 * 四条 ABI：moonui_native_focused_control / set_focus_chain /
 *          focus_widget_in_window / custom_on_clicked。
 *
 * 纯逻辑（ids 文本解析、链的下一跳、按下并原地抬起的判定）在生成物
 * prelude，假头闸第 13 组逐字对拍；这里只碰真 GTK 对象。
 *
 * 形态由 2026-11-09 真 GTK4 4.24 探针（/tmp/p65b-probe{,2}.c，4.6 最低版本
 * 口径带 -Werror=deprecated-declarations 编译通过）实测定下，不是照文档猜：
 *   ① 真头文件里**没有** gtk_container_set_focus_chain / get_focus_chain
 *      （GTK4 删掉了 GtkContainer），所以「按 Core 声明序遍历 Tab」只能自己
 *      接：在 P3 那只 GtkEventControllerKey 的 key-pressed 里认 Tab，
 *      按链 grab_focus 下一只并返回 TRUE 吞掉 GTK 默认遍历。与 Windows 半
 *      「键盘钩子拦 VK_TAB 按链 SetFocus」同一形状（adapter.h:1809-1811）。
 *   ② gtk_window_get_focus 对 GtkEntry 返回的是内部 **GtkText**，不是 Entry
 *      本身（父链实测 GtkText → GtkEntry → GtkBox → GtkWindow）；Button /
 *      ToggleButton 则直接返回自己。所以读焦点一律**沿父链反查登记表**
 *      （与 P6-1 的 moonui_owner_at 同一课）。
 *   ③ grab_focus 对 focusable=FALSE 的 GtkLabel、以及 sensitive=FALSE 的
 *      Button 都不生效（win_focus 保持旧值），于是 -4 那一档可以本机真跑。
 *   ④ 未上屏窗口上 gtk_widget_pick 恒返回 NULL —— 所以「按坐标命中」不靠
 *      GTK 的 pick，改读 control_set_bounds 落下的那份**逻辑坐标账**
 *      （与 widget_origin 同一份账）。真机排版后两者一致（GtkFixed 的子节点
 *      永远被分配在请求的 (x,y)）；真机上的 Tab 真遍历仍归 P8 xvfb。
 *   ⑤ GtkGestureClick 的 pressed / released 可以用
 *      g_signal_emit_by_name(g, "pressed", 1, x, y, NULL) 驱动，坐标真到账；
 *      所以「注册 + 接线 + 原地判定」能无显示器真跑。
 *
 * 证据边界：key-pressed 返回 TRUE 只证「我们拦了并 grab_focus」，GTK 在真窗
 * 上是否因此不再自己移动焦点、Shift+Tab 的 keyval 在真机上是 ISO_Left_Tab
 * 还是 Tab+Shift，要 P8 的 xvfb 真窗量；本机证的是 GTK 焦点状态真的按链变。
 * ========================================================================= */

/* 内部帮手一律 static：生成器只把**非 static** 的 moonui_* 定义认作 ABI 符号。 */

/* 按标题找我们登记过的窗口。(ptr,len) 不保证 NUL 结尾，先抄成 C 串再比。
 * 只在登记表里找：外面随手造的 GtkWindow 不归我们管，不该被测试脚手架点中。 */
static GtkWidget *moonui_focus_find_window(const char *title, int title_len) {
  char *dup = moonui_gtk_leaf_dup_text(title, title_len);
  int i;
  if (dup == NULL) return NULL;
  for (i = 0; i < MOONUI_WIN_SLOTS; ++i) {
    MoonuiWinSlot *s = &moonui_wins[i];
    const char *t;
    if (s->win == NULL) continue;
    t = gtk_window_get_title(GTK_WINDOW(s->win));
    if (t != NULL && strcmp(t, dup) == 0) {
      free(dup);
      return s->win;
    }
  }
  free(dup);
  return NULL;
}

/* 按逻辑坐标在登记表里找「挂在这只窗口内容树下、且 bounds 盖住这点」的控件。
 * 从后往前找（登记表槽位按创建序，后挂的画在上层，与 raise 的层叠口径一致）。
 * 注意不读 GTK 的 pick：探针实测未上屏恒 NULL，而 Core 在窗口刚建好、还没
 * 排版时就会问焦点。 */
static GtkWidget *moonui_focus_hit(GtkWidget *win, double lx, double ly) {
  int i;
  for (i = MOONUI_WIDGET_SLOTS - 1; i >= 0; --i) {
    MoonuiWidgetSlot *s = &moonui_widgets[i];
    GtkWidget *p;
    if (s->kind1 == 0 || !s->has_bounds) continue;
    if (lx < s->bx || ly < s->by || lx >= s->bx + s->bw ||
        ly >= s->by + s->bh) continue;
    for (p = s->w; p != NULL; p = gtk_widget_get_parent(p)) {
      if (p == win) return s->w;
    }
  }
  return NULL;
}

/* ---- 焦点：每圈问一次（adapter.h:852-861，「问而不报」）---- */

moonui_ptr moonui_native_focused_control(moonui_ptr w) {
  GtkWidget *win = (GtkWidget *)(uintptr_t)w;
  if (win == NULL || moonui_win_slot_of(win) == NULL) return 0;
  return moonui_focus_owner_of(gtk_window_get_focus(GTK_WINDOW(win)));
}

/* ---- 焦点链：整份替换，空串清空 ----
 * -1 窗口不真（不在登记表）/ -3 文本解析失败。-2 是 mac 独有的「链里有 owner
 * 换不出控件、整份丢弃」，Windows 半没有这一档；Linux 同样不预先过问链里每个
 * 指针是不是我们的控件（ids 是 Core 序列化出来的 owner 指针，不是用户输入），
 * 但 **Tab 推进时只对登记表里还活着的控件 grab_focus**，野指针不会进 GTK。 */
int moonui_native_set_focus_chain(moonui_ptr window, const char *ids,
                                  int ids_len) {
  GtkWidget *win = (GtkWidget *)(uintptr_t)window;
  MoonuiWinSlot *ws = moonui_win_slot_of(win);
  moonui_ptr parsed[MOONUI_FOCUS_CHAIN_MAX];
  int n, i;
  if (ws == NULL) return -1;
  n = moonui_gtk_focus_parse(ids, ids_len, parsed, MOONUI_FOCUS_CHAIN_MAX);
  if (n < 0) return -3;
  memset(ws->focus_chain, 0, sizeof(ws->focus_chain));
  for (i = 0; i < n; ++i) ws->focus_chain[i] = parsed[i];
  ws->focus_chain_len = n;
  return 0;
}

/* ---- 测试脚手架：按坐标把焦点摆过去，回读判定 ----
 * 0 已给出去 / -2 找不到窗口 / -3 点在窗口外 / -4 命不中或焦点漂走。
 * 坐标是客户区**物理像素**，登记表的 bounds 是逻辑单位（set_bounds 除了
 * scale），进这里先除回去。 */
int moonui_native_focus_widget_in_window(const char *title, int title_len,
                                         int x, int y) {
  GtkWidget *win = moonui_focus_find_window(title, title_len);
  GtkWidget *hit;
  int scale, ww, hh;
  if (win == NULL) return -2;
  if (x < 0 || y < 0) return -3;
  scale = moonui_scale_of(win);
  ww = gtk_widget_get_width(win);
  hh = gtk_widget_get_height(win);
  /* 未上屏时 GTK 量出 0×0 是「还没有版面」，不是「窗口外」——与 widget_size
   * 那条同一口径。有版面之后才拿真实宽高判越界。 */
  if (ww > 0 && hh > 0 &&
      ((double)x / scale > ww || (double)y / scale > hh)) return -3;
  hit = moonui_focus_hit(win, (double)x / scale, (double)y / scale);
  if (hit == NULL) return -4;
  gtk_widget_grab_focus(hit);
  if (moonui_focus_owner_of(gtk_window_get_focus(GTK_WINDOW(win))) !=
      (moonui_ptr)(uintptr_t)hit) return -4;
  return 0;
}

/* ---- 自绘面点击（T101）----
 * 与 widget_on_clicked 分开一条槽：两条 ABI 是独立的，共用 action 槽会让
 * 「换一条」悄悄改掉另一条（Core 对 Custom 只装这条，但契约没禁止并存）。
 * 判定（按下并原地抬起、拖出去松手不算）是 prelude 的纯逻辑
 * moonui_gtk_custom_click_edge，这里只负责把 GTK 信号的参数喂进去。 */

static void moonui_focus_custom_pressed(GtkGestureClick *g, int n_press,
                                        double x, double y, gpointer data) {
  GtkWidget *w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(g));
  MoonuiWidgetSlot *s = moonui_wslot_of(w);
  (void)data;
  if (s == NULL) return;
  moonui_gtk_custom_click_edge(s, n_press, x, y, 0);
}

static void moonui_focus_custom_released(GtkGestureClick *g, int n_press,
                                         double x, double y, gpointer data) {
  GtkWidget *w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(g));
  MoonuiWidgetSlot *s = moonui_wslot_of(w);
  (void)data;
  if (s == NULL) return;
  if (moonui_gtk_custom_click_edge(s, n_press, x, y, 1) && s->custom_fn != 0) {
    s->custom_fn(s->custom_cl);
  }
}

int moonui_native_custom_on_clicked(moonui_ptr c, moonui_closure_fn fn,
                                    void *closure) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s = moonui_wslot_of(w);
  if (s == NULL || s->kind1 - 1 != 18) return -1;
  if (!s->custom_connected) {
    GtkGesture *g = gtk_gesture_click_new();
    gtk_widget_add_controller(w, GTK_EVENT_CONTROLLER(g));
    g_signal_connect(g, "pressed", G_CALLBACK(moonui_focus_custom_pressed), NULL);
    g_signal_connect(g, "released", G_CALLBACK(moonui_focus_custom_released), NULL);
    s->custom_gesture = (void *)g;
    s->custom_connected = 1;
  }
  moonui_closure_replace(&s->custom_fn, &s->custom_cl, fn, closure);
  return 0;
}
