/*
 * MoonUI 原生后端 · Linux / GTK4 · 画布（Cairo 光栅）——T235 P4。
 *
 * 本文件被 adapter_native_gtk.c 用 #include 收进**同一个翻译单元**（所以能看见
 * 那边的 static 状态，也不新增 prebuild 的编译单元）。生成器扫描本文件里定义的
 * moonui_* 符号并从"桩"里剔除，两边不会重定义。
 *
 * 与 mac 半（adapter_native.m 画布段）的分工完全对应，一眼可以并排看：
 *
 *   mac                                 这里
 *   --------------------------------    --------------------------------
 *   CGBitmapContext + malloc RGBA 缓冲   cairo_image_surface（ARGB32）+ cairo_t
 *   同一条绘制 API，read_pixel 读缓冲     同一套 ABI，read_pixel 读表面数据
 *   present → 位图贴 layer.contents      present → GtkDrawingArea 的 draw func
 *
 * 口径（与 adapter.h 画布段逐条对齐，别在这里改）：
 *   - 坐标/尺寸一律**物理像素**；cairo 的原生坐标就是左上原点、y 向下，与 ABI
 *     完全同向，所以这里**不像 mac 那样翻 CTM**（CG 是左下原点才要翻）。
 *     凡涉及 y 的公式都与 mac 那份字面一致，不是巧合；
 *   - 颜色 0xRRGGBB 打包进 int64、alpha 独立 0..255（预乘由 cairo 自己算）；
 *   - permille = 逻辑值 × 1000（radius / blur / font / 线宽同此）；
 *   - 返回码：0 成功、-1 参数错或没有帧/平台没上屏目标。
 *
 * 位图格式：cairo 的 CAIRO_FORMAT_ARGB32 是**预乘**、按宿主字节序排的 32 位，
 * 与 mac 那份"预乘 RGBA、R 在第 0 字节"不同。凡是直接摸像素的地方
 * （read_pixel / blur / 贴图）一律按 32 位整数取（0xAARRGGBB），不按字节序取，
 * 这样大小端都对；只有"逐通道模糊"那处按 4 字节一组处理，因为模糊与通道顺序无关。
 */

#ifndef MOONUI_MOCK_GTK /* 假头（scripts/mock-gtk.h）不带 cairo/pango/pixbuf，见 mock-gtk-check.sh */
#include <cairo.h>
#include <pango/pangocairo.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gio/gio.h>
#endif

#define MOONUI_CANVAS_AREAS 32

typedef struct MoonuiCanvasGtk MoonuiCanvasGtk;
typedef struct MoonuiCanvasArea {
  GtkWidget *area;
  MoonuiCanvasGtk *canvas;
} MoonuiCanvasArea;

struct MoonuiCanvasGtk {
  cairo_surface_t *surface; /* ARGB32 图像表面；begin_frame 之前为 NULL */
  cairo_t *cr;              /* 绑在 surface 上的绘制上下文 */
  uint8_t *data;            /* 表面像素基址（读像素/模糊要直接摸） */
  int w, h, stride;
  /* 上屏目标：attach_window 记的窗口；area 是我们自己往窗口里塞的绘制面。 */
  GtkWidget *window;
  GtkWidget *area;
  /* 投影是**状态**（adapter.h）：设了之后所有填充都带影，save/restore 出界或
   * 再调一次 blur<=0 清零。开帧时归零（与 CG 新建 context 无影同构）。 */
  int shadow_on;
  int shadow_dx, shadow_dy, shadow_blur;
  int64_t shadow_rgb;
};

/* 上屏面登记表：present_view 会把画布挂到别人的绘制面上。画布销毁时要把这些
 * 引用逐一摘掉——不然那块面的 draw func 拿着一个已 free 的指针（`T110` 那条
 * "身份登记表要跟销毁同步销账"的同一课）。 */
static MoonuiCanvasArea moonui_canvas_areas[MOONUI_CANVAS_AREAS];

static MoonuiCanvasGtk *moonui_canvas_gtk_of(moonui_ptr p) {
  if (p == 0) {
    return NULL;
  }
  /* 与 mac 的 moonui_canvas_of 同一个口径：不做"是不是画布"的核验。 */
  return (MoonuiCanvasGtk *)(uintptr_t)p;
}

/* ---- 颜色 / 路径 ---- */

/* 颜色下发：rgb 是 0xRRGGBB，alpha 0..255。cairo 自己按目标格式预乘。 */
static void moonui_gtk_set_rgb(cairo_t *cr, int64_t rgb, int alpha) {
  double a = (double)alpha / 255.0;
  if (a < 0.0) {
    a = 0.0;
  }
  if (a > 1.0) {
    a = 1.0;
  }
  cairo_set_source_rgba(cr, (double)((rgb >> 16) & 0xFF) / 255.0,
                        (double)((rgb >> 8) & 0xFF) / 255.0,
                        (double)(rgb & 0xFF) / 255.0, a);
}

typedef struct MoonuiGtkRectPath {
  double x, y, w, h, r;
} MoonuiGtkRectPath;

/* 圆角矩形路径。半径按 mac 那份夹：负数当 0、上限 min(w,h)/2、小于 0.5 走直角。
 * 正圆（半径 = 半宽半高，滑条拇指）单独走一条整圆：四段弧拼出来在接点留抗锯齿
 * 缝（`T101` 那轮在 CG 上实测过，cairo 上同理）。 */
static void moonui_gtk_path_rect(cairo_t *cr, const void *arg) {
  const MoonuiGtkRectPath *a = (const MoonuiGtkRectPath *)arg;
  double r = a->r;
  double hw = a->w / 2.0;
  double hh = a->h / 2.0;
  cairo_new_path(cr);
  if (r < 0) {
    r = 0;
  }
  if (r > hw) {
    r = hw;
  }
  if (r > hh) {
    r = hh;
  }
  if (r < 0.5) {
    cairo_rectangle(cr, a->x, a->y, a->w, a->h);
    return;
  }
  if (r >= hw - 0.001 && r >= hh - 0.001) {
    cairo_arc(cr, a->x + hw, a->y + hh, hw < hh ? hw : hh, 0, 2.0 * M_PI);
    cairo_close_path(cr);
    return;
  }
  /* y 向下时角度增大 = 屏幕顺时针，与 ABI 的"0° 三点钟、顺时针为正"同向。 */
  cairo_move_to(cr, a->x + r, a->y);
  cairo_line_to(cr, a->x + a->w - r, a->y);
  cairo_arc(cr, a->x + a->w - r, a->y + r, r, -M_PI / 2.0, 0);
  cairo_line_to(cr, a->x + a->w, a->y + a->h - r);
  cairo_arc(cr, a->x + a->w - r, a->y + a->h - r, r, 0, M_PI / 2.0);
  cairo_line_to(cr, a->x + r, a->y + a->h);
  cairo_arc(cr, a->x + r, a->y + a->h - r, r, M_PI / 2.0, M_PI);
  cairo_line_to(cr, a->x, a->y + r);
  cairo_arc(cr, a->x + r, a->y + r, r, M_PI, 1.5 * M_PI);
  cairo_close_path(cr);
}

typedef struct MoonuiGtkArcPath {
  double cx, cy, r, a0, sweep;
} MoonuiGtkArcPath;

/* 圆弧路径。角度是弧度、起止已由调用方夹好（|sweep| <= 2π）。
 * 负扫角走 cairo_arc_negative：把负 delta 交给 cairo_arc 会被它按"补到起点"
 * 理解，画出来是剩下那一大圈（mac 那份注释里同样的坑，只是那边用采样绕开）。 */
static void moonui_gtk_path_arc(cairo_t *cr, const void *arg) {
  const MoonuiGtkArcPath *a = (const MoonuiGtkArcPath *)arg;
  cairo_new_path(cr);
  if (fabs(a->sweep) >= 2.0 * M_PI - 0.001) {
    cairo_arc(cr, a->cx, a->cy, a->r, 0, 2.0 * M_PI);
    return;
  }
  if (a->sweep >= 0) {
    cairo_arc(cr, a->cx, a->cy, a->r, a->a0, a->a0 + a->sweep);
  } else {
    cairo_arc_negative(cr, a->cx, a->cy, a->r, a->a0, a->a0 + a->sweep);
  }
}

typedef struct MoonuiGtkPolyPath {
  const int32_t *pts;
  int n;
} MoonuiGtkPolyPath;

/* 闭合多边形。首尾自动相连（adapter.h：调用方不必重复首点）；填充规则用 cairo
 * 默认的 nonzero winding，与 mac 的 kCGPathFill 同一档——even-odd 会把自交的
 * 面积图挖出洞来。 */
static void moonui_gtk_path_poly(cairo_t *cr, const void *arg) {
  const MoonuiGtkPolyPath *a = (const MoonuiGtkPolyPath *)arg;
  int i;
  cairo_new_path(cr);
  if (a->n <= 0) {
    return;
  }
  cairo_move_to(cr, (double)a->pts[0], (double)a->pts[1]);
  for (i = 1; i < a->n; i++) {
    cairo_line_to(cr, (double)a->pts[i * 2], (double)a->pts[i * 2 + 1]);
  }
  cairo_close_path(cr);
}

/* ---- 盒式模糊（毛玻璃与投影共用）----
 * 三次盒式模糊的 running-sum 版本：O(W·H)，与半径无关（mac 那份 blur_region 的
 * 同一套算法，只是这边按"任意子矩形 + 任意跨距"参数化）。三遍之后近似高斯。
 * 直接动像素，调用方负责 cairo_surface_flush / mark_dirty。 */
static void moonui_gtk_box_blur(uint8_t *base, int stride, int x0, int y0, int w,
                                int h, int r) {
  uint8_t *src;
  uint8_t *dst;
  int win;
  int i, j, k;
  if (r <= 0 || w <= 0 || h <= 0) {
    return;
  }
  win = 2 * r + 1;
  src = (uint8_t *)calloc((size_t)w * (size_t)h * 4, 1);
  dst = (uint8_t *)calloc((size_t)w * (size_t)h * 4, 1);
  if (src == NULL || dst == NULL) {
    free(src);
    free(dst);
    return;
  }
  /* 先把子矩形抠进 src（行跨距可能与 w*4 不同）。 */
  for (j = 0; j < h; j++) {
    memcpy(src + (size_t)j * (size_t)w * 4,
           base + (size_t)(y0 + j) * (size_t)stride + (size_t)x0 * 4,
           (size_t)w * 4);
  }
  for (k = 0; k < 3; k++) {
    /* 每一遍都是「水平 src→dst，再垂直 dst→src」，所以每遍**结束时结果都在
     * src**。别写成"in/out 按 k 奇偶交替"：那样第二遍会从上一遍的**中间结果**
     * （水平糊完、还没垂直糊的那份）起算，糊出来是错的。2026-11-08 实测症状：
     * 横线模糊后纹丝不动、矩形阴影歪成斜块——只在跨行读写时才看得出来。 */
    uint8_t *in = src;
    uint8_t *out = dst;
    for (j = 0; j < h; j++) {
      int64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
      for (i = 0; i < w; i++) {
        int ri = i + r;
        if (ri >= w) {
          ri = w - 1;
        }
        s0 += in[(size_t)(j * w + ri) * 4 + 0];
        s1 += in[(size_t)(j * w + ri) * 4 + 1];
        s2 += in[(size_t)(j * w + ri) * 4 + 2];
        s3 += in[(size_t)(j * w + ri) * 4 + 3];
        if (i - win >= 0) {
          int li = i - win;
          s0 -= in[(size_t)(j * w + li) * 4 + 0];
          s1 -= in[(size_t)(j * w + li) * 4 + 1];
          s2 -= in[(size_t)(j * w + li) * 4 + 2];
          s3 -= in[(size_t)(j * w + li) * 4 + 3];
        }
        out[(size_t)(j * w + i) * 4 + 0] = (uint8_t)(s0 / win);
        out[(size_t)(j * w + i) * 4 + 1] = (uint8_t)(s1 / win);
        out[(size_t)(j * w + i) * 4 + 2] = (uint8_t)(s2 / win);
        out[(size_t)(j * w + i) * 4 + 3] = (uint8_t)(s3 / win);
      }
    }
    for (i = 0; i < w; i++) {
      int64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
      for (j = 0; j < h; j++) {
        int rj = j + r;
        if (rj >= h) {
          rj = h - 1;
        }
        s0 += out[(size_t)(rj * w + i) * 4 + 0];
        s1 += out[(size_t)(rj * w + i) * 4 + 1];
        s2 += out[(size_t)(rj * w + i) * 4 + 2];
        s3 += out[(size_t)(rj * w + i) * 4 + 3];
        if (j - win >= 0) {
          int lj = j - win;
          s0 -= out[(size_t)(lj * w + i) * 4 + 0];
          s1 -= out[(size_t)(lj * w + i) * 4 + 1];
          s2 -= out[(size_t)(lj * w + i) * 4 + 2];
          s3 -= out[(size_t)(lj * w + i) * 4 + 3];
        }
        in[(size_t)(j * w + i) * 4 + 0] = (uint8_t)(s0 / win);
        in[(size_t)(j * w + i) * 4 + 1] = (uint8_t)(s1 / win);
        in[(size_t)(j * w + i) * 4 + 2] = (uint8_t)(s2 / win);
        in[(size_t)(j * w + i) * 4 + 3] = (uint8_t)(s3 / win);
      }
    }
  }
  /* 三遍落在 src，写回子矩形。 */
  for (j = 0; j < h; j++) {
    memcpy(base + (size_t)(y0 + j) * (size_t)stride + (size_t)x0 * 4,
           src + (size_t)j * (size_t)w * 4, (size_t)w * 4);
  }
  free(src);
  free(dst);
}

/* 整张表面模糊（投影用）：radius 是设备像素。 */
static void moonui_gtk_blur_surface(cairo_surface_t *s, int radius) {
  int w, h, stride;
  uint8_t *data;
  if (s == NULL || radius <= 0) {
    return;
  }
  if (cairo_surface_status(s) != CAIRO_STATUS_SUCCESS) {
    return;
  }
  cairo_surface_flush(s);
  data = cairo_image_surface_get_data(s);
  if (data == NULL) {
    return;
  }
  stride = cairo_image_surface_get_stride(s);
  w = cairo_image_surface_get_width(s);
  h = cairo_image_surface_get_height(s);
  moonui_gtk_box_blur(data, stride, 0, 0, w, h, radius);
  cairo_surface_mark_dirty(s);
}

/* 带投影的一次填充：先把同一个路径画进临时表面、糊一遍、按 (dx,dy) 合成上来，
 * 再画本体。CG 的 SetShadowWithColor 是引擎级的事，cairo 没有对等物，只能这么
 * 摊开做——代价是投影开着时每次填充多一张表面，**默认关着**所以不在热路径上。
 * 模糊半径取 shadow_blur/2：CG 的 blur 参数是"模糊半径"，三次盒式每遍半径 r
 * 的合成 σ 约等于 r/2 那个量级，取一半是让观感接近，不追求逐像素相同（判据
 * 只断言"有影/没影/影在偏移那一侧"，不验衰减曲线）。 */
static void moonui_gtk_fill_path(MoonuiCanvasGtk *c, void (*path)(cairo_t *, const void *),
                                 const void *arg, int64_t rgb, int alpha) {
  int r;
  if (c->shadow_on) {
    cairo_surface_t *tmp =
        cairo_image_surface_create(CAIRO_FORMAT_ARGB32, c->w, c->h);
    if (cairo_surface_status(tmp) == CAIRO_STATUS_SUCCESS) {
      cairo_t *tc = cairo_create(tmp);
      if (cairo_status(tc) == CAIRO_STATUS_SUCCESS) {
        path(tc, arg);
        moonui_gtk_set_rgb(tc, c->shadow_rgb, 255);
        cairo_fill(tc);
      }
      cairo_destroy(tc);
      r = c->shadow_blur / 2;
      if (r < 1) {
        r = 1;
      }
      moonui_gtk_blur_surface(tmp, r);
      cairo_set_source_surface(c->cr, tmp, (double)c->shadow_dx,
                              (double)c->shadow_dy);
      cairo_paint(c->cr);
    }
    cairo_surface_destroy(tmp);
  }
  path(c->cr, arg);
  moonui_gtk_set_rgb(c->cr, rgb, alpha);
  cairo_fill(c->cr);
}

/* ---- 画布生命周期 ---- */

int moonui_canvas_backend_of(moonui_ptr canvas) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  if (c == NULL) {
    return -1;
  }
  /* Linux 只有一个光栅后端（cairo/pixman），没有 mac 那种 CG/Metal 二选一，
   * 所以恒报 AUTO。Core 侧 render_backend_of_code(0) 落到 Auto，不会误判成
   * "用户显式选了 CoreGraphics"。 */
  return 0;
}

moonui_ptr moonui_canvas_create(void) {
  MoonuiCanvasGtk *c = (MoonuiCanvasGtk *)calloc(1, sizeof(MoonuiCanvasGtk));
  if (c == NULL) {
    return 0;
  }
  return (moonui_ptr)(uintptr_t)c;
}

int moonui_canvas_destroy(moonui_ptr canvas) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  int i;
  if (c == NULL) {
    return -1;
  }
  /* 先摘上屏面：那块面的 draw func 还拿着这个指针，晚一步就是 use-after-free。 */
  for (i = 0; i < MOONUI_CANVAS_AREAS; i++) {
    if (moonui_canvas_areas[i].canvas == c) {
      if (moonui_canvas_areas[i].area != NULL) {
        gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(moonui_canvas_areas[i].area),
                                       NULL, NULL, NULL);
      }
      moonui_canvas_areas[i].area = NULL;
      moonui_canvas_areas[i].canvas = NULL;
    }
  }
  if (c->cr != NULL) {
    cairo_destroy(c->cr);
  }
  if (c->surface != NULL) {
    cairo_surface_destroy(c->surface);
  }
  free(c);
  return 0;
}

int moonui_canvas_begin_frame(moonui_ptr canvas, int w, int h) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  if (c == NULL || w <= 0 || h <= 0) {
    return -1;
  }
  if (c->cr != NULL) {
    cairo_destroy(c->cr);
    c->cr = NULL;
  }
  if (c->surface != NULL) {
    cairo_surface_destroy(c->surface);
    c->surface = NULL;
  }
  c->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
  if (cairo_surface_status(c->surface) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(c->surface);
    c->surface = NULL;
    return -1;
  }
  c->cr = cairo_create(c->surface);
  if (cairo_status(c->cr) != CAIRO_STATUS_SUCCESS) {
    cairo_destroy(c->cr);
    c->cr = NULL;
    cairo_surface_destroy(c->surface);
    c->surface = NULL;
    return -1;
  }
  /* 开帧即"全透明"。cairo 的新图像表面本来就是全 0（透明黑），不用 paint 一遍；
   * 这里显式写成注释是为了不让后来人以为"忘了清屏"。 */
  c->w = w;
  c->h = h;
  c->stride = cairo_image_surface_get_stride(c->surface);
  c->data = cairo_image_surface_get_data(c->surface);
  /* 投影状态不跨帧（CG 新建 context 也是无影）。 */
  c->shadow_on = 0;
  c->shadow_blur = 0;
  return 0;
}

int moonui_canvas_end_frame(moonui_ptr canvas) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  if (c == NULL || c->surface == NULL) {
    return -1;
  }
  /* 帧就是位图，收帧只做到点确认（与 mac 同一条）。 */
  return 0;
}

/* ---- 上屏（GtkDrawingArea）---- */

static void moonui_gtk_on_area_draw(GtkDrawingArea *area, cairo_t *cr, int width,
                                    int height, gpointer user_data) {
  MoonuiCanvasGtk *c = (MoonuiCanvasGtk *)user_data;
  int sw, sh;
  (void)area;
  if (c == NULL || c->surface == NULL) {
    return;
  }
  sw = cairo_image_surface_get_width(c->surface);
  sh = cairo_image_surface_get_height(c->surface);
  if (sw <= 0 || sh <= 0) {
    return;
  }
  cairo_save(cr);
  /* 位图是**物理像素**、area 的 width/height 是**逻辑像素**（GTK4 的 draw func
   * 按控件坐标给）。按两者之比缩放，等价于 mac 那边把 layer.contentsScale 对齐
   * 到窗口 backing scale：HiDPI 下 1 物理像素 = 1/scale 逻辑点，位图不会被当成
   * "逻辑尺寸的图"缩小到一半。 */
  if (width > 0 && height > 0) {
    cairo_scale(cr, (double)width / (double)sw, (double)height / (double)sh);
  }
  cairo_set_source_surface(cr, c->surface, 0, 0);
  cairo_paint(cr);
  cairo_restore(cr);
}

/* 登记一块上屏面（同一块重复登记只更新 canvas）。 */
static void moonui_gtk_area_register(GtkWidget *area, MoonuiCanvasGtk *canvas) {
  int i;
  int free_slot = -1;
  for (i = 0; i < MOONUI_CANVAS_AREAS; i++) {
    if (moonui_canvas_areas[i].area == area) {
      moonui_canvas_areas[i].canvas = canvas;
      return;
    }
    if (free_slot < 0 && moonui_canvas_areas[i].area == NULL) {
      free_slot = i;
    }
  }
  if (free_slot < 0) {
    return; /* 表满：安静放弃（上屏是可选通道，不该因此让绘制整条失败） */
  }
  moonui_canvas_areas[free_slot].area = area;
  moonui_canvas_areas[free_slot].canvas = canvas;
}

/* 面被销毁时摘表（GtkWidget::destroy）。留着空槽会被下一次登记复用，所以这里
 * 只清内容、不搬动其它槽位。
 *
 * 顺手把画布自己那格 `area` 也清掉：窗口一销毁，GTK 会销毁它的整棵子树，而
 * 画布对象可能比窗口活得久。不清的话，之后一次 present 就会对着已经没了的
 * GtkWidget 调 queue_draw（`T110` 那条"身份登记表要跟销毁同步销账"的同一课）。 */
static void moonui_gtk_on_area_destroy(GtkWidget *area, gpointer user_data) {
  int i;
  (void)user_data;
  for (i = 0; i < MOONUI_CANVAS_AREAS; i++) {
    if (moonui_canvas_areas[i].area == area) {
      MoonuiCanvasGtk *c = moonui_canvas_areas[i].canvas;
      if (c != NULL && c->area == area) {
        c->area = NULL;
      }
      moonui_canvas_areas[i].area = NULL;
      moonui_canvas_areas[i].canvas = NULL;
    }
  }
}

int moonui_canvas_attach_window(moonui_ptr canvas, moonui_ptr window) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  GtkWidget *win = (GtkWidget *)(uintptr_t)window;
  GtkWidget *overlay;
  if (c == NULL || win == NULL) {
    return -1;
  }
  if (c->area == NULL) {
    c->area = gtk_drawing_area_new();
    if (c->area == NULL) {
      return -1;
    }
    gtk_widget_set_hexpand(c->area, TRUE);
    gtk_widget_set_vexpand(c->area, TRUE);
    g_signal_connect(c->area, "destroy", G_CALLBACK(moonui_gtk_on_area_destroy),
                     NULL);
  }
  /* 上屏面挂在窗口内容容器的**主位**（GtkOverlay 的 child）：主位天然跟着窗口
   * 铺满，控件层（overlay 位）压在它上面。这条容器由 widgets_gtk.inc 建，见
   * prelude 的 moonui_gtk_window_overlay——P4 那会儿直接 gtk_window_set_child，
   * 结果是"窗口已经有控件就挂不上画布"，P6-1 起不再有这个限制。 */
  overlay = moonui_gtk_window_overlay(win, 1);
  if (overlay == NULL) {
    return -1; /* 窗口带了别人的内容：不接管 */
  }
  if (gtk_overlay_get_child(GTK_OVERLAY(overlay)) != c->area) {
    if (gtk_overlay_get_child(GTK_OVERLAY(overlay)) != NULL) {
      return -1; /* 主位已被另一块画布占着：一块窗只能挂一张整窗画布 */
    }
    gtk_overlay_set_child(GTK_OVERLAY(overlay), c->area);
  }
  c->window = win;
  gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(c->area),
                                 moonui_gtk_on_area_draw, c, NULL);
  moonui_gtk_area_register(c->area, c);
  return 0;
}

int moonui_canvas_present(moonui_ptr canvas) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  if (c == NULL || c->surface == NULL || c->area == NULL) {
    return -1;
  }
  /* 一帧一贴：不清画布、不改状态，只是让 GTK 调一次 draw func 把当前位图铺上去。
   * 重画靠再一轮 begin_frame。 */
  gtk_widget_queue_draw(c->area);
  return 0;
}

int moonui_canvas_present_view(moonui_ptr canvas, moonui_ptr view) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  GtkWidget *v = (GtkWidget *)(uintptr_t)view;
  if (c == NULL || v == NULL || c->surface == NULL) {
    return -1;
  }
  /* 只有绘制面能当上屏目标。P6-1 起 `widget_new(18)`（Custom）在 GTK4 侧落地
   * 成 GtkDrawingArea，所以自绘面走的就是这一条——判据就在 GTK_IS_DRAWING_AREA
   * 这一句上，不用按"是不是我们造的"再分一次（attach_window 造的那块也是它）。 */
  if (!GTK_IS_DRAWING_AREA(v)) {
    return -1;
  }
  gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(v), moonui_gtk_on_area_draw, c,
                                 NULL);
  /* 这块面被销毁时摘表（窗口销毁会连带销毁子树，那条路不经过 attach/detach）。
   * 重复挂同一个回调是无害的：摘表本身幂等。不挂的话登记表里会留一个已释放的
   * 面，下一次 present 就对着它 queue_draw。 */
  g_signal_connect(v, "destroy", G_CALLBACK(moonui_gtk_on_area_destroy), NULL);
  moonui_gtk_area_register(v, c);
  gtk_widget_queue_draw(v);
  return 0;
}

/* ---- 状态栈 ---- */

int moonui_canvas_save(moonui_ptr canvas) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  if (c == NULL || c->cr == NULL) {
    return -1;
  }
  cairo_save(c->cr);
  return 0;
}

int moonui_canvas_restore(moonui_ptr canvas) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  if (c == NULL || c->cr == NULL) {
    return -1;
  }
  cairo_restore(c->cr);
  return 0;
}

int moonui_canvas_clip_rect(moonui_ptr canvas, int x, int y, int w, int h) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  if (c == NULL || c->cr == NULL) {
    return -1;
  }
  /* cairo 的 clip 是**累积交集**且受 save/restore 管，与 CG 的 ClipToRect 同构。 */
  cairo_rectangle(c->cr, (double)x, (double)y, (double)w, (double)h);
  cairo_clip(c->cr);
  return 0;
}

int moonui_canvas_translate(moonui_ptr canvas, int dx, int dy) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  if (c == NULL || c->cr == NULL) {
    return -1;
  }
  cairo_translate(c->cr, (double)dx, (double)dy);
  return 0;
}

/* ---- 绘制 ---- */

int moonui_canvas_fill_rect(moonui_ptr canvas, int x, int y, int w, int h,
                            int radius_permille, int64_t rgb, int alpha) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  MoonuiGtkRectPath p;
  if (c == NULL || c->cr == NULL) {
    return -1;
  }
  if (w <= 0 || h <= 0) {
    return 0; /* 空矩形不是错，什么都不画 */
  }
  p.x = (double)x;
  p.y = (double)y;
  p.w = (double)w;
  p.h = (double)h;
  p.r = (double)radius_permille / 1000.0;
  moonui_gtk_fill_path(c, moonui_gtk_path_rect, &p, rgb, alpha);
  return 0;
}

int moonui_canvas_blur_region(moonui_ptr canvas, int x, int y, int w, int h,
                              int radius_permille) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  int r, x0, y0, x1, y1;
  if (c == NULL || c->surface == NULL || c->data == NULL || w <= 0 || h <= 0) {
    return -1;
  }
  r = radius_permille / 1000;
  if (r < 0) {
    r = 0;
  }
  if (r == 0) {
    return 0; /* 半径 0 是恒等（adapter.h） */
  }
  /* 区域钳到缓冲内：栏贴边时 x/y 可能为 0、w/h 可能越界。 */
  x0 = x < 0 ? 0 : x;
  y0 = y < 0 ? 0 : y;
  x1 = x + w;
  y1 = y + h;
  if (x1 > c->w) {
    x1 = c->w;
  }
  if (y1 > c->h) {
    y1 = c->h;
  }
  if (x1 <= x0 || y1 <= y0) {
    return 0;
  }
  /* 直接改表面像素：cairo 要求先 flush（把可能挂起的绘制落盘）、改完 mark_dirty
   * （让缓存失效），否则后面 read_pixel 或 present 读到的还是旧内容。 */
  cairo_surface_flush(c->surface);
  moonui_gtk_box_blur(c->data, c->stride, x0, y0, x1 - x0, y1 - y0, r);
  cairo_surface_mark_dirty(c->surface);
  return 0;
}

int moonui_canvas_stroke_rect(moonui_ptr canvas, int x, int y, int w, int h,
                              int radius_permille, int64_t rgb,
                              int width_permille) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  MoonuiGtkRectPath p;
  if (c == NULL || c->cr == NULL) {
    return -1;
  }
  p.x = (double)x;
  p.y = (double)y;
  p.w = (double)w;
  p.h = (double)h;
  p.r = (double)radius_permille / 1000.0;
  moonui_gtk_path_rect(c->cr, &p);
  moonui_gtk_set_rgb(c->cr, rgb, 255);
  cairo_set_line_width(c->cr, (double)width_permille / 1000.0);
  cairo_stroke(c->cr);
  return 0;
}

int moonui_canvas_fill_linear(moonui_ptr canvas, int x, int y, int w, int h,
                              moonui_ptr stops, int n) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  typedef struct {
    double pos, r, g, b;
  } Stop;
  const int64_t *raw;
  Stop *s;
  cairo_pattern_t *pat;
  int i, j;
  if (c == NULL || c->cr == NULL || stops == 0 || n < 2 || w <= 0 || h <= 0) {
    return -1;
  }
  raw = (const int64_t *)(uintptr_t)stops;
  s = (Stop *)calloc((size_t)n, sizeof(Stop));
  if (s == NULL) {
    return -1;
  }
  for (i = 0; i < n; i++) {
    double pos = (double)raw[i * 2] / 1000.0;
    int64_t rgb = raw[i * 2 + 1];
    if (pos < 0) {
      pos = 0;
    }
    if (pos > 1) {
      pos = 1;
    }
    s[i].pos = pos;
    s[i].r = (double)((rgb >> 16) & 0xFF) / 255.0;
    s[i].g = (double)((rgb >> 8) & 0xFF) / 255.0;
    s[i].b = (double)(rgb & 0xFF) / 255.0;
  }
  /* cairo 要求 offset 非递减（会给 warning 且结果不可预期），ABI 说端点序随意，
   * 所以这里按 pos 插排（n 是个位数）。 */
  for (i = 1; i < n; i++) {
    Stop key = s[i];
    j = i - 1;
    while (j >= 0 && s[j].pos > key.pos) {
      s[j + 1] = s[j];
      j--;
    }
    s[j + 1] = key;
  }
  /* 垂直从上到下（adapter.h 第一期口径），色带沿 y 展开。 */
  pat = cairo_pattern_create_linear((double)x, (double)y, (double)x,
                                    (double)(y + h));
  if (cairo_pattern_status(pat) != CAIRO_STATUS_SUCCESS) {
    cairo_pattern_destroy(pat);
    free(s);
    return -1;
  }
  for (i = 0; i < n; i++) {
    cairo_pattern_add_color_stop_rgb(pat, s[i].pos, s[i].r, s[i].g, s[i].b);
  }
  free(s);
  cairo_save(c->cr);
  cairo_rectangle(c->cr, (double)x, (double)y, (double)w, (double)h);
  cairo_clip(c->cr);
  cairo_set_source(c->cr, pat);
  cairo_paint(c->cr);
  cairo_restore(c->cr);
  cairo_pattern_destroy(pat);
  return 0;
}

int moonui_canvas_shadow(moonui_ptr canvas, int dx, int dy, int blur_permille,
                         int64_t rgb) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  if (c == NULL || c->cr == NULL) {
    return -1;
  }
  if (blur_permille <= 0) {
    /* 清零口：显式关掉投影（状态语义，见 adapter.h）。 */
    c->shadow_on = 0;
    c->shadow_blur = 0;
    return 0;
  }
  c->shadow_on = 1;
  c->shadow_dx = dx;
  c->shadow_dy = dy;
  c->shadow_blur = blur_permille / 1000;
  if (c->shadow_blur < 1) {
    c->shadow_blur = 1;
  }
  c->shadow_rgb = rgb;
  return 0;
}

int moonui_canvas_line(moonui_ptr canvas, int x0, int y0, int x1, int y1,
                       int64_t rgb, int width_permille) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  if (c == NULL || c->cr == NULL) {
    return -1;
  }
  cairo_new_path(c->cr);
  cairo_move_to(c->cr, (double)x0, (double)y0);
  cairo_line_to(c->cr, (double)x1, (double)y1);
  moonui_gtk_set_rgb(c->cr, rgb, 255);
  /* 默认线帽是 BUTT（方头不延伸），与 CG 的 kCGLineCapButt 同档。 */
  cairo_set_line_width(c->cr, (double)width_permille / 1000.0);
  cairo_stroke(c->cr);
  return 0;
}

int moonui_canvas_stroke_arc(moonui_ptr canvas, int cx, int cy, int r,
                             int start_deg_permille, int sweep_deg_permille,
                             int64_t rgb, int width_permille) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  MoonuiGtkArcPath a;
  double sweep;
  if (c == NULL || c->cr == NULL) {
    return -1;
  }
  if (r <= 0 || width_permille <= 0) {
    return -1;
  }
  if (sweep_deg_permille == 0) {
    /* 进度 0% 是正常状态，不是错误：什么都不画。 */
    return 0;
  }
  /* 度 × 1000 → 弧度。y 向下时"角度增大 = 屏幕顺时针"，与 ABI 的定义同向，
   * 所以不需要像 CG 那样再翻一层（CG 的弧按 y 向上定义，mac 那份是采样折线
   * 绕开的）。 */
  a.cx = (double)cx;
  a.cy = (double)cy;
  a.r = (double)r;
  a.a0 = (double)start_deg_permille / 1000.0 * M_PI / 180.0;
  sweep = (double)sweep_deg_permille / 1000.0 * M_PI / 180.0;
  if (sweep >= 2.0 * M_PI) {
    sweep = 2.0 * M_PI;
  } else if (sweep <= -2.0 * M_PI) {
    sweep = -2.0 * M_PI;
  }
  a.sweep = sweep;
  moonui_gtk_path_arc(c->cr, &a);
  moonui_gtk_set_rgb(c->cr, rgb, 255);
  cairo_set_line_width(c->cr, (double)width_permille / 1000.0);
  cairo_stroke(c->cr);
  return 0;
}

int moonui_canvas_fill_polygon(moonui_ptr canvas, moonui_ptr points, int n,
                               int64_t rgb, int alpha) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  MoonuiGtkPolyPath p;
  if (c == NULL || c->cr == NULL || points == 0 || n < 3) {
    return -1;
  }
  p.pts = (const int32_t *)(uintptr_t)points;
  p.n = n;
  moonui_gtk_fill_path(c, moonui_gtk_path_poly, &p, rgb, alpha);
  return 0;
}

/* ---- 文本（Pango）----
 * mac 用 CoreText，这边用 Pango——两者都不保证与对方逐像素相同，所以 ABI 只承诺
 * "量出来的就是画出来的"（度量与绘制共用同一套参数、同一个 layout 构造），跨平台
 * 的字号/字体族由各自系统决定。 */

/* 字号口径：adapter.h 的 font_permille 是"点 × 1000"，而 mac 的位图上下文里
 * 1 点 = 1 设备像素。Pango 的 point size 走 96dpi（13pt 会画成 17px），所以这里
 * 用 **absolute size**（device unit = 像素），让 13pt 在这边也是 13px —— 否则
 * 同一个设计在 Linux 上字会比 mac 大 33%。 */
static PangoFontDescription *moonui_gtk_font_desc(int font_permille, int weight) {
  PangoFontDescription *d = pango_font_description_new();
  double px = (double)font_permille / 1000.0;
  if (px <= 0) {
    px = 12.0;
  }
  pango_font_description_set_absolute_size(d, px * (double)PANGO_SCALE);
  if (weight >= 2) {
    pango_font_description_set_weight(d, PANGO_WEIGHT_BOLD);
  } else if (weight == 1) {
    pango_font_description_set_weight(d, PANGO_WEIGHT_MEDIUM);
  } else {
    pango_font_description_set_weight(d, PANGO_WEIGHT_NORMAL);
  }
  return d;
}

/* 一个 layout，字体族走 fontconfig 的默认 sans（mac 那边是系统字体，同样是
 * "平台自己的默认"，不在适配器里钉字体名——字族是 Core 的设计决定）。 */
static PangoLayout *moonui_gtk_layout(const char *utf8, int len,
                                      int font_permille, int weight) {
  PangoFontMap *fm = pango_cairo_font_map_get_default();
  PangoContext *ctx;
  PangoLayout *l;
  PangoFontDescription *d;
  if (fm == NULL || utf8 == NULL || len <= 0) {
    return NULL;
  }
  ctx = pango_font_map_create_context(fm);
  if (ctx == NULL) {
    return NULL;
  }
  l = pango_layout_new(ctx);
  g_object_unref(ctx);
  if (l == NULL) {
    return NULL;
  }
  d = moonui_gtk_font_desc(font_permille, weight);
  pango_layout_set_font_description(l, d);
  pango_font_description_free(d);
  pango_layout_set_text(l, utf8, len);
  return l;
}

int64_t moonui_canvas_measure_text(const char *utf8, int len,
                                   int font_permille, int weight) {
  PangoLayout *l;
  PangoRectangle logical;
  if (utf8 == NULL || len <= 0) {
    return -1;
  }
  l = moonui_gtk_layout(utf8, len, font_permille, weight);
  if (l == NULL) {
    return -1;
  }
  /* logical extents 是"行框"（宽 + 行高，含 ascent/descent），与 mac 的
   * NSAttributedString -size 同一档；ink extents 只包住墨迹，会把行高算小。 */
  pango_layout_get_pixel_extents(l, NULL, &logical);
  g_object_unref(l);
  return ((int64_t)logical.width << 32) | (int64_t)(uint32_t)logical.height;
}

int moonui_canvas_draw_text(moonui_ptr canvas, const char *utf8, int len, int x,
                            int y, int font_permille, int weight, int64_t rgb) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  PangoLayout *l;
  if (c == NULL || c->cr == NULL || utf8 == NULL || len <= 0) {
    return -1;
  }
  l = moonui_gtk_layout(utf8, len, font_permille, weight);
  if (l == NULL) {
    return -1;
  }
  cairo_save(c->cr);
  /* y 是**顶边**（adapter.h）：layout 的原点就是首行的左上，直接放过去。
   * update_layout 必须在 move_to 之后、show 之前：它把 layout 的 context 换成
   * 跟着这个 cairo_t 的那一份（含 CTM 与字体选项），漏了这句，translate/save
   * 之后画出来的位置与度量就对不上。 */
  cairo_move_to(c->cr, (double)x, (double)y);
  moonui_gtk_set_rgb(c->cr, rgb, 255);
  pango_cairo_update_layout(c->cr, l);
  pango_cairo_show_layout(c->cr, l);
  cairo_restore(c->cr);
  g_object_unref(l);
  return 0;
}

/* ---- 位图 ---- */

int moonui_canvas_draw_image(moonui_ptr canvas, const char *bytes, int len, int x,
                             int y, int w, int h) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  GBytes *gb;
  GInputStream *in;
  GdkPixbuf *pb;
  GdkPixbuf *scaled;
  GError *err = NULL;
  cairo_surface_t *tmp;
  uint8_t *dst_base;
  int dst_stride;
  int row, col;
  int nch, pstride;
  const guchar *src;
  if (c == NULL || c->cr == NULL || bytes == NULL || len <= 0 || w <= 0 ||
      h <= 0) {
    return -1;
  }
  /* 解码走 gdk-pixbuf：GTK4 生态里它就是"平台认得的图像编码"的入口
   * （adapter.h 沿 T86⑤ 的约定，mac 那边是 NSImage）。 */
  gb = g_bytes_new(bytes, (gsize)len);
  in = g_memory_input_stream_new_from_bytes(gb);
  pb = gdk_pixbuf_new_from_stream(in, NULL, &err);
  g_object_unref(in);
  g_bytes_unref(gb);
  if (pb == NULL) {
    if (err != NULL) {
      g_error_free(err);
    }
    return -1;
  }
  scaled = gdk_pixbuf_scale_simple(pb, w, h, GDK_INTERP_BILINEAR);
  g_object_unref(pb);
  if (scaled == NULL) {
    return -1;
  }
  /* 转成 cairo 的预乘 ARGB32：pixbuf 给的是**未预乘**的 R G B [A]，cairo 要
   * 0xAARRGGBB 且已预乘。按 32 位整数写（而不是按字节写），大小端都对。 */
  tmp = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
  if (cairo_surface_status(tmp) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(tmp);
    g_object_unref(scaled);
    return -1;
  }
  dst_base = cairo_image_surface_get_data(tmp);
  dst_stride = cairo_image_surface_get_stride(tmp);
  nch = gdk_pixbuf_get_n_channels(scaled);
  pstride = gdk_pixbuf_get_rowstride(scaled);
  src = gdk_pixbuf_read_pixels(scaled);
  if (dst_base == NULL || src == NULL) {
    cairo_surface_destroy(tmp);
    g_object_unref(scaled);
    return -1;
  }
  for (row = 0; row < h; row++) {
    uint32_t *d = (uint32_t *)(void *)(dst_base + (size_t)row * (size_t)dst_stride);
    const guchar *s = src + (size_t)row * (size_t)pstride;
    for (col = 0; col < w; col++) {
      uint32_t r = s[0];
      uint32_t g = s[1];
      uint32_t b = s[2];
      uint32_t a = (nch == 4) ? s[3] : 255u;
      d[col] = (a << 24) | (((r * a) / 255u) << 16) | (((g * a) / 255u) << 8) |
               ((b * a) / 255u);
      s += nch;
    }
  }
  cairo_surface_mark_dirty(tmp);
  g_object_unref(scaled);
  cairo_set_source_surface(c->cr, tmp, (double)x, (double)y);
  cairo_paint(c->cr);
  cairo_surface_destroy(tmp);
  return 0;
}

int64_t moonui_canvas_read_pixel(moonui_ptr canvas, int x, int y) {
  MoonuiCanvasGtk *c = moonui_canvas_gtk_of(canvas);
  uint32_t p;
  uint32_t a;
  if (c == NULL || c->surface == NULL || c->data == NULL) {
    return -1;
  }
  if (x < 0 || y < 0 || x >= c->w || y >= c->h) {
    return -1;
  }
  /* 直接读表面像素前必须 flush：cairo 可能还有没落到缓冲里的绘制。 */
  cairo_surface_flush(c->surface);
  memcpy(&p, c->data + (size_t)y * (size_t)c->stride + (size_t)x * 4, 4);
  a = (p >> 24) & 0xFFu;
  if (a == 0) {
    return -1; /* 全透明：ABI 约定返回 -1（"没有像素"） */
  }
  /* 预乘展开：a=255 时逐位精确，半透明按 a 归一回 0xRRGGBB。与 mac 那份同一算式
   * （只是通道位置不同：cairo 的 ARGB32 里 R 在高位）。 */
  return (int64_t)((uint32_t)(((p >> 16) & 0xFFu) * 255u / a) << 16) |
         (int64_t)((uint32_t)(((p >> 8) & 0xFFu) * 255u / a) << 8) |
         (int64_t)(uint32_t)((p & 0xFFu) * 255u / a);
}
