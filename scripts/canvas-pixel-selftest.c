/*
 * MoonUI · Linux/GTK4 画布（P4）——**真跑**的像素判据。
 *
 * 这个文件直接对着 backends/native-linux/adapter_native_gtk.c 里那份**真实现**
 * 链接（不是复制一份代码），所以判据绿 = 发布出去的那份 C 行为正确。
 *
 * 为什么能在 macOS 上跑：画布这一层只用 cairo（软件光栅，pixman）+ pango +
 * gdk-pixbuf，不碰显示服务器；脚本从 brew bottle 拼出的私有 dylib 目录就能跑。
 * 见 scripts/macos-cairo-runtime.js 与 scripts/canvas-pixel-check.sh 的头注。
 *
 * 边界（写清楚，别把这里的绿当"Linux 上一定绿"）：
 *   - 字体：本机 fontconfig 与 Linux 的字体栈不同，所以文本只验"量得出、画得上"，
 *     **不验**具体像素宽度/字形位置；量不出字体时打 SKIP（不是 PASS）。
 *   - 上屏（attach_window / present / present_view）需要真窗口**系统**，这里只验
 *     "挂上了、present 不报错"以及失败路径；真上屏在 Linux 真机 + xvfb。
 *   - P6-1 起还验控件层**结构**（造 / 挂 / 摆 / 层叠 / 摘挂 / 与画布共存）：无显示器
 *     下 gtk_init_check 也成立，所以这一层是真 GTK4 真跑；但"上屏之后的实际分配
 *     尺寸"要排版，留给 P8。
 *   - P6-2 的剪贴板判据**会临时占用系统剪贴板**（每条先备份、出口恢复，实测跑完
 *     不留痕）；原本是图片之类的非文本内容会被清掉，因为 ABI 只有文本这一形。
 *     这里验的是"自己写、自己读回"，**不验跨进程交接**（那是真机上的事）。
 *   - P6-3 的消息框判据是**真跑**（无显示器下也能 present，靠 auto_dismiss 替按
 *     真按钮），代价是**桌面上会闪一下**原生对话框。文件面板那组只在
 *     MOONUI_FILE_PANEL=1 时跑——GtkFileChooserNative 缺 GSettings schema 时是
 *     `g_error()` 直接 abort，那不能让判据来承担。
 *   - P6-4b 的主题判据读真 GtkSettings / 真 GtkCssProvider / GTK 的样式级联，
 *     但**背景色与圆角上屏后的像素**、Label/Button 的前景色与字号要 P6-5 造出
 *     控件叶子之后才验得了（现在只造得出 Panel/Custom 两种控件）。
 *   - P6-4c 的无障碍判据读真 GtkAccessible 与 GTK 自己的 test AT context
 *     （gtk_test_accessible_check_*），验的是「GTK 收下了什么」，**不是**
 *     AT-SPI 上读屏器最终念什么、也不是 4.6 真机上没有新属性时的回落。
 *   - P6-5b 的焦点判据读的是**未上屏窗口**的 gtk_window_get_focus：能验焦点
 *     按声明链移动、沿父链反查到 Entry，验不了 Tab 键的真派发与 GTK 默认遍历
 *     有没有被 key-pressed 的 TRUE 吞掉（那要 P8 的 xvfb 真窗）。自绘面点击
 *     是 g_signal_emit_by_name 驱动的 GtkGestureClick，不是真人上屏点击。
 *   - 抗锯齿边缘（圆角/弧/斜线）：只断言"该有的地方有色、该空的地方透明"，
 *     不断言边缘像素的具体灰度值——那是渲染器的自由。
 *   - P6-9 的图像源判据是**真解码**（GdkTexture 的两个 4.6 入口），验到纹理的
 *     像素尺寸与 return code 三态；上屏之后 GtkPicture 的等比缩放 / 留白观感
 *     与 mac 的 NSImageView 怎么对照，仍要人眼核，不在本闸。
 *
 * 用法：bash scripts/canvas-pixel-check.sh
 */
#include "adapter.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

/* P6-4b 起判据要直接读真 GTK 对象（GtkSettings / GtkCssProvider / CSS class），
 * 不再只经 ABI 观察。编译口径由 canvas-pixel-check.sh 给：私有 sysroot 的
 * gtk-4.0 头 + 4.6 最低版本闸，和生成物那份是同一套。 */
#include <gtk/gtk.h>

/* P6-5b：prelude 里两条刻意非 static 的 helper（不是 adapter.h 的 ABI）。
 * 真跑判据与生成物是两个翻译单元，靠它们驱动 Tab 推进与自绘面手势。 */
int moonui_gtk_focus_tab_step(GtkWidget *win, int backward);
/* T235 P6-10：文件拖入的 "drop" 分发（生成物 prelude 里刻意非 static 的
 * 那一只，理由见 gen-native-linux-gtk.js）。这里用真 GdkFileList 驱动它。 */
gboolean moonui_gtk_on_file_drop(GtkDropTarget *target, const GValue *value,
                                 double x, double y, gpointer data);
void *moonui_gtk_probe_gesture_of(GtkWidget *w);

static int g_pass = 0;
static int g_fail = 0;
static int g_skip = 0;
/* 「因为拿不到显示而跳过」单独计数（T235 P7）：Linux 上没有 DISPLAY 时
 * gtk_init 会失败，三十来组判据全部走 SKIP，而 fail=0 → 进程照样返 0。那正是
 * 本仓最难查的一种假绿（xvfb 没装/没起，闸却报 OK）。所以这一类跳过在 main
 * 末尾一律升级成 FAIL。 */
static int g_nodisplay = 0;

static void ok(const char *name) {
  g_pass++;
  printf("PASS  %s\n", name);
}

static void bad(const char *name, const char *detail) {
  g_fail++;
  printf("FAIL  %s  (%s)\n", name, detail);
}

/* 一条判据的收尾：中途出过 FAIL 就不再记 PASS（否则日志里同一行既 FAIL 又
 * PASS，"pass 数"还会把红的算成绿的——这正是本仓反复栽过的"判据不可观测"）。 */
static void finish(const char *name, int fail_before) {
  if (g_fail == fail_before) {
    ok(name);
  }
}

static void skip(const char *name, const char *why) {
  g_skip++;
  if (why != NULL && strstr(why, "gtk_init 失败") != NULL) {
    g_nodisplay++;
  }
  printf("SKIP  %s  (%s)\n", name, why);
}

/* 造一只 w×h 已开帧的画布。 */
static moonui_ptr canvas_new(int w, int h) {
  moonui_ptr c = moonui_canvas_create();
  if (c == 0) {
    return 0;
  }
  if (moonui_canvas_begin_frame(c, w, h) != 0) {
    moonui_canvas_destroy(c);
    return 0;
  }
  return c;
}

#define RGB(r, g, b) (((int64_t)(r) << 16) | ((int64_t)(g) << 8) | (int64_t)(b))

static int chan(int64_t rgb, int shift) { return (int)((rgb >> shift) & 0xFF); }

/* 颜色近似比较：抗锯齿/预乘取整都会抖动，容差给 3。 */
static int near(int64_t got, int64_t want) {
  if (got < 0) {
    return 0;
  }
  return chan(got, 16) - chan(want, 16) <= 3 && chan(want, 16) - chan(got, 16) <= 3 &&
         chan(got, 8) - chan(want, 8) <= 3 && chan(want, 8) - chan(got, 8) <= 3 &&
         chan(got, 0) - chan(want, 0) <= 3 && chan(want, 0) - chan(got, 0) <= 3;
}

/* 断言某点"是某色"（容差内）。 */
static void expect_rgb(const char *name, const char *what, moonui_ptr c, int x,
                       int y, int64_t want) {
  char detail[160];
  int64_t got = moonui_canvas_read_pixel(c, x, y);
  if (near(got, want)) {
    return;
  }
  snprintf(detail, sizeof(detail), "%s (%d,%d) 期望 %06llx 实际 %s%06llx", what, x,
           y, (unsigned long long)want,
           got < 0 ? "<透明/越界> " : "", (unsigned long long)(got < 0 ? 0 : got));
  bad(name, detail);
}

/* 断言某点"没有像素"（全透明）。 */
static void expect_empty(const char *name, const char *what, moonui_ptr c, int x,
                         int y) {
  char detail[160];
  int64_t got = moonui_canvas_read_pixel(c, x, y);
  if (got < 0) {
    return;
  }
  snprintf(detail, sizeof(detail), "%s (%d,%d) 期望透明，实际 %06llx", what, x, y,
           (unsigned long long)got);
  bad(name, detail);
}

/* 断言返回值。 */
static void expect_rc(const char *name, const char *what, int got, int want) {
  char detail[160];
  if (got == want) {
    return;
  }
  snprintf(detail, sizeof(detail), "%s 期望返回 %d，实际 %d", what, want, got);
  bad(name, detail);
}

/* 断言一个整数读数（P6-14 的相位 / 次数用它，省得每组手写 snprintf）。 */
static void expect_ll(const char *name, const char *what, long long got,
                      long long want) {
  char detail[160];
  if (got == want) {
    return;
  }
  snprintf(detail, sizeof(detail), "%s 期望 %lld，实际 %lld", what, want, got);
  bad(name, detail);
}

/* ---- 1. 填充与读回 ---- */
static void t_fill_rect_opaque(void) {
  const char *nm = "fill_rect 不透明填充铺满矩形";
  int before = g_fail;
  moonui_ptr c = canvas_new(10, 10);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  expect_rc(nm, "fill_rect", moonui_canvas_fill_rect(c, 0, 0, 10, 10, 0, RGB(255, 0, 0), 255), 0);
  expect_rgb(nm, "左上", c, 0, 0, RGB(255, 0, 0));
  expect_rgb(nm, "中心", c, 5, 5, RGB(255, 0, 0));
  expect_rgb(nm, "右下", c, 9, 9, RGB(255, 0, 0));
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_fill_rect_rounded(void) {
  const char *nm = "fill_rect 圆角把四角裁掉、中心保留";
  int before = g_fail;
  /* 20×20、半径 10000‰ = 10px = 半宽 → 正圆。 */
  moonui_ptr c = canvas_new(20, 20);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  moonui_canvas_fill_rect(c, 0, 0, 20, 20, 10000, RGB(0, 128, 0), 255);
  expect_rgb(nm, "中心", c, 10, 10, RGB(0, 128, 0));
  expect_empty(nm, "左上角外侧", c, 0, 0);
  expect_empty(nm, "右下角外侧", c, 19, 19);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_fill_rect_alpha(void) {
  const char *nm = "fill_rect 半透明叠加按预乘混色";
  int before = g_fail;
  moonui_ptr c = canvas_new(4, 4);
  int64_t px;
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  moonui_canvas_fill_rect(c, 0, 0, 4, 4, 0, RGB(255, 255, 255), 255);
  moonui_canvas_fill_rect(c, 0, 0, 4, 4, 0, RGB(255, 0, 0), 128);
  /* 白底 + 50% 红：R 仍是 255，G/B 落在中间带（取整会有 ±2 抖动）。 */
  px = moonui_canvas_read_pixel(c, 2, 2);
  if (px < 0) {
    bad(nm, "叠完变透明了");
  } else if (chan(px, 16) < 250) {
    bad(nm, "R 通道被压低了（半透明混色不对）");
  } else if (chan(px, 8) < 100 || chan(px, 8) > 160) {
    bad(nm, "G 通道不在 100..160（预乘展开算错）");
  } else {
    moonui_canvas_destroy(c);
    finish(nm, before);
    return;
  }
  moonui_canvas_destroy(c);
}

static void t_read_pixel_bounds(void) {
  const char *nm = "read_pixel 越界与全透明都返回 -1";
  int before = g_fail;
  moonui_ptr c = canvas_new(4, 4);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  if (moonui_canvas_read_pixel(c, -1, 0) != -1 || moonui_canvas_read_pixel(c, 4, 0) != -1 ||
      moonui_canvas_read_pixel(c, 0, 4) != -1) {
    bad(nm, "越界没有返回 -1");
  } else if (moonui_canvas_read_pixel(c, 1, 1) != -1) {
    bad(nm, "空画布中心不是 -1（开帧没清成透明）");
  } else {
    moonui_canvas_destroy(c);
    finish(nm, before);
    return;
  }
  moonui_canvas_destroy(c);
}

/* ---- 2. 状态栈 ---- */
static void t_clip_rect(void) {
  const char *nm = "clip_rect 之后画到界外的部分被裁掉";
  int before = g_fail;
  moonui_ptr c = canvas_new(10, 10);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  moonui_canvas_clip_rect(c, 0, 0, 5, 5);
  moonui_canvas_fill_rect(c, 0, 0, 10, 10, 0, RGB(0, 0, 255), 255);
  expect_rgb(nm, "裁剪区内", c, 2, 2, RGB(0, 0, 255));
  expect_empty(nm, "裁剪区外", c, 7, 7);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_translate_save_restore(void) {
  const char *nm = "translate 累积、save/restore 能撤回";
  int before = g_fail;
  moonui_ptr c = canvas_new(10, 10);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  moonui_canvas_save(c);
  moonui_canvas_translate(c, 5, 5);
  moonui_canvas_fill_rect(c, 0, 0, 2, 2, 0, RGB(255, 0, 0), 255);
  expect_rgb(nm, "平移后落点", c, 5, 5, RGB(255, 0, 0));
  expect_empty(nm, "原点上没东西", c, 0, 0);
  moonui_canvas_restore(c);
  moonui_canvas_fill_rect(c, 0, 0, 2, 2, 0, RGB(0, 255, 0), 255);
  expect_rgb(nm, "restore 后落回原点", c, 0, 0, RGB(0, 255, 0));
  moonui_canvas_destroy(c);
  finish(nm, before);
}

/* ---- 3. 线 / 弧 / 多边形 ---- */
static void t_line(void) {
  const char *nm = "line 画在两点之间、外侧不染";
  int before = g_fail;
  moonui_ptr c = canvas_new(10, 10);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  moonui_canvas_line(c, 0, 5, 9, 5, RGB(255, 0, 0), 1000);
  expect_rgb(nm, "线上", c, 5, 5, RGB(255, 0, 0));
  expect_empty(nm, "线外", c, 5, 2);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_arc_full(void) {
  const char *nm = "stroke_arc 整圈画出圆环（中间是空的）";
  int before = g_fail;
  moonui_ptr c = canvas_new(40, 40);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  /* 圆心 (20,20) 半径 10、线宽 1、扫过 360°。 */
  expect_rc(nm, "stroke_arc", moonui_canvas_stroke_arc(c, 20, 20, 10, 0, 360000, RGB(255, 0, 0), 1000), 0);
  expect_rgb(nm, "顶部环上", c, 20, 10, RGB(255, 0, 0));
  expect_rgb(nm, "底部环上", c, 20, 30, RGB(255, 0, 0));
  expect_rgb(nm, "右侧环上", c, 30, 20, RGB(255, 0, 0));
  expect_empty(nm, "圆心是空的", c, 20, 20);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_arc_half_direction(void) {
  const char *nm = "stroke_arc 从 0° 顺时针扫 180°：下半圈有、上半圈没有";
  int before = g_fail;
  moonui_ptr c = canvas_new(40, 40);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  /* ABI：0° = 三点钟、顺时针为正，位图 y 向下 → 扫过的正是下半圈。 */
  moonui_canvas_stroke_arc(c, 20, 20, 10, 0, 180000, RGB(0, 0, 255), 1000);
  expect_rgb(nm, "六点钟方向", c, 20, 30, RGB(0, 0, 255));
  expect_empty(nm, "十二点钟方向", c, 20, 10);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_arc_zero_sweep(void) {
  const char *nm = "stroke_arc 扫过角为 0 是正常状态（不画、返回 0）";
  int before = g_fail;
  moonui_ptr c = canvas_new(20, 20);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  expect_rc(nm, "sweep=0", moonui_canvas_stroke_arc(c, 10, 10, 5, 0, 0, RGB(255, 0, 0), 1000), 0);
  expect_empty(nm, "什么都没画", c, 10, 15);
  expect_rc(nm, "半径非正", moonui_canvas_stroke_arc(c, 10, 10, 0, 0, 90000, RGB(255, 0, 0), 1000), -1);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_fill_polygon(void) {
  const char *nm = "fill_polygon 填充闭合三角形、少于 3 点报错";
  int before = g_fail;
  int32_t pts[6] = {5, 5, 15, 5, 10, 15};
  moonui_ptr c = canvas_new(20, 20);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  expect_rc(nm, "三角形", moonui_canvas_fill_polygon(c, (moonui_ptr)(uintptr_t)pts, 3, RGB(255, 0, 0), 255), 0);
  expect_rgb(nm, "形内", c, 10, 8, RGB(255, 0, 0));
  expect_empty(nm, "形外", c, 2, 2);
  expect_rc(nm, "只有 2 点", moonui_canvas_fill_polygon(c, (moonui_ptr)(uintptr_t)pts, 2, RGB(255, 0, 0), 255), -1);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

/* ---- 4. 渐变 / 模糊 / 投影 ---- */
static void t_fill_linear(void) {
  const char *nm = "fill_linear 上→下渐变、stops 乱序也按 pos 排";
  int before = g_fail;
  /* 端点故意反着给（先 1000 再 0），验实现自己排序。 */
  int64_t stops[4] = {1000, RGB(0, 0, 255), 0, RGB(255, 0, 0)};
  moonui_ptr c = canvas_new(10, 100);
  int64_t top, bottom;
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  expect_rc(nm, "fill_linear", moonui_canvas_fill_linear(c, 0, 0, 10, 100, (moonui_ptr)(uintptr_t)stops, 2), 0);
  top = moonui_canvas_read_pixel(c, 5, 2);
  bottom = moonui_canvas_read_pixel(c, 5, 97);
  if (top < 0 || bottom < 0) {
    bad(nm, "渐变没铺满");
  } else if (chan(top, 16) < 200 || chan(top, 0) > 60) {
    bad(nm, "顶端不是起点色（红）—— 起点/终点定义反了？");
  } else if (chan(bottom, 0) < 200 || chan(bottom, 16) > 60) {
    bad(nm, "底端不是终点色（蓝）");
  } else {
    moonui_canvas_destroy(c);
    finish(nm, before);
    return;
  }
  moonui_canvas_destroy(c);
}

static void t_blur_region(void) {
  const char *nm = "blur_region 把区域内 1px 红线糊开、区域外不动";
  int before = g_fail;
  moonui_ptr c = canvas_new(40, 40);
  int64_t center, neighbor;
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  /* **白底** + 一条 1px 竖红线。白底不是为了好看：read_pixel 会把颜色按 alpha
   * 反预乘回来，所以"很淡的红"照样读成 0xFF0000 —— 只看 R 通道永远看不出模糊
   * 有没有发生。糊开之后红被摊薄，G 通道从 0 抬起来，那才是可观测的量。 */
  moonui_canvas_fill_rect(c, 0, 0, 40, 40, 0, RGB(255, 255, 255), 255);
  /* 线宽 2px：1px 的线画在整数坐标上只覆盖半个像素，抗锯齿后读回来是 ff7f7f，
   * 那是**正确**行为，不该拿来当"纯红"的基准（第一版判据就栽在这）。 */
  moonui_canvas_line(c, 20, 0, 20, 39, RGB(255, 0, 0), 2000);
  expect_rgb(nm, "模糊前中心是纯红", c, 20, 20, RGB(255, 0, 0));
  expect_rgb(nm, "模糊前邻点是纯白", c, 22, 20, RGB(255, 255, 255));
  expect_rc(nm, "blur_region", moonui_canvas_blur_region(c, 10, 0, 20, 40, 3000), 0);
  center = moonui_canvas_read_pixel(c, 20, 20);
  neighbor = moonui_canvas_read_pixel(c, 22, 20);
  if (center < 0 || neighbor < 0) {
    bad(nm, "模糊之后读了透明（白底不该透明）");
  } else if (chan(center, 8) < 20) {
    bad(nm, "中心仍是纯红：模糊没把强度摊开");
  } else if (chan(neighbor, 8) > 250) {
    bad(nm, "邻点仍是纯白：模糊没把颜色铺出去");
  }
  /* 区域外（x=37 离模糊域 7px 以上）仍应是纯白。 */
  expect_rgb(nm, "区域外未被波及", c, 37, 20, RGB(255, 255, 255));
  expect_rc(nm, "半径 0 是恒等", moonui_canvas_blur_region(c, 10, 0, 20, 40, 0), 0);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_shadow(void) {
  const char *nm = "shadow 是状态：设了有影、blur=0 清零后无影";
  int before = g_fail;
  moonui_ptr c = canvas_new(40, 40);
  moonui_ptr d;
  int64_t px;
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  moonui_canvas_fill_rect(c, 0, 0, 40, 40, 0, RGB(255, 255, 255), 255);
  expect_rc(nm, "shadow", moonui_canvas_shadow(c, 4, 4, 4000, RGB(0, 0, 0)), 0);
  moonui_canvas_fill_rect(c, 10, 10, 10, 10, 0, RGB(255, 255, 255), 255);
  /* 阴影往右下偏 4px，所以右边外侧 (24,24) 应该被压暗一点。 */
  px = moonui_canvas_read_pixel(c, 24, 24);
  if (px < 0) {
    bad(nm, "阴影位置读了透明（白底不该透明）");
  } else if (chan(px, 16) > 250 && chan(px, 8) > 250) {
    bad(nm, "偏移方向上没有阴影");
  }
  moonui_canvas_destroy(c);

  /* 清零口：同一个渲染流程、不设影 → 同一位置必须纯白。 */
  d = canvas_new(40, 40);
  if (d == 0) {
    bad(nm, "第二只画布造不出来");
    return;
  }
  moonui_canvas_fill_rect(d, 0, 0, 40, 40, 0, RGB(255, 255, 255), 255);
  moonui_canvas_shadow(d, 4, 4, 4000, RGB(0, 0, 0));
  expect_rc(nm, "shadow 清零", moonui_canvas_shadow(d, 0, 0, 0, RGB(0, 0, 0)), 0);
  moonui_canvas_fill_rect(d, 10, 10, 10, 10, 0, RGB(255, 255, 255), 255);
  expect_rgb(nm, "清零后该处纯白", d, 24, 24, RGB(255, 255, 255));
  moonui_canvas_destroy(d);
  finish(nm, before);
}

/* ---- 5. 文本 ---- */
static void t_measure_text(void) {
  const char *nm = "measure_text 量得出宽高、空串报错";
  int before = g_fail;
  int64_t packed = moonui_canvas_measure_text("Hello", 5, 13000, 0);
  int64_t w = packed >> 32;
  int64_t h = packed & 0xFFFFFFFF;
  if (packed < 0) {
    bad(nm, "测量返回负数");
  } else if (w <= 0 || h <= 0) {
    bad(nm, "宽或高是 0（字体没装上？）");
  } else if (h < 8 || h > 40) {
    bad(nm, "行高不在 8..40（13px 字号的行高应该在这个带里）");
  } else if (moonui_canvas_measure_text("", 0, 13000, 0) != -1) {
    bad(nm, "空串没有返回 -1");
  } else {
    finish(nm, before);
    return;
  }
}

static void t_draw_text(void) {
  const char *nm = "draw_text 真的把像素染上";
  int before = g_fail;
  moonui_ptr c;
  int x, y;
  int inked = 0;
  /* 先确认字体栈可用：测不出宽度就说明这台机器没字体，判据不可观测 → SKIP。 */
  if (moonui_canvas_measure_text("W", 1, 16000, 0) <= 0) {
    skip(nm, "这台机器量不出字宽（无字体栈），文本像素判据不可观测");
    return;
  }
  c = canvas_new(80, 30);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  expect_rc(nm, "draw_text", moonui_canvas_draw_text(c, "Wg", 2, 2, 2, 16000, 0, RGB(0, 0, 0)), 0);
  for (y = 0; y < 30; y++) {
    for (x = 0; x < 80; x++) {
      if (moonui_canvas_read_pixel(c, x, y) >= 0) {
        inked++;
      }
    }
  }
  if (inked < 20) {
    bad(nm, "画了字但几乎没有染上的像素");
  } else {
    finish(nm, before);
  }
  moonui_canvas_destroy(c);
}

/* ---- 6. 位图 ---- */
/* 2×2 纯红 PPM（P6）。用 PPM 而不是 PNG：gdk-pixbuf 的 pnm 解码器不依赖外部
 * 库，判据本身不必背一份 PNG 字节流。 */
static const char kPpm[] = "P6\n2 2\n255\n\xff\x00\x00\xff\x00\x00\xff\x00\x00\xff\x00\x00";

static void t_draw_image(void) {
  const char *nm = "draw_image 解码并缩放贴到指定矩形";
  int before = g_fail;
  moonui_ptr c = canvas_new(8, 8);
  int rc;
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  rc = moonui_canvas_draw_image(c, kPpm, (int)sizeof(kPpm) - 1, 0, 0, 4, 4);
  if (rc != 0) {
    skip(nm, "本机 gdk-pixbuf 解不出 PPM（解码器模块没装）——真机/CI 上验");
    moonui_canvas_destroy(c);
    return;
  }
  expect_rgb(nm, "贴图区中心", c, 2, 2, RGB(255, 0, 0));
  expect_empty(nm, "矩形外", c, 6, 6);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

/* ---- 7. 失败路径（上屏类只能验这些，真窗在 Linux 真机）---- */
static void t_error_paths(void) {
  const char *nm = "参数错 / 没开帧 / 没挂窗 都返回 -1";
  int before = g_fail;
  moonui_ptr c = moonui_canvas_create();
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  if (moonui_canvas_begin_frame(c, 0, 10) != -1) {
    bad(nm, "0 宽的帧没有被拒");
  } else if (moonui_canvas_fill_rect(c, 0, 0, 1, 1, 0, RGB(255, 0, 0), 255) != -1) {
    bad(nm, "没开帧就画没报错");
  } else if (moonui_canvas_end_frame(c) != -1) {
    bad(nm, "没开帧就收帧没报错");
  } else if (moonui_canvas_present(c) != -1) {
    bad(nm, "没挂窗就 present 没报错");
  } else if (moonui_canvas_attach_window(c, 0) != -1) {
    bad(nm, "挂空窗口没报错");
  } else if (moonui_canvas_present_view(c, 0) != -1) {
    bad(nm, "贴空视图没报错");
  } else if (moonui_canvas_backend_of(c) != 0) {
    bad(nm, "backend_of 不是 AUTO(0)");
  } else if (moonui_canvas_destroy(0) != -1) {
    bad(nm, "销毁空画布没报错");
  } else {
    moonui_canvas_destroy(c);
    finish(nm, before);
    return;
  }
  moonui_canvas_destroy(c);
}

/* ---- P6-1 控件挂载层：真 GTK4 的结构判据 ----
 *
 * 2026-11-08 实测：`gtk_init_check()` 在 macOS **没有显示器**时也返回 1，
 * `gtk_fixed_new` / `gtk_drawing_area_new` / `gtk_overlay_new` 都造得出来。所以
 * 控件这一层的**结构**（造得出来、挂得上、摆得进、层叠顺序、摘得下、画布与控件
 * 共存）能在本机真跑——不是靠假 widget 树（那是 scripts/mock-gtk-selftest.c 第
 * 7 组的做法，只验纯指针逻辑）。
 *
 * 仍然证不了的：真上屏之后的分配尺寸、命中反查（要先排版）、坐标在 HiDPI 下的
 * 实际观感——那些留给 Linux 真机（P8）。
 */
static int64_t px_pack(int a, int b) {
  return (int64_t)(((uint64_t)(uint32_t)a << 32) | (uint64_t)(uint32_t)b);
}

static void t_widget_new_kinds(void) {
  const char *nm = "P6-5b 控件叶子：十二种 kind 造出对应的真 GTK 对象，缺席的如实返回 0";
  int before = g_fail;
  static const struct {
    int kind;
    const char *type;
    int orientation; /* -1 = 不适用 */
  } cases[] = {
    {0,  "GtkLabel", -1},
    {1,  "GtkButton", -1},
    {2,  "GtkEntry", -1},
    {3,  "GtkCheckButton", -1},
    {4,  "GtkPasswordEntry", -1},
    {5,  "GtkSeparator", GTK_ORIENTATION_HORIZONTAL},
    {13, "GtkSeparator", GTK_ORIENTATION_VERTICAL},
    {16, "GtkPicture", -1},
    {17, "GtkFixed", -1},
    {18, "GtkDrawingArea", -1},
    {14, "GtkToggleButton", -1},
    {15, "GtkScrolledWindow", -1}
  };
  /* 19 WebView 仍如实缺席（要 WebKitGTK 外部依赖）；6..12 走专属构造入口
   * （P6-5c，见 t_widget_p65c_controls），不走这套 (kind,text) 通用工厂。
   * 20/-1 是越界与负 kind 的护栏。 */
  static const int absent[] = {6, 7, 8, 9, 10, 11, 12, 19, 20, -1};
  moonui_ptr hs[12];
  int i;

  if (moonui_native_init() != 0) {
    skip(nm, "gtk_init 失败（无显示器）");
    return;
  }
  for (i = 0; i < 12; ++i) {
    char d[160];
    GtkWidget *w;
    hs[i] = moonui_native_widget_new(cases[i].kind, "x", 1);
    if (hs[i] == 0) {
      snprintf(d, sizeof(d), "kind %d（%s）造不出来", cases[i].kind, cases[i].type);
      bad(nm, d);
      continue;
    }
    /* 读 GTK 自己那份类型名，不读实现存过的 kind：造错对象（比如把 Label
     * 造成 Button）这条才会红。期望值写死在本表里。 */
    w = (GtkWidget *)(uintptr_t)hs[i];
    if (strcmp(G_OBJECT_TYPE_NAME(G_OBJECT(w)), cases[i].type) != 0) {
      snprintf(d, sizeof(d), "kind %d 期望 %s，实际 %s", cases[i].kind,
               cases[i].type, G_OBJECT_TYPE_NAME(G_OBJECT(w)));
      bad(nm, d);
    }
    /* 两个 Separator 是同一类型、不同方向：只读类型名会把 5/13 对调放过。 */
    if (cases[i].orientation >= 0 &&
        gtk_orientable_get_orientation(GTK_ORIENTABLE(w)) != cases[i].orientation) {
      snprintf(d, sizeof(d), "kind %d 分隔符方向错（期望 %d，实际 %d）",
               cases[i].kind, cases[i].orientation,
               (int)gtk_orientable_get_orientation(GTK_ORIENTABLE(w)));
      bad(nm, d);
    }
    /* 14 MenuRow：只读类型名分不出 ToggleButton 与普通 Button 的差别，
     * 再验它真的能接 clicked / active（探针实测 GTK_IS_BUTTON=1）。 */
    if (cases[i].kind == 14 &&
        (!GTK_IS_TOGGLE_BUTTON(w) || !GTK_IS_BUTTON(w))) {
      bad(nm, "kind 14 不是可勾选的 GtkToggleButton");
    }
    /* 15 Scroll：光造出 GtkScrolledWindow 不算数，文档区必须真的建起来
     * （4.24 探针实测 set_child(GtkFixed) 会自动包 GtkViewport）。 */
    if (cases[i].kind == 15) {
      GtkWidget *vp = gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(w));
      GtkWidget *doc = (vp != NULL && GTK_IS_VIEWPORT(vp))
                           ? gtk_viewport_get_child(GTK_VIEWPORT(vp)) : NULL;
      if (vp == NULL || !GTK_IS_VIEWPORT(vp)) {
        bad(nm, "kind 15 没有 GTK 自动包的 GtkViewport");
      } else if (doc == NULL ||
                 strcmp(G_OBJECT_TYPE_NAME(G_OBJECT(doc)), "GtkFixed") != 0) {
        snprintf(d, sizeof(d), "kind 15 文档区不是 GtkFixed，实际 %s",
                 doc != NULL ? G_OBJECT_TYPE_NAME(G_OBJECT(doc)) : "NULL");
        bad(nm, d);
      }
    }
  }
  for (i = 0; i < (int)(sizeof(absent) / sizeof(absent[0])); ++i) {
    char d[96];
    moonui_ptr h = moonui_native_widget_new(absent[i], "", 0);
    if (h != 0) {
      snprintf(d, sizeof(d), "缺席的 kind %d 被当成造出来了", absent[i]);
      bad(nm, d);
      moonui_native_widget_destroy(h);
    }
  }
  for (i = 0; i < 12; ++i) moonui_native_widget_destroy(hs[i]);
  finish(nm, before);
}

static void t_widget_props(void) {
  const char *nm = "widget 的可见/可用往返（真 GTK4 的 visible/sensitive）";
  int before = g_fail;
  moonui_ptr w = moonui_native_widget_new(18, "", 0);
  if (w == 0) {
    bad(nm, "Custom 造不出来");
    return;
  }
  if (moonui_native_widget_visible(w) != 1) {
    /* GTK4 的控件**默认可见**（4.0 起没有 gtk_widget_show，visible 的默认值就是
     * TRUE），与 mac 的 NSView（hidden=NO）同义。这条钉的是那个默认值——写成
     * 0 的话每个新控件都得靠 Core 先 show 一次才画得出来。 */
    bad(nm, "新控件初始不是「可见」（GTK4 的 visible 默认 TRUE，与 NSView 同义）");
  } else if (moonui_native_widget_set_visible(w, 0),
             moonui_native_widget_visible(w) != 0) {
    bad(nm, "set_visible(0) 之后读回不是 0");
  } else if (moonui_native_widget_set_visible(w, 1),
             moonui_native_widget_visible(w) != 1) {
    bad(nm, "set_visible(1) 之后读回不是 1");
  } else if (moonui_native_widget_enabled(w) != 1) {
    bad(nm, "新控件初始不是「可用」（GTK 的 sensitive 默认 TRUE）");
  } else if (moonui_native_widget_set_enabled(w, 0),
             moonui_native_widget_enabled(w) != 0) {
    bad(nm, "set_enabled(0) 之后读回不是 0");
  } else {
    moonui_native_widget_set_opacity(w, 2000); /* 越界要夹，不该崩 */
    moonui_native_widget_set_opacity(w, -5);
    finish(nm, before);
  }
  moonui_native_widget_destroy(w);
}

static void t_widget_attach_z(void) {
  const char *nm = "control_attach / z 序 / raise / detach（真 GtkFixed 的子节点顺序）";
  int before = g_fail;
  moonui_ptr win = moonui_native_window_new("w", 1, 320, 240);
  moonui_ptr a = moonui_native_widget_new(17, "", 0);
  moonui_ptr b = moonui_native_widget_new(18, "", 0);
  if (win == 0 || a == 0 || b == 0) {
    bad(nm, "窗口或控件造不出来");
    return;
  }
  if (moonui_native_control_z_index(a) != -1) {
    bad(nm, "还没挂的控件 z 序不是 -1");
  } else {
    moonui_native_control_attach(win, a);
    moonui_native_control_attach(win, b);
    /* 后挂的在上：ABI 的 0 = 最上层 */
    if (moonui_native_control_z_index(b) != 0 ||
        moonui_native_control_z_index(a) != 1) {
      bad(nm, "attach 之后的层叠不是「后挂的在上」");
    } else {
      /* raise 是"摘下来再放回去"（GtkFixed 没有重排 API），要真把顺序换过来 */
      moonui_native_control_raise(a);
      if (moonui_native_control_z_index(a) != 0 ||
          moonui_native_control_z_index(b) != 1) {
        bad(nm, "raise 之后顺序没换过来");
      } else if (moonui_native_control_detach(b),
                 moonui_native_control_z_index(b) != -1) {
        bad(nm, "detach 之后 z 序不是 -1");
      } else if (moonui_native_control_attach(win, b),
                 moonui_native_control_z_index(b) != 0) {
        /* 这一条同时验了「detach 不销毁」：被摘下来的控件还能挂回去。
         * 若 detach 顺手把对象释放了，这里就是一次自由后使用。 */
        bad(nm, "detach 之后重新 attach 挂不回去（控件被提前销毁了？）");
      } else {
        finish(nm, before);
      }
    }
  }
  moonui_native_widget_destroy(a);
  moonui_native_widget_destroy(b);
  moonui_native_window_destroy(win);
}

static void t_widget_bounds_origin(void) {
  const char *nm = "control_set_bounds → widget_origin 读回（物理像素 ↔ 逻辑单位换算）";
  int before = g_fail;
  moonui_ptr win = moonui_native_window_new("w", 1, 320, 240);
  moonui_ptr w = moonui_native_widget_new(18, "", 0);
  int scale, ex, ey;
  int64_t org;
  if (win == 0 || w == 0) {
    bad(nm, "窗口或控件造不出来");
    return;
  }
  moonui_native_control_attach(win, w);
  scale = moonui_native_widget_dpi(w) / 96;
  if (scale <= 0) scale = 1;
  moonui_native_control_set_bounds(w, 20, 10, 100, 50);
  org = moonui_native_widget_origin(w);
  /* 进参是物理像素，落地时除以缩放因子换成 GTK 的逻辑单位；读回再乘回去。
   * 20 与 10 都能被常见的 scale（1/2/3）整除，所以期望值是精确的。 */
  ex = (20 / scale) * scale;
  ey = (10 / scale) * scale;
  if ((int)((org >> 32) & 0x7FFFFFFF) != ex || (int)(org & 0x7FFFFFFF) != ey) {
    bad(nm, "origin 读回与 set_bounds 的进参对不上（scale 换算错）");
  } else {
    /* origin 读的是我们自己摆的那份账（见 widgets_gtk.inc 的注释：GTK 4.24 的
     * gtk_fixed_get_child_position 布局前恒报 0,0）。所以这里再验一条**真 GTK 的
     * 事实**：尺寸请求有没有真落进控件——minimum_size 走 gtk_widget_measure，
     * 数不对就说明 set_size_request 根本没执行到。 */
    int64_t mn = moonui_native_widget_minimum_size(w);
    if ((int)((mn >> 32) & 0x7FFFFFFF) != (100 / scale) * scale ||
        (int)(mn & 0x7FFFFFFF) != (50 / scale) * scale) {
      bad(nm, "minimum_size 没跟着 set_bounds 的尺寸走（GTK 没收到 set_size_request）");
    } else {
      finish(nm, before);
    }
  }
  moonui_native_widget_destroy(w);
  moonui_native_window_destroy(win);
}

static void t_canvas_on_widget_window(void) {
  const char *nm = "画布与控件共存（P4 缺口）：先挂控件再 attach_window 也成功";
  int before = g_fail;
  moonui_ptr win = moonui_native_window_new("w", 1, 320, 240);
  moonui_ptr panel = moonui_native_widget_new(17, "", 0);
  moonui_ptr custom = moonui_native_widget_new(18, "", 0);
  moonui_ptr c = canvas_new(64, 64);
  moonui_ptr c2;
  if (win == 0 || panel == 0 || custom == 0 || c == 0) {
    bad(nm, "窗口 / 控件 / 画布有一个造不出来");
    return;
  }
  moonui_native_control_attach(win, panel); /* 控件先挂：窗口内容容器此刻才建出来 */
  if (moonui_canvas_attach_window(c, win) != 0) {
    bad(nm, "窗口已有控件时 attach_window 仍然失败（P4 那条缺口又回来了）");
  } else if (moonui_canvas_present(c) != 0) {
    bad(nm, "挂上之后 present 报错");
  } else if ((c2 = canvas_new(8, 8)) != 0 &&
             moonui_canvas_attach_window(c2, win) != -1) {
    bad(nm, "同一扇窗挂第二张整窗画布没被拒（会互相盖住）");
    moonui_canvas_destroy(c2);
  } else {
    if (c2 != 0) moonui_canvas_destroy(c2);
    /* present_view：自绘面（kind 18）能当上屏目标，Panel（kind 17）不能 */
    if (moonui_canvas_present_view(c, custom) != 0) {
      bad(nm, "present_view 认不出 Custom 自绘面");
    } else if (moonui_canvas_present_view(c, panel) != -1) {
      bad(nm, "present_view 把 Panel 也当成自绘面了");
    } else {
      finish(nm, before);
    }
  }
  moonui_canvas_destroy(c);
  moonui_native_widget_destroy(panel);
  moonui_native_widget_destroy(custom);
  moonui_native_window_destroy(win);
}

/* ---- P6-2：剪贴板（真 GTK4 真跑）----
 *
 * 本自检只链 libmoonbitrun.o，里面**没有** `moonbit_make_bytes`，而剪贴板那条 ABI
 * 的返回值要造 bytes。同 `gdk_keyval_name` / `moonbit_make_bytes` 那招：补一个
 * "声明有、实现不在"的符号。
 *
 * 但这一条比前面几个替身严格——**布局必须与真运行时逐字节一致**：对象头是
 * `{ int32_t rc; uint32_t meta; }` 紧贴在 payload 之前，all-scalar array（bytes 就是）
 * 的 meta 就是元素个数。判据靠 `Moonbit_array_length` 读长度，所以这里写错的话
 * 长度判据会直接红（那不是"判据错"，是这个替身错——两条都得对）。 */
moonbit_bytes_t moonbit_make_bytes(int32_t size, int value) {
  struct moonbit_object *hdr;
  uint8_t *payload;
  if (size < 0) {
    size = 0;
  }
  hdr = (struct moonbit_object *)malloc(sizeof(struct moonbit_object) + (size_t)size);
  if (hdr == NULL) {
    abort();
  }
  hdr->rc = (int32_t)(((uint32_t)1 << MOONBIT_RC_COUNT_SHIFT) |
                      (uint32_t)moonbit_BLOCK_KIND_VAL_ARRAY);
  hdr->meta = (uint32_t)size;
  payload = (uint8_t *)(hdr + 1);
  memset(payload, value, (size_t)size);
  return payload;
}

/* ---- T235 P6-12：worker_run 的引用计数计数桩 ----
 * libmoonbitrun.o 不导出 moonbit_incref / moonbit_decref（此前作为未定义符号被
 * dynamic_lookup 放行，因为自检从不碰真闭包）。这个组的闭包是假指针，只量
 * "拿了几次、退了几次"，给计数桩比接真 GC 更直接，也不会对假指针做真操作。 */
static int g_worker_incref = 0;
static int g_worker_decref = 0;
void moonbit_incref(void *obj) {
  (void)obj;
  g_worker_incref++;
}
void moonbit_decref(void *obj) {
  (void)obj;
  g_worker_decref++;
}

/* 把 ABI 返回的 bytes 拷成可 strcmp 的 C 串。Bytes 不保证 NUL 结尾，长度只能从
 * 对象头拿（见上面那个替身的注释）。 */
static char *clip_text_dup(void) {
  moonbit_bytes_t b = moonui_native_clipboard_text();
  int32_t n;
  char *s;
  if (b == NULL) {
    return NULL;
  }
  n = (int32_t)Moonbit_array_length(b);
  s = (char *)malloc((size_t)n + 1);
  if (s == NULL) {
    return NULL;
  }
  if (n > 0) {
    memcpy(s, (const void *)b, (size_t)n);
  }
  s[n] = '\0';
  return s;
}

/* 往剪贴板写一段 C 串，长度按 UTF-8 字节数给（ABI 要的是字节数，不是字符数）。 */
static int clip_put(const char *s) {
  return moonui_native_clipboard_set_text(s, (int)strlen(s));
}

/* 写 → 读回 → 恢复。**这个判据会临时占用系统剪贴板**，所以进了就先备份、
 * 每条出口都恢复。原本是图片之类的非文本内容会被清掉——ABI 只有文本这一形，
 * 保不真（证据边界写在 TODO）。 */
static void t_clipboard_roundtrip(void) {
  const char *name = "clipboard 写读往返（UTF-8 中文）";
  const char *want = "moonui-剪贴板-42";
  int before = g_fail;
  char *old = clip_text_dup();
  char *got;
  int rc;
  if (old == NULL) {
    skip(name, "读剪贴板返回 NULL（不该发生：空也应是空 bytes）");
    return;
  }
  rc = clip_put(want);
  if (rc == -1) {
    free(old);
    skip(name, "没有可用的剪贴板（没有 GDK 后端 / 无 display）");
    return;
  }
  if (rc != 0) {
    bad(name, "set_text 返回了 0/-1 之外的码");
  } else {
    got = clip_text_dup();
    if (got == NULL || strcmp(got, want) != 0) {
      bad(name, "读回与写入不一致（写进去了但读出来不是那段）");
    }
    free(got);
  }
  /* 恢复：顺带验"写空串"这条不崩（原剪贴板为空时就是它）。 */
  if (clip_put(old) != 0) {
    bad(name, "恢复原剪贴板失败——本机剪贴板已被这次测试改掉");
  }
  free(old);
  finish(name, before);
}

/* 覆盖语义 + 长度维度。长度这一维必须单独钉：只比内容的话，返回多带/少带几个
 * 字节的实现在 strcmp 上照样绿（"判据不可观测"那个坑）。 */
static void t_clipboard_overwrite(void) {
  const char *name = "clipboard 覆盖不追加 + 长度是 UTF-8 字节数";
  const char *cn = "中文测试"; /* 4 个汉字，UTF-8 12 字节 */
  int before = g_fail;
  char *old = clip_text_dup();
  char *got;
  moonbit_bytes_t b;
  if (old == NULL) {
    skip(name, "读剪贴板返回 NULL");
    return;
  }
  if (clip_put("a") == -1) {
    free(old);
    skip(name, "没有可用的剪贴板");
    return;
  }
  if (clip_put(cn) != 0) {
    bad(name, "第二次写返回非 0");
  } else {
    b = moonui_native_clipboard_text();
    if (b == NULL || (int32_t)Moonbit_array_length(b) != 12) {
      bad(name, "读回长度不是 12（按字节数算；“中文测试”=4 汉字×3 字节）");
    } else if (memcmp((const void *)b, cn, 12) != 0) {
      bad(name, "读回内容不是第二段（覆盖变成追加了？）");
    }
  }
  got = clip_text_dup();
  if (got != NULL && strcmp(got, "a") == 0) {
    bad(name, "读回还是第一段（没覆盖成功）");
  }
  free(got);
  if (clip_put(old) != 0) {
    bad(name, "恢复原剪贴板失败");
  }
  free(old);
  finish(name, before);
}

/* 参数错必须报 -2（"拿住了但没写进去"这一档），不能悄悄当成功。
 * 这条不改剪贴板内容，所以不备份。 */
static void t_clipboard_bad_args(void) {
  const char *name = "clipboard 参数错误报 -2，不谎报成功";
  int before = g_fail;
  if (moonui_native_clipboard_set_text(NULL, 0) != -2) {
    bad(name, "text=NULL 没有报 -2");
  }
  if (moonui_native_clipboard_set_text("x", -1) != -2) {
    bad(name, "text_len<0 没有报 -2");
  }
  finish(name, before);
}

/* ---- P6-3 对话框与文件面板（真 GtkMessageDialog / 真 GtkFileChooserNative）----
 *
 * 消息框这组是**真跑**的：2026-11-08 探针实测，无显示器下 `gtk_window_present`
 * 照样能 present，我们自己的 GMainLoop 收到 response（点是 -8、点否 -9、确定 -5），
 * 所以"点了按钮之后 ABI 返回什么"这条能在本机验。注意这会**在桌面上闪一下**原生
 * 对话框（0ms 后就被替按掉），这是真跑的代价，不是故障。
 *
 * 文件面板那组默认 SKIP：GtkFileChooserNative 一 show 就去读
 * `org.gtk.Settings.FileChooser`，schema 不可用时 GTK 是 `g_error()`（直接把进程
 * 带走，不是返回错误码）。所以由 check 脚本先编译 schema 并导出
 * MOONUI_FILE_PANEL=1，只有这时候才跑——"判据把测试进程干掉"不能当成一条红。
 *
 * 仍然证不了的：真机上"用户真按了按钮"的完整路径（这里只证明应答通路与码表）、
 * portal 下的面板（本机走的是内置 GtkFileChooserDialog）。 */

/* ABI 返回的 bytes → 可 strcmp 的 C 串（长度只能从对象头拿，见 moonbit_make_bytes
 * 替身的注释）。空包返回空串而不是 NULL，判据里就能直接比 ""。 */
static char *dlg_bytes_dup(moonbit_bytes_t b) {
  int32_t n;
  char *s;
  if (b == NULL) {
    return NULL;
  }
  n = (int32_t)Moonbit_array_length(b);
  s = (char *)malloc((size_t)n + 1);
  if (s == NULL) {
    return NULL;
  }
  if (n > 0) {
    memcpy(s, b, (size_t)n);
  }
  s[n] = '\0';
  return s;
}

static int file_panel_ready(void) {
  const char *v = getenv("MOONUI_FILE_PANEL");
  return v != NULL && strcmp(v, "1") == 0;
}

/* message：只有一只按钮，"按了确定"与"面板被关掉"对调用方是同一件事，都返回 0。 */
static void t_dialog_message(void) {
  const char *name =
      "dialog_message：点确定返回 0（真 GtkMessageDialog + 自动应答）";
  int before = g_fail;
  int rc;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  if (moonui_native_auto_dismiss_dialog(0, 0) != 0) {
    bad(name, "装自动应答失败（index=0 是合法值）");
  } else {
    rc = moonui_native_dialog_message("title", 5, "body", 4);
    if (rc != 0) {
      bad(name, "返回码不是 0");
    }
  }
  finish(name, before);
}

/* confirm：GTK_RESPONSE_YES 才算同意。两条分开验——只验一条的话，"非 NO 即同意"
 * 那种写法（把 CANCEL/DELETE 也算成是）照样绿。 */
static void t_dialog_confirm_yes(void) {
  const char *name =
      "dialog_confirm：选「是」返回 1（只有 YES 算同意）";
  int before = g_fail;
  int rc;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  if (moonui_native_auto_dismiss_dialog(0, 0) != 0) {
    bad(name, "装自动应答失败（index=0 是合法值）");
  } else {
    rc = moonui_native_dialog_confirm("title", 5, "sure?", 5);
    if (rc != 1) {
      bad(name, "返回码不是 1（选了「是」却不算同意）");
    }
  }
  finish(name, before);
}

static void t_dialog_confirm_no(void) {
  const char *name = "dialog_confirm：选「否」返回 0（不是 -1，取消与失败要分开）";
  int before = g_fail;
  int rc;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  if (moonui_native_auto_dismiss_dialog(0, 1) != 0) {
    bad(name, "装自动应答失败（index=1 是 confirm 的合法值）");
  } else {
    rc = moonui_native_dialog_confirm("title", 5, "sure?", 5);
    if (rc != 0) {
      bad(name, "返回码不是 0（把「否」报成了失败或同意）");
    }
  }
  finish(name, before);
}

/* 文案不是合法 UTF-8 → -1（"文案没能交给系统"），不许弹一个空对话框冒充成功。
 * 这条不弹窗，所以不需要自动应答。 */
static void t_dialog_bad_utf8(void) {
  const char *name = "dialog 文案不是合法 UTF-8 时报 -1（不谎报成功）";
  int before = g_fail;
  /* 0xFF 在 UTF-8 里是非法起始字节。 */
  if (moonui_native_dialog_message("t", 1, "\xff", 1) != -1) {
    bad(name, "message 没有报 -1");
  }
  if (moonui_native_dialog_confirm("t", 1, "\xff", 1) != -1) {
    bad(name, "confirm 没有报 -1");
  }
  if (moonui_native_open_file("\xff", 1) != -1) {
    bad(name, "open_file 的标题不是合法 UTF-8 时没有报 -1");
  }
  finish(name, before);
}

/* 越界的按钮序号在**装的那一步**就报回去：留到运行时"什么也没按下"是一条挂住的
 * 测试，不是一条红的。 */
static void t_dialog_dismiss_bounds(void) {
  const char *name = "auto_dismiss_dialog：越界 index 当场报 -1";
  int before = g_fail;
  if (moonui_native_auto_dismiss_dialog(10, 2) != -1) {
    bad(name, "index=2 没有报 -1");
  }
  if (moonui_native_auto_dismiss_dialog(10, -1) != -1) {
    bad(name, "index=-1 没有报 -1");
  }
  finish(name, before);
}

/* 文件面板取消：auto_answer 替按取消之后，open_file 返回 0（取消），file_dialog_path
 * 取到空 bytes。
 *
 * **这里只验取消侧**，不验"取走即清"：取走语义只有在 accept 之后（result 里真放了
 * 一条路径）才有东西可取，而 accept 在本平台的 public API 上做不到（见
 * dialogs_gtk.inc 的 auto_answer_file_dialog）。取消路径上 result 恒为 NULL，所以
 * "第二次取走是否为空"这条判据在这条路上**不可观测**——改坏取走逻辑它照样绿。
 * 与其留一条假装在验的判据，不如把边界写在这里：取走即清由代码与 Linux 真机的
 * accept 路径（P8，走真实用户操作）保证。 */
static void t_file_dialog_cancel(void) {
  const char *name =
      "open_file：自动应答取消返回 0、路径为空（真 GtkFileChooserNative）";
  int before = g_fail;
  char *p;
  if (!file_panel_ready()) {
    skip(name, "缺 GSettings schema（内置文件面板一 show 就 g_error，见本组头注）");
    return;
  }
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  if (moonui_native_auto_answer_file_dialog(0, NULL, 0, 0) != 0) {
    bad(name, "装自动取消失败");
  } else if (moonui_native_open_file("title", 5) != 0) {
    bad(name, "取消没有返回 0（取消与失败必须分开）");
  } else {
    p = dlg_bytes_dup(moonui_native_file_dialog_path());
    if (p == NULL || p[0] != '\0') {
      bad(name, "取消之后路径不是空包");
    }
    free(p);
  }
  finish(name, before);
}

/* 三种形态都要能开、能取消——save 带默认名（走 set_current_name 那一支），
 * select_folder 走 SELECT_FOLDER 动作。只验 open 的话，"save 拼错 action 导致面板
 * 以打开文件的形态弹出"这类错就漏了。 */
static void t_file_dialog_save_folder(void) {
  const char *name = "save_file（带默认名）/ select_folder 也能开、能取消";
  int before = g_fail;
  if (!file_panel_ready()) {
    skip(name, "缺 GSettings schema（内置文件面板一 show 就 g_error，见本组头注）");
    return;
  }
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  if (moonui_native_auto_answer_file_dialog(0, NULL, 0, 0) != 0) {
    bad(name, "装自动取消失败（save）");
  } else if (moonui_native_save_file("t", 1, "out.txt", 7) != 0) {
    bad(name, "save_file 取消没有返回 0");
  }
  if (moonui_native_auto_answer_file_dialog(0, NULL, 0, 0) != 0) {
    bad(name, "装自动取消失败（folder）");
  } else if (moonui_native_select_folder("t", 1) != 0) {
    bad(name, "select_folder 取消没有返回 0");
  }
  finish(name, before);
}

/* auto_answer 的合法/非法形态：接受这一支在 4.24 的 public API 上做不到，如实报 -2
 * （与 mac 那半结论相同、理由不同）；接受但没给路径报 -1；取消报 0。 */
static void t_auto_answer_codes(void) {
  const char *name = "auto_answer_file_dialog：接受报 -2、空路径报 -1、取消报 0";
  int before = g_fail;
  if (moonui_native_auto_answer_file_dialog(10, "/tmp/x", 6, 0) != 0) {
    bad(name, "取消形态没有返回 0");
  }
  if (moonui_native_auto_answer_file_dialog(10, NULL, 0, 1) != -1) {
    bad(name, "接受但 path 为空没有报 -1");
  }
  if (moonui_native_auto_answer_file_dialog(10, "/tmp/x", 6, 1) != -2) {
    bad(name, "接受形态没有如实报 -2（本平台替按不到接受）");
  }
  finish(name, before);
}

/* ---- P6-4：菜单栏与上下文菜单（真 GTK4 真跑）----
 *
 * 这一组的判据读的都是**原生侧**，不是我们自己的账：
 *   - menu_dump 从 gtk_popover_menu_bar_get_menu_model 读，也就是真正挂在窗口上
 *     那个模型（只抄自己那份名字的话，"addItem 那一步整段删掉"照样能绿）；
 *   - 点击走 GActionGroup 的 activate_action，与用户点菜单项同一条派发；
 *   - 窗口结构用 gtk_window_get_child / first_child / next_sibling 真读。
 *
 * 菜单栏的容器结构（GtkBox[bar, overlay]）也在这组钉住：它是"客户区少一行"这件事
 * 的落点，结构一歪，content_size 的补偿就跟着歪。
 */

typedef struct {
  unsigned char buf[1024];
  int len;
} MenuBlob;

static void mb_u8(MenuBlob *b, int v) {
  if (b->len < (int)sizeof(b->buf)) b->buf[b->len] = (unsigned char)(v & 0xFF);
  b->len++;
}
static void mb_i32(MenuBlob *b, int v) {
  mb_u8(b, v);
  mb_u8(b, v >> 8);
  mb_u8(b, v >> 16);
  mb_u8(b, v >> 24);
}
static void mb_str(MenuBlob *b, const char *s) {
  int n = (int)strlen(s);
  int i;
  mb_i32(b, n);
  for (i = 0; i < n; ++i) mb_u8(b, (unsigned char)s[i]);
}
static void mb_item(MenuBlob *b, const char *label, int id, int role, int checked,
                    int enabled, int has_sc, int mods, const char *key) {
  mb_u8(b, 0);
  mb_str(b, label);
  mb_i32(b, id);
  mb_u8(b, role);
  mb_u8(b, checked);
  mb_u8(b, enabled);
  mb_u8(b, has_sc);
  if (has_sc) {
    mb_u8(b, mods);
    mb_str(b, key);
  }
}

/* File{New(Ctrl+Q), Auto(勾着), —, Off(禁用), More{Sub}}; Edit{A(单选勾着)} */
static void build_menu_tree(MenuBlob *b) {
  b->len = 0;
  mb_u8(b, 1);
  mb_i32(b, 2);
  /* menu 0：File */
  mb_str(b, "File");
  mb_i32(b, 5);
  mb_item(b, "New", 10, 0, 0, 1, 1, 1, "q");
  mb_item(b, "Auto", 11, 1, 1, 1, 0, 0, NULL);
  mb_u8(b, 1); /* 分隔线 */
  mb_item(b, "Off", 12, 0, 0, 0, 0, 0, NULL);
  mb_u8(b, 2); /* 子菜单 */
  mb_str(b, "More");
  mb_i32(b, 1);
  mb_item(b, "Sub", 13, 0, 0, 1, 0, 0, NULL);
  /* menu 1：Edit */
  mb_str(b, "Edit");
  mb_i32(b, 1);
  mb_item(b, "A", 20, 2, 1, 1, 0, 0, NULL);
}

/* 上下文菜单：Ctx{One(30), Two(31)}（一行两条，方便按 index 选）。 */
static void build_ctx_tree(MenuBlob *b) {
  b->len = 0;
  mb_u8(b, 1);
  mb_i32(b, 1);
  mb_str(b, "Ctx");
  mb_i32(b, 2);
  mb_item(b, "One", 30, 0, 0, 1, 0, 0, NULL);
  mb_item(b, "Two", 31, 0, 0, 1, 0, 0, NULL);
}

static int g_menu_click_id;
static int g_menu_click_count;

/* 客户区高度（ABI 回报值，pack2 的低 32 位）。
 *
 * 菜单栏那一行在 ABI 上有**两个**可观测口径：设尺寸时补进窗口请求值（+h），读回时
 * 从请求值里减出来（-h）。所以这条判据能从外面看见结构，不必去摸 GtkWidget——
 * 这个文件只 include adapter.h，没有 GTK 头（P6-1 那几条控件判据同理，全走 ABI）。
 * 两个口径合起来也正好把"量出来的高度"与"补进去的值必须是同一个数"钉住。 */
static int content_h(moonui_ptr win) {
  return (int)(moonui_native_window_content_size(win) & 0xFFFFFFFF);
}

/* T241（2026-11-10）：window_new 与 content_size / dpi 必须是同一套缩放口径。
 * ABI 的尺寸是物理像素：window_new(320,240) 之后立刻读回就该是 320x240，
 * 2x 屏上读成 640x480 就是「建窗按 1x、读回按 2x」那处老 bug（system_dpi
 * 同时谎报 96 而 window_dpi 报 192）。
 * 这条在 1x 的 xvfb 上平凡绿（1 是恒等），牙齿由本机 2x 屏真跑与
 * mock-gtk-selftest.c 第 15 组的注入判据给；两边合起来才盖住两种宿主。 */
static void t_window_new_scale_roundtrip(void) {
  const char *name = "T241：window_new / content_size / dpi 同一缩放口径（物理像素往返）";
  int before = g_fail;
  char d[256];
  moonui_ptr win;
  int64_t sz;
  int w, h, sd, wd;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  win = moonui_native_window_new("scale", 5, 320, 240);
  if (win == 0) {
    bad(name, "窗口造不出来");
    return;
  }
  sz = moonui_native_window_content_size(win);
  w = (int)(sz >> 32);
  h = (int)(sz & 0xFFFFFFFFLL);
  if (w != 320 || h != 240) {
    snprintf(d, sizeof(d),
             "window_new(320,240) 读回 %dx%d，期望 320x240（物理像素）", w, h);
    bad(name, d);
  }
  sd = moonui_native_system_dpi();
  wd = moonui_native_window_dpi(win);
  if (sd <= 0 || sd != wd) {
    snprintf(d, sizeof(d),
             "system_dpi=%d 与 window_dpi=%d 不同口径（期望相等且 > 0）", sd, wd);
    bad(name, d);
  }
  /* 只在未上屏的窗口上验「设完再读回」：上屏后 GTK 会保留已分配的尺寸，
   * set_content_size 改的是请求值，那是另一笔账（P6-4 的菜单栏判据绕开它）。 */
  moonui_native_window_set_content_size(win, 200, 160);
  sz = moonui_native_window_content_size(win);
  w = (int)(sz >> 32);
  h = (int)(sz & 0xFFFFFFFFLL);
  if (w != 200 || h != 160) {
    snprintf(d, sizeof(d),
             "set_content_size(200,160) 读回 %dx%d，期望 200x160", w, h);
    bad(name, d);
  }
  moonui_native_window_destroy(win);
  finish(name, before);
}

static void on_menu_click(void *closure, int id) {
  (void)closure;
  g_menu_click_id = id;
  ++g_menu_click_count;
}

static const char *menu_dump_str(void) {
  return dlg_bytes_dup(moonui_native_menu_dump());
}

static void t_menu_install_dump(void) {
  const char *name =
      "set_menu_bar：装进真窗口，menu_dump 与树一致（勾选/禁用/组合/子菜单/分隔）";
  const char *want =
      "File{#10:n.e:New:Cq,#11:c+e:Auto:.,-,#12:n.d:Off:.,+More{#13:n.e:Sub:.}};"
      "Edit{#20:r+e:A:.}";
  int before = g_fail;
  MenuBlob b;
  moonui_ptr win;
  char *got;
  char *tops;
  int h0;
  int h_bar;
  int h_set;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  win = moonui_native_window_new("w", 1, 320, 240);
  if (win == 0) {
    bad(name, "窗口造不出来");
    return;
  }
  /* T241 修好之后 window_new 与 content_size 同口径，基准可以直接量。
   * 以前这里要先走一次 set_content_size 绕开「建窗按 1x、读回按 2x」的
   * 不一致（2x 屏上 window_new(320,240) 曾报回 480，set 之后才是 240）；
   * 那行绕开会把口径倒退抹平，所以删掉，让这条判据也盯住同一处根因。 */
  h0 = content_h(win);
  g_menu_click_count = 0;
  build_menu_tree(&b);
  if (moonui_native_set_menu_bar((const char *)b.buf, b.len, on_menu_click,
                                 NULL) != 0) {
    bad(name, "set_menu_bar 返回非 0");
  } else {
    got = (char *)menu_dump_str();
    if (got == NULL || strcmp(got, want) != 0) {
      printf("       got  = %s\n       want = %s\n", got ? got : "(null)", want);
      bad(name, "menu_dump 与树不一致");
    }
    free(got);
    tops = dlg_bytes_dup(moonui_native_menu_tops_dump());
    if (tops == NULL || tops[0] != '\0') {
      bad(name, "menu_tops_dump 在 Linux 上应当是空（没有应用菜单这个概念）");
    }
    free(tops);
    /* 客户区真的让出了一行（菜单栏挂在窗口上，高度是 gtk_widget_measure 量的
     * 真值）：回报值于是比请求值少那一行。 */
    h_bar = content_h(win);
    if (h0 - h_bar <= 0) {
      printf("       h0 = %d  h_bar = %d\n", h0, h_bar);
      bad(name, "装上菜单栏之后客户区没有变矮（bar 没挂上，或高度被量成 0）");
    }
    /* 再设一次内容尺寸：补进去的与减出来的必须是同一个数，所以回报值要回到 h0。
     * 少了"补"那一步就是 h0 - 一行（= h_bar），少了"减"那一步就是 h0 + 一行。 */
    moonui_native_window_set_content_size(win, 320, 240);
    h_set = content_h(win);
    if (h_set != h0) {
      printf("       h0 = %d  h_bar = %d  h_set = %d\n", h0, h_bar, h_set);
      bad(name, "设了内容尺寸 240 之后回报的不是 240（菜单栏那一行没补进窗口请求值）");
    }
  }
  moonui_native_window_destroy(win);
  finish(name, before);
}

static void t_menu_set_checked(void) {
  const char *name = "menu_item_set_checked：推勾选真的落到原生动作上（unknown 报 -1）";
  int before = g_fail;
  MenuBlob b;
  moonui_ptr win;
  char *got;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  win = moonui_native_window_new("w", 1, 320, 240);
  if (win == 0) {
    bad(name, "窗口造不出来");
    return;
  }
  build_menu_tree(&b);
  if (moonui_native_set_menu_bar((const char *)b.buf, b.len, on_menu_click,
                                 NULL) != 0) {
    bad(name, "set_menu_bar 返回非 0");
  } else if (moonui_native_menu_item_set_checked(11, 0) != 0) {
    bad(name, "推 check 项的新状态失败");
  } else {
    got = (char *)menu_dump_str();
    if (got == NULL || strstr(got, "#11:c-e:Auto") == NULL) {
      bad(name, "dump 里 Auto 没有变成没勾（c-）");
    }
    free(got);
    if (moonui_native_menu_item_set_checked(999, 1) != -1) {
      bad(name, "不存在的 id 没有报 -1");
    }
    /* Normal 项没有状态：允许推、报"找到了"（与 mac 半同一口径），不改任何东西。 */
    if (moonui_native_menu_item_set_checked(10, 1) != 0) {
      bad(name, "Normal 项推勾选没有报 0");
    }
  }
  moonui_native_window_destroy(win);
  finish(name, before);
}

static void t_menu_click(void) {
  const char *name = "menu_click_item：走真 GAction（禁用项 -2、不存在的 -1）";
  int before = g_fail;
  MenuBlob b;
  moonui_ptr win;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  win = moonui_native_window_new("w", 1, 320, 240);
  if (win == 0) {
    bad(name, "窗口造不出来");
    return;
  }
  build_menu_tree(&b);
  if (moonui_native_set_menu_bar((const char *)b.buf, b.len, on_menu_click,
                                 NULL) != 0) {
    bad(name, "set_menu_bar 返回非 0");
  } else {
    g_menu_click_id = -1;
    g_menu_click_count = 0;
    if (moonui_native_menu_click_item(10) != 0) {
      bad(name, "点正常项没有返回 0");
    } else if (g_menu_click_count != 1 || g_menu_click_id != 10) {
      bad(name, "点击回调没有带回正确的 id");
    }
    if (moonui_native_menu_click_item(12) != -2) {
      bad(name, "禁用项没有报 -2（那就等于绕过置灰真派发了）");
    }
    if (moonui_native_menu_click_item(999) != -1) {
      bad(name, "不存在的 id 没有报 -1");
    }
  }
  moonui_native_window_destroy(win);
  finish(name, before);
}

static void t_menu_uninstall(void) {
  const char *name = "拆菜单（空树）：菜单栏真的摘掉，客户区回到整窗";
  int before = g_fail;
  MenuBlob b;
  moonui_ptr win;
  moonui_ptr base; /* 基准：装菜单之前建的、尺寸相同的窗口 */
  moonui_ptr win2;
  char *got;
  int h_base;
  int h_win0;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  win = moonui_native_window_new("w", 1, 320, 240);
  if (win == 0) {
    bad(name, "窗口造不出来");
    return;
  }
  /* 菜单栏是**进程全局**的：上一组装过的那一棵到现在还挂在所有窗口上，连新窗口
   * 都被钩子补了一行。所以先把基准恢复成"没有菜单"，否则下面两个基准值都偏一行
   * （实测 h_win0 读到 432 而不是 480）。 */
  b.len = 0;
  mb_u8(&b, 1);
  mb_i32(&b, 0);
  if (moonui_native_set_menu_bar((const char *)b.buf, b.len, on_menu_click,
                                 NULL) != 0) {
    bad(name, "清空残留菜单失败");
    moonui_native_window_destroy(win);
    finish(name, before);
    return;
  }
  h_win0 = content_h(win);
  /* 基准窗口要在**装菜单之前**建：它的客户区就是"没有菜单栏"那个数。拿它跟后来
   * 新建的窗口比，比的是同一个代码路径，缩放因子的差别（window_new 与
   * content_size 各按自己的口径除/乘）不会混进来。 */
  base = moonui_native_window_new("b", 1, 200, 160);
  if (base == 0) {
    bad(name, "基准窗口造不出来");
    moonui_native_window_destroy(win);
    return;
  }
  h_base = content_h(base);
  moonui_native_window_destroy(base);
  build_menu_tree(&b);
  if (moonui_native_set_menu_bar((const char *)b.buf, b.len, on_menu_click,
                                 NULL) != 0) {
    bad(name, "set_menu_bar 返回非 0");
  } else {
    /* 装过菜单之后新建的窗口要自动补上（钩子那条路）：同样 200x160，客户区比
     * 基准少一行，就是"补上了"的铁证。 */
    win2 = moonui_native_window_new("w2", 2, 200, 160);
    if (win2 == 0) {
      bad(name, "第二个窗口造不出来");
    } else {
      if (content_h(win2) >= h_base) {
        printf("       base = %d  win2 = %d\n", h_base, content_h(win2));
        bad(name, "装过菜单之后新建的窗口没有补上菜单栏（客户区没让出一行）");
      }
      moonui_native_window_destroy(win2);
    }
    b.len = 0;
    mb_u8(&b, 1);
    mb_i32(&b, 0);
    if (moonui_native_set_menu_bar((const char *)b.buf, b.len, on_menu_click,
                                   NULL) != 0) {
      bad(name, "拆菜单（menu_count=0）返回非 0");
    } else {
      /* 空树 = 没有菜单栏：客户区回到建窗口时那个数，dump 也变空。
       *
       * 这条钉的是"空树真的把旧菜单换下去了"（旧树留着的话两个都红）。它**不**
       * 钉"空 bar 没有挂上去"：一只没有条目的 GtkPopoverMenuBar 高度实测是 0，
       * 挂不挂客户区都一样（负控制验过），所以别在这条上加那个说法。 */
      if (content_h(win) != h_win0) {
        printf("       h_win0 = %d  now = %d\n", h_win0, content_h(win));
        bad(name, "拆掉菜单之后客户区没回到整窗（旧菜单还挂着？）");
      }
      got = (char *)menu_dump_str();
      if (got == NULL || got[0] != '\0') {
        bad(name, "拆掉菜单之后 dump 不是空");
      }
      free(got);
    }
  }
  moonui_native_window_destroy(win);
  finish(name, before);
}

static void t_menu_context(void) {
  const char *name = "上下文菜单：替按第 2 项派发真回调；index=-1 只关不派发";
  int before = g_fail;
  MenuBlob b;
  moonui_ptr win;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  win = moonui_native_window_new("w", 1, 320, 240);
  if (win == 0) {
    bad(name, "窗口造不出来");
    return;
  }
  build_ctx_tree(&b);
  g_menu_click_id = -1;
  g_menu_click_count = 0;
  if (moonui_native_auto_pick_context_menu(0, 1) != 0) {
    bad(name, "装替按失败");
  } else if (moonui_native_show_context_menu((const char *)b.buf, b.len,
                                             on_menu_click, NULL) != 0) {
    bad(name, "show_context_menu 返回非 0");
  } else if (g_menu_click_count != 1 || g_menu_click_id != 31) {
    bad(name, "替按第 2 项没有派发 id 31（回调没跑到或跑错项）");
  }
  /* -1 = 点空白关掉：必须不派发。 */
  g_menu_click_count = 0;
  if (moonui_native_auto_pick_context_menu(0, -1) != 0) {
    bad(name, "装\"点空白\"失败");
  } else if (moonui_native_show_context_menu((const char *)b.buf, b.len,
                                             on_menu_click, NULL) != 0) {
    bad(name, "点空白那一次 show_context_menu 返回非 0");
  } else if (g_menu_click_count != 0) {
    bad(name, "点空白也派发了回调");
  }
  if (moonui_native_auto_pick_context_menu(0, -2) != -1) {
    bad(name, "越界 index（-2）没有当场报 -1");
  }
  if (moonui_native_show_context_menu("abc", 3, on_menu_click, NULL) != -1) {
    bad(name, "树太短没有报 -1");
  }
  moonui_native_window_destroy(win);
  finish(name, before);
}

/* ==================== P6-4b：系统外观 + 样式下发（真 GTK4 对象层） ====================
 * 这一层读的是 GTK 自己的对象：
 *   - system_theme 的输入由 g_object_set 改真 GtkSettings，期望值是硬编码的 1/0；
 *   - CSS 读 gtk_css_provider_to_string，那是 GTK 的 CSS 解析器**规范化后**的文本
 *     （我们写 12.000px，它输出 12px），不是实现自己那份待办账；
 *   - class 挂载读 gtk_widget_get_css_classes；provider 有没有真挂到 display 由
 *     **样式级联**验（往实现那只 provider 追加 color 规则，读同款 class 的
 *     GtkLabel 算出来的颜色；只看 provider 自己的 CSS 文本会漏掉这一层）。
 * 证不了的：背景/圆角**上屏后的像素**（要排版+渲染，只有 Linux 真机 + xvfb），
 * 以及 Label/Button 的前景色与字号（P6-5 才造得出这两类控件，见 TODO）。
 * ==================================================================================== */

typedef struct {
  gboolean prefer_dark;
  char *theme_name;
  int scheme;
  int has_scheme;
} ThemeSettingsBackup;

/* 枚举值按 **nick** 查（实现按 name 查），两套查法互为对拍；不硬编码 2/3。 */
static int theme_enum_by_nick(GObject *obj, const char *prop, const char *nick) {
  GParamSpec *ps = g_object_class_find_property(G_OBJECT_GET_CLASS(obj), prop);
  GEnumClass *ec;
  GEnumValue *v;
  int out = -1;
  if (ps == NULL || !G_IS_PARAM_SPEC_ENUM(ps)) return -1;
  ec = (GEnumClass *)g_type_class_ref(G_PARAM_SPEC_VALUE_TYPE(ps));
  if (ec != NULL) {
    v = g_enum_get_value_by_nick(ec, nick);
    if (v != NULL) out = v->value;
    g_type_class_unref(ec);
  }
  return out;
}

static void theme_settings_save(ThemeSettingsBackup *b) {
  GtkSettings *s = gtk_settings_get_default();
  memset(b, 0, sizeof(*b));
  if (s == NULL) return;
  g_object_get(s, "gtk-application-prefer-dark-theme", &b->prefer_dark,
               "gtk-theme-name", &b->theme_name, NULL);
  b->has_scheme = g_object_class_find_property(
      G_OBJECT_GET_CLASS(s), "gtk-interface-color-scheme") != NULL;
  if (b->has_scheme)
    g_object_get(s, "gtk-interface-color-scheme", &b->scheme, NULL);
}

static void theme_settings_restore(const ThemeSettingsBackup *b) {
  GtkSettings *s = gtk_settings_get_default();
  if (s == NULL) return;
  if (b->has_scheme)
    g_object_set(s, "gtk-interface-color-scheme", b->scheme, NULL);
  g_object_set(s, "gtk-application-prefer-dark-theme", b->prefer_dark,
               "gtk-theme-name", b->theme_name, NULL);
  g_free(b->theme_name);
}

static void t_theme_system_dark(void) {
  const char *name = "system_theme：读真 GtkSettings，两代属性与主题名都可 A/B";
  int before = g_fail;
  ThemeSettingsBackup b;
  GtkSettings *s;
  int dark_v = -1, light_v = -1, default_v = -1;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  s = gtk_settings_get_default();
  if (s == NULL) {
    skip(name, "拿不到 GtkSettings");
    return;
  }
  theme_settings_save(&b);
  if (b.has_scheme) {
    dark_v = theme_enum_by_nick(G_OBJECT(s), "gtk-interface-color-scheme", "dark");
    light_v = theme_enum_by_nick(G_OBJECT(s), "gtk-interface-color-scheme", "light");
    default_v = theme_enum_by_nick(G_OBJECT(s), "gtk-interface-color-scheme", "default");
    if (dark_v < 0 || light_v < 0 || default_v < 0) {
      bad(name, "枚举 nick 查不到 dark/light/default");
      theme_settings_restore(&b);
      return;
    }
  }

  /* GTK 4.24 会把两代属性**联动**：设 prefer-dark=TRUE → scheme=DARK，
   * FALSE → scheme=LIGHT（2026-11-09 探针实测）。而实现按"新属性明确
   * DARK/LIGHT 优先"处理，所以每次改完老属性/主题名之后都要把 scheme 显式
   * 复位成 default，才能测到 4.6 那条**回落**分支；探针另证"先设 pref、再设
   * scheme=default"两者可以共存。不复位的话，theme-name 那两条会被 LIGHT
   * 抢先返回 0，看起来像实现漏读 theme-name。 */
  g_object_set(s, "gtk-application-prefer-dark-theme", FALSE,
               "gtk-theme-name", "Adwaita", NULL);
  if (b.has_scheme) g_object_set(s, "gtk-interface-color-scheme", default_v, NULL);
  if (moonui_native_system_theme() != 0) bad(name, "全浅却报深色");

  /* 4.6 真机唯一的读口：prefer-dark */
  g_object_set(s, "gtk-application-prefer-dark-theme", TRUE, NULL);
  if (b.has_scheme) g_object_set(s, "gtk-interface-color-scheme", default_v, NULL);
  if (moonui_native_system_theme() != 1)
    bad(name, "prefer-dark=TRUE 没读到深色（4.6 真机走这条）");

  /* theme-name 的 :dark：探针实测它不会联动 prefer-dark，必须单独读 */
  g_object_set(s, "gtk-application-prefer-dark-theme", FALSE,
               "gtk-theme-name", "Adwaita:dark", NULL);
  if (b.has_scheme) g_object_set(s, "gtk-interface-color-scheme", default_v, NULL);
  if (moonui_native_system_theme() != 1)
    bad(name, "theme-name 的 :dark 漏报");
  g_object_set(s, "gtk-theme-name", "ADWAITA-Dark", NULL);
  if (b.has_scheme) g_object_set(s, "gtk-interface-color-scheme", default_v, NULL);
  if (moonui_native_system_theme() != 1)
    bad(name, "theme-name 的 DARK 大小写没归一");

  if (b.has_scheme) {
    /* 4.20+ 明确 DARK（scheme 最后设，别被联动覆盖） */
    g_object_set(s, "gtk-application-prefer-dark-theme", FALSE, NULL);
    g_object_set(s, "gtk-interface-color-scheme", dark_v, NULL);
    if (moonui_native_system_theme() != 1)
      bad(name, "color-scheme=DARK 没读到深色");
    /* 明确 LIGHT 时不能被老属性盖掉（优先级的钉子） */
    g_object_set(s, "gtk-application-prefer-dark-theme", TRUE, NULL);
    g_object_set(s, "gtk-interface-color-scheme", light_v, NULL);
    if (moonui_native_system_theme() != 0)
      bad(name, "color-scheme=LIGHT 被 prefer-dark 盖掉了");
  }
  theme_settings_restore(&b);
  finish(name, before);
}

static int has_style_class(GtkWidget *w) {
  char **classes = gtk_widget_get_css_classes(w);
  int i, found = 0;
  for (i = 0; classes != NULL && classes[i] != NULL; ++i) {
    if (strncmp(classes[i], "moonui-w-", 9) == 0) found = 1;
  }
  g_strfreev(classes);
  return found;
}

static void t_theme_panel_css(void) {
  const char *name = "widget_set_style：Panel 的 CSS 真挂上 GTK，-1 哨兵不动旧值";
  int before = g_fail;
  moonui_ptr c;
  GtkWidget *w;
  GtkCssProvider *prov;
  char *css;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  c = moonui_native_widget_new(17, "", 0);
  if (c == 0) {
    bad(name, "Panel 造不出来");
    return;
  }
  w = (GtkWidget *)(uintptr_t)c;
  if (moonui_native_widget_set_style(c, RGB(10, 20, 30), -1, 7250, -1, -1) != 0)
    bad(name, "set_style 返回非 0");
  if (!has_style_class(w))
    bad(name, "widget 上找不到 moonui-w-* CSS class");

  /* 拿到的是实现借出的真 GtkCssProvider；to_string 是 GTK 解析器规范化后的文本。 */
  prov = (GtkCssProvider *)g_object_get_data(G_OBJECT(w),
                                             "moonui-gtk-css-provider");
  if (prov == NULL) {
    bad(name, "拿不到 provider（样式没落到 GTK 对象上）");
  } else {
    css = gtk_css_provider_to_string(prov);
    if (css == NULL || strstr(css, "background-color: rgb(10,20,30)") == NULL)
      bad(name, "GTK 解析后没有背景色 rgb(10,20,30)");
    if (css == NULL || strstr(css, "7.25px") == NULL)
      bad(name, "GTK 解析后没有 7.25px 圆角（7250 permille）");
    if (css != NULL && strstr(css, "\n  color:") != NULL)
      bad(name, "Panel 不该消费 fg 通道");
    if (css != NULL && strstr(css, "font-size") != NULL)
      bad(name, "Panel 不该消费 font 通道");
    g_free(css);

    /* 增量下发：只改 radius，其余全 -1，bg 必须还在（"这一项不动"的钉子）。 */
    if (moonui_native_widget_set_style(c, -1, -1, 12000, -1, -1) != 0)
      bad(name, "增量 set_style 返回非 0");
    css = gtk_css_provider_to_string(prov);
    if (css == NULL || strstr(css, "background-color: rgb(10,20,30)") == NULL)
      bad(name, "-1 哨兵把旧背景色弄丢了");
    if (css == NULL || strstr(css, "12px") == NULL)
      bad(name, "新的 12000 permille 没落到 12px 圆角");
    g_free(css);
  }
  moonui_native_widget_destroy(c);
  finish(name, before);
}

/* P6-4b：provider 是否**真挂到 display**。
 * 上面那条读的是 provider 自己的 CSS 文本（是原生 GTK 对象，但没证"挂上了"）：
 * 若有人把 add_provider_for_display 删掉，to_string 与 css class 两条照样绿。
 * 这里改用 GTK 的样式**级联**观察：往实现那只 provider 里追加一条 color 规则，
 * 再新建一只带同款 class 的 GtkLabel，读它 style context 算出来的颜色。
 * 没挂到 display 就永远走默认色——这条会红，而且红在真实 GTK 对象上。
 * 探针（/tmp/p64b-probe.c）实测：无显示器、未排版时 get_color 也能读到
 * display 级 provider 的级联结果，plain label 是 1,1,1。 */
static void t_theme_provider_on_display(void) {
  const char *name = "widget_set_style：provider 真挂到 display（样式级联读得到）";
  int before = g_fail;
  moonui_ptr c;
  GtkWidget *w, *probe, *plain;
  GtkCssProvider *prov;
  char cls[64] = "";
  char **classes;
  char *orig, *patched;
  GdkRGBA got_probe, got_plain;
  int i;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  c = moonui_native_widget_new(17, "", 0);
  if (c == 0) {
    bad(name, "Panel 造不出来");
    return;
  }
  w = (GtkWidget *)(uintptr_t)c;
  if (moonui_native_widget_set_style(c, RGB(1, 2, 3), -1, 1000, -1, -1) != 0)
    bad(name, "set_style 返回非 0");
  prov = (GtkCssProvider *)g_object_get_data(G_OBJECT(w),
                                             "moonui-gtk-css-provider");
  classes = gtk_widget_get_css_classes(w);
  for (i = 0; classes != NULL && classes[i] != NULL; ++i) {
    if (strncmp(classes[i], "moonui-w-", 9) == 0) {
      snprintf(cls, sizeof(cls), "%s", classes[i]);
      break;
    }
  }
  g_strfreev(classes);
  if (prov == NULL || cls[0] == '\0') {
    bad(name, "拿不到 provider 或 class（样式根本没落到 GTK 对象上）");
  } else {
    orig = gtk_css_provider_to_string(prov);
    patched = g_strconcat(orig != NULL ? orig : "", ".", cls,
                          " { color: rgb(11,22,33); }\n", NULL);
    gtk_css_provider_load_from_data(prov, patched, -1);

    probe = gtk_label_new("probe");
    plain = gtk_label_new("probe");
    g_object_ref_sink(probe);
    g_object_ref_sink(plain);
    gtk_widget_add_css_class(probe, cls);
    gtk_style_context_get_color(gtk_widget_get_style_context(probe), &got_probe);
    gtk_style_context_get_color(gtk_widget_get_style_context(plain), &got_plain);

    /* rgb(11,22,33) → 0.043 / 0.086 / 0.129，误差带各 ±0.01。 */
    if (got_probe.red < 0.035 || got_probe.red > 0.055 ||
        got_probe.green < 0.078 || got_probe.green > 0.098 ||
        got_probe.blue < 0.121 || got_probe.blue > 0.141) {
      char d[160];
      snprintf(d, sizeof(d),
               "级联读到的不是 rgb(11,22,33)：实际 %.3f,%.3f,%.3f",
               got_probe.red, got_probe.green, got_probe.blue);
      bad(name, d);
    }
    /* 对照组：没挂 class 的 label 不该被这条规则染到；否则我们读到的可能
     * 只是全局默认色恰好撞上，判据就又变成"看不出差别"了。 */
    if (got_plain.red > 0.035 && got_plain.red < 0.055 &&
        got_plain.green > 0.078 && got_plain.green < 0.098 &&
        got_plain.blue > 0.121 && got_plain.blue < 0.141)
      bad(name, "没挂 class 的对照 label 也被染成同一个颜色");

    g_object_unref(probe);
    g_object_unref(plain);
    /* 复原：让实现自己重灌一次 CSS，别把探针追加的颜色留给后续判据。 */
    moonui_native_widget_set_style(c, -1, -1, -1, -1, -1);
    g_free(patched);
    g_free(orig);
  }
  moonui_native_widget_destroy(c);
  finish(name, before);
}

static void t_theme_kind_guard(void) {
  const char *name = "widget_set_style：不认识的 kind 静默忽略，空句柄报 -1";
  int before = g_fail;
  moonui_ptr c;
  GtkWidget *w;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  if (moonui_native_widget_set_style(0, RGB(1, 2, 3), RGB(4, 5, 6),
                                    1000, 14000, 2) != -1)
    bad(name, "空句柄没报 -1");
  c = moonui_native_widget_new(18, "", 0); /* Custom：不在三处消费面里 */
  if (c == 0) {
    bad(name, "Custom 造不出来");
    return;
  }
  w = (GtkWidget *)(uintptr_t)c;
  if (moonui_native_widget_set_style(c, RGB(1, 2, 3), RGB(4, 5, 6),
                                    1000, 14000, 2) != 0)
    bad(name, "Custom 不该返回非 0");
  if (has_style_class(w))
    bad(name, "Custom 被偷偷挂了 CSS class");
  if (g_object_get_data(G_OBJECT(w), "moonui-gtk-css-provider") != NULL)
    bad(name, "Custom 被偷偷建了 provider");
  moonui_native_widget_destroy(c);
  finish(name, before);
}

/* ==================== P6-4c：无障碍（真 GTK4 对象层） ====================
 * 尺子是 GTK 自己那份账（不是实现自己的待办账）：
 *   - role 读 gtk_accessible_get_accessible_role（期望值写死成 GTK 常量）；
 *   - LABEL / DESCRIPTION / CHECKED 用 gtk_test_accessible_check_property/state，
 *     它返回的字符串就是 GTK 的 AT context 里的**实际值**（"undefined" /
 *     "false" / 旧文本），错误信息里期望与实际都有，不会只报一边的空话；
 *   - DISABLED / HIDDEN 也用同一把尺子，验的是「实现没把重排快照盖到 GTK 的
 *     活值上」（T58 定案：set_sensitive / set_visible 一改 GTK 自己就跟随）。
 * 证不了的：AT-SPI 消费端 / 真人听朗读、4.6 真机上属性不存在时的回落（那半在
 * 假头闸第 11 组逐分支钉住）、Tab 链真遍历（P8 xvfb 真窗）。
 * ==================================================================================== */

static const char *a11y_tri_name(GtkAccessibleTristate t) {
  if (t == GTK_ACCESSIBLE_TRISTATE_TRUE) return "TRUE";
  if (t == GTK_ACCESSIBLE_TRISTATE_FALSE) return "FALSE";
  return "MIXED";
}

/* want=NULL 表示「这个属性应该是 undefined」。 */
static void a11y_prop(moonui_ptr c, GtkAccessibleProperty prop,
                      const char *want, const char *name, const char *what) {
  char *got = gtk_test_accessible_check_property(
      GTK_ACCESSIBLE((GtkWidget *)(uintptr_t)c), prop, want);
  if (got != NULL) {
    char d[256];
    snprintf(d, sizeof(d), "%s：期望 %s，实际 %s", what,
             want != NULL ? want : "(undefined)", got);
    bad(name, d);
    g_free(got);
  }
}

static void a11y_checked(moonui_ptr c, GtkAccessibleTristate want,
                         const char *name, const char *what) {
  char *got = gtk_test_accessible_check_state(
      GTK_ACCESSIBLE((GtkWidget *)(uintptr_t)c),
      GTK_ACCESSIBLE_STATE_CHECKED, want);
  if (got != NULL) {
    char d[256];
    snprintf(d, sizeof(d), "%s：期望 %s，实际 %s", what, a11y_tri_name(want), got);
    bad(name, d);
    g_free(got);
  }
}

static void a11y_bool_state(moonui_ptr c, GtkAccessibleState st, gboolean want,
                            const char *name, const char *what) {
  char *got = gtk_test_accessible_check_state(
      GTK_ACCESSIBLE((GtkWidget *)(uintptr_t)c), st, want);
  if (got != NULL) {
    char d[256];
    snprintf(d, sizeof(d), "%s：期望 %s，实际 %s", what,
             want ? "true" : "false", got);
    bad(name, d);
    g_free(got);
  }
}

static void a11y_role(moonui_ptr c, GtkAccessibleRole want,
                      const char *name, const char *what) {
  GtkAccessibleRole got = gtk_accessible_get_accessible_role(
      GTK_ACCESSIBLE((GtkWidget *)(uintptr_t)c));
  if (got != want) {
    char d[160];
    snprintf(d, sizeof(d), "%s：期望 role %d，实际 %d", what, (int)want, (int)got);
    bad(name, d);
  }
}

/* role=2 CheckBox / state=0x0B（visible+enabled+已勾）全量下发，读 GTK 的账。 */
static void t_a11y_semantics(void) {
  const char *name = "set_widget_accessibility：role/LABEL/DESCRIPTION/CHECKED 真落到 GTK";
  int before = g_fail;
  moonui_ptr c, other;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  c = moonui_native_widget_new(17, "", 0);
  other = moonui_native_widget_new(17, "", 0);
  if (c == 0 || other == 0) {
    bad(name, "Panel 造不出来");
    if (c != 0) moonui_native_widget_destroy(c);
    if (other != 0) moonui_native_widget_destroy(other);
    return;
  }
  if (moonui_native_set_widget_accessibility(c, 2, "登录按钮", 12,
                                             "点它提交表单", 18, 0x0B) != 0)
    bad(name, "全量下发没返回 0");
  a11y_role(c, GTK_ACCESSIBLE_ROLE_CHECKBOX, name, "role=2 应落 CHECKBOX");
  a11y_prop(c, GTK_ACCESSIBLE_PROPERTY_LABEL, "登录按钮", name, "LABEL（CJK 12 字节）");
  a11y_prop(c, GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, "点它提交表单", name,
            "DESCRIPTION（CJK 18 字节）");
  a11y_checked(c, GTK_ACCESSIBLE_TRISTATE_TRUE, name, "state 0x0B 的 checked=2");
  /* 对照组：另一只控件不该继承这一只的语义。 */
  a11y_prop(other, GTK_ACCESSIBLE_PROPERTY_LABEL, NULL, name,
            "另一只 Panel 的 LABEL 应 undefined");
  a11y_role(other, GTK_ACCESSIBLE_ROLE_GENERIC, name,
            "另一只 Panel 的 role 应仍是 GENERIC");
  if (moonui_native_set_widget_accessibility(0, 1, "x", 1, "y", 1, 0) != -1)
    bad(name, "空句柄没报 -1");
  moonui_native_widget_destroy(c);
  moonui_native_widget_destroy(other);
  finish(name, before);
}

/* 按 (ptr,len) 复制、空串清属性、未知 role 不丢整轮、两只控件互不污染。 */
static void t_a11y_text_edges(void) {
  const char *name = "set_widget_accessibility：按长度复制 / 空串清空 / 未知 role / 多控件隔离";
  int before = g_fail;
  moonui_ptr c, other;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  c = moonui_native_widget_new(17, "", 0);
  other = moonui_native_widget_new(17, "", 0);
  if (c == 0 || other == 0) {
    bad(name, "Panel 造不出来");
    if (c != 0) moonui_native_widget_destroy(c);
    if (other != 0) moonui_native_widget_destroy(other);
    return;
  }
  /* 内嵌 NUL：只取前 12 字节，尾巴不许漏进 LABEL。 */
  if (moonui_native_set_widget_accessibility(c, 99, "登录按钮\0尾巴ABCDEF", 12,
                                             "点它提交表单", 18, 0x08) != 0)
    bad(name, "内嵌 NUL 那次没返回 0");
  a11y_prop(c, GTK_ACCESSIBLE_PROPERTY_LABEL, "登录按钮", name,
            "LABEL 只应到 NUL 前的 12 字节");
  a11y_prop(c, GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, "点它提交表单", name,
            "DESCRIPTION 应同时下发");
  a11y_role(c, GTK_ACCESSIBLE_ROLE_GENERIC, name,
            "未知 role 99 不该改 widget 默认角色");

  /* 空 label 要清成 undefined，desc 换新值，checked 从 TRUE 翻 FALSE。 */
  if (moonui_native_set_widget_accessibility(c, 1, "", 0, "新描述", 9, 0x04) != 0)
    bad(name, "空串那次没返回 0");
  a11y_prop(c, GTK_ACCESSIBLE_PROPERTY_LABEL, NULL, name,
            "空 LABEL 应被 reset 成 undefined（不能留旧名字）");
  a11y_prop(c, GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, "新描述", name,
            "DESCRIPTION 应换成新描述");
  a11y_role(c, GTK_ACCESSIBLE_ROLE_BUTTON, name, "role=1 应落 BUTTON");
  a11y_checked(c, GTK_ACCESSIBLE_TRISTATE_FALSE, name, "checked=1 应落 FALSE");

  /* 给另一只下发，第一只不许被染到。 */
  if (moonui_native_set_widget_accessibility(other, 5, "另一个", 9,
                                             "别的描述", 12, 0) != 0)
    bad(name, "第二只控件下发没返回 0");
  a11y_prop(other, GTK_ACCESSIBLE_PROPERTY_LABEL, "另一个", name,
            "第二只的 LABEL");
  a11y_prop(c, GTK_ACCESSIBLE_PROPERTY_LABEL, NULL, name,
            "第一只的 LABEL 不该跟着变");
  a11y_prop(c, GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, "新描述", name,
            "第一只的 DESCRIPTION 不该跟着变");
  a11y_role(other, GTK_ACCESSIBLE_ROLE_LIST, name, "role=5 应落 LIST");
  moonui_native_widget_destroy(c);
  moonui_native_widget_destroy(other);
  finish(name, before);
}

/* state 的 bit0/bit1 不许注记：GTK 自己按 sensitive/visible 活算 DISABLED/HIDDEN。
 * 两条反向 A/B 都能区分「注记了快照」与「留给 GTK 活值」——只测一条会假绿。 */
static void t_a11y_state_alive(void) {
  const char *name = "set_widget_accessibility：DISABLED/HIDDEN 留给 GTK 活值，CHECKED 三档跟随";
  int before = g_fail;
  moonui_ptr c;
  GtkWidget *w;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  c = moonui_native_widget_new(17, "", 0);
  if (c == 0) {
    bad(name, "Panel 造不出来");
    return;
  }
  w = (GtkWidget *)(uintptr_t)c;
  gtk_widget_set_sensitive(w, TRUE);
  /* state 说 disabled（bit1=0），但控件活值是 enabled：注记快照会让 DISABLED 变 true。 */
  if (moonui_native_set_widget_accessibility(c, 2, "x", 1, "y", 1, 0x00) != 0)
    bad(name, "第一次下发没返回 0");
  a11y_bool_state(c, GTK_ACCESSIBLE_STATE_DISABLED, FALSE, name,
                  "state bit1=0 但 widget sensitive 时 DISABLED 应仍 false");

  /* 反过来：state 说 enabled（bit1=1），但控件活值 disabled。 */
  gtk_widget_set_sensitive(w, FALSE);
  if (moonui_native_set_widget_accessibility(c, 2, "x", 1, "y", 1, 0x02) != 0)
    bad(name, "第二次下发没返回 0");
  a11y_bool_state(c, GTK_ACCESSIBLE_STATE_DISABLED, TRUE, name,
                  "state bit1=1 但 widget insensitive 时 DISABLED 应仍 true");
  gtk_widget_set_sensitive(w, TRUE);

  /* CHECKED 三档 + reset（0 表示"无此态"，不是"未勾"）。 */
  moonui_native_set_widget_accessibility(c, 2, "x", 1, "y", 1, 0x04);
  a11y_checked(c, GTK_ACCESSIBLE_TRISTATE_FALSE, name, "checked=1 → FALSE");
  moonui_native_set_widget_accessibility(c, 2, "x", 1, "y", 1, 0x08);
  a11y_checked(c, GTK_ACCESSIBLE_TRISTATE_TRUE, name, "checked=2 → TRUE");
  moonui_native_set_widget_accessibility(c, 2, "x", 1, "y", 1, 0x0C);
  a11y_checked(c, GTK_ACCESSIBLE_TRISTATE_MIXED, name, "checked=3 → MIXED");
  moonui_native_set_widget_accessibility(c, 2, "x", 1, "y", 1, 0x00);
  if (gtk_test_accessible_has_state(GTK_ACCESSIBLE(w),
                                    GTK_ACCESSIBLE_STATE_CHECKED))
    bad(name, "checked=0 之后 CHECKED 应被 reset，实际还有这个 state");
  moonui_native_widget_destroy(c);
  finish(name, before);
}

/* 两条进程级偏好：真 GtkSettings 上 A/B。contrast 与 color-scheme / prefer-dark /
 * theme-name 都不联动（2026-11-09 探针实测），所以不必像 P6-4b 那样复位 scheme。 */
static void t_a11y_preferences(void) {
  const char *name = "无障碍偏好：真 GtkSettings 的动画开关与两代高对比读口 A/B";
  int before = g_fail;
  GtkSettings *s;
  GParamSpec *ps;
  gboolean anim0 = FALSE, ok_init;
  char *theme0 = NULL, *icon0 = NULL;
  int contrast0 = 0, more = -1, less = -1, no_pref = -1, unsupported = -1;

  ok_init = (moonui_native_init() == 0);
  if (!ok_init) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  s = gtk_settings_get_default();
  if (s == NULL) {
    skip(name, "拿不到 GtkSettings");
    return;
  }
  g_object_get(s, "gtk-enable-animations", &anim0,
               "gtk-theme-name", &theme0,
               "gtk-icon-theme-name", &icon0, NULL);
  ps = g_object_class_find_property(G_OBJECT_GET_CLASS(s),
                                    "gtk-interface-contrast");
  if (ps != NULL) {
    g_object_get(s, "gtk-interface-contrast", &contrast0, NULL);
    /* 判据按 **nick** 查，实现按 GEnum **name** 查，两套查法互为对拍。 */
    more = theme_enum_by_nick(G_OBJECT(s), "gtk-interface-contrast", "more");
    less = theme_enum_by_nick(G_OBJECT(s), "gtk-interface-contrast", "less");
    no_pref = theme_enum_by_nick(G_OBJECT(s), "gtk-interface-contrast",
                                 "no-preference");
    unsupported = theme_enum_by_nick(G_OBJECT(s), "gtk-interface-contrast",
                                     "unsupported");
  }

  /* 干净基线：动画开、两个主题名普通、contrast 没表态。 */
  g_object_set(s, "gtk-enable-animations", TRUE,
               "gtk-theme-name", "Adwaita",
               "gtk-icon-theme-name", "Adwaita", NULL);
  if (ps != NULL && no_pref >= 0)
    g_object_set(s, "gtk-interface-contrast", no_pref, NULL);

  g_object_set(s, "gtk-enable-animations", FALSE, NULL);
  if (moonui_native_prefers_reduced_motion() != 1)
    bad(name, "关掉 gtk-enable-animations 后 reduced_motion 应为 1");
  g_object_set(s, "gtk-enable-animations", TRUE, NULL);
  if (moonui_native_prefers_reduced_motion() != 0)
    bad(name, "打开 gtk-enable-animations 后 reduced_motion 应为 0");

  if (ps != NULL) {
    if (more < 0 || less < 0 || no_pref < 0 || unsupported < 0) {
      bad(name, "contrast 枚举 nick 查不齐 more/less/no-preference/unsupported");
    } else {
      g_object_set(s, "gtk-interface-contrast", more, NULL);
      if (moonui_native_prefers_high_contrast() != 1)
        bad(name, "明确 MORE（普通主题名）时 high_contrast 应为 1");

      g_object_set(s, "gtk-theme-name", "HighContrast", NULL);
      g_object_set(s, "gtk-interface-contrast", less, NULL);
      if (moonui_native_prefers_high_contrast() != 0)
        bad(name, "明确 LESS 应压过主题名里的 HighContrast");

      g_object_set(s, "gtk-interface-contrast", no_pref, NULL);
      if (moonui_native_prefers_high_contrast() != 1)
        bad(name, "NO_PREFERENCE 应回落到 gtk-theme-name=HighContrast");

      g_object_set(s, "gtk-theme-name", "Adwaita", NULL);
      g_object_set(s, "gtk-icon-theme-name", "Adwaita-High-Contrast", NULL);
      g_object_set(s, "gtk-interface-contrast", unsupported, NULL);
      if (moonui_native_prefers_high_contrast() != 1)
        bad(name, "UNSUPPORTED 应回落到 icon theme 的 High-Contrast");

      g_object_set(s, "gtk-icon-theme-name", "Adwaita", NULL);
      if (moonui_native_prefers_high_contrast() != 0)
        bad(name, "两个主题名都普通时 high_contrast 应为 0");
    }
  }

  /* 复原，别把偏好留给后面几组判据。 */
  if (ps != NULL) g_object_set(s, "gtk-interface-contrast", contrast0, NULL);
  g_object_set(s, "gtk-enable-animations", anim0,
               "gtk-theme-name", theme0 != NULL ? theme0 : "Default",
               "gtk-icon-theme-name", icon0 != NULL ? icon0 : "Adwaita", NULL);
  g_free(theme0);
  g_free(icon0);
  finish(name, before);
}

/* 自绘面焦点 opt-in：只对 kind 18 生效，别的控件空操作、空句柄报 -1。 */
static void t_a11y_focusable(void) {
  const char *name = "custom_set_focusable：自绘面进焦点体系，别的控件空操作";
  int before = g_fail;
  moonui_ptr custom, panel;
  GtkWidget *wc, *wp;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  custom = moonui_native_widget_new(18, "", 0);
  panel = moonui_native_widget_new(17, "", 0);
  if (custom == 0 || panel == 0) {
    bad(name, "Custom / Panel 造不出来");
    if (custom != 0) moonui_native_widget_destroy(custom);
    if (panel != 0) moonui_native_widget_destroy(panel);
    return;
  }
  wc = (GtkWidget *)(uintptr_t)custom;
  wp = (GtkWidget *)(uintptr_t)panel;
  if (moonui_native_custom_set_focusable(custom, 1) != 0)
    bad(name, "Custom 设置没返回 0");
  if (!gtk_widget_get_focusable(wc))
    bad(name, "Custom 期望 focusable=TRUE，实际 FALSE");
  if (moonui_native_custom_set_focusable(custom, 0) != 0)
    bad(name, "Custom 关闭没返回 0");
  if (gtk_widget_get_focusable(wc))
    bad(name, "Custom 期望 focusable=FALSE，实际 TRUE");
  if (moonui_native_custom_set_focusable(panel, 1) != 0)
    bad(name, "Panel 空操作应返回 0");
  if (gtk_widget_get_focusable(wp))
    bad(name, "Panel 不该被设成 focusable（契约：空操作）");
  if (moonui_native_custom_set_focusable(0, 1) != -1)
    bad(name, "空句柄没报 -1");
  moonui_native_widget_destroy(custom);
  moonui_native_widget_destroy(panel);
  finish(name, before);
}

/* ==================== P6-5：控件叶子（真 GTK4 对象层） ====================
 * 尺子一律是 GTK 自己的读数（gtk_label_get_text / gtk_button_get_label /
 * gtk_check_button_get_active / gtk_editable_get_text / gtk_entry_get_placeholder_text
 * / G_OBJECT_TYPE_NAME），不是实现存过的那份账。回调那组用 g_signal_emit_by_name
 * 驱动 GTK 的信号：这能证"注册与接线"，不等于真人上屏点击（P8 xvfb 真窗）。
 * ==================================================================================== */

static int g_leaf_clicks = 0, g_leaf_clicks2 = 0;
static int g_leaf_texts = 0, g_leaf_toggles = 0;
static void leaf_cb_click(void *cl) { (void)cl; g_leaf_clicks += 1; }
static void leaf_cb_click2(void *cl) { (void)cl; g_leaf_clicks2 += 1; }
static void leaf_cb_text(void *cl) { (void)cl; g_leaf_texts += 1; }
static void leaf_cb_toggle(void *cl) { (void)cl; g_leaf_toggles += 1; }

/* widget_text 返回的是 MoonBit Bytes：长度要从对象头读，只 strcmp 会漏掉
 * "少抄/多抄几个字节"（判据口径见 criteria.md）。 */
static void leaf_text_is(moonui_ptr h, const char *want, const char *name,
                         const char *what) {
  moonbit_bytes_t b = moonui_native_widget_text(h);
  char *got = dlg_bytes_dup(b);
  int n = (b == NULL) ? -1 : (int)Moonbit_array_length(b);
  char d[256];
  if (got == NULL) {
    bad(name, "widget_text 返回 NULL（ABI 要给空 Bytes，不能给空指针）");
    return;
  }
  if (strcmp(got, want) != 0 || n != (int)strlen(want)) {
    snprintf(d, sizeof(d), "%s：期望 [%s] / %d 字节，实际 [%s] / %d 字节",
             what, want, (int)strlen(want), got, n);
    bad(name, d);
  }
  free(got);
}

static const char *leaf_native_text(moonui_ptr h, int kind) {
  GtkWidget *w = (GtkWidget *)(uintptr_t)h;
  switch (kind) {
    case 0:  return gtk_label_get_text(GTK_LABEL(w));
    case 1:  return gtk_button_get_label(GTK_BUTTON(w));
    case 3:  return gtk_check_button_get_label(GTK_CHECK_BUTTON(w));
    default: return gtk_editable_get_text(GTK_EDITABLE(w));
  }
}

static void t_leaf_text(void) {
  const char *name = "P6-5 文案：五个通道按 (ptr,len) 往返，占位不混进文本";
  int before = g_fail;
  static const int kinds[] = {0, 1, 2, 3, 4};
  int i;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  for (i = 0; i < 5; ++i) {
    moonui_ptr h = moonui_native_widget_new(kinds[i], "初值", 6);
    const char *native;
    char d[192];
    if (h == 0) {
      bad(name, "文本类控件造不出来");
      continue;
    }
    leaf_text_is(h, "初值", name, "构造时的初值");
    /* 内嵌 NUL：Core 给的是字节串，按长度复制后 C 串截断在前段。 */
    moonui_native_widget_set_text(h, "AB\0CD", 5);
    leaf_text_is(h, "AB", name, "内嵌 NUL 只取前 5 字节的前段");
    /* 同一件事再用 GTK 自己的 getter 对拍一次，防实现读的是自己那份账。 */
    native = leaf_native_text(h, kinds[i]);
    if (native == NULL || strcmp(native, "AB") != 0) {
      snprintf(d, sizeof(d), "kind %d 的 GTK getter 读到 [%s]，期望 [AB]",
               kinds[i], native != NULL ? native : "(null)");
      bad(name, d);
    }
    moonui_native_widget_set_text(h, "", 0);
    leaf_text_is(h, "", name, "空串清空");
    moonui_native_widget_set_text(h, NULL, 0);
    leaf_text_is(h, "", name, "NULL / 0 长度也清空");
    moonui_native_widget_destroy(h);
  }
  /* 非文本类：文案通道是空操作，读回空包（不能把别的东西当文案念出来）。 */
  {
    moonui_ptr img = moonui_native_widget_new(16, "", 0);
    moonui_ptr panel = moonui_native_widget_new(17, "", 0);
    moonui_native_widget_set_text(img, "不该进去", 12);
    moonui_native_widget_set_text(panel, "不该进去", 12);
    leaf_text_is(img, "", name, "Image 不消费文案");
    leaf_text_is(panel, "", name, "Panel 不消费文案");
    leaf_text_is(0, "", name, "空句柄给空包");
    moonui_native_widget_destroy(img);
    moonui_native_widget_destroy(panel);
  }
  finish(name, before);
}

static void t_leaf_placeholder(void) {
  const char *name = "P6-5 占位：TextInput / PasswordInput 各落各的，且不动文本";
  int before = g_fail;
  moonui_ptr e, p, l;
  GtkWidget *we, *wp;
  char *hint = NULL;
  const char *got;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  e = moonui_native_widget_new(2, "", 0);
  p = moonui_native_widget_new(4, "", 0);
  l = moonui_native_widget_new(0, "文字", 6);
  if (e == 0 || p == 0 || l == 0) {
    bad(name, "输入框 / Label 造不出来");
    return;
  }
  we = (GtkWidget *)(uintptr_t)e;
  wp = (GtkWidget *)(uintptr_t)p;
  moonui_native_widget_set_placeholder(e, "请输入", 9);
  got = gtk_entry_get_placeholder_text(GTK_ENTRY(we));
  if (got == NULL || strcmp(got, "请输入") != 0)
    bad(name, "GtkEntry 的 placeholder-text 不是 [请输入]");
  leaf_text_is(e, "", name, "设占位不能混进 widget_text");
  moonui_native_widget_set_placeholder(e, "", 0);
  got = gtk_entry_get_placeholder_text(GTK_ENTRY(we));
  if (got != NULL && got[0] != 0)
    bad(name, "空串占位没清掉");
  moonui_native_widget_set_placeholder(p, "密码提示", 12);
  g_object_get(G_OBJECT(wp), "placeholder-text", &hint, NULL);
  if (hint == NULL || strcmp(hint, "密码提示") != 0)
    bad(name, "GtkPasswordEntry 的 placeholder-text 不是 [密码提示]");
  g_free(hint);
  leaf_text_is(p, "", name, "密码框占位也不混进文本");
  moonui_native_widget_set_placeholder(l, "不该生效", 12);
  leaf_text_is(l, "文字", name, "Label 不该消费占位，原文本不能被改掉");
  moonui_native_widget_destroy(e);
  moonui_native_widget_destroy(p);
  moonui_native_widget_destroy(l);
  finish(name, before);
}

static void t_leaf_checked(void) {
  const char *name = "P6-5 勾选：真 GtkCheckButton 的 active 跟随，别的 kind 报 0";
  int before = g_fail;
  moonui_ptr c, l;
  GtkWidget *w;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  c = moonui_native_widget_new(3, "勾", 3);
  l = moonui_native_widget_new(0, "字", 3);
  if (c == 0 || l == 0) {
    bad(name, "Checkbox / Label 造不出来");
    return;
  }
  w = (GtkWidget *)(uintptr_t)c;
  moonui_native_widget_set_checked(c, 1);
  if (moonui_native_widget_checked(c) != 1 ||
      !gtk_check_button_get_active(GTK_CHECK_BUTTON(w)))
    bad(name, "set_checked(1) 之后 active 应为 TRUE");
  moonui_native_widget_set_checked(c, 0);
  if (moonui_native_widget_checked(c) != 0 ||
      gtk_check_button_get_active(GTK_CHECK_BUTTON(w)))
    bad(name, "set_checked(0) 之后 active 应为 FALSE");
  moonui_native_widget_set_checked(c, 2);
  if (moonui_native_widget_checked(c) != 1)
    bad(name, "非 0 就是勾上（Bool 口径），读回应是 1");
  moonui_native_widget_set_checked(l, 1);
  if (moonui_native_widget_checked(l) != 0)
    bad(name, "Label 不该有勾选态");
  moonui_native_widget_destroy(c);
  moonui_native_widget_destroy(l);
  finish(name, before);
}

static void t_leaf_callbacks(void) {
  const char *name = "P6-5 回调：clicked/changed/toggled 接线 + 程序化改值不回声";
  int before = g_fail;
  moonui_ptr b, e, ck, l;
  GtkWidget *wb, *we, *wc;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  g_leaf_clicks = g_leaf_clicks2 = g_leaf_texts = g_leaf_toggles = 0;
  b = moonui_native_widget_new(1, "点", 3);
  e = moonui_native_widget_new(2, "", 0);
  ck = moonui_native_widget_new(3, "勾", 3);
  l = moonui_native_widget_new(0, "字", 3);
  if (b == 0 || e == 0 || ck == 0 || l == 0) {
    bad(name, "叶子控件造不出来");
    return;
  }
  wb = (GtkWidget *)(uintptr_t)b;
  we = (GtkWidget *)(uintptr_t)e;
  wc = (GtkWidget *)(uintptr_t)ck;
  if (moonui_native_widget_on_clicked(b, leaf_cb_click, NULL) != 0)
    bad(name, "Button 装 clicked 回调没返回 0");
  g_signal_emit_by_name(wb, "clicked");
  if (g_leaf_clicks != 1)
    bad(name, "clicked 信号没派发到刚装的回调");
  /* 重复注册只换回调，不是叠加一份（不然一次点击会派发两次）。 */
  if (moonui_native_widget_on_clicked(b, leaf_cb_click2, NULL) != 0)
    bad(name, "重复注册应返回 0（单槽可换人）");
  g_signal_emit_by_name(wb, "clicked");
  if (g_leaf_clicks != 1 || g_leaf_clicks2 != 1)
    bad(name, "重复注册后旧回调还在或新回调没接上");

  if (moonui_native_widget_on_text_changed(e, leaf_cb_text, NULL) != 0)
    bad(name, "TextInput 装 changed 回调没返回 0");
  /* 探针实测：gtk_editable_set_text 会发 changed。ABI 契约要求程序化改值
   * 不回声，inhibit 摘掉这条就红。 */
  moonui_native_widget_set_text(e, "程序化", 9);
  moonui_native_widget_set_placeholder(e, "提示", 6);
  if (g_leaf_texts != 0)
    bad(name, "程序化 set_text / set_placeholder 回声成了 Input");
  g_signal_emit_by_name(we, "changed");
  if (g_leaf_texts != 1)
    bad(name, "真实 changed 信号没派发（inhibit 把正路也吞了）");

  if (moonui_native_widget_on_toggled(ck, leaf_cb_toggle, NULL) != 0)
    bad(name, "Checkbox 装 toggled 回调没返回 0");
  moonui_native_widget_set_checked(ck, 1);
  if (g_leaf_toggles != 0)
    bad(name, "程序化 set_checked 回声成了 Change");
  g_signal_emit_by_name(wc, "toggled");
  if (g_leaf_toggles != 1)
    bad(name, "真实 toggled 信号没派发");

  if (moonui_native_widget_on_clicked(l, leaf_cb_click, NULL) != -1)
    bad(name, "Label 没有点击语义，注册该报 -1");
  if (moonui_native_widget_on_text_changed(b, leaf_cb_text, NULL) != -1)
    bad(name, "Button 没有文本变化语义，注册该报 -1");
  if (moonui_native_widget_on_clicked(0, leaf_cb_click, NULL) != -1)
    bad(name, "空句柄注册该报 -1");
  moonui_native_widget_destroy(b);
  moonui_native_widget_destroy(e);
  moonui_native_widget_destroy(ck);
  moonui_native_widget_destroy(l);
  finish(name, before);
}

/* P6-4b 落地注②留下的缺口：fg / font / weight 三条通道当时只有纯逻辑判据，
 * 因为 widget_new 造不出 Label。现在拿真 GtkLabel 补上：CSS 文本读 GTK 解析器
 * 规范化后的结果，颜色读 GTK 样式级联，字号/字重读 Pango context。 */
static void t_leaf_style(void) {
  const char *name = "P6-5 外观：真 GtkLabel 上 fg / font / weight 三通道落到 GTK";
  int before = g_fail;
  moonui_ptr c;
  GtkWidget *w, *plain;
  GtkCssProvider *prov;
  GtkStyleContext *sc;
  GdkRGBA got, plain_col;
  const PangoFontDescription *fd;
  char *css;
  char d[256];
  int sz, wt;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  c = moonui_native_widget_new(0, "文字", 6);
  if (c == 0) {
    bad(name, "Label 造不出来");
    return;
  }
  w = (GtkWidget *)(uintptr_t)c;
  if (moonui_native_widget_set_style(c, -1, RGB(11, 22, 33), -1, 14000, 2) != 0)
    bad(name, "set_style 返回非 0");
  prov = (GtkCssProvider *)g_object_get_data(G_OBJECT(w),
                                             "moonui-gtk-css-provider");
  if (prov == NULL) {
    bad(name, "真 Label 上没挂 provider");
  } else {
    css = gtk_css_provider_to_string(prov);
    if (css == NULL || strstr(css, "color: rgb(11,22,33)") == NULL)
      bad(name, "GTK 解析后的 CSS 里没有 fg 色 rgb(11,22,33)");
    if (css == NULL || strstr(css, "font-size: 14") == NULL)
      bad(name, "GTK 解析后的 CSS 里没有 14px 字号（14000 permille）");
    if (css == NULL || strstr(css, "font-weight: 700") == NULL)
      bad(name, "GTK 解析后的 CSS 里没有 700 字重（weight=2 Bold）");
    g_free(css);
  }
  /* 级联：provider 挂在 display 级，颜色是 GTK 自己算出来的，不是读 CSS 文本。 */
  plain = gtk_label_new("plain");
  g_object_ref_sink(plain);
  sc = gtk_widget_get_style_context(w);
  gtk_style_context_get_color(sc, &got);
  gtk_style_context_get_color(gtk_widget_get_style_context(plain), &plain_col);
  if (got.red < 0.035 || got.red > 0.055 ||
      got.green < 0.078 || got.green > 0.098 ||
      got.blue < 0.121 || got.blue > 0.141) {
    snprintf(d, sizeof(d), "级联读到的不是 rgb(11,22,33)：实际 %.3f,%.3f,%.3f",
             got.red, got.green, got.blue);
    bad(name, d);
  }
  if (plain_col.red < 0.99 || plain_col.green < 0.99 || plain_col.blue < 0.99)
    bad(name, "对照用的 plain Label 也被染了色（判据失去对照）");
  fd = pango_context_get_font_description(gtk_widget_get_pango_context(w));
  sz = pango_font_description_get_size(fd);
  wt = pango_font_description_get_weight(fd);
  if (sz < 14000 || sz > 15000) {
    snprintf(d, sizeof(d), "Pango 字号期望约 14336（14px × PANGO_SCALE），实际 %d", sz);
    bad(name, d);
  }
  if (wt != 700) {
    snprintf(d, sizeof(d), "Pango 字重期望 700（Bold），实际 %d", wt);
    bad(name, d);
  }
  g_object_unref(plain);
  moonui_native_widget_destroy(c);
  finish(name, before);
}


/* ==================== P6-5b：菜单行 / 滚动 / 自绘面点击 / 焦点链 ====================
 * 真 GTK4 4.24 探针（/tmp/p65b-probe{,2}.c）量出来的形状写进各自注释。
 * 判据一律读 GTK 自己那份对象（类型名 / active / policy / measure / 焦点），
 * 不读实现存过的账；期望值写死在这里。
 */
static int g_p65b_clicks = 0, g_p65b_clicks2 = 0;
static void p65b_cb_click(void *cl) { (void)cl; g_p65b_clicks += 1; }
static void p65b_cb_click2(void *cl) { (void)cl; g_p65b_clicks2 += 1; }

/* 14 MenuRow = GtkToggleButton：文案走 gtk_button_set_label、勾选走
 * gtk_toggle_button_set_active（探针实测 set_active 会发一条 toggled，
 * 所以程序化设置要 inhibit），点击走 clicked；样式与 Button 同一消费面。 */
static void t_p65b_menurow(void) {
  const char *name = "P6-5b MenuRow：文案/勾选/点击/样式在真 GtkToggleButton 上";
  int before = g_fail;
  moonui_ptr c, ck;
  GtkWidget *w;
  GtkCssProvider *prov;
  char *css;
  char d[192];

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  g_p65b_clicks = g_p65b_clicks2 = 0;
  c = moonui_native_widget_new(14, "旧", 3);
  ck = moonui_native_widget_new(3, "勾", 3);
  if (c == 0 || ck == 0) {
    bad(name, "MenuRow / Checkbox 造不出来");
    return;
  }
  w = (GtkWidget *)(uintptr_t)c;

  /* 文案按 (ptr,len) 往返，读 GTK 的 label getter（不是实现的账）。 */
  moonui_native_widget_set_text(c, "中文测试", 12);
  if (gtk_button_get_label(GTK_BUTTON(w)) == NULL ||
      strcmp(gtk_button_get_label(GTK_BUTTON(w)), "中文测试") != 0) {
    snprintf(d, sizeof(d), "文案没落到 GTK：实际 %s",
             gtk_button_get_label(GTK_BUTTON(w)) != NULL
                 ? gtk_button_get_label(GTK_BUTTON(w)) : "NULL");
    bad(name, d);
  }
  moonui_native_widget_set_text(c, "", 0);
  if (moonui_native_widget_text(c) == NULL) bad(name, "空文案读回 NULL");

  /* 勾选：真 active 跟随（GtkToggleButton，不是 GtkCheckButton）。 */
  moonui_native_widget_set_checked(c, 1);
  if (!gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(w)) ||
      moonui_native_widget_checked(c) != 1)
    bad(name, "set_checked(1) 之后 GTK 的 active 或读回不是 1");
  moonui_native_widget_set_checked(c, 0);
  if (gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(w)) ||
      moonui_native_widget_checked(c) != 0)
    bad(name, "set_checked(0) 之后 GTK 的 active 或读回不是 0");

  /* 回调：程序化 set_checked 不回声（set_active 发的是 toggled，clicked
   * 不该被触发），真实 clicked 派发；重复注册只换人。 */
  if (moonui_native_widget_on_clicked(c, p65b_cb_click, NULL) != 0)
    bad(name, "MenuRow 装 clicked 没返回 0");
  moonui_native_widget_set_checked(c, 1);
  if (g_p65b_clicks != 0)
    bad(name, "程序化 set_checked 回声成了 Click");
  g_signal_emit_by_name(w, "clicked");
  if (g_p65b_clicks != 1)
    bad(name, "真实 clicked 没派发到刚装的回调");
  if (moonui_native_widget_on_clicked(c, p65b_cb_click2, NULL) != 0)
    bad(name, "重复注册应返回 0（单槽可换人）");
  g_signal_emit_by_name(w, "clicked");
  if (g_p65b_clicks != 1 || g_p65b_clicks2 != 1)
    bad(name, "重复注册后旧回调还在或新回调没接上");
  /* Core 对 MenuRow 只装 on_clicked（backend.mbt:1274），别给它连 toggled。 */
  if (moonui_native_widget_on_toggled(c, p65b_cb_click, NULL) != -1)
    bad(name, "MenuRow 装 on_toggled 应报 -1（否则一次点击会派发两条）");
  /* Checkbox 的勾选通道没被 14 的分支带歪（P6-5 回归）。 */
  moonui_native_widget_set_checked(ck, 1);
  if (moonui_native_widget_checked(ck) != 1)
    bad(name, "Checkbox 的勾选通道被 MenuRow 分支带歪");

  /* 样式：kind 14 与 Button 同一消费面，CSS 文本读 GTK 解析器规范化后的结果。
   * 护栏是双层的（prelude 的 style_css + theme_gtk.inc 的 kind 判断），
   * 只改一处不会红——负控制里两处一起拆。 */
  if (moonui_native_widget_set_style(c, RGB(1, 2, 3), RGB(4, 5, 6),
                                     7250, 14000, 2) != 0)
    bad(name, "MenuRow 的 set_style 返回非 0");
  prov = (GtkCssProvider *)g_object_get_data(G_OBJECT(w),
                                             "moonui-gtk-css-provider");
  if (prov == NULL) {
    bad(name, "真 MenuRow 上没挂 provider（kind 14 没进消费面）");
  } else {
    css = gtk_css_provider_to_string(prov);
    if (css == NULL || strstr(css, "background-color: rgb(1,2,3)") == NULL)
      bad(name, "MenuRow 的 CSS 里没有底色 rgb(1,2,3)");
    if (css == NULL || strstr(css, "color: rgb(4,5,6)") == NULL)
      bad(name, "MenuRow 的 CSS 里没有前景色 rgb(4,5,6)");
    if (css == NULL || strstr(css, "font-weight: 700") == NULL)
      bad(name, "MenuRow 的 CSS 里没有 700 字重");
    /* GTK 解析器会把 border-radius 展开成四个角，读的是规范化后的文本
     * （P6-4b 同一条：7.250px → 7.25px）。 */
    if (css == NULL ||
        strstr(css, "border-top-left-radius: 7.25px") == NULL) {
      snprintf(d, sizeof(d), "MenuRow 的圆角没落到 CSS（实际 %s）",
               css != NULL ? css : "NULL");
      bad(name, d);
    }
    g_free(css);
  }
  moonui_native_widget_destroy(c);
  moonui_native_widget_destroy(ck);
  finish(name, before);
}

/* 15 Scroll：文档区挂接 + set_bounds 的坐标账 + 两轴滚动行程。 */
static void t_p65b_scroll(void) {
  const char *name = "P6-5b Scroll：文档区挂接 / 坐标账 / 两轴滚动行程";
  int before = g_fail;
  moonui_ptr sc, child;
  GtkWidget *w, *vp, *doc;
  GtkPolicyType hp, vpol;
  int mw = 0, nat = 0, mh = 0, nath = 0, base_w = 0, base_h = 0;
  char d[160];

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  sc = moonui_native_widget_new(15, "", 0);
  child = moonui_native_widget_new(0, "内容", 6);
  if (sc == 0 || child == 0) {
    bad(name, "Scroll / Label 造不出来");
    return;
  }
  w = (GtkWidget *)(uintptr_t)sc;
  vp = gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(w));
  doc = (vp != NULL && GTK_IS_VIEWPORT(vp))
            ? gtk_viewport_get_child(GTK_VIEWPORT(vp)) : NULL;
  if (doc == NULL) {
    bad(name, "Scroll 没有可挂接的文档区");
    return;
  }
  /* container_attach 挂进文档区（不是 ScrolledWindow 自己）。 */
  moonui_native_container_attach(sc, child);
  if (gtk_widget_get_parent((GtkWidget *)(uintptr_t)child) != doc) {
    snprintf(d, sizeof(d), "child 的父级不是文档区，实际 %s",
             gtk_widget_get_parent((GtkWidget *)(uintptr_t)child) != NULL
                 ? G_OBJECT_TYPE_NAME(
                       G_OBJECT(gtk_widget_get_parent((GtkWidget *)(uintptr_t)child)))
                 : "NULL");
    bad(name, d);
  }
  /* 文档区被认成容器之后，set_bounds 才落得下、origin 才读得回。 */
  moonui_native_control_set_bounds(child, 10, 20, 100, 30);
  if (moonui_native_widget_origin(child) != px_pack(10, 20)) {
    snprintf(d, sizeof(d), "文档区里 widget_origin 不是 (10,20)：%lld",
             (long long)moonui_native_widget_origin(child));
    bad(name, d);
  }
  /* axis 0 = Vertical：横向 NEVER、纵向 ALWAYS，行程取 size_request。 */
  moonui_native_scroll_set_content(sc, 0, 640, 1200);
  gtk_scrolled_window_get_policy(GTK_SCROLLED_WINDOW(w), &hp, &vpol);
  if (hp != GTK_POLICY_NEVER || vpol != GTK_POLICY_ALWAYS) {
    snprintf(d, sizeof(d), "axis=0 的 policy 期望 NEVER/ALWAYS，实际 %d/%d",
             (int)hp, (int)vpol);
    bad(name, d);
  }
  gtk_widget_measure(doc, GTK_ORIENTATION_HORIZONTAL, -1,
                     &mw, &nat, NULL, NULL);
  gtk_widget_measure(doc, GTK_ORIENTATION_VERTICAL, -1,
                     &mh, &nath, NULL, NULL);
  if (mw != 640 || mh != 1200) {
    snprintf(d, sizeof(d), "axis=0 的行程期望 640x1200，实际 %dx%d", mw, mh);
    bad(name, d);
  }
  /* axis 1 = Horizontal：横向 AUTOMATIC、纵向 NEVER。 */
  moonui_native_scroll_set_content(sc, 1, 300, 200);
  gtk_scrolled_window_get_policy(GTK_SCROLLED_WINDOW(w), &hp, &vpol);
  if (hp != GTK_POLICY_AUTOMATIC || vpol != GTK_POLICY_NEVER) {
    snprintf(d, sizeof(d), "axis=1 的 policy 期望 AUTOMATIC/NEVER，实际 %d/%d",
             (int)hp, (int)vpol);
    bad(name, d);
  }
  mw = mh = 0;
  gtk_widget_measure(doc, GTK_ORIENTATION_HORIZONTAL, -1,
                     &mw, &nat, NULL, NULL);
  gtk_widget_measure(doc, GTK_ORIENTATION_VERTICAL, -1,
                     &mh, &nath, NULL, NULL);
  if (mw != 300 || mh != 200) {
    snprintf(d, sizeof(d), "axis=1 的行程期望 300x200，实际 %dx%d", mw, mh);
    bad(name, d);
  }
  /* 负尺寸夹到 0。GTK 的 measure 读的是「max(size_request, 子树 natural
   * minimum)」：文档区里挂着一只 Label，请求 0x0 时读回的是那只 Label 的
   * 最小尺寸（本机实测 55x25），不是 0。所以拿 0x0 请求当基线，负尺寸
   * 必须与它逐位相同——否则就是把负数/巨大值喂给了 GTK。 */
  moonui_native_scroll_set_content(sc, 0, 0, 0);
  mw = mh = 0;
  gtk_widget_measure(doc, GTK_ORIENTATION_HORIZONTAL, -1,
                     &mw, &nat, NULL, NULL);
  gtk_widget_measure(doc, GTK_ORIENTATION_VERTICAL, -1,
                     &mh, &nath, NULL, NULL);
  base_w = mw;
  base_h = mh;
  moonui_native_scroll_set_content(sc, 0, -5, -6);
  mw = mh = 0;
  gtk_widget_measure(doc, GTK_ORIENTATION_HORIZONTAL, -1,
                     &mw, &nat, NULL, NULL);
  gtk_widget_measure(doc, GTK_ORIENTATION_VERTICAL, -1,
                     &mh, &nath, NULL, NULL);
  if (mw != base_w || mh != base_h) {
    snprintf(d, sizeof(d),
             "负尺寸没夹到 0（应与 0x0 请求的 %dx%d 相同）：实际 %dx%d",
             base_w, base_h, mw, mh);
    bad(name, d);
  }
  moonui_native_scroll_set_content(sc, 7, 111, 222);
  gtk_scrolled_window_get_policy(GTK_SCROLLED_WINDOW(w), &hp, &vpol);
  if (hp != GTK_POLICY_NEVER || vpol != GTK_POLICY_ALWAYS) {
    bad(name, "未知 axis 不该改滚动策略");
  }
  mw = mh = 0;
  gtk_widget_measure(doc, GTK_ORIENTATION_HORIZONTAL, -1,
                     &mw, &nat, NULL, NULL);
  gtk_widget_measure(doc, GTK_ORIENTATION_VERTICAL, -1,
                     &mh, &nath, NULL, NULL);
  if (mw != 111 || mh != 222) {
    snprintf(d, sizeof(d), "未知 axis 仍该落尺寸 111x222，实际 %dx%d", mw, mh);
    bad(name, d);
  }
  /* 非 Scroll 句柄是空操作：Label 的尺寸请求不该被改。 */
  moonui_native_scroll_set_content(child, 0, 999, 999);
  gtk_widget_measure((GtkWidget *)(uintptr_t)child,
                     GTK_ORIENTATION_HORIZONTAL, -1, &mw, &nat, NULL, NULL);
  if (mw >= 999) bad(name, "非 Scroll 句柄被当成滚动视口改了尺寸");
  moonui_native_widget_destroy(sc);
  moonui_native_widget_destroy(child);
  finish(name, before);
}

/* 自绘面点击：GtkGestureClick 的 pressed/released 真派发 + 原地判定。 */
static void t_p65b_custom_click(void) {
  const char *name = "P6-5b 自绘面点击：按下并原地抬起才派发，拖出/多击不算";
  int before = g_fail;
  moonui_ptr c, lab;
  GtkGesture *g;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  g_p65b_clicks = g_p65b_clicks2 = 0;
  c = moonui_native_widget_new(18, "", 0);
  lab = moonui_native_widget_new(0, "字", 3);
  if (c == 0 || lab == 0) {
    bad(name, "Custom / Label 造不出来");
    return;
  }
  if (moonui_native_custom_on_clicked(c, p65b_cb_click, NULL) != 0)
    bad(name, "Custom 装点击回调没返回 0");
  g = (GtkGesture *)moonui_gtk_probe_gesture_of((GtkWidget *)(uintptr_t)c);
  if (g == NULL) {
    bad(name, "Custom 上没装 GtkGestureClick");
  } else {
    g_signal_emit_by_name(g, "pressed", 1, 10.0, 10.0);
    g_signal_emit_by_name(g, "released", 1, 10.0, 10.0);
    if (g_p65b_clicks != 1)
      bad(name, "原地抬起没派发到回调");
    g_signal_emit_by_name(g, "pressed", 1, 10.0, 10.0);
    g_signal_emit_by_name(g, "released", 1, 40.0, 10.0);
    if (g_p65b_clicks != 1)
      bad(name, "拖出去松手也算了一次点击");
    g_signal_emit_by_name(g, "pressed", 2, 10.0, 10.0);
    g_signal_emit_by_name(g, "released", 1, 10.0, 10.0);
    if (g_p65b_clicks != 1)
      bad(name, "多击（n_press=2）也算了一次点击");
    if (moonui_native_custom_on_clicked(c, p65b_cb_click2, NULL) != 0)
      bad(name, "重复注册应返回 0（单槽可换人）");
    g_signal_emit_by_name(g, "pressed", 1, 10.0, 10.0);
    g_signal_emit_by_name(g, "released", 1, 12.0, 12.0);
    if (g_p65b_clicks != 1 || g_p65b_clicks2 != 1)
      bad(name, "重复注册后旧回调还在或新回调没接上");
  }
  if (moonui_native_custom_on_clicked(lab, p65b_cb_click, NULL) != -1)
    bad(name, "非自绘面装点击回调应报 -1");
  if (moonui_native_custom_on_clicked(0, p65b_cb_click, NULL) != -1)
    bad(name, "空句柄装点击回调应报 -1");
  moonui_native_widget_destroy(c);
  moonui_native_widget_destroy(lab);
  finish(name, before);
}

/* 焦点链：按声明序推进 / 回绕 / Shift 反向；focused_control 沿父链反查
 * （GtkEntry 的焦点落在内部 GtkText，探针实测）。 */
static void t_p65b_focus_chain(void) {
  const char *name = "P6-5b 焦点链：按声明序推进/回绕/反向 + focused_control 沿父链反查";
  int before = g_fail;
  moonui_ptr win, w[3];
  GtkWidget *gw;
  char ids[128];
  char d[160];
  int i;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  win = moonui_native_window_new("focus-chain", 11, 320, 240);
  w[0] = moonui_native_widget_new(2, "", 0);  /* GtkEntry：焦点在内部 GtkText */
  w[1] = moonui_native_widget_new(1, "b", 1);
  w[2] = moonui_native_widget_new(3, "c", 3);
  if (win == 0 || w[0] == 0 || w[1] == 0 || w[2] == 0) {
    bad(name, "窗口或三只控件造不出来");
    return;
  }
  for (i = 0; i < 3; ++i) moonui_native_control_attach(win, w[i]);
  gw = (GtkWidget *)(uintptr_t)win;
  snprintf(ids, sizeof(ids), "%llu %llu %llu",
           (unsigned long long)(uintptr_t)w[0],
           (unsigned long long)(uintptr_t)w[1],
           (unsigned long long)(uintptr_t)w[2]);
  if (moonui_native_set_focus_chain(win, ids, (int)strlen(ids)) != 0)
    bad(name, "set_focus_chain 没返回 0");
  /* 焦点当下不在链上，正向从链首开始；每一步都读 GTK 的焦点状态。 */
  if (moonui_gtk_focus_tab_step(gw, 0) != 1)
    bad(name, "正向 Tab 没接管（空链？）");
  if (moonui_native_focused_control(win) != w[0]) {
    snprintf(d, sizeof(d), "第 1 跳焦点不在链首：实际 %p，期望 %p",
             (void *)(uintptr_t)moonui_native_focused_control(win),
             (void *)(uintptr_t)w[0]);
    bad(name, d);
  }
  if (moonui_gtk_focus_tab_step(gw, 0) != 1 ||
      moonui_native_focused_control(win) != w[1])
    bad(name, "第 2 跳没落到链的第 2 项");
  if (moonui_gtk_focus_tab_step(gw, 0) != 1 ||
      moonui_native_focused_control(win) != w[2])
    bad(name, "第 3 跳没落到链的第 3 项");
  if (moonui_gtk_focus_tab_step(gw, 0) != 1 ||
      moonui_native_focused_control(win) != w[0])
    bad(name, "链尾没有回绕到链首");
  if (moonui_gtk_focus_tab_step(gw, 1) != 1 ||
      moonui_native_focused_control(win) != w[2])
    bad(name, "Shift+Tab 没有反向回绕到链尾");
  /* 空串清空链：交回 GTK 默认 z 序（focus_tab_step 不再接管）。 */
  if (moonui_native_set_focus_chain(win, "", 0) != 0)
    bad(name, "空串清空链没返回 0");
  if (moonui_gtk_focus_tab_step(gw, 0) != 0)
    bad(name, "清链之后 Tab 仍被接管");
  /* 错误码：-1 窗口不真、-3 文本解析失败；窗口不真时 focused_control 报 0。 */
  if (moonui_native_set_focus_chain(0, ids, (int)strlen(ids)) != -1)
    bad(name, "空窗口句柄应报 -1");
  if (moonui_native_set_focus_chain(win, "1 x", 3) != -3)
    bad(name, "非法 ids 文本应报 -3");
  if (moonui_native_focused_control(0) != 0)
    bad(name, "空窗口句柄读焦点应报 0");
  moonui_native_window_destroy(win);
  finish(name, before);
}

/* focus_widget_in_window：按坐标命中 + 回读判定四档返回码。
 * 未上屏窗口的 gtk_widget_pick 恒 NULL（探针实测），所以命中走
 * control_set_bounds 落下的那份逻辑坐标账；真机排版后两者一致。 */
static void t_p65b_focus_widget(void) {
  const char *name = "P6-5b focus_widget_in_window：按坐标命中 + 回读四档返回码";
  int before = g_fail;
  moonui_ptr win, b, lab;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  win = moonui_native_window_new("focus-hit", 9, 320, 240);
  b = moonui_native_widget_new(1, "b", 1);
  lab = moonui_native_widget_new(0, "L", 1);
  if (win == 0 || b == 0 || lab == 0) {
    bad(name, "窗口或控件造不出来");
    return;
  }
  moonui_native_control_attach(win, b);
  moonui_native_control_attach(win, lab);
  moonui_native_control_set_bounds(b, 10, 10, 100, 30);
  moonui_native_control_set_bounds(lab, 10, 50, 100, 30);
  /* 命中 Button → 0，且焦点回读就是它。 */
  if (moonui_native_focus_widget_in_window("focus-hit", 9, 20, 20) != 0)
    bad(name, "命中可聚焦的 Button 没返回 0");
  if (moonui_native_focused_control(win) != b)
    bad(name, "命中后 focused_control 不是那只 Button");
  /* (ptr,len) 按长度截断：尾缀不该混进标题比对。 */
  if (moonui_native_focus_widget_in_window("focus-hitZZZ", 9, 20, 20) != 0)
    bad(name, "标题按 (ptr,len) 截断后没找到窗口");
  /* 命中 focusable=FALSE 的 Label：GTK 不接受焦点，回读判定 -4。 */
  if (moonui_native_focus_widget_in_window("focus-hit", 9, 20, 60) != -4)
    bad(name, "命中拿不了焦点的 Label 应报 -4");
  /* 空白 / 不存在的窗口 / 负坐标。 */
  if (moonui_native_focus_widget_in_window("focus-hit", 9, 300, 200) != -4)
    bad(name, "点在空白处应报 -4");
  if (moonui_native_focus_widget_in_window("no-such-window", 14, 20, 20) != -2)
    bad(name, "不存在的窗口应报 -2");
  if (moonui_native_focus_widget_in_window("focus-hit", 9, -1, 20) != -3)
    bad(name, "负坐标（窗口外）应报 -3");
  moonui_native_window_destroy(win);
  finish(name, before);
}
/* P6-5c：七构造族（kinds 6..12）——**专属构造入口**（adapter.h 508-529），
 * 与 (kind,text) 通用工厂分开（那条会如实回 0，见 t_widget_new_kinds 的 absent 表）。
 * 这组真跑：造出来的真 GTK 类型、值/选项/选中/日期文本的往返、六条 on_* 的 kind
 * 护栏，以及 Slider 的 value-changed 派发与程序化改值不回声。 */
static void t_widget_p65c_controls(void) {
  const char *name = "P6-5c 七构造族：类型/值/选项/选中/日期文本/回调护栏（真 GTK4）";
  int before = g_fail;
  moonui_ptr sl, sp, pr, cb, ml, rd, dp;
  GtkWidget *w;
  char d[224];

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  sl = moonui_native_slider_new(0, 100);
  sp = moonui_native_spinbox_new(0, 100);
  pr = moonui_native_progress_new();
  cb = moonui_native_combobox_new();
  ml = moonui_native_multiline_new();
  rd = moonui_native_radio_new();
  dp = moonui_native_datepicker_new();
  if (sl == 0 || sp == 0 || pr == 0 || cb == 0 || ml == 0 || rd == 0 || dp == 0) {
    bad(name, "七构造族里有造不出来的");
    return;
  }

  /* ---- 构造出的真 GTK 类型（读 GTK 自己那份，不读实现存的 kind）---- */
  {
    struct { moonui_ptr h; const char *type; int kind; } T[] = {
      {sl, "GtkScale", 6},       {sp, "GtkSpinButton", 7},
      {pr, "GtkProgressBar", 8}, {cb, "GtkDropDown", 9},
      {ml, "GtkTextView", 10},   {rd, "GtkBox", 11},
      {dp, "GtkCalendar", 12},
    };
    int i;
    for (i = 0; i < 7; ++i) {
      w = (GtkWidget *)(uintptr_t)T[i].h;
      if (strcmp(G_OBJECT_TYPE_NAME(G_OBJECT(w)), T[i].type) != 0) {
        snprintf(d, sizeof(d), "kind %d 期望 %s，实际 %s", T[i].kind, T[i].type,
                 G_OBJECT_TYPE_NAME(G_OBJECT(w)));
        bad(name, d);
      }
    }
  }
  /* 范围非法的构造必须造不出（libui 同款约束）。 */
  if (moonui_native_slider_new(5, 5) != 0)
    bad(name, "slider_new(min>=max) 应返回 0");
  if (moonui_native_spinbox_new(9, 3) != 0)
    bad(name, "spinbox_new(min>=max) 应返回 0");

  /* ---- Slider：值往返 + 扩范围后仍可设值 ---- */
  w = (GtkWidget *)(uintptr_t)sl;
  moonui_native_widget_set_value(sl, 42);
  if (moonui_native_widget_value(sl) != 42)
    bad(name, "Slider set_value(42) 后 value() 不是 42");
  if (gtk_range_get_value(GTK_RANGE(w)) != 42.0)
    bad(name, "Slider 的 GTK range 值不是 42（没落到 GTK 上）");
  moonui_native_slider_set_range(sl, 0, 200);
  moonui_native_widget_set_value(sl, 150);
  if (moonui_native_widget_value(sl) != 150)
    bad(name, "Slider 扩范围后 set_value(150) 读回不对");

  /* ---- Spinbox：值往返 ---- */
  w = (GtkWidget *)(uintptr_t)sp;
  moonui_native_widget_set_value(sp, 7);
  if (moonui_native_widget_value(sp) != 7)
    bad(name, "Spinbox set_value(7) 后 value() 不是 7");
  if (gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(w)) != 7)
    bad(name, "Spinbox 的 GTK 值不是 7");

  /* ---- Progress：0..100 落 fraction；-1 是不定哨兵（GTK 读不回，靠缓存）---- */
  w = (GtkWidget *)(uintptr_t)pr;
  moonui_native_widget_set_value(pr, 50);
  if (moonui_native_widget_value(pr) != 50)
    bad(name, "Progress set_value(50) 读回不是 50");
  {
    double f = gtk_progress_bar_get_fraction(GTK_PROGRESS_BAR(w));
    if (f < 0.49 || f > 0.51)
      bad(name, "Progress 50% 的 fraction 不在 0.5 附近");
  }
  moonui_native_widget_set_value(pr, -1);
  if (moonui_native_widget_value(pr) != -1)
    bad(name, "Progress set_value(-1) 的不定哨兵没缓存住");

  /* ---- ComboBox：append 三选项、选中往返、-1 无选中 ---- */
  moonui_native_widget_append_option(cb, "甲", 3);
  moonui_native_widget_append_option(cb, "乙", 3);
  moonui_native_widget_append_option(cb, "丙", 3);
  w = (GtkWidget *)(uintptr_t)cb;
  {
    GListModel *m = gtk_drop_down_get_model(GTK_DROP_DOWN(w));
    guint n = (m != NULL) ? g_list_model_get_n_items(m) : 0;
    if (n != 3u) {
      snprintf(d, sizeof(d), "ComboBox 应有 3 个选项，实际 %u", (unsigned)n);
      bad(name, d);
    }
  }
  /* 新建未 set_selected：ABI 是「没选中」→ -1。GtkDropDown 自己默认选 0，这条
   * 钉的正是 combo_has_sel 的跟踪，不是 GTK 的默认值。 */
  if (moonui_native_widget_selected(cb) != -1)
    bad(name, "新建 ComboBox 未选中时应报 -1（不能把 GTK 默认的 0 当选中）");
  moonui_native_widget_set_selected(cb, 2);
  if (moonui_native_widget_selected(cb) != 2)
    bad(name, "ComboBox set_selected(2) 后 selected() 不是 2");
  if (gtk_drop_down_get_selected(GTK_DROP_DOWN(w)) != 2u)
    bad(name, "ComboBox 的 GTK 选中项不是 2");
  moonui_native_widget_set_selected(cb, 0);
  if (moonui_native_widget_selected(cb) != 0)
    bad(name, "ComboBox set_selected(0) 后 selected() 不是 0");
  moonui_native_widget_set_selected(cb, -1);
  if (moonui_native_widget_selected(cb) != -1)
    bad(name, "ComboBox set_selected(-1) 后应报 -1（无选中）");

  /* ---- RadioButtons：append 三选项、选中互斥 ---- */
  moonui_native_widget_append_option(rd, "一", 3);
  moonui_native_widget_append_option(rd, "二", 3);
  moonui_native_widget_append_option(rd, "三", 3);
  if (moonui_native_widget_selected(rd) != -1)
    bad(name, "RadioButtons 未选中时应报 -1");
  moonui_native_widget_set_selected(rd, 1);
  if (moonui_native_widget_selected(rd) != 1)
    bad(name, "Radio set_selected(1) 后 selected() 不是 1");
  moonui_native_widget_set_selected(rd, 2);
  if (moonui_native_widget_selected(rd) != 2)
    bad(name, "Radio set_selected(2) 后 selected() 不是 2（互斥没生效？）");

  /* ---- MultilineEntry：多行文本往返（走 TEXT_VIEW 文案通道）---- */
  {
    const char *mt = "第一行\n第二行";
    GtkTextBuffer *buf;
    GtkTextIter a, b;
    char *got;
    moonui_native_widget_set_text(ml, mt, (int)strlen(mt));
    leaf_text_is(ml, mt, name, "多行文本往返");
    buf = gtk_text_view_get_buffer(GTK_TEXT_VIEW((GtkWidget *)(uintptr_t)ml));
    gtk_text_buffer_get_bounds(buf, &a, &b);
    got = gtk_text_buffer_get_text(buf, &a, &b, FALSE);
    if (got == NULL || strcmp(got, mt) != 0)
      bad(name, "GtkTextView 的 buffer 文本不是多行原文");
    g_free(got);
  }

  /* ---- DatePicker：日期文本往返（时间靠 date_cache，日历只认日期）---- */
  {
    const char *dt = "2026-11-09 13:30:00";
    moonbit_bytes_t bb;
    char *got;
    if (moonui_native_datepicker_set_text(dp, dt, (int)strlen(dt)) != 0)
      bad(name, "datepicker_set_text 合法日期没返回 0");
    bb = moonui_native_datepicker_text(dp);
    got = dlg_bytes_dup(bb);
    if (got == NULL || strcmp(got, dt) != 0) {
      snprintf(d, sizeof(d), "日期文本往返丢了时间：实际 [%s]", got ? got : "(null)");
      bad(name, d);
    }
    free(got);
  }
  if (moonui_native_datepicker_set_text(dp, "not-a-date", 10) != -1)
    bad(name, "datepicker_set_text 非法格式应报 -1");
  if (moonui_native_datepicker_set_text(sl, "2026-11-09", 10) != -2)
    bad(name, "datepicker_set_text 用在非日期控件上应报 -2");

  /* ---- 六个 on_*：kind 护栏（对的 kind → 0，错的 kind → -1）---- */
  if (moonui_native_slider_on_changed(sl, leaf_cb_text, NULL) != 0)
    bad(name, "slider_on_changed 对 Slider 应返回 0");
  if (moonui_native_spinbox_on_changed(sp, leaf_cb_text, NULL) != 0)
    bad(name, "spinbox_on_changed 对 Spinbox 应返回 0");
  if (moonui_native_combobox_on_selected(cb, leaf_cb_text, NULL) != 0)
    bad(name, "combobox_on_selected 对 ComboBox 应返回 0");
  if (moonui_native_radio_on_selected(rd, leaf_cb_text, NULL) != 0)
    bad(name, "radio_on_selected 对 RadioButtons 应返回 0");
  if (moonui_native_multiline_on_changed(ml, leaf_cb_text, NULL) != 0)
    bad(name, "multiline_on_changed 对 MultilineEntry 应返回 0");
  if (moonui_native_datepicker_on_changed(dp, leaf_cb_text, NULL) != 0)
    bad(name, "datepicker_on_changed 对 DatePicker 应返回 0");
  if (moonui_native_slider_on_changed(sp, leaf_cb_text, NULL) != -1)
    bad(name, "slider_on_changed 套到 Spinbox 上应报 -1");
  if (moonui_native_datepicker_on_changed(sl, leaf_cb_text, NULL) != -1)
    bad(name, "datepicker_on_changed 套到 Slider 上应报 -1");
  if (moonui_native_multiline_on_changed(0, leaf_cb_text, NULL) != -1)
    bad(name, "multiline_on_changed 空句柄应报 -1");

  /* ---- Slider value-changed：真实信号派发 + 程序化改值不回声 ---- */
  g_leaf_texts = 0;
  w = (GtkWidget *)(uintptr_t)sl;
  moonui_native_widget_set_value(sl, 10); /* 程序化，inhibit 挡住：不回声 */
  if (g_leaf_texts != 0)
    bad(name, "程序化 set_value 回声成了 change");
  g_signal_emit_by_name(w, "value-changed");
  if (g_leaf_texts != 1)
    bad(name, "真实 value-changed 没派发到刚装的回调");

  moonui_native_widget_destroy(sl);
  moonui_native_widget_destroy(sp);
  moonui_native_widget_destroy(pr);
  moonui_native_widget_destroy(cb);
  moonui_native_widget_destroy(ml);
  moonui_native_widget_destroy(rd);
  moonui_native_widget_destroy(dp);
  finish(name, before);
}

/* P8：真窗判据（T235 收口的那一半）——**上屏之后**才成立的那几条。
 *
 * P6-5b 的焦点判据读的是**未上屏**窗口：能验「焦点按声明链移动」，验不了
 * 「上屏后 GTK 到底给了多大分配」「焦点在真窗上是否还读得到」「GTK 自己的
 * 遍历还走不走得通」。这一条把窗口 present 出去、泵到映射并画出第一帧，再量：
 *   ① mapped=1，窗口按 window_new 的请求拿到 320/scale × 240/scale **逻辑点**
 *      （T241 之后 ABI 请求是物理像素，GTK 分配按逻辑点算；1x 的 xvfb 仍是
 *       320×240，本机 2x 屏是 160×120，两者读回的客户区都该是 320×240）；
 *   ② 上屏前 widget_size 必须是 0、上屏后必须非 0（"还没有版面"与"版面出来了"
 *      两档，正是 adapter.h 那句「未排版时 GTK 量出 0，这不是错」的反面）；
 *   ③ 零内缩的 GtkLabel 报的尺寸**逐像素等于**请求值——这条钉住物理像素口径
 *      的往返（请求走 set_bounds 除 scale、读回走 widget_size 乘 scale）；
 *   ④ GTK 自己的 gtk_widget_child_focus 在真窗上把焦点从前一只挪到后一只、
 *      再挪回来，且 focused_control 每次读到的 owner 都对。
 *
 * **不用 gtk_test_widget_wait_for_draw**：它没有超时，窗口在这个环境里画不出来
 * 时会挂死整道闸——门禁卡死比少一条判据坏得多。这里换成有界泵（最多 2s）。
 *
 * 已知的、**不是**本适配器造成的偏差（4.24 / macOS 实测，纯 GTK 探针
 * /tmp/p8-probe4.c 不带适配器也能复现）：带主题内缩的控件（Button）上屏后
 * `gtk_widget_get_width` 报的是**内容盒**——请求 100×30 时它报 66×24，而
 * `gtk_widget_compute_bounds` 给的版面矩形是 100×34（34 = Adwaita 的
 * min-height）。所以 `widget_size` 对这类控件会小于版面矩形，与 mac / win 的
 * frame 口径不同；X11 上是否同样，要 CI 真跑一次才知道（TODO T235 P8 已记）。
 * 判据因此只钉「非 0」，不钉具体数值——那个数取决于主题内缩。
 */
static void t_p8_real_window(void) {
  const char *name = "P8 真窗：上屏/mapped/分配尺寸/widget_size 真值/GTK 自己的焦点遍历";
  int before = g_fail;
  moonui_ptr win, b1, b2, lab;
  GtkWidget *gw;
  char d[240];
  int scale, i;
  int64_t sz;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  win = moonui_native_window_new("p8-real", 7, 320, 240);
  b1 = moonui_native_widget_new(1, "a", 1);
  b2 = moonui_native_widget_new(1, "b", 1);
  lab = moonui_native_widget_new(0, "L", 1);
  if (win == 0 || b1 == 0 || b2 == 0 || lab == 0) {
    bad(name, "窗口或控件造不出来");
    return;
  }
  scale = moonui_native_window_dpi(win) / 96;
  if (scale < 1) scale = 1;
  moonui_native_control_attach(win, b1);
  moonui_native_control_attach(win, b2);
  moonui_native_control_attach(win, lab);
  /* 坐标与尺寸都是**物理像素**（ABI 口径），这里按实测 scale 换算成 20/60/100
   * 这些整数逻辑点，于是期望值也是整数。 */
  moonui_native_control_set_bounds(b1, 20 * scale, 20 * scale, 100 * scale, 30 * scale);
  moonui_native_control_set_bounds(b2, 20 * scale, 60 * scale, 100 * scale, 30 * scale);
  moonui_native_control_set_bounds(lab, 20 * scale, 100 * scale, 100 * scale, 30 * scale);
  gw = (GtkWidget *)(uintptr_t)win;

  /* ① 上屏前：GTK 还没有版面可言，widget_size 必须是 0。 */
  sz = moonui_native_widget_size(lab);
  if (sz != 0) {
    snprintf(d, sizeof(d), "未上屏就报了尺寸 %lldx%lld（应当是 0）",
             (long long)(sz >> 32), (long long)(sz & 0xFFFFFFFFLL));
    bad(name, d);
  }

  moonui_native_window_show(win);
  for (i = 0; i < 400; ++i) {
    if (gtk_widget_get_mapped(gw) && gtk_widget_get_width(gw) > 0) break;
    g_main_context_iteration(NULL, FALSE);
    g_usleep(5000);
  }
  if (!gtk_widget_get_mapped(gw)) {
    bad(name, "present 之后 2s 内没映射（xvfb / 窗口管理器没起来？）");
    moonui_native_window_destroy(win);
    return;
  }
  /* ② T241：ABI 的请求是物理像素，GTK 的分配是逻辑点。window_new 按 display
   * scale 除过，所以 2x 屏上是 160x120 点，1x 的 xvfb 仍是 320x240。
   * (x + scale/2)/scale 是正数上的四舍五入，与实现里的 llround 同形。 */
  {
    int want_w = (320 + scale / 2) / scale;
    int want_h = (240 + scale / 2) / scale;
    if (gtk_widget_get_width(gw) != want_w ||
        gtk_widget_get_height(gw) != want_h) {
      snprintf(d, sizeof(d),
               "上屏后窗口分配 %dx%d 点，期望 %dx%d 点（scale=%d，物理请求 320x240）",
               gtk_widget_get_width(gw), gtk_widget_get_height(gw),
               want_w, want_h, scale);
      bad(name, d);
    }
  }
  /* 客户区尺寸走「上屏后读真实尺寸」那条分支，物理像素口径：与 window_new
   * 的请求相同，不再乘 scale（乘 scale 是 T241 之前按逻辑点建窗的旧口径）。 */
  sz = moonui_native_window_content_size(win);
  if ((sz >> 32) != 320 || (sz & 0xFFFFFFFFLL) != 240) {
    snprintf(d, sizeof(d), "上屏后客户区 %lldx%lld，期望 320x240（物理像素）",
             (long long)(sz >> 32), (long long)(sz & 0xFFFFFFFFLL));
    bad(name, d);
  }
  /* ③ Label 零内缩：尺寸必须逐像素等于请求值。 */
  sz = moonui_native_widget_size(lab);
  if ((sz >> 32) != 100 * scale || (sz & 0xFFFFFFFFLL) != 30 * scale) {
    snprintf(d, sizeof(d), "上屏后 Label %lldx%lld，期望 %dx%d（物理像素）",
             (long long)(sz >> 32), (long long)(sz & 0xFFFFFFFFLL),
             100 * scale, 30 * scale);
    bad(name, d);
  }
  /* Button 有主题内缩：只钉「不再是 0」。 */
  sz = moonui_native_widget_size(b1);
  if (sz == 0) bad(name, "Button 上屏后 widget_size 仍是 0（版面没落到控件上？）");
  if (g_fail == before) {
    printf("NOTE  P8 实测：scale=%d 窗口=%dx%d 点 Label=%lldx%lld Button=%lldx%lld（物理像素）\n",
           scale, gtk_widget_get_width(gw), gtk_widget_get_height(gw),
           (long long)(moonui_native_widget_size(lab) >> 32),
           (long long)(moonui_native_widget_size(lab) & 0xFFFFFFFFLL),
           (long long)(sz >> 32), (long long)(sz & 0xFFFFFFFFLL));
  }

  /* ④ 焦点：先按坐标摆到第一只 Button，再让 **GTK 自己**遍历（child_focus 就是
   * Tab 在 gtk_window 默认处理器里走的那条路），看 owner 读回对不对。 */
  if (moonui_native_focus_widget_in_window("p8-real", 7, 21 * scale, 21 * scale) != 0) {
    bad(name, "真窗上按坐标摆焦点没返回 0");
  } else if (moonui_native_focused_control(win) != b1) {
    bad(name, "真窗上摆完焦点，focused_control 不是第一只 Button");
  }
  if (!gtk_widget_child_focus(gw, GTK_DIR_TAB_FORWARD)) {
    bad(name, "GTK 自己的 child_focus 说没有下一个可聚焦控件");
  } else if (moonui_native_focused_control(win) != b2) {
    bad(name, "GTK 自己正向遍历之后焦点没落到第二只 Button");
  }
  if (!gtk_widget_child_focus(gw, GTK_DIR_TAB_BACKWARD)) {
    bad(name, "GTK 自己的 child_focus 反向说没有上一个可聚焦控件");
  } else if (moonui_native_focused_control(win) != b1) {
    bad(name, "GTK 自己反向遍历之后焦点没回到第一只 Button");
  }

  moonui_native_window_destroy(win);
  /* 销毁之后这一份窗口不再登记：焦点读 0（指针比对，不解引用已释放的槽）。 */
  if (moonui_native_focused_control(win) != 0) bad(name, "窗口销毁后还能读出焦点");
  finish(name, before);
}

/* =========================================================================
 * P6-6：窗口状态与尺寸下限（真 GTK4 对象层）
 *
 * 形态来自 2026-11-10 的 /tmp 探针（真 GTK 4.24.1 / GdkMacosDisplay）：
 * resizable、size_request、maximize+is_maximized、present+is_active 都真往返。
 * 但 unfullscreen 之后 is_fullscreen 恒 1（泵 1600 轮不回落），minimize /
 * unminimize 的 mapped / active 全不变，Quartz 侧还报 _gdk_macos_surface_*
 * 断言。所以本组**不碰** set_fullscreen / set_minimized 的状态生效：那两条
 * 只由 canvas-pixel-check.sh 的静态断言钉「函数体真的调了 GTK API」，状态
 * 红绿归 CI 的 4.6 / X11 + xvfb。把本机恒 1 当绿正是本仓反复栽过的假绿。
 *
 * 所有断言读的都是 **GTK 原生对象**（gtk_window_get_resizable /
 * gtk_widget_get_size_request / gtk_window_is_maximized / gtk_window_is_active），
 * 不是我们自己那份账；ABI 的读回再与原生读数交叉核对。
 * ========================================================================= */

static void t_p66_state_roundtrip(void) {
  const char *name =
      "P6-6 窗口状态：resizable / min_size / maximized / state 真往返（读 GTK 原生对象）";
  int before = g_fail;
  moonui_ptr w;
  GtkWidget *gw;
  char d[256];
  int scale, i, mw = -1, mh = -1;
  int64_t sz;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  w = moonui_native_window_new("p66-state", 9, 320, 240);
  if (w == 0) {
    bad(name, "窗口造不出来");
    return;
  }
  gw = (GtkWidget *)(uintptr_t)w;
  scale = moonui_native_window_dpi(w) / 96;
  if (scale < 1) scale = 1;
  moonui_native_window_show(w);
  for (i = 0; i < 400; ++i) {
    if (gtk_widget_get_mapped(gw)) break;
    g_main_context_iteration(NULL, FALSE);
    g_usleep(5000);
  }
  if (!gtk_widget_get_mapped(gw)) {
    bad(name, "present 之后没映射（xvfb / 窗口管理器没起来？）");
    moonui_native_window_destroy(w);
    return;
  }

  /* ① resizable：读 GTK 对象，不是「setter 没报错」 */
  moonui_native_window_set_resizable(w, 0);
  if (gtk_window_get_resizable(GTK_WINDOW(gw)))
    bad(name, "set_resizable(0) 之后 GTK 仍说可缩放");
  moonui_native_window_set_resizable(w, 1);
  if (!gtk_window_get_resizable(GTK_WINDOW(gw)))
    bad(name, "set_resizable(1) 之后 GTK 仍说不可缩放");

  /* ② min_size：ABI 物理像素 → GTK 逻辑点 → 读回物理像素，两头都对才算数。
   * 清限制走契约的 0，GTK 侧必须回到 -1（探针实测 set(0,0) 会钳成 0x0）。 */
  moonui_native_window_set_min_size(w, 420 * scale, 260 * scale);
  gtk_widget_get_size_request(gw, &mw, &mh);
  if (mw != 420 || mh != 260) {
    snprintf(d, sizeof(d), "GTK size request 是 %dx%d 点，期望 420x260（scale=%d）",
             mw, mh, scale);
    bad(name, d);
  }
  sz = moonui_native_window_min_size(w);
  if ((sz >> 32) != 420 * scale || (sz & 0xFFFFFFFFLL) != 260 * scale) {
    snprintf(d, sizeof(d), "min_size 读回 %lldx%lld，期望 %dx%d（物理像素）",
             (long long)(sz >> 32), (long long)(sz & 0xFFFFFFFFLL),
             420 * scale, 260 * scale);
    bad(name, d);
  }
  moonui_native_window_set_min_size(w, 0, 0);
  gtk_widget_get_size_request(gw, &mw, &mh);
  if (mw != -1 || mh != -1) {
    snprintf(d, sizeof(d), "清限制后 GTK size request 是 %dx%d，期望 -1x-1", mw, mh);
    bad(name, d);
  }
  sz = moonui_native_window_min_size(w);
  if (sz != 0) bad(name, "清限制后 min_size 没回到打包的 (0,0)");

  /* ③ maximized → window_state 的 bit1（adapter.h:1931）。
   * bit0（minimized）在本机读不回，NOTE 里如实记，不拿它凑一条绿。 */
  moonui_native_window_set_maximized(w, 1);
  for (i = 0; i < 200; ++i) {
    if (gtk_window_is_maximized(GTK_WINDOW(gw))) break;
    g_main_context_iteration(NULL, FALSE);
    g_usleep(5000);
  }
  if (!gtk_window_is_maximized(GTK_WINDOW(gw)))
    bad(name, "set_maximized(1) 之后 GTK 仍说没最大化");
  if ((moonui_native_window_state(w) & 2) == 0)
    bad(name, "window_state 没读到 bit1（最大化）");
  moonui_native_window_set_maximized(w, 0);
  for (i = 0; i < 200; ++i) {
    if (!gtk_window_is_maximized(GTK_WINDOW(gw))) break;
    g_main_context_iteration(NULL, FALSE);
    g_usleep(5000);
  }
  if ((moonui_native_window_state(w) & 2) != 0)
    bad(name, "unmaximize 之后 window_state 的 bit1 没清");
  if (g_fail == before) {
    printf("NOTE  P6-6 实测：scale=%d，bit0(minimized) 与 fullscreen 回落在本机读不回，归 CI 4.6/X11\n",
           scale);
  }
  moonui_native_window_destroy(w);
  finish(name, before);
}

/* 焦点 A/B 的「1/0」是**系统前台状态**，不是本片能保证的：T238 已经定性
 * 锁屏 / 前台 loginwindow 是唯一变量，应用不在前台时 gtk_window_is_active
 * 恒 0，硬断言 A=1 会让判据随桌面状态偶发红（2026-11-10 实测同一份代码
 * 一轮三条红、下一轮全绿）。所以这里只钉本片真正的契约：
 *   ① moonui_native_window_is_key 的读数与 GTK 原生 is_active **逐拍一致**
 *      （摘掉实现改成 return 0 / return 1 都会在某拍露馅）；
 *   ② 整组至少出现过一次 active=1，否则「ABI 恒 0」与「GTK 恒 0」也能
 *      一致，判据不可观测 → 如实 SKIP，不冒充绿；
 *   ③ 空句柄回 -1（不依赖前台，任何环境下都要验）。
 * A/B 的实际读数打进 NOTE，方便下次偶发时一眼看出是谁的状态。 */
static void t_p66_focus_key(void) {
  const char *name =
      "P6-6 焦点：window_is_key 与 GTK is_active 逐拍一致 + 空句柄回 -1";
  int before = g_fail;
  moonui_ptr a, b;
  GtkWidget *ga, *gb;
  char d[256];
  int ka, kb, ga_act, gb_act, saw_active = 0;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  /* ③ 与前台无关，先验。 */
  ka = moonui_native_window_is_key((moonui_ptr)0);
  if (ka != -1) {
    snprintf(d, sizeof(d), "空句柄回 %d，期望 -1", ka);
    bad(name, d);
  }

  a = moonui_native_window_new("p66-key-a", 9, 300, 180);
  b = moonui_native_window_new("p66-key-b", 9, 300, 180);
  if (a == 0 || b == 0) {
    bad(name, "两只窗口造不出来");
    return;
  }
  ga = (GtkWidget *)(uintptr_t)a;
  gb = (GtkWidget *)(uintptr_t)b;

  /* 未上屏的窗口在 GTK 里一定不是 active，ABI 必须跟着说 0。这一拍**不依赖
   * 应用是否在前台**，是焦点判据里唯一在无 WM / 后台也照样有牙齿的一步：
   * 恒返 1 的谎报在这里露馅。（恒返 0 的谎报读不出来——两窗都 0 时「一致」
   * 恒成立——那种谎报由静态断言⑥「函数体真调了 gtk_window_is_active」兜住，
   * 2026-11-10 的 c6 负控制实测就是⑥点名红的。） */
  ka = moonui_native_window_is_key(a);
  kb = moonui_native_window_is_key(b);
  if (ka != 0 || kb != 0) {
    snprintf(d, sizeof(d),
             "未上屏窗口 is_key(A)=%d is_key(B)=%d，期望都是 0（GTK 此时 active=%d/%d）",
             ka, kb, gtk_window_is_active(GTK_WINDOW(ga)),
             gtk_window_is_active(GTK_WINDOW(gb)));
    bad(name, d);
  }

#define P66_PUMP() do { int _j; for (_j = 0; _j < 200; ++_j) { \
    g_main_context_iteration(NULL, FALSE); g_usleep(5000); } } while (0)
#define P66_SNAP(tag) do { \
    ka = moonui_native_window_is_key(a); kb = moonui_native_window_is_key(b); \
    ga_act = gtk_window_is_active(GTK_WINDOW(ga)); \
    gb_act = gtk_window_is_active(GTK_WINDOW(gb)); \
    if (ka != (ga_act ? 1 : 0) || kb != (gb_act ? 1 : 0)) { \
      snprintf(d, sizeof(d), tag " 拍：is_key(A)=%d is_key(B)=%d 但 gtk_active(A)=%d gtk_active(B)=%d（逐拍不一致）", \
               ka, kb, ga_act, gb_act); \
      bad(name, d); \
    } \
    if (ga_act || gb_act) saw_active = 1; \
    printf("NOTE  P6-6 焦点 " tag "：is_key=%d/%d gtk_active=%d/%d mapped=%d/%d\n", \
           ka, kb, ga_act, gb_act, \
           gtk_widget_get_mapped(ga), gtk_widget_get_mapped(gb)); \
  } while (0)

  moonui_native_window_show(a); P66_PUMP(); P66_SNAP("present A");
  moonui_native_window_show(b); P66_PUMP(); P66_SNAP("present B");
  moonui_native_window_show(a); P66_PUMP(); P66_SNAP("present A again");
#undef P66_SNAP
#undef P66_PUMP

  moonui_native_window_destroy(a);
  moonui_native_window_destroy(b);
  if (!saw_active) {
    /* 应用不在前台（或 CI xvfb 没有 WM）：两窗 is_active 恒 0，一致性判据
     * 没有牙齿。按 T238 口径如实跳过，不加重试护栏、不把 SKIP 算成 PASS。 */
    skip(name, "应用不在前台，两窗 gtk_window_is_active 恒 0，焦点判据不可观测");
    return;
  }
  finish(name, before);
}

static void t_p66_request_close(void) {
  const char *name = "P6-6 关闭请求：命中回 0 / 找不到回 -2 / 参数错回 -1";
  int before = g_fail;
  moonui_ptr w;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  if (moonui_native_request_window_close("p66-none", 9) != -2)
    bad(name, "不存在的标题没回 -2");
  if (moonui_native_request_window_close(NULL, -1) != -1)
    bad(name, "负长度没回 -1");
  w = moonui_native_window_new("p66-close", 9, 300, 180);
  if (w == 0) {
    bad(name, "窗口造不出来");
    return;
  }
  if (moonui_native_request_window_close("p66-close", 9) != 0)
    bad(name, "命中标题没回 0");
  /* 没订阅 closing 时 close-request 返 FALSE，GTK 会自己销毁窗口；
   * 这里不能再 destroy 同一个句柄（重复销毁会崩）。 */
  finish(name, before);
}

/* =========================================================================
 * T235 P6-7：窗口几何口径（3 条真实现 + 12 条如实不接）
 *
 * 3 条 screen_* 的判据拿 **GDK 自己的 monitor 读数**对拍（不是读回我们
 * 缓存的账）：主屏 geometry × scale 对 screen_work_area；at_surface 那块屏
 * 对 window_screen_origin/size；另外钉「非 0 尺寸」——0 会让 Window::center
 * 把窗口堆到左上角，正是这组要防的回归。
 *
 * 12 条平台专属 ABI 只能钉兜底常量是否守约（GTK4 没有这些概念）：getter 与
 * 空操作 setter 一致、movable_probe 保留 -1、6 个 void 空操作不许破坏几何。
 * 「函数体到底有没有接」由 canvas-pixel-check.sh 的 P6-7 静态断言兜住。
 * ========================================================================= */

/* 主屏 monitor（列表首项）。transfer full：调用方负责 g_object_unref。 */
static GdkMonitor *p67_monitor0(void) {
  GdkDisplay *d = gdk_display_get_default();
  GListModel *mons;
  if (d == NULL) return NULL;
  mons = gdk_display_get_monitors(d);
  if (mons == NULL || g_list_model_get_n_items(mons) == 0) return NULL;
  return (GdkMonitor *)g_list_model_get_item(mons, 0);
}

static void t_p67_screen_geometry(void) {
  const char *name =
      "P6-7 屏幕几何：screen_work_area / window_screen_origin/size 与 GdkMonitor 读数一致且非 0";
  int before = g_fail;
  moonui_ptr w;
  GtkWidget *gw;
  GdkSurface *surf;
  GdkMonitor *m;
  GdkRectangle geo;
  int scale, i, full_ref = 0;
  int64_t sz, org;
  char d[256];

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  m = p67_monitor0();
  if (m == NULL) {
    skip(name, "GDK 没报出任何 monitor（无显示器）");
    return;
  }
  gdk_monitor_get_geometry(m, &geo);
  scale = gdk_monitor_get_scale_factor(m);
  g_object_unref(m);
  if (scale < 1) scale = 1;
  if (geo.width <= 0 || geo.height <= 0) {
    skip(name, "主屏 geometry 非正（无显示器）");
    return;
  }

  /* ① 主屏整屏尺寸：物理像素 = 逻辑点 × scale */
  sz = moonui_native_screen_work_area();
  if ((sz >> 32) != (int64_t)geo.width * scale ||
      (sz & 0xFFFFFFFFLL) != (int64_t)geo.height * scale) {
    snprintf(d, sizeof(d), "screen_work_area 是 %lldx%lld，期望 %dx%d（scale=%d）",
             (long long)(sz >> 32), (long long)(sz & 0xFFFFFFFFLL),
             geo.width * scale, geo.height * scale, scale);
    bad(name, d);
  }
  if ((sz >> 32) <= 0 || (sz & 0xFFFFFFFFLL) <= 0) {
    snprintf(d, sizeof(d), "screen_work_area 报 0 尺寸（%lldx%lld）",
             (long long)(sz >> 32), (long long)(sz & 0xFFFFFFFFLL));
    bad(name, d);
  }

  w = moonui_native_window_new("p67-geo", 9, 320, 240);
  if (w == 0) {
    bad(name, "窗口造不出来");
    finish(name, before);
    return;
  }
  gw = (GtkWidget *)(uintptr_t)w;
  moonui_native_window_show(w);
  for (i = 0; i < 400; ++i) {
    if (gtk_widget_get_mapped(gw)) break;
    g_main_context_iteration(NULL, FALSE);
    g_usleep(5000);
  }
  if (!gtk_widget_get_mapped(gw)) {
    bad(name, "present 之后没映射（xvfb / 窗口管理器没起来？）");
    moonui_native_window_destroy(w);
    finish(name, before);
    return;
  }

  /* ② 窗口所在那块屏：优先 at_surface（transfer none，不 unref）；GDK 没给
   * 出来时退回首屏（transfer full，要 unref）对拍并记 NOTE */
  surf = gtk_native_get_surface(GTK_NATIVE(gw));
  m = NULL;
  if (surf != NULL) {
    m = gdk_display_get_monitor_at_surface(gtk_widget_get_display(gw), surf);
  }
  if (m == NULL) {
    printf("NOTE  P6-7：GDK 未给出窗口所在 monitor，按首屏对拍 origin/size\n");
    m = p67_monitor0();
    full_ref = m != NULL;
  }
  if (m != NULL) {
    GdkRectangle wgeo;
    int wscale;
    gdk_monitor_get_geometry(m, &wgeo);
    wscale = gdk_monitor_get_scale_factor(m);
    if (wscale < 1) wscale = 1;
    org = moonui_native_window_screen_origin(w);
    if ((org >> 32) != (int64_t)wgeo.x * wscale ||
        (org & 0xFFFFFFFFLL) != (int64_t)wgeo.y * wscale) {
      snprintf(d, sizeof(d),
               "window_screen_origin 是 (%lld,%lld)，期望 (%d,%d)（scale=%d）",
               (long long)(org >> 32), (long long)(org & 0xFFFFFFFFLL),
               wgeo.x * wscale, wgeo.y * wscale, wscale);
      bad(name, d);
    }
    sz = moonui_native_window_screen_size(w);
    if ((sz >> 32) != (int64_t)wgeo.width * wscale ||
        (sz & 0xFFFFFFFFLL) != (int64_t)wgeo.height * wscale) {
      snprintf(d, sizeof(d),
               "window_screen_size 是 %lldx%lld，期望 %dx%d（scale=%d）",
               (long long)(sz >> 32), (long long)(sz & 0xFFFFFFFFLL),
               wgeo.width * wscale, wgeo.height * wscale, wscale);
      bad(name, d);
    }
    if ((sz >> 32) <= 0 || (sz & 0xFFFFFFFFLL) <= 0) {
      snprintf(d, sizeof(d), "window_screen_size 报 0 尺寸（%lldx%lld）",
               (long long)(sz >> 32), (long long)(sz & 0xFFFFFFFFLL));
      bad(name, d);
    }
    if (full_ref) g_object_unref(m); /* 只有首屏那一支是 transfer full */
  }

  /* ③ 空句柄走主屏兜底：不许回 0 尺寸，且与 work_area 同值 */
  org = moonui_native_window_screen_origin((moonui_ptr)0);
  sz = moonui_native_window_screen_size((moonui_ptr)0);
  if (org != 0 || sz != moonui_native_screen_work_area() || sz == 0) {
    snprintf(d, sizeof(d),
             "空句柄兜底不对：origin=%lld size=%lld work_area=%lld",
             (long long)org, (long long)sz,
             (long long)moonui_native_screen_work_area());
    bad(name, d);
  }

  moonui_native_window_destroy(w);
  if (g_fail == before) {
    printf("NOTE  P6-7 实测：scale=%d，主屏 geometry=%dx%d+%d+%d\n", scale,
           geo.width, geo.height, geo.x, geo.y);
  }
  finish(name, before);
}

static void t_p67_window_noop_contract(void) {
  const char *name =
      "P6-7 窗口口径：12 条平台专属 ABI 的兜底常量与空操作不破坏几何";
  int before = g_fail;
  moonui_ptr w;
  int64_t org0, sz0, org1, sz1;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  /* 空句柄的 -1 契约与前端状态无关，先验。 */
  if (moonui_native_window_movable_probe((moonui_ptr)0) != -1)
    bad(name, "movable_probe(空句柄) 没回 -1");

  w = moonui_native_window_new("p67-noop", 9, 240, 160);
  if (w == 0) {
    bad(name, "窗口造不出来");
    finish(name, before);
    return;
  }
  if (moonui_native_window_movable_probe(w) != 0)
    bad(name, "movable_probe(有效窗口) 没回 0");
  if (moonui_native_window_in_live_resize(w) != 0)
    bad(name, "in_live_resize 没恒 0");
  if (moonui_native_window_titlebar_style(w) != 0)
    bad(name, "titlebar_style 没恒 0");
  if (moonui_native_window_drag_band(w) != 0)
    bad(name, "drag_band 没恒 0");
  if (moonui_native_window_traffic_light_position(w) != 0)
    bad(name, "traffic_light_position 没恒 (0,0)");
  if (moonui_native_window_position(w) != 0)
    bad(name, "position 没恒 (0,0)（GTK4 无窗口位置读口）");

  /* 6 个 void 空操作 + set_position：全调一遍，几何读数不许变。 */
  org0 = moonui_native_window_screen_origin(w);
  sz0 = moonui_native_window_screen_size(w);
  if (org0 == 0 && sz0 == 0) bad(name, "几何读数全 0，后续不变判据不可观测");
  moonui_native_window_set_position(w, 120, 80);
  moonui_native_window_move_external(w, 40, 30);
  moonui_native_window_drag_step(w, 41, 31);
  moonui_native_window_set_titlebar_style(w, 7);
  moonui_native_window_set_drag_band(w, 24);
  moonui_native_window_set_traffic_light_position(w, 12, 16);
  org1 = moonui_native_window_screen_origin(w);
  sz1 = moonui_native_window_screen_size(w);
  if (org0 != org1 || sz0 != sz1)
    bad(name, "空操作之后 screen_origin/size 变了（不该动几何账）");
  if (moonui_native_window_titlebar_style(w) != 0)
    bad(name, "set_titlebar_style(7) 之后 getter 没保持 0（setter 是空操作）");

  moonui_native_window_destroy(w);
  finish(name, before);
}

/* P6-9：图像源两条——真 GdkTexture 解码 + GtkPicture 装上。
 * 这是全仓唯一能证明「4.6 的两个 GdkTexture 入口真把 PNG 解成纹理」的地方：
 * 假头闸（mock 第 18 组）只验账（返回码 / GError 释放 / 引用配平），解不出像素。
 * 像素尺寸写进判据，所以「纹理真的是这张图」不靠指针比对。 */
static void t_image_source(void) {
  const char *name = "图像源：set_path / set_data（真 GdkTexture 解码）";
  int before = g_fail;
  /* 一张 95 字节的合法 4×3 RGBA PNG（sips -g pixelWidth/Height 读得出 4×3）。 */
  static const unsigned char png43[] = {
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00,
      0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
      0x00, 0x03, 0x08, 0x06, 0x00, 0x00, 0x00, 0xB4, 0xF4, 0xAE, 0xC6,
      0x00, 0x00, 0x00, 0x26, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x15,
      0xC8, 0x31, 0x01, 0x00, 0x20, 0x00, 0xC3, 0xB0, 0xCA, 0x99, 0x9C,
      0xC9, 0xD9, 0x89, 0x73, 0x28, 0x47, 0x9E, 0x00, 0xE7, 0x46, 0xD5,
      0x04, 0x31, 0x54, 0x2D, 0x3F, 0x6A, 0xA8, 0x9A, 0x1E, 0x13, 0x41,
      0x16, 0xA5, 0xC3, 0x0F, 0xA4, 0x72, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  };
  char path[160];
  char badpath[160];
  FILE *f;
  moonui_ptr img, label;
  GtkWidget *w;
  GdkPaintable *p;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  img = moonui_native_widget_new(16, "", 0);
  label = moonui_native_widget_new(0, "x", 1);
  if (img == 0 || label == 0) {
    bad(name, "图像控件或对照控件造不出来");
    if (img != 0) moonui_native_widget_destroy(img);
    if (label != 0) moonui_native_widget_destroy(label);
    finish(name, before);
    return;
  }
  snprintf(path, sizeof(path), "/tmp/moonui-p69-%ld.png", (long)getpid());
  snprintf(badpath, sizeof(badpath), "/tmp/moonui-p69-%ld.txt", (long)getpid());
  f = fopen(path, "wb");
  if (f == NULL) {
    bad(name, "临时 PNG 写不出去（/tmp 不可写）");
  } else {
    size_t n = fwrite(png43, 1, sizeof(png43), f);
    fclose(f);
    if (n != sizeof(png43)) bad(name, "临时 PNG 没写完");
  }
  f = fopen(badpath, "wb");
  if (f != NULL) {
    fputs("not a png at all\n", f);
    fclose(f);
  }

  /* 文件源：真解码 → 纹理 4×3。 */
  if (moonui_native_image_set_path(img, path, (int)strlen(path)) != 0) {
    bad(name, "set_path(真 PNG) 没回 0");
  } else {
    w = (GtkWidget *)(uintptr_t)img;
    p = gtk_picture_get_paintable(GTK_PICTURE(w));
    if (p == NULL) {
      bad(name, "set_path 之后 paintable 是 NULL");
    } else if (!GDK_IS_TEXTURE(p)) {
      /* GdkTexture 是抽象基类，真身是 GdkMemoryTexture（或 GdkGLTexture），
       * 所以不能拿类型名跟 "GdkTexture" 比。 */
      char d[160];
      snprintf(d, sizeof(d), "set_path 装上的不是纹理，是 %s",
               G_OBJECT_TYPE_NAME(G_OBJECT(p)));
      bad(name, d);
    } else if (gdk_texture_get_width((GdkTexture *)p) != 4 ||
               gdk_texture_get_height((GdkTexture *)p) != 3) {
      char d[128];
      snprintf(d, sizeof(d), "纹理尺寸不是 4×3，实际 %d×%d",
               gdk_texture_get_width((GdkTexture *)p),
               gdk_texture_get_height((GdkTexture *)p));
      bad(name, d);
    }
  }
  /* 坏路径不动已装的那张图（整源替换只在成功时发生）。 */
  if (moonui_native_image_set_path(img, badpath, (int)strlen(badpath)) != -1)
    bad(name, "set_path(文本文件) 没回 -1");
  if (moonui_native_image_set_path(img, NULL, 0) != -1)
    bad(name, "set_path(NULL) 没回 -1");
  p = gtk_picture_get_paintable(GTK_PICTURE((GtkWidget *)(uintptr_t)img));
  if (p == NULL || gdk_texture_get_width((GdkTexture *)p) != 4)
    bad(name, "失败路径把已装好的图弄丢了");

  /* 数据源：同一份字节 → 0，纹理仍是 4×3（整源替换）。 */
  if (moonui_native_image_set_data(img, (const char *)png43,
                                   (int)sizeof(png43)) != 0) {
    bad(name, "set_data(真 PNG 字节) 没回 0");
  } else {
    p = gtk_picture_get_paintable(GTK_PICTURE((GtkWidget *)(uintptr_t)img));
    if (p == NULL || gdk_texture_get_width((GdkTexture *)p) != 4 ||
        gdk_texture_get_height((GdkTexture *)p) != 3)
      bad(name, "set_data 之后纹理不是 4×3");
  }
  if (moonui_native_image_set_data(img, "garbage!", 8) != -1)
    bad(name, "set_data(垃圾字节) 没回 -1");
  if (moonui_native_image_set_data(img, NULL, 4) != -1)
    bad(name, "set_data(NULL) 没回 -1");
  if (moonui_native_image_set_data(img, "x", 0) != -1)
    bad(name, "set_data(len 0) 没回 -1");

  /* kind 护栏：非图像控件 / 空句柄 → -2（不是 -1，也不是 0）。 */
  if (moonui_native_image_set_path(label, path, (int)strlen(path)) != -2)
    bad(name, "set_path(Label) 没回 -2");
  if (moonui_native_image_set_data(label, (const char *)png43, 8) != -2)
    bad(name, "set_data(Label) 没回 -2");
  if (moonui_native_image_set_path(0, path, (int)strlen(path)) != -2)
    bad(name, "set_path(0 句柄) 没回 -2");
  if (moonui_native_image_set_data(0, (const char *)png43, 8) != -2)
    bad(name, "set_data(0 句柄) 没回 -2");

  unlink(path);
  unlink(badpath);
  moonui_native_widget_destroy(img);
  moonui_native_widget_destroy(label);
  finish(name, before);
}

/* ---- P6-10：文件拖入（真 GdkFileList 驱动完整 "drop" 分发）----
 * 这里验的是假头构建验不到的那半：GtkDropTarget 的 "drop" 回调把 boxed
 * GdkFileList 里的 GFile 逐个取路径、按契约打包、再调进程级闭包。窗口用
 * moonui_native_window_new 真造（建窗即挂落点），但不进主循环、不上屏。 */
static int g_drop_events = 0;
static void drop_probe_closure(void *closure) {
  (void)closure;
  g_drop_events += 1;
}

static void t_file_drop(void) {
  const char *name = "文件拖入：GdkFileList → 快照 → 闭包";
  int before = g_fail;
  moonui_ptr win;
  GFile *files[2];
  GdkFileList *list;
  GdkFileList *empty;
  GValue v = G_VALUE_INIT;
  GValue v_null = G_VALUE_INIT;
  moonbit_bytes_t pack;
  const unsigned char *b;
  char p1[200];
  char p2[200];
  size_t n1, n2;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  win = moonui_native_window_new("moonui-p610", 4, 200, 120);
  if (win == 0) {
    bad(name, "窗口造不出来");
    moonui_native_terminate();
    return;
  }
  snprintf(p1, sizeof(p1), "/tmp/moonui-p610-%ld-a.txt", (long)getpid());
  snprintf(p2, sizeof(p2), "/tmp/moonui-p610-%ld-b.txt", (long)getpid());
  n1 = strlen(p1);
  n2 = strlen(p2);
  files[0] = g_file_new_for_path(p1);
  files[1] = g_file_new_for_path(p2);
  list = gdk_file_list_new_from_array(files, 2);
  g_value_init(&v, GDK_TYPE_FILE_LIST);
  g_value_set_boxed(&v, list);

  g_drop_events = 0;
  expect_rc(name, "on_file_drop", moonui_native_on_file_drop(drop_probe_closure, 0), 0);
  moonui_gtk_on_file_drop(NULL, &v, 0, 0, (gpointer)(uintptr_t)win);

  /* 快照：target 是接住拖入的那只窗口，闭包恰好响一声。 */
  if ((moonui_ptr)moonui_native_file_drop_target() != win)
    bad(name, "target 不是接住拖入的窗口");
  if (g_drop_events != 1) bad(name, "闭包没有恰好响一声");

  pack = moonui_native_file_drop_paths();
  b = (const unsigned char *)pack;
  /* 布局：i32 count, i32 len, 内容, i32 len, 内容。 */
  if (Moonbit_array_length(pack) != (int32_t)(4 + 4 + n1 + 4 + n2))
    bad(name, "paths 包长度与契约不符");
  if (b[0] != 2) bad(name, "count 字段不是 2");
  if (b[4] != (unsigned char)n1) bad(name, "第一条长度字段不对");
  if (memcmp(b + 8, p1, n1) != 0) bad(name, "第一条路径内容不对");
  if (memcmp(b + 8 + n1 + 4, p2, n2) != 0) bad(name, "第二条路径内容不对");

  /* 空文件列表：清空快照、不再产事件（拖的不是文件就不报）。 */
  empty = gdk_file_list_new_from_array(NULL, 0);
  g_value_set_boxed(&v, empty);
  moonui_gtk_on_file_drop(NULL, &v, 0, 0, (gpointer)(uintptr_t)win);
  if (moonui_native_file_drop_target() != 0) bad(name, "空列表没把 target 清 0");
  pack = moonui_native_file_drop_paths();
  if (Moonbit_array_length(pack) != 0) bad(name, "空列表读回不是空包");
  if (g_drop_events != 1) bad(name, "空列表不该再响闭包");

  /* boxed 值为 NULL（不是文件拖拽）：不崩、不产事件。 */
  g_value_init(&v_null, GDK_TYPE_FILE_LIST);
  moonui_gtk_on_file_drop(NULL, &v_null, 0, 0, (gpointer)(uintptr_t)win);
  if (moonui_native_file_drop_target() != 0) bad(name, "NULL boxed 弄脏了 target");
  if (g_drop_events != 1) bad(name, "NULL boxed 不该响闭包");

  /* 收窗要撤掉快照：先重新装上（target = 这只窗口），destroy 之后 target 归零，
   * 不再把已销毁的句柄交出去。 */
  g_value_set_boxed(&v, list);
  moonui_gtk_on_file_drop(NULL, &v, 0, 0, (gpointer)(uintptr_t)win);
  if ((moonui_ptr)moonui_native_file_drop_target() != win)
    bad(name, "收窗前没把 target 装回去");
  g_value_unset(&v_null);
  g_value_unset(&v);
  g_object_unref(empty);
  g_object_unref(list);
  g_object_unref(files[0]);
  g_object_unref(files[1]);
  /* 摘掉回调再收窗：terminate 与收窗都不该对着已释放的闭包操作。 */
  moonui_native_on_file_drop(0, 0);
  moonui_native_window_destroy(win);
  if (moonui_native_file_drop_target() != 0) bad(name, "收窗后 target 没清 0");
  moonui_native_terminate();
  finish(name, before);
}

/* ---- P6-12：后台任务（真 pthread + 真 glib 默认主上下文）----
 * 这里验的是假头构建验不到的那半：落地真的排进 glib 的事件队列，由
 * g_main_context_iteration 取走——也就是 UI 线程每圈做的那一句。work 必须在
 * 另一条线程跑（否则"后台"是假的）；两支闭包各一份引用，各自执行点回收。 */
static int g_p612_work = 0;
static int g_p612_land = 0;
static int g_p612_work_on_main = -1;
static int g_p612_land_on_main = -1;
static pthread_t g_p612_main;
static void p612_work_cb(void *closure) {
  (void)closure;
  g_p612_work_on_main = pthread_equal(pthread_self(), g_p612_main) ? 1 : 0;
  g_p612_work++;
}
static void p612_land_cb(void *closure) {
  (void)closure;
  g_p612_land_on_main = pthread_equal(pthread_self(), g_p612_main) ? 1 : 0;
  g_p612_land++;
}

static void t_worker_run(void) {
  const char *name = "后台任务：worker 线程 + glib 主上下文落地";
  int before = g_fail;
  int i;

  g_worker_incref = 0;
  g_worker_decref = 0;
  g_p612_work = 0;
  g_p612_land = 0;
  g_p612_work_on_main = -1;
  g_p612_land_on_main = -1;
  g_p612_main = pthread_self();

  /* 四参数任一缺失：-1，且不拿引用、不起线程。 */
  if (moonui_native_worker_run(0, (void *)0x11, p612_land_cb, (void *)0x22) != -1 ||
      moonui_native_worker_run(p612_work_cb, 0, p612_land_cb, (void *)0x22) != -1 ||
      moonui_native_worker_run(p612_work_cb, (void *)0x11, 0, (void *)0x22) != -1 ||
      moonui_native_worker_run(p612_work_cb, (void *)0x11, p612_land_cb, 0) != -1) {
    bad(name, "四参数任一缺失没有回 -1");
    finish(name, before);
    return;
  }
  if (g_worker_incref != 0) bad(name, "缺参数也动了引用");

  expect_rc(name, "worker_run",
            moonui_native_worker_run(p612_work_cb, (void *)0x11, p612_land_cb,
                                     (void *)0x22),
            0);
  if (g_worker_incref != 2) bad(name, "起线程前没有拿住两份引用");
  /* 等 work 跑完并把落地排进默认主上下文。落地本身必须等下面那次泵。 */
  for (i = 0; i < 2000 && (g_p612_work == 0 || g_p612_land != 0); i++) {
    g_usleep(1000);
  }
  if (g_p612_work != 1) bad(name, "work 没跑或跑了不止一次");
  if (g_p612_work_on_main != 0) bad(name, "work 跑在主线程上（那就不是后台任务）");
  if (g_p612_land != 0) bad(name, "还没泵主循环，land 就先跑了");
  if (g_worker_decref != 1) bad(name, "work 返回后没有回收自己那份引用");
  /* 泵默认主上下文：真事件循环每圈做的同一句。 */
  for (i = 0; i < 2000 && g_p612_land == 0; i++) {
    g_main_context_iteration(NULL, FALSE);
    g_usleep(1000);
  }
  if (g_p612_land != 1) bad(name, "落地没跑或跑了不止一次");
  if (g_p612_land_on_main != 1) bad(name, "land 不在主线程（投递丢了线程归属）");
  if (g_worker_decref != 2) bad(name, "两份引用没有配平");
  finish(name, before);
}

/* ---- P6-14 / T251：输入法组合相位的旁听（真 GTK）----
 * 本组证的是接线与相位机：GtkEntry / GtkTextView 内部那份 GtkIMContext 用 4.0
 * 起公开的取口拿到（get_delegate → observe_controllers → key controller 的
 * get_im_context），再从外面 g_signal_emit_by_name 驱动 preedit 三相位。真输入法
 * （ibus / fcitx5）注入的组合串要 Linux 真机，那是 T251 的余项。 */

/* 复刻后端 attach 的取口，用来交叉验证"我们连的就是控件正在用的那份"。 */
static GtkIMContext *ime_ctx_of(GtkWidget *w) {
  GtkWidget *edit = w;
  GListModel *model;
  GtkIMContext *ctx = NULL;
  guint n, i;
  if (w == NULL) {
    return NULL;
  }
  if (GTK_IS_EDITABLE(w)) {
    GtkEditable *d = gtk_editable_get_delegate(GTK_EDITABLE(w));
    if (d != NULL) {
      edit = GTK_WIDGET(d);
    }
  }
  model = gtk_widget_observe_controllers(edit);
  if (model == NULL) {
    return NULL;
  }
  n = g_list_model_get_n_items(model);
  for (i = 0; i < n && ctx == NULL; ++i) {
    gpointer item = g_list_model_get_item(model, i);
    if (item != NULL) {
      if (GTK_IS_EVENT_CONTROLLER_KEY(item)) {
        ctx = gtk_event_controller_key_get_im_context(
            GTK_EVENT_CONTROLLER_KEY(item));
      }
      g_object_unref(item);
    }
  }
  g_object_unref(model);
  return ctx;
}

static void ime_count_cb(void *closure) { ++(*(int *)closure); }

static void t_ime_preedit(void) {
  const char *nm = "P6-14 输入法组合：GTK4 旁听 IM context 的 preedit 三相位";
  int before = g_fail;
  moonui_ptr h;
  GtkWidget *w;
  GtkIMContext *ctx;
  moonui_ptr mh;
  GtkIMContext *mctx;
  int calls = 0;
  moonbit_bytes_t text;

  if (moonui_native_init() != 0) {
    skip(nm, "gtk_init 失败（无显示器）");
    return;
  }

  h = moonui_native_widget_new(2, "", 0);
  if (h == 0) {
    bad(nm, "单行文本控件造不出来");
    finish(nm, before);
    return;
  }
  w = (GtkWidget *)(uintptr_t)h;
  ctx = ime_ctx_of(w);
  if (ctx == NULL) {
    bad(nm, "单行控件取不到内部 GtkIMContext（4.0 的旁听取口断了）");
    moonui_native_widget_destroy(h);
    finish(nm, before);
    return;
  }
  expect_rc(nm, "on_ime 装上计数闭包", moonui_native_on_ime(ime_count_cb, &calls), 0);

  /* 开始：相位 0、target 是这只控件、不带串。 */
  g_signal_emit_by_name(ctx, "preedit-start");
  expect_ll(nm, "start 通知 1 次", calls, 1);
  expect_ll(nm, "start 的 target 是这只控件", (long long)moonui_native_ime_target(),
            (long long)h);
  expect_ll(nm, "start 相位 0", moonui_native_ime_phase(), 0);
  text = moonui_native_ime_text();
  expect_ll(nm, "start 的不带串", text == NULL ? -1 : (long long)Moonbit_array_length(text), 0);

  /* 没有真输入法时 changed 读到空串：按结束处理（相位 2，不带串）。 */
  g_signal_emit_by_name(ctx, "preedit-changed");
  expect_ll(nm, "空串 changed 通知 1 次", calls, 2);
  expect_ll(nm, "空串 changed 相位 2", moonui_native_ime_phase(), 2);
  text = moonui_native_ime_text();
  expect_ll(nm, "结束时不带串", text == NULL ? -1 : (long long)Moonbit_array_length(text), 0);

  /* 开始 → 结束：各一次。 */
  g_signal_emit_by_name(ctx, "preedit-start");
  g_signal_emit_by_name(ctx, "preedit-end");
  expect_ll(nm, "start + end 各通知一次", calls, 4);
  expect_ll(nm, "end 后相位 2", moonui_native_ime_phase(), 2);

  /* 组合中销毁控件：快照跟着清掉，且销毁本身不再发通知。 */
  g_signal_emit_by_name(ctx, "preedit-start");
  moonui_native_widget_destroy(h);
  expect_ll(nm, "销毁不再通知", calls, 5);
  expect_ll(nm, "销毁后 target 归 0", (long long)moonui_native_ime_target(), 0);
  expect_ll(nm, "销毁后相位归 0", moonui_native_ime_phase(), 0);

  /* 多行：IM context 就在 GtkTextView 自己身上（delegate 为 NULL 那条分支）。 */
  mh = moonui_native_multiline_new();
  if (mh == 0) {
    bad(nm, "多行文本控件造不出来");
  } else {
    mctx = ime_ctx_of((GtkWidget *)(uintptr_t)mh);
    if (mctx == NULL) {
      bad(nm, "多行控件取不到自己的 GtkIMContext");
    } else {
      g_signal_emit_by_name(mctx, "preedit-start");
      expect_ll(nm, "多行 start 通知一次", calls, 6);
      expect_ll(nm, "多行 target 是它自己", (long long)moonui_native_ime_target(),
                (long long)mh);
      expect_ll(nm, "多行 start 相位 0", moonui_native_ime_phase(), 0);
      g_signal_emit_by_name(mctx, "preedit-end");
      expect_ll(nm, "多行 end 通知一次", calls, 7);
    }
    moonui_native_widget_destroy(mh);
  }

  moonui_native_on_ime(NULL, NULL);
  expect_ll(nm, "清账后 target 归 0", (long long)moonui_native_ime_target(), 0);
  finish(nm, before);
}

int main(void) {
  t_fill_rect_opaque();
  t_fill_rect_rounded();
  t_fill_rect_alpha();
  t_read_pixel_bounds();
  t_clip_rect();
  t_translate_save_restore();
  t_line();
  t_arc_full();
  t_arc_half_direction();
  t_arc_zero_sweep();
  t_fill_polygon();
  t_fill_linear();
  t_blur_region();
  t_shadow();
  t_measure_text();
  t_draw_text();
  t_draw_image();
  t_error_paths();

  /* P6-1：控件挂载层（真 GTK4 结构，不需要显示器） */
  t_widget_new_kinds();
  t_widget_props();
  t_widget_attach_z();
  t_widget_bounds_origin();
  t_canvas_on_widget_window();

  /* T241：窗口缩放口径（物理像素往返；2x 屏上真有牙齿） */
  t_window_new_scale_roundtrip();

  /* P6-2：剪贴板（真 GDK；会临时占用系统剪贴板，每条自己恢复） */
  t_clipboard_roundtrip();
  t_clipboard_overwrite();
  t_clipboard_bad_args();

  /* P6-4：菜单栏与上下文菜单（真 GTK4；不碰显示服务器） */
  t_menu_install_dump();
  t_menu_set_checked();
  t_menu_click();
  t_menu_uninstall();
  t_menu_context();

  /* P6-4b：系统外观读数 + CSS 样式下发（真 GTK4 对象层） */
  t_theme_system_dark();
  t_theme_panel_css();
  t_theme_provider_on_display();
  t_theme_kind_guard();

  /* P6-4c：无障碍语义 + 两条系统偏好 + 自绘面焦点 opt-in（真 GTK4 对象层） */
  t_a11y_semantics();
  t_a11y_text_edges();
  t_a11y_state_alive();
  t_a11y_preferences();
  t_a11y_focusable();

  /* P6-5：控件叶子（十二种 kind + 文案 / 占位 / 勾选 / 回调 / 真控件外观） */
  t_leaf_text();
  t_leaf_placeholder();
  t_leaf_checked();
  t_leaf_callbacks();
  t_leaf_style();

  /* P6-5b：MenuRow / Scroll / 自绘面点击 / 焦点链（真 GTK4 对象层） */
  t_p65b_menurow();
  t_p65b_scroll();
  t_p65b_custom_click();
  t_p65b_focus_chain();
  t_p65b_focus_widget();

  /* P6-5c：七构造族（kinds 6..12，专属构造入口；真 GTK4 对象层） */
  t_widget_p65c_controls();

  /* P8：真窗判据（会真的把窗口 present 出来，桌面上闪一下） */
  t_p8_real_window();

  /* P6-6：窗口状态与尺寸下限（真 GTK4 对象层；fullscreen/minimized 的状态
   * 生效本机读不回，只由本闸的静态断言钉真 API 被调用，状态归 CI） */
  t_p66_state_roundtrip();
  t_p66_focus_key();
  t_p66_request_close();

  /* P6-7：窗口几何口径（3 条 GdkMonitor 真实现 + 12 条如实不接） */
  t_p67_screen_geometry();
  t_p67_window_noop_contract();

  /* P6-9：图像源两条（真 GdkTexture 解码 + GtkPicture 装上） */
  t_image_source();
  t_file_drop();
  t_worker_run();

  /* P6-14 / T251：输入法组合相位的旁听（真 GTK 信号驱动） */
  t_ime_preedit();

  /* P6-3：对话框与文件面板（消息框真跑，会在桌面上闪一下；文件面板要 schema） */
  t_dialog_message();
  t_dialog_confirm_yes();
  t_dialog_confirm_no();
  t_dialog_bad_utf8();
  t_dialog_dismiss_bounds();
  t_file_dialog_cancel();
  t_file_dialog_save_folder();
  t_auto_answer_codes();

  printf("\n[canvas-pixel] pass=%d fail=%d skip=%d\n", g_pass, g_fail, g_skip);
  if (g_fail > 0) {
    printf("[canvas-pixel] 有判据红——上面每行 FAIL 都点明了期望值与实际值\n");
    return 1;
  }
  /* SKIP ≠ PASS 的两档（T235 P7）：一般的跳过（本机缺字体栈 / 缺 pixbuf 解码器 /
   * 缺 schema）是已知的、可解释的，报个数就行；但"拿不到显示"这一档是**环境坏
   * 了**，不是"这台机器天生看不见"——它会让几十条判据一起消失而 fail 仍是 0。
   * Linux CI 上最常见的原因就是 xvfb 没装或 DISPLAY 没导出，所以这里必须红。 */
  if (g_nodisplay > 0) {
    printf("[canvas-pixel] FAIL：%d 条判据因为拿不到显示（gtk_init 失败）被跳过——SKIP ≠ PASS\n",
           g_nodisplay);
    printf("   Linux 上这条几乎总是 xvfb 没起作用：确认装了 xvfb，或用\n");
    printf("   `bash scripts/canvas-pixel-check.sh`（没有 DISPLAY 时会自己 exec xvfb-run -a）。\n");
    return 1;
  }
  if (g_skip > 0) {
    printf("[canvas-pixel] 有判据被跳过（SKIP ≠ PASS）：%d 条，原因见上\n", g_skip);
  }
  return 0;
}
