/*
 * MoonUI 原生后端 · Linux / GTK4 · HUD 置顶窗（T343 Linux 半）。
 *
 * 与其他三片同一规矩：被 adapter_native_gtk.c 用 #include 收进同一个翻译
 * 单元，生成器扫描非 static moonui_* 符号并从"桩"里剔除。
 *
 * 依赖分层：真实现走 gtk4-layer-shell（可选包，Wayland 的 overlay 标准——
 * dunst/waybar 同款）。prebuild-link.js 探测到包时注入
 * MOONUI_HUD_GTK_LAYER_SHELL，走 layer surface 真实现；没装包或合成器不
 * 支持（GNOME 的 Mutter 就不支持）时编空桩——Core 层（hud.mbt）的优雅降级
 * （create 返回 None、update/move 返回 false）接住，tetris-native 照常可玩。
 *
 * 定位语义：layer surface 四边都不锚 = 合成器居中，create 的 x/y 在这半
 * 不参与（Windows 半是屏幕任意坐标的独立置顶窗）；move 也因此是无操作，
 * 报成功让调用方不误判降级。
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
  gtk_layer_init_for_window(win);
  gtk_layer_set_layer(win, GTK_LAYER_SHELL_LAYER_OVERLAY);
  gtk_layer_set_namespace(win, "moonui-hud");
  gtk_window_set_resizable(win, FALSE);
  gtk_window_set_default_size(win, w, h);
  gtk_window_set_decorated(win, FALSE);
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
  /* layer surface 居中锚定后位置由合成器管——move 无语义，报成功让
   * 调用方不误判降级。 */
  return 0;
}

int moonui_native_hud_close(moonui_ptr hud) {
  if (hud == 0) {
    return -1;
  }
  gtk_window_destroy(GTK_WINDOW(hud));
  return 0;
}

#else /* 无包回退：与 mac 半同款空桩 */

moonui_ptr moonui_native_hud_create(int x, int y, int w, int h) {
  (void)x; (void)y; (void)w; (void)h; return 0;
}
int moonui_native_hud_update(moonui_ptr hud, const char *text, int len) {
  (void)hud; (void)text; (void)len; return -1;
}
int moonui_native_hud_move(moonui_ptr hud, int x, int y) {
  (void)hud; (void)x; (void)y; return -1;
}
int moonui_native_hud_close(moonui_ptr hud) { (void)hud; return 0; }

#endif
