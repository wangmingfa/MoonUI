/*
 * MoonUI 原生后端 · Linux / GTK4 · 浮层窗（T359 Linux 半，第十八片 IMPL_FILES）。
 *
 * 与其他片同一规矩：被 adapter_native_gtk.c 用 #include 收进同一个翻译单元，
 * 生成器扫描非 static moonui_* 符号并从"桩"里剔除。
 *
 * 浮层 = owner 锚定的无边框窗，装一棵普通 Widget 内容树。owned 语义全交给
 * gtk_window_set_transient_for：与 T354 HUD attached 那条同路——"在 owner 之上
 * / owner 最小化一起隐藏 / 切到别的应用被盖住"三件事都是 transient 的合成器
 * 行为，与 Windows 半 owned WS_POPUP、mac 半 addChildWindow 语义对齐。
 *
 * 返回的是 GtkWindow* 本身（与 window_new 同口径），Core 直接挂子控件 / 摆位 /
 * 销毁。GTK4 已移除 gtk_window_set_position/move，摆位由合成器贴 transient-parent
 * 决定——不假装收了锚点账（与 T354 Linux 半同一条如实边界）。
 *
 * 假头（mock-gtk.h）没有 transient/decorated 那几个 API，MOCK_GTK 下编空桩返回 0，
 * 真头编真实现（与 canvas_gtk.inc / clipboard_gtk.inc 同一分层口径）。
 */

#ifndef MOONUI_MOCK_GTK

/* 只认登记过的活窗作 owner——外面随手造的 GtkWindow 不归这条 ABI 管。 */
static GtkWindow *moonui_popup_owner_window(moonui_ptr owner) {
  int i;
  for (i = 0; i < MOONUI_WIN_SLOTS; ++i) {
    if (moonui_wins[i].win != NULL &&
        (moonui_ptr)moonui_wins[i].win == owner) {
      return GTK_WINDOW(moonui_wins[i].win);
    }
  }
  return NULL;
}

moonui_ptr moonui_native_popup_window_new(moonui_ptr owner, int width, int height) {
  GtkWindow *host = moonui_popup_owner_window(owner);
  GtkWidget *win;
  if (host == NULL || width <= 0 || height <= 0) {
    return 0;
  }
  win = gtk_window_new();
  if (win == NULL) {
    return 0;
  }
  gtk_window_set_default_size(GTK_WINDOW(win), width, height);
  gtk_window_set_decorated(GTK_WINDOW(win), FALSE);
  gtk_window_set_transient_for(GTK_WINDOW(win), host);
  /* 浮层要接鼠标/键盘，不 set_modal（那会把 owner 锁死）；不 init layer-shell
   * （全局置顶表达不了 owner，挂了会把浮层浮到所有应用之上，语义错）。 */
  if (moonui_win_slot_alloc(win) == NULL) {
    gtk_window_destroy(GTK_WINDOW(win));
    return 0;
  }
  g_signal_connect(win, "close-request",
                   G_CALLBACK(moonui_on_close_request), 0);
  g_signal_connect(win, "destroy",
                   G_CALLBACK(moonui_gtk_on_window_destroy), 0);
  return (moonui_ptr)(uintptr_t)win;
}

#else /* MOONUI_MOCK_GTK：假头没有 transient/decorated，编空桩 */

moonui_ptr moonui_native_popup_window_new(moonui_ptr owner, int width, int height) {
  (void)owner; (void)width; (void)height; return 0;
}

#endif
