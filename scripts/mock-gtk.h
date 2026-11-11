/* Mock GTK4/GDK headers for local macOS syntax-checking of
 * backends/native-linux/adapter_native_gtk.c. This only verifies the
 * author's OWN C (braces, helpers, pack2 math, undeclared-symbol typos),
 * NOT GTK4 API correctness — that is checked on Linux (CI linux-backend-link).
 *
 * 用法见 scripts/mock-gtk-check.sh。本文件刻意只声明 GTK4 的"形状"，不验证
 * 真实签名：GTK4 的真实编译 / 链接 / xvfb 真窗只发生在 Linux 真机。 */
#ifndef MOCK_GTK_H
#define MOCK_GTK_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

typedef int gboolean;
typedef unsigned int guint;
typedef int gint;
typedef char gchar;
typedef long long gint64;
typedef unsigned long long guint64;
typedef double gdouble;
typedef void (*GCallback)(void);
typedef void *gpointer;
typedef unsigned int GdkModifierType;
#ifndef TRUE
#define TRUE 1
#endif
#ifndef FALSE
#define FALSE 0
#endif

/* NOTE: moonui_ptr / moonui_closure_fn / moonbit_bytes_t and the moonbit_*
 * runtime are provided by adapter.h (via moonbit.h) — do NOT redefine here. */

/* Opaque object types */
typedef struct _GtkWidget GtkWidget;
typedef struct _GtkWindow GtkWindow;
typedef struct _GtkNative GtkNative;
typedef struct _GtkFixed GtkFixed;
typedef struct _GtkOverlay GtkOverlay;
typedef struct _GtkBox GtkBox;
typedef struct _GtkDrawingArea GtkDrawingArea;
typedef struct _GtkEventController GtkEventController;
typedef struct _GtkEventControllerKey GtkEventControllerKey;
typedef struct _GtkEventControllerMotion GtkEventControllerMotion;
typedef struct _GtkEventControllerScroll GtkEventControllerScroll;
typedef struct _GtkGesture GtkGesture;
typedef struct _GtkGestureClick GtkGestureClick;
typedef struct _GtkGestureZoom GtkGestureZoom;
typedef struct _GtkGestureRotate GtkGestureRotate;
typedef struct _GtkGestureSwipe GtkGestureSwipe;
typedef struct _GdkEvent GdkEvent;
typedef struct _GdkSurface GdkSurface;
typedef struct _GdkDisplay GdkDisplay;
typedef struct _GMainContext GMainContext;

/* Modifier / button masks（取值对齐真实 GDK 的位序，这样 mock 里跑出来的
 * 位运算语义与 Linux 上一致：SHIFT=1<<0、CONTROL=1<<2、ALT(MOD1)=1<<3、
 * SUPER(MOD4)=1<<6、BUTTON1..5=1<<8..1<<12）。 */
#define GDK_SHIFT_MASK   ((GdkModifierType)1)
#define GDK_LOCK_MASK    ((GdkModifierType)2)
#define GDK_CONTROL_MASK ((GdkModifierType)4)
#define GDK_ALT_MASK     ((GdkModifierType)8)
#define GDK_SUPER_MASK   ((GdkModifierType)64)
#define GDK_META_MASK    ((GdkModifierType)268435456)
#define GDK_BUTTON1_MASK ((GdkModifierType)256)
#define GDK_BUTTON2_MASK ((GdkModifierType)512)
#define GDK_BUTTON3_MASK ((GdkModifierType)1024)
#define GDK_BUTTON4_MASK ((GdkModifierType)2048)
#define GDK_BUTTON5_MASK ((GdkModifierType)4096)

/* Macros */
#define GTK_WINDOW(x) ((GtkWindow *)(x))
#define GTK_WIDGET(x) ((GtkWidget *)(x))
#define GTK_FIXED(x) ((GtkFixed *)(x))
#define GTK_OVERLAY(x) ((GtkOverlay *)(x))
#define GTK_BOX(x) ((GtkBox *)(x))
#define GTK_EVENT_CONTROLLER(x) ((GtkEventController *)(x))
#define GTK_NATIVE(x) ((GtkNative *)(x))
#define G_CALLBACK(x) ((GCallback)(x))
#define GTK_PHASE_BUBBLE 1
#define GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES 1
#define G_PI 3.14159265358979323846

/* 枚举：取值对齐真实 GTK4（GTK_ALIGN_FILL = 0、GTK_ORIENTATION_HORIZONTAL = 0、
 * GTK_PICK_DEFAULT = 0）。mock 里这些值不影响判据，但对齐了才能保证"两个分支
 * 真的走到不同代码"这类判据在 mock 与真机上是同一个意思。 */
typedef int GtkAlign;
typedef int GtkOrientation;
typedef int GtkPickFlags;
#define GTK_ALIGN_FILL 0
#define GTK_ALIGN_START 1
#define GTK_ALIGN_END 2
#define GTK_ALIGN_CENTER 3
#define GTK_ORIENTATION_HORIZONTAL 0
#define GTK_ORIENTATION_VERTICAL 1
#define GTK_PICK_DEFAULT 0
#define GTK_PICK_NON_TARGETABLE 1

/* 对话框的 response id（真值，见 GTK 的 gtkdialog.h）。P6-3 的 mapped 函数
 * moonui_dialog_confirm_result 直接比较这些常量，所以假头里必须有，且值要与
 * 真 GTK 一致——否则"点'是'返回 1"这条判据在 mock 里验的是另一个数。 */
#define GTK_RESPONSE_NONE (-1)
#define GTK_RESPONSE_ACCEPT (-3)
#define GTK_RESPONSE_DELETE_EVENT (-4)
#define GTK_RESPONSE_OK (-5)
#define GTK_RESPONSE_CANCEL (-6)
#define GTK_RESPONSE_REJECT (-7)
#define GTK_RESPONSE_YES (-8)
#define GTK_RESPONSE_NO (-9)

/* GTK declarations (best-guess signatures; mock only checks author's C) */
void gtk_init(void);
gboolean gtk_init_check(void);
gboolean gtk_events_pending(void);
gboolean gtk_main_iteration_do(gboolean blocking);
gboolean g_main_context_iteration(GMainContext *ctx, gboolean blocking);
gboolean g_main_context_pending(GMainContext *ctx);
/* T235 P6-12：worker_run 的落地走 idle 源（真 glib 里排在默认主上下文，
 * 事件循环每圈取走一次）；自检要能记下"投了什么"再由测试手动泵。 */
typedef gboolean (*GSourceFunc)(gpointer data);
guint g_idle_add(GSourceFunc function, gpointer data);
gint64 g_get_monotonic_time(void);
void g_usleep(guint64 microseconds);
/* GLib 的应用名（T235 P6-8）：set_app_name 真实现只调这一条。 */
void g_set_application_name(const char *name);

GtkWidget *gtk_window_new(void);
void gtk_window_set_title(GtkWindow *w, const char *t);
void gtk_window_set_default_size(GtkWindow *w, int width, int height);
void gtk_widget_set_visible(GtkWidget *w, gboolean visible);
void gtk_widget_set_size_request(GtkWidget *w, int width, int height);
void gtk_window_present(GtkWindow *w);
void gtk_window_resize(GtkWindow *w, int width, int height);
void gtk_window_get_default_size(GtkWindow *w, int *width, int *height);
void gtk_window_destroy(GtkWindow *w);
void gtk_widget_hide(GtkWidget *w);
void gtk_widget_add_controller(GtkWidget *w, GtkEventController *c);
int gtk_widget_get_scale_factor(GtkWidget *w);
int gtk_widget_get_width(GtkWidget *w);
int gtk_widget_get_height(GtkWidget *w);
GtkWidget *gtk_event_controller_get_widget(GtkEventController *c);
GdkEvent *gtk_event_controller_get_current_event(GtkEventController *c);

GdkModifierType gdk_event_get_modifier_state(GdkEvent *e);
guint gdk_button_event_get_button(GdkEvent *e);
const char *gdk_keyval_name(guint keyval);

GdkSurface *gtk_native_get_surface(GtkNative *n);
int gdk_surface_get_scale_factor(GdkSurface *s);
GdkDisplay *gdk_display_get_default(void);
int gdk_display_get_scale_factor(GdkDisplay *d);

GtkEventController *gtk_event_controller_key_new(void);
GtkEventController *gtk_event_controller_motion_new(void);
GtkEventController *gtk_event_controller_scroll_new(int flags);

GtkGesture *gtk_gesture_click_new(void);
GtkGesture *gtk_gesture_zoom_new(void);
GtkGesture *gtk_gesture_rotate_new(void);
GtkGesture *gtk_gesture_swipe_new(void);

void g_signal_connect(void *instance, const char *detailed_signal, GCallback c_handler, void *data);

/* ---- 控件挂载层（T235 P6-1）会用到的那批 ----
 * 只声明形状。**其中 gtk_widget_get_parent / get_first_child / get_next_sibling /
 * pick 是真的在 mock 构建里被调用的**（控件登记表 / 命中反查 / z 序），所以
 * scripts/mock-gtk-selftest.c 里给了够用的假实现（构建一棵假 widget 树），
 * 那几条判据是**真跑**的，不只是编译过。其余只有真机才走得到。 */
GtkWidget *gtk_window_get_child(GtkWindow *w);
void gtk_window_set_child(GtkWindow *w, GtkWidget *child);
/* P6-5b 焦点链：prelude 的 moonui_gtk_focus_tab_step 在假头构建里也会编译，
 * 且第 13 组判据用 mock 的替身真跑它（scripts/mock-gtk-selftest.c）。 */
GtkWidget *gtk_window_get_focus(GtkWindow *w);
void gtk_widget_grab_focus(GtkWidget *w);

GtkWidget *gtk_fixed_new(void);
void gtk_fixed_put(GtkFixed *f, GtkWidget *w, double x, double y);
void gtk_fixed_move(GtkFixed *f, GtkWidget *w, double x, double y);
void gtk_fixed_remove(GtkFixed *f, GtkWidget *w);
void gtk_fixed_get_child_position(GtkFixed *f, GtkWidget *w, double *x, double *y);

GtkWidget *gtk_overlay_new(void);
void gtk_overlay_set_child(GtkOverlay *o, GtkWidget *child);
GtkWidget *gtk_overlay_get_child(GtkOverlay *o);
void gtk_overlay_add_overlay(GtkOverlay *o, GtkWidget *child);

GtkWidget *gtk_drawing_area_new(void);

/* 菜单栏容器（T235 P6-4）：装了菜单栏的窗口，内容从 overlay 换成
 * GtkBox[menubar, overlay]。假头只声明形状——这几只在 mock 构建里不被调用
 * （窗口容器那几条判据走 canvas-pixel-check.sh 的真 GTK），只为让 prelude 编得过。 */
GtkWidget *gtk_box_new(GtkOrientation orientation, int spacing);
void gtk_box_append(GtkBox *box, GtkWidget *child);
void gtk_box_prepend(GtkBox *box, GtkWidget *child);
void gtk_box_remove(GtkBox *box, GtkWidget *child);

GtkWidget *gtk_widget_get_parent(GtkWidget *w);
GtkWidget *gtk_widget_get_first_child(GtkWidget *w);
GtkWidget *gtk_widget_get_next_sibling(GtkWidget *w);
GtkWidget *gtk_widget_pick(GtkWidget *w, double x, double y, GtkPickFlags flags);
void gtk_widget_unparent(GtkWidget *w);
void gtk_widget_set_can_target(GtkWidget *w, gboolean can_target);
void gtk_widget_set_halign(GtkWidget *w, GtkAlign align);
void gtk_widget_set_valign(GtkWidget *w, GtkAlign align);
void gtk_widget_set_hexpand(GtkWidget *w, gboolean expand);
void gtk_widget_set_vexpand(GtkWidget *w, gboolean expand);
void gtk_widget_set_opacity(GtkWidget *w, double opacity);
gboolean gtk_widget_get_visible(GtkWidget *w);
gboolean gtk_widget_get_sensitive(GtkWidget *w);
void gtk_widget_set_sensitive(GtkWidget *w, gboolean sensitive);
void gtk_widget_measure(GtkWidget *w, GtkOrientation orientation, int for_size,
                        int *minimum, int *natural, int *minimum_baseline,
                        int *natural_baseline);

void *g_object_ref(void *o);
void *g_object_ref_sink(void *o);
void g_object_unref(void *o);

/* ---- P6-5c 七构造族用到的 GTK4 形状（只声明；真链接 / 真窗在 Linux 真机）----
 * mock 闸以 -Wl,-undefined,dynamic_lookup 链接，这些符号不必有定义（mock 真跑
 * 的纯逻辑判据不创建 GTK 控件，只调 prelude 的 parse_datetime）。这里只让适配器
 * 编得过 + 链接得过。 */
typedef struct _GtkScale GtkScale;
typedef struct _GtkRange GtkRange;
typedef struct _GtkSpinButton GtkSpinButton;
typedef struct _GtkProgressBar GtkProgressBar;
typedef struct _GtkDropDown GtkDropDown;
typedef struct _GtkStringList GtkStringList;
typedef struct _GListModel GListModel;
typedef struct _GtkTextView GtkTextView;
typedef struct _GtkTextBuffer GtkTextBuffer;
typedef struct _GtkCheckButton GtkCheckButton;
typedef struct _GtkCalendar GtkCalendar;
typedef struct _GDateTime GDateTime;

#define GTK_SCALE(x) ((GtkScale *)(x))
#define GTK_RANGE(x) ((GtkRange *)(x))
#define GTK_SPIN_BUTTON(x) ((GtkSpinButton *)(x))
#define GTK_PROGRESS_BAR(x) ((GtkProgressBar *)(x))
#define GTK_DROP_DOWN(x) ((GtkDropDown *)(x))
#define GTK_STRING_LIST(x) ((GtkStringList *)(x))
#define GTK_TEXT_VIEW(x) ((GtkTextView *)(x))
#define GTK_TEXT_BUFFER(x) ((GtkTextBuffer *)(x))
#define GTK_CHECK_BUTTON(x) ((GtkCheckButton *)(x))
#define GTK_CALENDAR(x) ((GtkCalendar *)(x))
#define GTK_IS_RANGE(x) (1)
#define GTK_IS_SPIN_BUTTON(x) (1)
#define GTK_IS_PROGRESS_BAR(x) (1)
#define GTK_IS_DROP_DOWN(x) (1)
#define GTK_IS_STRING_LIST(x) (1)
#define GTK_IS_TEXT_VIEW(x) (1)
#define GTK_IS_TEXT_BUFFER(x) (1)
#define GTK_IS_CHECK_BUTTON(x) (1)
#define GTK_IS_CALENDAR(x) (1)
#define GTK_INVALID_LIST_POSITION ((guint)4294967295U)

GtkWidget *gtk_scale_new_with_range(GtkOrientation orientation, double min, double max, double step);
void gtk_range_set_range(GtkRange *r, double min, double max);
void gtk_range_set_value(GtkRange *r, double v);
double gtk_range_get_value(GtkRange *r);
GtkWidget *gtk_spin_button_new_with_range(double min, double max, double step);
void gtk_spin_button_set_value(GtkSpinButton *b, double v);
int gtk_spin_button_get_value_as_int(GtkSpinButton *b);
void gtk_spin_button_set_range(GtkSpinButton *b, double min, double max);
GtkWidget *gtk_progress_bar_new(void);
void gtk_progress_bar_set_fraction(GtkProgressBar *p, double f);
double gtk_progress_bar_get_fraction(GtkProgressBar *p);
void gtk_progress_bar_pulse(GtkProgressBar *p);
GtkWidget *gtk_drop_down_new(GListModel *model, gpointer item);
GListModel *gtk_drop_down_get_model(GtkDropDown *d);
guint gtk_drop_down_get_selected(GtkDropDown *d);
void gtk_drop_down_set_selected(GtkDropDown *d, guint pos);
GtkStringList *gtk_string_list_new(gpointer items);
void gtk_string_list_append(GtkStringList *list, const char *str);
GtkWidget *gtk_text_view_new(void);
GtkTextBuffer *gtk_text_view_get_buffer(GtkTextView *v);
void gtk_text_buffer_set_text(GtkTextBuffer *buf, const char *text, int len);
char *gtk_text_buffer_get_text(GtkTextBuffer *buf, gpointer start, gpointer end, gboolean hidden);
void gtk_text_buffer_get_bounds(GtkTextBuffer *buf, gpointer start, gpointer end);
GtkWidget *gtk_check_button_new_with_label(const char *label);
void gtk_check_button_set_group(GtkCheckButton *b, GtkCheckButton *group);
gboolean gtk_check_button_get_active(GtkCheckButton *b);
void gtk_check_button_set_active(GtkCheckButton *b, gboolean active);
GtkWidget *gtk_calendar_new(void);
GDateTime *gtk_calendar_get_date(GtkCalendar *c);
void gtk_calendar_select_day(GtkCalendar *c, GDateTime *dt);
GDateTime *g_date_time_new_local(int y, int mo, int d, int h, int mi, double s);
int g_date_time_get_year(GDateTime *dt);
int g_date_time_get_month(GDateTime *dt);
int g_date_time_get_day_of_month(GDateTime *dt);
int g_date_time_get_hour(GDateTime *dt);
int g_date_time_get_minute(GDateTime *dt);
int g_date_time_get_second(GDateTime *dt);
char *g_date_time_format(GDateTime *dt, const char *fmt);
void g_date_time_unref(GDateTime *dt);
void gtk_widget_set_margin_top(GtkWidget *w, int m);
void gtk_widget_set_margin_end(GtkWidget *w, int m);
void gtk_widget_set_margin_bottom(GtkWidget *w, int m);
void gtk_widget_set_margin_start(GtkWidget *w, int m);

/* ---- T241：display 的默认 scale（gtk_init 之后就有，不依赖 surface）----
 * 真头里这四个是 GDK / GIO 的公开 API；假头只声明形状，运行时由
 * mock-gtk-selftest.c 注入「有没有 display / 列表几项 / 首项 scale」，
 * 好让 1x 的 CI 也能验 moonui_scale_of(NULL) 不是硬编码 1。
 * 声明放在这里是因为 GListModel 的 typedef 在上面 P6-5c 那一节。 */
typedef struct _GdkMonitor GdkMonitor;
GListModel *gdk_display_get_monitors(GdkDisplay *d);
guint g_list_model_get_n_items(GListModel *model);
gpointer g_list_model_get_item(GListModel *model, guint position);
int gdk_monitor_get_scale_factor(GdkMonitor *m);

/* ---- T251：输入法组合相位的旁听接线 ----
 * 真头里这几条都是 GTK 4.0 起 / glib 2.44 起的公开 API；假头只声明形状，取口
 * 与相位机由 mock-gtk-selftest.c 第 23 组用可注入的替身真跑。
 * GTK_IS_EDITABLE 在假头恒真：attach 的「经 delegate 取内部 GtkText」那条分支
 * 由 selftest 的 gtk_editable_get_delegate 返回 NULL 走回 w 自己。 */
typedef struct _GtkEditable GtkEditable;
typedef struct _GtkIMContext GtkIMContext;
#define GTK_EDITABLE(x) ((GtkEditable *)(x))
#define GTK_IS_EDITABLE(x) (1)
#define GTK_IS_EVENT_CONTROLLER_KEY(x) (1)
#define GTK_EVENT_CONTROLLER_KEY(x) ((GtkEventControllerKey *)(x))
GtkEditable *gtk_editable_get_delegate(GtkEditable *e);
GListModel *gtk_widget_observe_controllers(GtkWidget *w);
GtkIMContext *gtk_event_controller_key_get_im_context(GtkEventControllerKey *c);
void gtk_im_context_get_preedit_string(GtkIMContext *ctx, char **str, gpointer attrs, int *cursor_pos);

/* ---- T235 P6-9：图像源两条用到的形状 ----
 * 这两条在 REAL 段，假头构建里也**真跑**（scripts/mock-gtk-selftest.c 第 18 组）：
 * 解码结果 / GError 释放 / 纹理与 GBytes 的引用配对都靠 selftest 里的替身记账。
 * gsize 按 glib 的口径给（LP64 上是 unsigned long，用 size_t 编得过且同宽）。 */
typedef struct _GtkPicture GtkPicture;
typedef struct _GdkTexture GdkTexture;
typedef struct _GdkPaintable GdkPaintable;
typedef struct _GBytes GBytes;
typedef struct _GError GError;
typedef size_t gsize;

#define GTK_PICTURE(x) ((GtkPicture *)(x))
#define GDK_PAINTABLE(x) ((GdkPaintable *)(x))

GtkWidget *gtk_picture_new(void);
void gtk_picture_set_paintable(GtkPicture *p, GdkPaintable *paintable);
void gtk_picture_set_can_shrink(GtkPicture *p, gboolean can_shrink);
GdkTexture *gdk_texture_new_from_filename(const char *filename, GError **error);
GdkTexture *gdk_texture_new_from_bytes(GBytes *bytes, GError **error);
GBytes *g_bytes_new(const void *data, gsize size);
void g_bytes_unref(GBytes *bytes);
void g_error_free(GError *error);

/* ---- T235 P6-10：文件拖入用到的形状 ----
 * 这三条在 REAL 段与 prelude，假头构建里也编译；编码布局 / 读回 / 单槽语义
 * 由 mock-gtk-selftest.c 第 19 组真跑。GTK 侧的 "drop" 分发只在真头构建里
 * 发生（canvas-pixel 闸用真 GdkFileList 驱动），假头只声明形状，不实现。 */
typedef unsigned long GType;
typedef int GdkDragAction;
typedef struct _GtkDropTarget GtkDropTarget;
typedef struct _GdkFileList GdkFileList;
typedef struct _GFile GFile;
typedef struct _GValue GValue;
typedef struct _GSList GSList;
struct _GSList {
  gpointer data;
  GSList *next;
};

#define GDK_TYPE_FILE_LIST ((GType)0)
#define GDK_ACTION_COPY 1

GtkDropTarget *gtk_drop_target_new(GType type, GdkDragAction actions);
gpointer g_value_get_boxed(const GValue *value);
GSList *gdk_file_list_get_files(GdkFileList *file_list);
char *g_file_get_path(GFile *file);
void g_free(gpointer mem);

#endif /* MOCK_GTK_H */
