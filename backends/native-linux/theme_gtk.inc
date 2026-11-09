/* =========================================================================
 * T235 P6-4b：系统外观读数 + 控件样式下发（第六片 IMPL_FILES）
 *
 * 两条 ABI：moonui_native_system_theme / moonui_native_widget_set_style。
 * 纯逻辑（CSS 文本拼装、深色判定）在生成物 prelude 里，假头闸也能真跑；
 * 这里只碰真 GTK 对象。
 *
 * 形态全部由 2026-11-09 真 GTK4 4.24 探针实测定下（不是照文档猜）：
 *   ① gtk_init_check() 在没有显示器的 macOS 上也返回 1，且
 *      gdk_display_get_default() 非 NULL —— 所以 add_provider_for_display
 *      这一路在本机真跑得了。
 *   ② GtkSettings 的深色读口分两代：
 *      - 4.20+ 有 gtk-interface-color-scheme（枚举，nick dark/light）。GTK 4.24
 *        每次读旧的 gtk-application-prefer-dark-theme 都会打一条
 *        "Use GtkSettings:gtk-interface-color-scheme instead" 的提示（提示不是
 *        错误，写在这里免得后来者去"修"）；枚举常量本身 Since 4.20，编译期
 *        不能引用，所以运行时按 GEnum **名字**查值，不硬编码 2。
 *      - 4.6 上只有 gtk-application-prefer-dark-theme 与 gtk-theme-name。
 *        g_object_set(theme-name, "Adwaita:dark") 实测**不会**联动 prefer-dark，
 *        所以两条都得读；否则 GTK_THEME=Adwaita:dark 那种常见设置会漏报。
 *      两条分支在本机都能 A/B：把新属性设成 default 就回落到旧属性。
 *   ③ CSS 下发：GtkCssProvider + gtk_style_context_add_provider_for_display
 *      （在 gtkstyleprovider.h、GDK_AVAILABLE_IN_ALL，4.6 可用）+ 每 widget 一个
 *      唯一 CSS class。widget 级的 gtk_style_context_add_provider 在 4.10 才弃用，
 *      但 display 级这条没弃用，正统。
 *   ④ 同一只 provider 重灌 gtk_css_provider_load_from_data 会**即时**更新 widget
 *      样式（探针实测：color 从 rgb(200,100,50) 变 rgb(0,0,255)），所以不需要
 *      每次重建 provider；remove_provider_for_display 之后样式回到默认。
 *   ⑤ gtk_css_provider_new() 返回的已经不是 floating（探针 is_floating=0），
 *      不能再 ref_sink —— 那会多持一份、销毁时漏放。引用账见下面 free。
 *   ⑥ gtk_style_context_to_string(SHOW_STYLE) 在控件未排版时只打印节点路径，
 *      读不到 background-color / border-radius；能读解析结果的是
 *      gtk_style_context_get_color 与 gtk_widget_get_pango_context。背景与圆角
 *      那一层用 gtk_css_provider_to_string 读（GTK 的 CSS 解析器规范化后的文本，
 *      不是我们手写的原串），**上屏后的真实像素只有 Linux 真机 + xvfb 能验**。
 * ========================================================================= */

typedef struct {
  int64_t bg_rgb;
  int64_t fg_rgb;
  int radius_pm;
  int font_pm;
  int weight;
  char cls[48];              /* moonui-w-<十六进制地址> */
  GtkCssProvider *provider;
  GdkDisplay *display;
  int attached;
} MoonuiGtkStyleState;

/* 引用账：new 给 1 份（我们持有），add_provider_for_display 让 display 再持 1 份。
 * 控件 finalize 时先 remove（display 放掉那份），再 unref 我们这份 → 0。
 * 只在 display 还是当初那只时才 remove：terminate 之后 display 可能已经不在，
 * 那时 GTK 自己会清 provider 列表，硬 remove 反而是对着失效指针操作。 */
static void moonui_gtk_style_state_free(gpointer data) {
  MoonuiGtkStyleState *st = (MoonuiGtkStyleState *)data;
  if (st == NULL) return;
  if (st->provider != NULL) {
    GdkDisplay *now = gdk_display_get_default();
    if (st->attached && now != NULL && now == st->display) {
      gtk_style_context_remove_provider_for_display(
          now, GTK_STYLE_PROVIDER(st->provider));
    }
    g_object_unref(st->provider);
  }
  free(st);
}

/* 4.6 上编译期没有 GTK_INTERFACE_COLOR_SCHEME_DARK 这个常量（Since 4.20），
 * 更不能把枚举值 2 写死；按 GEnum 的名字在运行时查，查不到就当属性不存在。 */
static int moonui_gtk_enum_value_by_name(GParamSpec *ps, const char *name) {
  GEnumClass *ec;
  GEnumValue *v;
  int out = -1;
  if (ps == NULL || !G_IS_PARAM_SPEC_ENUM(ps)) return -1;
  ec = (GEnumClass *)g_type_class_ref(G_PARAM_SPEC_VALUE_TYPE(ps));
  if (ec != NULL) {
    v = g_enum_get_value_by_name(ec, name);
    if (v != NULL) out = v->value;
    g_type_class_unref(ec);
  }
  return out;
}

/* 把 widget 地址编进 class 名：CSS class 只允许字母数字与连字符，用十六进制。
 * 不用十进制/自增序号，是为了避免"新控件复用了旧控件的名字、继承旧样式"——
 * 那是 T110 记过的老课。 */
static void moonui_gtk_style_class(char *out, int cap, GtkWidget *w) {
  static const char hex[] = "0123456789abcdef";
  unsigned long long v = (unsigned long long)(uintptr_t)w;
  char buf[20];
  int i = 0, j;
  memcpy(out, "moonui-w-", 9);
  j = 9;
  if (v == 0) buf[i++] = '0';
  while (v > 0 && i < (int)sizeof(buf)) {
    buf[i++] = hex[v & 0xFULL];
    v >>= 4;
  }
  while (i > 0 && j < cap - 1) out[j++] = buf[--i];
  out[j < cap ? j : cap - 1] = '\0';
}

int moonui_native_system_theme(void) {
  GtkSettings *settings;
  GObjectClass *klass;
  GParamSpec *ps;
  int scheme = 0, dark_value = -1, light_value = -1;
  gboolean prefer_dark = FALSE;
  char *theme_name = NULL;
  int out;

  settings = gtk_settings_get_default();
  if (settings == NULL) return 0; /* 没 init / 已经 terminate：读不到当浅色 */
  klass = G_OBJECT_GET_CLASS(settings);
  ps = g_object_class_find_property(klass, "gtk-interface-color-scheme");
  if (ps != NULL) {
    dark_value = moonui_gtk_enum_value_by_name(
        ps, "GTK_INTERFACE_COLOR_SCHEME_DARK");
    light_value = moonui_gtk_enum_value_by_name(
        ps, "GTK_INTERFACE_COLOR_SCHEME_LIGHT");
    g_object_get(settings, "gtk-interface-color-scheme", &scheme, NULL);
  }
  /* 新属性明说 DARK / LIGHT 时不再碰老属性（少一条 4.20+ 的提示）；
   * DEFAULT / UNSUPPORTED / 属性不存在（4.6）才回落。 */
  if (dark_value < 0 ||
      (scheme != dark_value && (light_value < 0 || scheme != light_value))) {
    g_object_get(settings, "gtk-application-prefer-dark-theme", &prefer_dark,
                 NULL);
  }
  g_object_get(settings, "gtk-theme-name", &theme_name, NULL);
  out = moonui_gtk_theme_dark(scheme, dark_value, light_value,
                              prefer_dark ? 1 : 0, theme_name);
  g_free(theme_name);
  return out;
}

int moonui_native_widget_set_style(moonui_ptr c,
                                   int64_t bg_rgb,
                                   int64_t fg_rgb,
                                   int radius_permille,
                                   int font_permille,
                                   int weight) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiGtkStyleState *st;
  MoonuiMenuText text = {0};
  GdkDisplay *d;
  int kind;

  if (w == NULL) return -1;
  kind = moonui_widget_kind_of(w);
  if (kind != 0 && kind != 1 && kind != 17) return 0; /* 不认识的 kind 静默忽略 */
  d = gdk_display_get_default();
  if (d == NULL) return 0; /* 还没 init：读不到，不是失败 */

  st = (MoonuiGtkStyleState *)g_object_get_data(G_OBJECT(w), "moonui-gtk-style");
  if (st == NULL) {
    st = (MoonuiGtkStyleState *)calloc(1, sizeof(*st));
    if (st == NULL) return -1;
    st->bg_rgb = -1;
    st->fg_rgb = -1;
    st->radius_pm = -1;
    st->font_pm = -1;
    st->weight = -1;
    moonui_gtk_style_class(st->cls, (int)sizeof(st->cls), w);
  }

  /* 各字段是独立通道：-1 表示这一项不动、保持上次的值（adapter.h 段注）。
   * 注意 mac 半只在 font_permille >= 0 时才顺带消费 weight；这里按契约把
   * weight 当独立通道，只改字重也能生效——各平台按自己的能力消费，不改契约。 */
  if (bg_rgb >= 0) st->bg_rgb = bg_rgb;
  if (fg_rgb >= 0) st->fg_rgb = fg_rgb;
  if (radius_permille >= 0) st->radius_pm = radius_permille;
  if (font_permille >= 0) st->font_pm = font_permille;
  if (weight >= 0) st->weight = weight;

  if (moonui_gtk_style_css(&text, st->cls, kind, st->bg_rgb, st->fg_rgb,
                           st->radius_pm, st->font_pm, st->weight) < 0) {
    free(text.p);
    return 0;
  }

  if (st->provider == NULL) {
    st->provider = gtk_css_provider_new();
    if (st->provider == NULL) {
      free(text.p);
      return -1;
    }
    st->display = d;
    gtk_style_context_add_provider_for_display(
        d, GTK_STYLE_PROVIDER(st->provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    st->attached = 1;
    gtk_widget_add_css_class(w, st->cls);
    /* 控件 finalize 时自动摘 provider：widget_destroy 放掉自持那份引用之后
     * 会走到这里，不需要改 widgets_gtk.inc 的销毁链。 */
    g_object_set_data_full(G_OBJECT(w), "moonui-gtk-style", st,
                           moonui_gtk_style_state_free);
    /* 判据要能拿到 GTK 解析后的 CSS 文本（背景/圆角那一层），这里把 provider
     * 单独暴露成一个只读的借用指针；不增引用，生命周期跟着上面的 state。 */
    g_object_set_data(G_OBJECT(w), "moonui-gtk-css-provider", st->provider);
  }
  gtk_css_provider_load_from_data(st->provider, text.p, (gssize)text.len);
  free(text.p);
  return 0;
}
