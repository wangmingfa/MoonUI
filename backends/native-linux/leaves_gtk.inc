/* =========================================================================
 * T235 P6-5：控件叶子的文案 / 占位 / 勾选 / 三条回调
 *            （第八片 IMPL_FILES；纯逻辑在生成物 prelude，这里只碰真 GTK 对象）
 *
 * 八条 ABI：moonui_native_widget_set_text / widget_text /
 *          widget_set_placeholder / widget_set_checked / widget_checked /
 *          widget_on_clicked / widget_on_text_changed / widget_on_toggled。
 * 控件本体的构造在 widgets_gtk.inc（widget_new 从只接 17/18 扩到十种 kind），
 * 两片共用 prelude 里**唯一**一张 kind → 构造形态表，不各写一遍（P6-4b 那次
 * "双层护栏"负控制全绿的教训）。
 *
 * 形态全部由 2026-11-09 真 GTK4 4.24 探针（/tmp/p65-probe.c，4.6 最低版本
 * 口径 -Werror=deprecated-declarations 编译通过）实测定下，不是照文档猜：
 *   ① 十种构造都造得出：GtkLabel / GtkButton / GtkCheckButton / GtkEntry /
 *      GtkPasswordEntry / GtkSeparator(H/V) / GtkImage / GtkFixed /
 *      GtkDrawingArea。GTK_IS_BUTTON(GtkCheckButton) 实测为 0，别拿按钮宏判勾选框。
 *   ② 文案分四个通道：gtk_label_set_text、gtk_button_set_label、
 *      gtk_check_button_set_label、gtk_editable_set_text。GtkPasswordEntry
 *      实现 GtkEditable（editable=1），与 GtkEntry 共用第三条。
 *   ③ GtkEntry 与 GtkPasswordEntry 都有 "placeholder-text" 属性；前者另有
 *      gtk_entry_set_placeholder_text。占位与文本是两条独立通道，设占位
 *      不改变 gtk_editable_get_text 的读数。
 *   ④ **程序化改值会回声**：gtk_editable_set_text 一次实测发 2 条 "changed"，
 *      gtk_check_button_set_active 一次发 1 条 "toggled"。ABI 契约（adapter.h
 *      :492，mac/win 两侧都钉着）要求程序化设置不回声成一条 Input/Change，
 *      所以这两条 setter 与 set_placeholder 一律在登记表上挂 inhibit，
 *      trampoline 见到 inhibit 直接吞掉；真实用户改字/点击仍照常派发。
 *   ⑤ g_signal_emit_by_name(button, "clicked") 能驱动已连接的回调，所以
 *      "回调注册 + 信号接线" 可以无显示器真跑；这不是真人上屏点击（P8 的
 *      xvfb 真窗才算那条完整路径）。
 *   ⑥ 只读 GTK 自己那份账：判据用 gtk_label_get_text / gtk_button_get_label /
 *      gtk_check_button_get_active / gtk_editable_get_text 读回，不读我们
 *      存过的字符串（P6-4b "读原生对象但读错层" 的同款防呆）。
 *
 * 明确缺席（不造空壳冒充）：14 MenuRow / 15 Scroll / 19 WebView——GTK4 没有
 * 一一对应的原生对象，Scroll 还要配 scroll_set_content 那条 ABI；造出来却接不
 * 上内容就是中性桩 return 0 那种谎报。6..12 走专属构造入口，也不在这片。
 * custom_on_clicked（自绘面按下并原地抬起）、焦点链三条、真机 Tab 遍历
 * 留 P6-5b / P8。
 * ========================================================================= */

/* 内部帮手一律 static：生成器只把**非 static** 的 moonui_* 定义认作 ABI 符号。 */

/* 两条 trampoline 都声明成 (GtkWidget *, gpointer)：clicked / toggled / changed
 * 的第一个实参都是对象指针，经 G_CALLBACK 转换后 C ABI 一致；user_data 传 NULL，
 * 槽位靠 widget 指针回查登记表，不靠 user_data 带一个可能失效的指针。 */
static void moonui_leaf_on_action(GtkWidget *w, gpointer data) {
  MoonuiWidgetSlot *s;
  (void)data;
  s = moonui_wslot_of(w);
  if (s == NULL || s->inhibit != 0) return;
  if (s->action_fn != 0) s->action_fn(s->action_cl);
}

static void moonui_leaf_on_text(GtkWidget *w, gpointer data) {
  MoonuiWidgetSlot *s;
  (void)data;
  s = moonui_wslot_of(w);
  if (s == NULL || s->inhibit != 0) return;
  if (s->text_fn != 0) s->text_fn(s->text_cl);
}

/* 槽位是不是这只控件能接的信号。不支持的 kind 返回 -1（不是 0）：Core 把
 * 注册失败抬成 OperationFailed，让它知道"这个控件没有点击语义"，比收下一个
 * 永远不会触发的回调诚实。menurow(14) 目前造不出来，故不在表内。 */
static int moonui_leaf_wire_action(moonui_ptr c, moonui_closure_fn fn,
                                   void *closure, const char *signal) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  if (w == NULL) return -1;
  s = moonui_wslot_of(w);
  if (s == NULL) return -1;
  if (!s->action_connected) {
    g_signal_connect(w, signal, G_CALLBACK(moonui_leaf_on_action), NULL);
    s->action_connected = 1;
  }
  /* 单槽可换人（adapter.h 的"重复调用只换回调"）：这里没有 mac 那种进程级
   * 槽池，所以"槽满"不会发生，成功一律 0。旧闭包的 decref 由 replace 负责。 */
  moonui_closure_replace(&s->action_fn, &s->action_cl, fn, closure);
  return 0;
}

/* ---- 文案读写 ---- */

void moonui_native_widget_set_text(moonui_ptr c, const char *text, int text_len) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *slot;
  char *dup;
  int leaf, ch;
  if (w == NULL) return;
  slot = moonui_wslot_of(w);
  if (slot == NULL) return; /* 不是我们造的控件：不动 */
  leaf = moonui_gtk_leaf_of_kind(slot->kind1 - 1);
  ch = moonui_gtk_leaf_text_channel(leaf);
  if (ch == MOONUI_LEAF_TEXT_NONE) return;
  dup = moonui_gtk_leaf_dup_text(text, text_len);
  if (dup == NULL) return;
  slot->inhibit += 1;
  switch (ch) {
    case MOONUI_LEAF_TEXT_LABEL:
      gtk_label_set_text(GTK_LABEL(w), dup);
      break;
    case MOONUI_LEAF_TEXT_BUTTON:
      gtk_button_set_label(GTK_BUTTON(w), dup);
      break;
    case MOONUI_LEAF_TEXT_CHECK:
      gtk_check_button_set_label(GTK_CHECK_BUTTON(w), dup);
      break;
    default:
      gtk_editable_set_text(GTK_EDITABLE(w), dup);
      break;
  }
  slot->inhibit -= 1;
  free(dup);
}

moonbit_bytes_t moonui_native_widget_text(moonui_ptr c) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *slot;
  const char *txt = "";
  int leaf, ch;
  if (w == NULL) return moonui_bytes_of("");
  slot = moonui_wslot_of(w);
  if (slot == NULL) return moonui_bytes_of("");
  leaf = moonui_gtk_leaf_of_kind(slot->kind1 - 1);
  ch = moonui_gtk_leaf_text_channel(leaf);
  switch (ch) {
    case MOONUI_LEAF_TEXT_LABEL:
      txt = gtk_label_get_text(GTK_LABEL(w));
      break;
    case MOONUI_LEAF_TEXT_BUTTON:
      txt = gtk_button_get_label(GTK_BUTTON(w));
      break;
    case MOONUI_LEAF_TEXT_CHECK:
      txt = gtk_check_button_get_label(GTK_CHECK_BUTTON(w));
      break;
    case MOONUI_LEAF_TEXT_EDITABLE:
      txt = gtk_editable_get_text(GTK_EDITABLE(w));
      break;
    default:
      break;
  }
  return moonui_bytes_of(txt != NULL ? txt : "");
}

/* 占位不是字段内容：只认输入框两种，且清掉占位不许动文本。 */
void moonui_native_widget_set_placeholder(moonui_ptr c, const char *text,
                                          int text_len) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *slot;
  char *dup;
  int leaf;
  if (w == NULL) return;
  slot = moonui_wslot_of(w);
  if (slot == NULL) return;
  leaf = moonui_gtk_leaf_of_kind(slot->kind1 - 1);
  if (leaf != MOONUI_LEAF_ENTRY && leaf != MOONUI_LEAF_PASSWORD) return;
  dup = moonui_gtk_leaf_dup_text(text, text_len);
  if (dup == NULL) return;
  slot->inhibit += 1;
  if (leaf == MOONUI_LEAF_ENTRY) {
    gtk_entry_set_placeholder_text(GTK_ENTRY(w), dup);
  } else {
    g_object_set(G_OBJECT(w), "placeholder-text", dup, NULL);
  }
  slot->inhibit -= 1;
  free(dup);
}

/* ---- 勾选态 ---- */

void moonui_native_widget_set_checked(moonui_ptr c, int checked) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *slot;
  int leaf;
  if (w == NULL) return;
  slot = moonui_wslot_of(w);
  if (slot == NULL) return;
  leaf = moonui_gtk_leaf_of_kind(slot->kind1 - 1);
  if (leaf != MOONUI_LEAF_CHECK) return;
  /* set_active 会发 toggled（探针实测），程序化设置必须吞掉那一条。 */
  slot->inhibit += 1;
  gtk_check_button_set_active(GTK_CHECK_BUTTON(w), checked ? TRUE : FALSE);
  slot->inhibit -= 1;
}

int moonui_native_widget_checked(moonui_ptr c) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *slot;
  int leaf;
  if (w == NULL) return 0;
  slot = moonui_wslot_of(w);
  if (slot == NULL) return 0;
  leaf = moonui_gtk_leaf_of_kind(slot->kind1 - 1);
  if (leaf != MOONUI_LEAF_CHECK) return 0;
  return gtk_check_button_get_active(GTK_CHECK_BUTTON(w)) ? 1 : 0;
}

/* ---- 回调注册 ---- */

int moonui_native_widget_on_clicked(moonui_ptr c, moonui_closure_fn fn,
                                    void *closure) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s = moonui_wslot_of(w);
  int leaf;
  if (s == NULL) return -1;
  leaf = moonui_gtk_leaf_of_kind(s->kind1 - 1);
  if (leaf != MOONUI_LEAF_BUTTON) return -1;
  return moonui_leaf_wire_action(c, fn, closure, "clicked");
}

int moonui_native_widget_on_toggled(moonui_ptr c, moonui_closure_fn fn,
                                    void *closure) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s = moonui_wslot_of(w);
  int leaf;
  if (s == NULL) return -1;
  leaf = moonui_gtk_leaf_of_kind(s->kind1 - 1);
  if (leaf != MOONUI_LEAF_CHECK) return -1;
  return moonui_leaf_wire_action(c, fn, closure, "toggled");
}

int moonui_native_widget_on_text_changed(moonui_ptr c, moonui_closure_fn fn,
                                         void *closure) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  int leaf;
  if (w == NULL) return -1;
  s = moonui_wslot_of(w);
  if (s == NULL) return -1;
  leaf = moonui_gtk_leaf_of_kind(s->kind1 - 1);
  if (leaf != MOONUI_LEAF_ENTRY && leaf != MOONUI_LEAF_PASSWORD) return -1;
  if (!s->text_connected) {
    g_signal_connect(w, "changed", G_CALLBACK(moonui_leaf_on_text), NULL);
    s->text_connected = 1;
  }
  moonui_closure_replace(&s->text_fn, &s->text_cl, fn, closure);
  return 0;
}
