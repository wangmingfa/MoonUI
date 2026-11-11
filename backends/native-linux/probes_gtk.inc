/* =========================================================================
 * T235 P6-16：拖入探针与拖拽落点探针（第十三片 IMPL_FILES）
 *
 * 两条 ABI：moonui_native_file_drop_probe / moonui_native_drag_hit_probe。
 *
 * 为什么在 .inc 而不是生成器的 REAL 段：两条都要按标题在**我们自己登记的
 * 窗口表**里找窗（focus_gtk.inc 的 moonui_focus_find_window），而那个帮手
 * 是 static、假头构建里整片被跳过——放 REAL 段假头闸会编不过。两条在假头
 * 构建里退化成同签名桩（返回 0），真判据由 canvas-pixel 闸的真 GTK 组跑。
 *
 * ① file_drop_probe（位打包，adapter.h:1698-1702）
 *    bit0 = 拖入监听闭包装没装（moonui_drop_fn）；
 *    bit1 = 建窗时挂了 GDK_TYPE_FILE_LIST 的 GtkDropTarget（prelude 的
 *           moonui_gtk_filedrop_attach 落的 filedrop_attached 账）；
 *    bit2 = 恒 0：GTK4 没有替投入口（simulate_file_drop 在本平台是显式
 *           缺席码 -1），"上一次替投"这条事实永远没发生——如实报 0，不是桩。
 *
 * ② drag_hit_probe（adapter.h:1704-1710）
 *    先在客户区里做 gtk_widget_pick，再沿父链反查登记表（moonui_owner_at）；
 *    窗口还没上屏时 pick 恒 NULL（focus_gtk.inc 头注④），退回 control_set_bounds
 *    落下的逻辑坐标账（moonui_focus_hit），所以无头与上屏后答案一致。
 *    落点是编辑控件（Entry / Password / TextView 的 kind 2/4/10）回 1，
 *    其余控件或窗口本体回 0，找不到窗口 -2，客户区外 -3。
 *
 * 证据边界：这条回答的是"落点归属"，不是"GTK 真的把 drop 交给谁"。GTK4 的
 * 文本控件是否自带 GtkDropTarget 取决于控件实现，真机 DnD 行为仍要 Linux
 * 真窗口复验；mac 的 field editor（NSTextView 自带 destination）没有 GTK 的
 * 直接对应物。**只在本平台回答可回答的部分，不编造 1 的语义。**
 * ========================================================================= */

int64_t moonui_native_file_drop_probe(const char *title, int title_len) {
  GtkWidget *win;
  MoonuiWinSlot *s;
  int64_t bits = 0;
  win = moonui_focus_find_window(title, title_len);
  if (win == NULL) return -2;
  s = moonui_win_slot_of(win);
  if (moonui_drop_fn != 0) bits |= 1;
  if (s != NULL && s->filedrop_attached) bits |= 2;
  return bits;
}

int moonui_native_drag_hit_probe(const char *title, int title_len, int x, int y) {
  GtkWidget *win;
  GtkWidget *hit;
  int scale, ww, hh, lx, ly, kind;
  win = moonui_focus_find_window(title, title_len);
  if (win == NULL) return -2;
  if (x < 0 || y < 0) return -3;
  scale = moonui_scale_of(win);
  if (scale < 1) scale = 1;
  lx = x / scale;
  ly = y / scale;
  ww = gtk_widget_get_width(win);
  hh = gtk_widget_get_height(win);
  /* 未上屏时 GTK 量出 0×0 是「还没有版面」，不是「窗口外」——与
   * focus_widget_in_window 同口径；有版面之后才拿真实宽高判越界。 */
  if (ww > 0 && hh > 0 && (lx >= ww || ly >= hh)) return -3;
  hit = (GtkWidget *)(uintptr_t)moonui_owner_at(win, (double)lx, (double)ly);
  if (hit == NULL) {
    /* 未上屏 / pick 问不到：退回 bounds 账（focus_gtk.inc 头注④）。 */
    hit = moonui_focus_hit(win, (double)lx, (double)ly);
  }
  if (hit == NULL) return 0;
  kind = moonui_widget_kind_of(hit);
  return (kind == 2 || kind == 4 || kind == 10) ? 1 : 0;
}
