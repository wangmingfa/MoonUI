/* =========================================================================
 * T235 P6-4c：无障碍语义 + 两条系统偏好 + 自绘面焦点 opt-in
 *            （第七片 IMPL_FILES；纯逻辑在生成物 prelude，这里只碰真 GTK 对象）
 *
 * 四条 ABI：moonui_native_set_widget_accessibility /
 *          moonui_native_prefers_reduced_motion /
 *          moonui_native_prefers_high_contrast /
 *          moonui_native_custom_set_focusable。
 *
 * 形态全部由 2026-11-09 真 GTK4 4.24 探针（/tmp/p64c-probe{,2,3}.c）实测定下，
 * 不是照文档猜：
 *   ① GtkWidget 的 "accessible-role" 属性 flags=0x23（READ|WRITE，**不是**
 *      construct-only），所以 Core 每轮重排推来的 role 可以运行时 g_object_set，
 *      gtk_accessible_get_accessible_role 立刻读到新值。默认 role 实测：
 *      GtkLabel=LABEL / GtkButton=BUTTON / GtkFixed=GENERIC /
 *      GtkCheckButton=CHECKBOX。
 *   ② gtk_accessible_update_property(LABEL/DESCRIPTION) 与
 *      update_state(CHECKED) 之后，GTK 自己的测试 AT context 能读回；
 *      gtk_test_accessible_check_* 在**没显示器、不设 GTK_A11Y** 时也成立
 *      （设 GTK_A11Y=test 的 A/B 两跑逐字相同）。这就是判据的独立尺子：
 *      它读的是 GTK 那份账，不是我们自己的待办账。
 *      同一只 widget 再灌一次 LABEL 不会冲掉 DESCRIPTION（增量下发成立），
 *      reset_property 能把属性清回 undefined。
 *   ③ **GTK 自己维护 DISABLED / HIDDEN**：gtk_widget_set_sensitive(FALSE) 一调，
 *      DISABLED 立刻变 true；set_visible(FALSE) 一调 HIDDEN 立刻变 true
 *      （未上屏的裸 widget 因无 parent 恒 HIDDEN=true）。所以 Core 的 state
 *      位包里 bit0 visible / bit1 enabled **一律不注记**——把重排那一刻的快照
 *      盖到活值上，正是 T58 在 MSAA 上量出来的谎报（show 之前定格 INVISIBLE、
 *      点勾选框后不跟随）。这里只下发 bits2-3 的 checked。
 *   ④ CHECKED 与 role 无关：在 GENERIC 的 GtkFixed 上注记，test API 照样读到；
 *      reset_state(CHECKED) 能把它清回 undefined。所以 P6-5 的 Checkbox 叶子
 *      还没造出来时，这一层也已经是可验的。
 *   ⑤ 4.20+ 才有 gtk-interface-contrast（枚举常量 Since 4.20，4.6 口径编译期
 *      不能引用），四个值按 GEnum **名字**运行时查：UNSUPPORTED=0 /
 *      NO_PREFERENCE=1 / MORE=2 / LESS=3；**MORE 才是高对比**。
 *      探针实测它与 color-scheme / prefer-dark / theme-name / animations
 *      **都不联动**（与 P6-4b 的 scheme 联动不同），判据不必复位别的属性。
 *   ⑥ gtk-enable-animations 是 4.0 起的 gboolean，关掉即"减少动态效果"。
 *   ⑦ (ptr,len) 是 UTF-8 字节串、不保证 NUL 结尾，也可能内嵌 NUL：探针用
 *      "登录按钮\0尾巴" + len=12 验过 g_strndup 那套按长度复制的形状。
 * ========================================================================= */

/* 按 GEnum 名字查值。role 表是 4.0 的 GEnum（用 GTK_TYPE_ACCESSIBLE_ROLE），
 * contrast 表是 4.20+ 的（从 GParamSpec 拿 GType）——两边都不硬编码数值，
 * 也不引用编译期不存在的枚举常量。 */
static int moonui_gtk_a11y_enum_value(GType type, const char *name) {
  GEnumClass *ec;
  GEnumValue *v;
  int out = -1;
  if (type == 0 || name == NULL) return -1;
  ec = (GEnumClass *)g_type_class_ref(type);
  if (ec != NULL) {
    v = g_enum_get_value_by_name(ec, name);
    if (v != NULL) out = v->value;
    g_type_class_unref(ec);
  }
  return out;
}

static int moonui_gtk_a11y_role_value(const char *name) {
  return moonui_gtk_a11y_enum_value(GTK_TYPE_ACCESSIBLE_ROLE, name);
}

/* 空串 / NULL / 负长度都表示"这一项没有"：不是保留上一轮的值，而是把 GTK 那边
 * 的属性清掉。Core 每次重排推的是**完整语义**（T41 完成注的定案），留旧值会让
 * 一个已经撤掉标签的控件继续被读屏器念出旧名字。 */
static void moonui_gtk_a11y_set_text(GtkWidget *w, GtkAccessibleProperty prop,
                                     const char *p, int len) {
  char *s = moonui_gtk_a11y_text(p, len);
  if (s != NULL) {
    gtk_accessible_update_property(GTK_ACCESSIBLE(w), prop, s, -1);
    free(s);
  } else {
    gtk_accessible_reset_property(GTK_ACCESSIBLE(w), prop);
  }
}

int moonui_native_set_widget_accessibility(moonui_ptr c, int role,
                                    const char *label, int label_len,
                                    const char *desc, int desc_len,
                                    int state) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  const char *role_name;
  int role_value, checked;

  if (w == NULL) return -1;

  /* 未知 role 不动 widget 自己的默认角色（mac 半同样是"咽下 role"），但 label /
   * desc / state 照常下发——不能因为一个没认出的角色号就把整轮语义丢掉。 */
  role_name = moonui_gtk_a11y_role_name(role);
  if (role_name != NULL) {
    role_value = moonui_gtk_a11y_role_value(role_name);
    if (role_value >= 0)
      g_object_set(G_OBJECT(w), "accessible-role", role_value, NULL);
  }

  moonui_gtk_a11y_set_text(w, GTK_ACCESSIBLE_PROPERTY_LABEL, label, label_len);
  moonui_gtk_a11y_set_text(w, GTK_ACCESSIBLE_PROPERTY_DESCRIPTION,
                           desc, desc_len);

  /* state 位包只消费 bits2-3（0=无此态 1=未勾 2=已勾 3=混合）。
   * bit0/bit1 由 GTK 按 widget 活值自己算，见文件头 ③。 */
  checked = moonui_gtk_a11y_checked(state);
  if (checked == 0) {
    gtk_accessible_reset_state(GTK_ACCESSIBLE(w), GTK_ACCESSIBLE_STATE_CHECKED);
  } else {
    int tri = (checked == 1) ? GTK_ACCESSIBLE_TRISTATE_FALSE
            : (checked == 2) ? GTK_ACCESSIBLE_TRISTATE_TRUE
                             : GTK_ACCESSIBLE_TRISTATE_MIXED;
    gtk_accessible_update_state(GTK_ACCESSIBLE(w),
                                GTK_ACCESSIBLE_STATE_CHECKED, tri, -1);
  }
  return 0;
}

int moonui_native_prefers_reduced_motion(void) {
  GtkSettings *settings = gtk_settings_get_default();
  GObjectClass *klass;
  gboolean enable_animations = FALSE;

  if (settings == NULL) return 0; /* 没 init / 已 terminate：读不到当"偏好关" */
  klass = G_OBJECT_GET_CLASS(settings);
  if (g_object_class_find_property(klass, "gtk-enable-animations") == NULL)
    return 0;
  g_object_get(settings, "gtk-enable-animations", &enable_animations, NULL);
  return moonui_gtk_a11y_reduced_motion(1, enable_animations ? 1 : 0);
}

int moonui_native_prefers_high_contrast(void) {
  GtkSettings *settings = gtk_settings_get_default();
  GObjectClass *klass;
  GParamSpec *ps;
  int contrast = 0;
  int more = -1, less = -1, no_pref = -1, unsupported = -1;
  char *theme = NULL, *icon_theme = NULL;
  int out;

  if (settings == NULL) return 0;
  klass = G_OBJECT_GET_CLASS(settings);
  ps = g_object_class_find_property(klass, "gtk-interface-contrast");
  if (ps != NULL) {
    GType type = G_PARAM_SPEC_VALUE_TYPE(ps);
    more = moonui_gtk_a11y_enum_value(type, "GTK_INTERFACE_CONTRAST_MORE");
    less = moonui_gtk_a11y_enum_value(type, "GTK_INTERFACE_CONTRAST_LESS");
    no_pref = moonui_gtk_a11y_enum_value(type,
                                         "GTK_INTERFACE_CONTRAST_NO_PREFERENCE");
    unsupported = moonui_gtk_a11y_enum_value(type,
                                         "GTK_INTERFACE_CONTRAST_UNSUPPORTED");
    g_object_get(settings, "gtk-interface-contrast", &contrast, NULL);
  }
  /* 4.6 上没有新属性时（more=-1）走纯回落；4.20+ 的 UNSUPPORTED /
   * NO_PREFERENCE 也走回落，因为 GNOME 的 HighContrast 主题名是那一代唯一的
   * 线索。两条主题名都得看：有的发行版只换 icon theme。 */
  g_object_get(settings, "gtk-theme-name", &theme, NULL);
  g_object_get(settings, "gtk-icon-theme-name", &icon_theme, NULL);
  out = moonui_gtk_a11y_high_contrast(contrast, more, less, no_pref,
                                      unsupported, theme, icon_theme);
  g_free(theme);
  g_free(icon_theme);
  return out;
}

int moonui_native_custom_set_focusable(moonui_ptr c, int on) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  if (w == NULL) return -1;
  /* 契约：只对自绘面（kind 18）生效，别的控件是空操作、也返回 0。
   * GTK 的 focusable 是 widget 属性，进不进 Tab 链由它自己算；这里不碰
   * focused_control / set_focus_chain（那一片属 P6-5）。 */
  if (moonui_widget_kind_of(w) == 18)
    gtk_widget_set_focusable(w, on ? TRUE : FALSE);
  return 0;
}
