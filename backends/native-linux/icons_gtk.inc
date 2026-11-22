/* 图标解析（`T339`）：按名字查当前图标主题（hicolor）。与 set_icon 的缺席
 * 不是一回事——set_icon 缺席是因为 SF Symbols 名硬映射会装错图；这里查的
 * 就是主题自己的名字（Adwaita 的 "media-playback-start-symbolic" 这套），
 * 名字对不对由调用方按主题约定来，解析本身是诚实的。
 * gtk_icon_theme_get_default 不依赖窗口，init 前调用也拿得到缺省主题对象。 */
/* 本地日期（`T341`）：本地时区的当天 ISO "YYYY-MM-DD"。g_date_time_new_now_local
 * 走 GTK 自带的时区处理；缓冲不足/失败 -1。 */
int moonui_native_local_date(char *buf, int cap) {
  GDateTime *dt = g_date_time_new_now_local();
  if (dt == NULL) {
    return -1;
  }
  gchar *iso = g_date_time_format(dt, "%Y-%m-%d");
  g_date_time_unref(dt);
  if (iso == NULL) {
    return -1;
  }
  int n = strlen(iso);
  if (cap <= n) {
    g_free(iso);
    return -1;
  }
  memcpy(buf, iso, n + 1);
  g_free(iso);
  return n;
}

/* 图标解析（`T339`）：按名字查当前图标主题（hicolor）。与 set_icon 的缺席
 * 不是一回事——set_icon 缺席是因为 SF Symbols 名硬映射会装错图；这里查的
 * 就是主题自己的名字（Adwaita 的 "media-playback-start-symbolic" 这套），
 * 名字对不对由调用方按主题约定来，解析本身是诚实的。 */
int moonui_native_icon_resolve(const char *name, int name_len) {
  GtkIconTheme *theme;
  (void)name_len;
  if (name == 0 || name_len <= 0) {
    return -1;
  }
  /* GTK3 的 gtk_icon_theme_get_default 在 GTK4 已删（P3 复核同族），GTK4
   * 按显示服务走 get_for_display。 */
  theme = gtk_icon_theme_get_for_display(gdk_display_get_default());
  if (theme == 0) {
    return 0;
  }
  return gtk_icon_theme_has_icon(theme, name) ? 1 : 0;
}

/* HUD 置顶窗（`T343`）：本平台第一期未实现——与 mac 半同款空桩，返回
 * 0/-1 让调用方优雅降级（hud.mbt 的 create 返回 None、update/move 返回
 * false），tetris-native 等消费方在 Linux 上不建 HUD、不挡流程。 */
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
