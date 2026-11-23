/*
 * MoonUI 原生后端 · Linux / GTK4 · 控件挂载层——T235 P6-1。
 *
 * 与 canvas_gtk.inc 同一套规矩：被 adapter_native_gtk.c 用 #include 收进**同一个
 * 翻译单元**（看得见那边的 static 状态，也不新增 prebuild 的编译单元），生成器
 * 扫描本文件里定义的非 static moonui_* 符号并从"桩"里剔除。
 *
 * 这一片做**结构与身份**：
 *   - 造控件（P6-5 起十种、P6-5b 起十二种 kind，见 prelude 的映射表）；
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
 * 外观与内容分在别的两片（同一个翻译单元）：theme_gtk.inc 走 GtkCssProvider
 * 接背景/圆角/字号/字重，leaves_gtk.inc 接文案/占位/勾选/三条回调。本片只保证
 * 控件**在正确的位置、有正确的身份**——这是后面所有控件共同的地基。
 */

/* ---- 构造 ---- */

/* leaves_gtk.inc（同一翻译单元、在本片之后 include）里的文本读回口。构造时
 * 拿它记下初值，作为 `T280` 去重比较的基准；不在这里重复一套通道分派。 */
static char *moonui_leaf_text_now(GtkWidget *w, int kind);

/* 控件被 GTK 销毁时销账。正常路径走 `widget_destroy`（它先销账再拆），这条信号
 * 是兜底：控件被别的路径销毁时（外部把引用放光、或将来引用关系变了），登记表
 * 不能留一个已经释放的指针让下一个同地址控件"继承"它的 kind——`T110` 那条老课
 * （后端自建的"身份登记表"必须跟销毁同步销账）。销账本身幂等。 */
static void moonui_gtk_on_widget_destroy(GtkWidget *w, gpointer user_data) {
  (void)user_data;
  moonui_ime_forget(w);
  moonui_wslot_free(w);
}

/* ---- 文本控件的文件拖入接管（T235 / T251 真机复验发现，2026-11-15）----
 * 真机拖文件进输入框（GtkEntry / GtkTextView）时，文件被当**文本**插入：
 * Nautilus 拖文件同时提供 text/plain;charset=utf-8（文件 URI 的文本表示），
 * GtkText 的默认 drop target（G_TYPE_STRING）在 accept 阶段匹配到它，把 URI
 * 文本插入输入框（gtktext.c:6637-6689），窗口层的 GtkDropTarget（GDK_TYPE_
 * FILE_LIST，moonui_gtk_filedrop_attach）收不到 FileDrop 事件。
 *
 * 为什么不是给 GtkText 的 string target 加 accept handler 拒绝文件：2026-11-15
 * 实测（真机 + GTK 4.24.1 源码）——GtkText 的 drop target 的 accept 信号在文件
 * drop 时**根本不发**（gtkdroptarget.c:489-519 的 crossing 处理里，accept 信号
 * 只在 `old_descendent == NULL && old_target != widget` 时发；指针从窗口进入
 * 输入框时 GtkText 收到 crossing 的 old_descendent 非空，直接 return），但
 * GtkText **仍接受并插入**（gtk_text_drag_accept 是 gtktext.c:2047 在构造时
 * g_signal_connect 的 RUN_FIRST handler，先于我们的 handler 跑，accept 信号
 * 用 g_signal_accumulator_first_wins 聚合，它先返回 TRUE 即定局）。所以
 * connect accept 无效——文件照样被插进输入框，窗口 FileDrop 收不到。
 *
 * 可靠的刀是**移除** GtkText 那份默认 string drop target（gtk_widget_
 * remove_controller），让文件 drop 沿父链冒泡到下面挂的 file-list target。
 * 代价：纯文本拖入输入框也不再插入（GtkText 的 string target 没了）。T235
 * 文件拖入优先，文本拖入属于可接受损失——与 mac 半同构（adapter_native.m:413
 * 段注「编辑中的文本控件上方可能被 field editor 拦住」，欠账在 T86③）。
 *
 * 为什么文本控件要自己挂 file-list target、而不是等窗口那只：窗口的 file-list
 * target 在 crossing 的 `old_descendent` 非空时被跳过（gtkdroptarget.c:505），
 * 指针在输入框上时它收不到 drop；文本控件自己的 file-list target 离得近，先
 * 收到。drop 回调把窗口当事件 target（root），与窗口 file-list target 传 win
 * 同口径——FileDrop 事件的 target 是窗口。 */
static gboolean moonui_gtk_text_file_drop(GtkDropTarget *target,
                                          const GValue *value, double x,
                                          double y, gpointer data) {
  GtkWidget *root = 0;
  if (data != 0) {
    GtkRoot *r = gtk_widget_get_root(GTK_WIDGET(data));
    root = GTK_WIDGET(r);
  }
  return moonui_gtk_on_file_drop(target, value, x, y,
                                 (gpointer)root);
}

static void moonui_gtk_text_drop_attach(GtkWidget *w) {
  GtkWidget *targets[2];
  GtkDropTarget *file_target;
  guint nt = 0; /* guint 与下面 t 同型，免 `-Wsign-compare`（t < nt 两边都无符号） */
  guint n, i, t;
  if (w == 0) return;
  /* 先枚举控件自己（GtkTextView 的 string drop target 挂在 view 自己，
   * gtktextview.c:2016），再枚举 editable delegate（GtkEntry 的挂在内部
   * GtkText，gtktext.c:2043）——两处都是 GTK 默认的 G_TYPE_STRING target。 */
  targets[nt++] = w;
  if (GTK_IS_EDITABLE(w)) {
    GtkEditable *delegate = gtk_editable_get_delegate(GTK_EDITABLE(w));
    if (delegate != 0 && GTK_WIDGET(delegate) != w) {
      targets[nt++] = GTK_WIDGET(delegate);
    }
  }
  for (t = 0; t < nt; ++t) {
    GtkWidget *edit = targets[t];
    GListModel *model = gtk_widget_observe_controllers(edit);
    if (model == 0) continue;
    n = g_list_model_get_n_items(model);
    for (i = 0; i < n; ++i) {
      gpointer item = g_list_model_get_item(model, i);
      if (item != 0) {
        if (GTK_IS_DROP_TARGET(item)) {
          gtk_widget_remove_controller(edit, GTK_EVENT_CONTROLLER(item));
        }
        g_object_unref(item);
      }
    }
    g_object_unref(model);
  }
  /* 文本控件自己挂一只 file-list target：GtkText 的 string target 移除后，
   * 文件 drop 冒泡到这只（比窗口近），文件事件从这里进窗口的 drop 闭包。 */
  file_target = gtk_drop_target_new(GDK_TYPE_FILE_LIST, GDK_ACTION_COPY);
  if (file_target != 0) {
    g_signal_connect(file_target, "drop",
                     G_CALLBACK(moonui_gtk_text_file_drop), w);
    gtk_widget_add_controller(w, GTK_EVENT_CONTROLLER(file_target));
  }
}

/* 造一个控件。kind 编码见 adapter.h 控件段；这里是**唯一**一张映射表的消费方
 * （moonui_gtk_leaf_of_kind 在生成物 prelude，假头闸第 12 组逐字对拍）。
 *
 * P6-5 之前只接 17/18，其余如实返回 0；P6-5 十种、P6-5b 十二种 kind 落地。
 * 14 MenuRow = GtkToggleButton（探针实测 GTK_IS_BUTTON=1、active 可读回），
 * 15 Scroll = GtkScrolledWindow + GTK 自动包的 GtkViewport + 一只 GtkFixed
 * 文档区（内容尺寸/滚动轴由 scroll_gtk.inc 的 scroll_set_content 给）。
 * 19 WebView 仍返回 0：GTK4 本体没有 WebView，WebKitGTK 是另一份依赖，
 * 不在这套 4.6 sysroot 里；造个空壳冒充会让 Core 以为控件建成了。
 * （P6-11：五条 WebView ABI 口子已按 Windows 半的缺席形状收口，构造这步
 * 照旧回 0，调用方在建控件处就停。）
 * 6..12 走 slider_new 那七个专属构造入口，不进这里（P6-5c）。
 *
 * 形态由 2026-11-09 真 GTK4 4.24 探针（/tmp/p65-probe.c）实测定下：GtkLabel /
 * GtkButton / GtkEntry / GtkPasswordEntry / GtkCheckButton / GtkSeparator(H/V) /
 * GtkPicture 在 4.6 口径都造得出；GtkPasswordEntry 实现 GtkEditable，所以与
 * GtkEntry 共用文案通道。Panel 用 GtkFixed（绝对摆放容器）；Custom 用
 * GtkDrawingArea（内容由 MoonBit 画成位图后经 present_view 贴上）。
 *
 * 史注（P6-9 订正）：图像控件 P6-5 造的是 GtkImage，P6-9 落地图像源时换成
 * GtkPicture。GtkImage 是图标控件，按图像固有尺寸出画、不随分配缩放，也没有
 * can-shrink 属性（真 4.24 头 gtkimage.h 里查不到）；kind 16 的对照物是 mac 的
 * NSImageView + NSImageScaleProportionallyUpOrDown，只有 GtkPicture 的
 * CONTAIN + can-shrink 对得上。
 *
 * 文案按 (ptr,len) 复制成 NUL 结尾副本：Core 的 Bytes 不保证 NUL 结尾。
 * 构造时给输入框灌初值会发 changed，但此刻回调还没注册（Core 在 create_widget
 * 之后才装），不会有回声；程序化改值的回声由 leaves_gtk.inc 的 inhibit 挡。 */
moonui_ptr moonui_native_widget_new(int kind, const char *text, int text_len) {
  GtkWidget *w = NULL;
  char *dup;
  int leaf = moonui_gtk_leaf_of_kind(kind);
  /* P6-5c：kinds 6..12 有**专属构造入口**（slider_new 等，adapter.h 508-529），
   * 范围/模型/选项不是 (kind,text) 能表达的，不走这套通用工厂。这里直接回 0：
   * 6..9,11,12 本会因 leaf=NONE 回 0，但 10（multiline）的 leaf 是 TEXTVIEW
   * （那是给文案通道 widget_set_text/widget_text 用的，不是给工厂用的），不挡住
   * 会掉进下面的 default 造出一只 GtkDrawingArea。 */
  if (kind >= 6 && kind <= 12) return 0;
  if (leaf == MOONUI_LEAF_NONE) return 0;
  dup = moonui_gtk_leaf_dup_text(text, text_len);
  if (dup == NULL) return 0;
  switch (leaf) {
    case MOONUI_LEAF_LABEL:
      w = gtk_label_new(dup);
      break;
    case MOONUI_LEAF_BUTTON:
      w = gtk_button_new_with_label(dup);
      break;
    case MOONUI_LEAF_ENTRY:
      w = gtk_entry_new();
      gtk_editable_set_text(GTK_EDITABLE(w), dup);
      break;
    case MOONUI_LEAF_PASSWORD:
      w = gtk_password_entry_new();
      gtk_editable_set_text(GTK_EDITABLE(w), dup);
      break;
    case MOONUI_LEAF_CHECK:
      w = gtk_check_button_new_with_label(dup);
      break;
    case MOONUI_LEAF_SEP_H:
      w = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
      break;
    case MOONUI_LEAF_SEP_V:
      w = gtk_separator_new(GTK_ORIENTATION_VERTICAL);
      break;
    case MOONUI_LEAF_IMAGE:
      /* GtkPicture 而不是 GtkImage：见文件头 P6-9 的订正注。图像内容由
       * image_set_path / image_set_data（生成器 REAL 段）装进来。 */
      w = gtk_picture_new();
      break;
    case MOONUI_LEAF_PANEL:
      w = gtk_fixed_new();
      break;
    case MOONUI_LEAF_MENUROW:
      w = gtk_toggle_button_new_with_label(dup);
      break;
    case MOONUI_LEAF_SCROLL: {
      GtkWidget *doc = gtk_fixed_new();
      w = gtk_scrolled_window_new();
      /* GTK4 探针实测：GtkFixed 不是 GtkScrollable，set_child 会自动包一层
       * GtkViewport；文档区从那层里读回来，不另存一份会分叉的账。 */
      gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(w), doc);
      break;
    }
    default:
      w = gtk_drawing_area_new(); /* MOONUI_LEAF_CUSTOM */
      break;
  }
  free(dup);
  if (w == NULL) return 0;
  /* 文本控件挂组合相位旁听（T251）：单行 / 密码的编辑视图是内部的 GtkText，
   * 取口与信号接线见 prelude 的「输入法组合」段。 */
  if (leaf == MOONUI_LEAF_ENTRY || leaf == MOONUI_LEAF_PASSWORD) {
    moonui_gtk_ime_attach(w);
  }
  /* 文本控件接管文件拖入（T235 / T251 真机复验）：GtkText 默认把文件当文本
   * 插入，这里让它的 string drop target 拒绝文件，好让窗口的 file-list
   * target 收到 FileDrop。multiline 的 GtkTextView 也是 GtkEditable（delegate
   * 是自己），一并处理。 */
  if (leaf == MOONUI_LEAF_ENTRY || leaf == MOONUI_LEAF_PASSWORD ||
      leaf == MOONUI_LEAF_TEXTVIEW) {
    moonui_gtk_text_drop_attach(w);
  }
  /* 能被命中：自绘面与面板都要能作为 mouse_owner 被反查出来（拖拽重排、滚轮
   * 落到自绘面身上都靠它）。GTK4 的默认值本来就是 TRUE，这里显式写死，是因为
   * "默认值"在这条通道上是行为契约的一部分，不该由库的默认值替我们保证。 */
  gtk_widget_set_can_target(w, TRUE);
  g_signal_connect(w, "destroy", G_CALLBACK(moonui_gtk_on_widget_destroy), NULL);
  /* **自己持一份引用**：GTK4 里控件是 GInitiallyUnowned，谁把它挂进容器谁就
   * sink 掉那份 floating 引用。只靠父级那唯一一份的话，gtk_widget_unparent
   * 一放引用对象当场终结——而 control_detach 的语义是"脱离内容树、控件还在"
   * （Core 之后可能重新挂回来，也可能才 destroy），不能顺手把人家删了。
   * mac 半是同一个形状（moonui_native_live_widgets 强引用一份）。这份引用在
   * widget_destroy 里放掉，那也是控件真正被销毁的时刻。 */
  g_object_ref_sink(w);
  if (moonui_wslot_alloc(w, kind) == NULL) {
    g_object_unref(w);
    return 0; /* 登记表满：宁可不给，也不给一个查不到身份的控件 */
  }
  {
    MoonuiWidgetSlot *slot = moonui_wslot_of(w);
    if (slot != NULL) {
      if (kind == 15) {
        /* 文档区不占控件槽（它是实现细节，不是 Core 造的控件），但
         * container_attach / is_container / set_bounds 都要认得它。 */
        slot->scroll_content = moonui_gtk_scroll_content(w);
      }
      /* T280：把构造时灌进去的初值记成去重基准。不记的话，非空初值控件的
       * 第一声 changed（哪怕文本没变）会被当成真变化派发一次。 */
      slot->last_text = moonui_leaf_text_now(w, kind);
    }
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
  MoonuiWidgetSlot *s;
  int scale, gw, gh;
  if (w == NULL) return 0;
  scale = moonui_scale_of(w);
  gw = gtk_widget_get_width(w);
  gh = gtk_widget_get_height(w);
  /* 未呈现时 GTK 的量出值是 0（"还没有版面"），不是"真缩成 0"：Core 的自绘面在
   * `win.show()` 那趟布局里就要开一帧，那时读回恒 0，`draw_custom` 的零尺寸守卫
   * 整帧跳过、画布从未建起，之后没有帧链的静止控件就永久空白（`T362`）。
   * 呈现后以 GTK 的真分配为准（natural size 可能把控件撑大）；呈现前退回
   * `set_bounds` 落下的那份账——与读位置同一条理由（见 `native_widget_origin`
   * 的那条：`gtk_fixed_get_child_position` 布局前也恒报 (0,0)）。自绘面的
   * natural size 是 0，这份账与真分配不会分叉。 */
  s = moonui_wslot_of(w);
  if ((gw <= 0 || gh <= 0) && s != NULL && s->has_bounds) {
    gw = s->bw;
    gh = s->bh;
  }
  return moonui_pack2(gw * scale, gh * scale);
}

/* 输入框家族 / Slider / Progress 的固定最小宽（逻辑点）。
 *
 * 空内容的 GtkEntry / GtkPasswordEntry 最小宽只有 18px，GtkTextView 更是 0×0
 * ——照 GTK 的 minimum 报上去，Core 的 Column（不给叶子铺交叉轴，fill_cross=false）
 * 会把它们压成一条竖缝（`T279`，2026-11-15 Linux 真机探针实测）。mac 半
 * （adapter_native.m 的 minimum_size 同表）与 Windows 半（adapter_native.c 同表）
 * 都给这一族垫固定宽：mac 120pt、Windows 107 DLU。这里取 mac 的 120 逻辑点，
 * 高仍然走 gtk_widget_measure（那一维 GTK 量得对）。
 *
 * 只给宽退化得没法看的这七种；Label/Button/Checkbox 的文字宽、Calendar 的固有
 * 尺寸都是真的，不动。刻度单位是逻辑点，乘 scale 后才是 ABI 的物理像素。 */
static int moonui_gtk_min_fixed_width(int kind) {
  switch (kind) {
    case 2:  /* TextInput */
    case 4:  /* PasswordInput */
    case 6:  /* Slider */
    case 7:  /* Spinbox */
    case 8:  /* Progress */
    case 9:  /* ComboBox */
    case 10: /* MultilineEntry */
      return 120;
    default:
      return 0;
  }
}

/* 固有最小尺寸（打包 (w<<32)|h，物理像素）。取 GTK 自己量出来的 minimum，
 * 不在这里另量一遍——字体度量属于原生层（§18 那条）。上面那张表补的是
 * GTK 量出来会退化到无法阅读的那一族（`T279`）。
 * 还没上屏时 GTK 量得出 0：这不是错，是"还没有版面可言"，Core 那时也不会问。 */
int64_t moonui_native_widget_minimum_size(moonui_ptr c) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)c;
  MoonuiWidgetSlot *slot;
  int mw = 0, mh = 0, nat = 0;
  int scale, fixed_w;
  if (w == NULL) return 0;
  gtk_widget_measure(w, GTK_ORIENTATION_HORIZONTAL, -1, &mw, &nat, NULL, NULL);
  gtk_widget_measure(w, GTK_ORIENTATION_VERTICAL, -1, &mh, &nat, NULL, NULL);
  slot = moonui_wslot_of(w);
  fixed_w = slot == NULL ? 0 : moonui_gtk_min_fixed_width(slot->kind1 - 1);
  if (mw < fixed_w) mw = fixed_w;
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
  GtkWidget *doc;
  MoonuiWidgetSlot *cs;
  if (c == NULL || w == NULL) return;
  /* kind 15 Scroll：子控件挂进视口文档区（那只 GtkFixed），不是挂进
   * GtkScrolledWindow 自己——4.24 探针实测 set_child 会包一层 GtkViewport。
   * Core 已把 child 的坐标平移成文档区坐标，这里只管挂接。 */
  cs = moonui_wslot_of(c);
  if (cs != NULL && cs->kind1 - 1 == 15) {
    doc = moonui_gtk_scroll_content(c);
    if (doc == NULL) return;
    parent = gtk_widget_get_parent(w);
    if (parent == doc) return;
    if (parent != NULL) gtk_widget_unparent(w);
    gtk_fixed_put(GTK_FIXED(doc), w, 0, 0);
    return;
  }
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
