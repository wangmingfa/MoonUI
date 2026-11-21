/* 图标解析（`T339`）：按名字查当前图标主题（hicolor）。与 set_icon 的缺席
 * 不是一回事——set_icon 缺席是因为 SF Symbols 名硬映射会装错图；这里查的
 * 就是主题自己的名字（Adwaita 的 "media-playback-start-symbolic" 这套），
 * 名字对不对由调用方按主题约定来，解析本身是诚实的。
 * gtk_icon_theme_get_default 不依赖窗口，init 前调用也拿得到缺省主题对象。 */
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
