/*
 * MoonUI 原生后端 · Linux / GTK4 · 控件挂载层——T235 P6-1。
 *
 * 与 canvas_gtk.inc 同一套规矩：被 adapter_native_gtk.c 用 #include 收进**同一个
 * 翻译单元**（看得见那边的 static 状态，也不新增 prebuild 的编译单元），生成器
 * 扫描本文件里定义的非 static moonui_* 符号并从"桩"里剔除。
 *
 * 这一片刻意只做**结构与身份**，不做外观：
 *   - 造控件（kind 17 Panel / 18 Custom）；
 *   - 挂进窗口（control_attach 走窗口的 GtkFixed 层）；
 *   - 摆放（control_set_bounds，物理像素进、逻辑单位落）；
 *   - 摘下来 / 提到最上层 / 读层叠号；
 *   - 命中反查要用的身份（mouse_owner 的读回口子）。
 *
 * 与 mac 半的对照（一眼可并排看）：
 *
 *   mac                               这里
 *   ------------------------------    ------------------------------
 *   contentView + addSubview          GtkOverlay(main) → GtkFixed → gtk_fixed_put
 *   setFrame:（点，y 向上要翻）        gtk_fixed_move + set_size_request（y 向下不翻）
 *   objc_setAssociatedObject 记 kind   moonui_widgets[] 登记表（生成器 prelude）
 *   [superview addSubview:positioned]  摘下来再放回去（GtkFixed 没有 raise）
 *
 * 为什么坐标不翻：GTK4 的坐标系就是左上原点、y 向下，与 ABI 同向（cairo 也同向，
 * 见 canvas_gtk.inc 那段；只有 mac 的 CG/AppKit 是左下原点才要翻）。所以这里
 * 直接把物理像素除以缩放因子落地，一个 y 翻转都不需要。
 *
 * 外观（背景/圆角/字号/图标/无障碍）刻意留到 P6-4 的样式与主题那一片：那些要
 * 走 GtkCssProvider，且"CSS 背景画不画得出来"只有 Linux 真机能验。本片只保证
 * 控件**在正确的位置、有正确的身份**——这是后面所有控件共同的地基。
 */

/* ---- 构造 ---- */

/* 控件被 GTK 销毁时销账。正常路径走 `widget_destroy`（它先销账再拆），这条信号
 * 是兜底：控件被别的路径销毁时（外部把引用放光、或将来引用关系变了），登记表
 * 不能留一个已经释放的指针让下一个同地址控件"继承"它的 kind——`T110` 那条老课
 * （后端自建的"身份登记表"必须跟销毁同步销账）。销账本身幂等。 */
static void moonui_gtk_on_widget_destroy(GtkWidget *w, gpointer user_data) {
  (void)user_data;
  moonui_wslot_free(w);
}

/* 造一个控件。kind 编码见 adapter.h 控件段：17=Panel、18=Custom。
 *
 * 只接这两种是**如实缺席**，不是漏写：其余 kind（Label/Button/TextInput/...）
 * 各有自己的文本、勾选、回调、固有尺寸语义，属于 P6-5 那一批；先返回 0 让 Core
 * 走"这个控件造不出来"的既有分支，比造一个空壳冒充控件诚实。
 *
 * Panel 用 GtkFixed：它在 mac 上是"纯背景 view + 子树的容器"，子树由 Core 算好
 * 绝对矩形挂进来；GtkFixed 正好是绝对摆放容器。面板的**底**由自绘层画（T101
 * 那套），样式通道的 bg/radius 等 P6-4 接 CSS 时再落，这里不假装已经画了。
 *
 * Custom 用 GtkDrawingArea：内容不在 GTK 侧生成，由 MoonBit 画成位图后经
 * moonui_canvas_present_view 贴上来（present_view 认的就是 GtkDrawingArea）。 */
moonui_ptr moonui_native_widget_new(int kind, const char *text, int text_len) {
  GtkWidget *w = NULL;
  (void)text;
  (void)text_len;
  switch (kind) {
    case 17:
      w = gtk_fixed_new();
      break;
    case 18:
      w = gtk_drawing_area_new();
      break;
    default:
      return 0;
  }
  if (w == NULL) {
    return 0;
  }
  /* 能被命中：自绘面与面板都要能作为 mouse_owner 被反查出来（拖拽重排、滚轮
   * 落到自绘面身上都靠它）。GTK4 的默认值本来就是 TRUE，这里显式写死，是因为
   * "默认值"在这条通道上是行为契约的一部分，不该由库的默认值替我们保证。 */
  gtk_widget_set_can_target(w, TRUE);
  g_signal_connect(w, "destroy", G_CALLBACK(moonui_gtk_on_widget_destroy), NULL);
  /* **自己持一份引用**：GTK4 里控件是 GInitiallyUnowned，谁把它挂进容器谁就
   * sink 掉那份 floating 引用。只靠父级那唯一一份的话，`gtk_widget_unparent`
   * 一放引用对象当场终结——而 `control_detach` 的语义是"脱离内容树、控件还在"
   * （Core 之后可能重新挂回来，也可能才 destroy），不能顺手把人家删了。
   * mac 半是同一个形状（`moonui_native_live_widgets` 强引用一份）。这份引用在
   * `widget_destroy` 里放掉，那也是控件真正被销毁的时刻。 */
  g_object_ref_sink(w);
  if (moonui_wslot_alloc(w, kind) == NULL) {
    g_object_unref(w);
    return 0; /* 登记表满：宁可不给，也不给一个查不到身份的控件 */
  }
  return (moonui_ptr)(uintptr_t)w;
}

void moonui_native_widget_destroy(moonui_ptr c) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  if (w == NULL) {
    return;
  }
  /* 先销账再拆：销账之后即使销毁链上有回调跑回来查 kind，查到的也是 -1
   * （"不是我们的控件"），而不是一个指向已释放对象的身份。 */
  moonui_wslot_free(w);
  if (gtk_widget_get_parent(w) != NULL) {
    gtk_widget_unparent(w); /* 放掉父级那份 */
  }
  g_object_unref(w); /* 放掉构造时自己那份；计数归零才真销毁 */
}

/* ---- 通用属性 ---- */

void moonui_native_widget_set_visible(moonui_ptr c, int visible) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  if (w == NULL) return;
  gtk_widget_set_visible(w, visible ? TRUE : FALSE);
}

int moonui_native_widget_visible(moonui_ptr c) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  if (w == NULL) return 0;
  return gtk_widget_get_visible(w) ? 1 : 0;
}

void moonui_native_widget_set_enabled(moonui_ptr c, int enabled) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  if (w == NULL) return;
  gtk_widget_set_sensitive(w, enabled ? TRUE : FALSE);
}

int moonui_native_widget_enabled(moonui_ptr c) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  if (w == NULL) return 0;
  return gtk_widget_get_sensitive(w) ? 1 : 0;
}

/* 不透明度（千分比）。ABI 明确"出界的值两侧都夹进 0..1000"。
 * 与 mac 的 alphaValue（便宜、控件级真生效）不同，GTK4 的 gtk_widget_set_opacity
 * 是**离屏合成**再混上来，代价比 mac 那侧高，但语义一致：只影响这一个控件，
 * 不连带子控件被系统整体拒掉（Windows 那条 `T89①` 的产品语义是"顶层生效"，
 * 这里没有那个限制）。 */
void moonui_native_widget_set_opacity(moonui_ptr c, int opacity) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  int v;
  if (w == NULL) return;
  v = opacity < 0 ? 0 : (opacity > 1000 ? 1000 : opacity);
  gtk_widget_set_opacity(w, (double)v / 1000.0);
}

/* ---- 度量 ---- */

int moonui_native_widget_dpi(moonui_ptr c) {
  return 96 * moonui_scale_of((GtkWidget *)(uintptr_t)c);
}

int64_t moonui_native_widget_origin(moonui_ptr c) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  GtkWidget *parent;
  MoonuiWidgetSlot *s;
  int scale;
  if (w == NULL) return 0;
  parent = gtk_widget_get_parent(w);
  if (parent == NULL || !moonui_gtk_is_container(parent)) {
    return 0;
  }
  /* 位置从**我们自己摆的那份账**读（`set_bounds` 落下的逻辑坐标），不用
   * `gtk_fixed_get_child_position`：2026-11-08 实测（GTK 4.24，本机真链接真跑）
   * 那个接口在**布局之前**恒报 (0,0)，`gtk_fixed_move` 挪过也一样——它报的是
   * 排版结果不是请求值，而排版要真窗口。
   *
   * 这份账与真分配不会分叉：GtkFixed 的子节点永远被分配在请求的 (x,y)，只有
   * **尺寸**可能被 natural size 撑大（那是 widget_size 的事，那边读 GTK 的实际
   * 分配）。没摆过的控件返回 0——与 mac 上"还没 setFrame 的 view 在原点"同义。 */
  s = moonui_wslot_of(w);
  if (s == NULL || !s->has_bounds) {
    return 0;
  }
  scale = moonui_scale_of(w);
  return moonui_pack2(s->bx * scale, s->by * scale);
}

int64_t moonui_native_widget_size(moonui_ptr c) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  int scale;
  if (w == NULL) return 0;
  scale = moonui_scale_of(w);
  return moonui_pack2(gtk_widget_get_width(w) * scale,
                      gtk_widget_get_height(w) * scale);
}

/* 固有最小尺寸（打包 (w<<32)|h，物理像素）。取 GTK 自己量出来的 minimum，
 * 不在这里另量一遍——字体度量属于原生层（§18 那条）。
 * 还没上屏时 GTK 量得出 0：这不是错，是"还没有版面可言"，Core 那时也不会问。 */
int64_t moonui_native_widget_minimum_size(moonui_ptr c) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  int mw = 0, mh = 0, nat = 0;
  int scale;
  if (w == NULL) return 0;
  gtk_widget_measure(w, GTK_ORIENTATION_HORIZONTAL, -1, &mw, &nat, NULL, NULL);
  gtk_widget_measure(w, GTK_ORIENTATION_VERTICAL, -1, &mh, &nat, NULL, NULL);
  scale = moonui_scale_of(w);
  return moonui_pack2(mw * scale, mh * scale);
}

/* ---- 挂载与摆放（§14）---- */

/* 挂进窗口：窗口的内容容器是一只 GtkOverlay，控件都放到它里面那层 GtkFixed 上
 * （见生成器 prelude 的 moonui_gtk_window_fixed）。重复 attach 是幂等的——
 * 不重排 z 序，否则每次重挂都会把层叠顺序和 Tab 顺序一起打乱。 */
void moonui_native_control_attach(moonui_ptr window, moonui_ptr child) {
  GtkWidget *win = (GtkWidget *)(uintptr_t)window;
  GtkWidget *w = (GtkWidget *)(uintptr_t)child;
  GtkWidget *fixed;
  GtkWidget *parent;
  if (win == NULL || w == NULL) return;
  fixed = moonui_gtk_window_fixed(win, 1);
  if (fixed == NULL) return; /* 窗口带了别人的内容：不接管 */
  parent = gtk_widget_get_parent(w);
  if (parent == fixed) return;
  if (parent != NULL) {
    /* 从别处搬过来：unparent 放掉旧父级那份，我们自己那份引用还在（构造时
     * ref_sink 过），所以中间这一下对象不会没。 */
    gtk_widget_unparent(w);
  }
  gtk_fixed_put(GTK_FIXED(fixed), w, 0, 0);
}

/* 挂进容器控件：目前唯一的容器是 Panel（也是 GtkFixed）。不是容器时静默不动
 * ——这条 ABI 没有返回码，而"Core 只会把子控件挂进容器"是 Core 侧保证的。 */
void moonui_native_container_attach(moonui_ptr container, moonui_ptr child) {
  GtkWidget *c = (GtkWidget *)(uintptr_t)container;
  GtkWidget *w = (GtkWidget *)(uintptr_t)child;
  GtkWidget *parent;
  if (c == NULL || w == NULL) return;
  if (!moonui_gtk_is_container(c)) return;
  parent = gtk_widget_get_parent(w);
  if (parent == c) return;
  if (parent != NULL) {
    gtk_widget_unparent(w);
  }
  gtk_fixed_put(GTK_FIXED(c), w, 0, 0);
}

/* 摆放。进参是**物理像素**、参照系是"最近那个认领容器的左上角、y 向下"
 * （与 mac 的 control_set_bounds 同一口径），落地时除以缩放因子换成 GTK 的
 * 逻辑单位。
 *
 * 为什么必须除：GTK4 的逻辑单位是"布局像素"，HiDPI 下 1 逻辑单位 = scale 个
 * 物理像素；Core 那边算的全是物理像素（§30）。不除就是 HiDPI 上整个界面放大
 * scale 倍、右下角全被裁掉。
 *
 * 尺寸只能走 set_size_request：GTK4 没有"设外框"的 API（GtkFixed 把子控件的
 * 测量结果当尺寸）。副作用是控件自己的 natural size 比 request 大时会溢出——
 * 对自绘面没有这个问题（natural = 0），对未来的文本控件要靠 Core 按测量值给
 * 边界，这也是 mac 那侧的既有约定。 */
void moonui_native_control_set_bounds(moonui_ptr child, int x, int y, int width,
                                      int height) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)child;
  GtkWidget *parent;
  MoonuiWidgetSlot *s;
  int scale;
  int xl, yl, wl, hl;
  if (w == NULL) return;
  parent = gtk_widget_get_parent(w);
  if (parent == NULL || !moonui_gtk_is_container(parent)) return;
  scale = moonui_scale_of(w);
  xl = (int)llround((double)x / scale);
  yl = (int)llround((double)y / scale);
  wl = (int)llround((double)width / scale);
  hl = (int)llround((double)height / scale);
  if (wl < 0) wl = 0;
  if (hl < 0) hl = 0;
  s = moonui_wslot_of(w);
  if (s != NULL) {
    s->has_bounds = 1;
    s->bx = xl;
    s->by = yl;
    s->bw = wl;
    s->bh = hl;
  }
  gtk_widget_set_size_request(w, wl, hl);
  gtk_fixed_move(GTK_FIXED(parent), w, (double)xl, (double)yl);
}

/* 摘下来：控件不再显示，也不再属于任何窗口（重新 attach 时插到最上层）。
 * **只摘引用、不销毁**——我们自己那份引用（构造时 ref_sink 的）让它继续活着，
 * 这是 detach 与 destroy 的分界（Core 之后可能把它挂回别处）。 */
void moonui_native_control_detach(moonui_ptr child) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)child;
  MoonuiWidgetSlot *s;
  if (w == NULL) return;
  if (gtk_widget_get_parent(w) == NULL) return;
  gtk_widget_unparent(w);
  s = moonui_wslot_of(w);
  if (s != NULL) s->has_bounds = 0;
}

/* 提到最上层。GtkFixed 没有"重排"的 API（GTK3 也没有），只能摘下来再放回去
 * ——后放的画在上面。位置靠登记表里那份逻辑坐标复原。
 *
 * 别把这条当成"顺便修坐标"的机会：ABI 说的是层叠，位置该由 set_bounds 管。 */
void moonui_native_control_raise(moonui_ptr child) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)child;
  GtkWidget *parent;
  MoonuiWidgetSlot *s;
  double x = 0.0, y = 0.0;
  if (w == NULL) return;
  parent = gtk_widget_get_parent(w);
  if (parent == NULL || !moonui_gtk_is_container(parent)) return;
  if (moonui_widget_z_index(w) == 0) return; /* 已经在最上层：不动，省一次重排 */
  s = moonui_wslot_of(w);
  if (s != NULL && s->has_bounds) {
    x = (double)s->bx;
    y = (double)s->by;
  } else {
    gtk_fixed_get_child_position(GTK_FIXED(parent), w, &x, &y);
  }
  /* 我们自己在构造时持了一份引用（见 widget_new），所以 unparent 与 put 之间
   * 不必再夹一层临时引用：计数从"自己的 + 父级的"减一再加一，始终 ≥1。 */
  gtk_widget_unparent(w);
  gtk_fixed_put(GTK_FIXED(parent), w, x, y);
}

int moonui_native_control_z_index(moonui_ptr child) {
  return moonui_widget_z_index((GtkWidget *)(uintptr_t)child);
}

/* ---- 命中反查的读回口子 ----
 * 值在事件处理器里算好（moonui_owner_at），这里只读——ABI 要的是"那一颗事件
 * 命中谁"，读回时再 pick 一次读到的是当时光标的位置，是另一件事。 */
moonui_ptr moonui_native_mouse_owner(void) { return moonui_mouse_owner_ptr; }
