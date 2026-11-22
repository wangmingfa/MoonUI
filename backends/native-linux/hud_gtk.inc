/*
 * MoonUI 原生后端 · Linux / GTK4 · HUD 置顶窗（T343 Linux 半）。
 *
 * 与其他三片同一规矩：被 adapter_native_gtk.c 用 #include 收进同一个翻译
 * 单元，生成器扫描非 static moonui_* 符号并从"桩"里剔除。
 *
 * 依赖分层：真实现走 gtk4-layer-shell（可选包）。prebuild-link.js 探测到
 * 包时注入 MOONUI_HUD_GTK_LAYER_SHELL，运行时再按合成器分两路：
 *   - gtk_layer_is_supported() 为真（niri/sway/Hyprland/KDE Plasma 等
 *     wlroots 系与 KDE）：layer surface，OVERLAY 层居中，与 Windows 半的
 *     全局置顶同语义；
 *   - 为假（GNOME 的 Mutter 不实现该协议）或非 Wayland（X11）：回退成
 *     transient 无边框窗，跟随主窗置顶（HUD 是应用自己的面板，不需要
 *     跨应用置顶）——GNOME/X11 上由此也有 HUD，而不是空桩降级。
 * 两路的定位/外观共用一套；没装包时整个文件编空桩，Core 层（hud.mbt）的
 * 优雅降级（create 返回 None、update/move 返回 false）接住。
 */

#ifdef MOONUI_HUD_GTK_LAYER_SHELL

#include <gtk4-layer-shell.h>

/* HUD 卡的固定外观：深底圆角 + 浅字（一次挂 display 级 provider）。 */
static void moonui_hud_ensure_css(void) {
  static int done = 0;
  GtkCssProvider *provider;
  if (done != 0) {
    return;
  }
  done = 1;
  provider = gtk_css_provider_new();
  gtk_css_provider_load_from_data(
      provider,
      ".moonui-hud { background-color: rgba(15,21,35,0.88);"
      " border-radius: 12px; }\n"
      ".moonui-hud label { color: #E6EDF3; font-size: 13px; }\n",
      -1);
  gtk_style_context_add_provider_for_display(
      gdk_display_get_default(), GTK_STYLE_PROVIDER(provider),
      GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  g_object_unref(provider);
}

/* 登记表里第一个活的主窗：transient 回退路的跟随对象（单应用通常一窗）。 */
static GtkWindow *moonui_hud_host_window(void) {
  int i;
  for (i = 0; i < MOONUI_WIN_SLOTS; ++i) {
    if (moonui_wins[i].win != NULL) {
      return GTK_WINDOW(moonui_wins[i].win);
    }
  }
  return NULL;
}

moonui_ptr moonui_native_hud_create(int x, int y, int w, int h) {
  GtkWindow *win;
  GtkWidget *label;
  (void)x;
  (void)y;
  if (w < 32 || h < 24) {
    return 0;
  }
  moonui_hud_ensure_css();
  win = GTK_WINDOW(gtk_window_new());
  gtk_window_set_resizable(win, FALSE);
  gtk_window_set_default_size(win, w, h);
  gtk_window_set_decorated(win, FALSE);
  if (gtk_layer_is_supported()) {
    /* layer surface：OVERLAY 层、四边都不锚 = 合成器居中。x/y 不参与。 */
    gtk_layer_init_for_window(win);
    gtk_layer_set_layer(win, GTK_LAYER_SHELL_LAYER_OVERLAY);
    gtk_layer_set_namespace(win, "moonui-hud");
  } else {
    /* GNOME/X11 回退：跟随主窗的无边框 transient 窗。GTK4 没有摆位 API
     *（gtk_window_set_position/move 都已移除），位置由合成器管——transient
     * 的摆位通常贴着父窗，够 HUD 用。 */
    GtkWindow *host = moonui_hud_host_window();
    if (host != NULL) {
      gtk_window_set_transient_for(win, host);
    }
  }
  label = gtk_label_new(NULL);
  gtk_label_set_justify(GTK_LABEL(label), GTK_JUSTIFY_CENTER);
  gtk_widget_set_halign(label, GTK_ALIGN_CENTER);
  gtk_widget_set_valign(label, GTK_ALIGN_CENTER);
  gtk_widget_add_css_class(label, "moonui-hud");
  gtk_window_set_child(win, label);
  gtk_window_present(GTK_WINDOW(win));
  return (moonui_ptr)(uintptr_t)win;
}

int moonui_native_hud_update(moonui_ptr hud, const char *text, int len) {
  GtkWindow *win;
  GtkWidget *child;
  gchar *copy;
  if (hud == 0 || text == 0 || len <= 0) {
    return -1;
  }
  win = GTK_WINDOW(hud);
  child = gtk_window_get_child(win);
  if (child == NULL || !GTK_IS_LABEL(child)) {
    return -1;
  }
  /* text 按 len 语义不一定带 NUL，先拷出再补。 */
  copy = g_strndup(text, (gsize)len);
  gtk_label_set_text(GTK_LABEL(child), copy);
  g_free(copy);
  return 0;
}

int moonui_native_hud_move(moonui_ptr hud, int x, int y) {
  (void)hud;
  (void)x;
  (void)y;
  /* GTK4 没有客户端摆位 API（layer surface 由合成器居中，transient 由合成
   * 器贴父窗）——move 两条路都无语义，报成功让调用方不误判降级。 */
  return 0;
}

int moonui_native_hud_close(moonui_ptr hud) {
  if (hud == 0) {
    return -1;
  }
  gtk_window_destroy(GTK_WINDOW(hud));
  return 0;
}

/* T349 的应用内档：layer-shell 表达不了 owner 关系（那是全局置顶层），
 * 第一期返回 0 让调用方降级到全局档。 */
moonui_ptr moonui_native_hud_create_attached(moonui_ptr owner, int corner,
                                             int dx, int dy, int w, int h) {
  (void)owner; (void)corner; (void)dx; (void)dy; (void)w; (void)h; return 0;
}

#else /* 无包回退：与 mac 半同款空桩 */

moonui_ptr moonui_native_hud_create(int x, int y, int w, int h) {
  (void)x; (void)y; (void)w; (void)h; return 0;
}
moonui_ptr moonui_native_hud_create_attached(moonui_ptr owner, int corner,
                                             int dx, int dy, int w, int h) {
  (void)owner; (void)corner; (void)dx; (void)dy; (void)w; (void)h; return 0;
}
int moonui_native_hud_update(moonui_ptr hud, const char *text, int len) {
  (void)hud; (void)text; (void)len; return -1;
}
int moonui_native_hud_move(moonui_ptr hud, int x, int y) {
  (void)hud; (void)x; (void)y; return -1;
}
int moonui_native_hud_close(moonui_ptr hud) { (void)hud; return 0; }

#endif
