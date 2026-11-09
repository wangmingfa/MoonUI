/* =========================================================================
 * T235 P6-5b：滚动视口的内容尺寸（第十片 IMPL_FILES）
 *
 * 一条 ABI：moonui_native_scroll_set_content。控件本体（kind 15）在
 * widgets_gtk.inc 造 GtkScrolledWindow，挂接那条 container_attach 也在那里
 * 扩；本片只管「文档区有多大、哪根轴能滚」。
 *
 * 形态由 2026-11-09 真 GTK4 4.24 探针（/tmp/p65b-probe{,2}.c，4.6 口径）
 * 实测定下：① gtk_scrolled_window_set_child(GtkFixed) 会**自动包一层
 * GtkViewport**，get_child 读到的是 GtkViewport、GtkFixed 的 parent 也是它
 * （因为 GTK_IS_SCROLLABLE(GtkFixed)=0），所以内容要往里走一层；
 * ② gtk_widget_set_size_request(content, 640, 1200) 之后
 * gtk_widget_measure(content, H/V, -1) 真的读出 min=nat=640 / 1200，
 * 即**这份请求就是滚动行程**，不用另造调整对象；
 * ③ gtk_scrolled_window_set_policy 的 h/v 两档能按 get_policy 原样读回
 * （NEVER=2 / AUTOMATIC=1 / ALWAYS=0）。
 *
 * axis 口径照 adapter.h:580-583：0 = Vertical、1 = Horizontal（与布局的
 * Axis 编码一致）。垂直：横向 NEVER、纵向 ALWAYS；水平：横向 AUTOMATIC、
 * 纵向 NEVER——与 mac 半「axis==0 → hasVerticalScroller，1 →
 * hasHorizontalScroller」同一取舍（水平滚动条让 GTK 按内容自己决定要不要
 * 出现，别把没有横向溢出的界面也钉一条）。
 *
 * 仍未验证：真机上滚动条真出现、滚轮驱动行程、GtkViewport 的滚动偏移与
 * Core 的 offset 记账是否对得上——要 P8 的 Linux 真机 / xvfb。
 * ========================================================================= */

/* 前向声明在生成物 prelude（widgets_gtk.inc 的 container_attach 要用它，
 * 而 IMPL_FILES 的顺序是 widgets 在前）。 */
static GtkWidget *moonui_gtk_scroll_content(GtkWidget *sw) {
  GtkWidget *child = gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(sw));
  if (child == NULL) return NULL;
  /* 4.24 探针实测：放进来的 GtkFixed 不是 GtkScrollable，GTK 会包一层
   * GtkViewport；内容从 viewport 里读，不读我们自己的账。 */
  if (GTK_IS_VIEWPORT(child)) return gtk_viewport_get_child(GTK_VIEWPORT(child));
  return NULL;
}

void moonui_native_scroll_set_content(moonui_ptr scroll, int axis, int width,
                                      int height) {
  GtkWidget *sw = (GtkWidget *)(uintptr_t)scroll;
  MoonuiWidgetSlot *s = moonui_wslot_of(sw);
  GtkWidget *content;
  if (s == NULL || s->kind1 - 1 != 15) return;
  content = moonui_gtk_scroll_content(sw);
  if (content == NULL) return;
  if (width < 0) width = 0;
  if (height < 0) height = 0;
  gtk_widget_set_size_request(content, width, height);
  if (axis == 0) {
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(sw), GTK_POLICY_NEVER,
                                   GTK_POLICY_ALWAYS);
  } else if (axis == 1) {
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(sw), GTK_POLICY_AUTOMATIC,
                                   GTK_POLICY_NEVER);
  }
  /* 别的 axis 值只落尺寸、不动策略：契约只定义 0/1，不猜第三档。 */
}
