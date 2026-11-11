/* T235 P3/P5/P6-1/P6-3：GTK4 适配器里**纯逻辑**那几块的本地自检（不碰 GTK 运行时）。
 *
 * 分组：①键名词表 ②pack2 / 修饰键 / 鼠标钮号 ③（P3 其余纯函数）④⑤…
 * ⑥音频"显式缺席"的码表（P5）⑦控件登记表 / 命中反查 / 层叠序号（P6-1，用一棵
 * 假 widget 树真跑）⑧对话框 response → 返回码（P6-3，决定"哪些应答算同意"）
 * ⑨菜单树的字节解析与 dump 文本（P6-4，好树/坏树两种都喂）
 * ⑩主题 / CSS 的纯逻辑（P6-4b：permille 小数、kind 消费面、字重档位、
 *   深色判定两代属性的优先级）
 * ⑪无障碍的纯逻辑（P6-4c：role → GTK 枚举名字、state 位包、按长度复制
 *   的 UTF-8 文本、两条系统偏好读数的优先级与回落）
 * ⑫控件叶子的纯逻辑（P6-5 / P6-5b：kind → 构造形态、文案/勾选通道）；
 * ⑬焦点链文本解析与下一跳、自绘面「按下并原地抬起」的判定、Tab 按链推进
 *   （P6-5b；后三者都用 mock 的 GTK 焦点替身真跑，不只是编译过）。
 * ⑭DatePicker 的日期文本解析（P6-5c）；⑮display / monitor 可注入替身与
 *   moonui_scale_of 的回升（T241）；⑯渲染后端名字表与偏好文件往返（P6-7）；
 * ⑰应用身份 / 显式缺席 / 目录行走（P6-8：walk_dir 的打包格式与失败支、
 *   set_app_name 真的交到 GLib、notify / tray / content_permille 如实报缺席）；
 * ⑱图像源两条（P6-9：返回码三态、坏输入的 GError 释放、纹理与 GBytes 的
 *   引用配平、paintable/can-shrink 真交给 GtkPicture——用替身真跑）。
 * ⑲文件拖入三条（P6-10：路径数组的 i32 count + count×(i32 len, UTF-8)
 *   编码布局、target 读回、空数组清空、重复装载覆盖）。
 * ⑳WebView 五条的显式缺席（P6-11：on → -1、target/phase 恒 0、detail 空包、
 *   load → -2——GTK4 本体没有网页视图，中性桩的 return 0 是谎报）。
 * ㉑后台任务的线程与落地（P6-12：真 pthread 起 worker、work 在非主线程跑、
 *   落地只经 idle 源投一回、四参数缺失回 -1、两支闭包引用各 2 次配平）。
 * ㉒输入法组合四条的簿记（P6-13：监听登记 / 换人退旧引用 / 空闭包清槽位 /
 *   无组合时三问报 0、0、空包 / 登记后不会自发通知 / 清账归零）。
 * ㉓输入法组合相位的旁听接线（T251：attach 经 observe_controllers 取
 *   im_context、四个信号真连；start→update→同串去重→update→空串 end；
 *   changed 无 start 时补发；commit 收尾；换控件状态重置；控件销毁清 target）。
 * 这份文件由 scripts/mock-gtk-check.sh 追加到"把 <gtk/gtk.h> 换成 mock 头"
 * 的那份生成物末尾再编译运行——静态函数（moonui_key_name_store / moonui_pack2
 * / moonui_mods_of / moonui_map_button / moonui_held_button）因此在同一个翻译
 * 单元里可见。
 *
 * 为什么值得单独造这条：这些函数是 Linux 上**唯一能在 macOS 真跑出判据**的
 * 部分——它们不调 GTK，只用整数与字符串。键名词表尤其要紧：拼错一处，Linux
 * 上那类键就静默变成"没有事件"，而那要等用户在真机上按键才发现。mock-gtk.h
 * 里 GDK_*_MASK 的取值按真实 GDK 的位序摆，所以这里的位运算判据与 Linux 同义。
 *
 * 链接用 -Wl,-undefined,dynamic_lookup：moonbit 运行时的绝大多数字号本文件不
 * 调用，留未定义即可。唯一的例外是 P6-12 / P6-13——那只线程与输入法监听要真
 * 跑引用配平，所以 moonbit_incref / moonbit_decref 在这里给了计数桩（各组
 * 开头按增量量），g_idle_add 也给了记录桩（真 glib 的落队由测试手动泵一次来
 * 模拟 UI 线程）。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>

/* mock 的 gdk_keyval_name：只认自检要用的那几个键码，其余回 "unknown"，用来
 * 验证"词表外的键留空串"。键码取真实 GDK 的数值，判据因此与 Linux 同义。 */
const char *gdk_keyval_name(guint keyval) {
  switch (keyval) {
    case 0xFF0D: return "Return";
    case 0xFF08: return "BackSpace";
    case 0xFF55: return "Page_Up";
    case 0xFF56: return "Page_Down";
    case 0x0020: return "space";
    case 0xFF09: return "Tab";
    case 0xFE20: return "ISO_Left_Tab"; /* Shift+Tab：词表外，但 Tab 拦截认它 */
    case 0xFF1B: return "Escape";
    case 0xFFFF: return "Delete";
    case 0xFF51: return "Left";
    case 0xFF53: return "Right";
    case 0xFF52: return "Up";
    case 0xFF54: return "Down";
    case 0xFF50: return "Home";
    case 0xFF57: return "End";
    case 0xFFBE: return "F1";
    case 0xFFE1: return "Shift_L"; /* 修饰键自己：不在词表里 */
    case 0x0061: return "a";
    case 0x0041: return "A";       /* Shift+a 的 keyval：要折成 "a" */
    case 0x0031: return "1";
    default: return "unknown";
  }
}

static int g_fails = 0;
static int g_checks = 0;

/* 自检**不链接 moonbit 运行时**（见文件头：那几个符号留未定义），但第 6 组要调
 * 两条 bytes 出参的音频函数，它们内部会 `moonbit_make_bytes`。这里给一个够用的
 * 小实现：判据只看"非 NULL"与载荷前 8 字节，不关心分配器本身。跟上面
 * gdk_keyval_name 是同一招——补上"声明有、实现不在"的那个符号。 */
static unsigned char g_bytes_pool[65536];
/* P6-8 加：walk_dir 的返回包是变长的（[count] + 每项 [len][字节]），第 17 组
 * 既要验"空包是 0 字节"又要验 total 账，所以记下**最近一次**分配长度。
 * 真实运行时这里是 GC 堆，长度由 moonbit_bytes_t 自己带着；自检没有运行时，
 * 只能由替身记。 */
static int g_last_bytes_size = -1;
moonbit_bytes_t moonbit_make_bytes(int32_t size, int value) {
  if (size < 0) size = 0;
  if (size > (int32_t)sizeof(g_bytes_pool)) size = (int32_t)sizeof(g_bytes_pool);
  g_last_bytes_size = size;
  memset(g_bytes_pool, value, (size_t)size);
  return (moonbit_bytes_t)g_bytes_pool;
}

/* ---- T235 P6-8：set_app_name 的 GLib 替身 ----
 * 真 GLib 那条只是把名字存进进程全局；自检要验"名字真的交出去了"，所以抄一份
 * 下来供第 17 组断言。 */
static char g_last_app_name[128];
void g_set_application_name(const char *name) {
  snprintf(g_last_app_name, sizeof(g_last_app_name), "%s", name == NULL ? "" : name);
}

/* ---- T235 P6-8：walk_dir 打包格式的三个读口（第 17 组用）----
 * 格式与 adapter.h 一致：[int32 count] + count×[int32 len][len 字节绝对路径]，
 * 名字**不带** NUL 结尾，所以比对要按长度 memcmp，不能 strcmp。 */
static int walk_i32(const unsigned char *b, size_t off) {
  int n;
  memcpy(&n, b + off, 4);
  return n;
}
static int walk_count(void) {
  return walk_i32(g_bytes_pool, 0);
}
static int walk_has(const char *want) {
  int count = walk_count();
  size_t off = 4;
  size_t wl = strlen(want);
  int i;
  for (i = 0; i < count; i++) {
    int len = walk_i32(g_bytes_pool, off);
    const char *nm = (const char *)g_bytes_pool + off + 4;
    if (len >= 0 && (size_t)len == wl && memcmp(nm, want, wl) == 0) {
      return 1;
    }
    off += 4 + (size_t)(len < 0 ? 0 : len);
  }
  return 0;
}
/* ---- T235 P6-10：文件拖入快照的 i32 读口（第 19 组用）----
 * 布局与 adapter.h 一致：[i32 count] + count×[i32 len][len 字节 UTF-8]。
 * 与 walk_i32 分开写：两套打包是两条独立 ABI，将来任何一边改布局都不该
 * 悄悄改到另一边的判据。 */
static int drop_i32(const unsigned char *b, size_t off) {
  int n;
  memcpy(&n, b + off, 4);
  return n;
}
/* 目录尾带 `/` 时不许拼出 `//`：逐项扫一遍。 */
static int walk_has_double_slash(void) {
  int count = walk_count();
  size_t off = 4;
  int i;
  for (i = 0; i < count; i++) {
    int len = walk_i32(g_bytes_pool, off);
    const char *nm = (const char *)g_bytes_pool + off + 4;
    int k;
    for (k = 0; k + 1 < len; k++) {
      if (nm[k] == '/' && nm[k + 1] == '/') {
        return 1;
      }
    }
    off += 4 + (size_t)(len < 0 ? 0 : len);
  }
  return 0;
}

/* ---- T241：display / monitor 的可注入替身（第 15 组用）----
 * 真 GDK 的 monitor 列表在 gtk_init 之后就有。这里把「有没有 display /
 * 列表有几项 / 首项 scale 多少 / get_item 与 unref 是否配对」都变成可观测，
 * 于是 1x 的 CI 也能验 moonui_scale_of(NULL) 不是硬编码 1——那个 bug 在
 * 1x 机器上任何外部判据都平凡绿，只有注入 2x 才看得见。 */
static int g_mock_has_display = 1;
static unsigned g_mock_monitor_n = 1;
static int g_mock_monitor_scale = 1;
static int g_mock_get_item_calls = 0;
static int g_mock_unref_calls = 0;
static char g_mock_display_obj, g_mock_model_obj, g_mock_monitor_obj;

GdkDisplay *gdk_display_get_default(void) {
  return g_mock_has_display ? (GdkDisplay *)&g_mock_display_obj : NULL;
}
GListModel *gdk_display_get_monitors(GdkDisplay *d) {
  return d == NULL ? NULL : (GListModel *)&g_mock_model_obj;
}
/* T251 的替身对象（第 23 组用），声明提前：上面的列表模型替身要按身份分流。 */
static char g_mock_ime_model_obj, g_mock_ime_ctrl_obj, g_mock_ime_ctx_obj;
static char g_mock_ime_owner_a, g_mock_ime_owner_b;
static int g_mock_ime_observe_calls = 0;
static int g_mock_ime_get_item_calls = 0;
static int g_mock_ime_ctx_calls = 0;
static int g_mock_ime_connect_calls = 0;
static int g_mock_ime_ctx_null = 0;
static char g_mock_ime_preedit[64];

guint g_list_model_get_n_items(GListModel *model) {
  if (model == (GListModel *)&g_mock_ime_model_obj) return 1;
  (void)model;
  return (guint)g_mock_monitor_n;
}
gpointer g_list_model_get_item(GListModel *model, guint position) {
  if (model == (GListModel *)&g_mock_ime_model_obj) {
    (void)position;
    ++g_mock_ime_get_item_calls;
    return (gpointer)&g_mock_ime_ctrl_obj;
  }
  (void)model;
  (void)position;
  ++g_mock_get_item_calls;
  return g_mock_monitor_n > 0 ? (gpointer)&g_mock_monitor_obj : NULL;
}
int gdk_monitor_get_scale_factor(GdkMonitor *m) {
  (void)m;
  return g_mock_monitor_scale;
}
void g_object_unref(void *o) {
  (void)o;
  ++g_mock_unref_calls;
}
/* 组合串的释放（prelude 的 changed 处理器 g_free 掉 get_preedit_string 的返回）。
 * 假 glib 没有这个符号，不补的话 dynamic_lookup 会把调用跳到 0（2026-11-11 实测
 * 就是这里段的）。 */
static int g_mock_g_free_calls = 0;
void g_free(gpointer mem) {
  ++g_mock_g_free_calls;
  free(mem);
}

/* ---- T251：输入法组合的替身（第 23 组用）----
 * attach 的取口路径整条都变成可注入：observe_controllers 回一只假 model，唯一
 * 条目是假 controller，get_im_context 回 g_mock_ime_ctx_obj（g_mock_ime_ctx_null
 * 时回 NULL，量"取不到就不连信号"）。preedit 串由 g_mock_ime_preedit 注入，
 * 量 update 的带串与同串去重；g_signal_connect 记账，量四个信号都连上。
 * delegate 恒 NULL：走"自己就是编辑视图"那条分支（真 GtkEntry 的取法是
 * 内部的 GtkText，shape 相同——canvas-pixel 闸的 P6-14 组用真 GTK 验）。 */

GListModel *gtk_widget_observe_controllers(GtkWidget *w) {
  (void)w;
  ++g_mock_ime_observe_calls;
  return (GListModel *)&g_mock_ime_model_obj;
}
GtkEditable *gtk_editable_get_delegate(GtkEditable *e) {
  (void)e;
  return NULL;
}
GtkIMContext *gtk_event_controller_key_get_im_context(GtkEventControllerKey *c) {
  (void)c;
  ++g_mock_ime_ctx_calls;
  return g_mock_ime_ctx_null ? NULL : (GtkIMContext *)&g_mock_ime_ctx_obj;
}
void gtk_im_context_get_preedit_string(GtkIMContext *ctx, char **str,
                                       gpointer attrs, int *cursor_pos) {
  size_t n;
  (void)ctx;
  if (attrs != NULL) *(gpointer *)attrs = NULL;
  if (cursor_pos != NULL) *cursor_pos = 0;
  if (str == NULL) return;
  n = strlen(g_mock_ime_preedit);
  *str = (char *)malloc(n + 1);
  if (*str != NULL) memcpy(*str, g_mock_ime_preedit, n + 1);
}
void g_signal_connect(void *instance, const char *detailed_signal,
                      GCallback c_handler, void *data) {
  (void)instance;
  (void)detailed_signal;
  (void)c_handler;
  (void)data;
  ++g_mock_ime_connect_calls;
}

/* ---- T235 P6-9：图像源的替身（第 18 组用）----
 * 这条通道上真解码做不到（假头没有 gdk-pixbuf），而本组要验的本来也不是解码：
 * ①返回码三态（0 / -1 / -2）；②失败时 GError 必须被放掉；③成功时 GtkPicture
 * 真拿到**那张纹理**且 can-shrink=1；④纹理与 GBytes 的引用配平。
 * 「解码」用 PNG 魔数近似：喂进来的文件/字节是真 PNG（sips 可读的那份字节在
 * 下面），坏的那份是文本——所以"认得出真图、认不出垃圾"这层是可信的。
 * 真解码（gdk-pixbuf 真把像素解出来）在 canvas-pixel-check.sh 的真 GTK 闸里跑。 */
static const unsigned char g_png_sig[8] = {0x89, 0x50, 0x4E, 0x47,
                                           0x0D, 0x0A, 0x1A, 0x0A};
static char g_mock_tex_obj, g_mock_err_obj, g_mock_bytes_obj;
static int g_mock_tex_new_calls = 0;
static int g_mock_paintable_calls = 0;
static void *g_mock_last_paintable = NULL;
static int g_mock_can_shrink = -1;
static int g_mock_err_free_calls = 0;
static int g_mock_bytes_new_calls = 0;
static int g_mock_bytes_unref_calls = 0;
static size_t g_mock_bytes_len = 0;
static unsigned char g_mock_bytes_head[8];
static int g_mock_bytes_head_len = 0;

static int mock_is_png(const unsigned char *b, size_t n) {
  return n >= 8 && memcmp(b, g_png_sig, 8) == 0;
}
GBytes *g_bytes_new(const void *data, gsize size) {
  ++g_mock_bytes_new_calls;
  g_mock_bytes_len = (size_t)size;
  g_mock_bytes_head_len = size >= 8 ? 8 : (int)size;
  if (g_mock_bytes_head_len > 0) {
    memcpy(g_mock_bytes_head, data, (size_t)g_mock_bytes_head_len);
  }
  return (GBytes *)&g_mock_bytes_obj;
}
void g_bytes_unref(GBytes *bytes) {
  (void)bytes;
  ++g_mock_bytes_unref_calls;
}
GdkTexture *gdk_texture_new_from_filename(const char *filename, GError **error) {
  unsigned char head[8];
  size_t n = 0;
  FILE *f;
  ++g_mock_tex_new_calls;
  f = fopen(filename, "rb");
  if (f != NULL) {
    n = fread(head, 1, sizeof(head), f);
    fclose(f);
  }
  if (!mock_is_png(head, n)) {
    if (error != NULL) *error = (GError *)&g_mock_err_obj;
    return NULL;
  }
  return (GdkTexture *)&g_mock_tex_obj;
}
GdkTexture *gdk_texture_new_from_bytes(GBytes *bytes, GError **error) {
  (void)bytes;
  ++g_mock_tex_new_calls;
  if (!mock_is_png(g_mock_bytes_head, (size_t)g_mock_bytes_head_len)) {
    if (error != NULL) *error = (GError *)&g_mock_err_obj;
    return NULL;
  }
  return (GdkTexture *)&g_mock_tex_obj;
}
void gtk_picture_set_paintable(GtkPicture *p, GdkPaintable *paintable) {
  (void)p;
  ++g_mock_paintable_calls;
  g_mock_last_paintable = paintable;
}
void gtk_picture_set_can_shrink(GtkPicture *p, gboolean can_shrink) {
  (void)p;
  g_mock_can_shrink = can_shrink ? 1 : 0;
}
void g_error_free(GError *error) {
  (void)error;
  ++g_mock_err_free_calls;
}

static void expect_str(const char *what, const char *got, const char *want) {
  ++g_checks;
  if (strcmp(got, want) != 0) {
    printf("  FAIL %s: got \"%s\", want \"%s\"\n", what, got, want);
    ++g_fails;
  }
}

static void expect_int(const char *what, long long got, long long want) {
  ++g_checks;
  if (got != want) {
    printf("  FAIL %s: got %lld, want %lld\n", what, got, want);
    ++g_fails;
  }
}

static void check_key_name(guint keyval, const char *want) {
  moonui_key_name_store(keyval);
  expect_str("key_name", moonui_key_name_buf, want);
}

/* ---- 假 GTK 控件树（T235 P6-1）----
 * 控件登记表 / 命中反查 / 层叠序号这三块是**纯指针逻辑**：只问"父是谁、下一个
 * 兄弟是谁、这个点命中谁"。所以给一份够用的假树就能在本机真跑判据——不碰 GTK
 * 运行时，也不需要窗口。补的是"声明有、实现不在"的那四个符号（与上面
 * gdk_keyval_name 同一招）。
 *
 * 假树**故意不模拟 GTK 的坐标/布局**：这几条判据验的是账（谁登记了、谁在里面、
 * 谁在上面），坐标换算要靠真机（P8）。 */
struct _GtkWidget {
  GtkWidget *parent;
  GtkWidget *first_child;
  GtkWidget *next_sibling;
  GtkWidget *pick; /* gtk_widget_pick 的结果：判据直接摆 */
};

GtkWidget *gtk_widget_get_parent(GtkWidget *w) {
  return w == NULL ? NULL : w->parent;
}
GtkWidget *gtk_widget_get_first_child(GtkWidget *w) {
  return w == NULL ? NULL : w->first_child;
}
GtkWidget *gtk_widget_get_next_sibling(GtkWidget *w) {
  return w == NULL ? NULL : w->next_sibling;
}
GtkWidget *gtk_widget_pick(GtkWidget *w, double x, double y, GtkPickFlags flags) {
  (void)x; (void)y; (void)flags;
  return w == NULL ? NULL : w->pick;
}

/* P6-5b 焦点链：第 13 组要真跑 moonui_gtk_focus_tab_step（它调这两个 GTK
 * 入口）。替身只记「窗口当下的焦点给了谁」，与真 GTK4 探针量到的形状同义
 * （gtk_window_get_focus 返回焦点 widget，grab_focus 换掉它）。 */
static GtkWidget *g_mock_focus = NULL;
GtkWidget *gtk_window_get_focus(GtkWindow *w) {
  (void)w;
  return g_mock_focus;
}
void gtk_widget_grab_focus(GtkWidget *w) {
  g_mock_focus = w;
}

/* 挂成最后一个孩子（GtkFixed 的绘制顺序 = 子节点顺序 = 后来的在上）。 */
static void mock_add_child(GtkWidget *parent, GtkWidget *child) {
  GtkWidget *it;
  child->parent = parent;
  child->next_sibling = NULL;
  if (parent->first_child == NULL) {
    parent->first_child = child;
    return;
  }
  it = parent->first_child;
  while (it->next_sibling != NULL) it = it->next_sibling;
  it->next_sibling = child;
}

/* ---- 菜单树打包（T235 P6-4）----
 * 与 adapter.h 那段布局逐字节一致（整数小端 i32；字符串 = i32 字节数 + UTF-8）。
 * 判据要同时喂**好树**与**坏树**，所以打包这一步得自己写一遍，而不是复用 C 侧的
 * 解析器——复用就变成"自己跟自己对"，两边一起歪也能绿。 */
typedef struct {
  unsigned char buf[1024];
  int len;
} MockBlob;

static void blob_u8(MockBlob *b, int v) {
  if (b->len < (int)sizeof(b->buf)) b->buf[b->len] = (unsigned char)(v & 0xFF);
  b->len++;
}
static void blob_i32(MockBlob *b, int v) {
  blob_u8(b, v);
  blob_u8(b, v >> 8);
  blob_u8(b, v >> 16);
  blob_u8(b, v >> 24);
}
static void blob_str(MockBlob *b, const char *s) {
  int n = (int)strlen(s);
  int i;
  blob_i32(b, n);
  for (i = 0; i < n; ++i) blob_u8(b, (unsigned char)s[i]);
}
/* kind 0 可点项；has_sc 非 0 时接 u8 mods + i32 key_len + key。 */
static void blob_item(MockBlob *b, const char *label, int id, int role,
                      int checked, int enabled, int has_sc, int mods,
                      const char *key) {
  blob_u8(b, 0);
  blob_str(b, label);
  blob_i32(b, id);
  blob_u8(b, role);
  blob_u8(b, checked);
  blob_u8(b, enabled);
  blob_u8(b, has_sc);
  if (has_sc) {
    blob_u8(b, mods);
    blob_str(b, key);
  }
}

/* 解析一次并 dump 成文本（成功时调用方负责 free）。失败返回 -1，成功返回 0。 */
static int menu_dump_of(const MockBlob *b, char **out) {
  MoonuiMenuTree tree;
  MoonuiMenuText txt = {0};
  *out = NULL;
  if (moonui_menu_parse((const char *)b->buf, b->len, &tree) != 0) return -1;
  moonui_menu_dump_tree(&txt, &tree);
  moonui_menu_tree_free(&tree);
  *out = txt.p != NULL ? txt.p : (char *)calloc(1, 1);
  return 0;
}

/* ---- 第 10 组的两个小工具（T235 P6-4b）----
 * text_take 把生成物里那只动态文本抄进静态缓冲并释放：判据只用 const char*，
 * 不碰 MoonuiMenuText 的内部账（期望串是这里手写死的，不是从实现里读回来）。 */
static char g_text_buf[2048];
static const char *text_take(MoonuiMenuText *t) {
  size_t n = (t->p != NULL) ? t->len : 0;
  if (n > sizeof(g_text_buf) - 1) n = sizeof(g_text_buf) - 1;
  if (n > 0) memcpy(g_text_buf, t->p, n);
  g_text_buf[n] = '\0';
  free(t->p);
  t->p = NULL;
  t->len = 0;
  t->cap = 0;
  return g_text_buf;
}

static const char *permille_of(int v) {
  MoonuiMenuText t = {0};
  moonui_menu_text_put_permille(&t, v);
  return text_take(&t);
}

static const char *css_of(int kind, int64_t bg, int64_t fg, int radius_pm,
                          int font_pm, int weight, int *rc) {
  MoonuiMenuText t = {0};
  int r = moonui_gtk_style_css(&t, "moonui-w-test", kind, bg, fg,
                               radius_pm, font_pm, weight);
  if (rc != NULL) *rc = r;
  return text_take(&t);
}

/* ---- T235 P6-12：worker_run 的两个替身与记录（第 21 组用）----
 * 这条 ABI 在假头构建里也要**真跑**：线程是真的（pthread），只有"投回 UI 线程"
 * 那一步由本文件顶替——真 glib 把回调排进默认主上下文，自检没有主循环，所以
 * g_idle_add 只记下回调与载荷，由第 21 组手动泵一次（那正是事件循环每圈做的）。
 * moonbit_incref / decref 同理：计数桩让"两支闭包各一份、各自执行点回收"能在
 * 本机量出来。 */
static volatile int g_ref_incref;
static volatile int g_ref_decref;
void moonbit_incref(void *obj) {
  (void)obj;
  g_ref_incref++;
}
void moonbit_decref(void *obj) {
  (void)obj;
  g_ref_decref++;
}

static GSourceFunc g_idle_fn;
static gpointer g_idle_data;
static volatile int g_idle_calls;
static volatile int g_idle_fail; /* 1 = 模拟 g_idle_add 排队失败（回 0） */
guint g_idle_add(GSourceFunc function, gpointer data) {
  g_idle_calls++;
  if (g_idle_fail) return 0;
  g_idle_fn = function;
  g_idle_data = data;
  return 0x51D1u;
}

static volatile int g_work_calls;
static volatile int g_land_calls;
static pthread_t g_main_thread;
static pthread_t g_work_thread;
static pthread_t g_land_thread;
static int g_work_on_main;
static int g_land_on_main;
static void worker_work_cb(void *closure) {
  (void)closure;
  g_work_thread = pthread_self();
  g_work_on_main = pthread_equal(g_work_thread, g_main_thread) ? 1 : 0;
  g_work_calls++;
}
static void worker_land_cb(void *closure) {
  (void)closure;
  g_land_thread = pthread_self();
  g_land_on_main = pthread_equal(g_land_thread, g_main_thread) ? 1 : 0;
  g_land_calls++;
}

/* 第 22 组（P6-13）的两只监听桩：只累计调用次数，用来钉住"登记后没有自发
 * 通知"——GTK4 半没有组合事件源，闭包登记了也永远不该被调。 */
static int g_ime_calls;
static void ime_probe_a(void *closure) {
  (void)closure;
  g_ime_calls += 1;
}
static void ime_probe_b(void *closure) {
  (void)closure;
  g_ime_calls += 10;
}

int main(void) {
  /* ---- 1. 键名词表：与 mac 的 moonui_native_key_name_of_code 逐字一致 ---- */
  check_key_name(0xFF0D, "Enter");     /* GTK 叫 Return，词表正本叫 Enter */
  check_key_name(0xFF08, "Backspace"); /* GTK 叫 BackSpace */
  check_key_name(0xFF55, "PageUp");    /* GTK 叫 Page_Up */
  check_key_name(0xFF56, "PageDown");  /* GTK 叫 Page_Down */
  check_key_name(0x0020, "Space");     /* GTK 叫 space */
  check_key_name(0xFF09, "Tab");
  check_key_name(0xFF1B, "Escape");
  check_key_name(0xFFFF, "Delete");    /* GTK 的 Delete 是"向后删"，词表同义 */
  check_key_name(0xFF51, "Left");
  check_key_name(0xFF53, "Right");
  check_key_name(0xFF52, "Up");
  check_key_name(0xFF54, "Down");
  check_key_name(0xFF50, "Home");
  check_key_name(0xFF57, "End");
  check_key_name(0xFFBE, "F1");
  check_key_name(0x0061, "a");
  check_key_name(0x0041, "a"); /* 大写折小写，Shift 由修饰键位表达 */
  check_key_name(0x0031, "1");
  /* 词表外：留空串 → 调用方不产事件（同 mac 的 notify 那一支） */
  check_key_name(0xFFE1, "");
  check_key_name(0x1234, "");

  /* ---- 2. pack2：高 32 位 a、低 32 位 b；负值也要确定（有符号左移是 UB） ---- */
  expect_int("pack2(1,2)", moonui_pack2(1, 2),
             (long long)(((uint64_t)1u << 32) | (uint64_t)2u));
  expect_int("pack2(-5,7)", moonui_pack2(-5, 7),
             (long long)(((uint64_t)0xFFFFFFFBu << 32) | (uint64_t)7u));
  expect_int("pack2(-1,-1)", moonui_pack2(-1, -1),
             (long long)(((uint64_t)0xFFFFFFFFu << 32) | (uint64_t)0xFFFFFFFFu));
  expect_int("pack2(0,0)", moonui_pack2(0, 0), 0);

  /* ---- 3. 修饰键位：ABI 是 bit0 ctrl / bit1 alt / bit2 shift / bit3 meta ---- */
  expect_int("mods(none)", moonui_mods_of((GdkModifierType)0), 0);
  expect_int("mods(ctrl)", moonui_mods_of(GDK_CONTROL_MASK), 1);
  expect_int("mods(alt)", moonui_mods_of(GDK_ALT_MASK), 2);
  expect_int("mods(shift)", moonui_mods_of(GDK_SHIFT_MASK), 4);
  expect_int("mods(super)", moonui_mods_of(GDK_SUPER_MASK), 8);
  expect_int("mods(shift+ctrl)",
             moonui_mods_of((GdkModifierType)(GDK_SHIFT_MASK | GDK_CONTROL_MASK)),
             5);
  /* 鼠标按键位不许串到修饰键里（GDK 的 BUTTON* 从 1<<8 起，两套不重叠） */
  expect_int("mods(button1 only)", moonui_mods_of(GDK_BUTTON1_MASK), 0);

  /* ---- 4. 鼠标钮号映射（ABI：0 Left / 1 Right / 2 Middle / 3 Extra1 / 4 Extra2）---- */
  expect_int("button(gtk 1)", moonui_map_button(1), 0);
  expect_int("button(gtk 2)", moonui_map_button(2), 2);
  expect_int("button(gtk 3)", moonui_map_button(3), 1);
  expect_int("button(gtk 8)", moonui_map_button(8), 3);
  expect_int("button(gtk 9)", moonui_map_button(9), 4);
  expect_int("button(gtk 4)", moonui_map_button(4), -1);
  expect_int("button(gtk 0)", moonui_map_button(0), -1);

  /* ---- 5. kind 2 的 button 位 = 按住哪颗在拖 ---- */
  expect_int("held(none)", moonui_held_button((GdkModifierType)0), 0);
  expect_int("held(left)", moonui_held_button(GDK_BUTTON1_MASK), 0);
  expect_int("held(right)", moonui_held_button(GDK_BUTTON3_MASK), 1);
  expect_int("held(middle)", moonui_held_button(GDK_BUTTON2_MASK), 2);

  /* ---- 6. 本平台未实现（T235 P5）：码必须是 adapter.h 的口径，不是中性桩的 0 ----
   *
   * 这一组验的是"不谎报"：中性桩 return 0，而 0 在 ABI 上多数是「成功」——音频
   * 那批返 0 会让应用壳以为歌装上了、播放器画得出来却永远不出声。所以逐条钉码。
   * 码表与 backends/native-windows/adapter_native.c 的音频段一致（同一契约）。 */
  expect_int("audio_load", moonui_native_audio_load("/x.mp3", 7), -3);
  expect_int("audio_play", moonui_native_audio_play(), -3);
  expect_int("audio_pause", moonui_native_audio_pause(), -3);
  expect_int("audio_stop", moonui_native_audio_stop(), -3);
  /* 位置/时长用 -1 表示"没有"（中性桩的 0 会被当成"播到了开头"） */
  expect_int("audio_position_ms", (long long)moonui_native_audio_position_ms(), -1);
  expect_int("audio_duration_ms", (long long)moonui_native_audio_duration_ms(), -1);
  expect_int("audio_seek_ms", moonui_native_audio_seek_ms(1000), -3);
  expect_int("audio_set_volume", moonui_native_audio_set_volume(500), -3);
  expect_int("audio_is_playing", moonui_native_audio_is_playing(), 0);
  /* 速率读回 1000（原速）：readback 不能用 0，那会被读成"停住了" */
  expect_int("audio_set_rate", moonui_native_audio_set_rate(1500), -3);
  expect_int("audio_rate", moonui_native_audio_rate(), 1000);
  expect_int("audio_on_finished", moonui_native_audio_on_finished(0, 0), -3);
  expect_int("audio_clear_on_finished", moonui_native_audio_clear_on_finished(), -3);
  expect_int("audio_prime", moonui_native_audio_prime("/x.mp3", 7), -3);
  expect_int("audio_prime_clear", moonui_native_audio_prime_clear(), -3);
  expect_int("audio_on_primed", moonui_native_audio_on_primed(0, 0), -3);
  expect_int("audio_clear_on_primed", moonui_native_audio_clear_on_primed(), -3);
  expect_int("audio_loudness_start", moonui_native_audio_loudness_start("/x.mp3", 7), -3);
  expect_int("audio_on_loudness", moonui_native_audio_on_loudness(0, 0), -3);
  expect_int("audio_clear_on_loudness", moonui_native_audio_clear_on_loudness(), -3);
  expect_int("audio_set_track_gain", moonui_native_audio_set_track_gain(300), 0);
  expect_int("audio_track_gain", moonui_native_audio_track_gain(), 0);
  /* EQ/频谱：读回 0 = 这侧没有，UI 据此不画假滑块 */
  expect_int("audio_level", moonui_native_audio_level(3), 0);
  expect_int("audio_eq_band_count", moonui_native_audio_eq_band_count(), 0);
  expect_int("audio_eq_set_band", moonui_native_audio_eq_set_band(0, 300), -3);
  expect_int("audio_eq_band_gain", moonui_native_audio_eq_band_gain(0), 0);
  expect_int("audio_eq_set_enabled", moonui_native_audio_eq_set_enabled(1), -3);
  expect_int("audio_eq_enabled", moonui_native_audio_eq_enabled(), 0);
  expect_int("audio_output_set", moonui_native_audio_output_set(1), -3);
  expect_int("media_keys_set", moonui_native_media_keys_set(0, 0), -3);
  expect_int("hotkeys_set", moonui_native_hotkeys_set(0, 0), -3);
  expect_int("now_playing_set",
             moonui_native_now_playing_set("t", 1, "a", 1, 0, 0, 1), -3);

  /* bytes 出参的两条必须给**空包**而不是 NULL：MoonBit 侧拿返回值直接 .length()，
   * NULL 会在那儿解引用空指针闪退（2026-10-16 选目录闪退案的修法，mac 同契约）。 */
  {
    unsigned char *out = (unsigned char *)moonui_native_audio_output_list();
    g_checks++;
    if (out == NULL) {
      printf("  FAIL audio_output_list: NULL（要空包）\n");
      ++g_fails;
    } else if (!(out[0] == 0 && out[1] == 0 && out[2] == 0 && out[3] == 0 &&
                 out[4] == 0xFF && out[5] == 0xFF && out[6] == 0xFF && out[7] == 0xFF)) {
      printf("  FAIL audio_output_list: 载荷不是 [count=0][current=-1]\n");
      ++g_fails;
    }
  }
  {
    unsigned char *probe = (unsigned char *)moonui_native_audio_probe("/x.mp3", 7);
    g_checks++;
    if (probe == NULL) {
      printf("  FAIL audio_probe: NULL（要空包）\n");
      ++g_fails;
    }
  }

  /* ---- 7. 控件挂载层的身份账（T235 P6-1，真跑）----
   * 三件事：kind 登记表（存 kind+1，0=空槽）、命中反查沿父链、层叠序号从尾数。
   * 全部是纯指针逻辑，所以在这一层能真跑出判据。 */
  {
    GtkWidget win, panel, custom, inner, nd_a, nd_b, label;

    memset(&win, 0, sizeof(win));
    memset(&panel, 0, sizeof(panel));
    memset(&custom, 0, sizeof(custom));
    memset(&inner, 0, sizeof(inner));
    memset(&nd_a, 0, sizeof(nd_a));
    memset(&nd_b, 0, sizeof(nd_b));
    memset(&label, 0, sizeof(label));

    /* kind 登记表：查得到的必须原值返回 */
    expect_int("wslot_alloc(Panel 17)", moonui_wslot_alloc(&panel, 17) != NULL, 1);
    expect_int("wslot_alloc(Custom 18)", moonui_wslot_alloc(&custom, 18) != NULL, 1);
    expect_int("kind_of(Panel)", moonui_widget_kind_of(&panel), 17);
    expect_int("kind_of(Custom)", moonui_widget_kind_of(&custom), 18);
    expect_int("kind_of(未登记控件)", moonui_widget_kind_of(&inner), -1);

    /* kind 0 是 Label：**不能**和"空槽"混成同一个值。
     * 这条正是"存 kind+1"的理由——如果直接存 kind，Label 会被读成没登记。 */
    expect_int("wslot_alloc(Label kind0)", moonui_wslot_alloc(&label, 0) != NULL, 1);
    expect_int("kind_of(Label)=0 不是空槽", moonui_widget_kind_of(&label), 0);
    moonui_wslot_free(&label);
    expect_int("kind_of(销账后)", moonui_widget_kind_of(&label), -1);
    expect_int("kind_of(销账只销自己)", moonui_widget_kind_of(&panel), 17);

    /* 命中反查：pick 命中的就是我们造的控件 → 报它自己 */
    mock_add_child(&win, &panel);
    mock_add_child(&panel, &inner);
    win.pick = &custom;
    expect_int("owner_at(命中 Custom)",
               (GtkWidget *)moonui_owner_at(&win, 1.0, 1.0) == &custom, 1);
    /* 命中的是控件的内部分件（真实 GTK 里 pick 会落到这种节点上）→ 沿父链
     * 找到最近一个登记过的祖先。找不到就直接报内部分件会让 Core 拿到一个
     * 它不认识的句柄。 */
    win.pick = &inner;
    expect_int("owner_at(内部分件→父级 Panel)",
               (GtkWidget *)moonui_owner_at(&win, 1.0, 1.0) == &panel, 1);
    /* 空白：pick 回到窗口自己（窗口不在控件登记表里）→ 0 */
    win.pick = &win;
    expect_int("owner_at(空白=窗口)",
               (GtkWidget *)moonui_owner_at(&win, 1.0, 1.0) == NULL, 1);
    win.pick = NULL;
    expect_int("owner_at(pick=NULL)",
               (GtkWidget *)moonui_owner_at(&win, 1.0, 1.0) == NULL, 1);

    /* 层叠序号：GtkFixed 里后挂的画在上面，所以 0 = 最后一个孩子 */
    mock_add_child(&win, &nd_a);
    mock_add_child(&win, &nd_b); /* win 的子链：[panel, nd_a, nd_b] */
    expect_int("z_index(最后挂的)", moonui_widget_z_index(&nd_b), 0);
    expect_int("z_index(中间的)", moonui_widget_z_index(&nd_a), 1);
    expect_int("z_index(最先挂的)", moonui_widget_z_index(&panel), 2);
    expect_int("z_index(无父=-1)", moonui_widget_z_index(&custom), -1);
    expect_int("z_index(空指针=-1)", moonui_widget_z_index(NULL), -1);

    /* 容器判定：Panel 是容器（也是 GtkFixed），Custom 不是。
     * 这条钉的是"container_attach 只往 GtkFixed 里挂"那道闸。 */
    expect_int("is_container(Panel 17)", moonui_gtk_is_container(&panel), 1);
    expect_int("is_container(Custom 18)", moonui_gtk_is_container(&custom), 0);
    expect_int("is_container(NULL)", moonui_gtk_is_container(NULL), 0);

    /* 不是 window_new 造的窗口：一律不接管（如实 NULL → 调用方拿到 -1）。
     * 这条防的是"随便一个 GtkWidget 当窗口传进来就往上挂"的静默错挂。 */
    expect_int("window_overlay(非我们造的窗)",
               moonui_gtk_window_overlay(&win, 1) == NULL, 1);
    expect_int("window_fixed(非我们造的窗)",
               moonui_gtk_window_fixed(&win, 1) == NULL, 1);

    moonui_wslot_free(&panel);
    moonui_wslot_free(&custom);
  }

  /* ---- 8. 对话框的 response → ABI 返回码（T235 P6-3，纯映射、真跑）----
   * 这一段钉的是"哪些应答算同意"。它比看起来重要：confirm 的返回值直接决定应用
   * 会不会执行那个动作（删文件、覆盖保存），而 GTK 的 response 有八种取值。口径
   * 错成"非 NO 即同意"的话，Esc / 直接关窗 / DELETE_EVENT 都会被当成"用户点了是"
   * ——那是这类代码最危险的一种错，且真窗判据很难覆盖全（Esc 与关窗不好模拟）。
   * message 相反：只有一只按钮，按了确定与面板被关掉对调用方是同一件事。 */
  expect_int("message_result(OK)", moonui_dialog_message_result(GTK_RESPONSE_OK), 0);
  expect_int("message_result(关掉=DELETE)",
             moonui_dialog_message_result(GTK_RESPONSE_DELETE_EVENT), 0);
  expect_int("confirm_result(YES) 算同意",
             moonui_dialog_confirm_result(GTK_RESPONSE_YES), 1);
  expect_int("confirm_result(NO) 算不同意",
             moonui_dialog_confirm_result(GTK_RESPONSE_NO), 0);
  expect_int("confirm_result(CANCEL) 算不同意",
             moonui_dialog_confirm_result(GTK_RESPONSE_CANCEL), 0);
  expect_int("confirm_result(DELETE_EVENT) 算不同意",
             moonui_dialog_confirm_result(GTK_RESPONSE_DELETE_EVENT), 0);
  /* 没有应答（GTK_RESPONSE_NONE）绝不能落成"同意"：那是"没答"，不是"答应了"。 */
  expect_int("confirm_result(NONE) 不算同意",
             moonui_dialog_confirm_result(GTK_RESPONSE_NONE), 0);

  /* ---- 9. 菜单树解析 + dump 文本（T235 P6-4，纯逻辑、真跑）----
   * 这一段钉两件事：
   *   ① **好树**能解析并 dump 成 adapter.h 约定的那根文本——它是像素闸里那条
   *      "读原生模型"判据的**对拍基准**（两边的期望串必须逐字相同：C 侧走真
   *      GMenuModel dump、这里走"字节树直接 dump"，任一侧拼法歪了都有一边红）。
   *   ② **坏树**一律 -1，且解析失败时不留半个结构。菜单树是 Core 一次推下来的
   *      快照，里面没有长度校验也能"跑得动"——它会读到别的内存去；这类错在真机
   *      上表现为菜单乱码/崩溃，很难倒查到这一层。
   */
  {
    MockBlob mb;
    char *dump = NULL;
    int rc;
    int i;

    /* File{New(Ctrl+Q), Auto(勾), —, Off(禁用), More{Sub}}; Edit{A(单选勾)} */
    mb.len = 0;
    blob_u8(&mb, 1);
    blob_i32(&mb, 2);
    blob_str(&mb, "File");
    blob_i32(&mb, 5);
    blob_item(&mb, "New", 10, 0, 0, 1, 1, 1, "q");
    blob_item(&mb, "Auto", 11, 1, 1, 1, 0, 0, "");
    blob_u8(&mb, 1); /* 分隔线 */
    blob_item(&mb, "Off", 12, 0, 0, 0, 0, 0, "");
    blob_u8(&mb, 2); /* 子菜单 */
    blob_str(&mb, "More");
    blob_i32(&mb, 1);
    blob_item(&mb, "Sub", 13, 0, 0, 1, 0, 0, "");
    blob_str(&mb, "Edit");
    blob_i32(&mb, 1);
    blob_item(&mb, "A", 20, 2, 1, 1, 0, 0, "");
    rc = menu_dump_of(&mb, &dump);
    expect_int("menu_parse(好树)", rc, 0);
    if (rc == 0) {
      expect_str("menu_dump_tree(好树)", dump,
                 "File{#10:n.e:New:Cq,#11:c+e:Auto:.,-,#12:n.d:Off:.,"
                 "+More{#13:n.e:Sub:.}};Edit{#20:r+e:A:.}");
      free(dump);
    }

    /* 空树（version=1, menu_count=0）：合法，dump 是空串 = "把菜单拆掉"。 */
    mb.len = 0;
    blob_u8(&mb, 1);
    blob_i32(&mb, 0);
    rc = menu_dump_of(&mb, &dump);
    expect_int("menu_parse(空树)", rc, 0);
    if (rc == 0) {
      expect_str("menu_dump_tree(空树)", dump, "");
      free(dump);
    }

    /* 尾巴多出来的字节不看（同 mac 口径）：解析器只按 count 走。 */
    mb.len = 0;
    blob_u8(&mb, 1);
    blob_i32(&mb, 0);
    blob_u8(&mb, 0x7F);
    expect_int("menu_parse(尾部多余字节不看)", menu_dump_of(&mb, &dump), 0);
    free(dump);

    /* 版本号不对 */
    mb.len = 0;
    blob_u8(&mb, 2);
    blob_i32(&mb, 0);
    expect_int("menu_parse(version=2) 报 -1", menu_dump_of(&mb, &dump), -1);

    /* 负的 menu_count */
    mb.len = 0;
    blob_u8(&mb, 1);
    blob_i32(&mb, -1);
    expect_int("menu_parse(menu_count<0) 报 -1", menu_dump_of(&mb, &dump), -1);

    /* 未知 kind（9） */
    mb.len = 0;
    blob_u8(&mb, 1);
    blob_i32(&mb, 1);
    blob_str(&mb, "F");
    blob_i32(&mb, 1);
    blob_u8(&mb, 9);
    expect_int("menu_parse(kind=9) 报 -1", menu_dump_of(&mb, &dump), -1);

    /* 截断：好树砍掉最后 3 个字节（Edit 的最后一个字段读不全） */
    mb.len = 0;
    blob_u8(&mb, 1);
    blob_i32(&mb, 1);
    blob_str(&mb, "F");
    blob_i32(&mb, 1);
    blob_item(&mb, "X", 7, 0, 0, 1, 0, 0, "");
    mb.len -= 3;
    expect_int("menu_parse(截断) 报 -1", menu_dump_of(&mb, &dump), -1);

    /* 比最短合法树还短 */
    expect_int("menu_parse(4 字节) 报 -1",
               moonui_menu_parse("abcd", 4, &(MoonuiMenuTree){0}), -1);

    /* 嵌套超过 32 层：递归要有上限，不然一棵恶意/写错的树能把栈吃干净。 */
    mb.len = 0;
    blob_u8(&mb, 1);
    blob_i32(&mb, 1);
    blob_str(&mb, "Deep");
    blob_i32(&mb, 1);
    for (i = 0; i < 40; ++i) {
      blob_u8(&mb, 2);
      blob_str(&mb, "S");
      blob_i32(&mb, 1);
    }
    blob_item(&mb, "Leaf", 1, 0, 0, 1, 0, 0, "");
    expect_int("menu_parse(嵌套 40 层) 报 -1", menu_dump_of(&mb, &dump), -1);
  }

  /* ---- 10. 主题 / CSS 的纯逻辑（T235 P6-4b，真跑）----
   * 钉两件事：① 我们生成的 CSS 原串长什么样；② 系统深不深色怎么判。
   * 真 GTK 那一半（provider 挂没挂上、GTK 解析后的 CSS、Pango 读到的字号）
   * 在 canvas-pixel 闸里。但 GTK 会把任何**合法** CSS 都照收：rgb 通道顺序
   * 写歪、permille 少了前导零、kind 多消费一面，真跑闸可能照样绿。所以两边
   * 必须各有判据——这里逐字钉原串，真跑闸钉 GTK 对象，谁都不读自己的账。
   */
  {
    int rc;

    /* permille → "N.mmm"。小数位错了 GTK 仍解析成合法字号（7.25px），
     * 真跑闸看不出来，只有这里的逐字对拍能拦住。 */
    expect_str("permille(7250)", permille_of(7250), "7.250");
    expect_str("permille(12000)", permille_of(12000), "12.000");
    expect_str("permille(7)", permille_of(7), "0.007");
    expect_str("permille(0)", permille_of(0), "0.000");
    expect_str("permille(-1) 一个字节都不写", permille_of(-1), "");

    /* 契约只认 0/1/2 三档；未知值按 Regular，不发明第四档。 */
    expect_int("weight_css(0)", moonui_gtk_style_weight_css(0), 400);
    expect_int("weight_css(1)", moonui_gtk_style_weight_css(1), 500);
    expect_int("weight_css(2)", moonui_gtk_style_weight_css(2), 700);
    expect_int("weight_css(99) 回落 Regular",
               moonui_gtk_style_weight_css(99), 400);
    expect_int("weight_css(-1) 回落 Regular",
               moonui_gtk_style_weight_css(-1), 400);

    /* Panel(17)：只吃 bg + radius。fg / font / weight 全喂满也不许漏进 CSS；
     * rgb 的通道顺序（R,G,B）也在这里钉死。 */
    expect_str("style_css(Panel 只吃底色与圆角)",
               css_of(17, 0x123456, 0xAABBCC, 7250, 14500, 2, &rc),
               ".moonui-w-test {\n"
               "  background-color: rgb(18,52,86);\n"
               "  border-radius: 7.250px;\n"
               "}\n");
    expect_int("style_css(Panel) 成功", rc > 0, 1);

    /* Label(0)：只吃 fg + font + weight，bg / radius 必须被无视。 */
    expect_str("style_css(Label 只吃前景与字体)",
               css_of(0, 0x123456, 0xAABBCC, 7250, 14500, 2, &rc),
               ".moonui-w-test {\n"
               "  color: rgb(170,187,204);\n"
               "  font-size: 14.500px;\n"
               "  font-weight: 700;\n"
               "}\n");
    expect_int("style_css(Label) 成功", rc > 0, 1);

    /* Button(1)：两面都吃，顺序固定（底色/圆角在前，前景/字体在后）。 */
    expect_str("style_css(Button 两面都吃)",
               css_of(1, 0x010203, 0xFEFDFC, 0, 0, 1, &rc),
               ".moonui-w-test {\n"
               "  background-color: rgb(1,2,3);\n"
               "  border-radius: 0.000px;\n"
               "  color: rgb(254,253,252);\n"
               "  font-size: 0.000px;\n"
               "  font-weight: 500;\n"
               "}\n");
    expect_int("style_css(Button) 成功", rc > 0, 1);

    /* -1 是"未设置"哨兵：那一项不写进 CSS（state 里保留上次的值，
     * 累积逻辑在 theme_gtk.inc，这里只管文本一个字节都不多写）。 */
    expect_str("style_css(-1 哨兵全不写)",
               css_of(1, -1, -1, -1, -1, -1, &rc),
               ".moonui-w-test {\n}\n");
    expect_int("style_css(-1 哨兵) 仍算成功", rc > 0, 1);

    /* 不认识的 kind：返回 -1 且一个字节都不写，调用方据此静默忽略。 */
    expect_str("style_css(kind=2) 不写 CSS",
               css_of(2, 0x112233, 0x445566, 1, 1, 1, &rc), "");
    expect_int("style_css(kind=2) 报 -1", rc, -1);
    {
      MoonuiMenuText t0 = {0};
      expect_int("style_css(text=NULL) 报 -1",
                 moonui_gtk_style_css(NULL, "x", 1, 0, 0, 0, 0, 0), -1);
      expect_int("style_css(cls=NULL) 报 -1",
                 moonui_gtk_style_css(&t0, NULL, 1, 0, 0, 0, 0, 0), -1);
      expect_str("style_css(cls=NULL) 不写 CSS", text_take(&t0), "");
    }

    /* 系统外观：4.20+ 的新属性明确表态时优先于老属性。GTK 4.24 会把两代
     * 属性联动（设 prefer-dark 会改 scheme），真跑闸里必须把 scheme 复位成
     * default 才能测回落分支；这里传的是纯整数，两代可以独立摆。 */
    expect_int("theme_dark(明确 DARK，老属性说浅)",
               moonui_gtk_theme_dark(2, 2, 1, 0, "Adwaita"), 1);
    expect_int("theme_dark(明确 LIGHT 压过 prefer-dark 与 :dark)",
               moonui_gtk_theme_dark(1, 2, 1, 1, "Adwaita:dark"), 0);
    /* 4.6 口径：属性不存在（dark/light 值都是 -1）→ 只看老属性。 */
    expect_int("theme_dark(4.6 prefer-dark)",
               moonui_gtk_theme_dark(0, -1, -1, 1, "Adwaita"), 1);
    expect_int("theme_dark(4.6 theme-name :dark)",
               moonui_gtk_theme_dark(0, -1, -1, 0, "Adwaita:dark"), 1);
    expect_int("theme_dark(theme-name 大小写归一)",
               moonui_gtk_theme_dark(0, -1, -1, 0, "ADWAITA-DARK"), 1);
    expect_int("theme_dark(theme-name 中间夹 DARK)",
               moonui_gtk_theme_dark(0, -1, -1, 0, "Yaru-Dark-variant"), 1);
    expect_int("theme_dark(DEFAULT 且都读不到 → 浅色)",
               moonui_gtk_theme_dark(0, 2, 1, 0, "Adwaita"), 0);
    expect_int("theme_dark(theme-name=NULL → 浅色)",
               moonui_gtk_theme_dark(0, -1, -1, 0, NULL), 0);
    /* 枚举里冒出个未知值（UNSUPPORTED / 未来新增）：当没表态，回落老属性。 */
    expect_int("theme_dark(scheme 未知值回落 prefer-dark)",
               moonui_gtk_theme_dark(9, 2, 1, 1, "Adwaita"), 1);
    expect_int("theme_dark(scheme 未知值回落浅色)",
               moonui_gtk_theme_dark(9, 2, 1, 0, "Adwaita"), 0);
    /* 只有 dark 枚举查得到、light 查不到时也不能把任意 scheme 当 DARK。 */
    expect_int("theme_dark(light 值缺失，scheme 不等于 dark)",
               moonui_gtk_theme_dark(7, 2, -1, 0, NULL), 0);
    {
      /* lower[128] 只收前 127 字节：长名字里的 dark 在截断外就不算。
       * 这条不是猜的边界，是给"实现里那只定长缓冲"留一条可读的账。 */
      char long_name[200];
      memset(long_name, 'x', sizeof(long_name));
      memcpy(long_name + 100, "DARK", 4);
      long_name[104] = '\0';
      expect_int("theme_dark(长名字里 127 字节内的 DARK)",
                 moonui_gtk_theme_dark(0, -1, -1, 0, long_name), 1);
      memset(long_name, 'x', sizeof(long_name));
      memcpy(long_name + 130, "dark", 4);
      long_name[134] = '\0';
      expect_int("theme_dark(dark 在 127 字节截断外)",
                 moonui_gtk_theme_dark(0, -1, -1, 0, long_name), 0);
    }
  }

  /* ---- 11. 无障碍的纯逻辑（T235 P6-4c，真跑）----
   * 这一层逐字钉"我们要交给 GTK 的是什么"：role 名字、checked 档位、按长度
   * 复制出来的文本、两条偏好读数的每个分支。真 GTK 那一半（role 有没有真落到
   * widget、LABEL/DESCRIPTION/CHECKED 能不能被 gtk_test_accessible_check_* 读回、
   * DISABLED/HIDDEN 是不是留给 GTK 的活值）在 canvas-pixel 闸里。
   * 两边都不能省：光有真跑闸的话，把 role 表里的两个名字对调、把 checked 的
   * FALSE/TRUE 对调，GTK 都会照收（都是合法值），判据照样绿。 */
  {
    static const char *const role_names[] = {
      "GTK_ACCESSIBLE_ROLE_LABEL",          /* 0 Text */
      "GTK_ACCESSIBLE_ROLE_BUTTON",         /* 1 Button */
      "GTK_ACCESSIBLE_ROLE_CHECKBOX",       /* 2 CheckBox */
      "GTK_ACCESSIBLE_ROLE_TEXT_BOX",       /* 3 TextBox */
      "GTK_ACCESSIBLE_ROLE_GROUP",          /* 4 Group */
      "GTK_ACCESSIBLE_ROLE_LIST",           /* 5 List */
      "GTK_ACCESSIBLE_ROLE_LIST_ITEM",      /* 6 ListItem */
      "GTK_ACCESSIBLE_ROLE_WINDOW",         /* 7 Window */
      "GTK_ACCESSIBLE_ROLE_SLIDER",         /* 8 SliderRole */
      "GTK_ACCESSIBLE_ROLE_PROGRESS_BAR"    /* 9 ProgressRole */
    };
    int i;
    char *t;

    /* ① role 序号 → GTK 枚举名字（十个声明序号逐一逐字对拍）。
     * 这里给的是**名字**不是数值：真 GTK 侧按 GEnum 名字查值，4.6 与 4.24
     * 的枚举值若增删都不会写错。 */
    for (i = 0; i < 10; ++i) {
      char what[64];
      const char *got = moonui_gtk_a11y_role_name(i);
      snprintf(what, sizeof(what), "a11y_role_name(%d)", i);
      expect_str(what, got != NULL ? got : "(null)", role_names[i]);
    }
    expect_int("a11y_role_name(10) 越界给 NULL",
               moonui_gtk_a11y_role_name(10) == NULL, 1);
    expect_int("a11y_role_name(99) 越界给 NULL",
               moonui_gtk_a11y_role_name(99) == NULL, 1);
    expect_int("a11y_role_name(-1) 越界给 NULL",
               moonui_gtk_a11y_role_name(-1) == NULL, 1);

    /* ② state 位包只解 bits2-3。bit0 visible / bit1 enabled 必须被无视：
     * 探针实测 GTK 自己按 set_sensitive/set_visible 活算 DISABLED/HIDDEN，
     * 注记快照就是 T58 在 MSAA 上量出来的谎报。 */
    expect_int("a11y_checked(0x00) 无此态", moonui_gtk_a11y_checked(0x00), 0);
    expect_int("a11y_checked(bit0 visible) 不消费",
               moonui_gtk_a11y_checked(0x01), 0);
    expect_int("a11y_checked(bit1 enabled) 不消费",
               moonui_gtk_a11y_checked(0x02), 0);
    expect_int("a11y_checked(0x03 两位都置) 仍无此态",
               moonui_gtk_a11y_checked(0x03), 0);
    expect_int("a11y_checked(0x04) 未勾", moonui_gtk_a11y_checked(0x04), 1);
    expect_int("a11y_checked(0x08) 已勾", moonui_gtk_a11y_checked(0x08), 2);
    expect_int("a11y_checked(0x0C) 混合", moonui_gtk_a11y_checked(0x0C), 3);
    expect_int("a11y_checked(0x0F) 低位不干扰 checked",
               moonui_gtk_a11y_checked(0x0F), 3);
    expect_int("a11y_checked(0xFF) 高位不干扰 checked",
               moonui_gtk_a11y_checked(0xFF), 3);

    /* ③ (ptr,len) 按字节复制：CJK、内嵌 NUL、ASCII 截断、空参数。
     * 用 strdup 的实现会在内嵌 NUL 处截短，这条会红。 */
    t = moonui_gtk_a11y_text("登录按钮\0尾巴ABCDEF", 12);
    expect_int("a11y_text(CJK) 非 NULL", t != NULL, 1);
    if (t != NULL) {
      expect_str("a11y_text(CJK 12 字节)", t, "登录按钮");
      expect_int("a11y_text(CJK) 按长度补 NUL", t[12], 0);
      free(t);
    }
    t = moonui_gtk_a11y_text("abcdef", 3);
    expect_str("a11y_text(ASCII 截断)", t != NULL ? t : "(null)", "abc");
    free(t);
    expect_int("a11y_text(NULL, 3) 给 NULL",
               moonui_gtk_a11y_text(NULL, 3) == NULL, 1);
    expect_int("a11y_text(ptr, 0) 给 NULL",
               moonui_gtk_a11y_text("abc", 0) == NULL, 1);
    expect_int("a11y_text(ptr, -1) 给 NULL",
               moonui_gtk_a11y_text("abc", -1) == NULL, 1);

    /* ④ 主题名里的高对比线索：大小写归一、两种拼法、NULL、截断。 */
    expect_int("a11y_hc_name(NULL)", moonui_gtk_a11y_hc_name(NULL), 0);
    expect_int("a11y_hc_name(Adwaita)", moonui_gtk_a11y_hc_name("Adwaita"), 0);
    expect_int("a11y_hc_name(HighContrast)",
               moonui_gtk_a11y_hc_name("HighContrast"), 1);
    expect_int("a11y_hc_name(HIGHCONTRAST 归一)",
               moonui_gtk_a11y_hc_name("HIGHCONTRAST"), 1);
    expect_int("a11y_hc_name(Adwaita-High-Contrast)",
               moonui_gtk_a11y_hc_name("Adwaita-High-Contrast"), 1);
    expect_int("a11y_hc_name(中间夹 highcontrast)",
               moonui_gtk_a11y_hc_name("Yaru-highcontrast-variant"), 1);
    {
      char long_name[200];
      memset(long_name, 'x', sizeof(long_name));
      memcpy(long_name + 100, "HIGHCONTRAST", 12);
      long_name[112] = '\0';
      expect_int("a11y_hc_name(127 字节内的线索)",
                 moonui_gtk_a11y_hc_name(long_name), 1);
      memset(long_name, 'x', sizeof(long_name));
      memcpy(long_name + 130, "highcontrast", 12);
      long_name[142] = '\0';
      expect_int("a11y_hc_name(线索在 127 字节截断外)",
                 moonui_gtk_a11y_hc_name(long_name), 0);
    }

    /* ⑤ 减少动态效果：gtk-enable-animations 的反面，读不到一律 0。 */
    expect_int("a11y_motion(属性不存在) 当偏好关",
               moonui_gtk_a11y_reduced_motion(0, 0), 0);
    expect_int("a11y_motion(动画开) 偏好关",
               moonui_gtk_a11y_reduced_motion(1, 1), 0);
    expect_int("a11y_motion(动画关) 偏好开",
               moonui_gtk_a11y_reduced_motion(1, 0), 1);

    /* ⑥ 高对比：4.20+ 明确 MORE/LESS 优先，NO_PREFERENCE / UNSUPPORTED /
     * 4.6 属性不存在回落到两个主题名；未知枚举不乱猜。
     * 枚举值按探针实测传：UNSUPPORTED=0 NO_PREFERENCE=1 MORE=2 LESS=3。 */
    expect_int("a11y_contrast(MORE 即使主题普通)",
               moonui_gtk_a11y_high_contrast(2, 2, 3, 1, 0,
                                             "Adwaita", "Adwaita"), 1);
    expect_int("a11y_contrast(MORE 压过主题名)",
               moonui_gtk_a11y_high_contrast(2, 2, 3, 1, 0,
                                             "HighContrast", NULL), 1);
    expect_int("a11y_contrast(LESS 压过主题名 HC)",
               moonui_gtk_a11y_high_contrast(3, 2, 3, 1, 0,
                                             "HighContrast", "HighContrast"), 0);
    expect_int("a11y_contrast(NO_PREFERENCE 回落 theme)",
               moonui_gtk_a11y_high_contrast(1, 2, 3, 1, 0,
                                             "HighContrast", NULL), 1);
    expect_int("a11y_contrast(UNSUPPORTED 回落 icon theme)",
               moonui_gtk_a11y_high_contrast(0, 2, 3, 1, 0,
                                             NULL, "Adwaita-High-Contrast"), 1);
    expect_int("a11y_contrast(4.6 属性不存在，theme HC)",
               moonui_gtk_a11y_high_contrast(0, -1, -1, -1, -1,
                                             "HighContrast", NULL), 1);
    expect_int("a11y_contrast(4.6 属性不存在，主题名普通)",
               moonui_gtk_a11y_high_contrast(0, -1, -1, -1, -1,
                                             "Adwaita", "Adwaita"), 0);
    expect_int("a11y_contrast(contrast=-1 且 more=-1 不能当 MORE)",
               moonui_gtk_a11y_high_contrast(-1, -1, -1, -1, -1,
                                             "Adwaita", NULL), 0);
    expect_int("a11y_contrast(未知枚举不乱猜)",
               moonui_gtk_a11y_high_contrast(9, 2, 3, 1, 0,
                                             "HighContrast", NULL), 0);
    expect_int("a11y_contrast(两个主题名都 NULL)",
               moonui_gtk_a11y_high_contrast(1, 2, 3, 1, 0, NULL, NULL), 0);
  }

  /* ---- 12. 控件叶子的纯逻辑（T235 P6-5，真跑）----
   * 与真 GTK4 真跑闸互为两条腿：把 kind 映射表里两行对调、把文案通道号
   * 写歪，GTK 都会照收（都是合法分派），真跑闸照样绿；只有逐字对拍这层
   * 拦得住。期望值一律写**数字/字符串字面量**，不引用实现里的 #define，
   * 免得实现常量与判据一起改还互相印证。
   * 真 GTK 那一半（造出来的对象类型、文案/勾选/回调有没有真落到 widget）
   * 在 canvas-pixel 闸的 t_widget_new_kinds / t_leaf_* 里。 */
  {
    /* kind 0..19 → 构造形态号。P6-5b 起 14/15 落地（11/12）；6..12 走专属
     * 构造入口、19 WebView 仍如实缺席。 */
    static const int want_leaf[20] = {
      1, 2, 3, 5, 4, 6, 0, 0, 0, 0,
      13, 0, 0, 7, 11, 12, 8, 9, 10, 0
    };
    static const char *const want_name[14] = {
      "NONE", "LABEL", "BUTTON", "ENTRY", "PASSWORD",
      "CHECK", "SEP_H", "SEP_V", "IMAGE", "PANEL", "CUSTOM",
      "MENUROW", "SCROLL", "TEXTVIEW"
    };
    /* 构造形态号 → 文案通道号（0 无 / 1 label / 2 button / 3 check / 4 editable）。
     * 14 MenuRow 是 GtkToggleButton（探针 GTK_IS_BUTTON=1），文案走 Button 那条。 */
    static const int want_channel[14] = {
      0, 1, 2, 4, 4, 3, 0, 0, 0, 0, 0, 2, 0, 5
    };
    /* 构造形态号 → 勾选通道号（0 无 / 1 GtkCheckButton / 2 GtkToggleButton）。
     * 两族不是同一类（探针 GTK_IS_BUTTON(GtkCheckButton)=0），不能共用一个宏。 */
    static const int want_active[14] = {
      0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 0
    };
    int i;
    char *t;
    char what[64];

    for (i = 0; i < 20; ++i) {
      snprintf(what, sizeof(what), "leaf_of_kind(%d)", i);
      expect_int(what, moonui_gtk_leaf_of_kind(i), want_leaf[i]);
    }
    expect_int("leaf_of_kind(负数)", moonui_gtk_leaf_of_kind(-1), 0);
    expect_int("leaf_of_kind(20) 越界", moonui_gtk_leaf_of_kind(20), 0);
    for (i = 0; i < 14; ++i) {
      const char *got = moonui_gtk_leaf_name(i);
      snprintf(what, sizeof(what), "leaf_name(%d)", i);
      expect_str(what, got != NULL ? got : "(null)", want_name[i]);
      snprintf(what, sizeof(what), "leaf_text_channel(%d)", i);
      expect_int(what, moonui_gtk_leaf_text_channel(i), want_channel[i]);
      snprintf(what, sizeof(what), "leaf_active_channel(%d)", i);
      expect_int(what, moonui_gtk_leaf_active_channel(i), want_active[i]);
    }
    /* P6-5c 起 leaf 13 = TEXTVIEW（kind 10 多行文本）已落地，边界随之移到 14。 */
    expect_str("leaf_name(13) 是 TEXTVIEW",
               moonui_gtk_leaf_name(13) != NULL ? moonui_gtk_leaf_name(13)
                                                 : "(null)",
               "TEXTVIEW");
    expect_int("leaf_text_channel(13) 是 5", moonui_gtk_leaf_text_channel(13), 5);
    expect_int("leaf_active_channel(13) 是 0",
               moonui_gtk_leaf_active_channel(13), 0);
    expect_int("leaf_name(14) 越界给 NULL", moonui_gtk_leaf_name(14) == NULL, 1);
    expect_int("leaf_text_channel(14) 越界给 0",
               moonui_gtk_leaf_text_channel(14), 0);
    expect_int("leaf_active_channel(14) 越界给 0",
               moonui_gtk_leaf_active_channel(14), 0);

    /* (ptr,len) 按长度复制：CJK 字节数、内嵌 NUL 不提前截断、空/NULL/负长度
     * 给空串（文本通道里"空串"是清空，不是 a11y 那条 NULL=reset）。 */
    t = moonui_gtk_leaf_dup_text("abc", 3);
    expect_str("leaf_dup_text(ascii)", t != NULL ? t : "(null)", "abc");
    expect_int("leaf_dup_text(ascii) 末尾收口", t != NULL && t[3] == 0, 1);
    free(t);

    t = moonui_gtk_leaf_dup_text("中文测试", 12);
    expect_str("leaf_dup_text(CJK 12 字节)", t != NULL ? t : "(null)", "中文测试");
    expect_int("leaf_dup_text(CJK) strlen 是 12",
               t != NULL ? (int)strlen(t) : -1, 12);
    free(t);

    t = moonui_gtk_leaf_dup_text("AB\0CD", 5);
    expect_str("leaf_dup_text(内嵌 NUL 读作 C 串)", t != NULL ? t : "(null)", "AB");
    expect_int("leaf_dup_text(内嵌 NUL) 按长度照样抄完 5 字节",
               t != NULL && memcmp(t, "AB\0CD", 5) == 0, 1);
    free(t);

    t = moonui_gtk_leaf_dup_text("", 0);
    expect_str("leaf_dup_text(空串)", t != NULL ? t : "(null)", "");
    free(t);
    t = moonui_gtk_leaf_dup_text(NULL, 5);
    expect_str("leaf_dup_text(NULL)", t != NULL ? t : "(null)", "");
    free(t);
    t = moonui_gtk_leaf_dup_text("x", -1);
    expect_str("leaf_dup_text(负长度)", t != NULL ? t : "(null)", "");
    free(t);
  }


  /* ---- 13. P6-5b 的纯逻辑（焦点链 / 自绘面点击 / Tab 推进，真跑）----
   * 与 canvas-pixel 闸互为两条腿：GTK 会把任何合法指针都收下、把任何合法
   * 手势都照派发，所以「链解析歪一格」「拖出松手也算点击」在真跑闸上可能
   * 照样绿。这里逐字钉纯逻辑；真跑闸那半读的是 GTK 焦点状态与信号派发。
   * 期望值一律写数字/字符串字面量，不引用实现里的 #define。 */
  {
    moonui_ptr out[8];
    MoonuiWidgetSlot slot;
    MoonuiWinSlot *ws;
    GtkWidget win, w0, w1, w2, stranger;
    char ids[128];
    int n, rc, i;

    /* 焦点链文本：空格分隔十进制 owner 指针，(ptr,len) 不保证 NUL 结尾。 */
    n = moonui_gtk_focus_parse("1 22 333", 8, out, 8);
    expect_int("focus_parse(三段)", n, 3);
    expect_int("focus_parse 第 1 段", (long long)out[0], 1);
    expect_int("focus_parse 第 2 段", (long long)out[1], 22);
    expect_int("focus_parse 第 3 段", (long long)out[2], 333);
    expect_int("focus_parse(首尾/连续空格)",
               moonui_gtk_focus_parse("  7   8  ", 9, out, 8), 2);
    expect_int("focus_parse(空格后第 1 段)", (long long)out[0], 7);
    expect_int("focus_parse(空格后第 2 段)", (long long)out[1], 8);
    expect_int("focus_parse(空串清空)", moonui_gtk_focus_parse("", 0, out, 8), 0);
    expect_int("focus_parse(NULL 清空)", moonui_gtk_focus_parse(NULL, 3, out, 8), 0);
    expect_int("focus_parse(负长度报 -3)",
               moonui_gtk_focus_parse("1", -1, out, 8), -3);
    expect_int("focus_parse(非数字报 -3)",
               moonui_gtk_focus_parse("1 x", 3, out, 8), -3);
    expect_int("focus_parse(负号报 -3)",
               moonui_gtk_focus_parse("1 -2", 4, out, 8), -3);
    expect_int("focus_parse(段后紧跟字母报 -3)",
               moonui_gtk_focus_parse("12a", 3, out, 8), -3);
    expect_int("focus_parse(超过 uintptr 上限报 -3)",
               moonui_gtk_focus_parse("18446744073709551616", 20, out, 8), -3);
    n = moonui_gtk_focus_parse("18446744073709551615", 20, out, 8);
    expect_int("focus_parse(恰好上限)", n, 1);
    expect_int("focus_parse(上限值读回)",
               out[0] == (moonui_ptr)~(moonui_ptr)0, 1);
    expect_int("focus_parse(超过 cap 报 -3)",
               moonui_gtk_focus_parse("1 2 3", 5, out, 2), -3);
    /* (ptr,len) Tail 后面的字节不许被读进去：len 只盖住 "1 2"。 */
    expect_int("focus_parse(按 len 截断)",
               moonui_gtk_focus_parse("1 2ZZZ", 3, out, 8), 2);

    /* 链的下一跳：尾回链头、Shift 反向、焦点不在链上从头/从尾。 */
    expect_int("focus_next(3,0,forward)", moonui_gtk_focus_next_index(3, 0, 0), 1);
    expect_int("focus_next(3,2,forward) 回绕",
               moonui_gtk_focus_next_index(3, 2, 0), 0);
    expect_int("focus_next(3,0,backward) 回绕",
               moonui_gtk_focus_next_index(3, 0, 1), 2);
    expect_int("focus_next(3,2,backward)",
               moonui_gtk_focus_next_index(3, 2, 1), 1);
    expect_int("focus_next(焦点不在链上,forward)",
               moonui_gtk_focus_next_index(3, -1, 0), 0);
    expect_int("focus_next(焦点不在链上,backward)",
               moonui_gtk_focus_next_index(3, -1, 1), 2);
    expect_int("focus_next(越界 cur 当不在链上)",
               moonui_gtk_focus_next_index(3, 7, 0), 0);
    expect_int("focus_next(空链)", moonui_gtk_focus_next_index(0, 0, 0), -1);
    expect_int("focus_next(单元素链回环)",
               moonui_gtk_focus_next_index(1, 0, 0), 0);

    /* 自绘面「按下并原地抬起」：slop 4.0、多击不算、没按过不算、拖出不算。 */
    memset(&slot, 0, sizeof(slot));
    expect_int("click_edge(pressed 不派发)",
               moonui_gtk_custom_click_edge(&slot, 1, 10.0, 10.0, 0), 0);
    expect_int("click_edge(原地抬起)",
               moonui_gtk_custom_click_edge(&slot, 1, 10.0, 10.0, 1), 1);
    expect_int("click_edge(重复抬起不再派发)",
               moonui_gtk_custom_click_edge(&slot, 1, 10.0, 10.0, 1), 0);
    moonui_gtk_custom_click_edge(&slot, 1, 10.0, 10.0, 0);
    expect_int("click_edge(slop 边界内 4.0)",
               moonui_gtk_custom_click_edge(&slot, 1, 14.0, 10.0, 1), 1);
    moonui_gtk_custom_click_edge(&slot, 1, 10.0, 10.0, 0);
    expect_int("click_edge(拖出 4.1 不派发)",
               moonui_gtk_custom_click_edge(&slot, 1, 14.1, 10.0, 1), 0);
    moonui_gtk_custom_click_edge(&slot, 1, 10.0, 10.0, 0);
    expect_int("click_edge(y 方向拖出也不派发)",
               moonui_gtk_custom_click_edge(&slot, 1, 10.0, 30.0, 1), 0);
    memset(&slot, 0, sizeof(slot));
    expect_int("click_edge(没按过就抬起)",
               moonui_gtk_custom_click_edge(&slot, 1, 10.0, 10.0, 1), 0);
    expect_int("click_edge(n_press=2 的 pressed 不记账)",
               moonui_gtk_custom_click_edge(&slot, 2, 10.0, 10.0, 0), 0);
    expect_int("click_edge(n_press=2 的 released 不派发)",
               moonui_gtk_custom_click_edge(&slot, 1, 10.0, 10.0, 1), 0);
    expect_int("click_edge(NULL 槽不崩)",
               moonui_gtk_custom_click_edge(NULL, 1, 1.0, 1.0, 1), 0);

    /* kind 14 MenuRow 的 CSS 消费面：与 Button 同形（bg/radius + fg/font/weight）。
     * GTK 会照收任何合法 CSS，这一层必须逐字对拍原串。 */
    {
      const char *css = css_of(14, 0x010203, 0xFEFDFC, 0, 0, 1, &rc);
      expect_str("style_css(kind 14 MenuRow 与 Button 同消费面)", css,
                 ".moonui-w-test {\n"
                 "  background-color: rgb(1,2,3);\n"
                 "  border-radius: 0.000px;\n"
                 "  color: rgb(254,253,252);\n"
                 "  font-size: 0.000px;\n"
                 "  font-weight: 500;\n"
                 "}\n");
      expect_int("style_css(kind 14) 成功", rc > 0, 1);
    }
    /* 键名：Tab 在词表里（事件流不动），ISO_Left_Tab 不在（不产事件，但
     * key_pressed 会按 gdk_keyval_name 的原名认它做反向遍历）。 */
    moonui_key_name_store(0xFF09);
    expect_str("key_name(Tab)", moonui_key_name_buf, "Tab");
    moonui_key_name_store(0xFE20);
    expect_str("key_name(ISO_Left_Tab 词表外)", moonui_key_name_buf, "");

    /* Tab 按链推进：用假 GTK 焦点替身真跑 moonui_gtk_focus_tab_step。
     * 造一只假窗口 + 三只登记过的假控件；链是 Core 推来的 owner 指针文本，
     * 这里直接填进窗口槽（set_focus_chain 这条 ABI 在假头构建里是替身桩，
     * 它的解析已由上面的 focus_parse 逐字钉住）。 */
    memset(&win, 0, sizeof(win));
    memset(&w0, 0, sizeof(w0));
    memset(&w1, 0, sizeof(w1));
    memset(&w2, 0, sizeof(w2));
    memset(&stranger, 0, sizeof(stranger));
    g_mock_focus = NULL;
    ws = moonui_win_slot_alloc(&win);
    if (ws == NULL || moonui_wslot_alloc(&w0, 1) == NULL ||
        moonui_wslot_alloc(&w1, 1) == NULL ||
        moonui_wslot_alloc(&w2, 1) == NULL) {
      expect_int("mock 焦点树登记得上", 0, 1);
    } else {
      snprintf(ids, sizeof(ids), "%llu %llu %llu",
               (unsigned long long)(uintptr_t)&w0,
               (unsigned long long)(uintptr_t)&w1,
               (unsigned long long)(uintptr_t)&w2);
      n = moonui_gtk_focus_parse(ids, (int)strlen(ids), out, 8);
      expect_int("mock 链文本解析出 3 段", n, 3);
      for (i = 0; i < n; ++i) ws->focus_chain[i] = out[i];
      ws->focus_chain_len = n;
      expect_int("Tab(空焦点→链首) 接管", moonui_gtk_focus_tab_step(&win, 0), 1);
      expect_int("Tab(空焦点→链首) 焦点落在 w0", g_mock_focus == &w0, 1);
      expect_int("Tab(前进→w1)", moonui_gtk_focus_tab_step(&win, 0), 1);
      expect_int("Tab(前进) 焦点落在 w1", g_mock_focus == &w1, 1);
      expect_int("Tab(前进→w2)", moonui_gtk_focus_tab_step(&win, 0), 1);
      expect_int("Tab(前进) 焦点落在 w2", g_mock_focus == &w2, 1);
      expect_int("Tab(链尾回绕→w0)", moonui_gtk_focus_tab_step(&win, 0), 1);
      expect_int("Tab(回绕) 焦点落在 w0", g_mock_focus == &w0, 1);
      expect_int("Shift+Tab(反向回绕→w2)",
                 moonui_gtk_focus_tab_step(&win, 1), 1);
      expect_int("Shift+Tab 焦点落在 w2", g_mock_focus == &w2, 1);
      /* 链里是没登记过的指针：不许把野指针喂给 GTK，交回默认 z 序。
       * 焦点当下在 w2（下标 2），Shift+Tab 的下一跳正是下标 1。 */
      ws->focus_chain[1] = (moonui_ptr)(uintptr_t)&stranger;
      expect_int("Tab(链里是野指针) 不接管",
                 moonui_gtk_focus_tab_step(&win, 1), 0);
      expect_int("Tab(野指针) 焦点没动", g_mock_focus == &w2, 1);
      /* 空链清空：交回 GTK 自己的 z 序（契约：空串 = 清空链）。 */
      ws->focus_chain_len = 0;
      expect_int("Tab(空链) 不接管", moonui_gtk_focus_tab_step(&win, 0), 0);
    }
  }
  /* ---- 第 14 组：P6-5c DatePicker 的日期文本解析（纯逻辑，真跑）----
   * moonui_gtk_parse_datetime 是 GtkCalendar「只认日期、时间靠 date_cache 往返」
   * 时唯一的把关口：把 (ptr,len) 里的 "YYYY-MM-DD HH:MM:SS" 拆成六个整数并做范围
   * 校验。解析错了，要么把非法日期送进 select_day（GTK 会自己纠到合法值，看不出来），
   * 要么把合法日期判成非法（控件反而不动）。这一层不碰 GTK，所以在 mac 上真跑。 */
  {
    int Y = 0, M = 0, D = 0, h = 0, mi = 0, sd = 0;
    char buf[32];
    /* 合法：字段值逐字对上 */
    expect_int("parse_datetime 合法返回 1",
               moonui_gtk_parse_datetime("2026-11-09 13:30:45", 19, &Y, &M, &D,
                                         &h, &mi, &sd), 1);
    expect_int("parse_datetime 年份", Y, 2026);
    expect_int("parse_datetime 月", M, 11);
    expect_int("parse_datetime 日", D, 9);
    expect_int("parse_datetime 时", h, 13);
    expect_int("parse_datetime 分", mi, 30);
    expect_int("parse_datetime 秒", sd, 45);
    /* 边界：上下限都算合法 */
    expect_int("parse_datetime 下界合法",
               moonui_gtk_parse_datetime("0001-01-01 00:00:00", 19, &Y, &M, &D,
                                         &h, &mi, &sd), 1);
    expect_int("parse_datetime 上界合法",
               moonui_gtk_parse_datetime("9999-12-31 23:59:59", 19, &Y, &M, &D,
                                         &h, &mi, &sd), 1);
    /* 非法：整数字段越界 */
    expect_int("parse_datetime 月 13 非法",
               moonui_gtk_parse_datetime("2026-13-09 13:30:45", 19, &Y, &M, &D,
                                         &h, &mi, &sd), 0);
    expect_int("parse_datetime 月 0 非法",
               moonui_gtk_parse_datetime("2026-00-09 13:30:45", 19, &Y, &M, &D,
                                         &h, &mi, &sd), 0);
    expect_int("parse_datetime 日 0 非法",
               moonui_gtk_parse_datetime("2026-11-00 13:30:45", 19, &Y, &M, &D,
                                         &h, &mi, &sd), 0);
    expect_int("parse_datetime 日 32 非法",
               moonui_gtk_parse_datetime("2026-11-32 13:30:45", 19, &Y, &M, &D,
                                         &h, &mi, &sd), 0);
    expect_int("parse_datetime 时 24 非法",
               moonui_gtk_parse_datetime("2026-11-09 24:00:00", 19, &Y, &M, &D,
                                         &h, &mi, &sd), 0);
    expect_int("parse_datetime 分 60 非法",
               moonui_gtk_parse_datetime("2026-11-09 13:60:00", 19, &Y, &M, &D,
                                         &h, &mi, &sd), 0);
    expect_int("parse_datetime 秒 60 非法",
               moonui_gtk_parse_datetime("2026-11-09 13:30:60", 19, &Y, &M, &D,
                                         &h, &mi, &sd), 0);
    /* 非法：格式（分隔符、缺字段、短于 19、尾随、非数字、NULL） */
    expect_int("parse_datetime 斜杠分隔非法",
               moonui_gtk_parse_datetime("2026/11/09 13:30:45", 19, &Y, &M, &D,
                                         &h, &mi, &sd), 0);
    expect_int("parse_datetime 日期时间间非空格非法",
               moonui_gtk_parse_datetime("2026-11-09x13:30:45", 19, &Y, &M, &D,
                                         &h, &mi, &sd), 0);
    expect_int("parse_datetime 只有日期(短于19) 非法",
               moonui_gtk_parse_datetime("2026-11-09", 10, &Y, &M, &D, &h, &mi,
                                         &sd), 0);
    expect_int("parse_datetime 尾随多余字符非法",
               moonui_gtk_parse_datetime("2026-11-09 13:30:45xyz", 22, &Y, &M,
                                         &D, &h, &mi, &sd), 0);
    expect_int("parse_datetime 非数字年份非法",
               moonui_gtk_parse_datetime("abcd-11-09 13:30:45", 19, &Y, &M, &D,
                                         &h, &mi, &sd), 0);
    expect_int("parse_datetime NULL 非法",
               moonui_gtk_parse_datetime(NULL, 19, &Y, &M, &D, &h, &mi, &sd), 0);
    /* 按长度、不看 NUL 结尾：只给 19 字节，后面塞一个 'Z' 不许被读到 */
    memcpy(buf, "2026-11-09 13:30:45", 19);
    buf[19] = 'Z';
    expect_int("parse_datetime 只读 19 字节（NUL 后不读）",
               moonui_gtk_parse_datetime(buf, 19, &Y, &M, &D, &h, &mi, &sd), 1);
  }
  /* ⑮ T241：未上屏那条 scale 口径。window_new / system_dpi 都调
   * moonui_scale_of(NULL)，以前它恒回 1；2x 屏上 window_new 按 1 换算、
   * content_size 按 2 读回，于是 window_new(320,240) 报 640x480。
   * 这一组是 1x 宿主上唯一能看见那条修复的判据——注入 2x 后必须报 2。 */
  {
    int items0, unrefs0;
    g_mock_has_display = 1;
    g_mock_monitor_n = 1;
    g_mock_monitor_scale = 2;
    items0 = g_mock_get_item_calls;
    unrefs0 = g_mock_unref_calls;
    expect_int("T241 2x display：scale_of(NULL) 报 2",
               moonui_scale_of(NULL), 2);
    expect_int("T241 取过 monitor 列表首项",
               g_mock_get_item_calls - items0, 1);
    expect_int("T241 monitor 首项配对 unref（真 GDK 不漏引用）",
               g_mock_unref_calls - unrefs0, 1);
    g_mock_monitor_scale = 1;
    expect_int("T241 1x display：scale_of(NULL) 报 1",
               moonui_scale_of(NULL), 1);
    g_mock_monitor_scale = 0;
    expect_int("T241 非法 scale 回落 1", moonui_scale_of(NULL), 1);
    g_mock_monitor_scale = 2;
    g_mock_monitor_n = 0;
    expect_int("T241 空 monitor 列表回落 1", moonui_scale_of(NULL), 1);
    g_mock_has_display = 0;
    expect_int("T241 无 display 回落 1", moonui_scale_of(NULL), 1);
    g_mock_has_display = 1;
  }
  /* ---- 第 16 组：渲染后端名字表与偏好文件往返（T235 P6-7，纯逻辑，真跑）----
   * Linux 只有 cairo/pixman 一种光栅后端，所以 resolve 恒 Auto；但 parse 的
   * 名字表与 mac 同构，偏好文件三条 ABI（写默认路径 / 写指定路径 / 读原始码）
   * 都要真落盘再读回。整组不碰 GTK，mac 上也能跑。 */
  {
    char p[128];
    char home[128];
    char pref[192];
    char *old_home = getenv("HOME");
    FILE *f;

    expect_int("parse(NULL) → Auto", (int)moonui_render_backend_parse(NULL), 0);
    expect_int("parse(metal) → 2", (int)moonui_render_backend_parse("metal"), 2);
    expect_int("parse(cg) → 1", (int)moonui_render_backend_parse("cg"), 1);
    expect_int("parse(coregraphics) → 1",
               (int)moonui_render_backend_parse("coregraphics"), 1);
    expect_int("parse(auto) → Auto", (int)moonui_render_backend_parse("auto"), 0);
    expect_int("parse(未知) → Auto", (int)moonui_render_backend_parse("garbage"), 0);
    expect_int("resolve() 在 Linux 恒 Auto",
               (int)moonui_render_backend_resolve(), 0);
    expect_int("resolve_at(NULL) 与 resolve 同口径",
               (int)moonui_render_backend_resolve_at(NULL), 0);

    /* `_at` 三条：指定路径里写什么、读回什么（不碰用户 home）。 */
    snprintf(p, sizeof(p), "/tmp/moonui-selftest-pref-%ld", (long)getpid());
    remove(p);
    expect_int("pref_code_at(不存在) → -1",
               moonui_render_backend_pref_code_at(p), -1);
    expect_int("write_pref_at(metal) → 0",
               moonui_render_backend_write_pref_at(p, "metal"), 0);
    expect_int("pref_code_at 读回 metal → 2",
               moonui_render_backend_pref_code_at(p), 2);
    expect_int("write_pref_at(cg) → 0",
               moonui_render_backend_write_pref_at(p, "cg"), 0);
    expect_int("pref_code_at 读回 cg → 1",
               moonui_render_backend_pref_code_at(p), 1);
    expect_int("write_pref_at(nonsense) → 0",
               moonui_render_backend_write_pref_at(p, "nonsense"), 0);
    expect_int("pref_code_at 读回 nonsense → 0",
               moonui_render_backend_pref_code_at(p), 0);
    expect_int("write_pref_at(NULL 路径) → -1",
               moonui_render_backend_write_pref_at(NULL, "cg"), -1);
    expect_int("write_pref_at(NULL 名字) → -1",
               moonui_render_backend_write_pref_at(p, NULL), -1);
    /* 手写一行带尾随空格 + CRLF：read_line 要去掉尾部空白，仍认得出 cg。 */
    f = fopen(p, "wb");
    expect_int("自检写临时偏好文件成功", f != NULL, 1);
    if (f != NULL) {
      fputs("cg  \r\n", f);
      fclose(f);
    }
    expect_int("pref_code_at 去尾部空白后仍认 cg → 1",
               moonui_render_backend_pref_code_at(p), 1);
    remove(p);

    /* 默认路径那条：用临时 HOME 验「建 .moonui 目录 + 落盘 + 读回」，不碰
     * 真用户目录。空 HOME 是契约里的失败支（-1）。 */
    snprintf(home, sizeof(home), "/tmp/moonui-selftest-home-%ld", (long)getpid());
    mkdir(home, 0700);
    snprintf(pref, sizeof(pref), "%s/.moonui/render_backend", home);
    setenv("HOME", home, 1);
    expect_int("write_pref(cg) 建目录并落盘 → 0",
               moonui_render_backend_write_pref("cg"), 0);
    expect_int("write_pref 之后 pref_code_at 读回 1",
               moonui_render_backend_pref_code_at(pref), 1);
    setenv("HOME", "", 1);
    expect_int("HOME 为空时 write_pref → -1",
               moonui_render_backend_write_pref("cg"), -1);
    if (old_home != NULL) {
      setenv("HOME", old_home, 1);
    } else {
      unsetenv("HOME");
    }
    remove(pref);
    {
      char sub[160];
      snprintf(sub, sizeof(sub), "%s/.moonui", home);
      rmdir(sub);
    }
    rmdir(home);
  }
  /* ---- 第 17 组：应用身份 + 显式缺席 + 目录行走（T235 P6-8，纯逻辑，真跑）----
   * 这一组验三件事：①host_platform / set_app_name / app_icon_present 的读数是
   * 本平台**正确值**（不是"还没来得及写"）；②notify / tray / content_permille
   * 如实报缺席，不再谎报 0；③walk_dir 的打包格式与失败支（0 字节空包，绝不
   * NULL）——那一条在 mac 与 Linux 上是同一份 libc 语义，所以本机能真跑。 */
  {
    char base[160];
    char miss[200];
    char sub[200];
    char f1[200];
    char f2[200];
    char withslash[176];
    FILE *f;

    expect_int("host_platform → 0 (Unknown)", moonui_native_host_platform(), 0);
    g_last_app_name[0] = '\0';
    expect_int("set_app_name(Luna Music) → 0",
               moonui_native_set_app_name("Luna Music", 10), 0);
    expect_str("set_app_name 交给 GLib 的名字", g_last_app_name, "Luna Music");
    expect_int("set_app_name(NULL) → -1", moonui_native_set_app_name(NULL, 0), -1);
    expect_int("set_app_name(len 0) → -1", moonui_native_set_app_name("x", 0), -1);

    expect_int("set_app_icon 收下 → 0", moonui_native_set_app_icon("AppIcon", 7), 0);
    expect_int("app_icon_present 恒 0", moonui_native_app_icon_present(), 0);
    expect_int("app_icon_content_permille 缺席 → -1",
               moonui_native_app_icon_content_permille(), -1);
    expect_int("notify 缺席 → -3", moonui_native_notify("t", 1, "b", 1), -3);
    expect_int("tray_set_icon 缺席 → -1", moonui_native_tray_set_icon("T", 1), -1);
    expect_int("tray_set_menu 缺席 → -1",
               moonui_native_tray_set_menu("[]", 2, NULL, NULL), -1);

    /* walk_dir 的失败支：0 字节空包，指针非 NULL（MoonBit 侧直接 .length()）。
     * moonui_ptr 是整数型句柄，所以拿 0 比，别拿 NULL 比（否则 -Wpointer-integer-compare）。 */
    expect_int("walk_dir(NULL) 非 0", moonui_native_walk_dir(NULL, 0) != 0, 1);
    expect_int("walk_dir(NULL) → 0 字节", g_last_bytes_size, 0);
    (void)moonui_native_walk_dir("", 0);
    expect_int("walk_dir(len 0) → 0 字节", g_last_bytes_size, 0);
    snprintf(base, sizeof(base), "/tmp/moonui-selftest-walk-%ld", (long)getpid());
    snprintf(miss, sizeof(miss), "%s/nope", base);
    (void)moonui_native_walk_dir(miss, (int)strlen(miss));
    expect_int("walk_dir(不存在的目录) → 0 字节", g_last_bytes_size, 0);

    /* 空目录：pack 只有 count（4 字节）。 */
    mkdir(base, 0700);
    (void)moonui_native_walk_dir(base, (int)strlen(base));
    expect_int("空目录 count = 0", walk_count(), 0);
    expect_int("空目录包长 = 4", g_last_bytes_size, 4);

    /* 2 文件 + 1 子目录：直接子项、绝对路径、不排序。 */
    snprintf(f1, sizeof(f1), "%s/a.txt", base);
    snprintf(f2, sizeof(f2), "%s/b.txt", base);
    snprintf(sub, sizeof(sub), "%s/sub", base);
    f = fopen(f1, "wb");
    if (f != NULL) fclose(f);
    f = fopen(f2, "wb");
    if (f != NULL) fclose(f);
    mkdir(sub, 0700);
    (void)moonui_native_walk_dir(base, (int)strlen(base));
    expect_int("三子项 count = 3", walk_count(), 3);
    expect_int("含 a.txt 的绝对路径", walk_has(f1), 1);
    expect_int("含 b.txt 的绝对路径", walk_has(f2), 1);
    expect_int("含子目录 sub", walk_has(sub), 1);
    expect_int("包长 = 4 + 3×(4+len)",
               4 + 3 * 4 + (long long)(strlen(f1) + strlen(f2) + strlen(sub)),
               (long long)g_last_bytes_size);

    /* 目录尾带 `/`：不许拼出 `//`，名字与不带斜杠时一致。 */
    snprintf(withslash, sizeof(withslash), "%s/", base);
    (void)moonui_native_walk_dir(withslash, (int)strlen(withslash));
    expect_int("尾斜杠 count 仍 3", walk_count(), 3);
    expect_int("尾斜杠不拼出 //", walk_has_double_slash(), 0);
    expect_int("尾斜杠名字与不带斜杠一致", walk_has(f1), 1);

    unlink(f1);
    unlink(f2);
    rmdir(sub);
    rmdir(base);
  }
  /* ---- 第 18 组：图像源两条（T235 P6-9，纯逻辑，真跑）----
   * 真解码（gdk-pixbuf）在 canvas-pixel 闸；这里验四类账：①返回码三态
   * （0 装上 / -1 解码失败 / -2 不指图像控件）；②坏输入必须把 GError 放掉
   * （否则每条坏路径漏一条 GLib 错误对象）；③成功时 GtkPicture 拿到的正是
   * 那张纹理，且 can-shrink 显式开；④纹理与 GBytes 的引用配平（我们自己那份
   * 也要放）。喂的文件是真 PNG（下面这份字节 sips 能读出 1×1），坏的那份是
   * 文本文件——替身按 PNG 魔数判"解不解得开"。 */
  {
    /* 一张 70 字节的合法 1×1 RGBA PNG（sips -g pixelWidth 读得出 1）。 */
    static const unsigned char one_px_png[] = {
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00,
        0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63,
        0x30, 0x4E, 0x9B, 0xF9, 0x1F, 0x00, 0x04, 0x34, 0x02, 0x32, 0x5B,
        0x2D, 0x0A, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
        0xAE, 0x42, 0x60, 0x82,
    };
    struct _GtkWidget img, other;
    char png_path[160];
    char bad_path[160];
    char missing[200];
    FILE *f;
    int u0, p0, e0, b0, bu0, t0;

    memset(&img, 0, sizeof(img));
    memset(&other, 0, sizeof(other));
    if (moonui_wslot_alloc(&img, 16) == NULL ||
        moonui_wslot_alloc(&other, 0) == NULL) {
      printf("  FAIL 图像源：控件登记表分配失败\n");
      ++g_checks;
      ++g_fails;
    } else {
      snprintf(png_path, sizeof(png_path), "/tmp/moonui-selftest-p69-%ld.png",
               (long)getpid());
      snprintf(bad_path, sizeof(bad_path), "/tmp/moonui-selftest-p69-%ld.txt",
               (long)getpid());
      snprintf(missing, sizeof(missing), "/tmp/moonui-selftest-p69-%ld/nope.png",
               (long)getpid());
      f = fopen(png_path, "wb");
      if (f != NULL) {
        fwrite(one_px_png, 1, sizeof(one_px_png), f);
        fclose(f);
      }
      f = fopen(bad_path, "wb");
      if (f != NULL) {
        fputs("not a png at all\n", f);
        fclose(f);
      }

      u0 = g_mock_unref_calls;
      p0 = g_mock_paintable_calls;
      e0 = g_mock_err_free_calls;
      b0 = g_mock_bytes_new_calls;
      bu0 = g_mock_bytes_unref_calls;
      t0 = g_mock_tex_new_calls;

      /* 真图：装上、can-shrink 开、纹理那份引用放掉。 */
      expect_int("set_path(真 PNG) → 0",
                 moonui_native_image_set_path((moonui_ptr)(uintptr_t)&img,
                                              png_path, (int)strlen(png_path)),
                 0);
      expect_int("真 PNG：paintable 装上 1 次", g_mock_paintable_calls - p0, 1);
      expect_int("真 PNG：装的是那张纹理",
                 g_mock_last_paintable == (void *)&g_mock_tex_obj, 1);
      expect_int("真 PNG：can-shrink 显式开", g_mock_can_shrink, 1);
      expect_int("真 PNG：纹理引用放掉 1 次", g_mock_unref_calls - u0, 1);

      /* 坏文件 / 不存在的路径：-1，GError 放掉，图不动（整源替换只在成功时发生）。 */
      expect_int("set_path(文本文件) → -1",
                 moonui_native_image_set_path((moonui_ptr)(uintptr_t)&img,
                                              bad_path, (int)strlen(bad_path)),
                 -1);
      expect_int("坏文件：GError 已放", g_mock_err_free_calls - e0, 1);
      expect_int("坏文件：paintable 不重设", g_mock_paintable_calls - p0, 1);
      expect_int("坏文件：没有纹理要放", g_mock_unref_calls - u0, 1);
      expect_int("set_path(不存在的路径) → -1",
                 moonui_native_image_set_path((moonui_ptr)(uintptr_t)&img,
                                              missing, (int)strlen(missing)),
                 -1);
      expect_int("不存在的路径：GError 已放", g_mock_err_free_calls - e0, 2);
      expect_int("set_path(NULL) → -1",
                 moonui_native_image_set_path((moonui_ptr)(uintptr_t)&img, NULL, 0),
                 -1);
      expect_int("set_path(空路径) → -1",
                 moonui_native_image_set_path((moonui_ptr)(uintptr_t)&img, "", 0),
                 -1);
      /* 空路径不该走到解码：调用数不变。 */
      expect_int("空路径不调解码", g_mock_tex_new_calls - t0, 3);

      /* kind 护栏：不是图像控件 / 空句柄 → -2，且不调解码。 */
      expect_int("set_path(非图像控件) → -2",
                 moonui_native_image_set_path((moonui_ptr)(uintptr_t)&other,
                                              png_path, (int)strlen(png_path)),
                 -2);
      expect_int("set_path(0 句柄) → -2",
                 moonui_native_image_set_path((moonui_ptr)0, png_path,
                                              (int)strlen(png_path)),
                 -2);
      expect_int("非图像控件不调解码", g_mock_tex_new_calls - t0, 3);

      /* 数据源：同一份 PNG 字节 → 0；GBytes 分配与释放配对；纹理引用放掉。 */
      expect_int("set_data(真 PNG 字节) → 0",
                 moonui_native_image_set_data((moonui_ptr)(uintptr_t)&img,
                                              (const char *)one_px_png,
                                              (int)sizeof(one_px_png)),
                 0);
      expect_int("真字节：GBytes 分配 1 次", g_mock_bytes_new_calls - b0, 1);
      expect_int("真字节：GBytes 释放 1 次", g_mock_bytes_unref_calls - bu0, 1);
      expect_int("真字节：长度原样交给 g_bytes_new",
                 (long long)g_mock_bytes_len, (long long)sizeof(one_px_png));
      expect_int("真字节：paintable 累计 2 次", g_mock_paintable_calls - p0, 2);
      expect_int("真字节：can-shrink 仍为开", g_mock_can_shrink, 1);
      expect_int("真字节：纹理引用累计 2 次", g_mock_unref_calls - u0, 2);

      /* 垃圾字节：-1，GBytes 照样释放、GError 放掉、图不动。 */
      expect_int("set_data(垃圾字节) → -1",
                 moonui_native_image_set_data((moonui_ptr)(uintptr_t)&img,
                                              "garbage!", 8),
                 -1);
      expect_int("垃圾字节：GError 已放", g_mock_err_free_calls - e0, 3);
      expect_int("垃圾字节：GBytes 仍释放", g_mock_bytes_unref_calls - bu0, 2);
      expect_int("垃圾字节：paintable 不重设", g_mock_paintable_calls - p0, 2);
      expect_int("set_data(NULL) → -1",
                 moonui_native_image_set_data((moonui_ptr)(uintptr_t)&img, NULL, 4),
                 -1);
      expect_int("set_data(len 0) → -1",
                 moonui_native_image_set_data((moonui_ptr)(uintptr_t)&img, "x", 0),
                 -1);
      /* 两条空数据都不该走到 g_bytes_new：计数停在"真字节 + 垃圾字节"的 2。 */
      expect_int("空数据不调 g_bytes_new", g_mock_bytes_new_calls - b0, 2);
      expect_int("set_data(非图像控件) → -2",
                 moonui_native_image_set_data((moonui_ptr)(uintptr_t)&other,
                                              (const char *)one_px_png,
                                              (int)sizeof(one_px_png)),
                 -2);
      expect_int("set_data(0 句柄) → -2",
                 moonui_native_image_set_data((moonui_ptr)0,
                                              (const char *)one_px_png, 8),
                 -2);

      unlink(png_path);
      unlink(bad_path);
      moonui_wslot_free(&img);
      moonui_wslot_free(&other);
    }
  }
  /* ---- 第 19 组：文件拖入三条（T235 P6-10，纯逻辑，真跑）----
   * 只验不碰 GTK 的那半：路径数组 → 快照的编码布局（i32 count + count×(i32
   * len, UTF-8)）、target 读回、空数组清空、重复装载的覆盖。真 "drop" 分发
   * （GdkFileList → GFile → 路径 → 闭包）在 canvas-pixel 闸里用真 GdkFileList
   * 驱动——假头的 GValue 是空壳，这里造不出来。 */
  {
    char a[] = "a/b";
    char b[] = "c/d/e";
    char zh[] = "中文";
    char *two[2];
    char *one[1];
    moonbit_bytes_t out;

    two[0] = a;
    two[1] = b;
    one[0] = zh;

    /* 初始态：没装过回调、没拖过 → target 0、空包。 */
    expect_int("on_file_drop(NULL,NULL) → 0",
               moonui_native_on_file_drop(0, 0), 0);
    expect_int("初始 target 是 0", (long long)moonui_native_file_drop_target(), 0);
    out = moonui_native_file_drop_paths();
    expect_int("初始 paths 是空包", g_last_bytes_size, 0);
    expect_int("空包非 NULL", out != 0, 1);

    /* 两条路径：4 + (4+3) + (4+5) = 20 字节。 */
    expect_int("snapshot_set(2 条) → 0",
               moonui_drop_snapshot_set((moonui_ptr)0xA5, two, 2), 0);
    expect_int("target 跟着快照走",
               (long long)moonui_native_file_drop_target(), 0xA5);
    out = moonui_native_file_drop_paths();
    expect_int("两条路径的总长", g_last_bytes_size, 20);
    expect_int("count 字段 = 2", drop_i32(out, 0), 2);
    expect_int("第一条长度 = 3", drop_i32(out, 4), 3);
    expect_int("第一条内容", memcmp(out + 8, "a/b", 3), 0);
    expect_int("第二条长度 = 5", drop_i32(out, 11), 5);
    expect_int("第二条内容", memcmp(out + 15, "c/d/e", 5), 0);

    /* 中文按 UTF-8 字节数，不按字符数（"中文" = 6 字节）。 */
    expect_int("snapshot_set(中文) → 0",
               moonui_drop_snapshot_set((moonui_ptr)0xB6, one, 1), 0);
    out = moonui_native_file_drop_paths();
    expect_int("中文路径总长 = 4+4+6", g_last_bytes_size, 14);
    expect_int("中文长度字段 = 6", drop_i32(out, 4), 6);
    expect_int("中文内容按字节", memcmp(out + 8, "中文", 6), 0);

    /* 空数组（count 0）：清空快照，target 归零，读回仍是空包。 */
    expect_int("snapshot_set(0 条) → 0",
               moonui_drop_snapshot_set((moonui_ptr)0xC7, two, 0), 0);
    expect_int("空数组把 target 清 0",
               (long long)moonui_native_file_drop_target(), 0);
    out = moonui_native_file_drop_paths();
    expect_int("空数组读回空包", g_last_bytes_size, 0);

    /* 负 count 同"没有路径"，不能去 malloc 负数。 */
    expect_int("snapshot_set(-1 条) → 0",
               moonui_drop_snapshot_set((moonui_ptr)0xD8, two, -1), 0);
    expect_int("负 count 也清空 target",
               (long long)moonui_native_file_drop_target(), 0);

    /* 重复装载覆盖前一份（长度按新内容算，不累加）。 */
    expect_int("snapshot_set(再次 2 条) → 0",
               moonui_drop_snapshot_set((moonui_ptr)0xE9, two, 2), 0);
    out = moonui_native_file_drop_paths();
    expect_int("覆盖后总长仍是 20", g_last_bytes_size, 20);
    expect_int("覆盖后 count 仍是 2", drop_i32(out, 0), 2);

    moonui_drop_snapshot_clear();
    expect_int("clear 之后 target 0",
               (long long)moonui_native_file_drop_target(), 0);
  }
  /* ---- 第 20 组：WebView 五条显式缺席（T235 P6-11，真跑）----
   * GTK4 本体没有网页视图，而中性桩的 return 0 在 on_webview / webview_load
   * 上会被 Core 当成"装上了 / 递进去了"。这里钉住与 adapter.h 的 Windows 半
   * 逐条对齐的缺席形状：-1 / 0 / 空包 / -2。 */
  {
    moonbit_bytes_t detail;
    expect_int("on_webview → -1（没有桥）",
               moonui_native_on_webview(0, 0), -1);
    expect_int("webview_target 恒 0",
               (long long)moonui_native_webview_target(), 0);
    expect_int("webview_phase 恒 0", moonui_native_webview_phase(), 0);
    detail = moonui_native_webview_detail();
    expect_int("webview_detail 是空包", g_last_bytes_size, 0);
    expect_int("空包非 NULL", detail != 0, 1);
    expect_int("webview_load(URL) → -2",
               moonui_native_webview_load(0, "https://example.invalid", 23, 0), -2);
    expect_int("webview_load(HTML) → -2",
               moonui_native_webview_load((moonui_ptr)0x1234, "<p>x</p>", 8, 1), -2);
  }
  /* ---- 第 21 组：worker_run 的线程与落地（T235 P6-12，真 pthread + 替身 idle）----
   * work 必须真在另一条线程跑；落地只能经 idle 源投一回，泵之前不跑、泵之后在
   * 主线程跑；两支闭包各拿一份引用、各在自己的执行点退掉。 */
  {
    void *wc = (void *)0x11;
    void *lc = (void *)0x22;

    g_ref_incref = 0;
    g_ref_decref = 0;
    g_idle_calls = 0;
    g_idle_fail = 0;
    g_idle_fn = 0;
    g_idle_data = 0;
    g_work_calls = 0;
    g_land_calls = 0;
    g_work_on_main = -1;
    g_land_on_main = -1;
    g_main_thread = pthread_self();

    /* 四参数任一缺失：-1，且不动引用、不起线程。 */
    expect_int("worker_run(work=NULL) → -1",
               moonui_native_worker_run(0, wc, worker_land_cb, lc), -1);
    expect_int("worker_run(work_closure=NULL) → -1",
               moonui_native_worker_run(worker_work_cb, 0, worker_land_cb, lc), -1);
    expect_int("worker_run(land=NULL) → -1",
               moonui_native_worker_run(worker_work_cb, wc, 0, lc), -1);
    expect_int("worker_run(land_closure=NULL) → -1",
               moonui_native_worker_run(worker_work_cb, wc, worker_land_cb, 0), -1);
    expect_int("缺参数不动引用", g_ref_incref, 0);
    expect_int("缺参数不起线程", g_work_calls, 0);

    /* 正常一趟：work 在 worker 线程跑，land 等在 idle 队列里。 */
    expect_int("worker_run 正常 → 0",
               moonui_native_worker_run(worker_work_cb, wc, worker_land_cb, lc), 0);
    expect_int("起线程前拿住两份引用", g_ref_incref, 2);
    {
      int waited = 0;
      while ((g_work_calls == 0 || g_idle_calls == 0) && waited < 2000) {
        usleep(1000);
        waited++;
      }
    }
    expect_int("work 跑过一次", g_work_calls, 1);
    expect_int("work 不在主线程", g_work_on_main, 0);
    expect_int("落地只投了一回", g_idle_calls, 1);
    expect_int("泵之前 land 不跑", g_land_calls, 0);
    expect_int("work 返回后回收自己那份", g_ref_decref, 1);
    expect_int("idle 回调记下来了", g_idle_fn != 0, 1);
    if (g_idle_fn != 0) {
      gboolean again = g_idle_fn(g_idle_data);
      expect_int("落地回调返回 FALSE（一次即摘）", again, 0);
    }
    expect_int("land 跑过一次", g_land_calls, 1);
    expect_int("land 在主线程", g_land_on_main, 1);
    expect_int("两份引用配平", g_ref_decref, 2);

    /* 排队失败（g_idle_add 回 0）：ABI 已回 0，worker 自己退 land 那份，不漏。 */
    g_ref_incref = 0;
    g_ref_decref = 0;
    g_work_calls = 0;
    g_land_calls = 0;
    g_idle_calls = 0;
    g_idle_fail = 1;
    expect_int("worker_run 再次 → 0",
               moonui_native_worker_run(worker_work_cb, wc, worker_land_cb, lc), 0);
    {
      int waited = 0;
      while (g_ref_decref < 2 && waited < 2000) {
        usleep(1000);
        waited++;
      }
    }
    expect_int("投递失败也没漏引用", g_ref_decref, 2);
    expect_int("投递失败不落地", g_land_calls, 0);
    g_idle_fail = 0;
  }
  /* ---- 第 22 组：输入法组合四条的簿记（T235 P6-13）----
   * 监听登记真的做（换回调、退旧引用、terminate 清账）；没有组合时三问如实报
   * 0 / 0 / 空包。相位源与相位机在第 23 组（T251）真跑，本组只量登记与空快照。 */
  {
    moonbit_bytes_t text;
    int inc0 = g_ref_incref;
    int dec0 = g_ref_decref;

    expect_int("on_ime(fn, cl) → 0",
               moonui_native_on_ime(ime_probe_a, (void *)0x31), 0);
    expect_int("挂号时拿住一份引用", g_ref_incref - inc0, 1);
    expect_int("存的是刚登记的回调", moonui_ime_fn == ime_probe_a, 1);
    expect_int("存的是刚登记的闭包", moonui_ime_closure == (void *)0x31, 1);

    /* 换监听：旧引用退掉、新引用拿住，槽位仍只有一个。 */
    expect_int("on_ime 换人 → 0",
               moonui_native_on_ime(ime_probe_b, (void *)0x32), 0);
    expect_int("换人退掉旧引用", g_ref_decref - dec0, 1);
    expect_int("换人再拿一份", g_ref_incref - inc0, 2);
    expect_int("换人后存的是新回调", moonui_ime_fn == ime_probe_b, 1);
    expect_int("换人后存的是新闭包", moonui_ime_closure == (void *)0x32, 1);

    /* closure 为 0：只清槽位，不去 incref/decref 一个空指针。 */
    expect_int("on_ime(fn, 0) → 0", moonui_native_on_ime(ime_probe_a, 0), 0);
    expect_int("空闭包退掉上一份", g_ref_decref - dec0, 2);
    expect_int("空闭包不再拿引用", g_ref_incref - inc0, 2);
    expect_int("空闭包把槽位清 0", moonui_ime_closure == 0, 1);

    /* 三问：没有组合时的如实回答。 */
    expect_int("ime_target 恒 0", (long long)moonui_native_ime_target(), 0);
    expect_int("ime_phase 恒 0", moonui_native_ime_phase(), 0);
    text = moonui_native_ime_text();
    expect_int("ime_text 是空包", g_last_bytes_size, 0);
    expect_int("空包非 NULL", text != 0, 1);
    expect_int("再读仍非 NULL", moonui_native_ime_text() != 0, 1);
    expect_int("再读长度仍是 0", g_last_bytes_size, 0);

    /* 通知永不发生：登记之后没有谁会把闭包跑起来。 */
    expect_int("登记后没有自发通知", g_ime_calls, 0);

    /* terminate 的那一步：退引用并清槽位。 */
    moonui_native_on_ime(ime_probe_a, (void *)0x33);
    {
      int dec1 = g_ref_decref;
      moonui_ime_drop_listener();
      expect_int("清账退掉最后一份", g_ref_decref - dec1, 1);
      expect_int("清账后 fn 归 0", moonui_ime_fn == 0, 1);
      expect_int("清账后闭包归 0", moonui_ime_closure == 0, 1);
    }
  }
  /* ---- 第 23 组：输入法组合相位的旁听接线（T251，真跑相位机）----
   * attach 的取口、四个信号的接线、start → update* → end 的相位机都在这里真跑：
   * 假 model / controller / ctx 由上面的替身提供，preedit 串可注入。 */
  {
    GtkWidget *wa = (GtkWidget *)&g_mock_ime_owner_a;
    GtkWidget *wb = (GtkWidget *)&g_mock_ime_owner_b;
    GtkIMContext *ctx = (GtkIMContext *)&g_mock_ime_ctx_obj;
    moonbit_bytes_t text;
    int o0, c0, u0, f0;

    moonui_ime_reset_state();
    moonui_native_on_ime(ime_probe_a, (void *)0x41);
    g_ime_calls = 0;

    g_mock_ime_ctx_null = 0;
    g_mock_ime_observe_calls = 0;
    g_mock_ime_ctx_calls = 0;
    g_mock_ime_connect_calls = 0;
    u0 = g_mock_unref_calls;
    moonui_gtk_ime_attach(wa);
    expect_int("attach 枚举控件 controller", g_mock_ime_observe_calls, 1);
    expect_int("attach 问 key controller 的 im_context", g_mock_ime_ctx_calls, 1);
    expect_int("四个组合信号都连上", g_mock_ime_connect_calls, 4);
    expect_int("controller 与 model 各放一份引用", g_mock_unref_calls - u0, 2);

    /* 取不到 im_context：不连任何信号（也不崩）。 */
    g_mock_ime_ctx_null = 1;
    o0 = g_mock_ime_observe_calls;
    c0 = g_mock_ime_connect_calls;
    moonui_gtk_ime_attach(wb);
    expect_int("ctx 为空也走完取口", g_mock_ime_observe_calls - o0, 1);
    expect_int("ctx 为空不连信号", g_mock_ime_connect_calls - c0, 0);
    g_mock_ime_ctx_null = 0;

    /* start → update → 同串去重 → 再 update → 空串 end。 */
    moonui_ime_on_start(ctx, wa);
    expect_int("start 通知 1 次", g_ime_calls, 1);
    expect_int("start 相位 0", moonui_native_ime_phase(), 0);
    expect_int("start 的 target 是这只控件",
               (long long)moonui_native_ime_target(), (long long)(moonui_ptr)wa);
    text = moonui_native_ime_text();
    expect_int("start 不带串", g_last_bytes_size, 0);
    expect_int("start 空包非 NULL", text != 0, 1);

    strcpy(g_mock_ime_preedit, "ni");
    f0 = g_mock_g_free_calls;
    moonui_ime_on_changed(ctx, wa);
    expect_int("changed 通知 1 次", g_ime_calls, 2);
    expect_int("changed 释放组合串 1 次", g_mock_g_free_calls - f0, 1);
    expect_int("changed 相位 1", moonui_native_ime_phase(), 1);
    text = moonui_native_ime_text();
    expect_int("update 带组合串长度", g_last_bytes_size, 2);
    expect_int("update 带的是注入的串",
               text != 0 && text[0] == 'n' && text[1] == 'i', 1);

    moonui_ime_on_changed(ctx, wa);
    expect_int("同串不重复通知", g_ime_calls, 2);

    strcpy(g_mock_ime_preedit, "nih");
    moonui_ime_on_changed(ctx, wa);
    expect_int("新串再通知", g_ime_calls, 3);
    moonui_native_ime_text();
    expect_int("新串长度", g_last_bytes_size, 3);

    strcpy(g_mock_ime_preedit, "");
    moonui_ime_on_changed(ctx, wa);
    expect_int("空串结束通知", g_ime_calls, 4);
    expect_int("空串相位 2", moonui_native_ime_phase(), 2);
    moonui_native_ime_text();
    expect_int("结束不带串", g_last_bytes_size, 0);

    /* changed 先于 start：补发 start 再发 update。 */
    strcpy(g_mock_ime_preedit, "hao");
    moonui_ime_on_changed(ctx, wa);
    expect_int("无 start 时补发两条", g_ime_calls, 6);
    expect_int("补发后停在相位 1", moonui_native_ime_phase(), 1);

    /* commit 收尾：只发一次 end。 */
    moonui_ime_on_commit(ctx, "hao", wa);
    expect_int("commit 发结束", g_ime_calls, 7);
    expect_int("commit 后相位 2", moonui_native_ime_phase(), 2);
    moonui_ime_on_end(ctx, wa);
    expect_int("已结束再收尾不重复", g_ime_calls, 7);

    /* 换控件：相位从头开始，target 跟着换。 */
    moonui_ime_on_start(ctx, wb);
    expect_int("换控件后 target 跟着换",
               (long long)moonui_native_ime_target(), (long long)(moonui_ptr)wb);
    expect_int("换控件相位回到 0", moonui_native_ime_phase(), 0);

    /* 控件销毁：它的快照被清掉。 */
    moonui_ime_forget(wb);
    expect_int("销毁后 target 归 0", (long long)moonui_native_ime_target(), 0);
    expect_int("销毁后相位归 0", moonui_native_ime_phase(), 0);
    moonui_native_ime_text();
    expect_int("销毁后串清空", g_last_bytes_size, 0);

    /* 别的控件销毁不动这只的快照。 */
    moonui_ime_on_start(ctx, wa);
    strcpy(g_mock_ime_preedit, "x");
    moonui_ime_on_changed(ctx, wa);
    moonui_ime_forget(wb);
    expect_int("别的控件销毁不动 target",
               (long long)moonui_native_ime_target(), (long long)(moonui_ptr)wa);

    moonui_ime_reset_state();
    moonui_ime_drop_listener();
    g_ime_calls = 0;
  }
  if (g_fails == 0) {
    printf("[selftest] OK：%d 项纯逻辑判据全绿\n", g_checks);
    return 0;
  }
  printf("[selftest] 失败：%d / %d 项判据红\n", g_fails, g_checks);
  return 1;
}
