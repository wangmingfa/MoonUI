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
gint64 g_get_monotonic_time(void);
void g_usleep(guint64 microseconds);

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

#endif /* MOCK_GTK_H */
