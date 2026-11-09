/*
 * MoonUI 原生后端 · Linux / GTK4 · 菜单栏与上下文菜单——T235 P6-4。
 *
 * 与 widgets / canvas / clipboard / dialogs 四片同一套规矩：被
 * adapter_native_gtk.c 用 #include 收进**同一个翻译单元**，生成器扫描本文件里
 * 定义的非 static moonui_* 符号并从"桩"里剔除。
 *
 * 这一片有七条 ABI：
 *   菜单栏   set_menu_bar / menu_item_set_checked / menu_dump / menu_tops_dump /
 *            menu_click_item
 *   上下文   show_context_menu / auto_pick_context_menu
 *
 * **GTK4 没有"窗口菜单栏"这个概念**，所以菜单栏是一只有内容的控件
 * （GtkPopoverMenuBar），挂在窗口内容区最上面那一行。窗口内容因此从
 * GtkOverlay 变成 GtkBox[菜单栏, GtkOverlay]——那一步在 prelude 的
 * moonui_gtk_window_set_menubar 里，客户区尺寸的补偿也在那边（与 Win32 半
 * 「SetMenu 之后客户区矮掉一行」同一个问题）。
 *
 * 几处与 mac / Windows 两份不同的落法，都是 GTK 的形态决定的，语义不变：
 *
 *   ① **整棵树译成 GMenuModel + GAction**（GTK4 的正统做法），而不是往某个容器
 *      里塞一堆按钮。可点项各配一只 GSimpleAction，动作名里带角色与编号
 *      （`app.m12` Normal / `app.c12` Check / `app.r12` Radio）——dump 从动作名
 *      反解出 `#12:c+` 这一段，不必另存一本账。
 *   ② **分隔线用 section 表达**：GMenuModel 里没有"分隔线"这种条目，两个 section
 *      之间 GTK 自己画那条线。所以相邻可点项被 section 切开时，dump 里补一个
 *      "-"。代价是**首尾与连续的分隔线会被吞掉**（空 section GTK 不画），这条
 *      记在这里而不是假装没发生。
 *   ③ **radio 的圆点做不到，改用勾**：GTK 的圆点要求同一只字符串状态的动作 +
 *      不同 target（它按 action 分组），而 §25 的互斥是 Core 算的、推下来的只有
 *      "这一项勾没勾"。mac 半是同一个取舍（AppKit 的圆点也只给同一 action 的
 *      分组），两边都显示勾、语义相同。
 *   ④ **快捷键显示走 GMenu 的 "accel" 属性**：GTK 自己把 `<Control><Shift>q`
 *      渲染成 `⌃⇧Q`（本机实测，见探针）。与 mac 把字母映射成 keyEquivalent、
 *      Windows 把组合拼在标题后面一样，显示与派发同源——派发仍归 Core 的事件
 *      循环，这里只借 GTK 的显示。
 *
 * 都不带窗口句柄（§25 的门面是应用级）：上下文菜单按"当下的窗口"挑，菜单栏装到
 * 所有活窗口上，之后新建的窗口由 window_new 的钩子补装（prelude 里那只
 * moonui_gtk_menu_attach_hook 指针）。
 */

/* ---- 状态 ---- */

/* 当前那棵菜单栏。所有窗口各挂一只 GtkPopoverMenuBar，共用同一个模型与同一个
 * 动作组（GMenuModel / GActionGroup 都是可以被多个控件引用的对象）。 */
static GMenuModel *moonui_menu_model = NULL;
static GSimpleActionGroup *moonui_menu_group = NULL;
static moonui_closure_id_fn moonui_menu_fn = NULL;
static void *moonui_menu_closure = NULL;

/* 上下文菜单是"一次调用一棵"：模型、动作组、闭包都活在这次调用的调用栈里。 */
static moonui_closure_id_fn moonui_ctx_fn = NULL;
static void *moonui_ctx_closure = NULL;
static GtkPopover *moonui_ctx_live = NULL;
/* 本次上下文菜单的动作组（替按定时器要靠它派发）。与 moonui_ctx_live 同生命周期。 */
static GSimpleActionGroup *moonui_ctx_group_for_pick = NULL;
static guint moonui_ctx_pick_source = 0;
static int moonui_ctx_pick_ms = -1;
static int moonui_ctx_pick_index = -1;
/* 定时器真正要点的那个序号。**必须在装定时器那一刻抄一份**：`pick_index` 装完就
 * 归 -1（下一次 auto_pick 要重新设），定时器是异步起的，读到的会是那个 -1——那样
 * 每条替按都变成"只关面板、不派发"，看着像"回调没跑到"。 */
static int moonui_ctx_pick_armed = -1;

/* ---- 动作名：`app.<m|c|r><id>` ---- */

static void moonui_gtk_menu_put_int(char *buf, int *pos, int v) {
  char tmp[16];
  int n = 0;
  unsigned u;
  if (v < 0) {
    u = (unsigned)(-(v + 1)) + 1u;
  } else {
    u = (unsigned)v;
  }
  do {
    tmp[n++] = (char)('0' + (u % 10u));
    u /= 10u;
  } while (u > 0 && n < (int)sizeof(tmp));
  if (v < 0) buf[(*pos)++] = '-';
  while (n > 0) buf[(*pos)++] = tmp[--n];
}

/* 角色字母：m = Normal、c = Check、r = Radio。dump 靠它反解，所以三者的拼法
 * 是格式的一部分，别改。 */
static char moonui_gtk_menu_role_letter(int role) {
  if (role == 1) return 'c';
  if (role == 2) return 'r';
  return 'm';
}

static int moonui_gtk_menu_letter_role(char c) {
  if (c == 'c') return 1;
  if (c == 'r') return 2;
  if (c == 'm') return 0;
  return -1;
}

/* 写 "app.<letter><id>" 或（不带前缀时）"<letter><id>"。 */
static void moonui_gtk_menu_action_name(char *buf, int with_prefix, int role,
                                        int id) {
  int pos = 0;
  if (with_prefix) {
    memcpy(buf, "app.", 4);
    pos = 4;
  }
  buf[pos++] = moonui_gtk_menu_role_letter(role);
  moonui_gtk_menu_put_int(buf, &pos, id);
  buf[pos] = '\0';
}

/* 反解：成功返回 1 并写出角色与编号，不是我们的动作返回 0。 */
static int moonui_gtk_menu_parse_action(const char *name, int *role, int *id) {
  int pos = 0;
  int r;
  int v = 0;
  int digits = 0;
  if (name == NULL) return 0;
  if (strncmp(name, "app.", 4) == 0) pos = 4;
  r = moonui_gtk_menu_letter_role(name[pos]);
  if (r < 0) return 0;
  ++pos;
  while (name[pos] >= '0' && name[pos] <= '9') {
    v = v * 10 + (name[pos] - '0');
    ++pos;
    ++digits;
  }
  if (digits == 0 || name[pos] != '\0') return 0;
  *role = r;
  *id = v;
  return 1;
}

/* ---- 快捷键：Core 词表 ↔ GTK accel 语法 ---- */

/* Core 的键名（event.mbt）→ GTK 的键名。GTK 那边有几个拼法不同（space /
 * Return / BackSpace / Page_Up / Page_Down），不换的话 accel 解析失败、菜单上
 * 就不显示组合（不显示比显示错好，但这条本来就该显示）。 */
static const char *moonui_gtk_menu_key_to_gtk(const char *key) {
  if (key == NULL) return NULL;
  if (strcmp(key, "Space") == 0) return "space";
  if (strcmp(key, "Enter") == 0) return "Return";
  if (strcmp(key, "Backspace") == 0) return "BackSpace";
  if (strcmp(key, "PageUp") == 0) return "Page_Up";
  if (strcmp(key, "PageDown") == 0) return "Page_Down";
  return key;
}

/* 反向。dump 读的是模型里那条 accel 属性（GTK 真正拿去显示的东西），所以这里
 * 要把 GTK 的拼法还原成 Core 的词表，两个平台的对拍才有意义。 */
static const char *moonui_gtk_menu_key_from_gtk(const char *key) {
  if (key == NULL) return NULL;
  if (strcmp(key, "space") == 0) return "Space";
  if (strcmp(key, "Return") == 0) return "Enter";
  if (strcmp(key, "BackSpace") == 0) return "Backspace";
  if (strcmp(key, "Page_Up") == 0) return "PageUp";
  if (strcmp(key, "Page_Down") == 0) return "PageDown";
  return key;
}

/* Core 的 mods 位（bit0 ctrl / bit1 alt / bit2 shift / bit3 meta）→
 * GTK 的 `<Control><Alt><Shift><Meta>` 顺序。顺序固定，dump 反解时按同一套认。 */
static void moonui_gtk_menu_accel_build(char *buf, size_t cap, int mods,
                                        const char *key) {
  const char *k = moonui_gtk_menu_key_to_gtk(key);
  size_t n = 0;
  if (k == NULL || cap == 0) {
    if (cap > 0) buf[0] = '\0';
    return;
  }
  if (mods & 1) {
    memcpy(buf + n, "<Control>", 9);
    n += 9;
  }
  if (mods & 2) {
    memcpy(buf + n, "<Alt>", 5);
    n += 5;
  }
  if (mods & 4) {
    memcpy(buf + n, "<Shift>", 7);
    n += 7;
  }
  if (mods & 8) {
    memcpy(buf + n, "<Meta>", 6);
    n += 6;
  }
  if (n + strlen(k) + 1 > cap) {
    buf[0] = '\0';
    return;
  }
  memcpy(buf + n, k, strlen(k) + 1);
}

/* accel → (mods, Core 键名)。键名的落点在 out_key（调用方给的缓冲）。 */
static void moonui_gtk_menu_accel_parse(const char *accel, int *mods,
                                        char *out_key, size_t cap) {
  size_t pos = 0;
  size_t n;
  *mods = 0;
  if (cap > 0) out_key[0] = '\0';
  if (accel == NULL) return;
  while (accel[pos] == '<') {
    const char *end = strchr(accel + pos, '>');
    if (end == NULL) break;
    n = (size_t)(end - (accel + pos)) - 1;
    if (n == 7 && strncmp(accel + pos + 1, "Control", 7) == 0) *mods |= 1;
    else if (n == 3 && strncmp(accel + pos + 1, "Alt", 3) == 0) *mods |= 2;
    else if (n == 5 && strncmp(accel + pos + 1, "Shift", 5) == 0) *mods |= 4;
    else if (n == 4 && strncmp(accel + pos + 1, "Meta", 4) == 0) *mods |= 8;
    pos = (size_t)(end - accel) + 1;
  }
  {
    const char *k = moonui_gtk_menu_key_from_gtk(accel + pos);
    if (k != NULL && strlen(k) + 1 <= cap) {
      memcpy(out_key, k, strlen(k) + 1);
    }
  }
}

/* ---- 动作 ---- */

static void moonui_gtk_menu_on_activate(GSimpleAction *action, GVariant *param,
                                        gpointer data) {
  int id = GPOINTER_TO_INT(data);
  moonui_closure_id_fn fn = moonui_menu_fn;
  void *cl = moonui_menu_closure;
  (void)action;
  (void)param;
  if (fn != NULL) fn(cl, id);
}

/* 每只可点项一只动作：名字带角色与编号，状态（勾选）只对 check / radio 有。
 * 注意 **check / radio 都不要 target**：带 target 的布尔状态动作在 GTK4 里
 * 初始 active 会变成 FALSE（本机探针实测），而不带 target 的按状态显示勾。 */
static GSimpleAction *moonui_gtk_menu_make_action(const MoonuiMenuNode *node,
                                                  GSimpleActionGroup *group) {
  char name[32];
  GSimpleAction *action;
  moonui_gtk_menu_action_name(name, 0, node->role, node->id);
  if (node->role == 0) {
    action = g_simple_action_new(name, NULL);
  } else {
    action = g_simple_action_new_stateful(name, NULL,
                                          g_variant_new_boolean(node->checked ? TRUE
                                                                            : FALSE));
  }
  if (action == NULL) return NULL;
  g_simple_action_set_enabled(action, node->enabled ? TRUE : FALSE);
  g_signal_connect(action, "activate", G_CALLBACK(moonui_gtk_menu_on_activate),
                   GINT_TO_POINTER(node->id));
  g_action_map_add_action(G_ACTION_MAP(group), G_ACTION(action));
  return action;
}

/* 造一条可点项。accel 是**属性**不是动作的一部分：它只影响显示，派发在 Core。 */
static GMenuItem *moonui_gtk_menu_make_item(const MoonuiMenuNode *node,
                                            GSimpleActionGroup *group) {
  char action[32];
  GMenuItem *item;
  GSimpleAction *act;
  act = moonui_gtk_menu_make_action(node, group);
  if (act == NULL) return NULL;
  moonui_gtk_menu_action_name(action, 1, node->role, node->id);
  item = g_menu_item_new(node->label != NULL ? node->label : "", action);
  if (item != NULL && node->has_shortcut && node->key != NULL) {
    char accel[64];
    moonui_gtk_menu_accel_build(accel, sizeof(accel), node->mods, node->key);
    if (accel[0] != '\0') {
      g_menu_item_set_attribute_value(item, "accel",
                                      g_variant_new_string(accel));
    }
  }
  return item;
}

/* 一层条目 → 一个 GMenu。分隔线把条目切成若干 section（GTK4 的分隔线就是这么
 * 来的）：连续可点项进同一个 section，遇到分隔线就把它交出去、开新的一段。 */
static void moonui_gtk_menu_fill(GMenu *menu, const MoonuiMenuNode *nodes,
                                 int count, GSimpleActionGroup *group) {
  GMenu *section = NULL;
  int i;
  for (i = 0; i < count; ++i) {
    const MoonuiMenuNode *n = &nodes[i];
    if (n->kind == MOONUI_MENU_SEP) {
      if (section != NULL) {
        if (g_menu_model_get_n_items(G_MENU_MODEL(section)) > 0) {
          g_menu_append_section(menu, NULL, G_MENU_MODEL(section));
        }
        g_object_unref(section);
        section = NULL;
      }
      continue;
    }
    if (section == NULL) {
      section = g_menu_new();
      if (section == NULL) return;
    }
    if (n->kind == MOONUI_MENU_SUB) {
      GMenu *sub = g_menu_new();
      if (sub == NULL) continue;
      moonui_gtk_menu_fill(sub, n->children, n->child_count, group);
      g_menu_append_submenu(section, n->label != NULL ? n->label : "",
                            G_MENU_MODEL(sub));
      g_object_unref(sub);
    } else {
      GMenuItem *item = moonui_gtk_menu_make_item(n, group);
      if (item == NULL) continue;
      g_menu_append_item(section, item);
      g_object_unref(item);
    }
  }
  if (section != NULL) {
    if (g_menu_model_get_n_items(G_MENU_MODEL(section)) > 0) {
      g_menu_append_section(menu, NULL, G_MENU_MODEL(section));
    }
    g_object_unref(section);
  }
}

/* ---- 装到窗口上 ---- */

/* 给一只窗口补装菜单栏。window_new 通过 prelude 的钩子指针调到这里；也用于
 * set_menu_bar 给当下所有活窗口装。 */
static void moonui_gtk_menu_attach_window(GtkWidget *win) {
  MoonuiWinSlot *s = moonui_win_slot_of(win);
  GtkWidget *bar;
  if (s == NULL || moonui_menu_model == NULL || s->menubar != NULL) return;
  /* 空树（menu_count = 0）= 没有菜单栏，就当没装。
   *
   * 这一条护栏**不是**为了"少占一行"：实测一只没有条目的 `GtkPopoverMenuBar`
   * `gtk_widget_measure` 出来是 0（负控制：把这一句改成 `if (0) return;`，像素闸
   * 那几条全绿），所以它本来就不占高度。留着它的理由是别把一个活的、DOM 里可达的
   * 空菜单栏挂在树上：换树时它要多算一份引用账，`menu_dump` 也要多走一层"明知是
   * 空的"遍历。等价行为下少一个对象。 */
  if (g_menu_model_get_n_items(moonui_menu_model) == 0) return;
  bar = gtk_popover_menu_bar_new_from_model(moonui_menu_model);
  if (bar == NULL) return;
  /* 自持一份：box 被拆的时候会放掉容器那份，而我们要留到"换一棵菜单"那一步
   * 自己放。这条与控件层 g_object_ref_sink 的账同一套。 */
  g_object_ref_sink(bar);
  gtk_widget_insert_action_group(bar, "app", G_ACTION_GROUP(moonui_menu_group));
  moonui_gtk_window_set_menubar(win, bar);
  if (s->menubar != bar) {
    g_object_unref(bar); /* 窗口没接（内容是别人的）：别漏这一份 */
  }
}

/* 把所有窗口上的菜单栏摘掉并释放我们那份引用。模型与动作组由调用方随后换掉。 */
static void moonui_gtk_menu_detach_all(void) {
  int i;
  for (i = 0; i < MOONUI_WIN_SLOTS; ++i) {
    MoonuiWinSlot *s = &moonui_wins[i];
    GtkWidget *bar;
    if (s->win == NULL || s->menubar == NULL) continue;
    bar = s->menubar;
    moonui_gtk_window_set_menubar(s->win, NULL);
    g_object_unref(bar);
  }
}

static void moonui_gtk_menu_drop(void) {
  if (moonui_menu_group != NULL) {
    g_object_unref(moonui_menu_group);
    moonui_menu_group = NULL;
  }
  if (moonui_menu_model != NULL) {
    g_object_unref(moonui_menu_model);
    moonui_menu_model = NULL;
  }
  if (moonui_menu_closure != NULL) {
    moonbit_decref(moonui_menu_closure);
    moonui_menu_closure = NULL;
  }
  moonui_menu_fn = NULL;
  moonui_gtk_menu_attach_hook = NULL;
}

int moonui_native_set_menu_bar(const char *tree, int tree_len,
                               moonui_closure_id_fn fn, void *closure) {
  MoonuiMenuTree parsed;
  GMenu *root;
  GSimpleActionGroup *group;
  GMenuModel *model;
  int i;
  if (!moonui_inited) return -2;
  /* 先解析、再造新树：失败时旧菜单一动不动地留着（adapter.h 的 -1 那一支）。 */
  if (moonui_menu_parse(tree, tree_len, &parsed) != 0) return -1;
  root = g_menu_new();
  group = g_simple_action_group_new();
  if (root == NULL || group == NULL) {
    if (root != NULL) g_object_unref(root);
    if (group != NULL) g_object_unref(group);
    moonui_menu_tree_free(&parsed);
    return -1;
  }
  for (i = 0; i < parsed.menu_count; ++i) {
    GMenu *menu = g_menu_new();
    if (menu == NULL) continue;
    moonui_gtk_menu_fill(menu, parsed.menus[i].nodes, parsed.menus[i].node_count,
                         group);
    g_menu_append_submenu(root, parsed.menus[i].label != NULL
                                    ? parsed.menus[i].label
                                    : "",
                          G_MENU_MODEL(menu));
    g_object_unref(menu);
  }
  moonui_menu_tree_free(&parsed);
  model = G_MENU_MODEL(root); /* root 的那份引用转给 model */
  /* 新树建完了，从这里开始才动屏幕上那棵。 */
  moonui_gtk_menu_detach_all();
  moonui_gtk_menu_drop();
  moonui_menu_model = model;
  moonui_menu_group = group;
  moonui_gtk_menu_attach_hook = moonui_gtk_menu_attach_window;
  for (i = 0; i < MOONUI_WIN_SLOTS; ++i) {
    if (moonui_wins[i].win != NULL) {
      moonui_gtk_menu_attach_window(moonui_wins[i].win);
    }
  }
  moonui_closure_id_replace(&moonui_menu_fn, &moonui_menu_closure, fn,
                            closure);
  return 0;
}

/* id → 动作。三个前缀挨个问：角色编在动作名里，而这里只有 id。 */
static GAction *moonui_gtk_menu_find_action(int id) {
  char name[32];
  int role;
  if (moonui_menu_group == NULL) return NULL;
  for (role = 0; role <= 2; ++role) {
    GAction *a;
    moonui_gtk_menu_action_name(name, 0, role, id);
    a = g_action_map_lookup_action(G_ACTION_MAP(moonui_menu_group), name);
    if (a != NULL) return a;
  }
  return NULL;
}

int moonui_native_menu_item_set_checked(int id, int checked) {
  GAction *action = moonui_gtk_menu_find_action(id);
  GVariant *state;
  if (action == NULL) return -1;
  /* "有没有状态"用 g_action_get_state 判，不拿 state 类型去比 G_VARIANT_TYPE_BOOLEAN
   * ——那两个是**指针**，直接 == 比的是地址（-Wstring-compare 会报，判据也会歪）。 */
  state = g_action_get_state(action);
  if (state == NULL) {
    return 0; /* Normal 项没有状态：改勾选是空操作，仍报"找到了"（同 mac） */
  }
  g_variant_unref(state);
  g_simple_action_set_state(G_SIMPLE_ACTION(action),
                            g_variant_new_boolean(checked ? TRUE : FALSE));
  return 0;
}

int moonui_native_menu_click_item(int id) {
  GAction *action = moonui_gtk_menu_find_action(id);
  if (action == NULL) return -1;
  if (!g_action_get_enabled(action)) return -2;
  /* 走动作组而不是直接调闭包：与用户点菜单项同一条路（GtkModelButton 激活的
   * 也是这只动作），于是"点一项 → 回调 → Core 推勾选"整条链在测试里真跑。 */
  g_action_group_activate_action(G_ACTION_GROUP(moonui_menu_group),
                                 g_action_get_name(action), NULL);
  return 0;
}

/* ---- dump：读**真正挂在窗口上**的那个模型 ---- */

/* 找一只挂着菜单栏的窗口（dump 的读取点）。没有就返回 NULL。 */
static GtkWidget *moonui_gtk_menu_any_bar(void) {
  int i;
  for (i = 0; i < MOONUI_WIN_SLOTS; ++i) {
    if (moonui_wins[i].win != NULL && moonui_wins[i].menubar != NULL) {
      return moonui_wins[i].menubar;
    }
  }
  return NULL;
}

static int moonui_gtk_menu_dump_model(GMenuModel *model, MoonuiMenuText *t);

/* 一条可点项 / 子菜单 / （不可能出现的）分隔线。返回 1 = 写了东西。
 * 写进临时缓冲再由调用方决定要不要前置逗号：认不出来的条目要能整条跳过，
 * 而不是先写了逗号再发现该跳过。 */
static int moonui_gtk_menu_dump_node(GMenuModel *model, int index,
                                     MoonuiMenuText *t) {
  GMenuModel *sub;
  char *label = NULL;
  int wrote = 0;
  sub = g_menu_model_get_item_link(model, index, G_MENU_LINK_SUBMENU);
  if (sub != NULL) {
    GVariant *lv = g_menu_model_get_item_attribute_value(
        model, index, "label", G_VARIANT_TYPE_STRING);
    if (lv != NULL) {
      label = g_variant_dup_string(lv, NULL);
      g_variant_unref(lv);
    }
    moonui_menu_text_put(t, "+");
    moonui_menu_text_put(t, label != NULL ? label : "");
    moonui_menu_text_put(t, "{");
    moonui_gtk_menu_dump_model(sub, t);
    moonui_menu_text_put(t, "}");
    g_free(label);
    g_object_unref(sub);
    return 1;
  }
  {
    GVariant *av = g_menu_model_get_item_attribute_value(
        model, index, G_MENU_ATTRIBUTE_ACTION, G_VARIANT_TYPE_STRING);
    char *action = (av != NULL) ? g_variant_dup_string(av, NULL) : NULL;
    int role = 0;
    int id = 0;
    if (av != NULL) g_variant_unref(av);
    if (action == NULL || !moonui_gtk_menu_parse_action(action, &role, &id)) {
      g_free(action);
      return 0; /* 不是我们装的项：跳过（同 mac 的"不认领就别编一个假的"） */
    }
    {
      GVariant *lv = g_menu_model_get_item_attribute_value(
          model, index, "label", G_VARIANT_TYPE_STRING);
      const char *name = strchr(action, '.');
      GAction *ga = NULL;
      int checked = 0;
      int enabled = 1;
      int mods = 0;
      char key[32];
      if (lv != NULL) {
        label = g_variant_dup_string(lv, NULL);
        g_variant_unref(lv);
      }
      name = (name != NULL) ? name + 1 : action;
      ga = g_action_map_lookup_action(G_ACTION_MAP(moonui_menu_group), name);
      if (ga != NULL) {
        GVariant *state;
        enabled = g_action_get_enabled(ga) ? 1 : 0;
        state = g_action_get_state(ga);
        if (state != NULL) {
          if (g_variant_is_of_type(state, G_VARIANT_TYPE_BOOLEAN)) {
            checked = g_variant_get_boolean(state) ? 1 : 0;
          }
          g_variant_unref(state);
        }
      }
      {
        GVariant *sv = g_menu_model_get_item_attribute_value(
            model, index, "accel", G_VARIANT_TYPE_STRING);
        if (sv != NULL) {
          char *accel = g_variant_dup_string(sv, NULL);
          moonui_gtk_menu_accel_parse(accel, &mods, key, sizeof(key));
          g_free(accel);
          g_variant_unref(sv);
        } else {
          key[0] = '\0';
        }
      }
      moonui_menu_format_item(t, id, role, checked, enabled,
                              label != NULL ? label : "", key[0] != '\0',
                              mods, key);
      g_free(label);
      wrote = 1;
    }
    g_free(action);
  }
  return wrote;
}

/* 一层模型 → 节点串。模型里的东西是 section（我们自己装的时候永远如此），
 * section 之间补一个 "-"；section 里也可能有子菜单（它同样先用 label + link
 * 认领）。别处塞进来的东西不认领。 */
static int moonui_gtk_menu_dump_model(GMenuModel *model, MoonuiMenuText *t) {
  int n = g_menu_model_get_n_items(model);
  int i;
  int need_comma = 0;
  int sections = 0;
  for (i = 0; i < n; ++i) {
    GMenuModel *section = g_menu_model_get_item_link(model, i,
                                                     G_MENU_LINK_SECTION);
    int j;
    int sn;
    if (section == NULL) continue;
    sn = g_menu_model_get_n_items(section);
    if (sn <= 0) {
      g_object_unref(section);
      continue;
    }
    if (sections > 0) {
      if (need_comma) moonui_menu_text_put(t, ",");
      moonui_menu_text_put(t, "-");
      need_comma = 1;
    }
    for (j = 0; j < sn; ++j) {
      MoonuiMenuText one = {0};
      if (moonui_gtk_menu_dump_node(section, j, &one) && one.p != NULL) {
        if (need_comma) moonui_menu_text_put(t, ",");
        moonui_menu_text_put(t, one.p);
        need_comma = 1;
      }
      free(one.p);
    }
    ++sections;
    g_object_unref(section);
  }
  return sections;
}

/* 顶层模型 → 全部顶。
 *
 * 注意顶层的形状与"某一顶里面"**不一样**：顶层是一串子菜单（每顶一个，见
 * set_menu_bar 里的 append_submenu），而一顶里面是一串 section。所以这里按
 * submenu 链接走，每顶写出 `Label{…}`，顶之间用 `;`——与 adapter.h 那段文本
 * 同一套拼法。
 */
static int moonui_gtk_menu_dump_root(GMenuModel *root, MoonuiMenuText *t) {
  int n = g_menu_model_get_n_items(root);
  int i;
  int wrote = 0;
  for (i = 0; i < n; ++i) {
    GMenuModel *sub = g_menu_model_get_item_link(root, i, G_MENU_LINK_SUBMENU);
    GVariant *lv;
    char *label = NULL;
    if (sub == NULL) continue; /* 顶层不是子菜单的东西不认领 */
    lv = g_menu_model_get_item_attribute_value(root, i, "label",
                                               G_VARIANT_TYPE_STRING);
    if (lv != NULL) {
      label = g_variant_dup_string(lv, NULL);
      g_variant_unref(lv);
    }
    if (wrote) moonui_menu_text_put(t, ";");
    moonui_menu_text_put(t, label != NULL ? label : "");
    moonui_menu_text_put(t, "{");
    moonui_gtk_menu_dump_model(sub, t);
    moonui_menu_text_put(t, "}");
    wrote = 1;
    g_free(label);
    g_object_unref(sub);
  }
  return wrote;
}

moonbit_bytes_t moonui_native_menu_dump(void) {
  GtkWidget *bar = moonui_gtk_menu_any_bar();
  GMenuModel *model;
  MoonuiMenuText text = {0};
  moonbit_bytes_t out;
  if (bar == NULL) return moonbit_make_bytes(0, 0);
  model = gtk_popover_menu_bar_get_menu_model(GTK_POPOVER_MENU_BAR(bar));
  if (model == NULL) return moonbit_make_bytes(0, 0);
  moonui_gtk_menu_dump_root(model, &text);
  if (text.len == 0) {
    free(text.p);
    return moonbit_make_bytes(0, 0);
  }
  out = moonui_bytes_of(text.p);
  free(text.p);
  return out;
}

/* 只给测试用（`T205`）：主菜单**全部顶**的标题。
 *
 * Linux / GTK 没有"应用菜单"这个概念（没有哪一顶归系统接管），所以这里与
 * Windows 半一致：返回空 bytes。测试里这条钉的是"这个平台没有这个形状"，
 * 而不是"读不到"——`T205` 那条判据本来就只对 mac 断言。
 * 菜单栏自己的顶名走 menu_dump（那份才验得到）。 */
moonbit_bytes_t moonui_native_menu_tops_dump(void) {
  return moonbit_make_bytes(0, 0);
}

/* ---- 上下文菜单 ---- */

static void moonui_gtk_ctx_on_activate(GSimpleAction *action, GVariant *param,
                                       gpointer data) {
  int id = GPOINTER_TO_INT(data);
  moonui_closure_id_fn fn = moonui_ctx_fn;
  void *cl = moonui_ctx_closure;
  (void)action;
  (void)param;
  if (fn != NULL) fn(cl, id);
}

static GSimpleAction *moonui_gtk_ctx_make_action(const MoonuiMenuNode *node,
                                                 GSimpleActionGroup *group) {
  char name[32];
  GSimpleAction *action;
  moonui_gtk_menu_action_name(name, 0, node->role, node->id);
  if (node->role == 0) {
    action = g_simple_action_new(name, NULL);
  } else {
    action = g_simple_action_new_stateful(
        name, NULL, g_variant_new_boolean(node->checked ? TRUE : FALSE));
  }
  if (action == NULL) return NULL;
  g_simple_action_set_enabled(action, node->enabled ? TRUE : FALSE);
  g_signal_connect(action, "activate", G_CALLBACK(moonui_gtk_ctx_on_activate),
                   GINT_TO_POINTER(node->id));
  g_action_map_add_action(G_ACTION_MAP(group), G_ACTION(action));
  return action;
}

static void moonui_gtk_ctx_fill(GMenu *menu, const MoonuiMenuNode *nodes,
                                int count, GSimpleActionGroup *group) {
  GMenu *section = NULL;
  int i;
  for (i = 0; i < count; ++i) {
    const MoonuiMenuNode *n = &nodes[i];
    if (n->kind == MOONUI_MENU_SEP) {
      if (section != NULL) {
        if (g_menu_model_get_n_items(G_MENU_MODEL(section)) > 0) {
          g_menu_append_section(menu, NULL, G_MENU_MODEL(section));
        }
        g_object_unref(section);
        section = NULL;
      }
      continue;
    }
    if (section == NULL) {
      section = g_menu_new();
      if (section == NULL) return;
    }
    if (n->kind == MOONUI_MENU_SUB) {
      GMenu *sub = g_menu_new();
      if (sub == NULL) continue;
      moonui_gtk_ctx_fill(sub, n->children, n->child_count, group);
      g_menu_append_submenu(section, n->label != NULL ? n->label : "",
                            G_MENU_MODEL(sub));
      g_object_unref(sub);
    } else {
      GMenuItem *item;
      GSimpleAction *act = moonui_gtk_ctx_make_action(n, group);
      if (act == NULL) continue;
      {
        char action[32];
        moonui_gtk_menu_action_name(action, 1, n->role, n->id);
        item = g_menu_item_new(n->label != NULL ? n->label : "", action);
      }
      if (item != NULL && n->has_shortcut && n->key != NULL) {
        char accel[64];
        moonui_gtk_menu_accel_build(accel, sizeof(accel), n->mods, n->key);
        if (accel[0] != '\0') {
          g_menu_item_set_attribute_value(item, "accel",
                                          g_variant_new_string(accel));
        }
      }
      if (item != NULL) {
        g_menu_append_item(section, item);
        g_object_unref(item);
      }
    }
  }
  if (section != NULL) {
    if (g_menu_model_get_n_items(G_MENU_MODEL(section)) > 0) {
      g_menu_append_section(menu, NULL, G_MENU_MODEL(section));
    }
    g_object_unref(section);
  }
}

/* "ms 毫秒之后点第 index 项"：index 数的是**顶层条目的扁平序列**（分隔线也算一格，
 * 与 mac 的 itemArray 同口径）。越界或落在分隔线/子菜单标题/禁用项上时只关面板、
 * 不派发——写错的脚手架要红在"没收到回调"上，不变成一条挂住的测试。 */
static gboolean moonui_gtk_ctx_on_pick(gpointer data) {
  MoonuiMenuTree *tree = (MoonuiMenuTree *)data;
  int index = moonui_ctx_pick_armed;
  GtkPopover *pop = moonui_ctx_live;
  moonui_ctx_pick_source = 0; /* 这一源只跑一次：自己销账，别让清理那步再 remove */
  moonui_ctx_pick_armed = -1;
  if (pop == NULL) return G_SOURCE_REMOVE;
  if (index >= 0 && tree != NULL && tree->menu_count > 0 &&
      index < tree->menus[0].node_count) {
    const MoonuiMenuNode *n = &tree->menus[0].nodes[index];
    if (n->kind == MOONUI_MENU_ITEM && n->enabled) {
      char name[32];
      moonui_gtk_menu_action_name(name, 0, n->role, n->id);
      if (moonui_ctx_group_for_pick != NULL) {
        g_action_group_activate_action(G_ACTION_GROUP(moonui_ctx_group_for_pick),
                                       name, NULL);
      }
    }
  }
  gtk_popover_popdown(pop);
  return G_SOURCE_REMOVE;
}

int moonui_native_auto_pick_context_menu(int ms, int index) {
  if (index < -1) return -1;
  moonui_ctx_pick_ms = ms < 0 ? 0 : ms;
  moonui_ctx_pick_index = index;
  return 0;
}

static void moonui_gtk_ctx_drop_closure(void) {
  if (moonui_ctx_closure != NULL) {
    moonbit_decref(moonui_ctx_closure);
    moonui_ctx_closure = NULL;
  }
  moonui_ctx_fn = NULL;
}

static void moonui_gtk_ctx_on_closed(GtkPopover *pop, gpointer data) {
  GMainLoop *loop = (GMainLoop *)data;
  (void)pop;
  if (loop != NULL) g_main_loop_quit(loop);
}

int moonui_native_show_context_menu(const char *tree, int tree_len,
                                    moonui_closure_id_fn fn, void *closure) {
  MoonuiMenuTree parsed;
  GtkWidget *win = NULL;
  GtkWidget *parent;
  GtkWidget *pop;
  GMenu *root;
  GSimpleActionGroup *group;
  GMainLoop *loop;
  int i;
  int rc = 0;
  if (!moonui_inited) return -2;
  if (tree == NULL || tree_len < 5) return -1;
  if (moonui_menu_parse(tree, tree_len, &parsed) != 0) return -1;
  if (parsed.menu_count < 1) {
    moonui_menu_tree_free(&parsed);
    return -1; /* 上下文菜单至少要有一层条目（同 mac 的 count < 1） */
  }
  for (i = 0; i < MOONUI_WIN_SLOTS; ++i) {
    if (moonui_wins[i].win == NULL) continue;
    if (win == NULL) win = moonui_wins[i].win;
    if (gtk_window_is_active(GTK_WINDOW(moonui_wins[i].win))) {
      win = moonui_wins[i].win;
      break;
    }
  }
  if (win == NULL) {
    moonui_menu_tree_free(&parsed);
    return -2; /* 没有窗口就没有可挂的面（mac 半同一条） */
  }
  parent = moonui_gtk_window_fixed(win, 1);
  if (parent == NULL) {
    moonui_menu_tree_free(&parsed);
    return -2;
  }
  root = g_menu_new();
  group = g_simple_action_group_new();
  if (root == NULL || group == NULL) {
    if (root != NULL) g_object_unref(root);
    if (group != NULL) g_object_unref(group);
    moonui_menu_tree_free(&parsed);
    return -2;
  }
  moonui_gtk_ctx_fill(root, parsed.menus[0].nodes, parsed.menus[0].node_count,
                      group);
  pop = gtk_popover_menu_new_from_model(G_MENU_MODEL(root));
  if (pop == NULL) {
    g_object_unref(group);
    g_object_unref(root);
    moonui_menu_tree_free(&parsed);
    return -2;
  }
  gtk_widget_insert_action_group(pop, "app", G_ACTION_GROUP(group));
  gtk_widget_set_parent(pop, parent);
  gtk_popover_set_has_arrow(GTK_POPOVER(pop), FALSE);
  /* 弹在鼠标当下那个点（根指针位置）：右键菜单的标准位置就是它。读不到的
   * 时候（无显示器 / 没有指针）就用 GTK 的默认位置——不为了一个位置读数让整个
   * 调用失败。 */
  {
    GdkDisplay *display = gdk_display_get_default();
    GdkSeat *seat = display != NULL ? gdk_display_get_default_seat(display) : NULL;
    GdkDevice *pointer = seat != NULL ? gdk_seat_get_pointer(seat) : NULL;
    GtkNative *native = gtk_widget_get_native(parent);
    GdkSurface *surface = native != NULL ? gtk_native_get_surface(native) : NULL;
    double px = 0.0;
    double py = 0.0;
    GdkModifierType mask = 0;
    if (pointer != NULL && surface != NULL &&
        gdk_surface_get_device_position(surface, pointer, &px, &py, &mask)) {
      GdkRectangle rect;
      rect.x = (int)px;
      rect.y = (int)py;
      rect.width = 1;
      rect.height = 1;
      gtk_popover_set_pointing_to(GTK_POPOVER(pop), &rect);
    }
  }
  moonui_gtk_ctx_drop_closure();
  moonui_ctx_fn = fn;
  if (closure != 0) {
    moonbit_incref(closure);
    moonui_ctx_closure = closure;
  }
  loop = g_main_loop_new(NULL, FALSE);
  if (loop == NULL) {
    gtk_widget_unparent(pop);
    g_object_unref(group);
    g_object_unref(root);
    moonui_gtk_ctx_drop_closure();
    moonui_menu_tree_free(&parsed);
    return -2;
  }
  g_signal_connect(pop, "closed", G_CALLBACK(moonui_gtk_ctx_on_closed), loop);
  moonui_ctx_live = GTK_POPOVER(pop);
  moonui_ctx_group_for_pick = group;
  if (moonui_ctx_pick_ms >= 0) {
    moonui_ctx_pick_armed = moonui_ctx_pick_index;
    moonui_ctx_pick_source = g_timeout_add((guint)moonui_ctx_pick_ms,
                                           moonui_gtk_ctx_on_pick, &parsed);
    moonui_ctx_pick_ms = -1;
    moonui_ctx_pick_index = -1;
  }
  gtk_popover_popup(GTK_POPOVER(pop));
  if (gtk_widget_get_visible(pop)) {
    /* 同步阻塞到用户选完（GTK4 的 popover 没有同步 run，自己开一圈主循环）。
     * 与对话框那条同一个形状，区别是没有超时：等的是人。 */
    g_main_loop_run(loop);
  }
  if (moonui_ctx_pick_source != 0) {
    g_source_remove(moonui_ctx_pick_source);
    moonui_ctx_pick_source = 0;
  }
  moonui_ctx_live = NULL;
  moonui_ctx_group_for_pick = NULL;
  g_main_loop_unref(loop);
  gtk_widget_unparent(pop);
  g_object_unref(group);
  g_object_unref(root);
  moonui_gtk_ctx_drop_closure();
  moonui_menu_tree_free(&parsed);
  return rc;
}
