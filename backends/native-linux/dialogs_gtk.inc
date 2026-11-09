/*
 * MoonUI 原生后端 · Linux / GTK4 · 对话框与文件面板——T235 P6-3。
 *
 * 被 adapter_native_gtk.c 用 #include 收进**同一个翻译单元**（与 widgets / canvas /
 * clipboard 三片并列）。生成器扫描本文件里定义的非 static moonui_* 符号并从"桩"
 * 里剔除，所以两边不会重定义。
 *
 * 这一片有两条 ABI 形态：
 *
 *   ① 消息框 `GtkMessageDialog`（§24 / §48-18）。按钮用 GTK_BUTTONS_OK /
 *      GTK_BUTTONS_YES_NO 交给 GTK 自己造——标签因此跟着 gtk40 的翻译走（中文环境
 *      就是"确定"/"是"/"否"），与 Windows 半把形态交给 MB_OK / MB_YESNO 同一个
 *      思路。契约说"按钮文字是后端的决定"，所以这里不自己 add_button，也不写死
 *      中英文。
 *
 *   ② 文件面板 `GtkFileChooserNative`（§24 / §48-18）。三种形态由
 *      GtkFileChooserAction 切（OPEN / SAVE / SELECT_FOLDER），与 mac 那半用
 *      NSOpenPanel 的 canChooseFiles / canChooseDirectories 切形态同构。
 *
 * **版本约束是这一片存在的全部理由**：目标最低版本是 GTK 4.6（Ubuntu 22.04 的
 * libgtk-4-dev），而 4.6 上能用的只有这两个类——`GtkAlertDialog` / `GtkFileDialog`
 * 都要 4.10。它们在 4.10 起被标弃用，但**弃用不等于移除**，4.6 上这是唯一形态。
 * prelude 里把 GDK_VERSION_MIN_REQUIRED 定成 4.6，正是为了让这些弃用标注在 4.6
 * 口径下不生效（否则 2026-11-08 实测每条都刷一遍 -Wdeprecated-declarations）。
 *
 * **GTK4 没有同步的 run 了**：`gtk_dialog_run` 在 4.10 被移除，`gtk_native_dialog_run`
 * / `gtk_native_dialog_response` 也一并从 GtkNativeDialog 里消失（2026-11-08 在
 * 4.24 头上确认 gtknativedialog.h 只剩 show/hide/destroy/title/transient 那一组）。
 * 而这份 ABI 是同步返回的，所以两份都得自己开一个临时 GMainLoop 等 "response"
 * ——与 clipboard_gtk.inc 泵异步读是同一招，区别只在**这里没有超时**：等的是人，
 * 不是对端。这是嵌套主循环，与已删除的 gtk_dialog_run 形状相同；本适配器没有
 * 跨调用的可变全局状态会被它撕开。
 *
 * 都不带窗口句柄（§24 的门面是全局形态），不建任何 MoonUI 句柄，所以和剪贴板
 * 同一条：弹一次对话框，句柄表一行都不动。也因此只能从事件循环里调——调用期间
 * MoonBit 一行都跑不到（mac 的 runModal 同形状）。
 *
 * 还带两条**测试脚手架**（auto_dismiss_dialog / auto_answer_file_dialog）：同步
 * 阻塞的对话框若不在调用前安排好"用户怎么答"，真窗测试就永远回不来。为什么替按
 * 必须点真按钮（而不是直接改返回值）、越界 index 为什么在这里就报回去，见
 * adapter.h 那两条的注释。
 */

/* ---- 共用的等待骨架 ----
 * 一次 modal 一场循环：响应到账就 quit。response 的初值是 GTK_RESPONSE_NONE，只为
 * 让"没人应答就退出了"这件事在读数上看得出来（正常路径一定被赋值）。 */
typedef struct MoonuiModalWait {
  GMainLoop *loop;
  int response;
  int done;
} MoonuiModalWait;

/* ---- 消息框 ---- */

/* 正在被展示的那只消息框。auto_dismiss 的定时器靠它取按钮（同 mac 的
 * moonui_native_open_alert：只在那次 modal 期间非空）。 */
static GtkWidget *moonui_dlg_open = NULL;

/* 本次面板的 response id 表：message 一只（OK）、confirm 两只（YES / NO）。
 * 存 id 而不是按钮指针，是因为按钮是 GTK 按 GTK_BUTTONS_* 自己造的，我们只在
 * 需要时用 gtk_dialog_get_widget_for_response 认领——指针随面板生灭，id 不会。 */
static int moonui_dlg_ids[2];
static int moonui_dlg_id_count = 0;

/* "用户在 ms 毫秒之后按下第 index 个按钮"。装它的入口在文件末尾的测试脚手架；
 * 认领它的是下面的 moonui_gtk_arm_dismissor（一次性的：认领时把参数清空）。 */
static int moonui_dlg_dismiss_ms = -1;
static int moonui_dlg_dismiss_index = -1;

static void moonui_gtk_on_dialog_response(GtkDialog *dlg, int response,
                                          gpointer data) {
  MoonuiModalWait *w = (MoonuiModalWait *)data;
  (void)dlg;
  w->response = response;
  w->done = 1;
  if (w->loop != NULL) {
    g_main_loop_quit(w->loop);
  }
}

static gboolean moonui_gtk_on_dismiss_timeout(gpointer data) {
  int idx = GPOINTER_TO_INT(data);
  GtkWidget *btn = NULL;
  if (moonui_dlg_open == NULL) {
    return G_SOURCE_REMOVE;
  }
  /* 越界退到最后一只（"否"或"确定"），和 mac / Windows 两份的兜底同一条：
   * 写错的脚手架要红在断言上，不要挂住整轮测试——什么都按不下就是永不返回。 */
  if (idx < 0 || idx >= moonui_dlg_id_count) {
    idx = moonui_dlg_id_count - 1;
  }
  if (moonui_dlg_id_count > 0) {
    btn = gtk_dialog_get_widget_for_response(GTK_DIALOG(moonui_dlg_open),
                                             moonui_dlg_ids[idx]);
  }
  /* 点的是**真按钮**：激活它走 GtkDialog 自己的应答路径，于是 response 是对话框
   * 给的答案，不是这里编出来的（同 mac 的 performClick: / Windows 的 BM_CLICK）。
   * 取不到按钮时退回 gtk_dialog_response——那也走同一条信号，只是少了"按钮被按"
   * 这一步；宁可少一步也不能挂住。 */
  if (btn != NULL) {
    gtk_widget_activate(btn);
  } else if (moonui_dlg_id_count > 0) {
    gtk_dialog_response(GTK_DIALOG(moonui_dlg_open), moonui_dlg_ids[idx]);
  }
  return G_SOURCE_REMOVE;
}

static void moonui_gtk_arm_dismissor(void) {
  int idx;
  if (moonui_dlg_dismiss_ms < 0 || moonui_dlg_open == NULL ||
      moonui_dlg_id_count <= 0) {
    return;
  }
  idx = moonui_dlg_dismiss_index;
  if (idx < 0 || idx >= moonui_dlg_id_count) {
    idx = moonui_dlg_id_count - 1;
  }
  g_timeout_add((guint)moonui_dlg_dismiss_ms, moonui_gtk_on_dismiss_timeout,
                GINT_TO_POINTER(idx));
  moonui_dlg_dismiss_ms = -1;
  moonui_dlg_dismiss_index = -1;
}

/* 文案：ABI 给的是 ptr + len，GTK 要 NUL 结尾的 UTF-8。不合法就返回 NULL，
 * 调用方按契约报 -1（"文案没能交给系统"）。 */
static char *moonui_gtk_dup_utf8(const char *s, int len) {
  if (s == NULL || len < 0) {
    return NULL;
  }
  if (!g_utf8_validate(s, (gssize)len, NULL)) {
    return NULL;
  }
  return g_strndup(s, (gsize)len);
}

/* 两只消息框共用的一段：建、挂、present、等一场 modal。返回 -1 / -2 / response。
 * confirm 决定 message type 与按钮形态（契约只区分"确定"和"是/否"两种，没给标题
 * 留参数——标题走 gtk_window_set_title，那是窗口标题栏的事）。 */
static int moonui_gtk_run_alert(const char *title, int title_len, const char *text,
                                int text_len, int confirm) {
  char *t;
  char *s;
  GtkWidget *dlg;
  MoonuiModalWait w;

  t = moonui_gtk_dup_utf8(title, title_len);
  s = moonui_gtk_dup_utf8(text, text_len);
  if (t == NULL || s == NULL) {
    g_free(t);
    g_free(s);
    return -1;
  }
  dlg = gtk_message_dialog_new(NULL, GTK_DIALOG_MODAL,
                               confirm ? GTK_MESSAGE_QUESTION : GTK_MESSAGE_INFO,
                               confirm ? GTK_BUTTONS_YES_NO : GTK_BUTTONS_OK,
                               "%s", s);
  g_free(s);
  if (dlg == NULL) {
    g_free(t);
    return -2;
  }
  gtk_window_set_title(GTK_WINDOW(dlg), t);
  g_free(t);

  moonui_dlg_id_count = 0;
  if (confirm) {
    moonui_dlg_ids[0] = GTK_RESPONSE_YES;
    moonui_dlg_ids[1] = GTK_RESPONSE_NO;
    moonui_dlg_id_count = 2;
  } else {
    moonui_dlg_ids[0] = GTK_RESPONSE_OK;
    moonui_dlg_id_count = 1;
  }

  memset(&w, 0, sizeof(w));
  w.response = GTK_RESPONSE_NONE;
  w.loop = g_main_loop_new(NULL, FALSE);
  if (w.loop == NULL) {
    gtk_window_destroy(GTK_WINDOW(dlg));
    return -2;
  }
  g_signal_connect(dlg, "response", G_CALLBACK(moonui_gtk_on_dialog_response),
                   &w);
  moonui_dlg_open = dlg;
  moonui_gtk_arm_dismissor();
  /* 不挂 transient parent（Core 没有"这个对话框属于哪个窗口"的概念），GTK 会打
   * 一条 "GtkDialog mapped without a transient parent" 的提示——那句是提示不是
   * 错误，专门写在这里免得后来者当成缺陷去修。 */
  gtk_window_present(GTK_WINDOW(dlg));
  if (!w.done) {
    g_main_loop_run(w.loop);
  }
  g_main_loop_unref(w.loop);
  moonui_dlg_open = NULL;
  moonui_dlg_id_count = 0;
  gtk_window_destroy(GTK_WINDOW(dlg));
  return w.response;
}

int moonui_native_dialog_message(const char *title, int title_len,
                                 const char *text, int text_len) {
  int rc = moonui_gtk_run_alert(title, title_len, text, text_len, 0);
  if (rc == -1 || rc == -2) {
    return rc;
  }
  return moonui_dialog_message_result(rc);
}

int moonui_native_dialog_confirm(const char *title, int title_len,
                                 const char *text, int text_len) {
  int rc = moonui_gtk_run_alert(title, title_len, text, text_len, 1);
  if (rc == -1 || rc == -2) {
    return rc;
  }
  return moonui_dialog_confirm_result(rc);
}

/* ---- 文件面板 ---- */

#define MOONUI_FILE_OPEN 0
#define MOONUI_FILE_SAVE 1
#define MOONUI_FILE_FOLDER 2

/* 面板结果的落点：到 moonui_native_file_dialog_path 取走（或下一次面板打开）之前
 * 归本文件所有。取消 / 失败时是 NULL，getter 因此给空 bytes。 */
static char *moonui_file_result = NULL;

/* 正在展示的那只面板（auto_answer 的定时器要用它）。与 moonui_dlg_open 同义。 */
static GtkNativeDialog *moonui_file_open = NULL;

/* "ms 毫秒之后替下一个文件面板按取消"。认领它的是 moonui_gtk_run_file_panel
 * （一次性：认领时清空）。 */
static int moonui_file_answer_ms = -1;

static void moonui_gtk_on_native_response(GtkNativeDialog *d, int response,
                                          gpointer data) {
  MoonuiModalWait *w = (MoonuiModalWait *)data;
  (void)d;
  w->response = response;
  w->done = 1;
  if (w->loop != NULL) {
    g_main_loop_quit(w->loop);
  }
}

static gboolean moonui_gtk_on_file_answer_timeout(gpointer data) {
  GtkNativeDialog *d = (GtkNativeDialog *)data;
  /* 对号：定时器的 data 不持引用，面板若已经关掉（或换成了下一只），这一发就不
   * 该再动它。比较的是指针值，不解引用，所以即使那块已经被释放也安全。 */
  if (d == NULL || d != moonui_file_open) {
    return G_SOURCE_REMOVE;
  }
  /* 4.10 起没有 public 的"应答"入口（gtk_native_dialog_response 已被移除，只剩
   * show/hide/destroy）。所以这里直接发 GtkNativeDialog 自己的 "response" 信号
   * ——面板关闭时 GTK 内部发的正是这一条，信号语义（谁收、收什么）不变。
   *
   * 为什么只替按"取消"、不替按"接受"：接受要面板先落到某条路径上再确认，
   * 4.24 的 public API 给不出这条链（见 moonui_native_auto_answer_file_dialog）。
   * 于是两个平台在"自动化替按接受"上都做不到，只是理由不同。 */
  g_signal_emit_by_name(d, "response", GTK_RESPONSE_CANCEL);
  return G_SOURCE_REMOVE;
}

/* 三种面板共用的一段。返回码见 adapter.h：1 = 选了、0 = 取消、-1 = 文案不是合法
 * UTF-8、-2 = 面板没能弹出来 / 接受了却拿不到路径。 */
static int moonui_gtk_run_file_panel(const char *title, int title_len,
                                     const char *default_name,
                                     int default_name_len, int mode) {
  char *t;
  char *d = NULL;
  GtkFileChooserAction action = GTK_FILE_CHOOSER_ACTION_OPEN;
  GtkFileChooserNative *n;
  MoonuiModalWait w;
  int rc;

  t = moonui_gtk_dup_utf8(title, title_len);
  if (t == NULL) {
    return -1;
  }
  if (default_name != NULL) {
    d = moonui_gtk_dup_utf8(default_name, default_name_len);
    if (d == NULL) {
      g_free(t);
      return -1;
    }
  }
  /* 取走语义的另一半：每开一次面板，上一次还没取走的就作废。 */
  g_free(moonui_file_result);
  moonui_file_result = NULL;

  if (mode == MOONUI_FILE_SAVE) {
    action = GTK_FILE_CHOOSER_ACTION_SAVE;
  } else if (mode == MOONUI_FILE_FOLDER) {
    action = GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER;
  }
  /* accept / cancel 标签给 NULL：让 GTK 用它自己的默认文案（跟着 gtk40 的翻译
   * 走），不在这里写死中英文。 */
  n = gtk_file_chooser_native_new(t, NULL, action, NULL, NULL);
  g_free(t);
  if (n == NULL) {
    g_free(d);
    return -2;
  }
  /* 预填文件名只有 save 有这一形（契约）；open / select_folder 没有这个形态，
   * 给了也不会用。gtk_file_chooser_set_current_name 在非 SAVE 模式会打 critical，
   * 所以按 mode 分开。 */
  if (d != NULL && mode == MOONUI_FILE_SAVE) {
    gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(n), d);
  }
  g_free(d);
  gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(n), TRUE);

  memset(&w, 0, sizeof(w));
  w.response = GTK_RESPONSE_NONE;
  w.loop = g_main_loop_new(NULL, FALSE);
  if (w.loop == NULL) {
    g_object_unref(n);
    return -2;
  }
  g_signal_connect(n, "response", G_CALLBACK(moonui_gtk_on_native_response), &w);
  moonui_file_open = GTK_NATIVE_DIALOG(n);
  if (moonui_file_answer_ms >= 0) {
    g_timeout_add((guint)moonui_file_answer_ms,
                  moonui_gtk_on_file_answer_timeout, n);
    moonui_file_answer_ms = -1;
  }
  gtk_native_dialog_show(GTK_NATIVE_DIALOG(n));
  if (!w.done) {
    g_main_loop_run(w.loop);
  }
  g_main_loop_unref(w.loop);
  moonui_file_open = NULL;
  rc = w.response;

  if (rc == GTK_RESPONSE_ACCEPT) {
    GFile *f = gtk_file_chooser_get_file(GTK_FILE_CHOOSER(n));
    char *p = (f != NULL) ? g_file_get_path(f) : NULL;
    if (f != NULL) {
      g_object_unref(f);
    }
    if (p == NULL) {
      /* 接受却拿不到本地路径（远程 URI / 面板状态不对）。"选了个空路径"不是
       * 用户做得出来的事，所以这属于 -2 而不是 0。 */
      gtk_native_dialog_destroy(GTK_NATIVE_DIALOG(n));
      g_object_unref(n);
      return -2;
    }
    moonui_file_result = g_strdup(p);
    g_free(p);
    gtk_native_dialog_destroy(GTK_NATIVE_DIALOG(n));
    g_object_unref(n);
    return (moonui_file_result != NULL) ? 1 : -2;
  }
  gtk_native_dialog_destroy(GTK_NATIVE_DIALOG(n));
  g_object_unref(n);
  /* 取消 / DELETE_EVENT / 直接把面板关掉：都是 0（§24 的"取消返回空"）。 */
  return 0;
}

int moonui_native_open_file(const char *title, int title_len) {
  return moonui_gtk_run_file_panel(title, title_len, NULL, 0, MOONUI_FILE_OPEN);
}

int moonui_native_save_file(const char *title, int title_len,
                            const char *default_name, int default_name_len) {
  return moonui_gtk_run_file_panel(title, title_len, default_name,
                                   default_name_len, MOONUI_FILE_SAVE);
}

int moonui_native_select_folder(const char *title, int title_len) {
  return moonui_gtk_run_file_panel(title, title_len, NULL, 0,
                                   MOONUI_FILE_FOLDER);
}

/* 取走：返回值是当场拷进 MoonBit 堆的一份，内部指针顺带清空。没结果时给空
 * bytes（不是 NULL——MoonBit 侧拿返回值直接 .length()，NULL 会闪退，`T84` 那笔
 * 老账同一个形状）。 */
moonbit_bytes_t moonui_native_file_dialog_path(void) {
  moonbit_bytes_t out;
  if (moonui_file_result == NULL) {
    return moonbit_make_bytes(0, 0);
  }
  out = moonui_bytes_of(moonui_file_result);
  g_free(moonui_file_result);
  moonui_file_result = NULL;
  return out;
}

/* ---- 测试脚手架 ---- */

/* 装好"ms 毫秒之后按下下一个对话框的第 index 个按钮"。index 只有两种合法形态
 * （message 一只 = 0、confirm 两只 = 0/1），越界在这里就报回去——留到运行时
 * "什么也没按下"是一条挂住的测试，而不是一条红的。
 * 一直没对话框来认领的话，这发就留在进程里（同 mac）。 */
int moonui_native_auto_dismiss_dialog(int ms, int index) {
  if (index < 0 || index > 1) {
    return -1;
  }
  moonui_dlg_dismiss_ms = ms < 0 ? 0 : ms;
  moonui_dlg_dismiss_index = index;
  return 0;
}

/* 装好"ms 毫秒之后替下一个文件面板按 取消（accept == 0）/ 接受"。
 *
 * 接受这一支在 Linux 上做不到，当场报 -2：4.10 起 GtkNativeDialog 的
 * gtk_native_dialog_response 被移除，public API 只剩 show / hide / destroy，没有
 * "把面板确认掉并让它把选中项交回来"的入口（hide/destroy 不会带上选中项）。
 * 这与 mac 那半（面板跑在 XPC 服务里，客户端的 ok: 是个桩）结论相同、理由不同。
 * 真人在真机上按"打开"的产品路径不受影响，死的只有"自动化替按"这一条。
 *
 * 校验在改状态之前做完：报错的这一发不许留下半装好的状态。 */
int moonui_native_auto_answer_file_dialog(int ms, const char *path, int path_len,
                                          int accept) {
  if (accept != 0) {
    if (path == NULL || path_len <= 0) {
      return -1;
    }
    return -2;
  }
  moonui_file_answer_ms = ms < 0 ? 0 : ms;
  return 0;
}
