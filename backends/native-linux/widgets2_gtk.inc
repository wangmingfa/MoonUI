/* =========================================================================
 * T235 P6-5c：七构造族（kinds 6-12）——第十一片 IMPL_FILES。
 *            （纯逻辑在生成物 prelude，这里只碰真 GTK 对象）
 *
 * 七个专属构造族（adapter.h 的 6..12）：Slider(6) / Spinbox(7) / Progress(8) /
 * ComboBox(9) / MultilineEntry(10) / RadioButtons(11) / DatePicker(12)。
 * WebView(19) 不在这一片（GTK4 无原生对象，要嵌 WebKitGTK）；P6-11 已把它的
 * 五条 ABI 口子从「中性桩谎报成功」收成显式缺席（on → -1、load → -2）。
 *
 * 全部形态由 2026-11-09 真 GTK4 4.24 探针（/tmp/p65c-probe.c / p65c-probe2.c，
 * 4.6 最低版本口径 -Werror=deprecated-declarations 编译通过）实测定下，不是照文档猜：
 *   ① Slider = GtkScale（gtk_scale_new_with_range + gtk_range_set_range/set_value/
 *      get_value，信号 "value-changed"）。GTK4 没 gtk_hscale/gtk_vscale。
 *   ② Spinbox = GtkSpinButton（new_with_range + set_value + get_value_as_int，
 *      信号 "value-changed"）。
 *   ③ Progress = GtkProgressBar（set_fraction 0..1；-1 不定进度走 pulse）。
 *      GTK 自身读不回"不定"，所以值缓存 progress_val（-1 与 0% 分不清，探针实证）。
 *   ④ ComboBox = GtkDropDown + GtkStringList（GTK4 新 API，非 GtkComboBoxText）。
 *      append 走 gtk_string_list_append（模型从 gtk_drop_down_get_model 取回）；
 *      选中走 gtk_drop_down_set_selected / get_selected。GtkDropDown **不支持无选中**
 *      （初始默认选 0、set_selected(INVALID) 是 no-op，探针实证），所以"没选中"
 *      用 combo_has_sel 跟踪，映射到 ABI 的 -1。
 *   ⑤ MultilineEntry = GtkTextView（文本走 GtkTextBuffer，自绘后端不归这里）。
 *      widget_set_text / widget_text 经叶子 TEXT_VIEW 通道（leaves_gtk.inc 那对
 *      通用入口按 kind 分派）。changed 信号在 buffer 上、user_data 传回 textview。
 *   ⑥ RadioButtons = GtkBox 装若干个 GtkCheckButton，set_group 互斥。选中下标靠
 *      遍历 box 子节点读 active；toggled 在 append_option 时逐个接（user_data=box）。
 *   ⑦ DatePicker = GtkCalendar（GTK4 的 GDateTime API：get_date 返回 GDateTime、
 *      select_day(GDateTime*)；4.20 起 select_day 被标 deprecated，但 4.6 口径下
 *      可用性分析把它压下、不触发 -Werror=deprecated，探针实证）。**GtkCalendar 只认
 *      日期、会把时间归成"当前时刻"**（get_date 回"所选日+现在"），所以时间原文
 *      靠 date_cache 缓存往返（set_text 解析日期→select_day，原文留 cache；text
 *      直接回 cache）。GDateTime 的创建/读字段/格式化走 GLib。
 *
 * 与现有片共用同一套机制：moonui_wslot_of / moonui_wslot_alloc（kind 记号，P6-1 起）
 * + moonui_closure_replace（闭包槽，leaves_gtk.inc 同款）+ moonui_gtk_on_widget_destroy
 * （销账，widgets_gtk.inc 同款）+ inhibit（挡程序化改值的回声，P6-5 同款）。
 * 六个 on_* 共用一条 change 槽（change_fn/change_cl），与 action/text 分开——它们
 * 不会在同一种控件上共存，单条足够；trampoline 用 user_data 回查登记控件，
 * 因此信号实例是不是登记控件本身都不影响（multiline 的 buffer / radio 的 checkbutton
 * 都靠 user_data 指回 box/textview）。
 * ========================================================================= */

/* 注册一只控件：can_target + 销账 + ref_sink + 入登记表。七构造器共用，
 * 与 widgets_gtk.inc 的 widget_new 同一套（不含 Scroll 文档区那类特殊账）。 */
static moonui_ptr moonui_gtk_register_widget(GtkWidget *w, int kind) {
  MoonuiWidgetSlot *s;
  if (w == NULL) return 0;
  gtk_widget_set_can_target(w, TRUE);
  g_signal_connect(w, "destroy", G_CALLBACK(moonui_gtk_on_widget_destroy), NULL);
  g_object_ref_sink(w);
  s = moonui_wslot_alloc(w, kind);
  if (s == NULL) { /* 登记表满：宁可不给，也不给半个控件 */
    g_object_unref(w);
    return 0;
  }
  return (moonui_ptr)(uintptr_t)w;
}

/* 两个 trampoline：2 参信号（value-changed / changed / toggled / day-selected）
 * 的 user_data 就是登记控件；3 参信号（notify::selected）的 user_data 在第三参。
 * 都只看 user_data 回查槽，信号实例是谁无所谓。 */
static void moonui_gtk_on_change(gpointer emitter, gpointer user) {
  MoonuiWidgetSlot *s;
  (void)emitter;
  s = moonui_wslot_of((GtkWidget *)user);
  if (s == NULL || s->inhibit != 0) return;
  if (s->change_fn != 0) s->change_fn(s->change_cl);
}
static void moonui_gtk_on_change_notify(gpointer obj, gpointer pspec, gpointer user) {
  MoonuiWidgetSlot *s;
  (void)obj; (void)pspec;
  s = moonui_wslot_of((GtkWidget *)user);
  if (s == NULL || s->inhibit != 0) return;
  if (s->change_fn != 0) s->change_fn(s->change_cl);
}

/* ---- 七构造器 ---- */

moonui_ptr moonui_native_slider_new(int min, int max) {
  GtkWidget *w;
  if (min >= max) return 0; /* libui 同款约束：范围非法即造不出 */
  w = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, (double)min, (double)max, 1.0);
  return moonui_gtk_register_widget(w, 6);
}

moonui_ptr moonui_native_spinbox_new(int min, int max) {
  GtkWidget *w;
  if (min >= max) return 0;
  w = gtk_spin_button_new_with_range((double)min, (double)max, 1.0);
  return moonui_gtk_register_widget(w, 7);
}

moonui_ptr moonui_native_progress_new(void) {
  return moonui_gtk_register_widget(gtk_progress_bar_new(), 8);
}

moonui_ptr moonui_native_combobox_new(void) {
  GtkStringList *m = gtk_string_list_new(NULL);
  GtkWidget *w = (GtkWidget *)gtk_drop_down_new(G_LIST_MODEL(m), NULL);
  /* 模型由 dropdown 接管引用，这里不手动 unref（否则双释放）。 */
  return moonui_gtk_register_widget(w, 9);
}

moonui_ptr moonui_native_radio_new(void) {
  GtkWidget *w = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  return moonui_gtk_register_widget(w, 11);
}

moonui_ptr moonui_native_multiline_new(void) {
  return moonui_gtk_register_widget(gtk_text_view_new(), 10);
}

moonui_ptr moonui_native_datepicker_new(void) {
  return moonui_gtk_register_widget(gtk_calendar_new(), 12);
}

/* Slider 专属：设范围（仅 kind 6）。设范围可能发 value-changed，inhibit 挡回声。 */
void moonui_native_slider_set_range(moonui_ptr c, int min, int max) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  if (w == NULL) return;
  s = moonui_wslot_of(w);
  if (s == NULL || s->kind1 - 1 != 6) return;
  if (!GTK_IS_RANGE(w)) return;
  s->inhibit += 1;
  gtk_range_set_range(GTK_RANGE(w), (double)min, (double)max);
  s->inhibit -= 1;
}

/* ---- 通用属通分派（按 moonui_widget_kind_of 的 kind 记号）---- */

void moonui_native_widget_set_value(moonui_ptr c, int v) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  if (w == NULL) return;
  s = moonui_wslot_of(w);
  if (s == NULL) return;
  switch (s->kind1 - 1) {
    case 6: /* Slider */
      if (GTK_IS_RANGE(w)) {
        s->inhibit += 1;
        gtk_range_set_value(GTK_RANGE(w), (double)v);
        s->inhibit -= 1;
      }
      break;
    case 7: /* Spinbox */
      if (GTK_IS_SPIN_BUTTON(w)) {
        s->inhibit += 1;
        gtk_spin_button_set_value(GTK_SPIN_BUTTON(w), (double)v);
        s->inhibit -= 1;
      }
      break;
    case 8: /* Progress：-1 不定进度走 pulse，0..100 走 fraction；值缓存 */
      s->progress_val = v;
      if (v < 0) {
        gtk_progress_bar_pulse(GTK_PROGRESS_BAR(w));
      } else {
        int p = v > 100 ? 100 : v;
        gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(w), (double)p / 100.0);
      }
      break;
    default: break; /* 其他 kind 不接 value */
  }
}

int moonui_native_widget_value(moonui_ptr c) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  if (w == NULL) return 0;
  s = moonui_wslot_of(w);
  if (s == NULL) return 0;
  switch (s->kind1 - 1) {
    case 6: return GTK_IS_RANGE(w) ? (int)llround(gtk_range_get_value(GTK_RANGE(w))) : 0;
    case 7: return GTK_IS_SPIN_BUTTON(w) ? gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(w)) : 0;
    case 8: return s->progress_val; /* 缓存含 -1 */
    default: return 0;
  }
}

void moonui_native_widget_append_option(moonui_ptr c, const char *text, int text_len) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  char *dup;
  if (w == NULL) return;
  s = moonui_wslot_of(w);
  if (s == NULL) return;
  dup = moonui_gtk_leaf_dup_text(text, text_len);
  if (dup == NULL) return;
  switch (s->kind1 - 1) {
    case 9: { /* ComboBox：模型从 dropdown 取回再 append */
      GtkDropDown *dd = GTK_DROP_DOWN(w);
      GtkStringList *m = GTK_STRING_LIST(gtk_drop_down_get_model(dd));
      gtk_string_list_append(m, dup);
      break;
    }
    case 11: { /* RadioButtons：新建 checkbutton 入组，接 toggled（user_data=box） */
      GtkWidget *btn = gtk_check_button_new_with_label(dup);
      GtkWidget *first = gtk_widget_get_first_child(w);
      if (first != NULL && GTK_IS_CHECK_BUTTON(first))
        gtk_check_button_set_group(GTK_CHECK_BUTTON(btn), GTK_CHECK_BUTTON(first));
      gtk_box_append(GTK_BOX(w), btn);
      if (!s->change_connected) {
        g_signal_connect(btn, "toggled", G_CALLBACK(moonui_gtk_on_change), w);
        s->change_connected = 1;
      }
      break;
    }
    default: break;
  }
  free(dup);
}

void moonui_native_widget_set_selected(moonui_ptr c, int index) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  if (w == NULL) return;
  s = moonui_wslot_of(w);
  if (s == NULL) return;
  switch (s->kind1 - 1) {
    case 9: /* ComboBox：GTK 不支持无选中，用 combo_has_sel 跟踪 -1 语义 */
      if (index < 0) {
        s->combo_has_sel = 0;
      } else {
        s->inhibit += 1;
        gtk_drop_down_set_selected(GTK_DROP_DOWN(w), (guint)index);
        s->inhibit -= 1;
        s->combo_has_sel = 1;
      }
      break;
    case 11: { /* RadioButtons：激活第 index 个 checkbutton */
      GtkWidget *cur = gtk_widget_get_first_child(w);
      int i = 0;
      s->inhibit += 1;
      while (cur != NULL) {
        if (GTK_IS_CHECK_BUTTON(cur)) {
          gtk_check_button_set_active(GTK_CHECK_BUTTON(cur), i == index);
          i++;
        }
        cur = gtk_widget_get_next_sibling(cur);
      }
      s->inhibit -= 1;
      break;
    }
    default: break;
  }
}

int moonui_native_widget_selected(moonui_ptr c) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  if (w == NULL) return -1;
  s = moonui_wslot_of(w);
  if (s == NULL) return -1;
  switch (s->kind1 - 1) {
    case 9: {
      guint sel;
      if (!s->combo_has_sel) return -1;
      sel = gtk_drop_down_get_selected(GTK_DROP_DOWN(w));
      return sel == GTK_INVALID_LIST_POSITION ? -1 : (int)sel;
    }
    case 11: { /* RadioButtons：遍历找 active 的 index */
      GtkWidget *cur = gtk_widget_get_first_child(w);
      int i = 0;
      while (cur != NULL) {
        if (GTK_IS_CHECK_BUTTON(cur)) {
          if (gtk_check_button_get_active(GTK_CHECK_BUTTON(cur))) return i;
          i++;
        }
        cur = gtk_widget_get_next_sibling(cur);
      }
      return -1;
    }
    default: return -1;
  }
}

/* 内缩（四方向物理像素）。不按 kind 分派——任何登记控件都给它垫上 margin。 */
void moonui_native_widget_set_insets(moonui_ptr c, int top, int end, int bottom,
                                     int start) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  if (w == NULL) return;
  gtk_widget_set_margin_top(w, top < 0 ? 0 : top);
  gtk_widget_set_margin_end(w, end < 0 ? 0 : end);
  gtk_widget_set_margin_bottom(w, bottom < 0 ? 0 : bottom);
  gtk_widget_set_margin_start(w, start < 0 ? 0 : start);
}

/* ---- DatePicker 文本（GtkCalendar 只认日期，时间靠 date_cache 往返）---- */

int moonui_native_datepicker_set_text(moonui_ptr c, const char *text, int text_len) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  int Y, M, D, h, mi, sd;
  char *dup;
  if (w == NULL) return -2;
  s = moonui_wslot_of(w);
  if (s == NULL) return -2;
  if (s->kind1 - 1 != 12) return -2; /* 不是日期控件 */
  if (text == NULL || text_len <= 0) return -1;
  if (!moonui_gtk_parse_datetime(text, text_len, &Y, &M, &D, &h, &mi, &sd))
    return -1; /* 格式/越界 */
  dup = moonui_gtk_leaf_dup_text(text, text_len);
  if (dup == NULL) return -1;
  if (s->date_cache != NULL) free(s->date_cache);
  s->date_cache = dup; /* 原文往返：时间 GtkCalendar 会丢 */
  {
    GDateTime *dt = g_date_time_new_local(Y, M, D, h, mi, sd);
    if (dt != NULL) {
      s->inhibit += 1;
      gtk_calendar_select_day(GTK_CALENDAR(w), dt);
      s->inhibit -= 1;
      g_date_time_unref(dt);
    }
  }
  return 0;
}

moonbit_bytes_t moonui_native_datepicker_text(moonui_ptr c) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  if (w == NULL) return moonui_bytes_of("");
  s = moonui_wslot_of(w);
  if (s == NULL) return moonui_bytes_of("");
  return moonui_bytes_of(s->date_cache != NULL ? s->date_cache : "");
}

/* ---- 六个 on_* 回调（共用 change 槽）---- */

int moonui_native_slider_on_changed(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  if (w == NULL) return -1;
  s = moonui_wslot_of(w);
  if (s == NULL || s->kind1 - 1 != 6) return -1;
  if (!s->change_connected) {
    g_signal_connect(w, "value-changed", G_CALLBACK(moonui_gtk_on_change), w);
    s->change_connected = 1;
  }
  moonui_closure_replace(&s->change_fn, &s->change_cl, fn, closure);
  return 0;
}

int moonui_native_spinbox_on_changed(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  if (w == NULL) return -1;
  s = moonui_wslot_of(w);
  if (s == NULL || s->kind1 - 1 != 7) return -1;
  if (!s->change_connected) {
    g_signal_connect(w, "value-changed", G_CALLBACK(moonui_gtk_on_change), w);
    s->change_connected = 1;
  }
  moonui_closure_replace(&s->change_fn, &s->change_cl, fn, closure);
  return 0;
}

int moonui_native_combobox_on_selected(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  if (w == NULL) return -1;
  s = moonui_wslot_of(w);
  if (s == NULL || s->kind1 - 1 != 9) return -1;
  if (!s->change_connected) {
    g_signal_connect(w, "notify::selected", G_CALLBACK(moonui_gtk_on_change_notify), w);
    s->change_connected = 1;
  }
  moonui_closure_replace(&s->change_fn, &s->change_cl, fn, closure);
  return 0;
}

int moonui_native_radio_on_selected(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  if (w == NULL) return -1;
  s = moonui_wslot_of(w);
  if (s == NULL || s->kind1 - 1 != 11) return -1;
  /* toggled 信号在 append_option 时逐个 checkbutton 接好；这里只换闭包。 */
  moonui_closure_replace(&s->change_fn, &s->change_cl, fn, closure);
  return 0;
}

int moonui_native_multiline_on_changed(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  if (w == NULL) return -1;
  s = moonui_wslot_of(w);
  if (s == NULL || s->kind1 - 1 != 10) return -1;
  if (!s->change_connected) {
    GtkTextBuffer *buf = gtk_text_view_get_buffer(GTK_TEXT_VIEW(w));
    g_signal_connect(buf, "changed", G_CALLBACK(moonui_gtk_on_change), w);
    s->change_connected = 1;
  }
  moonui_closure_replace(&s->change_fn, &s->change_cl, fn, closure);
  return 0;
}

int moonui_native_datepicker_on_changed(moonui_ptr c, moonui_closure_fn fn, void *closure) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *s;
  if (w == NULL) return -1;
  s = moonui_wslot_of(w);
  if (s == NULL || s->kind1 - 1 != 12) return -1;
  if (!s->change_connected) {
    g_signal_connect(w, "day-selected", G_CALLBACK(moonui_gtk_on_change), w);
    s->change_connected = 1;
  }
  moonui_closure_replace(&s->change_fn, &s->change_cl, fn, closure);
  return 0;
}
